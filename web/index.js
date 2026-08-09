// Keyboard-navigation escape hatch: when focus is in the top bar, menu, or an
// open modal, Tab must keep moving focus. This runs on window in the CAPTURE
// phase and is registered before em.js executes, so it outranks both the SDL
// runtime's key grab (which preventDefaults Tab app-wide once a game runs) and
// the fast-forward shortcut. Stopping propagation leaves the browser's default
// focus traversal intact. keydown only: keyup flows through so a held
// fast-forward always gets its release.
//
// Modal case: stopping at window capture means the event never reaches the
// overlay's own Tab-wrap trap either (capture stops downward propagation),
// so invoke the active trap handler directly to keep focus cycling inside
// the dialog. (modalTrapHandler is defined further down; events only fire
// after the whole script has run.)
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

// Typing escape hatch: once a core runs, the SDL runtime's key handlers
// (window, BUBBLE phase — they observably consume after target-phase
// dispatch) preventDefault page-wide, which silently ate every character
// typed into a text field (the cheat inputs only accepted paste). This guard
// also sits at window-bubble, registered before em.js so it runs first
// there, and stops text-field events from reaching SDL. Bubble, not capture:
// listeners attached to the fields themselves (the room-code input submits
// on its own Enter keydown) must still see the event in the target phase.
// Tab belongs to the hook above; Escape must keep flowing to the
// close-all-modals handler. No preventDefault anywhere here.
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

// --- Service Worker ---

let swRegistration = null;

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js").then((reg) => {
    if (!reg) return; // SW-blocked contexts (test harnesses) resolve undefined
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
  // Reload when a NEW service worker takes over from an old one (the Update
  // flow). On the very first visit the install's clients.claim() also fires
  // controllerchange — reloading then flashes the page mid-boot, aborts the
  // in-flight em.wasm fetch, and on a slow connection can land after the user
  // already started a game and kill it. An uncontrolled page simply starts
  // using the new SW without a reload.
  const hadController = !!navigator.serviceWorker.controller;
  let refreshing = false;
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if (hadController && !refreshing) {
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

// True once an update reload is committed. The Drive token renewal checks
// this: starting a GIS popup that the imminent reload will orphan only loses
// the token (see armDriveRenewOnGesture's update-button exemption).
var appUpdating = false;

const applyUpdate = async () => {
  appUpdating = true;
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
    // Cache-first on purpose: this is the version of the build the tab is
    // actually EXECUTING, which is the only one worth reporting. A new worker
    // stays waiting until Update is pressed, so the origin can be several
    // deploys ahead of the running code.
    version = (await (await fetch("version.txt")).text()).trim().slice(0, 12);
  } catch {}
  // ...and the origin's version, via a probe sw.js passes to the network, so a
  // stale running build is visible in the log instead of having to be deduced.
  // Measuring performance against the wrong build is otherwise invisible: the
  // page looks current because every network check reports the new version.
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
let modalTrapOverlay = null; // which overlay owns the current trap

const modalFocusables = (overlay) =>
  Array.from(
    overlay.querySelectorAll("button, input, select, textarea, [tabindex]")
  ).filter(
    (n) => !n.disabled && n.offsetParent !== null && n.getAttribute("tabindex") !== "-1"
      // An `inert` subtree is unreachable by Tab, so it must be unreachable by
      // the trap too: the settings sheet keeps its off-stage screen mounted
      // (and painted, mid-slide) but inert.
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
  // Only the overlay that owns the trap may release it. The global Escape
  // handler calls every modal's closer blindly; without this check the first
  // closer in that list would null the handler/focus state on behalf of a
  // different, actually-open modal (leaking its Tab-trap listener and
  // restoring focus prematurely).
  if (modalTrapOverlay !== overlay) return;
  modalTrapOverlay = null;
  if (modalTrapHandler) overlay.removeEventListener("keydown", modalTrapHandler);
  modalTrapHandler = null;
  try {
    // The return target may be gone or display:none by now (a modal opened
    // from the menu records the menu item, and the dropdown has since been
    // hidden — focusing it silently fails and keyboard focus falls to body).
    // Fall back to the menu button so focus stays in the chrome.
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

// --- Give focus back to the game after a pointer-activated chrome control ---
//
// Clicking a top-bar control (Pause, Reset, a menu item…) leaves DOM focus
// sitting on that button. Every keyboard shortcut afterwards is then aimed at
// the focus ring instead of the emulator — most visibly Tab, which the
// window-capture hook at the top of this file deliberately keeps as focus
// traversal while focus is in the chrome, so "click Pause, hold Tab to
// fast-forward" just walked the top bar. Hand focus back to the game surface
// instead.
//
// POINTER activations only. A keyboard user who tabs to a button and presses
// Enter/Space gets a click too, and stealing focus there would dump them at the
// top of the tab order with no visible ring. The two are told apart by
// `detail`: a real mouse/touch click carries its click count (>= 1), while a
// keyboard-synthesised click (and el.click()) reports 0.
const returnFocusToGame = (/** @type {any} */ ctl) => {
  if (ctl && typeof ctl.blur === "function") ctl.blur();
  // The canvas carries tabindex="-1": programmatically focusable, never in the
  // tab order. preventScroll matters — #home is a scroll container and the
  // default scroll-into-view would jump the library. If the surface isn't
  // focusable right now (no game loaded, so it's display:none) the blur above
  // has already done the important half.
  if (canvasEl && typeof canvasEl.focus === "function") {
    try { canvasEl.focus({ preventScroll: true }); } catch { try { canvasEl.focus(); } catch {} }
  }
};

// Bubble phase on document, so a control's own handler has already run (and,
// where it opens a modal synchronously, anyModalOpen() below already sees it).
document.addEventListener("click", (e) => {
  if (!e || e.detail === 0) return; // keyboard/programmatic activation
  const t = /** @type {any} */ (e.target);
  // Duck-typed: the click target is often the button's inner <svg>, and the
  // test harness dispatches bare event objects.
  if (!t || typeof t.closest !== "function") return;
  // Modals and the menu run their own focus management (trapFocus /
  // releaseFocus); pulling focus to the canvas underneath them would break the
  // trap and the restore-on-close.
  if (t.closest(".modal-overlay")) return;
  // Scoped to the main chrome. Home-screen controls (Load a game, the library
  // tiles) are a normal document flow where keeping focus is correct.
  if (!t.closest("#topbar, #topbar-handle")) return;
  if (anyModalOpen()) return;
  const ctl = t.closest("button, [href], [tabindex]");
  // Text fields and range inputs keep focus: typing and arrow-key nudging are
  // the whole point of them, and the SDL typing escape hatch at the top of this
  // file depends on the field still being document.activeElement.
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

// Move a set of keys — and write a set of unrelated records — as ONE
// transaction. This exists for renaming a game, where every record is keyed by
// the name (see perGameKeys): a half-finished rename would orphan a battery
// save from its ROM, which is data loss wearing a rename's clothing.
//
// Everything lives in the single "blobs" store, so one readwrite transaction
// covers the whole migration: the copies, the deletes, the recents index that
// points at them and the Drive queue that mirrors them all commit together or
// none of them do. That is strictly stronger than write-new/verify/delete-old,
// which can still be interrupted between its phases.
//
// `pairs` is [[from, to], ...]; a `from` that holds nothing is skipped (the
// per-game key list is a superset of what any one game actually stores), and a
// `to` that already holds something aborts the whole transaction rather than
// overwriting it — collisions are refused, never merged. `puts` is
// [[key, value], ...] applied in the same transaction. Resolves with the list
// of [from, to] pairs that actually moved.
const dbMoveKeys = (pairs, puts = []) => new Promise((resolve, reject) => {
  let tx = db.transaction("blobs", "readwrite");
  let store = tx.objectStore("blobs");
  let moved = [];
  let failure = null;
  const fail = (msg) => {
    if (failure) return;
    failure = new Error(msg);
    try { tx.abort(); } catch {}
  };
  for (let [from, to] of pairs) {
    // Read the destination first: the guard has to see the same snapshot the
    // writes land in, and inside one transaction it does.
    let dest = store.get(to);
    dest.onsuccess = () => {
      if (failure) return;
      if (dest.result !== undefined && dest.result !== null) {
        fail("Something is already stored under that name (" + to + ").");
        return;
      }
      // Issued from a request callback, so it is still inside this
      // transaction — an `await` here would end it instead.
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
  tx.oncomplete = () => resolve(moved);
  tx.onabort = () => reject(failure || tx.error || new Error("The move was rolled back."));
  tx.onerror = () => reject(failure || tx.error || new Error("The move failed."));
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

// Sweep up auto-resume snapshots orphaned by builds whose Delete didn't know
// about them (they were the one per-game record no destructive path removed).
// A snapshot whose game is neither stored here nor listed in the library can
// never be offered — nothing can launch it — so it is dead weight worth a whole
// save state each. Scoped to "stateauto:" on purpose: it is the only per-game
// record the app regenerates by itself, so deleting one loses nothing. Records
// the user authored (cheats) are left alone even when orphaned; they cost bytes
// and would be missed if a re-import found them gone.
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

// Show the bottom scrim only while more items sit below the fold, so it never
// permanently fades the last item (Report a Bug) in windows tall enough that
// the menu doesn't scroll. Re-checked on open/scroll/resize; scrollHeight
// reads 0 while hidden, so the open-time call does the first real measurement.
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
    // Fresh open starts with the Capture group folded (defined later;
    // guarded for the pre-parse window)
    if (typeof collapseCaptureSub === "function") collapseCaptureSub();
    updateMenuScrollHint();
  }
});

// aria-expanded tracks the dropdown wherever it gets closed (many sites set
// menuDropdown.hidden directly), so a screen reader always hears the truth.
new MutationObserver(() =>
  menuBtn.setAttribute("aria-expanded", String(!menuDropdown.hidden))
).observe(menuDropdown, { attributes: true, attributeFilter: ["hidden"] });

menuDropdown.addEventListener("scroll", updateMenuScrollHint, { passive: true });
window.addEventListener("resize", updateMenuScrollHint);

document.addEventListener("click", () => {
  menuDropdown.hidden = true;
});

// Screen-reader names for every settings switch: the visible text lives in a
// sibling div, not the wrapping <label>, so assistive tech read each one as a
// bare "checkbox". Link input -> row label (and description) once at boot;
// this covers every .modal-toggle-row in the static HTML, present and future.
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
      reader.addEventListener("load", () => { callback(new Uint8Array(/** @type {ArrayBuffer} */ (reader.result)), file.name); done(); });
      reader.addEventListener("error", done);
      reader.readAsArrayBuffer(file);
    } else done();
  });
  input.addEventListener("cancel", done);  // dismissed without picking
  input.click();
};

// --- Settings navigation ----------------------------------------------------
//
// Which layout is on screen is CSS's business (styles.css, "Settings
// surface"): >=760px is a fixed 900x640 modal with a section rail, below it an
// 88dvh sheet whose rail becomes a drill-down list. This half owns which
// section is showing, which screen the sheet is on, and the navigation that
// only exists on the sheet — push/pop, the header stepper, hardware back.
//
// Order is fixed and never most-recently-used: reordering would mean the item
// you want is somewhere new each time, which is the original complaint on a
// different axis.
const SETTINGS_SECTIONS = ["controls", "gb", "gba", "video", "audio", "general"];
const SETTINGS_LAST_KEY = "settings-section";

const settingsTabs = Array.from(/** @type {NodeListOf<HTMLElement>} */ (document.querySelectorAll(".settings-tab")));
const settingsFrame = document.getElementById("settings-frame");
const settingsRail = document.getElementById("settings-rail");
const settingsContent = document.getElementById("settings-content");
const settingsScroll = document.getElementById("settings-scroll");
const settingsSectionTitle = document.getElementById("settings-section-title");
const settingsBackBtn = document.getElementById("settings-back");
const settingsPrevBtn = document.getElementById("settings-prev");
const settingsNextBtn = document.getElementById("settings-next");
const settingsVersionEl = document.getElementById("settings-version");

// Width only, never pointer type or user-agent: an iPad at 1024 gets the rail,
// and (pointer: coarse) grows its rows rather than handing it a second layout.
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
    // Roving tabindex: one stop for the whole list, arrows move within it.
    t.setAttribute("tabindex", on ? "0" : "-1");
    const pane = document.getElementById("settings-pane-" + t.dataset.tab);
    if (pane) pane.hidden = !on;
  }
  settingsSectionTitle.textContent = settingsName(name);
  // Name the destination, not the direction.
  settingsPrevBtn.setAttribute(
    "aria-label", "Previous section: " + settingsName(settingsStep(name, -1)));
  settingsNextBtn.setAttribute(
    "aria-label", "Next section: " + settingsName(settingsStep(name, 1)));
  // Always top, never a restored per-section offset: landing mid-list reads as
  // the wrong section having loaded.
  settingsScroll.scrollTop = 0;
  try { localStorage.setItem(SETTINGS_LAST_KEY, name); } catch {}
};

// The off-stage sheet screen is still painted (it is mid-slide for 200ms) but
// must not be reachable by Tab or by the modal focus trap. `inert` says both
// things at once; modalFocusables skips anything inside one.
const applySettingsScreen = () => {
  const sheet = settingsIsSheet();
  settingsFrame.classList.toggle("on-detail", sheet && settingsOnDetail);
  const off = !sheet ? null : settingsOnDetail ? settingsRail : settingsContent;
  for (const el of [settingsRail, settingsContent]) {
    if (el === off) el.setAttribute("inert", "");
    else el.removeAttribute("inert");
  }
};

// One history entry per level, so Android's back gesture matches the sheet:
// back from a detail returns to the list, back from the list closes the sheet.
// Entries are only pushed in the sheet layout — a browser Back that closed a
// desktop dialog would be a surprise.
const settingsHistOk = typeof history !== "undefined" && !!history.pushState;
let settingsHistDepth = 0;   // our entries still on the stack
let settingsHistSkip = 0;    // popstate events we caused ourselves

const settingsHistPush = () => {
  if (!settingsHistOk) return;
  settingsHistDepth++;
  try { history.pushState({ dingbatSettings: settingsHistDepth }, ""); }
  catch { settingsHistDepth--; }
};

// Drop n of OUR entries. history.go() fires exactly one popstate however far
// it travels, so one skip covers the whole unwind.
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
  settingsTabOf(settingsSection)?.focus();
};

const openSettingsSection = (name) => {
  selectSettingsTab(name);
  if (!settingsIsSheet() || settingsOnDetail) return;
  settingsOnDetail = true;
  settingsHistPush();
  applySettingsScreen();
  settingsBackBtn.focus();
};

window.addEventListener("popstate", () => {
  if (settingsHistSkip > 0) { settingsHistSkip--; return; }
  if (settingsHistDepth <= 0) return;
  settingsHistDepth--;
  if (settingsOnDetail) showSettingsList(true);
  else closeSettingsModal(true);
});

// Layout can change under an open dialog (rotation, a resized window). The
// sheet always shows a section rather than the bare list in that case, which
// is where a desktop reader already was.
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

// Rail keyboard: up/down between sections, Home/End to the ends. On the rail
// the move selects, because the pane beside it is the thing being labelled; on
// the sheet's list it only moves focus, because entering is a separate act.
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

// Swipe the sheet's chrome down to dismiss. The sheet's HEIGHT is never
// dragged — there is no half-height detent — only its offset, and only far
// enough to read as a dismissal.
let sheetDragFrom = 0;
let sheetDragDy = null;
const endSheetDrag = () => {
  if (sheetDragDy === null) return;
  const dy = sheetDragDy;
  sheetDragDy = null;
  settingsFrame.classList.remove("sheet-dragging");
  settingsFrame.style.transform = "";
  if (dy > 90) closeSettingsModal();
};
settingsFrame.addEventListener("pointerdown", (e) => {
  if (!settingsIsSheet()) return;
  const chrome = /** @type {Element} */ (e.target);
  if (!chrome?.closest?.(".settings-grab, .settings-rail-head, .settings-head")) return;
  sheetDragFrom = e.clientY;
  sheetDragDy = 0;
  settingsFrame.classList.add("sheet-dragging");
});
settingsFrame.addEventListener("pointermove", (e) => {
  if (sheetDragDy === null) return;
  sheetDragDy = Math.max(0, e.clientY - sheetDragFrom);
  settingsFrame.style.transform = "translateY(" + sheetDragDy + "px)";
});
settingsFrame.addEventListener("pointerup", endSheetDrag);
settingsFrame.addEventListener("pointercancel", endSheetDrag);

// Anyone reading the build identity is about to retype it into a bug report.
const copySettingsVersion = async () => {
  const text = (settingsVersionEl.textContent || "").trim();
  if (!text) return;
  try {
    if (!navigator.clipboard) throw new Error("no clipboard");
    await navigator.clipboard.writeText(text);
    showToast("Copied " + text);
  } catch {
    showToast("Couldn't access the clipboard");
  }
};
settingsVersionEl.addEventListener("click", copySettingsVersion);
settingsVersionEl.addEventListener("keydown", (e) => {
  if (e.key === "Enter" || e.key === " ") { e.preventDefault(); copySettingsVersion(); }
});

const openSettingsModal = () => {
  menuDropdown.hidden = true;
  // Build identity: version.txt fetched through the SW cache = the running
  // build's commit, so a device can be matched to a deploy at a glance
  fetch("version.txt")
    .then((r) => (r.ok ? r.text() : ""))
    .then((v) => {
      settingsVersionEl.textContent = v ? "dingbat " + v.trim().slice(0, 12) : "";
    })
    .catch(() => {});
  updateBiosStatusText();
  kbSelection = -1;
  kbPreset.value = detectPreset(activeBindings);
  renderKbBindings();
  // Fresh open starts with Advanced folded (defined below the modal helpers;
  // guarded for the pre-parse window, as the menu does for Capture)
  if (typeof collapseAdvanced === "function") collapseAdvanced();
  // Reopen where they were. A large part of the old friction was people
  // re-finding the section they had just been in; on the sheet that means
  // opening ON the section, with the list one back-tap away.
  let last = null;
  try { last = localStorage.getItem(SETTINGS_LAST_KEY); } catch {}
  selectSettingsTab(last || SETTINGS_SECTIONS[0]);
  settingsOnDetail = settingsIsSheet();
  applySettingsScreen();
  if (settingsOnDetail) { settingsHistPush(); settingsHistPush(); }
  settingsModal.classList.add("open");
  document.addEventListener("keydown", kbKeyHandler, true);
  trapFocus(settingsModal);
};

const closeSettingsModal = (fromHistory) => {
  kbSelection = -1;
  if (!fromHistory) settingsHistDrop(settingsHistDepth);
  settingsHistDepth = 0;
  settingsOnDetail = false;
  settingsModal.classList.remove("open");
  document.removeEventListener("keydown", kbKeyHandler, true);
  releaseFocus(settingsModal);
};

document.getElementById("open-settings").addEventListener("click", openSettingsModal);
for (const id of ["settings-close", "settings-close-list"]) {
  document.getElementById(id).addEventListener("click", () => closeSettingsModal());
}

// Force Update and Toggle Log live in Settings ▸ General ▸ Advanced now. Each
// one hands the screen to something else (the log overlay, a reload), so
// Settings has to step aside first. Registered here, ahead of each button's
// own handler further down the file, so the close happens before the takeover.
for (const id of ["force-update", "show-log"]) {
  document.getElementById(id).addEventListener("click", () => closeSettingsModal());
}

// Advanced is a disclosure, and it refolds on every open of Settings rather
// than remembering: nobody opens Settings wanting it, so its resting state is
// the only one worth persisting.
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
// JS owns the cheat list (array of {name, codes, enabled, error}); the Nim
// core owns the parsed/applied form. On any edit we serialize to the shared
// ".cht" text format, push it into the core via load_cheats (which returns
// parse errors), and persist it per-game in IndexedDB under
// "cheats:<originalName>". Adds are validated up front (a cheat that doesn't
// parse is rejected, never inserted); `error` is only ever non-empty on
// entries persisted by older builds, whose rows are badged "Invalid".

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

// Probe-parse one cheat by itself. Core parsing is per-cheat and all-or-nothing
// within a cheat (any bad line fails that whole cheat, other cheats are
// unaffected), so parsing the candidate alone gives the same verdict it would
// get inside the full list. load_cheats REPLACES the core's cheat set, so the
// caller must re-push the real list afterwards.
const validateCheat = (c) => {
  const err = pushCheatsToCore(serializeCheats([c]));
  // The core prefixes each error with the cheat's name; next to the form (or
  // row) that named the cheat, the prefix is noise — strip it.
  const prefix = (c.name || "?") + ": ";
  return err.startsWith(prefix) ? err.slice(prefix.length) : err;
};

// The error line under the add form. It only ever describes the add form's
// current text: it is set when an add is rejected and cleared as soon as the
// user edits the inputs or an add succeeds.
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
      // Entries persisted by older builds could be saved without validation;
      // the core skips them, so say so instead of showing a dead checkbox.
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
    // Every entry was validated when it was added (or badged by restoreCheats),
    // so this can't produce new errors — and any legacy invalid entry is
    // already marked on its row, not under the add form. The core skips
    // entries it can't parse.
    pushCheatsToCore(text);
    if (cheatList.length) await dbPut(CHEATS_KEY(currentOriginalName), text);
    else await dbDelete(CHEATS_KEY(currentOriginalName));
  }
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
  // Entries saved by builds that accepted unvalidated adds may not parse;
  // probe each one so its row can be badged "Invalid".
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
    // Reject the add outright: the list stays untouched (re-push its copy —
    // the probe replaced the core's set) and the user's text stays in the
    // form so it can be fixed in place.
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

// A rejected add's error describes the form's current text; clear it the
// moment that text changes.
cheatNameEl.addEventListener("input", () => showCheatError(""));
cheatCodesEl.addEventListener("input", () => showCheatError(""));

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

// Like makeDisabledButton, but still tappable: mobile has no hover, so a
// truly disabled button can't explain itself there. Greyed via .is-inert,
// the reason doubles as the desktop tooltip and a toast on tap.
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

// THE inventory of everything this app stores for ONE game. Every destructive
// path below works from this function and nothing else, so a per-game record
// added later is deleted by all of them the moment it is listed here — and a
// record that is NOT listed here is, by construction, a record that survives a
// delete and haunts the user (that is exactly how the auto-resume snapshot
// came to outlive its game and keep offering "Resume").
//
// The groups exist because the two destructive paths take different subsets:
//   bytes    ROM image + box art. Bulk, and the ROM is re-downloadable from
//            Drive, which is what makes "Remove from device" safe at all.
//   saves    battery saves (P1 + the 2P link partner's) and the nine manual
//            save-state slots with their thumbnails. Irreplaceable user
//            progress, and the only group Drive mirrors besides the ROM.
//   session  the auto-resume snapshot. A full save state, but captured behind
//            the user's back on every tab switch and re-made next session;
//            never synced. Disposable by design.
//   prefs    per-game settings the user typed in — currently the cheat list.
//            Bytes, never synced, so dropping it can only lose work and can
//            never free space worth having.
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

// Flattened: everything, i.e. what "this game is gone" means on this device.
const allPerGameKeys = (name) => Object.values(perGameKeys(name)).flat();

const deleteKeys = async (keys) => {
  for (let k of keys) await dbDelete(k);
};

// Remove all stored save data for one ROM: both battery saves, all nine
// save-state slots with their thumbnails, and the auto-resume snapshot. The
// snapshot has to go with them — it is itself a full save state, so leaving it
// behind lets a one-tap "Resume" drop the player straight back into the
// progress they just asked us to wipe.
const deleteSaveData = async (name) => {
  let k = perGameKeys(name);
  await deleteKeys([...k.saves, ...k.session]);
};

// Remove every trace of one game from THIS device — the ROM, its art, all save
// data, the resume snapshot, the cheats. Drive is untouched here; the callers
// decide whether only this device is forgetting the game (a tombstone that
// arrived from another device) or all of them (deleteGameEverywhere).
const deleteGameLocalData = async (name) => {
  await deleteKeys(allPerGameKeys(name));
};

