// End-to-end tests: loads the real extension into Chromium and talks to real WebDAV servers.
// Prerequisites: ./start-servers.sh is running, and `node make-dataset.cjs <work>/dataset` was run.
//   NAS_TEST_WORK=<dir> node e2e.cjs [filter]
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const crypto = require('crypto');

const EXT_SRC = path.resolve(process.env.NAS_EXT_SRC || path.join(__dirname, '../extension'));
const WORK = path.resolve(process.env.NAS_TEST_WORK || fs.mkdtempSync(path.join(os.tmpdir(), 'nas-e2e-')));
const DATA = process.env.NAS_TEST_DATA || '/var/tmp/nas-uploader-test';
const DS = path.join(WORK, 'dataset');
const SHOTS = path.join(WORK, 'screenshots');
const USER = 'nasuser';
const PASSWORD = process.env.NAS_TEST_PASSWORD || 'pässwörd:with colon';
const FILTER = process.argv[2] ? new RegExp(process.argv[2], 'i') : null;
fs.mkdirSync(SHOTS, { recursive: true });

const SERVERS = {
  apache: { url: 'http://127.0.0.1:18081/', root: path.join(DATA, 'root1') },
  apacheSub: { url: 'http://127.0.0.1:18082/my dav/', root: path.join(DATA, 'root2') },
  wsgidav: { url: 'http://127.0.0.1:18083/', root: path.join(DATA, 'root3') },
  flaky: { url: 'http://127.0.0.1:18084/', root: path.join(DATA, 'root1'), proxyPort: 18084 },
  throttle: { url: 'http://127.0.0.1:18085/', root: path.join(DATA, 'root1'), proxyPort: 18085 },
};

// ---------------------------------------------------------------------------
// tiny test harness
// ---------------------------------------------------------------------------
const results = [];
const tests = [];
function test(name, fn) {
  tests.push({ name, fn });
}
function assert(cond, msg) {
  if (!cond) throw new Error('Assertion failed: ' + msg);
}
function eq(a, b, msg) {
  if (a !== b) throw new Error(`Assertion failed: ${msg} — expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}
const log = (...a) => console.log('   ', ...a);

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
const browsers = [];
let extCounter = 0;

async function launch(config, { colorScheme } = {}) {
  const name = `${++extCounter}`;
  const ext = path.join(WORK, 'ext-' + name);
  fs.rmSync(ext, { recursive: true, force: true });
  fs.cpSync(EXT_SRC, ext, { recursive: true });
  if (config) fs.writeFileSync(path.join(ext, 'config.js'), 'export const CONFIG = ' + JSON.stringify(config, null, 2) + ';\n');
  const udd = path.join(WORK, 'profile-' + name);
  fs.rmSync(udd, { recursive: true, force: true });
  const ctx = await chromium.launchPersistentContext(udd, {
    channel: 'chromium',
    headless: !process.env.HEADED,
    viewport: { width: 1280, height: 860 },
    colorScheme,
    acceptDownloads: true,
    // Real desktops use a Unicode locale; without one Chromium on Linux cannot read non-ASCII file names.
    env: { ...process.env, LANG: 'C.UTF-8' },
    args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`],
  });
  browsers.push(ctx);
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker');
  const id = sw.url().split('/')[2];
  const appUrl = `chrome-extension://${id}/app.html`;
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('dialog', (d) => {
    errors.push('Unexpected native dialog: ' + d.message());
    d.dismiss();
  });
  await page.goto(appUrl);
  return { ctx, page, sw, id, appUrl, errors };
}

function cfg(server, extra = {}) {
  return { serverUrl: SERVERS[server].url, username: USER, password: PASSWORD, startFolder: '/', parallelUploads: 3, ...extra };
}

async function waitConnected(page) {
  await page.waitForSelector('#app:not([hidden])', { timeout: 15000 });
  await page.waitForFunction(() => document.getElementById('listing-loading').hidden, null, { timeout: 15000 });
}

async function goTo(page, folder) {
  await page.evaluate((f) => {
    location.hash = '#' + f.split('/').map(encodeURIComponent).join('/');
  }, folder);
  await page.waitForFunction((f) => window.nasUploader.cwd === f && document.getElementById('listing-loading').hidden, folder, { timeout: 15000 });
}

async function listingNames(page) {
  return page.$$eval('#listing-body tr', (rows) => rows.map((r) => r.dataset.name));
}

async function drop(page, paths) {
  const cdp = await page.context().newCDPSession(page);
  const box = await page.locator('#dropzone').boundingBox();
  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  const data = { items: [], files: paths, dragOperationsMask: 1 };
  await cdp.send('Input.dispatchDragEvent', { type: 'dragEnter', x, y, data });
  await cdp.send('Input.dispatchDragEvent', { type: 'dragOver', x, y, data });
  await cdp.send('Input.dispatchDragEvent', { type: 'drop', x, y, data });
  await cdp.detach();
}

function currentRun(page) {
  return page.evaluate(() => window.nasUploader.manager?.runs ?? 0);
}

