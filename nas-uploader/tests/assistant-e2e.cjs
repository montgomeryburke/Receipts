// End-to-end tests for the assistant side of the extension: side panel, settings, engine (index, email
// drafts, chat with tools, undo), meeting window (audio capture, transcription, prompts, NAS transcript).
// Uses the real extension in Chromium, the real WebDAV test servers (./start-servers.sh), and mock
// Anthropic / Gemini servers (mock-ai.cjs) — no API keys needed.
//   NAS_TEST_WORK=<dir> node assistant-e2e.cjs [filter]
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { startMockAI } = require('./mock-ai.cjs');

const EXT_SRC = path.resolve(process.env.NAS_EXT_SRC || path.join(__dirname, '../extension'));
const WORK = path.resolve(process.env.NAS_TEST_WORK || fs.mkdtempSync(path.join(os.tmpdir(), 'assistant-e2e-')));
const DATA = process.env.NAS_TEST_DATA || '/var/tmp/nas-uploader-test';
const SHOTS = path.join(WORK, 'screenshots');
const USER = 'nasuser';
const PASSWORD = process.env.NAS_TEST_PASSWORD || 'pässwörd:with colon';
const FILTER = process.argv[2] ? new RegExp(process.argv[2], 'i') : null;
const NAS = { url: 'http://127.0.0.1:18081/', root: path.join(DATA, 'root1') };
fs.mkdirSync(SHOTS, { recursive: true });

// ---------------------------------------------------------------------------
// harness
// ---------------------------------------------------------------------------
const results = [];
const tests = [];
const test = (name, fn) => tests.push({ name, fn });
function assert(cond, msg) {
  if (!cond) throw new Error('Assertion failed: ' + msg);
}
function eq(a, b, msg) {
  if (a !== b) throw new Error(`Assertion failed: ${msg} — expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}
const log = (...a) => console.log('   ', ...a);
const browsers = [];
let extCounter = 0;

async function launch({ config = {}, chromeArgs = [] } = {}) {
  const name = `a${++extCounter}`;
  const ext = path.join(WORK, 'ext-' + name);
  fs.rmSync(ext, { recursive: true, force: true });
  // Copy everything except the big vendor folder, which is linked (saves ~30 MB per launch).
  fs.mkdirSync(ext, { recursive: true });
  for (const entry of fs.readdirSync(EXT_SRC)) {
    if (entry === 'vendor') fs.symlinkSync(path.join(EXT_SRC, 'vendor'), path.join(ext, 'vendor'));
    else fs.cpSync(path.join(EXT_SRC, entry), path.join(ext, entry), { recursive: true });
  }
  const conf = { serverUrl: NAS.url, username: USER, password: PASSWORD, startFolder: '/', parallelUploads: 3, ...config };
  fs.writeFileSync(path.join(ext, 'config.js'), 'export const CONFIG = ' + JSON.stringify(conf, null, 2) + ';\n');
  const udd = path.join(WORK, 'profile-' + name);
  fs.rmSync(udd, { recursive: true, force: true });
  const ctx = await chromium.launchPersistentContext(udd, {
    channel: 'chromium',
    headless: !process.env.HEADED,
    viewport: { width: 1280, height: 860 },
    env: { ...process.env, LANG: 'C.UTF-8' },
    args: [
      `--disable-extensions-except=${ext}`,
      `--load-extension=${ext}`,
      '--autoplay-policy=no-user-gesture-required',
      ...chromeArgs,
    ],
  });
  browsers.push(ctx);
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker');
  const id = sw.url().split('/')[2];
  const errors = [];
  const watch = (page) => {
    page.on('pageerror', (e) => errors.push(`${page.url().split('/').pop()}: ${e.message}`));
    page.on('dialog', (d) => d.accept());
    return page;
  };
  ctx.on('page', watch);
  const open = async (file) => {
    const page = watch(await ctx.newPage());
    await page.goto(`chrome-extension://${id}/${file}`);
    return page;
  };
  return { ctx, sw, id, ext, errors, open };
}

/** Runs a message through the service worker to the engine and returns the answer. */
function engine(sw, payload) {
  return sw.evaluate((p) => globalThis.toEngine(p), payload);
}

