import { Nas, loadSettings, formatBytes, formatDate } from './api.js';

const view = {
  setup: document.getElementById('setup'),
  browser: document.getElementById('browser'),
  breadcrumb: document.getElementById('breadcrumb'),
  listing: document.getElementById('listing'),
  empty: document.getElementById('empty'),
  message: document.getElementById('message'),
  usage: document.getElementById('usage'),
  transfers: document.getElementById('transfers'),
  dropOverlay: document.getElementById('drop-overlay'),
  fileInput: document.getElementById('file-input'),
};

let nas = null;
let currentPath = '';
const LAST_PATH_KEY = 'pinas.lastPath';

// --------------------------------------------------------------- messaging
let messageTimer = null;
function showMessage(text, kind = 'error') {
  clearTimeout(messageTimer);
  view.message.textContent = text;
  view.message.classList.remove('hidden');
  view.message.classList.toggle('info', kind === 'info');
  if (kind === 'info') messageTimer = setTimeout(hideMessage, 2500);
}
function hideMessage() {
  view.message.classList.add('hidden');
}

// ----------------------------------------------------------------- render
function renderBreadcrumb(path) {
  view.breadcrumb.replaceChildren();
  const segments = path ? path.split('/') : [];

  const addCrumb = (label, target) => {
    const button = document.createElement('button');
    button.textContent = label;
    button.addEventListener('click', () => navigate(target));
    view.breadcrumb.append(button);
  };

  addCrumb('NAS', '');
  segments.forEach((segment, index) => {
    const separator = document.createElement('span');
    separator.className = 'sep';
    separator.textContent = '/';
    view.breadcrumb.append(separator);
    addCrumb(segment, segments.slice(0, index + 1).join('/'));
  });
}

function makeRow(entry) {
  const row = document.createElement('li');
  row.className = `row ${entry.is_dir ? 'folder' : 'file'}`;

  const glyph = document.createElement('span');
  glyph.className = 'glyph';
  glyph.textContent = entry.is_dir ? '📁' : '📄';

  const name = document.createElement('button');
  name.className = 'name';
  name.textContent = entry.name;
  name.title = entry.name;
  if (entry.is_dir) {
    name.addEventListener('click', () => navigate(entry.path));
  } else {
    name.disabled = true;
  }

  const meta = document.createElement('span');
  meta.className = 'meta';
  meta.textContent = entry.is_dir ? formatDate(entry.modified)
    : `${formatBytes(entry.size)} · ${formatDate(entry.modified)}`;

  const actions = document.createElement('span');
  actions.className = 'actions';

  if (!entry.is_dir) {
    actions.append(actionButton('⬇', 'Download', async () => {
      await nas.download(entry.path, entry.name);
      showMessage(`Downloading ${entry.name}`, 'info');
    }));
  }
  actions.append(actionButton('✎', 'Rename', () => renameEntry(entry)));
  actions.append(actionButton('🗑', 'Delete', () => deleteEntry(entry), 'delete'));

  row.append(glyph, name, meta, actions);
  return row;
}

function actionButton(label, title, handler, extraClass = '') {
  const button = document.createElement('button');
  button.textContent = label;
  button.title = title;
  button.setAttribute('aria-label', title);
  if (extraClass) button.className = extraClass;
  button.addEventListener('click', async (event) => {
    event.stopPropagation();
    try {
      await handler();
    } catch (error) {
      showMessage(error.message);
    }
  });
  return button;
}

// -------------------------------------------------------------- navigation
async function navigate(path) {
  try {
    const data = await nas.list(path);
    currentPath = data.path;
    chrome.storage.local.set({ [LAST_PATH_KEY]: currentPath });
    hideMessage();
    renderBreadcrumb(currentPath);
    view.listing.replaceChildren(...data.entries.map(makeRow));
    view.empty.classList.toggle('hidden', data.entries.length > 0);
  } catch (error) {
    // A saved path can disappear between sessions; fall back to the root
    // rather than leaving the popup stuck on an error.
    if (error.status === 404 && path) return navigate('');
    showMessage(error.message);
  }
}

async function refreshUsage() {
  try {
    const { total, free } = await nas.usage();
    view.usage.textContent = `${formatBytes(free)} free of ${formatBytes(total)}`;
  } catch {
    view.usage.textContent = '';
  }
}

// ----------------------------------------------------------------- actions
async function renameEntry(entry) {
  const next = prompt(`Rename "${entry.name}" to:`, entry.name);
  if (!next || next === entry.name) return;
  if (next.includes('/') || next.includes('\\')) {
    showMessage('A name cannot contain a slash.');
    return;
  }
  const destination = currentPath ? `${currentPath}/${next}` : next;
  await nas.move(entry.path, destination);
  await navigate(currentPath);
}

async function deleteEntry(entry) {
  const warning = entry.is_dir
    ? `Delete the folder "${entry.name}" and everything inside it?`
    : `Delete "${entry.name}"?`;
  if (!confirm(warning)) return;
  await nas.remove(entry.path, entry.is_dir);
  await navigate(currentPath);
  refreshUsage();
}

