// Minimal ZIP reader for Blobs/Files (Office documents, archive listings).
// Reads only the central directory plus the entries asked for, so listing a
// multi-GB archive costs a few KB of I/O. Supports ZIP64 and deflate via the
// browser's native DecompressionStream.

const SIG_EOCD = 0x06054b50;
const SIG_Z64_LOC = 0x07064b50;
const SIG_Z64_EOCD = 0x06064b50;
const SIG_CEN = 0x02014b50;
const SIG_LOC = 0x04034b50;

async function readBytes(blob, start, end) {
  return new DataView(await blob.slice(start, end).arrayBuffer());
}

const u64 = (dv, o) => dv.getUint32(o, true) + dv.getUint32(o + 4, true) * 2 ** 32;

export async function listZip(blob) {
  const size = blob.size;
  const tailLen = Math.min(size, 65557 + 20);
  const tail = await readBytes(blob, size - tailLen, size);
  let eocd = -1;
  for (let i = tail.byteLength - 22; i >= 0; i--) {
    if (tail.getUint32(i, true) === SIG_EOCD) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('not a zip file');
  let total = tail.getUint16(eocd + 10, true);
  let cdSize = tail.getUint32(eocd + 12, true);
  let cdOff = tail.getUint32(eocd + 16, true);
  if (total === 0xffff || cdSize === 0xffffffff || cdOff === 0xffffffff) {
    const loc = eocd - 20;
    if (loc >= 0 && tail.getUint32(loc, true) === SIG_Z64_LOC) {
      const z64Off = u64(tail, loc + 8);
      const z = await readBytes(blob, z64Off, z64Off + 56);
      if (z.getUint32(0, true) !== SIG_Z64_EOCD) throw new Error('bad zip64 record');
      total = u64(z, 32);
      cdSize = u64(z, 40);
      cdOff = u64(z, 48);
    }
  }
  const cd = await readBytes(blob, cdOff, cdOff + cdSize);
  const dec = new TextDecoder();
  const entries = [];
  let p = 0;
  for (let n = 0; n < total && p + 46 <= cd.byteLength; n++) {
    if (cd.getUint32(p, true) !== SIG_CEN) break;
    const method = cd.getUint16(p + 10, true);
    let csize = cd.getUint32(p + 20, true);
    let usize = cd.getUint32(p + 24, true);
    const nameLen = cd.getUint16(p + 28, true);
    const extraLen = cd.getUint16(p + 30, true);
    const commentLen = cd.getUint16(p + 32, true);
    let offset = cd.getUint32(p + 42, true);
    const name = dec.decode(new Uint8Array(cd.buffer, cd.byteOffset + p + 46, nameLen));
    // ZIP64 extra field holds the real values for any field set to 0xFFFFFFFF.
    let e = p + 46 + nameLen;
    const eEnd = e + extraLen;
    while (e + 4 <= eEnd) {
      const id = cd.getUint16(e, true);
      const len = cd.getUint16(e + 2, true);
      if (id === 0x0001) {
        let q = e + 4;
        if (usize === 0xffffffff) { usize = u64(cd, q); q += 8; }
        if (csize === 0xffffffff) { csize = u64(cd, q); q += 8; }
        if (offset === 0xffffffff) { offset = u64(cd, q); q += 8; }
      }
      e += 4 + len;
    }
    entries.push({ name, method, csize, usize, offset, dir: name.endsWith('/') });
    p += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

export async function readEntry(blob, entry, maxBytes = 64 * 1024 * 1024) {
  if (entry.usize > maxBytes) throw new Error(`zip entry too large: ${entry.name}`);
  const h = await readBytes(blob, entry.offset, entry.offset + 30);
  if (h.getUint32(0, true) !== SIG_LOC) throw new Error('bad local header');
  const start = entry.offset + 30 + h.getUint16(26, true) + h.getUint16(28, true);
  const data = blob.slice(start, start + entry.csize);
  if (entry.method === 0) return new Uint8Array(await data.arrayBuffer());
  if (entry.method !== 8) throw new Error(`unsupported zip method ${entry.method}`);
  const stream = data.stream().pipeThrough(new DecompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

export async function readEntryText(blob, entry) {
  return new TextDecoder().decode(await readEntry(blob, entry));
}
