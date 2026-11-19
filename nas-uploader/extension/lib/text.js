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

// A quoted earlier message starts with a header block (From + Sent/Date + To/Subject, in English, French,
// Spanish or German; also "*From:*" in plain-text mail and "> "-quoted), "-----Original Message-----", or a
// "On … wrote:" line. A lone "From: … Date: …" pair inside a message (a delivery ticket) is not a quote.
const HB = (k) => String.raw`[ \t>]*\*{0,2}(?:${k})\*{0,2}[ \t]?:\*{0,2}`;
const H_FROM = HB('From|De|Von');
const H_SENT = HB('Sent|Date|Envoy[ée]|Enviado|Gesendet|Datum|Fecha');
const H_TO = HB('To|[ÀA]|Para|An|Cc|Subject|Objet|Asunto|Betreff');
const QUOTE_MARKERS = [
  /^[ \t>]*-{2,}\s*(?:Original Message|Message d'origine|Mensaje original|Ursprüngliche Nachricht)\s*-{2,}/im,
  new RegExp(String.raw`^[ \t>]*_{10,}[ \t]*\n${H_FROM}`, 'im'),
  new RegExp(String.raw`^${H_FROM}.*\S.*\n(?:.*\n){0,3}?${H_SENT}.*\S.*\n(?:.*\n){0,3}?${H_TO}`, 'im'),
  /^[ \t>]*On (?:.|\n(?!\s*\n)){6,240}?\bwrote:[ \t]*$/im,
  /^[ \t>]*Le (?:.|\n(?!\s*\n)){6,240}?a écrit[ \t]?:[ \t]*$/im,
  /^[ \t>]*El (?:.|\n(?!\s*\n)){6,240}?escribió[ \t]?:[ \t]*$/im,
  /^[ \t>]*Am (?:.|\n(?!\s*\n)){6,240}?schrieb.{0,160}:[ \t]*$/im,
];

// ---- dates as Outlook and mail clients write them ----

const MONTHS = {
  jan: 0, january: 0, janv: 0, janvier: 0, enero: 0, januar: 0,
  feb: 1, february: 1, fev: 1, fevr: 1, fevrier: 1, febrero: 1, februar: 1,
  mar: 2, march: 2, mars: 2, marzo: 2, marz: 2,
  apr: 3, april: 3, avr: 3, avril: 3, abril: 3,
  may: 4, mai: 4, mayo: 4,
  jun: 5, june: 5, juin: 5, junio: 5, juni: 5,
  jul: 6, july: 6, juil: 6, juillet: 6, julio: 6, juli: 6,
  aug: 7, august: 7, aout: 7, agosto: 7,
  sep: 8, sept: 8, september: 8, septembre: 8, septiembre: 8,
  oct: 9, october: 9, octobre: 9, octubre: 9, okt: 9, oktober: 9,
  nov: 10, november: 10, novembre: 10, noviembre: 10,
  dec: 11, december: 11, decembre: 11, diciembre: 11, dez: 11, dezember: 11,
};
const WEEKDAY = /^\s*(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues?|wed|thu(?:rs?)?|fri|sat|sun|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|lun|mar|mer|jeu|ven|sam|dim)\.?,?\s+/i;
const plain = (w) => w.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/\.$/, '');
let dayFirstCache = null;
/** Whether this computer writes numeric dates day first (25/11/2026) — Outlook uses the same order. */
function dayFirst() {
  if (dayFirstCache == null) {
    try {
      const parts = new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'numeric', year: 'numeric' }).formatToParts(new Date(2026, 10, 25));
      dayFirstCache = parts.findIndex((x) => x.type === 'day') < parts.findIndex((x) => x.type === 'month');
    } catch {
      dayFirstCache = false;
    }
  }
  return dayFirstCache;
}

/**
 * The time (ms, local) of a date as written in an email header or Outlook's list: "Tue 2026-11-10 3:12 PM",
 * "mar. 2026-11-10 15:12", "Tuesday, November 10, 2026 3:12 PM", "10 novembre 2026 à 15 h 12", "11/10/2026",
 * "Mon 11/9" (this year), "3:12 PM" (today), "Yesterday 3:12 PM". NaN when it can't be read for sure.
 */
