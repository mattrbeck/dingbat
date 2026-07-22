// Drive file-name mapping: the real parseDriveFileName / groupDriveFiles
// from web/index.js. Drive file names mirror IndexedDB keys one-to-one.

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
  // A name that merely contains "-p2" mid-string is not a P2 save
  eq(api.parseDriveFileName("save:x-p2.gba"), { game: "x-p2.gba", kind: "save" });
});

test("parseDriveFileName folds save-state slots + metadata into the base game", async () => {
  const { api } = await loadApp();
  // Slot 0 keeps the legacy keys/kinds.
  eq(api.parseDriveFileName("state:A.gba"), { game: "A.gba", kind: "state" });
  eq(api.parseDriveFileName("statemeta:A.gba"), { game: "A.gba", kind: "statemeta" });
  // Slots 1..8 fold into the base game (no phantom "A.gba:slotN" game).
  eq(api.parseDriveFileName("state:A.gba:slot3"), { game: "A.gba", kind: "state:3" });
  eq(api.parseDriveFileName("statemeta:A.gba:slot7"),
    { game: "A.gba", kind: "statemeta:7" });
  // "statemeta:" is distinguished from "state:" even though it starts the same.
  eq(api.parseDriveFileName("statemeta:A.gba:slot3"),
    { game: "A.gba", kind: "statemeta:3" });
  // A game name that merely contains ":slot" mid-string is not a slot suffix.
  eq(api.parseDriveFileName("state:my:slot machine.gba"),
    { game: "my:slot machine.gba", kind: "state" });
});

test("groupDriveFiles groups by game, sorted by name", async () => {
  const { api } = await loadApp();
  const files = [
    { id: "1", name: "save:B.gba", size: "8" },
    { id: "2", name: "rom:A.gba", size: "100" },
    { id: "3", name: "save:A.gba", size: "8" },
    { id: "4", name: "save:A.gba-p2", size: "8" },
    { id: "5", name: "state:A.gba", size: "50" },
    { id: "6", name: "unrelated.bin", size: "1" }, // ignored
  ];
  const groups = api.groupDriveFiles(files);
  eq(groups.map((g) => g.game), ["A.gba", "B.gba"]);
  const a = groups[0].files;
  assert.equal(a.rom.id, "2");
  assert.equal(a.save.id, "3");
  assert.equal(a.save2.id, "4");
  assert.equal(a.state.id, "5");
  eq(Object.keys(groups[1].files), ["save"], "save-only game groups cleanly");
});
