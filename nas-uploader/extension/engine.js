// The engine: a hidden offscreen document that owns all long-running work
// (indexing, mirroring, drafting, Automate polling). It is a normal window
// context, so it can use folder handles, DOMParser and pdf.js, and it is not
// stopped after 30 s idle the way the service worker is.

import { getSettings, kvGet, kvSet, getAll, log } from './lib/db.js';
import { runIndex, applyDeepIndex } from './lib/indexer.js';
import { search, indexSummary } from './lib/index.js';
import { planSync, runSync } from './lib/mirror.js';
import { RemoteStore } from './lib/remote.js';
import { getRootHandle, permissionState } from './lib/fsutil.js';
import {
  processEmail, regenerate, decideRequest, runItemAction, applyFolderResults, teachSource,
  listItems, summarize,
} from './lib/assistant.js';
import { pollFolderResponses } from './lib/automate.js';
import { listModels, hasKey, activeModel } from './lib/llm.js';

const ui = (type, data) => chrome.runtime.sendMessage({ to: 'ui', type, ...data }).catch(() => {});
const bg = (type, data) => chrome.runtime.sendMessage({ to: 'bg', type, ...data }).catch(() => {});

// ---------- job runner: one file-system job at a time ----------

let job = null;           // {name, started, controller, progress}
let lastPlans = null;     // [{pair, plan}] from the last preview, reused by "Run sync"

function startJob(name, fn) {
  if (job) return { busy: true, job: job.name };
  const controller = new AbortController();
  job = { name, started: Date.now(), controller, progress: null };
  const onProgress = (p) => { if (job) job.progress = p; ui('progress', { job: name, progress: p }); };
  (async () => {
    try {
      const result = await fn({ signal: controller.signal, onProgress });
      ui('jobDone', { job: name, result: strip(result) });
    } catch (err) {
      await log('error', `${name}: ${err.message}`);
      ui('jobDone', { job: name, error: err.message });
    } finally {
      job = null;
      ui('status', {});
    }
  })();
  return { started: true, job: name };
}

function strip(result) {
  if (!result || typeof result !== 'object') return result;
  const { L, N, ...rest } = result;
  if (rest.actions && rest.actions.length > 300) rest.actions = rest.actions.slice(0, 300);
  return rest;
}

// ---------- folders ----------

