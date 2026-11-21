// Builds the folder trees that the end-to-end tests drag onto the NAS.
// Usage: node make-dataset.cjs <outDir> [--no-big]
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const out = path.resolve(process.argv[2] || 'dataset');
const noBig = process.argv.includes('--no-big');

// Deterministic pseudo-random bytes so runs are reproducible.
function prng(seed) {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13;
    s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5;
    s >>>= 0;
    return s;
  };
}
function bytes(n, seed) {
  const r = prng(seed);
  const b = Buffer.alloc(n);
  for (let i = 0; i < n; i += 4) {
    const v = r();
    b[i] = v & 255;
    if (i + 1 < n) b[i + 1] = (v >> 8) & 255;
    if (i + 2 < n) b[i + 2] = (v >> 16) & 255;
    if (i + 3 < n) b[i + 3] = (v >> 24) & 255;
  }
  return b;
}
function write(p, data) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, data);
}

const SPECIAL = [
  'hash#tag.txt',
  'percent%41 literal.txt',
  'percent%2Fnot-a-slash.txt',
  'question?mark.txt',
  'amp&plus+equals=.txt',
  'semi;colon,comma.txt',
  '[brackets] (parens) {braces}.txt',
  "quote'apostrophe.txt",
  'dollar$ at@ bang!.txt',
  'tilde~ caret^ backtick`.txt',
  'unicode café naïve 日本語 ✓.txt',
  'emoji 🎉📁.txt',
  'double  spaces.txt',
  ' leading space.txt',
  'trailing.dots..txt',
  'UPPER lower MiXeD.TXT',
  'x'.repeat(200) + '.txt',
];

function specialNames(root) {
  const dir = path.join(root, 'special names');
  SPECIAL.forEach((n, i) => write(path.join(dir, n), `content of ${n}\n` + bytes(100 + i * 37, 1000 + i).toString('base64')));
  write(path.join(dir, 'sub folder with spaces & #', 'file in it.txt'), 'nested special\n');
  write(path.join(dir, 'ünïcödé folder 日本', 'файл.txt'), 'cyrillic name\n');
  write(path.join(dir, 'percent%20folder', 'inside.txt'), 'literal %20 in folder name\n');
}

function junk(root) {
  write(path.join(root, '.DS_Store'), bytes(64, 7));
  write(path.join(root, 'Thumbs.db'), bytes(64, 8));
  write(path.join(root, 'many', 'desktop.ini'), '[.ShellClassInfo]\n');
  write(path.join(root, '._appledouble.txt'), bytes(32, 9));
}

function emptyDirs(root) {
  fs.mkdirSync(path.join(root, 'empty folder'), { recursive: true });
  fs.mkdirSync(path.join(root, 'nested empty', 'inner empty', 'innermost empty'), { recursive: true });
}

function deep(root, levels) {
  let p = path.join(root, 'deep');
  for (let i = 1; i <= levels; i++) p = path.join(p, `level ${String(i).padStart(2, '0')}`);
  write(path.join(p, 'deepest.txt'), 'bottom of the tree\n');
  write(path.join(root, 'deep', 'level 01', 'shallow.txt'), 'near the top\n');
}

function many(root, dirs, perDir, seed) {
  for (let d = 0; d < dirs; d++) {
    for (let f = 0; f < perDir; f++) {
      const size = (d * 7919 + f * 104729) % 20000;
      write(path.join(root, 'many', `batch ${String(d).padStart(3, '0')}`, `file-${String(f).padStart(4, '0')}.dat`), bytes(size, seed + d * 1000 + f));
    }
  }
}

function bigRandomFile(p, size) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const fd = fs.openSync(p, 'w');
  const chunk = 16 * 1024 * 1024;
  for (let written = 0; written < size; written += chunk) {
    fs.writeSync(fd, crypto.randomBytes(Math.min(chunk, size - written)));
  }
  fs.closeSync(fd);
}

fs.rmSync(out, { recursive: true, force: true });

// 1) Full dataset — the main drag & drop test.
const full = path.join(out, 'full', 'Project Archive');
write(path.join(full, 'README.txt'), 'Top level readme\n');
write(path.join(full, 'zero-bytes.dat'), Buffer.alloc(0));
specialNames(full);
emptyDirs(full);
deep(full, 15);
many(full, 40, 50, 1);
for (let i = 0; i < 4; i++) write(path.join(full, 'media', `clip-${i + 1}.bin`), bytes((8 + i * 7) * 1024 * 1024 + i, 500 + i));
if (!noBig) bigRandomFile(path.join(full, 'big', 'disk-image-1.2GB.img'), 1288490189);
junk(full);

// 2) Small dataset — used against other servers and through the flaky proxy.
const small = path.join(out, 'small', 'Small Set');
write(path.join(small, 'notes.txt'), 'small set\n');
write(path.join(small, 'zero.dat'), Buffer.alloc(0));
specialNames(small);
emptyDirs(small);
deep(small, 6);
many(small, 6, 18, 77);
write(path.join(small, 'locked', 'FORBIDDEN-report.pdf'), bytes(5000, 4242));
junk(small);

// 3) Media dataset — slow uploads through the throttling proxy (pause/resume/cancel).
const media = path.join(out, 'media', 'Media Set');
for (let i = 0; i < 3; i++) write(path.join(media, `video-${i + 1}.mp4`), bytes(12 * 1024 * 1024 + i * 333, 9000 + i));

// 4) Huge sparse file (> 4 GB) to prove there is no 32-bit size limit anywhere.
if (!noBig) {
  const huge = path.join(out, 'huge', 'backup-5GB.tar');
  fs.mkdirSync(path.dirname(huge), { recursive: true });
  const fd = fs.openSync(huge, 'w');
  fs.writeSync(fd, Buffer.from('HEADER-' + 'h'.repeat(1000)), 0, 1007, 0);
  const size = 5 * 1024 * 1024 * 1024 + 12345;
  fs.writeSync(fd, Buffer.from('-TRAILER'), 0, 8, size - 8);
  fs.closeSync(fd);
}

// 5) Stress test: 20,000 tiny files in 200 folders (checks nothing slows down quadratically).
const stress = path.join(out, 'stress', 'Twenty Thousand');
for (let dIdx = 0; dIdx < 200; dIdx++) {
  const dir = path.join(stress, `group ${String(dIdx).padStart(3, '0')}`);
  fs.mkdirSync(dir, { recursive: true });
  for (let f = 0; f < 100; f++) fs.writeFileSync(path.join(dir, `item-${f}.txt`), `group ${dIdx} item ${f}\n`.repeat((f % 5) + 1));
}

// 6) A single loose file for the "Choose files" button.
write(path.join(out, 'loose', 'single file.pdf'), bytes(250000, 31337));

console.log('dataset ready in', out);
