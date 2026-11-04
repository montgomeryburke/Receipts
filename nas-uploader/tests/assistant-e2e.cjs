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
const T0 = Date.now();
const log = (...a) => console.log('   ', process.env.DEBUG ? `[${((Date.now() - T0) / 1000).toFixed(1)}s]` : '', ...a);
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
    acceptDownloads: true,
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
async function mirrorProjects(b, { files = PROJECT_FILES, pdf = true, mode = 'subfolders', extra = [] } = {}) {
  const base = await nasFolder();
  const nasPath = `${base}/Projects`;
  const app = await b.open('app.html');
  await app.waitForSelector('#app:not([hidden])', { timeout: 15000 });
  await app.waitForFunction(() => document.getElementById('listing-loading').hidden, null, { timeout: 15000 });
  const payload = Object.entries(files).map(([p, c]) => [p, Buffer.from(c).toString('base64')]);
  if (pdf) payload.push(['2024-017 Alert Bridge/Standards/MoTI Barrier Note.pdf', makePdf(['BC MoTI supplement note:', 'Bridge barrier height shall be 1050 mm minimum for TL-4.']).toString('base64')]);
  for (const [p, buf] of extra) payload.push([p, Buffer.from(buf).toString('base64')]);
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

/** A WAV of synthetic speech (espeak-ng), followed by padSec of silence (so a looping fake mic pauses). */
function speechWav(name, words, { speed = 150, padSec = 0 } = {}) {
  const out = path.join(WORK, `${name}${padSec ? `-pad${padSec}` : ''}.wav`);
  if (!fs.existsSync(out)) {
    const r = spawnSync('espeak-ng', ['-s', String(speed), '-w', out, words]);
    if (r.status !== 0) throw new Error('espeak-ng failed: ' + r.stderr);
    if (padSec) {
      const wav = fs.readFileSync(out);
      const rate = wav.readUInt32LE(24);
      const block = wav.readUInt16LE(32);
      const dataAt = wav.indexOf('data', 12) + 8;
      const silence = Buffer.alloc(Math.round(rate * padSec) * block);
      const outBuf = Buffer.concat([wav.subarray(0, dataAt), wav.subarray(dataAt), silence]);
      outBuf.writeUInt32LE(outBuf.length - 8, 4);
      outBuf.writeUInt32LE(outBuf.length - dataAt, dataAt - 4);
      fs.writeFileSync(out, outBuf);
    }
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
  return { url: `https://127.0.0.1:${server.address().port}/workflows/abc/triggers/manual/paths/invoke?sig=secret`, calls, close: () => new Promise((r) => {
      server.closeAllConnections?.();
      server.close(r);
    }) };
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


const THEM_SAY = 'Quick question about the Alert Bridge. What deck width did we use in the design?';
const ME_SAY = 'I think it was twelve metres.';

/** Copies test audio into the loaded extension and returns {them, me} file paths. */
function meetingMedia(b) {
  const dir = path.join(b.ext, 'test-media');
  fs.mkdirSync(dir, { recursive: true });
  const them = speechWav('them', THEM_SAY);
  const me = speechWav('me', ME_SAY, { speed: 140 });
  fs.copyFileSync(them, path.join(dir, 'them.wav'));
  fs.copyFileSync(me, path.join(dir, 'me.wav'));
  return { them, me };
}

/** Makes the meeting window "hear" a WAV as the Teams meeting (instead of the screen-share picker). */
async function feedMeetingAudio(page, file = 'test-media/them.wav') {
  await page.evaluate((f) => {
    window.meeting.captureOverride = async () => {
      const ctx = window.meeting.ctx;
      const a = new Audio(f);
      const src = ctx.createMediaElementSource(a);
      const dest = ctx.createMediaStreamDestination();
      src.connect(dest);
      await a.play();
      window.__themAudio = a;
      return dest.stream;
    };
  }, file);
}

const wavSeconds = (b64) => (Buffer.from(b64, 'base64').length - 44) / 32000;

/** Gemini mock that transcribes by audio length (the meeting audio is long, the mic line short). */
function geminiTranscriber(ai) {
  ai.gemini = (body) => {
    const audio = body.contents?.[0]?.parts?.find((p) => p.inline_data);
    if (audio) return geminiReply({ text: wavSeconds(audio.inline_data.data) > 3.2 ? THEM_SAY : ME_SAY });
    return geminiReply({ text: 'ok' });
  };
}

/** Anthropic mock for meeting calls: prompt, private answer, web look-up, summary. */
function meetingClaude(ai, { lookup = '' } = {}) {
  ai.anthropic = (body) => {
    const sys = Array.isArray(body.system) ? body.system.map((x) => x.text).join('') : String(body.system || '');
    const user = Array.isArray(body.messages[0].content) ? body.messages[0].content.map((c) => c.text).join('\n') : body.messages[0].content;
    if (body.tools?.some((t) => t.type === 'web_search_20260209')) {
      return { content: [{ type: 'text', text: 'CSA S6:19 cl. 12.4.3.5 sets the TL-4 barrier height at 1050 mm minimum.', citations: [{ type: 'web_search_result_location', url: 'https://www.csagroup.org/store/product/S6-19/', title: 'CSA S6:19 Canadian Highway Bridge Design Code', cited_text: 'barrier height', encrypted_index: 'x' }] }] };
    }
    if (/Summarise this meeting/.test(user)) {
      return { content: [text(JSON.stringify({ title: 'Alert deck width check', summary: 'The team confirmed the Alert Bridge deck width.', decisions: ['Deck width stays 12.0 m'], action_items: [{ who: 'Monty', what: 'Send the design criteria to the contractor', when: 'Friday' }], open_questions: [], remember: ['Deck width confirmed at 12.0 m clear between barriers in the meeting.'] }))] };
    }
    const tag = (/\[(S\d+)\] [^\n]*Design Criteria\.txt/.exec(user) || [])[1] || 'S1';
    if (/<private_question>/.test(user)) {
      return { content: [text(JSON.stringify({ answer: 'The design uses a 12.0 m clear deck width.', say: 'Our criteria say 12.0 m clear.', sources: [{ ref: tag, quote: 'Deck width: 12.0 m clear roadway between barriers.' }], lookup: '' }))] };
    }
    assert(/live work meeting/.test(sys), 'meeting system prompt');
    return { content: [text(JSON.stringify({ needed: true, topic: 'Alert deck width', suggestions: [{ say: 'We designed for a 12.0 m clear roadway between barriers.', why: 'From the design criteria.', sources: [{ ref: tag, quote: 'Deck width: 12.0 m clear roadway between barriers.' }] }], lookup }))] };
  };
}


// The speech model for the free-transcription test. huggingface.co can't be reached from the test machine, so
// the same Xenova/whisper-base files come from a local folder laid out like Hugging Face
// (/<model>/resolve/<revision>/<file>). WHISPER_TEST_MODEL_DIR points at the folder holding config.json.
const WHISPER_DIR = process.env.WHISPER_TEST_MODEL_DIR || '';

async function startModelServer(dir) {
  const hits = [];
  const server = http.createServer((req, res) => {
    const m = /^\/Xenova\/whisper-base\/resolve\/[^/]+\/(.+)$/.exec(decodeURIComponent(req.url.split('?')[0]));
    const file = m && path.join(dir, m[1]);
    if (!file || !file.startsWith(dir) || !fs.existsSync(file)) {
      res.writeHead(404, { 'access-control-allow-origin': '*' });
      return res.end('not found');
    }
    hits.push({ file: m[1], auth: req.headers.authorization || '' });
    const st = fs.statSync(file);
    res.writeHead(200, { 'content-length': st.size, 'content-type': 'application/octet-stream', 'access-control-allow-origin': '*' });
    fs.createReadStream(file).pipe(res);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { url: `http://127.0.0.1:${server.address().port}/`, hits, close: () => new Promise((r) => {
      server.closeAllConnections?.();
      server.close(r);
    }) };
}


const OCR_SCRIPT = path.join(__dirname, '../server/assistant-ocr-index.py');

/** A "scanned" PDF (an image of a page, no text layer) and a phone photo of the same page. */
function scannedFixtures() {
  const dir = path.join(WORK, 'scans');
  const pdf = path.join(dir, 'scanned.pdf');
  if (!fs.existsSync(pdf)) {
    fs.mkdirSync(dir, { recursive: true });
    const png = path.join(dir, 'page.png');
    let r = spawnSync('convert', ['-size', '1700x2200', 'xc:white', '-font', 'DejaVu-Sans', '-pointsize', '44', '-fill', 'black', '-annotate', '+150+300', 'SUBMITTAL 057 - CCTV', '-annotate', '+150+420', 'Camera mounting height: 4.5 m above deck', '-annotate', '+150+540', 'Approved by Daniel Aubrey 2025-03-18', png]);
    if (r.status !== 0) throw new Error('convert failed: ' + r.stderr);
    r = spawnSync('python3', ['-I', '-c', 'import sys\nfrom PIL import Image\nim=Image.open(sys.argv[1]).convert("RGB")\nim.save(sys.argv[2],"PDF",resolution=200.0)\nim.save(sys.argv[3],"JPEG",quality=90)', png, pdf, path.join(dir, 'photo.jpg')]);
    if (r.status !== 0) throw new Error('PIL failed: ' + r.stderr);
  }
  return { pdf: fs.readFileSync(pdf), jpg: fs.readFileSync(path.join(dir, 'photo.jpg')) };
}


/** A stand-in for Outlook on the web: same roles and labels the content script looks for. */
const FAKE_OUTLOOK = `<!doctype html><html><head><meta charset="utf-8"><title>Mail - Outlook</title></head><body>
<div role="listbox" aria-label="Message list">
  <div role="option" data-convid="conv-alert-1" aria-selected="true" aria-label="Alert Bridge deck width Engineer">Alert Bridge deck width</div>
</div>
<div role="main" style="min-height:300px">
  <div role="heading" aria-level="2">Alert Bridge deck width</div>
  <div class="msg">
    <div><span title="engineer@client.ca">Engineer</span> <span aria-label="To: Monty Burke">To: Monty</span></div>
    <time title="2026-11-03 10:15">2026-11-03 10:15</time>
    <div aria-label="Message body">Hello Monty,

Can you confirm the clear deck width and the barrier test level for the Alert Bridge?

Thanks,
Engineer</div>
    <button aria-label="Reply" onclick="if(!document.getElementById('ed')){const d=document.createElement('div');d.id='ed';d.contentEditable='true';d.setAttribute('role','textbox');d.setAttribute('aria-label','Message body, press Alt+F10 to exit');d.style.height='200px';d.style.border='1px solid #999';document.querySelector('[role=main]').append(d);}">Reply</button>
    <button aria-label="Reply all">Reply all</button>
  </div>
</div></body></html>`;

async function startFakeOutlook() {
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(FAKE_OUTLOOK);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  return { url: `${base}/owa/#/mail/inbox/id/AAMk-alert-1`, pattern: `${base}/owa/*`, close: () => new Promise((r) => {
      server.closeAllConnections?.();
      server.close(r);
    }) };
}

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


test('meeting: hears the meeting and the mic (meters), transcribes, flashes a prompt with a file quote, private ask, web look-up, saves to the NAS with a summary', async () => {
  const ai = global.mockAI;
  ai.reset();
  // The microphone is Chromium's fake device playing a WAV of the user speaking.
  const me = speechWav('me', ME_SAY, { speed: 140, padSec: 2 });
  const b = await launch({ chromeArgs: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', `--use-file-for-fake-audio-capture=${me}`] });
  meetingMedia(b);
  const { prefix } = await mirrorProjects(b);
  await waitIndexed(b, 6);
  const meeting = await b.open('meeting.html');
  await meeting.waitForFunction(() => window.meeting?.ready);
  await setSettings(meeting, keys({ meetingStt: 'gemini', myName: 'Monty Burke', meetingFolder: '/Meetings', meetingMinGapSec: 5 }));
  geminiTranscriber(ai);
  meetingClaude(ai, { lookup: 'CSA S6 barrier height for TL-4' });
  await feedMeetingAudio(meeting);
  await meeting.click('#btnTab');
  // Both sound meters move.
  await meeting.waitForFunction(() => document.querySelector('#mThem .state').textContent === 'hearing sound', null, { timeout: 15000 });
  await meeting.waitForFunction(() => document.querySelector('#mMe .state').textContent === 'hearing sound', null, { timeout: 15000 });
  await meeting.screenshot({ path: path.join(SHOTS, 'meeting-listening.png') });
  // Transcript from both.
  await meeting.waitForFunction(() => window.meeting.entries.some((e) => e.who === 'Them') && window.meeting.entries.some((e) => e.who !== 'Them'), null, { timeout: 30000 });
  const entries = await meeting.evaluate(() => window.meeting.entries);
  assert(entries.find((e) => e.who === 'Them').text === THEM_SAY, 'meeting transcribed');
  assert(entries.find((e) => e.who === 'Me').text === ME_SAY, 'mic transcribed (labelled Me)');
  const sttReq = ai.ofApi('gemini').find((r) => r.body.contents[0].parts.some((p) => p.inline_data));
  eq(sttReq.body.contents[0].parts[1].inline_data.mime_type, 'audio/wav', 'audio sent as WAV');
  // A prompt flashes up, with the quote and its file, plus the online standard.
  await meeting.waitForSelector('#prompts .card .say', { timeout: 30000 });
  const card = await meeting.textContent('#prompts .card');
  assert(card.includes('12.0 m clear roadway') && card.includes('Design Criteria.txt'), 'prompt with source: ' + card);
  await meeting.waitForFunction(() => /1050 mm/.test(document.getElementById('prompts').textContent), null, { timeout: 15000 });
  assert(await meeting.$('#prompts .card .web a[href^="https://www.csagroup.org"]'), 'web source linked');
  const promptReq = ai.ofApi('anthropic').find((r) => /What could the user say next/.test(JSON.stringify(r.body.messages)));
  const userText = promptReq.body.messages[0].content.map((c) => c.text).join('\n');
  assert(userText.length < 9000, `prompt kept small (${userText.length} chars)`);
  assert(/Design Criteria\.txt/.test(userText) && !/Harbour Road pavement/.test(userText), 'only relevant excerpts sent');
  eq(promptReq.body.output_config?.effort, 'low', 'low effort for live prompts');
  // Ask privately.
  await meeting.fill('#askInput', 'What width does our design use?');
  await meeting.click('#askForm button[type="submit"]');
  await meeting.waitForFunction(() => /12\.0 m clear deck width/.test(document.getElementById('answers').textContent), null, { timeout: 20000 });
  // Stop and save: summary, NAS file, project memory.
  await meeting.click('#btnStop');
  await meeting.waitForFunction(() => /Saved to the NAS/.test(document.getElementById('status').textContent), null, { timeout: 60000 });
  const saved = await meeting.evaluate(() => window.meeting.savedPath);
  assert(saved.startsWith('/Meetings/2024-017 Alert Bridge/') && saved.endsWith('Alert deck width check.md'), 'saved under the project: ' + saved);
  const md = await dav('GET', saved);
  eq(md.status, 200, 'transcript on the NAS');
  assert(md.body.includes('## Summary') && md.body.includes('Deck width stays 12.0 m') && md.body.includes('- [ ] Send the design criteria'), 'summary, decisions, action items');
  assert(md.body.includes(`Them:** ${THEM_SAY}`) && md.body.includes(`Me:** ${ME_SAY}`), 'transcript lines');
  assert(md.body.includes('## Private questions') && md.body.includes('## Prompts shown'), 'prompts and private questions kept');
  // The meeting itself is now searchable (for later meetings, drafts and the chat).
  const mh = (await engine(b.sw, { type: 'search', q: 'send the design criteria to the contractor' })).hits;
  assert(mh.some((h) => h.path === saved.slice(1)), 'saved meeting is in the index: ' + JSON.stringify(mh.map((h) => h.path)));
  const mem = await meeting.evaluate(async (p) => (await import('./lib/memory.js')).getMemory(p), `${prefix}/2024-017 Alert Bridge`);
  assert(mem.notes.some((n) => /12\.0 m clear/.test(n.text) && n.source === 'meeting'), 'meeting fact remembered for the project');
  await meeting.screenshot({ path: path.join(SHOTS, 'meeting-saved.png'), fullPage: true });
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});

test('meeting: speakers echo (meeting heard on the mic) is dropped; prompts respect the minimum gap', async () => {
  const ai = global.mockAI;
  ai.reset();
  const b = await launch();
  const page = await b.open('meeting.html');
  await page.waitForFunction(() => window.meeting?.ready);
  const r = await page.evaluate(async () => {
    const m = window.meeting;
    const { shouldPrompt } = await import('./lib/meeting-ai.js');
    m.settings = { ...m.settings, meetingPrompts: 'off' };
    const t = Date.now();
    // The meeting says something; the mic picks up the same words from the speakers (slightly garbled).
    m.onText({ who: 'Them', start: t, end: t + 3000 }, 'What deck width did we use on the Alert Bridge?');
    m.onText({ who: 'Me', start: t + 300, end: t + 3300 }, 'what deck width did we use on the alert bridge');
    // The other order: the mic copy is transcribed first, then the meeting copy replaces it.
    m.onText({ who: 'Me', start: t + 10000, end: t + 12000 }, 'and the barrier height is ten fifty');
    m.onText({ who: 'Them', start: t + 9800, end: t + 12000 }, 'And the barrier height is 1050?');
    // The user really speaking at the same time is kept.
    m.onText({ who: 'Me', start: t + 10500, end: t + 12500 }, 'Yes, TL-4.');
    const q = (text, since) => shouldPrompt([{ who: 'Them', text }], { sinceLastMs: since, minGapMs: 20000, myLabel: 'Me', useLocalAI: false });
    return {
      entries: m.entries.map((e) => `${e.who}: ${e.text}`),
      gap: await q('What is the deck width?', 3000),
      go: await q('What is the deck width?', 30000),
      small: await q('Morning all, how was the weekend', 30000),
    };
  });
  eq(JSON.stringify(r.entries), JSON.stringify(['Them: What deck width did we use on the Alert Bridge?', 'Them: And the barrier height is 1050?', 'Me: Yes, TL-4.']), 'echo copies dropped, real speech kept');
  eq(r.gap.go, false, 'no prompt inside the minimum gap');
  eq(r.go.go, true, 'question → prompt');
  eq(r.go.reason, 'question', 'reason');
  eq(r.small.go, false, 'short small talk → no paid call');
});


test('meeting, free transcription: real Whisper on this computer, no API key; transcript saved to the NAS', async () => {
  if (!WHISPER_DIR) {
    log('skipped: set WHISPER_TEST_MODEL_DIR to a folder with the Xenova/whisper-base files');
    return;
  }
  const models = await startModelServer(WHISPER_DIR);
  const b = await launch();
  meetingMedia(b);
  const page = await b.open('meeting.html');
  await page.waitForFunction(() => window.meeting?.ready);
  await setSettings(page, { meetingStt: 'whisper', whisperModel: 'Xenova/whisper-base', whisperHost: models.url, meetingPrompts: 'auto', anthropicKey: '', geminiKey: '' });
  await page.uncheck('#chkMic');
  await feedMeetingAudio(page);
  const t0 = Date.now();
  await page.click('#btnApp');
  page.on('console', (m) => process.env.DEBUG && log('console:', m.text()));
  const entry = await waitFor(() => page.evaluate(() => window.meeting.entries.find((e) => e.who === 'Them')), { timeout: 240000, every: 500, what: 'Whisper transcript' }).catch(async (err) => {
    const st = await page.evaluate(() => ({ status: document.getElementById('status').textContent, warn: document.getElementById('warn').textContent, errors: window.meeting.errors, behind: window.meeting.stt?.behindSec, queue: window.meeting.stt?.queue.length, ready: window.meeting.stt?.ready }));
    throw new Error(`${err.message}: ${JSON.stringify(st)} model requests: ${JSON.stringify(models.hits.map((h) => h.file))}`);
  });
  log(`Whisper heard: "${entry.text}" after ${((Date.now() - t0) / 1000).toFixed(1)} s (incl. model load)`);
  const heard = ['question', 'bridge', 'deck', 'width', 'design'].filter((w) => entry.text.toLowerCase().includes(w));
  assert(heard.length >= 3, `transcript resembles the speech (${heard.join(', ')}): ${entry.text}`);
  assert(models.hits.some((h) => h.file === 'onnx/encoder_model_quantized.onnx') && models.hits.some((h) => h.file === 'onnx/decoder_model_merged_quantized.onnx'), 'quantized model files fetched');
  assert(models.hits.every((h) => !h.auth), 'no NAS login sent to a non-NAS host');
  const prompts = await page.evaluate(() => window.meeting.prompts.length);
  eq(prompts, 0, 'no key → no prompts, transcript only');
  await page.click('#btnStop');
  await page.waitForFunction(() => /Saved to the NAS/.test(document.getElementById('status').textContent), null, { timeout: 60000 });
  const saved = await page.evaluate(() => window.meeting.savedPath);
  const md = await dav('GET', saved);
  assert(md.body.includes('Transcribed on this computer (Whisper)') && md.body.includes(entry.text), 'transcript file');
  // Second meeting in the same browser: the model comes from the browser cache, not the network.
  const before = models.hits.length;
  await page.reload();
  await page.waitForFunction(() => window.meeting?.ready);
  await page.uncheck('#chkMic');
  await feedMeetingAudio(page);
  await page.click('#btnApp');
  await waitFor(() => page.evaluate(() => window.meeting.entries.find((e) => e.who === 'Them')), { timeout: 120000, every: 500, what: 'second transcript' });
  eq(models.hits.length, before, 'model loaded from the browser cache the second time');
  await page.click('#btnStop');
  await models.close();
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});


test('audio: the 16 kHz resampler is clean at 48 kHz and 44.1 kHz (no NaN at block edges, right pitch, right length)', async () => {
  const b = await launch();
  const page = await b.open('meeting.html');
  await page.waitForFunction(() => window.meeting?.ready);
  const r = await page.evaluate(async () => {
    const out = {};
    for (const rate of [48000, 44100, 32000]) {
      const ctx = new OfflineAudioContext(1, rate * 2, rate);
      await ctx.audioWorklet.addModule('lib/audio-worklet.js');
      const osc = ctx.createOscillator();
      osc.frequency.value = 440;
      const node = new AudioWorkletNode(ctx, 'pcm-capture');
      const chunks = [];
      node.port.onmessage = (e) => chunks.push(e.data.samples);
      osc.connect(node).connect(ctx.destination);
      osc.start();
      await ctx.startRendering();
      await new Promise((res) => setTimeout(res, 200));
      const all = new Float32Array(chunks.reduce((n, c) => n + c.length, 0));
      let o = 0;
      for (const c of chunks) {
        all.set(c, o);
        o += c.length;
      }
      let bad = 0;
      let crossings = 0;
      for (let i = 1; i < all.length; i++) {
        if (!Number.isFinite(all[i])) bad++;
        if (all[i - 1] < 0 && all[i] >= 0) crossings++;
      }
      out[rate] = { samples: all.length, bad, hz: crossings / (all.length / 16000) };
    }
    return out;
  });
  for (const [rate, v] of Object.entries(r)) {
    eq(v.bad, 0, `${rate} Hz: no NaN samples`);
    assert(Math.abs(v.samples - 32000) <= 1700, `${rate} Hz: ~2 s at 16 kHz (${v.samples})`);
    assert(Math.abs(v.hz - 440) < 5, `${rate} Hz: pitch kept (${v.hz.toFixed(1)} Hz)`);
  }
});

test('meeting: the real screen-share path (Chrome’s picker, fake capture device) starts listening or explains what to tick', async () => {
  const b = await launch({ chromeArgs: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--auto-select-desktop-capture-source=Entire screen'] });
  const page = await b.open('meeting.html');
  await page.waitForFunction(() => window.meeting?.ready);
  await page.uncheck('#chkMic');
  await page.click('#btnApp');
  await page.waitForFunction(() => !document.getElementById('warn').hidden || /cancelled|Listening/.test(document.getElementById('status').textContent), null, { timeout: 20000 });
  const warn = await page.textContent('#warn');
  const status = await page.textContent('#status');
  log(`status: ${status} | warning: ${warn}`);
  assert(/share has no sound.*Entire screen.*system audio/i.test(warn) || /cancelled/.test(status) || /Listening/.test(status), 'friendly outcome');
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});

test('meeting: pop-out window keeps prompts on top and takes private questions', async () => {
  const ai = global.mockAI;
  ai.reset();
  const b = await launch();
  const page = await b.open('meeting.html');
  await page.waitForFunction(() => window.meeting?.ready);
  await setSettings(page, keys());
  meetingClaude(ai);
  const supported = await page.evaluate(() => 'documentPictureInPicture' in window);
  await page.click('#btnPip');
  if (!supported) {
    await page.waitForFunction(() => /cannot keep a window on top/.test(document.getElementById('toast').textContent));
    log('Document Picture-in-Picture not available in this Chromium build; fallback message shown');
    return;
  }
  await page.waitForFunction(() => !!window.meeting.pip, null, { timeout: 10000 });
  await page.evaluate(() => {
    const d = window.meeting.pip.document;
    d.getElementById('pipQ').value = 'What width does our design use?';
    d.getElementById('pipAsk').requestSubmit();
  });
  await page.waitForFunction(() => /12\.0 m clear deck width/.test(window.meeting.pip.document.getElementById('pipList').textContent), null, { timeout: 20000 });
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});


test('OCR on the HP: scanned PDFs and photos become searchable here (only project folders are read)', async () => {
  const which = spawnSync('which', ['tesseract']);
  if (which.status !== 0) {
    log('skipped: tesseract not installed');
    return;
  }
  const { pdf, jpg } = scannedFixtures();
  const b = await launch();
  const { prefix } = await mirrorProjects(b, { pdf: false, extra: [['2024-017 Alert Bridge/Submittals/Submittal 057 CCTV.pdf', pdf], ['2024-017 Alert Bridge/Submittals/site photo.jpg', jpg]] });
  await waitIndexed(b, 7);
  let hits = (await engine(b.sw, { type: 'search', q: 'camera mounting height deck' })).hits;
  eq(hits.filter((h) => /Submittal 057/.test(h.path) && /4\.5 m/.test(h.text)).length, 0, 'scanned text not readable before OCR');
  // The extension told the HP which folders are project folders.
  const pf = JSON.parse((await dav('GET', '/.assistant/project-folders.json')).body);
  assert(pf.folders.includes('/' + prefix), 'project folders published: ' + JSON.stringify(pf));
  // The HP's job (run here against the test WebDAV folder).
  const r = spawnSync('python3', ['-I', OCR_SCRIPT, NAS.root], { encoding: 'utf8' });
  log(r.stdout.trim().split('\n').slice(-1)[0]);
  eq(r.status, 0, 'OCR script: ' + r.stderr);
  assert(!/Existing Share|Uploads #1/.test(r.stdout), 'other NAS folders were not read');
  const res = await engine(b.sw, { type: 'deep.apply', force: false });
  assert(res.started, 'deep apply started');
  await waitFor(async () => !(await engine(b.sw, { type: 'status' })).job, { what: 'deep apply' });
  const st = await engine(b.sw, { type: 'status' });
  assert(st.deep?.applied >= 2, 'OCR results applied: ' + JSON.stringify(st.deep));
  hits = (await engine(b.sw, { type: 'search', q: 'camera mounting height deck' })).hits;
  assert(hits.some((h) => h.path === `${prefix}/2024-017 Alert Bridge/Submittals/Submittal 057 CCTV.pdf` && /4\.5 m above deck/.test(h.text)), 'scanned PDF searchable: ' + JSON.stringify(hits.map((h) => h.path)));
  assert(hits.some((h) => h.path.endsWith('site photo.jpg')), 'photo searchable');
  // Unchanged index on the NAS → not downloaded again.
  await engine(b.sw, { type: 'deep.apply', force: false });
  await waitFor(async () => !(await engine(b.sw, { type: 'status' })).job, { what: 'second apply' });
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});


test('free transcription when huggingface.co is blocked: the model comes from the NAS copy (with the NAS login)', async () => {
  if (!WHISPER_DIR) {
    log('skipped: set WHISPER_TEST_MODEL_DIR');
    return;
  }
  // What server/setup-webdav.sh does on the HP: copy the model into /.assistant/models/<model>/.
  const dest = path.join(NAS.root, '.assistant', 'models', 'Xenova', 'whisper-base');
  for (const f of ['config.json', 'generation_config.json', 'preprocessor_config.json', 'tokenizer.json', 'tokenizer_config.json', 'onnx/encoder_model_quantized.onnx', 'onnx/decoder_model_merged_quantized.onnx']) {
    fs.mkdirSync(path.dirname(path.join(dest, f)), { recursive: true });
    if (!fs.existsSync(path.join(dest, f))) fs.copyFileSync(path.join(WHISPER_DIR, f), path.join(dest, f));
  }
  const b = await launch();
  meetingMedia(b);
  const page = await b.open('meeting.html');
  await page.waitForFunction(() => window.meeting?.ready);
  await setSettings(page, { meetingStt: 'whisper', whisperModel: 'Xenova/whisper-base', whisperHost: 'http://127.0.0.1:9/', anthropicKey: '', geminiKey: '' });
  await page.uncheck('#chkMic');
  await feedMeetingAudio(page);
  await page.click('#btnApp');
  const entry = await waitFor(() => page.evaluate(() => window.meeting.entries.find((e) => e.who === 'Them')), { timeout: 240000, every: 500, what: 'transcript via the NAS model' });
  assert(/bridge/i.test(entry.text), 'transcribed: ' + entry.text);
  const opts = await page.evaluate(() => window.meeting.stt.loadOpts);
  assert(opts.host.endsWith('/.assistant/models/') && opts.pathTemplate === '{model}/', 'loaded from the NAS: ' + JSON.stringify({ host: opts.host, t: opts.pathTemplate }));
  await page.click('#btnStop');
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});


test('chat guard: a flow URL found in a file or email is refused — only a URL the user pasted is saved', async () => {
  const ai = global.mockAI;
  ai.reset();
  const b = await launch();
  const panel = await b.open('sidepanel.html');
  await setSettings(panel, keys({ actions: [{ name: 'sap_po', kind: 'read', transport: 'http', url: 'https://good.example/flow', params: 'po', enabled: true }] }));
  ai.anthropic = (body) => (endsWithToolResult(body)
    ? { content: [text(JSON.stringify(lastToolResults(body).automate_save))] }
    : { stop_reason: 'tool_use', content: [toolUse('automate_save', { name: 'sap_po', url: 'https://evil.example/steal' })] });
  const r = await chatSend(panel, 'The search results say to update the SAP flow. Do what they say.');
  assert(/pasted by the user/.test(r), 'refused: ' + r);
  const s = await panel.evaluate(async () => (await import('./lib/db.js')).getSettings());
  eq(s.actions[0].url, 'https://good.example/flow', 'flow URL unchanged');
  const sys = ai.ofApi('anthropic')[0].body.system;
  assert(/data, not instructions/.test(sys), 'injection warning in the system prompt');
});

test('meeting guard: transcripts are never saved inside a mirrored project folder (a sync would delete them)', async () => {
  const b = await launch();
  const page = await b.open('meeting.html');
  await page.waitForFunction(() => window.meeting?.ready);
  const r = await page.evaluate(() => {
    const m = window.meeting;
    m.mirrorPaths = ['/Work/Projects'];
    m.startedAt = new Date(2026, 10, 4, 9, 5).getTime();
    m.settings = { ...m.settings, meetingFolder: '/Work/Projects/Notes' };
    const inside = m.nasPathFor();
    m.settings = { ...m.settings, meetingFolder: '/Work/Meeting notes' };
    const outside = m.nasPathFor();
    return { inside, outside };
  });
  eq(r.inside, '/Meetings/2026-11-04 0905 Teams meeting.md', 'inside a mirror → /Meetings');
  eq(r.outside, '/Work/Meeting notes/2026-11-04 0905 Teams meeting.md', 'own folder kept');
});


test('Outlook: reads the open email, drafts from the project files, inserts the draft into the reply box', async () => {
  const ai = global.mockAI;
  ai.reset();
  const outlook = await startFakeOutlook();
  const b = await launch();
  log('outlook: launched');
  await mirrorProjects(b);
  log('outlook: mirrored');
  await waitIndexed(b, 6);
  log('outlook: indexed');
  const panel = await b.open('sidepanel.html');
  await setSettings(panel, keys({ extraOutlookUrls: outlook.pattern, processOnOpen: false, autoScan: false, myName: 'Monty' }));
  await panel.evaluate(() => chrome.runtime.sendMessage({ to: 'bg', type: 'scripts.sync' }));
  ai.anthropic = (body) => ({ content: [text(JSON.stringify({ needs_reply: true, category: 'information_request', summary: 'Deck width and barrier level.', requests: [{ ask: 'Deck width', status: 'answered', answer: '12.0 m', sources: ['S1'] }], missing_info: [], search_terms: [], data_requests: [], draft_reply: 'Hi,\n\nThe clear deck width is 12.0 m between barriers; the barriers are TL-4.\n\nMonty', confidence: 'high' }))] });
  log('outlook: opening the page');
  const mail = await b.ctx.newPage();
  await mail.goto(outlook.url);
  log('outlook: page open');
  // The side panel sees Outlook.
  await panel.reload();
  log('outlook: panel reloaded');
  await panel.waitForFunction(() => /Outlook connected/.test(document.getElementById('chips').textContent), null, { timeout: 15000 });
  log('outlook: connected');
  await panel.click('.tabs [data-tab="drafts"]');
  await panel.click('#draftOpen');
  log('outlook: draft requested');
  await panel.selectOption('#filter', 'all');
  await panel.waitForFunction(() => /Ready/.test(document.getElementById('list').textContent), null, { timeout: 30000 });
  const req = ai.ofApi('anthropic')[0].body.messages[0].content.map((c) => c.text).join('\n');
  assert(/Subject: Alert Bridge deck width/.test(req) && /engineer@client\.ca/.test(req), 'email read from the page: ' + req.slice(-400));
  assert(/Deck width: 12\.0 m/.test(req), 'project excerpt included');
  // Insert into the Outlook reply.
  log('outlook: draft ready');
  // "Draft reply to open email" already opened the card.
  if (!(await panel.$('#list .card [data-act="insert"]'))) await panel.click('#list .card .card-head');
  await panel.click('#list .card [data-act="insert"]');
  log('outlook: insert clicked');
  await mail.waitForFunction(() => /12\.0 m between barriers/.test(document.getElementById('ed')?.innerText || ''), null, { timeout: 15000 });
  log('outlook: inserted');
  const sent = await mail.evaluate(() => document.querySelectorAll('[aria-label="Send"]').length);
  eq(sent, 0, 'nothing sent');
  await panel.waitForFunction(() => /Inserted/.test(document.getElementById('list').textContent), null, { timeout: 10000 });
  await mail.screenshot({ path: path.join(SHOTS, 'outlook-inserted.png') });
  await outlook.close();
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});


const FAKE_CAPTURE = ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--auto-select-desktop-capture-source=Entire screen'];

test('recorder: "Record audio" toggle records the computer’s sound + mic into a chosen folder (real share path)', async () => {
  const me = speechWav('me', ME_SAY, { speed: 140, padSec: 2 });
  const b = await launch({ chromeArgs: [...FAKE_CAPTURE, `--use-file-for-fake-audio-capture=${me}`] });
  const page = await b.open('recorder.html');
  await page.waitForFunction(() => window.recorder?.ready);
  await page.evaluate(() => {
    window.recorder.pickFolder = async () => (await navigator.storage.getDirectory()).getDirectoryHandle('My Recordings', { create: true });
  });
  await page.click('#btnFolder');
  await page.waitForFunction(() => /My Recordings/.test(document.getElementById('where').textContent));
  await page.click('#tglAudio');
  await page.waitForFunction(() => document.getElementById('tglAudio').getAttribute('aria-pressed') === 'true', null, { timeout: 15000 });
  await page.waitForFunction(() => parseFloat(document.querySelector('#mMic .fill').style.width) > 0, null, { timeout: 10000 });
  await page.waitForTimeout(3500);
  const during = await page.textContent('#tglAudio');
  assert(/Stop audio recording\s*00:0[3-5]/.test(during), 'toggle shows time: ' + during);
  await page.click('#tglAudio');
  await page.waitForFunction(() => window.recorder.done.length === 1, null, { timeout: 15000 });
  const r = await page.evaluate(async () => {
    const d = window.recorder.done[0];
    const dir = await (await navigator.storage.getDirectory()).getDirectoryHandle('My Recordings');
    const file = await (await dir.getFileHandle(d.name)).getFile();
    const buf = await new AudioContext().decodeAudioData(await file.arrayBuffer());
    const ch = buf.getChannelData(0);
    let sum = 0;
    for (let i = 0; i < ch.length; i++) sum += ch[i] * ch[i];
    return { name: d.name, where: d.where, size: file.size, secs: buf.duration, rms: Math.sqrt(sum / ch.length), mime: d.mime };
  });
  log(`recorded ${r.name} (${r.mime}): ${r.size} bytes, ${r.secs.toFixed(1)} s`);
  assert(/^Recording \d{4}-\d\d-\d\d \d{6} \(audio\)\.(m4a|webm)$/.test(r.name), 'file name: ' + r.name);
  assert(r.secs > 2.5 && r.secs < 6, 'length ≈ the time recorded: ' + r.secs);
  assert(r.rms > 0.001, 'has sound');
  eq(await page.getAttribute('#tglAudio', 'aria-pressed'), 'false', 'toggle off again');
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});

test('recorder: "Record screen + audio" saves a video to Downloads/Recordings (no memory build-up, temp copy removed)', async () => {
  const b = await launch({ chromeArgs: FAKE_CAPTURE });
  const page = await b.open('recorder.html');
  await page.waitForFunction(() => window.recorder?.ready);
  await page.uncheck('#chkMic');
  await page.click('#tglScreen');
  await page.waitForFunction(() => document.getElementById('tglScreen').getAttribute('aria-pressed') === 'true', null, { timeout: 15000 });
  await page.waitForTimeout(3000);
  await page.click('#tglScreen');
  await page.waitForFunction(() => window.recorder.done.length === 1, null, { timeout: 15000 });
  let d = null;
  for (let i = 0; i < 80 && !d; i++) {
    d = await page.evaluate(async () => {
      const [x] = await chrome.downloads.search({ orderBy: ['-startTime'], limit: 1 });
      return x && x.state === 'complete' ? x : null;
    });
    if (!d) await page.waitForTimeout(250);
  }
  assert(d, 'download finished');
  // (Playwright stores downloads under its own names; real Chrome uses the name the extension asks for.)
  const where = await page.evaluate(() => window.recorder.done[0].where);
  assert(/^Downloads\\Recordings\\Recording \d{4}-\d\d-\d\d \d{6} \(screen\)\.(mp4|webm)$/.test(where), 'saved as Downloads/Recordings/…: ' + where);
  const head = fs.readFileSync(d.filename).subarray(0, 12);
  const isWebm = head.readUInt32BE(0) === 0x1a45dfa3;
  const isMp4 = head.subarray(4, 8).toString() === 'ftyp';
  assert(isWebm || isMp4, 'a real video container');
  assert(fs.statSync(d.filename).size > 20000, 'has content: ' + fs.statSync(d.filename).size);
  const leftovers = await page.evaluate(async () => {
    await new Promise((r) => setTimeout(r, 500));
    const dir = await (await navigator.storage.getDirectory()).getDirectoryHandle('recordings-in-progress', { create: true });
    const names = [];
    for await (const [n] of dir.entries()) names.push(n);
    return names;
  });
  eq(leftovers.length, 0, 'temporary copy removed after saving');
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});

test('meeting: "Record audio" toggle saves the meeting’s sound locally while it transcribes', async () => {
  const ai = global.mockAI;
  ai.reset();
  const b = await launch();
  meetingMedia(b);
  const page = await b.open('meeting.html');
  await page.waitForFunction(() => window.meeting?.ready);
  await setSettings(page, keys({ meetingStt: 'gemini', meetingPrompts: 'off', meetingSummary: false }));
  geminiTranscriber(ai);
  await page.evaluate(async () => {
    const { setRecordingFolder } = await import('./lib/recorder.js');
    await setRecordingFolder(await (await navigator.storage.getDirectory()).getDirectoryHandle('Meeting audio', { create: true }));
  });
  await page.uncheck('#chkMic');
  await page.click('#btnRec');
  await page.waitForFunction(() => /Start listening first/.test(document.getElementById('toast').textContent));
  await feedMeetingAudio(page);
  await page.click('#btnTab');
  await page.waitForFunction(() => !!window.meeting.them);
  await page.click('#btnRec');
  await page.waitForFunction(() => document.getElementById('btnRec').getAttribute('aria-pressed') === 'true');
  await page.waitForFunction(() => window.meeting.entries.length > 0, null, { timeout: 20000 });
  await page.click('#btnStop');
  await page.waitForFunction(() => /Saved to the NAS/.test(document.getElementById('status').textContent), null, { timeout: 30000 });
  const r = await page.evaluate(async () => {
    const dir = await (await navigator.storage.getDirectory()).getDirectoryHandle('Meeting audio');
    const out = [];
    for await (const [n, h] of dir.entries()) out.push({ n, size: (await h.getFile()).size });
    return { files: out, md: window.meeting.savedPath };
  });
  assert(r.files.length === 1 && /\(meeting\)\.(m4a|webm)$/.test(r.files[0].n) && r.files[0].size > 5000, 'meeting audio saved: ' + JSON.stringify(r.files));
  const md = await dav('GET', r.md);
  assert(md.body.includes('Audio recording (on the computer): Meeting audio'), 'transcript notes where the recording is');
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});


// A real Outlook .pst (the public EDRM Enron sample, 71 emails) for the mailbox test. PST_TEST_FILE points at it.
const PST_FILE = process.env.PST_TEST_FILE || '';

test('Outlook archives (.pst) on the HP: unpacked into emails, searchable here, cited as "email N"', async () => {
  if (!PST_FILE || spawnSync('which', ['readpst']).status !== 0) {
    log('skipped: needs PST_TEST_FILE and readpst');
    return;
  }
  const ai = global.mockAI;
  ai.reset();
  const b = await launch();
  const { prefix } = await mirrorProjects(b, { pdf: false, extra: [['2024-017 Alert Bridge/Mail/Archive 2001.pst', fs.readFileSync(PST_FILE)]] });
  await waitIndexed(b, 6);
  const r = spawnSync('python3', ['-I', OCR_SCRIPT, NAS.root], { encoding: 'utf8' });
  assert(/Archive 2001\.pst 71 of 71 email/.test(r.stdout), 'PST unpacked on the server: ' + r.stdout.slice(-300));
  await engine(b.sw, { type: 'deep.apply', force: true });
  await waitFor(async () => !(await engine(b.sw, { type: 'status' })).job, { what: 'deep apply' });
  const hits = (await engine(b.sw, { type: 'search', q: 'Transwestern presentations finalize' })).hits;
  const h = hits.find((x) => x.path === `${prefix}/2024-017 Alert Bridge/Mail/Archive 2001.pst`);
  assert(h && h.page > 0 && /Subject: .*Transwestern/i.test(h.text), 'an email inside the PST is found: ' + JSON.stringify(hits.map((x) => [x.path, x.page])));
  // A draft cites it as an email, not a page.
  const panel = await b.open('sidepanel.html');
  await setSettings(panel, keys());
  ai.anthropic = () => ({ content: [text(JSON.stringify({ needs_reply: true, category: 'information_request', summary: 's', requests: [], missing_info: [], search_terms: [], data_requests: [], draft_reply: 'ok', confidence: 'high' }))] });
  await engine(b.sw, { type: 'email.capture', email: { from: 'x@y.ca', subject: 'Transwestern presentations', body: 'Did we finalize the Transwestern presentations?', source: 'manual' } });
  await waitFor(async () => (await panel.evaluate(async () => (await import('./lib/db.js')).getAll('items'))).some((i) => i.status === 'ready'), { what: 'draft' });
  const sent = ai.ofApi('anthropic')[0].body.messages[0].content.map((c) => c.text).join('\n');
  assert(/Archive 2001\.pst \(email \d+\)/.test(sent), 'excerpt labelled as an email');
  // Opening that source shows the email itself (never downloads the whole mailbox).
  await panel.evaluate(({ path, page }) => window.__openSourceForTest(path, page), { path: h.path, page: h.page });
  await panel.waitForSelector('#previewDlg[open]');
  const pv = await panel.textContent('#pvText');
  assert(/Subject: .*Transwestern/i.test(pv) && pv.length < 7000, 'preview shows just that email');
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});

test('Outlook desktop app: "From copied email" reads the clipboard, fills From/Subject, drafts, offers Copy reply', async () => {
  const ai = global.mockAI;
  ai.reset();
  const b = await launch();
  await mirrorProjects(b);
  await waitIndexed(b, 6);
  const panel = await b.open('sidepanel.html');
  await setSettings(panel, keys());
  ai.anthropic = () => ({ content: [text(JSON.stringify({ needs_reply: true, category: 'information_request', summary: 'Pour date.', requests: [], missing_info: [], search_terms: [], data_requests: [], draft_reply: 'Hi Jason,\n\nThe Level 2 pour is on November 4.\n\nMonty', confidence: 'high' }))] });
  await panel.bringToFront();
  await panel.evaluate(() => navigator.clipboard.writeText('From: Jason Giesbrecht <jason@pjselectric.ca>\nSent: Tuesday, November 3, 2026 10:15 AM\nTo: Monty Burke\nSubject: RE: Alert - Level 2 pour\n\nHi Monty,\n\nWhat is the Level 2 pour date?\n\nThanks\nJason'));
  await panel.click('.tabs [data-tab="drafts"]');
  await panel.click('#clipBtn');
  await panel.waitForSelector('#pasteDlg[open]');
  eq(await panel.inputValue('#pFrom'), 'Jason Giesbrecht <jason@pjselectric.ca>', 'sender from the header');
  eq(await panel.inputValue('#pSubject'), 'RE: Alert - Level 2 pour', 'subject from the header');
  assert((await panel.inputValue('#pBody')).startsWith('Hi Monty'), 'body without the header block');
  await panel.click('#pGo');
  await panel.selectOption('#filter', 'all');
  await panel.waitForFunction(() => /Ready/.test(document.getElementById('list').textContent), null, { timeout: 20000 });
  await panel.waitForSelector('#list .card [data-act="copy"].primary');
  eq(await panel.$('#list .card [data-act="insert"]'), null, 'no "Insert into Outlook" for a desktop email');
  await panel.click('#list .card [data-act="copy"]');
  const clip = await panel.evaluate(() => navigator.clipboard.readText());
  assert(/Level 2 pour is on November 4/.test(clip), 'reply on the clipboard, ready to paste into Outlook');
  const req = ai.ofApi('anthropic')[0].body.messages[0].content.map((c) => c.text).join('\n');
  assert(/Pour date is November 4|Level 2 pour date is November 4/.test(req), 'site meeting minutes found locally');
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
});


/** A minimal Word document with these paragraphs (built with Python's zipfile — no Office needed). */
function makeDocx(paras) {
  const out = path.join(WORK, `doc-${Date.now()}.docx`);
  const xml = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>${paras.map((p) => `<w:p><w:r><w:t>${p}</w:t></w:r></w:p>`).join('')}</w:body></w:document>`;
  const r = spawnSync('python3', ['-I', '-c', 'import sys,zipfile\nz=zipfile.ZipFile(sys.argv[1],"w")\nz.writestr("[Content_Types].xml","<Types xmlns=\\"http://schemas.openxmlformats.org/package/2006/content-types\\"/>")\nz.writestr("word/document.xml",sys.argv[2])\nz.close()', out, xml]);
  if (r.status !== 0) throw new Error('docx: ' + r.stderr);
  return fs.readFileSync(out);
}

test('NAS-only folders (standards copied from Google Drive): the HP extracts them, search finds them, nothing local needed', async () => {
  const base = await nasFolder();
  const std = `${base}/Standards`;
  await dav('MKCOL', std + '/');
  const put = (p, buf) => new Promise((resolve, reject) => {
    const u = new URL(p.split('/').map(encodeURIComponent).join('/').replace(/^%2F/, ''), NAS.url);
    const req = http.request(u, { method: 'PUT', headers: { Authorization: 'Basic ' + Buffer.from(`${USER}:${PASSWORD}`).toString('base64'), 'Content-Length': buf.length } }, (res) => {
      res.resume();
      res.on('end', () => resolve(res.statusCode));
    });
    req.on('error', reject);
    req.end(buf);
  });
  await put(`${std}/CSA S6-19 Section 12.pdf`, makePdf(['CSA S6:19 Canadian Highway Bridge Design Code', 'Clause 12.4.3.5: TL-4 barrier height shall be at least 1050 mm.']));
  await put(`${std}/TAC Geometric Design Guide.docx`, makeDocx(['TAC Geometric Design Guide, Chapter 4', 'Typical lane width on a rural arterial: 3.7 m.']));
  const b = await launch();
  const panel = await b.open('sidepanel.html');
  await setSettings(panel, { nasFolders: [std] });
  const run = await engine(b.sw, { type: 'index.run' });
  assert(run.started, 'index run starts with only NAS folders: ' + JSON.stringify(run));
  await waitFor(async () => !(await engine(b.sw, { type: 'status' })).job, { what: 'publish' });
  const pf = JSON.parse((await dav('GET', '/.assistant/project-folders.json')).body);
  assert(pf.nasOnly.includes(std), 'NAS-only folder published: ' + JSON.stringify(pf));
  let r = spawnSync('python3', ['-I', OCR_SCRIPT, NAS.root], { encoding: 'utf8' });
  eq(r.status, 0, r.stderr);
  await engine(b.sw, { type: 'deep.apply', force: false });
  await waitFor(async () => !(await engine(b.sw, { type: 'status' })).job, { what: 'apply' });
  let hits = (await engine(b.sw, { type: 'search', q: 'TL-4 barrier height clause' })).hits;
  assert(hits.some((h) => h.path === `${std.slice(1)}/CSA S6-19 Section 12.pdf` && /1050 mm/.test(h.text)), 'S6 found: ' + JSON.stringify(hits.map((h) => h.path)));
  hits = (await engine(b.sw, { type: 'search', q: 'rural arterial lane width' })).hits;
  assert(hits.some((h) => h.path.endsWith('TAC Geometric Design Guide.docx') && /3\.7 m/.test(h.text)), 'TAC (Word) found');
  const projects = await panel.evaluate(async () => (await import('./lib/db.js')).kvGet('projects'));
  assert(projects.includes(std.slice(1)), 'standards folder listed as a project: ' + JSON.stringify(projects));
  // A normal index run of a mirrored folder keeps the NAS-only files.
  await mirrorProjects(b, { pdf: false });
  await waitIndexed(b, 7);
  hits = (await engine(b.sw, { type: 'search', q: 'TL-4 barrier height clause' })).hits;
  assert(hits.some((h) => h.path.endsWith('CSA S6-19 Section 12.pdf')), 'still there after a local index run');
  // Deleted on the NAS → gone from the index after the next HP run.
  await dav('DELETE', `${std}/TAC Geometric Design Guide.docx`);
  r = spawnSync('python3', ['-I', OCR_SCRIPT, NAS.root], { encoding: 'utf8' });
  await engine(b.sw, { type: 'deep.apply', force: false });
  await waitFor(async () => !(await engine(b.sw, { type: 'status' })).job, { what: 'apply 2' });
  hits = (await engine(b.sw, { type: 'search', q: 'rural arterial lane width' })).hits;
  eq(hits.filter((h) => h.path.endsWith('TAC Geometric Design Guide.docx')).length, 0, 'removed file left the index');
  eq(b.errors.length, 0, `page errors: ${b.errors.join(' | ')}`);
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
