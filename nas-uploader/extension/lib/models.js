// The model lists shown in the pickers (Settings, the meeting window): the models the user's own key can use,
// text models only, best-first, with a plain-words label for each.

const NOT_TEXT = /embedding|aqa|imagen|veo|image|tts|live|audio|native-audio|robotics|computer-use|learnlm|gemma/i;

function geminiInfo(name) {
  const m = /^gemini-(\d+(?:\.\d+)?)-(pro|flash-lite|flash)(.*)$/.exec(name);
  if (!m) return { version: 0, family: 9, preview: /preview|exp/.test(name), label: name };
  const family = { pro: 0, flash: 1, 'flash-lite': 2 }[m[2]];
  const preview = /preview|exp/.test(m[3]);
  const what = { pro: 'Pro — best quality, costs more', flash: 'Flash — fast, low cost', 'flash-lite': 'Flash-Lite — cheapest' }[m[2]];
  return { version: Number(m[1]), family, preview, label: `${name} — ${what}${preview ? ' (preview: may be withdrawn)' : ''}` };
}

function claudeInfo(name) {
  const fam = /opus/.test(name) ? 0 : /sonnet/.test(name) ? 1 : /haiku/.test(name) ? 2 : /fable/.test(name) ? 0 : 3;
  const what = ['best quality', 'balanced, costs less', 'fastest, cheapest', ''][fam];
  // "claude-opus-4-5-20251101", "claude-3-5-sonnet-20241022", "claude-sonnet-5-5": the version, not the date.
  const nums = name.replace(/-\d{8}$/, '').match(/\d+/g) || [];
  const v = Number(nums.slice(0, 2).join('.')) || 0;
  return { version: v, family: fam, preview: false, label: `${name}${what ? ` — ${what}` : ''}` };
}

/**
 * [{value, label}] for a provider's model picker. `models` is what the key can use (listModels). The first entry
 * for Gemini is "auto" (the newest stable Flash), shown with the model it currently means.
 */
export function modelChoices(provider, models = [], { autoModel = '' } = {}) {
  const info = provider === 'gemini' ? geminiInfo : claudeInfo;
  const list = [...new Set(models)]
    .filter((m) => (provider === 'gemini' ? /^gemini/i.test(m) && !NOT_TEXT.test(m) : /^claude/i.test(m)))
    .map((m) => ({ value: m, ...info(m) }))
    .sort((a, b) => Number(a.preview) - Number(b.preview) || b.version - a.version || a.family - b.family || a.value.localeCompare(b.value));
  const out = list.map(({ value, label }) => ({ value, label }));
  if (provider === 'gemini') out.unshift({ value: 'auto', label: `auto — the newest stable Flash${autoModel ? ` (now ${autoModel})` : ''}` });
  return out;
}

/** Fills a <select> with the choices; a saved value that isn't in the list (typed by hand) is kept and shown. */
export function fillModelSelect(select, choices, current) {
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const opts = [...choices];
  if (current && !opts.some((o) => o.value === current)) opts.unshift({ value: current, label: `${current} (saved; not in your key's list)` });
  select.innerHTML = opts.map((o) => `<option value="${esc(o.value)}">${esc(o.label)}</option>`).join('') + '<option value="__other">Other… (type a model name)</option>';
  select.value = current && opts.some((o) => o.value === current) ? current : opts[0]?.value || '__other';
}
