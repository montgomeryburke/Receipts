// Power Automate bridge.
//
// Each configured "action" is one flow. Two transports:
//  - http:   POST to the flow's "When an HTTP request is received" URL
//            (premium trigger). Sync responses and the 202 + Location async
//            pattern are both handled.
//  - folder: write <bridge>/requests/<id>.json into a OneDrive-synced folder;
//            a flow with the standard "When a file is created" trigger does
//            the work and writes <bridge>/responses/<id>.json back.
// Flows do the SharePoint/Excel, SAP and GCdocs work; this side only sends
// requests and reads results.

import { kvGet, kvSet, log } from './db.js';
import { getRootHandle, getFileByPath, writeFile, removeFile } from './fsutil.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function enabledActions(settings) {
  return (settings.actions || []).filter((a) => a && a.enabled !== false && a.name);
}

export function findAction(settings, name) {
  const n = String(name || '').trim().toLowerCase();
  return enabledActions(settings).find((a) => a.name.toLowerCase() === n) || null;
}

// "po_number: SAP purchase order number, project" -> [{name, hint}]
export function paramSpec(action) {
  return String(action.params || '').split(/[,\n]/).map((p) => p.trim()).filter(Boolean).map((p) => {
    const [name, ...rest] = p.split(':');
    const [key, def] = name.split('=');
    return { name: key.trim(), hint: rest.join(':').trim(), template: (def || '').trim() };
  });
}

// Short, stable text for the system prompt (kept cacheable).
export function actionsPromptBlock(settings) {
  const acts = enabledActions(settings);
  if (!acts.length) return '';
  const lines = acts.map((a) => {
    const ps = paramSpec(a).map((p) => (p.hint ? `${p.name} (${p.hint})` : p.name)).join(', ');
    return `- ${a.name} [${a.kind === 'write' ? 'write — user must approve' : 'read'}]: ${a.description || ''}${ps ? ` Params: ${ps}.` : ''}`;
  });
  return `\n\nData actions (Power Automate flows) you may request through "data_requests" when an answer depends on data that is not in the excerpts — e.g. SAP figures or a SharePoint tracker. Request only what the email needs, at most 3, and only actions from this list:\n${lines.join('\n')}\nWrite actions change records; propose them only when the email clearly calls for it.`;
}

// Fills {{field}} templates from an item.
export function fillTemplate(tpl, item) {
  return String(tpl || '').replace(/\{\{\s*(\w+)\s*\}\}/g, (_, f) => {
    if (f === 'project') return (item.projects || [])[0] || '';
    if (f === 'missing') return (item.missing || []).join('; ');
    if (f === 'date') return new Date().toISOString().slice(0, 10);
    const v = item[f];
    return v == null ? '' : String(v);
  });
}

export function defaultParams(action, item) {
  const out = {};
  for (const p of paramSpec(action)) out[p.name] = p.template ? fillTemplate(p.template, item) : '';
  return out;
}

function requestBody(action, params, item, requestId) {
  return {
    requestId,
    action: action.name,
    kind: action.kind || 'read',
    params,
    createdAt: new Date().toISOString(),
    source: 'MailMirror',
    item: item ? {
      id: item.id, subject: item.subject, from: item.from, receivedAt: item.receivedAt,
      project: (item.projects || [])[0] || '', summary: item.summary || '', status: item.status || '',
    } : null,
    replyTo: action.transport === 'folder' ? `responses/${requestId}.json` : undefined,
  };
}

function normalizeResult(body) {
  if (body && typeof body === 'object' && ('ok' in body || 'data' in body || 'message' in body)) {
    return { ok: body.ok !== false, data: body.data ?? null, message: body.message || '' };
  }
  return { ok: true, data: body, message: '' };
}

async function readBody(res) {
  const text = await res.text();
  try { return text ? JSON.parse(text) : null; } catch { return text; }
}

