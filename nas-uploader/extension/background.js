// Clicking the toolbar icon opens the uploader in a full tab (a popup would close and kill uploads),
// or focuses it if it is already open.

const APP_URL = chrome.runtime.getURL('app.html');

async function findAppTab() {
  try {
    const contexts = await chrome.runtime.getContexts({ contextTypes: ['TAB'] });
    const ctx = contexts.find((c) => c.documentUrl && c.documentUrl.startsWith(APP_URL) && c.tabId >= 0);
    if (ctx) return { tabId: ctx.tabId, windowId: ctx.windowId };
  } catch {
    // getContexts unavailable — fall through and open a new tab.
  }
  return null;
}

async function openApp() {
  const existing = await findAppTab();
  if (existing) {
    await chrome.tabs.update(existing.tabId, { active: true });
    if (existing.windowId >= 0) await chrome.windows.update(existing.windowId, { focused: true });
    return;
  }
  await chrome.tabs.create({ url: APP_URL });
}

chrome.action.onClicked.addListener(openApp);
globalThis.openApp = openApp; // used by the automated tests
