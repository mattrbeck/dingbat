// Snippets that run INSIDE the real web app's page, shared by webbench.mjs
// (A/B benchmarking) and swstale.mjs (service-worker staleness reproduction).
//
// Each export is passed whole to page.evaluate(), so none of them may close
// over anything in this module's scope — they only see the page's globals.
//
// They deliberately call the app's own top-level functions rather than
// reimplementing anything: index.js is a classic script, so its top-level
// const/let (loadRom, writeToFS) resolve by bare name in an evaluate, and its
// top-level vars (paused, fastForward) are window properties.

// Fetch a ROM from the harness's /roms/ route, boot it through the app's real
// loadRom, run a fixed deterministic warm-up, then snapshot that moment so
// every later trial measures the exact same emulated frames.
//
// The warm-up uses benchFrames (no presentation, no rewind) and is long enough
// to get past logos into a title/attract scene with music running — these
// optimisations live in the APU/PPU/timer paths, so a silent black boot screen
// would understate them.
export const PAGE_PREP = async ({ romFile, bootFrames, stateFile }) => {
  const resp = await fetch("/roms/" + encodeURIComponent(romFile));
  if (!resp.ok) throw new Error("rom fetch failed " + resp.status);
  const bytes = new Uint8Array(await resp.arrayBuffer());
  const ext = romFile.slice(romFile.lastIndexOf(".")).toLowerCase();
  const fsName = "rom" + ext;
  writeToFS(fsName, bytes);
  await loadRom(fsName, romFile);

  Module._benchFrames(bootFrames);
  Module._clearAudioBuffer();

  // HEAPU8 is not in this build's EXPORTED_RUNTIME_METHODS, and the heap can
  // move under ALLOW_MEMORY_GROWTH, so take a fresh view on every access —
  // exactly what index.js does for the audio buffer.
  const u8 = () => Module.HEAPU8 || new Uint8Array(Module.memory.buffer);
  let size, ptr;
  if (stateFile) {
    // A supplied state replaces the captured one. It is loaded once here so a
    // version/format rejection fails prep loudly rather than silently leaving
    // every trial measuring the post-boot scene instead of the intended one.
    const sr = await fetch("/roms/" + encodeURIComponent(stateFile));
    if (!sr.ok) throw new Error("state fetch failed " + sr.status);
    window.__benchState = new Uint8Array(await sr.arrayBuffer());
    size = window.__benchState.length;
  } else {
    size = Module._wasm_state_size();
    ptr = Module._wasm_state_data();
    window.__benchState = u8().slice(ptr, ptr + size);
  }
  window.__benchRestore = () => {
    const s = window.__benchState;
    const p = Module._malloc(s.length);
    u8().set(s, p);
    const ok = Module._wasm_load_state(p, s.length);
    Module._free(p);
    Module._clearAudioBuffer();
    if (!ok) throw new Error("state restore rejected");
  };
  if (stateFile) window.__benchRestore();   // fail now, not silently per-trial
  return { stateBytes: size };
};

// Two core-level costs, from the identical restored state:
//   emu  — benchFrames: emulation ONLY (no rewind, no present, no audio).
//   tick — loop_tick: what the app's frame loop actually calls, i.e. emulation
//          plus prepare_game_frame plus the rewind ring's periodic state
//          serialize/XOR/deflate.
// Returns ms per frame for each trial.
export const PAGE_CORE_TRIALS = ({ frames, trials }) => {
  const out = { emu: [], tick: [] };
  for (let t = 0; t < trials; t++) {
    for (const kind of ["emu", "tick"]) {
      window.__benchRestore();
      const t0 = performance.now();
      if (kind === "emu") {
        Module._benchFrames(frames);
      } else {
        for (let i = 0; i < frames; i++) Module._loop_tick();
      }
      const dt = performance.now() - t0;
      Module._clearAudioBuffer();
      out[kind].push(dt / frames);
    }
  }
  return out;
};

// The fast-forward loop's body, replicated exactly, timed per frame.
//
// index.js's FF branch is not just loop_tick: for every emulated frame it also
// consults performance.now() for the 16 ms budget and either pushes that
// frame's audio or throws it away with _clearAudioBuffer. Those are per-FRAME
// costs, so unlike the once-per-tick present they do NOT shrink as emulation
// gets cheaper — they are what makes the observed fps gain come in under the
// emulation gain. This isolates them: (ffsim - tick) is the per-frame JS
// overhead of the loop itself, with no RAF and no present involved.
//
// Kept structurally identical to the shipped loop rather than shared with it;
// if index.js's FF branch changes, this stops matching and should be updated.
export const PAGE_FFSIM = ({ frames }) => {
  window.__benchRestore();
  const t0 = performance.now();
  let n = 0;
  const start = performance.now();
  while (n < frames) {
    performance.now() - start;         // the budget check the real loop makes
    Module._loop_tick();
    Module._clearAudioBuffer();        // the no-audio-room branch
    n++;
  }
  return (performance.now() - t0) / frames;
};