async function createFolder() {
  const name = prompt('New folder name:');
  if (!name) return;
  if (name.includes('/') || name.includes('\\')) {
    showMessage('A name cannot contain a slash.');
    return;
  }
  try {
    await nas.mkdir(currentPath ? `${currentPath}/${name}` : name);
    await navigate(currentPath);
  } catch (error) {
    showMessage(error.message);
  }
}

// ----------------------------------------------------------------- uploads
async function uploadFiles(files) {
  if (!files.length) return;
  view.transfers.classList.remove('hidden');

  for (const file of files) {
    const item = document.createElement('div');
    item.className = 'transfer';
    const label = document.createElement('span');
    label.textContent = `${file.name} — 0%`;
    const bar = document.createElement('div');
    bar.className = 'bar';
    const fill = document.createElement('div');
    bar.append(fill);
    item.append(label, bar);
    view.transfers.append(item);

    try {
      await nas.upload(file, currentPath, {
        onProgress: (ratio) => {
          const percent = Math.round(ratio * 100);
          label.textContent = `${file.name} — ${percent}%`;
          fill.style.width = `${percent}%`;
        },
      });
      label.textContent = `${file.name} — done`;
      fill.style.width = '100%';
      setTimeout(() => item.remove(), 1500);
    } catch (error) {
      label.textContent = `${file.name} — ${error.message}`;
      showMessage(error.message);
    }
  }

  setTimeout(() => {
    if (!view.transfers.children.length) view.transfers.classList.add('hidden');
  }, 1600);
  await navigate(currentPath);
  refreshUsage();
}

// Collect files from a drop, walking into any dropped folders so their
// structure is preserved rather than silently dropping the contents.
async function filesFromDataTransfer(dataTransfer) {
  const entries = [...dataTransfer.items]
    .map((item) => (item.webkitGetAsEntry ? item.webkitGetAsEntry() : null))
    .filter(Boolean);

  if (!entries.length) return [...dataTransfer.files].map((file) => ({ file, prefix: '' }));

  const collected = [];
  const walk = (entry, prefix) => new Promise((resolve) => {
    if (entry.isFile) {
      entry.file((file) => {
        collected.push({ file, prefix });
        resolve();
      }, resolve);
    } else if (entry.isDirectory) {
      const reader = entry.createReader();
      const readBatch = () => reader.readEntries(async (batch) => {
        if (!batch.length) return resolve();
        await Promise.all(batch.map((child) =>
          walk(child, prefix ? `${prefix}/${entry.name}` : entry.name)));
        readBatch();
      }, resolve);
      readBatch();
    } else {
      resolve();
    }
  });

  await Promise.all(entries.map((entry) => walk(entry, '')));
  return collected;
}

async function uploadDropped(dataTransfer) {
  const items = await filesFromDataTransfer(dataTransfer);
  if (!items.length) return;
  view.transfers.classList.remove('hidden');

  for (const { file, prefix } of items) {
    const directory = [currentPath, prefix].filter(Boolean).join('/');
    const item = document.createElement('div');
    item.className = 'transfer';
    const label = document.createElement('span');
    const display = prefix ? `${prefix}/${file.name}` : file.name;
    label.textContent = `${display} — 0%`;
    const bar = document.createElement('div');
    bar.className = 'bar';
    const fill = document.createElement('div');
    bar.append(fill);
    item.append(label, bar);
    view.transfers.append(item);

    try {
      await nas.upload(file, directory, {
        onProgress: (ratio) => {
          const percent = Math.round(ratio * 100);
          label.textContent = `${display} — ${percent}%`;
          fill.style.width = `${percent}%`;
        },
      });
      label.textContent = `${display} — done`;
      setTimeout(() => item.remove(), 1500);
    } catch (error) {
      label.textContent = `${display} — ${error.message}`;
    }
  }

  await navigate(currentPath);
  refreshUsage();
}

// -------------------------------------------------------------------- wiring
document.getElementById('open-options').addEventListener('click', () => {
  chrome.runtime.openOptionsPage();
});
document.getElementById('refresh').addEventListener('click', () => {
  navigate(currentPath);
  refreshUsage();
});
document.getElementById('new-folder').addEventListener('click', createFolder);
document.getElementById('upload-button').addEventListener('click', () => view.fileInput.click());
view.fileInput.addEventListener('change', () => {
  uploadFiles([...view.fileInput.files]);
  view.fileInput.value = '';
});

let dragDepth = 0;
document.addEventListener('dragenter', (event) => {
  event.preventDefault();
  dragDepth += 1;
  view.dropOverlay.classList.remove('hidden');
});
document.addEventListener('dragover', (event) => event.preventDefault());
document.addEventListener('dragleave', () => {
  dragDepth = Math.max(0, dragDepth - 1);
  if (!dragDepth) view.dropOverlay.classList.add('hidden');
});
document.addEventListener('drop', (event) => {
  event.preventDefault();
  dragDepth = 0;
  view.dropOverlay.classList.add('hidden');
  uploadDropped(event.dataTransfer);
});

(async function start() {
  const settings = await loadSettings();
  nas = new Nas(settings);
  if (!nas.configured) {
    view.setup.classList.remove('hidden');
    return;
  }
  view.browser.classList.remove('hidden');
  const stored = await chrome.storage.local.get(LAST_PATH_KEY);
  await navigate(stored[LAST_PATH_KEY] || '');
  refreshUsage();
})();
