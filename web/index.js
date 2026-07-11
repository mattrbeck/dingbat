// --- Service Worker ---

let swRegistration = null;

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js").then((reg) => {
    swRegistration = reg;
    // A new version already installed on a previous visit and is waiting
    if (reg.waiting) showUpdateButton();
    // A new version is discovered while this page is open (the browser
    // checks sw.js on navigation, so this fires on the first load after
    // a deploy)
    reg.addEventListener("updatefound", () => {
      let sw = reg.installing;
      sw.addEventListener("statechange", () => {
        // Ignore the very first install, when nothing controls the page yet
        if (sw.state === "installed" && navigator.serviceWorker.controller) {
          showUpdateButton();
        }
      });
    });
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

const showUpdateButton = () => {
  updateAvailable = true;
  updateBtn.hidden = false;
};

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
      showUpdateButton();
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

// Full reset: drop every cache AND unregister the workers, then reload.
// Deleting caches alone is worse than useless — the old worker stays in
// control with an empty cache it will never repopulate (install only runs
// once), so the next load mixes browser-HTTP-cached assets instead.
const fullResetReload = async () => {
  if (typeof caches !== "undefined") {
    let keys = await caches.keys();
    await Promise.all(keys.map((key) => caches.delete(key)));
  }
  if (navigator.serviceWorker) {
    let regs = await navigator.serviceWorker.getRegistrations();
    await Promise.all(regs.map((r) => r.unregister()));
  }
  location.reload();
};

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
      let installing = swRegistration.installing;
      if (installing) {
        // Activate it as soon as it finishes installing; controllerchange
        // then reloads the page
        installing.addEventListener("statechange", () => {
          if (installing.state === "installed") {
            installing.postMessage({ type: "skipWaiting" });
          }
        });
        return;
      }
    } catch {}
  }
  // No new worker found (e.g. deploy propagation lag): full clean slate
  await fullResetReload();
};

const closeUpdateModal = () => {
  updateModal.classList.remove("open");
  releaseFocus(updateModal);
};

updateBtn.addEventListener("click", () => {
  if (currentRomName) {
    updateModal.classList.add("open");
    trapFocus(updateModal);
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
    await fullResetReload();
  } catch (e) {
    alert("Force update failed: " + e.message);
  }
});

const showLogButton = document.getElementById("show-log");
const logDiv = document.getElementById("log");
const logEntries = document.getElementById("log-entries");
logDiv.hidden = true;

const LOG_MAX_ENTRIES = 500;
const logTime = () => new Date().toTimeString().slice(0, 8);

const log = (message, level = "info") => {
  let shouldScroll =
    logDiv.scrollTop >= logDiv.scrollHeight - logDiv.offsetHeight - 4;
  let p = document.createElement("p");
  p.className = "log-" + level;
  p.textContent = `[${logTime()}] ${message}`;
  logEntries.appendChild(p);
  while (logEntries.childElementCount > LOG_MAX_ENTRIES)
    logEntries.firstElementChild.remove();
  if (shouldScroll) logDiv.scroll({ top: logDiv.scrollHeight });
};

// Mirror the console into the log view: the emulator core's own messages
// (save-state rejections, backup-type detection, ...) arrive via
// emscripten's default print -> console.log, which is invisible on phones
for (const level of ["log", "warn", "error"]) {
  const orig = console[level].bind(console);
  console[level] = (...args) => {
    orig(...args);
    try {
      const text = args
        .map((a) => (a instanceof Error ? a.stack || a.message
                     : typeof a === "object" ? JSON.stringify(a) : String(a)))
        .join(" ");
      log(text, level === "log" ? "info" : level);
    } catch {}
  };
}

window.onerror = (msg, src, line, col, err) => {
  log(`ERROR: ${msg} (${src}:${line}:${col})`, "error");
};
window.addEventListener("unhandledrejection", (e) => {
  log("REJECT: " + ((e.reason && e.reason.stack) || e.reason), "error");
});

// One line of environment context, refreshed each time the log opens —
// exactly the details needed to make sense of remote bug reports
const logContext = async () => {
  let version = "unknown";
  try {
    version = (await (await fetch("version.txt")).text()).trim().slice(0, 12);
  } catch {}
  const sw = navigator.serviceWorker && navigator.serviceWorker.controller
    ? "sw:controlled" : "sw:none";
  return `dingbat ${version} | ${sw} | ${window.innerWidth}x${window.innerHeight}@${devicePixelRatio} | ${navigator.userAgent}`;
};

