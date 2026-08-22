#!/usr/bin/env bash
# One-command setup for a Raspberry Pi that acts as:
#   * a private NAS on its USB drive, reachable from anywhere, and
#   * a Home Assistant voice assistant powered by Claude.
#
# Usage on the Pi:
#   curl -fsSL https://raw.githubusercontent.com/montgomeryburke/Receipts/claude/pi-nas-home-assistant-8ed8tw/pi/install.sh | sudo bash
#
# Flags (append with `| sudo bash -s -- --skip-ha` etc.):
#   --skip-usb      leave the USB drive alone
#   --format-usb    ERASE the USB drive and make a fresh ext4 filesystem
#   --skip-remote   do not set up Tailscale remote access
#   --funnel        publish the NAS to the public internet, not just your tailnet
#   --skip-ha       do not install Home Assistant
#   --skip-nas      do not install the NAS
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/montgomeryburke/Receipts.git}
REPO_BRANCH=${REPO_BRANCH:-claude/pi-nas-home-assistant-8ed8tw}

INSTALL_DIR=/opt/pi-nas
CONFIG_DIR=/etc/pi-nas
MOUNT_POINT=/srv/nas
SERVICE_USER=pinas
PORT=8765

DO_USB=1 DO_REMOTE=1 DO_HA=1 DO_NAS=1 FORMAT_USB=0 FUNNEL=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-usb)    DO_USB=0 ;;
    --format-usb)  FORMAT_USB=1 ;;
    --skip-remote) DO_REMOTE=0 ;;
    --skip-ha)     DO_HA=0 ;;
    --skip-nas)    DO_NAS=0; DO_USB=0; DO_REMOTE=0 ;;
    --funnel)      FUNNEL=1 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m xx\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this with sudo."
[[ -f /etc/os-release ]] || die "This installer targets Raspberry Pi OS / Debian."

# ---------------------------------------------------------------- get sources
# Works both from a git checkout and from `curl | sudo bash`, where there is no
# checkout to read from.
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/nas/app/main.py" ]]; then
  SOURCE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  say "Using local sources at $SOURCE"
else
  say "Fetching setup files"
  apt-get update -qq
  apt-get install -y -qq git
  WORKDIR=$(mktemp -d)
  trap 'rm -rf "$WORKDIR"' EXIT
  git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$WORKDIR/repo"
  SOURCE="$WORKDIR/repo/pi"
fi

say "Installing system packages"
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip curl ca-certificates

# ==========================================================================
#  NAS
# ==========================================================================
if [[ $DO_NAS -eq 1 ]]; then
  say "Creating the service account"
  id -u "$SERVICE_USER" >/dev/null 2>&1 ||
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"

  if [[ $DO_USB -eq 1 ]]; then
    say "Setting up the USB drive"
    USB_ARGS=()
    [[ $FORMAT_USB -eq 1 ]] && USB_ARGS+=(--format)
    MOUNT_POINT="$MOUNT_POINT" SERVICE_USER="$SERVICE_USER" \
      bash "$SOURCE/nas/scripts/setup-usb.sh" "${USB_ARGS[@]}"
  else
    mkdir -p "$MOUNT_POINT"
    chown "$SERVICE_USER:$SERVICE_USER" "$MOUNT_POINT"
    warn "Skipping USB setup — files will live on the SD card at $MOUNT_POINT"
  fi

  say "Installing the file server"
  mkdir -p "$INSTALL_DIR"
  cp -r "$SOURCE/nas/app" "$INSTALL_DIR/"
  python3 -m venv "$INSTALL_DIR/venv"
  "$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
  "$INSTALL_DIR/venv/bin/pip" install --quiet -r "$SOURCE/nas/requirements.txt"

  install -m 0755 "$SOURCE/nas/scripts/pi-nas-token" /usr/local/bin/pi-nas-token

  mkdir -p "$CONFIG_DIR"
  chmod 0750 "$CONFIG_DIR"
  if [[ ! -f "$CONFIG_DIR/config.env" ]]; then
    cat > "$CONFIG_DIR/config.env" <<ENV
# pi-nas configuration. Restart after editing:  sudo systemctl restart pi-nas
PI_NAS_ROOT=$MOUNT_POINT
PI_NAS_TOKENS_FILE=$CONFIG_DIR/tokens.json
PI_NAS_MAX_UPLOAD_BYTES=21474836480

# Lock the API to one Chrome extension by putting its ID here (the extension's
# settings page shows it). Empty means any extension holding a valid token.
PI_NAS_ALLOWED_EXTENSION_IDS=

