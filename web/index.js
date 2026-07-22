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

// The per-tile "2P" local link-cable launcher is a debugging aid (test a link
// trade with two cores of the same ROM). It's hidden by default; add `?2p` to
// the URL to reveal it — a `debug-2p` body class the CSS keys off of.
if (new URLSearchParams(location.search).has("2p")) {
  document.body.classList.add("debug-2p");
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
    // current: the version.txt in the running build's cache. latest: a fresh
    // version.txt. deployed: the CACHE_VERSION stamped in a fresh sw.js.
    // version.txt alone can't gate the button — Pages' CDN propagates
    // per-object after a deploy, so version.txt can be new while sw.js and
    // the assets still serve the previous build; clicking Update then finds
    // nothing to install and the button "does nothing". Only show the button
    // once sw.js and version.txt agree on the same new version, i.e. the
    // update is actually fetchable.
    let [cachedRes, networkRes, swRes] = await Promise.all([
      fetch("version.txt"),
      fetch("version.txt", { cache: "no-store" }),
      fetch("sw.js", { cache: "no-store" }),
    ]);
    if (!cachedRes.ok || !networkRes.ok || !swRes.ok) return;
    let current = (await cachedRes.text()).trim();
    let latest = (await networkRes.text()).trim();
    let deployed = (await swRes.text()).match(/CACHE_VERSION = "([^"]+)"/)?.[1];
    if (current && latest && latest !== current) {
      if (deployed === latest) {
        showUpdateButton();
      } else {
        // Deploy still propagating through the CDN: skip stamping the check
        // time so the next tab-visibility change retries soon
        return;
      }
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
  if (currentRomName || linkMode) {
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

// Force update: ask the live worker to re-download every asset straight from
// origin (nonce-busted URLs skip stale CDN edges AND the browser HTTP cache
// — Pages serves assets with multi-hour max-age) and reload into the result.
// This works even while the CDN still serves the previous build's sw.js,
// which is exactly when the normal update flow can't find anything to
// install. Falls back to the old nuke-everything reset when no worker is in
// control or the reinstall doesn't ack.
const forceUpdate = async () => {
  const ctrl = navigator.serviceWorker?.controller;
  if (ctrl) {
    const ok = await new Promise((resolve) => {
      const timer = setTimeout(() => done(false), 20000);
      const done = (v) => {
        clearTimeout(timer);
        navigator.serviceWorker.removeEventListener("message", onMsg);
        resolve(v);
      };
      const onMsg = (e) => {
        if (e.data?.type === "reinstalled") done(e.data.ok);
      };
      navigator.serviceWorker.addEventListener("message", onMsg);
      ctrl.postMessage({ type: "reinstall", nonce: Date.now() });
    });
    if (ok) {
      location.reload();
      return;
    }
  }
  await fullResetReload();
};

document.getElementById("force-update").addEventListener("click", async () => {
  document.getElementById("menu-dropdown").hidden = true;
  if (!confirm("This will re-download the app and reload. Continue?")) return;
  try {
    await forceUpdate();
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

// Viewport diagnostics for the iOS portrait layout bug (frame not full
// width + dead space under the controls): dump every quantity that
// determines the app column's height, so a copied device log pinpoints
// where the missing height goes. Logged at boot, on ROM load, and after
// orientation changes.
const logViewportDiag = (tag) => {
  try {
    const probe = document.createElement("div");
    probe.style.cssText =
      "position:fixed;top:0;left:0;width:0;visibility:hidden;pointer-events:none;height:100dvh";
    document.body.appendChild(probe);
    const dvh = probe.getBoundingClientRect().height;
    probe.style.height = "100vh";
    const vh = probe.getBoundingClientRect().height;
    probe.style.height = "100svh";
    const svh = probe.getBoundingClientRect().height;
    probe.remove();
    const cs = getComputedStyle(document.documentElement);
    const rect = (el) => {
      if (!el) return "n/a";
      const b = el.getBoundingClientRect();
      return `${Math.round(b.top)}..${Math.round(b.bottom)}(w${Math.round(b.width)})`;
    };
    const standalone =
      navigator.standalone === true ||
      matchMedia("(display-mode: standalone)").matches;
    log(
      `viewport[${tag}]: inner ${window.innerWidth}x${window.innerHeight} ` +
        `vv ${Math.round(visualViewport ? visualViewport.height : -1)} ` +
        `vh/svh/dvh ${Math.round(vh)}/${Math.round(svh)}/${Math.round(dvh)} ` +
        `screen ${screen.width}x${screen.height} standalone ${standalone} ` +
        `safe t/b ${cs.getPropertyValue("--safe-t").trim() || "?"}/` +
        `${cs.getPropertyValue("--safe-b").trim() || "?"} | ` +
        `body ${rect(document.body)} topbar ${rect(document.getElementById("topbar"))} ` +
        `stage ${rect(document.getElementById("stage"))} ` +
        `controls ${rect(document.getElementById("controls"))} ` +
        `canvas ${rect(document.getElementById("canvas"))}`
    );
  } catch (e) {
    log("viewport diag failed: " + e.message, "error");
  }
};

window.addEventListener("load", () => setTimeout(() => logViewportDiag("boot"), 1000));
window.addEventListener("orientationchange", () =>
  setTimeout(() => logViewportDiag("rotate"), 1000)
);

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
  // Vibration diagnostic: support + a live test call so real-device haptic
  // debugging is one log-read away. vibrate(0) cancels any pulse and returns
  // true when supported AND sticky activation exists (returns/logs a block
  // otherwise) — the log is opened by a click, so activation is present here
  // and the return reflects genuine device support. `act` is the page's sticky
  // activation state; `firstAct` is the event that first granted it (or none).
  const vibSupported = "vibrate" in navigator;
  let vibTest = "n/a";
  if (vibSupported) {
    try { vibTest = String(navigator.vibrate(0)); } catch { vibTest = "err"; }
  }
  const act = navigator.userActivation
    ? String(navigator.userActivation.hasBeenActive) : "?";
  // hblk: running count of in-game haptic() calls whose vibrate() returned
  // false (blocked) over total calls — read after pressing a few buttons to
  // see whether pulses are being swallowed on this device.
  const vib = `vibrate:${vibSupported} test:${vibTest} act:${act} firstAct:${firstActivationEvent || "none"} hblk:${hapticBlocked}/${hapticCalls}`;
  return `dingbat ${version} | ${sw} | ${window.innerWidth}x${window.innerHeight}@${devicePixelRatio} | ${vib} | ${navigator.userAgent}`;
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
    if (navigator.clipboard) {
      await navigator.clipboard.writeText(text);
    } else {
      // navigator.clipboard only exists on secure origins; dev serves over
      // LAN http land here. The deprecated execCommand path still works.
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand("copy");
      ta.remove();
      if (!ok) throw new Error("execCommand copy failed");
    }
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

const dbKeys = () => new Promise((resolve, reject) => {
  let tx = db.transaction("blobs", "readonly");
  let req = tx.objectStore("blobs").getAllKeys();
  req.onsuccess = () => resolve(req.result || []);
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

  // Migrate recent ROMs (straight into the per-ROM layout: rom:<name>
  // records first, then the metadata-only "recent" index)
  let recentRaw = localStorage.getItem("dingbat_recent_roms");
  if (recentRaw) {
    try {
      let list = JSON.parse(recentRaw);
      let now = Date.now();
      let meta = [];
      for (let i = 0; i < list.length; i++) {
        let r = list[i];
        if (!r?.name) continue;
        await dbPut(romKey(r.name), { name: r.name, data: decodeBase64(r.data) });
        meta.push({ name: r.name, ts: now - i }); // order encodes recency
      }
      await dbPut("recent", meta);
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

// Migrate the old single-record recents format (one "recent" record holding
// every ROM's bytes inline: [{ name, data, art? }]) to the per-ROM layout.
// ROM/art records are written before the index is rewritten, so an interrupted
// run leaves the old record intact and a re-run just overwrites the same
// per-ROM records — idempotent either way. Entries without .data (already the
// new metadata format) mean there is nothing to do.
const migrateRecentFormat = async () => {
  let list = await dbGet("recent");
  if (!Array.isArray(list) || !list.some((r) => r && r.data)) return;
  let now = Date.now();
  let meta = [];
  for (let i = 0; i < list.length; i++) {
    let r = list[i];
    if (!r?.name) continue;
    if (r.data) await dbPut(romKey(r.name), { name: r.name, data: r.data });
    if (r.art) await dbPut(artKey(r.name), r.art);
    meta.push({ name: r.name, ts: r.ts ?? now - i }); // keep most-recent-first
  }
  await dbPut("recent", meta);
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

// --- Settings modal (tabbed: Controls / Game Boy / GBA / Video) ---

const settingsModal = document.getElementById("settings-modal");
const gbaBiosStatus = document.getElementById("gba-bios-status");
const gbcBootromStatus = document.getElementById("gbc-bootrom-status");

const updateBiosStatusText = async () => {
  let gba = await dbGet("bios:gba");
  gbaBiosStatus.textContent = gba ? gba.name || "Set" : "Not set";
  let gbc = await dbGet("bios:gbc");
  gbcBootromStatus.textContent = gbc ? gbc.name || "Set" : "Not set";
};

// iOS/iPadOS (iPad reports as "MacIntel" with touch points since iPadOS 13).
const IS_IOS = /iP(hone|ad|od)/.test(navigator.platform) ||
  (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);

const pickFile = (accept, callback) => {
  let input = document.createElement("input");
  input.type = "file";
  // iOS Safari greys out (makes unselectable) any file whose extension it can't
  // map to a known type — ".sav"/".state"/".bin" have no UTI, so the save file
  // can't be picked at all. Skip the filter on iOS; the extension isn't needed
  // functionally (the target save name is derived from the loaded ROM).
  if (accept && !IS_IOS) input.accept = accept;
  // iOS Safari needs the input attached to the DOM and NOT display:none for the
  // picker to open — hide it off-screen instead.
  input.style.position = "fixed";
  input.style.left = "-9999px";
  input.style.opacity = "0";
  document.body.appendChild(input);
  const done = () => input.remove();
  input.addEventListener("change", () => {
    if (input.files?.length > 0) {
      let file = input.files[0];
      let reader = new FileReader();
      reader.addEventListener("load", () => { callback(new Uint8Array(reader.result), file.name); done(); });
      reader.addEventListener("error", done);
      reader.readAsArrayBuffer(file);
    } else done();
  });
  input.addEventListener("cancel", done);  // dismissed without picking
  input.click();
};

// Tab bar: one pane visible at a time
const settingsTabs = Array.from(document.querySelectorAll(".settings-tab"));

const selectSettingsTab = (name) => {
  for (let t of settingsTabs) {
    let on = t.dataset.tab === name;
    t.classList.toggle("active", on);
    t.setAttribute("aria-selected", on ? "true" : "false");
    document.getElementById("settings-pane-" + t.dataset.tab).hidden = !on;
  }
};

settingsTabs.forEach((t) =>
  t.addEventListener("click", () => selectSettingsTab(t.dataset.tab))
);

const openSettingsModal = () => {
  menuDropdown.hidden = true;
  // Build identity: version.txt fetched through the SW cache = the running
  // build's commit, so a device can be matched to a deploy at a glance
  fetch("version.txt")
    .then((r) => (r.ok ? r.text() : ""))
    .then((v) => {
      document.getElementById("settings-version").textContent =
        v ? "dingbat " + v.trim().slice(0, 12) : "";
    })
    .catch(() => {});
  updateBiosStatusText();
  kbSelection = -1;
  kbPreset.value = detectPreset(activeBindings);
  renderKbBindings();
  settingsModal.classList.add("open");
  document.addEventListener("keydown", kbKeyHandler, true);
  trapFocus(settingsModal);
};

const closeSettingsModal = () => {
  kbSelection = -1;
  settingsModal.classList.remove("open");
  document.removeEventListener("keydown", kbKeyHandler, true);
  releaseFocus(settingsModal);
};

document.getElementById("open-settings").addEventListener("click", openSettingsModal);
document.getElementById("settings-close").addEventListener("click", closeSettingsModal);

settingsModal.addEventListener("click", (e) => {
  if (e.target === settingsModal) closeSettingsModal();
});

// BIOS / bootrom files apply immediately: the FS copy and the IndexedDB copy
// are updated on pick, and the next core construction reads the FS file.
document.getElementById("pick-gba-bios").addEventListener("click", () => {
  pickFile(".bin", async (bytes, name) => {
    writeToFS("bios.bin", bytes);
    await dbPut("bios:gba", { name, data: bytes });
    updateBiosStatusText();
  });
});

document.getElementById("remove-gba-bios").addEventListener("click", async () => {
  await dbDelete("bios:gba");
  try { FS.unlink("bios.bin"); } catch {}
  updateBiosStatusText();
});

document.getElementById("pick-gbc-bootrom").addEventListener("click", () => {
  pickFile(".bin", async (bytes, name) => {
    writeToFS("bootrom.bin", bytes);
    await dbPut("bios:gbc", { name, data: bytes });
    updateBiosStatusText();
  });
});

document.getElementById("remove-gbc-bootrom").addEventListener("click", async () => {
  await dbDelete("bios:gbc");
  try { FS.unlink("bootrom.bin"); } catch {}
  updateBiosStatusText();
});

// --- Manage Saves modal (state + battery-save import/export) ---

const savesModal = document.getElementById("saves-modal");

const openSavesModal = () => {
  menuDropdown.hidden = true;
  savesModal.classList.add("open");
  trapFocus(savesModal);
};

const closeSavesModal = () => {
  savesModal.classList.remove("open");
  releaseFocus(savesModal);
};

document.getElementById("manage-saves").addEventListener("click", openSavesModal);
document.getElementById("saves-close").addEventListener("click", closeSavesModal);

savesModal.addEventListener("click", (e) => {
  if (e.target === savesModal) closeSavesModal();
});

// --- Cheats modal ---
// JS owns the cheat list (array of {name, codes, enabled}); the Nim core owns
// the parsed/applied form. On any edit we serialize to the shared ".cht" text
// format, push it into the core via load_cheats (which returns parse errors),
// and persist it per-game in IndexedDB under "cheats:<originalName>".

const cheatsModal = document.getElementById("cheats-modal");
const cheatsListEl = document.getElementById("cheats-list");
const cheatNameEl = document.getElementById("cheat-name");
const cheatCodesEl = document.getElementById("cheat-codes");
const cheatErrorEl = document.getElementById("cheat-error");
const cheatEmptyEl = document.getElementById("cheats-empty");
const cheatHelpEl = document.getElementById("cheats-help");
const cheatFormatHintEl = document.getElementById("cheat-format-hint");
const CHEATS_KEY = (n) => "cheats:" + n;
let cheatList = [];

const serializeCheats = (list) => {
  let out = "";
  for (const c of list) {
    out += "[" + (c.enabled ? "x" : " ") + "] " + c.name + "\n";
    for (const line of c.codes.split("\n")) {
      const l = line.trim();
      if (l) out += l + "\n";
    }
    out += "\n";
  }
  return out;
};

const parseCheats = (text) => {
  const list = [];
  let cur = null;
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    if (line.length >= 3 && line[0] === "[" && line[2] === "]") {
      cur = { enabled: line[1] === "x" || line[1] === "X", name: line.slice(3).trim(), codes: "" };
      list.push(cur);
    } else if (cur) {
      cur.codes += (cur.codes ? "\n" : "") + line;
    }
  }
  return list;
};

const pushCheatsToCore = (text) => {
  if (typeof Module === "undefined" || !Module.ccall) return "";
  return Module.ccall("load_cheats", "string", ["string"], [text]) || "";
};

const showCheatError = (err) => {
  if (err && err.length) {
    cheatErrorEl.textContent = err;
    cheatErrorEl.hidden = false;
  } else {
    cheatErrorEl.hidden = true;
  }
};

const renderCheatList = () => {
  const hasGame = !!currentOriginalName;
  cheatEmptyEl.hidden = hasGame;
  cheatHelpEl.hidden = !hasGame;
  if (cheatFormatHintEl) {
    const gba = hasGame && extOf(currentOriginalName) === ".gba";
    cheatFormatHintEl.textContent = gba
      ? "GameShark/AR v3: XXXXXXXX YYYYYYYY   ·   CodeBreaker: 82XXXXXX YYYY"
      : "Game Genie: ABC-DEF-GHI    ·    GameShark: 011234C0";
  }
  cheatsListEl.innerHTML = "";
  cheatList.forEach((c, i) => {
    const row = document.createElement("div");
    row.className = "cheat-row";
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = c.enabled;
    cb.addEventListener("change", () => { cheatList[i].enabled = cb.checked; applyCheats(); });
    const info = document.createElement("div");
    info.className = "cheat-row-info";
    const nm = document.createElement("span");
    nm.className = "cheat-row-name";
    nm.textContent = c.name || "Cheat " + (i + 1);
    const code = document.createElement("span");
    code.className = "cheat-row-code";
    code.textContent = c.codes.replace(/\n/g, "  ");
    info.appendChild(nm);
    info.appendChild(code);
    const del = document.createElement("button");
    del.type = "button";
    del.className = "cheat-del";
    del.textContent = "×";
    del.title = "Delete cheat";
    del.addEventListener("click", () => { cheatList.splice(i, 1); applyCheats(); });
    row.appendChild(cb);
    row.appendChild(info);
    row.appendChild(del);
    cheatsListEl.appendChild(row);
  });
};

const applyCheats = async () => {
  const text = serializeCheats(cheatList);
  const err = currentOriginalName ? pushCheatsToCore(text) : "";
  if (currentOriginalName) {
    if (cheatList.length) await dbPut(CHEATS_KEY(currentOriginalName), text);
    else await dbDelete(CHEATS_KEY(currentOriginalName));
  }
  showCheatError(err);
  renderCheatList();
};

// Called from loadRom after the core is built: pull this game's saved cheats
// from IndexedDB and push them into the fresh core.
const restoreCheats = async () => {
  cheatList = [];
  if (currentOriginalName) {
    const text = await dbGet(CHEATS_KEY(currentOriginalName));
    if (typeof text === "string" && text) cheatList = parseCheats(text);
  }
  pushCheatsToCore(serializeCheats(cheatList));
  renderCheatList();
};

const openCheatsModal = () => {
  menuDropdown.hidden = true;
  showCheatError("");
  renderCheatList();
  cheatsModal.classList.add("open");
  trapFocus(cheatsModal);
};

const closeCheatsModal = () => {
  cheatsModal.classList.remove("open");
  releaseFocus(cheatsModal);
};

document.getElementById("open-cheats").addEventListener("click", openCheatsModal);
document.getElementById("cheats-close").addEventListener("click", closeCheatsModal);
cheatsModal.addEventListener("click", (e) => {
  if (e.target === cheatsModal) closeCheatsModal();
});

document.getElementById("cheat-add").addEventListener("click", () => {
  if (!currentOriginalName) { showCheatError("Load a game first."); return; }
  const codes = cheatCodesEl.value.trim();
  if (!codes) { showCheatError("Enter at least one code."); return; }
  const name = cheatNameEl.value.trim() || "Cheat " + (cheatList.length + 1);
  cheatList.push({ name, codes, enabled: true });
  cheatNameEl.value = "";
  cheatCodesEl.value = "";
  applyCheats();
});

// --- Delete save data (per-ROM), shared by the home "Manage ROMs and Saves"
// list and the in-game "Reset save file" action ---
// "Save data" for a ROM is spread across the "blobs" store under keys derived
// from its original file name: "save:<name>" (battery), "state:<name>" (the
// single save-state slot), and "save:<name>-p2" (the 2P-link partner's
// battery). Deleting a game wipes all three so it truly boots fresh.

// Two-step inline confirm button (the app has no shared confirm dialog): the
// first tap arms the button (swaps to "Confirm?" and turns red), a second tap
// within 3.5s runs onConfirm. Returns the <button>; `disarm()` is exposed so a
// caller can reset a sibling when another button in the same row is armed.
const makeConfirmButton = ({
  label,
  confirmLabel = "Confirm?",
  className,
  onConfirm,
  onArm,
}) => {
  let btn = document.createElement("button");
  btn.type = "button";
  btn.className = className;
  btn.textContent = label;
  let armed = false;
  let armTimer = null;
  const disarm = () => {
    armed = false;
    clearTimeout(armTimer);
    btn.classList.remove("armed");
    btn.textContent = label;
  };
  btn.disarm = disarm;
  btn.addEventListener("click", async () => {
    if (!armed) {
      armed = true;
      btn.classList.add("armed");
      btn.textContent = confirmLabel;
      armTimer = setTimeout(disarm, 3500);
      if (onArm) onArm();
      return;
    }
    clearTimeout(armTimer);
    btn.disabled = true;
    await onConfirm();
  });
  return btn;
};

// A greyed-out button used when an action can't be taken right now (e.g. the
// game is live), mirroring the "In use" pattern in the delete lists.
const makeDisabledButton = (label, className, title) => {
  let btn = document.createElement("button");
  btn.type = "button";
  btn.className = className;
  btn.textContent = label;
  btn.disabled = true;
  if (title) btn.title = title;
  return btn;
};

// Collect the set of ROM identities (original names) that have any save data.
const romsWithSaveData = async () => {
  let names = new Set();
  for (let k of await dbKeys()) {
    if (typeof k !== "string") continue;
    if (k.startsWith("save:")) {
      let n = k.slice(5);
      if (n.endsWith("-p2")) n = n.slice(0, -3); // fold P2 link save into base
      names.add(n);
    } else if (k.startsWith("state:")) {
      // Fold numbered slots ("state:<name>:slotN") into the base ROM identity.
      names.add(k.slice(6).replace(/:slot\d+$/, ""));
    }
  }
  return [...names].sort((a, b) => a.localeCompare(b));
};

// True when this ROM is the game currently held in memory (running or paused
// at the home screen) — deleting its stored save would just be re-persisted
// by the next autosave flush, so this case needs special handling.
const isRomLoaded = (name) =>
  (!!currentOriginalName && currentOriginalName === name) ||
  (linkMode && !!linkRomEntry && linkRomEntry.name === name);

// Remove all stored save data for one ROM.
const deleteSaveData = async (name) => {
  await dbDelete("save:" + name);
  await dbDelete("save:" + name + "-p2");
  // All nine save-state slots and their thumbnail metadata (slot 0 is the
  // legacy "state:<name>" key).
  for (let s = 0; s < NUM_STATE_SLOTS; s++) {
    await dbDelete(slotStateKey(name, s));
    await dbDelete(slotMetaKey(name, s));
  }
};

// Wipe the running game's battery save and reboot it as a fresh cartridge. The
// save-state slot is left untouched — it's managed separately by the modal's
// Export/Import state actions.
const resetCurrentSaveFile = async () => {
  if (!currentOriginalName) return;
  await dbDelete("save:" + currentOriginalName);
  await dbDelete("save:" + currentOriginalName + "-p2");
  // resetLoadedGameSave drops the in-memory FS .sav and reboots the core, so the
  // 5s autosave interval can't re-flush the just-deleted save over the top.
  resetLoadedGameSave();
};

// Reboot the currently-loaded single-player game with no battery save. Called
// only after its stored save has been removed from IndexedDB.
const resetLoadedGameSave = () => {
  if (!currentRomName || !currentOriginalName) return;
  let romName = currentRomName;
  let originalName = currentOriginalName;
  // Drop the in-memory FS .sav so the fresh core doesn't reload it.
  try { FS.unlink(stripExt(romName) + ".sav"); } catch {}
  // Null these first so loadRom's "persist previous save" step is skipped —
  // otherwise it would write the old in-memory save straight back to the key
  // we just deleted. loadRom then restoreSave()s nothing, booting clean.
  currentRomName = null;
  currentOriginalName = null;
  loadRom(romName, originalName);
};

// "Reset save file" action in the in-game Manage Saves modal. A persistent
// two-step confirm button (like Reset all settings): armed on first click,
// wipes + reboots on the second.
const resetSaveSlot = document.getElementById("reset-save-slot");
if (resetSaveSlot) {
  const resetSaveBtn = makeConfirmButton({
    label: "Reset",
    confirmLabel: "Confirm reset?",
    className: "button button-sm saves-reset-btn",
    onConfirm: async () => {
      await resetCurrentSaveFile();
      // Reboots the game rather than re-rendering the button; re-enable and
      // disarm it so it works again next time the modal is opened.
      resetSaveBtn.disabled = false;
      resetSaveBtn.disarm();
      closeSavesModal();
      showToast("Save reset — starting fresh");
    },
  });
  resetSaveSlot.appendChild(resetSaveBtn);
}

// --- Manage ROMs and Saves modal (home-screen game library) ---
// One row per stored game: the recents entries first (most-recently-played
// order, matching the home grid), then any ROM whose save data outlived its
// recents entry (evicted past the 20-item cap) so its leftovers can still be
// cleaned up. Each row offers "Delete Save File" (wipe battery + state + P2
// save) and "Delete Everything" (that plus removing the ROM from this browser).

const romsModal = document.getElementById("roms-modal");
const romsManageList = document.getElementById("roms-manage-list");
const romsManageEmpty = document.getElementById("roms-manage-empty");

const openRomsModal = () => {
  menuDropdown.hidden = true;
  romsModal.classList.add("open");
  refreshRomsManageList();
  renderGdriveSection();
  trapFocus(romsModal);
};

const closeRomsModal = () => {
  romsModal.classList.remove("open");
  releaseFocus(romsModal);
};

document.getElementById("manage-roms").addEventListener("click", openRomsModal);
document.getElementById("roms-close").addEventListener("click", closeRomsModal);
romsModal.addEventListener("click", (e) => {
  if (e.target === romsModal) closeRomsModal();
});

// Ordered rows for the manage list: recents first (already most-recent-first),
// then orphaned save-only games sorted by name. { name, inRecent }.
const romsForManagement = async () => {
  let recents = await getRecentMeta();
  let seen = new Set();
  let rows = [];
  for (let r of recents) {
    if (seen.has(r.name)) continue;
    seen.add(r.name);
    rows.push({ name: r.name, inRecent: true });
  }
  for (let name of await romsWithSaveData()) {
    if (!seen.has(name)) rows.push({ name, inRecent: false });
  }
  return rows;
};

const refreshRomsManageList = async () => {
  if (!db) return;
  let rows = await romsForManagement();
  romsManageList.innerHTML = "";
  romsManageEmpty.hidden = rows.length > 0;

  for (let { name, inRecent } of rows) {
    let row = document.createElement("div");
    row.className = "roms-manage-row";

    let label = document.createElement("span");
    label.className = "roms-manage-name";
    label.textContent = name;
    label.title = name;
    row.appendChild(label);

    let actions = document.createElement("div");
    actions.className = "roms-manage-actions";

    // A live 2P link has two cores writing this ROM's saves; deleting under it
    // would corrupt state, so both actions are blocked until link mode exits.
    let linkRunning = linkMode && linkRomEntry && linkRomEntry.name === name;
    // The single-player game currently in memory (running or paused at home)
    // needs no special-casing for "Delete Everything" anymore: its confirm
    // handler unloads the game first via unloadGame(), which detaches it from
    // the autosave flush before the stored save is deleted.

    // Buttons in a row coordinate: arming one disarms any other still armed.
    let siblings = [];
    const disarmOthers = (except) => {
      for (let b of siblings) if (b !== except && b.disarm) b.disarm();
    };

    let saveBtn;
    if (linkRunning) {
      saveBtn = makeDisabledButton(
        "Delete Save File",
        "button button-sm roms-manage-btn",
        "Exit link mode to delete this game's save",
      );
    } else {
      saveBtn = makeConfirmButton({
        label: "Delete Save File",
        className: "button button-sm roms-manage-btn",
        onArm: () => disarmOthers(saveBtn),
        onConfirm: async () => {
          await deleteSaveData(name);
          if (isRomLoaded(name)) {
            // Reboot the loaded game clean, else its in-memory save re-flushes.
            resetLoadedGameSave();
            closeRomsModal();
            showToast("Save deleted — starting fresh");
          } else {
            showToast("Save data deleted");
            refreshRomsManageList();
            updateStorageInfo();
          }
        },
      });
    }
    siblings.push(saveBtn);

    let allBtn;
    if (linkRunning) {
      allBtn = makeDisabledButton(
        "Delete Everything",
        "button button-sm roms-manage-btn roms-manage-danger",
        "Exit link mode to remove this game",
      );
    } else {
      allBtn = makeConfirmButton({
        label: "Delete Everything",
        className: "button button-sm roms-manage-btn roms-manage-danger",
        onArm: () => disarmOthers(allBtn),
        onConfirm: async () => {
          if (isRomLoaded(name)) {
            // Unload the in-memory game BEFORE deleting: unloadGame nulls
            // currentRomName/currentOriginalName, which is what the 5s
            // autosave interval keys on — so the in-memory save can't be
            // re-flushed over the freshly deleted key. No final flush
            // (flushSave: false); we are deleting this save on purpose.
            if (!(await unloadGame({ flushSave: false }))) {
              showToast("Exit the online session first");
              return;
            }
          }
          await deleteSaveData(name);
          if (inRecent) await deleteRecent(name); // also refreshes home grid
          showToast("Removed from this browser");
          refreshRomsManageList();
          refreshHomeRecent();
          updateStorageInfo();
        },
      });
    }
    siblings.push(allBtn);

    actions.appendChild(saveBtn);
    actions.appendChild(allBtn);
    row.appendChild(actions);
    romsManageList.appendChild(row);
  }
};

// --- Google Drive backup (prototype) ---
// Backs up battery saves, save states, and ROMs to the hidden per-app
// "appDataFolder" in the user's Google Drive, and restores them on another
// device. Pure client-side OAuth via Google Identity Services' token flow:
// no backend, no client secret, and the access token lives in memory only
// (never localStorage/IndexedDB) — it expires after ~1h and is silently
// re-requested on a 401.
//
// Drive file names mirror the IndexedDB keys one-to-one:
//   save:<rom name>       battery save        (overwritten on every backup)
//   save:<rom name>-p2    2P link partner save
//   state:<rom name>      save-state blob
//   rom:<rom name>        ROM image           (skipped when Drive already has
//                                              one with the same byte size —
//                                              ROMs are immutable)
// There is no manifest file: the appDataFolder listing itself is the index,
// and files are matched by name client-side from a full listing, which also
// sidesteps escaping quotes in ROM names inside Drive `q` queries.

// To enable this feature, create an OAuth client ID:
//   1. console.cloud.google.com → create (or pick) a project
//   2. APIs & Services → Library → enable "Google Drive API"
//   3. APIs & Services → OAuth consent screen → add the
//      .../auth/drive.appdata scope, and add yourself as a test user while
//      the app is unverified
//   4. APIs & Services → Credentials → Create credentials → OAuth client ID
//      → type "Web application" → under "Authorized JavaScript origins" add
//      every origin the app is served from (e.g. http://localhost:8000 and
//      the deployed https origin). No redirect URIs are needed for the
//      token flow.
//   5. Paste the client ID below. This flow has no client secret.
// While empty, the modal shows a "not configured" note instead of a
// sign-in button, and the GIS script is never loaded.
// The localStorage override lets a dev test a client ID per-origin without
// committing it: localStorage.setItem("gdrive_client_id", "<id>") + reload.
const GDRIVE_CLIENT_ID = localStorage.getItem("gdrive_client_id") || "";

// drive.appdata = access to the hidden app folder only (no other Drive
// files); "email" lets the UI show which account is connected (via the
// tokeninfo endpoint).
const GDRIVE_SCOPE = "https://www.googleapis.com/auth/drive.appdata email";

const GDRIVE_FILES = "https://www.googleapis.com/drive/v3/files";
const GDRIVE_UPLOAD = "https://www.googleapis.com/upload/drive/v3/files";

let gdriveToken = null;       // access token, in memory only
let gdriveEmail = null;       // best-effort display of the signed-in account
let gdriveTokenClient = null; // GIS token client, created after script load
let gdriveBusy = false;       // one backup/restore/list at a time

// The GIS script loads lazily on first interaction so normal page loads
// never touch Google's servers.
let gisScriptPromise = null;
const loadGisScript = () => {
  gisScriptPromise ??= new Promise((resolve, reject) => {
    let s = document.createElement("script");
    s.src = "https://accounts.google.com/gsi/client";
    s.async = true;
    s.onload = resolve;
    s.onerror = () => {
      gisScriptPromise = null; // allow a retry on the next click
      reject(new Error("Couldn't load Google sign-in — check your connection"));
    };
    document.head.appendChild(s);
  });
  return gisScriptPromise;
};

// Request an access token. promptMode "" = silent refresh (no UI when the
// Google session and a prior grant still stand); undefined = the normal
// account-chooser/consent popup.
const gdriveAcquireToken = async (promptMode) => {
  await loadGisScript();
  gdriveTokenClient ??= google.accounts.oauth2.initTokenClient({
    client_id: GDRIVE_CLIENT_ID,
    scope: GDRIVE_SCOPE,
    callback: () => {}, // replaced per request below
  });
  return new Promise((resolve, reject) => {
    gdriveTokenClient.callback = (resp) => {
      if (resp.error) {
        reject(new Error("Google sign-in failed: " + resp.error));
        return;
      }
      gdriveToken = resp.access_token;
      resolve();
    };
    gdriveTokenClient.error_callback = (err) => {
      reject(new Error(
        err?.type === "popup_failed_to_open"
          ? "Popup blocked — allow popups for this site and try again"
          : "Sign-in was cancelled",
      ));
    };
    gdriveTokenClient.requestAccessToken(
      promptMode === undefined ? {} : { prompt: promptMode },
    );
  });
};

// Best-effort: only works because GDRIVE_SCOPE includes "email".
const gdriveFetchEmail = async () => {
  try {
    let res = await fetch(
      "https://oauth2.googleapis.com/tokeninfo?access_token=" +
        encodeURIComponent(gdriveToken),
    );
    if (res.ok) gdriveEmail = (await res.json()).email || null;
  } catch {}
};

// Authenticated fetch against the Drive API. On a 401 (token expired), one
// silent re-grant is attempted and the request replayed; if that fails the
// user is signed out locally and must sign in again.
const driveFetch = async (url, opts = {}) => {
  const send = () => fetch(url, {
    ...opts,
    headers: { ...(opts.headers || {}), Authorization: "Bearer " + gdriveToken },
  });
  let res = await send();
  if (res.status === 401) {
    try {
      await gdriveAcquireToken("");
    } catch {
      gdriveToken = null;
      renderGdriveSection();
      throw new Error("Google session expired — sign in again");
    }
    res = await send();
  }
  if (!res.ok) throw new Error("Drive request failed (HTTP " + res.status + ")");
  return res;
};

// Everything in the app's hidden folder. Prototype limitation: a single page
// of up to 1000 files, no nextPageToken paging (20 games × 4 files is far
// below that).
const driveListAll = async () => {
  let url = GDRIVE_FILES + "?spaces=appDataFolder&pageSize=1000&fields=" +
    encodeURIComponent("files(id,name,size,modifiedTime)");
  let res = await driveFetch(url);
  return (await res.json()).files || [];
};

// Create + upload a small file in one atomic multipart request. The bytes go
// into the body as a raw Uint8Array inside a Blob — never string-converted.
const driveCreateMultipart = (name, bytes) => {
  let boundary = "dingbat" + Math.random().toString(36).slice(2);
  let body = new Blob([
    `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n` +
      JSON.stringify({ name, parents: ["appDataFolder"] }) +
      `\r\n--${boundary}\r\nContent-Type: application/octet-stream\r\n\r\n`,
    bytes,
    `\r\n--${boundary}--`,
  ]);
  return driveFetch(GDRIVE_UPLOAD + "?uploadType=multipart", {
    method: "POST",
    headers: { "Content-Type": "multipart/related; boundary=" + boundary },
    body,
  });
};

const driveCreateEmpty = async (name) => {
  let res = await driveFetch(GDRIVE_FILES, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, parents: ["appDataFolder"] }),
  });
  return (await res.json()).id;
};

const driveUpdateContent = (fileId, bytes) =>
  driveFetch(GDRIVE_UPLOAD + "/" + fileId + "?uploadType=media", {
    method: "PATCH",
    headers: { "Content-Type": "application/octet-stream" },
    body: new Blob([bytes]),
  });

// Drive caps multipart bodies at 5 MB, so big files (ROMs) go as a bare
// metadata create followed by a media-only content PATCH instead.
const driveUploadFile = async (name, bytes, existingId) => {
  if (existingId) return driveUpdateContent(existingId, bytes);
  if (bytes.length <= 4 * 1024 * 1024) return driveCreateMultipart(name, bytes);
  return driveUpdateContent(await driveCreateEmpty(name), bytes);
};

const driveDownload = async (fileId) => {
  let res = await driveFetch(GDRIVE_FILES + "/" + fileId + "?alt=media");
  return new Uint8Array(await res.arrayBuffer());
};

// Local data worth backing up. Saves/states first so an interrupted backup
// still captured the important (small) part before the multi-MB ROMs.
// ROM entries are lazy (`load`, no `bytes`): the upload loop fetches each
// ROM's bytes from its per-ROM record one at a time and lets them go after
// the upload, so a backup never holds the whole library in memory.
const collectLocalBackupEntries = async () => {
  let entries = [];
  for (let k of await dbKeys()) {
    if (typeof k !== "string") continue;
    if (!k.startsWith("save:") && !k.startsWith("state:")) continue;
    let v = await dbGet(k);
    if (v instanceof ArrayBuffer) v = new Uint8Array(v);
    if (v instanceof Uint8Array && v.length) {
      entries.push({ name: k, bytes: v, rom: false });
    }
  }
  for (let r of await getRecentMeta()) {
    if (!r?.name) continue;
    let name = r.name;
    entries.push({ name: "rom:" + name, load: () => getRomBytes(name), rom: true });
  }
  return entries;
};

// Map a Drive file name back to { game, kind }; null for anything a future
// version might add. Mirrors romsWithSaveData's "-p2" folding.
const parseDriveFileName = (n) => {
  if (n.startsWith("rom:")) return { game: n.slice(4), kind: "rom" };
  if (n.startsWith("state:")) return { game: n.slice(6), kind: "state" };
  if (n.startsWith("save:")) {
    let g = n.slice(5);
    return g.endsWith("-p2")
      ? { game: g.slice(0, -3), kind: "save2" }
      : { game: g, kind: "save" };
  }
  return null;
};

const groupDriveFiles = (files) => {
  let games = new Map();
  for (let f of files) {
    let parsed = parseDriveFileName(f.name);
    if (!parsed) continue;
    let g = games.get(parsed.game);
    if (!g) games.set(parsed.game, (g = { game: parsed.game, files: {} }));
    g.files[parsed.kind] = f;
  }
  return [...games.values()].sort((a, b) => a.game.localeCompare(b.game));
};

// Upload every local save/state (overwrite-always: simplest correct behavior
// for a prototype) plus any ROM Drive doesn't already hold at the same size.
const gdriveBackup = async () => {
  if (gdriveBusy) {
    showToast("A Drive operation is already running");
    return;
  }
  gdriveBusy = true;
  try {
    setGdriveProgress("Checking what's on Drive…");
    let remote = new Map((await driveListAll()).map((f) => [f.name, f]));
    let entries = await collectLocalBackupEntries();
    let uploaded = 0;
    for (let i = 0; i < entries.length; i++) {
      let e = entries[i];
      let existing = remote.get(e.name);
      // Lazy ROM bytes: fetched here, released when `bytes` leaves scope.
      let bytes = e.bytes ?? await e.load();
      if (!bytes || !bytes.length) continue;
      if (e.rom && existing && Number(existing.size) === bytes.length) continue;
      setGdriveProgress(
        `Uploading ${e.name} — ${formatBytes(bytes.length)} (${i + 1}/${entries.length})…`,
      );
      await driveUploadFile(e.name, bytes, existing?.id);
      uploaded++;
    }
    setGdriveProgress("");
    showToast(uploaded
      ? `Backed up ${uploaded} file${uploaded === 1 ? "" : "s"} to Drive`
      : "Everything is already on Drive");
  } catch (e) {
    setGdriveProgress("");
    showToast("Backup failed: " + e.message);
  } finally {
    gdriveBusy = false;
  }
};

// Pull one game's files down. Saves/states overwrite local (behind the
// two-step confirm on the Restore button); the ROM goes through the normal
// addRecentRom path so it appears in the home grid, skipping the download
// when an identically-sized copy is already here.
const gdriveRestoreGame = async (group, btn) => {
  if (gdriveBusy) {
    showToast("A Drive operation is already running");
    btn.disabled = false;
    btn.disarm();
    return;
  }
  gdriveBusy = true;
  try {
    let f = group.files;
    if (f.save) {
      setGdriveProgress(`Downloading save for ${group.game}…`);
      await dbPut("save:" + group.game, await driveDownload(f.save.id));
    }
    if (f.save2) {
      setGdriveProgress(`Downloading P2 save for ${group.game}…`);
      await dbPut("save:" + group.game + "-p2", await driveDownload(f.save2.id));
    }
    if (f.state) {
      setGdriveProgress(`Downloading save state for ${group.game}…`);
      await dbPut(stateKey(group.game), await driveDownload(f.state.id));
    }
    if (f.rom) {
      let local = await getRomBytes(group.game);
      if (!local || local.length !== Number(f.rom.size)) {
        setGdriveProgress(
          `Downloading ROM (${formatBytes(Number(f.rom.size) || 0)})…`,
        );
        await addRecentRom(group.game, await driveDownload(f.rom.id));
      }
    }
    setGdriveProgress("");
    btn.textContent = "Restored";
    showToast(`Restored ${group.game} from Drive`);
    refreshRomsManageList();
    updateStorageInfo();
  } catch (e) {
    setGdriveProgress("");
    btn.disabled = false;
    btn.disarm();
    showToast("Restore failed: " + e.message);
  } finally {
    gdriveBusy = false;
  }
};

// --- Drive section UI (rendered into #gdrive-body in the roms modal) ---

const gdriveBody = document.getElementById("gdrive-body");
let gdriveProgressEl = null;
let gdriveRestoreListEl = null;

const setGdriveProgress = (text) => {
  if (gdriveProgressEl) gdriveProgressEl.textContent = text;
};

const makeGdriveButton = (label, ghost, onClick) => {
  let btn = document.createElement("button");
  btn.type = "button";
  btn.className = "button button-sm" + (ghost ? " button-ghost" : "");
  btn.textContent = label;
  btn.addEventListener("click", onClick);
  return btn;
};

const renderGdriveRestoreList = (files) => {
  if (!gdriveRestoreListEl) return;
  gdriveRestoreListEl.innerHTML = "";
  let groups = groupDriveFiles(files);
  if (groups.length === 0) {
    let p = document.createElement("p");
    p.className = "modal-toggle-sub";
    p.textContent = "Nothing is backed up on Drive yet.";
    gdriveRestoreListEl.appendChild(p);
    return;
  }
  for (let group of groups) {
    let row = document.createElement("div");
    row.className = "roms-manage-row";

    let f = group.files;
    let parts = [];
    if (f.rom) parts.push("ROM " + formatBytes(Number(f.rom.size) || 0));
    if (f.save) parts.push("Save");
    if (f.save2) parts.push("P2 save");
    if (f.state) parts.push("State");
    let newest = Math.max(...Object.values(f).map((x) => Date.parse(x.modifiedTime) || 0));
    if (newest > 0) parts.push(new Date(newest).toLocaleDateString());

    let name = document.createElement("span");
    name.className = "gdrive-restore-name";
    let title = document.createElement("span");
    title.className = "gdrive-restore-title";
    title.textContent = group.game;
    title.title = group.game;
    let sub = document.createElement("span");
    sub.className = "gdrive-restore-sub";
    sub.textContent = parts.join(" · ");
    name.appendChild(title);
    name.appendChild(sub);
    row.appendChild(name);

    let btn;
    if (isRomLoaded(group.game)) {
      // Restoring the running game's save would race the autosave flush
      // (whichever writes last wins) — make the user stop the game first.
      btn = makeDisabledButton(
        "In use",
        "button button-sm roms-manage-btn",
        "Stop this game before restoring its save from Drive",
      );
    } else {
      btn = makeConfirmButton({
        label: "Restore",
        confirmLabel: "Overwrite?",
        className: "button button-sm roms-manage-btn",
        onConfirm: () => gdriveRestoreGame(group, btn),
      });
    }
    row.appendChild(btn);
    gdriveRestoreListEl.appendChild(row);
  }
};

const gdriveShowRestoreList = async () => {
  if (gdriveBusy) {
    showToast("A Drive operation is already running");
    return;
  }
  gdriveBusy = true;
  try {
    setGdriveProgress("Loading what's on Drive…");
    let files = await driveListAll();
    setGdriveProgress("");
    renderGdriveRestoreList(files);
  } catch (e) {
    setGdriveProgress("");
    showToast("Couldn't list Drive: " + e.message);
  } finally {
    gdriveBusy = false;
  }
};

const gdriveSignOut = () => {
  if (gdriveToken && typeof google !== "undefined" && google.accounts?.oauth2) {
    google.accounts.oauth2.revoke(gdriveToken, () => {});
  }
  gdriveToken = null;
  gdriveEmail = null;
  renderGdriveSection();
  showToast("Signed out of Google Drive");
};

const renderGdriveSection = () => {
  if (!gdriveBody) return;
  gdriveBody.innerHTML = "";
  gdriveProgressEl = null;
  gdriveRestoreListEl = null;

  if (!GDRIVE_CLIENT_ID) {
    let p = document.createElement("p");
    p.className = "modal-toggle-sub";
    p.textContent =
      "Drive backup isn't configured in this build (no Google client ID).";
    gdriveBody.appendChild(p);
    return;
  }

  if (!gdriveToken) {
    let btn = makeGdriveButton("Sign in with Google", false, async () => {
      btn.disabled = true;
      try {
        await gdriveAcquireToken();
        await gdriveFetchEmail();
        renderGdriveSection();
        showToast("Connected to Google Drive");
      } catch (e) {
        showToast(e.message);
        btn.disabled = false;
      }
    });
    gdriveBody.appendChild(btn);
    return;
  }

  let status = document.createElement("p");
  status.className = "gdrive-status";
  status.textContent = gdriveEmail
    ? "Connected as " + gdriveEmail
    : "Connected to Google Drive";
  gdriveBody.appendChild(status);

  let actions = document.createElement("div");
  actions.className = "gdrive-actions";
  actions.appendChild(makeGdriveButton("Back up to Drive", false, gdriveBackup));
  actions.appendChild(
    makeGdriveButton("Restore from Drive", false, gdriveShowRestoreList),
  );
  actions.appendChild(makeGdriveButton("Sign out", true, gdriveSignOut));
  gdriveBody.appendChild(actions);

  gdriveProgressEl = document.createElement("p");
  gdriveProgressEl.className = "gdrive-progress";
  gdriveBody.appendChild(gdriveProgressEl);

  gdriveRestoreListEl = document.createElement("div");
  gdriveRestoreListEl.className = "roms-manage-list";
  gdriveBody.appendChild(gdriveRestoreListEl);
};

// --- Core-construction settings (GB renderer, GBA BIOS behavior) ---
// JS mirrors of the wasm-side option vars; they take effect the next time a
// core is constructed (ROM load / reset), matching the desktop config.

var gbFifo = true;
var gbaBiosMode = 0; // 0 = HLE, 1 = real BIOS, 2 = real BIOS boot + HLE calls
var gbaRunBios = true;
// Presentation-side only (the RAF loop polls _wasm_rumble and reacts here),
// so unlike its siblings it has no wasm setter in applySystemSettings.
var gbRumble = true;

const gbaRunBiosToggle = document.getElementById("gba-run-bios-toggle");
const gbRumbleToggle = document.getElementById("gb-rumble-toggle");

const applySystemSettings = () => {
  if (typeof Module === "undefined") return;
  if (Module._wasm_set_gb_renderer) Module._wasm_set_gb_renderer(gbFifo ? 1 : 0);
  if (Module._wasm_set_gba_bios_mode) Module._wasm_set_gba_bios_mode(gbaBiosMode);
  if (Module._wasm_set_gba_run_bios) Module._wasm_set_gba_run_bios(gbaRunBios ? 1 : 0);
};

const syncSystemSettingsUI = () => {
  for (let r of document.querySelectorAll('input[name="gb-renderer"]')) {
    r.checked = r.value === (gbFifo ? "fifo" : "scanline");
  }
  for (let r of document.querySelectorAll('input[name="gba-bios-mode"]')) {
    r.checked = Number(r.value) === gbaBiosMode;
  }
  gbaRunBiosToggle.checked = gbaRunBios;
  gbRumbleToggle.checked = gbRumble;
};

const saveSystemSettings = () => {
  applySystemSettings();
  if (db) dbPut("system", { gbFifo, gbaBiosMode, gbaRunBios, gbRumble });
};

for (let r of document.querySelectorAll('input[name="gb-renderer"]')) {
  r.addEventListener("change", () => {
    if (r.checked) {
      gbFifo = r.value === "fifo";
      saveSystemSettings();
    }
  });
}

for (let r of document.querySelectorAll('input[name="gba-bios-mode"]')) {
  r.addEventListener("change", () => {
    if (r.checked) {
      gbaBiosMode = Number(r.value);
      saveSystemSettings();
    }
  });
}

gbaRunBiosToggle.addEventListener("change", () => {
  gbaRunBios = gbaRunBiosToggle.checked;
  saveSystemSettings();
});

gbRumbleToggle.addEventListener("change", () => {
  gbRumble = gbRumbleToggle.checked;
  saveSystemSettings();
});

const loadSystemSettings = async () => {
  let s = await dbGet("system");
  if (s) {
    if (typeof s.gbFifo === "boolean") gbFifo = s.gbFifo;
    if ([0, 1, 2].includes(s.gbaBiosMode)) gbaBiosMode = s.gbaBiosMode;
    if (typeof s.gbaRunBios === "boolean") gbaRunBios = s.gbaRunBios;
    if (typeof s.gbRumble === "boolean") gbRumble = s.gbRumble;
  }
  syncSystemSettingsUI();
  applySystemSettings();
};

// --- Recent ROMs ---
// Storage layout (per-ROM, so the home grid never loads ROM bytes):
//   "recent"      metadata index only: [{ name, ts }], most-recent-first,
//                 capped at MAX_RECENT
//   "rom:<name>"  { name, data: Uint8Array } — the ROM image, fetched only
//                 at launch/backup time
//   "art:<name>"  Blob — optional box art (from a zip), fetched lazily by
//                 the grid without touching the ROM bytes
// Keeping bytes out of the index (and out of tile closures) is an iOS
// Safari memory-pressure fix: a handful of GBA ROMs held in the JS heap was
// enough to get the wasm JIT demoted.

const MAX_RECENT = 20;

const romKey = (name) => "rom:" + name;
const artKey = (name) => "art:" + name;

const getRecentMeta = async () => {
  return (await dbGet("recent")) || [];
};

// Fetch one ROM's bytes on demand. Returns null when the record is missing.
const getRomBytes = async (name) => {
  let rec = await dbGet(romKey(name));
  let d = rec?.data ?? null;
  if (d instanceof ArrayBuffer) d = new Uint8Array(d);
  return d instanceof Uint8Array && d.length ? d : null;
};

const getRomArt = async (name) => (await dbGet(artKey(name))) || null;

// Move `name` to the front of the metadata index (adding it if new) and
// evict past the cap — an evicted game loses its stored ROM + art records,
// but never its saves (romsForManagement still lists it for cleanup).
const bumpRecentIndex = async (name) => {
  let list = (await getRecentMeta()).filter((r) => r.name !== name);
  list.unshift({ name, ts: Date.now() });
  while (list.length > MAX_RECENT) {
    let evicted = list.pop();
    await dbDelete(romKey(evicted.name));
    await dbDelete(artKey(evicted.name));
  }
  await dbPut("recent", list);
};

const addRecentRom = async (name, bytes, art) => {
  // Bytes first, index second: an interruption leaves at worst an orphaned
  // rom: record, never an index entry pointing at nothing.
  await dbPut(romKey(name), { name, data: new Uint8Array(bytes) });
  if (art) await dbPut(artKey(name), art); // Blob (box art from a zip)
  await bumpRecentIndex(name);
  refreshHomeRecent();
};

// Recency bump for a ROM whose bytes are already stored (relaunch paths) —
// no multi-MB rewrite of the rom: record.
const touchRecent = async (name) => {
  await bumpRecentIndex(name);
  refreshHomeRecent();
};

// Launch a ROM by name, fetching its bytes from IndexedDB only now.
const launchRom = async (name) => {
  let data = await getRomBytes(name);
  if (!data) {
    showToast("This game's ROM is no longer stored — load the file again");
    return;
  }
  let ext = name.substring(name.lastIndexOf(".")).toLowerCase();
  let romFile = "rom" + ext;
  writeToFS(romFile, data);
  await touchRecent(name);
  loadRom(romFile, name);
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
  let list = (await getRecentMeta()).filter((r) => r.name !== name);
  await dbPut("recent", list);
  await dbDelete(romKey(name));
  await dbDelete(artKey(name));
  refreshHomeRecent();
};

// Object URLs for box-art thumbnails, revoked and rebuilt each render
let homeArtUrls = [];
// Render generation: a lazy art fetch that resolves after a newer render
// must not touch (or leak URLs into) the fresh grid.
let homeRenderGen = 0;

const refreshHomeRecent = async () => {
  if (!db) return;
  let roms = await getRecentMeta(); // metadata only — no ROM bytes
  let gen = ++homeRenderGen;
  homeArtUrls.forEach(URL.revokeObjectURL);
  homeArtUrls = [];
  homeRecent.innerHTML = "";
  if (roms.length === 0) {
    homeRecentWrap.hidden = true;
    return;
  }
  homeRecentWrap.hidden = false;
  updateStorageInfo();
  for (let { name: romName } of roms) {
    let system = systemOf(romName);
    let tile = document.createElement("div");
    tile.className = "home-tile";

    let launch = document.createElement("button");
    launch.type = "button";
    launch.className = "home-tile-launch";
    launch.title = romName; // full name on hover when truncated

    // Cartridge icon now, box art swapped in async if this game has any —
    // the art Blob lives in its own record so this never deserializes ROM
    // bytes just to draw the grid.
    let icon = document.createElement("span");
    icon.className = "cart cart-" + system.toLowerCase();
    getRomArt(romName).then((art) => {
      if (!art || gen !== homeRenderGen) return;
      let url = URL.createObjectURL(art);
      homeArtUrls.push(url);
      let img = document.createElement("img");
      img.className = "home-tile-art";
      img.src = url;
      img.alt = "";
      launch.replaceChild(img, icon);
    }).catch(() => {});

    let name = document.createElement("span");
    name.className = "home-tile-name";
    name.textContent = romName;

    let badge = document.createElement("span");
    badge.className = "home-tile-badge badge-" + system.toLowerCase();
    badge.textContent = system;

    launch.appendChild(icon);
    launch.appendChild(name);
    launch.appendChild(badge);
    launch.addEventListener("click", () => launchRom(romName));

    // 2-player local link cable: two linked cores of this ROM, one per
    // player. Trading needs both — this is how you test a link trade here.
    let link2p = document.createElement("button");
    link2p.type = "button";
    link2p.className = "home-tile-link";
    link2p.title = "2-player link cable (" + romName + ")";
    link2p.setAttribute("aria-label", "Start 2-player link: " + romName);
    link2p.textContent = "2P";
    link2p.addEventListener("click", async (e) => {
      e.stopPropagation();
      let data = await getRomBytes(romName);
      if (!data) {
        showToast("This game's ROM is no longer stored — load the file again");
        return;
      }
      launchLinkRom({ name: romName, data });
    });

    let del = document.createElement("button");
    del.type = "button";
    del.className = "home-tile-delete";
    del.title = "Remove from recent";
    del.setAttribute("aria-label", "Remove " + romName);
    del.innerHTML = "&times;";
    del.addEventListener("click", (e) => {
      e.stopPropagation();
      deleteRecent(romName);
    });

    tile.appendChild(launch);
    tile.appendChild(link2p);
    tile.appendChild(del);
    homeRecent.appendChild(tile);
  }
};

// Close any open modal on Escape
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    // Don't close settings if we're rebinding a key — the capture handler eats it
    if (!settingsModal.classList.contains("open") || kbSelection < 0) {
      closeSettingsModal();
    }
    closeSavesModal();
    closeRomsModal();
    closeUpdateModal();
  }
});

// --- Save state persistence ---

// Cheap change detector so the 5s autosave doesn't structured-clone the save
// and hit IndexedDB when nothing was written (the common case) — that write
// occasionally landed on a frame and cost a visible stutter. FNV-1a over the
// bytes (+ length) is a few hundred K ops on the largest saves, far cheaper
// than the clone + IDB transaction it lets us skip.
let lastSaveSig = null;
let lastSaveSigKey = null;
const saveSignature = (data) => {
  let h = 0x811c9dc5;
  for (let i = 0; i < data.length; i++) { h ^= data[i]; h = Math.imul(h, 0x01000193) >>> 0; }
  return h + ":" + data.length;
};

const persistSave = async (romName, originalName) => {
  let savName = romName.substring(0, romName.lastIndexOf(".")) + ".sav";
  try {
    let data = FS.readFile(savName);
    if (data && data.length > 0) {
      const sig = saveSignature(data);
      // Unchanged since the last persist for this game: the copy is already in
      // IndexedDB, so skip the write entirely.
      if (lastSaveSigKey === originalName && sig === lastSaveSig) return;
      lastSaveSig = sig;
      lastSaveSigKey = originalName;
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

// Overwrite the current game's battery save with imported .sav bytes (with the
// same name-mismatch guard as the "Import save file" button), then reboot the
// core so the game reloads from it. Shared by that button and by a dropped
// .sav file. Assumes a game is loaded (callers check currentOriginalName).
const applyImportedSave = async (bytes, fileName) => {
  if (!confirm("This will overwrite any existing save file for the current game. Continue?")) return;
  if (stripExt(fileName) !== stripExt(currentOriginalName)) {
    if (!confirm("You've selected a save file that doesn't match the name of the current game. Are you sure you want to overwrite the save?")) return;
  }
  let savName = currentRomName.substring(0, currentRomName.lastIndexOf(".")) + ".sav";
  writeToFS(savName, bytes);
  await dbPut("save:" + currentOriginalName, new Uint8Array(bytes));
  loadRom(currentRomName, currentOriginalName);
};

document.getElementById("load-save").addEventListener("click", () => {
  closeSavesModal(); // success reloads the game — don't leave the modal over it
  if (!currentRomName || !currentOriginalName) {
    alert("No ROM is loaded.");
    return;
  }
  // pickFile() must run synchronously in this tap handler: on iOS Safari a
  // preceding confirm()/alert() consumes the transient user activation, so
  // input.click() no longer opens the file picker. Do the overwrite prompts
  // AFTER a file is chosen (inside the callback), not before opening the picker.
  pickFile(".sav", (bytes, fileName) => applyImportedSave(bytes, fileName));
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

// --- Save-state slots ---
// Nine per-ROM slots. Slot 0 is the "Quick" slot and keeps the historical
// "state:<name>" key so existing quick-saves (and Drive sync) keep working;
// slots 1..8 add a ":slotN" suffix. The state blob stays a raw Uint8Array
// under that key (unchanged); a small thumbnail + timestamp are stored
// separately under "statemeta:..." so the state blobs and Drive sync are
// untouched.
const NUM_STATE_SLOTS = 9;
const slotStateKey = (name, slot) =>
  "state:" + name + (slot === 0 ? "" : ":slot" + slot);
const slotMetaKey = (name, slot) =>
  "statemeta:" + name + (slot === 0 ? "" : ":slot" + slot);

const fmtStateTime = (ts) => {
  try {
    return new Date(ts).toLocaleString([], {
      month: "short", day: "numeric", hour: "2-digit", minute: "2-digit",
    });
  } catch {
    return "";
  }
};

// Grab the current framebuffer as a small thumbnail dataURL (or null). Reads
// the wasm framebuffer pointer (color-corrected, produced off the hot path),
// so it works whether the game is running or paused and doesn't need the
// canvas to have preserveDrawingBuffer.
const captureThumbnail = () => {
  if (typeof Module === "undefined" || !Module._wasm_fb_ptr) return null;
  const ptr = Module._wasm_fb_ptr();
  if (!ptr) return null;
  const [w, h] = nativeRes();
  const heap = new Uint8Array(Module.memory.buffer, ptr, w * h * 4);
  const full = document.createElement("canvas");
  full.width = w;
  full.height = h;
  const fctx = full.getContext("2d");
  const img = fctx.createImageData(w, h);
  img.data.set(heap);
  for (let i = 3; i < img.data.length; i += 4) img.data[i] = 255; // opaque
  fctx.putImageData(img, 0, 0);
  const tw = 160;
  const th = Math.round((tw * h) / w);
  const small = document.createElement("canvas");
  small.width = tw;
  small.height = th;
  const sctx = small.getContext("2d");
  sctx.imageSmoothingEnabled = false;
  sctx.drawImage(full, 0, 0, tw, th);
  try {
    return small.toDataURL("image/webp", 0.7);
  } catch {
    return small.toDataURL("image/png");
  }
};

// Save the running core into a slot (state blob + thumbnail/timestamp meta).
const saveToSlot = async (slot) => {
  if (!currentOriginalName) return false;
  const bytes = captureStateBytes();
  if (!bytes) {
    showToast("Couldn't capture the emulator state");
    return false;
  }
  const thumb = captureThumbnail();
  try {
    await dbPut(slotStateKey(currentOriginalName, slot), bytes);
    await dbPut(slotMetaKey(currentOriginalName, slot), { thumb, ts: Date.now() });
    return true;
  } catch (e) {
    showToast("Save state failed: " + e.message);
    return false;
  }
};

// Apply a slot's state to the running game. The core validates the image
// (version, core kind, ROM checksum, payload hash) and leaves itself untouched
// when it doesn't match — e.g. a state saved for a different ROM.
const loadFromSlot = async (slot) => {
  if (!currentOriginalName) return false;
  let bytes = null;
  try {
    bytes = await dbGet(slotStateKey(currentOriginalName, slot));
  } catch (e) {
    showToast("Load state failed: " + e.message);
    return false;
  }
  if (!bytes) {
    showToast(slot === 0 ? "No saved state for this game" : "Slot " + (slot + 1) + " is empty");
    return false;
  }
  const ok = applyStateBytes(bytes);
  showToast(ok ? "State loaded" : "State didn't match this game");
  return ok;
};

document.getElementById("save-state").addEventListener("click", async () => {
  menuDropdown.hidden = true;
  if (!currentOriginalName) return;
  if (await saveToSlot(0)) showToast("State saved");
});

document.getElementById("load-state").addEventListener("click", async () => {
  menuDropdown.hidden = true;
  if (!currentOriginalName) return;
  await loadFromSlot(0);
});

// --- Save States modal (9-slot grid with thumbnails) ---
const statesModal = document.getElementById("states-modal");
const statesGrid = document.getElementById("states-grid");
const statesSaveBtn = document.getElementById("states-save");
const statesLoadBtn = document.getElementById("states-load");
const statesEmpty = document.getElementById("states-empty");
let selectedSlot = 0;
let slotHasState = [];

const updateStatesButtons = () => {
  const loaded = !!currentOriginalName;
  statesSaveBtn.disabled = !loaded;
  statesLoadBtn.disabled = !loaded || !slotHasState[selectedSlot];
};

const selectSlot = (s) => {
  selectedSlot = s;
  for (const el of statesGrid.children) {
    el.classList.toggle("selected", Number(el.dataset.slot) === s);
  }
  updateStatesButtons();
};

const renderStatesGrid = async () => {
  const name = currentOriginalName;
  statesEmpty.hidden = !!name;
  statesGrid.hidden = !name;
  statesGrid.innerHTML = "";
  slotHasState = [];
  if (!name) {
    updateStatesButtons();
    return;
  }
  for (let s = 0; s < NUM_STATE_SLOTS; s++) {
    const bytes = await dbGet(slotStateKey(name, s)).catch(() => null);
    const meta = await dbGet(slotMetaKey(name, s)).catch(() => null);
    const has = !!bytes;
    slotHasState[s] = has;
    const cell = document.createElement("button");
    cell.type = "button";
    cell.className =
      "state-slot" + (has ? "" : " empty") + (s === selectedSlot ? " selected" : "");
    cell.dataset.slot = s;
    const thumb =
      meta && meta.thumb
        ? `<img class="slot-thumb" src="${meta.thumb}" alt="">`
        : `<div class="slot-thumb"></div>`;
    const when =
      meta && meta.ts ? fmtStateTime(meta.ts) : has ? "saved" : "empty";
    const label = s === 0 ? "1 · Quick" : String(s + 1);
    cell.innerHTML =
      thumb +
      `<div class="slot-label"><span class="slot-num">${label}</span><span>${when}</span></div>`;
    cell.addEventListener("click", () => selectSlot(s));
    statesGrid.appendChild(cell);
  }
  updateStatesButtons();
};

const openStatesModal = () => {
  menuDropdown.hidden = true;
  statesModal.classList.add("open");
  trapFocus(statesModal);
  renderStatesGrid();
};

const closeStatesModal = () => {
  statesModal.classList.remove("open");
  releaseFocus(statesModal);
};

document.getElementById("open-states").addEventListener("click", openStatesModal);
document.getElementById("states-close").addEventListener("click", closeStatesModal);
statesModal.addEventListener("click", (e) => {
  if (e.target === statesModal) closeStatesModal();
});

statesSaveBtn.addEventListener("click", async () => {
  if (!currentOriginalName) return;
  if (await saveToSlot(selectedSlot)) {
    showToast("Saved to slot " + (selectedSlot + 1));
    await renderStatesGrid();
  }
});

statesLoadBtn.addEventListener("click", async () => {
  if (await loadFromSlot(selectedSlot)) closeStatesModal();
});

// --- Report a Bug modal ---
// Builds a downloadable report bundle {title, description, diagnostics, save
// state} entirely client-side — nothing is transmitted. The save state carries
// only emulator RAM/registers + a screenshot, never the ROM. A scrubber lets
// the user pick the moment the bug happened from the rewind history: slider 0
// is "now" (live state), 1..N are rewind samples (0..N-1, newest first).
const reportModal = document.getElementById("report-modal");
const reportTitle = document.getElementById("report-title");
const reportDesc = document.getElementById("report-desc");
const reportSlider = document.getElementById("report-slider");
const reportWhen = document.getElementById("report-when");
const reportPreview = document.getElementById("report-preview");
const reportScrub = document.getElementById("report-scrub");
const reportScrubHint = document.getElementById("report-scrub-hint");
let reportWasPaused = false;
let reportSamples = 0;
let reportThumbs = null; // packed BGR555 thumbnails copied out of wasm
let reportThumbW = 0;
let reportThumbH = 0;

const bgr555ToImageData = (src, off, w, h) => {
  const out = new Uint8ClampedArray(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    const v = src[off + i * 2] | (src[off + i * 2 + 1] << 8);
    out[i * 4] = Math.round((v & 31) * (255 / 31));
    out[i * 4 + 1] = Math.round(((v >> 5) & 31) * (255 / 31));
    out[i * 4 + 2] = Math.round(((v >> 10) & 31) * (255 / 31));
    out[i * 4 + 3] = 255;
  }
  return new ImageData(out, w, h);
};

const drawReportLivePreview = () => {
  if (typeof Module === "undefined" || !Module._wasm_fb_ptr) return;
  const ptr = Module._wasm_fb_ptr();
  if (!ptr) return;
  const [w, h] = nativeRes();
  const heap = new Uint8Array(Module.memory.buffer, ptr, w * h * 4);
  reportPreview.width = w;
  reportPreview.height = h;
  const ctx = reportPreview.getContext("2d");
  const img = ctx.createImageData(w, h);
  img.data.set(heap);
  for (let i = 3; i < img.data.length; i += 4) img.data[i] = 255;
  ctx.putImageData(img, 0, 0);
};

const drawReportSamplePreview = (sample) => {
  if (!reportThumbs) return;
  const stride = reportThumbW * reportThumbH * 2;
  const img = bgr555ToImageData(reportThumbs, sample * stride, reportThumbW, reportThumbH);
  reportPreview.width = reportThumbW;
  reportPreview.height = reportThumbH;
  reportPreview.getContext("2d").putImageData(img, 0, 0);
};

const updateReportPreview = () => {
  const v = Number(reportSlider.value);
  if (v === 0) {
    reportWhen.textContent = "now";
    drawReportLivePreview();
  } else {
    const sample = v - 1;
    const tenths = Module._wasm_rewind_scrub_seconds_ago(sample);
    reportWhen.textContent = (tenths / 10).toFixed(1) + "s ago";
    drawReportSamplePreview(sample);
  }
};

reportSlider.addEventListener("input", updateReportPreview);

const openReportModal = () => {
  menuDropdown.hidden = true;
  reportWasPaused = paused;
  paused = true; // freeze emulation + the rewind ring while scrubbing
  reportSamples = 0;
  reportThumbs = null;
  if (currentOriginalName && Module._wasm_rewind_scrub_generate) {
    reportSamples = Module._wasm_rewind_scrub_generate(48);
    if (reportSamples > 0) {
      reportThumbW = Module._wasm_rewind_scrub_thumb_w();
      reportThumbH = Module._wasm_rewind_scrub_thumb_h();
      const ptr = Module._wasm_rewind_scrub_thumbs_ptr();
      const len = reportSamples * reportThumbW * reportThumbH * 2;
      reportThumbs = new Uint8Array(Module.memory.buffer, ptr, len).slice();
    }
  }
  reportSlider.max = String(reportSamples); // 0..N, 0 = now
  reportSlider.value = "0";
  reportScrub.classList.toggle("disabled", !currentOriginalName);
  reportScrubHint.hidden = reportSamples > 0;
  updateReportPreview();
  reportModal.classList.add("open");
  trapFocus(reportModal);
};

const closeReportModal = () => {
  reportModal.classList.remove("open");
  releaseFocus(reportModal);
  reportThumbs = null;
  paused = reportWasPaused; // restore the prior run/pause state
};

document.getElementById("report-bug").addEventListener("click", openReportModal);
document.getElementById("report-close").addEventListener("click", closeReportModal);
document.getElementById("report-cancel").addEventListener("click", closeReportModal);
reportModal.addEventListener("click", (e) => {
  if (e.target === reportModal) closeReportModal();
});

const base64FromBytes = (bytes) => {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
};

document.getElementById("report-download").addEventListener("click", async () => {
  if (!currentOriginalName) {
    showToast("Load a game first");
    return;
  }
  const v = Number(reportSlider.value);
  let stateBytes = null;
  let savedFrom = "current frame";
  if (v === 0) {
    stateBytes = captureStateBytes();
  } else {
    const sample = v - 1;
    const sz = Module._wasm_rewind_scrub_state_size(sample);
    if (sz > 0) {
      stateBytes = new Uint8Array(Module.memory.buffer, Module._wasm_state_data(), sz).slice();
      savedFrom = (Module._wasm_rewind_scrub_seconds_ago(sample) / 10).toFixed(1) + "s before report";
    }
  }
  const report = {
    kind: "dingbat-bug-report",
    version: 1,
    createdAt: new Date().toISOString(),
    title: reportTitle.value.trim(),
    description: reportDesc.value.trim(),
    game: currentOriginalName,
    savedFrom,
    diagnostics: await logContext(),
    // Emulator save state (RAM/registers + screenshot). Never the ROM.
    state: stateBytes ? base64FromBytes(stateBytes) : null,
  };
  const blob = new Blob([JSON.stringify(report, null, 2)], { type: "application/json" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  a.download = "dingbat-bugreport-" + stripExt(currentOriginalName) + "-" + stamp + ".json";
  a.click();
  URL.revokeObjectURL(a.href);
  showToast("Report downloaded");
  closeReportModal();
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

// Apply an imported .state image to the running game (not persisted — use Save
// State to keep it). Shared by the "Import state" button and a dropped .state.
const applyImportedState = (bytes) => {
  showToast(applyStateBytes(bytes) ? "State loaded" : "State didn't match this game");
};

document.getElementById("import-state").addEventListener("click", () => {
  menuDropdown.hidden = true;
  if (!currentOriginalName) return;
  pickFile(".state", (bytes) => applyImportedState(bytes));
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
  audioSaveTimer = setTimeout(
    () => dbPut("audio", { volume, muted, pitchCorrectFF }), 250);
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
  if (s && typeof s.pitchCorrectFF === "boolean") pitchCorrectFF = s.pitchCorrectFF;
  if (pcffToggle) pcffToggle.checked = pitchCorrectFF;
  applyPitchCorrectFF();
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

// --- Color correction (LCD gamma) toggle ---
// The wasm core keeps a single BGR555->RGBA lookup table used by every present
// path; _wasm_set_color_correction rebuilds it. Default on, matching desktop.
var colorCorrect = true;
const ccToggle = document.getElementById("color-correct-toggle");

const applyColorCorrect = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_color_correction) {
    Module._wasm_set_color_correction(colorCorrect ? 1 : 0);
  }
};

ccToggle.addEventListener("change", () => {
  colorCorrect = ccToggle.checked;
  applyColorCorrect();
  drawGame();  // reflect the shader-uniform change even while paused
  if (db) dbPut("colorCorrect", colorCorrect);
});

const loadColorCorrect = async () => {
  let v = await dbGet("colorCorrect");
  if (typeof v === "boolean") colorCorrect = v;
  ccToggle.checked = colorCorrect;
  applyColorCorrect();
};

// --- Pitch-correct fast-forward (WSOLA time-stretch at 2x) ---
// Local audio preference persisted in the "audio" IDB record alongside
// volume/mute. When on, the core time-stretches 2x audio so it keeps its pitch
// instead of jumping an octave; independent of the rollback-synced 2x state.
var pitchCorrectFF = false;
const pcffToggle = document.getElementById("pitch-correct-ff-toggle");

const applyPitchCorrectFF = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_pitch_correct_ff) {
    Module._wasm_set_pitch_correct_ff(pitchCorrectFF ? 1 : 0);
  }
};

if (pcffToggle) {
  pcffToggle.addEventListener("change", () => {
    pitchCorrectFF = pcffToggle.checked;
    applyPitchCorrectFF();
    saveAudioSettings();
  });
}

// --- Video effects (integer scaling, scanline overlay) ---
// Integer scaling pins the canvas's CSS size to a whole multiple of the
// emulated resolution. The scanline overlay is a separate element JS keeps
// aligned over the canvas (a WebGL canvas can't carry pseudo-elements), with
// background-size set so one line lands on each emulated pixel row.

var integerScale = false;
var scanlines = false;
var motionBlur = false;
var ambientGlow = false;
var upscaleFilter = "none";  // "none" | "hq4x" | "xbr" — GPU upscale filter
// A smoothing filter and integer-scale pinning fight (integer pinning throws
// away the fractional smoothing), so a filter suspends integer-scale layout.
const filterActive = () => upscaleFilter !== "none";

// #canvas backing store = native resolution * GL_SCALE. The game texture is
// sampled NEAREST, so this is a crisp integer upscale (identical pixels to the
// old SDL logical-size scaling) that also keeps screenshots at their prior size.
const GL_SCALE = 4;

const canvasEl = document.getElementById("canvas");
const stageEl = document.getElementById("stage");
const glowCanvas = document.getElementById("glow-canvas");
const glowCtx = glowCanvas.getContext("2d");
const integerScaleToggle = document.getElementById("integer-scale-toggle");
const scanlinesToggle = document.getElementById("scanlines-toggle");
const motionBlurToggle = document.getElementById("motion-blur-toggle");
const ambientGlowToggle = document.getElementById("ambient-glow-toggle");
const upscaleFilterSelect = document.getElementById("upscale-filter-select");

// Native resolution of the running system (GBA 240x160, GB/GBC 160x144)
const nativeRes = () =>
  currentRomName && extOf(currentRomName) !== ".gba" ? [160, 144] : [240, 160];

const updateCanvasScaling = () => {
  // WebGL2 present: WE own the #canvas backing store now (SDL renders to the
  // hidden #sdl-canvas). Pin it to the native resolution * GL_SCALE — NEAREST
  // texture sampling makes that a crisp integer upscale, and the extra pixels
  // keep screenshots at their previous size. Only touch it when it actually
  // changes: assigning canvas.width/height resets the GL drawing buffer.
  presentDirty = true; // resize can wipe the backing — repaint on the next tick
  const running0 =
    document.body.classList.contains("running") && !!currentRomName;
  if (running0 && !linkMode && !rollbackMode) {
    const [nw, nh] = nativeRes();
    const bw = nw * GL_SCALE, bh = nh * GL_SCALE;
    if (canvasEl.width !== bw) canvasEl.width = bw;
    if (canvasEl.height !== bh) canvasEl.height = bh;
  }
  // Size the canvas box in JS from two live measurements: the stage's actual
  // box and the canvas backing store's actual shape (native per system:
  // GBA 3:2, GB 10:9). CSS alone cannot do this safely — with
  // aspect-ratio, a max-height clamp squashes the picture instead of
  // shrinking it, which stretched GB games on phone portrait where the
  // in-flow touch controls leave the stage short. The --game-ar variable is
  // still published for the stylesheet's pre-JS fallback rules.
  if (canvasEl.width > 0 && canvasEl.height > 0) {
    canvasEl.style.setProperty("--game-ar", canvasEl.width / canvasEl.height);
  }
  const ar =
    canvasEl.width > 0 && canvasEl.height > 0
      ? canvasEl.width / canvasEl.height
      : 1.5;
  const running =
    document.body.classList.contains("running") && !!currentRomName;
  if (integerScale && running && !filterActive()) {
    const [w, h] = nativeRes();
    const k = Math.max(
      1,
      Math.floor(Math.min(stageEl.clientWidth / w, stageEl.clientHeight / h))
    );
    canvasEl.style.width = k * w + "px";
    canvasEl.style.height = k * h + "px";
  } else if (running) {
    // Contain-fit: as large as the stage allows without changing shape
    const w = Math.min(stageEl.clientWidth, stageEl.clientHeight * ar);
    canvasEl.style.width = w + "px";
    canvasEl.style.height = w / ar + "px";
  } else {
    canvasEl.style.width = "";
    canvasEl.style.height = "";
  }
  // Scanlines are now drawn by the WebGL2 shader (uniform-gated), not a DOM
  // overlay — nothing to position here. Ambient glow stays a separate blurred
  // canvas behind the game; keep it pinned to the canvas rect.
  const singleCore = running && !linkMode && !rollbackMode;
  if (ambientGlow && singleCore) {
    const c = canvasEl.getBoundingClientRect();
    const s = stageEl.getBoundingClientRect();
    glowCanvas.style.left = c.left - s.left + "px";
    glowCanvas.style.top = c.top - s.top + "px";
    glowCanvas.style.width = c.width + "px";
    glowCanvas.style.height = c.height + "px";
  }
  glowCanvas.hidden = !(ambientGlow && singleCore);
};

// Sample a coarse grid from the wasm-side presented framebuffer into the glow
// canvas. Called from the RAF loop but throttled to ~10 Hz; each sample is
// blended over the previous one so the glow eases between scenes instead of
// flickering. The buffer is stale-while-paused/static, which reads correctly.
const glowBuf = document.createElement("canvas");
glowBuf.width = glowCanvas.width;
glowBuf.height = glowCanvas.height;
const glowBufCtx = glowBuf.getContext("2d");
let glowImage = null;
let glowTick = 0;
let glowFresh = true; // first sample after enabling paints at full alpha

const updateGlow = () => {
  if (glowCanvas.hidden || !currentRomName) return;
  if (typeof Module === "undefined" || !Module._wasm_fb_ptr) return;
  if (glowTick++ % 6 !== 0) return;
  const ptr = Module._wasm_fb_ptr();
  if (!ptr) return;
  const [w, h] = nativeRes();
  const heap = new Uint8Array(Module.memory.buffer, ptr, w * h * 4);
  const gw = glowCanvas.width;
  const gh = glowCanvas.height;
  if (!glowImage) glowImage = glowBufCtx.createImageData(gw, gh);
  const d = glowImage.data;
  for (let y = 0; y < gh; y++) {
    const sy = Math.floor(((y + 0.5) * h) / gh);
    for (let x = 0; x < gw; x++) {
      const sx = Math.floor(((x + 0.5) * w) / gw);
      const si = (sy * w + sx) * 4;
      const di = (y * gw + x) * 4;
      const r = heap[si], g = heap[si + 1], b = heap[si + 2];
      // Saturation boost, folded in here (384 px) so the CSS filter is just the
      // blur — one compositor pass instead of blur + saturate. Uint8ClampedArray
      // clamps + rounds the assignment. Luma-preserving, matches saturate(1.5).
      const luma = 0.299 * r + 0.587 * g + 0.114 * b;
      d[di] = luma + (r - luma) * 1.5;
      d[di + 1] = luma + (g - luma) * 1.5;
      d[di + 2] = luma + (b - luma) * 1.5;
      d[di + 3] = 255;
    }
  }
  glowBufCtx.putImageData(glowImage, 0, 0);
  glowCtx.globalAlpha = glowFresh ? 1 : 0.3;
  glowCtx.drawImage(glowBuf, 0, 0);
  glowFresh = false;
};

// --- WebGL2 game presentation ---
// Our own WebGL2 context on #canvas draws the single-core game view (SDL is no
// longer the visual path). The wasm core hands us the RAW BGR555 framebuffer
// (Module._wasm_game_fb_ptr); we upload it to an R16UI integer texture and a
// GLSL ES 300 fragment shader unpacks the 5-bit channels and applies the LCD
// color-correction (same math as the desktop shader / the old CPU LUT) plus
// scanlines — both uniform-gated. This removes the per-frame CPU color LUT the
// core used to run and replaces the DOM scanline overlay. Link / rollback modes
// keep their own 2D-canvas blit path (deferred — see notes below).
// WebGL2 game presenter (shared with the embed — see web/glpresent.js).
const glRenderer = createGlRenderer(canvasEl, nativeRes, log);

// Present one game frame via WebGL2. No-op in link / rollback modes (they blit
// their own 2D canvases) and when no game is loaded.
// True when the next RAF tick must present even if emulation stepped no new
// frame (first paint, resize wiped the canvas backing, a display setting
// changed). Cleared after each present.
var presentDirty = true;
var presentSkip = false;
var presentSkips = 0;

const drawGame = () => {
  if (!currentRomName || linkMode || rollbackMode) return;
  glRenderer.draw({
    colorCorrect,
    panelGbc: Module._wasm_panel_gbc
      ? Module._wasm_panel_gbc() === 1
      : extOf(currentRomName) !== ".gba",
    // An upscale filter suspends scanlines (smoothing + row-darkening fight
    // each other); the toggle keeps its state for when the filter turns off.
    scanlines: scanlines && !filterActive(),
    filter: upscaleFilter,
  });
};

// Gray out the toggles an active upscale filter suspends (integer scaling and
// scanlines) so the modal shows they're not in effect right now.
const updateSuspendedVideoToggles = () => {
  const sus = filterActive();
  for (const [rowId, input] of [
    ["integer-scale-row", integerScaleToggle],
    ["scanlines-row", scanlinesToggle],
  ]) {
    document.getElementById(rowId)?.classList.toggle("suspended", sus);
    input.disabled = sus;
  }
};

const saveVideoSettings = () => {
  if (db) dbPut("video", { integerScale, scanlines, motionBlur, ambientGlow, upscaleFilter });
};

const applyMotionBlur = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_frame_blend) {
    Module._wasm_set_frame_blend(motionBlur ? 1 : 0);
  }
};

integerScaleToggle.addEventListener("change", () => {
  integerScale = integerScaleToggle.checked;
  updateCanvasScaling();
  saveVideoSettings();
});

scanlinesToggle.addEventListener("change", () => {
  scanlines = scanlinesToggle.checked;
  updateCanvasScaling();
  drawGame();  // scanlines are a shader uniform now — redraw to show it live
  saveVideoSettings();
});

motionBlurToggle.addEventListener("change", () => {
  motionBlur = motionBlurToggle.checked;
  applyMotionBlur();
  saveVideoSettings();
});

ambientGlowToggle.addEventListener("change", () => {
  ambientGlow = ambientGlowToggle.checked;
  glowFresh = true; // repaint at full strength rather than fading in
  updateCanvasScaling();
  saveVideoSettings();
});

upscaleFilterSelect.addEventListener("change", () => {
  upscaleFilter = upscaleFilterSelect.value;
  updateSuspendedVideoToggles();
  updateCanvasScaling();  // filter suspends integer-scale layout pinning
  drawGame();             // filter is a shader uniform — redraw to show it live
  saveVideoSettings();
});

const loadVideoSettings = async () => {
  let v = await dbGet("video");
  if (v) {
    integerScale = !!v.integerScale;
    scanlines = !!v.scanlines;
    motionBlur = !!v.motionBlur;
    ambientGlow = !!v.ambientGlow;
    if (typeof v.upscaleFilter === "string") upscaleFilter = v.upscaleFilter;
  }
  integerScaleToggle.checked = integerScale;
  scanlinesToggle.checked = scanlines;
  motionBlurToggle.checked = motionBlur;
  ambientGlowToggle.checked = ambientGlow;
  upscaleFilterSelect.value = upscaleFilter;
  updateSuspendedVideoToggles();
  applyMotionBlur();
  updateCanvasScaling();
};

window.addEventListener("resize", updateCanvasScaling);
new ResizeObserver(updateCanvasScaling).observe(stageEl);

// WebKit applies the SDL window resize to the canvas attributes a beat AFTER
// initFromEmscripten returns (Chromium is synchronous), so the sizing pass in
// loadRom can run against the previous system's backing shape. Watch for the
// late change from the RAF loop and re-fit when it lands.
let seenCanvasW = 0;
let seenCanvasH = 0;
const watchCanvasBacking = () => {
  if (canvasEl.width !== seenCanvasW || canvasEl.height !== seenCanvasH) {
    seenCanvasW = canvasEl.width;
    seenCanvasH = canvasEl.height;
    updateCanvasScaling();
  }
};

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

// Online input-rollback mode: this player's currently-held buttons as a
// bitmask (bit i = input id i). Captured from every input source so the RAF
// loop can hand it to rollback_tick and ship it to the peer each frame.
var rollbackMode = false;
var localButtons = 0;
var rbWasLinked = false;  // the games have actually communicated over the link
var rbLastTransfers = 0;  // last-seen SIO transfer count (activity probe)
var rbLastActivity = 0;   // timestamp of the last transfer-count change
// The ONLY signal used to auto-end an online link is hardware activity on the
// emulated serial cable (_rollback_transfers = completed SIO byte-transfers).
// No game-specific knowledge — no memory addresses, ROM/title detection, or
// protocol sniffing — so this behaves the same for any linked GB/GBC/GBA title.
//
// Knowing when a link is "done" is a judgement call because games pace the
// cable very differently, so we adapt to observed activity with two windows:
//  - QUIET: before the cable has seen sustained use, stay lenient. A game can
//    hold a link open yet idle for a long time before real traffic flows (e.g.
//    a player walking to an in-game link terminal), so a short window here would
//    cut the link before it is ever used.
//  - ACTIVE: once a meaningful amount of traffic has crossed (rbLinkWasActive),
//    tighten up. A game that is genuinely linking keeps the cable busy — every
//    frame, or in periodic bursts — so any transfer keeps resetting the timer;
//    the window only elapses once the cable truly falls silent (the players
//    ended the link / walked away), and then it disconnects promptly.
// Both windows reset on every transfer, so neither fires mid-activity. Erring
// long is harmless: a late auto-disconnect just leaves an already-idle link up
// a little longer, and the manual disconnect button is always available.
var rbLinkWasActive = false; // the cable has seen a sustained burst of traffic
const RB_IDLE_QUIET_MS  = 90000; // silence tolerated before the link is used
const RB_IDLE_ACTIVE_MS = 20000; // silence tolerated after real traffic flowed
const RB_ACTIVE_LINK_TRANSFERS = 300; // SIO transfers that mean "link in real use"
const noteLocalButton = (inputId, down) => {
  if (down) localButtons |= 1 << inputId;
  else localButtons &= ~(1 << inputId);
};

// Route player-1 input (keyboard, touch controls) to the right core: the
// single running core normally, core 0 in 2P link mode, or — in online
// rollback mode — captured into localButtons (the RAF loop feeds the core).
const routeP1Input = (inputId, down) => {
  if (rollbackMode) {
    noteLocalButton(inputId, down);
  } else if (linkMode) {
    // Keyboard drives whichever linked screen has focus (click to switch);
    // a gamepad, if present, always drives P2.
    if (Module._link_input) Module._link_input(linkFocus, inputId, down ? 1 : 0);
  } else {
    Module._setInput(inputId, down ? 1 : 0);
  }
};

// JS-side keyboard handler: intercepts bound keys before Emscripten's SDL layer
// and calls _setInput directly. This is authoritative for keyboard input.
const gameKeyHandler = (e, down) => {
  if (settingsModal.classList.contains("open")) return;
  // Don't hijack keystrokes while the user is typing in a text field (e.g. the
  // room-code input): letters like A/S/Z/X are default game-input keys, and
  // preventDefault here would swallow them before they reach the field.
  const t = e.target;
  if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
  let inputId = codeLookup[e.code];
  if (inputId !== undefined && typeof Module !== "undefined" && Module._setInput) {
    e.preventDefault();
    e.stopImmediatePropagation();
    routeP1Input(inputId, down);
  }
};
document.addEventListener("keydown", (e) => gameKeyHandler(e, true), true);
document.addEventListener("keyup", (e) => gameKeyHandler(e, false), true);

const kbBindingsDiv = document.getElementById("kb-bindings");
const kbPreset = document.getElementById("kb-preset");

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
    btn.textContent = sdlName(activeBindings[i]);
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

const applyKeybindings = (bindings) => {
  activeBindings = [...bindings];
  rebuildLookup();
};

// Rebinds commit immediately: apply to the live bindings and persist
const commitBindings = (bindings) => {
  applyKeybindings(bindings);
  if (db) dbPut("keybindings", activeBindings);
  kbPreset.value = detectPreset(activeBindings);
  renderKbBindings();
};

const kbKeyHandler = (e) => {
  if (kbSelection < 0) return;
  let sdl = JS_TO_SDL[e.code];
  if (sdl === undefined) return;
  e.preventDefault();
  e.stopImmediatePropagation();
  let bindings = [...activeBindings];
  // Remove any existing binding for this key
  for (let i = 0; i < bindings.length; i++) {
    if (bindings[i] === sdl) bindings[i] = -1;
  }
  bindings[kbSelection] = sdl;
  // Auto-advance to next input
  if (kbSelection < INPUT_NAMES.length - 1) {
    kbSelection++;
  } else {
    kbSelection = -1;
  }
  commitBindings(bindings);
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

// --- Opaque controls in landscape (solid instead of see-through buttons) ---
const opaqueControlsToggle = document.getElementById("opaque-controls-toggle");

const applyOpaqueControls = (on) => {
  document.body.classList.toggle("opaque-controls", on);
  opaqueControlsToggle.checked = on;
};

opaqueControlsToggle.addEventListener("change", async () => {
  applyOpaqueControls(opaqueControlsToggle.checked);
  await dbPut("opaque-controls", opaqueControlsToggle.checked);
});

const loadOpaqueControlsFromStorage = async () => {
  applyOpaqueControls(!!(await dbGet("opaque-controls")));
};

// --- Hide touch controls while a game controller is connected (default on) ---
// pollGamepads maintains body.gamepad-hides-touch from the live connected
// state; the CSS gate only bites in the touch layout, so desktop is unaffected.
const hideTouchOnGamepadToggle = document.getElementById("hide-touch-on-gamepad-toggle");
var hideTouchOnGamepad = true;

const applyHideTouchOnGamepad = (on) => {
  hideTouchOnGamepad = on;
  hideTouchOnGamepadToggle.checked = on;
  if (!on) document.body.classList.remove("gamepad-hides-touch");
  // (re-enable happens on the next pollGamepads tick)
};

hideTouchOnGamepadToggle.addEventListener("change", async () => {
  applyHideTouchOnGamepad(hideTouchOnGamepadToggle.checked);
  await dbPut("hide-touch-on-gamepad", hideTouchOnGamepadToggle.checked);
});

const loadHideTouchOnGamepadFromStorage = async () => {
  const v = await dbGet("hide-touch-on-gamepad");
  applyHideTouchOnGamepad(typeof v === "boolean" ? v : true);
};

// --- Touch direction input: d-pad (default) vs joystick + joystick behavior ---
// Two IndexedDB keys: "control-style" ("dpad" | "joystick") and
// "joystick-mode" ("fixed" | "floating"). body.joystick-controls swaps the
// on-screen d-pad for the joystick; the behavior row only shows while the
// joystick is selected.
let controlStyle = "dpad";
let joystickMode = "fixed";
const controlStyleChips = Array.from(
  document.querySelectorAll("#control-style-picker .choice-chip"));
const joystickModeChips = Array.from(
  document.querySelectorAll("#joystick-mode-picker .choice-chip"));
const joystickModeRow = document.getElementById("joystick-mode-row");

const syncChipGroup = (chips, value) => {
  for (const chip of chips) {
    const on = chip.dataset.value === value;
    chip.classList.toggle("selected", on);
    chip.setAttribute("aria-checked", on ? "true" : "false");
  }
};

const applyControlStyle = (style) => {
  controlStyle = style === "joystick" ? "joystick" : "dpad";
  document.body.classList.toggle("joystick-controls", controlStyle === "joystick");
  syncChipGroup(controlStyleChips, controlStyle);
  joystickModeRow.classList.toggle("hidden", controlStyle !== "joystick");
  // Swapping styles mid-touch must not leave direction bits stuck down
  joystickForceRelease();
};

const applyJoystickMode = (mode) => {
  joystickMode = mode === "floating" ? "floating" : "fixed";
  syncChipGroup(joystickModeChips, joystickMode);
};

controlStyleChips.forEach((chip) =>
  chip.addEventListener("click", async () => {
    applyControlStyle(chip.dataset.value);
    await dbPut("control-style", controlStyle);
  })
);

joystickModeChips.forEach((chip) =>
  chip.addEventListener("click", async () => {
    applyJoystickMode(chip.dataset.value);
    await dbPut("joystick-mode", joystickMode);
  })
);

const loadControlStyleFromStorage = async () => {
  applyControlStyle(await dbGet("control-style"));
  applyJoystickMode(await dbGet("joystick-mode"));
};

// --- Chrome theme (background / buttons / menus color scheme) ---
// Persisted in localStorage — NOT IndexedDB — so the inline <head> script can
// apply it synchronously before first paint (no flash of the wrong theme).
// "amber" is the default and maps to no data-theme attribute at all.
const THEME_KEY = "dingbat_theme";
const THEME_NAMES = ["amber", "black", "light", "indigo", "fuchsia", "glacier", "emerald"];
const themeChips = Array.from(document.querySelectorAll("#theme-picker .theme-chip"));
// Null on iOS standalone: the <head> boot script removes the meta there (iOS
// paints the below-the-layout-viewport band with theme-color, drawing an
// opaque bar over our 100vh body's bottom edge — see the boot script note).
const themeColorMeta = document.querySelector('meta[name="theme-color"]');

const applyTheme = (name) => {
  if (!THEME_NAMES.includes(name)) name = "amber";
  if (name === "amber") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", name);
  for (const chip of themeChips) {
    const on = chip.dataset.themeName === name;
    chip.classList.toggle("selected", on);
    chip.setAttribute("aria-checked", on ? "true" : "false");
  }
  // Browser/PWA chrome color follows the page background. Derived from the
  // live token so the CSS stays the single source of truth (the inline boot
  // script's map is only a pre-CSS hint).
  if (themeColorMeta) {
    themeColorMeta.content =
      getComputedStyle(document.documentElement).getPropertyValue("--bg").trim();
  }
};

themeChips.forEach((chip) =>
  chip.addEventListener("click", () => {
    applyTheme(chip.dataset.themeName);
    try { localStorage.setItem(THEME_KEY, chip.dataset.themeName); } catch (e) {}
  })
);

// Sync the picker + theme-color meta with whatever the boot script applied
{
  let storedTheme = "amber";
  try { storedTheme = localStorage.getItem(THEME_KEY) || "amber"; } catch (e) {}
  applyTheme(storedTheme);
}

// --- Reset all settings ---
// Wipes ONLY the settings keys from IndexedDB — NOT ROMs, saves, states, BIOS,
// box art, recents, or link saves — then restores every in-memory setting to its
// default and re-runs each subsystem's sync/apply so the UI and the running core
// reflect defaults immediately, no reload. Defaults are taken from the same
// initial values each loader falls back to, kept in one place at the var decls.
const SETTINGS_KEYS = [
  "system", "audio", "colorCorrect", "video",
  "keybindings", "large-controls", "opaque-controls",
  "control-style", "joystick-mode", "hide-touch-on-gamepad",
];

const resetAllSettings = async () => {
  for (const k of SETTINGS_KEYS) await dbDelete(k);
  try { localStorage.removeItem(UPDATE_CHECK_KEY); } catch (e) {}

  // System (GB renderer / GBA BIOS mode + intro / rumble)
  gbFifo = true; gbaBiosMode = 0; gbaRunBios = true; gbRumble = true;
  syncSystemSettingsUI();
  applySystemSettings();

  // Audio (volume / mute / pitch-correct fast-forward)
  volume = 100; muted = false;
  syncVolumeUI();
  if (typeof updateGain === "function") updateGain();
  pitchCorrectFF = false;
  if (pcffToggle) pcffToggle.checked = false;
  applyPitchCorrectFF();

  // Color correction
  colorCorrect = true;
  ccToggle.checked = colorCorrect;
  applyColorCorrect();

  // Video effects
  integerScale = false; scanlines = false; motionBlur = false; ambientGlow = false;
  upscaleFilter = "none";
  integerScaleToggle.checked = false;
  scanlinesToggle.checked = false;
  motionBlurToggle.checked = false;
  ambientGlowToggle.checked = false;
  upscaleFilterSelect.value = "none";
  updateSuspendedVideoToggles();
  glowFresh = true;
  applyMotionBlur();
  updateCanvasScaling();

  // Keybindings -> default preset (the same path the "Default" preset uses)
  kbSelection = -1;
  applyKeybindings(PRESET_DEFAULT);
  kbPreset.value = "default";
  renderKbBindings();

  // Touch controls
  applyLargeControls(false);
  applyOpaqueControls(false);
  applyControlStyle("dpad");
  applyJoystickMode("fixed");
  applyHideTouchOnGamepad(true);

  // Chrome theme -> Amber (lives in localStorage, not IndexedDB — see the
  // theme section: the <head> boot script needs a synchronous read)
  try { localStorage.removeItem(THEME_KEY); } catch (e) {}
  applyTheme("amber");
};

const resetSettingsSlot = document.getElementById("reset-settings-slot");
if (resetSettingsSlot) {
  const resetBtn = makeConfirmButton({
    label: "Reset all settings",
    confirmLabel: "Confirm reset?",
    className: "button button-sm reset-settings-btn",
    onConfirm: async () => {
      await resetAllSettings();
      // Persistent button (unlike the delete lists it isn't re-rendered away),
      // so re-enable and disarm it for reuse.
      resetBtn.disabled = false;
      resetBtn.disarm();
    },
  });
  resetSettingsSlot.appendChild(resetBtn);
}

kbPreset.addEventListener("change", () => {
  kbSelection = -1;
  if (kbPreset.value === "default") commitBindings(PRESET_DEFAULT);
  else if (kbPreset.value === "homerow") commitBindings(PRESET_HOMEROW);
  else renderKbBindings();
});

var currentRomName = null;
var currentOriginalName = null;
var paused = false;
var fastForward = false;
var speed2x = false;
var rewindHeld = false;
var lastRewindPop = 0;

// --- Screen Wake Lock ---
// Keep the device awake while emulation is actively stepping (any mode: single,
// 2P link, online rollback — including fast-forward/2x/rewind, since they all
// run through the RAF loop). Released the instant we pause or return to the
// menu. No UI: release-on-pause is the user's control. The browser auto-drops
// the lock when the tab is hidden, so syncWakeLock() (driven every frame from
// the main loop, and on visibilitychange) re-acquires when we're visible again.
let wakeSentinel = null;
let wakeRequesting = false;
const emulationActive = () =>
  (!!currentRomName || linkMode || rollbackMode || netActive()) && !paused;
const syncWakeLock = () => {
  if (!navigator.wakeLock) return; // unsupported: silent no-op
  const want = emulationActive() && document.visibilityState === "visible";
  if (want && !wakeSentinel && !wakeRequesting) {
    wakeRequesting = true;
    navigator.wakeLock
      .request("screen")
      .then((s) => {
        wakeRequesting = false;
        // A pause/hide may have raced in while the request was pending; if we no
        // longer want it, drop it immediately.
        if (!emulationActive() || document.visibilityState !== "visible") {
          s.release().catch(() => {});
          return;
        }
        wakeSentinel = s;
        s.addEventListener("release", () => {
          if (wakeSentinel === s) wakeSentinel = null; // e.g. auto-release on hide
        });
      })
      .catch(() => {
        // request() rejects on e.g. low battery or a hidden document — ignore.
        wakeRequesting = false;
      });
  } else if (!want && wakeSentinel) {
    const s = wakeSentinel;
    wakeSentinel = null;
    s.release().catch(() => {});
  }
};
document.addEventListener("visibilitychange", syncWakeLock);

const pauseButton = document.getElementById("pause");
const resetButton = document.getElementById("reset");
const fastForwardButton = document.getElementById("fast-forward");
const speed2xButton = document.getElementById("speed-2x-btn");
const rewindButton = document.getElementById("rewind");

// Performance/memory telemetry for the on-page log (diagnosing iOS "slow
// until force-quit" = wasm JIT demotion under memory pressure). _benchFrames
// steps the LIVE core without presenting, i.e. it advances the game by n
// frames — so it must only run right after initFromEmscripten, before any
// gameplay (it just trims ~1s off the boot intro), and never in link/net/
// rollback modes (loadRom is the single-core path; benchFrames itself also
// refuses under an online link). Periodic runs would skip a second of real
// gameplay, so the 5-minute interval below logs heap size only.
const wasmHeapBytes = () =>
  (Module.HEAPU8?.buffer || Module.memory?.buffer)?.byteLength || 0;

// Pure-JS spin (~10-20ms on a healthy phone). Scales with raw CPU speed:
// if this is slow too, the whole CPU is throttled (Low Power Mode, thermal
// or low-battery management); if it's normal while the wasm bench is slow,
// the problem is wasm-specific (JIT demotion / tiering).
const jsBench = () => {
  const t0 = performance.now();
  let x = 0;
  for (let i = 0; i < 20_000_000; i++) x = (x + i) | 0;
  if (x === 42) console.log(x); // defeat dead-code elimination
  return performance.now() - t0;
};

const benchReport = (label) => {
  if (typeof Module === "undefined" || !Module._benchFrames) return;
  try {
    const t0 = performance.now();
    Module._benchFrames(60);
    const ms = performance.now() - t0;
    // The benched frames queued ~1s of audio in the wasm buffer; drop it so
    // the first real pushAudio doesn't schedule a stale backlog.
    if (Module._clearAudioBuffer) Module._clearAudioBuffer();
    const mb = Math.round(wasmHeapBytes() / (1024 * 1024));
    log(
      `bench (${label}): 60 frames in ${ms.toFixed(0)}ms, ` +
        `js ${jsBench().toFixed(0)}ms, heap ${mb}MB`
    );
  } catch {}
};

// Average rAF interval over 20 frames: ~16.7ms on a 60Hz panel; ~33ms means
// the display loop is halved — Low Power Mode's signature on iOS.
const rafProbe = () =>
  new Promise((resolve) => {
    const times = [];
    const tick = (t) => {
      times.push(t);
      if (times.length < 21) requestAnimationFrame(tick);
      else resolve((times[20] - times[0]) / 20);
    };
    requestAnimationFrame(tick);
  });

window.addEventListener("load", () =>
  setTimeout(async () => {
    const avg = await rafProbe();
    log(`display: rAF avg ${avg.toFixed(1)}ms (~${Math.round(1000 / avg)}Hz)`);
  }, 1500)
);

const loadRom = async (romName, originalName) => {
  // Leaving 2P link mode: flush and persist both players' saves first
  if (linkMode) await exitLinkMode();
  // Leaving online link mode: say BYE to the peer and drop the channel
  if (typeof netShutdown === "function" && netMode) await netShutdown();
  // Persist save from previous ROM before switching
  if (currentRomName && currentOriginalName) {
    await persistSave(currentRomName, currentOriginalName);
  }
  currentRomName = romName;
  currentOriginalName = originalName || romName;
  paused = false;
  document.body.classList.remove("paused");
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
  await restoreCheats();  // fresh core: re-apply this game's saved cheats
  applyPitchCorrectFF();  // fresh core: re-push the local audio preference
  benchReport("load");
  updateCanvasScaling();
  setTimeout(() => logViewportDiag("romload"), 500);
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

// A dropped file is usually a ROM/zip to load, but a dropped .sav or .state is
// imported into the running game instead — the same flows as the Manage Saves
// "Import save file" / "Import state" buttons. A save/state can only target a
// running single-player game, so reject it with a specific reason otherwise
// (rather than falling through to the ROM loader's generic "unsupported file").
const handleDroppedFile = (file) => {
  let ext = extOf(file.name);
  if (ext === ".sav" || ext === ".state") {
    let kind = ext === ".sav" ? "save file" : "save state";
    if (linkMode || rollbackMode || netActive()) {
      alert(`Can't import a ${kind} while a link cable is connected. Disconnect first, then try again.`);
      return;
    }
    if (!currentOriginalName) {
      alert(`Load a game first, then drop its ${kind} to import it.`);
      return;
    }
    let reader = new FileReader();
    reader.addEventListener("load", () => {
      let bytes = new Uint8Array(reader.result);
      if (ext === ".sav") applyImportedSave(bytes, file.name);
      else applyImportedState(bytes);
    });
    reader.readAsArrayBuffer(file);
    return;
  }
  handleRomFile(file);
};

const openRomPicker = () => {
  menuDropdown.hidden = true;
  let input = document.createElement("input");
  input.type = "file";
  // iOS Safari greys out (makes unselectable) files whose extension it can't
  // map to a known type — .gba/.gb/.gbc — as soon as a known type like .zip
  // is listed, so the filter is desktop-only. handleRomFile validates the
  // extension itself either way.
  if (!IS_IOS) input.accept = ROM_EXTS.join(",") + ",.zip";
  input.addEventListener("input", () => {
    if (input.files?.length > 0) handleRomFile(input.files[0]);
  });
  input.click();
};

document.getElementById("dropzone").addEventListener("click", openRomPicker);
// Mobile home: compact "Load a game" button shown where the drop target is
// hidden (touch devices — no drag-and-drop there).
document.getElementById("home-load").addEventListener("click", openRomPicker);

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
  if (e.dataTransfer.files?.length > 0) handleDroppedFile(e.dataTransfer.files[0]);
});

pauseButton.addEventListener("click", () => {
  paused = !paused;
  pauseButton.classList.toggle("paused", paused);
  pauseButton.classList.toggle("active", paused);
  pauseButton.title = paused ? "Resume" : "Pause";
  document.body.classList.toggle("paused", paused);
});

resetButton.addEventListener("click", () => {
  if (linkMode && linkRomEntry) launchLinkRom(linkRomEntry);
  else if (currentRomName) loadRom(currentRomName, currentOriginalName);
});

// 2x speed and unbounded fast forward are radio-style: fast forward would
// silently dominate 2x (it ignores pacing entirely), so enabling either
// clears the other.
const setSpeed2x = (on, fromRemote) => {
  speed2x = on;
  speed2xButton.classList.toggle("active", on);
  if (typeof Module !== "undefined" && Module._wasm_set_turbo) {
    Module._wasm_set_turbo(on ? 1 : 0);
  }
  // While linked online, 2x must drive BOTH cores or the pair desyncs — relay
  // our toggle to the peer (unless this change *came* from the peer).
  if (!fromRemote && rollbackMode && typeof window.rbSendSpeed === "function") {
    window.rbSendSpeed(on);
  }
};
// The peer toggled 2x; apply it here without echoing back (fromRemote = true).
window.applyRemoteSpeed2x = (on) => setSpeed2x(on, true);
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

// --- Desktop keyboard shortcuts ---
// Mirrors the native app's conventions (src/dingbat.nim): Tab holds unbounded
// fast-forward, Shift+Tab toggles 2x, backquote holds rewind. Registered
// after gameKeyHandler (same capture phase, later registration), which
// consumes bound game keys with stopImmediatePropagation — and the codeLookup
// check below also covers the window before the wasm module is ready.

const saveStateItem = document.getElementById("save-state");
const loadStateItem = document.getElementById("load-state");

const anyModalOpen = () => !!document.querySelector(".modal-overlay.open");
// netplay.js loads after index.js, so its netMode global may not exist yet
const netActive = () => typeof netMode !== "undefined" && !!netMode;
// The speed/rewind/state controls are hidden in the linked modes because
// they desync the pair; the shortcuts follow the same gating. 2x is the one
// exception: it stays available in rollback mode (it's relayed to the peer).
const speedControlsOk = () => !linkMode && !rollbackMode && !netActive();

// Which holds the KEYBOARD owns, so losing the keyup (window blur, a modal
// opening mid-hold) releases them without touching a button-initiated hold.
var kbFastForward = false;
var kbRewindHeld = false;
const releaseKbHolds = () => {
  if (kbFastForward) {
    kbFastForward = false;
    setFastForward(false);
  }
  if (kbRewindHeld) {
    kbRewindHeld = false;
    setRewindHeld(false);
  }
};
window.addEventListener("blur", releaseKbHolds);

const shortcutKeyHandler = (e, down) => {
  if (codeLookup[e.code] !== undefined) return; // game bindings always win
  if (e.ctrlKey || e.metaKey || e.altKey) return; // browser/OS chords

  // Releases skip the modal/typing guards: a hold must not stay stuck on
  // when a modal opens (or focus lands in a field) before the keyup.
  if (!down) {
    if ((e.code === "Tab" && kbFastForward) ||
        (e.code === "Backquote" && kbRewindHeld)) {
      if (e.code === "Tab") {
        kbFastForward = false;
        setFastForward(false);
      } else {
        kbRewindHeld = false;
        setRewindHeld(false);
      }
      e.preventDefault();
      e.stopPropagation();
    }
    return;
  }

  if (anyModalOpen()) return;
  // Same guard as gameKeyHandler: don't hijack typing in text fields
  const t = e.target;
  if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;

  const gameLoaded = !!currentRomName || linkMode || rollbackMode || netActive();
  let handled = false;
  switch (e.code) {
    case "Space":
      if (!gameLoaded) break;
      if (!e.repeat) pauseButton.click();
      handled = true; // swallow repeats too (Space would scroll / click)
      break;
    case "Tab":
      if (!gameLoaded) break; // leave Tab to focus navigation otherwise
      if (e.shiftKey) {
        // Toggle 2x — radio with fast-forward, same as the buttons
        if (linkMode || netActive()) break;
        if (!e.repeat) {
          setSpeed2x(!speed2x);
          if (speed2x) setFastForward(false);
        }
        handled = true;
      } else {
        // Hold for unbounded fast-forward
        if (!speedControlsOk()) break;
        if (!kbFastForward) {
          kbFastForward = true;
          setFastForward(true);
          setSpeed2x(false);
        }
        handled = true;
      }
      break;
    case "Backquote":
      if (!gameLoaded || !speedControlsOk()) break;
      if (!kbRewindHeld) {
        kbRewindHeld = true;
        setRewindHeld(true);
      }
      handled = true;
      break;
    case "KeyF":
      if (e.shiftKey || fullscreenBtn.hidden) break; // hidden = no fullscreen API (iOS)
      if (!e.repeat) fullscreenBtn.click();
      handled = true;
      break;
    case "KeyM":
      if (e.shiftKey) break;
      if (!e.repeat) toggleMute();
      handled = true;
      break;
    case "F5": // save state (F5 default is reload — must be swallowed)
      if (e.shiftKey || !gameLoaded || !speedControlsOk()) break;
      if (!e.repeat) saveStateItem.click();
      handled = true;
      break;
    case "F8": // load state
      if (e.shiftKey || !gameLoaded || !speedControlsOk()) break;
      if (!e.repeat) loadStateItem.click();
      handled = true;
      break;
    case "F9": // screenshot (F12 opens devtools). OK in net mode: this
      // side's canvas is the only one here — matches the hidden-button CSS.
      if (e.shiftKey || !currentRomName || linkMode || rollbackMode) break;
      if (!e.repeat) takeScreenshot();
      handled = true;
      break;
  }
  if (handled) {
    e.preventDefault();
    e.stopPropagation();
  }
};
document.addEventListener("keydown", (e) => shortcutKeyHandler(e, true), true);
document.addEventListener("keyup", (e) => shortcutKeyHandler(e, false), true);

// --- 2P local link mode ---
// Two GBA cores running the same ROM over the emulated link cable (lockstep,
// in-process), rendered side by side on their own 2D canvases. Keyboard and
// touch controls drive P1, a connected gamepad drives P2. Each player has an
// independent battery save: the same ROM bytes are written to two FS paths,
// so core 2's .sav lands in its own file, persisted under "save:<name>-p2".
// Rewind / 2x / fast-forward / save states are disabled in this mode — any
// of them would desync the pair (their controls are hidden by CSS).

var linkMode = false;
// { name, data } for the live 2P session only — kept for reset + save
// persistence while linked, and released (bytes and all) on exitLinkMode so
// no ROM bytes outlive their session in the JS heap.
var linkRomEntry = null;
var linkIsGb = false;    // true while the linked pair is GB/GBC (160x144)
var linkFocus = 0;       // which core the keyboard drives (click a screen to switch)

// Point the keyboard at player `p`'s core. Clears held buttons on both cores
// first so a key held during the switch doesn't stick on the other player.
const setLinkFocus = (p) => {
  if (!linkMode) return;
  if (Module._link_input) {
    for (let c = 0; c < 2; c++)
      for (let i = 0; i < 10; i++) Module._link_input(c, i, 0);
  }
  linkFocus = p;
  for (let c = 0; c < 2; c++) {
    let pane = document.getElementById("link-canvas-" + c)?.closest(".link-pane");
    if (pane) pane.classList.toggle("focused", c === p);
    let label = pane?.querySelector(".link-label");
    if (label)
      label.textContent = c === p ? "▶ P" + (c + 1) + " · Keyboard"
                                   : "P" + (c + 1) + " · Click to control";
  }
};

// ROM lives at two FS paths so each core derives its own .sav; the extension
// follows the launched ROM's system so the wasm side picks GB vs GBA.
let LINK_FS_ROMS = ["linkrom1.gba", "linkrom2.gba"];
const LINK_FS_SAVS = ["linkrom1.sav", "linkrom2.sav"];
const linkSaveKey = (name, player) =>
  "save:" + (player === 0 ? name : name + "-p2");

// Backing-store dimensions of each player's canvas, set per launch.
const linkDims = () => (linkIsGb ? [160, 144] : [240, 160]);

let linkCtx = [null, null];
let linkImg = [null, null];

const initLinkCanvases = () => {
  const [w, h] = linkDims();
  for (let p = 0; p < 2; p++) {
    let c = document.getElementById("link-canvas-" + p);
    c.width = w;
    c.height = h;
    linkCtx[p] = c.getContext("2d");
    linkImg[p] = linkCtx[p].createImageData(w, h);
    c.style.cursor = "pointer";
    c.onclick = () => setLinkFocus(p);
  }
  setLinkFocus(0); // keyboard starts on P1
};

const blitLinkCanvases = () => {
  const [w, h] = linkDims();
  for (let p = 0; p < 2; p++) {
    if (!linkCtx[p] || !Module._link_fb_ptr) continue;
    let ptr = Module._link_fb_ptr(p);
    if (!ptr) continue;
    // Build the heap view fresh each blit: memory growth detaches buffers
    linkImg[p].data.set(new Uint8Array(Module.memory.buffer, ptr, w * h * 4));
    linkCtx[p].putImageData(linkImg[p], 0, 0);
  }
};

// Online rollback shows only THIS player's core, on link-canvas-0.
const blitRollbackCanvas = () => {
  if (!linkCtx[0] || !Module._rollback_fb_ptr) return;
  let ptr = Module._rollback_fb_ptr();
  if (!ptr) return;
  const [w, h] = linkDims();
  linkImg[0].data.set(new Uint8Array(Module.memory.buffer, ptr, w * h * 4));
  linkCtx[0].putImageData(linkImg[0], 0, 0);
};

// Debug: from the browser console during an online link session, run
// `dumpLinkStates()` to download both linked cores' save states (core0.state /
// core1.state). Used to capture a stuck-trade repro for offline debugging.
window.dumpLinkStates = () => {
  if (!Module._rollback_dump_size) return "no dump export in this build";
  for (let p = 0; p < 2; p++) {
    const n = Module._rollback_dump_size(p);
    if (n <= 0) return "no active online link session";
    const ptr = Module._rollback_dump_data();
    const bytes = new Uint8Array(Module.memory.buffer, ptr, n).slice();
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([bytes]));
    a.download = "core" + p + ".state";
    a.click();
  }
  return "downloaded core0.state + core1.state";
};

// Enter/leave online input-rollback mode. netplay.js calls these once the
// RollbackSession is initialized (enter) and on teardown (leave). The core is
// driven by the RAF loop's rollbackMode branch.
window.enterRollbackMode = () => {
  // Always (re)init: sizes the canvas backing store to the session's system
  // (linkIsGb is set by rbConnect), which may differ from a prior session.
  initLinkCanvases();
  localButtons = 0;
  gpPrev.fill(false);
  rollbackMode = true;
  rbWasLinked = false;
  rbLinkWasActive = false;
  rbLastTransfers = 0;
  rbLastActivity = performance.now();
  paused = false;
  document.body.classList.remove("paused");
  // The Link Cable click froze the game and lit the pause button (openNetConnect);
  // now that the linked session is running, clear that indicator to match.
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  document.body.classList.toggle("link-gb", linkIsGb);
  document.body.classList.add("has-game", "running", "rollback-mode");
  if (typeof window.setNetConnectLabel === "function") window.setNetConnectLabel(true);
  updateCanvasScaling();
};
// Clear the JS-side rollback flags. The wasm side (promote-to-single vs exit)
// is handled by the caller (netplay's rbTeardown) so the local game can keep
// playing solo after a disconnect.
window.leaveRollbackMode = () => {
  if (!rollbackMode) return;
  rollbackMode = false;
  localButtons = 0;
  document.body.classList.remove("rollback-mode", "link-gb");
  if (typeof window.setNetConnectLabel === "function") window.setNetConnectLabel(false);
  updateCanvasScaling();
};

// Persist both players' battery saves (the core flushes dirty saves to the
// FS .sav files once per frame, same as single-player)
const persistLinkSaves = async () => {
  if (!linkRomEntry) return;
  for (let p = 0; p < 2; p++) {
    try {
      let data = FS.readFile(LINK_FS_SAVS[p]);
      if (data && data.length > 0) {
        await dbPut(linkSaveKey(linkRomEntry.name, p), new Uint8Array(data));
      }
    } catch {}
  }
};

const exitLinkMode = async () => {
  if (!linkMode) return;
  if (Module._link_exit) Module._link_exit(); // final battery flush into FS
  await persistLinkSaves();
  linkRomEntry = null; // release the session's ROM bytes
  linkMode = false;
  gpPrev.fill(false);
  document.body.classList.remove("link-mode", "link-gb");
  updateCanvasScaling();
};

const launchLinkRom = async (rom) => {
  // Flush whatever was running before
  if (linkMode) {
    await exitLinkMode();
  } else if (currentRomName && currentOriginalName) {
    await persistSave(currentRomName, currentOriginalName);
  }
  // FS ROM extension follows the ROM's system so the wasm link_init picks the
  // GB lockstep path for .gb/.gbc and the GBA path otherwise.
  const ext = extOf(rom.name) === ".gba" ? ".gba" : extOf(rom.name) || ".gb";
  linkIsGb = ext !== ".gba";
  LINK_FS_ROMS = ["linkrom1" + ext, "linkrom2" + ext];
  document.body.classList.toggle("link-gb", linkIsGb);
  // Same ROM bytes at two FS paths: each core derives its own .sav file
  writeToFS(LINK_FS_ROMS[0], rom.data);
  writeToFS(LINK_FS_ROMS[1], rom.data);
  // Restore both players' saves (never leave a previous game's .sav behind).
  // P2 starts from a copy of P1's save the first time, so both sides hold a
  // viable game — trading needs two playable saves.
  for (let sav of LINK_FS_SAVS) {
    try { FS.unlink(sav); } catch {}
  }
  let s1 = await dbGet(linkSaveKey(rom.name, 0));
  let s2 = await dbGet(linkSaveKey(rom.name, 1));
  if (!s2 && s1) s2 = s1;
  if (s1) writeToFS(LINK_FS_SAVS[0], s1);
  if (s2) writeToFS(LINK_FS_SAVS[1], s2);
  // None of the speed/rewind toggles exist in link mode
  setFastForward(false);
  setSpeed2x(false);
  setRewindHeld(false);
  currentRomName = null;
  currentOriginalName = null;
  linkRomEntry = { name: rom.name, data: rom.data };
  let ok = Module.ccall("link_init", "number", ["string", "string"], LINK_FS_ROMS);
  if (ok !== 1) {
    linkRomEntry = null;
    showToast("Couldn't start 2P link mode");
    return;
  }
  linkMode = true;
  paused = false;
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  gpPrev.fill(false);
  initLinkCanvases();
  document.body.classList.add("has-game", "running", "link-mode");
  updateCanvasScaling();
  await touchRecent(rom.name); // bytes are already stored — recency bump only
};

// --- Main Menu (return to the home screen without terminating the game) ---

// Show the home screen over the paused-but-still-loaded game. The emulator
// keeps its state; Resume (or loading another ROM) picks up where it left off.
const showMainMenu = () => {
  menuDropdown.hidden = true;
  if (!currentRomName && !linkMode) return;
  paused = true;
  document.body.classList.add("paused");
  document.body.classList.remove("running");
  updatePausedCard();
  refreshHomeRecent();
  updateCanvasScaling();
};

const resumeGame = () => {
  if (!currentRomName && !linkMode) return;
  paused = false;
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  document.body.classList.remove("paused");
  document.body.classList.add("running");
  updateCanvasScaling();
};

document.getElementById("main-menu").addEventListener("click", showMainMenu);
document.getElementById("home-resume").addEventListener("click", resumeGame);

// --- Paused-game card (home screen) ---
// A frozen frame of the paused game shown beside Resume, so it's clear which
// game Resume returns to. Pixels come from the wasm-side presented
// framebuffer, exactly like the ambient glow sampler — the game canvas is a
// WebGL context without preserveDrawingBuffer, so reading the canvas itself
// after pausing yields nothing.
const homePausedCard = document.getElementById("home-paused");
const homePausedCanvas = document.getElementById("home-paused-canvas");
const homePausedName = document.getElementById("home-paused-name");

const updatePausedCard = () => {
  homePausedCard.hidden = true;
  // Single-core sessions only (the glow sampler's condition): 2P/online modes
  // render to their own canvases, not the shared framebuffer.
  if (!currentRomName || linkMode || rollbackMode || netActive()) return;
  if (typeof Module === "undefined" || !Module._wasm_fb_ptr) return;
  const ptr = Module._wasm_fb_ptr();
  if (!ptr) return;
  const [w, h] = nativeRes(); // GBA 240x160, GB/GBC 160x144
  const heap = new Uint8Array(Module.memory.buffer, ptr, w * h * 4);
  homePausedCanvas.width = w;
  homePausedCanvas.height = h;
  const ctx = homePausedCanvas.getContext("2d");
  const img = ctx.createImageData(w, h);
  img.data.set(heap);
  // The wasm fb's alpha channel is not meaningful; force opaque (as the glow
  // sampler does).
  for (let i = 3; i < img.data.length; i += 4) img.data[i] = 255;
  ctx.putImageData(img, 0, 0);
  homePausedName.textContent = currentOriginalName;
  homePausedName.title = currentOriginalName;
  homePausedCard.hidden = false;
};

document.getElementById("home-paused-shot").addEventListener("click", resumeGame);

// Close the paused game from the home screen: flush its save once, detach it
// from every later flush path, and return the home screen to its fresh-boot
// state. The orphaned core simply stays frozen in wasm memory (`paused` gates
// the RAF loop, and every unpause path — Resume, Space, the pause button — is
// gated on a loaded game); the next loadRom re-inits over it, which is the
// same thing loading a second ROM over a live core has always done.
// Returns false when there is nothing to unload (or an online/link session is
// up, which has its own teardown paths).
const unloadGame = async ({ flushSave = true } = {}) => {
  if (!currentRomName || linkMode || rollbackMode || netActive()) return false;
  const romName = currentRomName;
  const originalName = currentOriginalName;
  // Detach FIRST: once these are null, the 5s autosave interval and the
  // beforeunload/pagehide flushes all skip this game, so nothing can
  // re-persist its save after the single flush below (or after a caller
  // deletes the stored save).
  currentRomName = null;
  currentOriginalName = null;
  if (flushSave) await persistSave(romName, originalName);
  // Drop the FS-side .sav so a later load can't pick up battery data that
  // IndexedDB no longer agrees with.
  try { FS.unlink(stripExt(romName) + ".sav"); } catch {}
  paused = true; // keep the orphaned core frozen
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  document.body.classList.remove("has-game", "running", "paused");
  homePausedCard.hidden = true;
  refreshHomeRecent();
  updateCanvasScaling();
  return true;
};

document.getElementById("home-paused-close").addEventListener("click", async () => {
  if (await unloadGame()) showToast("Game closed — save kept");
});

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
    drawGame();
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

// --- Mobile-landscape top bar handle ---
// In landscape on phones the top bar sits off-screen (CSS); this small
// handle at the top edge slides it in and out.
document.getElementById("topbar-handle").addEventListener("click", () => {
  document.body.classList.toggle("topbar-open");
});

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
  document.body.classList.toggle(
    "gamepad-hides-touch", hideTouchOnGamepad && anyConnected);
  if (!anyConnected) return;
  for (let i = 0; i < 10; i++) {
    if (want[i] !== gpPrev[i]) {
      // In 2P link mode the gamepad is player 2's controller; in online
      // rollback it is this player's controller (captured into localButtons).
      if (rollbackMode) {
        noteLocalButton(i, want[i]);
      } else if (linkMode) {
        if (Module._link_input) Module._link_input(1, i, want[i] ? 1 : 0);
      } else {
        Module._setInput(i, want[i] ? 1 : 0);
      }
      gpPrev[i] = want[i];
    }
  }
};

// --- MBC5 rumble (GB cart types 0x1C-0x1E) ---
// The RAF loop polls _wasm_rumble each tick while a single-core GB game runs
// (link/net/rollback modes are GBA-only, and _wasm_rumble itself returns 0
// for anything but a single GB core). Motor-on drives three presentation-side
// effects, all gated by the gbRumble setting:
//  - gamepad vibration, re-triggered every ~50 ms with 60 ms effects so they
//    chain into a continuous buzz instead of spamming one per frame
//  - navigator.vibrate on touch devices, same throttle
//  - a body.rumbling class animating a small transform-only canvas shake
const RUMBLE_RETRIGGER_MS = 50;
const touchDevice = "ontouchstart" in window || navigator.maxTouchPoints > 0;
let rumbling = false;
let lastRumblePulse = 0;

const updateRumble = (timestamp) => {
  const on = !!(gbRumble && currentRomName && !paused &&
    typeof Module !== "undefined" && Module._wasm_rumble && Module._wasm_rumble());
  if (on !== rumbling) {
    rumbling = on;
    document.body.classList.toggle("rumbling", on);
  }
  if (!on) return; // running effects are <=60 ms, they die out on their own
  if (timestamp - lastRumblePulse < RUMBLE_RETRIGGER_MS) return;
  lastRumblePulse = timestamp;
  const pads = navigator.getGamepads ? navigator.getGamepads() : [];
  for (const pad of pads) {
    if (!pad?.vibrationActuator?.playEffect) continue;
    try {
      pad.vibrationActuator.playEffect("dual-rumble", {
        duration: 60, strongMagnitude: 0.6, weakMagnitude: 0.4,
      }).catch(() => {});
    } catch {}
  }
  if (touchDevice) {
    // 45 ms (> the 25 ms button tick, < the 50 ms retrigger) reads as a
    // distinct, near-continuous rumble rather than a light press tick.
    try { navigator.vibrate?.(45); } catch {}
  }
};

var Module = {
  // SDL renders (invisibly) to a dedicated hidden canvas so its WebGL context
  // doesn't collide with the WebGL2 context we own on the visible #canvas. A
  // canvas can hold only one context type; game input (_setInput) and audio
  // (Web Audio) are JS-driven, so SDL's canvas is never seen or interacted with.
  canvas: (() => document.getElementById("sdl-canvas"))(),
  onRuntimeInitialized: async () => {
    // iOS Safari kills (or JIT-demotes) tabs under process memory pressure;
    // shrink the rewind ring's cap from 64 MB before any core exists — the
    // ring is created at ROM load (initFromEmscripten), so setting it here
    // covers every session.
    if (IS_IOS && Module._setRewindCapBytes) {
      Module._setRewindCapBytes(16 * 1024 * 1024);
    }
    await openDB();
    await migrateFromLocalStorage();
    await migrateRecentFormat();
    await loadBiosFromStorage();
    await loadKeybindingsFromStorage();
    await loadLargeControlsFromStorage();
    await loadOpaqueControlsFromStorage();
    await loadHideTouchOnGamepadFromStorage();
    await loadControlStyleFromStorage();
    await loadAudioSettings();
    await loadColorCorrect();
    await loadSystemSettings();
    await loadVideoSettings();
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
    // Audio can only play at realtime rate. When unbounded fast-forward runs the
    // core many frames per rAF, we play the frames that fit within this much
    // queued lead and drop the rest (see the fastForward branch), keeping FF
    // audio realtime-rate instead of piling into overlapping buffers.
    const FF_MAX_AUDIO_LEAD = 0.15; // seconds of audio allowed queued ahead
    // Cap on scheduled lead in ALL play modes. Steady state keeps only a few
    // frames (<100 ms) queued, so a healthy session never comes near this;
    // it exists for when audioCtx.currentTime stalls while state stays
    // "running" (iOS route changes / interruptions) — without a cap, one
    // AudioBufferSourceNode per frame accumulates at 60/s until the tab is
    // killed. Generous vs FF_MAX_AUDIO_LEAD so 2x/catch-up bursts (which
    // legitimately schedule a few frames at once) are never clipped.
    const MAX_AUDIO_LEAD = 0.25;

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
      // Not just "suspended": iOS Safari parks the context in a non-standard
      // "interrupted" state after phone calls / Siri, which also needs an
      // explicit resume(). Attempt it for any non-running state.
      if (audioCtx.state !== "running") audioCtx.resume().catch(() => {});
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
      const now = audioCtx.currentTime;
      if (playTime < now) playTime = now;
      // Scheduled too far ahead (the audio clock stalled): drop this frame's
      // samples — same pattern embed.js uses — instead of stacking source
      // nodes without bound.
      if (playTime - now > MAX_AUDIO_LEAD) {
        Module._clearAudioBuffer();
        return;
      }
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
      // Schedule playback at the correct time (playTime was clamped to the
      // current clock above, before the lead-cap check)
      const source = audioCtx.createBufferSource();
      source.buffer = buffer;
      source.connect(gainNode);
      source.start(playTime);
      playTime += buffer.duration;
    };

    const fpsDiv = document.getElementById("fps");
    // The counter is a diagnostic: it only appears when the frame rate is
    // UNUSUAL for the current mode. Expected rates — 0 while paused or
    // rewinding (rewind pops don't count as frames), ~120 at 2x, ~60
    // otherwise — hide it; fast-forward is unbounded, so whatever rate it
    // reaches is the interesting number and always shows.
    let lastFpsMode = "";
    setInterval(() => {
      if (sleepVisible) {
        frameCount = 0;
        return;  // fps display is showing SLEEPING
      }
      const mode = paused ? "paused" : rewindHeld ? "rewind"
        : fastForward ? "ffw" : speed2x ? "2x" : "normal";
      const expected = mode === "paused" || mode === "rewind" ? 0
        : mode === "2x" ? 119.5 : mode === "normal" ? 59.7 : null;
      const usual = expected !== null &&
        Math.abs(frameCount - expected) <= Math.max(3, expected * 0.05);
      // A mode switch mid-window yields a blended count; don't flash it
      if (usual || mode !== lastFpsMode) {
        fpsDiv.textContent = "";
      } else {
        fpsDiv.textContent = frameCount + " fps";
      }
      lastFpsMode = mode;
      frameCount = 0;
    }, 1000);

    // Periodic memory telemetry. The frame bench can't run here (benchReport
    // explains why: _benchFrames advances the live game), so while a game is
    // up just track wasm heap growth every 5 minutes.
    setInterval(() => {
      if (!currentRomName && !linkMode) return;
      const mb = Math.round(wasmHeapBytes() / (1024 * 1024));
      if (mb) log(`heap ${mb}MB`);
    }, 5 * 60 * 1000);

    // Persist save data to IndexedDB every 5 seconds
    setInterval(() => {
      if (linkMode) {
        persistLinkSaves();
      } else if (currentRomName && currentOriginalName) {
        persistSave(currentRomName, currentOriginalName);
      }
    }, 5000);

    // Also persist on page unload
    window.addEventListener("beforeunload", () => {
      // Closing the tab mid-online-game: get the BYE out so the peer sees a
      // clean exit instead of a dead channel (the sync parts run before the
      // page dies; the await inside is best-effort)
      if (netMode && typeof netShutdown === "function") netShutdown();
      if (linkMode) {
        persistLinkSaves();
      } else if (currentRomName && currentOriginalName) {
        persistSave(currentRomName, currentOriginalName);
      }
    });

    // iOS Safari frequently skips beforeunload entirely; pagehide is the
    // reliable end-of-life signal there (it also fires when the page enters
    // the back/forward cache). Do the same persistence work, and suspend the
    // AudioContext so a bfcached page doesn't hold the device audio session.
    // Note the existing visibilitychange listener (top of file) only checks
    // for updates — nothing else suspends audio, so there's no conflict.
    window.addEventListener("pagehide", () => {
      if (netMode && typeof netShutdown === "function") netShutdown();
      if (linkMode) {
        persistLinkSaves();
      } else if (currentRomName && currentOriginalName) {
        persistSave(currentRomName, currentOriginalName);
      }
      if (audioCtx && audioCtx.state === "running") {
        audioCtx.suspend().catch(() => {});
      }
    });
    // Restored from the back/forward cache (e.persisted) with a game up:
    // resume the context we suspended in pagehide, else the game comes back
    // silent. resumeAudio is a no-op beyond resume() once already unlocked.
    window.addEventListener("pageshow", (e) => {
      if (e.persisted && (currentRomName || linkMode)) resumeAudio();
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

    // Advance the online-link core by whatever the shared `accumulator`
    // affords, capped so a long stall can't later burst. Called from the RAF
    // loop (after accumulator is topped up with real elapsed time) AND from
    // netplay.js on every inbound DataChannel message — the latter drains
    // any debt a stall left behind the moment the peer's data arrives, which
    // is what keeps link-heavy screens near full speed. Re-entrancy guarded.
    let netPumping = false;
    const driveNet = () => {
      if (!netMode || netPumping) return;
      netPumping = true;
      try {
        if (accumulator > FRAME_TIME * 4) accumulator = FRAME_TIME * 4;
        let st = 4;
        let framesRun = 0;
        while (accumulator >= FRAME_TIME && framesRun < 4) {
          st = netStep();
          if (st !== 1) break; // stalled / handshake / failed — keep the debt
          pushAudio();
          frameCount++;
          accumulator -= FRAME_TIME;
          framesRun++;
        }
        netAfterTick(framesRun > 0 && st !== 3 ? (st === 1 ? 1 : st) : st);
      } finally {
        netPumping = false;
      }
    };
    window.driveNet = driveNet;

    const tick = (timestamp) => {
      pollGamepads();
      syncWakeLock(); // acquire while stepping, release on pause/menu (idempotent)
      if (paused) {
        updateRumble(timestamp); // drops body.rumbling promptly on pause
        watchCanvasBacking();
        lastFrameTime = 0;
        accumulator = 0;
        requestAnimationFrame(tick);
        return;
      }
      if (lastFrameTime === 0) lastFrameTime = timestamp;
      accumulator += timestamp - lastFrameTime;
      lastFrameTime = timestamp;
      if (rollbackMode) {
        // Online input-rollback: both cores run locally at full speed; only
        // this player's per-frame buttons cross the network. rollback_tick
        // returns the frame just simulated (ship it) or -1 when stalled at the
        // prediction window. 2x is allowed because it's synchronized — both
        // peers halve the step together (see setSpeed2x/RB_SPEED), so the frame
        // numbering stays aligned; rewind/unbounded fast-forward still can't.
        const rbStep = speed2x ? FRAME_TIME / 2 : FRAME_TIME;
        const rbCap = speed2x ? 4 : 2;
        let framesRun = 0;
        while (accumulator >= rbStep && framesRun < rbCap) {
          const frame = Module._rollback_tick(localButtons);
          if (frame < 0) { accumulator = 0; break; } // stalled: wait for peer input
          if (typeof window.rbSendInput === "function") window.rbSendInput(frame, localButtons);
          pushAudio();
          frameCount++;
          accumulator -= rbStep;
          framesRun++;
        }
        if (accumulator > FRAME_TIME * 2) accumulator = 0;
        blitRollbackCanvas();
        // Auto-end via serial-cable INACTIVITY (see the RB_IDLE_* block above for
        // the QUIET vs ACTIVE window rationale). Once the games have linked and
        // then stop transferring for long enough, assume the link is done and
        // disconnect (each side continues solo). One extra guard:
        //  - Skip while the tab is HIDDEN. A backgrounded tab's rAF is throttled
        //    so the emulator barely advances and transfers naturally pause — that
        //    is NOT "link done", and counting it once dropped a peer's link mid-
        //    session. Reset the activity clock so the timer restarts on return.
        if (Module._rollback_transfers) {
          const t = Module._rollback_transfers();
          const idleLimit = rbLinkWasActive ? RB_IDLE_ACTIVE_MS : RB_IDLE_QUIET_MS;
          if (t !== rbLastTransfers) {
            rbLastTransfers = t;
            rbLastActivity = timestamp;
            if (t > 0) rbWasLinked = true;
            if (t >= RB_ACTIVE_LINK_TRANSFERS) rbLinkWasActive = true;
          } else if (document.hidden) {
            rbLastActivity = timestamp; // don't accrue idle time while throttled
          } else if (rbWasLinked && timestamp - rbLastActivity > idleLimit) {
            rbWasLinked = false;
            if (typeof netShutdown === "function") netShutdown();
            showToast("Link idle — disconnected");
          }
        }
      } else if (netMode) {
        // Online link: driveNet consumes the shared accumulator. It is ALSO
        // called from netplay.js the instant a DataChannel message arrives,
        // so a frame stalled on the peer's reply resumes at network speed
        // instead of waiting a whole 16 ms RAF interval — without that, the
        // trade handshake (hundreds of round-trips) crawls at a few fps.
        driveNet();
      } else if (linkMode) {
        // 2P link: fixed-rate frames only — rewind/turbo would desync the
        // pair, so their branches (and controls) don't exist here
        let framesRun = 0;
        while (accumulator >= FRAME_TIME && framesRun < 2) {
          Module._link_tick();
          pushAudio();
          frameCount++;
          accumulator -= FRAME_TIME;
          framesRun++;
        }
        if (accumulator > FRAME_TIME * 2) accumulator = 0;
        blitLinkCanvases();
      } else if (rewindHeld) {
        // Pop ~30 snapshots/s (10 frames each ≈ 5x realtime backward); the
        // pop presents the restored frame itself, and no audio is queued so
        // the scheduled lead just drains
        if (timestamp - lastRewindPop >= 33) {
          lastRewindPop = timestamp;
          if (Module._wasm_rewind_pop) Module._wasm_rewind_pop();
        }
        accumulator = 0;
      } else if (fastForward) {
        // Run as many frames as fit in a ~16ms wall-clock budget. Audio can't
        // play faster than realtime, so instead of the old approach (reset
        // playTime to now every rAF, then schedule ~8 full frames of audio —
        // which re-piled 8x too much into 10-30 OVERLAPPING buffers, garbling
        // and clipping the sound), we keep playTime continuous and only play
        // frames whose audio fits within FF_MAX_AUDIO_LEAD of realtime; the rest
        // are dropped. Result: clean realtime-rate audio that skips ahead with
        // the video (to mute FF entirely, drop the pushAudio call).
        const budget = 16;
        const start = performance.now();
        while (performance.now() - start < budget) {
          Module._loop_tick();
          if (audioCtx && audioCtx.state === "running" &&
              playTime - audioCtx.currentTime < FF_MAX_AUDIO_LEAD) {
            pushAudio();
          } else if (Module._clearAudioBuffer) {
            Module._clearAudioBuffer(); // discard this frame's audio; keep the WASM buffer bounded
          }
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
        // Emulation is 60 fps but RAF follows the display: on a 120 Hz screen
        // every other tick steps zero frames, and re-presenting the identical
        // frame would double the texture-upload + shader cost (noticeable
        // with xBR on phones). Settings/resize paths set presentDirty to
        // force a repaint even without a new frame.
        presentSkip = framesRun === 0 && !presentDirty;
      }
      // Present the freshly-stepped frame through WebGL2 (single-core / online
      // link / rewind / fast-forward paths; 2P link & rollback blit their own
      // canvases and drawGame no-ops for them).
      if (!presentSkip) {
        drawGame();
        presentDirty = false;
      } else {
        presentSkips++; // diagnostics: ticks that reused the shown frame
      }
      presentSkip = false;
      // Screenshot: draw one guaranteed-fresh frame and grab it in this task
      // (the WebGL2 context has no preserveDrawingBuffer).
      if (pendingShot) {
        Module._loop_tick();
        drawGame();
        captureCanvas();
      }
      updateSleepOverlay();
      updateGlow();
      updateRumble(timestamp);
      watchCanvasBacking();
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  },
};

const getInputs = (element) =>
  element?.getAttribute("data-inputs")?.split(" ").map(Number) ?? [];

const setInputs = (inputs, down) => {
  for (let id of inputs) routeP1Input(id, down);
};

// Map each direction input id to the cardinal d-pad cell that visually
// represents it. A diagonal cell (e.g. up-left "0 2") lights BOTH arms.
const ARM_CELL_ID = { 0: "up", 1: "down", 2: "left", 3: "right" };
const setArms = (inputs, on) => {
  for (let id of inputs) {
    let cell = document.getElementById(ARM_CELL_ID[id]);
    if (cell) cell.classList.toggle("arm-active", on);
  }
};

// --- Vibration / haptic ---
// navigator.vibrate needs *sticky* user activation in Chromium. Crucially,
// touchstart does NOT grant activation (only touchend/pointerup/mousedown/
// keydown / mouse-pointerdown do), yet our in-game buttons fire haptic() from
// touchstart for input latency. So if the very first interaction on the page
// is an in-game touchstart (e.g. a PWA launched straight into a game), Chrome
// drops that first pulse and logs "Blocked call to navigator.vibrate...". Any
// normal menu/home-screen tap sets the sticky bit before gameplay, so in
// practice at most one pulse in a rare touch-first flow is ever at risk. We
// bind a one-time capture-phase listener on the activation-granting events so
// the sticky bit is established at the earliest gesture, and record which
// event did it purely so the diagnostic log can confirm, on a real device,
// that activation existed by the time buttons were pressed.
let firstActivationEvent = null;
const noteActivation = (e) => {
  if (firstActivationEvent) return;
  firstActivationEvent = e.type;
  for (const ev of ["touchend", "pointerup", "mousedown", "keydown"])
    window.removeEventListener(ev, noteActivation, true);
};
for (const ev of ["touchend", "pointerup", "mousedown", "keydown"])
  window.addEventListener(ev, noteActivation, true);

// Short haptic tick for touch controls (no-op where unsupported). 8 ms was
// below the spin-up threshold of most Android vibration motors, so presses
// felt dead; ~25 ms is the perceptible floor for a subtle "tick" without
// reading as a notification buzz. iOS/WebKit never shipped vibrate and Firefox
// removed it in 129 — the optional-chain + try make those silent no-ops.
const HAPTIC_MS = 25;
// Diagnostic counters surfaced in the debug-log context line as
// hblk:<blocked>/<total>. A call counts as blocked only when vibrate()
// exists and returns false (Chromium's "no sticky activation" / policy
// block) — unsupported platforms (iOS, Firefox 129+) stay 0/n by design.
let hapticCalls = 0;
let hapticBlocked = 0;
const haptic = () => {
  hapticCalls++;
  try {
    if (navigator.vibrate?.(HAPTIC_MS) === false) hapticBlocked++;
  } catch {
    hapticBlocked++;
  }
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
    if (element.closest("#dpad") && element.hasAttribute("data-inputs")) {
      currentDpadElement = element;
      let inputs = getInputs(element);
      setArms(inputs, true);
      setInputs(inputs, true);
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
    let oldInputs = getInputs(currentDpadElement);
    // Only treat the hit element as a d-pad cell if it's actually inside
    // #dpad. Face buttons (A/B/L/R/Select/Start) also carry data-inputs, so
    // sliding onto them must NOT press them. A null element (finger dragged
    // off-viewport) is likewise treated as "moved off the pad".
    if (element && element.closest("#dpad") && element.hasAttribute("data-inputs")) {
      let newInputs = getInputs(element);
      for (let id of oldInputs) {
        if (newInputs.includes(id)) continue;
        routeP1Input(id, false);
      }
      for (let id of newInputs) {
        if (oldInputs.includes(id)) continue;
        routeP1Input(id, true);
      }
      setArms(oldInputs, false);
      setArms(newInputs, true);
      currentDpadElement = element;
      haptic();
    } else {
      setInputs(oldInputs, false);
      setArms(oldInputs, false);
      currentDpadElement = null;
    }
  }
};

const dpadTouchEnd = (event) => {
  let touch = getTouch(event.changedTouches, currentDpadTouchId);
  if (touch != null) {
    let inputs = getInputs(currentDpadElement);
    setInputs(inputs, false);
    setArms(inputs, false);
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

// --- Joystick touch controls (body.joystick-controls swaps out the d-pad) ---
// The finger's vector from the stick center is quantized to the SAME 8-way
// carving the gamepad analog path uses (pollGamepads): past a radial
// deadzone, a direction bit goes down when its normalized axis component
// exceeds 0.4. At full deflection each cardinal spans ~133 degrees with ~43
// degree diagonal-overlap windows, so a 45-degree drag reliably presses both
// bits. Only press/release DELTAS are routed, like the d-pad handlers.
const JOY_DEADZONE = 0.35;    // radial deadzone, fraction of the base radius
const JOY_AXIAL = 0.4;        // same axis threshold as GP_DEADZONE
const JOY_KNOB_TRAVEL = 0.6;  // knob-center clamp, fraction of the radius

const joystickEl = document.getElementById("joystick");
const joyBaseEl = document.getElementById("joystick-base");
const joyKnobEl = document.getElementById("joystick-knob");
const joyRimEl = document.getElementById("joystick-rim");

var joyTouchId = null;
let joyBits = [false, false, false, false]; // Up / Down / Left / Right
let joyHome = null;   // base home center {x, y} + radius r (client coords)
let joyCenter = null; // live stick center — floating mode drags it around
let joyBounds = null; // clamp box for the floating center (region minus radius)

const joyClampCenter = () => {
  joyCenter.x = joyBounds.left > joyBounds.right
    ? (joyBounds.left + joyBounds.right) / 2
    : Math.min(joyBounds.right, Math.max(joyBounds.left, joyCenter.x));
  joyCenter.y = joyBounds.top > joyBounds.bottom
    ? (joyBounds.top + joyBounds.bottom) / 2
    : Math.min(joyBounds.bottom, Math.max(joyBounds.top, joyCenter.y));
};

// Route only the bits that changed; haptic + rim/knob feedback on changes.
const joyApplyBits = (want) => {
  let changed = false;
  for (let i = 0; i < 4; i++) {
    if (want[i] !== joyBits[i]) {
      routeP1Input(i, want[i]);
      joyBits[i] = want[i];
      changed = true;
    }
  }
  const any = joyBits.some(Boolean);
  joystickEl.classList.toggle("active", any);
  joyKnobEl.classList.toggle("pressed", any);
  if (any) {
    // The rim arc points at the QUANTIZED direction actually being sent
    // (0deg = up, clockwise), not the raw finger angle.
    const rx = (joyBits[3] ? 1 : 0) - (joyBits[2] ? 1 : 0);
    const ry = (joyBits[1] ? 1 : 0) - (joyBits[0] ? 1 : 0);
    joyRimEl.style.transform =
      `rotate(${(Math.atan2(rx, -ry) * 180) / Math.PI}deg)`;
    if (changed) haptic();
  }
};

const joyTrack = (cx, cy) => {
  let dx = cx - joyCenter.x;
  let dy = cy - joyCenter.y;
  let mag = Math.hypot(dx, dy);
  const r = joyHome.r;
  if (joystickMode === "floating" && mag > r) {
    // Finger crossed the rim: drag the base along behind it (classic
    // follow), but never out of the touch region — a runaway base would
    // slide under Select/Start and the face buttons.
    const pull = (mag - r) / mag;
    joyCenter.x += dx * pull;
    joyCenter.y += dy * pull;
    joyClampCenter();
    dx = cx - joyCenter.x;
    dy = cy - joyCenter.y;
    mag = Math.hypot(dx, dy);
  }
  const want = [false, false, false, false];
  if (mag > r * JOY_DEADZONE) {
    const ux = dx / mag;
    const uy = dy / mag;
    if (uy < -JOY_AXIAL) want[0] = true;
    if (uy > JOY_AXIAL) want[1] = true;
    if (ux < -JOY_AXIAL) want[2] = true;
    if (ux > JOY_AXIAL) want[3] = true;
  }
  // Base rides at its floating offset; knob chases the finger, clamped near
  // the rim. Transform-only, no layout.
  joyBaseEl.style.transform =
    `translate(${joyCenter.x - joyHome.x}px, ${joyCenter.y - joyHome.y}px)`;
  const lim = r * JOY_KNOB_TRAVEL;
  const scale = mag > lim ? lim / mag : 1;
  joyKnobEl.style.transform = `translate(${dx * scale}px, ${dy * scale}px)`;
  joyApplyBits(want);
};

const joystickTouchStart = (event) => {
  event.preventDefault();
  if (joyTouchId != null) return; // one finger drives the stick, like the d-pad
  const touch = event.changedTouches[0];
  joyTouchId = touch.identifier;
  joyBaseEl.classList.remove("homing");
  joyKnobEl.classList.remove("homing");
  // Measure the home geometry from the untranslated base
  joyBaseEl.style.transform = "";
  const rect = joyBaseEl.getBoundingClientRect();
  joyHome = {
    x: rect.left + rect.width / 2,
    y: rect.top + rect.height / 2,
    r: rect.width / 2,
  };
  if (joystickMode === "floating") {
    // The base spawns under the finger, clamped so it stays inside the
    // (generous) touch region — spawn and follow share the same clamp box.
    const region = joystickEl.getBoundingClientRect();
    joyBounds = {
      left: region.left + joyHome.r,
      right: region.right - joyHome.r,
      top: region.top + joyHome.r,
      bottom: region.bottom - joyHome.r,
    };
    joyCenter = { x: touch.clientX, y: touch.clientY };
    joyClampCenter();
  } else {
    joyCenter = { x: joyHome.x, y: joyHome.y };
  }
  joyTrack(touch.clientX, touch.clientY);
};

const joystickTouchMove = (event) => {
  event.preventDefault();
  if (joyTouchId == null) return;
  const touch = getTouch(event.targetTouches, joyTouchId);
  if (touch != null) joyTrack(touch.clientX, touch.clientY);
};

// Clear all bits and animate base + knob back home ("homing" enables the
// transform transition just for the return trip; the next touchstart strips
// it so live tracking stays transition-free).
const joystickRelease = () => {
  joyApplyBits([false, false, false, false]);
  joyBaseEl.classList.add("homing");
  joyKnobEl.classList.add("homing");
  joyBaseEl.style.transform = "";
  joyKnobEl.style.transform = "";
  joyTouchId = null;
};

const joystickTouchEnd = (event) => {
  if (joyTouchId == null) return;
  if (getTouch(event.changedTouches, joyTouchId) != null) joystickRelease();
};

// Safety valve for style/mode switches while a touch is live
const joystickForceRelease = () => {
  if (joyTouchId != null) joystickRelease();
};

joystickEl.addEventListener("touchstart", joystickTouchStart);
joystickEl.addEventListener("touchmove", joystickTouchMove);
joystickEl.addEventListener("touchend", joystickTouchEnd);
joystickEl.addEventListener("touchcancel", joystickTouchEnd);