showLogButton.addEventListener("click", async () => {
  menuDropdown.hidden = true;
  logDiv.hidden = !logDiv.hidden;
  if (!logDiv.hidden) {
    document.getElementById("log-context").textContent = await logContext();
    logDiv.scroll({ top: logDiv.scrollHeight });
  }
});

document.getElementById("log-clear").addEventListener("click", () => {
  logEntries.textContent = "";
});

document.getElementById("log-copy").addEventListener("click", async () => {
  const text = [
    document.getElementById("log-context").textContent,
    ...Array.from(logEntries.children, (p) => p.textContent),
  ].join("\n");
  try {
    await navigator.clipboard.writeText(text);
    showToast("Log copied");
  } catch {
    showToast("Couldn't access the clipboard");
  }
});

// --- Modal focus management (open: focus first control + trap Tab; close:
// restore focus to the element that opened it) ---

let modalReturnFocus = null;
let modalTrapHandler = null;

const modalFocusables = (overlay) =>
  Array.from(
    overlay.querySelectorAll("button, input, select, textarea, [tabindex]")
  ).filter(
    (n) => !n.disabled && n.offsetParent !== null && n.getAttribute("tabindex") !== "-1"
  );

const trapFocus = (overlay) => {
  modalReturnFocus = document.activeElement;
  let f = modalFocusables(overlay);
  if (f.length) f[0].focus();
  modalTrapHandler = (e) => {
    if (e.key !== "Tab") return;
    let items = modalFocusables(overlay);
    if (!items.length) return;
    let idx = items.indexOf(document.activeElement);
    if (e.shiftKey && idx <= 0) {
      e.preventDefault();
      items[items.length - 1].focus();
    } else if (!e.shiftKey && idx === items.length - 1) {
      e.preventDefault();
      items[0].focus();
    }
  };
  overlay.addEventListener("keydown", modalTrapHandler);
};

const releaseFocus = (overlay) => {
  if (modalTrapHandler) overlay.removeEventListener("keydown", modalTrapHandler);
  modalTrapHandler = null;
  try {
    if (modalReturnFocus && modalReturnFocus.focus) modalReturnFocus.focus();
  } catch {}
  modalReturnFocus = null;
};

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
  trapFocus(biosModal);
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
  releaseFocus(biosModal);
};

document.getElementById("bios-close").addEventListener("click", closeBiosModal);

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

const addRecentRom = async (name, bytes, art) => {
  let list = (await getRecentRoms()).filter(r => r.name !== name);
  let entry = { name, data: new Uint8Array(bytes) };
  if (art) entry.art = art; // Blob (box art from a zip), optional
  list.unshift(entry);
  if (list.length > MAX_RECENT) list.length = MAX_RECENT;
  await saveRecentRoms(list);
  refreshHomeRecent();
};

// Launch a ROM from a stored recent entry ({ name, data, art? })
const launchRom = async (rom) => {
  let ext = rom.name.substring(rom.name.lastIndexOf(".")).toLowerCase();
  let romFile = "rom" + ext;
  writeToFS(romFile, rom.data);
  await addRecentRom(rom.name, rom.data, rom.art);
  loadRom(romFile, rom.name);
};

// Home-screen recent grid — this is the app's game library (it replaces the
// old Recent modal: launch, remove, and storage usage all live here).
const homeRecentWrap = document.getElementById("home-recent-wrap");
const homeRecent = document.getElementById("home-recent");
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
  storageInfo.textContent = `${formatBytes(est.usage)} used`;
};

const deleteRecent = async (name) => {
  let list = (await getRecentRoms()).filter((r) => r.name !== name);
  await saveRecentRoms(list);
  refreshHomeRecent();
};

// Object URLs for box-art thumbnails, revoked and rebuilt each render
let homeArtUrls = [];

