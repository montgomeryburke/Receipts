// Service worker: routes messages between the Outlook tab, the side panel, the meeting window and the
// engine (offscreen document), runs the one-minute timer, keeps the toolbar badge up to date, and
// opens the NAS file manager (app.html) and the meeting window.

import { getSettings, getAll } from './lib/db.js';
import { splitList } from './lib/text.js';

const OUTLOOK_URLS = [
  'https://outlook.office.com/*',
  'https://outlook.office365.com/*',
  'https://outlook.live.com/*',
  'https://outlook.cloud.microsoft/*',
];

const APP_URL = chrome.runtime.getURL('app.html');
const MEETING_URL = chrome.runtime.getURL('meeting.html');
const RECORDER_URL = chrome.runtime.getURL('recorder.html');

// ---------- engine (offscreen document) ----------

let creating = null;
async function ensureEngine() {
  const contexts = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] });
  if (contexts.length) return;
  if (!creating) {
    creating = chrome.offscreen
      .createDocument({
        url: 'engine.html',
        reasons: ['DOM_PARSER', 'WORKERS', 'BLOBS'],
        justification: 'Indexes project files and prepares email drafts in the background.',
      })
      .catch((err) => {
        if (!String(err.message).includes('single offscreen')) throw err;
      })
      .finally(() => {
        creating = null;
      });
  }
  await creating;
}

async function toEngine(payload) {
  await ensureEngine();
  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      const res = await chrome.runtime.sendMessage({ ...payload, to: 'engine' });
      if (res !== undefined) return res;
    } catch (err) {
      if (!/Receiving end does not exist/i.test(err.message)) throw err;
    }
    await new Promise((r) => setTimeout(r, 150)); // engine still loading its modules
  }
  throw new Error('engine did not respond');
}

// ---------- NAS file manager tab and meeting window ----------

async function findTab(url) {
  try {
    const contexts = await chrome.runtime.getContexts({ contextTypes: ['TAB'] });
    const ctx = contexts.find((c) => c.documentUrl && c.documentUrl.startsWith(url) && c.tabId >= 0);
    if (ctx) return { tabId: ctx.tabId, windowId: ctx.windowId };
  } catch {
    // getContexts unavailable — fall through and open a new tab.
  }
  return null;
}

/** Opens the NAS file manager in a full tab (a popup would close and kill uploads), or focuses it. */
async function openApp(hash = '') {
  const existing = await findTab(APP_URL);
  if (existing) {
    await chrome.tabs.update(existing.tabId, { active: true, ...(hash ? { url: APP_URL + hash } : {}) });
    if (existing.windowId >= 0) await chrome.windows.update(existing.windowId, { focused: true });
    return existing;
  }
  const tab = await chrome.tabs.create({ url: APP_URL + hash });
  return { tabId: tab.id, windowId: tab.windowId };
}

/** The meeting assistant and the recorder get their own small windows, so they keep going when the side panel closes. */
async function openWindow(url, width, height) {
  const existing = await findTab(url);
  if (existing) {
    if (existing.windowId >= 0) await chrome.windows.update(existing.windowId, { focused: true });
    return existing;
  }
  const win = await chrome.windows.create({ url, type: 'popup', width, height });
  return { windowId: win.id, tabId: win.tabs?.[0]?.id };
}
const openMeeting = () => openWindow(MEETING_URL, 460, 780);
const openRecorder = () => openWindow(RECORDER_URL, 420, 640);

// ---------- Outlook ----------

async function outlookUrls() {
  const s = await getSettings();
  return [...OUTLOOK_URLS, ...splitList(s.extraOutlookUrls)];
}

async function outlookTabs() {
  const urls = await outlookUrls();
  const tabs = await chrome.tabs.query({ url: urls }).catch(() => []);
  return tabs.sort((a, b) => (b.active ? 1 : 0) - (a.active ? 1 : 0) || (b.lastAccessed || 0) - (a.lastAccessed || 0));
}

