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
      add(p, 3);
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
    for (const person of splitList(r.people)) {
      const x = person.toLowerCase().trim();
      if (x.length >= 3 && who.some((w) => w.includes(x))) add(p, 2.5);
    }
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
