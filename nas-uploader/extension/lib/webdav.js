// Minimal WebDAV client built on XMLHttpRequest (XHR gives us upload progress, fetch does not).
// Works with Synology, QNAP, TrueNAS, Nextcloud, Apache mod_dav and any other RFC 4918 server.

import { normalizePath, encodePath, safeDecode, basicAuthHeader, parentPath, baseName } from './util.js';

const RETRYABLE_STATUS = new Set([0, 408, 423, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524]);

export class WebDAVError extends Error {
  constructor(message, { status = 0, retryable = false, aborted = false } = {}) {
    super(message);
    this.name = 'WebDAVError';
    this.status = status;
    this.retryable = retryable;
    this.aborted = aborted;
  }
}

function describeStatus(status, method) {
  switch (status) {
    case 0:
      return 'Could not reach the NAS (network error, wrong address, or HTTPS certificate problem)';
    case 400:
      return 'The NAS rejected the request (HTTP 400) — the name may contain characters it does not allow';
    case 401:
      return 'The NAS rejected the username or password (HTTP 401)';
    case 403:
      return 'Permission denied by the NAS (HTTP 403) — this account cannot write here';
    case 404:
      return 'Not found on the NAS (HTTP 404)';
    case 405:
      return method === 'MKCOL' ? 'Folder already exists (HTTP 405)' : 'The NAS does not allow this operation here (HTTP 405)';
    case 409:
      return 'The parent folder does not exist on the NAS (HTTP 409)';
    case 413:
      return 'File is too large for the NAS or a proxy in front of it (HTTP 413) — raise its upload size limit';
    case 414:
      return 'Path is too long for the NAS (HTTP 414)';
    case 423:
      return 'The file is locked on the NAS (HTTP 423)';
    case 507:
      return 'The NAS is out of space (HTTP 507)';
    default:
      return `The NAS answered HTTP ${status}`;
  }
}

export class WebDAVClient {
  /**
   * @param {{serverUrl: string, username: string, password: string}} opts
   */
  constructor({ serverUrl, username, password }) {
    const url = new URL(serverUrl);
    if (!url.pathname.endsWith('/')) url.pathname += '/';
    url.search = '';
    url.hash = '';
    this.origin = url.origin;
    this.basePath = url.pathname; // already percent-encoded by URL
    this.decodedBasePath = safeDecode(url.pathname);
    this.username = username || '';
    this.password = password || '';
    this.authHeader = username || password ? basicAuthHeader(username, password) : null;
  }

  /** Absolute URL for a NAS path ("/" is the WebDAV root). Folders get a trailing slash when asked. */
  url(path, { dir = false } = {}) {
    const rel = encodePath(path).replace(/^\/+/, '');
    let u = this.origin + this.basePath + rel;
    if (dir && rel && !u.endsWith('/')) u += '/';
    return u;
  }

  /**
   * Low-level request. Resolves with {status, text, headers} for 2xx, throws WebDAVError otherwise.
   */
  request(method, path, { headers = {}, body = null, dir = false, timeout = 120000, signal, onUploadProgress, okStatuses } = {}) {
    return new Promise((resolve, reject) => {
      if (signal?.aborted) {
        reject(new WebDAVError('Cancelled', { aborted: true }));
        return;
      }
      const xhr = new XMLHttpRequest();
      // Passing the credentials here as well as in the header stops Chrome from showing (and waiting on)
      // its own login pop-up when the NAS answers 401; the request then simply fails with status 401.
      if (this.authHeader) xhr.open(method, this.url(path, { dir }), true, this.username, this.password);
      else xhr.open(method, this.url(path, { dir }), true);
      xhr.timeout = timeout;
      if (this.authHeader) xhr.setRequestHeader('Authorization', this.authHeader);
      for (const [k, v] of Object.entries(headers)) xhr.setRequestHeader(k, v);

      let stallTimer = null;
      let lastProgress = Date.now();
      const STALL_MS = 120000;
      const cleanup = () => {
        if (stallTimer) clearInterval(stallTimer);
        signal?.removeEventListener('abort', onAbort);
      };
      const onAbort = () => xhr.abort();
      signal?.addEventListener('abort', onAbort, { once: true });

      if (onUploadProgress && xhr.upload) {
        let sentAll = false;
        xhr.upload.onprogress = (e) => {
          lastProgress = Date.now();
          if (e.lengthComputable && e.loaded >= e.total) sentAll = true;
          onUploadProgress(e.loaded, e.total);
        };
        // Abort uploads that stop moving for two minutes so the retry logic can take over.
        stallTimer = setInterval(() => {
          if (!sentAll && Date.now() - lastProgress > STALL_MS) {
            xhr.stalled = true;
            xhr.abort();
          }
        }, 5000);
      }

      xhr.onload = () => {
        cleanup();
        const status = xhr.status;
        const ok = okStatuses ? okStatuses.includes(status) : status >= 200 && status < 300;
        if (ok) {
          resolve({ status, text: xhr.responseText, headers: xhr.getAllResponseHeaders() });
        } else {
          reject(new WebDAVError(describeStatus(status, method), { status, retryable: RETRYABLE_STATUS.has(status) }));
        }
      };
      xhr.onerror = () => {
        cleanup();
        reject(new WebDAVError(describeStatus(0, method), { status: 0, retryable: true }));
      };
      xhr.ontimeout = () => {
        cleanup();
        reject(new WebDAVError('The NAS took too long to answer', { status: 0, retryable: true }));
      };
      xhr.onabort = () => {
        cleanup();
        if (xhr.stalled) reject(new WebDAVError('Upload stalled (no progress for 2 minutes)', { status: 0, retryable: true }));
        else reject(new WebDAVError('Cancelled', { aborted: true }));
      };
      xhr.send(body);
    });
  }

