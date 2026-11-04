// Local full-text index: BM25 ranking over IndexedDB, zero tokens spent.
//
// Layout: `chunks` holds ~1 KB passages, `terms` holds one posting list per
// term as a flat array [chunkId, impact, chunkId, impact, ...]. Impacts are
// BM25 term weights precomputed at index time (length-normalised), so a
// query only reads the posting lists of its own terms.

import { tx, reqP, txDone, kvGet, kvSet } from './db.js';
import { tokenize, termFreqs } from './text.js';

export const INDEX_VERSION = 1;
const K1 = 1.2;
const B = 0.75;
const DEFAULT_AVGDL = 160;

async function loadState() {
  const stats = (await kvGet('indexStats')) || { n: 0, totalLen: 0 };
  const dead = new Set((await kvGet('deadChunks')) || []);
  return { stats, dead };
}

export class IndexWriter {
  constructor() {
    this.pending = new Map();      // term -> flat [id, impact, ...]
    this.pendingEntries = 0;
    this.ready = loadState().then((s) => Object.assign(this, s));
  }

  avgdl() {
    return this.stats.n > 50 ? this.stats.totalLen / this.stats.n : DEFAULT_AVGDL;
  }

  // Replaces whatever the index holds for rec.path.
  // rec: file record (path, size, mtime, ...); chunks: [{text, page}]
  async addFile(rec, chunks) {
    await this.ready;
    await this.removeFile(rec.path);
    const pathTerms = rec.path.replace(/\.[^./]+$/, '').replace(/[/_]+/g, ' ');
    const t = await tx(['chunks', 'files'], 'readwrite');
    const cs = t.objectStore('chunks');
    const prepared = chunks.map((c, ord) => {
      const indexText = ord === 0 ? `${pathTerms}\n${c.text}` : c.text;
      const tf = termFreqs(indexText);
      let len = 0;
      for (const v of tf.values()) len += v;
      return { c, ord, tf, len };
    });
    const idReqs = prepared.map(({ c, ord, len }) =>
      reqP(cs.add({ path: rec.path, ord, page: c.page || 0, text: c.text, len })));
    const ids = await Promise.all(idReqs);
    rec.chunkIds = ids;
    rec.v = INDEX_VERSION;
    t.objectStore('files').put(rec);
    await txDone(t);

    const avgdl = this.avgdl();
    prepared.forEach(({ tf, len }, i) => {
      const id = ids[i];
      this.stats.n += 1;
      this.stats.totalLen += len;
      const norm = K1 * (1 - B + (B * len) / avgdl);
      for (const [term, f] of tf) {
        const impact = Math.max(1, Math.round((100 * f * (K1 + 1)) / (f + norm)));
        let list = this.pending.get(term);
        if (!list) this.pending.set(term, (list = []));
        list.push(id, impact);
        this.pendingEntries += 1;
      }
    });
    if (this.pendingEntries > 150000) await this.flush();
  }

  async removeFile(path) {
    await this.ready;
    const t = await tx(['files', 'chunks'], 'readwrite');
    const fs = t.objectStore('files');
    const old = await reqP(fs.get(path));
    if (old) {
      const cs = t.objectStore('chunks');
      for (const id of old.chunkIds || []) {
        const c = await reqP(cs.get(id));
        if (c) {
          this.stats.n -= 1;
          this.stats.totalLen -= c.len || 0;
          cs.delete(id);
        }
        this.dead.add(id);
      }
      fs.delete(path);
    }
    await txDone(t);
    return !!old;
  }

  async flush() {
    if (!this.pending.size) return;
    const pending = this.pending;
    this.pending = new Map();
    this.pendingEntries = 0;
    const t = await tx(['terms'], 'readwrite');
    const ts = t.objectStore('terms');
    await Promise.all([...pending].map(async ([term, list]) => {
      const cur = await reqP(ts.get(term));
      ts.put({ t: term, p: cur ? cur.p.concat(list) : list });
    }));
    await txDone(t);
  }

