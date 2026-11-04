// Recorder window: two toggles — record the computer's sound (or one tab's), or record the screen with its sound —
// optionally with the microphone mixed in, saved to a folder on this computer (or Downloads).

import { Recording, getRecordingFolder, setRecordingFolder } from './lib/recorder.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pad = (n) => String(n).padStart(2, '0');
const clock = (sec) => `${Math.floor(sec / 3600) ? `${Math.floor(sec / 3600)}:` : ''}${pad(Math.floor((sec % 3600) / 60))}:${pad(Math.floor(sec % 60))}`;
const size = (b) => (b > 1e9 ? `${(b / 1e9).toFixed(2)} GB` : b > 1e6 ? `${(b / 1e6).toFixed(1)} MB` : `${Math.round(b / 1e3)} KB`);

const state = {
  audio: null,
  screen: null,
  done: [],
  // Tests can stand in for Chrome's share picker and the microphone.
  captureOverride: null,
  micOverride: null,
};
window.recorder = state;

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

function message(text) {
  $('msg').textContent = text || '';
  $('msg').hidden = !text;
}

async function toggle(kind) {
  const btn = kind === 'audio' ? $('tglAudio') : $('tglScreen');
  const cur = state[kind];
  btn.disabled = true;
  try {
    if (cur) {
      await finish(kind);
      return;
    }
    message('');
    const rec = new Recording({
      kind,
      source: $('audioSource').value,
      includeMic: $('chkMic').checked,
      captureOverride: state.captureOverride,
      micOverride: state.micOverride,
    });
    try {
      await rec.start();
    } catch (err) {
      if (err.name === 'NotAllowedError' || err.name === 'AbortError') toast('Recording cancelled.');
      else message(err.message || String(err));
      return;
    }
    if (rec.micError) toast(`Recording without the microphone (${rec.micError}).`, 6000);
    rec.addEventListener('stopped', (e) => {
      state[kind] = null;
      addDone(e.result);
      render();
    });
    state[kind] = rec;
  } finally {
    btn.disabled = false;
    render();
  }
}

async function finish(kind) {
  const rec = state[kind];
  if (!rec) return;
  state[kind] = null;
  const result = await rec.stop();
  addDone(result);
}

function addDone(result) {
  if (!result || state.done.some((d) => d.name === result.name)) return;
  state.done.unshift(result);
  if (result.error) message(`The recording may be incomplete: ${result.error}`);
  else toast(`Saved: ${result.where}`);
  renderList();
}

function render() {
  for (const [kind, id, label] of [['audio', 'tglAudio', '🎙 Record audio'], ['screen', 'tglScreen', '🖥 Record screen + audio']]) {
    const btn = $(id);
    const rec = state[kind];
    btn.setAttribute('aria-pressed', String(!!rec));
    btn.querySelector('.t-label').textContent = rec ? `■ Stop ${kind === 'audio' ? 'audio' : 'screen'} recording` : label;
    btn.querySelector('.t-time').textContent = rec ? `${clock(rec.seconds)} · ${size(rec.bytes)}` : '';
  }
  $('audioSource').disabled = !!state.audio;
}

function renderList() {
  $('list').innerHTML = state.done.length
    ? state.done.map((d, i) => `<div class="rec"><span class="name"><b>${esc(d.name)}</b><br><span class="muted">${clock(d.seconds)} · ${size(d.bytes)} · ${esc(d.where)}</span></span>${d.downloadId ? `<button data-show="${i}">Show</button>` : ''}</div>`).join('')
    : '<div class="muted">None yet.</div>';
}

$('list').addEventListener('click', (e) => {
  const b = e.target.closest('[data-show]');
  if (b) chrome.downloads.show(state.done[Number(b.dataset.show)].downloadId);
});

async function renderWhere() {
  const folder = await getRecordingFolder();
  let perm = 'granted';
  if (folder && typeof folder.queryPermission === 'function') perm = await folder.queryPermission({ mode: 'readwrite' }).catch(() => 'prompt');
  $('btnDownloads').hidden = !folder;
  if (!folder) $('where').innerHTML = 'Chrome\'s <b>Downloads</b> folder, in <b>Recordings</b>. Choose a folder to save somewhere else.';
  else if (perm === 'granted') $('where').innerHTML = `The folder <b>${esc(folder.name)}</b>.`;
  else $('where').innerHTML = `The folder <b>${esc(folder.name)}</b> — <button id="btnAllow" class="link">allow access again</button> (until then, Downloads is used).`;
  $('btnAllow')?.addEventListener('click', async () => {
    await folder.requestPermission({ mode: 'readwrite' }).catch(() => {});
    renderWhere();
  });
}

$('btnFolder').addEventListener('click', async () => {
  try {
    const dir = await (state.pickFolder ? state.pickFolder() : window.showDirectoryPicker({ id: 'recordings', mode: 'readwrite', startIn: 'videos' }));
    await setRecordingFolder(dir);
    renderWhere();
  } catch (err) {
    if (err.name !== 'AbortError') toast(err.message, 6000);
  }
});
$('btnDownloads').addEventListener('click', async () => {
  await setRecordingFolder(null);
  renderWhere();
});
$('tglAudio').addEventListener('click', () => toggle('audio'));
$('tglScreen').addEventListener('click', () => toggle('screen'));

setInterval(() => {
  const lv = { system: 0, mic: 0 };
  for (const rec of [state.audio, state.screen]) {
    if (!rec) continue;
    const l = rec.levels();
    lv.system = Math.max(lv.system, l.system || 0);
    lv.mic = Math.max(lv.mic, l.mic || 0);
  }
  $('mSys').querySelector('.fill').style.width = `${Math.round(lv.system * 100)}%`;
  $('mMic').querySelector('.fill').style.width = `${Math.round(lv.mic * 100)}%`;
  if (state.audio || state.screen) render();
}, 200);

window.addEventListener('beforeunload', (e) => {
  if (state.audio || state.screen) {
    e.preventDefault();
    e.returnValue = '';
  }
});

renderWhere();
render();
state.ready = true;