const refreshHomeRecent = async () => {
  if (!db) return;
  let roms = await getRecentRoms();
  homeArtUrls.forEach(URL.revokeObjectURL);
  homeArtUrls = [];
  homeRecent.innerHTML = "";
  if (roms.length === 0) {
    homeRecentWrap.hidden = true;
    return;
  }
  homeRecentWrap.hidden = false;
  updateStorageInfo();
  for (let rom of roms) {
    let system = systemOf(rom.name);
    let tile = document.createElement("div");
    tile.className = "home-tile";

    let launch = document.createElement("button");
    launch.type = "button";
    launch.className = "home-tile-launch";
    launch.title = rom.name; // full name on hover when truncated

    let icon;
    if (rom.art) {
      // Box art from a zip, shown in place of the cartridge icon
      let url = URL.createObjectURL(rom.art);
      homeArtUrls.push(url);
      icon = document.createElement("img");
      icon.className = "home-tile-art";
      icon.src = url;
      icon.alt = "";
    } else {
      icon = document.createElement("span");
      icon.className = "cart cart-" + system.toLowerCase();
    }

    let name = document.createElement("span");
    name.className = "home-tile-name";
    name.textContent = rom.name;

    let badge = document.createElement("span");
    badge.className = "home-tile-badge badge-" + system.toLowerCase();
    badge.textContent = system;

    launch.appendChild(icon);
    launch.appendChild(name);
    launch.appendChild(badge);
    launch.addEventListener("click", () => launchRom(rom));

    let del = document.createElement("button");
    del.type = "button";
    del.className = "home-tile-delete";
    del.title = "Remove from recent";
    del.setAttribute("aria-label", "Remove " + rom.name);
    del.innerHTML = "&times;";
    del.addEventListener("click", (e) => {
      e.stopPropagation();
      deleteRecent(rom.name);
    });

    tile.appendChild(launch);
    tile.appendChild(del);
    homeRecent.appendChild(tile);
  }
};

// Close any open modal on Escape
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    // Don't close keyboard modal if we're rebinding — the capture handler will eat it
    if (!keyboardModal.classList.contains("open") || kbSelection < 0) {
      closeKeyboardModal();
    }
    closeBiosModal();
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

// --- Save states ---
// State images come from the core's wasm_state_size/wasm_state_data/
// wasm_load_state exports and are stored in IndexedDB keyed by the same
// per-ROM identity the library uses ("state:" + original file name, next to
// "save:" battery saves). The bytes are byte-compatible with the desktop
// emulator's ~/.config/dingbat/states/*.state files, so exported states can
// move between web and desktop. All calls happen from event handlers, which
// run between requestAnimationFrame ticks — i.e. at a frame boundary.

let toastTimer = null;
const showToast = (msg) => {
  let t = document.getElementById("toast");
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show"), 2200);
};

const stateKey = (name) => "state:" + name;

// Serialize the running core's state; returns a Uint8Array copy or null.
const captureStateBytes = () => {
  if (typeof Module === "undefined" || !Module._wasm_state_size) return null;
  let len = Module._wasm_state_size();
  if (len <= 0) return null;
  let ptr = Module._wasm_state_data();
  if (!ptr) return null;
  // Copy out of WASM memory immediately: the buffer is only retained until
  // the next wasm_state_size call (and the heap can move when memory grows).
  return new Uint8Array(Module.memory.buffer, ptr, len).slice();
};

// Validate + apply a state image; returns true when the core accepted it.
const applyStateBytes = (bytes) => {
  if (typeof Module === "undefined" || !Module._wasm_load_state) return false;
  let ptr = Module._malloc(bytes.length);
  if (!ptr) return false;
  // Build the heap view after _malloc: growth can detach the old buffer
  new Uint8Array(Module.memory.buffer, ptr, bytes.length).set(bytes);
  let ok = Module._wasm_load_state(ptr, bytes.length) === 1;
  Module._free(ptr);
  return ok;
};

document.getElementById("save-state").addEventListener("click", async () => {
  menuDropdown.hidden = true;
  if (!currentOriginalName) return;
  let bytes = captureStateBytes();
  if (!bytes) {
    showToast("Couldn't capture the emulator state");
    return;
  }
  try {
    await dbPut(stateKey(currentOriginalName), bytes);
    showToast("State saved");
  } catch (e) {
    showToast("Save state failed: " + e.message);
  }
});

