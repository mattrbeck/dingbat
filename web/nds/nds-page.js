// DS prototype page: loads the wasm core (nds.js), feeds it a ROM plus
// optional BIOS/firmware, blits the two 256x192 RGBA framebuffers and plays
// the sound output (NdsAudio below). The main app's audio path (web/index.js)
// is far more elaborate; this one only has to be simple and not glitch much.
'use strict';

// Stereo ring buffer + linear resampler from the core's 32728.5 Hz to the
// AudioContext rate. The read step is nudged (+-0.5%) to hold the fill near
// `target`, absorbing the drift between requestAnimationFrame emulation
// pacing and the audio clock; an underrun goes silent until refilled.
// Shared by the AudioWorklet (its source is stringified into the worklet)
// and the ScriptProcessor fallback (insecure origins have no worklet).
class NdsAudioRing {
  constructor(inRate, outRate) {
    this.size = 32768;                     // frames, ~1 s
    this.buf = new Float32Array(this.size * 2);
    this.w = 0;                            // frames written (monotonic)
    this.r = 0;                            // read position, fractional frames
    this.step = inRate / outRate;
    this.target = Math.round(inRate * 0.06);
    this.primed = false;
  }
  push(data) {
    const n = data.length >> 1, m = this.size - 1;
    if (this.w + n - this.r > this.size - 4) this.r = this.w + n - this.target;  // overrun: skip
    for (let i = 0; i < n; i++) {
      const j = ((this.w + i) & m) * 2;
      this.buf[j] = data[2 * i];
      this.buf[j + 1] = data[2 * i + 1];
    }
    this.w += n;
  }
  pull(L, R) {
    const m = this.size - 1;
    for (let i = 0; i < L.length; i++) {
      const fill = this.w - this.r;
      if (!this.primed) this.primed = fill >= this.target;
      if (!this.primed || fill < 2) {
        this.primed = false;
        L[i] = R[i] = 0;
        continue;
      }
      const k = Math.floor(this.r), f = this.r - k;
      const a = (k & m) * 2, b = ((k + 1) & m) * 2;
      L[i] = this.buf[a] + (this.buf[b] - this.buf[a]) * f;
      R[i] = this.buf[a + 1] + (this.buf[b + 1] - this.buf[a + 1]) * f;
      const err = Math.max(-1, Math.min(1, (fill - this.target) / this.target));
      this.r += this.step * (1 + 0.005 * err);
    }
  }
}

const NdsAudio = (() => {
  const IN_RATE = 33513982 / 1024;         // io/spu.nim SAMPLE_RATE
  let ctx = null, send = null, muted = false;

  async function start() {
    if (ctx) return;
    try {
      ctx = new AudioContext();
      if (ctx.audioWorklet) {
        const src = NdsAudioRing.toString() + `
          registerProcessor('nds-audio', class extends AudioWorkletProcessor {
            constructor(o) {
              super();
              this.ring = new NdsAudioRing(o.processorOptions.inRate, sampleRate);
              this.port.onmessage = e => this.ring.push(e.data);
            }
            process(_, outs) {
              const o = outs[0];
              this.ring.pull(o[0], o[1] || o[0]);
              return true;
            }
          });`;
        const url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
        await ctx.audioWorklet.addModule(url);
        URL.revokeObjectURL(url);
        const node = new AudioWorkletNode(ctx, 'nds-audio', {
          outputChannelCount: [2], processorOptions: { inRate: IN_RATE } });
        node.connect(ctx.destination);
        send = d => node.port.postMessage(d, [d.buffer]);
      } else {
        const ring = new NdsAudioRing(IN_RATE, ctx.sampleRate);
        const node = ctx.createScriptProcessor(2048, 0, 2);
        node.onaudioprocess = e =>
          ring.pull(e.outputBuffer.getChannelData(0), e.outputBuffer.getChannelData(1));
        node.connect(ctx.destination);
        send = d => ring.push(d);
      }
      if (muted) ctx.suspend();
    } catch (e) {
      console.warn('nds audio unavailable', e);
    }
  }

  return {
    start,
    // After each emulated frame: hand the core's samples on, then clear.
    drain() {
      const n = Module._nds_audio_frames();
      if (n > 0 && send && !muted) {
        const p = Module._nds_audio_ptr();
        send(new Float32Array(Module.HEAPU8.buffer, p, n * 2).slice());
      }
      Module._nds_audio_clear();
    },
    toggleMute() {
      muted = !muted;
      if (ctx) muted ? ctx.suspend() : ctx.resume();
      return muted;
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

  function tick(now) {
    if (loaded && !paused) {
      acc += Math.min(100, now - last);
      let n = 0;
      while (acc >= FRAME_MS && n < 3) { frame(); acc -= FRAME_MS; n++; }
    }
    last = now;
    requestAnimationFrame(tick);
  }

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
