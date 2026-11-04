// "Teach" — remembers which documents are (or are not) the right source for
// a kind of email. Rules are learned from thumbs-up/down on sources, from
// documents the user attaches by hand, and from typed hints. Matching is
// local term overlap, so it costs no tokens.

import { kvGet, kvSet, get } from './db.js';
import { tokenize } from './text.js';
import { selectQueryTerms } from './index.js';

export async function getRules() {
  return (await kvGet('rules')) || [];
}

async function saveRules(rules) {
  await kvSet('rules', rules);
}

function domainOf(from) {
  const m = String(from || '').toLowerCase().match(/@([\w.-]+)/);
  return m ? m[1] : '';
}

async function itemTerms(item, n = 8) {
  const terms = await selectQueryTerms(item.bodyClean || '', n, item.subject || '');
  if (terms.size) return [...terms.keys()];
  return [...new Set(tokenize(`${item.subject} ${item.bodyClean}`))].slice(0, n);
}

// kind: 'prefer' | 'avoid'
export async function learnFromItem(item, path, kind = 'prefer') {
  const rules = await getRules();
  const terms = await itemTerms(item);
  const sender = domainOf(item.from);
  // Same document + mostly the same terms: strengthen instead of duplicating.
  const twin = rules.find((r) => r.path === path && r.kind === kind
    && r.terms.filter((t) => terms.includes(t)).length >= Math.min(3, terms.length));
  if (twin) {
    twin.weight = Math.min(5, (twin.weight || 1) + 1);
    twin.terms = [...new Set([...twin.terms, ...terms])].slice(0, 16);
    twin.updatedAt = Date.now();
  } else {
    rules.push({
      id: `r${Date.now().toString(36)}${Math.random().toString(36).slice(2, 5)}`,
      kind, path, terms, sender, weight: 1, note: item.subject || '', createdAt: Date.now(),
    });
  }
  // A thumbs-down cancels an earlier thumbs-up for the same email terms, and vice versa.
  const opposite = kind === 'prefer' ? 'avoid' : 'prefer';
  const kept = rules.filter((r) => !(r.path === path && r.kind === opposite
    && r.terms.filter((t) => terms.includes(t)).length >= Math.min(3, terms.length)));
  await saveRules(kept);
  return kept;
}

// Free-text hint: "Concrete strength questions → Specs/03 30 00.pdf"
export async function addHint(text, path, kind = 'prefer') {
  const rules = await getRules();
  const terms = [...new Set(tokenize(text))].slice(0, 12);
  if (!terms.length || !path) throw new Error('A hint needs some keywords and a document');
  rules.push({
    id: `r${Date.now().toString(36)}${Math.random().toString(36).slice(2, 5)}`,
    kind, path, terms, sender: '', weight: 2, note: text, createdAt: Date.now(),
  });
  await saveRules(rules);
  return rules;
}

export async function deleteRule(id) {
  const rules = (await getRules()).filter((r) => r.id !== id);
  await saveRules(rules);
  return rules;
}

// Returns {prefer: [path...], avoid: Set(path)} for an email.
export async function matchRules(queryTerms, from) {
  const rules = await getRules();
  if (!rules.length) return { prefer: [], avoid: new Set() };
  const q = new Set(queryTerms instanceof Map ? queryTerms.keys() : queryTerms);
  const dom = domainOf(from);
  const scored = [];
  for (const r of rules) {
    const overlap = r.terms.filter((t) => q.has(t)).length;
    const senderHit = r.sender && dom && r.sender === dom;
    const need = Math.min(2, r.terms.length);
    const matched = overlap >= need || (senderHit && overlap >= 1);
    if (!matched) continue;
    // Skip rules whose document no longer exists in the index.
    if (!(await get('files', r.path))) continue;
    scored.push([r, (overlap / Math.max(3, Math.min(r.terms.length, 8))) * (r.weight || 1) + (senderHit ? 0.5 : 0)]);
  }
  scored.sort((a, b) => b[1] - a[1]);
  const prefer = [];
  const avoid = new Set();
  for (const [r] of scored) {
    if (r.kind === 'avoid') avoid.add(r.path);
    else if (!prefer.includes(r.path)) prefer.push(r.path);
  }
  return { prefer: prefer.filter((p) => !avoid.has(p)).slice(0, 3), avoid };
}
