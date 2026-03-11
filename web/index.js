// --- Service Worker ---

let swRegistration = null;

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js").then((reg) => {
    swRegistration = reg;
  });
  // Reload when a new service worker takes over
  let refreshing = false;
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if (!refreshing) {
      refreshing = true;
      location.reload();
    }
  });
}

document.getElementById("check-update").addEventListener("click", async () => {
  document.getElementById("menu-dropdown").hidden = true;
  if (!swRegistration) {
    alert("Service worker not available.");
    return;
  }
  try {
    await swRegistration.update();
    let waiting = swRegistration.waiting;
    if (waiting) {
      // A new version is installed and waiting — activate it
      waiting.postMessage({ type: "skipWaiting" });
    } else if (!swRegistration.installing) {
      alert("Already up to date.");
    }
    // If installing, the controllerchange listener will reload automatically
  } catch (e) {
    alert("Update check failed: " + e.message);
  }
});

document.getElementById("force-update").addEventListener("click", async () => {
  document.getElementById("menu-dropdown").hidden = true;
  if (!confirm("This will clear all cached assets and reload. Continue?")) return;
  try {
    // Delete all service worker caches
    let keys = await caches.keys();
    await Promise.all(keys.map((key) => caches.delete(key)));
    // Unregister the service worker so it re-fetches everything
    if (swRegistration) await swRegistration.unregister();
    location.reload();
  } catch (e) {
    alert("Force update failed: " + e.message);
  }
});

const showLogButton = document.getElementById("show-log");
const logDiv = document.getElementById("log");
logDiv.hidden = true;
showLogButton.addEventListener("click", () => {
  menuDropdown.hidden = true;
  logDiv.hidden = !logDiv.hidden;
  logDiv.scroll({ top: logDiv.scrollHeight });
});
const log = (message) => {
  let shouldScroll =
    logDiv.scrollTop === logDiv.scrollHeight - logDiv.offsetHeight;
  logDiv.innerHTML += `<p>${message}</p>`;
  if (shouldScroll) logDiv.scroll({ top: logDiv.scrollHeight });
};

window.onerror = (msg, src, line, col, err) => {
  log(`ERROR: ${msg} (${src}:${line}:${col})`);
};
window.addEventListener("unhandledrejection", (e) => {
  log("REJECT: " + e.reason);
});

// --- IndexedDB storage ---

const DB_NAME = "crab";
const DB_VERSION = 1;
let db = null;

const openDB = () => new Promise((resolve, reject) => {
  let req = indexedDB.open(DB_NAME, DB_VERSION);
  req.onupgradeneeded = () => {
    let d = req.result;
    if (!d.objectStoreNames.contains("blobs")) d.createObjectStore("blobs");
  };
  req.onsuccess = () => { db = req.result; resolve(db); };
  req.onerror = () => reject(req.error);
});

const dbGet = (key) => new Promise((resolve, reject) => {
  let tx = db.transaction("blobs", "readonly");
  let req = tx.objectStore("blobs").get(key);
  req.onsuccess = () => resolve(req.result ?? null);
  req.onerror = () => reject(req.error);
});

const dbPut = (key, value) => new Promise((resolve, reject) => {
  let tx = db.transaction("blobs", "readwrite");
  let req = tx.objectStore("blobs").put(value, key);
  req.onsuccess = () => resolve();
  req.onerror = () => reject(req.error);
});

const dbDelete = (key) => new Promise((resolve, reject) => {
  let tx = db.transaction("blobs", "readwrite");
  let req = tx.objectStore("blobs").delete(key);
  req.onsuccess = () => resolve();
  req.onerror = () => reject(req.error);
});

