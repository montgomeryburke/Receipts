// Nightly event scanner for Event Scout.
// Runs on GitHub Actions (Node 20+, global fetch), searches all sources
// server-side (no CORS proxies needed), and writes events/data.json,
// which the app loads instantly.
'use strict';
const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const CONFIG = JSON.parse(fs.readFileSync(path.join(DIR, 'config.json'), 'utf8'));
const OUT = path.join(DIR, 'data.json');

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

const DEFAULT_KEYWORDS = [
  'demolition derby', 'hit to pass', 'hit-to-pass', 'enduro', 'figure 8', 'figure eight',
  'sprint car', 'late model', 'stock car', 'dirt track', 'motocross', 'supercross',
  'drag racing', 'monster truck', 'tractor pull', 'truck pull', 'bump to pass',
  'wing night', 'wing special', 'wing wednesday', 'chicken wing'
];
const MONTHS = ['january','february','march','april','may','june','july','august',
                'september','october','november','december'];
const WINDOW_DAYS = 30;

function log(msg) { console.log('[scan] ' + msg); }

async function fetchText(url, ms) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms || 20000);
  try {
    const r = await fetch(url, {
      signal: ctrl.signal,
      headers: { 'User-Agent': UA, 'Accept-Language': 'en-US,en;q=0.9' }
    });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return await r.text();
  } finally { clearTimeout(t); }
}

function ymd(d) {
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' +
         String(d.getDate()).padStart(2, '0');
}
function haversineMi(lat1, lon1, lat2, lon2) {
  const R = 3958.8, toR = Math.PI / 180;
  const dLat = (lat2 - lat1) * toR, dLon = (lon2 - lon1) * toR;
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * toR) * Math.cos(lat2 * toR) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}
function matchAny(text, words) {
  const t = (text || '').toLowerCase();
  for (const w of words) if (t.includes(w)) return w;
  return null;
}
function stripTags(s) { return s.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim(); }
function cleanResultUrl(href) {
  href = href.replace(/&amp;/g, '&');
  const um = href.match(/uddg=([^&]+)/);
  if (um) { try { href = decodeURIComponent(um[1]); } catch (e) {} }
  if (href.startsWith('//')) href = 'https:' + href;
  return href;
}
function resultOk(href) {
  return href.startsWith('http') &&
    !href.includes('duckduckgo.com') && !href.includes('bing.com') &&
    !href.includes('microsoft.com') && !href.includes('google.com') &&
    !href.includes('gstatic.com');
}

/* ---------- Eventbrite ---------- */
function extractServerData(html) {
  let i = html.indexOf('window.__SERVER_DATA__');
  if (i === -1) return null;
  i = html.indexOf('{', i);
  if (i === -1) return null;
  let depth = 0, inStr = false, escp = false;
  for (let j = i; j < html.length; j++) {
    const c = html[j];
    if (inStr) {
      if (escp) escp = false;
      else if (c === '\\') escp = true;
      else if (c === '"') inStr = false;
    } else {
      if (c === '"') inStr = true;
      else if (c === '{') depth++;
      else if (c === '}') {
        depth--;
        if (!depth) { try { return JSON.parse(html.slice(i, j + 1)); } catch (e) { return null; } }
      }
    }
  }
  return null;
}
async function scanEventbrite(loc, start, end) {
  const city = loc.city.toLowerCase().replace(/^(city|town|township|village) of /, '')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  const variants = [];
  if (loc.st) variants.push(loc.st + '--' + city);
  variants.push((loc.country === 'ca' ? 'canada' : 'united-states') + '--' + city);
  for (const slug of variants) {
    try {
      const events = [];
      for (let page = 1; page <= 3; page++) {
        const html = await fetchText('https://www.eventbrite.com/d/' + slug +
          '/all-events/?page=' + page);
        const data = extractServerData(html);
        const res = (data && data.search_data && data.search_data.events &&
                     data.search_data.events.results) || [];
        for (const e of res) {
          if (!e || !e.name || !e.url) continue;
          const v = e.primary_venue || {}, ad = v.address || {};
          const dt = e.start_date ? new Date(e.start_date + 'T' + (e.start_time || '19:00')) : null;
          if (!dt || dt < start || dt > end) continue;
          const ta = e.ticket_availability || {};
          let price = null;
          if (ta.is_free) price = 0;
          else if (ta.minimum_ticket_price && ta.minimum_ticket_price.major_value != null)
            price = parseFloat(ta.minimum_ticket_price.major_value);
          events.push({
            id: 'eb:' + (e.id || e.url), source: 'Eventbrite', title: e.name, url: e.url,
            dt: dt.toISOString(), hasTime: !!e.start_time,
            venue: v.name || '', venueCity: ad.city || '',
            venueLat: ad.latitude != null ? parseFloat(ad.latitude) : null,
            venueLon: ad.longitude != null ? parseFloat(ad.longitude) : null,
            priceMin: price, priceMax: null,
            segment: (e.tags || []).map(t => t.display_name || '').join(' '),
            genre: '', desc: e.summary || '', confirmed: true
          });
        }
        if (res.length < 20) break;
      }
      if (events.length) { log('Eventbrite (' + slug + '): ' + events.length); return events; }
    } catch (e) { log('Eventbrite ' + slug + ' failed: ' + e.message); }
  }
  return [];
}

