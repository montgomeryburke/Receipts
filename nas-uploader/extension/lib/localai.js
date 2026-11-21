// Chrome's built-in AI (Gemini Nano, runs on this computer, free). Used only for small yes/no judgements —
// "is this worth a paid prompt?" — so the paid API is called less. If the computer or Chrome version doesn't
// have it (or the model isn't downloaded), every call returns null and the caller falls back to simple rules.
// It never starts the ~2 GB model download on its own.

let session = null;
let state = 'unknown'; // unknown | available | unavailable

async function getSession() {
  if (state === 'unavailable') return null;
  if (session) return session;
  try {
    const LM = globalThis.LanguageModel;
    if (!LM?.availability || !LM?.create) {
      state = 'unavailable';
      return null;
    }
    const a = await LM.availability();
    if (a !== 'available') {
      state = 'unavailable';
      return null;
    }
    session = await LM.create({
      initialPrompts: [{ role: 'system', content: 'You answer with exactly one word: yes or no.' }],
    });
    state = 'available';
    return session;
  } catch {
    state = 'unavailable';
    return null;
  }
}

export const localAI = {
  /** true / false, or null when there is no local model (or it gave no clear answer). */
  async yesNo(question, { timeoutMs = 4000 } = {}) {
    const s = await getSession();
    if (!s) return null;
    try {
      const s2 = s.clone ? await s.clone() : s; // keep each judgement independent
      const answer = await Promise.race([s2.prompt(question), new Promise((r) => setTimeout(() => r(''), timeoutMs))]);
      s2.destroy?.();
      const a = String(answer || '').trim().toLowerCase();
      if (a.startsWith('yes')) return true;
      if (a.startsWith('no')) return false;
      return null;
    } catch {
      return null;
    }
  },
  get available() {
    return state === 'available';
  },
  async check() {
    await getSession();
    return state;
  },
};
