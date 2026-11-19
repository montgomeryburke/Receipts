// Outlook emails in the project index. Every email the assistant reads (drafted, or listed with "Index these
// emails" in Outlook on the web) is stored here as one searchable document with its whole chain, filed under its
// project (project number or name in it, or people / keywords given for the project). No AI is used: it costs
// nothing. Email drafts, meeting prompts and the chat then find earlier emails like any project file.

import { kvGet, kvSet, get } from './db.js';
import { IndexWriter } from './index.js';
import { chunkText, cleanEmailBody, threadOf, emailId, hashString, parseMailDate, localDay } from './text.js';
import { detectProjects } from './projects.js';

/**
 * The tag in an email document's name, e.g. "[c3f9a2b]": one per Outlook conversation (its newest message holds
 * the whole chain), else one per email.
 */
export function mailTag(email) {
  return email.convId ? `c${hashString(String(email.convId)).slice(-6)}` : emailId(email).slice(-6);
}
const safe = (s) => String(s || '').replace(/[\\/:*?"<>|\u0000-\u001f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80) || '(no subject)';

/** The text that is indexed: the headers, the newest message and every earlier message of the thread. */
export function mailDocument(email) {
  const latest = cleanEmailBody(email.body, 20000);
  const thread = threadOf(email, { maxThreadChars: 40000 });
  const head = [`Email: ${email.subject || '(no subject)'}`, `From: ${email.from || ''}`, email.to ? `To: ${email.to}` : '', email.cc ? `Cc: ${email.cc}` : '', `Date: ${email.receivedAt || ''}`].filter(Boolean).join('\n');
  const earlier = thread.map((m) => `From: ${m.from || 'unknown'}${m.date ? ` | Date: ${m.date}` : ''}${m.subject ? ` | Subject: ${m.subject}` : ''}\n${m.text}`).join('\n\n');
  return { text: `${head}\n\n${latest}${earlier ? `\n\n— Earlier messages in this thread —\n\n${earlier}` : ''}`, latest, thread };
}

// One email at a time: drafting, "Index these emails" and the chat can all add emails.
let queue = Promise.resolve();

/**
 * Indexes one email (with its chain). Returns {path, project}. An Outlook conversation is one document: a newer
 * message replaces it (also when its project changed); an older message of it is skipped.
 */
export function indexEmail(email, opts) {
  const run = queue.then(() => indexOne(email, opts));
  queue = run.catch(() => {});
  return run;
}

async function indexOne(email, { projects } = {}) {
  if (!String(email?.body || '').trim()) throw new Error('empty email');
  const id = emailId(email);
  const key = email.convId ? `mailconv:${hashString(String(email.convId))}` : `mailpath:${id}`;
  const prev = await kvGet(key);
  const prevPath = typeof prev === 'string' ? prev : prev?.path || '';
  const parsed = parseMailDate(email.receivedAt);
  if (email.convId && prev?.when && !Number.isNaN(parsed) && parsed < prev.when) return { path: prevPath, project: prev.project || '', kept: true };
  const doc = mailDocument(email);
  const people = [email.from, email.to, email.cc, ...doc.thread.map((m) => m.from)];
  const project = (projects && projects.length ? projects : await detectProjects(`${email.subject}\n${doc.latest}\n${doc.thread.map((m) => m.text).join('\n').slice(0, 6000)}`, { people }))[0] || '';
  // The date Outlook showed; when it can't be read, the date first seen (so re-indexing doesn't move it to today).
  const when = !Number.isNaN(parsed) ? parsed : (prevPath && (await get('files', prevPath))?.mtime) || Date.now();
  const path = `${project ? `${project}/` : ''}Emails/${localDay(when)} ${safe(email.subject)} [${mailTag(email)}].eml`;
  const w = new IndexWriter();
  if (prevPath && prevPath !== path) await w.removeFile(prevPath);
  // Before conversations were kept as one document, each message had its own: replaced by this one.
  const perMessage = email.convId ? await kvGet(`mailpath:${id}`) : '';
  if (perMessage && perMessage !== path) await w.removeFile(perMessage);
  const brief = { from: String(email.from || '').slice(0, 160), subject: String(email.subject || '').slice(0, 200), latest: doc.latest.slice(0, 700) };
  await w.addFile(
    { path, rel: path, folderId: 'mail', size: doc.text.length, mtime: when, ext: 'eml', project, method: 'mail', chars: doc.text.length, note: String(email.from || '').slice(0, 120), indexedAt: Date.now(), brief, dateKnown: !Number.isNaN(parsed) },
    chunkText(doc.text),
  );
  await w.finish();
  await kvSet(key, email.convId ? { path, when, project } : path);
  if (perMessage) await kvSet(`mailpath:${id}`, null);
  if (project) {
    const list = (await kvGet('projects')) || [];
    if (!list.includes(project)) await kvSet('projects', [...list, project].sort());
  }
  return { path, project };
}
