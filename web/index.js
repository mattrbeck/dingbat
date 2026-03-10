const showLogButton = document.getElementById("show-log");
const logDiv = document.getElementById("log");
logDiv.hidden = true;
showLogButton.addEventListener("click", () => {
  logDiv.hidden = !logDiv.hidden;
  logDiv.scroll({ top: logDiv.scrollHeight });
});
const log = (message) => {
  let shouldScroll =
    logDiv.scrollTop === logDiv.scrollHeight - logDiv.offsetHeight;
  logDiv.innerHTML += `<p>${message}</p>`;
  if (shouldScroll) logDiv.scroll({ top: logDiv.scrollHeight });
};

const writeBiosToFS = (bytes) => {
  let stream = FS.open("bios.bin", "w+");
  FS.write(stream, bytes, 0, bytes.length, 0);
  FS.close(stream);
};

const saveBiosToStorage = (bytes) => {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  localStorage.setItem("crab_bios", btoa(binary));
};

const loadBiosFromStorage = () => {
  let data = localStorage.getItem("crab_bios");
  if (!data) return false;
  let binary = atob(data);
  let bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  writeBiosToFS(bytes);
  return true;
};

document.getElementById("open-bios").addEventListener("click", () => {
  let input = document.createElement("input");
  input.type = "file";
  input.accept = ".bin";
  input.addEventListener("input", () => {
    if (input.files?.length > 0) {
      let reader = new FileReader();
      reader.addEventListener("load", () => {
        let bytes = new Uint8Array(reader.result);
        writeBiosToFS(bytes);
        saveBiosToStorage(bytes);
      });
      reader.readAsArrayBuffer(input.files[0]);
    }
  });
  input.click();
});

var currentRomName = null;
var paused = false;

const pauseButton = document.getElementById("pause");
const resetButton = document.getElementById("reset");

const loadRom = (romName) => {
  currentRomName = romName;
  paused = false;
  pauseButton.textContent = "Pause";
  pauseButton.hidden = false;
  resetButton.hidden = false;
  Module.ccall("initFromEmscripten", null, ["string"], [romName]);
};

document.getElementById("open-rom").addEventListener("click", () => {
  let input = document.createElement("input");
  input.type = "file";
  input.accept = ".gba,.gb,.gbc";
  input.addEventListener("input", () => {
    if (input.files?.length > 0) {
      let file = input.files[0];
      let ext = file.name.substring(file.name.lastIndexOf(".")).toLowerCase();
      let romName = "rom" + ext;
      let reader = new FileReader();
      reader.addEventListener("load", () => {
        let bytes = new Uint8Array(reader.result);
        let stream = FS.open(romName, "w+");
        FS.write(stream, bytes, 0, bytes.length, 0);
        FS.close(stream);
        loadRom(romName);
      });
      reader.readAsArrayBuffer(file);
    }
  });
  input.click();
});

pauseButton.addEventListener("click", () => {
  paused = !paused;
  pauseButton.textContent = paused ? "Resume" : "Pause";
});

resetButton.addEventListener("click", () => {
  if (currentRomName) loadRom(currentRomName);
});

