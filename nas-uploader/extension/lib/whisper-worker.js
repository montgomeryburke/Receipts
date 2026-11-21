// Free speech-to-text on this computer: Whisper (transformers.js + ONNX Runtime WebAssembly) in a worker, so
// the meeting window stays responsive. The model is downloaded once (from Hugging Face, or from the NAS after
// the HP setup script copied it there) and kept in the browser's cache.

import { pipeline, env } from '../vendor/transformers.mjs';

env.allowLocalModels = false;
env.useBrowserCache = true;
env.useWasmCache = false; // the WebAssembly files ship inside the extension
env.backends.onnx.wasm.wasmPaths = new URL('../vendor/ort/', import.meta.url).href;
env.backends.onnx.wasm.proxy = false;

let asr = null;
let loadedKey = '';
let loading = null;

// What Whisper typically "hears" in near-silence or noise. Real short replies ("Okay.", "Thank you.") are kept.
const HALLUCINATION = /^[\s.!?]*(\[[^\]]*\]|\([^)]*\)|\u266a+|thanks for watching!?|you)[\s.!?]*$/i;

async function load({ model, host, pathTemplate, auth, device }) {
  const key = `${model}|${host}|${device}`;
  if (asr && loadedKey === key) return;
  if (loading && loadedKey === key) return loading;
  loadedKey = key;
  env.remoteHost = host.endsWith('/') ? host : `${host}/`;
  env.remotePathTemplate = pathTemplate || '{model}/resolve/{revision}/';
  // The NAS needs the login; Hugging Face must not get it.
  env.fetch = (url, init = {}) => {
    if (auth && String(url).startsWith(env.remoteHost)) {
      const headers = new Headers(init.headers || {});
      headers.set('Authorization', auth);
      return fetch(url, { ...init, headers });
    }
    return fetch(url, init);
  };
  loading = (async () => {
    const opts = {
      dtype: 'q8',
      progress_callback: (p) => {
        if (p.status === 'progress') postMessage({ type: 'progress', file: p.file, loaded: p.loaded, total: p.total });
      },
    };
    try {
      asr = await pipeline('automatic-speech-recognition', model, { ...opts, device: device || 'wasm' });
    } catch (err) {
      if (device && device !== 'wasm') asr = await pipeline('automatic-speech-recognition', model, { ...opts, device: 'wasm' }); // WebGPU unavailable
      else throw err;
    }
  })();
  try {
    await loading;
  } catch (err) {
    asr = null;
    loadedKey = '';
    throw err;
  } finally {
    loading = null;
  }
}

self.onmessage = async (e) => {
  const msg = e.data;
  try {
    if (msg.type === 'load') {
      await load(msg);
      postMessage({ type: 'loaded', id: msg.id });
    } else if (msg.type === 'transcribe') {
      if (!asr) await load(msg.load);
      const english = /\.en$/.test(msg.load.model);
      const t0 = performance.now();
      const out = await asr(msg.samples, {
        chunk_length_s: 30,
        return_timestamps: false,
        ...(english ? {} : { language: msg.language || 'english', task: 'transcribe' }),
      });
      let text = String(out?.text || '').trim();
      if (HALLUCINATION.test(text)) text = '';
      postMessage({ type: 'result', id: msg.id, text, ms: Math.round(performance.now() - t0) });
    }
  } catch (err) {
    postMessage({ type: 'error', id: msg.id, error: String(err?.message || err) });
  }
};
