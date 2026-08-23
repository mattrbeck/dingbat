/*
 * Pacing probe: diagnostic overlay, loaded only with ?probe in the URL.
 * Records audio scheduling lead and underruns (buffers scheduled at/behind
 * the clock), rAF deltas, long tasks, and JS-heap GC cadence (Chrome only).
 * "I felt it" snapshots the ±2s window around a perceived hiccup, since
 * aggregates hide a once-a-minute glitch.
 */
(() => {
  if (window.__pacingProbe) return;
  window.__pacingProbe = true;

  const UA = navigator.userAgent;
  const isIOS = /iPhone|iPad|iPod/.test(UA) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  const httpOnIOS = isIOS && location.protocol === "http:";
  const noHeap = !performance.memory;

  const WIN = 2000; // ± window (ms) a felt-marker inspects
  const S = {
    t0: performance.now(),
    lead: [],          // seconds of audio queued ahead, per scheduled buffer
    underruns: [],      // timestamps of buffers scheduled at/behind the clock
    stalls: [],         // timestamps of frame ticks >20ms or long tasks
    longtasks: [],      // {t,d}
    raf: [],            // rAF deltas (ms)
    maxDt: 0, maxDtAt: 0,
    heap: [],
    recentF: [],        // {t, dt} rolling ~6s ring of frame deltas
    recentL: [],        // {t, lead} rolling ~6s ring of audio leads (ms)
    marks: [],          // felt-hiccup snapshots
  };
  const cap = (a, n) => { if (a.length > n) a.splice(0, a.length - n); };
  const prune = (a, now) => { while (a.length && now - a[0].t > 6000) a.shift(); };

  // Patch AudioBufferSourceNode.start to record lead + underruns.
  const P = window.AudioBufferSourceNode && AudioBufferSourceNode.prototype;
  if (P && !P.__pp) {
    const orig = P.start;
    P.start = function (when, ...rest) {
      try {
        const c = this.context;
        if (c && typeof when === "number" && c.state === "running") {
          const leadS = when - c.currentTime;
          const now = performance.now();
          S.lead.push(leadS); cap(S.lead, 8000);
          S.recentL.push({ t: now, lead: leadS * 1000 }); prune(S.recentL, now);
          if (leadS <= 0.001) { S.underruns.push(now); cap(S.underruns, 2000); }
        }
      } catch (e) {}
      return orig.call(this, when, ...rest);
    };
    P.__pp = true;
  }

  try {
    new PerformanceObserver((l) => {
      const now = performance.now();
      for (const e of l.getEntries()) { S.longtasks.push({ t: Math.round(e.startTime), d: Math.round(e.duration) }); S.stalls.push(now); }
      cap(S.longtasks, 1000); cap(S.stalls, 3000);
    }).observe({ entryTypes: ["longtask"] });
  } catch (e) {}

  let last = 0;
  (function raf(t) {
    if (last) {
      const dt = t - last;
      S.raf.push(dt); cap(S.raf, 8000);
      S.recentF.push({ t, dt }); prune(S.recentF, t);
      if (dt > S.maxDt) { S.maxDt = dt; S.maxDtAt = t; }
      if (dt > 20) { S.stalls.push(t); cap(S.stalls, 3000); }
    }
    last = t;
    requestAnimationFrame(raf);
  })(performance.now());

  setInterval(() => { if (performance.memory) { S.heap.push(performance.memory.usedJSHeapSize / 1e6); cap(S.heap, 3000); } }, 100);

  const pct = (a, p) => { if (!a.length) return NaN; const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]; };
  const f = (x, d = 0) => (Number.isFinite(x) ? x.toFixed(d) : "-");
  const stats = () => {
    const raf = S.raf, leadMs = S.lead.map((x) => x * 1000), heap = S.heap;
    const coupled = S.underruns.filter((u) => S.stalls.some((s) => Math.abs(s - u) < 60)).length;
    return {
      sec: (performance.now() - S.t0) / 1000,
      avg: raf.length ? raf.reduce((a, b) => a + b, 0) / raf.length : 0,
      p95: pct(raf, 95), max: S.maxDt,
      b1620: raf.filter((x) => x > 16.9 && x <= 20).length,
      b2033: raf.filter((x) => x > 20 && x <= 33).length,
      b33: raf.filter((x) => x > 33).length,
      sched: S.lead.length, ur: S.underruns.length, coupled,
      leadP50: pct(leadMs, 50), leadP95: pct(leadMs, 95), leadMin: leadMs.length ? Math.min(...leadMs) : NaN,
      lt: S.longtasks.length, ltMax: S.longtasks.reduce((m, x) => Math.max(m, x.d), 0),
      heapLo: heap.length ? Math.min(...heap) : NaN, heapHi: heap.length ? Math.max(...heap) : NaN,
      gc: heap.filter((v, i) => i > 0 && v < heap[i - 1] - 1).length,
    };
  };
  const markLine = (m) => `  @${m.at}s: worst frame ${f(m.worstDt, 1)}ms, min lead ${f(m.minLead, 1)}ms, underrun nearby: ${m.underrunNear ? "YES" : "no"}, longtask nearby: ${m.ltNear ? "YES(" + m.ltMax + "ms)" : "no"}`;
  const report = () => {
    const s = stats();
    const lines = [
      `dingbat pacing probe — ${f(s.sec)}s`,
      `origin: ${location.protocol}//${location.host}${httpOnIOS ? "  ⚠ HTTP on iOS = no JIT (use https://dingbat.gg)" : ""}${noHeap ? "  [heap/GC not available on this browser]" : ""}`,
      `frames: avg ${f(s.avg, 1)}ms  p95 ${f(s.p95, 1)}  max ${f(s.max, 1)}  |  16-20ms ${s.b1620}  20-33ms ${s.b2033}  >33ms ${s.b33}`,
      `audio: scheduled ${s.sched}  underruns ${s.ur}  (coupled w/ frame stall ${s.coupled})`,
      `  lead ms: p50 ${f(s.leadP50, 1)}  p95 ${f(s.leadP95, 1)}  min ${f(s.leadMin, 1)}`,
      `felt hiccups: ${S.marks.length}`,
      ...S.marks.map(markLine),
      `longtasks: ${s.lt} (worst ${f(s.ltMax)}ms)   heap ${f(s.heapLo)}–${f(s.heapHi)}MB  GC ${s.gc}`,
      `ua: ${UA}`,
    ];
    return lines.join("\n");
  };
  window.__pacingReport = report;

  const markFelt = () => {
    const now = performance.now();
    const nf = S.recentF.filter((x) => Math.abs(x.t - now) <= WIN);
    const nl = S.recentL.filter((x) => Math.abs(x.t - now) <= WIN).map((x) => x.lead);
    const lt = S.longtasks.filter((x) => Math.abs(x.t - now) <= WIN);
    S.marks.push({
      at: Math.round((now - S.t0) / 1000),
      worstDt: nf.reduce((m, x) => Math.max(m, x.dt), 0),
      minLead: nl.length ? Math.min(...nl) : NaN,
      underrunNear: S.underruns.some((u) => Math.abs(u - now) <= WIN),
      ltNear: lt.length > 0,
      ltMax: lt.reduce((m, x) => Math.max(m, x.d), 0),
    });
  };

  const build = () => {
    const box = document.createElement("div");
    box.setAttribute("style", [
      "position:fixed", "z-index:99999", "top:calc(env(safe-area-inset-top,0px) + 2px)", "left:50%", "transform:translateX(-50%)",
      "max-width:min(96vw,600px)", "font:11px/1.35 ui-monospace,Menlo,monospace", "color:#e8eef6",
      "background:rgba(8,10,16,0.82)", "border:1px solid rgba(255,255,255,0.18)", "border-radius:8px",
      "padding:4px 6px", "backdrop-filter:blur(3px)", "-webkit-backdrop-filter:blur(3px)", "user-select:none", "-webkit-user-select:none",
    ].join(";"));
    const bodyEl = document.createElement("div");
    bodyEl.setAttribute("style", "white-space:pre-wrap");
    const row = document.createElement("div");
    row.setAttribute("style", "display:flex;gap:6px;margin-top:4px");
    const mkBtn = (label, bg, fg, fn, grow = 1) => {
      const b = document.createElement("button");
      b.textContent = label;
      b.setAttribute("style", `flex:${grow};font:600 12px ui-monospace,monospace;color:${fg};background:${bg};border:none;border-radius:5px;padding:7px 8px;cursor:pointer;white-space:nowrap`);
      b.addEventListener("click", (e) => { e.stopPropagation(); fn(b); });
      return b;
    };
    let collapsed = true;

    const feltBtn = mkBtn("⚠ I felt it", "#ff6b6b", "#2a0000", (b) => {
      markFelt();
      try { navigator.vibrate && navigator.vibrate(20); } catch (e) {}
      b.textContent = `logged @${S.marks[S.marks.length - 1].at}s`;
      setTimeout(() => { b.textContent = "⚠ I felt it"; }, 900);
      render();
    }, 2);
    const expandBtn = mkBtn("▽", "#2a3245", "#e8eef6", () => { collapsed = !collapsed; expandBtn.textContent = collapsed ? "▽" : "△"; render(); }, 0.6);

    const copyBtn = mkBtn("Copy report", "#ffb04d", "#2a1800", async (b) => {
      const txt = report();
      try { await navigator.clipboard.writeText(txt); b.textContent = "Copied ✓"; }
      catch {
        const ta = document.createElement("textarea"); ta.value = txt;
        ta.setAttribute("style", "position:fixed;top:8%;left:4%;width:92%;height:46%;z-index:100000;font:11px ui-monospace,monospace");
        document.body.appendChild(ta); ta.focus(); ta.select();
        b.textContent = "select+copy, tap to close"; b.onclick = () => ta.remove();
      }
      setTimeout(() => { if (b.textContent.startsWith("Copied")) b.textContent = "Copy report"; }, 1500);
    });
    const resetBtn = mkBtn("Reset", "#2a3245", "#e8eef6", () => {
      S.t0 = performance.now(); S.maxDt = 0;
      for (const k of ["lead", "underruns", "stalls", "longtasks", "raf", "heap", "recentF", "recentL", "marks"]) S[k].length = 0;
      render();
    });
    const expandedRow = document.createElement("div");
    expandedRow.setAttribute("style", "display:flex;gap:6px;margin-top:6px");
    expandedRow.append(copyBtn, resetBtn);

    row.append(feltBtn, expandBtn);
    box.append(bodyEl, row, expandedRow);

    const render = () => {
      const s = stats();
      if (collapsed) {
        bodyEl.textContent = `⏱ ${f(s.avg, 1)}ms  drops ${s.b33}  ur ${s.ur}  felt ${S.marks.length}`;
        expandedRow.style.display = "none";
      } else {
        bodyEl.textContent = report();
        expandedRow.style.display = "flex";
      }
      if (httpOnIOS) box.style.borderColor = "#ff6b6b";
    };
    document.body.appendChild(box);
    render();
    setInterval(render, 500);
  };

  if (document.body) build(); else addEventListener("DOMContentLoaded", build);
})();
