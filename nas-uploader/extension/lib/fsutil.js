// Helpers around File System Access handles (local folders, mapped NAS drives,
// and OPFS in tests — they all share one interface).

import { kvGet, kvSet } from './db.js';

export const META_DIR = '.mailmirror';

export async function getRootHandle(which) {
  return (await kvGet(`handle:${which}`)) || null;
}

export async function setRootHandle(which, handle) {
  await kvSet(`handle:${which}`, handle);
}

// 'granted' | 'prompt' | 'denied' | 'missing'
export async function permissionState(handle, mode = 'readwrite') {
  if (!handle) return 'missing';
  if (typeof handle.queryPermission !== 'function') return 'granted'; // OPFS
  try {
    return await handle.queryPermission({ mode });
  } catch {
    return 'prompt';
  }
}

// Must be called from a user gesture (button click) in a visible page.
export async function requestPermission(handle, mode = 'readwrite') {
  if (!handle) return 'missing';
  if (typeof handle.requestPermission !== 'function') return 'granted';
  return handle.requestPermission({ mode });
}

// Walks a directory tree. Yields { path, handle, file } for files that pass
// `skip(path, isDir)`. Unreadable entries are reported via onError and skipped.
export async function* walk(dir, { skip = () => false, onError = () => {}, prefix = '', withFile = true } = {}) {
  let entries;
  try {
    entries = [];
    for await (const entry of dir.values()) entries.push(entry);
  } catch (err) {
    onError(prefix || '/', err);
    return;
  }
  entries.sort((a, b) => a.name.localeCompare(b.name));
  for (const entry of entries) {
    const path = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.kind === 'directory') {
      if (skip(path, true)) continue;
      yield* walk(entry, { skip, onError, prefix: path, withFile });
    } else {
      if (skip(path, false)) continue;
      if (!withFile) { yield { path, handle: entry }; continue; }
      try {
        yield { path, handle: entry, file: await entry.getFile() };
      } catch (err) {
        onError(path, err);
      }
    }
  }
}

export async function getDirByPath(root, dirPath, create = false) {
  let dir = root;
  if (!dirPath) return dir;
  for (const seg of dirPath.split('/')) {
    if (!seg) continue;
    dir = await dir.getDirectoryHandle(seg, { create });
  }
  return dir;
}

export function splitPath(path) {
  const i = path.lastIndexOf('/');
  return i < 0 ? ['', path] : [path.slice(0, i), path.slice(i + 1)];
}

export async function getFileByPath(root, path, create = false) {
  const [dirPath, name] = splitPath(path);
  const dir = await getDirByPath(root, dirPath, create);
  return dir.getFileHandle(name, { create });
}

export async function fileExists(root, path) {
  try {
    await getFileByPath(root, path);
    return true;
  } catch {
    return false;
  }
}

// Streams src (a File/Blob) into root/path, creating folders as needed.
// createWritable writes to a temporary file and swaps it in on close, so a
// failed copy never leaves a half-written destination.
export async function writeFile(root, path, blob) {
  const fh = await getFileByPath(root, path, true);
  const w = await fh.createWritable();
  try {
    await blob.stream().pipeTo(w);
  } catch (err) {
    try { await w.abort(); } catch { /* already closed */ }
    throw err;
  }
  return fh.getFile();
}

export async function removeFile(root, path) {
  const [dirPath, name] = splitPath(path);
  const dir = await getDirByPath(root, dirPath);
  await dir.removeEntry(name);
}

export function stamp(d = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}`;
}