async function runHttp(action, body, { signal } = {}) {
  const timeoutMs = (Number(action.timeoutSec) || 300) * 1000;
  const started = Date.now();
  let res = await fetch(action.url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal,
  });
  // Async response pattern: 202 + Location, poll until done.
  if (res.status === 202 && !res.headers.get('location')) {
    return { ok: true, data: null, message: 'Flow accepted the request but returned no result (add a Response action to the flow to send data back).' };
  }
  while (res.status === 202 && res.headers.get('location')) {
    if (Date.now() - started > timeoutMs) throw new Error('flow timed out');
    const wait = Math.min(Number(res.headers.get('retry-after')) || 5, 30);
    await sleep(wait * 1000);
    res = await fetch(res.headers.get('location'), { signal });
  }
  const parsed = await readBody(res);
  if (!res.ok) {
    const msg = typeof parsed === 'string' ? parsed.slice(0, 300) : (parsed?.error?.message || parsed?.message || res.statusText);
    throw new Error(`flow returned ${res.status}: ${msg}`);
  }
  return normalizeResult(parsed);
}

async function bridgeRoot() {
  const h = await getRootHandle('bridge');
  if (!h) throw new Error('No Automate bridge folder chosen (Settings → Power Automate)');
  return h;
}

export function newRequestId() {
  return `mm-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

// Runs an action. http: returns the result. folder: queues the request and
// returns {pending: true, requestId}; pollFolderResponses() picks it up later.
export async function runAction(action, params, item, { signal } = {}) {
  const requestId = newRequestId();
  const body = requestBody(action, params, item, requestId);
  if (action.transport === 'folder') {
    const root = await bridgeRoot();
    await writeFile(root, `requests/${requestId}.json`, new Blob([JSON.stringify(body, null, 2)], { type: 'application/json' }));
    const pending = (await kvGet('pendingActions')) || [];
    pending.push({ requestId, itemId: item?.id || '', action: action.name, params, at: Date.now(), timeoutSec: Number(action.timeoutSec) || 900 });
    await kvSet('pendingActions', pending);
    await log('automate', `Queued ${action.name} (${requestId}) in bridge folder`);
    return { pending: true, requestId };
  }
  if (!action.url) throw new Error(`Action "${action.name}" has no flow URL`);
  const result = await runHttp(action, body, { signal });
  await log('automate', `${action.name} → ${result.ok ? 'ok' : 'failed'}${result.message ? `: ${result.message}` : ''}`);
  return { ...result, requestId };
}

// Checks the bridge folder for responses. Returns [{requestId, itemId, action, ok, data, message}]
// for completed or timed-out requests and removes them from the pending list.
export async function pollFolderResponses() {
  const pending = (await kvGet('pendingActions')) || [];
  if (!pending.length) return [];
  let root;
  try { root = await bridgeRoot(); } catch { return []; }
  if (typeof root.queryPermission === 'function' && (await root.queryPermission({ mode: 'readwrite' })) !== 'granted') return [];
  const done = [];
  const still = [];
  for (const p of pending) {
    let fh = null;
    try { fh = await getFileByPath(root, `responses/${p.requestId}.json`); } catch { /* not yet */ }
    if (fh) {
      let result;
      try {
        result = normalizeResult(JSON.parse(await (await fh.getFile()).text()));
      } catch (err) {
        result = { ok: false, data: null, message: `unreadable response: ${err.message}` };
      }
      try { await removeFile(root, `responses/${p.requestId}.json`); } catch { /* flow may clean up itself */ }
      done.push({ ...p, ...result });
    } else if (Date.now() - p.at > p.timeoutSec * 1000) {
      try { await removeFile(root, `requests/${p.requestId}.json`); } catch { /* already taken */ }
      done.push({ ...p, ok: false, data: null, message: 'no response from the flow before the timeout' });
    } else {
      still.push(p);
    }
  }
  if (done.length) await kvSet('pendingActions', still);
  return done;
}

export function resultText(result, max = 3000) {
  let s = typeof result.data === 'string' ? result.data : JSON.stringify(result.data, null, 1);
  if (s == null) s = '';
  if (s.length > max) s = s.slice(0, max) + '…';
  return `${result.ok ? 'OK' : 'FAILED'}${result.message ? ` — ${result.message}` : ''}${s ? `\n${s}` : ''}`;
}
