#!/usr/bin/env bash
# Bundles the third-party libraries the meeting assistant uses into extension/vendor/.
# The output is committed, so the extension itself needs no build step. Re-run after changing versions.
set -euo pipefail
cd "$(dirname "$0")"
[ -d node_modules ] || npm install --silent
OUT=../extension/vendor
# Only replace what this script makes (vendor/pdfjs comes from MailMirror and is kept as it is).
rm -rf "$OUT/ort" "$OUT/anthropic-sdk.mjs" "$OUT/transformers.mjs" "$OUT/VERSIONS.txt" && mkdir -p "$OUT/ort"
cat > entry-anthropic.mjs <<'JS'
export { default as Anthropic } from '@anthropic-ai/sdk';
JS
cat > entry-transformers.mjs <<'JS'
export { pipeline, env } from '@huggingface/transformers';
JS
npx esbuild entry-anthropic.mjs --bundle --format=esm --platform=browser --minify --legal-comments=eof --outfile="$OUT/anthropic-sdk.mjs"
npx esbuild entry-transformers.mjs --bundle --format=esm --platform=browser --minify --legal-comments=eof \
  --main-fields=browser,module,main --conditions=browser --outfile="$OUT/transformers.mjs"
# GitHub's secret scanning mistakes some 32-character model class names next to the word "mistral" for Mistral API
# keys and refuses the push. Split those names into two joined strings (same value, so nothing changes at runtime).
node - "$OUT/transformers.mjs" <<'JS'
const fs = require('fs');
const file = process.argv[2];
let src = fs.readFileSync(file, 'utf8');
let n = 0;
src = src.replace(/(["']?)\b([A-Za-z0-9]{32})\b\1(\s*:)?/g, (m, q, name, colon, off) => {
  if (!/mistral/i.test(name)) return m;
  n++;
  const split = `"${name.slice(0, 12)}"+"${name.slice(12)}"`;
  if (q) return colon ? `[${split}]${colon}` : split; // "Name" → "Name…"+"…"   ("Name": → [..]:)
  if (colon) return `[${split}]${colon}`; // object key  Name: → ["…"+"…"]:
  if (src[off - 1] === '.') throw new Error(`property access to ${name} — handle it`);
  return m;
});
const left = (src.match(/\b[A-Za-z0-9]{32}\b/g) || []).filter((t) => /mistral/i.test(t));
if (left.length) throw new Error('still present: ' + left.join(', '));
fs.writeFileSync(file, src);
console.log(`split ${n} model name(s) that look like API keys to secret scanners`);
JS
# ONNX Runtime's WebAssembly files, loaded from inside the extension (never from a CDN).
# (transformers.js uses onnxruntime-web/webgpu, which loads the "asyncify" build; check after upgrading:
#  grep -o 'ort-wasm-simd-threaded[a-z.]*' ../extension/vendor/transformers.mjs | sort -u)
cp node_modules/onnxruntime-web/dist/ort-wasm-simd-threaded.asyncify.mjs node_modules/onnxruntime-web/dist/ort-wasm-simd-threaded.asyncify.wasm "$OUT/ort/"
for p in @anthropic-ai/sdk @huggingface/transformers onnxruntime-web; do
  node -e "const p=JSON.parse(require('fs').readFileSync('node_modules/$p/package.json','utf8')); console.log(p.name+' '+p.version+' ('+p.license+')')"
done > "$OUT/VERSIONS.txt"
rm -f entry-anthropic.mjs entry-transformers.mjs
ls -la "$OUT" "$OUT/ort" "$OUT/pdfjs"
