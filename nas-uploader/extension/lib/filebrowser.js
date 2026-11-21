// A File Browser server (filebrowser.org, e.g. "Mark NAS") as the NAS: the same operations as the WebDAV client
// (list, stat, mkdir, upload, remove, move, getText, getBlob, putText), over File Browser's own API.
//   POST   api/login                         {username, password} → a session token (sent as X-Auth)
//   GET    api/resources/<folder>/           folder listing (items: name, size, modified, isDir)
//   POST   api/resources/<folder>/           make the folder (and its parents)
//   POST   api/resources/<file>?override=true upload (parent folders made too)
//   PATCH  api/resources/<from>?action=rename&destination=<to>&override=false   move; 409 if <to> exists
//   DELETE api/resources/<path>              delete (folders with their contents)
//   GET    api/raw/<file>                    download
// The token lasts a couple of hours; a 401 signs in again once and repeats the request.

import { normalizePath, encodePath, parentPath, baseName } from './util.js';
import { WebDAVError, describeStatus, xhrSend } from './webdav.js';

export class FileBrowserClient {
  constructor({ serverUrl, username, password }) {
    const url = new URL(serverUrl);
    if (!url.pathname.endsWith('/')) url.pathname += '/';
    url.search = '';
    url.hash = '';
    this.kind = 'filebrowser';
    this.origin = url.origin;
    this.basePath = url.pathname;
    this.username = username || '';
    this.password = password || '';
    this.authHeader = null; // no Basic auth: a session token instead
    this.token = null;
    this.signingIn = null;
  }

  /** api/<kind>/<path> (folders end in "/"), with an optional query. */
  api(kind, path, { dir = false, query = null } = {}) {
    const p = normalizePath(path);
    let u = `${this.origin}${this.basePath}api/${kind}${encodePath(p)}`;
    if (dir && !u.endsWith('/')) u += '/';
    if (query) u += `?${new URLSearchParams(query)}`;
    return u;
  }

  /** The file's page in File Browser's own web interface. */
  url(path) {
    return `${this.origin}${this.basePath}files${encodePath(normalizePath(path))}`;
  }