// Wipe the running game's battery save and reboot it as a fresh cartridge. The
// save-state slot is left untouched — it's managed separately by the modal's
// Export/Import state actions.
const resetCurrentSaveFile = async () => {
  if (!currentOriginalName) return;
  await dbDelete("save:" + currentOriginalName);
  await dbDelete("save:" + currentOriginalName + "-p2");
  // The auto-resume snapshot holds the very progress we just erased, and the
  // reboot below ends in offerAutoResume — without this, "Save reset — starting
  // fresh" is followed immediately by an offer to un-reset it. Manual slots
  // still survive on purpose (Export/Import state manages those).
  await deleteKeys(perGameKeys(currentOriginalName).session);
  // Mirror rule: a local save deletion propagates to Drive (no-op if not synced).
  markDelete("save:" + currentOriginalName);
  markDelete("save:" + currentOriginalName + "-p2");
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
// The intro's Remove sentence — hidden while signed out, when the per-row
// Remove button it describes doesn't render (see romOnDrive below).
const romsHintRemove = document.getElementById("roms-hint-remove");
// Sign-in state the rows were last rendered under, so renderGdriveSection can
// re-render them only when that state actually flips (a routine repaint must
// not disarm a row's armed confirm button).
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

// How the manage list is ordered. "recent" is the play order the grid uses;
// "alpha" is for auditing a long library, where recency tells you nothing about
// where a given game sits.
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

// Ordered rows for the manage list: recents first (already most-recent-first),
// then orphaned save-only games sorted by name. { name, inRecent }.
// Under "alpha" the two groups merge into one A–Z list, since the recent /
// orphan split is only meaningful when the order is recency.
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

// The rename affordance, one per row. Stroked with currentColor so it takes
// the button's own colour (and its hover/disabled states) rather than carrying
// a palette of its own.
const PENCIL_ICON =
  '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">' +
  '<path d="M4 20.5h4.2L19 9.7a2.4 2.4 0 0 0-3.4-3.4L4.8 17.1v3.4z"/>' +
  '<path d="M14.3 7.6l3.4 3.4"/></svg>';

const refreshRomsManageList = async () => {
  if (!db) return;
  romsRowsSignedIn = driveLinked();
  // Keep the intro copy and the rows telling the same story: signed out there
  // is no Remove button, so the sentence describing it goes too.
  romsHintRemove.hidden = !driveLinked();
  let rows = await romsForManagement();
  // A remote-only entry (on Drive, nothing stored here) has no local save to
  // Reset — it's "just deletable", so those rows show only Delete. Work out
  // what this device actually holds.
  let keys = await dbKeys();
  let localRoms = new Set();
  for (let k of keys) {
    if (typeof k === "string" && k.startsWith("rom:")) localRoms.add(k.slice(4));
  }
  let withSaves = new Set(await romsWithSaveData());
  romsManageList.innerHTML = "";
  romsManageEmpty.hidden = rows.length > 0;
  syncRomsSortButton();
  // Sorting an empty or single-game list is noise.
  if (romsSortBtn) romsSortBtn.parentElement.hidden = rows.length < 2;

  for (let { name, inRecent } of rows) {
    let row = document.createElement("div");
    row.className = "roms-manage-row";

    // A live 2P link has two cores writing this ROM's saves; deleting under it
    // would corrupt state, so both actions are blocked until link mode exits.
    // Renaming is blocked for the same reason — it moves those same saves.
    let linkRunning = linkMode && linkRomEntry && linkRomEntry.name === name;

    // The name, and the pencil that renames it. This wrapper keeps the row's
    // first child, the .roms-manage-name class and the full-name title exactly
    // where they were: the title is how the rest of the app identifies a row.
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
    // An icon-only control with no text of its own; the accessible name says
    // which game it belongs to, since a list of them is otherwise identical.
    renameBtn.setAttribute("aria-label", "Rename " + displayName(name));
    renameBtn.innerHTML = PENCIL_ICON;
    // A game whose bytes are only on Drive can't be renamed here: the rename
    // would have to delete the remote files and re-upload them under the new
    // name, and this device has nothing to re-upload. Sync it down first —
    // which is the button sitting on this very row.
    let romHere = localRoms.has(name);
    if (linkRunning) {
      renameBtn.disabled = true;
      renameBtn.title = "Exit link mode to rename this game";
    } else if (driveLinked() && !romHere) {
      renameBtn.disabled = true;
      renameBtn.title = "Sync this game to this device before renaming it";
    } else {
      renameBtn.title = "Rename this game and everything saved with it";
      renameBtn.addEventListener("click", () => openRenameModal(name));
    }
    label.appendChild(renameBtn);
    row.appendChild(label);

    let actions = document.createElement("div");
    actions.className = "roms-manage-actions";

    // The single-player game currently in memory (running or paused at home)
    // needs no special-casing for "Delete Everything" anymore: its confirm
    // handler unloads the game first via unloadGame(), which detaches it from
    // the autosave flush before the stored save is deleted.

    // Buttons in a row coordinate: arming one disarms any other still armed.
    let siblings = [];
    const disarmOthers = (except) => {
      for (let b of siblings) if (b !== except && b.disarm) b.disarm();
    };

    // Reset  = wipe this game's save data, keep the ROM.
    // Remove from device = free this device's ROM bytes, keep the save data
    //          and the Drive copy; the game becomes a Drive-only tile. Needs a
    //          Drive copy to come back from, so it is gated hard — see below.
    // Sync to device = the inverse of Remove: pull a Drive-only game's ROM
    //          and saves onto this device (same path as the grid's download
    //          glyph). Drive-only rows only, signed in only.
    // Delete = remove the game outright (ROM + save data).
    // When signed in these mirror to Drive (Delete also tombstones the game so
    // every device drops it); signed out they are purely local.
    // Reset renders on EVERY row — a row whose action set shifts with sync
    // minutiae reads as a bug — but it only arms when there is something to
    // wipe: local save data, or (signed in) save/state files recorded in the
    // last Drive listing. Otherwise it sits greyed with the reason.
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
            // Reboot the loaded game clean, else its in-memory save re-flushes.
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

    // Remove = free THIS device's copy of the ROM and leave the game in the
    // Drive library — the inverse of the grid's download glyph. Three
    // conditions, all required, because getting this wrong destroys someone's
    // only copy of a game:
    //   1. signed in to Drive — otherwise there is nowhere to re-download from
    //      and this is just a silent delete;
    //   2. the bytes are actually here — nothing to free otherwise, and a
    //      Drive-only row already offers Download in the grid instead;
    //   3. Drive has the ROM — sigs["rom:<name>"] is this device's record of
    //      having put exactly these bytes on Drive (written on upload AND on
    //      download), and nothing queued to delete them again.
    // (3) is what makes the dangerous case unreachable: a game imported a
    // moment ago whose upload is still sitting in queueUp has no sig, so it
    // gets no button at all. You cannot evict what exists only here. The sig
    // can still go stale (wiped app folder, different account), so
    // removeGameFromDevice re-checks the live Drive listing before deleting.
    let romOnDrive = driveLinked() && !!syncState.sigs[romKey(name)] &&
      !syncState.queueDel.includes(romKey(name));
    let freeBtn = null;
    if (localRoms.has(name) && driveLinked() && !romOnDrive) {
      // Signed in but Drive can't be confirmed to hold this ROM (upload still
      // queued or failing, imported while signed out, lost sig). Locality
      // decides the SLOT — a local row always shows Remove — but eligibility
      // shows as a greyed button with the reason, not a silent absence.
      freeBtn = makeInertButton(
        "Remove from device",
        "button button-sm roms-manage-btn",
        "Not backed up to Drive yet — removing now would delete your only copy",
      );
      siblings.push(freeBtn);
    } else if (localRoms.has(name) && romOnDrive) {
      if (isRomLoaded(name)) {
        // Covers link mode too (isRomLoaded folds linkRomEntry in). Unlike
        // Delete we don't unload the game for the user: "free some space" is
        // no reason to close what they're playing.
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

    // Sync to device = downloadGame, the same pull the home grid's download
    // glyph does. Not a confirm button — it destroys nothing — but clicking
    // it disarms any armed sibling so a half-armed Delete can't linger.
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

    // Order: the two save-data actions first (Reset, Delete), then the
    // device-transfer action (Remove from device / Sync to device) last.
    if (saveBtn) actions.appendChild(saveBtn);
    actions.appendChild(allBtn);
    if (freeBtn) actions.appendChild(freeBtn);
    if (downBtn) actions.appendChild(downBtn);
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

// The OAuth client ID below is PUBLIC BY DESIGN and safe in source: this is
// the GIS token (implicit) flow, which has no client secret. What actually
// protects the client is the "Authorized JavaScript origins" allowlist in the
// Cloud Console — a token is only ever issued to a page served from a
// registered origin — plus the drive.appdata scope, which can reach nothing
// but this app's own hidden folder.
//
// Adding a new origin (each deployment, and each dev port):
//   console.cloud.google.com → Google Auth Platform → Clients → this client →
//   Authorized JavaScript origins. Scheme + host (+ port), no path, no
//   trailing slash. Must be https unless it's localhost — Google rejects raw
//   IP addresses, so an http://192.168.x.x LAN origin can never work.
//   No redirect URIs are needed for the token flow.
//
// The localStorage override lets a dev point a build at a different client
// without editing source: localStorage.setItem("gdrive_client_id", "<id>").
// If this were ever emptied, the Drive section degrades to a "not configured"
// note and the GIS script is never loaded.
const GDRIVE_CLIENT_ID = localStorage.getItem("gdrive_client_id") ||
  "44914400148-bkh9oiu6ian098gbg5jecns4js5d849f.apps.googleusercontent.com";

// drive.appdata = access to the hidden app folder only (no other Drive
// files); "email" lets the UI show which account is connected (via the
// tokeninfo endpoint).
const GDRIVE_SCOPE = "https://www.googleapis.com/auth/drive.appdata email";

const GDRIVE_FILES = "https://www.googleapis.com/drive/v3/files";
const GDRIVE_UPLOAD = "https://www.googleapis.com/upload/drive/v3/files";

let gdriveToken = null;       // access token
let gdriveTokenExp = 0;       // epoch ms the access token stops being valid
let gdriveEmail = null;       // best-effort display of the signed-in account
let gdriveTokenClient = null; // GIS token client, created after script load

// Persist the access token + expiry so a reload within its lifetime (~1h)
// resumes with NO popup. The token model gives no refresh token and its
// re-grant is a gesture-gated popup, so without this every reload — and every
// app update, which force-reloads — lands signed out until the user interacts.
// The token is short-lived, scoped to drive.appdata + email, and same-origin;
// storing it beside the other Drive state is an acceptable trade for not
// dropping the session on every update.
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

// The signed-in account's email, remembered across reloads purely so re-grants
// can carry a login_hint (see gdriveAcquireToken). It is not a credential and
// it never leaves this origin except back to Google, which already knows it.
const rememberDriveEmail = (email) => {
  gdriveEmail = email || null;
  if (syncState.email === gdriveEmail) return;
  syncState.email = gdriveEmail;
  saveSyncState();
};

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

// One token request may be in flight at a time. The GIS client is a single
// object whose `callback` is overwritten per request, so two overlapping
// requestAccessToken() calls orphan the first one's popup AND leave its promise
// unsettled forever. That happened for real: a background 401 clears the token
// and paints "Sign in", the user taps it, and the window-level renewal listener
// (capture phase, so it runs first) fires a silent re-grant a beat before the
// button's own interactive one. Sharing the in-flight promise makes the second
// caller wait for the first result instead of racing it.
let gdriveTokenInFlight = null;

// Request an access token. promptMode "" = silent refresh (no UI when the
// Google session and a prior grant still stand); undefined = the normal
// account-chooser/consent popup.
//
// login_hint is the difference between "a window flashes" and "an account
// chooser appears". Google's docs are explicit that with it "account selection
// is skipped" — without it, a browser signed in to more than one Google account
// shows the chooser on EVERY re-grant, which is exactly what a user experiences
// as "it keeps making me sign in". We know the account (the email scope told us
// at connect time and it is persisted), so every renewal names it.
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
        // expires_in is seconds; keep a 60s margin so we never send a token that
        // expires mid-request.
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
  // Settled either way: the next caller starts a fresh request.
  return gdriveTokenInFlight.finally(() => { gdriveTokenInFlight = null; });
};

// A token request always opens a popup, so it can only succeed while the tab
// still holds transient user activation. Asking anyway from a background timer
// doesn't just fail — some browsers answer a refused popup with a "pop-up
// blocked" bar, i.e. the background does something visible AND useless. Where
// the browser will tell us (Chrome 72+, Safari 16.4+), don't try.
const hasUserActivation = () =>
  !navigator.userActivation || navigator.userActivation.isActive;

// Best-effort: only works because GDRIVE_SCOPE includes "email".
const gdriveFetchEmail = async () => {
  try {
    let res = await fetch(
      "https://oauth2.googleapis.com/tokeninfo?access_token=" +
        encodeURIComponent(gdriveToken),
    );
    if (res.ok) rememberDriveEmail((await res.json()).email);
  } catch {}
};

// Authenticated fetch against the Drive API. On a 401 (token expired), one
// silent re-grant is attempted and the request replayed.
//
// That re-grant only succeeds when this call chain started from a user gesture
// (the GIS popup needs transient activation). Most 401s arrive on the
// background poll instead, where it can only fail — so a failure here does NOT
// sign the user out. It drops the dead token and hands off to the gesture-armed
// renewal, which retries on the user's next tap; only after DRIVE_RENEW_MAX_FAILS
// of those does the UI fall back to signed-out.
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
      // Not "sign in again": the account is still linked and the queue is
      // still on disk. This aborts one request; the next gesture (or the next
      // Sync) picks up a token and the work drains.
      throw new Error("Drive is reconnecting — your changes are saved");
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

// Map a Drive file name back to { game, kind }; null for anything a future
// version might add. `kind` is the per-game grouping key (unique within a game)
// and self-describes both the category and, for save states, the slot: slot 0
// keeps the legacy kind ("state"/"statemeta"), slots 1..8 append ":slotN".
// Mirrors romsWithSaveData's ":slotN" and "-p2" folding so numbered save-state
// slots fold into the base game rather than becoming phantom "game" rows.
const parseDriveFileName = (n) => {
  if (n.startsWith("rom:")) return { game: n.slice(4), kind: "rom" };
  // Check "statemeta:" before "state:" for clarity (they don't actually
  // collide: "statemeta:"[5] is 'm', so it fails startsWith("state:")).
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

// --- Drive section UI (rendered into #gdrive-body in the roms modal) ---

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
  // Stand down background sync. Queued work stays on disk rather than being
  // dropped: sign back in and it flushes then.
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
  // The manage rows and the intro's Remove sentence are sign-in gated too:
  // every path that morphs this section between "Sign in with Google" and the
  // connected view (sign-in, Sign out, token expiry) lands here, so an open
  // modal re-renders its rows on a real state flip — and only on a flip, so
  // routine repaints can't disarm an armed confirm button.
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
    // No sub-caption here: the static hint right above this section already
    // says exactly what signing in does — repeating it read as a glitch.
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
  // Linked but between access tokens is NOT signed out — the account, the
  // library and the queue are all still here, and the next Sync (or the next
  // tap anywhere) buys a token. Saying "Sign in with Google" at that moment is
  // what made an hourly token rollover feel like being logged out.
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
// Google Drive SYNC
// ----------------------------------------------------------------------------
// Signing in IS turning sync on — there is no mode, no opt-in prompt. Signed
// out, none of this runs and the app behaves exactly as it always has.
//
// The library (which games exist, and which were deleted) lives in ONE Drive
// file, "library":
//     { recents: [{ name, ts }], tomb: [{ name, ts }] }
// `recents` is the merged cross-device play history — it drives the home grid,
// so the grid is your library across every device. `tomb` are tombstones:
// games explicitly deleted, recorded so a plain union-merge can't resurrect
// them. Re-uploading a game clears its tombstone (re-upload supersedes).
//
// ROMs are NEVER bulk-downloaded. A merged-recents entry whose rom: record is
// missing locally renders as a "Drive-only" tile with a download affordance;
// tapping it fetches that one game (ROM + its saves/states) on demand.
//
// Uploads are queued and coalesced: a dirty event (ROM import, truly-dirty
// save, save-state write/delete, delete) pushes a key onto a PERSISTED queue,
// flushed 2s after the last change and at most 10s after the first — so
// hammering save states costs one upload of the final state, and a queue that
// couldn't be sent (offline, reload) survives to the next opportunity.
// ============================================================================

const LIBRARY_FILE = "library";
const SYNC_DEBOUNCE_MS = 2000;   // quiet period before a flush
const SYNC_MAX_WAIT_MS = 10000;  // ...but never sit on changes longer than this
const SYNC_POLL_MS = 3 * 60 * 1000;

// Persisted under "gdrive_sync". queueUp/queueDel/tomb survive reloads so an
// offline edit still reaches Drive later. sigs = last agreed content signature
// per Drive file; rmt = the remote modifiedTime we last saw for it.
let syncState = { queueUp: [], queueDel: [], tomb: [], sigs: {}, rmt: {}, email: null };
let syncBusy = false;
let syncTimer = null;
let syncCapTimer = null;
let syncPollTimer = null;
let syncDoneTimer = null;
// Games currently being pulled on demand (drives the per-tile spinner).
let syncDownloading = new Set();

const loadSyncState = async () => {
  let s = await dbGet("gdrive_sync");
  if (s && typeof s === "object") {
    syncState = {
      queueUp: Array.isArray(s.queueUp) ? s.queueUp : [],
      queueDel: Array.isArray(s.queueDel) ? s.queueDel : [],
      tomb: Array.isArray(s.tomb) ? s.tomb : [],
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

// Two different questions, and conflating them was the source of most of the
// "it keeps signing me out" feeling:
//
//   driveLinked()  — has the user connected Drive at all? Survives token
//                    expiry, reloads, being offline. This is what the UI and
//                    the upload queue key off, so an hour-old access token
//                    changes nothing the user can see.
//   syncActive()   — can we talk to the Drive API *right now*? Only true with
//                    a live access token, so it gates actual network work.
//
// A token gap is therefore a quiet, recoverable state: changes keep queueing,
// the library keeps showing its Drive games, and the re-grant happens on the
// next gesture (or lazily, when the user asks for something that needs Drive).
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
// Drive file names ARE the IndexedDB keys, so parseDriveFileName classifies
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
// Does this device hold the ROM bytes for a game?
const hasLocalRom = async (game) => !!(await dbGet(romKey(game)))?.data?.length;
// Any local trace of a game at all (ROM or save data)?
const hasLocalData = async (game) => (await localFilesForGame(game)).length > 0;

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

const driveListMap = async () =>
  new Map((await driveListAll()).map((f) => [f.name, f]));

// --- The shared library file (merged recents + tombstones) ----------------
const readDriveLibrary = async (remote) => {
  let f = remote.get(LIBRARY_FILE);
  if (!f) return { recents: [], tomb: [] };
  try {
    let bytes = await driveDownload(f.id);
    let o = JSON.parse(new TextDecoder().decode(bytes));
    return {
      recents: Array.isArray(o.recents) ? o.recents : [],
      tomb: Array.isArray(o.tomb) ? o.tomb : [],
    };
  } catch { return { recents: [], tomb: [] }; }
};
const writeDriveLibrary = async (lib, remote) => {
  let bytes = new TextEncoder().encode(JSON.stringify(lib));
  await driveUploadFile(LIBRARY_FILE, bytes, remote.get(LIBRARY_FILE)?.id);
};

// Union by name keeping the newest timestamp, then drop anything tombstoned
// more recently than the entry itself (a re-upload bumps ts, so it wins).
const mergeLibrary = (a, b) => {
  let byName = new Map();
  for (let e of [...(a.recents || []), ...(b.recents || [])]) {
    if (!e?.name) continue;
    let prev = byName.get(e.name);
    if (!prev || (e.ts || 0) > (prev.ts || 0)) byName.set(e.name, { name: e.name, ts: e.ts || 0 });
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
  };
};

const localLibrary = async () => ({
  recents: (await getRecentMeta()).filter((r) => r?.name),
  tomb: syncState.tomb.slice(),
});

// --- Sync status indicator (lives in the retired status-LED slot) ---------
// Deliberately subtle: muted text colour, never the accent (that's the HLE
// indicator's job). Desktop shows icon + word; phones show the icon alone and
// reveal the wording on tap.
const SYNC_ICONS = {
  syncing: '<svg class="sync-spin" viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v3.5h-3.5"/></svg>',
  done: '<svg viewBox="0 0 24 24"><path d="M20 6L9 17l-5-5"/></svg>',
  // A COMPLETE cloud plus a slash. The usual "cloud-off" glyph omits the
  // cloud's right shoulder so the slash can pass through, which just reads as
  // a broken shape at 15px.
  offline: '<svg viewBox="0 0 24 24"><path d="M17.5 18.5H7.2A4.2 4.2 0 0 1 6.5 10.1a5.8 5.8 0 0 1 11.1 1 3.8 3.8 0 0 1-.1 7.4z"/><path d="M4.5 4.5l15 15"/></svg>',
};
// Same cloud-with-a-slash: from the user's side "no connection" and "no token"
// are the same fact — Drive is out of reach and their changes are waiting.
SYNC_ICONS.paused = SYNC_ICONS.offline;
const SYNC_WORDS = { syncing: "Syncing", done: "Synced", offline: "Offline",
                     paused: "Paused" };
const SYNC_DESCS = {
  syncing: "Syncing your games with Google Drive…",
  done: "All changes are synced to Google Drive",
  offline: "Offline — your changes will sync when you reconnect",
  // Linked, online, but out of access token and out of silent retries. Said
  // once, quietly, instead of a sign-in prompt: nothing is lost, and tapping
  // Sync (or the indicator) is all it takes.
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
  // Label first, icon last: this sits in the right-aligned cluster, so keeping
  // the icon outermost holds it still as the word changes length.
  syncIndicator.innerHTML =
    '<span class="sync-label">' + SYNC_WORDS[s] + "</span>" + SYNC_ICONS[s];
};
// "Synced" is a momentary confirmation, not a permanent badge.
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
  // Phones hide the word; tapping explains what the icon means.
  syncIndicator.addEventListener("click", () => {
    if (syncStatus !== "idle") showToast(SYNC_DESCS[syncStatus]);
  });
}
const pendingCount = () => syncState.queueUp.length + syncState.queueDel.length;
// Pending and in-flight both read as "Syncing" — a bare number confuses more
// than it informs, especially icon-only on a phone.
const refreshSyncStatus = () => {
  if (!driveLinked()) { setSyncStatus("idle"); return; }
  // Out of token AND out of silent retries: stop claiming to be syncing.
  if (!syncActive() && driveRenewFails >= DRIVE_RENEW_MAX_FAILS && pendingCount()) {
    setSyncStatus("paused");
    return;
  }
  if (syncBusy || pendingCount()) setSyncStatus("syncing");
  else if (syncStatus === "syncing") setSyncStatus("done");
  else renderSyncIndicator();
};

// --- Dirty queue ---------------------------------------------------------
// Queueing is keyed off driveLinked(), not a live token: a save made while the
// access token is between grants must still reach Drive later. (flushSync
// itself still requires a token — it just finds the work waiting when one
// arrives.) Before this, an expired token meant those writes were silently
// never queued, and only a manual full sync ever noticed.
const scheduleFlush = () => {
  if (!driveLinked()) return;
  if (syncTimer) clearTimeout(syncTimer);
  syncTimer = setTimeout(flushSync, SYNC_DEBOUNCE_MS);
  // First change in a burst arms the ceiling so a busy stretch still lands.
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
// Mirror a local save-data wipe to Drive. Only the "saves" group: the resume
// snapshot deleted alongside it locally was never uploaded (parseDriveFileName
// rejects "stateauto:"), so there is nothing on Drive to delete.
const queueSaveDataDeletes = (name) => {
  for (let k of perGameKeys(name).saves) markDelete(k);
};

// Drive operations run one at a time, but a busy engine must DEFER work, never
// drop it. An earlier version returned early while another op was in flight,
// which raced on mobile: returning from the sign-in sheet fires
// visibilitychange, whose flush+pull collided with gdriveConnect's own
// runFullSync, and whichever lost silently skipped its push or its pull — so a
// freshly signed-in phone showed an empty grid until the 3-minute poll bailed
// it out. Queueing instead makes sign-in deterministic.
let syncChain = Promise.resolve();
const runExclusive = (fn) => {
  const run = syncChain.then(() => fn());
  syncChain = run.catch(() => {}); // a failed op must not poison the chain
  return run;
};
// One pending pull is enough; extra triggers while one is queued collapse.
let pullQueued = false;

// Push the queue. Anything that fails stays queued for the next attempt, so a
// dropped connection degrades to "syncs later" rather than losing data.
const flushSync = (...a) => {
  // Disarm at call time, not when the queued flush finally runs — otherwise a
  // flush waiting behind a long pull leaves the debounce armed and re-queues.
  if (syncTimer) { clearTimeout(syncTimer); syncTimer = null; }
  if (syncCapTimer) { clearTimeout(syncCapTimer); syncCapTimer = null; }
  return runExclusive(() => flushSyncInner());
};
const flushSyncInner = async () => {
  if (!syncActive()) return;
  if (!pendingCount() && !syncState.tomb.length) { refreshSyncStatus(); return; }
  syncBusy = true;
  setSyncStatus("syncing");
  try {
    let remote = await driveListMap();
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
        // The listing is the truth about what Drive holds; sigs only remember
        // what THIS device once uploaded. A queued file that's missing
        // remotely uploads regardless of its sig — otherwise a wiped app
        // folder or a different signed-in account never receives it. When
        // the file IS present: ROMs are immutable (presence is enough) and
        // anything else re-uploads only when its bytes changed.
        if (!r || (!name.startsWith("rom:") && sig !== syncState.sigs[name])) {
          await driveUploadFile(name, bytes, r?.id);
          syncState.sigs[name] = sig;
        }
      }
      syncState.queueUp = syncState.queueUp.filter((n) => n !== name);
    }
    // Publish the library (recents + any tombstones raised locally).
    let lib = mergeLibrary(await readDriveLibrary(remote), await localLibrary());
    await writeDriveLibrary(lib, await driveListMap());
    syncState.tomb = lib.tomb;
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

    // Tombstones: anything deleted elsewhere that this device still holds.
    let pending = [];
    for (let t of lib.tomb) if (await hasLocalData(t.name)) pending.push(t.name);
    if (pending.length) {
      let keep = await confirmTombstones(pending);
      if (keep === "restore") {
        // Un-delete: drop the tombstones and re-upload what we still have.
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
          // Same local wipe Delete performs — a game deleted on another device
          // must not leave its cheats or resume snapshot behind here either.
          await deleteGameLocalData(g);
          gridDirty = true;
        }
      }
    }

    // Pull saves/states for games this device actually holds (progress sync).
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

    // Reconcile upward: queue anything this device holds that the listing
    // lacks. sigs only remember what was once uploaded — if the app folder
    // was wiped or a different account signed in, every local game is
    // "already synced" by sig yet absent from Drive, and nothing would ever
    // re-upload it. Tombstoned games stay deleted.
    for (let [name, p] of local) {
      if (remote.has(name)) continue;
      if (lib.tomb.some((t) => t.name === p.game)) continue;
      if (!syncState.queueUp.includes(name)) {
        syncState.queueUp.push(name);
        queuedMissing = true;
      }
    }

    // Adopt the merged library locally.
    syncState.tomb = lib.tomb;
    // The merged library is the grid — do NOT cap it at MAX_RECENT, or every
    // game past the 20th silently vanishes with no way to see or download it.
    // MAX_RECENT still bounds how many ROMs this device keeps bytes for
    // (bumpRecentIndex), which just turns the rest into Drive-only tiles.
    await dbPut("recent", lib.recents);
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
  // Queued-missing files flush on the normal debounce (after syncBusy clears
  // — flushes are serialized behind this pull anyway).
  if (queuedMissing) scheduleFlush();
  if (gridDirty) refreshHomeRecent();
};

// Sign-in / manual "Sync now": push everything local, then pull.
const runFullSync = async ({ label } = /** @type {{label?: string}} */ ({})) => {
  if (!syncActive()) return;
  // Queue every local file so a first sign-in backs the device up.
  let names = [...(await localSyncFiles()).keys()];
  for (let n of names) if (!syncState.queueUp.includes(n)) syncState.queueUp.push(n);
  await saveSyncState();
  await flushSync();
  await pullSync({ silent: false });
};

// --- On-demand download of one Drive-only game ---------------------------
const downloadGame = async (game) => {
  // Called straight from a tap in the manage list as well as behind the home
  // tile's own ensureDriveSignedIn, so it re-auths for itself: a token that
  // aged out between opening the modal and pressing the button must not turn
  // into "sign in first". An account that was never linked still is refused —
  // there is nothing on Drive to fetch.
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
// Frees this device's copy of a game's ROM (plus the two things that are only
// meaningful while those bytes are here: the box art and the auto-resume
// snapshot). Nothing leaves Drive: no tombstone, no Drive delete, and the
// recents entry stays put, so the game keeps its place in the merged library
// and simply re-renders as a Drive-only tile that one tap brings back. That is
// the whole difference from deleteGameEverywhere, which raises a tombstone
// precisely so every OTHER device drops the game too.
//
// Save data is deliberately KEPT. It is kilobytes next to a multi-megabyte
// ROM, so it isn't what a user reclaiming space came for, and it is the one
// thing here that can be irreplaceable — a battery save that hasn't reached
// Drive yet would be gone for good, with no "download it again". Keeping it
// also matches the MAX_RECENT eviction rule (bumpRecentIndex has always
// dropped ROM bytes and never saves), and what's left is still wipeable from
// this same row via Reset. On the way out we queue the leftovers for upload,
// so the copy that stays behind is also a copy Drive has.
const removeGameFromDevice = async (game) => {
  if (!driveLinked()) { showToast("Sign in to Google Drive first"); return false; }
  if (!(await ensureDriveSignedIn())) return false;
  // Never take the last copy. The button is already gated on this device's
  // record of the upload (syncState.sigs), but that record can lie: a wiped
  // app folder, or a different Google account signed in, leaves stale sigs
  // pointing at files Drive no longer holds. The live listing is the only
  // authority, so re-check it here, immediately before the bytes go — and if
  // the ROM genuinely isn't backed up, back it up instead of deleting it.
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
  // bytes + session. The resume snapshot goes with the ROM because it is a
  // snapshot OF that ROM: with the bytes gone the game can't be launched, so
  // the only thing it can do here is sit there weighing as much as a save state
  // until the game is downloaded again — at which point the battery save we
  // kept resumes the player anyway. Everything irreplaceable (both battery
  // saves, all nine manual slots, the cheat list) stays; see the group comment
  // on perGameKeys and the long note above.
  let keys = perGameKeys(game);
  await deleteKeys([...keys.bytes, ...keys.session]);
  markGameUpload(game); // the ROM is gone, so this queues the saves we kept
  return true;
};

// --- Deletion (Manage ROMs) ----------------------------------------------
// Reset = wipe save data, keep the ROM. Delete = remove the game entirely and
// tombstone it so every device drops it. Both are local-only when signed out.
const resetGameSaves = async (game) => {
  await deleteSaveData(game);
  if (driveLinked()) queueSaveDataDeletes(game);
};
const deleteGameEverywhere = async (game) => {
  await deleteGameLocalData(game);
  await dbPut("recent", (await getRecentMeta()).filter((r) => r.name !== game));
  if (driveLinked()) {
    // Queue the whole inventory: markDelete drops anything Drive doesn't hold
    // (parseDriveFileName rejects art:/stateauto:/cheats:), so passing every
    // key means a per-game record added to perGameKeys later starts mirroring
    // its deletion the day it starts syncing, with no second list to update.
    for (let n of allPerGameKeys(game)) markDelete(n);
    syncState.tomb = syncState.tomb.filter((t) => t.name !== game);
    syncState.tomb.push({ name: game, ts: Date.now() });
    await saveSyncState();
    scheduleFlush();
  }
};

// --- Rename (Manage ROMs) -------------------------------------------------
// A game's name is not a label on this record — it IS the record's address.
// Every key in perGameKeys is built from it, the Drive file names are those
// same keys one-for-one, the recents index refers to the game by name, and a
// printed photo carries the name of the game that printed it. So a rename is a
// migration of the whole record, and the only honest shape for it is
// all-or-nothing: dbMoveKeys does the lot in one IndexedDB transaction.

// Long enough for any real title, short enough that the name still fits an
// export file name and a Drive listing row.
const RENAME_MAX_LEN = 100;

// Split a stored name into the part the user may edit and the extension we
// keep for them. The extension is not up for editing: it decides the system
// (systemOf), the file loadRom writes into the Emscripten FS, and the name of
// an exported save — retyping it wrongly would silently turn a GBA game into a
// Game Boy one. Kept verbatim (not extOf's lowercased form) so "ZELDA.GB"
// stays "ZELDA.GB".
const splitRomName = (name) => {
  let s = String(name);
  let i = s.lastIndexOf(".");
  return i > 0 ? { base: s.slice(0, i), ext: s.slice(i) } : { base: s, ext: "" };
};

// Every name the library already knows: the recents index (which includes
// Drive-only games) plus any game whose save data outlived its entry. This is
// the set a rename must not land on.
const libraryNames = async () => {
  let s = new Set();
  for (let r of await getRecentMeta()) if (r?.name) s.add(r.name);
  for (let n of await romsWithSaveData()) s.add(n);
  return s;
};

// What the user typed, resolved to a full stored name. Two liberties are taken
// with the input, both of them visible: it is trimmed, and a typed-out copy of
// the extension is not doubled ("Zelda.gb" while renaming a .gb game means
// "Zelda.gb", not "Zelda.gb.gb"). The confirmation screen shows the result, so
// neither happens behind the user's back.
const renameFullName = (base, oldName) => {
  let { ext } = splitRomName(oldName);
  let t = String(base).trim();
  if (ext && t.length > ext.length && t.slice(-ext.length).toLowerCase() === ext.toLowerCase()) {
    t = t.slice(0, -ext.length).trim();
  }
  return t + ext;
};

// Why this name can't be used, or null when it can. `taken` is libraryNames()
// with the game's own name removed.
const renameNameError = (base, oldName, taken) => {
  let t = String(base).trim();
  if (!t) return "Enter a name.";
  if (t.length > RENAME_MAX_LEN)
    return "Keep the name to " + RENAME_MAX_LEN + " characters or fewer.";
  if (/[\u0000-\u001f\u007f]/.test(t)) return "Names can't contain control characters.";
  if (/[/\\]/.test(t)) return "Names can't contain / or \\ — they'd break the exported file name.";
  // ":" separates a key from its slot suffix ("state:<name>:slot3"), so a name
  // containing one could parse back out as a different game.
  if (t.includes(":")) return "Names can't contain a colon.";
  let full = renameFullName(base, oldName);
  // "save:<name>-p2" is the 2P link partner's save, so a name ending in "-p2"
  // would read back as another game's link save. Only reachable when the name
  // has no extension to sit after it.
  if (full.endsWith("-p2")) return "Names can't end in “-p2” — that ending is reserved for 2-player link saves.";
  if (full === oldName) return "That's already this game's name.";
  if (taken && taken.has(full))
    return "“" + displayName(full) + "” is already in your library. Pick another name.";
  return null;
};

// What a rename would move, counted, so the confirmation can enumerate it
// instead of asking "are you sure?". Counts, not key names: what the user
// recognises is "3 save states", not "state:<name>:slot4".
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

// The user-facing lines for that inventory, most valuable first.
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

// Rename one game and everything stored with it. Returns { ok: true, moved }
// or { ok: false, error } — the error is shown verbatim, so it says what
// happened AND that nothing changed.
const renameGame = async (oldName, newName) => {
  if (!db) return { ok: false, error: "Storage isn't ready yet — try again in a moment." };
  if (oldName === newName) return { ok: false, error: "That's already this game's name." };
  // A live link/online session has a second core writing this game's saves and
  // a peer that agreed on the name; renaming under it would corrupt both.
  if (isRomLoaded(oldName) && (linkMode || rollbackMode || netActive())) {
    return { ok: false, error: "Close the link or online session before renaming this game." };
  }
  // A game whose bytes live only on Drive cannot be renamed from here, and this
  // is the guard that stops a rename from being a delete. The remote files are
  // named by the OLD key; renaming would have to delete them and upload the
  // same content under the new one — but with nothing stored on this device
  // there is nothing to upload, so the delete would take the only copy. Sync
  // the game down first (the same row offers it) and the rename is safe.
  if (driveLinked() && !(await hasLocalRom(oldName))) {
    return { ok: false, error: "Sync “" + displayName(oldName) +
             "” to this device before renaming it — its files are only on Drive." };
  }

  // Collisions are refused, never merged. Two questions, both asked: is the
  // name in the library, and does ANY record already sit under it?
  let existing = new Set((await dbKeys()).filter((k) => typeof k === "string"));
  let taken = await libraryNames();
  if (taken.has(newName) || allPerGameKeys(newName).some((k) => existing.has(k))) {
    return { ok: false,
             error: "“" + displayName(newName) + "” already exists in your library. Nothing was changed." };
  }

  // The game in memory: flush whatever it has pending under the OLD name, then
  // detach it. With currentOriginalName null every write path (the 5s autosave,
  // the tab-switch snapshot, the cheat list, the state slots) skips this game,
  // so nothing can re-create an old key behind the transaction's back — and
  // nothing can land on a new key before the transaction claims it, which
  // would abort the move as a collision.
  let loaded = isRomLoaded(oldName) && !!currentRomName;
  if (loaded) {
    await persistSave(currentRomName, oldName);
    currentOriginalName = null;
  }

  // Records that are not per-game keys but do name the game. All written in
  // the same transaction as the move, so the pointers can never disagree with
  // the data they point at.
  let puts = [];

  // The library index. The renamed entry goes to the front with a fresh
  // timestamp rather than keeping its place, and that is a correctness
  // requirement, not a flourish: mergeLibrary drops any entry older than a
  // tombstone of the same name, so a new name that some other device once
  // deleted would vanish from the merged library (and its tombstone would
  // offer to delete the freshly renamed game) unless this entry outranks it.
  let recents = await getRecentMeta();
  if (recents.some((r) => r?.name === oldName)) {
    let list = recents.filter((r) => r?.name !== oldName);
    list.unshift({ name: newName, ts: Date.now() });
    puts.push(["recent", list]);
  }

  // Printed photos carry the name of the game that printed them (it names the
  // exported PNG), so they are re-tagged rather than left pointing at a game
  // that no longer exists.
  let prints = await dbGet(PRINTER_PHOTOS_KEY);
  if (Array.isArray(prints) && prints.some((p) => p?.game === oldName)) {
    puts.push([PRINTER_PHOTOS_KEY,
               prints.map((p) => (p?.game === oldName ? { ...p, game: newName } : p))]);
  }

  // The move list. Every per-game key is offered, not only the ones that exist:
  // dbMoveKeys skips a source that holds nothing, and reading the truth inside
  // the transaction beats trusting a list taken before it.
  let fromKeys = allPerGameKeys(oldName);
  let toKeys = allPerGameKeys(newName);
  let pairs = fromKeys.map((k, i) => [k, toKeys[i]]);

  // Drive. The remote file names ARE these keys, and Drive has no rename we
  // could mirror, so the correct remote consequence of a local rename is
  // exactly: delete the files under the old names, upload the files under the
  // new ones, and tombstone the old game name so the other devices drop it
  // (their library entry for the old name would otherwise come back on the
  // next merge and re-download a game that no longer exists here).
  //
  // Both queues are written INSIDE the move transaction. That is what makes a
  // tab closed mid-rename safe: the bytes and the record of what still has to
  // happen to them commit together, so there is no instant where the data has
  // moved and Drive doesn't know, or vice versa. Nothing is ever deleted
  // remotely before the local copy is durable under its new name, and a
  // failed flush leaves both queue entries in place for the next attempt.
  let nextSync = null;
  if (driveLinked()) {
    // Only files this device actually holds. A remote file with no local
    // counterpart cannot be re-uploaded under the new name, so queueing its
    // deletion would destroy the only copy — the one asymmetry that matters
    // here. Erring the other way merely orphans a file on Drive, and pullSync's
    // reconcile-upward pass re-queues any upload this misses.
    let mirrored = pairs.filter(([f]) => !!parseDriveFileName(f) && existing.has(f));
    let oldKeys = mirrored.map(([f]) => f);
    let newKeys = mirrored.map(([, t]) => t);
    let sigs = { ...syncState.sigs };
    let rmt = { ...syncState.rmt };
    // These record what Drive holds under the OLD names; they die with them.
    // Nothing is copied to the new names — Drive has never seen those, and
    // claiming otherwise is how an upload gets skipped.
    for (let k of oldKeys) { delete sigs[k]; delete rmt[k]; }
    nextSync = {
      ...syncState,
      sigs,
      rmt,
      // Old names out, new names in. The flush deletes before it uploads, and
      // that is safe here precisely because every queued delete has a local
      // copy behind it: the bytes are already durable under the new name
      // before the first request goes out.
      queueDel: [
        ...syncState.queueDel.filter((n) => !newKeys.includes(n)),
        ...oldKeys.filter((n) => !syncState.queueDel.includes(n)),
      ],
      queueUp: [
        ...syncState.queueUp.filter((n) => !oldKeys.includes(n)),
        ...newKeys.filter((n) => !syncState.queueUp.includes(n)),
      ],
      // Tombstone the old name; clear any stale tombstone on the new one (the
      // same rule the fresh recents timestamp above enforces on the remote
      // side — this game exists now, whatever some older delete said).
      tomb: [
        ...syncState.tomb.filter((t) => t?.name !== oldName && t?.name !== newName),
        { name: oldName, ts: Date.now() },
      ],
    };
    puts.push(["gdrive_sync", nextSync]);
  }

  let moved;
  try {
    moved = await dbMoveKeys(pairs, puts);
  } catch (e) {
    // Nothing moved: the transaction either committed whole or rolled back
    // whole, so the game is exactly as it was. Put the session back on it.
    if (loaded) currentOriginalName = oldName;
    return { ok: false, error: (e?.message || "The rename could not be completed.") +
                              " Nothing was changed." };
  }

  // Committed. Everything from here is in-memory bookkeeping catching up.
  if (nextSync) {
    syncState = nextSync;
    scheduleFlush();
  }
  if (Array.isArray(printerPhotos)) {
    for (let p of printerPhotos) if (p?.game === oldName) p.game = newName;
  }
  // The two "undo the last state load" buffers are keyed by game name.
  if (stateUndoName === oldName) stateUndoName = newName;
  if (rwUndoName === oldName) rwUndoName = newName;
  if (loaded) {
    currentOriginalName = newName;
    // The paused-at-home card prints the game's name; refresh it only if it is
    // actually on screen (it re-shows itself otherwise).
    if (homePausedCard && !homePausedCard.hidden) updatePausedCard();
  }
  return { ok: true, moved: moved.length };
};

// --- Rename modal ---------------------------------------------------------
// Three panes in one overlay: name it, confirm it, and (only when something
// goes wrong) say what happened. The confirmation is not a speed bump — it is
// where the user learns that a rename moves their saves too, so it enumerates
// what is about to move, with counts, and says what Drive will do about it.

// Opening reads storage before the overlay exists, so without this a double
// tap (a phone fires touch AND click) stacks two overlays — the second taking
// the focus trap and the first left behind when it is dismissed.
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

  // The Manage modal stays open behind this one, so hand the Tab trap over
  // rather than running two of them (trapFocus keeps one handler, and the
  // overlay that took it is the one allowed to give it back).
  let reopen = romsModal.classList.contains("open");
  if (reopen) releaseFocus(romsModal);

  let m;
  const close = () => {
    renameModalOpen = false;
    m.dismiss();
    if (reopen && romsModal.classList.contains("open")) trapFocus(romsModal);
  };
  // hint: null — this modal's intro line changes per pane, so it is rendered
  // into the body rather than fixed in the header.
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

    // One live line, doing double duty: the resulting file name while the
    // input is valid, the reason it isn't while it isn't. aria-live so a
    // screen reader hears the refusal without hunting for it.
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
    } else {
      para(body, "modal-toggle-sub",
        "This game has no saved data on this device yet — only its place in your library moves.");
    }

    if (driveLinked()) {
      para(body, "modal-toggle-sub",
        "Google Drive: the copies filed under the old name are deleted and the " +
        "renamed copies uploaded on the next sync. Your other devices drop " +
        "“" + displayName(oldName) + "” and pick up “" + displayName(newName) + "”.");
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

  // --- Pane 3: it didn't happen ---
  // A failed rename has to say two things: what went wrong, and whether
  // anything moved. Because the move is one transaction, the second answer is
  // always "no", and saying so is the point of this pane.
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

// --- "Removed on another device" modal ------------------------------------
// Resolves "continue" (drop the local copies) or "restore" (keep them and put
// them back on Drive). Continue is the primary action, bottom-right.
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

// Ensure we hold a Drive session before doing Drive work. Already holding a
// live token → true. Otherwise this is the LAZY re-auth path: callers invoke it
// from a click, so the popup has the activation it needs.
//
// Two cases, deliberately different. An already-linked account only needs a
// re-grant, so it gets the silent prompt:"" one carrying login_hint — with the
// Google session and the prior grant standing, that is a window that opens and
// closes with nothing in it, and the user's tap does what they asked. Only a
// genuinely new (or revoked) connection falls through to the full
// account-chooser flow with its "Connected to Google Drive" toast and full sync.
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
      // Grant really is gone (or the popup was blocked): fall through and ask
      // properly rather than leaving the user's tap doing nothing.
    }
  }
  try { await gdriveConnect(); }
  catch (e) { showToast(e.message); return false; }
  return syncActive();
};

// --- Keeping the session alive -------------------------------------------
// The GIS token flow hands out ~1h access tokens and NO refresh token, and its
// re-grant — even the silent prompt:"" one — goes through a popup window, so
// it needs transient user activation or the popup blocker kills it. That makes
// renewal a scheduling problem: we must find a user gesture BEFORE the token
// dies, not react to the 401 afterwards from a background timer (which has no
// activation and can only fail).
//
// So: whenever the token is missing or near expiry, arm a one-shot listener
// that does the silent re-grant on the very next pointerdown/keydown/touchstart.
// An emulator user supplies one within seconds. With the Google session and the
// prior grant still standing, that popup opens and closes with no visible
// chooser and the session rolls over invisibly.
//
// Renewal starts this long before the token actually expires, so there are
// several poll ticks' worth of chances to catch a gesture while the current
// token still works.
const DRIVE_RENEW_LEAD_MS = 10 * 60 * 1000;
// Consecutive silent-renew rejections before we conclude the grant is really
// gone (revoked, or the Google session ended) and show the signed-out UI. Each
// attempt costs a popup, so this is deliberately small.
const DRIVE_RENEW_MAX_FAILS = 3;

let driveRenewArmed = false;
let driveRenewFails = 0;

// True when we should be hunting for a gesture to renew on.
const driveTokenStale = () =>
  !gdriveToken || gdriveTokenExp - Date.now() < DRIVE_RENEW_LEAD_MS;

const armDriveRenewOnGesture = () => {
  if (driveRenewArmed) return;
  if (!GDRIVE_CLIENT_ID || !syncState.connected) return;
  if (driveRenewFails >= DRIVE_RENEW_MAX_FAILS) return;
  driveRenewArmed = true;
  const events = ["pointerdown", "keydown", "touchstart"];
  const onGesture = (e) => {
    // The update controls must never spend the renewal gesture: applyUpdate
    // reloads the page moments later, which orphans the GIS popup
    // mid-negotiation and loses the token it was fetching — the user just
    // sees Update inexplicably open a Google sign-in window. Stay armed;
    // the next ordinary gesture (or the post-reload boot resume) pays.
    // (Duck-typed rather than `instanceof Element`: text nodes lack closest,
    // and the test harness dispatches bare event objects.)
    const t = e && e.target;
    if (t && typeof t.closest === "function" &&
        t.closest("#update-btn, #update-confirm, #force-update")) return;
    events.forEach((ev) => window.removeEventListener(ev, onGesture, true));
    // Cleared before the attempt so the *next* expiry can arm again — the old
    // one-shot latch was never reset, which meant a session could be resumed at
    // most once per page load.
    driveRenewArmed = false;
    renewDriveToken();
  };
  events.forEach((e) => window.addEventListener(e, onGesture, true));
};

// Silent re-grant. Safe to call with a live token (rollover) or none (resume).
const renewDriveToken = async () => {
  if (!GDRIVE_CLIENT_ID || !syncState.connected) return;
  if (appUpdating) return; // reload imminent: a popup now would be orphaned
  if (navigator.onLine === false) { armDriveRenewOnGesture(); return; }
  const wasSignedOut = !gdriveToken;

  // Loading Google's script is a network call, not a consent decision: a
  // failure here (offline, blocked) must not count against the fail budget or
  // an offline session would be signed out for no reason.
  try { await loadGisScript(); }
  catch { armDriveRenewOnGesture(); return; }

  // The gesture may have aged out while the script loaded (activation lasts
  // about five seconds). A popup now is refused, and — worse — that refusal
  // would spend one of the three strikes that decide whether the grant is
  // really gone. Wait for a fresh gesture instead.
  if (!hasUserActivation()) { armDriveRenewOnGesture(); return; }

  try {
    await gdriveAcquireToken("");
  } catch {
    // Popup blocked (no activation after all) or the grant is gone. Try again
    // on the next gesture until the budget runs out; only then does the user
    // actually see a signed-out UI and have to click Sign in.
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

// Boot resume. If the persisted access token is still within its lifetime,
// reuse it directly — no popup, no gesture — so a reload or app update doesn't
// drop the session. The token is confirmed live via the tokeninfo endpoint (a
// plain fetch, never a popup), so a revoked token falls back to the
// gesture-gated re-grant instead of flashing a blocked popup. Only when there's
// no usable token do we arm the first-gesture re-grant.
const resumeDriveOnBoot = async () => {
  if (!GDRIVE_CLIENT_ID || !syncState.connected || gdriveToken) return;
  // Warm the GIS script now, for an account that already uses Drive. A gesture
  // only carries transient activation for about five seconds (measured: still
  // live at 1.2s, gone at 5.2s, in both WebKit and Chromium), and fetching
  // accounts.google.com/gsi/client cold on a phone can eat that whole budget —
  // so a renewal armed on the first tap after launch could lose its popup to a
  // script download. Loading it off the gesture path removes that failure mode.
  // Signed-out users still never touch Google's servers.
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
      // Offline at boot: keep the token rather than signing out; the normal
      // sync path retries and its 401 handling covers a genuinely dead token.
      live = true;
    }
    if (live) {
      refreshSyncUI();
      refreshHomeRecent();
      pullSync();
      // A restored token can be minutes from expiry; start hunting for a
      // gesture now rather than waiting for the first poll tick.
      if (driveTokenStale()) armDriveRenewOnGesture();
      return;
    }
    clearDriveToken();
  }
  armDriveRenewOnGesture();
};

// --- Sync triggers --------------------------------------------------------
// No push channel exists, so pull on the moments that matter and poll gently.
// The poll also retries a stuck flush: queued changes normally drain via the
// debounce timers or the `online` event, but when Drive is unreachable while
// the browser still considers itself online (Drive outage, blocking proxy)
// no `online` event will ever fire — without this, "Offline — your changes
// will sync when you reconnect" held until the user made another change or
// switched tabs.
const syncPollTick = () => {
  // Before the syncActive() gate: this is also the heartbeat that notices an
  // expiring (or already-expired) token and arms the gesture-gated renewal, and
  // it has to keep running once the token is gone.
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
  // Coming back to a phone that was asleep for an hour is the single most
  // likely moment to be holding a dead token — arm the renewal now rather than
  // waiting up to three minutes for the poll to notice.
  if (driveLinked() && driveTokenStale()) armDriveRenewOnGesture();
  if (syncActive()) flushSync().then(() => pullSync());
});

// --- Sync UI surfaces -----------------------------------------------------
const homeSyncBtn = /** @type {HTMLButtonElement} */ (document.getElementById("home-sync"));
// Same slot as Sync, shown in its place while signed out. Without it the only
// route into Drive from a populated library was Manage ROMs and Saves → Sign in
// with Google, which nothing on the home screen hinted at.
const homeSignInBtn = /** @type {HTMLButtonElement} */ (document.getElementById("home-signin"));

// The grid's own sync affordance doubles as its progress readout: while a sync
// is running the "Sync" link becomes a spinner + "Syncing…" and stops being
// clickable, so activity is visible right where the games are.
const refreshHomeSyncButton = () => {
  // Exactly one of the two is ever visible. Signed out is the Sign-in state;
  // a build with no client ID has no Drive at all, so neither shows.
  if (homeSignInBtn) {
    homeSignInBtn.hidden = !GDRIVE_CLIENT_ID || driveLinked();
    // A failed/cancelled sign-in re-enables the control here rather than in the
    // click handler's tail, so every path back to "signed out" is clickable.
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
    // Doubles as the reconnect affordance: linked but tokenless, this is the
    // gesture that buys a new token, and then it syncs as asked.
    if (!(await ensureDriveSignedIn())) return;
    runFullSync({ label: "Syncing" });
  });
}
if (homeSignInBtn) {
  // gdriveConnect() must be reached with the click's transient activation still
  // live or Google's OAuth popup is blocked ("Sign-in was cancelled"). The body
  // of an async function runs synchronously up to its first await, so the
  // assignment above it is free — but nothing may be awaited BEFORE the call.
  homeSignInBtn.addEventListener("click", async () => {
    homeSignInBtn.disabled = true;
    try { await gdriveConnect(); }
    catch (e) { showToast(e.message); }
    // gdriveConnect's success path already ran refreshSyncUI (which hides this
    // button); on failure this is what makes it clickable again.
    refreshHomeSyncButton();
  });
}
// The markup starts both buttons hidden, and nothing else paints this slot
// until an auth transition. Signed-out is the boot state, so seed it here.
refreshHomeSyncButton();

// --- Core-construction settings (GB renderer, GBA BIOS behavior) ---
// JS mirrors of the wasm-side option vars; they take effect the next time a
// core is constructed (ROM load / reset), matching the desktop config.

var gbFifo = true;
var gbaBiosMode = 0; // 0 = HLE, 1 = real BIOS, 2 = real BIOS boot + HLE calls
var gbaRunBios = true;
// Presentation-side only (the RAF loop polls _wasm_rumble and reacts here),
// so unlike its siblings it has no wasm setter in applySystemSettings.
var gbRumble = true;
// Rewind, on by default — matching the native `rewind` config default, and
// matching what every existing web install already does (the ring used to be
// allocated unconditionally). A "system" record written before this setting
// existed has no rewindOn key, and loadSystemSettings leaves this `true`
// rather than reading `undefined`, so nobody loses rewind by upgrading.
//
// Off is a real saving, not a hidden button: the wasm side stops allocating
// the ring, so loop_tick's per-interval snapshot + thumbnail never runs.
// Measured at ~0.8 ms per push (one per 10 frames), i.e. 8% of loop_tick on
// the Good Boy Galaxy demo — see the bench note in the settings markup.
var rewindOn = true;

const gbaRunBiosToggle = /** @type {HTMLInputElement} */ (document.getElementById("gba-run-bios-toggle"));
const gbRumbleToggle = /** @type {HTMLInputElement} */ (document.getElementById("gb-rumble-toggle"));
const rewindToggle = /** @type {HTMLInputElement} */ (document.getElementById("rewind-toggle"));

// Every rewind affordance is hidden by one body class (see body.rewind-off in
// styles.css) so there is a single place to add the next one to. Turning it
// off mid-session also has to shut the film strip if it happens to be open —
// the ring behind it is about to go away.
const applyRewindUI = () => {
  document.body.classList.toggle("rewind-off", !rewindOn);
  if (!rewindOn) {
    setRewindHeld(false);          // a held rewind must not survive the switch
    closeRewindScrubber();
  }
};

// Super Game Boy. sgbEnable is OFF by default -- a fresh install plays
// monochrome carts as a Game Boy, and the adapter is something you go and turn
// on. An existing "system" record predating this feature has no sgbEnable key,
// so loadSystemSettings leaves it off too: nobody silently gains it.
// sgbBorder defaults on because it is not a second opt-in; once you have asked
// for the adapter, the border is most of what it does.
// Both are only consulted by the core at ROM load (the cart header has the
// final say after that), so changing sgbEnable applies to the next game.
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
  // The border switch IS live — it only hides a layer the core already has.
  if (Module._wasm_sgb_border_show) Module._wasm_sgb_border_show(sgbBorder ? 1 : 0);
  // Live in both directions: off drops the ring now, on allocates a fresh
  // (empty) one for the session already running. No reload, so no
  // "takes effect next launch" note is owed here.
  if (Module._setRewindEnabled) Module._setRewindEnabled(rewindOn ? 1 : 0);
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
  rewindToggle.checked = rewindOn;
  applyRewindUI();
};

const saveSystemSettings = () => {
  applySystemSettings();
  applyRewindUI();
  if (db) dbPut("system",
    { gbFifo, gbaBiosMode, gbaRunBios, gbRumble, rewindOn, sgbEnable, sgbBorder });
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
  // Live: the canvas changes shape the moment the layer is shown or hidden.
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
    if (typeof s.gbFifo === "boolean") gbFifo = s.gbFifo;
    if ([0, 1, 2].includes(s.gbaBiosMode)) gbaBiosMode = s.gbaBiosMode;
    if (typeof s.gbaRunBios === "boolean") gbaRunBios = s.gbaRunBios;
    if (typeof s.gbRumble === "boolean") gbRumble = s.gbRumble;
    if (typeof s.sgbEnable === "boolean") sgbEnable = s.sgbEnable;
    if (typeof s.sgbBorder === "boolean") sgbBorder = s.sgbBorder;
    // Deliberately only assigns for a real boolean: a record saved before this
    // setting existed leaves rewindOn at its `true` default instead of
    // becoming undefined, so upgrading never silently turns rewind off.
    if (typeof s.rewindOn === "boolean") rewindOn = s.rewindOn;
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

// Drop this device's copy of a game's bytes: the ROM record and its box art,
// which together are effectively all of a game's footprint. Save data is
// never touched here — it is the small, irreplaceable half, and the callers
// that only want space back (the MAX_RECENT eviction below, "Remove from this
// device") must not take it. Callers that really are deleting the game wipe
// the saves themselves, alongside this.
const evictLocalRom = async (name) => {
  await dbDelete(romKey(name));
  await dbDelete(artKey(name));
};

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
  // Past MAX_RECENT this device stops holding ROM bytes. Signed in, the entry
  // stays in the index and simply becomes a Drive-only tile — the bytes are
  // re-downloadable, so the library stays whole. Signed out there'd be nothing
  // to come back to, so the entry is dropped as before.
  for (let i = MAX_RECENT; i < list.length; i++) await evictLocalRom(list[i].name);
  if (!driveLinked()) list = list.slice(0, MAX_RECENT);
  await dbPut("recent", list);
};

// Ask the browser to exempt this origin's storage — the ROM library and every
// save — from automatic eviction under disk pressure ("best-effort" storage
// can be silently wiped). Chromium and Safari decide silently from engagement
// heuristics, but Firefox shows a permission prompt, so the request is tied to
// the moments the user just entrusted us with data (a ROM import, a battery-
// save flush) rather than fired at page load, and made at most once per
// session so a dismissed prompt never nags.
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
  // Bytes first, index second: an interruption leaves at worst an orphaned
  // rom: record, never an index entry pointing at nothing.
  await dbPut(romKey(name), { name, data: new Uint8Array(bytes) });
  if (art) await dbPut(artKey(name), art); // Blob (box art from a zip)
  await bumpRecentIndex(name);
  refreshHomeRecent();
  requestPersistentStorage();
  // Back the freshly-imported game up to Drive soon (no-op unless it syncs).
  markGameUpload(name);
};

