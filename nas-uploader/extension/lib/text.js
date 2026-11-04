// Tokenizing, chunking and email cleanup. Pure functions, no browser APIs,
// so the same code runs in the engine, the side panel and the tests.

const STOP = new Set(`a about above after again against all am an and any are as at be because been
before being below between both but by can could did do does doing down during each few for from
further had has have having he her here hers him his how i if in into is it its itself just me more
most my no nor not now of off on once only or other our ours out over own same she should so some
such than that the their theirs them then there these they this those through to too under until up
very was we were what when where which while who whom why will with would you your yours yourself
re fw fwd hi hello dear thanks thank regards best please kind cheers also get got let us may might
must shall per via etc ok yes`.split(/\s+/));

const WORD = /[\p{L}\p{N}]+(?:[-./_][\p{L}\p{N}]+)*/gu;

function stem(w) {
  if (w.length > 4 && /\p{L}$/u.test(w)) {
    if (w.endsWith('ies') && w.length > 5) return w.slice(0, -3) + 'y';
    if (w.endsWith('sses')) return w.slice(0, -2);
    if (w.endsWith('s') && !w.endsWith('ss') && !w.endsWith('us') && !w.endsWith('is')) return w.slice(0, -1);
  }
  return w;
}

// Returns index terms. Compound codes like "24-0173" or "A-201" are kept whole
// and also split into parts, so both "24-0173" and "0173" match.
export function tokenize(text) {
  const out = [];
  if (!text) return out;
  const lower = text.toLowerCase();
  for (const m of lower.matchAll(WORD)) {
    const tok = m[0];
    if (/[-./_]/.test(tok)) {
      if (tok.length <= 40 && /\p{N}/u.test(tok)) out.push(tok);
      for (const part of tok.split(/[-./_]+/)) addWord(part, out);
    } else {
      addWord(tok, out);
    }
  }
  return out;
}

function addWord(w, out) {
  if (!w || w.length > 40) return;
  if (w.length < 2 && !/\p{N}/u.test(w)) return;
  if (STOP.has(w)) return;
  out.push(stem(w));
}

export function termFreqs(text) {
  const tf = new Map();
  for (const t of tokenize(text)) tf.set(t, (tf.get(t) || 0) + 1);
  return tf;
}

// Splits text into ~target-sized chunks on paragraph, then sentence boundaries.
// pages: optional array of [pageNumber, text]; chunks remember their start page.
export function chunkText(textOrPages, target = 1100) {
  const pages = Array.isArray(textOrPages) ? textOrPages : [[0, textOrPages || '']];
  const chunks = [];
  let buf = '';
  let bufPage = null;
  const flush = () => {
    const t = buf.replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
    if (t.length >= 3) chunks.push({ text: t, page: bufPage || 0 });
    buf = '';
    bufPage = null;
  };
  for (const [page, text] of pages) {
    // A chunk never spans pages (so citations name the right page), except
    // that near-empty pages are folded into the next one.
    if (buf && bufPage !== page && buf.length >= 80) flush();
    const paras = String(text || '').split(/\n\s*\n|\f/);
    for (let p of paras) {
      p = p.trim();
      if (!p) continue;
      while (p.length > target * 1.5) {
        // Long paragraph: cut at the last sentence end before the target.
        let cut = p.lastIndexOf('. ', target);
        if (cut < target * 0.5) cut = p.lastIndexOf(' ', target);
        if (cut < target * 0.5) cut = target;
        if (buf) flush();
        bufPage = page;
        buf = p.slice(0, cut + 1);
        flush();
        p = p.slice(cut + 1).trim();
      }
      if (buf && buf.length + p.length + 2 > target) flush();
      if (!buf) bufPage = page;
      buf += (buf ? '\n\n' : '') + p;
    }
  }
  if (buf) flush();
  return chunks;
}

// ---- email cleanup (saves tokens: drop quoted history, signatures, disclaimers) ----

const QUOTE_MARKERS = [
  /^-{2,}\s*Original Message\s*-{2,}/im,
  /^_{10,}\s*$/m,
  /^From:\s.+\n(?:.*\n){0,3}?(?:Sent|Date):\s.+/im,
  /^On .{6,120}\bwrote:\s*$/im,
  /^De\s?:\s.+\n(?:.*\n){0,3}?(?:Envoy[ée]|Date)\s?:\s.+/im,
  /^Le .{6,120}a écrit\s?:\s*$/im,
];

const DISCLAIMER = /(this (e-?mail|message)( and any attachments)? (is|are|may be) (confidential|intended)|ce (courriel|message) (est|peut être) confidentiel|please consider the environment before printing|caution: this email originated from outside)/i;

