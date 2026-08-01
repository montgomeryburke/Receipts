'use strict';

const os = require('os');

/**
 * Return the usable IPv4 interfaces (non-internal) with computed
 * broadcast addresses and /24-style subnet host lists.
 */
function ipv4Interfaces() {
  const out = [];
  const ifaces = os.networkInterfaces();
  for (const [name, addrs] of Object.entries(ifaces)) {
    for (const a of addrs || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      out.push({
        name,
        address: a.address,
        netmask: a.netmask,
        broadcast: broadcastAddress(a.address, a.netmask),
        cidr: a.cidr,
      });
    }
  }
  return out;
}

function ipToInt(ip) {
  return ip.split('.').reduce((acc, oct) => ((acc << 8) + (parseInt(oct, 10) & 255)) >>> 0, 0) >>> 0;
}

function intToIp(int) {
  return [(int >>> 24) & 255, (int >>> 16) & 255, (int >>> 8) & 255, int & 255].join('.');
}

function broadcastAddress(ip, mask) {
  const ipInt = ipToInt(ip);
  const maskInt = ipToInt(mask);
  const bcast = (ipInt | (~maskInt >>> 0)) >>> 0;
  return intToIp(bcast);
}

/**
 * Enumerate host addresses in the interface's subnet, capped so we never
 * try to walk anything larger than a /22 (1024 hosts) which would be slow
 * and noisy. Excludes the network and broadcast addresses.
 */
function subnetHosts(iface, maxHosts = 512) {
  const ipInt = ipToInt(iface.address);
  const maskInt = ipToInt(iface.netmask);
  const network = (ipInt & maskInt) >>> 0;
  const broadcast = (network | (~maskInt >>> 0)) >>> 0;
  const total = broadcast - network - 1;
  if (total <= 0) return [];
  const count = Math.min(total, maxHosts);
  const hosts = [];
  for (let i = 1; i <= count; i++) {
    hosts.push(intToIp((network + i) >>> 0));
  }
  return hosts;
}

module.exports = { ipv4Interfaces, subnetHosts, ipToInt, intToIp, broadcastAddress };
