// Provider adapters: Anthropic (Claude, through the official SDK) and Google Gemini (REST), called directly
// from the extension with the user's own API key.
//  - callLLM: one structured call (JSON constrained by a schema) — email drafts, meeting prompts.
//  - runChat: a tool-use loop — the assistant chat, which changes the extension's own settings.
//  - generateText: a plain call with an optional web lookup — meeting standards look-ups.

import { Anthropic } from '../vendor/anthropic-sdk.mjs';
import { getSettings, saveSettings, kvGet, kvSet } from './db.js';

export class LLMError extends Error {
  constructor(kind, message, status) {
    super(message);
    // auth | rate | declined | truncated | network | bad-request | server | parse | config | stopped | paused | budget
    this.kind = kind;
    this.status = status;
  }
}

// ---------------- kill switch and spending limit ----------------
// Every paid call (Claude or Gemini) goes through aiGate() and track(): "Stop AI" aborts the calls in flight in
// every open part of the extension and refuses new ones until "Resume AI"; a daily limit does the same once
// today's estimated spend reaches it.

const inFlight = new Set();

/** An abort signal for one call, cancelled by its own signal or by Stop AI. */
function track(signal) {
  const c = new AbortController();
  inFlight.add(c);
  const onAbort = () => c.abort();
  if (signal) {
    if (signal.aborted) c.abort();
    else signal.addEventListener('abort', onAbort, { once: true });
  }
  return {
    signal: c.signal,
    done: () => {
      inFlight.delete(c);
      signal?.removeEventListener('abort', onAbort);
    },
  };
}

/** Cancels every AI call in progress in this page. */
export function abortAllAI() {
  for (const c of inFlight) c.abort();
  inFlight.clear();
}

try {
  chrome.runtime.onMessage.addListener((m) => {
    if (m?.type === 'ai.stopAll') abortAllAI();
    return false;
  });
} catch {
  /* not in an extension page */
}

/** Stop AI everywhere: saves the switch, cancels the calls here and tells the other pages to cancel theirs. */
export async function stopAllAI() {
  await saveSettings({ aiPaused: true });
  abortAllAI();
  try {
    await chrome.runtime.sendMessage({ to: 'all', type: 'ai.stopAll' });
  } catch {
    /* no other page open */
  }
}

export async function resumeAI() {
  await saveSettings({ aiPaused: false });
  try {
    await chrome.runtime.sendMessage({ to: 'all', type: 'ai.resumed' });
  } catch {
    /* no other page open */
  }
}

function today() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export async function spentToday() {
  return (await kvGet(`spend:${today()}`)) || 0;
}

async function recordSpend(usage, model, settings) {
  const c = costOf(usage, model, settings);
  if (!c) return;
  try {
    await kvSet(`spend:${today()}`, Math.round(((await spentToday()) + c) * 1e5) / 1e5);
  } catch {
    /* the estimate is best effort */
  }
}

/** Throws if AI is stopped or today's limit is reached. Reads the switch fresh, so it applies at once. */
export async function aiGate() {
  const s = await getSettings();
  if (s.aiPaused) throw new LLMError('paused', 'AI is stopped (kill switch). Click "Resume AI" to use it again.');
  const limit = Number(s.dailyBudgetUsd) || 0;
  if (limit > 0) {
    const spent = await spentToday();
    if (spent >= limit) {
      throw new LLMError('budget', `Today's AI spending limit ($${limit.toFixed(2)}) is reached (about $${spent.toFixed(2)} spent). Raise it in Settings → Accuracy & safety, or wait until tomorrow.`);
    }
  }
  return s;
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
  const key = Object.keys(PRICES)
    .filter((k) => String(model || '').startsWith(k))
    .sort((a, b) => b.length - a.length)[0];
  return key ? PRICES[key] : null;
}