var Module = {
  canvas: (() => document.getElementById("canvas"))(),
  onRuntimeInitialized: () => {
    loadBiosFromStorage();
    let frameCount = 0;
    const SAMPLE_RATE = 32768; // GBA/GB native sample rate
    const TARGET_FPS = 59.7275;
    const FRAME_TIME = 1000.0 / TARGET_FPS;
    let lastFrameTime = 0;
    let accumulator = 0;

    // Web Audio API push-based playback (binjgb approach).
    // Audio samples are produced by the emulator at SAMPLE_RATE and scheduled
    // for playback at precise times. The browser handles resampling to the
    // output device rate natively, so no custom resampler is needed.
    let audioCtx = null;
    let playTime = 0;

    const initAudio = () => {
      if (audioCtx) return;
      audioCtx = new AudioContext({ sampleRate: SAMPLE_RATE });
      playTime = 0;
    };

    // Resume audio context on first user interaction (browser autoplay policy)
    const resumeAudio = () => {
      initAudio();
      if (audioCtx.state === "suspended") audioCtx.resume();
    };
    document.addEventListener("click", resumeAudio, { once: false });
    document.addEventListener("keydown", resumeAudio, { once: false });

    const pushAudio = () => {
      if (!audioCtx || audioCtx.state !== "running") return;
      const len = Module._getAudioBufferLen();
      if (len === 0) return;
      const ptr = Module._getAudioBufferPtr();
      if (!ptr) return;
      const stereoSamples = len; // total float32 values (L,R,L,R,...)
      const frames = stereoSamples / 2;
      const buffer = audioCtx.createBuffer(2, frames, SAMPLE_RATE);
      const left = buffer.getChannelData(0);
      const right = buffer.getChannelData(1);
      // Read interleaved float32 samples directly from WASM memory
      const heap = new Float32Array(Module.memory.buffer, ptr, stereoSamples);
      for (let i = 0; i < frames; i++) {
        left[i] = heap[i * 2];
        right[i] = heap[i * 2 + 1];
      }
      Module._clearAudioBuffer();
      // Schedule playback at the correct time
      const now = audioCtx.currentTime;
      if (playTime < now) playTime = now;
      const source = audioCtx.createBufferSource();
      source.buffer = buffer;
      source.connect(audioCtx.destination);
      source.start(playTime);
      playTime += buffer.duration;
    };

    setInterval(() => {
      document.getElementById("fps").textContent = frameCount + " fps";
      frameCount = 0;
    }, 1000);

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
      // Run as many frames as needed to catch up, capped to avoid spiral
      let framesRun = 0;
      while (accumulator >= FRAME_TIME && framesRun < 2) {
        Module._loop_tick();
        pushAudio();
        frameCount++;
        accumulator -= FRAME_TIME;
        framesRun++;
      }
      // Prevent accumulator from growing unbounded if tab was backgrounded
      if (accumulator > FRAME_TIME * 2) accumulator = 0;
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  },
};

const getInputs = (element) =>
  element?.getAttribute("data-inputs")?.split(" ").map(Number) ?? [];

const setInputs = (inputs, down) => {
  for (let id of inputs) Module._setInput(id, down ? 1 : 0);
};

var currentDpadTouchId = null;
var currentDpadElement = null;

const getTouch = (touchList, touchId) => {
  for (let touch of touchList) {
    if (touch.identifier == touchId) {
      return touch;
    }
  }
};

const dpadTouchStart = (event) => {
  event.preventDefault();
  let element = event.target;
  if (currentDpadTouchId == null) {
    currentDpadTouchId = event.targetTouches[0].identifier;
    if (element.hasAttribute("data-inputs")) {
      currentDpadElement = element;
      setInputs(getInputs(element), true);
    }
  }
};

const dpadTouchMove = (event) => {
  event.preventDefault();
  if (currentDpadTouchId == null) return;
  let touch = getTouch(event.targetTouches, currentDpadTouchId);
  if (touch != null) {
    let element = document.elementFromPoint(touch.clientX, touch.clientY);
    if (element == currentDpadElement) return;
    if (element == null) return;
    let oldInputs = getInputs(currentDpadElement);
    if (element.hasAttribute("data-inputs")) {
      let newInputs = getInputs(element);
      for (let id of oldInputs) {
        if (newInputs.includes(id)) continue;
        Module._setInput(id, 0);
      }
      for (let id of newInputs) {
        if (oldInputs.includes(id)) continue;
        Module._setInput(id, 1);
      }
      currentDpadElement = element;
    } else {
      setInputs(oldInputs, false);
      currentDpadElement = null;
    }
  }
};

const dpadTouchEnd = (event) => {
  let touch = getTouch(event.changedTouches, currentDpadTouchId);
  if (touch != null) {
    setInputs(getInputs(currentDpadElement), false);
    currentDpadTouchId = null;
    currentDpadElement = null;
  }
};

document.getElementById("dpad").addEventListener("touchstart", dpadTouchStart);
document.getElementById("dpad").addEventListener("touchmove", dpadTouchMove);
document.getElementById("dpad").addEventListener("touchend", dpadTouchEnd);
document.getElementById("dpad").addEventListener("touchcancel", dpadTouchEnd);

document.querySelectorAll("[data-inputs]").forEach((element) => {
  element.addEventListener("touchstart", (event) => {
    event.preventDefault();
    setInputs(getInputs(element), true);
  });
  element.addEventListener("touchend", (event) => {
    setInputs(getInputs(element), false);
  });
});
