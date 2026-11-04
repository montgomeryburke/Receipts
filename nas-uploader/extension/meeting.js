// Meeting window: listens to the Teams meeting (desktop app via system audio, or a Chrome tab) and the user's
// microphone, shows both sound levels, transcribes (free on this computer, or Gemini), flashes prompts of what
// to say with quotes from the project files, answers private typed questions, and saves the transcript to
// the NAS (every minute, and at the end with a summary).

import { getSettings, saveSettings, put, kvGet } from './lib/db.js';
import { createAudioContext, captureTeamsApp, captureTeamsTab, captureMicrophone, AudioChannel } from './lib/audio.js';
import { Transcriber } from './lib/stt.js';
import { makePrompt, answerQuestion, summarize, shouldPrompt, checkResult } from './lib/meeting-ai.js';
import { detectProjects } from './lib/assistant.js';
import { addHint } from './lib/teach.js';
import { hasKey, pickProvider, stopAllAI, resumeAI } from './lib/llm.js';
import { localAI } from './lib/localai.js';
import { nasClient, writeTextFile, safeFileName } from './lib/nas.js';
import { after } from './lib/util.js';
import { projectFolders } from './lib/folders.js';
import { pageLabel, chunkText } from './lib/text.js';
import { IndexWriter } from './lib/index.js';
import { Recording } from './lib/recorder.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pad = (n) => String(n).padStart(2, '0');
const hms = (d) => `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
const money = (c) => (c < 0.01 ? `$${c.toFixed(4)}` : `$${c.toFixed(2)}`);

const state = {
  settings: null,
  ctx: null,
  them: null, // AudioChannel for the meeting
  me: null, // AudioChannel for the microphone
  themKind: '',
  stt: null,
  listening: false,
  meetingId: '',
  startedAt: 0,
  entries: [], // {who, text, start, end}
  prompts: [], // cards
  answers: [],
  project: '', // chosen by the user
  autoProjects: [],
  lastPromptAt: 0,
  lastPromptIdx: 0,
  prompting: null, // AbortController
  cost: 0,
  errors: [],
  savedPath: '',
  savedAt: 0,
  summary: null,
  pip: null,
  mirrorPaths: [], // NAS paths of the mirrored project folders
  recording: null, // a local audio recording of the meeting (Record audio toggle)
  aiPaused: false, // Stop AI (here or in the side panel): no prompts, answers or Gemini calls until resumed
  // Tests can provide audio instead of the real screen-share / microphone pickers.
  captureOverride: null, // async (kind: 'app'|'tab') => MediaStream
  micOverride: null, // async () => MediaStream
};
window.meeting = state;

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

function warn(html) {
  $('warn').innerHTML = html || '';
  $('warn').hidden = !html;
}

function myLabel() {
  return state.settings?.myVoiceLabel || 'Me';
}

function projects() {
  return state.project ? [state.project] : state.autoProjects;
}

// ---------------------------------------------------------------- listening

async function ensureContext() {
  if (!state.ctx) state.ctx = await createAudioContext();
  if (state.ctx.state === 'suspended') await state.ctx.resume();
}

async function listen(kind) {
  state.settings = await getSettings();
  try {
    await ensureContext();
  } catch (err) {
    warn(`Couldn't start audio processing: ${esc(err.message)}`);
    return;
  }
  let stream;
  try {
    setStatus(kind === 'app' ? 'Choose "Entire screen" and tick "Also share system audio"…' : 'Choose the Teams tab and keep "Also share tab audio" on…');
    stream = state.captureOverride ? await state.captureOverride(kind) : kind === 'app' ? await captureTeamsApp() : await captureTeamsTab();
  } catch (err) {
    if (err.name === 'NotAllowedError' || err.name === 'AbortError') {
      setStatus(state.listening ? 'Still listening to the previous source.' : 'Not listening — sharing was cancelled.');
      return;
    }
    warn(esc(err.message || String(err)));
    setStatus(state.listening ? 'Still listening to the previous source.' : 'Not listening.');
    return;
  }
  if (state.recording) await stopRecording('The meeting source changed, so the recording was saved. Click Record audio to start a new one.');
  state.them?.stop();
  state.them = new AudioChannel(state.ctx, stream, 'Them');
  state.themKind = kind;
  state.them.addEventListener('segment', (e) => onSegment(e, 'Them'));
  state.them.addEventListener('ended', () => {
    if (state.listening) {
      warn('Teams sharing stopped. Click <b>Teams app</b> or <b>Teams in Chrome</b> to listen again, or <b>Stop and save</b>.');
      setStatus('Meeting sound stopped.');
    }
  });
  warn('');
  if ($('chkMic').checked && !state.me) await startMic();
  await startSession();
  setStatus(`Listening to ${kind === 'app' ? 'the Teams app' : 'Teams in Chrome'}${state.me ? ' and your microphone' : ''}.`);
}

async function startMic() {
  try {
    const stream = state.micOverride ? await state.micOverride() : await captureMicrophone();
    state.me = new AudioChannel(state.ctx, stream, myLabel());
    state.me.addEventListener('segment', (e) => onSegment(e, myLabel()));
    state.me.addEventListener('ended', () => {
      state.me = null;
    });
  } catch (err) {
    toast(`Microphone not available (${err.message}). Listening to the meeting only.`, 6000);
    $('chkMic').checked = false;
  }
}

