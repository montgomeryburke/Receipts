// IndexedDB storage shared by every extension context (service worker,
// offscreen engine, side panel, options page). Everything persistent lives
// here, including settings and folder handles, so no context needs
// chrome.storage (which offscreen documents cannot use).

const DB_NAME = 'mailmirror';
const DB_VERSION = 1;

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
      if (!db.objectStoreNames.contains('mirror')) db.createObjectStore('mirror', { keyPath: 'path' });
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
  provider: 'anthropic',              // 'anthropic' | 'gemini'
  anthropicKey: '',
  anthropicModel: 'claude-opus-5-5',
  geminiKey: '',
  geminiModel: 'gemini-2.5-flash',
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

  fileSource: 'auto',                 // which copy to index/open: 'local' | 'nas' | 'auto'
  projectDepth: 1,                    // folder depth that names a project
  includeExt: 'pdf,docx,docm,dotx,xlsx,xlsm,pptx,odt,ods,odp,txt,md,csv,tsv,json,xml,html,htm,eml,rtf,log,yaml,yml,ini',
  nameOnlyExt: 'zip,dwg,dxf,rvt,nwd,ifc,jpg,jpeg,png,tif,tiff,gif,bmp,heic,msg,doc,xls,ppt,mpp,kmz,kml,shp',
  excludePatterns: '.git, node_modules, ~$*, *.tmp, Thumbs.db, .DS_Store, desktop.ini',
  maxFileMB: 150,
  maxCharsPerFile: 1000000,
  autoIndexMinutes: 60,
  deepIndexFile: '.mailmirror/deep-index.jsonl.gz',

  // NAS over the internet (HTTPS sync server in nas-sync/server.py). The token
  // is stored here in this browser profile only; entered once, not per sync.
  nasUrl: '',                         // e.g. https://home.example.com:8443
  nasToken: '',
  nasBasePath: '',                    // a subfolder on the server, if any

  // Folders designated to mirror/index. Each: {id, name, remotePath}. The
  // directory handle for each is stored separately under handle:folder:<id>.
  mirrorFolders: [],
  rootRemotePath: '',                 // remote path for the single-folder fallback

  mirrorMode: 'two-way',              // 'two-way' | 'push' (local→NAS) | 'pull' (NAS→local)
  autoSyncMinutes: 0,                 // 0 = manual only
  deleteGuard: 25,                    // refuse a sync that would trash more than this many files

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
