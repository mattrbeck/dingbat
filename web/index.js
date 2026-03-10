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

// --- BIOS/Bootrom storage helpers ---

const writeToFS = (filename, bytes) => {
  let stream = FS.open(filename, "w+");
  FS.write(stream, bytes, 0, bytes.length, 0);
  FS.close(stream);
};

const saveToStorage = (key, bytes) => {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  localStorage.setItem(key, btoa(binary));
};

const loadFromStorage = (key, filename) => {
  let data = localStorage.getItem(key);
  if (!data) return false;
  let binary = atob(data);
  let bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  writeToFS(filename, bytes);
  return true;
};

const loadBiosFromStorage = () => {
  loadFromStorage("crab_bios", "bios.bin");
  loadFromStorage("crab_gbc_bootrom", "bootrom.bin");
};

// --- Menu ---

const menuBtn = document.getElementById("menu-btn");
const menuDropdown = document.getElementById("menu-dropdown");

menuBtn.addEventListener("click", (e) => {
  e.stopPropagation();
  menuDropdown.hidden = !menuDropdown.hidden;
});

document.addEventListener("click", () => {
  menuDropdown.hidden = true;
});

// --- BIOS Modal ---

const biosModal = document.getElementById("bios-modal");
const gbaBiosStatus = document.getElementById("gba-bios-status");
const gbcBootromStatus = document.getElementById("gbc-bootrom-status");

// Pending state: { bytes, name } for a new pick, "remove" for removal, or null for no change
let pendingGbaBios = null;
let pendingGbcBootrom = null;

const getStoredBiosName = (key) => localStorage.getItem(key + "_name") || null;

const updateBiosStatusText = () => {
  if (pendingGbaBios === "remove") {
    gbaBiosStatus.textContent = "Default (pending)";
  } else if (pendingGbaBios) {
    gbaBiosStatus.textContent = pendingGbaBios.name + " (pending)";
  } else {
    let name = getStoredBiosName("crab_bios");
    gbaBiosStatus.textContent = name || (localStorage.getItem("crab_bios") ? "Set" : "Not set");
  }

  if (pendingGbcBootrom === "remove") {
    gbcBootromStatus.textContent = "None (pending)";
  } else if (pendingGbcBootrom) {
    gbcBootromStatus.textContent = pendingGbcBootrom.name + " (pending)";
  } else {
    let name = getStoredBiosName("crab_gbc_bootrom");
    gbcBootromStatus.textContent = name || (localStorage.getItem("crab_gbc_bootrom") ? "Set" : "Not set");
  }
};

const pickFile = (accept, callback) => {
  let input = document.createElement("input");
  input.type = "file";
  input.accept = accept;
  input.addEventListener("input", () => {
    if (input.files?.length > 0) {
      let file = input.files[0];
      let reader = new FileReader();
      reader.addEventListener("load", () => callback(new Uint8Array(reader.result), file.name));
      reader.readAsArrayBuffer(file);
    }
  });
  input.click();
};

document.getElementById("open-bios").addEventListener("click", () => {
  menuDropdown.hidden = true;
  pendingGbaBios = null;
  pendingGbcBootrom = null;
  updateBiosStatusText();
  biosModal.classList.add("open");
});

document.getElementById("pick-gba-bios").addEventListener("click", () => {
  pickFile(".bin", (bytes, name) => {
    pendingGbaBios = { bytes, name };
    updateBiosStatusText();
  });
});

document.getElementById("pick-gbc-bootrom").addEventListener("click", () => {
  pickFile(".bin", (bytes, name) => {
    pendingGbcBootrom = { bytes, name };
    updateBiosStatusText();
  });
});

document.getElementById("remove-gba-bios").addEventListener("click", () => {
  pendingGbaBios = "remove";
  updateBiosStatusText();
});

document.getElementById("remove-gbc-bootrom").addEventListener("click", () => {
  pendingGbcBootrom = "remove";
  updateBiosStatusText();
});

const closeBiosModal = () => {
  pendingGbaBios = null;
  pendingGbcBootrom = null;
  biosModal.classList.remove("open");
};

document.getElementById("bios-save").addEventListener("click", () => {
  if (pendingGbaBios === "remove") {
    localStorage.removeItem("crab_bios");
    localStorage.removeItem("crab_bios_name");
    try { FS.unlink("bios.bin"); } catch {}
  } else if (pendingGbaBios) {
    writeToFS("bios.bin", pendingGbaBios.bytes);
    saveToStorage("crab_bios", pendingGbaBios.bytes);
    localStorage.setItem("crab_bios_name", pendingGbaBios.name);
  }
  if (pendingGbcBootrom === "remove") {
    localStorage.removeItem("crab_gbc_bootrom");
    localStorage.removeItem("crab_gbc_bootrom_name");
    try { FS.unlink("bootrom.bin"); } catch {}
  } else if (pendingGbcBootrom) {
    writeToFS("bootrom.bin", pendingGbcBootrom.bytes);
    saveToStorage("crab_gbc_bootrom", pendingGbcBootrom.bytes);
    localStorage.setItem("crab_gbc_bootrom_name", pendingGbcBootrom.name);
  }
  closeBiosModal();
});

document.getElementById("bios-cancel").addEventListener("click", closeBiosModal);

biosModal.addEventListener("click", (e) => {
  if (e.target === biosModal) closeBiosModal();
});

// --- Recent ROMs ---

const RECENT_KEY = "crab_recent_roms";
const MAX_RECENT = 20;

const getRecentRoms = () => {
  try { return JSON.parse(localStorage.getItem(RECENT_KEY)) || []; }
  catch { return []; }
};

