// Text extraction for project files, entirely in the browser.
// Returns { pages: [[pageNo, text], ...], method } or { pages: [], method, note }.
// Scanned PDFs and images return little or no text here; the optional deep
// indexer (OCR) fills those in later.

import { listZip, readEntryText } from './zip.js';
import { decodeXmlEntities, extOf } from './text.js';

let pdfjsPromise = null;
function loadPdfJs() {
  if (!pdfjsPromise) {
    pdfjsPromise = import('../vendor/pdfjs/pdf.min.mjs').then((lib) => {
      lib.GlobalWorkerOptions.workerSrc = new URL('../vendor/pdfjs/pdf.worker.min.mjs', import.meta.url).href;
      return lib;
    });
  }
  return pdfjsPromise;
}

const TEXT_EXT = new Set(['txt', 'md', 'csv', 'tsv', 'json', 'xml', 'log', 'yaml', 'yml', 'ini']);

export async function extractFile(file, { maxChars = 1000000 } = {}) {
  const ext = extOf(file.name);
  let res;
  if (TEXT_EXT.has(ext)) res = { pages: [[0, await file.text()]], method: 'text' };
  else if (ext === 'pdf') res = await extractPdf(file, maxChars);
  else if (['docx', 'docm', 'dotx'].includes(ext)) res = await extractDocx(file);
  else if (['xlsx', 'xlsm'].includes(ext)) res = await extractXlsx(file, maxChars);
  else if (ext === 'pptx') res = await extractPptx(file);
  else if (['odt', 'ods', 'odp'].includes(ext)) res = await extractOdf(file);
  else if (ext === 'html' || ext === 'htm') res = await extractHtml(file);
  else if (ext === 'eml') res = await extractEml(file);
  else if (ext === 'rtf') res = { pages: [[0, rtfToText(await file.text())]], method: 'rtf' };
  else if (ext === 'zip') res = await extractZipListing(file);
  else res = { pages: [], method: 'none' };
  return capPages(res, maxChars);
}

function capPages(res, maxChars) {
  let total = 0;
  const pages = [];
  for (const [n, t] of res.pages) {
    if (total >= maxChars) { res.note = 'truncated'; break; }
    const text = String(t || '');
    const room = maxChars - total;
    pages.push([n, text.length > room ? text.slice(0, room) : text]);
    total += Math.min(text.length, room);
  }
  res.pages = pages;
  res.chars = total;
  return res;
}

async function extractPdf(file, maxChars) {
  const pdfjs = await loadPdfJs();
  const data = new Uint8Array(await file.arrayBuffer());
  const doc = await pdfjs.getDocument({
    data,
    isEvalSupported: false,      // extension CSP forbids eval
    disableFontFace: true,
    useSystemFonts: false,
    stopAtErrors: false,
    standardFontDataUrl: new URL('../vendor/pdfjs/standard_fonts/', import.meta.url).href,
  }).promise;
  const pages = [];
  let total = 0;
  try {
    for (let i = 1; i <= doc.numPages && total < maxChars; i++) {
      const page = await doc.getPage(i);
      const content = await page.getTextContent();
      let text = '';
      for (const item of content.items) {
        if (!('str' in item)) continue;
        text += item.str;
        text += item.hasEOL ? '\n' : (item.str && !item.str.endsWith(' ') ? ' ' : '');
      }
      text = text.replace(/[ \t]+\n/g, '\n').trim();
      pages.push([i, text]);
      total += text.length;
      page.cleanup();
    }
  } finally {
    await doc.destroy();
  }
  const chars = pages.reduce((a, [, t]) => a + t.length, 0);
  const res = { pages, method: 'pdf' };
  if (chars < 40 * Math.max(1, pages.length) / 4) res.note = 'little text (scanned?) — deep index can OCR it';
  return res;
}

function wordXmlToText(xml) {
  return decodeXmlEntities(
    xml
      .replace(/<w:tab\/>/g, '\t')
      .replace(/<w:br[^>]*\/>/g, '\n')
      .replace(/<\/w:p>/g, '\n')
      .replace(/<\/w:tc>/g, '\t')
      .replace(/<[^>]+>/g, ''),
  );
}

async function extractDocx(file) {
  const entries = await listZip(file);
  const want = entries.filter((e) => /^word\/(document|header\d*|footer\d*|footnotes|endnotes)\.xml$/.test(e.name));
  want.sort((a, b) => (a.name === 'word/document.xml' ? -1 : b.name === 'word/document.xml' ? 1 : 0));
  const parts = [];
  for (const e of want) parts.push(wordXmlToText(await readEntryText(file, e)));
  return { pages: [[0, parts.join('\n\n')]], method: 'docx' };
}

