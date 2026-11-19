// A stand-in for File Browser (filebrowser.org) v2.63's HTTP API, following its source (http/auth.go,
// http/resource.go, http/raw.go): JSON sign-in returning a JWT-shaped token (X-Auth header), folder listings,
// uploads that make missing folders, mkdir with a trailing "/", rename refusing an existing destination (409),
// delete (204), raw downloads with Last-Modified. Files live in a real folder, so tests can compare trees.
//   const fb = await startFileBrowser({ root, port, username, password }); … fb.expireTokens(); await fb.close();
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function startFileBrowser({ root, port = 0, username, password, name = 'Mark NAS' }) {
  fs.mkdirSync(root, { recursive: true });
  const tokens = new Set();
  const requests = [];
  const page = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${name}</title></head><body><div id="app"></div>
<script>window.FileBrowser = {"AuthMethod":"json","BaseURL":"","DisableExternal":false,"LoginPage":true,"Name":"${name}","NoAuth":false,"Signup":false,"StaticURL":"/static","Version":"2.63.23"};</script></body></html>`;

  // URL path → a path inside root (never outside it).
  const inRoot = (p) => {
    const rel = path.posix.normalize('/' + decodeURIComponent(p)).replace(/^\/+/, '');
    const full = path.join(root, rel);
    if (full !== root && !full.startsWith(root + path.sep)) throw Object.assign(new Error('outside'), { status: 403 });
    return full;
  };
  const info = (full, rel) => {
    const st = fs.statSync(full);
    return { path: rel, name: path.basename(full), size: st.isDirectory() ? 4096 : st.size, extension: st.isDirectory() ? '' : path.extname(full), modified: st.mtime.toISOString(), mode: st.mode, isDir: st.isDirectory(), isSymlink: false, type: st.isDirectory() ? '' : 'blob' };
  };
  const send = (res, status, body = '', headers = {}) => {
    res.writeHead(status, { 'Content-Type': typeof body === 'string' && body.startsWith('{') ? 'application/json; charset=utf-8' : 'text/plain; charset=utf-8', ...headers });
    res.end(body);
  };

  const server = http.createServer(async (req, res) => {
    const u = new URL(req.url, 'http://x');
    requests.push({ method: req.method, path: u.pathname, query: Object.fromEntries(u.searchParams) });
    try {
      if (req.method === 'GET' && (u.pathname === '/' || u.pathname.startsWith('/files') || u.pathname === '/login')) {
        return send(res, 200, page, { 'Content-Type': 'text/html; charset=utf-8' });
      }
      if (u.pathname === '/api/login' && req.method === 'POST') {
        let body = '';
        for await (const c of req) body += c;
        let cred = {};
        try {
          cred = JSON.parse(body);
        } catch {
          return send(res, 400, '400 Bad Request');
        }
        if (cred.username !== username || cred.password !== password) return send(res, 403, '403 Forbidden');
        const token = ['eyJhbGciOiJIUzI1NiJ9', Buffer.from(JSON.stringify({ u: username, n: crypto.randomUUID() })).toString('base64url'), crypto.randomBytes(16).toString('base64url')].join('.');
        tokens.add(token);
        return send(res, 200, token);
      }
      if (u.pathname.startsWith('/api/')) {
        const token = req.headers['x-auth'];
        if (!token || !tokens.has(token)) return send(res, 401, '401 Unauthorized');
      }
      const resource = /^\/api\/resources(\/.*)?$/.exec(u.pathname);
      const raw = /^\/api\/raw(\/.*)?$/.exec(u.pathname);
      if (resource) {
        const urlPath = resource[1] || '/';
        const full = inRoot(urlPath);
        const rel = path.posix.normalize('/' + decodeURIComponent(urlPath));
        if (req.method === 'GET') {
          if (!fs.existsSync(full)) return send(res, 404, '404 Not Found');
          const me = info(full, rel);
          if (me.isDir) {
            const items = fs.readdirSync(full).sort().map((n) => info(path.join(full, n), path.posix.join(rel, n)));
            return send(res, 200, JSON.stringify({ ...me, items, numDirs: items.filter((i) => i.isDir).length, numFiles: items.filter((i) => !i.isDir).length, sorting: { by: 'name', asc: true } }));
          }
          return send(res, 200, JSON.stringify(me));
        }
        if (req.method === 'POST') {
          if (urlPath.endsWith('/')) {
            if (fs.existsSync(full) && !fs.statSync(full).isDirectory()) return send(res, 500, '500 Internal Server Error');
            fs.mkdirSync(full, { recursive: true });
            return send(res, 200, '200 OK');
          }
          if (fs.existsSync(full) && u.searchParams.get('override') !== 'true') return send(res, 409, '409 Conflict');
          fs.mkdirSync(path.dirname(full), { recursive: true });
          await new Promise((resolve, reject) => {
            const out = fs.createWriteStream(full);
            req.pipe(out);
            out.on('finish', resolve);
            out.on('error', reject);
            req.on('error', reject);
          });
          return send(res, 200, '200 OK');
        }
        if (req.method === 'DELETE') {
          if (rel === '/') return send(res, 403, '403 Forbidden');
          if (!fs.existsSync(full)) return send(res, 404, '404 Not Found');
          fs.rmSync(full, { recursive: true, force: true });
          return send(res, 204, '');
        }
        if (req.method === 'PATCH') {
          const dstRel = path.posix.normalize('/' + (u.searchParams.get('destination') || ''));
          if (rel === '/' || dstRel === '/') return send(res, 403, '403 Forbidden');
          if (dstRel === rel || dstRel.startsWith(rel + '/')) return send(res, 400, '400 Bad Request');
          const dst = inRoot(encodeURIComponent(dstRel).replace(/%2F/g, '/'));
          if (!fs.existsSync(full)) return send(res, 404, '404 Not Found');
          if (u.searchParams.get('override') !== 'true' && fs.existsSync(dst)) return send(res, 409, '409 Conflict');
          if (u.searchParams.get('action') !== 'rename') return send(res, 400, '400 Bad Request');
          fs.mkdirSync(path.dirname(dst), { recursive: true });
          fs.renameSync(full, dst);
          return send(res, 200, '200 OK');
        }
        return send(res, 405, '405 Method Not Allowed');
      }
      if (raw && req.method === 'GET') {
        const full = inRoot(raw[1] || '/');
        if (!fs.existsSync(full) || fs.statSync(full).isDirectory()) return send(res, 404, '404 Not Found');
        const st = fs.statSync(full);
        res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': st.size, 'Last-Modified': st.mtime.toUTCString(), 'Content-Disposition': `attachment; filename*=utf-8''${encodeURIComponent(path.basename(full))}` });
        return fs.createReadStream(full).pipe(res);
      }
      return send(res, 404, '404 Not Found');
    } catch (err) {
      return send(res, err.status || 500, `${err.status || 500} ${err.message}`);
    }
  });
  return new Promise((resolve) => {
    server.listen(port, '127.0.0.1', () => {
      const p = server.address().port;
      resolve({
        url: `http://127.0.0.1:${p}/`,
        requests,
        expireTokens: () => tokens.clear(),
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

module.exports = { startFileBrowser };
