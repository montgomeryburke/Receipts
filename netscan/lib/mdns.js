'use strict';

/**
 * Minimal multicast-DNS (Bonjour) discovery with zero dependencies. Sends PTR
 * queries for a set of common service types to 224.0.0.251:5353 and parses the
 * PTR/SRV/TXT/A records that come back, correlating them into device records.
 * Handles DNS name compression pointers.
 */

const dgram = require('dgram');

const MCAST_ADDR = '224.0.0.251';
const MCAST_PORT = 5353;

// Service type -> how we should classify a responder.
const SERVICES = {
  '_rtsp._tcp.local': 'camera',
  '_onvif._tcp.local': 'camera',
  '_axis-video._tcp.local': 'camera',
  '_dahua._tcp.local': 'camera',
  '_shelly._tcp.local': 'switch',
  '_hue._tcp.local': 'light',
  '_hap._tcp.local': 'other', // HomeKit accessories (could be any type)
  '_googlecast._tcp.local': 'other',
  '_http._tcp.local': 'other',
  '_https._tcp.local': 'other',
};

function encodeName(name) {
  const parts = name.replace(/\.$/, '').split('.');
  const bufs = parts.map((p) => {
    const b = Buffer.from(p, 'utf8');
    return Buffer.concat([Buffer.from([b.length]), b]);
  });
  return Buffer.concat([...bufs, Buffer.from([0])]);
}

function encodeQuery(names) {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(0, 0); // id
  header.writeUInt16BE(0, 2); // flags: standard query
  header.writeUInt16BE(names.length, 4); // qdcount
  const questions = names.map((n) => {
    const nameBuf = encodeName(n);
    const tail = Buffer.alloc(4);
    tail.writeUInt16BE(12, 0); // QTYPE = PTR
    tail.writeUInt16BE(1, 2); // QCLASS = IN
    return Buffer.concat([nameBuf, tail]);
  });
  return Buffer.concat([header, ...questions]);
}

function decodeName(buf, offset) {
  const labels = [];
  let jumped = false;
  let pos = offset;
  let safety = 0;
  let next = offset;
  while (safety++ < 128) {
    const len = buf[pos];
    if (len === undefined) break;
    if (len === 0) { if (!jumped) next = pos + 1; break; }
    if ((len & 0xc0) === 0xc0) {
      const ptr = ((len & 0x3f) << 8) | buf[pos + 1];
      if (!jumped) next = pos + 2;
      jumped = true;
      pos = ptr;
      continue;
    }
    labels.push(buf.slice(pos + 1, pos + 1 + len).toString('utf8'));
    pos += 1 + len;
  }
  return { name: labels.join('.'), next };
}

function parseRecords(buf) {
  const records = [];
  if (buf.length < 12) return records;
  const qd = buf.readUInt16BE(4);
  const an = buf.readUInt16BE(6);
  const ns = buf.readUInt16BE(8);
  const ar = buf.readUInt16BE(10);
  let pos = 12;
  // skip questions
  for (let i = 0; i < qd; i++) {
    const { next } = decodeName(buf, pos);
    pos = next + 4;
  }
  const totalRR = an + ns + ar;
  for (let i = 0; i < totalRR; i++) {
    if (pos >= buf.length) break;
    const { name, next } = decodeName(buf, pos);
    pos = next;
    if (pos + 10 > buf.length) break;
    const type = buf.readUInt16BE(pos);
    const rdlength = buf.readUInt16BE(pos + 8);
    pos += 10;
    const rdata = buf.slice(pos, pos + rdlength);
    const rec = { name, type };
    if (type === 12) rec.ptr = decodeName(buf, pos).name; // PTR
    else if (type === 33) { // SRV
      rec.port = rdata.readUInt16BE(4);
      rec.target = decodeName(buf, pos + 6).name;
    } else if (type === 1 && rdlength === 4) rec.a = `${rdata[0]}.${rdata[1]}.${rdata[2]}.${rdata[3]}`; // A
    else if (type === 16) rec.txt = parseTxt(rdata); // TXT
    records.push(rec);
    pos += rdlength;
  }
  return records;
}

function parseTxt(rdata) {
  const out = {};
  let i = 0;
  while (i < rdata.length) {
    const len = rdata[i++];
    if (!len) continue;
    const kv = rdata.slice(i, i + len).toString('utf8');
    i += len;
    const eq = kv.indexOf('=');
    if (eq > 0) out[kv.slice(0, eq)] = kv.slice(eq + 1);
  }
  return out;
}

function discover(timeoutMs = 3000) {
  return new Promise((resolve) => {
    const query = encodeQuery(Object.keys(SERVICES));
    const ptrs = [];   // {service, instance}
    const srv = new Map(); // instance -> {port, target}
    const aRecs = new Map(); // hostname -> ip
    const txtRecs = new Map(); // instance -> txt

    const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    sock.on('message', (msg) => {
      for (const rec of parseRecords(msg)) {
        if (rec.type === 12 && rec.ptr) {
          const svc = Object.keys(SERVICES).find((s) => rec.name.startsWith(s));
          if (svc) ptrs.push({ service: svc, instance: rec.ptr });
        } else if (rec.type === 33) {
          srv.set(rec.name, { port: rec.port, target: rec.target });
        } else if (rec.type === 1) {
          aRecs.set(rec.name, rec.a);
        } else if (rec.type === 16) {
          txtRecs.set(rec.name, rec.txt);
        }
      }
    });
    sock.once('error', () => { try { sock.close(); } catch (_) {} resolve([]); });

    sock.bind(MCAST_PORT >= 0 ? 0 : undefined, () => {
      try { sock.setMulticastTTL(255); } catch (_) {}
      sock.send(query, 0, query.length, MCAST_PORT, MCAST_ADDR, () => {});
      setTimeout(() => {
        try { sock.close(); } catch (_) {}
        resolve(assemble(ptrs, srv, aRecs, txtRecs));
      }, timeoutMs);
    });
  });
}

function assemble(ptrs, srv, aRecs, txtRecs) {
  const devices = [];
  const seen = new Set();
  for (const { service, instance } of ptrs) {
    if (seen.has(instance)) continue;
    seen.add(instance);
    const s = srv.get(instance);
    const ip = s ? aRecs.get(s.target) : undefined;
    const txt = txtRecs.get(instance) || {};
    const label = instance.split('.')[0].replace(/\\032/g, ' ');
    devices.push({
      kind: SERVICES[service] || 'other',
      protocol: 'mdns',
      ip,
      port: s && s.port,
      name: txt.fn || txt.md || label || 'mDNS device',
      vendor: txt.vendor || txt.manufacturer,
      model: txt.md || txt.model,
      capabilities: { stream: SERVICES[service] === 'camera' },
      raw: { service, instance, target: s && s.target, txt },
    });
  }
  return devices;
}

// parseRecords/assemble exposed for offline unit testing of the packet parser.
module.exports = { discover, SERVICES, _parseRecords: parseRecords, _assemble: assemble };
