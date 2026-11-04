// IndexedDB storage shared by every extension context (service worker,
// offscreen engine, side panel, options page, meeting window). Everything
// persistent lives here, including settings and folder handles, so no context
// needs chrome.storage (which offscreen documents cannot use).

const DB_NAME = 'assistant';
const DB_VERSION = 2;

let dbPromise = null;

export function openDb() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains('kv')) db.createObjectStore('kv');
      if (!db.objectStoreNames.contains('files')) db.createObjectStore('files', { keyPath: 'path' });
      if (!db.objectStoreNames.contains('chunks')) {
        const s = db.createObjectStore('chunks', { keyPath: 'id', autoIncrement: true });
        s.createIndex('path', 'path');
      }
      if (!db.objectStoreNames.contains('terms')) db.createObjectStore('terms', { keyPath: 't' });
      if (!db.objectStoreNames.contains('items')) {
        const s = db.createObjectStore('items', { keyPath: 'id' });
        s.createIndex('processedAt', 'processedAt');
      }
      // v2: chat with the assistant, its undo log, and saved meetings.
      if (!db.objectStoreNames.contains('chat')) db.createObjectStore('chat', { keyPath: 'id', autoIncrement: true });
      if (!db.objectStoreNames.contains('changes')) db.createObjectStore('changes', { keyPath: 'id', autoIncrement: true });
      if (!db.objectStoreNames.contains('meetings')) db.createObjectStore('meetings', { keyPath: 'id' });
    };
    req.onsuccess = () => {
      const db = req.result;
      // Another context upgraded the schema: drop our handle so the next call reopens.
      db.onversionchange = () => { db.close(); dbPromise = null; };
      resolve(db);
    };
    req.onerror = () => { dbPromise = null; reject(req.error); };
  });
  return dbPromise;
}

export function reqP(req) {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export function txDone(tx) {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error('transaction aborted'));
  });
}

export async function tx(stores, mode = 'readonly') {
  const db = await openDb();
  return db.transaction(stores, mode);
}

export async function get(store, key) {
  const t = await tx([store]);
  return reqP(t.objectStore(store).get(key));
}

export async function put(store, value, key) {
  const t = await tx([store], 'readwrite');
  t.objectStore(store).put(value, key);
  return txDone(t);
}

export async function del(store, key) {
  const t = await tx([store], 'readwrite');
  t.objectStore(store).delete(key);
  return txDone(t);
}

export async function getAll(store) {
  const t = await tx([store]);
  return reqP(t.objectStore(store).getAll());
}

export async function clear(...stores) {
  const t = await tx(stores, 'readwrite');
  for (const s of stores) t.objectStore(s).clear();
  return txDone(t);
}

export async function count(store) {
  const t = await tx([store]);
  return reqP(t.objectStore(store).count());
}

// ---- key/value helpers ----

export const kvGet = (key) => get('kv', key);
export const kvSet = (key, value) => put('kv', value, key);

// ---- settings ----

