#!/usr/bin/env bash
# Writes one text file with every source file of the extension and the server script, for an AI code review
# (e.g. paste or upload into Gemini together with the prompt in GEMINI_QA.md).
#   ./build-review-bundle.sh [output-file]      (default: nas-uploader-review-bundle.txt)
set -euo pipefail
cd "$(dirname "$0")"
out="${1:-nas-uploader-review-bundle.txt}"
{
  echo "NAS Uploader: complete source for review ($(git log -1 --format='%h %cd' --date=short 2>/dev/null || date +%F))"
  echo "Files: extension/ (Chrome extension, Manifest V3) and server/setup-webdav.sh (Proxmox container setup)."
  echo "Tests live in tests/ in the repository and are not included here."
  for f in extension/manifest.json extension/config.js extension/background.js extension/app.html extension/app.css \
           extension/app.js extension/lib/*.js server/setup-webdav.sh; do
    printf '\n\n===== FILE: %s (%s lines) =====\n' "$f" "$(wc -l < "$f")"
    cat "$f"
  done
} > "$out"
echo "wrote $out ($(wc -l < "$out") lines)"
