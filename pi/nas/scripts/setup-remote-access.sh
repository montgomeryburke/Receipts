#!/usr/bin/env bash
# Make the NAS reachable from outside the house — without opening a port on the
# router.
#
# Two modes:
#   (default)  tailscale serve  — reachable only by devices signed into your
#              own tailnet, over an encrypted WireGuard link, with a real
#              HTTPS certificate. Nothing is exposed to the public internet.
#   --funnel   tailscale funnel — additionally published to the public
#              internet at the same HTTPS name. Anyone can reach the URL, so
#              the access token becomes the only thing standing between a
#              stranger and your files.
#
# Port forwarding is deliberately not offered: it puts a home-built service
# directly on the public internet with your home IP attached to it.
set -euo pipefail

MODE=serve
LOCAL_PORT=${LOCAL_PORT:-8765}

while [[ $# -gt 0 ]]; do
  case $1 in
    --funnel) MODE=funnel; shift ;;
    --port) LOCAL_PORT=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"

if ! command -v tailscale >/dev/null 2>&1; then
  say "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled

if ! tailscale status >/dev/null 2>&1; then
  say "Sign in to Tailscale — open the URL below in any browser and log in."
  echo
  tailscale up
fi

say "Enabling HTTPS certificates for your tailnet"
tailscale cert --help >/dev/null 2>&1 || warn "tailscale cert unavailable; continuing"

# Reset any previous configuration so re-running is idempotent.
tailscale serve reset >/dev/null 2>&1 || true

say "Publishing 127.0.0.1:$LOCAL_PORT over HTTPS"
tailscale serve --bg --https=443 "http://127.0.0.1:${LOCAL_PORT}"

if [[ $MODE == funnel ]]; then
  warn "Enabling public internet access (Funnel)."
  warn "Your access token is now the ONLY protection on this URL."
  tailscale funnel --bg --https=443 "http://127.0.0.1:${LOCAL_PORT}"
fi

HOSTNAME_FQDN=$(tailscale status --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')

echo
say "Your NAS URL:"
echo
echo "    https://${HOSTNAME_FQDN}"
echo
if [[ $MODE == funnel ]]; then
  echo "  Reachable from anywhere on the internet."
else
  echo "  Reachable from any device signed into your tailnet."
  echo "  Install Tailscale on your laptop/phone and sign in with the same"
  echo "  account — then this URL works from anywhere in the world."
fi
echo
tailscale serve status || true
