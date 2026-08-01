'use strict';

/**
 * WiZ smart lights. Plain-JSON UDP protocol on port 38899, no auth. Discovery
 * broadcasts getPilot; control sends setPilot. Colour is direct RGB; whites use
 * `temp` (kelvin). Brightness `dimming` is 10-100.
 */

const dgram = require('dgram');

const PORT = 38899;

function discover(broadcasts, timeoutMs = 2500) {
  return new Promise((resolve) => {
    const byMac = new Map();
    const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    const probe = Buffer.from(JSON.stringify({ method: 'getPilot', params: {} }));

    sock.on('message', (msg, rinfo) => {
      try {
        const res = JSON.parse(msg.toString());
        const r = res && res.result;
        if (!r || r.mac === undefined) return;
        byMac.set(r.mac, toDevice(r, rinfo.address));
      } catch (_) {}
    });
    sock.once('error', () => { try { sock.close(); } catch (_) {} resolve([]); });

    sock.bind(() => {
      try { sock.setBroadcast(true); } catch (_) {}
      for (const b of broadcasts) sock.send(probe, 0, probe.length, PORT, b, () => {});
      setTimeout(() => {
        try { sock.close(); } catch (_) {}
        resolve(Array.from(byMac.values()));
      }, timeoutMs);
    });
  });
}

function toDevice(r, ip) {
  const hasColor = r.r !== undefined || r.g !== undefined || r.b !== undefined;
  return {
    kind: 'light',
    protocol: 'wiz',
    ip,
    port: PORT,
    mac: r.mac,
    name: 'WiZ light',
    vendor: 'WiZ',
    capabilities: { power: true, brightness: true, color: true, colorTemp: true },
    state: {
      on: !!r.state,
      brightness: r.dimming,
      rgb: hasColor ? [r.r || 0, r.g || 0, r.b || 0] : undefined,
      colorTemp: r.temp,
    },
  };
}

function send(ip, method, params, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const sock = dgram.createSocket('udp4');
    const msg = Buffer.from(JSON.stringify({ method, params }));
    const timer = setTimeout(() => { try { sock.close(); } catch (_) {} reject(new Error('WiZ timeout')); }, timeoutMs);
    sock.on('message', (m) => {
      clearTimeout(timer);
      try { sock.close(); } catch (_) {}
      try { resolve(JSON.parse(m.toString())); } catch (e) { reject(e); }
    });
    sock.on('error', (e) => { clearTimeout(timer); reject(e); });
    sock.send(msg, 0, msg.length, PORT, ip, (err) => { if (err) { clearTimeout(timer); reject(err); } });
  });
}

const setPower = (dev, on) => send(dev.ip, 'setPilot', { state: !!on });
const setBrightness = (dev, pct) => send(dev.ip, 'setPilot', { state: true, dimming: Math.max(10, Math.min(100, Math.round(pct))) });
const setColor = (dev, { r, g, b }) => send(dev.ip, 'setPilot', { state: true, r: clamp8(r), g: clamp8(g), b: clamp8(b) });
const setColorTemp = (dev, kelvin) => send(dev.ip, 'setPilot', { state: true, temp: Math.max(2200, Math.min(6500, Math.round(kelvin))) });

function clamp8(v) { return Math.max(0, Math.min(255, Math.round(v || 0))); }

module.exports = { discover, setPower, setBrightness, setColor, setColorTemp };
