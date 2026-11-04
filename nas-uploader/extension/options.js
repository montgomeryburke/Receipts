import { getSettings, saveSettings, clear, kvSet, get, DEFAULT_SETTINGS } from './lib/db.js';
import { getRootHandle, setRootHandle, permissionState, requestPermission } from './lib/fsutil.js';
import { getRules, deleteRule, addHint } from './lib/teach.js';
import { splitList } from './lib/text.js';
import { projectFolders } from './lib/folders.js';
import { listInstructions, addInstruction, removeInstruction } from './lib/memory.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const bg = (type, data = {}) => chrome.runtime.sendMessage({ to: 'bg', type, ...data });
const engine = (type, data = {}) => bg('engine', { payload: { type, ...data } });

let settings = null;

let toastTimer = null;
function toast(msg, ms = 3500) {
  const t = $('toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, ms);
}

function flashSaved() {
  $('saved').textContent = `Saved ${new Date().toLocaleTimeString()}`;
}

// ---------------------------------------------------------------- simple fields

const NUMERIC = new Set(['snippetCount', 'snippetCharBudget', 'maxEmailChars', 'maxFileMB', 'maxCharsPerFile', 'autoIndexMinutes', 'meetingMinGapSec']);
const NULLABLE = new Set(['priceInPerM', 'priceOutPerM']);

function readField(el) {
  const key = el.dataset.key;
  if (el.type === 'checkbox') return el.checked;
  if (el.type === 'radio') return el.value;
  if (NULLABLE.has(key)) return el.value === '' ? null : Number(el.value);
  if (NUMERIC.has(key)) return Number(el.value) || 0;
  return el.value;
}

function fillFields() {
  document.querySelectorAll('[data-key]').forEach((el) => {
    const v = settings[el.dataset.key];
    if (el.type === 'checkbox') el.checked = !!v;
    else if (el.type === 'radio') el.checked = el.value === v;
    else el.value = v ?? '';
  });
}

const pending = {};
let saveTimer = null;
function queueSave(el) {
  if (el.type === 'radio' && !el.checked) return;
  pending[el.dataset.key] = readField(el);
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    const patch = { ...pending };
    for (const k of Object.keys(pending)) delete pending[k];
    settings = await saveSettings(patch);
    flashSaved();
  }, 300);
}

document.addEventListener('input', (e) => { if (e.target.dataset?.key) queueSave(e.target); });
document.addEventListener('change', (e) => { if (e.target.dataset?.key) queueSave(e.target); });

document.querySelectorAll('[data-reveal]').forEach((b) => b.addEventListener('click', () => {
  const inp = document.querySelector(`[data-key="${b.dataset.reveal}"]`);
  inp.type = inp.type === 'password' ? 'text' : 'password';
  b.textContent = inp.type === 'password' ? 'Show' : 'Hide';
}));

document.querySelectorAll('[data-test]').forEach((b) => b.addEventListener('click', async () => {
  const provider = b.dataset.test;
  const out = document.querySelector(`[data-testout="${provider}"]`);
  await new Promise((r) => setTimeout(r, 350)); // let a just-typed key save
  out.textContent = 'Testing…';
  const res = await engine('llm.models', { provider });
  if (res?.error) { out.innerHTML = `<span class="err">${esc(res.error)}</span>`; return; }
  const models = res.models || [];
  out.textContent = `Key works · ${models.length} models`;
  const dl = $(provider === 'gemini' ? 'geminiModels' : 'anthropicModels');
  dl.innerHTML = models.map((m) => `<option value="${esc(m)}"></option>`).join('');
}));

// ---------------------------------------------------------------- folders

async function renderFolders() {
  const h = await getRootHandle('bridge');
  const el = $('f-bridge');
  if (!h) {
    el.innerHTML = '<span class="pill">not set</span>';
  } else {
    const p = await permissionState(h);
    el.innerHTML = `<b>${esc(h.name)}</b> ${p === 'granted' ? '<span class="pill ok">connected</span>' : '<button type="button" data-grant="bridge">Grant access</button>'}`;
  }
  await renderFolderList();
}