function stopMic() {
  state.me?.stop();
  state.me = null;
}

async function startSession() {
  if (state.listening) return;
  state.listening = true;
  state.meetingId = `m-${Date.now().toString(36)}`;
  state.startedAt = Date.now();
  state.entries = [];
  state.prompts = [];
  state.answers = [];
  state.summary = null;
  state.savedPath = '';
  state.cost = 0;
  state.errors = [];
  state.lastPromptAt = 0;
  state.lastPromptIdx = 0;
  $('btnStop').disabled = false;
  $('clock').hidden = false;
  renderTranscript();
  renderPrompts();
  renderAnswers();
  state.stt = new Transcriber(state.settings);
  state.stt.addEventListener('progress', (e) => {
    if (e.total) setStatus(`Getting the free speech model ready (first time only): ${Math.round((100 * e.loaded) / e.total)}% of ${e.file.split('/').pop()}`);
  });
  state.stt.addEventListener('text', (e) => onText(e.segment, e.text, e));
  state.stt.addEventListener('error', (e) => {
    const msg = e.error?.message || String(e.error);
    state.errors.push(msg);
    if (e.fatal) {
      warn(`The speech model couldn't load: ${esc(msg)}. <button id="sttRetry" type="button">Try again</button>${state.settings.geminiKey ? ' or switch Transcription to Gemini in ⚙.' : ''}`);
      $('sttRetry')?.addEventListener('click', () => {
        warn('');
        state.stt.retry();
      });
    } else if (state.errors.length <= 3) toast(`Transcription: ${msg}`, 6000);
  });
  state.stt.start().then(
    () => {
      state.sttEngine = state.stt?.engine;
      if (state.listening) setStatus(`Listening${{ gemini: ' · transcribing with Gemini', both: ' · transcribing with Gemini, checked by the free model' }[state.stt.engine] || ' · transcribing on this computer (free)'}.`);
    },
    () => {},
  );
  scheduleAutosave();
}

// ---------------------------------------------------------------- local recording of the meeting's sound

async function toggleRecording() {
  if (state.recording) {
    await stopRecording();
    return;
  }
  if (!state.them && !state.me) {
    toast('Start listening first (Teams app or Teams in Chrome) — the recording uses the same sound.');
    return;
  }
  const rec = new Recording({ kind: 'audio', streams: [state.them?.stream, state.me?.stream].filter(Boolean), label: 'meeting' });
  try {
    await rec.start();
  } catch (err) {
    toast(`Couldn't record: ${err.message}`, 6000);
    return;
  }
  state.recording = rec;
  renderRecording();
}

async function stopRecording(note) {
  const rec = state.recording;
  if (!rec) return null;
  state.recording = null;
  renderRecording();
  const r = await rec.stop();
  toast(note || `Recording saved: ${r.where}`, 6000);
  state.recordedTo = r.where;
  return r;
}

function renderRecording() {
  const b = $('btnRec');
  const rec = state.recording;
  b.setAttribute('aria-pressed', String(!!rec));
  b.textContent = rec ? `■ Recording ${Math.floor(rec.seconds / 60)}:${pad(Math.floor(rec.seconds % 60))}` : '⏺ Record audio';
}

async function stopAndSave() {
  if (!state.listening) return;
  $('btnStop').disabled = true;
  if (state.recording) await stopRecording();
  state.them?.stop();
  stopMic();
  state.them = null;
  setStatus('Finishing the transcript…');
  // Let the last segments be transcribed (up to a minute).
  const t0 = Date.now();
  while (state.stt && (state.stt.queue.length || state.stt.busy) && Date.now() - t0 < 60000) await new Promise((r) => setTimeout(r, 300));
  state.prompting?.abort();
  state.listening = false;
  await detectProject({ now: true });
  if (state.settings.meetingSummary && state.entries.length) {
    setStatus('Writing the summary…');
    try {
      state.summary = await summarize(state.entries, { projects: projects() });
      if (state.summary?.cost) state.cost += state.summary.cost;
    } catch (err) {
      state.errors.push(`summary: ${err.message}`);
      toast(`Summary failed: ${err.message}`, 6000);
    }
  }
  await save(true);
  state.stt?.stop();
  state.stt = null;
  $('clock').hidden = true;
  setStatus(state.savedPath ? `Saved to the NAS: ${state.savedPath}` : 'Stopped. (Not saved to the NAS — see the message below.)');
  renderSummary();
}

// ---------------------------------------------------------------- transcript

function onSegment(e, who) {
  if (!state.stt) return;
  state.stt.push({ samples: e.samples, start: e.start.getTime(), end: e.end.getTime(), who });
  updateBehind();
}

function words(t) {
  return String(t || '').toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, ' ').split(/\s+/).filter((w) => w.length > 1);
}

function similar(a, b) {
  const A = new Set(words(a));
  const B = words(b);
  if (!A.size || !B.length) return 0;
  return B.filter((w) => A.has(w)).length / Math.max(A.size, B.length);
}

// With speakers (no headset) the meeting also reaches the microphone. Drop those copies.
function isEcho(entry) {
  const others = state.entries.filter((x) => x.who !== entry.who && Math.abs(x.start - entry.start) < 6000);
  return others.some((x) => similar(x.text, entry.text) >= 0.6);
}