/* ---------- OpenStreetMap race tracks ---------- */
const OVERPASS = ['https://overpass-api.de/api/interpreter',
                  'https://overpass.kumi.systems/api/interpreter',
                  'https://overpass.private.coffee/api/interpreter'];
async function scanTracks(loc, radiusMi) {
  const r = Math.round(Math.min(radiusMi, 300) * 1609);
  const around = `(around:${r},${loc.lat},${loc.lon})`;
  const q = `[out:json][timeout:25];(nwr["sport"="motor"]${around};` +
    `nwr["highway"="raceway"]${around};nwr["sport"="motocross"]${around};);out center tags 80;`;
  for (const base of OVERPASS) {
    try {
      const txt = await fetchText(base + '?data=' + encodeURIComponent(q), 30000);
      const j = JSON.parse(txt);
      const seen = {}, tracks = [];
      for (const el of j.elements || []) {
        const t = el.tags || {};
        if (!t.name || seen[t.name.toLowerCase()]) continue;
        seen[t.name.toLowerCase()] = 1;
        const lat = el.lat != null ? el.lat : (el.center && el.center.lat);
        const lon = el.lon != null ? el.lon : (el.center && el.center.lon);
        tracks.push({
          name: t.name, lat, lon,
          website: t.website || t['contact:website'] || '',
          dist: (lat != null && lon != null) ? haversineMi(loc.lat, loc.lon, lat, lon) : null
        });
      }
      tracks.sort((a, b) => (a.dist || 9e9) - (b.dist || 9e9));
      log('Overpass (' + base + '): ' + tracks.length + ' tracks');
      return tracks.slice(0, 30);
    } catch (e) { log('Overpass ' + base + ' failed: ' + e.message); }
  }
  return [];
}

