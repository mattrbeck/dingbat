// Games are shown by a title made from the file name (cleanTitle); a name
// typed in Rename is shown exactly as typed.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle, gameTiles, u8 } from "./helpers.mjs";

const CASES = [
  ["Legend of Zelda, The - Link's Awakening (USA, Europe).gb", "The Legend of Zelda: Link's Awakening"],
  ["Mario Kart Super Circuit (E) [!].gba", "Mario Kart Super Circuit"],
  ["Kirby - Tilt 'n' Tumble (USA).gbc", "Kirby: Tilt 'n' Tumble"],
  ["0412 - Metroid Fusion (U)(Venom).gba", "Metroid Fusion"],
  ["Pokemon - Crystal Version (USA, Europe) (Rev 1).gbc", "Pokemon: Crystal Version"],
  ["advance_wars_2.gba", "advance wars 2"],
  ["GoodboyGalaxy.gba", "GoodboyGalaxy"],
];

const REGIONS = [
  ["Legend of Zelda, The - Link's Awakening (USA, Europe).gb", "USA, Europe"],
  ["Mario Kart Super Circuit (E) [!].gba", "Europe"],
  ["Metroid Fusion (UE) (Rev 1).gba", "USA, Europe"],
  ["Golden Sun (En,Fr,De).gba", ""],
  ["Tetris.gb", ""],
];

test("a file name becomes a title", async () => {
  const app = await loadApp();
  for (const [name, want] of CASES) {
    assert.equal(app.runIn(`displayName(${JSON.stringify(name)})`), want, name);
  }
});

test("the region a file name carries", async () => {
  const app = await loadApp();
  for (const [name, want] of REGIONS) {
    assert.equal(app.runIn(`regionOf(${JSON.stringify(name)})`), want, name);
  }
});

test("a renamed game keeps the name as typed, brackets and all", async () => {
  const app = await loadApp();
  app.idb.set("recent", [{ name: "Zelda (USA).gb", ts: 1 }]);
  app.idb.set("rom:Zelda (USA).gb", { name: "Zelda (USA).gb", data: u8(1) });
  await app.api.refreshHomeRecent();
  await settle();
  const nameOf = () => gameTiles(app)[0].children[0].children[1].children[0].textContent;
  assert.equal(nameOf(), "Zelda");
  const res = await app.api.renameGame("Zelda (USA).gb", "Zelda - my hack (v2).gb");
  assert.ok(res.ok, res.error);
  await app.api.refreshHomeRecent();
  await settle();
  assert.equal(nameOf(), "Zelda - my hack (v2)");
  assert.deepEqual([...app.idb.get("usernames")], ["Zelda - my hack (v2).gb"]);
});
