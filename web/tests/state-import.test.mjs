// Save-state import toast copy.
//
// Two rules, and the second one is newer:
//
//  1. A file that isn't a dingbat save state at all must NOT be reported as a
//     rejected state. That distinction is a JS-side sniff of the "DGBSTATE"
//     header magic (src/dingbat/common/serialize.nim), because wasm_load_state
//     only returns a boolean.
//  2. A state the core DID recognise and refuse must say WHICH refusal it was.
//     "State didn't match this game" used to be the answer to every one of
//     them, and it is actively wrong for four of the five — it sent people
//     hunting for the wrong problem when the real answer was "your dingbat is
//     older than the one that wrote this". The core now classifies the refusal
//     (StateRejectKind, exposed as wasm_state_error_kind) and the UI writes a
//     sentence per cause that says what to do about it.
//
// These assertions are the contract for that copy. If the wording changes,
// change it here too — but do not collapse two causes back onto one string.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const MAGIC = [..."DGBSTATE"].map((c) => c.charCodeAt(0));

// StateRejectKind ordinals from src/dingbat/common/serialize.nim.
const SRK = {
  NONE: 0, NOT_A_STATE: 1, WRONG_CORE: 2, WRONG_ROM: 3,
  TOO_NEW: 4, TRUNCATED: 5, CORRUPT: 6, NO_FILE: 7,
};

// A fake Emscripten Module whose _wasm_load_state returns `result` and whose
// _wasm_state_error_kind returns `kind`.
const fakeModule = (result, kind = SRK.NONE, detail = "") => ({
  _malloc: () => 8,
  _free() {},
  _wasm_load_state: () => result,
  _wasm_state_error_kind: () => kind,
  _wasm_state_error: () => 1,
  UTF8ToString: () => detail,
  memory: { buffer: new ArrayBuffer(4096) },
});

const realState = () => {
  const bytes = new Uint8Array(64);
  bytes.set(MAGIC, 0);
  return bytes;
};

test("importing a garbage file says it's not a save state file", async () => {
  const app = await loadApp();
  app.sandbox.Module = fakeModule(0); // never reached: magic sniff fails first
  app.api.applyImportedState(new Uint8Array([0x50, 0x4b, 0x03, 0x04, 9, 9]));
  assert.match(app.toasts.at(-1), /isn't a dingbat save state/);
});

test("an empty/truncated file also gets the not-a-state copy", async () => {
  const app = await loadApp();
  app.api.applyImportedState(new Uint8Array(0));
  assert.match(app.toasts.at(-1), /isn't a dingbat save state/);
});

test("an accepted state image toasts State loaded", async () => {
  const app = await loadApp();
  app.sandbox.Module = fakeModule(1);
  app.api.applyImportedState(realState());
  assert.equal(app.toasts.at(-1), "State loaded");
});

// --- one sentence per cause, and they must all be different ----------------

test("a state for another game says so, and says what to do", async () => {
  const app = await loadApp();
  app.sandbox.Module = fakeModule(0, SRK.WRONG_ROM);
  app.api.applyImportedState(realState());
  assert.match(app.toasts.at(-1), /belongs to a different game/);
  assert.match(app.toasts.at(-1), /Load the game it was made in/);
});

test("a state from a newer dingbat says to update, not that it's corrupt", async () => {
  const app = await loadApp();
  app.sandbox.Module = fakeModule(0, SRK.TOO_NEW);
  app.api.applyImportedState(realState());
  assert.match(app.toasts.at(-1), /newer version of dingbat/);
  assert.doesNotMatch(app.toasts.at(-1), /damaged|different game/);
});

test("a GB state offered to a GBA game names the system mismatch", async () => {
  const app = await loadApp();
  app.sandbox.Module = fakeModule(0, SRK.WRONG_CORE);
  app.api.applyImportedState(realState());
  assert.match(app.toasts.at(-1), /for the other system/);
});

test("a short file blames the transfer, not the file's contents", async () => {
  const app = await loadApp();
  app.sandbox.Module = fakeModule(0, SRK.TRUNCATED);
  app.api.applyImportedState(realState());
  assert.match(app.toasts.at(-1), /incomplete/);
  assert.match(app.toasts.at(-1), /again/);
});

test("a damaged state reassures that the running game is untouched", async () => {
  const app = await loadApp();
  app.sandbox.Module = fakeModule(0, SRK.CORRUPT);
  app.api.applyImportedState(realState());
  assert.match(app.toasts.at(-1), /damaged/);
  // The core restores its pre-load payload on any failure; saying so is the
  // difference between a scary message and an informative one.
  assert.match(app.toasts.at(-1), /nothing was changed/);
});

test("every cause gets a distinct sentence", async () => {
  const app = await loadApp();
  const seen = new Set();
  for (const kind of [SRK.WRONG_CORE, SRK.WRONG_ROM, SRK.TOO_NEW,
                      SRK.TRUNCATED, SRK.CORRUPT, SRK.NO_FILE]) {
    app.sandbox.Module = fakeModule(0, kind);
    app.api.applyImportedState(realState());
    seen.add(app.toasts.at(-1));
  }
  assert.equal(seen.size, 6, "two refusal causes share one message");
});

test("an unclassified refusal still says something useful", async () => {
  // Older wasm builds have no _wasm_state_error_kind at all; the UI must not
  // fall back to a blank toast or to a raw exception string.
  const app = await loadApp();
  app.sandbox.Module = {
    _malloc: () => 8, _free() {}, _wasm_load_state: () => 0,
    memory: { buffer: new ArrayBuffer(4096) },
  };
  app.api.applyImportedState(realState());
  assert.match(app.toasts.at(-1), /couldn't be loaded/);
});
