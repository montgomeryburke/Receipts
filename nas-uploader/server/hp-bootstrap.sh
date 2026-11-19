#!/usr/bin/env bash
# =============================================================================
#  Project Assistant — set up the HP in one go, from the Proxmox host (pve → Shell):
#
#    bash <(curl -fsSL https://raw.githubusercontent.com/montgomeryburke/Receipts/claude/friendly-pasteur-uixwht/nas-uploader/server/hp-bootstrap.sh)
#
#  Sets up the NAS container (101 unless --nas-ct): WebDAV for the extension through Tailscale Funnel, the OCR
#  job for scanned PDFs and .pst mailboxes, and commands from Project Assistant (limited user, logged). Then
#  prints what to paste into the extension, and the command login (for Settings → Run on the HP, and for
#  Claude to do HP jobs for you). The assistant's AI is Claude and Gemini; nothing AI runs on the HP.
#
#  Options: --nas-ct ID  --folder PATH  --access funnel|local  --dry-run
#  Safe to run again. Nothing outside the NAS container is changed.
# =============================================================================
set -euo pipefail
SRC="${HP_BOOTSTRAP_SRC:-https://raw.githubusercontent.com/montgomeryburke/Receipts/claude/friendly-pasteur-uixwht/nas-uploader/server}"
NAS_CT=101
FOLDER=""
ACCESS="funnel"
DRY=0

say()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m ✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nas-ct) NAS_CT="${2:?}"; shift 2 ;;
    --folder) FOLDER="${2:?}"; shift 2 ;;
    --access) ACCESS="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" 2>/dev/null | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) die "Unknown option $1 (see --help)" ;;
  esac
done
[[ "$NAS_CT" =~ ^[0-9]+$ ]] || die "--nas-ct must be a container number"
[[ "$ACCESS" =~ ^(funnel|local)$ ]] || die "--access must be funnel or local"
[[ -z "$FOLDER" || "$FOLDER" =~ ^/[A-Za-z0-9._/@+-]+$ ]] || die "--folder must be an absolute path"
command -v pct >/dev/null || die "Run this on the Proxmox host itself (web interface → pve → Shell), not inside a container."
[[ $EUID -eq 0 || $DRY -eq 1 ]] || die "Run it as root (the Proxmox shell is root)."

# Changes go through change(); --dry-run only prints them. Looking around (pct list, status, checks) always runs.
change() { if [[ $DRY -eq 1 ]]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }
running() { pct status "$1" 2>/dev/null | grep -q 'status: running'; }
in_ct() { local id="$1"; shift; pct exec "$id" -- bash -c "$*"; }

say "Containers on this HP"
pct list
running "$NAS_CT" || die "Container $NAS_CT (the NAS) isn't running. Start it, or pass --nas-ct with the right number."
ok "NAS container: $NAS_CT"

say "NAS container $NAS_CT: WebDAV, Funnel, OCR, commands"
if [[ -z "$FOLDER" ]] && in_ct "$NAS_CT" 'test -d /mnt/mirror'; then FOLDER=/mnt/mirror; fi
args=(--access "$ACCESS" --enable-commands --no-llm)
[[ -n "$FOLDER" ]] && args+=(--folder "$FOLDER" --yes)
change in_ct "$NAS_CT" "command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl >/dev/null; }; curl -fsSL '$SRC/setup-webdav.sh' -o /root/setup-webdav.sh"
change pct exec "$NAS_CT" -- bash /root/setup-webdav.sh "${args[@]}"

say "Done. Paste these into the extension (NAS files → Connect, and Settings → Run on the HP):"
change pct exec "$NAS_CT" -- cat /root/nas-uploader-settings.txt
cat <<'EOF'

To let Claude do HP jobs for you from now on: give Claude the NAS address above (not the password); it opens a
secure form where you save the "command login" shown above. It can then run commands in the NAS container (as the
limited user nas-runner, every command logged in /var/log/nas-uploader-commands.log). To take that back:
  pct exec <NAS container> -- bash /root/setup-webdav.sh --disable-commands
EOF
