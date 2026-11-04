// Provider adapters: Anthropic (Claude) and Google Gemini, called directly
// from the extension with the user's own API key. Both return structured
// JSON constrained by the same schema.

export class LLMError extends Error {
  constructor(kind, message, status) {
    super(message);
    this.kind = kind;       // auth | rate | declined | truncated | network | bad-request | server | parse | config
    this.status = status;
  }
}

// USD per 1M tokens: [input, output, cacheRead]. Longest matching prefix wins.
const PRICES = {
  'claude-fable-5-1': [10, 50, 1],
  'claude-opus-5-5': [4, 20, 0.2],
  'claude-opus-5': [5, 25, 0.5],
  'claude-opus-4': [5, 25, 0.5],
  'claude-sonnet-5-5': [2, 10, 0.2],
  'claude-sonnet-5': [2, 10, 0.2],
  'claude-sonnet-4': [3, 15, 0.3],
  'claude-haiku-5-5': [0.1, 0.5, 0.01],
  'claude-haiku-4': [1, 5, 0.1],
  'gemini-2.5-pro': [1.25, 10, 0.31],
  'gemini-2.5-flash-lite': [0.1, 0.4, 0.025],
  'gemini-2.5-flash': [0.3, 2.5, 0.075],
  'gemini-3-pro': [2, 12, 0.2],
  'gemini-3-flash': [0.5, 3, 0.05],
};

export function priceFor(model, settings = {}) {
  if (settings.priceInPerM != null && settings.priceOutPerM != null && settings.priceInPerM !== '' && settings.priceOutPerM !== '') {
    const i = Number(settings.priceInPerM);
    return [i, Number(settings.priceOutPerM), i / 10];
  }
  const key = Object.keys(PRICES).filter((k) => model.startsWith(k)).sort((a, b) => b.length - a.length)[0];
  return key ? PRICES[key] : null;
}

export function costOf(usage, model, settings) {
  const p = priceFor(model, settings);
  if (!p) return null;
  const [pin, pout, pread] = p;
  const cost = ((usage.input || 0) * pin + (usage.cacheWrite || 0) * pin * 1.25
    + (usage.cacheRead || 0) * pread + (usage.output || 0) * pout) / 1e6;
  return Math.round(cost * 1e5) / 1e5;
}

export function activeModel(settings) {
  return settings.provider === 'gemini' ? settings.geminiModel : settings.anthropicModel;
}

export function hasKey(settings) {
  return settings.provider === 'gemini' ? !!settings.geminiKey : !!settings.anthropicKey;
}