document.getElementById("load-state").addEventListener("click", async () => {
  menuDropdown.hidden = true;
  if (!currentOriginalName) return;
  let bytes = null;
  try {
    bytes = await dbGet(stateKey(currentOriginalName));
  } catch (e) {
    showToast("Load state failed: " + e.message);
    return;
  }
  if (!bytes) {
    showToast("No saved state for this game");
    return;
  }
  // The core validates the image (version, core kind, ROM checksum, payload
  // hash) and leaves itself untouched when it doesn't match — e.g. a state
  // saved for a different ROM.
  showToast(applyStateBytes(bytes) ? "State loaded" : "State didn't match this game");
});

document.getElementById("export-state").addEventListener("click", () => {
  menuDropdown.hidden = true;
  if (!currentOriginalName) return;
  let bytes = captureStateBytes();
  if (!bytes) {
    showToast("Couldn't capture the emulator state");
    return;
  }
  // Same format as the desktop emulator's .state files
  let blob = new Blob([bytes], { type: "application/octet-stream" });
  let a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = stripExt(currentOriginalName) + ".state";
  a.click();
  URL.revokeObjectURL(a.href);
});

document.getElementById("import-state").addEventListener("click", () => {
  menuDropdown.hidden = true;
  if (!currentOriginalName) return;
  pickFile(".state", (bytes) => {
    // Applied directly, not persisted — use Save State to keep it around
    showToast(applyStateBytes(bytes) ? "State loaded" : "State didn't match this game");
  });
});

// --- Volume control ---

var volume = 100;
var muted = false;
// Both the top-bar slider (hidden on phones) and the in-menu slider
const volSliders = Array.from(document.querySelectorAll(".vol-range"));
const muteBtn = document.getElementById("mute-btn");
const menuVolume = document.getElementById("menu-volume");

// Effective gain applied to the audio graph (0..1), respecting mute.
const effectiveGain = () => (muted ? 0 : volume / 100);

const syncVolumeUI = () => {
  let off = muted || volume === 0;
  for (let s of volSliders) {
    s.value = volume;
    s.style.setProperty("--vol", volume + "%");
    s.classList.toggle("muted", off);
  }
  muteBtn.classList.toggle("muted", off);
  muteBtn.title = muted ? "Unmute" : "Mute";
};

// Persist volume/mute to IndexedDB, debounced so slider drags don't hammer it
let audioSaveTimer = null;
const saveAudioSettings = () => {
  if (!db) return;
  clearTimeout(audioSaveTimer);
  audioSaveTimer = setTimeout(() => dbPut("audio", { volume, muted }), 250);
};

const setVolume = (v) => {
  volume = Math.max(0, Math.min(100, Math.round(v)));
  if (volume > 0) muted = false;
  syncVolumeUI();
  if (typeof updateGain === "function") updateGain();
  saveAudioSettings();
};

const toggleMute = () => {
  muted = !muted;
  if (!muted && volume === 0) volume = 50;
  syncVolumeUI();
  if (typeof updateGain === "function") updateGain();
  saveAudioSettings();
};

const loadAudioSettings = async () => {
  let s = await dbGet("audio");
  if (s && typeof s.volume === "number") {
    volume = Math.max(0, Math.min(100, s.volume));
    muted = !!s.muted;
    syncVolumeUI();
    if (typeof updateGain === "function") updateGain();
  }
};

for (let s of volSliders) {
  s.addEventListener("input", () => setVolume(Number(s.value)));
}
muteBtn.addEventListener("click", toggleMute);
// Keep the menu open while interacting with its volume slider
["click", "pointerdown"].forEach((ev) =>
  menuVolume.addEventListener(ev, (e) => e.stopPropagation())
);
syncVolumeUI();

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
  trapFocus(keyboardModal);
};

const closeKeyboardModal = () => {
  kbSelection = -1;
  keyboardModal.classList.remove("open");
  document.removeEventListener("keydown", kbKeyHandler, true);
  releaseFocus(keyboardModal);
};

document.getElementById("kb-close").addEventListener("click", closeKeyboardModal);

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

// --- Large on-screen controls (bigger d-pad for touch) ---
const largeControlsToggle = document.getElementById("large-controls-toggle");

const applyLargeControls = (on) => {
  document.body.classList.toggle("large-controls", on);
  largeControlsToggle.checked = on;
};

