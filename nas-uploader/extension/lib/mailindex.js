// Outlook emails in the project index. Every email the assistant reads (drafted, or listed with "Index these
// emails" in Outlook on the web) is stored here as one searchable document with its whole chain, filed under its
// project (project number or name in it, or people / keywords given for the project). No AI is used: it costs
// nothing. Email drafts, meeting prompts and the chat then find earlier emails like any project file.

import { kvGet, kvSet } from './db.js';
import { IndexWriter } from './index.js';
import { chunkText, cleanEmailBody, threadOf, emailId } from './text.js';
import { detectProjects } from './projects.js';

const day = (d) => {
  const t = typeof d === 'number' ? d : Date.parse(String(d || '').replace(/\bat\b/i, ''));
  return Number.isNaN(t) ? '' : new Date(t).toISOString().slice(0, 10);
};
const safe = (s) => String(s || '').replace(/[\\/:*?"<>|\u0000-\u001f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80) || '(no subject)';

/** The text that is indexed: the headers, the newest message and every earlier message of the thread. */
export function mailDocument(email) {
  const latest = cleanEmailBody(email.body, 20000);
  const thread = threadOf(email, { maxThreadChars: 40000 });
  const head = [`Email: ${email.subject || '(no subject)'}`, `From: ${email.from || ''}`, email.to ? `To: ${email.to}` : '', email.cc ? `Cc: ${email.cc}` : '', `Date: ${email.receivedAt || ''}`].filter(Boolean).join('\n');
  const earlier = thread.map((m) => `From: ${m.from || 'unknown'}${m.date ? ` | Date: ${m.date}` : ''}${m.subject ? ` | Subject: ${m.subject}` : ''}\n${m.text}`).join('\n\n');
  return { text: `${head}\n\n${latest}${earlier ? `\n\n— Earlier messages in this thread —\n\n${earlier}` : ''}`, latest, thread };
}

/**
 * Indexes one email (with its chain). Returns {path, project}. Re-indexing the same email replaces the earlier
 * entry, also when its project changed.
 */
export async function indexEmail(email, { projects } = {}) {
  if (!String(email?.body || '').trim()) throw new Error('empty email');
  const id = emailId(email);
  const doc = mailDocument(email);
  const people = [email.from, email.to, email.cc, ...doc.thread.map((m) => m.from)];
  const project = (projects && projects.length ? projects : await detectProjects(`${email.subject}\n${doc.latest}\n${doc.thread.map((m) => m.text).join('\n').slice(0, 6000)}`, { people }))[0] || '';
  const when = Date.parse(String(email.receivedAt || '').replace(/\bat\b/i, '')) || Date.now();
  const path = `${project ? `${project}/` : ''}Emails/${day(when)} ${safe(email.subject)} [${id.slice(-6)}].eml`;
  const w = new IndexWriter();
  const old = await kvGet(`mailpath:${id}`);
  if (old && old !== path) await w.removeFile(old);
  await w.addFile(
    { path, rel: path, folderId: 'mail', size: doc.text.length, mtime: when, ext: 'eml', project, method: 'mail', chars: doc.text.length, note: String(email.from || '').slice(0, 120), indexedAt: Date.now() },
    chunkText(doc.text),
  );
  await w.finish();
  await kvSet(`mailpath:${id}`, path);
  if (project) {
    const list = (await kvGet('projects')) || [];
    if (!list.includes(project)) await kvSet('projects', [...list, project].sort());
  }
  return { path, project };
}
