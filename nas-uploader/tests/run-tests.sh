#!/usr/bin/env bash
# Runs the full end-to-end suite: builds the dataset, starts the WebDAV servers, runs Chromium tests.
#   ./run-tests.sh [test-name-filter]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${NAS_TEST_WORK:-$(mktemp -d)}"
export NAS_TEST_WORK="$WORK"
cd "$HERE"
[ -d node_modules/playwright ] || PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --silent
[ -d "$WORK/dataset" ] || node make-dataset.cjs "$WORK/dataset" ${NO_BIG:+--no-big}
./start-servers.sh
trap './stop-servers.sh >/dev/null' EXIT
node e2e.cjs "${1:-}"