function slug(name) {
  return String(name || '').trim().replace(/[\\/:*?"<>|]+/g, ' ').replace(/\s+/g, ' ').trim() || 'folder';
}

function joinPath(...parts) {
  return parts.map((p) => String(p || '').replace(/^\/+|\/+$/g, '')).filter(Boolean).join('/');
}

async function roots() {
  const [local, nas] = await Promise.all([getRootHandle('local'), getRootHandle('nas')]);
  const [pl, pn] = await Promise.all([permissionState(local), permissionState(nas)]);
  return { local, nas, perm: { local: pl, nas: pn } };
}

// The folders the user designated to mirror/index. Each has a remote path (its
// location on the NAS). Falls back to the single 'local' handle at the NAS root
// when none are configured yet, so a one-folder setup needs no extra step.
async function designatedFolders() {
  const settings = await getSettings();
  const metas = settings.mirrorFolders || [];
  if (!metas.length) {
    const h = await getRootHandle('local');
    if (!h) return [];
    return [{ id: 'local', name: h.name, remotePath: settings.rootRemotePath || '', handle: h, perm: await permissionState(h) }];
  }
  const out = [];
  for (const m of metas) {
    const h = await getRootHandle('folder:' + m.id);
    out.push({
      id: m.id, name: m.name || (h && h.name) || m.id,
      remotePath: m.remotePath != null ? m.remotePath : slug(m.name || (h && h.name)),
      handle: h, perm: h ? await permissionState(h) : 'missing',
    });
  }
  return out;
}

function remoteConfigured(settings) {
  return !!(settings.nasUrl && settings.nasToken);
}

function remoteFor(settings, remotePath = '') {
  return new RemoteStore({
    base: settings.nasUrl, token: settings.nasToken,
    basePath: joinPath(settings.nasBasePath, remotePath), label: 'NAS',
  });
}

// The pairs to mirror: local folder ⇄ its place on the NAS (over HTTPS), or,
// when no NAS connection is set, a single local↔local folder pair (home LAN).
async function mirrorPairs(settings) {
  const folders = await designatedFolders();
  const granted = folders.filter((f) => f.perm === 'granted');
  if (remoteConfigured(settings)) {
    if (!granted.length) throw new Error('Choose at least one folder to mirror (Settings → Folders).');
    return granted.map((f) => ({ label: f.name, local: f.handle, remote: remoteFor(settings, f.remotePath), statePrefix: f.remotePath }));
  }
  const r = await roots();
  if (!r.local || !r.nas) throw new Error('Set up the NAS connection in Settings (NAS over the internet), or choose both a local and a second folder.');
  if (r.perm.local !== 'granted' || r.perm.nas !== 'granted') throw new Error('Folder permission needed — click "Reconnect folders" in the side panel.');
  return [{ label: 'nas', local: r.local, remote: r.nas, statePrefix: '' }];
}

async function indexRoots() {
  const granted = (await designatedFolders()).filter((f) => f.perm === 'granted');
  if (!granted.length) throw new Error('No project folder connected. Choose one in Settings, or click "Reconnect folders".');
  return granted.map((f) => ({ root: f.handle, prefix: f.remotePath, folderId: f.id }));
}

// Where the deep OCR index comes from: the NAS over HTTPS, else a local folder.
async function deepSource(settings) {
  if (remoteConfigured(settings)) {
    const store = remoteFor(settings);
    return { get: () => store.fetchDeepIndex(settings.deepIndexFile), from: 'NAS (HTTPS)' };
  }
  const r = await roots();
  return {
    get: [['nas', r.perm.nas === 'granted' ? r.nas : null], ['local', r.perm.local === 'granted' ? r.local : null]],
    from: 'folder',
  };
}

async function doIndex({ signal, onProgress }) {
  const settings = await getSettings();
  const roots2 = await indexRoots();
  const status = await runIndex(roots2, settings, { signal, onProgress, rootName: 'local' });
  if (!signal.aborted) {
    const src = await deepSource(settings);
    status.deep = await applyDeepIndex(src.get, settings, { signal, onProgress, from: src.from });
  }
  return status;
}

async function doDeep({ signal, onProgress, force }) {
  const settings = await getSettings();
  const src = await deepSource(settings);
  return applyDeepIndex(src.get, settings, { signal, onProgress, force, from: src.from });
}

function aggregatePlans(entries) {
  const actions = [];
  let blocked = '';
  const sumKeys = ['localFiles', 'nasFiles', 'toNas', 'toLocal', 'conflicts', 'trashLocal', 'trashNas', 'adopt'];
  const summary = Object.fromEntries(sumKeys.map((k) => [k, 0]));
  summary.mode = entries[0]?.plan.summary.mode;
  for (const { pair, plan } of entries) {
    if (plan.blocked && !blocked) blocked = plan.blocked;
    for (const a of plan.actions) actions.push({ ...a, path: pair.statePrefix ? `${pair.statePrefix}/${a.path}` : a.path });
    for (const k of sumKeys) summary[k] += plan.summary[k] || 0;
  }
  return { actions, summary, blocked, at: Date.now() };
}

async function doPlan({ signal, onProgress }) {
  const settings = await getSettings();
  const pairs = await mirrorPairs(settings);
  const entries = [];
  for (const pair of pairs) {
    const plan = await planSync(pair.local, pair.remote, settings, { signal, onProgress, statePrefix: pair.statePrefix });
    entries.push({ pair, plan });
    if (signal?.aborted) break;
  }
  lastPlans = entries;
  return aggregatePlans(entries);
}

async function doSync({ signal, onProgress, usePlan, allowLargeDelete }) {
  const settings = await getSettings();
  const pairs = await mirrorPairs(settings);
  const reuse = usePlan && lastPlans && Date.now() - (lastPlans[0]?.plan.at || 0) < 10 * 60000 ? lastPlans : null;
  const statuses = [];
  let done = 0; let total = 0; let bytes = 0; const errors = []; let blocked = '';
  for (const pair of pairs) {
    const plan = reuse?.find((e) => e.pair.statePrefix === pair.statePrefix)?.plan;
    const st = await runSync(pair.local, pair.remote, settings, {
      signal, onProgress, plan, statePrefix: pair.statePrefix, allowLargeDelete, writeStatus: false,
    });
    statuses.push(st);
    done += st.done || 0; total += st.total || 0; bytes += st.bytes || 0;
    if (st.blocked && !blocked) blocked = st.blocked;
    for (const e of st.errors || []) errors.push(`[${pair.label}] ${e}`);
    if (signal?.aborted) break;
  }
  const summary = aggregatePlans(statuses.map((st) => ({ pair: { statePrefix: '' }, plan: { actions: [], summary: st.summary || {} } }))).summary;
  const status = {
    at: Date.now(), ok: errors.length === 0 && !blocked, blocked, summary,
    done, total, bytes, errors: errors.slice(0, 50), folders: pairs.length,
  };
  await kvSet('mirrorStatus', status);
  return status;
}

// ---------- email queue (one draft at a time) ----------

const queue = [];
let draining = false;
const onItem = (item) => { ui('item', { id: item.id, status: item.status }); updateBadge(); };

async function drain() {
  if (draining) return;
  draining = true;
  try {
    while (queue.length) {
      const { email, force } = queue.shift();
      try {
        await processEmail(email, { force, onChange: onItem });
      } catch (err) {
        await log('error', `process: ${err.message}`);
      }
    }
  } finally {
    draining = false;
  }
}

async function updateBadge() {
  const items = await listItems();
  const n = items.filter((i) => ['needs-info', 'needs-approval', 'ready'].includes(i.status)).length;
  bg('badge', { text: n ? String(n) : '' });
}

// ---------- timers ----------

let lastAutoIndex = 0;
let lastAutoSync = 0;

async function tick() {
  const settings = await getSettings();
  // Automate bridge responses.
  try {
    const results = await pollFolderResponses();
    if (results.length) await applyFolderResults(results, { onChange: onItem });
  } catch (err) {
    await log('error', `bridge poll: ${err.message}`);
  }
  if (job) return;
  const now = Date.now();
  const idx = (await kvGet('indexStatus'))?.at || 0;
  if (settings.autoIndexMinutes > 0 && now - Math.max(idx, lastAutoIndex) > settings.autoIndexMinutes * 60000) {
    lastAutoIndex = now;
    try { await indexRoots(); startJob('index', doIndex); } catch { /* folders not connected */ }
    return;
  }
  const ms = (await kvGet('mirrorStatus'))?.at || 0;
  if (settings.autoSyncMinutes > 0 && now - Math.max(ms, lastAutoSync) > settings.autoSyncMinutes * 60000) {
    lastAutoSync = now;
    try {
      await mirrorPairs(settings); // throws if nothing is set up
      startJob('sync', (o) => doSync({ ...o, usePlan: false, allowLargeDelete: false }));
    } catch { /* not connected */ }
  }
}

// ---------- status ----------

async function status() {
  const settings = await getSettings();
  const r = await roots();
  const bridge = await getRootHandle('bridge');
  const items = await listItems();
  const folders = await designatedFolders();
  return {
    provider: settings.provider,
    model: activeModel(settings),
    hasKey: hasKey(settings),
    folders: {
      local: r.local ? { name: r.local.name, perm: r.perm.local } : null,
      nas: r.nas ? { name: r.nas.name, perm: r.perm.nas } : null,
      bridge: bridge ? { name: bridge.name, perm: await permissionState(bridge) } : null,
    },
    mirrorFolders: folders.map((f) => ({ id: f.id, name: f.name, remotePath: f.remotePath, perm: f.perm })),
    nas: {
      configured: remoteConfigured(settings),
      url: settings.nasUrl || '',
      base: settings.nasBasePath || '',
      status: (await kvGet('nasStatus')) || null,
    },
    index: await indexSummary(),
    deep: await kvGet('deepApplied'),
    mirror: await kvGet('mirrorStatus'),
    job: job ? { name: job.name, started: job.started, progress: job.progress } : null,
    queue: queue.length + (draining ? 1 : 0),
    pendingActions: ((await kvGet('pendingActions')) || []).length,
    summary: summarize(items),
    actions: (settings.actions || []).filter((a) => a.enabled !== false).map((a) => ({ name: a.name, kind: a.kind || 'read', description: a.description || '', params: a.params || '' })),
  };
}

// ---------- message handling ----------

const handlers = {
  ping: async () => ({ ok: true }),
  status,
  'index.run': async () => startJob('index', doIndex),
  'deep.apply': async (m) => startJob('deep', (o) => doDeep({ ...o, force: !!m.force })),
  'job.stop': async () => { if (job) job.controller.abort(); return { ok: true }; },
  search: async (m) => ({ hits: await search(m.q || '', { k: m.k || 12, charBudget: 20000, perFile: 2, maxChunkChars: 400 }) }),
  'mirror.plan': async () => startJob('plan', doPlan),
  'mirror.run': async (m) => startJob('sync', (o) => doSync({ ...o, usePlan: !!m.usePlan, allowLargeDelete: !!m.allowLargeDelete })),
  'nas.test': async (m) => {
    const settings = { ...(await getSettings()), ...(m.override || {}) };
    if (!remoteConfigured(settings)) return { ok: false, error: 'Enter the NAS URL and token first.' };
    try {
      const res = await remoteFor(settings).ping();
      const st = { ok: true, at: Date.now(), files: res.files, version: res.version };
      await kvSet('nasStatus', st);
      return st;
    } catch (err) {
      const st = { ok: false, at: Date.now(), error: err.message, kind: err.kind };
      await kvSet('nasStatus', st);
      return st;
    }
  },
  'email.capture': async (m) => {
    if (!m.email) return { error: 'no email' };
    queue.push({ email: m.email, force: !!m.force });
    drain();
    return { queued: true };
  },
  'item.regenerate': async (m) => regenerate(m.id, { notes: m.notes, effort: m.effort, onChange: onItem }),
  'item.reprocess': async (m) => {
    const item = (await getAll('items')).find((i) => i.id === m.id);
    if (!item) return { error: 'not found' };
    queue.push({ email: { ...item, body: item.bodyClean }, force: true });
    drain();
    return { queued: true };
  },
  'item.decide': async (m) => decideRequest(m.id, m.key, m.approve, { params: m.params, onChange: onItem }),
  'item.action': async (m) => runItemAction(m.id, m.action, m.params || {}, { onChange: onItem }),
  'item.teach': async (m) => teachSource(m.id, m.path, m.kind, { onChange: onItem }),
  'llm.models': async (m) => {
    const settings = { ...(await getSettings()), ...(m.override || {}) };
    return { models: await listModels(settings, m.provider || settings.provider) };
  },
  tick: async () => { await tick(); return { ok: true }; },
  badge: async () => { await updateBadge(); return { ok: true }; },
};

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || msg.to !== 'engine') return false;
  const h = handlers[msg.type];
  if (!h) { sendResponse({ error: `unknown engine message ${msg.type}` }); return false; }
  Promise.resolve()
    .then(() => h(msg))
    .then((res) => sendResponse(res ?? { ok: true }))
    .catch((err) => sendResponse({ error: err.message || String(err), kind: err.kind }));
  return true;
});

kvSet('engineStartedAt', Date.now());
updateBadge();
