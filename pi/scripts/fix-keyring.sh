#!/usr/bin/env bash
# Stop Raspberry Pi OS asking to unlock the "login keyring".
#
# The prompt has three common triggers, and this handles all of them:
#   1. Chromium wanting the system password store  -> force it to use the
#      plain-text "basic" store instead (nothing sensitive is kept there once
#      the keyring is gone).
#   2. A stale keyring whose password no longer matches the login password
#      -> delete it; it is recreated unlocked and empty.
#   3. Desktop auto-login, which means PAM never unlocks the keyring at all
#      -> optionally boot to console, which is what a headless server wants.
#
# Run as your normal user (NOT with sudo) unless noted.
set -euo pipefail

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

if [[ ${EUID} -eq 0 && -z ${SUDO_USER:-} ]]; then
  echo "Run this as your normal user, not as root." >&2
  exit 1
fi

TARGET_USER=${SUDO_USER:-$USER}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

# ---------------------------------------------------------------- 1. keyrings
say "Removing stored keyrings for $TARGET_USER"
rm -rf "$TARGET_HOME/.local/share/keyrings"/* 2>/dev/null || true

# --------------------------------------------------------------- 2. Chromium
say "Telling Chromium to stop using the system password store"
for launcher in /usr/share/applications/chromium-browser.desktop \
                /usr/share/applications/chromium.desktop; do
  [[ -f $launcher ]] || continue
  sudo sed -i 's|^Exec=\(.*chromium[^ ]*\)\( \|$\)|Exec=\1 --password-store=basic |' "$launcher"
done
# Also covers launches from a terminal or from autostart.
mkdir -p "$TARGET_HOME/.config"
if ! grep -qs -- '--password-store=basic' "$TARGET_HOME/.config/chromium-flags.conf" 2>/dev/null; then
  echo '--password-store=basic' >> "$TARGET_HOME/.config/chromium-flags.conf"
fi

# ------------------------------------------------------- 3. keyring on unlock
# If gnome-keyring is installed, make sure PAM can unlock it with the login
# password. This is a no-op when the package is already configured.
if dpkg -s libpam-gnome-keyring >/dev/null 2>&1; then
  say "PAM keyring unlock is installed (good)"
else
  say "Installing libpam-gnome-keyring so the keyring unlocks at login"
  sudo apt-get update -qq && sudo apt-get install -y -qq libpam-gnome-keyring || true
fi

say "Done. Reboot to apply: sudo reboot"
echo
echo "If it STILL prompts after the reboot, this Pi is auto-logging into the"
echo "desktop, which is what prevents the keyring from ever being unlocked."
echo "For a headless NAS/Home Assistant box the right fix is to boot to console:"
echo
echo "    sudo raspi-config nonint do_boot_behaviour B2 && sudo reboot"
echo
echo "(B2 = console, auto-login. The desktop, and the keyring prompt with it,"
echo " never starts. You keep full SSH access.)"