async function waitFor(fn, { timeout = 30000, every = 250, what = 'condition' } = {}) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    last = await fn();
    if (last) return last;
    await new Promise((r) => setTimeout(r, every));
  }
  throw new Error(`Timed out waiting for ${what}`);
}

/** Saves settings straight into the extension's database (from any extension page). */
async function setSettings(page, patch) {
  await page.evaluate(async (p) => {
    const db = await import('./lib/db.js');
    await db.saveSettings(p);
  }, patch);
}


const http = require('http');
const https = require('https');
const { spawnSync } = require('child_process');
const { anthropicMessage, geminiReply, text, toolUse } = require('./mock-ai.cjs');

function dav(method, p, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(p.split('/').map(encodeURIComponent).join('/').replace(/^%2F/, ''), NAS.url);
    const req = http.request(u, { method, headers: { Authorization: 'Basic ' + Buffer.from(`${USER}:${PASSWORD}`).toString('base64'), ...(body ? { 'Content-Length': Buffer.byteLength(body) } : {}) } }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

let nasSeq = 0;
/** A fresh folder on the NAS for one test. */
async function nasFolder() {
  const name = `/at-${process.pid}-${++nasSeq}`;
  await dav('MKCOL', name + '/');
  return name;
}

/** A minimal one-page PDF with the given lines of text (so pdf.js extraction is exercised). */
function makePdf(lines) {
  const content = `BT /F1 12 Tf 72 720 Td 16 TL ${lines.map((l) => `(${l.replace(/[()\\]/g, '\\$&')}) '`).join(' ')} ET`;
  const objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    `<< /Length ${content.length} >>\nstream\n${content}\nendstream`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  let pdf = '%PDF-1.4\n';
  const offs = [];
  objs.forEach((o, i) => {
    offs.push(pdf.length);
    pdf += `${i + 1} 0 obj\n${o}\nendobj\n`;
  });
  const xref = pdf.length;
  pdf += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n${offs.map((o) => `${String(o).padStart(10, '0')} 00000 n \n`).join('')}`;
  pdf += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(pdf, 'latin1');
}

const PROJECT_FILES = {
  '2024-017 Alert Bridge/Design/Design Criteria.txt': 'Alert Bridge design criteria.\n\nDeck width: 12.0 m clear roadway between barriers.\n\nDesign live load CL-625. Barrier test level TL-4, barrier height 1050 mm. Design code CSA S6:19.',
  '2024-017 Alert Bridge/Schedule/Schedule Update 2026-10.md': '# Schedule update October 2026\n\nDeck pour moved to November 18, 2026. Forecast substantial completion: June 2027.',
  '2024-017 Alert Bridge/Minutes/Site Meeting 3.txt': 'Site meeting 3. Contractor: Arctic Fresh Projects. Level 2 pour date is November 4.',
  '2025-003 Harbour Road/Specs/Pavement.txt': 'Harbour Road pavement structure: 100 mm asphalt over 300 mm granular base course.',
  'readme.txt': 'Project drive index. Each folder is one project.',
};

/**
 * Mirrors a folder of project files to the NAS through "NAS files" (the browser-private file system stands in
 * for the folder picker), which also triggers the assistant's index. Returns {app, nasPath}.
 */
async function mirrorProjects(b, { files = PROJECT_FILES, pdf = true, mode = 'subfolders' } = {}) {
  const base = await nasFolder();
  const nasPath = `${base}/Projects`;
  const app = await b.open('app.html');
  await app.waitForSelector('#app:not([hidden])', { timeout: 15000 });
  await app.waitForFunction(() => document.getElementById('listing-loading').hidden, null, { timeout: 15000 });
  const payload = Object.entries(files).map(([p, c]) => [p, Buffer.from(c).toString('base64')]);
  if (pdf) payload.push(['2024-017 Alert Bridge/Standards/MoTI Barrier Note.pdf', makePdf(['BC MoTI supplement note:', 'Bridge barrier height shall be 1050 mm minimum for TL-4.']).toString('base64')]);
  await app.evaluate(async (entries) => {
    const root = await navigator.storage.getDirectory();
    try {
      await root.removeEntry('Projects', { recursive: true });
    } catch {}
    const dir = await root.getDirectoryHandle('Projects', { create: true });
    for (const [p, b64] of entries) {
      const parts = p.split('/');
      let d = dir;
      for (const seg of parts.slice(0, -1)) d = await d.getDirectoryHandle(seg, { create: true });
      const fh = await d.getFileHandle(parts.at(-1), { create: true });
      const w = await fh.createWritable();
      await w.write(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)));
      await w.close();
    }
    window.nasUploader.pickDirectory = async () => dir;
    window.nasUploader.renderMirrors();
  }, payload);
  await app.waitForSelector('#mirrors-card:not([hidden]) #btn-new-mirror:not([hidden])');
  await app.click('#btn-new-mirror');
  await app.waitForSelector('dialog[open] #mirror-nas-path');
  await app.fill('#mirror-nas-path', nasPath);
  await app.selectOption('#mirror-project-mode', mode);
  const run0 = await app.evaluate(() => window.nasUploader.manager?.runs ?? 0);
  await app.click('#dialog-ok');
  await app.waitForFunction(() => document.getElementById('dialog').open && /^Mirror: review the changes/.test(document.getElementById('dialog-title').textContent), null, { timeout: 60000 });
  await app.click('#dialog-ok');
  await app.waitForFunction((r) => window.nasUploader.manager?.runs > r && window.nasUploader.manager.state === 'done', run0, { timeout: 120000 });
  return { app, nasPath, prefix: nasPath.slice(1) };
}

/** Waits until the engine's index has at least n files and no job is running. */
async function waitIndexed(b, n) {
  return waitFor(async () => {
    const st = await engine(b.sw, { type: 'status' });
    return st?.index?.status?.files >= n && !st.job ? st : null;
  }, { timeout: 60000, what: `index of ${n} files` });
}

function keys(extra = {}) {
  const ai = global.mockAI;
  return { anthropicKey: 'sk-ant-test', anthropicBaseUrl: ai.url, geminiKey: 'AIza-test', geminiBaseUrl: ai.url, ...extra };
}

/** A WAV of synthetic speech (espeak-ng), at 16 kHz. */
function speechWav(name, words, { speed = 150 } = {}) {
  const out = path.join(WORK, `${name}.wav`);
  if (!fs.existsSync(out)) {
    const r = spawnSync('espeak-ng', ['-s', String(speed), '-w', out, words]);
    if (r.status !== 0) throw new Error('espeak-ng failed: ' + r.stderr);
  }
  return out;
}


/** A stand-in for a Power Automate "When an HTTP request is received" trigger (HTTPS, self-signed). */
async function startFlowServer(respond) {
  const key = path.join(WORK, 'flow-key.pem');
  const cert = path.join(WORK, 'flow-cert.pem');
  if (!fs.existsSync(cert)) spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', cert, '-days', '2', '-subj', '/CN=127.0.0.1']);
  const calls = [];
  const server = https.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert) }, (req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      let body = null;
      try {
        body = JSON.parse(raw);
      } catch {}
      calls.push({ url: req.url, method: req.method, body });
      const out = respond(body, req);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(out));
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { url: `https://127.0.0.1:${server.address().port}/workflows/abc/triggers/manual/paths/invoke?sig=secret`, calls, close: () => new Promise((r) => server.close(r)) };
}

/** Sends a chat message from the side panel and waits for the reply to finish. Returns the reply text. */
async function chatSend(panel, textMsg) {
  const before = await panel.$$eval('#chatLog .msg.assistant', (n) => n.length);
  await panel.click('.tabs [data-tab="chat"]');
  await panel.fill('#chatInput', textMsg);
  await panel.click('#chatSend');
  await panel.waitForFunction((n) => {
    const msgs = document.querySelectorAll('#chatLog .msg.assistant');
    return msgs.length > n && !/Working…/.test(msgs[msgs.length - 1].textContent) && !document.getElementById('chatSend').disabled;
  }, before, { timeout: 60000 });
  return panel.$eval('#chatLog .msg.assistant:last-child', (n) => n.textContent);
}

/** The last tool results the client sent back to Claude, by tool name. */
function lastToolResults(body) {
  const out = {};
  const uses = {};
  for (const m of body.messages) {
    if (m.role === 'assistant' && Array.isArray(m.content)) for (const b of m.content) if (b.type === 'tool_use') uses[b.id] = b.name;
    if (m.role === 'user' && Array.isArray(m.content)) for (const b of m.content) if (b.type === 'tool_result') out[uses[b.tool_use_id]] = JSON.parse(b.content);
  }
  return out;
}

const lastUserText = (body) => {
  const m = [...body.messages].reverse().find((x) => x.role === 'user' && typeof x.content === 'string');
  return m ? m.content : '';
};
const endsWithToolResult = (body) => {
  const m = body.messages.at(-1);
  return Array.isArray(m.content) && m.content.some((b) => b.type === 'tool_result');
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test('smoke: every page loads without errors, engine starts', async () => {
  const b = await launch();
  const panel = await b.open('sidepanel.html');
  await panel.waitForSelector('#chips .pill');
  const options = await b.open('options.html');
  await options.waitForSelector('#folderList');
  const app = await b.open('app.html');
  await app.waitForSelector('#app:not([hidden])', { timeout: 15000 });
  const st = await waitFor(() => engine(b.sw, { type: 'status' }).then((r) => (r && !r.error ? r : null)), { what: 'engine status' });
  eq(st.nas.configured, true, 'NAS configured from config.js');
  const nas = await engine(b.sw, { type: 'nas.test' });
  eq(nas.ok, true, `NAS reachable from the engine (${nas.error || ''})`);
  await panel.screenshot({ path: path.join(SHOTS, 'smoke-sidepanel.png') });
  await options.screenshot({ path: path.join(SHOTS, 'smoke-options.png'), fullPage: true });
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});


test('one fileset: mirroring a folder to the NAS also indexes it here (NAS paths, projects per subfolder, PDF text)', async () => {
  const b = await launch();
  const { nasPath, prefix } = await mirrorProjects(b);
  // The files are on the NAS…
  const onNas = await dav('GET', `${nasPath}/2024-017 Alert Bridge/Design/Design Criteria.txt`);
  eq(onNas.status, 200, 'mirrored file on the NAS');
  // …and the same folder was indexed on this computer, keyed by NAS path.
  const st = await waitIndexed(b, 6);
  eq(st.projectFolders.length, 1, 'one project folder');
  eq(st.projectFolders[0].nasPath, nasPath, 'folder → NAS path');
  const hits = (await engine(b.sw, { type: 'search', q: 'deck width clear roadway' })).hits;
  assert(hits.length && hits[0].path === `${prefix}/2024-017 Alert Bridge/Design/Design Criteria.txt`, 'search hit by NAS path: ' + JSON.stringify(hits.map((h) => h.path)));
  const pdfHits = (await engine(b.sw, { type: 'search', q: 'MoTI barrier height' })).hits;
  assert(pdfHits.some((h) => h.path.endsWith('MoTI Barrier Note.pdf') && /1050 mm/.test(h.text)), 'PDF text indexed: ' + JSON.stringify(pdfHits.map((h) => [h.path, h.text.slice(0, 60)])));
  const panel = await b.open('sidepanel.html');
  const projects = await panel.evaluate(async () => (await import('./lib/db.js')).kvGet('projects'));
  eq(JSON.stringify(projects), JSON.stringify([`${prefix}/2024-017 Alert Bridge`, `${prefix}/2025-003 Harbour Road`]), 'projects = subfolders (loose readme belongs to none)');
  // Side panel Mirror tab shows the folder with its last sync.
  await panel.click('.tabs [data-tab="mirror"]');
  await panel.waitForFunction(() => /Last synced/.test(document.getElementById('mirrorFolders').textContent));
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});

test('folder options: "one project" mode and switching indexing off, from Settings', async () => {
  const b = await launch();
  const { prefix } = await mirrorProjects(b, { pdf: false });
  await waitIndexed(b, 5);
  const options = await b.open('options.html');
  await options.waitForSelector('[data-folder] [data-pref="projectMode"]');
  await options.selectOption('[data-folder] [data-pref="projectMode"]', 'single');
  await waitFor(async () => {
    const p = await options.evaluate(async () => (await import('./lib/db.js')).kvGet('projects'));
    return JSON.stringify(p) === JSON.stringify([prefix]) ? p : null;
  }, { what: 'reindex as one project' });
  await options.uncheck('[data-folder] [data-pref="index"]');
  await waitFor(async () => {
    const st = await engine(b.sw, { type: 'status' });
    return st.projectFolders[0].index === false ? st : null;
  }, { what: 'indexing switched off' });
  const r = await engine(b.sw, { type: 'index.run' });
  await waitFor(async () => !(await engine(b.sw, { type: 'status' })).job, { what: 'index job to end' });
  assert(r.started || r.busy, 'index run accepted');
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});

test('email draft: local search picks the right file, prompt carries instructions + memory, Claude call uses fallbacks', async () => {
  const ai = global.mockAI;
  ai.reset();
  const b = await launch();
  const { prefix } = await mirrorProjects(b);
  await waitIndexed(b, 6);
  const panel = await b.open('sidepanel.html');
  await setSettings(panel, keys({ myName: 'Monty Burke', instructions: [{ id: 'i1', scope: 'email', text: 'Always mention the drawing number if one is known.', at: 1 }] }));
  await panel.evaluate(async (project) => (await import('./lib/memory.js')).addMemory(project, 'The client contact for Alert is Dana at Public Services.'), `${prefix}/2024-017 Alert Bridge`);
  ai.anthropic = (body) => {
    const user = body.messages[0].content.map((c) => c.text).join('\n');
    const m = /\[(S\d+)\] [^\n]*Design Criteria\.txt/.exec(user);
    return {
      content: [text(JSON.stringify({
        needs_reply: true, category: 'information_request', summary: 'Asks for deck width and barrier level.',
        requests: [{ ask: 'Clear deck width', status: 'answered', answer: '12.0 m', sources: [m ? m[1] : 'S1'] }],
        missing_info: [], search_terms: [], data_requests: [], draft_reply: 'Hi,\n\nThe clear deck width is 12.0 m between barriers, with TL-4 barriers.\n\nMonty', confidence: 'high',
      }))],
    };
  };
  await engine(b.sw, { type: 'email.capture', email: { from: 'Engineer <engineer@client.ca>', subject: 'Alert Bridge deck width', body: 'Hello, can you confirm the clear deck width and the barrier test level for the Alert Bridge? Thanks', source: 'manual' } });
  const item = await waitFor(async () => {
    const items = await panel.evaluate(async () => (await import('./lib/db.js')).getAll('items'));
    return items.find((i) => i.status === 'ready') || (items.find((i) => i.status === 'error') ? Promise.reject(new Error('draft failed: ' + items[0].error)) : null);
  }, { what: 'draft ready' });
  assert(/12\.0 m/.test(item.draft), 'draft text');
  eq(item.projects[0], `${prefix}/2024-017 Alert Bridge`, 'project detected from the email');
  const req = ai.ofApi('anthropic')[0];
  const sys = req.body.system.map((x) => x.text).join('');
  const user = req.body.messages[0].content.map((c) => c.text).join('\n');
  assert(/Always mention the drawing number/.test(sys), 'standing instruction in system prompt');
  assert(/Dana at Public Services/.test(user), 'project memory in the prompt');
  assert(/Deck width: 12\.0 m/.test(user), 'right excerpt sent');
  assert(!/Harbour Road pavement/.test(user), 'unrelated project file not sent');
  assert(user.length < 12000, `prompt kept small (${user.length} chars)`);
  eq(req.body.fallbacks, 'default', 'server-side fallback requested');
  assert(String(req.headers['anthropic-beta']).includes('server-side-fallback-2026-07-01'), 'fallback beta header');
  eq(req.body.output_config?.format?.type, 'json_schema', 'structured output');
  eq(req.body.output_config?.effort, 'low', 'low effort by default');
  eq(req.body.model, 'claude-opus-5-5', 'default model');
  // The side panel shows it.
  await panel.click('.tabs [data-tab="drafts"]');
  await panel.selectOption('#filter', 'all');
  await panel.waitForSelector('.card .subj');
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});

test('recency: updates and forecasts rank the newest file first', async () => {
  const b = await launch();
  const panel = await b.open('sidepanel.html');
  const order = await panel.evaluate(async () => {
    const { IndexWriter, search } = await import('./lib/index.js');
    const w = new IndexWriter();
    const old = Date.now() - 900 * 86400000;
    // The old file matches a little better on words alone (it repeats "forecast").
    await w.addFile({ path: 'P/X/Schedule 2024.txt', size: 1, mtime: old, project: 'P/X' }, [{ text: 'Schedule forecast for the deck pour. Forecast completion December 2024.', page: 0 }]);
    await w.addFile({ path: 'P/X/Schedule 2026.txt', size: 1, mtime: Date.now() - 5 * 86400000, project: 'P/X' }, [{ text: 'Schedule for the deck pour. Forecast completion June 2027.', page: 0 }]);
    await w.finish();
    const plain = (await search('schedule forecast deck pour completion', { k: 2 })).map((h) => h.path);
    const recent = (await search('schedule forecast deck pour completion', { k: 2, preferRecent: true })).map((h) => h.path);
    return { plain, recent };
  });
  eq(order.plain[0], 'P/X/Schedule 2024.txt', 'without recency the better text match wins');
  eq(order.recent[0], 'P/X/Schedule 2026.txt', 'with recency the newer file wins');
});


test('chat (Claude): "keep meeting prompts short" → instruction + setting changed, shown with Undo, undo restores', async () => {
  const ai = global.mockAI;
  ai.reset();
  const b = await launch();
  const panel = await b.open('sidepanel.html');
  await setSettings(panel, keys());
  let calls = 0;
  ai.anthropic = (body) => {
    calls++;
    if (!endsWithToolResult(body)) {
      return {
        stop_reason: 'tool_use',
        content: [
          text('I will change that.'),
          toolUse('add_instruction', { text: 'Keep meeting prompts to one sentence.', scope: 'meeting' }),
          toolUse('update_settings', { changes: [{ key: 'meetingMinGapSec', value: '45' }] }),
        ],
      };
    }
    const r = lastToolResults(body);
    return { content: [text(`Done. ${r.update_settings?.ok ? 'Prompts at most every 45 s.' : 'Setting failed.'} ${r.add_instruction?.ok ? 'Instruction added.' : ''}`)] };
  };
  const reply = await chatSend(panel, 'In meetings the prompts are too long and too frequent.');
  assert(/Prompts at most every 45 s/.test(reply) && /Instruction added/.test(reply), 'reply: ' + reply);
  eq(calls, 2, 'two calls (tools, then answer)');
  const s1 = await panel.evaluate(async () => (await import('./lib/db.js')).getSettings());
  eq(s1.meetingMinGapSec, 45, 'setting changed');
  eq(s1.instructions[0]?.scope, 'meeting', 'instruction scope');
  const req = ai.ofApi('anthropic')[0].body;
  assert(req.tools.some((t) => t.name === 'automate_save') && req.tools.some((t) => t.name === 'record_change_request'), 'tools offered');
  assert(/Power Automate/.test(req.system), 'Power Automate guide in system prompt');
  eq(req.cache_control?.type, 'ephemeral', 'prompt caching on the tool loop');
  assert(!JSON.stringify(req).includes('sk-ant-test'), 'key never in the prompt');
  // Changes are listed under the reply with Undo.
  await panel.waitForSelector('#chatLog .msg.assistant .change [data-act="undo"]');
  const changes = await panel.$$eval('#chatLog .msg.assistant .change', (n) => n.map((x) => x.textContent));
  eq(changes.length, 2, 'two changes listed: ' + changes.join(' | '));
  // Undo the setting change.
  const idx = changes.findIndex((c) => c.includes('meetingMinGapSec'));
  await panel.locator('#chatLog .msg.assistant .change [data-act="undo"]').nth(idx).click();
  await waitFor(async () => (await panel.evaluate(async () => (await import('./lib/db.js')).getSettings())).meetingMinGapSec === 20, { what: 'undo restores 20 s' });
  const s2 = await panel.evaluate(async () => (await import('./lib/db.js')).getSettings());
  eq(s2.instructions.length, 1, 'other change kept');
  // Refused: secrets and unknown settings.
  ai.anthropic = (body) => (endsWithToolResult(body) ? { content: [text(JSON.stringify(lastToolResults(body).update_settings))] } : { stop_reason: 'tool_use', content: [toolUse('update_settings', { changes: [{ key: 'anthropicKey', value: 'x' }] })] });
  const r2 = await chatSend(panel, 'set my key to x');
  assert(/API keys go in Settings/.test(r2), 'key change refused: ' + r2);
  eq((await panel.evaluate(async () => (await import('./lib/db.js')).getSettings())).anthropicKey, 'sk-ant-test', 'key untouched');
  await panel.screenshot({ path: path.join(SHOTS, 'chat-claude.png') });
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});

test('chat (Gemini): function calling round trip keeps thought signatures; auto model = newest stable Flash', async () => {
  const ai = global.mockAI;
  ai.reset();
  const b = await launch();
  const panel = await b.open('sidepanel.html');
  await setSettings(panel, keys({ provider: 'gemini', anthropicKey: '' }));
  ai.gemini = (body) => {
    const last = body.contents.at(-1);
    if (last.parts.some((p) => p.functionResponse)) return geminiReply({ text: `Saved: ${JSON.stringify(last.parts[0].functionResponse.response.result.ok)}` });
    return geminiReply({ calls: [{ name: 'remember', args: { project: 'Projects/2024-017 Alert Bridge', note: 'The GC is Arctic Fresh Projects.' } }] });
  };
  const reply = await chatSend(panel, 'Remember that the GC on Alert is Arctic Fresh.');
  assert(/Saved: true/.test(reply), 'reply: ' + reply);
  const reqs = ai.ofApi('gemini');
  eq(reqs.length, 2, 'two calls');
  eq(reqs[0].model, 'gemini-3.5-flash', 'auto picked the newest stable Flash (not preview/lite/pro)');
  const second = reqs[1].body.contents;
  assert(second.some((c) => c.role === 'model' && c.parts.some((p) => p.thoughtSignature === 'sig-remember')), 'model turn echoed with its thought signature');
  assert(second.at(-1).parts[0].functionResponse?.name === 'remember', 'function response sent');
  assert(reqs[0].body.tools[0].functionDeclarations.some((f) => f.name === 'get_status' && !f.parameters), 'tool without inputs has no schema (Gemini rejects empty objects)');
  const mem = await panel.evaluate(async () => (await import('./lib/memory.js')).getMemory('Projects/2024-017 Alert Bridge'));
  eq(mem.notes[0]?.text, 'The GC is Arctic Fresh Projects.', 'memory saved');
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});

test('chat sets up a Power Automate flow: action saved, schema given, URL added, write test runs only on click', async () => {
  const ai = global.mockAI;
  ai.reset();
  const flow = await startFlowServer((body) => ({ ok: true, data: { row: 12 }, message: `Row added for ${body?.params?.subject}` }));
  const b = await launch({ chromeArgs: ['--ignore-certificate-errors'] });
  const panel = await b.open('sidepanel.html');
  await setSettings(panel, keys());
  let schemaResult = null;
  ai.anthropic = (body) => {
    const user = lastUserText(body);
    const results = lastToolResults(body);
    if (/SharePoint tracker/.test(user)) {
      if (!endsWithToolResult(body)) {
        return { stop_reason: 'tool_use', content: [toolUse('automate_save', { name: 'log_email_to_tracker', description: 'Adds a row for each email to the SharePoint tracker.', kind: 'write', transport: 'http', params: 'subject={{subject}}, sender={{from}}, project={{project}}', auto: true })] };
      }
      if (!results.automate_flow_schema) return { stop_reason: 'tool_use', content: [toolUse('automate_flow_schema', { name: 'log_email_to_tracker' })] };
      schemaResult = results.automate_flow_schema;
      return { content: [text('1. Go to make.powerautomate.com → Create → Instant cloud flow → "When an HTTP request is received".\n2. Paste this schema:\n```\n' + JSON.stringify(schemaResult.requestSchema) + '\n```\n3. Paste the URL here.')] };
    }
    if (/Here is the URL/.test(user)) {
      const url = /https:\S+/.exec(user)[0];
      if (!endsWithToolResult(body)) return { stop_reason: 'tool_use', content: [toolUse('automate_save', { name: 'log_email_to_tracker', url })] };
      if (!results.automate_test) return { stop_reason: 'tool_use', content: [toolUse('automate_test', { name: 'log_email_to_tracker', params: [{ name: 'subject', value: 'Test from chat' }] })] };
      return { content: [text(results.automate_test.awaiting_user ? 'Click Run test below to send a test row.' : 'unexpected')] };
    }
    return { content: [text('?')] };
  };
  const r1 = await chatSend(panel, 'Set up a flow that logs every email to my SharePoint tracker.');
  assert(/make\.powerautomate\.com/.test(r1), 'step-by-step guide: ' + r1);
  assert(schemaResult?.requestSchema?.properties?.params?.properties?.subject && schemaResult.requestSchema.properties.params.properties.sender, 'schema lists the params');
  assert(schemaResult.paramExpressions.includes("triggerBody()?['params']?['project']"), 'expressions for the flow');
  const r2 = await chatSend(panel, `Here is the URL: ${flow.url}`);
  assert(/Run test/.test(r2), r2);
  const s = await panel.evaluate(async () => (await import('./lib/db.js')).getSettings());
  const act = s.actions.find((a) => a.name === 'log_email_to_tracker');
  eq(act?.url, flow.url, 'URL saved on the action');
  eq(act.kind, 'write', 'write action');
  eq(flow.calls.length, 0, 'write action not run without the user’s click');
  await panel.click('#chatLog [data-act="runTest"]');
  await panel.waitForFunction(() => /Row added for Test from chat/.test(document.getElementById('chatLog').textContent), null, { timeout: 30000 });
  eq(flow.calls.length, 1, 'flow called once');
  eq(flow.calls[0].body.action, 'log_email_to_tracker', 'request names the action');
  eq(flow.calls[0].body.params.subject, 'Test from chat', 'params sent');
  // The Automate tab lists it.
  await panel.click('.tabs [data-tab="automate"]');
  await panel.waitForFunction(() => /log_email_to_tracker/.test(document.getElementById('actionsBox').textContent));
  await panel.screenshot({ path: path.join(SHOTS, 'chat-power-automate.png') });
  await flow.close();
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});

test('chat: something it can’t change is saved as a change request on the NAS', async () => {
  const ai = global.mockAI;
  ai.reset();
  const b = await launch();
  const panel = await b.open('sidepanel.html');
  await setSettings(panel, keys());
  ai.anthropic = (body) => (endsWithToolResult(body)
    ? { content: [text(`Saved to ${lastToolResults(body).record_change_request.savedTo}.`)] }
    : { stop_reason: 'tool_use', content: [toolUse('record_change_request', { title: 'Show prompts as a Teams overlay', details: 'User wants prompts drawn inside the Teams window itself.' })] });
  const r = await chatSend(panel, 'Can you draw the prompts inside the Teams window?');
  assert(/NAS/.test(r), r);
  const f = await dav('GET', '/.assistant/change-requests.md');
  eq(f.status, 200, 'change request file on the NAS');
  assert(f.body.includes('Show prompts as a Teams overlay'), 'request written');
});

// ---------------------------------------------------------------------------
// runner
// ---------------------------------------------------------------------------
(async () => {
  const ai = await startMockAI();
  global.mockAI = ai;
  let failed = 0;
  for (const t of tests) {
    if (FILTER && !FILTER.test(t.name)) continue;
    const t0 = Date.now();
    process.stdout.write(`• ${t.name}\n`);
    try {
      await t.fn();
      results.push({ name: t.name, ok: true, ms: Date.now() - t0 });
      console.log(`  ✔ ${((Date.now() - t0) / 1000).toFixed(1)}s`);
    } catch (err) {
      failed++;
      results.push({ name: t.name, ok: false, error: err.stack || String(err) });
      console.log(`  ✘ ${err.stack || err}`);
    } finally {
      while (browsers.length) await browsers.pop().close().catch(() => {});
    }
  }
  await ai.close();
  fs.writeFileSync(path.join(WORK, 'assistant-results.json'), JSON.stringify(results, null, 2));
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})();
