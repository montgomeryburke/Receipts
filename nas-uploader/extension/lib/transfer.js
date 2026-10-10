// Transfer queue: parallel uploads, server-side moves and deletions (for mirrors), retries with back-off,
// pause/resume/cancel, skip-existing (resume) and verification.

import { WebDAVError } from './webdav.js';
import { joinPath, parentPath, baseName, normalizePath, sleep, waitForOnline } from './util.js';

let nextId = 1;

/** True when the NAS copy was written after the local file was last modified (HTTP dates have 1 s resolution). */
export function remoteIsUpToDate(remoteModified, localMtime) {
  if (!remoteModified || isNaN(remoteModified)) return true;
  return remoteModified.getTime() >= Math.floor(localMtime / 1000) * 1000;
}

export class TransferManager extends EventTarget {
  /**
   * @param {import('./webdav.js').WebDAVClient} client
   * @param {{concurrency?: number, skipExisting?: boolean, verify?: boolean, maxAttempts?: number, retryBaseMs?: number, autoResumeMs?: number}} options
   */
  constructor(client, options = {}) {
    super();
    this.client = client;
    this.options = { concurrency: 3, skipExisting: true, verify: true, maxAttempts: 8, retryBaseMs: 2000, autoResumeMs: 60000, ...options };
    this.state = 'idle'; // idle | running | paused | verifying | done | cancelled
    this.runs = 0; // incremented every time a new run starts (used by the UI and tests)
    this.connectionIssue = null; // {message, resumeAt} while auto-paused because the NAS is unreachable
    this.autoResumeTimer = null;
    this.reset();
  }

  reset() {
    this.tasks = [];
    this.queue = [];
    this.qi = 0;
    this.front = [];
    this.deferred = []; // deletions: only run once every upload and move has finished
    this.active = new Set();
    this.dirMemo = new Map(); // folder -> Promise<{created}>
    this.listMemo = new Map(); // folder -> Promise<Map(name -> entry)>
    this.knownDirs = new Set(); // folders known to exist
    this.knownListings = new Map(); // folder -> Map(name -> entry), known without asking the NAS
    this.createdDirs = new Set();
    this.batches = []; // mirror batches, kept until the next fresh session
    this.session = new AbortController();
    this.sentBytes = 0;
    this.samples = [];
    this.startedAt = 0;
    this.finishedAt = 0;
    this.verifying = false;
    this.verifyProgress = null;
  }

  setClient(client) {
    this.client = client;
  }

  emit() {
    this.dispatchEvent(new Event('change'));
  }

  setState(s) {
    if (this.state !== s) {
      if (s === 'running' && !this.busy) this.runs++;
      this.state = s;
      this.emit();
    }
  }

  get busy() {
    return this.state === 'running' || this.state === 'paused' || this.state === 'verifying';
  }

  startSessionIfIdle() {
    if (this.busy) return;
    // Start a fresh session, but keep earlier failures visible until the user clears them.
    const keep = this.tasks.filter((t) => t.status === 'failed');
    this.reset();
    for (const t of keep) this.tasks.push(t);
    this.startedAt = Date.now();
  }

  newTask(fields) {
    const t = { id: nextId++, status: 'pending', loaded: 0, size: 0, error: null, note: null, ...fields };
    this.tasks.push(t);
    return t;
  }

  start() {
    if (this.state !== 'paused') this.setState('running');
    this.emit();
    this.pump();
  }

  /**
   * Queue a scanned batch for upload into destRoot.
   * @param {{files: {rel: string, file: File}[], dirs: string[]}} scan
   * @param {string} destRoot existing folder on the NAS
   */
  addBatch(scan, destRoot) {
    this.startSessionIfIdle();
    destRoot = normalizePath(destRoot);
    this.knownDirs.add(destRoot);

    const fileDirs = new Set();
    for (const { rel, file } of scan.files) {
      const destPath = joinPath(destRoot, rel);
      const task = this.newTask({ kind: 'file', rel, name: baseName(destPath), destPath, destDir: parentPath(destPath), file, size: file.size, expectSize: file.size, verified: false });
      this.queue.push(task);
      for (let d = task.destDir; d !== '/' && !fileDirs.has(d); d = parentPath(d)) fileDirs.add(d);
    }
    // Folders with no files inside them still need to exist on the NAS.
    for (const rel of scan.dirs) {
      const destPath = joinPath(destRoot, rel);
      if (fileDirs.has(destPath)) continue;
      this.queue.push(this.newTask({ kind: 'dir', rel: rel + '/', name: baseName(destPath), destPath, destDir: parentPath(destPath) }));
    }
    this.start();
  }

