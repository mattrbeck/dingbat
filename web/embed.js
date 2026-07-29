// Keyboard-navigation escape hatch (same trick as index.js): the SDL runtime
// preventDefaults keydown app-wide once it initializes, which kills Tab and
// makes the whole embed keyboard-inoperable. This runs on window in the
// CAPTURE phase and embed.js executes before em.js, so it outranks SDL's key
// grab. Stopping propagation leaves the browser's default focus traversal
// intact. The embed binds nothing to Tab, so it is unconditional here.
window.addEventListener("keydown", (e) => {
  if (e.code === "Tab") e.stopImmediatePropagation();
}, true);

// --- Query parameters ---

const params = new URLSearchParams(window.location.search);
const integerScaling = params.get("integer-scaling") !== "false";
const demoMode = params.has("demo");

// --- Integer scaling toggle ---

const canvasEl = /** @type {HTMLCanvasElement} */ (document.getElementById("canvas"));
if (!integerScaling) {
  canvasEl.classList.add("fill");
}

// --- Emulator state ---

var volume = 0;
var paused = false;
var fastForward = false;
var currentRomName = null;
var currentOriginalName = null;

// --- WebGL2 game presentation ---
// SDL no longer paints the game (commit 4c4a3e9): the core hands us a raw
// BGR555 framebuffer and JS uploads it to a WebGL2 texture + shader. We own the
// visible #canvas; SDL was pointed at the hidden #sdl-canvas. Same presenter as
// the main page — see web/glpresent.js. The embed exposes no video toggles, so
// the uniforms are fixed at the defaults index.js ships with (LCD color
// correction on, no scanlines, no upscale filter).
const GL_SCALE = 4; // #canvas backing store = native resolution * GL_SCALE

const isGbc = () =>
  typeof Module !== "undefined" && Module._wasm_panel_gbc
    ? Module._wasm_panel_gbc() === 1
    : !!(currentRomName && currentRomName !== "rom.gba");

const nativeRes = () => (isGbc() ? [160, 144] : [240, 160]);

const glRenderer = createGlRenderer(canvasEl, nativeRes, (m) =>
  console.log(m)
);

// Pin the #canvas backing store to native * GL_SCALE. NEAREST sampling makes
// that a crisp integer upscale; CSS (embed.css) sizes the displayed element.
const resizeCanvas = () => {
  const [nw, nh] = nativeRes();
  const bw = nw * GL_SCALE,
    bh = nh * GL_SCALE;
  if (canvasEl.width !== bw) canvasEl.width = bw;
  if (canvasEl.height !== bh) canvasEl.height = bh;
};

const drawGame = () => {
  if (!currentRomName) return;
  glRenderer.draw({
    colorCorrect: true,
    panelGbc: isGbc(),
    scanlines: false,
    filter: "none",
  });
};

// --- FS helper ---

const writeToFS = (filename, bytes) => {
  let stream = FS.open(filename, "w+");
  FS.write(stream, bytes, 0, bytes.length, 0);
  FS.close(stream);
};

// --- ROM loading (drag-and-drop only) ---

const loadRom = (romName, originalName) => {
  currentRomName = romName;
  currentOriginalName = originalName || romName;
  paused = false;
  fastForward = false;
  updatePauseIcon();
  fastForwardButton.classList.remove("active");
  Module.ccall("initFromEmscripten", null, ["string"], [romName]);
  // Now that the core is up, wasm_panel_gbc() reports the right system: size the
  // backing store and present the first frame immediately.
  resizeCanvas();
  drawGame();
};

const handleRomFile = (file) => {
  let ext = file.name.substring(file.name.lastIndexOf(".")).toLowerCase();
  if (ext !== ".gba" && ext !== ".gb" && ext !== ".gbc") return;
  let romName = "rom" + ext;
  let reader = new FileReader();
  reader.addEventListener("load", () => {
    let bytes = new Uint8Array(/** @type {ArrayBuffer} */ (reader.result));
    writeToFS(romName, bytes);
    loadRom(romName, file.name);
  });
  reader.readAsArrayBuffer(file);
};

// --- Drop zone ---

