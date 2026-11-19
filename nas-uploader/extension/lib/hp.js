// Commands on the HP: the NAS container runs them for the extension (setup-webdav.sh --enable-commands), as its
// limited "nas-runner" user, behind the NAS login and a separate command key (Settings → Run on the HP).
// Nothing runs on this computer: Chrome doesn't allow that.

import { getSettings } from './db.js';
import { nasCreds } from './nas.js';
import { basicAuthHeader } from './util.js';
import { CONFIG, loadConfig } from './config-store.js';

/** The command endpoint: <NAS address>/.run */
async function endpoint() {
  await loadConfig();
  if (!CONFIG.serverUrl || /your-nas\.example/.test(CONFIG.serverUrl)) throw new Error('Connect the NAS first (NAS files → Connect).');
  return new URL('.run', CONFIG.serverUrl.endsWith('/') ? CONFIG.serverUrl : `${CONFIG.serverUrl}/`).href;
}

export async function hpCommandsReady(settings) {
  const s = settings || (await getSettings());
  return Boolean(s.hpCommandKey);
}

/**
 * Runs one command on the HP. Returns {exit, stdout, stderr, ms, timed_out, cwd} or throws with a plain-words
 * reason. `cwd` defaults to the shared folder; `timeout` in seconds (max 600).
 */
export async function runOnHp(cmd, { cwd = '', timeout = 60, signal } = {}) {
  const s = await getSettings();
  if (!s.hpCommandKey) throw new Error('Commands on the HP are not set up: run the NAS setup script with --enable-commands, then paste the command key it prints into Settings → Run on the HP.');
  const c = await nasCreds();
  if (!c) throw new Error('The NAS login is missing (NAS files → Connect).');
  const res = await fetch(await endpoint(), {
    method: 'POST',
    headers: { authorization: basicAuthHeader(c.username, c.password), 'x-command-key': s.hpCommandKey, 'content-type': 'application/json' },
    body: JSON.stringify({ cmd: String(cmd), cwd: String(cwd || ''), timeout: Math.max(1, Math.min(600, Number(timeout) || 60)) }),
    signal,
    credentials: 'omit',
    cache: 'no-store',
  });
  let data = {};
  try {
    data = await res.json();
  } catch {
    /* not JSON (e.g. a 404 page) */
  }
  if (res.status === 401) throw new Error('The NAS refused the login.');
  if (res.status === 403) throw new Error('Wrong command key (Settings → Run on the HP).');
  if (res.status === 404) throw new Error('Commands are not switched on on the HP: run the NAS setup script with --enable-commands.');
  if (res.status === 409) throw new Error('Another command is still running on the HP.');
  if (!res.ok || data.error) throw new Error(data.error || `The HP answered ${res.status}`);
  return data;
}

/** Short text for the chat / UI. */
export function commandResultText(r, max = 6000) {
  const out = [r.stdout ? r.stdout.trimEnd() : '', r.stderr ? `[stderr]\n${r.stderr.trimEnd()}` : ''].filter(Boolean).join('\n');
  return `exit ${r.exit}${r.timed_out ? ' (stopped: time limit)' : ''} · ${r.ms} ms${out ? `\n${out.length > max ? `…${out.slice(-max)}` : out}` : ''}`;
}
