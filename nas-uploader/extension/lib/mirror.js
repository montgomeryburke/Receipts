// Mirror: make a NAS folder match a local folder, sending only what changed.
//
// A small manifest (.nas-uploader-mirror.json) in the NAS folder records the size and modification time each
// file had on the local computer when it was last sent. Next time, a file is re-sent only if that changed, which
// is the same quick check rsync uses. Without a manifest (first mirror of an existing folder) a NAS file counts
// as up to date when it has the same size and was written after the local file was last modified.

import { joinPath, parentPath, baseName, isJunkFile, isJunkDir, sleep } from './util.js';

export const MANIFEST_NAME = '.nas-uploader-mirror.json';

// Renames/moves are only detected for files at least this big (small files are cheap to re-send, and size+time
// collisions between different small files are more likely).
export const MIN_MOVE_SIZE = 256 * 1024;

// Artwork and metadata that Jellyfin / Kodi / Plex / Emby write next to media files, and NAS system folders.
// A mirror never deletes these when they only exist on the NAS.
const META_FILE_RE =
  /^(?:.*\.nfo|.*\.bif|.*\.(?:srt|ass|ssa|sub|idx|vtt|sup|lrc)|theme\.(?:mp3|flac|ogg|wav)|(?:poster|folder|fanart|backdrop\d*|banner|logo|clearlogo|clearart|landscape|thumb|disc|discart|cover|keyart|season\d*-(?:poster|banner|landscape|fanart)|season-(?:specials|all)-(?:poster|banner|landscape|fanart))\.(?:jpe?g|png|webp|gif|tbn)|.+-(?:poster|fanart|thumb|landscape|banner|logo|clearlogo|clearart|disc|backdrop)\.(?:jpe?g|png|webp|gif|tbn))$/i;
