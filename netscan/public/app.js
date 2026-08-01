'use strict';

const $ = (sel) => document.querySelector(sel);
const api = async (path, opts) => {
  const res = await fetch(path, opts);
  const ct = res.headers.get('content-type') || '';
  const data = ct.includes('json') ? await res.json() : await res.text();
  if (!res.ok) throw new Error((data && data.error) || res.statusText);
  return data;
};

let devices = [];
const streamTimers = new Map();

function setStatus(html) { $('#status').innerHTML = html; }

async function loadInterfaces() {
  try {
    const { interfaces } = await api('/api/interfaces');
    if (!interfaces.length) { $('#ifaces').textContent = 'No active network interface detected.'; return; }
    $('#ifaces').textContent = 'Connected: ' + interfaces.map((i) => `${i.name} ${i.address} (bcast ${i.broadcast})`).join('   ·   ');
  } catch (e) { $('#ifaces').textContent = ''; }
}

async function scan() {
  const btn = $('#scanBtn');
  btn.disabled = true;
  const deep = $('#deep').checked;
  setStatus('<span class="spin"></span> Scanning' + (deep ? ' (deep — probing subnet, this can take ~10s)…' : '…'));
  try {
    const result = await api('/api/scan?deep=' + (deep ? '1' : '0'), { method: 'POST' });
    devices = result.devices || [];
    render();
    setStatus(`Found ${devices.length} device(s). Probed ${result.scanned} address(es). Click "Scan network" again to refresh.`);
  } catch (e) {
    setStatus('Scan failed: ' + e.message);
  } finally {
    btn.disabled = false;
  }
}

function render() {
  // Tear down any live streams from a previous render so orphaned timers
  // don't keep firing against detached <img> elements.
  for (const id of Array.from(streamTimers.keys())) stopStream(id);
  for (const kind of ['camera', 'switch', 'light', 'other']) {
    const list = devices.filter((d) => d.kind === kind);
    $('#count-' + kind).textContent = list.length;
    const grid = $('#grid-' + kind);
    grid.innerHTML = '';
    if (!list.length) {
      const empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = 'None found yet.';
      grid.appendChild(empty);
      continue;
    }
    for (const dev of list) grid.appendChild(kind === 'camera' ? cameraCard(dev) : deviceCard(dev));
  }
}

function header(dev) {
  const row = el('div', 'row');
  const left = el('div');
  left.appendChild(el('div', 'name', dev.name || 'Device'));
  left.appendChild(el('div', 'meta', [dev.ip, dev.model, dev.vendor].filter(Boolean).join(' · ')));
  row.appendChild(left);
  row.appendChild(el('span', 'badge', dev.protocol));
  return row;
}

function deviceCard(dev) {
  const card = el('div', 'card');
  const top = header(dev);
  if (dev.capabilities.power) {
    const sw = document.createElement('label');
    sw.className = 'switch';
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.checked = !!dev.state.on;
    input.addEventListener('change', async () => {
      try { await api(`/api/devices/${dev.id}/power`, jsonBody({ on: input.checked })); dev.state.on = input.checked; }
      catch (e) { input.checked = !input.checked; setStatus('Control failed: ' + e.message); }
    });
    const slider = el('span', 'slider');
    sw.append(input, slider);
    top.appendChild(sw);
  }
  card.appendChild(top);

  if (dev.capabilities.brightness) {
    const r = el('div', 'control-row');
    r.appendChild(el('label', '', 'Bright'));
    const range = document.createElement('input');
    range.type = 'range'; range.min = 1; range.max = 100; range.value = dev.state.brightness || 60;
    range.addEventListener('change', () => debounceCtl(dev, 'brightness', { pct: +range.value }));
    r.appendChild(range);
    card.appendChild(r);
  }
  if (dev.capabilities.color) {
    const r = el('div', 'control-row');
    r.appendChild(el('label', '', 'Color'));
    const color = document.createElement('input');
    color.type = 'color';
    color.value = rgbToHex(dev.state.rgb) || '#ffffff';
    color.addEventListener('change', () => {
      const { r: rr, g, b } = hexToRgb(color.value);
      ctl(dev, 'color', { r: rr, g, b });
    });
    r.appendChild(color);
    if (dev.capabilities.colorTemp) {
      const temp = document.createElement('input');
      temp.type = 'range'; temp.min = 2200; temp.max = 6500; temp.value = dev.state.colorTemp || 4000;
      temp.title = 'White color temperature (K)';
      temp.addEventListener('change', () => debounceCtl(dev, 'colortemp', { kelvin: +temp.value }));
      r.appendChild(temp);
    }
    card.appendChild(r);
  }
  return card;
}

