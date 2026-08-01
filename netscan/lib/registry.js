'use strict';

/**
 * In-memory registry of discovered devices. Devices are keyed by a stable
 * identity (mac when known, otherwise ip:protocol) so repeated scans merge
 * rather than duplicate, and so control endpoints can look a device up by id.
 *
 * A device record looks like:
 * {
 *   id, kind: 'camera'|'switch'|'light'|'other',
 *   name, vendor, model, ip, port, mac,
 *   protocol: 'kasa'|'wiz'|'shelly'|'onvif'|'ssdp'|'mdns'|'lifx',
 *   capabilities: { power, brightness, color, colorTemp, stream },
 *   state: { on, brightness, rgb, ... },
 *   raw: <protocol-specific blob>,
 *   lastSeen: <ms epoch, stamped by caller>
 * }
 */
class Registry {
  constructor() {
    this.devices = new Map();
  }

  keyFor(dev) {
    if (dev.mac) return `mac:${String(dev.mac).toLowerCase().replace(/[^a-f0-9]/g, '')}`;
    return `net:${dev.ip}:${dev.protocol}`;
  }

  upsert(dev, now) {
    const key = this.keyFor(dev);
    const existing = this.devices.get(key);
    if (existing) {
      // Merge: newer non-empty fields win, capabilities/state shallow-merge.
      const merged = { ...existing, ...clean(dev) };
      merged.capabilities = { ...existing.capabilities, ...(dev.capabilities || {}) };
      merged.state = { ...existing.state, ...(dev.state || {}) };
      merged.id = existing.id;
      merged.lastSeen = now;
      this.devices.set(key, merged);
      return merged;
    }
    const id = key.replace(/[^a-z0-9]/gi, '').slice(0, 24) + '-' + shortHash(key);
    const record = {
      id,
      kind: dev.kind || 'other',
      capabilities: dev.capabilities || {},
      state: dev.state || {},
      ...clean(dev),
      lastSeen: now,
    };
    record.id = id;
    this.devices.set(key, record);
    return record;
  }

  get(id) {
    for (const dev of this.devices.values()) {
      if (dev.id === id) return dev;
    }
    return null;
  }

  list() {
    return Array.from(this.devices.values()).sort((a, b) => {
      const order = { camera: 0, switch: 1, light: 2, other: 3 };
      if (order[a.kind] !== order[b.kind]) return order[a.kind] - order[b.kind];
      return (a.name || a.ip || '').localeCompare(b.name || b.ip || '');
    });
  }
}

function clean(obj) {
  const out = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null || v === '') continue;
    out[k] = v;
  }
  return out;
}

function shortHash(str) {
  let h = 5381;
  for (let i = 0; i < str.length; i++) h = ((h << 5) + h + str.charCodeAt(i)) >>> 0;
  return h.toString(36);
}

module.exports = { Registry };
