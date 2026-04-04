// --- Query parameters ---

const params = new URLSearchParams(window.location.search);
const integerScaling = params.get("integer-scaling") !== "false";
const demoMode = params.has("demo");

// --- Integer scaling toggle ---

if (!integerScaling) {
  const canvas = document.getElementById("canvas");
  canvas.classList.add("fill");
}

// --- Emulator state ---

var volume = 0;
var paused = false;
var fastForward = false;
var currentRomName = null;
var currentOriginalName = null;

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
};

const handleRomFile = (file) => {
  let ext = file.name.substring(file.name.lastIndexOf(".")).toLowerCase();
  if (ext !== ".gba" && ext !== ".gb" && ext !== ".gbc") return;
  let romName = "rom" + ext;
  let reader = new FileReader();
  reader.addEventListener("load", () => {
    let bytes = new Uint8Array(reader.result);
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
  if (typeof updateGain === "function") updateGain();
};

const setVolumeFromTrack = (clientX) => {
  let rect = volTrack.getBoundingClientRect();
  let ratio = (clientX - rect.left) / rect.width;
  volume = Math.round(Math.max(0, Math.min(1, ratio)) * 100);
  updateVolumeUI();
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

// Toggle mute via icon
let volumeBeforeMute = 50;
volIconBtn.addEventListener("click", () => {
  if (volume > 0) {
    volumeBeforeMute = volume;
    volume = 0;
  } else {
    volume = volumeBeforeMute;
  }
  updateVolumeUI();
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

var Module = {
  canvas: (() => document.getElementById("canvas"))(),
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
      if (audioCtx.state === "suspended") audioCtx.resume();
      if (!audioUnlocked) {
        audioUnlocked = true;
        let silentBuf = audioCtx.createBuffer(1, 1, SAMPLE_RATE);
        let src = audioCtx.createBufferSource();
        src.buffer = silentBuf;
        src.connect(audioCtx.destination);
        src.start(0);
      }
    };
    document.addEventListener("click", resumeAudio, { once: false });
    document.addEventListener("keydown", resumeAudio, { once: false });

    const MAX_AUDIO_LEAD = 0.04; // max seconds audio can be scheduled ahead

    const pushAudio = () => {
      if (!audioCtx || audioCtx.state !== "running") return;
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
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  },
};
