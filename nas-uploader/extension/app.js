import { CONFIG } from './config.js';
import { WebDAVClient } from './lib/webdav.js';
import { captureDrop, scanEntries, scanFileList, scanDirectoryHandle, stripTopFolder, singleTopFolder } from './lib/scan.js';
import { TransferManager } from './lib/transfer.js';
import { MANIFEST_NAME, isProtectedName, listRemoteTree, readManifest, writeManifest, planMirror, buildManifest } from './lib/mirror.js';
import { listMirrors, saveMirror, deleteMirror } from './lib/store.js';
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
  isJunkDir,
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
  mirrors: [],
  pickDirectory: null, // tests can replace the native folder picker
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
    state.manager.addEventListener('settled', onManagerSettled);
  }
  const insecure = new URL(CONFIG.serverUrl).protocol === 'http:';
  setConn('ok', `${serverLabel()} · ${creds.username}${insecure ? ' · not encrypted (http)' : ''}`, insecure ? 'This connection uses http://, so your password and files travel unencrypted. Use https:// if you can.' : '');
  $('btn-lock').hidden = state.passwordBuiltIn;
  showOnly('app');
  state.ready = true;
  await navigate(folder, { entries });
  await loadMirrors();
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
  const sorted = entries.filter((e) => !(e.name === MANIFEST_NAME && !e.isDir)).sort((a, b) => (a.isDir !== b.isDir ? (a.isDir ? -1 : 1) : a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' })));
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

let currentDialog = null;

/**
 * @returns {Promise<any>} input value (string) for input dialogs, true for confirmations, 'alt' for the optional
 *   third button, null/false when cancelled.
 */
function dialog({ title, body = '', bodyNodes = null, input = undefined, okText = 'OK', cancelText = 'Cancel', altText = '', danger = false, noCancel = false, validate = null }) {
  const dlg = $('dialog');
  currentDialog?.supersede();
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
  $('dialog-alt').hidden = !altText;
  $('dialog-alt').textContent = altText;
  dlg._validate = validate;
  dlg._hasInput = input !== undefined;
  dlg.returnValue = '';
  dlg.showModal();
  if (input !== undefined) inp.focus();
  else $('dialog-ok').focus();
  const hasInput = input !== undefined;
  const cancelValue = hasInput ? null : false;
  return new Promise((resolve) => {
    const me = {};
    const finish = (value) => {
      dlg.removeEventListener('close', onClose);
      if (currentDialog === me) currentDialog = null;
      resolve(value);
    };
    const onClose = () => {
      if (dlg.open) return; // a previous dialog's close event arriving late
      const rv = dlg.returnValue;
      finish(rv === 'alt' ? 'alt' : rv === 'ok' ? (hasInput ? inp.value : true) : cancelValue);
    };
    me.supersede = () => finish(cancelValue);
    currentDialog = me;
    dlg.addEventListener('close', onClose);
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
  $('dialog-alt').addEventListener('click', () => dlg.close('alt'));
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

async function startScan(scanFn, { handlePromise = null, knowsEmptyDirs = true } = {}) {
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
  const tops = [...new Set([...result.files.map((f) => f.rel.split('/')[0] + (f.rel.includes('/') ? '/' : '')), ...result.dirs.map((d) => d.split('/')[0] + '/')])];
  const nodes = [];
  nodes.push(
    el('p', `Upload ${nf.format(result.files.length)} file${result.files.length === 1 ? '' : 's'} (${formatBytes(result.totalBytes)})${result.dirs.length ? ` in ${nf.format(result.dirs.length)} folder${result.dirs.length === 1 ? '' : 's'}` : ''} into ${dest}?`),
  );
  const ul = el('ul');
  for (const t of tops.slice(0, 12)) ul.append(el('li', (t.endsWith('/') ? '📁 ' : '📄 ') + t));
  if (tops.length > 12) ul.append(el('li', `…and ${tops.length - 12} more`, 'muted'));
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
  const top = singleTopFolder(result);
  if (top) {
    nodes.push(el('p', `Mirror… instead keeps ${joinPath(dest, top)} identical to this folder: it also removes from the NAS what you deleted here, and moves renamed files instead of sending them again.`, 'muted small'));
  }
  const ok = await dialog({ title: 'Ready to upload', bodyNodes: nodes, okText: 'Upload', altText: top ? 'Mirror…' : '' });
  if (ok === 'alt') {
    let handle = null;
    try {
      const h = await handlePromise;
      if (h && h.kind === 'directory') handle = h;
    } catch {}
    await mirrorFolder({
      name: top,
      nasRoot: joinPath(dest, top),
      local: stripTopFolder(result),
      options: { deletions: true, protectMetadata: true, localKnowsEmptyDirs: knowsEmptyDirs },
      rememberHandle: handle,
    });
    return;
  }
  if (!ok) return;
  state.manager.addBatch(result, dest);
}

// ---------------------------------------------------------------------------
// Mirrors
// ---------------------------------------------------------------------------

function setStatus(text) {
  $('scan-status').hidden = !text;
  if (text) $('scan-text').textContent = text;
}

/**
 * Compare a local folder with a NAS folder, show what will change, and queue it.
 * Either `local` (already scanned, paths relative to the folder) or `scanLocal` must be given.
 */
async function mirrorFolder({ name, nasRoot, local = null, scanLocal = null, options, record = null, rememberHandle = null }) {
  nasRoot = normalizePath(nasRoot);
  if (nasRoot === '/') {
    await dialog({ title: "Can't mirror to the top level", body: 'Choose a folder on the NAS to mirror into, not the top level.', noCancel: true });
    return;
  }
  if (state.manager.busy) {
    await dialog({ title: 'A transfer is still running', body: 'Wait until it has finished (or cancel it), then mirror again.', noCancel: true });
    return;
  }
  if (state.scanning) return;
  const ac = new AbortController();
  state.scanning = ac;
  updateKeepAwake();
  let remote;
  let manifest;
  let plan;
  try {
    if (!local) {
      setStatus(`Reading “${name}” on this computer…`);
      local = await scanLocal({
        skipJunk: state.prefs.skipJunk,
        signal: ac.signal,
        onProgress: ({ files, bytes }) => setStatus(`Reading “${name}”… ${nf.format(files)} files (${formatBytes(bytes)})`),
      });
    }
    setStatus(`Comparing with ${nasRoot} on the NAS…`);
    const localDirKeys = new Set(local.dirs.map((d) => d.normalize('NFC')));
    remote = await listRemoteTree(state.client, nasRoot, {
      signal: ac.signal,
      // Don't walk into NAS-only metadata or system folders (never touched); do walk into ones that exist here too.
      shouldDescend: (rel, n) => localDirKeys.has(rel.normalize('NFC')) || !((options.protectMetadata && isProtectedName(n, true)) || (state.prefs.skipJunk && isJunkDir(n))),
      onProgress: ({ folders, files }) => setStatus(`Comparing with ${nasRoot} on the NAS… ${nf.format(folders)} folders, ${nf.format(files)} files`),
    });
    manifest = remote.exists ? await readManifest(state.client, nasRoot, { signal: ac.signal }) : null;
    plan = planMirror({ local, remote, manifest, options: { ...options, skipJunk: state.prefs.skipJunk } });
  } catch (err) {
    if (ac.signal.aborted) return;
    await dialog({ title: "Couldn't prepare the mirror", body: err?.message || String(err), noCancel: true });
    return;
  } finally {
    state.scanning = null;
    setStatus('');
    updateKeepAwake();
  }

  if (local.errors?.length) plan.warnings.unshift(`${local.errors.length} item(s) in “${name}” could not be read; they are left alone on the NAS.`);
  if (plan.nothingToDo) {
    // Record the current state so the next comparison is exact, then report.
    if (remote.exists) {
      const m = buildManifest({ previous: manifest, plan, remote, tasks: [], sourceName: name });
      await writeManifest(state.client, nasRoot, m).catch(() => {});
    }
    if (record) await recordSync(record, { uploaded: 0, moved: 0, deleted: 0, failed: 0 });
    else if (rememberHandle) await rememberMirror(rememberHandle, name, nasRoot, options);
    await dialog({ title: 'Already in sync', body: `${nasRoot} on the NAS already matches “${name}” (${nf.format(plan.unchanged.length)} files). Nothing to send or delete.`, noCancel: true });
    return;
  }

  const choice = await reviewMirrorPlan({ plan, name, nasRoot, firstSync: !manifest, canRemember: !record && !!rememberHandle, deletionsEnabled: options.deletions !== false });
  if (!choice) return;
  if (!choice.deletions) {
    plan.deletes = [];
    plan.deleteDirs = [];
  }
  if (choice.remember) record = await rememberMirror(rememberHandle, name, nasRoot, options);
  state.manager.addMirror(plan, nasRoot, remote, { manifest, sourceName: name, mirrorId: record?.id || null });
}

function countUploads(plan, reason) {
  const list = plan.uploads.filter((u) => u.reason === reason);
  return { n: list.length, bytes: list.reduce((a, u) => a + u.file.size, 0) };
}

/** Show what a mirror will do. Resolves to {deletions, remember} or null if cancelled. */
async function reviewMirrorPlan({ plan, name, nasRoot, firstSync, canRemember, deletionsEnabled }) {
  const nodes = [el('p', `Make ${nasRoot} on the NAS match “${name}” on this computer:`)];
  const ul = el('ul', undefined, 'plan-list');
  const row = (n, text) => {
    const li = el('li');
    li.append(el('span', nf.format(n), 'n'), document.createTextNode(' ' + text));
    ul.append(li);
  };
  const added = countUploads(plan, 'new');
  const changed = countUploads(plan, 'changed');
  if (added.n) row(added.n, `new file${added.n === 1 ? '' : 's'} to upload (${formatBytes(added.bytes)})`);
  if (changed.n) row(changed.n, `changed file${changed.n === 1 ? '' : 's'} to upload (${formatBytes(changed.bytes)})`);
  if (plan.moves.length) row(plan.moves.length, `renamed or moved file${plan.moves.length === 1 ? '' : 's'}, moved on the NAS without uploading again (${formatBytes(plan.moves.reduce((a, m) => a + m.file.size, 0))} saved)`);
  if (plan.createDirs.length) row(plan.createDirs.length, `new folder${plan.createDirs.length === 1 ? '' : 's'}`);
  row(plan.unchanged.length, 'unchanged, skipped');
  if (plan.keptProtected) row(plan.keptProtected, 'artwork/metadata files that only exist on the NAS (e.g. Jellyfin posters, .nfo), kept');
  if (plan.keptOnNas) row(plan.keptOnNas, 'files only on the NAS, kept (deleting is off for this mirror)');
  nodes.push(ul);
  if (firstSync && plan.unchanged.length) {
    nodes.push(el('p', 'First mirror of this NAS folder: files with the same size that the NAS received after you last changed them count as unchanged.', 'muted small'));
  }

  let delBox = null;
  const delFolders = plan.deleteDirs.length;
  if (plan.deletingFiles > 0 || delFolders > 0) {
    const box = el('div', undefined, 'plan-del');
    const parts = [];
    if (plan.deletes.length) parts.push(`${nf.format(plan.deletes.length)} file${plan.deletes.length === 1 ? '' : 's'}`);
    if (delFolders) parts.push(`${nf.format(delFolders)} folder${delFolders === 1 ? '' : 's'} (${nf.format(plan.deleteDirs.reduce((a, d) => a + d.files, 0))} files inside)`);
    box.append(el('strong', `${parts.join(' and ')} on the NAS ${parts.length === 1 && plan.deletes.length === 1 && !delFolders ? 'is' : 'are'} no longer in your folder:`));
    const dl = el('ul');
    const items = [...plan.deleteDirs.map((d) => `📁 ${d.rel}/`), ...plan.deletes.map((d) => d.rel)];
    for (const t of items.slice(0, 12)) dl.append(el('li', t));
    if (items.length > 12) dl.append(el('li', `…and ${nf.format(items.length - 12)} more`, 'muted'));
    box.append(dl);
    const label = el('label', undefined, 'check');
    delBox = document.createElement('input');
    delBox.type = 'checkbox';
    delBox.id = 'plan-delete';
    // Be cautious by default when the numbers look like a mistake.
    delBox.checked = deletionsEnabled && plan.warnings.length === 0;
    label.append(delBox, document.createTextNode(' Delete them from the NAS'));
    box.append(label);
    nodes.push(box);
  }
  for (const c of plan.conflicts.slice(0, 5)) nodes.push(el('p', `Can't mirror ${c.rel}: ${c.message}.`, 'warn-text small'));
  for (const w of plan.warnings) nodes.push(el('p', '⚠ ' + w, 'plan-warn'));

  let rememberBox = null;
  if (canRemember) {
    const label = el('label', undefined, 'check');
    rememberBox = document.createElement('input');
    rememberBox.type = 'checkbox';
    rememberBox.id = 'plan-remember';
    rememberBox.checked = true;
    label.append(rememberBox, document.createTextNode(` Remember “${name}” for one-click Sync next time`));
    nodes.push(label);
  }
  const ok = await dialog({ title: 'Mirror: review the changes', bodyNodes: nodes, okText: 'Start mirror' });
  if (!ok) return null;
  return { deletions: !!delBox?.checked, remember: !!rememberBox?.checked };
}

async function rememberMirror(handle, name, nasPath, options) {
  if (!handle) return null;
  const rec = {
    id: crypto.randomUUID(),
    name,
    handle,
    nasPath: normalizePath(nasPath),
    deletions: options.deletions !== false,
    protectMetadata: options.protectMetadata !== false,
    serverUrl: CONFIG.serverUrl,
    created: Date.now(),
    lastSync: null,
  };
  try {
    await saveMirror(rec);
  } catch (err) {
    await dialog({ title: "Couldn't remember this mirror", body: err?.message || String(err), noCancel: true });
    return null;
  }
  await loadMirrors();
  return rec;
}

async function recordSync(rec, summary) {
  const fresh = state.mirrors.find((m) => m.id === rec.id) || rec;
  fresh.lastSync = { at: Date.now(), ...summary };
  try {
    await saveMirror(fresh);
  } catch {}
  await loadMirrors();
}

/** After every run: store each mirror's manifest and the "last synced" summary. */
async function onManagerSettled(e) {
  for (const b of e.detail.batches) {
    if (b.kind !== 'mirror') continue;
    const manifest = buildManifest({ previous: b.manifest, plan: b.plan, remote: b.remote, tasks: b.tasks, sourceName: b.sourceName });
    try {
      await writeManifest(state.client, b.root, manifest);
    } catch (err) {
      console.warn('Could not save mirror manifest', err);
    }
    if (b.mirrorId) {
      const done = (k) => b.tasks.filter((t) => t.kind === k && t.status === 'done');
      await recordSync(
        { id: b.mirrorId },
        {
          uploaded: done('file').length,
          moved: done('move').length,
          deleted: done('delete').reduce((n, t) => n + (t.count || 1), 0),
          failed: b.tasks.filter((t) => t.status === 'failed' || t.status === 'cancelled').length,
        },
      );
    }
  }
}

async function loadMirrors() {
  try {
    state.mirrors = (await listMirrors()).filter((m) => m.serverUrl === CONFIG.serverUrl).sort((a, b) => a.created - b.created);
  } catch {
    state.mirrors = [];
  }
  renderMirrors();
}

function canPickFolders() {
  return !!state.pickDirectory || typeof window.showDirectoryPicker === 'function';
}

function renderMirrors() {
  const card = $('mirrors-card');
  card.hidden = !canPickFolders() && !state.mirrors.length;
  $('btn-new-mirror').hidden = !canPickFolders();
  const rows = state.mirrors.map((m) => {
    const li = el('li');
    li.dataset.id = m.id;
    const main = el('div', undefined, 'm-main');
    main.append(el('div', '📁 ' + m.name, 'm-name'), el('div', `→ ${m.nasPath} on the NAS${m.deletions ? '' : ' (never deletes)'}`, 'm-dest'));
    const ls = m.lastSync;
    main.append(
      el(
        'div',
        ls
          ? `Last synced ${new Date(ls.at).toLocaleString()} · ${nf.format(ls.uploaded)} uploaded · ${nf.format(ls.moved)} moved · ${nf.format(ls.deleted)} deleted${ls.failed ? ` · ${nf.format(ls.failed)} problem(s)` : ''}`
          : 'Not synced yet',
        'm-last',
      ),
    );
    const sync = el('button', 'Sync now', 'btn small primary m-sync');
    sync.type = 'button';
    sync.addEventListener('click', () => syncMirror(m));
    const open = el('button', 'Open on NAS', 'btn small m-open');
    open.type = 'button';
    open.addEventListener('click', () => navigate(m.nasPath));
    const del = el('button', 'Remove', 'btn small ghost m-remove');
    del.type = 'button';
    del.addEventListener('click', async () => {
      const ok = await dialog({ title: `Remove the mirror “${m.name}”?`, body: 'Only the shortcut is removed. Nothing is deleted on this computer or on the NAS.', okText: 'Remove' });
      if (!ok) return;
      await deleteMirror(m.id).catch(() => {});
      await loadMirrors();
    });
    li.append(main, sync, open, del);
    return li;
  });
  $('mirror-list').replaceChildren(...rows);
}

async function ensureReadPermission(handle) {
  if (typeof handle.queryPermission !== 'function') return true;
  let p = await handle.queryPermission({ mode: 'read' });
  if (p !== 'granted') p = await handle.requestPermission({ mode: 'read' });
  return p === 'granted';
}

async function syncMirror(m) {
  try {
    if (!(await ensureReadPermission(m.handle))) {
      await dialog({ title: 'No access to the folder', body: `Chrome needs your permission to read “${m.name}”. Click Sync now again and choose Allow.`, noCancel: true });
      return;
    }
  } catch (err) {
    await dialog({ title: "Couldn't open the folder", body: `${err?.message || err}. If “${m.name}” was moved or deleted, remove this mirror and create it again.`, noCancel: true });
    return;
  }
  await mirrorFolder({
    name: m.name,
    nasRoot: m.nasPath,
    scanLocal: (opts) => scanDirectoryHandle(m.handle, opts),
    options: { deletions: m.deletions, protectMetadata: m.protectMetadata, localKnowsEmptyDirs: true },
    record: m,
  });
}

async function newMirror() {
  let handle;
  try {
    handle = await (state.pickDirectory ? state.pickDirectory() : window.showDirectoryPicker({ id: 'nas-mirror', mode: 'read' }));
  } catch (err) {
    if (err?.name !== 'AbortError') await dialog({ title: "Couldn't choose that folder", body: err?.message || String(err), noCancel: true });
    return;
  }
  const field = el('label', 'Mirror into this folder on the NAS', 'field');
  const pathInput = document.createElement('input');
  pathInput.type = 'text';
  pathInput.id = 'mirror-nas-path';
  pathInput.spellcheck = false;
  pathInput.value = joinPath(state.cwd, handle.name);
  field.append(pathInput);
  const mkCheck = (id, text, checked) => {
    const label = el('label', undefined, 'check');
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.id = id;
    box.checked = checked;
    label.append(box, document.createTextNode(' ' + text));
    return { label, box };
  };
  const del = mkCheck('mirror-deletions', 'When I delete files here, delete them from the NAS too (you always see the list first)', true);
  const prot = mkCheck('mirror-protect', 'Never delete artwork or metadata that only exists on the NAS (Jellyfin posters, .nfo files, trickplay)', true);
  const ok = await dialog({
    title: `New mirror: “${handle.name}”`,
    bodyNodes: [el('p', `Keep a NAS folder identical to “${handle.name}” on this computer.`), field, del.label, prot.label],
    okText: 'Create and sync',
  });
  if (!ok) return;
  const nasPath = normalizePath(pathInput.value);
  if (nasPath === '/') {
    await dialog({ title: "Can't mirror to the top level", body: 'Type a folder on the NAS, for example ' + joinPath('/', handle.name), noCancel: true });
    return;
  }
  const options = { deletions: del.box.checked, protectMetadata: prot.box.checked };
  const rec = await rememberMirror(handle, handle.name, nasPath, options);
  if (rec) await syncMirror(rec);
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
    const handlePromise = captured.handlePromises.length === 1 ? captured.handlePromises[0] : null;
    startScan((opts) => scanEntries(captured, opts), { handlePromise });
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
      startScan(async (opts) => scanFileList(files, opts), { knowsEmptyDirs: id !== 'pick-folder' });
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
  const visible = s.files + s.dirs + s.moves + s.deletes > 0;
  panel.hidden = !visible;
  if (!visible) {
    document.title = 'NAS Uploader';
    return;
  }
  const problems = s.failedFiles + s.dirsFailed + s.opsFailed;
  let title;
  let pstate = 'running';
  const mirroring = m.batches.some((b) => b.kind === 'mirror');
  switch (s.state) {
    case 'running':
      title = m.activeTasks().some((t) => t.kind === 'delete') ? 'Removing files you deleted…' : mirroring ? 'Mirroring…' : 'Uploading…';
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
  const ops = s.files + s.moves + s.deletes;
  const opsDone = s.doneFiles + s.movesDone + s.deletesDone;
  const pct = s.totalBytes > 0 ? doneish / s.totalBytes : ops ? opsDone / ops : s.dirs ? s.dirsDone / s.dirs : 1;
  $('tr-fill').style.width = `${Math.min(100, pct * 100).toFixed(1)}%`;

  let line = `${nf.format(s.doneFiles)} of ${nf.format(s.files)} files · ${formatBytes(doneish)} of ${formatBytes(s.totalBytes)}`;
  if (s.state === 'running' && s.speed > 0) line += ` · ${formatBytes(s.speed)}/s · about ${formatDuration(s.eta)} left`;
  $('tr-stats').textContent = line;

  const sub = [];
  if (s.uploadedFiles) sub.push(`${nf.format(s.uploadedFiles)} uploaded (${formatBytes(s.uploadedBytes)})`);
  if (s.verifiedFiles) sub.push(`${nf.format(s.verifiedFiles)} double-checked on NAS`);
  if (s.skippedFiles) sub.push(`${nf.format(s.skippedFiles)} already on NAS, skipped`);
  if (s.moves) sub.push(`${nf.format(s.movesDone)} of ${nf.format(s.moves)} renamed/moved on NAS`);
  if (s.deletes) sub.push(`${nf.format(s.deletedFiles)} deleted from NAS`);
  if (s.dirs) sub.push(`${nf.format(s.dirsDone)} of ${nf.format(s.dirs)} empty folders created`);
  if (s.failedFiles) sub.push(`${nf.format(s.failedFiles)} failed`);
  if (s.cancelledFiles) sub.push(`${nf.format(s.cancelledFiles)} cancelled`);
  if (s.elapsed > 1) sub.push(`time ${formatDuration(s.elapsed)}`);
  $('tr-sub').textContent = sub.join(' · ');

  $('btn-pause').hidden = s.state !== 'running';
  $('btn-resume').hidden = s.state !== 'paused';
  $('btn-cancel').hidden = !m.busy;
  const retryable = s.failedFiles + s.dirsFailed + s.opsFailed + (m.busy ? 0 : s.cancelledFiles);
  $('btn-retry').hidden = retryable === 0;
  $('btn-retry').textContent = `Retry ${nf.format(retryable)} failed`;
  $('btn-clear').hidden = m.busy;

  // Files in flight
  const active = m.activeTasks().filter((t) => t.kind !== 'dir');
  $('active-list').replaceChildren(
    ...active.map((t) => {
      const li = document.createElement('li');
      const name = el('div', '', 'name');
      name.append(el('bdi', t.kind === 'delete' ? `🗑 ${t.rel}` : t.kind === 'move' && !t.fellBack ? `↪ ${t.rel}` : t.rel));
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
  $('btn-new-mirror').addEventListener('click', newMirror);
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
state.renderMirrors = () => renderMirrors();
await loadPrefs();
wireUi();
await init();
