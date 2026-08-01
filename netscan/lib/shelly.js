'use strict';

/**
 * Shelly relays / dimmers / RGBW lights. Local HTTP control, no cloud.
 * Supports both Gen1 (/shelly, /relay/0, /light/0) and Gen2+ RPC
 * (/rpc/Shelly.GetDeviceInfo, /rpc/Switch.Set, /rpc/Light.Set).
 * Discovery is by probing candidate IPs (from mDNS or a subnet sweep) for
 * the always-present unauthenticated GET /shelly endpoint.
 */

const http = require('http');

function httpJson(ip, path, timeoutMs = 1500) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: ip, port: 80, path, timeout: timeoutMs }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        try { resolve({ status: res.statusCode, json: JSON.parse(body) }); }
        catch (_) { resolve({ status: res.statusCode, json: null, body }); }
      });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
  });
}

/** Probe a single IP. Returns a device record or null. */
async function probe(ip) {
  let info;
  try {
    const r = await httpJson(ip, '/shelly');
    if (r.status !== 200 || !r.json) return null;
    info = r.json;
  } catch (_) {
    return null;
  }

  const gen = info.gen || 1;
  if (gen >= 2) return probeGen2(ip, info);
  return probeGen1(ip, info);
}

async function probeGen1(ip, info) {
  const type = (info.type || '').toLowerCase();
  const isLight = type.includes('rgbw') || type.includes('bulb') || type.includes('dimmer') || type.includes('duo');
  let state = {};
  try {
    const s = await httpJson(ip, '/status');
    if (s.json) {
      const relay = (s.json.relays || [])[0];
      const lightState = (s.json.lights || [])[0];
      if (relay) state.on = !!relay.ison;
      if (lightState) {
        state.on = !!lightState.ison;
        state.brightness = lightState.brightness;
        if (lightState.red !== undefined) state.rgb = [lightState.red, lightState.green, lightState.blue];
      }
    }
  } catch (_) {}

  return {
    kind: isLight ? 'light' : 'switch',
    protocol: 'shelly',
    ip,
    port: 80,
    mac: info.mac,
    name: info.name || info.type || 'Shelly',
    vendor: 'Shelly',
    model: info.type,
    capabilities: { power: true, brightness: isLight, color: type.includes('rgbw') },
    state,
    raw: { gen: 1, isLight },
  };
}

async function probeGen2(ip, info) {
  let dinfo = info;
  try {
    const r = await httpJson(ip, '/rpc/Shelly.GetDeviceInfo');
    if (r.json) dinfo = { ...info, ...r.json };
  } catch (_) {}
  const model = (dinfo.model || dinfo.app || '').toLowerCase();
  const isLight = model.includes('rgbw') || model.includes('dimmer') || model.includes('light') || model.includes('bulb');
  let state = {};
  try {
    const key = isLight ? 'light:0' : 'switch:0';
    const st = await httpJson(ip, `/rpc/Shelly.GetStatus`);
    if (st.json && st.json[key]) {
      state.on = !!st.json[key].output;
      if (st.json[key].brightness !== undefined) state.brightness = st.json[key].brightness;
    }
  } catch (_) {}

  return {
    kind: isLight ? 'light' : 'switch',
    protocol: 'shelly',
    ip,
    port: 80,
    mac: dinfo.mac,
    name: dinfo.name || dinfo.id || 'Shelly',
    vendor: 'Shelly',
    model: dinfo.model || dinfo.app,
    capabilities: { power: true, brightness: isLight, color: model.includes('rgbw') },
    state,
    raw: { gen: dinfo.gen || 2, isLight },
  };
}

async function setPower(dev, on) {
  const gen = dev.raw && dev.raw.gen;
  if (gen >= 2) {
    const comp = dev.raw.isLight ? 'Light' : 'Switch';
    return httpJson(dev.ip, `/rpc/${comp}.Set?id=0&on=${on ? 'true' : 'false'}`);
  }
  const path = dev.raw && dev.raw.isLight ? `/light/0?turn=${on ? 'on' : 'off'}` : `/relay/0?turn=${on ? 'on' : 'off'}`;
  return httpJson(dev.ip, path);
}

async function setBrightness(dev, pct) {
  const b = Math.max(0, Math.min(100, Math.round(pct)));
  if (dev.raw && dev.raw.gen >= 2) return httpJson(dev.ip, `/rpc/Light.Set?id=0&on=true&brightness=${b}`);
  return httpJson(dev.ip, `/light/0?turn=on&brightness=${b}`);
}

async function setColor(dev, { r, g, b }) {
  if (dev.raw && dev.raw.gen >= 2) return httpJson(dev.ip, `/rpc/Light.Set?id=0&on=true&rgb=[${r},${g},${b}]`);
  return httpJson(dev.ip, `/light/0?turn=on&red=${r}&green=${g}&blue=${b}&gain=100`);
}

module.exports = { probe, setPower, setBrightness, setColor };