// Migrate localStorage data to IndexedDB on first run
const migrateFromLocalStorage = async () => {
  const decodeBase64 = (b64) => {
    let binary = atob(b64);
    let bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  };

  // Migrate GBA BIOS
  let gbaBios = localStorage.getItem("crab_bios");
  if (gbaBios) {
    let name = localStorage.getItem("crab_bios_name") || null;
    await dbPut("bios:gba", { name, data: decodeBase64(gbaBios) });
    localStorage.removeItem("crab_bios");
    localStorage.removeItem("crab_bios_name");
  }

  // Migrate GBC bootrom
  let gbcBootrom = localStorage.getItem("crab_gbc_bootrom");
  if (gbcBootrom) {
    let name = localStorage.getItem("crab_gbc_bootrom_name") || null;
    await dbPut("bios:gbc", { name, data: decodeBase64(gbcBootrom) });
    localStorage.removeItem("crab_gbc_bootrom");
    localStorage.removeItem("crab_gbc_bootrom_name");
  }

  // Migrate recent ROMs
  let recentRaw = localStorage.getItem("crab_recent_roms");
  if (recentRaw) {
    try {
      let list = JSON.parse(recentRaw);
      let migrated = list.map(r => ({ name: r.name, data: decodeBase64(r.data) }));
      await dbPut("recent", migrated);
    } catch {}
    localStorage.removeItem("crab_recent_roms");
  }

  // Migrate saves
  let savesRaw = localStorage.getItem("crab_saves");
  if (savesRaw) {
    try {
      let saves = JSON.parse(savesRaw);
      for (let [key, b64] of Object.entries(saves)) {
        await dbPut("save:" + key, decodeBase64(b64));
      }
    } catch {}
    localStorage.removeItem("crab_saves");
  }
};

// --- FS / BIOS helpers ---

const writeToFS = (filename, bytes) => {
  let stream = FS.open(filename, "w+");
  FS.write(stream, bytes, 0, bytes.length, 0);
  FS.close(stream);
};

