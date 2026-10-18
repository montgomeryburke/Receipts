#!/usr/bin/env bash
# Packs the extension folder into nas-uploader-extension.zip (with the example config.js — fill it in after unzipping).
set -euo pipefail
cd "$(dirname "$0")"
rm -f nas-uploader-extension.zip
python3 - <<'PY'
import os, zipfile
with zipfile.ZipFile('nas-uploader-extension.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk('extension'):
        for f in sorted(files):
            p = os.path.join(root, f)
            z.write(p, os.path.join('nas-uploader', os.path.relpath(p, 'extension')))
print('wrote nas-uploader-extension.zip')
PY