  async signIn(force = false) {
    if (this.token && !force) return this.token;
    if (!this.signingIn) {
      this.signingIn = (async () => {
        let res;
        try {
          res = await fetch(`${this.origin}${this.basePath}api/login`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ username: this.username, password: this.password, recaptcha: '' }),
            credentials: 'omit',
            cache: 'no-store',
          });
        } catch {
          throw new WebDAVError(describeStatus(0), { status: 0, retryable: true });
        }
        // File Browser answers 403 to a wrong username or password.
        if (res.status === 403 || res.status === 401) throw new WebDAVError(describeStatus(401), { status: 401 });
        if (!res.ok) throw new WebDAVError(describeStatus(res.status, 'POST'), { status: res.status, retryable: res.status >= 500 });
        const token = (await res.text()).trim();
        if (token.split('.').length !== 3) throw new WebDAVError('The NAS answered the sign-in with something unexpected (is this File Browser?)');
        this.token = token;
        return token;
      })().finally(() => {
        this.signingIn = null;
      });
    }
    return this.signingIn;
  }

  /** A signed-in request; signs in again once if the token ran out. */
  async send(method, url, opts = {}) {
    const go = async () => xhrSend(method, url, { ...opts, headers: { ...(opts.headers || {}), 'X-Auth': await this.signIn() } });
    try {
      return await go();
    } catch (err) {
      if (err.status !== 401) throw err;
      this.token = null;
      await this.signIn(true);
      return go();
    }
  }

  async list(path, opts = {}) {
    const res = await this.send('GET', this.api('resources', path, { dir: true }), { ...opts, timeout: 300000 });
    let data;
    try {
      data = JSON.parse(res.text);
    } catch {
      throw new WebDAVError('The NAS sent a folder listing that could not be read (is this really File Browser?)');
    }
    if (!data.isDir) return [];
    const folder = normalizePath(path);
    return (data.items || []).map((it) => {
      const p = normalizePath(`${folder}/${it.name}`);
      const modified = it.modified ? new Date(it.modified) : null;
      return { path: p, name: it.name, isDir: !!it.isDir, size: it.isDir ? null : Number(it.size) || 0, modified: modified && !Number.isNaN(modified.getTime()) ? modified : null };
    });
  }

  /** Info about a path, or null when it doesn't exist (read from its folder's listing: never the file itself). */
  async stat(path, opts = {}) {
    const p = normalizePath(path);
    if (p === '/') return { path: '/', name: '', isDir: true, size: null, modified: null };
    try {
      const entries = await this.list(parentPath(p), opts);
      return entries.find((e) => e.name === baseName(p)) || null;
    } catch (err) {
      if (err.status === 404) return null;
      throw err;
    }
  }

  /** Create a folder (and any missing parents). Resolves to 'created' or 'exists'. */
  async mkdir(path, opts = {}) {
    const p = normalizePath(path);
    if (p === '/') return 'exists';
    const info = await this.stat(p, opts);
    if (info?.isDir) return 'exists';
    if (info) throw new WebDAVError(`A file named "${baseName(p)}" already exists where a folder is needed`, { status: 409 });
    await this.send('POST', this.api('resources', p, { dir: true }), opts);
    return 'created';
  }

  /** Upload a File/Blob to path (overwrites; missing folders are made). */
  upload(path, file, { onProgress, signal } = {}) {
    return this.send('POST', this.api('resources', path, { query: { override: 'true' } }), {
      headers: { 'Content-Type': 'application/octet-stream' },
      body: file,
      timeout: 0,
      signal,
      onUploadProgress: onProgress,
    });
  }

  async remove(path, { ignoreMissing = false, ...opts } = {}) {
    const p = normalizePath(path);
    if (p === '/') throw new WebDAVError('Refusing to delete the root folder');
    try {
      await this.send('DELETE', this.api('resources', p), opts);
    } catch (err) {
      if (ignoreMissing && err.status === 404) return;
      throw err;
    }
  }

  /** Server-side rename/move. Never overwrites: fails if the destination exists. */
  async move(from, to, { dir: _dir, ...opts } = {}) {
    const src = normalizePath(from);
    const dst = normalizePath(to);
    if (src === '/' || dst === '/') throw new WebDAVError('Refusing to move the root folder');
    try {
      await this.send('PATCH', this.api('resources', src, { query: { action: 'rename', destination: dst, override: 'false', rename: 'false' } }), opts);
    } catch (err) {
      if (err.status === 409) throw new WebDAVError(`"${baseName(dst)}" already exists on the NAS`, { status: 412 });
      throw err;
    }
  }

  async getText(path, opts = {}) {
    try {
      const res = await this.send('GET', this.api('raw', path), { headers: { 'Cache-Control': 'no-cache' }, ...opts });
      return res.text;
    } catch (err) {
      if (err.status === 404) return null;
      throw err;
    }
  }

  async getBlob(path, opts = {}) {
    try {
      const res = await this.send('GET', this.api('raw', path), { headers: { 'Cache-Control': 'no-cache' }, responseType: 'blob', timeout: 600000, ...opts });
      const lm = Date.parse(res.lastModified || '') || Date.now();
      return new File([res.response], baseName(normalizePath(path)), { lastModified: lm, type: res.response?.type || '' });
    } catch (err) {
      if (err.status === 404) return null;
      throw err;
    }
  }

  putText(path, text, { contentType = 'application/json; charset=utf-8', ...opts } = {}) {
    return this.send('POST', this.api('resources', path, { query: { override: 'true' } }), { headers: { 'Content-Type': contentType }, body: text, ...opts });
  }

  /** Where Chrome's download manager can fetch a file from, with the session token it needs. */
  async downloadInfo(path) {
    const token = await this.signIn();
    return { url: this.api('raw', path), headers: [{ name: 'X-Auth', value: token }] };
  }
}