function onText(seg, text, extra = {}) {
  updateBehind();
  const t = String(text || '').trim();
  if (!t) return;
  const entry = { who: seg.who, text: t, start: seg.start, end: seg.end };
  // "both": the two transcriptions heard different numbers — shown so the user knows which line to doubt.
  if (extra.unsure && extra.alt) Object.assign(entry, { unsure: true, alt: String(extra.alt).trim() });
  if (isEcho(entry)) {
    if (entry.who === 'Them') {
      // The meeting copy is the real one: remove the microphone duplicate.
      state.entries = state.entries.filter((x) => !(x.who !== 'Them' && Math.abs(x.start - entry.start) < 6000 && similar(x.text, entry.text) >= 0.6));
    } else return;
  }
  let i = state.entries.length;
  while (i > 0 && state.entries[i - 1].start > entry.start) i--;
  state.entries.splice(i, 0, entry);
  renderTranscript();
  detectProject();
  maybePrompt();
}

function updateBehind() {
  const b = state.stt?.behindSec || 0;
  $('behind').textContent = b > 20 ? `transcription ${Math.round(b)} s behind${state.stt?.engine === 'whisper' ? ' (Gemini transcription is faster)' : ''}` : '';
}

function renderTranscript() {
  const box = $('transcript');
  if (!state.entries.length) {
    box.innerHTML = '<div class="empty small">Nothing yet.</div>';
    return;
  }
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
  box.innerHTML = state.entries.slice(-400).map((e) => `<div class="t ${e.who === 'Them' ? 'them' : 'me'}${e.unsure ? ' unsure' : ''}"><span class="ts">${hms(new Date(e.start))}</span><span class="who">${esc(e.who === 'Them' ? 'Them' : e.who)}</span><span>${esc(e.text)}${e.unsure ? `<span class="alt" title="The two transcriptions heard different numbers">⚠ or: “${esc(e.alt)}”</span>` : ''}</span></div>`).join('');
  if (atBottom) box.scrollTop = box.scrollHeight;
}

// Which project is being discussed: re-checked at most every 5 s (local, free), and once more when saving.
let projectCheckAt = 0;
let projectRecheck = null;
async function detectProject({ now = false } = {}) {
  if (state.project) return;
  const wait = 5000 - (Date.now() - projectCheckAt);
  if (!now && wait > 0) {
    if (!projectRecheck) projectRecheck = setTimeout(() => {
      projectRecheck = null;
      detectProject();
    }, wait);
    return;
  }
  projectCheckAt = Date.now();
  const text = state.entries.slice(-60).map((e) => e.text).join('\n');
  const found = await detectProjects(text).catch(() => []);
  if (found.length && found.join('|') !== state.autoProjects.join('|')) {
    state.autoProjects = found;
    $('project').options[0].textContent = `Detected: ${found[0].split('/').pop()}`;
  }
}

// ---------------------------------------------------------------- prompts

async function maybePrompt() {
  const s = state.settings;
  if (state.aiPaused || s.meetingPrompts !== 'auto' || state.prompting || !hasKey(s, pickProvider(s, s.meetingProvider || s.provider))) return;
  const fresh = state.entries.slice(state.lastPromptIdx);
  const d = await shouldPrompt(fresh, {
    sinceLastMs: Date.now() - state.lastPromptAt,
    minGapMs: (s.meetingMinGapSec || 20) * 1000,
    myName: s.myName,
    myLabel: myLabel(),
  });
  if (d.go) runPrompt(d.reason);
}

async function runPrompt(reason, { manual = false } = {}) {
  if (state.prompting) return;
  const s = state.settings || (state.settings = await getSettings());
  if (!hasKey(s, pickProvider(s, s.meetingProvider || s.provider))) {
    toast('Add a Claude or Gemini key in Settings to get prompts. The transcript works without one.', 6000);
    return;
  }
  if (!state.entries.length && manual) {
    toast('Nothing has been said yet.');
    return;
  }
  if (state.aiPaused) {
    toast('AI is stopped. Click ▶ Resume AI to get prompts again.');
    return;
  }
  state.prompting = new AbortController();
  state.lastPromptAt = Date.now();
  state.lastPromptIdx = state.entries.length;
  const card = { id: `p${Date.now()}`, at: Date.now(), thinking: true, reason, manual };
  state.prompts.unshift(card);
  renderPrompts();
  try {
    const res = await makePrompt(state.entries, { projects: projects(), signal: state.prompting.signal });
    Object.assign(card, res, { thinking: false });
    state.cost += (res.cost || 0) + (res.web?.cost || 0);
    if (!res.needed && !res.web?.text) {
      if (manual) Object.assign(card, { empty: true });
      else state.prompts.splice(state.prompts.indexOf(card), 1);
    } else runCheck(card, renderPrompts);
  } catch (err) {
    Object.assign(card, { thinking: false, error: err.message || String(err) });
    state.errors.push(`prompt: ${card.error}`);
  } finally {
    state.prompting = null;
  }
  renderPrompts();
  renderCost();
}

// ---- the second check: shown on each card once it is done (it runs after the card appears) ----