// Recency bump for a ROM whose bytes are already stored (relaunch paths) —
// no multi-MB rewrite of the rom: record.
const touchRecent = async (name) => {
  await bumpRecentIndex(name);
  refreshHomeRecent();
};

// Launch a ROM by name, fetching its bytes from IndexedDB only now.
const launchRom = async (name) => {
  // The grid renders before the wasm runtime is up; a tile tapped in that
  // window waits here (with a "Starting…" toast) instead of crashing in
  // writeToFS/loadRom below.
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

// Home-screen recent grid — this is the app's game library (it replaces the
// old Recent modal: launch, remove, and storage usage all live here).
const homeRecentWrap = document.getElementById("home-recent-wrap");
const homeRecentHead = document.getElementById("home-recent-head");
const homeRecent = document.getElementById("home-recent");
const storageInfo = document.getElementById("storage-info");

// Empty-library placeholder. Its whole reason for existing beyond "you have no
// games" is Drive: on a fresh device this is the ONLY way to reach sign-in
// (the Manage-ROMs link that normally hosts it lives in the recents header,
// which is hidden when the library is empty). So configured-but-signed-out
// users get a direct sign-in button here; already-connected users get a pull.
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

// Object URLs for box-art thumbnails, revoked and rebuilt each render
let homeArtUrls = [];
// Render generation: a lazy art fetch that resolves after a newer render
// must not touch (or leak URLs into) the fresh grid.
let homeRenderGen = 0;

// The grid is rebuilt off-DOM and swapped in with ONE replaceChildren at the
// very end — never emptied first. #home is the scroll container, so the moment
// the grid holds no tiles its scrollHeight collapses to the viewport and the
// browser clamps scrollTop to 0; the tiles coming back a tick later don't
// bring the scroll offset back. The rebuild awaits dbKeys() between "clear"
// and "refill", so that collapse was guaranteed to be laid out — clearing
// early threw the user to the top of their library on every render, most
// painfully when downloading Drive-only games one after another (each
// download refreshes twice: busy spinner, then result).
const refreshHomeRecent = async () => {
  if (!db) return;
  let roms = await getRecentMeta(); // metadata only — no ROM bytes
  let gen = ++homeRenderGen;
  // Art URLs minted by THIS render — they only become homeArtUrls (the set the
  // next render revokes) once this render commits. Nothing is minted before
  // the commit point below, so a superseded render leaves none behind.
  let artUrls = [];
  if (roms.length === 0) {
    // Keep the section visible (empty state) so Drive sign-in stays reachable,
    // but drop the "Recent"/Manage header since there's nothing to manage yet.
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
  // The grid is the merged cross-device library, so some entries are games this
  // device doesn't hold bytes for. Those render as "Drive-only" download tiles —
  // whether or not we're signed in. Signed out, a game that lives on Drive but
  // isn't downloaded here must still read as "needs download" (tap prompts
  // sign-in) rather than masquerading as a stored game whose launch then fails.
  let localRoms = new Set();
  let keys = await dbKeys();
  // A newer render may have started during that await; committing ours too
  // would show a stale grid (and, before the off-DOM rebuild, doubled every
  // game). The art callbacks below re-check gen the same way.
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

    // The system chip is the game's identity slot: one place, one signal (it
    // replaced the cartridge glyph + duplicate corner badge). Box art, when a
    // game has any, takes the same slot — its Blob lives in its own record so
    // this never deserializes ROM bytes just to draw the grid.
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
    // Clicking anywhere on the tile body downloads (signing in first if needed)
    // and launches. The download glyph is a separate target (below) that
    // downloads without launching.
    launch.addEventListener("click", async () => {
      if (!driveOnly) { launchRom(romName); return; }
      if (syncDownloading.has(romName)) return;
      if (!(await ensureDriveSignedIn())) return;
      if (await downloadGame(romName)) launchRom(romName);
    });

    tile.appendChild(launch);

    if (driveOnly) {
      // Its own click target: hitting exactly the download glyph downloads the
      // ROM + saves WITHOUT launching (grab it for later), while a click on the
      // rest of the tile downloads and launches. Sits where the 2P/remove
      // controls would be on a local tile, so the tile never carries both.
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
      tile.appendChild(link2p);
    }
    // No remove button here by design: the grid is a library view, and all
    // deletion (Reset / Delete) lives in Manage ROMs and Saves.
    tiles.push(tile);
  }
  // The one and only DOM commit. Atomic: the grid goes straight from the old
  // tiles to the new ones with no zero-height moment in between, so an
  // unchanged tile count leaves scrollTop exactly where the user put it.
  homeRecent.replaceChildren(...tiles);
  homeArtUrls.forEach(URL.revokeObjectURL);
  homeArtUrls = artUrls;
};

// Close any open modal on Escape. Every modal belongs here (the net modal is
// the one exception — netplay.js owns its dismissal, which also abandons a
// pending session). Backdrop click and the × button already cover all of
// them; Escape must stay in step or a modal reads as "stuck".
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    menuDropdown.hidden = true; // the dropdown must not outlive Escape either
    // Don't close settings if we're rebinding a key — the capture handler
    // cancels the capture and eats the event before this handler runs
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
    closeRomWarnModal();
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
// What the library UI shows for a game: the filename without its extension
// (the GB/GBA chip already says what kind of cartridge it is; full filename
// stays in tooltips). Falls back to the raw name if there's no extension.
const displayName = (name) => stripExt(name) || name;

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

// --- Toasts -----------------------------------------------------------------
// #toast is a STACK, not a single slot. It used to be one element whose text
// each new message overwrote, which meant a routine toast could silently
// destroy an offer the user still needed: the Game Boy Camera's "use your
// real camera?" prompt — the only way to enable the webcam — was wiped by the
// auto-resume "Last session saved" toast 98 ms later, and Reset's "Undo"
// collided with the same offer. Toasts now coexist; nothing destroys anything.
//
// Newest is PREPENDED, so it renders on top and the container (anchored to the
// viewport bottom) grows upward. The oldest toast therefore never moves once
// it is on screen, which matters because these carry tap targets ("Enable
// camera", "Undo", "Resume") — a pill that jumps out from under a committed
// thumb is worse than no pill. The cap keeps the stack from creeping up over
// the game and the touch controls; the oldest retires first.
const TOAST_MAX = 3;
const TOAST_FADE_MS = 220; // keep in sync with .toast-item.leaving in styles.css
const toastHost = document.getElementById("toast");
// Live toasts, newest first — mirrors toastHost's children. Each entry is a
// record { el, msg, label, timer, gone } rather than bookkeeping hung off the
// element as expandos, which the types/ typecheck rejects on HTMLDivElement.
let toastItems = [];

const dismissToast = (rec) => {
  if (!rec || rec.gone) return;
  rec.gone = true;
  clearTimeout(rec.timer);
  const i = toastItems.indexOf(rec);
  if (i >= 0) toastItems.splice(i, 1);
  rec.el.classList.add("leaving");
  // Unmount after the fade so the stack's height settles in one step. Guarded
  // by rec.gone, so removeChild runs exactly once while it is still a child.
  setTimeout(() => toastHost.removeChild(rec.el), TOAST_FADE_MS);
};

// Auto-dismiss is per toast, not one shared timer: a 2.2 s status message
// arriving next to an 8 s offer must not shorten (or extend) the offer.
const armToastTimer = (rec, ms) => {
  clearTimeout(rec.timer);
  rec.timer = setTimeout(() => dismissToast(rec), ms);
};

// `action` is null for a plain toast, or { label, fn } for a tappable one.
const pushToast = (msg, ms, action) => {
  msg = String(msg);
  // Duplicates don't pile up. A repeated plain message just gets its life
  // extended in place; a repeated offer is replaced outright so the freshest
  // closure is what the tap runs (the old one may close over a stale game).
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
    // The ENTIRE pill is the tap target — on phones the labeled button alone
    // is small and missable, and users tap the text anyway.
    //
    // fn() runs SYNCHRONOUSLY in this handler, with nothing awaited before it.
    // Several callers (enableOrientationTilt, enableWebcam) use this tap to
    // satisfy iOS's user-gesture requirement for
    // DeviceOrientationEvent.requestPermission() and getUserMedia(); any
    // await, timer, or re-dispatch here breaks the activation chain and the
    // permission prompt never appears.
    const fn = action.fn;
    item.onclick = () => {
      item.onclick = null;
      dismissToast(rec);
      fn();
    };
  }

  // Prepend: newest on top, older ones hold still (see the note above).
  toastHost.prepend(item);
  toastItems.unshift(rec);
  while (toastItems.length > TOAST_MAX) dismissToast(toastItems[toastItems.length - 1]);
  armToastTimer(rec, ms);
  return rec;
};