  async finish() {
    await this.ready;
    await this.flush();
    this.stats.n = Math.max(0, this.stats.n);
    this.stats.totalLen = Math.max(0, this.stats.totalLen);
    await kvSet('indexStats', this.stats);
    if (this.dead.size > 2000 && this.dead.size > this.stats.n * 0.25) {
      await compact(this.dead);
      this.dead.clear();
    }
    await kvSet('deadChunks', [...this.dead]);
  }
}

// Drops postings that point at deleted chunks.
async function compact(dead) {
  const t = await tx(['terms'], 'readwrite');
  const ts = t.objectStore('terms');
  await new Promise((resolve, reject) => {
    const req = ts.openCursor();
    req.onerror = () => reject(req.error);
    req.onsuccess = () => {
      const cur = req.result;
      if (!cur) return resolve();
      const p = cur.value.p;
      const kept = [];
      for (let i = 0; i < p.length; i += 2) if (!dead.has(p[i])) kept.push(p[i], p[i + 1]);
      if (!kept.length) cur.delete();
      else if (kept.length !== p.length) cur.update({ t: cur.value.t, p: kept });
      cur.continue();
    };
  });
  await txDone(t);
}

// Document frequency for each term (approximate: includes not-yet-compacted dead ids).
export async function termStats(terms) {
  const t = await tx(['terms']);
  const ts = t.objectStore('terms');
  const out = new Map();
  await Promise.all(terms.map(async (term) => {
    const rec = await reqP(ts.get(term));
    out.set(term, rec ? rec.p.length / 2 : 0);
  }));
  return out;
}

// Picks the terms of a long text that best identify it (tf·idf against the
// index). Terms the index has never seen are useless for retrieval and are
// dropped; so are terms present in a large share of all chunks.
export async function selectQueryTerms(text, maxTerms = 24, boostText = '') {
  const tf = new Map();
  for (const t of tokenize(text)) tf.set(t, (tf.get(t) || 0) + 1);
  for (const t of tokenize(boostText)) tf.set(t, (tf.get(t) || 0) + 3);
  if (!tf.size) return new Map();
  const { stats } = await loadState();
  const N = Math.max(1, stats.n);
  const df = await termStats([...tf.keys()]);
  const scored = [];
  for (const [term, f] of tf) {
    const d = df.get(term) || 0;
    if (!d) continue;
    if (N > 200 && d / N > 0.3) continue;
    const idf = Math.log(1 + (N - d + 0.5) / (d + 0.5));
    scored.push([term, Math.log(1 + f) * idf]);
  }
  scored.sort((a, b) => b[1] - a[1]);
  const top = scored.slice(0, maxTerms);
  const max = top.length ? top[0][1] : 1;
  return new Map(top.map(([t, s]) => [t, 0.5 + s / max]));
}

