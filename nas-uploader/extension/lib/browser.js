// Controls a Chrome tab for the browser agent through the DevTools protocol (chrome.debugger):
// real (trusted) mouse clicks and key presses, typing, screenshots, and a numbered list of the page's
// interactive elements, so the AI can act by number instead of guessing coordinates (cheaper and more
// reliable than screenshots alone). Chrome shows "Project Assistant started debugging this browser" while
// a tab is controlled; cancelling that bar stops the agent.

const VERSION = '1.3';

// Runs in the page: numbers the visible interactive elements and returns them with the page text.
function snapshotPage(maxEls, maxText) {
  const SEL = 'a[href],button,input,select,textarea,summary,label[for],[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=combobox],[role=textbox],[role=switch],[role=slider],[contenteditable=""],[contenteditable="true"],[onclick],[tabindex]:not([tabindex="-1"])';
  document.querySelectorAll('[data-agent-id]').forEach((e) => e.removeAttribute('data-agent-id'));
  const vw = innerWidth;
  const vh = innerHeight;
  const shown = (e) => {
    const r = e.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return null;
    const st = getComputedStyle(e);
    if (st.visibility === 'hidden' || st.display === 'none' || Number(st.opacity) === 0) return null;
    return r;
  };
  const clean = (s) => String(s || '').replace(/\s+/g, ' ').trim();
  const labelOf = (e) => {
    const by = e.getAttribute('aria-labelledby');
    const fromIds = by ? by.split(/\s+/).map((id) => document.getElementById(id)?.innerText || '').join(' ') : '';
    const labels = e.labels ? [...e.labels].map((l) => l.innerText).join(' ') : '';
    const tag = e.tagName;
    const own = tag === 'INPUT' && /^(button|submit|reset)$/i.test(e.type) ? e.value : tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' ? '' : e.innerText;
    return clean(e.getAttribute('aria-label') || fromIds || labels || own || e.getAttribute('placeholder') || e.getAttribute('title') || e.getAttribute('alt') || e.getAttribute('name') || '');
  };
  const items = [];
  for (const e of document.querySelectorAll(SEL)) {
    const r = shown(e);
    if (!r) continue;
    const inView = r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw;
    items.push({ e, inView });
  }
  items.sort((a, b) => Number(b.inView) - Number(a.inView));
  const out = [];
  let n = 0;
  for (const { e, inView } of items.slice(0, maxEls)) {
    n++;
    e.setAttribute('data-agent-id', String(n));
    const tag = e.tagName.toLowerCase();
    const type = (e.getAttribute('type') || '').toLowerCase();
    const o = { n, tag };
    if (type) o.type = type;
    const role = e.getAttribute('role');
    if (role) o.role = role;
    o.name = labelOf(e).slice(0, 80);
    if (tag === 'input' || tag === 'textarea' || tag === 'select') {
      if (type === 'password') {
        o.password = true;
        o.value = e.value ? '(filled)' : '';
      } else if (type === 'file') {
        o.file = true;
        if (e.multiple) o.multiple = true;
        o.value = [...(e.files || [])].map((f) => f.name).join(', ');
      } else if (type !== 'checkbox' && type !== 'radio') o.value = String(e.value ?? '').slice(0, 100);
    }
    if (e.isContentEditable) o.value = clean(e.innerText).slice(0, 100);
    if (type === 'checkbox' || type === 'radio') o.checked = !!e.checked;
    if (tag === 'select') o.options = [...e.options].slice(0, 30).map((op) => clean(op.text).slice(0, 40));
    if (e.disabled) o.disabled = true;
    if (e.required) o.required = true;
    if (tag === 'a' && e.href) o.href = e.href.slice(0, 140);
    const ac = e.getAttribute('autocomplete') || '';
    if (/cc-|card/i.test(ac + ' ' + (e.name || '') + ' ' + (e.id || ''))) o.payment = true;
    if (!inView) o.offscreen = true;
    out.push(o);
  }
  const text = clean((document.body?.innerText || '').replace(/\n{2,}/g, ' ¶ ')).slice(0, maxText);
  return {
    url: location.href,
    title: document.title,
    elements: out,
    more_elements: Math.max(0, items.length - maxEls),
    text,
    iframes: document.querySelectorAll('iframe').length,
    scroll: { y: Math.round(scrollY), height: document.documentElement.scrollHeight, viewport: vh },
  };
}