const showToast = (msg) => pushToast(msg, 2200, null);

// Toast with a single action (e.g. "Resume", "Undo"). Lingers longer than a
// plain toast, and coexists with anything that arrives afterwards.
const showActionToast = (msg, label, fn, ms = 8000) =>
  pushToast(msg, ms, { label, fn });

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

// wasm_load_state only reports accept/reject (the specific reason is echoed
// to the console), so sniff the header magic here to tell "this isn't a
// dingbat save state at all" apart from "real state image the core rejected"
// (different game, newer dingbat version, or corruption). Header layout is
// documented in src/dingbat/common/serialize.nim (STATE_MAGIC = "DGBSTATE").
const STATE_MAGIC = "DGBSTATE";
const looksLikeStateFile = (bytes) =>
  !!bytes && bytes.length >= STATE_MAGIC.length &&
  [...STATE_MAGIC].every((c, i) => bytes[i] === c.charCodeAt(0));

// Toast copy for a state image the core refused to load. The core knows
// exactly why — wrong ROM, written by a newer build, a corrupt section — and
// now says WHICH via wasm_state_error_kind(). "State didn't match this game"
// used to be the answer to all of them, and it is actively wrong for four of
// the five: it sent people hunting for the wrong problem when the real answer
// was "your dingbat is older than the one that wrote this".
//
// StateRejectKind ordinals, from src/dingbat/common/serialize.nim. The core
// classifies the refusal; this table turns each cause into a sentence that
// says what to DO about it, because "wrong game" and "damaged file" are
// different problems and used to render as the same toast.
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
  // Only the native build loads from a path, so this one cannot arrive here
  // today. It is in the table anyway: the ordinals are a shared contract with
  // the core, and a missing entry would silently fall through to the raw
  // exception text the moment anything does surface it.
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
  // Fall back to the core's own wording (it is written for a person), just
  // sentence-cased so it sits in a toast.
  return why.charAt(0).toUpperCase() + why.slice(1).replace(/\.$/, "");
};

// Validate + apply a state image; returns true when the core accepted it.
// keepRewind is for undoing a rewind-scrubber commit and nothing else: that
// state belongs to the same timeline the ring already holds, so the core keeps
// its rewind history instead of starting over. Every other load starts a new
// timeline and drops the ring (see wasm_load_state).
const applyStateBytes = (bytes, keepRewind = false) => {
  if (typeof Module === "undefined" || !Module._wasm_load_state) return false;
  let ptr = Module._malloc(bytes.length);
  if (!ptr) return false;
  // Build the heap view after _malloc: growth can detach the old buffer
  new Uint8Array(Module.memory.buffer, ptr, bytes.length).set(bytes);
  let ok = Module._wasm_load_state(ptr, bytes.length, keepRewind ? 1 : 0) === 1;
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
    markUpload(slotStateKey(currentOriginalName, slot));
    markUpload(slotMetaKey(currentOriginalName, slot));
    return true;
  } catch (e) {
    showToast("Save state failed: " + e.message);
    return false;
  }
};

// Undo buffer for the last state load: the state of the game the moment
// before the load replaced it. In-memory only — survives until the next
// load or a ROM switch. Saves the day when F8 lands a fraction after an
// unintended F5, or a slot tap loads hours-old progress.
var stateUndoBytes = null;
var stateUndoName = null;

