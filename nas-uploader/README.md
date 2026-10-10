# NAS Uploader — Chrome extension

Upload whole folder trees from any computer to your home NAS, straight from Chrome. There's nothing to install
except the extension itself. Drag a folder (with all its sub-folders) onto the page and it is recreated
on the NAS exactly as it was. You can also browse the NAS, make folders, download and delete files.

- **Drag & drop complete folder structures**, any depth, including empty folders, unicode / emoji / `#` / `%` names,
  and files of any size (tested with a 5 GB file and with 20,000 files in one drop).
- **Mirror**: keep a NAS folder identical to a folder on the offsite computer. Each sync sends only what changed:
  new and edited files are uploaded, renamed or moved files are moved on the NAS without uploading again, and
  files you deleted are removed (after you've seen the list). Save a mirror once, then it's one click: **Sync now**.
- **Built for big, slow transfers**: parallel uploads, automatic retries, waits out lost Wi-Fi, pauses by itself if
  the NAS drops off and carries on when it's back, keeps the computer awake, pause / resume / cancel, speed and
  time left.
- **Double-checks the result**: afterwards every folder is re-read from the NAS and every file's size compared.
- Your NAS address, username and password are **built into the extension** (`config.js`). Or leave the
  password out and it will ask once per browser session instead.

It talks to the NAS over **WebDAV**, the standard file-sharing protocol.

---

## 1. Set up the server on the HP (Proxmox), once

Your media lives in a Proxmox container on the HP, and Jellyfin reads it from there. The script in
`server/setup-webdav.sh` turns that folder into something the extension can upload into:

- it finds the folders Jellyfin uses (from Jellyfin's own library settings) and lets you pick;
- it installs a WebDAV server (Apache) with a login, no upload size limit, and nothing uploaded is ever executed;
- it sorts out permissions so uploads are written like your existing files and **Jellyfin can read them**;
- it makes it reachable from outside your home (see the choices below);
- it tests itself, then prints the exact lines to paste into `config.js`.

**Run it in the container that has the media** (Proxmox web UI → the container → **Console**):

```bash
apt-get update && apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/montgomeryburke/Receipts/claude/friendly-pasteur-uixwht/nas-uploader/server/setup-webdav.sh -o setup-webdav.sh
bash setup-webdav.sh
```

(Once this is merged, `claude/friendly-pasteur-uixwht` in that address becomes `main`.)

It asks how the offsite computer should reach the HP:

| Choice | What you do | Good for |
|---|---|---|
| **1. Tailscale Funnel** | Sign in to Tailscale once when asked. No router changes. | Easiest. Real HTTPS certificate. Tailscale caps the speed somewhat. |
| **2. Port forward** | Forward TCP **443** and **80** on your router to the container, and get a free name at [duckdns.org](https://www.duckdns.org). The script keeps the name updated and gets a free Let's Encrypt certificate. | Fastest for very large transfers. Failed logins are blocked after 10 tries. |
| **3. Home network only** | Nothing. | Trying it out first. You can re-run the script later and pick 1 or 2. |

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
3. Click the puzzle-piece icon in the toolbar and pin **NAS Uploader**. Click it to open the uploader in a tab.

If you edit `config.js` later, press the **reload** ↻ button on the NAS Uploader card in `chrome://extensions`.

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

## Good to know

- **Self-signed certificate (home-network-only mode):** click **Open the NAS address in a tab** on the error screen
  and accept the warning once per computer. Funnel and port-forward mode use real certificates.
- **Folder picker vs drag & drop:** *Choose a folder…* can't see empty folders (a browser limitation), so a mirror
  started that way never deletes empty folders on the NAS. Drag & drop and saved mirrors can see them.
- **Timestamps:** the NAS sets a file's modification time to when it was uploaded.
- **Reverse proxies:** if you put your own proxy in front (`--access proxy --public-url …` in the setup script),
  make sure it doesn't cap request size (nginx: `client_max_body_size 0;`). Cloudflare Tunnel's free plan stops at
  100 MB per file.
- **Permissions:** the extension only talks to your NAS. It has no content scripts and does not read other web
  pages. You can narrow `host_permissions` in `manifest.json` to your NAS address.

## Security

Anyone who can use the Chrome profile where the extension is installed can use the account in `config.js`, and
can read the password from the extension folder. To limit the damage if a computer is lost or shared:

- the setup script creates a dedicated `uploader` account that can only reach the one shared folder;
- or leave `password: ''` so the password is typed once per browser session and kept in memory only. **Lock**
  forgets it immediately;
- remove the extension and delete its folder from computers you don't own.

---

## Tests

`tests/` holds an end-to-end suite. It loads the real extension into Chromium (Playwright) and uploads and mirrors
real folder trees to real WebDAV servers:
- Apache mod_dav, at the root, under a sub-path with a space, over self-signed HTTPS, and behind an HTTPS reverse
  proxy;
- WsgiDAV.

Proxies inject failures (503s, 502s, dropped connections, permanent 403s), throttle bandwidth and take the server
offline mid-transfer. Every uploaded file is compared byte-for-byte (SHA-256) with the original.

`tests/test-setup-script.sh` runs `server/setup-webdav.sh` for real in a container made to look like the HP's
(media owned by a user, Jellyfin libraries), then drives the extension against the result. It changes the system
Apache, so it only runs in a throwaway container.

```bash
sudo apt-get install apache2 apache2-utils      # mod_dav
python3 -m pip install wsgidav cheroot          # second WebDAV server
cd tests && ./run-tests.sh                      # NO_BIG=1 ./run-tests.sh skips the 1.2 GB / 5 GB files
CI_OK_TO_MODIFY_SYSTEM=1 ./test-setup-script.sh # throwaway containers only
```
