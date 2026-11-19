// Which project an email, a meeting or a chat message is about: the project number or name in the text, and the
// people and keywords the user gave each project (Settings → Project emails, or the chat). Runs on this computer.

import { kvGet, getSettings } from './db.js';
import { tokenize, splitList } from './text.js';

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const hasPhrase = (lower, phrase) => new RegExp(`(^|[^\\p{L}\\p{N}])${esc(phrase)}($|[^\\p{L}\\p{N}])`, 'iu').test(lower);

/**
 * Projects the text is about, best first (at most 3). `people` are the From / To / Cc lines of an email (or the
 * names heard in a meeting): someone the user listed for a project counts for it.
 */
export async function detectProjects(text, { people = [] } = {}) {
  const projects = (await kvGet('projects')) || [];
  const rules = (await getSettings()).projectMail || {};
  const lower = String(text || '').toLowerCase();
  const words = new Set(tokenize(text));
  const who = people.filter(Boolean).map((p) => String(p).toLowerCase());
  const score = new Map();
  const add = (p, s) => score.set(p, (score.get(p) || 0) + s);
  for (const p of projects) {
    const name = p.split('/').pop();
    const code = (name.match(/^[A-Za-z]{0,4}[-_ ]?\d[\w.-]{1,}/) || [])[0];
    if (code && code.length >= 3 && hasPhrase(lower, code.toLowerCase())) {
      add(p, 10); // the project number written in it beats people and keywords
      continue;
    }
    const toks = tokenize(name).filter((t) => !/^\d+$/.test(t));
    if (!toks.length) continue;
    const found = toks.filter((t) => words.has(t));
    const ratio = found.length / toks.length;
    if (ratio >= 0.6 && found.some((t) => t.length >= 4)) add(p, ratio);
  }
  for (const [p, r] of Object.entries(rules)) {
    for (const kw of splitList(r.keywords)) if (kw.length >= 3 && hasPhrase(lower, kw.toLowerCase())) add(p, 2);
    // People count once per project (two people on the email don't outweigh a keyword), matched as whole words or
    // addresses: "dan" is Dan Smith or dan@x.ca, not jordan@city.ca.
    const listed = splitList(r.people).map((x) => x.toLowerCase().trim()).filter((x) => x.length >= 3);
    if (listed.some((x) => who.some((w) => hasPhrase(w, x)))) add(p, 2.5);
  }
  return [...score].sort((a, b) => b[1] - a[1]).slice(0, 3).map(([p]) => p);
}

/** Suggested keywords for a project: its number and its name (from the folder name). */
export function suggestKeywords(project) {
  const name = String(project || '').split('/').pop();
  const code = (name.match(/^[A-Za-z]{0,4}[-_ ]?\d[\w.-]{1,}/) || [])[0] || '';
  const rest = name.slice(code.length).replace(/^[\s_-]+/, '').trim();
  return [code, rest].filter((x) => x && x.length >= 3).join(', ');
}
