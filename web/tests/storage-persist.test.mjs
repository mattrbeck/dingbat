// navigator.storage.persist(): requested on ROM import and battery-save
// flush, at most once per session, skipped when already persisted.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8 } from "./helpers.mjs";

// The request is a detached promise chain; give the queue a beat.
const settle = () => new Promise((r) => setTimeout(r, 0));

test("ROM import requests persistent storage once per session", async () => {
  const app = await loadApp();
  await app.api.addRecentRom("A.gba", u8(1, 2, 3));
  await settle();
  assert.equal(app.state.persistCalls, 1);
  await app.api.addRecentRom("B.gba", u8(4, 5, 6)); // once-guard: no re-ask
  await settle();
  assert.equal(app.state.persistCalls, 1);
});

test("battery-save flush requests persistent storage", async () => {
  const app = await loadApp();
  app.sandbox.FS.files.set("rom.sav", u8(7, 7, 7));
  await app.api.persistSave("rom.gba", "Original.gba");
  await settle();
  assert.equal(app.state.persistCalls, 1);
});

test("no request when the origin is already persisted", async () => {
  const app = await loadApp();
  app.state.persisted = true;
  await app.api.addRecentRom("A.gba", u8(1));
  await settle();
  assert.equal(app.state.persistCalls, 0);
});

test("empty/missing save flush does not trigger a request", async () => {
  const app = await loadApp();
  await app.api.persistSave("rom.gba", "A.gba"); // no FS .sav file at all
  await settle();
  assert.equal(app.state.persistCalls, 0);
});
