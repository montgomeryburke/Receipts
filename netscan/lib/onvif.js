'use strict';

/**
 * ONVIF WS-Discovery. The standard way IP cameras announce themselves:
 * a SOAP "Probe" sent to the 239.255.255.250:3702 multicast group. Cameras
 * reply with ProbeMatches containing their service XAddrs plus scopes that
 * usually include name / hardware / location hints.
 *
 * WS-Discovery gives us the camera and its ONVIF service URL. Pulling an
 * actual snapshot/stream URI needs an authenticated GetSnapshotUri call, so
 * that is deferred to the camera-proxy layer where the user supplies creds.
 */

const dgram = require('dgram');
const { URL } = require('url');

const MCAST_ADDR = '239.255.255.250';
const MCAST_PORT = 3702;

// The Probe takes a caller-supplied MessageID so the packet is deterministic.
const PROBE = (msgId) =>
  '<?xml version="1.0" encoding="UTF-8"?>' +
  '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" ' +
  'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" ' +
  'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" ' +
  'xmlns:dn="http://www.onvif.org/ver10/network/wsdl">' +
  '<e:Header>' +
  `<w:MessageID>uuid:${msgId}</w:MessageID>` +
  '<w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>' +
  '<w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>' +
  '</e:Header>' +
  '<e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body>' +
  '</e:Envelope>';

function discover(seed = 1, timeoutMs = 3000) {
  return new Promise((resolve) => {
    const byAddr = new Map();
    const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });

    sock.on('message', (msg) => {
      const xml = msg.toString('utf8');
      if (!/ProbeMatch/i.test(xml)) return;
      const xaddrs = (match(xml, 'XAddrs') || '').split(/\s+/).filter(Boolean);
      const scopes = match(xml, 'Scopes') || '';
      let ip, serviceUrl;
      for (const x of xaddrs) {
        try { ip = new URL(x).hostname; serviceUrl = x; break; } catch (_) {}
      }
      if (!ip) return;
      byAddr.set(ip, {
        kind: 'camera',
        protocol: 'onvif',
        ip,
        name: scopeValue(scopes, 'name') || 'ONVIF camera',
        vendor: scopeValue(scopes, 'hardware') || scopeValue(scopes, 'mfr'),
        model: scopeValue(scopes, 'hardware'),
        capabilities: { stream: true },
        raw: { serviceUrl, scopes },
      });
    });
    sock.once('error', () => { try { sock.close(); } catch (_) {} resolve([]); });

    sock.bind(() => {
      try { sock.setMulticastTTL(2); } catch (_) {}
      // Deterministic pseudo-uuid derived from the seed; a stable id is fine here.
      const msgId = `4b2a0000-0000-4000-8000-${String(1e11 + seed).slice(-12)}`;
      const buf = Buffer.from(PROBE(msgId));
      sock.send(buf, 0, buf.length, MCAST_PORT, MCAST_ADDR, () => {});
      setTimeout(() => { try { sock.close(); } catch (_) {} resolve(Array.from(byAddr.values())); }, timeoutMs);
    });
  });
}

function match(xml, local) {
  const m = xml.match(new RegExp(`<[^>]*:?${local}[^>]*>([\\s\\S]*?)</[^>]*:?${local}>`, 'i'));
  return m ? m[1].trim() : undefined;
}

// ONVIF scopes look like: onvif://www.onvif.org/name/FrontDoor
function scopeValue(scopes, key) {
  const re = new RegExp(`onvif://www\\.onvif\\.org/${key}/([^\\s]+)`, 'i');
  const m = scopes.match(re);
  return m ? decodeURIComponent(m[1]) : undefined;
}

module.exports = { discover };
