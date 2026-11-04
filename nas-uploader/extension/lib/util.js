// Small helpers shared by the app: path handling, formatting, auth.

/** Normalise a NAS path to "/a/b" form (always leading slash, no trailing slash, no empty or "." segments). */
export function normalizePath(path) {
  const parts = [];
  for (const seg of String(path || '').split('/')) {
    if (!seg || seg === '.') continue;
    if (seg === '..') parts.pop();
    else parts.push(seg);
  }
  return '/' + parts.join('/');
}

export function joinPath(...parts) {
  return normalizePath(parts.filter((p) => p !== undefined && p !== null && p !== '').join('/'));
}

export function parentPath(path) {
  const p = normalizePath(path);
  if (p === '/') return '/';
  return p.slice(0, p.lastIndexOf('/')) || '/';
}

export function baseName(path) {
  const p = normalizePath(path);
  return p.slice(p.lastIndexOf('/') + 1);
}

/** Percent-encode every segment of a path so names with #, ?, %, spaces or unicode survive the trip. */
export function encodePath(path) {
  return normalizePath(path).split('/').map(encodeURIComponent).join('/');
}

export function safeDecode(s) {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}

export function basicAuthHeader(username, password) {
  const bytes = new TextEncoder().encode(`${username}:${password}`);
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return 'Basic ' + btoa(bin);
}

export function formatBytes(n) {
  if (n === null || n === undefined || isNaN(n)) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${i === 0 ? v : v.toFixed(v >= 100 ? 0 : v >= 10 ? 1 : 2)} ${units[i]}`;
}

export function formatDuration(seconds) {
  if (!isFinite(seconds) || seconds < 0) return '—';
  seconds = Math.round(seconds);
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m ${s}s`;
  return `${s}s`;
}

export function formatDate(d) {
  if (!d || isNaN(d)) return '';
  return d.toLocaleString(undefined, { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

// Chrome slows timers in background tabs down to about one per minute. A dedicated worker's timers aren't
// throttled that way, so waits (retry back-off, auto-resume) run on one when possible.
let timerWorker;
let timerSeq = 0;
const timerCallbacks = new Map();
function getTimerWorker() {
  if (timerWorker === undefined) {
    try {
      timerWorker = new Worker(new URL('./timer-worker.js', import.meta.url));
      timerWorker.onmessage = (e) => {
        const fn = timerCallbacks.get(e.data);
        timerCallbacks.delete(e.data);
        fn?.();
      };
    } catch {
      timerWorker = null;
    }
  }
  return timerWorker;
}

/** Run fn after ms milliseconds; returns a function that cancels it. */
export function after(ms, fn) {
  const w = getTimerWorker();
  if (!w) {
    const t = setTimeout(fn, ms);
    return () => clearTimeout(t);
  }
  const id = ++timerSeq;
  timerCallbacks.set(id, fn);
  w.postMessage({ id, ms });
  return () => timerCallbacks.delete(id);
}

export function sleep(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(signal.reason);
    const cancel = after(ms, () => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    });
    const onAbort = () => {
      cancel();
      reject(signal.reason);
    };
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}

/** Resolves once the browser reports it is online again (immediately if it already is). */
export function waitForOnline(signal) {
  if (navigator.onLine) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const done = () => {
      window.removeEventListener('online', done);
      signal?.removeEventListener('abort', onAbort);
      resolve();
    };
    const onAbort = () => {
      window.removeEventListener('online', done);
      reject(signal.reason);
    };
    window.addEventListener('online', done);
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}

/** Files that operating systems scatter around and nobody wants on the NAS. */
const JUNK_FILES = new Set(['.ds_store', 'thumbs.db', 'ehthumbs.db', 'desktop.ini']);
const JUNK_DIRS = new Set(['$recycle.bin', 'system volume information', '.spotlight-v100', '.trashes', '.fseventsd']);

export function isJunkFile(name) {
  const n = name.toLowerCase();
  return JUNK_FILES.has(n) || n.startsWith('._');
}

export function isJunkDir(name) {
  return JUNK_DIRS.has(name.toLowerCase());
}

/** Names that can't be saved by Chrome's downloads API. */
export function sanitizeDownloadName(name) {
  const cleaned = name.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_').replace(/^\.+/, '_').trim();
  return cleaned || 'download';
}