async function toOutlook(payload) {
  const tabs = await outlookTabs();
  if (!tabs.length) return { error: 'No Outlook Web tab is open.' };
  for (const tab of tabs) {
    try {
      const res = await chrome.tabs.sendMessage(tab.id, payload);
      if (res) return { ...res, tabId: tab.id };
    } catch {
      /* content script not loaded in this tab yet */
    }
  }
  return { error: 'Outlook tab found but the extension is not active in it — reload the Outlook tab once.' };
}

// On-premises Outlook (custom URL) needs its content script registered at runtime.
async function syncExtraContentScripts() {
  const s = await getSettings();
  const extra = splitList(s.extraOutlookUrls);
  try {
    await chrome.scripting.unregisterContentScripts({ ids: ['outlook-extra'] });
  } catch {
    /* none */
  }
  if (!extra.length) return;
  const granted = await chrome.permissions.contains({ origins: extra }).catch(() => false);
  if (!granted) return;
  await chrome.scripting.registerContentScripts([
    { id: 'outlook-extra', matches: extra, js: ['content/outlook.js'], runAt: 'document_idle', persistAcrossSessions: true },
  ]);
}

// ---------- messages ----------

const handlers = {
  engine: (m) => toEngine(m.payload),
  'settings.get': async () => {
    const s = await getSettings();
    return { processOnOpen: s.processOnOpen, autoScan: s.autoScan, autoScanOnlyWhenIdle: s.autoScanOnlyWhenIdle };
  },
  'items.known': async () => {
    const items = await getAll('items');
    return { ids: items.map((i) => i.id), convIds: items.map((i) => i.convId).filter(Boolean) };
  },
  'outlook.status': async () => {
    const tabs = await outlookTabs();
    if (!tabs.length) return { open: false };
    const res = await toOutlook({ type: 'ping' });
    return { open: true, active: !res.error, title: tabs[0].title || '', error: res.error };
  },
  'outlook.getOpen': () => toOutlook({ type: 'getOpenEmail' }),
  'outlook.insert': (m) => toOutlook({ type: 'insertDraft', text: m.text, convId: m.convId, itemId: m.itemId }),
  'outlook.scanNow': () => toOutlook({ type: 'scanNow' }),
  'outlook.diagnose': () => toOutlook({ type: 'diagnose' }),
  badge: async (m) => {
    await chrome.action.setBadgeBackgroundColor({ color: '#b45309' });
    await chrome.action.setBadgeText({ text: m.text || '' });
    return { ok: true };
  },
  'scripts.sync': async () => {
    await syncExtraContentScripts();
    return { ok: true };
  },
  // NAS login typed into the file manager (only when config.js has no password). The engine can't read
  // chrome.storage itself, so it asks here.
  'nas.creds': async () => {
    try {
      const s = await chrome.storage.session.get(['username', 'password']);
      return s.username && s.password ? { username: s.username, password: s.password } : { none: true };
    } catch {
      return { none: true };
    }
  },
  'app.open': async (m) => {
    await openApp(m.hash || '');
    return { ok: true };
  },
  'meeting.open': async () => {
    await openMeeting();
    return { ok: true };
  },
  'recorder.open': async () => {
    await openRecorder();
    return { ok: true };
  },
};

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || msg.to !== 'bg') return false;
  const h = handlers[msg.type];
  if (!h) {
    sendResponse({ error: `unknown message ${msg.type}` });
    return false;
  }
  Promise.resolve()
    .then(() => h(msg))
    .then((res) => sendResponse(res ?? { ok: true }))
    .catch((err) => sendResponse({ error: err.message || String(err) }));
  return true;
});

async function setup() {
  await chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {});
  await chrome.alarms.create('tick', { periodInMinutes: 1 });
  await syncExtraContentScripts().catch(() => {});
  await ensureEngine().catch(() => {});
}

chrome.runtime.onInstalled.addListener(setup);
chrome.runtime.onStartup.addListener(setup);

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'tick') toEngine({ type: 'tick' }).catch(() => {});
});

// Used by the automated tests.
globalThis.openApp = openApp;
globalThis.openMeeting = openMeeting;
globalThis.openRecorder = openRecorder;
globalThis.toEngine = toEngine;