/* ---------- page scanning (track sites, extra sources) ---------- */
function scanPageText(text, src, start, end, keywords) {
  const t = text.replace(/\s+/g, ' ').slice(0, 200000);
  const found = [], seen = {};
  const year = start.getFullYear();
  function consider(dt, idx, len) {
    if (!dt || dt < start || dt > end) return;
    const ctx = t.slice(Math.max(0, idx - 120), Math.min(t.length, idx + len + 160)).trim();
    const kw = matchAny(ctx, keywords);
    const key = ymd(dt) + '|' + ctx.slice(0, 60);
    if (seen[key]) return;
    seen[key] = 1;
    found.push({
      id: 'src:' + src.url + '|' + key, source: src.name,
      title: (kw || 'Possible event') + ' — ' + src.name,
      url: src.url, dt: dt.toISOString(), hasTime: false,
      venue: src.name, venueCity: '',
      venueLat: src.lat != null ? src.lat : null, venueLon: src.lon != null ? src.lon : null,
      priceMin: null, priceMax: null, segment: src.type || '', genre: '',
      desc: '…' + ctx + '…', confirmed: false,
      forcedCat: src.type === 'racing' ? 'racing' : (src.type === 'deals' ? 'deals' : null),
      kwHit: kw
    });
  }
  let m;
  const re1 = new RegExp('\\b(' + MONTHS.map(mo => mo.slice(0, 3)).join('|') +
    ')[a-z]*\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b', 'gi');
  while ((m = re1.exec(t)) !== null && found.length < 12) {
    const mi = MONTHS.findIndex(mo => mo.startsWith(m[1].toLowerCase()));
    const day = parseInt(m[2], 10);
    if (mi < 0 || day < 1 || day > 31) continue;
    let dt = new Date(year, mi, day);
    if (dt < start) dt = new Date(year + 1, mi, day);
    consider(dt, m.index, m[0].length);
  }
  const re2 = /\b(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?\b/g;
  while ((m = re2.exec(t)) !== null && found.length < 12) {
    const mo = parseInt(m[1], 10), da = parseInt(m[2], 10);
    if (mo < 1 || mo > 12 || da < 1 || da > 31) continue;
    const yr = m[3] ? parseInt(m[3].length === 2 ? '20' + m[3] : m[3], 10) : year;
    let dt = new Date(yr, mo - 1, da);
    if (!m[3] && dt < start) dt = new Date(yr + 1, mo - 1, da);
    consider(dt, m.index, m[0].length);
  }
  return found;
}
async function scanPage(src, start, end, keywords) {
  try {
    const html = await fetchText(src.url);
    const text = html.replace(/<script[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' ')
      .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&');
    const evs = scanPageText(text, src, start, end, keywords);
    log('page ' + src.url + ': ' + evs.length);
    return evs;
  } catch (e) { log('page ' + src.url + ' failed: ' + e.message); return []; }
}

/* ---------- web sweep ---------- */
function parseGoogle(html, max) {
  const out = []; let m;
  const re = /href="\/url\?q=([^&"]+)[^"]*"[^>]*>([\s\S]*?)<\/a>/g;
  while ((m = re.exec(html)) !== null && out.length < max) {
    let href;
    try { href = cleanResultUrl(decodeURIComponent(m[1])); } catch (e) { continue; }
    if (!resultOk(href)) continue;
    const title = stripTags(m[2]);
    if (!title) continue;
    out.push({ url: href, title, snippet: stripTags(html.slice(re.lastIndex, re.lastIndex + 600)).slice(0, 180) });
  }
  return out;
}
function parseDdg(html, max) {
  const out = []; let m;
  const re = /class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?class="result__snippet"[^>]*>([\s\S]*?)<\/(?:a|div|td)>/g;
  while ((m = re.exec(html)) !== null && out.length < max) {
    const href = cleanResultUrl(m[1]);
    if (!resultOk(href)) continue;
    out.push({ url: href, title: stripTags(m[2]), snippet: stripTags(m[3]) });
  }
  return out;
}
function parseDdgLite(html, max) {
  const out = []; let m;
  const re = /href="([^"]+)"[^>]*class="result-link"[^>]*>([\s\S]*?)<\/a>[\s\S]*?class="result-snippet"[^>]*>([\s\S]*?)<\/td>/g;
  while ((m = re.exec(html)) !== null && out.length < max) {
    const href = cleanResultUrl(m[1]);
    if (!resultOk(href)) continue;
    out.push({ url: href, title: stripTags(m[2]), snippet: stripTags(m[3]) });
  }
  return out;
}
function parseBing(html, max) {
  const out = []; let m;
  const re = /<li class="b_algo"[\s\S]*?<h2[^>]*><a href="([^"]+)"[^>]*>([\s\S]*?)<\/a><\/h2>[\s\S]*?<p[^>]*>([\s\S]*?)<\/p>/g;
  while ((m = re.exec(html)) !== null && out.length < max) {
    const href = cleanResultUrl(m[1]);
    if (!resultOk(href)) continue;
    out.push({ url: href, title: stripTags(m[2]), snippet: stripTags(m[3]) });
  }
  return out;
}
const ENGINES = [
  { name: 'google', url: q => 'https://www.google.com/search?q=' + encodeURIComponent(q) + '&gbv=1&num=20&hl=en', parse: parseGoogle },
  { name: 'ddg', url: q => 'https://html.duckduckgo.com/html/?q=' + encodeURIComponent(q), parse: parseDdg },
  { name: 'ddg-lite', url: q => 'https://lite.duckduckgo.com/lite/?q=' + encodeURIComponent(q), parse: parseDdgLite },
  { name: 'bing', url: q => 'https://www.bing.com/search?q=' + encodeURIComponent(q), parse: parseBing }
];
async function webSearch(q, max) {
  for (const eng of ENGINES) {
    try {
      const html = await fetchText(eng.url(q));
      const res = eng.parse(html, max);
      if (res.length) { log('web [' + eng.name + '] "' + q + '": ' + res.length); return res; }
    } catch (e) { log('web [' + eng.name + '] failed: ' + e.message); }
  }
  log('web: all engines empty for "' + q + '"');
  return [];
}
function parseFirstDate(text, start, end) {
  const re = new RegExp('\\b(' + MONTHS.map(mo => mo.slice(0, 3)).join('|') +
    ')[a-z]*\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b', 'i');
  const m = re.exec((text || '').toLowerCase());
  if (!m) return null;
  const mi = MONTHS.findIndex(mo => mo.startsWith(m[1].toLowerCase()));
  const day = parseInt(m[2], 10);
  if (mi < 0 || day < 1 || day > 31) return null;
  let dt = new Date(start.getFullYear(), mi, day);
  if (dt < start) dt = new Date(start.getFullYear() + 1, mi, day);
  return (dt >= start && dt <= end) ? dt : null;
}
async function scanWeb(loc, start, end) {
  const city = loc.city, mon = MONTHS[start.getMonth()];
  const queries = [
    { q: `"demolition derby" OR "hit to pass" OR "enduro" ${city} ${start.getFullYear()}`, cat: 'racing' },
    { q: `"demolition derby" OR "hit to pass" OR speedway ${city} site:facebook.com`, cat: 'racing' },
    { q: `"wing night" OR "wing special" ${city}`, cat: 'deals' },
    { q: `events ${city} ${mon} site:facebook.com/events`, cat: null },
    { q: `${city} live music OR comedy ${mon} ${start.getFullYear()}`, cat: null }
  ];
  const seen = {}, out = [];
  for (const sq of queries) {
    const results = await webSearch(sq.q, 6);
    for (const r of results) {
      if (seen[r.url]) continue;
      seen[r.url] = 1;
      const dt = parseFirstDate(r.title + ' ' + r.snippet, start, end);
      const isFb = r.url.includes('facebook.com');
      out.push({
        id: 'web:' + r.url, source: isFb ? 'Facebook (public)' : 'Web search',
        title: r.title || r.url, url: r.url,
        dt: dt ? dt.toISOString() : null, hasTime: false,
        venue: '', venueCity: '', venueLat: null, venueLon: null,
        priceMin: null, priceMax: null, segment: '', genre: '',
        desc: r.snippet, confirmed: false, fallbackCat: sq.cat, kwHit: null
      });
    }
  }
  return out;
}

