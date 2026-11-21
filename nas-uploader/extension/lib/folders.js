// The project folders: the mirrors saved in "NAS files" (app.html). One fileset — each folder is mirrored to
// the NAS once and indexed once, and email drafts, meeting prompts and the chat all search that index.
// Paths in the index are the files' NAS paths without the leading slash ("Projects/2024-017 Alert/Specs/x.pdf"),
// so a file means the same thing on this computer and on the NAS (where the deep OCR index is built).

import { CONFIG, loadConfig } from './config-store.js';
import { listMirrors } from './store.js';
import { getSettings } from './db.js';
import { permissionState } from './fsutil.js';

/** [{id, name, handle, nasPath, prefix, index, projectMode, lastSync, perm}] for this NAS. */
export async function projectFolders({ withPerm = true } = {}) {
  await loadConfig();
  const settings = await getSettings();
  let mirrors = [];
  try {
    mirrors = await listMirrors();
  } catch {
    mirrors = [];
  }
  mirrors = mirrors.filter((m) => m.serverUrl === CONFIG.serverUrl && m.handle).sort((a, b) => a.created - b.created);
  const out = [];
  for (const m of mirrors) {
    const pref = (settings.folderPrefs || {})[m.id] || {};
    out.push({
      id: m.id,
      name: m.name,
      handle: m.handle,
      nasPath: m.nasPath,
      prefix: String(m.nasPath || '').replace(/^\/+|\/+$/g, ''),
      index: pref.index !== false,
      projectMode: pref.projectMode === 'single' ? 'single' : 'subfolders',
      lastSync: m.lastSync || null,
      perm: withPerm ? await permissionState(m.handle, 'read') : undefined,
    });
  }
  return out;
}

/**
 * The project a file belongs to. 'subfolders': every folder directly inside the mirrored folder is a project
 * (a drive of project folders). 'single': the mirrored folder itself is one project.
 */
export function projectFor(prefix, rel, mode = 'subfolders') {
  if (mode === 'single') return prefix;
  if (!rel.includes('/')) return ''; // loose files next to the project folders belong to no project
  const first = rel.split('/')[0];
  return prefix ? `${prefix}/${first}` : first;
}
