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
over WebDAV (Synology / QNAP / TrueNAS / Nextcloud). Credentials are built into config.js (or, if the
password is left empty, asked once per browser session and kept in chrome.storage.session).

Files: manifest.json, background.js (opens/focuses the app tab), app.html/app.css/app.js (UI),
lib/webdav.js (XHR-based WebDAV client: PROPFIND/MKCOL/PUT/DELETE with Basic auth),
lib/scan.js (walks dropped folders via webkitGetAsEntry / input[webkitdirectory]),
lib/transfer.js (upload queue: concurrency, retries with exponential back-off, pause/resume/cancel,
skip-existing-by-size resume, post-upload size verification), lib/util.js, config.js.

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

For each finding give: severity (critical/high/medium/low), file:line, what goes wrong, how to reproduce,
and a suggested fix. Do not report style preferences. If you are unsure, say so explicitly.
```
