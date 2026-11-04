// The browser agent window: a task box, the tab to work in, a live log of every step, Allow / Don't for
// risky steps, questions from the agent, and the user's Power Automate desktop flows.

import { getSettings, saveSettings } from './lib/db.js';
import { Agent, desktopFlowUrl } from './lib/agent.js';
import { stopAllAI, resumeAI, LLMError } from './lib/llm.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pad = (n) => String(n).padStart(2, '0');
const hms = (d) => `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
const money = (c) => (c < 0.01 ? `$${c.toFixed(4)}` : `$${c.toFixed(2)}`);
const AI_NAME = { gemini: 'Gemini', anthropic: 'Claude' };

const state = {
  agent: null,
  settings: null,
  aiPaused: false,
  confirmResolve: null,
  askResolve: null,
  entries: [],
};
window.agentWindow = state; // for the automated tests

let toastTimer = null;
function toast(msg, ms = 4000) {
  const t = $('toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    t.hidden = true;
  }, ms);
}

function setStatus(text) {
  $('status').textContent = text;
}

// ---------------------------------------------------------------- tabs

async function loadTabs(preferId) {
  const sel = $('tab');
  const keep = preferId ?? Number(sel.value || 0);
  const tabs = (await chrome.tabs.query({})).filter((t) => /^https?:|^file:/.test(t.url || ''));
  // The tab the user was looking at before opening this window comes first.
  const last = tabs.filter((t) => t.active).sort((a, b) => (b.lastAccessed || 0) - (a.lastAccessed || 0))[0];
  sel.innerHTML = tabs.map((t) => `<option value="${t.id}">${esc((t.title || t.url).slice(0, 70))} — ${esc(new URL(t.url).hostname)}</option>`).join('') + '<option value="0">No tab yet (the agent opens what it needs)</option>';
  sel.value = String(tabs.some((t) => t.id === keep) ? keep : last?.id || 0);
}

// ---------------------------------------------------------------- the log

function checkHtml(c) {
  if (!c) return '';
  if (c.error) return `<div class="chk warn">Not double-checked: ${esc(c.error)}</div>`;
  const local = [];
  if (c.failed?.length) local.push(...c.failed.map((f) => `Step failed or didn't check out: ${f}`));
  if (c.declined) local.push(`${c.declined} step${c.declined === 1 ? '' : 's'} you said no to`);
  if (c.localOnly) {
    return local.length ? `<div class="chk warn" data-check="issues">⚠ Check:<ul>${local.map((l) => `<li>${esc(l)}</li>`).join('')}</ul></div>` : '<div class="chk ok" data-check="ok">✓ Every step went through and every typed value read back correctly.</div>';
  }
  const by = AI_NAME[c.by] || 'The second AI';
  const findings = [...(c.issues || []).map((i) => `<li><b>“${esc(i.claim)}”</b> — ${esc(i.problem)}${i.evidence ? ` <span class="muted">${esc(i.evidence)}</span>` : ''}</li>`), ...(c.missed || []).map((m) => `<li>Not done: ${esc(m)}</li>`), ...local.map((l) => `<li>${esc(l)}</li>`)];
  if (c.verdict === 'ok' && !findings.length) return `<div class="chk ok" data-check="ok">✓ ${by} checked the result against the task and the final page: no problems found.</div>`;
  return `<div class="chk warn" data-check="issues">⚠ ${by} checked the result:<ul>${findings.join('')}</ul></div>`;
}

function entryHtml(e) {
  const ts = `<span class="ts">${hms(new Date(e.at))}</span>`;
  if (e.type === 'check') return `<div class="e">${checkHtml(e.check)}</div>`;
  if (e.type === 'act') {
    const r = e.result || {};
    const flag = r.error ? ` <span class="bad">✗ ${esc(r.error)}</span>` : r.declined ? ' <span class="bad">— you said no</span>' : r.mismatch ? ` <span class="bad">⚠ ${esc(typeof r.mismatch === 'string' ? r.mismatch : 'mismatch')}</span>` : '';
    const detail = e.tool === 'read_page' && r.url ? `${r.title || ''} · ${r.url} · ${r.elements?.length || 0} elements` : JSON.stringify(r).slice(0, 600);
    return `<div class="e act">${ts}${esc(e.text)}${flag}<details><summary class="muted">details</summary><pre>${esc(detail)}</pre></details></div>`;
  }
  const cls = { think: 'think', info: 'info', error: 'err', result: 'result' }[e.type] || '';
  return `<div class="e ${cls}">${ts}${esc(e.text)}</div>`;
}

