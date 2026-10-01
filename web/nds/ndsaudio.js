// --- DS audio output, shared by the main app and the dev page (nds.html) ---
// The core outputs interleaved stereo float32 at 33513982 / 1024 Hz. It goes
// through a ring buffer and a band-limited resampler (NdsAudioRing) running
// in an AudioWorklet (ScriptProcessor where there is no worklet: insecure
// origins), into whatever node the page hands attach(): the app's master
// gain (so volume, mute and the clip tap apply), or the dev page's own.
//
// Pacing is the page's job and reads fillFrames(): emulate while less than
// target() input frames are buffered ahead of the audio clock, so the audio
// clock sets the speed and nothing drifts. The ring still nudges its read
// step (at most +-0.2%, from a smoothed fill) to absorb what pacing leaves.
// An underrun fades the last output to zero instead of cutting it (no click)
// and plays silence until `target` is buffered again, then fades back in.
// Each underrun raises the target by a video frame (up to 8 frames); 20 s
// without one lowers it a frame again, down to the 4-frame base.

// Stereo ring buffer + windowed-sinc resampler from the core's rate to the
// AudioContext's (TAPS input frames per output frame, cut off just under the
// lower Nyquist). Its source is stringified into the worklet, so it must not
// refer to anything outside itself.
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
  setTarget(t) {
    this.target = t;
  }
  // Drop what is queued (a pause, a hidden tab): silent, not an underrun.
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

// One output: attach(ctx, dest) builds the node in that context (again only
// when the context changes), push() hands it samples, fillFrames() says how
// far ahead of the audio clock they reach.
const createNdsAudio = (inRate = 33513982 / 1024, fps = 59.8261) => {
  const FRAME = inRate / fps;              // input frames per video frame
  const BASE = Math.round(4 * FRAME), MAX = Math.round(8 * FRAME);   // 67 / 134 ms
  let target = BASE, calmSince = 0;
  let ctx = null, node = null, send = null, doReset = null, retarget = null, ring = null;
  let attaching = null;
  let sent = 0;                            // frames handed to the ring
  let last = null;                         // latest ring stats + when they were taken
  const totals = { underruns: 0, overruns: 0, minFill: Infinity };
  const workletCtxs = new WeakSet();       // contexts the processor is registered in

  function onStats(s, t) {
    if (s.underruns > totals.underruns) {
      target = Math.min(MAX, target + Math.round(FRAME));
      if (retarget) retarget(target);
      calmSince = t;
    } else if (t - calmSince > 20 && target > BASE) {
      target = Math.max(BASE, target - Math.round(FRAME));
      if (retarget) retarget(target);
      calmSince = t;
    }
    last = { ...s, t };
    totals.underruns = s.underruns;
    totals.overruns = s.overruns;
    if (s.minFill !== null && s.minFill < totals.minFill) totals.minFill = s.minFill;
  }

  const detach = () => {
    if (node) { try { node.disconnect(); } catch {} }
    if (node && node.port) { try { node.port.onmessage = null; } catch {} }
    if (node && "onaudioprocess" in node) node.onaudioprocess = null;
    node = send = doReset = retarget = ring = null;
    ctx = null;
    last = null;
    sent = 0;
    totals.underruns = 0; totals.overruns = 0; totals.minFill = Infinity;
  };

  const build = async (c, dest) => {
    if (c.audioWorklet && typeof AudioWorkletNode !== "undefined") {
      if (!workletCtxs.has(c)) {
        const src = NdsAudioRing.toString() + `
          registerProcessor('nds-audio', class extends AudioWorkletProcessor {
            constructor(o) {
              super();
              const p = o.processorOptions;
              this.ring = new NdsAudioRing(p.inRate, sampleRate, p.target);
              this.n = 0;
              this.port.onmessage = e => {
                if (e.data === 'reset') this.ring.reset();
                else if (typeof e.data === 'number') this.ring.setTarget(e.data);
                else this.ring.push(e.data);
              };
            }
            process(_, outs) {
              const o = outs[0];
              this.ring.pull(o[0], o[1] || o[0]);
              if ((++this.n & 3) === 0) this.port.postMessage({ s: this.ring.stats(), t: currentTime });
              return true;
            }
          });`;
        const url = URL.createObjectURL(new Blob([src], { type: "text/javascript" }));
        try { await c.audioWorklet.addModule(url); } finally { URL.revokeObjectURL(url); }
        workletCtxs.add(c);
      }
      const n = new AudioWorkletNode(c, "nds-audio", {
        outputChannelCount: [2], processorOptions: { inRate, target } });
      n.port.onmessage = (e) => onStats(e.data.s, e.data.t);
      n.connect(dest);
      node = n;
      send = (d) => n.port.postMessage(d, [d.buffer]);
      doReset = () => n.port.postMessage("reset");
      retarget = (t) => n.port.postMessage(t);
    } else {
      const rg = new NdsAudioRing(inRate, c.sampleRate, target);
      const n = c.createScriptProcessor(1024, 0, 2);
      n.onaudioprocess = (e) => {
        rg.pull(e.outputBuffer.getChannelData(0), e.outputBuffer.getChannelData(1));
        onStats(rg.stats(), c.currentTime);
      };
      n.connect(dest);
      node = n;
      ring = rg;
      send = (d) => rg.push(d);
      doReset = () => rg.reset();
      retarget = (t) => rg.setTarget(t);
    }
    ctx = c;
  };

  return {
    IN_RATE: inRate,
    FRAME,
    // Build the output in `c`, feeding `dest`. A second call for the same
    // context is a no-op; another context replaces the node.
    attach(c, dest) {
      if (!c) return Promise.resolve(false);
      if (ctx === c && node) return Promise.resolve(true);
      if (attaching) return attaching;
      detach();
      attaching = build(c, dest).then(() => true, (e) => {
        console.warn("DS audio unavailable", e);
        detach();
        return false;
      }).finally(() => { attaching = null; });
      return attaching;
    },
    detach,
    attached: () => !!send,
    target: () => target,
    // Input frames buffered ahead of the audio clock, or null when audio is
    // not running (pace by wall time then).
    fillFrames() {
      if (!ctx || ctx.state !== "running" || !send) return null;
      if (ring) return ring.w - ring.r;
      if (!last) return sent;              // nothing consumed yet
      const used = last.primed ? Math.max(0, ctx.currentTime - last.t) * inRate : 0;
      return sent - (last.r + used);
    },
    // Interleaved stereo; the array is transferred (do not reuse it).
    push(data) {
      const n = data.length >> 1; // before the send: a transfer empties `data`
      if (!send || !n) return;
      send(data);
      sent += n;
    },
    // Drop what is queued and refill from scratch (pause, hidden tab).
    reset() {
      if (doReset) doReset();
      if (last) last = { ...last, r: sent, primed: false };
    },
    stats() {
      return { state: ctx ? ctx.state : "none", rate: ctx ? ctx.sampleRate : 0,
               sent, fill: this.fillFrames(), target, underruns: totals.underruns,
               overruns: totals.overruns,
               minFill: totals.minFill === Infinity ? null : totals.minFill };
    },
  };
};
