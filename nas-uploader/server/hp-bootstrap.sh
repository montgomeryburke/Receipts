#!/usr/bin/env bash
# =============================================================================
#  Project Assistant — set up the HP in one go, from the Proxmox host (pve → Shell):
#
#    bash <(curl -fsSL https://raw.githubusercontent.com/montgomeryburke/Receipts/claude/friendly-pasteur-uixwht/nas-uploader/server/hp-bootstrap.sh)
#
#  1. The local AI container (a container named like "llm" or "ollama" with Ollama in it): Ollama listens on
#     the network, reads 16k tokens at once, and has the model (qwen2.5:7b unless --model).
#  2. The NAS container (101 unless --nas-ct): WebDAV for the extension through Tailscale Funnel, the OCR job,
#     the local model at <NAS address>/.llm/, and commands from Project Assistant (limited user, logged).
#  3. Prints what to paste into the extension, and the command login (for Settings → Run on the HP, and for
#     Claude to do HP jobs for you).
#
#  Options: --nas-ct ID  --llm-ct ID  --model NAME  --folder PATH  --access funnel|local  --no-llm  --dry-run
#  Safe to run again. Nothing outside those two containers is changed.
# =============================================================================
set -euo pipefail
SRC="${HP_BOOTSTRAP_SRC:-https://raw.githubusercontent.com/montgomeryburke/Receipts/claude/friendly-pasteur-uixwht/nas-uploader/server}"
NAS_CT=101
LLM_CT=""
MODEL="qwen2.5:7b"
FOLDER=""
ACCESS="funnel"
NO_LLM=0
DRY=0

say()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m ✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nas-ct) NAS_CT="${2:?}"; shift 2 ;;
    --llm-ct) LLM_CT="${2:?}"; shift 2 ;;
    --model) MODEL="${2:?}"; shift 2 ;;
    --folder) FOLDER="${2:?}"; shift 2 ;;
    --access) ACCESS="${2:?}"; shift 2 ;;
    --no-llm) NO_LLM=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" 2>/dev/null | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) die "Unknown option $1 (see --help)" ;;
  esac
done
[[ "$NAS_CT" =~ ^[0-9]+$ ]] || die "--nas-ct must be a container number"
[[ -z "$LLM_CT" || "$LLM_CT" =~ ^[0-9]+$ ]] || die "--llm-ct must be a container number"
[[ "$MODEL" =~ ^[A-Za-z0-9._:/-]+$ ]] || die "--model looks wrong"
[[ "$ACCESS" =~ ^(funnel|local)$ ]] || die "--access must be funnel or local"
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

# ---------------------------------------------------------------------------- the local AI container
LLM_URL=""
if [[ $NO_LLM -eq 0 ]]; then
  if [[ -z "$LLM_CT" ]]; then
    LLM_CT="$(pct list | awk 'NR > 1 && tolower($NF) ~ /llm|ollama/ { print $1; exit }')"
  fi
  if [[ -z "$LLM_CT" ]]; then
    warn "No container named like \"llm\" or \"ollama\": skipping the local model (use --llm-ct ID to pick one)."
  elif ! running "$LLM_CT"; then
    warn "Container $LLM_CT (local AI) isn't running: skipping the local model. Start it and run this again."
  elif ! in_ct "$LLM_CT" 'command -v ollama >/dev/null'; then
    warn "Container $LLM_CT has no Ollama: skipping the local model (install it there: curl -fsSL https://ollama.com/install.sh | sh)."
  else
    say "Local AI in container $LLM_CT: listen on the network, read 16k tokens, model $MODEL"
    change in_ct "$LLM_CT" 'mkdir -p /etc/systemd/system/ollama.service.d && printf "[Service]\nEnvironment=\"OLLAMA_HOST=0.0.0.0\"\nEnvironment=\"OLLAMA_CONTEXT_LENGTH=16384\"\n" > /etc/systemd/system/ollama.service.d/project-assistant.conf && systemctl daemon-reload && systemctl restart ollama'
    change in_ct "$LLM_CT" 'for i in $(seq 60); do curl -sf http://127.0.0.1:11434/api/tags >/dev/null && exit 0; sleep 1; done; echo "Ollama did not come back up" >&2; exit 1'
    change in_ct "$LLM_CT" "ollama list | awk 'NR>1{print \$1}' | grep -qx '$MODEL' || ollama pull '$MODEL'"
    ip="$(pct exec "$LLM_CT" -- hostname -I 2>/dev/null | awk '{print $1}')"
    [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "Couldn't find the address of container $LLM_CT."
    LLM_URL="http://$ip:11434"
    ok "Local AI: $LLM_URL ($MODEL)"
  fi
fi

# ---------------------------------------------------------------------------- the NAS container
say "NAS container $NAS_CT: WebDAV, Funnel, OCR, local model, commands"
if [[ -z "$FOLDER" ]] && in_ct "$NAS_CT" 'test -d /mnt/mirror'; then FOLDER=/mnt/mirror; fi
args=(--access "$ACCESS" --enable-commands)
[[ -n "$FOLDER" ]] && args+=(--folder "$FOLDER" --yes)
[[ -n "$LLM_URL" ]] && args+=(--llm-url "$LLM_URL")
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
