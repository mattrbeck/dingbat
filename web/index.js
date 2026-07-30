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

// Show the bottom scrim only while more items sit below the fold, so it never
// permanently fades the last item (Toggle Log) in windows tall enough that the
// menu doesn't scroll. Re-checked on open/scroll/resize; scrollHeight reads 0
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
  if (!menuDropdown.hidden) updateMenuScrollHint();
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

// Tab bar: one pane visible at a time
const settingsTabs = Array.from(/** @type {NodeListOf<HTMLElement>} */ (document.querySelectorAll(".settings-tab")));
const settingsTabBar = document.getElementById("settings-tabs");
const settingsTabsWrap = document.getElementById("settings-tabs-wrap");

// Edge scrims on the wrapper signal that the bar can scroll further in that
// direction (the tab bar overflows on narrow phones). Re-checked on scroll,
// resize, tab selection and modal open — clientWidth is 0 while the modal is
// closed, so the open-time call does the first real measurement.
const updateTabsScrollHints = () => {
  const el = settingsTabBar;
  settingsTabsWrap.classList.toggle("can-scroll-left", el.scrollLeft > 1);
  settingsTabsWrap.classList.toggle(
    "can-scroll-right", el.scrollLeft + el.clientWidth < el.scrollWidth - 1);
};

settingsTabBar.addEventListener("scroll", updateTabsScrollHints, { passive: true });
window.addEventListener("resize", updateTabsScrollHints);

