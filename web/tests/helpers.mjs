// Test harness: evaluates the REAL web/index.js inside a node:vm context with
// stubbed browser globals (fake DOM, Map-backed fake IndexedDB, controllable
// fetch), then harvests the app's top-level functions out of the context's
// global lexical scope. Tests exercise the actual app code — nothing is
// reimplemented here. If web/index.js behavior changes, these tests break.

import { readFileSync } from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const SOURCE = readFileSync(new URL("../index.js", import.meta.url), "utf8");

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
  removeChild(c) { this.children = this.children.filter((x) => x !== c); }
  replaceChild(n, o) {
    const i = this.children.indexOf(o);
    if (i >= 0) this.children[i] = n; else this.children.push(n);
  }
  insertBefore(n) { this.children.unshift(n); return n; }
  remove() {}
  setAttribute(k, v) { this.attributes[k] = String(v); }
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
export const loadApp = async ({ localStorageSeed = {}, confirmResult = true } = {}) => {
  const idb = new Map();          // the fake IndexedDB "blobs" store
  const fetchCalls = [];          // every fetch: { url, opts, method }
  const alerts = [];
  const toasts = [];              // via the real showToast -> #toast textContent
  const confirms = [];

  const state = {
    confirmResult,
    // Tests replace this to control Drive responses.
    fetchImpl: async () => ({ ok: false, status: 599, text: async () => "", json: async () => ({}) }),
  };

  const lsMap = new Map(Object.entries(localStorageSeed));
  const localStorage = {
    getItem: (k) => (lsMap.has(k) ? lsMap.get(k) : null),
    setItem: (k, v) => lsMap.set(k, String(v)),
    removeItem: (k) => lsMap.delete(k),
  };

  const elements = new Map();
  const document = {
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, new FakeElement());
      return elements.get(id);
    },
    createElement: (tag) => new FakeElement(tag),
    querySelectorAll: () => [],
    querySelector: () => null,
    addEventListener() {},
    removeEventListener() {},
    elementFromPoint: () => null,
    visibilityState: "visible",
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
      maxTouchPoints: 0,
      userAgent: "node-test",
      storage: { estimate: async () => ({ usage: 12345 }) },
    },
    URL: { createObjectURL: () => "blob:fake", revokeObjectURL() {} },
    ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
    FileReader: FakeFileReader,
    requestAnimationFrame: () => 0,
    cancelAnimationFrame() {},
    alert: (msg) => alerts.push(String(msg)),
    confirm: (msg) => { confirms.push(String(msg)); return state.confirmResult; },
    console: { log() {}, warn() {}, error() {}, info() {}, debug() {} },
    FS: makeFakeFS(),
    caches: { keys: async () => [], delete: async () => true },
  };
  sandbox.addEventListener = () => {};
  sandbox.removeEventListener = () => {};
  sandbox.devicePixelRatio = 1;
  sandbox.innerWidth = 1024;
  sandbox.innerHeight = 768;
  sandbox.window = sandbox;
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;

  const context = vm.createContext(sandbox);
  vm.runInContext(SOURCE, context, { filename: "web/index.js" });

  // Harvest the app's top-level lexical bindings. Scripts run in the same
  // context share the global lexical environment, so const/let function
  // declarations from index.js are visible here.
  const api = vm.runInContext(`({
    openDB, dbGet, dbPut, dbDelete, dbKeys,
    migrateFromLocalStorage, migrateRecentFormat,
    romKey, artKey, stateKey, linkSaveKey, stripExt, formatBytes,
    getRecentMeta, getRomBytes, getRomArt,
    addRecentRom, bumpRecentIndex, touchRecent, deleteRecent, MAX_RECENT,
    romsWithSaveData, deleteSaveData, romsForManagement, isRomLoaded,
    persistSave, restoreSave,
    collectLocalBackupEntries, parseDriveFileName, groupDriveFiles,
    gdriveBackup, gdriveRestoreGame, driveFetch, driveListAll,
    driveUploadFile, driveDownload,
    refreshHomeRecent, handleRomFile, loadRom,
    get currentRomName() { return currentRomName; },
    set currentRomName(v) { currentRomName = v; },
    get currentOriginalName() { return currentOriginalName; },
    set currentOriginalName(v) { currentOriginalName = v; },
    get gdriveToken() { return gdriveToken; },
    set gdriveToken(v) { gdriveToken = v; },
    set gisScriptPromise(v) { gisScriptPromise = v; },
    get linkMode() { return linkMode; },
    set linkMode(v) { linkMode = v; },
    get linkRomEntry() { return linkRomEntry; },
    set linkRomEntry(v) { linkRomEntry = v; },
  })`, context);

  // Bring the app's IndexedDB handle up (real openDB against the fake indexedDB).
  await api.openDB();

  // Track toast text without touching app code.
  const toastEl = document.getElementById("toast");
  Object.defineProperty(toastEl, "textContent", {
    set: (v) => toasts.push(String(v)),
    get: () => toasts[toasts.length - 1] ?? "",
  });

  return {
    api, context, idb, fetchCalls, alerts, confirms, toasts,
    document, elements, localStorage, lsMap, sandbox,
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
