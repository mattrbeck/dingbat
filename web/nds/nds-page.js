// DS prototype page: loads the wasm core (nds.js), feeds it a ROM plus
// optional BIOS/firmware, blits the two 256x192 RGBA framebuffers and plays
// the sound output (NdsAudio below). The main app's audio path (web/index.js)
// is far more elaborate; this one only has to be simple and not glitch.
'use strict';

// Stereo ring buffer + band-limited resampler from the core's 32728.5 Hz to
// the AudioContext rate (windowed sinc, TAPS input frames per output frame,
// cut off just under the lower Nyquist). Shared by the AudioWorklet (its
// source is stringified into the worklet) and the ScriptProcessor fallback
// (insecure origins have no worklet).
//
// The page paces emulation from the audio clock (NdsAudio.fillFrames), so
// the fill hovers at `target`; the read step is still nudged (at most
// +-0.2%, from a smoothed fill) to absorb what pacing leaves. An underrun
// fades the last output to zero instead of cutting it (no click) and plays
// silence until `target` is buffered again, then fades back in.
class NdsAudioRing {
  constructor(inRate, outRate, targetFrames) {
    this.size = 16384;                     // frames, 0.5 s
    this.buf = new Float32Array(this.size * 2);
    this.w = 0;                            // frames written (monotonic)
    this.r = 0;                            // read position, fractional frames
    this.step = inRate / outRate;
    this.target = targetFrames;
    this.primed = false;
    this.avg = targetFrames;               // smoothed fill
    this.gain = 0;                         // fade in/out
    this.fade = 1 / (0.004 * outRate);     // 4 ms
    this.lastL = 0; this.lastR = 0;
    this.underruns = 0; this.overruns = 0; this.minFill = Infinity;
    // Windowed-sinc table: PHASES fractional offsets x TAPS taps.
    const T = this.TAPS = 24, P = this.PHASES = 512;
    const fc = 0.94 * Math.min(1, outRate / inRate) / 2;   // cycles per input frame
    this.kern = new Float32Array((P + 1) * T);
    for (let p = 0; p <= P; p++) {
      let sum = 0;
      for (let k = 0; k < T; k++) {
        const x = k - (T / 2 - 1) - p / P;   // tap position minus read position
        const s = x === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * x) / (Math.PI * x);
        const u = (x + T / 2) / T;            // 0..1 across the window
        const win = 0.42 - 0.5 * Math.cos(2 * Math.PI * u) + 0.08 * Math.cos(4 * Math.PI * u);
        this.kern[p * T + k] = s * win;
        sum += s * win;
      }
      for (let k = 0; k < T; k++) this.kern[p * T + k] /= sum;
    }
  }
  reset() {
    this.r = this.w;
    this.primed = false;
  }
  push(data) {
    const n = data.length >> 1, m = this.size - 1;
    if (this.w + n - this.r > this.size - this.TAPS) {    // overrun: drop the oldest
      this.r = this.w + n - this.target;
      this.overruns++;
    }
    for (let i = 0; i < n; i++) {
      const j = ((this.w + i) & m) * 2;
      this.buf[j] = data[2 * i];
      this.buf[j + 1] = data[2 * i + 1];
    }
    this.w += n;
  }
  pull(L, R) {
    const m = this.size - 1, T = this.TAPS, P = this.PHASES, kern = this.kern, buf = this.buf;
    const fill0 = this.w - this.r;
    this.avg += (fill0 - this.avg) * 0.02;
    if (this.primed && fill0 < this.minFill) this.minFill = fill0;
    const err = Math.max(-1, Math.min(1, (this.avg - this.target) / this.target));
    const step = this.step * (1 + 0.002 * err);
    for (let i = 0; i < L.length; i++) {
      const fill = this.w - this.r;
      if (!this.primed && fill >= this.target) this.primed = true;
      if (this.primed && fill < T) {
        this.primed = false;
        this.underruns++;
      }
      if (!this.primed) {
        // Fade the last output out: no step to zero.
        this.gain = Math.max(0, this.gain - this.fade);
        L[i] = this.lastL * this.gain;
        R[i] = this.lastR * this.gain;
        continue;
      }
      const k = Math.floor(this.r), f = this.r - k;
      const base = Math.round(f * P) * T;
      let l = 0, rr = 0;
      for (let t = 0, j = k - (T / 2 - 1); t < T; t++, j++) {
        const c = kern[base + t], a = (j & m) * 2;
        l += buf[a] * c;
        rr += buf[a + 1] * c;
      }
      this.gain = Math.min(1, this.gain + this.fade);
      this.lastL = l; this.lastR = rr;
      L[i] = l * this.gain;
      R[i] = rr * this.gain;
      this.r += step;
    }
  }
  stats() {
    const s = { r: this.r, fill: this.w - this.r, primed: this.primed,
                underruns: this.underruns, overruns: this.overruns,
                minFill: this.minFill === Infinity ? null : this.minFill };
    this.minFill = Infinity;
    return s;
  }
}