const META_DIR_RE = /^(?:metadata|\.actors|extrafanart|extrathumbs|.*\.trickplay|@eadir|#recycle|\.recycle|\.snapshots?|lost\+found)$/i;
const SERVER_TEMP_RE = /^\.davfs\.tmp/;

export function isProtectedName(name, isDir) {
  return isDir ? META_DIR_RE.test(name) : META_FILE_RE.test(name);
}

const nfc = (s) => s.normalize('NFC');

async function withRetry(fn, signal, attempts = 4) {
  for (let i = 1; ; i++) {
    try {
      return await fn();
    } catch (err) {
      if (err?.aborted || signal?.aborted || !err?.retryable || i >= attempts) throw err;
      await sleep(1000 * 2 ** (i - 1), signal);
    }
  }
}

/**
 * Recursively list a NAS folder. Paths in the result are relative to root.
 * Keys are NFC-normalised relative paths; `listed` marks folders whose contents were read.
 * @returns {Promise<{exists: boolean, files: Map<string, {rel: string, size: number|null, modified: Date|null}>, dirs: Map<string, {rel: string, listed?: boolean}>}>}
 */
export async function listRemoteTree(client, root, { signal, onProgress, shouldDescend = () => true, concurrency = 6 } = {}) {
  const files = new Map();
  const dirs = new Map();
  const rootInfo = await withRetry(() => client.stat(root, { signal, dir: true }), signal);
  if (!rootInfo) return { exists: false, files, dirs };
  if (!rootInfo.isDir) throw new Error(`"${root}" on the NAS is a file, not a folder`);
  const queue = [''];
  let active = 0;
  let listed = 0;
  let failure = null;
  await new Promise((resolve) => {
    const next = () => {
      if (failure || signal?.aborted) {
        if (active === 0) resolve();
        return;
      }
      while (active < concurrency && queue.length) {
        const rel = queue.shift();
        active++;
        withRetry(() => client.list(joinPath(root, rel), { signal }), signal)
          .then((entries) => {
            if (rel) dirs.get(nfc(rel)).listed = true;
            for (const e of entries) {
              const childRel = rel ? rel + '/' + e.name : e.name;
              const key = nfc(childRel);
              if (e.isDir) {
                dirs.set(key, { rel: childRel });
                if (shouldDescend(childRel, e.name)) queue.push(childRel);
              } else {
                files.set(key, { rel: childRel, size: e.size, modified: e.modified });
              }
            }
            listed++;
            onProgress?.({ folders: listed, files: files.size });
          })
          .catch((err) => {
            failure = failure || err;
          })
          .finally(() => {
            active--;
            next();
          });
      }
      if (active === 0 && !queue.length) resolve();
    };
    next();
  });
  if (signal?.aborted) throw new DOMException('Cancelled', 'AbortError');
  if (failure) throw failure;
  return { exists: true, files, dirs };
}

export async function readManifest(client, root, { signal } = {}) {
  let text;
  try {
    text = await withRetry(() => client.getText(joinPath(root, MANIFEST_NAME), { signal }), signal);
  } catch (err) {
    if (err.status === 404) return null;
    throw err;
  }
  if (!text) return null;
  try {
    const m = JSON.parse(text);
    return m && m.version === 1 && m.files && typeof m.files === 'object' ? m : null;
  } catch {
    return null; // a damaged manifest only costs a slower first sync
  }
}

export function writeManifest(client, root, manifest, opts) {
  return client.putText(joinPath(root, MANIFEST_NAME), JSON.stringify(manifest), opts);
}

/**
 * Work out what to do to make the NAS folder match the local folder.
 * @param {object} p
 * @param {{files: {rel: string, file: File}[], dirs: string[]}} p.local paths relative to the mirrored folder
 * @param {{exists: boolean, files: Map, dirs: Map}} p.remote from listRemoteTree
 * @param {object|null} p.manifest from readManifest
 * @param {{deletions?: boolean, protectMetadata?: boolean, detectMoves?: boolean, skipJunk?: boolean, localKnowsEmptyDirs?: boolean}} [p.options]
 */
export function planMirror({ local, remote, manifest, options = {} }) {
  const { deletions = true, protectMetadata = true, detectMoves = true, skipJunk = true, localKnowsEmptyDirs = true } = options;
  const mfiles = manifest?.files || {};

  const localFiles = new Map();
  for (const f of local.files) localFiles.set(nfc(f.rel), f);
  const localDirs = new Set(local.dirs.map(nfc));
  for (const key of localFiles.keys()) for (let d = parentPath('/' + key).slice(1); d; d = parentPath('/' + d).slice(1)) localDirs.add(d);

  // Anything that couldn't be read locally (locked, no permission) is left alone on the NAS, never deleted.
  const unreadable = (local.errors || []).map((e) => nfc(e.rel).replace(/^\.\/?/, '').replace(/\/+$/, ''));
  const unreadableAll = unreadable.includes('');
  const isUnreadable = (key) => unreadableAll || unreadable.some((u) => key === u || key.startsWith(u + '/'));

  // Ignore things on the NAS that a mirror must never touch.
  const ignoredRemote = (key, isDir) => {
    const name = baseName('/' + key);
    if (!isDir && key === MANIFEST_NAME) return true;
    if (!isDir && SERVER_TEMP_RE.test(name)) return true;
    if (skipJunk && (isDir ? isJunkDir(name) : isJunkFile(name))) return true;
    return false;
  };
  const remoteFiles = new Map([...remote.files].filter(([k]) => !ignoredRemote(k, false)));
  const remoteDirs = new Map([...remote.dirs].filter(([k]) => !ignoredRemote(k, true)));

  const plan = {
    uploads: [], // {rel, file, reason: 'new'|'changed'}
    moves: [], // {from, to, file} (remote paths, relative)
    deletes: [], // {rel, size}
    deleteDirs: [], // {rel, files, bytes}
    createDirs: [], // rel of local folders missing on the NAS
    unchanged: [], // {key, file}
    keptProtected: 0,
    conflicts: [], // {rel, message}
    warnings: [],
    remoteFileCount: remoteFiles.size,
  };

  const newFiles = [];
  for (const [key, lf] of localFiles) {
    if (remoteDirs.has(key)) {
      plan.conflicts.push({ rel: lf.rel, message: 'There is a folder with this name on the NAS' });
      continue;
    }
    const r = remoteFiles.get(key);
    if (!r) {
      newFiles.push({ key, lf });
      continue;
    }
    const size = lf.file.size;
    const mtime = lf.file.lastModified;
    const m = mfiles[key];
    let same;
    if (m) same = m.size === size && m.mtime === mtime && r.size === size;
    else same = r.size === size && (!r.modified || isNaN(r.modified) || r.modified.getTime() >= Math.floor(mtime / 1000) * 1000);
    if (same) plan.unchanged.push({ key, file: lf.file });
    else plan.uploads.push({ rel: lf.rel, file: lf.file, reason: 'changed' });
  }

  const remoteOnly = [...remoteFiles].filter(([k]) => !localFiles.has(k));

  // Renames / moves: a new local file whose size and modification time match exactly one NAS file that is gone
  // locally (as recorded in the manifest) is moved on the NAS instead of uploaded again.
  const movedFrom = new Set();
  if (detectMoves && manifest) {
    const bySig = new Map();
    for (const [k, r] of remoteOnly) {
      const m = mfiles[k];
      if (!m || m.size !== r.size || r.size < MIN_MOVE_SIZE) continue;
      const sig = `${m.size}:${m.mtime}`;
      if (!bySig.has(sig)) bySig.set(sig, []);
      bySig.get(sig).push(k);
    }
    const localBySig = new Map();
    for (const nf of newFiles) {
      if (nf.lf.file.size < MIN_MOVE_SIZE) continue;
      const sig = `${nf.lf.file.size}:${nf.lf.file.lastModified}`;
      localBySig.set(sig, (localBySig.get(sig) || 0) + 1);
    }
    for (let i = newFiles.length - 1; i >= 0; i--) {
      const { lf } = newFiles[i];
      const sig = `${lf.file.size}:${lf.file.lastModified}`;
      const cands = bySig.get(sig);
      if (!cands || cands.length !== 1 || localBySig.get(sig) !== 1) continue;
      const fromKey = cands[0];
      plan.moves.push({ from: remoteFiles.get(fromKey).rel, to: lf.rel, file: lf.file, fromKey });
      movedFrom.add(fromKey);
      newFiles.splice(i, 1);
    }
    plan.moves.reverse();
  }
  for (const { lf } of newFiles) plan.uploads.push({ rel: lf.rel, file: lf.file, reason: 'new' });

  const dirOriginal = new Map(local.dirs.map((d) => [nfc(d), d]));
  for (const d of localDirs) if (!remoteDirs.has(d)) plan.createDirs.push(dirOriginal.get(d) || d);

  if (deletions) {
    // Whole folders that are gone locally: delete only the top-most one (DELETE is recursive).
    // Files that are being moved out don't count as deleted with their old folder (moves run before deletions).
    const dirFileCount = new Map();
    const dirBytes = new Map();
    for (const [k, r] of remoteFiles) {
      if (movedFrom.has(k)) continue;
      for (let d = parentPath('/' + k).slice(1); d; d = parentPath('/' + d).slice(1)) {
        dirFileCount.set(d, (dirFileCount.get(d) || 0) + 1);
        dirBytes.set(d, (dirBytes.get(d) || 0) + (r.size || 0));
      }
    }
    const deletedDirKeys = new Set();
    const keptDirKeys = new Set();
    const sortedDirs = [...remoteDirs.keys()].sort((a, b) => a.split('/').length - b.split('/').length);
    for (const k of sortedDirs) {
      if (localDirs.has(k)) continue;
      if (isUnreadable(k)) {
        keptDirKeys.add(k);
        continue;
      }
      const parent = parentPath('/' + k).slice(1);
      if (parent && (deletedDirKeys.has(parent) || keptDirKeys.has(parent) || !localDirs.has(parent))) {
        if (keptDirKeys.has(parent)) keptDirKeys.add(k);
        continue;
      }
      const name = baseName('/' + k);
      const files = dirFileCount.get(k) || 0;
      const hadMoveSource = [...movedFrom].some((f) => f.startsWith(k + '/'));
      if (protectMetadata && isProtectedName(name, true)) {
        keptDirKeys.add(k);
        plan.keptProtected += files;
      } else if (!localKnowsEmptyDirs && files === 0 && !hadMoveSource) {
        keptDirKeys.add(k); // the folder picker can't see empty folders, so don't assume this one is gone
      } else {
        deletedDirKeys.add(k);
        plan.deleteDirs.push({ rel: remoteDirs.get(k).rel, files, bytes: dirBytes.get(k) || 0 });
      }
    }
    const underDeletedDir = (k) => {
      for (let d = parentPath('/' + k).slice(1); d; d = parentPath('/' + d).slice(1)) if (deletedDirKeys.has(d)) return true;
      return false;
    };
    const underKeptDir = (k) => {
      for (let d = parentPath('/' + k).slice(1); d; d = parentPath('/' + d).slice(1)) if (keptDirKeys.has(d)) return true;
      return false;
    };
    for (const [k, r] of remoteOnly) {
      if (movedFrom.has(k) || underDeletedDir(k) || underKeptDir(k)) continue; // kept folders were counted above
      if (isUnreadable(k)) continue;
      const inProtectedDir = (() => {
        for (let d = parentPath('/' + k).slice(1); d; d = parentPath('/' + d).slice(1)) if (isProtectedName(baseName('/' + d), true)) return true;
        return false;
      })();
      if (protectMetadata && (isProtectedName(baseName('/' + k), false) || inProtectedDir)) {
        plan.keptProtected++;
        continue;
      }
      plan.deletes.push({ rel: r.rel, size: r.size || 0 });
    }
  } else {
    plan.keptOnNas = remoteOnly.length - movedFrom.size;
  }

  // Safety checks shown prominently before anything is deleted.
  const deletingFiles = plan.deletes.length + plan.deleteDirs.reduce((n, d) => n + d.files, 0);
  plan.deletingFiles = deletingFiles;
  if (deletingFiles > 0 && local.files.length === 0) {
    plan.warnings.push('Your local folder looks empty, but the NAS copy has files. Mirroring would delete everything on the NAS. Make sure you picked the right folder.');
  } else if (deletingFiles >= 20 && deletingFiles > plan.remoteFileCount / 2) {
    plan.warnings.push(`This would delete ${deletingFiles} of the ${plan.remoteFileCount} files in the NAS copy. Make sure you picked the right folder.`);
  }
  plan.nothingToDo = !plan.uploads.length && !plan.moves.length && !plan.deletes.length && !plan.deleteDirs.length && !plan.createDirs.length && !plan.conflicts.length;
  plan.uploadBytes = plan.uploads.reduce((n, u) => n + u.file.size, 0);
  return plan;
}

/** The manifest to store after a run: what the NAS copy now holds, in terms of local size + modification time. */
export function buildManifest({ previous, plan, remote, tasks, sourceName }) {
  const files = {};
  const prev = previous?.files || {};
  // Start from previous entries for NAS files that still exist (failed uploads/deletes leave them accurate).
  for (const key of remote.files.keys()) if (prev[key]) files[key] = prev[key];
  for (const u of plan.unchanged) files[u.key] = { size: u.file.size, mtime: u.file.lastModified };
  for (const t of tasks) {
    if (t.status !== 'done' || !t.mirrorRel) continue;
    if (t.kind === 'delete') {
      const key = nfc(t.mirrorRel);
      if (t.dir) {
        for (const k of Object.keys(files)) if (k === key || k.startsWith(key + '/')) delete files[k];
      } else delete files[key];
    } else if ((t.kind === 'file' || t.kind === 'move') && t.mirrorRel && t.localMtime !== undefined) {
      if (t.kind === 'move' && t.mirrorFrom) delete files[nfc(t.mirrorFrom)];
      files[nfc(t.mirrorRel)] = { size: t.localSize, mtime: t.localMtime };
    }
  }
  return { version: 1, updated: new Date().toISOString(), source: sourceName || '', files };
}