  /**
   * Queue a mirror plan (from mirror.js planMirror) that makes the NAS folder `root` match the local folder.
   * Uploads and moves run first; deletions run last, once everything else has finished.
   * @returns {{kind: 'mirror', root: string, plan: object, remote: object, tasks: object[]}}
   */
  addMirror(plan, root, remote, extra = {}) {
    this.startSessionIfIdle();
    root = normalizePath(root);
    const batch = { kind: 'mirror', root, plan, remote, tasks: [], ...extra };
    const mk = (fields) => {
      const t = this.newTask({ ...fields, batch });
      batch.tasks.push(t);
      return t;
    };

    // Seed what the listing already told us, so the queue doesn't have to ask the NAS again.
    if (remote.exists) {
      this.knownDirs.add(root);
      const listings = new Map([[root, new Map()]]);
      for (const d of remote.dirs.values()) {
        const abs = joinPath(root, d.rel);
        this.knownDirs.add(abs);
        if (d.listed) listings.set(abs, new Map());
      }
      for (const d of remote.dirs.values()) {
        const abs = joinPath(root, d.rel);
        listings.get(parentPath(abs))?.set(baseName(abs), { name: baseName(abs), isDir: true });
      }
      for (const f of remote.files.values()) {
        const abs = joinPath(root, f.rel);
        listings.get(parentPath(abs))?.set(baseName(abs), { name: baseName(abs), isDir: false, size: f.size, modified: f.modified });
      }
      for (const [k, v] of listings) this.knownListings.set(k, v);
    } else {
      this.queue.push(mk({ kind: 'dir', rel: baseName(root) + '/', name: baseName(root), destPath: root, destDir: parentPath(root) }));
    }

    const fileDirs = new Set();
    const noteDirs = (destDir) => {
      for (let d = destDir; d !== '/' && !fileDirs.has(d); d = parentPath(d)) fileDirs.add(d);
    };
    for (const m of plan.moves) {
      const to = joinPath(root, m.to);
      const t = mk({
        kind: 'move',
        rel: m.to,
        name: baseName(to),
        from: joinPath(root, m.from),
        destPath: to,
        destDir: parentPath(to),
        file: m.file,
        expectSize: m.file.size,
        verified: false,
        mirrorRel: m.to,
        mirrorFrom: m.from,
        localSize: m.file.size,
        localMtime: m.file.lastModified,
      });
      this.queue.push(t);
      noteDirs(t.destDir);
    }
    for (const u of plan.uploads) {
      const destPath = joinPath(root, u.rel);
      const t = mk({
        kind: 'file',
        force: true,
        reason: u.reason,
        rel: u.rel,
        name: baseName(destPath),
        destPath,
        destDir: parentPath(destPath),
        file: u.file,
        size: u.file.size,
        expectSize: u.file.size,
        verified: false,
        mirrorRel: u.rel,
        localSize: u.file.size,
        localMtime: u.file.lastModified,
      });
      this.queue.push(t);
      noteDirs(t.destDir);
    }
    for (const rel of plan.createDirs) {
      const destPath = joinPath(root, rel);
      if (fileDirs.has(destPath)) continue;
      this.queue.push(mk({ kind: 'dir', rel: rel + '/', name: baseName(destPath), destPath, destDir: parentPath(destPath) }));
    }
    for (const d of plan.deleteDirs) {
      const p = joinPath(root, d.rel);
      this.deferred.push(mk({ kind: 'delete', dir: true, rel: d.rel + '/', name: baseName(p), destPath: p, destDir: parentPath(p), mirrorRel: d.rel, count: d.files }));
    }
    for (const d of plan.deletes) {
      const p = joinPath(root, d.rel);
      this.deferred.push(mk({ kind: 'delete', dir: false, rel: d.rel, name: baseName(p), destPath: p, destDir: parentPath(p), mirrorRel: d.rel, count: 1 }));
    }
    this.batches.push(batch);
    this.start();
    return batch;
  }