const loadBiosFromStorage = async () => {
  let gba = await dbGet("bios:gba");
  if (gba) writeToFS("bios.bin", gba.data);
  let gbc = await dbGet("bios:gbc");
  if (gbc) writeToFS("bootrom.bin", gbc.data);
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

const updateBiosStatusText = async () => {
  if (pendingGbaBios === "remove") {
    gbaBiosStatus.textContent = "Default (pending)";
  } else if (pendingGbaBios) {
    gbaBiosStatus.textContent = pendingGbaBios.name + " (pending)";
  } else {
    let stored = await dbGet("bios:gba");
    gbaBiosStatus.textContent = stored?.name || (stored ? "Set" : "Not set");
  }

  if (pendingGbcBootrom === "remove") {
    gbcBootromStatus.textContent = "None (pending)";
  } else if (pendingGbcBootrom) {
    gbcBootromStatus.textContent = pendingGbcBootrom.name + " (pending)";
  } else {
    let stored = await dbGet("bios:gbc");
    gbcBootromStatus.textContent = stored?.name || (stored ? "Set" : "Not set");
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

document.getElementById("bios-save").addEventListener("click", async () => {
  if (pendingGbaBios === "remove") {
    await dbDelete("bios:gba");
    try { FS.unlink("bios.bin"); } catch {}
  } else if (pendingGbaBios) {
    writeToFS("bios.bin", pendingGbaBios.bytes);
    await dbPut("bios:gba", { name: pendingGbaBios.name, data: pendingGbaBios.bytes });
  }
  if (pendingGbcBootrom === "remove") {
    await dbDelete("bios:gbc");
    try { FS.unlink("bootrom.bin"); } catch {}
  } else if (pendingGbcBootrom) {
    writeToFS("bootrom.bin", pendingGbcBootrom.bytes);
    await dbPut("bios:gbc", { name: pendingGbcBootrom.name, data: pendingGbcBootrom.bytes });
  }
  closeBiosModal();
});

document.getElementById("bios-cancel").addEventListener("click", closeBiosModal);

biosModal.addEventListener("click", (e) => {
  if (e.target === biosModal) closeBiosModal();
});

// --- Recent ROMs ---

const MAX_RECENT = 20;

const getRecentRoms = async () => {
  return (await dbGet("recent")) || [];
};

const saveRecentRoms = async (list) => {
  await dbPut("recent", list);
};

const addRecentRom = async (name, bytes) => {
  let list = (await getRecentRoms()).filter(r => r.name !== name);
  list.unshift({ name, data: new Uint8Array(bytes) });
  if (list.length > MAX_RECENT) list.length = MAX_RECENT;
  await saveRecentRoms(list);
};

const recentModal = document.getElementById("recent-modal");
const recentList = document.getElementById("recent-list");
const storageInfo = document.getElementById("storage-info");

const formatBytes = (bytes) => {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + " MB";
  return (bytes / (1024 * 1024 * 1024)).toFixed(1) + " GB";
};

const updateStorageInfo = async () => {
  if (!navigator.storage?.estimate) {
    storageInfo.textContent = "";
    return;
  }
  let est = await navigator.storage.estimate();
  storageInfo.textContent = `Storage: ${formatBytes(est.usage)} / ${formatBytes(est.quota)}`;
};

const renderRecentList = async () => {
  recentList.innerHTML = "";
  let roms = await getRecentRoms();
  for (let rom of roms) {
    let entry = document.createElement("div");
    entry.className = "recent-entry";
    let nameSpan = document.createElement("span");
    nameSpan.className = "recent-entry-name";
    nameSpan.textContent = rom.name;
    nameSpan.addEventListener("click", async () => {
      let ext = rom.name.substring(rom.name.lastIndexOf(".")).toLowerCase();
      let romFile = "rom" + ext;
      writeToFS(romFile, rom.data);
      await addRecentRom(rom.name, rom.data);
      recentModal.classList.remove("open");
      loadRom(romFile, rom.name);
    });
    let delBtn = document.createElement("button");
    delBtn.className = "recent-delete";
    delBtn.innerHTML = "&#x1f5d1;";
    delBtn.title = "Remove";
    delBtn.addEventListener("click", async (e) => {
      e.stopPropagation();
      let list = (await getRecentRoms()).filter(r => r.name !== rom.name);
      await saveRecentRoms(list);
      await renderRecentList();
      updateStorageInfo();
    });
    entry.appendChild(nameSpan);
    entry.appendChild(delBtn);
    recentList.appendChild(entry);
  }
};

document.getElementById("open-recent").addEventListener("click", () => {
  menuDropdown.hidden = true;
  renderRecentList();
  updateStorageInfo();
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

const persistSave = async (romName, originalName) => {
  let savName = romName.substring(0, romName.lastIndexOf(".")) + ".sav";
  try {
    let data = FS.readFile(savName);
    if (data && data.length > 0) {
      await dbPut("save:" + originalName, new Uint8Array(data));
    }
  } catch {}
};

const restoreSave = async (romName, originalName) => {
  let data = await dbGet("save:" + originalName);
  if (!data) return;
  let savName = romName.substring(0, romName.lastIndexOf(".")) + ".sav";
  writeToFS(savName, data);
};

document.getElementById("export-save").addEventListener("click", async () => {
  menuDropdown.hidden = true;
  if (!currentRomName || !currentOriginalName) {
    alert("No ROM is loaded.");
    return;
  }
  // Persist latest save data first
  await persistSave(currentRomName, currentOriginalName);
  let data = await dbGet("save:" + currentOriginalName);
  if (!data || data.length === 0) {
    alert("No save data found for this ROM.");
    return;
  }
  let savName = currentOriginalName.substring(0, currentOriginalName.lastIndexOf(".")) + ".sav";
  let blob = new Blob([data], { type: "application/octet-stream" });
  let a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = savName;
  a.click();
  URL.revokeObjectURL(a.href);
});

var currentRomName = null;
var currentOriginalName = null;
var paused = false;
var fastForward = false;

const pauseButton = document.getElementById("pause");
const resetButton = document.getElementById("reset");
const fastForwardButton = document.getElementById("fast-forward");
const playbackControls = document.getElementById("playback-controls");

const loadRom = async (romName, originalName) => {
  // Persist save from previous ROM before switching
  if (currentRomName && currentOriginalName) {
    await persistSave(currentRomName, currentOriginalName);
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
  await restoreSave(romName, currentOriginalName);
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
      reader.addEventListener("load", async () => {
        let bytes = new Uint8Array(reader.result);
        writeToFS(romName, bytes);
        await addRecentRom(file.name, bytes);
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
  onRuntimeInitialized: async () => {
    await openDB();
    await migrateFromLocalStorage();
    await loadBiosFromStorage();
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

    const fpsDiv = document.getElementById("fps");
    setInterval(() => {
      if (frameCount >= 59 && frameCount <= 60) {
        fpsDiv.textContent = "";
      } else {
        fpsDiv.textContent = frameCount + " fps";
      }
      frameCount = 0;
    }, 1000);

    // Persist save data to IndexedDB every 5 seconds
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
        // Reset playTime so audio plays immediately (sped up) instead of
        // queuing behind previously scheduled buffers
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
