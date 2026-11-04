// Meeting audio: capture (Teams app via system audio, Teams in Chrome via tab audio, microphone),
// level metering, and cutting speech into short segments at natural pauses.

export const SAMPLE_RATE = 16000;

export async function createAudioContext() {
  const ctx = new AudioContext();
  await ctx.audioWorklet.addModule(new URL('./audio-worklet.js', import.meta.url));
  return ctx;
}

/** Keep only the audio of a screen/tab share. Throws a friendly error if the share has no sound. */
function audioOnly(stream, howToFix) {
  const audio = stream.getAudioTracks();
  for (const v of stream.getVideoTracks()) v.stop(); // we only listen; nothing is recorded from the screen
  if (!audio.length) {
    for (const t of stream.getTracks()) t.stop();
    const err = new Error(`That share has no sound. ${howToFix}`);
    err.code = 'no-audio';
    throw err;
  }
  return new MediaStream(audio);
}

/**
 * Teams desktop app (Windows): Chrome can only hear other programs through a screen share with
 * "Share system audio" ticked. The picture is discarded straight away.
 */
export async function captureTeamsApp() {
  const stream = await navigator.mediaDevices.getDisplayMedia({
    video: { displaySurface: 'monitor' },
    audio: { suppressLocalAudioPlayback: false },
    systemAudio: 'include',
    monitorTypeSurfaces: 'include',
    selfBrowserSurface: 'exclude',
    surfaceSwitching: 'exclude',
  });
  return audioOnly(stream, 'Pick "Entire screen" and tick "Share system audio" before clicking Share.');
}

/** Teams in a Chrome tab: share that tab with "Share tab audio" ticked (you still hear it as normal). */
export async function captureTeamsTab() {
  const stream = await navigator.mediaDevices.getDisplayMedia({
    video: { displaySurface: 'browser' },
    audio: { suppressLocalAudioPlayback: false },
    preferCurrentTab: false,
    selfBrowserSurface: 'exclude',
    surfaceSwitching: 'include',
  });
  return audioOnly(stream, 'Pick the Chrome tab with your Teams meeting and keep "Share tab audio" ticked.');
}

export async function captureMicrophone() {
  return navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
}

/**
 * One audio source ("Them" = the meeting, "Me" = microphone). Emits:
 *   'segment' {samples: Float32Array (16 kHz mono), start: Date, end: Date}
 * and exposes `level` (0..1) and `lastSoundAt` for the on-screen meters.
 */
export class AudioChannel extends EventTarget {
  constructor(ctx, stream, label, { minSegmentSec = 1.2, maxSegmentSec = 14, endSilenceMs = 700 } = {}) {
    super();
    this.ctx = ctx;
    this.stream = stream;
    this.label = label;
    this.opts = { minSegmentSec, maxSegmentSec, endSilenceMs };
    this.level = 0;
    this.peak = 0;
    this.lastSoundAt = 0;
    this.startedAt = Date.now();
    this.noiseFloor = 0.003;
    this.paused = false;
    this.frames = []; // current segment (100 ms frames)
    this.preroll = []; // a little audio before speech starts
    this.speechFrames = 0;
    this.silentMs = 0;
    this.segmentStart = null;
    this.ended = false;

    this.source = ctx.createMediaStreamSource(stream);
    this.node = new AudioWorkletNode(ctx, 'pcm-capture');
    this.node.port.onmessage = (e) => this.onFrame(e.data.samples, e.data.rms);
    this.source.connect(this.node);
    // The worklet must be pulled by the graph; route it through a muted gain so nothing is played back.
    this.sink = ctx.createGain();
    this.sink.gain.value = 0;
    this.node.connect(this.sink).connect(ctx.destination);
    for (const t of stream.getAudioTracks()) {
      t.addEventListener('ended', () => {
        this.ended = true;
        this.flush();
        this.dispatchEvent(new Event('ended'));
      });
    }
  }

