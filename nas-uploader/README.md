# NAS Uploader — Chrome extension

Upload whole folder trees from any computer to your home NAS, straight from Chrome. There's nothing to install
except the extension itself. Drag a folder (with all its sub-folders) onto the page and it is recreated
on the NAS exactly as it was. You can also browse the NAS, make folders, download and delete files.

- **Drag & drop complete folder structures**, any depth, including empty folders, unicode / emoji / `#` / `%` names,
  and files of any size (tested with a 5 GB file).
- **Built for big, slow transfers**: parallel uploads, automatic retries with back-off, waits out lost Wi-Fi, keeps
  the computer awake, pause / resume / cancel, live speed and time left.
- **Resume anything**: if a transfer gets interrupted (tab closed, laptop shut, network dropped), drop the same
  folder again. Files already on the NAS with the same size are skipped, and only the rest are sent.
- **Double-checks the result**: after uploading, every folder is re-read from the NAS and every file's size is
  compared. Anything that doesn't match is listed and can be retried with one click.
- Your NAS address, username and password are **built into the extension** (`config.js`). Or leave the
  password out and it will ask once per browser session instead.

It talks to the NAS over **WebDAV**, the standard file-sharing protocol supported by Synology, QNAP, TrueNAS,
Asustor, Netgear ReadyNAS, OpenMediaVault, Nextcloud/ownCloud and most other NAS systems.

---

## 1. Prepare the NAS (once, at home)

The extension needs a WebDAV address that works **from the internet**. Ideally it uses **https://** with a real
certificate.

### Synology (DSM 7)
1. **Package Center** → install **WebDAV Server** → open it → tick **Enable HTTPS** (port **5006**).
2. **Control Panel → External Access → DDNS** → add a free `yourname.synology.me` address.
3. **Control Panel → Security → Certificate** → **Add** → **Let's Encrypt** for that address (so browsers trust it).
4. On your router, **forward TCP port 5006** to the NAS.
5. *(Recommended)* **Control Panel → User** → create a user just for this (e.g. `uploader`) with read/write on one
   shared folder only (e.g. `Uploads`) and no admin rights.
6. Your address is `https://yourname.synology.me:5006/`.

> QuickConnect (`quickconnect.to`) does **not** carry WebDAV, so you need the DDNS + port-forward route above
> (or your own reverse proxy).

### QNAP (QTS / QuTS hero)
1. **Control Panel → Network & File Services → Win/Mac/NFS/WebDAV → WebDAV** → enable WebDAV, and give your user
   WebDAV permission on the shared folder.
