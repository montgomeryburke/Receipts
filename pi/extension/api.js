// Thin client for the pi-nas HTTP API.
//
// The access token lives in chrome.storage.local and is attached as a bearer
// header on every call. It is never put in a URL — downloads use a short-lived
// single-use ticket instead, so the token cannot leak through browser history,
// the download list, or a server log.

export const SETTINGS_KEY = 'pinas.settings';

export async function loadSettings() {
  const stored = await chrome.storage.local.get(SETTINGS_KEY);
  return stored[SETTINGS_KEY] || { baseUrl: '', token: '' };
}

export async function saveSettings(settings) {
  await chrome.storage.local.set({ [SETTINGS_KEY]: settings });
}

export class NasError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

export class Nas {
  constructor({ baseUrl, token }) {
    this.baseUrl = (baseUrl || '').replace(/\/+$/, '');
    this.token = token || '';
  }

  get configured() {
    return Boolean(this.baseUrl && this.token);
  }

  url(path, params = {}) {
    const target = new URL(this.baseUrl + path);
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined && value !== null) target.searchParams.set(key, value);
    }
    return target.toString();
  }

  async request(path, { method = 'GET', params, body } = {}) {
    let response;
    try {
      response = await fetch(this.url(path, params), {
        method,
        headers: {
          Authorization: `Bearer ${this.token}`,
          ...(body ? { 'Content-Type': 'application/json' } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch (cause) {
      throw new NasError(
        'Cannot reach the Pi. Check that it is powered on and that you are connected to your tailnet.',
        0,
      );
    }
    if (!response.ok) {
      let detail = `Request failed (${response.status})`;
      if (response.status === 401) detail = 'Access token rejected. Re-check it in Options.';
      if (response.status === 403) detail = 'This token is read-only.';
      try {
        const payload = await response.json();
        if (payload && payload.detail && response.status !== 401) detail = payload.detail;
      } catch { /* body was not JSON; keep the generic message */ }
      throw new NasError(detail, response.status);
    }
    return response.status === 204 ? null : response.json();
  }

  whoami() { return this.request('/api/whoami'); }
  usage() { return this.request('/api/usage'); }
  list(path = '') { return this.request('/api/list', { params: { path } }); }
  mkdir(path) { return this.request('/api/mkdir', { method: 'POST', body: { path } }); }
  move(src, dst) { return this.request('/api/move', { method: 'POST', body: { src, dst } }); }

  remove(path, recursive = false) {
    return this.request('/api/delete', { method: 'POST', body: { path, recursive } });
  }

  // Mints a ticket, then hands the URL to Chrome's download manager so the
  // file streams to disk instead of being buffered in extension memory.
  async download(path, filename) {
    const { ticket } = await this.request('/api/ticket', { method: 'POST', body: { path } });
    return chrome.downloads.download({
      url: this.url('/api/download', { path, ticket }),
      filename,
      saveAs: false,
    });
  }

  // XHR rather than fetch: fetch still cannot report upload progress, and a
  // NAS upload of a multi-gigabyte file with no progress bar is unusable.
  upload(file, directory, { onProgress } = {}) {
    const path = directory ? `${directory}/${file.name}` : file.name;
    return new Promise((resolve, reject) => {
      const request = new XMLHttpRequest();
      request.open('PUT', this.url('/api/upload', { path }), true);
      request.setRequestHeader('Authorization', `Bearer ${this.token}`);
      request.upload.addEventListener('progress', (event) => {
        if (event.lengthComputable && onProgress) onProgress(event.loaded / event.total);
      });
      request.addEventListener('load', () => {
        if (request.status >= 200 && request.status < 300) {
          try { resolve(JSON.parse(request.responseText)); }
          catch { resolve({ path }); }
        } else if (request.status === 403) {
          reject(new NasError('This token is read-only.', 403));
        } else if (request.status === 413) {
          reject(new NasError('File is larger than the server allows.', 413));
        } else {
          reject(new NasError(`Upload failed (${request.status})`, request.status));
        }
      });
      request.addEventListener('error', () => reject(new NasError('Upload failed: network error', 0)));
      request.addEventListener('abort', () => reject(new NasError('Upload cancelled', 0)));
      request.send(file);
    });
  }
}

export function formatBytes(bytes) {
  if (!bytes) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const value = bytes / 1024 ** index;
  return `${value >= 10 || index === 0 ? Math.round(value) : value.toFixed(1)} ${units[index]}`;
}

export function formatDate(seconds) {
  const date = new Date(seconds * 1000);
  const now = new Date();
  const sameYear = date.getFullYear() === now.getFullYear();
  return date.toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric',
    ...(sameYear ? {} : { year: 'numeric' }),
  });
}
