# Raspberry Pi: private NAS + Claude voice assistant

Turns one Raspberry Pi into two things:

1. **A private NAS** — the USB drive plugged into the Pi, reachable from
   anywhere in the world through a Chrome extension that only you can use.
   Built to be the file store for Claude projects.
2. **A Claude voice assistant** — Home Assistant with Claude as the
   conversation agent, so you can talk to your house and it can talk back.

Speech recognition, speech synthesis, and wake-word detection all run **on the
Pi**. Microphone audio never leaves your house.

---

## What you need

- Raspberry Pi 4 or 5 (4 GB minimum, 8 GB better) running Raspberry Pi OS
  (64-bit Bookworm or newer)
- A USB drive
- An Anthropic API key from [console.anthropic.com](https://console.anthropic.com)
  (only for the voice assistant — the NAS does not need one)
- Google Chrome on the computers you want file access from

---

## Install

Plug in the USB drive, then on the Pi run:

```bash
curl -fsSL https://raw.githubusercontent.com/montgomeryburke/Receipts/claude/pi-nas-home-assistant-8ed8tw/pi/install.sh | sudo bash
```

It takes 15–30 minutes, mostly downloading. It will:

- find and mount your USB drive at `/srv/nas`, keyed by UUID so it survives
  reboots and gets remounted in the same place no matter which port you use
- install the file server as a hardened systemd service
- set up Tailscale so the NAS is reachable from outside without opening a
  single port on your router
- install Home Assistant with local speech and the Claude agent
- print your access token — **copy it, it is shown exactly once**

Useful flags (`... | sudo bash -s -- --skip-ha`):

| Flag | Effect |
|---|---|
| `--skip-ha` | NAS only, no Home Assistant |
| `--skip-nas` | Home Assistant only |
| `--format-usb` | **Erases** the USB drive and makes a fresh ext4 filesystem |
| `--funnel` | Publish the NAS to the public internet, not just your own devices |
| `--skip-remote` | Skip Tailscale; local network access only |

The installer never formats anything unless you pass `--format-usb` *and* type
`ERASE` at the prompt.

---

## The Chrome extension

1. On your laptop, clone this repo (or copy the `pi/extension` folder to it).
2. Go to `chrome://extensions`, turn on **Developer mode** (top right).
3. Click **Load unpacked** and select the `pi/extension` folder.
4. Click the extension's **Details → Extension options**.
5. Paste the NAS address and the access token from the installer, then
   **Connect and save**.

You can now browse, upload, download, rename, delete, and make folders. Drag
files or whole folders onto the popup to upload them.

### Locking it to just your extension

The extension's settings page shows its own ID. To refuse every other
extension, put that ID on the Pi in `/etc/pi-nas/config.env`:

```
PI_NAS_ALLOWED_EXTENSION_IDS=your_extension_id_here
```

then `sudo systemctl restart pi-nas`.

---

## Getting to your files from anywhere

The installer uses **Tailscale**, which builds an encrypted private network
between your own devices. Nothing is exposed to the public internet.

Install Tailscale on your laptop and phone, sign in with the same account, and
your NAS address works from anywhere — a hotel, a café, another country.

If you would rather not install anything on the client side, rerun with
`--funnel` and the NAS gets a public HTTPS address instead. Understand the
trade: anyone on the internet can then reach the URL, and your access token
becomes the only thing protecting your files. Tailscale is the better default.

Port forwarding on your router is deliberately not offered — it puts a
self-hosted service straight onto the public internet with your home IP
attached.

---

## The voice assistant

After the installer finishes, open `http://<pi-ip>:8123`:

1. Create your Home Assistant account.
2. **Settings → Devices & Services → Add Integration → "Claude Assist"**,
   paste your Anthropic API key.
3. **Settings → Voice assistants → Add assistant**:
   - Conversation agent: **Claude Assist**
   - Speech-to-text: **faster-whisper**
   - Text-to-speech: **piper**
   - Wake word: **openWakeWord**
4. **Settings → Voice assistants → Expose** — pick exactly which devices Claude
   can see and control. Nothing is exposed until you choose it.

To talk to it you need a microphone. Options, cheapest first: the Home
Assistant app on a phone or tablet, an ESPHome voice satellite (~$15 in parts),
or an official Home Assistant Voice Preview Edition.

### Why it beats a Google Home

- It answers general questions properly, not just "here's what I found on the web"
- It follows multi-step requests: *"turn off everything downstairs except the
  hallway light, and set the thermostat to 19"* is one sentence, one action
- It asks a clarifying question instead of guessing wrong
- You can rewrite its personality and rules in plain English in the integration
  options
- Your voice recordings are processed on your own hardware

### Tuning speed vs. depth

In the integration options, **Thinking effort** trades latency for
thoroughness. It defaults to `low`, which is right for "turn on the lights".
Raise it if you ask harder questions.

Thinking is deliberately never turned off. On this model family, disabling it
can make Claude *describe* a tool call in text instead of actually making one —
so it would say it turned the light on without having done it.

---

## Everyday commands

```bash
sudo systemctl status pi-nas        # is the file server healthy?
sudo journalctl -u pi-nas -f        # live logs
sudo pi-nas-token list              # what tokens exist
sudo pi-nas-token add work-laptop   # mint another
sudo pi-nas-token add phone --read-only
sudo pi-nas-token revoke phone      # instant, no restart needed
df -h /srv/nas                      # free space

cd /opt/homeassistant
sudo docker compose ps              # voice stack status
sudo docker compose logs -f homeassistant
sudo docker compose pull && sudo docker compose up -d   # update
```

---

## Layout

```
pi/
├── install.sh                  one-command setup
├── nas/
│   ├── app/                    the file server (FastAPI)
│   │   ├── main.py             routes
│   │   ├── storage.py          path containment — the security-critical part
│   │   ├── auth.py             hashed bearer tokens
│   │   └── config.py           environment configuration
│   ├── tests/                  44 tests, mostly attack cases
│   ├── scripts/                USB mount, remote access, token CLI
│   └── systemd/pi-nas.service  hardened unit file
├── extension/                  the Chrome extension (Manifest V3)
├── homeassistant/
│   ├── docker-compose.yml      HA + whisper + piper + openwakeword
│   └── custom_components/claude_assist/   the Claude conversation agent
├── scripts/fix-keyring.sh      stops the Pi OS keyring popup
└── docs/                       security notes and troubleshooting
```

## More

- [docs/security.md](docs/security.md) — what protects your files, and what does not
- [docs/troubleshooting.md](docs/troubleshooting.md) — including the keyring popup