  onFrame(samples, rms) {
    // Meter: dB scale from -60 dB (empty) to 0 dB (full), smoothed.
    const db = 20 * Math.log10(Math.max(rms, 1e-6));
    const lvl = Math.min(1, Math.max(0, (db + 60) / 60));
    this.level = Math.max(lvl, this.level * 0.85);
    this.peak = Math.max(this.peak * 0.97, lvl);
    // Adaptive noise floor: drifts down quickly, up slowly.
    this.noiseFloor = rms < this.noiseFloor ? rms * 0.5 + this.noiseFloor * 0.5 : this.noiseFloor * 0.995 + rms * 0.005;
    const threshold = Math.max(0.006, this.noiseFloor * 2.5);
    const speaking = rms > threshold;
    if (rms > 0.004) this.lastSoundAt = Date.now();
    if (this.paused) return;

    const frameMs = (samples.length / SAMPLE_RATE) * 1000;
    if (!this.frames.length) {
      if (!speaking) {
        this.preroll.push(samples);
        if (this.preroll.length > 3) this.preroll.shift();
        return;
      }
      this.segmentStart = new Date(Date.now() - frameMs * (this.preroll.length + 1));
      this.frames = this.preroll;
      this.preroll = [];
      this.speechFrames = 0;
      this.silentMs = 0;
    }
    this.frames.push(samples);
    if (speaking) {
      this.speechFrames++;
      this.silentMs = 0;
    } else this.silentMs += frameMs;
    const lenSec = (this.frames.length * frameMs) / 1000;
    if ((this.silentMs >= this.opts.endSilenceMs && lenSec >= this.opts.minSegmentSec) || lenSec >= this.opts.maxSegmentSec) this.flush();
    else if (this.silentMs >= this.opts.endSilenceMs * 2 && this.speechFrames < 3) this.reset(); // just a click or cough
  }

  reset() {
    this.frames = [];
    this.speechFrames = 0;
    this.silentMs = 0;
  }

  flush() {
    if (this.frames.length && this.speechFrames >= 3) {
      const total = this.frames.reduce((n, f) => n + f.length, 0);
      const samples = new Float32Array(total);
      let o = 0;
      for (const f of this.frames) {
        samples.set(f, o);
        o += f.length;
      }
      this.dispatchEvent(Object.assign(new Event('segment'), { samples, start: this.segmentStart, end: new Date() }));
    }
    this.reset();
  }

  /** True when no sound at all has arrived for `ms` (after the first `ms` of listening). */
  silentFor(ms) {
    const now = Date.now();
    return now - this.startedAt > ms && now - (this.lastSoundAt || this.startedAt) > ms;
  }

  stop() {
    this.flush();
    try {
      this.source.disconnect();
      this.node.disconnect();
      this.sink.disconnect();
    } catch {}
    for (const t of this.stream.getTracks()) t.stop();
  }
}

/** 16-bit PCM WAV (what speech APIs accept everywhere). */
export function encodeWav(samples, sampleRate = SAMPLE_RATE) {
  const buf = new ArrayBuffer(44 + samples.length * 2);
  const v = new DataView(buf);
  const str = (o, s) => [...s].forEach((c, i) => v.setUint8(o + i, c.charCodeAt(0)));
  str(0, 'RIFF');
  v.setUint32(4, 36 + samples.length * 2, true);
  str(8, 'WAVE');
  str(12, 'fmt ');
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true); // PCM
  v.setUint16(22, 1, true); // mono
  v.setUint32(24, sampleRate, true);
  v.setUint32(28, sampleRate * 2, true);
  v.setUint16(32, 2, true);
  v.setUint16(34, 16, true);
  str(36, 'data');
  v.setUint32(40, samples.length * 2, true);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    v.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
  return buf;
}

export function toBase64(arrayBuffer) {
  const bytes = new Uint8Array(arrayBuffer);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}