  // ---- queue mechanics ---------------------------------------------------

  nextPending() {
    while (this.front.length) {
      const t = this.front.shift();
      if (t.status === 'pending') return t;
    }
    while (this.qi < this.queue.length) {
      const t = this.queue[this.qi++];
      if (t.status === 'pending') return t;
    }
    // Compact the queue so it doesn't grow forever across retries.
    if (this.qi > 0) {
      this.queue = [];
      this.qi = 0;
    }
    return null;
  }

  hasPending() {
    return this.front.length > 0 || this.qi < this.queue.length;
  }

  pump() {
    if (this.state !== 'running') return;
    for (;;) {
      while (this.active.size < this.options.concurrency) {
        const task = this.nextPending();
        if (!task) break;
        this.runTask(task);
      }
      if (this.active.size === 0 && !this.hasPending()) {
        if (this.deferred.length) {
          for (const t of this.deferred) this.queue.push(t);
          this.deferred = [];
          continue;
        }
        this.finishRun();
      }
      return;
    }
  }

  async retry(fn, { signal, onRetry, retryIf = (err) => err?.retryable } = {}) {
    let attempt = 0;
    for (;;) {
      attempt++;
      try {
        return await fn();
      } catch (err) {
        if (err?.aborted || signal?.aborted) throw err;
        if (!retryIf(err) || attempt >= this.options.maxAttempts) throw err;
        if (!navigator.onLine) {
          onRetry?.(err, attempt, 0, true);
          await waitForOnline(signal);
        }
        const base = Math.min(60000, this.options.retryBaseMs * 2 ** (attempt - 1));
        const delay = Math.round(base * (0.75 + Math.random() * 0.5));
        onRetry?.(err, attempt, delay, false);
        await sleep(delay, signal);
      }
    }
  }

  /** Make sure a folder exists on the NAS; resolves to {created}. */
  prepareDir(dir) {
    dir = normalizePath(dir);
    let p = this.dirMemo.get(dir);
    if (!p) {
      p = this._prepareDir(dir);
      this.dirMemo.set(dir, p);
      p.catch(() => {
        if (this.dirMemo.get(dir) === p) this.dirMemo.delete(dir);
      });
    }
    return p;
  }

  async _prepareDir(dir) {
    const signal = this.session.signal;
    if (dir === '/' || this.knownDirs.has(dir)) return { created: false };
    const parentDir = parentPath(dir);
    const parent = await this.prepareDir(parentDir);
    if (!parent.created) {
      // If we know (or are going to fetch anyway) what the parent holds, skip asking to create existing folders.
      const listing = this.knownListings.get(parentDir) || (this.options.skipExisting ? await this.listDir(parentDir) : null);
      const e = listing?.get(baseName(dir));
      if (e && !e.isDir) throw new WebDAVError(`A file named "${baseName(dir)}" already exists on the NAS where a folder is needed`);
      if (e) return { created: false };
    }
    const r = await this.retry(() => this.client.mkdir(dir, { signal }), { signal });
    if (r === 'created') {
      this.createdDirs.add(dir);
      return { created: true };
    }
    return { created: false };
  }

  /** Children of a NAS folder (memoised; folders created in this session are known to be empty). */
  listDir(dir) {
    dir = normalizePath(dir);
    if (this.knownListings.has(dir)) return Promise.resolve(this.knownListings.get(dir));
    if (this.createdDirs.has(dir)) return Promise.resolve(new Map());
    let p = this.listMemo.get(dir);
    if (!p) {
      const signal = this.session.signal;
      p = this.retry(() => this.client.list(dir, { signal }), { signal }).then((entries) => new Map(entries.map((e) => [e.name, e])));
      this.listMemo.set(dir, p);
      p.catch(() => {
        if (this.listMemo.get(dir) === p) this.listMemo.delete(dir);
      });
    }
    return p;
  }

