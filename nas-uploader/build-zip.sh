#!/usr/bin/env bash
# Packs the extension folder into nas-uploader-extension.zip (with the example config.js — fill it in after unzipping).
# The folder inside stays "nas-uploader", so unzipping a new version over an old one keeps saved mirrors and settings.
set -euo pipefail
cd "$(dirname "$0")"
rm -f nas-uploader-extension.zip
python3 - <<'PY'
import os, zipfile
with zipfile.ZipFile('nas-uploader-extension.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk('extension'):
        dirs[:] = sorted(d for d in dirs if d != 'test-media')
        for f in sorted(files):
            p = os.path.join(root, f)
            z.write(p, os.path.join('nas-uploader', os.path.relpath(p, 'extension')))
print('wrote nas-uploader-extension.zip')
PY
