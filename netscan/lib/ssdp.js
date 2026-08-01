'use strict';

/**
 * SSDP / UPnP discovery. Sends an M-SEARCH to the 239.255.255.250:1900
 * multicast group and collects responders, then fetches each device's
 * description XML to extract friendlyName / manufacturer / model and to
 * classify cameras.
 */

const dgram = require('dgram');
const http = require('http');
const { URL } = require('url');

const MCAST_ADDR = '239.255.255.250';
const MCAST_PORT = 1900;

function mSearch(targets = ['ssdp:all'], timeoutMs = 3000) {
  return new Promise((resolve) => {
    const responders = new Map(); // location -> headers
    const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });

    sock.on('message', (msg) => {
      const headers = parseHeaders(msg.toString('utf8'));
      const loc = headers['location'];
      if (loc && !responders.has(loc)) responders.set(loc, headers);
    });
    sock.once('error', () => { try { sock.close(); } catch (_) {} resolve([]); });

    sock.bind(() => {
      try { sock.setBroadcast(true); sock.setMulticastTTL(2); } catch (_) {}
      for (const st of targets) {
        const req = Buffer.from(
          'M-SEARCH * HTTP/1.1\r\n' +
          `HOST: ${MCAST_ADDR}:${MCAST_PORT}\r\n` +
          'MAN: "ssdp:discover"\r\n' +
          'MX: 2\r\n' +
          `ST: ${st}\r\n\r\n`
        );
        sock.send(req, 0, req.length, MCAST_PORT, MCAST_ADDR, () => {});
      }
      setTimeout(() => { try { sock.close(); } catch (_) {} resolve(Array.from(responders.entries())); }, timeoutMs);
    });
  });
}

function parseHeaders(text) {
  const headers = {};
  for (const line of text.split('\r\n')) {
    const idx = line.indexOf(':');
    if (idx > 0) headers[line.slice(0, idx).trim().toLowerCase()] = line.slice(idx + 1).trim();
  }
  return headers;
}

function fetchText(urlStr, timeoutMs = 2000) {
  return new Promise((resolve) => {
    let u;
    try { u = new URL(urlStr); } catch (_) { return resolve(null); }
    const req = http.get({ host: u.hostname, port: u.port || 80, path: u.pathname + u.search, timeout: timeoutMs }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    });
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.on('error', () => resolve(null));
  });
}

function tag(xml, name) {
  const m = xml && xml.match(new RegExp(`<${name}[^>]*>([\\s\\S]*?)</${name}>`, 'i'));
  return m ? m[1].trim() : undefined;
}

async function discover(timeoutMs = 3000) {
  const responders = await mSearch(['ssdp:all', 'urn:schemas-upnp-org:device:Basic:1'], timeoutMs);
  const devices = [];
  await Promise.all(responders.map(async ([location, headers]) => {
    const xml = await fetchText(location);
    const friendly = tag(xml, 'friendlyName');
    const manufacturer = tag(xml, 'manufacturer');
    const model = tag(xml, 'modelName');
    const deviceType = tag(xml, 'deviceType') || headers['st'] || '';
    let host;
    try { host = new URL(location).hostname; } catch (_) { host = undefined; }

    const hay = `${deviceType} ${model} ${friendly} ${headers['server'] || ''}`.toLowerCase();
    const looksCamera = /camera|ipcam|webcam|nvr|dvr|onvif|axis|hikvision|dahua|reolink|amcrest|foscam|wyze/.test(hay);

    devices.push({
      kind: looksCamera ? 'camera' : 'other',
      protocol: 'ssdp',
      ip: host,
      name: friendly || model || deviceType || 'UPnP device',
      vendor: manufacturer,
      model,
      capabilities: { stream: looksCamera },
      raw: { location, deviceType, server: headers['server'] },
    });
  }));
  return devices;
}

module.exports = { discover };