const NdsAudio = (() => {
  const IN_RATE = 33513982 / 1024;         // io/spu.nim SAMPLE_RATE
  const TARGET = Math.round(IN_RATE * 0.065);  // 65 ms buffered (4 video frames)
  let ctx = null, gainNode = null, send = null, reset = null, ring = null, muted = false;
  let sent = 0;                            // frames handed to the ring
  let last = null;                         // latest ring stats + the time they were taken
  const totals = { underruns: 0, overruns: 0, minFill: Infinity };

  function onStats(s, t) {
    last = { ...s, t };
    totals.underruns = s.underruns;
    totals.overruns = s.overruns;
    if (s.minFill !== null && s.minFill < totals.minFill) totals.minFill = s.minFill;
  }

  async function start() {
    if (ctx) return;
    try {
      ctx = new AudioContext({ latencyHint: 'interactive' });
      gainNode = ctx.createGain();
      gainNode.gain.value = muted ? 0 : 1;
      gainNode.connect(ctx.destination);
      if (ctx.audioWorklet) {
        const src = NdsAudioRing.toString() + `
          registerProcessor('nds-audio', class extends AudioWorkletProcessor {
            constructor(o) {
              super();
              const p = o.processorOptions;
              this.ring = new NdsAudioRing(p.inRate, sampleRate, p.target);
              this.n = 0;
              this.port.onmessage = e => {
                if (e.data === 'reset') this.ring.reset(); else this.ring.push(e.data);
              };
            }
            process(_, outs) {
              const o = outs[0];
              this.ring.pull(o[0], o[1] || o[0]);
              if ((++this.n & 3) === 0) this.port.postMessage({ s: this.ring.stats(), t: currentTime });
              return true;
            }
          });`;
        const url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
        await ctx.audioWorklet.addModule(url);
        URL.revokeObjectURL(url);
        const node = new AudioWorkletNode(ctx, 'nds-audio', {
          outputChannelCount: [2], processorOptions: { inRate: IN_RATE, target: TARGET } });
        node.port.onmessage = e => onStats(e.data.s, e.data.t);
        node.connect(gainNode);
        send = d => node.port.postMessage(d, [d.buffer]);
        reset = () => node.port.postMessage('reset');
      } else {
        ring = new NdsAudioRing(IN_RATE, ctx.sampleRate, TARGET);
        const node = ctx.createScriptProcessor(1024, 0, 2);
        node.onaudioprocess = e => {
          ring.pull(e.outputBuffer.getChannelData(0), e.outputBuffer.getChannelData(1));
          onStats(ring.stats(), ctx.currentTime);
        };
        node.connect(gainNode);
        send = d => ring.push(d);
        reset = () => ring.reset();
      }
      last = null;
      sent = 0;
    } catch (e) {
      console.warn('nds audio unavailable', e);
      ctx = null;
    }
  }

  return {
    start,
    IN_RATE,
    TARGET,
    // Input frames buffered ahead of the audio clock, or null when audio is
    // not running (pace by wall time then).
    fillFrames() {
      if (!ctx || ctx.state !== 'running' || !send) return null;
      if (ring) return ring.w - ring.r;
      if (!last) return sent;              // nothing consumed yet
      const used = last.primed ? Math.max(0, ctx.currentTime - last.t) * IN_RATE : 0;
      return sent - (last.r + used);
    },
    // After each emulated frame: hand the core's samples on, then clear.
    drain() {
      const n = Module._nds_audio_frames();
      if (n > 0 && send) {
        const p = Module._nds_audio_ptr();
        send(new Float32Array(Module.HEAPU8.buffer, p, n * 2).slice());
        sent += n;
      }
      Module._nds_audio_clear();
    },
    // Tab hidden: stop the clock (the page stops emulating); visible again:
    // drop what was queued and refill from scratch.
    pause() { if (ctx) ctx.suspend(); },
    resume() {
      if (!ctx) return;
      if (reset) reset();
      if (last) last = { ...last, r: sent, primed: false };
      ctx.resume();
    },
    toggleMute() {
      muted = !muted;
      if (gainNode) gainNode.gain.value = muted ? 0 : 1;
      return muted;
    },
    stats() {
      return { state: ctx ? ctx.state : 'none', rate: ctx ? ctx.sampleRate : 0,
               baseLatency: ctx ? ctx.baseLatency : 0, outputLatency: ctx ? ctx.outputLatency || 0 : 0,
               sent, fill: this.fillFrames(), underruns: totals.underruns,
               overruns: totals.overruns,
               minFill: totals.minFill === Infinity ? null : totals.minFill };
    },
  };
})();