// Runs in the page: scrolls element n into view and returns its centre and what it is.
function locate(n) {
  const e = document.querySelector(`[data-agent-id="${n}"]`);
  if (!e) return null;
  e.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
  const r = e.getBoundingClientRect();
  const x = r.left + r.width / 2;
  const y = r.top + r.height / 2;
  const at = document.elementFromPoint(x, y);
  const covered = at && at !== e && !e.contains(at) && !at.contains(e) ? (at.innerText || at.tagName).trim().slice(0, 60) : '';
  const form = e.form || e.closest('form');
  return {
    x, y,
    tag: e.tagName.toLowerCase(),
    type: (e.getAttribute('type') || '').toLowerCase(),
    name: (e.getAttribute('aria-label') || (e.labels && [...e.labels].map((l) => l.innerText).join(' ')) || (/^(INPUT|TEXTAREA|SELECT)$/.test(e.tagName) && !/^(button|submit|reset)$/i.test(e.type) ? '' : e.innerText || e.value) || e.getAttribute('placeholder') || e.getAttribute('title') || e.getAttribute('name') || '').replace(/\s+/g, ' ').trim().slice(0, 80),
    href: e.href || '',
    inForm: !!form,
    submits: (e.tagName === 'BUTTON' && (e.type || 'submit') === 'submit' && !!form) || (e.tagName === 'INPUT' && /^(submit|image)$/i.test(e.type)),
    password: e.type === 'password',
    payment: /cc-|card/i.test(`${e.getAttribute('autocomplete') || ''} ${e.name || ''} ${e.id || ''}`),
    editable: e.isContentEditable || /^(INPUT|TEXTAREA)$/.test(e.tagName),
    covered,
  };
}

function prepareTyping(n, clear) {
  const e = document.querySelector(`[data-agent-id="${n}"]`);
  if (!e) return { error: 'element not found' };
  e.focus();
  if (clear) {
    if (typeof e.select === 'function' && /^(INPUT|TEXTAREA)$/.test(e.tagName)) e.select();
    else if (e.isContentEditable) {
      const range = document.createRange();
      range.selectNodeContents(e);
      const sel = getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    }
  }
  return { ok: true };
}

function readValue(n) {
  const e = document.querySelector(`[data-agent-id="${n}"]`);
  if (!e) return null;
  if (e.tagName === 'SELECT') return e.options[e.selectedIndex]?.text?.trim() ?? '';
  if (/^(INPUT|TEXTAREA)$/.test(e.tagName)) return e.type === 'password' ? '' : String(e.value);
  return (e.innerText || '').trim();
}

function chooseOption(n, wanted) {
  const e = document.querySelector(`[data-agent-id="${n}"]`);
  if (!e || e.tagName !== 'SELECT') return { error: 'not a drop-down list (select); click it and pick from the list instead' };
  const w = String(wanted).trim().toLowerCase();
  const opts = [...e.options];
  const opt = opts.find((o) => o.text.trim().toLowerCase() === w) || opts.find((o) => o.value.toLowerCase() === w) || opts.find((o) => o.text.trim().toLowerCase().includes(w));
  if (!opt) return { error: `no option "${wanted}"`, options: opts.map((o) => o.text.trim()).slice(0, 30) };
  e.value = opt.value;
  e.dispatchEvent(new Event('input', { bubbles: true }));
  e.dispatchEvent(new Event('change', { bubbles: true }));
  return { ok: true, selected: opt.text.trim() };
}

function putFiles(n, files, mode) {
  const e = document.querySelector(`[data-agent-id="${n}"]`);
  if (!e) return { error: 'element not found' };
  const dt = new DataTransfer();
  for (const f of files) {
    const bin = atob(f.b64);
    const u8 = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
    dt.items.add(new File([u8], f.name, { type: f.type || 'application/octet-stream', lastModified: Date.now() }));
  }
  if (e.tagName === 'INPUT' && e.type === 'file') {
    e.files = dt.files;
    e.dispatchEvent(new Event('input', { bubbles: true }));
    e.dispatchEvent(new Event('change', { bubbles: true }));
    return { ok: true, how: 'file input', files: [...e.files].map((f) => ({ name: f.name, size: f.size })) };
  }
  // A drop zone: the same files dropped on it.
  for (const type of ['dragenter', 'dragover', 'drop']) e.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: dt }));
  return { ok: true, how: 'dropped', files: files.map((f) => ({ name: f.name })) };
}

