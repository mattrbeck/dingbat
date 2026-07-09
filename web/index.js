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

// --- Update check ---

const UPDATE_CHECK_KEY = "dingbat_last_update_check";
const UPDATE_CHECK_INTERVAL = 24 * 60 * 60 * 1000; // 24 hours
const updateBtn = document.getElementById("update-btn");
const updateModal = document.getElementById("update-modal");
let updateAvailable = false;

const checkForUpdate = async () => {
  try {
    // Fetch cached version (what we're running) and network version (what's deployed)
    let [cachedRes, networkRes] = await Promise.all([
      fetch("version.txt"),
      fetch("version.txt", { cache: "no-store" }),
    ]);
    if (!cachedRes.ok || !networkRes.ok) return;
    let current = (await cachedRes.text()).trim();
    let latest = (await networkRes.text()).trim();
    if (current && latest && latest !== current) {
      updateAvailable = true;
      updateBtn.hidden = false;
    }
    localStorage.setItem(UPDATE_CHECK_KEY, Date.now().toString());
  } catch {}
};

const maybeCheckForUpdate = () => {
  if (updateAvailable) return; // already showing
  let last = parseInt(localStorage.getItem(UPDATE_CHECK_KEY) || "0", 10);
  if (Date.now() - last >= UPDATE_CHECK_INTERVAL) {
    checkForUpdate();
  }
};

// Check on page load
maybeCheckForUpdate();

// Check when user returns to the tab
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") maybeCheckForUpdate();
});

const applyUpdate = async () => {
  closeUpdateModal();
  // Use the same service worker update flow
  if (swRegistration) {
    try {
      await swRegistration.update();
      let waiting = swRegistration.waiting;
      if (waiting) {
        waiting.postMessage({ type: "skipWaiting" });
        return;
      }
      if (swRegistration.installing) return; // controllerchange will reload
    } catch {}
  }
  // Fallback: clear caches and reload
  if (typeof caches !== "undefined") {
    let keys = await caches.keys();
    await Promise.all(keys.map((key) => caches.delete(key)));
  }
  location.reload();
};

const closeUpdateModal = () => {
  updateModal.classList.remove("open");
};

updateBtn.addEventListener("click", () => {
  if (currentRomName) {
    updateModal.classList.add("open");
  } else {
    applyUpdate();
  }
});

document.getElementById("update-confirm").addEventListener("click", applyUpdate);
document.getElementById("update-not-now").addEventListener("click", closeUpdateModal);
document.getElementById("update-modal-close").addEventListener("click", closeUpdateModal);

updateModal.addEventListener("click", (e) => {
  if (e.target === updateModal) closeUpdateModal();
});

