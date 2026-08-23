// Tab escape hatch: with focus in the chrome or a modal, Tab keeps moving
// focus. Window capture phase, registered before em.js, so it outranks the
// SDL runtime's key grab (which preventDefaults Tab app-wide once a game
// runs) and the fast-forward shortcut. keydown only, so a held fast-forward
// always gets its keyup. Stopping at window capture also hides the event
// from the modal's own Tab trap, so that handler is invoked directly.
window.addEventListener("keydown", (e) => {
  if (e.code !== "Tab" || !e.target || !(/** @type {Element} */ (e.target).closest)) return;
  const t = /** @type {Element} */ (e.target);
  if (t.closest("#topbar, #menu-dropdown")) {
    e.stopImmediatePropagation();
  } else if (t.closest(".modal-overlay.open")) {
    e.stopImmediatePropagation();
    if (modalTrapHandler) modalTrapHandler(e);
  }
}, true);

// Typing escape hatch: the SDL runtime's window-bubble key handlers
// preventDefault page-wide once a core runs. This sits at window-bubble too,
// registered before em.js so it runs first, and stops text-field events
// there. Bubble, not capture: the fields' own listeners must still see the
// target phase. Tab belongs to the hook above; Escape must keep flowing to
// the close-all-modals handler.
{
  const typingGuard = (e) => {
    if (e.code === "Tab" || e.code === "Escape") return;
    const t = e.target;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) {
      e.stopImmediatePropagation();
    }
  };
  for (const type of ["keydown", "keypress", "keyup"]) {
    window.addEventListener(type, typingGuard, false);
  }
}

// Browser-chord escape hatch: on the home screen modifier chords belong to
// the browser (Cmd/Ctrl+R, Alt+Left), which SDL's app-wide preventDefault
// and gameKeyHandler would otherwise swallow. Window capture hides the chord
// from every app handler while the default action still fires. Stands down
// in the running-game view: swallowing chords there is deliberate.
window.addEventListener("keydown", (e) => {
  if (!e.metaKey && !e.ctrlKey && !e.altKey) return;
  if (document.body.classList.contains("running")) return;
  const t = /** @type {HTMLElement} */ (e.target);
  if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
  e.stopImmediatePropagation();
}, true);

// --- Service Worker ---

let swRegistration = null;

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js").then((reg) => {
    if (!reg) return; // SW-blocked contexts (test harnesses) resolve undefined
    swRegistration = reg;
    if (reg.waiting) showUpdateButton();
    // The browser checks sw.js on navigation, so this fires on the first
    // load after a deploy.
    reg.addEventListener("updatefound", () => {
      let sw = reg.installing;
      sw.addEventListener("statechange", () => {
        if (sw.state === "installed" && navigator.serviceWorker.controller) {
          showUpdateButton();
        }
      });
    });
  });
  // Reload when a new worker takes over from an old one. The first visit's
  // clients.claim() also fires controllerchange; reloading then would abort
  // the em.wasm fetch mid-boot. hadController flips after any
  // controllerchange (not a load-time constant: a session that begins
  // uncontrolled becomes controlled by the first claim and a later Update
  // click must still reload); appUpdating covers the handover being the
  // first claim this page sees.
  let hadController = !!navigator.serviceWorker.controller;
  let refreshing = false;
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if ((hadController || appUpdating) && !refreshing) {
      refreshing = true;
      location.reload();
    }
    hadController = true;
  });
}

// ?2p reveals the per-tile local link-cable launcher (body.debug-2p).
if (new URLSearchParams(location.search).has("2p")) {
  document.body.classList.add("debug-2p");
}

// --- Update check ---

const UPDATE_CHECK_KEY = "dingbat_last_update_check";
const UPDATE_CHECK_INTERVAL = 24 * 60 * 60 * 1000; // 24 hours
const updateBtn = /** @type {HTMLButtonElement} */ (document.getElementById("update-btn"));
const updateModal = document.getElementById("update-modal");
let updateAvailable = false;

const showUpdateButton = () => {
  updateAvailable = true;
  updateBtn.hidden = false;
};

const checkForUpdate = async () => {
  try {
    // current: the cached version.txt; latest: a fresh one; deployed: the
    // CACHE_VERSION in a fresh sw.js. Pages' CDN propagates per-object, so
    // the button only shows once sw.js and version.txt agree, i.e. the
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
        // Still propagating: skip the stamp so the next visibility change retries.
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

maybeCheckForUpdate();

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") maybeCheckForUpdate();
});

// Full reset: caches and workers both. Deleting caches alone leaves the old
// worker in control of an empty cache it never repopulates.
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

// True once an update reload is committed; the Drive token renewal must not
// start a popup the reload will orphan.
var appUpdating = false;

const applyUpdate = async () => {
  appUpdating = true;
  // Busy until the reload lands (the install downloads every asset). Never
  // un-set: every path out of here ends in a reload.
  updateBtn.disabled = true;
  updateBtn.classList.add("updating");
  document.getElementById("update-label").textContent = "Updating…";
  closeUpdateModal();
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
        // controllerchange then reloads the page.
        installing.addEventListener("statechange", () => {
          if (installing.state === "installed") {
            installing.postMessage({ type: "skipWaiting" });
          } else if (installing.state === "redundant") {
            // Install failed (one bad asset fetch fails the whole install):
            // recover with the clean-slate path.
            fullResetReload();
          }
        });
        return;
      }
    } catch {}
  }
  // No new worker found (propagation lag): full clean slate.
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

// Force update: the live worker re-downloads every asset under a nonce
// (skips stale CDN edges and the browser HTTP cache), which works while the
// CDN still serves the previous sw.js. Falls back to the full reset.
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
  appUpdating = true; // see applyUpdate: no Drive popups once a reload is committed
  try {
    await forceUpdate();
  } catch (e) {
    appUpdating = false; // no reload happened after all; renewals may resume
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

// Viewport diagnostics: every quantity that determines the app column's
// height, for device logs. Logged at boot, ROM load, orientation changes.
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

// Mirror the console into the log view: the core's messages arrive via
// emscripten's print -> console.log, invisible on phones.
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

// One line of environment context, refreshed each time the log opens.
const logContext = async () => {
  let version = "unknown";
  try {
    // Cache-first: the build the tab is actually executing.
    version = (await (await fetch("version.txt")).text()).trim().slice(0, 12);
  } catch {}
  // ...and the origin's version (no-store bypasses sw.js), so a stale
  // running build is visible in the log.
  let originVersion = "";
  try {
    const fresh = (await (await fetch("version.txt", { cache: "no-store" })).text())
      .trim().slice(0, 12);
    if (fresh && fresh !== version) originVersion = fresh;
  } catch {}
  const versionField = originVersion
    ? version + " (origin " + originVersion + " \u2014 UPDATE PENDING)"
    : version;
  const sw = navigator.serviceWorker && navigator.serviceWorker.controller
    ? "sw:controlled" : "sw:none";
  // Vibration diagnostic: vibrate(0) returns true when supported and sticky
  // activation exists (the log is opened by a click, so it does).
  const vibSupported = "vibrate" in navigator;
  let vibTest = "n/a";
  if (vibSupported) {
    try { vibTest = String(navigator.vibrate(0)); } catch { vibTest = "err"; }
  }
  const act = navigator.userActivation
    ? String(navigator.userActivation.hasBeenActive) : "?";
  // hblk: haptic() calls whose vibrate() returned false, over total.
  const vib = `vibrate:${vibSupported} test:${vibTest} act:${act} firstAct:${firstActivationEvent || "none"} hblk:${hapticBlocked}/${hapticCalls}`;
  return `dingbat ${versionField} | ${sw} | ${window.innerWidth}x${window.innerHeight}@${devicePixelRatio} | ${vib} | ${navigator.userAgent}`;
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
      // navigator.clipboard only exists on secure origins.
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

// --- Modal focus management ---

let modalReturnFocus = null;
let modalTrapHandler = null;
let modalTrapOverlay = null; // which overlay owns the current trap

const modalFocusables = (overlay) =>
  Array.from(
    overlay.querySelectorAll("button, input, select, textarea, [tabindex]")
  ).filter(
    (n) => !n.disabled && n.offsetParent !== null && n.getAttribute("tabindex") !== "-1"
      // An `inert` subtree (the settings sheet's off-stage screen) is
      // unreachable by Tab, so by the trap too.
      && !n.closest?.("[inert]")
  );

const trapFocus = (overlay) => {
  modalTrapOverlay = overlay;
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
  // Only the owning overlay may release the trap: the global Escape handler
  // calls every modal's closer blindly.
  if (modalTrapOverlay !== overlay) return;
  modalTrapOverlay = null;
  if (modalTrapHandler) overlay.removeEventListener("keydown", modalTrapHandler);
  modalTrapHandler = null;
  try {
    // The return target may be display:none by now (a hidden menu item);
    // fall back to the menu button so focus stays in the chrome.
    if (modalReturnFocus && modalReturnFocus.focus) {
      if (modalReturnFocus.isConnected && modalReturnFocus.offsetParent !== null) {
        modalReturnFocus.focus();
      } else {
        menuBtn.focus();
      }
    }
  } catch {}
  modalReturnFocus = null;
};

// Give focus back to the game after a pointer-activated chrome control,
// else Tab walks the top bar instead of fast-forwarding. Pointer only: a
// keyboard-synthesised click (and el.click()) reports detail 0, and
// stealing focus there would dump the user at the top of the tab order.
const returnFocusToGame = (/** @type {any} */ ctl) => {
  if (ctl && typeof ctl.blur === "function") ctl.blur();
  // preventScroll: #home is a scroll container and scroll-into-view would
  // jump the library. If the canvas is display:none, the blur above suffices.
  if (canvasEl && typeof canvasEl.focus === "function") {
    try { canvasEl.focus({ preventScroll: true }); } catch { try { canvasEl.focus(); } catch {} }
  }
};

// Document bubble phase, so a control's own handler has already run (and a
// modal it opened is visible to anyModalOpen()).
document.addEventListener("click", (e) => {
  if (!e || e.detail === 0) return; // keyboard/programmatic activation
  const t = /** @type {any} */ (e.target);
  // Duck-typed: the target is often an inner <svg>, and tests dispatch bare objects.
  if (!t || typeof t.closest !== "function") return;
  // Modals and the menu run their own focus management.
  if (t.closest(".modal-overlay")) return;
  if (!t.closest("#topbar, #topbar-handle")) return;
  if (anyModalOpen()) return;
  const ctl = t.closest("button, [href], [tabindex]");
  // Text fields and range inputs keep focus (the typing escape hatch depends
  // on the field being document.activeElement).
  const tag = ctl && ctl.tagName;
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" ||
      (ctl && ctl.isContentEditable)) return;
  returnFocusToGame(ctl);
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

const dbKeys = () => new Promise((resolve, reject) => {
  let tx = db.transaction("blobs", "readonly");
  let req = tx.objectStore("blobs").getAllKeys();
  req.onsuccess = () => resolve(req.result || []);
  req.onerror = () => reject(req.error);
});

// Move keys and write unrelated records in one readwrite transaction (a
// game rename: a half-finished one would orphan a save from its ROM).
// `pairs` is [[from, to], ...]; an empty `from` is skipped. An occupied
// `to` aborts the whole transaction (collisions are refused, never merged)
// unless `skipCollisions`, in which case that pair is left in place and
// reported. `puts` is [[key, value], ...] in the same transaction.
// Resolves { moved, skipped }.
const dbMoveKeys = (pairs, puts = [], { skipCollisions = false } = {}) =>
  new Promise((resolve, reject) => {
  let tx = db.transaction("blobs", "readwrite");
  let store = tx.objectStore("blobs");
  let moved = [];
  let skipped = [];
  let failure = null;
  const fail = (msg) => {
    if (failure) return;
    failure = new Error(msg);
    try { tx.abort(); } catch {}
  };
  for (let [from, to] of pairs) {
    // Read the destination inside the transaction so the guard sees the same
    // snapshot the writes land in.
    let dest = store.get(to);
    dest.onsuccess = () => {
      if (failure) return;
      if (dest.result !== undefined && dest.result !== null) {
        if (!skipCollisions) {
          fail("Something is already stored under that name (" + to + ").");
          return;
        }
        let src = store.get(from);
        src.onsuccess = () => {
          if (!failure && src.result !== undefined && src.result !== null) {
            skipped.push([from, to]);
          }
        };
        return;
      }
      // Issued from a request callback to stay inside the transaction; an
      // `await` here would end it.
      let src = store.get(from);
      src.onsuccess = () => {
        if (failure) return;
        if (src.result === undefined || src.result === null) return;
        store.put(src.result, to);
        store.delete(from);
        moved.push([from, to]);
      };
    };
  }
  for (let [k, v] of puts) store.put(v, k);
  tx.oncomplete = () => resolve({ moved, skipped });
  tx.onabort = () => reject(failure || tx.error || new Error("The move was rolled back."));
  tx.onerror = () => reject(failure || tx.error || new Error("The move failed."));
});

const migrateFromLocalStorage = async () => {
  const decodeBase64 = (b64) => {
    let binary = atob(b64);
    let bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  };

  let gbaBios = localStorage.getItem("dingbat_bios");
  if (gbaBios) {
    let name = localStorage.getItem("dingbat_bios_name") || null;
    await dbPut("bios:gba", { name, data: decodeBase64(gbaBios) });
    localStorage.removeItem("dingbat_bios");
    localStorage.removeItem("dingbat_bios_name");
  }

  let gbcBootrom = localStorage.getItem("dingbat_gbc_bootrom");
  if (gbcBootrom) {
    let name = localStorage.getItem("dingbat_gbc_bootrom_name") || null;
    await dbPut("bios:gbc", { name, data: decodeBase64(gbcBootrom) });
    localStorage.removeItem("dingbat_gbc_bootrom");
    localStorage.removeItem("dingbat_gbc_bootrom_name");
  }

  // Recent ROMs go straight into the per-ROM layout: rom:<name> records
  // first, then the metadata-only index.
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

// Old single-record recents ([{ name, data, art? }] inline) -> per-ROM
// layout. ROM/art records are written before the index is rewritten, so an
// interrupted run is re-runnable.
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

// Sweep auto-resume snapshots whose game is neither stored nor in the
// library. "stateauto:" only: the one per-game record the app regenerates
// itself; user-authored records (cheats) are left alone even when orphaned.
const sweepOrphanedAutoStates = async () => {
  let keys = await dbKeys();
  let known = new Set();
  for (let k of keys) {
    if (typeof k === "string" && k.startsWith("rom:")) known.add(k.slice(4));
  }
  for (let r of await getRecentMeta()) if (r?.name) known.add(r.name);
  for (let k of keys) {
    if (typeof k !== "string" || !k.startsWith("stateauto:")) continue;
    if (!known.has(k.slice("stateauto:".length))) await dbDelete(k);
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

// Bottom scrim only while items sit below the fold. scrollHeight reads 0
// while hidden, so the open-time call does the first real measurement.
const updateMenuScrollHint = () => {
  menuDropdown.classList.toggle(
    "can-scroll-down",
    menuDropdown.scrollTop + menuDropdown.clientHeight <
      menuDropdown.scrollHeight - 1,
  );
};

menuBtn.addEventListener("click", (e) => {
  e.stopPropagation();
  menuDropdown.hidden = !menuDropdown.hidden;
  if (!menuDropdown.hidden) {
    // Fresh open starts with Capture folded (guarded for the pre-parse window).
    if (typeof collapseCaptureSub === "function") collapseCaptureSub();
    updateMenuScrollHint();
  }
});

// aria-expanded tracks `hidden` wherever the dropdown gets closed.
new MutationObserver(() =>
  menuBtn.setAttribute("aria-expanded", String(!menuDropdown.hidden))
).observe(menuDropdown, { attributes: true, attributeFilter: ["hidden"] });

menuDropdown.addEventListener("scroll", updateMenuScrollHint, { passive: true });
window.addEventListener("resize", updateMenuScrollHint);

document.addEventListener("click", () => {
  menuDropdown.hidden = true;
});

// The switches' visible text lives in a sibling div, not the <label>, so
// link input -> row label (and description) once at boot.
for (const row of document.querySelectorAll(".modal-toggle-row")) {
  const label = row.querySelector(".modal-row-label");
  const input = row.querySelector("input, select");
  if (!label || !input || input.hasAttribute("aria-label")) continue;
  if (!label.id) label.id = (input.id || "row" + Math.random().toString(36).slice(2)) + "-label";
  input.setAttribute("aria-labelledby", label.id);
  const sub = row.querySelector(".modal-toggle-sub");
  if (sub) {
    if (!sub.id) sub.id = label.id + "-sub";
    input.setAttribute("aria-describedby", sub.id);
  }
}

// --- Settings modal ---

const settingsModal = document.getElementById("settings-modal");
const gbaBiosStatus = document.getElementById("gba-bios-status");
const gbaRunBiosRow = document.getElementById("gba-run-bios-row");
const gbaBiosModeGroup = document.getElementById("gba-bios-mode-group");
const gbaBiosModeRadios = /** @type {NodeListOf<HTMLInputElement>} */ (
  document.querySelectorAll('input[name="gba-bios-mode"]'));
const gbcBootromStatus = document.getElementById("gbc-bootrom-status");

const updateBiosStatusText = async () => {
  let gba = await dbGet("bios:gba");
  gbaBiosStatus.textContent = gba ? gba.name || "Set" : "Not set";
  let gbc = await dbGet("bios:gbc");
  gbcBootromStatus.textContent = gbc ? gbc.name || "Set" : "Not set";
  // With no BIOS file the intro and call-mode rows are inert but keep their
  // stored values.
  const noBios = !gba;
  gbaRunBiosToggle.disabled = noBios;
  gbaRunBiosRow.classList.toggle("row-disabled", noBios);
  gbaBiosModeGroup.classList.toggle("row-disabled", noBios);
  for (const r of gbaBiosModeRadios) r.disabled = noBios;
};

// iOS/iPadOS (iPad reports as "MacIntel" with touch points since iPadOS 13).
const IS_IOS = /iP(hone|ad|od)/.test(navigator.platform) ||
  (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);

const pickFile = (accept, callback) => {
  let input = document.createElement("input");
  input.type = "file";
  // iOS Safari greys out any file whose extension has no UTI (.sav/.state/
  // .bin), so the accept filter is skipped there.
  if (accept && !IS_IOS) input.accept = accept;
  // iOS Safari needs the input in the DOM and not display:none for the
  // picker to open.
  input.style.position = "fixed";
  input.style.left = "-9999px";
  input.style.opacity = "0";
  document.body.appendChild(input);
  const done = () => input.remove();
  input.addEventListener("change", () => {
    if (input.files?.length > 0) {
      let file = input.files[0];
      let reader = new FileReader();
      reader.addEventListener("load", () => { callback(new Uint8Array(/** @type {ArrayBuffer} */ (reader.result)), file.name); done(); });
      reader.addEventListener("error", done);
      reader.readAsArrayBuffer(file);
    } else done();
  });
  input.addEventListener("cancel", done);  // dismissed without picking
  input.click();
};

// --- Settings navigation ----------------------------------------------------
// Layout is CSS's (styles.css "Settings surface"); this owns which section
// shows, which screen the sheet is on, and the sheet-only navigation
// (push/pop, stepper, hardware back). Section order is fixed.
const SETTINGS_SECTIONS = ["controls", "gb", "gba", "video", "audio", "general"];
const SETTINGS_LAST_KEY = "settings-section";

const settingsTabs = Array.from(/** @type {NodeListOf<HTMLElement>} */ (document.querySelectorAll(".settings-tab")));
const settingsFrame = document.getElementById("settings-frame");
const settingsBody = /** @type {HTMLElement} */ (
  settingsFrame.querySelector(".settings-body"));
const settingsRail = document.getElementById("settings-rail");
const settingsContent = document.getElementById("settings-content");
const settingsScroll = document.getElementById("settings-scroll");
const settingsSectionTitle = document.getElementById("settings-section-title");
const settingsBackBtn = document.getElementById("settings-back");
const settingsPrevBtn = document.getElementById("settings-prev");
const settingsNextBtn = document.getElementById("settings-next");
// Two copies of the build identity, one per layout; CSS displays one.
const settingsVersionEls = Array.from(
  /** @type {NodeListOf<HTMLElement>} */ (document.querySelectorAll(".settings-version")));

// Width only, never pointer type: an iPad at 1024 gets the rail.
const settingsSheetQuery = window.matchMedia("(max-width: 759px)");
const settingsIsSheet = () => settingsSheetQuery.matches;

const settingsTabOf = (sec) => settingsTabs.find((t) => t.dataset.tab === sec);
const settingsName = (sec) => settingsTabOf(sec)?.dataset.name || "";
const settingsStep = (sec, delta) => {
  const n = SETTINGS_SECTIONS.length;
  return SETTINGS_SECTIONS[(SETTINGS_SECTIONS.indexOf(sec) + delta + n) % n];
};

let settingsSection = SETTINGS_SECTIONS[0];
let settingsOnDetail = false;

const selectSettingsTab = (name) => {
  if (!SETTINGS_SECTIONS.includes(name)) name = SETTINGS_SECTIONS[0];
  settingsSection = name;
  for (const t of settingsTabs) {
    const on = t.dataset.tab === name;
    t.classList.toggle("active", on);
    t.setAttribute("aria-selected", on ? "true" : "false");
    // Roving tabindex.
    t.setAttribute("tabindex", on ? "0" : "-1");
    const pane = document.getElementById("settings-pane-" + t.dataset.tab);
    if (pane) pane.hidden = !on;
  }
  settingsSectionTitle.textContent = settingsName(name);
  settingsPrevBtn.setAttribute(
    "aria-label", "Previous section: " + settingsName(settingsStep(name, -1)));
  settingsNextBtn.setAttribute(
    "aria-label", "Next section: " + settingsName(settingsStep(name, 1)));
  // Always top, never a restored per-section offset.
  settingsScroll.scrollTop = 0;
  try { localStorage.setItem(SETTINGS_LAST_KEY, name); } catch {}
};

// The off-stage sheet screen is still painted mid-slide; `inert` keeps it
// out of Tab and the focus trap (modalFocusables skips inert subtrees).
const applySettingsScreen = () => {
  const sheet = settingsIsSheet();
  settingsFrame.classList.toggle("on-detail", sheet && settingsOnDetail);
  const off = !sheet ? null : settingsOnDetail ? settingsRail : settingsContent;
  for (const el of [settingsRail, settingsContent]) {
    if (el === off) el.setAttribute("inert", "");
    else el.removeAttribute("inert");
  }
};

// One history entry per sheet level, so Android's back gesture matches.
// Sheet layout only.
const settingsHistOk = typeof history !== "undefined" && !!history.pushState;
let settingsHistDepth = 0;   // our entries still on the stack
let settingsHistSkip = 0;    // popstate events we caused ourselves

const settingsHistPush = () => {
  if (!settingsHistOk) return;
  settingsHistDepth++;
  try { history.pushState({ dingbatSettings: settingsHistDepth }, ""); }
  catch { settingsHistDepth--; }
};

// Drop n of our entries; history.go() fires one popstate however far it goes.
const settingsHistDrop = (n) => {
  if (!settingsHistOk || settingsHistDepth <= 0 || n <= 0) return;
  n = Math.min(n, settingsHistDepth);
  settingsHistDepth -= n;
  settingsHistSkip++;
  try { history.go(-n); } catch { settingsHistSkip--; }
};

const showSettingsList = (fromHistory) => {
  if (!settingsOnDetail) return;
  settingsOnDetail = false;
  if (!fromHistory) settingsHistDrop(1);
  applySettingsScreen();
  settingsTabOf(settingsSection)?.focus({ preventScroll: true });
  settingsBody.scrollLeft = 0;
};

const openSettingsSection = (name) => {
  selectSettingsTab(name);
  if (!settingsIsSheet() || settingsOnDetail) return;
  settingsOnDetail = true;
  settingsHistPush();
  applySettingsScreen();
  // preventScroll is required: Back is inside the detail screen, still
  // translated off to the right, and a plain focus() scrolls .settings-body
  // to reveal it even though it is overflow:hidden. Same in showSettingsList.
  settingsBackBtn.focus({ preventScroll: true });
  settingsBody.scrollLeft = 0;
};

window.addEventListener("popstate", () => {
  if (settingsHistSkip > 0) { settingsHistSkip--; return; }
  if (settingsHistDepth <= 0) return;
  settingsHistDepth--;
  if (settingsOnDetail) showSettingsList(true);
  else closeSettingsModal(true);
});

// Layout can change under an open dialog (rotation); the sheet then shows
// the section a desktop reader was already on.
settingsSheetQuery.addEventListener?.("change", () => {
  if (settingsIsSheet() && settingsModal.classList.contains("open")) {
    settingsOnDetail = true;
  }
  applySettingsScreen();
});

for (const t of settingsTabs) {
  t.addEventListener("click", () => {
    if (settingsIsSheet()) openSettingsSection(t.dataset.tab);
    else selectSettingsTab(t.dataset.tab);
  });
}

// Rail keyboard: on the rail a move selects; on the sheet's list it only
// moves focus.
document.getElementById("settings-tabs").addEventListener("keydown", (e) => {
  const keys = { ArrowUp: -1, ArrowDown: 1, Home: 0, End: 0 };
  if (!(e.key in keys)) return;
  e.preventDefault();
  const to = e.key === "Home" ? SETTINGS_SECTIONS[0]
    : e.key === "End" ? SETTINGS_SECTIONS[SETTINGS_SECTIONS.length - 1]
    : settingsStep(settingsSection, keys[e.key]);
  if (settingsIsSheet()) settingsTabOf(to)?.focus();
  else { selectSettingsTab(to); settingsTabOf(to)?.focus(); }
});

settingsBackBtn.addEventListener("click", () => showSettingsList());
settingsPrevBtn.addEventListener("click", () => selectSettingsTab(settingsStep(settingsSection, -1)));
settingsNextBtn.addEventListener("click", () => selectSettingsTab(settingsStep(settingsSection, 1)));

// Swipe down to dismiss, from the chrome or from content whose scroller is
// at the top. From the chrome it drags on contact; in the content it stays
// pending until the move is clearly downward, and is abandoned the moment
// it looks like a scroll.
const SHEET_DRAG_SLOP = 8;     // px before a content drag commits
const SHEET_DRAG_CLOSE = 90;   // px of travel that counts as a dismissal
const SHEET_DRAG_EXPAND = 40;  // px UP on the chrome that fills the screen
// Below this much spare room the expand gesture is not offered.
const SHEET_EXPAND_MIN_GAIN = 80;
let sheetDragFrom = 0;
let sheetDragX0 = 0;
let sheetDragDy = null;       // non-null once committed
let sheetDragPending = false;
let sheetDragScroller = null;
let sheetDragOnChrome = false;
let sheetExpanded = false;

const sheetCanExpand = () => {
  if (sheetExpanded) return false;
  const h = settingsFrame.getBoundingClientRect().height;
  const vh = window.visualViewport?.height || window.innerHeight;
  return vh - h >= SHEET_EXPAND_MIN_GAIN;
};

const setSheetExpanded = (on) => {
  sheetExpanded = on;
  settingsFrame.classList.toggle("sheet-expanded", on);
};

const sheetScrollerFor = (el) =>
  el?.closest?.(".settings-scroll, .settings-rail-body") || null;

const endSheetDrag = () => {
  sheetDragPending = false;
  sheetDragScroller = null;
  if (sheetDragDy === null) return;
  const dy = sheetDragDy;
  const onChrome = sheetDragOnChrome;
  sheetDragDy = null;
  sheetDragOnChrome = false;
  settingsFrame.classList.remove("sheet-dragging");
  settingsFrame.style.transform = "";
  // Upward, from the chrome only: take the whole screen.
  if (dy <= -SHEET_DRAG_EXPAND && onChrome) {
    if (sheetCanExpand()) setSheetExpanded(true);
    return;
  }
  if (dy > SHEET_DRAG_CLOSE) {
    if (!sheetExpanded) { closeSettingsModal(); return; }
    // Expanded: a short pull steps back to normal height, one past halfway
    // (of the frame) dismisses outright.
    const half = settingsFrame.getBoundingClientRect().height / 2;
    if (dy >= half) closeSettingsModal();
    else setSheetExpanded(false);
  }
};

const commitSheetDrag = () => {
  sheetDragPending = false;
  sheetDragDy = 0;
  settingsFrame.classList.add("sheet-dragging");
};

settingsFrame.addEventListener("pointerdown", (e) => {
  if (!settingsIsSheet()) return;
  const target = /** @type {Element} */ (e.target);
  sheetDragFrom = e.clientY;
  sheetDragX0 = e.clientX;
  if (target?.closest?.(".settings-grab, .settings-rail-head, .settings-head")) {
    sheetDragOnChrome = true;
    commitSheetDrag();
    return;
  }
  // In content: only if the scroller under the finger is at the top. A tap
  // never reaches SHEET_DRAG_SLOP, so controls still work.
  const scroller = sheetScrollerFor(target);
  if (!scroller || scroller.scrollTop > 0) return;
  sheetDragScroller = scroller;
  sheetDragPending = true;
});

settingsFrame.addEventListener("pointermove", (e) => {
  const dy = e.clientY - sheetDragFrom;
  if (sheetDragPending) {
    // It was a scroll after all.
    if ((sheetDragScroller && sheetDragScroller.scrollTop > 0) ||
        dy < -2 || Math.abs(e.clientX - sheetDragX0) > Math.abs(dy)) {
      sheetDragPending = false;
      sheetDragScroller = null;
      return;
    }
    if (dy < SHEET_DRAG_SLOP) return;
    commitSheetDrag();
  }
  if (sheetDragDy === null) return;
  sheetDragDy = dy;
  // Only the downward half is previewed: translating upward would lift the
  // bottom-anchored sheet off its edge. Expansion lands on release.
  settingsFrame.style.transform = "translateY(" + Math.max(0, dy) + "px)";
});

// Non-passive: once the drag is committed the scroller must stop
// rubber-banding, and pointer events cannot preventDefault the touch scroll.
settingsFrame.addEventListener("touchmove", (e) => {
  if (sheetDragDy !== null && e.cancelable) e.preventDefault();
}, { passive: false });

settingsFrame.addEventListener("pointerup", endSheetDrag);
settingsFrame.addEventListener("pointercancel", endSheetDrag);

const copySettingsVersion = async () => {
  const text = (settingsVersionEls[0]?.textContent || "").trim();
  if (!text) return;
  try {
    if (!navigator.clipboard) throw new Error("no clipboard");
    await navigator.clipboard.writeText(text);
    showToast("Copied " + text);
  } catch {
    showToast("Couldn't access the clipboard");
  }
};
for (const el of settingsVersionEls) {
  el.addEventListener("click", copySettingsVersion);
  el.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); copySettingsVersion(); }
  });
}

const openSettingsModal = () => {
  menuDropdown.hidden = true;
  // version.txt through the SW cache = the running build's commit.
  fetch("version.txt")
    .then((r) => (r.ok ? r.text() : ""))
    .then((v) => {
      const text = v ? "dingbat " + v.trim().slice(0, 12) : "";
      for (const el of settingsVersionEls) el.textContent = text;
    })
    .catch(() => {});
  updateBiosStatusText();
  kbSelection = -1;
  kbPreset.value = detectPreset(activeBindings);
  renderKbBindings();
  // Fresh open starts with Advanced folded (guarded for the pre-parse window).
  if (typeof collapseAdvanced === "function") collapseAdvanced();
  // The remembered section stays selected, but the sheet always opens on
  // the list rather than drilled into it.
  let last = null;
  try { last = localStorage.getItem(SETTINGS_LAST_KEY); } catch {}
  selectSettingsTab(last || SETTINGS_SECTIONS[0]);
  settingsOnDetail = false;
  applySettingsScreen();
  if (settingsIsSheet()) settingsHistPush();
  settingsModal.classList.add("open");
  // Both input handlers stand down while this modal is up, so a button held
  // across the open never sees its release: clear the input display.
  clearInputDisplay();
  document.addEventListener("keydown", kbKeyHandler, true);
  trapFocus(settingsModal);
};

const closeSettingsModal = (fromHistory) => {
  kbSelection = -1;
  if (!fromHistory) settingsHistDrop(settingsHistDepth);
  settingsHistDepth = 0;
  settingsOnDetail = false;
  // Expansion is not a preference; the sheet starts collapsed every time.
  setSheetExpanded(false);
  settingsModal.classList.remove("open");
  document.removeEventListener("keydown", kbKeyHandler, true);
  releaseFocus(settingsModal);
};

document.getElementById("open-settings").addEventListener("click", openSettingsModal);
for (const id of ["settings-close", "settings-close-list"]) {
  document.getElementById(id).addEventListener("click", () => closeSettingsModal());
}

// Force Update and Toggle Log hand the screen to something else, so Settings
// closes first; registered ahead of each button's own handler.
for (const id of ["force-update", "show-log"]) {
  document.getElementById(id).addEventListener("click", () => closeSettingsModal());
}

// Advanced refolds on every open of Settings.
const advancedToggle = document.getElementById("advanced-toggle");
const advancedSub = document.getElementById("advanced-sub");
const collapseAdvanced = () => {
  advancedSub.hidden = true;
  advancedToggle.setAttribute("aria-expanded", "false");
};
advancedToggle.addEventListener("click", () => {
  advancedSub.hidden = !advancedSub.hidden;
  advancedToggle.setAttribute("aria-expanded", advancedSub.hidden ? "false" : "true");
});

settingsModal.addEventListener("click", (e) => {
  if (e.target === settingsModal) closeSettingsModal();
});

// BIOS / bootrom files update FS and IndexedDB on pick; the next core
// construction reads the FS file.
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

// --- Manage Saves modal ---

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
// JS owns the list ({name, codes, enabled, error}); the core owns the parsed
// form. Every edit serializes to ".cht", pushes via load_cheats (returns
// parse errors) and persists under "cheats:<originalName>". Adds are
// validated up front; `error` is only non-empty on entries persisted by
// older builds.

const cheatsModal = document.getElementById("cheats-modal");
const cheatsListEl = document.getElementById("cheats-list");
const cheatNameEl = /** @type {HTMLInputElement} */ (document.getElementById("cheat-name"));
const cheatCodesEl = /** @type {HTMLTextAreaElement} */ (document.getElementById("cheat-codes"));
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
      cur = { enabled: line[1] === "x" || line[1] === "X", name: line.slice(3).trim(), codes: "", error: "" };
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

// Probe-parse one cheat alone (core parsing is per-cheat, so the verdict is
// the same as inside the full list). load_cheats replaces the core's set,
// so the caller must re-push the real list afterwards.
const validateCheat = (c) => {
  const err = pushCheatsToCore(serializeCheats([c]));
  // Strip the core's cheat-name prefix.
  const prefix = (c.name || "?") + ": ";
  return err.startsWith(prefix) ? err.slice(prefix.length) : err;
};

// The add form's error line: describes its current text only.
const showCheatError = (err) => {
  if (err && err.length) {
    cheatErrorEl.textContent = err;
    cheatErrorEl.hidden = false;
    cheatCodesEl.setAttribute("aria-invalid", "true");
  } else {
    cheatErrorEl.hidden = true;
    cheatCodesEl.removeAttribute("aria-invalid");
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
    cb.setAttribute("aria-label", "Enable " + (c.name || "cheat"));
    cb.addEventListener("change", () => { cheatList[i].enabled = cb.checked; applyCheats(); });
    const info = document.createElement("div");
    info.className = "cheat-row-info";
    const nm = document.createElement("span");
    nm.className = "cheat-row-name";
    nm.textContent = c.name || "Cheat " + (i + 1);
    if (c.error) {
      // Unvalidated legacy entries: the core skips them, so say so.
      row.classList.add("cheat-row-invalid");
      cb.checked = false;
      cb.disabled = true;
      const bad = document.createElement("span");
      bad.className = "cheat-badge-invalid";
      bad.textContent = "Invalid";
      bad.title = c.error;
      nm.appendChild(bad);
    }
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
  if (currentOriginalName) {
    // Every entry was validated on add or badged by restoreCheats, so this
    // cannot produce new errors for the add form.
    pushCheatsToCore(text);
    if (cheatList.length) await dbPut(CHEATS_KEY(currentOriginalName), text);
    else await dbDelete(CHEATS_KEY(currentOriginalName));
  }
  renderCheatList();
};

// From loadRom after the core is built.
const restoreCheats = async () => {
  cheatList = [];
  if (currentOriginalName) {
    const text = await dbGet(CHEATS_KEY(currentOriginalName));
    if (typeof text === "string" && text) cheatList = parseCheats(text);
  }
  // Probe each entry so legacy unvalidated ones can be badged "Invalid".
  for (const c of cheatList) c.error = validateCheat(c);
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
  const candidate = { name, codes, enabled: true, error: "" };
  const err = validateCheat(candidate);
  if (err) {
    // Reject: re-push the untouched list (the probe replaced the core's set)
    // and leave the text in the form.
    pushCheatsToCore(serializeCheats(cheatList));
    showCheatError(err);
    return;
  }
  cheatList.push(candidate);
  cheatNameEl.value = "";
  cheatCodesEl.value = "";
  showCheatError("");
  applyCheats();
});

cheatNameEl.addEventListener("input", () => showCheatError(""));
cheatCodesEl.addEventListener("input", () => showCheatError(""));

// --- Delete save data (per-ROM) ---

// Two-step inline confirm button: first tap arms, a second within 3.5s runs
// onConfirm. `disarm()` lets a caller reset a sibling.
/** @param {{label: string, confirmLabel?: string, className?: string,
 *          onConfirm: () => any, onArm?: () => any}} opts */
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

const makeDisabledButton = (label, className, title) => {
  let btn = document.createElement("button");
  btn.type = "button";
  btn.className = className;
  btn.textContent = label;
  btn.disabled = true;
  if (title) btn.title = title;
  return btn;
};

// Like makeDisabledButton but still tappable: mobile has no hover, so the
// reason is a toast on tap as well as the tooltip.
const makeInertButton = (label, className, reason) => {
  let btn = document.createElement("button");
  btn.type = "button";
  btn.className = className + " is-inert";
  btn.textContent = label;
  btn.setAttribute("aria-disabled", "true");
  btn.title = reason;
  btn.addEventListener("click", () => showToast(reason));
  return btn;
};

const romsWithSaveData = async () => {
  let names = new Set();
  for (let k of await dbKeys()) {
    if (typeof k !== "string") continue;
    if (k.startsWith("save:")) {
      let n = k.slice(5);
      if (n.endsWith("-p2")) n = n.slice(0, -3); // fold P2 link save into base
      names.add(n);
    } else if (k.startsWith("state:")) {
      // Fold numbered slots into the base ROM identity.
      names.add(k.slice(6).replace(/:slot\d+$/, ""));
    }
  }
  return [...names].sort((a, b) => a.localeCompare(b));
};

// The game held in memory: deleting its stored save would be re-persisted
// by the next autosave flush.
const isRomLoaded = (name) =>
  (!!currentOriginalName && currentOriginalName === name) ||
  (linkMode && !!linkRomEntry && linkRomEntry.name === name);

// The inventory of everything stored for one game. Every destructive path
// works from this; a record not listed here survives a delete.
//   bytes    ROM image + box art (re-downloadable from Drive)
//   saves    battery saves (P1 + 2P partner) and the nine state slots with
//            their meta; the only group Drive mirrors besides the ROM
//   session  the auto-resume snapshot; regenerated, never synced
//   prefs    the cheat list; never synced
const perGameKeys = (name) => {
  let saves = ["save:" + name, "save:" + name + "-p2"];
  // Slot 0 is the legacy un-suffixed "state:<name>" / "statemeta:<name>" pair.
  for (let s = 0; s < NUM_STATE_SLOTS; s++) {
    saves.push(slotStateKey(name, s), slotMetaKey(name, s));
  }
  return {
    bytes: [romKey(name), artKey(name)],
    saves,
    session: [autoStateKey(name)],
    prefs: [CHEATS_KEY(name)],
  };
};

const allPerGameKeys = (name) => Object.values(perGameKeys(name)).flat();

const deleteKeys = async (keys) => {
  for (let k of keys) await dbDelete(k);
};

// Remove one ROM's save data. The auto-resume snapshot goes with it: it is
// a full save state, and "Resume" would restore the wiped progress.
const deleteSaveData = async (name) => {
  let k = perGameKeys(name);
  await deleteKeys([...k.saves, ...k.session]);
};

// Remove every trace of one game from this device. Drive is untouched here.
const deleteGameLocalData = async (name) => {
  await deleteKeys(allPerGameKeys(name));
};

// Wipe the running game's battery save and reboot it; state slots stay.
const resetCurrentSaveFile = async () => {
  if (!currentOriginalName) return;
  await dbDelete("save:" + currentOriginalName);
  await dbDelete("save:" + currentOriginalName + "-p2");
  // The reboot ends in offerAutoResume, which would offer to un-reset.
  await deleteKeys(perGameKeys(currentOriginalName).session);
  markDelete("save:" + currentOriginalName);
  markDelete("save:" + currentOriginalName + "-p2");
  // Drops the FS .sav and reboots, so the autosave cannot re-flush it.
  resetLoadedGameSave();
};

// Reboot the loaded game with no battery save (after its stored save is gone).
const resetLoadedGameSave = () => {
  if (!currentRomName || !currentOriginalName) return;
  let romName = currentRomName;
  let originalName = currentOriginalName;
  try { FS.unlink(stripExt(romName) + ".sav"); } catch {}
  // Null these first so loadRom's "persist previous save" step is skipped,
  // else it writes the old save straight back to the deleted key.
  currentRomName = null;
  currentOriginalName = null;
  loadRom(romName, originalName);
};

// "Reset save file": a persistent two-step confirm button.
const resetSaveSlot = document.getElementById("reset-save-slot");
if (resetSaveSlot) {
  const resetSaveBtn = makeConfirmButton({
    label: "Reset",
    confirmLabel: "Confirm reset?",
    className: "button button-sm saves-reset-btn",
    onConfirm: async () => {
      await resetCurrentSaveFile();
      // The button persists across the reboot: re-enable and disarm it.
      resetSaveBtn.disabled = false;
      resetSaveBtn.disarm();
      closeSavesModal();
      showToast("Save reset — starting fresh");
    },
  });
  resetSaveSlot.appendChild(resetSaveBtn);
}

// --- Manage ROMs and Saves modal ---
// One row per stored game: recents first, then any ROM whose save data
// outlived its recents entry.

const romsModal = document.getElementById("roms-modal");
const romsManageList = document.getElementById("roms-manage-list");
const romsManageEmpty = document.getElementById("roms-manage-empty");
// Hidden while signed out, when the per-row Remove button doesn't render.
const romsHintRemove = document.getElementById("roms-hint-remove");
// Sign-in state the rows were last rendered under: a routine repaint must
// not disarm an armed confirm button.
let romsRowsSignedIn = null;

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

// "recent" is the grid's play order; "alpha" for auditing a long library.
let romsSort = "recent";
const romsSortBtn = document.getElementById("roms-sort");

const loadRomsSort = async () => {
  let v = await dbGet("roms_sort");
  if (v === "recent" || v === "alpha") romsSort = v;
  syncRomsSortButton();
};
const syncRomsSortButton = () => {
  if (!romsSortBtn) return;
  romsSortBtn.textContent =
    romsSort === "alpha" ? "Sort: A–Z" : "Sort: Last played";
  romsSortBtn.title = romsSort === "alpha"
    ? "Sorted alphabetically — click to sort by last played"
    : "Sorted by last played — click to sort alphabetically";
};
if (romsSortBtn) {
  romsSortBtn.addEventListener("click", async () => {
    romsSort = romsSort === "alpha" ? "recent" : "alpha";
    syncRomsSortButton();
    await dbPut("roms_sort", romsSort);
    refreshRomsManageList();
  });
}

// Rows: recents first, then orphaned save-only games by name; under "alpha"
// one merged A-Z list. { name, inRecent }.
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
  if (romsSort === "alpha") {
    rows.sort((a, b) => a.name.localeCompare(b.name));
  }
  return rows;
};

// The rename pencil; currentColor so it follows the button's states.
const PENCIL_ICON =
  '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
  '<path d="M4 20.5h4.2L19 9.7a2.4 2.4 0 0 0-3.4-3.4L4.8 17.1v3.4z"/>' +
  '<path d="M14.3 7.6l3.4 3.4"/></svg>';

const refreshRomsManageList = async () => {
  if (!db) return;
  romsRowsSignedIn = driveLinked();
  romsHintRemove.hidden = !driveLinked();
  let rows = await romsForManagement();
  // What this device actually holds decides each row's buttons.
  let keys = await dbKeys();
  let localRoms = new Set();
  for (let k of keys) {
    if (typeof k === "string" && k.startsWith("rom:")) localRoms.add(k.slice(4));
  }
  let withSaves = new Set(await romsWithSaveData());
  romsManageList.innerHTML = "";
  romsManageEmpty.hidden = rows.length > 0;
  syncRomsSortButton();
  if (romsSortBtn) romsSortBtn.parentElement.hidden = rows.length < 2;

  for (let { name, inRecent } of rows) {
    let row = document.createElement("div");
    row.className = "roms-manage-row";

    // A live 2P link has two cores writing this ROM's saves: delete, reset
    // and rename are all blocked until link mode exits.
    let linkRunning = linkMode && linkRomEntry && linkRomEntry.name === name;

    // The title on .roms-manage-name is how the rest of the app identifies a row.
    let label = document.createElement("div");
    label.className = "roms-manage-name";
    label.title = name; // full filename (with extension) for disambiguation
    let title = document.createElement("span");
    title.className = "roms-manage-title";
    title.textContent = displayName(name);
    label.appendChild(title);
    let renameBtn = document.createElement("button");
    renameBtn.type = "button";
    renameBtn.className = "roms-rename-btn";
    // Icon-only: the accessible name says which game.
    renameBtn.setAttribute("aria-label", "Rename " + displayName(name));
    renameBtn.innerHTML = PENCIL_ICON;
    // Drive-only rows rename too (a metadata PATCH needs no bytes here).
    if (linkRunning) {
      renameBtn.disabled = true;
      renameBtn.title = "Exit link mode to rename this game";
    } else {
      renameBtn.title = "Rename this game and everything saved with it";
      renameBtn.addEventListener("click", () => openRenameModal(name));
    }
    label.appendChild(renameBtn);
    row.appendChild(label);

    let actions = document.createElement("div");
    actions.className = "roms-manage-actions";

    // "Delete Everything" on the game in memory unloads it first (unloadGame
    // detaches it from the autosave flush).

    // Arming one button disarms any other in the row.
    let siblings = [];
    const disarmOthers = (except) => {
      for (let b of siblings) if (b !== except && b.disarm) b.disarm();
    };

    // Reset = wipe save data, keep the ROM. Remove from device = free this
    // device's ROM bytes, keep saves and the Drive copy. Sync to device =
    // the inverse (downloadGame). Delete = ROM + saves, tombstoned on Drive
    // when signed in. Reset renders on every row but only arms when there
    // is something to wipe; otherwise greyed with the reason.
    let driveOnly = !localRoms.has(name);
    let stateKeyOfGame = (k) =>
      k === "state:" + name || k.startsWith("state:" + name + ":slot");
    let savesOnDrive = driveLinked() && Object.keys(syncState.rmt || {}).some(
      (k) => k === "save:" + name || k === "save:" + name + "-p2" || stateKeyOfGame(k));
    let hasSaves = withSaves.has(name) || savesOnDrive;
    let saveBtn = null;
    if (hasSaves && linkRunning) {
      saveBtn = makeDisabledButton(
        "Reset",
        "button button-sm roms-manage-btn",
        "Exit link mode to reset this game's save",
      );
    } else if (!hasSaves) {
      saveBtn = makeInertButton(
        "Reset",
        "button button-sm roms-manage-btn",
        "No saves to reset",
      );
    } else {
      saveBtn = makeConfirmButton({
        label: "Reset",
        confirmLabel: "Delete all save data?",
        className: "button button-sm roms-manage-btn",
        onArm: () => disarmOthers(saveBtn),
        onConfirm: async () => {
          await resetGameSaves(name);
          if (isRomLoaded(name)) {
            // Else the in-memory save re-flushes.
            resetLoadedGameSave();
            closeRomsModal();
            showToast("Save data deleted — starting fresh");
          } else {
            showToast("Save data deleted");
            refreshRomsManageList();
            updateStorageInfo();
          }
        },
      });
    }
    if (saveBtn) siblings.push(saveBtn);

    // Remove needs: signed in, bytes here, and Drive has the ROM
    // (sigs["rom:<name>"] with no delete queued). A just-imported game whose
    // upload is still queued has no sig, so it gets no button: the only copy
    // is never evictable. Sigs can go stale, so removeGameFromDevice
    // re-checks the live listing before deleting.
    let romOnDrive = driveLinked() && !!syncState.sigs[romKey(name)] &&
      !syncState.queueDel.includes(romKey(name));
    let freeBtn = null;
    if (localRoms.has(name) && driveLinked() && !romOnDrive) {
      // Drive cannot be confirmed to hold this ROM: greyed with the reason,
      // not a silent absence.
      freeBtn = makeInertButton(
        "Remove from device",
        "button button-sm roms-manage-btn",
        "Not backed up to Drive yet — removing now would delete your only copy",
      );
      siblings.push(freeBtn);
    } else if (localRoms.has(name) && romOnDrive) {
      if (isRomLoaded(name)) {
        // Unlike Delete, the loaded game is not unloaded for the user.
        freeBtn = makeDisabledButton(
          "Remove from device",
          "button button-sm roms-manage-btn",
          "Close this game first to remove it from this device",
        );
      } else {
        freeBtn = makeConfirmButton({
          label: "Remove from device",
          confirmLabel: "Remove from this device?",
          className: "button button-sm roms-manage-btn",
          onArm: () => disarmOthers(freeBtn),
          onConfirm: async () => {
            if (await removeGameFromDevice(name)) {
              showToast("ROM removed from this device — save kept, still on Drive");
            }
            refreshRomsManageList();
            refreshHomeRecent();
            updateStorageInfo();
          },
        });
        freeBtn.title =
          "Free this device's copy of the ROM. Your save data stays here, the " +
          "game stays in your Drive library, and one tap re-downloads it.";
      }
      siblings.push(freeBtn);
    }

    // Sync to device = downloadGame. Not a confirm button, but it disarms
    // any armed sibling.
    let downBtn = null;
    if (driveOnly && driveLinked()) {
      downBtn = document.createElement("button");
      downBtn.type = "button";
      downBtn.className = "button button-sm roms-manage-btn";
      downBtn.title = "Download this game's ROM and saves from Drive to this device";
      if (syncDownloading.has(name)) {
        downBtn.textContent = "Syncing…";
        downBtn.disabled = true;
      } else {
        downBtn.textContent = "Sync to device";
        downBtn.addEventListener("click", async () => {
          disarmOthers(null);
          downBtn.textContent = "Syncing…";
          downBtn.disabled = true;
          if (await downloadGame(name)) showToast("Synced to this device");
          refreshRomsManageList();
          refreshHomeRecent();
          updateStorageInfo();
        });
      }
    }

    let allBtn;
    if (linkRunning) {
      allBtn = makeDisabledButton(
        "Delete",
        "button button-sm roms-manage-btn roms-manage-danger",
        "Exit link mode to remove this game",
      );
    } else {
      allBtn = makeConfirmButton({
        label: "Delete",
        confirmLabel: "Delete ROM and save data?",
        className: "button button-sm roms-manage-btn roms-manage-danger",
        onArm: () => disarmOthers(allBtn),
        onConfirm: async () => {
          if (isRomLoaded(name)) {
            // Unload before deleting: nulling currentRomName keeps the
            // autosave from re-flushing over the deleted key. No final flush.
            if (!(await unloadGame({ flushSave: false }))) {
              showToast("Exit the online session first");
              return;
            }
          }
          await deleteGameEverywhere(name);
          showToast(driveLinked() ? "Deleted from all your devices"
                                  : "Removed from this browser");
          refreshRomsManageList();
          refreshHomeRecent();
          updateStorageInfo();
        },
      });
    }
    siblings.push(allBtn);

    if (saveBtn) actions.appendChild(saveBtn);
    actions.appendChild(allBtn);
    if (freeBtn) actions.appendChild(freeBtn);
    if (downBtn) actions.appendChild(downBtn);
    row.appendChild(actions);
    romsManageList.appendChild(row);
  }
};

// --- Google Drive backup ---
// Battery saves, save states and ROMs in the hidden appDataFolder, via the
// GIS token flow (no backend, no client secret). Drive file names mirror
// the IndexedDB keys one-to-one; the folder listing is the index (no
// manifest), matched by name client-side.
//
// The client ID is public by design (the token flow has no secret): the
// "Authorized JavaScript origins" allowlist in the Cloud Console and the
// drive.appdata scope are the protection. New origins go in Google Auth
// Platform > Clients > this client > Authorized JavaScript origins: scheme +
// host (+ port), https unless localhost (raw IPs are rejected), no redirect
// URIs. localStorage "gdrive_client_id" overrides it for dev; empty means
// the Drive section degrades to "not configured".
const GDRIVE_CLIENT_ID = localStorage.getItem("gdrive_client_id") ||
  "44914400148-bkh9oiu6ian098gbg5jecns4js5d849f.apps.googleusercontent.com";

// drive.appdata = the hidden app folder only; "email" names the account.
const GDRIVE_SCOPE = "https://www.googleapis.com/auth/drive.appdata email";

const GDRIVE_FILES = "https://www.googleapis.com/drive/v3/files";
const GDRIVE_UPLOAD = "https://www.googleapis.com/upload/drive/v3/files";

let gdriveToken = null;       // access token
let gdriveTokenExp = 0;       // epoch ms the access token stops being valid
let gdriveEmail = null;       // best-effort display of the signed-in account
let gdriveTokenClient = null; // GIS token client, created after script load

// Persist the access token + expiry so a reload within its ~1h lifetime
// resumes with no popup (there is no refresh token, and a re-grant is a
// gesture-gated popup).
const persistDriveToken = () => {
  syncState.token = gdriveToken;
  syncState.tokenExp = gdriveTokenExp;
  saveSyncState();
};
const clearDriveToken = () => {
  gdriveToken = null;
  gdriveTokenExp = 0;
  syncState.token = null;
  syncState.tokenExp = 0;
  saveSyncState();
};

// The account email, kept so re-grants can carry a login_hint.
const rememberDriveEmail = (email) => {
  gdriveEmail = email || null;
  if (syncState.email === gdriveEmail) return;
  syncState.email = gdriveEmail;
  saveSyncState();
};

// The GIS script loads lazily so normal page loads never touch Google.
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

// One token request in flight at a time: the GIS client's `callback` is
// overwritten per request, so overlapping calls orphan the first popup and
// its promise (reachable: the window-level renewal listener runs in capture
// a beat before the Sign in button's own handler).
let gdriveTokenInFlight = null;

// promptMode "" = silent refresh; undefined = the account-chooser popup.
// login_hint skips account selection: without it a browser signed in to
// more than one Google account shows the chooser on every re-grant.
const gdriveAcquireToken = (promptMode, hint = syncState.email) => {
  if (gdriveTokenInFlight) return gdriveTokenInFlight;
  gdriveTokenInFlight = (async () => {
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
        // 60s margin so a token never expires mid-request.
        gdriveTokenExp = Date.now() + ((Number(resp.expires_in) || 3600) - 60) * 1000;
        persistDriveToken();
        resolve();
      };
      gdriveTokenClient.error_callback = (err) => {
        reject(new Error(
          err?.type === "popup_failed_to_open"
            ? "Popup blocked — allow popups for this site and try again"
            : "Sign-in was canceled",
        ));
      };
      const opts = promptMode === undefined ? {} : { prompt: promptMode };
      if (hint) opts.login_hint = hint;
      gdriveTokenClient.requestAccessToken(opts);
    });
  })();
  return gdriveTokenInFlight.finally(() => { gdriveTokenInFlight = null; });
};

// A token request opens a popup, so it needs transient user activation; a
// refused popup can show a "pop-up blocked" bar. Where the browser will
// tell us (Chrome 72+, Safari 16.4+), don't try.
const hasUserActivation = () =>
  !navigator.userActivation || navigator.userActivation.isActive;

// Works because GDRIVE_SCOPE includes "email".
const gdriveFetchEmail = async () => {
  try {
    let res = await fetch(
      "https://oauth2.googleapis.com/tokeninfo?access_token=" +
        encodeURIComponent(gdriveToken),
    );
    if (res.ok) rememberDriveEmail((await res.json()).email);
  } catch {}
};

// Authenticated fetch; on a 401 one silent re-grant and replay. The re-grant
// needs a user gesture, and most 401s arrive on the background poll, so a
// failure here does not sign out: it drops the token and hands off to the
// gesture-armed renewal.
const driveFetch = async (url, opts = {}) => {
  const send = () => fetch(url, {
    ...opts,
    headers: { ...(opts.headers || {}), Authorization: "Bearer " + gdriveToken },
  });
  let res = await send();
  if (res.status === 401) {
    try {
      if (!hasUserActivation()) throw new Error("no activation for a popup");
      await gdriveAcquireToken("");
    } catch {
      clearDriveToken();
      armDriveRenewOnGesture();
      renderGdriveSection();
      // Not "sign in again": the account stays linked, the next gesture
      // picks up a token.
      throw new Error("Drive is reconnecting — your changes are saved");
    }
    res = await send();
  }
  if (!res.ok) throw new Error("Drive request failed (HTTP " + res.status + ")");
  return res;
};

// A single page of up to 1000 files, no nextPageToken paging.
const driveListAll = async () => {
  let url = GDRIVE_FILES + "?spaces=appDataFolder&pageSize=1000&fields=" +
    encodeURIComponent("files(id,name,size,modifiedTime)");
  let res = await driveFetch(url);
  return (await res.json()).files || [];
};

// Create + upload in one multipart request; bytes go in as a Blob, never
// string-converted.
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

// Drive caps multipart bodies at 5 MB, so big files go as metadata create
// + media PATCH.
const driveUploadFile = async (name, bytes, existingId) => {
  if (existingId) return driveUpdateContent(existingId, bytes);
  if (bytes.length <= 4 * 1024 * 1024) return driveCreateMultipart(name, bytes);
  return driveUpdateContent(await driveCreateEmpty(name), bytes);
};

const driveDownload = async (fileId) => {
  let res = await driveFetch(GDRIVE_FILES + "/" + fileId + "?alt=media");
  return new Uint8Array(await res.arrayBuffer());
};

// Drive file name -> { game, kind }; null for anything unknown. `kind` is
// unique within a game: slot 0 keeps "state"/"statemeta", slots 1..8 append
// ":slotN". Mirrors romsWithSaveData's ":slotN" and "-p2" folding.
const parseDriveFileName = (n) => {
  if (n.startsWith("rom:")) return { game: n.slice(4), kind: "rom" };
  for (let [prefix, cat] of [["statemeta:", "statemeta"], ["state:", "state"]]) {
    if (n.startsWith(prefix)) {
      let g = n.slice(prefix.length);
      let m = g.match(/:slot(\d+)$/);
      let slot = m ? Number(m[1]) : 0;
      if (m) g = g.slice(0, m.index);
      return { game: g, kind: slot === 0 ? cat : cat + ":" + slot };
    }
  }
  if (n.startsWith("save:")) {
    let g = n.slice(5);
    return g.endsWith("-p2")
      ? { game: g.slice(0, -3), kind: "save2" }
      : { game: g, kind: "save" };
  }
  return null;
};

// --- Drive section UI (#gdrive-body in the roms modal) ---

const gdriveBody = document.getElementById("gdrive-body");

const makeGdriveButton = (label, ghost, onClick) => {
  let btn = document.createElement("button");
  btn.type = "button";
  btn.className = "button button-sm" + (ghost ? " button-ghost" : "");
  btn.textContent = label;
  btn.addEventListener("click", onClick);
  return btn;
};

const gdriveSignOut = () => {
  if (gdriveToken && typeof google !== "undefined" && google.accounts?.oauth2) {
    google.accounts.oauth2.revoke(gdriveToken, () => {});
  }
  rememberDriveEmail(null); // no hint left behind: the next sign-in may be another account
  syncState.connected = false;
  clearDriveToken(); // also drops the persisted token + saves
  // Queued work stays on disk; it flushes on the next sign-in.
  if (syncTimer) { clearTimeout(syncTimer); syncTimer = null; }
  if (syncCapTimer) { clearTimeout(syncCapTimer); syncCapTimer = null; }
  setSyncStatus("idle");
  renderGdriveSection();
  refreshSyncUI();
  refreshHomeRecent();
  showToast("Signed out of Google Drive");
};

const renderGdriveSection = () => {
  if (!gdriveBody) return;
  // Re-render the manage rows on a real sign-in flip only, so routine
  // repaints cannot disarm an armed confirm button.
  if (romsModal.classList.contains("open") && romsRowsSignedIn !== driveLinked()) {
    refreshRomsManageList();
  }
  gdriveBody.innerHTML = "";

  if (!GDRIVE_CLIENT_ID) {
    let p = document.createElement("p");
    p.className = "modal-toggle-sub";
    p.textContent =
      "Drive sync isn't configured in this build (no Google client ID).";
    gdriveBody.appendChild(p);
    return;
  }

  if (!driveLinked()) {
    let btn = makeGdriveButton("Sign in with Google", false, async () => {
      btn.disabled = true;
      try { await gdriveConnect(); }
      catch (e) { showToast(e.message); btn.disabled = false; }
    });
    gdriveBody.appendChild(btn);
    return;
  }

  let n = pendingCount();
  let status = document.createElement("p");
  status.className = "gdrive-status";
  // Linked but between tokens is not signed out; the next Sync buys a token.
  status.textContent =
    (gdriveEmail || "Connected to Google Drive") +
    " · " + (!gdriveToken ? "reconnects when you next sync"
               : n ? n + " change" + (n === 1 ? "" : "s") + " pending"
               : "all changes synced");
  gdriveBody.appendChild(status);

  let actions = document.createElement("div");
  actions.className = "gdrive-actions";
  actions.appendChild(
    makeGdriveButton("Sync now", false, async () => {
      if (!(await ensureDriveSignedIn())) return;
      runFullSync({ label: "Syncing" });
    }));
  actions.appendChild(makeGdriveButton("Sign out", true, gdriveSignOut));
  gdriveBody.appendChild(actions);
};

// ============================================================================
// Google Drive sync. Signing in is turning sync on. The library lives in
// one Drive file, "library":
//     { recents: [{ name, ts }], tomb: [{ name, ts }], ren: [{ from, to, ts }] }
// `recents` is the merged cross-device play history (the home grid). `tomb`
// are tombstones, so a union-merge cannot resurrect a deleted game; a
// re-upload supersedes one. `ren` are rename markers: every other device
// migrates its records for `from` to `to` on its next sync; a newer recents
// entry under `from` supersedes the marker. ROMs are never bulk-downloaded
// (Drive-only tiles download on demand). Uploads go through a persisted
// queue, flushed 2s after the last change and at most 10s after the first.
// ============================================================================

const LIBRARY_FILE = "library";
const SYNC_DEBOUNCE_MS = 2000;   // quiet period before a flush
const SYNC_MAX_WAIT_MS = 10000;  // ...but never sit on changes longer than this
const SYNC_POLL_MS = 3 * 60 * 1000;

// Persisted under "gdrive_sync". sigs = last agreed content signature per
// Drive file; rmt = its last seen modifiedTime; queueRen = pending remote
// renames [{ from, to }]; ren = this device's rename markers.
let syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                  sigs: {}, rmt: {}, email: null };
let syncBusy = false;
let syncTimer = null;
let syncCapTimer = null;
let syncPollTimer = null;
let syncDoneTimer = null;
// Games being pulled on demand (the per-tile spinner).
let syncDownloading = new Set();

const loadSyncState = async () => {
  let s = await dbGet("gdrive_sync");
  if (s && typeof s === "object") {
    syncState = {
      queueUp: Array.isArray(s.queueUp) ? s.queueUp : [],
      queueDel: Array.isArray(s.queueDel) ? s.queueDel : [],
      queueRen: Array.isArray(s.queueRen) ? s.queueRen : [],
      tomb: Array.isArray(s.tomb) ? s.tomb : [],
      ren: Array.isArray(s.ren) ? s.ren : [],
      sigs: s.sigs && typeof s.sigs === "object" ? s.sigs : {},
      rmt: s.rmt && typeof s.rmt === "object" ? s.rmt : {},
      connected: !!s.connected,
      token: typeof s.token === "string" ? s.token : null,
      tokenExp: typeof s.tokenExp === "number" ? s.tokenExp : 0,
      email: typeof s.email === "string" ? s.email : null,
    };
    gdriveEmail = syncState.email;
  }
};
const saveSyncState = () => dbPut("gdrive_sync", syncState);

// driveLinked(): has the user connected Drive at all (survives token expiry);
// what the UI and the queue key off. syncActive(): a live token right now;
// gates network work. A token gap is a quiet, recoverable state.
const driveLinked = () => !!GDRIVE_CLIENT_ID && !!syncState.connected;
const syncActive = () => !!gdriveToken;

const sigOfBytes = (bytes) => saveSignature(bytes); // FNV-1a + length

// --- Naming helpers ------------------------------------------------------
const kindLabel = (kind) => {
  if (kind === "rom") return "ROM";
  if (kind === "save") return "save file";
  if (kind === "save2") return "P2 link save";
  if (kind === "state" || kind === "statemeta") return "save state (Quick)";
  let m = String(kind).match(/:(\d+)$/);
  if (m) return "save state (slot " + (Number(m[1]) + 1) + ")";
  return String(kind);
};
const prettyName = (name) => {
  let p = parseDriveFileName(name);
  return p ? p.game + " — " + kindLabel(p.kind) : name;
};

// --- Local <-> Drive byte plumbing --------------------------------------
// Drive file names are the IndexedDB keys, so parseDriveFileName classifies
// local keys too.
const localSyncFiles = async () => {
  let out = new Map();
  for (let k of await dbKeys()) {
    if (typeof k !== "string") continue;
    let parsed = parseDriveFileName(k);
    if (parsed) out.set(k, parsed);
  }
  return out;
};
const localFilesForGame = async (game) => {
  let names = [];
  for (let [k, p] of await localSyncFiles()) if (p.game === game) names.push(k);
  return names;
};
const hasLocalRom = async (game) => !!(await dbGet(romKey(game)))?.data?.length;
const hasLocalData = async (game) => (await localFilesForGame(game)).length > 0;
// Over every per-game record, including the ones Drive never mirrors.
const hasAnyLocalRecord = async (game) => {
  for (let k of allPerGameKeys(game)) if ((await dbGet(k)) != null) return true;
  return false;
};

const readSyncBytes = async (key) => {
  let v = await dbGet(key);
  if (key.startsWith("rom:")) {
    let d = v?.data;
    return d && d.length ? new Uint8Array(d) : null;
  }
  if (key.startsWith("statemeta:")) {
    if (v && typeof v === "object" && !(v instanceof Uint8Array) &&
        !(v instanceof ArrayBuffer)) {
      let b = new TextEncoder().encode(JSON.stringify(v));
      return b.length ? b : null;
    }
    return null;
  }
  if (v instanceof ArrayBuffer) v = new Uint8Array(v);
  return v instanceof Uint8Array && v.length ? v : null;
};
const writeSyncBytes = async (name, bytes) => {
  if (name.startsWith("rom:")) {
    await dbPut(name, { name: name.slice(4), data: new Uint8Array(bytes) });
    return;
  }
  if (name.startsWith("statemeta:")) {
    try { await dbPut(name, JSON.parse(new TextDecoder().decode(bytes))); }
    catch {}
    return;
  }
  await dbPut(name, bytes);
};

const driveDelete = (fileId) =>
  driveFetch(GDRIVE_FILES + "/" + fileId, { method: "DELETE" });

// Metadata-only PATCH. Asks for modifiedTime back so rmt tracks the bump
// the rename causes (else the next pull re-downloads the file once).
const driveRenameFile = (fileId, newName) =>
  driveFetch(GDRIVE_FILES + "/" + fileId +
             "?fields=" + encodeURIComponent("id,name,modifiedTime"), {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: newName }),
  });

const driveListMap = async () =>
  new Map((await driveListAll()).map((f) => [f.name, f]));

// --- The shared library file (merged recents + tombstones + renames) ------
const readDriveLibrary = async (remote) => {
  let f = remote.get(LIBRARY_FILE);
  if (!f) return { recents: [], tomb: [], ren: [] };
  try {
    let bytes = await driveDownload(f.id);
    let o = JSON.parse(new TextDecoder().decode(bytes));
    return {
      recents: Array.isArray(o.recents) ? o.recents : [],
      tomb: Array.isArray(o.tomb) ? o.tomb : [],
      ren: Array.isArray(o.ren) ? o.ren : [],
    };
  } catch { return { recents: [], tomb: [], ren: [] }; }
};
const writeDriveLibrary = async (lib, remote) => {
  let bytes = new TextEncoder().encode(JSON.stringify(lib));
  await driveUploadFile(LIBRARY_FILE, bytes, remote.get(LIBRARY_FILE)?.id);
};

// Union by name keeping the newest ts, apply rename markers, then drop
// anything tombstoned more recently than the entry itself.
const mergeLibrary = (a, b) => {
  let byName = new Map();
  for (let e of [...(a.recents || []), ...(b.recents || [])]) {
    if (!e?.name) continue;
    let prev = byName.get(e.name);
    if (!prev || (e.ts || 0) > (prev.ts || 0)) byName.set(e.name, { name: e.name, ts: e.ts || 0 });
  }
  // Newest marker per old name wins.
  let ren = new Map();
  for (let r of [...(a.ren || []), ...(b.ren || [])]) {
    if (!r?.from || !r?.to || r.from === r.to) continue;
    let prev = ren.get(r.from);
    if (!prev || (r.ts || 0) > (prev.ts || 0)) {
      ren.set(r.from, { from: r.from, to: r.to, ts: r.ts || 0 });
    }
  }
  // Oldest-first so a chain (A->B, B->C) lands on C. An entry moves only
  // when the marker is newer than it, and keeps its own recency.
  for (let r of [...ren.values()].sort((x, y) => (x.ts || 0) - (y.ts || 0))) {
    let e = byName.get(r.from);
    if (e && (e.ts || 0) < r.ts) {
      byName.delete(r.from);
      let t = byName.get(r.to);
      if (!t || (t.ts || 0) < (e.ts || 0)) byName.set(r.to, { name: r.to, ts: e.ts || 0 });
    }
    // An entry newer than the marker under the old name is a fresh import
    // re-using the name: the marker is spent.
    if (byName.has(r.from)) ren.delete(r.from);
  }
  let tomb = new Map();
  for (let t of [...(a.tomb || []), ...(b.tomb || [])]) {
    if (!t?.name) continue;
    let prev = tomb.get(t.name);
    if (!prev || (t.ts || 0) > (prev.ts || 0)) tomb.set(t.name, { name: t.name, ts: t.ts || 0 });
  }
  for (let [name, t] of tomb) {
    let e = byName.get(name);
    if (e && (e.ts || 0) > (t.ts || 0)) tomb.delete(name); // re-upload supersedes
    else byName.delete(name);
  }
  return {
    recents: [...byName.values()].sort((x, y) => (y.ts || 0) - (x.ts || 0)),
    tomb: [...tomb.values()],
    ren: [...ren.values()],
  };
};

const localLibrary = async () => ({
  recents: (await getRecentMeta()).filter((r) => r?.name),
  tomb: syncState.tomb.slice(),
  ren: syncState.ren.slice(),
});

// --- Sync status indicator ---------
const SYNC_ICONS = {
  syncing: '<svg class="sync-spin" viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v3.5h-3.5"/></svg>',
  done: '<svg viewBox="0 0 24 24"><path d="M20 6L9 17l-5-5"/></svg>',
  // A complete cloud plus a slash (the usual "cloud-off" glyph reads as a
  // broken shape at 15px).
  offline: '<svg viewBox="0 0 24 24"><path d="M17.5 18.5H7.2A4.2 4.2 0 0 1 6.5 10.1a5.8 5.8 0 0 1 11.1 1 3.8 3.8 0 0 1-.1 7.4z"/><path d="M4.5 4.5l15 15"/></svg>',
};
// "no connection" and "no token" are the same fact to the user.
SYNC_ICONS.paused = SYNC_ICONS.offline;
const SYNC_WORDS = { syncing: "Syncing", done: "Synced", offline: "Offline",
                     paused: "Paused" };
const SYNC_DESCS = {
  syncing: "Syncing your games with Google Drive…",
  done: "All changes are synced to Google Drive",
  offline: "Offline — your changes will sync when you reconnect",
  // Out of token and out of silent retries: said quietly, not a sign-in prompt.
  paused: "Tap Sync to reconnect to Google Drive — your changes are saved",
};
let syncStatus = "idle"; // idle | syncing | done | offline | paused
const syncIndicator = document.getElementById("sync-indicator");

const renderSyncIndicator = () => {
  if (!syncIndicator) return;
  let s = syncStatus;
  let show = s !== "idle" && driveLinked();
  document.body.classList.toggle("sync-shown", show);
  syncIndicator.hidden = !show;
  if (!show) { syncIndicator.innerHTML = ""; return; }
  syncIndicator.className = "sync-" + s;
  syncIndicator.title = SYNC_DESCS[s] || "";
  syncIndicator.setAttribute("aria-label", SYNC_DESCS[s] || "");
  // Icon outermost so it holds still as the word changes length.
  syncIndicator.innerHTML =
    '<span class="sync-label">' + SYNC_WORDS[s] + "</span>" + SYNC_ICONS[s];
};
const setSyncStatus = (s) => {
  if (syncDoneTimer) { clearTimeout(syncDoneTimer); syncDoneTimer = null; }
  syncStatus = s;
  renderSyncIndicator();
  refreshHomeSyncButton();
  if (s === "done") {
    syncDoneTimer = setTimeout(() => {
      syncDoneTimer = null;
      if (syncStatus === "done") {
        syncStatus = "idle";
        renderSyncIndicator();
        refreshHomeSyncButton();
      }
    }, 2600);
  }
};
if (syncIndicator) {
  syncIndicator.addEventListener("click", () => {
    if (syncStatus !== "idle") showToast(SYNC_DESCS[syncStatus]);
  });
}
const pendingCount = () =>
  syncState.queueUp.length + syncState.queueDel.length + syncState.queueRen.length;
const refreshSyncStatus = () => {
  if (!driveLinked()) { setSyncStatus("idle"); return; }
  if (!syncActive() && driveRenewFails >= DRIVE_RENEW_MAX_FAILS && pendingCount()) {
    setSyncStatus("paused");
    return;
  }
  if (syncBusy || pendingCount()) setSyncStatus("syncing");
  else if (syncStatus === "syncing") setSyncStatus("done");
  else renderSyncIndicator();
};

// --- Dirty queue ---------------------------------------------------------
// Keyed off driveLinked(), not a live token: a save made between grants must
// still reach Drive later.
const scheduleFlush = () => {
  if (!driveLinked()) return;
  if (syncTimer) clearTimeout(syncTimer);
  syncTimer = setTimeout(flushSync, SYNC_DEBOUNCE_MS);
  // The first change in a burst arms the ceiling.
  if (!syncCapTimer) syncCapTimer = setTimeout(flushSync, SYNC_MAX_WAIT_MS);
  refreshSyncStatus();
};
const markUpload = (name) => {
  if (!driveLinked()) return;
  if (!parseDriveFileName(name)) return;
  if (!syncState.queueUp.includes(name)) syncState.queueUp.push(name);
  saveSyncState();
  scheduleFlush();
};
const markDelete = (name) => {
  if (!driveLinked()) return;
  if (!parseDriveFileName(name)) return;
  if (!syncState.queueDel.includes(name)) syncState.queueDel.push(name);
  syncState.queueUp = syncState.queueUp.filter((n) => n !== name);
  saveSyncState();
  scheduleFlush();
};
const markGameUpload = (game) => {
  if (!driveLinked()) return;
  localFilesForGame(game).then((names) => {
    for (let n of names) if (!syncState.queueUp.includes(n)) syncState.queueUp.push(n);
    saveSyncState();
    scheduleFlush();
  });
};
// Mirror a local save-data wipe to Drive ("saves" group only; the resume
// snapshot was never uploaded).
const queueSaveDataDeletes = (name) => {
  for (let k of perGameKeys(name).saves) markDelete(k);
};

// Drive operations run one at a time; a busy engine defers work, never
// drops it (returning from the sign-in sheet fires visibilitychange, whose
// flush+pull collides with gdriveConnect's own sync).
let syncChain = Promise.resolve();
const runExclusive = (fn) => {
  const run = syncChain.then(() => fn());
  syncChain = run.catch(() => {}); // a failed op must not poison the chain
  return run;
};
// Extra pull triggers while one is queued collapse.
let pullQueued = false;

// Push the queue; anything that fails stays queued.
const flushSync = (...a) => {
  // Disarm at call time: a flush waiting behind a long pull would otherwise
  // leave the debounce armed and re-queue.
  if (syncTimer) { clearTimeout(syncTimer); syncTimer = null; }
  if (syncCapTimer) { clearTimeout(syncCapTimer); syncCapTimer = null; }
  return runExclusive(() => flushSyncInner());
};
const flushSyncInner = async () => {
  if (!syncActive()) return;
  if (!pendingCount() && !syncState.tomb.length && !syncState.ren.length) {
    refreshSyncStatus();
    return;
  }
  syncBusy = true;
  setSyncStatus("syncing");
  try {
    let remote = await driveListMap();
    // Renames first: every later step speaks in new names.
    for (let r of syncState.queueRen.slice()) {
      let f = remote.get(r.from);
      if (f && !remote.has(r.to)) {
        let meta = await (await driveRenameFile(f.id, r.to)).json().catch(() => null);
        remote.delete(r.from);
        remote.set(r.to, { ...f, name: r.to,
                           modifiedTime: meta?.modifiedTime || f.modifiedTime });
        if (meta?.modifiedTime && syncState.rmt[r.to]) {
          syncState.rmt[r.to] = meta.modifiedTime;
        }
      } else if (f) {
        // Another device raced us with the same rename: the old file is a duplicate.
        await driveDelete(f.id);
        remote.delete(r.from);
      } else if (!remote.has(r.to) && !syncState.queueUp.includes(r.to) &&
                 (await readSyncBytes(r.to))) {
        // Drive holds neither name but this device holds the bytes: upload.
        syncState.queueUp.push(r.to);
      }
      syncState.queueRen = syncState.queueRen.filter((x) => x !== r);
    }
    for (let name of syncState.queueDel.slice()) {
      let r = remote.get(name);
      if (r) await driveDelete(r.id);
      delete syncState.sigs[name];
      delete syncState.rmt[name];
      syncState.queueDel = syncState.queueDel.filter((n) => n !== name);
    }
    for (let name of syncState.queueUp.slice()) {
      let bytes = await readSyncBytes(name);
      if (bytes) {
        let r = remote.get(name);
        let sig = sigOfBytes(bytes);
        // The listing is the truth; sigs only remember what this device once
        // uploaded. A file missing remotely uploads regardless of its sig.
        // Present: ROMs are immutable, anything else re-uploads on change.
        if (!r || (!name.startsWith("rom:") && sig !== syncState.sigs[name])) {
          await driveUploadFile(name, bytes, r?.id);
          syncState.sigs[name] = sig;
        }
      }
      syncState.queueUp = syncState.queueUp.filter((n) => n !== name);
    }
    let lib = mergeLibrary(await readDriveLibrary(remote), await localLibrary());
    await writeDriveLibrary(lib, await driveListMap());
    syncState.tomb = lib.tomb;
    syncState.ren = lib.ren;
    await saveSyncState();
    syncBusy = false;
    setSyncStatus("done");
  } catch (e) {
    syncBusy = false;
    await saveSyncState();
    setSyncStatus("offline");
    console.warn("Drive sync flush failed:", e);
  }
};

// Apply a rename from another device: move every local record and let
// sigs/rmt follow. Nothing uploads or deletes on Drive. Collisions are per
// key (unlike renameGame): every key that can move does; a colliding key
// keeps both copies unless they hold identical bytes, in which case the
// old-name one is dropped. Returns { moved, leftover }, or null when the
// transaction failed.
const applyRemoteRename = async (from, to) => {
  let fromKeys = allPerGameKeys(from);
  let toKeys = allPerGameKeys(to);
  // The game may be open: flush the pending save under the old name,
  // detach the session so no write path recreates an old key, reattach
  // after. A link/online session cannot be migrated under; the caller defers.
  if (isRomLoaded(from) && (linkMode || rollbackMode || netActive())) return null;
  let loaded = isRomLoaded(from) && !!currentRomName;
  if (loaded) {
    await persistSave(currentRomName, from);
    currentOriginalName = null;
  }
  let puts = [];
  let prints = await dbGet(PRINTER_PHOTOS_KEY);
  if (Array.isArray(prints) && prints.some((p) => p?.game === from)) {
    puts.push([PRINTER_PHOTOS_KEY,
               prints.map((p) => (p?.game === from ? { ...p, game: to } : p))]);
  }
  let sigs = { ...syncState.sigs };
  let rmt = { ...syncState.rmt };
  fromKeys.forEach((f, i) => {
    let t = toKeys[i];
    if (f in sigs) { sigs[t] = sigs[f]; delete sigs[f]; }
    if (f in rmt) { rmt[t] = rmt[f]; delete rmt[f]; }
  });
  // Queued work keeps its intent under the new names, else the flush
  // looks the old keys up, finds nothing, and drops it.
  let mapKey = (k) => {
    let i = fromKeys.indexOf(k);
    return i >= 0 ? toKeys[i] : k;
  };
  let nextSync = {
    ...syncState,
    sigs,
    rmt,
    queueUp: [...new Set(syncState.queueUp.map(mapKey))],
    queueDel: [...new Set(syncState.queueDel.map(mapKey))],
    queueRen: syncState.queueRen.map((r) => ({ from: mapKey(r.from), to: r.to })),
  };
  puts.push(["gdrive_sync", nextSync]);
  let res;
  try {
    res = await dbMoveKeys(fromKeys.map((k, i) => [k, toKeys[i]]), puts,
                           { skipCollisions: true });
  } catch (e) {
    if (loaded) currentOriginalName = from;
    console.warn("Rename from another device not applied here:", from, "→", to, e);
    return null;
  }
  syncState = nextSync;
  if (Array.isArray(printerPhotos)) {
    for (let p of printerPhotos) if (p?.game === from) p.game = to;
  }
  if (stateUndoName === from) stateUndoName = to;
  if (rwUndoName === from) rwUndoName = to;
  if (loaded) {
    currentOriginalName = to;
    if (homePausedCard && !homePausedCard.hidden) updatePausedCard();
  }
  // Collided pairs: identical bytes drop the old-name copy; anything else
  // is kept and counted. Kinds readSyncBytes cannot serialize stay put.
  let leftover = 0;
  for (let [f, t] of res.skipped) {
    let a = await readSyncBytes(f);
    let b = await readSyncBytes(t);
    if (a && b && sigOfBytes(a) === sigOfBytes(b)) await dbDelete(f);
    else leftover++;
  }
  return { moved: res.moved.length, leftover };
};

// --- Pull (down-sync): merged library, tombstones, saves for local games ---
const pullSync = (opts = {}) => {
  if (pullQueued) return syncChain; // already one waiting; don't pile up
  pullQueued = true;
  return runExclusive(() => { pullQueued = false; return pullSyncInner(opts); });
};
const pullSyncInner = async ({ silent = true } = {}) => {
  if (!syncActive()) return;
  syncBusy = true;
  if (!silent) setSyncStatus("syncing");
  let gridDirty = false;
  let queuedMissing = false;
  try {
    let remote = await driveListMap();
    let lib = mergeLibrary(await readDriveLibrary(remote), await localLibrary());

    // Remote renames before the tombstone pass, so anything still under an
    // old name is genuinely deleted data. Oldest-first so chains replay in order.
    let renPending = new Set();
    for (let r of [...(lib.ren || [])].sort((x, y) => (x.ts || 0) - (y.ts || 0))) {
      if (!(await hasAnyLocalRecord(r.from))) continue;
      let applied = await applyRemoteRename(r.from, r.to);
      if (!applied) {
        renPending.add(r.from);
        continue;
      }
      // Old-name files still on Drive raced the rename: queue their in-place
      // renames so the remote side converges.
      let fk = allPerGameKeys(r.from);
      let tk = allPerGameKeys(r.to);
      for (let i = 0; i < fk.length; i++) {
        if (remote.has(fk[i]) && !!parseDriveFileName(fk[i]) &&
            !syncState.queueRen.some((q) => q.from === fk[i])) {
          syncState.queueRen.push({ from: fk[i], to: tk[i] });
          queuedMissing = true;
        }
      }
      gridDirty = true;
      if (applied.moved) {
        showToast("“" + displayName(r.from) + "” is now “" + displayName(r.to) +
                  "” — renamed on another device");
      }
    }

    let pending = [];
    for (let t of lib.tomb) if (await hasLocalData(t.name)) pending.push(t.name);
    if (pending.length) {
      let keep = await confirmTombstones(pending);
      if (keep === "restore") {
        // Un-delete: drop the tombstones and re-upload.
        lib.tomb = lib.tomb.filter((t) => !pending.includes(t.name));
        let now = Date.now();
        for (let g of pending) {
          lib.recents = lib.recents.filter((r) => r.name !== g);
          lib.recents.unshift({ name: g, ts: now });
          markGameUpload(g);
        }
      } else {
        for (let g of pending) {
          if (isRomLoaded(g)) continue; // never yank the game being played
          // The same local wipe Delete performs.
          await deleteGameLocalData(g);
          gridDirty = true;
        }
      }
    }

    // Pull saves/states for games this device holds.
    let local = await localSyncFiles();
    for (let [name, f] of remote) {
      if (name === LIBRARY_FILE) continue;
      let p = parseDriveFileName(name);
      if (!p || p.kind === "rom") continue;
      if (!(await hasLocalRom(p.game))) continue;  // Drive-only: pull on demand
      if (isRomLoaded(p.game)) continue;           // don't fight the autosave
      if (syncState.rmt[name] === f.modifiedTime) continue; // unchanged remotely
      let bytes = await driveDownload(f.id);
      let sig = sigOfBytes(bytes);
      if (sig !== syncState.sigs[name]) {
        await writeSyncBytes(name, bytes);
        syncState.sigs[name] = sig;
      }
      syncState.rmt[name] = f.modifiedTime;
      local.delete(name);
    }

    // Reconcile upward: queue anything held here that the listing lacks
    // (sigs only remember what was once uploaded). Tombstoned games stay deleted.
    for (let [name, p] of local) {
      if (remote.has(name)) continue;
      if (lib.tomb.some((t) => t.name === p.game)) continue;
      // A deferred rename still holds files under the old name; re-uploading
      // them would resurrect the retired names.
      if (renPending.has(p.game)) continue;
      if (!syncState.queueUp.includes(name)) {
        syncState.queueUp.push(name);
        queuedMissing = true;
      }
    }

    syncState.tomb = lib.tomb;
    syncState.ren = lib.ren;
    // A deferred rename keeps its old name on the local grid (else a
    // "Drive only" tile for a local game, whose download forks the library),
    // with ts pinned under the marker so it still folds forward next merge.
    let recents = lib.recents;
    if (renPending.size) {
      let back = new Map();
      for (let m of lib.ren) if (renPending.has(m.from)) back.set(m.to, m);
      recents = recents.map((e) => {
        let m = back.get(e.name);
        return m ? { name: m.from, ts: Math.min(e.ts || 0, (m.ts || 1) - 1) } : e;
      });
    }
    // Do not cap at MAX_RECENT: games past the 20th would vanish with no
    // way to download them. MAX_RECENT only bounds locally held bytes.
    await dbPut("recent", recents);
    await writeDriveLibrary(lib, remote);
    await saveSyncState();
    gridDirty = true;
  } catch (e) {
    console.warn("Drive pull failed:", e);
    syncBusy = false;
    setSyncStatus("offline");
    return;
  }
  syncBusy = false;
  refreshSyncStatus();
  if (queuedMissing) scheduleFlush();
  if (gridDirty) refreshHomeRecent();
};

const runFullSync = async ({ label } = /** @type {{label?: string}} */ ({})) => {
  if (!syncActive()) return;
  let names = [...(await localSyncFiles()).keys()];
  for (let n of names) if (!syncState.queueUp.includes(n)) syncState.queueUp.push(n);
  await saveSyncState();
  await flushSync();
  await pullSync({ silent: false });
};

// --- On-demand download of one Drive-only game ---------------------------
const downloadGame = async (game) => {
  // Re-auths for itself (a token can age out between opening the modal and
  // the tap); a never-linked account is refused.
  if (!driveLinked()) { showToast("Sign in to Google Drive first"); return false; }
  if (!(await ensureDriveSignedIn())) return false;
  if (syncDownloading.has(game)) return false;
  syncDownloading.add(game);
  refreshHomeRecent();
  let ok = false;
  try {
    let remote = await driveListMap();
    let files = [...remote.values()].filter(
      (f) => parseDriveFileName(f.name)?.game === game);
    if (!files.length) { showToast("That game isn't on Drive anymore"); }
    else {
      for (let f of files) {
        let bytes = await driveDownload(f.id);
        await writeSyncBytes(f.name, bytes);
        syncState.sigs[f.name] = sigOfBytes(bytes);
        syncState.rmt[f.name] = f.modifiedTime;
      }
      await bumpRecentIndex(game);
      await saveSyncState();
      requestPersistentStorage();
      ok = true;
    }
  } catch (e) {
    showToast("Couldn't download: " + e.message);
  } finally {
    syncDownloading.delete(game);
    refreshHomeRecent();
  }
  return ok;
};

// --- "Remove from this device" (the inverse of downloadGame) --------------
// Frees the ROM bytes, box art and auto-resume snapshot. No tombstone, no
// Drive delete; the game re-renders as a Drive-only tile. Save data is kept
// (it may be irreplaceable) and queued for upload on the way out.
const removeGameFromDevice = async (game) => {
  if (!driveLinked()) { showToast("Sign in to Google Drive first"); return false; }
  if (!(await ensureDriveSignedIn())) return false;
  // Never take the last copy: sigs can be stale (wiped app folder, different
  // account), so re-check the live listing and back up instead if needed.
  let remote;
  try {
    remote = await driveListMap();
  } catch (e) {
    console.warn("Drive listing failed, not removing:", e);
    showToast("Couldn't reach Drive — nothing was removed");
    return false;
  }
  if (!remote.has(romKey(game))) {
    markGameUpload(game);
    showToast("Not backed up yet — kept here and queued for Drive");
    return false;
  }
  // bytes + session; saves and prefs stay (see perGameKeys).
  let keys = perGameKeys(game);
  await deleteKeys([...keys.bytes, ...keys.session]);
  markGameUpload(game); // the ROM is gone, so this queues the saves we kept
  return true;
};

// --- Deletion (Manage ROMs) ----------------------------------------------
const resetGameSaves = async (game) => {
  await deleteSaveData(game);
  if (driveLinked()) queueSaveDataDeletes(game);
};
const deleteGameEverywhere = async (game) => {
  await deleteGameLocalData(game);
  await dbPut("recent", (await getRecentMeta()).filter((r) => r.name !== game));
  if (driveLinked()) {
    // Queue the whole inventory: markDelete drops what Drive doesn't hold.
    for (let n of allPerGameKeys(game)) markDelete(n);
    syncState.tomb = syncState.tomb.filter((t) => t.name !== game);
    syncState.tomb.push({ name: game, ts: Date.now() });
    await saveSyncState();
    scheduleFlush();
  }
};

// --- Rename (Manage ROMs) -------------------------------------------------
// Every per-game key, Drive file name, recents entry and printed photo is
// addressed by the name, so a rename is an all-or-nothing migration
// (dbMoveKeys, one transaction).

const RENAME_MAX_LEN = 100;

// The extension is not editable: it decides the system (systemOf). Kept
// verbatim, not extOf's lowercased form.
const splitRomName = (name) => {
  let s = String(name);
  let i = s.lastIndexOf(".");
  return i > 0 ? { base: s.slice(0, i), ext: s.slice(i) } : { base: s, ext: "" };
};

// Every name the library knows: the set a rename must not land on.
const libraryNames = async () => {
  let s = new Set();
  for (let r of await getRecentMeta()) if (r?.name) s.add(r.name);
  for (let n of await romsWithSaveData()) s.add(n);
  return s;
};

// Typed name -> full stored name: trimmed, and a typed-out extension is
// not doubled.
const renameFullName = (base, oldName) => {
  let { ext } = splitRomName(oldName);
  let t = String(base).trim();
  if (ext && t.length > ext.length && t.slice(-ext.length).toLowerCase() === ext.toLowerCase()) {
    t = t.slice(0, -ext.length).trim();
  }
  return t + ext;
};

// Why this name cannot be used, or null. `taken` excludes the game's own name.
const renameNameError = (base, oldName, taken) => {
  let t = String(base).trim();
  if (!t) return "Enter a name.";
  if (t.length > RENAME_MAX_LEN)
    return "Keep the name to " + RENAME_MAX_LEN + " characters or fewer.";
  if (/[\u0000-\u001f\u007f]/.test(t)) return "Names can't contain control characters.";
  if (/[/\\]/.test(t)) return "Names can't contain / or \\ — they'd break the exported file name.";
  // ":" separates a key from its slot suffix.
  if (t.includes(":")) return "Names can't contain a colon.";
  let full = renameFullName(base, oldName);
  // "save:<name>-p2" is the 2P partner's save (only reachable with no extension).
  if (full.endsWith("-p2")) return "Names can't end in “-p2” — that ending is reserved for 2-player link saves.";
  if (full === oldName) return "That's already this game's name.";
  if (taken && taken.has(full))
    return "“" + displayName(full) + "” is already in your library. Pick another name.";
  return null;
};

// What a rename would move, counted, for the confirmation.
const renameInventory = async (name) => {
  const has = async (k) => (await dbGet(k)) != null;
  let states = 0;
  for (let s = 0; s < NUM_STATE_SLOTS; s++) {
    if (await has(slotStateKey(name, s))) states++;
  }
  let prints = await dbGet(PRINTER_PHOTOS_KEY);
  return {
    rom: await has(romKey(name)),
    art: await has(artKey(name)),
    save: await has(linkSaveKey(name, 0)),
    save2: await has(linkSaveKey(name, 1)),
    states,
    session: await has(autoStateKey(name)),
    cheats: await has(CHEATS_KEY(name)),
    prints: Array.isArray(prints)
      ? prints.filter((p) => p?.game === name).length : 0,
  };
};

const renameInventoryLines = (inv) => {
  let out = [];
  if (inv.rom) out.push(inv.art ? "The ROM file and its box art" : "The ROM file");
  if (inv.save) out.push("1 save file");
  if (inv.save2) out.push("The 2-player link save");
  if (inv.states) out.push(inv.states + (inv.states === 1 ? " save state" : " save states"));
  if (inv.session) out.push("The resume snapshot");
  if (inv.cheats) out.push("Your cheat list");
  if (inv.prints) out.push(inv.prints + (inv.prints === 1 ? " printed photo" : " printed photos"));
  return out;
};

// Returns { ok: true, moved } or { ok: false, error } (shown verbatim).
const renameGame = async (oldName, newName) => {
  if (!db) return { ok: false, error: "Storage isn't ready yet — try again in a moment." };
  if (oldName === newName) return { ok: false, error: "That's already this game's name." };
  // A link/online session has a second core writing these saves.
  if (isRomLoaded(oldName) && (linkMode || rollbackMode || netActive())) {
    return { ok: false, error: "Close the link or online session before renaming this game." };
  }
  // Collisions are refused, never merged: library name, or any record.
  let existing = new Set((await dbKeys()).filter((k) => typeof k === "string"));
  let taken = await libraryNames();
  if (taken.has(newName) || allPerGameKeys(newName).some((k) => existing.has(k))) {
    return { ok: false,
             error: "“" + displayName(newName) + "” already exists in your library. Nothing was changed." };
  }

  // The game in memory: flush under the old name, then detach so no write
  // path recreates an old key or lands on a new one mid-transaction.
  let loaded = isRomLoaded(oldName) && !!currentRomName;
  if (loaded) {
    await persistSave(currentRomName, oldName);
    currentOriginalName = null;
  }

  // Records that name the game, written in the same transaction.
  let puts = [];

  // The renamed entry gets a fresh timestamp: mergeLibrary drops any entry
  // older than a tombstone of the same name.
  let recents = await getRecentMeta();
  if (recents.some((r) => r?.name === oldName)) {
    let list = recents.filter((r) => r?.name !== oldName);
    list.unshift({ name: newName, ts: Date.now() });
    puts.push(["recent", list]);
  }

  // Printed photos carry the game's name (it names the exported PNG).
  let prints = await dbGet(PRINTER_PHOTOS_KEY);
  if (Array.isArray(prints) && prints.some((p) => p?.game === oldName)) {
    puts.push([PRINTER_PHOTOS_KEY,
               prints.map((p) => (p?.game === oldName ? { ...p, game: newName } : p))]);
  }

  // Every per-game key is offered; dbMoveKeys skips empty sources.
  let fromKeys = allPerGameKeys(oldName);
  let toKeys = allPerGameKeys(newName);
  let pairs = fromKeys.map((k, i) => [k, toKeys[i]]);

  // Drive: rename the files in place (metadata PATCH), whether or not this
  // device holds their bytes. The queue is written inside the move
  // transaction, so a tab closed mid-rename leaves records and queue consistent.
  let nextSync = null;
  if (driveLinked()) {
    // Every syncable key, held locally or not, except one already queued
    // for remote deletion (renaming it would resurrect it).
    let mirrored = pairs.filter(([f]) => !!parseDriveFileName(f) &&
                                         !syncState.queueDel.includes(f));
    let oldKeys = mirrored.map(([f]) => f);
    let newKeys = mirrored.map(([, t]) => t);
    // Signatures and modified-times follow their files.
    let sigs = { ...syncState.sigs };
    let rmt = { ...syncState.rmt };
    for (let [f, t] of mirrored) {
      if (f in sigs) { sigs[t] = sigs[f]; delete sigs[f]; }
      if (f in rmt) { rmt[t] = rmt[f]; delete rmt[f]; }
    }
    nextSync = {
      ...syncState,
      sigs,
      rmt,
      // A pending upload delivers under the new name (its sig moved too).
      queueUp: [...new Set(syncState.queueUp.map((n) => {
        let i = oldKeys.indexOf(n);
        return i >= 0 ? newKeys[i] : n;
      }))],
      // A delete aimed at a new name is stale: this game exists now.
      queueDel: syncState.queueDel.filter((n) => !newKeys.includes(n)),
      queueRen: [...syncState.queueRen,
                 ...mirrored.map(([from, to]) => ({ from, to }))],
      // No tombstone for the old name (the ren marker migrates other
      // devices instead of deleting); stale markers/tombstones on either
      // name are cleared.
      tomb: syncState.tomb.filter((t) => t?.name !== oldName && t?.name !== newName),
      ren: [
        ...syncState.ren.filter((r) => r?.from !== oldName && r?.from !== newName),
        { from: oldName, to: newName, ts: Date.now() },
      ],
    };
    puts.push(["gdrive_sync", nextSync]);
  }

  let moved;
  try {
    ({ moved } = await dbMoveKeys(pairs, puts));
  } catch (e) {
    // Rolled back whole: put the session back.
    if (loaded) currentOriginalName = oldName;
    return { ok: false, error: (e?.message || "The rename could not be completed.") +
                              " Nothing was changed." };
  }

  // Committed; in-memory bookkeeping catches up.
  if (nextSync) {
    syncState = nextSync;
    scheduleFlush();
  }
  if (Array.isArray(printerPhotos)) {
    for (let p of printerPhotos) if (p?.game === oldName) p.game = newName;
  }
  if (stateUndoName === oldName) stateUndoName = newName;
  if (rwUndoName === oldName) rwUndoName = newName;
  if (loaded) {
    currentOriginalName = newName;
    if (homePausedCard && !homePausedCard.hidden) updatePausedCard();
  }
  return { ok: true, moved: moved.length };
};

// --- Rename modal: name it, confirm it (enumerating what moves), report ---

// Opening reads storage before the overlay exists; a double tap (touch +
// click) would stack two overlays without this.
let renameModalOpen = false;

const openRenameModal = async (oldName) => {
  if (renameModalOpen) return;
  renameModalOpen = true;
  let { base, ext } = splitRomName(oldName);
  let taken, inv;
  try {
    taken = await libraryNames();
    taken.delete(oldName);
    inv = await renameInventory(oldName);
  } catch {
    renameModalOpen = false;
    showToast("Couldn't read this game's files — nothing was changed");
    return;
  }
  let wasLoaded = isRomLoaded(oldName);

  // The Manage modal stays open behind; hand the Tab trap over rather than
  // running two.
  let reopen = romsModal.classList.contains("open");
  if (reopen) releaseFocus(romsModal);

  let m;
  const close = () => {
    renameModalOpen = false;
    m.dismiss();
    if (reopen && romsModal.classList.contains("open")) trapFocus(romsModal);
  };
  m = buildSyncModal({ title: "Rename game", hint: null, onDismiss: close });

  const pane = () => { m.body.innerHTML = ""; return m.body; };
  const para = (parent, cls, text) => {
    let p = document.createElement("p");
    p.className = cls;
    p.textContent = text;
    parent.appendChild(p);
    return p;
  };
  const actions = (parent) => {
    let d = document.createElement("div");
    d.className = "states-actions";
    parent.appendChild(d);
    return d;
  };
  const action = (parent, label, primary, onClick) => {
    let b = document.createElement("button");
    b.type = "button";
    b.className = "button button-sm" + (primary ? " button-primary" : " button-ghost");
    b.textContent = label;
    b.addEventListener("click", onClick);
    parent.appendChild(b);
    return b;
  };

  // --- Pane 1: the new name ---
  const showNameStep = (start) => {
    let body = pane();
    para(body, "modal-hint",
      "The name is how every one of this game's files is stored, so renaming it " +
      "moves its saves, save states and cheats too. Nothing is deleted." +
      (ext ? " Its “" + ext + "” ending stays as it is." : ""));

    let label = document.createElement("label");
    label.className = "modal-row-label";
    label.textContent = "New name";
    label.htmlFor = "rename-input";
    body.appendChild(label);

    let input = document.createElement("input");
    input.type = "text";
    input.id = "rename-input";
    input.className = "cheat-input";
    input.value = start === undefined ? base : start;
    input.setAttribute("spellcheck", "false");
    input.setAttribute("aria-label", "New name for " + displayName(oldName));
    body.appendChild(input);

    // The resulting name while valid, the reason while not; aria-live.
    let note = para(body, "modal-toggle-sub", "");
    note.setAttribute("aria-live", "polite");

    let row = actions(body);
    action(row, "Cancel", false, close);
    let go = action(row, "Continue", true, () => {
      let err = renameNameError(input.value, oldName, taken);
      if (err) { note.className = "cheat-error"; note.textContent = err; return; }
      showConfirmStep(renameFullName(input.value, oldName));
    });

    const revalidate = () => {
      let err = renameNameError(input.value, oldName, taken);
      go.disabled = !!err;
      note.className = err ? "cheat-error" : "modal-toggle-sub";
      note.textContent = err
        ? err
        : "Stored as “" + renameFullName(input.value, oldName) + "”.";
    };
    input.addEventListener("input", revalidate);
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !go.disabled) { e.preventDefault(); go.click(); }
    });
    revalidate();
    input.focus();
  };

  // --- Pane 2: the confirmation ---
  const showConfirmStep = (newName) => {
    let body = pane();
    para(body, "modal-hint",
      "Everything stored under the old name moves to the new one. " +
      "This does not delete anything.");

    let diff = document.createElement("div");
    diff.className = "rename-diff";
    for (let [k, v] of [["From", oldName], ["To", newName]]) {
      let r = document.createElement("div");
      r.className = "rename-diff-row";
      let key = document.createElement("span");
      key.className = "rename-diff-key";
      key.textContent = k;
      let val = document.createElement("span");
      val.className = "rename-diff-val";
      val.textContent = v;
      val.title = v;
      r.appendChild(key);
      r.appendChild(val);
      diff.appendChild(r);
    }
    body.appendChild(diff);

    let lines = renameInventoryLines(inv);
    let head = document.createElement("div");
    head.className = "modal-subhead";
    head.textContent = lines.length ? "What gets renamed" : "Nothing else is stored here";
    body.appendChild(head);
    if (lines.length) {
      let ul = document.createElement("ul");
      ul.className = "rename-items";
      for (let t of lines) {
        let li = document.createElement("li");
        li.textContent = t;
        ul.appendChild(li);
      }
      body.appendChild(ul);
    } else if (!driveLinked()) {
      para(body, "modal-toggle-sub",
        "This game has no saved data on this device yet — only its place in your library moves.");
    }

    if (driveLinked()) {
      para(body, "modal-toggle-sub",
        "Copies on Google Drive are renamed on the next sync, and your other " +
        "devices follow.");
    }
    if (wasLoaded) {
      para(body, "modal-toggle-sub",
        "This game is open right now. It stays open, under its new name.");
    }

    let row = actions(body);
    action(row, "Back", false, () => showNameStep(splitRomName(newName).base));
    let go = action(row, "Rename", true, async () => {
      go.disabled = true;
      go.textContent = "Renaming…";
      let res = await renameGame(oldName, newName);
      if (!res.ok) { showErrorStep(newName, res.error); return; }
      close();
      showToast("Renamed to “" + displayName(newName) + "”");
      refreshRomsManageList();
      refreshHomeRecent();
      updateStorageInfo();
    });
  };

  // --- Pane 3: it didn't happen (and, the move being one transaction,
  // nothing moved) ---
  const showErrorStep = (newName, message) => {
    let body = pane();
    let p = para(body, "cheat-error", message);
    p.setAttribute("role", "alert");
    para(body, "modal-toggle-sub",
      "“" + displayName(oldName) + "” is unchanged — its ROM, saves and save " +
      "states are all still stored under that name.");
    let row = actions(body);
    action(row, "Close", false, close);
    action(row, "Try again", true, () => showNameStep(splitRomName(newName).base));
  };

  showNameStep();
};

// --- "Removed on another device" modal: resolves "continue" or "restore" ---
const confirmTombstones = (games) =>
  new Promise((resolve) => {
    let m;
    let done = (v) => { m.dismiss(); resolve(v); };
    m = buildSyncModal({
      title: "Games removed on another device",
      hint: "These games were deleted from your synced Drive and will be removed from this device. Restore keeps them and puts them back on Drive.",
      onDismiss: () => done("continue"),
    });
    let list = document.createElement("div");
    list.className = "tomb-list";
    for (let g of games) {
      let row = document.createElement("div");
      row.className = "tomb-row";
      let chip = document.createElement("span");
      let sys = systemOf(g);
      chip.className = "sys-chip badge-" + sys.toLowerCase();
      chip.textContent = sys;
      let nm = document.createElement("span");
      nm.className = "tomb-name";
      let t = document.createElement("span");
      t.className = "tomb-title";
      t.textContent = g;
      t.title = g;
      nm.appendChild(t);
      row.appendChild(chip);
      row.appendChild(nm);
      list.appendChild(row);
    }
    m.body.appendChild(list);
    let actions = document.createElement("div");
    actions.className = "tomb-actions";
    let restore = document.createElement("button");
    restore.type = "button";
    restore.className = "button button-ghost";
    restore.textContent = "Restore";
    restore.addEventListener("click", () => done("restore"));
    let cont = document.createElement("button");
    cont.type = "button";
    cont.className = "button button-primary";
    cont.textContent = "Continue";
    cont.addEventListener("click", () => done("continue"));
    actions.appendChild(restore); // secondary left…
    actions.appendChild(cont);    // …primary bottom-right
    m.body.appendChild(actions);
  });

// --- Modal plumbing ------------------------------------------------------
const buildSyncModal = ({ title, hint, onDismiss }) => {
  let overlay = document.createElement("div");
  overlay.className = "modal-overlay sync-modal";
  let modal = document.createElement("div");
  modal.className = "modal";
  overlay.appendChild(modal);
  let closeBtn = document.createElement("button");
  closeBtn.type = "button";
  closeBtn.className = "modal-close";
  closeBtn.setAttribute("aria-label", "Close");
  closeBtn.innerHTML = "&times;";
  modal.appendChild(closeBtn);
  let h = document.createElement("h2");
  h.textContent = title;
  modal.appendChild(h);
  if (hint) {
    let p = document.createElement("p");
    p.className = "modal-hint";
    p.textContent = hint;
    modal.appendChild(p);
  }
  let body = document.createElement("div");
  modal.appendChild(body);
  document.body.appendChild(overlay);
  overlay.classList.add("open");
  trapFocus(overlay);
  let onKey = (e) => {
    if (e.key === "Escape") { e.stopPropagation(); if (onDismiss) onDismiss(); }
  };
  document.addEventListener("keydown", onKey, true);
  if (onDismiss) {
    closeBtn.addEventListener("click", onDismiss);
    overlay.addEventListener("click", (e) => { if (e.target === overlay) onDismiss(); });
  } else {
    closeBtn.hidden = true;
  }
  return {
    overlay, modal, body,
    dismiss: () => {
      document.removeEventListener("keydown", onKey, true);
      releaseFocus(overlay);
      overlay.remove();
    },
  };
};

// --- Connect / disconnect -------------------------------------------------
const gdriveConnect = async () => {
  await gdriveAcquireToken();
  await gdriveFetchEmail();
  driveRenewFails = 0; // fresh grant: the silent-renew budget starts over
  syncState.connected = true; // remembered so a reload can re-grant silently
  await saveSyncState();
  refreshSyncUI();
  showToast("Connected to Google Drive");
  await runFullSync({ label: "Syncing your games" });
  refreshHomeRecent();
};

// Ensure a Drive session before Drive work; the lazy re-auth path, called
// from a click so the popup has activation. A linked account gets the
// silent prompt:"" re-grant with login_hint; only a new or revoked
// connection falls through to the full account-chooser flow.
const ensureDriveSignedIn = async () => {
  if (syncActive()) return true;
  if (driveLinked()) {
    try {
      await gdriveAcquireToken("");
      driveRenewFails = 0;
      if (!gdriveEmail) await gdriveFetchEmail();
      refreshSyncUI();
      refreshHomeRecent();
      return true;
    } catch {
      // Grant gone or popup blocked: ask properly.
    }
  }
  try { await gdriveConnect(); }
  catch (e) { showToast(e.message); return false; }
  return syncActive();
};

// --- Keeping the session alive -------------------------------------------
// ~1h tokens, no refresh token, and even the silent re-grant is a popup
// needing transient activation. So when the token is missing or near
// expiry, a one-shot listener does the silent re-grant on the next
// pointerdown/keydown/touchstart. Renewal starts this long before expiry.
const DRIVE_RENEW_LEAD_MS = 10 * 60 * 1000;
// Consecutive silent-renew rejections before the signed-out UI; each costs a popup.
const DRIVE_RENEW_MAX_FAILS = 3;

let driveRenewArmed = false;
let driveRenewFails = 0;

const driveTokenStale = () =>
  !gdriveToken || gdriveTokenExp - Date.now() < DRIVE_RENEW_LEAD_MS;

const armDriveRenewOnGesture = () => {
  if (driveRenewArmed) return;
  if (!GDRIVE_CLIENT_ID || !syncState.connected) return;
  if (driveRenewFails >= DRIVE_RENEW_MAX_FAILS) return;
  driveRenewArmed = true;
  const events = ["pointerdown", "keydown", "touchstart"];
  const onGesture = (e) => {
    // The update controls must not spend the gesture: the reload orphans
    // the popup and loses the token. (Duck-typed: text nodes lack closest.)
    const t = e && e.target;
    if (t && typeof t.closest === "function" &&
        t.closest("#update-btn, #update-confirm, #force-update")) return;
    events.forEach((ev) => window.removeEventListener(ev, onGesture, true));
    // Cleared before the attempt so the next expiry can arm again.
    driveRenewArmed = false;
    renewDriveToken();
  };
  events.forEach((e) => window.addEventListener(e, onGesture, true));
};

// Silent re-grant, with a live token (rollover) or none (resume).
const renewDriveToken = async () => {
  if (!GDRIVE_CLIENT_ID || !syncState.connected) return;
  if (appUpdating) return; // reload imminent: a popup now would be orphaned
  if (navigator.onLine === false) { armDriveRenewOnGesture(); return; }
  const wasSignedOut = !gdriveToken;

  // A script-load failure (offline) must not count against the fail budget.
  try { await loadGisScript(); }
  catch { armDriveRenewOnGesture(); return; }

  // Activation lasts about five seconds and may have aged out while the
  // script loaded; a refused popup would spend a strike, so wait.
  if (!hasUserActivation()) { armDriveRenewOnGesture(); return; }

  try {
    await gdriveAcquireToken("");
  } catch {
    // Popup blocked or grant gone: retry on the next gesture until the
    // budget runs out.
    if (++driveRenewFails >= DRIVE_RENEW_MAX_FAILS) {
      clearDriveToken();
      renderGdriveSection();
      refreshSyncUI();
      refreshHomeRecent();
    } else {
      armDriveRenewOnGesture();
    }
    return;
  }

  driveRenewFails = 0;
  if (!wasSignedOut) return; // pure rollover: nothing user-visible changed
  await gdriveFetchEmail();
  renderGdriveSection();
  refreshSyncUI();
  refreshHomeRecent();
  await pullSync();
};

// Boot resume: reuse a persisted token within its lifetime, confirmed via
// tokeninfo (a plain fetch); otherwise arm the first-gesture re-grant.
const resumeDriveOnBoot = async () => {
  if (!GDRIVE_CLIENT_ID || !syncState.connected || gdriveToken) return;
  // Warm the GIS script for a linked account: transient activation lasts
  // ~5s, and a cold script fetch on a phone can eat that whole budget.
  loadGisScript().catch(() => {});
  if (syncState.token && syncState.tokenExp > Date.now() + 5000) {
    gdriveToken = syncState.token;
    gdriveTokenExp = syncState.tokenExp;
    let live = false;
    try {
      const r = await fetch(
        "https://oauth2.googleapis.com/tokeninfo?access_token=" +
          encodeURIComponent(gdriveToken),
      );
      live = r.ok;
      if (live) rememberDriveEmail((await r.json()).email);
    } catch {
      // Offline at boot: keep the token; the sync path's 401 handling covers it.
      live = true;
    }
    if (live) {
      refreshSyncUI();
      refreshHomeRecent();
      pullSync();
      // A restored token can be minutes from expiry.
      if (driveTokenStale()) armDriveRenewOnGesture();
      return;
    }
    clearDriveToken();
  }
  armDriveRenewOnGesture();
};

// --- Sync triggers --------------------------------------------------------
// No push channel: pull on the moments that matter and poll gently. The poll
// also retries a stuck flush (Drive unreachable while navigator stays
// online fires no `online` event).
const syncPollTick = () => {
  // Before the syncActive() gate: this heartbeat also arms the renewal.
  if (GDRIVE_CLIENT_ID && syncState.connected && driveTokenStale()) {
    armDriveRenewOnGesture();
  }
  if (!syncActive()) return;
  if (pendingCount()) flushSync().then(() => pullSync());
  else pullSync();
};
const startSyncTriggers = () => {
  if (syncPollTimer) clearInterval(syncPollTimer);
  syncPollTimer = setInterval(syncPollTick, SYNC_POLL_MS);
};
window.addEventListener("online", () => {
  if (!syncActive()) return;
  refreshSyncStatus();
  flushSync().then(() => pullSync());
});
window.addEventListener("offline", () => {
  if (driveLinked() && pendingCount()) setSyncStatus("offline");
});
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  // Returning to a phone asleep for an hour: arm the renewal now.
  if (driveLinked() && driveTokenStale()) armDriveRenewOnGesture();
  if (syncActive()) flushSync().then(() => pullSync());
});

// --- Sync UI surfaces -----------------------------------------------------
const homeSyncBtn = /** @type {HTMLButtonElement} */ (document.getElementById("home-sync"));
// Same slot as Sync, shown while signed out.
const homeSignInBtn = /** @type {HTMLButtonElement} */ (document.getElementById("home-signin"));

// The grid's Sync link doubles as its progress readout.
const refreshHomeSyncButton = () => {
  // Exactly one is visible; a build with no client ID shows neither.
  if (homeSignInBtn) {
    homeSignInBtn.hidden = !GDRIVE_CLIENT_ID || driveLinked();
    if (!homeSignInBtn.hidden) homeSignInBtn.disabled = false;
  }
  if (!homeSyncBtn) return;
  homeSyncBtn.hidden = !driveLinked();
  const busy = syncStatus === "syncing";
  homeSyncBtn.disabled = busy;
  homeSyncBtn.innerHTML = busy
    ? '<svg class="sync-spin" viewBox="0 0 24 24" aria-hidden="true">' +
      '<path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v3.5h-3.5"/></svg>Syncing…'
    : "Sync";
};

const refreshSyncUI = () => {
  refreshHomeSyncButton();
  renderSyncIndicator();
  if (romsModal.classList.contains("open")) renderGdriveSection();
};
if (homeSyncBtn) {
  homeSyncBtn.addEventListener("click", async () => {
    // Linked but tokenless: this gesture buys the new token.
    if (!(await ensureDriveSignedIn())) return;
    runFullSync({ label: "Syncing" });
  });
}
if (homeSignInBtn) {
  // gdriveConnect() must be reached with the click's activation live, so
  // nothing may be awaited before the call.
  homeSignInBtn.addEventListener("click", async () => {
    homeSignInBtn.disabled = true;
    try { await gdriveConnect(); }
    catch (e) { showToast(e.message); }
    refreshHomeSyncButton();
  });
}
// The markup starts both buttons hidden; seed the signed-out boot state.
refreshHomeSyncButton();

// --- Core-construction settings ---
// JS mirrors of the wasm-side option vars; effective at the next core construction.

var gbFifo = true;
var gbaBiosMode = 0; // 0 = HLE, 1 = real BIOS, 2 = real BIOS boot + HLE calls
var gbaRunBios = true;
// Presentation-side only: no wasm setter in applySystemSettings.
var gbRumble = true;
// Rewind, on by default; a "system" record with no rewindOn key stays on
// (loadSystemSettings). Off stops allocating the wasm ring.
var rewindOn = true;

// Speed mode: wasm_set_speed_mode (GBA renders every other frame at half
// clock; GB loads the scanline renderer), and rewind / MP2K HLE / FIFO
// interpolation / glow / run-ahead are suspended, not overwritten.
var speedMode = false;

const gbaRunBiosToggle = /** @type {HTMLInputElement} */ (document.getElementById("gba-run-bios-toggle"));
const gbRumbleToggle = /** @type {HTMLInputElement} */ (document.getElementById("gb-rumble-toggle"));
const rewindToggle = /** @type {HTMLInputElement} */ (document.getElementById("rewind-toggle"));

// body.rewind-off hides every rewind affordance; turning it off also shuts
// an open film strip, since its ring is about to go.
const applyRewindUI = () => {
  document.body.classList.toggle("rewind-off", !rewindOn);
  if (!rewindOn) {
    setRewindHeld(false);          // a held rewind must not survive the switch
    closeRewindScrubber();
  }
};

// Super Game Boy: sgbEnable off by default, sgbBorder on. Both are read by
// the core at ROM load, so sgbEnable applies to the next game.
var sgbEnable = false;
var sgbBorder = true;
const sgbToggle = /** @type {HTMLInputElement} */ (document.getElementById("sgb-toggle"));
const sgbBorderToggle = /** @type {HTMLInputElement} */ (document.getElementById("sgb-border-toggle"));
const sgbBorderRow = document.getElementById("sgb-border-row");

const applySystemSettings = () => {
  if (typeof Module === "undefined") return;
  if (Module._wasm_set_gb_renderer) Module._wasm_set_gb_renderer(gbFifo ? 1 : 0);
  if (Module._wasm_set_gba_bios_mode) Module._wasm_set_gba_bios_mode(gbaBiosMode);
  if (Module._wasm_set_gba_run_bios) Module._wasm_set_gba_run_bios(gbaRunBios ? 1 : 0);
  if (Module._wasm_sgb_enable) Module._wasm_sgb_enable(sgbEnable ? 1 : 0);
  // The border switch is live: it only hides a layer the core has.
  if (Module._wasm_sgb_border_show) Module._wasm_sgb_border_show(sgbBorder ? 1 : 0);
  // Live in both directions; speed mode suspends it.
  if (Module._setRewindEnabled) Module._setRewindEnabled((rewindOn && !speedMode) ? 1 : 0);
  if (Module._wasm_set_speed_mode) Module._wasm_set_speed_mode(speedMode ? 1 : 0);
  // Re-push the suspended audio settings' effective values on a flip.
  applyMp2kHle();
  applyFifoInterp();
  applyPitchCorrectFF();
  applyAudioLowpass();
  applyLcdResponse();
};

const syncSystemSettingsUI = () => {
  for (let r of /** @type {NodeListOf<HTMLInputElement>} */ (document.querySelectorAll('input[name="gb-renderer"]'))) {
    r.checked = r.value === (gbFifo ? "fifo" : "scanline");
  }
  for (let r of /** @type {NodeListOf<HTMLInputElement>} */ (document.querySelectorAll('input[name="gba-bios-mode"]'))) {
    r.checked = Number(r.value) === gbaBiosMode;
  }
  gbaRunBiosToggle.checked = gbaRunBios;
  gbRumbleToggle.checked = gbRumble;
  if (sgbToggle) sgbToggle.checked = sgbEnable;
  if (sgbBorderToggle) {
    sgbBorderToggle.checked = sgbBorder;
    sgbBorderToggle.disabled = !sgbEnable;
  }
  if (sgbBorderRow) sgbBorderRow.classList.toggle("row-disabled", !sgbEnable);
  const sm = /** @type {HTMLInputElement} */ (document.getElementById("speed-mode-toggle"));
  if (sm) sm.checked = speedMode;
  // Show suspended controls as suspended; stored preferences are untouched.
  rewindToggle.checked = rewindOn;
  rewindToggle.disabled = speedMode;
  const ra = /** @type {HTMLSelectElement} */ (document.getElementById("runahead-select"));
  if (ra) ra.disabled = speedMode;
  // Volume/mute, scanlines and color correction stay live (free or ~0.2%).
  for (const id of ["fifo-interp-toggle", "mp2k-hle-toggle",
                    "audio-lowpass-toggle", "pitch-correct-ff-toggle",
                    "upscale-filter-select", "ambient-glow-toggle",
                    "lcd-response-toggle"]) {
    const el = /** @type {HTMLInputElement} */ (document.getElementById(id));
    if (el) el.disabled = speedMode;
  }
  applyRewindUI();
};

const saveSystemSettings = () => {
  applySystemSettings();
  applyRewindUI();
  if (db) dbPut("system",
    { gbFifo, gbaBiosMode, gbaRunBios, gbRumble, rewindOn, sgbEnable, sgbBorder,
      speedMode });
};

for (let r of /** @type {NodeListOf<HTMLInputElement>} */ (document.querySelectorAll('input[name="gb-renderer"]'))) {
  r.addEventListener("change", () => {
    if (r.checked) {
      gbFifo = r.value === "fifo";
      saveSystemSettings();
    }
  });
}

for (let r of /** @type {NodeListOf<HTMLInputElement>} */ (document.querySelectorAll('input[name="gba-bios-mode"]'))) {
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

if (sgbToggle) sgbToggle.addEventListener("change", () => {
  sgbEnable = sgbToggle.checked;
  saveSystemSettings();
  syncSystemSettingsUI();
  syncGbPaletteUI();
  if (currentRomName) showToast("Super Game Boy mode applies the next time a game is loaded");
});

if (sgbBorderToggle) sgbBorderToggle.addEventListener("change", () => {
  sgbBorder = sgbBorderToggle.checked;
  saveSystemSettings();
  // The canvas changes shape the moment the layer is shown or hidden.
  updateCanvasScaling();
  presentDirty = true;
});

rewindToggle.addEventListener("change", () => {
  rewindOn = rewindToggle.checked;
  saveSystemSettings();
});

{
  const sm = /** @type {HTMLInputElement} */ (document.getElementById("speed-mode-toggle"));
  if (sm) sm.addEventListener("change", () => {
    speedMode = sm.checked;
    saveSystemSettings();
    syncSystemSettingsUI();
    // Refresh layout (the RGB look changes the backing-store scale) and the frame.
    if (typeof updateCanvasScaling === "function") updateCanvasScaling();
    if (typeof drawGame === "function") drawGame();
    if (speedMode && currentRomName) {
      showToast("Speed mode is on — a running Game Boy game switches renderer at the next load");
    }
  });
}

const loadSystemSettings = async () => {
  let s = await dbGet("system");
  if (s) {
    if (typeof s.gbFifo === "boolean") gbFifo = s.gbFifo;
    if ([0, 1, 2].includes(s.gbaBiosMode)) gbaBiosMode = s.gbaBiosMode;
    if (typeof s.gbaRunBios === "boolean") gbaRunBios = s.gbaRunBios;
    if (typeof s.gbRumble === "boolean") gbRumble = s.gbRumble;
    if (typeof s.sgbEnable === "boolean") sgbEnable = s.sgbEnable;
    if (typeof s.sgbBorder === "boolean") sgbBorder = s.sgbBorder;
    // Only a real boolean: a record predating the setting leaves the default.
    if (typeof s.rewindOn === "boolean") rewindOn = s.rewindOn;
    if (typeof s.speedMode === "boolean") speedMode = s.speedMode;
  }
  syncSystemSettingsUI();
  applySystemSettings();
};

// --- Recent ROMs ---
//   "recent"      metadata index: [{ name, ts }], most-recent-first, capped
//   "rom:<name>"  { name, data: Uint8Array }, fetched only at launch/backup
//   "art:<name>"  Blob, fetched lazily by the grid
// Bytes stay out of the index and tile closures: a few GBA ROMs in the JS
// heap get the wasm JIT demoted on iOS Safari.

const MAX_RECENT = 20;

const romKey = (name) => "rom:" + name;
const artKey = (name) => "art:" + name;

// Drop the ROM record and its box art; save data is never touched here.
const evictLocalRom = async (name) => {
  await dbDelete(romKey(name));
  await dbDelete(artKey(name));
};

const getRecentMeta = async () => {
  return (await dbGet("recent")) || [];
};

const getRomBytes = async (name) => {
  let rec = await dbGet(romKey(name));
  let d = rec?.data ?? null;
  if (d instanceof ArrayBuffer) d = new Uint8Array(d);
  return d instanceof Uint8Array && d.length ? d : null;
};

const getRomArt = async (name) => (await dbGet(artKey(name))) || null;

// Move `name` to the front of the index and evict past the cap (ROM + art
// only, never saves).
const bumpRecentIndex = async (name, { fresh = false } = {}) => {
  let list = (await getRecentMeta()).filter((r) => r.name !== name);
  let ts = Date.now();
  // A relaunch under a not-yet-applied rename marker must not outrank it
  // (the merge would read that as a new claim on the name): pin recency
  // just under the marker. A real re-import (fresh: true) is a new claim.
  if (!fresh) {
    let m = syncState.ren.find((r) => r?.from === name);
    if (m?.ts && ts >= m.ts) ts = m.ts - 1;
  }
  list.unshift({ name, ts });
  // Past MAX_RECENT: signed in, the entry becomes a Drive-only tile; signed
  // out it is dropped.
  for (let i = MAX_RECENT; i < list.length; i++) await evictLocalRom(list[i].name);
  if (!driveLinked()) list = list.slice(0, MAX_RECENT);
  await dbPut("recent", list);
};

// navigator.storage.persist(): Firefox shows a prompt, so request it on a
// ROM import or save flush, at most once per session.
let persistAsked = false;
const requestPersistentStorage = () => {
  if (persistAsked || !navigator.storage?.persist) return;
  persistAsked = true;
  navigator.storage
    .persisted()
    .then((p) => p || navigator.storage.persist())
    .then((p) => log("persistent storage: " + (p ? "granted" : "best-effort")))
    .catch(() => {});
};

const addRecentRom = async (name, bytes, art) => {
  // Bytes first, index second: an interruption leaves at worst an orphan.
  await dbPut(romKey(name), { name, data: new Uint8Array(bytes) });
  if (art) await dbPut(artKey(name), art); // Blob (box art from a zip)
  await bumpRecentIndex(name, { fresh: true });
  refreshHomeRecent();
  requestPersistentStorage();
  markGameUpload(name);
};

// Recency bump without rewriting the rom: record.
const touchRecent = async (name) => {
  await bumpRecentIndex(name);
  refreshHomeRecent();
};

const launchRom = async (name) => {
  // The grid renders before the wasm runtime is up; wait here.
  await ensureRuntimeReady();
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

// Home-screen recent grid: the game library.
const homeRecentWrap = document.getElementById("home-recent-wrap");
const homeRecentHead = document.getElementById("home-recent-head");
const homeRecent = document.getElementById("home-recent");
const storageInfo = document.getElementById("storage-info");

// Empty-library placeholder: on a fresh device the only way to reach Drive
// sign-in (the recents header is hidden when the library is empty).
const buildEmptyLibraryCard = () => {
  let card = document.createElement("div");
  card.className = "home-empty";
  let msg = document.createElement("p");
  msg.className = "home-empty-msg";
  msg.textContent = "No games yet — load one to get started.";
  card.appendChild(msg);
  if (GDRIVE_CLIENT_ID && !driveLinked()) {
    let sub = document.createElement("p");
    sub.className = "home-empty-sub";
    sub.textContent = "Already have games backed up to Google Drive?";
    card.appendChild(sub);
    let btn = document.createElement("button");
    btn.type = "button";
    btn.className = "button button-sm";
    btn.textContent = "Sign in with Google"; // same label as Manage ROMs
    btn.addEventListener("click", async () => {
      btn.disabled = true;
      try { await gdriveConnect(); }
      catch (e) { showToast(e.message); btn.disabled = false; }
    });
    card.appendChild(btn);
  } else if (driveLinked()) {
    let btn = document.createElement("button");
    btn.type = "button";
    btn.className = "button button-sm";
    btn.textContent = "Sync now";
    btn.addEventListener("click", () => runFullSync({ label: "Syncing" }));
    card.appendChild(btn);
  }
  return card;
};

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
  await evictLocalRom(name);
  refreshHomeRecent();
};

// Box-art object URLs, revoked and rebuilt each render.
let homeArtUrls = [];
// Render generation: a lazy art fetch resolving after a newer render must
// not touch the fresh grid.
let homeRenderGen = 0;

// Rebuilt off-DOM and swapped in with one replaceChildren, never emptied
// first: #home is the scroll container, and an empty grid collapses its
// scrollHeight so the browser clamps scrollTop to 0.
const refreshHomeRecent = async () => {
  if (!db) return;
  let roms = await getRecentMeta(); // metadata only — no ROM bytes
  let gen = ++homeRenderGen;
  // Art URLs minted by this render become homeArtUrls only on commit.
  let artUrls = [];
  if (roms.length === 0) {
    // Keep the section (Drive sign-in lives in the empty state), drop the header.
    homeRecentWrap.hidden = false;
    if (homeRecentHead) homeRecentHead.hidden = true;
    storageInfo.textContent = "";
    homeRecent.replaceChildren(buildEmptyLibraryCard());
    homeArtUrls.forEach(URL.revokeObjectURL);
    homeArtUrls = artUrls;
    return;
  }
  if (homeRecentHead) homeRecentHead.hidden = false;
  homeRecentWrap.hidden = false;
  updateStorageInfo();
  // Entries without local bytes render as Drive-only download tiles, signed
  // in or not (a tap prompts sign-in).
  let localRoms = new Set();
  let keys = await dbKeys();
  // A newer render may have started during that await.
  if (gen !== homeRenderGen) return;
  for (let k of keys) {
    if (typeof k === "string" && k.startsWith("rom:")) localRoms.add(k.slice(4));
  }
  let tiles = [];
  for (let { name: romName } of roms) {
    let system = systemOf(romName);
    let driveOnly = !localRoms.has(romName);
    let busy = syncDownloading.has(romName);
    let tile = document.createElement("div");
    tile.className = "home-tile" + (driveOnly ? " home-tile-cloud" : "");

    let launch = document.createElement("button");
    launch.type = "button";
    launch.className = "home-tile-launch";
    launch.title = driveOnly
      ? romName + (driveLinked() ? " — on Drive, tap to download"
                                 : " — on Drive, tap to sign in and download")
      : romName;

    // The system chip is the identity slot; box art takes the same slot
    // (its Blob lives in its own record, so no ROM bytes are deserialized).
    let icon = document.createElement("span");
    icon.className = "sys-chip badge-" + system.toLowerCase();
    icon.textContent = system;
    getRomArt(romName).then((art) => {
      if (!art || gen !== homeRenderGen) return;
      let url = URL.createObjectURL(art);
      artUrls.push(url);
      let img = document.createElement("img");
      img.className = "home-tile-art";
      img.src = url;
      img.alt = "";
      launch.replaceChild(img, icon);
    }).catch(() => {});

    let name = document.createElement("span");
    name.className = "home-tile-name";
    name.textContent = displayName(romName); // full name stays in launch.title

    launch.appendChild(icon);
    launch.appendChild(name);
    // The tile body downloads and launches; the glyph downloads only.
    launch.addEventListener("click", async () => {
      if (!driveOnly) { launchRom(romName); return; }
      if (syncDownloading.has(romName)) return;
      if (!(await ensureDriveSignedIn())) return;
      if (await downloadGame(romName)) launchRom(romName);
    });

    tile.appendChild(launch);

    if (driveOnly) {
      let dl = document.createElement("button");
      dl.type = "button";
      dl.className = "home-tile-dl" + (busy ? " is-busy" : "");
      dl.disabled = busy;
      dl.title = romName + " — download without launching";
      dl.setAttribute("aria-label", "Download " + displayName(romName));
      dl.innerHTML = busy
        ? '<svg class="sync-spin" viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v3.5h-3.5"/></svg>'
        : '<svg viewBox="0 0 24 24"><path d="M12 3v12M8 11l4 4 4-4M5 19h14"/></svg>';
      dl.addEventListener("click", async (e) => {
        e.stopPropagation();
        if (syncDownloading.has(romName)) return;
        if (!(await ensureDriveSignedIn())) return;
        await downloadGame(romName); // download only — no launch
      });
      tile.appendChild(dl);
    } else {
      // Local 2P link: two linked cores of this ROM.
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
      tile.appendChild(link2p);
    }
    tiles.push(tile);
  }
  // The one DOM commit, atomic: no zero-height moment.
  homeRecent.replaceChildren(...tiles);
  homeArtUrls.forEach(URL.revokeObjectURL);
  homeArtUrls = artUrls;
};

// Escape closes every modal (the net modal's dismissal is netplay.js's).
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    menuDropdown.hidden = true; // the dropdown must not outlive Escape either
    // Rebinding a key: the capture handler eats the event first.
    if (!settingsModal.classList.contains("open") || kbSelection < 0) {
      closeSettingsModal();
    }
    closeSavesModal();
    closeRomsModal();
    closeUpdateModal();
    closeStatesModal();
    closeCheatsModal();
    closeReportModal();
    closeRewindScrubber();
    closeClipScrubber();
    closeRomWarnModal();
  }
});

// --- Save state persistence ---

// Change detector so the 5s autosave skips the clone + IDB write when
// nothing changed (that write cost a visible stutter).
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
      if (lastSaveSigKey === originalName && sig === lastSaveSig) return;
      lastSaveSig = sig;
      lastSaveSigKey = originalName;
      await dbPut("save:" + originalName, new Uint8Array(data));
      requestPersistentStorage();
      markUpload("save:" + originalName); // truly-dirty save -> Drive soon

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
// Display name: the filename without its extension.
const displayName = (name) => stripExt(name) || name;

// Overwrite the loaded game's battery save with imported bytes and reboot.
// GameShark-family containers are unwrapped first (saveimport.js).
const applyImportedSave = async (bytes, fileName) => {
  const unwrapped = SaveImport.unwrap(bytes, fileName);
  if (!unwrapped.ok) {
    alert(unwrapped.error);
    return;
  }
  let overwriteAsk = "This will overwrite any existing save file for the current game.";
  if (unwrapped.warning) overwriteAsk += ` Note: ${unwrapped.warning}.`;
  if (!confirm(overwriteAsk + " Continue?")) return;
  if (stripExt(fileName) !== stripExt(currentOriginalName)) {
    if (!confirm("You've selected a save file that doesn't match the name of the current game. Are you sure you want to overwrite the save?")) return;
  }
  bytes = unwrapped.bytes;
  let savName = currentRomName.substring(0, currentRomName.lastIndexOf(".")) + ".sav";
  writeToFS(savName, bytes);
  await dbPut("save:" + currentOriginalName, new Uint8Array(bytes));
  if (unwrapped.format)
    showToast(`Imported ${unwrapped.format} save` +
      (unwrapped.title ? ` — ${unwrapped.title}` : ""));
  loadRom(currentRomName, currentOriginalName);
};

document.getElementById("load-save").addEventListener("click", () => {
  closeSavesModal(); // success reloads the game — don't leave the modal over it
  if (!currentRomName || !currentOriginalName) {
    alert("No ROM is loaded.");
    return;
  }
  // pickFile() must run synchronously in the tap: on iOS Safari a preceding
  // confirm() consumes the activation and input.click() no longer opens.
  pickFile(".sav,.srm,.sps,.xps,.gsv", (bytes, fileName) => applyImportedSave(bytes, fileName));
});

// --- Save states ---
// wasm_state_size/wasm_state_data/wasm_load_state images, keyed "state:" +
// original name; byte-compatible with the desktop .state files. All calls
// happen from event handlers, i.e. at a frame boundary.

// --- Toasts -----------------------------------------------------------------
// #toast is a stack: newest is prepended and the bottom-anchored container
// grows upward, so a toast (which may carry a tap target) never moves once
// on screen. The cap retires the oldest first.
const TOAST_MAX = 3;
const TOAST_FADE_MS = 220; // keep in sync with .toast-item.leaving in styles.css
const toastHost = document.getElementById("toast");
// Live toasts, newest first: { el, msg, label, timer, gone } records
// (expandos on the element fail the types/ typecheck).
let toastItems = [];

const dismissToast = (rec) => {
  if (!rec || rec.gone) return;
  rec.gone = true;
  clearTimeout(rec.timer);
  const i = toastItems.indexOf(rec);
  if (i >= 0) toastItems.splice(i, 1);
  rec.el.classList.add("leaving");
  // Unmount after the fade; rec.gone guards removeChild running once.
  setTimeout(() => toastHost.removeChild(rec.el), TOAST_FADE_MS);
};

// Auto-dismiss is per toast, not one shared timer.
const armToastTimer = (rec, ms) => {
  clearTimeout(rec.timer);
  rec.timer = setTimeout(() => dismissToast(rec), ms);
};

// `action` is null for a plain toast, or { label, fn } for a tappable one.
const pushToast = (msg, ms, action) => {
  msg = String(msg);
  // A repeated plain message extends in place; a repeated offer is replaced
  // so the freshest closure runs.
  for (const live of toastItems.slice()) {
    if (live.msg !== msg) continue;
    if (!action && !live.label) {
      armToastTimer(live, ms);
      return live;
    }
    if (action && live.label === action.label) dismissToast(live);
  }

  const item = document.createElement("div");
  item.className = "toast-item";
  const span = document.createElement("span");
  span.className = "toast-msg";
  span.textContent = msg;
  item.append(span);
  const rec = { el: item, msg, label: action ? action.label : null, timer: 0, gone: false };

  if (action) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "toast-action";
    btn.textContent = action.label;
    const close = document.createElement("button");
    close.type = "button";
    close.className = "toast-close";
    close.setAttribute("aria-label", "Dismiss");
    close.textContent = "×";
    close.addEventListener("click", (e) => {
      e.stopPropagation(); // the pill-wide action handler must not also fire
      dismissToast(rec);
    });
    item.append(btn, close);
    item.classList.add("has-action");
    // The whole pill is the tap target. fn() runs synchronously with nothing
    // awaited before it: callers use this tap for iOS's user-gesture
    // requirement (requestPermission / getUserMedia).
    const fn = action.fn;
    item.onclick = () => {
      item.onclick = null;
      dismissToast(rec);
      fn();
    };
  }

  // Prepend: newest on top.
  toastHost.prepend(item);
  toastItems.unshift(rec);
  while (toastItems.length > TOAST_MAX) dismissToast(toastItems[toastItems.length - 1]);
  armToastTimer(rec, ms);
  return rec;
};

const showToast = (msg) => pushToast(msg, 2200, null);

// Toast with a single action; lingers longer than a plain toast.
const showActionToast = (msg, label, fn, ms = 8000) =>
  pushToast(msg, ms, { label, fn });

const stateKey = (name) => "state:" + name;

const captureStateBytes = () => {
  if (typeof Module === "undefined" || !Module._wasm_state_size) return null;
  let len = Module._wasm_state_size();
  if (len <= 0) return null;
  let ptr = Module._wasm_state_data();
  if (!ptr) return null;
  // Copy out immediately: the buffer lives until the next wasm_state_size
  // call, and the heap can move.
  return new Uint8Array(Module.memory.buffer, ptr, len).slice();
};

// Sniff the header magic (STATE_MAGIC in src/dingbat/common/serialize.nim)
// to tell "not a save state" from "a state the core rejected".
const STATE_MAGIC = "DGBSTATE";
const looksLikeStateFile = (bytes) =>
  !!bytes && bytes.length >= STATE_MAGIC.length &&
  [...STATE_MAGIC].every((c, i) => bytes[i] === c.charCodeAt(0));

// Toast copy per StateRejectKind (src/dingbat/common/serialize.nim, via
// wasm_state_error_kind): one sentence per cause saying what to do.
const SRK = {
  NONE: 0, NOT_A_STATE: 1, WRONG_CORE: 2, WRONG_ROM: 3,
  TOO_NEW: 4, TRUNCATED: 5, CORRUPT: 6, NO_FILE: 7,
};
const STATE_REJECT_COPY = {
  [SRK.NOT_A_STATE]: "That file isn't a dingbat save state.",
  [SRK.WRONG_CORE]:
    "That save state is for the other system — a Game Boy state can't load into a GBA game, or the reverse.",
  [SRK.WRONG_ROM]:
    "That save state belongs to a different game. Load the game it was made in, then try again.",
  [SRK.TOO_NEW]:
    "That save state was made by a newer version of dingbat than this one. Update dingbat and try again.",
  [SRK.TRUNCATED]:
    "That save state file is incomplete — the download or copy was cut short. Try getting the file again.",
  [SRK.CORRUPT]:
    "That save state is damaged and can't be loaded. The game is still running and nothing was changed.",
  // Native-only today; kept so the ordinals stay a complete contract.
  [SRK.NO_FILE]: "There's no save state in that slot yet.",
};

const stateRejectKind = () => {
  try {
    if (typeof Module !== "undefined" && Module._wasm_state_error_kind) {
      return Module._wasm_state_error_kind();
    }
  } catch {}
  return SRK.NONE;
};

/** The one-line detail from the core, for the console. */
const stateRejectDetail = () => {
  try {
    if (typeof Module !== "undefined" && Module._wasm_state_error) {
      return Module.UTF8ToString(Module._wasm_state_error()) || "";
    }
  } catch {}
  return "";
};

const stateRejectMessage = (bytes) => {
  if (!looksLikeStateFile(bytes)) return STATE_REJECT_COPY[SRK.NOT_A_STATE];
  const copy = STATE_REJECT_COPY[stateRejectKind()];
  if (copy) return copy;
  const why = stateRejectDetail();
  if (!why) return "That save state couldn't be loaded.";
  // Fall back to the core's own wording, sentence-cased.
  return why.charAt(0).toUpperCase() + why.slice(1).replace(/\.$/, "");
};

// Apply a state image; true when accepted. keepRewind is only for undoing
// a rewind-scrubber commit (same timeline as the ring); every other load
// drops the ring.
const applyStateBytes = (bytes, keepRewind = false) => {
  if (typeof Module === "undefined" || !Module._wasm_load_state) return false;
  let ptr = Module._malloc(bytes.length);
  if (!ptr) return false;
  // Heap view after _malloc: growth can detach the old buffer.
  new Uint8Array(Module.memory.buffer, ptr, bytes.length).set(bytes);
  let ok = Module._wasm_load_state(ptr, bytes.length, keepRewind ? 1 : 0) === 1;
  Module._free(ptr);
  return ok;
};

// --- Save-state slots ---
// Nine per-ROM slots. Slot 0 ("Quick") keeps the legacy "state:<name>" key;
// slots 1..8 add ":slotN". Thumbnail + timestamp live under "statemeta:...".
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

// Thumbnail dataURL from the wasm framebuffer pointer (works paused; needs
// no preserveDrawingBuffer).
const captureThumbnail = () => {
  if (typeof Module === "undefined" || !Module._wasm_fb_ptr) return null;
  const ptr = Module._wasm_fb_ptr();
  if (!ptr) return null;
  const [w, h] = gameRes();
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
    markUpload(slotStateKey(currentOriginalName, slot));
    markUpload(slotMetaKey(currentOriginalName, slot));
    return true;
  } catch (e) {
    showToast("Save state failed: " + e.message);
    return false;
  }
};

// Undo buffer for the last state load; in-memory, until the next load or
// ROM switch.
var stateUndoBytes = null;
var stateUndoName = null;

const undoStateLoad = () => {
  if (!stateUndoBytes || stateUndoName !== currentOriginalName) return;
  if (applyStateBytes(stateUndoBytes)) {
    stateUndoBytes = null;
    showToast("Back to before the load");
  }
};

// Apply a slot's state; the core validates and leaves itself untouched on
// a mismatch.
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
  const undo = captureStateBytes(); // where the game is NOW, pre-load
  const ok = applyStateBytes(bytes);
  if (ok && undo) {
    stateUndoBytes = undo;
    stateUndoName = currentOriginalName;
    showActionToast("State loaded", "Undo", undoStateLoad, 6000);
  } else {
    showToast(ok ? "State loaded" : stateRejectMessage(bytes));
  }
  return ok;
};

// --- Auto save-state (session resume) ---
// Captured when the page is hidden or closed; local-only (an upload every
// tab switch otherwise).
const autoStateKey = (name) => "stateauto:" + name;

const persistAutoState = () => {
  if (!currentRomName || !currentOriginalName) return;
  if (linkMode || rollbackMode || netActive()) return; // frame-synced modes
  const bytes = captureStateBytes();
  if (!bytes) return;
  dbPut(autoStateKey(currentOriginalName), { bytes, ts: Date.now() }).catch(() => {});
};

const fmtAgo = (ts) => {
  const m = Math.round((Date.now() - ts) / 60000);
  if (m < 1) return "moments ago";
  if (m < 60) return m + "m ago";
  const h = Math.round(m / 60);
  if (h < 48) return h + "h ago";
  return Math.round(h / 24) + "d ago";
};

// The core's header check keeps a stale/mismatched snapshot harmless.
const offerAutoResume = async () => {
  const name = currentOriginalName;
  if (!name) return;
  let auto = null;
  try {
    auto = await dbGet(autoStateKey(name));
  } catch {}
  if (!auto || !auto.bytes || name !== currentOriginalName) return;
  showActionToast("Last session saved " + fmtAgo(auto.ts), "Resume", () => {
    if (currentOriginalName !== name) return; // switched games since
    showToast(applyStateBytes(auto.bytes) ? "Resumed" : "Couldn't restore the session");
  });
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

// --- Save States modal ---
const statesModal = document.getElementById("states-modal");
const statesGrid = document.getElementById("states-grid");
const statesSaveBtn = /** @type {HTMLButtonElement} */ (document.getElementById("states-save"));
const statesLoadBtn = /** @type {HTMLButtonElement} */ (document.getElementById("states-load"));
const statesDeleteBtn = /** @type {HTMLButtonElement} */ (document.getElementById("states-delete"));
const statesEmpty = document.getElementById("states-empty");
const statesHint = document.getElementById("states-hint");
let selectedSlot = 0;
let slotHasState = [];

const updateStatesButtons = () => {
  const loaded = !!currentOriginalName;
  const has = loaded && slotHasState[selectedSlot];
  statesSaveBtn.disabled = !loaded;
  statesLoadBtn.disabled = !has;
  statesDeleteBtn.disabled = !has;
};

const selectSlot = (s) => {
  selectedSlot = s;
  for (const el of /** @type {HTMLCollectionOf<HTMLElement>} */ (statesGrid.children)) {
    el.classList.toggle("selected", Number(el.dataset.slot) === s);
  }
  updateStatesButtons();
};

const renderStatesGrid = async () => {
  const name = currentOriginalName;
  statesEmpty.hidden = !!name;
  statesHint.hidden = !name;
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
    cell.dataset.slot = /** @type {*} */ (s);
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

statesDeleteBtn.addEventListener("click", async () => {
  if (!currentOriginalName || !slotHasState[selectedSlot]) return;
  const label = selectedSlot === 0 ? "the Quick slot" : "slot " + (selectedSlot + 1);
  if (!confirm("Delete the save state in " + label + "? This can't be undone.")) return;
  await dbDelete(slotStateKey(currentOriginalName, selectedSlot));
  await dbDelete(slotMetaKey(currentOriginalName, selectedSlot));
  markDelete(slotStateKey(currentOriginalName, selectedSlot));
  markDelete(slotMetaKey(currentOriginalName, selectedSlot));
  showToast("Deleted " + label);
  await renderStatesGrid();
});

// --- Report a Bug modal ---
// A downloadable bundle {title, description, diagnostics, save state},
// client-side only; the state carries RAM/registers + a screenshot, never
// the ROM. The scrubber picks the moment from the rewind ring's thumbnails.
const reportModal = document.getElementById("report-modal");
const reportTitle = /** @type {HTMLInputElement} */ (document.getElementById("report-title"));
const reportDesc = /** @type {HTMLTextAreaElement} */ (document.getElementById("report-desc"));
const reportSlider = /** @type {HTMLInputElement} */ (document.getElementById("report-slider"));
const reportWhen = document.getElementById("report-when");
const reportPreview = /** @type {HTMLCanvasElement} */ (document.getElementById("report-preview"));
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
  const [w, h] = gameRes();
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

// Slider 0..N, max = "now"; back = 0 is the live frame, 1..N are rewind
// samples 0..N-1.
const reportSliderBack = () => reportSamples - Number(reportSlider.value);

const updateReportPreview = () => {
  const back = reportSliderBack();
  if (back === 0) {
    reportWhen.textContent = "now";
    drawReportLivePreview();
  } else {
    const sample = back - 1;
    const tenths = Module._wasm_rewind_scrub_seconds_ago(sample);
    reportWhen.textContent = (tenths / 10).toFixed(1) + "s ago";
    drawReportSamplePreview(sample);
  }
};

reportSlider.addEventListener("input", updateReportPreview);

const openReportModal = () => {
  menuDropdown.hidden = true;
  reportWasPaused = paused;
  // Freeze so the strip stays the ring's contents (samples are addressed
  // by snapshot ID, so an evicted one goes blank rather than sliding).
  paused = true;
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
  reportSlider.max = String(reportSamples); // 0..N; right end (max) = now
  reportSlider.value = String(reportSamples);
  reportScrub.classList.toggle("disabled", !currentOriginalName);
  // body.rewind-off hides the timeline; the hint says why.
  reportScrubHint.textContent = rewindOn
    ? "Slide left to go further back in time. Enable Rewind in Settings to capture a longer timeline."
    : "Rewind is off, so only this moment can be attached. Turn Rewind on in Settings to pick an earlier one.";
  reportScrubHint.hidden = rewindOn && reportSamples > 0;
  updateReportPreview();
  reportModal.classList.add("open");
  trapFocus(reportModal);
};

const closeReportModal = () => {
  // The global Escape handler calls every closer blindly; a stale
  // reportWasPaused would unpause a game paused later.
  if (!reportModal.classList.contains("open")) return;
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
  const back = reportSliderBack();
  let stateBytes = null;
  let savedFrom = "current frame";
  if (back === 0) {
    stateBytes = captureStateBytes();
  } else {
    const sample = back - 1;
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
    // Never the ROM.
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

// --- Film strip (shared scrubber component) --------------------------------
// One draggable strip of thumbnails with N markers: Rewind (one) and Save a
// Clip (two). The caller supplies the canvas + wrapper, one element per
// marker, and a `paint` callback for the shading; it gets marker values in
// samples back from newest, clamped, ordered and snapped. Thumbnails arrive
// from wasm as packed little-endian BGR555, newest first.

const STRIP_GAP = 2;             // px between frames in the strip
const STRIP_TAP_SLOP = 5;        // px of travel below which a drag counts as a tap

// Frame size is driven by how many should be visible across the strip's
// own width (a 208px phone strip and a 400px desktop one show the same
// history), clamped at both ends. A range picker overrides these for span,
// and states the span it needs in pitches (`fitFrames`); the fit wins over
// frameWMin, down to STRIP_FRAME_W_FLOOR.
const STRIP_VISIBLE_FRAMES = 5.5;
const STRIP_FRAME_W_MIN = 38;
const STRIP_FRAME_W_MAX = 72;
// Below this the fit rule gives up and the bracket goes off-strip.
const STRIP_FRAME_W_FLOOR = 16;

/**
 * @param {object} opts
 * @param {HTMLCanvasElement} opts.canvas   the strip canvas
 * @param {HTMLElement} opts.wrap           its clipping wrapper (the drag target)
 * @param {{el: HTMLElement, edge: string}[]} opts.markers
 *        `edge` is which side of the selected FRAME the marker sits on:
 *        "trail" = its right-hand edge (the frame is on the left of the line),
 *        "lead"  = its left-hand edge (the frame is on the right).
 * @param {(ctx: CanvasRenderingContext2D, g: object) => void} opts.paint
 * @param {(marker: number) => void} opts.onChange  fired after a marker moves
 * @param {number} [opts.visibleFrames]  frames across the strip's width
 * @param {number} [opts.frameWMin]      px floor on a frame's width
 * @param {number} [opts.frameWMax]      px ceiling on a frame's width
 * @param {number} [opts.fitFrames]      frame pitches that MUST fit the width
 * @param {number} [opts.frameWFloor]    px floor the fit rule may shrink to
 */
const createFilmStrip = ({
  canvas, wrap, markers, paint, onChange,
  visibleFrames = STRIP_VISIBLE_FRAMES,
  frameWMin = STRIP_FRAME_W_MIN,
  frameWMax = STRIP_FRAME_W_MAX,
  fitFrames = 0,
  frameWFloor = STRIP_FRAME_W_FLOOR,
}) => {
  let samples = 0;
  let thumbs = null;      // packed BGR555, copied out of wasm at open
  let thumbW = 0;
  let thumbH = 0;
  let stripColor = null;  // offscreen: the whole strip, in colour
  let stripDim = null;    // ...and desaturated
  let pitch = 0;          // px per sample along the strip
  let values = markers.map(() => 0);
  let active = 0;         // which marker the view follows / a drag moves

  const frameSize = (stripW, stripH) => {
    const maxH = Math.max(8, stripH - 6);
    let tw = Math.round(
      Math.min(frameWMax, Math.max(frameWMin, stripW / visibleFrames))
    );
    // `fitFrames` pitches must land inside the width: a bracket off the end
    // reads as "the clip ends here". The fit beats frameWMin.
    if (fitFrames > 0) {
      tw = Math.max(frameWFloor,
                    Math.min(tw, Math.floor(stripW / fitFrames) - STRIP_GAP));
    }
    let th = Math.round((tw * thumbH) / thumbW);
    if (th > maxH) {
      th = maxH;
      tw = Math.max(12, Math.round((th * thumbW) / thumbH));
    }
    return { tw, th };
  };

  // The desaturated copy is baked once per open: CanvasRenderingContext2D
  // .filter only arrived in Safari 17 and iOS 15 is supported.
  const build = () => {
    stripColor = null;
    stripDim = null;
    if (!thumbs || samples <= 0) return;
    const rect = wrap.getBoundingClientRect();
    const stripH = Math.max(24, Math.round(rect.height) - 2);
    const { tw, th } = frameSize(Math.max(120, Math.round(rect.width)), stripH);
    pitch = tw + STRIP_GAP;
    const total = samples * pitch;

    const scratch = document.createElement("canvas");
    scratch.width = thumbW;
    scratch.height = thumbH;
    const sctx = scratch.getContext("2d");

    stripColor = document.createElement("canvas");
    stripColor.width = total;
    stripColor.height = stripH;
    const cctx = stripColor.getContext("2d");
    const stride = thumbW * thumbH * 2;
    const top = Math.round((stripH - th) / 2);
    for (let s = 0; s < samples; s++) {
      sctx.putImageData(bgr555ToImageData(thumbs, s * stride, thumbW, thumbH), 0, 0);
      // Newest on the right.
      const x = (samples - 1 - s) * pitch + Math.floor(STRIP_GAP / 2);
      cctx.drawImage(scratch, 0, 0, thumbW, thumbH, x, top, tw, th);
    }

    stripDim = document.createElement("canvas");
    stripDim.width = total;
    stripDim.height = stripH;
    const dctx = stripDim.getContext("2d");
    dctx.drawImage(stripColor, 0, 0);
    const img = dctx.getImageData(0, 0, total, stripH);
    const px = img.data;
    for (let i = 0; i < px.length; i += 4) {
      // Rec.601 luma, halved: readable, never mistaken for the live side.
      const y = (px[i] * 77 + px[i + 1] * 150 + px[i + 2] * 29) >> 9;
      px[i] = px[i + 1] = px[i + 2] = y;
    }
    dctx.putImageData(img, 0, 0);
  };

  // Marker x in strip-bitmap pixels. "trail" = the selected frame's right
  // edge (it is the last one kept, wholly on the colour side); "lead" the
  // mirror for a frame that is the first one kept.
  const edgeX = (index, edge) =>
    edge === "lead" ? (samples - 1 - index) * pitch : (samples - index) * pitch;

  // Film and marker placement. The focus rides the middle and the film
  // scrolls under it until the film runs out of slack, then the markers
  // travel (else half the strip is empty at the "now" end, where these
  // modals open). The focus is the whole selection when it fits, else the
  // dragged marker.
  const placement = (cssW) => {
    const filmW = samples * pitch;
    const xsFilm = markers.map((m, i) => edgeX(values[i], m.edge));
    const lo = Math.min(...xsFilm);
    const hi = Math.max(...xsFilm);
    const focus = hi - lo <= cssW ? (lo + hi) / 2 : xsFilm[active];
    const off = filmW <= cssW
      ? (cssW - filmW) / 2               // short film: centred, markers move
      : Math.min(0, Math.max(cssW - filmW, cssW / 2 - focus));
    return { off, xs: xsFilm.map((x) => x + off) };
  };

  const draw = () => {
    const rect = canvas.getBoundingClientRect();
    const cssW = Math.max(1, Math.round(rect.width));
    const cssH = Math.max(1, Math.round(rect.height));
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    if (canvas.width !== cssW * dpr || canvas.height !== cssH * dpr) {
      canvas.width = cssW * dpr;
      canvas.height = cssH * dpr;
    }
    const ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, cssW, cssH);
    if (!stripColor) return;
    const { off, xs } = placement(cssW);
    // A marker on the film's outer edge is nudged just inside (half of it
    // would be clipped). A genuinely off-screen marker is marked instead,
    // and the CSS drops its line: pinning it would claim the selection ends there.
    markers.forEach((m, i) => {
      m.el.style.left = Math.min(Math.max(xs[i], 2), cssW - 2) + "px";
      m.el.classList.toggle("offscreen", xs[i] < -1 || xs[i] > cssW + 1);
    });
    paint(ctx, { cssW, cssH, off, xs, color: stripColor, dim: stripDim });
  };

  // Colour inside [x0, x1), greyed outside.
  const shadeBetween = (ctx, g, x0, x1) => {
    const bands = [[0, x0], [x1, g.cssW]];
    ctx.save();
    ctx.beginPath();
    ctx.rect(x0, 0, Math.max(0, x1 - x0), g.cssH);
    ctx.clip();
    ctx.drawImage(g.color, g.off, 0);
    ctx.restore();
    for (const [a, b] of bands) {
      if (b <= a) continue;
      ctx.save();
      ctx.beginPath();
      ctx.rect(a, 0, b - a, g.cssH);
      ctx.clip();
      ctx.drawImage(g.dim, g.off, 0);
      ctx.globalAlpha = 0.35;
      ctx.fillStyle = "#000";
      ctx.fillRect(a, 0, b - a, g.cssH);
      ctx.restore();
    }
  };

  // Every marker move goes through here. `snap` settles onto a whole frame;
  // a live drag passes false. `bounds` clamps each marker against its
  // neighbours so a two-marker selection cannot invert.
  const setValue = (i, v, snap, bounds) => {
    let lo = 0;
    let hi = Math.max(0, samples - 1);
    if (bounds) {
      if (bounds.min !== undefined) lo = Math.max(lo, bounds.min);
      if (bounds.max !== undefined) hi = Math.min(hi, bounds.max);
    }
    if (hi < lo) hi = lo;
    const clamped = Math.min(Math.max(v, lo), hi);
    const next = snap ? Math.round(clamped) : clamped;
    if (next === values[i]) return false;
    values[i] = next;
    return true;
  };

  // Pointer-driven, not a scroll container: iOS scroll momentum would
  // select a frame the player never chose.
  let dragging = false;
  let lastX = 0;
  let travel = 0;

  // A press grabs the nearest marker on screen.
  const grabNearest = (clientX) => {
    if (markers.length === 1) return 0;
    const rect = wrap.getBoundingClientRect();
    const { xs } = placement(rect.width);
    const px = clientX - rect.left;
    let best = 0;
    for (let i = 1; i < xs.length; i++) {
      if (Math.abs(xs[i] - px) < Math.abs(xs[best] - px)) best = i;
    }
    return best;
  };

  const api = {
    get samples() { return samples; },
    get pitch() { return pitch; },
    get thumbW() { return thumbW; },
    get thumbH() { return thumbH; },
    get thumbs() { return thumbs; },
    values,
    /** Whole-frame value of marker `i` (fractional mid-drag). */
    at(i) { return Math.round(values[i]); },
    /** Adopt a captured strip. `data` is a copy: the wasm heap can move. */
    load(data, w, h, n) {
      thumbs = data;
      thumbW = w;
      thumbH = h;
      samples = n;
      stripColor = null;
      stripDim = null;
    },
    /** Drop everything on close (tens of thumbnails). */
    release() {
      thumbs = null;
      stripColor = null;
      stripDim = null;
      samples = 0;
    },
    setValue(i, v, snap, bounds) {
      const moved = setValue(i, v, snap, bounds);
      if (moved) onChange(i);
      return moved;
    },
    setActive(i) { active = i; },
    build,
    draw,
    shadeBetween,
    /** Paint one thumbnail into a preview canvas at native size. */
    preview(el, sample) {
      if (!thumbs || samples <= 0) return;
      const stride = thumbW * thumbH * 2;
      const s = Math.min(Math.max(sample, 0), samples - 1);
      el.width = thumbW;
      el.height = thumbH;
      el.getContext("2d").putImageData(
        bgr555ToImageData(thumbs, s * stride, thumbW, thumbH), 0, 0);
    },
    /** Bind the drag/tap gesture. `bounds(i)` returns marker i's clamp. */
    attach(bounds) {
      const boundsFor = (i) => (bounds ? bounds(i) : undefined);
      wrap.addEventListener("pointerdown", (e) => {
        if (samples <= 0) return;
        e.preventDefault();
        dragging = true;
        travel = 0;
        lastX = e.clientX;
        active = grabNearest(e.clientX);
        wrap.setPointerCapture(e.pointerId);
        draw();  // the view follows the newly active marker
      });
      wrap.addEventListener("pointermove", (e) => {
        if (!dragging) return;
        const dx = e.clientX - lastX;
        lastX = e.clientX;
        travel += Math.abs(dx);
        // Dragging right pulls older frames under the marker.
        api.setValue(active, values[active] + dx / pitch, false, boundsFor(active));
      });
      const endDrag = (e) => {
        if (!dragging) return;
        dragging = false;
        if (wrap.hasPointerCapture?.(e.pointerId)) wrap.releasePointerCapture(e.pointerId);
        if (travel <= STRIP_TAP_SLOP && e.type === "pointerup") {
          // A tap moves the nearest marker to the frame under the finger,
          // resolved through the draw's own placement.
          const rect = wrap.getBoundingClientRect();
          const { off } = placement(rect.width);
          const filmX = e.clientX - rect.left - off;
          api.setValue(active, samples - 1 - Math.floor(filmX / pitch), true,
                       boundsFor(active));
        } else {
          api.setValue(active, values[active], true, boundsFor(active)); // settle
        }
        onChange(active);
      };
      for (const ev of ["pointerup", "pointercancel", "pointerleave"]) {
        wrap.addEventListener(ev, endDrag);
      }
    },
  };
  return api;
};

// --- Rewind scrubber -------------------------------------------------------
// Dragging paints the ring's thumbnails; a real state is built once, on
// commit. Destructive (two-tap confirm), and a third tap when it would cost
// the battery save. An ordinary modal on the film-strip component above.

const rewindModal = document.getElementById("rewind-modal");
const rwStripCanvas = /** @type {HTMLCanvasElement} */ (document.getElementById("rewind-strip"));
// By id: the test harness's fake DOM resolves getElementById, and a null
// module-scope global aborts every web test.
const rwStripWrap = document.getElementById("rewind-strip-wrap");
const rwPreview = /** @type {HTMLCanvasElement} */ (document.getElementById("rewind-preview"));
const rwSlider = /** @type {HTMLInputElement} */ (document.getElementById("rewind-slider"));
const rwWhen = document.getElementById("rewind-when");
const rwPlayhead = document.getElementById("rewind-playhead");
const rwOldest = document.getElementById("rewind-oldest");
const rwWarn = document.getElementById("rewind-warn");
const rwCommitBtn = /** @type {HTMLButtonElement} */ (document.getElementById("rewind-commit"));
const rwHint = document.getElementById("rewind-scrub-hint");

// Thumbnails pulled from the ring: each is a full BGR555 copy (19 KB GBA,
// 26 KB GB); 96 covers a minute and a half at ~2.5 MB transiently.
const RW_MAX_SAMPLES = 96;

let rwStage = 0;              // 0 pick, 1 confirm discard, 2 confirm save loss
let rwWasPaused = false;
let rwUndoBytes = null;
let rwUndoName = null;

// "2m 14s" / "8.4s".
const fmtDuration = (tenths) => {
  const s = tenths / 10;
  if (s < 60) return (s < 10 ? s.toFixed(1) : Math.round(s)) + "s";
  const m = Math.floor(s / 60);
  return m + "m " + Math.round(s - m * 60) + "s";
};

const rwTenthsAt = (sample) =>
  sample > 0 && Module._wasm_rewind_scrub_seconds_ago
    ? Module._wasm_rewind_scrub_seconds_ago(sample)
    : 0;

const rwStrip = createFilmStrip({
  canvas: rwStripCanvas,
  wrap: rwStripWrap,
  markers: [{ el: rwPlayhead, edge: "trail" }],
  // Colour up to the cut; the discarded future greyed beyond it.
  paint: (ctx, g) => rwStrip.shadeBetween(ctx, g, 0, g.xs[0]),
  onChange: () => {
    // Any playhead movement disarms the confirm.
    rwStage = 0;
    rwRefresh();
  },
});
rwStrip.attach();

const rwSelected = () => rwStrip.at(0);

// Stages 1 and 2 are the two confirmations.
const rwRefreshActions = () => {
  const sel = rwSelected();
  const cost = fmtDuration(rwTenthsAt(sel));
  rwCommitBtn.classList.toggle("armed", rwStage > 0);
  rwWarn.classList.toggle("save-loss", rwStage === 2);
  if (sel === 0) {
    rwCommitBtn.disabled = true;
    rwCommitBtn.textContent = "Rewind to this point";
    rwWarn.hidden = true;
    return;
  }
  rwCommitBtn.disabled = false;
  if (rwStage === 0) {
    rwCommitBtn.textContent = "Rewind to this point · discards " + cost;
    rwWarn.hidden = true;
  } else if (rwStage === 1) {
    rwCommitBtn.textContent = "Yes, discard " + cost;
    rwWarn.hidden = false;
    rwWarn.textContent =
      "The last " + cost + " will be thrown away. You will not be able to move forward again.";
  } else {
    rwCommitBtn.textContent = "Rewind and lose that save";
    rwWarn.hidden = false;
    rwWarn.textContent =
      "This also rolls your in-game save back to how it was " + cost +
      " ago. Anything the game has saved to the cartridge since then will be gone.";
  }
};

const rwRefresh = () => {
  const sel = rwSelected();
  rwWhen.textContent = sel === 0 ? "now" : fmtDuration(rwTenthsAt(sel)) + " ago";
  if (rwSlider.value !== String(rwStrip.samples - 1 - sel)) {
    rwSlider.value = String(rwStrip.samples - 1 - sel);
  }
  rwStrip.draw();
  rwStrip.preview(rwPreview, sel);
  rwRefreshActions();
};

// The range input is the keyboard path onto the same state, not a second truth.
rwSlider.addEventListener("input", () => {
  rwStrip.setValue(0, rwStrip.samples - 1 - Number(rwSlider.value), true);
});

const openRewindScrubber = () => {
  menuDropdown.hidden = true;
  if (!rewindOn) return;   // no ring, so the strip would only ever be empty
  if (!currentOriginalName || !speedControlsOk()) return;
  if (typeof Module === "undefined" || !Module._wasm_rewind_scrub_generate) return;
  rwWasPaused = paused;
  // Freeze the core so the ring stays what the strip shows.
  paused = true;
  rwStage = 0;
  rwStrip.release();
  rwStrip.values[0] = 0;
  const n = Module._wasm_rewind_scrub_generate(RW_MAX_SAMPLES);
  if (n > 0) {
    const w = Module._wasm_rewind_scrub_thumb_w();
    const h = Module._wasm_rewind_scrub_thumb_h();
    const ptr = Module._wasm_rewind_scrub_thumbs_ptr();
    rwStrip.load(new Uint8Array(Module.memory.buffer, ptr, n * w * h * 2).slice(), w, h, n);
  }
  rwSlider.max = String(Math.max(0, n - 1));
  rwSlider.value = String(Math.max(0, n - 1));
  rwHint.textContent =
    n > 1
      ? "Drag the strip, or the bar for longer jumps. Everything right of the line is discarded."
      : "No rewind history yet — it builds up as you play.";
  rwOldest.textContent = n > 1 ? fmtDuration(rwTenthsAt(n - 1)) + " ago" : "";
  rewindModal.classList.add("open");
  trapFocus(rewindModal);
  // After .open, so the strip has a laid-out height.
  rwStrip.build();
  rwRefresh();
};

const closeRewindScrubber = () => {
  // The global Escape handler calls every closer blindly; a stale
  // rwWasPaused would unpause a game paused later.
  if (!rewindModal.classList.contains("open")) return;
  rewindModal.classList.remove("open");
  releaseFocus(rewindModal);
  rwStrip.release();
  rwStage = 0;
  paused = rwWasPaused;
};

const rwUndoCommit = () => {
  if (!rwUndoBytes || rwUndoName !== currentOriginalName) return;
  // keepRewind: the same timeline the ring still holds.
  if (applyStateBytes(rwUndoBytes, true)) {
    rwUndoBytes = null;
    showToast("Back to where you were");
  }
};

const rwCommit = () => {
  const sel = rwSelected();
  if (sel <= 0) return;
  const cost = fmtDuration(rwTenthsAt(sel));
  const undo = captureStateBytes(); // where the game is NOW, pre-commit
  if (Module._wasm_rewind_commit(sel) !== 1) {
    showToast("That moment is no longer in the rewind history");
    closeRewindScrubber();
    return;
  }
  closeRewindScrubber();
  if (undo) {
    rwUndoBytes = undo;
    rwUndoName = currentOriginalName;
    showActionToast("Rewound " + cost, "Undo", rwUndoCommit, 8000);
  } else {
    showToast("Rewound " + cost);
  }
};

// The commit button is the confirmation, in place. Stage 2 only when the
// rewind would cost a save.
rwCommitBtn.addEventListener("click", () => {
  const sel = rwSelected();
  if (sel <= 0) return;
  if (rwStage === 0) {
    rwStage = 1;
    rwRefreshActions();
    return;
  }
  if (rwStage === 1) {
    const differs =
      Module._wasm_rewind_scrub_save_differs &&
      Module._wasm_rewind_scrub_save_differs(sel) === 1;
    if (differs) {
      rwStage = 2;
      rwRefreshActions();
      return;
    }
  }
  rwCommit();
});

document.getElementById("rewind-scrub-close").addEventListener("click", closeRewindScrubber);
document.getElementById("rewind-scrub-cancel").addEventListener("click", closeRewindScrubber);
rewindModal.addEventListener("click", (e) => {
  if (e.target === rewindModal) closeRewindScrubber();
});
document.getElementById("open-rewind-scrub").addEventListener("click", openRewindScrubber);

// The strip bitmaps are rasterised for one strip height and frame size,
// which change across the phone/desktop breakpoint.
window.addEventListener("resize", () => {
  if (!rewindModal.classList.contains("open")) return;
  rwStrip.build();
  rwRefresh();
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

// Apply an imported .state to the running game (not persisted).
const applyImportedState = (bytes) => {
  showToast(applyStateBytes(bytes) ? "State loaded" : stateRejectMessage(bytes));
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
const volSliders = Array.from(/** @type {NodeListOf<HTMLInputElement>} */ (document.querySelectorAll(".vol-range")));
const muteBtn = document.getElementById("mute-btn");
const menuVolume = document.getElementById("menu-volume");

// Effective gain applied to the audio graph (0..1), respecting mute.
const effectiveGain = () => (muted ? 0 : volume / 100);

const syncVolumeUI = () => {
  let off = muted || volume === 0;
  for (let s of volSliders) {
    s.value = /** @type {*} */ (volume);
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
    () => dbPut("audio", { volume, muted, pitchCorrectFF, audioLowpass, mp2kHle, fifoInterp }), 250);
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
  if (s && typeof s.audioLowpass === "boolean") audioLowpass = s.audioLowpass;
  if (lowpassToggle) lowpassToggle.checked = audioLowpass;
  applyAudioLowpass();
  if (s && typeof s.mp2kHle === "boolean") mp2kHle = s.mp2kHle;
  if (mp2kHleToggle) mp2kHleToggle.checked = mp2kHle;
  applyMp2kHle();
  if (s && typeof s.fifoInterp === "boolean") fifoInterp = s.fifoInterp;
  if (fifoInterpToggle) fifoInterpToggle.checked = fifoInterp;
  applyFifoInterp();
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
// _wasm_set_color_correction rebuilds the core's BGR555->RGBA LUT. Default on.
var colorCorrect = true;
const ccToggle = /** @type {HTMLInputElement} */ (document.getElementById("color-correct-toggle"));

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
// Persisted in the "audio" record; independent of the rollback-synced 2x state.
var pitchCorrectFF = false;
const pcffToggle = /** @type {HTMLInputElement} */ (document.getElementById("pitch-correct-ff-toggle"));

const applyPitchCorrectFF = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_pitch_correct_ff) {
    // Suspended (not overwritten) while speed mode is on
    Module._wasm_set_pitch_correct_ff((pitchCorrectFF && !speedMode) ? 1 : 0);
  }
};

if (pcffToggle) {
  pcffToggle.addEventListener("change", () => {
    pitchCorrectFF = pcffToggle.checked;
    applyPitchCorrectFF();
    saveAudioSettings();
  });
}

// --- GBA audio interpolation ---
// Cubic reconstruction of the DirectSound FIFO stream, on by default; off is
// bit-true DAC output. The wasm side remembers it for future cores.
var fifoInterp = true;
const fifoInterpToggle = /** @type {HTMLInputElement} */ (document.getElementById("fifo-interp-toggle"));

const applyFifoInterp = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_fifo_interp) {
    // Suspended (not overwritten) while speed mode is on
    Module._wasm_set_fifo_interp((fifoInterp && !speedMode) ? 1 : 0);
  }
};

if (fifoInterpToggle) {
  fifoInterpToggle.addEventListener("change", () => {
    fifoInterp = fifoInterpToggle.checked;
    applyFifoInterp();
    saveAudioSettings();
  });
}

// --- MP2K sound-engine HLE ---
// Opt-in: re-renders GBA music above the FIFO's ~13 kHz when the MP2K/m4a
// engine is detected. The wasm side remembers it for future cores.
var mp2kHle = false;
const mp2kHleToggle = /** @type {HTMLInputElement} */ (document.getElementById("mp2k-hle-toggle"));

const applyMp2kHle = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_mp2k_hle) {
    // Suspended (not overwritten) while speed mode is on
    Module._wasm_set_mp2k_hle((mp2kHle && !speedMode) ? 1 : 0);
  }
};

if (mp2kHleToggle) {
  mp2kHleToggle.addEventListener("change", () => {
    mp2kHle = mp2kHleToggle.checked;
    applyMp2kHle();
    saveAudioSettings();
  });
}

// --- Analog low-pass filter (optional BiquadFilter) ---
// Off by default: routed out of the graph, bit-identical to no filter.
var audioLowpass = false;
const lowpassToggle = /** @type {HTMLInputElement} */ (document.getElementById("audio-lowpass-toggle"));

const applyAudioLowpass = () => {
  if (typeof window.updateAudioLowpass === "function") window.updateAudioLowpass();
};

if (lowpassToggle) {
  lowpassToggle.addEventListener("change", () => {
    audioLowpass = lowpassToggle.checked;
    applyAudioLowpass();
    saveAudioSettings();
  });
}

// --- Video effects ---

var integerScale = false;
// LCD response: on/off over src/dingbat/common/lcd_response.nim; the core
// resolves the panel from the running machine. Two older stored shapes
// ("Motion blur", a panel picker) migrate in loadVideoSettings.
var lcdResponse = false;
// Every panel name the old picker could store; all mean on. Anything else
// falls back to off rather than sliding a bad value into wasm.
const LCD_LEGACY_ON = ["auto", "on", "true", "yes",
                       "dmg", "cgb", "gbc", "agb", "agb001", "gba",
                       "ags", "ags101", "sp"];
var ambientGlow = false;
// The Filter selector: smoothing filters ("hq4x" | "xbr" | "xbrz") and
// screen looks ("grid" | "rgb") in one select, since exactly one is active.
// The screen looks are not u_filter values; drawGame maps them to their own
// uniforms.
var upscaleFilter = "none";
// Speed mode suspends the whole selector; every consumer goes through this.
const effectiveFilter = () => (speedMode ? "none" : upscaleFilter);

// Backing store = native * glScale(); NEAREST sampling makes it a crisp
// integer upscale. The RGB look needs 6: two whole backing pixels per
// stripe, where 4 gives 4/3 and aliases into moire.
const glScale = () => (effectiveFilter() === "rgb" ? 6 : 4);

const canvasEl = /** @type {HTMLCanvasElement} */ (document.getElementById("canvas"));
const stageEl = document.getElementById("stage");
const glowCanvas = /** @type {HTMLCanvasElement} */ (document.getElementById("glow-canvas"));
const glowCtx = glowCanvas.getContext("2d");
const integerScaleToggle = /** @type {HTMLInputElement} */ (document.getElementById("integer-scale-toggle"));
const lcdResponseToggle = /** @type {HTMLInputElement} */ (document.getElementById("lcd-response-toggle"));
const ambientGlowToggle = /** @type {HTMLInputElement} */ (document.getElementById("ambient-glow-toggle"));
const upscaleFilterSelect = /** @type {HTMLSelectElement} */ (document.getElementById("upscale-filter-select"));

// Native picture size. The core is authoritative (an SGB border makes it
// 256x224); the filename check covers the window before the core exists.
const nativeRes = () => {
  if (typeof Module !== "undefined" && Module._wasm_out_w && currentRomName) {
    const w = Module._wasm_out_w(), h = Module._wasm_out_h();
    if (w > 0 && h > 0) return [w, h];
  }
  return currentRomName && extOf(currentRomName) !== ".gba" ? [160, 144] : [240, 160];
};

// Size of the buffer _wasm_fb_ptr / _wasm_game_fb_ptr point at: the
// console's own framebuffer (160x144 even under an SGB border). Readers of
// those pointers must use this, not nativeRes(), or they walk off the heap view.
const gameRes = () =>
  currentRomName && extOf(currentRomName) !== ".gba" ? [160, 144] : [240, 160];

// True while the running cart has an SGB adapter (the shade palette is inert).
const sgbActive = () =>
  !!(typeof Module !== "undefined" && Module._wasm_sgb_active &&
     currentRomName && Module._wasm_sgb_active());

const updateCanvasScaling = () => {
  // Backing store = native * glScale(). Only assign on change: assigning
  // canvas.width/height resets the GL drawing buffer.
  presentDirty = true; // resize can wipe the backing — repaint on the next tick
  const running0 =
    document.body.classList.contains("running") && !!currentRomName;
  if (running0 && !linkMode && !rollbackMode) {
    const [nw, nh] = nativeRes();
    const s = glScale();
    const bw = nw * s, bh = nh * s;
    if (canvasEl.width !== bw) canvasEl.width = bw;
    if (canvasEl.height !== bh) canvasEl.height = bh;
  }
  // Size the canvas box from the stage's box and the backing store's shape.
  // CSS aspect-ratio alone cannot: a max-height clamp squashes instead of
  // shrinking. --game-ar is still published for the pre-JS fallback.
  if (canvasEl.width > 0 && canvasEl.height > 0) {
    canvasEl.style.setProperty("--game-ar", /** @type {*} */ (canvasEl.width / canvasEl.height));
  }
  const ar =
    canvasEl.width > 0 && canvasEl.height > 0
      ? canvasEl.width / canvasEl.height
      : 1.5;
  const running =
    document.body.classList.contains("running") && !!currentRomName;
  // Stage content box: the tablet-landscape tier reserves the rail width as
  // stage padding, and the frame must yield to the rails.
  const stageCS = getComputedStyle(stageEl);
  const availW =
    stageEl.clientWidth -
    parseFloat(stageCS.paddingLeft) - parseFloat(stageCS.paddingRight);
  const availH =
    stageEl.clientHeight -
    parseFloat(stageCS.paddingTop) - parseFloat(stageCS.paddingBottom);
  if (integerScale && running) {
    const [w, h] = nativeRes();
    const k = Math.max(1, Math.floor(Math.min(availW / w, availH / h)));
    canvasEl.style.width = k * w + "px";
    canvasEl.style.height = k * h + "px";
  } else if (running) {
    // Contain-fit.
    const w = Math.min(availW, availH * ar);
    canvasEl.style.width = w + "px";
    canvasEl.style.height = w / ar + "px";
  } else {
    canvasEl.style.width = "";
    canvasEl.style.height = "";
  }
  // Keep the glow canvas pinned to the canvas rect; speed mode suspends it
  // (a visible canvas would show a stale glow).
  const singleCore = running && !linkMode && !rollbackMode && !speedMode;
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

// Sample a coarse grid from the presented framebuffer into the glow canvas
// at ~10 Hz, blended over the previous sample.
const glowBuf = document.createElement("canvas");
glowBuf.width = glowCanvas.width;
glowBuf.height = glowCanvas.height;
const glowBufCtx = glowBuf.getContext("2d");
let glowImage = null;
let glowTick = 0;
let glowFresh = true; // first sample after enabling paints at full alpha

// "#rrggbb" -> the ABGR word the sampler compares against.
const glowPackHex = (c) => {
  const n = parseInt(String(c).replace("#", ""), 16) || 0;
  return (0xff000000 | ((n & 0xff) << 16) | (n & 0xff00) | ((n >> 16) & 0xff)) >>> 0;
};

const updateGlow = () => {
  if (glowCanvas.hidden || !currentRomName || speedMode) return;
  if (typeof Module === "undefined" || !Module._wasm_glow_sample) return;
  if (glowTick++ % 6 !== 0) return;
  const gw = glowCanvas.width;
  const gh = glowCanvas.height;
  // The core samples (it owns the LUT and the SGB border) and touches only
  // the gw*gh cells asked for. See wasm_glow_sample for what is not sampled.
  const pal = gbMonoPanel && !sgbActive() ? gbPaletteColors() : null;
  const remap = !!(pal && pal.length === 4);
  const ptr = Module._wasm_glow_sample(
    gw, gh, remap ? 1 : 0,
    remap ? glowPackHex(pal[0]) : 0, remap ? glowPackHex(pal[1]) : 0,
    remap ? glowPackHex(pal[2]) : 0, remap ? glowPackHex(pal[3]) : 0);
  if (!ptr) return;
  const heap = new Uint8Array(Module.memory.buffer, ptr, gw * gh * 4);
  if (!glowImage) glowImage = glowBufCtx.createImageData(gw, gh);
  const d = glowImage.data;
  for (let y = 0; y < gh; y++) {
    for (let x = 0; x < gw; x++) {
      const si = (y * gw + x) * 4;
      const di = si;
      const r = heap[si], g = heap[si + 1], b = heap[si + 2];
      // Saturation folded in here so the CSS filter is just the blur (one
      // compositor pass). Luma-preserving, matches saturate(1.5).
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

// --- WebGL2 game presentation (web/glpresent.js, shared with the embed) ---
// The raw BGR555 framebuffer (Module._wasm_game_fb_ptr) goes to an R16UI
// texture; the fragment shader unpacks it and applies LCD colour correction
// and scanlines. Link / rollback modes keep their own 2D-canvas blit path.
const glRenderer = createGlRenderer(canvasEl, nativeRes, log);

// True when the next RAF tick must present even without a new frame (first
// paint, resize, a display setting changed).
var presentDirty = true;
var presentSkip = false;
var presentSkips = 0;

// True while the running game is a monochrome Game Boy title (the shade
// palette's gate). Set by detectMonoPanel.
var gbMonoPanel = false;

// Decided as the core does (new_gb in src/dingbat/gb/gb.nim): colour if the
// header's CGB flag is set (0x80 / 0xC0) or a CGB boot ROM is installed
// (it colourises monochrome carts itself). Read here, not exported from
// wasm, so the feature stays in the presentation layer; the shader
// substitutes only exact DMG shade values anyway.
const detectMonoPanel = (romFile) => {
  gbMonoPanel = false;
  if (extOf(romFile) === ".gba") return;
  try {
    const rom = FS.readFile(romFile);
    if (!rom || rom.length < 0x150) return;
    if ((rom[0x143] & 0x80) !== 0) return;      // CGB-enhanced or CGB-only
  } catch (e) { return; }
  try {
    // The core's test: larger than the 0x100-byte DMG boot ROM.
    if (FS.readFile("bootrom.bin").length > 0x100) return;
  } catch (e) { /* no boot ROM installed — monochrome stays monochrome */ }
  gbMonoPanel = true;
};

// An SGB border changes the output size mid-session; the presenter watches
// for it, since the backing store, --game-ar and the fit all key off nativeRes().
var lastOutW = 0, lastOutH = 0;

const drawGame = () => {
  if (!currentRomName || linkMode || rollbackMode) return;
  const [ow, oh] = nativeRes();
  if (ow !== lastOutW || oh !== lastOutH) {
    lastOutW = ow; lastOutH = oh;
    updateCanvasScaling();
    syncGbPaletteUI();   // the SGB note appears with the adapter
  }
  glRenderer.draw({
    colorCorrect,
    // Under SGB colour the framebuffer no longer holds DMG shade values, so
    // the palette would no-op; gate it and say so (syncGbPaletteUI).
    dmgPalette: gbMonoPanel && !sgbActive() ? gbPaletteColors() : null,
    panelGbc: Module._wasm_panel_gbc
      ? Module._wasm_panel_gbc() === 1
      : extOf(currentRomName) !== ".gba",
    // Screen looks are their own uniforms; smoothing values pass through and
    // glpresent maps anything else to u_filter 0.
    grid: effectiveFilter() === "grid",
    subpixel: effectiveFilter() === "rgb",
    filter: effectiveFilter(),
  });
};

const saveVideoSettings = () => {
  if (db) dbPut("video", { integerScale, lcdResponse, ambientGlow, upscaleFilter });
};

const applyLcdResponse = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_lcd_response) {
    // Suspended (not overwritten) while speed mode is on.
    Module._wasm_set_lcd_response((lcdResponse && !speedMode) ? 1 : 0);
  }
};

integerScaleToggle.addEventListener("change", () => {
  integerScale = integerScaleToggle.checked;
  updateCanvasScaling();
  saveVideoSettings();
});

lcdResponseToggle.addEventListener("change", () => {
  lcdResponse = lcdResponseToggle.checked;
  applyLcdResponse();
  drawGame();   // the panel state is rebuilt — show the change immediately
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
  updateCanvasScaling();  // the RGB-subpixel look changes the backing scale
  drawGame();             // the rest is shader uniforms — redraw to show it live
  saveVideoSettings();
});

const loadVideoSettings = async () => {
  let v = await dbGet("video");
  if (v) {
    integerScale = !!v.integerScale;
    // Two migrations, oldest first: "Motion blur" on means LCD response on;
    // a stored panel name (LCD_LEGACY_ON) means on.
    if (typeof v.lcdResponse === "boolean") lcdResponse = v.lcdResponse;
    else if (typeof v.lcdResponse === "string")
      lcdResponse = LCD_LEGACY_ON.includes(v.lcdResponse);
    else lcdResponse = !!v.motionBlur;
    ambientGlow = !!v.ambientGlow;
    if (typeof v.upscaleFilter === "string") upscaleFilter = v.upscaleFilter;
    // The old scanlines toggle and "scanlines" dropdown value both land on
    // "grid"; the toggle only migrates when no smoothing filter was stored
    // (the old UI let the filter win).
    if (upscaleFilter === "scanlines") upscaleFilter = "grid";
    if (v.scanlines && upscaleFilter === "none") upscaleFilter = "grid";
  }
  integerScaleToggle.checked = integerScale;
  lcdResponseToggle.checked = lcdResponse;
  ambientGlowToggle.checked = ambientGlow;
  upscaleFilterSelect.value = upscaleFilter;
  applyLcdResponse();
  updateCanvasScaling();
};

window.addEventListener("resize", updateCanvasScaling);

// --- iOS rotation settle ---
// Rotating on iPhone can leave the touch strip's painted pixels out of sync
// with where WebKit hit-tests them: resize fires mid-rotation with stale
// numbers and the composited layer may never re-raster. Force a fresh
// layout + composite after the rotation settles (double-rAF plus a 350ms
// follow-up), nudge the strip's layer, release a mid-rotation joystick hold.
{
  let settleTimer = null;
  const settleNow = () => {
    // Phantom scroll: iOS can leave the position:fixed document scrolled by
    // a few dozen px after a rotation, and hit-testing follows the scroll
    // while fixed-position paint does not. Log it, then zero it.
    const vv = window.visualViewport;
    // Not phantom: pinch-zoom sets vv.offsetTop, and the iOS keyboard
    // scrolls the page while a field is focused.
    const zoomed = vv && vv.scale && vv.scale > 1.01;
    const typing = document.activeElement &&
      (document.activeElement.tagName === "INPUT" ||
       document.activeElement.tagName === "TEXTAREA" ||
       /** @type {HTMLElement} */ (document.activeElement).isContentEditable);
    const phantom = !zoomed && !typing && ((window.scrollY || 0) ||
      (vv ? Math.round(vv.offsetTop || vv.pageTop || 0) : 0));
    if (phantom) {
      log(`rotate-settle: phantom scroll ${window.scrollY}/${vv ? vv.offsetTop : "-"} — resetting`);
      window.scrollTo(0, 0);
      document.documentElement.scrollTop = 0;
      document.body.scrollTop = 0;
    }
    // Publish the measured app height (visualViewport.height has none of
    // 100vh's post-rotation staleness). Skip while the keyboard is up.
    if (vv && vv.height > 0 && vv.height >= window.innerHeight - 1) {
      document.documentElement.style.setProperty(
        "--app-h", Math.round(vv.height) + "px");
    }
    updateCanvasScaling();
    // Nudge the layers WebKit is most likely to have stale: the control
    // strip and the fixed body root.
    for (const el of [document.getElementById("controls"), document.body]) {
      if (!el) continue;
      void el.offsetHeight;                 // force reflow
      el.style.transform = "translateZ(0)"; // force re-composite
    }
    requestAnimationFrame(() => {
      document.body.style.transform = "";
      const c = document.getElementById("controls");
      if (c) c.style.transform = "";
    });
    if (typeof joystickForceRelease === "function") joystickForceRelease();
  };
  const scheduleSettle = () => {
    requestAnimationFrame(() => requestAnimationFrame(settleNow));
    clearTimeout(settleTimer);
    settleTimer = setTimeout(settleNow, 350); // iOS: last resize lies; re-check
  };
  window.addEventListener("orientationchange", scheduleSettle);
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", scheduleSettle);
    window.visualViewport.addEventListener("scroll", scheduleSettle);
  }
}
new ResizeObserver(updateCanvasScaling).observe(stageEl);

// WebKit applies the SDL window resize to the canvas a beat after
// initFromEmscripten returns (Chromium is synchronous); re-fit when it lands.
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

// event.code -> SDL keycode mapping.
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
  for (let i = 0; i < 26; i++) {
    m["Key" + String.fromCharCode(65 + i)] = 97 + i;
  }
  return m;
})();

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

// Presets: 10 SDL keycodes indexed by Input enum order.
const PRESET_DEFAULT = [
  0x40000052, 0x40000051, 0x40000050, 0x4000004F, // Up Down Left Right
  122, 120, 8, 13, 97, 115 // Z X Backspace Return A S
];
const PRESET_HOMEROW = [
  101, 100, 115, 102, // E D S F
  107, 106, 108, 59, 119, 114 // K J L ; W R
];

var activeBindings = [...PRESET_DEFAULT];

var codeLookup = {};
const rebuildLookup = () => {
  codeLookup = {};
  for (let i = 0; i < activeBindings.length; i++) {
    for (let [code, sdl] of Object.entries(JS_TO_SDL)) {
      if (sdl === activeBindings[i]) {
        codeLookup[code] = i;
        break;
      }
    }
  }
};
rebuildLookup();

// Rollback mode: this player's held buttons as a bitmask (bit i = input id
// i), handed to rollback_tick and shipped to the peer each frame.
var rollbackMode = false;
var localButtons = 0;
var rbWasLinked = false;  // the games have actually communicated over the link
var rbLastTransfers = 0;  // last-seen SIO transfer count (activity probe)
var rbLastActivity = 0;   // timestamp of the last transfer-count change
// Auto-end of an online link keys only off serial-cable activity
// (_rollback_transfers), never game knowledge. Two windows, both reset on
// every transfer: QUIET (lenient, before the cable has seen sustained use;
// a game can hold a link open idle for a long time) and ACTIVE (tight, once
// meaningful traffic has crossed: a linking game keeps the cable busy).
var rbLinkWasActive = false; // the cable has seen a sustained burst of traffic
const RB_IDLE_QUIET_MS  = 90000; // silence tolerated before the link is used
const RB_IDLE_ACTIVE_MS = 20000; // silence tolerated after real traffic flowed
const RB_ACTIVE_LINK_TRANSFERS = 300; // SIO transfers that mean "link in real use"
const noteLocalButton = (inputId, down) => {
  if (down) localButtons |= 1 << inputId;
  else localButtons &= ~(1 << inputId);
};

// --- Input display overlay -------------------------
// Every local input source funnels through noteInputDisplay (routeP1Input
// for keyboard/touch, pollGamepads per edge), so it cannot drift from what
// the core was told. Local only: a peer's buttons never pass here, and CSS
// hides it in 2P local link. DOM, not #canvas: clip recording is
// canvas.captureStream, so clips stay clean while a window capture picks it up.
const inputOverlay = document.getElementById("input-overlay");
const inputDisplayToggle = /** @type {HTMLInputElement} */ (document.getElementById("input-display-toggle"));
// Indexed by core input id (setInput order): 0-3 Up/Down/Left/Right, 4 A,
// 5 B, 6 Select, 7 Start, 8 L, 9 R.
const IO_CELLS = ["io-up", "io-down", "io-left", "io-right", "io-a", "io-b",
                  "io-select", "io-start", "io-l", "io-r"]
  .map((id) => document.getElementById(id));
var inputDisplay = false;
// Held buttons as a bitmask, tracked even while the overlay is off (so
// switching it on mid-hold is right, and repeat keydowns cost no DOM work).
var inputDisplayHeld = 0;

const noteInputDisplay = (inputId, down) => {
  const bit = 1 << inputId;
  if (!!down === !!(inputDisplayHeld & bit)) return;
  if (down) inputDisplayHeld |= bit;
  else inputDisplayHeld &= ~bit;
  if (inputDisplay) IO_CELLS[inputId]?.classList.toggle("io-on", !!down);
};

// Nothing may stay lit through a toggle, an unload, or a blur that
// swallowed the keyup.
const clearInputDisplay = () => {
  inputDisplayHeld = 0;
  for (const el of IO_CELLS) el?.classList.remove("io-on");
};

const applyInputDisplay = (on) => {
  inputDisplay = on;
  inputDisplayToggle.checked = on;
  // CSS decides where it may appear (styles.css).
  inputOverlay.classList.toggle("on", on);
  clearInputDisplay();
};

// The switch and the I shortcut both go through here.
const setInputDisplay = async (on) => {
  applyInputDisplay(on);
  await dbPut("input-display", on);
};

inputDisplayToggle.addEventListener("change", () =>
  setInputDisplay(inputDisplayToggle.checked));

const toggleInputDisplay = () => { setInputDisplay(!inputDisplay); };

const loadInputDisplayFromStorage = async () => {
  applyInputDisplay(!!(await dbGet("input-display")));
};

// Route P1 input: the single core, core 0 in 2P link, or localButtons in
// rollback mode.
const routeP1Input = (inputId, down) => {
  noteInputDisplay(inputId, down);
  // Tilt cart: the D-pad doubles as a tilt source (smoothed in updateTilt);
  // the real press goes through too for menus.
  if (tiltActive && inputId <= 3) {
    kbTiltDirs[inputId] = down;
    tiltTargetY = (kbTiltDirs[0] ? -TILT_KB_RANGE : 0) + (kbTiltDirs[1] ? TILT_KB_RANGE : 0);
    tiltTargetX = (kbTiltDirs[2] ? -TILT_KB_RANGE : 0) + (kbTiltDirs[3] ? TILT_KB_RANGE : 0);
  }
  if (rollbackMode) {
    noteLocalButton(inputId, down);
  } else if (linkMode) {
    // Keyboard drives the focused linked screen; a gamepad always drives P2.
    if (Module._link_input) Module._link_input(linkFocus, inputId, down ? 1 : 0);
  } else {
    Module._setInput(inputId, down ? 1 : 0);
  }
};

// Intercepts bound keys before the SDL layer and calls _setInput directly.
const gameKeyHandler = (e, down) => {
  if (settingsModal.classList.contains("open")) return;
  // Not while typing in a text field.
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
const kbPreset = /** @type {HTMLSelectElement} */ (document.getElementById("kb-preset"));

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
    btn.setAttribute("aria-label", INPUT_NAMES[i] + ": " + sdlName(activeBindings[i]));
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

const commitBindings = (bindings) => {
  applyKeybindings(bindings);
  if (db) dbPut("keybindings", activeBindings);
  kbPreset.value = detectPreset(activeBindings);
  renderKbBindings();
};

const kbKeyHandler = (e) => {
  if (kbSelection < 0) return;
  if (e.code === "Escape") {
    // Escape must never become a binding: bound keys pre-empt shortcuts, so
    // it would stop closing every modal.
    kbSelection = -1;
    renderKbBindings();
    e.preventDefault();
    e.stopImmediatePropagation();
    return;
  }
  let sdl = JS_TO_SDL[e.code];
  if (sdl === undefined) return;
  e.preventDefault();
  e.stopImmediatePropagation();
  let bindings = [...activeBindings];
  for (let i = 0; i < bindings.length; i++) {
    if (bindings[i] === sdl) bindings[i] = -1;
  }
  bindings[kbSelection] = sdl;
  // No auto-advance: a stray keystroke must not rebind the next button.
  kbSelection = -1;
  commitBindings(bindings);
};

const loadKeybindingsFromStorage = async () => {
  let stored = await dbGet("keybindings");
  if (stored && stored.length === INPUT_NAMES.length) {
    // Heal profiles saved before Escape became unbindable.
    applyKeybindings(stored.map((k) => (k === 27 ? -1 : k)));
  }
};

// --- Large on-screen controls ---
const largeControlsToggle = /** @type {HTMLInputElement} */ (document.getElementById("large-controls-toggle"));

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

// --- Opaque controls in landscape ---
const opaqueControlsToggle = /** @type {HTMLInputElement} */ (document.getElementById("opaque-controls-toggle"));

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

// --- Hide touch controls while a game controller is connected ---
// pollGamepads maintains body.gamepad-hides-touch; the CSS gate only bites
// in the touch layout.
const hideTouchOnGamepadToggle = /** @type {HTMLInputElement} */ (document.getElementById("hide-touch-on-gamepad-toggle"));
var hideTouchOnGamepad = true;

const applyHideTouchOnGamepad = (on) => {
  hideTouchOnGamepad = on;
  hideTouchOnGamepadToggle.checked = on;
  if (!on) document.body.classList.remove("gamepad-hides-touch");
};

hideTouchOnGamepadToggle.addEventListener("change", async () => {
  applyHideTouchOnGamepad(hideTouchOnGamepadToggle.checked);
  await dbPut("hide-touch-on-gamepad", hideTouchOnGamepadToggle.checked);
});

const loadHideTouchOnGamepadFromStorage = async () => {
  const v = await dbGet("hide-touch-on-gamepad");
  applyHideTouchOnGamepad(typeof v === "boolean" ? v : true);
};

// --- Touch direction input: d-pad vs joystick ---
// "control-style" ("dpad" | "joystick") and "joystick-mode" ("fixed" |
// "floating"); body.joystick-controls swaps the d-pad for the joystick.
let controlStyle = "dpad";
let joystickMode = "fixed";
const controlStyleChips = Array.from(/** @type {NodeListOf<HTMLElement>} */ (
  document.querySelectorAll("#control-style-picker .choice-chip")));
const joystickModeChips = Array.from(/** @type {NodeListOf<HTMLElement>} */ (
  document.querySelectorAll("#joystick-mode-picker .choice-chip")));
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
  // Swapping styles mid-touch must not leave direction bits stuck down.
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

// --- Run-ahead (opt-in) ---
// 0 = off: plain loop_tick, zero cost. N > 0 swaps in runahead_tick(N)
// (docs/run-ahead.md). Not during fast-forward/2x, never in the link modes.
let runaheadFrames = 0;
const runaheadSelect = /** @type {HTMLSelectElement} */ (
  document.getElementById("runahead-select"));

const applyRunahead = (n) => {
  runaheadFrames = [0, 1, 2, 3].includes(n) ? n : 0;
  runaheadSelect.value = String(runaheadFrames);
};

runaheadSelect.addEventListener("change", async () => {
  applyRunahead(Number(runaheadSelect.value));
  await dbPut("runahead", runaheadFrames);
});

const loadRunaheadFromStorage = async () => {
  const v = await dbGet("runahead");
  applyRunahead(typeof v === "number" ? v : 0);
};

// --- Game Boy shade palette ---------------------------------------------
// Recolours a monochrome game's four shades in the glpresent.js fragment
// shader, never in the core. One setting with a mode: "default" (the core's
// shades), "theme" (GB_THEME_PALETTES), "custom" (four picked colours).

// DMG_COLORS from src/dingbat/gb/gb.nim, expanded 5->8 bits: the only four
// values a monochrome framebuffer holds, which makes the shader's
// substitution exact. Also the seed for a custom palette (raw hardware
// values, so slightly more saturated than "default", which adds the panel
// colour model).
const GB_HW_SHADES = ["#fff7d6", "#ffad73", "#ef6b6b", "#7b3a5a"];

// One four-shade ramp per app theme, lightest to darkest. Rules (pinned by
// web/tests/gb-palette.test.mjs): the theme's main colour appears verbatim;
// themes with several distinct colours spend them (dmg, famicom); the rest
// fill with tints ending on --bg; monotonically darkening with no two steps
// closer than ~1.5:1 contrast; no two adjacent steps more than ~45 CIEDE2000
// apart, since games dither shades 1 and 2 against each other and a hue
// gap shimmers instead of blending (dmg's pea-green against magenta was 74).
const GB_THEME_PALETTES = {
  // Amber phosphor on near-black.
  amber:           ["#fff0d6", "#ffb04d", "#8f5312", "#1a1206"],
  // Same amber ink, darkest shade the theme's #000.
  black:           ["#fff0d6", "#ffb04d", "#7a4a0f", "#000000"],
  // Paper white -> gold -> the burnt-amber accent -> the text ink.
  light:           ["#f3f4f8", "#d88a1f", "#9c5400", "#1d2433"],
  // Blue-violet accent verbatim, then a darkened shell purple, then --bg.
  indigo:          ["#cdc7f0", "#7f6ae7", "#55497f", "#0d0b17"],
  // Dusty rose accent verbatim; shade 2 is the shell rose darkened.
  fuchsia:         ["#f0ccd8", "#e8739a", "#7e4560", "#170a0f"],
  // Periwinkle accent verbatim; shade 2 is the shell grey-blue darkened.
  glacier:         ["#ccd9f0", "#769be5", "#3c4a6b", "#0b0e16"],
  // Kiwi shell green verbatim; shade 0 must be very pale to separate from it.
  kiwi:            ["#effbea", "#6ee126", "#2d7a1f", "#0c170b"],
  // Four distinct DMG colours: LCD, shell grey, magenta A/B, d-pad black.
  // The pea-green --accent is deliberately absent (the CIEDE2000 rule).
  dmg:             ["#eaf3de", "#b4aca9", "#6f6a6d", "#262828"],
  // Orchid accent verbatim; shade 2 is the shell violet darkened.
  "atomic-purple": ["#e7cbf0", "#c36ee7", "#6a3d80", "#120b16"],
  // Burnt-orange accent verbatim; shade 2 is the shell orange darkened.
  daiei:           ["#f2d2b0", "#eb7c33", "#8c3d18", "#160f0b"],
  // Four distinct Famicom colours: cream faceplate, gold chrome, garnet A/B
  // ring, charcoal buttons.
  famicom:         ["#e6d9bf", "#b99c68", "#b44148", "#25272b"],
};

var gbPaletteMode = "default";              // "default" | "theme" | "custom"
var gbPaletteCustom = GB_HW_SHADES.slice(); // the four user-picked colours

const gbPaletteSelect = /** @type {HTMLSelectElement} */ (document.getElementById("gb-palette-mode"));
const gbPaletteCustomRow = document.getElementById("gb-palette-custom-row");
const gbPalettePreview = document.getElementById("gb-palette-preview");
const gbPaletteResetBtn = document.getElementById("gb-palette-reset");
const gbPaletteInputs = [0, 1, 2, 3].map((i) =>
  /** @type {HTMLInputElement} */ (document.getElementById("gb-palette-shade-" + i)));

// Read off <html data-theme>, not localStorage, so this never disagrees
// with the chrome on screen (Reset all settings changes the theme without
// writing it back).
const currentThemeName = () => {
  const n = document.documentElement.getAttribute("data-theme") || "amber";
  return GB_THEME_PALETTES[n] ? n : "amber";
};

// The four shades in force, or null (the "default" mode, and every
// non-monochrome game whatever the mode).
const gbPaletteColors = () => {
  if (gbPaletteMode === "theme") return GB_THEME_PALETTES[currentThemeName()];
  if (gbPaletteMode === "custom") return gbPaletteCustom;
  return null;
};

const gbPaletteSgbNote = document.getElementById("gb-palette-sgb-note");

const syncGbPaletteUI = () => {
  if (gbPaletteSelect) gbPaletteSelect.value = gbPaletteMode;
  if (gbPaletteCustomRow) gbPaletteCustomRow.hidden = gbPaletteMode !== "custom";
  // Under SGB colour the shader has nothing to substitute: disabled with a reason.
  const sgb = sgbActive();
  if (gbPaletteSelect) gbPaletteSelect.disabled = sgb;
  if (gbPaletteSgbNote) gbPaletteSgbNote.hidden = !sgb;
  for (const r of document.querySelectorAll(".gb-palette-row"))
    r.classList.toggle("row-disabled", sgb);
  for (let i = 0; i < 4; i++) {
    if (gbPaletteInputs[i]) gbPaletteInputs[i].value = gbPaletteCustom[i];
  }
  if (gbPalettePreview) {
    const shades = gbPaletteColors() || GB_HW_SHADES;
    gbPalettePreview.replaceChildren(...shades.map((c) => {
      const chip = document.createElement("span");
      chip.className = "gb-shade-chip";
      chip.style.setProperty("background", c);
      chip.title = c;
      return chip;
    }));
  }
};

const applyGbPalette = () => {
  syncGbPaletteUI();
  // Repaint even if paused.
  presentDirty = true;
  if (typeof drawGame === "function") drawGame();
};

const saveGbPalette = () => {
  if (db) dbPut("gb-palette", { mode: gbPaletteMode, custom: gbPaletteCustom.slice() });
};

const HEX6 = /^#[0-9a-f]{6}$/i;

const loadGbPalette = async () => {
  const v = await dbGet("gb-palette");
  if (v && typeof v === "object") {
    if (v.mode === "theme" || v.mode === "custom" || v.mode === "default") {
      gbPaletteMode = v.mode;
    }
    if (Array.isArray(v.custom) && v.custom.length === 4 &&
        v.custom.every((c) => typeof c === "string" && HEX6.test(c))) {
      gbPaletteCustom = v.custom.map((c) => c.toLowerCase());
    }
  }
  applyGbPalette();
};

// Reset this setting only.
const resetGbPalette = () => {
  gbPaletteMode = "default";
  gbPaletteCustom = GB_HW_SHADES.slice();
  applyGbPalette();
  saveGbPalette();
};

if (gbPaletteSelect) {
  gbPaletteSelect.addEventListener("change", () => {
    const v = gbPaletteSelect.value;
    gbPaletteMode = (v === "theme" || v === "custom") ? v : "default";
    applyGbPalette();
    saveGbPalette();
  });
}

gbPaletteInputs.forEach((input, i) => {
  if (!input) return;
  input.addEventListener("input", () => {
    if (!HEX6.test(input.value)) return;
    gbPaletteCustom[i] = input.value.toLowerCase();
    applyGbPalette();
    saveGbPalette();
  });
});

if (gbPaletteResetBtn) gbPaletteResetBtn.addEventListener("click", resetGbPalette);

// --- Chrome theme ---
// Persisted in localStorage, not IndexedDB, so the inline <head> script can
// apply it before first paint. "amber" = no data-theme attribute.
const THEME_KEY = "dingbat_theme";
const THEME_NAMES = ["amber", "black", "light", "dmg", "kiwi", "atomic-purple",
  "indigo", "fuchsia", "glacier", "daiei", "famicom"];
// "emerald" was renamed "kiwi"; migrate the persisted value.
const migrateTheme = (name) => (name === "emerald" ? "kiwi" : name);
const themeChips = Array.from(/** @type {NodeListOf<HTMLElement>} */ (document.querySelectorAll("#theme-picker .theme-chip")));
// iOS fills the standalone safe areas from this; browser tabs tint their chrome.
const themeColorMeta = /** @type {HTMLMetaElement} */ (document.querySelector('meta[name="theme-color"]'));

const applyTheme = (name) => {
  name = migrateTheme(name);
  if (!THEME_NAMES.includes(name)) name = "amber";
  if (name === "amber") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", name);
  for (const chip of themeChips) {
    const on = chip.dataset.themeName === name;
    chip.classList.toggle("selected", on);
    chip.setAttribute("aria-checked", on ? "true" : "false");
  }
  // Match --bg so the bottom strip blends in; derived from the live token
  // (the boot-script map is only a pre-CSS hint).
  if (themeColorMeta) {
    const cs = getComputedStyle(document.documentElement);
    themeColorMeta.content =
      (cs.getPropertyValue("--bg").trim() ||
       cs.getPropertyValue("--topbar-top").trim());
  }
  // "Match the app theme" is derived, not stored: re-derive and repaint.
  applyGbPalette();
};

themeChips.forEach((chip) =>
  chip.addEventListener("click", () => {
    applyTheme(chip.dataset.themeName);
    try { localStorage.setItem(THEME_KEY, chip.dataset.themeName); } catch (e) {}
  })
);

// Sync the picker + theme-color meta with what the boot script applied.
{
  let storedTheme = "amber";
  try { storedTheme = localStorage.getItem(THEME_KEY) || "amber"; } catch (e) {}
  const migrated = migrateTheme(storedTheme);
  if (migrated !== storedTheme) {
    try { localStorage.setItem(THEME_KEY, migrated); } catch (e) {}
  }
  applyTheme(migrated);
}

// --- Reset all settings ---
// Wipes only the settings keys, then restores every in-memory default and
// re-runs each subsystem's apply. No reload.
const SETTINGS_KEYS = [
  "system", "audio", "colorCorrect", "video",
  "keybindings", "large-controls", "opaque-controls",
  "control-style", "joystick-mode", "hide-touch-on-gamepad",
  "runahead", "gb-palette", "input-display",
];

const resetAllSettings = async () => {
  for (const k of SETTINGS_KEYS) await dbDelete(k);
  try { localStorage.removeItem(UPDATE_CHECK_KEY); } catch (e) {}

  // System (GB renderer / GBA BIOS mode + intro / rumble)
  gbFifo = true; gbaBiosMode = 0; gbaRunBios = true; gbRumble = true;
  rewindOn = true;
  speedMode = false;
  syncSystemSettingsUI();   // also re-applies the rewind-off body class
  applySystemSettings();

  // Audio (volume / mute / pitch-correct fast-forward)
  volume = 100; muted = false;
  syncVolumeUI();
  if (typeof updateGain === "function") updateGain();
  pitchCorrectFF = false;
  if (pcffToggle) pcffToggle.checked = false;
  applyPitchCorrectFF();
  mp2kHle = false;
  if (mp2kHleToggle) mp2kHleToggle.checked = false;
  applyMp2kHle();
  fifoInterp = true;
  if (fifoInterpToggle) fifoInterpToggle.checked = true;
  applyFifoInterp();
  audioLowpass = false;   // (was previously missed by reset)
  if (lowpassToggle) lowpassToggle.checked = false;
  applyAudioLowpass();

  // Color correction
  colorCorrect = true;
  ccToggle.checked = colorCorrect;
  applyColorCorrect();

  // Video effects
  integerScale = false; lcdResponse = false; ambientGlow = false;
  upscaleFilter = "none";
  integerScaleToggle.checked = false;
  lcdResponseToggle.checked = false;
  ambientGlowToggle.checked = false;
  upscaleFilterSelect.value = "none";
  glowFresh = true;
  applyLcdResponse();
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
  applyInputDisplay(false);

  // Run-ahead -> off
  applyRunahead(0);

  // Game Boy shade palette -> default, custom colours back to hardware.
  gbPaletteMode = "default";
  gbPaletteCustom = GB_HW_SHADES.slice();
  applyGbPalette();

  // Super Game Boy -> defaults, pushed into the core.
  sgbEnable = false;
  sgbBorder = true;
  applySystemSettings();
  syncSystemSettingsUI();

  // Chrome theme -> Amber (localStorage).
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
      // Persistent button: re-enable and disarm it for reuse.
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
var slowMotion = false;
var rewindHeld = false;
var lastRewindPop = 0;
// Tilt cart: gamepad stick / D-pad / device orientation feed a smoothed
// tilt vector to wasm_set_tilt each RAF tick.
var tiltActive = false;
var tiltTargetX = 0, tiltTargetY = 0;   // where input wants the tilt to be
var tiltX = 0, tiltY = 0;               // smoothed value actually sent
var tiltOrientationOn = false;          // device-orientation stream attached
var tiltNeutral = null;                 // neutral hold pose, in SCREEN space
var padTiltLive = false;                // gamepad stick currently owns the target
var kbTiltDirs = [false, false, false, false]; // held U/D/L/R while tilting
var tiltKind = 0;                       // 1 = accelerometer cart, 2 = gyro cart

// --- Screen Wake Lock ---
// Held while emulation is stepping, released on pause. The browser drops
// it when the tab is hidden, so syncWakeLock() re-acquires on return.
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
        // A pause/hide may have raced in while the request was pending.
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
        // request() rejects on low battery or a hidden document.
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

// Performance/memory telemetry for the on-page log (iOS wasm JIT demotion
// under memory pressure). _benchFrames advances the live core by n frames,
// so it runs only right after initFromEmscripten, never in the link modes;
// the 5-minute interval logs heap size only.
const wasmHeapBytes = () =>
  (Module.HEAPU8?.buffer || Module.memory?.buffer)?.byteLength || 0;

// Pure-JS spin: slow here too = the whole CPU is throttled; normal while
// the wasm bench is slow = JIT demotion.
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
    // Drop the ~1s of audio the benched frames queued.
    if (Module._clearAudioBuffer) Module._clearAudioBuffer();
    const mb = Math.round(wasmHeapBytes() / (1024 * 1024));
    log(
      `bench (${label}): 60 frames in ${ms.toFixed(0)}ms, ` +
        `js ${jsBench().toFixed(0)}ms, heap ${mb}MB`
    );
  } catch {}
};

// Average rAF interval: ~33ms means the display loop is halved (iOS Low
// Power Mode).
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

const loadRom = async (romName, originalName, opts = {}) => {
  // A capture spanning a ROM switch would splice two games.
  if (typeof abortRetroClip === "function") abortRetroClip();
  if (typeof stopClipRecording === "function") stopClipRecording();
  if (linkMode) await exitLinkMode();
  if (typeof netShutdown === "function" && netMode) await netShutdown();
  if (currentRomName && currentOriginalName) {
    await persistSave(currentRomName, currentOriginalName);
  }
  currentRomName = romName;
  currentOriginalName = originalName || romName;
  // Before `paused` is reset: closing a scrubber restores the paused state
  // it captured, which must land on the old session's value.
  closeRewindScrubber();
  closeClipScrubber();
  paused = false;
  document.body.classList.remove("paused");
  fastForward = false;
  speed2x = false;  // a fresh core starts with turbo off
  slowMotion = false; // and the wasm-side sample stretch off (module global)
  if (typeof Module !== "undefined" && Module._wasm_set_slowmo) Module._wasm_set_slowmo(0);
  slowMotionItem.classList.remove("active");
  slowMotionItem.setAttribute("aria-pressed", "false");
  rewindHeld = false;
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  fastForwardButton.classList.remove("active");
  speed2xButton.classList.remove("active");
  rewindButton.classList.remove("active");
  // body.gb-mode drops the L/R row.
  document.body.classList.toggle("gb-mode", systemOf(romName) !== "GBA");
  document.body.classList.add("has-game", "running");
  await restoreSave(romName, currentOriginalName);
  Module.ccall("initFromEmscripten", null, ["string"], [romName]);
  await restoreCheats();  // fresh core: re-apply this game's saved cheats
  applyPitchCorrectFF();  // fresh core: re-push the local audio preference
  applyMp2kHle();         // (covers loadAudioSettings racing Module init)
  detectTiltCart();       // MBC7/Yoshi: enable tilt input routing for this cart
  detectCameraCart();     // Pocket Camera: offer the real webcam
  detectMonoPanel(romName); // DMG (4-shade) vs colour screen — palette gate
  applyGbPalette();       // fresh core: push the shade palette (or drop it)
  stateUndoBytes = null;  // undo buffer belongs to the previous game
  rwUndoBytes = null;     // ...as does the rewind-commit undo
  benchReport("load");
  updateCanvasScaling();
  // The reset button opts out: it shows its own Undo toast.
  if (!opts.skipResumeOffer) offerAutoResume();
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

// --- Minimal ZIP reader (central directory + DecompressionStream deflate-raw) ---

const unzip = async (arrayBuffer) => {
  const view = new DataView(arrayBuffer);
  const bytes = new Uint8Array(arrayBuffer);
  const len = arrayBuffer.byteLength;

  // End Of Central Directory: the comment is at most 64 KB.
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

// --- ROM header sanity check ---
// Any-signal-matches (homebrew is often raw objcopy output with no logo and
// an unfixed checksum), and a failed check only asks, never blocks:
//   .gba     byte 3 is 0xEA (ARM branch entry), OR the Nintendo logo at
//            0x004, OR the header checksum at 0xBD (GBATEK).
//   .gb/.gbc the Nintendo logo at 0x104, OR the header checksum at 0x14D
//            (Pan Docs); rgbfix fixes the checksum on logo-less homebrew.
// An 8-byte prefix of each logo is checked.
const GBA_LOGO_PREFIX = [0x24, 0xff, 0xae, 0x51, 0x69, 0x9a, 0xa2, 0x21];
const GB_LOGO_PREFIX = [0xce, 0xed, 0x66, 0x66, 0xcc, 0x0d, 0x00, 0x0b];
const bytesMatchAt = (bytes, offset, ref) =>
  ref.every((b, i) => bytes[offset + i] === b);

const looksLikeValidRom = (bytes, ext) => {
  if (ext === ".gba") {
    if (bytes.length >= 4 && bytes[3] === 0xea) return true; // ARM branch entry
    if (bytes.length < 0xc0) return false; // no full header to check
    if (bytesMatchAt(bytes, 0x004, GBA_LOGO_PREFIX)) return true;
    let sum = 0;
    for (let i = 0xa0; i <= 0xbc; i++) sum += bytes[i];
    return bytes[0xbd] === (-(sum + 0x19) & 0xff);
  }
  // .gb / .gbc
  if (bytes.length < 0x150) return false;
  if (bytesMatchAt(bytes, 0x104, GB_LOGO_PREFIX)) return true;
  let chk = 0;
  for (let i = 0x134; i <= 0x14c; i++) chk = (chk - bytes[i] - 1) & 0xff;
  return bytes[0x14d] === chk;
};

// Ask before loading a file that failed the check; false drops the file.
const romWarnModal = document.getElementById("rom-warn-modal");
let romWarnResolve = null;

const settleRomWarn = (proceed) => {
  let resolve = romWarnResolve;
  romWarnResolve = null; // closeRomWarnModal must not double-resolve
  romWarnModal.classList.remove("open");
  releaseFocus(romWarnModal);
  if (resolve) resolve(proceed);
};

const closeRomWarnModal = () => {
  if (romWarnResolve) settleRomWarn(false);
};

const confirmSuspectRom = (fileName, ext) =>
  new Promise((resolve) => {
    let system = ext === ".gba" ? "GBA" : ext === ".gbc" ? "Game Boy Color" : "Game Boy";
    document.getElementById("rom-warn-text").textContent =
      `"${fileName}" doesn't look like a valid ${system} ROM — it may be ` +
      `corrupt or not a game at all. Load it anyway?`;
    romWarnResolve = resolve;
    romWarnModal.classList.add("open");
    trapFocus(romWarnModal);
  });

document.getElementById("rom-warn-load").addEventListener("click", () => settleRomWarn(true));
document.getElementById("rom-warn-cancel").addEventListener("click", closeRomWarnModal);
document.getElementById("rom-warn-close").addEventListener("click", closeRomWarnModal);
romWarnModal.addEventListener("click", (e) => {
  if (e.target === romWarnModal) closeRomWarnModal();
});

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
  // The largest embedded image is almost always the box art.
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
  let innerExt = extOf(innerName);
  if (!looksLikeValidRom(romBytes, innerExt) &&
      !(await confirmSuspectRom(innerName, innerExt))) return;
  let romFile = "rom" + innerExt;
  await ensureRuntimeReady(); // a zip dropped before the wasm runtime is up
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
    let bytes = new Uint8Array(/** @type {ArrayBuffer} */ (reader.result));
    if (!looksLikeValidRom(bytes, ext) &&
        !(await confirmSuspectRom(file.name, ext))) return;
    await ensureRuntimeReady(); // a ROM picked/dropped before the runtime is up
    writeToFS(romName, bytes);
    await addRecentRom(file.name, bytes);
    loadRom(romName, file.name);
  });
  reader.readAsArrayBuffer(file);
};

// A dropped save (.sav/.srm or a GameShark container) or .state is imported
// into the running single-player game; anything else is a ROM/zip to load.
const SAVE_IMPORT_EXTS = new Set([".sav", ".srm", ".sps", ".xps", ".gsv"]);
const handleDroppedFile = (file) => {
  let ext = extOf(file.name);
  if (SAVE_IMPORT_EXTS.has(ext) || ext === ".state") {
    let kind = ext === ".state" ? "save state" : "save file";
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
      let bytes = new Uint8Array(/** @type {ArrayBuffer} */ (reader.result));
      if (ext === ".state") applyImportedState(bytes);
      else applyImportedSave(bytes, file.name);
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
  // iOS Safari greys out .gba/.gb/.gbc as soon as a known type like .zip is
  // listed, so the accept filter is desktop-only.
  if (!IS_IOS) input.accept = ROM_EXTS.join(",") + ",.zip";
  input.addEventListener("input", () => {
    if (input.files?.length > 0) handleRomFile(input.files[0]);
  });
  input.click();
};

// Mobile "Load a game" button (no drag-and-drop on touch).
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

const togglePause = (fromRemote) => {
  paused = !paused;
  pauseButton.classList.toggle("paused", paused);
  pauseButton.classList.toggle("active", paused);
  pauseButton.title = paused ? "Resume" : "Pause";
  document.body.classList.toggle("paused", paused);
  // Linked online, pause freezes both sides (a one-sided pause stalls the
  // peer at the prediction limit); relay unless it came from them.
  if (!fromRemote && rollbackMode && typeof window.rbSendPause === "function") {
    window.rbSendPause(paused);
  }
};
// The peer paused/resumed: match without echoing back.
window.applyRemotePause = (on) => {
  if (paused !== on) togglePause(true);
};

// iOS suppresses the synthesized click for a second finger while the first
// is held on the touch controls, so Pause runs from pointerup; the click
// listener (programmatic callers, keyboards) sits behind a short lockout.
var pausePointerTs = 0;
{
  let armed = false; // require the press to START on the button: a finger
                     // dragged across it must not toggle on release
  pauseButton.addEventListener("pointerdown", (e) => {
    if (e.button === 0 || e.pointerType !== "mouse") armed = true;
  });
  for (const ev of ["pointerleave", "pointercancel"]) {
    pauseButton.addEventListener(ev, () => { armed = false; });
  }
  pauseButton.addEventListener("pointerup", (e) => {
    if (!armed) return;
    armed = false;
    e.preventDefault();
    pausePointerTs = performance.now();
    togglePause();
  });
}
pauseButton.addEventListener("click", () => {
  if (performance.now() - pausePointerTs < 350) return;
  togglePause();
});

resetButton.addEventListener("click", async () => {
  if (linkMode && linkRomEntry) {
    launchLinkRom(linkRomEntry);
    return;
  }
  if (!currentRomName) return;
  // Snapshot the state being thrown away and offer it on a toast; the
  // auto-resume offer is suppressed for this reload.
  const undo = captureStateBytes();
  const name = currentOriginalName;
  await loadRom(currentRomName, currentOriginalName, { skipResumeOffer: true });
  if (undo) {
    stateUndoBytes = undo; // fresh core: re-arm the buffer loadRom cleared
    stateUndoName = name;
    showActionToast("Game reset", "Undo", () => {
      if (currentOriginalName !== name) return; // switched games since
      if (applyStateBytes(undo)) showToast("Back to before the reset");
    });
  }
});

// 2x and unbounded fast forward are radio-style (fast forward ignores pacing).
const setSpeed2x = (on, fromRemote) => {
  speed2x = on;
  speed2xButton.classList.toggle("active", on);
  if (on && slowMotion) setSlowMotion(false);
  if (typeof Module !== "undefined" && Module._wasm_set_turbo) {
    Module._wasm_set_turbo(on ? 1 : 0);
  }
  // Re-push pitch-correct alongside turbo: rollback_init builds fresh cores
  // that never saw it (pinned by web/tests/pitch-correct-2x.test.mjs).
  applyPitchCorrectFF();
  // Linked online, 2x must drive both cores: relay unless it came from the peer.
  if (!fromRemote && rollbackMode && typeof window.rbSendSpeed === "function") {
    window.rbSendSpeed(on);
  }
};
// The peer toggled 2x: apply without echoing back.
window.applyRemoteSpeed2x = (on) => setSpeed2x(on, true);
const setFastForward = (on) => {
  fastForward = on;
  fastForwardButton.classList.toggle("active", on);
  if (on) setSlowMotion(false);
};

// Slow motion (0.5x): the tick loop doubles the wall-clock step and the
// wasm shim fills the sample gap (doubled samples, or WSOLA 1:2 under
// pitch-correct). Radio-exclusive with FF/2x.
const slowMotionItem = document.getElementById("slow-motion");
const setSlowMotion = (on) => {
  if (slowMotion === on) return; // no toast spam from the radio-clear paths
  slowMotion = on;
  if (typeof Module !== "undefined" && Module._wasm_set_slowmo) {
    Module._wasm_set_slowmo(on ? 1 : 0);
  }
  slowMotionItem.classList.toggle("active", on);
  slowMotionItem.setAttribute("aria-pressed", on ? "true" : "false");
  if (on) {
    setFastForward(false);
    setSpeed2x(false);
  }
  showToast(on ? "Slow motion on (0.5x)" : "Slow motion off");
};

// The three speed flags collapse to one value; momentary keys snapshot it
// on press and restore it on release.
const currentSpeedMode = () =>
  fastForward ? "ffw" : speed2x ? "2x" : slowMotion ? "slow" : "normal";
// The setters clear each other, so the wanted one goes last.
const applySpeedMode = (mode) => {
  if (mode !== "slow") setSlowMotion(false);
  setFastForward(mode === "ffw");
  setSpeed2x(mode === "2x");
  if (mode === "slow") setSlowMotion(true);
};

slowMotionItem.addEventListener("click", () => {
  menuDropdown.hidden = true;
  if (!currentRomName || !speedControlsOk()) return;
  setSlowMotion(!slowMotion);
});

fastForwardButton.addEventListener("click", () => {
  setFastForward(!fastForward);
  if (fastForward) setSpeed2x(false);
});

// 2x: the core drops every other audio sample while the tick loop halves
// its time step.
speed2xButton.addEventListener("click", () => {
  setSpeed2x(!speed2x);
  if (speed2x) setFastForward(false);
});

// Frame advance while paused; the frame's audio sliver is discarded.
const frameAdvance = () => {
  if (typeof Module === "undefined" || !Module._loop_tick) return;
  if (!paused || !currentRomName || !speedControlsOk()) return;
  Module._loop_tick();
  if (Module._clearAudioBuffer) Module._clearAudioBuffer();
  drawGame();
};

// --- Retroactive clip capture ---
// The wasm side keeps one state anchor per second plus a per-frame input
// log (clip_* in dingbat_wasm.nim). clip_begin rewinds to the anchor before
// the range and re-emulates to its first frame; clip_tick then replays at
// realtime while a MediaRecorder captures the canvas and the audio tap.
var clipReplayActive = false;
var clipRecorder = null;
var clipChunks = [];
const clipLastItem = document.getElementById("clip-last");

const clipMimeType = () => {
  if (typeof MediaRecorder === "undefined") return null;
  for (const m of ["video/webm;codecs=vp9,opus", "video/webm",
                   "video/mp4;codecs=avc1.64001F,mp4a.40.2", "video/mp4"]) {
    if (MediaRecorder.isTypeSupported(m)) return m;
  }
  return null;
};

const finishRetroClip = (save) => {
  clipReplayActive = false;
  document.body.classList.remove("clip-replaying");
  clipBanner.hidden = true;
  if (clipRecorder && clipRecorder.state !== "inactive") {
    if (save) clipRecorder.stop(); // onstop saves the blob
    else { clipRecorder.ondataavailable = null; clipRecorder.onstop = null;
           clipRecorder.stop(); clipChunks = []; clipRecorder = null;
           if (typeof window.releaseClipAudio === "function") window.releaseClipAudio(); }
  }
};

const abortRetroClip = () => {
  if (!clipReplayActive) return;
  if (typeof Module !== "undefined" && Module._clip_abort) Module._clip_abort();
  finishRetroClip(false);
};

var clipTotalFrames = 0;
var clipBannerLabel = "";
const clipBanner = document.getElementById("clip-banner");
const updateClipBanner = (left) => {
  const pct = clipTotalFrames > 0
    ? Math.min(100, Math.round(100 * (clipTotalFrames - left) / clipTotalFrames)) : 0;
  clipBanner.textContent = `${clipBannerLabel}… ${pct}%`;
};

/**
 * Replay [startAgo, endAgo), both in frames before now, into a video file.
 * @param {number} startAgo
 * @param {number} endAgo
 * @param {string} slug   filename infix, e.g. "last10s"
 * @param {string} label  banner wording, e.g. "Capturing the last 10s"
 * @returns {boolean} true once the replay is armed and recording
 */
const startClipExport = (startAgo, endAgo, slug, label) => {
  if (clipReplayActive || !currentRomName || !speedControlsOk()) return false;
  const mime = clipMimeType();
  if (!mime) { showToast("Video recording isn't supported in this browser"); return false; }
  const frames = Module._clip_begin ? Module._clip_begin(startAgo, endAgo) : 0;
  if (frames <= 0) { showToast("Not enough gameplay history yet"); return false; }
  // The framebuffer now holds the clip's first frame: push it to the canvas
  // before captureStream attaches, or the recorder opens on the live moment.
  drawGame();
  let stream;
  try {
    stream = canvasEl.captureStream(60);
  } catch {
    Module._clip_abort();
    showToast("Couldn't capture the game canvas");
    return false;
  }
  const audio = typeof window.acquireClipAudio === "function"
    ? window.acquireClipAudio() : null;
  if (audio) for (const t of audio.getAudioTracks()) stream.addTrack(t);
  clipChunks = [];
  try {
    clipRecorder = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: 8_000_000 });
  } catch {
    Module._clip_abort();
    if (typeof window.releaseClipAudio === "function") window.releaseClipAudio();
    showToast("Couldn't start the recorder");
    return false;
  }
  clipRecorder.ondataavailable = (e) => { if (e.data && e.data.size) clipChunks.push(e.data); };
  clipRecorder.onstop = () => {
    if (typeof window.releaseClipAudio === "function") window.releaseClipAudio();
    const blob = new Blob(clipChunks, { type: clipRecorder.mimeType });
    clipRecorder = null;
    clipChunks = [];
    if (!blob.size) { showToast("The clip came out empty"); return; }
    const ext = blob.type.includes("mp4") ? "mp4" : "webm";
    const base = (currentOriginalName || "dingbat").replace(/\.[^.]+$/, "");
    const stamp = new Date().toISOString().slice(0, 19).replace(/[T:]/g, "-");
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `${base}-${slug}-${stamp}.${ext}`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
    showToast("Clip saved");
  };
  clipRecorder.start(500);
  clipReplayActive = true;
  clipTotalFrames = frames;
  clipBannerLabel = label;
  document.body.classList.add("clip-replaying");
  clipBanner.hidden = false;
  updateClipBanner(frames);
  paused = false; // the replay must run even if the game was paused
  return true;
};

// The last ten seconds, ending now.
const CLIP_QUICK_SECONDS = 10;

// --- Clip range picker -----------------------------------------------------
// The same export with an in/out point, on createFilmStrip with two markers.
// Thumbnails come from the clip ring, not the rewind ring, which can be off.

const clipModal = document.getElementById("clip-modal");
const clipStripCanvas =
  /** @type {HTMLCanvasElement} */ (document.getElementById("clip-strip"));
const clipStripWrap = document.getElementById("clip-strip-wrap");
const clipPreviewCanvas =
  /** @type {HTMLCanvasElement} */ (document.getElementById("clip-preview"));
const clipWhen = document.getElementById("clip-when");
const clipOldest = document.getElementById("clip-oldest");
const clipEstimate = document.getElementById("clip-estimate");
const clipScrubHint = document.getElementById("clip-scrub-hint");
const clipPreviewLabel = document.getElementById("clip-preview-label");
const clipStartSlider =
  /** @type {HTMLInputElement} */ (document.getElementById("clip-slider-start"));
const clipEndSlider =
  /** @type {HTMLInputElement} */ (document.getElementById("clip-slider-end"));
const clipRangeWrap = document.getElementById("clip-range");
const clipRangeFill = document.getElementById("clip-range-fill");
const clipSaveBtn =
  /** @type {HTMLButtonElement} */ (document.getElementById("clip-save"));

// Same budget as the rewind strip; the clip ring stores one per second.
const CLIP_MAX_SAMPLES = 96;

let clipAgo = [];             // frames-ago of each strip sample, newest first
let clipWasPaused = false;
let clipActiveMarker = 0;     // which marker the preview is showing

// Markers in samples back from newest: [0] the in point (first frame kept,
// line on its left), [1] the out point (last kept, line on its right).
const clipStrip = createFilmStrip({
  canvas: clipStripCanvas,
  wrap: clipStripWrap,
  // Twice the rewind strip's span, and the default selection must fit: the
  // quick range is one pitch wider than its seconds (brackets sit on the
  // end frames' outer edges), else the "now" bracket opens off a phone wrap.
  visibleFrames: 11,
  frameWMin: 26,
  frameWMax: 40,
  fitFrames: CLIP_QUICK_SECONDS + 1,
  markers: [
    { el: document.getElementById("clip-marker-start"), edge: "lead" },
    { el: document.getElementById("clip-marker-end"), edge: "trail" },
  ],
  paint: (ctx, g) => clipStrip.shadeBetween(ctx, g, g.xs[0], g.xs[1]),
  onChange: (i) => {
    // The strip follows its active marker; a knob or preset move must adopt
    // the marker it moved or nudge something off-screen.
    clipSetActive(i);
    clipRefresh();
  },
});

// The preview and the strip follow the same marker: the last one acted on.
const clipSetActive = (i) => {
  clipActiveMarker = i;
  clipStrip.setActive(i);
};
// Blocking, not pushing: a marker driven into its neighbour pins one frame
// short. One rule for the strip, the knobs and the presets.
const clipBoundsFor = (i) =>
  i === 0 ? { min: clipStrip.at(1) + 1 } : { max: clipStrip.at(0) - 1 };
clipStrip.attach(clipBoundsFor);

// Frames-ago of a marker. Sample 0 is the newest anchor, up to a second
// old; as the out point it means "now".
const clipAgoAt = (sample, isOut) => {
  if (isOut && sample <= 0) return 0;
  return clipAgo[Math.min(Math.max(sample, 0), clipAgo.length - 1)] || 0;
};

const clipRangeFrames = () => {
  const start = clipAgoAt(clipStrip.at(0), false);
  const end = clipAgoAt(clipStrip.at(1), true);
  return { start, end, len: Math.max(0, start - end) };
};

// --- The range slider: one track, two knobs --------------------------------
// Two <input type="range"> on one rail (.dual-range): each knob keeps its
// tab stop, arrow keys, Home/End and announceable value. Not a second source
// of truth: every move goes through clipStrip.setValue and clipRefresh
// writes them back from the strip.
const clipKnobs = [clipStartSlider, clipEndSlider];

// Must match .dual-range-rail's inset in styles.css.
const CLIP_KNOB_W = 22;

// Knob i as a fraction of its travel; start is the left knob. With no
// history both sit at the left and the span is empty.
const clipKnobPct = (i) => {
  const max = Number(clipKnobs[i].max) || 0;
  return max > 0 ? Number(clipKnobs[i].value) / max : 0;
};

// Travel a knob has left away from its neighbour.
const clipKnobRoom = (i) => {
  const max = Number(clipKnobs[i].max) || 0;
  return i === 0 ? Number(clipKnobs[i].value) : max - Number(clipKnobs[i].value);
};

const clipTrackGeom = () => {
  const rect = clipRangeWrap.getBoundingClientRect();
  return { left: rect.left + CLIP_KNOB_W / 2,
           span: Math.max(1, rect.width - CLIP_KNOB_W) };
};

// The highlighted span (in % of the rail, i.e. of the knobs' travel) and
// which knob is on top.
const clipPaintTrack = () => {
  clipRangeFill.style.left = clipKnobPct(0) * 100 + "%";
  clipRangeFill.style.right = 100 - clipKnobPct(1) * 100 + "%";
  // Stacking order is presentation only; clipGrabKnob decides by distance.
  clipKnobs.forEach((el, i) => el.classList.toggle("on-top", i === clipActiveMarker));
};

// aria-valuetext in words: a lone "s" is read as a letter.
const clipSpokenAgo = (frames) => {
  if (frames <= 0) return "now";
  const s = Math.max(1, Math.round(frames / 60));
  if (s < 60) return s + (s === 1 ? " second ago" : " seconds ago");
  const m = Math.floor(s / 60);
  const r = s - m * 60;
  return m + (m === 1 ? " minute" : " minutes") +
         (r ? " " + r + (r === 1 ? " second" : " seconds") : "") + " ago";
};

const clipRefresh = () => {
  const { start, end, len } = clipRangeFrames();
  const tenths = (f) => Math.round((f * 10) / 60);
  clipWhen.textContent =
    end === 0
      ? "the last " + fmtDuration(tenths(len))
      : fmtDuration(tenths(start)) + " to " + fmtDuration(tenths(end)) +
        " ago · " + fmtDuration(tenths(len));
  const startSlot = String(clipStrip.samples - 1 - clipStrip.at(0));
  const endSlot = String(clipStrip.samples - 1 - clipStrip.at(1));
  if (clipStartSlider.value !== startSlot) clipStartSlider.value = startSlot;
  if (clipEndSlider.value !== endSlot) clipEndSlider.value = endSlot;
  clipStartSlider.setAttribute("aria-valuetext", clipSpokenAgo(start));
  clipEndSlider.setAttribute("aria-valuetext", clipSpokenAgo(end));
  clipPaintTrack();
  clipStrip.draw();
  clipStrip.preview(clipPreviewCanvas, clipStrip.at(clipActiveMarker));
  clipPreviewLabel.textContent =
    clipActiveMarker === 0 ? "first frame of the clip" : "last frame of the clip";
  // A minute of 8 Mbit/s video is ~60 MB, straight into downloads.
  const seconds = len / 60;
  clipEstimate.textContent =
    len > 0
      ? `${seconds.toFixed(1)}s of video, roughly ${Math.max(1, Math.round(seconds))} MB. ` +
        "The clip is re-played at normal speed while it records, so it takes that long."
      : "";
  clipSaveBtn.disabled = len <= 0;
};

// Move marker i to the slot knob i asks for; keyboard and pointer both land here.
const clipKnobMove = (i, slot) => {
  // Claim the marker first so the strip follows it.
  clipSetActive(i);
  // Redraw either way: a move clamped against the other knob must snap the
  // input back.
  if (!clipStrip.setValue(i, clipStrip.samples - 1 - slot, true, clipBoundsFor(i)))
    clipRefresh();
};
clipKnobs.forEach((el, i) =>
  el.addEventListener("input", () => clipKnobMove(i, Number(el.value))));

// The track handles pointer input (the inputs are pointer-events: none):
// with stacked inputs the top one would swallow every press where they
// overlap. Routed by distance, the film strip's own rule.
const clipGrabKnob = (clientX) => {
  const { left, span } = clipTrackGeom();
  const px = clientX - left;
  const d = clipKnobs.map((_, i) => Math.abs(clipKnobPct(i) * span - px));
  // A dead heat takes the knob with somewhere to go, so a pinned pair can
  // be pulled apart.
  if (d[0] === d[1]) return clipKnobRoom(0) >= clipKnobRoom(1) ? 0 : 1;
  return d[0] < d[1] ? 0 : 1;
};

const clipTrackSlot = (clientX) => {
  const { left, span } = clipTrackGeom();
  return Math.round(((clientX - left) / span) * (Number(clipKnobs[0].max) || 0));
};

let clipDragKnob = -1;
clipRangeWrap.addEventListener("pointerdown", (e) => {
  if (clipStrip.samples <= 0) return;
  e.preventDefault();
  clipDragKnob = clipGrabKnob(e.clientX);
  clipRangeWrap.setPointerCapture?.(e.pointerId);
  // The inputs take no pointer events, so move focus by hand.
  clipKnobs[clipDragKnob].focus();
  clipKnobMove(clipDragKnob, clipTrackSlot(e.clientX));
});
clipRangeWrap.addEventListener("pointermove", (e) => {
  if (clipDragKnob >= 0) clipKnobMove(clipDragKnob, clipTrackSlot(e.clientX));
});
// Named: an inline listener under a `string` event name is typed as a bare
// Event and `e.pointerId` fails the typecheck.
const clipEndKnobDrag = (e) => {
  if (clipDragKnob < 0) return;
  if (clipRangeWrap.hasPointerCapture?.(e.pointerId))
    clipRangeWrap.releasePointerCapture(e.pointerId);
  clipDragKnob = -1;
};
for (const ev of ["pointerup", "pointercancel", "pointerleave"]) {
  clipRangeWrap.addEventListener(ev, clipEndKnobDrag);
}

// The sample closest to `seconds` back (searched: one sample is only one
// second while the ring holds fewer anchors than the strip shows).
const clipNearestSample = (seconds) => {
  if (clipAgo.length === 0) return 0;
  if (seconds <= 0) return clipAgo.length - 1;   // "everything"
  const want = seconds * 60;
  let best = 0;
  for (let i = 1; i < clipAgo.length; i++) {
    if (Math.abs(clipAgo[i] - want) < Math.abs(clipAgo[best] - want)) best = i;
  }
  return best;
};

// Presets set the in point and pin the out point to now.
const clipSetPreset = (seconds) => {
  if (clipStrip.samples <= 0) return;
  clipStrip.setValue(1, 0, true);
  clipStrip.setValue(0, Math.max(1, clipNearestSample(seconds)), true, { min: 1 });
  clipSetActive(0);
  clipRefresh();
};
document.getElementById("clip-preset-10").addEventListener("click", () => clipSetPreset(10));
document.getElementById("clip-preset-30").addEventListener("click", () => clipSetPreset(30));
document.getElementById("clip-preset-all").addEventListener("click", () => clipSetPreset(0));

const openClipScrubber = () => {
  menuDropdown.hidden = true;
  if (!currentRomName || !speedControlsOk()) return;
  // A build missing the scrub API from EXPORTED_FUNCTIONS: say so (this
  // guard once shipped silent; see web/tests/wasm-exports.test.mjs).
  if (typeof Module === "undefined" || !Module._clip_scrub_generate) {
    console.error("clip: the scrub API is missing from this build " +
                  "(check EXPORTED_FUNCTIONS in src/dingbat_wasm.nims)");
    showToast("Clips aren't available in this build");
    return;
  }
  if (clipReplayActive) return;
  clipWasPaused = paused;
  // Freeze the core so the anchors cannot age out from under the markers.
  paused = true;
  clipStrip.release();
  clipAgo = [];
  const n = Module._clip_scrub_generate(CLIP_MAX_SAMPLES);
  if (n > 0) {
    const w = Module._clip_scrub_thumb_w();
    const h = Module._clip_scrub_thumb_h();
    const ptr = Module._clip_scrub_thumbs_ptr();
    clipStrip.load(new Uint8Array(Module.memory.buffer, ptr, n * w * h * 2).slice(), w, h, n);
    for (let i = 0; i < n; i++) clipAgo.push(Module._clip_scrub_frames_ago(i));
  }
  // Open on the quick action's range.
  clipStrip.values[1] = 0;
  clipStrip.values[0] = Math.max(1, Math.min(n - 1, clipNearestSample(CLIP_QUICK_SECONDS)));
  clipSetActive(0);
  const slotMax = String(Math.max(0, n - 1));
  for (const el of clipKnobs) el.max = slotMax;
  clipScrubHint.textContent =
    n > 1
      ? "Drag either marker, or either knob on the slider. " +
        "Everything between them is saved."
      : "No gameplay history yet — it builds up as you play.";
  clipOldest.textContent =
    n > 1 ? fmtDuration(Math.round((clipAgo[n - 1] * 10) / 60)) + " ago" : "";
  clipModal.classList.add("open");
  trapFocus(clipModal);
  // After .open, so the strip has a laid-out height.
  clipStrip.build();
  clipRefresh();
};

const closeClipScrubber = () => {
  // The global Escape handler calls every closer blindly; a stale
  // clipWasPaused would unpause a game paused later.
  if (!clipModal.classList.contains("open")) return;
  clipModal.classList.remove("open");
  releaseFocus(clipModal);
  clipStrip.release();
  paused = clipWasPaused;
};

clipSaveBtn.addEventListener("click", () => {
  const { start, end, len } = clipRangeFrames();
  if (len <= 0) return;
  const seconds = Math.max(1, Math.round(len / 60));
  closeClipScrubber();
  startClipExport(start, end, `clip${seconds}s`,
                  end === 0 ? `Capturing the last ${seconds}s`
                            : `Capturing ${seconds}s of gameplay`);
});

document.getElementById("clip-scrub-close").addEventListener("click", closeClipScrubber);
document.getElementById("clip-scrub-cancel").addEventListener("click", closeClipScrubber);
clipModal.addEventListener("click", (e) => {
  if (e.target === clipModal) closeClipScrubber();
});
clipLastItem.addEventListener("click", openClipScrubber);

// As the rewind strip: the bitmaps are rasterised for one breakpoint.
window.addEventListener("resize", () => {
  if (!clipModal.classList.contains("open")) return;
  clipStrip.build();
  clipRefresh();
});

// Frame-step: tap = one frame, hold repeats at 10/s. Pointer events, not
// click: iOS won't synthesize click for a second finger while a game
// button is held.
// --- Forward clip recording ---
// MediaRecorder over the canvas plus the audio tap; .webm (.mp4 on Safari).
var recRecorder = null;
var recChunks = [];
var recStopTimer = null;
const recordClipItem = document.getElementById("record-clip");
const REC_MAX_MS = 5 * 60 * 1000; // a forgotten recorder stops itself

const setRecMenuState = (recording) => {
  recordClipItem.querySelector("span").textContent =
    recording ? "Stop Recording" : "Record";
  recordClipItem.classList.toggle("recording", recording);
};

const stopClipRecording = () => {
  if (recRecorder && recRecorder.state !== "inactive") recRecorder.stop();
};

const startClipRecording = () => {
  if (recRecorder || clipReplayActive || !currentRomName) return;
  const mime = clipMimeType();
  if (!mime) { showToast("Video recording isn't supported in this browser"); return; }
  let stream;
  try {
    stream = canvasEl.captureStream(60);
  } catch {
    showToast("Couldn't capture the game canvas");
    return;
  }
  const audio = typeof window.acquireClipAudio === "function"
    ? window.acquireClipAudio() : null;
  if (audio) for (const t of audio.getAudioTracks()) stream.addTrack(t);
  recChunks = [];
  try {
    recRecorder = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: 8_000_000 });
  } catch {
    if (typeof window.releaseClipAudio === "function") window.releaseClipAudio();
    showToast("Couldn't start the recorder");
    return;
  }
  recRecorder.ondataavailable = (e) => { if (e.data && e.data.size) recChunks.push(e.data); };
  recRecorder.onstop = () => {
    if (typeof window.releaseClipAudio === "function") window.releaseClipAudio();
    clearTimeout(recStopTimer);
    const blob = new Blob(recChunks, { type: recRecorder.mimeType });
    recRecorder = null;
    recChunks = [];
    setRecMenuState(false);
    if (!blob.size) { showToast("The recording came out empty"); return; }
    const ext = blob.type.includes("mp4") ? "mp4" : "webm";
    const base = (currentOriginalName || "dingbat").replace(/\.[^.]+$/, "");
    const stamp = new Date().toISOString().slice(0, 19).replace(/[T:]/g, "-");
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `${base}-clip-${stamp}.${ext}`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
    showToast("Clip saved");
  };
  recRecorder.start(1000);
  recStopTimer = setTimeout(stopClipRecording, REC_MAX_MS);
  setRecMenuState(true);
  showToast("Recording — pick Stop Recording to finish");
};

recordClipItem.addEventListener("click", () => {
  menuDropdown.hidden = true;
  if (recRecorder) stopClipRecording();
  else startClipRecording();
});

// Capture accordion.
const captureToggle = document.getElementById("capture-toggle");
const captureSub = document.getElementById("capture-sub");
const collapseCaptureSub = () => {
  captureSub.hidden = true;
  captureToggle.setAttribute("aria-expanded", "false");
};
captureToggle.addEventListener("click", (e) => {
  // The document click handler would close the dropdown.
  e.stopPropagation();
  captureSub.hidden = !captureSub.hidden;
  captureToggle.setAttribute("aria-expanded", captureSub.hidden ? "false" : "true");
});

const frameStepButton = document.getElementById("frame-step");
{
  let holdTimer = null;
  let repeatTimer = null;
  let repeated = false;
  let stepPointerTs = 0;
  const stopHold = () => {
    clearTimeout(holdTimer);
    clearInterval(repeatTimer);
    holdTimer = repeatTimer = null;
  };
  let armed = false;
  frameStepButton.addEventListener("pointerdown", (e) => {
    if (e.pointerType === "mouse" && e.button !== 0) return;
    armed = true;
    stopHold();
    repeated = false;
    holdTimer = setTimeout(() => {
      repeated = true;
      repeatTimer = setInterval(frameAdvance, 100);
    }, 400);
  });
  frameStepButton.addEventListener("pointerup", (e) => {
    if (!armed) return; // press began elsewhere (drag-across release)
    armed = false;
    e.preventDefault();
    stepPointerTs = performance.now();
    const tap = !repeated;
    stopHold();
    if (tap) frameAdvance(); // a hold already stepped via the repeater
  });
  for (const ev of ["pointerleave", "pointercancel"]) {
    frameStepButton.addEventListener(ev, () => { armed = false; stopHold(); });
  }
  // Programmatic .click().
  frameStepButton.addEventListener("click", () => {
    if (performance.now() - stepPointerTs < 350) return;
    frameAdvance();
  });
}

// Hold-to-rewind. Gated here for every caller: with rewind off there is no
// ring to pop. Only turning it on is refused.
const setRewindHeld = (on) => {
  rewindHeld = on && rewindOn;
  rewindButton.classList.toggle("active", rewindHeld);
};

// pointerdown rewinds instantly; nothing waits to see whether a second
// press is coming. The film strip is a double tap recognised after the
// fact (the first tap's fraction of a second of rewind stands); a press
// held longer than a tap never counts towards it. Pointer events, not
// `dblclick`: the preventDefault() this button needs suppresses the
// compatibility mouse-event family (WebKit fires neither click nor
// dblclick here). body { touch-action: none } means no double-tap-to-zoom
// and no 300 ms click delay, so the windows below are the gesture's own.
const RW_TAP_MAX_MS = 250;    // a press longer than this is a hold, never a tap
const RW_DBLTAP_MS = 300;     // from the first tap's release to the second's press
const RW_DBLTAP_SLOP = 28;    // px a press may travel, and the two taps may differ by
{
  // One pointer owns the hold; a second finger neither re-arms, counts as a
  // tap, nor stops the rewind on release.
  let holdId = null;
  let downTs = 0;
  let downX = 0;
  let downY = 0;
  let tapTs = 0;              // when the previous qualifying tap was released
  let tapX = 0;
  let tapY = 0;

  const near = (ax, ay, bx, by, slop) =>
    Math.abs(ax - bx) <= slop && Math.abs(ay - by) <= slop;

  rewindButton.addEventListener("pointerdown", (e) => {
    if (e.pointerType === "mouse" && e.button !== 0) return;
    e.preventDefault();
    if (holdId !== null) return;
    holdId = e.pointerId;
    downTs = performance.now();
    downX = e.clientX || 0;
    downY = e.clientY || 0;
    setRewindHeld(true);      // first statement that matters, and it is not gated
  });

  // Only pointerup can complete a tap; pointerleave/pointercancel just end
  // the hold.
  const endPress = (e) => {
    if (holdId === null || (e.pointerId !== undefined && e.pointerId !== holdId)) return;
    holdId = null;
    setRewindHeld(false);
    if (e.type !== "pointerup") return;
    const x = e.clientX || 0;
    const y = e.clientY || 0;
    const now = performance.now();
    // A tap: short, and ended where it started.
    if (now - downTs > RW_TAP_MAX_MS || !near(x, y, downX, downY, RW_DBLTAP_SLOP)) {
      tapTs = 0;
      return;
    }
    // The window runs from the first tap's release to this one's press.
    if (tapTs && downTs - tapTs <= RW_DBLTAP_MS && near(x, y, tapX, tapY, RW_DBLTAP_SLOP)) {
      tapTs = 0;              // a third tap starts a fresh pair, not another open
      openRewindScrubber();
      return;
    }
    tapTs = now;
    tapX = x;
    tapY = y;
  };
  for (const ev of ["pointerup", "pointerleave", "pointercancel"]) {
    rewindButton.addEventListener(ev, endPress);
  }
}

// --- Desktop keyboard shortcuts ---
// As the native app (src/dingbat.nim): Tab holds fast-forward, Shift+Tab
// toggles 2x, backquote holds rewind. Registered after gameKeyHandler, which
// consumes bound game keys with stopImmediatePropagation.

const saveStateItem = document.getElementById("save-state");
const loadStateItem = document.getElementById("load-state");

const anyModalOpen = () => !!document.querySelector(".modal-overlay.open");
// netplay.js loads after index.js, so netMode may not exist yet.
const netActive = () => typeof netMode !== "undefined" && !!netMode;
// The shortcuts follow the linked modes' control gating; 2x stays available
// in rollback mode (relayed to the peer).
const speedControlsOk = () => !linkMode && !rollbackMode && !netActive();

// Holds the keyboard owns, so a lost keyup releases them without touching
// a button-initiated hold.
var kbFastForward = false;
var kbRewindHeld = false;
// The speed latched when the fast-forward key went down; release restores it.
var kbSpeedBeforeHold = "normal";
const endKbFastForward = () => {
  if (!kbFastForward) return;
  kbFastForward = false;
  // Something else claimed the speed while the key was down: leave it.
  if (!fastForward) return;
  applySpeedMode(kbSpeedBeforeHold);
};
const releaseKbHolds = () => {
  endKbFastForward();
  // A blur eats the keyup, so every lit cell would stick on.
  clearInputDisplay();
  if (kbRewindHeld) {
    kbRewindHeld = false;
    setRewindHeld(false);
  }
};
window.addEventListener("blur", releaseKbHolds);

const shortcutKeyHandler = (e, down) => {
  // A capture replay owns the machine: no state loads, speed changes or
  // pauses (game keys still pass as the post-replay held state).
  if (typeof clipReplayActive !== "undefined" && clipReplayActive) return;
  if (codeLookup[e.code] !== undefined) return; // game bindings always win
  if (e.ctrlKey || e.metaKey || e.altKey) return; // browser/OS chords

  // Releases skip the modal/typing guards so a hold cannot stick.
  if (!down) {
    if ((e.code === "Tab" && kbFastForward) ||
        (e.code === "Backquote" && kbRewindHeld)) {
      if (e.code === "Tab") {
        endKbFastForward();
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
  // Not while typing in a text field.
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
      // (Tab with focus in the chrome never reaches this handler.)
      if (e.shiftKey) {
        if (linkMode || netActive()) break;
        if (!e.repeat) {
          setSpeed2x(!speed2x);
          if (speed2x) setFastForward(false);
        }
        handled = true;
      } else {
        // Hold for fast-forward, restoring the previous speed on release;
        // holding the key for the speed already in force restores to 1x.
        if (!speedControlsOk()) break;
        if (!kbFastForward) {
          kbFastForward = true;
          kbSpeedBeforeHold = fastForward ? "normal" : currentSpeedMode();
          setFastForward(true);
          setSpeed2x(false);
        }
        handled = true;
      }
      break;
    case "Backquote":
      if (!gameLoaded || !speedControlsOk()) break;
      if (e.shiftKey) {
        if (!e.repeat) setSlowMotion(!slowMotion);
        handled = true;
        break;
      }
      // With rewind off the key is not ours.
      if (!rewindOn) break;
      if (!kbRewindHeld) {
        kbRewindHeld = true;
        setRewindHeld(true);
      }
      handled = true;
      break;
    case "Period":
      // Frame advance: first press pauses, further presses step one frame.
      // Single-core only.
      if (e.shiftKey || !currentRomName || !speedControlsOk()) break;
      if (!paused) {
        if (!e.repeat) pauseButton.click();
      } else {
        frameAdvance();
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
    case "KeyI": // input display on/off (free in both keyboard presets; a
      // custom binding still wins via the codeLookup guard at the top)
      if (e.shiftKey) break;
      if (!e.repeat) toggleInputDisplay();
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
// Two cores of the same ROM over the emulated cable, lockstep, on their own
// 2D canvases. Keyboard/touch drive P1, a gamepad P2. Each player has its
// own battery save: the ROM is written to two FS paths, core 2's .sav
// persisted under "save:<name>-p2".

var linkMode = false;
// { name, data } for the live 2P session; released on exitLinkMode so no
// ROM bytes outlive the session.
var linkRomEntry = null;
var linkIsGb = false;    // true while the linked pair is GB/GBC (160x144)
var linkFocus = 0;       // which core the keyboard drives (click a screen to switch)

// Point the keyboard at player `p`; clear held buttons first so none stick.
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

// Two FS paths so each core derives its own .sav; the extension picks GB vs GBA.
let LINK_FS_ROMS = ["linkrom1.gba", "linkrom2.gba"];
const LINK_FS_SAVS = ["linkrom1.sav", "linkrom2.sav"];
const linkSaveKey = (name, player) =>
  "save:" + (player === 0 ? name : name + "-p2");

const linkDims = () => (linkIsGb ? [160, 144] : [240, 160]);

let linkCtx = [null, null];
let linkImg = [null, null];

const initLinkCanvases = () => {
  const [w, h] = linkDims();
  for (let p = 0; p < 2; p++) {
    let c = /** @type {HTMLCanvasElement} */ (document.getElementById("link-canvas-" + p));
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
    // Fresh heap view each blit: memory growth detaches buffers.
    linkImg[p].data.set(new Uint8Array(Module.memory.buffer, ptr, w * h * 4));
    linkCtx[p].putImageData(linkImg[p], 0, 0);
  }
};

// Online rollback shows only this player's core, on link-canvas-0.
const blitRollbackCanvas = () => {
  if (!linkCtx[0] || !Module._rollback_fb_ptr) return;
  let ptr = Module._rollback_fb_ptr();
  if (!ptr) return;
  const [w, h] = linkDims();
  linkImg[0].data.set(new Uint8Array(Module.memory.buffer, ptr, w * h * 4));
  linkCtx[0].putImageData(linkImg[0], 0, 0);
};

// Debug: `dumpLinkStates()` from the console downloads both cores' states.
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

// Enter/leave rollback mode (called by netplay.js).
window.enterRollbackMode = () => {
  // Always (re)init: the session's system (linkIsGb) may differ from before.
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
  // openNetConnect froze the game and lit the pause button; clear it.
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  document.body.classList.toggle("link-gb", linkIsGb);
  document.body.classList.add("has-game", "running", "rollback-mode");
  if (typeof window.setNetConnectLabel === "function") window.setNetConnectLabel(true);
  updateCanvasScaling();
};
// JS-side flags only; the wasm side is netplay's rbTeardown.
window.leaveRollbackMode = () => {
  if (!rollbackMode) return;
  rollbackMode = false;
  localButtons = 0;
  document.body.classList.remove("rollback-mode", "link-gb");
  if (typeof window.setNetConnectLabel === "function") window.setNetConnectLabel(false);
  updateCanvasScaling();
};

// Persist both players' battery saves.
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
  // Same runtime gate as launchRom.
  await ensureRuntimeReady();
  if (linkMode) {
    await exitLinkMode();
  } else if (currentRomName && currentOriginalName) {
    await persistSave(currentRomName, currentOriginalName);
  }
  // The FS extension makes link_init pick the GB or GBA path.
  const ext = extOf(rom.name) === ".gba" ? ".gba" : extOf(rom.name) || ".gb";
  linkIsGb = ext !== ".gba";
  LINK_FS_ROMS = ["linkrom1" + ext, "linkrom2" + ext];
  document.body.classList.toggle("link-gb", linkIsGb);
  writeToFS(LINK_FS_ROMS[0], rom.data);
  writeToFS(LINK_FS_ROMS[1], rom.data);
  // P2 starts from a copy of P1's save the first time (trading needs two
  // playable saves).
  for (let sav of LINK_FS_SAVS) {
    try { FS.unlink(sav); } catch {}
  }
  let s1 = await dbGet(linkSaveKey(rom.name, 0));
  let s2 = await dbGet(linkSaveKey(rom.name, 1));
  if (!s2 && s1) s2 = s1;
  if (s1) writeToFS(LINK_FS_SAVS[0], s1);
  if (s2) writeToFS(LINK_FS_SAVS[1], s2);
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

// --- Main Menu ---

const showMainMenu = () => {
  menuDropdown.hidden = true;
  if (!currentRomName && !linkMode) return;
  stopClipRecording(); // don't keep recording a frozen frame from the menu
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

// --- Paused-game card ---
// Pixels come from the wasm framebuffer: the canvas is a WebGL context
// without preserveDrawingBuffer, so reading it after pausing yields nothing.
const homePausedCard = document.getElementById("home-paused");
const homePausedCanvas = /** @type {HTMLCanvasElement} */ (document.getElementById("home-paused-canvas"));
const homePausedName = document.getElementById("home-paused-name");

const updatePausedCard = () => {
  homePausedCard.hidden = true;
  // Single-core only: the link modes render to their own canvases.
  if (!currentRomName || linkMode || rollbackMode || netActive()) return;
  if (typeof Module === "undefined" || !Module._wasm_fb_ptr) return;
  const ptr = Module._wasm_fb_ptr();
  if (!ptr) return;
  const [w, h] = gameRes(); // GBA 240x160, GB/GBC 160x144
  const heap = new Uint8Array(Module.memory.buffer, ptr, w * h * 4);
  homePausedCanvas.width = w;
  homePausedCanvas.height = h;
  const ctx = homePausedCanvas.getContext("2d");
  const img = ctx.createImageData(w, h);
  img.data.set(heap);
  // The wasm fb's alpha is not meaningful; force opaque.
  for (let i = 3; i < img.data.length; i += 4) img.data[i] = 255;
  ctx.putImageData(img, 0, 0);
  homePausedName.textContent = displayName(currentOriginalName);
  homePausedName.title = currentOriginalName;
  homePausedCard.hidden = false;
};

document.getElementById("home-paused-shot").addEventListener("click", resumeGame);

// Close the paused game: flush its save once, detach it from every later
// flush path. The core stays frozen in wasm memory until the next loadRom
// re-inits over it. False when there is nothing to unload or a link session is up.
const unloadGame = async ({ flushSave = true } = {}) => {
  if (!currentRomName || linkMode || rollbackMode || netActive()) return false;
  const romName = currentRomName;
  const originalName = currentOriginalName;
  // Detach first: once null, no flush path can re-persist this game's save.
  currentRomName = null;
  currentOriginalName = null;
  if (flushSave) await persistSave(romName, originalName);
  // Drop the FS .sav so a later load cannot pick up stale battery data.
  try { FS.unlink(stripExt(romName) + ".sav"); } catch {}
  // The cheat list belongs to the game that left; restoreCheats refills it.
  cheatList = [];
  renderCheatList();
  paused = true; // keep the orphaned core frozen
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  document.body.classList.remove("has-game", "running", "paused", "gb-mode");
  clearInputDisplay();   // no cart, no held buttons
  // No cart, no sensor: drop the camera and its button.
  stopWebcam();
  camNoticeShown = null;
  homePausedCard.hidden = true;
  refreshHomeRecent();
  updateCanvasScaling();
  return true;
};

document.getElementById("home-paused-close").addEventListener("click", async () => {
  if (await unloadGame()) showToast("Game closed — save kept");
});

// --- Screenshot ---
// No preserveDrawingBuffer: pixels are only valid within the render task,
// so captureCanvas() runs from the main loop right after a frame is drawn.
let pendingShot = false;

const captureCanvas = () => {
  pendingShot = false;
  /** @type {HTMLCanvasElement} */ (document.getElementById("canvas")).toBlob((blob) => {
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
    // Paused: draw one frame, then grab it in the same task.
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
  // iOS Safari cannot fullscreen arbitrary elements.
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
document.getElementById("topbar-handle").addEventListener("click", () => {
  document.body.classList.toggle("topbar-open");
});

// --- Gamepad support (polled each frame) ---

// Input IDs: 0 Up, 1 Down, 2 Left, 3 Right, 4 A, 5 B, 6 Select, 7 Start, 8 L, 9 R
const gpPrev = new Array(10).fill(false);
const GP_DEADZONE = 0.4;

// Gamepad inside Settings: shoulders cycle sections, d-pad walks controls,
// A activates, B goes back. Everything is consumed; nothing reaches the game.
const settingsGamepadNav = (want) => {
  const hit = (i) => want[i] && !gpPrev[i];
  if (hit(8)) selectSettingsTab(settingsStep(settingsSection, -1)); // L
  if (hit(9)) selectSettingsTab(settingsStep(settingsSection, 1));  // R
  if (hit(5)) {                                                     // B
    if (settingsOnDetail) showSettingsList();
    else closeSettingsModal();
    return;
  }
  if (hit(4)) {                                                     // A
    const el = /** @type {HTMLElement} */ (document.activeElement);
    if (el && settingsModal.contains(el) && el.click) el.click();
  }
  if (hit(0) || hit(1)) {                                           // d-pad
    const items = modalFocusables(settingsModal);
    if (!items.length) return;
    const d = hit(1) ? 1 : -1;
    let i = items.indexOf(document.activeElement);
    if (i < 0) i = d > 0 ? -1 : 0;
    items[(i + d + items.length) % items.length].focus();
  }
};

const pollGamepads = () => {
  const settingsOpen = settingsModal.classList.contains("open");
  if (!settingsOpen && (typeof Module === "undefined" || !Module._setInput)) return;
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
    // Tilt cart: the left stick is the accelerometer; claims the target only
    // while deflected.
    if (tiltActive && !settingsOpen) {
      if (Math.abs(ax) > 0.1 || Math.abs(ay) > 0.1) {
        padTiltLive = true;
        tiltTargetX = ax;
        tiltTargetY = ay;
      } else if (padTiltLive) {
        padTiltLive = false;
        tiltTargetX = 0;
        tiltTargetY = 0;
      }
    }
  }
  document.body.classList.toggle(
    "gamepad-hides-touch", hideTouchOnGamepad && anyConnected);
  if (!anyConnected) return;
  if (settingsOpen) {
    settingsGamepadNav(want);
    // A button held across the close must not arrive as a fresh press.
    for (let i = 0; i < 10; i++) gpPrev[i] = want[i];
    return;
  }
  for (let i = 0; i < 10; i++) {
    if (want[i] !== gpPrev[i]) {
      // The gamepad does not pass through routeP1Input, so it notifies the
      // overlay itself; not in 2P link, where it is the other console's.
      if (!linkMode) noteInputDisplay(i, want[i]);
      // 2P link: player 2's controller; rollback: this player's.
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

// --- Tilt cart input ---
// Gamepad stick, D-pad and device orientation feed a shared target, eased
// toward each RAF tick. iOS requires the motion permission from a user
// gesture: the offer toast's tap is the gesture.
const TILT_KB_RANGE = 0.65;   // full keyboard deflection (playable, not violent)
const TILT_SMOOTHING = 0.18;  // per-tick ease factor toward the target
const TILT_ORIENT_RANGE = 25; // degrees of physical tilt = full deflection

const detectTiltCart = () => {
  tiltKind =
    typeof Module !== "undefined" && Module._wasm_cart_has_tilt
      ? Module._wasm_cart_has_tilt() : 0; // 1 = accelerometer, 2 = gyro rate
  tiltActive = tiltKind > 0;
  tiltTargetX = tiltTargetY = tiltX = tiltY = 0;
  kbTiltDirs = [false, false, false, false];
  tiltNeutral = null; tiltGlideUntil = Date.now() + TILT_GLIDE_MS;
  tiltCartBtnUpdate();
  if (tiltActive && !maybeOfferOrientationTilt()) {
    showToast("Tilt cart detected — D-pad or stick tilts the game");
  }
};

// Jolt channel: a flick is an out-of-range acceleration transient that
// orientation alone underreports; devicemotion's linear acceleration rides
// on top and decays fast.
var tiltJoltX = 0, tiltJoltY = 0;

const updateTilt = () => {
  if (!tiltActive || typeof Module === "undefined" || !Module._wasm_set_tilt) return;
  if (tiltOrientationOn) {
    if (Date.now() < tiltGlideUntil) {
      // Glide across a discontinuity we introduced (recenter, re-baseline):
      // the cart derives acceleration from the sensor value, so a step is a
      // flick. Only the step is smoothed.
      tiltX += (tiltTargetX - tiltX) * TILT_GLIDE_RATE;
      tiltY += (tiltTargetY - tiltY) * TILT_GLIDE_RATE;
    } else {
      // Real sensor: raw, or the flick transient is low-passed away.
      tiltX = tiltTargetX;
      tiltY = tiltTargetY;
    }
  } else {
    tiltX += (tiltTargetX - tiltX) * TILT_SMOOTHING;
    tiltY += (tiltTargetY - tiltY) * TILT_SMOOTHING;
  }
  const clamp3 = (v) => Math.max(-3, Math.min(3, v)); // flicks may exceed 1g;
  // the MBC7 latch (center 0x81D0, 0x70/g) has headroom to +/-3g
  // Negated at this single send point: the ball rolls into the tilt. GBATEK
  // notes the sensor axes mirror between form factors; the sign is empirical.
  Module._wasm_set_tilt(clamp3(-(tiltX + tiltJoltX)), clamp3(-(tiltY + tiltJoltY)));
  tiltJoltX *= 0.55;
  tiltJoltY *= 0.55;
};

const motionJoltHandler = (e) => {
  if (!tiltActive) return;
  if (tiltKind === 2) {
    // Gyro cart: rotation rate around the screen normal; 180 deg/s = extreme.
    const rr = e.rotationRate;
    if (rr && rr.alpha != null) {
      tiltTargetX = Math.max(-1, Math.min(1, rr.alpha / 180));
    }
    return;
  }
  // Detect the turn from rotationRate.alpha (live during the turn), not
  // orientationchange (too late: the acceleration already reached the
  // core). Integrated signed: a flick twists and twists back, netting near
  // zero, while a turn is ~90 degrees one way.
  const rr = e.rotationRate;
  const now = Date.now();
  const dt = tiltSpinAt ? Math.min(0.2, (now - tiltSpinAt) / 1000) : 0;
  tiltSpinAt = now;
  if (rr && rr.alpha != null && dt > 0) {
    tiltSpin = tiltSpin * Math.exp(-dt / TILT_SPIN_HALFLIFE) + rr.alpha * dt;
    if (Math.abs(tiltSpin) > TILT_SPIN_DEGREES) tiltRotateUntil = now + TILT_SETTLE_MS;
  }
  if (!e.acceleration) return;
  if (tiltSettling()) { tiltJoltX = tiltJoltY = 0; return; } // turning != flick
  const ax = e.acceleration.x, ay = e.acceleration.y;
  if (ax == null || ay == null) return;
  // Linear acceleration in g, rotated into screen space. Below ~0.4g is
  // hand tremor.
  const [gx, gy] = toScreenFrame(ax / 9.81, ay / 9.81);
  if (Math.abs(gx) > 0.4) tiltJoltX = Math.max(-3, Math.min(3, gx * 1.5));
  if (Math.abs(gy) > 0.4) tiltJoltY = Math.max(-3, Math.min(3, gy * 1.5));
};

// beta/gamma and devicemotion are against the device's natural orientation;
// rotate into screen space or landscape play maps left/right to pitch.
const screenAngle = () => {
  const so = screen.orientation;
  if (so && typeof so.angle === "number") return ((so.angle % 360) + 360) % 360;
  // Legacy iOS (pre-16.4): window.orientation is the negative of the
  // standard angle.
  const w = typeof window.orientation === "number" ? -window.orientation : 0;
  return ((w % 360) + 360) % 360;
};

const toScreenFrame = (x, y) => {
  const rad = (screenAngle() * Math.PI) / 180;
  const c = Math.cos(rad), s = Math.sin(rad);
  return [x * c + y * s, -x * s + y * c];
};

const orientationTiltHandler = (e) => {
  if (!tiltActive || tiltKind === 2) return; // gyro carts use rotation RATE
  if (e.beta == null || e.gamma == null) return;
  if (tiltSettling()) {
    // Mid-rotation: freeze at the last value (snapping to level would be a
    // step, i.e. a flick). tiltNeutral stays null until settled.
    return;
  }
  const [sx, sy] = toScreenFrame(e.gamma, e.beta);
  // The first reading after a (re)baseline defines neutral, both axes in
  // screen space.
  if (tiltNeutral === null) tiltNeutral = { x: sx, y: sy };
  const clamp = (v) => Math.max(-1, Math.min(1, v));
  tiltTargetX = clamp((sx - tiltNeutral.x) / TILT_ORIENT_RANGE);
  tiltTargetY = clamp((sy - tiltNeutral.y) / TILT_ORIENT_RANGE);
};

// Rotation changes the axis and the pose: re-baseline once the phone has
// settled. Motion input is frozen at neutral across the rotation, since a
// turn is a large linear acceleration the jolt channel would read as a flick.
const TILT_REBASE_MS = 450;   // when the stale neutral is dropped
const TILT_SETTLE_MS = 650;   // when motion input starts counting again
const TILT_GLIDE_MS = 380;   // how long a re-baseline takes to settle in
const TILT_GLIDE_RATE = 0.16; // per-tick ease toward the new value
const TILT_SPIN_DEGREES = 50; // NET Z rotation that means "turning", degrees
const TILT_SPIN_HALFLIFE = 0.5; // seconds; keeps the integral from drifting
var tiltRebaseTimer = 0;
var tiltRotateUntil = 0;      // Date.now() before which motion is ignored
var tiltGlideUntil = 0;       // Date.now() before which the value eases
var tiltSpin = 0;             // leaky integral of |rotationRate.alpha|, deg
var tiltSpinAt = 0;           // timestamp of the last motion sample
const tiltSettling = () => Date.now() < tiltRotateUntil;

const rebaselineTiltForOrientation = () => {
  if (!tiltOrientationOn) return;
  tiltRotateUntil = Date.now() + TILT_SETTLE_MS;
  tiltJoltX = tiltJoltY = 0;      // kill any spike the turn already produced
  clearTimeout(tiltRebaseTimer);
  tiltRebaseTimer = setTimeout(() => {
    tiltNeutral = null; tiltGlideUntil = Date.now() + TILT_GLIDE_MS; // next settled reading re-baselines in the new frame
    tiltJoltX = tiltJoltY = 0;
    showToast("Tilt recentered for the new orientation");
  }, TILT_REBASE_MS);
};
window.addEventListener("orientationchange", rebaselineTiltForOrientation);
if (screen.orientation && screen.orientation.addEventListener) {
  screen.orientation.addEventListener("change", rebaselineTiltForOrientation);
}

const enableOrientationTilt = async () => {
  if (tiltOrientationOn) return;
  try {
    // iOS 13+ permission gate, must be called from a user gesture: neither
    // route awaits anything before this line.
    const doe = /** @type {*} */ (
      typeof DeviceOrientationEvent !== "undefined" ? DeviceOrientationEvent : null);
    if (doe && typeof doe.requestPermission === "function") {
      const res = await doe.requestPermission();
      if (res !== "granted") {
        showToast("Motion permission denied — D-pad and stick still tilt");
        return;
      }
    }
    // Motion shares the iOS permission sheet; best-effort elsewhere.
    const dme = /** @type {*} */ (
      typeof DeviceMotionEvent !== "undefined" ? DeviceMotionEvent : null);
    if (dme && typeof dme.requestPermission === "function") {
      try { await dme.requestPermission(); } catch {}
    }
    window.addEventListener("deviceorientation", orientationTiltHandler);
    window.addEventListener("devicemotion", motionJoltHandler);
    tiltOrientationOn = true;
    tiltNeutral = null; tiltGlideUntil = Date.now() + TILT_GLIDE_MS; // re-baseline at the moment of enabling
    showToast("Device tilt enabled — hold your comfortable angle now");
  } catch {
  } finally {
    // Granted or refused, the button re-reads the world.
    tiltCartBtnUpdate();
  }
};

// Device tilt is only offered where an orientation sensor could exist.
const tiltCanOrient = () =>
  typeof DeviceOrientationEvent !== "undefined" &&
  ("ontouchstart" in window || navigator.maxTouchPoints > 0);

// The top-bar cart button: "Enable tilt" until the orientation listener is
// attached (only the branch that attached it sets tiltOrientationOn), then
// Recenter.
const tiltCartBtnUpdate = () => {
  if (!tiltActive) {
    tiltRecenterBtn.hidden = true;
    return;
  }
  const needsEnable = !tiltOrientationOn;
  tiltRecenterBtn.classList.toggle("needs-enable", needsEnable);
  const label = needsEnable ? "Enable tilt" : "Recenter tilt";
  tiltRecenterBtn.title = label;
  tiltRecenterBtn.setAttribute("aria-label", label);
  tiltRecenterLabel.textContent = needsEnable ? "Enable tilt" : "Recenter";
  tiltRecenterBtn.hidden = needsEnable && !tiltCanOrient();
};

// Recenter: the current angle becomes neutral.
const tiltRecenterBtn = document.getElementById("tilt-recenter");
const tiltRecenterLabel = document.getElementById("tilt-recenter-label");
tiltRecenterBtn.addEventListener("click", () => {
  // Nothing awaited first: a single `await` ahead of requestPermission()
  // loses the iOS user gesture.
  if (!tiltOrientationOn) { enableOrientationTilt(); return; }
  tiltNeutral = null; tiltGlideUntil = Date.now() + TILT_GLIDE_MS; // next orientation reading re-baselines
  tiltJoltX = tiltJoltY = 0;
  showToast("Tilt recentered");
});

// The offer toast is a nudge; the top-bar button is the durable route in.
const maybeOfferOrientationTilt = () => {
  if (tiltOrientationOn || !tiltCanOrient()) return false;
  showActionToast("Play by tilting your device?", "Enable tilt", enableOrientationTilt);
  return true;
};

// --- Game Boy Printer ---
// A printer is always plugged into a solo GB core (gb/printer.nim); finished
// strips arrive via the wasm outbox, go to the gallery, and are announced
// with a toast.
var printerPhotos = [];       // {ts, w, h, png} newest-first, capped
const PRINTER_MAX_PHOTOS = 30;
const PRINTER_PHOTOS_KEY = "prints";

const loadPrinterPhotos = async () => {
  try {
    printerPhotos = (await dbGet(PRINTER_PHOTOS_KEY)) || [];
  } catch {
    printerPhotos = [];
  }
  await loadPhotoDots();
  refreshPrintsMenuItem();
};

// --- New-photo indicator ---------------------------------------------------
// A dot at each step (hamburger, Capture row, Printed Photos row); each
// clears when its own element is used. "View" on the print toast clears all
// three only if the gallery has ever been opened from the menu
// (`everOpenedFromMenu`, set by the menu row and nothing else), since the
// trail is what teaches where the gallery lives.
const PRINTER_DOTS_KEY = "prints-seen";
var photoDots = {
  everOpenedFromMenu: false, // has the gallery ever been opened FROM THE MENU
  menu: false,               // dot on the hamburger
  capture: false,            // dot on the Capture row
  gallery: false,            // dot on the Printed Photos row
};

const applyPhotoDots = () => {
  menuBtn.classList.toggle("has-new-photo", photoDots.menu);
  captureToggle.classList.toggle("has-new-photo", photoDots.capture);
  printsItem.classList.toggle("has-new-photo", photoDots.gallery);
};

const savePhotoDots = async () => {
  try { await dbPut(PRINTER_DOTS_KEY, photoDots); } catch {}
};

const loadPhotoDots = async () => {
  try {
    const rec = await dbGet(PRINTER_DOTS_KEY);
    if (rec && typeof rec === "object") photoDots = { ...photoDots, ...rec };
  } catch {}
  // If the photos are gone the trail goes with them.
  if (!printerPhotos.length) photoDots.menu = photoDots.capture = photoDots.gallery = false;
  applyPhotoDots();
};

const setPhotoDots = (on) => {
  photoDots.menu = photoDots.capture = photoDots.gallery = on;
  applyPhotoDots();
  savePhotoDots();
};

const clearPhotoDot = (which) => {
  if (!photoDots[which]) return;
  photoDots[which] = false;
  applyPhotoDots();
  savePhotoDots();
};

const refreshPrintsMenuItem = () => {
  printsItem.hidden = printerPhotos.length === 0;
};

const printToPng = (h) => {
  const W = 160;
  const ptr = Module._printer_take_ptr();
  if (!ptr || h <= 0) return null;
  const gray = new Uint8Array(Module.memory.buffer, ptr, W * h);
  const cnv = document.createElement("canvas");
  cnv.width = W;
  cnv.height = h;
  const ctx = cnv.getContext("2d");
  const img = ctx.createImageData(W, h);
  for (let i = 0; i < W * h; i++) {
    img.data[i * 4] = img.data[i * 4 + 1] = img.data[i * 4 + 2] = gray[i];
    img.data[i * 4 + 3] = 255;
  }
  ctx.putImageData(img, 0, 0);
  return { w: W, h, png: cnv.toDataURL("image/png") };
};

const downloadPrint = (photo) => {
  const a = document.createElement("a");
  a.href = photo.png;
  const base = (photo.game || "dingbat").replace(/\.[^.]+$/, "");
  const stamp = new Date(photo.ts).toISOString().slice(0, 19).replace(/[T:]/g, "-");
  a.download = `${base}-print-${stamp}.png`;
  a.click();
};

// What a finished print does once it is pixels; split from collectPrint so
// tests can drive it without wasm.
const storePrint = async (photo) => {
  printerPhotos.unshift(photo);
  if (printerPhotos.length > PRINTER_MAX_PHOTOS) printerPhotos.length = PRINTER_MAX_PHOTOS;
  try { await dbPut(PRINTER_PHOTOS_KEY, printerPhotos); } catch {}
  refreshPrintsMenuItem(); // the first print is what puts the row in the menu
  if (printsModal.classList.contains("open")) {
    // The gallery is open: nothing unseen.
    renderPrintsGrid();
    return;
  }
  setPhotoDots(true);
  showActionToast("Photo printed", "View", () => {
    // The toast only retires the trail for someone who knows where it leads.
    if (photoDots.everOpenedFromMenu) setPhotoDots(false);
    openPrintsModal();
  }, 6000);
};

const collectPrint = async (h) => {
  const shot = printToPng(h);
  if (!shot) return;
  await storePrint({ ...shot, ts: Date.now(), game: currentOriginalName || "" });
};

const pollPrinter = () => {
  if (typeof Module === "undefined" || !Module._printer_poll) return;
  if (Module._printer_poll() > 0) collectPrint(Module._printer_take());
};

// --- Printed photos gallery ---
const printsModal = document.getElementById("prints-modal");
const printsGrid = document.getElementById("prints-grid");
const printsEmpty = document.getElementById("prints-empty");
const printsItem = document.getElementById("open-prints"); // Capture ▸ Printed Photos

const renderPrintsGrid = () => {
  printsGrid.innerHTML = "";
  printsEmpty.hidden = printerPhotos.length > 0;
  printerPhotos.forEach((photo, idx) => {
    const cell = document.createElement("div");
    cell.className = "print-cell";
    const img = document.createElement("img");
    img.src = photo.png;
    img.alt = `Printed photo, ${photo.w} by ${photo.h} pixels`;
    img.className = "print-thumb";
    const row = document.createElement("div");
    row.className = "print-actions";
    const save = document.createElement("button");
    save.type = "button";
    save.className = "button button-sm";
    save.textContent = "Save PNG";
    save.addEventListener("click", () => downloadPrint(photo));
    const del = document.createElement("button");
    del.type = "button";
    del.className = "button button-sm roms-manage-danger";
    del.textContent = "Delete";
    del.addEventListener("click", async () => {
      printerPhotos.splice(idx, 1);
      try { await dbPut(PRINTER_PHOTOS_KEY, printerPhotos); } catch {}
      // Deleting the last photo takes the menu row and its dots.
      refreshPrintsMenuItem();
      if (!printerPhotos.length) setPhotoDots(false);
      renderPrintsGrid();
    });
    row.append(save, del);
    cell.append(img, row);
    printsGrid.appendChild(cell);
  });
};

const openPrintsModal = () => {
  menuDropdown.hidden = true;
  printsModal.classList.add("open");
  trapFocus(printsModal);
  renderPrintsGrid();
};

const closePrintsModal = () => {
  printsModal.classList.remove("open");
  releaseFocus(printsModal);
};

// The menu row is the one route that sets everOpenedFromMenu.
printsItem.addEventListener("click", () => {
  photoDots.everOpenedFromMenu = true;
  photoDots.gallery = false;
  applyPhotoDots();
  savePhotoDots();
  openPrintsModal();
});

// Each dot clears only when its own element is used.
menuBtn.addEventListener("click", () => {
  if (!menuDropdown.hidden) clearPhotoDot("menu");
});
captureToggle.addEventListener("click", () => {
  if (!captureSub.hidden) clearPhotoDot("capture");
});

document.getElementById("prints-close").addEventListener("click", closePrintsModal);
printsModal.addEventListener("click", (e) => {
  if (e.target === printsModal) closePrintsModal();
});

// --- GB Camera webcam source ---
// A hidden <video> is drawn cover-cropped and mirrored into a 128x120
// canvas ~15x/s, converted to luminance, and copied into the wasm buffer the
// sensor proc reads. Needs a secure context.
const CAM_W = 128, CAM_H = 120;
var camStream = null;
var camVideo = null;
var camTimer = null;
var camFacing = "user";   // phones: facingMode toggled by the flip button
var camDeviceIdx = -1;    // desktop: index into camDevices, -1 = default
var camDevices = [];      // videoinput deviceIds (labels arrive post-grant)
var camMirror = true;     // selfie-mirror front/desktop cams; not the back one
var camPending = false;   // a getUserMedia request is in flight
var camDenied = false;    // the browser refused: NotAllowedError, or the
                          // Permissions API reporting "denied" outright
var camMissing = false;   // asked, and there is no camera to open
var camEnded = false;     // had live frames, and the track died on its own
var camPermProbed = false;   // the Permissions API has been asked (once)
var camNoticeShown = null;   // which notice the sensor is currently carrying
const camFlipBtn = document.getElementById("cam-flip");
const camFlipLabel = document.getElementById("cam-flip-label");

// Usable frames right now. A non-null camStream is not enough: iOS ends the
// tracks on backgrounding and an ended track's <video> goes black rather
// than throwing.
const camLive = () =>
  !!camStream && camStream.getVideoTracks().some((t) => t.readyState === "live");

const camCartLoaded = () =>
  typeof Module !== "undefined" && !!Module._wasm_cart_has_camera &&
  Module._wasm_cart_has_camera() === 1;

const camUsable = () => !!navigator.mediaDevices?.getUserMedia;

// The button's label with no stream; the viewfinder notices name it via
// this constant.
const CAM_ENABLE_LABEL = "Enable camera";

// The top-bar button: "Enable camera" before a stream is attached, then
// the front/back switch (only with more than one camera).
const camCartBtnUpdate = () => {
  if (!camCartLoaded()) {
    camFlipBtn.hidden = true;
    return;
  }
  const needsEnable = !camLive();
  camFlipBtn.classList.toggle("needs-enable", needsEnable);
  const label = needsEnable ? CAM_ENABLE_LABEL : "Switch camera";
  camFlipBtn.title = label;
  camFlipBtn.setAttribute("aria-label", label);
  camFlipLabel.textContent = needsEnable ? CAM_ENABLE_LABEL : "Camera";
  // Nothing to enable without getUserMedia; nothing to switch to with one camera.
  camFlipBtn.hidden = needsEnable ? !camUsable() : camDevices.length < 2;
};

// --- What the emulated viewfinder says when there is no camera ---
// A rendered text frame goes into the 128x120 8-bit sensor buffer like a
// webcam frame would (camera.nim's synthetic scene reads as corruption).
// The MAC-GBD's edge enhancement keeps large high-contrast type clean
// through the dither; each line is auto-fitted to the full 128px width.
// One string per notice: "/" is the line break, {tap} the pointing verb,
// {label} CAM_ENABLE_LABEL. Keep lines to ~14 characters (below the 17.6px
// floor they turn to mush); `node tools/cammsg.mjs` fit-checks a candidate.
const CAM_NOTICES = {
  // Never asked.
  prompt: "{tap} / {label} / in the top bar",
  // NotAllowedError, or the Permissions API said "denied".
  blocked: "Camera is / currently / restricted / by the / browser.",
  // NotFoundError.
  missing: "No camera / found on / this device",
  // The track ended by itself (backgrounding, another app, unplugged).
  ended: "Camera / stopped. / {tap} / {label}",
  // No getUserMedia at all (a plain-http origin).
  insecure: "Camera needs / a secure / connection",
};

// A notice's lines. `touch` lets tools/cammsg.mjs preview both wordings.
const camNoticeLines = (kind, touch = touchDevice) =>
  (CAM_NOTICES[kind] || "").split("/")
    .map((s) => s.trim()
      .replace(/\{tap\}/g, touch ? "Tap" : "Click")
      .replace(/\{label\}/g, CAM_ENABLE_LABEL))
    .filter((s) => s !== "");

// Which notice belongs in the viewfinder, or null when frames are flowing.
const camNoticeFor = () => {
  if (camLive()) return null;
  if (!camUsable()) return "insecure";
  if (camDenied) return "blocked";
  if (camMissing) return "missing";
  if (camEnded) return "ended";
  return "prompt";
};

// Lay the lines out across the 112 sensor rows the MAC-GBD keeps (it
// discards CAM_SENSOR_EXTRA/2 = 4 rows at each end). White on black, the
// heaviest weight: the cart's edge filter keys off boundaries.
const CAM_VIEW_TOP = 4, CAM_VIEW_H = 112;

// Layout arithmetic, separate from painting so tools/cammsg.mjs can report
// render sizes. Uses ctx only to measure.
const camFitLines = (ctx, lines) => {
  const slot = CAM_VIEW_H / lines.length;
  return lines.map((text, i) => {
    let px = Math.min(slot * 0.8, 44);
    ctx.font = `900 ${px}px sans-serif`;
    const w = ctx.measureText(text).width;
    if (w > CAM_W - 4) px = (px * (CAM_W - 4)) / w;
    return { text, px, y: CAM_VIEW_TOP + slot * (i + 0.5) };
  });
};

const camDrawNotice = (ctx, lines) => {
  ctx.fillStyle = "#000";
  ctx.fillRect(0, 0, CAM_W, CAM_H);
  ctx.fillStyle = "#fff";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  for (const fit of camFitLines(ctx, lines)) {
    ctx.font = `900 ${fit.px}px sans-serif`;
    ctx.fillText(fit.text, CAM_W / 2, fit.y);
  }
};

// RGBA canvas pixels -> the sensor's 8-bit grey; shared by the notice
// writer and the webcam pump.
const camToGrey = (img, dst) => {
  for (let i = 0, p = 0; i < dst.length; i++, p += 4) {
    dst[i] = (img[p] * 299 + img[p + 1] * 587 + img[p + 2] * 114) / 1000;
  }
};

// Push one still frame into the sensor; the cart re-reads the buffer on
// every capture.
const camShowNotice = (kind) => {
  if (camNoticeShown === kind) return;
  if (!CAM_NOTICES[kind] || typeof Module === "undefined" ||
      !Module._wasm_camera_attach) return;
  // Attaching takes the cart off its synthetic scene.
  if (!Module._wasm_camera_attach()) return;
  const ptr = Module._wasm_camera_frame_ptr();
  if (!ptr) return;
  const cnv = document.createElement("canvas");
  cnv.width = CAM_W;
  cnv.height = CAM_H;
  const ctx = cnv.getContext("2d", { willReadFrequently: true });
  camDrawNotice(ctx, camNoticeLines(kind));
  const img = ctx.getImageData(0, 0, CAM_W, CAM_H).data;
  // Fresh heap view every copy: memory growth detaches cached buffers.
  camToGrey(img, new Uint8Array(Module.memory.buffer, ptr, CAM_W * CAM_H));
  camNoticeShown = kind;
};

// The button's state and the viewfinder's notice are decided together.
const camRefresh = () => {
  camCartBtnUpdate();
  if (!camCartLoaded()) return;
  const kind = camNoticeFor();
  if (kind) camShowNotice(kind);
  else camNoticeShown = null;   // live frames are overwriting it anyway
};

// The Permissions API can report "denied" without prompting. WebKit rejects
// the "camera" query, so a failed probe leaves camDenied alone.
const camProbePermission = async () => {
  if (camPermProbed) return;   // one status object per session, one listener
  camPermProbed = true;
  try {
    const st = await navigator.permissions.query(
      /** @type {*} */ ({ name: "camera" }));
    if (st.state === "denied") camDenied = true;
    else if (st.state === "granted") camDenied = false;
    // Flipping the site permission does not reload the page.
    st.onchange = () => {
      camDenied = st.state === "denied";
      if (!camLive()) camRefresh();
    };
    camRefresh();
  } catch {}
};

const stopWebcam = () => {
  clearInterval(camTimer);
  camTimer = null;
  if (camStream) for (const t of camStream.getTracks()) t.stop();
  camStream = null;
  camVideo = null;
  camFacing = "user";   // a fresh cart starts front-facing again
  camDeviceIdx = -1;
  camFlipBtn.hidden = true;
};

const camConstraints = () => {
  const size = { width: { ideal: 320 }, height: { ideal: 240 } };
  if (touchDevice) return { facingMode: camFacing, ...size };
  if (camDeviceIdx >= 0 && camDevices[camDeviceIdx]) {
    return { deviceId: { exact: camDevices[camDeviceIdx] }, ...size };
  }
  return { facingMode: "user", ...size };
};

// (Re)open the camera; the flip button swaps the stream under the pump.
const openCamStream = async () => {
  const stream = await navigator.mediaDevices.getUserMedia({ video: camConstraints() });
  if (camStream) for (const t of camStream.getTracks()) t.stop();
  camStream = stream;
  if (!camVideo) {
    camVideo = document.createElement("video");
    camVideo.muted = true;
    camVideo.playsInline = true;
  }
  camVideo.srcObject = stream;
  // A track that ends on its own must tear the pump down (else it copies
  // black frames); the guard keeps switchCamera's deliberate swap from
  // tripping it.
  for (const t of stream.getVideoTracks()) {
    t.addEventListener("ended", () => {
      if (camLive()) return;
      stopWebcam();
      camEnded = true;
      camRefresh();
      showToast("Camera disconnected");
    });
  }
  await camVideo.play().catch(() => {});
  // Mirror the front camera and desktop webcams, not the back camera.
  camMirror = touchDevice ? camFacing === "user" : true;
};

// Flip: phones toggle front/back; desktops cycle the device list.
const switchCamera = async () => {
  if (!camLive()) return;
  if (touchDevice) {
    camFacing = camFacing === "user" ? "environment" : "user";
  } else if (camDevices.length > 1) {
    camDeviceIdx = (camDeviceIdx + 1) % camDevices.length;
  }
  try {
    await openCamStream();
    if (!touchDevice) {
      const track = camStream.getVideoTracks()[0];
      showToast("Camera: " +
        (track && track.label ? track.label : "camera " + (camDeviceIdx + 1)));
    }
  } catch {
    showToast("Couldn't switch camera");
  }
  camRefresh();
};
// Both branches run straight off the click with nothing awaited, so
// getUserMedia still carries the iOS user gesture.
camFlipBtn.addEventListener("click", () =>
  camLive() ? switchCamera() : enableWebcam());

const enableWebcam = async () => {
  if (camPending || camLive() || !camUsable()) return;
  // Drop a dead stream first, or a second pump interval stacks on the first.
  if (camStream) stopWebcam();
  camPending = true;
  try {
    await openCamStream();
    camDenied = camMissing = camEnded = false;
  } catch (e) {
    // NotAllowedError = refused; NotFoundError = no device; anything else
    // is a camera that would not open.
    const name = e && e.name;
    if (name === "NotAllowedError" || name === "SecurityError") camDenied = true;
    else camMissing = true;
    showToast(camDenied
      ? "Camera blocked by the browser — the viewfinder says so"
      : "No camera available — the viewfinder says so");
    return;
  } finally {
    camPending = false;
    camRefresh();
  }
  const len = Module._wasm_camera_attach();
  if (!len) { stopWebcam(); camRefresh(); return; }
  // Post-grant, enumerateDevices yields labels; two or more inputs earn
  // the flip button.
  try {
    const devs = await navigator.mediaDevices.enumerateDevices();
    camDevices = devs.filter((d) => d.kind === "videoinput").map((d) => d.deviceId);
    // Seed the cycle at the first device so the first flip reaches a
    // different camera.
    if (camDeviceIdx < 0) camDeviceIdx = 0;
  } catch {}
  camRefresh();
  const cnv = document.createElement("canvas");
  cnv.width = CAM_W;
  cnv.height = CAM_H;
  const ctx = cnv.getContext("2d", { willReadFrequently: true });
  camTimer = setInterval(() => {
    if (!camVideo || camVideo.readyState < 2) return;
    const vw = camVideo.videoWidth, vh = camVideo.videoHeight;
    if (!vw || !vh) return;
    // Cover-crop into 128x120; mirror only when facing the user.
    const scale = Math.max(CAM_W / vw, CAM_H / vh);
    const sw = CAM_W / scale, sh = CAM_H / scale;
    const sx = (vw - sw) / 2, sy = (vh - sh) / 2;
    ctx.save();
    if (camMirror) {
      ctx.translate(CAM_W, 0);
      ctx.scale(-1, 1);
    }
    ctx.drawImage(camVideo, sx, sy, sw, sh, 0, 0, CAM_W, CAM_H);
    ctx.restore();
    const img = ctx.getImageData(0, 0, CAM_W, CAM_H).data;
    const ptr = Module._wasm_camera_frame_ptr();
    if (!ptr) return;
    // Fresh heap view every copy: memory growth detaches cached buffers.
    camToGrey(img, new Uint8Array(Module.memory.buffer, ptr, CAM_W * CAM_H));
  }, 66);
  camNoticeShown = null;
  showToast("Camera live — the cart sees what you see");
};

const detectCameraCart = () => {
  camNoticeShown = null;   // a fresh cart's sensor carries nothing yet
  // A fresh load is a fresh chance; only camDenied (the browser's answer)
  // survives.
  camMissing = camEnded = false;
  if (!camCartLoaded()) {
    stopWebcam(); // a non-camera game must not hold the camera open
    camCartBtnUpdate();
    return;
  }
  if (camLive()) {
    // A fresh core has no sensor callback: re-point it at the live stream
    // instead of asking for permission again.
    Module._wasm_camera_attach();
    camCartBtnUpdate();
    return;
  }
  if (camStream) { stopWebcam(); camEnded = true; }  // tracks are dead
  camRefresh();          // button reads "Enable camera"; viewfinder says why
  camProbePermission();  // may upgrade "tap Enable" to "blocked", async
  if (!camUsable()) return;
  showActionToast("Game Boy Camera cart — use your real camera?",
    CAM_ENABLE_LABEL, enableWebcam);
};

// --- MBC5 rumble ---
// _wasm_rumble is polled each tick. Motor-on drives gamepad vibration
// (re-triggered every ~50 ms with 60 ms effects so they chain),
// navigator.vibrate, and a body.rumbling canvas shake; all gated by gbRumble.
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
    // 45 ms: above the 25 ms button tick, below the 50 ms retrigger.
    try { navigator.vibrate?.(45); } catch {}
  }
};

// --- Early (pre-wasm) boot -------------------------------------------------
// initStorage runs at DOMContentLoaded so the home grid never waits on the
// wasm; onRuntimeInitialized awaits storageReady. The test harness keeps
// readyState at "loading" and drives openDB/migrations/refreshHomeRecent itself.

// Resolved once the wasm runtime is initialized; launch paths wait here.
// The test harness calls markRuntimeReady() itself.
let runtimeReady = false;
let markRuntimeReady = () => {};
const runtimeReadyPromise = new Promise((resolve) => {
  markRuntimeReady = () => { runtimeReady = true; resolve(); };
});

// Queue an FS/Module-touching action behind runtime init, with a toast
// when the wait is real.
const ensureRuntimeReady = () => {
  if (runtimeReady) return Promise.resolve();
  showToast("Starting the emulator…");
  return runtimeReadyPromise;
};

const initStorage = async () => {
  await openDB();
  // Migrations before anything renders from the records they rewrite.
  await migrateFromLocalStorage();
  await migrateRecentFormat();
  // loadBiosFromStorage is not here: the FS doesn't exist yet. The loads
  // below only set JS vars / DOM; their apply* helpers no-op without the
  // runtime and onRuntimeInitialized re-pushes the wasm-side mirrors.
  await loadKeybindingsFromStorage();
  await loadLargeControlsFromStorage();
  await loadOpaqueControlsFromStorage();
  await loadHideTouchOnGamepadFromStorage();
  await loadInputDisplayFromStorage();
  await loadControlStyleFromStorage();
  await loadRunaheadFromStorage();
  await loadAudioSettings();
  await loadColorCorrect();
  await loadSystemSettings();
  await loadVideoSettings();
  await loadGbPalette();
  // Must run before anything can print: storePrint writes the whole array
  // back (web/tests/printer-photos.test.mjs), and the menu row and dots are
  // driven off the count.
  await loadPrinterPhotos();
  await loadSyncState();
  await loadRomsSort();
  refreshSyncUI();
  startSyncTriggers();
  // Resume Drive (see resumeDriveOnBoot).
  resumeDriveOnBoot();
  refreshHomeRecent();
  // Not awaited: nothing renders from it.
  sweepOrphanedAutoStates().catch(() => {});
};

let storageReadyResolve;
let storageReadyReject;
const storageReady = new Promise((resolve, reject) => {
  storageReadyResolve = resolve;
  storageReadyReject = reject;
});
// If the wasm never arrives nobody awaits storageReady; keep the rejection
// from surfacing as unhandled on top of the real failure.
storageReady.catch(() => {});
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => {
    initStorage().then(storageReadyResolve, storageReadyReject);
  }, { once: true });
} else {
  // If this file is ever loaded defer/dynamic, boot anyway.
  initStorage().then(storageReadyResolve, storageReadyReject);
}

/** @type {EmscriptenModule} */
var Module = {
  // SDL renders to a hidden canvas: a canvas holds one context type, and
  // the visible #canvas carries our WebGL2 context.
  canvas: /** @type {HTMLCanvasElement} */ ((() => document.getElementById("sdl-canvas"))()),
  onRuntimeInitialized: async () => {
    // iOS Safari kills or JIT-demotes tabs under memory pressure: shrink the
    // rewind ring's cap before any core exists.
    if (IS_IOS && Module._setRewindCapBytes) {
      Module._setRewindCapBytes(16 * 1024 * 1024);
    }
    // Same for the clip ring's separate budget (CLIP_CAP_BYTES); bounded in
    // time as well, so the cap shortens history rather than growing the footprint.
    if (IS_IOS && Module._setClipCapBytes) {
      Module._setClipCapBytes(6 * 1024 * 1024);
    }
    // Storage boot started at DOMContentLoaded (initStorage); a storage
    // failure must still abort the boot here.
    await storageReady;
    // The FS exists only now.
    await loadBiosFromStorage();
    // Re-push the wasm-side mirrors of settings loaded before the runtime.
    applySystemSettings();
    applyColorCorrect();
    applyPitchCorrectFF();
    applyMp2kHle();
    applyLcdResponse();
    // Unblock queued launches and retire the boot progress strip.
    markRuntimeReady();
    document.body.classList.add("runtime-ready");
    let frameCount = 0;
    const SAMPLE_RATE = 32768; // GBA/GB native sample rate
    const TARGET_FPS = 59.7275;
    const FRAME_TIME = 1000.0 / TARGET_FPS;
    let lastFrameTime = 0;
    let accumulator = 0;

    // Push-based Web Audio playback: samples at SAMPLE_RATE scheduled at
    // precise times; the browser resamples to the device rate.
    let audioCtx = null;
    let gainNode = null;
    let lowpassNode = null;
    let playTime = 0;

    // Optional ~12 kHz low-pass (off = no filter node in the path). Clip
    // recording tap: the master gain also feeds a MediaStreamDestination;
    // routeOutput re-attaches it across lowpass toggles.
    let clipTapNode = null;
    let clipTapActive = false;

    const routeOutput = () => {
      if (!audioCtx || !gainNode) return;
      try { gainNode.disconnect(); } catch (e) {}
      if (typeof audioLowpass !== "undefined" && audioLowpass && !speedMode) {
        if (!lowpassNode) {
          lowpassNode = audioCtx.createBiquadFilter();
          lowpassNode.type = "lowpass";
          lowpassNode.frequency.value = 12000;
          lowpassNode.Q.value = 0.707;   // gentle Butterworth-ish, no resonance
          lowpassNode.connect(audioCtx.destination);
        }
        gainNode.connect(lowpassNode);
      } else {
        gainNode.connect(audioCtx.destination);
      }
      if (clipTapActive && clipTapNode) gainNode.connect(clipTapNode);
    };
    window.updateAudioLowpass = () => routeOutput();
    // Recorder-side hooks; the tap's MediaStream, or null pre-unlock.
    window.acquireClipAudio = () => {
      if (!audioCtx || !gainNode) return null;
      if (!clipTapNode) clipTapNode = audioCtx.createMediaStreamDestination();
      clipTapActive = true;
      routeOutput();
      return clipTapNode.stream;
    };
    window.releaseClipAudio = () => {
      clipTapActive = false;
      if (audioCtx && gainNode) routeOutput();
    };
    // Under fast-forward, play the frames that fit within this much queued
    // lead and drop the rest (audio can only play at realtime rate).
    const FF_MAX_AUDIO_LEAD = 0.15; // seconds of audio allowed queued ahead
    // Cap on scheduled lead: when audioCtx.currentTime stalls while state
    // stays "running" (iOS route changes), source nodes would otherwise
    // accumulate at 60/s. Generous so 2x/catch-up bursts are never clipped.
    const MAX_AUDIO_LEAD = 0.25;
    // Lead servo (see pushAudio): the floor restored after a spend, and the
    // target the rate servo holds the lead near.
    const AUDIO_LEAD_FLOOR = 0.008;
    const AUDIO_TARGET_LEAD = 0.030;

    const initAudio = () => {
      if (audioCtx) return;
      // "playback" audio session so iOS ignores the silent switch (Safari 17+).
      if (navigator.audioSession) {
        navigator.audioSession.type = "playback";
      }
      try {
        audioCtx = new AudioContext({ sampleRate: SAMPLE_RATE });
      } catch (e) {
        // Old WebKit can reject the sampleRate option; createBuffer() tags
        // each buffer 32768 Hz and Web Audio resamples.
        audioCtx = new AudioContext();
      }
      gainNode = audioCtx.createGain();
      gainNode.gain.value = effectiveGain();
      lowpassNode = null;
      routeOutput();   // gain -> (lowpass ->) destination per the toggle
      playTime = 0;
    };

    window.updateGain = () => {
      if (gainNode) gainNode.gain.value = effectiveGain();
    };

    // Resume on first user interaction (autoplay policy); on iOS also play a
    // silent buffer and an <audio> element to activate the session.
    let audioUnlocked = false;
    // iOS <= 16: Web Audio obeys the silent switch unless an <audio> element
    // is playing, so a silent element loops for the life of the page.
    let silentLoopEl = null;
    const needsSilentLoop = () =>
      !navigator.audioSession &&
      (/iPhone|iPad|iPod/.test(navigator.userAgent) ||
        (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1));
    const silentWavURL = () => {
      // 0.25 s of 8 kHz mono 8-bit silence, built inline.
      const n = 2000;
      const buf = new Uint8Array(44 + n).fill(0x80, 44);
      const dv = new DataView(buf.buffer);
      const tag = (off, s) => { for (let i = 0; i < s.length; i++) buf[off + i] = s.charCodeAt(i); };
      tag(0, "RIFF"); dv.setUint32(4, 36 + n, true); tag(8, "WAVE");
      tag(12, "fmt "); dv.setUint32(16, 16, true); dv.setUint16(20, 1, true);
      dv.setUint16(22, 1, true); dv.setUint32(24, 8000, true);
      dv.setUint32(28, 8000, true); dv.setUint16(32, 1, true);
      dv.setUint16(34, 8, true); tag(36, "data"); dv.setUint32(40, n, true);
      return URL.createObjectURL(new Blob([buf], { type: "audio/wav" }));
    };
    const resumeAudio = () => {
      initAudio();
      // iOS Safari parks the context in a non-standard "interrupted" state
      // after calls / Siri; resume() for any non-running state.
      if (audioCtx.state !== "running") audioCtx.resume().catch(() => {});
      // Outside the unlock branch: retried until it sticks (old iOS refuses
      // the touchstart play(); pagehide pauses the loop).
      if (silentLoopEl && silentLoopEl.paused) silentLoopEl.play().catch(() => {});
      if (!audioUnlocked) {
        audioUnlocked = true;
        let silentBuf = audioCtx.createBuffer(1, 1, SAMPLE_RATE);
        let src = audioCtx.createBufferSource();
        src.buffer = silentBuf;
        src.connect(audioCtx.destination);
        src.start(0);
        if (needsSilentLoop()) {
          silentLoopEl = new Audio(silentWavURL());
          silentLoopEl.loop = true;
          silentLoopEl.play().catch(() => {});
        } else {
          let a = new Audio("data:audio/wav;base64,UklGRiYAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQIAAAAAAA==");
          a.play().catch(() => {});
        }
      }
    };
    document.addEventListener("click", resumeAudio, { once: false });
    document.addEventListener("keydown", resumeAudio, { once: false });
    document.addEventListener("touchstart", resumeAudio, { once: false });
    // Old iOS WebKit only counts touchend as a media gesture, and the touch
    // controls preventDefault so they never synthesize a click.
    document.addEventListener("touchend", resumeAudio, { once: false });

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
      // A spent cushion means a gap already happened: restore a small floor
      // so the next hitch doesn't click too; the rate servo walks the lead
      // back to its target (docs/web_audio_pacing.md).
      if (playTime < now + AUDIO_LEAD_FLOOR) playTime = now + AUDIO_LEAD_FLOOR;
      // The audio clock stalled: drop this frame's samples rather than stack
      // source nodes. A backstop; the rate servo keeps it from firing.
      if (playTime - now > MAX_AUDIO_LEAD) {
        Module._clearAudioBuffer();
        return;
      }
      const stereoSamples = len; // total float32 values (L,R,L,R,...)
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
      // Playback-rate servo: hold the lead near its target from both
      // directions (above: marginally fast, draining production drift;
      // below: marginally slow, rebuilding the cushion). Clamped to +/-0.4%
      // (7 cents); steady state ~0.1%. Gapless because the cursor advances
      // by the consumed duration (duration / rate).
      const excess = playTime - now - AUDIO_TARGET_LEAD;
      const rate = 1 + Math.max(-0.004, Math.min(0.004, excess * 0.15));
      source.playbackRate.value = rate;
      source.start(playTime);
      playTime += buffer.duration / rate;
    };

    const fpsDiv = document.getElementById("fps");
    // The counter appears only when the frame rate is unusual for the mode
    // (0 paused/rewinding, ~120 at 2x, ~60 otherwise); fast-forward always shows.
    let lastFpsMode = "";
    setInterval(() => {
      if (sleepVisible) {
        frameCount = 0;
        return;  // fps display is showing SLEEPING
      }
      const mode = paused ? "paused" : rewindHeld ? "rewind"
        : fastForward ? "ffw" : speed2x ? "2x" : slowMotion ? "slow" : "normal";
      const expected = mode === "paused" || mode === "rewind" ? 0
        : mode === "2x" ? 119.5 : mode === "slow" ? 29.9
        : mode === "normal" ? 59.7 : null;
      const usual = expected !== null &&
        Math.abs(frameCount - expected) <= Math.max(3, expected * 0.05);
      // A mode switch mid-window yields a blended count.
      if (usual || mode !== lastFpsMode) {
        fpsDiv.textContent = "";
      } else {
        // The unit rides in its own span so phones can drop it.
        fpsDiv.innerHTML = frameCount + '<span class="fps-unit"> fps</span>';
      }
      lastFpsMode = mode;
      frameCount = 0;
    }, 1000);

    // Periodic memory telemetry (the frame bench cannot run mid-game).
    setInterval(() => {
      if (!currentRomName && !linkMode) return;
      const mb = Math.round(wasmHeapBytes() / (1024 * 1024));
      if (mb) log(`heap ${mb}MB`);
    }, 5 * 60 * 1000);

    setInterval(() => {
      if (linkMode) {
        persistLinkSaves();
      } else if (currentRomName && currentOriginalName) {
        persistSave(currentRomName, currentOriginalName);
      }
    }, 5000);

    window.addEventListener("beforeunload", () => {
      // Get the BYE out so the peer sees a clean exit (the sync parts run
      // before the page dies).
      if (netMode && typeof netShutdown === "function") netShutdown();
      if (linkMode) {
        persistLinkSaves();
      } else if (currentRomName && currentOriginalName) {
        persistSave(currentRomName, currentOriginalName);
        persistAutoState();
      }
    });

    // Mobile browsers kill backgrounded tabs without pagehide: snapshot on hide.
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) persistAutoState();
    });

    // iOS Safari often skips beforeunload; pagehide is the reliable signal
    // (also on bfcache entry). Suspend the AudioContext so a bfcached page
    // doesn't hold the audio session.
    window.addEventListener("pagehide", () => {
      if (netMode && typeof netShutdown === "function") netShutdown();
      if (linkMode) {
        persistLinkSaves();
      } else if (currentRomName && currentOriginalName) {
        persistSave(currentRomName, currentOriginalName);
        persistAutoState(); // one-tap resume next launch
      }
      if (audioCtx && audioCtx.state === "running") {
        audioCtx.suspend().catch(() => {});
      }
      // The legacy-iOS silent loop holds the session too; pageshow restarts it.
      if (silentLoopEl) silentLoopEl.pause();
    });
    // Restored from bfcache: resume the context suspended in pagehide.
    window.addEventListener("pageshow", (e) => {
      if (e.persisted && (currentRomName || linkMode)) resumeAudio();
    });

    // "SLEEPING" in place of the FPS counter while the GBA is in Stop mode.
    let sleepVisible = false;
    const updateSleepOverlay = () => {
      const sleeping = !!(Module._isStopped && Module._isStopped());
      if (sleeping !== sleepVisible) {
        sleepVisible = sleeping;
        fpsDiv.textContent = sleeping ? "SLEEPING" : "";
        document.body.classList.toggle("sleeping", sleeping);
      }
    };

    // Enhanced-audio indicator. Two-stage so the CSS transition plays:
    // unhide, then .on on the next frame.
    const hleIndicator = document.getElementById("hle-indicator");
    let hleActive = false;
    const updateHleIndicator = () => {
      const on = !!(
        Module._wasm_hle_audio_active && Module._wasm_hle_audio_active()
      );
      if (on === hleActive) return;
      hleActive = on;
      if (on) {
        hleIndicator.hidden = false;
        // reflow so the class add animates
        void hleIndicator.offsetWidth;
        hleIndicator.classList.add("on");
      } else {
        hleIndicator.classList.remove("on");
        hleIndicator.hidden = true;
      }
    };

    // Advance the online-link core by what `accumulator` affords, capped.
    // Called from the RAF loop and from netplay.js on every inbound message
    // (draining a stall's debt the moment the peer's data arrives).
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
      updateTilt(); // MBC7 carts: ease the tilt vector toward its target
      pollPrinter(); // GB carts: print-intent offer + finished-strip pickup
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
        // Rollback: rollback_tick returns the frame just simulated (ship it)
        // or -1 when stalled at the prediction window. 2x is allowed because
        // both peers halve the step together (RB_SPEED).
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
        // Auto-end via serial-cable inactivity (the RB_IDLE_* windows). Skip
        // while the tab is hidden: throttled rAF pauses transfers, which is
        // not "link done"; reset the clock so the timer restarts on return.
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
        // Online link: driveNet consumes the accumulator (also called from
        // netplay.js on every message, so a stall resumes at network speed).
        driveNet();
      } else if (linkMode) {
        // 2P link: fixed-rate frames only.
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
      } else if (clipReplayActive) {
        // Capture replay: clip_tick presents each frame and returns -1 when
        // the log is exhausted (the live state is already restored).
        let framesRun = 0;
        let done = false;
        while (accumulator >= FRAME_TIME && framesRun < 2) {
          const left = Module._clip_tick();
          if (left < 0) { done = true; break; }
          if ((left & 15) === 0) updateClipBanner(left);
          pushAudio();
          frameCount++;
          accumulator -= FRAME_TIME;
          framesRun++;
        }
        if (accumulator > FRAME_TIME * 2) accumulator = 0;
        if (done) finishRetroClip(true);
      } else if (rewindHeld) {
        // Pop ~30 snapshots/s (10 frames each, ~5x realtime backward); the
        // pop presents the frame itself and queues no audio.
        if (timestamp - lastRewindPop >= 33) {
          lastRewindPop = timestamp;
          if (Module._wasm_rewind_pop) Module._wasm_rewind_pop();
        }
        accumulator = 0;
      } else if (fastForward) {
        // As many frames as fit in a ~16ms budget. playTime stays continuous
        // and only frames whose audio fits within FF_MAX_AUDIO_LEAD play;
        // the rest are dropped, so audio stays realtime-rate.
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
        // Catch up, capped. At 2x each frame consumes half the step.
        const step = speed2x ? FRAME_TIME / 2 : slowMotion ? FRAME_TIME * 2 : FRAME_TIME;
        const maxFrames = speed2x ? 4 : 2;
        // Run-ahead only at normal speed; off, this is plain loop_tick.
        const useRunahead = runaheadFrames > 0 && !speed2x && !slowMotion &&
          !speedMode && typeof Module._runahead_tick === "function";
        let framesRun = 0;
        while (accumulator >= step && framesRun < maxFrames) {
          if (useRunahead) Module._runahead_tick(runaheadFrames);
          else Module._loop_tick();
          pushAudio();
          frameCount++;
          accumulator -= step;
          framesRun++;
        }
        // Bound the debt but keep two frames of it: zeroing deletes those
        // frames' audio (a click at every big hitch, docs/web_audio_pacing.md).
        if (accumulator > step * 2) accumulator = step * 2;
        // On a 120 Hz display every other tick steps zero frames; don't
        // re-present (doubles the upload + shader cost). presentDirty forces one.
        presentSkip = framesRun === 0 && !presentDirty;
      }
      // Present through WebGL2 (2P link and rollback blit their own canvases).
      if (!presentSkip) {
        drawGame();
        presentDirty = false;
      } else {
        presentSkips++; // diagnostics: ticks that reused the shown frame
      }
      presentSkip = false;
      // Screenshot: grab it in this task (no preserveDrawingBuffer).
      if (pendingShot) {
        Module._loop_tick();
        drawGame();
        captureCanvas();
      }
      updateSleepOverlay();
      updateHleIndicator();
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

// Direction input id -> d-pad cell; a diagonal cell lights both arms.
const ARM_CELL_ID = { 0: "up", 1: "down", 2: "left", 3: "right" };
const setArms = (inputs, on) => {
  for (let id of inputs) {
    let cell = document.getElementById(ARM_CELL_ID[id]);
    if (cell) cell.classList.toggle("arm-active", on);
  }
};

// --- Vibration / haptic ---
// navigator.vibrate needs sticky user activation in Chromium, and touchstart
// (which the game buttons fire haptic() from) does not grant it. A one-time
// capture listener on the granting events establishes it at the earliest
// gesture, and records which event did it for the diagnostic log.
let firstActivationEvent = null;
const noteActivation = (e) => {
  if (firstActivationEvent) return;
  firstActivationEvent = e.type;
  for (const ev of ["touchend", "pointerup", "mousedown", "keydown"])
    window.removeEventListener(ev, noteActivation, true);
};
for (const ev of ["touchend", "pointerup", "mousedown", "keydown"])
  window.addEventListener(ev, noteActivation, true);

// Haptic tick: ~25 ms is the perceptible floor for Android motors. iOS
// never shipped vibrate and Firefox removed it in 129; silent no-ops there.
const HAPTIC_MS = 25;
// hblk:<blocked>/<total> in the debug log; blocked = vibrate() exists and
// returned false.
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
const dpadEl = document.getElementById("dpad");

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
  if (touch == null) return;
  let element = document.elementFromPoint(touch.clientX, touch.clientY);
  if (element == currentDpadElement) return;
  let oldInputs = getInputs(currentDpadElement);
  // Only cells inside #dpad count: face buttons also carry data-inputs.
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
    // Slide-off tolerance: keep the direction held just past the pad's edge.
    const onOtherControl = element && element.hasAttribute("data-inputs");
    if (currentDpadElement && !onOtherControl) {
      const r = dpadEl.getBoundingClientRect();
      const margin = r.width * 0.22; // ~2/3 of a cell of forgiveness
      if (
        touch.clientX >= r.left - margin &&
        touch.clientX <= r.right + margin &&
        touch.clientY >= r.top - margin &&
        touch.clientY <= r.bottom + margin
      ) {
        return; // stay on the current direction
      }
    }
    setInputs(oldInputs, false);
    setArms(oldInputs, false);
    currentDpadElement = null;
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

// Standalone buttons; d-pad children are handled above.
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

// --- Joystick touch controls ---
// The finger's vector is quantized like the gamepad analog path: past a
// radial deadzone, a direction bit goes down when its normalized axis
// component exceeds 0.4. Only press/release deltas are routed.
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
    // The rim arc points at the quantized direction (0deg = up, clockwise).
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
    // Finger crossed the rim: drag the base along, but never out of the
    // touch region.
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
  // Transform-only, no layout.
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
  // Measure the home geometry from the untranslated base.
  joyBaseEl.style.transform = "";
  const rect = joyBaseEl.getBoundingClientRect();
  joyHome = {
    x: rect.left + rect.width / 2,
    y: rect.top + rect.height / 2,
    r: rect.width / 2,
  };
  if (joystickMode === "floating") {
    // Spawn under the finger; spawn and follow share the same clamp box.
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

// Clear all bits and animate home ("homing" enables the transition for the
// return trip only).
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

// Safety valve for style/mode switches while a touch is live.
const joystickForceRelease = () => {
  if (joyTouchId != null) joystickRelease();
};

joystickEl.addEventListener("touchstart", joystickTouchStart);
joystickEl.addEventListener("touchmove", joystickTouchMove);
joystickEl.addEventListener("touchend", joystickTouchEnd);
joystickEl.addEventListener("touchcancel", joystickTouchEnd);