export function costOf(usage, model, settings) {
  const p = priceFor(model, settings);
  if (!p) return null;
  const [pin, pout, pread] = p;
  const cost = ((usage.input || 0) * pin + (usage.cacheWrite || 0) * pin * 1.25 + (usage.cacheRead || 0) * pread + (usage.output || 0) * pout) / 1e6;
  return Math.round(cost * 1e5) / 1e5;
}

export function activeModel(settings, provider = settings.provider) {
  return provider === 'gemini' ? settings.geminiModel : settings.anthropicModel;
}

export function hasKey(settings, provider = settings.provider) {
  return provider === 'gemini' ? !!settings.geminiKey : !!settings.anthropicKey;
}

/** The provider for a job, falling back to whichever key exists. */
export function pickProvider(settings, preferred) {
  const want = preferred || settings.provider;
  if (hasKey(settings, want)) return want;
  const other = want === 'gemini' ? 'anthropic' : 'gemini';
  return hasKey(settings, other) ? other : want;
}

export function parseJson(text) {
  let t = String(text || '').trim();
  t = t.replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  try {
    return JSON.parse(t);
  } catch {
    const a = t.indexOf('{');
    const b = t.lastIndexOf('}');
    if (a >= 0 && b > a) {
      try {
        return JSON.parse(t.slice(a, b + 1));
      } catch {
        /* fall through */
      }
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
      if (init?.signal?.aborted) throw new LLMError('stopped', 'Stopped.');
      if (attempt < retries) {
        await sleep(1500 * (attempt + 1));
        continue;
      }
      throw new LLMError('network', `Network error: ${err.message}`);
    }
    let body = null;
    const raw = await res.text();
    try {
      body = raw ? JSON.parse(raw) : null;
    } catch {
      body = { raw };
    }
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
    if (/api key not valid|api_key_invalid/i.test(msg)) throw new LLMError('auth', msg, res.status);
    throw new LLMError('bad-request', `Request rejected (${res.status}): ${msg}`, res.status);
  }
}

// ---------------- Anthropic (official SDK) ----------------

const FALLBACK_MODELS = /^claude-(opus-5-5|opus-5|fable-5-1|sonnet-5-5)$/;
const FALLBACK_BETA = 'server-side-fallback-2026-07-01';

function anthropicClient(settings) {
  return new Anthropic({
    apiKey: settings.anthropicKey,
    baseURL: (settings.anthropicBaseUrl || 'https://api.anthropic.com').replace(/\/+$/, ''),
    dangerouslyAllowBrowser: true, // the key is the user's own, kept in this browser profile
    maxRetries: 2,
    timeout: 600000, // explicit, so the SDK does not insist on streaming for large max_tokens
  });
}

function anthropicError(err) {
  if (err instanceof LLMError) return err;
  if (err instanceof Anthropic.APIUserAbortError || err?.name === 'AbortError') return new LLMError('stopped', 'Stopped.');
  const status = err?.status;
  const msg = err?.error?.error?.message || err?.message || String(err);
  if (err instanceof Anthropic.AuthenticationError || err instanceof Anthropic.PermissionDeniedError) {
    return new LLMError('auth', `API key rejected (${status}): ${msg}`, status);
  }
  if (err instanceof Anthropic.RateLimitError) return new LLMError('rate', `Rate limited: ${msg}`, status);
  if (err instanceof Anthropic.InternalServerError) return new LLMError('server', `Provider error ${status}: ${msg}`, status);
  if (err instanceof Anthropic.APIConnectionError) return new LLMError('network', `Network error: ${msg}`);
  if (err instanceof Anthropic.APIError) return new LLMError('bad-request', `Request rejected (${status}): ${msg}`, status);
  return new LLMError('network', msg);
}

function anthropicUsage(u) {
  return {
    input: u?.input_tokens || 0,
    output: u?.output_tokens || 0,
    cacheRead: u?.cache_read_input_tokens || 0,
    cacheWrite: u?.cache_creation_input_tokens || 0,
  };
}

function addUsage(total, u) {
  for (const k of ['input', 'output', 'cacheRead', 'cacheWrite']) total[k] = (total[k] || 0) + (u[k] || 0);
  return total;
}

