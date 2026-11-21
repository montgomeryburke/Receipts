// Test-only stand-in for duckdns.org's update API. TXT updates are passed to Pebble's test DNS server
// (pebble-challtestsrv), so Let's Encrypt's test CA (Pebble) can validate the DNS challenge.
//   node mock-duckdns.cjs --listen 18600 --token TOKEN --challtestsrv http://127.0.0.1:8055
const http = require('http');
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, v, i, a) => (v.startsWith('--') ? [...acc, [v.slice(2), a[i + 1]]] : acc), []));
const post = (path, body) =>
  new Promise((resolve, reject) => {
    const u = new URL(path, args.challtestsrv);
    const req = http.request(u, { method: 'POST', headers: { 'Content-Type': 'application/json' } }, (res) => {
      res.resume();
      res.on('end', () => (res.statusCode < 300 ? resolve() : reject(new Error('challtestsrv ' + res.statusCode))));
    });
    req.on('error', reject);
    req.end(JSON.stringify(body));
  });
http
  .createServer(async (req, res) => {
    const u = new URL(req.url, 'http://x');
    const q = Object.fromEntries(u.searchParams);
    const reply = (t) => {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end(t);
    };
    console.log(new Date().toISOString(), u.pathname, { ...q, token: q.token === args.token ? '(ok)' : '(wrong)' });
    if (u.pathname !== '/update' || q.token !== args.token || !q.domains) return reply('KO');
    const host = `_acme-challenge.${q.domains}.duckdns.org.`;
    try {
      if (q.clear === 'true') await post('/clear-txt', { host });
      else if (q.txt) await post('/set-txt', { host, value: q.txt });
      reply('OK');
    } catch (e) {
      console.error(e);
      reply('KO');
    }
  })
  .listen(Number(args.listen), '127.0.0.1', () => console.log('mock duckdns on', args.listen));
