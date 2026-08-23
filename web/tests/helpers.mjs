// Test harness: evaluates the real web/index.js in a node:vm context with
// stubbed browser globals (fake DOM, Map-backed fake IndexedDB, controllable
// fetch) and harvests its top-level functions from the global lexical scope.
// A browser global index.js newly touches at module scope must be stubbed
// here, or every web test dies with the same ReferenceError.

import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

// glpresent.js (createGlRenderer) and saveimport.js load before index.js in
// index.html, so they are prepended here too.
const SOURCE =
  readFileSync(new URL("../glpresent.js", import.meta.url), "utf8") + "\n" +
  readFileSync(new URL("../saveimport.js", import.meta.url), "utf8") + "\n" +
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

// The shape of `new ImageData(data, w, h)`.
class FakeImageData {
  constructor(data, width, height) {
    this.data = data;
    this.width = width;
    this.height = height;
  }
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
    // Handlers registered for several event names branch on `type`.
    ev.type ??= type;
    ev.target ??= this;
    ev.preventDefault ??= () => {};
    ev.stopPropagation ??= () => {};
    for (const f of this._listeners[type] || []) await f(ev);
  }
  appendChild(c) { this.children.push(c); return c; }
  append(...cs) { for (const c of cs) this.children.push(c); }
  prepend(...cs) { this.children.unshift(...cs); }
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
    // 2D-context stand-in: every method is a no-op except the two that are
    // read from (getImageData().data would otherwise be `undefined.data`).
    const self = this;
    return new Proxy({}, {
      get: (_t, p) => {
        if (p === "canvas") return self;
        if (p === "getImageData" || p === "createImageData") {
          return (...args) => {
            const w = args.length >= 4 ? args[2] : args[0];
            const h = args.length >= 4 ? args[3] : args[1];
            return new FakeImageData(new Uint8ClampedArray(Math.max(0, w * h) * 4),
                                     w, h);
          };
        }
        return () => undefined;
      },
    });
  }
  set innerHTML(v) { this._innerHTML = v; if (v === "") this.children = []; }
  get innerHTML() { return this._innerHTML; }
  // className and classList are two views of one set, as in a real DOM.
  set className(v) {
    this.classList._set = new Set(String(v).split(/\s+/).filter(Boolean));
  }
  get className() { return [...this.classList._set].join(" "); }
}

// --- Fake IndexedDB (Map-backed, real async request shape) ------------------

// A transaction with what dbMoveKeys depends on: `oncomplete` fires once
// every request issued on it (including from another request's onsuccess)
// has settled, and an abort rolls the store back. Writes hit the Map
// immediately (tests read it straight after awaiting dbPut); atomicity is an
// undo log. `state.idbFail(op, key)` makes that one request fail.
const makeFakeTx = (store, state) => {
  let pending = 0;
  let settled = false;
  const undo = []; // [key, hadIt, previousValue], oldest first
  const tx = { error: null, abort: () => doAbort(null) };

  const doAbort = (err) => {
    if (settled) return;
    settled = true;
    tx.error = tx.error || err || null;
    for (let i = undo.length - 1; i >= 0; i--) {
      const [k, had, prev] = undo[i];
      had ? store.set(k, prev) : store.delete(k);
    }
    tx.onabort?.();
  };

  const req = (op, key, fn) => {
    const r = {};
    if (settled) return r; // post-abort requests are inert, as in a real tx
    pending++;
    queueMicrotask(() => {
      pending--;
      if (settled) return;
      if (state?.idbFail?.(op, key)) {
        r.error = new Error(`fake IndexedDB failure: ${op} ${key}`);
        r.onerror?.();
        tx.error = r.error;
        tx.onerror?.();
        doAbort(r.error); // a failed request aborts its transaction
        return;
      }
      try { r.result = fn(); }
      catch (e) { r.error = e; r.onerror?.(); doAbort(e); return; }
      r.onsuccess?.(); // may issue further requests on this same transaction
      if (!pending && !settled) { settled = true; tx.oncomplete?.(); }
    });
    return r;
  };

  const remember = (k) => undo.push([k, store.has(k), store.get(k)]);

  tx.objectStore = () => ({
    get: (k) => req("get", k, () => store.get(k)),
    put: (v, k) => req("put", k, () => { remember(k); store.set(k, v); }),
    delete: (k) => req("delete", k, () => { remember(k); store.delete(k); }),
    // Ascending key order, as real IndexedDB.
    getAllKeys: () => req("getAllKeys", null, () => [...store.keys()].sort()),
  });
  return tx;
};

