# Security notes

Your NAS holds your files and is reachable from the internet. This is what
protects it, and — just as importantly — what does not.

## What protects your files

**Tailscale (the default).** Your Pi joins a private encrypted network made of
only your own devices. The NAS has no public address at all. Someone scanning
the internet cannot find it, cannot connect to it, and cannot attack it. This
is the single biggest protection in the setup.

**Access tokens.** Every request needs a 256-bit random bearer token. Tokens
are stored on the Pi only as SHA-256 digests, so someone who reads
`tokens.json` still cannot make a valid request. Revocation takes effect on the
next request — no restart, no window.

**Path containment.** Every path from a client is normalised, stripped of `..`,
and resolved through symlinks before being checked against the share root.
A request for `../../../../etc/passwd` is rejected, and so is a symlink inside
the share pointing outside it. This is `storage.resolve()` and it is the piece
that is tested hardest.

**Browser origin checks.** The API answers cross-origin requests only from
Chrome extensions (optionally only *your* extension ID) and any origins you
list explicitly. A malicious web page you happen to visit cannot make your
browser talk to your NAS, even though your browser can reach it.

**A locked-down service account.** `pi-nas` runs as its own user with no login
shell and no capabilities, under systemd hardening that makes the entire
filesystem read-only except the share itself. A total compromise of the file
server still cannot write to `/etc`, load a kernel module, or become root.

**Download tickets.** Browsers cannot attach an auth header to a download, so
downloads use a ticket that is random, single-use, expires in two minutes, and
works for exactly one file. Your real token never appears in a URL, browser
history, or server log.

## What does not protect your files

**The token is a bearer credential.** Anyone holding it is you. Do not paste it
into a chat, an issue, or a screenshot. If you do, revoke it:

```bash
sudo pi-nas-token revoke <name>
sudo pi-nas-token add <name>
```

**`--funnel` removes the biggest protection.** It publishes the NAS to the
whole internet, leaving the token as the only barrier. Use it only if you truly
cannot install Tailscale on the client, and prefer a read-only token if you do.

**There is no encryption at rest.** Someone who physically steals the USB drive
reads everything on it. If that matters, use LUKS — note that an encrypted
drive cannot auto-mount unattended after a power cut.

**There is no ransomware protection.** A token with write access can delete
everything. Keep a backup that the Pi cannot reach; a NAS is not a backup.

## The voice assistant

Your microphone audio is transcribed **on the Pi** by Whisper and never sent to
Anthropic. What *is* sent is the resulting text, plus the names and states of
the devices you explicitly exposed.

Claude can only touch devices you list under **Settings → Voice assistants →
Expose**. Nothing is exposed by default. It acts through Home Assistant's own
permission-checked tool API, not by touching devices directly.

Your Anthropic API key is stored in Home Assistant's config directory. Anyone
with admin access to Home Assistant, or with the SD card, can read it.

## Reasonable hygiene

- One token per device, named for that device, so a single loss is contained
- Read-only tokens for anything that only needs to read
- `sudo apt update && sudo apt full-upgrade` every so often
- `cd /opt/homeassistant && sudo docker compose pull && sudo docker compose up -d`
- Back the drive up somewhere the Pi cannot write to
