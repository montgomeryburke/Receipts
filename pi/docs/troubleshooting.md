# Troubleshooting

## The Pi keeps asking to unlock a "keyring"

That is Raspberry Pi OS's login keyring — where saved Wi-Fi, Chromium, and VNC
passwords live. It prompts because the Pi auto-logs-in to the desktop, so your
password is never typed and the keyring is never unlocked.

Run this as your normal user (**not** with sudo):

```bash
rm -rf ~/.local/share/keyrings/* && echo '--password-store=basic' >> ~/.config/chromium-flags.conf && sudo reboot
```

That covers both usual triggers: a stale keyring, and Chromium demanding the
system password store. You lose passwords saved *inside the keyring* — not your
Wi-Fi setup and not your user password.

Still prompting? Then it is the auto-login. For a headless NAS the right fix is
to stop starting the desktop:

```bash
sudo raspi-config nonint do_boot_behaviour B2 && sudo reboot
```

`B2` is console with auto-login. SSH keeps working; the desktop and its keyring
prompt never start. There is a script for all of this at
`pi/scripts/fix-keyring.sh`.

---

## The USB drive was not found

```bash
lsblk -o NAME,SIZE,TRAN,FSTYPE,MOUNTPOINT
```

Look for a device with `TRAN=usb`. If nothing appears, try another port or
cable — an underpowered hub is the usual cause. If the drive appears but has no
`FSTYPE`, it has no filesystem:

```bash
sudo bash pi/nas/scripts/setup-usb.sh --format    # ERASES the drive
```

To target a specific device:

```bash
sudo bash pi/nas/scripts/setup-usb.sh --device /dev/sda1
```

## The drive is not there after a reboot

```bash
mount /srv/nas
sudo journalctl -u pi-nas -n 50
```

The fstab entry uses `nofail`, so a missing drive never blocks boot — the Pi
comes up fine and the share is simply empty. Check the drive is seated and
powered.

## The extension says it cannot reach the Pi

Work outward:

```bash
curl http://127.0.0.1:8765/api/health     # on the Pi itself
sudo systemctl status pi-nas
tailscale status                          # is the Pi online in your tailnet?
```

Then on your laptop, open the NAS address directly in a browser tab and add
`/api/health`. You should see `{"ok":true,...}`. If that works but the
extension does not, the address in its settings is probably wrong — it must
include `https://` and no trailing path.

## "Access token rejected"

```bash
sudo pi-nas-token list
sudo pi-nas-token add my-laptop
```

Paste the new token into the extension's options. Tokens cannot be recovered,
only replaced — only their hashes are stored.

## Uploads fail on large files

Raise the limit in `/etc/pi-nas/config.env`:

```
PI_NAS_MAX_UPLOAD_BYTES=107374182400
```

then `sudo systemctl restart pi-nas`. Also check there is room: `df -h /srv/nas`.

## Home Assistant will not start

```bash
cd /opt/homeassistant
sudo docker compose ps
sudo docker compose logs --tail 80 homeassistant
```

First boot genuinely takes a few minutes. If a container keeps restarting, the
log line before each restart is the real error.

## "Claude Assist" is not in the integration list

The custom component is only picked up at startup:

```bash
ls /opt/homeassistant/config/custom_components/claude_assist/
cd /opt/homeassistant && sudo docker compose restart homeassistant
```

Then search the integration list again. Hard-refresh the browser if it is
cached.

## The assistant replies but does not control anything

Devices must be exposed explicitly: **Settings → Voice assistants → Expose**.
Also check **Device control** in the Claude Assist options is not set to
"No device control".

## The assistant is slow

Set **Thinking effort** to `low` in the Claude Assist options, and check which
speech model you are running:

```bash
grep WHISPER_MODEL /opt/homeassistant/.env
```

`tiny-int8` is the fast one. If a Pi 4 was given `base-int8`, drop it back to
`tiny-int8` and `sudo docker compose up -d`.

## Starting over

```bash
sudo systemctl disable --now pi-nas
sudo rm -rf /opt/pi-nas /etc/pi-nas /etc/systemd/system/pi-nas.service
sudo systemctl daemon-reload
cd /opt/homeassistant && sudo docker compose down -v
```

Your files in `/srv/nas` are untouched by any of that.
