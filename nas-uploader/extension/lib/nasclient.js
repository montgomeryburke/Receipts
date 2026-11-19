// The NAS client for an address: WebDAV (Apache, Synology, QNAP, Nextcloud…) or File Browser (filebrowser.org,
// e.g. "Mark NAS"). Which one is found out once from the address's own start page and remembered.

import { WebDAVClient } from './webdav.js';
import { FileBrowserClient } from './filebrowser.js';

const KEY = (serverUrl) => `nasKind:${serverUrl}`;
const known = new Map(); // also in memory: the background engine has no chrome.storage

/** 'filebrowser' when the address is a File Browser, else 'webdav'. Remembered per address. */
export async function serverKind(serverUrl, { fresh = false } = {}) {
  const key = KEY(serverUrl);
  if (!fresh && known.has(serverUrl)) return known.get(serverUrl);
  if (!fresh) {
    try {
      const saved = (await chrome.storage.local.get(key))[key];
      if (saved) {
        known.set(serverUrl, saved);
        return saved;
      }
    } catch {
      /* no storage (tests) */
    }
  }
  let kind = 'webdav';
  let sure = false;
  try {
    const res = await fetch(serverUrl, { credentials: 'omit', cache: 'no-store', redirect: 'follow' });
    sure = true;
    if (res.ok && /text\/html/i.test(res.headers.get('content-type') || '')) {
      const html = (await res.text()).slice(0, 20000);
      // File Browser's page carries its settings in "window.FileBrowser = {…}".
      if (/window\.FileBrowser\s*=/.test(html)) kind = 'filebrowser';
    }
  } catch {
    sure = false; // unreachable now: don't remember a guess
  }
  if (sure) {
    known.set(serverUrl, kind);
    try {
      await chrome.storage.local.set({ [key]: kind });
    } catch {
      /* no storage */
    }
  }
  return kind;
}

/** A client for the NAS at serverUrl with these credentials. */
export async function createNasClient({ serverUrl, username, password }) {
  const kind = await serverKind(serverUrl);
  return kind === 'filebrowser' ? new FileBrowserClient({ serverUrl, username, password }) : new WebDAVClient({ serverUrl, username, password });
}