function renderLog() {
  const box = $('log');
  if (!state.entries.length) {
    box.innerHTML = '<div class="empty small">Nothing yet.</div>';
    return;
  }
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
  box.innerHTML = state.entries.slice(-300).map(entryHtml).join('');
  if (atBottom) box.scrollTop = box.scrollHeight;
  $('steps').textContent = state.agent ? `${state.agent.steps} step${state.agent.steps === 1 ? '' : 's'}` : '';
}

function addEntry(e) {
  state.entries.push({ at: Date.now(), ...e });
  renderLog();
  if (state.agent) $('cost').textContent = state.agent.cost ? `AI ${money(state.agent.cost)}` : '';
}

// ---------------------------------------------------------------- asking the user

function confirmStep(req) {
  return new Promise((resolve) => {
    state.confirmResolve = (answer) => {
      state.confirmResolve = null;
      $('confirmBox').hidden = true;
      resolve(answer);
    };
    state.pendingConfirm = req;
    $('confirmTitle').textContent = req.title;
    $('confirmDetail').textContent = req.detail || '';
    $('confirmDetail').hidden = !req.detail;
    const c = req.check;
    $('confirmCheck').innerHTML = !c ? '' : c.error ? `<div class="chk warn">The second check failed: ${esc(c.error)}</div>`
      : c.verdict === 'ok' ? `<div class="chk ok" data-check="ok">✓ ${AI_NAME[c.by]} checked the page against your task: looks right.</div>`
        : `<div class="chk warn" data-check="issues">⚠ ${AI_NAME[c.by]} checked the page against your task:<ul>${[...(c.issues || []).map((i) => `<li><b>“${esc(i.claim)}”</b> — ${esc(i.problem)}${i.fix && i.fix !== 'remove' ? ` → ${esc(i.fix)}` : ''}</li>`), ...(c.missed || []).map((m) => `<li>Missing: ${esc(m)}</li>`)].join('')}</ul></div>`;
    $('btnAlways').hidden = !!req.launchUrl || req.kind === 'overwrite';
    $('confirmBox').hidden = false;
    $('confirmBox').scrollIntoView({ block: 'nearest' });
    $('btnAllow').focus();
  });
}

function launchExternal(url) {
  // Inside the click on Allow (a user gesture), so Chrome may hand the ms-powerautomate: link to Windows.
  const a = document.createElement('a');
  a.href = url;
  a.rel = 'noopener';
  document.body.appendChild(a);
  a.click();
  a.remove();
  state.launched = (state.launched || []).concat(url); // for the tests
}

$('btnAllow').addEventListener('click', () => {
  if (state.pendingConfirm?.launchUrl) launchExternal(state.pendingConfirm.launchUrl);
  state.confirmResolve?.('allow');
});
$('btnAlways').addEventListener('click', () => state.confirmResolve?.('always'));
$('btnDeny').addEventListener('click', () => state.confirmResolve?.('deny'));

function askUser(question) {
  return new Promise((resolve) => {
    state.askResolve = (answer) => {
      state.askResolve = null;
      $('askBox').hidden = true;
      resolve(answer);
    };
    $('askQuestion').textContent = question;
    $('askInput').value = '';
    $('askBox').hidden = false;
    $('askInput').focus();
  });
}

$('askForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const v = $('askInput').value.trim();
  if (!v) return;
  addEntry({ type: 'info', text: `You answered: ${v}` });
  state.askResolve?.(v);
});

// ---------------------------------------------------------------- start / stop

async function start() {
  const task = $('task').value.trim();
  if (!task) {
    toast('Write what the agent should do.');
    return;
  }
  if (state.agent) return;
  if (state.aiPaused) {
    toast('AI is stopped. Click ▶ Resume AI first.');
    return;
  }
  await saveSettings({ agentConfirm: $('confirm').value, agentProvider: $('provider').value, agentMaxSteps: Number($('maxSteps').value) || 40 });
  state.settings = await getSettings();
  state.entries = [];
  const tabId = Number($('tab').value) || null;
  const agent = new Agent({
    task,
    tabId,
    settings: state.settings,
    ui: {
      confirm: confirmStep,
      ask: askUser,
      log: (e) => addEntry(e),
    },
  });
  state.agent = agent;
  $('btnStart').disabled = true;
  $('btnStop').disabled = false;
  setStatus('Working… (Chrome shows a “debugging this browser” bar while the agent controls a tab)');
  try {
    const r = await agent.run();
    setStatus(`Done in ${r.steps} step${r.steps === 1 ? '' : 's'}${r.cost ? ` · ${money(r.cost)}` : ''}.`);
    state.result = r;
  } catch (err) {
    const stopped = err instanceof LLMError && (err.kind === 'stopped' || err.kind === 'paused');
    addEntry({ type: stopped ? 'info' : 'error', text: stopped ? 'Stopped.' : err.message || String(err) });
    setStatus(stopped ? 'Stopped.' : `Stopped with an error: ${err.message}`);
    state.result = { error: err.message, kind: err.kind };
  } finally {
    state.confirmResolve?.('deny');
    state.askResolve?.('');
    state.agent = null;
    $('btnStart').disabled = false;
    $('btnStop').disabled = true;
    renderLog();
    if (agent.cost) $('cost').textContent = `AI ${money(agent.cost)}`;
  }
}

