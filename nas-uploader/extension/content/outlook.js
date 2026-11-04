// Runs inside Outlook on the web. Reads the open message, notices new mail
// in the message list, and inserts prepared drafts into a reply. It never
// sends anything. Selectors are deliberately loose (roles and labels in
// English and French) because Outlook's class names change often.

(() => {
  if (window.__mailmirrorLoaded) return;
  window.__mailmirrorLoaded = true;

  const send = (type, extra = {}) => chrome.runtime.sendMessage({ to: 'bg', type, ...extra }).catch(() => null);
  const engine = (payload) => send('engine', { payload });
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const qa = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const visible = (el) => !!el && el.isConnected && el.getClientRects().length > 0;

  async function waitFor(fn, timeout = 8000, every = 150) {
    const end = Date.now() + timeout;
    while (Date.now() < end) {
      const v = fn();
      if (v) return v;
      await sleep(every);
    }
    return null;
  }

  // ---------------- reading ----------------

  const BODY_SELECTORS = [
    'div[aria-label="Message body"]',
    'div[aria-label="Corps du message"]',
    '[data-testid="mailMessageBodyContainer"]',
    'div[role="document"]',
    'div.allowTextSelection',
  ];

  function readingPane() {
    return qa('[role="main"]').find(visible) || document.body;
  }

  function messageBodies(root = readingPane()) {
    for (const sel of BODY_SELECTORS) {
      const els = qa(sel, root).filter((el) => visible(el) && !el.isContentEditable && !el.closest('[contenteditable="true"]'));
      if (els.length) return els;
    }
    return [];
  }

  function selectedListItem() {
    return qa('[role="option"][aria-selected="true"]').find(visible) || null;
  }

  function itemIdFromUrl() {
    const m = location.href.match(/\/id\/([^/?#]+)/);
    return m ? decodeURIComponent(m[1]) : '';
  }

  // Walks up from the body to the message's own container (the closest
  // ancestor that also holds sender/date info), then reads header fields.
  function messageContainer(body) {
    let el = body;
    for (let i = 0; i < 8 && el.parentElement; i++) {
      el = el.parentElement;
      if (el.querySelector('[title*="@"], [aria-label^="From"], [aria-label^="De "], [aria-label^="De:"]')) return el;
    }
    return body.parentElement || body;
  }

  const EMAIL_RE = /[\w.+'-]+@[\w-]+(\.[\w-]+)+/;

  function senderOf(container) {
    const el = qa('[aria-label^="From"], [aria-label^="De "], [aria-label^="De:"], [title*="@"]', container).find(visible);
    if (el) {
      const title = el.getAttribute('title') || '';
      const label = el.getAttribute('aria-label') || '';
      const text = (el.textContent || '').trim();
      const email = (title.match(EMAIL_RE) || label.match(EMAIL_RE) || text.match(EMAIL_RE) || [])[0] || '';
      const name = text.replace(EMAIL_RE, '').replace(/[<>]/g, '').replace(/^(From|De)\s*:?\s*/i, '').trim();
      if (email || name) return name && email ? `${name} <${email}>` : (email || name);
    }
    const m = (container.innerText || '').slice(0, 400).match(EMAIL_RE);
    return m ? m[0] : '';
  }

  function recipientsOf(container, label) {
    const el = qa(`[aria-label^="${label}"]`, container).find(visible);
    return el ? (el.getAttribute('aria-label') || '').replace(new RegExp(`^${label}\\s*:?\\s*`, 'i'), '').slice(0, 300) : '';
  }

  const DATE_RE = /\b(\d{4}-\d{2}-\d{2}|\d{1,2}\/\d{1,2}\/\d{2,4}|(mon|tue|wed|thu|fri|sat|sun|lun|mar|mer|jeu|ven|sam|dim)[a-z.]*\s+\d{1,2}[/ -]\d{1,2}|\d{1,2}:\d{2}\s?(am|pm)?)/i;

  function dateOf(container) {
    const el = qa('[data-testid="SentReceivedSavedTime"], time, [title]', container)
      .find((e) => visible(e) && DATE_RE.test((e.getAttribute('title') || '') + ' ' + (e.textContent || '')) && (e.textContent || '').length < 80);
    if (!el) return '';
    return (el.getAttribute('datetime') || el.getAttribute('title') || el.textContent || '').trim();
  }

  const FOLDER_NAMES = /^(inbox|boîte de réception|focused|other|prioritaire|autres|sent items|éléments envoyés|drafts|brouillons|archive|deleted items|éléments supprimés)$/i;

  // The subject is the heading closest above the message body (the reading
  // pane can also contain folder and list headings).
  function subjectOf(pane, body) {
    const heads = qa('[role="heading"], h1, h2', pane)
      .filter(visible)
      .filter((e) => {
        const t = (e.textContent || '').trim();
        return t && t.length < 300 && !FOLDER_NAMES.test(t);
      });
    const before = body ? heads.filter((h) => h.compareDocumentPosition(body) & Node.DOCUMENT_POSITION_FOLLOWING) : heads;
    const pick = before.length ? before[before.length - 1] : heads[0];
    return pick ? pick.textContent.trim() : '';
  }

  function readOpenEmail() {
    const pane = readingPane();
    const bodies = messageBodies(pane);
    if (!bodies.length) return null;
    // Default conversation order is newest first; the newest message is the
    // first expanded body.
    const body = bodies[0];
    const container = messageContainer(body);
    const li = selectedListItem();
    const text = (body.innerText || '').trim();
    if (!text) return null;
    const subject = subjectOf(pane, body) || (li?.getAttribute('aria-label') || '').slice(0, 120);
    const convId = li?.getAttribute('data-convid') || '';
    return {
      id: itemIdFromUrl() || '',
      convId,
      subject,
      from: senderOf(container),
      to: recipientsOf(container, 'To'),
      cc: recipientsOf(container, 'Cc'),
      receivedAt: dateOf(container),
      body: text,
      source: 'outlook',
    };
  }

  // ---------------- settings & state ----------------

  let settings = { processOnOpen: true, autoScan: true, autoScanOnlyWhenIdle: true };
  async function refreshSettings() {
    const s = await send('settings.get');
    if (s && !s.error) settings = s;
  }

  let lastUserActivity = Date.now();
  for (const ev of ['mousemove', 'keydown', 'mousedown', 'wheel', 'touchstart']) {
    window.addEventListener(ev, (e) => { if (e.isTrusted) lastUserActivity = Date.now(); }, { passive: true, capture: true });
  }
  const userIsAway = () => document.hidden || Date.now() - lastUserActivity > 60000;

  // Conversations already seen (kept in memory; persisted so a reload does
  // not treat the whole inbox as new mail).
  const SEEN_KEY = 'mm_seenConv';
  let seenCache = null;
  async function loadSeen() {
    if (!seenCache) {
      const r = await chrome.storage.local.get(SEEN_KEY);
      seenCache = new Set(r[SEEN_KEY] || []);
    }
    return seenCache;
  }
  async function saveSeen(set) {
    const arr = [...set].slice(-3000);
    seenCache = new Set(arr);
    await chrome.storage.local.set({ [SEEN_KEY]: arr });
  }

  // ---------------- capture on open ----------------

  let lastKey = '';
  let captureTimer = null;
  let busy = false;

  async function captureOpen(auto) {
    const email = readOpenEmail();
    if (!email) return null;
    const key = email.id || `${email.convId}|${email.subject}|${email.body.slice(0, 120)}`;
    if (auto && key === lastKey) return null;
    lastKey = key;
    // Let Outlook finish rendering (images, expanding) before reading for real.
    await sleep(500);
    const again = readOpenEmail();
    const final = again && again.body.length >= email.body.length ? again : email;
    return final;
  }

  function scheduleCapture() {
    if (captureTimer || busy) return;
    captureTimer = setTimeout(async () => {
      captureTimer = null;
      if (!settings.processOnOpen || busy) return;
      // Only mail that arrived after the extension started watching is
      // drafted automatically; older mail is drafted on request, so browsing
      // the archive never spends tokens.
      const convId = selectedListItem()?.getAttribute('data-convid');
      if (!convId) return;
      const seen = await loadSeen();
      if (!baselined || seen.has(convId)) return;
      const email = await captureOpen(true);
      if (email) {
        await engine({ type: 'email.capture', email });
        seen.add(convId);
        await saveSeen(seen);
      }
    }, 900);
  }

  // ---------------- new-mail scanning ----------------

  function listItems() {
    return qa('[role="option"][data-convid]').filter(visible).slice(0, 40);
  }

  let baselined = false;
  async function scan({ includeUnreadBacklog = false } = {}) {
    if (busy) return 0;
    const items = listItems();
    if (!items.length) return 0;
    const seen = await loadSeen();
    if (!baselined && !seen.size && !includeUnreadBacklog) {
      // First run: everything already in the inbox is history, not new mail.
      for (const li of items) seen.add(li.getAttribute('data-convid'));
      await saveSeen(seen);
      baselined = true;
      return 0;
    }
    baselined = true;
    const known = await send('items.known');
    const done = new Set(known?.convIds || []);
    const todo = items.filter((li) => {
      const id = li.getAttribute('data-convid');
      if (done.has(id)) return false;
      if (!seen.has(id)) return true;
      return includeUnreadBacklog && /unread|non lu/i.test(li.getAttribute('aria-label') || '');
    });
    if (!todo.length) return 0;
    busy = true;
    let n = 0;
    try {
      for (const li of todo) {
        if (!includeUnreadBacklog && settings.autoScanOnlyWhenIdle && !userIsAway()) break;
        const id = li.getAttribute('data-convid');
        const before = readOpenEmail();
        li.click();
        const opened = await waitFor(() => {
          const sel = selectedListItem();
          const e = readOpenEmail();
          return sel && sel.getAttribute('data-convid') === id && e && (!before || e.body !== before.body || e.subject !== before.subject) ? e : null;
        }, 8000);
        seen.add(id);
        if (opened) {
          await sleep(600);
          const email = readOpenEmail() || opened;
          email.convId = email.convId || id;
          lastKey = email.id || `${email.convId}|${email.subject}|${email.body.slice(0, 120)}`;
          await engine({ type: 'email.capture', email });
          n++;
        }
        await sleep(1200);
      }
    } finally {
      busy = false;
      await saveSeen(seen);
    }
    return n;
  }

  // ---------------- inserting drafts ----------------

  const REPLY_LABEL = /^(reply|répondre)$/i;
  const NOT_REPLY = /(all|tous|forward|transférer)/i;

  function findReplyButton() {
    const buttons = qa('button, [role="button"], [role="menuitem"]').filter(visible);
    const named = (b) => [b.getAttribute('aria-label'), b.getAttribute('title'), (b.textContent || '').trim()].filter(Boolean);
    const pane = readingPane();
    const inPane = buttons.filter((b) => pane.contains(b));
    for (const list of [inPane, buttons]) {
      const hit = list.find((b) => named(b).some((n) => REPLY_LABEL.test(n.trim()) && !NOT_REPLY.test(n)));
      if (hit) return hit;
    }
    return null;
  }

  function findComposeEditor() {
    const eds = qa('div[contenteditable="true"]').filter(visible);
    const labelled = eds.filter((e) => /message body|corps du message|body|corps/i.test(e.getAttribute('aria-label') || ''));
    const pool = labelled.length ? labelled : eds.filter((e) => e.getAttribute('role') === 'textbox' || e.offsetHeight > 80);
    if (!pool.length) return null;
    return pool.sort((a, b) => b.offsetHeight * b.offsetWidth - a.offsetHeight * a.offsetWidth)[0];
  }

  function textToHtml(text) {
    const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    return text.split(/\n{2,}/).map((p) => `<div>${esc(p).replace(/\n/g, '<br>')}</div><div><br></div>`).join('');
  }

  async function insertDraft(text, convId) {
    if (!text) return { ok: false, error: 'empty draft' };
    if (convId) {
      const li = qa(`[role="option"][data-convid="${CSS.escape(convId)}"]`)[0];
      if (li && li.getAttribute('aria-selected') !== 'true') {
        li.click();
        await waitFor(() => selectedListItem()?.getAttribute('data-convid') === convId && messageBodies().length, 8000);
      }
    }
    let editor = findComposeEditor();
    if (!editor) {
      const btn = findReplyButton();
      if (!btn) return { ok: false, error: 'Could not find the Reply button — open a reply yourself, then click Insert again.' };
      btn.click();
      editor = await waitFor(findComposeEditor, 10000);
    }
    if (!editor) return { ok: false, error: 'The reply editor did not open.' };
    editor.focus();
    const sel = window.getSelection();
    const range = document.createRange();
    range.setStart(editor, 0);
    range.collapse(true);
    sel.removeAllRanges();
    sel.addRange(range);
    const html = textToHtml(text);
    const before = editor.innerText;
    let ok = document.execCommand('insertHTML', false, html);
    if (!ok || editor.innerText === before) ok = document.execCommand('insertText', false, text);
    if (!ok || editor.innerText === before) {
      const dt = new DataTransfer();
      dt.setData('text/plain', text);
      dt.setData('text/html', html);
      editor.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    }
    const inserted = editor.innerText.includes(text.split('\n').find((l) => l.trim())?.trim().slice(0, 40) || '');
    return inserted ? { ok: true } : { ok: false, error: 'Outlook did not accept the text — use Copy and paste it.' };
  }

  // ---------------- wiring ----------------

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (!msg || !msg.type) return false;
    if (msg.type === 'ping') { sendResponse({ ok: true, url: location.href }); return false; }
    if (msg.type === 'getOpenEmail') {
      captureOpen(false).then((email) => sendResponse(email ? { email } : { error: 'No open message found in the reading pane.' }));
      return true;
    }
    if (msg.type === 'insertDraft') {
      insertDraft(msg.text, msg.convId).then(sendResponse).catch((err) => sendResponse({ ok: false, error: err.message }));
      return true;
    }
    if (msg.type === 'diagnose') {
      // What the extension can see on this Outlook page — for troubleshooting.
      const email = readOpenEmail();
      sendResponse({
        url: location.origin + location.pathname,
        messageList: listItems().length,
        selectedItem: !!selectedListItem(),
        readingPane: readingPane() !== document.body,
        bodies: messageBodies().length,
        subject: email?.subject || '',
        from: email?.from || '',
        date: email?.receivedAt || '',
        bodyChars: email?.body.length || 0,
        replyButton: !!findReplyButton(),
        composeOpen: !!findComposeEditor(),
      });
      return false;
    }
    if (msg.type === 'scanNow') {
      scan({ includeUnreadBacklog: true }).then((n) => sendResponse({ ok: true, processed: n }));
      return true;
    }
    return false;
  });

  const observer = new MutationObserver(() => scheduleCapture());
  observer.observe(document.body, { childList: true, subtree: true, characterData: false });

  refreshSettings().then(() => scan());
  setInterval(async () => {
    await refreshSettings();
    if (settings.autoScan) scan();
  }, 20000);

  window.__mailmirror = { readOpenEmail, insertDraft, scan, findReplyButton, findComposeEditor };
})();