# Extra browser origins allowed to call the API, comma separated.
PI_NAS_EXTRA_ORIGINS=
ENV
    chmod 0640 "$CONFIG_DIR/config.env"
  fi

  # The service runs as pinas and must be able to read its own config.
  chown -R root:"$SERVICE_USER" "$CONFIG_DIR"

  NEW_TOKEN=""
  if [[ ! -f "$CONFIG_DIR/tokens.json" ]]; then
    say "Creating your access token"
    NEW_TOKEN=$(PI_NAS_TOKENS_FILE="$CONFIG_DIR/tokens.json" \
      "$INSTALL_DIR/venv/bin/python" - <<'PY'
import os, sys
sys.path.insert(0, "/opt/pi-nas")
from pathlib import Path
from app.auth import add_token
print(add_token(Path(os.environ["PI_NAS_TOKENS_FILE"]), "my-devices", ["read", "write"]))
PY
)
    chown root:"$SERVICE_USER" "$CONFIG_DIR/tokens.json"
    chmod 0640 "$CONFIG_DIR/tokens.json"
  fi

  say "Starting the pi-nas service"
  sed "s|^ReadWritePaths=.*|ReadWritePaths=$MOUNT_POINT|" \
    "$SOURCE/nas/systemd/pi-nas.service" > /etc/systemd/system/pi-nas.service
  systemctl daemon-reload
  systemctl enable --now pi-nas

  sleep 2
  if curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null; then
    info "File server is up and answering on port $PORT"
  else
    warn "The service did not answer. Check:  sudo journalctl -u pi-nas -n 50"
  fi

  if [[ $DO_REMOTE -eq 1 ]]; then
    say "Setting up remote access"
    REMOTE_ARGS=()
    [[ $FUNNEL -eq 1 ]] && REMOTE_ARGS+=(--funnel)
    LOCAL_PORT=$PORT bash "$SOURCE/nas/scripts/setup-remote-access.sh" "${REMOTE_ARGS[@]}" || {
      warn "Remote access setup did not finish. Rerun it later with:"
      info "sudo bash $SOURCE/nas/scripts/setup-remote-access.sh"
    }
  fi
fi

# ==========================================================================
#  Home Assistant
# ==========================================================================
if [[ $DO_HA -eq 1 ]]; then
  say "Installing Home Assistant and the local voice pipeline"
  bash "$SOURCE/homeassistant/scripts/install-ha.sh" || {
    warn "Home Assistant setup did not finish. Rerun it with:"
    info "sudo bash $SOURCE/homeassistant/scripts/install-ha.sh"
  }
fi

# ==========================================================================
#  Summary
# ==========================================================================
IP=$(hostname -I | awk '{print $1}')
NAS_URL="http://$IP:$PORT"
if command -v tailscale >/dev/null 2>&1; then
  TS_NAME=$(tailscale status --json 2>/dev/null |
    python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)
  [[ -n ${TS_NAME:-} ]] && NAS_URL="https://$TS_NAME"
fi

cat <<SUMMARY

╭──────────────────────────────────────────────────────────────╮
│  Setup complete                                              │
╰──────────────────────────────────────────────────────────────╯

SUMMARY

if [[ $DO_NAS -eq 1 ]]; then
  echo "  NAS address       $NAS_URL"
  echo "  Files stored in   $MOUNT_POINT"
  if [[ -n ${NEW_TOKEN:-} ]]; then
    echo
    echo "  ACCESS TOKEN — copy this now, it is not shown again:"
    echo
    echo "      $NEW_TOKEN"
  else
    echo "  Access token      already set up (make another: sudo pi-nas-token add <name>)"
  fi
  echo
  echo "  Next: load the Chrome extension from the pi/extension folder"
  echo "        (chrome://extensions > Developer mode > Load unpacked),"
  echo "        then paste the address and token into its settings."
fi

if [[ $DO_HA -eq 1 ]]; then
  echo
  echo "  Home Assistant    http://$IP:8123"
  echo "  Next: finish onboarding, then add the 'Claude Assist' integration"
  echo "        with an Anthropic API key from console.anthropic.com."
fi

echo
echo "  Useful commands:"
echo "    sudo systemctl status pi-nas       service health"
echo "    sudo journalctl -u pi-nas -f       live logs"
echo "    sudo pi-nas-token list             show tokens"
echo "    sudo pi-nas-token add <name>       mint another token"
echo "    sudo pi-nas-token revoke <name>    revoke one"
echo