async function extractXlsx(file, maxChars) {
  const entries = await listZip(file);
  const byName = new Map(entries.map((e) => [e.name, e]));
  const shared = [];
  const ss = byName.get('xl/sharedStrings.xml');
  if (ss) {
    const xml = await readEntryText(file, ss);
    for (const si of xml.matchAll(/<si>([\s\S]*?)<\/si>/g)) {
      shared.push(decodeXmlEntities(si[1].replace(/<rPh[\s\S]*?<\/rPh>/g, '').replace(/<[^>]+>/g, '')));
    }
  }
  // Sheet names, in workbook order.
  const names = [];
  const wb = byName.get('xl/workbook.xml');
  if (wb) {
    const xml = await readEntryText(file, wb);
    for (const m of xml.matchAll(/<sheet\b[^>]*\bname="([^"]*)"/g)) names.push(decodeXmlEntities(m[1]));
  }
  const sheets = entries
    .filter((e) => /^xl\/worksheets\/sheet\d+\.xml$/.test(e.name))
    .sort((a, b) => parseInt(a.name.match(/\d+/)[0], 10) - parseInt(b.name.match(/\d+/)[0], 10));
  const pages = [];
  let total = 0;
  for (let si = 0; si < sheets.length && total < maxChars; si++) {
    const xml = await readEntryText(file, sheets[si]);
    const lines = [];
    for (const row of xml.matchAll(/<row\b[^>]*>([\s\S]*?)<\/row>/g)) {
      const cells = [];
      for (const c of row[1].matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
        const attrs = c[1];
        const inner = c[2] || '';
        const t = (attrs.match(/\bt="([^"]+)"/) || [])[1];
        let v = (inner.match(/<v>([\s\S]*?)<\/v>/) || [])[1];
        if (t === 's' && v != null) v = shared[parseInt(v, 10)];
        else if (t === 'inlineStr') v = inner.replace(/<[^>]+>/g, '');
        if (v != null && String(v).trim() !== '') cells.push(decodeXmlEntities(String(v)).trim());
      }
      if (cells.length) lines.push(cells.join(' | '));
    }
    const text = `Sheet: ${names[si] || `Sheet${si + 1}`}\n${lines.join('\n')}`;
    pages.push([si + 1, text]);
    total += text.length;
  }
  return { pages, method: 'xlsx' };
}

async function extractPptx(file) {
  const entries = await listZip(file);
  const slides = entries
    .filter((e) => /^ppt\/slides\/slide\d+\.xml$/.test(e.name))
    .sort((a, b) => parseInt(a.name.match(/\d+/)[0], 10) - parseInt(b.name.match(/\d+/)[0], 10));
  const pages = [];
  for (let i = 0; i < slides.length; i++) {
    const xml = await readEntryText(file, slides[i]);
    const text = decodeXmlEntities(xml.replace(/<\/a:p>/g, '\n').replace(/<a:br\/>/g, '\n').replace(/<[^>]+>/g, ''));
    pages.push([i + 1, text]);
  }
  return { pages, method: 'pptx' };
}

async function extractOdf(file) {
  const entries = await listZip(file);
  const content = entries.find((e) => e.name === 'content.xml');
  if (!content) return { pages: [], method: 'odf' };
  const xml = await readEntryText(file, content);
  const text = decodeXmlEntities(
    xml.replace(/<text:tab\/>/g, '\t').replace(/<text:line-break\/>/g, '\n')
      .replace(/<\/text:(p|h)>/g, '\n').replace(/<\/table:table-cell>/g, '\t').replace(/<[^>]+>/g, ''),
  );
  return { pages: [[0, text]], method: 'odf' };
}

export function htmlToText(html) {
  // Drop embedded media first: exported reports often carry tens of MB of base64.
  const cleaned = html
    .replace(/<(script|style|svg|noscript|template)\b[\s\S]*?<\/\1>/gi, ' ')
    .replace(/(src|href)\s*=\s*"data:[^"]*"/gi, '')
    .replace(/url\(\s*['"]?data:[^)]*\)/gi, '');
  if (typeof DOMParser !== 'undefined') {
    const doc = new DOMParser().parseFromString(cleaned, 'text/html');
    doc.querySelectorAll('br').forEach((b) => b.replaceWith('\n'));
    doc.querySelectorAll('p,div,li,tr,h1,h2,h3,h4,h5,h6,section,article,table').forEach((el) => el.append('\n'));
    doc.querySelectorAll('td,th').forEach((el) => el.append('\t'));
    return (doc.body ? doc.body.textContent : doc.documentElement.textContent || '').replace(/\n\s*\n\s*\n+/g, '\n\n');
  }
  return decodeXmlEntities(cleaned.replace(/<br\s*\/?>/gi, '\n').replace(/<\/(p|div|li|tr|h\d)>/gi, '\n').replace(/<[^>]+>/g, ' '));
}

async function extractHtml(file) {
  if (file.size > 60 * 1024 * 1024) return { pages: [], method: 'html', note: 'too large' };
  return { pages: [[0, htmlToText(await file.text())]], method: 'html' };
}

async function extractEml(file) {
  const raw = await file.text();
  const split = raw.search(/\r?\n\r?\n/);
  const headers = split > 0 ? raw.slice(0, split) : '';
  let body = split > 0 ? raw.slice(split) : raw;
  const pick = (h) => (headers.match(new RegExp(`^${h}:\\s*(.+)$`, 'im')) || [])[1] || '';
  // Prefer the text/plain part of multipart mail; decode quoted-printable.
  const plain = body.match(/Content-Type:\s*text\/plain[\s\S]*?\r?\n\r?\n([\s\S]*?)(?:\r?\n--[^\r\n]+)/i);
  if (plain) body = plain[1];
  else if (/<html/i.test(body)) body = htmlToText(body);
  if (/quoted-printable/i.test(raw)) {
    body = body.replace(/=\r?\n/g, '').replace(/=([0-9A-F]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));
  }
  const head = `From: ${pick('From')}\nTo: ${pick('To')}\nDate: ${pick('Date')}\nSubject: ${pick('Subject')}\n\n`;
  return { pages: [[0, head + body]], method: 'eml' };
}

function rtfToText(rtf) {
  return rtf
    .replace(/\\par[d]?/g, '\n')
    .replace(/\\'([0-9a-f]{2})/gi, (_, h) => String.fromCharCode(parseInt(h, 16)))
    .replace(/\\[a-z]+-?\d* ?/gi, '')
    .replace(/[{}]/g, '');
}

async function extractZipListing(file) {
  const entries = await listZip(file);
  const names = entries.filter((e) => !e.dir).map((e) => e.name);
  return { pages: [[0, `Archive contents (${names.length} files):\n${names.slice(0, 5000).join('\n')}`]], method: 'zip-list' };
}
