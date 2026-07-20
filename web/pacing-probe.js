/*
 * dingbat pacing probe — diagnostic overlay, loaded only with ?probe in the URL.
 *
 * Measures what a "frame + audio hiccup at the same time" actually is:
 *   - audio scheduling lead (how far ahead of the audio clock each buffer is
 *     queued) and underruns (buffers scheduled at/behind the clock = a gap)
 *   - frame cadence via rAF deltas (>20ms / >33ms ticks = dropped frames)
 *   - main-thread long tasks (PerformanceObserver)
 *   - JS-heap GC cadence (Chrome only)
 * and correlates audio underruns with frame stalls — if they line up, one
 * blocked main thread is causing both; if underruns happen with no nearby
 * stall, the audio lead is just too small to absorb clock drift.
 *
 * Read it on the device: a tappable panel shows live stats; "Copy" puts a text
 * report on the clipboard so it can be pasted back. No effect without ?probe.
 */
(() => {
  if (window.__pacingProbe) return;
  window.__pacingProbe = true;

  const UA = navigator.userAgent;
  const isIOS = /iPhone|iPad|iPod/.test(UA) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  const httpOnIOS = isIOS && location.protocol === "http:";

  const S = {
    t0: performance.now(),
    lead: [],        // seconds of audio queued ahead, per scheduled buffer
    underruns: [],    // timestamps (performance.now) of buffers scheduled at/behind the clock
    stalls: [],       // timestamps of frame ticks >20ms or long tasks
    longtasks: [],    // {t,d}
    raf: [],          // rAF deltas (ms)
    maxDt: 0,
    heap: [],         // usedJSHeapSize MB samples
  };
  const cap = (a, n) => { if (a.length > n) a.splice(0, a.length - n); };

  // --- audio: patch scheduling to record lead + underruns ---
  const P = window.AudioBufferSourceNode && AudioBufferSourceNode.prototype;
  if (P && !P.__pp) {
    const orig = P.start;
    P.start = function (when, ...rest) {
      try {
        const c = this.context;
        if (c && typeof when === "number" && c.state === "running") {
          const lead = when - c.currentTime;
          S.lead.push(lead); cap(S.lead, 8000);
          if (lead <= 0.001) { S.underruns.push(performance.now()); cap(S.underruns, 2000); }
        }
      } catch (e) {}
      return orig.call(this, when, ...rest);
    };
    P.__pp = true;
  }

  // --- long tasks ---
  try {
    new PerformanceObserver((l) => {
      for (const e of l.getEntries()) {
        S.longtasks.push({ t: Math.round(e.startTime), d: Math.round(e.duration) });
        S.stalls.push(performance.now());
      }
      cap(S.longtasks, 1000); cap(S.stalls, 3000);
    }).observe({ entryTypes: ["longtask"] });
  } catch (e) {}

  // --- frame cadence ---
  let last = 0;
  (function raf(t) {
    if (last) {
      const dt = t - last;
      S.raf.push(dt); cap(S.raf, 8000);
      if (dt > S.maxDt) S.maxDt = dt;
      if (dt > 20) { S.stalls.push(performance.now()); cap(S.stalls, 3000); }
    }
    last = t;
    requestAnimationFrame(raf);
  })(performance.now());

  // --- heap / GC ---
  setInterval(() => { if (performance.memory) { S.heap.push(performance.memory.usedJSHeapSize / 1e6); cap(S.heap, 3000); } }, 100);

  // --- stats ---
  const pct = (a, p) => { if (!a.length) return NaN; const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]; };
  const stats = () => {
    const raf = S.raf, leadMs = S.lead.map((x) => x * 1000), heap = S.heap;
    const coupled = S.underruns.filter((u) => S.stalls.some((s) => Math.abs(s - u) < 60)).length;
    return {
      sec: (performance.now() - S.t0) / 1000,
      avg: raf.length ? raf.reduce((a, b) => a + b, 0) / raf.length : 0,
      p95: pct(raf, 95), max: S.maxDt,
      over20: raf.filter((x) => x > 20).length, over33: raf.filter((x) => x > 33).length,
      sched: S.lead.length, ur: S.underruns.length, coupled,
      leadP50: pct(leadMs, 50), leadP95: pct(leadMs, 95), leadMin: leadMs.length ? Math.min(...leadMs) : NaN,
      lt: S.longtasks.length, ltMax: S.longtasks.reduce((m, x) => Math.max(m, x.d), 0),
      heapLo: heap.length ? Math.min(...heap) : NaN, heapHi: heap.length ? Math.max(...heap) : NaN,
      gc: heap.filter((v, i) => i > 0 && v < heap[i - 1] - 1).length,
    };
  };
  const f = (x, d = 0) => (Number.isFinite(x) ? x.toFixed(d) : "-");
  const report = () => {
    const s = stats();
    return [
      `dingbat pacing probe — ${f(s.sec)}s`,
      `origin: ${location.protocol}//${location.host}${httpOnIOS ? "  ⚠ HTTP on iOS = no JIT (use https://gba.mattrb.com)" : ""}`,
      `frames: avg ${f(s.avg, 1)}ms  p95 ${f(s.p95, 1)}  max ${f(s.max, 1)}  |  >20ms ${s.over20}  >33ms ${s.over33}`,
      `audio: scheduled ${s.sched}  underruns ${s.ur}  (coupled w/ frame stall ${s.coupled})`,
      `  lead ms: p50 ${f(s.leadP50, 1)}  p95 ${f(s.leadP95, 1)}  min ${f(s.leadMin, 1)}`,
      `longtasks: ${s.lt} (worst ${f(s.ltMax)}ms)   heap ${f(s.heapLo)}–${f(s.heapHi)}MB  GC ${s.gc}`,
      `ua: ${UA}`,
    ].join("\n");
  };
  window.__pacingReport = report;

  // --- on-screen panel (readable + copyable on a phone) ---
  const build = () => {
    const box = document.createElement("div");
    box.setAttribute("style", [
      "position:fixed", "z-index:99999", "top:calc(env(safe-area-inset-top,0px) + 4px)", "left:50%", "transform:translateX(-50%)",
      "max-width:min(96vw,560px)", "font:11px/1.35 ui-monospace,Menlo,monospace", "color:#e8eef6",
      "background:rgba(8,10,16,0.86)", "border:1px solid rgba(255,255,255,0.18)", "border-radius:8px",
      "padding:6px 8px", "white-space:pre-wrap", "backdrop-filter:blur(3px)", "-webkit-backdrop-filter:blur(3px)",
    ].join(";"));
    const body = document.createElement("div");
    const bar = document.createElement("div");
    bar.setAttribute("style", "display:flex;gap:6px;margin-top:5px");
    const mkBtn = (label, fn) => {
      const b = document.createElement("button");
      b.textContent = label;
      b.setAttribute("style", "flex:1;font:600 11px ui-monospace,monospace;color:#2a1800;background:#ffb04d;border:none;border-radius:5px;padding:5px 0;cursor:pointer");
      b.addEventListener("click", (e) => { e.stopPropagation(); fn(b); });
      return b;
    };
    const copyBtn = mkBtn("Copy report", async (b) => {
      const txt = report();
      try { await navigator.clipboard.writeText(txt); b.textContent = "Copied ✓"; }
      catch { // clipboard API needs https/localhost; fall back to a selectable box
        const ta = document.createElement("textarea"); ta.value = txt;
        ta.setAttribute("style", "position:fixed;top:10%;left:5%;width:90%;height:40%;z-index:100000");
        document.body.appendChild(ta); ta.focus(); ta.select();
        b.textContent = "Select + copy, then tap again";
        b.onclick = () => ta.remove();
      }
      setTimeout(() => { if (b.textContent.startsWith("Copied")) b.textContent = "Copy report"; }, 1500);
    });
    const resetBtn = mkBtn("Reset", () => {
      S.t0 = performance.now(); S.lead.length = S.underruns.length = S.stalls.length = 0;
      S.longtasks.length = S.raf.length = S.heap.length = 0; S.maxDt = 0;
    });
    bar.append(copyBtn, resetBtn);
    box.append(body, bar);

    let collapsed = false;
    box.addEventListener("click", () => { collapsed = !collapsed; bar.style.display = collapsed ? "none" : "flex"; render(); });
    const render = () => {
      const s = stats();
      if (collapsed) { body.textContent = `⏱ probe  max ${f(s.max, 0)}ms  ur ${s.ur}  (tap)`; return; }
      body.textContent = report();
      if (httpOnIOS) box.style.borderColor = "#ff6b6b";
    };
    document.body.appendChild(box);
    render();
    setInterval(render, 500);
  };

  if (document.body) build(); else addEventListener("DOMContentLoaded", build);
})();