async function renderFolderList() {
  const folders = await projectFolders();
  if (!folders.length) {
    $('folderList').innerHTML = '<p class="small muted">No project folders yet. Click "Mirror a folder…", choose the folder (or the drive folder) that holds your projects, and pick where it goes on the NAS.</p>';
    return;
  }
  $('folderList').innerHTML = folders.map((f) => {
    const state = f.perm === 'granted' ? '<span class="pill ok">connected</span>' : f.perm === 'missing' ? '<span class="pill bad">folder lost — mirror it again</span>' : `<button type="button" data-grant-folder="${esc(f.id)}">Grant access</button>`;
    return `<div class="action-card" data-folder="${esc(f.id)}">
      <div class="row"><b class="grow">📁 ${esc(f.name)} → ${esc(f.nasPath)}</b>${state}</div>
      <div class="row">
        <label class="check small"><input type="checkbox" data-pref="index" ${f.index ? 'checked' : ''}> Index this folder</label>
        <label class="field small" style="min-width:260px"><span>Projects in this folder</span>
          <select data-pref="projectMode">
            <option value="subfolders" ${f.projectMode !== 'single' ? 'selected' : ''}>Each subfolder is a project</option>
            <option value="single" ${f.projectMode === 'single' ? 'selected' : ''}>The whole folder is one project</option>
          </select>
        </label>
      </div>
    </div>`;
  }).join('');
}

$('addFolder').addEventListener('click', () => bg('app.open', { hash: '#new-mirror' }));

$('saveNasFolders').addEventListener('click', async () => {
  const list = $('nasFolders').value.split(/[\n,]/).map((x) => x.trim()).filter(Boolean).map((x) => `/${x.replace(/^\/+|\/+$/g, '')}`).filter((x) => x !== '/');
  settings = await saveSettings({ nasFolders: [...new Set(list)] });
  $('nasFolders').value = settings.nasFolders.join('\n');
  $('nasFoldersOut').textContent = list.length ? 'Saved. The HP reads them on its next run (every 2 hours), then they appear in search.' : 'Saved.';
  engine('index.run');
});
$('openNasFiles').addEventListener('click', () => bg('app.open', { hash: '' }));

$('folderList').addEventListener('change', async (e) => {
  const key = e.target.dataset.pref;
  const card = e.target.closest('[data-folder]');
  if (!key || !card) return;
  const prefs = { ...(settings.folderPrefs || {}) };
  const cur = { ...(prefs[card.dataset.folder] || {}) };
  cur[key] = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
  prefs[card.dataset.folder] = cur;
  settings = await saveSettings({ folderPrefs: prefs });
  flashSaved();
  engine('index.run');
});

$('folderList').addEventListener('click', async (e) => {
  const g = e.target.closest('[data-grant-folder]');
  if (!g) return;
  const f = (await projectFolders({ withPerm: false })).find((x) => x.id === g.dataset.grantFolder);
  if (f) await requestPermission(f.handle, 'read');
  await renderFolderList();
  engine('index.run');
});

document.addEventListener('click', async (e) => {
  const pick = e.target.closest('[data-pick]');
  if (pick) {
    const which = pick.dataset.pick;
    try {
      const h = await window.showDirectoryPicker({ id: `mm-${which}`, mode: 'readwrite' });
      await setRootHandle(which, h);
      toast(`${which} folder set to ${h.name}`);
    } catch (err) {
      if (err.name !== 'AbortError') toast(err.message, 6000);
    }
    renderFolders();
    return;
  }
  const grant = e.target.closest('[data-grant]');
  if (grant) {
    const h = await getRootHandle(grant.dataset.grant);
    await requestPermission(h);
    renderFolders();
  }
});

// ---------------------------------------------------------------- Outlook URLs

$('grantOutlook').addEventListener('click', async () => {
  const origins = splitList($('grantOutlook').closest('section').querySelector('[data-key="extraOutlookUrls"]').value);
  if (!origins.length) { $('grantOut').textContent = 'Add an address first.'; return; }
  try {
    const ok = await chrome.permissions.request({ origins });
    if (ok) await bg('scripts.sync');
    $('grantOut').textContent = ok ? 'Allowed. Reload that Outlook tab.' : 'Not allowed.';
  } catch (err) {
    $('grantOut').textContent = err.message;
  }
});

