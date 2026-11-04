// The NAS connection every part of the extension uses. config.js wins when it is filled in (details built into
// the extension folder). Otherwise the address and login typed into the setup form are used, kept in
// chrome.storage.local on this computer (or, without "remember", the password only for this browser session).
//
// CONFIG is one shared object: call loadConfig() once when a page starts, then read CONFIG as usual.

import { CONFIG as FILE } from '../config.js';

export const CONFIG = { ...FILE, source: 'config.js' };

const KEY = 'nasConfig';

/** Why these settings can't be used yet, or null. */
export function problemWith(c) {
  const url = String(c?.serverUrl || '').trim();
  if (!url || /your-nas\.example\.com/i.test(url)) return 'serverUrl is still set to the example address.';
  let u;
  try {
    u = new URL(url);
  } catch {
    return `serverUrl "${url}" is not a valid web address.`;
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return 'serverUrl must start with https:// (or http://).';
  if (c.username === 'your-nas-username') return 'username is still set to the example value.';
  if (c.password === 'your-nas-password') return 'password is still set to the example value.';
  return null;
}

export const fileIsConfigured = () => !problemWith(FILE);

async function readSaved() {
  try {
    if (chrome.storage?.local) return (await chrome.storage.local.get(KEY))[KEY] || null;
  } catch {
    /* not available in this context */
  }
  // Offscreen documents can't read chrome.storage; the service worker answers for them.
  try {
    const r = await chrome.runtime.sendMessage({ to: 'bg', type: 'nas.config' });
    return r?.serverUrl ? r : null;
  } catch {
    return null;
  }
}

let loaded = null;
/**
 * Fills CONFIG from config.js or the saved settings. Safe to call often: config.js is read once, saved settings
 * are re-read each time (a small local read), so a NAS address typed in one page reaches the others.
 */
export function loadConfig({ fresh = false } = {}) {
  if (loaded && !fresh && fileIsConfigured()) return loaded;
  loaded = (async () => {
    if (fileIsConfigured()) {
      Object.assign(CONFIG, FILE, { source: 'config.js' });
      return CONFIG;
    }
    const saved = await readSaved();
    if (saved?.serverUrl) {
      Object.assign(CONFIG, FILE, { serverUrl: saved.serverUrl, username: saved.username || '', password: saved.password || '', startFolder: saved.startFolder || FILE.startFolder || '/', source: 'settings' });
    } else {
      Object.assign(CONFIG, FILE, { source: 'config.js' }); // nothing saved (or it was forgotten)
    }
    return CONFIG;
  })();
  return loaded;
}

/**
 * Saves the NAS address and login typed into the setup form (only used when config.js isn't filled in).
 * remember=false keeps the password out of storage: it is asked once per browser session instead.
 */
export async function saveConfig({ serverUrl, username, password, remember = true }) {
  let url = String(serverUrl || '').trim();
  if (url && !/^https?:\/\//i.test(url)) url = `https://${url}`;
  if (url && !url.endsWith('/')) url += '/';
  const next = { serverUrl: url, username: String(username || '').trim(), password: remember ? String(password || '') : '' };
  const problem = problemWith({ ...next, password: next.password || 'x' });
  if (problem) throw new Error(problem.replace(/^serverUrl/, 'The NAS address'));
  await chrome.storage.local.set({ [KEY]: next });
  if (!remember && password) {
    try {
      await chrome.storage.session.set({ username: next.username, password: String(password) });
    } catch {
      /* asked again at sign-in */
    }
  }
  Object.assign(CONFIG, FILE, next, { startFolder: FILE.startFolder || '/', source: 'settings' });
  loaded = Promise.resolve(CONFIG);
  return CONFIG;
}

export async function forgetSavedConfig() {
  await chrome.storage.local.remove(KEY);
  try {
    await chrome.storage.session.remove(['username', 'password']);
  } catch {
    /* nothing kept */
  }
  Object.assign(CONFIG, FILE, { source: 'config.js' });
  loaded = Promise.resolve(CONFIG);
}
