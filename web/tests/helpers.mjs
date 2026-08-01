// Test harness: evaluates the REAL web/index.js inside a node:vm context with
// stubbed browser globals (fake DOM, Map-backed fake IndexedDB, controllable
// fetch), then harvests the app's top-level functions out of the context's
// global lexical scope. Tests exercise the actual app code — nothing is
// reimplemented here. If web/index.js behavior changes, these tests break.

import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

// index.js calls createGlRenderer() at top-level eval; that helper lives in
// glpresent.js (loaded as a separate <script> before index.js in index.html),
// so the vm context needs it prepended too.
const SOURCE =
  readFileSync(new URL("../glpresent.js", import.meta.url), "utf8") + "\n" +
  readFileSync(new URL("../index.js", import.meta.url), "utf8");

// --- Fake DOM ---------------------------------------------------------------

class FakeClassList {
  constructor() { this._set = new Set(); }
  add(...cs) { for (const c of cs) this._set.add(c); }
  remove(...cs) { for (const c of cs) this._set.delete(c); }
  toggle(c, force) {
    const on = force === undefined ? !this._set.has(c) : !!force;
    on ? this._set.add(c) : this._set.delete(c);
    return on;
  }
  contains(c) { return this._set.has(c); }
}

class FakeElement {
  constructor(tag = "div") {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.classList = new FakeClassList();
    this.style = { setProperty() {}, removeProperty() {} };
    this.attributes = {};
    this.dataset = {};
    this.hidden = false;
    this.disabled = false;
    this.textContent = "";
    this.value = "";
    this.title = "";
    this._listeners = {};
    this._innerHTML = "";
  }
  addEventListener(type, fn) { (this._listeners[type] ??= []).push(fn); }
  removeEventListener(type, fn) {
    this._listeners[type] = (this._listeners[type] || []).filter((f) => f !== fn);
  }
  async dispatch(type, ev = {}) {
    ev.target ??= this;
    ev.preventDefault ??= () => {};
    ev.stopPropagation ??= () => {};
    for (const f of this._listeners[type] || []) await f(ev);
  }
  appendChild(c) { this.children.push(c); return c; }
  // Variadic sibling of appendChild (showActionToast, the prints gallery).
  append(...cs) { for (const c of cs) this.children.push(c); }
  // Head insertion — how the toast stack mounts its newest pill (pushToast).
  prepend(...cs) { this.children.unshift(...cs); }
  // Atomic swap — how the home grid commits a render (see refreshHomeRecent).
  replaceChildren(...cs) { this.children = cs; }
  removeChild(c) { this.children = this.children.filter((x) => x !== c); }
  replaceChild(n, o) {
    const i = this.children.indexOf(o);
    if (i >= 0) this.children[i] = n; else this.children.push(n);
  }
  insertBefore(n) { this.children.unshift(n); return n; }
  remove() {}
  setAttribute(k, v) { this.attributes[k] = String(v); }
  removeAttribute(k) { delete this.attributes[k]; }
  getAttribute(k) { return k in this.attributes ? this.attributes[k] : null; }
  hasAttribute(k) { return k in this.attributes; }
  focus() {}
  click() { return this.dispatch("click"); }
  querySelectorAll() { return []; }
  querySelector() { return null; }
  getBoundingClientRect() {
    return { width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0, x: 0, y: 0 };
  }
  getContext() {
    // Permissive 2D-context stand-in: any method call is a no-op.
    return new Proxy({}, { get: (_t, p) => (p === "canvas" ? this : () => undefined) });
  }
  set innerHTML(v) { this._innerHTML = v; if (v === "") this.children = []; }
  get innerHTML() { return this._innerHTML; }
  // className and classList are two views of one set, as in a real DOM. They
  // used to be unrelated here, so `el.className = "toast-msg"` left
  // classList.contains("toast-msg") false — invisible until something tried
  // to find an element by the class another line had just assigned.
  set className(v) {
    this.classList._set = new Set(String(v).split(/\s+/).filter(Boolean));
  }
  get className() { return [...this.classList._set].join(" "); }
}

// --- Fake IndexedDB (Map-backed, real async request shape) ------------------

