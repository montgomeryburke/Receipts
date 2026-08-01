'use strict';

/**
 * TP-Link Kasa (smart plugs, switches, dimmers, bulbs).
 * Local protocol, no cloud/auth required. Payloads are JSON obfuscated with
 * an "autokey" XOR cipher. Discovery is a UDP broadcast on :9999; control is
 * a TCP request on :9999 with a 4-byte big-endian length prefix.
 */

const dgram = require('dgram');
const net = require('net');

const PORT = 9999;
const KEY_INIT = 0xab;

function encrypt(text) {
  const buf = Buffer.from(text, 'utf8');
  const out = Buffer.alloc(buf.length);
  let key = KEY_INIT;
  for (let i = 0; i < buf.length; i++) {
    key = buf[i] ^ key;
    out[i] = key;
  }
  return out;
}

function decrypt(buf) {
  const out = Buffer.alloc(buf.length);
  let key = KEY_INIT;
  for (let i = 0; i < buf.length; i++) {
    const c = buf[i];
    out[i] = c ^ key;
    key = c;
  }
  return out.toString('utf8');
}

const GET_SYSINFO = '{"system":{"get_sysinfo":{}}}';

/**
 * Broadcast a get_sysinfo probe on every provided broadcast address and
 * collect replies for `timeoutMs`.
 */
function discover(broadcasts, timeoutMs = 2500) {
  return new Promise((resolve) => {
    const found = [];
    const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    const payload = encrypt(GET_SYSINFO);

    sock.on('message', (msg, rinfo) => {
      try {
        const info = JSON.parse(decrypt(msg));
        const sys = info && info.system && info.system.get_sysinfo;
        if (sys) found.push(toDevice(sys, rinfo.address));
      } catch (_) {
        /* ignore malformed replies */
      }
    });

    sock.once('error', () => {
      try { sock.close(); } catch (_) {}
      resolve(found);
    });

    sock.bind(() => {
      try { sock.setBroadcast(true); } catch (_) {}
      for (const b of broadcasts) {
        sock.send(payload, 0, payload.length, PORT, b, () => {});
      }
      setTimeout(() => {
        try { sock.close(); } catch (_) {}
        resolve(found);
      }, timeoutMs);
    });
  });
}

function toDevice(sys, ip) {
  // Bulbs report `mic_type`/`is_dimmable`/`is_color`; plugs/switches report `type`.
  const isBulb = sys.mic_type === 'IOT.SMARTBULB' || sys.dev_name?.toLowerCase().includes('bulb');
  const isColor = sys.is_color === 1;
  const isDimmable = sys.is_dimmable === 1 || sys.brightness !== undefined;
  const light = sys.light_state || {};
  const on = isBulb ? light.on_off === 1 : sys.relay_state === 1;

  return {
    kind: isBulb ? 'light' : 'switch',
    protocol: 'kasa',
    ip,
    port: PORT,
    mac: sys.mac || sys.mic_mac,
    name: sys.alias || sys.dev_name || 'Kasa device',
    vendor: 'TP-Link Kasa',
    model: sys.model,
    capabilities: {
      power: true,
      brightness: isDimmable,
      color: isColor,
      colorTemp: isBulb && !!sys.light_state,
    },
    state: {
      on,
      brightness: isBulb ? light.brightness : sys.brightness,
      rgb: isColor && light.hue !== undefined ? hsvToRgb(light.hue, light.saturation, light.brightness) : undefined,
    },
    raw: { childId: null, isBulb },
  };
}

function sendCommand(ip, cmdObj, timeoutMs = 4000) {
  return new Promise((resolve, reject) => {
    const json = JSON.stringify(cmdObj);
    const enc = encrypt(json);
    const framed = Buffer.alloc(4 + enc.length);
    framed.writeUInt32BE(enc.length, 0);
    enc.copy(framed, 4);

    const sock = net.createConnection({ host: ip, port: PORT });
    const chunks = [];
    let expected = null;
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error('Kasa command timeout'));
    }, timeoutMs);

    sock.on('connect', () => sock.write(framed));
    sock.on('data', (d) => {
      chunks.push(d);
      const all = Buffer.concat(chunks);
      if (expected === null && all.length >= 4) expected = all.readUInt32BE(0);
      if (expected !== null && all.length >= 4 + expected) {
        clearTimeout(timer);
        sock.end();
        try {
          resolve(JSON.parse(decrypt(all.slice(4, 4 + expected))));
        } catch (e) {
          reject(e);
        }
      }
    });
    sock.on('error', (e) => { clearTimeout(timer); reject(e); });
  });
}

async function setPower(dev, on) {
  if (dev.raw && dev.raw.isBulb) {
    return sendCommand(dev.ip, {
      'smartlife.iot.smartbulb.lightingservice': {
        transition_light_state: { on_off: on ? 1 : 0, transition_period: 150 },
      },
    });
  }
  return sendCommand(dev.ip, { system: { set_relay_state: { state: on ? 1 : 0 } } });
}

async function setBrightness(dev, pct) {
  const b = Math.max(0, Math.min(100, Math.round(pct)));
  if (dev.raw && dev.raw.isBulb) {
    return sendCommand(dev.ip, {
      'smartlife.iot.smartbulb.lightingservice': {
        transition_light_state: { on_off: 1, brightness: b, transition_period: 150 },
      },
    });
  }
  // Kasa dimmer switch
  return sendCommand(dev.ip, { 'smartlife.iot.dimmer': { set_brightness: { brightness: b } } });
}

async function setColor(dev, { r, g, b }) {
  const { h, s, v } = rgbToHsv(r, g, b);
  return sendCommand(dev.ip, {
    'smartlife.iot.smartbulb.lightingservice': {
      transition_light_state: { on_off: 1, hue: h, saturation: s, brightness: v, color_temp: 0, transition_period: 150 },
    },
  });
}

// --- small color helpers (Kasa uses HSV) ---
function hsvToRgb(h, s, v) {
  s /= 100; v /= 100;
  const c = v * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = v - c;
  let r = 0, g = 0, b = 0;
  if (h < 60) [r, g, b] = [c, x, 0];
  else if (h < 120) [r, g, b] = [x, c, 0];
  else if (h < 180) [r, g, b] = [0, c, x];
  else if (h < 240) [r, g, b] = [0, x, c];
  else if (h < 300) [r, g, b] = [x, 0, c];
  else [r, g, b] = [c, 0, x];
  return [Math.round((r + m) * 255), Math.round((g + m) * 255), Math.round((b + m) * 255)];
}

function rgbToHsv(r, g, b) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const d = max - min;
  let h = 0;
  if (d !== 0) {
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h = Math.round(h * 60);
    if (h < 0) h += 360;
  }
  const s = max === 0 ? 0 : Math.round((d / max) * 100);
  const v = Math.round(max * 100);
  return { h, s, v };
}

module.exports = { discover, setPower, setBrightness, setColor };