export const DEFAULT_SETTINGS = {
  provider: 'anthropic',              // 'anthropic' | 'gemini' — writes email drafts and answers in the chat
  anthropicKey: '',
  anthropicModel: 'claude-opus-5-5',
  geminiKey: '',
  geminiModel: 'auto',                // 'auto' = the newest Gemini Flash model the key can use
  effort: 'low',                      // low | medium | high — thinking depth / token spend
  anthropicFallbacks: true,           // server-side retry on a fallback model if a request is declined
  anthropicBaseUrl: 'https://api.anthropic.com',
  geminiBaseUrl: 'https://generativelanguage.googleapis.com',
  snippetCount: 8,
  snippetCharBudget: 7000,
  maxEmailChars: 6000,
  refinePass: true,                   // one extra local search + call when info is missing
  priceInPerM: null,                  // override estimated price, USD per 1M input tokens
  priceOutPerM: null,

  myName: '',
  myRole: '',
  signature: '',
  styleNotes: 'Concise, professional, plain language.',

  // Standing instructions the user gave (in the chat or in Settings). Each: {id, scope, text, at}.
  // scope: 'all' | 'email' | 'meeting' | 'chat'. They are added to the matching prompts.
  instructions: [],

  // Project folders are the mirrors kept in "NAS files" (one fileset: mirrored once, indexed once).
  // Per-folder choices, keyed by mirror id: {index: true|false, projectMode: 'subfolders'|'single'}.
  folderPrefs: {},
  // Folders that are only on the NAS (e.g. standards copied from Google Drive): the HP extracts their text and
  // the extension adds it to the same index. NAS paths, e.g. ['/Standards'].
  nasFolders: [],
  includeExt: 'pdf,docx,docm,dotx,xlsx,xlsm,pptx,odt,ods,odp,txt,md,csv,tsv,json,xml,html,htm,eml,rtf,log,yaml,yml,ini',
  nameOnlyExt: 'zip,dwg,dxf,rvt,nwd,ifc,jpg,jpeg,png,tif,tiff,gif,bmp,heic,msg,doc,xls,ppt,mpp,kmz,kml,shp',
  excludePatterns: '.git, node_modules, ~$*, *.tmp, Thumbs.db, .DS_Store, desktop.ini',
  maxFileMB: 150,
  maxCharsPerFile: 1000000,
  maxCharsPerMailbox: 8000000,        // .pst archives unpacked on the HP: newest emails first, up to this much text
  autoIndexMinutes: 60,
  // OCR / deep index built on the NAS (the HP or a Pi) for scanned PDFs, applied to the same files here.
  deepIndexFile: '/.assistant/deep-index.jsonl.gz',

  processOnOpen: true,
  autoScan: true,
  autoScanOnlyWhenIdle: true,
  ignoreSenders: 'noreply, no-reply, donotreply, do-not-reply, notifications@, newsletter, mailer-daemon, postmaster@',
  ignoreSubjects: 'unsubscribe, out of office, automatic reply, undeliverable, delivery status notification',
  extraOutlookUrls: '',               // e.g. https://webmail.example.gc.ca/owa/* for on-premises Outlook

  // Power Automate flows: {name, description, kind:'read'|'write', transport:'http'|'folder',
  // url, params:'name: hint, name={{template}}', autoRun (reads), auto (writes, after each draft),
  // timeoutSec, enabled}
  actions: [],

  // Accuracy and safety
  crossCheck: true,                   // with both keys: the other AI checks drafts, prompts, answers and summaries
  crossCheckRevise: true,             // …and a draft it finds problems in is revised once by the first AI
  dualLookUp: true,                   // with both keys: standards are looked up online by both and compared
  aiPaused: false,                    // the kill switch: no AI calls at all until resumed
  dailyBudgetUsd: 0,                  // stop AI calls for the day once this much is spent (0 = no limit)

  // Meetings
  meetingStt: 'whisper',              // 'whisper' (free, on this computer) | 'gemini' (needs a Gemini key) | 'both' (Gemini, checked by Whisper)
  meetingPrompts: 'auto',             // 'auto' (when a question or a new topic comes up) | 'manual' (Ask now only) | 'off'
  meetingProvider: '',                // '' = same as provider; or 'anthropic' | 'gemini'
  meetingMinGapSec: 20,               // at most one automatic prompt every N seconds (saves tokens)
  meetingWebLookup: true,             // look a standard up online when the project files don't have it
  meetingFolder: '/Meetings',         // transcripts are saved here on the NAS
  meetingSummary: true,               // one call at the end for a summary, decisions and action items
  myVoiceLabel: 'Me',
  whisperModel: 'Xenova/whisper-base.en',
  whisperHost: 'https://huggingface.co/', // or the NAS address, after the setup script copied the model there
  whisperPathTemplate: '{model}/resolve/{revision}/',
};

export async function getSettings() {
  const s = (await kvGet('settings')) || {};
  return { ...DEFAULT_SETTINGS, ...s };
}

export async function saveSettings(patch) {
  const cur = await getSettings();
  const next = { ...cur, ...patch };
  await kvSet('settings', next);
  return next;
}

// ---- simple activity log (ring buffer) ----

export async function log(kind, message, extra) {
  try {
    const entries = (await kvGet('log')) || [];
    entries.push({ at: Date.now(), kind, message, ...(extra ? { extra } : {}) });
    while (entries.length > 200) entries.shift();
    await kvSet('log', entries);
  } catch { /* logging must never break a job */ }
}
