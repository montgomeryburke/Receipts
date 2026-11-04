// Recording to this computer: the computer's sound (or a tab's), the screen with its sound, and/or the microphone,
// mixed and written as it records — to a folder the user chose, or to Chrome's Downloads folder.
//
// Long recordings never sit in memory: chunks go straight to the chosen folder, or (for Downloads) to the
// browser's private file system first and are handed to Downloads when the recording stops.

import { kvGet, kvSet } from './db.js';

const pad = (n) => String(n).padStart(2, '0');

/** Best format this Chrome can record: MP4 (plays everywhere on Windows) when available, else WebM. */
export function pickFormat(kind) {
  const R = globalThis.MediaRecorder;
  const options = kind === 'screen'
    ? [['video/mp4;codecs=avc1.42E01E,mp4a.40.2', 'mp4'], ['video/mp4', 'mp4'], ['video/webm;codecs=vp9,opus', 'webm'], ['video/webm;codecs=vp8,opus', 'webm'], ['video/webm', 'webm']]
    : [['audio/mp4;codecs=mp4a.40.2', 'm4a'], ['audio/mp4', 'm4a'], ['audio/webm;codecs=opus', 'webm'], ['audio/webm', 'webm']];
  for (const [mime, ext] of options) if (R?.isTypeSupported?.(mime)) return { mime, ext };
  return { mime: '', ext: kind === 'screen' ? 'webm' : 'webm' };
}

export function recordingName(kind, ext, when = new Date(), label = '') {
  const stamp = `${when.getFullYear()}-${pad(when.getMonth() + 1)}-${pad(when.getDate())} ${pad(when.getHours())}${pad(when.getMinutes())}${pad(when.getSeconds())}`;
  return `Recording ${stamp} (${label || (kind === 'screen' ? 'screen' : 'audio')}).${ext}`;
}

// ---------- where recordings go ----------

export async function getRecordingFolder() {
  return (await kvGet('handle:recordings')) || null;
}

export async function setRecordingFolder(handle) {
  await kvSet('handle:recordings', handle || null);
}

/** Writes chunks, in order, into a file in a folder the user chose. */
class FolderSink {
  constructor(dir, name) {
    this.dir = dir;
    this.name = name;
    this.where = `${dir.name}\\${name}`;
    this.chain = Promise.resolve();
    this.bytes = 0;
  }

  async open() {
    this.file = await this.dir.getFileHandle(this.name, { create: true });
    this.w = await this.file.createWritable();
  }

  write(blob) {
    this.bytes += blob.size;
    this.chain = this.chain.then(() => this.w.write(blob));
    return this.chain;
  }

  async close() {
    await this.chain;
    await this.w.close();
    return { where: this.where, bytes: this.bytes };
  }
}

/** Writes chunks into the browser's private file system, then saves the finished file to Downloads/Recordings. */
class DownloadsSink {
  constructor(name) {
    this.name = name;
    this.where = `Downloads\\Recordings\\${name}`;
    this.chain = Promise.resolve();
    this.bytes = 0;
  }

  async open() {
    const root = await navigator.storage.getDirectory();
    this.tmpDir = await root.getDirectoryHandle('recordings-in-progress', { create: true });
    this.file = await this.tmpDir.getFileHandle(this.name, { create: true });
    this.w = await this.file.createWritable();
  }

  write(blob) {
    this.bytes += blob.size;
    this.chain = this.chain.then(() => this.w.write(blob));
    return this.chain;
  }

  async close() {
    await this.chain;
    await this.w.close();
    const file = await this.file.getFile();
    const url = URL.createObjectURL(file);
    const id = await chrome.downloads.download({ url, filename: `Recordings/${this.name}`, saveAs: false, conflictAction: 'uniquify' });
    // Tidy up the temporary copy once Chrome has saved it.
    const done = (delta) => {
      if (delta.id !== id || !delta.state || delta.state.current === 'in_progress') return;
      chrome.downloads.onChanged.removeListener(done);
      URL.revokeObjectURL(url);
      this.tmpDir.removeEntry(this.name).catch(() => {});
    };
    chrome.downloads.onChanged.addListener(done);
    return { where: this.where, bytes: this.bytes, downloadId: id };
  }
}

// ---------- a recording ----------

/**
 * opts: {kind: 'audio'|'screen', source: 'system'|'tab' (audio), includeMic, streams?: [MediaStream] (record these
 *        instead of asking — e.g. the meeting window's), label?, captureOverride?: async () => MediaStream,
 *        micOverride?: async () => MediaStream}
 * Events: 'level' is not dispatched; read .levels() for {system, mic} (0..1). 'stopped' when it ends by itself.
 */
export class Recording extends EventTarget {
  constructor(opts) {
    super();
    this.opts = opts;
    this.kind = opts.kind;
    this.tracks = [];
    this.startedAt = 0;
    this.state = 'idle';
  }

