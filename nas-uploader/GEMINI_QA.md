# Independent QA review with Google Gemini

This build was tested automatically in Chromium against real WebDAV servers (see `tests/`). To get a
second opinion from Gemini:

1. Download `nas-uploader-extension.zip` (or the `extension/` folder) from this repository.
2. Open https://gemini.google.com, attach the zip (or the individual `.js`, `.html`, `.css` and `manifest.json`
   files), and paste the prompt below.
3. If Gemini reports a problem, paste its finding back to Claude and ask for it to be checked and fixed.
   Treat findings as claims to verify, not facts.

---

## Prompt to paste into Gemini

```
You are a senior QA engineer reviewing a Chrome extension (Manifest V3) called "NAS Uploader".
Purpose: from a computer where only Chrome is available, the user drags and drops complete nested folder
structures (potentially tens of thousands of files and multi-GB files) and uploads them to their home NAS
over WebDAV (their NAS is a Proxmox container on an HP machine, also used by Jellyfin). Credentials are built into config.js (or, if the
password is left empty, asked once per browser session and kept in chrome.storage.session).

Files: manifest.json, background.js (opens/focuses the app tab), app.html/app.css/app.js (UI),
lib/webdav.js (XHR-based WebDAV client: PROPFIND/MKCOL/PUT/MOVE/DELETE with Basic auth),
lib/scan.js (walks dropped folders via webkitGetAsEntry, input[webkitdirectory] and FileSystemDirectoryHandle),
lib/transfer.js (queue: concurrency, retries with exponential back-off, pause/resume/cancel, auto-pause when the
NAS is unreachable, skip-existing resume, server-side moves with upload fallback, deletions deferred to the end,
post-upload size verification), lib/mirror.js (one-way mirror: remote tree listing, manifest of local
size+mtime, change/rename/deletion planning, Jellyfin/Kodi metadata protection, mass-deletion safety checks),
lib/store.js (saved mirrors with folder handles in IndexedDB), lib/util.js, config.js.

Also review server/setup-webdav.sh: a bash script run as root inside a Proxmox LXC (Debian/Ubuntu) that installs
Apache mod_dav for the folder Jellyfin uses, fixes permissions (runs Apache as the folder owner, or grants
www-data access via ACLs/group), and exposes it via Tailscale Funnel, port-forward + DuckDNS + Let's Encrypt, or
LAN-only self-signed HTTPS.

Please review for, and report concrete findings with file + line + a reproduction scenario:
1. Correctness bugs: path encoding (#, %, ?, unicode, emoji, leading spaces), href parsing of PROPFIND
   responses from different servers, directory creation order, race conditions in the queue
   (pause/resume/cancel/retry while uploads or verification are in flight), progress/ETA math.
2. Large-scale behaviour: 100k+ files, 50 GB+ files, very deep trees, memory use, UI responsiveness,
   behaviour when the tab is in the background, laptop sleep, network loss and recovery.
3. Error handling: 401/403/404/405/409/413/423/507, timeouts, dropped connections, self-signed certificates,
   servers that answer MKCOL for existing folders with unusual status codes.
4. Security: credential handling, XSS via file names (all UI text must use textContent), permissions in
   manifest.json, anything that could leak the password.
5. Chrome/MV3 compatibility issues (CSP, service worker lifecycle, chrome.downloads headers, chrome.power,
   chrome.storage.session, chrome.runtime.getContexts).
6. UX problems a non-technical user would hit.
7. Mirror correctness: could a mirror ever delete something it shouldn't (wrong folder picked, unicode
   normalisation, case differences, interrupted runs, stale manifest, files Jellyfin writes next to media)?
   Could it miss a change it should send?
8. Setup script: idempotency, security of the Apache config (auth, no script execution), permission handling
   in privileged/unprivileged containers, failure modes.

For each finding give: severity (critical/high/medium/low), file:line, what goes wrong, how to reproduce,
and a suggested fix. Do not report style preferences. If you are unsure, say so explicitly.
```