document.getElementById("force-update").addEventListener("click", async () => {
  document.getElementById("menu-dropdown").hidden = true;
  if (!confirm("This will clear all cached assets and reload. Continue?")) return;
  try {
    // Delete all service worker caches (Cache API may not be available on iOS standalone)
    if (typeof caches !== "undefined") {
      let keys = await caches.keys();
      await Promise.all(keys.map((key) => caches.delete(key)));
    }
    // Unregister all service workers (handles case where swRegistration is null)
    if (navigator.serviceWorker) {
      let regs = await navigator.serviceWorker.getRegistrations();
      await Promise.all(regs.map((r) => r.unregister()));
    }
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

const DB_NAME = "dingbat";
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
  let gbaBios = localStorage.getItem("dingbat_bios");
  if (gbaBios) {
    let name = localStorage.getItem("dingbat_bios_name") || null;
    await dbPut("bios:gba", { name, data: decodeBase64(gbaBios) });
    localStorage.removeItem("dingbat_bios");
    localStorage.removeItem("dingbat_bios_name");
  }

  // Migrate GBC bootrom
  let gbcBootrom = localStorage.getItem("dingbat_gbc_bootrom");
  if (gbcBootrom) {
    let name = localStorage.getItem("dingbat_gbc_bootrom_name") || null;
    await dbPut("bios:gbc", { name, data: decodeBase64(gbcBootrom) });
    localStorage.removeItem("dingbat_gbc_bootrom");
    localStorage.removeItem("dingbat_gbc_bootrom_name");
  }

  // Migrate recent ROMs
  let recentRaw = localStorage.getItem("dingbat_recent_roms");
  if (recentRaw) {
    try {
      let list = JSON.parse(recentRaw);
      let migrated = list.map(r => ({ name: r.name, data: decodeBase64(r.data) }));
      await dbPut("recent", migrated);
    } catch {}
    localStorage.removeItem("dingbat_recent_roms");
  }

  // Migrate saves
  let savesRaw = localStorage.getItem("dingbat_saves");
  if (savesRaw) {
    try {
      let saves = JSON.parse(savesRaw);
      for (let [key, b64] of Object.entries(saves)) {
        await dbPut("save:" + key, decodeBase64(b64));
      }
    } catch {}
    localStorage.removeItem("dingbat_saves");
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
    gbaBiosStatus.textContent = "Not set (pending)";
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
    // Don't close keyboard modal if we're rebinding — the capture handler will eat it
    if (!keyboardModal.classList.contains("open") || kbSelection < 0) {
      closeKeyboardModal();
    }
    closeBiosModal();
    closeRecentModal();
    closeUpdateModal();
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

const stripExt = (name) => name.substring(0, name.lastIndexOf("."));

document.getElementById("load-save").addEventListener("click", async () => {
  menuDropdown.hidden = true;
  if (!currentRomName || !currentOriginalName) {
    alert("No ROM is loaded.");
    return;
  }
  if (!confirm("This will overwrite any existing save file for the current game. Continue?")) return;
  pickFile(".sav", async (bytes, fileName) => {
    if (stripExt(fileName) !== stripExt(currentOriginalName)) {
      if (!confirm("You've selected a save file that doesn't match the name of the current game. Are you sure you want to overwrite the save?")) return;
    }
    let savName = currentRomName.substring(0, currentRomName.lastIndexOf(".")) + ".sav";
    writeToFS(savName, bytes);
    await dbPut("save:" + currentOriginalName, new Uint8Array(bytes));
    loadRom(currentRomName, currentOriginalName);
  });
});

// --- Volume control ---

var volume = 100;
const volDisplay = document.getElementById("vol-display");
const volDown = document.getElementById("vol-down");
const volUp = document.getElementById("vol-up");

const setVolume = (v) => {
  volume = Math.max(0, Math.min(100, v));
  volDisplay.value = volume + "%";
  if (typeof updateGain === "function") updateGain();
};

volDown.addEventListener("click", () => setVolume(volume - 10));
volUp.addEventListener("click", () => setVolume(volume + 10));

// --- Keyboard settings ---

const INPUT_NAMES = ["Up", "Down", "Left", "Right", "A", "B", "Select", "Start", "L", "R"];

// event.code → SDL keycode mapping (covers common bindable keys)
const JS_TO_SDL = (() => {
  const m = {
    ArrowUp: 0x40000052, ArrowDown: 0x40000051,
    ArrowLeft: 0x40000050, ArrowRight: 0x4000004F,
    Backspace: 8, Tab: 9, Enter: 13, Escape: 27, Space: 32,
    Comma: 44, Minus: 45, Period: 46, Slash: 47,
    Digit0: 48, Digit1: 49, Digit2: 50, Digit3: 51, Digit4: 52,
    Digit5: 53, Digit6: 54, Digit7: 55, Digit8: 56, Digit9: 57,
    Semicolon: 59, Equal: 61, BracketLeft: 91, Backslash: 92,
    BracketRight: 93, Backquote: 96, Delete: 127,
    CapsLock: 0x40000039,
    F1: 0x4000003A, F2: 0x4000003B, F3: 0x4000003C, F4: 0x4000003D,
    F5: 0x4000003E, F6: 0x4000003F, F7: 0x40000040, F8: 0x40000041,
    F9: 0x40000042, F10: 0x40000043, F11: 0x40000044, F12: 0x40000045,
    ShiftLeft: 0x400000E1, ShiftRight: 0x400000E5,
    ControlLeft: 0x400000E0, ControlRight: 0x400000E4,
    AltLeft: 0x400000E2, AltRight: 0x400000E6,
  };
  // Letter keys: KeyA-KeyZ → 97-122
  for (let i = 0; i < 26; i++) {
    m["Key" + String.fromCharCode(65 + i)] = 97 + i;
  }
  return m;
})();

// Reverse: SDL keycode → display name
const SDL_TO_NAME = (() => {
  const m = {
    0x40000052: "\u2191", 0x40000051: "\u2193",
    0x40000050: "\u2190", 0x4000004F: "\u2192",
    8: "Backspace", 9: "Tab", 13: "Return", 27: "Escape", 32: "Space",
    44: ",", 45: "-", 46: ".", 47: "/",
    59: ";", 61: "=", 91: "[", 92: "\\", 93: "]", 96: "`", 127: "Delete",
  };
  for (let i = 0; i < 10; i++) m[48 + i] = String(i);
  for (let i = 0; i < 26; i++) m[97 + i] = String.fromCharCode(65 + i);
  return m;
})();

// Presets: array of 10 SDL keycodes indexed by Input enum order
const PRESET_DEFAULT = [
  0x40000052, 0x40000051, 0x40000050, 0x4000004F, // Up Down Left Right
  122, 120, 8, 13, 97, 115 // Z X Backspace Return A S
];
const PRESET_HOMEROW = [
  101, 100, 115, 102, // E D S F
  107, 106, 108, 59, 119, 114 // K J L ; W R
];

// Current active keybindings (SDL keycodes indexed by input ID)
var activeBindings = [...PRESET_DEFAULT];

// Build reverse lookup: event.code → input ID (for JS-side keyboard handling)
var codeLookup = {};
const rebuildLookup = () => {
  codeLookup = {};
  for (let i = 0; i < activeBindings.length; i++) {
    // Find the event.code that maps to this SDL keycode
    for (let [code, sdl] of Object.entries(JS_TO_SDL)) {
      if (sdl === activeBindings[i]) {
        codeLookup[code] = i;
        break;
      }
    }
  }
};
rebuildLookup();

// JS-side keyboard handler: intercepts bound keys before Emscripten's SDL layer
// and calls _setInput directly. This is authoritative for keyboard input.
const gameKeyHandler = (e, down) => {
  if (keyboardModal.classList.contains("open")) return;
  let inputId = codeLookup[e.code];
  if (inputId !== undefined && typeof Module !== "undefined" && Module._setInput) {
    e.preventDefault();
    e.stopImmediatePropagation();
    Module._setInput(inputId, down ? 1 : 0);
  }
};
document.addEventListener("keydown", (e) => gameKeyHandler(e, true), true);
document.addEventListener("keyup", (e) => gameKeyHandler(e, false), true);

const keyboardModal = document.getElementById("keyboard-modal");
const kbBindingsDiv = document.getElementById("kb-bindings");
const kbPreset = document.getElementById("kb-preset");

var kbEditing = [...PRESET_DEFAULT]; // temp editing state
var kbSelection = -1; // which input is selected for rebinding (-1 = none)

const sdlName = (code) => SDL_TO_NAME[code] || "???";

const detectPreset = (bindings) => {
  if (bindings.every((v, i) => v === PRESET_DEFAULT[i])) return "default";
  if (bindings.every((v, i) => v === PRESET_HOMEROW[i])) return "homerow";
  return "custom";
};

const renderKbBindings = () => {
  kbBindingsDiv.innerHTML = "";
  for (let i = 0; i < INPUT_NAMES.length; i++) {
    let row = document.createElement("div");
    row.className = "kb-row";
    let btn = document.createElement("button");
    btn.type = "button";
    btn.className = "kb-btn" + (kbSelection === i ? " active" : "");
    btn.textContent = sdlName(kbEditing[i]);
    btn.addEventListener("click", () => {
      kbSelection = i;
      renderKbBindings();
    });
    let label = document.createElement("span");
    label.textContent = INPUT_NAMES[i];
    row.appendChild(btn);
    row.appendChild(label);
    kbBindingsDiv.appendChild(row);
  }
};

const kbKeyHandler = (e) => {
  if (kbSelection < 0) return;
  let sdl = JS_TO_SDL[e.code];
  if (sdl === undefined) return;
  e.preventDefault();
  e.stopImmediatePropagation();
  // Remove any existing binding for this key
  for (let i = 0; i < kbEditing.length; i++) {
    if (kbEditing[i] === sdl) kbEditing[i] = -1;
  }
  kbEditing[kbSelection] = sdl;
  // Auto-advance to next input
  if (kbSelection < INPUT_NAMES.length - 1) {
    kbSelection++;
  } else {
    kbSelection = -1;
  }
  kbPreset.value = detectPreset(kbEditing);
  renderKbBindings();
};

const openKeyboardModal = () => {
  menuDropdown.hidden = true;
  kbEditing = [...activeBindings];
  kbSelection = -1;
  kbPreset.value = detectPreset(kbEditing);
  renderKbBindings();
  keyboardModal.classList.add("open");
  document.addEventListener("keydown", kbKeyHandler, true);
};

const closeKeyboardModal = () => {
  kbSelection = -1;
  keyboardModal.classList.remove("open");
  document.removeEventListener("keydown", kbKeyHandler, true);
};

const applyKeybindings = (bindings) => {
  activeBindings = [...bindings];
  rebuildLookup();
};

const saveKeybindings = async () => {
  applyKeybindings(kbEditing);
  await dbPut("keybindings", activeBindings);
  closeKeyboardModal();
};

const loadKeybindingsFromStorage = async () => {
  let stored = await dbGet("keybindings");
  if (stored && stored.length === INPUT_NAMES.length) {
    applyKeybindings(stored);
  }
};

document.getElementById("open-keyboard").addEventListener("click", openKeyboardModal);
document.getElementById("kb-save").addEventListener("click", saveKeybindings);
document.getElementById("kb-cancel").addEventListener("click", closeKeyboardModal);

keyboardModal.addEventListener("click", (e) => {
  if (e.target === keyboardModal) closeKeyboardModal();
});

kbPreset.addEventListener("change", () => {
  if (kbPreset.value === "default") kbEditing = [...PRESET_DEFAULT];
  else if (kbPreset.value === "homerow") kbEditing = [...PRESET_HOMEROW];
  kbSelection = -1;
  renderKbBindings();
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

let handleRomFile = (file) => {
  let ext = file.name.substring(file.name.lastIndexOf(".")).toLowerCase();
  if (ext !== ".gba" && ext !== ".gb" && ext !== ".gbc") return;
  let romName = "rom" + ext;
  let reader = new FileReader();
  reader.addEventListener("load", async () => {
    let bytes = new Uint8Array(reader.result);
    writeToFS(romName, bytes);
    await addRecentRom(file.name, bytes);
    loadRom(romName, file.name);
  });
  reader.readAsArrayBuffer(file);
};

document.getElementById("open-rom").addEventListener("click", () => {
  menuDropdown.hidden = true;
  let input = document.createElement("input");
  input.type = "file";
  input.accept = ".gba,.gb,.gbc";
  input.addEventListener("input", () => {
    if (input.files?.length > 0) handleRomFile(input.files[0]);
  });
  input.click();
});

let dropOverlay = document.getElementById("drop-overlay");
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
    await loadKeybindingsFromStorage();
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
    let gainNode = null;
    let playTime = 0;

    const initAudio = () => {
      if (audioCtx) return;
      // Request "playback" audio session so iOS ignores the silent switch.
      // This is the official WebKit API (Safari 17+).
      if (navigator.audioSession) {
        navigator.audioSession.type = "playback";
      }
      audioCtx = new AudioContext({ sampleRate: SAMPLE_RATE });
      gainNode = audioCtx.createGain();
      gainNode.gain.value = volume / 100;
      gainNode.connect(audioCtx.destination);
      playTime = 0;
    };

    // Expose gain update for the volume control
    window.updateGain = () => {
      if (gainNode) gainNode.gain.value = volume / 100;
    };

    // Resume audio context on first user interaction (browser autoplay policy).
    // On iOS Safari, we also play a brief silent buffer through the AudioContext
    // and an <audio> element to ensure the audio session is fully activated.
    let audioUnlocked = false;
    const resumeAudio = () => {
      initAudio();
      if (audioCtx.state === "suspended") audioCtx.resume();
      if (!audioUnlocked) {
        audioUnlocked = true;
        // Play a silent buffer through the AudioContext to fully unlock it
        let silentBuf = audioCtx.createBuffer(1, 1, SAMPLE_RATE);
        let src = audioCtx.createBufferSource();
        src.buffer = silentBuf;
        src.connect(audioCtx.destination);
        src.start(0);
        // Also play through an <audio> element as a fallback for older iOS
        let a = new Audio("data:audio/wav;base64,UklGRiYAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQIAAAAAAA==");
        a.play().catch(() => {});
      }
    };
    document.addEventListener("click", resumeAudio, { once: false });
    document.addEventListener("keydown", resumeAudio, { once: false });
    document.addEventListener("touchstart", resumeAudio, { once: false });

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
      source.connect(gainNode);
      source.start(playTime);
      playTime += buffer.duration;
    };

    const fpsDiv = document.getElementById("fps");
    setInterval(() => {
      if (sleepVisible) {
        frameCount = 0;
        return;  // fps display is showing SLEEPING
      }
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

    // "SLEEPING" indicator while the GBA is in Stop mode, shown in place of
    // the FPS counter (which isn't meaningful while sleeping)
    let sleepVisible = false;
    const updateSleepOverlay = () => {
      const sleeping = !!(Module._isStopped && Module._isStopped());
      if (sleeping !== sleepVisible) {
        sleepVisible = sleeping;
        fpsDiv.textContent = sleeping ? "SLEEPING" : "";
      }
    };

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
      updateSleepOverlay();
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
