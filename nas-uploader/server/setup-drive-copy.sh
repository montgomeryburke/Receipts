#!/usr/bin/env bash
# =============================================================================
#  Copies Google Drive folders (e.g. your S6 / TAC standards) to the NAS every day, so Project Assistant can
#  search them. Runs on the HP's container (where setup-webdav.sh was run). Nothing to install on the work PC.
#
#  It uses a Google "service account": a robot Google account you create once in a web browser, and share the
#  Drive folders with. No password or browser sign-in is needed on the HP.
#
#  One-time, in any browser (about 5 minutes):
#    1. https://console.cloud.google.com → create a project (any name) → "APIs & Services" → Library →
#       enable "Google Drive API".
#    2. "IAM & Admin" → Service accounts → Create → (no roles needed) → Done. Open it → Keys → Add key →
#       JSON → a .json file downloads. Copy its text.
#    3. In Google Drive, share each folder you want (e.g. "Standards") with the service account's e-mail
#       (…@….iam.gserviceaccount.com) as Viewer. Copy each folder's ID from its address bar
#       (https://drive.google.com/drive/folders/<THIS-PART>).
#
#  Then on the HP container:
#    nano /root/drive-key.json                      # paste the key, save
#    bash setup-drive-copy.sh --key /root/drive-key.json --folder <FOLDER-ID-or-URL> --to /mnt/mirror/Standards
#    (repeat --folder/--to pairs for more folders)
#
#  Options:
#    --key FILE        the service account key (.json); it is moved to /etc/nas-uploader-drive/drive-key.json
#    --folder ID|URL   a shared Drive folder (repeatable, each followed by --to)
#    --to DIR          where its copy goes on the NAS (inside the WebDAV folder)
#    --sync            also delete files from the copy that were deleted in Drive (default: only add/update)
#    --now             copy once right away (also done at the end of setup)
#    --uninstall       stop the daily copy (copied files are kept)
#
#  Then in the extension: Settings → Project folders → "Folders that are only on the NAS": add the NAS path
#  (e.g. /Standards). The HP reads the documents (with OCR) and they become searchable in meetings and drafts.
# =============================================================================
set -euo pipefail

KEY=""
SYNC=0
NOW=0
UNINSTALL=0
FOLDERS=()
DESTS=()
STATE_DIR=/etc/nas-uploader
KEY_DIR=/etc/nas-uploader-drive # readable by the WebDAV user's group only (rclone runs as that user)
JOBS="$KEY_DIR/drive-copy.list"
RUNNER=/usr/local/sbin/nas-uploader-drive-copy
# For automated tests only: copy from a local folder instead of Google Drive.
TEST_SOURCE="${NAS_UPLOADER_DRIVE_TEST_SOURCE:-}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="${2:?}"; shift 2 ;;
    --folder) FOLDERS+=("${2:?}"); shift 2 ;;
    --to) DESTS+=("${2:?}"); shift 2 ;;
    --sync) SYNC=1; shift ;;
    --now) NOW=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done
[[ $EUID -eq 0 ]] || die "Run this as root (in the Proxmox container console you already are root)."
have_systemd() { [[ -d /run/systemd/system ]]; }

if [[ $UNINSTALL -eq 1 ]]; then
  if have_systemd; then systemctl disable --now nas-uploader-drive.timer >/dev/null 2>&1 || true; fi
  rm -f /etc/systemd/system/nas-uploader-drive.service /etc/systemd/system/nas-uploader-drive.timer /etc/cron.d/nas-uploader-drive "$RUNNER" "$JOBS"
  rm -rf /var/lib/nas-uploader-drive
  ok "Daily Drive copy stopped. The copied files are still on the NAS; the key is in $KEY_DIR/drive-key.json (delete it if you like)."
  exit 0
fi

