// Speech-to-text for the meeting window, one segment at a time, in order:
//  - 'whisper': free, on this computer (lib/whisper-worker.js)
//  - 'gemini':  Gemini with the user's key (audio sent as a short WAV; ~32 tokens per second of audio)
//  - 'both':    Gemini, and Whisper on the same audio as a free second opinion: when the two hear different
//               numbers (12.5 m vs 12 m), the line is marked "unsure" and shows the other reading. If Gemini is
//               stopped, over the daily limit or unreachable, Whisper's text is used.

import { encodeWav, toBase64, SAMPLE_RATE } from './audio.js';
import { resolveGeminiModel, geminiRequest } from './llm.js';
import { sameNumbers, numbersIn } from './crosscheck.js';
import { basicAuthHeader } from './util.js';
import { CONFIG } from './config-store.js';
import { nasCreds } from './nas.js';

export class Transcriber extends EventTarget {
  constructor(settings) {
    super();
    this.settings = settings;
    const gem = Boolean(settings.geminiKey);
    this.engine = gem && settings.meetingStt === 'both' ? 'both' : gem && settings.meetingStt === 'gemini' ? 'gemini' : 'whisper';
    this.queue = [];
    this.busy = false;
    this.worker = null;
    this.seq = 0;
    this.pending = new Map();
    this.ready = false;
    this.behindSec = 0; // audio waiting to be transcribed
    this.audioSec = 0;
    this.costTokens = 0;
  }

  async whisperLoadOptions() {
    const s = this.settings;
    const host = (s.whisperHost || 'https://huggingface.co/').trim();
    let auth = '';
    // Model copied to the NAS by the setup script: send the NAS login with it.
    try {
      if (CONFIG.serverUrl && host.startsWith(new URL(CONFIG.serverUrl).origin)) {
        const c = await nasCreds();
        if (c) auth = basicAuthHeader(c.username, c.password);
      }
    } catch {
      /* not a NAS address */
    }
    return {
      model: s.whisperModel || 'Xenova/whisper-base.en',
      host,
      pathTemplate: s.whisperPathTemplate || '{model}/resolve/{revision}/',
      auth,
      // WebAssembly works on every computer; WebGPU with these quantized weights is not dependable.
      device: s.whisperDevice === 'webgpu' ? 'webgpu' : 'wasm',
    };
  }

  /** The model copy on the NAS (server/setup-webdav.sh puts it in /.assistant/models/<model>/). */
  async nasModelOptions() {
    try {
      const c = await nasCreds();
      if (!c || !CONFIG.serverUrl || /your-nas\.example/.test(CONFIG.serverUrl)) return null;
      return {
        ...this.loadOpts,
        host: new URL('.assistant/models/', CONFIG.serverUrl.endsWith('/') ? CONFIG.serverUrl : `${CONFIG.serverUrl}/`).href,
        pathTemplate: '{model}/',
        auth: basicAuthHeader(c.username, c.password),
      };
    } catch {
      return null;
    }
  }

  /** Loads the speech model (Whisper). Emits 'progress' {file, loaded, total}. Segments pushed meanwhile wait. */
  start() {
    if (!this.startPromise) this.startPromise = this._start();
    return this.startPromise;
  }

  async _start() {
    if (this.engine === 'both') {
      // Gemini unreachable at the start: carry on with the free model alone rather than not at all.
      try {
        this.model = await resolveGeminiModel(this.settings);
      } catch (err) {
        this.engine = 'whisper';
        this.lastGeminiError = err;
      }
    } else if (this.engine === 'gemini') this.model = await resolveGeminiModel(this.settings);
    if (this.engine === 'gemini') {
      this.ready = true;
      return;
    }
    await this.startWhisper();
  }

  /** Loads the free model (also later, as a stand-in, when Gemini is stopped or over the daily limit). */
  startWhisper() {
    if (!this.whisperPromise) this.whisperPromise = this._startWhisper().catch((err) => {
      this.whisperPromise = null;
      throw err;
    });
    return this.whisperPromise;
  }

  async _startWhisper() {
    this.worker?.terminate();
    this.worker = new Worker(new URL('./whisper-worker.js', import.meta.url), { type: 'module' });
    this.worker.onmessage = (e) => {
      const m = e.data;
      if (m.type === 'progress') {
        this.dispatchEvent(Object.assign(new Event('progress'), { file: m.file, loaded: m.loaded, total: m.total }));
        return;
      }
      const p = this.pending.get(m.id);
      if (!p) return;
      this.pending.delete(m.id);
      if (m.type === 'error') p.reject(new Error(m.error));
      else p.resolve(m);
    };
    this.worker.onerror = (e) => {
      for (const p of this.pending.values()) p.reject(new Error(e.message || 'speech worker crashed'));
      this.pending.clear();
    };
    this.loadOpts = await this.whisperLoadOptions();
    try {
      await this.call({ type: 'load', ...this.loadOpts });
    } catch (err) {
      // Work networks often block huggingface.co: fall back to the copy the HP setup script put on the NAS.
      const nas = await this.nasModelOptions();
      if (!nas || nas.host === this.loadOpts.host) throw err;
      this.loadOpts = nas;
      try {
        await this.call({ type: 'load', ...this.loadOpts });
      } catch (err2) {
        throw new Error(`${err.message} — and the copy on the NAS failed too: ${err2.message}`);
      }
    }
    this.ready = true;
  }

