// Tab escape hatch: the SDL runtime preventDefaults keydown app-wide once
// it initializes. Window capture phase, registered before em.js, so it runs
// first; stopping propagation leaves the browser's focus traversal intact.
window.addEventListener("keydown", (e) => {
  if (e.code === "Tab") e.stopImmediatePropagation();
}, true);

const params = new URLSearchParams(window.location.search);
const integerScaling = params.get("integer-scaling") !== "false";
const demoMode = params.has("demo");

const canvasEl = /** @type {HTMLCanvasElement} */ (document.getElementById("canvas"));
if (!integerScaling) {
  canvasEl.classList.add("fill");
}

var volume = 0;
var paused = false;
var fastForward = false;
var currentRomName = null;
var currentOriginalName = null;

// Presentation: the core hands over a raw BGR555 framebuffer and JS uploads
// it to WebGL2 (web/glpresent.js) on the visible #canvas; SDL paints the
// hidden #sdl-canvas. No video toggles here, so uniforms are index.js's
// defaults (LCD color correction on, no screen look, no filter).
const GL_SCALE = 4; // #canvas backing store = native resolution * GL_SCALE

const isGbc = () =>
  typeof Module !== "undefined" && Module._wasm_panel_gbc
    ? Module._wasm_panel_gbc() === 1
    : !!(currentRomName && currentRomName !== "rom.gba");

// Native picture size. The core is authoritative (an SGB border makes it
// 256x224); the panel check covers the frame before the core exists.
const nativeRes = () => {
  if (typeof Module !== "undefined" && Module._wasm_out_w && currentRomName) {
    const w = Module._wasm_out_w(), h = Module._wasm_out_h();
    if (w > 0 && h > 0) return [w, h];
  }
  return isGbc() ? [160, 144] : [240, 160];
};

const glRenderer = createGlRenderer(canvasEl, nativeRes, (m) =>
  console.log(m)
);

// Backing store = native * GL_SCALE (NEAREST sampling gives a crisp integer
// upscale); embed.css sizes the displayed element.
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
    grid: false,
    filter: "none",
  });
};

const writeToFS = (filename, bytes) => {
  let stream = FS.open(filename, "w+");
  FS.write(stream, bytes, 0, bytes.length, 0);
  FS.close(stream);
};

const loadRom = (romName, originalName) => {
  currentRomName = romName;
  currentOriginalName = originalName || romName;
  paused = false;
  fastForward = false;
  updatePauseIcon();
  fastForwardButton.classList.remove("active");
  Module.ccall("initFromEmscripten", null, ["string"], [romName]);
  // The core is up, so nativeRes() is right: size and present immediately.
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
  overlay.classList.toggle("pinned", paused);
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
  volTrack.setAttribute("aria-valuenow", String(volume));
  volIconBtn.setAttribute("aria-label", volume === 0 ? "Unmute" : "Mute");
  if (typeof updateGain === "function") updateGain();
};

const setVolume = (v) => {
  volume = Math.round(Math.max(0, Math.min(100, v)));
  updateVolumeUI();
};

const setVolumeFromTrack = (clientX) => {
  let rect = volTrack.getBoundingClientRect();
  let ratio = (clientX - rect.left) / rect.width;
  setVolume(ratio * 100);
};

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

volTrack.addEventListener("touchstart", (e) => {
  e.preventDefault();
  setVolumeFromTrack(e.touches[0].clientX);
});
volTrack.addEventListener("touchmove", (e) => {
  e.preventDefault();
  setVolumeFromTrack(e.touches[0].clientX);
});

// Slider keys: window capture, registered before em.js, so arrows adjust
// volume instead of reaching the SDL runtime as game input.
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

let volumeBeforeMute = 50;
volIconBtn.addEventListener("click", () => {
  if (volume > 0) {
    volumeBeforeMute = volume;
    setVolume(0);
  } else {
    setVolume(volumeBeforeMute);
  }
});

updateVolumeUI();

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

wrapper.addEventListener("touchstart", (e) => {
  if (e.target === document.getElementById("canvas")) {
    showOverlay();
  }
}, { passive: true });

overlay.addEventListener("touchstart", (e) => {
  if (e.target === overlay || e.target === document.getElementById("controls") || e.target === document.getElementById("volume")) {
    e.preventDefault();
    hideOverlay();
  }
});

const resetOverlayTimer = () => {
  if (overlay.classList.contains("visible") && !paused) {
    clearTimeout(overlayTimer);
    overlayTimer = setTimeout(() => overlay.classList.remove("visible"), 2000);
  }
};

[pauseButton, resetButton, fastForwardButton, volIconBtn, volTrack].forEach(
  (el) => el.addEventListener("touchstart", resetOverlayTimer, { passive: true })
);

/** @type {EmscriptenModule} */
var Module = {
  canvas: /** @type {HTMLCanvasElement} */ ((() => document.getElementById("sdl-canvas"))()),
  onRuntimeInitialized: () => {
    const SAMPLE_RATE = 32768;
    const TARGET_FPS = 59.7275;
    const FRAME_TIME = 1000.0 / TARGET_FPS;
    let lastFrameTime = 0;
    let accumulator = 0;
    let frameCount = 0;

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
      // iOS Safari parks the context in a non-standard "interrupted" state
      // after calls / Siri; resume() for any non-running state.
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
    // Lead servo, as in index.js pushAudio: a floor restored after a hitch
    // spends the cushion, and a target the ±0.4% playback-rate servo holds
    // the lead near (pitch-inaudible).
    const AUDIO_LEAD_FLOOR = 0.008;
    const AUDIO_TARGET_LEAD = 0.020;

    const pushAudio = () => {
      if (!audioCtx || audioCtx.state !== "running") {
        // Locked or suspended: discard this tick's samples, else the first
        // unlock schedules the whole stale backlog behind the video.
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
      if (playTime < now + AUDIO_LEAD_FLOOR) playTime = now + AUDIO_LEAD_FLOOR;
      // Too far ahead (e.g. rAF throttled in an iframe): drop.
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
      const excess = playTime - now - AUDIO_TARGET_LEAD;
      const rate = 1 + Math.max(-0.004, Math.min(0.004, excess * 0.15));
      source.playbackRate.value = rate;
      source.start(playTime);
      playTime += buffer.duration / rate;
    };

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
        // Keep bounded debt: zeroing it deletes the missed frames' audio
        // (a click at every big hitch).
        if (accumulator > FRAME_TIME * 2) accumulator = FRAME_TIME * 2;
      }
      // Present once per rAF; paused returns early, keeping the last frame.
      drawGame();
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  },
};