// ---------------------------------------------------------------- Power Automate actions

const ACTION_DEFAULTS = { name: '', description: '', kind: 'read', transport: 'http', url: '', params: '', autoRun: false, auto: false, timeoutSec: 300, enabled: true };

function actionCard(a, i) {
  return `<div class="action-card stack" data-i="${i}">
    <div class="grid3">
      <label class="field"><span>Name (short, no spaces)</span><input type="text" data-a="name" value="${esc(a.name)}" placeholder="sap_po_status"></label>
      <label class="field"><span>Type</span><select data-a="kind"><option value="read" ${a.kind !== 'write' ? 'selected' : ''}>Read — fetches data</option><option value="write" ${a.kind === 'write' ? 'selected' : ''}>Write — changes records</option></select></label>
      <label class="field"><span>Connection</span><select data-a="transport"><option value="http" ${a.transport !== 'folder' ? 'selected' : ''}>HTTP trigger URL</option><option value="folder" ${a.transport === 'folder' ? 'selected' : ''}>Bridge folder (OneDrive)</option></select></label>
    </div>
    <label class="field" ${a.transport === 'folder' ? 'hidden' : ''}><span>Flow URL (from "When an HTTP request is received")</span>
      <div class="row nowrap"><input type="url" class="grow" data-a="url" value="${esc(a.url)}" placeholder="https://prod-00.canadacentral.logic.azure.com/workflows/…"><button type="button" data-allow="${i}" hidden>Allow this address</button></div></label>
    <label class="field"><span>What it does / when to use it (the AI reads this)</span><textarea data-a="description" rows="2" placeholder="Returns SAP purchase-order status, amounts and vendor for a PO number. Use when an email asks about a PO, invoice or payment.">${esc(a.description)}</textarea></label>
    <label class="field"><span>Parameters — comma separated; "name: hint" or "name={{subject}}" to prefill from the email ({{subject}} {{from}} {{project}} {{summary}} {{status}} {{missing}} {{draft}} {{date}})</span><input type="text" data-a="params" value="${esc(a.params)}" placeholder="po_number: 10-digit SAP PO, project={{project}}"></label>
    <div class="row">
      <label class="check small" ${a.kind === 'write' ? 'hidden' : ''}><input type="checkbox" data-a="autoRun" ${a.autoRun ? 'checked' : ''}> Let the AI run this without asking</label>
      <label class="check small" ${a.kind === 'write' ? '' : 'hidden'}><input type="checkbox" data-a="auto" ${a.auto ? 'checked' : ''}> Run after every draft without asking (e.g. tracker log)</label>
      <label class="check small"><input type="checkbox" data-a="enabled" ${a.enabled !== false ? 'checked' : ''}> Enabled</label>
      <label class="field small" style="width:150px"><span>Timeout (s)</span><input type="number" min="10" data-a="timeoutSec" value="${esc(a.timeoutSec ?? 300)}"></label>
      <span class="grow"></span>
      <button type="button" class="danger" data-remove="${i}">Remove</button>
    </div>
  </div>`;
}

function originPattern(url) {
  try { return `${new URL(url).origin}/*`; } catch { return null; }
}

// Shows "Allow this address" for flow URLs the extension has no access to yet.
async function checkActionAccess() {
  for (const b of document.querySelectorAll('[data-allow]')) {
    const a = settings.actions[Number(b.dataset.allow)];
    const pattern = a && a.transport !== 'folder' ? originPattern(a.url) : null;
    b.hidden = !pattern || await chrome.permissions.contains({ origins: [pattern] }).catch(() => true);
  }
}

function renderActions() {
  const acts = settings.actions || [];
  $('actions').innerHTML = acts.length ? acts.map(actionCard).join('') : '<p class="small muted">No flows yet.</p>';
  checkActionAccess();
}

async function saveActions(rerender = false) {
  settings = await saveSettings({ actions: settings.actions });
  flashSaved();
  if (rerender) renderActions();
}