const undoStateLoad = () => {
  if (!stateUndoBytes || stateUndoName !== currentOriginalName) return;
  if (applyStateBytes(stateUndoBytes)) {
    stateUndoBytes = null;
    showToast("Back to before the load");
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
// Captured when the page is hidden or closed, offered back as a one-tap
// "Resume" when the same game is next launched. Local-only by design: it is
// a convenience snapshot, not user data — keeping it out of Drive sync
// avoids an upload every tab switch.
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

// Offer to restore the auto state for the game that just launched. The state
// header check inside the core keeps a stale/mismatched snapshot harmless.
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

// --- Save States modal (9-slot grid with thumbnails) ---
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
  // The "Tap a slot…" instructions only make sense when slots are rendered.
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
// Builds a downloadable report bundle {title, description, diagnostics, save
// state} entirely client-side — nothing is transmitted. The save state carries
// only emulator RAM/registers + a screenshot, never the ROM. A scrubber lets
// the user pick the moment the bug happened from the rewind history: slider 0
// is "now" (live state), 1..N are rewind samples (0..N-1, newest first).
// The samples come straight out of the rewind ring, which captured each
// thumbnail when its snapshot was pushed — opening this modal copies a strip,
// it does not re-render history (that used to cost 1.4 s on a full ring).
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

// Slider runs 0..N with the RIGHT end (max) = "now"; sliding left goes back in
// time. back = 0 is the live frame, back = 1..N are rewind samples 0..N-1.
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
  // Freeze emulation so the strip on screen stays the ring's contents. A
  // sample the ring evicts anyway is not dangerous — samples are addressed by
  // absolute snapshot ID, so an evicted one yields nothing rather than
  // silently sliding onto a different moment — but it would go blank.
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
  // The timeline itself is hidden by body.rewind-off; the hint takes over and
  // says why, instead of leaving a slider that can only sit at "now" and an
  // invitation to enable a setting from a modal that cannot reach it.
  reportScrubHint.textContent = rewindOn
    ? "Slide left to go further back in time. Enable Rewind in Settings to capture a longer timeline."
    : "Rewind is off, so only this moment can be attached. Turn Rewind on in Settings to pick an earlier one.";
  reportScrubHint.hidden = rewindOn && reportSamples > 0;
  updateReportPreview();
  reportModal.classList.add("open");
  trapFocus(reportModal);
};

const closeReportModal = () => {
  // Guard: the global Escape handler calls every modal's closer blindly, and
  // this one has side effects — restoring `paused` from a stale
  // reportWasPaused would silently unpause a game the user paused later.
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

// --- Rewind scrubber -------------------------------------------------------
// Hold-to-rewind is fine for a second and useless for a minute; this is the
// map. Same preview-cheap / reconstruct-once split as the bug-report scrubber
// above: dragging only ever paints thumbnails the ring captured at push time,
// and a real emulator state is built exactly once, on commit.
//
// Two things separate it from the report scrubber: it is DESTRUCTIVE (the
// future is gone, hence the two-tap confirm), and it may cost the player their
// in-game battery save (hence the third tap, when it actually would).
//
// It presents as an ordinary modal — same overlay, panel, close button, focus
// trap and Escape handling as Save States or Report a Bug — and it reuses that
// scrubber's .report-scrub box outright rather than a private variant of it.

const rewindModal = document.getElementById("rewind-modal");
const rwStripCanvas = /** @type {HTMLCanvasElement} */ (document.getElementById("rewind-strip"));
// By id, not selector: the test harness's fake DOM resolves getElementById
// (and a module-scope global that comes back null aborts the whole sandbox,
// taking every web test with it).
const rwStripWrap = document.getElementById("rewind-strip-wrap");
const rwPreview = /** @type {HTMLCanvasElement} */ (document.getElementById("rewind-preview"));
const rwSlider = /** @type {HTMLInputElement} */ (document.getElementById("rewind-slider"));
const rwWhen = document.getElementById("rewind-when");
const rwPlayhead = document.getElementById("rewind-playhead");
const rwOldest = document.getElementById("rewind-oldest");
const rwWarn = document.getElementById("rewind-warn");
const rwCommitBtn = /** @type {HTMLButtonElement} */ (document.getElementById("rewind-commit"));
const rwHint = document.getElementById("rewind-scrub-hint");

// How many thumbnails to pull out of the ring. Each one is a full BGR555 copy
// (19 KB on GBA, 26 KB on GB), so this is a real memory number on the phones
// that run the 16 MB ring; 96 covers a minute and a half at the ring's one
// thumbnail per second and costs ~2.5 MB transiently.
const RW_MAX_SAMPLES = 96;
const RW_GAP = 2;             // px between frames in the strip
const RW_TAP_SLOP = 5;        // px of travel below which a drag counts as a tap

let rwSamples = 0;
let rwThumbs = null;          // packed BGR555, copied out of wasm at open
let rwThumbW = 0;
let rwThumbH = 0;
let rwStripColor = null;      // offscreen: the whole strip, in colour
let rwStripDim = null;        // ...and desaturated, for the discarded future
let rwPitch = 0;              // px per sample along the strip
let rwIndex = 0;              // playhead position, in samples back from now
let rwStage = 0;              // 0 pick, 1 confirm discard, 2 confirm save loss
let rwWasPaused = false;
let rwUndoBytes = null;
let rwUndoName = null;

const rwSelected = () => Math.round(rwIndex);

// "2m 14s" / "8.4s". Sub-minute keeps a decimal because at the shallow end a
// whole second is a big fraction of what is being discarded.
const rwFmtDuration = (tenths) => {
  const s = tenths / 10;
  if (s < 60) return (s < 10 ? s.toFixed(1) : Math.round(s)) + "s";
  const m = Math.floor(s / 60);
  return m + "m " + Math.round(s - m * 60) + "s";
};

const rwTenthsAt = (sample) =>
  sample > 0 && Module._wasm_rewind_scrub_seconds_ago
    ? Module._wasm_rewind_scrub_seconds_ago(sample)
    : 0;

// Strip geometry. Frames keep their native aspect, but the size is driven by
// how many should be VISIBLE rather than by the strip's height: a GBA frame is
// 3:2, so filling a 76px strip makes each one ~110px and a phone shows three —
// a peephole, and half a minute of history then takes ten swipes to cross.
//
// Sizing from the strip's own width instead of a fixed pixel target is what
// makes one rule serve a 208px strip inside a modal on a 320pt phone and a
// 400px one on desktop: both show the same amount of history, the phone just
// shows it smaller. The clamp keeps frames recognisable at the low end and
// stops them ballooning at the high end.
const RW_VISIBLE_FRAMES = 5.5;
const RW_FRAME_W_MIN = 38;
const RW_FRAME_W_MAX = 72;

const rwFrameSize = (stripW, stripH) => {
  const maxH = Math.max(8, stripH - 6);
  let tw = Math.round(
    Math.min(RW_FRAME_W_MAX, Math.max(RW_FRAME_W_MIN, stripW / RW_VISIBLE_FRAMES))
  );
  let th = Math.round((tw * rwThumbH) / rwThumbW);
  if (th > maxH) {
    th = maxH;
    tw = Math.max(12, Math.round((th * rwThumbW) / rwThumbH));
  }
  return { tw, th };
};

// Both strips are built once per open. Painting the discarded future by
// filtering at draw time would be the obvious approach, but CanvasRenderingContext2D.filter
// only arrived in Safari 17 and this app still supports iOS 15 — so the
// desaturated copy is baked here instead, and drawing is two clipped blits.
const rwBuildStrips = () => {
  rwStripColor = null;
  rwStripDim = null;
  if (!rwThumbs || rwSamples <= 0) return;
  const wrap = rwStripWrap.getBoundingClientRect();
  const stripH = Math.max(24, Math.round(wrap.height) - 2);
  const { tw, th } = rwFrameSize(Math.max(120, Math.round(wrap.width)), stripH);
  rwPitch = tw + RW_GAP;
  const total = rwSamples * rwPitch;

  const scratch = document.createElement("canvas");
  scratch.width = rwThumbW;
  scratch.height = rwThumbH;
  const sctx = scratch.getContext("2d");

  rwStripColor = document.createElement("canvas");
  rwStripColor.width = total;
  rwStripColor.height = stripH;
  const cctx = rwStripColor.getContext("2d");
  const stride = rwThumbW * rwThumbH * 2;
  const top = Math.round((stripH - th) / 2);
  for (let s = 0; s < rwSamples; s++) {
    sctx.putImageData(bgr555ToImageData(rwThumbs, s * stride, rwThumbW, rwThumbH), 0, 0);
    // Newest on the RIGHT — same direction as the report slider, and the
    // direction a film strip runs.
    const x = (rwSamples - 1 - s) * rwPitch + Math.floor(RW_GAP / 2);
    cctx.drawImage(scratch, 0, 0, rwThumbW, rwThumbH, x, top, tw, th);
  }

  rwStripDim = document.createElement("canvas");
  rwStripDim.width = total;
  rwStripDim.height = stripH;
  const dctx = rwStripDim.getContext("2d");
  dctx.drawImage(rwStripColor, 0, 0);
  const img = dctx.getImageData(0, 0, total, stripH);
  const px = img.data;
  for (let i = 0; i < px.length; i += 4) {
    // Rec.601 luma, then halved: the discarded frames must stay readable as
    // pictures (you are choosing where to cut, so you need to see what goes)
    // while never being mistaken for the live side of the playhead.
    const y = (px[i] * 77 + px[i + 1] * 150 + px[i + 2] * 29) >> 9;
    px[i] = px[i + 1] = px[i + 2] = y;
  }
  dctx.putImageData(img, 0, 0);
};

// Where the cut falls, in strip-bitmap pixels: the TRAILING edge of the
// selected frame, not its centre. The selected moment is the last one kept, so
// it belongs entirely on the colour side of the line — a playhead through its
// middle would show the frame you are keeping as half-discarded.
const rwCutX = (index) => (rwSamples - index) * rwPitch;

// Where the film sits and where the playhead sits, for the current selection.
//
// The playhead rides the middle and the film scrolls under it — until the film
// runs out of slack at either end, at which point the film stops and the
// playhead travels the rest of the way. Without that clamp the newest frame
// can only ever reach the middle, so half the strip is permanently empty at
// the "now" end — which is where the modal opens, so the control's first
// impression is of being broken. The cost is that inside those end regions the
// playhead moves opposite the finger for a few dozen pixels; the film staying
// put is the stronger cue, and it is what a video timeline does.
const rwPlacement = (cssW) => {
  const filmW = rwSamples * rwPitch;
  const x = rwCutX(rwIndex);
  if (filmW <= cssW) {
    const off = (cssW - filmW) / 2; // short film: centred, playhead moves
    return { off, head: off + x };
  }
  const off = Math.min(0, Math.max(cssW - filmW, cssW / 2 - x));
  return { off, head: x + off };
};

const rwDrawStrip = () => {
  const rect = rwStripCanvas.getBoundingClientRect();
  const cssW = Math.max(1, Math.round(rect.width));
  const cssH = Math.max(1, Math.round(rect.height));
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  if (rwStripCanvas.width !== cssW * dpr || rwStripCanvas.height !== cssH * dpr) {
    rwStripCanvas.width = cssW * dpr;
    rwStripCanvas.height = cssH * dpr;
  }
  const ctx = rwStripCanvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, cssW, cssH);
  if (!rwStripColor) return;
  const { off, head } = rwPlacement(cssW);
  // The cut can legitimately land on the film's outer edge (nothing discarded
  // at "now"), where the marker's own width would put half of it outside the
  // clipped wrapper and leave it looking like a border. Nudge it just inside.
  rwPlayhead.style.left = Math.min(Math.max(head, 2), cssW - 2) + "px";
  // Past and present in colour up to the playhead; the discarded future
  // desaturated beyond it. The boundary is the playhead by construction, so
  // the doomed region grows as the strip is dragged back without anything
  // having to track how much of it there is.
  ctx.save();
  ctx.beginPath();
  ctx.rect(0, 0, head, cssH);
  ctx.clip();
  ctx.drawImage(rwStripColor, off, 0);
  ctx.restore();
  ctx.save();
  ctx.beginPath();
  ctx.rect(head, 0, cssW - head, cssH);
  ctx.clip();
  ctx.drawImage(rwStripDim, off, 0);
  ctx.globalAlpha = 0.35;
  ctx.fillStyle = "#000";
  ctx.fillRect(head, 0, cssW - head, cssH);
  ctx.restore();
};

const rwDrawPreview = () => {
  if (!rwThumbs || rwSamples <= 0) return;
  const stride = rwThumbW * rwThumbH * 2;
  rwPreview.width = rwThumbW;
  rwPreview.height = rwThumbH;
  rwPreview
    .getContext("2d")
    .putImageData(bgr555ToImageData(rwThumbs, rwSelected() * stride, rwThumbW, rwThumbH), 0, 0);
};

// Stages 1 and 2 are the two confirmations, each stated in terms of what it
// costs. Any movement of the playhead disarms back to stage 0 — the confirm
// has to be about the moment the player is looking at.
const rwRefreshActions = () => {
  const sel = rwSelected();
  const cost = rwFmtDuration(rwTenthsAt(sel));
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
  rwWhen.textContent = sel === 0 ? "now" : rwFmtDuration(rwTenthsAt(sel)) + " ago";
  if (rwSlider.value !== String(rwSamples - 1 - sel)) {
    rwSlider.value = String(rwSamples - 1 - sel);
  }
  rwDrawStrip();
  rwDrawPreview();
  rwRefreshActions();
};

// Every path that moves the playhead goes through here, so disarming the
// confirm can't be forgotten by one of them.
const rwSetIndex = (v, snap) => {
  const clamped = Math.min(Math.max(v, 0), Math.max(0, rwSamples - 1));
  const next = snap ? Math.round(clamped) : clamped;
  if (next === rwIndex) return;
  if (Math.round(next) !== rwSelected()) rwStage = 0;
  rwIndex = next;
  rwRefresh();
};

// Pointer-driven, not a scroll container: native horizontal scrolling on iOS
// carries momentum, and a scrubber that keeps gliding after the finger lifts
// selects a frame the player never chose.
{
  let dragging = false;
  let lastX = 0;
  let travel = 0;
  rwStripWrap.addEventListener("pointerdown", (e) => {
    if (rwSamples <= 0) return;
    e.preventDefault();
    dragging = true;
    travel = 0;
    lastX = e.clientX;
    rwStripWrap.setPointerCapture(e.pointerId);
  });
  rwStripWrap.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    const dx = e.clientX - lastX;
    lastX = e.clientX;
    travel += Math.abs(dx);
    // Dragging the film to the RIGHT pulls older frames under the playhead,
    // which is the same gesture as physically winding a reel back.
    rwSetIndex(rwIndex + dx / rwPitch, false);
  });
  const endDrag = (e) => {
    if (!dragging) return;
    dragging = false;
    if (rwStripWrap.hasPointerCapture?.(e.pointerId)) {
      rwStripWrap.releasePointerCapture(e.pointerId);
    }
    if (travel <= RW_TAP_SLOP && e.type === "pointerup") {
      // A tap selects the frame that is literally under the finger — resolved
      // through the same placement the draw used, so it stays correct in the
      // clamped region where the film is not centred on the playhead.
      const rect = rwStripWrap.getBoundingClientRect();
      const { off } = rwPlacement(rect.width);
      const filmX = e.clientX - rect.left - off;
      rwSetIndex(rwSamples - 1 - Math.floor(filmX / rwPitch), true);
    } else {
      rwSetIndex(rwIndex, true); // settle on a whole frame
    }
    rwRefresh();
  };
  for (const ev of ["pointerup", "pointercancel", "pointerleave"]) {
    rwStripWrap.addEventListener(ev, endDrag);
  }
}

// The coarse range input is the keyboard and screen-reader path onto the same
// state; it is not a second source of truth.
rwSlider.addEventListener("input", () => {
  rwSetIndex(rwSamples - 1 - Number(rwSlider.value), true);
});

const openRewindScrubber = () => {
  menuDropdown.hidden = true;
  if (!rewindOn) return;   // no ring, so the strip would only ever be empty
  if (!currentOriginalName || !speedControlsOk()) return;
  if (typeof Module === "undefined" || !Module._wasm_rewind_scrub_generate) return;
  rwWasPaused = paused;
  // Freeze the core: the strip on screen must stay the ring's contents while
  // it is being read, and a running game would push new snapshots (and evict
  // old ones) out from under the playhead.
  paused = true;
  rwSamples = 0;
  rwThumbs = null;
  rwStripColor = null;
  rwStripDim = null;
  rwIndex = 0;
  rwStage = 0;
  rwSamples = Module._wasm_rewind_scrub_generate(RW_MAX_SAMPLES);
  if (rwSamples > 0) {
    rwThumbW = Module._wasm_rewind_scrub_thumb_w();
    rwThumbH = Module._wasm_rewind_scrub_thumb_h();
    const ptr = Module._wasm_rewind_scrub_thumbs_ptr();
    const len = rwSamples * rwThumbW * rwThumbH * 2;
    rwThumbs = new Uint8Array(Module.memory.buffer, ptr, len).slice();
  }
  rwSlider.max = String(Math.max(0, rwSamples - 1));
  rwSlider.value = String(Math.max(0, rwSamples - 1));
  rwHint.textContent =
    rwSamples > 1
      ? "Drag the strip, or the bar for longer jumps. Everything right of the line is discarded."
      : "No rewind history yet — it builds up as you play.";
  rwOldest.textContent = rwSamples > 1 ? rwFmtDuration(rwTenthsAt(rwSamples - 1)) + " ago" : "";
  rewindModal.classList.add("open");
  trapFocus(rewindModal);
  // After .open, so the strip has a laid-out height to size frames against.
  rwBuildStrips();
  rwRefresh();
};

const closeRewindScrubber = () => {
  // Guard: the global Escape handler calls every closer blindly and this one
  // has side effects — restoring `paused` from a stale rwWasPaused would
  // silently unpause a game the user paused later.
  if (!rewindModal.classList.contains("open")) return;
  rewindModal.classList.remove("open");
  releaseFocus(rewindModal);
  rwThumbs = null;
  rwStripColor = null;
  rwStripDim = null;
  rwStage = 0;
  paused = rwWasPaused;
};

const rwUndoCommit = () => {
  if (!rwUndoBytes || rwUndoName !== currentOriginalName) return;
  // keepRewind: this is the same timeline the ring still holds — everything in
  // it really did happen before this state. There is a gap where the committed
  // window used to be (those snapshots are gone for good), but the frames are
  // the player's own past, not another save's.
  if (applyStateBytes(rwUndoBytes, true)) {
    rwUndoBytes = null;
    showToast("Back to where you were");
  }
};

