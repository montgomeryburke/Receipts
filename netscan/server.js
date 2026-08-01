'use strict';

/**
 * netscan — local network device discovery & control.
 *
 * A tiny zero-dependency Node HTTP server that:
 *   - serves the web UI in public/
 *   - runs multi-protocol device discovery on your LAN (mDNS, SSDP, ONVIF,
 *     TP-Link Kasa, WiZ, Shelly)
 *   - exposes control endpoints for switches & lights
 *   - proxies camera snapshots / MJPEG streams so they render in the browser
 *
 * Runs entirely on your machine against your own network. Nothing is sent to
 * any cloud service.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const { Registry } = require('./lib/registry');
const { runScan } = require('./lib/scan');
const kasa = require('./lib/kasa');
const wiz = require('./lib/wiz');
const shelly = require('./lib/shelly');
const camera = require('./lib/camera');
const net = require('./lib/net');

const PORT = process.env.PORT ? parseInt(process.env.PORT, 10) : 8137;
const HOST = process.env.HOST || '127.0.0.1';
const PUBLIC_DIR = path.join(__dirname, 'public');

const registry = new Registry();
const cameraCreds = new Map(); // deviceId -> { user, pass, path }

const CONTROLLERS = { kasa, wiz, shelly };

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try { resolve(JSON.parse(raw)); } catch (_) { resolve({}); }
    });
    req.on('error', () => resolve({}));
  });
}

function serveStatic(req, res, pathname) {
  let rel = pathname === '/' ? '/index.html' : pathname;
  const filePath = path.normalize(path.join(PUBLIC_DIR, rel));
  if (!filePath.startsWith(PUBLIC_DIR)) { res.writeHead(403); return res.end('forbidden'); }
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); return res.end('not found'); }
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
}

function controllerFor(dev) {
  return CONTROLLERS[dev.protocol] || null;
}

const server = http.createServer(async (req, res) => {
  const parsed = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = parsed.pathname;

  try {
    // ---- API ----
    if (pathname === '/api/interfaces' && req.method === 'GET') {
      return sendJson(res, 200, { interfaces: net.ipv4Interfaces() });
    }

    if (pathname === '/api/scan' && req.method === 'POST') {
      const deep = parsed.searchParams.get('deep') === '1';
      const result = await runScan(registry, { deep, now: nowMs(), timeoutMs: 3000 });
      return sendJson(res, 200, result);
    }

    if (pathname === '/api/devices' && req.method === 'GET') {
      return sendJson(res, 200, { devices: registry.list() });
    }

    const ctrl = pathname.match(/^\/api\/devices\/([^/]+)\/(power|brightness|color|colortemp|refresh)$/);
    if (ctrl && req.method === 'POST') {
      const dev = registry.get(ctrl[1]);
      if (!dev) return sendJson(res, 404, { error: 'device not found' });
      const controller = controllerFor(dev);
      if (!controller) return sendJson(res, 400, { error: `no controller for protocol ${dev.protocol}` });
      const body = await readBody(req);
      try {
        const action = ctrl[2];
        if (action === 'power') { await controller.setPower(dev, !!body.on); dev.state.on = !!body.on; }
        else if (action === 'brightness') { if (controller.setBrightness) { await controller.setBrightness(dev, body.pct); dev.state.brightness = body.pct; } }
        else if (action === 'color') { if (controller.setColor) { await controller.setColor(dev, body); dev.state.rgb = [body.r, body.g, body.b]; } }
        else if (action === 'colortemp') { if (controller.setColorTemp) { await controller.setColorTemp(dev, body.kelvin); dev.state.colorTemp = body.kelvin; } }
        return sendJson(res, 200, { ok: true, state: dev.state });
      } catch (e) {
        return sendJson(res, 502, { error: e.message });
      }
    }

    const credMatch = pathname.match(/^\/api\/camera\/([^/]+)\/creds$/);
    if (credMatch && req.method === 'POST') {
      const body = await readBody(req);
      cameraCreds.set(credMatch[1], { user: body.user || '', pass: body.pass || '', path: body.path || '' });
      return sendJson(res, 200, { ok: true });
    }

    const camMatch = pathname.match(/^\/api\/camera\/([^/]+)\/(snapshot|stream)$/);
    if (camMatch && req.method === 'GET') {
      const dev = registry.get(camMatch[1]);
      if (!dev || !dev.ip) return sendJson(res, 404, { error: 'camera not found' });
      const creds = cameraCreds.get(camMatch[1]) || {};
      const override = parsed.searchParams.get('path') || creds.path;
      const scheme = camMatch[2];
      const candidates = override
        ? [override]
        : (scheme === 'stream' ? camera.COMMON_MJPEG_PATHS : camera.COMMON_SNAPSHOT_PATHS);
      const port = dev.port && dev.port !== 9999 ? dev.port : 80;
      const target = `http://${dev.ip}:${port}${candidates[0]}`;
      return camera.proxy(target, {
        user: parsed.searchParams.get('user') || creds.user,
        pass: parsed.searchParams.get('pass') || creds.pass,
      }, res);
    }

    // ---- static ----
    if (req.method === 'GET') return serveStatic(req, res, pathname);

    res.writeHead(405); res.end('method not allowed');
  } catch (e) {
    if (!res.headersSent) sendJson(res, 500, { error: e.message });
    else res.end();
  }
});

// Date.now is available in Node; wrapper keeps a single call site.
function nowMs() { return Date.now(); }

server.listen(PORT, HOST, () => {
  const ifaces = net.ipv4Interfaces();
  console.log(`\n  netscan running →  http://${HOST}:${PORT}\n`);
  console.log('  Local network interfaces detected:');
  if (ifaces.length === 0) console.log('    (none found — are you connected to a network?)');
  for (const i of ifaces) console.log(`    ${i.name.padEnd(12)} ${i.address}/${maskBits(i.netmask)}  broadcast ${i.broadcast}`);
  console.log('\n  Open the URL above, then click "Scan network".\n');
});

function maskBits(mask) {
  return mask.split('.').reduce((acc, o) => acc + ((parseInt(o, 10).toString(2).match(/1/g) || []).length), 0);
}