$('actions').addEventListener('input', (e) => {
  const card = e.target.closest('.action-card');
  const field = e.target.dataset.a;
  if (!card || !field) return;
  const a = settings.actions[Number(card.dataset.i)];
  a[field] = e.target.type === 'checkbox' ? e.target.checked : field === 'timeoutSec' ? Number(e.target.value) || 300 : e.target.value;
  if (field === 'name') a.name = a.name.trim().replace(/\s+/g, '_');
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => saveActions(field === 'kind' || field === 'transport'), 300);
});
$('actions').addEventListener('change', (e) => {
  if (e.target.dataset.a === 'kind' || e.target.dataset.a === 'transport' || e.target.type === 'checkbox') {
    const card = e.target.closest('.action-card');
    const a = settings.actions[Number(card.dataset.i)];
    a[e.target.dataset.a] = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
    saveActions(true);
  }
});
$('actions').addEventListener('focusout', (e) => { if (e.target.dataset.a === 'url') checkActionAccess(); });
$('actions').addEventListener('click', async (e) => {
  const allow = e.target.closest('[data-allow]');
  if (allow) {
    const pattern = originPattern(settings.actions[Number(allow.dataset.allow)].url);
    const ok = pattern && await chrome.permissions.request({ origins: [pattern] }).catch(() => false);
    toast(ok ? 'Access allowed.' : 'Access not granted — the flow cannot be called.');
    checkActionAccess();
    return;
  }
  const r = e.target.closest('[data-remove]');
  if (!r) return;
  if (!confirm('Remove this flow from the assistant? (The flow itself is not touched.)')) return;
  settings.actions.splice(Number(r.dataset.remove), 1);
  saveActions(true);
});
$('addAction').addEventListener('click', () => {
  settings.actions = [...(settings.actions || []), { ...ACTION_DEFAULTS }];
  saveActions(true);
});
$('exportActions').addEventListener('click', async () => {
  await navigator.clipboard.writeText(JSON.stringify(settings.actions || [], null, 2));
  toast('Flow list copied as JSON.');
});
$('importActions').addEventListener('click', async () => {
  const text = prompt('Paste a JSON array of flows (as produced by "Copy as JSON"):');
  if (!text) return;
  try {
    const arr = JSON.parse(text);
    if (!Array.isArray(arr)) throw new Error('expected a JSON array');
    settings.actions = arr.map((a) => ({ ...ACTION_DEFAULTS, ...a }));
    await saveActions(true);
    toast(`Imported ${arr.length} flow(s).`);
  } catch (err) {
    toast(`Could not import: ${err.message}`, 6000);
  }
});

// ---------------------------------------------------------------- teaching

async function renderRules() {
  const rules = await getRules();
  $('rules').innerHTML = rules.length
    ? rules.slice().reverse().map((r) => `<div class="rule"><span class="pill ${r.kind === 'prefer' ? 'ok' : 'bad'}">${r.kind === 'prefer' ? 'use' : 'skip'}</span>
        <span class="grow" title="${esc(r.terms.join(', '))}"><b>${esc(r.path)}</b> <span class="muted">for: ${esc(r.terms.slice(0, 8).join(', '))}${r.sender ? ` · from ${esc(r.sender)}` : ''}</span></span>
        <button type="button" data-del-rule="${esc(r.id)}">Forget</button></div>`).join('')
    : '<p class="small muted">Nothing learned yet.</p>';
}

$('rules').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-del-rule]');
  if (!b) return;
  await deleteRule(b.dataset.delRule);
  renderRules();
});

let hintTimer = null;
$('hintPath').addEventListener('input', () => {
  clearTimeout(hintTimer);
  hintTimer = setTimeout(async () => {
    const q = $('hintPath').value.trim();
    if (q.length < 2) return;
    const res = await engine('search', { q, k: 15 });
    const paths = [...new Set((res?.hits || []).map((h) => h.path))];
    $('hintPaths').innerHTML = paths.map((p) => `<option value="${esc(p)}"></option>`).join('');
  }, 250);
});