function declined(data, usage) {
  const e = new LLMError('declined', `The model declined this request${data.stop_details?.category ? ` (${data.stop_details.category})` : ''}.`);
  e.usage = usage;
  return e;
}

/**
 * One Messages API request with graceful degradation: if the account or model rejects an optional
 * feature (server-side fallback, effort, structured output), retry without it.
 * opts: {fallbacks, effort, schema} — mutated as features are dropped.
 */
async function anthropicCreate(client, settings, params, opts, outerSignal) {
  await aiGate();
  const call = track(outerSignal);
  try {
    const data = await anthropicCreateOnce(client, settings, params, opts, call.signal);
    recordSpend(anthropicUsage(data.usage), data.model || params.model, settings);
    return data;
  } finally {
    call.done();
  }
}

async function anthropicCreateOnce(client, settings, params, opts, signal) {
  for (let attempt = 0; attempt < 4; attempt++) {
    const body = { ...params };
    const outputConfig = { ...(params.output_config || {}) };
    if (opts.effort) outputConfig.effort = opts.effort;
    if (opts.schema) outputConfig.format = { type: 'json_schema', schema: opts.schema };
    if (Object.keys(outputConfig).length) body.output_config = outputConfig;
    else delete body.output_config;
    try {
      if (opts.fallbacks) {
        return await client.beta.messages.create({ ...body, fallbacks: 'default', betas: [FALLBACK_BETA] }, { signal });
      }
      return await client.messages.create(body, { signal });
    } catch (e) {
      const err = anthropicError(e);
      if (err.kind === 'bad-request') {
        const m = err.message.toLowerCase();
        if (opts.fallbacks && /fallback|beta/.test(m)) {
          opts.fallbacks = false;
          continue;
        }
        if (opts.effort && /effort/.test(m)) {
          opts.effort = null;
          continue;
        }
        if (opts.schema && /output_config|format|schema/.test(m)) {
          opts.schema = null;
          continue;
        }
      }
      throw err;
    }
  }
  throw new LLMError('bad-request', 'Anthropic request failed after retries');
}

function anthropicOpts(settings, model, effort, schema) {
  return {
    fallbacks: settings.anthropicFallbacks !== false && FALLBACK_MODELS.test(model),
    effort: effort || settings.effort || null,
    schema: schema || null,
  };
}

async function callAnthropic(settings, { system, parts, schema, effort, maxTokens, cacheParts = [], model: modelOverride, signal }) {
  const model = modelOverride || settings.anthropicModel;
  const client = anthropicClient(settings);
  const opts = anthropicOpts(settings, model, effort, schema);
  let max = maxTokens || 8000;
  const usage = {};
  for (let attempt = 0; attempt < 3; attempt++) {
    const data = await anthropicCreate(
      client,
      settings,
      {
        model,
        max_tokens: max,
        system: [{ type: 'text', text: system, cache_control: { type: 'ephemeral' } }],
        messages: [
          {
            role: 'user',
            content: parts.map((text, i) => (cacheParts.includes(i) ? { type: 'text', text, cache_control: { type: 'ephemeral' } } : { type: 'text', text })),
          },
        ],
      },
      opts,
      signal,
    );
    addUsage(usage, anthropicUsage(data.usage));
    if (data.stop_reason === 'refusal') throw declined(data, usage);
    if (data.stop_reason === 'max_tokens') {
      if (max < 32000) {
        max *= 2;
        continue;
      }
      throw new LLMError('truncated', 'Response hit the output limit');
    }
    const text = (data.content || []).filter((b) => b.type === 'text').map((b) => b.text).join('');
    return { data: parseJson(text), usage, model: data.model || model, provider: 'anthropic' };
  }
  throw new LLMError('truncated', 'Response hit the output limit');
}

// ---------------- Gemini (REST) ----------------