  uploadTask(task, signal) {
    return this.retry(
      () => {
        task.loaded = 0;
        return this.client.upload(task.destPath, task.file, {
          signal,
          onProgress: (loaded) => {
            const delta = loaded - task.loaded;
            if (delta > 0) this.sentBytes += delta;
            task.loaded = loaded;
          },
        });
      },
      {
        signal,
        onRetry: (err, attempt, delay, offline) => {
          task.note = offline ? 'Waiting for internet connection…' : `Retry ${attempt}/${this.options.maxAttempts - 1} in ${Math.round(delay / 1000)}s — ${err.message}`;
          this.emit();
        },
      },
    );
  }

  async runTask(task) {
    task.status = 'active';
    task.loaded = 0;
    task.note = null;
    task.error = null;
    task.pauseRequested = false;
    task.controller = new AbortController();
    const session = this.session;
    const onSessionAbort = () => task.controller?.abort();
    session.signal.addEventListener('abort', onSessionAbort, { once: true });
    this.active.add(task);
    const signal = task.controller.signal;
    const aborted = () => new WebDAVError('Cancelled', { aborted: true });
    try {
      if (task.kind === 'dir') {
        await this.prepareDir(task.destPath);
        task.status = 'done';
      } else if (task.kind === 'delete') {
        await this.retry(() => this.client.remove(task.destPath, { dir: task.dir, ignoreMissing: true, signal }), { signal });
        task.status = 'done';
      } else if (task.kind === 'move') {
        await this.prepareDir(task.destDir);
        if (signal.aborted) throw aborted();
        try {
          // A refused move (e.g. 502 "Destination refers to a different scheme" behind a proxy) won't succeed on
          // retry; only connection trouble and "busy" answers are worth retrying before falling back.
          await this.retry(() => this.client.move(task.from, task.destPath, { signal }), {
            signal,
            retryIf: (e) => e?.status === 0 || e?.status === 503 || e?.status === 429,
          });
        } catch (err) {
          if (err?.aborted || signal.aborted || err?.status === 0) throw err;
          // The NAS refused the server-side move (some do behind proxies): send the file instead, then remove
          // the old copy along with the other deletions.
          task.fellBack = true;
          task.size = task.file.size;
          task.note = 'The NAS could not move it, uploading instead…';
          this.emit();
          await this.uploadTask(task, signal);
          const old = this.newTask({
            kind: 'delete',
            dir: false,
            rel: task.mirrorFrom || task.from,
            name: baseName(task.from),
            destPath: task.from,
            destDir: parentPath(task.from),
            batch: task.batch,
            mirrorRel: task.mirrorFrom,
            count: 1,
          });
          task.batch?.tasks.push(old);
          this.deferred.push(old);
        }
        task.status = 'done';
      } else {
        const dirInfo = await this.prepareDir(task.destDir);
        if (signal.aborted) throw aborted();
        if (!task.force && this.options.skipExisting) {
          const listing = dirInfo.created ? null : await this.listDir(task.destDir);
          const existing = listing?.get(task.name);
          if (existing && existing.isDir) throw new WebDAVError(`A folder named "${task.name}" already exists on the NAS where this file should go`);
          if (existing && existing.size === task.size && remoteIsUpToDate(existing.modified, task.file.lastModified)) {
            task.status = 'skipped';
            return;
          }
        }
        await this.uploadTask(task, signal);
        task.status = 'done';
        task.verified = false;
      }
    } catch (err) {
      if (task.pauseRequested) {
        task.status = 'pending';
        this.front.push(task);
      } else if (session.signal.aborted) {
        task.status = 'cancelled';
      } else if (err?.retryable && err.status === 0 && (task.netRounds = (task.netRounds || 0) + 1) < 3) {
        // The NAS stayed unreachable through every retry. Don't burn through the whole queue marking files as
        // failed: put this one at the back, pause, and try again automatically in a minute.
        task.status = 'pending';
        if (task.kind === 'delete') this.deferred.push(task);
        else this.queue.push(task);
        this.connectionLost(err);
      } else {
        task.status = 'failed';
        task.error = err?.message || String(err);
      }
    } finally {
      session.signal.removeEventListener('abort', onSessionAbort);
      task.loaded = 0;
      task.controller = null;
      task.note = null;
      // Release the File reference once it is safely on the NAS.
      if (task.status === 'done' && !this.options.verify) task.file = null;
      this.active.delete(task);
      this.emit();
      this.pump();
    }
  }