const KEYS = {
  Enter: [13, 'Enter', '\r'], Tab: [9, 'Tab'], Escape: [27, 'Escape'], Backspace: [8, 'Backspace'], Delete: [46, 'Delete'],
  ArrowUp: [38, 'ArrowUp'], ArrowDown: [40, 'ArrowDown'], ArrowLeft: [37, 'ArrowLeft'], ArrowRight: [39, 'ArrowRight'],
  Home: [36, 'Home'], End: [35, 'End'], PageUp: [33, 'PageUp'], PageDown: [34, 'PageDown'], Space: [32, 'Space', ' '],
  F5: [116, 'F5'],
};
const MOD = { Alt: 1, Control: 2, Ctrl: 2, Meta: 4, Cmd: 4, Shift: 8 };
const COMMANDS = { a: 'selectAll', c: 'copy', v: 'paste', x: 'cut', z: 'undo', y: 'redo' };

/** "Control+A" → the CDP key event fields. */
export function keyEvent(combo) {
  const parts = String(combo).split('+').map((p) => p.trim()).filter(Boolean);
  let modifiers = 0;
  let key = parts.pop() || '';
  for (const p of parts) {
    const m = MOD[p[0].toUpperCase() + p.slice(1).toLowerCase()];
    if (!m) throw new Error(`unknown modifier "${p}"`);
    modifiers |= m;
  }
  if (/^space$/i.test(key)) key = 'Space';
  const named = KEYS[key] || KEYS[Object.keys(KEYS).find((k) => k.toLowerCase() === key.toLowerCase())];
  if (named) {
    const [code, name, text] = named;
    return { key: name === 'Space' ? ' ' : name, code: name === 'Space' ? 'Space' : name, windowsVirtualKeyCode: code, modifiers, text: modifiers & 2 ? undefined : text };
  }
  if (key.length === 1) {
    const ch = key;
    const upper = ch.toUpperCase();
    const isLetter = /[a-z]/i.test(ch);
    const isDigit = /\d/.test(ch);
    return {
      key: modifiers & 8 && isLetter ? upper : ch,
      code: isLetter ? `Key${upper}` : isDigit ? `Digit${ch}` : '',
      windowsVirtualKeyCode: isLetter ? upper.charCodeAt(0) : isDigit ? ch.charCodeAt(0) : 0,
      modifiers,
      text: modifiers & (2 | 4) ? undefined : modifiers & 8 ? upper : ch,
      commands: modifiers & (2 | 4) && COMMANDS[ch.toLowerCase()] ? [COMMANDS[ch.toLowerCase()]] : undefined,
    };
  }
  throw new Error(`unknown key "${key}"`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export class TabControl {
  constructor(tabId, { onDetach, onDialog } = {}) {
    this.tabId = tabId;
    this.target = { tabId };
    this.attached = false;
    this.dialog = null; // {type, message} while a page dialog is open
    this.onDetach = onDetach;
    this.onDialog = onDialog;
    this.scale = 1;
    this._onEvent = (src, method, params) => {
      if (src.tabId !== this.tabId) return;
      if (method === 'Page.javascriptDialogOpening') {
        this.dialog = { type: params.type, message: String(params.message || '').slice(0, 500), defaultPrompt: params.defaultPrompt || '' };
        this.onDialog?.(this.dialog);
      }
      if (method === 'Page.javascriptDialogClosed') this.dialog = null;
    };
    this._onDetach = (src, reason) => {
      if (src.tabId !== this.tabId) return;
      this.attached = false;
      this.onDetach?.(reason);
    };
  }

  async attach() {
    if (this.attached) return;
    await chrome.debugger.attach(this.target, VERSION);
    this.attached = true;
    chrome.debugger.onEvent.addListener(this._onEvent);
    chrome.debugger.onDetach.addListener(this._onDetach);
    await this.send('Page.enable');
  }

  async detach() {
    chrome.debugger.onEvent.removeListener(this._onEvent);
    chrome.debugger.onDetach.removeListener(this._onDetach);
    if (this.attached) await chrome.debugger.detach(this.target).catch(() => {});
    this.attached = false;
  }

  send(method, params = {}) {
    return chrome.debugger.sendCommand(this.target, method, params);
  }

  /** Runs fn(...args) in the page and returns its (JSON) result. */
  async run(fn, ...args) {
    if (this.dialog) throw new Error(`A ${this.dialog.type} dialog is open on the page ("${this.dialog.message}"). Answer it first (answer_dialog).`);
    const res = await this.send('Runtime.evaluate', { expression: `(${fn.toString()})(...${JSON.stringify(args)})`, returnByValue: true, awaitPromise: true, userGesture: true });
    if (res.exceptionDetails) throw new Error(res.exceptionDetails.exception?.description?.split('\n')[0] || res.exceptionDetails.text || 'page script failed');
    return res.result?.value;
  }

  /** Waits for the page to settle after an action (navigation or not). */
  async settle(maxMs = 8000) {
    await sleep(250);
    const end = Date.now() + maxMs;
    while (Date.now() < end) {
      if (this.dialog) return;
      try {
        const st = await this.run(() => document.readyState);
        if (st === 'complete') return;
      } catch {
        /* the page is changing */
      }
      await sleep(250);
    }
  }

  snapshot({ maxElements = 120, maxText = 3000 } = {}) {
    return this.run(snapshotPage, maxElements, maxText);
  }

  locate(n) {
    return this.run(locate, n);
  }

  async mouse(type, x, y, extra = {}) {
    await this.send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1, ...extra });
  }

  async clickAt(x, y, { double = false } = {}) {
    await this.mouse('mouseMoved', x, y, { button: 'none', clickCount: 0 });
    await this.mouse('mousePressed', x, y);
    await this.mouse('mouseReleased', x, y);
    if (double) {
      await this.mouse('mousePressed', x, y, { clickCount: 2 });
      await this.mouse('mouseReleased', x, y, { clickCount: 2 });
    }
  }

  async typeText(text) {
    await this.send('Input.insertText', { text });
  }

  prepareTyping(n, clear) {
    return this.run(prepareTyping, n, clear);
  }

  readValue(n) {
    return this.run(readValue, n);
  }

  chooseOption(n, wanted) {
    return this.run(chooseOption, n, wanted);
  }

  putFiles(n, files, mode) {
    return this.run(putFiles, n, files, mode);
  }

  async key(combo, { holdMs = 0 } = {}) {
    const ev = keyEvent(combo);
    await this.send('Input.dispatchKeyEvent', { type: ev.text ? 'keyDown' : 'rawKeyDown', ...ev });
    if (holdMs) await sleep(Math.min(holdMs, 5000));
    await this.send('Input.dispatchKeyEvent', { type: 'keyUp', key: ev.key, code: ev.code, windowsVirtualKeyCode: ev.windowsVirtualKeyCode, modifiers: ev.modifiers });
  }

  async scroll(dy, at) {
    const m = await this.send('Page.getLayoutMetrics');
    const vp = m.cssVisualViewport || m.visualViewport;
    const x = at?.x ?? vp.clientWidth / 2;
    const y = at?.y ?? vp.clientHeight / 2;
    await this.send('Input.dispatchMouseEvent', { type: 'mouseWheel', x, y, deltaX: 0, deltaY: dy });
  }

  /** A JPEG of what is visible, at most 1024 px wide. Returns {b64, width, height, scale}. */
  async screenshot() {
    if (this.dialog) throw new Error(`A ${this.dialog.type} dialog is open on the page ("${this.dialog.message}"). Answer it first (answer_dialog).`);
    const m = await this.send('Page.getLayoutMetrics');
    const vp = m.cssVisualViewport || m.visualViewport;
    const scale = Math.min(1, 1024 / vp.clientWidth);
    const shot = await this.send('Page.captureScreenshot', {
      format: 'jpeg',
      quality: 60,
      clip: { x: vp.pageX, y: vp.pageY, width: vp.clientWidth, height: vp.clientHeight, scale },
    });
    this.scale = scale;
    return { b64: shot.data, width: Math.round(vp.clientWidth * scale), height: Math.round(vp.clientHeight * scale), scale };
  }

  async navigate(url) {
    const r = await this.send('Page.navigate', { url });
    if (r.errorText) throw new Error(`couldn't open ${url}: ${r.errorText}`);
    await this.settle(20000);
  }

  async answerDialog(accept, promptText) {
    if (!this.dialog) return { error: 'no dialog is open' };
    await this.send('Page.handleJavaScriptDialog', { accept: !!accept, ...(promptText != null ? { promptText: String(promptText) } : {}) });
    this.dialog = null;
    await this.settle();
    return { ok: true };
  }
}
