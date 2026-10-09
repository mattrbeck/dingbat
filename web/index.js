// Tab escape hatch: with focus in the chrome or a modal, or anywhere on the
// home screen, Tab keeps moving focus. Window capture phase, registered before em.js, so it outranks the
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
  } else if (!document.body.classList.contains("running")) {
    // The home screen: no game on show, so Tab is the page's.
    e.stopImmediatePropagation();
  }
}, true);

// Typing escape hatch: the SDL runtime's window-bubble key handlers
// preventDefault page-wide once a core runs. This sits at window-bubble too,
// registered before em.js so it runs first, and stops text-field events
// there. Bubble, not capture: the fields' own listeners must still see the
// target phase. Tab belongs to the hook above; Escape must keep flowing to
// the close-all-modals handler. On the home screen the same goes for a
// focused button or select: Enter and Space must press it (a library tile,
// from the keyboard or after the pad put focus there), not be swallowed for
// the core paused behind the page.
{
  const typingGuard = (e) => {
    if (e.code === "Tab" || e.code === "Escape") return;
    const t = e.target;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) {
      e.stopImmediatePropagation();
    } else if (t && (t.tagName === "BUTTON" || t.tagName === "SELECT") &&
               !document.body.classList.contains("running")) {
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
  //
  // The new worker claims every tab, so an Update clicked in another tab
  // lands here too: with a game in progress that reload is not this tab's
  // player's to lose. The button offers it instead (applyUpdate reloads).
  let hadController = !!navigator.serviceWorker.controller;
  let refreshing = false;
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if ((hadController || appUpdating) && !refreshing) {
      if (appUpdating || !(currentRomName || linkMode || rollbackMode || netActive())) {
        refreshing = true;
        location.reload();
      } else {
        updateActivated = true;
        showUpdateButton();
        document.getElementById("update-label").textContent = "Reload";
        updateBtn.title = "Updated in another tab: reload when you're ready";
      }
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

// current: the cached version.txt (the running build); latest: a fresh one;
// deployed: the CACHE_VERSION in a fresh sw.js. Pages' CDN propagates
// per-object, so an update is only actually fetchable once sw.js and
// version.txt agree. null when any of them can't be fetched (offline).
const probeBuilds = async () => {
  try {
    let [cachedRes, networkRes, swRes] = await Promise.all([
      fetch("version.txt"),
      fetch("version.txt", { cache: "no-store" }),
      fetch("sw.js", { cache: "no-store" }),
    ]);
    if (!cachedRes.ok || !networkRes.ok || !swRes.ok) return null;
    return {
      current: (await cachedRes.text()).trim(),
      latest: (await networkRes.text()).trim(),
      deployed: (await swRes.text()).match(/CACHE_VERSION = "([^"]+)"/)?.[1],
    };
  } catch {
    return null;
  }
};

const checkForUpdate = async () => {
  const builds = await probeBuilds();
  if (!builds) return;
  const { current, latest, deployed } = builds;
  if (current && latest && latest !== current) {
    if (deployed === latest) {
      showUpdateButton();
    } else {
      // Still propagating: skip the stamp so the next visibility change retries.
      return;
    }
  }
  try { localStorage.setItem(UPDATE_CHECK_KEY, Date.now().toString()); } catch {}
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
// Another tab's Update already put the new worker in charge of this one,
// which kept its game (controllerchange above): all that is left is the reload.
var updateActivated = false;

const applyUpdate = async () => {
  appUpdating = true;
  // Busy until the reload lands (the install downloads every asset). Never
  // un-set: every path out of here ends in a reload.
  updateBtn.disabled = true;
  updateBtn.classList.add("updating");
  document.getElementById("update-label").textContent = "Updating…";
  closeUpdateModal();
  if (updateActivated) {
    location.reload();
    return;
  }
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
    ? version + " (origin " + originVersion + " — UPDATE PENDING)"
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
  if (!t.closest("#topbar")) return;
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
  // A full disk is not always reported on the request: Safari checks its
  // quota when the transaction commits, and the only sign is the abort.
  // Settling twice is a no-op, so this is a second chance at the error and
  // not a second answer.
  tx.onabort = () => reject(tx.error || req.error);
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

// Read a record and replace it in one readwrite transaction, so nothing
// written between the read and the write is lost. `fn` runs synchronously on
// the stored value and returns the new one, or undefined to leave it.
// Resolves whether it wrote.
const dbUpdate = (key, fn) => new Promise((resolve, reject) => {
  let tx = db.transaction("blobs", "readwrite");
  let store = tx.objectStore("blobs");
  let wrote = false;
  let req = store.get(key);
  req.onsuccess = () => {
    let next = fn(req.result ?? null);
    if (next === undefined) return;
    store.put(next, key);
    wrote = true;
  };
  tx.oncomplete = () => resolve(wrote);
  tx.onerror = () => reject(tx.error);
  tx.onabort = () => reject(tx.error);
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

// Sweep auto-resume snapshots (and their pictures) whose game is neither
// stored nor in the library. The session records only: the one per-game
// pair the app regenerates itself; user-authored records (cheats) are left
// alone even when orphaned.
const sweepOrphanedAutoStates = async () => {
  let keys = await dbKeys();
  let known = new Set();
  for (let k of keys) {
    if (typeof k === "string" && k.startsWith("rom:")) known.add(k.slice(4));
  }
  for (let r of await getRecentMeta()) if (r?.name) known.add(r.name);
  for (let k of keys) {
    if (typeof k !== "string") continue;
    const prefix = ["stateauto:", "sessionpic:"].find((p) => k.startsWith(p)) ||
      k.match(CKPT_KEY_RE)?.[0];
    if (prefix && !known.has(k.slice(prefix.length))) await dbDelete(k);
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
  // The Drive controls live under General now; nothing else paints them.
  renderGdriveSection();
  kbSelection = -1;
  kbPreset.value = detectPreset(activeBindings);
  renderKbBindings();
  // Fresh open starts with Advanced folded (guarded for the pre-parse window).
  if (typeof collapseAdvanced === "function") collapseAdvanced();
  if (typeof collapseChannels === "function") collapseChannels();
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
document.getElementById("settings-btn").addEventListener("click", openSettingsModal);
for (const id of ["settings-close", "settings-close-list"]) {
  document.getElementById(id).addEventListener("click", () => closeSettingsModal());
}

// Force Update and Toggle Log hand the screen to something else, so Settings
// closes first; registered ahead of each button's own handler.
for (const id of ["force-update", "show-log"]) {
  document.getElementById(id).addEventListener("click", () => closeSettingsModal());
}

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

// --- Settings › Audio › Channels ---
// Mute single channels to hear the rest on their own: a listening aid,
// output only (APU.channel_mask). Settable with or without a game; it holds
// across game loads until turned back on, and is never saved (a reload
// clears it). Bit i mutes channel i: Square 1, Square 2, Wave, Noise, Sample
// A, Sample B (the last two GBA only). #channels-indicator shows in game
// while any is muted.
let channelMutes = 0;
const channelsToggle = document.getElementById("channels-toggle");
const channelsSub = document.getElementById("channels-sub");
const channelsFoot = document.getElementById("channels-foot");
const channelsSummary = document.getElementById("channels-summary");
const channelsIndicator = document.getElementById("channels-indicator");
const channelsIndicatorLabel = document.getElementById("channels-indicator-label");
const channelChips = [0, 1, 2, 3, 4, 5].map((i) => document.getElementById("channel-chip-" + i));
// Each group's Mute all / Turn on, with the bits it covers.
const channelGroups = [
  { btn: document.getElementById("channels-all-tone"), bits: 0b001111 },
  { btn: document.getElementById("channels-all-sample"), bits: 0b110000 },
];
const mutedCount = (bits) => {
  let n = 0;
  for (let b = bits; b; b &= b - 1) n++;
  return n;
};

const renderChannels = () => {
  channelChips.forEach((chip, i) => {
    chip.setAttribute("aria-pressed", (channelMutes >> i) & 1 ? "false" : "true");
  });
  for (const g of channelGroups) {
    g.btn.textContent = (channelMutes & g.bits) === g.bits ? "Turn on" : "Mute all";
  }
  const count = mutedCount(channelMutes);
  const what = count === 1 ? "1 channel muted" : count + " channels muted";
  channelsFoot.hidden = count === 0;
  channelsSummary.textContent = what;
  channelsIndicator.hidden = count === 0;
  channelsIndicatorLabel.textContent = String(count);
  channelsIndicator.title = "Audio: " + what;
  channelsIndicator.setAttribute("aria-label", "Audio: " + what + ". Open channels");
};

// The wasm side keeps them for every core it builds; pushed again once the
// runtime is up, for mutes set before it was.
const applyChannelMutes = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_channel_mutes) {
    Module._wasm_set_channel_mutes(channelMutes);
  }
};

const setChannelMutes = (bits) => {
  channelMutes = bits;
  applyChannelMutes();
  renderChannels();
};

const resetChannelMutes = () => setChannelMutes(0);

const setChannelsOpen = (open) => {
  channelsSub.hidden = !open;
  channelsToggle.setAttribute("aria-expanded", open ? "true" : "false");
  renderChannels();
};

// Folded on every Settings open, unless something is muted.
const collapseChannels = () => setChannelsOpen(channelMutes !== 0);

channelsToggle.addEventListener("click", () => setChannelsOpen(channelsSub.hidden));
channelChips.forEach((chip, i) => {
  chip.addEventListener("click", () => setChannelMutes(channelMutes ^ (1 << i)));
});
for (const g of channelGroups) {
  g.btn.addEventListener("click", () => {
    setChannelMutes((channelMutes & g.bits) === g.bits
      ? channelMutes & ~g.bits : channelMutes | g.bits);
  });
}
document.getElementById("channels-reset").addEventListener("click", resetChannelMutes);

channelsIndicator.addEventListener("click", () => {
  openSettingsModal();
  openSettingsSection("audio");
  setChannelsOpen(true);
  const top = channelsToggle.getBoundingClientRect().top - settingsScroll.getBoundingClientRect().top;
  settingsScroll.scrollTop += top - 12;
  channelsToggle.focus({ preventScroll: true });
});
renderChannels();

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
  refreshKeptSaveRow().catch(() => {});
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

// Save data with no library entry. Two ways in: the localStorage-era
// migration writes every save it finds, including games the old recents list
// never held; and builds before this one dropped the entry outright when the
// 20-game cap evicted the bytes. A game with a save is a game in the library
// - it comes back as a tile with no file, to be found again or deleted like
// any other, rather than bytes that nothing on screen accounts for. ts 0
// because this is a residue and not a claim: it sorts last, and a tombstone
// from another device still outranks it.
const adoptSaveOnlyGames = () => updateRecent(async (recents) => {
  let known = new Set(recents.map((r) => r?.name));
  let add = [];
  for (let name of await romsWithSaveData()) {
    if (known.has(name)) continue;
    if (syncState.tomb.some((t) => t?.name === name)) continue; // deleted elsewhere
    add.push({ name, ts: 0 });
  }
  if (add.length) return [...recents, ...add];
});

// The game held in memory: deleting its stored save would be re-persisted
// by the next autosave flush.
const isRomLoaded = (name) =>
  (!!currentOriginalName && currentOriginalName === name) ||
  (linkMode && !!linkRomEntry && linkRomEntry.name === name);

// The inventory of everything stored for one game. Every destructive path
// works from this; a record not listed here survives a delete.
//   bytes    ROM image, box art and the last-frame thumbnail (ROM and
//            frame are mirrored on Drive; the frame is also regenerated the
//            next time the game runs, and Remove from device keeps it)
//   saves    battery saves (P1 + 2P partner) and the nine state slots with
//            their meta; the only group Drive mirrors besides the ROM
//   session  the auto-resume snapshot and its picture; the snapshot is
//            mirrored (its picture riding in it), the hand-off between devices
//   checkpoints  earlier moments of play and their index (Resume from
//            earlier); this device only, and they go with the session
//            wherever the progress goes, but not when a kept save is restored
//   prefs    the cheat list; never synced
//   kept     a save from before the game was deleted and loaded again
//            (keptSaveKey), mirrored; a save reset leaves it, being a way
//            back rather than the game's progress
const perGameKeys = (name) => {
  let saves = ["save:" + name, "save:" + name + "-p2"];
  // Slot 0 is the legacy un-suffixed "state:<name>" / "statemeta:<name>" pair.
  for (let s = 0; s < NUM_STATE_SLOTS; s++) {
    saves.push(slotStateKey(name, s), slotMetaKey(name, s));
  }
  return {
    bytes: [romKey(name), artKey(name), frameKey(name)],
    saves,
    session: [autoStateKey(name), sessionPicKey(name)],
    checkpoints: ckptKeys(name),
    prefs: [CHEATS_KEY(name)],
    kept: [keptSaveKey(name)],
  };
};

const allPerGameKeys = (name) => Object.values(perGameKeys(name)).flat();

const deleteKeys = async (keys) => {
  for (let k of keys) {
    // In the segment that issues the delete: a persist of this save waiting
    // on a quota eviction must not put it back (persistSeq).
    if (k.startsWith("save:")) retireSavePuts(k.slice(5));
    // A checkpoint packing meanwhile must not write the session back.
    if (k.startsWith("stateauto:")) {
      const g = k.slice(10);
      sessionEpochs.set(g, sessionEpoch(g) + 1);
    }
    await dbDelete(k);
  }
};

// Remove one ROM's save data. The auto-resume snapshot goes with it: it is
// a full save state, and "Resume" would restore the wiped progress.
const deleteSaveData = async (name) => {
  let k = perGameKeys(name);
  await deleteKeys([...k.saves, ...k.session, ...k.checkpoints]);
};

// Remove every trace of one game from this device. Drive is untouched here.
const deleteGameLocalData = async (name) => {
  await deleteKeys(allPerGameKeys(name));
};

// Wipe the running game's battery save and reboot it; state slots stay.
const resetCurrentSaveFile = async () => {
  // Detached before the first delete, so the autosave cannot re-flush it.
  const game = detachLoadedGame();
  if (!game) return;
  const name = game.originalName;
  retireSavePuts(name); // as deleteKeys
  // Queued before the first await, as resetGameSaves does: a pull that is
  // downloading this save checks the queue before writing it back, and
  // would otherwise land it in these awaits (bug_file_reset_undone_by_pull).
  markDelete("save:" + name);
  markDelete("save:" + name + "-p2");
  markDelete(autoStateKey(name));
  await dbDelete("save:" + name);
  await dbDelete("save:" + name + "-p2");
  // The reboot ends in offerAutoResume, which would offer to un-reset.
  await deleteKeys([...perGameKeys(name).session, ...perGameKeys(name).checkpoints]);
  loadRom(game.romName, name);
};

// Detach the loaded game ahead of deleting its stored save: drop its FS .sav
// and null its names, so no flush path can write the in-memory save back -
// neither the 5 s autosave landing between the deletes nor loadRom's
// "persist the outgoing game" step at the reboot. It also takes the load
// token, so no load or close in flight finishes on it. Returns the names to
// reboot under (loadRom), or null when no game is loaded.
const detachLoadedGame = () => {
  if (!currentRomName || !currentOriginalName) return null;
  clearPlaying();
  const game = { romName: currentRomName, originalName: currentOriginalName };
  nextLoadGen();
  try { FS.unlink(stripExt(game.romName) + ".sav"); } catch {}
  currentRomName = null;
  currentOriginalName = null;
  return game;
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

// A kept save (see genOf) for the loaded game: shown only while there is
// one, with when it was saved and how long it stays.
const keptSaveRow = document.getElementById("kept-save-row");
const keptSaveBtn = makeConfirmButton({
  label: "Restore",
  confirmLabel: "Replace current save?",
  className: "button button-sm",
  onConfirm: async () => {
    let game = currentOriginalName;
    if (game) await restoreKeptSave(game);
    keptSaveBtn.disabled = false;
    keptSaveBtn.disarm();
    closeSavesModal();
  },
});
document.getElementById("kept-save-slot")?.appendChild(keptSaveBtn);
const refreshKeptSaveRow = async () => {
  if (!keptSaveRow) return;
  let game = currentOriginalName;
  let rec = game ? await getKeptSave(game) : null;
  if (game !== currentOriginalName) return; // another game since
  keptSaveRow.hidden = !rec;
  if (!rec) return;
  document.getElementById("kept-save-label").textContent = keptSaveTitle(rec);
  document.getElementById("kept-save-sub").textContent = keptSaveSub(rec);
};


// --- Library sort + filter --------------------------------------------------
// One sort, shared by the home grid and the Manage list and kept in
// "roms_sort": "recent" is play order (the index's own order), "alpha" the
// name, "system" GBA / GBC / GB then the name. The filters are for the
// session: a search string, a set of systems (empty = every system) and a
// location (all / device / drive). Filtering hides tiles in place rather
// than re-rendering, so the grid never rebuilds under a finger.
const LIB_SORTS = ["recent", "alpha", "system"];
let romsSort = "recent";
const libSortSel = /** @type {HTMLSelectElement} */ (document.getElementById("lib-sort"));
const libSearch = /** @type {HTMLInputElement} */ (document.getElementById("lib-search"));
const libChips = document.getElementById("lib-chips");
const libCountEl = document.getElementById("lib-count");
const libBar = document.getElementById("lib-bar");
const libNone = document.getElementById("lib-none");
let libFilter = { q: "", systems: new Set(), loc: "all" };

const loadRomsSort = async () => {
  let v = await dbGet("roms_sort");
  if (LIB_SORTS.includes(v)) romsSort = v;
  syncLibSort();
};
const syncLibSort = () => { if (libSortSel) libSortSel.value = romsSort; };
const setRomsSort = async (v) => {
  if (!LIB_SORTS.includes(v) || v === romsSort) return;
  romsSort = v;
  syncLibSort();
  await dbPut("roms_sort", v);
  refreshHomeRecent();
};
if (libSortSel) libSortSel.addEventListener("change", () => setRomsSort(libSortSel.value));

const SYSTEM_ORDER = { GBA: 0, GBC: 1, GB: 2 };
// Rows carry .name; "recent" keeps the order given (the index's).
const sortRoms = (rows) => {
  if (romsSort === "alpha") return [...rows].sort((a, b) => a.name.localeCompare(b.name));
  if (romsSort === "system") {
    return [...rows].sort((a, b) =>
      (SYSTEM_ORDER[systemOf(a.name)] - SYSTEM_ORDER[systemOf(b.name)]) ||
      a.name.localeCompare(b.name));
  }
  return rows;
};

// Search is forgiving. Names and the query are folded to lowercase letters
// and digits (spaces, apostrophes, dashes and the like never matter, so
// "firered", "fire red" and "Fire-Red" are one thing). Every word of the
// query must land somewhere in the name, in any order. A word of three or
// more characters that lands nowhere as a run still matches if its
// characters appear in order ("pokmon", "zlda", "adwars"); shorter words
// stay exact, or "ar" would match most of a library.
const libFold = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, "");
const libSubsequence = (needle, hay) => {
  let i = 0;
  for (let j = 0; j < hay.length && i < needle.length; j++) if (hay[j] === needle[i]) i++;
  return i === needle.length;
};
const libWordMatches = (word, foldedName) =>
  foldedName.includes(word) || (word.length >= 3 && libSubsequence(word, foldedName));
// `q` is the raw search string; `foldedName` a folded display name.
const libSearchMatch = (q, foldedName) => {
  let words = String(q).toLowerCase().split(/\s+/).map(libFold).filter(Boolean);
  if (!words.length) return true;
  if (words.every((w) => libWordMatches(w, foldedName))) return true;
  // "fire red" typed as two words is also "firered" typed as one.
  let joined = words.join("");
  return words.length > 1 && libWordMatches(joined, foldedName);
};

const libTileMatches = (tile) => {
  let f = libFilter;
  if (f.q && !libSearchMatch(f.q, tile.dataset.name)) return false;
  if (f.systems.size && !f.systems.has(tile.dataset.system)) return false;
  if (f.loc !== "all" && tile.dataset.loc !== f.loc) return false;
  return true;
};

// How many columns the grid should draw. A library smaller than the row it
// sits in gets only the columns it fills, so the head is ruled over its own
// tiles instead of across an empty half-screen. styles.css reads the count
// and works out the rest: which breakpoints are wide enough to narrow at,
// the floor that keeps the search field and the chips usable, and the cap
// that stops one game being blown up to fill that floor.
//
// The library's own size, not the filter's: a search that narrowed the
// block would resize the field being typed into, and a chip would move the
// chip next to it. Filtering changes which tiles show, not how wide the
// library is.
const LIB_FIT_MAX = 5;
// On #home-inner, not the wrap: the paused card reads the same width tokens
// and is the wrap's sibling, so their common parent is where they live.
const setLibFit = (count) => {
  if (!homeInner) return;
  if (count > LIB_FIT_MAX) delete homeInner.dataset.n;
  else homeInner.dataset.n = String(Math.max(1, count));
};

// The hero shows one game, and that game is shown once. Its tile stands down
// from the grid (.is-current, hidden by styles.css unless a search or filter
// is running - asked for by name, it must be found), and a library holding
// nothing but that game folds away entirely (body.home-solo): the hero IS the
// library then, with a quiet way to add a second game under it. The same at
// every width - on a phone the same game twice, one above the other, read as
// two things.
let libNames = []; // the library as refreshHomeRecent last saw it
let heroName = null; // the game the hero is showing, while it is up

const syncHomeCurrent = () => {
  const cur = document.body.classList.contains("home-card") ? heroName : null;
  const inLib = !!cur && libNames.includes(cur);
  document.body.classList.toggle("home-solo", inLib && libNames.length === 1);
  for (let t of /** @type {HTMLCollectionOf<HTMLElement>} */ (homeRecent.children)) {
    if (t.classList.contains("home-tile")) t.classList.toggle("is-current", t.dataset.rom === cur);
  }
  // The stood-down tile is not a cell.
  setLibFit(libNames.length - (inLib ? 1 : 0));
};

// Hide the tiles the filter excludes; the count and the empty note follow.
const applyLibFilter = () => {
  let shown = 0, total = 0;
  for (let t of /** @type {HTMLCollectionOf<HTMLElement>} */ (homeRecent.children)) {
    if (!t.classList.contains("home-tile")) continue;
    total++;
    let m = libTileMatches(t);
    t.hidden = !m;
    if (m) shown++;
  }
  if (libNone) libNone.hidden = !(total > 0 && shown === 0);
  // A search or filter brings the paused game's tile back (syncHomeCurrent).
  document.body.classList.toggle("lib-filtering", libFilterActive());
  if (libCountEl) {
    libCountEl.textContent = shown === total
      ? total + (total === 1 ? " game" : " games")
      : shown + " of " + total;
  }
};

// The chips: one per system present (only when there is more than one),
// then, signed in with games on both sides, "On device" / "On Drive". The
// counts are desktop detail (styles.css hides them on phones).
const renderLibChips = (roms, localRoms) => {
  if (!libChips) return;
  let counts = { GBA: 0, GBC: 0, GB: 0 };
  let local = 0;
  let onDrive = 0;
  for (let { name } of roms) {
    counts[systemOf(name)]++;
    if (localRoms.has(name)) local++;
    else if (driveHasRom(name)) onDrive++;
  }
  let systems = Object.keys(SYSTEM_ORDER).filter((s) => counts[s] > 0);
  // A system that left the library leaves the filter too.
  for (let s of libFilter.systems) if (!counts[s]) libFilter.systems.delete(s);
  let chips = [];
  const chip = (label, n, pressed, cls, onTap) => {
    let b = document.createElement("button");
    b.type = "button";
    b.className = "lib-chip " + cls;
    b.setAttribute("aria-pressed", pressed ? "true" : "false");
    b.textContent = label;
    if (n != null) {
      let c = document.createElement("span");
      c.className = "lib-chip-n";
      c.textContent = String(n);
      b.appendChild(c);
    }
    b.addEventListener("click", () => { onTap(); renderLibChips(roms, localRoms); applyLibFilter(); });
    chips.push(b);
    return b;
  };
  if (systems.length > 1) {
    for (let s of systems) {
      chip(s, counts[s], libFilter.systems.has(s), "lib-chip-sys", () => {
        if (libFilter.systems.has(s)) libFilter.systems.delete(s);
        else libFilter.systems.add(s);
      }).dataset.sys = s; // the pad's LB/RB step through these
    }
  }
  // A game whose file is neither here nor on Drive is on neither side of
  // this choice, so neither chip counts it and neither filter shows it.
  if (driveLinked() && local > 0 && onDrive > 0) {
    chip("On device", local, libFilter.loc === "device", "lib-chip-loc",
      () => { libFilter.loc = libFilter.loc === "device" ? "all" : "device"; });
    chip("On Drive", onDrive, libFilter.loc === "drive", "lib-chip-loc",
      () => { libFilter.loc = libFilter.loc === "drive" ? "all" : "drive"; });
  } else if (libFilter.loc !== "all") {
    libFilter.loc = "all"; // the choice no longer exists
  }
  libChips.replaceChildren(...chips);
};

if (libSearch) {
  const clearLibSearch = () => {
    libSearch.value = "";
    libFilter.q = "";
    applyLibFilter();
  };
  libSearch.addEventListener("input", () => {
    libFilter.q = libSearch.value.trim();
    applyLibFilter();
  });
  libSearch.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && libSearch.value) {
      e.stopPropagation(); // clears the field; does not close anything
      clearLibSearch();
    }
  });
  // Back in the field afterwards, as the native clear leaves it.
  document.getElementById("lib-search-clear")?.addEventListener("click", () => {
    clearLibSearch();
    libSearch.focus();
  });
}

// Drive confirmed to hold this game's ROM, with no delete queued. Two ways
// of knowing, and both count: this device uploaded it (sigs), or a pull saw
// it in the listing (rmt). Only the second covers a ROM that was already on
// Drive when this device got the file - it uploads nothing, so it would
// otherwise never learn there is a copy to fall back on. A just-imported
// game whose upload is still queued has neither, so the only copy is never
// evictable. Both can go stale, so removeGameFromDevice re-checks the live
// listing before deleting.
//
// Enrolled, not linked: a signed-out device still knows what its account's
// Drive holds, and a tile has to say where its file is whether or not there
// is a token this minute. The one caller that needs a live session - Remove
// from this device, which is about to free the only local copy - adds that
// condition itself.
const driveHasRom = (name) =>
  driveEnrolled() &&
  (!!syncState.sigs[romKey(name)] || !!syncState.rmt[romKey(name)]) &&
  !syncState.queueDel.includes(romKey(name));

// What a game's management options key off, from the two inventories the
// callers already hold (this device's ROMs; the games with save data).
// Shared by the Manage rows and the tile menu, so the two never disagree
// about what a game can do.
const gameFlags = (name, localRoms, withSaves) => {
  let linked = driveLinked();
  let stateKeyOfGame = (k) =>
    k === "state:" + name || k.startsWith("state:" + name + ":slot");
  let savesOnDrive = linked && Object.keys(syncState.rmt || {}).some(
    (k) => k === "save:" + name || k === "save:" + name + "-p2" || stateKeyOfGame(k));
  return {
    linked,
    driveOnly: !localRoms.has(name),
    // No bytes here and no copy to fetch: the file has to come back from the
    // user's own disk, so every surface that would offer a download offers
    // to find it instead.
    missing: !localRoms.has(name) && !driveHasRom(name),
    hasSaves: withSaves.has(name) || savesOnDrive,
    hasLocalSaves: withSaves.has(name),
    romOnDrive: linked && driveHasRom(name),
    loaded: isRomLoaded(name),
    // A game in a session that cannot just be closed: an online link, or
    // the same-browser 2P rig behind ?2p. Two cores are writing this game's
    // saves, and unloadGame refuses outright, so every action that touches
    // its files waits for the session to end.
    busy: isRomLoaded(name) && (linkMode || rollbackMode || netActive()),
    downloading: syncDownloading.has(name),
  };
};

const localRomSet = async () => {
  let s = new Set();
  for (let k of await dbKeys()) {
    if (typeof k === "string" && k.startsWith("rom:")) s.add(k.slice(4));
  }
  return s;
};

// The four per-game actions, each with its toast and refreshes; the Manage
// rows and the tile menu both call these.
// Reset = wipe save data, keep the ROM.
const resetGameAction = async (name) => {
  const loaded = isRomLoaded(name);
  // Detached before the deletes, else the in-memory save re-flushes.
  const game = currentOriginalName === name ? detachLoadedGame() : null;
  await resetGameSaves(name);
  if (loaded) {
    if (game) loadRom(game.romName, game.originalName); // no .sav, no save: fresh
    showToast("Save data deleted — starting fresh");
  } else {
    showToast("Save data deleted");
    updateStorageInfo();
  }
};
// unloadGame refused: a link session holds the game, or a load that started
// after the close took over from it (loadGen) - then the game was not closed
// here, and the load persists it as the outgoing one. Say which.
const unloadRefused = (what) => showToast(linkMode || rollbackMode || netActive()
  ? "Exit the online session first"
  : "Not " + what + " — another game started loading");
// Remove from device = free this device's ROM bytes, keep saves and the
// Drive copy.
const removeFromDeviceAction = async (name) => {
  // Unlike Delete, the save is being kept, so it is flushed on the way out.
  if (isRomLoaded(name) && !(await unloadGame({ flushSave: true }))) {
    unloadRefused("removed");
    return;
  }
  if (await removeGameFromDevice(name)) {
    showToast("ROM removed from this device — save kept, still on Drive");
  }
  refreshHomeRecent();
  updateStorageInfo();
};
// Download = the inverse (downloadGame). Signs in first when needed, with
// the progress on the game's tile (fetchTileGame).
const downloadGameAction = async (name) => {
  let ok = await fetchTileGame(name);
  if (ok) showToast("Synced to this device");
  refreshHomeRecent();
  updateStorageInfo();
  return ok;
};
// Find the file = the same inverse, from the user's own disk. The bytes are
// stored under the entry's name, never the picked file's: the game keeps its
// save, its picture and its place, which is the whole point of asking. Two
// guards first, because pairing the wrong ROM with a save is how a save gets
// written over - the extension has to match, being what decides the system,
// and so does a size noted before the file left.
const relinkGameAction = (name, { launch = false } = {}) => {
  let want = extOf(name);
  pickFile(ROM_EXTS.join(","), async (bytes, fileName) => {
    if (extOf(fileName) !== want) {
      showToast("“" + displayName(name) + "” needs a " + want + " file");
      return;
    }
    let was = romSizeOf(name);
    if (was && was !== bytes.length && !(await askRomWarn(
      "A Different File",
      `"${fileName}" is ${formatBytes(bytes.length)}, but “${displayName(name)}” ` +
      `was ${formatBytes(was)}. Another game's ROM will not match the save kept ` +
      `here, and playing it would write over that save. Use it anyway?`))) return;
    if (!looksLikeValidRom(bytes, want) &&
        !(await confirmSuspectRom(fileName, want))) return;
    await dbPut(romKey(name), { name, data: bytes });
    await noteRomSize(name, bytes.length);
    markGameUpload(name); // the account's only copy may be this one again
    showToast("“" + displayName(name) + "” is back on this device");
    refreshHomeRecent();
    updateStorageInfo();
    if (launch) launchRom(name);
  });
};
// Delete = ROM + saves, tombstoned on Drive when signed in. The game in
// memory is unloaded first (unloadGame detaches it from the autosave flush).
const deleteGameAction = async (name) => {
  if (isRomLoaded(name)) {
    // Unload before deleting: nulling currentRomName keeps the autosave
    // from re-flushing over the deleted key. No final flush.
    if (!(await unloadGame({ flushSave: false }))) {
      unloadRefused("deleted");
      return false;
    }
  }
  await deleteGameEverywhere(name);
  showToast(driveLinked() ? "Deleted from all your devices"
                          : "Removed from this browser");
  refreshHomeRecent();
  updateStorageInfo();
  return true;
};


// --- Google Drive backup ---
// Battery saves, save states and ROMs in the hidden appDataFolder, via the
// GIS token flow (no backend, no client secret), upgraded to refresh tokens
// when the token broker answers (see driveCodeGrant). Drive file names mirror
// the IndexedDB keys one-to-one; the folder listing is the index (no
// manifest), matched by name client-side.
// The client ID is public by design (the token flow has no secret): the
// Cloud Console's "Authorized JavaScript origins" allowlist and the
// drive.appdata scope are the protection. localStorage "gdrive_client_id"
// overrides it for dev; empty degrades the Drive section to "not configured".
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

const adoptGrantedToken = (resp) => {
  gdriveToken = resp.access_token;
  // 60s margin so a token never expires mid-request.
  gdriveTokenExp = Date.now() + ((Number(resp.expires_in) || 3600) - 60) * 1000;
  persistDriveToken();
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

// The Drive session. Everything Drive work does after an await rests on the
// token and the loaded account state being the ones it started with, and
// Sign out and Sign in change both while a flush, a pull or a renewal popup
// is still out. So each of those takes a new session number: Sign out,
// the grant a sign-in receives (it may be another account), the sign-in's
// end, and a switch of the loaded account (adoptDriveAccount). Work checks
// the number after every await (driveSessionGuard) and stops when it moved.
let driveSession = 0;
// gdriveConnect calls between asking for a token and knowing whose it is.
// Nothing syncs meanwhile (syncActive): the token may be another account's
// while the loaded state is still the last one's.
let driveConnecting = 0;
// A sign-in is waiting on the token request in flight (it made it, or joined
// the one it found). Only then may a grant start a new session.
let gdriveTokenForConnect = false;
class DriveSessionEnded extends Error {}
const driveSessionGuard = () => {
  const at = driveSession;
  return (v) => {
    if (driveSession !== at) throw new DriveSessionEnded("The Drive session ended");
    return v;
  };
};

// promptMode "" = silent refresh; undefined = the account-chooser popup.
// login_hint skips account selection: without it a browser signed in to
// more than one Google account shows the chooser on every re-grant.
const gdriveAcquireToken = (promptMode, hint = syncState.email, { connect = false } = {}) => {
  if (gdriveTokenInFlight) {
    if (connect) gdriveTokenForConnect = true;
    return gdriveTokenInFlight;
  }
  const issued = driveSession;
  gdriveTokenForConnect = connect;
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
        // A grant is only as good as the session that asked for it. The tap
        // on "Sign out" can itself open the renewal popup (the capture
        // listener runs first), and its answer lands after the sign-out:
        // kept, it would sign the tab back in behind the person's back and
        // sync on. A sign-in waiting on this request is what asks for a
        // grant while signed out; the grant may be another account, so it
        // starts a new session there and then.
        if (gdriveTokenForConnect) driveSession++;
        else if (!syncState.connected || issued !== driveSession) {
          reject(new Error("Signed out of Google Drive"));
          return;
        }
        adoptGrantedToken(resp);
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

// --- Refresh-token sign-in through the token broker ------------------------
// The token flow above has no refresh token, so every renewal is a popup.
// The signaling server doubles as a token broker (web/signaling/server.js):
// one consent popup on the authorization-code flow buys a refresh token,
// kept in syncState, and renewals become a plain fetch with no gesture. The
// broker holds the client secret and nothing else. It is often down, and
// every path then falls back to the popup flow above, unchanged.
const DRIVE_OAUTH_CHANNEL = "dingbat-oauth"; // oauth-callback.html posts here
const DRIVE_BROKER_RETRY_MS = 60 * 1000;     // after a failure, popups own renewal this long
const DRIVE_CODE_WAIT_MS = 5 * 60 * 1000;    // an abandoned consent popup gives up

// Same host as the signaling socket (netplay.js decides: prod, LAN or
// ?signal=), over http(s). "" when netplay.js is not loaded.
const driveBrokerBase = () => {
  if (typeof NET_SIGNAL_URL === "undefined") return "";
  let m = /^(wss?):\/\/([^/?#]+)/.exec(NET_SIGNAL_URL);
  return m ? (m[1] === "wss" ? "https://" : "http://") + m[2] : "";
};

// fetch with a deadline; AbortSignal.timeout is too new for iOS 15.
const fetchWithin = (url, opts, ms) => {
  let ctl = typeof AbortController === "function" ? new AbortController() : null;
  let t = ctl && setTimeout(() => ctl.abort(), ms);
  return fetch(url, { ...opts, signal: ctl?.signal })
    .finally(() => { if (t) clearTimeout(t); });
};

// text/plain keeps it a CORS "simple" request: no preflight round trip.
const driveBrokerPost = async (path, body) => {
  let r = await fetchWithin(driveBrokerBase() + path, {
    method: "POST",
    headers: { "Content-Type": "text/plain" },
    body: JSON.stringify(body),
    cache: "no-store",
  }, 8000);
  let j = null;
  try { j = await r.json(); } catch {}
  return { status: r.status, j };
};

// Whether the broker is configured and reachable; cached for a minute.
let driveBrokerOk = false;
let driveBrokerProbedAt = 0;
const probeDriveBroker = async () => {
  let base = driveBrokerBase();
  if (!base || !GDRIVE_CLIENT_ID) return false;
  if (Date.now() - driveBrokerProbedAt < 60 * 1000) return driveBrokerOk;
  driveBrokerProbedAt = Date.now();
  try {
    let r = await fetchWithin(base + "/oauth", { cache: "no-store" }, 3000);
    driveBrokerOk = r.ok && (await r.json())?.oauth === true;
  } catch {
    driveBrokerOk = false;
  }
  return driveBrokerOk;
};

// A new access token from the stored refresh token, no popup. False when
// there is none, the broker is down (retried after DRIVE_BROKER_RETRY_MS
// unless forced), or Google says the grant is gone (then it is dropped and
// this device is back on popups).
let driveBrokerRetryAt = 0;
let driveRefreshInFlight = null;
// A refresh token is used only for the account it was granted for. One kept
// from before refreshAcct existed has none recorded, and a device that has
// not learned its own account has nothing to hold it against: both are
// trusted as before.
const driveRefreshUsable = () => !!syncState.refresh &&
  (syncState.refreshAcct == null || !syncState.acct ||
   syncState.refreshAcct === syncState.acct);
const driveRefreshSilently = ({ force = false } = {}) => {
  if (!driveRefreshUsable() || !driveBrokerBase()) return Promise.resolve(false);
  if (!force && Date.now() < driveBrokerRetryAt) return Promise.resolve(false);
  driveRefreshInFlight ??= (async () => {
    const rt = syncState.refresh;
    const issued = driveSession;
    // Signed out, or in again, while the fetch was out: the answer is the
    // old session's and is refused, as a popup's is.
    const stale = () => !syncState.connected || issued !== driveSession;
    try {
      let { status, j } = await driveBrokerPost("/oauth/refresh", { refresh_token: rt });
      if (stale()) return false;
      if (status === 200 && j?.access_token) {
        driveBrokerOk = true;
        adoptGrantedToken(j);
        return true;
      }
      // The grant is gone: signed out everywhere, or expired unused. This
      // device is signed out too, not left to pop a sign-in on a tap.
      if (status === 400 && j?.error === "invalid_grant" && syncState.refresh === rt) {
        gdriveSignOut({ message: "Signed out of Google Drive — sign in again to keep syncing" });
        return false;
      }
    } catch {}
    driveBrokerRetryAt = Date.now() + DRIVE_BROKER_RETRY_MS;
    return false;
  })().finally(() => { driveRefreshInFlight = null; });
  return driveRefreshInFlight;
};

const base64Url = (bytes) =>
  btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const randomUrlToken = () => base64Url(crypto.getRandomValues(new Uint8Array(32)));

// The code arrives from oauth-callback.html by whichever route survives:
// window.opener (unless Google's pages severed it), a BroadcastChannel, or a
// localStorage write (the storage event). A newer attempt cancels this one.
let driveCodeCancel = null;
const waitForDriveCode = (state, popup) => new Promise((resolve, reject) => {
  driveCodeCancel?.(new Error("Sign-in was canceled"));
  let channel = null;
  let focusTimer = null;
  const finish = (fn, v) => {
    clearTimeout(timer);
    clearTimeout(focusTimer);
    window.removeEventListener("message", onMessage);
    window.removeEventListener("storage", onStorage);
    window.removeEventListener("focus", onFocus);
    try { channel?.close(); } catch {}
    driveCodeCancel = null;
    fn(v);
  };
  const onResult = (d) => {
    if (!d || d.type !== DRIVE_OAUTH_CHANNEL || d.state !== state) return;
    if (d.code) finish(resolve, d.code);
    else finish(reject, new Error(d.error === "access_denied"
      ? "Sign-in was canceled" : "Google sign-in failed: " + d.error));
  };
  const onMessage = (e) => { if (e.origin === location.origin) onResult(e.data); };
  const onStorage = (e) => {
    if (e.key !== DRIVE_OAUTH_CHANNEL || !e.newValue) return;
    try { onResult(JSON.parse(e.newValue)); } catch {}
  };
  // Focus coming back with the popup gone and no code: the user closed it.
  // (A severed opener reads the popup as closed throughout, hence the grace.)
  const onFocus = () => {
    clearTimeout(focusTimer);
    focusTimer = setTimeout(() => {
      if (popup.closed) finish(reject, new Error("Sign-in was canceled"));
    }, 3000);
  };
  const timer = setTimeout(() => finish(reject, new Error("Sign-in timed out")),
    DRIVE_CODE_WAIT_MS);
  driveCodeCancel = (err) => finish(reject, err);
  window.addEventListener("message", onMessage);
  window.addEventListener("storage", onStorage);
  window.addEventListener("focus", onFocus);
  try {
    channel = new BroadcastChannel(DRIVE_OAUTH_CHANNEL);
    channel.onmessage = (e) => onResult(e.data);
  } catch {}
});

// The one consent popup: authorization-code flow with offline access, so
// the broker's exchange returns a refresh token. prompt=consent because
// Google only issues a refresh token when the consent screen is shown (a
// second device would otherwise get none). Must run inside a user gesture.
// Session rules as gdriveAcquireToken: a sign-in's grant starts a new
// session; any other grant is refused if the session ended meanwhile.
const driveCodeGrant = async (hint, { connect = false } = {}) => {
  const issued = driveSession;
  let popup = window.open("", "dingbat-google-signin", "popup,width=500,height=650");
  if (!popup) throw new Error("Popup blocked — allow popups for this site and try again");
  let redirectUri = new URL("oauth-callback.html", location.origin + location.pathname).href;
  let state = randomUrlToken();
  let verifier = randomUrlToken();
  let challenge = "";
  try {
    let digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
    challenge = base64Url(new Uint8Array(digest));
  } catch {
    verifier = ""; // no SubtleCrypto (plain-http LAN dev): the secret still guards the code
  }
  let q = new URLSearchParams({
    client_id: GDRIVE_CLIENT_ID,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: GDRIVE_SCOPE,
    access_type: "offline",
    prompt: hint ? "consent" : "select_account consent",
    include_granted_scopes: "true",
    state,
  });
  if (challenge) {
    q.set("code_challenge", challenge);
    q.set("code_challenge_method", "S256");
  }
  if (hint) q.set("login_hint", hint);
  popup.location.href = "https://accounts.google.com/o/oauth2/v2/auth?" + q;
  let code = await waitForDriveCode(state, popup);
  let { status, j } = await driveBrokerPost("/oauth/exchange",
    { code, code_verifier: verifier, redirect_uri: redirectUri });
  if (status !== 200 || !j?.access_token) {
    throw new Error("Google sign-in failed" + (j?.error ? ": " + j.error : ""));
  }
  // Whose grant this is, learned before anything is adopted. A re-grant
  // for the linked account can come back as another (the consent screen
  // lets the person pick), and the next sync would write this library into
  // that account's Drive (bug_consent_regrant_crosses_accounts). A sign-in's
  // is kept beside its refresh token (refreshAcct).
  let sub = await driveTokenSub(j.access_token);
  if (connect) driveSession++;
  else {
    if (!syncState.connected || issued !== driveSession) {
      throw new Error("Signed out of Google Drive");
    }
    if (syncState.acct && sub !== syncState.acct) {
      throw new Error(sub
        ? "That's a different Google account — choose " +
          (syncState.email || "the one this library is linked to")
        : "Couldn't confirm which Google account signed in — try again");
    }
  }
  adoptGrantedToken(j);
  // Replaced even when none came back: one kept from before may belong to
  // another account.
  syncState.refresh = j.refresh_token || null;
  // "" when the account could not be learned: such a token is never used.
  syncState.refreshAcct = sub || "";
  driveBrokerRetryAt = 0;
  await saveSyncState();
};

// A device signed in on the popup flow is moved onto the broker at its next
// tap once the broker answers: the consent screen once, then no more
// popups. A decline, or a trip that never came back (a home-screen app the
// callback cannot reach), rests the offer a day so it is never a popup per
// tap; the token flow renews meanwhile.
const DRIVE_UPGRADE_REST_MS = 24 * 60 * 60 * 1000;
class DriveUpgradeDeclined extends Error {}
const driveWantsUpgrade = () =>
  // Not "no refresh token": one this device may not use (another
  // account's, or of unknown account) leaves it on popups, so it is offered.
  !!GDRIVE_CLIENT_ID && !!syncState.connected && !driveRefreshUsable() &&
  driveBrokerOk && !!driveBrokerBase() &&
  Date.now() >= (syncState.upgradeRestUntil || 0);

// The popup re-grant for a linked account: the consent screen that ends
// the popups when it can be had, else the token flow's silent re-grant.
// Must run inside a user gesture.
const driveRegrantPopup = async () => {
  if (!driveWantsUpgrade()) return gdriveAcquireToken("");
  let failure = null;
  try { await driveCodeGrant(syncState.email); }
  catch (e) { failure = e; }
  if (failure || !syncState.refresh) {
    syncState.upgradeRestUntil = Date.now() + DRIVE_UPGRADE_REST_MS;
    saveSyncState();
  }
  if (failure) throw new DriveUpgradeDeclined(failure.message);
};

// The account a token was granted for (tokeninfo's `sub`), or null when it
// could not be learned. Adopts nothing.
const driveTokenSub = async (tok) => {
  try {
    let res = await fetch("https://oauth2.googleapis.com/tokeninfo?access_token=" +
                          encodeURIComponent(tok));
    if (!res.ok) return null;
    let info = await res.json();
    return typeof info.sub === "string" ? info.sub : null;
  } catch { return null; }
};

// Works because GDRIVE_SCOPE includes "email".
// tokeninfo carries the account's stable subject id beside the address.
// `sub` is what the queues hang on: it is not an address, so it can outlive
// sign-out without leaving one behind, and it survives the user changing
// their email, which a hash of that email would not.
// Resolves to the account id, or null when it could not be learned.
const gdriveFetchEmail = async () => {
  let tok = gdriveToken;
  try {
    let res = await fetch(
      "https://oauth2.googleapis.com/tokeninfo?access_token=" +
        encodeURIComponent(tok),
    );
    if (!res.ok) return null;
    let info = await res.json();
    // The tab holds another token by now (signed out, or in as someone
    // else): this answer is about an account it no longer holds.
    if (gdriveToken !== tok) return null;
    rememberDriveEmail(info.email);
    let sub = typeof info.sub === "string" ? info.sub : null;
    await adoptDriveAccount(sub);
    return sub;
  } catch { return null; }
};

// Authenticated fetch; on a 401 one silent re-grant and replay. The re-grant
// needs a user gesture, and most 401s arrive on the background poll, so a
// failure here does not sign out: it drops the token and hands off to the
// gesture-armed renewal.
const driveFetch = async (url, opts = {}) => {
  const live = driveSessionGuard();
  const send = () => fetch(url, {
    ...opts,
    headers: { ...(opts.headers || {}), Authorization: "Bearer " + gdriveToken },
  });
  let res = await send();
  if (res.status === 401) {
    const wasLinked = driveLinked();
    try {
      // Signed out since the request left: no re-grant, the answer is refused.
      if (!driveLinked()) throw new Error("signed out");
      if (!(await driveRefreshSilently({ force: true }))) {
        if (!driveLinked()) throw new Error("signed out");
        if (!hasUserActivation()) throw new Error("no activation for a popup");
        await driveRegrantPopup();
      }
    } catch {
      // The grant was gone, and this device has just signed itself out.
      if (wasLinked && !driveLinked()) throw new Error("Signed out of Google Drive");
      clearDriveToken();
      armDriveRenewOnGesture();
      renderGdriveSection();
      // Not "sign in again": the account stays linked, the next gesture
      // picks up a token.
      throw new Error("Drive is reconnecting — your changes are saved");
    }
    // Replayed only in the session it was first sent in: the re-grant may
    // have been answered for whoever signed in since.
    live();
    res = await send();
  }
  // Drive asking to slow down, or briefly failing: sent again after a wait
  // (driveRetryWait) rather than failing the whole sync to "Offline" - a sync
  // keeps several requests in flight (SYNC_PARALLEL), so a burst can meet
  // Drive's per-user rate limit. Again only in the session it began in.
  for (let attempt = 0; !res.ok && attempt < DRIVE_RETRIES; attempt++) {
    let wait = await driveRetryWait(res, opts.method || "GET", attempt);
    if (wait === null) break;
    await new Promise((r) => setTimeout(r, wait));
    live();
    res = await send();
  }
  if (!res.ok) throw new Error("Drive request failed (HTTP " + res.status + ")");
  return res;
};

// How many times, and from what first wait, a refused Drive request is sent
// again; the wait doubles each time.
const DRIVE_RETRIES = 3;
let driveRetryMs = 500;
// The wait before sending `res`'s request again, or null when it is not one
// to repeat. A rate limit (429, or 403 with a rate reason) refused the request
// before doing anything, so any request goes again. A server error (5xx) may
// have done it anyway: only a read or an in-place update (GET, PATCH) is
// safe to repeat - a repeated create could leave two files of one name, and
// a repeated delete would fail on the file it just deleted. Drive's
// Retry-After is honoured up to 10 s.
const driveRetryWait = async (res, method, attempt) => {
  let limited = res.status === 429;
  if (res.status === 403) {
    let body = await res.json?.().catch(() => null);
    let reasons = (body?.error?.errors || []).map((e) => e?.reason);
    limited = reasons.some((r) => r === "rateLimitExceeded" || r === "userRateLimitExceeded");
  }
  let transient = [500, 502, 503, 504].includes(res.status) &&
                  (method === "GET" || method === "PATCH");
  if (!limited && !transient) return null;
  let after = Number(res.headers?.get?.("retry-after"));
  if (after > 0) return Math.min(after * 1000, 10000);
  return driveRetryMs * 2 ** attempt * (0.75 + Math.random() / 2);
};

// Every page of the listing. A library runs to about 22 Drive files a game,
// so a big one passes a page, and a missing page can be the one holding the
// library file: the next write would then create a second one.
const driveListAll = async () => {
  let files = [];
  let page = null;
  do {
    let url = GDRIVE_FILES + "?spaces=appDataFolder&pageSize=1000&fields=" +
      encodeURIComponent("nextPageToken,files(id,name,size,modifiedTime,createdTime,appProperties)") +
      (page ? "&pageToken=" + encodeURIComponent(page) : "");
    let body = await (await driveFetch(url)).json();
    files.push(...(body.files || []));
    page = body.nextPageToken || null;
  } while (page);
  return files;
};

// An upload answers with when Drive stamped the write (flushSyncInner needs
// it to tell its own write from another device's).
const UPLOAD_FIELDS = "&fields=" + encodeURIComponent("id,modifiedTime");

// The generation stamp a file is written with (see genOf). Absent is 0, so
// a generation-0 write sends no metadata a build before generations did not;
// a file restamped down to 0 drops the key (Drive removes a null property).
const genMeta = (gen) => (gen > 0 ? { appProperties: { gen: String(gen) } } : {});

// Metadata and bytes in one multipart body; bytes go in as a Blob, never
// string-converted.
const multipartBody = (meta, bytes) => {
  let boundary = "dingbat" + Math.random().toString(36).slice(2);
  let body = new Blob([
    `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n` +
      JSON.stringify(meta) +
      `\r\n--${boundary}\r\nContent-Type: application/octet-stream\r\n\r\n`,
    bytes,
    `\r\n--${boundary}--`,
  ]);
  return { headers: { "Content-Type": "multipart/related; boundary=" + boundary }, body };
};

// Create + upload in one multipart request.
const driveCreateMultipart = (name, bytes, gen = 0) =>
  driveFetch(GDRIVE_UPLOAD + "?uploadType=multipart" + UPLOAD_FIELDS, {
    method: "POST",
    ...multipartBody({ name, parents: ["appDataFolder"], ...genMeta(gen) }, bytes),
  });

const driveCreateEmpty = async (name, gen = 0) => {
  let res = await driveFetch(GDRIVE_FILES, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, parents: ["appDataFolder"], ...genMeta(gen) }),
  });
  return (await res.json()).id;
};

const driveUpdateContent = (fileId, bytes) =>
  driveFetch(GDRIVE_UPLOAD + "/" + fileId + "?uploadType=media" + UPLOAD_FIELDS, {
    method: "PATCH",
    headers: { "Content-Type": "application/octet-stream" },
    body: new Blob([bytes]),
  });

// New bytes under a new generation stamp, in one request, so no one ever
// lists the new bytes under the old stamp or the reverse.
const driveUpdateMultipart = (fileId, bytes, gen) =>
  driveFetch(GDRIVE_UPLOAD + "/" + fileId + "?uploadType=multipart" + UPLOAD_FIELDS, {
    method: "PATCH",
    ...multipartBody({ appProperties: { gen: gen > 0 ? String(gen) : null } }, bytes),
  });

// Metadata only: the stamp, after the bytes of a file too big for multipart.
const driveStampGen = (fileId, gen) =>
  driveFetch(GDRIVE_FILES + "/" + fileId + "?fields=" + encodeURIComponent("id,modifiedTime"), {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ appProperties: { gen: gen > 0 ? String(gen) : null } }),
  });

// Drive caps multipart bodies at 5 MB, so big files go as metadata create
// + media PATCH. `gen` is the generation the bytes belong to; `restamp` says
// the existing file carries another one. A big file restamped gets its bytes
// first and its stamp second: the other order would, between the two, show
// the old bytes as the new game's, which is the one thing the stamp is for.
const driveUploadFile = async (name, bytes, existingId, gen = 0, restamp = false) => {
  let small = bytes.length <= 4 * 1024 * 1024;
  if (existingId) {
    if (!restamp) return driveUpdateContent(existingId, bytes);
    if (small) return driveUpdateMultipart(existingId, bytes, gen);
    await driveUpdateContent(existingId, bytes);
    return driveStampGen(existingId, gen);
  }
  if (small) return driveCreateMultipart(name, bytes, gen);
  return driveUpdateContent(await driveCreateEmpty(name, gen), bytes);
};

// `onBytes(n)` hears each chunk as it lands, for a tile's progress bar.
const driveDownload = async (fileId, onBytes = null) => {
  let res = await driveFetch(GDRIVE_FILES + "/" + fileId + "?alt=media");
  let reader = onBytes && res.body?.getReader?.();
  if (!reader) {
    let bytes = new Uint8Array(await res.arrayBuffer());
    onBytes?.(bytes.length);
    return bytes;
  }
  let parts = [];
  let len = 0;
  for (;;) {
    let { done, value } = await reader.read();
    if (done) break;
    parts.push(value);
    len += value.length;
    onBytes(value.length);
  }
  let out = new Uint8Array(len);
  let at = 0;
  for (let p of parts) { out.set(p, at); at += p.length; }
  return out;
};

// `fn` over `items`, at most `n` running at once, started in order. The
// first failure starts nothing further and is thrown once the ones already
// running have ended, so nothing is left writing after the caller moves on.
const runPool = async (items, n, fn) => {
  let next = 0;
  /** @type {{ e: unknown } | null} */
  let failure = null;
  const worker = async () => {
    while (!failure && next < items.length) {
      const item = items[next++];
      try { await fn(item); } catch (e) { failure ||= { e }; }
    }
  };
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, worker));
  if (failure) throw failure.e;
};

// Downloads started ahead of a loop that takes them one at a time, in order:
// at most `n` on the wire, the earliest first. `take(f)` is the one for f
// (started now if it was not yet); `stop()` starts no more. One the loop
// never takes costs only its bytes, and a failure is the taker's to see.
const downloadAhead = (files, n = SYNC_PARALLEL) => {
  let started = new Map();
  let waiting = files.slice();
  let active = 0;
  const start = (f) => {
    let p = started.get(f.id);
    if (p) return p;
    active++;
    p = driveDownload(f.id);
    p.catch(() => {}).finally(() => { active--; pump(); });
    started.set(f.id, p);
    return p;
  };
  const pump = () => { while (active < n && waiting.length) start(waiting.shift()); };
  pump();
  return {
    take: (f) => { waiting = waiting.filter((w) => w.id !== f.id); return start(f); },
    stop: () => { waiting = []; },
  };
};

// Drive file name -> { game, kind }; null for anything unknown. `kind` is
// unique within a game: slot 0 keeps "state"/"statemeta", slots 1..8 append
// ":slotN". Mirrors romsWithSaveData's ":slotN" and "-p2" folding.
const parseDriveFileName = (n) => {
  if (n.startsWith("rom:")) return { game: n.slice(4), kind: "rom" };
  if (n.startsWith("frame:")) return { game: n.slice(6), kind: "frame" };
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
  // A save kept from before the game was deleted (keptSaveKey).
  if (n.startsWith("oldsave:")) return { game: n.slice(8), kind: "oldsave" };
  // The session (autoStateKey), its picture riding inside it (sessionBundle).
  if (n.startsWith("stateauto:")) return { game: n.slice(10), kind: "session" };
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

// Signs this device out: its tokens are forgotten, and nothing is revoked,
// so the account's other devices stay signed in. (Google cannot revoke one
// device: any revoke ends the whole grant. That is gdriveSignOutEverywhere.)
const gdriveSignOut = ({ message = "Signed out of Google Drive" } = {}) => {
  // Ends the session: a flush or pull still running stops at its next
  // await, and a token popup still open is refused when it answers.
  driveSession++;
  syncState.refresh = null;
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
  showToast(message);
};

// Ends dingbat's Drive access for the whole Google account. Each other
// device finds out at its next renewal (invalid_grant) and signs itself
// out. Signs this device out only once Google has said yes.
const gdriveSignOutEverywhere = async () => {
  // A popup-flow device with a lapsed token has nothing Google would take.
  if (!syncState.refresh && driveTokenStale() && !(await ensureDriveSignedIn())) return;
  let tokens = [syncState.refresh, driveTokenStale() ? null : gdriveToken].filter(Boolean);
  for (let token of tokens) {
    try {
      let r = await fetchWithin("https://oauth2.googleapis.com/revoke", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: "token=" + encodeURIComponent(token),
      }, 8000);
      if (r.ok) {
        gdriveSignOut({ message: "Signed out of Google Drive on every device" });
        return;
      }
    } catch {}
  }
  showToast("Couldn't reach Google to sign out everywhere — try again");
};

// One Settings row: what it is on the left, the controls that act on it on
// the right — the shape every other actionable row in this box already has.
// The account's name is an email, which can outrun any column, so the row
// wraps as a whole: the buttons keep their size and drop to their own line
// when the row is tight, leaving the address the full width. Only an
// address too long even for that breaks mid-word.
const gdriveRow = (label, sub, ...controls) => {
  let row = document.createElement("div");
  row.className = "modal-toggle-row gdrive-row";
  let text = document.createElement("div");
  text.className = "gdrive-row-text";
  let l = document.createElement("span");
  l.className = "modal-row-label gdrive-row-label";
  l.textContent = label;
  let s = document.createElement("span");
  s.className = "modal-toggle-sub";
  s.textContent = sub;
  text.append(l, s);
  row.appendChild(text);
  let live = controls.filter(Boolean);
  if (live.length) {
    let actions = document.createElement("div");
    actions.className = "gdrive-actions";
    // A wide control goes under the others, across their combined width.
    if (live.some((c) => c.classList.contains("gdrive-action-wide"))) {
      actions.classList.add("gdrive-actions-stack");
    }
    actions.append(...live);
    row.appendChild(actions);
  }
  return row;
};

const renderGdriveSection = () => {
  if (!gdriveBody) return;
  gdriveBody.innerHTML = "";

  if (!GDRIVE_CLIENT_ID) {
    gdriveBody.appendChild(gdriveRow(
      "Not available in this build",
      "This build was made without a Google client ID.", null));
    return;
  }

  if (!driveLinked()) {
    let btn = makeGdriveButton("Sign in", false, async () => {
      btn.disabled = true;
      try { await gdriveConnect(); }
      catch (e) { showToast(e.message); btn.disabled = false; }
    });
    gdriveBody.appendChild(gdriveRow(
      "Sign in with Google",
      "Mirrors your games and saves across every device you sign in to.", btn));
    return;
  }

  let n = pendingCount();
  // Linked but between tokens is not signed out; the next Sync buys a token.
  let state = !gdriveToken ? "Reconnects when you next sync."
            : n ? n + " change" + (n === 1 ? "" : "s") + " waiting to go up."
            : "All changes synced.";
  let sync = makeGdriveButton("Sync", false, async () => {
    if (!(await ensureDriveSignedIn())) return;
    runFullSync({ label: "Syncing" });
  });
  let out = makeGdriveButton("Sign out", true, gdriveSignOut);
  // The row has no space to say it, and it is the one thing worth saying.
  out.title = "Your games and saves stay on this device";
  // Two taps: it reaches every device, and the first could be a slip.
  let armTimer = null;
  let everywhere = makeGdriveButton("Sign out everywhere", true, async () => {
    if (!everywhere.classList.contains("armed")) {
      everywhere.classList.add("armed");
      everywhere.textContent = "Tap again to confirm";
      armTimer = setTimeout(() => {
        everywhere.classList.remove("armed");
        everywhere.textContent = "Sign out everywhere";
      }, 4000);
      return;
    }
    clearTimeout(armTimer);
    everywhere.disabled = true;
    await gdriveSignOutEverywhere();
    everywhere.disabled = false;
    everywhere.classList.remove("armed");
    everywhere.textContent = "Sign out everywhere";
  });
  everywhere.title = "Signs this Google account out of dingbat on all your devices";
  everywhere.classList.add("gdrive-action-wide");
  gdriveBody.appendChild(gdriveRow(
    gdriveEmail || "Connected to Google Drive", state, sync, out, everywhere));
};

// ============================================================================
// Google Drive sync. Signing in is turning sync on. The library lives in
// one Drive file, "library":
//     { recents: [{ name, ts, imp?, gen? }], tomb: [{ name, ts, gen? }],
//       ren: [{ from, to, ts }] }
// `recents` is the merged cross-device play history (the home grid). `tomb`
// are tombstones, so a union-merge cannot resurrect a deleted game; a
// re-upload supersedes one, and a game loaded again after its delete stands
// beside it as the next generation (see genOf). `ren` are rename markers: every other device
// migrates its records for `from` to `to` on its next sync; a newer recents
// entry under `from` supersedes the marker. ROMs are never bulk-downloaded
// (Drive-only tiles download on demand). Uploads go through a persisted
// queue, flushed 2s after the last change and at most 10s after the first.
// ============================================================================

const LIBRARY_FILE = "library";
const SYNC_DEBOUNCE_MS = 2000;   // quiet period before a flush
const SYNC_MAX_WAIT_MS = 10000;  // ...but never sit on changes longer than this
const SYNC_POLL_MS = 3 * 60 * 1000;
// Drive requests a sync keeps in flight at once. Each is a round trip of
// 100-300 ms from a phone; one at a time, a second device's first pull of a
// 20-game library took 13 s at 150 ms (web/e2e/sync-bench.mjs).
const SYNC_PARALLEL = 6;

// Persisted under "gdrive_sync". sigs = last agreed content signature per
// Drive file; rmt = its last seen modifiedTime; queueRen = pending remote
// renames [{ from, to }]; ren = this device's rename markers.
let syncState = { queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [],
                  delTs: {}, acct: null, parked: {},
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
      delTs: s.delTs && typeof s.delTs === "object" ? s.delTs : {},
      // The account the rest of this belongs to, and the per-account state
      // of any other account that has signed in here (adoptDriveAccount).
      acct: typeof s.acct === "string" ? s.acct : null,
      parked: s.parked && typeof s.parked === "object" ? s.parked : {},
      connected: !!s.connected,
      token: typeof s.token === "string" ? s.token : null,
      tokenExp: typeof s.tokenExp === "number" ? s.tokenExp : 0,
      // Refresh token from the broker's code exchange (driveCodeGrant).
      refresh: typeof s.refresh === "string" ? s.refresh : null,
      // The account the refresh token was granted for; null when it was
      // stored before this was kept (driveRefreshUsable).
      refreshAcct: typeof s.refreshAcct === "string" ? s.refreshAcct : null,
      // No consent screen offered before this (driveWantsUpgrade).
      upgradeRestUntil: typeof s.upgradeRestUntil === "number" ? s.upgradeRestUntil : 0,
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
// Linked is a live Drive session. Enrolled is weaker and longer-lived: this
// device belongs to a Drive account, signed in this minute or not. Intent
// recorded while signed out or offline still belongs to that account and
// flushes when it comes back, so the queues key off this. A device that has
// never signed in records nothing, having nowhere to send it.
const driveEnrolled = () => !!GDRIVE_CLIENT_ID && (!!syncState.connected || !!syncState.acct);

// Everything the sync remembers describes one account's Drive and means
// nothing against another: what is queued, what was deleted or renamed, and
// what Drive is known to hold.
const PER_ACCOUNT_KEYS = ["queueUp", "queueDel", "queueRen", "tomb", "ren",
                          "sigs", "rmt", "delTs"];
// A sync record written before delete stamps existed, or one built whole by
// a caller, has no map yet.
const delStamps = () => (syncState.delTs ??= {});
const blankAccountState = () => ({ queueUp: [], queueDel: [], queueRen: [],
                                   tomb: [], ren: [], sigs: {}, rmt: {}, delTs: {} });

// Anything of the game on this device besides the picture a pull brought.
const holdsGame = async (name) => {
  let pic = frameKey(name);
  for (let k of allPerGameKeys(name)) if (k !== pic && (await dbGet(k)) != null) return true;
  return false;
};

// The grid ("recent") and the pictures a pull brings down are this device's,
// shared by every account that signs in here, and what this device holds of
// a game (its ROM, a save, a state) goes to whichever account is signed in.
// But a tile with nothing of it here except its picture is on the grid only
// because the last account's Drive listed it: it is that account's, and
// left in place it would be written into the next account's library, its
// picture uploaded there too. So it leaves with its account: the entry is
// parked beside that account's queues (`outgoing.recents`), the picture is
// dropped along with the sigs/rmt that say it is here (that account's next
// pull fetches it again), and the entries parked for the incoming account
// come back.
const swapAccountGames = async (outgoing, incoming) => {
  let gone = [];
  await updateRecent(async (list) => {
    let keep = [];
    for (let e of list) {
      if (e?.name && !(await holdsGame(e.name))) gone.push(e);
      else keep.push(e);
    }
    let back = incoming.filter((e) => e?.name && !keep.some((k) => k.name === e.name));
    if (!gone.length && !back.length) return;
    return [...keep, ...back].sort((x, y) => (y.ts || 0) - (x.ts || 0));
  });
  for (let e of gone) {
    let pic = frameKey(e.name);
    await dbDelete(pic);
    delete outgoing.sigs?.[pic];
    delete outgoing.rmt?.[pic];
  }
  outgoing.recents = gone;
  if (gone.length || incoming.length) refreshHomeRecent();
};

// One device, more than one Google account. A different account signing in
// parks the previous account's state under its own id and starts clean; if
// that account ever signs back in, its parked work is restored and flushes
// then. Nothing is discarded, and nothing is replayed into a Drive that did
// not ask for it.
const adoptDriveAccount = async (acct) => {
  if (!acct) return;                       // tokeninfo gave no id: leave as is
  if (syncState.acct === acct) return;     // the same account as before
  let parked = { ...(syncState.parked || {}) };
  let mine = null;
  if (syncState.acct) {
    mine = {};
    for (let k of PER_ACCOUNT_KEYS) mine[k] = syncState[k];
    parked[syncState.acct] = mine;
  }
  let restored = parked[acct];
  delete parked[acct];
  let { recents: theirs = [], ...theirState } = restored || {};
  // Drive work still running holds the last account's state: end its session.
  driveSession++;
  syncRemarked.clear();
  Object.assign(syncState, blankAccountState(), theirState);
  syncState.acct = acct;
  syncState.parked = parked;
  if (mine) await swapAccountGames(mine, theirs);
  await saveSyncState();
  let waiting = restored
    ? (restored.queueDel || []).length + (restored.queueRen || []).length +
      (restored.tomb || []).length
    : 0;
  if (waiting) showToast("Applying changes saved for this account");
};
// A token alone is not a session: a signed-out tab can still come to hold
// one, and a sign-in holds one before it knows whose it is.
const syncActive = () => !!gdriveToken && driveLinked() && !driveConnecting;

const sigOfBytes = (bytes) => saveSignature(bytes); // FNV-1a + length

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
  if (key.startsWith("frame:")) {
    if (!(v instanceof Blob) || !v.size) return null;
    return new Uint8Array(await v.arrayBuffer());
  }
  if (key.startsWith("statemeta:")) {
    if (v && typeof v === "object" && !(v instanceof Uint8Array) &&
        !(v instanceof ArrayBuffer)) {
      let b = new TextEncoder().encode(JSON.stringify(v));
      return b.length ? b : null;
    }
    return null;
  }
  if (key.startsWith("oldsave:")) return keptRecordBytes(v);
  if (key.startsWith("stateauto:")) return sessionBundle(key.slice(10), v);
  if (v instanceof ArrayBuffer) v = new Uint8Array(v);
  return v instanceof Uint8Array && v.length ? v : null;
};
const writeSyncBytes = async (name, bytes) => {
  if (name.startsWith("rom:")) {
    let game = name.slice(4);
    // The one sync write big enough to fill a disk, and the one with a copy
    // to come back for.
    if (!(await dbPutRoomy(name, { name: game, data: new Uint8Array(bytes) }, game)))
      throw new Error("this device is out of room");
    return;
  }
  if (name.startsWith("frame:")) {
    // A picture this browser cannot keep (Safari's private browsing stores
    // no Blob in IndexedDB) is left out, not the end of the pull.
    await dbPut(name, new Blob([bytes], { type: "image/jpeg" })).catch(() => {});
    return;
  }
  if (name.startsWith("statemeta:")) {
    try { await dbPut(name, JSON.parse(new TextDecoder().decode(bytes))); }
    catch {}
    return;
  }
  if (name.startsWith("oldsave:")) {
    let rec = keptRecordFrom(bytes);
    if (!rec) return;
    let game = parseDriveFileName(name).game;
    let had = await getKeptSave(game);
    // Kept by another device (it held the game when it was deleted and
    // loaded again): said here once, as the device that kept it said it.
    if ((await storeKeptRecord(game, rec)) && !had && keptOffer(rec) && rec.why === "deleted") {
      showToast("A save of “" + displayName(game) + "” from before you deleted it came " +
                "back from another device. It is kept for 30 days — Restore it from the " +
                "game's menu.");
    }
    return;
  }
  if (name.startsWith("stateauto:")) {
    let s = sessionFromBundle(bytes);
    if (!s) return;
    let game = name.slice(10);
    if (!(await dbPutRoomy(name, s.rec, game))) throw new Error("this device is out of room");
    // The picture after the session, as persistAutoState writes them.
    if (s.pic) await dbPut(sessionPicKey(game), { ts: s.rec.ts, blob: s.pic }).catch(() => {});
    return;
  }
  // A save or a state: the person's own, and worth a ROM file to land. Left
  // to a plain write, a full device would fail the whole pull and report
  // itself offline. Throwing when even that is not enough is right - the
  // caller records nothing, so the next pull tries again.
  if (!(await dbPutRoomy(name, bytes, parseDriveFileName(name)?.game)))
    throw new Error("this device is out of room");
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

// Drive names are not unique, and two devices syncing for the first time
// can each create "library" before either lists the other's. Every copy is
// kept here, per listing, oldest first (then by id), and the oldest is the
// library: the one the map names, and so the one every device reads and
// writes, whichever order its listing came back in.
const libraryCopies = new WeakMap();
const driveListMap = async () => {
  let files = await driveListAll();
  let libs = files.filter((f) => f.name === LIBRARY_FILE).sort((x, y) =>
    (Date.parse(x.createdTime || "") || 0) - (Date.parse(y.createdTime || "") || 0) ||
    (x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
  let m = new Map(files.filter((f) => f.name !== LIBRARY_FILE).map((f) => [f.name, f]));
  if (libs.length) m.set(LIBRARY_FILE, libs[0]);
  libraryCopies.set(m, libs);
  return m;
};

// --- The shared library file (merged recents + tombstones + renames) ------
// The ids of the copies a read actually merged, per listing: only those may
// be retired, since only their contents are in what gets written.
const libraryRead = new WeakMap();
// The text of the one copy a listing had, as read: a library merged to the
// same text is already Drive's, and writing it again is a wasted round trip.
const libraryText = new WeakMap();
const readDriveLibrary = async (remote) => {
  let copies = libraryCopies.get(remote) ||
    (remote.get(LIBRARY_FILE) ? [remote.get(LIBRARY_FILE)] : []);
  let libs = [];
  let read = [];
  for (let f of copies) {
    // A failed download fails the sync: going on without this copy would
    // write a library that no longer holds what it says.
    let bytes = await driveDownload(f.id);
    let o;
    let text = new TextDecoder().decode(bytes);
    if (copies.length === 1) libraryText.set(remote, text);
    // Unreadable content has nothing in it to keep; the next write replaces it.
    try { o = JSON.parse(text); } catch { o = {}; }
    libs.push({
      recents: Array.isArray(o?.recents) ? o.recents : [],
      tomb: Array.isArray(o?.tomb) ? o.tomb : [],
      ren: Array.isArray(o?.ren) ? o.ren : [],
    });
    read.push(f.id);
  }
  libraryRead.set(remote, read);
  if (!libs.length) return { recents: [], tomb: [], ren: [] };
  // More than one: the union, by the same merge the devices use.
  return libs.slice(1).reduce((a, b) => mergeLibrary(a, b), libs[0]);
};
// Whether `lib` is, to the byte, the one copy read under `readFrom`.
const libraryUnchanged = (lib, readFrom) =>
  libraryText.has(readFrom) && libraryText.get(readFrom) === JSON.stringify(lib);
// `readFrom` is the listing the library was read under (the flush lists
// again before writing). The write goes to the oldest copy; the other
// copies that read merged are then deleted, their contents being in it.
const writeDriveLibrary = async (lib, remote, readFrom = remote) => {
  let bytes = new TextEncoder().encode(JSON.stringify(lib));
  let keep = remote.get(LIBRARY_FILE);
  await driveUploadFile(LIBRARY_FILE, bytes, keep?.id);
  let merged = libraryRead.get(readFrom) || [];
  for (let f of libraryCopies.get(remote) || []) {
    // Already gone (another device got there first) or not now: next time.
    if (f.id !== keep?.id && merged.includes(f.id)) await driveDelete(f.id).catch(() => {});
  }
};

// --- Generations -----------------------------------------------------------
// A game deleted and then loaded again is a new game under the old name, and
// nothing of the deleted one may follow it in: not from a device that had
// not pulled the delete, and not from Drive. So a library entry carries a
// generation (`gen`; absent is 0, which is every entry and tombstone written
// before generations existed), and loading a game again after its delete
// starts the next one (bumpRecentIndex). A tombstone records the generation
// it deleted and stands beside an entry of a newer one instead of giving way
// to it (mergeLibrary), so a device holding the deleted game can tell. A
// Drive file carries the generation it was written for in
// appProperties.gen (absent is 0), its name and bytes saying nothing of it.
//
// A save of an older generation is never applied to the newer game. It is
// kept aside under "oldsave:<name>" ("a save from before you deleted this
// game"), offered in the game's menu and in Manage Saves with a Restore, for
// KEPT_SAVE_MS from the delete, then dropped here and on Drive.
const genOf = (x) => (Number.isInteger(x?.gen) && x.gen > 0 ? x.gen : 0);
const withGen = (o, gen) => (gen > 0 ? { ...o, gen } : o);
const fileGen = (f) => {
  let g = Number(f?.appProperties?.gen);
  return Number.isInteger(g) && g > 0 ? g : 0;
};
const KEPT_SAVE_MS = 30 * 24 * 3600 * 1000;
const keptSaveKey = (name) => "oldsave:" + name;
// The Drive kinds that belong to one generation of a game: its progress and
// its picture. A ROM carries no progress, and a kept save says for itself
// which game it came from.
const genBound = (kind) => kind !== "rom" && kind !== "oldsave";
// Deleted: a tombstone with no entry of a newer generation beside it (in a
// merged library the two stand together only then).
const deletedIn = (lib, name) =>
  lib.tomb.some((t) => t.name === name) && !lib.recents.some((e) => e.name === name);
const libGen = (lib, name) => genOf(lib.recents.find((e) => e.name === name));

const mergeLibrary = (a, b) => {
  let byName = new Map();
  for (let e of [...(a.recents || []), ...(b.recents || [])]) {
    if (!e?.name) continue;
    let prev = byName.get(e.name);
    // A newer generation wins the entry outright; within one, the newest
    // play. The newest import claim from either side is kept alongside it,
    // whichever entry that was.
    let imp = Math.max(prev?.imp || 0, e.imp || 0);
    let g = genOf(e);
    let pg = prev ? genOf(prev) : -1;
    if (!prev || g > pg || (g === pg && (e.ts || 0) > (prev.ts || 0))) {
      byName.set(e.name, withGen({ name: e.name, ts: e.ts || 0 }, g));
    }
    if (imp) byName.get(e.name).imp = imp;
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
  // Oldest-first so a chain (A->B, B->C) lands on C.
  let done = new Set();
  for (let r of [...ren.values()].sort((x, y) => (x.ts || 0) - (y.ts || 0))) {
    let e = byName.get(r.from);
    // Someone playing the old name is not an argument about the name: it is
    // a device that has not pulled the rename yet, and it gets migrated when
    // it does. Only an import claiming the old name after the rename is a
    // different game, and spends the marker.
    let reimported = !!e && (e.imp || 0) > r.ts;
    if (e && !reimported) {
      byName.delete(r.from);
      // The game keeps its generation under its new name.
      let t = byName.get(r.to);
      if (!t || genOf(t) < genOf(e) || (genOf(t) === genOf(e) && (t.ts || 0) < (e.ts || 0))) {
        byName.set(r.to, withGen(e.imp ? { name: r.to, ts: e.ts || 0, imp: e.imp }
                                        : { name: r.to, ts: e.ts || 0 }, genOf(e)));
      }
      // A rename claims its new name, as an import does (and as renameGame
      // stamps it on the renaming device). A game renamed into a name that
      // an older rename had vacated must not be carried on by that older
      // marker: the marker is spent here, and the claim goes with the entry
      // so that a device still holding the marker spends it too. Without
      // this, another device's rename into a retired name (then a delete
      // there, overruled by a later play here) had its game folded into
      // the old one's, save and all.
      let at = byName.get(r.to);
      if (r.ts > (at.imp || 0)) at.imp = r.ts;
      if (done.has(r.to)) ren.delete(r.to);
    }
    if (reimported) ren.delete(r.from);
    done.add(r.from);
  }
  let tomb = new Map();
  for (let t of [...(a.tomb || []), ...(b.tomb || [])]) {
    if (!t?.name) continue;
    let prev = tomb.get(t.name);
    let g = genOf(t);
    let pg = prev ? genOf(prev) : -1;
    if (!prev || g > pg || (g === pg && (t.ts || 0) > (prev.ts || 0))) {
      tomb.set(t.name, withGen({ name: t.name, ts: t.ts || 0 }, g));
    }
  }
  for (let [name, t] of tomb) {
    let e = byName.get(name);
    // Loaded again after the delete: a new game under the old name. Both
    // stand, the tombstone being how a device that holds the deleted game
    // learns that it was.
    if (e && genOf(e) > genOf(t)) continue;
    // Within one generation a later play says the delete was not meant (a
    // re-upload supersedes); an entry of an older generation than the
    // delete is of a game already gone.
    if (e && genOf(e) === genOf(t) && (e.ts || 0) > (t.ts || 0)) tomb.delete(name);
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

// --- Kept saves (see genOf) --------------------------------------------------
// "oldsave:<name>" holds { data, at, del, kept, why }: the save's bytes (null
// once a restore found no save to put in its place), when it was saved as
// near as is known, when the game was deleted (the 30 days run from there),
// when this record was written, and what it is - "deleted" (a save from
// before you deleted this game), "replaced" (the save a restore put aside),
// "restored" (nothing left to offer). On Drive it is JSON, the bytes base64.
const keptRecordBytes = (v) => {
  if (!v || typeof v !== "object" || ArrayBuffer.isView(v)) return null;
  let d = ArrayBuffer.isView(v.data)
    ? new Uint8Array(v.data.buffer, v.data.byteOffset, v.data.byteLength) : null;
  return new TextEncoder().encode(JSON.stringify({
    at: v.at || 0, del: v.del || 0, kept: v.kept || 0, why: v.why || "deleted",
    data: d && d.length ? base64FromBytes(d) : null,
  }));
};
const keptRecordFrom = (bytes) => {
  try {
    let o = JSON.parse(new TextDecoder().decode(bytes));
    if (!o || typeof o !== "object") return null;
    let data = null;
    if (typeof o.data === "string" && o.data) {
      let bin = atob(o.data);
      data = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) data[i] = bin.charCodeAt(i);
    }
    return { data, at: Number(o.at) || 0, del: Number(o.del) || 0,
             kept: Number(o.kept) || 0, why: typeof o.why === "string" ? o.why : "deleted" };
  } catch {
    return null;
  }
};
// A save the kept record still offers (a "restored" one offers nothing).
const keptOffer = (rec) =>
  rec && typeof rec === "object" && ArrayBuffer.isView(rec.data) && rec.data.byteLength > 0
    ? rec : null;
const getKeptSave = async (game) => keptOffer(await dbGet(keptSaveKey(game)));

// Two copies of one game's kept save (this device's, and another device's
// from Drive): the one written later stands. A capture is stamped with when
// its save was made, so the newest save from before the delete wins; a
// restore with the moment of the restore, so it outranks every copy of the
// save it restored. True when `rec` was stored. Ours being the newer, Drive
// gets ours back.
const storeKeptRecord = async (game, rec) => {
  let key = keptSaveKey(game);
  let cur = await dbGet(key);
  if (cur && typeof cur === "object" && (cur.kept || 0) >= (rec.kept || 0)) {
    if ((cur.kept || 0) > (rec.kept || 0)) markUpload(key);
    return false;
  }
  await dbPut(key, rec);
  return true;
};
const keepOldSave = async (game, rec) => {
  let stored = await storeKeptRecord(game, rec);
  if (stored) markUpload(keptSaveKey(game));
  return stored;
};

// Past its 30 days, a kept save leaves this device and (queued) Drive.
const expireKeptSaves = async () => {
  let now = Date.now();
  for (let k of await dbKeys()) {
    if (typeof k !== "string" || !k.startsWith("oldsave:")) continue;
    let rec = await dbGet(k);
    if (rec && typeof rec === "object" && now < (rec.del || 0) + KEPT_SAVE_MS) continue;
    await dbDelete(k);
    markDelete(k);
  }
};

// This device's records of `game` are of an older generation than the
// library's: the game was deleted and loaded again elsewhere before this
// device pulled the delete. They go, as the delete would have taken them had
// it arrived in time, except the battery save, which is kept aside. Queued
// uploads of them are dropped (the flush holds them back meanwhile). True
// when a save was kept.
const convertStaleGame = async (game, lib, entry) => {
  let kept = keptSaveKey(game);
  let bytes = await readSyncBytes("save:" + game);
  let keptIt = false;
  if (bytes) {
    // When it was saved, as near as this device knows: when Drive last took
    // it from here, or when the game was last started.
    let at = Math.max(Date.parse(syncState.rmt["save:" + game] || "") || 0,
                      entry?.ts || 0) || Date.now();
    let t = lib.tomb.find((x) => x.name === game);
    keptIt = await keepOldSave(game, { data: bytes, at, del: t?.ts || Date.now(),
                                       kept: at, why: "deleted" });
  }
  let old = allPerGameKeys(game).filter((k) => k !== kept);
  syncState.queueUp = syncState.queueUp.filter((n) => !old.includes(n));
  await deleteKeys(old);
  // What sigs/rmt remember is of the deleted game's files.
  for (let k of old) {
    delete syncState.sigs[k];
    delete syncState.rmt[k];
  }
  return keptIt;
};

// Kept-save wording, shared by the game's menu and Manage Saves.
const fmtKeptDay = (ts) => {
  try { return new Date(ts).toLocaleDateString([], { month: "short", day: "numeric" }); }
  catch { return ""; }
};
const keptSaveTitle = (rec) => rec.why === "replaced"
  ? "The save you replaced" : "Save from before you deleted this game";
const keptSaveSub = (rec) => (rec.at ? "Saved " + fmtStateTime(rec.at) + " · " : "") +
  "kept until " + fmtKeptDay((rec.del || 0) + KEPT_SAVE_MS);

// Restore: the kept save becomes the game's save, and the game's save is kept
// in its place, so a second Restore undoes the first. No save to keep in its
// place leaves a record that offers nothing (and outranks every older copy
// of the save just restored, which another device may still hold).
const restoreKeptSave = async (game) => {
  let key = keptSaveKey(game);
  let rec = keptOffer(await dbGet(key));
  if (!rec) return false;
  if (isRomLoaded(game) && (linkMode || rollbackMode || netActive())) {
    showToast("Exit the online session first");
    return false;
  }
  // The running game's save as it is now is the one being replaced: flushed,
  // then detached, as an imported save is (applyImportedSave).
  let game0 = null;
  if (currentOriginalName === game && currentRomName) {
    await persistSave(currentRomName, game);
    game0 = detachLoadedGame();
  }
  let cur = await readSyncBytes("save:" + game);
  let now = Date.now();
  let at = !cur ? 0 : game0 || syncState.queueUp.includes("save:" + game)
    ? now : Date.parse(syncState.rmt["save:" + game] || "") || now;
  retireSavePuts(game); // a waiting quota retry gives way (persistSeq)
  await dbPut("save:" + game, new Uint8Array(rec.data));
  // The resume snapshot holds the save being replaced.
  await deleteKeys(perGameKeys(game).session);
  markDelete(autoStateKey(game));
  markUpload("save:" + game);
  await dbPut(key, cur
    ? { data: cur, at, del: rec.del, kept: now, why: "replaced" }
    : { data: null, at: 0, del: rec.del, kept: now, why: "restored" });
  markUpload(key);
  if (game0) loadRom(game0.romName, game0.originalName);
  showToast(cur ? "Old save restored — Restore again to switch back"
                : "Old save restored");
  return true;
};

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

// The hero's kicker says how the paused game stands with Drive; set where
// the hero is (it is declared further down).
let onSyncRendered = () => {};
const renderSyncIndicator = () => {
  onSyncRendered();
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
// Keys saved again while already queued. Queued is not enough to be safe:
// the running flush may have read that key's bytes already and be sending
// them, and it takes the key off the queue once they land. It takes it off
// only if the key is not in here, and clears a key from here just before it
// reads it (flushSyncInner).
const syncRemarked = new Set();
const markUpload = (name) => {
  if (!driveEnrolled()) return;
  if (!parseDriveFileName(name)) return;
  if (!syncState.queueUp.includes(name)) syncState.queueUp.push(name);
  else syncRemarked.add(name);
  saveSyncState();
  scheduleFlush();
};
const markDelete = (name) => {
  if (!driveEnrolled()) return;
  if (!parseDriveFileName(name)) return;
  if (!syncState.queueDel.includes(name)) syncState.queueDel.push(name);
  // Stamped with the moment it was asked for, not the moment it reaches
  // Drive: a delete made offline on Tuesday must not outrank another
  // device's Wednesday write. The same rule the tombstones already use.
  delStamps()[name] = Date.now();
  syncState.queueUp = syncState.queueUp.filter((n) => n !== name);
  saveSyncState();
  scheduleFlush();
};
const markGameUpload = (game) => {
  if (!driveEnrolled()) return;
  localFilesForGame(game).then((names) => {
    for (let n of names) if (!syncState.queueUp.includes(n)) syncState.queueUp.push(n);
    saveSyncState();
    scheduleFlush();
  });
};
// Mirror a local save-data wipe to Drive: the saves, and the session, which
// carries the wiped battery.
const queueSaveDataDeletes = (name) => {
  for (let k of perGameKeys(name).saves) markDelete(k);
  markDelete(autoStateKey(name));
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
  // Tombstones and rename markers are kept for good (a device may come back
  // after any length of time and still need them), so on a device that has
  // ever deleted or renamed a game this lets every trigger through. That is
  // the point: each flush re-asserts them over a Drive write that lost them
  // (there is no compare-and-swap on the library file). What retires a
  // marker is a newer claim on its old name, never age (mergeLibrary).
  if (!pendingCount() && !syncState.tomb.length && !syncState.ren.length) {
    refreshSyncStatus();
    return;
  }
  // Every await below is followed by live(): the flush stops there if the
  // session it started in has ended (driveSessionGuard).
  const live = driveSessionGuard();
  syncBusy = true;
  setSyncStatus("syncing");
  try {
    let remote = live(await driveListMap());
    // What the library says about existence and naming, settled before a
    // single file is touched, so the files cannot end up disagreeing with it.
    let lib = mergeLibrary(live(await readDriveLibrary(remote)), live(await localLibrary()));
    // A tombstone the merge dropped: a later play on another device says the
    // delete was not meant. Its queued file deletes are cancelled. Only a
    // game delete raises a tombstone, so a save reset's deletes - whose game
    // is still in the library - are never caught by this.
    let revived = new Set();
    for (let t of syncState.tomb) {
      if (t?.name && !lib.tomb.some((x) => x.name === t.name)) revived.add(t.name);
    }
    if (revived.size) {
      syncState.queueDel = syncState.queueDel.filter((n) => {
        let g = parseDriveFileName(n)?.game;
        if (!g || !revived.has(g)) return true;
        delete delStamps()[n];
        return false;
      });
    }
    // A rename marker the merge spent: someone imported a fresh game under
    // the old name, so the name is taken and the queued file renames would
    // carry off that new game's files.
    let spent = new Set();
    for (let r of syncState.ren) {
      if (r?.from && !lib.ren.some((x) => x.from === r.from)) spent.add(r.from);
    }
    if (spent.size) {
      syncState.queueRen = syncState.queueRen.filter(
        (q) => !spent.has(parseDriveFileName(q.from)?.game));
    }

    // Renames first: every later step speaks in new names.
    for (let r of syncState.queueRen.slice()) {
      let f = remote.get(r.from);
      if (f && !remote.has(r.to)) {
        let res = live(await driveRenameFile(f.id, r.to));
        let meta = live(await res.json().catch(() => null));
        remote.delete(r.from);
        remote.set(r.to, { ...f, name: r.to,
                           modifiedTime: meta?.modifiedTime || f.modifiedTime });
        if (meta?.modifiedTime && syncState.rmt[r.to]) {
          syncState.rmt[r.to] = meta.modifiedTime;
        }
      } else if (f) {
        // Another device raced us with the same rename: the old file is a duplicate.
        await driveDelete(f.id);
        live();
        remote.delete(r.from);
      } else if (!remote.has(r.to) && !syncState.queueUp.includes(r.to) &&
                 live(await readSyncBytes(r.to))) {
        // Drive holds neither name but this device holds the bytes: upload.
        syncState.queueUp.push(r.to);
      }
      syncState.queueRen = syncState.queueRen.filter((x) => x !== r);
    }
    for (let name of syncState.queueDel.slice()) {
      let r = remote.get(name);
      // Another device wrote this file after the delete was asked for: the
      // newer write wins and the delete is dropped, leaving the file and
      // what is known about it alone.
      let asked = delStamps()[name] || 0;
      let outranked = !!r && !!asked && Date.parse(r.modifiedTime || 0) > asked;
      if (r && !outranked) {
        await driveDelete(r.id);
        live();
        // Gone from the listing too: the upload pass below then creates the
        // file afresh if it is queued again (a game deleted and loaded again
        // before this flush) rather than writing to the deleted one.
        remote.delete(name);
      }
      if (!outranked) {
        delete syncState.sigs[name];
        delete syncState.rmt[name];
      }
      delete delStamps()[name];
      syncState.queueDel = syncState.queueDel.filter((n) => n !== name);
    }
    // Each file's checks and bookkeeping touch only its own keys, so several
    // go at once (runPool); a failure still stops the flush, as before.
    await runPool(syncState.queueUp.slice(), SYNC_PARALLEL, async (name) => {
      // Gone from the queue since this pass began: a delete asked for it
      // (markDelete unqueues), or a rename moved it to its new name.
      if (!syncState.queueUp.includes(name)) return;
      // The library merged above has the last word on which games exist and
      // what they are called, and a device that has not pulled yet can hold
      // files it has overruled (a Sync tap queues every local file). A game
      // deleted elsewhere, with no later play: its files stay off Drive (a
      // missing file would otherwise upload regardless, and nothing would
      // ever take it down again), and the pull's tombstone pass deals with
      // the local copy. A game renamed elsewhere: its old-name files wait,
      // still queued, for the pull to move them under the new name.
      let parsed = parseDriveFileName(name);
      let game = parsed?.game;
      if (game && deletedIn(lib, game)) {
        syncState.queueUp = syncState.queueUp.filter((n) => n !== name);
        return;
      }
      if (game && lib.ren.some((r) => r.from === game)) return;
      // The generation this device holds the game at, read now: an import
      // made since the merge starts a new one.
      let gen = game
        ? genOf(live(await getRecentMeta()).find((e) => e?.name === game)) : 0;
      // What this device holds of a game deleted and loaded again elsewhere
      // is the deleted game's, and never goes up as the new one's. The pull
      // keeps its save aside and drops the rest (convertStaleGame).
      if (game && genBound(parsed.kind) && libGen(lib, game) > gen) {
        syncState.queueUp = syncState.queueUp.filter((n) => n !== name);
        return;
      }
      // A save of this key from here on is newer than the bytes read below.
      syncRemarked.delete(name);
      // A ROM never changes: one Drive holds at this generation (or a newer
      // one), already known here, is not read again - tens of MB a game on
      // every Sync now.
      let held0 = remote.get(name);
      if (parsed?.kind === "rom" && held0 && fileGen(held0) >= gen && syncState.sigs[name]) {
        syncState.queueUp = syncState.queueUp.filter((n) => n !== name);
        return;
      }
      let bytes = live(await readSyncBytes(name));
      // A session another device wrote since this one last saw Drive's copy
      // is not written over unseen: it stays queued, and the pull after this
      // flush decides (a hand-off, or the offer to switch, which marks it
      // seen - then this one, the newer, goes up). One a deleted generation
      // of the game left is no other device's moment, and nothing would ever
      // mark it seen: it is written over (below).
      let r0 = remote.get(name);
      let forced = handoffForce.delete(name);
      if (bytes && parsed?.kind === "session" && r0 && fileGen(r0) >= gen &&
          syncState.rmt[name] !== r0.modifiedTime &&
          sigOfBytes(bytes) !== syncState.sigs[name] && !forced) {
        return;
      }
      if (bytes) {
        let r = remote.get(name);
        let sig = sigOfBytes(bytes);
        // The listing is the truth; sigs only remember what this device once
        // uploaded. A file missing remotely uploads regardless of its sig.
        // Present: ROMs are immutable, anything else re-uploads on change;
        // and a file written for an older generation is replaced whatever
        // its bytes, taking this one's stamp.
        let restamp = !!r && fileGen(r) !== gen;
        if (!r || (restamp && fileGen(r) < gen) ||
            (!name.startsWith("rom:") && sig !== syncState.sigs[name])) {
          let res = live(await driveUploadFile(name, bytes, r?.id, gen, restamp));
          let meta = live(await res?.json?.().catch(() => null));
          // Drive's stamp for this write, so the next pull knows the file
          // is unchanged since and does not fetch back what was just sent.
          if (meta?.modifiedTime) syncState.rmt[name] = meta.modifiedTime;
          // Deleted while this upload was on the wire: the delete is the
          // later word, but the delete pass lets any write to the file after
          // the delete's stamp outrank it, and this write is exactly such a
          // one. Stamp it no earlier than this write, so only another
          // device's later write still can; with no time to go on, the
          // delete simply goes ahead.
          if (syncState.queueDel.includes(name)) {
            let mt = Date.parse(meta?.modifiedTime || "");
            if (mt) delStamps()[name] = Math.max(delStamps()[name] || 0, mt);
            else delete delStamps()[name];
          }
        }
        // Either way Drive now holds these bytes, so record it: a skipped
        // upload of an already-present ROM is still proof of a copy there.
        syncState.sigs[name] = sig;
      }
      // Saved again while it was being read or sent: what went up is
      // already stale, so it stays queued for the next flush.
      if (!syncRemarked.has(name)) {
        syncState.queueUp = syncState.queueUp.filter((n) => n !== name);
      }
    });
    // Unchanged, it is not written, and so needs no second listing either.
    if (!libraryUnchanged(lib, remote)) {
      await writeDriveLibrary(lib, live(await driveListMap()), remote);
    }
    live();
    // `lib` was merged before the awaits above. A delete, import or rename
    // made here since then is in this device's library now and not in
    // `lib`: adopting `lib` as it stands would drop that delete's
    // tombstone or that rename's marker for good. So it is merged again
    // with the library as it is at this moment, read and adopted in one
    // step under the "recent" lock.
    let addedBack = false;
    await updateRecent((here) => {
      live();
      let now = mergeLibrary(lib, { recents: here, tomb: syncState.tomb, ren: syncState.ren });
      syncState.tomb = now.tomb;
      syncState.ren = now.ren;
      // A game the merge brought back belongs in this device's own library
      // again, as a tile it can download from.
      let add = now.recents.filter((r) => revived.has(r.name) &&
                                          !here.some((h) => h.name === r.name));
      if (!add.length) return;
      addedBack = true;
      return [...here, ...add].sort((x, y) => (y.ts || 0) - (x.ts || 0));
    });
    if (addedBack) refreshHomeRecent();
    await saveSyncState();
    syncBusy = false;
    setSyncStatus("done");
  } catch (e) {
    syncBusy = false;
    // Signed out, or in as someone else: nothing failed, and this flush's
    // work (still queued) belongs to the session that ended.
    if (e instanceof DriveSessionEnded) { refreshSyncStatus(); return; }
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
  // Another device's game claims the name: a pull may write under it again
  // (renamedAway; bug_remote_rename_into_away_name_skips_saves).
  renamedAway.delete(to);
  let fromKeys = allPerGameKeys(from);
  let toKeys = allPerGameKeys(to);
  // The game may be open: flush the pending save under the old name,
  // detach the session so no write path recreates an old key, reattach
  // after. A link/online session cannot be migrated under; the caller defers.
  if (isRomLoaded(from) && (linkMode || rollbackMode || netActive())) return null;
  // Nor under a load of the old name: it is reading those records right now
  // and names its game only when it boots, after this move.
  if (loadingName === from) return null;
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
  // Queued work keeps its intent under the new names, else the flush
  // looks the old keys up, finds nothing, and drops it.
  let mapKey = (k) => {
    let i = fromKeys.indexOf(k);
    return i >= 0 ? toKeys[i] : k;
  };
  // Applied twice, like renameGame's: to the state as the transaction starts
  // (the copy it writes) and as it ends (the one kept), so nothing queued
  // while the move is in flight is lost to a stale copy.
  let renamed = (s) => {
    let sigs = { ...s.sigs };
    let rmt = { ...s.rmt };
    fromKeys.forEach((f, i) => {
      let t = toKeys[i];
      if (f in sigs) { sigs[t] = sigs[f]; delete sigs[f]; }
      if (f in rmt) { rmt[t] = rmt[f]; delete rmt[f]; }
    });
    return {
      ...s,
      sigs,
      rmt,
      queueUp: [...new Set(s.queueUp.map(mapKey))],
      queueDel: [...new Set(s.queueDel.map(mapKey))],
      delTs: Object.fromEntries(
        Object.entries(s.delTs || {}).map(([k, v]) => [mapKey(k), v])),
      queueRen: s.queueRen.map((r) => ({ from: mapKey(r.from), to: r.to })),
    };
  };
  puts.push(["gdrive_sync", renamed(syncState)]);
  let res;
  try {
    res = await dbMoveKeys(fromKeys.map((k, i) => [k, toKeys[i]]), puts,
                           { skipCollisions: true });
  } catch (e) {
    if (loaded) currentOriginalName = from;
    console.warn("Rename from another device not applied here:", from, "→", to, e);
    return null;
  }
  syncState = renamed(syncState);
  if (Array.isArray(printerPhotos)) {
    for (let p of printerPhotos) if (p?.game === from) p.game = to;
  }
  if (stateUndoName === from) stateUndoName = to;
  if (rwUndoName === from) rwUndoName = to;
  if (loaded) {
    currentOriginalName = to;
    if (heroCard && !heroCard.hidden) drawPausedHero();
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

// --- Hand-off: the game in memory, played on another device since ---------
// A pull leaves the loaded game's files alone, its autosave being their
// writer. But a game left paused here while another device played on is a
// stale copy: Resume would carry on from the old moment, and its next
// in-game save would write over the other device's. So when a pull finds
// another device's newer save or session for the game in memory, it is
// picked up there instead: the copy here is let go, nothing of it written,
// and the newer files land - the hero shows the other device's picture and
// Resume goes to its moment. On its own only while that is safe: the game
// is on the home screen (not being played), and everything of it here has
// gone up (the session is of this very moment, the save stored and sent).
// Otherwise it is offered (Switch), once per newer copy.
const HANDOFF_KEYS = (game) => ["save:" + game, autoStateKey(game)];
let handoffOffered = "";

// Another device's newer save or session for `game`, downloaded:
// [{ key, f, bytes }], or [] when Drive holds nothing newer than here.
const handoffNews = async (game, remote, lib, live) => {
  let news = [];
  for (let key of HANDOFF_KEYS(game)) {
    let f = remote.get(key);
    if (!f || syncState.rmt[key] === f.modifiedTime) continue;
    if (fileGen(f) < libGen(lib, game) || syncState.queueDel.includes(key)) continue;
    let bytes = live(await driveDownload(f.id));
    let sig = sigOfBytes(bytes);
    let here = live(await readSyncBytes(key));
    if (here && sigOfBytes(here) === sig) {
      // The same bytes (this device's own, or never recorded): nothing new.
      syncState.sigs[key] = sig;
      syncState.rmt[key] = f.modifiedTime;
      continue;
    }
    news.push({ key, f, bytes });
  }
  return news;
};

// Nothing of the game in memory is waiting to go up: its session is of this
// moment, and its battery is the stored save, sent. Asked after the read, so
// the caller acts on it in the same run: a tap during the read (Resume, and
// frames run) is seen.
const heldGameIsSent = async (game) => {
  let stored = await dbGet("save:" + game).catch(() => null);
  if (sessionMoved || sessionSnapFor !== game) return false;
  if (HANDOFF_KEYS(game).some((k) => syncState.queueUp.includes(k))) return false;
  return liveSaveSig() === sigOfSave(stored);
};

// Where the newer copy came from, as the hero and the toasts say it.
const fromWhere = (news) => {
  let s = news.find((n) => n.key.startsWith("stateauto:"));
  return deviceWords(s ? sessionFromBundle(s.bytes)?.rec.dev : "");
};

// Let the copy in memory go and land the newer files in its place.
const takeHandoff = async (game, news) => {
  // Before any await: a checkpoint packing meanwhile is of the copy being
  // let go, and must not write its session over the one landing here
  // (bug_checkpoint_after_switch).
  sessionEpochs.set(game, sessionEpoch(game) + 1);
  if (!(await unloadGame({ flushSave: false, picture: false }))) return false;
  for (let { key, f, bytes } of news) {
    await writeSyncBytes(key, bytes);
    syncState.sigs[key] = sigOfBytes(bytes);
    syncState.rmt[key] = f.modifiedTime;
  }
  if (heroDrawnFor === game) heroDrawnFor = null;
  return true;
};

// The Switch a pull offers: the copy here is dropped, unsent work and all
// (the player chose the other device's), and the newer files the pull
// downloaded land in its place. Kept here rather than fetched again: once
// offered, the other device's session is marked seen, and this device's
// own next session would go up over it.
let handoffStash = null; // { game, news }
const switchToHandoff = async (game) => {
  if (currentOriginalName !== game || handoffStash?.game !== game) return;
  const { news } = handoffStash;
  handoffStash = null;
  handoffOffered = "";
  syncState.queueUp = syncState.queueUp.filter((k) => !HANDOFF_KEYS(game).includes(k));
  await saveSyncState();
  if (!(await takeHandoff(game, news))) return;
  // Chosen, so it is the copy everywhere: sent up again, over whatever this
  // device sent while the offer was up (handoffForce lets the session past
  // the flush's unseen-write check).
  for (let { key } of news) {
    delete syncState.sigs[key];
    handoffForce.add(key);
    markUpload(key);
    // As saved again: a flush may be sending this device's own copy right
    // now (the offer schedules one), and its completion would otherwise
    // take the key off the queue with the turned-down copy on Drive.
    syncRemarked.add(key);
  }
  await saveSyncState();
  refreshHomeRecent();
  // Sent before the next pull, which would otherwise take whatever this
  // device sent meanwhile for the newer copy and land it back.
  flushSync().then(() => pullSync({ silent: false }));
};
const handoffForce = new Set();

// --- Pull (down-sync): merged library, tombstones, saves for local games ---
// Resolves when the session's first pull has ended, well or badly: the
// boot-time library-pictures offer waits on it, since a pull may be
// bringing every picture down.
/** @type {(v?: unknown) => void} */
let firstPullSettled = () => {};
const firstPullPromise = new Promise((r) => { firstPullSettled = r; });
const pullSync = (opts = {}) => {
  if (pullQueued) return syncChain; // already one waiting; don't pile up
  pullQueued = true;
  return runExclusive(() => {
    pullQueued = false;
    return pullSyncInner(opts).finally(() => firstPullSettled());
  });
};
const pullSyncInner = async ({ silent = true } = {}) => {
  if (!syncActive()) return;
  // As in flushSyncInner: the pull stops after any await that finds the
  // session it started in over.
  const live = driveSessionGuard();
  syncBusy = true;
  if (!silent) setSyncStatus("syncing");
  let gridDirty = false;
  let queuedMissing = false;
  /** @type {ReturnType<typeof downloadAhead> | null} */
  let ahead = null;
  try {
    let remote = live(await driveListMap());
    // Not the library's business: a setting riding the same pull.
    live(await syncSaveHook(remote, live));
    let lib = mergeLibrary(live(await readDriveLibrary(remote)), live(await localLibrary()));

    // Remote renames before the tombstone pass, so anything still under an
    // old name is genuinely deleted data. Oldest-first so chains replay in order.
    let renPending = new Set();
    for (let r of [...(lib.ren || [])].sort((x, y) => (x.ts || 0) - (y.ts || 0))) {
      if (!live(await hasAnyLocalRecord(r.from))) continue;
      let applied = live(await applyRemoteRename(r.from, r.to));
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
      // Uploads the flush held back while this game was still under its
      // old name here are queued under the new one now: send them.
      if (syncState.queueUp.some((n) => parseDriveFileName(n)?.game === r.to)) {
        queuedMissing = true;
      }
      gridDirty = true;
      if (applied.moved) {
        showToast("“" + displayName(r.from) + "” is now “" + displayName(r.to) +
                  "” — renamed on another device");
      }
    }

    let pending = [];
    for (let t of lib.tomb) {
      // A tombstone beside a newer generation is of a game loaded again
      // since: the pass below deals with what is held of the deleted one.
      if (deletedIn(lib, t.name) && live(await hasLocalData(t.name))) pending.push(t.name);
    }
    if (pending.length) {
      let keep = live(await confirmTombstones(pending));
      if (keep === "restore") {
        // Un-delete: drop the tombstones and re-upload, at the generation
        // that was deleted.
        let now = Date.now();
        for (let g of pending) {
          let gen = genOf(lib.tomb.find((t) => t.name === g));
          lib.recents = lib.recents.filter((r) => r.name !== g);
          lib.recents.unshift(withGen({ name: g, ts: now }, gen));
          markGameUpload(g);
        }
        lib.tomb = lib.tomb.filter((t) => !pending.includes(t.name));
      } else {
        for (let g of pending) {
          // Never yank the game being played, nor the one mid-load: its load
          // has read these records and would boot on them.
          if (isRomLoaded(g) || loadingName === g) continue;
          // The same local wipe Delete performs.
          await deleteGameLocalData(g);
          live();
          gridDirty = true;
        }
      }
    }

    // Games deleted and loaded again elsewhere while this device held them:
    // what it holds is the deleted game's (its entry is of an older
    // generation than the library's). Its save is kept aside and the rest
    // goes. Not the game being played or loaded, which keeps its generation
    // here (`stale`, pinned at the commit below) until the next pull.
    let stale = new Map();
    let hereList = live(await getRecentMeta());
    for (let e of lib.recents) {
      let h = hereList.find((x) => x?.name === e.name);
      if (genOf(e) <= genOf(h)) continue;
      let held = false;
      for (let k of allPerGameKeys(e.name)) {
        if (k !== keptSaveKey(e.name) && live(await dbGet(k)) != null) { held = true; break; }
      }
      if (!held) continue;
      if (isRomLoaded(e.name) || loadingName === e.name) {
        stale.set(e.name, genOf(h));
        continue;
      }
      let keptIt = live(await convertStaleGame(e.name, lib, h));
      gridDirty = true;
      if (keptIt) {
        showToast("“" + displayName(e.name) + "” was deleted and loaded again on another " +
                  "device. Your save from before is kept for 30 days — Restore it from " +
                  "the game's menu.");
      }
    }
    // Past their 30 days: kept saves held here (Drive's copies follow in
    // the listing pass).
    live(await expireKeptSaves());

    // The game in memory, played on another device since (see Hand-off).
    let held = currentOriginalName;
    if (held && currentRomName && !linkMode && !rollbackMode && !netActive() &&
        loadingName !== held && lib.recents.some((r) => r.name === held)) {
      // The downloads below take seconds, and the player may close the game,
      // go back into it or load another meanwhile (each moves loadGen).
      const g0 = loadGen;
      const running = () => document.body.classList.contains("running");
      // Still the game in memory, by the player's leave: a game closed (or
      // closing) since is no longer held - the files pass, or the next pull,
      // lands what came, as for any closed game, where an offer would mark
      // it seen and leave the closed copy resuming its older moment.
      const stillHeld = () => currentOriginalName === held && (loadGen === g0 || running());
      let news = live(await handoffNews(held, remote, lib, live));
      if (news.length && stillHeld()) {
        let where = fromWhere(news);
        // Decided in the run that acts: heldGameIsSent asks after its read.
        if (!running() && live(await heldGameIsSent(held)) && loadGen === g0 &&
            !running() && currentOriginalName === held &&
            live(await takeHandoff(held, news))) {
          gridDirty = true;
          showToast("“" + displayName(held) + "” was played on " + where +
                    " since — Resume picks up there");
        } else if (stillHeld()) {
          // A later pull no longer lists what it marked seen below: kept.
          let kept = handoffStash?.game === held
            ? handoffStash.news.filter((o) => !news.some((n) => n.key === o.key)) : [];
          handoffStash = { game: held, news: [...kept, ...news] };
          // Seen: if the player keeps this copy, its next session is the
          // newer one and goes up (the flush holds a session back only
          // until it is seen).
          for (let n of news) {
            if (n.key === autoStateKey(held)) syncState.rmt[n.key] = n.f.modifiedTime;
          }
          if (syncState.queueUp.includes(autoStateKey(held))) queuedMissing = true;
          let seen = held + "|" + news.map((n) => n.f.modifiedTime).join("|");
          if (handoffOffered !== seen) {
            handoffOffered = seen;
            showActionToast("“" + displayName(held) + "” was played on " + where +
                            " since you opened it here", "Switch",
                            () => switchToHandoff(held), 12000);
          }
        }
      }
    }

    // Pull saves/states for games this device holds, and pictures for every
    // game in the library: a Drive-only tile shows the screen another device
    // last saw (20 KB, and the whole point of the picture).
    let local = live(await localSyncFiles());
    // Which games' ROMs are here, from the keys: every write of one carries
    // its bytes, and reading each to ask cost its whole size per file.
    let romsHere = new Set([...local].filter(([, p]) => p.kind === "rom").map(([, p]) => p.game));
    // The files the loop below will fetch, started ahead (downloadAhead):
    // the same tests it applies before a download, minus the ones it makes
    // again after (a game loaded meanwhile). It still takes, checks and
    // writes them one at a time, in this order.
    ahead = downloadAhead([...remote].filter(([name, f]) => {
      let p = name !== LIBRARY_FILE && parseDriveFileName(name);
      if (!p || p.kind === "rom" || syncState.rmt[name] === f.modifiedTime) return false;
      if (genBound(p.kind) && fileGen(f) < libGen(lib, p.game)) return false;
      if (isRomLoaded(p.game) || loadingName === p.game) return false;
      return p.kind === "frame" ? lib.recents.some((r) => r.name === p.game)
        : romsHere.has(p.game) || (p.kind === "oldsave" && local.has(name));
    }).map(([, f]) => f));
    for (let [name, f] of remote) {
      live(); // the downloads below await, and write the sync state after
      if (name === LIBRARY_FILE) continue;
      let p = parseDriveFileName(name);
      if (!p) continue;
      if (p.kind === "rom") {
        // Never downloaded here: a ROM is immutable, and either already on
        // this device or fetched on demand (downloadGame). The listing is
        // then the only place this device can learn that Drive holds it -
        // which is what "Remove from this device" needs to know before it
        // frees the local bytes. Recorded, not fetched - and the listing
        // gives the size for free, for a game that has never been here.
        syncState.rmt[name] = f.modifiedTime;
        if (f.size) await noteRomSize(p.game, Number(f.size) || 0);
        continue;
      }
      if (p.kind === "oldsave") {
        // A kept save past its 30 days, whoever kept it: from the delete the
        // library records, or failing that from when it reached Drive.
        let t = lib.tomb.find((x) => x.name === p.game);
        let from = t?.ts || Date.parse(f.modifiedTime || "") || 0;
        if (Date.now() >= from + KEPT_SAVE_MS) {
          if (!syncState.queueDel.includes(name)) markDelete(name);
          continue;
        }
      }
      if (p.kind === "frame") {
        if (!lib.recents.some((r) => r.name === p.game)) continue; // not a library game
      } else if (!romsHere.has(p.game) &&
                 // A kept save held here follows Drive's (a restore elsewhere).
                 !(p.kind === "oldsave" && local.has(name))) {
        continue;                                  // Drive-only: pull on demand
      }
      // Don't fight the autosave: not for the game being played, nor for the
      // one being loaded (loadingName), which will run on the save it read.
      if (isRomLoaded(p.game) || loadingName === p.game) continue;
      if (syncState.rmt[name] === f.modifiedTime) continue; // unchanged remotely
      // Written for an older generation of the game: a device that had not
      // pulled the delete sent it. Never applied. A save is kept aside; then
      // Drive's copy is replaced by this device's (the new game's) or, with
      // none here, taken down - by a device holding the game, so the save is
      // kept before it goes.
      if (genBound(p.kind) && fileGen(f) < libGen(lib, p.game)) {
        if (p.kind === "save") {
          let old = live(await driveDownload(f.id));
          let at = Date.parse(f.modifiedTime || "") || Date.now();
          let t = lib.tomb.find((x) => x.name === p.game);
          if (old.length && live(await keepOldSave(p.game, {
            data: old, at, del: t?.ts || Date.now(), kept: at, why: "deleted" }))) {
            showToast("A save of “" + displayName(p.game) + "” from before you deleted " +
                      "it came back from another device. It is kept for 30 days — " +
                      "Restore it from the game's menu.");
          }
        }
        if (syncState.queueDel.includes(name)) continue;
        if (live(await readSyncBytes(name))) markUpload(name);
        else markDelete(name);
        continue;
      }
      let bytes = live(await ahead.take(f));
      // Again, in the run that writes: a tap during the download has booted
      // the game on the older save, and its first flush would write that
      // back over this one and upload it over the other device's.
      if (isRomLoaded(p.game) || loadingName === p.game) continue;
      let sig = sigOfBytes(bytes);
      // Reset or deleted here while it downloaded: the delete is queued for
      // Drive, and writing these bytes back would undo it (the next pull
      // would then upload them again). resetGameSaves and
      // deleteGameEverywhere queue before they wipe, so this check, in the
      // same segment as the write, sees every such delete.
      if (syncState.queueDel.includes(name)) continue;
      // Renamed here while it downloaded: written now it would land under
      // the old name, an orphan no rename may reuse; it comes down under the
      // new name once the rename reaches Drive (bug_pull_after_rename_orphans_frame).
      if (renamedAway.has(p.game)) continue;
      if (sig !== syncState.sigs[name]) {
        live(await writeSyncBytes(name, bytes));
        syncState.sigs[name] = sig;
        // The closed hero redraws its picture: it may be this one now.
        if (heroDrawnFor === p.game) heroDrawnFor = null;
      }
      syncState.rmt[name] = f.modifiedTime;
      local.delete(name);
    }

    ahead.stop();
    live();
    // Reconcile upward: queue anything held here that the listing lacks
    // (sigs only remember what was once uploaded). Tombstoned games stay deleted.
    for (let [name, p] of local) {
      if (remote.has(name)) continue;
      if (deletedIn(lib, p.game)) continue;
      // A deferred rename still holds files under the old name; re-uploading
      // them would resurrect the retired names.
      if (renPending.has(p.game)) continue;
      if (!syncState.queueUp.includes(name)) {
        syncState.queueUp.push(name);
        queuedMissing = true;
      }
    }

    // `lib` was merged before every await above, and the person may have
    // deleted, imported or renamed a game meanwhile (closing the iOS file
    // picker fires visibilitychange, whose sync races the import). Merged
    // again with this device's library as it is now, and adopted in the
    // same step, under the "recent" lock: else the stale merge would write
    // the deleted game's tile back, drop the import's, and lose the delete's
    // tombstone or the rename's marker for good.
    await updateRecent((here) => {
      live();
      lib = mergeLibrary(lib, { recents: here, tomb: syncState.tomb, ren: syncState.ren });
      syncState.tomb = lib.tomb;
      syncState.ren = lib.ren;
      // Files on Drive of a game the library has deleted (no later play):
      // put back by a device that had not pulled the delete, or by a build
      // that uploaded before asking the library. Nothing else would ever
      // take them down, and a later import of the game would pull their old
      // save back in. Queued for deletion like a local delete (and so
      // cancelled by the flush if a later play revives the game), from the
      // tombstones as adopted here, after this device's own changes.
      for (let t of lib.tomb) {
        if (!deletedIn(lib, t.name)) continue; // loaded again since: its files are its own
        for (let n of remote.keys()) {
          if (parseDriveFileName(n)?.game === t.name && !syncState.queueDel.includes(n)) {
            markDelete(n);
          }
        }
      }
      // A deferred rename keeps its old name on the local grid (else a
      // "Drive only" tile for a local game, whose download forks the library),
      // with ts pinned under the marker so it still folds forward next merge.
      let recents = lib.recents;
      // A game still held at an older generation (being played) keeps it
      // here, so the next pull knows its records are the deleted game's.
      if (stale.size) {
        recents = recents.map((e) => {
          if (!stale.has(e.name)) return e;
          let { gen, ...rest } = e;
          return withGen(rest, stale.get(e.name));
        });
      }
      if (renPending.size) {
        let back = new Map();
        for (let m of lib.ren) if (renPending.has(m.from)) back.set(m.to, m);
        recents = recents.map((e) => {
          let m = back.get(e.name);
          return m ? { name: m.from, ts: Math.min(e.ts || 0, (m.ts || 1) - 1) } : e;
        });
      }
      // Do not apply the byte budget here: it is about this device's disk, and
      // an entry dropped from the cross-device library is a game no device
      // could ask for again.
      return recents;
    });
    if (!libraryUnchanged(lib, remote)) await writeDriveLibrary(lib, remote);
    live();
    await saveSyncState();
    gridDirty = true;
  } catch (e) {
    ahead?.stop();
    syncBusy = false;
    if (e instanceof DriveSessionEnded) { refreshSyncStatus(); return; }
    console.warn("Drive pull failed:", e);
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
  // The game in memory as it is now, not as the 5 s autosave last left it:
  // a save made a moment ago goes up with this sync.
  if (currentRomName && currentOriginalName && !linkMode && !rollbackMode && !netActive()) {
    await persistAutoState();
    await persistSave(currentRomName, currentOriginalName);
  }
  let names = [...(await localSyncFiles()).keys()];
  for (let n of names) if (!syncState.queueUp.includes(n)) syncState.queueUp.push(n);
  await saveSyncState();
  await flushSync();
  await pullSync({ silent: false });
};

// --- On-demand download of one Drive-only game ---------------------------
// `onProgress(got, total)` counts bytes across every file this fetches; the
// total is from the listing's sizes, so it is known before the first byte.
const downloadGame = async (game, { onProgress = null } = {}) => {
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
      // The newest generation any of it was written for (see genOf); a file
      // of an older one is the deleted game's, not applied (its save kept
      // aside), and left for the next pull to replace or take down.
      let entry = (await getRecentMeta()).find((e) => e?.name === game);
      let gen = Math.max(genOf(entry), ...files.map(fileGen));
      const stale = (f) => {
        let p = parseDriveFileName(f.name);
        return p && genBound(p.kind) && fileGen(f) < gen;
      };
      // An older generation's files are skipped, bar its save.
      let total = files.reduce((n, f) =>
        stale(f) && parseDriveFileName(f.name).kind !== "save" ? n : n + (Number(f.size) || 0), 0);
      let got = 0;
      const tick = onProgress && ((n) => { got += n; onProgress(got, total); });
      onProgress?.(0, total);
      for (let f of files) {
        let p = parseDriveFileName(f.name);
        if (stale(f)) {
          if (p.kind === "save") {
            let at = Date.parse(f.modifiedTime || "") || Date.now();
            let t = syncState.tomb.find((x) => x?.name === game);
            await keepOldSave(game, { data: await driveDownload(f.id, tick), at,
                                      del: t?.ts || Date.now(), kept: at, why: "deleted" });
          }
          continue;
        }
        let bytes = await driveDownload(f.id, tick);
        await writeSyncBytes(f.name, bytes);
        if (f.name === romKey(game)) await noteRomSize(game, bytes.length);
        syncState.sigs[f.name] = sigOfBytes(bytes);
        syncState.rmt[f.name] = f.modifiedTime;
      }
      await bumpRecentIndex(game, { gen });
      await saveSyncState();
      requestPersistentStorage();
      if (heroDrawnFor === game) heroDrawnFor = null; // its session's picture may be here now
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
  // bytes + session; saves and prefs stay (see perGameKeys). The picture
  // stays too: it is mirrored, tiny, and the Drive-only tile keeps its face.
  let keys = perGameKeys(game);
  await deleteKeys([...keys.bytes.filter((k) => k !== frameKey(game)), ...keys.session,
                    ...keys.checkpoints]);
  markGameUpload(game); // the ROM is gone, so this queues the saves we kept
  return true;
};

// --- Deletion -------------------------------------------------------------
const resetGameSaves = async (game) => {
  // Enrolled, not linked: wiping a save is the same kind of intent as
  // deleting a game, so a reset made offline or signed out is recorded and
  // reaches Drive when the account comes back. Otherwise the next sync
  // hands the save straight back. Recorded before the wipe: a pull that is
  // downloading this save checks the queue before writing it back.
  if (driveEnrolled()) queueSaveDataDeletes(game);
  await deleteSaveData(game);
};
const deleteGameEverywhere = async (game) => {
  // Enrolled, not linked: a delete made offline or signed out is still a
  // delete, and the tombstone's timestamp is what carries that intent to
  // the other devices whenever this one next reaches Drive.
  // Queue the whole inventory (markDelete drops what Drive doesn't hold),
  // before the wipe: a pull downloading one of these files checks the queue
  // before writing it back.
  if (driveEnrolled()) for (let n of allPerGameKeys(game)) markDelete(n);
  await deleteGameLocalData(game);
  // The tombstone is raised in the same step that drops the tile, so a sync
  // commit (which re-reads both under the same lock) sees both or neither.
  await updateRecent((list) => {
    if (driveEnrolled()) {
      // The generation deleted: loading the game again starts the next.
      let gen = genOf(list.find((r) => r?.name === game));
      syncState.tomb = syncState.tomb.filter((t) => t.name !== game);
      syncState.tomb.push(withGen({ name: game, ts: Date.now() }, gen));
    }
    return list.filter((r) => r.name !== game);
  });
  if (driveEnrolled()) {
    await saveSyncState();
    scheduleFlush();
  }
};

// --- Rename ---------------------------------------------------------------
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
    kept: !!(await getKeptSave(name)),
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
  if (inv.kept) out.push("The save kept from before you deleted it");
  if (inv.prints) out.push(inv.prints + (inv.prints === 1 ? " printed photo" : " printed photos"));
  return out;
};

// Returns { ok: true, moved } or { ok: false, error } (shown verbatim).
// Names this session renamed a game away from, until a game holds the name
// again (a rename into it, here or from another device, or any library entry
// under it): a pull downloading a file under one must not write it
// (pullSyncInner's write segment).
const renamedAway = new Set();

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

  renamedAway.add(oldName);
  renamedAway.delete(newName);

  // The game in memory: flush under the old name, then detach so no write
  // path recreates an old key or lands on a new one mid-transaction.
  let loaded = isRomLoaded(oldName) && !!currentRomName;
  if (loaded) {
    await persistSave(currentRomName, oldName);
    currentOriginalName = null;
  }

  // Records that name the game, written in the same transaction.
  let puts = [];
  // One moment for the rename: the new entry's claim on the name and the
  // marker carry the same stamp.
  let ts = Date.now();

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
  // transaction, so a tab closed mid-rename leaves records and queue
  // consistent. It is a function of the sync state rather than a copy: the
  // copy written in the transaction is taken as the transaction starts and
  // the one kept in memory as it ends, so a save queued while the move is
  // in flight is carried along instead of being dropped with a stale copy.
  let renamed = null;
  if (driveEnrolled()) renamed = (s) => {
    // Every syncable key, held locally or not, except one already queued
    // for remote deletion (renaming it would resurrect it).
    let mirrored = pairs.filter(([f]) => !!parseDriveFileName(f) &&
                                         !s.queueDel.includes(f));
    let oldKeys = mirrored.map(([f]) => f);
    let newKeys = mirrored.map(([, t]) => t);
    // Signatures and modified-times follow their files.
    let sigs = { ...s.sigs };
    let rmt = { ...s.rmt };
    for (let [f, t] of mirrored) {
      if (f in sigs) { sigs[t] = sigs[f]; delete sigs[f]; }
      if (f in rmt) { rmt[t] = rmt[f]; delete rmt[f]; }
    }
    return {
      ...s,
      sigs,
      rmt,
      // A pending upload delivers under the new name (its sig moved too).
      queueUp: [...new Set(s.queueUp.map((n) => {
        let i = oldKeys.indexOf(n);
        return i >= 0 ? newKeys[i] : n;
      }))],
      // A delete aimed at a new name is stale: this game exists now.
      queueDel: s.queueDel.filter((n) => !newKeys.includes(n)),
      delTs: Object.fromEntries(Object.entries(s.delTs || {})
        .filter(([k]) => !newKeys.includes(k))
        .map(([k, v]) => [oldKeys.includes(k) ? newKeys[oldKeys.indexOf(k)] : k, v])),
      queueRen: [...s.queueRen,
                 ...mirrored.map(([from, to]) => ({ from, to }))],
      // No tombstone for the old name: the ren marker migrates other devices.
      tomb: s.tomb.filter((t) => t?.name !== oldName && t?.name !== newName),
      ren: [
        ...s.ren.filter((r) => r?.from !== oldName && r?.from !== newName),
        { from: oldName, to: newName, ts },
      ],
    };
  };

  let moved = [];
  try {
    // Under the "recent" lock, so a sync commit re-merging this device's
    // library sees the whole rename (entry, marker, records) or none of it.
    await updateRecent(async (recents) => {
      let all = puts.slice();
      // The renamed entry gets a fresh timestamp (mergeLibrary drops any
      // entry older than a tombstone of the same name) and claims the name
      // the way an import does (`imp`). A marker from an earlier rename
      // *away* from this name is older than the claim, so the merge spends
      // it instead of applying it to this game too. Without the claim,
      // renaming a game back, or another game into a name one was renamed
      // away from, is undone by the next merge, and the stale marker then
      // drags the files back and forth on every sync.
      if (recents.some((r) => r?.name === oldName)) {
        let list = recents.filter((r) => r?.name !== oldName);
        list.unshift(withGen({ name: newName, ts, imp: ts },
                             genOf(recents.find((r) => r?.name === oldName))));
        all.push(["recent", list]);
      }
      if (renamed) all.push(["gdrive_sync", renamed(syncState)]);
      ({ moved } = await dbMoveKeys(pairs, all));
      if (renamed) syncState = renamed(syncState);
    });
  } catch (e) {
    // Rolled back whole: put the session back.
    renamedAway.delete(oldName);
    if (loaded) currentOriginalName = oldName;
    return { ok: false, error: (e?.message || "The rename could not be completed.") +
                              " Nothing was changed." };
  }

  if (renamed) scheduleFlush();
  if (Array.isArray(printerPhotos)) {
    for (let p of printerPhotos) if (p?.game === oldName) p.game = newName;
  }
  if (stateUndoName === oldName) stateUndoName = newName;
  if (rwUndoName === oldName) rwUndoName = newName;
  if (loaded) {
    currentOriginalName = newName;
    if (heroCard && !heroCard.hidden) drawPausedHero();
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

  let m;
  const close = () => {
    renameModalOpen = false;
    m.dismiss();
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

// --- Export: one game's files, out to the person's own disk ---------------
// The tile menu's Export… lists every kind of file this game has here, one
// checkbox each, ticked as they were last time. The ROM always starts
// unticked: the person most likely has it already, and it is the one big
// file. A kind this game has nothing of is not offered at all. One file goes
// out as itself; more go out as one .zip (zipwrite.js) with an info.json
// saying what each file is, for an import to read one day.
//
// Every state kind - the nine slots, where you left off, the earlier moments
// - is one choice: none of them opens anywhere but here, so there is nothing
// to pick between.
const EXPORT_TICKS_KEY = "export-ticks";
// Headings are clutter over a short list; from this many rows they group it.
const EXPORT_SECTION_MIN = 5;
const EXPORT_STATES_DIR = "dingbat save states/";

// File names from game names: the characters a filesystem refuses go.
const exportSafeName = (s) => String(s).replace(/[\\/:*?"<>|\x00-\x1f]/g, "_").trim() || "game";
const exportStamp = (ts) => {
  let d = new Date(ts);
  let p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
         `${p(d.getHours())}-${p(d.getMinutes())}`;
};
const exportDay = (ts) => exportStamp(ts).slice(0, 10);
const exportBytes = (v) =>
  v instanceof Uint8Array ? v : v instanceof ArrayBuffer ? new Uint8Array(v)
  : ArrayBuffer.isView(v) ? new Uint8Array(v.buffer, v.byteOffset, v.byteLength) : null;
const exportBlobBytes = async (b) =>
  b instanceof Blob && b.size ? new Uint8Array(await b.arrayBuffer()) : null;
const exportDataUrl = (url) => {
  let m = /^data:([^;,]*)(;base64)?,(.*)$/s.exec(typeof url === "string" ? url : "");
  if (!m || !m[2]) return null;
  let ext = { "image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp",
              "image/gif": ".gif" }[m[1]] || ".png";
  return { ext, bytes: b64ToBytes(m[3]) };
};
const exportImgExt = (blob) =>
  ({ "image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp",
     "image/gif": ".gif" }[blob?.type] || ".png");

// --- Game Boy Camera photos, out of the camera's own save ---
// The cart's 128 KB of RAM holds 30 photo slots: slot k's 128x112 picture
// is 0xE00 bytes of 2bpp tiles (16 across, 14 down) at 0x2000 + k * 0x1000.
// Which slots hold a photo, and where each sits in the album, is a 30-byte
// table at 0x11B2: the photo's album number minus one, 0xFF for an empty
// slot. The table is followed by "Magic" and a checksum, and the whole run
// is repeated at 0x11D7 as a backup copy. Layout from Raphaël Boichot's
// public write-up of the save format ("Inject pictures in your Game Boy
// Camera saves"); Pan Docs covers the mapper and sensor, not the album.
const CAM_CART_TYPE = 0xfc;
const CAM_RAM_SIZE = 0x20000;
const CAM_SLOTS = 30;
const CAM_PHOTO_W = 128, CAM_PHOTO_H = 112;
const camAlbum = (sav) => {
  const magicAt = (o) => [..."Magic"].every((c, i) => sav[o + i] === c.charCodeAt(0));
  for (const at of [0x11b2, 0x11d7]) {
    if (magicAt(at + CAM_SLOTS)) return sav.subarray(at, at + CAM_SLOTS);
  }
  return null;
};
// [{ number, pixels }] in album order; pixels are 0 (lightest) to 3.
const cameraPhotos = (rom, sav) => {
  if (!rom || rom.length <= 0x147 || rom[0x147] !== CAM_CART_TYPE) return [];
  if (!sav || sav.length < CAM_RAM_SIZE) return [];
  const album = camAlbum(sav);
  if (!album) return [];
  const out = [];
  for (let slot = 0; slot < CAM_SLOTS; slot++) {
    const n = album[slot];
    if (n >= CAM_SLOTS) continue; // 0xFF: empty
    const base = 0x2000 + slot * 0x1000;
    const pixels = new Uint8Array(CAM_PHOTO_W * CAM_PHOTO_H);
    for (let ty = 0; ty < CAM_PHOTO_H / 8; ty++) {
      for (let tx = 0; tx < CAM_PHOTO_W / 8; tx++) {
        const tile = base + (ty * (CAM_PHOTO_W / 8) + tx) * 16;
        for (let row = 0; row < 8; row++) {
          const lo = sav[tile + row * 2], hi = sav[tile + row * 2 + 1];
          for (let bit = 0; bit < 8; bit++) {
            const v = ((lo >> (7 - bit)) & 1) | (((hi >> (7 - bit)) & 1) << 1);
            pixels[(ty * 8 + row) * CAM_PHOTO_W + tx * 8 + bit] = v;
          }
        }
      }
    }
    out.push({ number: n + 1, pixels });
  }
  return out.sort((a, b) => a.number - b.number);
};
// A 2-bit greyscale PNG (PNG spec, colour type 0, bit depth 2), its zlib
// stream made of stored blocks: four shades are exactly what the format
// holds, and at 3.6 KB a photo there is nothing worth compressing.
const greyPng2 = (pixels, w, h) => {
  const row = 1 + w / 4;
  const raw = new Uint8Array(row * h);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      // Shade 0 is the lightest; PNG grey 3 is white.
      raw[y * row + 1 + (x >> 2)] |= (3 - pixels[y * w + x]) << (6 - (x & 3) * 2);
    }
  }
  // Stored deflate blocks (RFC 1951 3.2.4): header byte, LEN, NLEN, bytes.
  const blocks = [];
  for (let o = 0; o < raw.length; o += 0xffff) {
    const n = Math.min(0xffff, raw.length - o);
    const last = o + n >= raw.length ? 1 : 0;
    blocks.push(Uint8Array.of(last, n & 0xff, n >> 8, ~n & 0xff, (~n >> 8) & 0xff),
                raw.subarray(o, o + n));
  }
  let a = 1, b = 0;
  for (const v of raw) { a = (a + v) % 65521; b = (b + a) % 65521; }
  const zlib = [Uint8Array.of(0x78, 0x01), ...blocks,
                Uint8Array.of(b >> 8, b & 0xff, a >> 8, a & 0xff)];
  const join = (parts) => {
    const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
    let o = 0;
    for (const p of parts) { out.set(p, o); o += p.length; }
    return out;
  };
  const u32 = (n) => Uint8Array.of(n >>> 24, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff);
  const chunk = (type, data) => {
    const td = join([new TextEncoder().encode(type), data]);
    return join([u32(data.length), td, u32(ZipWrite.crc32(td))]);
  };
  const ihdr = join([u32(w), u32(h), Uint8Array.of(2, 0, 0, 0, 0)]);
  return join([Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a),
               chunk("IHDR", ihdr), chunk("IDAT", join(zlib)), chunk("IEND", new Uint8Array(0))]);
};

const plural = (n, one, many = one + "s") => n + " " + (n === 1 ? one : many);

// What this game has to export, as the rows of the modal: { kind, group,
// label, sub, files: [{ path, data, solo? }] }. `path` is where a file sits
// in the zip; `solo` is its name when it goes out alone. Only kinds with
// something in them are listed.
const exportInventory = async (name) => {
  const base = exportSafeName(stripExt(name) || name);
  const items = [];
  const add = (kind, group, label, sub, files) => {
    files = files.filter((f) => f.data && f.data.length);
    if (files.length) items.push({ kind, group, label, sub, files });
  };

  const rom = await getRomBytes(name);
  add("rom", "The game", "ROM", exportSafeName(name), [{ path: exportSafeName(name), data: rom }]);

  const sav = exportBytes(await dbGet(linkSaveKey(name, 0)));
  const sav2 = exportBytes(await dbGet(linkSaveKey(name, 1)));
  add("save", "Progress", "Save file",
      "Your in-game progress · .sav" + (sav2 && sav2.length ? " · with Player 2's" : ""),
      [{ path: base + ".sav", data: sav, solo: base + ".sav" },
       { path: base + " (Player 2).sav", data: sav2 }]);

  const states = [];
  let slots = 0, quick = false;
  for (let s = 0; s < NUM_STATE_SLOTS; s++) {
    const bytes = exportBytes(await dbGet(slotStateKey(name, s)));
    if (!bytes || !bytes.length) continue;
    const label = s === 0 ? "Quick" : "Slot " + s;
    if (s === 0) quick = true; else slots++;
    states.push({ path: EXPORT_STATES_DIR + label + ".state", data: bytes,
                  solo: base + (s === 0 ? "" : " (" + label + ")") + ".state" });
    const pic = exportDataUrl((await dbGet(slotMetaKey(name, s)))?.thumb);
    if (pic) states.push({ path: EXPORT_STATES_DIR + label + pic.ext, data: pic.bytes });
  }
  const auto = await dbGet(autoStateKey(name));
  const autoBytes = exportBytes(auto?.bytes);
  if (autoBytes && autoBytes.length) {
    states.push({ path: EXPORT_STATES_DIR + "Where you left off.state", data: autoBytes,
                  solo: base + " (where you left off).state" });
    const pic = await dbGet(sessionPicKey(name));
    const picBytes = await exportBlobBytes(pic?.blob);
    if (picBytes) states.push({ path: EXPORT_STATES_DIR + "Where you left off" + exportImgExt(pic.blob),
                                data: picBytes });
  }
  let moments = 0;
  const taken = new Set();
  for (const e of (await readCheckpointIndex(name)).list) {
    const rec = await dbGet(ckptKey(name, e.slot));
    const bytes = exportBytes(rec?.bytes);
    if (!bytes || !bytes.length) continue;
    moments++;
    let stem = EXPORT_STATES_DIR + "Moments/" + exportStamp(rec.ts || e.ts);
    for (let i = 2; taken.has(stem); i++) stem = stem.replace(/( \(\d+\))?$/, ` (${i})`);
    taken.add(stem);
    states.push({ path: stem + ".state", data: bytes,
                  solo: base + " (" + stem.slice(stem.lastIndexOf("/") + 1) + ").state" });
    const picBytes = await exportBlobBytes(rec.pic);
    if (picBytes) states.push({ path: stem + exportImgExt(rec.pic), data: picBytes });
  }
  const what = [quick && "Quick", slots && plural(slots, "slot"),
                autoBytes?.length && "where you left off", moments && plural(moments, "moment")]
    .filter(Boolean).join(", ");
  add("states", "Progress", "Save states", what + " · dingbat only", states);

  const kept = await getKeptSave(name);
  if (kept) {
    const when = kept.at ? exportDay(kept.at) : "";
    const stem = (kept.why === "replaced" ? "Replaced save" : "Save from before you deleted it") +
                 (when ? " " + when : "");
    add("kept", "Progress", kept.why === "replaced" ? "Replaced save" : "Old save",
        (kept.why === "replaced" ? "The save you replaced" : "From before you deleted it") +
        (kept.at ? " · " + fmtStateTime(kept.at) : "") + " · .sav",
        [{ path: "old saves/" + stem + ".sav", data: exportBytes(kept.data),
           solo: base + " (" + stem.toLowerCase() + ").sav" }]);
  }

  const photos = cameraPhotos(rom, sav);
  add("camera", "Pictures", "Camera photos",
      plural(photos.length, "photo") + " from the camera's album · .png",
      photos.map((p) => ({ path: "camera/Photo " + String(p.number).padStart(2, "0") + ".png",
                           data: greyPng2(p.pixels, CAM_PHOTO_W, CAM_PHOTO_H) })));

  const prints = printerPhotos.filter((p) => p?.game === name);
  const printFiles = [];
  for (const p of prints) {
    const png = exportDataUrl(p.png);
    let stem = "prints/" + exportStamp(p.ts);
    for (let i = 2; taken.has(stem); i++) stem = stem.replace(/( \(\d+\))?$/, ` (${i})`);
    taken.add(stem);
    if (png) printFiles.push({ path: stem + png.ext, data: png.bytes });
  }
  add("prints", "Pictures", "Printed photos",
      plural(printFiles.length, "Game Boy Printer photo") + " · .png", printFiles);

  const frame = await getRomFrame(name);
  add("thumb", "Pictures", "Library thumbnail", "The picture on its tile · " + exportImgExt(frame),
      [{ path: "pictures/Thumbnail" + exportImgExt(frame), data: await exportBlobBytes(frame),
         solo: base + exportImgExt(frame) }]);
  const art = await getRomArt(name);
  add("art", "Pictures", "Box art", "The cover it came with · " + exportImgExt(art),
      [{ path: "pictures/Box art" + exportImgExt(art), data: await exportBlobBytes(art),
         solo: base + " box art" + exportImgExt(art) }]);

  const cheats = await dbGet(CHEATS_KEY(name));
  const cheatList = Array.isArray(cheats) ? cheats : [];
  add("cheats", "Extras", "Cheats", plural(cheatList.length, "code") + " · .cht",
      [{ path: base + ".cht", data: cheatList.length ? new TextEncoder().encode(serializeCheats(cheatList)) : null,
         solo: base + ".cht" }]);
  return items;
};

const exportSize = (item) => item.files.reduce((s, f) => s + f.data.length, 0);

// The file the chosen rows become: { fileName, blob, count }. One file goes
// out bare; anything more is a zip with info.json in it.
const exportPackage = (name, chosen, now = Date.now()) => {
  const files = chosen.flatMap((it) => it.files.map((f) => ({ ...f, kind: it.kind })));
  if (files.length === 1) {
    const f = files[0];
    const fileName = f.solo || f.path.slice(f.path.lastIndexOf("/") + 1);
    return { fileName, blob: new Blob([f.data], { type: "application/octet-stream" }),
             count: 1 };
  }
  const info = {
    app: "dingbat",
    format: 1,
    game: name,
    system: systemOf(name),
    exported: new Date(now).toISOString(),
    files: files.map((f) => ({ path: f.path, kind: f.kind })),
  };
  const entries = [
    { name: "info.json", data: new TextEncoder().encode(JSON.stringify(info, null, 2) + "\n") },
    ...files.map((f) => ({ name: f.path, data: f.data })),
  ];
  const base = exportSafeName(stripExt(name) || name);
  return { fileName: base + " — dingbat " + exportDay(now) + ".zip",
           blob: ZipWrite.blob(entries, new Date(now)), count: chosen.length };
};

const exportDownload = (fileName, blob) => {
  let a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = fileName;
  a.click();
  // Safari starts the download after the click returns; a revoke right away
  // can cancel it.
  setTimeout(() => URL.revokeObjectURL(a.href), 60000);
};

// What was ticked last time, the ROM never among it.
const exportTicks = async () => {
  let t = await dbGet(EXPORT_TICKS_KEY).catch(() => null);
  return t && typeof t === "object" ? t : {};
};
const exportTicked = (ticks, kind) => kind !== "rom" && ticks[kind] !== false;

let exportModalOpen = false;

const openExportModal = async (name) => {
  if (exportModalOpen) return;
  exportModalOpen = true;
  let items, ticks;
  try {
    // The running game's battery RAM first, so the .sav is as fresh as the
    // screen.
    if (isRomLoaded(name) && currentRomName) await persistSave(currentRomName, name);
    [items, ticks] = await Promise.all([exportInventory(name), exportTicks()]);
  } catch {
    exportModalOpen = false;
    showToast("Couldn't read this game's files");
    return;
  }
  if (!items.length) {
    exportModalOpen = false;
    showToast("Nothing to export for this game yet");
    return;
  }

  let m;
  const close = () => {
    exportModalOpen = false;
    m.dismiss();
  };
  m = buildSyncModal({ title: "What would you like to export?",
                       hint: displayName(name) + " · " + systemOf(name), onDismiss: close });
  m.modal.classList.add("export-modal");

  const on = new Map(items.map((it) => [it, exportTicked(ticks, it.kind)]));
  const list = document.createElement("div");
  list.className = "export-list";
  const sectioned = items.length >= EXPORT_SECTION_MIN;
  let group = null;
  items.forEach((it, i) => {
    if (sectioned && it.group !== group) {
      group = it.group;
      let h = document.createElement("div");
      h.className = "modal-subhead export-subhead" + (list.children.length ? "" : " no-rule");
      h.textContent = group;
      list.appendChild(h);
    }
    let row = document.createElement("label");
    row.className = "export-row";
    let box = document.createElement("input");
    box.type = "checkbox";
    box.checked = on.get(it);
    // "export-save" and "export-state" are the in-game menu's buttons.
    box.id = "export-pick-" + it.kind;
    let text = document.createElement("span");
    text.className = "export-row-text";
    let label = document.createElement("span");
    label.className = "export-row-label";
    label.textContent = it.label;
    let sub = document.createElement("span");
    sub.className = "export-row-sub";
    sub.textContent = it.sub;
    text.append(label, sub);
    let size = document.createElement("span");
    size.className = "export-row-size";
    size.textContent = formatBytes(exportSize(it));
    row.append(box, text, size);
    row.classList.toggle("off", !box.checked);
    box.addEventListener("change", () => {
      on.set(it, box.checked);
      row.classList.toggle("off", !box.checked);
      refresh();
    });
    list.appendChild(row);
  });

  const foot = document.createElement("div");
  foot.className = "export-foot";
  const footText = document.createElement("div");
  footText.className = "export-foot-text";
  const fileLine = document.createElement("span");
  fileLine.className = "export-file";
  const sumLine = document.createElement("span");
  sumLine.className = "export-sum";
  footText.append(fileLine, sumLine);
  const cancel = document.createElement("button");
  cancel.type = "button";
  cancel.className = "button button-ghost";
  cancel.textContent = "Cancel";
  cancel.addEventListener("click", close);
  const go = document.createElement("button");
  go.type = "button";
  go.className = "button button-primary";
  // The two buttons wrap together, under the file line on a phone.
  const footActions = document.createElement("div");
  footActions.className = "export-foot-actions";
  footActions.append(cancel, go);
  foot.append(footText, footActions);

  const chosen = () => items.filter((it) => on.get(it));
  const refresh = () => {
    const c = chosen();
    const files = c.flatMap((it) => it.files);
    go.disabled = !c.length;
    go.textContent = c.length ? "Export " + c.length : "Export";
    if (!c.length) {
      fileLine.textContent = "Nothing selected";
      sumLine.textContent = "Tick something to export";
      return;
    }
    const bytes = files.reduce((s, f) => s + f.data.length, 0);
    if (files.length === 1) {
      const f = files[0];
      fileLine.textContent = f.solo || f.path.slice(f.path.lastIndexOf("/") + 1);
      sumLine.textContent = formatBytes(bytes) + " · a single file";
    } else {
      fileLine.textContent = exportSafeName(stripExt(name) || name) + " — dingbat " +
                             exportDay(Date.now()) + ".zip";
      sumLine.textContent = plural(c.length, "item") + " · " + formatBytes(bytes);
    }
  };

  go.addEventListener("click", async () => {
    const c = chosen();
    if (!c.length) return;
    const remember = {};
    for (const it of items) if (it.kind !== "rom") remember[it.kind] = on.get(it);
    dbPut(EXPORT_TICKS_KEY, { ...ticks, ...remember }).catch(() => {});
    let pkg;
    try {
      pkg = exportPackage(name, c);
    } catch (e) {
      showToast("Couldn't export: " + e.message);
      return;
    }
    exportDownload(pkg.fileName, pkg.blob);
    showDone(pkg, c);
  });

  const showDone = (pkg, c) => {
    m.heading.textContent = "Exported";
    m.hintEl?.remove();
    m.body.replaceChildren();
    const card = document.createElement("div");
    card.className = "export-done-file";
    const n = document.createElement("span");
    n.className = "export-file";
    n.textContent = pkg.fileName;
    const s = document.createElement("span");
    s.className = "export-sum";
    s.textContent = (pkg.count > 1 ? plural(pkg.count, "item") + " · " : "") +
                    formatBytes(pkg.blob.size) + " · in your downloads";
    card.append(n, s);
    m.body.appendChild(card);
    const kinds = new Set(c.map((it) => it.kind));
    if (kinds.has("states")) {
      const p = document.createElement("p");
      p.className = "modal-hint export-done-note";
      p.textContent = kinds.has("save")
        ? "The .sav opens in any emulator. The save states only open in dingbat."
        : "The save states only open in dingbat.";
      m.body.appendChild(p);
    }
    const actions = document.createElement("div");
    actions.className = "modal-actions";
    // Phones keep downloads out of sight; the share sheet puts the file in
    // Files, AirDrop or a message, which is where it was going anyway.
    const file = typeof File === "function"
      ? new File([pkg.blob], pkg.fileName, { type: pkg.blob.type }) : null;
    if (file && navigator.canShare?.({ files: [file] })) {
      const share = document.createElement("button");
      share.type = "button";
      share.className = "button";
      share.textContent = "Share…";
      share.addEventListener("click", () => {
        navigator.share({ files: [file] }).catch(() => {});
      });
      actions.appendChild(share);
    }
    const done = document.createElement("button");
    done.type = "button";
    done.className = "button button-primary";
    done.textContent = "Done";
    done.addEventListener("click", close);
    actions.appendChild(done);
    m.body.appendChild(actions);
    done.focus();
  };

  m.body.append(list, foot);
  refresh();
  // On Export: what was ticked last time goes with one press (Enter, or A on
  // a pad), and the boxes are an arrow away.
  go.focus();
};

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
  let hintEl = null;
  if (hint) {
    hintEl = document.createElement("p");
    hintEl.className = "modal-hint";
    hintEl.textContent = hint;
    modal.appendChild(hintEl);
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
    overlay, modal, body, heading: h, hintEl,
    dismiss: () => {
      document.removeEventListener("keydown", onKey, true);
      releaseFocus(overlay);
      overlay.remove();
    },
  };
};

// --- Connect / disconnect -------------------------------------------------
// Through the broker when it answers (one consent screen, then no more
// popups); otherwise the token flow's account chooser.
const gdriveConnect = async () => {
  let acct;
  // The popup must open inside the tap, so a known probe answer is taken as
  // it stands (resumeDriveOnBoot probes early); only a first tap waits.
  let viaBroker = driveBrokerProbedAt ? driveBrokerOk : await probeDriveBroker();
  probeDriveBroker(); // refresh a stale answer for next time
  driveConnecting++;
  try {
    if (viaBroker) {
      await driveCodeGrant(syncState.email, { connect: true });
    } else {
      await gdriveAcquireToken(undefined, syncState.email, { connect: true });
      // A refresh token left from an earlier grant may be another account's.
      syncState.refresh = null;
    }
    acct = await gdriveFetchEmail();
  } finally {
    driveConnecting--;
  }
  // The refresh token the broker sign-in stored is another account's than
  // the one confirmed (a re-grant swapped the token meanwhile): dropped, or
  // every silent renewal would fetch that account's token with this one
  // loaded (bug_refresh_token_outlives_its_account).
  if (syncState.refresh && acct && syncState.refreshAcct !== acct) syncState.refresh = null;
  // Whose token this is could not be learned, and another account's queued
  // work, tombstones and renames are what is loaded: syncing now could send
  // them to this one. Better to ask again.
  if (!acct && syncState.acct) {
    syncState.refresh = null;
    clearDriveToken();
    // A session of its own ends with it: a refresh it started (a Drive-only
    // tile's ensureDriveSignedIn) would otherwise land as current and adopt
    // the refused account's token (bug_refresh_of_refused_signin).
    driveSession++;
    throw new Error("Couldn't confirm which Google account signed in — try again");
  }
  driveSession++; // a new session, whichever account it is
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
      let upgrade = driveWantsUpgrade();
      if (!(await driveRefreshSilently({ force: true }))) {
        if (!driveLinked()) throw new Error("signed out"); // → Sign in below
        await driveRegrantPopup();
      }
      driveRenewFails = 0;
      // The consent screen offers the account chooser too.
      if (!gdriveEmail || upgrade) await gdriveFetchEmail();
      refreshSyncUI();
      refreshHomeRecent();
      return true;
    } catch (e) {
      // Declined the consent screen: not a reason to show it again now.
      if (e instanceof DriveUpgradeDeclined) { showToast(e.message); return false; }
      // Grant gone or popup blocked: ask properly.
    }
  }
  try { await gdriveConnect(); }
  catch (e) { showToast(e.message); return false; }
  return syncActive();
};

// --- Keeping the session alive -------------------------------------------
// ~1h tokens. With a refresh token and a live broker, renewal is a fetch,
// done as soon as the token goes stale. Otherwise even the silent re-grant
// is a popup needing transient activation, so a one-shot listener does it
// on the next pointerdown/keydown/touchstart. Renewal starts this long
// before expiry.
const DRIVE_RENEW_LEAD_MS = 10 * 60 * 1000;
// Consecutive silent-renew rejections before the signed-out UI; each costs a popup.
const DRIVE_RENEW_MAX_FAILS = 3;

let driveRenewArmed = false;
let driveRenewFails = 0;

const driveTokenStale = () =>
  !gdriveToken || gdriveTokenExp - Date.now() < DRIVE_RENEW_LEAD_MS;

// The token needs renewing: now, through the broker, when this device has
// a refresh token and the broker has not just failed; else on a gesture.
const armDriveRenewOnGesture = () => {
  if (!GDRIVE_CLIENT_ID || !syncState.connected) return;
  if (driveRefreshUsable() && driveBrokerBase() && Date.now() >= driveBrokerRetryAt) {
    renewDriveToken({ gesture: false });
    return;
  }
  armDriveRenewListener();
};

// Listener only. renewDriveToken's fallbacks come here, never back through
// armDriveRenewOnGesture, so a failing broker cannot loop.
const armDriveRenewListener = () => {
  if (!GDRIVE_CLIENT_ID || !syncState.connected) return;
  if (driveRenewArmed) return;
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

// Silent re-grant, with a live token (rollover) or none (resume): through
// the broker when this device has a refresh token, else the popup, which
// only a gesture may open.
const renewDriveToken = async ({ gesture = true } = {}) => {
  if (!GDRIVE_CLIENT_ID || !syncState.connected) return;
  if (appUpdating) return; // reload imminent: a popup now would be orphaned
  if (navigator.onLine === false) { armDriveRenewListener(); return; }
  const wasSignedOut = !gdriveToken;
  // Signed out (or in again) while this was waiting: not this renewal's
  // business any more.
  const live = driveSessionGuard();
  const over = () => {
    try { live(); } catch { return true; }
    return !syncState.connected;
  };

  if (await driveRefreshSilently()) {
    driveRenewFails = 0;
    if (wasSignedOut && !over()) await driveSessionResumed(over);
    return;
  }
  if (!gesture) { armDriveRenewListener(); return; }

  const upgrade = driveWantsUpgrade();
  // Armed only to offer the upgrade, which has lapsed since: nothing to do.
  if (!upgrade && !driveTokenStale()) return;

  // A script-load failure (offline) must not count against the fail budget.
  // (The consent screen is our own popup and needs no script.)
  if (!upgrade) {
    try { await loadGisScript(); }
    catch { armDriveRenewListener(); return; }
    if (over()) return;
  }

  // Activation lasts about five seconds and may have aged out while the
  // script loaded; a refused popup would spend a strike, so wait.
  if (!hasUserActivation()) { armDriveRenewListener(); return; }

  try {
    await driveRegrantPopup();
  } catch (e) {
    // Refused because the session ended: not a strike.
    if (over()) return;
    // Declined the consent screen: not a strike either. The token flow
    // takes the next tap, if the token needs one.
    if (e instanceof DriveUpgradeDeclined) {
      if (driveTokenStale()) armDriveRenewListener();
      return;
    }
    // Popup blocked or grant gone: retry on the next gesture until the
    // budget runs out.
    if (++driveRenewFails >= DRIVE_RENEW_MAX_FAILS) {
      clearDriveToken();
      renderGdriveSection();
      refreshSyncUI();
      refreshHomeRecent();
    } else {
      armDriveRenewListener();
    }
    return;
  }

  if (over()) return;
  driveRenewFails = 0;
  if (upgrade && syncState.refresh) {
    showToast("You'll stay signed in to Drive on this device");
  }
  // A pure rollover changed nothing the user sees; the consent screen may
  // have changed the account.
  if (!wasSignedOut && !upgrade) return;
  await driveSessionResumed(over);
};

// A token again after a gap: name the account, redraw, catch up. `over`
// is the caller's check that its session is still the live one.
const driveSessionResumed = async (over) => {
  await gdriveFetchEmail();
  if (over()) return;
  renderGdriveSection();
  refreshSyncUI();
  refreshHomeRecent();
  await pullSync();
};

// Boot resume: reuse a persisted token within its lifetime, confirmed via
// tokeninfo (a plain fetch); otherwise arm the first-gesture re-grant.
const resumeDriveOnBoot = async () => {
  // Learn early whether the broker answers: a signed-out device's Sign in
  // must choose its popup inside the tap (gdriveConnect), and a popup-flow
  // device is moved onto the broker at its next tap.
  if (GDRIVE_CLIENT_ID && !syncState.refresh) {
    probeDriveBroker().then(() => { if (driveWantsUpgrade()) armDriveRenewListener(); });
  }
  if (!GDRIVE_CLIENT_ID || !syncState.connected) return;
  if (gdriveToken) return;
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
      if (live) {
        let info = await r.json();
        rememberDriveEmail(info.email);
        await adoptDriveAccount(typeof info.sub === "string" ? info.sub : null);
      }
    } catch {
      // Offline at boot: keep the token; the sync path's 401 handling covers it.
      live = true;
    }
    if (live) {
      refreshSyncUI();
      refreshHomeRecent();
      // Then what the last visit queued and never sent (a page closed within
      // the flush's debounce): after the pull, so it is held to what Drive
      // holds now, and not left until the next poll.
      pullSync().then(() => { if (pendingCount()) flushSync(); });
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
  if (GDRIVE_CLIENT_ID && syncState.connected) {
    if (driveTokenStale()) armDriveRenewOnGesture();
    else if (!syncState.refresh) probeDriveBroker().then(() => {
      if (driveWantsUpgrade()) armDriveRenewListener();
    });
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
// The account slot in the bar (home screen only): "Sign in" signed out, the
// account's initial with a sync badge signed in. Both open the account menu,
// #account-pop - so the bar never carries Google's mark, and the menu has
// room to say what signing in is for before Google's own button asks.
const accountSlot = document.getElementById("account-slot");
const accountBtn = /** @type {HTMLButtonElement} */ (document.getElementById("account-btn"));
const accountAvatar = document.getElementById("account-avatar");
const accountPop = document.getElementById("account-pop");
let accountPopOpen = false;

// How sync is doing, as the badge says it: fine, busy, or asking for you.
// "Linked" (syncState.connected), not the hour-long token: a token rolling
// over is not a sign-out, and the slot never demands one for it.
const accountSyncKind = () =>
  syncStatus === "syncing" ? "syncing"
  : syncStatus === "offline" || syncStatus === "paused" ? "attention"
  : "ok";

const accountInitial = () => {
  const who = gdriveEmail || syncState.email || "";
  const c = Array.from(who.trim())[0];
  return c ? c.toUpperCase() : "";
};

const PERSON_SVG = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="9" r="3.6"/>' +
  '<path d="M5 19.5c1.2-3.3 3.9-5 7-5s5.8 1.7 7 5"/></svg>';

// The status box in the signed-in menu: a heading and a line under it.
const accountStatusText = () => {
  const n = pendingCount();
  const waiting = n + (n === 1 ? " change" : " changes");
  if (syncStatus === "syncing") return ["Syncing with Google Drive…", n ? waiting + " going up." : "Checking for changes."];
  if (syncStatus === "offline") return ["Can't reach Google Drive",
    (n ? waiting + " waiting. They" : "Your changes") + " are safe on this device and upload when Drive is back."];
  if (syncStatus === "paused") return ["Google Drive needs you again",
    "Sync now reconnects. Your changes are safe on this device."];
  if (!gdriveToken) return ["Games and saves are in your Drive", "Reconnects when you next sync."];
  return ["Games and saves are in your Drive", n ? waiting + " waiting to go up." : "Everything is synced."];
};

const acctOut = document.getElementById("acct-out");
const acctIn = document.getElementById("acct-in");
const acctAvatar = document.getElementById("acct-avatar");
const acctEmail = document.getElementById("acct-email");
const acctStatus = document.getElementById("acct-status");
const acctStatusTitle = document.getElementById("acct-status-title");
const acctStatusSub = document.getElementById("acct-status-sub");
const accountGoogle = /** @type {HTMLButtonElement} */ (document.getElementById("account-google"));
const accountSync = /** @type {HTMLButtonElement} */ (document.getElementById("account-sync"));

// The menu's two faces, filled in place: its buttons are the same elements
// all along, so a sync that re-renders it mid-click never swaps the button
// being pressed.
const renderAccountPop = () => {
  if (!accountPop) return;
  const linked = driveLinked();
  acctOut.hidden = linked;
  acctIn.hidden = !linked;
  if (!linked) return;
  const kind = accountSyncKind();
  const [title, sub] = accountStatusText();
  const who = gdriveEmail || syncState.email || "";
  const initial = accountInitial();
  if (initial) acctAvatar.textContent = initial;
  else acctAvatar.innerHTML = PERSON_SVG;
  acctEmail.textContent = who;
  acctEmail.hidden = !who;
  acctStatus.className = "acct-status acct-" + kind;
  acctStatusTitle.textContent = title;
  acctStatusSub.textContent = sub;
  accountSync.textContent = kind === "syncing" ? "Syncing…" : "Sync now";
  accountSync.disabled = kind === "syncing";
};

// gdriveConnect() must be reached with the click's activation live, so
// nothing may be awaited before the call.
accountGoogle?.addEventListener("click", async () => {
  accountGoogle.disabled = true;
  try { await gdriveConnect(); }
  catch (e) { showToast(e.message); }
  accountGoogle.disabled = false;
  refreshSyncUI();
});
accountSync?.addEventListener("click", async () => {
  // Linked but tokenless: this gesture buys the new token.
  if (!(await ensureDriveSignedIn())) return;
  runFullSync({ label: "Syncing" });
});
document.getElementById("account-signout")?.addEventListener("click", () => {
  closeAccountPop();
  gdriveSignOut();
});
// Two taps, as in Settings: it reaches every device, and the first could be
// a slip. The menu closing, or a pause, disarms it.
const accountEverywhere = /** @type {HTMLButtonElement | null} */ (document.getElementById("account-everywhere"));
const EVERYWHERE_LABEL = "Sign out everywhere";
let everywhereTimer = null;
const disarmEverywhere = () => {
  clearTimeout(everywhereTimer);
  if (!accountEverywhere) return;
  accountEverywhere.classList.remove("armed");
  accountEverywhere.textContent = EVERYWHERE_LABEL;
};
accountEverywhere?.addEventListener("click", async () => {
  if (!accountEverywhere.classList.contains("armed")) {
    accountEverywhere.classList.add("armed");
    accountEverywhere.textContent = "Tap again to sign out everywhere";
    everywhereTimer = setTimeout(disarmEverywhere, 4000);
    return;
  }
  disarmEverywhere();
  closeAccountPop();
  await gdriveSignOutEverywhere();
});

const refreshHomeSyncButton = () => {
  if (!accountSlot) return;
  // A build with no client ID has no account to speak of.
  accountSlot.hidden = !GDRIVE_CLIENT_ID;
  const linked = driveLinked();
  accountBtn.classList.toggle("signed-in", linked);
  accountBtn.dataset.sync = linked ? accountSyncKind() : "";
  // Signed out it is a quiet outline of a person, not a word: the bar's one
  // word is the wordmark.
  const initial = linked ? accountInitial() : "";
  if (initial) accountAvatar.textContent = initial;
  else accountAvatar.innerHTML = PERSON_SVG;
  const label = linked ? "Google Drive: " + (SYNC_WORDS[syncStatus] || "Signed in") : "Sign in";
  accountBtn.title = label;
  accountBtn.setAttribute("aria-label", label);
  if (accountPopOpen) renderAccountPop();
};

const closeAccountPop = () => {
  if (!accountPop || !accountPopOpen) return;
  accountPopOpen = false;
  accountPop.hidden = true;
  disarmEverywhere();
  accountBtn.setAttribute("aria-expanded", "false");
};

const openAccountPop = () => {
  renderAccountPop();
  accountPopOpen = true;
  accountPop.hidden = false;
  accountBtn.setAttribute("aria-expanded", "true");
  accountPop.querySelector?.("button")?.focus?.({ preventScroll: true });
};

if (accountBtn) {
  accountPop.hidden = true;
  accountBtn.addEventListener("click", (e) => {
    e.stopPropagation?.();
    if (accountPopOpen) closeAccountPop();
    else openAccountPop();
  });
  // Anywhere else closes it, as Escape does.
  document.addEventListener("pointerdown", (e) => {
    if (!accountPopOpen) return;
    const t = /** @type {Node} */ (e.target);
    if (accountPop.contains?.(t) || accountBtn.contains?.(t)) return;
    closeAccountPop();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeAccountPop();
  });
}

// With no games there is no library head, so the hero carries the Drive
// slot: the two ways to get a game sit on one rung, the quieter one second.
// Same two labels the head uses, so the slot has one name wherever it
// appears. It withdraws the moment there is a library to head.
const homeDriveBtn = /** @type {HTMLButtonElement} */ (document.getElementById("home-drive"));
const homeDriveRow = document.getElementById("home-drive-row");
// null until the library has been read: the sync UI refreshes at boot,
// before that, and must not decide either way (a false here marked an empty
// library as having games, hiding the empty state for a frame or two).
let libraryEmpty = /** @type {boolean | null} */ (null);

// Google's own button, as it supplies it (signin-assets.zip, Android + Web,
// pill with text): its branding rules allow no redrawing. One file per
// theme; the stylesheet shows the one that matches.
const GOOGLE_BUTTON_HTML =
  '<img class="gsi-dark" src="google-signin-dark.svg" alt="" width="180" height="40">' +
  '<img class="gsi-light" src="google-signin-light.svg" alt="" width="180" height="40">';

// --- The first picture -----------------------------------------------------
// A fresh visit opens on the brand with the library under it (the hero
// appears only once a game is played in this visit: playedThisVisit). The
// library comes out of IndexedDB a few frames after the page paints, and
// painting under the brand before then showed the empty state's drop box
// first. Where the last visit had games, index.html's head adds
// html.home-pending: the brand paints at once, what goes under it waits
// (styles.css) and fades in once the first render has its pictures. With
// no hint - a first visit, an empty library - nothing waits, and the empty
// state paints as early as it always did.
const LIB_HINT_KEY = "dingbat_library";
// However the read goes, the page shows by then.
const HOME_REVEAL_MAX_MS = 2000;
// How long the first render waits on its pictures before it shows anyway.
const HOME_PICTURES_MAX_MS = 400;
let libHint = null;
try { libHint = localStorage.getItem(LIB_HINT_KEY); } catch {}
let homePending = !!document.documentElement.classList?.contains("home-pending");
// A library's side of the page - no drop box, the account in the bar -
// from the start.
if (homePending) document.body.classList.add("lib-has-games");
// Set by a launch: from then on the page is headed by that game's hero
// (paused, then Last played after a close) rather than the brand.
let playedThisVisit = false;

const revealHome = () => {
  if (!homePending) return;
  homePending = false;
  document.documentElement.classList.remove("home-pending");
  // The brand was up all along; what was held under it fades in.
  const inner = document.getElementById("home-inner");
  for (const el of /** @type {HTMLCollectionOf<HTMLElement>} */ (inner?.children ?? [])) {
    if (el.id !== "home-brand" && el.animate) {
      el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 260, easing: "ease-out" });
    }
  }
};
if (homePending) setTimeout(revealHome, HOME_REVEAL_MAX_MS);
const noteLibraryHint = () => {
  if (libraryEmpty === null) return;
  const v = libraryEmpty ? "empty" : "games";
  if (v === libHint) return;
  libHint = v;
  try { localStorage.setItem(LIB_HINT_KEY, v); } catch {}
};

const refreshHomeEmptyActions = () => {
  // Which way in from a file is on screen: the empty state's with no library
  // to speak of, the library head's #lib-add once there is one. Stated the
  // positive way round on purpose - before the first refresh neither class
  // is set, and the empty state is the right thing to be showing then.
  if (libraryEmpty !== null) document.body.classList.toggle("lib-has-games", !libraryEmpty);
  noteLibraryHint();
  if (!homeDriveBtn) return;
  const shown = libraryEmpty === true && !!GDRIVE_CLIENT_ID;
  homeDriveBtn.hidden = !shown;
  if (homeDriveRow) homeDriveRow.hidden = !shown;
  if (!shown) return;
  homeDriveBtn.disabled = false;
  // Signed out it is a Google sign-in button, drawn the way Google's rules
  // require; signed in to an account with nothing on it yet, a plain Sync.
  const linked = driveLinked();
  homeDriveBtn.className = linked ? "button" : "gsi-btn";
  if (linked) {
    homeDriveBtn.textContent = "Sync";
    homeDriveBtn.removeAttribute("aria-label");
  } else {
    homeDriveBtn.innerHTML = GOOGLE_BUTTON_HTML;
    homeDriveBtn.setAttribute("aria-label", "Sign in with Google");
  }
  const lead = document.getElementById("home-drive-lead");
  if (lead) lead.hidden = linked;
};

if (homeDriveBtn) {
  homeDriveBtn.addEventListener("click", async () => {
    if (driveLinked()) {
      if (!(await ensureDriveSignedIn())) return;
      runFullSync({ label: "Syncing" });
      return;
    }
    // gdriveConnect() must be reached with the click's activation still
    // live, so nothing may be awaited before the call.
    homeDriveBtn.disabled = true;
    try { await gdriveConnect(); }
    catch (e) { showToast(e.message); }
    refreshHomeEmptyActions();
  });
}

const refreshSyncUI = () => {
  refreshHomeSyncButton();
  refreshHomeEmptyActions();
  renderSyncIndicator();
  if (settingsModal.classList.contains("open")) renderGdriveSection();
};
// The markup starts the slot hidden; seed the signed-out boot state.
refreshHomeSyncButton();

// --- Core-construction settings ---
// JS mirrors of the wasm-side option vars; effective at the next core construction.

var gbaBiosMode = 0; // 0 = HLE, 1 = real BIOS, 2 = real BIOS boot + HLE calls
var gbaRunBios = true;
// Presentation-side only: no wasm setter in applySystemSettings.
var gbRumble = true;
// Rewind, on by default; a "system" record with no rewindOn key stays on
// (loadSystemSettings). Off stops allocating the wasm ring.
var rewindOn = true;

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
  if (Module._wasm_set_gba_bios_mode) Module._wasm_set_gba_bios_mode(gbaBiosMode);
  if (Module._wasm_set_gba_run_bios) Module._wasm_set_gba_run_bios(gbaRunBios ? 1 : 0);
  if (Module._wasm_sgb_enable) Module._wasm_sgb_enable(sgbEnable ? 1 : 0);
  // The border switch is live: it only hides a layer the core has.
  if (Module._wasm_sgb_border_show) Module._wasm_sgb_border_show(sgbBorder ? 1 : 0);
  // Live in both directions.
  if (Module._setRewindEnabled) Module._setRewindEnabled(rewindOn ? 1 : 0);
};

const syncSystemSettingsUI = () => {
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
  rewindToggle.checked = rewindOn;
  applyRewindUI();
};

const saveSystemSettings = () => {
  applySystemSettings();
  applyRewindUI();
  if (db) dbPut("system",
    { gbaBiosMode, gbaRunBios, gbRumble, rewindOn, sgbEnable, sgbBorder });
};

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

const loadSystemSettings = async () => {
  let s = await dbGet("system");
  if (s) {
    if ([0, 1, 2].includes(s.gbaBiosMode)) gbaBiosMode = s.gbaBiosMode;
    if (typeof s.gbaRunBios === "boolean") gbaRunBios = s.gbaRunBios;
    if (typeof s.gbRumble === "boolean") gbRumble = s.gbRumble;
    if (typeof s.sgbEnable === "boolean") sgbEnable = s.sgbEnable;
    if (typeof s.sgbBorder === "boolean") sgbBorder = s.sgbBorder;
    // Only a real boolean: a record predating the setting leaves the default.
    if (typeof s.rewindOn === "boolean") rewindOn = s.rewindOn;
  }
  syncSystemSettingsUI();
  applySystemSettings();
};

// --- Save webhook (Settings > General > Advanced) ---
// Every in-game save, as it is written, is also POSTed to a URL of the
// player's: multipart form data, fields "save" (the file), "game", "player"
// and "savedAt". Form data keeps it a CORS-simple request, sent no-cors, so
// it lands whether or not the receiver answers with CORS headers; the answer
// is never read, and only a network failure is seen.
// Synced across a Drive account's devices in its own Drive file (not the
// library, which older builds rewrite with only the fields they know; they
// skip a file they cannot name, parseDriveFileName): { url, ts }, the newest
// ts wins (syncSaveHook). `dirty` = changed here and not yet on Drive.
const SAVE_HOOK_KEY = "save-hook";
const SAVE_HOOK_FILE = "save-hook";
let saveHook = { url: "", ts: 0, dirty: false };
const saveHookInput = /** @type {HTMLInputElement} */ (document.getElementById("save-hook-url"));
const saveHookStatus = document.getElementById("save-hook-status");

const setSaveHookStatus = (text) => {
  if (saveHookStatus) saveHookStatus.textContent = text;
};

// "" or an absolute http(s) URL; null for anything else.
const normalizeSaveHookUrl = (s) => {
  s = String(s || "").trim();
  if (!s) return "";
  try {
    let u = new URL(s);
    return u.protocol === "http:" || u.protocol === "https:" ? u.href : null;
  } catch { return null; }
};

const adoptSaveHook = async (rec) => {
  let changed = rec.url !== saveHook.url;
  saveHook = { url: rec.url, ts: rec.ts, dirty: !!rec.dirty };
  if (db) await dbPut(SAVE_HOOK_KEY, saveHook);
  if (saveHookInput && document.activeElement !== saveHookInput) saveHookInput.value = saveHook.url;
  if (changed) setSaveHookStatus("");
};

const loadSaveHook = async () => {
  let s = await dbGet(SAVE_HOOK_KEY);
  if (s && typeof s === "object") {
    let url = normalizeSaveHookUrl(s.url);
    saveHook = { url: url || "", ts: Number(s.ts) || 0, dirty: !!s.dirty };
  }
  if (saveHookInput) saveHookInput.value = saveHook.url;
};

// A change made here: kept, stamped, and sent to Drive at once when signed
// in (an enrolled device that is signed out sends it at its next pull).
const setSaveHookUrl = async (url) => {
  if (url === saveHook.url) return;
  await adoptSaveHook({ url, ts: Date.now(), dirty: true });
  if (syncActive()) pullSync();
};

if (saveHookInput) saveHookInput.addEventListener("change", async () => {
  let url = normalizeSaveHookUrl(saveHookInput.value);
  if (url === null) {
    setSaveHookStatus("Not a web address — it must start with http:// or https://");
    return;
  }
  saveHookInput.value = url;
  await setSaveHookUrl(url);
  setSaveHookStatus(url ? "Saves will be sent here" : "");
});

// The Drive side, inside a pull (pullSyncInner): Drive's copy when it changed
// since last seen and is newer than this device's, then this device's when
// it has a change Drive has not had.
const syncSaveHook = async (remote, live) => {
  let f = remote.get(SAVE_HOOK_FILE);
  if (f && syncState.rmt[SAVE_HOOK_FILE] !== f.modifiedTime) {
    let bytes = live(await driveDownload(f.id));
    let o = null;
    try { o = JSON.parse(new TextDecoder().decode(bytes)); } catch {}
    syncState.rmt[SAVE_HOOK_FILE] = f.modifiedTime;
    let ts = Number(o?.ts) || 0;
    let url = normalizeSaveHookUrl(o?.url);
    if (url !== null && ts > saveHook.ts) live(await adoptSaveHook({ url, ts, dirty: false }));
  }
  if (!saveHook.dirty) return;
  let sent = { url: saveHook.url, ts: saveHook.ts };
  let res = live(await driveUploadFile(SAVE_HOOK_FILE,
    new TextEncoder().encode(JSON.stringify(sent)), f?.id));
  let meta = live(await res?.json?.().catch(() => null));
  if (meta?.modifiedTime) syncState.rmt[SAVE_HOOK_FILE] = meta.modifiedTime;
  // Changed again while on the wire: still dirty, sent next time.
  if (saveHook.ts === sent.ts) await adoptSaveHook({ ...sent, dirty: false });
};

// Fire and forget.
const postSaveToHook = (game, data) => {
  let url = saveHook.url;
  if (!url || !data || !data.length) return;
  let form = new FormData();
  form.append("game", game);
  form.append("savedAt", new Date().toISOString());
  form.append("save", new Blob([new Uint8Array(data)], { type: "application/octet-stream" }),
              stripExt(game) + ".sav");
  // keepalive lets a save written as the page is hidden still leave, but
  // keepalive bodies share a 64 KiB budget, so only then.
  let keepalive = document.visibilityState === "hidden" && data.length <= 48 * 1024;
  fetch(url, { method: "POST", mode: "no-cors", body: form, keepalive })
    .then(() => setSaveHookStatus("Last sent " + new Date().toLocaleTimeString() +
                                  " · " + displayName(game)))
    .catch((e) => {
      console.warn("Save webhook POST failed:", e);
      setSaveHookStatus("Couldn't reach it at " + new Date().toLocaleTimeString());
    });
};

// --- Recent ROMs ---
//   "recent"      metadata index: [{ name, ts }], most-recent-first, capped
//   "rom:<name>"  { name, data: Uint8Array }, fetched only at launch/backup
//   "art:<name>"  Blob, fetched lazily by the grid
//   "frame:<name>" Blob (JPEG), the last screen the game showed; the grid's
//                 thumbnail, fetched lazily like the art (see storeLastFrame)
// Bytes stay out of the index and tile closures: a few GBA ROMs in the JS
// heap get the wasm JIT demoted on iOS Safari.

// How many bytes of ROM this device keeps. A budget, not a count: the games
// it bounds run from 32 KB to 32 MB, so "twenty games" - which is what this
// was, dating from when ROMs lived base64-encoded inside localStorage's 5 MB
// - meant either half a megabyte or two thirds of a gigabyte depending on
// whose library it was. Past the line the bytes go and the entry stays, so
// drawing it in the wrong place costs a tap to find the file again, not a
// game.
//
// A share of what the browser says this origin may hold, rather than a number
// of our own. Every current engine sets that allowance as a fraction of the
// disk - around 60% on Chrome and on Safari 17 and later, min(10%, 10 GiB) on
// Firefox - so it is a different figure on a phone and a desktop, and a
// different figure again on the same disk in a private window: two Chromiums
// on one 199 GB disk here reported 4 GB and 10 GB. Half of it leaves room for
// the saves, states and pictures this budget does not count, and keeps a
// refused write exceptional rather than routine. Clamped at both ends: worth
// having on a nearly-full disk, and never hundreds of gigabytes on a large
// one merely because the browser would allow it.
const ROM_BUDGET_SHARE = 0.5;
const ROM_BUDGET_MIN = 256 * 1024 * 1024;
const ROM_BUDGET_MAX = 16 * 1024 * 1024 * 1024;
const ROM_BUDGET_FALLBACK = 2 * 1024 * 1024 * 1024; // no estimate() to ask

// estimate() is deliberately coarse and can be slow enough to notice, and the
// answer moves only as the disk does, so one reading a minute is as current as
// a line drawn this roughly needs.
const QUOTA_TTL_MS = 60 * 1000;
let quotaBytes = 0;
let quotaAskedAt = 0;
const storageQuota = async () => {
  if (!navigator.storage?.estimate) return 0;
  if (quotaBytes && Date.now() - quotaAskedAt < QUOTA_TTL_MS) return quotaBytes;
  try {
    let est = await navigator.storage.estimate();
    quotaAskedAt = Date.now();
    quotaBytes = est?.quota || 0;
  } catch { /* leave the last reading standing */ }
  return quotaBytes;
};

// The browser's real limit is lower than what it estimated often enough to
// matter, and it is only ever reported by a write failing, so that is where it
// is learned - the ROM bytes being held when one last fit. Session-scoped on
// purpose: tomorrow's free space is not today's, and a figure kept across
// restarts would hold a device small long after the disk had been cleared.
let romCeiling = Infinity;

const romBudget = async () => {
  let quota = await storageQuota();
  let share = quota ? quota * ROM_BUDGET_SHARE : ROM_BUDGET_FALLBACK;
  // The clamp first, then the ceiling: a device that has proved it cannot
  // hold even the floor is telling the truth, and outranks any of this.
  return Math.min(romCeiling,
                  Math.max(ROM_BUDGET_MIN, Math.min(ROM_BUDGET_MAX, share)));
};

const romKey = (name) => "rom:" + name;
const artKey = (name) => "art:" + name;
const frameKey = (name) => "frame:" + name;

// How big each game is, by name. Local only: the key does not parse as a
// Drive file name, so it is never uploaded, and it describes this device's
// idea of a size that is the same everywhere anyway. IndexedDB cannot give
// a record's size without reading it, and a ROM is up to 32 MB, so the
// figure is noted when it is already in hand - on import, on download, and
// from the Drive listing - and only read from the ROM itself as a last
// resort, once, off the back of an explicit menu.
const ROM_SIZES_KEY = "romsizes";
/** @type {Record<string, number> | null} */
let romSizes = null;
const loadRomSizes = async () => {
  if (!romSizes) romSizes = (await dbGet(ROM_SIZES_KEY)) || {};
  return romSizes;
};
const romSizeOf = (game) => (romSizes && romSizes[game]) || 0;
const noteRomSize = async (game, bytes) => {
  if (!bytes) return;
  await loadRomSizes();
  if (romSizes[game] === bytes) return;
  romSizes[game] = bytes;
  await dbPut(ROM_SIZES_KEY, romSizes);
};

// Drop the ROM record. The pictures and the save data stay, and so does the
// library entry (bumpRecentIndex), so what is left is the game itself minus
// its file: a tile that keeps its face and its save, and says where the file
// has to come from. Remove from this device keeps the frame for the same
// reason; here both pictures stay, there being no Drive copy to re-pull them
// from. The size is noted on the way out, so the menu can still say what
// getting the file back is worth.
const evictLocalRom = async (name) => {
  let rec = await dbGet(romKey(name));
  let n = rec?.data?.byteLength ?? rec?.data?.length ?? 0;
  if (n) await noteRomSize(name, n);
  await dbDelete(romKey(name));
};

// The ROM bytes held here, as far as the size record knows. A game whose size
// was never noted counts nothing, which errs toward keeping files rather than
// evicting on a guess; every launch notes one (getRomBytes), so the blind spot
// closes as the library is used, and the pressure path below covers what it
// misses in the meantime.
const localRomBytes = async () => {
  let local = await localRomSet();
  await loadRomSizes();
  let n = 0;
  for (let name of local) n += romSizeOf(name);
  return n;
};

// A file queued for upload is, as far as the account is concerned, the only
// copy: give it up before it has been sent and the tile goes looking for a
// file nothing has. The polite budget always spares those; the pressure path
// spares them until there is nothing else, losing a copy the person can find
// again being better than losing the write.
const uploadPending = (name) =>
  driveEnrolled() && syncState.queueUp.includes(romKey(name));

// Give up the least-recently-played file. `keep` and the running game are off
// limits, being the two the room is usually wanted for.
const evictOldestRom = async (keep, { sparePending = true } = {}) => {
  let list = await getRecentMeta();
  let local = await localRomSet();
  for (let i = list.length - 1; i >= 0; i--) {
    let name = list[i]?.name;
    if (!name || name === keep || name === currentOriginalName) continue;
    if (!local.has(name)) continue;
    if (sparePending && uploadPending(name)) continue;
    await evictLocalRom(name);
    return name;
  }
  if (sparePending) return evictOldestRom(keep, { sparePending: false });
  return null;
};

// Firefox's name for it, Safari's legacy code, everyone else's name.
const isQuotaError = (e) =>
  !!e && (e.name === "QuotaExceededError" ||
          e.name === "NS_ERROR_DOM_QUOTA_REACHED" || e.code === 22);

// A write that makes room for itself. The budget above is drawn from what the
// browser estimated; the limit that actually stops a write can be under it -
// estimate() is coarse by design, the disk fills behind us, and bytes can be
// reclaimed while the tab is closed. None of that is announced, so the
// failure is the signal: give up the oldest file, try the
// write again, and keep going until it fits or there is no file left to give.
// Only ROM files are given up, never a save - a save is usually the very thing
// being written, and always the thing no one else has a copy of. False means
// even an empty library could not hold it. `superseded()`, asked before each
// retry, says a newer value of the key went in while a file was given up;
// the older one is then not put back over it, and the result is null.
const dbPutRoomy = async (key, value, keep, superseded = () => false) => {
  let freed = 0;
  let evictedCkpts = false;
  // Any retry, after checkpoints or ROMs gave way: both awaits let a newer
  // value (or a reset, delete or import) in (bug_ckpt_evict_retry_*).
  let retried = false;
  let put = true;
  for (;;) {
    if (retried && superseded()) {
      put = null;
      break;
    }
    try {
      await dbPut(key, value);
      break;
    } catch (e) {
      if (!isQuotaError(e)) throw e;
      retried = true;
      // Other games' earlier moments go first, then ROM files.
      if (!evictedCkpts) {
        evictedCkpts = true;
        if (await evictCheckpoints(keep)) continue;
      }
      if (!(await evictOldestRom(keep))) return false;
      freed++;
    }
  }
  if (freed) {
    // Hold the session's line at a figure that demonstrably fit, so the
    // next launch settles the library down to it instead of walking into
    // the same wall one failed write at a time.
    romCeiling = Math.min(romCeiling, await localRomBytes());
    showToast("This device was full - " + (freed === 1
      ? "one game gave up its file" : freed + " games gave up their files") +
      " to make room");
    refreshHomeRecent();
  }
  return put;
};

const getRecentMeta = async () => {
  return (await dbGet("recent")) || [];
};

// "recent" is read, changed and written back by an import, a play, a delete,
// a rename and both Drive sync commits, each with awaits in between. Two of
// those overlapping each write back the list they read, and the later write
// silently undoes the earlier one: a game imported while a pull was out lost
// its tile that way, and a deleted one got its tile back. So every change
// goes through here, one at a time, each starting from the list the one
// before it left. `fn` gets the current list and returns the new one, or
// nothing to leave it; it may await, and may write "recent" itself inside a
// wider transaction (renameGame). It must not call updateRecent: that would
// wait on itself.
let recentChain = Promise.resolve();
const updateRecent = (fn) => {
  const run = recentChain.then(async () => {
    let next = await fn(await getRecentMeta());
    if (next) await dbPut("recent", next);
    return next;
  });
  recentChain = run.catch(() => {}); // a failed change must not block the next
  return run;
};

const getRomBytes = async (name) => {
  let rec = await dbGet(romKey(name));
  let d = rec?.data ?? null;
  if (d instanceof ArrayBuffer) d = new Uint8Array(d);
  if (!(d instanceof Uint8Array) || !d.length) return null;
  // The one moment a size is free: the bytes are already in hand. Games
  // imported by older builds have no recorded size, and the budget cannot
  // count what it cannot measure, so playing one fixes it.
  await noteRomSize(name, d.length);
  return d;
};

const getRomArt = async (name) => (await dbGet(artKey(name))) || null;
const getRomFrame = async (name) => (await dbGet(frameKey(name))) || null;

// --- Last frame ------------------------------------------------------------
// The library tile's thumbnail is the last screen the game showed. It is
// stored as a JPEG Blob at 2x native (480x320 GBA, 320x288 GB) - around
// 20 KB a game - captured whenever play stops being visible: pause, the
// main menu, a save state, a game switch or close, the tab going to the
// background, and a slow tick while running so a killed tab still has a
// recent picture. A Drive kind (parseDriveFileName): each capture queues
// an upload, and the pull brings pictures down for every library game,
// so a Drive-only tile shows the screen another device last saw.
const FRAME_SCALE = 2;
const FRAME_JPEG_Q = 0.75;
const FRAME_TICK_MS = 60000;

// Signature of the framebuffer last stored, so the tick skips an unchanged
// picture (a title screen left running writes once, not every minute).
// One pixel in 61, FNV-1a: tells a menu from play; not a checksum.
let lastFrameSig = null;
const framebufferSig = (heap) => {
  let h = 0x811c9dc5;
  for (let i = 0; i + 2 < heap.length; i += 61 * 4) {
    h ^= heap[i] ^ (heap[i + 1] << 8) ^ (heap[i + 2] << 16);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h;
};

// Paint the framebuffer at native size, scale it up by FRAME_SCALE with
// smoothing off (crisp pixels; the JPEG softens enough on its own). Resolves
// null where toBlob is missing (the test harness's canvas stand-in).
const frameBlobFromFb = (heap, w, h) => new Promise((resolve) => {
  const full = document.createElement("canvas");
  full.width = w;
  full.height = h;
  const fctx = full.getContext("2d");
  const img = fctx.createImageData(w, h);
  img.data.set(heap);
  for (let i = 3; i < img.data.length; i += 4) img.data[i] = 255; // fb alpha is not meaningful
  fctx.putImageData(img, 0, 0);
  const out = document.createElement("canvas");
  out.width = w * FRAME_SCALE;
  out.height = h * FRAME_SCALE;
  const octx = out.getContext("2d");
  octx.imageSmoothingEnabled = false;
  octx.drawImage(full, 0, 0, out.width, out.height);
  if (typeof out.toBlob !== "function") { resolve(null); return; }
  try { out.toBlob(resolve, "image/jpeg", FRAME_JPEG_Q); } catch { resolve(null); }
});

// Store the running game's current picture. `force` skips the unchanged
// check: a pause or a close is worth the write even if nothing moved.
// Single-core only; the link modes draw their own canvases. The framebuffer
// is copied out synchronously, before the first await, and the name with
// it: the game may change while the JPEG encodes. Writes are serialized
// through one chain, so a forced capture landing during the tick's encode
// still stores last (the tick's picture is the older one).
let frameStoreChain = Promise.resolve();
// The screen as it is now, copied out of the wasm heap; null with no core.
const copyFramebuffer = () => {
  if (typeof Module === "undefined" || !Module._wasm_fb_ptr) return null;
  const ptr = Module._wasm_fb_ptr();
  if (!ptr) return null;
  const [w, h] = gameRes();
  return { heap: new Uint8Array(Module.memory.buffer, ptr, w * h * 4).slice(), w, h };
};
const storeLastFrame = ({ force = false } = {}) => {
  if (!currentRomName || !currentOriginalName) return Promise.resolve();
  if (linkMode || rollbackMode || netActive()) return Promise.resolve();
  if (sessionHeldFor === currentOriginalName) return Promise.resolve(); // a boot screen

  const fb = copyFramebuffer();
  if (!fb) return Promise.resolve();
  const { heap, w, h } = fb;
  const sig = framebufferSig(heap);
  if (!force && sig === lastFrameSig) return Promise.resolve();
  lastFrameSig = sig;
  const name = currentOriginalName;
  frameStoreChain = frameStoreChain.then(async () => {
    try {
      const blob = await frameBlobFromFb(heap, w, h);
      if (blob) {
        await dbPut(frameKey(name), blob);
        markUpload(frameKey(name)); // signed in: the other devices' tiles too
      }
    } catch {}
  });
  return frameStoreChain;
};

// The slow tick. Paused, the frame is what the pause stored.
setInterval(() => { if (!paused) storeLastFrame(); }, FRAME_TICK_MS);

// Walk the library newest-first and keep files until the budget is spent;
// from the first game that does not fit, every file after it goes. Strictly
// by recency, so the rule stays sayable: this device holds the files for the
// games you played most recently, up to the budget. Only the bytes go - the
// entry, the pictures and the save stay, because dropping the entry as well
// would strand the save with nothing on screen to account for it and take
// away the one place that could ask for the file back. The merged library
// has never had the budget applied to it, for the same reason.
const enforceRomBudget = async (list) => {
  let local = await localRomSet();
  await loadRomSizes();
  let budget = await romBudget();
  let used = 0;
  let full = false;
  for (let r of list) {
    let name = r?.name;
    if (!name || !local.has(name)) continue;
    // Two files this line never takes: the running game, which is the most
    // recent thing there is whatever the index says (a download can otherwise
    // push it below the line mid-session), and one the account has not been
    // sent yet. Their bytes still count against the budget - they are held
    // either way, and pretending otherwise would just evict something else in
    // their place.
    if (name === currentOriginalName || uploadPending(name)) {
      used += romSizeOf(name);
      continue;
    }
    if (!full) {
      used += romSizeOf(name);
      if (used <= budget) continue;
      full = true; // the one that overflowed goes too
    }
    await evictLocalRom(name);
  }
};

// Move `name` to the front of the index and spend the byte budget over the
// result (ROM files only, never saves).
const bumpRecentIndex = (name, { fresh = false, gen: atLeast = 0 } = {}) => updateRecent(async (all) => {
  // Any game under the name claims it again - an import, a Drive-only
  // tile's download, a launch - and a pull may write under it once more
  // (bug_download_into_away_name_skips_saves).
  renamedAway.delete(name);
  let prev = all.find((r) => r?.name === name);
  let list = all.filter((r) => r.name !== name);
  let ts = Date.now();
  // A relaunch under a not-yet-applied rename marker must not outrank it
  // (the merge would read that as a new claim on the name): pin recency
  // just under the marker. A real re-import (fresh: true) is a new claim.
  if (!fresh) {
    let m = syncState.ren.find((r) => r?.from === name);
    if (m?.ts && ts >= m.ts) ts = m.ts - 1;
  }
  // `imp` is when this game was last really imported, as against merely
  // played. A rename marker from another device is not spent by a play -
  // that device simply has not heard about the rename yet - but it is spent
  // by a fresh import claiming the old name, which is a different game now.
  // mergeLibrary is what reads it.
  let imp = fresh ? ts : prev?.imp;
  // The generation (see genOf) carries over, raised to `atLeast` (a download
  // of files written for a newer one); a game loaded again after this device
  // deleted it starts the next one after the generation deleted.
  let gen = Math.max(genOf(prev), atLeast);
  if (fresh) {
    let t = syncState.tomb.find((x) => x?.name === name);
    if (t) gen = Math.max(gen, genOf(t) + 1);
  }
  list.unshift(withGen(imp ? { name, ts, imp } : { name, ts }, gen));
  await enforceRomBudget(list);
  return list;
});

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
  if (!(await dbPutRoomy(romKey(name), { name, data: new Uint8Array(bytes) }, name))) {
    // The game still plays - it is in the emulator's own filesystem already.
    // What could not be done is keep it, so say that and add no entry: a
    // library row with no file behind it would offer to find a file the
    // person is holding.
    showToast("No room on this device to keep “" + displayName(name) + "”");
    return;
  }
  await noteRomSize(name, bytes.byteLength ?? bytes.length);
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

// `resume`: go back into the game's session if it still matches the save
// (resumeSessionFor), else boot from the save - either way with no offer
// afterwards, the choice having been made on the home screen. Without it the
// boot ends in the "Last session saved" offer, which is what a library tile
// and a file dropped on the page get.
// `session`: a moment to go back into instead (resumeMoment).
const launchRom = async (name, { resume = false, fresh = false, flyFrom = null,
                                 session: chosen = null } = {}) => {
  const gen = nextLoadGen(); // a later tap supersedes this one (loadGen)
  // The grid renders before the wasm runtime is up; wait here.
  await ensureRuntimeReady();
  if (gen !== loadGen) return;
  let data = await getRomBytes(name);
  if (gen !== loadGen) return;
  if (!data) {
    showToast("This game's ROM is no longer stored — load the file again");
    return;
  }
  let session = chosen || (resume ? await resumeSessionFor(name) : null);
  if (gen !== loadGen) return;
  // The flight lands intact only on the frame the session goes back to: the
  // hero, when it is already showing it, else the session's own picture,
  // which the flying one turns into on the way. With neither it goes dark.
  // Measured now, while the picture is still on screen.
  if (flyFrom) {
    const shown = flyFrom === heroShot && heroShowsSession;
    const land = session && !shown ? await sessionPicFor(name, session) : null;
    if (gen !== loadGen) return;
    armFlight(name, flyFrom, !(session && (shown || land)), land);
  }
  await touchRecent(name);
  if (gen !== loadGen) return;
  let ext = name.substring(name.lastIndexOf(".")).toLowerCase();
  return loadRom("rom" + ext, name,
    { gen, rom: data, resume: session, skipResumeOffer: resume || fresh || !!chosen });
};

// Home-screen recent grid: the game library.
const homeRecentWrap = document.getElementById("home-recent-wrap");
const homeInner = document.getElementById("home-inner");
const homeRecentHead = document.getElementById("home-recent-head");
const homeRecent = document.getElementById("home-recent");
const homeThumbsBtn = document.getElementById("home-thumbs");
const storageInfo = document.getElementById("storage-info");

const formatBytes = (bytes) => {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + " MB";
  return (bytes / (1024 * 1024 * 1024)).toFixed(1) + " GB";
};

// Nothing at all until the room starts to run out. A figure in the library
// head is furniture the rest of the time - at 3 MB of 10 GB there is no
// decision it informs, and it sits among links that do something. Then three
// steps, quietest first: the figure, the figure in the colour that means
// trouble, and the figure with the reason.
//
// The top step says what happens and drops the figures: once the words
// explain themselves the numbers inform no decision, and the line is long
// enough on a phone as it is.
//
// "Are removed" describes the rule rather than an event, which is the only
// tense that is true in both cases - ROM files start going at the budget,
// half the allowance, so usually this has been happening for a while by here,
// but a device whose room went on saves and states can reach 95% with nothing
// evicted yet. And it names ROMs, the one thing that does go: saying it keeps
// saves is the point of the sentence, because that is what someone reading a
// storage warning is actually afraid of.
const usedOf = (usage, quota) =>
  `${formatBytes(usage)} / ${formatBytes(quota)} used`;

const STORAGE_TIERS = [
  { at: 0.95, bad: true, text: () =>
      "Storage nearly full. Old ROMs are removed to make room. Saves are kept." },
  { at: 0.90, bad: true, text: usedOf },
  { at: 0.80, bad: false, text: usedOf },
];

const updateStorageInfo = async () => {
  storageInfo.textContent = "";
  storageInfo.classList.remove("warn");
  if (!navigator.storage?.estimate) return;
  let est = await navigator.storage.estimate();
  if (!est?.quota) return;
  let tier = STORAGE_TIERS.find((t) => est.usage / est.quota >= t.at);
  if (!tier) return;
  storageInfo.textContent = tier.text(est.usage, est.quota);
  if (tier.bad) storageInfo.classList.add("warn");
};

// Box-art object URLs, revoked and rebuilt each render.
let homeArtUrls = [];
// Render generation: a lazy art fetch resolving after a newer render must
// not touch the fresh grid.
let homeRenderGen = 0;

// --- Per-game menu ---
// Every per-game action, on the library tile: the
// ⋯ glyph, a right-click, or a long press. One DOM, two layouts
// (styles.css): a popover by the glyph on desktop, a bottom sheet headed by
// the game's picture on phones. Items that cannot apply right now stay,
// disabled, with the reason as their sub-line - a user learns why, rather
// than hunting for a button that is not there. Items that never apply to
// this game (Download on a game already here; Remove from device signed
// out, where there is nowhere to remove it to) are absent.
const tileMenu = document.getElementById("tile-menu");
const tileMenuScrim = document.getElementById("tile-menu-scrim");
const tileMenuHead = document.getElementById("tile-menu-head");
const tileMenuItems = document.getElementById("tile-menu-items");
const homeScroller = document.getElementById("home");
let tileMenuFor = null;     // the game, while open
let tileMenuAnchor = null;  // focus returns here on close
let tileMenuPicUrl = null;
const TILE_MENU_ARM_MS = 3500;
// The items, as the buttons they are.
const tileMenuButtons = () =>
  /** @type {HTMLButtonElement[]} */ ([...tileMenuItems.children]);
const LONG_PRESS_MS = 450;
const LONG_PRESS_SLOP = 10; // px of travel that makes it a scroll, not a press

// The phone breakpoint of styles.css.
const tileMenuIsSheet = () => matchMedia("(max-width: 759px)").matches;

const closeTileMenu = () => {
  if (tileMenu.hidden) return;
  tileMenu.hidden = true;
  tileMenuScrim.hidden = true;
  tileMenuHead.hidden = false;
  tileMenuHead.replaceChildren();
  tileMenuItems.replaceChildren();
  if (tileMenuPicUrl) { URL.revokeObjectURL(tileMenuPicUrl); tileMenuPicUrl = null; }
  for (let t of homeRecent.children) t.classList.remove("menu-open");
  homeScroller.removeEventListener("scroll", closeTileMenu);
  window.removeEventListener("resize", closeTileMenu);
  let back = tileMenuAnchor;
  tileMenuFor = null;
  tileMenuAnchor = null;
  if (back && back.isConnected) back.focus({ preventScroll: true });
};

// The glyphs the hamburger uses for these same commands, so a command looks
// like itself wherever it is offered. Path data rather than a clone of the
// menu button: those carry live state (Link Cable's label flips to Disconnect,
// Printed Photos wears a seen-dot) that has no business in here.
const MENU_ICONS = {
  states: '<path d="M4 5h6v6H4zM14 5h6v6h-6zM4 15h6v4H4zM14 15h6v4h-6z"/>',
  saves: '<path d="M4 7h5l2 2h9v10H4zM4 7V5h7l2 2"/>',
  link: '<path d="M7 8V6a2 2 0 0 1 2-2h1v6H9a2 2 0 0 1-2-2zM17 16v2a2 2 0 0 1-2 2h-1v-6h1a2 2 0 0 1 2 2zM10 8h4M10 16h4M12 8v8"/>',
  cheats: '<path d="M12 3l2.2 4.6 5 .7-3.6 3.5.9 5L12 14.9 7.5 16.8l.9-5L4.8 8.3l5-.7z"/>',
  bug: '<path d="M8 8a4 4 0 0 1 8 0v2a4 4 0 0 1-8 0zM12 12v7M6 10H3M6 14H3M18 10h3M18 14h3M8 7 6 5M16 7l2-2"/>',
  prints: '<path d="M6 9V4h12v5M6 15h12v5H6zM6 9h12a2 2 0 0 1 2 2v4H4v-4a2 2 0 0 1 2-2z"/>',
};

// A menu item: a label over a sub-line. `disabled` is the reason, shown in
// the sub-line's place. Destructive items arm on the first tap and run on
// the second (the pattern of every destructive button here), disarming
// after a moment or when a sibling arms.
const tileMenuItem = ({ label, sub = "", icon = "", danger = false, disabled = "", confirmLabel = "", run }) => {
  let b = document.createElement("button");
  b.type = "button";
  b.className = "tile-menu-item" + (danger ? " danger" : "");
  b.setAttribute("role", "menuitem");
  // Only the session items carry one. The file items (Rename, Delete and the
  // rest) have never had a glyph anywhere, and inventing one for Delete in
  // particular would be inventing a meaning.
  if (icon) {
    b.classList.add("has-icon");
    let g = document.createElement("span");
    g.className = "tile-menu-icon";
    g.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">' + icon + "</svg>";
    b.appendChild(g);
  }
  let l = document.createElement("span");
  l.className = "tile-menu-label";
  l.textContent = label;
  let s = document.createElement("span");
  s.className = "tile-menu-sub";
  s.textContent = disabled || sub;
  s.hidden = !s.textContent;
  b.append(l, s);
  if (disabled) {
    b.disabled = true;
    return b;
  }
  let armed = false;
  let armTimer = null;
  const disarm = () => {
    armed = false;
    clearTimeout(armTimer);
    b.classList.remove("armed");
    l.textContent = label;
    s.textContent = sub;
    s.hidden = !sub;
  };
  b.disarm = disarm;
  b.addEventListener("click", async (e) => {
    e.stopPropagation();
    if (confirmLabel && !armed) {
      armed = true;
      b.classList.add("armed");
      l.textContent = confirmLabel;
      s.textContent = "Tap again to confirm";
      s.hidden = false;
      armTimer = setTimeout(disarm, TILE_MENU_ARM_MS);
      for (let o of tileMenuButtons()) if (o !== b && o.disarm) o.disarm();
      return;
    }
    clearTimeout(armTimer);
    closeTileMenu();
    await run();
  });
  return b;
};

// The items for one game, from its flags (gameFlags). Order: get it, name
// it, wipe its saves, free the space, and last - set apart - delete it.
// Every item says what it does in its own label: nothing carries a
// description. Only a blocked item speaks, and only to say why, since a
// greyed row that will not explain itself is worse than one that will.
// Delete needs no reach line any more - enrolled, it always means every
// device, because a delete made away from Drive is recorded and flushes
// when the account comes back.
// The loaded game's own controls, offered only from the paused card's ⋯.
// They sit above the file items because they are about the session in front
// of you rather than the bytes on disk, and they are the reason those same
// commands can leave the hamburger while the card is up (body.home-card).
//
// Link Cable goes through the menu button rather than duplicating netplay.js:
// that button owns a two-step disarm for the disconnect case, and this menu
// can never be the disconnect case - the card is drawn only for a single
// core, so a link session means no card and no ⋯.
// The card's ⋯. The card is the SESSION - the game you are in the middle of -
// so this is everything you might do to it while it is paused, and none of
// the things you might do to its file. Those live on the game's tile in the
// grid an inch below (Rename, Reset save data, Remove, Delete), which is
// where they have always lived and where they belong: the tile is the file.
// Keeping the split means neither menu is a pile, and the card's never has to
// say which game it is - the card said so, at size, directly above it.
//
// Link Cable, Clip that! and Printed Photos go through their own menu
// buttons rather than being reimplemented: each owns state this menu should
// not learn (a two-step disarm, a range picker's defaults, a seen-dot).
const sessionMenuEntries = () => {
  // No Screenshot and no Clip that!: both are about the frame in front of
  // you, and the frame in front of you here is the card's own picture of a
  // game that stopped. They stay in the menu over a running game.
  let items = [
    tileMenuItem({ label: "Save states", icon: MENU_ICONS.states,
                   run: () => openStatesModal() }),
    tileMenuItem({ label: "Manage saves", icon: MENU_ICONS.saves,
                   run: () => openSavesModal() }),
  ];
  if (printerPhotos.length) {
    items.push(tileMenuItem({ label: "Printed photos", icon: MENU_ICONS.prints,
                              run: () => printsItem.click() }));
  }
  items.push(
    tileMenuItem({
      label: "Link cable",
      icon: MENU_ICONS.link,
      run: () => document.getElementById("net-connect").click(),
    }),
    tileMenuItem({ label: "Cheats", icon: MENU_ICONS.cheats,
                   run: () => openCheatsModal() }),
    tileMenuItem({ label: "Report a bug", icon: MENU_ICONS.bug,
                   run: () => openReportModal() }),
  );
  return items;
};

const tileMenuEntries = (name, f) => {
  let items = [];
  let busy = f.busy ? "Exit the online session first" : "";
  if (f.missing) {
    items.push(tileMenuItem({
      label: "Find the file…",
      run: () => relinkGameAction(name),
    }));
  } else if (f.driveOnly) {
    items.push(tileMenuItem({
      label: "Download to this device",
      disabled: f.downloading ? "Downloading…" : "",
      run: () => downloadGameAction(name),
    }));
  }
  // Earlier moments of play (checkpoints), kept on this device: the way back
  // when where the game stopped is what keeps stopping it.
  if (f.moments && !f.driveOnly && !f.missing) {
    items.push(tileMenuItem({
      label: "Resume from earlier",
      disabled: busy,
      run: () => openMomentsModal(name),
    }));
  }
  items.push(tileMenuItem({
    label: "Rename",
    disabled: busy,
    run: () => openRenameModal(name),
  }));
  // Just above the ways to lose a save: the way to keep one. It only reads,
  // so an online session does not hold it up. A game kept only on Drive
  // comes down first, as Download does, and is exported from here.
  if (f.driveOnly && !f.missing) {
    items.push(tileMenuItem({
      label: "Download and export…",
      disabled: f.downloading ? "Downloading…" : "",
      run: async () => { if (await downloadGameAction(name)) await openExportModal(name); },
    }));
  } else {
    items.push(tileMenuItem({
      label: "Export…",
      run: () => openExportModal(name),
    }));
  }
  items.push(tileMenuItem({
    label: "Reset save data",
    disabled: busy || (f.hasSaves ? "" : "No save data yet"),
    confirmLabel: "Delete all save data?",
    run: () => resetGameAction(name),
  }));
  // A save from before the game was deleted and loaded again (see genOf),
  // or the one a Restore put aside: the only item that says what it is,
  // because nothing else on screen can.
  if (f.kept) {
    items.push(tileMenuItem({
      label: "Restore old save",
      sub: (f.kept.why === "replaced" ? "The save you replaced" : "From before you deleted it") +
           (f.kept.at ? " · saved " + fmtStateTime(f.kept.at) : ""),
      disabled: busy,
      confirmLabel: "Replace the current save?",
      run: () => restoreKeptSave(name),
    }));
  }
  if (!f.driveOnly && f.linked) {
    items.push(tileMenuItem({
      label: "Remove from this device",
      // A paused game is closed on the way, the way Delete already does it.
      disabled: busy ||
        (f.romOnDrive ? "" : "Not backed up to Drive yet — this is your only copy"),
      confirmLabel: f.loaded ? "Close and remove?" : "Remove from this device?",
      run: () => removeFromDeviceAction(name),
    }));
  }
  items.push(tileMenuItem({
    label: "Delete",
    danger: true,
    disabled: busy,
    confirmLabel: f.loaded ? "Close and delete everything?"
                : f.missing ? "Delete this game and its save?"
                            : "Delete ROM and save data?",
    run: () => deleteGameAction(name),
  }));
  return items;
};

// The system and, once known, how big the game is - which is the figure
// every choice in this menu turns on and the one the rest of the screen
// never gives. Where the game lives is left to the items, which already say
// it: a Download means it is not here, a Remove means it is. The one thing
// nothing else can say is that a freed game left its save behind.
const tileMenuStatus = (name, f) => {
  let bits = [systemOf(name)];
  let size = romSizeOf(name);
  if (size) bits.push(formatBytes(size));
  if (f.missing) {
    bits.push(f.hasLocalSaves ? "the file is not here, but your save is"
                              : "the file is not on this device");
  } else if (f.driveOnly && f.hasLocalSaves) {
    bits.push("your save is still on this device");
  }
  return bits.join(" · ");
};

// The head: the game's picture (phones), its name and where it lives.
const buildTileMenuHead = (name, f) => {
  let system = systemOf(name);
  let pic = document.createElement("span");
  pic.className = "tile-menu-pic";
  let chip = document.createElement("span");
  chip.className = "sys-chip badge-" + system.toLowerCase();
  chip.textContent = system;
  pic.appendChild(chip);
  getRomFrame(name)
    .then((frame) => frame || getRomArt(name))
    .then((blob) => {
      if (!blob || tileMenuFor !== name) return;
      if (tileMenuPicUrl) URL.revokeObjectURL(tileMenuPicUrl);
      tileMenuPicUrl = URL.createObjectURL(blob);
      let img = document.createElement("img");
      img.src = tileMenuPicUrl;
      img.alt = "";
      pic.replaceChildren(img);
    })
    .catch(() => {});
  let text = document.createElement("span");
  text.className = "tile-menu-text";
  let title = document.createElement("span");
  title.className = "tile-menu-title";
  title.id = "tile-menu-title";
  title.textContent = displayName(name);
  title.title = name;
  let status = document.createElement("span");
  status.className = "tile-menu-status";
  status.textContent = tileMenuStatus(name, f);
  // Never noted and the bytes are here: read them once, behind the open
  // menu, and fill the line in. A ROM record is up to 32 MB, so this never
  // blocks the menu and never happens twice for the same game.
  if (!romSizeOf(name) && !f.driveOnly) {
    getRomBytes(name)
      .then((bytes) => bytes && noteRomSize(name, bytes.length))
      .then(() => {
        if (tileMenuFor === name) status.textContent = tileMenuStatus(name, f);
      })
      .catch(() => {});
  }
  text.append(title, status);
  tileMenuHead.replaceChildren(pic, text);
};

// Desktop: by the glyph, below and right-aligned to it, flipping above when
// the bottom is short; a right-click opens at the pointer. Phones: the
// sheet, positioned by styles.css alone.
const placeTileMenu = (anchor, at) => {
  if (tileMenuIsSheet()) {
    tileMenu.style.left = "";
    tileMenu.style.top = "";
    return;
  }
  let m = tileMenu.getBoundingClientRect();
  let vw = window.innerWidth, vh = window.innerHeight, pad = 8;
  let left, top;
  if (at) {
    left = at.x;
    top = at.y;
  } else {
    let r = anchor.getBoundingClientRect();
    left = r.right - m.width;
    top = r.bottom + 6;
    if (top + m.height > vh - pad) top = r.top - m.height - 6;
  }
  if (left + m.width > vw - pad) left = vw - pad - m.width;
  if (top + m.height > vh - pad) top = vh - pad - m.height;
  tileMenu.style.left = Math.max(pad, left) + "px";
  tileMenu.style.top = Math.max(pad, top) + "px";
};

// `at` = {x, y} for a right-click; else the menu hangs off `anchor`.
const openTileMenu = async (name, anchor, tile, at = null, session = false) => {
  closeTileMenu();
  let [localRoms, withSaves, kept, moments] = await Promise.all(
    [localRomSet(), romsWithSaveData(), getKeptSave(name), hasEarlierMoments(name)]);
  let f = { ...gameFlags(name, localRoms, new Set(withSaves)), kept, moments };
  tileMenuFor = name;
  tileMenuAnchor = anchor;
  // A tile is a picture in a grid of them, so the menu has to say which game
  // it belongs to and where that game lives. The card has already said both,
  // at size, an inch above - so the head goes, and with it the accessible
  // name it carried.
  tileMenuHead.hidden = session;
  if (session) {
    tileMenu.removeAttribute("aria-labelledby");
    tileMenu.setAttribute("aria-label", displayName(name));
  } else {
    tileMenu.removeAttribute("aria-label");
    tileMenu.setAttribute("aria-labelledby", "tile-menu-title");
    buildTileMenuHead(name, f);
  }
  tileMenuItems.replaceChildren(
    ...(session ? sessionMenuEntries() : tileMenuEntries(name, f)));
  if (tile) tile.classList.add("menu-open");
  tileMenuScrim.hidden = false;
  tileMenu.hidden = false;
  placeTileMenu(anchor, at);
  homeScroller.addEventListener("scroll", closeTileMenu, { passive: true });
  window.addEventListener("resize", closeTileMenu);
  let first = tileMenuButtons().find((b) => !b.disabled);
  if (first) first.focus({ preventScroll: true });
};

tileMenuScrim.addEventListener("click", closeTileMenu);
// A right-click elsewhere while open: no browser menu over ours.
tileMenuScrim.addEventListener("contextmenu", (e) => { e.preventDefault(); closeTileMenu(); });
tileMenu.addEventListener("keydown", (e) => {
  if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
  let items = tileMenuButtons().filter((b) => !b.disabled);
  if (!items.length) return;
  let i = items.indexOf(/** @type {HTMLButtonElement} */ (document.activeElement));
  let n = e.key === "ArrowDown" ? (i + 1) % items.length
                                : (i - 1 + items.length) % items.length;
  items[n].focus();
  e.preventDefault();
});

// The ⋯ glyph and the two shortcuts, wired onto one tile.
const wireTileMenu = (tile, launch, romName) => {
  let more = document.createElement("button");
  more.type = "button";
  more.className = "home-tile-more";
  more.title = "More";
  more.setAttribute("aria-label", "More for " + displayName(romName));
  more.setAttribute("aria-haspopup", "menu");
  more.innerHTML = '<svg viewBox="0 0 24 24"><circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/></svg>';
  more.addEventListener("click", (e) => {
    e.stopPropagation();
    if (tileMenuFor === romName) closeTileMenu();
    else openTileMenu(romName, more, tile);
  });
  tile.appendChild(more);

  // Right-click (and Android's long press, which arrives as contextmenu).
  tile.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    cancelPress();
    if (tileMenuFor === romName) return;
    openTileMenu(romName, more, tile, tileMenuIsSheet() ? null : { x: e.clientX, y: e.clientY });
  });

  // A long press on touch (iOS fires no contextmenu). The press that opens
  // the menu must not also launch the game when the finger lifts.
  let pressTimer = null;
  let pressX = 0, pressY = 0;
  let pressed = false;
  const cancelPress = () => { clearTimeout(pressTimer); pressTimer = null; };
  launch.addEventListener("pointerdown", (e) => {
    if (e.pointerType === "mouse") return;
    pressed = false;
    pressX = e.clientX;
    pressY = e.clientY;
    cancelPress();
    pressTimer = setTimeout(() => {
      pressTimer = null;
      pressed = true;
      openTileMenu(romName, more, tile);
    }, LONG_PRESS_MS);
  });
  launch.addEventListener("pointermove", (e) => {
    if (pressTimer && Math.hypot(e.clientX - pressX, e.clientY - pressY) > LONG_PRESS_SLOP) cancelPress();
  });
  launch.addEventListener("pointerup", cancelPress);
  launch.addEventListener("pointercancel", cancelPress);
  launch.addEventListener("pointerleave", cancelPress);
  // True once, for the click that ends the press that opened the menu.
  return () => { let p = pressed; pressed = false; return p; };
};

// A library game chosen from the home screen, from its tile or from the hero.
// The hero says Resume or Play before the tap and passes `resume`; a tile
// does what the "Opening a game from the library" setting says - go back
// into the session where one still matches the save (the default), or boot
// from the in-game save and offer the session after ("Last session saved").
// The loaded game carries on instead: a reboot would drop what happened
// since the snapshot.
const openLibraryGame = async (romName, { driveOnly = false, missing = false, flyFrom = null, resume = libraryOpen === "resume" } = {}) => {
  if (currentOriginalName === romName && !linkMode) { resumeGame(); return; }
  if (!driveOnly && crashGate(romName)) return;
  if (!driveOnly) { launchRom(romName, { resume, flyFrom }); return; }
  if (missing) { relinkGameAction(romName, { launch: true }); return; }
  await fetchTileGame(romName, { open: { resume, flyFrom } });
};

// --- A Drive-only game coming down, on its tile --------------------------
// The tile says what is happening over its picture: "Signing in…", then
// "Opening" (tapped to play) or "Downloading" (↓ or the menu) with the bytes
// and a bar, "Starting…" as the player takes over, a check for a moment
// after a plain download, and "Couldn't download" until the next tap if it
// fails. name -> { open, gen, stage, got, total, run }; stage is one of
// signin, download, start, done, failed.
const tileLoads = new Map();
const TILE_DONE_MS = 2000;
const tileLoadBusy = (s) => !!s && (s.stage === "signin" || s.stage === "download" ||
                                     s.stage === "start");
// "Opening" only while the tap's load token is the latest: a later tap on
// anything else wins (loadGen), and this one is back to a plain download.
const tileLoadOpening = (s) => tileLoadBusy(s) && !!s.open && s.gen === loadGen;

const tileBytes = (got, total) => {
  if (!total) return got ? formatBytes(got) : "";
  let [div, unit, dp] = total >= 1024 * 1024 ? [1024 * 1024, " MB", 1] : [1024, " KB", 0];
  return (Math.min(got, total) / div).toFixed(dp) + " of " + (total / div).toFixed(dp) + unit;
};

const gameTileEls = () => /** @type {HTMLElement[]} */ ([...homeRecent.children])
  .filter((t) => t.classList.contains("home-tile"));
const tileOf = (name) => gameTileEls().find((t) => t.dataset.rom === name);
const childOf = (el, cls) => el && [...el.children].find((c) => c.classList.contains(cls));

const DL_ICON = '<svg viewBox="0 0 24 24"><path d="M12 3v12M8 11l4 4 4-4M5 19h14"/></svg>';
const SPIN_ICON = '<svg class="sync-spin" viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v3.5h-3.5"/></svg>';

// Brings one tile in line with its entry, or its absence. Every render calls
// it, so the state outlives the grid being rebuilt under it.
const paintTileLoad = (tile) => {
  if (!tile) return;
  let name = tile.dataset.rom;
  let s = tileLoads.get(name);
  let launch = childOf(tile, "home-tile-launch");
  let busy = tileLoadBusy(s);
  let opening = tileLoadOpening(s);
  let failed = s?.stage === "failed";
  tile.classList.toggle("is-loading", busy);
  tile.classList.toggle("is-opening", opening);
  tile.classList.toggle("is-failed", failed);

  let over = childOf(launch, "home-tile-load");
  if (!busy && !failed) { if (over) launch.removeChild(over); }
  else if (launch) {
    if (!over) {
      over = document.createElement("span");
      over.className = "home-tile-load";
      let label = document.createElement("span");
      label.className = "home-tile-load-label";
      let sub = document.createElement("span");
      sub.className = "home-tile-load-sub";
      sub.setAttribute("aria-hidden", "true"); // the bytes would churn the name
      let bar = document.createElement("span");
      bar.className = "home-tile-load-bar";
      bar.appendChild(document.createElement("span"));
      over.append(label, sub, bar);
      launch.appendChild(over);
    }
    let [label, sub, bar] = over.children;
    label.textContent = s.stage === "signin" ? "Signing in…"
      : failed ? "Couldn’t download"
      : s.stage === "start" ? "Starting…"
      : opening ? "Opening" : "Downloading";
    sub.textContent = s.stage === "signin" ? "Google Drive"
      : failed ? "Tap to try again"
      : tileBytes(s.got, s.total);
    let pct = s.stage === "start" ? 100 : s.total ? Math.min(100, 100 * s.got / s.total) : 0;
    bar.hidden = s.stage === "signin" || (!s.total && s.stage !== "start");
    bar.children[0].style.width = pct + "%";
  }

  // The corner ↓ spins, on its chip, for as long as anything is fetching
  // this game; a failed one offers ↓ again.
  if (tile.classList.contains("home-tile-cloud")) {
    let dl = childOf(tile, "home-tile-dl");
    let spin = busy || syncDownloading.has(name);
    if (dl && dl.classList.contains("is-busy") !== spin) {
      dl.classList.toggle("is-busy", spin);
      dl.disabled = spin;
      dl.innerHTML = spin ? SPIN_ICON : DL_ICON;
    }
  }

  let check = childOf(tile, "home-tile-done");
  if (s?.stage === "done" && !check) {
    check = document.createElement("span");
    check.className = "home-tile-done";
    check.setAttribute("role", "img");
    check.setAttribute("aria-label", "On this device");
    check.innerHTML = '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7"/></svg>';
    tile.appendChild(check);
  } else if (s?.stage !== "done" && check) tile.removeChild(check);
};

// The hero's game has its tile stood down (syncHomeCurrent), so the hero's
// own button carries the state instead, in a word and a percentage.
const paintHeroLoad = (name) => {
  if (name !== heroName || heroCard.dataset.mode !== "closed") return;
  let s = tileLoads.get(name);
  let pct = s?.total ? " · " + Math.floor(100 * Math.min(s.got, s.total) / s.total) + "%" : "";
  heroResumeLabel.textContent = !s || s.stage === "done" ? (heroSession ? "Resume" : "Play")
    : s.stage === "signin" ? "Signing in…"
    : s.stage === "start" ? "Starting…"
    : s.stage === "failed" ? "Try again"
    : (tileLoadOpening(s) ? "Opening" : "Downloading") + pct;
};

const paintLoadOf = (name) => {
  paintTileLoad(tileOf(name));
  paintHeroLoad(name);
};

const setTileLoad = (name, s) => {
  if (s) tileLoads.set(name, s); else tileLoads.delete(name);
  paintLoadOf(name);
};

// Fetches a Drive-only game with its tile showing it. `open` ({ resume,
// flyFrom }) plays it after, unless a later tap has taken the load token by
// then. A call while one runs joins it rather than starting another, so a
// tap on the picture during a ↓ download turns it into an open. Resolves
// true once the game is on this device.
const fetchTileGame = async (name, { open = null } = {}) => {
  // The tap takes the load token now, not when the download (seconds) is
  // done: a tile tapped meanwhile is the later tap, and wins. The download
  // itself finishes either way.
  let gen = open ? nextLoadGen() : 0;
  // Every tile, and the hero: an Opening elsewhere gives way to this tap.
  const paintAll = () => {
    gameTileEls().forEach(paintTileLoad);
    if (heroName) paintHeroLoad(heroName);
  };
  let s = tileLoads.get(name);
  if (tileLoadBusy(s)) {
    if (open) {
      Object.assign(s, { open, gen });
      paintAll();
    }
    return !!(await s.run);
  }
  s = { open, gen, stage: syncActive() ? "download" : "signin", got: 0, total: 0, run: null };
  tileLoads.set(name, s);
  paintAll();
  s.run = (async () => {
    if (!(await ensureDriveSignedIn())) return null; // declined: never tried
    s.stage = "download";
    paintLoadOf(name);
    return downloadGame(name, { onProgress: (got, total) => {
      s.got = got;
      s.total = total;
      paintLoadOf(name);
    } });
  })();
  let ok = await s.run;
  if (tileLoads.get(name) !== s) return !!ok;
  if (ok === null) { setTileLoad(name, null); return false; }
  if (!ok) { s.stage = "failed"; paintLoadOf(name); return false; }
  if (tileLoadOpening(s)) {
    s.stage = "start";
    paintLoadOf(name);
    // The tile the tap came from has been rebuilt since: fly from the one
    // standing in its place.
    let from = s.open.flyFrom;
    if (from && !from.isConnected) {
      from = childOf(childOf(tileOf(name), "home-tile-launch"), "home-tile-thumb") || null;
    }
    try {
      await launchRom(name, { resume: s.open.resume, flyFrom: from });
    } finally {
      // Booted or not, the game is here now: an ordinary tile.
      if (tileLoads.get(name) === s) setTileLoad(name, null);
    }
  } else {
    s.stage = "done";
    paintLoadOf(name);
    setTimeout(() => { if (tileLoads.get(name) === s) setTileLoad(name, null); }, TILE_DONE_MS);
  }
  return true;
};

const libFilterActive = () =>
  !!libFilter.q || libFilter.systems.size > 0 || libFilter.loc !== "all";

// Search, chips and sort are for finding a game in a library too big to
// take in at a glance. Under two rows of a wide screen they are furniture.
// A running filter keeps them, so a delete that crosses the line cannot
// strand the grid filtered with no way to clear it.
const LIB_BAR_MIN = 9;


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
    // Nothing to head, filter or count: the whole section leaves, and the
    // hero above it becomes the empty state.
    libraryEmpty = true;
    refreshHomeEmptyActions();
    homeRecentWrap.hidden = true;
    if (libNone) libNone.hidden = true;
    storageInfo.textContent = "";
    homeThumbsBtn.hidden = true;
    closeTileMenu();
    homeRecent.replaceChildren();
    libNames = [];
    if (!currentRomName) setHeroShown(false);
    syncHomeCurrent();
    homeArtUrls.forEach(URL.revokeObjectURL);
    homeArtUrls = artUrls;
    syncBrand(); // the big brand is back, and the bar's copy gives way
    revealHome();
    return;
  }
  libraryEmpty = false;
  refreshHomeEmptyActions();
  libNames = roms.map((r) => r.name);
  syncHomeCurrent(); // the fit and home-solo
  if (homeRecentHead) homeRecentHead.hidden = false;
  homeRecentWrap.hidden = false;
  if (libBar) libBar.hidden = roms.length < LIB_BAR_MIN && !libFilterActive();
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
  const heroReady = refreshHero(roms, localRoms, keys);
  renderLibChips(roms, localRoms);
  // Sizes ride along with the render that needs them, and lose the games
  // that have left the library.
  await loadRomSizes();
  if (gen !== homeRenderGen) return;
  let live = new Set(roms.map((r) => r.name));
  let stale = Object.keys(romSizes).filter((n) => !live.has(n));
  if (stale.length) {
    for (let n of stale) delete romSizes[n];
    dbPut(ROM_SIZES_KEY, romSizes);
  }
  roms = sortRoms(roms);
  let tiles = [];
  let pictures = []; // each tile's picture, decoded (The first picture)
  for (let { name: romName } of roms) {
    let system = systemOf(romName);
    let driveOnly = !localRoms.has(romName);
    // Byte-less with nothing to fetch: the file has to be found again.
    let missing = driveOnly && !driveHasRom(romName);
    let tile = document.createElement("div");
    // no-art until a picture arrives: the chip stands in for it.
    tile.className = "home-tile no-art" +
      (missing ? " home-tile-missing" : driveOnly ? " home-tile-cloud" : "");
    // What the filter reads: the name folded the way the search folds it.
    tile.dataset.name = libFold(displayName(romName));
    tile.dataset.rom = romName; // what syncHomeCurrent matches the card by
    tile.dataset.system = system;
    // "missing" is on neither side of the location chips, so neither claims
    // it and either filter hides it (libTileMatches).
    tile.dataset.loc = missing ? "missing" : driveOnly ? "drive" : "device";

    let launch = document.createElement("button");
    launch.type = "button";
    launch.className = "home-tile-launch";
    launch.title = missing
      ? romName + " — the file is not on this device, tap to find it"
      : driveOnly
        ? romName + (driveLinked() ? " — on Drive, tap to download"
                                   : " — on Drive, tap to sign in and download")
        : romName;

    // The 3:2 picture (the GBA screen's shape). Precedence: the last screen
    // the game showed, else the box art, else the system chip standing in -
    // a game never opened has no frame and must not get an invented one.
    // Both Blobs live in their own records, so no ROM bytes are
    // deserialized here.
    let thumb = document.createElement("div");
    thumb.className = "home-tile-thumb";
    thumb.appendChild(buildCart(romName));
    const showPicture = (blob, cls) => {
      if (!blob || gen !== homeRenderGen) return null;
      let url = URL.createObjectURL(blob);
      artUrls.push(url);
      let img = document.createElement("img");
      img.className = cls;
      img.src = url;
      img.alt = "";
      thumb.replaceChildren(img);
      tile.classList.remove("no-art");
      return img;
    };
    pictures.push(getRomFrame(romName)
      .then((frame) => showPicture(frame, "home-tile-frame") ||
                       getRomArt(romName).then((art) => showPicture(art, "home-tile-art")))
      .then((img) => img?.decode?.())
      .catch(() => {}));

    // The footer under the picture: name and system chip.
    let caption = document.createElement("span");
    caption.className = "home-tile-caption";
    let name = document.createElement("span");
    name.className = "home-tile-name";
    name.textContent = displayName(romName); // full name stays in launch.title
    let chip = document.createElement("span");
    chip.className = "sys-chip badge-" + system.toLowerCase();
    chip.textContent = system;
    caption.append(name, chip);

    launch.appendChild(thumb);
    launch.appendChild(caption);
    tile.appendChild(launch);
    let consumedByPress = wireTileMenu(tile, launch, romName);
    if (romName === tileMenuFor) tile.classList.add("menu-open");
    // The tile body downloads and launches; the glyph downloads only.
    launch.addEventListener("click", () => {
      if (consumedByPress()) return; // the long press opened the menu
      openLibraryGame(romName, { driveOnly, missing, flyFrom: thumb });
    });

    if (missing) {
      // The corner Download sits in, doing the same job from the other
      // place a file can come from: fetch it, without launching.
      let find = document.createElement("button");
      find.type = "button";
      find.className = "home-tile-dl";
      find.title = romName + " — find the file without launching";
      find.setAttribute("aria-label", "Find the file for " + displayName(romName));
      find.innerHTML = '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6"/>' +
                       '<path d="M20 20l-4.5-4.5"/></svg>';
      find.addEventListener("click", (e) => {
        e.stopPropagation();
        relinkGameAction(romName);
      });
      tile.appendChild(find);
    } else if (driveOnly) {
      let dl = document.createElement("button");
      dl.type = "button";
      dl.className = "home-tile-dl";
      dl.title = romName + " — download without launching";
      dl.setAttribute("aria-label", "Download " + displayName(romName));
      dl.innerHTML = DL_ICON; // paintTileLoad spins it while one runs
      dl.addEventListener("click", (e) => {
        e.stopPropagation();
        fetchTileGame(romName); // download only — no launch
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
    paintTileLoad(tile);
    tiles.push(tile);
  }
  // The pictures offer is worth showing only while something lacks one.
  // Drive-only games count when signed in, since the run can fetch them.
  thumbsCandidates(driveLinked(), keys)
    .then((cands) => { if (gen === homeRenderGen) homeThumbsBtn.hidden = !cands.length; })
    .catch(() => {});
  // Filtered before the commit: a fresh render is already filtered.
  for (let t of tiles) t.hidden = !libTileMatches(t);
  // The one DOM commit, atomic: no zero-height moment.
  homeRecent.replaceChildren(...tiles);
  syncHomeCurrent(); // mark the new tiles
  // A menu open on a game that just left the library (deleted elsewhere).
  if (tileMenuFor && !roms.some((r) => r.name === tileMenuFor)) closeTileMenu();
  applyLibFilter(); // the count and the empty note
  homeArtUrls.forEach(URL.revokeObjectURL);
  homeArtUrls = artUrls;
  // The page just changed height: the crossover point moved with it.
  syncBrand();
  // The first render shows once its top game and pictures are in, or after
  // HOME_PICTURES_MAX_MS if a picture is slow.
  if (homePending) {
    Promise.race([
      Promise.allSettled([heroReady, ...pictures]),
      new Promise((r) => setTimeout(r, HOME_PICTURES_MAX_MS)),
    ]).then(revealHome);
  }
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
    closeUpdateModal();
    closeStatesModal();
    closeMomentsModal();
    closeCheatsModal();
    closeReportModal();
    closeRewindScrubber();
    closeClipScrubber();
    closeRomWarnModal();
    closeThumbsModal();
    closeTileMenu();
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

// Each persist of a game's save takes the next number: a put waiting on a
// quota eviction gives way to a later persist of the same save that went in
// meanwhile, instead of putting its older bytes back over it. A delete of the
// save (Reset, Delete) takes one too, so the waiting put gives way to that.
const persistSeq = new Map();
const retireSavePuts = (name) => persistSeq.set(name, (persistSeq.get(name) || 0) + 1);

// The solo core's battery RAM into its file now, if it changed. A paused core
// runs no frames to flush it, and a state loaded while paused leaves the RAM
// it carried only in the core: whatever reads the file for the loaded game
// (persistSave, persistAutoState's signature) flushes it first.
const flushSoloSave = () => {
  if (currentRomName && !linkMode && !rollbackMode &&
      typeof Module !== "undefined" && Module._wasm_flush_save) {
    Module._wasm_flush_save();
  }
};

const persistSave = async (romName, originalName) => {
  let savName = romName.substring(0, romName.lastIndexOf(".")) + ".sav";
  try {
    if (romName === currentRomName) flushSoloSave(); // the solo core's file
    let data = FS.readFile(savName);
    if (data && data.length > 0) {
      const sig = saveSignature(data);
      if (lastSaveSigKey === originalName && sig === lastSaveSig) return;
      const seq = (persistSeq.get(originalName) || 0) + 1;
      persistSeq.set(originalName, seq);
      const put = await dbPutRoomy("save:" + originalName, new Uint8Array(data),
                                   originalName, () => persistSeq.get(originalName) !== seq);
      if (put === null) return; // the later persist records its own signature
      if (!put) {
        // Do not remember a signature that was never written, or the next
        // flush would take this save for already-stored and skip it.
        lastSaveSig = lastSaveSigKey = null;
        showToast("This device is out of room - your save could not be written");
        return;
      }
      lastSaveSig = sig;
      lastSaveSigKey = originalName;
      requestPersistentStorage();
      markUpload("save:" + originalName); // truly-dirty save -> Drive soon
      postSaveToHook(originalName, data);

    }
  } catch {}
};

// Put a game's stored battery save in its FS file, right before the core is
// built on it, or remove the file when the game has none: every solo game is
// "rom.<ext>", so a file left behind is the last game's battery, which the
// core would boot on and the next flush would store as this game's save. The
// signature is remembered as written, so the first flush does not write the
// save it was just read from back (and queue it for Drive, over whatever
// newer copy another device put there meanwhile).
const installSave = (romName, originalName, data) => {
  let savName = romName.substring(0, romName.lastIndexOf(".")) + ".sav";
  if (data && data.length) writeToFS(savName, data);
  else try { FS.unlink(savName); } catch {}
  lastSaveSig = data && data.length ? saveSignature(data) : null;
  lastSaveSigKey = lastSaveSig === null ? null : originalName;
};

const restoreSave = async (romName, originalName) => {
  installSave(romName, originalName, await dbGet("save:" + originalName));
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
const displayName = (name) => stripExt(name) || name;

// --- Cartridge labels ------------------------------------------------------
// A game with no picture yet gets a cartridge of its system's shape, and on
// its label a short mark to tell it from the next one: two initials and a
// sequel's number. The mark comes from a tidied title - file names carry dump
// tags and release numbers that name nothing about the game - which is used
// for the label only; the tile's own name is the library's.
//   "0412 - Metroid Fusion (U) [!].gba"          -> Metroid Fusion       -> MF
//   "Legend of Zelda, The - The Minish Cap (U)"  -> The Legend of ...    -> LZ
//   "GoodboyGalaxy.gba" -> GG   "advance_wars_2.gba" -> AW2
//   "Final Fantasy VI Advance (J)" -> FF6   "TETRIS.gb" -> Te
const cartTitle = (name) => {
  let s = stripExt(name) || name;
  s = s.replace(/\s*[([][^)\]]*[)\]]/g, "");            // (U) [!] (Rev 1) (En,Fr)
  s = s.replace(/^\s*\d{3,5}\s*-\s*/, "");                // "0412 - "
  s = s.replace(/^([^,]+),\s*(The|A|An)\b/i, "$2 $1");     // "Zelda, The"
  return s.replace(/_/g, " ").replace(/\s+/g, " ").trim() || name;
};
const CART_SMALL_WORDS = new Set(["the", "a", "an", "of", "and", "version", "edition"]);
// No V or X: "Mega Man X" is not the tenth.
const CART_ROMAN = { ii: 2, iii: 3, iv: 4, vi: 6, vii: 7, viii: 8, ix: 9 };
const cartLabelFor = (name) => {
  const bare = cartTitle(name).replace(/['\u2019]/g, "");
  // One run with no spaces is split where its capitals and digits start.
  const src = /[\s_]/.test(bare) ? bare
    : bare.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/([A-Za-z])(\d)/g, "$1 $2");
  let words = src.split(/[\s\-\u2013:.,&!_]+/).filter(Boolean);
  let num = "";
  for (let i = 1; i < words.length; i++) {
    const w = words[i].toLowerCase();
    if (/^\d{1,3}$/.test(w) || CART_ROMAN[w]) {
      num = /^\d/.test(w) ? w : String(CART_ROMAN[w]);
      words.splice(i, 1);
      break;
    }
  }
  let sig = words.filter((w) => !CART_SMALL_WORDS.has(w.toLowerCase()));
  if (!sig.length) sig = words;
  if (!sig.length) return "";
  if (sig.length === 1) {
    const c = Array.from(sig[0]);
    return (c[0] || "").toUpperCase() + (c[1] || "").toLowerCase() + num;
  }
  return sig.slice(0, 2).map((w) => Array.from(w)[0].toUpperCase()).join("") + num;
};

// The cartridge itself: its system's shape, the mark on its label.
const buildCart = (name, el = document.createElement("span")) => {
  const system = systemOf(name);
  el.className = "lib-cart cart-" + system.toLowerCase();
  const label = document.createElement("span");
  label.className = "lib-cart-label";
  label.textContent = cartLabelFor(name);
  el.replaceChildren(label);
  el.setAttribute("aria-hidden", "true");
  return el;
};

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
  // Detached first, as Reset: the save being replaced must not be persisted
  // on the way out (the flush would write the core's own RAM over the
  // imported file), nor snapshotted for Resume under the imported save's
  // signature (Resume would then put the replaced battery back). The reboot
  // installs the import from save:<name>.
  const game = detachLoadedGame();
  if (!game) return;
  retireSavePuts(game.originalName); // a waiting quota retry gives way (persistSeq)
  await dbPut("save:" + game.originalName, new Uint8Array(bytes));
  markUpload("save:" + game.originalName); // no flush will: its signature is the installed one
  if (unwrapped.format)
    showToast(`Imported ${unwrapped.format} save` +
      (unwrapped.title ? ` — ${unwrapped.title}` : ""));
  loadRom(game.romName, game.originalName);
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
// Live toasts, newest first: { el, msg, label, game, timer, gone } records
// (expandos on the element fail the types/ typecheck). `game`: an offer
// about the moment in the running game (Resume a session, Undo a load, a
// rewind or a reset), which the home screen has no business showing.
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

// `action` is null for a plain toast, or { label, fn, game } for a tappable one.
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
  const rec = { el: item, msg, label: action ? action.label : null, game: !!action?.game,
                timer: 0, gone: false };

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

  toastHost.prepend(item);
  toastItems.unshift(rec);
  while (toastItems.length > TOAST_MAX) dismissToast(toastItems[toastItems.length - 1]);
  armToastTimer(rec, ms);
  return rec;
};

const showToast = (msg) => pushToast(msg, 2200, null);

// Toast with a single action; lingers longer than a plain toast.
const showActionToast = (msg, label, fn, ms = 8000, { game = false } = {}) =>
  pushToast(msg, ms, { label, fn, game });

// Leaving the game for the home screen: its offers go with it.
const dismissGameToasts = () => {
  for (const rec of toastItems.slice()) if (rec.game) dismissToast(rec);
};

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

// Every state the core hands out is packed (pack_state in serialize.nim):
// the header as it was, flagged in byte 15, the rest deflated - a GBA state
// is ~550 KB plain and ~55 KB packed.
const isPackedState = (bytes) =>
  looksLikeStateFile(bytes) && bytes.length > 15 && (bytes[15] & 0x80) !== 0;

const packStateBytes = (bytes) => {
  if (typeof Module === "undefined" || !Module._wasm_pack_state) return null;
  let ptr = Module._malloc(bytes.length);
  if (!ptr) return null;
  new Uint8Array(Module.memory.buffer, ptr, bytes.length).set(bytes);
  let len = Module._wasm_pack_state(ptr, bytes.length);
  Module._free(ptr);
  if (len <= 0) return null;
  return new Uint8Array(Module.memory.buffer, Module._wasm_state_data(), len).slice();
};

// Slots saved before states were packed are packed once, at boot, and sent
// up again in their smaller form. Sessions are left: each is rewritten the
// next time its game is left, and repacking one would hand the other device
// new bytes for the same moment, which reads as news (handoffNews).
const packStoredStates = async () => {
  if (typeof Module === "undefined" || !Module._wasm_pack_state) return 0;
  let keys = [];
  try { keys = await dbKeys(); } catch { return 0; }
  let packed = 0;
  for (const key of keys) {
    if (typeof key !== "string" || !key.startsWith("state:")) continue;
    let wrote = false;
    try {
      wrote = await dbUpdate(key, (stored) => {
        const bytes = stored instanceof ArrayBuffer ? new Uint8Array(stored) : stored;
        if (!(bytes instanceof Uint8Array) || !looksLikeStateFile(bytes) ||
            isPackedState(bytes)) return undefined;
        const next = packStateBytes(bytes);
        return next && isPackedState(next) ? next : undefined;
      });
    } catch {}
    if (!wrote) continue;
    packed++;
    markUpload(key);
  }
  return packed;
};

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
    "That save state was made by a newer version of dingbat than this one. Reload the page to update dingbat, then try again.",
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

// --- A state from a newer dingbat: update, then offer the load again ---
// The core refuses only states from the future (it reads every older
// revision, serialize.nim), so the cure is the newer build. Such a refusal
// fetches it and reloads, saying so; what was being loaded is kept under
// UPDATE_RETRY_KEY and offered again, one tap, once the new build is up.
const UPDATE_RETRY_KEY = "updateretry";
// An older retry is from an update that never landed.
const UPDATE_RETRY_MAX_AGE = 10 * 60 * 1000;

const TOO_NEW_COPY = {
  offline:
    "That save state was made by a newer version of dingbat. Connect to the internet so dingbat can update, then try again.",
  unpublished:
    "That save state was made by a newer version of dingbat that isn't available here yet. Try again later.",
  arriving:
    "That save state was made by a newer version of dingbat. The update is still on its way — try again in a few minutes.",
  updating: "That save state was made by a newer version of dingbat. Updating dingbat so it can load…",
  stuck: "dingbat couldn't update, so that save state still can't load. Try again later.",
};

// A refused load's toast, or, for a state from a newer dingbat, the update.
// `retry` is what to load again after it: { kind: "session" } the game's
// session, { kind: "slot", slot }, or { kind: "bytes", bytes } for a state
// kept nowhere else (an import). Called straight after the refusal, before
// another wasm call can replace its kind.
const refuseState = (bytes, retry) => {
  if (!looksLikeStateFile(bytes) || stateRejectKind() !== SRK.TOO_NEW ||
      !currentOriginalName || linkMode || rollbackMode || netActive()) {
    showToast(stateRejectMessage(bytes));
    return;
  }
  const name = currentOriginalName;
  // Now, not after the probe: a hide meanwhile would snapshot the boot.
  if (retry.kind === "session") sessionHeldFor = name;
  updateForNewerState({ ...retry, name });
};

const updateForNewerState = async (retry) => {
  const builds = await probeBuilds();
  if (!builds) { showToast(TOO_NEW_COPY.offline); return; }
  const { current, latest, deployed } = builds;
  // The same build: the state came from one this site doesn't serve (a
  // development build), or version.txt hasn't reached this edge yet.
  if (!latest || latest === current) { showToast(TOO_NEW_COPY.unpublished); return; }
  if (deployed !== latest) { showToast(TOO_NEW_COPY.arriving); return; }
  if (appUpdating) return; // an update already under way reloads anyway
  paused = true; // the game waits out the download
  pushToast(TOO_NEW_COPY.updating, 120000, null);
  // The game as it is now goes down first (a held session: its battery
  // only), rather than trusting the reload's pagehide to finish it.
  if (currentRomName && currentOriginalName) {
    try {
      await persistSave(currentRomName, currentOriginalName);
      await persistAutoState();
    } catch {}
  }
  try {
    await dbPut(UPDATE_RETRY_KEY, { ...retry, from: current, ts: Date.now() });
  } catch {}
  applyUpdate();
};

// After the update a refused state asked for: offer the load again. A tap,
// not a launch at boot: it is also the gesture iOS wants before a game's
// audio can start.
const offerStateRetry = async () => {
  let rec = null;
  try { rec = await dbGet(UPDATE_RETRY_KEY); } catch {}
  if (!rec) return;
  try { await dbDelete(UPDATE_RETRY_KEY); } catch {}
  if (!rec.name || !(Date.now() - rec.ts < UPDATE_RETRY_MAX_AGE)) return;
  let running = "";
  try { running = (await (await fetch("version.txt")).text()).trim(); } catch {}
  if (running && running === rec.from) { showToast(TOO_NEW_COPY.stuck); return; }
  const session = rec.kind === "session";
  showActionToast(
    "dingbat updated — " + (session ? "your session" : "that save state") + " can load now",
    session ? "Resume" : "Load", () => retryStateLoad(rec), 20000);
};

const retryStateLoad = async (rec) => {
  // The session first: for a slot or an import, it is where the game was
  // when the load was asked for, so the load's Undo goes back there.
  await launchRom(rec.name, { resume: true });
  if (currentOriginalName !== rec.name) return; // failed, or another tap won
  if (rec.kind === "slot") await loadFromSlot(rec.slot);
  else if (rec.kind === "bytes" && rec.bytes) applyImportedState(rec.bytes);
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
  if (ok) sessionMoved = true;
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
  storeLastFrame({ force: true }); // a save is a moment worth a picture
  try {
    if (!(await dbPutRoomy(slotStateKey(currentOriginalName, slot), bytes,
                           currentOriginalName))) {
      showToast("This device is out of room - the state was not saved");
      return false;
    }
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
    showActionToast("State loaded", "Undo", undoStateLoad, 6000, { game: true });
  } else if (ok) {
    showToast("State loaded");
  } else {
    refuseState(bytes, { kind: "slot", slot });
  }
  return ok;
};

// --- Auto save-state (session resume) ---
// Captured when the game is left (Main Menu, a switch, a close) and when the
// page is hidden or closed - but only when the game has moved since the
// last one (sessionMoved), so a game sitting paused takes no new snapshot.
// Mirrored on Drive, so the session is the hand-off between devices: pause
// on one, and another's hero resumes at that moment.
//
// A snapshot carries the cart's battery RAM as it was, and restoring it
// marks that RAM dirty, so the next flush writes it over the save. A
// snapshot is therefore only offered while the stored save is still the one
// it was taken with: saveSig is the .sav's signature at capture, and a save
// written since (in game, or pulled from Drive) retires the snapshot. A
// session from another device is held to the same rule against the save
// that came with it.
const autoStateKey = (name) => "stateauto:" + name;
// The snapshot's own picture, { ts, blob }: the screen at the moment it
// was taken, stamped with its ts. The library's picture (frameKey) is not
// it - another device's, a later tick's, one the closing page never
// finished - so what a resume flies and lands on is this, and only while
// its ts is the snapshot's.
const sessionPicKey = (name) => "sessionpic:" + name;

const sigOfSave = (data) => (data && data.length ? saveSignature(data) : null);

// Which device took a session, for the hero to say so when it was another
// one: a random id kept in this browser, and what kind of device it is.
const DEVICE_ID_KEY = "dingbat_device";
const deviceId = (() => {
  let id = null;
  try { id = localStorage.getItem(DEVICE_ID_KEY); } catch {}
  if (!id) {
    id = Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
    try { localStorage.setItem(DEVICE_ID_KEY, id); } catch {}
  }
  return id;
})();
const deviceLabel = (() => {
  const ua = navigator.userAgent || "";
  if (/iPhone|iPod/.test(ua)) return "iPhone";
  // iPadOS asks for the desktop site and says Macintosh; it has a touch screen.
  if (/iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return "iPad";
  if (/Android/.test(ua)) return "Android";
  if (/CrOS/.test(ua)) return "Chromebook";
  if (/Macintosh|Mac OS X/.test(ua)) return "Mac";
  if (/Windows|Linux/.test(ua)) return "PC";
  return "";
})();
// Another device, as a sentence says it: "your iPhone", "your other Mac".
const deviceWords = (dev) => !dev ? "another device"
  : dev === deviceLabel ? "your other " + dev : "your " + dev;

// Whether the game in memory has moved since its last snapshot: set by every
// frame run, a state loaded and a boot; cleared by the snapshot. A session is
// what another device resumes, so a snapshot of a game that has not moved is
// not taken - it would stamp the same moment newer, and send it up over a
// session another device took since.
let sessionMoved = true;
let sessionSnapFor = null;
// The game whose session no snapshot may replace: a resume this build
// refused as too new left the core on a fresh boot, and a snapshot of that
// would put the boot screen over the newer session, here and on Drive. Held
// until another game loads (loadRom); the battery save still persists.
var sessionHeldFor = null;

// The newest snapshot taken of each game (its ts), and each game's session
// epoch, bumped when its session is deleted (deleteKeys). A checkpoint packs
// in a worker and lands later; it writes the session only while it is still
// the newest one taken and nothing has deleted the session since - a Main
// Menu, a switch or a close takes a newer one in the meantime, and a reset
// wipes it.
const sessionSnapTs = new Map();
const sessionEpochs = new Map();
const sessionEpoch = (name) => sessionEpochs.get(name) || 0;

const persistAutoState = () => {
  if (!currentRomName || !currentOriginalName) return;
  if (linkMode || rollbackMode || netActive()) return; // frame-synced modes
  const name = currentOriginalName;
  if (sessionHeldFor === name) return; // see sessionHeldFor
  // A checkpoint still packing is not yet stored: a closing page takes the
  // moment itself (and the checkpoint, now older, is dropped when it lands).
  if (!sessionMoved && sessionSnapFor === name && !ckptInFlight) {
    // Nothing new to take, but a checkpoint's session may be here unsent
    // (sendSessionNow): leaving the game sends it.
    if (sessionUnsent.has(name)) {
      sessionUnsent.delete(name);
      const key = autoStateKey(name);
      return checkpointLanded().then(() => markUpload(key));
    }
    return;
  }
  const bytes = captureStateBytes();
  if (!bytes) return;
  const ts = Date.now();
  const fb = copyFramebuffer();
  sessionMoved = false;
  sessionSnapFor = name;
  sessionSnapTs.set(name, ts);
  sessionUnsent.delete(name);
  // liveSaveSig flushes first: the signature is the battery this state carries.
  // The snapshot is written at once and its picture after the encode: a
  // closing page may cut the encode short, which leaves the older picture
  // and its older ts, so it is not taken for this one. Each goes up when it
  // lands (the picture rides in the session's Drive file).
  const key = autoStateKey(name);
  const rec = { bytes, ts, saveSig: liveSaveSig(), by: deviceId, dev: deviceLabel,
                play: playClock() };
  const snap = { name, ...rec };
  unstoredSnap = snap;
  const put = dbPut(key, rec)
    .then(() => {
      if (unstoredSnap === snap) unstoredSnap = null;
      markUpload(key);
    }).catch(() => {});
  if (fb) {
    frameBlobFromFb(fb.heap, fb.w, fb.h)
      .then((blob) => blob && dbPut(sessionPicKey(name), { ts, blob }).then(() => put)
        .then(() => markUpload(key)))
      .catch(() => {});
  }
  return put;
};

// --- Checkpoints ---------------------------------------------------------
// The session above is taken when the game is left or the page hidden. A
// browser that crashes, or is killed while the game is on screen, gives no
// such moment, so the session would be wherever the game was last left -
// an hour back, or (saved in game since) none. So while a game runs, every
// CHECKPOINT_PLAY_MS of play takes the session again, and keeps it as a
// checkpoint: a few earlier moments, kept on this device only, for when the
// newest one is the thing that crashes (Resume from earlier).
//
// The frame's thread only copies: the plain state image, the screen and the
// battery file (wasm_state_plain_size, ~1 ms; ~4 ms on a phone-speed CPU).
// ckptworker.js packs the state, signs the battery and encodes the picture
// - packing on this thread cost ~10 ms there, a dropped frame. Without a
// worker it all runs here, as persistAutoState does.
const CHECKPOINT_PLAY_MS = 60 * 1000;
// How often the battery file is looked at for a fresh in-game save.
const SAVE_SETTLE_MS = 500;

// The battery stored within about a second of the game writing it, not at
// the next 5 s autosave: a crash in between lost an in-game save (measured).
// The core writes the file the frame the game writes its save, and a save
// is written over many frames (a flash chip's sectors), so it is stored
// once the file has stopped changing for one look. Every SAVE_SETTLE_MS.
let savSeen = { name: null, mtime: 0, settled: true };
const watchBattery = () => {
  if (linkMode || rollbackMode || netActive() || !currentRomName || !currentOriginalName) return;
  let mtime = 0;
  try { mtime = +FS.stat(stripExt(currentRomName) + ".sav").mtime; } catch { return; }
  if (savSeen.name !== currentOriginalName) {
    savSeen = { name: currentOriginalName, mtime, settled: true };
  } else if (mtime !== savSeen.mtime) {
    savSeen.mtime = mtime;
    savSeen.settled = false;
  } else if (!savSeen.settled) {
    savSeen.settled = true;
    return persistSave(currentRomName, currentOriginalName);
  }
};
// Taken in a tick that has room for it; a busy one passes it to the next,
// for up to CKPT_WAIT_MS before one is taken anyway.
const CKPT_SLACK_MS = 6;
const CKPT_WAIT_MS = 5000;
// Drive gets a checkpoint's session at most this often while playing; Main
// Menu, a hide or a close sends the newest at once (sessionUnsent).
const SESSION_UPLOAD_MS = 5 * 60 * 1000;

// Play time, the clock checkpoints are spaced on: wall time would put a
// week-old evening's checkpoints all in one bucket the moment play resumed.
// Per game and per device, carried in the checkpoint index (`play`): the
// run's base plus the ms this run has played.
let runPlayMs = 0;
let ckptPlayBase = 0;
let ckptLastAt = 0; // runPlayMs at the last checkpoint
const playClock = () => ckptPlayBase + runPlayMs;

// Games whose session is a checkpoint's not yet queued for Drive.
const sessionUnsent = new Set();
const sessionMarkedAt = new Map();
let ckptInFlight = null;
const checkpointLanded = () => ckptInFlight || Promise.resolve();

// One worker, made on first use; null where there is none to make (no
// Worker, no CompressionStream: iOS 15), and the page does the work.
let ckptWorker;
let ckptWorkerSeq = 0;
const ckptWorkerWaits = new Map();
const getCkptWorker = () => {
  if (ckptWorker !== undefined) return ckptWorker;
  ckptWorker = null;
  if (typeof Worker !== "function" || typeof CompressionStream !== "function") return null;
  try {
    ckptWorker = new Worker("ckptworker.js");
    ckptWorker.onmessage = (e) => {
      const wait = ckptWorkerWaits.get(e.data?.id);
      if (!wait) return;
      ckptWorkerWaits.delete(e.data.id);
      wait(e.data);
    };
    ckptWorker.onerror = () => {
      // A worker that cannot load (an old cache without the file): every
      // checkpoint from here runs on the page.
      for (const wait of ckptWorkerWaits.values()) wait({ error: "worker failed" });
      ckptWorkerWaits.clear();
      ckptWorker = null;
    };
  } catch { ckptWorker = null; }
  return ckptWorker;
};

// -> { bytes (packed), pic (Blob | null), saveSig }, or null.
const packCheckpoint = async (plain, fb, sav) => {
  const worker = getCkptWorker();
  if (worker) {
    const id = ++ckptWorkerSeq;
    const got = await new Promise((resolve) => {
      ckptWorkerWaits.set(id, resolve);
      // The state moves; the screen is copied (150 KB), so the page still
      // has it to draw where the worker cannot (no OffscreenCanvas JPEG).
      worker.postMessage({ id, state: plain.buffer, fb: fb ? fb.heap.buffer : null,
                           w: fb?.w, h: fb?.h, scale: FRAME_SCALE, q: FRAME_JPEG_Q,
                           sav: sav ? sav.buffer : null }, [plain.buffer]);
    });
    if (!got.error) {
      let pic = got.pic || null;
      if (!pic && fb) pic = await frameBlobFromFb(fb.heap, fb.w, fb.h).catch(() => null);
      return { bytes: new Uint8Array(got.packed), pic, saveSig: got.saveSig ?? null };
    }
    // The buffers went with the message; this one is lost, the next runs here.
    log("checkpoint worker: " + got.error, "warn");
    return null;
  }
  const bytes = packStateBytes(plain);
  if (!bytes) return null;
  const pic = fb ? await frameBlobFromFb(fb.heap, fb.w, fb.h).catch(() => null) : null;
  return { bytes, pic, saveSig: sigOfSave(sav) };
};

const capturePlainState = () => {
  if (typeof Module === "undefined" || !Module._wasm_state_plain_size) return null;
  const len = Module._wasm_state_plain_size();
  if (len <= 0) return null;
  const ptr = Module._wasm_state_data();
  if (!ptr) return null;
  return new Uint8Array(Module.memory.buffer, ptr, len).slice();
};

// From the end of every running tick, after the frame is on screen.
const maybeCheckpoint = (timestamp) => {
  if (ckptInFlight || !currentRomName || !currentOriginalName) return;
  if (linkMode || rollbackMode || netActive() || clipReplayActive || rewindHeld) return;
  if (sessionHeldFor === currentOriginalName) return; // a boot screen (sessionHeldFor)
  const due = runPlayMs - ckptLastAt - CHECKPOINT_PLAY_MS;
  if (due < 0) return;
  if (performance.now() - timestamp > CKPT_SLACK_MS && due < CKPT_WAIT_MS) return;
  takeCheckpoint();
};

const takeCheckpoint = () => {
  const name = currentOriginalName;
  ckptLastAt = runPlayMs;
  flushSoloSave(); // the battery the state carries, into its file
  const plain = capturePlainState();
  if (!plain) return null;
  let sav = null;
  try { sav = FS.readFile(stripExt(currentRomName) + ".sav"); } catch {}
  const fb = copyFramebuffer();
  const ts = Date.now();
  const play = playClock();
  const epoch = sessionEpoch(name);
  sessionMoved = false;
  sessionSnapFor = name;
  sessionSnapTs.set(name, ts);
  const run = packCheckpoint(plain, fb, sav)
    .then((snap) => snap && storeCheckpoint(name, { ...snap, ts, play, epoch }))
    .catch((e) => log("checkpoint: " + (e?.message || e), "warn"))
    .finally(() => { if (ckptInFlight === run) ckptInFlight = null; });
  ckptInFlight = run;
  return run;
};

const storeCheckpoint = async (name, snap) => {
  // A newer snapshot, or a delete or reset, since this one was taken: it is
  // history. Held since it was taken: not ours to write.
  const stale = () => sessionSnapTs.get(name) !== snap.ts ||
    sessionEpoch(name) !== snap.epoch || sessionHeldFor === name;
  if (stale()) return;
  // The battery it carries, stored now if the 5 s autosave has not yet: a
  // crash before that would leave a session that matches no stored save.
  if (currentOriginalName === name && currentRomName &&
      !(lastSaveSigKey === name && lastSaveSig === snap.saveSig)) {
    await persistSave(currentRomName, name);
    // Again: a Main Menu, a hide or a reset can land in that await, and
    // this older session would go over theirs (bug_ckpt_store_over_*).
    if (stale()) return;
  }
  const key = autoStateKey(name);
  await dbPut(key, { bytes: snap.bytes, ts: snap.ts, saveSig: snap.saveSig, by: deviceId,
                     dev: deviceLabel, play: snap.play });
  // A picture is a Blob, which Safari's private browsing will not store: the
  // session goes on without it (the hero falls back to the library's).
  if (snap.pic) await dbPut(sessionPicKey(name), { ts: snap.ts, blob: snap.pic }).catch(() => {});
  if (Date.now() - (sessionMarkedAt.get(name) || 0) >= SESSION_UPLOAD_MS) {
    sessionMarkedAt.set(name, Date.now());
    sessionUnsent.delete(name);
    markUpload(key);
  } else {
    sessionUnsent.add(name);
  }
  await addCheckpoint(name, snap);
};

// The kept checkpoints of a game: `ckpts:<game>` is the index ({ play, list:
// [{ slot, ts, play, saveSig }] }), and `ckpt<slot>:<game>` each one's
// { bytes, ts, play, saveSig, pic }. Local only: never in a Drive name.
const CKPT_SLOTS = 9;
const ckptIndexKey = (name) => "ckpts:" + name;
const ckptKey = (name, slot) => "ckpt" + slot + ":" + name;
const ckptKeys = (name) => [ckptIndexKey(name),
  ...Array.from({ length: CKPT_SLOTS }, (_, i) => ckptKey(name, i))];
const CKPT_KEY_RE = /^ckpts?\d*:/;

// Which to keep, spread over play time: the newest, and the oldest of each
// span behind it - up to 3 min, 10 min, 30 min, 2 h, 8 h, and beyond - so
// there is always one a little way back and one a long way back. Past
// CKPT_MAX_AGE_MS of real time one goes.
//
// After the game stops unexpectedly (crashSince), the ones taken before
// that are frozen until it has run cleanly again: a checkpoint that crashes
// the game can be resumed again and again, and what those runs take must
// not push out the moments from before it. They share CKPT_CRASH_ROOM.
const CKPT_SPANS = [3, 10, 30, 120, 480].map((m) => m * 60 * 1000);
const CKPT_MAX_AGE_MS = 30 * 24 * 3600 * 1000;
const CKPT_CRASH_ROOM = 2;
const newestFirst = (a, b) => (b.play - a.play) || (b.ts - a.ts);
const spreadCheckpoints = (list) => {
  if (!list.length) return [];
  const sorted = [...list].sort(newestFirst);
  const top = sorted[0];
  const oldest = new Map(); // span index -> the oldest in it
  for (const e of sorted.slice(1)) {
    const age = top.play - e.play;
    let span = CKPT_SPANS.findIndex((s) => age <= s);
    if (span < 0) span = CKPT_SPANS.length;
    oldest.set(span, e); // sorted newest first: the last one seen is the oldest
  }
  return [top, ...[...oldest.keys()].sort((a, b) => a - b).map((k) => oldest.get(k))];
};
const keepCheckpoints = (list, crashSince = 0, now = Date.now()) => {
  const live = list.filter((e) => now - e.ts < CKPT_MAX_AGE_MS);
  if (!crashSince) return spreadCheckpoints(live);
  const frozen = live.filter((e) => e.ts < crashSince);
  const since = live.filter((e) => e.ts >= crashSince).sort(newestFirst)
    .slice(0, CKPT_CRASH_ROOM);
  return [...since, ...frozen.sort(newestFirst)].slice(0, CKPT_SLOTS);
};

const readCheckpointIndex = async (name) => {
  const idx = await dbGet(ckptIndexKey(name)).catch(() => null);
  return idx && Array.isArray(idx.list) ? idx : { play: 0, list: [] };
};

const addCheckpoint = async (name, snap) => {
  const idx = await readCheckpointIndex(name);
  if (sessionEpoch(name) !== snap.epoch) return; // reset while it was read
  const entry = { slot: -1, ts: snap.ts, play: snap.play, saveSig: snap.saveSig };
  const keep = keepCheckpoints([...idx.list, entry], crashInfo(name)?.since || 0);
  if (!keep.includes(entry)) return;
  const used = new Set(keep.filter((e) => e !== entry).map((e) => e.slot));
  entry.slot = [...Array(CKPT_SLOTS).keys()].find((s) => !used.has(s)) ?? -1;
  if (entry.slot < 0) return;
  // The record and the index in one transaction: a slot the index names is
  // always the checkpoint it says. One it no longer names is overwritten
  // when its slot is next taken.
  const write = (pic) => dbMoveKeys([], [
    [ckptKey(name, entry.slot), { bytes: snap.bytes, ts: snap.ts, play: snap.play,
                                  saveSig: snap.saveSig, pic }],
    [ckptIndexKey(name), { play: Math.max(idx.play || 0, snap.play), list: keep }],
  ]);
  // Without its picture where a Blob will not store (Safari's private
  // browsing, seen in WebKit): the moment matters, the picture does not.
  try { await write(snap.pic || null); } catch (e) {
    if (!snap.pic) throw e;
    await write(null);
  }
};

// A game booted: its clock goes on from where its index left it.
const startCheckpointClock = (name) => {
  runPlayMs = 0;
  ckptLastAt = 0;
  ckptPlayBase = 0;
  readCheckpointIndex(name).then((idx) => {
    if (currentOriginalName !== name) return;
    ckptPlayBase = Math.max(idx.play || 0, ...idx.list.map((e) => e.play || 0));
  });
};

// Storage running out: other games' checkpoints go before any ROM does.
const evictCheckpoints = async (keep) => {
  let freed = false;
  for (const k of await dbKeys()) {
    if (typeof k !== "string" || !CKPT_KEY_RE.test(k)) continue;
    if (k.slice(k.indexOf(":") + 1) === keep) continue;
    await dbDelete(k);
    freed = true;
  }
  return freed;
};

// --- Crashes -------------------------------------------------------------
// A page that dies while a game is on screen leaves its mark behind: each
// page records itself in `playing` ({ <page>: { game, at, long } }) while
// its game runs in view, and takes itself out when the game pauses, the
// page is hidden or closed, or the game is left. One found at boot is a run
// that ended without any of those - a crash, or a kill in the foreground -
// unless its page is still alive, which that page's Web Lock says.
//
// Crashes are counted per game in a row (`crashes`: { games: { <game>:
// { streak, since } }, seen: [<page>...] }). Two in a row and the game asks
// before resuming (the sheet's crash form), since the moment it resumes may
// be the cause. A run counts toward the row only while it is short: one
// that played CLEAN_RUN_MS (`long`, set once it gets there) starts a new
// row at one - whatever ended it, what it resumed did not stop it - and one
// that played that long and ended normally clears the count.
//
// The marks and counts are in IndexedDB: Chrome writes localStorage to disk
// seconds later, so a browser killed soon after a relaunch - a game that
// crashes as soon as it resumes - lost the count and brought back the mark
// already counted (seen in a SIGKILL test). `seen` keeps a mark that comes
// back from being counted twice. But a closing page's IndexedDB writes do
// not land when the whole browser quits (Chrome and WebKit both, measured),
// while a synchronous localStorage write made in Chrome's close handlers
// does: so the end of a run is also said there (`dingbat_clean:<page>`),
// and a mark with it is not a crash.
const PLAYING_KEY = "playing";
const CRASHES_KEY = "crashes";
const CLEAN_PREFIX = "dingbat_clean:";
const CLEAN_RUN_MS = 60 * 1000;
const CRASH_ASK_STREAK = 2;
const CRASH_SEEN_MAX = 50;
const pageId = Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
let playingMarked = false;
let playingLong = false;
let coreFaulted = false;
// Read at boot (noteCrashedRuns) and written through: the tap that asks
// first reads it synchronously.
let crashes = { games: {}, seen: [] };
const crashRecord = (v) => v && typeof v === "object" && v.games && typeof v.games === "object"
  ? { games: v.games, seen: Array.isArray(v.seen) ? v.seen : [] } : { games: {}, seen: [] };
const crashInfo = (name) => crashes.games[name] || null;
const crashStreak = (name) => crashInfo(name)?.streak || 0;
const storeCrashes = () => dbPut(CRASHES_KEY, crashes).catch(() => {});
const lsGet = (k) => { try { return localStorage.getItem(k); } catch { return null; } };
const lsSet = (k, v) => { try { localStorage.setItem(k, v); return true; } catch { return false; } };
const lsDel = (k) => { try { localStorage.removeItem(k); } catch {} };
const lsKeys = () => { try { return Object.keys(localStorage); } catch { return []; } };

// Held for this page's life, so another page can tell a mark of ours from
// a crashed one's.
if (typeof navigator !== "undefined" && navigator.locks?.request) {
  try { navigator.locks.request("dingbat-page:" + pageId, () => new Promise(() => {})); } catch {}
}

const putMark = (mark) =>
  dbUpdate(PLAYING_KEY, (v) => ({ ...(v && typeof v === "object" ? v : {}), [pageId]: mark }))
    .catch(() => {});
const markPlaying = () => {
  if (playingMarked || !currentOriginalName) return;
  playingMarked = true;
  playingLong = runPlayMs >= CLEAN_RUN_MS;
  lsDel(CLEAN_PREFIX + pageId);
  putMark({ game: currentOriginalName, at: Date.now(), long: playingLong });
};
// From the tick: the run has played long enough that what it resumed did
// not stop it.
const notePlayingLong = () => {
  if (!playingMarked || playingLong || runPlayMs < CLEAN_RUN_MS || !currentOriginalName) return;
  playingLong = true;
  putMark({ game: currentOriginalName, at: Date.now(), long: true });
};
// The run ended normally. A core that faulted keeps its mark: the next
// boot counts it.
const clearPlaying = () => {
  if (!playingMarked || coreFaulted) return;
  playingMarked = false;
  const name = currentOriginalName;
  const long = runPlayMs >= CLEAN_RUN_MS;
  // First, and synchronously: what a quitting browser keeps.
  lsSet(CLEAN_PREFIX + pageId, JSON.stringify({ game: name, long }));
  dbUpdate(PLAYING_KEY, (v) => {
    if (!v || typeof v !== "object" || !(pageId in v)) return undefined;
    const next = { ...v };
    delete next[pageId];
    return next;
  }).then(() => lsDel(CLEAN_PREFIX + pageId)).catch(() => {});
  if (name && long && crashStreak(name)) {
    delete crashes.games[name];
    storeCrashes();
  }
};

// At boot: the marks of pages that are gone, and did not end cleanly, are
// crashes.
const noteCrashedRuns = async () => {
  crashes = crashRecord(await dbGet(CRASHES_KEY).catch(() => null));
  const stored = await dbGet(PLAYING_KEY).catch(() => null);
  const marks = stored && typeof stored === "object" ? stored : {};
  let held = new Set();
  try {
    const q = await navigator.locks?.query?.();
    for (const l of q?.held || []) held.add(l.name);
  } catch {}
  const alive = (id) => id === pageId || held.has("dingbat-page:" + id);
  const gone = Object.keys(marks).filter((id) => !alive(id));
  const counted = [];
  let changed = false;
  for (const id of gone) {
    const game = marks[id]?.game;
    if (crashes.seen.includes(id) || typeof game !== "string") continue;
    const clean = lsGet(CLEAN_PREFIX + id);
    if (clean !== null) {
      // Ended normally; only its IndexedDB write was lost.
      let c = null;
      try { c = JSON.parse(clean); } catch {}
      if (c?.long && crashes.games[game]) { delete crashes.games[game]; changed = true; }
      continue;
    }
    const c = crashes.games[game] || { streak: 0, since: 0 };
    crashes.games[game] = marks[id]?.long
      ? { streak: 1, since: Date.now() }
      : { streak: c.streak + 1, since: c.since || Date.now() };
    log("previous run of " + game + " ended unexpectedly (" + crashes.games[game].streak +
        " in a row)", "warn");
    counted.push(game);
    changed = true;
  }
  if (gone.length) {
    crashes.seen = [...crashes.seen, ...gone].slice(-CRASH_SEEN_MAX);
    changed = true;
  }
  // The count first, with the marks it counted; then the marks go.
  if (changed) await storeCrashes();
  if (gone.length) {
    await dbUpdate(PLAYING_KEY, (v) => {
      if (!v || typeof v !== "object") return undefined;
      const next = { ...v };
      for (const id of gone) delete next[id];
      return next;
    }).catch(() => {});
  }
  // Clean-end notes of pages that are gone: their marks are dealt with.
  for (const id of gone) lsDel(CLEAN_PREFIX + id);
  for (const k of lsKeys()) {
    if (k.startsWith(CLEAN_PREFIX) && !alive(k.slice(CLEAN_PREFIX.length))) lsDel(k);
  }
  // Its last checkpoint may never have been queued for Drive.
  for (const game of counted) {
    if (await dbGet(autoStateKey(game)).catch(() => null)) markUpload(autoStateKey(game));
  }
};

// --- Last gasp -------------------------------------------------------------
// A browser that quits with the game on screen runs the page's close
// handlers, but the IndexedDB writes they start never land (Chrome and
// WebKit both, measured) - so the session taken there, and a battery the
// autosave had not stored, were lost, and the next launch went back to the
// last checkpoint. What does land in Chrome is a synchronous localStorage
// write: so the close handlers also leave the session there, with the
// battery when it is not stored yet (`dingbat_lastgasp`), and the next boot
// takes it in when it is newer than the stored session. `lastgasp` in
// IndexedDB is the newest one taken in, so one that comes back from
// localStorage (written to disk late, like the marks) is never taken twice.
const LAST_GASP_KEY = "dingbat_lastgasp";
const LAST_GASP_SEEN_KEY = "lastgasp";
// The newest snapshot of the game, while its IndexedDB write has not landed.
let unstoredSnap = null;

const bytesToB64 = (u8) => {
  let s = "";
  for (let i = 0; i < u8.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
  }
  return btoa(s);
};
const b64ToBytes = (b64) => {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
};

// From the close handlers, after persistAutoState and persistSave.
const leaveLastGasp = () => {
  const snap = unstoredSnap;
  if (!snap || snap.name !== currentOriginalName || !currentRomName) return;
  let sav = null;
  try { sav = FS.readFile(stripExt(currentRomName) + ".sav"); } catch {}
  // The battery it was taken with, when the stored one is not that already.
  const savSig = sigOfSave(sav);
  const keepSav = !!sav && savSig === snap.saveSig &&
    !(lastSaveSigKey === snap.name && lastSaveSig === savSig);
  lsSet(LAST_GASP_KEY, JSON.stringify({
    game: snap.name, ts: snap.ts, saveSig: snap.saveSig, play: snap.play, page: pageId,
    state: bytesToB64(snap.bytes), sav: keepSav ? bytesToB64(sav) : null,
  }));
};

// At boot, before anything reads the sessions.
const takeLastGasp = async () => {
  const raw = lsGet(LAST_GASP_KEY);
  if (!raw) return;
  let g = null;
  try { g = JSON.parse(raw); } catch {}
  const seen = (await dbGet(LAST_GASP_SEEN_KEY).catch(() => null)) || 0;
  if (g && typeof g.game === "string" && typeof g.state === "string" && g.ts > seen &&
      g.page !== pageId) {
    const cur = await dbGet(autoStateKey(g.game)).catch(() => null);
    if (!cur || !(cur.ts >= g.ts)) {
      if (g.sav) {
        const sav = b64ToBytes(g.sav);
        if (sigOfSave(sav) === g.saveSig &&
            sigOfSave(await dbGet("save:" + g.game).catch(() => null)) !== g.saveSig) {
          await dbPut("save:" + g.game, sav);
          markUpload("save:" + g.game);
        }
      }
      await dbPut(autoStateKey(g.game), { bytes: b64ToBytes(g.state), ts: g.ts,
                                          saveSig: g.saveSig, by: deviceId, dev: deviceLabel,
                                          play: g.play });
      markUpload(autoStateKey(g.game));
      log("took in the session " + g.game + " was closed on", "info");
    }
    await dbPut(LAST_GASP_SEEN_KEY, g.ts).catch(() => {});
  }
  lsDel(LAST_GASP_KEY);
};

// A trap in the core leaves the page up with the game dead in it: as good
// as a crash, so its mark stays for the next boot.
window.addEventListener("error", (e) => {
  if (typeof WebAssembly !== "undefined" && e?.error instanceof WebAssembly.RuntimeError) {
    coreFaulted = true;
  }
});

// A session as one Drive file: "DGBSESS1", the header's length (u32 LE),
// the header (JSON: ts, saveSig, by, dev and the two lengths), the state,
// then the picture when it is this session's.
const SESSION_MAGIC = "DGBSESS1";
const sessionBundle = async (game, rec) => {
  if (!rec?.bytes) return null;
  let state = rec.bytes instanceof Uint8Array ? rec.bytes : new Uint8Array(rec.bytes);
  if (!state.length) return null;
  let pic = new Uint8Array(0);
  let p = await dbGet(sessionPicKey(game)).catch(() => null);
  if (p?.blob && p.ts === rec.ts) pic = new Uint8Array(await p.blob.arrayBuffer());
  let head = new TextEncoder().encode(JSON.stringify({
    // saveSig null is "taken with no save" (a game not yet saved in), and
    // counts; absent is a snapshot from before saveSig, which does not.
    ts: rec.ts, saveSig: rec.saveSig, by: rec.by ?? null, dev: rec.dev ?? null,
    state: state.length, pic: pic.length,
  }));
  let out = new Uint8Array(12 + head.length + state.length + pic.length);
  for (let i = 0; i < 8; i++) out[i] = SESSION_MAGIC.charCodeAt(i);
  new DataView(out.buffer).setUint32(8, head.length, true);
  out.set(head, 12);
  out.set(state, 12 + head.length);
  out.set(pic, 12 + head.length + state.length);
  return out;
};
// -> { rec, pic: Blob | null }, or null for anything that is not one.
const sessionFromBundle = (bytes) => {
  if (!bytes || bytes.length < 12) return null;
  for (let i = 0; i < 8; i++) if (bytes[i] !== SESSION_MAGIC.charCodeAt(i)) return null;
  let hl = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(8, true);
  let h;
  try { h = JSON.parse(new TextDecoder().decode(bytes.subarray(12, 12 + hl))); } catch { return null; }
  let at = 12 + hl;
  if (!h || !(h.state > 0) || at + h.state + (h.pic || 0) > bytes.length) return null;
  let rec = { bytes: bytes.slice(at, at + h.state), ts: h.ts };
  // Kept as written, null included: a snapshot from before saveSig has
  // the key absent, and is not offered (autoStateMatchesSave).
  if ("saveSig" in h) rec.saveSig = h.saveSig;
  if (h.by) rec.by = h.by;
  if (h.dev) rec.dev = h.dev;
  let pic = h.pic > 0
    ? new Blob([bytes.slice(at + h.state, at + h.state + h.pic)], { type: "image/jpeg" }) : null;
  return { rec, pic };
};

// The loaded game's battery as it is now: its FS .sav, which the core writes
// the moment the game saves (flushed first: a paused core's RAM may be ahead
// of it) and save:<name> catches up with only at the next autosave (up to 5 s
// later).
const liveSaveSig = () => {
  flushSoloSave();
  let sav = null;
  try { sav = FS.readFile(stripExt(currentRomName) + ".sav"); } catch {}
  return sigOfSave(sav);
};

// Snapshots from before saveSig have no proof either way and are not offered.
const autoStateMatchesSave = async (name, auto) =>
  auto.saveSig !== undefined &&
  auto.saveSig === sigOfSave(await dbGet("save:" + name).catch(() => null));

// A game's session where it can be resumed: a snapshot taken with the save
// that is stored now. Null otherwise - none, one from before saveSig, or one
// the game has saved past. What the hero's Resume goes back into, with no
// offer to ask.
const resumeSessionFor = async (name) => {
  let auto = null;
  try { auto = await dbGet(autoStateKey(name)); } catch {}
  if (!auto?.bytes) return null;
  if (!(await autoStateMatchesSave(name, auto))) return null;
  // `elsewhere`: the kind of device another one is ("" when unknown), for
  // the hero to say where the session was left.
  let elsewhere = auto.by && auto.by !== deviceId ? auto.dev || "" : null;
  return { bytes: auto.bytes, saveSig: auto.saveSig, ts: auto.ts, elsewhere };
};

// The session's picture, decoded, if it is this session's (see
// sessionPicKey); null otherwise, or where nothing can decode it.
const sessionPicFor = async (name, session) => {
  if (!session || typeof createImageBitmap !== "function") return null;
  let rec = null;
  try { rec = await dbGet(sessionPicKey(name)); } catch {}
  if (!rec?.blob || rec.ts !== session.ts) return null;
  try { return await createImageBitmap(rec.blob); } catch { return null; }
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
  if (!(await autoStateMatchesSave(name, auto))) return;
  if (name !== currentOriginalName) return;
  showActionToast("Last session saved " + fmtAgo(auto.ts), "Resume", async () => {
    if (currentOriginalName !== name) return; // switched games since
    // The toast outlives the check above; the game may have saved since -
    // in save:<name>, or only in its FS .sav so far (the live battery is
    // read in the same run as the apply, after the await).
    if (!(await autoStateMatchesSave(name, auto)) || currentOriginalName !== name ||
        auto.saveSig !== liveSaveSig()) {
      showToast("The game has saved since — that session is gone");
      return;
    }
    if (applyStateBytes(auto.bytes)) showToast("Resumed");
    else refuseState(auto.bytes, { kind: "session" });
  }, 8000, { game: true });
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

// --- Resume from earlier ---------------------------------------------------
// The moments a game can go back into: its session (where it stopped) and
// its checkpoints, newest first, each with its picture, how much play
// earlier it is and when. Two ways in, and nothing anywhere else: the
// game's menu (Resume from earlier), and - after the game has stopped
// unexpectedly CRASH_ASK_STREAK times in a row - a tap on the game itself,
// which opens this instead of resuming the moment that may be the cause.
//
// A moment from before the game's last in-game save takes its battery back
// with it (a state carries the cart's RAM). The newer save is kept aside
// first, as a restored save keeps the one it replaces: Restore old save, on
// the game's menu, switches back.
const momentsModal = document.getElementById("moments-modal");
const momentsGrid = document.getElementById("moments-grid");
const momentsTitle = document.getElementById("moments-title");
const momentsHint = document.getElementById("moments-hint");
const momentsNote = document.getElementById("moments-note");
const momentsResumeBtn = /** @type {HTMLButtonElement} */ (document.getElementById("moments-resume"));
const momentsFromSaveBtn = /** @type {HTMLButtonElement} */ (document.getElementById("moments-from-save"));
let momentsFor = null;
let momentsList = [];
let momentsPick = 0;
let momentsSaveSig = null;
let momentsUrls = [];

// -> [{ kind: "session" | "checkpoint", slot?, ts, play, saveSig }], newest first.
const listMoments = async (name) => {
  const out = [];
  const auto = await dbGet(autoStateKey(name)).catch(() => null);
  const idx = await readCheckpointIndex(name);
  const ckpts = [...idx.list].sort(newestFirst);
  if (auto?.bytes) {
    out.push({ kind: "session", ts: auto.ts, play: auto.play ?? ckpts[0]?.play ?? 0,
               saveSig: auto.saveSig });
  }
  for (const e of ckpts) {
    if (auto?.bytes && e.ts >= auto.ts) continue; // the session is that moment, or newer
    out.push({ kind: "checkpoint", slot: e.slot, ts: e.ts, play: e.play, saveSig: e.saveSig });
  }
  return out;
};
const hasEarlierMoments = async (name) => (await readCheckpointIndex(name)).list.length > 0;

const momentRecord = (name, m) =>
  dbGet(m.kind === "session" ? autoStateKey(name) : ckptKey(name, m.slot)).catch(() => null);
const momentPicture = async (name, m) => {
  if (m.kind === "checkpoint") return (await momentRecord(name, m))?.pic || null;
  const p = await dbGet(sessionPicKey(name)).catch(() => null);
  return p?.blob && p.ts === m.ts ? p.blob : null;
};

// "4 min earlier", "2 h earlier": play time, the clock the moments are kept on.
const fmtPlayGap = (ms) => {
  const m = Math.round(ms / 60000);
  if (m < 1) return "Just before";
  if (m < 60) return m + " min earlier";
  const h = ms / 3600000;
  return (h < 10 ? Math.round(h * 2) / 2 : Math.round(h)) + " h earlier";
};
const fmtMomentTime = (ts) => {
  try {
    const d = new Date(ts);
    return d.toDateString() === new Date().toDateString()
      ? d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : fmtStateTime(ts);
  } catch { return ""; }
};

const selectMoment = (i) => {
  momentsPick = i;
  for (const el of /** @type {HTMLCollectionOf<HTMLElement>} */ (momentsGrid.children)) {
    el.classList.toggle("selected", Number(el.dataset.i) === i);
  }
  const m = momentsList[i];
  momentsResumeBtn.disabled = !m;
  const before = !!m && m.saveSig !== momentsSaveSig && momentsSaveSig !== null;
  momentsNote.hidden = !before;
  momentsNote.textContent = before
    ? "This is from before your last in-game save, which goes back with it. Your newer save " +
      "is kept: Restore old save, on the game's menu, brings it back." : "";
};

const renderMoments = async (name) => {
  for (const u of momentsUrls) URL.revokeObjectURL(u);
  momentsUrls = [];
  momentsList = await listMoments(name);
  momentsSaveSig = sigOfSave(await dbGet("save:" + name).catch(() => null));
  if (momentsFor !== name) return;
  momentsGrid.replaceChildren();
  const top = momentsList[0];
  for (let i = 0; i < momentsList.length; i++) {
    const m = momentsList[i];
    const cell = document.createElement("button");
    cell.type = "button";
    cell.className = "state-slot";
    cell.dataset.i = /** @type {*} */ (i);
    const thumb = document.createElement("img");
    thumb.className = "slot-thumb";
    thumb.alt = "";
    const label = document.createElement("div");
    label.className = "slot-label";
    const what = document.createElement("span");
    what.className = "slot-num";
    what.textContent = i === 0 ? "Latest" : fmtPlayGap(top.play - m.play);
    const when = document.createElement("span");
    when.textContent = fmtMomentTime(m.ts);
    label.append(what, when);
    cell.append(thumb, label);
    if (m.saveSig !== momentsSaveSig && momentsSaveSig !== null) {
      const note = document.createElement("span");
      note.className = "moment-before-save";
      note.textContent = "Before your last save";
      cell.append(note);
    }
    cell.addEventListener("click", () => selectMoment(i));
    cell.addEventListener("dblclick", () => { selectMoment(i); momentsResumeBtn.click(); });
    momentsGrid.append(cell);
    momentPicture(name, m).then((blob) => {
      if (!blob || momentsFor !== name) return;
      const url = URL.createObjectURL(blob);
      momentsUrls.push(url);
      thumb.src = url;
    }).catch(() => {});
  }
  selectMoment(0);
};

// `crash`: the form a tap on a game that keeps stopping opens.
const openMomentsModal = (name, { crash = false } = {}) => {
  closeTileMenu();
  momentsFor = name;
  const n = crashStreak(name);
  momentsTitle.textContent = crash
    ? displayName(name) + " stopped unexpectedly" : "Resume from earlier";
  momentsHint.textContent = crash
    ? "It closed without warning the last " + (n === 2 ? "two" : n) + " times. If the " +
      "moment it resumes from is what's stopping it, pick an earlier one."
    : "Moments from your recent play, kept on this device.";
  momentsFromSaveBtn.hidden = !crash;
  momentsGrid.replaceChildren();
  momentsNote.hidden = true;
  momentsResumeBtn.disabled = true;
  momentsModal.classList.add("open");
  trapFocus(momentsModal);
  return renderMoments(name);
};

const closeMomentsModal = () => {
  if (!momentsModal.classList.contains("open")) return;
  momentsModal.classList.remove("open");
  releaseFocus(momentsModal);
  momentsFor = null;
  for (const u of momentsUrls) URL.revokeObjectURL(u);
  momentsUrls = [];
};

// Back into one moment: the game boots on its stored save and the moment
// goes in during the boot (loadRom's `resume`, forced - the battery comes
// with it). True when the boot was started.
const resumeMoment = async (name, m) => {
  if (isRomLoaded(name) && (linkMode || rollbackMode || netActive())) {
    showToast("Exit the online session first");
    return false;
  }
  // The running game's save as it is now is the one that may be replaced.
  if (currentOriginalName === name && currentRomName) await persistSave(currentRomName, name);
  const rec = await momentRecord(name, m);
  if (!rec?.bytes) {
    showToast("That moment is no longer stored");
    return false;
  }
  const cur = await dbGet("save:" + name).catch(() => null);
  if (cur?.length && rec.saveSig !== sigOfSave(cur)) {
    const now = Date.now();
    await keepOldSave(name, { data: new Uint8Array(cur), at: now, del: now, kept: now,
                              why: "replaced" });
  }
  launchRom(name, { session: { bytes: rec.bytes, saveSig: rec.saveSig, force: true } });
  return true;
};

// A tap on a game that has stopped unexpectedly twice in a row asks first.
const crashGate = (name) => {
  if (crashStreak(name) < CRASH_ASK_STREAK || isRomLoaded(name)) return false;
  openMomentsModal(name, { crash: true });
  return true;
};

momentsResumeBtn.addEventListener("click", async () => {
  const name = momentsFor;
  const m = momentsList[momentsPick];
  if (!name || !m) return;
  closeMomentsModal();
  await resumeMoment(name, m);
});
momentsFromSaveBtn.addEventListener("click", () => {
  const name = momentsFor;
  if (!name) return;
  closeMomentsModal();
  launchRom(name, { fresh: true });
});
document.getElementById("moments-close").addEventListener("click", closeMomentsModal);
momentsModal.addEventListener("click", (e) => {
  if (e.target === momentsModal) closeMomentsModal();
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
  reportWasPaused = takePlayerPause();
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
  // Escape calls every closer blindly; a stale reportWasPaused would unpause a later pause.
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
// Clip (two). Marker values are samples back from newest. Thumbnails arrive
// from wasm as packed little-endian BGR555, newest first.

const STRIP_GAP = 2;             // px between frames in the strip
const STRIP_TAP_SLOP = 5;        // px of travel below which a drag counts as a tap

// Frame width follows how many frames fit the strip's own width (a 208px
// phone strip and a 400px desktop one show the same history), clamped.
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
 * @param {boolean} [opts.direct]       a drag carries the marker (else scrolls the film)
 */
const createFilmStrip = ({
  canvas, wrap, markers, paint, onChange,
  visibleFrames = STRIP_VISIBLE_FRAMES,
  frameWMin = STRIP_FRAME_W_MIN,
  frameWMax = STRIP_FRAME_W_MAX,
  fitFrames = 0,
  frameWFloor = STRIP_FRAME_W_FLOOR,
  // false: the marker stays put and a drag scrolls the film under it (the
  // rewind playhead). true: a drag carries the grabbed marker with the
  // finger over a still film, which scrolls only at the strip's ends (the
  // clip's two bounds, which are pulled in and out, not scrubbed).
  direct = false,
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
  // Direct mode: the film offset a drag holds still (and keeps once the
  // finger lifts, so nothing jumps); null lets placement() frame the view.
  let held = null;

  // Layout sizes, not getBoundingClientRect's: the modal opens with a
  // scale-in, and a strip framed mid-animation was framed for a narrower
  // strip than the one the finger then lands on. (The test DOM has rects only.)
  const layoutW = (el) => el.offsetWidth || el.getBoundingClientRect().width;
  const layoutH = (el) => el.offsetHeight || el.getBoundingClientRect().height;
  // Where the film is, for a pointer: the canvas's left edge (the markers
  // are placed in its coordinates) and its width.
  const filmFrame = () => ({ left: canvas.getBoundingClientRect().left, width: layoutW(canvas) });

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
    held = null;   // the pitch may change, so a held offset means nothing
    if (!thumbs || samples <= 0) return;
    const stripH = Math.max(24, Math.round(layoutH(wrap)) - 2);
    const { tw, th } = frameSize(Math.max(120, Math.round(layoutW(wrap))), stripH);
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

  // The focus (the whole selection when it fits, else the dragged marker)
  // rides the middle and the film scrolls under it until the film runs out
  // of slack; then the markers travel, else half the strip is empty at the
  // "now" end, where these modals open.
  const offRange = (cssW) => {
    const filmW = samples * pitch;
    return filmW <= cssW
      ? { lo: (cssW - filmW) / 2, hi: (cssW - filmW) / 2 } // short film: centred
      : { lo: cssW - filmW, hi: 0 };
  };

  const placement = (cssW) => {
    const filmW = samples * pitch;
    const xsFilm = markers.map((m, i) => edgeX(values[i], m.edge));
    const { lo: offLo, hi: offHi } = offRange(cssW);
    let off;
    if (held !== null) {
      off = Math.min(offHi, Math.max(offLo, held));
    } else {
      const lo = Math.min(...xsFilm);
      const hi = Math.max(...xsFilm);
      const focus = hi - lo <= cssW ? (lo + hi) / 2 : xsFilm[active];
      off = filmW <= cssW ? offLo : Math.min(offHi, Math.max(offLo, cssW / 2 - focus));
    }
    return { off, xs: xsFilm.map((x) => x + off) };
  };

  const draw = () => {
    const cssW = Math.max(1, Math.round(layoutW(canvas)));
    const cssH = Math.max(1, Math.round(layoutH(canvas)));
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
  let grabDX = 0;         // direct: finger x less the grabbed marker's, at the press
  let edgeTimer = 0;      // direct: the rAF scrolling the film at an end
  let edgeLast = 0;
  let heading = 0;        // direct: -1 / +1, the way the finger last moved

  // A press grabs the nearest marker on screen.
  const grabNearest = (clientX) => {
    if (markers.length === 1) return 0;
    const rect = filmFrame();
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
      held = null;
    },
    /** Drop everything on close (tens of thumbnails). */
    release() {
      thumbs = null;
      stripColor = null;
      stripDim = null;
      samples = 0;
    },
    setValue(i, v, snap, bounds) {
      // A move from outside the strip (a knob, a preset) hands the framing
      // back, so the view goes to the marker that moved.
      held = null;
      const moved = setValue(i, v, snap, bounds);
      if (moved) onChange(i);
      return moved;
    },
    setActive(i) { active = i; },
    /** Let placement() frame the view again (a fresh open). */
    reframe() { held = null; },
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
      // Direct: the grabbed marker goes where the finger is, over a film
      // held at `held`. The inverse of edgeX.
      const followFinger = () => {
        const rect = filmFrame();
        const filmX = lastX - rect.left - grabDX - held;
        const v = markers[active].edge === "lead"
          ? samples - 1 - filmX / pitch
          : samples - filmX / pitch;
        if (setValue(active, v, false, boundsFor(active))) onChange(active);
        else draw();
      };
      // A finger held near either end, having moved toward it, scrolls the
      // film that way, faster the nearer the edge, so a bound can be pulled
      // past what is on screen. (A bound grabbed near an end and pulled
      // inward must not set the film creeping.)
      const EDGE = 28;            // px from each end that scrolls
      const EDGE_SPEED = 700;     // px/s at the very edge
      const edgeStep = (now) => {
        edgeTimer = 0;
        if (!dragging || held === null) return;
        const rect = filmFrame();
        const x = lastX - rect.left;
        const push = x < EDGE && heading < 0 ? (EDGE - x) / EDGE
          : x > rect.width - EDGE && heading > 0 ? -(x - (rect.width - EDGE)) / EDGE : 0;
        if (push === 0) return;
        const dt = edgeLast ? Math.min(0.05, (now - edgeLast) / 1000) : 1 / 60;
        edgeLast = now;
        const { lo, hi } = offRange(rect.width);
        const next = Math.min(hi, Math.max(lo, held + Math.max(-1, Math.min(1, push)) * EDGE_SPEED * dt));
        if (next !== held) {
          held = next;
          followFinger();
        }
        edgeTimer = requestAnimationFrame(edgeStep);
      };
      wrap.addEventListener("pointerdown", (e) => {
        if (samples <= 0) return;
        e.preventDefault();
        dragging = true;
        travel = 0;
        heading = 0;
        lastX = e.clientX;
        active = grabNearest(e.clientX);
        if (direct) {
          const rect = filmFrame();
          const { off, xs } = placement(rect.width);
          held = off;
          grabDX = e.clientX - rect.left - xs[active];
        }
        wrap.setPointerCapture(e.pointerId);
        draw();  // the view follows the newly active marker
      });
      wrap.addEventListener("pointermove", (e) => {
        if (!dragging) return;
        const dx = e.clientX - lastX;
        lastX = e.clientX;
        travel += Math.abs(dx);
        if (dx !== 0) heading = Math.sign(dx);
        if (direct) {
          followFinger();
          if (!edgeTimer) {
            edgeLast = 0;
            edgeTimer = requestAnimationFrame(edgeStep);
          }
          return;
        }
        // Dragging right pulls older frames under the marker.
        api.setValue(active, values[active] + dx / pitch, false, boundsFor(active));
      });
      const endDrag = (e) => {
        if (!dragging) return;
        dragging = false;
        if (edgeTimer) { cancelAnimationFrame(edgeTimer); edgeTimer = 0; }
        if (wrap.hasPointerCapture?.(e.pointerId)) wrap.releasePointerCapture(e.pointerId);
        if (travel <= STRIP_TAP_SLOP && e.type === "pointerup") {
          // A tap moves the nearest marker to the frame under the finger,
          // resolved through the draw's own placement.
          const rect = filmFrame();
          const { off } = placement(rect.width);
          const filmX = e.clientX - rect.left - off;
          setValue(active, samples - 1 - Math.floor(filmX / pitch), true, boundsFor(active));
        } else {
          setValue(active, values[active], true, boundsFor(active)); // settle
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
  rwWasPaused = takePlayerPause();
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
  // Escape calls every closer blindly; a stale rwWasPaused would unpause a later pause.
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
    showActionToast("Rewound " + cost, "Undo", rwUndoCommit, 8000, { game: true });
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
  if (applyStateBytes(bytes)) showToast("State loaded");
  else refuseState(bytes, { kind: "bytes", bytes });
};

document.getElementById("import-state").addEventListener("click", () => {
  menuDropdown.hidden = true;
  if (!currentOriginalName) return;
  pickFile(".state", (bytes) => applyImportedState(bytes));
});

// --- Volume control ---

var volume = 100;
var muted = false;
const volSliders = Array.from(/** @type {NodeListOf<HTMLInputElement>} */ (document.querySelectorAll(".vol-range")));
const muteBtn = document.getElementById("mute-btn");
const menuVolume = document.getElementById("menu-volume");

const effectiveGain = () => (muted ? 0 : volume / 100);

// Nothing audible: the core skips mixing (emulation is unchanged) and
// pushAudio gets no samples. The core remembers it for later games.
const applyAudioSilent = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_audio_silent) {
    Module._wasm_set_audio_silent(effectiveGain() === 0 ? 1 : 0);
  }
};

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

// The "audio" record's defaults revision. Rev 2 (2026-09-30) turned
// pitch-correct fast-forward and the analog filter on by default. Every
// audio change writes all six fields, so a rev-1 record's `false` for those
// two is the old default saved alongside a volume change, not a choice
// (neither could be turned off without first being turned on): a rev-1
// record takes the new defaults for them once.
const AUDIO_REV = 2;

let audioSaveTimer = null;
const saveAudioSettings = () => {
  if (!db) return;
  clearTimeout(audioSaveTimer);
  audioSaveTimer = setTimeout(
    () => dbPut("audio", { rev: AUDIO_REV, volume, muted, pitchCorrectFF, audioLowpass,
                           mp2kHle, fifoInterp, playInSilent }), 250);
};

const setVolume = (v) => {
  volume = Math.max(0, Math.min(100, Math.round(v)));
  if (volume > 0) muted = false;
  syncVolumeUI();
  applyAudioSilent();
  if (typeof updateGain === "function") updateGain();
  saveAudioSettings();
};

const toggleMute = () => {
  muted = !muted;
  if (!muted && volume === 0) volume = 50;
  syncVolumeUI();
  applyAudioSilent();
  if (typeof updateGain === "function") updateGain();
  saveAudioSettings();
};

const loadAudioSettings = async () => {
  let s = await dbGet("audio");
  if (s && typeof s.volume === "number") {
    volume = Math.max(0, Math.min(100, s.volume));
    muted = !!s.muted;
    syncVolumeUI();
    applyAudioSilent();
    if (typeof updateGain === "function") updateGain();
  }
  const current = !!s && s.rev === AUDIO_REV;
  if (current && typeof s.pitchCorrectFF === "boolean") pitchCorrectFF = s.pitchCorrectFF;
  if (pcffToggle) pcffToggle.checked = pitchCorrectFF;
  applyPitchCorrectFF();
  if (current && typeof s.audioLowpass === "boolean") audioLowpass = s.audioLowpass;
  if (lowpassToggle) lowpassToggle.checked = audioLowpass;
  applyAudioLowpass();
  if (s && typeof s.mp2kHle === "boolean") mp2kHle = s.mp2kHle;
  if (mp2kHleToggle) mp2kHleToggle.checked = mp2kHle;
  applyMp2kHle();
  if (s && typeof s.fifoInterp === "boolean") fifoInterp = s.fifoInterp;
  if (fifoInterpToggle) fifoInterpToggle.checked = fifoInterp;
  applyFifoInterp();
  if (s && typeof s.playInSilent === "boolean") playInSilent = s.playInSilent;
  if (playInSilentToggle) playInSilentToggle.checked = playInSilent;
  applyAudioSession();
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
// On by default: the APUs reach the stretcher only while turbo is set, so it
// costs nothing at normal speed (~1-3 % of fast-forward speed when used).
var pitchCorrectFF = true;
const pcffToggle = /** @type {HTMLInputElement} */ (document.getElementById("pitch-correct-ff-toggle"));

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

// --- GBA audio interpolation ---
// Cubic reconstruction of the DirectSound FIFO stream, on by default; off is
// bit-true DAC output. The wasm side remembers it for future cores.
var fifoInterp = true;
const fifoInterpToggle = /** @type {HTMLInputElement} */ (document.getElementById("fifo-interp-toggle"));

const applyFifoInterp = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_fifo_interp) {
    Module._wasm_set_fifo_interp(fifoInterp ? 1 : 0);
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
// The note icon in the top bar (#hle-indicator) turns the HLE off and on for
// the loaded game only: never saved, cleared by loadRom. It exists so the
// two mixes can be compared mid-song without a trip through Settings.
var mp2kHleSessionOff = false;
const mp2kHleToggle = /** @type {HTMLInputElement} */ (document.getElementById("mp2k-hle-toggle"));

const applyMp2kHle = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_mp2k_hle) {
    Module._wasm_set_mp2k_hle((mp2kHle && !mp2kHleSessionOff) ? 1 : 0);
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
// On by default, GBA games only (the GBA's own output filter and speaker).
// Off, or on a Game Boy game, it is routed out of the graph: bit-identical
// to no filter. It runs on the audio thread, never the emulation's.
var audioLowpass = true;
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

// --- Play in Silent Mode (iOS/iPadOS) ---
// Safari's "playback" audio session plays in Silent Mode but pauses other
// apps' audio (WebKit sets it without mix-with-others); "ambient" mixes
// with them but is silenced in Silent Mode (not on headphones). No type
// does both, so the user picks; on by default, as the game sounding
// broken on a muted phone is the worse surprise. Paused, with no
// game open, muted or at volume 0 there is nothing to play, so the page
// never holds the exclusive session then. Only claimed once audio has
// started (initAudio); the frame loop re-applies it every tick, which
// catches every pause.
var playInSilent = true;
var audioSessionLive = false;
let audioSessionSet = "";   // the type last given, so most ticks are a compare
const playInSilentToggle = /** @type {HTMLInputElement} */ (document.getElementById("play-in-silent-toggle"));

const audioSessionType = () =>
  (!playInSilent || paused || !(currentRomName || linkMode) || muted || volume === 0)
    ? "ambient" : "playback";

const applyAudioSession = () => {
  const session = navigator.audioSession;
  if (!session || !audioSessionLive) return;
  const t = audioSessionType();
  if (t === audioSessionSet) return;
  audioSessionSet = t;
  session.type = t;
};

// Only where Silent Mode exists to choose about: iOS/iPadOS (any browser).
{
  const row = document.getElementById("play-in-silent-row");
  const iosLike = /iPhone|iPad|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  if (row) row.hidden = !(navigator.audioSession && iosLike);
}

if (playInSilentToggle) {
  playInSilentToggle.addEventListener("change", () => {
    playInSilent = playInSilentToggle.checked;
    applyAudioSession();
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
// The Filter selector: smoothing filters ("hq4x" | "xbr") and
// screen looks ("grid" | "rgb") in one select, since exactly one is active.
// The screen looks are not u_filter values; drawGame maps them to their own
// uniforms.
var upscaleFilter = "none";

// Backing store = native * glScale(); NEAREST sampling makes it a crisp
// integer upscale. The RGB look needs 6: two whole backing pixels per
// stripe, where 4 gives 4/3 and aliases into moire.
const glScale = () => (upscaleFilter === "rgb" ? 6 : 4);

const canvasEl = /** @type {HTMLCanvasElement} */ (document.getElementById("canvas"));
const stageEl = document.getElementById("stage");
const glowCanvas = /** @type {HTMLCanvasElement} */ (document.getElementById("glow-canvas"));
const glowCtx = glowCanvas.getContext("2d");
// The ambient glow's sample grid; glpresent.js composes it (createGlowComposer).
const GLOW_SAMPLE_W = 24, GLOW_SAMPLE_H = 16;
const glowComposer = createGlowComposer(GLOW_SAMPLE_W, GLOW_SAMPLE_H);
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
  // Keep the glow canvas pinned to the canvas rect.
  const singleCore = running && !linkMode && !rollbackMode;
  if (ambientGlow && singleCore) {
    // The unzoomed box: the glow sits behind the frame's home, not its zoom.
    const z = canvasEl.getBoundingClientRect();
    const zw = z.width / zoomS, zh = z.height / zoomS;
    const c = { left: z.left + (z.width - zw) / 2 - zoomX,
                top: z.top + (z.height - zh) / 2 - zoomY, width: zw, height: zh };
    const s = stageEl.getBoundingClientRect();
    glowCanvas.style.left = c.left - s.left + "px";
    glowCanvas.style.top = c.top - s.top + "px";
    glowCanvas.style.width = c.width + "px";
    glowCanvas.style.height = c.height + "px";
    // The blur is sized in the box's CSS pixels, so the grid follows the box.
    const [gw, gh] = glowComposer.layout(c.width, c.height, glowCtx);
    if (glowCanvas.width !== gw || glowCanvas.height !== gh) {
      glowCanvas.width = gw; glowCanvas.height = gh;   // clears it
      glowTick = 0;                                    // repaint next tick
    }
  }
  glowCanvas.hidden = !(ambientGlow && singleCore);
  refitFrameZoom();
};

// Sample a coarse grid from the presented framebuffer at ~10 Hz; the
// composer blends it over the last sample, blurs it and fades it to the
// ellipse, into the glow canvas.
let glowTick = 0;
let glowFresh = true; // first sample after enabling paints at full alpha

// "#rrggbb" -> the ABGR word the sampler compares against.
const glowPackHex = (c) => {
  const n = parseInt(String(c).replace("#", ""), 16) || 0;
  return (0xff000000 | ((n & 0xff) << 16) | (n & 0xff00) | ((n >> 16) & 0xff)) >>> 0;
};

const updateGlow = () => {
  if (glowCanvas.hidden || !currentRomName) return;
  if (typeof Module === "undefined" || !Module._wasm_glow_sample) return;
  if (glowTick++ % 6 !== 0) return;
  // The core samples (it owns the LUT and the SGB border) and touches only
  // the cells asked for. See wasm_glow_sample for what is not sampled.
  const pal = gbMonoPanel && !sgbActive() ? gbPaletteColors() : null;
  const remap = !!(pal && pal.length === 4);
  const ptr = Module._wasm_glow_sample(
    GLOW_SAMPLE_W, GLOW_SAMPLE_H, remap ? 1 : 0,
    remap ? glowPackHex(pal[0]) : 0, remap ? glowPackHex(pal[1]) : 0,
    remap ? glowPackHex(pal[2]) : 0, remap ? glowPackHex(pal[3]) : 0);
  if (!ptr) return;
  glowComposer.compose(
    new Uint8Array(Module.memory.buffer, ptr, GLOW_SAMPLE_W * GLOW_SAMPLE_H * 4),
    glowCtx, glowFresh);
  glowFresh = false;
};

// --- WebGL2 game presentation (web/glpresent.js, shared with the embed) ---
// Link / rollback modes keep their own 2D-canvas blit path.
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
    grid: upscaleFilter === "grid",
    subpixel: upscaleFilter === "rgb",
    filter: upscaleFilter,
  });
};

const saveVideoSettings = () => {
  if (db) dbPut("video", { integerScale, lcdResponse, ambientGlow, upscaleFilter });
};

const applyLcdResponse = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_lcd_response) {
    Module._wasm_set_lcd_response(lcdResponse ? 1 : 0);
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
    // "xbrz" was removed; the nearest remaining smoother is xBR.
    if (upscaleFilter === "xbrz") upscaleFilter = "xbr";
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

// --- Frame zoom ---
// Pinch the picture to zoom it: two fingers on a touch screen, a trackpad
// pinch on desktop (Chromium and Firefox send that as ctrl+wheel, Safari as
// gesture events). While zoomed, one finger or a two-finger scroll pans, and
// a double tap (or double click) puts it back. CSS `scale` and `translate`
// on #canvas, so nothing about the emulator changes; `transform` stays free
// for the rumble shake, which composes on top. The stage clips: the picture
// may spread over the letterbox but never leaves a gap it could fill. A zoom
// belongs to the game on screen, so leaving or switching games drops it.
const ZOOM_MAX = 6;
var zoomS = 1, zoomX = 0, zoomY = 0;
var zoomRom = null;

// The picture's unzoomed centre and size, and the stage box it may fill,
// in client px. offset* is the layout box, which no transform touches.
function frameZoomBox() {
  const s = stageEl.getBoundingClientRect();
  return {
    cx: s.left + stageEl.clientLeft + canvasEl.offsetLeft + canvasEl.offsetWidth / 2,
    cy: s.top + stageEl.clientTop + canvasEl.offsetTop + canvasEl.offsetHeight / 2,
    w: canvasEl.offsetWidth, h: canvasEl.offsetHeight,
    l: s.left, t: s.top, r: s.right, b: s.bottom,
  };
}

// One axis of the pan limit: a picture narrower than the stage stays inside
// it, a wider one keeps covering it.
const zoomClampAxis = (t, c, half, lo, hi) => {
  const a = lo - c + half, b = hi - c - half;
  return Math.min(Math.max(t, Math.min(a, b)), Math.max(a, b));
};

function setFrameZoom(s, x, y, box = null) {
  s = Math.min(ZOOM_MAX, Math.max(1, s));
  if (s < 1.01) {
    s = 1; x = 0; y = 0;   // fully out is home, not a nudge off-centre
  } else {
    const b = box || frameZoomBox();
    x = zoomClampAxis(x, b.cx, (b.w * s) / 2, b.l, b.r);
    y = zoomClampAxis(y, b.cy, (b.h * s) / 2, b.t, b.b);
  }
  zoomS = s; zoomX = x; zoomY = y;
  const on = s > 1;
  canvasEl.style.scale = on ? String(s) : "";
  canvasEl.style.translate = on ? `${x}px ${y}px` : "";
  document.body.classList.toggle("frame-zoomed", on);
}

// Zoom to `s` keeping the picture point under client (px, py) where it is.
const zoomFrameAt = (s, px, py) => {
  const b = frameZoomBox();
  const k = Math.min(ZOOM_MAX, Math.max(1, s)) / zoomS;
  zoomRom = currentRomName;
  setFrameZoom(zoomS * k, px - b.cx - k * (px - b.cx - zoomX),
               py - b.cy - k * (py - b.cy - zoomY), b);
};

// Glide home (double tap): the one zoom change that is not under a finger.
const resetFrameZoom = () => {
  if (zoomS === 1) return;
  canvasEl.classList.add("zoom-ease");
  setTimeout(() => canvasEl.classList.remove("zoom-ease"), 250);
  setFrameZoom(1, 0, 0);
};

// updateCanvasScaling's last word: the stage changed under the zoom, so
// re-clamp it, or drop it once its game is no longer the one on screen.
function refitFrameZoom() {
  if (zoomS === 1) return;
  const live = document.body.classList.contains("running") &&
    !!currentRomName && currentRomName === zoomRom && !linkMode && !rollbackMode;
  if (live) setFrameZoom(zoomS, zoomX, zoomY);
  else setFrameZoom(1, 0, 0);
}

const frameZoomable = () =>
  document.body.classList.contains("running") && !!currentRomName &&
  !linkMode && !rollbackMode && !anyModalOpen();

// The picture or the stage around it, never a control drawn over them. On
// phones in landscape the touch overlay's layout boxes (#main-controls, #lr)
// span the picture, so a press on one of those, between the buttons and
// inside the stage, is a press on the picture.
const ZOOM_NOT_SURFACE = "#dpad, #joystick, #ab, #select-start, .pad-btn, [data-inputs]";
const onFrameZoomSurface = (/** @type {any} */ t, x, y) => {
  if (t === canvasEl || t === stageEl) return true;
  if (!t || typeof t.closest !== "function" || !t.closest("#controls") ||
      t.closest(ZOOM_NOT_SURFACE)) return false;
  const s = stageEl.getBoundingClientRect();
  return x >= s.left && x < s.right && y >= s.top && y < s.bottom;
};

{
  const ptrs = new Map();   // touch pointerId -> {x, y}
  let from = null;          // the gesture so far, rebased on every finger change
  const ZOOM_TAP_MAX_MS = 250, ZOOM_DBLTAP_MS = 300, ZOOM_TAP_SLOP = 12;
  let tapDown = null;       // the lone finger that may yet be a tap
  let lastTap = null;       // the previous tap's release, for the double

  // Fingers come and go mid-gesture; each change starts afresh from the
  // current zoom, so the picture never jumps.
  const rebase = () => {
    const p = [...ptrs.values()];
    from = !p.length ? null : {
      box: frameZoomBox(), s: zoomS, x: zoomX, y: zoomY,
      mx: p.length > 1 ? (p[0].x + p[1].x) / 2 : p[0].x,
      my: p.length > 1 ? (p[0].y + p[1].y) / 2 : p[0].y,
      d: p.length > 1 ? Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y) || 1 : 0,
    };
  };

  // On the document: the touch overlay sits over the stage, not inside it.
  document.addEventListener("pointerdown", (e) => {
    if (e.pointerType !== "touch" || !frameZoomable() ||
        !onFrameZoomSurface(e.target, e.clientX, e.clientY)) return;
    ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY });
    zoomRom = currentRomName;
    rebase();
    tapDown = ptrs.size === 1 ? { ts: performance.now(), x: e.clientX, y: e.clientY } : null;
  });

  document.addEventListener("pointermove", (e) => {
    const p = ptrs.get(e.pointerId);
    if (!p || !from) return;
    p.x = e.clientX; p.y = e.clientY;
    if (tapDown && Math.hypot(p.x - tapDown.x, p.y - tapDown.y) > ZOOM_TAP_SLOP) tapDown = null;
    const f = from;
    const pts = [...ptrs.values()];
    if (pts.length > 1) {
      const mx = (pts[0].x + pts[1].x) / 2, my = (pts[0].y + pts[1].y) / 2;
      const d = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
      const s = Math.min(ZOOM_MAX, Math.max(1, (f.s * d) / f.d));
      const k = s / f.s;
      setFrameZoom(s, mx - f.box.cx - k * (f.mx - f.box.cx - f.x),
                   my - f.box.cy - k * (f.my - f.box.cy - f.y), f.box);
    } else if (f.s > 1) {
      setFrameZoom(f.s, f.x + p.x - f.mx, f.y + p.y - f.my, f.box);
    }
  });

  const lift = (/** @type {PointerEvent} */ e) => {
    if (!ptrs.delete(e.pointerId)) return;
    rebase();
    if (ptrs.size || !tapDown) { tapDown = null; return; }
    const now = performance.now();
    const tap = e.type === "pointerup" && now - tapDown.ts <= ZOOM_TAP_MAX_MS;
    if (tap && lastTap && now - lastTap.ts <= ZOOM_DBLTAP_MS &&
        Math.hypot(lastTap.x - tapDown.x, lastTap.y - tapDown.y) <= 2 * ZOOM_TAP_SLOP) {
      lastTap = null;
      resetFrameZoom();
    } else {
      lastTap = tap ? { ts: now, x: tapDown.x, y: tapDown.y } : null;
    }
    tapDown = null;
  };
  document.addEventListener("pointerup", lift);
  document.addEventListener("pointercancel", lift);

  canvasEl.addEventListener("dblclick", resetFrameZoom);

  // Trackpad pinch arrives as ctrl+wheel; a plain scroll pans a zoomed picture.
  stageEl.addEventListener("wheel", (e) => {
    if (!frameZoomable() || !onFrameZoomSurface(e.target, e.clientX, e.clientY)) return;
    const px = e.deltaMode === 1 ? 16 : 1;   // line-mode wheels count lines
    if (e.ctrlKey) {
      e.preventDefault();   // else the browser zooms the whole page
      const dy = Math.max(-50, Math.min(50, e.deltaY * px));
      zoomFrameAt(zoomS * Math.exp(-dy * 0.01), e.clientX, e.clientY);
    } else if (zoomS > 1) {
      e.preventDefault();
      setFrameZoom(zoomS, zoomX - e.deltaX * px, zoomY - e.deltaY * px);
    }
  }, { passive: false });

  // Safari's trackpad pinch. iOS sends these for a touch pinch too, where the
  // pointer path above already has it: there they only cancel page zoom.
  let gestureFrom = 0;
  document.addEventListener("gesturestart", (e) => {
    const g = /** @type {any} */ (e);
    if (!frameZoomable() || !onFrameZoomSurface(e.target, g.clientX, g.clientY)) return;
    e.preventDefault();
    gestureFrom = ptrs.size ? 0 : zoomS;
  });
  document.addEventListener("gesturechange", (e) => {
    if (!gestureFrom) return;
    e.preventDefault();
    const g = /** @type {any} */ (e);
    zoomFrameAt(gestureFrom * g.scale, g.clientX, g.clientY);
  });
  document.addEventListener("gestureend", (e) => {
    if (!gestureFrom) return;
    e.preventDefault();
    gestureFrom = 0;
  });
}

// --- Idle cursor ---
// A mouse left resting on the picture hides after 3 s and comes back on the
// next move or press. "On the picture" is a hit test, so it is the frame's
// exact on-screen box (zoom included, clipped by the stage) minus anything
// drawn over it: letterbox, bars, menus and toasts keep the pointer.
const CURSOR_IDLE_MS = 3000;
{
  let x = 0, y = 0;
  let timer = null;
  const idle = () => {
    timer = null;
    document.body.classList.toggle("cursor-idle",
      document.body.classList.contains("running") &&
      document.elementFromPoint(x, y) === canvasEl);
  };
  const active = (/** @type {PointerEvent} */ e) => {
    if (e.pointerType !== "mouse") return;
    x = e.clientX; y = e.clientY;
    document.body.classList.remove("cursor-idle");
    clearTimeout(timer);
    timer = setTimeout(idle, CURSOR_IDLE_MS);
  };
  document.addEventListener("pointermove", active);
  document.addEventListener("pointerdown", active);
}

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
  // The home screen keeps a loaded game paused behind it: there Enter, Space
  // and the arrows are the page's (a focused tile), not the hidden core's.
  // A release still goes through, so a key held across Main Menu lets go.
  if (down && !document.body.classList.contains("running")) return;
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

// --- Buttons in landscape: "outline" | "bold" | "solid" ---
// Phones held sideways draw the pads over the game (styles.css):
// body.bold-controls and body.opaque-controls pick the look.
let landscapeButtons = "bold";
const landscapeButtonsChips = Array.from(/** @type {NodeListOf<HTMLElement>} */ (
  document.querySelectorAll("#landscape-buttons-picker .choice-chip")));

const applyLandscapeButtons = (look) => {
  landscapeButtons = look === "outline" || look === "solid" ? look : "bold";
  document.body.classList.toggle("bold-controls", landscapeButtons === "bold");
  document.body.classList.toggle("opaque-controls", landscapeButtons === "solid");
  syncChipGroup(landscapeButtonsChips, landscapeButtons);
};

landscapeButtonsChips.forEach((chip) =>
  chip.addEventListener("click", async () => {
    applyLandscapeButtons(chip.dataset.value);
    await dbPut("landscape-buttons", landscapeButtons);
  })
);

const loadLandscapeButtonsFromStorage = async () => {
  let look = await dbGet("landscape-buttons");
  // Before Bold this was the yes/no "Opaque controls in landscape".
  if (look == null && (await dbGet("opaque-controls"))) look = "solid";
  applyLandscapeButtons(look);
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

// --- Opening a game from the library ---
// "library-open": "resume" (a tile goes back into the game's session, where
// one still matches its save) or "save" (it boots from the in-game save and
// offers the session). openLibraryGame reads it.
let libraryOpen = "resume";
const libraryOpenChips = Array.from(/** @type {NodeListOf<HTMLElement>} */ (
  document.querySelectorAll("#library-open-picker .choice-chip")));

const applyLibraryOpen = (v) => {
  libraryOpen = v === "save" ? "save" : "resume";
  syncChipGroup(libraryOpenChips, libraryOpen);
};

libraryOpenChips.forEach((chip) =>
  chip.addEventListener("click", async () => {
    applyLibraryOpen(chip.dataset.value);
    await dbPut("library-open", libraryOpen);
  })
);

const loadLibraryOpenFromStorage = async () => {
  applyLibraryOpen(await dbGet("library-open"));
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
// values a monochrome framebuffer holds. Also the seed for a custom palette.
const GB_HW_SHADES = ["#fff7d6", "#ffad73", "#ef6b6b", "#7b3a5a"];

// One four-shade ramp per app theme, lightest to darkest. The rules (theme
// colour verbatim, monotonic darkening, a minimum contrast per step, and a
// CIEDE2000 cap between adjacent shades because games dither shades 1 and 2
// against each other) are pinned by web/tests/gb-palette.test.mjs.
const GB_THEME_PALETTES = {
  amber:           ["#fff0d6", "#ffb04d", "#8f5312", "#1a1206"],
  black:           ["#fff0d6", "#ffb04d", "#7a4a0f", "#000000"],
  light:           ["#f3f4f8", "#d88a1f", "#9c5400", "#1d2433"],
  indigo:          ["#cdc7f0", "#7f6ae7", "#55497f", "#0d0b17"],
  fuchsia:         ["#f0ccd8", "#e8739a", "#7e4560", "#170a0f"],
  glacier:         ["#ccd9f0", "#769be5", "#3c4a6b", "#0b0e16"],
  // Shade 0 must be very pale to separate from the shell green.
  kiwi:            ["#effbea", "#6ee126", "#2d7a1f", "#0c170b"],
  // The pea-green --accent is deliberately absent (the CIEDE2000 rule).
  dmg:             ["#eaf3de", "#b4aca9", "#6f6a6d", "#262828"],
  "atomic-purple": ["#e7cbf0", "#c36ee7", "#6a3d80", "#120b16"],
  daiei:           ["#f2d2b0", "#eb7c33", "#8c3d18", "#160f0b"],
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
  "keybindings", "large-controls", "opaque-controls", "landscape-buttons",
  "control-style", "joystick-mode", "hide-touch-on-gamepad",
  "runahead", "gb-palette", "input-display", "library-open",
];

const resetAllSettings = async () => {
  for (const k of SETTINGS_KEYS) await dbDelete(k);
  try { localStorage.removeItem(UPDATE_CHECK_KEY); } catch (e) {}

  gbaBiosMode = 0; gbaRunBios = true; gbRumble = true;
  rewindOn = true;
  syncSystemSettingsUI();   // also re-applies the rewind-off body class
  applySystemSettings();

  volume = 100; muted = false;
  syncVolumeUI();
  applyAudioSilent();
  if (typeof updateGain === "function") updateGain();
  pitchCorrectFF = true;
  if (pcffToggle) pcffToggle.checked = true;
  applyPitchCorrectFF();
  mp2kHle = false;
  if (mp2kHleToggle) mp2kHleToggle.checked = false;
  applyMp2kHle();
  fifoInterp = true;
  if (fifoInterpToggle) fifoInterpToggle.checked = true;
  applyFifoInterp();
  audioLowpass = true;
  if (lowpassToggle) lowpassToggle.checked = true;
  applyAudioLowpass();
  playInSilent = true;
  if (playInSilentToggle) playInSilentToggle.checked = true;
  applyAudioSession();

  colorCorrect = true;
  ccToggle.checked = colorCorrect;
  applyColorCorrect();

  integerScale = false; lcdResponse = false; ambientGlow = false;
  upscaleFilter = "none";
  integerScaleToggle.checked = false;
  lcdResponseToggle.checked = false;
  ambientGlowToggle.checked = false;
  upscaleFilterSelect.value = "none";
  glowFresh = true;
  applyLcdResponse();
  updateCanvasScaling();

  kbSelection = -1;
  applyKeybindings(PRESET_DEFAULT);
  kbPreset.value = "default";
  renderKbBindings();

  applyLargeControls(false);
  applyLandscapeButtons("bold");
  applyControlStyle("dpad");
  applyJoystickMode("fixed");
  applyHideTouchOnGamepad(true);
  applyInputDisplay(false);
  applyLibraryOpen("resume");

  applyRunahead(0);

  gbPaletteMode = "default";
  gbPaletteCustom = GB_HW_SHADES.slice();
  applyGbPalette();

  sgbEnable = false;
  sgbBorder = true;
  applySystemSettings();
  syncSystemSettingsUI();

  // Synced: turning it off here turns it off on the account's other devices.
  await setSaveHookUrl("");
  setSaveHookStatus("");

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
// The load/close token. A tile tap, a file open, a reset, an import and a
// close each take the next number synchronously, and every continuation of
// that flow (launchRom, handleRomFile, loadRom, unloadGame) returns after an
// await once a later one has taken it: two taps in a row boot the second
// game, never one game's ROM under the other's name, and a close cannot
// finish on a game a newer load swapped in under it.
let loadGen = 0;
// The game whose save loadRom has read and not yet booted. Until the boot it
// is not named, but a Drive pull must leave its save alone all the same: the
// game will run on what was read, and its first flush would write that back.
let loadingName = null;
const nextLoadGen = () => {
  loadingName = null;
  return ++loadGen;
};
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

// `opts.rom`: the ROM's bytes, written to `romName` only at the boot (a caller
// that writes it itself writes over the file the named game was built from,
// before this load has won). `opts.gen`: the caller's load token, when it took
// one at the tap; otherwise this call takes one.
const loadRom = async (romName, originalName, opts = {}) => {
  const gen = opts.gen ?? nextLoadGen();
  // An online session holds the core: running (netMode, rollbackMode), or a
  // rollback session set up and waiting for the peer (netHoldsCore), whose
  // cores have replaced the solo one.
  const sessionHoldsCore = () => netActive() || rollbackMode ||
    (typeof netHoldsCore === "function" && netHoldsCore());
  // A later load or close has taken over, or a link session has started and
  // owns the core.
  const abandoned = () => gen !== loadGen || linkMode || sessionHoldsCore();
  // A capture spanning a ROM switch would splice two games.
  if (typeof abortRetroClip === "function") abortRetroClip();
  if (typeof stopClipRecording === "function") stopClipRecording();
  if (linkMode) await exitLinkMode();
  // Rollback is a link session too, though netMode is false in it: its
  // teardown persists the session's battery under currentOriginalName, so it
  // runs while that still names the session's game - before this load boots
  // anything, since it also puts the session's core back as the solo one.
  if (typeof netShutdown === "function" && sessionHoldsCore()) await netShutdown();
  if (abandoned()) return;
  if (currentRomName && currentOriginalName) {
    clearPlaying();
    await persistAutoState(); // where the outgoing game was left
    if (abandoned()) return;
    await storeLastFrame({ force: true }); // the outgoing game's picture
    if (abandoned()) return;
    await persistSave(currentRomName, currentOriginalName);
    if (abandoned()) return;
  }
  // The outgoing game stays named, running on its own rom.sav, until the
  // core is replaced below: every flush until then is still its own.
  const name = originalName || romName;
  loadingName = name;
  const save = await dbGet("save:" + name);
  if (abandoned()) {
    if (gen === loadGen) loadingName = null; // a link session, not a later load
    return;
  }
  // One synchronous run from here to the names: the ROM and its battery file
  // go down, the core is built on them, and only then is the game named. So
  // no flush, snapshot or picture ever pairs one game's name with another
  // game's core or battery.
  if (opts.rom) writeToFS(romName, opts.rom);
  installSave(romName, name, save);
  Module.ccall("initFromEmscripten", null, ["string"], [romName]);
  loadingName = null;
  currentRomName = romName;
  sessionHeldFor = null; // the held session was the outgoing game's
  currentOriginalName = name;
  applyAudioLowpass(); // the filter follows the machine: GBA in, GB out
  lastFrameSig = null; // a new game: the tick's skip must not carry over
  sessionMoved = true; // and no snapshot of it yet
  startCheckpointClock(name);
  // The session the home screen chose to go back into, put back in this same
  // synchronous run so no frame of the boot is ever drawn. Checked once more
  // against the battery just installed, as the offer's Resume checks it.
  if (opts.resume) {
    // `force`: an earlier moment chosen from the sheet, whose battery goes
    // back with it (resumeMoment kept the newer save aside first).
    if (!opts.resume.force && opts.resume.saveSig !== liveSaveSig()) {
      showToast("The game has saved since — starting from that save");
    } else if (!applyStateBytes(opts.resume.bytes)) {
      refuseState(opts.resume.bytes, { kind: "session" });
    }
  }
  // Again, for a capture started on the outgoing game during the awaits
  // above: it would run on into this one.
  if (typeof abortRetroClip === "function") abortRetroClip();
  if (typeof stopClipRecording === "function") stopClipRecording();
  // Before `paused` is reset: closing a scrubber restores the paused state
  // it captured, which must land on the old session's value.
  closeRewindScrubber();
  closeClipScrubber();
  // The same for the overlays that pause the game under them: a ROM dropped,
  // or a download that finished, while Report a Bug is open would otherwise
  // run behind it, and closing it later would write the old game's paused
  // state onto the new one. The Link Cable modal is dismissed (a session
  // still pairing is shut down, synchronously): it froze the old game only.
  closeReportModal();
  if (typeof netModalOpen === "function" && netModalOpen()) netDismissModal();
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
  // Before the class, not after: body.running hides #home, and a flight
  // measured from a display:none hero has nowhere to come from.
  flyBrand(true);
  document.body.classList.add("has-game", "running");
  setBrandP(1);
  takePendingFlight(); // a launch from the home screen lands on the screen
  playedThisVisit = true;
  await restoreCheats();  // fresh core: re-apply this game's saved cheats
  if (gen !== loadGen) return; // the next load re-applies all of this to its core
  applyPitchCorrectFF();  // fresh core: re-push the local audio preference
  applyAudioSilent();
  mp2kHleSessionOff = false; // the note-icon A/B belongs to the previous game
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

// The same list as src/dingbat/common/rom_exts.nim, which picks the core.
// .cgb/.sgb are Color-only and Super Game Boy carts some ROM sets name so;
// the core reads the mode from the header. Not .dmg: a macOS disk image.
const ROM_EXTS = [".gba", ".gb", ".gbc", ".cgb", ".sgb"];
const IMG_EXTS = [".png", ".jpg", ".jpeg", ".webp", ".gif"];

const extOf = (n) => {
  let i = n.lastIndexOf(".");
  return i < 0 ? "" : n.slice(i).toLowerCase();
};
const baseName = (n) => n.slice(n.lastIndexOf("/") + 1);
const systemOf = (name) => {
  let e = extOf(name);
  return e === ".gba" ? "GBA" : e === ".gbc" || e === ".cgb" ? "GBC" : "GB";
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

// One question about a file, asked before it is accepted; false drops it.
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

const askRomWarn = (title, text) =>
  new Promise((resolve) => {
    document.getElementById("rom-warn-title").textContent = title;
    document.getElementById("rom-warn-text").textContent = text;
    romWarnResolve = resolve;
    romWarnModal.classList.add("open");
    trapFocus(romWarnModal);
  });

const confirmSuspectRom = (fileName, ext) => {
  let system = ext === ".gba" ? "GBA"
    : ext === ".gbc" || ext === ".cgb" ? "Game Boy Color" : "Game Boy";
  return askRomWarn("File Check Failed",
    `"${fileName}" doesn't look like a valid ${system} ROM — it may be ` +
    `corrupt or not a game at all. Load it anyway?`);
};

document.getElementById("rom-warn-load").addEventListener("click", () => settleRomWarn(true));
document.getElementById("rom-warn-cancel").addEventListener("click", closeRomWarnModal);
document.getElementById("rom-warn-close").addEventListener("click", closeRomWarnModal);
romWarnModal.addEventListener("click", (e) => {
  if (e.target === romWarnModal) closeRomWarnModal();
});

// A dingbat export's map of path -> kind, from its info.json; null for any
// other zip (or an info.json that is not ours).
const exportKinds = async (zip) => {
  let e = zip.entries.find((x) => x.name === "info.json");
  if (!e) return null;
  try {
    let info = JSON.parse(new TextDecoder().decode(await zip.extract(e)));
    if (info?.app !== "dingbat" || !Array.isArray(info.files)) return null;
    return new Map(info.files.filter((f) => typeof f?.path === "string")
                             .map((f) => [f.path, f.kind]));
  } catch {
    return null;
  }
};

const handleZipFile = async (file) => {
  const gen = nextLoadGen(); // a later tap or open supersedes this one (loadGen)
  let zip;
  try {
    zip = await unzip(await file.arrayBuffer());
  } catch (e) {
    alert("Couldn't read that zip: " + e.message);
    return;
  }
  // One of our own exports says what each file is (exportPackage's
  // info.json): its box art is the file it calls box art, or there is none.
  // Guessing would make the library thumbnail or a printed photo the cover.
  let kinds = await exportKinds(zip);
  let ofKind = (k) => kinds && zip.entries.find((e) => kinds.get(e.name) === k);
  let romEntry = ofKind("rom") ||
    zip.entries.find((e) => usable(e) && ROM_EXTS.includes(extOf(e.name)));
  if (!romEntry) {
    alert("No .gba, .gb or .gbc ROM was found inside that zip.");
    return;
  }
  // Anyone else's zip: the largest embedded image is almost always the box art.
  let imgEntry = kinds ? ofKind("art") : zip.entries
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
  await ensureRuntimeReady(); // a zip dropped before the wasm runtime is up
  await addRecentRom(innerName, romBytes, art);
  // In the library either way; booted only if nothing was opened since.
  if (gen !== loadGen) return;
  loadRom("rom" + innerExt, innerName, { gen, rom: romBytes });
};

let handleRomFile = (file) => {
  let ext = extOf(file.name);
  if (ext === ".zip") return handleZipFile(file);
  if (!ROM_EXTS.includes(ext)) {
    alert("Unsupported file. Load a .gba, .gb, or .gbc ROM (or a .zip containing one).");
    return;
  }
  let romName = "rom" + ext;
  const gen = nextLoadGen(); // a later tap or open supersedes this one (loadGen)
  let reader = new FileReader();
  reader.addEventListener("load", async () => {
    let bytes = new Uint8Array(/** @type {ArrayBuffer} */ (reader.result));
    if (!looksLikeValidRom(bytes, ext) &&
        !(await confirmSuspectRom(file.name, ext))) return;
    await ensureRuntimeReady(); // a ROM picked/dropped before the runtime is up
    await addRecentRom(file.name, bytes);
    // In the library either way; booted only if nothing was opened since.
    if (gen !== loadGen) return;
    loadRom(romName, file.name, { gen, rom: bytes });
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

// Every "Add a game": the empty state's, the library head's, and the pill
// under a hero that is the whole library.
for (let id of ["home-load", "lib-add", "home-solo-add"]) {
  document.getElementById(id)?.addEventListener("click", openRomPicker);
}

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
  // A recording clip owns the machine, as for every other control; a file
  // check's prompt over its panel lost the focus trap when both closed
  // (bug_drop_during_clip_export_loses_focus).
  if (clipReplayActive) {
    if (e.dataTransfer.files?.length > 0) showToast("Finish or cancel the clip first");
    return;
  }
  if (e.dataTransfer.files?.length > 0) handleDroppedFile(e.dataTransfer.files[0]);
});

// The pause button's icon/title and body.paused for the player's pause choice.
const showPauseChoice = (on) => {
  pauseButton.classList.toggle("paused", on);
  pauseButton.classList.toggle("active", on);
  pauseButton.title = on ? "Resume" : "Pause";
  document.body.classList.toggle("paused", on);
};
const togglePause = (fromRemote) => {
  paused = !takePlayerPause();
  if (paused) storeLastFrame({ force: true }); // the paused picture is the library's
  showPauseChoice(paused);
  // Linked online, pause freezes both sides (a one-sided pause stalls the
  // peer at the prediction limit); relay unless it came from them.
  if (!fromRemote && rollbackMode && typeof window.rbSendPause === "function") {
    window.rbSendPause(paused);
  }
};
// The peer paused/resumed: match without echoing back. Not through a pause
// someone else holds: the home screen's lasts until Resume, and Report a Bug
// (still in the menu while linked) keeps the core frozen until it closes, so
// there the peer's choice becomes what closing it gives back.
window.applyRemotePause = (on) => {
  if (!document.body.classList.contains("running")) return;
  if (reportModal.classList.contains("open")) {
    reportWasPaused = !!on;
    showPauseChoice(!!on);
    return;
  }
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
    }, 8000, { game: true });
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
const currentSpeed = () =>
  fastForward ? "ffw" : speed2x ? "2x" : slowMotion ? "slow" : "normal";
// The setters clear each other, so the wanted one goes last.
const applySpeed = (mode) => {
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
  sessionMoved = true;
  if (Module._clearAudioBuffer) Module._clearAudioBuffer();
  drawGame();
};

// --- The console's own picture and sound, for everything exported ---
// Clips, recordings and screenshots carry the scene as the console makes
// it: the core's framebuffer at a whole-number scale (no LCD response,
// colour correction, DMG shades, SGB border or upscale filter) and its mix
// without the MP2K HLE, the FIFO smoothing or the channel mutes. Those are
// ways of playing, not part of the game. The HLE only shadows the game's
// own mixer (mp2k.nim), so switching it off for a replay changes nothing
// the replay emulates.
const NATIVE_SCALE = 4;
let nativeSmall = null;
let nativeBig = null;

// Paint the current frame into the export canvas, which is reused (a
// recorder's captureStream follows it) until the picture's size changes.
// Null with no core.
const nativeFrameCanvas = () => {
  if (typeof Module === "undefined" || !Module._wasm_native_fb_ptr) return null;
  const ptr = Module._wasm_native_fb_ptr();
  if (!ptr) return null;
  const [w, h] = gameRes();
  if (!nativeSmall || nativeSmall.width !== w || nativeSmall.height !== h) {
    nativeSmall = document.createElement("canvas");
    nativeSmall.width = w;
    nativeSmall.height = h;
    nativeBig = document.createElement("canvas");
    nativeBig.width = w * NATIVE_SCALE;
    nativeBig.height = h * NATIVE_SCALE;
  }
  nativeSmall.getContext("2d").putImageData(
    bgr555ToImageData(new Uint8Array(Module.memory.buffer, ptr, w * h * 2), 0, w, h), 0, 0);
  const ctx = nativeBig.getContext("2d");
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(nativeSmall, 0, 0, nativeBig.width, nativeBig.height);
  return nativeBig;
};

// The core's native mix while an export runs (and audible at all, whatever
// the volume); the player's own settings back after.
const setNativeAudio = (on) => {
  if (typeof Module === "undefined") return;
  if (on) {
    if (Module._wasm_set_mp2k_hle) Module._wasm_set_mp2k_hle(0);
    if (Module._wasm_set_fifo_interp) Module._wasm_set_fifo_interp(0);
    if (Module._wasm_set_channel_mutes) Module._wasm_set_channel_mutes(0);
    if (Module._wasm_set_audio_silent) Module._wasm_set_audio_silent(0);
  } else {
    // Another export still running keeps it (a Record across a clip).
    if (clipReplayActive || (recRecorder && recRecorder.state === "recording")) return;
    applyMp2kHle();
    applyFifoInterp();
    applyChannelMutes();
    applyAudioSilent();
  }
};

// --- Retroactive clip capture ---
// The wasm side keeps one state anchor per second plus a per-frame input
// log (clip_* in dingbat_wasm.nim). clip_begin rewinds to the anchor before
// the range and re-emulates to its first frame; clip_tick steps one frame of
// it. The replay is neither shown nor heard: a progress panel covers the
// screen (the canvas under it is hidden) while the frames and their sound
// go to an encoder.
//  - WebCodecs (clipEncode): as fast as the machine allows, each frame and
//    its samples straight from the core into an MP4 (clipmux.js). Nothing is
//    timed by a clock, so nothing can stutter, and the sound is the core's.
//  - Otherwise MediaRecorder over the canvas and a private audio tap (one
//    that never reaches the speakers), stepped at realtime by the tick.
var clipReplayActive = false;
// The WebCodecs path owns the core: the tick keeps off it.
var clipEncodeActive = false;
// Bumped per export, so a cancelled encode's tail never ends a later one.
var clipExportGen = 0;
// `paused` as the export found it: the replay unpauses the core to run, and
// the live game comes back to the player's choice, not to the replay's.
var clipExportWasPaused = false;
var clipRecorder = null;
var clipChunks = [];
var clipTotalFrames = 0;
const clipLastItem = document.getElementById("clip-last");

// Both consoles run 70224 dots a frame at 4 MiHz (GBA: 280896 at 16 MiHz).
const CLIP_FPS = 4194304 / 70224;
const CLIP_SRC_RATE = 32768;           // the core's sample rate
const CLIP_AUDIO_RATE = 48000;         // what AAC and Opus encoders take
const CLIP_VIDEO_BPS = 8_000_000;
const CLIP_AUDIO_BPS = 160_000;
const CLIP_KEY_EVERY = 120;            // frames between keyframes (~2 s)

const clipProgressModal = document.getElementById("clip-progress-modal");
const clipProgressLabel = document.getElementById("clip-progress-label");
const clipProgressBar = document.getElementById("clip-progress-bar");
const clipProgressFill = document.getElementById("clip-progress-fill");
const clipProgressPct = document.getElementById("clip-progress-pct");

const setClipProgress = (frac) => {
  const pct = Math.max(0, Math.min(100, Math.floor(frac * 100)));
  clipProgressFill.style.width = pct + "%";
  clipProgressPct.textContent = pct + "%";
  clipProgressBar.setAttribute("aria-valuenow", String(pct));
};

const clipMimeType = () => {
  if (typeof MediaRecorder === "undefined") return null;
  for (const m of ["video/webm;codecs=vp9,opus", "video/webm",
                   "video/mp4;codecs=avc1.64001F,mp4a.40.2", "video/mp4"]) {
    if (MediaRecorder.isTypeSupported(m)) return m;
  }
  return null;
};

const clipWebCodecs = () =>
  typeof VideoEncoder !== "undefined" && typeof AudioEncoder !== "undefined" &&
  typeof VideoFrame !== "undefined" && typeof AudioData !== "undefined" &&
  typeof OfflineAudioContext !== "undefined" && typeof ClipMux !== "undefined";

// The first H.264 profile and the first audio codec this browser encodes,
// or null (then the realtime recorder records the clip).
const clipCodecConfig = async (w, h) => {
  if (!clipWebCodecs()) return null;
  let video = null;
  // Level 5.1 covers the largest canvas (1440x960 at 60).
  for (const codec of ["avc1.640033", "avc1.4d0033", "avc1.420033"]) {
    const c = { codec, width: w, height: h, bitrate: CLIP_VIDEO_BPS, framerate: 60,
                avc: { format: /** @type {"avc"} */ ("avc") } };
    try {
      if ((await VideoEncoder.isConfigSupported(c)).supported) { video = c; break; }
    } catch {}
  }
  if (!video) return null;
  for (const [kind, codec] of [["aac", "mp4a.40.2"], ["opus", "opus"]]) {
    const c = { codec, sampleRate: CLIP_AUDIO_RATE, numberOfChannels: 2, bitrate: CLIP_AUDIO_BPS };
    try {
      if ((await AudioEncoder.isConfigSupported(c)).supported)
        return { video, audio: { kind: /** @type {"aac" | "opus"} */ (kind), config: c } };
    } catch {}
  }
  return null;
};

const clipBytes = (buf) =>
  buf instanceof ArrayBuffer ? new Uint8Array(buf.slice(0))
    : new Uint8Array(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));

const saveClipBlob = (blob, slug) => {
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

// Back to the live game, whichever path ran and however it ended. The core
// is already live again (clip_tick's last step, or clip_abort).
const endClipExport = () => {
  clipReplayActive = false;
  clipEncodeActive = false;
  paused = clipExportWasPaused;
  document.body.classList.remove("clip-replaying");
  if (clipProgressModal.classList.contains("open")) {
    clipProgressModal.classList.remove("open");
    releaseFocus(clipProgressModal);
  }
  setNativeAudio(false); // the player's mix back
  drawGame();            // the live picture back on the canvas
};

const finishRetroClip = (save) => {
  if (clipRecorder && clipRecorder.state !== "inactive") {
    if (save) clipRecorder.stop(); // onstop saves the blob
    else { clipRecorder.ondataavailable = null; clipRecorder.onstop = null;
           clipRecorder.stop(); clipChunks = []; clipRecorder = null;
           if (typeof window.releaseClipAudio === "function") window.releaseClipAudio(); }
  }
  endClipExport();
};

const abortRetroClip = () => {
  if (!clipReplayActive) return;
  if (typeof Module !== "undefined" && Module._clip_abort) Module._clip_abort();
  finishRetroClip(false);
};

// The realtime path: the tick steps clip_tick and pushAudio sends each
// frame's samples to the private tap. Returns false (nothing armed) on failure.
const startClipRecorder = (slug, mime) => {
  // The framebuffer holds the clip's first frame: paint it before
  // captureStream attaches, or the recorder opens on the live moment.
  const frame = nativeFrameCanvas();
  let stream;
  try {
    stream = frame.captureStream(60);
  } catch {
    showToast("Couldn't capture the game canvas");
    return false;
  }
  const audio = typeof window.acquireClipAudio === "function"
    ? window.acquireClipAudio(true) : null;
  if (audio) for (const t of audio.getAudioTracks()) stream.addTrack(t);
  clipChunks = [];
  try {
    clipRecorder = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: CLIP_VIDEO_BPS });
  } catch {
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
    saveClipBlob(blob, slug);
  };
  clipRecorder.start(500);
  return true;
};

// The whole clip's samples, resampled to the encoder's rate by the browser
// and encoded. `pcm` is the core's interleaved stereo, one array per frame.
const clipEncodeAudio = async (pcm, len, acfg) => {
  const frames = len / 2;
  const rate = acfg.config.sampleRate;
  const oc = new OfflineAudioContext(2, Math.max(1, Math.ceil((frames * rate) / CLIP_SRC_RATE)), rate);
  const src = oc.createBuffer(2, Math.max(1, frames), CLIP_SRC_RATE);
  const l0 = src.getChannelData(0), r0 = src.getChannelData(1);
  let o = 0;
  for (const p of pcm) {
    for (let k = 0; k < p.length; k += 2) { l0[o] = p[k]; r0[o] = p[k + 1]; o++; }
  }
  const node = oc.createBufferSource();
  node.buffer = src;
  node.connect(oc.destination);
  node.start();
  const out = await oc.startRendering();

  const chunks = [];
  let description = null;
  let failure = null;
  const aenc = new AudioEncoder({
    output: (c, meta) => {
      const data = new Uint8Array(c.byteLength);
      c.copyTo(data);
      chunks.push({ data, timestamp: c.timestamp, duration: c.duration ?? 0 });
      if (meta?.decoderConfig?.description) description = clipBytes(meta.decoderConfig.description);
    },
    error: (e) => { failure = e; },
  });
  try {
    aenc.configure(acfg.config);
    const l = out.getChannelData(0), r = out.getChannelData(1);
    const BLOCK = 4800;
    for (let s = 0; s < out.length; s += BLOCK) {
      if (failure) throw failure;
      const n = Math.min(BLOCK, out.length - s);
      const data = new Float32Array(n * 2);
      data.set(l.subarray(s, s + n), 0);
      data.set(r.subarray(s, s + n), n);
      const ad = new AudioData({ format: "f32-planar", sampleRate: rate, numberOfFrames: n,
                                 numberOfChannels: 2, timestamp: Math.round((s * 1e6) / rate), data });
      aenc.encode(ad);
      ad.close();
    }
    await aenc.flush();
    if (failure) throw failure;
  } finally {
    try { aenc.close(); } catch {}
  }
  return { codec: acfg.kind, sampleRate: rate, channels: 2, bitrate: CLIP_AUDIO_BPS,
           frames: out.length, description, chunks };
};

// The WebCodecs path, from clip_begin's armed replay to a saved file.
const clipEncode = async (gen, slug, mime) => {
  const first = nativeFrameCanvas();
  const w = first ? first.width : 0, h = first ? first.height : 0;
  const cfg = await clipCodecConfig(w, h);
  if (gen !== clipExportGen || !clipReplayActive) return; // cancelled while asking
  if (!cfg) {
    // No encoder here: the realtime recorder instead, from the same frame.
    clipEncodeActive = false;
    if (!mime || !startClipRecorder(slug, mime)) {
      if (!mime) showToast("Video recording isn't supported in this browser");
      abortRetroClip();
    }
    return;
  }

  const vChunks = [];
  let vDesc = null;
  let failure = null;
  const venc = new VideoEncoder({
    output: (c, meta) => {
      const data = new Uint8Array(c.byteLength);
      c.copyTo(data);
      vChunks.push({ data, timestamp: c.timestamp, duration: c.duration ?? 0, key: c.type === "key" });
      if (meta?.decoderConfig?.description) vDesc = clipBytes(meta.decoderConfig.description);
    },
    error: (e) => { failure = e; },
  });
  const pcm = [];
  let pcmLen = 0;
  const frameUs = 1e6 / CLIP_FPS;
  const total = clipTotalFrames;
  let done = 0;
  const live = () => gen === clipExportGen && clipReplayActive;
  try {
    venc.configure(cfg.video);
    // Frames in ~12 ms batches, then a yield: the panel repaints and Cancel
    // is heard. The encoder's queue is the brake on a fast core.
    for (let left = 0; left >= 0;) {
      if (!live()) return;            // Cancel or a game switch: already restored
      if (failure) throw failure;
      const t0 = performance.now();
      while (performance.now() - t0 < 12 && venc.encodeQueueSize < 8) {
        left = Module._clip_tick();
        if (left < 0) break;          // the live state is back
        const vf = new VideoFrame(nativeFrameCanvas(), { timestamp: Math.round(done * frameUs),
                                                         duration: Math.round(frameUs) });
        venc.encode(vf, { keyFrame: done % CLIP_KEY_EVERY === 0 });
        vf.close();
        const n = Module._getAudioBufferLen();
        if (n > 0) {
          pcm.push(new Float32Array(Module.memory.buffer, Module._getAudioBufferPtr(), n).slice());
          pcmLen += n;
        }
        Module._clearAudioBuffer();
        done++;
      }
      setClipProgress((0.9 * done) / Math.max(1, total));
      if (left >= 0) await new Promise((r) => setTimeout(r, 0));
    }
    await venc.flush();
    if (failure) throw failure;
    if (!live()) return;
    if (!vDesc) throw new Error("the encoder gave no avcC");
    const audio = pcmLen > 0 ? await clipEncodeAudio(pcm, pcmLen, cfg.audio) : null;
    if (!live()) return;
    setClipProgress(0.98);
    const bytes = ClipMux.mp4({
      video: { width: w, height: h, description: vDesc, chunks: vChunks },
      audio,
    });
    setClipProgress(1);
    saveClipBlob(new Blob([/** @type {Uint8Array<ArrayBuffer>} */ (bytes)], { type: "video/mp4" }), slug);
  } catch (e) {
    console.error("clip: encode failed", e);
    if (live()) showToast("Couldn't record the clip");
  } finally {
    try { venc.close(); } catch {}
    if (live()) {
      if (Module._clip_abort) Module._clip_abort();  // a no-op once the replay ran out
      endClipExport();
    }
  }
};

/**
 * Replay [startAgo, endAgo), both in frames before now, into a video file,
 * off screen, behind a progress panel.
 * @param {number} startAgo
 * @param {number} endAgo
 * @param {string} slug   filename infix, e.g. "clip10s"
 * @param {string} label  what is being recorded, e.g. "The last 10s"
 * @returns {boolean} true once the replay is armed and recording
 */
const startClipExport = (startAgo, endAgo, slug, label) => {
  if (clipReplayActive || !currentRomName || !speedControlsOk()) return false;
  const webcodecs = clipWebCodecs();
  const mime = clipMimeType();
  if (!webcodecs && !mime) { showToast("Video recording isn't supported in this browser"); return false; }
  const frames = Module._clip_begin ? Module._clip_begin(startAgo, endAgo) : 0;
  if (frames <= 0) { showToast("Not enough gameplay history yet"); return false; }
  const gen = ++clipExportGen;
  clipReplayActive = true;
  clipEncodeActive = webcodecs;
  clipTotalFrames = frames;
  clipExportWasPaused = takePlayerPause();
  paused = false; // the replay must run even if the game was paused
  setNativeAudio(true);
  document.body.classList.add("clip-replaying");
  clipProgressLabel.textContent = label;
  setClipProgress(0);
  clipProgressModal.classList.add("open");
  trapFocus(clipProgressModal);
  if (webcodecs) {
    clipEncode(gen, slug, mime);
  } else if (!startClipRecorder(slug, /** @type {string} */ (mime))) {
    abortRetroClip();
    return false;
  }
  return true;
};

document.getElementById("clip-progress-cancel").addEventListener("click", () => {
  if (clipReplayActive) {
    abortRetroClip();
    showToast("Clip cancelled");
  }
});

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
  direct: true,
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
        "It records off screen; you'll see how far along it is."
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
  // A build missing the scrub API from EXPORTED_FUNCTIONS (web/tests/wasm-exports.test.mjs).
  if (typeof Module === "undefined" || !Module._clip_scrub_generate) {
    console.error("clip: the scrub API is missing from this build " +
                  "(check EXPORTED_FUNCTIONS in src/dingbat_wasm.nims)");
    showToast("Clips aren't available in this build");
    return;
  }
  if (clipReplayActive) return;
  clipWasPaused = takePlayerPause();
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
  // Escape calls every closer blindly; a stale clipWasPaused would unpause a later pause.
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
                  end === 0 ? `The last ${seconds}s`
                            : `${seconds}s of gameplay`);
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

// Records the console's own picture and sound (nativeFrameCanvas,
// setNativeAudio): the HLE and the rest of the player's mix are off, and
// heard off, while it runs.
const startClipRecording = () => {
  if (recRecorder || clipReplayActive || !currentRomName) return;
  const mime = clipMimeType();
  if (!mime) { showToast("Video recording isn't supported in this browser"); return; }
  const frame = nativeFrameCanvas();
  let stream;
  try {
    stream = frame.captureStream(60);
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
  setNativeAudio(true);
  recRecorder.ondataavailable = (e) => { if (e.data && e.data.size) recChunks.push(e.data); };
  recRecorder.onstop = () => {
    if (typeof window.releaseClipAudio === "function") window.releaseClipAudio();
    setNativeAudio(false);
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
  applySpeed(kbSpeedBeforeHold);
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

  // The game keys act on a game in the game view only. The home screen keeps
  // a loaded game paused behind it (body.running off), and there they would
  // run, step, speed up, rewind, save, load or photograph a game nobody can
  // see (and Tab would stop moving focus).
  const gameShown = document.body.classList.contains("running");
  const gameInSession = !!currentRomName || linkMode || rollbackMode || netActive();
  const gameLoaded = gameInSession && gameShown;
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
          kbSpeedBeforeHold = fastForward ? "normal" : currentSpeed();
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
      if (e.shiftKey || !currentRomName || !gameShown || !speedControlsOk()) break;
      if (!playerPaused()) {
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
      if (e.shiftKey) break;
      // On the home screen too: the reload would drop the paused game's session.
      if (gameInSession && !gameShown) { handled = true; break; }
      if (!gameLoaded || !speedControlsOk()) break;
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
      if (e.shiftKey || !currentRomName || !gameShown || linkMode || rollbackMode) break;
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
  flyBrand(true);
  document.body.classList.add("has-game", "running", "rollback-mode");
  setBrandP(1);
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

// Persist both players' battery saves. Every call writes both; P1's goes to
// the save webhook when it changed (linkSaveSig, seeded at link start with
// the save the core boots on). P2's is the local second copy, never sent.
let linkSaveSig = null;
const persistLinkSaves = async () => {
  if (!linkRomEntry) return;
  for (let p = 0; p < 2; p++) {
    try {
      let data = FS.readFile(LINK_FS_SAVS[p]);
      if (data && data.length > 0) {
        await dbPut(linkSaveKey(linkRomEntry.name, p), new Uint8Array(data));
        let sig = p === 0 ? saveSignature(data) : linkSaveSig;
        if (sig !== linkSaveSig) {
          linkSaveSig = sig;
          postSaveToHook(linkRomEntry.name, data);
        }
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
  // What the cores boot on is not news to the save webhook.
  linkSaveSig = s1 ? saveSignature(s1) : null;
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
  flyBrand(true);
  document.body.classList.add("has-game", "running", "link-mode");
  setBrandP(1);
  updateCanvasScaling();
  await touchRecent(rom.name); // bytes are already stored — recency bump only
};

// --- Main Menu ---

const showMainMenu = () => {
  menuDropdown.hidden = true;
  if (!currentRomName && !linkMode) return;
  setFrameZoom(1, 0, 0);   // the flight home starts from the whole picture
  // Where the screen is, before it goes: the picture flies from here.
  const from = !linkMode && document.body.classList.contains("running")
    ? canvasEl.getBoundingClientRect() : null;
  stopClipRecording(); // don't keep recording a frozen frame from the menu
  releaseFlight();
  dismissGameToasts();
  paused = true;
  // The tile behind this menu shows the picture the player just left: the
  // grid renders now and again once the picture is stored.
  storeLastFrame({ force: true }).then(() => refreshHomeRecent());
  // What another device picks up: the session at this moment and the save it
  // was taken with, stored now (not at the next 5 s autosave) and queued for
  // Drive, so a Sync from this screen sends exactly this.
  if (currentRomName && currentOriginalName && !linkMode && !rollbackMode && !netActive()) {
    persistAutoState();
    persistSave(currentRomName, currentOriginalName);
  }
  document.body.classList.add("paused");
  document.body.classList.remove("running");
  drawPausedHero();
  refreshHomeRecent();
  updateCanvasScaling();
  if (from?.width) flyHome(from);
};

const resumeGame = () => {
  if (!currentRomName && !linkMode) return;
  // A choice of game like a tile tap: a load another tile started a moment
  // ago must not boot over the game the player just chose to keep playing.
  nextLoadGen();
  paused = false;
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  document.body.classList.remove("paused");
  document.body.classList.add("running");
  updateCanvasScaling();
};

document.getElementById("main-menu").addEventListener("click", showMainMenu);
document.getElementById("home-resume").addEventListener("click", resumeGame);


// --- The brand, twice ------------------------------------------------------
// The hero has one and the bar has another. They are not the same element
// moved between two parents, which is what this was at first: #home is the
// scroll container, so an element carried up out of it is clipped at its top
// edge, and a move can only ever be a jump at some threshold. The point here
// is the opposite - the hero's copy scrolls away under the bar natively,
// smoothly, for free, and the bar's copy comes up to meet it over the same
// distance.
//
// One number does it. --brand-p is 0 while the hero's brand is fully in view
// and 1 once it has gone completely under the bar; styles.css reads it for the
// bar copy's opacity and a few pixels of lift. The travel is the brand's own
// height, so the two cross over exactly as the hero one disappears.
//
// A loaded game pins it at 1: #home is display:none then, there is nothing to
// scroll and nothing to measure. The two crossings that are events rather than
// scrolls - a game opening, a game closing - still get the flight, played on
// the bar copy between the two resting places.
const brandEl = document.getElementById("home-brand");
const brandLogo = document.getElementById("home-logo");
const brandBarSlot = document.getElementById("brand-slot");
const barBrand = document.getElementById("bar-brand");
const barLogo = document.getElementById("bar-logo");
const barWord = document.getElementById("bar-word");
const BRAND_MOVE_MS = 380;
// The tail of the flight, over which the bar's copy hands the brand to the
// hero's. Short on purpose: any longer and the word is readable twice.
const BRAND_HANDOVER_MS = 130;

let brandAnim = null;
let brandP = 0;

const setBrandP = (p) => {
  brandP = p;
  brandBarSlot.style?.setProperty("--brand-p", String(p));
  // Only reachable once it is actually there to be clicked; an element at
  // opacity 0 still takes a tap.
  brandBarSlot.classList.toggle("on", p > 0.02);
  barBrand.tabIndex = p > 0.5 ? 0 : -1;
};

const brandProgress = () => {
  // Under a hero the page is headed by a game, so the bar has the brand from
  // the top. Otherwise the big brand is up and the bar's crosses over on
  // the scroll.
  if (document.body.classList.contains("has-game") ||
      document.body.classList.contains("home-card")) return 1;
  let s = homeScroller.getBoundingClientRect?.();
  let b = brandEl.getBoundingClientRect?.();
  if (!s || !b || !b.height) return brandP;
  // How much of the hero's brand is still below the top of the scroller.
  let below = b.bottom - s.top;
  let p = (b.height - below) / b.height;
  return p < 0 ? 0 : p > 1 ? 1 : p;
};

const syncBrand = () => setBrandP(brandProgress());

if (homeScroller.addEventListener) {
  homeScroller.addEventListener("scroll", syncBrand, { passive: true });
  window.addEventListener("resize", syncBrand);
}

// The two crossings that are not scrolls. `up` is a game opening (the hero is
// about to be hidden), `down` is one closing (it has just come back). Measured
// on the LOGOS rather than the brand boxes: the two layouts are different
// shapes - a column with a tagline down there, a wordmark beside its mark up
// here - and the logo is the one part that is the same thing in both, so
// anchoring the transform on it lands it exactly while the word sweeps along.
// Every animation this makes is tagged, and every flight begins by cancelling
// anything still tagged on any of the elements it touches. Tracking them in a
// variable was not enough: the variable is cleared when a flight settles, so a
// finished animation that is still FILLING is invisible to the next flight and
// goes on holding whatever property it ended on. Which is also why nothing
// here fills forwards - every one of these is `backwards`, so the moment it is
// done the element goes back to being described by the stylesheet and nothing
// else. A brand that cannot be shown is worse than a brand that does not fly.
const BRAND_FLY_ID = "brand-fly";
const BRAND_FLIERS = [barBrand, barLogo, barWord, brandEl];

const cancelFlight = () => {
  for (let el of BRAND_FLIERS) {
    el.getAnimations?.().forEach((a) => { if (a.id === BRAND_FLY_ID) a.cancel(); });
  }
  brandAnim = null;
};

// What flies is the LOGO, by itself.
//
// It has to be the logo, because it is the one part the two layouts have in
// common - everything else about them disagrees. But that means the word
// cannot come along: the bar's sits to the RIGHT of its logo where the hero's
// sits UNDER it, so any transform that lands the logo correctly carries the
// word off to one side. Fading it while it travelled did not fix that, it just
// made it a fainter thing sailing past the mark.
//
// So the word is not in the flight at all. It stays exactly where it is in the
// bar and dissolves on the spot, and the logo detaches and makes the trip
// alone. Nothing can overshoot, because nothing but the logo moves - and the
// logo is being aimed.
const flyBrand = (up) => {
  cancelFlight();
  if (!barBrand.animate) return;
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  let hero = brandLogo.getBoundingClientRect?.();
  let bar = barLogo.getBoundingClientRect?.();
  if (!hero || !bar || !hero.width || !bar.width) return;

  // Both rects are as they sit right now, so whatever the bar's own
  // --brand-p transform is doing is already accounted for in the delta.
  // transform-origin is the logo's own centre, which is what these numbers
  // are measured between.
  let overHero = "translate(" +
    ((hero.left + hero.width / 2) - (bar.left + bar.width / 2)) + "px, " +
    ((hero.top + hero.height / 2) - (bar.top + bar.height / 2)) + "px) scale(" +
    (hero.width / bar.width) + ")";

  /** @type {KeyframeAnimationOptions} */
  let glide = { duration: BRAND_MOVE_MS, easing: "cubic-bezier(.22,.61,.36,1)",
                fill: "backwards" };
  // Full length and LINEAR, so the offsets below mean what they say in wall
  // clock. A short animation would finish mid-flight, drop its effect and hand
  // the word straight back at full opacity - and nothing fills forwards here,
  // so the tail keyframe is what holds it. Both tails agree with what the
  // stylesheet says once the flight lets go.
  /** @type {KeyframeAnimationOptions} */
  let word = { duration: BRAND_MOVE_MS, easing: "linear", fill: "backwards" };
  let wordFrames = up
    ? [{ opacity: 0, offset: 0 }, { opacity: 0, offset: 0.55 },
       { opacity: 1, offset: 1 }]
    : [{ opacity: 1, offset: 0 }, { opacity: 0, offset: 0.4 },
       { opacity: 0, offset: 1 }];

  let made;
  if (up) {
    // A game opening. The hero's copy is hidden the same instant, so the logo
    // starts solid and exactly over it - fading in from nothing would leave a
    // moment with no brand anywhere.
    made = [
      barLogo.animate([{ transform: overHero }, { transform: "none" }], glide),
      barWord.animate(wordFrames, word),
    ];
  } else {
    // A game closing, and the harder direction: the hero's copy is back on
    // screen immediately, so simply flying a ghost down onto it left the real
    // one sitting there at full size the whole time, which is what read as
    // growing out of nowhere.
    //
    // The two hand over instead, and the handover is its OWN animation rather
    // than a pair of keyframe offsets. The `easing` option is iteration
    // easing: it remaps progress before the keyframes are read, so on a glide
    // this ease-out an offset of 0.66 arrives about a third of the way through
    // the wall clock, and a flick at the end became most of the flight.
    /** @type {KeyframeAnimationOptions} */
    let fade = { duration: BRAND_HANDOVER_MS,
                 delay: BRAND_MOVE_MS - BRAND_HANDOVER_MS,
                 easing: "linear", fill: "backwards" };
    made = [
      barLogo.animate([{ transform: "none" }, { transform: overHero }], glide),
      barWord.animate(wordFrames, word),
      // On the whole bar copy, so the flying logo goes with it. Held solid
      // from the start (backwards fill) against the stylesheet, which has
      // already put --brand-p at 0 by now.
      barBrand.animate([{ opacity: 1 }, { opacity: 0 }], fade),
      brandEl.animate(
        [{ opacity: 0, transform: "scale(.97)" },
         { opacity: 1, transform: "none" }], fade),
    ];
  }
  made.forEach((a) => { a.id = BRAND_FLY_ID; });
  brandAnim = made;

  // Settled the same way whether it lands or is cut short, and only by the
  // flight that is still the current one.
  let settle = () => {
    if (brandAnim !== made) return;
    brandAnim = null;
    syncBrand();
  };
  Promise.all(made.map((a) => a.finished)).then(settle, settle);
};

// In a game the brand is the way home, the same as Main Menu (desktop only in
// practice: phones drop the bar's brand while a game runs). On the home screen
// - with or without a paused game behind it - it goes back to the top.
const brandGoesHome = () => document.body.classList.contains("running");

// The label follows what a click will do, read at the moment it matters.
const labelBarBrand = () => {
  let label = brandGoesHome() ? "Main Menu" : "Back to the top";
  barBrand.title = label;
  barBrand.setAttribute("aria-label", label);
};
barBrand.addEventListener("pointerenter", labelBarBrand);
barBrand.addEventListener("focus", labelBarBrand);

barBrand.addEventListener("click", () => {
  if (brandGoesHome()) {
    showMainMenu();
    return;
  }
  let smooth = !matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (homeScroller.scrollTo) {
    homeScroller.scrollTo({ top: 0, behavior: smooth ? "smooth" : "auto" });
  } else {
    homeScroller.scrollTop = 0;
  }
});

// --- Paused-game card ---
// Pixels come from the wasm framebuffer: the canvas is a WebGL context
// without preserveDrawingBuffer, so reading it after pausing yields nothing.
const heroCard = document.getElementById("hero");
const heroCanvas = /** @type {HTMLCanvasElement} */ (document.getElementById("hero-canvas"));
const heroNameEl = document.getElementById("hero-name");

// body.home-card is set exactly while the card is up, and it is what the
// hamburger and the hero read to stand their own copies down. It is NOT the
// same question as body.has-game: a 2P, rollback or online session reaches
// the home screen with a game loaded and no card (two cores, no single
// framebuffer to draw), and there the menu items and the hero's Resume are
// the only way back and the only way to disconnect.
const setHeroShown = (on) => {
  heroCard.hidden = !on;
  if (!on) heroName = null;
  document.body.classList.toggle("home-card", on);
  syncHomeCurrent();
};

const heroGlow = /** @type {HTMLCanvasElement} */ (document.getElementById("hero-glow"));
const heroSys = document.getElementById("hero-sys");
const heroShot = document.getElementById("hero-shot");
const heroStateLabel = document.getElementById("hero-state");
const heroResumeLabel = document.getElementById("hero-resume-label");
const heroClose = document.getElementById("hero-close");
const heroPlay = document.getElementById("hero-play");
const heroPlaceholder = document.getElementById("hero-placeholder");

// What the closed hero's buttons act on: whether its game can go straight
// back into a session, and where its file is (as its tile would say).
let heroSession = false;
let heroFile = { driveOnly: false, missing: false };
// Which game's picture the canvas holds, so a close - the same game, the
// same frame - does not redraw it from the stored JPEG; and whether that
// picture is the moment its session goes back to (the paused screen, or
// the session's own picture), which a Resume can fly intact.
let heroDrawnFor = null;
let heroShowsSession = false;

// The blurred glow behind the frame is the same picture.
const drawHeroGlow = () => {
  heroGlow.width = heroCanvas.width;
  heroGlow.height = heroCanvas.height;
  heroGlow.getContext("2d")?.drawImage?.(heroCanvas, 0, 0);
};

// The words and buttons for a mode. The frame and the name are the callers'.
// A word or a button that changes under the player's eye (Close giving
// way to Play as the game closes, Resume to Play) fades in rather than
// popping. Nothing fills forwards; tagged like the flights.
const HERO_SWAP_ID = "hero-swap";
const heroSwapIn = (els) => {
  if (!canFly()) return;
  for (const el of els) {
    el.animate([{ opacity: 0 }, { opacity: 1 }],
      { duration: 260, easing: "ease-out" }).id = HERO_SWAP_ID;
  }
};

// The kicker over the hero's name. Paused and signed in, it says whether
// this moment has reached Drive - what to know before picking the game up on
// another device (Main Menu sends it; see showMainMenu). Closed, on a session
// another device left, it says which kind of device and when.
let heroFrom = null; // { dev, ts }: the closed hero's session, from elsewhere
const heroSyncWord = (game) => {
  const pending = ["save:" + game, autoStateKey(game), frameKey(game)]
    .some((k) => syncState.queueUp.includes(k));
  if (!pending) return "Synced";
  return syncStatus === "offline" || syncStatus === "paused" ? "Not synced yet" : "Syncing…";
};
const heroStateText = (mode) => {
  if (mode === "paused") {
    return driveLinked() && currentOriginalName
      ? "Paused · " + heroSyncWord(currentOriginalName) : "Paused";
  }
  if (!heroFrom) return "Last played";
  // "On", not "Last played on": the kicker is one line on a phone.
  const ago = Date.now() - heroFrom.ts < 60000 ? "just now" : fmtAgo(heroFrom.ts);
  return "On " + deviceWords(heroFrom.dev) + " · " + ago;
};
onSyncRendered = () => {
  if (heroCard.hidden || heroCard.dataset.mode !== "paused") return;
  heroStateLabel.textContent = heroStateText("paused");
};

const setHeroMode = (mode, name) => {
  // The same game staying up: what changes is animated.
  const same = !heroCard.hidden && heroName === name;
  const was = same ? {
    state: heroStateLabel.textContent,
    resume: heroResumeLabel.textContent,
    close: heroClose.hidden,
    restart: heroPlay.hidden,
  } : null;
  heroName = name;
  heroCard.dataset.mode = mode;
  const paused = mode === "paused";
  const resumable = paused || heroSession;
  heroStateLabel.textContent = heroStateText(mode);
  heroResumeLabel.textContent = resumable ? "Resume" : "Play";
  heroClose.hidden = !paused;
  heroPlay.hidden = paused || !heroSession;
  paintHeroLoad(name);
  if (was) {
    heroSwapIn([
      was.state !== heroStateLabel.textContent && heroStateLabel,
      was.resume !== heroResumeLabel.textContent && heroResumeLabel,
      was.close && !heroClose.hidden && heroClose,
      was.restart && !heroPlay.hidden && heroPlay,
    ].filter(Boolean));
  }
  const label = (resumable ? "Resume " : "Play ") + displayName(name);
  heroShot.title = label;
  heroShot.setAttribute("aria-label", label);
  heroNameEl.textContent = displayName(name);
  heroNameEl.title = name;
  const system = systemOf(name);
  heroSys.className = "sys-chip badge-" + system.toLowerCase();
  heroSys.textContent = system;
  setHeroShown(true);
};

const drawPausedHero = () => {
  // Single-core only: the link modes render to their own canvases.
  if (!currentRomName || linkMode || rollbackMode || netActive()) { setHeroShown(false); return; }
  if (typeof Module === "undefined" || !Module._wasm_fb_ptr) { setHeroShown(false); return; }
  const ptr = Module._wasm_fb_ptr();
  if (!ptr) { setHeroShown(false); return; }
  const [w, h] = gameRes(); // GBA 240x160, GB/GBC 160x144
  const heap = new Uint8Array(Module.memory.buffer, ptr, w * h * 4);
  heroCanvas.width = w;
  heroCanvas.height = h;
  const ctx = heroCanvas.getContext("2d");
  const img = ctx.createImageData(w, h);
  img.data.set(heap);
  // The wasm fb's alpha is not meaningful; force opaque.
  for (let i = 3; i < img.data.length; i += 4) img.data[i] = 255;
  ctx.putImageData(img, 0, 0);
  drawHeroGlow();
  heroPlaceholder.hidden = true;
  heroCard.classList.remove("no-picture");
  heroDrawnFor = currentOriginalName;
  heroShowsSession = true; // closing snapshots this very screen
  setHeroMode("paused", currentOriginalName);
};

// The last game played, with nothing loaded: the moment its session goes
// back to, where it has one with its picture; else its stored last screen
// (else its box art, else its system chip standing in, as on its tile);
// and what the hero can do with it. Renders are numbered so a slower one
// cannot land over a newer one.
let heroGen = 0;
const renderClosedHero = async (name, file, keys) => {
  const gen = ++heroGen;
  const local = !file.driveOnly;
  const session = local ? await resumeSessionFor(name) : null;
  const redraw = heroDrawnFor !== name;
  let bitmap = null;
  let ofSession = false;
  if (redraw) {
    bitmap = await sessionPicFor(name, session);
    ofSession = !!bitmap;
    let picture = null;
    if (!bitmap) {
      picture = keys.includes(frameKey(name)) ? await getRomFrame(name).catch(() => null) : null;
      if (!picture) picture = await getRomArt(name).catch(() => null);
    }
    if (picture && typeof createImageBitmap === "function") {
      try { bitmap = await createImageBitmap(picture); } catch {}
    }
  }
  if (gen !== heroGen || currentRomName || loadingName) return;
  if (redraw) {
    const ctx = heroCanvas.getContext("2d");
    if (bitmap) {
      heroCanvas.width = bitmap.width;
      heroCanvas.height = bitmap.height;
      ctx?.drawImage?.(bitmap, 0, 0);
    } else {
      const [w, h] = systemOf(name) === "GBA" ? [240, 160] : [160, 144];
      heroCanvas.width = w;
      heroCanvas.height = h;
      if (ctx) { ctx.fillStyle = "#000"; ctx.fillRect?.(0, 0, w, h); }
    }
    buildCart(name, heroPlaceholder);
    heroPlaceholder.hidden = !!bitmap;
    heroCard.classList.toggle("no-picture", !bitmap);
    heroCard.dataset.system = systemOf(name);
    drawHeroGlow();
    heroDrawnFor = name;
    heroShowsSession = ofSession;
  }
  // A game closed in place dims to the closed look by the canvas's own
  // filter transition.
  heroSession = !!session;
  heroFrom = session && session.elsewhere !== null ? { dev: session.elsewhere, ts: session.ts } : null;
  heroFile = file;
  setHeroMode("closed", name);
};

// Whenever the library renders: with nothing loaded, the hero is its most
// recent game - once a game has been played in this visit; a fresh visit
// opens on the brand. A loaded game is the paused card's (drawPausedHero),
// and a link or online session has no hero at all.
const refreshHero = (roms, localRoms, keys) => {
  if (currentRomName || loadingName) return;
  if (linkMode || rollbackMode || netActive() || !roms.length || !playedThisVisit) {
    setHeroShown(false);
    return;
  }
  let latest = roms[0];
  for (let r of roms) if ((r.ts || 0) > (latest.ts || 0)) latest = r;
  const driveOnly = !localRoms.has(latest.name);
  return renderClosedHero(latest.name,
    { driveOnly, missing: driveOnly && !driveHasRom(latest.name) }, keys);
};

// The picture and the labelled button do the same thing.
const heroPrimary = () => {
  if (heroCard.dataset.mode === "paused") { resumeFromHero(); return; }
  if (!heroName) return;
  if (crashGate(heroName)) return;
  if (heroSession) { launchRom(heroName, { resume: true, flyFrom: heroShot }); return; }
  openLibraryGame(heroName, { ...heroFile, flyFrom: heroShot, resume: true });
};
heroShot.addEventListener("click", heroPrimary);
document.getElementById("hero-resume").addEventListener("click", heroPrimary);
heroPlay.addEventListener("click", () => {
  if (heroName && heroCard.dataset.mode === "closed") {
    launchRom(heroName, { fresh: true, flyFrom: heroShot });
  }
});

// --- Flights -----------------------------------------------------------------
// The game's picture travels between the hero (or a tile) and the screen, so
// going home and coming back read as the same thing moving rather than one
// page replacing another. What flies is a copy - a canvas or a cloned tile
// picture - laid out at the DESTINATION'S size and transformed back to the
// start, so the one property animated is a composited transform. The real
// screen stays hidden (body.home-flying) and the game held (paused) until
// the copy lands on it, so no frame runs underneath.
//
// Two kinds of landing. A picture that IS the first frame the game will show
// (the paused game, or a session that goes back in) lands intact. One that is
// not - the closed hero's second button (Play, from the in-game save), or a
// game with no session to resume - darkens to black on the way and the
// screen powers on from black: the picture was the last one seen, not the
// one about to be.
//
// Nothing fills forwards (see "The brand, twice"): every element made here is
// removed when its animation ends, and every animation is tagged.
const FLIGHT_MS = 460;
const FLIGHT_EASE = "cubic-bezier(.2,.8,.2,1)";
const POWER_ON_MS = 700;
const FLIGHT_ID = "home-flight";

const canFly = () =>
  typeof document.body.animate === "function" &&
  !matchMedia("(prefers-reduced-motion: reduce)").matches;

// A copy of what is on screen: a canvas's pixels, or any other picture cloned.
const flierContent = (src) => {
  if (typeof HTMLCanvasElement !== "undefined" && src instanceof HTMLCanvasElement) {
    const c = document.createElement("canvas");
    c.width = src.width;
    c.height = src.height;
    c.getContext("2d")?.drawImage(src, 0, 0);
    return c;
  }
  return /** @type {Element} */ (src.cloneNode?.(true) ?? document.createElement("div"));
};

const flyPicture = (content, from, to, { dark = false, land = null, radius = 0 } = {}) =>
  new Promise((resolve) => {
    if (!canFly() || !from?.width || !to?.width) { resolve(false); return; }
    const el = document.createElement("div");
    el.className = "home-flier";
    el.style.left = to.left + "px";
    el.style.top = to.top + "px";
    el.style.width = to.width + "px";
    el.style.height = to.height + "px";
    el.style.borderRadius = radius + "px";
    el.appendChild(content);
    // The picture it lands as, where that is not the one it left as: laid
    // over it and faded in over the middle of the flight.
    let landing = null;
    if (land) {
      landing = document.createElement("canvas");
      landing.className = "home-flier-land";
      landing.width = land.width;
      landing.height = land.height;
      landing.getContext("2d")?.drawImage(land, 0, 0);
      el.appendChild(landing);
    }
    let shade = null;
    if (dark) {
      shade = document.createElement("div");
      shade.className = "home-flier-shade";
      el.appendChild(shade);
    }
    document.body.appendChild(el);
    const sx = from.width / to.width;
    const sy = from.height / to.height;
    const a = el.animate(
      [{ transform: `translate(${from.left - to.left}px, ${from.top - to.top}px) scale(${sx}, ${sy})` },
       { transform: "none" }],
      { duration: FLIGHT_MS, easing: FLIGHT_EASE, fill: "backwards" });
    a.id = FLIGHT_ID;
    // Linear and full length, so the offsets are wall clock (iteration easing
    // would remap them); its tail agrees with the stylesheet (opacity 1).
    if (shade) {
      shade.animate([{ opacity: 0 }, { opacity: 0, offset: 0.15 }, { opacity: 1, offset: 0.8 }, { opacity: 1 }],
        { duration: FLIGHT_MS, easing: "linear", fill: "backwards" }).id = FLIGHT_ID;
    }
    if (landing) {
      landing.animate([{ opacity: 0 }, { opacity: 0, offset: 0.1 }, { opacity: 1, offset: 0.6 }, { opacity: 1 }],
        { duration: FLIGHT_MS, easing: "linear", fill: "backwards" }).id = FLIGHT_ID;
    }
    const done = () => { el.remove(); resolve(true); };
    a.finished.then(done, done);
  });

// The screen coming on: black over the new game, fading as its first frames
// draw.
const powerOn = (rect) => {
  if (!canFly() || !rect?.width) return;
  const el = document.createElement("div");
  el.className = "home-poweron";
  el.style.left = rect.left + "px";
  el.style.top = rect.top + "px";
  el.style.width = rect.width + "px";
  el.style.height = rect.height + "px";
  document.body.appendChild(el);
  const a = el.animate([{ opacity: 1 }, { opacity: 1, offset: 0.15 }, { opacity: 0 }],
    { duration: POWER_ON_MS, easing: "ease-out", fill: "backwards" });
  a.id = FLIGHT_ID;
  const done = () => el.remove();
  a.finished.then(done, done);
};

// Holding the game for a flight, and letting it go. `flightHeld` is only ours:
// a pause the player makes meanwhile is theirs and is kept.
let flightHeld = false;
// Whether the PLAYER has the game paused. While a flight holds the game,
// `paused` is the flight's, not a choice: it is the pause button that says.
const playerPaused = () => (flightHeld ? pauseButton.classList.contains("paused") : paused);
// The same, for a surface that takes the run state over (an overlay that
// pauses and gives back, a toggle): it takes it from the flight too, so the
// flight's landing lets go of nothing it no longer holds
// (bug_overlay_in_flight_*, bug_pause_in_flight_lost, bug_link_modal_in_flight_*).
const takePlayerPause = () => {
  const p = playerPaused();
  flightHeld = false;
  return p;
};
const holdForFlight = () => {
  flightHeld = true;
  paused = true;
  document.body.classList.add("home-flying");
};
const releaseFlight = () => {
  document.body.classList.remove("home-flying");
  if (!flightHeld) return;
  flightHeld = false;
  if (document.body.classList.contains("running") &&
      !pauseButton.classList.contains("paused")) paused = false;
};

// Main Menu: the screen shrinks into the hero's frame while the page rises
// in under it.
const HOME_ARRIVE_MS = 900;
let homeArriveTimer = null;
const arriveHome = () => {
  clearTimeout(homeArriveTimer);
  homeScroller.classList.add("home-arriving");
  homeArriveTimer = setTimeout(() => homeScroller.classList.remove("home-arriving"), HOME_ARRIVE_MS);
};
const flyHome = (from) => {
  if (!canFly() || heroCard.hidden) return;
  homeScroller.scrollTop = 0; // the hero is where the game comes back to
  arriveHome();
  const to = heroShot.getBoundingClientRect();
  heroShot.style.visibility = "hidden";
  flyPicture(flierContent(heroCanvas), from, to, { radius: 14 })
    .then(() => { heroShot.style.visibility = ""; });
};

// The hero's Resume, for the game still in memory: the frame grows back into
// the screen, and play goes on when it gets there.
const resumeFromHero = () => {
  const from = canFly() && !heroCard.hidden ? heroShot.getBoundingClientRect() : null;
  const content = from ? flierContent(heroCanvas) : null;
  resumeGame();
  if (!from?.width || !content) return;
  holdForFlight();
  flyPicture(content, from, canvasEl.getBoundingClientRect()).then(releaseFlight);
};

// A launch from the home screen (the closed hero, a tile): armed when the
// launch knows whether it resumes, flown once the new game is on screen.
/** @type {{ name: string, from: DOMRect, content: Element, dark: boolean, land: ImageBitmap | null, at: number } | null} */
let pendingFlight = null;
const armFlight = (name, fromEl, dark, land = null) => {
  pendingFlight = null;
  if (!canFly() || !fromEl) return;
  const from = fromEl.getBoundingClientRect();
  if (!from.width) return;
  const src = fromEl === heroShot ? heroCanvas : fromEl;
  pendingFlight = { name, from, content: flierContent(src), dark, land, at: Date.now() };
};
// From loadRom, the moment the game is on screen: hold it, give the layout a
// frame to size the screen, then fly onto it.
const takePendingFlight = () => {
  const f = pendingFlight;
  pendingFlight = null;
  if (!f || f.name !== currentOriginalName || Date.now() - f.at > 5000) return;
  holdForFlight();
  // A flight that never gets to run (a tab put away mid-launch) must not
  // hold the game for good.
  const safety = setTimeout(releaseFlight, 2500);
  requestAnimationFrame(() => {
    if (f.name !== currentOriginalName) { clearTimeout(safety); releaseFlight(); return; }
    const to = canvasEl.getBoundingClientRect();
    flyPicture(f.content, f.from, to, { dark: f.dark, land: f.land }).then((flew) => {
      clearTimeout(safety);
      releaseFlight();
      if (flew && f.dark) powerOn(canvasEl.getBoundingClientRect());
    });
  });
};

// The card's ⋯ is the game's ⋯: the loaded game's own tile in the grid
// opens the same menu with the same entries, so there is one menu per game
// rather than a session menu and a library menu that disagree.
// currentOriginalName, NOT currentRomName: the library keys every game by the
// name it was added under, and currentRomName is the emulator filesystem's
// sanitised one. Address a game by the wrong one and every flag reads false -
// the menu decides the file is missing and offers to go and find a file the
// player is, demonstrably, playing.
const heroMore = document.getElementById("hero-more");
heroMore.addEventListener("click", () => {
  // Closed, the hero is a library game like any tile, and gets its file menu.
  const paused = heroCard.dataset.mode !== "closed";
  const name = paused ? currentOriginalName : heroName;
  if (!name) return;
  if (tileMenuFor === name) closeTileMenu();
  else openTileMenu(name, heroMore, null, null, paused);
});

// Close the paused game: flush its save once, detach it from every later
// flush path. The core stays frozen in wasm memory until the next loadRom
// re-inits over it. False when there is nothing to unload or a link session is up.
// A close takes the load token too (loadGen): a load in flight when the X is
// tapped is dropped, and a tap after it drops the close (false), whose game
// the load then persists as the outgoing one.
const unloadGame = async ({ flushSave = true, picture = true } = {}) => {
  if (!currentRomName || linkMode || rollbackMode || netActive()) return false;
  const gen = nextLoadGen();
  const romName = currentRomName;
  const originalName = currentOriginalName;
  clearPlaying();
  // The closing picture and session, taken while the name is still attached.
  if (flushSave) await persistAutoState();
  if (gen !== loadGen) return false;
  // A hand-off writes nothing of the copy it lets go, not even its picture:
  // the newer one is on its way.
  if (picture) await storeLastFrame({ force: true });
  if (gen !== loadGen) return false;
  // Flush, detach and drop the FS .sav with no await between them. The flush
  // goes first, while the name still says the core is this game's (it
  // flushes the core's unwritten RAM to the file only then) and reads the
  // file before its first await; once the names are null no flush path can
  // re-persist this game's save; the unlink keeps a later load from picking
  // up stale battery data.
  const flushed = flushSave ? persistSave(romName, originalName) : null;
  currentRomName = null;
  currentOriginalName = null;
  try { FS.unlink(stripExt(romName) + ".sav"); } catch {}
  // The cheat list belongs to the game that left; restoreCheats refills it.
  cheatList = [];
  renderCheatList();
  releaseFlight();
  paused = true; // keep the orphaned core frozen
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  document.body.classList.remove("has-game", "running", "paused", "gb-mode");
  // syncBrand, not a flat 0: if the library is still scrolled down, the
  // bar keeps its brand for that reason instead, and the flight is from
  // wherever the scroll says it should end up.
  syncBrand();
  if (brandP < 0.5) flyBrand(false);
  clearInputDisplay();   // no cart, no held buttons
  // No cart, no sensor: drop the camera and its button.
  stopWebcam();
  camNoticeShown = null;
  // The hero stays up: the render turns it from the paused game into the
  // last one played - the same game, in place, now with its session.
  refreshHomeRecent();
  updateCanvasScaling();
  await flushed; // callers go on to the stored records (Remove keeps this save)
  return true;
};

document.getElementById("hero-close").addEventListener("click", async () => {
  await unloadGame();
});

// --- Library pictures, in one go ------------------------------------------
// A one-time offer to picture every game that has none. Each game is booted
// in the core WITHOUT becoming the loaded game (currentRomName stays null,
// so no save, session, cheat or frame path can fire for it): its last
// session is restored where one exists and it is stepped one full render;
// with no session it runs through its boot toward a title screen, bounded
// in frames and in wall clock. The screen is then stored as the library
// frame. The core is left holding the last game, as after a close; the
// next loadRom re-inits over it. Signed in, Drive-only games can be
// included: ROM and battery save are fetched into memory, pictured, and
// never written to this device, so the library's order and local footprint
// are exactly what they were. The picture itself uploads like any other.
const THUMBS_OFFER_KEY = "thumbs_offered";
const THUMBS_RESUME_FRAMES = 2;   // after a state restore: one full render
const THUMBS_BOOT_FRAMES = 600;   // no session: through the logo to a title (10 s)
const THUMBS_BOOT_MS = 2500;      // ...or this much wall clock, whichever first
const THUMBS_CHUNK = 30;          // frames per task, so the page stays responsive

const thumbsModal = document.getElementById("thumbs-modal");
const thumbsOffer = document.getElementById("thumbs-offer");
const thumbsProgress = document.getElementById("thumbs-progress");
const thumbsStatus = document.getElementById("thumbs-status");
const thumbsBarFill = document.getElementById("thumbs-bar-fill");
const thumbsDriveRow = document.getElementById("thumbs-drive-row");
const thumbsDriveToggle = /** @type {HTMLInputElement} */ (document.getElementById("thumbs-drive-toggle"));
let thumbsRun = null; // { cancelled, done } while a batch runs

// Library entries without a picture. Drive-only ones only when asked.
// `known` is the caller's key list, where it already has one (the grid
// reads the same keys to decide which games are local).
const thumbsCandidates = async (includeDrive, known) => {
  let keys = new Set((known || await dbKeys()).filter((k) => typeof k === "string"));
  let out = [];
  for (let { name } of await getRecentMeta()) {
    if (keys.has(frameKey(name))) continue;
    let local = keys.has(romKey(name));
    if (local || includeDrive) out.push({ name, local });
  }
  return out;
};

const closeThumbsModal = () => {
  if (thumbsRun) thumbsRun.cancelled = true;
  thumbsModal.classList.remove("open");
  releaseFocus(thumbsModal);
};

// The box in its offer state. The Drive row shows only when it can mean
// something: signed in, with a Drive-only game still unpictured.
const openThumbsOffer = (cands) => {
  thumbsDriveRow.hidden = !driveLinked() || !cands.some((c) => !c.local);
  thumbsDriveToggle.checked = false;
  thumbsOffer.hidden = false;
  thumbsProgress.hidden = true;
  thumbsModal.classList.add("open");
  trapFocus(thumbsModal);
};

// Shown once per device, when there is something to picture and nothing is
// loaded (a batch re-inits the core the paused game sits in). the library head
// offers the same box any time (openThumbsRun).
const maybeOfferThumbnails = async () => {
  if (!db || currentRomName || linkMode || rollbackMode || netActive()) return false;
  if (await dbGet(THUMBS_OFFER_KEY)) return false;
  let cands = await thumbsCandidates(driveLinked());
  if (!cands.length) return false;
  await dbPut(THUMBS_OFFER_KEY, Date.now()); // one offer, whatever the answer
  openThumbsOffer(cands);
  return true;
};

// At boot, signed in, the first pull may still be bringing pictures down
// (they are Drive files): a game is only unpictured once it has had that
// chance. Waits for the pull, or `maxWait` if none comes (a stale token
// waits on a gesture; offline).
const THUMBS_PULL_WAIT_MS = 15000;
const offerThumbnailsAfterBoot = async (maxWait = THUMBS_PULL_WAIT_MS) => {
  if (GDRIVE_CLIENT_ID && syncState.connected) {
    await Promise.race([firstPullPromise, new Promise((r) => setTimeout(r, maxWait))]);
  }
  return maybeOfferThumbnails();
};

// The manual entry: the same box, from the library head. A loaded game
// (paused at home, say) has to close first: the batch takes the core.
// The library head's "Add pictures", which is shown only while there is
// something to picture (refreshHomeRecent).
const openThumbsRun = async () => {
  if (currentRomName || linkMode || rollbackMode || netActive()) {
    showToast("Close the running game first");
    return false;
  }
  let cands = await thumbsCandidates(driveLinked());
  if (!cands.length) {
    showToast("Every game already has a picture");
    return false;
  }
  openThumbsOffer(cands);
  return true;
};

const thumbsSetProgress = (i, total, name) => {
  thumbsStatus.textContent = name
    ? "Picturing " + (i + 1) + " of " + total + " — " + displayName(name)
    : "Done";
  thumbsBarFill.style.width = Math.round((i / Math.max(1, total)) * 100) + "%";
};

// Boot one game in the core and store its screen. Never touches the game's
// own records: the ROM and save go to scratch FS names, and the .sav is
// unlinked after, so no later load can pick it up.
const thumbsPictureOne = async (cand, run, remote) => {
  let name = cand.name;
  let bytes = null, save = null;
  if (cand.local) {
    bytes = await getRomBytes(name);
    save = await dbGet("save:" + name);
  } else {
    let f = remote.get(romKey(name));
    if (!f) return false;
    bytes = await driveDownload(f.id);
    save = await dbGet("save:" + name); // kept locally by Remove from device
    let sf = !save && remote.get("save:" + name);
    if (sf) save = await driveDownload(sf.id);
  }
  if (run.cancelled || currentRomName || !bytes || !bytes.length) return false;
  let ext = extOf(name);
  let romFile = "thumb" + ext;
  writeToFS(romFile, bytes);
  try { FS.unlink("thumb.sav"); } catch {}
  if (save && save.length) writeToFS("thumb.sav", save);
  Module.ccall("initFromEmscripten", null, ["string"], [romFile]);
  let frames = THUMBS_BOOT_FRAMES;
  let deadline = performance.now() + THUMBS_BOOT_MS;
  let auto = cand.local ? await dbGet(autoStateKey(name)) : null;
  if (auto?.bytes && applyStateBytes(auto.bytes)) {
    frames = THUMBS_RESUME_FRAMES;
    deadline = Infinity;
  }
  for (let done = 0; done < frames && performance.now() < deadline;) {
    if (run.cancelled || currentRomName) return false; // a launch took the core
    let n = Math.min(THUMBS_CHUNK, frames - done);
    for (let i = 0; i < n; i++) Module._loop_tick();
    done += n;
    if (Module._clearAudioBuffer) Module._clearAudioBuffer(); // nobody plays it
    await new Promise((r) => setTimeout(r, 0));
  }
  if (run.cancelled || currentRomName) return false;
  let [w, h] = ext === ".gba" ? [240, 160] : [160, 144];
  let ptr = Module._wasm_fb_ptr();
  if (!ptr) return false;
  let heap = new Uint8Array(Module.memory.buffer, ptr, w * h * 4).slice();
  let blob = await frameBlobFromFb(heap, w, h);
  try { FS.unlink("thumb.sav"); } catch {}
  if (!blob) return false;
  await dbPut(frameKey(name), blob);
  markUpload(frameKey(name));
  return true;
};

const runThumbnailBatch = async ({ includeDrive = false } = {}) => {
  if (thumbsRun) return 0;
  if (currentRomName || linkMode || rollbackMode || netActive()) {
    showToast("Close the running game first");
    return 0;
  }
  await ensureRuntimeReady();
  let remote = null;
  if (includeDrive) {
    if (!(await ensureDriveSignedIn())) includeDrive = false;
    else {
      try { remote = await driveListMap(); }
      catch (e) { showToast("Couldn't reach Drive — local games only"); includeDrive = false; }
    }
  }
  let cands = await thumbsCandidates(includeDrive);
  let run = { cancelled: false, done: 0 };
  thumbsRun = run;
  thumbsOffer.hidden = true;
  thumbsProgress.hidden = false;
  thumbsModal.classList.add("open");
  try {
    for (let i = 0; i < cands.length && !run.cancelled; i++) {
      thumbsSetProgress(i, cands.length, cands[i].name);
      try {
        if (await thumbsPictureOne(cands[i], run, remote)) {
          run.done++;
          refreshHomeRecent(); // the grid fills in as it goes
        }
      } catch (e) {
        console.warn("thumbnail failed for " + cands[i].name, e);
      }
    }
    thumbsSetProgress(cands.length, cands.length, null);
  } finally {
    thumbsRun = null;
    thumbsModal.classList.remove("open");
    releaseFocus(thumbsModal);
    refreshHomeRecent();
  }
  showToast(run.done === 0 ? "No pictures added"
    : run.done + (run.done === 1 ? " picture" : " pictures") + " added" +
      (run.cancelled ? " before stopping" : ""));
  return run.done;
};

const cancelThumbnailRun = () => { if (thumbsRun) thumbsRun.cancelled = true; };

document.getElementById("thumbs-go").addEventListener("click", () => {
  runThumbnailBatch({ includeDrive: !thumbsDriveRow.hidden && thumbsDriveToggle.checked });
});
document.getElementById("thumbs-not-now").addEventListener("click", closeThumbsModal);
document.getElementById("home-thumbs").addEventListener("click", () => { openThumbsRun(); });
document.getElementById("thumbs-close").addEventListener("click", closeThumbsModal);
document.getElementById("thumbs-stop").addEventListener("click", cancelThumbnailRun);
thumbsModal.addEventListener("click", (e) => {
  if (e.target === thumbsModal && !thumbsRun) closeThumbsModal();
});

// --- Screenshot ---
// The console's own picture (nativeFrameCanvas), read straight from the
// core: no render task to wait for, and a paused game is not stepped.
const takeScreenshot = () => {
  menuDropdown.hidden = true;
  if (!currentRomName) return;
  const frame = nativeFrameCanvas();
  if (!frame || typeof frame.toBlob !== "function") return;
  frame.toBlob((blob) => {
    if (!blob) return;
    let a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = (currentOriginalName || "dingbat").replace(/\.[^.]*$/, "") + ".png";
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
  }, "image/png");
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

// --- Mobile-landscape top bar: tap the picture ---
// On a phone held sideways the bar waits off-screen; a tap on the picture (or
// the letterbox round it) brings it down and another puts it away. It has to
// be a deliberate tap, not a thumb that slid off a button mid-game: one
// finger with no other on the screen, short and still, and a thumb's width
// clear of the drawn controls. While zoomed, a double tap resets the zoom, so
// there the bar waits out the double-tap window first.
const PHONE_LANDSCAPE = "(pointer: coarse) and (orientation: landscape) and (max-height: 500px)";
{
  const BAR_TAP_MAX_MS = 250, BAR_TAP_SLOP = 12, BAR_TAP_MARGIN = 20, BAR_DBLTAP_MS = 300;
  const touches = new Set();   // every touch down, on a control or not
  let cand = null;             // the lone touch that may yet be a tap
  let pending = 0;             // zoomed: the toggle waiting out a double tap

  const nearControl = (x, y) => {
    const m = BAR_TAP_MARGIN;
    for (const el of document.querySelectorAll("#controls .pad-btn")) {
      const r = el.getBoundingClientRect();
      if (r.width && x > r.left - m && x < r.right + m && y > r.top - m && y < r.bottom + m) {
        return true;
      }
    }
    return false;
  };
  // The stage's picture and letterbox, or the touch overlay's layout boxes
  // between its buttons (they span the picture). Never a control, the bar, a
  // menu, a toast or a modal.
  const onPicture = (/** @type {any} */ t) => {
    if (!t || typeof t.closest !== "function") return false;
    if (t.closest("#stage")) return !t.closest("#home");
    return !!t.closest("#controls") && !t.closest(ZOOM_NOT_SURFACE);
  };
  const toggleBar = () => document.body.classList.toggle("topbar-open");

  document.addEventListener("pointerdown", (e) => {
    if (e.pointerType !== "touch") return;
    touches.add(e.pointerId);
    cand = touches.size === 1 && document.body.classList.contains("running") &&
      matchMedia(PHONE_LANDSCAPE).matches && !anyModalOpen() &&
      onPicture(e.target) && !nearControl(e.clientX, e.clientY)
      ? { id: e.pointerId, ts: performance.now(), x: e.clientX, y: e.clientY }
      : null;
  });
  document.addEventListener("pointermove", (e) => {
    if (cand && e.pointerId === cand.id &&
        Math.hypot(e.clientX - cand.x, e.clientY - cand.y) > BAR_TAP_SLOP) cand = null;
  });
  const lift = (/** @type {PointerEvent} */ e) => {
    touches.delete(e.pointerId);
    if (!cand || cand.id !== e.pointerId) return;
    const c = cand;
    cand = null;
    if (e.type !== "pointerup" || performance.now() - c.ts > BAR_TAP_MAX_MS) return;
    if (pending) {             // the second tap of a double: the zoom's, not ours
      clearTimeout(pending);
      pending = 0;
    } else if (zoomS > 1) {
      pending = setTimeout(() => { pending = 0; toggleBar(); }, BAR_DBLTAP_MS);
    } else {
      toggleBar();
    }
  };
  document.addEventListener("pointerup", lift);
  document.addEventListener("pointercancel", lift);

  // Nothing on screen says the bar is there, so say it once: the first time a
  // game runs on a phone held sideways.
  const BAR_HINT_KEY = "dingbat_bar_tap_hint";
  const maybeHint = () => {
    if (!document.body.classList.contains("running") ||
        !matchMedia(PHONE_LANDSCAPE).matches) return;
    try {
      if (localStorage.getItem(BAR_HINT_KEY)) return;
      localStorage.setItem(BAR_HINT_KEY, "1");
    } catch { return; }
    pushToast("Tap the picture to show the bar", 4000, null);
  };
  new MutationObserver(maybeHint).observe(document.body, { attributes: true, attributeFilter: ["class"] });
  matchMedia(PHONE_LANDSCAPE).addEventListener?.("change", maybeHint);
}

// --- Gamepad support (polled each frame) ---
// A pad drives whatever is on screen. In the game view it plays (A/B/X/Y,
// shoulders, Back/Start, d-pad and left stick are the console's), with the
// triggers and stick clicks left for the app: RT holds fast-forward, LT holds
// rewind, and R3, the Guide button or Select+Start held opens the menu,
// paused, like a console's own. Everywhere else - the library, the menu,
// Settings, the other modals - the d-pad and stick move focus, A presses
// and B backs out (Escape). The Guide button is the OS's on most machines
// (Launchpad, Game Bar, Steam), hence the stick click and the chord.

// Standard-mapping button indices (w3c Gamepad "standard" layout).
const PB = { A: 0, B: 1, X: 2, Y: 3, LB: 4, RB: 5, LT: 6, RT: 7, BACK: 8, START: 9,
  L3: 10, R3: 11, UP: 12, DOWN: 13, LEFT: 14, RIGHT: 15, GUIDE: 16 };
const PAD_BUTTONS = 17;

const gpPrev = new Array(10).fill(false); // the game inputs the core was last sent
const GP_DEADZONE = 0.4;
let padNow = new Array(PAD_BUTTONS).fill(false);
let padPrev = new Array(PAD_BUTTONS).fill(false);
const padHit = (i) => padNow[i] && !padPrev[i];
let padCtx = "";              // the surface the pad drove last poll
const PAD_CHORD_MS = 500;     // Select+Start held this long opens the menu
let padChordSince = 0;
let padChordFired = false;
let padMenuPaused = false;    // the pad's menu paused the game; closing it resumes
let padMenuBar = false;       // ... and put the phone-landscape bar up for it
let padFastForward = false;   // RT's hold, as kbFastForward is Tab's
let padSpeedBeforeHold = "normal";
let padRewindHeld = false;

// D-pad and stick navigation repeats while held, like a key.
const PAD_REPEAT_DELAY_MS = 380;
const PAD_REPEAT_MS = 110;
let padNavDir = -1, padNavSince = 0, padNavLast = 0;
// The direction to move this poll (with auto-repeat), or -1.
const padNavPress = (now) => {
  const d = [PB.UP, PB.DOWN, PB.LEFT, PB.RIGHT].find((i) => padNow[i]);
  if (d === undefined) { padNavDir = -1; return -1; }
  if (d !== padNavDir) { padNavDir = d; padNavSince = padNavLast = now; return d; }
  if (now - padNavSince >= PAD_REPEAT_DELAY_MS && now - padNavLast >= PAD_REPEAT_MS) {
    padNavLast = now;
    return d;
  }
  return -1;
};

// Pad focus is drawn whatever the browser thinks of :focus-visible (a
// programmatic focus after a mouse click gets none); a pointer or key puts
// it back to the browser's.
const padNavOn = () => document.body.classList.add("pad-nav");
for (const ev of ["pointerdown", "keydown"]) {
  document.addEventListener(ev, (e) => {
    // Not the Escape that B dispatches.
    if (e.isTrusted) document.body.classList.remove("pad-nav");
  }, true);
}

const padReachable = (/** @type {HTMLElement} */ el) =>
  !(/** @type {any} */ (el).disabled) && el.getClientRects().length > 0 &&
  !el.closest("[inert], [hidden]") && getComputedStyle(el).visibility !== "hidden";

// The nearest of `items` from `from` in direction `dir`: candidates must lie
// that way, overlap in the cross axis wins, then the shortest gap.
const padSpatialPick = (items, from, dir) => {
  const r = from.getBoundingClientRect();
  const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
  let best = null, bestScore = Infinity;
  for (const el of items) {
    if (el === from) continue;
    const q = el.getBoundingClientRect();
    const qx = q.left + q.width / 2, qy = q.top + q.height / 2;
    let main, cross;
    const gap = (a0, a1, b0, b1) => Math.max(0, b0 - a1, a0 - b1); // 0 when overlapping
    if (dir === PB.UP || dir === PB.DOWN) {
      if (dir === PB.UP ? qy >= cy - 1 : qy <= cy + 1) continue;
      main = dir === PB.UP ? r.top - q.bottom : q.top - r.bottom;
      cross = gap(r.left, r.right, q.left, q.right);
      cross = cross * 3 + Math.abs(qx - cx) * 0.05;
    } else {
      if (dir === PB.LEFT ? qx >= cx - 1 : qx <= cx + 1) continue;
      main = dir === PB.LEFT ? r.left - q.right : q.left - r.right;
      cross = gap(r.top, r.bottom, q.top, q.bottom);
      cross = cross * 3 + Math.abs(qy - cy) * 0.05;
    }
    const score = Math.max(0, main) + cross;
    if (score < bestScore) { bestScore = score; best = el; }
  }
  return best;
};

const padFocus = (/** @type {HTMLElement} */ el, block = "nearest") => {
  padNavOn();
  el.focus({ preventScroll: true });
  el.scrollIntoView?.({ block: /** @type {ScrollLogicalPosition} */ (block), inline: "nearest" });
};

// Left/right on a slider or a select changes it rather than leaving it.
const padAdjust = (/** @type {HTMLElement} */ el, dir) => {
  const step = dir === PB.RIGHT ? 1 : dir === PB.LEFT ? -1 : 0;
  if (!step || !el) return false;
  if (el.tagName === "INPUT" && /** @type {HTMLInputElement} */ (el).type === "range") {
    const r = /** @type {HTMLInputElement} */ (el);
    if (step > 0) r.stepUp(); else r.stepDown();
  } else if (el.tagName === "SELECT") {
    const sel = /** @type {HTMLSelectElement} */ (el);
    const i = sel.selectedIndex + step;
    if (i < 0 || i >= sel.options.length) return true;
    sel.selectedIndex = i;
  } else {
    return false;
  }
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  return true;
};

// One step of focus navigation over `items`; nothing focused there yet
// takes `first` (or the first item) without moving.
const padMove = (items, dir, first = null, block = "nearest") => {
  if (!items.length) return;
  const cur = /** @type {HTMLElement} */ (document.activeElement);
  if (!cur || !items.includes(cur)) { padFocus(first || items[0], block); return; }
  if (padAdjust(cur, dir)) { padNavOn(); return; }
  const next = padSpatialPick(items, cur, dir);
  if (next) padFocus(next, block);
};

const padPress = () => {
  const el = /** @type {HTMLElement} */ (document.activeElement);
  if (!el || el === document.body || el.tagName === "SELECT") return;
  padNavOn();
  el.click();
};

// B: what Escape does where the pad is (close the modal, the menu).
const padBack = () => {
  const t = document.activeElement || document.body;
  t.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", bubbles: true, cancelable: true }));
};

// Gamepad inside Settings: shoulders cycle sections, d-pad walks controls,
// A activates, B goes back.
const settingsGamepadNav = (dir) => {
  if (padHit(PB.LB)) selectSettingsTab(settingsStep(settingsSection, -1));
  if (padHit(PB.RB)) selectSettingsTab(settingsStep(settingsSection, 1));
  if (padHit(PB.B)) {
    if (settingsOnDetail) showSettingsList();
    else closeSettingsModal();
    return;
  }
  if (padHit(PB.A)) {
    const el = /** @type {HTMLElement} */ (document.activeElement);
    if (el && settingsModal.contains(el) && el.click) { padNavOn(); el.click(); }
  }
  const cur = /** @type {HTMLElement} */ (document.activeElement);
  if ((dir === PB.LEFT || dir === PB.RIGHT) && cur && settingsModal.contains(cur)) {
    if (padAdjust(cur, dir)) padNavOn();
  }
  if (dir === PB.UP || dir === PB.DOWN) {
    const items = modalFocusables(settingsModal);
    if (!items.length) return;
    const d = dir === PB.DOWN ? 1 : -1;
    let i = items.indexOf(cur);
    if (i < 0) i = d > 0 ? -1 : 0;
    padFocus(items[(i + d + items.length) % items.length]);
  }
};

// The open modal on top: the trap's owner, else the last one open.
const padTopModal = () => {
  if (modalTrapOverlay && modalTrapOverlay.classList.contains("open")) return modalTrapOverlay;
  const open = document.querySelectorAll(".modal-overlay.open");
  return /** @type {HTMLElement} */ (open[open.length - 1]);
};

const padMenuItems = () => /** @type {HTMLElement[]} */ (
  [...menuDropdown.querySelectorAll("button, input[type=range]")].filter(padReachable));

// The library: the hero, the tiles, the chips and the head's buttons. The
// search field and the sort select are not the pad's (LT/RT sort; nothing
// types); a tile's corner buttons are Y's menu.
const padHomeItems = () => /** @type {HTMLElement[]} */ (
  [...document.querySelectorAll("#home button, #topbar button")].filter((el) =>
    el.getAttribute("tabindex") !== "-1" &&
    !el.matches(".home-tile-more, .home-tile-dl, .home-tile-link, .lib-search-clear") &&
    padReachable(/** @type {HTMLElement} */ (el))));

const padHomeFirst = (items) =>
  items.find((el) => el.id === "hero-resume") ||
  items.find((el) => el.id === "home-resume") ||
  items.find((el) => el.classList.contains("home-tile-launch")) || items[0];

// The arrow keys walk the grid the way the d-pad does, from a focused tile.
const PAD_ARROWS = { ArrowUp: PB.UP, ArrowDown: PB.DOWN, ArrowLeft: PB.LEFT, ArrowRight: PB.RIGHT };
document.addEventListener("keydown", (e) => {
  const dir = PAD_ARROWS[e.key];
  if (dir === undefined || e.shiftKey || e.metaKey || e.ctrlKey || e.altKey) return;
  if (document.body.classList.contains("running") || anyModalOpen() || tileMenuFor !== null) return;
  const t = /** @type {HTMLElement} */ (e.target);
  if (!t || !t.classList || !t.classList.contains("home-tile-launch")) return;
  const next = padSpatialPick(padHomeItems(), t, dir);
  e.preventDefault();
  if (next) {
    next.focus({ preventScroll: true });
    next.scrollIntoView?.({ block: "nearest", inline: "nearest" });
  }
});

// LB/RB: the system filter steps All -> each system -> All.
const padStepSystemFilter = (step) => {
  const systems = [...libChips.querySelectorAll(".lib-chip-sys")].map(
    (c) => /** @type {HTMLElement} */ (c).dataset.sys);
  if (!systems.length) return;
  const states = ["", ...systems];
  const cur = libFilter.systems.size === 1 ? [...libFilter.systems][0] : "";
  const want = states[(states.indexOf(cur) + step + states.length) % states.length];
  // Each chip click re-renders the chips, so look them up afresh each time.
  for (let guard = 0; guard < 8; guard++) {
    const wrong = /** @type {HTMLElement} */ ([...libChips.querySelectorAll(".lib-chip-sys")].find((c) =>
      (c.getAttribute("aria-pressed") === "true") !== (/** @type {HTMLElement} */ (c).dataset.sys === want)));
    if (!wrong) break;
    wrong.click();
  }
  padRefocusUntil = performance.now() + PAD_REFOCUS_MS;
};

const padStepSort = (step) => {
  const v = LIB_SORTS[(LIB_SORTS.indexOf(romsSort) + step + LIB_SORTS.length) % LIB_SORTS.length];
  setRomsSort(v);
  padRefocusUntil = performance.now() + PAD_REFOCUS_MS;
};

// A filter hides, and a sort rebuilds, the tile that had focus: for a moment
// after either, focus that went with it lands on the first game shown.
const PAD_REFOCUS_MS = 1500;
let padRefocusUntil = 0;

const padHomeNav = (dir) => {
  const items = padHomeItems();
  let cur = /** @type {HTMLElement} */ (document.activeElement);
  // Focus on a tile's corner button (where closing its menu puts it back)
  // is focus on the tile.
  const curTile = cur && cur.closest?.(".home-tile");
  if (curTile && !cur.classList.contains("home-tile-launch")) {
    const launch = /** @type {HTMLElement} */ (curTile.querySelector(".home-tile-launch"));
    if (launch && items.includes(launch)) { launch.focus({ preventScroll: true }); cur = launch; }
  }
  const onTile = cur && cur.classList.contains("home-tile-launch");
  if (padRefocusUntil && !(cur && items.includes(cur))) {
    if (performance.now() > padRefocusUntil) padRefocusUntil = 0;
    else {
      const tile = items.find((el) => el.classList.contains("home-tile-launch"));
      if (tile) { padRefocusUntil = 0; padFocus(tile, "center"); }
    }
  }
  if (dir >= 0) padMove(items, dir, padHomeFirst(items), "center");
  if (padHit(PB.A)) {
    if (cur && items.includes(cur)) padPress();
    else { const f = padHomeFirst(items); if (f) padFocus(f, "center"); }
  }
  if (padHit(PB.Y)) {
    // A tile's (or the hero's) ⋯ menu.
    const more = onTile ? cur.parentElement?.querySelector(".home-tile-more")
      : cur && cur.closest("#hero") ? document.getElementById("hero-more") : null;
    if (more) { padNavOn(); /** @type {HTMLElement} */ (more).click(); }
  }
  if (padHit(PB.START)) {
    // The hero's game: Resume, or Play when it has no session.
    const go = ["hero-resume", "hero-play", "home-resume"].map((id) => document.getElementById(id))
      .find((el) => el && padReachable(el));
    if (go) { padNavOn(); go.click(); }
  }
  if (libBar && !libBar.hidden) {
    if (padHit(PB.LB)) padStepSystemFilter(-1);
    if (padHit(PB.RB)) padStepSystemFilter(1);
    if (padHit(PB.LT)) padStepSort(-1);
    if (padHit(PB.RT)) padStepSort(1);
  }
  if (padHit(PB.B)) {
    // Back to the top of the page, where the game in hand is.
    const f = padHomeFirst(items);
    if (f) padFocus(f, "center");
  }
};

// The menu, opened from the pad over a running game: paused, the way a
// console's own menu is; closing it (B, Start, the same button again, or an
// item that closes it) resumes once nothing else is open.
const openPadMenu = () => {
  if (!menuDropdown.hidden) return;
  if (!playerPaused()) { togglePause(); padMenuPaused = true; }
  if (!document.body.classList.contains("topbar-open")) {
    document.body.classList.add("topbar-open"); // phone landscape keeps the bar folded away
    padMenuBar = true;
  }
  menuBtn.click();
  const items = padMenuItems();
  const first = items.find((el) => el.id === "save-state") || items[0];
  if (first) padFocus(first);
};
const closePadMenu = () => { menuDropdown.hidden = true; };

const padMenuNav = (dir) => {
  if (dir >= 0) padMove(padMenuItems(), dir);
  if (padHit(PB.A)) padPress();
  if (padHit(PB.B) || padHit(PB.START) || padHit(PB.R3) || padHit(PB.GUIDE)) closePadMenu();
};

// Back in the game with nothing over it: undo what the pad's menu did.
const settlePadMenu = () => {
  if (padMenuBar) { padMenuBar = false; document.body.classList.remove("topbar-open"); }
  if (padMenuPaused) {
    padMenuPaused = false;
    if (playerPaused()) togglePause();
  }
};

const endPadHolds = () => {
  if (padFastForward) {
    padFastForward = false;
    if (fastForward) applySpeed(padSpeedBeforeHold);
  }
  if (padRewindHeld) { padRewindHeld = false; setRewindHeld(false); }
};

// The triggers, the stick click, Guide and the chord, over the game view.
// A pad that does not claim the standard layout numbers its buttons its own
// way (an SNES-style pad can send Select and Start as 6 and 7, LT and RT
// here): the trigger holds, R3 and Guide stand down for it, so a button
// meant for the game never rewinds or fast-forwards it.
let padStd = true; // every connected pad claims the standard layout
const padGameSystem = (now) => {
  if (typeof clipReplayActive !== "undefined" && clipReplayActive) return;
  if (padNow[PB.RT] && padStd && !padFastForward && speedControlsOk() && currentRomName) {
    padFastForward = true;
    padSpeedBeforeHold = fastForward ? "normal" : currentSpeed();
    setFastForward(true);
    setSpeed2x(false);
  } else if (!padNow[PB.RT] && padFastForward) {
    padFastForward = false;
    if (fastForward) applySpeed(padSpeedBeforeHold);
  }
  if (padNow[PB.LT] && padStd && !padRewindHeld && speedControlsOk() && currentRomName) {
    padRewindHeld = true;
    setRewindHeld(true);
  } else if (!padNow[PB.LT] && padRewindHeld) {
    padRewindHeld = false;
    setRewindHeld(false);
  }
  let open = padStd && (padHit(PB.R3) || padHit(PB.GUIDE));
  if (padNow[PB.BACK] && padNow[PB.START]) {
    if (!padChordSince) padChordSince = now;
    else if (!padChordFired && now - padChordSince >= PAD_CHORD_MS) { padChordFired = true; open = true; }
  } else {
    padChordSince = 0;
    padChordFired = false;
  }
  if (open) openPadMenu();
};

// The ten console inputs from the pad, as the core numbers them.
const padGameInputs = () => {
  const want = new Array(10).fill(false);
  if (padNow[PB.A] || padNow[PB.Y]) want[4] = true;      // A / Y -> A
  if (padNow[PB.B] || padNow[PB.X]) want[5] = true;      // B / X -> B
  if (padNow[PB.BACK]) want[6] = true;                    // Back -> Select
  if (padNow[PB.START]) want[7] = true;
  if (padNow[PB.LB]) want[8] = true;                      // LB -> L
  if (padNow[PB.RB]) want[9] = true;                      // RB -> R
  if (padNow[PB.UP]) want[0] = true;                      // d-pad (and the stick)
  if (padNow[PB.DOWN]) want[1] = true;
  if (padNow[PB.LEFT]) want[2] = true;
  if (padNow[PB.RIGHT]) want[3] = true;
  return want;
};

const sendGameInputs = (want) => {
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

const padContext = () => {
  if (settingsModal.classList.contains("open")) return "settings";
  if (tileMenuFor !== null) return "tilemenu";
  if (anyModalOpen()) return "modal";
  if (!menuDropdown.hidden) return "menu";
  if (!document.body.classList.contains("running")) return "home";
  return "game";
};

const pollGamepads = () => {
  const pads = navigator.getGamepads ? navigator.getGamepads() : [];
  let anyConnected = false;
  for (const pad of pads) if (pad) { anyConnected = true; break; }
  document.body.classList.toggle(
    "gamepad-hides-touch", hideTouchOnGamepad && anyConnected);
  if (!anyConnected) {
    endPadHolds();
    return;
  }
  const now = performance.now();
  padPrev = padNow;
  padNow = new Array(PAD_BUTTONS).fill(false);
  const ctx = padContext();
  padStd = true;
  for (const pad of pads) {
    if (!pad) continue;
    if (pad.mapping !== "standard") padStd = false;
    for (let i = 0; i < PAD_BUTTONS; i++) if (pad.buttons[i] && pad.buttons[i].pressed) padNow[i] = true;
    const ax = pad.axes[0] || 0;
    const ay = pad.axes[1] || 0; // Left stick: the d-pad
    if (ay < -GP_DEADZONE) padNow[PB.UP] = true;
    if (ay > GP_DEADZONE) padNow[PB.DOWN] = true;
    if (ax < -GP_DEADZONE) padNow[PB.LEFT] = true;
    if (ax > GP_DEADZONE) padNow[PB.RIGHT] = true;
    // Tilt cart: the left stick is the accelerometer; claims the target only
    // while deflected.
    if (tiltActive && ctx === "game") {
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
  const gameReady = typeof Module !== "undefined" && !!Module._setInput;
  if (ctx !== padCtx) {
    // Leaving the game: let go of everything the core and the speed hold
    // had from the pad. Arriving anywhere: a button held across the switch
    // is not a press there (padPrev carries it).
    if (padCtx === "game" && gameReady) sendGameInputs(new Array(10).fill(false));
    if (ctx !== "game") endPadHolds();
    padCtx = ctx;
  }
  const dir = ctx === "game" ? -1 : padNavPress(now);
  const anyPress = padNow.some((p, i) => p && !padPrev[i]);
  switch (ctx) {
    case "settings":
      settingsGamepadNav(dir);
      break;
    case "tilemenu": {
      const items = tileMenuButtons().filter((b) => !b.disabled);
      if (dir === PB.UP || dir === PB.DOWN) padMove(items, dir);
      if (padHit(PB.A)) padPress();
      if (padHit(PB.B) || padHit(PB.Y)) closeTileMenu();
      break;
    }
    case "modal": {
      const top = padTopModal();
      if (top && dir >= 0) padMove(modalFocusables(top), dir);
      if (padHit(PB.A)) padPress();
      if (padHit(PB.B)) padBack();
      break;
    }
    case "menu":
      padMenuNav(dir);
      break;
    case "home":
      padMenuPaused = false; // Main Menu from the pad's menu: the game stays paused
      if (padMenuBar) { padMenuBar = false; document.body.classList.remove("topbar-open"); }
      // Only on a press: the items cost a style read apiece.
      if (dir >= 0 || anyPress || padRefocusUntil) padHomeNav(dir);
      break;
    case "game":
      if (!gameReady) break;
      settlePadMenu();
      padGameSystem(now);
      if (padContext() !== "game") {
        // The menu just opened over it: the game lets go now, not a frame on.
        sendGameInputs(new Array(10).fill(false));
        endPadHolds();
        padCtx = padContext();
        break;
      }
      sendGameInputs(padGameInputs());
      break;
  }
  // Away from the game, the console inputs track the pad without being
  // sent, so a button held into the game is not a press there either.
  if (ctx !== "game") {
    const want = padGameInputs();
    for (let i = 0; i < 10; i++) gpPrev[i] = want[i];
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
  // The home screen has no hamburger to carry the dot; its card's ⋯ does.
  heroMore.classList.toggle("has-new-photo", photoDots.menu);
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
    del.className = "button button-sm";
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
  await loadLandscapeButtonsFromStorage();
  await loadHideTouchOnGamepadFromStorage();
  await loadInputDisplayFromStorage();
  await loadControlStyleFromStorage();
  await loadLibraryOpenFromStorage();
  await loadRunaheadFromStorage();
  await loadAudioSettings();
  await loadColorCorrect();
  await loadSystemSettings();
  await loadSaveHook();
  await loadVideoSettings();
  await loadGbPalette();
  // Must run before anything can print: storePrint writes the whole array
  // back (web/tests/printer-photos.test.mjs), and the menu row and dots are
  // driven off the count.
  await loadPrinterPhotos();
  await loadSyncState();
  // After loadSyncState: a crashed run's session is queued for Drive.
  await takeLastGasp().catch(() => {});
  await noteCrashedRuns().catch(() => {});
  await loadRomsSort();
  // After loadSyncState, which reads the tombstones it consults, and before
  // the first render: an adopted game is a library game from the start.
  await adoptSaveOnlyGames();
  // Kept saves past their 30 days (see genOf), whether or not Drive is
  // reachable today: the delete to Drive is queued.
  await expireKeptSaves().catch(() => {});
  refreshSyncUI();
  startSyncTriggers();
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
    applyAudioSilent();
    applyChannelMutes();
    applyMp2kHle();
    applyFifoInterp();
    applyLcdResponse();
    // Unblock queued launches and retire the boot progress strip.
    markRuntimeReady();
    document.body.classList.add("runtime-ready");
    // The one-time library-pictures offer: after the grid and the Drive
    // session (resumeDriveOnBoot) have had a moment to settle, and the
    // first pull has had its say.
    setTimeout(() => { offerThumbnailsAfterBoot().catch(() => {}); }, 1500);
    setTimeout(() => { packStoredStates().catch(() => {}); }, 4000);
    offerStateRetry().catch(() => {});
    let frameCount = 0;
    const SAMPLE_RATE = 32768; // GBA/GB native sample rate
    const TARGET_FPS = 59.7275;
    const FRAME_TIME = 1000.0 / TARGET_FPS;
    let lastFrameTime = 0;
    let accumulator = 0;
    // Fast-forward pacing. A tick's frames have to end before the vsync
    // they aim at: where rAF keeps to the display, one that overruns it
    // waits for the next and the time between idles. A fixed 16 ms budget
    // ends past a 60 Hz vsync once the present is added, so at ~5 ms a frame
    // (an iPhone SE) a tick ran 4 frames per 33 ms, and 3 once a frame took
    // over 16/3 ms: 120 fps to 90 on a few percent of frame cost.
    let ffFrameMs = 4;      // running mean of one fast-forward frame
    // Frames nobody sees (docs/frame-skip.md): of the frames a tick runs
    // only the last is shown, so the others are not drawn (and run-ahead
    // looks ahead only for the shown one). `?draw=all` draws every frame,
    // to compare.
    const drawAll = new URLSearchParams(location.search).get("draw") === "all";
    let unseenFrames = 0;   // diagnostics: frames run undrawn (the ff log)
    const unseenNext = () => {
      if (!drawAll && Module._wasm_unseen_next) { Module._wasm_unseen_next(); unseenFrames++; }
    };
    let ffVsyncMs = 1000 / 60; // running mean of the rAF interval at play
    let ffOverMs = 2;       // running mean of the tick's own work after them
    let ffReserveMs = 2;    // and of the browser's, learnt from late ticks
    let ffEmuEnd = 0;       // when the last fast-forward tick's frames ended
    let tickEnd = 0;        // when the last tick returned
    let ffAimed = 0;        // vsyncs the last fast-forward tick aimed at
    let ffLastTs = 0;
    // Whether running past a vsync costs one here. Where rAF does not keep
    // to the display (a late tick is called straight back), aiming only
    // leaves the reserve idle and the plain 16 ms budget runs more. Every
    // FF_PROBE_TICKS an aimed tick overruns its vsync on purpose; called back
    // before the next vsync, the overrun was free. A free tick called back a
    // vsync after it ended says it no longer is.
    const FF_PROBE_TICKS = 120;
    let ffFree = false;
    let ffProbing = false;
    let ffProbeIn = 10;
    // Fast-forward diagnostics for the log, every ~5 s of it: what a frame
    // costs here and how the ticks land on the display.
    let ffStat = { since: 0, frames: 0, ticks: 0, emuMs: 0, late: 0 };
    const ffStatNote = (timestamp, frames, emuMs, late) => {
      const st = ffStat;
      if (st.since === 0 || timestamp - st.since > 10000) {
        ffStat = { since: timestamp, frames: 0, ticks: 0, emuMs: 0, late: 0 };
        unseenFrames = 0;
        return;
      }
      st.frames += frames; st.ticks++; st.emuMs += emuMs; if (late) st.late++;
      const span = timestamp - st.since;
      if (span < 5000) return;
      log(`ff: ${(1000 * st.frames / span).toFixed(0)} fps, ` +
        `${(st.emuMs / st.frames).toFixed(2)} ms/frame, ${(st.frames / st.ticks).toFixed(1)} frames/tick, ` +
        `${(span / st.ticks).toFixed(1)} ms/tick (vsync ${ffVsyncMs.toFixed(1)}), ` +
        `${st.late} late of ${st.ticks}, after ${ffOverMs.toFixed(1)} + ${ffReserveMs.toFixed(1)} ms, ` +
        `${ffFree ? "free (16 ms budget)" : "aimed"}, ` +
        (drawAll ? "every frame drawn (draw=all)" : `${unseenFrames} not drawn`));
      ffStat = { since: timestamp, frames: 0, ticks: 0, emuMs: 0, late: 0 };
      unseenFrames = 0;
    };

    // Push-based Web Audio playback: samples at SAMPLE_RATE scheduled at
    // precise times; the browser resamples to the device rate.
    let audioCtx = null;
    let gainNode = null;
    let lowpassNode = null;
    let playTime = 0;

    // The recorder's audio (Record, and Clip that! where there is no
    // WebCodecs): every pushed buffer is also played into a MediaStream
    // destination in a context of its own at 48 kHz. Not a branch of the
    // 32768 Hz graph: Chrome's MediaRecorder, handed a 32768 Hz track,
    // drops ~2 % of it and stamps the rest unevenly (a 60 ms hole and
    // dozens of 2-6 ms gaps and overlaps in 10 s, measured), which players
    // render as chop; at 48 kHz the same recording is whole.
    let clipTapCtx = null;
    let clipTapNode = null;
    let clipTapTime = 0;
    let clipTapActive = false;
    // A clip replay's sound goes to the tap alone, never to the speakers.
    let clipTapPrivate = false;
    const CLIP_TAP_LEAD = 0.05;   // s queued ahead in the tap's context

    const routeOutput = () => {
      if (!audioCtx || !gainNode) return;
      try { gainNode.disconnect(); } catch (e) {}
      // GBA games only, as the setting says: the filter models the GBA's
      // output stage, and a Game Boy game keeps the unfiltered path.
      if (typeof audioLowpass !== "undefined" && audioLowpass &&
          !!currentRomName && extOf(currentRomName) === ".gba") {
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
    };
    window.updateAudioLowpass = () => routeOutput();
    // Recorder-side hooks; the tap's MediaStream, or null pre-unlock.
    // `priv`: the samples pushed from now on reach the tap and nothing
    // else (a clip replay); otherwise the tap hears what the speakers do.
    window.acquireClipAudio = (priv = false) => {
      if (!audioCtx || !gainNode) return null;
      if (!clipTapCtx) {
        try {
          clipTapCtx = new AudioContext({ sampleRate: 48000 });
        } catch (e) {
          clipTapCtx = new AudioContext();
        }
        clipTapNode = clipTapCtx.createMediaStreamDestination();
      }
      if (clipTapCtx.state !== "running") clipTapCtx.resume().catch(() => {});
      clipTapPrivate = !!priv;
      clipTapActive = true;
      clipTapTime = 0;
      return clipTapNode.stream;
    };
    window.releaseClipAudio = () => {
      clipTapActive = false;
      clipTapPrivate = false;
      // Idle, it would hold an output stream open for nothing.
      if (clipTapCtx) clipTapCtx.suspend().catch(() => {});
    };
    // The buffer pushAudio just built, into the tap's context. AudioBuffers
    // are not tied to a context; this one is resampled there. Its own lead
    // servo, as pushAudio's: the two contexts' clocks are not one clock.
    const feedClipTap = (buffer) => {
      const now = clipTapCtx.currentTime;
      if (clipTapTime < now + 0.01) clipTapTime = now + CLIP_TAP_LEAD;
      const src = clipTapCtx.createBufferSource();
      src.buffer = buffer;
      src.connect(clipTapNode);
      const excess = clipTapTime - now - CLIP_TAP_LEAD;
      const rate = 1 + Math.max(-0.004, Math.min(0.004, excess * 0.15));
      src.playbackRate.value = rate;
      src.start(clipTapTime);
      clipTapTime += buffer.duration / rate;
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
      // "playback" audio session so iOS plays in Silent Mode (Safari 17+),
      // unless the user turned that off or the game is paused or muted.
      audioSessionLive = true;
      applyAudioSession();
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
      applyAudioSession();   // muted or 0 lets go at once, not next tick
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
      if (clipTapActive && clipTapCtx) {
        feedClipTap(buffer);
        if (clipTapPrivate) return;   // a replay: not for the speakers
      }
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

    setInterval(watchBattery, SAVE_SETTLE_MS);

    window.addEventListener("beforeunload", () => {
      // Get the BYE out so the peer sees a clean exit (the sync parts run
      // before the page dies). A rollback session (netMode is false in it)
      // too: its teardown promotes the session's core and issues the put of
      // its battery synchronously (rbTeardown -> persistSave), and nothing
      // else here would persist what was played in it.
      if ((netActive() || rollbackMode) && typeof netShutdown === "function") netShutdown();
      if (linkMode) {
        persistLinkSaves();
      } else if (currentRomName && currentOriginalName) {
        // The run's end first: a quitting WebKit lands that small write
        // and none after it (measured), and a quit counted as a crash would
        // count toward asking. Chrome lands none of them, and the session
        // comes back from localStorage (see "Last gasp").
        clearPlaying();
        persistSave(currentRomName, currentOriginalName);
        persistAutoState();
        leaveLastGasp();
        // Best-effort (the encode may not finish), and only a screen not yet
        // stored: a paused game's would re-queue a picture Drive may hold a
        // newer one of, from the device that played on.
        storeLastFrame();
      }
    });

    // Mobile browsers kill backgrounded tabs without pagehide: snapshot on hide.
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) return;
      // As at beforeunload: a quitting browser may run this and no more.
      clearPlaying(); // hidden is a normal end, whatever happens after
      if (currentRomName && currentOriginalName && !linkMode) {
        persistSave(currentRomName, currentOriginalName);
      }
      persistAutoState();
      leaveLastGasp();
      storeLastFrame(); // as at beforeunload
    });

    // iOS Safari often skips beforeunload; pagehide is the reliable signal
    // (also on bfcache entry). Suspend the AudioContext so a bfcached page
    // doesn't hold the audio session.
    window.addEventListener("pagehide", () => {
      // As beforeunload, rollback included.
      if ((netActive() || rollbackMode) && typeof netShutdown === "function") netShutdown();
      if (linkMode) {
        persistLinkSaves();
      } else if (currentRomName && currentOriginalName) {
        // As at beforeunload, in its order.
        clearPlaying();
        persistSave(currentRomName, currentOriginalName);
        persistAutoState(); // one-tap resume next launch
        leaveLastGasp();
        storeLastFrame(); // as at beforeunload
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

    // Enhanced-audio switch (#hle-indicator). Shown while the setting is on
    // and the loaded game's sound engine is recognised — detection survives
    // the per-game bypass, so the button stays put to be tapped back on —
    // and lit while the HLE is substituting audio right now.
    const hleIndicator = document.getElementById("hle-indicator");
    let hleShown = false;
    let hleActive = false;
    let hlePressed = true;
    const updateHleIndicator = () => {
      const avail = mp2kHle && !!(
        Module._wasm_mp2k_available && Module._wasm_mp2k_available()
      );
      const on = avail && !!(
        Module._wasm_hle_audio_active && Module._wasm_hle_audio_active()
      );
      const pressed = !mp2kHleSessionOff;
      if (avail !== hleShown) {
        hleShown = avail;
        hleIndicator.hidden = !avail;
      }
      if (on !== hleActive) {
        hleActive = on;
        hleIndicator.classList.toggle("on", on);
      }
      if (pressed !== hlePressed) {
        hlePressed = pressed;
        hleIndicator.setAttribute("aria-pressed", pressed ? "true" : "false");
        hleIndicator.title = pressed
          ? "Enhanced audio on — tap to hear the hardware mix"
          : "Enhanced audio off for this game — tap to turn it back on";
      }
    };
    hleIndicator.addEventListener("click", () => {
      mp2kHleSessionOff = !mp2kHleSessionOff;
      applyMp2kHle();
      updateHleIndicator();
    });

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
      applyAudioSession(); // other apps' audio plays while paused (idempotent)
      if (paused) {
        clearPlaying(); // a paused game is not a run a crash could end
        updateRumble(timestamp); // drops body.rumbling promptly on pause
        watchCanvasBacking();
        lastFrameTime = 0;
        accumulator = 0;
        requestAnimationFrame(tick);
        return;
      }
      sessionMoved = true;
      if (lastFrameTime === 0) lastFrameTime = timestamp;
      const rafIv = timestamp - lastFrameTime;
      if (!fastForward && rafIv > 4 && rafIv < 40) ffVsyncMs += (rafIv - ffVsyncMs) * 0.05;
      // Play time for the checkpoints: a stall (a hidden tab's) counts as little.
      runPlayMs += Math.min(rafIv, 250);
      if (!linkMode && !rollbackMode && !netMode && !document.hidden) markPlaying();
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
      } else if (clipReplayActive && clipEncodeActive) {
        // clipEncode steps the core itself, off screen and off the clock.
        accumulator = 0;
        presentSkip = true;
      } else if (clipReplayActive) {
        // Realtime capture replay (no WebCodecs): clip_tick presents each
        // frame and returns -1 when the log is exhausted (the live state is
        // already restored). pushAudio feeds the private tap only.
        let framesRun = 0;
        let done = false;
        while (accumulator >= FRAME_TIME && framesRun < 2) {
          const left = Module._clip_tick();
          if (left < 0) { done = true; break; }
          if ((left & 15) === 0)
            setClipProgress((clipTotalFrames - left) / Math.max(1, clipTotalFrames));
          pushAudio();
          frameCount++;
          accumulator -= FRAME_TIME;
          framesRun++;
        }
        // As the normal loop: zeroing the debt would delete those frames'
        // audio, a gap in the recording at every hitch.
        if (accumulator > FRAME_TIME * 2) accumulator = FRAME_TIME * 2;
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
        // As many frames as end, by their running mean, before the vsync
        // aimed at less what follows them: the rest of this tick (measured)
        // and the browser's present (a reserve, widened by each tick that
        // missed its vsync). The aim spans enough vsyncs for 4 frames and
        // what follows them, so the partial frame lost at the end stays
        // small. playTime
        // stays continuous and only frames whose audio fits within
        // FF_MAX_AUDIO_LEAD play; the rest are dropped, so audio stays
        // realtime-rate.
        const iv = timestamp - ffLastTs;
        const busy = tickEnd - ffLastTs; // the last tick, from its rAF time
        ffLastTs = timestamp;
        let late = ffAimed > 0 && iv < 200 && iv > (ffAimed + 0.5) * ffVsyncMs;
        if (ffProbing) {
          ffProbing = false;
          ffFree = !late && iv < 200;
          late = false; // that overrun was the probe's own
          ffProbeIn = FF_PROBE_TICKS;
        } else if (ffFree) {
          if (iv < 200 && iv > busy + 0.5 * ffVsyncMs) ffFree = false;
        } else if (late) {
          ffReserveMs = Math.min(ffReserveMs + 1, 60);
        } else if (ffAimed > 0 && iv < 200) {
          ffReserveMs = Math.max(ffReserveMs - 0.05, 1);
        }
        if (ffEmuEnd > 0 && tickEnd > ffEmuEnd && iv < 200)
          ffOverMs += (Math.min(tickEnd - ffEmuEnd, 100) - ffOverMs) * 0.2;
        let t = performance.now();
        let deadline;
        if (ffFree) {
          ffAimed = 0;
          deadline = t + 16 + ffFrameMs; // frames start until 16 ms in
        } else {
          const after = ffOverMs + ffReserveMs;
          ffAimed = Math.min(6, Math.max(1, Math.ceil(
            (Math.max(0, t - timestamp) + 4 * ffFrameMs + after) / ffVsyncMs)));
          deadline = timestamp + ffAimed * ffVsyncMs - after;
          if (--ffProbeIn <= 0) {
            // Frames until the vsync itself: the last ends past it
            ffProbing = true;
            deadline = timestamp + ffAimed * ffVsyncMs + ffFrameMs;
          }
        }
        const t0 = t;
        let n = 0;
        do {
          // Not the last if another fits after it; a wrong guess shows a
          // frame or two back, never a broken one
          if (t + 2 * ffFrameMs < deadline) unseenNext();
          Module._loop_tick();
          if (audioCtx && audioCtx.state === "running" &&
              playTime - audioCtx.currentTime < FF_MAX_AUDIO_LEAD) {
            pushAudio();
          } else if (Module._clearAudioBuffer) {
            Module._clearAudioBuffer(); // discard this frame's audio; keep the WASM buffer bounded
          }
          frameCount++;
          const now = performance.now();
          ffFrameMs += (Math.min(now - t, 50) - ffFrameMs) * 0.1;
          t = now;
          n++;
        } while (t + ffFrameMs < deadline);
        ffEmuEnd = t;
        ffStatNote(timestamp, n, t - t0, late);
        accumulator = 0;
      } else {
        // Catch up, capped. At 2x each frame consumes half the step.
        const step = speed2x ? FRAME_TIME / 2 : slowMotion ? FRAME_TIME * 2 : FRAME_TIME;
        const maxFrames = speed2x ? 4 : 2;
        // Run-ahead only at normal speed; off, this is plain loop_tick.
        const useRunahead = runaheadFrames > 0 && !speed2x && !slowMotion &&
          typeof Module._runahead_tick === "function";
        let framesRun = 0;
        while (accumulator >= step && framesRun < maxFrames) {
          if (accumulator - step >= step && framesRun + 1 < maxFrames) unseenNext();
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
      // A recorder at realtime (Record, or a clip replay without WebCodecs)
      // films the export canvas, not this one: paint it each new frame.
      if (!presentSkip && (recRecorder || (clipReplayActive && !clipEncodeActive))) {
        nativeFrameCanvas();
      }
      presentSkip = false;
      updateSleepOverlay();
      updateHleIndicator();
      updateGlow();
      updateRumble(timestamp);
      watchCanvasBacking();
      maybeCheckpoint(timestamp);
      notePlayingLong();
      tickEnd = performance.now();
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

// Haptic tick: ~25 ms is the perceptible floor for Android motors (Assumed).
// iOS never shipped vibrate and Firefox removed it in 129; silent no-ops there.
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

