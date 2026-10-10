// Upload queue: parallel uploads, retries with back-off, pause/resume/cancel, skip-existing (resume) and verification.

import { WebDAVError } from './webdav.js';
import { joinPath, parentPath, baseName, normalizePath, sleep, waitForOnline } from './util.js';

let nextId = 1;

export class TransferManager extends EventTarget {
  /**
   * @param {import('./webdav.js').WebDAVClient} client
   * @param {{concurrency?: number, skipExisting?: boolean, verify?: boolean, maxAttempts?: number, retryBaseMs?: number}} options
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
    this.active = new Set();
    this.dirMemo = new Map();
    this.knownDirs = new Set();
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

  /**
   * Queue a scanned batch for upload into destRoot.
   * @param {{files: {rel: string, file: File}[], dirs: string[]}} scan
   * @param {string} destRoot existing folder on the NAS
   */
  addBatch(scan, destRoot) {
    if (!this.busy) {
      // Start a fresh session, but keep earlier failures visible until the user clears them.
      const keep = this.tasks.filter((t) => t.status === 'failed');
      this.reset();
      for (const t of keep) this.tasks.push(t);
      this.startedAt = Date.now();
    }
    destRoot = normalizePath(destRoot);
    this.knownDirs.add(destRoot);

    const fileDirs = new Set();
    for (const { rel, file } of scan.files) {
      const destPath = joinPath(destRoot, rel);
      const task = {
        id: nextId++,
        kind: 'file',
        rel,
        name: baseName(destPath),
        destPath,
        destDir: parentPath(destPath),
        file,
        size: file.size,
        status: 'pending',
        loaded: 0,
        error: null,
        note: null,
        verified: false,
      };
      this.tasks.push(task);
      this.queue.push(task);
      for (let d = task.destDir; d !== '/' && !fileDirs.has(d); d = parentPath(d)) fileDirs.add(d);
    }
    // Folders with no files inside them still need to exist on the NAS.
    for (const rel of scan.dirs) {
      const destPath = joinPath(destRoot, rel);
      if (fileDirs.has(destPath)) continue;
      const task = { id: nextId++, kind: 'dir', rel: rel + '/', name: baseName(destPath), destPath, destDir: parentPath(destPath), size: 0, status: 'pending', loaded: 0, error: null, note: null };
      this.tasks.push(task);
      this.queue.push(task);
    }
    if (this.state !== 'paused') this.setState('running');
    this.emit();
    this.pump();
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
    // Compact the queue occasionally so it doesn't grow forever across retries.
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
    while (this.active.size < this.options.concurrency) {
      const task = this.nextPending();
      if (!task) break;
      this.runTask(task);
    }
    if (this.active.size === 0 && !this.hasPending()) this.finishRun();
  }

  async retry(fn, { signal, onRetry } = {}) {
    let attempt = 0;
    for (;;) {
      attempt++;
      try {
        return await fn();
      } catch (err) {
        if (err?.aborted || signal?.aborted) throw err;
        if (!err?.retryable || attempt >= this.options.maxAttempts) throw err;
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

  /** Make sure a folder exists; returns {created, listing} where listing maps child name -> entry (if known). */
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
    let exists;
    if (dir === '/' || this.knownDirs.has(dir)) {
      exists = true;
    } else {
      const parent = await this.prepareDir(parentPath(dir));
      if (parent.created) exists = false;
      else if (parent.listing) {
        const e = parent.listing.get(baseName(dir));
        if (e && !e.isDir) throw new WebDAVError(`A file named "${baseName(dir)}" already exists on the NAS where a folder is needed`);
        exists = !!e;
      }
    }
    if (exists !== true) {
      const r = await this.retry(() => this.client.mkdir(dir, { signal }), { signal });
      if (r === 'created') return { created: true, listing: new Map() };
    }
    if (!this.options.skipExisting) return { created: false, listing: null };
    const entries = await this.retry(() => this.client.list(dir, { signal }), { signal });
    return { created: false, listing: new Map(entries.map((e) => [e.name, e])) };
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
    try {
      if (task.kind === 'dir') {
        await this.prepareDir(task.destPath);
        task.status = 'done';
        return;
      }
      const dirInfo = await this.prepareDir(task.destDir);
      if (signal.aborted) throw new WebDAVError('Cancelled', { aborted: true });
      if (this.options.skipExisting && dirInfo.listing) {
        const existing = dirInfo.listing.get(task.name);
        if (existing && !existing.isDir && existing.size === task.size) {
          task.status = 'skipped';
          return;
        }
        if (existing && existing.isDir) throw new WebDAVError(`A folder named "${task.name}" already exists on the NAS where this file should go`);
      }
      await this.retry(
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
      task.status = 'done';
      task.verified = false;
    } catch (err) {
      if (task.pauseRequested) {
        task.status = 'pending';
        this.front.push(task);
      } else if (session.signal.aborted) {
        task.status = 'cancelled';
      } else if (err?.retryable && err.status === 0 && (task.netRounds = (task.netRounds || 0) + 1) < 3) {
        // The NAS stayed unreachable through every retry. Don't burn through the whole queue marking files as
        // failed: put this file at the back, pause, and try again automatically in a minute.
        task.status = 'pending';
        this.queue.push(task);
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
      const toVerify = this.tasks.filter((t) => t.kind === 'file' && t.status === 'done' && !t.verified);
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
  }

  /** Re-list every folder we uploaded into and confirm each file is there with the right size. */
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
            if (!e || e.isDir) {
              t.status = 'failed';
              t.error = 'Verification failed: file is missing on the NAS after upload';
            } else if (e.size !== null && e.size !== t.size) {
              t.status = 'failed';
              t.error = `Verification failed: NAS has ${e.size} bytes, expected ${t.size}`;
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
      if (t.kind === 'file') {
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
    this.finishedAt = Date.now();
    this.setState('cancelled');
    this.session = new AbortController();
    this.dirMemo.clear();
  }

  retryFailed() {
    const failed = this.tasks.filter((t) => t.status === 'failed' || t.status === 'cancelled');
    if (!failed.length) return;
    if (!this.busy) {
      this.session = new AbortController();
      this.dirMemo.clear();
      this.sentBytes = 0;
      this.samples = [];
      this.startedAt = Date.now();
    }
    for (const t of failed) {
      if (t.kind === 'file' && !t.file) continue;
      t.status = 'pending';
      t.error = null;
      t.verified = false;
      this.queue.push(t);
    }
    if (this.state !== 'paused') this.setState('running');
    this.pump();
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
    };
    for (const t of this.tasks) {
      if (t.kind === 'dir') {
        s.dirs++;
        if (t.status === 'done') s.dirsDone++;
        if (t.status === 'failed') s.dirsFailed++;
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