  async finishRun() {
    if (this.state !== 'running' || this.verifying) return;
    if (this.options.verify) {
      const toVerify = this.tasks.filter((t) => (t.kind === 'file' || t.kind === 'move') && t.status === 'done' && !t.verified);
      if (toVerify.length) {
        this.verifying = true;
        this.setState('verifying');
        try {
          await this.verify(toVerify);
        } finally {
          this.verifying = false;
        }
        if (this.state === 'verifying') this.setState('running');
        else if (this.state !== 'running') return; // cancelled meanwhile
        // More files may have been dropped while verifying; pump() finishes the run once everything is idle.
        this.pump();
        return;
      }
    }
    this.finishedAt = Date.now();
    this.setState('done');
    this.settled();
  }

  /** Tell listeners (mirror bookkeeping) that a run has ended, successfully or not. */
  settled() {
    this.dispatchEvent(new CustomEvent('settled', { detail: { batches: this.batches.slice() } }));
  }

  /** Re-list every folder we wrote into and confirm each file is there with the right size. */
  async verify(tasks) {
    const byDir = new Map();
    for (const t of tasks) {
      if (!byDir.has(t.destDir)) byDir.set(t.destDir, []);
      byDir.get(t.destDir).push(t);
    }
    const dirs = [...byDir.keys()];
    this.verifyProgress = { done: 0, total: dirs.length };
    const signal = this.session.signal;
    let i = 0;
    const worker = async () => {
      while (i < dirs.length && !signal.aborted) {
        const dir = dirs[i++];
        const group = byDir.get(dir);
        try {
          const entries = await this.retry(() => this.client.list(dir, { signal }), { signal });
          const map = new Map(entries.map((e) => [e.name, e]));
          for (const t of group) {
            const e = map.get(t.name);
            const expected = t.expectSize ?? t.size;
            if (!e || e.isDir) {
              t.status = 'failed';
              t.error = 'Verification failed: file is missing on the NAS afterwards';
            } else if (e.size !== null && e.size !== expected) {
              t.status = 'failed';
              t.error = `Verification failed: NAS has ${e.size} bytes, expected ${expected}`;
            } else {
              t.verified = true;
              t.file = null;
            }
          }
        } catch (err) {
          if (signal.aborted) return;
          for (const t of group) {
            t.status = 'failed';
            t.error = 'Could not verify: ' + (err?.message || err);
          }
        }
        this.verifyProgress.done++;
        this.emit();
      }
    };
    await Promise.all(Array.from({ length: Math.min(4, dirs.length) }, worker));
  }

  connectionLost(err) {
    if (this.state !== 'running') return;
    const delay = this.options.autoResumeMs;
    this.connectionIssue = { message: err?.message || String(err), resumeAt: Date.now() + delay };
    this.setState('paused');
    clearTimeout(this.autoResumeTimer);
    this.autoResumeTimer = setTimeout(() => {
      if (this.state === 'paused' && this.connectionIssue) this.resume();
    }, delay);
  }

  clearConnectionIssue() {
    clearTimeout(this.autoResumeTimer);
    this.autoResumeTimer = null;
    if (this.connectionIssue) {
      this.connectionIssue = null;
      this.emit();
    }
  }

  // ---- user controls -----------------------------------------------------

  pause() {
    if (this.state !== 'running') return;
    this.clearConnectionIssue();
    this.setState('paused');
    for (const t of this.active) {
      if (t.kind === 'file' || (t.kind === 'move' && t.fellBack)) {
        t.pauseRequested = true;
        t.controller?.abort();
      }
    }
  }

  resume() {
    if (this.state !== 'paused') return;
    this.clearConnectionIssue();
    this.setState('running');
    this.pump();
  }

  cancel() {
    if (!this.busy) return;
    this.clearConnectionIssue();
    this.session.abort();
    for (const t of this.tasks) if (t.status === 'pending') t.status = 'cancelled';
    this.front = [];
    this.queue = [];
    this.qi = 0;
    this.deferred = [];
    this.finishedAt = Date.now();
    this.setState('cancelled');
    this.session = new AbortController();
    this.dirMemo.clear();
    this.listMemo.clear();
    this.settled();
  }