function geminiBase(settings) {
  return (settings.geminiBaseUrl || 'https://generativelanguage.googleapis.com').replace(/\/+$/, '');
}

function toGeminiSchema(s) {
  if (!s || typeof s !== 'object') return s;
  const out = {};
  if (Array.isArray(s.type)) {
    // Gemini takes one type per field (+ nullable), not a list.
    out.type = String(s.type.find((t) => t !== 'null') || 'string').toUpperCase();
    if (s.type.includes('null')) out.nullable = true;
  } else if (s.type) out.type = String(s.type).toUpperCase();
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
  if (/gemini-[3-9]/.test(model)) return { thinkingLevel: effort === 'low' ? 'low' : 'high' };
  return null;
}

let geminiModelCache = null; // {key, model}

/** 'auto' → the newest general-purpose Gemini Flash model this key can use (looked up once). */
export async function resolveGeminiModel(settings) {
  const m = String(settings.geminiModel || '').replace(/^models\//, '');
  if (m && m !== 'auto') return m;
  if (geminiModelCache?.key === settings.geminiKey) return geminiModelCache.model;
  let models = [];
  try {
    models = await listModels(settings, 'gemini');
  } catch {
    models = [];
  }
  const model = pickGeminiFlash(models) || 'gemini-2.5-flash';
  geminiModelCache = { key: settings.geminiKey, model };
  return model;
}

/**
 * Newest stable "gemini-X.Y-flash" (previews only if there is no stable one — they get withdrawn without
 * notice); never the lite/image/tts/live/audio variants.
 */
export function pickGeminiFlash(models) {
  const scored = [];
  for (const name of models) {
    const m = /^gemini-(\d+(?:\.\d+)?)-flash(-preview(?:-[\w-]+)?|-\d{3}|-latest)?$/.exec(name);
    if (!m) continue;
    const stable = !m[2] || /^-\d{3}$/.test(m[2]);
    scored.push([stable ? 1 : 0, Number(m[1]), name]);
  }
  scored.sort((a, b) => b[0] - a[0] || b[1] - a[1]);
  return scored[0]?.[2] || null;
}

function geminiUsage(um = {}) {
  return {
    input: Math.max(0, (um.promptTokenCount || 0) - (um.cachedContentTokenCount || 0)),
    output: (um.candidatesTokenCount || 0) + (um.thoughtsTokenCount || 0),
    cacheRead: um.cachedContentTokenCount || 0,
    cacheWrite: 0,
  };
}

async function geminiGenerate(settings, model, body, outerSignal) {
  await aiGate();
  const call = track(outerSignal);
  try {
    const data = await httpJson(`${geminiBase(settings)}/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': settings.geminiKey },
      body: JSON.stringify(body),
      signal: call.signal,
    });
    recordSpend(geminiUsage(data.usageMetadata), data.modelVersion || model, settings);
    return data;
  } finally {
    call.done();
  }
}

/** Gemini audio transcription (lib/stt.js) uses the same kill switch, limit and spend record. */
export function geminiRequest(settings, model, body, signal) {
  return geminiGenerate(settings, model, body, signal);
}

function geminiCandidate(data, usage) {
  if (data.promptFeedback?.blockReason) {
    const e = new LLMError('declined', `Gemini blocked the request (${data.promptFeedback.blockReason}).`);
    e.usage = usage;
    throw e;
  }
  const cand = data.candidates?.[0];
  if (!cand) throw new LLMError('server', 'Gemini returned no candidates');
  if (['SAFETY', 'RECITATION', 'PROHIBITED_CONTENT', 'BLOCKLIST', 'SPII'].includes(cand.finishReason)) {
    const e = new LLMError('declined', `Gemini stopped the response (${cand.finishReason}).`);
    e.usage = usage;
    throw e;
  }
  return cand;
}

const geminiText = (cand) => (cand.content?.parts || []).filter((p) => !p.thought && typeof p.text === 'string').map((p) => p.text).join('');

async function callGemini(settings, { system, parts, schema, effort, maxTokens, signal }) {
  const model = await resolveGeminiModel(settings);
  const opts = { thinking: geminiThinking(model, effort || settings.effort), schema: true };
  let max = maxTokens || 8192;
  const usage = {};
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
      data = await geminiGenerate(settings, model, body, signal);
    } catch (err) {
      if (err.kind === 'bad-request') {
        const m = err.message.toLowerCase();
        if (opts.thinking && /thinking/.test(m)) {
          opts.thinking = null;
          continue;
        }
        if (opts.schema && /schema/.test(m)) {
          opts.schema = false;
          continue;
        }
      }
      throw err;
    }
    addUsage(usage, geminiUsage(data.usageMetadata));
    const cand = geminiCandidate(data, usage);
    if (cand.finishReason === 'MAX_TOKENS') {
      if (max < 32768) {
        max *= 2;
        continue;
      }
      throw new LLMError('truncated', 'Response hit the output limit');
    }
    return { data: parseJson(geminiText(cand)), usage, model: data.modelVersion || model, provider: 'gemini' };
  }
  throw new LLMError('bad-request', 'Gemini request failed after retries');
}

/** request: {system, parts: [string], schema, effort?, maxTokens?, cacheParts?, provider?, model?, signal?} */
export async function callLLM(settings, request) {
  const provider = request.provider || settings.provider;
  if (!hasKey(settings, provider)) throw new LLMError('config', `No ${provider === 'gemini' ? 'Gemini' : 'Anthropic'} API key set`);
  return provider === 'gemini' ? callGemini(settings, request) : callAnthropic(settings, request);
}

// ---------------- plain text with optional web lookup ----------------

/**
 * One call that may search the web (Claude's web_search tool / Gemini's Google Search grounding).
 * Returns {text, sources: [{url, title}], usage, model, provider}.
 */
export async function generateText(settings, { provider: p, system, prompt, web = false, effort, maxTokens = 2000, signal }) {
  const provider = p || settings.provider;
  if (!hasKey(settings, provider)) throw new LLMError('config', `No ${provider === 'gemini' ? 'Gemini' : 'Anthropic'} API key set`);
  if (provider === 'gemini') {
    const model = await resolveGeminiModel(settings);
    const body = {
      systemInstruction: { parts: [{ text: system }] },
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
      generationConfig: { maxOutputTokens: maxTokens, ...(geminiThinking(model, effort || 'low') ? { thinkingConfig: geminiThinking(model, effort || 'low') } : {}) },
      ...(web ? { tools: [{ google_search: {} }] } : {}),
    };
    const data = await geminiGenerate(settings, model, body, signal);
    const usage = geminiUsage(data.usageMetadata);
    const cand = geminiCandidate(data, usage);
    const chunks = cand.groundingMetadata?.groundingChunks || [];
    const sources = chunks.map((c) => c.web).filter(Boolean).map((w) => ({ url: w.uri, title: w.title || w.uri }));
    return { text: geminiText(cand), sources, usage, model: data.modelVersion || model, provider };
  }
  const model = settings.anthropicModel;
  const client = anthropicClient(settings);
  const opts = anthropicOpts(settings, model, effort || 'low', null);
  const messages = [{ role: 'user', content: prompt }];
  const usage = {};
  const sources = [];
  let text = '';
  for (let turn = 0; turn < 4; turn++) {
    const data = await anthropicCreate(
      client,
      settings,
      {
        model,
        max_tokens: maxTokens,
        system,
        messages,
        ...(web ? { tools: [{ type: 'web_search_20260209', name: 'web_search', max_uses: 3 }] } : {}),
      },
      opts,
      signal,
    );
    addUsage(usage, anthropicUsage(data.usage));
    if (data.stop_reason === 'refusal') throw declined(data, usage);
    for (const b of data.content || []) {
      if (b.type !== 'text') continue;
      text += b.text;
      for (const c of b.citations || []) if (c.url && !sources.some((s) => s.url === c.url)) sources.push({ url: c.url, title: c.title || c.url, quote: c.cited_text || '' });
    }
    if (data.stop_reason !== 'pause_turn') return { text, sources, usage, model: data.model || model, provider };
    messages.push({ role: 'assistant', content: data.content }); // the server resumes its search loop
  }
  return { text, sources, usage, model, provider };
}

// ---------------- tool-use loop (assistant chat) ----------------

/**
 * Runs a conversation with client-side tools until the model answers.
 * tools: [{name, description, input_schema, run: async (input) => result}]
 * history: [{role: 'user'|'assistant', text}] — earlier turns as plain text (keeps every call small).
 * onStep({type:'tool', name, input, result}) is called after each tool runs.
 * Returns {text, usage, model, provider, steps}.
 */
export async function runChat(settings, { provider: p, system, history, tools, effort, maxTokens = 4000, maxTurns = 12, onStep = () => {}, onText = () => {}, trim = null, signal }) {
  const provider = p || settings.provider;
  if (!hasKey(settings, provider)) throw new LLMError('config', `No ${provider === 'gemini' ? 'Gemini' : 'Anthropic'} API key set`);
  const byName = new Map(tools.map((t) => [t.name, t]));
  const steps = [];
  const usage = {};
  const checkStop = () => {
    if (signal?.aborted) throw new LLMError('stopped', 'Stopped.');
  };
  // A tool may return {image: {mime, data}} (a screenshot): sent to the model as a picture, not as text.
  const split = (result) => {
    if (!result || typeof result !== 'object' || !result.image) return { data: result, image: null };
    const { image, ...rest } = result;
    return { data: rest, image };
  };
  const runTool = async (name, input) => {
    checkStop();
    const t = byName.get(name);
    let result;
    try {
      result = t ? await t.run(input || {}) : { error: `unknown tool ${name}` };
    } catch (err) {
      if (err instanceof LLMError && (err.kind === 'stopped' || err.kind === 'paused')) throw err;
      result = { error: err.message || String(err) };
    }
    const { data, image } = split(result);
    const step = { type: 'tool', name, input, result: data, image: !!image };
    steps.push(step);
    onStep(step);
    return result;
  };
  // trim = {tools: ['read_page', 'screenshot'], keep: 2}: older results of those tools are replaced by a short
  // note before each call, so a long task doesn't resend every old page (the newest ones are kept).
  const trimmed = [];
  const noteTrim = (name, ref) => {
    if (!trim || !trim.tools.includes(name)) return;
    trimmed.push(ref);
    while (trimmed.length > (trim.keep ?? 2)) trimmed.shift().stub();
  };

  if (provider === 'gemini') {
    const model = await resolveGeminiModel(settings);
    const contents = history.map((m) => ({ role: m.role === 'assistant' ? 'model' : 'user', parts: [{ text: m.text }] }));
    const thinking = geminiThinking(model, effort || 'medium');
    for (let turn = 0; turn < maxTurns; turn++) {
      checkStop();
      const data = await geminiGenerate(
        settings,
        model,
        {
          systemInstruction: { parts: [{ text: system }] },
          contents,
          tools: [
            {
              functionDeclarations: tools.map((t) => ({
                name: t.name,
                description: t.description,
                // Gemini rejects an OBJECT with no properties, so a tool without inputs gets no schema.
                ...(Object.keys(t.input_schema?.properties || {}).length ? { parameters: toGeminiSchema(t.input_schema) } : {}),
              })),
            },
          ],
          generationConfig: { maxOutputTokens: maxTokens, ...(thinking ? { thinkingConfig: thinking } : {}) },
        },
        signal,
      );
      addUsage(usage, geminiUsage(data.usageMetadata));
      const cand = geminiCandidate(data, usage);
      const calls = (cand.content?.parts || []).filter((x) => x.functionCall);
      if (!calls.length) return { text: geminiText(cand), usage, model: data.modelVersion || model, provider, steps };
      const said = geminiText(cand);
      if (said.trim()) onText(said);
      contents.push(cand.content); // echoed back unchanged (it carries Gemini's thought signatures)
      const responses = [];
      const pictures = [];
      for (const c of calls) {
        const { data: result, image } = split(await runTool(c.functionCall.name, c.functionCall.args));
        const part = { functionResponse: { name: c.functionCall.name, response: { result } } };
        responses.push(part);
        if (image) {
          const pic = { inline_data: { mime_type: image.mime, data: image.data } };
          pictures.push(pic);
          noteTrim(c.functionCall.name, { stub: () => { delete pic.inline_data; pic.text = '[an earlier screenshot, removed to save tokens]'; } });
        } else {
          noteTrim(c.functionCall.name, { stub: () => { part.functionResponse.response = { result: '[an earlier result, removed to save tokens — call the tool again for the current state]' }; } });
        }
      }
      contents.push({ role: 'user', parts: [...responses, ...pictures] });
    }
    return { text: 'I stopped after too many steps. Tell me what to do next.', usage, model, provider, steps };
  }

  const model = settings.anthropicModel;
  const client = anthropicClient(settings);
  const opts = anthropicOpts(settings, model, effort || 'medium', null);
  const messages = history.map((m) => ({ role: m.role, content: m.text }));
  const toolDefs = tools.map((t) => ({ name: t.name, description: t.description, input_schema: t.input_schema }));
  for (let turn = 0; turn < maxTurns; turn++) {
    checkStop();
    const data = await anthropicCreate(
      client,
      settings,
      { model, max_tokens: maxTokens, system, messages, tools: toolDefs, cache_control: { type: 'ephemeral' } },
      opts,
      signal,
    );
    addUsage(usage, anthropicUsage(data.usage));
    if (data.stop_reason === 'refusal') throw declined(data, usage);
    const text = (data.content || []).filter((b) => b.type === 'text').map((b) => b.text).join('');
    if (data.stop_reason !== 'tool_use') return { text, usage, model: data.model || model, provider, steps };
    if (text.trim()) onText(text);
    messages.push({ role: 'assistant', content: data.content });
    const results = [];
    for (const b of data.content) {
      if (b.type !== 'tool_use') continue;
      const { data: result, image } = split(await runTool(b.name, b.input));
      const json = JSON.stringify(result ?? null).slice(0, 20000);
      const block = {
        type: 'tool_result',
        tool_use_id: b.id,
        content: image ? [{ type: 'text', text: json }, { type: 'image', source: { type: 'base64', media_type: image.mime, data: image.data } }] : json,
        ...(result?.error ? { is_error: true } : {}),
      };
      results.push(block);
      noteTrim(b.name, { stub: () => { block.content = image ? '[an earlier screenshot, removed to save tokens]' : '[an earlier result, removed to save tokens — call the tool again for the current state]'; } });
    }
    messages.push({ role: 'user', content: results });
  }
  return { text: 'I stopped after too many steps. Tell me what to do next.', usage, model, provider, steps };
}

// ---------------- models (doubles as a key check) ----------------

export async function listModels(settings, provider = settings.provider) {
  if (provider === 'gemini') {
    if (!settings.geminiKey) throw new LLMError('config', 'Enter a Gemini API key first');
    const data = await httpJson(`${geminiBase(settings)}/v1beta/models?pageSize=1000`, { headers: { 'x-goog-api-key': settings.geminiKey } }, { retries: 0 });
    return (data.models || [])
      .filter((m) => (m.supportedGenerationMethods || []).includes('generateContent'))
      .map((m) => m.name.replace(/^models\//, ''))
      .filter((n) => /gemini/i.test(n));
  }
  if (!settings.anthropicKey) throw new LLMError('config', 'Enter an Anthropic API key first');
  try {
    const ids = [];
    for await (const m of anthropicClient(settings).models.list({ limit: 100 })) ids.push(m.id);
    return ids;
  } catch (e) {
    throw anthropicError(e);
  }
}