$('addHint').addEventListener('click', async () => {
  const text = $('hintText').value.trim();
  const path = $('hintPath').value.trim();
  if (!(await get('files', path))) { $('hintOut').textContent = 'Pick a file from the suggestions (it must be in the index).'; return; }
  try {
    await addHint(text, path);
    $('hintOut').textContent = 'Hint added.';
    $('hintText').value = '';
    $('hintPath').value = '';
    renderRules();
  } catch (err) {
    $('hintOut').textContent = err.message;
  }
});

// ---------------------------------------------------------------- data

$('rebuildIndex').addEventListener('click', async () => {
  if (!confirm('Throw away the index and read every file again? Your files are not touched.')) return;
  await clear('files', 'chunks', 'terms');
  for (const k of ['indexStats', 'deadChunks', 'indexStatus', 'deepApplied', 'projects']) await kvSet(k, null);
  const res = await engine('index.run');
  toast(res?.error || 'Rebuilding the index…');
});
$('clearDrafts').addEventListener('click', async () => {
  if (!confirm('Clear the draft log? Outlook is not touched.')) return;
  await clear('items');
  engine('badge');
  toast('Draft log cleared.');
});
$('clearRules').addEventListener('click', async () => {
  if (!confirm('Forget everything the assistant has been taught about documents?')) return;
  await kvSet('rules', []);
  renderRules();
});

// ---------------------------------------------------------------- standing instructions

const SCOPE_LABEL = { all: 'everything', email: 'email drafts', meeting: 'meetings', chat: 'the chat' };

async function renderInstructions() {
  const list = await listInstructions();
  $('instList').innerHTML = list.length
    ? list.slice().reverse().map((i) => `<div class="rule"><span class="pill">${esc(SCOPE_LABEL[i.scope] || i.scope)}</span><span class="grow">${esc(i.text)}</span><button type="button" data-del-inst="${esc(i.id)}">Remove</button></div>`).join('')
    : '<p class="small muted">None yet.</p>';
}

$('addInst').addEventListener('click', async () => {
  const text = $('instText').value.trim();
  if (!text) return;
  await addInstruction(text, $('instScope').value);
  $('instText').value = '';
  settings = await getSettings();
  renderInstructions();
  flashSaved();
});
$('instList').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-del-inst]');
  if (!b) return;
  await removeInstruction(b.dataset.delInst);
  settings = await getSettings();
  renderInstructions();
});

// ---------------------------------------------------------------- export / import (moving to another computer)

const SECRET = new Set(['anthropicKey', 'geminiKey']);

$('exportSetup').addEventListener('click', async () => {
  const s = await getSettings();
  const out = Object.fromEntries(Object.entries(s).filter(([k]) => !SECRET.has(k) && k !== 'folderPrefs'));
  out.rules = await getRules();
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([JSON.stringify({ projectAssistantSettings: 1, at: new Date().toISOString(), settings: out }, null, 2)], { type: 'application/json' }));
  a.download = `project-assistant-settings-${new Date().toISOString().slice(0, 10)}.json`;
  a.click();
});

$('importSetup').addEventListener('click', () => {
  const inp = document.createElement('input');
  inp.type = 'file';
  inp.accept = 'application/json,.json';
  inp.onchange = async () => {
    try {
      const data = JSON.parse(await inp.files[0].text());
      const incoming = data.settings || data;
      const patch = {};
      for (const [k, v] of Object.entries(incoming)) if (k in DEFAULT_SETTINGS && !SECRET.has(k) && k !== 'folderPrefs') patch[k] = v;
      settings = await saveSettings(patch);
      if (Array.isArray(incoming.rules)) await kvSet('rules', incoming.rules);
      fillFields();
      renderActions();
      renderRules();
      renderInstructions();
      toast(`Imported ${Object.keys(patch).length} settings.`);
    } catch (err) {
      toast(`Could not import: ${err.message}`, 6000);
    }
  };
  inp.click();
});

// ---------------------------------------------------------------- init

(async () => {
  settings = await getSettings();
  fillFields();
  renderFolders();
  renderActions();
  renderRules();
  renderInstructions();
  $('nasFolders').value = (settings.nasFolders || []).join('\n');
  if (location.hash) document.querySelector(location.hash)?.scrollIntoView();
})();
