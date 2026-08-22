import { Nas, loadSettings, saveSettings } from './api.js';

const baseUrlField = document.getElementById('base-url');
const tokenField = document.getElementById('token');
const statusBox = document.getElementById('status');
const saveButton = document.getElementById('save');

document.getElementById('extension-id').textContent = chrome.runtime.id;

function setStatus(text, kind) {
  statusBox.textContent = text;
  statusBox.className = `status ${kind}`;
}

function normaliseUrl(raw) {
  const trimmed = raw.trim().replace(/\/+$/, '');
  if (!trimmed) return '';
  // Default to https rather than http: the whole point of the Tailscale setup
  // is that this link is encrypted.
  return /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
}

// Chrome only grants host permissions in response to a user gesture, which is
// why this runs from the click handler rather than on page load.
async function ensurePermission(baseUrl) {
  const origin = `${new URL(baseUrl).origin}/*`;
  if (await chrome.permissions.contains({ origins: [origin] })) return true;
  return chrome.permissions.request({ origins: [origin] });
}

saveButton.addEventListener('click', async () => {
  const baseUrl = normaliseUrl(baseUrlField.value);
  const token = tokenField.value.trim();

  if (!baseUrl || !token) {
    setStatus('Enter both the address and the token.', 'error');
    return;
  }

  let origin;
  try {
    origin = new URL(baseUrl).origin;
  } catch {
    setStatus('That address is not a valid URL.', 'error');
    return;
  }

  saveButton.disabled = true;
  setStatus('Connecting…', 'busy');

  try {
    if (!(await ensurePermission(baseUrl))) {
      setStatus(`Permission to reach ${origin} was declined.`, 'error');
      return;
    }
    const nas = new Nas({ baseUrl, token });
    const identity = await nas.whoami();
    await saveSettings({ baseUrl, token });
    baseUrlField.value = baseUrl;
    const scopes = identity.scopes.includes('write') ? 'read and write' : 'read only';
    setStatus(`Connected as "${identity.name}" (${scopes}). Settings saved.`, 'ok');
  } catch (error) {
    setStatus(error.message, 'error');
  } finally {
    saveButton.disabled = false;
  }
});

document.getElementById('forget').addEventListener('click', async () => {
  await saveSettings({ baseUrl: '', token: '' });
  baseUrlField.value = '';
  tokenField.value = '';
  setStatus('Saved settings cleared.', 'ok');
});

(async function start() {
  const settings = await loadSettings();
  baseUrlField.value = settings.baseUrl || '';
  tokenField.value = settings.token || '';
})();
