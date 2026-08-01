#!/bin/bash
# Double-click this file to start netscan on macOS.
# (If macOS blocks it the first time: right-click → Open, or run
#  `chmod +x "Start netscan (Mac).command"` once in Terminal.)

cd "$(dirname "$0")" || exit 1

if ! command -v node >/dev/null 2>&1; then
  echo
  echo "  Node.js is not installed."
  echo "  Install the 'LTS' version from https://nodejs.org then try again."
  echo
  read -r -p "  Press Return to close." _
  exit 1
fi

# Open the browser on this computer a moment after the server starts.
( sleep 1.5; open "http://localhost:8137" >/dev/null 2>&1 ) &

HOST=0.0.0.0 node server.js

echo
read -r -p "  netscan stopped. Press Return to close." _