  /** Convert an href from a PROPFIND response into a normalised NAS path, or null if it is outside our root. */
  hrefToPath(href) {
    let pathname;
    try {
      pathname = new URL(href, this.origin + this.basePath).pathname;
    } catch {
      return null;
    }
    const decoded = safeDecode(pathname);
    if (decoded.startsWith(this.decodedBasePath)) return normalizePath(decoded.slice(this.decodedBasePath.length));
    if (decoded + '/' === this.decodedBasePath) return '/';
    return null;
  }

  /** Parse a multistatus body into entries. */
  parseMultistatus(xmlText, requestedPath) {
    const doc = new DOMParser().parseFromString(xmlText, 'application/xml');
    if (doc.getElementsByTagName('parsererror').length) {
      throw new WebDAVError('The NAS sent a folder listing that could not be read (is this really a WebDAV address?)');
    }
    const DAV = 'DAV:';
    const first = (el, name) => el.getElementsByTagNameNS(DAV, name)[0] || null;
    const entries = [];
    for (const resp of Array.from(doc.getElementsByTagNameNS(DAV, 'response'))) {
      const hrefEl = first(resp, 'href');
      if (!hrefEl) continue;
      const href = hrefEl.textContent.trim();
      let path = this.hrefToPath(href);
      const hrefIsDir = href.endsWith('/');

      // Collect properties from the propstat blocks that report success.
      let isDir = false;
      let size = null;
      let modified = null;
      let foundProps = false;
      for (const ps of Array.from(resp.getElementsByTagNameNS(DAV, 'propstat'))) {
        const statusEl = first(ps, 'status');
        if (statusEl && !/\s2\d\d\s/.test(' ' + statusEl.textContent + ' ')) continue;
        const prop = first(ps, 'prop');
        if (!prop) continue;
        foundProps = true;
        const rt = first(prop, 'resourcetype');
        if (rt && rt.getElementsByTagNameNS(DAV, 'collection').length) isDir = true;
        const len = first(prop, 'getcontentlength');
        if (len && len.textContent.trim() !== '') size = Number(len.textContent.trim());
        const lm = first(prop, 'getlastmodified');
        if (lm && lm.textContent.trim()) modified = new Date(lm.textContent.trim());
      }
      if (!foundProps) isDir = hrefIsDir;

      if (path === null) {
        // The server reports paths without our base prefix (e.g. a reverse proxy rewrote them).
        // Work out whether this entry is the requested folder itself or one of its children.
        let hp;
        try {
          hp = normalizePath(safeDecode(new URL(href, this.origin).pathname));
        } catch {
          continue;
        }
        const req = normalizePath(requestedPath);
        const hpParent = parentPath(hp);
        const isChild = hp !== req && (req === '/' ? hp !== '/' : hpParent === req || hpParent.endsWith(req));
        path = isChild ? normalizePath(req + '/' + baseName(hp)) : req;
      }
      entries.push({ path, name: baseName(path), isDir, size: isDir ? null : size, modified });
    }
    return entries;
  }

  async propfind(path, depth, opts = {}) {
    const body =
      '<?xml version="1.0" encoding="utf-8"?>' +
      '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>';
    const res = await this.request('PROPFIND', path, {
      headers: { Depth: String(depth), 'Content-Type': 'application/xml; charset=utf-8' },
      body,
      dir: depth > 0,
      okStatuses: [207, 200],
      timeout: 300000, // listings of huge folders can be large
      ...opts,
    });
    return this.parseMultistatus(res.text, path);
  }

  /** List the immediate children of a folder. */
  async list(path, opts) {
    const target = normalizePath(path);
    const entries = await this.propfind(target, 1, opts);
    return entries.filter((e) => e.path !== target && e.name);
  }

  /** Info about a single path, or null if it does not exist. */
  async stat(path, opts) {
    try {
      const entries = await this.propfind(normalizePath(path), 0, opts);
      return entries[0] || null;
    } catch (err) {
      if (err.status === 404) return null;
      throw err;
    }
  }

  /** Create one folder. Resolves to 'created' or 'exists'. Parent must exist. */
  async mkdir(path, opts) {
    const p = normalizePath(path);
    if (p === '/') return 'exists';
    try {
      await this.request('MKCOL', p, { dir: true, ...opts });
      return 'created';
    } catch (err) {
      if (err.aborted || err.retryable || err.status === 401 || err.status === 507) throw err;
      // 405 (exists) is the normal answer for an existing folder; some servers use 301/302/409/403. Check.
      const info = await this.stat(p, opts).catch(() => null);
      if (info && info.isDir) return 'exists';
      if (info && !info.isDir) {
        throw new WebDAVError(`A file named "${baseName(p)}" already exists where a folder is needed`, { status: err.status });
      }
      throw err;
    }
  }

  /** Upload a File/Blob to path (overwrites). */
  upload(path, file, { onProgress, signal } = {}) {
    const headers = { 'Content-Type': 'application/octet-stream' };
    // Nextcloud/ownCloud keep the original modification time when given this header; other servers ignore it.
    if (file.lastModified) headers['X-OC-Mtime'] = String(Math.floor(file.lastModified / 1000));
    return this.request('PUT', path, { headers, body: file, timeout: 0, signal, onUploadProgress: onProgress });
  }

  async remove(path, { dir = false, ...opts } = {}) {
    const p = normalizePath(path);
    if (p === '/') throw new WebDAVError('Refusing to delete the root folder');
    await this.request('DELETE', p, { dir, ...opts });
  }
}