const rwCommit = () => {
  const sel = rwSelected();
  if (sel <= 0) return;
  const cost = rwFmtDuration(rwTenthsAt(sel));
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

// The commit button IS the confirmation, switching in place rather than
// stacking a second dialog on top of this one. Stage 2 only ever appears when
// the rewind really would cost a save — asking every time is how a warning
// stops being read.
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

// The strip bitmaps are rasterised for one strip height and one frame size,
// both of which change across the phone/desktop breakpoint — a rotation with
// the modal open would otherwise scale a stale bitmap.
window.addEventListener("resize", () => {
  if (!rewindModal.classList.contains("open")) return;
  rwBuildStrips();
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

// Apply an imported .state image to the running game (not persisted — use Save
// State to keep it). Shared by the "Import state" button and a dropped .state.
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
    () => dbPut("audio", { volume, muted, pitchCorrectFF, audioLowpass, mp2kHle }), 250);
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
// Local audio preference persisted in the "audio" IDB record alongside
// volume/mute. When on, the core time-stretches 2x audio so it keeps its pitch
// instead of jumping an octave; independent of the rollback-synced 2x state.
var pitchCorrectFF = false;
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

// --- MP2K sound-engine HLE ("Improve audio quality in supported titles") ---
// Experimental opt-in: re-renders GBA music above the FIFO's ~13 kHz when the
// runtime detection recognizes Nintendo's MP2K/m4a engine in the loaded game.
// The wasm side remembers the preference for future cores (make_gba) and
// applies it to the live core, so this only needs to push on change / init.
// Persisted in the "audio" IDB record alongside volume/mute/pitchCorrectFF.
var mp2kHle = false;
const mp2kHleToggle = /** @type {HTMLInputElement} */ (document.getElementById("mp2k-hle-toggle"));

const applyMp2kHle = () => {
  if (typeof Module !== "undefined" && Module._wasm_set_mp2k_hle) {
    Module._wasm_set_mp2k_hle(mp2kHle ? 1 : 0);
  }
};

if (mp2kHleToggle) {
  mp2kHleToggle.addEventListener("change", () => {
    mp2kHle = mp2kHleToggle.checked;
    applyMp2kHle();
    saveAudioSettings();
  });
}

// --- Analog low-pass filter (optional AudioContext BiquadFilter) ---
// Models the GBA speaker's cap/analog smoothing; off by default (routed out
// of the graph → bit-identical to no filter). Persisted in the "audio" IDB
// record alongside volume/mute/pitchCorrectFF.
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

// --- Video effects (integer scaling, scanline overlay) ---
// Integer scaling pins the canvas's CSS size to a whole multiple of the
// emulated resolution. The scanline overlay is a separate element JS keeps
// aligned over the canvas (a WebGL canvas can't carry pseudo-elements), with
// background-size set so one line lands on each emulated pixel row.

var integerScale = false;
var scanlines = false;
// LCD response: a plain on/off switch over the panel-response model in
// src/dingbat/common/lcd_response.nim. On, the core resolves the panel from
// the machine it is running (DMG / CGB / AGB-001, and nothing under a Super
// Game Boy) — the panel is never picked here. Two older shapes of this
// setting are still out there in stored records: the "Motion blur" 50/50
// interframe blend it replaced, and the six-way panel picker it shipped as.
// See loadVideoSettings for both migrations.
var lcdResponse = false;
// Every panel name the picker could store. All of them mean ON now: someone
// who chose a panel was asking for that machine's response, and the switch
// gives it to them. Anything not in here (a newer build's name, a corrupted
// record) falls back to off rather than sliding a bad value into wasm.
const LCD_LEGACY_ON = ["auto", "on", "true", "yes",
                       "dmg", "cgb", "gbc", "agb", "agb001", "gba",
                       "ags", "ags101", "sp"];
var ambientGlow = false;
var upscaleFilter = "none";  // "none" | "hq4x" | "xbr" — GPU upscale filter
// A smoothing filter and integer-scale pinning fight (integer pinning throws
// away the fractional smoothing), so a filter suspends integer-scale layout.
const filterActive = () => upscaleFilter !== "none";

// #canvas backing store = native resolution * GL_SCALE. The game texture is
// sampled NEAREST, so this is a crisp integer upscale (identical pixels to the
// old SDL logical-size scaling) that also keeps screenshots at their prior size.
const GL_SCALE = 4;

const canvasEl = /** @type {HTMLCanvasElement} */ (document.getElementById("canvas"));
const stageEl = document.getElementById("stage");
const glowCanvas = /** @type {HTMLCanvasElement} */ (document.getElementById("glow-canvas"));
const glowCtx = glowCanvas.getContext("2d");
const integerScaleToggle = /** @type {HTMLInputElement} */ (document.getElementById("integer-scale-toggle"));
const scanlinesToggle = /** @type {HTMLInputElement} */ (document.getElementById("scanlines-toggle"));
const lcdResponseToggle = /** @type {HTMLInputElement} */ (document.getElementById("lcd-response-toggle"));
const ambientGlowToggle = /** @type {HTMLInputElement} */ (document.getElementById("ambient-glow-toggle"));
const upscaleFilterSelect = /** @type {HTMLSelectElement} */ (document.getElementById("upscale-filter-select"));

// The presented picture's native size. The core is authoritative: it is the
// only thing that knows a Super Game Boy border has appeared and made the
// picture 256x224 instead of 160x144. The filename check stays as the
// bootstrap answer for the window before the core exists (updateCanvasScaling
// runs during load), and as the answer for GBA, which never changes shape.
const nativeRes = () => {
  if (typeof Module !== "undefined" && Module._wasm_out_w && currentRomName) {
    const w = Module._wasm_out_w(), h = Module._wasm_out_h();
    if (w > 0 && h > 0) return [w, h];
  }
  return currentRomName && extOf(currentRomName) !== ".gba" ? [160, 144] : [240, 160];
};

// The size of the buffer _wasm_fb_ptr / _wasm_game_fb_ptr point at, which is
// always the console's own framebuffer -- 160x144 even when a Super Game Boy
// border makes the PRESENTED picture 256x224. Everything that reads those
// pointers (thumbnails, the ambient-glow sampler, the paused card, the
// bug-report preview) must use this and not nativeRes(), or it walks off the
// end of the heap view. Those surfaces also look better without the border: a
// 160px-wide thumbnail of a bordered frame is mostly border.
const gameRes = () =>
  currentRomName && extOf(currentRomName) !== ".gba" ? [160, 144] : [240, 160];

// True while the running cart actually has an SGB adapter. Used to explain
// why the shade palette is inert rather than leaving a dead control.
const sgbActive = () =>
  !!(typeof Module !== "undefined" && Module._wasm_sgb_active &&
     currentRomName && Module._wasm_sgb_active());

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
    canvasEl.style.setProperty("--game-ar", /** @type {*} */ (canvasEl.width / canvasEl.height));
  }
  const ar =
    canvasEl.width > 0 && canvasEl.height > 0
      ? canvasEl.width / canvasEl.height
      : 1.5;
  const running =
    document.body.classList.contains("running") && !!currentRomName;
  // Available box = stage content box: clientWidth/Height include padding,
  // and the tablet-landscape tier reserves the control-rail width as stage
  // padding — the frame must yield to the rails, never sit under them.
  const stageCS = getComputedStyle(stageEl);
  const availW =
    stageEl.clientWidth -
    parseFloat(stageCS.paddingLeft) - parseFloat(stageCS.paddingRight);
  const availH =
    stageEl.clientHeight -
    parseFloat(stageCS.paddingTop) - parseFloat(stageCS.paddingBottom);
  if (integerScale && running && !filterActive()) {
    const [w, h] = nativeRes();
    const k = Math.max(1, Math.floor(Math.min(availW / w, availH / h)));
    canvasEl.style.width = k * w + "px";
    canvasEl.style.height = k * h + "px";
  } else if (running) {
    // Contain-fit: as large as the stage allows without changing shape
    const w = Math.min(availW, availH * ar);
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

// Pack a "#rrggbb" into the ABGR word the sampler compares against.
const glowPackHex = (c) => {
  const n = parseInt(String(c).replace("#", ""), 16) || 0;
  return (0xff000000 | ((n & 0xff) << 16) | (n & 0xff00) | ((n >> 16) & 0xff)) >>> 0;
};

const updateGlow = () => {
  if (glowCanvas.hidden || !currentRomName) return;
  if (typeof Module === "undefined" || !Module._wasm_glow_sample) return;
  if (glowTick++ % 6 !== 0) return;
  const gw = glowCanvas.width;
  const gh = glowCanvas.height;
  // The core composites and samples: it owns the colour LUT and the SGB
  // border, and it only touches the gw*gh cells we ask for instead of running
  // the whole frame through the LUT the way _wasm_fb_ptr does. See
  // wasm_glow_sample for what is deliberately NOT sampled (upscale filters,
  // scanlines, letterbox bars).
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

// True while the running game is a MONOCHROME Game Boy title. Only those have
// a four-shade screen to recolour: a Game Boy Color game draws from its own
// full-colour palettes and must come out exactly as the game intended, so the
// shade palette is gated on this and not merely on "the GB core is running".
// detectMonoPanel (loadRom) sets it; see there for how it is decided.
var gbMonoPanel = false;

// Decide it exactly the way the core does (new_gb in src/dingbat/gb/gb.nim):
// the screen is colour if the cartridge header's CGB flag is set (0x80
// CGB-enhanced, 0xC0 CGB-only) OR a CGB boot ROM is installed, because that
// boot ROM colourises monochrome carts itself and the result is no longer a
// four-shade image. GBA never applies.
//
// Reading the header here rather than exporting a flag from wasm is what keeps
// this whole feature inside the presentation layer: no Nim, no new core export,
// nothing that could touch emulated state. The shader is belt-and-braces on top
// — it substitutes only exact DMG shade values, so even a wrong answer here
// could not repaint a colour game's artwork.
const detectMonoPanel = (romFile) => {
  gbMonoPanel = false;
  if (extOf(romFile) === ".gba") return;
  try {
    const rom = FS.readFile(romFile);
    if (!rom || rom.length < 0x150) return;
    if ((rom[0x143] & 0x80) !== 0) return;      // CGB-enhanced or CGB-only
  } catch (e) { return; }
  try {
    // Matches the core's own test: present and larger than the 0x100-byte
    // DMG boot ROM (i.e. a real CGB boot ROM).
    if (FS.readFile("bootrom.bin").length > 0x100) return;
  } catch (e) { /* no boot ROM installed — monochrome stays monochrome */ }
  gbMonoPanel = true;
};

// The output size an SGB border changes mid-session. Watched here rather than
// pushed from the core, because it is the presenter that has to react: the
// canvas backing store, --game-ar and the integer-scale/contain-fit maths all
// key off nativeRes().
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
    // Under SGB colour the framebuffer no longer holds the four DMG shade
    // values the shader substitutes, so the palette would silently no-op.
    // Gate it here and say so in the UI (syncGbPaletteUI).
    dmgPalette: gbMonoPanel && !sgbActive() ? gbPaletteColors() : null,
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
  for (const [rowId, input] of /** @type {[string, HTMLInputElement][]} */ ([
    ["integer-scale-row", integerScaleToggle],
    ["scanlines-row", scanlinesToggle],
  ])) {
    document.getElementById(rowId)?.classList.toggle("suspended", sus);
    input.disabled = sus;
  }
};

const saveVideoSettings = () => {
  if (db) dbPut("video", { integerScale, scanlines, lcdResponse, ambientGlow, upscaleFilter });
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

scanlinesToggle.addEventListener("change", () => {
  scanlines = scanlinesToggle.checked;
  updateCanvasScaling();
  drawGame();  // scanlines are a shader uniform now — redraw to show it live
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
    // Two migrations, oldest first. "Motion blur" (a 50/50 interframe blend)
    // became the LCD response model; anyone who had it on wanted panel
    // ghosting, so the feature stays on for them rather than vanishing. The
    // model then shipped briefly as a six-way panel picker, which stored a
    // name here; every name it could store means on (LCD_LEGACY_ON), because
    // asking for a panel is asking for that machine's response.
    if (typeof v.lcdResponse === "boolean") lcdResponse = v.lcdResponse;
    else if (typeof v.lcdResponse === "string")
      lcdResponse = LCD_LEGACY_ON.includes(v.lcdResponse);
    else lcdResponse = !!v.motionBlur;
    ambientGlow = !!v.ambientGlow;
    if (typeof v.upscaleFilter === "string") upscaleFilter = v.upscaleFilter;
  }
  integerScaleToggle.checked = integerScale;
  scanlinesToggle.checked = scanlines;
  lcdResponseToggle.checked = lcdResponse;
  ambientGlowToggle.checked = ambientGlow;
  upscaleFilterSelect.value = upscaleFilter;
  updateSuspendedVideoToggles();
  applyLcdResponse();
  updateCanvasScaling();
};

window.addEventListener("resize", updateCanvasScaling);

// --- iOS rotation settle ---
// Rotating landscape -> portrait on iPhone can leave the touch-control
// strip's PAINTED pixels out of sync with where WebKit hit-tests them (the
// targets land above the buttons): the layout tier tears down the landscape
// position:fixed layers and re-resolves vw/cq/safe-area units, but iOS fires
// its resize events mid-rotation with stale numbers and may never re-raster
// the strip's composited layer. Hit-testing here is entirely DOM-based (no
// cached rects anywhere), so the fix is to force a fresh layout + composite
// AFTER the rotation settles: coalesced double-rAF plus a 350ms follow-up,
// re-running canvas scaling, nudging the strip's layer (the reflow read
// alone is often not enough on iOS), and releasing a mid-rotation joystick
// hold so no direction sticks.
{
  let settleTimer = null;
  const settleNow = () => {
    // Phantom scroll is the classic cause of "touch targets sit ABOVE the
    // painted buttons": iOS sometimes leaves the (position:fixed!) document
    // scrolled by a few dozen px after a rotation round-trip, and native
    // touch hit-testing follows the scroll while fixed-position paint does
    // not. Log it (visible via Toggle Log on-device), then zero it.
    const vv = window.visualViewport;
    // Not phantom: pinch-zoom sets vv.offsetTop legitimately (resetting
    // would yank the user's pan), and the iOS keyboard scrolls the page
    // while a field is focused (resetting would fight the caret).
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
    // Publish the MEASURED app height for the standalone body sizing:
    // visualViewport.height has none of 100vh's post-rotation staleness.
    // Skip while it's the on-screen KEYBOARD shrinking the visual viewport
    // (vv well below innerHeight) — the app must not resize under typing.
    if (vv && vv.height > 0 && vv.height >= window.innerHeight - 1) {
      document.documentElement.style.setProperty(
        "--app-h", Math.round(vv.height) + "px");
    }
    updateCanvasScaling();
    // Nudge the layers WebKit is most likely to have stale after rotation:
    // the control strip AND the fixed body root (landscape creates/destroys
    // fixed tiers on both).
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
  // Tilt cart: the D-pad (keyboard or touch) doubles as a tilt source — the
  // held directions become the tilt target, smoothed toward in updateTilt so
  // digital input still gives controllable analog motion. The real D-pad
  // press goes through too (menus use it; gameplay ignores it).
  if (tiltActive && inputId <= 3) {
    kbTiltDirs[inputId] = down;
    tiltTargetY = (kbTiltDirs[0] ? -TILT_KB_RANGE : 0) + (kbTiltDirs[1] ? TILT_KB_RANGE : 0);
    tiltTargetX = (kbTiltDirs[2] ? -TILT_KB_RANGE : 0) + (kbTiltDirs[3] ? TILT_KB_RANGE : 0);
  }
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
    // The visible label ("Z") only names the key; tell screen readers which
    // action this button rebinds.
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

// Rebinds commit immediately: apply to the live bindings and persist
const commitBindings = (bindings) => {
  applyKeybindings(bindings);
  if (db) dbPut("keybindings", activeBindings);
  kbPreset.value = detectPreset(activeBindings);
  renderKbBindings();
};

const kbKeyHandler = (e) => {
  if (kbSelection < 0) return;
  if (e.code === "Escape") {
    // Cancel the capture. Escape must never become a game binding: bound
    // keys pre-empt shortcuts, so a bound Escape stops closing every modal
    // app-wide with no visible cause.
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
  // Remove any existing binding for this key
  for (let i = 0; i < bindings.length; i++) {
    if (bindings[i] === sdl) bindings[i] = -1;
  }
  bindings[kbSelection] = sdl;
  // One key per click: ending capture here (no auto-advance) keeps a stray
  // extra keystroke from silently rebinding the next button in the list.
  kbSelection = -1;
  commitBindings(bindings);
};

const loadKeybindingsFromStorage = async () => {
  let stored = await dbGet("keybindings");
  if (stored && stored.length === INPUT_NAMES.length) {
    // Heal profiles saved before Escape became unbindable (see kbKeyHandler)
    applyKeybindings(stored.map((k) => (k === 27 ? -1 : k)));
  }
};

// --- Large on-screen controls (bigger d-pad for touch) ---
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

// --- Opaque controls in landscape (solid instead of see-through buttons) ---
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

// --- Hide touch controls while a game controller is connected (default on) ---
// pollGamepads maintains body.gamepad-hides-touch from the live connected
// state; the CSS gate only bites in the touch layout, so desktop is unaffected.
const hideTouchOnGamepadToggle = /** @type {HTMLInputElement} */ (document.getElementById("hide-touch-on-gamepad-toggle"));
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

// --- Run-ahead (latency reduction, opt-in) ---
// 0 = off (default): the tick loop calls plain loop_tick, the identical
// path that exists without this feature — zero cost until someone opts in.
// N > 0 swaps the single-core step for runahead_tick(N) (see the algorithm
// notes in docs/run-ahead.md). Deliberately not engaged during
// fast-forward/2x (N+1x the work for no latency benefit) and never in the
// frame-synced link modes.
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
// Recolours the four shades of a MONOCHROME Game Boy game. Purely a
// presentation setting: the substitution happens in the WebGL presenter's
// fragment shader (web/glpresent.js), never in the core, so the emulated
// framebuffer, save states, rewind and netplay are bit-for-bit unaffected by
// it. See GB_HW_SHADES below for why an exact substitution is possible.
//
// Three sources of shades are mutually exclusive, so they are ONE setting with
// a mode rather than two toggles that could contradict each other:
//   "default" — the shades the core itself produces (LCD colour model applied)
//   "theme"   — derived from the current app theme (GB_THEME_PALETTES)
//   "custom"  — four colours the user picked
// Its own Reset restores all of that (mode + the four custom colours) without
// touching any other preference — "Reset all settings" is a separate path.

// The four BGR555 values the GB core writes for DMG shades 0..3 — the literal
// contents of DMG_COLORS in src/dingbat/gb/gb.nim, expanded 5->8 bits. A
// monochrome game's framebuffer contains ONLY these four values (the DMG has
// no other colours to draw with), which is what makes recolouring an exact
// 4-way substitution in the shader instead of a fuzzy image filter. They are
// also the starting point for a custom palette, so "Custom" opens on what the
// user was already looking at.
// NOTE: these are the RAW hardware values; in "default" mode they additionally
// go through the CGB panel colour model, so the custom seed is very slightly
// more saturated than the default screen until the user edits it.
const GB_HW_SHADES = ["#fff7d6", "#ffad73", "#ef6b6b", "#7b3a5a"];

// One four-shade ramp per app theme, lightest (shade 0) to darkest (shade 3).
//
// The rules these follow, in order:
//  1. The theme's own main colour appears VERBATIM as one of the four — not a
//     tint of it. It is shade 1 everywhere except `light` (shade 2, because a
//     light theme's ink has to be the dark end), `famicom` (shade 1 is the
//     Famicom gold chrome, its identity colour) and `dmg` (see rule 5).
//  2. Themes that own several distinct colours spend them instead of inventing
//     tints: `dmg` uses the LCD paper, the shell grey, the magenta A/B buttons
//     and the near-black d-pad; `famicom` uses the cream faceplate, the gold
//     chrome, the garnet button ring and the charcoal buttons.
//  3. Everything else fills the remaining steps with tints/shades of the main
//     colour, ending on the theme's own --bg so the darkest shade belongs to
//     the same world as the chrome around the screen.
//  4. Every ramp is monotonically darkening with no two steps closer than
//     ~1.5:1 contrast — a collapsed pair is what makes a game unreadable.
//  5. …and no two ADJACENT steps more than ~45 CIEDE2000 apart. Monotonic
//     luminance is not enough: two shades can darken correctly and still be so
//     far apart in hue that dithering one against the other vibrates instead
//     of blending. Games spend most of a busy frame alternating shades 1 and 2
//     at the pixel level, so that pair in particular has to be near in hue.
//     This is what cost `dmg` its pea-green: green at shade 1 against magenta
//     at shade 2 measured 74 dE — twice the worst of any other ramp — and on
//     dithered art (Prehistorik Man's rock face is ~73% those two shades) it
//     read as a broken display. The shell grey costs the ramp nothing and
//     brings the pair down to 36, inside the band the other ten occupy.
const GB_THEME_PALETTES = {
  // Amber phosphor on near-black: pale amber, the accent itself, a deep amber
  // and an almost-black ember.
  amber:           ["#fff0d6", "#ffb04d", "#8f5312", "#1a1206"],
  // Same amber ink, but the darkest shade is the theme's true #000 (OLED).
  black:           ["#fff0d6", "#ffb04d", "#7a4a0f", "#000000"],
  // The one light theme: paper white -> gold -> the burnt-amber accent ->
  // the theme's own text ink.
  light:           ["#f3f4f8", "#d88a1f", "#9c5400", "#1d2433"],
  // Blue-violet accent verbatim, then a darkened shell purple, then --bg.
  indigo:          ["#cdc7f0", "#7f6ae7", "#55497f", "#0d0b17"],
  // Dusty rose accent verbatim; the shell rose is too close in luminance to
  // sit next to it, so shade 2 is a darkened version of it.
  fuchsia:         ["#f0ccd8", "#e8739a", "#7e4560", "#170a0f"],
  // Periwinkle accent verbatim; shade 2 is the shell grey-blue darkened.
  glacier:         ["#ccd9f0", "#769be5", "#3c4a6b", "#0b0e16"],
  // The bright kiwi shell green verbatim. It is so luminous that shade 0 has
  // to be a very pale green for the two to separate at all.
  kiwi:            ["#effbea", "#6ee126", "#2d7a1f", "#0c170b"],
  // Four DISTINCT DMG colours: the pale LCD, the shell grey the console is
  // moulded in, the magenta A/B buttons, the near-black d-pad. The one theme
  // whose --accent (the pea-green #9cc954) is deliberately NOT in its ramp —
  // see rule 5. The magenta stays because shade 2 is a small share of flat
  // art, where it lands on exactly the details the artist accented.
  dmg:             ["#eaf3de", "#b4aca9", "#6f6a6d", "#262828"],
  // Orchid accent verbatim; shade 2 is the shell violet darkened.
  "atomic-purple": ["#e7cbf0", "#c36ee7", "#6a3d80", "#120b16"],
  // Burnt-orange accent verbatim; shade 2 is the shell orange darkened.
  daiei:           ["#f2d2b0", "#eb7c33", "#8c3d18", "#160f0b"],
  // Four DISTINCT Famicom colours: cream faceplate, gold chrome, the garnet
  // A/B ring, the charcoal buttons. (The --accent #e0635c is the ring red
  // lightened; the ring itself is used because it keeps the ramp separated.)
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

// The theme the palette derives from. Read off the root element rather than
// out of localStorage: <html data-theme> is what applyTheme actually put in
// force (and what the pre-paint boot script set), so this can never disagree
// with the chrome on screen — including on the paths that change the theme
// without writing it back, like Reset all settings.
const currentThemeName = () => {
  const n = document.documentElement.getAttribute("data-theme") || "amber";
  return GB_THEME_PALETTES[n] ? n : "amber";
};

// The four shades in force right now, or null for "leave the core's own
// colours alone" — which is both the "default" mode and every non-monochrome
// game, whatever the mode says.
const gbPaletteColors = () => {
  if (gbPaletteMode === "theme") return GB_THEME_PALETTES[currentThemeName()];
  if (gbPaletteMode === "custom") return gbPaletteCustom;
  return null;
};

const gbPaletteSgbNote = document.getElementById("gb-palette-sgb-note");

const syncGbPaletteUI = () => {
  if (gbPaletteSelect) gbPaletteSelect.value = gbPaletteMode;
  if (gbPaletteCustomRow) gbPaletteCustomRow.hidden = gbPaletteMode !== "custom";
  // Under SGB colour the shader has nothing to substitute (the framebuffer no
  // longer holds DMG shade values), so the control is disabled with a reason
  // rather than left live and inert.
  const sgb = sgbActive();
  if (gbPaletteSelect) gbPaletteSelect.disabled = sgb;
  if (gbPaletteSgbNote) gbPaletteSgbNote.hidden = !sgb;
  // The In-use swatches and the Reset button belong to the same control.
  for (const r of document.querySelectorAll(".gb-palette-row"))
    r.classList.toggle("row-disabled", sgb);
  for (let i = 0; i < 4; i++) {
    if (gbPaletteInputs[i]) gbPaletteInputs[i].value = gbPaletteCustom[i];
  }
  // The preview is the only place "theme" mode shows its colours, and it is
  // also what tells a user on a colour game that nothing is being recoloured.
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
  // Shader uniform: repaint even if emulation is paused / stepped no frame.
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

// Reset THIS setting only. Deliberately its own button rather than a corner of
// "Reset all settings": undoing a palette experiment should not cost you your
// keybindings.
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

// --- Chrome theme (background / buttons / menus color scheme) ---
// Persisted in localStorage — NOT IndexedDB — so the inline <head> script can
// apply it synchronously before first paint (no flash of the wrong theme).
// "amber" is the default and maps to no data-theme attribute at all.
const THEME_KEY = "dingbat_theme";
const THEME_NAMES = ["amber", "black", "light", "dmg", "kiwi", "atomic-purple",
  "indigo", "fuchsia", "glacier", "daiei", "famicom"];
// "emerald" was renamed to "kiwi" (the GBC's original color name). Migrate any
// value persisted under the old name so it doesn't fall back to Amber.
const migrateTheme = (name) => (name === "emerald" ? "kiwi" : name);
const themeChips = Array.from(/** @type {NodeListOf<HTMLElement>} */ (document.querySelectorAll("#theme-picker .theme-chip")));
// Present in every mode now (the boot script keeps it): iOS fills the standalone
// safe areas from it, and browser tabs tint their chrome with it.
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
  // The theme-color meta is what iOS fills the standalone safe areas (status bar
  // + home-indicator strip) with, and what tints browser chrome in a tab. Match
  // --bg (the page / controls-deck bottom) so the bottom strip blends into the
  // app under every theme. Derived from the live token so CSS stays the single
  // source of truth (the boot-script map is only a pre-CSS hint).
  if (themeColorMeta) {
    const cs = getComputedStyle(document.documentElement);
    themeColorMeta.content =
      (cs.getPropertyValue("--bg").trim() ||
       cs.getPropertyValue("--topbar-top").trim());
  }
  // "Match the app theme" is derived, not stored — a theme switch has to
  // re-derive it and repaint the screen.
  applyGbPalette();
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
  const migrated = migrateTheme(storedTheme);
  if (migrated !== storedTheme) {
    try { localStorage.setItem(THEME_KEY, migrated); } catch (e) {}
  }
  applyTheme(migrated);
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
  "runahead", "gb-palette",
];

const resetAllSettings = async () => {
  for (const k of SETTINGS_KEYS) await dbDelete(k);
  try { localStorage.removeItem(UPDATE_CHECK_KEY); } catch (e) {}

  // System (GB renderer / GBA BIOS mode + intro / rumble)
  gbFifo = true; gbaBiosMode = 0; gbaRunBios = true; gbRumble = true;
  rewindOn = true;
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
  audioLowpass = false;   // (was previously missed by reset)
  if (lowpassToggle) lowpassToggle.checked = false;
  applyAudioLowpass();

  // Color correction
  colorCorrect = true;
  ccToggle.checked = colorCorrect;
  applyColorCorrect();

  // Video effects
  integerScale = false; scanlines = false; lcdResponse = false; ambientGlow = false;
  upscaleFilter = "none";
  integerScaleToggle.checked = false;
  scanlinesToggle.checked = false;
  lcdResponseToggle.checked = false;
  ambientGlowToggle.checked = false;
  upscaleFilterSelect.value = "none";
  updateSuspendedVideoToggles();
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

  // Run-ahead -> off
  applyRunahead(0);

  // Game Boy shade palette -> default shades, custom colours back to hardware.
  // (The dbDelete above already removed the record; this restores the live
  // state, exactly as its own Reset button would.)
  gbPaletteMode = "default";
  gbPaletteCustom = GB_HW_SHADES.slice();
  applyGbPalette();

  // Super Game Boy -> on, border shown (the "system" record was already
  // deleted above; this restores the live state and pushes it into the core).
  sgbEnable = false;
  sgbBorder = true;
  applySystemSettings();
  syncSystemSettingsUI();

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
var slowMotion = false;
var rewindHeld = false;
var lastRewindPop = 0;
// Tilt cart (MBC7 — Kirby Tilt 'n' Tumble): when the running cart has an
// accelerometer, gamepad stick / keyboard-touch D-pad / device orientation
// feed a smoothed tilt vector to wasm_set_tilt each RAF tick.
var tiltActive = false;
var tiltTargetX = 0, tiltTargetY = 0;   // where input wants the tilt to be
var tiltX = 0, tiltY = 0;               // smoothed value actually sent
var tiltOrientationOn = false;          // device-orientation stream attached
var tiltNeutral = null;                 // neutral hold pose, in SCREEN space
var padTiltLive = false;                // gamepad stick currently owns the target
var kbTiltDirs = [false, false, false, false]; // held U/D/L/R while tilting
var tiltKind = 0;                       // 1 = accelerometer cart, 2 = gyro cart

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

const loadRom = async (romName, originalName, opts = {}) => {
  // A capture or recording spanning a ROM switch would splice two games
  if (typeof abortRetroClip === "function") abortRetroClip();
  if (typeof stopClipRecording === "function") stopClipRecording();
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
  // Before `paused` is reset below: a scrubber left open across a ROM switch
  // would scrub the old game's strip against the new game's core, and closing
  // it restores the paused state it captured — which must land on the OLD
  // session's value and then be overwritten, not the other way round.
  closeRewindScrubber();
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
  // GB/GBC has no shoulder buttons: flag CSS to drop the L/R row so the
  // frame gets that vertical space back (see body.gb-mode rules).
  document.body.classList.toggle("gb-mode", systemOf(romName) !== "GBA");
  document.body.classList.add("has-game", "running");
  // Restore save for the new ROM
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
  // async: "Resume last session?" toast if one exists (the reset button
  // opts out — it shows its own Undo toast for the state it just discarded)
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

// --- ROM header sanity check ---
// A garbage file with a plausible extension used to "play" as a silent black
// screen and then get enshrined in the Recent library, so sniff the header
// before accepting a ROM. The cores themselves never validate any of this,
// and lots of homebrew is raw objcopy output with NO Nintendo logo and an
// unfixed checksum (this repo's own tests/roms/*.gba are exactly that, some
// smaller than the 0xC0-byte GBA header) — so the rule is deliberately
// any-signal-matches, and a failed check only asks, never blocks:
//   .gba — valid if byte 3 is 0xEA (the cartridge entry point is an ARM
//          branch instruction — true of every licensed ROM and of raw
//          objcopy homebrew alike, and the only signal tests/roms/*.gba
//          carry), OR the Nintendo logo bitmap at 0x004 matches, OR the
//          header checksum at 0xBD is the complement-sum over 0xA0-0xBC
//          (per GBATEK).
//   .gb/.gbc — valid if the Nintendo logo at 0x104 matches (the same bytes
//          the emulator's own multicart detection keys on, src/dingbat/gb/
//          mbc/mbc.nim), OR the header checksum at 0x14D matches Pan Docs'
//          sum over 0x134-0x14C. rgbfix fixes the checksum even on logo-less
//          homebrew — this repo's tests/roms/*.gb(c) pass via that arm.
// An 8-byte prefix of each logo is checked — already a 2^64 signal, and it
// keeps the constants short.
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

// Ask before loading a file that failed the sanity check. Resolves true to
// proceed, false to drop the file (nothing loads, nothing enters the
// library). Cancel, ×, backdrop and Escape all decline.
const romWarnModal = document.getElementById("rom-warn-modal");
let romWarnResolve = null;

const settleRomWarn = (proceed) => {
  let resolve = romWarnResolve;
  romWarnResolve = null; // closeRomWarnModal must not double-resolve
  romWarnModal.classList.remove("open");
  releaseFocus(romWarnModal);
  if (resolve) resolve(proceed);
};

// Called blindly by the global Escape handler; a no-op while not open.
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
      let bytes = new Uint8Array(/** @type {ArrayBuffer} */ (reader.result));
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

const togglePause = () => {
  paused = !paused;
  pauseButton.classList.toggle("paused", paused);
  pauseButton.classList.toggle("active", paused);
  pauseButton.title = paused ? "Resume" : "Pause";
  document.body.classList.toggle("paused", paused);
};

// iOS suppresses the synthesized `click` for a SECOND finger while the first
// is held on the (preventDefaulted) touch controls — which made Pause dead
// exactly when someone held A to frame-step. Drive it from pointerup, and
// keep the click listener (programmatic .click() callers, keyboards) behind
// a short lockout so a pointer-handled tap can't double-toggle.
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
  // Reset with a way back: snapshot the state being thrown away and offer
  // it on a toast, exactly like loading a save state does. The auto-resume
  // offer is suppressed for this reload — right after a deliberate reset it
  // is stale noise, and it would race this toast for the shared slot.
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

// 2x speed and unbounded fast forward are radio-style: fast forward would
// silently dominate 2x (it ignores pacing entirely), so enabling either
// clears the other.
const setSpeed2x = (on, fromRemote) => {
  speed2x = on;
  speed2xButton.classList.toggle("active", on);
  if (on && slowMotion) setSlowMotion(false);
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
  if (on) setSlowMotion(false);
};

// Slow motion (0.5x): the tick loop doubles the per-frame wall-clock step
// while the wasm shim fills the sample gap — doubled samples (octave-down)
// normally, or a WSOLA 1:2 stretch when pitch-correct fast-forward is on
// (see wasm_set_slowmo/appendAudioSample). Radio-exclusive with FF/2x.
// Toggled from the kebab menu item or Shift+`.
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

// The three speed flags are radio-exclusive, so they collapse to one value.
// Momentary speed keys (hold Tab) snapshot it on press and put it back on
// release, which is what makes a hold an overlay rather than a mode switch.
const currentSpeedMode = () =>
  fastForward ? "ffw" : speed2x ? "2x" : slowMotion ? "slow" : "normal";
// Order matters: the setters clear each other, so the wanted one goes last.
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

// 2x speed: the core drops every other audio sample (pitched-up realtime
// audio) while the tick loop halves its per-frame time step
speed2xButton.addEventListener("click", () => {
  setSpeed2x(!speed2x);
  if (speed2x) setFastForward(false);
});

// Frame advance: while paused, run exactly one emulated frame and present
// it. The frame's audio sliver is discarded (13ms of sound per press is
// noise). Reached from the top-bar step button (which replaces 2x/FFW while
// paused) and the "." key; key-repeat and press-and-hold both crawl.
const frameAdvance = () => {
  if (typeof Module === "undefined" || !Module._loop_tick) return;
  if (!paused || !currentRomName || !speedControlsOk()) return;
  Module._loop_tick();
  if (Module._clearAudioBuffer) Module._clearAudioBuffer();
  drawGame();
};

// --- Retroactive clip capture ("Save Last 10s") ---
// The wasm side keeps a rolling window: one state anchor per second plus a
// 2-byte-per-frame input log (see the clip_* block in dingbat_wasm.nim).
// clip_begin rewinds the core to the best anchor; the tick loop then steps
// clip_tick at realtime — a deterministic replay of what the player just
// did — while a MediaRecorder captures the canvas and the master-gain audio
// tap. When the log runs out the live state is restored and the file saves.
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
const clipBanner = document.getElementById("clip-banner");
const updateClipBanner = (left) => {
  const pct = clipTotalFrames > 0
    ? Math.min(100, Math.round(100 * (clipTotalFrames - left) / clipTotalFrames)) : 0;
  clipBanner.textContent = `Capturing the last ${Math.round(clipTotalFrames / 60)}s… ${pct}%`;
};

const startRetroClip = () => {
  if (clipReplayActive || !currentRomName || !speedControlsOk()) return;
  const mime = clipMimeType();
  if (!mime) { showToast("Video recording isn't supported in this browser"); return; }
  const frames = Module._clip_begin ? Module._clip_begin(10) : 0;
  if (frames <= 0) { showToast("Not enough gameplay history yet"); return; }
  let stream;
  try {
    stream = canvasEl.captureStream(60);
  } catch {
    Module._clip_abort();
    showToast("Couldn't capture the game canvas");
    return;
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
    return;
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
    a.download = `${base}-last10s-${stamp}.${ext}`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
    showToast("Clip saved");
  };
  clipRecorder.start(500);
  clipReplayActive = true;
  clipTotalFrames = frames;
  document.body.classList.add("clip-replaying");
  clipBanner.hidden = false;
  updateClipBanner(frames);
  paused = false; // the replay must run even if the game was paused
};

clipLastItem.addEventListener("click", () => {
  menuDropdown.hidden = true;
  startRetroClip();
});

// Frame-step is fully pointer-driven: tap = one frame, press-and-hold
// repeats at 10/s (the touch analogue of holding "."). Pointer events, not
// click — iOS won't synthesize click for a second finger while a game
// button is held, and stepping WHILE holding a button is the whole point.
// --- Forward clip recording (Record Clip menu item) ---
// MediaRecorder over the game canvas (shader output included) plus the
// master-gain audio tap; saves .webm (.mp4 where that's what the browser
// records — Safari). Single-core modes only (CSS hides the item elsewhere).
var recRecorder = null;
var recChunks = [];
var recStopTimer = null;
const recordClipItem = document.getElementById("record-clip");
const REC_MAX_MS = 5 * 60 * 1000; // a forgotten recorder stops itself

const setRecMenuState = (recording) => {
  recordClipItem.querySelector("span").textContent =
    recording ? "Stop Recording" : "Record Clip";
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

// Capture accordion: Screenshot / Record Clip / Save Last 10s live under
// one expandable "Capture" entry so the menu's top level stays short.
const captureToggle = document.getElementById("capture-toggle");
const captureSub = document.getElementById("capture-sub");
const collapseCaptureSub = () => {
  captureSub.hidden = true;
  captureToggle.setAttribute("aria-expanded", "false");
};
captureToggle.addEventListener("click", (e) => {
  // The document-level click handler closes the dropdown on any click that
  // bubbles to it — right for leaf items, wrong for an accordion header.
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
  // Programmatic .click() (and any browser that skips pointer events)
  frameStepButton.addEventListener("click", () => {
    if (performance.now() - stepPointerTs < 350) return;
    frameAdvance();
  });
}

// Rewind: hold to step history backward (the tick loop pops snapshots at a
// fixed cadence while held)
// Gated here rather than at each caller: the button gesture, the ` key and
// netplay's teardown all funnel through this, and with rewind off there is no
// ring to pop from — the tick loop would burn 30 pops a second on nothing.
// Only turning it ON is refused; turning it off always works.
const setRewindHeld = (on) => {
  rewindHeld = on && rewindOn;
  rewindButton.classList.toggle("active", rewindHeld);
};

// The button's first job is the hold, and the hold is instant: pointerdown
// rewinds, full stop. Nothing is delayed, buffered or classified first — an
// earlier design that waited to see whether a second press was coming made
// every rewind feel late, and lateness is the one thing this control cannot
// afford.
//
// The film strip is layered on top as a DOUBLE TAP, recognised only after the
// fact so it can never hold the rewind up. Two quick taps: the first rewinds a
// fraction of a second and that simply stands (nothing is rolled forward
// again), the second opens the strip. A press held longer than a tap is a
// deliberate rewind and never counts towards the gesture, so hold, release,
// hold again behaves exactly as it always did. The menu item stays; this is a
// shortcut to it, not its only door.
//
// Recognised from POINTER events, not `dblclick`. dblclick belongs to the
// compatibility mouse-event family, and the preventDefault() below — which
// this button needs so a press does not turn into a text selection or a
// scroll — is entitled to suppress that family. Measured against this build:
// WebKit fires neither click nor dblclick on this button, and Chromium fires
// click but not dblclick. A dblclick handler would have been dead code on
// every platform. One pointer path covers mouse, touch and pen instead, with
// no UA guessing and no synthesised second opening to defend against.
//
// The platform is already out of the way: `body { touch-action: none }` in
// styles.css means there is no double-tap-to-zoom to fight and no legacy
// 300 ms click delay to sit behind, so the windows below are the gesture's
// own numbers rather than something inherited.
const RW_TAP_MAX_MS = 250;    // a press longer than this is a hold, never a tap
const RW_DBLTAP_MS = 300;     // from the first tap's release to the second's press
const RW_DBLTAP_SLOP = 28;    // px a press may travel, and the two taps may differ by
{
  // One pointer owns the hold. A second finger arriving while the first is
  // down is ignored outright: it does not re-arm the hold, it does not count
  // as a tap, and — the part that used to bite — its release no longer stops a
  // rewind the other finger is still asking for.
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

  // pointerup is the only release that can complete a tap. pointerleave and
  // pointercancel mean the press went somewhere else (dragged off the button,
  // stolen by a system gesture) and just end the hold.
  const endPress = (e) => {
    if (holdId === null || (e.pointerId !== undefined && e.pointerId !== holdId)) return;
    holdId = null;
    setRewindHeld(false);
    if (e.type !== "pointerup") return;
    const x = e.clientX || 0;
    const y = e.clientY || 0;
    const now = performance.now();
    // A tap: short, and it ended where it started (a press dragged across the
    // top bar is a mis-hit, not half a gesture).
    if (now - downTs > RW_TAP_MAX_MS || !near(x, y, downX, downY, RW_DBLTAP_SLOP)) {
      tapTs = 0;
      return;
    }
    // Second of a pair? The window is measured from the first tap's release to
    // this one's PRESS, so a slow-but-deliberate second tap is not penalised
    // for how long the finger stayed down.
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
// The speed that was latched when the fast-forward key went down. Releasing
// restores it, so Tabbing through a cutscene while parked at 2x (or slow
// motion) lands back there instead of dumping the player at 1x.
var kbSpeedBeforeHold = "normal";
const endKbFastForward = () => {
  if (!kbFastForward) return;
  kbFastForward = false;
  // Something else claimed the speed while the key was down (clicked 2x,
  // slow motion from the menu — both clear fast-forward): that choice is
  // newer than the snapshot, so leave it standing.
  if (!fastForward) return;
  applySpeedMode(kbSpeedBeforeHold);
};
const releaseKbHolds = () => {
  endKbFastForward();
  if (kbRewindHeld) {
    kbRewindHeld = false;
    setRewindHeld(false);
  }
};
window.addEventListener("blur", releaseKbHolds);

const shortcutKeyHandler = (e, down) => {
  // A retroactive-capture replay owns the machine: no state loads, speed
  // changes or pauses until it finishes (game keys still pass — the wasm
  // side records them as the post-replay held state).
  if (typeof clipReplayActive !== "undefined" && clipReplayActive) return;
  if (codeLookup[e.code] !== undefined) return; // game bindings always win
  if (e.ctrlKey || e.metaKey || e.altKey) return; // browser/OS chords

  // Releases skip the modal/typing guards: a hold must not stay stuck on
  // when a modal opens (or focus lands in a field) before the keyup.
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
      // (Tab with focus in the top bar / menu never reaches this handler —
      // the window-capture hook at the top of the file keeps it as focus
      // traversal so keyboard users can operate the chrome during play.)
      if (e.shiftKey) {
        // Toggle 2x — radio with fast-forward, same as the buttons
        if (linkMode || netActive()) break;
        if (!e.repeat) {
          setSpeed2x(!speed2x);
          if (speed2x) setFastForward(false);
        }
        handled = true;
      } else {
        // Hold for unbounded fast-forward, restoring the previous speed on
        // release. Holding the key for the speed you are ALREADY in reads as
        // "turn this off", so a latched fast-forward restores to 1x — the
        // same place a second click of the button would leave you.
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
        // Shift+` toggles slow motion — the inverse of Shift+Tab's 2x
        if (!e.repeat) setSlowMotion(!slowMotion);
        handled = true;
        break;
      }
      // With rewind switched off the key is not ours: fall through unhandled
      // rather than swallowing ` for a feature that is not running.
      if (!rewindOn) break;
      if (!kbRewindHeld) {
        kbRewindHeld = true;
        setRewindHeld(true);
      }
      handled = true;
      break;
    case "Period":
      // Frame advance, mGBA-style: first press pauses, further presses (key
      // repeat included) step one frame each. Single-core only — loop_tick
      // is a no-op in the linked modes and would desync them anyway.
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
  // Same runtime gate as launchRom: the 2P button exists on tiles that render
  // before the wasm runtime is up.
  await ensureRuntimeReady();
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

// --- Paused-game card (home screen) ---
// A frozen frame of the paused game shown beside Resume, so it's clear which
// game Resume returns to. Pixels come from the wasm-side presented
// framebuffer, exactly like the ambient glow sampler — the game canvas is a
// WebGL context without preserveDrawingBuffer, so reading the canvas itself
// after pausing yields nothing.
const homePausedCard = document.getElementById("home-paused");
const homePausedCanvas = /** @type {HTMLCanvasElement} */ (document.getElementById("home-paused-canvas"));
const homePausedName = document.getElementById("home-paused-name");

const updatePausedCard = () => {
  homePausedCard.hidden = true;
  // Single-core sessions only (the glow sampler's condition): 2P/online modes
  // render to their own canvases, not the shared framebuffer.
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
  // The wasm fb's alpha channel is not meaningful; force opaque (as the glow
  // sampler does).
  for (let i = 3; i < img.data.length; i += 4) img.data[i] = 255;
  ctx.putImageData(img, 0, 0);
  homePausedName.textContent = displayName(currentOriginalName);
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
  // The cheat list belongs to the game that just left. Holding it would leave
  // the Cheats modal listing a game that is closed — or, after the Manage-ROMs
  // Delete (which unloads first, then deletes), listing a game that no longer
  // exists. loadRom's restoreCheats refills this for the next game.
  cheatList = [];
  renderCheatList();
  paused = true; // keep the orphaned core frozen
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  document.body.classList.remove("has-game", "running", "paused", "gb-mode");
  // No cart, no sensor: drop the camera rather than leaving the recording
  // light on — and the button with it, since "Enable camera" over the home
  // screen would enable it for nothing.
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
// The GBA canvas is a WebGL context without preserveDrawingBuffer, so its
// pixels are only valid within the render task. captureCanvas() is therefore
// called from the main loop right after a fresh frame is drawn.
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

// Gamepad inside Settings. Worth wiring given the product: the shoulder
// buttons cycle sections in the same fixed order and with the same wrapping as
// the sheet's stepper, the d-pad walks the pane's controls, A activates and B
// goes back or closes. Everything it reads is consumed — with the dialog up,
// no button reaches the game.
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
    // Tilt cart: the left stick doubles as the accelerometer (full analog
    // range). Only claims the tilt target while deflected so the keyboard /
    // device-orientation sources aren't fought over a centered stick.
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
    // Absorb the edges: a button held across the close must not arrive at the
    // game as a fresh press.
    for (let i = 0; i < 10; i++) gpPrev[i] = want[i];
    return;
  }
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

// --- Tilt cart input (MBC7: Kirby Tilt 'n' Tumble) ---
// Three sources feed a shared target: gamepad left stick (analog, best),
// keyboard/touch D-pad (digital, smoothed), and the phone's real orientation
// sensor. The target is eased toward each RAF tick so digital input rolls
// the ball rather than teleporting the tilt. iOS requires the motion
// permission be requested from a user gesture, so the offer is an action
// toast shown at game load — tapping it is the gesture.
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

// Jolt channel: Kirby's jump is a sharp FLICK of the device, which the game
// detects as an out-of-range acceleration transient. Orientation alone
// underreports it, so devicemotion's linear acceleration rides on top, and
// decays fast so a jolt is a spike rather than a lean.
var tiltJoltX = 0, tiltJoltY = 0;

const updateTilt = () => {
  if (!tiltActive || typeof Module === "undefined" || !Module._wasm_set_tilt) return;
  if (tiltOrientationOn) {
    if (Date.now() < tiltGlideUntil) {
      // Glide across a discontinuity WE introduced — a recenter, or the
      // re-baseline after a rotation. The cart derives acceleration from the
      // sensor value, so stepping that value instantly is indistinguishable
      // from a violent flick, and Kirby jumps. Easing over a few hundred ms
      // keeps the same destination without the transient. Only the step is
      // smoothed; steady-state motion below still passes raw.
      tiltX += (tiltTargetX - tiltX) * TILT_GLIDE_RATE;
      tiltY += (tiltTargetY - tiltY) * TILT_GLIDE_RATE;
    } else {
      // Real sensor: pass raw. Easing every sample would low-pass away
      // exactly the flick transient the jump detector needs.
      tiltX = tiltTargetX;
      tiltY = tiltTargetY;
    }
  } else {
    tiltX += (tiltTargetX - tiltX) * TILT_SMOOTHING;
    tiltY += (tiltTargetY - tiltY) * TILT_SMOOTHING;
  }
  const clamp3 = (v) => Math.max(-3, Math.min(3, v)); // flicks may exceed 1g;
  // the MBC7 latch (center 0x81D0, 0x70/g) has headroom to ±3g without wrap
  // Negated at this single send point (all sources agree): on hardware the
  // ball rolls INTO the tilt — marble on a tray — and the phone test showed
  // the raw mapping ran backwards. GBATEK notes the sensor axes mirror
  // between console form factors, so the sign was always empirical.
  Module._wasm_set_tilt(clamp3(-(tiltX + tiltJoltX)), clamp3(-(tiltY + tiltJoltY)));
  tiltJoltX *= 0.55;
  tiltJoltY *= 0.55;
};

const motionJoltHandler = (e) => {
  if (!tiltActive) return;
  if (tiltKind === 2) {
    // Gyro cart: the sensor measures rotation RATE around the screen
    // normal. 180 deg/s = the hard-rotation extreme.
    const rr = e.rotationRate;
    if (rr && rr.alpha != null) {
      tiltTargetX = Math.max(-1, Math.min(1, rr.alpha / 180));
    }
    return;
  }
  // Detect the turn from the motion itself, not from orientationchange.
  // That event fires only once the OS has decided the orientation changed —
  // by then the turn's acceleration has already been fed to the core and
  // Kirby has jumped. rotationRate.alpha is rotation about the screen
  // normal, exactly the portrait<->landscape axis, and it is live DURING
  // the turn.
  //
  // Integrate it SIGNED. A turn is ~90 degrees sustained one way; a jump
  // flick twists the wrist and twists straight back, so it nets near zero
  // however hard it was thrown. An absolute integral counts both halves of
  // that flick and trips on it — which is what made jumping feel harder.
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
  // Linear acceleration (gravity excluded), in g, rotated into screen space
  // like the orientation channel — a flick must stay a flick in landscape.
  // Only spikes matter: below ~0.4g it's hand tremor and must not disturb
  // the tilt.
  const [gx, gy] = toScreenFrame(ax / 9.81, ay / 9.81);
  if (Math.abs(gx) > 0.4) tiltJoltX = Math.max(-3, Math.min(3, gx * 1.5));
  if (Math.abs(gy) > 0.4) tiltJoltY = Math.max(-3, Math.min(3, gy * 1.5));
};

// beta/gamma (and devicemotion's acceleration) are expressed against the
// device's NATURAL orientation, not the current one. Rotate them into screen
// space or landscape play is wrong twice over: the game's left/right axis
// becomes the phone's pitch, and the comfortable hold angle turns into a
// large constant lean.
const screenAngle = () => {
  const so = screen.orientation;
  if (so && typeof so.angle === "number") return ((so.angle % 360) + 360) % 360;
  // Legacy iOS (pre-16.4): window.orientation is the NEGATIVE of the
  // standard angle, so landscape-left reports +90 where the spec says 270.
  const w = typeof window.orientation === "number" ? -window.orientation : 0;
  return ((w % 360) + 360) % 360;
};

// Device frame -> screen frame: rotate by -angle.
const toScreenFrame = (x, y) => {
  const rad = (screenAngle() * Math.PI) / 180;
  const c = Math.cos(rad), s = Math.sin(rad);
  return [x * c + y * s, -x * s + y * c];
};

const orientationTiltHandler = (e) => {
  if (!tiltActive || tiltKind === 2) return; // gyro carts use rotation RATE
  if (e.beta == null || e.gamma == null) return;
  if (tiltSettling()) {
    // Mid-rotation: FREEZE at the last value rather than tracking a pose the
    // player is only passing through. Snapping to level here would be its own
    // step change, which is exactly what makes the cart read a flick.
    // tiltNeutral stays null so the first settled reading defines neutral.
    return;
  }
  const [sx, sy] = toScreenFrame(e.gamma, e.beta);
  // First reading after a (re)baseline defines neutral: people play holding
  // the phone at ~30-50°, not flat on a table. Baselining BOTH axes in
  // screen space is what makes every orientation behave the same — in
  // landscape the hold angle lands on x instead of y.
  if (tiltNeutral === null) tiltNeutral = { x: sx, y: sy };
  const clamp = (v) => Math.max(-1, Math.min(1, v));
  tiltTargetX = clamp((sx - tiltNeutral.x) / TILT_ORIENT_RANGE);
  tiltTargetY = clamp((sy - tiltNeutral.y) / TILT_ORIENT_RANGE);
};

// Rotating the device changes which physical axis is "left/right" AND the
// pose the player is holding, so the old neutral is meaningless. Re-baseline
// once the phone has stopped moving — sampling mid-rotation would capture a
// pose nobody is holding. Applies to MBC7 and GBA tilt alike (same handler).
// Turning the phone IS a large linear acceleration, and the jolt channel
// cannot tell it from the sharp flick that makes Kirby jump — so rotating
// made him jump. Motion input is therefore frozen at neutral across the
// rotation and only resumes once the phone has settled, which also stops the
// wild mid-rotation orientation readings from lurching the tilt.
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
    // iOS 13+: permission gate (non-standard static, hence the cast), must
    // be called from a user gesture — the action toast's tap and the top-bar
    // button's click both provide it, which is why neither route awaits
    // anything before reaching this line.
    const doe = /** @type {*} */ (
      typeof DeviceOrientationEvent !== "undefined" ? DeviceOrientationEvent : null);
    if (doe && typeof doe.requestPermission === "function") {
      const res = await doe.requestPermission();
      if (res !== "granted") {
        showToast("Motion permission denied — D-pad and stick still tilt");
        return;
      }
    }
    // Motion (the jump-flick channel) shares the same iOS permission sheet;
    // request explicitly where the API exists, best-effort elsewhere.
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
    // Granted or refused, the button has to re-read the world: on success it
    // becomes Recenter, on refusal it stays the way back in.
    tiltCartBtnUpdate();
  }
};

// Device tilt is only offered where it could possibly work: a phone or tablet
// with an orientation sensor. On a desktop the D-pad and stick are the whole
// story, and an "Enable tilt" button there would be a dead end.
const tiltCanOrient = () =>
  typeof DeviceOrientationEvent !== "undefined" &&
  ("ontouchstart" in window || navigator.maxTouchPoints > 0);

// The top-bar cart button, in its two states. Before the orientation listener
// is attached it is the way IN — a permanent affordance, because the load-time
// offer toast is easy to miss and there is no way to ask for it again. Once
// tilt is running it is Recenter, which is what a player actually needs mid-
// game. "Not yet on" is the real listener state, never a guess: nothing sets
// tiltOrientationOn but the branch that succeeded in attaching the handlers.
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

// Recenter: whatever angle the phone is at RIGHT NOW becomes neutral —
// tilt games are unplayable after shifting in a chair without this.
const tiltRecenterBtn = document.getElementById("tilt-recenter");
const tiltRecenterLabel = document.getElementById("tilt-recenter-label");
tiltRecenterBtn.addEventListener("click", () => {
  // Straight off the click with nothing awaited first: iOS grants the motion
  // permission only from inside a real user gesture, and a single `await`
  // ahead of requestPermission() is enough to lose it.
  if (!tiltOrientationOn) { enableOrientationTilt(); return; }
  tiltNeutral = null; tiltGlideUntil = Date.now() + TILT_GLIDE_MS; // next orientation reading re-baselines
  tiltJoltX = tiltJoltY = 0;
  showToast("Tilt recentered");
});

// On touch devices a tilt cart offers real device-tilt via a tappable toast
// (the permission request needs a user gesture on iOS). Elsewhere (or if
// dismissed) the D-pad/stick fallbacks just work with no setup. The toast is
// now only a nudge — the top-bar button above is the durable route in.
const maybeOfferOrientationTilt = () => {
  if (tiltOrientationOn || !tiltCanOrient()) return false;
  showActionToast("Play by tilting your device?", "Enable tilt", enableOrientationTilt);
  return true;
};

// --- Game Boy Printer ---
// Solo GB cores run with a print-intent sniffer attached to the serial
// port; the first time a game sends the printer-packet magic, offer to
// connect. Finished strips arrive via the wasm outbox and save as PNGs —
// hardware-matched timing means the in-game "printing" screens play out.
// A printer is always plugged into a solo GB core (see gb/printer.nim):
// games that never print send no packets, and games that do print just work
// on the first attempt. Finished prints are stored in the photo gallery and
// announced with a toast; nothing to connect, nothing to time.
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
// A dot at each step of the path to a photo you have not seen: the hamburger,
// the Capture row, the Printed Photos row. Each clears when its OWN element is
// used, so the trail shortens as you walk it.
//
// The one conditional bit is what "View" on the print toast does, and it turns
// on whether the gallery has ever been opened from the menu:
//
//   * Never opened from the menu. View shows the photo and changes NOTHING —
//     all three dots stay lit. The trail is the only way this person is going
//     to find out that the gallery exists at a fixed address in the menu, and
//     a toast they will never see again cannot teach them that.
//   * Opened from the menu before. View clears all three. They already know
//     where the gallery lives, so the dots have no lesson left to give and
//     would just be an unread badge over a photo they have already seen.
//
// So `everOpenedFromMenu` is set by the menu row and by nothing else — not by
// the toast, which is exactly the route that does not teach the address.
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
  // A dot with nothing behind it is a dead end: if the photos are gone (an
  // old record, a cleared gallery) the trail goes with them.
  if (!printerPhotos.length) photoDots.menu = photoDots.capture = photoDots.gallery = false;
  applyPhotoDots();
};

// on=true lights the whole trail (a photo arrived); on=false retires it.
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

// The Printed Photos row exists only once there is something behind it.
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

// Everything a finished print does once it is pixels: store it, put the menu
// row up, light the trail, offer the shortcut. Split out of collectPrint so
// the parts that need no wasm can be driven directly (web/tests).
const storePrint = async (photo) => {
  printerPhotos.unshift(photo);
  if (printerPhotos.length > PRINTER_MAX_PHOTOS) printerPhotos.length = PRINTER_MAX_PHOTOS;
  try { await dbPut(PRINTER_PHOTOS_KEY, printerPhotos); } catch {}
  refreshPrintsMenuItem(); // the first print is what puts the row in the menu
  if (printsModal.classList.contains("open")) {
    // The gallery is open and the photo lands in it. Nothing unseen, so
    // nothing to point at and nothing to offer.
    renderPrintsGrid();
    return;
  }
  setPhotoDots(true);
  showActionToast("Photo printed", "View", () => {
    // See "New-photo indicator" above: the toast only retires the trail for
    // someone who already knows where the trail leads.
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
      // Deleting the last photo takes the menu row with it, and any dot still
      // pointing at that row would then point at nothing.
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

// The menu row is the ONE route that sets everOpenedFromMenu — it is the only
// one that teaches where the gallery lives, which is the whole thing the
// indicator exists to teach.
printsItem.addEventListener("click", () => {
  photoDots.everOpenedFromMenu = true;
  photoDots.gallery = false;
  applyPhotoDots();
  savePhotoDots();
  openPrintsModal();
});

// Each of the other two dots clears when its own element is used, and only
// then — opening the menu says nothing about whether you found Capture, and
// expanding Capture says nothing about whether you opened the gallery.
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
// The Pocket Camera cart's sensor is fully emulated; opting in points it at
// real getUserMedia frames: a hidden <video> is drawn cover-cropped and
// selfie-mirrored into a 128x120 canvas ~15x/s, converted to luminance, and
// copied into the wasm-side buffer the sensor proc reads. The emulated
// exposure/dither pipeline then Game-Boy-ifies it authentically. Requires a
// secure context (HTTPS), same as tilt.
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

// "Do we have usable frames right now?" A non-null camStream is not the same
// thing: iOS ends the tracks whenever the page is backgrounded or another app
// takes the camera, and an ended track's <video> goes black rather than
// throwing — so the pump keeps copying black into the sensor. Every decision
// below keys off live tracks, never off camStream being set.
const camLive = () =>
  !!camStream && camStream.getVideoTracks().some((t) => t.readyState === "live");

const camCartLoaded = () =>
  typeof Module !== "undefined" && !!Module._wasm_cart_has_camera &&
  Module._wasm_cart_has_camera() === 1;

const camUsable = () => !!navigator.mediaDevices?.getUserMedia;

// What the top-bar button says when there is no stream yet — and, because two
// of the viewfinder notices below tell the player to look for that button BY
// NAME, the one place either wording is written. Rename it here and the
// emulated viewfinder renames it too; there is no second copy to forget.
const CAM_ENABLE_LABEL = "Enable camera";

// The top-bar button has two jobs. Before a stream is attached it is the way
// IN — a permanent affordance, because the one-shot offer toast is easy to
// miss and impossible to summon back. Once frames are flowing it becomes the
// front/back switch, shown only when there is more than one camera to switch
// between.
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
  // Nothing to enable without getUserMedia (insecure origin, ancient browser),
  // and nothing to switch to with a single camera.
  camFlipBtn.hidden = needsEnable ? !camUsable() : camDevices.length < 2;
};

// --- What the emulated viewfinder says when there is no camera ---
// With no sensor attached the cart falls back to camera.nim's synthetic scene
// (ramp + checkerboard + disc), which players read as a badly corrupted
// picture — one reported it as exactly that. The sensor is only a 128x120
// 8-bit grey buffer, so a rendered TEXT frame goes in through the same door
// real webcam frames do, and the viewfinder can say what is actually wrong.
//
// This survives the cart far better than it sounds like it should. The
// MAC-GBD's 2-D edge enhancement multiplies a black/white boundary by up to
// 5x before the 4x4 dither matrix quantises it, so large high-contrast type
// comes out with hard, clean edges — verified in-game against gbcamera.gb,
// including a five-line sentence. Small type would still turn to mush, which
// is why each line is auto-fitted to the full 128px width rather than set at
// a fixed size.
//
// Each notice is ONE string: "/" is the line break, and two placeholders keep
// it honest — {tap} is the verb for the pointing device, {label} is the
// top-bar button's own label (CAM_ENABLE_LABEL, so the viewfinder cannot go on
// naming a button that has been renamed). Editing a message is a one-line
// change; `node tools/cammsg.mjs` renders and fit-checks any candidate before
// it lands. Keep lines to ~14 characters: past that the fitter shrinks them
// below the 17.6px floor measured off these five (the smallest type known to
// survive the cart's dither), and they turn to mush.
const CAM_NOTICES = {
  // Never asked. The button this points at is the thing the player missed.
  prompt: "{tap} / {label} / in the top bar",
  // getUserMedia rejected with NotAllowedError, or the Permissions API said
  // "denied" before we ever asked.
  blocked: "Camera is / currently / restricted / by the / browser.",
  // Asked and granted, but the hardware isn't there (NotFoundError).
  missing: "No camera / found on / this device",
  // Had live frames, then the track ended by itself: iOS backgrounding the
  // tab, another app taking the camera, a USB webcam unplugged.
  ended: "Camera / stopped. / {tap} / {label}",
  // No getUserMedia at all — a plain-http origin is the common case.
  insecure: "Camera needs / a secure / connection",
};

// A notice's text, split into the lines the viewfinder will draw. `touch`
// exists so tools/cammsg.mjs can preview the Tap and Click wordings without a
// touchscreen; the app never passes it.
const camNoticeLines = (kind, touch = touchDevice) =>
  (CAM_NOTICES[kind] || "").split("/")
    .map((s) => s.trim()
      .replace(/\{tap\}/g, touch ? "Tap" : "Click")
      .replace(/\{label\}/g, CAM_ENABLE_LABEL))
    .filter((s) => s !== "");

// Which notice belongs in the viewfinder right now, or null when real frames
// are flowing. Ordered most-certain first; every branch is a fact we observed
// rather than an inference.
const camNoticeFor = () => {
  if (camLive()) return null;
  if (!camUsable()) return "insecure";
  if (camDenied) return "blocked";
  if (camMissing) return "missing";
  if (camEnded) return "ended";
  return "prompt";
};

// Lay the lines out across the 112 sensor rows the MAC-GBD actually keeps
// (it discards CAM_SENSOR_EXTRA/2 = 4 rows at each end, so rows 0-3 and
// 116-119 are never seen), each line scaled down only if it would overflow
// 128px. White on black: the cart's edge filter keys off boundaries, and the
// heaviest weight available gives it the most to bite on.
const CAM_VIEW_TOP = 4, CAM_VIEW_H = 112;

// The whole of the layout arithmetic, separated from the painting so that
// tools/cammsg.mjs can report the size a line will actually render at without
// keeping a second, driftable copy of these numbers. Uses ctx only to measure.
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

// RGBA canvas pixels -> the 8-bit grey the MAC-GBD sensor hands the cart.
// Shared by the notice writer and the live webcam pump so a preview rendered
// by tools/cammsg.mjs is the same bytes the cart will see.
const camToGrey = (img, dst) => {
  for (let i = 0, p = 0; i < dst.length; i++, p += 4) {
    dst[i] = (img[p] * 299 + img[p + 1] * 587 + img[p + 2] * 114) / 1000;
  }
};

// Push one still frame into the sensor. Nothing repaints it: the cart re-reads
// the buffer on every capture, so one write holds until the camera starts or
// the notice changes.
const camShowNotice = (kind) => {
  if (camNoticeShown === kind) return;
  if (!CAM_NOTICES[kind] || typeof Module === "undefined" ||
      !Module._wasm_camera_attach) return;
  // Attaching also takes the cart off its synthetic scene, which is the point.
  if (!Module._wasm_camera_attach()) return;
  const ptr = Module._wasm_camera_frame_ptr();
  if (!ptr) return;
  const cnv = document.createElement("canvas");
  cnv.width = CAM_W;
  cnv.height = CAM_H;
  const ctx = cnv.getContext("2d", { willReadFrequently: true });
  camDrawNotice(ctx, camNoticeLines(kind));
  const img = ctx.getImageData(0, 0, CAM_W, CAM_H).data;
  // Fresh heap view every copy: memory growth detaches cached buffers
  camToGrey(img, new Uint8Array(Module.memory.buffer, ptr, CAM_W * CAM_H));
  camNoticeShown = kind;
};

// One place that re-reads the world: the button's two states and the
// viewfinder's notice always agree because they are decided together.
const camRefresh = () => {
  camCartBtnUpdate();
  if (!camCartLoaded()) return;
  const kind = camNoticeFor();
  if (kind) camShowNotice(kind);
  else camNoticeShown = null;   // live frames are overwriting it anyway
};

// The Permissions API can tell us the camera is blocked WITHOUT prompting, so
// a player who denied the site months ago gets the honest message instead of
// "tap Enable camera" followed by an invisible failure. Chromium-only in
// practice: WebKit rejects the "camera" query outright, which is why a failed
// probe leaves camDenied alone rather than clearing it — only a real
// getUserMedia rejection can decide it there.
const camProbePermission = async () => {
  if (camPermProbed) return;   // one status object per session, one listener
  camPermProbed = true;
  try {
    const st = await navigator.permissions.query(
      /** @type {*} */ ({ name: "camera" }));
    if (st.state === "denied") camDenied = true;
    else if (st.state === "granted") camDenied = false;
    // Flipping the site permission in browser settings does not reload the
    // page; re-decide when it happens so the viewfinder stops lying.
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

// (Re)open the camera with the current facing/device choice; reused by the
// flip button, so it swaps the stream under the running pump.
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
  // A track that ends on its own (iOS backgrounding the tab, the OS handing
  // the camera to another app, a USB webcam unplugged) has to tear the pump
  // down, or it spends the rest of the session copying black frames into the
  // sensor. The guard keeps a *deliberate* swap — switchCamera stops the old
  // tracks after the new stream is live — from tripping it.
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
  // Selfie-mirror the front camera (and desktop webcams — they face the
  // user); the back camera shows the world and must not be flipped.
  camMirror = touchDevice ? camFacing === "user" : true;
};

// Flip: phones toggle front/back; desktops cycle the device list and name
// each camera as it's chosen. Only offered when >1 camera exists.
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
// One button, two meanings — see camCartBtnUpdate. Both branches run straight
// off the click, with nothing awaited first, so the getUserMedia call still
// carries the user gesture iOS requires.
camFlipBtn.addEventListener("click", () =>
  camLive() ? switchCamera() : enableWebcam());

const enableWebcam = async () => {
  if (camPending || camLive() || !camUsable()) return;
  // Retrying after the stream died: drop the corpse first, or the second
  // enable stacks another pump interval on top of the first one.
  if (camStream) stopWebcam();
  camPending = true;
  try {
    await openCamStream();
    camDenied = camMissing = camEnded = false;
  } catch (e) {
    // Say which failure it was. NotAllowedError is the browser refusing
    // (denied, or blocked by permissions policy); NotFoundError means the
    // constraint matched no device. Anything else is a camera that exists but
    // would not open — another app holding it, a driver fault — and gets the
    // same "no camera to show you" treatment rather than a wrong accusation.
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
  // Post-grant, enumerateDevices yields the real camera list (labels
  // included); two or more video inputs earn the flip button.
  try {
    const devs = await navigator.mediaDevices.enumerateDevices();
    camDevices = devs.filter((d) => d.kind === "videoinput").map((d) => d.deviceId);
    // The default open is (approximately) the first device: seed the cycle
    // there so the first flip actually reaches a DIFFERENT camera.
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
    // cover-crop the source into 128x120; mirror only when facing the user
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
    // Fresh heap view every copy: memory growth detaches cached buffers
    camToGrey(img, new Uint8Array(Module.memory.buffer, ptr, CAM_W * CAM_H));
  }, 66);
  camNoticeShown = null;
  showToast("Camera live — the cart sees what you see");
};

const detectCameraCart = () => {
  camNoticeShown = null;   // a fresh cart's sensor carries nothing yet
  // Both of these describe a moment, not a standing decision — a webcam can
  // be plugged in between games — so a fresh load is a fresh chance. Only
  // camDenied survives: that one is the browser's answer, and it holds.
  camMissing = camEnded = false;
  if (!camCartLoaded()) {
    stopWebcam(); // a non-camera game must not hold the camera open
    camCartBtnUpdate();
    return;
  }
  if (camLive()) {
    // Same session, fresh core (Restart, or loading this cart again): the
    // new cartridge object has no sensor callback, so the emulated camera
    // falls back to its synthetic scene — which reads as a corrupted
    // viewfinder. Keep the stream and re-point the new cart at the live
    // frame buffer instead of asking for permission all over again.
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

// --- Early (pre-wasm) boot -------------------------------------------------
// The home grid reads only IndexedDB metadata, so it must not wait for the
// wasm (~65% of the payload) to download+compile. initStorage runs at
// DOMContentLoaded — after every script tag has executed, typically while
// em.wasm is still in flight — and onRuntimeInitialized awaits storageReady
// before its wasm-dependent work. The vm test harness (web/tests/helpers.mjs)
// keeps document.readyState at "loading" and never fires DOMContentLoaded, so
// tests still drive openDB/migrations/refreshHomeRecent explicitly.

// Resolved once the wasm runtime is initialized. Launch paths touch FS and
// Module (writeToFS, ccall), so a ROM tile tapped before the runtime exists
// must wait here instead of crashing. The test harness calls
// markRuntimeReady() itself — no runtime ever initializes inside the vm.
let runtimeReady = false;
let markRuntimeReady = () => {};
const runtimeReadyPromise = new Promise((resolve) => {
  markRuntimeReady = () => { runtimeReady = true; resolve(); };
});

// Queue an FS/Module-touching user action behind runtime init. When the wait
// is real — a tile tapped during a cold load on a slow connection — say so
// once, subtly; the queued action proceeds the moment the runtime lands.
const ensureRuntimeReady = () => {
  if (runtimeReady) return Promise.resolve();
  showToast("Starting the emulator…");
  return runtimeReadyPromise;
};

const initStorage = async () => {
  await openDB();
  // Migrations strictly before anything renders from the records they rewrite.
  await migrateFromLocalStorage();
  await migrateRecentFormat();
  // loadBiosFromStorage is deliberately NOT here: it writes into the
  // Emscripten FS, which doesn't exist yet. onRuntimeInitialized runs it.
  // Every load below only reads IndexedDB and sets JS vars / DOM state; their
  // apply* helpers guard each Module export and no-op without the runtime
  // (onRuntimeInitialized re-pushes the wasm-side mirrors).
  await loadKeybindingsFromStorage();
  await loadLargeControlsFromStorage();
  await loadOpaqueControlsFromStorage();
  await loadHideTouchOnGamepadFromStorage();
  await loadControlStyleFromStorage();
  await loadRunaheadFromStorage();
  await loadAudioSettings();
  await loadColorCorrect();
  await loadSystemSettings();
  await loadVideoSettings();
  await loadGbPalette();
  // Was never called at all, which meant printerPhotos started every session
  // empty: the gallery showed "Nothing printed yet" over a full store, and the
  // next print dbPut a one-element array back over every earlier photo. It is
  // load-bearing now for a second reason — the Capture ▸ Printed Photos row
  // and the new-photo dots are both driven off the photo count. It has to run
  // before anything can print, for the same reason it exists at all.
  await loadPrinterPhotos();
  await loadSyncState();
  await loadRomsSort();
  refreshSyncUI();
  startSyncTriggers();
  // Resume Drive: reuse a still-valid persisted token with no popup (so an
  // app update / reload keeps the session), else re-grant on the first user
  // gesture (the token popup is gesture-gated). See resumeDriveOnBoot.
  resumeDriveOnBoot();
  refreshHomeRecent();
  // Deliberately not awaited and last: nothing renders from it, so it must not
  // sit on the boot path (it costs one extra key listing).
  sweepOrphanedAutoStates().catch(() => {});
};

let storageReadyResolve;
let storageReadyReject;
const storageReady = new Promise((resolve, reject) => {
  storageReadyResolve = resolve;
  storageReadyReject = reject;
});
// onRuntimeInitialized awaits storageReady, so a failed openDB aborts the
// boot there exactly as it did when these calls lived inline. But if the wasm
// never arrives, nobody awaits it — don't let the rejection also surface as
// an unhandled one on top of the real failure.
storageReady.catch(() => {});
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => {
    initStorage().then(storageReadyResolve, storageReadyReject);
  }, { once: true });
} else {
  // Scripts at the end of <body> always execute before DOMContentLoaded, but
  // if this file is ever loaded differently (defer/dynamic), boot anyway.
  initStorage().then(storageReadyResolve, storageReadyReject);
}

/** @type {EmscriptenModule} */
var Module = {
  // SDL renders (invisibly) to a dedicated hidden canvas so its WebGL context
  // doesn't collide with the WebGL2 context we own on the visible #canvas. A
  // canvas can hold only one context type; game input (_setInput) and audio
  // (Web Audio) are JS-driven, so SDL's canvas is never seen or interacted with.
  canvas: /** @type {HTMLCanvasElement} */ ((() => document.getElementById("sdl-canvas"))()),
  onRuntimeInitialized: async () => {
    // iOS Safari kills (or JIT-demotes) tabs under process memory pressure;
    // shrink the rewind ring's cap from 64 MB before any core exists — the
    // ring is created at ROM load (initFromEmscripten), so setting it here
    // covers every session.
    if (IS_IOS && Module._setRewindCapBytes) {
      Module._setRewindCapBytes(16 * 1024 * 1024);
    }
    // Storage boot (openDB, migrations, settings, home grid) started at
    // DOMContentLoaded so the library rendered without waiting on this
    // runtime (see initStorage). Everything below reads what it loads, and a
    // storage failure must keep aborting the boot exactly as it did when the
    // calls lived inline here.
    await storageReady;
    // The FS exists only now — the BIOS/bootrom files can't be written early.
    await loadBiosFromStorage();
    // Re-push the wasm-side mirrors of settings loaded while there was no
    // runtime to receive them (each apply* no-ops without its Module export;
    // the early loads only set the JS vars + UI).
    applySystemSettings();
    applyColorCorrect();
    applyPitchCorrectFF();
    applyMp2kHle();
    applyLcdResponse();
    // Unblock queued launches (a ROM tile tapped mid-boot) and retire the
    // home screen's wasm-boot progress strip.
    markRuntimeReady();
    document.body.classList.add("runtime-ready");
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
    let lowpassNode = null;
    let playTime = 0;

    // Optional analog-output low-pass (~12 kHz), modeling the GBA speaker's
    // cap/analog smoothing. Off by default → gain routes straight to the
    // destination (no filter node in the path). Mirrors the native IIR.
    // Clip recording tap: while a capture runs, the master gain ALSO feeds a
    // MediaStreamDestination whose audio tracks the MediaRecorder consumes.
    // Held here because gainNode lives in this closure; routeOutput
    // re-attaches it across lowpass toggles.
    let clipTapNode = null;
    let clipTapActive = false;

    const routeOutput = () => {
      if (!audioCtx || !gainNode) return;
      try { gainNode.disconnect(); } catch (e) {}
      if (typeof audioLowpass !== "undefined" && audioLowpass) {
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
    // Recorder-side hooks (recording code lives at module scope, outside
    // this closure). Return the tap's MediaStream, or null pre-audio-unlock.
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
      try {
        audioCtx = new AudioContext({ sampleRate: SAMPLE_RATE });
      } catch (e) {
        // Old WebKit can reject the sampleRate option outright. Fall back to
        // the hardware rate: createBuffer() tags each buffer 32768 Hz and Web
        // Audio resamples on playback, so scheduling stays correct.
        audioCtx = new AudioContext();
      }
      gainNode = audioCtx.createGain();
      gainNode.gain.value = effectiveGain();
      lowpassNode = null;
      routeOutput();   // gain -> (lowpass ->) destination per the toggle
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
    // Pre-audioSession iOS (≤16): Web Audio output obeys the ringer (silent)
    // switch unless an <audio> element is actively playing, which promotes
    // the whole session to "playback". A one-shot blip isn't enough — the
    // promotion only lasts while the element plays — so those devices keep a
    // silent element looping for the life of the page. Modern iOS is handled
    // by navigator.audioSession in initAudio; nobody else needs any of this.
    let silentLoopEl = null;
    const needsSilentLoop = () =>
      !navigator.audioSession &&
      (/iPhone|iPad|iPod/.test(navigator.userAgent) ||
        (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1));
    const silentWavURL = () => {
      // 0.25 s of 8 kHz mono 8-bit silence (0x80), built inline — looping a
      // microscopic file (like the 1-sample one-shot below) would be churn.
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
      // Not just "suspended": iOS Safari parks the context in a non-standard
      // "interrupted" state after phone calls / Siri, which also needs an
      // explicit resume(). Attempt it for any non-running state.
      if (audioCtx.state !== "running") audioCtx.resume().catch(() => {});
      // Outside the unlock branch on purpose: retried until it sticks. On old
      // iOS the touchstart listener runs this first and its play() is refused
      // (see the touchend note below); pagehide also pauses the loop, and
      // pageshow funnels back through here.
      if (silentLoopEl && silentLoopEl.paused) silentLoopEl.play().catch(() => {});
      if (!audioUnlocked) {
        audioUnlocked = true;
        // Play a silent buffer through the AudioContext to fully unlock it
        let silentBuf = audioCtx.createBuffer(1, 1, SAMPLE_RATE);
        let src = audioCtx.createBufferSource();
        src.buffer = silentBuf;
        src.connect(audioCtx.destination);
        src.start(0);
        // Also play through an <audio> element to activate the audio session
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
    // Old iOS WebKit only counts touchEND (and the click it synthesizes) as a
    // user gesture for media playback, and the touch controls preventDefault
    // so taps on them never synthesize a click. Without this, a player who
    // only ever touches the d-pad/buttons would never unlock audio there.
    document.addEventListener("touchend", resumeAudio, { once: false });

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
        : fastForward ? "ffw" : speed2x ? "2x" : slowMotion ? "slow" : "normal";
      const expected = mode === "paused" || mode === "rewind" ? 0
        : mode === "2x" ? 119.5 : mode === "slow" ? 29.9
        : mode === "normal" ? 59.7 : null;
      const usual = expected !== null &&
        Math.abs(frameCount - expected) <= Math.max(3, expected * 0.05);
      // A mode switch mid-window yields a blended count; don't flash it
      if (usual || mode !== lastFpsMode) {
        fpsDiv.textContent = "";
      } else {
        // The unit rides in its own span so phones can drop it: at 375pt the
        // top bar has no room for " fps" once the sync + audio indicators are
        // both up, and the number alone is unambiguous there.
        fpsDiv.innerHTML = frameCount + '<span class="fps-unit"> fps</span>';
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
        persistAutoState();
      }
    });

    // Mobile browsers routinely kill backgrounded tabs without pagehide ever
    // firing again — capture the resume snapshot the moment we're hidden.
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) persistAutoState();
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
        persistAutoState(); // one-tap resume next launch
      }
      if (audioCtx && audioCtx.state === "running") {
        audioCtx.suspend().catch(() => {});
      }
      // The legacy-iOS silent loop holds the audio session too; resumeAudio
      // (via pageshow) restarts it.
      if (silentLoopEl) silentLoopEl.pause();
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

    // "Enhanced audio" note: lit when a sound-engine HLE (MP2K / Golden Sun
    // "Bon" driver) is enabled in settings AND detected+substituting right now.
    // Two-stage toggle so the CSS opacity/scale transition plays: unhide first,
    // then add .on on the next frame.
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
        // reflow so the class add animates from the hidden state
        void hleIndicator.offsetWidth;
        hleIndicator.classList.add("on");
      } else {
        hleIndicator.classList.remove("on");
        hleIndicator.hidden = true;
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
      } else if (clipReplayActive) {
        // Retroactive capture: step the deterministic replay at realtime
        // (the MediaRecorder captures the canvas + audio as it plays back).
        // clip_tick presents each frame and returns -1 when the log is
        // exhausted — the wasm side has already restored the live state.
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
        const step = speed2x ? FRAME_TIME / 2 : slowMotion ? FRAME_TIME * 2 : FRAME_TIME;
        const maxFrames = speed2x ? 4 : 2;
        // Run-ahead engages only at normal speed: at 2x/slow-mo the (N+1)x
        // per-frame cost buys nothing (latency is dominated by the speed
        // change itself), and with it off this line picks the identical
        // loop_tick call that predates the feature — zero cost while off.
        const useRunahead = runaheadFrames > 0 && !speed2x && !slowMotion &&
          typeof Module._runahead_tick === "function";
        let framesRun = 0;
        while (accumulator >= step && framesRun < maxFrames) {
          if (useRunahead) Module._runahead_tick(runaheadFrames);
          else Module._loop_tick();
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
  // Only treat the hit element as a d-pad cell if it's actually inside #dpad.
  // Face buttons (A/B/L/R/Select/Start) also carry data-inputs, so sliding onto
  // them must NOT press them. A null element (finger off-viewport) is "off pad".
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
    // Slide-off tolerance: keep the current direction held while the finger is
    // only just past the pad's edge — a common cause of dropped inputs mid-hold.
    // Release only when it moves clearly away, or slides onto another control.
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