  call(msg, transfer) {
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ ...msg, id }, transfer || []);
    });
  }

  /** Queue a segment {samples, start, end, who}. Emits 'text' {segment, text} or 'error'. */
  push(segment) {
    const sec = segment.samples.length / SAMPLE_RATE;
    this.behindSec += sec;
    this.queue.push(segment);
    this.pump();
  }

  async pump() {
    if (this.busy) return;
    this.busy = true;
    try {
      try {
        await this.start();
      } catch (err) {
        // The model couldn't load: report every waiting segment once, keep them for a retry.
        this.dispatchEvent(Object.assign(new Event('error'), { error: err, fatal: true }));
        return;
      }
      while (this.queue.length) {
        const seg = this.queue.shift();
        const sec = seg.samples.length / SAMPLE_RATE;
        try {
          const r = await this.transcribe(seg.samples);
          this.audioSec += sec;
          this.dispatchEvent(Object.assign(new Event('text'), { segment: seg, ...r }));
        } catch (err) {
          this.dispatchEvent(Object.assign(new Event('error'), { segment: seg, error: err }));
        } finally {
          this.behindSec = Math.max(0, this.behindSec - sec);
        }
      }
    } finally {
      this.busy = false;
    }
  }

  /** {text, alt?, unsure?, by} for one segment, by the chosen engine(s). */
  async transcribe(samples) {
    if (this.engine === 'gemini') {
      try {
        return { text: await this.gemini(samples), by: 'gemini' };
      } catch (err) {
        // Stop AI, the daily limit, or a cancelled call: carry on with the free model instead of losing speech.
        if (!['paused', 'budget', 'stopped'].includes(err.kind)) throw err;
        this.lastGeminiError = err;
        await this.startWhisper();
        return { text: await this.whisper(samples), by: 'whisper', note: err.message };
      }
    }
    if (this.engine === 'whisper') return { text: await this.whisper(samples), by: 'whisper' };
    const [g, w] = await Promise.allSettled([this.gemini(samples), this.whisper(samples)]);
    if (g.status !== 'fulfilled') {
      if (w.status !== 'fulfilled') throw g.reason;
      this.lastGeminiError = g.reason;
      return { text: w.value, by: 'whisper', note: `Gemini: ${g.reason?.message || g.reason}` };
    }
    const text = g.value;
    const other = w.status === 'fulfilled' ? w.value : '';
    if (!other || !text) return { text: text || other, by: text ? 'gemini' : 'whisper' };
    // Numbers matter most (dimensions, prices, dates): two independent engines must agree on them.
    const unsure = (numbersIn(text).length || numbersIn(other).length) && !sameNumbers(text, other);
    return unsure ? { text, alt: other, unsure: true, by: 'gemini' } : { text, by: 'gemini' };
  }

  async whisper(samples) {
    const copy = new Float32Array(samples); // the original stays with the caller
    const r = await this.call({ type: 'transcribe', samples: copy, load: this.loadOpts }, [copy.buffer]);
    return r.text;
  }

  async gemini(samples, noThinking = false) {
    const thinking = noThinking ? {} : /gemini-2\.5/.test(this.model) ? { thinkingConfig: { thinkingBudget: 0 } } : /gemini-[3-9]/.test(this.model) ? { thinkingConfig: { thinkingLevel: 'low' } } : {};
    const body = {
      contents: [
        {
          role: 'user',
          parts: [
            { text: 'Transcribe this meeting audio word for word, in the language spoken. Return only the words, with normal punctuation. Write numbers as digits. If there is no speech, return nothing.' },
            { inline_data: { mime_type: 'audio/wav', data: toBase64(encodeWav(samples)) } },
          ],
        },
      ],
      generationConfig: { temperature: 0, maxOutputTokens: 1024, ...thinking },
    };
    let data;
    try {
      data = await geminiRequest(this.settings, this.model, body);
    } catch (err) {
      if (!noThinking && thinking.thinkingConfig && err.kind === 'bad-request' && /thinking/i.test(err.message)) return this.gemini(samples, true);
      err.message = `Gemini transcription: ${err.message}`;
      throw err;
    }
    this.costTokens += data?.usageMetadata?.totalTokenCount || 0;
    const parts = data?.candidates?.[0]?.content?.parts || [];
    return parts.filter((p) => !p.thought && typeof p.text === 'string').map((p) => p.text).join('').trim();
  }

  /** After a failed model load (no internet, wrong address): try again; waiting segments are kept. */
  retry() {
    this.startPromise = null;
    this.whisperPromise = null;
    this.pump();
  }

  stop() {
    this.queue = [];
    this.worker?.terminate();
    this.worker = null;
  }
}