const AI_NAME = { gemini: 'Gemini', anthropic: 'Claude' };

function runCheck(obj, render) {
  if (!obj.review || state.aiPaused) {
    delete obj.review;
    return;
  }
  obj.check = { pending: true };
  render();
  checkResult(obj)
    .then((r) => {
      obj.check = r;
      state.cost += r?.cost || 0;
    })
    .catch((err) => {
      obj.check = { error: err.message || String(err) };
    })
    .finally(() => {
      delete obj.review; // the excerpts aren't kept with the meeting
      render();
      renderCost();
    });
}

function checkHtml(c) {
  if (!c) return '';
  if (c.pending) return '<div class="chk pending small">Checking…</div>';
  if (c.error) return `<div class="chk warn small" data-check="unchecked">Not double-checked: ${esc(c.error)}</div>`;
  const local = [];
  if ((c.badQuotes || []).length) local.push(`${c.badQuotes.length === 1 ? 'a quote was' : `${c.badQuotes.length} quotes were`} not found word for word in the file`);
  if ((c.unsupported || []).length) local.push(`numbers not in the files or the transcript: ${c.unsupported.join(', ')}`);
  const findings = [...(c.issues || []).map((i) => `<li><b>“${esc(i.claim)}”</b> — ${esc(i.problem)}${i.evidence ? ` <span class="muted">${esc(i.evidence)}</span>` : ''}${i.fix && i.fix !== 'remove' ? ` <span class="muted">→ ${esc(i.fix)}</span>` : ''}</li>`), ...(c.missed || []).map((m) => `<li>Not covered: ${esc(m)}</li>`), ...local.map((l) => `<li>${esc(l)}</li>`)];
  if (c.verdict === 'ok' && !findings.length) return `<div class="chk ok small" data-check="ok">✓ ${c.by ? `Checked by ${AI_NAME[c.by]} against the files` : 'Quotes and numbers found in the files'}</div>`;
  return `<div class="chk warn small" data-check="issues">⚠ ${c.by ? `${AI_NAME[c.by]} disagrees` : 'Check before using'}:<ul class="plain">${findings.join('')}</ul></div>`;
}

function quoteMark(src) {
  if (src.verified === true) return '<span class="qok" title="Quote found word for word in the file">✓</span>';
  if (src.verified === false) return '<span class="qbad" title="This quote was NOT found word for word in the file — check it">⚠ not in the file</span>';
  return '';
}

function sourceHtml(src) {
  const name = (src.path || '').split('/').pop() || src.ref;
  const where = src.page ? ` · ${pageLabel(src.path, src.page)}` : '';
  // An email inside a .pst mailbox can't be opened on its own; the quote is the useful part.
  if (/\.pst$/i.test(src.path || '')) return `<div class="src">✉ <span title="${esc(src.path)}">${esc(name)}${where}</span> <span class="quote">“${esc(src.quote)}”</span> ${quoteMark(src)}</div>`;
  return `<div class="src">📄 <a data-open="${esc(src.path)}" data-page="${src.page || 0}" title="${esc(src.path)}">${esc(name)}${where}</a> <span class="quote">“${esc(src.quote)}”</span> ${quoteMark(src)}</div>`;
}