/* ---------- main ---------- */
(async () => {
  if (CONFIG.unset || CONFIG.lat == null || CONFIG.lon == null || !CONFIG.city) {
    log('config.json not set yet — writing empty data.json');
    fs.writeFileSync(OUT, JSON.stringify({ unset: true }) + '\n');
    return;
  }
  const loc = { lat: CONFIG.lat, lon: CONFIG.lon, city: CONFIG.city,
                st: (CONFIG.st || '').toLowerCase(), country: (CONFIG.country || 'us').toLowerCase() };
  const radius = CONFIG.radiusMiles || 50;
  const keywords = (CONFIG.keywords || DEFAULT_KEYWORDS).map(k => k.toLowerCase());
  const start = new Date(); start.setHours(0, 0, 0, 0);
  const end = new Date(start); end.setDate(end.getDate() + WINDOW_DAYS); end.setHours(23, 59, 59, 0);

  const events = [];
  events.push(...await scanEventbrite(loc, start, end));
  const tracks = await scanTracks(loc, radius);
  for (const t of tracks.filter(t => t.website).slice(0, 8)) {
    events.push(...await scanPage({ name: t.name, url: t.website, type: 'racing',
      lat: t.lat, lon: t.lon }, start, end, keywords));
  }
  for (const s of CONFIG.extraPages || []) {
    events.push(...await scanPage(s, start, end, keywords));
  }
  events.push(...await scanWeb(loc, start, end));

  const data = {
    generated: new Date().toISOString(),
    loc, radiusMiles: radius,
    tracks, events
  };
  fs.writeFileSync(OUT, JSON.stringify(data, null, 1) + '\n');
  log('wrote data.json: ' + events.length + ' events, ' + tracks.length + ' tracks');
})().catch(e => { console.error(e); process.exit(1); });