function cameraCard(dev) {
  const card = el('div', 'card');
  card.appendChild(header(dev));

  const view = el('div', 'cam-view');
  const img = document.createElement('img');
  img.alt = dev.name || 'camera';
  img.style.display = 'none';
  const overlay = el('div', 'cam-overlay');
  const ph = el('div', 'placeholder');
  view.append(img, overlay, ph);
  card.appendChild(view);

  let live = false;
  const setLive = (on) => {
    live = on;
    overlay.textContent = on ? '● LIVE  ·  tap to pause' : '▶ tap for live view';
    overlay.classList.toggle('live', on);
  };

  // Load a single snapshot into the thumbnail. Resolves true on success.
  const loadThumb = () =>
    new Promise((resolve) => {
      img.onload = () => { img.style.display = 'block'; overlay.style.display = 'block'; ph.textContent = ''; resolve(true); };
      img.onerror = () => {
        img.style.display = 'none'; overlay.style.display = 'none';
        ph.textContent = 'No preview. Most cameras need a login — tap ⚙ to add one. (RTSP-only cameras can\'t preview in a browser.)';
        resolve(false);
      };
      img.src = `/api/camera/${dev.id}/snapshot?t=` + Date.now();
    });

  const startStream = () => {
    stopStream(dev.id);
    setLive(true);
    const refresh = () => { img.src = `/api/camera/${dev.id}/snapshot?t=` + Date.now(); };
    refresh();
    // Poll JPEG snapshots ~2fps: works everywhere incl. iOS/Android Safari,
    // which cannot render multipart MJPEG streams.
    streamTimers.set(dev.id, setInterval(refresh, 500));
  };
  const toggleLive = () => {
    if (live) { stopStream(dev.id); setLive(false); loadThumb(); }
    else startStream();
  };
  view.addEventListener('click', () => { if (img.style.display !== 'none') toggleLive(); });

  const actions = el('div', 'cam-actions');
  const liveBtn = document.createElement('button');
  liveBtn.textContent = 'Live view';
  liveBtn.addEventListener('click', () => (live ? toggleLive() : startStream()));
  const refreshBtn = document.createElement('button');
  refreshBtn.textContent = 'Refresh';
  refreshBtn.addEventListener('click', () => { stopStream(dev.id); setLive(false); loadThumb(); });
  const gear = document.createElement('button');
  gear.textContent = '⚙';
  gear.title = 'Camera login & stream path';
  actions.append(liveBtn, refreshBtn, gear);
  card.appendChild(actions);

  const creds = el('div', 'creds');
  const userIn = credInput('Username', 'text');
  const passIn = credInput('Password', 'password');
  const pathIn = credInput('Snapshot path (optional, e.g. /snapshot.jpg)', 'text');
  const saveBtn = document.createElement('button');
  saveBtn.textContent = 'Save & load';
  saveBtn.addEventListener('click', async () => {
    await api(`/api/camera/${dev.id}/creds`, jsonBody({ user: userIn.value, pass: passIn.value, path: pathIn.value }));
    setStatus('Saved login for ' + (dev.name || dev.ip));
    creds.classList.remove('open');
    loadThumb();
  });
  const hint = el('div', 'hint', 'Stored in server memory only. Common paths are auto-tried if blank.');
  creds.append(userIn, passIn, pathIn, saveBtn, hint);
  card.appendChild(creds);
  gear.addEventListener('click', () => creds.classList.toggle('open'));

  setLive(false);
  overlay.style.display = 'none';
  ph.textContent = 'Loading preview…';
  loadThumb(); // auto-load thumbnail as soon as the card appears
  return card;
}

function stopStream(id) {
  if (streamTimers.has(id)) { clearInterval(streamTimers.get(id)); streamTimers.delete(id); }
}

// --- control helpers ---
const ctlTimers = new Map();
function debounceCtl(dev, action, body) {
  const key = dev.id + action;
  clearTimeout(ctlTimers.get(key));
  ctlTimers.set(key, setTimeout(() => ctl(dev, action, body), 120));
}
async function ctl(dev, action, body) {
  try { await api(`/api/devices/${dev.id}/${action}`, jsonBody(body)); }
  catch (e) { setStatus('Control failed: ' + e.message); }
}

// --- tiny DOM/util helpers ---
function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}
function credInput(placeholder, type) {
  const i = document.createElement('input');
  i.type = type; i.placeholder = placeholder;
  return i;
}
function jsonBody(obj) {
  return { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(obj) };
}
function hexToRgb(hex) {
  const n = parseInt(hex.slice(1), 16);
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
}
function rgbToHex(rgb) {
  if (!Array.isArray(rgb)) return null;
  return '#' + rgb.map((v) => Math.max(0, Math.min(255, v | 0)).toString(16).padStart(2, '0')).join('');
}

$('#scanBtn').addEventListener('click', scan);

// Load interface info, then kick off a first scan automatically so the user
// just opens the page and sees their devices. The button re-scans any time.
(async () => {
  await loadInterfaces();
  scan();
})();
