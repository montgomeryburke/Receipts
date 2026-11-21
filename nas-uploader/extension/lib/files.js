// File tools for the chat, like Desktop Commander's but inside Chrome: list, read and find files in the project
// folders on this computer (read-only: Chrome gave the extension read access) and on the NAS (read and write over
// WebDAV). Changes (write, new folder, move/rename, copy, delete) only happen on the NAS, and wait for the user's
// click unless they switched that off.

import { getAll, getSettings } from './db.js';
import { nasClient, ensureDir } from './nas.js';
import { projectFolders } from './folders.js';
import { permissionState, getFileByPath, getDirByPath } from './fsutil.js';
import { extractFile } from './extract.js';

const MAX_READ = 12000;

/** "nas:/Projects/x" → "/Projects/x"; anything not "local:" is a NAS path. */
export function nasPathOf(p) {
  return `/${String(p || '').replace(/^nas:/i, '').replace(/^\/+/, '')}`.replace(/\/+$/, '') || '/';
}

async function localFolder(name) {
  const folders = await projectFolders({ withPerm: false }).catch(() => []);
  const m = folders.find((x) => x.name === name || x.handle.name === name) || (!name && folders.length === 1 ? folders[0] : null);
  if (!m) throw new Error(`No project folder called "${name}". Folders: ${folders.map((x) => x.handle.name).join(', ') || '(none)'}`);
  if ((await permissionState(m.handle, 'read')) !== 'granted') throw new Error(`No access to "${m.handle.name}" right now: in "NAS files" click Reconnect, or use the NAS copy (nas:${m.nasPath}).`);
  return m;
}

