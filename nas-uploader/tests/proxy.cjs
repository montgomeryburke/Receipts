// Test-only HTTP proxy that sits in front of a WebDAV server and misbehaves on purpose:
//   --mode flaky     : first attempt of some PUTs gets a 503 or a dropped connection; some PROPFINDs get a 502;
//                      any PUT whose path contains "FORBIDDEN" always gets a 403.
//   --mode throttle  : passes everything through but limits upload speed (--rate bytes/sec).
// Usage: node proxy.cjs --listen 18084 --target 18081 --mode flaky
const http = require('http');

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, v, i, a) => (v.startsWith('--') ? [...acc, [v.slice(2), a[i + 1]]] : acc), []),
);
const LISTEN = Number(args.listen);
const TARGET = Number(args.target);
const MODE = args.mode || 'flaky';
const RATE = Number(args.rate || 4 * 1024 * 1024);

const attempts = new Map();
const stats = { putBytes: 0, putStarted: 0, putAborted: 0, injected503: 0, injectedDrop: 0, injected502: 0, forbidden: 0 };

function hash(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619) >>> 0;
  return h;
}

function forward(req, res, bodySource) {
  const up = http.request({ host: '127.0.0.1', port: TARGET, method: req.method, path: req.url, headers: req.headers }, (upRes) => {
    res.writeHead(upRes.statusCode, upRes.headers);
    upRes.pipe(res);
  });
  up.on('error', () => res.destroy());
  bodySource.pipe(up);
}

function throttled(req) {
  const { PassThrough } = require('stream');
  const out = new PassThrough();
  let allowance = RATE / 10;
  const queue = [];
  let ended = false;
  const timer = setInterval(() => {
    allowance = RATE / 10;
    flush();
  }, 100);
  function flush() {
    while (queue.length && allowance > 0) {
      let chunk = queue[0];
      if (chunk.length > allowance) {
        out.write(chunk.subarray(0, allowance));
        queue[0] = chunk.subarray(allowance);
        allowance = 0;
      } else {
        out.write(chunk);
        allowance -= chunk.length;
        queue.shift();
      }
    }
    if (!queue.length && req.isPaused()) req.resume();
    if (ended && !queue.length) {
      clearInterval(timer);
      out.end();
    }
  }
  req.on('data', (c) => {
    stats.putBytes += c.length;
    queue.push(c);
    if (queue.length > 4) req.pause();
    flush();
  });
  req.on('end', () => {
    ended = true;
    flush();
  });
  req.on('close', () => {
    if (!ended) {
      clearInterval(timer);
      out.destroy();
    }
  });
  return out;
}

const server = http.createServer((req, res) => {
  if (req.url === '/__proxy_stats') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(stats));
    return;
  }
  if (req.method === 'PUT') {
    stats.putStarted++;
    req.on('close', () => {
      if (!req.complete) stats.putAborted++;
    });
  }
  const key = req.method + ' ' + req.url;
  const n = (attempts.get(key) || 0) + 1;
  attempts.set(key, n);

  if (MODE === 'flaky') {
    const h = hash(req.url);
    if (req.method === 'PUT') {
      if (decodeURIComponent(req.url).includes('FORBIDDEN')) {
        stats.forbidden++;
        req.resume();
        req.on('end', () => {
          res.writeHead(403, { 'Content-Type': 'text/plain' });
          res.end('Forbidden');
        });
        return;
      }
      if (n === 1 && h % 3 === 0) {
        stats.injected503++;
        req.resume();
        req.on('end', () => {
          res.writeHead(503, { 'Content-Type': 'text/plain' });
          res.end('Busy');
        });
        return;
      }
      if (n === 1 && h % 5 === 1) {
        stats.injectedDrop++;
        let got = 0;
        req.on('data', (c) => {
          got += c.length;
          if (got > 2048) req.socket.destroy();
        });
        req.on('end', () => req.socket.destroy());
        return;
      }
    }
    if (req.method === 'PROPFIND' && n === 1 && h % 4 === 0) {
      stats.injected502++;
      req.resume();
      req.on('end', () => {
        res.writeHead(502, { 'Content-Type': 'text/plain' });
        res.end('Bad gateway');
      });
      return;
    }
    if (req.method === 'PUT') req.on('data', (c) => (stats.putBytes += c.length));
    forward(req, res, req);
    return;
  }
  if (MODE === 'throttle' && req.method === 'PUT') {
    forward(req, res, throttled(req));
    return;
  }
  forward(req, res, req);
});
server.listen(LISTEN, '127.0.0.1', () => console.log(`proxy ${MODE} :${LISTEN} -> :${TARGET}`));
