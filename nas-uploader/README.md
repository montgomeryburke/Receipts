# Project Assistant — NAS mirror, email drafts and Teams meeting prompts (Chrome extension)

One Chrome extension, nothing else to install on the work computer:

- **NAS files** — upload whole folder trees to your home NAS and **mirror** project folders to it (only changes
  are sent: new, edited, renamed, deleted). Drag & drop any depth, any size, resumable, double-checked.
- **One fileset** — each mirrored project folder is copied to the NAS once and **indexed once, on this computer**.
  Email drafts, meeting prompts and the chat all search that same index; nothing is mirrored twice.
- **Email drafts (Outlook on the web)** — reads the open email, finds the answer in your project files, and
  prepares a reply with the sources. You review and send. (This is the former MailMirror extension.)
- **Meeting assistant (Teams)** — listens to the meeting (the **Teams app** on Windows or **Teams in Chrome**)
  and to your microphone, with a sound meter for each, transcribes, and flashes up **what you could say** with
  quotes from your project files and standards (looking a standard up online when you don't have it). Ask it
  questions **privately** by typing. Transcripts and a summary with action items are saved to the NAS.
- **Chat** — tell the extension in plain words when something isn't working the way you want ("keep meeting
  prompts to one sentence", "always use the 2024 spec for concrete questions") and it changes its own settings,
  rules and memory. Every change has **Undo**. It also walks you through **setting up Power Automate flows**.
- **Learns each project** — decisions, names and facts from meetings and the chat are remembered per project
  and used the next time that project comes up.
- **Saves on AI cost** — indexing, search, project detection, the "is this worth a prompt?" check and free
  transcription (Whisper) all run on your computer; scanned PDFs are OCR'd on the HP. Only short excerpts are
  sent to Claude or Gemini, and only when needed. Without any key, transcription and search still work.

The NAS is reached over **WebDAV** (the setup script below turns the HP into one). Your NAS address, username
and password are built into `config.js`.

---

## 1. Set up the server on the HP (Proxmox), once

**Nothing is ever installed on the offsite computer.** It only needs Chrome and this extension. Everything
below happens on the HP at home.

### 1a. Add the drive for the mirror (Proxmox web interface)

1. Fit the new drive in the HP and start it up.
2. In Proxmox, click the HP (the node) → **Disks**. Find the new drive by its model and size; **Usage** should
   say *No*. If it was used before, select it and click **Wipe Disk**. This erases *that drive only*, so double-check
   the model and size.
3. **Disks → Directory → Create: Directory**: choose the new drive, filesystem **ext4**, name **mirror**, keep
   **Add Storage** ticked → **Create**.
4. Open the container that will run the uploader, then **Resources → Add → Mount Point**:
   - **Storage**: `mirror`
   - **Disk size**: nearly the whole drive (for a 4 TB drive, about 3600 GiB)
   - **Path**: `/mnt/mirror`
   - leave **Backup** unticked, so Proxmox backups don't try to copy the whole drive.

   Then click **Create** and restart the container. You can use the Jellyfin container or a small new Debian
   container. The uploader only ever gets access to `/mnt/mirror`, never to your Jellyfin media.

### 1b. Run the setup script in that container

The script in `server/setup-webdav.sh` turns the drive into something the extension can upload into:

- it shares only the folder you give it (`/mnt/mirror`), or without `--folder` it offers Jellyfin's
  library folders and other mounted drives to pick from;
- it installs a WebDAV server (Apache) with a login, no upload size limit, and nothing uploaded is ever executed;
- it sorts out permissions so uploads are written like your existing files and **Jellyfin can read them**;
- it makes it reachable from outside your home (see the choices below);
- it tests itself, then prints the exact lines to paste into `config.js`.

**Run it in the container that has the media** (Proxmox web UI → the container → **Console**):

```bash
apt-get update && apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/montgomeryburke/Receipts/claude/friendly-pasteur-uixwht/nas-uploader/server/setup-webdav.sh -o setup-webdav.sh
bash setup-webdav.sh --folder /mnt/mirror --access port-forward --domain YOURNAME.duckdns.org --duckdns-token YOUR-TOKEN
```

Your router must forward **TCP 443 to this container's address** (for example `192.168.1.187`), *not* to the
router's own address (`192.168.1.1`). Using your own domain instead of DuckDNS also needs TCP 80 forwarded.

(Once this is merged, `claude/friendly-pasteur-uixwht` in that address becomes `main`.)

It asks how the offsite computer should reach the HP. With every choice the offsite computer needs **nothing
installed**: it just uses Chrome with the extension.

| Choice | What you do (at home) | Good for |
|---|---|---|
| **1. Port forward** | Get a free name at [duckdns.org](https://www.duckdns.org) and forward TCP **443** on your router to the container. The script keeps the name pointed at your home, gets a free Let's Encrypt certificate through DuckDNS (so port 80 isn't needed), and renews it automatically. | Fastest. Best for large mirrors. Failed logins are blocked after 10 tries; security updates install automatically. |
| **2. Tailscale Funnel** | Tailscale is installed **on the HP's container only** and gives it a normal public `https://…ts.net` address that any browser can open, no Tailscale needed on the visiting computer. No router changes. | When you can't change router settings. Tailscale caps the speed somewhat. |
| **3. Home network only** | Nothing. | Trying it out first. You can re-run the script later and pick 1 or 2. |

The script also sets up two helpers for the assistant (skip them with `--no-ocr` / `--no-whisper`):

- **OCR for scanned PDFs and photos**: every 2 hours, at idle priority, it OCRs the scanned documents in the
  folders the extension lists as project folders (never your movies) and writes `/.assistant/deep-index.jsonl.gz`.
  The extension picks it up, so scanned submittals become searchable without slowing the work computer.
- **The free speech-to-text model** (80 MB) is copied to `/.assistant/models/`, for work networks that block
  huggingface.co.

Re-running the script is safe: it keeps your password unless you pass a new one with `--password`.
`bash setup-webdav.sh --help` lists the options; `bash setup-webdav.sh --uninstall` removes it (your files are
never touched). The settings are also saved in `/root/nas-uploader-settings.txt` in the container.

In Jellyfin, turn on **Real time monitoring** for your libraries (Dashboard → Libraries → ⋯ → Manage library) so
uploads show up straight away; otherwise they appear after the next library scan.

<details>
<summary>If the script says the folder belongs to "nobody"</summary>

That's an *unprivileged* container whose media folder is owned on the Proxmox host by a user the container can't
see, so nothing inside it can write there. The script prints the one-line fix to run on the Proxmox **host**
(`chown -R 100000:100000 /host/path/to/media`), then run the script again.
</details>

<details>
<summary>Other NAS systems (Synology, QNAP, TrueNAS, Nextcloud)</summary>

The extension works with any WebDAV server reachable over HTTPS:

- **Synology**: Package Center → **WebDAV Server** → enable HTTPS (port 5006); DDNS + Let's Encrypt in Control Panel;
  forward port 5006. QuickConnect does *not* carry WebDAV. Address: `https://yourname.synology.me:5006/`.
- **QNAP**: Control Panel → Network & File Services → WebDAV; myQNAPcloud for DDNS + certificate.
- **TrueNAS**: Services → WebDAV. **Nextcloud**: `https://cloud.example.com/remote.php/dav/files/USERNAME/` with
  an app password.
</details>

---

## 2. Put your details into the extension

Download **`nas-uploader-extension.zip`** from this folder on GitHub (open the file, then **Download raw file**)
and unzip it. You get a folder called `nas-uploader`. Open `config.js` in it with any text editor (Notepad is
fine) and paste the lines the setup script printed:

```js
export const CONFIG = {
  serverUrl: 'https://hp.your-tailnet.ts.net/',
  username: 'uploader',
  password: 'the password it printed',   // or '' to be asked once per browser session
  startFolder: '/',                       // folder that opens first, e.g. '/Movies'
  parallelUploads: 3,
};
```

**Never commit your real password to this repository: it is public.** Edit the copy you downloaded, not the
one in the repo.

---

## 3. Install it on a computer

1. Get the filled-in **`nas-uploader`** folder onto the computer: download and unzip it there, or bring it on a
   USB stick or cloud drive. Leave the folder in place; Chrome loads the extension from it.
2. In Chrome open **`chrome://extensions`**, switch on **Developer mode** (top-right), click **Load unpacked**
   and select the `nas-uploader` folder (the one that contains `manifest.json`).
3. Click the puzzle-piece icon in the toolbar and pin **Project Assistant**. Clicking it opens the assistant side
   panel; **🗄 NAS files** opens the uploader in a tab, **🎙 Meeting** opens the meeting window.

If you edit `config.js` later, press the **reload** ↻ button on the extension's card in `chrome://extensions`.
**Updating from an earlier version:** unzip the new version over the same folder and press reload — saved
mirrors are kept. (MailMirror users: remove MailMirror; its settings don't carry over, so paste your API keys
into Settings once. Use **Settings → Data → Export** next time you move computers.)

> **Locked-down computers:** if *Developer mode* or *Load unpacked* is greyed out, the computer's administrator
> has blocked extensions with a policy (check `chrome://policy`). That can't be bypassed from inside Chrome.

**When you're done on a shared or borrowed computer:** remove the extension in `chrome://extensions` and delete the
folder. Your credentials live in `config.js`.

---

## 4. Using it

### Upload
- **Browse** with the folder names, the breadcrumb bar and **↑ Up**. **＋ New folder** creates a folder.
  ⤓ downloads a file and 🗑 deletes it (you'll be asked to confirm).
- Go to the destination folder, then drag folders and/or files anywhere onto the page, or use
  **Choose a folder…** / **Choose files…**. You'll see a summary and confirm with **Upload**.
- While uploading you see progress, speed, time left and the files in flight. **Pause**, **Resume** and **Cancel**
  do what they say. You can keep browsing and dropping more; it's queued.
- If anything fails, the reason is listed and **Retry failed** tries those files again.
- **Keep the tab open** until it says *All done ✓*. If the tab is closed or the computer restarts, drop the same
  folder into the same place again; files already on the NAS (same size, not changed since) are skipped.

### Mirror (send only the changes)
- **From a drop:** drag a single folder onto the page and choose **Mirror…** instead of Upload. The NAS folder
  with the same name in the current folder is made identical to it.
- **One-click mirrors:** under **Mirrors**, click **＋ New mirror…**, pick the folder on this computer and the
  folder on the NAS. From then on, **Sync now** is all it takes. Chrome may ask once per session to allow reading
  the folder. (A mirror you start by dropping a folder can be remembered the same way: tick *Remember…*.)
- Before anything happens you see exactly what will change: new files, changed files, renamed/moved files (moved on
  the NAS, nothing re-uploaded), and the list of files and folders that will be **deleted** from the NAS because
  they're gone from your folder. Untick **Delete them from the NAS** to keep them.
- **Safety:** if your folder looks empty, or more than half of the NAS copy would be deleted, you get a red warning
  and deleting is *not* ticked. Deletions always run last, after every upload has finished.
- **Jellyfin's files are protected:** artwork, `.nfo` files, downloaded subtitles and trickplay images that
  Jellyfin (or Kodi/Plex) saved next to your media on the NAS are never deleted by a mirror. A whole folder you
  deleted (e.g. a movie) does go, artwork included.
- Files on your computer that can't be read during a sync (locked by another program, no permission) are
  reported and their NAS copies are left alone.
- How changes are found: the mirror keeps a small file, `.nas-uploader-mirror.json`, in the NAS folder. It records
  each file's size and modification time as they were on your computer when last sent, the same quick check rsync
  uses. A file that changed but kept *both* its size and its modification time wouldn't be noticed (very rare).

**Upload options** (under the drop area, remembered per computer):

| Option | Default | What it does |
|---|---|---|
| Skip files already on the NAS | on | Same size and not changed since it was sent → skipped. Turn off to force re-sending everything. |
| Double-check every file after uploading | on | Re-reads each folder from the NAS and compares sizes. |
| Leave out system junk files | on | Skips `.DS_Store`, `Thumbs.db`, `desktop.ini`, `._*`, `$RECYCLE.BIN`, `System Volume Information`. |
| Parallel uploads | 3 | More helps with many small files; 2–4 is plenty for big ones. |

---

### Project folders: one fileset for everything

Mirror the folder that holds your projects (or the drive folder with one folder per project) with **Mirror a
folder…** — in NAS files, or from the side panel's **Mirror** tab. When you create it, choose whether each
subfolder is a project (the usual case) or the whole folder is one project. After every sync the assistant
re-reads only the changed files. Settings → **Project folders** lets you switch indexing off for a folder.

---

## 5. Email drafts (Outlook on the web)

Open the side panel next to Outlook on the web. Open an email and click **Draft reply to open email** (or let it
draft new mail by itself — Settings → Email). The draft lists what was asked, the answers and the files they came
from; anything it couldn't find is marked `[MISSING: …]` and shown under **Questions**, where your answer
rewrites the draft. 👍 / 👎 on a source teaches it which document to use for emails like that one.
**Insert into Outlook reply** puts the text into the reply box. It never sends anything.

## 6. Meetings (Teams)

Click **🎙 Meeting** in the side panel. A small window opens:

1. Click **🖥 Teams app** (the Windows app). Chrome asks what to share: choose **Entire screen**, tick
   **Also share system audio**, click **Share**. Or click **🌐 Teams in Chrome** and pick the Teams tab
   (keep **Also share tab audio** on). Only the sound is used; the picture is discarded immediately.
2. **Also listen to my microphone** is on by default (Chrome asks once). The two meters show the meeting and
   your mic; if the meeting goes silent for 15 s it tells you what to check. A headset avoids echo; with speakers,
   duplicated lines are dropped.
3. Prompts appear when someone asks a question or a technical topic comes up: what to say, why, and the exact
   quote with its file and page (click it to open the file from the NAS). If your files don't cover a standard,
   it looks it up online and links the source. **Ask now** asks for a prompt; **⧉ Pop out** keeps prompts in a
   small window on top of Teams.
4. **Ask privately**: type a question (e.g. "what did we agree on the barrier height?") — only you see the answer.
5. **Stop and save**: the transcript, prompts, your private questions and (with a key) a summary with decisions
   and action items are saved to `/Meetings/<project>/` on the NAS (also every minute while it runs), and the key
   facts are remembered for that project.

Transcription is **free on this computer** (Whisper; the model is downloaded once) or, with a Gemini key, done by
Gemini (⚙ in the meeting window). Prompts need a Claude or Gemini key. Make sure everyone in the meeting knows it
is being transcribed, as your workplace requires.

## 7. The chat: tell it what to change, and Power Automate

The side panel's **Chat** tab talks to the extension itself. Examples:

- "In meetings the prompts are too long" → it adds a standing instruction (and can space prompts out).
- "Concrete questions should always use the 2024 spec" → it teaches that document for those topics.
- "Remember that the GC on Alert is Arctic Fresh" → saved to that project's memory.
- "Why didn't the Alert email get a draft?" → it checks the status and errors and explains.
- "Set up a flow that logs every email to my SharePoint tracker" → it creates the action, gives you the
  click-by-click steps in make.powerautomate.com with the exact JSON schema, asks for the flow's URL, and offers a
  test. Flows that change records only ever run when you click.

Every change appears under the reply with **Undo** (and under *Changes made from the chat*). API keys are never
taken in the chat. If something needs a change to the extension's code, it says so and saves a change request to
`/.assistant/change-requests.md` on the NAS — paste that into Claude Code.

## 8. AI keys and cost

Paste a Claude (Anthropic) and/or Gemini key in **Settings → AI provider**; they stay in this browser profile and
go only to that provider. Claude uses `claude-opus-5-5` at low effort by default (Settings lets you pick Sonnet or
Haiku to spend less), with Anthropic's server-side fallback: if Claude declines a request, Anthropic retries it on
its recommended fallback model. Gemini "auto" picks the newest stable Gemini Flash. The cost of each draft, chat
reply and meeting is shown as you go. To keep it low: search and indexing are local, automatic meeting prompts
come at most every 20 s (adjustable) and only when something is asked, and each call carries only the last couple
of minutes of conversation plus the best few excerpts.

## Good to know

- **Self-signed certificate (home-network-only mode):** click **Open the NAS address in a tab** on the error screen
  and accept the warning once per computer. Funnel and port-forward mode use real certificates.
- **Folder picker vs drag & drop:** *Choose a folder…* can't see empty folders (a browser limitation), so a mirror
  started that way never deletes empty folders on the NAS. Drag & drop and saved mirrors can see them.
- **Timestamps:** the NAS sets a file's modification time to when it was uploaded.
- **Reverse proxies:** if you put your own proxy in front (`--access proxy --public-url …` in the setup script),
  make sure it doesn't cap request size (nginx: `client_max_body_size 0;`). Cloudflare Tunnel's free plan stops at
  100 MB per file.
- **Permissions:** the extension needs access to your NAS, the AI provider you use, your Power Automate flow
  addresses, and Outlook on the web (its only content script, which reads the open email and fills in the reply
  box). It reads no other pages. You can narrow `host_permissions` in `manifest.json`.

## Security

Anyone who can use the Chrome profile where the extension is installed can use the account in `config.js`, and
can read the password from the extension folder. To limit the damage if a computer is lost or shared:

- the setup script creates a dedicated `uploader` account that can only reach the one shared folder;
- or leave `password: ''` so the password is typed once per browser session and kept in memory only. **Lock**
  forgets it immediately;
- remove the extension and delete its folder from computers you don't own.

---

## Tests

`tests/assistant-e2e.cjs` covers the assistant: mirroring a folder also indexes it (NAS paths, PDF text,
projects), email drafts (right excerpts, instructions, memory, fallbacks), the chat with Claude and with Gemini
(tool calls, Undo, refusing API keys, Power Automate setup against a stand-in HTTPS flow), the meeting window
(real audio through both channels, sound meters, Gemini transcription, prompts with quotes, web look-ups, private
questions, saving to the NAS with a summary, echo removal), **real Whisper transcription** in the extension
(including the NAS fallback), the audio resampler, and OCR of scanned PDFs on the server. It uses mock Claude and
Gemini servers, so no keys are needed: `node tests/assistant-e2e.cjs` with the WebDAV test servers running.

`tests/e2e.cjs` is the NAS uploader suite. It loads the real extension into Chromium (Playwright) and uploads and mirrors
real folder trees to real WebDAV servers:
- Apache mod_dav, at the root, under a sub-path with a space, over self-signed HTTPS, and behind an HTTPS reverse
  proxy;
- WsgiDAV.

Proxies inject failures (503s, 502s, dropped connections, permanent 403s), throttle bandwidth and take the server
offline mid-transfer. Every uploaded file is compared byte-for-byte (SHA-256) with the original.

`tests/test-setup-script.sh` runs `server/setup-webdav.sh` for real in a container made to look like the HP's
(media owned by a user, Jellyfin libraries, a freshly added drive), then drives the extension against the result.
Port-forward mode is tested with real certificates from Pebble (Let's Encrypt's test CA): issuance through DuckDNS
and through port 80, renewal, fail2ban. It changes the system Apache, so it only runs in a throwaway container.

```bash
sudo apt-get install apache2 apache2-utils      # mod_dav
python3 -m pip install wsgidav cheroot          # second WebDAV server
cd tests && ./run-tests.sh                      # NO_BIG=1 ./run-tests.sh skips the 1.2 GB / 5 GB files
CI_OK_TO_MODIFY_SYSTEM=1 ./test-setup-script.sh # throwaway containers only
```
