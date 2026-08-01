'use strict';

/**
 * Camera proxy. Browsers can't fetch a local camera directly (mixed content,
 * no cross-origin auth, private-network-access blocks), so the server fetches
 * the camera's HTTP snapshot / MJPEG stream and pipes it back to the page.
 * Handles HTTP Basic and Digest (MD5) authentication.
 */

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const { URL } = require('url');

// Common snapshot/stream paths, tried in order when the user hasn't set one.
const COMMON_SNAPSHOT_PATHS = [
  '/Streaming/channels/1/picture',        // Hikvision
  '/cgi-bin/snapshot.cgi',                // Dahua / generic
  '/onvif-http/snapshot',                 // ONVIF-ish
  '/tmpfs/auto.jpg',                      // Reolink / generic
  '/snap.jpg',
  '/snapshot.jpg',
  '/image/jpeg.cgi',
  '/axis-cgi/jpg/image.cgi',              // Axis
  '/cgi-bin/api.cgi?cmd=Snap&channel=0',  // Reolink
];

const COMMON_MJPEG_PATHS = [
  '/videostream.cgi',
  '/mjpg/video.mjpg',                     // Axis
  '/cgi-bin/mjpg/video.cgi',
  '/video.mjpg',
];

function md5(s) { return crypto.createHash('md5').update(s).digest('hex'); }

function parseAuthHeader(header) {
  const out = {};
  const scheme = header.split(' ')[0];
  out.scheme = scheme;
  const rest = header.slice(scheme.length);
  const re = /(\w+)=(?:"([^"]*)"|([^,\s]+))/g;
  let m;
  while ((m = re.exec(rest))) out[m[1]] = m[2] !== undefined ? m[2] : m[3];
  return out;
}

function digestHeader(auth, { user, pass, method, uri }) {
  const ha1 = md5(`${user}:${auth.realm}:${pass}`);
  const ha2 = md5(`${method}:${uri}`);
  const nc = '00000001';
  const cnonce = crypto.randomBytes(8).toString('hex');
  let response;
  const parts = [`username="${user}"`, `realm="${auth.realm}"`, `nonce="${auth.nonce}"`, `uri="${uri}"`];
  if (auth.qop) {
    response = md5(`${ha1}:${auth.nonce}:${nc}:${cnonce}:${auth.qop.split(',')[0]}:${ha2}`);
    parts.push(`qop=${auth.qop.split(',')[0]}`, `nc=${nc}`, `cnonce="${cnonce}"`);
  } else {
    response = md5(`${ha1}:${auth.nonce}:${ha2}`);
  }
  parts.push(`response="${response}"`);
  if (auth.opaque) parts.push(`opaque="${auth.opaque}"`);
  return 'Digest ' + parts.join(', ');
}

/**
 * Proxy a single camera URL to `clientRes`, handling auth. Pipes the upstream
 * body straight through, so it works for both single JPEG snapshots and
 * multipart MJPEG streams.
 */
function proxy(urlStr, { user, pass } = {}, clientRes) {
  let u;
  try { u = new URL(urlStr); } catch (_) { clientRes.writeHead(400); return clientRes.end('bad url'); }
  const lib = u.protocol === 'https:' ? https : http;
  const uri = u.pathname + u.search;

  const doRequest = (extraHeaders) => {
    const headers = { ...extraHeaders };
    if (user && !headers.Authorization) {
      headers.Authorization = 'Basic ' + Buffer.from(`${user}:${pass || ''}`).toString('base64');
    }
    const req = lib.request(
      { host: u.hostname, port: u.port || (lib === https ? 443 : 80), path: uri, method: 'GET', headers, timeout: 8000, rejectUnauthorized: false },
      (res) => {
        if (res.statusCode === 401 && !extraHeaders && res.headers['www-authenticate'] && user) {
          const auth = parseAuthHeader(res.headers['www-authenticate']);
          if (/digest/i.test(auth.scheme)) {
            res.resume();
            return doRequest({ Authorization: digestHeader(auth, { user, pass: pass || '', method: 'GET', uri }) });
          }
        }
        if (res.statusCode >= 400) {
          clientRes.writeHead(res.statusCode, { 'Content-Type': 'text/plain' });
          return clientRes.end(`camera returned HTTP ${res.statusCode}`);
        }
        clientRes.writeHead(200, {
          'Content-Type': res.headers['content-type'] || 'image/jpeg',
          'Cache-Control': 'no-store',
        });
        res.pipe(clientRes);
      }
    );
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', (e) => {
      if (!clientRes.headersSent) clientRes.writeHead(502, { 'Content-Type': 'text/plain' });
      clientRes.end('camera unreachable: ' + e.message);
    });
    req.end();
  };

  doRequest();
}

module.exports = { proxy, COMMON_SNAPSHOT_PATHS, COMMON_MJPEG_PATHS };
