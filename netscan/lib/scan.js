'use strict';

const net = require('./net');
const kasa = require('./kasa');
const wiz = require('./wiz');
const shelly = require('./shelly');
const ssdp = require('./ssdp');
const onvif = require('./onvif');
const mdns = require('./mdns');

/**
 * Run every discovery method concurrently, then optionally sweep the subnet for
 * Shelly HTTP endpoints. Results are folded into the provided registry.
 *
 * @param {Registry} registry
 * @param {object} opts { deep: boolean, timeoutMs: number, now: number }
 */
async function runScan(registry, opts = {}) {
  const timeoutMs = opts.timeoutMs || 3000;
  const now = opts.now || 0; // caller supplies the timestamp used for lastSeen
  const ifaces = net.ipv4Interfaces();
  const broadcasts = dedupe(ifaces.map((i) => i.broadcast).concat(['255.255.255.255']));

  const results = await Promise.allSettled([
    kasa.discover(broadcasts, timeoutMs),
    wiz.discover(broadcasts, timeoutMs),
    ssdp.discover(timeoutMs),
    onvif.discover(1, timeoutMs),
    mdns.discover(timeoutMs),
  ]);

  const found = [];
  for (const r of results) if (r.status === 'fulfilled') found.push(...r.value);

  // Shelly: probe IPs surfaced by mDNS/SSDP, plus a bounded subnet sweep if deep.
  const candidateIps = new Set(found.map((d) => d.ip).filter(Boolean));
  if (opts.deep) {
    for (const iface of ifaces) for (const h of net.subnetHosts(iface, 256)) candidateIps.add(h);
  }
  const shellyResults = await mapLimit(Array.from(candidateIps), 32, (ip) =>
    shelly.probe(ip).catch(() => null)
  );
  for (const s of shellyResults) if (s) found.push(s);

  const merged = [];
  for (const dev of found) {
    if (!dev || (!dev.ip && !dev.mac)) continue;
    merged.push(registry.upsert(dev, now));
  }
  return {
    interfaces: ifaces,
    scanned: candidateIps.size,
    devices: registry.list(),
  };
}

function dedupe(arr) {
  return Array.from(new Set(arr));
}

/** Run `fn` over items with a concurrency cap. */
async function mapLimit(items, limit, fn) {
  const out = new Array(items.length);
  let idx = 0;
  const workers = new Array(Math.min(limit, items.length || 1)).fill(0).map(async () => {
    while (idx < items.length) {
      const i = idx++;
      out[i] = await fn(items[i], i);
    }
  });
  await Promise.all(workers);
  return out;
}

module.exports = { runScan };