const dropOverlay = document.getElementById("drop-overlay");
let dragCounter = 0;

document.addEventListener("dragenter", (e) => {
  e.preventDefault();
  dragCounter++;
  dropOverlay.classList.add("visible");
});

document.addEventListener("dragleave", (e) => {
  e.preventDefault();
  dragCounter--;
  if (dragCounter <= 0) {
    dragCounter = 0;
    dropOverlay.classList.remove("visible");
  }
});

document.addEventListener("dragover", (e) => {
  e.preventDefault();
});

document.addEventListener("drop", (e) => {
  e.preventDefault();
  dragCounter = 0;
  dropOverlay.classList.remove("visible");
  if (e.dataTransfer.files?.length > 0) handleRomFile(e.dataTransfer.files[0]);
});

// --- Playback controls ---

const pauseButton = document.getElementById("pause");
const resetButton = document.getElementById("reset");
const fastForwardButton = document.getElementById("fast-forward");
const iconPause = document.getElementById("icon-pause");
const iconPlay = document.getElementById("icon-play");
const overlay = document.getElementById("overlay");
let overlayTimer = null;

const updatePauseIcon = () => {
  iconPause.style.display = paused ? "none" : "";
  iconPlay.style.display = paused ? "" : "none";
  pauseButton.setAttribute("aria-label", paused ? "Play" : "Pause");
  pauseButton.title = paused ? "Play" : "Pause";
  // Pin the overlay open while paused so the user can see the play button
  overlay.classList.toggle("pinned", paused);
  // When unpausing on mobile, start auto-hide; when pausing, cancel timer
  if (paused) {
    clearTimeout(overlayTimer);
  } else if (overlay.classList.contains("visible")) {
    clearTimeout(overlayTimer);
    overlayTimer = setTimeout(() => overlay.classList.remove("visible"), 2000);
  }
};

pauseButton.addEventListener("click", () => {
  paused = !paused;
  updatePauseIcon();
});

resetButton.addEventListener("click", () => {
  if (currentRomName) loadRom(currentRomName, currentOriginalName);
});

fastForwardButton.addEventListener("click", () => {
  fastForward = !fastForward;
  fastForwardButton.classList.toggle("active", fastForward);
  fastForwardButton.setAttribute("aria-pressed", String(fastForward));
});

// --- Volume slider ---

const volTrack = document.getElementById("vol-track");
const volFill = document.getElementById("vol-fill");
const volKnob = document.getElementById("vol-knob");
const volIconBtn = document.getElementById("vol-icon");
const iconMuted = document.getElementById("icon-muted");
const iconVol = document.getElementById("icon-vol");

const updateVolumeUI = () => {
  let pct = volume + "%";
  volFill.style.width = pct;
  volKnob.style.left = pct;
  iconMuted.style.display = volume === 0 ? "" : "none";
  iconVol.style.display = volume === 0 ? "none" : "";
  // Keep the a11y state in sync for every input path (pointer, keyboard, mute)
  volTrack.setAttribute("aria-valuenow", String(volume));
  volIconBtn.setAttribute("aria-label", volume === 0 ? "Unmute" : "Mute");
  if (typeof updateGain === "function") updateGain();
};

// Single setter shared by the pointer, keyboard and mute paths
const setVolume = (v) => {
  volume = Math.round(Math.max(0, Math.min(100, v)));
  updateVolumeUI();
};

const setVolumeFromTrack = (clientX) => {
  let rect = volTrack.getBoundingClientRect();
  let ratio = (clientX - rect.left) / rect.width;
  setVolume(ratio * 100);
};

// Click on track to jump
volTrack.addEventListener("mousedown", (e) => {
  setVolumeFromTrack(e.clientX);
  const onMove = (ev) => setVolumeFromTrack(ev.clientX);
  const onUp = () => {
    document.removeEventListener("mousemove", onMove);
    document.removeEventListener("mouseup", onUp);
  };
  document.addEventListener("mousemove", onMove);
  document.addEventListener("mouseup", onUp);
});

