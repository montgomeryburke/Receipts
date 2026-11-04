# Independent QA review with Google Gemini

This build was tested automatically in Chromium: against real WebDAV servers, with mock Claude/Gemini servers, real
audio through the meeting window, real Whisper speech recognition and real OCR (see `tests/` and the README). To
get a second opinion from Gemini:

1. Get `nas-uploader-review-bundle.txt`: one text file with all the extension code (except third-party libraries
   in `vendor/`), the server setup script and the OCR script. Regenerate it any time with `./build-review-bundle.sh`.
2. Open https://gemini.google.com (a model with a long context, e.g. Gemini Pro), attach that file, and paste the
   prompt below.
3. Paste Gemini's findings back to Claude and ask for each to be checked and fixed. Treat findings as claims to
   verify, not facts.

---

## Prompt to paste into Gemini

```
You are a senior QA engineer and security reviewer. The attached file is the complete source of a Chrome
extension (Manifest V3) called "Project Assistant", plus two server scripts. Review it as code that one person
will rely on every working day. Report only real problems, with evidence.

What it does:
1. NAS files (app.html, app.js, lib/webdav.js, lib/scan.js, lib/transfer.js, lib/mirror.js, lib/store.js):
   upload whole folder trees and one-way MIRROR project folders from a locked-down work computer to the user's
   home NAS over WebDAV (Apache mod_dav in a Proxmox container on an HP machine, also used by Jellyfin).
   Credentials are in config.js. Mirror sends only changes (size+mtime manifest), renames as server-side MOVE,
   deletions after review, Jellyfin metadata protection.
2. One fileset: those mirrors are the "project folders" (lib/folders.js). The offscreen engine (engine.js)
   indexes them locally (lib/indexer.js, lib/index.js BM25 in IndexedDB, lib/extract.js with pdf.js) under their
   NAS paths. An OCR index of scanned PDFs is built on the NAS by server/assistant-ocr-index.py and applied.
3. Email drafts (content/outlook.js on Outlook on the web, lib/assistant.js, lib/teach.js, lib/automate.js):
   reads the open email, retrieves excerpts locally, one structured AI call, draft with sources; Power Automate
   flows as read/write "actions" (HTTP trigger or OneDrive bridge folder).
4. Meeting assistant (meeting.html/js, lib/audio.js, lib/audio-worklet.js, lib/stt.js, lib/whisper-worker.js,
   lib/meeting-ai.js, lib/localai.js): captures Teams audio (getDisplayMedia with system/tab audio) and the mic,
   level meters, segments speech at pauses, transcribes with Whisper in a worker (transformers.js/ONNX WASM) or
   Gemini, decides locally when a prompt is worth an API call, prompts with quotes from local excerpts, optional
   web look-up of standards, private typed questions, Document Picture-in-Picture pop-out, autosaves the
   transcript to the NAS, end-of-meeting summary that is stored as per-project memory (lib/memory.js).
5. Recorder (recorder.html/js, lib/recorder.js): toggles to record the computer's sound (getDisplayMedia with system
   audio) or the screen with sound, mic mixed in via Web Audio, MediaRecorder written as it records to a chosen
   folder (File System Access) or via OPFS to chrome.downloads.
6. Desktop Outlook and archives: "From copied email" parses a copied Outlook message (lib/text.js
   parseCopiedEmail); server/assistant-ocr-index.py also unpacks .pst (readpst) and .msg (msgconvert) into one
   entry per email and extracts full text for NAS-only folders (standards copied from Google Drive by
   server/setup-drive-copy.sh with rclone and a service account).
7. Chat (lib/chat.js, sidepanel.js): the user tells the extension what to change; the AI (Claude via the
   official Anthropic SDK in lib/llm.js, or Gemini function calling) changes settings, standing instructions,
   document rules, project memory, folder options and Power Automate actions through validated tools, with an
   undo log; it helps set up Power Automate flows and records code change requests on the NAS.
8. server/setup-webdav.sh (run as root in the Proxmox LXC): Apache WebDAV, permissions, DuckDNS + Let's Encrypt,
   fail2ban, unattended upgrades, the OCR systemd timer and a copy of the speech model.
9. Accuracy (lib/crosscheck.js): with both keys the other AI reviews drafts (lib/assistant.js checkDraft, one
   revision), meeting prompts/answers/summaries (lib/meeting-ai.js checkResult, summarize) and the agent's
   results; standards looked up by both (dualLookUp); free local checks of quotes (quoteFound) and numbers
   (numbersIn, unsupportedNumbers); "both" transcription (lib/stt.js) compares numbers heard by Gemini and Whisper.
10. Kill switch and spending limit (lib/llm.js aiGate, track, stopAllAI/resumeAI, recordSpend): Stop AI must cancel
   every Claude/Gemini call in every page (side panel, offscreen engine, meeting, agent) and refuse new ones.
11. Browser agent (agent.html/js, lib/agent.js, lib/browser.js): drives a tab through chrome.debugger (CDP):
   numbered DOM snapshot, trusted mouse/keyboard input, screenshots, file inputs filled from the NAS or local
   folders with new names, NAS copy/rename, Power Automate desktop flow run links. Risky steps (submit, Enter in a
   form, pay, delete, upload, another site, desktop flow) wait for the user's Allow; passwords are never typed.

Look especially for:
A. Security and privacy. Prompt injection from emails, meeting speech or file contents that could make the chat
   or drafter change settings, run a Power Automate WRITE action, exfiltrate data, or call tools it shouldn't.
   API keys or the NAS password leaking into prompts, logs, the NAS or the page. XSS (any innerHTML with
   untrusted text: email bodies, file names, transcripts, model output). Manifest permissions and CSP.
B. Data loss: anything that could delete or overwrite files on the NAS or the computer that it shouldn't (mirror
   logic, undo of settings, meeting autosave replacing the wrong file, OCR script writing outside .assistant).
C. Correctness: the tool-use loops (Anthropic tool_use/tool_result pairing, pause_turn, Gemini functionCall /
   functionResponse and thought signatures), structured-output parsing, the audio pipeline (resampling,
   segmentation, echo removal, ordering of transcript entries, stop/start while transcription is in flight),
   index updates (incremental re-index, relabelling projects, deep index matching by path+size), race
   conditions between the engine, side panel and meeting window sharing one IndexedDB.
D. Token and cost efficiency: places where the code sends more to the AI than needed, calls it more often than
   needed, or could loop. Anything that could run up a bill unattended.
E. Robustness for a non-technical user: what happens with no API key, a wrong key, rate limits, the NAS offline,
   huggingface.co blocked, Chrome restarted mid-meeting, the side panel closed mid-reply, Outlook's page changing.
F. Chrome/MV3 issues: offscreen document lifecycle, service worker restarts, getDisplayMedia options, AudioWorklet,
   module workers in extensions, Document PiP, chrome.storage vs IndexedDB, background-tab throttling.
G. The bash/Python server scripts: idempotency, running as root vs the WebDAV user, paths with spaces, failure
   handling, anything unsafe (including parsing untrusted .pst/.msg/.docx files from the user's mailbox).
H. Recorder: losing data on long recordings, files left half-written, recording continuing after the user thinks
   it stopped, permission prompts, formats that won't play on Windows.
I. Browser agent: any way a web page (its text, its DOM, a dialog, a redirect) can make the agent act without the
   user's Allow: submit or send something, upload a file, type into a password field, go to another site, start a
   desktop flow, or read NAS/local files into a page. Element numbers going stale between snapshot and click.
   Detaching the debugger on every exit path. Large file uploads through Runtime.evaluate.
J. Cross-check and kill switch: a call that escapes the gate or keeps running after Stop AI; a review result that
   is trusted when it shouldn't be (or blocks a correct draft); cost doubling where it isn't worth it.

For each finding give: severity (critical/high/medium/low), file:line, what goes wrong, a concrete reproduction,
and a suggested fix. No style preferences. Say explicitly when you are unsure.

Previously reported and already resolved — re-check the CURRENT code and only report one again if it is still wrong:
1. Mirror deleting a NAS folder that holds only Jellyfin metadata when the folder picker can't see an empty local
   folder: fixed in lib/mirror.js (dirContentCount ignores protected metadata for that safeguard; renames still
   clean up via hadMoveSource).
2. NAS folder listing freezing on 100k entries: app.js renders 1,000 rows and a "Show more" row (LISTING_PAGE).
3. Credentials only in config.js: the setup form in app.html + lib/config-store.js (chrome.storage.local, optional
   session-only password, Settings → NAS connection); config.js still wins when filled in.
4. "Memory leak" from keeping t.file after a failed upload: intentional — Retry failed needs it (transfer.js
   retryFailed skips tasks without a file), and a File from a dropped folder is a disk reference, not a copy in memory.
5. Background-tab timer throttling: retry back-off and auto-resume use a dedicated worker's timers (lib/util.js
   after()/sleep(), lib/timer-worker.js); chrome.alarms (30 s minimum) would be worse.
```