  retryFailed() {
    const failed = this.tasks.filter((t) => t.status === 'failed' || t.status === 'cancelled');
    if (!failed.length) return;
    if (!this.busy) {
      this.session = new AbortController();
      this.dirMemo.clear();
      this.listMemo.clear();
      this.sentBytes = 0;
      this.samples = [];
      this.startedAt = Date.now();
    }
    for (const t of failed) {
      if ((t.kind === 'file' || t.kind === 'move') && !t.file) continue;
      t.status = 'pending';
      t.error = null;
      t.verified = false;
      if (t.kind === 'delete') this.deferred.push(t);
      else this.queue.push(t);
    }
    this.start();
  }

  clearFinished() {
    if (this.busy) return;
    this.reset();
    this.setState('idle');
  }

  // ---- reporting -----------------------------------------------------------

  stats() {
    const s = {
      state: this.state,
      files: 0,
      dirs: 0,
      totalBytes: 0,
      doneFiles: 0,
      doneBytes: 0,
      uploadedFiles: 0,
      uploadedBytes: 0,
      skippedFiles: 0,
      skippedBytes: 0,
      failedFiles: 0,
      cancelledFiles: 0,
      verifiedFiles: 0,
      inflightBytes: 0,
      pendingFiles: 0,
      dirsDone: 0,
      dirsFailed: 0,
      moves: 0,
      movesDone: 0,
      movesFellBack: 0,
      deletes: 0,
      deletesDone: 0,
      deletedFiles: 0,
      opsFailed: 0,
      opsPending: 0,
    };
    for (const t of this.tasks) {
      if (t.kind === 'dir') {
        s.dirs++;
        if (t.status === 'done') s.dirsDone++;
        if (t.status === 'failed') s.dirsFailed++;
        continue;
      }
      if (t.kind === 'delete' || t.kind === 'move') {
        const isMove = t.kind === 'move';
        if (isMove) s.moves++;
        else s.deletes++;
        if (t.status === 'done') {
          if (isMove) {
            s.movesDone++;
            if (t.fellBack) s.movesFellBack++;
            if (t.verified) s.verifiedFiles++;
          } else {
            s.deletesDone++;
            s.deletedFiles += t.count || 1;
          }
        } else if (t.status === 'failed') s.opsFailed++;
        else if (t.status === 'cancelled') s.cancelledFiles++;
        else s.opsPending++;
        if (isMove && t.fellBack) {
          s.totalBytes += t.size;
          if (t.status === 'done') s.doneBytes += t.size;
          if (t.status === 'active') s.inflightBytes += t.loaded;
        }
        continue;
      }
      s.files++;
      s.totalBytes += t.size;
      switch (t.status) {
        case 'done':
          s.doneFiles++;
          s.uploadedFiles++;
          s.doneBytes += t.size;
          s.uploadedBytes += t.size;
          if (t.verified) s.verifiedFiles++;
          break;
        case 'skipped':
          s.doneFiles++;
          s.skippedFiles++;
          s.doneBytes += t.size;
          s.skippedBytes += t.size;
          break;
        case 'failed':
          s.failedFiles++;
          break;
        case 'cancelled':
          s.cancelledFiles++;
          break;
        case 'active':
          s.inflightBytes += t.loaded;
          break;
        default:
          s.pendingFiles++;
      }
    }
    // Speed over the last ~10 seconds of real network transfer.
    const now = Date.now();
    this.samples.push([now, this.sentBytes]);
    while (this.samples.length > 2 && now - this.samples[0][0] > 10000) this.samples.shift();
    const [t0, b0] = this.samples[0];
    s.speed = now - t0 > 500 ? ((this.sentBytes - b0) * 1000) / (now - t0) : 0;
    const remaining = Math.max(0, s.totalBytes - s.doneBytes - s.inflightBytes);
    s.eta = s.speed > 0 ? remaining / s.speed : Infinity;
    s.elapsed = ((this.finishedAt && !this.busy ? this.finishedAt : now) - (this.startedAt || now)) / 1000;
    s.verifyProgress = this.verifyProgress;
    return s;
  }

  activeTasks() {
    return [...this.active];
  }

  failedTasks() {
    return this.tasks.filter((t) => t.status === 'failed');
  }
}