export function parseMailDate(input, now = Date.now()) {
  if (typeof input === 'number') return Number.isFinite(input) ? input : NaN;
  let s = String(input || '').replace(/\s+/g, ' ').replace(/\b(at|à|um|a las)\b/gi, ' ').trim();
  if (!s) return NaN;
  // Machine dates with a time zone ("2026-10-05T09:00:00Z", "Wed, 11 Nov 2026 09:30:00 -0800"): exact as given.
  if (/^\d{4}-\d{2}-\d{2}T\d/.test(s) || (/\b(19|20)\d{2}\b/.test(s) && /(?:[+-]\d{4}|\bGMT\b|\bUTC\b|\dZ)\s*$/.test(s))) {
    const t = Date.parse(s);
    if (!Number.isNaN(t)) return t;
  }
  const today = new Date(now);
  let base = null;
  const rel = /^(today|aujourd'hui|heute|hoy|yesterday|hier|gestern|ayer)\b/i.exec(s);
  if (rel) {
    base = new Date(today.getFullYear(), today.getMonth(), today.getDate() - (/^(today|aujourd|heute|hoy)/i.test(rel[1]) ? 0 : 1));
    s = s.slice(rel[0].length);
  }
  const tm = /(\d{1,2})\s?(?::|h)\s?(\d{2})(?::\d{2})?\s*(?:([AaPp])\.?\s?[Mm]\.?)?/.exec(s);
  let hh = 0;
  let mi = 0;
  if (tm) {
    hh = Number(tm[1]) % 24;
    mi = Number(tm[2]);
    if (tm[3]) hh = (hh % 12) + (/p/i.test(tm[3]) ? 12 : 0);
    if (mi > 59) return NaN;
  }
  const rest = tm ? s.slice(0, tm.index) + ' ' + s.slice(tm.index + tm[0].length) : s;
  // A weekday in front ("mar." is Tuesday in French, not March) — dropped only when a full date follows.
  const wd = WEEKDAY.exec(rest);
  const dateText = wd && /\d{4}[-/.]\d|\d[/.-]\d|\b[a-zA-Zéûä]{3,}\.?\s+\d|\d{1,2}(?:er)?\.?\s+[a-zA-Zéûä]{3,}/.test(rest.slice(wd[0].length)) ? rest.slice(wd[0].length) : rest;
  let y;
  let m;
  let d;
  let r;
  if ((r = /(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/.exec(dateText))) [y, m, d] = [Number(r[1]), Number(r[2]) - 1, Number(r[3])];
  else if ((r = /(\d{1,2})([/.-])(\d{1,2})[/.-](\d{2,4})\b/.exec(dateText))) {
    const [a, b] = [Number(r[1]), Number(r[3])];
    // 10.11.2026 (dots) is always day first; slashes follow this computer's order unless a number is over 12.
    const df = a > 12 ? true : b > 12 ? false : r[2] === '.' ? true : dayFirst();
    [d, m] = df ? [a, b - 1] : [b, a - 1];
    y = Number(r[4]) < 100 ? 2000 + Number(r[4]) : Number(r[4]);
  } else if ((r = /(\d{1,2})(?:er|st|nd|rd|th)?\.?\s+([a-zA-Zéûä]{3,})\.?,?(?:\s+(\d{4}))?/.exec(dateText)) && plain(r[2]) in MONTHS) {
    [d, m, y] = [Number(r[1]), MONTHS[plain(r[2])], r[3] ? Number(r[3]) : null];
  } else if ((r = /([a-zA-Zéûä]{3,})\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b,?(?:\s+(\d{4}))?/.exec(dateText)) && plain(r[1]) in MONTHS) {
    [m, d, y] = [MONTHS[plain(r[1])], Number(r[2]), r[3] ? Number(r[3]) : null];
  } else if ((r = /(?:^|\s)(\d{1,2})\/(\d{1,2})(?:\s|$)/.exec(dateText))) {
    const [a, b] = [Number(r[1]), Number(r[2])];
    const df = a > 12 ? true : b > 12 ? false : dayFirst();
    [d, m, y] = df ? [a, b - 1, null] : [b, a - 1, null];
  } else if (base || (tm && !/\d/.test(rest))) {
    const b = base || today;
    return new Date(b.getFullYear(), b.getMonth(), b.getDate(), hh, mi).getTime();
  } else if (/\b(19|20)\d{2}\b/.test(s)) {
    const t = Date.parse(String(input));
    return Number.isNaN(t) ? NaN : t;
  } else return NaN;
  if (!(m >= 0 && m <= 11 && d >= 1 && d <= 31)) return NaN;
  if (y == null) {
    // No year (Outlook's list for recent mail): the latest such date that isn't in the future.
    y = today.getFullYear();
    if (new Date(y, m, d).getTime() > now + 2 * 86400000) y -= 1;
  }
  const t = new Date(y, m, d, hh, mi);
  return t.getMonth() === m ? t.getTime() : NaN;
}

/** YYYY-MM-DD in this computer's time zone ('' when unknown). */
export function localDay(t) {
  if (t == null || t === '' || Number.isNaN(Number(t))) return '';
  const d = new Date(Number(t));
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** A date as YYYY-MM-DD when it can be read for sure (for comparisons), else ''. */
export function isoDay(s, now = Date.now()) {
  const v = String(s || '').trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return v;
  const t = parseMailDate(v, now);
  return Number.isNaN(t) ? '' : localDay(t);
}

const DISCLAIMER = /(this (e-?mail|message)( and any attachments)? (is|are|may be) (confidential|intended)|ce (courriel|message) (est|peut être) confidentiel|please consider the environment before printing|caution: this email originated from outside)/i;

export function cleanEmailBody(body, maxChars = 6000) {
  if (!body) return '';
  let text = String(body).replace(/\r\n?/g, '\n').replace(/ /g, ' ');
  let cut = text.length;
  for (const re of QUOTE_MARKERS) {
    const m = re.exec(text);
    if (m && m.index < cut && text.slice(0, m.index).trim()) cut = m.index;
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

// ---- the whole email chain ----

const HK = (k) => new RegExp(String.raw`^\s*\*{0,2}(${k})\*{0,2}\s*:\s*\*{0,2}\s*(.*)$`, 'i');
const HEADER_KEYS = {
  from: HK('from|de|von'),
  date: HK('sent|date|envoy[ée]|re[çc]u|enviado|gesendet|datum|fecha'),
  to: HK('to|[àa]|para|an'),
  cc: HK('cc'),
  subject: HK('subject|objet|asunto|betreff'),
};
const WROTE = /^\s*(?:On|Le|El|Am)\s+(.{6,240}?)\s+(?:wrote|a écrit|escribió|schrieb\s*(.*?))\s?:\s*$/i;
// "Fri, Nov 6, 2026 at 4:00 PM Arctic Fresh <pm@x.ca>" → date up to the time, then the sender.
const WHEN_WHO = /^(.*?\d{1,2}[:h]\d{2}(?:\s*[AaPp]\.?\s?[Mm]\.?)?)\s*,?\s*(.+)$/;

/** Lines of a quoted message without "> " prefixes, signatures' disclaimers and extra blank lines. */
function cleanQuoted(text, maxChars) {
  let t = String(text).split('\n').map((l) => l.replace(/^\s*(>\s?)+/, '')).join('\n');
  const d = DISCLAIMER.exec(t);
  if (d && d.index > 40) t = t.slice(0, d.index);
  t = t.replace(/[ \t]+/g, ' ').replace(/\n[ \t]+/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  return t.length > maxChars ? `${t.slice(0, maxChars)}\n[…shortened]` : t;
}

/**
 * Splits an email (as read from Outlook or copied from it) into the newest message and the earlier messages
 * quoted below it, newest first: {latest, earlier: [{from, date, to, subject, text}]}. Works with Outlook's
 * "From: … Sent: …" blocks (English and French), "-----Original Message-----" and "On … wrote:" quotes.
 */
export function splitThread(body, { perMessage = 2500 } = {}) {
  const text = String(body || '').replace(/\r\n?/g, '\n').replace(/ /g, ' ');
  const starts = [];
  for (const re of QUOTE_MARKERS) for (const m of text.matchAll(new RegExp(re.source, 'gim'))) if (text.slice(0, m.index).trim()) starts.push(m.index);
  starts.sort((a, b) => a - b);
  const cuts = starts.filter((x, i) => i === 0 || x - starts[i - 1] > 4);
  const latest = cuts.length ? text.slice(0, cuts[0]) : text;
  const earlier = [];
  cuts.forEach((start, i) => {
    const seg = text.slice(start, cuts[i + 1] ?? text.length);
    const lines = seg.split('\n');
    const unq = (l) => String(l || '').replace(/^\s*(>\s?)+/, '');
    const msg = { from: '', date: '', to: '', subject: '' };
    let k = 0;
    // The header block: an optional "Original Message" / underline line, then From/Sent/To/Cc/Subject lines.
    if (/^\s*(-{2,}\s*(Original Message|Message d'origine|Mensaje original|Ursprüngliche Nachricht)|_{10,})/i.test(unq(lines[0]))) k = 1;
    let wrote = WROTE.exec(unq(lines[k]));
    let used = 1;
    if (!wrote && /^\s*(On|Le|El|Am)\s/i.test(unq(lines[k]))) {
      wrote = WROTE.exec(`${unq(lines[k])} ${unq(lines[k + 1])}`.replace(/<\s+/, '<'));
      used = 2;
    }
    if (wrote) {
      const inner = wrote[1].trim();
      const ww = WHEN_WHO.exec(inner);
      const c = inner.lastIndexOf(',');
      if (wrote[2]) {
        msg.date = inner;
        msg.from = wrote[2].trim();
      } else {
        msg.date = (ww ? ww[1] : c > 0 ? inner.slice(0, c) : '').trim();
        msg.from = (ww ? ww[2] : c > 0 ? inner.slice(c + 1) : inner).trim();
      }
      k += used;
    } else {
      for (let n = 0; k < lines.length && n < 10; k++, n++) {
        const line = unq(lines[k]);
        if (!line.trim()) {
          if (msg.from) {
            k++;
            break;
          }
          continue;
        }
        const hit = Object.entries(HEADER_KEYS).find(([, re]) => re.test(line));
        if (!hit) break;
        const [key, re] = hit;
        const m = re.exec(line);
        msg[key] = (m[2] ?? m[1] ?? '').trim();
      }
    }
    const t = cleanQuoted(lines.slice(k).join('\n'), perMessage);
    if (t) earlier.push({ ...msg, text: t });
  });
  return { latest, earlier };
}

/**
 * The earlier messages of this email's thread, newest first and without repeats: the history quoted below the
 * newest message, plus the other messages Outlook showed in the conversation (each with its own quoted history).
 */
export function threadOf(email, settings = {}) {
  const budget = settings.maxThreadChars || 12000;
  const seen = new Set();
  const all = [];
  const key = (t) => String(t).toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 200);
  const add = (m) => {
    const t = key(m.text);
    if (!t) return;
    // Long messages are the same message wherever they were quoted; a short answer ("Yes.", "OK") only when the
    // sender and date match too.
    const k = t.length < 12 ? `${key(m.from)}|${key(m.date)}|${t}` : t;
    if (seen.has(k)) return;
    seen.add(k);
    all.push(m);
  };
  for (const m of splitThread(email.body).earlier) add(m);
  for (const t of email.conversation || []) {
    add({ from: t.from || '', date: t.date || '', to: '', subject: '', text: cleanEmailBody(t.body, 2500) });
    for (const q of splitThread(t.body).earlier) add(q);
  }
  // Newest first when the dates can be read; otherwise the order they were found in (already newest first).
  const when = (m) => parseMailDate(m.date);
  if (all.length > 1 && all.every((m) => !Number.isNaN(when(m)))) all.sort((a, b) => when(b) - when(a));
  const out = [];
  let used = 0;
  for (const m of all) {
    if (used >= budget) break;
    const text = used + m.text.length > budget ? `${m.text.slice(0, Math.max(300, budget - used))}…` : m.text;
    out.push({ ...m, text });
    used += text.length;
  }
  return out;
}

export function emailId(email) {
  if (email.id) return String(email.id);
  return 'm' + hashString(`${email.from}|${email.subject}|${email.receivedAt}|${String(email.body || '').slice(0, 300)}`);
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