largeControlsToggle.addEventListener("change", async () => {
  applyLargeControls(largeControlsToggle.checked);
  await dbPut("large-controls", largeControlsToggle.checked);
});

const loadLargeControlsFromStorage = async () => {
  applyLargeControls(!!(await dbGet("large-controls")));
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
var speed2x = false;
var rewindHeld = false;
var lastRewindPop = 0;

const pauseButton = document.getElementById("pause");
const resetButton = document.getElementById("reset");
const fastForwardButton = document.getElementById("fast-forward");
const speed2xButton = document.getElementById("speed-2x-btn");
const rewindButton = document.getElementById("rewind");

const loadRom = async (romName, originalName) => {
  // Persist save from previous ROM before switching
  if (currentRomName && currentOriginalName) {
    await persistSave(currentRomName, currentOriginalName);
  }
  currentRomName = romName;
  currentOriginalName = originalName || romName;
  paused = false;
  fastForward = false;
  speed2x = false;  // a fresh core starts with turbo off
  rewindHeld = false;
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  fastForwardButton.classList.remove("active");
  speed2xButton.classList.remove("active");
  rewindButton.classList.remove("active");
  document.body.classList.add("has-game", "running");
  // Restore save for the new ROM
  await restoreSave(romName, currentOriginalName);
  Module.ccall("initFromEmscripten", null, ["string"], [romName]);
};

// --- File type helpers ---

const ROM_EXTS = [".gba", ".gb", ".gbc"];
const IMG_EXTS = [".png", ".jpg", ".jpeg", ".webp", ".gif"];

const extOf = (n) => {
  let i = n.lastIndexOf(".");
  return i < 0 ? "" : n.slice(i).toLowerCase();
};
const baseName = (n) => n.slice(n.lastIndexOf("/") + 1);
const systemOf = (name) => {
  let e = extOf(name);
  return e === ".gba" ? "GBA" : e === ".gbc" ? "GBC" : "GB";
};
const mimeForImg = (e) =>
  ({ ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
     ".webp": "image/webp", ".gif": "image/gif" }[e] || "image/png");

// --- Minimal in-browser ZIP reader ---
// Reads the central directory and inflates entries with the platform's
// DecompressionStream (deflate-raw) — no external library, works under COEP.

const unzip = async (arrayBuffer) => {
  const view = new DataView(arrayBuffer);
  const bytes = new Uint8Array(arrayBuffer);
  const len = arrayBuffer.byteLength;

  // Find End Of Central Directory (scan the tail; comment is at most 64 KB)
  let eocd = -1;
  const scanStart = Math.max(0, len - 65557);
  for (let i = len - 22; i >= scanStart; i--) {
    if (view.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("not a valid zip file");

  const count = view.getUint16(eocd + 10, true);
  let p = view.getUint32(eocd + 16, true); // central directory offset
  const entries = [];
  for (let n = 0; n < count && p + 46 <= len; n++) {
    if (view.getUint32(p, true) !== 0x02014b50) break;
    const method = view.getUint16(p + 10, true);
    const compSize = view.getUint32(p + 20, true);
    const uncompSize = view.getUint32(p + 24, true);
    const nameLen = view.getUint16(p + 28, true);
    const extraLen = view.getUint16(p + 30, true);
    const commentLen = view.getUint16(p + 32, true);
    const localOffset = view.getUint32(p + 42, true);
    const name = new TextDecoder().decode(bytes.subarray(p + 46, p + 46 + nameLen));
    entries.push({ name, method, compSize, uncompSize, localOffset });
    p += 46 + nameLen + extraLen + commentLen;
  }

  const extract = async (entry) => {
    const lo = entry.localOffset;
    if (view.getUint32(lo, true) !== 0x04034b50) throw new Error("bad local header");
    const nameLen = view.getUint16(lo + 26, true);
    const extraLen = view.getUint16(lo + 28, true);
    const start = lo + 30 + nameLen + extraLen;
    const comp = bytes.subarray(start, start + entry.compSize);
    if (entry.method === 0) return comp.slice(); // stored
    if (entry.method === 8) {
      if (typeof DecompressionStream === "undefined")
        throw new Error("this browser can't decompress zip files");
      const stream = new Blob([comp]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
      return new Uint8Array(await new Response(stream).arrayBuffer());
    }
    throw new Error("unsupported zip compression (method " + entry.method + ")");
  };

  return { entries, extract };
};

const usable = (e) => !e.name.startsWith("__MACOSX/") && !e.name.endsWith("/");

const handleZipFile = async (file) => {
  let zip;
  try {
    zip = await unzip(await file.arrayBuffer());
  } catch (e) {
    alert("Couldn't read that zip: " + e.message);
    return;
  }
  let romEntry = zip.entries.find((e) => usable(e) && ROM_EXTS.includes(extOf(e.name)));
  if (!romEntry) {
    alert("No .gba, .gb or .gbc ROM was found inside that zip.");
    return;
  }
  // Largest embedded image is almost always the box art
  let imgEntry = zip.entries
    .filter((e) => usable(e) && IMG_EXTS.includes(extOf(e.name)))
    .sort((a, b) => b.uncompSize - a.uncompSize)[0];

  let romBytes;
  try {
    romBytes = await zip.extract(romEntry);
  } catch (e) {
    alert("Couldn't extract the ROM: " + e.message);
    return;
  }
  let art = null;
  if (imgEntry) {
    try {
      let imgBytes = await zip.extract(imgEntry);
      art = new Blob([imgBytes], { type: mimeForImg(extOf(imgEntry.name)) });
    } catch { /* art is optional */ }
  }

  let innerName = baseName(romEntry.name);
  let romFile = "rom" + extOf(innerName);
  writeToFS(romFile, romBytes);
  await addRecentRom(innerName, romBytes, art);
  loadRom(romFile, innerName);
};

let handleRomFile = (file) => {
  let ext = extOf(file.name);
  if (ext === ".zip") return handleZipFile(file);
  if (!ROM_EXTS.includes(ext)) {
    alert("Unsupported file. Load a .gba, .gb, or .gbc ROM (or a .zip containing one).");
    return;
  }
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

const openRomPicker = () => {
  menuDropdown.hidden = true;
  let input = document.createElement("input");
  input.type = "file";
  // No `accept` filter: some platforms (notably iOS Safari) grey out files
  // whose extension they don't recognize — .gba/.gb/.gbc — as soon as a known
  // type like .zip is listed. Showing all files keeps every ROM selectable;
  // handleRomFile validates the extension itself.
  input.addEventListener("input", () => {
    if (input.files?.length > 0) handleRomFile(input.files[0]);
  });
  input.click();
};

document.getElementById("dropzone").addEventListener("click", openRomPicker);

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
  pauseButton.classList.toggle("paused", paused);
  pauseButton.classList.toggle("active", paused);
  pauseButton.title = paused ? "Resume" : "Pause";
});

resetButton.addEventListener("click", () => {
  if (currentRomName) loadRom(currentRomName, currentOriginalName);
});

// 2x speed and unbounded fast forward are radio-style: fast forward would
// silently dominate 2x (it ignores pacing entirely), so enabling either
// clears the other.
const setSpeed2x = (on) => {
  speed2x = on;
  speed2xButton.classList.toggle("active", on);
  if (typeof Module !== "undefined" && Module._wasm_set_turbo) {
    Module._wasm_set_turbo(on ? 1 : 0);
  }
};
const setFastForward = (on) => {
  fastForward = on;
  fastForwardButton.classList.toggle("active", on);
};

fastForwardButton.addEventListener("click", () => {
  setFastForward(!fastForward);
  if (fastForward) setSpeed2x(false);
});

// 2x speed: the core drops every other audio sample (pitched-up realtime
// audio) while the tick loop halves its per-frame time step
speed2xButton.addEventListener("click", () => {
  setSpeed2x(!speed2x);
  if (speed2x) setFastForward(false);
});

// Rewind: hold to step history backward (the tick loop pops snapshots at a
// fixed cadence while held)
const setRewindHeld = (on) => {
  rewindHeld = on;
  rewindButton.classList.toggle("active", on);
};
rewindButton.addEventListener("pointerdown", (e) => {
  e.preventDefault();
  setRewindHeld(true);
});
for (const ev of ["pointerup", "pointerleave", "pointercancel"]) {
  rewindButton.addEventListener(ev, () => setRewindHeld(false));
}

// --- Main Menu (return to the home screen without terminating the game) ---

// Show the home screen over the paused-but-still-loaded game. The emulator
// keeps its state; Resume (or loading another ROM) picks up where it left off.
const showMainMenu = () => {
  menuDropdown.hidden = true;
  if (!currentRomName) return;
  paused = true;
  document.body.classList.remove("running");
  refreshHomeRecent();
};

const resumeGame = () => {
  if (!currentRomName) return;
  paused = false;
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  document.body.classList.add("running");
};

document.getElementById("main-menu").addEventListener("click", showMainMenu);
document.getElementById("home-resume").addEventListener("click", resumeGame);

// --- Screenshot ---
// The GBA canvas is a WebGL context without preserveDrawingBuffer, so its
// pixels are only valid within the render task. captureCanvas() is therefore
// called from the main loop right after a fresh frame is drawn.
let pendingShot = false;

const captureCanvas = () => {
  pendingShot = false;
  document.getElementById("canvas").toBlob((blob) => {
    if (!blob) return;
    let a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = (currentOriginalName || "dingbat").replace(/\.[^.]*$/, "") + ".png";
    a.click();
    URL.revokeObjectURL(a.href);
  });
};

const takeScreenshot = () => {
  menuDropdown.hidden = true;
  if (!currentRomName || typeof Module === "undefined" || !Module._loop_tick) return;
  if (paused) {
    // Paused loop isn't rendering; draw one frame, then grab it in the same task
    Module._loop_tick();
    captureCanvas();
  } else {
    pendingShot = true; // grabbed by the running loop after the next render
  }
};

document.getElementById("screenshot").addEventListener("click", takeScreenshot);

// --- Fullscreen ---

const fullscreenBtn = document.getElementById("fullscreen-btn");
const fsRoot = document.documentElement;
const requestFs = fsRoot.requestFullscreen || fsRoot.webkitRequestFullscreen;
if (!requestFs) {
  // iOS Safari can't fullscreen arbitrary elements
  fullscreenBtn.hidden = true;
} else {
  fullscreenBtn.addEventListener("click", () => {
    let active = document.fullscreenElement || document.webkitFullscreenElement;
    if (active) {
      (document.exitFullscreen || document.webkitExitFullscreen).call(document);
    } else {
      requestFs.call(fsRoot);
    }
  });
  const onFsChange = () => {
    let active = !!(document.fullscreenElement || document.webkitFullscreenElement);
    document.body.classList.toggle("fs", active);
    fullscreenBtn.title = active ? "Exit Fullscreen" : "Fullscreen";
  };
  document.addEventListener("fullscreenchange", onFsChange);
  document.addEventListener("webkitfullscreenchange", onFsChange);
}

// --- Gamepad support (polled each frame from the main loop) ---

// Input IDs: 0 Up, 1 Down, 2 Left, 3 Right, 4 A, 5 B, 6 Select, 7 Start, 8 L, 9 R
const gpPrev = new Array(10).fill(false);
const GP_DEADZONE = 0.4;

const pollGamepads = () => {
  if (typeof Module === "undefined" || !Module._setInput) return;
  const pads = navigator.getGamepads ? navigator.getGamepads() : [];
  const want = new Array(10).fill(false);
  let anyConnected = false;
  for (const pad of pads) {
    if (!pad) continue;
    anyConnected = true;
    const b = (i) => pad.buttons[i] && pad.buttons[i].pressed;
    if (b(0) || b(3)) want[4] = true; // A / Y -> A
    if (b(1) || b(2)) want[5] = true; // B / X -> B
    if (b(8)) want[6] = true; // Back -> Select
    if (b(9)) want[7] = true; // Start
    if (b(4) || b(6)) want[8] = true; // LB / LT -> L
    if (b(5) || b(7)) want[9] = true; // RB / RT -> R
    if (b(12)) want[0] = true; // Dpad
    if (b(13)) want[1] = true;
    if (b(14)) want[2] = true;
    if (b(15)) want[3] = true;
    const ax = pad.axes[0] || 0;
    const ay = pad.axes[1] || 0; // Left stick
    if (ay < -GP_DEADZONE) want[0] = true;
    if (ay > GP_DEADZONE) want[1] = true;
    if (ax < -GP_DEADZONE) want[2] = true;
    if (ax > GP_DEADZONE) want[3] = true;
  }
  if (!anyConnected) return;
  for (let i = 0; i < 10; i++) {
    if (want[i] !== gpPrev[i]) {
      Module._setInput(i, want[i] ? 1 : 0);
      gpPrev[i] = want[i];
    }
  }
};

var Module = {
  canvas: (() => document.getElementById("canvas"))(),
  onRuntimeInitialized: async () => {
    await openDB();
    await migrateFromLocalStorage();
    await loadBiosFromStorage();
    await loadKeybindingsFromStorage();
    await loadLargeControlsFromStorage();
    await loadAudioSettings();
    refreshHomeRecent();
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
      gainNode.gain.value = effectiveGain();
      gainNode.connect(audioCtx.destination);
      playTime = 0;
    };

    // Expose gain update for the volume control
    window.updateGain = () => {
      if (gainNode) gainNode.gain.value = effectiveGain();
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
        document.body.classList.toggle("sleeping", sleeping);
      }
    };

    const tick = (timestamp) => {
      pollGamepads();
      if (paused) {
        lastFrameTime = 0;
        accumulator = 0;
        requestAnimationFrame(tick);
        return;
      }
      if (lastFrameTime === 0) lastFrameTime = timestamp;
      accumulator += timestamp - lastFrameTime;
      lastFrameTime = timestamp;
      if (rewindHeld) {
        // Pop ~30 snapshots/s (10 frames each ≈ 5x realtime backward); the
        // pop presents the restored frame itself, and no audio is queued so
        // the scheduled lead just drains
        if (timestamp - lastRewindPop >= 33) {
          lastRewindPop = timestamp;
          if (Module._wasm_rewind_pop) Module._wasm_rewind_pop();
        }
        accumulator = 0;
      } else if (fastForward) {
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
        // Run as many frames as needed to catch up, capped to avoid spiral.
        // At 2x speed each frame consumes half the wall-clock step (the core
        // decimates audio to match).
        const step = speed2x ? FRAME_TIME / 2 : FRAME_TIME;
        const maxFrames = speed2x ? 4 : 2;
        let framesRun = 0;
        while (accumulator >= step && framesRun < maxFrames) {
          Module._loop_tick();
          pushAudio();
          frameCount++;
          accumulator -= step;
          framesRun++;
        }
        // Prevent accumulator from growing unbounded if tab was backgrounded
        if (accumulator > step * 2) accumulator = 0;
      }
      // Draw one guaranteed-fresh frame, then capture it in this same task
      if (pendingShot) {
        Module._loop_tick();
        captureCanvas();
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

// Short haptic tick for touch controls (no-op where unsupported)
const haptic = () => {
  try { navigator.vibrate?.(8); } catch {}
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
      element.classList.add("pressed");
      setInputs(getInputs(element), true);
      haptic();
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
      currentDpadElement?.classList.remove("pressed");
      element.classList.add("pressed");
      currentDpadElement = element;
      haptic();
    } else {
      setInputs(oldInputs, false);
      currentDpadElement?.classList.remove("pressed");
      currentDpadElement = null;
    }
  }
};

const dpadTouchEnd = (event) => {
  let touch = getTouch(event.changedTouches, currentDpadTouchId);
  if (touch != null) {
    setInputs(getInputs(currentDpadElement), false);
    currentDpadElement?.classList.remove("pressed");
    currentDpadTouchId = null;
    currentDpadElement = null;
  }
};

document.getElementById("dpad").addEventListener("touchstart", dpadTouchStart);
document.getElementById("dpad").addEventListener("touchmove", dpadTouchMove);
document.getElementById("dpad").addEventListener("touchend", dpadTouchEnd);
document.getElementById("dpad").addEventListener("touchcancel", dpadTouchEnd);

// Standalone buttons (A/B/L/R/Select/Start). D-pad children are handled by the
// dedicated d-pad handlers above, so they're excluded here.
document
  .querySelectorAll("#l, #r, #a, #b, #select, #start")
  .forEach((element) => {
    element.addEventListener("touchstart", (event) => {
      event.preventDefault();
      element.classList.add("pressed");
      setInputs(getInputs(element), true);
      haptic();
    });
    const release = () => {
      element.classList.remove("pressed");
      setInputs(getInputs(element), false);
    };
    element.addEventListener("touchend", release);
    element.addEventListener("touchcancel", release);
  });