function stop() {
  state.agent?.stop();
  state.confirmResolve?.('deny');
  state.askResolve?.('');
}

$('btnStart').addEventListener('click', start);
$('btnStop').addEventListener('click', stop);
$('btnRefreshTabs').addEventListener('click', () => loadTabs());

// ---------------------------------------------------------------- the kill switch

function renderAi() {
  const b = $('btnAi');
  b.textContent = state.aiPaused ? '▶ Resume AI' : '⏹ Stop AI';
  b.className = state.aiPaused ? 'primary' : 'danger';
}
$('btnAi').addEventListener('click', async () => {
  if (state.aiPaused) {
    await resumeAI();
    state.aiPaused = false;
    toast('AI resumed.');
  } else {
    stop();
    await stopAllAI();
    state.aiPaused = true;
    toast('AI stopped everywhere.');
  }
  renderAi();
});
chrome.runtime.onMessage.addListener((m) => {
  if (m?.type === 'ai.stopAll' || m?.type === 'ai.resumed') {
    state.aiPaused = m.type === 'ai.stopAll';
    if (state.aiPaused) stop();
    renderAi();
  }
  return false;
});

// ---------------------------------------------------------------- desktop flows

function renderFlows() {
  const list = state.settings.desktopFlows || [];
  $('flows').innerHTML = list.length
    ? list.map((f, i) => `<div class="flow" data-i="${i}"><span class="grow"><b>${esc(f.name)}</b>${f.inputs ? ` <span class="muted">(${esc(f.inputs)})</span>` : ''}${f.description ? ` — ${esc(f.description)}` : ''}</span><button data-act="remove" class="link">Remove</button></div>`).join('')
    : '<div class="muted">No desktop flows yet.</div>';
}

$('flows').addEventListener('click', async (e) => {
  const b = e.target.closest('[data-act="remove"]');
  if (!b) return;
  const i = Number(b.closest('[data-i]').dataset.i);
  const list = [...(state.settings.desktopFlows || [])];
  list.splice(i, 1);
  state.settings = await saveSettings({ desktopFlows: list });
  renderFlows();
});

$('flowForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const flow = { name: $('flowName').value.trim(), runUrl: $('flowUrl').value.trim(), inputs: $('flowInputs').value.trim(), description: $('flowDesc').value.trim() };
  if (!flow.name) {
    $('flowMsg').textContent = 'Give it a name.';
    return;
  }
  try {
    desktopFlowUrl(flow); // checks the link
  } catch (err) {
    $('flowMsg').textContent = err.message;
    return;
  }
  const list = (state.settings.desktopFlows || []).filter((f) => f.name.toLowerCase() !== flow.name.toLowerCase());
  state.settings = await saveSettings({ desktopFlows: [...list, flow] });
  for (const id of ['flowName', 'flowUrl', 'flowInputs', 'flowDesc']) $(id).value = '';
  $('flowMsg').textContent = 'Added.';
  renderFlows();
});

// ---------------------------------------------------------------- init

window.addEventListener('pagehide', () => {
  const agent = state.agent;
  stop();
  agent?.releaseAll();
});
state.settings = await getSettings();
state.aiPaused = !!state.settings.aiPaused;
$('confirm').value = state.settings.agentConfirm || 'risky';
$('provider').value = state.settings.agentProvider || '';
$('maxSteps').value = state.settings.agentMaxSteps || 40;
const fromHash = Number(new URLSearchParams(location.hash.slice(1)).get('tab')) || undefined;
await loadTabs(fromHash);
renderAi();
renderFlows();
state.ready = true;