2. Set up **myQNAPcloud** (DDNS + free Let's Encrypt certificate) and forward the NAS's HTTPS port on your router.
3. Your address looks like `https://yourname.myqnapcloud.com:<https-port>/`.

### TrueNAS, OpenMediaVault, Unraid, others
Turn on the WebDAV service (TrueNAS: **Services → WebDAV**; OMV: WebDAV plugin; Unraid: a WebDAV container),
put it behind HTTPS (reverse proxy or the built-in TLS option) and forward the port.

### Nextcloud / ownCloud
Use `https://cloud.example.com/remote.php/dav/files/USERNAME/`. Create an app password under
*Settings → Security* and use that as the password.

**Check it before you leave:** open the address in a browser on your phone *with Wi-Fi turned off* (so you're
coming from the internet, like you will be). You should get a login prompt. After logging in, an error page or a
plain listing is fine. "Connection refused" or "site can't be reached" means the port forward or the service
isn't working yet.

---

## 2. Put your details into the extension

Get the extension: download **`nas-uploader-extension.zip`** from this folder on GitHub (open the file, then
**Download raw file**) and unzip it. You get a folder called `nas-uploader`. (The same files are in
`extension/` here.)

Open `config.js` in that folder with any text editor (Notepad is fine) and fill in:

```js
export const CONFIG = {
  serverUrl: 'https://yourname.synology.me:5006/',
  username: 'uploader',
  password: 'your password here',   // or '' to be asked once per browser session
  startFolder: '/Uploads',           // folder that opens first ('/' = top level)
  parallelUploads: 3,
};
```

Save the file. **Do not commit your real password to a public GitHub repository.** Edit the copy on the
computer (or USB stick), not the one in the repo.

---

## 3. Install it on a computer

1. Get the unzipped **`nas-uploader`** folder onto the computer: download and unzip it there, or bring it
   already filled in on a USB stick or cloud drive. Leave the folder in place; Chrome loads the extension from it.
2. If you didn't fill in `config.js` beforehand, do it now (step 2).
3. In Chrome open **`chrome://extensions`**, switch on **Developer mode** (top-right), click **Load unpacked**
   and select the `nas-uploader` folder (the one that contains `manifest.json`).
4. Click the puzzle-piece icon in the toolbar and pin **NAS Uploader**. Click it to open the uploader in a tab.

If you edit `config.js` later, press the **reload** ↻ button on the NAS Uploader card in `chrome://extensions`.

> **Locked-down computers:** if *Developer mode* or *Load unpacked* is greyed out, the computer's administrator
> has blocked extensions with a policy (check `chrome://policy`). That can't be bypassed from inside Chrome.
> On such machines you can still use your NAS's own web interface. For example, Synology **File Station**
> (log in to DSM in the browser) also accepts folder drag & drop uploads.

**When you're done on a shared or borrowed computer:** remove the extension in `chrome://extensions` and delete the
folder. Your credentials live in `config.js`.

---

## 4. Using it

- **Browse** with the folder names, the breadcrumb bar and **↑ Up**. **＋ New folder** creates a folder.
  ⤓ downloads a file and 🗑 deletes it (you'll be asked to confirm).
- On Synology and QNAP the top level shows your **shared folders**. Open one of them before uploading; the
  top level itself can't hold files.
- **Upload**: go to the destination folder, then drag folders and/or files anywhere onto the page, or use
  **Choose a folder…** / **Choose files…**. You'll see a summary (number of files, total size, unreadable items)
  and confirm with **Upload**.
- While uploading you see overall progress, speed, time left and the files currently in flight. **Pause**,
  **Resume** and **Cancel** do what they say. You can keep browsing and dropping more folders; they are queued.
- If anything fails, the reason is listed and **Retry failed** tries those files again.
- **Keep the tab open** until it says *All done ✓*. If the tab is closed or the computer restarts, just drop the same
  folder into the same place again; what's already there is skipped.

**Upload options** (under the drop area, remembered per computer):

| Option | Default | What it does |
|---|---|---|
| Skip files already on the NAS with the same size | on | Makes re-dropping a folder a cheap "resume". Turn off to force re-sending everything. |
| Double-check every file after uploading | on | Re-reads each folder from the NAS and compares sizes. |
| Leave out system junk files | on | Skips `.DS_Store`, `Thumbs.db`, `desktop.ini`, `._*`, `$RECYCLE.BIN`, `System Volume Information`. |
| Parallel uploads | 3 | More helps with many small files; 2–4 is plenty for big ones. |

---

## Good to know

- **Big single files and proxies:** a reverse proxy in front of the NAS may cap request size. Cloudflare Tunnel
  allows 100 MB per request on free plans; nginx's `client_max_body_size` defaults to 1 MB. A file over the limit fails
  with *"File is too large for the NAS or a proxy in front of it (HTTP 413)"*. Raise the limit, or connect to the
  NAS's WebDAV port directly.
- **Self-signed certificates:** if the NAS uses one, click **Open the NAS address in a tab** on the error screen
  and accept the warning once. A Let's Encrypt certificate avoids this entirely.
- **http:// works but is not encrypted.** The top bar says *not encrypted (http)* when that's the case.
- **Folder picker vs drag & drop:** *Choose a folder…* can't see empty folders (a browser limitation).
  Drag & drop can.
- **Timestamps:** WebDAV servers set the modification time to the upload time. Nextcloud/ownCloud keep the
  original time.
- **"Same size" is the skip rule.** A file that changed but kept exactly the same size would be skipped. Untick the
  skip option to force a full re-send.
- **Permissions:** the extension only talks to your NAS. It has no content scripts and does not read other web
  pages. Its broad host permission exists only so it can reach whatever NAS address you put in `config.js`.
  You can narrow `host_permissions` in `manifest.json` to your NAS address, e.g.
  `"https://yourname.synology.me:5006/*"`.

## Security

Anyone who can use the Chrome profile where the extension is installed can use the NAS account in `config.js`, and
can read the password from the extension folder. To limit the damage if a computer is lost or shared:

- use a dedicated NAS account with write access to a single shared folder (no admin rights);
- or leave `password: ''` so the password is typed once per browser session and kept in memory only. **Lock**
  forgets it immediately;
- prefer https:// with a valid certificate;
- remove the extension and delete its folder from computers you don't own.

---

## Tests

`tests/` contains an end-to-end suite. It loads the real extension into Chromium (Playwright) and uploads real
folder trees to real WebDAV servers: Apache mod_dav (the engine behind Synology/QNAP/TrueNAS WebDAV), Apache
under a sub-path containing a space, and WsgiDAV. A proxy injects 503s, 502s, dropped connections and permanent
403s, and a second proxy throttles bandwidth for the pause/resume/cancel tests. Every uploaded file is
compared byte-for-byte (SHA-256) with the original.

```bash
sudo apt-get install apache2 apache2-utils      # mod_dav
python3 -m pip install wsgidav cheroot          # second WebDAV server
cd tests && ./run-tests.sh                      # NO_BIG=1 ./run-tests.sh skips the 1.2 GB / 5 GB files
```
