// Walks the designated project folders and keeps the local index current.
// Incremental: unchanged files (same size and modified time) are skipped.
//
// Each designated folder has a remote path (its location on the NAS). Files
// are indexed under that path, e.g. "2024-017 Alert/Specs/x.pdf", so the OCR
// "deep index" the Pi builds on the NAS lines up with the same files here.
// The deep index can be read from the NAS over HTTPS or from a local folder.

import { getAll, kvGet, kvSet, log } from './db.js';
import { IndexWriter, INDEX_VERSION } from './index.js';
import { chunkText, makeMatcher, splitList, extOf, projectOf } from './text.js';
import { extractFile } from './extract.js';
import { walk, getFileByPath, META_DIR } from './fsutil.js';

const tick = () => new Promise((r) => setTimeout(r, 0));

// roots: a single directory handle, or [{root, prefix, folderId}]. prefix is
// the file path shown in the index (the folder's location on the NAS).
function normalizeRoots(roots) {
  if (Array.isArray(roots)) return roots;
  return [{ root: roots, prefix: '', folderId: 'local' }];
}

export async function runIndex(roots, settings, { onProgress = () => {}, signal, rootName = 'local' } = {}) {
  const started = Date.now();
  const list = normalizeRoots(roots);
  const exclude = makeMatcher(settings.excludePatterns);
  const include = new Set(splitList(settings.includeExt).map((e) => e.replace(/^\./, '').toLowerCase()));
  const maxBytes = (settings.maxFileMB || 150) * 1024 * 1024;
  const existing = new Map((await getAll('files')).map((f) => [f.path, f]));
  const writer = new IndexWriter();
  const seen = new Set();
  const counts = { scanned: 0, indexed: 0, unchanged: 0, nameOnly: 0, errors: 0, removed: 0, lowText: 0 };
  const errors = [];
  let lastReport = 0;
  const report = (path, force) => {
    const now = Date.now();
    if (!force && now - lastReport < 250) return;
    lastReport = now;
    onProgress({ phase: 'index', path, ...counts });
  };

  for (const { root, prefix, folderId } of list) {
    const skip = (path, isDir) => {
      const vp = prefix ? `${prefix}/${path}` : path;
      if (path === META_DIR || path.startsWith(META_DIR + '/')) return true;
      return exclude(vp) || (isDir && path.split('/').pop().startsWith('.'));
    };
    for await (const { path: rel, file } of walk(root, { skip, onError: (p, e) => { counts.errors++; errors.push(`${p}: ${e.message}`); } })) {
      if (signal?.aborted) break;
      const path = prefix ? `${prefix}/${rel}` : rel;
      seen.add(path);
      counts.scanned++;
      const prev = existing.get(path);
      if (prev && prev.v === INDEX_VERSION && prev.size === file.size && prev.mtime === file.lastModified) {
        counts.unchanged++;
        report(path);
        continue;
      }
      const ext = extOf(file.name);
      const rec = {
        path, rel, folderId, size: file.size, mtime: file.lastModified, ext,
        project: projectOf(path, settings.projectDepth || 1),
        indexedAt: Date.now(), method: 'name', chars: 0, note: '',
      };
      let chunks = [];
      if (include.has(ext) && file.size <= maxBytes) {
        try {
          const res = await extractFile(file, { maxChars: settings.maxCharsPerFile });
          chunks = chunkText(res.pages);
          rec.method = res.method;
          rec.chars = res.chars || 0;
          rec.note = res.note || '';
          if (rec.note.startsWith('little text')) counts.lowText++;
          counts.indexed++;
        } catch (err) {
          rec.method = 'error';
          rec.note = String(err.message || err).slice(0, 200);
          counts.errors++;
          errors.push(`${path}: ${rec.note}`);
        }
      } else {
        if (file.size > maxBytes && include.has(ext)) rec.note = 'too large — name only';
        counts.nameOnly++;
      }
      if (!chunks.length) chunks = [{ text: `File: ${path}`, page: 0 }];
      await writer.addFile(rec, chunks);
      report(path, false);
      if (counts.scanned % 20 === 0) await tick();
    }
    if (signal?.aborted) break;
  }

  if (!signal?.aborted) {
    for (const path of existing.keys()) {
      if (!seen.has(path)) {
        await writer.removeFile(path);
        counts.removed++;
      }
    }
  }
  await writer.finish();
  const files = await getAll('files');
  const projects = [...new Set(files.map((f) => f.project).filter(Boolean))].sort();
  await kvSet('projects', projects);
  const status = {
    at: Date.now(), root: rootName, ms: Date.now() - started, aborted: !!signal?.aborted,
    files: files.length, folders: list.length, ...counts, errors: errors.slice(0, 50),
  };
  await kvSet('indexStatus', status);
  await log('index', `Indexed ${counts.indexed} changed, ${counts.unchanged} unchanged, ${counts.removed} removed across ${list.length} folder(s)`);
  report('', true);
  return status;
}

