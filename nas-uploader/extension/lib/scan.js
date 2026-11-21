// Turn dropped folders / picked files into a flat list of {rel, file} plus every folder path.

import { isJunkDir, isJunkFile } from './util.js';

/**
 * Must be called synchronously inside the drop event: DataTransfer items are only valid until the handler returns.
 */
export function captureDrop(dataTransfer) {
  const entries = [];
  const looseFiles = [];
  const handlePromises = []; // FileSystemHandles, so a dropped folder can be remembered for one-click mirroring
  const items = dataTransfer.items ? Array.from(dataTransfer.items) : [];
  if (items.length) {
    for (const item of items) {
      if (item.kind !== 'file') continue;
      if (typeof item.getAsFileSystemHandle === 'function') {
        try {
          const p = item.getAsFileSystemHandle();
          p.catch(() => {});
          handlePromises.push(p);
        } catch {}
      }
      const entry = typeof item.webkitGetAsEntry === 'function' ? item.webkitGetAsEntry() : null;
      if (entry) entries.push(entry);
      else {
        const f = item.getAsFile();
        if (f) looseFiles.push(f);
      }
    }
  } else if (dataTransfer.files) {
    looseFiles.push(...Array.from(dataTransfer.files));
  }
  return { entries, looseFiles, handlePromises };
}

function readBatch(reader) {
  return new Promise((resolve, reject) => reader.readEntries(resolve, reject));
}

async function readAllChildren(dirEntry) {
  const reader = dirEntry.createReader();
  const all = [];
  // readEntries returns at most ~100 entries per call; keep asking until it returns an empty batch.
  for (;;) {
    const batch = await readBatch(reader);
    if (!batch.length) break;
    all.push(...batch);
  }
  return all;
}

function entryFile(fileEntry) {
  return new Promise((resolve, reject) => fileEntry.file(resolve, reject));
}

function errMsg(err) {
  return (err && (err.message || err.name)) || String(err);
}

function newResult() {
  return { files: [], dirs: [], errors: [], skippedJunk: 0, totalBytes: 0 };
}

/**
 * Walk dropped entries (folders are walked recursively, empty folders are kept).
 * @returns {Promise<{files: {rel: string, file: File}[], dirs: string[], errors: {rel: string, message: string}[], skippedJunk: number, totalBytes: number}>}
 */
export async function scanEntries({ entries, looseFiles }, { skipJunk = true, onProgress, signal } = {}) {
  const out = newResult();
  let lastReport = 0;
  const report = (force) => {
    const now = Date.now();
    if (onProgress && (force || now - lastReport > 200)) {
      lastReport = now;
      onProgress({ files: out.files.length, dirs: out.dirs.length, bytes: out.totalBytes });
    }
  };
  const addFile = (rel, file) => {
    out.files.push({ rel, file });
    out.totalBytes += file.size;
  };

  for (const f of looseFiles || []) {
    if (skipJunk && isJunkFile(f.name)) out.skippedJunk++;
    else addFile(f.name, f);
  }

  // Depth-first walk with an explicit stack so very deep trees can't overflow the call stack.
  const stack = [...(entries || [])].reverse().map((entry) => ({ entry, prefix: '' }));
  while (stack.length) {
    if (signal?.aborted) throw new DOMException('Scan cancelled', 'AbortError');
    const { entry, prefix } = stack.pop();
    const rel = prefix + entry.name;
    if (entry.isFile) {
      if (skipJunk && isJunkFile(entry.name)) {
        out.skippedJunk++;
        continue;
      }
      try {
        addFile(rel, await entryFile(entry));
      } catch (err) {
        out.errors.push({ rel, message: 'Could not read file: ' + errMsg(err) });
      }
      report();
      continue;
    }
    if (!entry.isDirectory) continue;
    if (skipJunk && isJunkDir(entry.name)) {
      out.skippedJunk++;
      continue;
    }
    out.dirs.push(rel);
    let children;
    try {
      children = await readAllChildren(entry);
    } catch (err) {
      out.errors.push({ rel: rel + '/', message: 'Could not read folder: ' + errMsg(err) });
      continue;
    }
    children.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
    const fileChildren = children.filter((c) => c.isFile && !(skipJunk && isJunkFile(c.name)));
    out.skippedJunk += children.filter((c) => c.isFile && skipJunk && isJunkFile(c.name)).length;
    // Resolve File objects in parallel chunks; much faster than one at a time on big folders.
    for (let i = 0; i < fileChildren.length; i += 64) {
      if (signal?.aborted) throw new DOMException('Scan cancelled', 'AbortError');
      const chunk = fileChildren.slice(i, i + 64);
      const results = await Promise.allSettled(chunk.map(entryFile));
      results.forEach((r, j) => {
        const childRel = rel + '/' + chunk[j].name;
        if (r.status === 'fulfilled') addFile(childRel, r.value);
        else out.errors.push({ rel: childRel, message: 'Could not read file: ' + errMsg(r.reason) });
      });
      report();
    }
    const dirChildren = children.filter((c) => c.isDirectory);
    for (let i = dirChildren.length - 1; i >= 0; i--) stack.push({ entry: dirChildren[i], prefix: rel + '/' });
  }
  report(true);
  return out;
}

