#!/usr/bin/env bash
# Bundles the third-party libraries the meeting assistant uses into extension/vendor/.
# The output is committed, so the extension itself needs no build step. Re-run after changing versions.
set -euo pipefail
cd "$(dirname "$0")"
[ -d node_modules ] || npm install --silent
OUT=../extension/vendor
rm -rf "$OUT" && mkdir -p "$OUT/ort"
cat > entry-anthropic.mjs <<'JS'
export { default as Anthropic } from '@anthropic-ai/sdk';
JS
cat > entry-transformers.mjs <<'JS'
export { pipeline, env } from '@huggingface/transformers';
JS
npx esbuild entry-anthropic.mjs --bundle --format=esm --platform=browser --minify --legal-comments=eof --outfile="$OUT/anthropic-sdk.mjs"
npx esbuild entry-transformers.mjs --bundle --format=esm --platform=browser --minify --legal-comments=eof \
  --main-fields=browser,module,main --conditions=browser --outfile="$OUT/transformers.mjs"
# ONNX Runtime's WebAssembly files, loaded from inside the extension (never from a CDN).
cp node_modules/onnxruntime-web/dist/ort-wasm-simd-threaded.jsep.mjs node_modules/onnxruntime-web/dist/ort-wasm-simd-threaded.jsep.wasm \
   node_modules/onnxruntime-web/dist/ort-wasm-simd-threaded.mjs node_modules/onnxruntime-web/dist/ort-wasm-simd-threaded.wasm "$OUT/ort/"
for p in @anthropic-ai/sdk @huggingface/transformers onnxruntime-web; do
  node -e "const p=JSON.parse(require('fs').readFileSync('node_modules/$p/package.json','utf8')); console.log(p.name+' '+p.version+' ('+p.license+')')"
done > "$OUT/VERSIONS.txt"
rm -f entry-anthropic.mjs entry-transformers.mjs
ls -la "$OUT" "$OUT/ort"
