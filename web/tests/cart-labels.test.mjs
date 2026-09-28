// A game with no picture yet shows a cartridge with a short mark on its
// label: two initials of a tidied title and a sequel's number. The table is
// the rule set agreed on the home-states design canvas.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle, gameTiles, u8 } from "./helpers.mjs";

const CASES = [
  ["Metroid Fusion (U) [!].gba", "MF", "dump tags go"],
  ["0412 - Metroid Fusion (U)(Venom).gba", "MF", "and release numbers"],
  ["Pokemon - Crystal Version (USA, Europe) (Rev 1).gbc", "PC", "small words skipped"],
  ["Legend of Zelda, The - The Minish Cap (U).gba", "LZ", "a trailing The comes round"],
  ["GoodboyGalaxy.gba", "GG", "one run split at its capitals"],
  ["advance_wars_2.gba", "AW2", "underscores are spaces; a sequel keeps its number"],
  ["Final Fantasy VI Advance (J).gba", "FF6", "a roman numeral anywhere after the first word"],
  ["Golden Sun 2 - The Lost Age (E).gba", "GS2", ""],
  ["TETRIS.gb", "Te", "one word: its first two letters"],
  ["Mother 3 (J).gba", "Mo3", ""],
  ["Kirby's Dream Land (USA, Europe).gb", "KD", "an apostrophe does not split a word"],
  ["Mega Man X.gbc", "MM", "X is not read as ten"],
  ["ポケットモンスター ルビー (J).gba", "ポル", "any script"],
];

test("the cartridge label rules", async () => {
  const app = await loadApp();
  for (const [name, want, why] of CASES) {
    assert.equal(app.runIn(`cartLabelFor(${JSON.stringify(name)})`), want, name + (why ? " — " + why : ""));
  }
});

test("a tile with no picture carries its system's cartridge and label", async () => {
  const app = await loadApp();
  app.idb.set("recent", [{ name: "A.gba", ts: 2 }, { name: "Metroid Fusion (U).gba", ts: 1 },
                         { name: "Tetris.gb", ts: 0 }]);
  for (const n of ["A.gba", "Metroid Fusion (U).gba", "Tetris.gb"]) app.idb.set("rom:" + n, { name: n, data: u8(1) });
  await app.api.refreshHomeRecent();
  await settle();
  const cart = (rom) => gameTiles(app).find((t) => t.dataset.rom === rom)
    .children[0].children[0].children[0];
  assert.equal(cart("Metroid Fusion (U).gba").className, "lib-cart cart-gba");
  assert.equal(cart("Metroid Fusion (U).gba").children[0].textContent, "MF");
  assert.equal(cart("Tetris.gb").className, "lib-cart cart-gb");
});