const makeFakeIndexedDB = (store, state) => ({
  open() {
    const req = {};
    queueMicrotask(() => {
      req.result = {
        objectStoreNames: { contains: () => true },
        createObjectStore() {},
        transaction: () => makeFakeTx(store, state),
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

export const fakeFile = (name, bytes) => ({ name, _bytes: bytes });

// Emscripten-FS stand-in.
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

export const loadApp = async ({ localStorageSeed = {}, confirmResult = true,
                                touch = false, mediaDevices = true,
                                serviceWorker = false } = {}) => {
  const idb = new Map();          // the fake IndexedDB "blobs" store
  const fetchCalls = [];          // every fetch: { url, opts, method }
  const alerts = [];
  const toasts = [];              // every message the real app mounted in #toast
  const confirms = [];

  const state = {
    confirmResult,
    fetchImpl: async () => ({ ok: false, status: 599, text: async () => "", json: async () => ({}) }),
    // navigator.storage.persist() fake.
    persisted: false,
    persistGrant: true,
    persistCalls: 0,
    // matchMedia() queries that report matches:true; all others false.
    mediaMatches: {},
    // location.reload() call count (the SW update-flow tests' signal).
    reloads: 0,
    // registration.update() body; tests replace it to plant a worker.
    swUpdateImpl: async () => {},
  };

  // --- Fake service worker container (opt-in: loadApp({ serviceWorker })) ---
  // index.js guards its SW block with `"serviceWorker" in navigator`, so the
  // key exists only when asked for. `true` boots uncontrolled (first visit);
  // `{ controlled: true }` boots controlled. Workers are inert records: tests
  // flip `.state` and fire events themselves.
  const makeSWWorker = (state0 = "installed") => {
    const listeners = {};
    return {
      state: state0,
      messages: [], // every postMessage payload, e.g. {type:"skipWaiting"}
      postMessage(msg) { this.messages.push(msg); },
      addEventListener(type, fn) { (listeners[type] ??= []).push(fn); },
      removeEventListener(type, fn) {
        listeners[type] = (listeners[type] || []).filter((f) => f !== fn);
      },
      dispatch(type, ev = {}) { for (const f of (listeners[type] || []).slice()) f(ev); },
    };
  };
  let sw = null;
  if (serviceWorker) {
    const regListeners = {};
    const registration = {
      waiting: null,
      installing: null,
      unregisterCalls: 0,
      updateCalls: 0,
      addEventListener(type, fn) { (regListeners[type] ??= []).push(fn); },
      removeEventListener(type, fn) {
        regListeners[type] = (regListeners[type] || []).filter((f) => f !== fn);
      },
      dispatch(type, ev = {}) { for (const f of (regListeners[type] || []).slice()) f(ev); },
      async update() { this.updateCalls++; await state.swUpdateImpl(); },
      async unregister() { this.unregisterCalls++; return true; },
    };
    const containerListeners = {};
    const container = {
      controller: serviceWorker.controlled ? makeSWWorker("activated") : null,
      register: async () => registration,
      getRegistrations: async () => [registration],
      addEventListener(type, fn) { (containerListeners[type] ??= []).push(fn); },
      removeEventListener(type, fn) {
        containerListeners[type] = (containerListeners[type] || []).filter((f) => f !== fn);
      },
      dispatch(type, ev = {}) { for (const f of (containerListeners[type] || []).slice()) f(ev); },
    };
    // A handover as the page sees it: new controller, then controllerchange.
    sw = {
      registration, container, makeWorker: makeSWWorker,
      takeControl(worker = makeSWWorker("activated")) {
        container.controller = worker;
        container.dispatch("controllerchange");
      },
    };
  }

  const lsMap = new Map(Object.entries(localStorageSeed));
  const localStorage = {
    getItem: (k) => (lsMap.has(k) ? lsMap.get(k) : null),
    setItem: (k, v) => lsMap.set(k, String(v)),
    removeItem: (k) => lsMap.delete(k),
  };

  const elements = new Map();
  // Document-level listeners are recorded so tests can dispatch to them.
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
    // Held at "loading" so index.js registers a DOMContentLoaded listener
    // (never fired) instead of auto-booting initStorage, which would race
    // the tests' explicit openDB/migrations/refreshHomeRecent.
    readyState: "loading",
    body: new FakeElement("body"),
    head: new FakeElement("head"),
    documentElement: new FakeElement("html"),
  };

  const sandbox = {
    // Host intrinsics so `instanceof Uint8Array` etc. match across realms.
    Uint8Array, ArrayBuffer, Blob, TextDecoder, TextEncoder,
    URLSearchParams, Response,
    Uint8ClampedArray, ImageData: FakeImageData,
    atob, btoa, performance,
    setTimeout: (fn, ms) => { const t = setTimeout(fn, ms); t.unref?.(); return t; },
    clearTimeout, // host
    setInterval: (fn, ms) => { const t = setInterval(fn, ms); t.unref?.(); return t; },
    clearInterval,
    queueMicrotask,
    document,
    localStorage,
    indexedDB: makeFakeIndexedDB(idb, state),
    fetch: (url, opts = {}) => {
      fetchCalls.push({ url: String(url), opts, method: opts.method || "GET" });
      return state.fetchImpl(url, opts);
    },
    location: { search: "", reload() { state.reloads++; } },
    navigator: {
      ...(sw ? { serviceWorker: sw.container } : {}),
      platform: "TestPlatform",
      // `touch` flips the module-scope `touchDevice` const (phone-only
      // affordances: tilt, camera flipping).
      maxTouchPoints: touch ? 5 : 0,
      userAgent: "node-test",
      // getUserMedia's existence is what the camera code reads as "a camera
      // is possible"; `mediaDevices: false` is the insecure-origin shape. It
      // never resolves: tests drive the state variables directly.
      ...(mediaDevices
        ? { mediaDevices: { getUserMedia: () => new Promise(() => {}),
                            enumerateDevices: async () => [] } }
        : {}),
      // Transient activation, read before opening the Drive popup; flip
      // isActive to false for the background-timer case.
      userActivation: { get isActive() { return state.userActivation !== false; } },
      storage: {
        estimate: async () => ({ usage: 12345 }),
        persisted: async () => state.persisted,
        persist: async () => { state.persistCalls++; return state.persistGrant; },
      },
    },
    // Evaluated at module scope, so a missing stub aborts every test.
    matchMedia: (query) => ({
      media: String(query),
      matches: !!state.mediaMatches[String(query)],
      onchange: null,
      addEventListener() {}, removeEventListener() {},
      addListener() {}, removeListener() {},
      dispatchEvent: () => false,
    }),
    // screen.orientation is subscribed at module scope (same rule as
    // matchMedia); `state.screenAngle` rotates the device.
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
    // Observed at module scope; inert here.
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
  // Window-level listeners are recorded, like document's.
  const winListeners = {};
  sandbox.addEventListener = (type, fn) => { (winListeners[type] ??= []).push(fn); };
  sandbox.removeEventListener = (type, fn) => {
    winListeners[type] = (winListeners[type] || []).filter((f) => f !== fn);
  };
  // updateCanvasScaling reads stage padding via getComputedStyle; NaN
  // paddings are tolerated (the canvas just gets no explicit size).
  sandbox.getComputedStyle = () =>
    new Proxy({}, { get: (_t, p) => (p === "getPropertyValue" ? () => "" : "0") });
  sandbox.devicePixelRatio = 1;
  sandbox.innerWidth = 1024;
  sandbox.innerHeight = 768;
  sandbox.window = sandbox;
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;

  // --- Toast observation ----------------------------------------------------
  // #toast is a stack (pushToast prepends one .toast-item per message), so
  // the observation point is a pill being mounted. Wired before index.js is
  // evaluated so early-boot toasts are recorded too.
  const toastEl = document.getElementById("toast");
  const toastMsgOf = (node) => {
    const span = (node.children || []).find((c) => c.classList?.contains("toast-msg"));
    if (!span) {
      // Loud: a changed toast DOM shape must not silently empty every
      // toast assertion in the suite.
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
  // On screen now (vs `toasts`, the history); .leaving pills are retired.
  const liveToasts = () =>
    toastEl.children
      .filter((c) => !c.classList.contains("leaving"))
      .map(toastMsgOf);

  const context = vm.createContext(sandbox);
  try {
    vm.runInContext(SOURCE, context, { filename: "web/index.js" });
  } catch (e) {
    // A browser global newly touched at module scope aborts the eval for
    // every test; say what to do.
    const missing = /^(\w+) is not defined$/.exec(e?.message || "")?.[1];
    if (missing) {
      const message =
        `${e.message} — web/index.js uses the browser global \`${missing}\` ` +
        `at module scope, but the node:vm sandbox in web/tests/helpers.mjs ` +
        `does not stub it. Add a \`${missing}\` stub to \`sandbox\` there.`;
      // The reporter prints .stack, so rewrite both.
      const frames = String(e.stack || "").split("\n").slice(1).join("\n");
      e.message = message;
      e.stack = `${e.name}: ${message}\n${frames}`;
    }
    throw e;
  }

  // Scripts run in the same context share the global lexical environment,
  // so index.js's const/let bindings are visible here.
  const api = vm.runInContext(`({
    openDB, dbGet, dbPut, dbDelete, dbKeys,
    migrateFromLocalStorage, migrateRecentFormat,
    romKey, artKey, stateKey, linkSaveKey, stripExt, formatBytes,
    dbMoveKeys, allPerGameKeys, perGameKeys, libraryNames,
    splitRomName, renameFullName, renameNameError, renameInventory,
    renameInventoryLines, renameGame, openRenameModal, RENAME_MAX_LEN,
    getRecentMeta, getRomBytes, getRomArt,
    addRecentRom, bumpRecentIndex, touchRecent, deleteRecent, MAX_RECENT,
    evictLocalRom,
    romsWithSaveData, deleteSaveData, romsForManagement, isRomLoaded,
    refreshRomsManageList,
    persistSave, restoreSave,
    parseDriveFileName, driveFetch, driveListAll,
    driveUploadFile, driveDownload,
    localSyncFiles, mergeLibrary, syncActive, loadSyncState,
    applyRemoteRename, hasAnyLocalRecord, driveRenameFile,
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
    driveLinked, gdriveAcquireToken, ensureDriveSignedIn, gdriveConnect,
    refreshSyncStatus, resumeDriveOnBoot,
    get gdriveEmail() { return gdriveEmail; },
    set gdriveEmail(v) { gdriveEmail = v; },
    get syncStatus() { return syncStatus; },
    DRIVE_RENEW_LEAD_MS, DRIVE_RENEW_MAX_FAILS,
    get driveRenewFails() { return driveRenewFails; },
    set driveRenewFails(v) { driveRenewFails = v; },
    get linkMode() { return linkMode; },
    set linkMode(v) { linkMode = v; },
    get linkRomEntry() { return linkRomEntry; },
    set linkRomEntry(v) { linkRomEntry = v; },
    storePrint, loadPrinterPhotos, refreshPrintsMenuItem, openPrintsModal,
    closePrintsModal, PRINTER_PHOTOS_KEY, PRINTER_DOTS_KEY,
    get printerPhotos() { return printerPhotos; },
    set printerPhotos(v) { printerPhotos = v; },
    get photoDots() { return photoDots; },
    GB_HW_SHADES, GB_THEME_PALETTES, THEME_NAMES, SETTINGS_KEYS,
    gbPaletteColors, loadGbPalette, resetGbPalette, resetAllSettings,
    detectMonoPanel, applyTheme, currentThemeName,
    get gbPaletteMode() { return gbPaletteMode; },
    set gbPaletteMode(v) { gbPaletteMode = v; },
    get gbPaletteCustom() { return gbPaletteCustom; },
    set gbPaletteCustom(v) { gbPaletteCustom = v; },
    get gbMonoPanel() { return gbMonoPanel; },
    set gbMonoPanel(v) { gbMonoPanel = v; },
    get runaheadFrames() { return runaheadFrames; },
  })`, context);

  await api.openDB();

  // No wasm runtime initializes in the vm; launch paths await it, so mark
  // it ready.
  vm.runInContext("markRuntimeReady()", context);

  const dispatchDoc = async (type, ev = {}) => {
    ev.type ??= type;
    ev.preventDefault ??= () => {};
    ev.stopPropagation ??= () => {};
    ev.stopImmediatePropagation ??= () => {};
    for (const f of docListeners[type] || []) await f(ev);
  };

  const dispatchWin = async (type, ev = {}) => {
    ev.type ??= type;
    ev.preventDefault ??= () => {};
    ev.stopPropagation ??= () => {};
    for (const f of (winListeners[type] || []).slice()) await f(ev);
  };

  return {
    api, context, idb, fetchCalls, alerts, confirms, toasts, liveToasts, toastEl,
    sw, document, elements, localStorage, lsMap, sandbox, state,
    docListeners, dispatchDoc, winListeners, dispatchWin,
    setFetch: (fn) => { state.fetchImpl = fn; },
    setConfirmResult: (v) => { state.confirmResult = v; },
    runIn: (code) => vm.runInContext(code, context),
  };
};

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

export const settle = () => new Promise((r) => setTimeout(r, 0));

// Deep equality tolerant of vm-realm prototypes (assert.deepStrictEqual
// rejects the context's Object.prototype).
export const eq = (actual, expected, msg) =>
  assert.deepStrictEqual(structuredClone(actual), structuredClone(expected), msg);
