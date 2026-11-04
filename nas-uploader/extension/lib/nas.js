// The NAS connection for every part of the extension (file manager, engine, meeting window, side panel).
// The address and login come from config.js; if config.js has no password, the login typed into
// "NAS files" is kept for this browser session only.

import { CONFIG } from '../config.js';
import { WebDAVClient } from './webdav.js';
import { normalizePath, parentPath } from './util.js';

/** Why config.js can't be used yet, or null. */
export function configProblem() {
  const url = String(CONFIG?.serverUrl || '').trim();
  if (!url || /your-nas\.example\.com/i.test(url)) return 'serverUrl is still set to the example address.';
  let u;
  try {
    u = new URL(url);
  } catch {
    return `serverUrl "${url}" is not a valid web address.`;
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return 'serverUrl must start with https:// (or http://).';
  if (CONFIG.username === 'your-nas-username') return 'username is still set to the example value.';
  if (CONFIG.password === 'your-nas-password') return 'password is still set to the example value.';
  return null;
}

export async function nasCreds() {
  if (CONFIG.username && CONFIG.password) return { username: CONFIG.username, password: CONFIG.password };
  try {
    if (chrome.storage?.session) {
      const s = await chrome.storage.session.get(['username', 'password']);
      const username = CONFIG.username || s.username || '';
      if (username && s.password) return { username, password: s.password };
      return null;
    }
  } catch {
    /* not available in this context */
  }
  // Offscreen documents can't read chrome.storage; the service worker answers for them.
  try {
    const r = await chrome.runtime.sendMessage({ to: 'bg', type: 'nas.creds' });
    if (r?.username && r?.password) return { username: r.username, password: r.password };
  } catch {
    /* no answer */
  }
  return null;
}

export async function nasClient() {
  const problem = configProblem();
  if (problem) throw new Error(`The NAS isn't set up in config.js yet: ${problem}`);
  const creds = await nasCreds();
  if (!creds) throw new Error('Not signed in to the NAS — open "NAS files" once and sign in.');
  return new WebDAVClient({ serverUrl: CONFIG.serverUrl, ...creds });
}

/** Creates a folder and any missing parents. */
export async function ensureDir(client, path) {
  const parts = normalizePath(path).split('/').filter(Boolean);
  let cur = '';
  for (const p of parts) {
    cur += '/' + p;
    await client.mkdir(cur);
  }
}

/** Writes a text file, creating its folder first. */
export async function writeTextFile(client, path, text, contentType = 'text/markdown; charset=utf-8') {
  await ensureDir(client, parentPath(path));
  await client.putText(path, text, { contentType });
}

/** A name that is safe as a file name on Windows, macOS and Linux. */
export function safeFileName(name, fallback = 'untitled') {
  const cleaned = String(name || '')
    .replace(/[\\/:*?"<>|\u0000-\u001f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^\.+/, '')
    .slice(0, 120);
  return cleaned || fallback;
}