const mkReq = (fn) => {
  const req = {};
  queueMicrotask(() => {
    try { req.result = fn(); req.onsuccess?.(); }
    catch (e) { req.error = e; req.onerror?.(); }
  });
  return req;
};

const makeFakeIndexedDB = (store) => ({
  open() {
    const req = {};
    queueMicrotask(() => {
      req.result = {
        objectStoreNames: { contains: () => true },
        createObjectStore() {},
        transaction: () => ({
          objectStore: () => ({
            get: (k) => mkReq(() => store.get(k)),
            put: (v, k) => mkReq(() => { store.set(k, v); }),
            delete: (k) => mkReq(() => { store.delete(k); }),
            // Real IndexedDB returns keys in ascending key order
            getAllKeys: () => mkReq(() => [...store.keys()].sort()),
          }),
        }),
      };
      req.onupgradeneeded?.();
      req.onsuccess?.();
    });
    return req;
  },
});

// --- Misc stubs -------------------------------------------------------------

class FakeFileReader {
  readAsArrayBuffer(file) {
    queueMicrotask(() => {
      this.result = file._bytes.buffer.slice(
        file._bytes.byteOffset, file._bytes.byteOffset + file._bytes.byteLength);
      for (const f of this._load || []) f();
    });
  }
  addEventListener(type, fn) { (this["_" + type] ??= []).push(fn); }
}

// A fake picked File for FakeFileReader.
export const fakeFile = (name, bytes) => ({ name, _bytes: bytes });

// In-memory Emscripten-FS stand-in (writeToFS / persistSave / resetLoadedGameSave).
const makeFakeFS = () => {
  const files = new Map();
  return {
    files,
    open: (name) => ({ name, buf: [] }),
    write(stream, bytes) { files.set(stream.name, new Uint8Array(bytes)); },
    close() {},
    readFile(name) {
      if (!files.has(name)) throw new Error("ENOENT: " + name);
      return files.get(name);
    },
    unlink(name) { files.delete(name); },
  };
};

// --- App loader -------------------------------------------------------------

