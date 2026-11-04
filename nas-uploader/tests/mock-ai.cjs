// Mock Anthropic and Gemini APIs for the assistant tests. Each test sets handlers; every request is recorded
// so tests can check what was sent (and how much).
//   const ai = await startMockAI();  ai.url → http://127.0.0.1:<port>
//   ai.anthropic = (body, req) => ({ content: [...], stop_reason: 'end_turn' })   (partial message is fine)
//   ai.gemini = (body, model) => ({ candidates: [...] })
//   ai.requests → [{api, path, body, headers}]
const http = require('http');

// API version 2026-10-21 (SDK 1.x) sends the key as "Authorization: Bearer"; older clients use x-api-key.
const anthropicKeyOk = (h) => h['x-api-key'] === 'sk-ant-test' || h.authorization === 'Bearer sk-ant-test';

function anthropicMessage(partial, body) {
  return {
    id: 'msg_' + Math.random().toString(36).slice(2),
    type: 'message',
    role: 'assistant',
    model: body?.model || 'claude-opus-5-5',
    content: [],
    stop_reason: 'end_turn',
    stop_sequence: null,
    usage: { input_tokens: 1000, output_tokens: 200, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
    ...partial,
  };
}

const text = (t) => ({ type: 'text', text: t });
const toolUse = (name, input, id) => ({ type: 'tool_use', id: id || 'toolu_' + Math.random().toString(36).slice(2, 10), name, input });

/** Gemini candidate with text or function calls. */
function geminiReply({ text: t, calls, finishReason = 'STOP', grounding } = {}) {
  const parts = [];
  if (t != null) parts.push({ text: t });
  for (const c of calls || []) parts.push({ functionCall: { name: c.name, args: c.args || {} }, thoughtSignature: 'sig-' + c.name });
  return {
    candidates: [{ content: { role: 'model', parts }, finishReason, ...(grounding ? { groundingMetadata: grounding } : {}) }],
    usageMetadata: { promptTokenCount: 800, candidatesTokenCount: 120, totalTokenCount: 920 },
    modelVersion: 'gemini-3.5-flash',
  };
}

async function startMockAI({ port = 0 } = {}) {
  const ai = {
    requests: [],
    anthropic: (body) => anthropicMessage({ content: [text('ok')] }, body),
    gemini: () => geminiReply({ text: 'ok' }),
    geminiModels: ['gemini-2.5-flash', 'gemini-3.5-flash', 'gemini-3.5-flash-lite', 'gemini-3.7-flash-preview-09-2026', 'gemini-3.5-pro', 'gemini-3.5-flash-image'],
    anthropicStatus: null, // e.g. {status: 401, body: {...}} to simulate errors once
    reset() {
      this.requests = [];
      this.anthropicStatus = null;
      this.anthropic = (body) => anthropicMessage({ content: [text('ok')] }, body);
      this.gemini = () => geminiReply({ text: 'ok' });
    },
    ofApi(api) {
      return this.requests.filter((r) => r.api === api);
    },
  };

  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', async () => {
      const send = (status, obj) => {
        res.writeHead(status, { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'access-control-allow-headers': '*' });
        res.end(JSON.stringify(obj));
      };
      if (req.method === 'OPTIONS') return send(204, {});
      let body = null;
      try {
        body = raw ? JSON.parse(raw) : null;
      } catch {
        body = { raw: raw.slice(0, 200) };
      }
      const url = new URL(req.url, 'http://x');
      try {
        if (url.pathname === '/v1/messages' && req.method === 'POST') {
          ai.requests.push({ api: 'anthropic', path: url.pathname, body, headers: req.headers });
          if (!anthropicKeyOk(req.headers)) return send(401, { type: 'error', error: { type: 'authentication_error', message: 'invalid x-api-key' } });
          if (ai.anthropicStatus) {
            const s = ai.anthropicStatus;
            ai.anthropicStatus = null;
            return send(s.status, s.body);
          }
          const out = await ai.anthropic(body, req);
          if (out && out.__status) return send(out.__status, out.body);
          return send(200, anthropicMessage(out, body));
        }
        if (url.pathname === '/v1/models' && req.method === 'GET') {
          ai.requests.push({ api: 'anthropic-models', path: url.pathname, headers: req.headers });
          if (!anthropicKeyOk(req.headers)) return send(401, { type: 'error', error: { type: 'authentication_error', message: 'invalid x-api-key' } });
          return send(200, { data: ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5'].map((id) => ({ id, type: 'model', display_name: id, created_at: '2026-01-01T00:00:00Z' })), has_more: false, first_id: 'claude-opus-5-5', last_id: 'claude-haiku-5-5' });
        }
        if (url.pathname === '/v1beta/models' && req.method === 'GET') {
          ai.requests.push({ api: 'gemini-models', path: url.pathname, headers: req.headers });
          if (req.headers['x-goog-api-key'] !== 'AIza-test') return send(400, { error: { code: 400, message: 'API key not valid. Please pass a valid API key.', status: 'INVALID_ARGUMENT' } });
          return send(200, { models: ai.geminiModels.map((n) => ({ name: 'models/' + n, supportedGenerationMethods: ['generateContent', 'countTokens'] })) });
        }
        const gm = /^\/v1beta\/models\/([^:]+):generateContent$/.exec(url.pathname);
        if (gm && req.method === 'POST') {
          const model = decodeURIComponent(gm[1]);
          ai.requests.push({ api: 'gemini', path: url.pathname, model, body, headers: req.headers });
          if (req.headers['x-goog-api-key'] !== 'AIza-test') return send(400, { error: { code: 400, message: 'API key not valid. Please pass a valid API key.', status: 'INVALID_ARGUMENT' } });
          const out = await ai.gemini(body, model);
          if (out && out.__status) return send(out.__status, out.body);
          return send(200, out);
        }
        send(404, { error: 'not found' });
      } catch (err) {
        send(500, { error: { message: String(err.stack || err) } });
      }
    });
  });
  await new Promise((r) => server.listen(port, '127.0.0.1', r));
  ai.url = `http://127.0.0.1:${server.address().port}`;
  ai.close = () => new Promise((r) => {
    server.closeAllConnections?.();
    server.close(r);
  });
  return ai;
}

module.exports = { startMockAI, anthropicMessage, geminiReply, text, toolUse };