function linksHtml(list) {
  return (list || []).filter((s) => /^https?:\/\//i.test(s.url || '')).map((s) => `<div class="src"><a href="${esc(s.url)}" target="_blank" rel="noopener noreferrer">${esc(s.title || s.url)}</a></div>`).join('');
}

function webHtml(web) {
  if (!web) return '';
  if (web.error) return `<div class="web muted">Online look-up failed: ${esc(web.error)}</div>`;
  // Looked up by both AIs, each with its own search engine: do they give the same numbers?
  let both = '';
  if (web.second) {
    const a = AI_NAME[web.by];
    const b = AI_NAME[web.second.by];
    const verdict = web.agree === true ? `<div class="chk ok small" data-agree="yes">✓ ${a} and ${b} looked it up separately and found the same values.</div>`
      : web.agree === false ? `<div class="chk warn small" data-agree="no">⚠ ${a} and ${b} found different values — check the documents below before relying on it.</div>`
        : `<div class="chk small muted" data-agree="unknown">${b} looked it up too (no numbers to compare).</div>`;
    both = `${verdict}<details class="small"${web.agree === false ? ' open' : ''}><summary>What ${b} found</summary><div>${esc(web.second.text)}</div>${linksHtml(web.second.sources)}</details>`;
  }
  return `<div class="web">🌐 ${esc(web.text)}${linksHtml(web.sources)}${both}</div>`;
}

function promptCardHtml(c, i) {
  if (c.thinking) return `<div class="card" data-i="${i}"><div class="thinking">Thinking${c.manual ? '' : ` (${esc(c.reason)})`}…</div></div>`;
  if (c.error) return `<div class="card" data-i="${i}"><div class="err">${esc(c.error)}</div></div>`;
  if (c.empty) return `<div class="card" data-i="${i}"><div class="muted small">Nothing useful to add right now${c.topic ? ` about ${esc(c.topic)}` : ''}.</div></div>`;
  const fresh = Date.now() - c.at < 15000;
  const sug = (c.suggestions || []).map((s) => `<div class="say">${esc(s.say)}</div><div class="why">${esc(s.why)}</div>${(s.sources || []).map(sourceHtml).join('')}`).join('<hr class="sep">');
  return `<div class="card ${fresh ? 'new' : ''} ${c.pinned ? 'pinned' : ''}" data-i="${i}">
    ${c.topic ? `<div class="small muted">${esc(c.topic)}</div>` : ''}${sug}${checkHtml(c.check)}${webHtml(c.web)}
    <div class="meta"><span>${hms(new Date(c.at))}</span><span class="grow"></span>
      ${c.id === 'summary' ? '' : `<button data-act="good" title="Useful — prefer these documents for this topic">👍</button>
      <button data-act="bad" title="Not useful — avoid these documents for this topic">👎</button>`}
      <button data-act="pin" title="Keep at the top">${c.pinned ? 'Unpin' : '📌'}</button></div></div>`;
}

function renderPrompts() {
  const list = [...state.prompts].sort((a, b) => (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0));
  const html = list.length ? list.slice(0, 30).map((c) => promptCardHtml(c, state.prompts.indexOf(c))).join('') : '<div class="empty small">Prompts appear here when a question or a new topic comes up.</div>';
  $('prompts').innerHTML = html;
  const pipList = state.pip?.document.getElementById('pipList');
  if (pipList) pipList.innerHTML = html + answersHtml();
}

async function onPromptClick(e) {
  const open = e.target.closest('[data-open]');
  if (open) {
    openFile(open.dataset.open, Number(open.dataset.page) || 0);
    return;
  }
  const b = e.target.closest('[data-act]');
  const cardEl = e.target.closest('[data-i]');
  if (!b || !cardEl) return;
  const c = state.prompts[Number(cardEl.dataset.i)];
  if (!c) return;
  if (b.dataset.act === 'pin') c.pinned = !c.pinned;
  if (b.dataset.act === 'good' || b.dataset.act === 'bad') {
    const paths = [...new Set((c.suggestions || []).flatMap((s) => (s.sources || []).map((x) => x.path)).filter(Boolean))];
    const keywords = [c.topic, ...(c.suggestions || []).map((s) => s.say)].join(' ');
    for (const p of paths) await addHint(keywords, p, b.dataset.act === 'good' ? 'prefer' : 'avoid').catch(() => {});
    toast(paths.length ? (b.dataset.act === 'good' ? 'Learned: these documents are right for this topic.' : 'Learned: skip these documents for this topic.') : 'Noted.');
  }
  renderPrompts();
}

async function openFile(path, page) {
  if (!path) return;
  try {
    const file = await (await nasClient()).getBlob('/' + path);
    if (!file) throw new Error('not on the NAS yet (mirror the folder first)');
    const url = URL.createObjectURL(file) + (/\.pdf$/i.test(path) && page ? `#page=${page}` : '');
    window.open(url, '_blank');
  } catch (err) {
    toast(`Couldn't open ${path.split('/').pop()}: ${err.message}`, 6000);
  }
}

// ---------------------------------------------------------------- private questions

function answersHtml() {
  return state.answers.map((a) => (a.thinking ? `<div class="card private"><div class="small"><b>You asked:</b> ${esc(a.q)}</div><div class="thinking">Looking…</div></div>` : `<div class="card private">
      <div class="small"><b>You asked:</b> ${esc(a.q)}</div>
      ${a.error ? `<div class="err">${esc(a.error)}</div>` : `<div>${esc(a.answer)}</div>${a.say ? `<div class="say" style="margin-top:4px">Say: ${esc(a.say)}</div>` : ''}${(a.sources || []).map(sourceHtml).join('')}${checkHtml(a.check)}${webHtml(a.web)}`}
    </div>`)).join('');
}

function renderAnswers() {
  $('answers').innerHTML = answersHtml();
  renderPrompts();
}

async function ask(q) {
  q = String(q || '').trim();
  if (!q) return;
  state.settings = state.settings || (await getSettings());
  if (state.aiPaused) {
    toast('AI is stopped. Click ▶ Resume AI to ask questions again.');
    return;
  }
  const a = { q, at: Date.now(), thinking: true };
  state.answers.unshift(a);
  renderAnswers();
  try {
    const res = await answerQuestion(q, state.entries, { projects: projects() });
    Object.assign(a, res, { thinking: false });
    state.cost += (res.cost || 0) + (res.web?.cost || 0);
    runCheck(a, renderAnswers);
  } catch (err) {
    Object.assign(a, { thinking: false, error: err.message || String(err) });
  }
  renderAnswers();
  renderCost();
}

// ---------------------------------------------------------------- saving

function markdown() {
  const start = new Date(state.startedAt || Date.now());
  const date = `${start.getFullYear()}-${pad(start.getMonth() + 1)}-${pad(start.getDate())}`;
  const mins = Math.round(((state.entries.at(-1)?.end || Date.now()) - state.startedAt) / 60000);
  const proj = projects()[0];
  const lines = [`# ${state.summary?.title || 'Teams meeting'} — ${date} ${pad(start.getHours())}:${pad(start.getMinutes())}`, ''];
  if (proj) lines.push(`Project: ${proj}`);
  const how = { gemini: 'with Gemini', both: 'with Gemini, checked by Whisper' }[state.sttEngine || state.stt?.engine] || 'on this computer (Whisper)';
  lines.push(`Length: about ${Math.max(1, mins)} min · Transcribed ${how}${state.cost ? ` · AI cost ${money(state.cost)}` : ''}`, '');
  if (state.recordedTo) lines.push(`Audio recording (on the computer): ${state.recordedTo}`, '');
  const sm = state.summary;
  if (sm) {
    lines.push('## Summary', '', sm.summary || '', '');
    if (sm.decisions?.length) lines.push('## Decisions', '', ...sm.decisions.map((d) => `- ${d}`), '');
    if (sm.action_items?.length) lines.push('## Action items', '', ...sm.action_items.map((a) => `- [ ] ${a.what}${a.who ? ` — ${a.who}` : ''}${a.when ? ` (${a.when})` : ''}`), '');
    if (sm.open_questions?.length) lines.push('## Open questions', '', ...sm.open_questions.map((q) => `- ${q}`), '');
    const ck = sm.check;
    if (ck?.by) {
      const found = [...(ck.issues || []).map((i) => `- “${i.claim}” — ${i.problem}${i.fix && i.fix !== 'remove' ? ` (→ ${i.fix})` : ''}`), ...(ck.missed || []).map((m) => `- Not covered: ${m}`)];
      lines.push(`## Checked by ${AI_NAME[ck.by]}`, '', ...(found.length ? found : ['No problems found against the transcript.']), '');
    }
  }
  const shown = state.prompts.filter((p) => !p.thinking && !p.error && !p.empty);
  if (shown.length) {
    lines.push('## Prompts shown', '');
    for (const p of [...shown].reverse()) {
      const flag = p.check?.verdict === 'issues' ? ' ⚠ (the second check disagreed)' : '';
      for (const sgt of p.suggestions || []) lines.push(`- ${hms(new Date(p.at))} — ${sgt.say}${(sgt.sources || []).length ? ` _(${sgt.sources.map((x) => `${x.path.split('/').pop()}${x.page ? ` ${pageLabel(x.path, x.page)}` : ''}${x.verified === false ? ' — quote not found in the file' : ''}`).join('; ')})_` : ''}${flag}`);
      if (p.web?.text) lines.push(`- ${hms(new Date(p.at))} — 🌐 ${p.web.text.replace(/\n+/g, ' ')}`);
    }
    lines.push('');
  }
  const asked = state.answers.filter((a) => !a.thinking);
  if (asked.length) {
    lines.push('## Private questions', '');
    for (const a of [...asked].reverse()) lines.push(`- **${a.q}** — ${a.error ? `(failed: ${a.error})` : a.answer}`);
    lines.push('');
  }
  lines.push('## Transcript', '');
  for (const e of state.entries) lines.push(`**[${hms(new Date(e.start))}] ${e.who === 'Them' ? 'Them' : e.who}:** ${e.text}${e.unsure ? ` _(unsure — the other transcription heard: “${e.alt}”)_` : ''}  `);
  return lines.join('\n') + '\n';
}

// Never inside a mirrored project folder: the next one-way sync would delete a file that isn't on the computer.
function meetingRoot() {
  const want = `/${String(state.settings.meetingFolder || '/Meetings').replace(/^\/+|\/+$/g, '')}`;
  const inside = state.mirrorPaths.some((p) => want === p || want.startsWith(`${p}/`) || p === '/');
  return inside || want === '/' ? '/Meetings' : want;
}

function nasPathFor() {
  const start = new Date(state.startedAt);
  const stamp = `${start.getFullYear()}-${pad(start.getMonth() + 1)}-${pad(start.getDate())} ${pad(start.getHours())}${pad(start.getMinutes())}`;
  const proj = projects()[0];
  const folder = `${meetingRoot()}${proj ? `/${safeFileName(proj.split('/').pop())}` : ''}`;
  return `${folder}/${stamp} ${safeFileName(state.summary?.title || 'Teams meeting')}.md`;
}

async function save(final = false) {
  if (!state.startedAt || !state.entries.length) return;
  await detectProject({ now: true });
  const rec = {
    id: state.meetingId,
    title: state.summary?.title || 'Teams meeting',
    startedAt: state.startedAt,
    endedAt: final ? Date.now() : null,
    project: projects()[0] || '',
    segments: state.entries,
    prompts: state.prompts.filter((p) => !p.thinking).map(({ hitPaths, review, ...p }) => p),
    answers: state.answers.filter((a) => !a.thinking).map(({ review, ...a }) => a),
    summary: state.summary,
    cost: state.cost,
    errors: state.errors.slice(-20),
    savedPath: state.savedPath,
  };
  await put('meetings', rec).catch(() => {});
  try {
    const client = await nasClient();
    const path = nasPathFor();
    await writeTextFile(client, path, markdown());
    if (state.savedPath && state.savedPath !== path) await client.remove(state.savedPath, { ignoreMissing: true }).catch(() => {});
    if (state.indexedPath && state.indexedPath !== path) await unindexMeeting(state.indexedPath);
    state.savedPath = path;
    state.savedAt = Date.now();
    rec.savedPath = path;
    await put('meetings', rec).catch(() => {});
    if (final) await indexMeeting(path);
    $('saved').textContent = `Saved ${hms(new Date())} → ${path}`;
  } catch (err) {
    $('saved').textContent = `Not saved to the NAS (${err.message}) — kept on this computer.`;
    state.errors.push(`save: ${err.message}`);
  }
}

// Past meetings are searchable like any project file ("what did we agree on the deck width last week?").
async function indexMeeting(nasPath) {
  try {
    const md = markdown();
    const path = nasPath.replace(/^\/+/, '');
    const w = new IndexWriter();
    await w.addFile(
      { path, rel: path, folderId: 'meeting', size: md.length, mtime: Date.now(), ext: 'md', project: projects()[0] || '', method: 'meeting', chars: md.length, note: '', indexedAt: Date.now() },
      chunkText(md),
    );
    await w.finish();
    state.indexedPath = nasPath;
  } catch (err) {
    state.errors.push(`index: ${err.message}`);
  }
}

async function unindexMeeting(nasPath) {
  try {
    const w = new IndexWriter();
    await w.removeFile(nasPath.replace(/^\/+/, ''));
    await w.finish();
  } catch {
    /* not indexed */
  }
}

let cancelAutosave = null;
function scheduleAutosave() {
  cancelAutosave?.();
  cancelAutosave = after(60000, async () => {
    if (!state.listening) return;
    await save(false);
    scheduleAutosave();
  });
}

function renderSummary() {
  const sm = state.summary;
  if (!sm) return;
  const card = { id: 'summary', at: Date.now(), topic: 'Meeting summary', suggestions: [{ say: sm.summary, why: [sm.decisions?.length ? `${sm.decisions.length} decision(s)` : '', sm.action_items?.length ? `${sm.action_items.length} action item(s)` : ''].filter(Boolean).join(' · '), sources: [] }], pinned: true, check: sm.check ? (sm.check.error ? { error: sm.check.error } : { ...sm.check, verdict: sm.check.verdict }) : null };
  state.prompts.unshift(card);
  renderPrompts();
}

function renderCost() {
  $('cost').textContent = state.cost ? `AI ${money(state.cost)}` : '';
}

// ---------------------------------------------------------------- meters and clock

function updateMeter(id, ch, offText) {
  const el = $(id);
  const fill = el.querySelector('.fill');
  const peak = el.querySelector('.peak');
  const st = el.querySelector('.state');
  if (!ch) {
    el.className = 'meter off';
    fill.style.width = '0';
    peak.style.left = '0';
    st.textContent = offText;
    return;
  }
  ch.level *= 0.9; // decays between frames, so the bar falls when sound stops
  fill.style.width = `${Math.round(Math.min(1, ch.level) * 100)}%`;
  peak.style.left = `${Math.round(Math.min(1, ch.peak) * 100)}%`;
  const quiet = ch.silentFor(15000);
  const hearing = Date.now() - ch.lastSoundAt < 1500;
  el.className = `meter ${quiet ? 'quiet' : hearing ? 'live' : ''}`;
  st.textContent = quiet ? 'no sound' : hearing ? 'hearing sound' : 'quiet';
  return quiet;
}

setInterval(() => {
  const themQuiet = updateMeter('mThem', state.them, 'off');
  updateMeter('mMe', state.me, $('chkMic').checked ? 'off' : 'not used');
  if (state.listening && state.them && themQuiet && $('warn').hidden) {
    warn(state.themKind === 'app'
      ? 'No sound from the meeting for 15 s. If people are talking: share again with <b>Entire screen</b> and tick <b>Also share system audio</b>.'
      : 'No sound from the meeting for 15 s. If people are talking: share again, pick the Teams tab, and keep <b>Also share tab audio</b> on.');
  } else if (state.them && !themQuiet && /No sound from the meeting/.test($('warn').textContent)) warn('');
  if (state.recording) renderRecording();
  if (state.listening) {
    const s = Math.round((Date.now() - state.startedAt) / 1000);
    $('clock').textContent = `● ${Math.floor(s / 60)}:${pad(s % 60)}`;
  }
  const pipDoc = state.pip?.document;
  if (pipDoc) {
    for (const [id, ch] of [['pThem', state.them], ['pMe', state.me]]) {
      const f = pipDoc.getElementById(id);
      if (f) f.style.width = `${Math.round(Math.min(1, ch?.level || 0) * 100)}%`;
    }
  }
}, 100);

// ---------------------------------------------------------------- always-on-top window

async function popOut() {
  if (state.pip) {
    state.pip.focus();
    return;
  }
  if (!('documentPictureInPicture' in window)) {
    toast('This Chrome version cannot keep a window on top. Keep this window beside Teams instead.', 6000);
    return;
  }
  try {
    const pip = await window.documentPictureInPicture.requestWindow({ width: 380, height: 520 });
    for (const link of document.querySelectorAll('link[rel="stylesheet"]')) {
      const l = pip.document.createElement('link');
      l.rel = 'stylesheet';
      l.href = link.href;
      pip.document.head.append(l);
    }
    pip.document.title = 'Prompts';
    pip.document.body.className = 'pip';
    pip.document.body.innerHTML = `<div class="pip-wrap">
      <div class="pip-meters"><span>Meeting</span><div class="bar meter"><div class="fill" id="pThem"></div></div><span>Me</span><div class="bar meter"><div class="fill" id="pMe"></div></div><button id="pipAskNow">Ask now</button><button id="pipAi" title="Stop / resume AI">⏹ Stop AI</button></div>
      <div class="pip-list" id="pipList"></div>
      <form id="pipAsk" class="row nowrap"><input id="pipQ" class="grow" type="text" placeholder="Ask privately…" autocomplete="off"><button class="primary" type="submit">Ask</button></form>
    </div>`;
    pip.document.getElementById('pipAsk').addEventListener('submit', (e) => {
      e.preventDefault();
      const q = pip.document.getElementById('pipQ');
      ask(q.value);
      q.value = '';
    });
    pip.document.getElementById('pipAskNow').addEventListener('click', () => runPrompt('asked', { manual: true }));
    pip.document.getElementById('pipAi').addEventListener('click', toggleAi);
    renderAi();
    pip.document.getElementById('pipList').addEventListener('click', onPromptClick);
    pip.addEventListener('pagehide', () => {
      state.pip = null;
    });
    state.pip = pip;
    renderPrompts();
  } catch (err) {
    toast(`Couldn't pop out: ${err.message}`, 6000);
  }
}

// ---------------------------------------------------------------- settings and wiring

async function loadProjects() {
  const list = (await kvGet('projects')) || [];
  const sel = $('project');
  for (const p of list) {
    const o = document.createElement('option');
    o.value = p;
    o.textContent = p.split('/').pop();
    sel.append(o);
  }
}

function fillSettings() {
  for (const el of document.querySelectorAll('#setDlg [data-key]')) {
    const v = state.settings[el.dataset.key];
    if (el.type === 'checkbox') el.checked = !!v;
    else el.value = v ?? '';
  }
}

$('setDlg').addEventListener('change', async (e) => {
  const el = e.target;
  if (!el.dataset.key) return;
  const v = el.type === 'checkbox' ? el.checked : el.type === 'number' ? Number(el.value) || 20 : el.value;
  state.settings = await saveSettings({ [el.dataset.key]: v });
  if (el.dataset.key === 'meetingStt' && state.listening) toast('The new transcription choice applies to the next meeting.');
});

$('btnSettings').addEventListener('click', async () => {
  state.settings = await getSettings();
  fillSettings();
  const la = await localAI.check();
  $('localAiNote').textContent = la === 'available' ? "Chrome's built-in AI is available on this computer: it decides when a prompt is worth paying for." : "Chrome's built-in AI isn't available on this computer; simple rules decide when to prompt instead.";
  $('setDlg').showModal();
});
$('btnApp').addEventListener('click', () => listen('app'));
$('btnTab').addEventListener('click', () => listen('tab'));
$('chkMic').addEventListener('change', async () => {
  if (!state.listening) return;
  if ($('chkMic').checked) await startMic();
  else stopMic();
});
$('btnStop').addEventListener('click', stopAndSave);
$('btnRec').addEventListener('click', toggleRecording);

// ---- the kill switch ----
function renderAi() {
  const b = $('btnAi');
  b.textContent = state.aiPaused ? '▶ Resume AI' : '⏹ Stop AI';
  b.className = state.aiPaused ? 'primary' : 'danger';
  b.setAttribute('aria-pressed', String(state.aiPaused));
  const pip = state.pip?.document.getElementById('pipAi');
  if (pip) pip.textContent = state.aiPaused ? '▶ Resume AI' : '⏹ Stop AI';
}
async function toggleAi() {
  if (state.aiPaused) {
    await resumeAI();
    state.aiPaused = false;
    toast('AI resumed.');
  } else {
    await stopAllAI(); // cancels the calls in progress here and in every other part of the extension
    state.aiPaused = true;
    state.prompting?.abort();
    toast('AI stopped: no prompts, answers or Gemini transcription until you resume. Listening and saving carry on.', 6000);
  }
  renderAi();
}
$('btnAi').addEventListener('click', toggleAi);
chrome.runtime.onMessage.addListener((m) => {
  if (m?.type === 'ai.stopAll' || m?.type === 'ai.resumed') {
    state.aiPaused = m.type === 'ai.stopAll';
    if (state.aiPaused) state.prompting?.abort();
    renderAi();
  }
  return false;
});
$('btnAsk').addEventListener('click', () => runPrompt('asked', { manual: true }));
$('btnPip').addEventListener('click', popOut);
$('prompts').addEventListener('click', onPromptClick);
$('answers').addEventListener('click', onPromptClick);
$('askForm').addEventListener('submit', (e) => {
  e.preventDefault();
  ask($('askInput').value);
  $('askInput').value = '';
});
$('project').addEventListener('change', () => {
  state.project = $('project').value;
});
window.addEventListener('beforeunload', (e) => {
  if (state.listening) {
    save(false);
    e.preventDefault();
    e.returnValue = '';
  }
});

state.onText = onText; // for the automated tests
state.nasPathFor = nasPathFor;
state.renderPrompts = renderPrompts;
state.settings = await getSettings();
state.aiPaused = !!state.settings.aiPaused;
renderAi();
state.mirrorPaths = (await projectFolders({ withPerm: false }).catch(() => [])).map((f) => f.nasPath);
await loadProjects();
state.ready = true;