/** Waits for the "Ready to upload" dialog, returns its text and clicks Upload. */
async function confirmUpload(page) {
  page.__run = await currentRun(page);
  await page.waitForSelector('dialog[open]', { timeout: 120000 });
  const title = await page.textContent('#dialog-title');
  const text = await page.textContent('#dialog-body');
  if (title !== 'Ready to upload') {
    await page.click('#dialog-cancel').catch(() => {});
    throw new Error(`Expected the upload confirmation, got "${title}": ${text}`);
  }
  await page.click('#dialog-ok');
  return text;
}

/** Waits until the run started by the last confirmUpload()/retry click has finished. */
async function waitFinished(page, timeout = 300000) {
  await page.waitForFunction((run) => window.nasUploader.manager?.runs > run && ['done', 'cancelled'].includes(window.nasUploader.manager.state), page.__run ?? 0, { timeout, polling: 250 });
  await page.waitForTimeout(400); // let the panel render
  return stats(page);
}

function stats(page) {
  return page.evaluate(() => {
    const s = window.nasUploader.manager.stats();
    return { ...s, eta: null };
  });
}

function failedList(page) {
  return page.evaluate(() => window.nasUploader.manager.failedTasks().map((t) => ({ rel: t.rel, error: t.error })));
}

const JUNK_FILES = new Set(['.ds_store', 'thumbs.db', 'ehthumbs.db', 'desktop.ini']);
const isJunk = (n) => JUNK_FILES.has(n.toLowerCase()) || n.startsWith('._');

function walk(dir, { skipJunk = true } = {}) {
  const files = new Map();
  const dirs = new Set();
  const rec = (abs, rel) => {
    for (const d of fs.readdirSync(abs, { withFileTypes: true })) {
      const r = rel ? rel + '/' + d.name : d.name;
      const a = path.join(abs, d.name);
      if (d.isDirectory()) {
        dirs.add(r);
        rec(a, r);
      } else if (!(skipJunk && isJunk(d.name))) files.set(r, a);
    }
  };
  rec(dir, '');
  return { files, dirs };
}

function sha256(file) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    fs.createReadStream(file).on('data', (c) => h.update(c)).on('end', () => resolve(h.digest('hex'))).on('error', reject);
  });
}

/** Byte-for-byte comparison of a local tree with what landed on the server. */
async function assertSameTree(src, dst, { ignoreEmptyDirs = false, exclude = [] } = {}) {
  assert(fs.existsSync(dst), `destination ${dst} exists`);
  const a = walk(src);
  // Apache writes uploads to .davfs.tmp* files and removes them when an aborted upload's connection closes.
  // Our test proxies can hold such connections open for a few seconds after a pause/cancel, so allow that.
  const isTmp = (rel) => /(^|\/)\.davfs\.tmp/.test(rel);
  let b = walk(dst, { skipJunk: false });
  for (let i = 0; i < 60 && [...b.files.keys()].some(isTmp); i++) {
    await new Promise((r) => setTimeout(r, 500));
    b = walk(dst, { skipJunk: false });
  }
  for (const x of exclude) a.files.delete(x);
  const missing = [...a.files.keys()].filter((k) => !b.files.has(k));
  const extra = [...b.files.keys()].filter((k) => !a.files.has(k));
  assert(missing.length === 0, `files missing on NAS: ${missing.slice(0, 10).join(', ')}`);
  assert(extra.length === 0, `unexpected files on NAS: ${extra.slice(0, 10).join(', ')}`);
  if (!ignoreEmptyDirs) {
    const missingDirs = [...a.dirs].filter((d) => !b.dirs.has(d));
    assert(missingDirs.length === 0, `folders missing on NAS: ${missingDirs.slice(0, 10).join(', ')}`);
  }
  let bytes = 0;
  for (const [rel, abs] of a.files) {
    const sa = fs.statSync(abs).size;
    const sb = fs.statSync(b.files.get(rel)).size;
    eq(sb, sa, `size of ${rel}`);
    bytes += sa;
    if ((await sha256(abs)) !== (await sha256(b.files.get(rel)))) throw new Error(`Content differs for ${rel}`);
  }
  return { files: a.files.size, dirs: a.dirs.size, bytes };
}

function dav(server, method, p, body) {
  const u = new URL(SERVERS[server].url);
  const base = u.pathname.endsWith('/') ? u.pathname : u.pathname + '/';
  const fullPath = base + p.replace(/^\//, '').split('/').map(encodeURIComponent).join('/');
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: u.hostname, port: u.port, method, path: fullPath, headers: { Authorization: 'Basic ' + Buffer.from(`${USER}:${PASSWORD}`).toString('base64'), Depth: '1' } },
      (res) => {
        let text = '';
        res.on('data', (c) => (text += c));
        res.on('end', () => resolve({ status: res.statusCode, text }));
      },
    );
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function proxyStats(port) {
  return new Promise((resolve, reject) => {
    http
      .get({ host: '127.0.0.1', port, path: '/__proxy_stats' }, (res) => {
        let t = '';
        res.on('data', (c) => (t += c));
        res.on('end', () => resolve(JSON.parse(t)));
      })
      .on('error', reject);
  });
}

async function shot(page, name) {
  await page.screenshot({ path: path.join(SHOTS, name + '.png'), fullPage: true });
}