// Touch support for volume slider
volTrack.addEventListener("touchstart", (e) => {
  e.preventDefault();
  setVolumeFromTrack(e.touches[0].clientX);
});
volTrack.addEventListener("touchmove", (e) => {
  e.preventDefault();
  setVolumeFromTrack(e.touches[0].clientX);
});

// Keyboard support: the track is a role="slider" div (tabindex in embed.html).
// Window CAPTURE phase, like the Tab hatch at the top of this file: while the
// slider is focused the arrows must adjust volume, not reach the SDL runtime
// as game input, and this listener is registered before em.js loads.
window.addEventListener("keydown", (e) => {
  if (document.activeElement !== volTrack) return;
  let v;
  switch (e.key) {
    case "ArrowLeft":
    case "ArrowDown":
      v = volume - 5;
      break;
    case "ArrowRight":
    case "ArrowUp":
      v = volume + 5;
      break;
    case "Home":
      v = 0;
      break;
    case "End":
      v = 100;
      break;
    default:
      return;
  }
  e.preventDefault();
  e.stopImmediatePropagation();
  setVolume(v);
}, true);

// Toggle mute via icon
let volumeBeforeMute = 50;
volIconBtn.addEventListener("click", () => {
  if (volume > 0) {
    volumeBeforeMute = volume;
    setVolume(0);
  } else {
    setVolume(volumeBeforeMute);
  }
});

// Initialize volume UI
updateVolumeUI();

// --- Touch overlay (YouTube-style show/hide) ---

const wrapper = document.getElementById("wrapper");

const showOverlay = () => {
  overlay.classList.add("visible");
  clearTimeout(overlayTimer);
  if (!paused) {
    overlayTimer = setTimeout(() => overlay.classList.remove("visible"), 2000);
  }
};

const hideOverlay = () => {
  clearTimeout(overlayTimer);
  overlay.classList.remove("visible");
};

// Tapping the canvas shows the overlay
wrapper.addEventListener("touchstart", (e) => {
  if (e.target === document.getElementById("canvas")) {
    showOverlay();
  }
}, { passive: true });

// Tapping empty space in the overlay dismisses it
overlay.addEventListener("touchstart", (e) => {
  if (e.target === overlay || e.target === document.getElementById("controls") || e.target === document.getElementById("volume")) {
    e.preventDefault();
    hideOverlay();
  }
});

// Reset the auto-hide timer when interacting with controls
const resetOverlayTimer = () => {
  if (overlay.classList.contains("visible") && !paused) {
    clearTimeout(overlayTimer);
    overlayTimer = setTimeout(() => overlay.classList.remove("visible"), 2000);
  }
};

[pauseButton, resetButton, fastForwardButton, volIconBtn, volTrack].forEach(
  (el) => el.addEventListener("touchstart", resetOverlayTimer, { passive: true })
);

// --- Emscripten Module ---

