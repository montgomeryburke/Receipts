import { getSettings, saveSettings, getAll, get, put, kvGet } from './lib/db.js';
import { getRootHandle, setRootHandle, permissionState, requestPermission, getFileByPath } from './lib/fsutil.js';
import { updateItem, deleteItem, summarize, emailId } from './lib/assistant.js';
import { paramSpec, defaultParams } from './lib/automate.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const bg = (type, data = {}) => chrome.runtime.sendMessage({ to: 'bg', type, ...data });
const engine = (type, data = {}) => bg('engine', { payload: { type, ...data } });

let status = null;
let items = [];
let settings = null;
const expanded = new Set(JSON.parse(sessionStorage.getItem('mm_expanded') || '[]'));
let lastPlan = null;

function saveExpanded() { sessionStorage.setItem('mm_expanded', JSON.stringify([...expanded].slice(-50))); }

let toastTimer = null;
function toast(msg, ms = 3500) {
  const t = $('toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, ms);
}

function ago(ts) {
  if (!ts) return '';
  const s = Math.round((Date.now() - ts) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return new Date(ts).toLocaleDateString();
}

const fmtN = (n) => (n || 0).toLocaleString();
const money = (c) => (c == null ? '—' : c < 0.01 ? `$${c.toFixed(4)}` : `$${c.toFixed(2)}`);

const STATUS_LABEL = {
  processing: 'Working…', 'needs-approval': 'Approve data request', 'waiting-data': 'Waiting for data',
  'needs-info': 'Needs info', ready: 'Ready', inserted: 'Inserted', sent: 'Sent', 'no-reply': 'No reply needed',
  skipped: 'Skipped', dismissed: 'Dismissed', error: 'Error',
};
const STATUS_PILL = {
  processing: 'info', 'waiting-data': 'info', 'needs-approval': 'warn', 'needs-info': 'warn',
  ready: 'ok', inserted: 'ok', sent: '', error: 'bad',
};
const ACTIVE = new Set(['processing', 'needs-approval', 'waiting-data', 'needs-info', 'ready', 'error']);

// ---------------------------------------------------------------- data

async function refresh() {
  [settings, items] = await Promise.all([getSettings(), getAll('items')]);
  items.sort((a, b) => (b.capturedAt || 0) - (a.capturedAt || 0));
  try {
    const s = await engine('status');
    if (s && !s.error) status = s;
  } catch { /* engine starting */ }
  render();
}

let refreshTimer = null;
function refreshSoon(ms = 150) {
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(refresh, ms);
}

// ---------------------------------------------------------------- render

function render() {
  renderChips();
  renderSetup();
  renderReconnect();
  renderSummary();
  renderList();
  renderQuestions();
  renderFiles();
  renderMirror();
  renderAutomate();
}

function chip(text, cls, title = '') {
  return `<span class="pill ${cls}" title="${esc(title)}">${esc(text)}</span>`;
}

function renderChips() {
  const c = [];
  if (!status) { $('chips').innerHTML = chip('Starting…', 'info'); return; }
  c.push(status.hasKey ? chip(`${status.provider === 'gemini' ? 'Gemini' : 'Claude'} · ${status.model}`, 'ok') : chip('No API key', 'bad'));
  const idx = status.index?.status;
  c.push(idx ? chip(`Index · ${fmtN(idx.files)} files`, idx.errors?.length ? 'warn' : 'ok', `Last run ${ago(idx.at)}`) : chip('Not indexed', 'warn'));
  if (status.nas?.configured || status.folders.nas) {
    const m = status.mirror;
    c.push(m ? chip(`Mirror · ${ago(m.at)}`, m.ok ? 'ok' : 'warn', m.blocked || '') : chip('Mirror · never', ''));
  }
  if (status.job) c.push(chip(`${status.job.name}…`, 'info'));
  if (status.queue) c.push(chip(`${status.queue} drafting`, 'info'));
  if (status.pendingActions) c.push(chip(`${status.pendingActions} flow${status.pendingActions > 1 ? 's' : ''} pending`, 'info'));
  c.push('<span id="outlookChip"></span>');
  $('chips').innerHTML = c.join('');
  updateOutlookChip();
}

let outlookState = null;
async function updateOutlookChip() {
  try { outlookState = await bg('outlook.status'); } catch { outlookState = null; }
  const el = $('outlookChip');
  if (!el) return;
  if (!outlookState?.open) el.innerHTML = chip('Outlook not open', '', 'Open Outlook on the web in a tab');
  else if (!outlookState.active) el.innerHTML = chip('Reload Outlook tab', 'warn', outlookState.error || '');
  else el.innerHTML = chip('Outlook connected', 'ok', 'Click to check what MailMirror can read on the Outlook page');
  el.style.cursor = 'pointer';
  el.onclick = outlookCheck;
}

// Shows what the content script detects on the real Outlook page.
async function outlookCheck() {
  const d = await bg('outlook.diagnose');
  const yes = (v) => (v ? 'yes' : 'NO');
  const lines = d?.error ? [d.error] : [
    `Page: ${d.url}`,
    `Message list items found: ${d.messageList}${d.messageList ? '' : '  ← new-mail watching needs this'}`,
    `A message is selected: ${yes(d.selectedItem)}`,
    `Reading pane found: ${yes(d.readingPane)}`,
    `Message body found: ${yes(d.bodies)}${d.bodies ? ` (${d.bodyChars} characters)` : '  ← open an email first'}`,
    `Subject read: ${d.subject || '—'}`,
    `Sender read: ${d.from || '—'}`,
    `Date read: ${d.date || '—'}`,
    `Reply button found: ${yes(d.replyButton)}`,
    `Reply editor open: ${yes(d.composeOpen)}`,
  ];
  $('pvTitle').textContent = 'Outlook check';
  $('pvText').textContent = lines.join('\n');
  $('pvDownload').hidden = true;
  $('previewDlg').showModal();
}

function renderSetup() {
  if (!status) return;
  const needKey = !status.hasKey;
  const folders = status.mirrorFolders || [];
  const needFolder = !folders.length;
  $('setup').hidden = !(needKey || needFolder);
  const f = folders.map((x) => `<b>${esc(x.name)}</b>${x.perm === 'granted' ? '' : ' <span class="pill warn">needs access</span>'}`);
  if (status.nas?.configured) f.unshift(`NAS: <b>${esc(status.nas.url)}</b>`);
  $('setupFolders').innerHTML = f.join(' · ') || '<span class="muted">No folders chosen yet.</span>';
}

function renderReconnect() {
  if (!status) return;
  const f = status.folders;
  const bridgePrompt = f.bridge && f.bridge.perm === 'prompt';
  const folderPrompt = (status.mirrorFolders || []).some((x) => x.perm === 'prompt');
  $('reconnect').hidden = !(bridgePrompt || folderPrompt);
}

function renderSummary() {
  const s = summarize(items);
  const tiles = [
    ['needs-info', 'Needs info', true], ['needs-approval', 'To approve', true], ['ready', 'Ready', false],
    ['inserted', 'Inserted', false], ['sent', 'Sent', false],
  ].map(([k, label, hot]) => `<button class="stat ${hot && s.by[k] ? 'hot' : ''}" data-filter="${k}"><b>${s.by[k] || 0}</b><span>${label}</span></button>`);
  tiles.push(`<div class="stat cost" title="${fmtN(s.tokensIn)} tokens in, ${fmtN(s.tokensOut)} out (all time)"><b>${money(s.today)}</b><span>today · ${money(s.cost)} total</span></div>`);
  $('summary').innerHTML = tiles.join('');
  const q = items.filter((i) => i.status === 'needs-info' || i.status === 'needs-approval').length;
  $('qCount').textContent = q ? String(q) : '';
}

function filteredItems() {
  const f = $('filter').value;
  if (f === 'all') return items;
  if (f === 'active') return items.filter((i) => ACTIVE.has(i.status));
  return items.filter((i) => i.status === f);
}

function itemVersion(it) {
  return `${it.status}|${it.processedAt}|${(it.draft || '').length}|${(it.dataRequests || []).map((r) => r.state).join(',')}|${JSON.stringify(it.taught || {})}|${expanded.has(it.id)}`;
}

function renderList() {
  const list = $('list');
  const shown = filteredItems();
  if (!shown.length) {
    list.innerHTML = `<div class="empty">${items.length ? 'Nothing in this view.' : 'No drafts yet. Open an email in Outlook and click <b>Draft reply to open email</b>, or wait for new mail.'}</div>`;
    return;
  }
  const focused = document.activeElement?.closest?.('.card')?.dataset.id;
  const existing = new Map([...list.querySelectorAll(':scope > .card')].map((n) => [n.dataset.id, n]));
  const frag = document.createDocumentFragment();
  for (const it of shown) {
    let node = existing.get(it.id);
    const ver = itemVersion(it);
    if (!node || (node.dataset.ver !== ver && it.id !== focused)) node = cardNode(it, ver);
    frag.appendChild(node);
  }
  list.replaceChildren(frag);
}

function reqMark(s) {
  return s === 'answered' ? '✓' : s === 'partial' ? '◐' : '✗';
}

function cardNode(it, ver) {
  const el = document.createElement('article');
  el.className = `card s-${it.status}`;
  el.dataset.id = it.id;
  el.dataset.ver = ver;
  const open = expanded.has(it.id);
  const pill = `<span class="pill ${STATUS_PILL[it.status] || ''}">${esc(STATUS_LABEL[it.status] || it.status)}</span>`;
  const meta = [it.from, it.receivedAt || ago(it.capturedAt), (it.projects || [])[0]].filter(Boolean).map(esc).join(' · ');
  let html = `<div class="card-head" data-act="toggle" aria-expanded="${open}">
    <div class="subj">${esc(it.subject || '(no subject)')}</div>${pill}
    <div class="meta">${meta}</div>
    ${it.summary ? `<div class="sum">${esc(it.summary)}</div>` : ''}
    ${it.status === 'skipped' ? `<div class="sum muted">${esc(it.skipReason || '')}</div>` : ''}
    ${it.status === 'error' ? `<div class="err">${esc(it.error)}</div>` : ''}
  </div>`;
  if (open) html += `<div class="card-body">${cardBody(it)}</div>`;
  el.innerHTML = html;
  return el;
}

function cardBody(it) {
  const parts = [];
  if (it.requests?.length) {
    parts.push('<h3>Requests</h3>');
    for (const r of it.requests) {
      parts.push(`<div class="req"><span class="mark ${esc(r.status)}">${reqMark(r.status)}</span><div><b>${esc(r.ask)}</b>${r.answer ? ` — ${esc(r.answer)}` : ''} ${(r.sources || []).map((s) => `<span class="mono muted">[${esc(s)}]</span>`).join(' ')}</div></div>`);
    }
  }
  if (it.missing?.length) {
    parts.push(`<h3>Missing</h3><ul class="plain missing">${it.missing.map((m) => `<li>${esc(m)}</li>`).join('')}</ul>`);
  }
  const reqs = it.dataRequests || [];
  if (reqs.length) {
    parts.push('<h3>Power Automate</h3>');
    for (const r of reqs) {
      const params = Object.entries(r.params || {});
      if (r.state === 'proposed') {
        parts.push(`<div class="dreq" data-key="${esc(r.key)}"><div><b>${esc(r.action)}</b> <span class="pill ${r.kind === 'write' ? 'warn' : 'info'}">${r.kind}</span></div>
          <div class="muted">${esc(r.reason)}</div>
          ${params.map(([k, v]) => `<label class="field"><span>${esc(k)}</span><input type="text" data-param="${esc(k)}" value="${esc(v)}"></label>`).join('')}
          <div class="row" style="margin-top:6px"><button class="primary" data-act="approve">Run</button><button data-act="reject">Skip</button></div></div>`);
      } else {
        const st = { approved: 'info', running: 'info', waiting: 'info', done: 'ok', failed: 'bad', rejected: '' }[r.state] || '';
        parts.push(`<div class="dreq"><b>${esc(r.action)}</b> <span class="pill ${st}">${esc(r.state)}</span> <span class="mono muted">${esc(params.map(([k, v]) => `${k}=${v}`).join(', '))}</span>${r.resultText ? `<details><summary class="small">Result</summary><pre class="preview">${esc(r.resultText)}</pre></details>` : ''}</div>`);
      }
    }
  }
  if (it.status !== 'skipped' && it.status !== 'no-reply') {
    parts.push(`<h3>Draft</h3><textarea class="draft" data-act="draft" aria-label="Draft reply">${esc(it.draft || '')}</textarea>`);
  }
  if (it.snippets?.length) {
    parts.push('<h3>Sources</h3>');
    const taught = it.taught || {};
    const seen = new Set();
    for (const s of it.snippets) {
      const key = s.path;
      const tag = `[${s.sid}]`;
      const slash = s.path.lastIndexOf('/');
      const fname = s.path.slice(slash + 1);
      const folder = slash > 0 ? s.path.slice(0, slash) : '';
      parts.push(`<div class="src" data-path="${esc(s.path)}" data-page="${s.page || 0}">
        <span class="tag">${tag}</span><span class="path" title="${esc(s.path)}"><b>${esc(fname)}</b>${s.page ? ` · p.${s.page}` : ''}${s.taught ? ' · taught' : ''} <span class="muted">${esc(folder)}</span></span>
        <button data-act="open" title="Open">Open</button>
        ${seen.has(key) ? '' : `<button data-act="good" class="${taught[key] === 'prefer' ? 'on' : ''}" title="Right document — use it for emails like this">👍</button>
        <button data-act="bad" class="${taught[key] === 'avoid' ? 'off' : ''}" title="Wrong document — don't use it for emails like this">👎</button>`}
      </div>`);
      seen.add(key);
    }
  }
  if (it.status !== 'skipped') {
    parts.push(`<div class="row" style="margin-top:6px"><button class="link" data-act="attach">Attach the right document…</button></div>`);
  }
  if (it.status === 'needs-info' || it.missing?.length || it.notes) {
    parts.push(`<h3>Your answers / instructions</h3>
      ${it.notes ? `<div class="small muted" style="white-space:pre-wrap">${esc(it.notes)}</div>` : ''}
      <textarea data-role="notes" rows="3" placeholder="e.g. Pour date is Nov 4. PO 4500123 was approved."></textarea>
      <div class="row" style="margin-top:6px"><button class="primary" data-act="answer">Redraft with this</button></div>`);
  }
  const btns = [];
  if (it.draft) {
    btns.push('<button class="primary" data-act="insert">Insert into Outlook reply</button>');
    btns.push('<button data-act="copy">Copy</button>');
  }
  if (['ready', 'needs-info', 'inserted', 'error', 'needs-approval'].includes(it.status)) btns.push('<button data-act="deeper" title="Redraft with more thinking">Redraft (deeper)</button>');
  if (['skipped', 'error', 'no-reply', 'dismissed'].includes(it.status)) btns.push('<button data-act="reprocess">Draft anyway</button>');
  if (status?.actions?.length) btns.push('<button data-act="runAction">Automate…</button>');
  if (it.status !== 'sent') btns.push('<button data-act="sent">Mark sent</button>');
  if (it.status !== 'dismissed') btns.push('<button data-act="dismiss">Dismiss</button>');
  btns.push('<button class="danger" data-act="delete">Delete</button>');
  parts.push(`<div class="actions">${btns.join('')}</div>`);
  if (it.actionLog?.length) {
    parts.push(`<div class="usage">${it.actionLog.slice(-3).map((a) => `${esc(a.action)}${a.auto ? ' (auto)' : ''}: ${a.ok == null ? 'queued' : a.ok ? 'ok' : 'failed'} ${esc(a.message || '')}`).join('<br>')}</div>`);
  }
  if (it.usage) {
    const u = it.usage;
    parts.push(`<div class="usage">${u.calls} call${u.calls > 1 ? 's' : ''} · ${fmtN(u.input + u.cacheRead + u.cacheWrite)} in${u.cacheRead ? ` (${fmtN(u.cacheRead)} cached)` : ''} / ${fmtN(u.output)} out · ${money(u.cost)} · ${esc(it.model || '')}</div>`);
  }
  return parts.join('');
}

function renderQuestions() {
  const qs = items.filter((i) => (i.status === 'needs-info' || i.status === 'needs-approval') && (i.missing?.length || (i.dataRequests || []).some((r) => r.state === 'proposed')));
  if (!qs.length) { $('questions').innerHTML = '<div class="empty">No open questions.</div>'; return; }
  if (document.activeElement?.closest?.('#questions')) return; // don't wipe a half-typed answer
  $('questions').innerHTML = qs.map((it) => `<div class="q stack" data-id="${esc(it.id)}">
    <div class="row"><b class="grow">${esc(it.subject)}</b><button class="link" data-act="show">Open draft</button></div>
    <div class="small muted">${esc(it.from)}</div>
    ${it.missing?.length ? `<ul class="plain missing small">${it.missing.map((m) => `<li>${esc(m)}</li>`).join('')}</ul>` : ''}
    ${(it.dataRequests || []).some((r) => r.state === 'proposed') ? '<div class="small">A Power Automate request is waiting for your approval in the draft.</div>' : ''}
    <textarea data-role="notes" rows="2" placeholder="Answer here…"></textarea>
    <div class="row"><button class="primary" data-act="answer">Redraft with answer</button></div>
  </div>`).join('');
}

function renderFiles() {
  if (!status) return;
  const st = status.index?.status;
  const job = status.job;
  const busy = !!job;
  $('indexBtn').disabled = busy;
  $('deepBtn').disabled = busy;
  $('stopBtn').hidden = !busy;
  if (st) {
    $('indexPill').className = `pill ${st.errors?.length ? 'warn' : 'ok'}`;
    $('indexPill').textContent = `${fmtN(st.files)} files`;
    const deep = status.deep;
    $('indexInfo').innerHTML = [
      `Last run ${ago(st.at)} on the ${st.root === 'nas' ? 'sync-folder' : 'local'} copy · ${fmtN(status.index.chunks)} passages`,
      `${fmtN(st.indexed)} read · ${fmtN(st.unchanged)} unchanged · ${fmtN(st.nameOnly)} name-only · ${fmtN(st.removed)} removed${st.lowText ? ` · ${st.lowText} look scanned (need OCR)` : ''}`,
      deep ? `Deep index: ${fmtN(deep.applied)} files improved ${ago(deep.at)} (${deep.from})` : 'Deep index: not applied yet',
    ].map((l) => `<div>${esc(l)}</div>`).join('');
    $('indexErrors').textContent = (st.errors || []).join('\n') || 'None';
  } else {
    $('indexPill').className = 'pill warn';
    $('indexPill').textContent = 'not indexed';
    $('indexInfo').textContent = 'Choose a project folder in Settings, then click Index now.';
  }
  showJob(job, ['index', 'deep'], 'jobBar', 'jobText');
}

function showJob(job, names, barId, textId) {
  const bar = $(barId);
  if (!job || !names.includes(job.name)) { bar.hidden = true; return; }
  bar.hidden = false;
  const p = job.progress || {};
  if (p.total) {
    bar.classList.remove('indeterminate');
    bar.firstElementChild.style.width = `${Math.round((100 * p.done) / p.total)}%`;
  } else {
    bar.classList.add('indeterminate');
  }
  $(textId).textContent = progressText(job.name, p);
}

function progressText(name, p) {
  if (!p) return '';
  if (p.phase === 'index') return `Indexing… ${fmtN(p.scanned)} files checked, ${fmtN(p.indexed)} read${p.path ? ` — ${p.path}` : ''}`;
  if (p.phase === 'deep') return p.done ? `Deep index applied: ${fmtN(p.applied)} files improved` : `Applying deep index… ${fmtN(p.applied)} files`;
  if (p.phase?.startsWith('scan-')) return `Scanning ${p.phase === 'scan-nas' ? 'sync' : 'local'} folder… ${fmtN(p.files)} files`;
  if (p.phase === 'sync') return `Syncing… ${p.done}/${p.total}${p.path ? ` — ${p.path}` : ''}`;
  return `${name}…`;
}

function renderMirror() {
  if (!status) return;
  const permPill = (p) => (p === 'granted' ? '<span class="pill ok">connected</span>' : p === 'missing' ? '<span class="pill bad">folder lost</span>' : '<span class="pill warn">needs permission</span>');
  const mode = { 'two-way': 'Two-way (both sides kept identical)', push: 'Local → NAS (backup)', pull: 'NAS → local' }[settings?.mirrorMode] || settings?.mirrorMode;
  const nas = status.nas || {};
  const folders = status.mirrorFolders || [];
  const nasLine = nas.configured
    ? `<div>NAS: <b>${esc(nas.url)}</b> ${nas.status ? (nas.status.ok ? '<span class="pill ok">reachable</span>' : `<span class="pill bad">${esc(nas.status.error || 'unreachable')}</span>`) : '<span class="pill">not tested</span>'} <button class="link" id="testNasBtn">Test</button></div>`
    : '<div class="banner warn small">No NAS connection yet — set the URL and token in Settings → NAS over the internet.</div>';
  const folderLines = folders.length
    ? folders.map((x) => `<div>• <b>${esc(x.name)}</b> → ${esc(x.remotePath || '(root)')} ${permPill(x.perm)}</div>`).join('')
    : '<div class="muted">No folders chosen — add one in Settings.</div>';
  $('mirrorFolders').innerHTML = `${nasLine}${folderLines}
    <div class="muted">Mode: ${esc(mode)}${settings?.autoSyncMinutes ? ` · every ${settings.autoSyncMinutes} min` : ' · manual'} · deleted/overwritten files go to .mailmirror/trash and /conflicts on the side that lost them</div>`;
  $('testNasBtn')?.addEventListener('click', async () => {
    toast('Testing NAS…');
    const r = await engine('nas.test');
    toast(r?.ok ? `NAS reachable — ${r.files} files.` : `NAS: ${r?.error || 'unreachable'}`, 5000);
    refreshSoon();
  });
  const busy = !!status.job;
  const ready = (nas.configured && folders.some((x) => x.perm === 'granted')) || (status.folders.local && status.folders.nas);
  $('planBtn').disabled = busy || !ready;
  $('syncBtn').disabled = busy || !ready;
  showJob(status.job, ['plan', 'sync'], 'mirrorBar', 'mirrorText');
  const m = status.mirror;
  $('mirrorLast').innerHTML = m
    ? `Last sync ${ago(m.at)}: ${m.blocked ? `<span class="err">${esc(m.blocked)}</span>` : `${m.done ?? 0}/${m.total ?? 0} actions, ${(m.bytes / 1e6 || 0).toFixed(1)} MB${m.errors?.length ? ` · ${m.errors.length} errors` : ''}`}
      ${m.errors?.length ? `<details><summary>Errors</summary><div class="mono">${m.errors.map(esc).join('<br>')}</div></details>` : ''}`
    : 'Never synced.';
}

function renderPlan(plan) {
  lastPlan = plan;
  const box = $('planBox');
  box.hidden = false;
  const s = plan.summary;
  const lines = (plan.actions || []).filter((a) => a.op !== 'adopt' && a.op !== 'forget');
  const opText = { 'copy-ln': '→ sync', 'copy-nl': '← sync', 'conflict-ln': '→ sync (conflict, synced copy saved)', 'conflict-nl': '← sync (conflict, local copy saved)', 'trash-l': 'trash local', 'trash-n': 'trash in sync folder' };
  box.innerHTML = `<h2>Sync preview</h2>
    <div class="small">${fmtN(s.localFiles)} local files · ${fmtN(s.nasFiles)} in sync folder · ${s.toNas} to copy out · ${s.toLocal} to copy here · ${s.conflicts} conflicts · ${s.trashLocal + s.trashNas} to trash · ${s.adopt} already matching</div>
    ${plan.blocked ? `<div class="banner warn small">${esc(plan.blocked)}</div>` : ''}
    <div class="plan-list">${lines.slice(0, 300).map((a) => `<div>${esc(opText[a.op] || a.op)} — ${esc(a.path)} <span class="muted">(${esc(a.reason)})</span></div>`).join('') || '<div class="muted">Nothing to copy.</div>'}${lines.length > 300 ? `<div class="muted">…and ${lines.length - 300} more</div>` : ''}</div>
    <div class="row">${plan.blocked && !plan.blocked.includes('looks empty') ? '<button class="danger" id="allowSync">Allow and sync</button>' : '<button class="primary" id="runPlan">Run this sync</button>'}</div>`;
  $('runPlan')?.addEventListener('click', () => startSync(false));
  $('allowSync')?.addEventListener('click', () => {
    if (confirm('Move the listed files to the .mailmirror/trash folder and continue?')) startSync(true);
  });
}

async function renderAutomate() {
  if (!status) return;
  const acts = settings?.actions || [];
  const bridge = status.folders.bridge;
  const html = [];
  html.push(`<div class="panel stack"><div class="row"><h2 class="grow">Power Automate actions</h2><button id="editActions">Edit…</button></div>`);
  if (!acts.length) {
    html.push('<p class="small muted">No flows connected yet. In Settings → Power Automate, add a flow (HTTP trigger URL, or the OneDrive bridge folder) for each job: SAP lookups, the SharePoint Excel tracker, GCdocs filing.</p>');
  } else {
    for (const a of acts) {
      html.push(`<div class="dreq"><div class="row"><b class="grow">${esc(a.name)}</b><span class="pill ${a.kind === 'write' ? 'warn' : 'info'}">${esc(a.kind || 'read')}</span><span class="pill">${esc(a.transport === 'folder' ? 'bridge folder' : 'HTTP')}</span>${a.enabled === false ? '<span class="pill">off</span>' : ''}</div>
        <div class="small muted">${esc(a.description || '')}</div>
        ${a.enabled === false ? '' : `<div class="row" style="margin-top:4px"><button data-run="${esc(a.name)}">Run…</button>${a.autoRun ? '<span class="small muted">runs automatically when a draft needs it</span>' : ''}${a.auto ? '<span class="small muted">runs after every draft</span>' : ''}</div>`}</div>`);
    }
  }
  html.push(`<div class="small muted">Bridge folder: ${bridge ? `<b>${esc(bridge.name)}</b> ${bridge.perm === 'granted' ? '' : '(needs permission)'}` : 'not set'} · ${status.pendingActions} request(s) waiting for a flow</div></div>`);
  $('actionsBox').innerHTML = html.join('');
  $('editActions').addEventListener('click', () => openSettings('automate'));
  $('actionsBox').querySelectorAll('[data-run]').forEach((b) => b.addEventListener('click', () => openActionDialog(null, b.dataset.run)));
  const log = ((await kvGet('log')) || []).slice(-30).reverse();
  $('activity').innerHTML = log.length
    ? log.map((l) => `<div><span class="muted">${new Date(l.at).toLocaleTimeString()}</span> <span class="pill">${esc(l.kind)}</span> ${esc(l.message)}</div>`).join('')
    : '<span class="muted">Nothing yet.</span>';
}

// ---------------------------------------------------------------- actions

function openSettings(section) {
  const url = chrome.runtime.getURL(`options.html${section ? `#${section}` : ''}`);
  chrome.tabs.create({ url });
}

const VIEWABLE = new Set(['pdf', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'txt', 'html', 'htm', 'svg', 'mp4']);

// Opens the local copy of a file from its designated folder (rec.folderId +
// rec.rel). The NAS is never read for viewing — the work computer has the file.
async function openLocalFile(rec, path) {
  const folderId = rec?.folderId || 'local';
  const rel = rec?.rel || path;
  try {
    const h = await getRootHandle(folderId === 'local' ? 'local' : 'folder:' + folderId);
    if (h && (await permissionState(h)) === 'granted') return await (await getFileByPath(h, rel)).getFile();
  } catch { /* not reachable */ }
  return null;
}

async function openSource(path, page) {
  const ext = (path.split('.').pop() || '').toLowerCase();
  const rec0 = await get('files', path);
  let file = await openLocalFile(rec0, path);
  if (file && VIEWABLE.has(ext)) {
    const url = URL.createObjectURL(file) + (ext === 'pdf' && page ? `#page=${page}` : '');
    try { await chrome.tabs.create({ url }); } catch { window.open(url, '_blank'); }
    return;
  }
  // Office files etc.: show the indexed text; offer the original as a download.
  const rec = rec0;
  const chunks = await Promise.all((rec?.chunkIds || []).slice(0, 60).map((id) => get('chunks', id)));
  $('pvTitle').textContent = path;
  $('pvText').textContent = chunks.filter(Boolean).map((c) => (c.page ? `— page ${c.page} —\n` : '') + c.text).join('\n\n') || '(no text indexed for this file)';
  $('pvDownload').hidden = !file;
  $('pvDownload').onclick = () => {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(file);
    a.download = path.split('/').pop();
    a.click();
  };
  $('previewDlg').showModal();
}

async function insertDraft(it) {
  const res = await bg('outlook.insert', { text: it.draft, convId: it.convId, itemId: it.id });
  if (res?.ok) {
    await updateItem(it.id, { status: 'inserted' });
    toast('Draft inserted into the Outlook reply. Review it there and press Send yourself.');
    engine('badge');
  } else {
    try { await navigator.clipboard.writeText(it.draft); } catch { /* clipboard blocked */ }
    toast(`${res?.error || 'Could not reach Outlook.'} The draft is on your clipboard.`, 6000);
  }
  refreshSoon();
}

async function onListClick(e) {
  const btn = e.target.closest('[data-act]');
  const card = e.target.closest('.card');
  if (!btn || !card) return;
  const id = card.dataset.id;
  const it = items.find((x) => x.id === id);
  if (!it) return;
  const act = btn.dataset.act;
  if (act === 'toggle') {
    if (expanded.has(id)) expanded.delete(id); else expanded.add(id);
    saveExpanded();
    renderList();
    return;
  }
  if (act === 'draft') return;
  switch (act) {
    case 'insert': await insertDraft(it); break;
    case 'copy':
      await navigator.clipboard.writeText(it.draft || '');
      toast('Draft copied.');
      break;
    case 'deeper':
      toast('Redrafting with more effort…');
      engine('item.regenerate', { id, effort: 'high' }).then(afterEngine);
      break;
    case 'answer': {
      const notes = card.querySelector('[data-role="notes"]').value.trim();
      if (!notes) { toast('Type the missing information first.'); return; }
      toast('Redrafting with your answer…');
      engine('item.regenerate', { id, notes }).then(afterEngine);
      break;
    }
    case 'reprocess':
      engine('item.reprocess', { id }).then(afterEngine);
      toast('Drafting…');
      break;
    case 'sent':
      await updateItem(id, { status: 'sent' });
      engine('badge');
      break;
    case 'dismiss':
      await updateItem(id, { status: 'dismissed' });
      engine('badge');
      break;
    case 'delete':
      if (!confirm('Delete this draft from MailMirror? (Nothing in Outlook is touched.)')) return;
      await deleteItem(id);
      engine('badge');
      break;
    case 'open': {
      const src = btn.closest('.src');
      await openSource(src.dataset.path, Number(src.dataset.page) || 0);
      return;
    }
    case 'good':
    case 'bad': {
      const src = btn.closest('.src');
      await engine('item.teach', { id, path: src.dataset.path, kind: act === 'good' ? 'prefer' : 'avoid' });
      toast(act === 'good' ? 'Learned: this document is right for emails like this.' : 'Learned: skip this document for emails like this.');
      break;
    }
    case 'attach': openAttach(id); return;
    case 'runAction': openActionDialog(it); return;
    case 'approve':
    case 'reject': {
      const box = btn.closest('.dreq');
      const params = {};
      box.querySelectorAll('[data-param]').forEach((inp) => { params[inp.dataset.param] = inp.value; });
      if (act === 'approve') {
        const r = (it.dataRequests || []).find((x) => x.key === box.dataset.key);
        if (r?.kind === 'write' && !confirm(`Run "${r.action}"? It will change records.\n\n${Object.entries(params).map(([k, v]) => `${k}: ${v}`).join('\n')}`)) return;
        toast('Running flow…');
      }
      engine('item.decide', { id, key: box.dataset.key, approve: act === 'approve', params }).then(afterEngine);
      break;
    }
    default: break;
  }
  refreshSoon();
}

function afterEngine(res) {
  if (res?.error) toast(res.error, 6000);
  refreshSoon();
}

let draftSaveTimer = null;
function onListInput(e) {
  if (e.target.dataset.act !== 'draft') return;
  const id = e.target.closest('.card').dataset.id;
  const value = e.target.value;
  clearTimeout(draftSaveTimer);
  draftSaveTimer = setTimeout(async () => {
    await updateItem(id, { draft: value });
    const it = items.find((x) => x.id === id);
    if (it) { it.draft = value; it.draftEdited = true; }
  }, 500);
}

// ---- attach / teach ----

let attachFor = null;
function openAttach(id) {
  attachFor = id;
  $('attSearch').value = '';
  $('attResults').innerHTML = '';
  $('attachDlg').showModal();
  $('attSearch').focus();
}

let attTimer = null;
$('attSearch').addEventListener('input', () => {
  clearTimeout(attTimer);
  attTimer = setTimeout(async () => {
    const q = $('attSearch').value.trim();
    if (q.length < 2) { $('attResults').innerHTML = ''; return; }
    const res = await engine('search', { q, k: 15 });
    const seen = new Set();
    const hits = (res?.hits || []).filter((h) => !seen.has(h.path) && seen.add(h.path));
    $('attResults').innerHTML = hits.map((h) => `<div class="hit"><div class="row"><span class="path grow">${esc(h.path)}</span><button data-path="${esc(h.path)}" class="primary">Use this</button></div><div class="text">${esc(h.text)}</div></div>`).join('') || '<div class="muted small">No matches.</div>';
  }, 250);
});

$('attResults').addEventListener('click', async (e) => {
  const b = e.target.closest('button[data-path]');
  if (!b || !attachFor) return;
  await engine('item.teach', { id: attachFor, path: b.dataset.path, kind: 'prefer' });
  $('attachDlg').close();
  toast('Attached and learned. Click "Redraft" to use it.');
  expanded.add(attachFor);
  saveExpanded();
  refreshSoon();
});

// ---- Automate dialog ----

let actionItem = null;
function openActionDialog(it, name) {
  const acts = (settings.actions || []).filter((a) => a.enabled !== false);
  if (!acts.length) { openSettings('automate'); return; }
  actionItem = it;
  $('aName').innerHTML = acts.map((a) => `<option ${a.name === name ? 'selected' : ''}>${esc(a.name)}</option>`).join('');
  $('aTitle').textContent = it ? `Run a flow for "${it.subject}"` : 'Run a Power Automate flow';
  fillActionParams();
  $('actionDlg').showModal();
}

function fillActionParams() {
  const a = (settings.actions || []).find((x) => x.name === $('aName').value);
  if (!a) return;
  $('aDesc').textContent = a.description || '';
  $('aWarn').hidden = a.kind !== 'write';
  const defaults = actionItem ? defaultParams(a, actionItem) : {};
  $('aParams').innerHTML = paramSpec(a).map((p) => `<label class="field"><span>${esc(p.name)}${p.hint ? ` — ${esc(p.hint)}` : ''}</span><input type="text" data-param="${esc(p.name)}" value="${esc(defaults[p.name] || '')}"></label>`).join('') || '<p class="small muted">This flow takes no parameters.</p>';
}
$('aName').addEventListener('change', fillActionParams);

$('aGo').addEventListener('click', async (e) => {
  e.preventDefault();
  const name = $('aName').value;
  const params = {};
  $('aParams').querySelectorAll('[data-param]').forEach((i) => { params[i.dataset.param] = i.value; });
  $('actionDlg').close();
  if (actionItem) {
    toast('Running flow…');
    const res = await engine('item.action', { id: actionItem.id, action: name, params });
    afterEngine(res);
  } else {
    // Not tied to an email: run it through a throwaway item-less request.
    const res = await engine('item.action', { id: await adhocItem(), action: name, params });
    afterEngine(res);
    $('filter').value = 'all';
  }
});

// A flow run that isn't about an email gets its own log entry in the list.
async function adhocItem() {
  const id = `run-${Date.now().toString(36)}`;
  await put('items', {
    id, source: 'manual', adhoc: true, from: 'You', subject: `Flow run ${new Date().toLocaleString()}`,
    capturedAt: Date.now(), processedAt: Date.now(), status: 'no-reply', bodyClean: '', history: [],
  });
  return id;
}

// ---- export ----

function csvCell(v) {
  const s = String(v ?? '');
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

$('exportBtn').addEventListener('click', () => {
  const head = ['captured', 'from', 'subject', 'project', 'status', 'summary', 'missing', 'tokens_in', 'tokens_out', 'cost_usd', 'model'];
  const rows = items.map((i) => [
    new Date(i.capturedAt || 0).toISOString(), i.from, i.subject, (i.projects || [])[0] || '', i.status, i.summary,
    (i.missing || []).join('; '), i.usage ? i.usage.input + i.usage.cacheRead + i.usage.cacheWrite : 0, i.usage?.output || 0, i.usage?.cost ?? '', i.model || '',
  ]);
  const csv = [head, ...rows].map((r) => r.map(csvCell).join(',')).join('\n');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
  a.download = `mailmirror-drafts-${new Date().toISOString().slice(0, 10)}.csv`;
  a.click();
});

// ---- setup ----

function setupProvider() {
  return document.querySelector('input[name="setupProvider"]:checked').value;
}

function updateSetupLabels() {
  const g = setupProvider() === 'gemini';
  $('setupKeyLabel').textContent = g ? 'Gemini API key' : 'Anthropic API key';
  $('setupKey').placeholder = g ? 'AIza…' : 'sk-ant-…';
  $('setupHelp').textContent = g ? 'Get a key at aistudio.google.com → Get API key.' : 'Get a key at console.anthropic.com → API keys.';
}
document.querySelectorAll('input[name="setupProvider"]').forEach((r) => r.addEventListener('change', updateSetupLabels));

$('setupSave').addEventListener('click', async () => {
  const provider = setupProvider();
  const key = $('setupKey').value.trim();
  if (!key) { $('setupMsg').textContent = 'Paste a key first.'; return; }
  await saveSettings(provider === 'gemini' ? { provider, geminiKey: key } : { provider, anthropicKey: key });
  $('setupMsg').textContent = 'Testing…';
  const res = await engine('llm.models', { provider });
  if (res?.error) {
    $('setupMsg').innerHTML = `<span class="err">${esc(res.error)}</span>`;
  } else {
    const s = await getSettings();
    const models = res.models || [];
    const cur = provider === 'gemini' ? s.geminiModel : s.anthropicModel;
    if (models.length && !models.includes(cur)) {
      const pick = provider === 'gemini'
        ? models.find((m) => /flash/.test(m) && !/lite|image|tts|live/.test(m)) || models[0]
        : models.find((m) => m === 'claude-opus-5-5') || models.find((m) => /opus/.test(m)) || models[0];
      await saveSettings(provider === 'gemini' ? { geminiModel: pick } : { anthropicModel: pick });
    }
    $('setupMsg').textContent = `Key works (${models.length} models available).`;
    $('setupKey').value = '';
    toast('API key saved.');
  }
  refresh();
});

function slug(name) {
  return String(name || '').trim().replace(/[\\/:*?"<>|]+/g, ' ').replace(/\s+/g, ' ').trim() || 'folder';
}

async function addMirrorFolder() {
  try {
    const handle = await window.showDirectoryPicker({ id: 'mm-project', mode: 'readwrite' });
    const id = `f${Date.now().toString(36)}${Math.random().toString(36).slice(2, 5)}`;
    await setRootHandle('folder:' + id, handle);
    const s = await getSettings();
    await saveSettings({ mirrorFolders: [...(s.mirrorFolders || []), { id, name: handle.name, remotePath: slug(handle.name) }] });
    toast(`Added ${handle.name}. Indexing…`);
    engine('index.run');
    refresh();
  } catch (err) {
    if (err.name === 'AbortError') return;
    toast(`Folder picker unavailable here — opening Settings. (${err.message})`, 5000);
    openSettings('folders');
  }
}
$('setupLocal').addEventListener('click', addMirrorFolder);
$('setupNas').addEventListener('click', () => openSettings('folders'));

$('reconnectBtn').addEventListener('click', async () => {
  const keys = ['bridge', ...(status?.mirrorFolders || []).map((x) => (x.id === 'local' ? 'local' : 'folder:' + x.id))];
  for (const k of keys) {
    const h = await getRootHandle(k);
    if (h && (await permissionState(h)) === 'prompt') {
      try { await requestPermission(h); } catch (err) { toast(err.message); }
    }
  }
  refresh();
});

// ---- toolbar ----

$('openSettings').addEventListener('click', () => chrome.runtime.openOptionsPage());

$('draftOpen').addEventListener('click', async () => {
  const res = await bg('outlook.getOpen');
  if (!res?.email) { toast(res?.error || 'Open an email in Outlook first.', 5000); return; }
  const id = emailId(res.email);
  const existing = items.find((i) => i.id === id);
  expanded.add(id);
  saveExpanded();
  if (existing && existing.status !== 'error') {
    toast('Already drafted — showing it. Use "Redraft" to refresh.');
    $('filter').value = 'all';
  } else {
    await engine('email.capture', { email: res.email, force: !!existing });
    toast('Drafting…');
  }
  refreshSoon(400);
});

$('scanNow').addEventListener('click', async () => {
  toast('Scanning Outlook…');
  const res = await bg('outlook.scanNow');
  toast(res?.error || `Queued ${res?.processed || 0} message(s).`);
  refreshSoon(500);
});

$('pasteBtn').addEventListener('click', () => $('pasteDlg').showModal());
$('pGo').addEventListener('click', async (e) => {
  e.preventDefault();
  const email = { from: $('pFrom').value.trim(), subject: $('pSubject').value.trim(), body: $('pBody').value, source: 'manual', receivedAt: new Date().toLocaleString() };
  if (!email.body.trim()) { toast('Paste the email body.'); return; }
  $('pasteDlg').close();
  const id = emailId(email);
  expanded.add(id);
  saveExpanded();
  await engine('email.capture', { email, force: true });
  toast('Drafting…');
  ['pFrom', 'pSubject', 'pBody'].forEach((k) => { $(k).value = ''; });
  refreshSoon(400);
});

$('filter').addEventListener('change', () => {
  sessionStorage.setItem('mm_filter', $('filter').value);
  renderList();
});
$('summary').addEventListener('click', (e) => {
  const b = e.target.closest('[data-filter]');
  if (!b) return;
  $('filter').value = b.dataset.filter;
  selectTab('drafts');
  renderList();
});
$('list').addEventListener('click', onListClick);
$('list').addEventListener('input', onListInput);

$('questions').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-act]');
  const q = e.target.closest('.q');
  if (!b || !q) return;
  const id = q.dataset.id;
  if (b.dataset.act === 'show') {
    expanded.add(id);
    saveExpanded();
    $('filter').value = 'all';
    selectTab('drafts');
    renderList();
    document.querySelector(`.card[data-id="${CSS.escape(id)}"]`)?.scrollIntoView({ behavior: 'smooth' });
    return;
  }
  const notes = q.querySelector('[data-role="notes"]').value.trim();
  if (!notes) { toast('Type the answer first.'); return; }
  document.activeElement.blur();
  toast('Redrafting with your answer…');
  afterEngine(await engine('item.regenerate', { id, notes }));
});

// ---- files tab ----

let searchTimer = null;
$('searchBox').addEventListener('input', () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(async () => {
    const q = $('searchBox').value.trim();
    if (q.length < 2) { $('searchResults').innerHTML = ''; return; }
    const res = await engine('search', { q, k: 12 });
    if (res?.error) { $('searchResults').innerHTML = `<div class="err">${esc(res.error)}</div>`; return; }
    $('searchResults').innerHTML = (res.hits || []).map((h) => `<div class="hit"><div class="path" data-path="${esc(h.path)}" data-page="${h.page || 0}">${esc(h.path)}${h.page ? ` · p.${h.page}` : ''}</div><div class="text">${esc(h.text)}</div></div>`).join('') || '<div class="muted small">No matches.</div>';
  }, 250);
});
$('searchResults').addEventListener('click', (e) => {
  const p = e.target.closest('.path');
  if (p) openSource(p.dataset.path, Number(p.dataset.page) || 0);
});
$('indexBtn').addEventListener('click', async () => afterEngine(await engine('index.run')));
$('deepBtn').addEventListener('click', async () => afterEngine(await engine('deep.apply', { force: true })));
$('stopBtn').addEventListener('click', () => engine('job.stop'));

// ---- mirror tab ----

$('planBtn').addEventListener('click', async () => {
  $('planBox').hidden = true;
  afterEngine(await engine('mirror.plan'));
});
async function startSync(allowLargeDelete) {
  $('planBox').hidden = true;
  afterEngine(await engine('mirror.run', { usePlan: !!lastPlan, allowLargeDelete }));
}
$('syncBtn').addEventListener('click', () => startSync(false));

// ---- tabs ----

function selectTab(name) {
  document.querySelectorAll('.tabs [role="tab"]').forEach((t) => t.setAttribute('aria-selected', String(t.dataset.tab === name)));
  document.querySelectorAll('.tab').forEach((s) => { s.hidden = s.id !== `tab-${name}`; });
  sessionStorage.setItem('mm_tab', name);
}
document.querySelector('.tabs').addEventListener('click', (e) => {
  const t = e.target.closest('[role="tab"]');
  if (t) selectTab(t.dataset.tab);
});

// ---- live updates ----

chrome.runtime.onMessage.addListener((msg) => {
  if (!msg || msg.to !== 'ui') return false;
  if (msg.type === 'progress' && status) {
    status.job = { name: msg.job, progress: msg.progress, started: status.job?.started || Date.now() };
    renderFiles();
    renderMirror();
    return false;
  }
  if (msg.type === 'jobDone') {
    if (msg.error) toast(`${msg.job}: ${msg.error}`, 6000);
    else if (msg.job === 'plan') renderPlan(msg.result);
    else if (msg.job === 'sync') toast(msg.result?.blocked || `Sync finished: ${msg.result?.done ?? 0} actions.`, 5000);
    else if (msg.job === 'index') toast(`Index updated: ${msg.result?.indexed ?? 0} files read.`);
    else if (msg.job === 'deep') toast(msg.result?.found === false ? 'No deep index file in the sync folder yet (the NAS writes it there).' : `Deep index: ${msg.result?.applied ?? 0} files improved.`);
  }
  refreshSoon();
  return false;
});

document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
setInterval(() => { if (!document.hidden) refresh(); }, 8000);

selectTab(sessionStorage.getItem('mm_tab') || 'drafts');
$('filter').value = sessionStorage.getItem('mm_filter') || 'active';
updateSetupLabels();
refresh();
