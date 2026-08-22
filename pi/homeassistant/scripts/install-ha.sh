#!/usr/bin/env bash
# Install Home Assistant with a local voice pipeline and the Claude agent.
set -euo pipefail

HA_DIR=${HA_DIR:-/opt/homeassistant}
SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"

# ------------------------------------------------------------------- docker
if ! command -v docker >/dev/null 2>&1; then
  say "Installing Docker"
  curl -fsSL https://get.docker.com | sh
  # So the login user can run docker without sudo after the next login.
  [[ -n ${SUDO_USER:-} ]] && usermod -aG docker "$SUDO_USER" || true
fi
systemctl enable --now docker

docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"

# -------------------------------------------------------------------- files
say "Installing to $HA_DIR"
mkdir -p "$HA_DIR/config/custom_components" "$HA_DIR/config/packages"
cp "$SOURCE_DIR/docker-compose.yml" "$HA_DIR/"
cp -r "$SOURCE_DIR/custom_components/claude_assist" "$HA_DIR/config/custom_components/"
cp "$SOURCE_DIR/config/packages/voice_assistant.yaml" "$HA_DIR/config/packages/"

# Environment: timezone and model sizes. A Pi 5 can afford a better STT model.
if [[ ! -f $HA_DIR/.env ]]; then
  TZ_VALUE=$(timedatectl show -p Timezone --value 2>/dev/null || echo "Etc/UTC")
  MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  WHISPER_MODEL=tiny-int8
  [[ $MEM_KB -gt 6000000 ]] && WHISPER_MODEL=base-int8
  cat > "$HA_DIR/.env" <<ENV
TZ=$TZ_VALUE
WHISPER_MODEL=$WHISPER_MODEL
PIPER_VOICE=en_US-lessac-medium
WAKE_WORD=ok_nabu
VOICE_LANGUAGE=en
ENV
  say "Wrote $HA_DIR/.env (speech model: $WHISPER_MODEL)"
fi

# --------------------------------------------------------------- packages
# Home Assistant writes configuration.yaml on first run; only add the packages
# include, and only if it is not already there.
CONFIG_FILE="$HA_DIR/config/configuration.yaml"
if [[ -f $CONFIG_FILE ]] && ! grep -q "packages:" "$CONFIG_FILE"; then
  say "Enabling the packages directory in configuration.yaml"
  printf '\nhomeassistant:\n  packages: !include_dir_named packages\n' >> "$CONFIG_FILE"
fi

# ----------------------------------------------------------------- start up
say "Starting the stack (first run pulls several images — this takes a while)"
cd "$HA_DIR"
docker compose pull
docker compose up -d

IP=$(hostname -I | awk '{print $1}')
echo
say "Home Assistant is starting at:  http://${IP}:8123"
echo
echo "  It needs a minute or two on first boot. Then:"
echo "   1. Create your Home Assistant account in the browser."
echo "   2. Settings > Devices & Services > Add Integration > 'Claude Assist'"
echo "      and paste an Anthropic API key from console.anthropic.com."
echo "   3. Settings > Voice assistants > Add assistant:"
echo "        Conversation agent : Claude Assist"
echo "        Speech-to-text     : faster-whisper"
echo "        Text-to-speech     : piper"
echo "        Wake word          : openWakeWord (ok_nabu)"
echo "   4. Settings > Voice assistants > Expose — choose which devices Claude"
echo "      is allowed to see and control."
echo
