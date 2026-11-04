// Saved mirrors live in IndexedDB: unlike chrome.storage, it can hold the folder handles the browser gives us.

const DB_NAME = 'nas-uploader';
const STORE = 'mirrors';

function open() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE, { keyPath: 'id' });
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function tx(mode, fn) {
  const db = await open();
  try {
    return await new Promise((resolve, reject) => {
      const t = db.transaction(STORE, mode);
      const result = fn(t.objectStore(STORE));
      t.oncomplete = () => resolve(result?.result);
      t.onerror = () => reject(t.error);
      t.onabort = () => reject(t.error);
    });
  } finally {
    db.close();
  }
}

export const listMirrors = () => tx('readonly', (s) => s.getAll());
export const saveMirror = (m) => tx('readwrite', (s) => s.put(m));
export const deleteMirror = (id) => tx('readwrite', (s) => s.delete(id));
