// Run-ahead A/B harness: two embed players side by side, the right one
// stepping with runahead_tick(N). This page owns the keyboard and mirrors
// every press to BOTH iframes over postMessage (see the parent-page bridge in
// embed.js), so the cores receive identical input and the only difference on
// screen is the run-ahead. Keep focus here — clicking inside a pane lets the
// focused embed's SDL keyboard path double-apply input a frame apart.

const leftFrame = /** @type {HTMLIFrameElement} */ (document.getElementById("left"));
const rightFrame = /** @type {HTMLIFrameElement} */ (document.getElementById("right"));
const romInput = /** @type {HTMLInputElement} */ (document.getElementById("rom-file"));
const raSelect = /** @type {HTMLSelectElement} */ (document.getElementById("ra-frames"));
const statusEl = document.getElementById("status");

let romBytes = null; // ArrayBuffer of the picked ROM
let romName = null;
const ready = new Set(); // window objects that have posted db-ready

const post = (frame, msg) => {
  if (frame.contentWindow) frame.contentWindow.postMessage(msg, window.location.origin);
};
const postBoth = (msg) => {
  post(leftFrame, msg);
  post(rightFrame, msg);
};

const sendRom = (frame) => {
  if (!romBytes) return;
  // Each pane gets its own copy (transfer would detach the buffer)
  post(frame, { type: "db-rom", name: romName, bytes: romBytes.slice(0) });
};

window.addEventListener("message", (e) => {
  if (e.origin !== window.location.origin) return;
  const msg = e.data;
  if (!msg || typeof msg !== "object") return;
  if (msg.type === "db-ready") {
    ready.add(e.source);
    // A pane that (re)loaded after the ROM was picked catches up here
    if (e.source === leftFrame.contentWindow) sendRom(leftFrame);
    if (e.source === rightFrame.contentWindow) sendRom(rightFrame);
  } else if (msg.type === "db-key") {
    // A focused pane forwarded a keystroke (bridge mode intercepts it before
    // SDL): apply it through the same shared path as this page's keyboard,
    // so both cores stay on identical input wherever focus lives.
    applyKey(msg.code, msg.down);
  }
});

const useRom = (bytes, name) => {
  romBytes = bytes;
  romName = name;
  sendRom(leftFrame);
  sendRom(rightFrame);
  statusEl.textContent =
    `${romName} loaded in both panes — baseline vs runahead_tick(${raSelect.value}).`;
};

romInput.addEventListener("change", async () => {
  const file = romInput.files && romInput.files[0];
  if (!file) return;
  useRom(await file.arrayBuffer(), file.name);
  romInput.blur(); // keys must drive the game now, not the file input
});

// One-click demo: the repo's own goodboy demo ROM (served next to this page)
document.getElementById("demo-rom").addEventListener("click", async (e) => {
  const res = await fetch("goodboy-demo-en.gba");
  if (!res.ok) {
    statusEl.textContent = "Couldn't fetch goodboy-demo-en.gba";
    return;
  }
  useRom(await res.arrayBuffer(), "goodboy-demo-en.gba");
  /** @type {HTMLButtonElement} */ (e.currentTarget).blur();
});

// Changing N reloads the right pane with the new query param; db-ready
// re-sends the ROM once its runtime is back up.
raSelect.addEventListener("change", () => {
  document.getElementById("ra-label").textContent = `runahead_tick(${raSelect.value})`;
  ready.delete(rightFrame.contentWindow);
  rightFrame.src = `embed.html?runahead=${raSelect.value}`;
});

let bothPaused = false;
document.getElementById("reset-both").addEventListener("click", () => {
  postBoth({ type: "db-reset" });
});
document.getElementById("pause-both").addEventListener("click", (e) => {
  bothPaused = !bothPaused;
  postBoth({ type: "db-pause", paused: bothPaused });
  /** @type {HTMLButtonElement} */ (e.currentTarget).textContent =
    bothPaused ? "Resume both" : "Pause both";
});

// --- Keyboard -> both panes ---
// Input ids follow the core's Input enum: UP DOWN LEFT RIGHT A B SELECT START L R
const KEYMAP = {
  ArrowUp: 0, ArrowDown: 1, ArrowLeft: 2, ArrowRight: 3,
  KeyZ: 4, KeyX: 5, Backspace: 6, Enter: 7, KeyA: 8, KeyS: 9,
};

const held = new Set();
const updateFlash = () => {
  document.body.classList.toggle("btn-down", held.size > 0);
};

// Shared application point for this page's keyboard AND db-key forwards
// from a focused pane — one path, identical input in both cores.
const applyKey = (code, down) => {
  const id = KEYMAP[code];
  if (id === undefined) return;
  postBoth({ type: "db-input", id, down });
  if (down) held.add(id); else held.delete(id);
  updateFlash();
};

const onKey = (e, down) => {
  if (KEYMAP[e.code] === undefined) return;
  const t = /** @type {HTMLElement|null} */ (e.target);
  if (t && (t.tagName === "INPUT" || t.tagName === "SELECT" || t.tagName === "BUTTON")) return;
  e.preventDefault();
  if (down && e.repeat) return;
  applyKey(e.code, down);
};

document.addEventListener("keydown", (e) => onKey(e, true));
document.addEventListener("keyup", (e) => onKey(e, false));
window.addEventListener("blur", () => {
  // Never leave a button stuck down in either core
  for (const id of held) postBoth({ type: "db-input", id, down: false });
  held.clear();
  updateFlash();
});