function splitLocal(p) {
  const [folder, ...rest] = String(p).replace(/^local:\/*/i, '').split('/');
  return { folder, rel: rest.filter(Boolean).join('/') };
}

/** Lists a folder: local:<project folder>/<sub> or a NAS path. At most 300 entries. */
export async function listFolder(path = '/') {
  if (/^local:/i.test(path)) {
    const { folder, rel } = splitLocal(path);
    const m = await localFolder(folder);
    const dir = rel ? await getDirByPath(m.handle, rel) : m.handle;
    const out = [];
    for await (const [name, h] of dir.entries()) {
      if (out.length >= 300) break;
      const e = { name, dir: h.kind === 'directory' };
      if (h.kind === 'file') {
        const f = await h.getFile().catch(() => null);
        if (f) Object.assign(e, { size: f.size, modified: new Date(f.lastModified).toISOString().slice(0, 16) });
      }
      out.push(e);
    }
    return { path, entries: out.sort((a, b) => Number(b.dir) - Number(a.dir) || a.name.localeCompare(b.name)) };
  }
  const c = await nasClient();
  const entries = (await c.list(nasPathOf(path))).slice(0, 300).map((e) => ({ name: e.name, dir: !!e.isDir, size: e.isDir ? undefined : e.size, modified: e.modified ? new Date(e.modified).toISOString().slice(0, 16) : undefined }));
  return { path: nasPathOf(path), entries };
}

/** Reads a file's text (PDF, Word, Excel, PowerPoint and text files), shortened. */
export async function readFile(path, { maxChars = MAX_READ } = {}) {
  let file;
  if (/^local:/i.test(path)) {
    const { folder, rel } = splitLocal(path);
    const m = await localFolder(folder);
    file = await (await getFileByPath(m.handle, rel)).getFile();
  } else {
    const p = nasPathOf(path);
    const blob = await (await nasClient()).getBlob(p);
    if (!blob) throw new Error(`${p} is not on the NAS`);
    file = new File([blob], p.split('/').pop());
  }
  const res = await extractFile(file, { maxChars: maxChars * 2 });
  const text = (res.pages || []).map(([page, t]) => (page ? `[page ${page}]\n${t}` : t)).join('\n\n');
  return { path, size: file.size, chars: text.length, text: text.length > maxChars ? `${text.slice(0, maxChars)}\n[…shortened]` : text };
}

/** Finds files by name in the index (free, instant): every indexed project file, email and meeting. */
export async function findFiles(name, { under = '', limit = 40 } = {}) {
  const words = String(name || '').toLowerCase().split(/\s+/).filter(Boolean);
  const prefix = String(under || '').replace(/^nas:/i, '').replace(/^\/+/, '').toLowerCase();
  const hits = (await getAll('files'))
    .filter((r) => {
      const p = r.path.toLowerCase();
      return (!prefix || p.startsWith(prefix)) && words.every((w) => p.includes(w));
    })
    .sort((a, b) => (b.mtime || 0) - (a.mtime || 0))
    .slice(0, limit)
    .map((r) => ({ path: r.folderId === 'mail' || r.folderId === 'meeting' ? r.path : `nas:/${r.path.replace(/^\/+/, '')}`, modified: r.mtime ? new Date(r.mtime).toISOString().slice(0, 10) : '', size: r.size }));
  return { hits };
}

/** A plain-words summary of a change, for the confirmation button. */
export function describeChange(op) {
  switch (op.op) {
    case 'write': return `Write ${nasPathOf(op.path)} on the NAS (${String(op.text || '').length} characters)`;
    case 'mkdir': return `Create the folder ${nasPathOf(op.path)} on the NAS`;
    case 'move': return `Move/rename ${nasPathOf(op.path)} → ${nasPathOf(op.to)} on the NAS`;
    case 'copy': return `Copy ${nasPathOf(op.path)} → ${nasPathOf(op.to)} on the NAS`;
    case 'delete': return `Delete ${nasPathOf(op.path)} on the NAS`;
    default: return `Unknown change ${op.op}`;
  }
}

/** Is this NAS path inside a mirrored project folder? (The mirror copies this computer → NAS, one way.) */
async function mirroredFolder(p) {
  const folders = await projectFolders({ withPerm: false }).catch(() => []);
  return folders.find((f) => f.nasPath && (p === f.nasPath || p.startsWith(`${f.nasPath.replace(/\/+$/, '')}/`)));
}

/** Makes a change on the NAS. Returns {done, note?}. */
export async function applyChange(op) {
  const c = await nasClient();
  const p = nasPathOf(op.path);
  if (p === '/' || p.split('/').length < 2) throw new Error('Refused: that is the top of the NAS.');
  const mirrored = await mirroredFolder(p);
  const note = mirrored ? `Note: ${p} is inside the mirrored folder "${mirrored.name}" — the mirror copies this computer to the NAS, so the next sync may undo this change on the NAS.` : undefined;
  switch (op.op) {
    case 'write': {
      await ensureDir(c, p.slice(0, p.lastIndexOf('/')) || '/');
      await c.upload(p, new Blob([String(op.text || '')], { type: 'text/plain;charset=utf-8' }));
      return { done: true, note };
    }
    case 'mkdir':
      await ensureDir(c, p);
      return { done: true, note };
    case 'move': {
      const to = nasPathOf(op.to);
      const st = await c.stat(p);
      if (!st) throw new Error(`${p} is not on the NAS`);
      await ensureDir(c, to.slice(0, to.lastIndexOf('/')) || '/');
      await c.move(p, to, { dir: !!st.isDir });
      return { done: true, note };
    }
    case 'copy': {
      const to = nasPathOf(op.to);
      const blob = await c.getBlob(p);
      if (!blob) throw new Error(`${p} is not on the NAS (folders can't be copied this way)`);
      await ensureDir(c, to.slice(0, to.lastIndexOf('/')) || '/');
      await c.upload(to, blob);
      return { done: true, note };
    }
    case 'delete': {
      const st = await c.stat(p);
      if (!st) return { done: true, note: 'It was already gone.' };
      await c.remove(p, { dir: !!st.isDir });
      return { done: true, note };
    }
    default:
      throw new Error(`Unknown change ${op.op}`);
  }
}

/** Whether changes wait for the user's click (Settings → Chat; on by default). */
export async function changesNeedClick() {
  return (await getSettings()).chatFileConfirm !== false;
}