// query: string or Map(term -> weight).
// Returns [{id, path, page, text, score}] — at most k, at most perFile per
// file, total text within charBudget.
// preferRecent: when the talk is about updates, schedules or forecasts, newer files rank higher
// (a file changed this month scores up to 1.8x; one untouched for years about 1x).
export async function search(query, {
  k = 8, charBudget = 7000, perFile = 2, maxChunkChars = 1200,
  boostPrefixes = [], excludeIds = new Set(), pathPrefix = '',
  onlyPaths = null, excludePaths = null, preferRecent = false,
} = {}) {
  const weights = query instanceof Map ? query : new Map([...new Set(tokenize(query))].map((t) => [t, 1]));
  if (!weights.size) return [];
  const { stats, dead } = await loadState();
  const N = Math.max(1, stats.n);
  const t = await tx(['terms', 'chunks']);
  const ts = t.objectStore('terms');
  const lists = await Promise.all([...weights.keys()].map((term) => reqP(ts.get(term))));
  const scores = new Map();
  [...weights.values()].forEach((w, i) => {
    const rec = lists[i];
    if (!rec) return;
    const p = rec.p;
    const df = p.length / 2;
    const idf = Math.log(1 + (N - df + 0.5) / (df + 0.5));
    for (let j = 0; j < p.length; j += 2) {
      const id = p[j];
      if (dead.has(id) || excludeIds.has(id)) continue;
      scores.set(id, (scores.get(id) || 0) + w * idf * (p[j + 1] / 100));
    }
  });
  // A path filter can discard most top hits, so look deeper when one is set.
  const depth = onlyPaths || pathPrefix ? 2000 : Math.max(60, k * 8);
  const cands = [...scores].sort((a, b) => b[1] - a[1]).slice(0, depth);
  const cs = t.objectStore('chunks');
  const recs = await Promise.all(cands.map(([id]) => reqP(cs.get(id))));
  const boosts = boostPrefixes.filter(Boolean).map((p) => p.toLowerCase());
  const mtimes = new Map();
  if (preferRecent) {
    const ft = await tx(['files']);
    const fs = ft.objectStore('files');
    const paths = [...new Set(recs.filter(Boolean).map((c) => c.path))];
    await Promise.all(paths.map(async (p) => mtimes.set(p, (await reqP(fs.get(p)))?.mtime || 0)));
  }
  const now = Date.now();
  const hits = [];
  recs.forEach((c, i) => {
    if (!c) return;
    if (pathPrefix && !c.path.startsWith(pathPrefix)) return;
    if (onlyPaths && !onlyPaths.has(c.path)) return;
    if (excludePaths && excludePaths.has(c.path)) return;
    let score = cands[i][1];
    const lp = c.path.toLowerCase();
    if (boosts.some((b) => lp.startsWith(b + '/') || lp === b)) score *= 1.6;
    if (preferRecent) {
      const ageDays = Math.max(0, (now - (mtimes.get(c.path) || 0)) / 86400000);
      score *= 1 + 0.8 * Math.exp(-ageDays / 120);
    }
    hits.push({ id: c.id, path: c.path, page: c.page, text: c.text, score, ...(preferRecent ? { mtime: mtimes.get(c.path) || 0 } : {}) });
  });
  hits.sort((a, b) => b.score - a.score);
  const out = [];
  const perFileCount = new Map();
  let used = 0;
  for (const h of hits) {
    if (out.length >= k) break;
    const n = perFileCount.get(h.path) || 0;
    if (n >= perFile) continue;
    const text = h.text.length > maxChunkChars ? h.text.slice(0, maxChunkChars) + '…' : h.text;
    if (used + text.length > charBudget && out.length) continue;
    perFileCount.set(h.path, n + 1);
    used += text.length;
    out.push({ ...h, text, score: Math.round(h.score * 100) / 100 });
  }
  return out;
}

// First chunks of a file — used when a taught document has no term overlap
// with the email (e.g. a form or a register the user always wants attached).
export async function leadChunks(path, n = 1, maxChunkChars = 1200) {
  const t = await tx(['files', 'chunks']);
  const f = await reqP(t.objectStore('files').get(path));
  if (!f) return [];
  const ids = (f.chunkIds || []).slice(0, n);
  const recs = await Promise.all(ids.map((id) => reqP(t.objectStore('chunks').get(id))));
  return recs.filter(Boolean).map((c) => ({
    id: c.id, path: c.path, page: c.page, score: 0,
    text: c.text.length > maxChunkChars ? c.text.slice(0, maxChunkChars) + '…' : c.text,
  }));
}

/** Words that mean "the newest version matters" (updates, forecasts, schedules). */
export const RECENCY_WORDS = /\b(updat\w*|forecast\w*|latest|newest|current(ly)?|status|progress|schedule\w*|revis\w*|recent(ly)?|this (week|month)|to date|look-?ahead|projection\w*|estimate at completion|eac|cash ?flow)\b/i;

export async function indexSummary() {
  const stats = (await kvGet('indexStats')) || { n: 0, totalLen: 0 };
  const status = (await kvGet('indexStatus')) || null;
  return { chunks: stats.n, status };
}