  async start() {
    const { kind, source = 'system', includeMic = true, streams } = this.opts;
    let display = null;
    let mic = null;
    if (streams) {
      // Already-captured sound (the meeting window records what it is listening to).
    } else if (this.opts.captureOverride) {
      display = await this.opts.captureOverride(kind);
    } else if (kind === 'screen') {
      display = await navigator.mediaDevices.getDisplayMedia({
        video: { frameRate: { ideal: 30, max: 30 } },
        audio: { suppressLocalAudioPlayback: false, echoCancellation: false, noiseSuppression: false, autoGainControl: false },
        systemAudio: 'include',
        monitorTypeSurfaces: 'include',
        selfBrowserSurface: 'exclude',
        surfaceSwitching: 'include',
      });
    } else {
      display = await navigator.mediaDevices.getDisplayMedia({
        video: { displaySurface: source === 'tab' ? 'browser' : 'monitor' },
        audio: { suppressLocalAudioPlayback: false, echoCancellation: false, noiseSuppression: false, autoGainControl: false },
        systemAudio: 'include',
        monitorTypeSurfaces: 'include',
        selfBrowserSurface: 'exclude',
        surfaceSwitching: 'include',
      });
    }
    if (display) this.tracks.push(...display.getTracks());
    if (kind === 'audio' && display) {
      for (const v of display.getVideoTracks()) v.stop(); // sound only
      if (!display.getAudioTracks().length) {
        this.cleanup();
        throw Object.assign(new Error(source === 'tab' ? 'That tab share has no sound. Keep "Also share tab audio" on.' : 'That share has no sound. Choose "Entire screen" and tick "Also share system audio".'), { code: 'no-audio' });
      }
    }
    if (includeMic && !streams) {
      try {
        mic = this.opts.micOverride ? await this.opts.micOverride() : await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
        this.tracks.push(...mic.getTracks());
      } catch (err) {
        this.micError = err.message || String(err);
      }
    }

    // Mix every sound source into one track (and measure each for the meters).
    this.ctx = new AudioContext();
    const dest = this.ctx.createMediaStreamDestination();
    this.analysers = {};
    const addSound = (stream, key) => {
      if (!stream?.getAudioTracks().length) return;
      const src = this.ctx.createMediaStreamSource(new MediaStream(stream.getAudioTracks()));
      const an = this.ctx.createAnalyser();
      an.fftSize = 1024;
      src.connect(an);
      src.connect(dest);
      this.analysers[key] = an;
    };
    if (streams) streams.forEach((s, i) => addSound(s, i === 0 ? 'system' : 'mic'));
    addSound(display, 'system');
    addSound(mic, 'mic');
    const video = kind === 'screen' && display ? display.getVideoTracks() : [];
    if (kind === 'screen' && !video.length) {
      this.cleanup();
      throw new Error('Nothing to record: the screen share has no picture.');
    }
    const hasSound = Object.keys(this.analysers).length > 0;
    if (!hasSound && kind === 'audio') {
      this.cleanup();
      throw new Error('No sound to record.');
    }
    const out = new MediaStream([...video, ...(hasSound ? dest.stream.getAudioTracks() : [])]);

    this.format = pickFormat(kind);
    this.name = recordingName(kind, this.format.ext, new Date(), this.opts.label);
    const folder = await getRecordingFolder();
    let sink = null;
    if (folder) {
      try {
        const perm = typeof folder.queryPermission === 'function' ? await folder.queryPermission({ mode: 'readwrite' }) : 'granted';
        if (perm === 'granted') sink = new FolderSink(folder, this.name);
      } catch {
        sink = null;
      }
    }
    this.sink = sink || new DownloadsSink(this.name);
    await this.sink.open();

    this.recorder = new MediaRecorder(out, {
      ...(this.format.mime ? { mimeType: this.format.mime } : {}),
      audioBitsPerSecond: 128000,
      ...(kind === 'screen' ? { videoBitsPerSecond: 2500000 } : {}),
    });
    this.recorder.ondataavailable = (e) => {
      if (e.data?.size) this.sink.write(e.data).catch((err) => {
        this.writeError = err.message;
      });
    };
    this.stopped = new Promise((r) => {
      this.recorder.onstop = r;
    });
    // If the user ends the share from Chrome's "Stop sharing" bar, finish the file.
    for (const t of display ? display.getTracks() : []) {
      t.addEventListener('ended', () => {
        if (this.state === 'recording' && (kind === 'screen' ? t.kind === 'video' : t.kind === 'audio')) this.stop().then((r) => this.dispatchEvent(Object.assign(new Event('stopped'), { result: r })));
      });
    }
    this.recorder.start(2000);
    this.startedAt = Date.now();
    this.state = 'recording';
    return this;
  }

  levels() {
    const out = {};
    for (const [k, an] of Object.entries(this.analysers || {})) {
      const buf = new Float32Array(an.fftSize);
      an.getFloatTimeDomainData(buf);
      let sum = 0;
      for (const v of buf) sum += v * v;
      const db = 20 * Math.log10(Math.max(Math.sqrt(sum / buf.length), 1e-6));
      out[k] = Math.min(1, Math.max(0, (db + 60) / 60));
    }
    return out;
  }

  get seconds() {
    return this.startedAt ? (Date.now() - this.startedAt) / 1000 : 0;
  }

  get bytes() {
    return this.sink?.bytes || 0;
  }

  async stop() {
    if (this.state !== 'recording') return this.result;
    this.state = 'stopping';
    if (this.recorder.state !== 'inactive') this.recorder.stop();
    await this.stopped;
    const saved = await this.sink.close();
    this.cleanup();
    this.state = 'done';
    this.result = { ...saved, name: this.name, seconds: this.seconds, kind: this.kind, mime: this.format.mime, error: this.writeError || '' };
    return this.result;
  }

  cleanup() {
    for (const t of this.tracks) t.stop();
    // Tracks of streams handed in by the meeting window belong to it — never stop those.
    this.ctx?.close().catch(() => {});
  }
}