// Evaluates web/index.js in a fresh vm context and returns handles to the real
// functions plus the fakes backing it.
export const loadApp = async ({ localStorageSeed = {}, confirmResult = true,
                                touch = false, mediaDevices = true } = {}) => {
  const idb = new Map();          // the fake IndexedDB "blobs" store
  const fetchCalls = [];          // every fetch: { url, opts, method }
  const alerts = [];
  const toasts = [];              // every message the real app mounted in #toast
  const confirms = [];

  const state = {
    confirmResult,
    // Tests replace this to control Drive responses.
    fetchImpl: async () => ({ ok: false, status: 599, text: async () => "", json: async () => ({}) }),
    // navigator.storage.persist() fake: already-persisted flag, grant result,
    // and a call counter tests assert on.
    persisted: false,
    persistGrant: true,
    persistCalls: 0,
    // matchMedia() queries that should report matches:true (e.g.
    // "(display-mode: standalone)"). Everything else reports false.
    mediaMatches: {},
  };

  const lsMap = new Map(Object.entries(localStorageSeed));
  const localStorage = {
    getItem: (k) => (lsMap.has(k) ? lsMap.get(k) : null),
    setItem: (k, v) => lsMap.set(k, String(v)),
    removeItem: (k) => lsMap.delete(k),
  };

  const elements = new Map();
  // Document-level listeners are recorded (not just swallowed) so tests can
  // dispatch synthetic events — e.g. the global Escape-closes-modals handler.
  const docListeners = {};
  const document = {
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, new FakeElement());
      return elements.get(id);
    },
    createElement: (tag) => new FakeElement(tag),
    querySelectorAll: () => [],
    querySelector: () => null,
    addEventListener(type, fn) { (docListeners[type] ??= []).push(fn); },
    removeEventListener(type, fn) {
      docListeners[type] = (docListeners[type] || []).filter((f) => f !== fn);
    },
    elementFromPoint: () => null,
    visibilityState: "visible",
    // Held at "loading" so index.js's early-boot block registers its
    // DOMContentLoaded listener (which we never fire) instead of kicking off
    // initStorage — tests drive openDB/migrations/refreshHomeRecent
    // explicitly, and an auto-boot racing them would be nondeterministic.
    readyState: "loading",
    body: new FakeElement("body"),
    head: new FakeElement("head"),
    documentElement: new FakeElement("html"),
  };

  const sandbox = {
    // Realm-unification: pass host intrinsics so `instanceof Uint8Array` etc.
    // inside the vm matches bytes created by tests and by host Blob/Response.
    Uint8Array, ArrayBuffer, Blob, TextDecoder, TextEncoder,
    URLSearchParams, Response,
    atob, btoa, performance,
    setTimeout: (fn, ms) => { const t = setTimeout(fn, ms); t.unref?.(); return t; },
    clearTimeout, // host
    setInterval: (fn, ms) => { const t = setInterval(fn, ms); t.unref?.(); return t; },
    clearInterval,
    queueMicrotask,
    document,
    localStorage,
    indexedDB: makeFakeIndexedDB(idb),
    fetch: (url, opts = {}) => {
      fetchCalls.push({ url: String(url), opts, method: opts.method || "GET" });
      return state.fetchImpl(url, opts);
    },
    location: { search: "", reload() {} },
    // No `serviceWorker` key: index.js guards with `"serviceWorker" in navigator`.
    navigator: {
      platform: "TestPlatform",
      // `touch` flips the module-scope `touchDevice` const (and the tilt
      // code's own touch test), which decides whether phone-only affordances
      // — device-tilt, front/back camera flipping — are offered at all.
      maxTouchPoints: touch ? 5 : 0,
      userAgent: "node-test",
      // getUserMedia's mere existence is what the camera code reads as "a
      // camera is possible here"; `mediaDevices: false` is the insecure-origin
      // shape, where the API is absent entirely. Nothing here ever resolves —
      // tests that need a stream drive the state variables directly.
      ...(mediaDevices
        ? { mediaDevices: { getUserMedia: () => new Promise(() => {}),
                            enumerateDevices: async () => [] } }
        : {}),
      storage: {
        estimate: async () => ({ usage: 12345 }),
        persisted: async () => state.persisted,
        persist: async () => { state.persistCalls++; return state.persistGrant; },
      },
    },
    // index.js evaluates matchMedia("(display-mode: standalone)") at module
    // scope, so a missing stub is not a soft failure — it aborts the whole
    // eval and every test in the suite. Reports "not matching" for any query;
    // `state.mediaMatches` lets a test opt a query into matching.
    matchMedia: (query) => ({
      media: String(query),
      matches: !!state.mediaMatches[String(query)],
      onchange: null,
      addEventListener() {}, removeEventListener() {},
      addListener() {}, removeListener() {},
      dispatchEvent: () => false,
    }),
    // The tilt code reads screen.orientation.angle to rotate device-frame
    // motion into screen space, and subscribes to its change event at module
    // scope. Same rule as matchMedia: a missing stub aborts the whole eval.
    // `state.screenAngle` lets a test pretend the device is rotated.
    screen: {
      get orientation() {
        return {
          get angle() { return state.screenAngle || 0; },
          type: "portrait-primary",
          addEventListener() {}, removeEventListener() {},
          dispatchEvent: () => false,
        };
      },
      width: 390, height: 844,
    },
    URL: { createObjectURL: () => "blob:fake", revokeObjectURL() {} },
    ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
    // index.js watches the menu dropdown's `hidden` attribute at module scope
    // to mirror it into aria-expanded; inert here (no attribute mutations in
    // the fake DOM anyway).
    MutationObserver: class { observe() {} disconnect() {} takeRecords() { return []; } },
    FileReader: FakeFileReader,
    requestAnimationFrame: () => 0,
    cancelAnimationFrame() {},
    alert: (msg) => alerts.push(String(msg)),
    confirm: (msg) => { confirms.push(String(msg)); return state.confirmResult; },
    console: { log() {}, warn() {}, error() {}, info() {}, debug() {} },
    FS: makeFakeFS(),
    caches: { keys: async () => [], delete: async () => true },
  };
  // Window-level listeners are recorded (like document's) so tests can fire
  // synthetic events — e.g. the one-shot pointerdown that triggers the
  // gesture-gated Drive token renewal.
  const winListeners = {};
  sandbox.addEventListener = (type, fn) => { (winListeners[type] ??= []).push(fn); };
  sandbox.removeEventListener = (type, fn) => {
    winListeners[type] = (winListeners[type] || []).filter((f) => f !== fn);
  };
  // updateCanvasScaling reads stage padding via getComputedStyle; "" keeps
  // parseFloat() NaN-free callers happy enough (NaN paddings are tolerated —
  // the canvas just gets no explicit size in tests) and getPropertyValue("")
  // matches the CSS-variable reads.
  sandbox.getComputedStyle = () =>
    new Proxy({}, { get: (_t, p) => (p === "getPropertyValue" ? () => "" : "0") });
  sandbox.devicePixelRatio = 1;
  sandbox.innerWidth = 1024;
  sandbox.innerHeight = 768;
  sandbox.window = sandbox;
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;

  // --- Toast observation ----------------------------------------------------
  // #toast is a STACK container: showToast/showActionToast build one
  // .toast-item per message and prepend it (web/index.js, pushToast). So the
  // faithful observation point is "a pill was mounted into the live region" —
  // exactly the moment its text becomes visible — not the old
  // #toast.textContent setter, which the stack never touches.
  //
  // Wired BEFORE index.js is evaluated so a toast fired during module-scope
  // eval or early boot is recorded too.
  const toastEl = document.getElementById("toast");
  const toastMsgOf = (node) => {
    const span = (node.children || []).find((c) => c.classList?.contains("toast-msg"));
    if (!span) {
      // Loud on purpose. If the toast DOM shape in web/index.js changes and
      // this silently returned "", every toast assertion in the suite would
      // start passing/failing against an empty list instead of real behavior.
      throw new Error(
        "web/tests/helpers.mjs: a <" + node.tagName + "> was mounted into " +
        "#toast with no .toast-msg child. The toast DOM shape in " +
        "web/index.js changed and this harness can no longer see what the " +
        "app shows. Update toastMsgOf to match before trusting any test " +
        "that asserts on `toasts`.");
    }
    return String(span.textContent);
  };
  for (const method of ["prepend", "append", "appendChild"]) {
    const real = toastEl[method].bind(toastEl);
    toastEl[method] = (...cs) => {
      for (const c of cs) toasts.push(toastMsgOf(c));
      return real(...cs);
    };
  }
  // What is on screen right now, as opposed to `toasts` (the whole history).
  // .leaving pills are mid-fade and already retired, so they don't count.
  const liveToasts = () =>
    toastEl.children
      .filter((c) => !c.classList.contains("leaving"))
      .map(toastMsgOf);

  const context = vm.createContext(sandbox);
  try {
    vm.runInContext(SOURCE, context, { filename: "web/index.js" });
  } catch (e) {
    // A browser global index.js newly touches at module scope (matchMedia,
    // screen, visualViewport, ...) aborts the eval, and every test in every
    // file then fails with the same bare ReferenceError. Say what to do.
    const missing = /^(\w+) is not defined$/.exec(e?.message || "")?.[1];
    if (missing) {
      const message =
        `${e.message} — web/index.js uses the browser global \`${missing}\` ` +
        `at module scope, but the node:vm sandbox in web/tests/helpers.mjs ` +
        `does not stub it. Add a \`${missing}\` stub to \`sandbox\` there.`;
      // The reporter prints .stack, which embeds the original message, so
      // rewrite both — otherwise the hint is invisible in CI logs.
      const frames = String(e.stack || "").split("\n").slice(1).join("\n");
      e.message = message;
      e.stack = `${e.name}: ${message}\n${frames}`;
    }
    throw e;
  }

  // Harvest the app's top-level lexical bindings. Scripts run in the same
  // context share the global lexical environment, so const/let function
  // declarations from index.js are visible here.
  const api = vm.runInContext(`({
    openDB, dbGet, dbPut, dbDelete, dbKeys,
    migrateFromLocalStorage, migrateRecentFormat,
    romKey, artKey, stateKey, linkSaveKey, stripExt, formatBytes,
    getRecentMeta, getRomBytes, getRomArt,
    addRecentRom, bumpRecentIndex, touchRecent, deleteRecent, MAX_RECENT,
    evictLocalRom,
    romsWithSaveData, deleteSaveData, romsForManagement, isRomLoaded,
    refreshRomsManageList,
    persistSave, restoreSave,
    parseDriveFileName, driveFetch, driveListAll,
    driveUploadFile, driveDownload,
    localSyncFiles, mergeLibrary, syncActive, loadSyncState,
    markUpload, markDelete, markGameUpload, flushSync, pullSync, syncPollTick,
    downloadGame, removeGameFromDevice,
    deleteGameEverywhere, resetGameSaves, queueSaveDataDeletes,
    get syncState() { return syncState; },
    set syncState(v) { syncState = v; },
    applyImportedState, applyStateBytes, stateRejectMessage, looksLikeStateFile,
    refreshHomeRecent, handleRomFile, loadRom,
    looksLikeValidRom, closeRomWarnModal,
    serializeCheats, parseCheats, validateCheat, applyCheats, restoreCheats,
    renderCheatList,
    get cheatList() { return cheatList; },
    set cheatList(v) { cheatList = v; },
    get currentRomName() { return currentRomName; },
    set currentRomName(v) { currentRomName = v; },
    get currentOriginalName() { return currentOriginalName; },
    set currentOriginalName(v) { currentOriginalName = v; },
    get gdriveToken() { return gdriveToken; },
    set gdriveToken(v) { gdriveToken = v; },
    get gdriveTokenExp() { return gdriveTokenExp; },
    set gdriveTokenExp(v) { gdriveTokenExp = v; },
    set gisScriptPromise(v) { gisScriptPromise = v; },
    driveTokenStale, renewDriveToken, armDriveRenewOnGesture,
    DRIVE_RENEW_LEAD_MS, DRIVE_RENEW_MAX_FAILS,
    get driveRenewFails() { return driveRenewFails; },
    set driveRenewFails(v) { driveRenewFails = v; },
    get linkMode() { return linkMode; },
    set linkMode(v) { linkMode = v; },
    get linkRomEntry() { return linkRomEntry; },
    set linkRomEntry(v) { linkRomEntry = v; },
  })`, context);

  // Bring the app's IndexedDB handle up (real openDB against the fake indexedDB).
  await api.openDB();

  // No wasm runtime ever initializes inside the vm, but launch paths
  // (launchRom / handleRomFile / launchLinkRom) now await it before touching
  // FS/Module. Mark it ready so those paths run to completion in tests.
  vm.runInContext("markRuntimeReady()", context);

  // Fire every recorded document-level listener of `type` with a stub-filled
  // event, awaiting async handlers (mirrors FakeElement.dispatch).
  const dispatchDoc = async (type, ev = {}) => {
    ev.preventDefault ??= () => {};
    ev.stopPropagation ??= () => {};
    ev.stopImmediatePropagation ??= () => {};
    for (const f of docListeners[type] || []) await f(ev);
  };

  // Same, for window-level listeners.
  const dispatchWin = async (type, ev = {}) => {
    ev.preventDefault ??= () => {};
    ev.stopPropagation ??= () => {};
    for (const f of (winListeners[type] || []).slice()) await f(ev);
  };

  return {
    api, context, idb, fetchCalls, alerts, confirms, toasts, liveToasts, toastEl,
    document, elements, localStorage, lsMap, sandbox, state,
    docListeners, dispatchDoc, winListeners, dispatchWin,
    setFetch: (fn) => { state.fetchImpl = fn; },
    setConfirmResult: (v) => { state.confirmResult = v; },
    runIn: (code) => vm.runInContext(code, context),
  };
};

// JSON Response helper for fake Drive endpoints.
export const jsonRes = (obj, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  json: async () => obj,
  text: async () => JSON.stringify(obj),
  arrayBuffer: async () => new ArrayBuffer(0),
});

export const bytesRes = (bytes, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  json: async () => ({}),
  text: async () => "",
  arrayBuffer: async () =>
    bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
});

export const u8 = (...vals) => new Uint8Array(vals);

// Wait for queued microtasks (fake-IDB request callbacks) to settle.
export const settle = () => new Promise((r) => setTimeout(r, 0));

// Structural deep-equality that tolerates vm-realm prototypes (objects created
// inside the evaluated web/index.js have the context's Object.prototype, which
// assert.deepStrictEqual would reject).
export const eq = (actual, expected, msg) =>
  assert.deepStrictEqual(structuredClone(actual), structuredClone(expected), msg);
