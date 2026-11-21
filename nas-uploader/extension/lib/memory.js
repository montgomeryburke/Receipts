// What the assistant has been told and has learned, kept on this computer:
//  - standing instructions ("always write in French to Hydro-Québec", "don't prompt me about small talk"),
//    added to the email, meeting and chat prompts they apply to;
//  - project memory: short notes per project (decisions, terms, people, where things are), learned from
//    meetings and from the chat, used to make prompts project-specific;
//  - a change log with undo for every change the chat makes.
// All of it is small text, so it costs few tokens when it is added to a prompt.

import { getSettings, saveSettings, kvGet, kvSet, getAll, put, get, del, tx, reqP, txDone } from './db.js';
import { tokenize } from './text.js';

const newId = (p) => `${p}${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;

// ---------- standing instructions ----------

export const SCOPES = ['all', 'email', 'meeting', 'chat'];

export async function listInstructions() {
  return (await getSettings()).instructions || [];
}

export async function addInstruction(text, scope = 'all') {
  const t = String(text || '').trim();
  if (!t) throw new Error('An instruction needs some text');
  if (!SCOPES.includes(scope)) scope = 'all';
  const list = await listInstructions();
  if (list.some((i) => i.text.toLowerCase() === t.toLowerCase() && i.scope === scope)) return list;
  const next = [...list, { id: newId('i'), scope, text: t.slice(0, 600), at: Date.now() }];
  await saveSettings({ instructions: next });
  return next;
}

export async function removeInstruction(id) {
  const next = (await listInstructions()).filter((i) => i.id !== id);
  await saveSettings({ instructions: next });
  return next;
}

/** The instructions for one kind of job, as a prompt block ('' when there are none). */
export function instructionsBlock(settings, scope) {
  const list = (settings.instructions || []).filter((i) => i.scope === 'all' || i.scope === scope);
  if (!list.length) return '';
  return `\n\nStanding instructions from the user (follow them unless they conflict with the rules above):\n${list.map((i) => `- ${i.text}`).join('\n')}`;
}

// ---------- project memory ----------

const MEMORY_KEY = (project) => `memory:${project}`;
const MAX_NOTES = 60;

export async function getMemory(project) {
  if (!project) return { project: '', notes: [] };
  return (await kvGet(MEMORY_KEY(project))) || { project, notes: [] };
}

export async function addMemory(project, text, source = 'chat') {
  const t = String(text || '').trim();
  if (!project || !t) throw new Error('A memory note needs a project and some text');
  const mem = await getMemory(project);
  if (mem.notes.some((n) => n.text.toLowerCase() === t.toLowerCase())) return mem;
  mem.notes.push({ id: newId('n'), text: t.slice(0, 500), source, at: Date.now(), uses: 0 });
  // Keep the most useful notes: drop the oldest never-used ones first.
  while (mem.notes.length > MAX_NOTES) {
    let drop = 0;
    for (let i = 1; i < mem.notes.length; i++) {
      const a = mem.notes[i];
      const b = mem.notes[drop];
      if ((a.uses || 0) < (b.uses || 0) || ((a.uses || 0) === (b.uses || 0) && a.at < b.at)) drop = i;
    }
    mem.notes.splice(drop, 1);
  }
  await kvSet(MEMORY_KEY(project), mem);
  await noteProject(project);
  return mem;
}

export async function removeMemory(project, id) {
  const mem = await getMemory(project);
  mem.notes = mem.notes.filter((n) => n.id !== id);
  await kvSet(MEMORY_KEY(project), mem);
  return mem;
}

async function noteProject(project) {
  const known = (await kvGet('memoryProjects')) || [];
  if (!known.includes(project)) await kvSet('memoryProjects', [...known, project]);
}

export async function memoryProjects() {
  return (await kvGet('memoryProjects')) || [];
}

/**
 * The notes about these projects that best match the text, as a prompt block (capped, so it stays cheap).
 * Marks the chosen notes as used, so useful notes survive pruning.
 */
export async function memoryBlock(projects, text, maxChars = 1200) {
  const list = [...new Set((projects || []).filter(Boolean))];
  if (!list.length) return '';
  const words = new Set(tokenize(text || ''));
  const out = [];
  let used = 0;
  for (const project of list) {
    const mem = await getMemory(project);
    if (!mem.notes.length) continue;
    const scored = mem.notes
      .map((n) => [n, tokenize(n.text).filter((w) => words.has(w)).length + (n.uses || 0) * 0.05 + n.at / 1e15])
      .sort((a, b) => b[1] - a[1]);
    const lines = [];
    for (const [n] of scored) {
      if (used + n.text.length > maxChars) break;
      lines.push(`- ${n.text}`);
      used += n.text.length;
      n.uses = (n.uses || 0) + 1;
    }
    if (lines.length) {
      out.push(`${project.split('/').pop()}:\n${lines.join('\n')}`);
      await kvSet(MEMORY_KEY(project), mem);
    }
  }
  return out.length ? `<project_memory>\nWhat the user's earlier meetings and notes established (treat as background, check against the files):\n${out.join('\n')}\n</project_memory>` : '';
}

// ---------- change log with undo ----------

/**
 * Records a change so it can be undone. before: {settings: {key: oldValue}} and/or {kv: {key: oldValue}}.
 * Returns the change id.
 */
export async function recordChange(summary, before, tool = '') {
  const rec = { at: Date.now(), summary, before, tool, undone: false };
  const txn = await tx(['changes'], 'readwrite');
  const id = await reqP(txn.objectStore('changes').add(rec));
  await txDone(txn);
  return id;
}

export async function listChanges(limit = 30) {
  const all = await getAll('changes');
  return all.sort((a, b) => b.at - a.at).slice(0, limit);
}

export async function undoChange(id) {
  const rec = await get('changes', id);
  if (!rec) throw new Error('That change is not in the log any more');
  if (rec.undone) return rec;
  if (rec.before?.settings) await saveSettings(rec.before.settings);
  for (const [k, v] of Object.entries(rec.before?.kv || {})) await kvSet(k, v ?? null);
  rec.undone = true;
  rec.undoneAt = Date.now();
  await put('changes', rec);
  return rec;
}

export async function clearChanges() {
  for (const c of await getAll('changes')) await del('changes', c.id);
}