// Applies the Pi's deep OCR index. `getFile` returns the gz File (fetched over
// HTTPS from the NAS, or read from a local folder) or null if there is none.
export async function applyDeepIndex(getFile, settings, { onProgress = () => {}, force = false, signal, from = 'nas' } = {}) {
  let file;
  try {
    file = typeof getFile === 'function' ? await getFile() : await legacyFolderFile(getFile, settings);
  } catch (err) {
    return { found: false, error: err.message };
  }
  if (!file) return { applied: 0, found: false };
  const last = (await kvGet('deepApplied')) || {};
  if (!force && last.mtime === file.lastModified && last.size === file.size) {
    return { applied: 0, found: true, upToDate: true, from };
  }
  const existing = new Map((await getAll('files')).map((f) => [f.path, f]));
  const writer = new IndexWriter();
  const counts = { records: 0, applied: 0, stale: 0, unmatched: 0, kept: 0 };
  const stream = file.stream()
    .pipeThrough(new DecompressionStream('gzip'))
    .pipeThrough(new TextDecoderStream());
  let buf = '';
  const handle = async (line) => {
    if (!line.trim()) return;
    let r;
    try { r = JSON.parse(line); } catch { return; }
    counts.records++;
    const rec = existing.get(r.path);
    if (!rec) { counts.unmatched++; return; }
    if (rec.size !== r.size) { counts.stale++; return; }
    if (rec.method && rec.method.startsWith('deep:') && rec.deepMtime === r.mtime) { counts.kept++; return; }
    const pages = (r.pages || []).map((p) => [p[0], p[1]]);
    const chars = pages.reduce((acc, p) => acc + (p[1] || '').length, 0);
    if (!chars) { counts.kept++; return; }
    if (!(chars >= rec.chars * 0.8 || rec.chars < 500)) { counts.kept++; return; }
    const capped = [];
    let total = 0;
    for (const [n, t] of pages) {
      if (total >= settings.maxCharsPerFile) break;
      capped.push([n, t.slice(0, settings.maxCharsPerFile - total)]);
      total += t.length;
    }
    const next = { ...rec, method: `deep:${r.method || 'text'}`, chars, deepMtime: r.mtime, note: '', indexedAt: Date.now() };
    delete next.chunkIds;
    await writer.addFile(next, chunkText(capped));
    counts.applied++;
    if (counts.applied % 10 === 0) onProgress({ phase: 'deep', ...counts });
  };
  const reader = stream.getReader();
  for (;;) {
    if (signal?.aborted) break;
    const { value, done } = await reader.read();
    if (done) break;
    buf += value;
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      await handle(line);
    }
  }
  if (buf) await handle(buf);
  await writer.finish();
  await kvSet('deepApplied', { mtime: file.lastModified, size: file.size, at: Date.now(), from, ...counts });
  await log('deep', `Deep index from ${from}: ${counts.applied} files improved, ${counts.stale} stale, ${counts.unmatched} not present here`);
  onProgress({ phase: 'deep', done: true, ...counts });
  return { found: true, from, ...counts };
}

// Backward-compatible folder lookup: roots = [[name, handle], ...]
async function legacyFolderFile(roots, settings) {
  for (const [, root] of roots) {
    if (!root) continue;
    try {
      return await (await getFileByPath(root, settings.deepIndexFile)).getFile();
    } catch { /* not in this root */ }
  }
  return null;
}
