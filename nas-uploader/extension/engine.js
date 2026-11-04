// The engine: a hidden offscreen document that owns the long-running work — indexing the project folders,
// drafting email replies, Power Automate polling and the assistant chat. It is a normal window context, so
// it can use folder handles, DOMParser and pdf.js, and it is not stopped after 30 s idle the way the service
// worker is. (Mirroring itself runs in "NAS files", which has to stay open for big uploads anyway.)

import { getSettings, kvGet, getAll, log } from './lib/db.js';
import { runIndex, applyDeepIndex } from './lib/indexer.js';
import { search, indexSummary, RECENCY_WORDS } from './lib/index.js';
import { getRootHandle, permissionState } from './lib/fsutil.js';
import { processEmail, regenerate, decideRequest, runItemAction, applyFolderResults, teachSource, listItems, summarize } from './lib/assistant.js';
import { pollFolderResponses } from './lib/automate.js';
import { listModels, hasKey, activeModel } from './lib/llm.js';
import { projectFolders } from './lib/folders.js';
import { nasClient, configProblem } from './lib/nas.js';
import { sendChat, chatHistory, clearChat, runPendingTest } from './lib/chat.js';
import { listChanges, undoChange } from './lib/memory.js';
import { CONFIG } from './config.js';

const ui = (type, data) => chrome.runtime.sendMessage({ to: 'ui', type, ...data }).catch(() => {});
const bg = (type, data) => chrome.runtime.sendMessage({ to: 'bg', type, ...data }).catch(() => {});

// ---------- job runner: one file-system job at a time ----------

let job = null; // {name, started, controller, progress}
let indexAgain = false; // a reindex was asked for while another job ran

function startJob(name, fn) {
  if (job) {
    if (name === 'index') indexAgain = true;
    return { busy: true, job: job.name };
  }
  const controller = new AbortController();
  job = { name, started: Date.now(), controller, progress: null };
  const onProgress = (p) => {
    if (job) job.progress = p;
    ui('progress', { job: name, progress: p });
  };
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
      if (indexAgain) {
        indexAgain = false;
        startJob('index', doIndex);
      }
    }
  })();
  return { started: true, job: name };
}

function strip(result) {
  if (!result || typeof result !== 'object') return result;
  const { L, N, ...rest } = result;
  return rest;
}

// ---------- folders and index ----------

async function indexRoots() {
  const folders = (await projectFolders()).filter((f) => f.index);
  const granted = folders.filter((f) => f.perm === 'granted');
  if (!granted.length) {
    if (folders.length) throw new Error('Chrome needs your OK to read the project folders again — click "Reconnect folders" in the side panel.');
    throw new Error('No project folders yet. Add one with "Mirror a folder" (it is mirrored to the NAS and indexed here).');
  }
  return granted.map((f) => ({ root: f.handle, prefix: f.prefix, folderId: f.id, projectMode: f.projectMode }));
}

// The deep (OCR) index is built on the NAS by the HP or a Pi and fetched over WebDAV.
async function deepSource(settings) {
  return {
    get: async () => (await nasClient()).getBlob(settings.deepIndexFile),
    from: 'NAS',
  };
}

async function doIndex({ signal, onProgress }) {
  const settings = await getSettings();
  const roots = await indexRoots();
  const status = await runIndex(roots, settings, { signal, onProgress, rootName: 'local' });
  if (!signal.aborted && !configProblem()) {
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

// ---------- email queue (one draft at a time) ----------

const queue = [];
let draining = false;
const onItem = (item) => {
  ui('item', { id: item.id, status: item.status });
  updateBadge();
};

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

// ---------- chat (one reply at a time) ----------

let chatBusy = null; // AbortController of the reply being written

async function doChat(text) {
  if (chatBusy) return { busy: true };
  chatBusy = new AbortController();
  const signal = chatBusy.signal;
  (async () => {
    try {
      const reply = await sendChat(text, { signal, onUpdate: (m) => ui('chat', { message: m }) });
      if (reply.reindex) startJob('index', doIndex);
    } catch (err) {
      await log('error', `chat: ${err.message}`);
      ui('chat', { error: err.message });
    } finally {
      chatBusy = null;
    }
  })();
  return { started: true };
}

// ---------- timers ----------

let lastAutoIndex = 0;

async function tick() {
  const settings = await getSettings();
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
    try {
      await indexRoots();
      startJob('index', doIndex);
    } catch {
      /* folders not connected */
    }
  }
}

// ---------- status ----------

async function status() {
  const settings = await getSettings();
  const bridge = await getRootHandle('bridge');
  const items = await listItems();
  const folders = await projectFolders().catch(() => []);
  return {
    provider: settings.provider,
    model: activeModel(settings),
    hasKey: hasKey(settings),
    keys: { anthropic: !!settings.anthropicKey, gemini: !!settings.geminiKey },
    folders: {
      bridge: bridge ? { name: bridge.name, perm: await permissionState(bridge) } : null,
    },
    projectFolders: folders.map((f) => ({ id: f.id, name: f.name, nasPath: f.nasPath, perm: f.perm, index: f.index, projectMode: f.projectMode, lastSync: f.lastSync })),
    nas: { configured: !configProblem(), problem: configProblem(), url: CONFIG.serverUrl },
    index: await indexSummary(),
    deep: await kvGet('deepApplied'),
    job: job ? { name: job.name, started: job.started, progress: job.progress } : null,
    queue: queue.length + (draining ? 1 : 0),
    chatBusy: !!chatBusy,
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
  'job.stop': async () => {
    if (job) job.controller.abort();
    return { ok: true };
  },
  // Local search — no tokens. Meeting prompts, the chat and the Files tab all use it.
  search: async (m) => ({
    hits: await search(m.q || '', {
      k: m.k || 12,
      charBudget: m.charBudget || 20000,
      perFile: m.perFile || 2,
      maxChunkChars: m.maxChunkChars || 400,
      boostPrefixes: m.projects || [],
      preferRecent: m.preferRecent ?? RECENCY_WORDS.test(m.q || ''),
      excludePaths: m.excludePaths ? new Set(m.excludePaths) : null,
    }),
  }),
  'nas.test': async () => {
    try {
      const client = await nasClient();
      const entries = await client.list('/');
      return { ok: true, entries: entries.length };
    } catch (err) {
      return { ok: false, error: err.message };
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
  'chat.send': async (m) => doChat(m.text || ''),
  'chat.stop': async () => {
    chatBusy?.abort();
    return { ok: true };
  },
  'chat.history': async () => ({ messages: await chatHistory(), busy: !!chatBusy }),
  'chat.clear': async () => {
    await clearChat();
    return { ok: true };
  },
  'chat.runTest': async (m) => runPendingTest(m.messageId, m.testId),
  'changes.list': async () => ({ changes: await listChanges(40) }),
  'changes.undo': async (m) => {
    const rec = await undoChange(m.id);
    if (/^set_folder_options$/.test(rec.tool)) startJob('index', doIndex);
    return { ok: true, change: rec };
  },
  tick: async () => {
    await tick();
    return { ok: true };
  },
  badge: async () => {
    await updateBadge();
    return { ok: true };
  },
};

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || msg.to !== 'engine') return false;
  const h = handlers[msg.type];
  if (!h) {
    sendResponse({ error: `unknown engine message ${msg.type}` });
    return false;
  }
  Promise.resolve()
    .then(() => h(msg))
    .then((res) => sendResponse(res ?? { ok: true }))
    .catch((err) => sendResponse({ error: err.message || String(err), kind: err.kind }));
  return true;
});

updateBadge();