/** Files from <input type=file> (with or without webkitdirectory). Empty folders are not visible this way. */
export function scanFileList(fileList, { skipJunk = true } = {}) {
  const out = newResult();
  const dirs = new Set();
  outer: for (const file of Array.from(fileList)) {
    const rel = file.webkitRelativePath || file.name;
    const segs = rel.split('/').filter(Boolean);
    if (skipJunk) {
      if (isJunkFile(segs[segs.length - 1])) {
        out.skippedJunk++;
        continue;
      }
      for (const s of segs.slice(0, -1)) {
        if (isJunkDir(s)) {
          out.skippedJunk++;
          continue outer;
        }
      }
    }
    for (let i = 1; i < segs.length; i++) dirs.add(segs.slice(0, i).join('/'));
    out.files.push({ rel: segs.join('/'), file });
    out.totalBytes += file.size;
  }
  out.dirs = [...dirs].sort();
  return out;
}

/**
 * Walk a folder chosen with the folder picker or remembered from an earlier mirror (FileSystemDirectoryHandle).
 * Paths are relative to that folder (its own name is not included). Empty folders are kept.
 */
export async function scanDirectoryHandle(rootHandle, { skipJunk = true, onProgress, signal } = {}) {
  const out = newResult();
  let lastReport = 0;
  const report = (force) => {
    const now = Date.now();
    if (onProgress && (force || now - lastReport > 200)) {
      lastReport = now;
      onProgress({ files: out.files.length, dirs: out.dirs.length, bytes: out.totalBytes });
    }
  };
  const stack = [{ handle: rootHandle, prefix: '' }];
  while (stack.length) {
    if (signal?.aborted) throw new DOMException('Scan cancelled', 'AbortError');
    const { handle, prefix } = stack.pop();
    const children = [];
    try {
      for await (const child of handle.values()) children.push(child);
    } catch (err) {
      out.errors.push({ rel: prefix || './', message: 'Could not read folder: ' + errMsg(err) });
      continue;
    }
    children.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
    const fileChildren = [];
    for (const c of children) {
      if (c.kind !== 'file') continue;
      if (skipJunk && isJunkFile(c.name)) out.skippedJunk++;
      else fileChildren.push(c);
    }
    for (let i = 0; i < fileChildren.length; i += 64) {
      if (signal?.aborted) throw new DOMException('Scan cancelled', 'AbortError');
      const chunk = fileChildren.slice(i, i + 64);
      const results = await Promise.allSettled(chunk.map((c) => c.getFile()));
      results.forEach((r, j) => {
        const rel = prefix + chunk[j].name;
        if (r.status === 'fulfilled') {
          out.files.push({ rel, file: r.value });
          out.totalBytes += r.value.size;
        } else out.errors.push({ rel, message: 'Could not read file: ' + errMsg(r.reason) });
      });
      report();
    }
    const dirChildren = children.filter((c) => c.kind === 'directory');
    for (let i = dirChildren.length - 1; i >= 0; i--) {
      const d = dirChildren[i];
      if (skipJunk && isJunkDir(d.name)) {
        out.skippedJunk++;
        continue;
      }
      out.dirs.push(prefix + d.name);
      stack.push({ handle: d, prefix: prefix + d.name + '/' });
    }
  }
  out.dirs.sort();
  report(true);
  return out;
}

/** Make scan results relative to their single top-level folder ("Photos/2024/a.jpg" -> "2024/a.jpg"). */
export function stripTopFolder(result) {
  const top = result.files[0]?.rel.split('/')[0] ?? result.dirs[0]?.split('/')[0];
  const strip = (p) => p.slice(top.length + 1);
  return {
    ...result,
    top,
    files: result.files.map((f) => ({ ...f, rel: strip(f.rel) })),
    dirs: result.dirs.filter((d) => d !== top).map(strip),
    errors: result.errors.map((e) => ({ ...e, rel: e.rel === top + '/' || e.rel === top ? './' : e.rel.startsWith(top + '/') ? strip(e.rel) : e.rel })),
  };
}

/** The single folder a scan result consists of, or null if it has loose files or several folders. */
export function singleTopFolder(result) {
  const tops = new Set();
  for (const f of result.files) {
    if (!f.rel.includes('/')) return null;
    tops.add(f.rel.split('/')[0]);
  }
  for (const d of result.dirs) tops.add(d.split('/')[0]);
  return tops.size === 1 ? [...tops][0] : null;
}
