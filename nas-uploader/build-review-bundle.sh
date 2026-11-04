#!/usr/bin/env bash
# Writes one text file with every source file of the extension and the server scripts, for an AI code review
# (e.g. paste or upload into Gemini together with the prompt in GEMINI_QA.md).
#   ./build-review-bundle.sh [output-file]      (default: nas-uploader-review-bundle.txt)
set -euo pipefail
cd "$(dirname "$0")"
out="${1:-nas-uploader-review-bundle.txt}"
{
  # The commit the code comes from, and whether the code has changes not committed yet (so the header can't mislead).
  rev="$(git log -1 --format='%h %cd' --date=short 2>/dev/null || date +%F)"
  if [ -n "$(git status --porcelain -- extension server 2>/dev/null)" ]; then rev="$rev + uncommitted changes"; fi
  echo "Project Assistant: complete source for review ($rev)"
  echo "Files: extension/ (Chrome extension, Manifest V3; third-party libraries in extension/vendor/ are left out),"
  echo "server/setup-webdav.sh (Proxmox container setup), server/assistant-ocr-index.py (OCR / mail / NAS-only text job"
  echo "on the NAS) and server/setup-drive-copy.sh (daily Google Drive copy with rclone)."
  echo "Tests live in tests/ in the repository and are not included here."
  for f in extension/manifest.json extension/config.js extension/background.js extension/engine.html extension/engine.js \
           extension/app.html extension/app.css extension/app.js extension/sidepanel.html extension/sidepanel.css extension/sidepanel.js \
           extension/options.html extension/options.js extension/meeting.html extension/meeting.css extension/meeting.js \
           extension/recorder.html extension/recorder.css extension/recorder.js \
           extension/agent.html extension/agent.css extension/agent.js \
           extension/content/*.js extension/lib/*.js server/setup-webdav.sh server/assistant-ocr-index.py server/setup-drive-copy.sh; do
    printf '\n\n===== FILE: %s (%s lines) =====\n' "$f" "$(wc -l < "$f")"
    cat "$f"
  done
} > "$out"
echo "wrote $out ($(wc -l < "$out") lines)"