// The present path, measured directly: the app's own drawGame() — texture
// upload of the raw BGR555 framebuffer plus the present shader. In fast-forward
// this runs ONCE PER RAF TICK while loop_tick runs as many times as fit in the
// tick's 16 ms budget, so its per-emulated-frame share is this divided by the
// frames-per-tick count. drawGame is a top-level const in index.js, which
// cannot be reassigned but can be READ by name from an evaluate.
//
// Caveat, stated because it bounds the conclusion: this is CPU submit time.
// GPU work runs asynchronously, so a GPU-bound present would show up here only
// as back-pressure on a later call, and headless Chromium's ANGLE/SwiftShader
// path does that work on the CPU anyway. Treat it as "what the frame loop
// blocks on", which is the quantity the fast-forward budget cares about.
export const PAGE_DRAW_TRIALS = ({ calls, trials }) => {
  const out = [];
  for (let t = 0; t < trials; t++) {
    drawGame(); // warm the first-call path out of the sample
    const t0 = performance.now();
    for (let i = 0; i < calls; i++) drawGame();
    out.push((performance.now() - t0) / calls);
  }
  return out;
};

// The app's real uncapped fast-forward: clicks the real #fast-forward button
// and reads the app's own #fps counter — the exact number the user reports.
export const PAGE_FF = async ({ samples }) => {
  window.__benchRestore();
  const fpsDiv = document.getElementById("fps");
  document.getElementById("fast-forward").click();
  const seen = [];
  let last = null;
  const t0 = performance.now();
  // The counter is republished by a 1 s setInterval; poll for changes and
  // discard the first two (a mode switch mid-window yields a blended count,
  // and the first full window includes FF spin-up).
  while (seen.length < samples + 2 && performance.now() - t0 < (samples + 6) * 1100) {
    await new Promise((r) => setTimeout(r, 60));
    const txt = fpsDiv.textContent.trim();
    const n = parseInt(txt, 10);
    if (Number.isFinite(n) && txt !== last) { seen.push(n); last = txt; }
  }
  document.getElementById("fast-forward").click();
  return { fps: seen.slice(2), raw: seen };
};

// Average RAF interval — the tick cadence the fast-forward loop's fixed 16 ms
// per-tick budget is quantised to.
//
// The 3 s bail-out is not belt-and-braces: a browser window that is not
// actually being composited (a headed run with no visible window, an occluded
// or backgrounded tab) delivers NO animation frames at all, and page.evaluate
// has no default timeout, so without this the whole harness hangs silently
// instead of reporting a useless RAF rate. Returns 0 when RAF never ran, which
// also invalidates the fast-forward numbers from that run — the FF loop IS a
// RAF loop.
export const PAGE_RAF = () =>
  new Promise((res) => {
    const ts = [];
    const bail = setTimeout(() => res(ts.length > 1 ? (ts[ts.length - 1] - ts[0]) / (ts.length - 1) : 0), 3000);
    const tick = (t) => {
      ts.push(t);
      if (ts.length < 31) requestAnimationFrame(tick);
      else { clearTimeout(bail); res((ts[30] - ts[0]) / 30); }
    };
    requestAnimationFrame(tick);
  });

// The benched scene as a PNG data URL. Guards against silently benchmarking a
// black boot screen. Uses the core's own corrected-RGBA framebuffer
// (_wasm_fb_ptr) rather than a canvas grab — the WebGL2 present context has no
// preserveDrawingBuffer.
export const PAGE_SHOT = () => {
  const gbc = Module._wasm_panel_gbc() === 1;
  const w = gbc ? 160 : 240, h = gbc ? 144 : 160;
  const ptr = Module._wasm_fb_ptr();
  const src = new Uint8Array(Module.HEAPU8 ? Module.HEAPU8.buffer : Module.memory.buffer,
                             ptr, w * h * 4);
  const cv = document.createElement("canvas");
  cv.width = w; cv.height = h;
  cv.getContext("2d").putImageData(new ImageData(new Uint8ClampedArray(src), w, h), 0, 0);
  return cv.toDataURL("image/png");
};

// Which build is this tab actually RUNNING, versus which is on the server?
//
// The production service worker is cache-first and matches only its own
// versioned cache, while index.js's update check reads version.txt with
// cache:"no-store" — which sw.js explicitly passes through to the network. So
// these two answers can disagree, and when they do, every server-side check
// ("version.txt says the new commit") is satisfied while the tab still runs
// the previous em.wasm. This reports both sides plus the update button state.
export const PAGE_WHICH_BUILD = async () => {
  const size = async (u, init) => {
    try { return (await (await fetch(u, init)).arrayBuffer()).byteLength; }
    catch { return -1; }
  };
  const text = async (u, init) => {
    try { return (await (await fetch(u, init)).text()).trim(); } catch { return "?"; }
  };
  return {
    // What the running page is served (through the SW, if one controls it)
    servedVersion: await text("version.txt"),
    servedWasmBytes: await size("em.wasm"),
    // What the ORIGIN currently has (sw.js passes no-store straight through)
    networkVersion: await text("version.txt", { cache: "no-store" }),
    networkWasmBytes: await size("em.wasm", { cache: "no-store" }),
    controlled: !!navigator.serviceWorker?.controller,
    updateButtonVisible: !document.getElementById("update-btn").hidden,
    cacheNames: typeof caches !== "undefined" ? await caches.keys() : [],
  };
};