[[ ${#FOLDERS[@]} -gt 0 ]] || die "Give at least one --folder <ID or URL> --to <NAS folder>. See --help."
[[ ${#FOLDERS[@]} -eq ${#DESTS[@]} ]] || die "Each --folder needs its own --to."
RUN_USER="$(cat "$STATE_DIR/run-user" 2>/dev/null || echo www-data)"
RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || echo www-data)"
NAS_ROOT="$(cat "$STATE_DIR/folder" 2>/dev/null || true)"
mkdir -p "$KEY_DIR"
chown "root:$RUN_GROUP" "$KEY_DIR" && chmod 750 "$KEY_DIR"
if [[ -z "$TEST_SOURCE" ]]; then
  if [[ -n "$KEY" ]]; then
    [[ -f "$KEY" ]] || die "Key file not found: $KEY"
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("type")=="service_account" and d.get("client_email")' "$KEY" 2>/dev/null \
      || die "$KEY isn't a service account key (.json from Google Cloud → Service accounts → Keys)."
    install -m 640 -o root -g "$RUN_GROUP" "$KEY" "$KEY_DIR/drive-key.json"
    [[ "$(realpath "$KEY")" == "$KEY_DIR/drive-key.json" ]] || rm -f "$KEY"
  fi
  [[ -f "$KEY_DIR/drive-key.json" ]] || die "Give the service account key with --key FILE."
  SA_EMAIL="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["client_email"])' "$KEY_DIR/drive-key.json")"
fi

say "Installing rclone"
command -v rclone >/dev/null || { apt-get update -qq && apt-get install -y -qq rclone >/dev/null; } || die "Couldn't install rclone."
ok "rclone $(rclone version 2>/dev/null | head -1 | awk '{print $2}')"

# Copied files belong to the user the WebDAV server runs as, so they look like any upload.
: > "$JOBS.new"
for i in "${!FOLDERS[@]}"; do
  id="${FOLDERS[$i]}"
  id="${id##*/folders/}"; id="${id%%\?*}"; id="${id%%/*}"
  [[ "$id" =~ ^[A-Za-z0-9_-]{10,}$ ]] || [[ -n "$TEST_SOURCE" ]] || die "\"${FOLDERS[$i]}\" doesn't look like a Drive folder ID or link."
  dest="$(realpath -m "${DESTS[$i]}")"
  if [[ -n "$NAS_ROOT" && "$dest" != "$NAS_ROOT"/* ]]; then die "$dest is not inside the folder the NAS shares ($NAS_ROOT), so the extension couldn't see it."; fi
  mkdir -p "$dest"
  chown "$RUN_USER:" "$dest" 2>/dev/null || true
  printf '%s\t%s\n' "$id" "$dest" >> "$JOBS.new"
done
mv "$JOBS.new" "$JOBS"
chmod 600 "$JOBS"

MODE=copy
[[ $SYNC -eq 1 ]] && MODE=sync
WORK_DIR=/var/lib/nas-uploader-drive
mkdir -p "$WORK_DIR" && touch "$WORK_DIR/rclone.conf"
chown -R "$RUN_USER:$RUN_GROUP" "$WORK_DIR" && chmod 700 "$WORK_DIR"
cat > "$RUNNER" <<RUN
#!/usr/bin/env bash
# Copies each Drive folder in $JOBS to the NAS (written by setup-drive-copy.sh).
set -uo pipefail
status=0
while IFS=\$'\\t' read -r id dest; do
  [[ -n "\$id" ]] || continue
  if [[ -n "$TEST_SOURCE" ]]; then src="$TEST_SOURCE/\$id"; else src=":drive,scope=drive.readonly,service_account_file=$KEY_DIR/drive-key.json,root_folder_id=\$id:"; fi
  # Google Docs/Sheets/Slides are saved as Word/Excel/PowerPoint so they can be read and searched.
  # rclone runs as the WebDAV user, with its own home (it must not look at root's).
  setpriv --reuid="$RUN_USER" --regid="\$(id -g "$RUN_USER")" --init-groups -- \\
    env HOME="$WORK_DIR" RCLONE_CONFIG="$WORK_DIR/rclone.conf" \\
    rclone $MODE "\$src" "\$dest" --drive-export-formats docx,xlsx,pptx,pdf --transfers 4 --log-level NOTICE || status=1
done < "$JOBS"
exit \$status
RUN
chmod 700 "$RUNNER"

if have_systemd; then
  cat > /etc/systemd/system/nas-uploader-drive.service <<UNIT
[Unit]
Description=Project Assistant: copy Google Drive folders to the NAS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Nice=10
ExecStart=$RUNNER
UNIT
  cat > /etc/systemd/system/nas-uploader-drive.timer <<UNIT
[Unit]
Description=Copy Google Drive folders to the NAS, daily

[Timer]
OnCalendar=*-*-* 03:17
OnBootSec=30min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now nas-uploader-drive.timer >/dev/null
else
  echo "17 3 * * * root $RUNNER >/dev/null 2>&1" > /etc/cron.d/nas-uploader-drive
fi
ok "Daily copy set up ($MODE): $(wc -l < "$JOBS") folder(s)"

say "Copying now"
if "$RUNNER"; then
  ok "Copied."
else
  if [[ -z "$TEST_SOURCE" ]]; then
    warn "The copy reported errors. Check that each folder is shared with $SA_EMAIL (Viewer) and that the Google Drive API is enabled for its project."
  else
    warn "The copy reported errors."
  fi
  exit 1
fi
echo
echo "In the extension: Settings → Project folders → \"Folders that are only on the NAS\", add:"
while IFS=$'\t' read -r _ dest; do
  if [[ -n "$NAS_ROOT" ]]; then echo "  ${dest#"$NAS_ROOT"}"; else echo "  $dest (as a path inside the folder the NAS shares)"; fi
done < "$JOBS"
