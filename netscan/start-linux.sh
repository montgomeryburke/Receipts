#!/bin/bash
# Start netscan on Linux (also works in Termux on Android).
cd "$(dirname "$0")" || exit 1

if ! command -v node >/dev/null 2>&1; then
  echo
  echo "  Node.js is not installed."
  echo "  On Termux (Android):  pkg install nodejs"
  echo "  On desktop Linux:     install 'nodejs' with your package manager,"
  echo "                        or get it from https://nodejs.org"
  echo
  exit 1
fi

# Try to open a browser on desktop Linux (ignored on Termux/headless).
( sleep 1.5; command -v xdg-open >/dev/null 2>&1 && xdg-open "http://localhost:8137" >/dev/null 2>&1 ) &

HOST=0.0.0.0 node server.js