var Module = {
  onRuntimeInitialized() { NdsPage.ready(); },
};

const NdsPage = (() => {
  const W = 256, H = 192;
  const top = document.getElementById('top').getContext('2d');
  const bottom = document.getElementById('bottom').getContext('2d');
  const imgTop = top.createImageData(W, H);
  const imgBottom = bottom.createImageData(W, H);
  const statusEl = document.getElementById('status');
  let loaded = false, paused = false, romBytes = null, last = 0, acc = 0;
  const FRAME_MS = 1000 / 59.8261;

  // BIOS/firmware live in localStorage (base64) so a reload keeps them.
  const BIOS_NAMES = ['bios9.bin', 'bios7.bin', 'firmware.bin'];
  function loadStored(name) {
    try {
      const s = localStorage.getItem('nds:' + name);
      if (!s) return null;
      return Uint8Array.from(atob(s), c => c.charCodeAt(0));
    } catch (e) { return null; }
  }
  function store(name, bytes) {
    try {
      let s = '';
      for (let i = 0; i < bytes.length; i += 0x8000)
        s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
      localStorage.setItem('nds:' + name, btoa(s));
    } catch (e) { console.warn('could not remember', name, e); }
  }

  function toHeap(bytes) {
    if (!bytes || !bytes.length) return [0, 0];
    const p = Module._malloc(bytes.length);
    Module.HEAPU8.set(bytes, p);
    return [p, bytes.length];
  }

  function boot(bytes) {
    romBytes = bytes;
    const args = [bytes, ...BIOS_NAMES.map(loadStored)].map(toHeap);
    Module._nds_load(...args.flat());
    args.forEach(([p]) => p && Module._free(p));
    loaded = true;
  }

  function blit() {
    const t = Module._nds_fb_top(), b = Module._nds_fb_bottom();
    imgTop.data.set(Module.HEAPU8.subarray(t, t + W * H * 4));
    imgBottom.data.set(Module.HEAPU8.subarray(b, b + W * H * 4));
    top.putImageData(imgTop, 0, 0);
    bottom.putImageData(imgBottom, 0, 0);
  }

  function frame() {
    Module._nds_run_frame();
    NdsAudio.drain();
    blit();
    statusEl.textContent = Module.UTF8ToString(Module._nds_status());
  }

  // Pacing: with audio running, emulate whenever less than the audio
  // target is buffered (the audio clock sets the speed, so there is no drift
  // to correct); without audio, by wall time. At most 4 frames per callback.
  const FRAME_FRAMES = NdsAudio.IN_RATE / 59.8261;
  function tick(now) {
    if (loaded && !paused) {
      let fill = NdsAudio.fillFrames();
      let n = 0;
      if (fill !== null) {
        while (fill < NdsAudio.TARGET && n < 4) { frame(); fill += FRAME_FRAMES; n++; }
        acc = 0;
      } else {
        acc += Math.min(100, now - last);
        while (acc >= FRAME_MS && n < 4) { frame(); acc -= FRAME_MS; n++; }
      }
    }
    last = now;
    requestAnimationFrame(tick);
  }
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) NdsAudio.pause(); else NdsAudio.resume();
  });

  // Buttons: ids follow NdsButton in src/dingbat/nds/io/input.nim
  const KEYS = { KeyX: 0, KeyZ: 1, ShiftLeft: 2, ShiftRight: 2, Enter: 3, ArrowRight: 4,
                 ArrowLeft: 5, ArrowUp: 6, ArrowDown: 7, KeyW: 8, KeyQ: 9, KeyS: 10, KeyA: 11 };
  function key(e, down) {
    if (!(e.code in KEYS) || !loaded) return;
    Module._nds_set_button(KEYS[e.code], down ? 1 : 0);
    e.preventDefault();
  }
  addEventListener('keydown', e => key(e, true));
  addEventListener('keyup', e => key(e, false));

  const bc = document.getElementById('bottom');
  function touch(e, down) {
    if (!loaded) return;
    const r = bc.getBoundingClientRect();
    const x = Math.floor((e.clientX - r.left) * W / r.width);
    const y = Math.floor((e.clientY - r.top) * H / r.height);
    Module._nds_set_touch(x, y, down ? 1 : 0);
  }
  bc.addEventListener('pointerdown', e => { bc.setPointerCapture(e.pointerId); touch(e, true); });
  bc.addEventListener('pointermove', e => { if (e.buttons) touch(e, true); });
  bc.addEventListener('pointerup', e => touch(e, false));

  document.getElementById('rom').addEventListener('change', async e => {
    const f = e.target.files[0];
    if (f) boot(new Uint8Array(await f.arrayBuffer()));
  });
  document.getElementById('bios').addEventListener('change', async e => {
    for (const f of e.target.files) {
      const name = f.name.toLowerCase();
      const bytes = new Uint8Array(await f.arrayBuffer());
      const kind = BIOS_NAMES.find(n => name.includes(n.split('.')[0])) ||
        (bytes.length === 4096 ? 'bios9.bin' : bytes.length === 16384 ? 'bios7.bin' :
         bytes.length === 262144 ? 'firmware.bin' : null);
      if (kind) store(kind, bytes);
    }
    if (romBytes) boot(romBytes);
  });
  document.getElementById('demo').addEventListener('change', async e => {
    if (!e.target.value) return;
    const r = await fetch(e.target.value);
    boot(new Uint8Array(await r.arrayBuffer()));
  });
  document.getElementById('pause').addEventListener('click', e => {
    paused = !paused;
    e.target.textContent = paused ? 'Resume' : 'Pause';
  });
  document.getElementById('step').addEventListener('click', () => { if (loaded) frame(); });
  document.getElementById('reset').addEventListener('click', () => { if (romBytes) boot(romBytes); });
  document.getElementById('mute').addEventListener('click', e => {
    e.target.textContent = NdsAudio.toggleMute() ? 'Unmute' : 'Mute';
  });
  // Browsers only allow audio after a user gesture.
  for (const ev of ['pointerdown', 'keydown'])
    addEventListener(ev, NdsAudio.start, { once: true, capture: true });

  return {
    ready() {
      const have = BIOS_NAMES.filter(loadStored);
      statusEl.textContent = 'core ready. BIOS/firmware stored: ' + (have.join(', ') || 'none');
      requestAnimationFrame(t => { last = t; tick(t); });
      const demo = new URLSearchParams(location.search).get('rom');
      if (demo) fetch(demo).then(r => r.arrayBuffer()).then(b => boot(new Uint8Array(b)));
    },
  };
})();