const selectSettingsTab = (name) => {
  for (let t of settingsTabs) {
    let on = t.dataset.tab === name;
    t.classList.toggle("active", on);
    t.setAttribute("aria-selected", on ? "true" : "false");
    document.getElementById("settings-pane-" + t.dataset.tab).hidden = !on;
    // The tab bar scrolls on narrow screens — keep the active tab in view
    if (on) t.scrollIntoView({ block: "nearest", inline: "nearest" });
  }
  updateTabsScrollHints();
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
  updateTabsScrollHints();  // first measurable layout: modal was display:none
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

const refreshRomsManageList = async () => {
  if (!db) return;
  romsRowsSignedIn = syncActive();
  // Keep the intro copy and the rows telling the same story: signed out there
  // is no Remove button, so the sentence describing it goes too.
  romsHintRemove.hidden = !syncActive();
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

    let label = document.createElement("span");
    label.className = "roms-manage-name";
    label.textContent = displayName(name);
    label.title = name; // full filename (with extension) for disambiguation
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
    let savesOnDrive = syncActive() && Object.keys(syncState.rmt || {}).some(
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
    let romOnDrive = syncActive() && !!syncState.sigs[romKey(name)] &&
      !syncState.queueDel.includes(romKey(name));
    let freeBtn = null;
    if (localRoms.has(name) && syncActive() && !romOnDrive) {
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
    if (driveOnly && syncActive()) {
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
          showToast(syncActive() ? "Deleted from all your devices"
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
      await gdriveAcquireToken("");
    } catch {
      clearDriveToken();
      armDriveRenewOnGesture();
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
  gdriveEmail = null;
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
  if (romsModal.classList.contains("open") && romsRowsSignedIn !== syncActive()) {
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

  if (!gdriveToken) {
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
  status.textContent =
    (gdriveEmail || "Connected to Google Drive") +
    " · " + (n ? n + " change" + (n === 1 ? "" : "s") + " pending"
               : "all changes synced");
  gdriveBody.appendChild(status);

  let actions = document.createElement("div");
  actions.className = "gdrive-actions";
  actions.appendChild(
    makeGdriveButton("Sync now", false, () => runFullSync({ label: "Syncing" })));
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
let syncState = { queueUp: [], queueDel: [], tomb: [], sigs: {}, rmt: {} };
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
    };
  }
};
const saveSyncState = () => dbPut("gdrive_sync", syncState);

// Signed in == syncing. Every hook below no-ops when this is false.
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
const SYNC_WORDS = { syncing: "Syncing", done: "Synced", offline: "Offline" };
const SYNC_DESCS = {
  syncing: "Syncing your games with Google Drive…",
  done: "All changes are synced to Google Drive",
  offline: "Offline — your changes will sync when you reconnect",
};
let syncStatus = "idle"; // idle | syncing | done | offline
const syncIndicator = document.getElementById("sync-indicator");

const renderSyncIndicator = () => {
  if (!syncIndicator) return;
  let s = syncStatus;
  let show = s !== "idle" && syncActive();
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
  if (!syncActive()) { setSyncStatus("idle"); return; }
  if (syncBusy || pendingCount()) setSyncStatus("syncing");
  else if (syncStatus === "syncing") setSyncStatus("done");
  else renderSyncIndicator();
};

// --- Dirty queue ---------------------------------------------------------
const scheduleFlush = () => {
  if (!syncActive()) return;
  if (syncTimer) clearTimeout(syncTimer);
  syncTimer = setTimeout(flushSync, SYNC_DEBOUNCE_MS);
  // First change in a burst arms the ceiling so a busy stretch still lands.
  if (!syncCapTimer) syncCapTimer = setTimeout(flushSync, SYNC_MAX_WAIT_MS);
  refreshSyncStatus();
};
const markUpload = (name) => {
  if (!syncActive()) return;
  if (!parseDriveFileName(name)) return;
  if (!syncState.queueUp.includes(name)) syncState.queueUp.push(name);
  saveSyncState();
  scheduleFlush();
};
const markDelete = (name) => {
  if (!syncActive()) return;
  if (!parseDriveFileName(name)) return;
  if (!syncState.queueDel.includes(name)) syncState.queueDel.push(name);
  syncState.queueUp = syncState.queueUp.filter((n) => n !== name);
  saveSyncState();
  scheduleFlush();
};
const markGameUpload = (game) => {
  if (!syncActive()) return;
  localFilesForGame(game).then((names) => {
    for (let n of names) if (!syncState.queueUp.includes(n)) syncState.queueUp.push(n);
    saveSyncState();
    scheduleFlush();
  });
};
// Mirror a local save-data wipe to Drive.
const queueSaveDataDeletes = (name) => {
  markDelete("save:" + name);
  markDelete("save:" + name + "-p2");
  for (let s = 0; s < NUM_STATE_SLOTS; s++) {
    markDelete(slotStateKey(name, s));
    markDelete(slotMetaKey(name, s));
  }
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
          await deleteSaveData(g);
          await evictLocalRom(g);
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
  if (!syncActive()) { showToast("Sign in to Google Drive first"); return false; }
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
// Frees this device's copy of a game's ROM and nothing else: no tombstone, no
// Drive delete, and the recents entry stays put, so the game keeps its place
// in the merged library and simply re-renders as a Drive-only tile that one
// tap brings back. That is the whole difference from deleteGameEverywhere,
// which raises a tombstone precisely so every OTHER device drops the game too.
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
  if (!syncActive()) { showToast("Sign in to Google Drive first"); return false; }
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
  await evictLocalRom(game);
  markGameUpload(game); // the ROM is gone, so this queues the saves we kept
  return true;
};

// --- Deletion (Manage ROMs) ----------------------------------------------
// Reset = wipe save data, keep the ROM. Delete = remove the game entirely and
// tombstone it so every device drops it. Both are local-only when signed out.
const resetGameSaves = async (game) => {
  await deleteSaveData(game);
  if (syncActive()) queueSaveDataDeletes(game);
};
const deleteGameEverywhere = async (game) => {
  await deleteSaveData(game);
  await evictLocalRom(game);
  await dbPut("recent", (await getRecentMeta()).filter((r) => r.name !== game));
  if (syncActive()) {
    for (let n of ["save:" + game, "save:" + game + "-p2", "rom:" + game]) markDelete(n);
    for (let s = 0; s < NUM_STATE_SLOTS; s++) {
      markDelete(slotStateKey(game, s));
      markDelete(slotMetaKey(game, s));
    }
    syncState.tomb = syncState.tomb.filter((t) => t.name !== game);
    syncState.tomb.push({ name: game, ts: Date.now() });
    await saveSyncState();
    scheduleFlush();
  }
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

// Ensure we hold a Drive session before a download. Already signed in → true.
// Signed out → open sign-in (callers invoke this from a click, so the popup is
// gesture-allowed); returns whether we ended up connected.
const ensureDriveSignedIn = async () => {
  if (syncActive()) return true;
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
      if (live) gdriveEmail = (await r.json()).email || null;
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
  if (syncActive() && pendingCount()) setSyncStatus("offline");
});
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && syncActive()) {
    flushSync().then(() => pullSync());
  }
});

// --- Sync UI surfaces -----------------------------------------------------
const homeSyncBtn = /** @type {HTMLButtonElement} */ (document.getElementById("home-sync"));

// The grid's own sync affordance doubles as its progress readout: while a sync
// is running the "Sync" link becomes a spinner + "Syncing…" and stops being
// clickable, so activity is visible right where the games are.
const refreshHomeSyncButton = () => {
  if (!homeSyncBtn) return;
  homeSyncBtn.hidden = !syncActive();
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
  homeSyncBtn.addEventListener("click", () => runFullSync({ label: "Syncing" }));
}

// --- Core-construction settings (GB renderer, GBA BIOS behavior) ---
// JS mirrors of the wasm-side option vars; they take effect the next time a
// core is constructed (ROM load / reset), matching the desktop config.

var gbFifo = true;
var gbaBiosMode = 0; // 0 = HLE, 1 = real BIOS, 2 = real BIOS boot + HLE calls
var gbaRunBios = true;
// Presentation-side only (the RAF loop polls _wasm_rumble and reacts here),
// so unlike its siblings it has no wasm setter in applySystemSettings.
var gbRumble = true;

const gbaRunBiosToggle = /** @type {HTMLInputElement} */ (document.getElementById("gba-run-bios-toggle"));
const gbRumbleToggle = /** @type {HTMLInputElement} */ (document.getElementById("gb-rumble-toggle"));

const applySystemSettings = () => {
  if (typeof Module === "undefined") return;
  if (Module._wasm_set_gb_renderer) Module._wasm_set_gb_renderer(gbFifo ? 1 : 0);
  if (Module._wasm_set_gba_bios_mode) Module._wasm_set_gba_bios_mode(gbaBiosMode);
  if (Module._wasm_set_gba_run_bios) Module._wasm_set_gba_run_bios(gbaRunBios ? 1 : 0);
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
};

const saveSystemSettings = () => {
  applySystemSettings();
  if (db) dbPut("system", { gbFifo, gbaBiosMode, gbaRunBios, gbRumble });
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
  if (!syncActive()) list = list.slice(0, MAX_RECENT);
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
  if (GDRIVE_CLIENT_ID && !gdriveToken) {
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
  } else if (GDRIVE_CLIENT_ID && syncActive()) {
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
      ? romName + (syncActive() ? " — on Drive, tap to download"
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

let toastTimer = null;
const showToast = (msg) => {
  let t = document.getElementById("toast");
  t.textContent = msg;
  t.onclick = null; // disarm a lingering action toast's tap handler
  t.classList.remove("has-action");
  t.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show"), 2200);
};

// Toast with a single action (e.g. "Resume", "Undo"). The ENTIRE toast is
// the tap target — on phones the labeled button alone is a small, missable
// pill, and users tap the text anyway. Lingers longer than a plain toast;
// any later toast replaces it.
const showActionToast = (msg, label, fn, ms = 8000) => {
  const t = document.getElementById("toast");
  t.textContent = "";
  const span = document.createElement("span");
  span.className = "toast-msg";
  span.textContent = msg;
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "toast-action";
  btn.textContent = label;
  t.append(span, btn);
  t.onclick = () => {
    t.onclick = null;
    t.classList.remove("show", "has-action");
    clearTimeout(toastTimer);
    fn();
  };
  t.classList.add("show", "has-action");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show", "has-action"), ms);
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

// wasm_load_state only reports accept/reject (the specific reason is echoed
// to the console), so sniff the header magic here to tell "this isn't a
// dingbat save state at all" apart from "real state image the core rejected"
// (different game, newer dingbat version, or corruption). Header layout is
// documented in src/dingbat/common/serialize.nim (STATE_MAGIC = "DGBSTATE").
const STATE_MAGIC = "DGBSTATE";
const looksLikeStateFile = (bytes) =>
  !!bytes && bytes.length >= STATE_MAGIC.length &&
  [...STATE_MAGIC].every((c, i) => bytes[i] === c.charCodeAt(0));

// Toast copy for a state image the core refused to load.
const stateRejectMessage = (bytes) =>
  looksLikeStateFile(bytes)
    ? "State didn't match this game"
    : "Not a dingbat save state file";

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
  reportSlider.max = String(reportSamples); // 0..N; right end (max) = now
  reportSlider.value = String(reportSamples);
  reportScrub.classList.toggle("disabled", !currentOriginalName);
  reportScrubHint.hidden = reportSamples > 0;
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

const canvasEl = /** @type {HTMLCanvasElement} */ (document.getElementById("canvas"));
const stageEl = document.getElementById("stage");
const glowCanvas = /** @type {HTMLCanvasElement} */ (document.getElementById("glow-canvas"));
const glowCtx = glowCanvas.getContext("2d");
const integerScaleToggle = /** @type {HTMLInputElement} */ (document.getElementById("integer-scale-toggle"));
const scanlinesToggle = /** @type {HTMLInputElement} */ (document.getElementById("scanlines-toggle"));
const motionBlurToggle = /** @type {HTMLInputElement} */ (document.getElementById("motion-blur-toggle"));
const ambientGlowToggle = /** @type {HTMLInputElement} */ (document.getElementById("ambient-glow-toggle"));
const upscaleFilterSelect = /** @type {HTMLSelectElement} */ (document.getElementById("upscale-filter-select"));

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
  for (const [rowId, input] of /** @type {[string, HTMLInputElement][]} */ ([
    ["integer-scale-row", integerScaleToggle],
    ["scanlines-row", scanlinesToggle],
  ])) {
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
  "runahead",
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

  // Run-ahead -> off
  applyRunahead(0);

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

const loadRom = async (romName, originalName, opts = {}) => {
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
  stateUndoBytes = null;  // undo buffer belongs to the previous game
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

pauseButton.addEventListener("click", () => {
  paused = !paused;
  pauseButton.classList.toggle("paused", paused);
  pauseButton.classList.toggle("active", paused);
  pauseButton.title = paused ? "Resume" : "Pause";
  document.body.classList.toggle("paused", paused);
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
  paused = true; // keep the orphaned core frozen
  pauseButton.classList.remove("paused", "active");
  pauseButton.title = "Pause";
  document.body.classList.remove("has-game", "running", "paused", "gb-mode");
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
  await loadSyncState();
  await loadRomsSort();
  refreshSyncUI();
  startSyncTriggers();
  // Resume Drive: reuse a still-valid persisted token with no popup (so an
  // app update / reload keeps the session), else re-grant on the first user
  // gesture (the token popup is gesture-gated). See resumeDriveOnBoot.
  resumeDriveOnBoot();
  refreshHomeRecent();
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
    applyMotionBlur();
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
    };
    window.updateAudioLowpass = () => routeOutput();
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
        : fastForward ? "ffw" : speed2x ? "2x" : "normal";
      const expected = mode === "paused" || mode === "rewind" ? 0
        : mode === "2x" ? 119.5 : mode === "normal" ? 59.7 : null;
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
        // Run-ahead engages only at normal speed: at 2x the (N+1)x per-frame
        // cost buys nothing (latency is dominated by the speed change
        // itself), and with it off this line picks the identical loop_tick
        // call that predates the feature — zero cost while off.
        const useRunahead = runaheadFrames > 0 && !speed2x &&
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

