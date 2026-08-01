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
  const ph = el('div', 'placeholder', 'Click "Live view". Most cameras need a username/password — set them via ⚙.');
  view.appendChild(ph);
  card.appendChild(view);

  const actions = el('div', 'cam-actions');
  const liveBtn = document.createElement('button');
  liveBtn.textContent = 'Live view';
  const snapBtn = document.createElement('button');
  snapBtn.textContent = 'Snapshot';
  const gear = document.createElement('button');
  gear.textContent = '⚙';
  gear.title = 'Camera credentials & stream path';
  actions.append(liveBtn, snapBtn, gear);
  card.appendChild(actions);

  const creds = el('div', 'creds');
  const userIn = credInput('Username', 'text');
  const passIn = credInput('Password', 'password');
  const pathIn = credInput('Stream/snapshot path (optional, e.g. /snapshot.jpg)', 'text');
  const saveBtn = document.createElement('button');
  saveBtn.textContent = 'Save';
  saveBtn.addEventListener('click', async () => {
    await api(`/api/camera/${dev.id}/creds`, jsonBody({ user: userIn.value, pass: passIn.value, path: pathIn.value }));
    setStatus('Saved credentials for ' + (dev.name || dev.ip));
    creds.classList.remove('open');
  });
  const hint = el('div', 'hint', 'Stored in server memory only. Common paths are auto-tried if left blank. Cameras that only speak RTSP can\'t render directly in a browser — see the README.');
  creds.append(userIn, passIn, pathIn, saveBtn, hint);
  card.appendChild(creds);

  gear.addEventListener('click', () => creds.classList.toggle('open'));

  const startStream = () => {
    stopStream(dev.id);
    view.innerHTML = '';
    const img = document.createElement('img');
    img.alt = 'camera stream';
    img.onerror = () => { view.innerHTML = ''; view.appendChild(el('div', 'placeholder', 'Could not load stream. Check credentials / path (⚙), or the camera may be RTSP-only.')); stopStream(dev.id); };
    view.appendChild(img);
    // Poll snapshots ~2fps for broad compatibility (works even without MJPEG).
    const refresh = () => { img.src = `/api/camera/${dev.id}/snapshot?t=` + Date.now(); };
    refresh();
    streamTimers.set(dev.id, setInterval(refresh, 500));
  };

  liveBtn.addEventListener('click', startStream);
  snapBtn.addEventListener('click', () => {
    stopStream(dev.id);
    view.innerHTML = '';
    const img = document.createElement('img');
    img.onerror = () => { view.innerHTML = ''; view.appendChild(el('div', 'placeholder', 'Snapshot failed. Set credentials / path via ⚙.')); };
    img.src = `/api/camera/${dev.id}/snapshot?t=` + Date.now();
    view.appendChild(img);
  });

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
loadInterfaces();