function parseJson(text) {
  let t = String(text || '').trim();
  t = t.replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  try {
    return JSON.parse(t);
  } catch {
    const a = t.indexOf('{');
    const b = t.lastIndexOf('}');
    if (a >= 0 && b > a) {
      try { return JSON.parse(t.slice(a, b + 1)); } catch { /* fall through */ }
    }
    throw new LLMError('parse', 'Model returned text that is not valid JSON');
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function httpJson(url, init, { retries = 2 } = {}) {
  for (let attempt = 0; ; attempt++) {
    let res;
    try {
      res = await fetch(url, init);
    } catch (err) {
      if (attempt < retries) { await sleep(1500 * (attempt + 1)); continue; }
      throw new LLMError('network', `Network error: ${err.message}`);
    }
    let body = null;
    const raw = await res.text();
    try { body = raw ? JSON.parse(raw) : null; } catch { body = { raw }; }
    if (res.ok) return body;
    const msg = body?.error?.message || body?.message || raw.slice(0, 300) || res.statusText;
    if ((res.status === 429 || res.status >= 500) && attempt < retries) {
      const ra = Number(res.headers.get('retry-after'));
      await sleep(Number.isFinite(ra) && ra > 0 ? Math.min(ra, 30) * 1000 : 2000 * (attempt + 1));
      continue;
    }
    if (res.status === 401 || res.status === 403) throw new LLMError('auth', `API key rejected (${res.status}): ${msg}`, res.status);
    if (res.status === 429) throw new LLMError('rate', `Rate limited: ${msg}`, res.status);
    if (res.status >= 500) throw new LLMError('server', `Provider error ${res.status}: ${msg}`, res.status);
    throw new LLMError('bad-request', `Request rejected (${res.status}): ${msg}`, res.status);
  }
}

// ---------------- Anthropic ----------------

const FALLBACK_MODELS = /^claude-(opus-5-5|opus-5|fable-5-1|sonnet-5-5)$/;

async function callAnthropic(settings, { system, parts, schema, effort, maxTokens, cacheParts = [] }) {
  const model = settings.anthropicModel;
  const base = (settings.anthropicBaseUrl || 'https://api.anthropic.com').replace(/\/+$/, '');
  const opts = {
    fallbacks: settings.anthropicFallbacks !== false && FALLBACK_MODELS.test(model),
    effort: effort || settings.effort,
    schema: true,
  };
  let max = maxTokens || 8000;
  for (let attempt = 0; attempt < 5; attempt++) {
    const headers = {
      'content-type': 'application/json',
      'x-api-key': settings.anthropicKey,
      'anthropic-version': '2023-06-01',
      'anthropic-dangerous-direct-browser-access': 'true',
    };
    if (opts.fallbacks) headers['anthropic-beta'] = 'server-side-fallback-2026-07-01';
    const outputConfig = {};
    if (opts.effort) outputConfig.effort = opts.effort;
    if (opts.schema) outputConfig.format = { type: 'json_schema', schema };
    const body = {
      model,
      max_tokens: max,
      system: [{ type: 'text', text: system, cache_control: { type: 'ephemeral' } }],
      messages: [{
        role: 'user',
        content: parts.map((text, i) => (cacheParts.includes(i)
          ? { type: 'text', text, cache_control: { type: 'ephemeral' } }
          : { type: 'text', text })),
      }],
    };
    if (Object.keys(outputConfig).length) body.output_config = outputConfig;
    if (opts.fallbacks) body.fallbacks = 'default';
    let data;
    try {
      data = await httpJson(`${base}/v1/messages`, { method: 'POST', headers, body: JSON.stringify(body) });
    } catch (err) {
      // Degrade gracefully for models/accounts that reject an optional feature.
      if (err.kind === 'bad-request') {
        const m = err.message.toLowerCase();
        if (opts.fallbacks && /fallback|beta/.test(m)) { opts.fallbacks = false; continue; }
        if (opts.effort && /effort/.test(m)) { opts.effort = null; continue; }
        if (opts.schema && /output_config|format|schema/.test(m)) { opts.schema = false; continue; }
      }
      throw err;
    }
    const usage = {
      input: data.usage?.input_tokens || 0,
      output: data.usage?.output_tokens || 0,
      cacheRead: data.usage?.cache_read_input_tokens || 0,
      cacheWrite: data.usage?.cache_creation_input_tokens || 0,
    };
    if (data.stop_reason === 'refusal') {
      const e = new LLMError('declined', `The model declined this request${data.stop_details?.category ? ` (${data.stop_details.category})` : ''}.`);
      e.usage = usage;
      throw e;
    }
    if (data.stop_reason === 'max_tokens') {
      if (max < 32000) { max *= 2; continue; }
      throw new LLMError('truncated', 'Response hit the output limit');
    }
    const text = (data.content || []).filter((b) => b.type === 'text').map((b) => b.text).join('');
    return { data: parseJson(text), usage, model: data.model || model, provider: 'anthropic' };
  }
  throw new LLMError('bad-request', 'Anthropic request failed after retries');
}

// ---------------- Gemini ----------------

function toGeminiSchema(s) {
  if (!s || typeof s !== 'object') return s;
  const out = {};
  if (s.type) out.type = String(s.type).toUpperCase();
  if (s.description) out.description = s.description;
  if (s.enum) out.enum = s.enum;
  if (s.properties) {
    out.properties = {};
    for (const [k, v] of Object.entries(s.properties)) out.properties[k] = toGeminiSchema(v);
    out.propertyOrdering = Object.keys(s.properties);
  }
  if (s.required) out.required = s.required;
  if (s.items) out.items = toGeminiSchema(s.items);
  return out;
}

function geminiThinking(model, effort) {
  if (/gemini-2\.5/.test(model)) return { thinkingBudget: effort === 'high' ? -1 : effort === 'medium' ? 2048 : 256 };
  if (/gemini-3/.test(model)) return { thinkingLevel: effort === 'low' ? 'low' : 'high' };
  return null;
}

async function callGemini(settings, { system, parts, schema, effort, maxTokens }) {
  const model = String(settings.geminiModel || '').replace(/^models\//, '');
  const base = (settings.geminiBaseUrl || 'https://generativelanguage.googleapis.com').replace(/\/+$/, '');
  const opts = { thinking: geminiThinking(model, effort || settings.effort), schema: true };
  let max = maxTokens || 8192;
  for (let attempt = 0; attempt < 5; attempt++) {
    const generationConfig = { responseMimeType: 'application/json', maxOutputTokens: max };
    if (opts.schema) generationConfig.responseSchema = toGeminiSchema(schema);
    if (opts.thinking) generationConfig.thinkingConfig = opts.thinking;
    const body = {
      systemInstruction: { parts: [{ text: system }] },
      contents: [{ role: 'user', parts: parts.map((text) => ({ text })) }],
      generationConfig,
    };
    let data;
    try {
      data = await httpJson(`${base}/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-goog-api-key': settings.geminiKey },
        body: JSON.stringify(body),
      });
    } catch (err) {
      if (err.kind === 'bad-request') {
        const m = err.message.toLowerCase();
        if (opts.thinking && /thinking/.test(m)) { opts.thinking = null; continue; }
        if (opts.schema && /schema/.test(m)) { opts.schema = false; continue; }
      }
      if (err.kind === 'bad-request' && /api key not valid|api_key_invalid/i.test(err.message)) {
        throw new LLMError('auth', err.message, err.status);
      }
      throw err;
    }
    const um = data.usageMetadata || {};
    const usage = {
      input: Math.max(0, (um.promptTokenCount || 0) - (um.cachedContentTokenCount || 0)),
      output: (um.candidatesTokenCount || 0) + (um.thoughtsTokenCount || 0),
      cacheRead: um.cachedContentTokenCount || 0,
      cacheWrite: 0,
    };
    if (data.promptFeedback?.blockReason) {
      const e = new LLMError('declined', `Gemini blocked the request (${data.promptFeedback.blockReason}).`);
      e.usage = usage;
      throw e;
    }
    const cand = data.candidates?.[0];
    if (!cand) throw new LLMError('server', 'Gemini returned no candidates');
    if (cand.finishReason === 'MAX_TOKENS') {
      if (max < 32768) { max *= 2; continue; }
      throw new LLMError('truncated', 'Response hit the output limit');
    }
    if (['SAFETY', 'RECITATION', 'PROHIBITED_CONTENT', 'BLOCKLIST', 'SPII'].includes(cand.finishReason)) {
      const e = new LLMError('declined', `Gemini stopped the response (${cand.finishReason}).`);
      e.usage = usage;
      throw e;
    }
    const text = (cand.content?.parts || []).filter((p) => !p.thought && typeof p.text === 'string').map((p) => p.text).join('');
    return { data: parseJson(text), usage, model: data.modelVersion || model, provider: 'gemini' };
  }
  throw new LLMError('bad-request', 'Gemini request failed after retries');
}

export async function callLLM(settings, request) {
  if (!hasKey(settings)) throw new LLMError('config', `No ${settings.provider === 'gemini' ? 'Gemini' : 'Anthropic'} API key set`);
  return settings.provider === 'gemini' ? callGemini(settings, request) : callAnthropic(settings, request);
}

// Lists models the key can use — doubles as a key check.
export async function listModels(settings, provider = settings.provider) {
  if (provider === 'gemini') {
    if (!settings.geminiKey) throw new LLMError('config', 'Enter a Gemini API key first');
    const base = (settings.geminiBaseUrl || 'https://generativelanguage.googleapis.com').replace(/\/+$/, '');
    const data = await httpJson(`${base}/v1beta/models?pageSize=1000`, {
      headers: { 'x-goog-api-key': settings.geminiKey },
    }, { retries: 0 }).catch((err) => {
      if (/api key not valid|api_key_invalid/i.test(err.message)) throw new LLMError('auth', err.message);
      throw err;
    });
    return (data.models || [])
      .filter((m) => (m.supportedGenerationMethods || []).includes('generateContent'))
      .map((m) => m.name.replace(/^models\//, ''))
      .filter((n) => /gemini/i.test(n));
  }
  if (!settings.anthropicKey) throw new LLMError('config', 'Enter an Anthropic API key first');
  const base = (settings.anthropicBaseUrl || 'https://api.anthropic.com').replace(/\/+$/, '');
  const data = await httpJson(`${base}/v1/models?limit=100`, {
    headers: {
      'x-api-key': settings.anthropicKey,
      'anthropic-version': '2023-06-01',
      'anthropic-dangerous-direct-browser-access': 'true',
    },
  }, { retries: 0 });
  return (data.data || []).map((m) => m.id);
}
