// Speech both ways, on this computer (free) or by the AI (Gemini):
//  - read aloud (text to speech): Chrome's own voices (Windows voices, offline, free) or a Gemini voice;
//  - dictation (speech to text) into the chat and the meeting's question box: Whisper on this computer (free) or
//    Gemini. Meeting transcription has its own choice (Settings → Meetings).

import { listModels, geminiRequest, hasKey } from './llm.js';
import { captureMicrophone, createAudioContext, AudioChannel } from './audio.js';
import { Transcriber } from './stt.js';

// ---------------- read aloud ----------------

let playing = null; // {stop()}

/** Stops whatever is being read aloud. */
export function stopSpeaking() {
  const p = playing;
  playing = null;
  try {
    p?.stop();
  } catch {
    /* already stopped */
  }
}

export const isSpeaking = () => Boolean(playing);

/** What is worth saying: no markdown marks, source tags or web addresses. */
export function speechText(text) {
  return String(text || '')
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, '$1')
    .replace(/https?:\/\/\S+?(?=[.,;:!?)]*(?:\s|$))/g, ' ')
    .replace(/\[(?:S|E|W|D|M|I|T)\d+(?:,\s*(?:S|E|W)\d+)*\]/g, '')
    .replace(/\[MISSING:\s*([^\]]+)\]/gi, '(missing: $1)')
    .replace(/[*_`#>]+/g, '')
    .replace(/[ \t]+/g, ' ')
    .replace(/ ([.,;:!?])/g, '$1')
    .replace(/\n{2,}/g, '\n')
    .trim()
    .slice(0, 5000);
}

/** Chrome's voices on this computer (the list fills in shortly after the page loads). */
export function computerVoices() {
  return new Promise((resolve) => {
    const have = speechSynthesis.getVoices();
    if (have.length) return resolve(have);
    const done = () => resolve(speechSynthesis.getVoices());
    speechSynthesis.addEventListener('voiceschanged', done, { once: true });
    setTimeout(done, 1500);
  });
}

export const GEMINI_VOICES = ['Kore', 'Puck', 'Charon', 'Aoede', 'Fenrir', 'Leda', 'Orus', 'Zephyr'];

async function speakComputer(text, settings) {
  const voices = await computerVoices();
  return new Promise((resolve) => {
    const u = new SpeechSynthesisUtterance(text);
    const v = voices.find((x) => x.name === settings.ttsVoice) || voices.find((x) => x.default) || null;
    if (v) u.voice = v;
    u.rate = Math.min(2, Math.max(0.5, Number(settings.ttsRate) || 1));
    u.onend = u.onerror = () => {
      if (playing?.utterance === u) playing = null;
      resolve({ engine: 'computer' });
    };
    playing = { utterance: u, stop: () => speechSynthesis.cancel() };
    speechSynthesis.speak(u);
  });
}

let ttsModelCache = '';
/** The newest Gemini voice model the key can use (a model name with "tts"), Flash before Pro. */
async function geminiTtsModel(settings) {
  if (settings.ttsGeminiModel) return settings.ttsGeminiModel;
  if (ttsModelCache) return ttsModelCache;
  const all = (await listModels(settings, 'gemini')).filter((m) => /tts/i.test(m));
  if (!all.length) throw Object.assign(new Error("Your Gemini key can't use a voice model."), { kind: 'config' });
  const ver = (m) => Number((/gemini-(\d+(?:\.\d+)?)/.exec(m) || [])[1]) || 0;
  all.sort((a, b) => ver(b) - ver(a) || Number(/pro/.test(a)) - Number(/pro/.test(b)) || Number(/preview/.test(a)) - Number(/preview/.test(b)));
  ttsModelCache = all[0];
  return ttsModelCache;
}

async function speakGemini(text, settings) {
  const model = await geminiTtsModel(settings);
  const voiceName = GEMINI_VOICES.includes(settings.ttsGeminiVoice) ? settings.ttsGeminiVoice : 'Kore';
  const body = {
    contents: [{ role: 'user', parts: [{ text }] }],
    generationConfig: { responseModalities: ['AUDIO'], speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName } } } },
  };
  const data = await geminiRequest({ ...settings, _tag: 'voice' }, model, body);
  const part = (data?.candidates?.[0]?.content?.parts || []).find((p) => p.inlineData || p.inline_data);
  const inl = part?.inlineData || part?.inline_data;
  if (!inl?.data) throw new Error('Gemini returned no audio');
  const rate = Number((/rate=(\d+)/.exec(inl.mimeType || inl.mime_type || '') || [])[1]) || 24000;
  const bytes = Uint8Array.from(atob(inl.data), (c) => c.charCodeAt(0));
  const pcm = new Int16Array(bytes.buffer, 0, bytes.length >> 1); // 16-bit little-endian, mono
  const ctx = new AudioContext();
  const buf = ctx.createBuffer(1, Math.max(1, pcm.length), rate);
  const ch = buf.getChannelData(0);
  for (let i = 0; i < pcm.length; i++) ch[i] = pcm[i] / 32768;
  const src = ctx.createBufferSource();
  src.buffer = buf;
  src.connect(ctx.destination);
  return new Promise((resolve) => {
    const end = () => {
      if (playing?.src === src) playing = null;
      ctx.close().catch(() => {});
      resolve({ engine: 'gemini', model });
    };
    src.onended = end;
    playing = { src, stop: () => { try { src.stop(); } catch { /* not started */ } end(); } };
    src.start();
  });
}

/**
 * Reads the text aloud with the chosen voice. The Gemini voice falls back to this computer's voice when it can't
 * be used (no key, AI stopped, over the daily limit), so read-aloud always works. Resolves when it has finished.
 */
export async function speak(text, settings) {
  stopSpeaking();
  const t = speechText(text);
  if (!t) return { engine: 'none' };
  if (settings.ttsEngine === 'gemini' && hasKey(settings, 'gemini')) {
    try {
      return await speakGemini(t, settings);
    } catch (err) {
      const r = await speakComputer(t, settings);
      return { ...r, fallback: err.message };
    }
  }
  return speakComputer(t, settings);
}

// ---------------- dictation ----------------

/**
 * Records the microphone until stop(), then turns the speech into text: Whisper on this computer (free; the
 * speech model is downloaded once) or Gemini (settings.dictationStt === 'gemini' and a Gemini key).
 */
export class Dictation {
  constructor(settings) {
    this.settings = settings;
    this.segments = [];
    this.useGemini = settings.dictationStt === 'gemini' && hasKey(settings, 'gemini');
  }

  async start() {
    try {
      this.stream = await captureMicrophone();
    } catch (err) {
      throw new Error(err?.name === 'NotAllowedError'
        ? 'Chrome needs your permission to use the microphone: open the meeting window once (🎙 Meeting) and allow the microphone, then try again.'
        : `The microphone can't be used: ${err.message}`);
    }
    this.ctx = await createAudioContext();
    this.channel = new AudioChannel(this.ctx, this.stream, 'dictation', { maxSegmentSec: 28, endSilenceMs: 1500 });
    this.channel.addEventListener('segment', (e) => this.segments.push(e.samples));
    // The speech model loads while you talk.
    this.stt = new Transcriber({ ...this.settings, meetingStt: this.useGemini ? 'gemini' : 'whisper' });
    this.ready = this.stt.start().catch((err) => err);
  }

  /** Level 0..1 for a meter. */
  get level() {
    return this.channel?.level || 0;
  }

  /** Stops recording and returns the text ('' when nothing was said). */
  async stop() {
    this.channel?.stop();
    this.ctx?.close().catch(() => {});
    const total = this.segments.reduce((n, s) => n + s.length, 0);
    if (!total) {
      this.stt?.stop();
      return '';
    }
    const samples = new Float32Array(total);
    let o = 0;
    for (const s of this.segments) {
      samples.set(s, o);
      o += s.length;
    }
    const startErr = await this.ready;
    try {
      if (startErr instanceof Error) throw startErr;
      const text = this.stt.engine === 'gemini' ? await this.stt.gemini(samples) : await this.stt.whisper(samples);
      return String(text || '').trim();
    } finally {
      this.stt.stop();
    }
  }

  cancel() {
    this.channel?.stop();
    this.ctx?.close().catch(() => {});
    this.stt?.stop();
  }
}

/**
 * Wires a 🎤 button to an input: click to talk, click again to stop; the words are added to the input.
 * `onError(message)` shows problems.
 */
export function attachDictation(button, input, { getSettings, onError = () => {}, onText = () => {} }) {
  let d = null;
  const idle = button.textContent;
  button.addEventListener('click', async () => {
    if (d) {
      const cur = d;
      d = null;
      button.textContent = '…';
      button.disabled = true;
      try {
        const text = await cur.stop();
        if (text) {
          input.value = `${input.value.trim()}${input.value.trim() ? ' ' : ''}${text}`;
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.focus();
          onText(text);
        } else onError('Nothing was heard.');
      } catch (err) {
        onError(`Dictation failed: ${err.message}`);
      } finally {
        button.textContent = idle;
        button.disabled = false;
        button.setAttribute('aria-pressed', 'false');
      }
      return;
    }
    const settings = await getSettings();
    d = new Dictation(settings);
    try {
      await d.start();
      button.textContent = '■ Stop';
      button.setAttribute('aria-pressed', 'true');
    } catch (err) {
      d = null;
      onError(err.message);
    }
  });
}
