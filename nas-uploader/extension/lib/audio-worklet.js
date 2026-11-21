// AudioWorklet: turns any input into 16 kHz mono float samples (what speech models expect) and reports the level.
// Runs on the audio thread, so it keeps working while the window is in the background.

class PcmCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ratio = sampleRate / 16000;
    // Read position for resampling, relative to the current block. It can be -1..0, meaning "between the
    // last sample of the previous block and the first of this one" — so `prev` carries that sample over.
    this.pos = 0;
    this.prev = 0;
    this.buf = new Float32Array(1600); // 100 ms at 16 kHz
    this.n = 0;
    this.sumSq = 0;
    this.count = 0;
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || !input.length || !input[0]) return true;
    const frames = input[0].length;
    // Mix down to mono.
    const mono = new Float32Array(frames);
    for (const ch of input) for (let i = 0; i < frames; i++) mono[i] += ch[i] / input.length;
    for (let i = 0; i < frames; i++) {
      this.sumSq += mono[i] * mono[i];
      this.count++;
    }
    // Linear-interpolation resampling to 16 kHz.
    while (this.pos < frames - 1) {
      const i = Math.floor(this.pos);
      const f = this.pos - i;
      const a = i < 0 ? this.prev : mono[i];
      const v = a * (1 - f) + mono[i + 1] * f;
      this.buf[this.n++] = Number.isFinite(v) ? v : 0;
      this.pos += this.ratio;
      if (this.n === this.buf.length) {
        const rms = Math.sqrt(this.sumSq / Math.max(1, this.count));
        this.port.postMessage({ samples: this.buf, rms: Number.isFinite(rms) ? rms : 0 }, [this.buf.buffer]);
        this.buf = new Float32Array(1600);
        this.n = 0;
        this.sumSq = 0;
        this.count = 0;
      }
    }
    this.prev = mono[frames - 1];
    this.pos -= frames; // now >= -1
    return true;
  }
}

registerProcessor('pcm-capture', PcmCapture);
