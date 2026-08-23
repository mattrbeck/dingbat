// parseDriveFileName: Drive file names mirror IndexedDB keys one-to-one.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, eq } from "./helpers.mjs";

test("parseDriveFileName maps every key kind and folds -p2", async () => {
  const { api } = await loadApp();
  eq(api.parseDriveFileName("rom:A.gba"), { game: "A.gba", kind: "rom" });
  eq(api.parseDriveFileName("save:A.gba"), { game: "A.gba", kind: "save" });
  eq(api.parseDriveFileName("save:A.gba-p2"), { game: "A.gba", kind: "save2" });
  eq(api.parseDriveFileName("state:A.gba"), { game: "A.gba", kind: "state" });
  assert.equal(api.parseDriveFileName("manifest.json"), null);
  assert.equal(api.parseDriveFileName("art:A.gba"), null, "art is not a Drive kind");
});

test("parseDriveFileName tolerates colons and quotes inside game names", async () => {
  const { api } = await loadApp();
  eq(api.parseDriveFileName('save:Zelda: Oracle "of" Ages.gbc'),
    { game: 'Zelda: Oracle "of" Ages.gbc', kind: "save" });
  eq(api.parseDriveFileName("rom:a:b:c.gba"), { game: "a:b:c.gba", kind: "rom" });
  eq(api.parseDriveFileName("save:x-p2.gba"), { game: "x-p2.gba", kind: "save" });
});

test("parseDriveFileName folds save-state slots + metadata into the base game", async () => {
  const { api } = await loadApp();
  eq(api.parseDriveFileName("state:A.gba"), { game: "A.gba", kind: "state" });
  eq(api.parseDriveFileName("statemeta:A.gba"), { game: "A.gba", kind: "statemeta" });
  // Slots 1..8 fold into the base game, not a phantom "A.gba:slotN" game.
  eq(api.parseDriveFileName("state:A.gba:slot3"), { game: "A.gba", kind: "state:3" });
  eq(api.parseDriveFileName("statemeta:A.gba:slot7"),
    { game: "A.gba", kind: "statemeta:7" });
  eq(api.parseDriveFileName("statemeta:A.gba:slot3"),
    { game: "A.gba", kind: "statemeta:3" });
  eq(api.parseDriveFileName("state:my:slot machine.gba"),
    { game: "my:slot machine.gba", kind: "state" });
});