const full = path.join(DS, 'full', 'Project Archive');
const small = path.join(DS, 'small', 'Small Set');
const media = path.join(DS, 'media', 'Media Set');
const looseFile = path.join(DS, 'loose', 'single file.pdf');
const hugeFile = path.join(DS, 'huge', 'backup-5GB.tar');
const UPLOAD_DIR = 'Uploads #1 – ünï & co';

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test('unit: path helpers and PROPFIND parsing for different NAS response styles', async () => {
  const { page, errors } = await launch(null);
  const r = await page.evaluate(async () => {
    const u = await import('./lib/util.js');
    const { WebDAVClient } = await import('./lib/webdav.js');
    const out = [];
    const check = (name, got, want) => out.push({ name, ok: JSON.stringify(got) === JSON.stringify(want), got, want });
    check('normalize', u.normalizePath('a//b/./c/'), '/a/b/c');
    check('normalize root', u.normalizePath(''), '/');
    check('normalize dotdot', u.normalizePath('/x/../y'), '/y');
    check('encode', u.encodePath('/a b/#?%/é'), '/a%20b/%23%3F%25/%C3%A9');
    check('join', u.joinPath('/', 'x', 'y z/'), '/x/y z');
    check('parent', [u.parentPath('/a'), u.parentPath('/a/b'), u.parentPath('/')], ['/', '/a', '/']);
    check('basic auth utf8', u.basicAuthHeader('ü', 'p:w'), 'Basic ' + btoa(String.fromCharCode(...new TextEncoder().encode('ü:p:w'))));
    check('junk', [u.isJunkFile('.DS_Store'), u.isJunkFile('thumbs.db'), u.isJunkFile('._x'), u.isJunkFile('photo.jpg'), u.isJunkDir('$RECYCLE.BIN')], [true, true, true, false, true]);
    check('download name', u.sanitizeDownloadName('a/b:c?.txt'), 'a_b_c_.txt');

    const c = new WebDAVClient({ serverUrl: 'https://nas.example.com:5006/dav', username: 'u', password: 'p' });
    check('url', c.url('/Photos/café #1.jpg'), 'https://nas.example.com:5006/dav/Photos/caf%C3%A9%20%231.jpg');
    check('dir url', c.url('/Photos', { dir: true }), 'https://nas.example.com:5006/dav/Photos/');
    const simplify = (es) => es.map((e) => [e.path, e.isDir, e.size]);
    // Synology / Apache style with absolute URLs.
    const a = `<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">
      <D:response><D:href>https://nas.example.com:5006/dav/Photos/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
      <D:response><D:href>https://nas.example.com:5006/dav/Photos/2024%20Trip/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
      <D:response><D:href>https://nas.example.com:5006/dav/Photos/caf%C3%A9%20%231.jpg</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>12345</D:getcontentlength><D:getlastmodified>Sat, 10 Oct 2026 10:00:00 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
    </D:multistatus>`;
    check('absolute hrefs', simplify(c.parseMultistatus(a, '/Photos')), [['/Photos', true, null], ['/Photos/2024 Trip', true, null], ['/Photos/café #1.jpg', false, 12345]]);
    // Default namespace, internal host name, a 404 propstat block.
    const b = `<multistatus xmlns="DAV:"><response><href>http://192.168.1.10:5005/dav/Photos/x.txt</href>
      <propstat><prop><getcontentlength>5</getcontentlength><resourcetype/></prop><status>HTTP/1.1 200 OK</status></propstat>
      <propstat><prop><getlastmodified/></prop><status>HTTP/1.1 404 Not Found</status></propstat></response></multistatus>`;
    const bb = c.parseMultistatus(b, '/Photos');
    check('default ns + 404 propstat', [simplify(bb), bb[0].modified], [[['/Photos/x.txt', false, 5]], null]);
    // Unencoded spaces / unicode in hrefs.
    const d = `<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/Photos/new folder/ü.txt</d:href><d:propstat><d:prop><d:getcontentlength>7</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>`;
    check('unencoded href', simplify(c.parseMultistatus(d, '/Photos/new folder')), [['/Photos/new folder/ü.txt', false, 7]]);
    // Reverse proxy that strips the /dav prefix from hrefs.
    const e = `<d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/Photos/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      <d:response><d:href>/Photos/a.txt</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>3</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
    </d:multistatus>`;
    check('prefix-stripping proxy', simplify(c.parseMultistatus(e, '/Photos').filter((x) => x.path !== '/Photos')), [['/Photos/a.txt', false, 3]]);
    const e2 = `<d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/Photos/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      <d:response><d:href>/Photos/Photos/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
    </d:multistatus>`;
    check('prefix-stripping proxy, same-named subfolder', simplify(c.parseMultistatus(e2, '/Photos')), [['/Photos', true, null], ['/Photos/Photos', true, null]]);
    // Root of a base path given without trailing slash.
    const f = `<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>`;
    check('root without slash', simplify(c.parseMultistatus(f, '/')), [['/', true, null]]);
    let threw = false;
    try {
      c.parseMultistatus('<html><body>Login</body', '/');
    } catch {
      threw = true;
    }
    check('html login page is rejected', threw, true);
    return out;
  });
  const bad = r.filter((x) => !x.ok);
  log(`${r.length - bad.length}/${r.length} checks passed`);
  assert(bad.length === 0, 'failed checks: ' + JSON.stringify(bad, null, 1));
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('shipped config.js (example values) shows the setup screen', async () => {
  const { page, errors } = await launch(null);
  await page.waitForSelector('#setup:not([hidden])', { timeout: 10000 });
  const detail = await page.textContent('#setup-detail');
  assert(detail.includes('serverUrl'), 'setup detail mentions serverUrl: ' + detail);
  eq(await page.isVisible('#app'), false, 'app hidden');
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

let main; // shared Apache session for the main flow
test('connects to NAS (Apache mod_dav at root) and lists folders — no CORS setup needed', async () => {
  await dav('apache', 'MKCOL', 'Existing Share/');
  await dav('apache', 'PUT', 'Existing Share/hello.txt', 'hello!');
  main = await launch(cfg('apache'));
  const { page } = main;
  await waitConnected(page);
  const conn = await page.textContent('#conn-text');
  assert(conn.includes('127.0.0.1:18081') && conn.includes(USER), 'connection label: ' + conn);
  assert((await listingNames(page)).includes('Existing Share'), 'root listing shows Existing Share');
  await page.click('#listing-body tr[data-name="Existing Share"] button.entry');
  await page.waitForFunction(() => window.nasUploader.cwd === '/Existing Share');
  await page.waitForSelector('#listing-body tr[data-name="hello.txt"]');
  const size = await page.textContent('#listing-body tr[data-name="hello.txt"] td.c-size');
  eq(size, '6 B', 'file size shown');
  await page.click('#btn-up');
  await page.waitForFunction(() => window.nasUploader.cwd === '/');
});

test('New folder: validates names and creates a folder with special characters', async () => {
  const { page } = main;
  await page.click('#btn-mkdir');
  await page.waitForSelector('dialog[open]');
  await page.fill('#dialog-input', 'bad/name');
  await page.click('#dialog-ok');
  await page.waitForSelector('#dialog-error:not([hidden])');
  assert((await page.textContent('#dialog-error')).includes('cannot contain'), 'slash rejected');
  await page.fill('#dialog-input', UPLOAD_DIR);
  await page.press('#dialog-input', 'Enter');
  await page.waitForSelector(`#listing-body tr[data-name="${UPLOAD_DIR}"]`);
  assert(fs.statSync(path.join(SERVERS.apache.root, UPLOAD_DIR)).isDirectory(), 'folder exists on server');
  await page.click(`#listing-body tr[data-name="${UPLOAD_DIR}"] button.entry`);
  await page.waitForFunction((d) => window.nasUploader.cwd === '/' + d, UPLOAD_DIR);
  eq(await page.textContent('#dz-dest'), '/' + UPLOAD_DIR, 'drop destination label');
});

let fullCount = 0;
test('drag & drop a whole nested folder tree (2,000+ files, 1.2 GB file, unicode, empty folders) — byte-identical on NAS', async () => {
  const { page, errors } = main;
  const expected = walk(full);
  fullCount = expected.files.size;
  const t0 = Date.now();
  await drop(page, [full]);
  const text = await confirmUpload(page);
  assert(text.includes(`Upload ${fullCount.toLocaleString('en-US')} files`), 'dialog shows file count: ' + text.slice(0, 120));
  assert(text.includes('Leaving out 4 system junk file(s)'), 'dialog mentions junk files');
  await page.waitForFunction(() => window.nasUploader.manager.stats().inflightBytes > 0 || window.nasUploader.manager.state === 'done', null, { timeout: 60000 });
  await shot(page, '01-uploading');
  const s = await waitFinished(page, 900000);
  const secs = (Date.now() - t0) / 1000;
  log(`uploaded ${s.uploadedFiles} files, ${(s.uploadedBytes / 1e6).toFixed(0)} MB in ${secs.toFixed(1)}s`);
  eq(s.state, 'done', 'state');
  eq(s.failedFiles, 0, 'failed files ' + JSON.stringify(await failedList(page)));
  eq(s.uploadedFiles, fullCount, 'uploaded count');
  eq(s.verifiedFiles, fullCount, 'verified count');
  eq(s.dirsFailed, 0, 'dir failures');
  assert(s.dirs >= 3, 'empty folders tracked: ' + s.dirs);
  eq(await page.textContent('#tr-title'), 'All done ✓', 'panel title');
  await shot(page, '02-done');
  const r = await assertSameTree(full, path.join(SERVERS.apache.root, UPLOAD_DIR, 'Project Archive'));
  log(`verified ${r.files} files / ${r.dirs} folders / ${(r.bytes / 1e6).toFixed(0)} MB byte-for-byte`);
  assert((await listingNames(page)).includes('Project Archive'), 'listing refreshed after upload');
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('dropping the same folder again skips everything already on the NAS (resume)', async () => {
  const { page } = main;
  const t0 = Date.now();
  await drop(page, [full]);
  await confirmUpload(page);
  const s = await waitFinished(page);
  log(`re-check of ${s.files} files took ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  eq(s.uploadedFiles, 0, 'uploaded');
  eq(s.skippedFiles, fullCount, 'skipped');
  eq(s.failedFiles, 0, 'failed');
});

test('after an interruption, only missing / incomplete files are uploaded again', async () => {
  const { page } = main;
  const base = path.join(SERVERS.apache.root, UPLOAD_DIR, 'Project Archive');
  // Simulate a half-written file, a missing file and a missing empty folder.
  fs.truncateSync(path.join(base, 'media', 'clip-3.bin'), 1000);
  fs.rmSync(path.join(base, 'many', 'batch 007', 'file-0003.dat'));
  fs.rmSync(path.join(base, 'nested empty'), { recursive: true });
  await drop(page, [full]);
  await confirmUpload(page);
  const s = await waitFinished(page);
  eq(s.uploadedFiles, 2, 'uploaded');
  eq(s.skippedFiles, fullCount - 2, 'skipped');
  eq(s.failedFiles, 0, 'failed');
  await assertSameTree(full, base);
});

test('"Choose a folder" button (folder picker) uploads a tree', async () => {
  const { page } = main;
  await goTo(page, '/' + UPLOAD_DIR);
  await page.setInputFiles('#pick-folder', small);
  await confirmUpload(page);
  const s = await waitFinished(page);
  eq(s.failedFiles, 0, 'failed');
  await assertSameTree(small, path.join(SERVERS.apache.root, UPLOAD_DIR, 'Small Set'), { ignoreEmptyDirs: true });
});

test('"Choose files" button uploads loose files', async () => {
  const { page } = main;
  await page.setInputFiles('#pick-files', looseFile);
  await confirmUpload(page);
  const s = await waitFinished(page);
  eq(s.uploadedFiles, 1, 'uploaded');
  const dst = path.join(SERVERS.apache.root, UPLOAD_DIR, 'single file.pdf');
  eq(await sha256(dst), await sha256(looseFile), 'content');
});

test('download a file from the NAS', async () => {
  const { page } = main;
  await page.waitForSelector('#listing-body tr[data-name="single file.pdf"]');
  await page.click('#listing-body tr[data-name="single file.pdf"] button.dl');
  let d = null;
  for (let i = 0; i < 120 && !d; i++) {
    d = await page.evaluate(async () => {
      const [x] = await chrome.downloads.search({ orderBy: ['-startTime'], limit: 1 });
      return x && x.state === 'complete' ? x : x && x.state === 'interrupted' ? { error: x.error } : null;
    });
    if (!d) await page.waitForTimeout(250);
  }
  assert(d, 'download finished within 30s');
  assert(!d.error, 'download interrupted: ' + d.error);
  eq(d.fileSize, fs.statSync(looseFile).size, 'downloaded size');
  eq(await sha256(d.filename), await sha256(looseFile), 'downloaded content');
});

test('delete a file and a folder from the NAS', async () => {
  const { page, errors } = main;
  await page.click('#listing-body tr[data-name="single file.pdf"] button.del');
  await page.waitForSelector('dialog[open]');
  await page.click('#dialog-ok');
  await page.waitForSelector('#listing-body tr[data-name="single file.pdf"]', { state: 'detached' });
  assert(!fs.existsSync(path.join(SERVERS.apache.root, UPLOAD_DIR, 'single file.pdf')), 'file gone on server');
  await page.click('#listing-body tr[data-name="Small Set"] button.del');
  await page.waitForSelector('dialog[open]');
  assert((await page.textContent('#dialog-body')).includes('everything inside'), 'folder delete warning');
  await page.click('#dialog-ok');
  await page.waitForSelector('#listing-body tr[data-name="Small Set"]', { state: 'detached' });
  assert(!fs.existsSync(path.join(SERVERS.apache.root, UPLOAD_DIR, 'Small Set')), 'folder gone on server');
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('flaky connection: retries 503s, dropped connections and 502s; reports a permanent 403 clearly', async () => {
  await dav('apache', 'MKCOL', 'flaky-test/');
  const { page, errors } = await launch(cfg('flaky'));
  await waitConnected(page);
  await goTo(page, '/flaky-test');
  await drop(page, [small]);
  await confirmUpload(page);
  const s = await waitFinished(page, 600000);
  const ps = await proxyStats(18084);
  log('proxy injected:', JSON.stringify(ps));
  assert(ps.injected503 > 0 && ps.injectedDrop > 0 && ps.injected502 > 0, 'faults were actually injected');
  eq(s.failedFiles, 1, 'exactly one failure');
  const failed = await failedList(page);
  assert(failed[0].rel.endsWith('FORBIDDEN-report.pdf'), 'failed file is the forbidden one');
  assert(failed[0].error.includes('Permission denied'), 'clear error: ' + failed[0].error);
  assert(await page.isVisible('#failed-box'), 'problems box visible');
  assert((await page.textContent('#tr-title')).includes('need'), 'title shows problems');
  await shot(page, '03-problems');
  await assertSameTree(small, path.join(SERVERS.flaky.root, 'flaky-test', 'Small Set'), { exclude: ['locked/FORBIDDEN-report.pdf'] });
  // Retry: still forbidden, still reported once.
  page.__run = await currentRun(page);
  await page.click('#btn-retry');
  const s2 = await waitFinished(page);
  eq(s2.failedFiles, 1, 'still one failure after retry');
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('pause / resume / cancel on a slow connection', async () => {
  await dav('apache', 'MKCOL', 'slow-test/');
  const { page, errors } = await launch(cfg('throttle'));
  await waitConnected(page);
  await goTo(page, '/slow-test');
  await drop(page, [media]);
  await confirmUpload(page);
  await page.waitForFunction(() => window.nasUploader.manager.stats().inflightBytes > 3e6, null, { timeout: 30000, polling: 100 });
  await shot(page, '04-uploading-slow');
  await page.click('#btn-pause');
  await page.waitForFunction(() => window.nasUploader.manager.state === 'paused' && window.nasUploader.manager.activeTasks().length === 0, null, { timeout: 5000 });
  await page.waitForSelector('#btn-resume:not([hidden])', { timeout: 2000 });
  eq(await page.textContent('#tr-title'), 'Paused', 'paused title');
  // While paused: the in-flight uploads were aborted, nothing new starts, and the extension sends nothing.
  const p0 = await proxyStats(18085);
  const sent0 = await page.evaluate(() => window.nasUploader.manager.sentBytes);
  await page.waitForTimeout(3000);
  const p1 = await proxyStats(18085);
  const sent1 = await page.evaluate(() => window.nasUploader.manager.sentBytes);
  eq(p1.putStarted, p0.putStarted, 'no new uploads started while paused');
  eq(sent1, sent0, 'no bytes sent while paused');
  eq(p1.putAborted, p1.putStarted, 'every started upload was aborted by the pause');
  await shot(page, '05-paused');
  await page.click('#btn-resume');
  let s = await waitFinished(page, 120000);
  eq(s.state, 'done', 'done after resume');
  eq(s.failedFiles, 0, 'no failures');
  await assertSameTree(media, path.join(SERVERS.throttle.root, 'slow-test', 'Media Set'));

  // Cancel, then retry the cancelled files.
  await dav('apache', 'DELETE', 'slow-test/Media Set/');
  await drop(page, [media]);
  await confirmUpload(page);
  await page.waitForFunction(() => window.nasUploader.manager.stats().inflightBytes > 2e6, null, { timeout: 30000, polling: 100 });
  await page.click('#btn-cancel');
  await page.waitForSelector('dialog[open]');
  await page.click('#dialog-ok');
  s = await waitFinished(page);
  eq(s.state, 'cancelled', 'cancelled');
  assert(s.cancelledFiles > 0, 'cancelled files counted');
  assert(await page.isVisible('#btn-retry'), 'retry offered after cancel');
  page.__run = await currentRun(page);
  await page.click('#btn-retry');
  s = await waitFinished(page, 120000);
  eq(s.state, 'done', 'done after retry');
  eq(s.failedFiles + s.cancelledFiles, 0, 'nothing left over');
  await assertSameTree(media, path.join(SERVERS.throttle.root, 'slow-test', 'Media Set'));
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('NAS goes offline in the middle of a transfer: auto-pauses, then resumes by itself when it is back', async () => {
  await dav('apache', 'MKCOL', 'offline-test/');
  const { page, errors } = await launch(cfg('throttle'));
  await waitConnected(page);
  await goTo(page, '/offline-test');
  // Shorten the waits so the test doesn't take minutes (defaults: 8 attempts from 2 s, auto-resume after 60 s).
  await page.evaluate(() => Object.assign(window.nasUploader.manager.options, { retryBaseMs: 200, maxAttempts: 3, autoResumeMs: 4000 }));
  await drop(page, [media]);
  await confirmUpload(page);
  await page.waitForFunction(() => window.nasUploader.manager.stats().inflightBytes > 2e6, null, { timeout: 30000, polling: 100 });
  const pidFile = path.join(DATA, 'proxy-throttle.pid');
  process.kill(Number(fs.readFileSync(pidFile, 'utf8')));
  await page.waitForFunction(() => !!window.nasUploader.manager.connectionIssue, null, { timeout: 30000, polling: 100 });
  assert((await page.textContent('#tr-title')).includes("Can't reach the NAS"), 'title explains the auto-pause');
  await shot(page, '06-connection-lost');
  const { spawn } = require('child_process');
  const out = fs.openSync(path.join(DATA, 'logs', 'proxy-throttle.log'), 'a');
  const child = spawn(process.execPath, [path.join(__dirname, 'proxy.cjs'), '--listen', '18085', '--target', '18081', '--mode', 'throttle', '--rate', '3000000'], { detached: true, stdio: ['ignore', out, out] });
  child.unref();
  fs.writeFileSync(pidFile, String(child.pid));
  const s = await waitFinished(page, 120000);
  eq(s.state, 'done', 'finished after the NAS came back');
  eq(s.failedFiles, 0, 'no failures ' + JSON.stringify(await failedList(page)));
  await assertSameTree(media, path.join(SERVERS.throttle.root, 'offline-test', 'Media Set'));
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('HTTPS with a self-signed certificate: explains it, and works after accepting the certificate once', async () => {
  const { ctx, page, errors } = await launch(cfg('apache', { serverUrl: 'https://127.0.0.1:18443/' }));
  await page.waitForSelector('#conn-error:not([hidden])', { timeout: 15000 });
  assert((await page.textContent('#conn-error-tips')).includes('self-signed'), 'tips mention self-signed certificates');
  const [nasTab] = await Promise.all([ctx.waitForEvent('page'), page.click('#btn-open-nas')]);
  await nasTab.waitForLoadState('domcontentloaded').catch(() => {});
  await nasTab.waitForTimeout(500);
  await nasTab.keyboard.type('thisisunsafe'); // Chrome's keyboard bypass for its certificate warning page
  await nasTab.waitForTimeout(1500);
  await nasTab.close();
  await page.click('#btn-retry-conn');
  await waitConnected(page);
  assert((await page.textContent('#conn-text')).includes('127.0.0.1:18443'), 'connected over HTTPS');
  assert(!(await page.textContent('#conn-text')).includes('not encrypted'), 'no http warning for https');
  await page.evaluate(() => (location.hash = '#/'));
  await dav('apache', 'MKCOL', 'https-test/');
  await goTo(page, '/https-test');
  await drop(page, [small]);
  await confirmUpload(page);
  const s = await waitFinished(page);
  eq(s.failedFiles, 0, 'failed ' + JSON.stringify(await failedList(page)));
  await assertSameTree(small, path.join(SERVERS.apache.root, 'https-test', 'Small Set'));
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('wrong password: clear error, no browser login pop-up', async () => {
  const { page, errors } = await launch(cfg('apache', { password: 'wrong password' }));
  await page.waitForSelector('#conn-error:not([hidden])', { timeout: 15000 });
  assert((await page.textContent('#conn-error-msg')).includes('username or password'), 'message');
  await shot(page, '06-wrong-password');
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('unreachable NAS: helpful connection error', async () => {
  const { page } = await launch(cfg('apache', { serverUrl: 'http://127.0.0.1:18099/' }));
  await page.waitForSelector('#conn-error:not([hidden])', { timeout: 15000 });
  assert((await page.textContent('#conn-error-msg')).includes('Could not reach'), 'message');
  assert((await page.$$('#conn-error-tips li')).length >= 3, 'tips shown');
  await shot(page, '07-unreachable');
});

test('password left empty in config: asks once per browser session, Lock forgets it', async () => {
  const { page, errors } = await launch(cfg('apache', { password: '' }));
  await page.waitForSelector('#login:not([hidden])', { timeout: 10000 });
  eq(await page.inputValue('#login-user'), USER, 'username prefilled');
  await page.fill('#login-pass', 'nope');
  await page.click('#login-submit');
  await page.waitForSelector('#login-error:not([hidden])');
  await shot(page, '08-login');
  await page.fill('#login-pass', PASSWORD);
  await page.click('#login-submit');
  await waitConnected(page);
  await page.reload();
  await waitConnected(page);
  assert(await page.isVisible('#btn-lock'), 'lock button visible');
  await page.click('#btn-lock');
  await page.waitForSelector('#login:not([hidden])', { timeout: 10000 });
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('WebDAV under a sub-path with a space ("/my dav/")', async () => {
  const { page, errors } = await launch(cfg('apacheSub'));
  await waitConnected(page);
  await drop(page, [small]);
  await confirmUpload(page);
  const s = await waitFinished(page);
  eq(s.failedFiles, 0, 'failed ' + JSON.stringify(await failedList(page)));
  await assertSameTree(small, path.join(SERVERS.apacheSub.root, 'Small Set'));
  // Names shown in the browser match the real names.
  await page.click('#listing-body tr[data-name="Small Set"] button.entry');
  await page.waitForSelector('#listing-body tr[data-name="special names"]');
  await page.click('#listing-body tr[data-name="special names"] button.entry');
  await page.waitForFunction(() => window.nasUploader.cwd === '/Small Set/special names');
  await page.waitForFunction(() => document.querySelectorAll('#listing-body tr').length > 5);
  const shown = new Set(await listingNames(page));
  const local = fs.readdirSync(path.join(small, 'special names'));
  for (const n of local) assert(shown.has(n), `listing shows "${n}"`);
  eq(shown.size, local.length, 'listing count');
  await shot(page, '09-special-names');
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('second WebDAV implementation (WsgiDAV): upload + resume', async () => {
  const { page, errors } = await launch(cfg('wsgidav'));
  await waitConnected(page);
  await drop(page, [small]);
  await confirmUpload(page);
  let s = await waitFinished(page);
  eq(s.failedFiles, 0, 'failed ' + JSON.stringify(await failedList(page)));
  await assertSameTree(small, path.join(SERVERS.wsgidav.root, 'Small Set'));
  await drop(page, [small]);
  await confirmUpload(page);
  s = await waitFinished(page);
  eq(s.uploadedFiles, 0, 'nothing re-uploaded');
  eq(s.skippedFiles, walk(small).files.size, 'all skipped');
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('20,000 small files in one drop', async () => {
  const stressDir = path.join(DS, 'stress', 'Twenty Thousand');
  const { page, errors } = main;
  await goTo(page, '/');
  await dav('apache', 'MKCOL', 'stress-test/');
  await goTo(page, '/stress-test');
  await page.evaluate(() => {
    document.getElementById('opt-parallel').value = '6';
    document.getElementById('opt-parallel').dispatchEvent(new Event('change'));
  });
  const t0 = Date.now();
  await drop(page, [stressDir]);
  const text = await confirmUpload(page);
  assert(text.includes('Upload 20,000 files'), 'count in dialog: ' + text.slice(0, 80));
  log(`scan + confirm took ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  // The page must stay responsive while thousands of uploads run.
  let maxLag = 0;
  const lagProbe = setInterval(async () => {
    const t = Date.now();
    await page.evaluate(() => 1).catch(() => {});
    maxLag = Math.max(maxLag, Date.now() - t);
  }, 500);
  const s = await waitFinished(page, 900000);
  clearInterval(lagProbe);
  log(`20,000 files uploaded in ${((Date.now() - t0) / 1000).toFixed(1)}s, worst UI response ${maxLag} ms`);
  eq(s.failedFiles, 0, 'failed');
  eq(s.uploadedFiles, 20000, 'uploaded');
  eq(s.verifiedFiles, 20000, 'verified');
  assert(maxLag < 2000, 'UI stayed responsive');
  await assertSameTree(stressDir, path.join(SERVERS.apache.root, 'stress-test', 'Twenty Thousand'));
  await page.evaluate(() => {
    document.getElementById('opt-parallel').value = '3';
    document.getElementById('opt-parallel').dispatchEvent(new Event('change'));
  });
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('dropping a folder and loose files together, and dropping more while an upload is running', async () => {
  await dav('apache', 'MKCOL', 'queue-test/');
  const { page, errors } = await launch(cfg('throttle'));
  await waitConnected(page);
  await goTo(page, '/queue-test');
  await drop(page, [media]);
  await confirmUpload(page);
  await page.waitForFunction(() => window.nasUploader.manager.stats().inflightBytes > 1e6, null, { timeout: 30000, polling: 100 });
  // Second drop while the first is still uploading: a folder plus a loose file in one go.
  await drop(page, [small, looseFile]);
  await page.waitForSelector('dialog[open]', { timeout: 30000 });
  await page.click('#dialog-ok');
  const s = await waitFinished(page, 180000);
  eq(s.failedFiles, 0, 'failed ' + JSON.stringify(await failedList(page)));
  await assertSameTree(media, path.join(SERVERS.apache.root, 'queue-test', 'Media Set'));
  await assertSameTree(small, path.join(SERVERS.apache.root, 'queue-test', 'Small Set'));
  eq(await sha256(path.join(SERVERS.apache.root, 'queue-test', 'single file.pdf')), await sha256(looseFile), 'loose file');
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('single file larger than 4 GB', async () => {
  if (!fs.existsSync(hugeFile)) {
    log('skipped (dataset built with --no-big)');
    return;
  }
  const { page, errors } = main;
  await goTo(page, '/');
  await dav('apache', 'MKCOL', 'huge-test/');
  await goTo(page, '/huge-test');
  const t0 = Date.now();
  await drop(page, [hugeFile]);
  await confirmUpload(page);
  const s = await waitFinished(page, 1200000);
  log(`5 GB file uploaded in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  eq(s.failedFiles, 0, 'failed ' + JSON.stringify(await failedList(page)));
  eq(s.verifiedFiles, 1, 'verified');
  const dst = path.join(SERVERS.apache.root, 'huge-test', 'backup-5GB.tar');
  eq(fs.statSync(dst).size, fs.statSync(hugeFile).size, 'size');
  eq(await sha256(dst), await sha256(hugeFile), 'content');
  fs.rmSync(dst);
  eq(errors.length, 0, 'page errors: ' + errors.join('; '));
});

test('toolbar button opens the app once and re-focuses it instead of opening duplicates', async () => {
  const { ctx, sw, appUrl } = await launch(cfg('apache'));
  const count = () => ctx.pages().filter((p) => p.url().startsWith(appUrl)).length;
  eq(count(), 1, 'one app tab to start');
  await sw.evaluate(() => globalThis.openApp());
  await sw.evaluate(() => globalThis.openApp());
  eq(count(), 1, 'still one app tab');
  for (const p of ctx.pages().filter((p) => p.url().startsWith(appUrl))) await p.close();
  await sw.evaluate(() => globalThis.openApp());
  await new Promise((r) => setTimeout(r, 1000));
  eq(count(), 1, 'reopened after closing');
});

test('dark mode renders', async () => {
  const { page } = await launch(cfg('apache'), { colorScheme: 'dark' });
  await waitConnected(page);
  await goTo(page, '/' + UPLOAD_DIR + '/Project Archive');
  await shot(page, '10-dark');
});

// ---------------------------------------------------------------------------
(async () => {
  let failed = 0;
  for (const t of tests) {
    if (FILTER && !FILTER.test(t.name)) continue;
    const t0 = Date.now();
    process.stdout.write(`• ${t.name}\n`);
    try {
      await t.fn();
      results.push({ name: t.name, ok: true, ms: Date.now() - t0 });
      console.log(`  ✔ passed (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
    } catch (err) {
      failed++;
      results.push({ name: t.name, ok: false, ms: Date.now() - t0, error: err.message });
      console.log(`  ✘ FAILED: ${err.stack || err}`);
      for (const b of browsers)
        for (const p of b.pages()) {
          await p.screenshot({ path: path.join(SHOTS, `FAIL-${results.length}-${Date.now()}.png`) }).catch(() => {});
          await p
            .evaluate(() => {
              const d = document.getElementById('dialog');
              if (d?.open) d.close('cancel');
              window.nasUploader?.manager?.cancel();
            })
            .catch(() => {});
        }
    }
  }
  for (const b of browsers) await b.close().catch(() => {});
  console.log(`\n${results.filter((r) => r.ok).length} passed, ${failed} failed`);
  fs.writeFileSync(path.join(WORK, 'results.json'), JSON.stringify(results, null, 2));
  process.exit(failed ? 1 : 0);
})();