/** @type {EmscriptenModule} */
var Module = {
  // SDL renders into this hidden canvas; the visible #canvas is ours (WebGL2).
  canvas: /** @type {HTMLCanvasElement} */ ((() => document.getElementById("sdl-canvas"))()),
  onRuntimeInitialized: () => {
    const SAMPLE_RATE = 32768;
    const TARGET_FPS = 59.7275;
    const FRAME_TIME = 1000.0 / TARGET_FPS;
    let lastFrameTime = 0;
    let accumulator = 0;
    let frameCount = 0;

    // --- Web Audio ---
    let audioCtx = null;
    let gainNode = null;
    let playTime = 0;

    const initAudio = () => {
      if (audioCtx) return;
      if (navigator.audioSession) {
        navigator.audioSession.type = "playback";
      }
      audioCtx = new AudioContext({ sampleRate: SAMPLE_RATE });
      gainNode = audioCtx.createGain();
      gainNode.gain.value = volume / 100;
      gainNode.connect(audioCtx.destination);
      playTime = 0;
    };

    window.updateGain = () => {
      if (gainNode) gainNode.gain.value = volume / 100;
    };

    let audioUnlocked = false;
    const resumeAudio = () => {
      initAudio();
      // Not just "suspended": iOS Safari parks the context in a non-standard
      // "interrupted" state after phone calls / Siri, which also needs an
      // explicit resume(). Attempt it for any non-running state.
      if (audioCtx.state !== "running") audioCtx.resume().catch(() => {});
      if (!audioUnlocked) {
        audioUnlocked = true;
        let silentBuf = audioCtx.createBuffer(1, 1, SAMPLE_RATE);
        let src = audioCtx.createBufferSource();
        src.buffer = silentBuf;
        src.connect(audioCtx.destination);
        src.start(0);
        let a = new Audio("data:audio/wav;base64,UklGRiYAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQIAAAAAAA==");
        a.play().catch(() => {});
      }
    };
    document.addEventListener("click", resumeAudio, { once: false });
    document.addEventListener("keydown", resumeAudio, { once: false });
    document.addEventListener("touchstart", resumeAudio, { once: false });

    const MAX_AUDIO_LEAD = 0.04; // max seconds audio can be scheduled ahead

    const pushAudio = () => {
      if (!audioCtx || audioCtx.state !== "running") {
        // Audio is locked (no user gesture yet) or suspended: discard the
        // samples from this tick. Letting them accumulate grows WASM-side
        // memory without bound, and the first unlock would schedule the
        // whole stale backlog, leaving audio permanently behind the video.
        if (typeof Module !== "undefined" && Module._clearAudioBuffer) {
          Module._clearAudioBuffer();
        }
        return;
      }
      const len = Module._getAudioBufferLen();
      if (len === 0) return;
      const ptr = Module._getAudioBufferPtr();
      if (!ptr) return;
      const now = audioCtx.currentTime;
      if (playTime < now) playTime = now;
      // Drop audio if we've scheduled too far ahead (e.g. RAF throttled in iframe)
      if (playTime - now > MAX_AUDIO_LEAD) {
        Module._clearAudioBuffer();
        return;
      }
      const stereoSamples = len;
      const frames = stereoSamples / 2;
      const buffer = audioCtx.createBuffer(2, frames, SAMPLE_RATE);
      const left = buffer.getChannelData(0);
      const right = buffer.getChannelData(1);
      const heap = new Float32Array(Module.memory.buffer, ptr, stereoSamples);
      for (let i = 0; i < frames; i++) {
        left[i] = heap[i * 2];
        right[i] = heap[i * 2 + 1];
      }
      Module._clearAudioBuffer();
      const source = audioCtx.createBufferSource();
      source.buffer = buffer;
      source.connect(gainNode);
      source.start(playTime);
      playTime += buffer.duration;
    };

    // --- Demo ROM auto-load ---
    if (demoMode) {
      fetch("goodboy-demo-en.gba")
        .then((res) => {
          if (!res.ok) throw new Error("Failed to fetch demo ROM");
          return res.arrayBuffer();
        })
        .then((buf) => {
          let bytes = new Uint8Array(buf);
          writeToFS("rom.gba", bytes);
          loadRom("rom.gba", "goodboy-demo-en.gba");
        })
        .catch((err) => console.error("Demo ROM load failed:", err));
    }

    // --- Game loop ---
    const tick = (timestamp) => {
      if (paused) {
        lastFrameTime = 0;
        accumulator = 0;
        requestAnimationFrame(tick);
        return;
      }
      if (lastFrameTime === 0) lastFrameTime = timestamp;
      accumulator += timestamp - lastFrameTime;
      lastFrameTime = timestamp;
      if (fastForward) {
        if (audioCtx) playTime = audioCtx.currentTime;
        const budget = 16;
        const start = performance.now();
        while (performance.now() - start < budget) {
          Module._loop_tick();
          pushAudio();
          frameCount++;
        }
        accumulator = 0;
      } else {
        let framesRun = 0;
        while (accumulator >= FRAME_TIME && framesRun < 2) {
          Module._loop_tick();
          pushAudio();
          frameCount++;
          accumulator -= FRAME_TIME;
          framesRun++;
        }
        if (accumulator > FRAME_TIME * 2) accumulator = 0;
      }
      // Present once per RAF (SDL no longer paints — see the WebGL2 section
      // above). Paused returns early, so the last frame stays on the canvas.
      drawGame();
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  },
};
