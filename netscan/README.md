# netscan — LAN cameras & smart-device controller

Find the **webcams**, **smart switches/plugs**, and **smart lights** on whatever
Wi-Fi/LAN you're connected to, then **view** the cameras and **control** the
switches and lights — all from a web page served by a small local app.

It re-scans automatically for the current network every time you press **Scan
network**, so it works on any network you join.

```
cd netscan
npm start            # or: node server.js
# then open http://127.0.0.1:8137
```

No `npm install` is needed — the app has **zero runtime dependencies** and uses
only the Node.js standard library. Requires Node 18+ (developed on Node 22).

---

## Why this is a local app and not a "pure" website/PWA

This repo already contains a browser PWA (the Receipts OCR app). Your request
**cannot** be built the same way, and it's worth being upfront about why:

A web browser is sandboxed and **physically cannot scan a network**. It can't do
ARP or port scans, can't send the UDP multicast that mDNS/SSDP/ONVIF discovery
requires, and the browser's *Private Network Access* + CORS rules block a public
page from connecting to arbitrary devices on your LAN. Real device discovery and
control therefore needs a process with genuine network access.

`netscan` is that process: a tiny Node HTTP server that runs on your machine,
does the network work, and serves a web UI you open in your browser. Everything
stays on your machine and your LAN — nothing is sent to any cloud.

---

## What it discovers, and how

| Method | Finds | Notes |
|---|---|---|
| **mDNS / Bonjour** | cameras, Shelly, Hue, HomeKit, Chromecast, generic HTTP | UDP 5353 multicast, PTR/SRV/TXT parsing |
| **SSDP / UPnP** | cameras, media & UPnP devices | `M-SEARCH` to 239.255.255.250:1900, fetches device description XML |
| **ONVIF WS-Discovery** | IP cameras | the camera-industry standard, UDP 3702 multicast |
| **TP-Link Kasa** | plugs, switches, dimmers, bulbs | UDP 9999 broadcast, XOR-obfuscated JSON |
| **WiZ** | lights | UDP 38899 broadcast JSON |
| **Shelly** | relays, dimmers, RGBW | HTTP `/shelly` probe (Gen1 + Gen2 RPC) |

"Deep scan" additionally probes every host in your subnet for a Shelly HTTP
endpoint (slower, ~10s, but catches Shellies that don't answer mDNS).

## What it controls

- **Switches / plugs** — on/off (Kasa, Shelly).
- **Lights** — on/off, brightness, RGB color, and white color-temperature where
  the device supports it (Kasa bulbs, WiZ, Shelly RGBW).

Control is direct and local — no vendor cloud account, no internet round-trip.

## Viewing cameras

Cameras are the one area with an unavoidable caveat. The app discovers cameras
and, because a browser can't reach a local camera directly, the **server proxies
the camera's HTTP snapshot / MJPEG stream** back to the page (handling HTTP Basic
and Digest auth). The live view polls JPEG snapshots (~2 fps) for the widest
compatibility.

- Most cameras need a **username/password** — set them with the ⚙ button on the
  camera card. Credentials are held in server memory only.
- If auto-detection of the snapshot URL fails, enter the camera's snapshot/stream
  path in the ⚙ panel (e.g. `/snapshot.jpg`, `/Streaming/channels/1/picture`).
- **RTSP-only cameras** can't be rendered natively by any browser. Discovery
  still lists them with their address; to view an RTSP stream you'd transcode it
  to HLS/MJPEG with a tool like `ffmpeg` (a natural next step if you need it).

---

## Layout

```
netscan/
  server.js            HTTP server, REST API, camera proxy, control routing
  lib/
    net.js             interface / subnet / broadcast helpers
    registry.js        in-memory device registry (merge + dedupe)
    scan.js            runs all discovery methods concurrently
    mdns.js            multicast-DNS query + packet parser
    ssdp.js            SSDP/UPnP M-SEARCH + description fetch
    onvif.js           ONVIF WS-Discovery probe
    kasa.js            TP-Link Kasa discover + control
    wiz.js             WiZ discover + control
    shelly.js          Shelly Gen1/Gen2 discover + control
    camera.js          camera snapshot/MJPEG proxy (Basic + Digest auth)
  public/              web UI (index.html, app.js, styles.css)
```

## HTTP API (used by the UI)

| Method & path | Purpose |
|---|---|
| `GET  /api/interfaces` | active network interfaces |
| `POST /api/scan?deep=0\|1` | run discovery, return devices |
| `GET  /api/devices` | current registry |
| `POST /api/devices/:id/power` | `{ "on": true }` |
| `POST /api/devices/:id/brightness` | `{ "pct": 60 }` |
| `POST /api/devices/:id/color` | `{ "r":255,"g":0,"b":0 }` |
| `POST /api/devices/:id/colortemp` | `{ "kelvin": 4000 }` |
| `POST /api/camera/:id/creds` | `{ "user","pass","path" }` |
| `GET  /api/camera/:id/snapshot` | proxied JPEG |
| `GET  /api/camera/:id/stream` | proxied MJPEG (when supported) |

## Security & scope

Use this only on networks and devices you own or are authorized to manage. By
default the server binds to `127.0.0.1` (localhost only); set `HOST=0.0.0.0` to
expose the UI to your LAN, and `PORT` to change the port. Camera credentials live
in memory for the life of the process and are never written to disk.