const saveRecentRoms = (list) => {
  localStorage.setItem(RECENT_KEY, JSON.stringify(list));
};

const addRecentRom = (name, bytes) => {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  let encoded = btoa(binary);
  let list = getRecentRoms().filter(r => r.name !== name);
  list.unshift({ name, data: encoded });
  if (list.length > MAX_RECENT) list.length = MAX_RECENT;
  saveRecentRoms(list);
};

const recentModal = document.getElementById("recent-modal");
const recentList = document.getElementById("recent-list");

const renderRecentList = () => {
  recentList.innerHTML = "";
  let roms = getRecentRoms();
  for (let rom of roms) {
    let entry = document.createElement("div");
    entry.className = "recent-entry";
    let nameSpan = document.createElement("span");
    nameSpan.className = "recent-entry-name";
    nameSpan.textContent = rom.name;
    nameSpan.addEventListener("click", () => {
      let binary = atob(rom.data);
      let bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      let ext = rom.name.substring(rom.name.lastIndexOf(".")).toLowerCase();
      let romFile = "rom" + ext;
      writeToFS(romFile, bytes);
      recentModal.classList.remove("open");
      loadRom(romFile, rom.name);
    });
    let delBtn = document.createElement("button");
    delBtn.className = "recent-delete";
    delBtn.innerHTML = "&#x1f5d1;";
    delBtn.title = "Remove";
    delBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      let list = getRecentRoms().filter(r => r.name !== rom.name);
      saveRecentRoms(list);
      renderRecentList();
    });
    entry.appendChild(nameSpan);
    entry.appendChild(delBtn);
    recentList.appendChild(entry);
  }
};

document.getElementById("open-recent").addEventListener("click", () => {
  menuDropdown.hidden = true;
  renderRecentList();
  recentModal.classList.add("open");
});

const closeRecentModal = () => {
  recentModal.classList.remove("open");
};

document.getElementById("recent-close").addEventListener("click", closeRecentModal);

recentModal.addEventListener("click", (e) => {
  if (e.target === recentModal) closeRecentModal();
});

// Close any open modal on Escape
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    closeBiosModal();
    closeRecentModal();
  }
});

// --- Save state persistence ---

const SAVES_KEY = "crab_saves";

const getSaves = () => {
  try { return JSON.parse(localStorage.getItem(SAVES_KEY)) || {}; }
  catch { return {}; }
};

const saveSavesToStorage = (saves) => {
  localStorage.setItem(SAVES_KEY, JSON.stringify(saves));
};

const persistSave = (romName, originalName) => {
  let savName = romName.substring(0, romName.lastIndexOf(".")) + ".sav";
  try {
    let data = FS.readFile(savName);
    if (data && data.length > 0) {
      let binary = "";
      for (let i = 0; i < data.length; i++) binary += String.fromCharCode(data[i]);
      let saves = getSaves();
      saves[originalName] = btoa(binary);
      saveSavesToStorage(saves);
    }
  } catch {}
};

const restoreSave = (romName, originalName) => {
  let saves = getSaves();
  let encoded = saves[originalName];
  if (!encoded) return;
  let savName = romName.substring(0, romName.lastIndexOf(".")) + ".sav";
  let binary = atob(encoded);
  let bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  writeToFS(savName, bytes);
};

var currentRomName = null;
var currentOriginalName = null;
var paused = false;
var fastForward = false;

const pauseButton = document.getElementById("pause");
const resetButton = document.getElementById("reset");
const fastForwardButton = document.getElementById("fast-forward");
const playbackControls = document.getElementById("playback-controls");

const loadRom = (romName, originalName) => {
  // Persist save from previous ROM before switching
  if (currentRomName && currentOriginalName) {
    persistSave(currentRomName, currentOriginalName);
  }
  currentRomName = romName;
  currentOriginalName = originalName || romName;
  paused = false;
  fastForward = false;
  pauseButton.textContent = "\u23f8";
  pauseButton.classList.remove("active");
  fastForwardButton.classList.remove("active");
  playbackControls.hidden = false;
  // Restore save for the new ROM
  restoreSave(romName, currentOriginalName);
  Module.ccall("initFromEmscripten", null, ["string"], [romName]);
};

document.getElementById("open-rom").addEventListener("click", () => {
  menuDropdown.hidden = true;
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
        writeToFS(romName, bytes);
        addRecentRom(file.name, bytes);
        loadRom(romName, file.name);
      });
      reader.readAsArrayBuffer(file);
    }
  });
  input.click();
});

pauseButton.addEventListener("click", () => {
  paused = !paused;
  pauseButton.textContent = paused ? "\u25b6" : "\u23f8";
  pauseButton.classList.toggle("active", paused);
});

resetButton.addEventListener("click", () => {
  if (currentRomName) loadRom(currentRomName, currentOriginalName);
});

fastForwardButton.addEventListener("click", () => {
  fastForward = !fastForward;
  fastForwardButton.classList.toggle("active", fastForward);
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

    // Persist save data to localStorage every 5 seconds
    setInterval(() => {
      if (currentRomName && currentOriginalName) {
        persistSave(currentRomName, currentOriginalName);
      }
    }, 5000);

    // Also persist on page unload
    window.addEventListener("beforeunload", () => {
      if (currentRomName && currentOriginalName) {
        persistSave(currentRomName, currentOriginalName);
      }
    });

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
        // Run as many frames as possible within ~16ms budget
        const budget = 16;
        const start = performance.now();
        while (performance.now() - start < budget) {
          Module._loop_tick();
          Module._clearAudioBuffer();
          frameCount++;
        }
        accumulator = 0;
      } else {
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
      }
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
