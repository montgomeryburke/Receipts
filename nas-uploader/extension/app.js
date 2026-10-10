import { CONFIG } from './config.js';
import { WebDAVClient } from './lib/webdav.js';
import { captureDrop, scanEntries, scanFileList } from './lib/scan.js';
import { TransferManager } from './lib/transfer.js';
import {
  normalizePath,
  joinPath,
  parentPath,
  encodePath,
  safeDecode,
  formatBytes,
  formatDuration,
  formatDate,
  sanitizeDownloadName,
} from './lib/util.js';

const $ = (id) => document.getElementById(id);
const nf = new Intl.NumberFormat();

const state = {
  client: null,
  username: '',
  cwd: '/',
  listingSeq: 0,
  ready: false,
  scanning: null,
  awake: false,
  manager: null,
  prefs: { skipExisting: true, verify: true, skipJunk: true, parallel: 3 },
  passwordBuiltIn: !!CONFIG.password,
  lastFailedSig: '',
};

// ---------------------------------------------------------------------------
// Config, credentials and connection
// ---------------------------------------------------------------------------

function configProblem() {
  const url = String(CONFIG?.serverUrl || '').trim();
  if (!url || /your-nas\.example\.com/i.test(url)) return 'serverUrl is still set to the example address.';
  let u;
  try {
    u = new URL(url);
  } catch {
    return `serverUrl "${url}" is not a valid web address.`;
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return 'serverUrl must start with https:// (or http://).';
  if (CONFIG.username === 'your-nas-username') return 'username is still set to the example value.';
  if (CONFIG.password === 'your-nas-password') return 'password is still set to the example value.';
  return null;
}

function serverLabel() {
  try {
    const u = new URL(CONFIG.serverUrl);
    return u.host;
  } catch {
    return CONFIG.serverUrl;
  }
}

async function storedCreds() {
  if (CONFIG.username && CONFIG.password) return { username: CONFIG.username, password: CONFIG.password };
  let s = {};
  try {
    s = await chrome.storage.session.get(['username', 'password']);
  } catch {
    // storage unavailable — ask every time
  }
  const username = CONFIG.username || s.username || '';
  const password = CONFIG.password || s.password || '';
  return username && password ? { username, password } : null;
}

function setConn(kind, text, title = '') {
  $('conn').dataset.state = kind;
  $('conn-text').textContent = text;
  $('conn').title = title;
}

function showOnly(sectionId) {
  for (const id of ['setup', 'login', 'conn-error', 'app']) $(id).hidden = id !== sectionId;
}

function folderFromHash() {
  const h = location.hash.replace(/^#/, '');
  if (!h) return null;
  return normalizePath(h.split('/').map(safeDecode).join('/'));
}

const CONN_TIPS = {
  network: [
    'Check that serverUrl in config.js is right, including the port (for example :5006 for Synology WebDAV over HTTPS).',
    'Make sure the NAS can be reached from the internet (port forwarding / DDNS / reverse proxy) and that WebDAV is switched on.',
    'If the NAS uses a self-signed certificate, click "Open the NAS address in a tab", accept the warning once, then try again — or install a free Let\'s Encrypt certificate on the NAS.',
    'Some work or hotel networks block unusual ports; HTTPS on port 443 is the most likely to get through.',
  ],
  auth: ['Check username and password in config.js.', 'Make sure this account is allowed to use WebDAV on the NAS (Synology: WebDAV Server → Settings / user permissions).'],
  protocol: [
    'The address answered, but not like a WebDAV server. Make sure serverUrl points at the WebDAV service (e.g. port 5006 on Synology), not the NAS\'s normal login page.',
  ],
};

function showConnError(err) {
  showOnly('conn-error');
  setConn('error', 'Not connected');
  $('conn-error-msg').textContent = err?.message || String(err);
  const tips = err?.status === 401 || err?.status === 403 ? CONN_TIPS.auth : err?.status === 0 ? CONN_TIPS.network : CONN_TIPS.protocol;
  const ul = $('conn-error-tips');
  ul.replaceChildren(...tips.map((t) => Object.assign(document.createElement('li'), { textContent: t })));
}

async function connect(creds, { fromLogin = false } = {}) {
  setConn('connecting', `Connecting to ${serverLabel()}…`);
  const client = new WebDAVClient({ serverUrl: CONFIG.serverUrl, ...creds });
  const candidates = [...new Set([folderFromHash(), normalizePath(CONFIG.startFolder || '/'), '/'].filter(Boolean))];
  let entries = null;
  let folder = null;
  let lastErr = null;
  for (const f of candidates) {
    try {
      entries = await client.list(f);
      folder = f;
      break;
    } catch (err) {
      lastErr = err;
      // Wrong password or no connection would fail the same way for every folder; anything else
      // (missing folder, no permission) is worth trying the next fallback folder for.
      if (err.status === 401 || err.status === 0) break;
    }
  }
  if (!entries) {
    if (lastErr?.status === 401 && !state.passwordBuiltIn) {
      try {
        await chrome.storage.session.remove(['username', 'password']);
      } catch {}
      showLogin('Wrong username or password.');
      return false;
    }
    showConnError(lastErr);
    return false;
  }

  if (fromLogin) {
    try {
      await chrome.storage.session.set({ username: creds.username, password: creds.password });
    } catch {}
  }
  state.client = client;
  state.username = creds.username;
  if (state.manager) state.manager.setClient(client);
  else {
    state.manager = new TransferManager(client, managerOptions());
    state.manager.addEventListener('change', onManagerChange);
  }
  const insecure = new URL(CONFIG.serverUrl).protocol === 'http:';
  setConn('ok', `${serverLabel()} · ${creds.username}${insecure ? ' · not encrypted (http)' : ''}`, insecure ? 'This connection uses http://, so your password and files travel unencrypted. Use https:// if you can.' : '');
  $('btn-lock').hidden = state.passwordBuiltIn;
  showOnly('app');
  state.ready = true;
  await navigate(folder, { entries });
  return true;
}

function showLogin(error) {
  showOnly('login');
  setConn('error', 'Signed out');
  $('login-user').value = CONFIG.username || '';
  $('login-user').disabled = !!CONFIG.username;
  $('login-pass').value = '';
  $('login-error').hidden = !error;
  $('login-error').textContent = error || '';
  (CONFIG.username ? $('login-pass') : $('login-user')).focus();
}

// ---------------------------------------------------------------------------
// Folder browsing
// ---------------------------------------------------------------------------

function renderCrumbs() {
  const nav = $('crumbs');
  const parts = state.cwd.split('/').filter(Boolean);
  const nodes = [];
  const mk = (label, path, current) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = label;
    b.title = path;
    if (current) b.setAttribute('aria-current', 'page');
    else b.addEventListener('click', () => navigate(path));
    return b;
  };
  nodes.push(mk(serverLabel(), '/', parts.length === 0));
  parts.forEach((p, i) => {
    const sep = document.createElement('span');
    sep.className = 'sep';
    sep.textContent = '›';
    nodes.push(sep, mk(p, '/' + parts.slice(0, i + 1).join('/'), i === parts.length - 1));
  });
  nav.replaceChildren(...nodes);
  $('dz-dest').textContent = state.cwd;
  $('overlay-dest').textContent = state.cwd;
  $('btn-up').disabled = state.cwd === '/';
}

async function navigate(path, { entries } = {}) {
  path = normalizePath(path);
  const seq = ++state.listingSeq;
  $('listing-loading').hidden = false;
  $('listing-error').hidden = true;
  try {
    if (!entries) entries = await state.client.list(path);
  } catch (err) {
    if (seq !== state.listingSeq) return;
    $('listing-loading').hidden = true;
    $('listing-error').hidden = false;
    $('listing-error').textContent = `Couldn't open ${path}: ${err.message}`;
    return;
  }
  if (seq !== state.listingSeq) return;
  state.cwd = path;
  const hash = '#' + encodePath(path);
  if (location.hash !== hash) history.replaceState(null, '', hash);
  renderCrumbs();
  renderListing(entries);
  $('listing-loading').hidden = true;
}

function refresh() {
  return navigate(state.cwd);
}

function renderListing(entries) {
  const sorted = [...entries].sort((a, b) => (a.isDir !== b.isDir ? (a.isDir ? -1 : 1) : a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' })));
  const rows = sorted.map((e) => {
    const tr = document.createElement('tr');
    tr.dataset.name = e.name;
    const tdName = document.createElement('td');
    tdName.className = 'c-name';
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'entry ' + (e.isDir ? 'dir' : 'file');
    btn.title = e.name;
    const ico = document.createElement('span');
    ico.className = 'ico';
    ico.textContent = e.isDir ? '📁' : '📄';
    btn.append(ico, document.createTextNode(e.name));
    if (e.isDir) btn.addEventListener('click', () => navigate(e.path));
    tdName.append(btn);

    const tdSize = document.createElement('td');
    tdSize.className = 'c-size';
    tdSize.textContent = e.isDir ? '—' : formatBytes(e.size);
    const tdDate = document.createElement('td');
    tdDate.className = 'c-date';
    tdDate.textContent = formatDate(e.modified);

    const tdAct = document.createElement('td');
    tdAct.className = 'c-act';
    if (!e.isDir) {
      const dl = document.createElement('button');
      dl.type = 'button';
      dl.className = 'icon-btn dl';
      dl.textContent = '⤓';
      dl.title = `Download ${e.name}`;
      dl.setAttribute('aria-label', dl.title);
      dl.addEventListener('click', () => downloadEntry(e));
      tdAct.append(dl);
    }
    const del = document.createElement('button');
    del.type = 'button';
    del.className = 'icon-btn del';
    del.textContent = '🗑';
    del.title = `Delete ${e.name}`;
    del.setAttribute('aria-label', del.title);
    del.addEventListener('click', () => deleteEntry(e));
    tdAct.append(del);
    tr.append(tdName, tdSize, tdDate, tdAct);
    return tr;
  });
  $('listing-body').replaceChildren(...rows);
  $('listing-empty').hidden = rows.length > 0;
}

function validateName(name) {
  const n = name.trim();
  if (!n) return 'Please enter a name.';
  if (n === '.' || n === '..') return 'That name is not allowed.';
  if (/[\\/]/.test(n)) return 'Names cannot contain / or \\.';
  return null;
}

async function newFolder() {
  const name = await dialog({ title: 'New folder', body: `Create a folder inside ${state.cwd}`, input: '', okText: 'Create', validate: validateName });
  if (name === null) return;
  try {
    const r = await state.client.mkdir(joinPath(state.cwd, name.trim()));
    if (r === 'exists') await dialog({ title: 'Folder already exists', body: `"${name.trim()}" already exists here.`, okText: 'OK', noCancel: true });
  } catch (err) {
    await dialog({ title: "Couldn't create folder", body: err.message, okText: 'OK', noCancel: true });
  }
  await refresh();
}

async function deleteEntry(e) {
  const ok = await dialog({
    title: `Delete "${e.name}"?`,
    body: e.isDir ? 'This folder and everything inside it will be permanently deleted from the NAS.' : 'This file will be permanently deleted from the NAS.',
    okText: 'Delete',
    danger: true,
  });
  if (!ok) return;
  try {
    await state.client.remove(e.path, { dir: e.isDir });
  } catch (err) {
    await dialog({ title: "Couldn't delete", body: err.message, okText: 'OK', noCancel: true });
  }
  await refresh();
}

async function downloadEntry(e) {
  try {
    const headers = state.client.authHeader ? [{ name: 'Authorization', value: state.client.authHeader }] : [];
    await chrome.downloads.download({ url: state.client.url(e.path), filename: sanitizeDownloadName(e.name), conflictAction: 'uniquify', saveAs: false, headers });
  } catch (err) {
    await dialog({ title: "Couldn't start download", body: err?.message || String(err), okText: 'OK', noCancel: true });
  }
}

// ---------------------------------------------------------------------------
// Dialog helper (avoids native alert/confirm/prompt)
// ---------------------------------------------------------------------------

let dialogResolve = null;

/**
 * @returns {Promise<any>} input value (string) for input dialogs, true for confirmations, null/false when cancelled.
 */
function dialog({ title, body = '', bodyNodes = null, input = undefined, okText = 'OK', cancelText = 'Cancel', danger = false, noCancel = false, validate = null }) {
  const dlg = $('dialog');
  if (dlg.open) dlg.close('cancel');
  $('dialog-title').textContent = title;
  const bodyEl = $('dialog-body');
  if (bodyNodes) bodyEl.replaceChildren(...bodyNodes);
  else bodyEl.textContent = body;
  const inp = $('dialog-input');
  inp.hidden = input === undefined;
  inp.value = input ?? '';
  $('dialog-error').hidden = true;
  $('dialog-ok').textContent = okText;
  $('dialog-ok').className = 'btn ' + (danger ? 'primary danger-fill' : 'primary');
  $('dialog-cancel').textContent = cancelText;
  $('dialog-cancel').hidden = noCancel;
  dlg._validate = validate;
  dlg._hasInput = input !== undefined;
  dlg.returnValue = '';
  dlg.showModal();
  if (input !== undefined) inp.focus();
  else $('dialog-ok').focus();
  return new Promise((resolve) => {
    dialogResolve = resolve;
  });
}

function wireDialog() {
  const dlg = $('dialog');
  $('dialog-form').addEventListener('submit', (ev) => {
    if (dlg._hasInput && dlg._validate) {
      const msg = dlg._validate($('dialog-input').value);
      if (msg) {
        ev.preventDefault();
        $('dialog-error').textContent = msg;
        $('dialog-error').hidden = false;
        return;
      }
    }
    // Explicitly mark OK (pressing Enter in the input submits without a submitter value).
    ev.preventDefault();
    dlg.close('ok');
  });
  $('dialog-cancel').addEventListener('click', () => dlg.close('cancel'));
  dlg.addEventListener('close', () => {
    const ok = dlg.returnValue === 'ok';
    const r = dialogResolve;
    dialogResolve = null;
    if (!r) return;
    if (dlg._hasInput) r(ok ? $('dialog-input').value : null);
    else r(ok);
  });
}

// ---------------------------------------------------------------------------
// Scanning dropped / picked items and starting uploads
// ---------------------------------------------------------------------------

function el(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (cls) e.className = cls;
  return e;
}

async function startScan(scanFn) {
  if (!state.ready) return;
  if (state.scanning) {
    await dialog({ title: 'Still reading the previous drop', body: 'Please wait until it has been read, then drop again.', noCancel: true });
    return;
  }
  const dest = state.cwd;
  const ac = new AbortController();
  state.scanning = ac;
  updateKeepAwake();
  $('scan-status').hidden = false;
  $('scan-text').textContent = 'Reading dropped items…';
  let result;
  try {
    result = await scanFn({
      skipJunk: state.prefs.skipJunk,
      signal: ac.signal,
      onProgress: ({ files, bytes }) => {
        $('scan-text').textContent = `Reading… ${nf.format(files)} files found (${formatBytes(bytes)})`;
      },
    });
  } catch (err) {
    if (ac.signal.aborted) return;
    await dialog({ title: "Couldn't read the dropped items", body: err?.message || String(err), noCancel: true });
    return;
  } finally {
    state.scanning = null;
    $('scan-status').hidden = true;
    updateKeepAwake();
  }

  if (!result.files.length && !result.dirs.length) {
    const why = result.errors.length ? `${result.errors.length} item(s) could not be read.` : result.skippedJunk ? 'Only system junk files were found.' : 'There was nothing to upload.';
    await dialog({ title: 'Nothing to upload', body: why + ' (Tip: empty folders can only be uploaded by drag & drop, not with "Choose a folder".)', noCancel: true });
    return;
  }

  // Confirm before sending anything.
  const top = [...new Set([...result.files.map((f) => f.rel.split('/')[0] + (f.rel.includes('/') ? '/' : '')), ...result.dirs.map((d) => d.split('/')[0] + '/')])];
  const nodes = [];
  nodes.push(
    el('p', `Upload ${nf.format(result.files.length)} file${result.files.length === 1 ? '' : 's'} (${formatBytes(result.totalBytes)})${result.dirs.length ? ` in ${nf.format(result.dirs.length)} folder${result.dirs.length === 1 ? '' : 's'}` : ''} into ${dest}?`),
  );
  const ul = el('ul');
  for (const t of top.slice(0, 12)) ul.append(el('li', (t.endsWith('/') ? '📁 ' : '📄 ') + t));
  if (top.length > 12) ul.append(el('li', `…and ${top.length - 12} more`, 'muted'));
  nodes.push(ul);
  if (state.prefs.skipExisting) nodes.push(el('p', 'Files already on the NAS with the same size will be skipped; other files with the same name will be replaced.', 'muted small'));
  else nodes.push(el('p', 'Files with the same name on the NAS will be replaced.', 'muted small'));
  if (result.skippedJunk) nodes.push(el('p', `Leaving out ${nf.format(result.skippedJunk)} system junk file(s).`, 'muted small'));
  if (result.errors.length) {
    nodes.push(el('p', `${nf.format(result.errors.length)} item(s) could not be read and will be skipped:`, 'warn-text'));
    const eu = el('ul');
    for (const e of result.errors.slice(0, 20)) eu.append(el('li', `${e.rel} — ${e.message}`, 'small'));
    if (result.errors.length > 20) eu.append(el('li', `…and ${result.errors.length - 20} more`, 'muted small'));
    nodes.push(eu);
  }
  const ok = await dialog({ title: 'Ready to upload', bodyNodes: nodes, okText: 'Upload' });
  if (!ok) return;
  state.manager.addBatch(result, dest);
}

function wireDragAndDrop() {
  let depth = 0;
  const overlay = $('drop-overlay');
  const hasFiles = (e) => !!e.dataTransfer && Array.from(e.dataTransfer.types || []).includes('Files');
  window.addEventListener('dragenter', (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    depth++;
    if (state.ready && !$('dialog').open) overlay.hidden = false;
  });
  window.addEventListener('dragover', (e) => {
    e.preventDefault();
    if (e.dataTransfer) e.dataTransfer.dropEffect = state.ready && hasFiles(e) ? 'copy' : 'none';
  });
  window.addEventListener('dragleave', (e) => {
    if (!hasFiles(e)) return;
    depth = Math.max(0, depth - 1);
    if (depth === 0) overlay.hidden = true;
  });
  window.addEventListener('drop', (e) => {
    e.preventDefault();
    depth = 0;
    overlay.hidden = true;
    if (!state.ready || !hasFiles(e) || $('dialog').open) return;
    const captured = captureDrop(e.dataTransfer); // must happen synchronously
    startScan((opts) => scanEntries(captured, opts));
  });
}

function wirePickers() {
  $('btn-pick-folder').addEventListener('click', () => $('pick-folder').click());
  $('btn-pick-files').addEventListener('click', () => $('pick-files').click());
  for (const id of ['pick-folder', 'pick-files']) {
    $(id).addEventListener('change', (e) => {
      const files = Array.from(e.target.files || []);
      e.target.value = '';
      if (!files.length) return;
      startScan(async (opts) => scanFileList(files, opts));
    });
  }
  $('btn-cancel-scan').addEventListener('click', () => state.scanning?.abort());
}

// ---------------------------------------------------------------------------
// Transfer panel
// ---------------------------------------------------------------------------

let renderTimer = null;
let tickTimer = null;
let lastManagerState = 'idle';

function renderNow() {
  clearTimeout(renderTimer);
  renderTimer = null;
  renderTransfers();
}

function scheduleRender() {
  if (renderTimer) return;
  renderTimer = setTimeout(() => {
    renderTimer = null;
    renderTransfers();
  }, 150);
}

function onManagerChange() {
  const m = state.manager;
  if (m.state !== lastManagerState) {
    renderNow();
    const prev = lastManagerState;
    lastManagerState = m.state;
    updateKeepAwake();
    if (m.busy && !tickTimer) tickTimer = setInterval(renderTransfers, 500);
    if (!m.busy && tickTimer) {
      clearInterval(tickTimer);
      tickTimer = null;
    }
    if ((m.state === 'done' || m.state === 'cancelled') && prev !== 'idle') refresh();
  }
  scheduleRender();
}

function renderTransfers() {
  const m = state.manager;
  if (!m) return;
  const s = m.stats();
  const panel = $('transfers');
  const visible = s.files + s.dirs > 0;
  panel.hidden = !visible;
  if (!visible) {
    document.title = 'NAS Uploader';
    return;
  }
  const problems = s.failedFiles + s.dirsFailed;
  let title;
  let pstate = 'running';
  switch (s.state) {
    case 'running':
      title = 'Uploading…';
      break;
    case 'paused':
      title = m.connectionIssue
        ? `Can't reach the NAS — trying again automatically at ${new Date(m.connectionIssue.resumeAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`
        : 'Paused';
      pstate = m.connectionIssue ? 'problems' : 'running';
      break;
    case 'verifying':
      title = `Double-checking files on the NAS… ${s.verifyProgress ? `(${nf.format(s.verifyProgress.done)} of ${nf.format(s.verifyProgress.total)} folders)` : ''}`;
      break;
    case 'cancelled':
      title = 'Cancelled';
      pstate = 'problems';
      break;
    default:
      title = problems ? `Finished — ${nf.format(problems)} item${problems === 1 ? '' : 's'} need${problems === 1 ? 's' : ''} attention` : 'All done ✓';
      pstate = problems ? 'problems' : 'done';
  }
  $('tr-title').textContent = title;
  panel.dataset.state = pstate;

  const doneish = s.doneBytes + s.inflightBytes;
  const pct = s.totalBytes > 0 ? doneish / s.totalBytes : s.files ? s.doneFiles / s.files : s.dirs ? s.dirsDone / s.dirs : 1;
  $('tr-fill').style.width = `${Math.min(100, pct * 100).toFixed(1)}%`;

  let line = `${nf.format(s.doneFiles)} of ${nf.format(s.files)} files · ${formatBytes(doneish)} of ${formatBytes(s.totalBytes)}`;
  if (s.state === 'running' && s.speed > 0) line += ` · ${formatBytes(s.speed)}/s · about ${formatDuration(s.eta)} left`;
  $('tr-stats').textContent = line;

  const sub = [];
  if (s.uploadedFiles) sub.push(`${nf.format(s.uploadedFiles)} uploaded (${formatBytes(s.uploadedBytes)})`);
  if (s.verifiedFiles) sub.push(`${nf.format(s.verifiedFiles)} double-checked on NAS`);
  if (s.skippedFiles) sub.push(`${nf.format(s.skippedFiles)} already on NAS, skipped`);
  if (s.dirs) sub.push(`${nf.format(s.dirsDone)} of ${nf.format(s.dirs)} empty folders created`);
  if (s.failedFiles) sub.push(`${nf.format(s.failedFiles)} failed`);
  if (s.cancelledFiles) sub.push(`${nf.format(s.cancelledFiles)} cancelled`);
  if (s.elapsed > 1) sub.push(`time ${formatDuration(s.elapsed)}`);
  $('tr-sub').textContent = sub.join(' · ');

  $('btn-pause').hidden = s.state !== 'running';
  $('btn-resume').hidden = s.state !== 'paused';
  $('btn-cancel').hidden = !m.busy;
  const retryable = s.failedFiles + s.dirsFailed + (m.busy ? 0 : s.cancelledFiles);
  $('btn-retry').hidden = retryable === 0;
  $('btn-retry').textContent = `Retry ${nf.format(retryable)} failed`;
  $('btn-clear').hidden = m.busy;

  // Files in flight
  const active = m.activeTasks().filter((t) => t.kind === 'file');
  $('active-list').replaceChildren(
    ...active.map((t) => {
      const li = document.createElement('li');
      const name = el('div', '', 'name');
      name.append(el('bdi', t.rel));
      name.title = t.rel;
      const right = el('div');
      const mini = el('div', undefined, 'mini');
      const fill = el('div');
      fill.style.width = `${t.size ? Math.min(100, (t.loaded / t.size) * 100) : 100}%`;
      mini.append(fill);
      right.append(mini, el('div', `${formatBytes(t.loaded)} / ${formatBytes(t.size)}`, 'muted small'));
      li.append(name, right);
      if (t.note) li.append(el('div', t.note, 'note'));
      return li;
    }),
  );

  // Problems
  const failed = m.tasks.filter((t) => t.status === 'failed');
  const sig = failed.length + ':' + (failed[0]?.id ?? '') + ':' + (failed[failed.length - 1]?.id ?? '');
  $('failed-box').hidden = failed.length === 0;
  if (sig !== state.lastFailedSig) {
    state.lastFailedSig = sig;
    $('failed-summary').textContent = `${nf.format(failed.length)} item${failed.length === 1 ? '' : 's'} could not be uploaded — click to see why`;
    const items = failed.slice(0, 500).map((t) => {
      const li = el('li');
      li.append(el('span', t.rel), el('span', ' — ' + t.error, 'why'));
      return li;
    });
    if (failed.length > 500) items.push(el('li', `…and ${nf.format(failed.length - 500)} more`, 'muted'));
    $('failed-list').replaceChildren(...items);
  }

  const pctText = `${Math.floor(pct * 100)}%`;
  document.title = m.busy ? `${s.state === 'paused' ? 'Paused' : pctText} · NAS Uploader` : problems ? '⚠ NAS Uploader' : 'NAS Uploader';
}

function updateKeepAwake() {
  const busy = !!(state.manager?.busy || state.scanning);
  if (busy === state.awake) return;
  state.awake = busy;
  try {
    if (busy) chrome.power.requestKeepAwake('system');
    else chrome.power.releaseKeepAwake();
  } catch {}
  try {
    chrome.tabs.getCurrent((tab) => {
      if (chrome.runtime.lastError || !tab) return;
      chrome.tabs.update(tab.id, { autoDiscardable: !busy }, () => void chrome.runtime.lastError);
    });
  } catch {}
}

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

function managerOptions() {
  return { concurrency: state.prefs.parallel, skipExisting: state.prefs.skipExisting, verify: state.prefs.verify };
}

async function loadPrefs() {
  const parallel = Math.min(6, Math.max(1, parseInt(CONFIG.parallelUploads, 10) || 3));
  state.prefs.parallel = parallel;
  try {
    const { prefs } = await chrome.storage.local.get('prefs');
    if (prefs) Object.assign(state.prefs, prefs);
  } catch {}
  $('opt-skip').checked = state.prefs.skipExisting;
  $('opt-verify').checked = state.prefs.verify;
  $('opt-junk').checked = state.prefs.skipJunk;
  $('opt-parallel').value = String(state.prefs.parallel);
}

function savePrefs() {
  state.prefs.skipExisting = $('opt-skip').checked;
  state.prefs.verify = $('opt-verify').checked;
  state.prefs.skipJunk = $('opt-junk').checked;
  state.prefs.parallel = parseInt($('opt-parallel').value, 10) || 3;
  if (state.manager) {
    Object.assign(state.manager.options, managerOptions());
    state.manager.pump();
  }
  try {
    chrome.storage.local.set({ prefs: state.prefs });
  } catch {}
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

function wireUi() {
  wireDialog();
  wireDragAndDrop();
  wirePickers();
  for (const id of ['opt-skip', 'opt-verify', 'opt-junk', 'opt-parallel']) $(id).addEventListener('change', savePrefs);

  $('btn-up').addEventListener('click', () => navigate(parentPath(state.cwd)));
  $('btn-refresh').addEventListener('click', refresh);
  $('btn-mkdir').addEventListener('click', newFolder);
  $('btn-pause').addEventListener('click', () => state.manager.pause());
  $('btn-resume').addEventListener('click', () => state.manager.resume());
  $('btn-cancel').addEventListener('click', async () => {
    const ok = await dialog({ title: 'Cancel the upload?', body: 'Files already uploaded stay on the NAS. You can resume later by dropping the same folder again.', okText: 'Cancel upload', cancelText: 'Keep going', danger: true });
    if (ok) state.manager.cancel();
  });
  $('btn-retry').addEventListener('click', () => {
    state.lastFailedSig = '';
    state.manager.retryFailed();
  });
  $('btn-clear').addEventListener('click', () => {
    state.manager.clearFinished();
    state.lastFailedSig = '';
    renderTransfers();
  });

  $('btn-retry-conn').addEventListener('click', init);
  $('btn-open-nas').addEventListener('click', () => chrome.tabs.create({ url: CONFIG.serverUrl }));
  $('btn-lock').addEventListener('click', async () => {
    if (state.manager?.busy) {
      const ok = await dialog({ title: 'Upload in progress', body: 'Locking will stop the current upload. Continue?', okText: 'Lock anyway', danger: true });
      if (!ok) return;
      state.manager.cancel();
    }
    try {
      await chrome.storage.session.remove(['username', 'password']);
    } catch {}
    location.reload();
  });

  $('login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const username = CONFIG.username || $('login-user').value.trim();
    const password = $('login-pass').value;
    if (!username || !password) return;
    $('login-submit').disabled = true;
    $('login-error').hidden = true;
    try {
      await connect({ username, password }, { fromLogin: true });
    } finally {
      $('login-submit').disabled = false;
    }
  });

  window.addEventListener('hashchange', () => {
    const f = folderFromHash();
    if (state.ready && f && f !== state.cwd) navigate(f);
  });

  window.addEventListener('beforeunload', (e) => {
    if (state.manager?.busy || state.scanning) {
      e.preventDefault();
      e.returnValue = '';
    }
  });
}

async function init() {
  const problem = configProblem();
  if (problem) {
    showOnly('setup');
    setConn('error', 'Not configured');
    $('setup-detail').textContent = problem;
    return;
  }
  const creds = await storedCreds();
  if (!creds) {
    showLogin();
    return;
  }
  await connect(creds);
}

// Exposed for automated tests and troubleshooting from DevTools.
window.nasUploader = state;
await loadPrefs();
wireUi();
await init();