export function cleanEmailBody(body, maxChars = 6000) {
  if (!body) return '';
  let text = String(body).replace(/\r\n?/g, '\n').replace(/ /g, ' ');
  let cut = text.length;
  for (const re of QUOTE_MARKERS) {
    const m = re.exec(text);
    if (m && m.index > 20 && m.index < cut) cut = m.index;
  }
  text = text.slice(0, cut);
  text = text.split('\n').filter((l) => !/^\s*>/.test(l)).join('\n');
  const d = DISCLAIMER.exec(text);
  if (d && d.index > 40) text = text.slice(0, d.index);
  const sig = /^\s*(--|__)\s*$/m.exec(text);
  if (sig && sig.index > 40) text = text.slice(0, sig.index);
  text = text.replace(/[ \t]+/g, ' ').replace(/\n[ \t]+/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  if (text.length > maxChars) text = text.slice(0, maxChars) + '\n[…email truncated]';
  return text;
}

export function splitList(s) {
  return String(s || '').split(/[,\n]/).map((x) => x.trim()).filter(Boolean);
}

// Glob-lite: "*" wildcard, matched against each path segment and the whole path.
export function makeMatcher(patterns) {
  const res = splitList(patterns).map((p) => {
    const re = p.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
    return new RegExp(`^${re}$`, 'i');
  });
  return (path) => {
    if (!res.length) return false;
    const segs = path.split('/');
    return res.some((re) => re.test(path) || segs.some((s) => re.test(s)));
  };
}

/** "p. 3" for documents, "email 3" for a mailbox (.pst) whose "pages" are emails. */
export function pageLabel(path, page) {
  if (!page) return '';
  return /\.pst$/i.test(path || '') ? `email ${page}` : `p. ${page}`;
}

/**
 * An email copied from the Outlook desktop app (or anywhere): pulls From / Sent / To / Cc / Subject from a header
 * block at the top if there is one (English or French Outlook), the rest is the body.
 */
export function parseCopiedEmail(text) {
  const t = String(text || '').replace(/\r\n?/g, '\n').replace(/\u00a0/g, ' ').trim();
  const out = { from: '', to: '', cc: '', subject: '', receivedAt: '', body: t };
  const keys = {
    from: /^(from|de)\s*:\s*(.*)$/i, sent: /^(sent|date|envoy[ée]|re[çc]u)\s*:\s*(.*)$/i, to: /^(to|[àa])\s*:\s*(.*)$/i,
    cc: /^cc\s*:\s*(.*)$/i, subject: /^(subject|objet)\s*:\s*(.*)$/i,
  };
  const lines = t.split('\n');
  let i = 0;
  let found = 0;
  for (; i < Math.min(lines.length, 14); i++) {
    const l = lines[i].trim();
    if (!l) {
      if (found) break;
      continue;
    }
    let m;
    if ((m = keys.from.exec(l))) out.from = m[2].trim();
    else if ((m = keys.sent.exec(l))) out.receivedAt = m[2].trim();
    else if ((m = keys.to.exec(l))) out.to = m[2].trim();
    else if ((m = keys.cc.exec(l))) out.cc = m[1].trim();
    else if ((m = keys.subject.exec(l))) out.subject = m[2].trim();
    else if (found) break;
    else continue;
    found++;
  }
  if (found >= 2) out.body = lines.slice(i).join('\n').trim();
  return out;
}

export function extOf(name) {
  const i = name.lastIndexOf('.');
  return i > 0 ? name.slice(i + 1).toLowerCase() : '';
}

export function projectOf(path, depth = 1) {
  const segs = path.split('/');
  if (segs.length <= depth) return '';
  return segs.slice(0, depth).join('/');
}

export function hashString(s) {
  // FNV-1a, 52-bit safe; stable ids for emails captured without a server id.
  let h1 = 0x811c9dc5, h2 = 0x1000193;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 16777619) >>> 0;
    h2 = Math.imul(h2 ^ c, 2246822519) >>> 0;
  }
  return h1.toString(36) + h2.toString(36);
}

export function decodeXmlEntities(s) {
  return s.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, (m, e) => {
    const l = e.toLowerCase();
    if (l === 'amp') return '&';
    if (l === 'lt') return '<';
    if (l === 'gt') return '>';
    if (l === 'quot') return '"';
    if (l === 'apos') return "'";
    if (l === 'nbsp') return ' ';
    const code = l.startsWith('#x') ? parseInt(l.slice(2), 16) : parseInt(l.slice(1), 10);
    try { return String.fromCodePoint(code); } catch { return ' '; }
  });
}
