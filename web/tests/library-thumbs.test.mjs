// The library grid's thumbnail: each tile shows the last screen the game
// showed ("frame:<name>", a Blob the app stores whenever play stops being
// visible), else the box art, else the system chip standing in.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, u8, eq, settle } from "./helpers.mjs";

const grid = (app) => app.document.getElementById("home-recent");
const thumbOf = (tile) => tile.children[0].children[0]; // launch > thumb
const captionOf = (tile) => tile.children[0].children[1]; // launch > footer

const seedLibrary = (app, names) => {
  app.idb.set("recent", names.map((name, i) => ({ name, ts: 100 - i })));
  for (const n of names) app.idb.set("rom:" + n, { name: n, data: u8(1, 2) });
};

test("a stored frame renders as the tile's picture", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba"]);
  app.idb.set("frame:A.gba", new Blob([u8(1)], { type: "image/jpeg" }));
  await app.api.refreshHomeRecent();
  await settle();

  const tile = grid(app).children[0];
  const img = thumbOf(tile).children[0];
  assert.equal(img.tagName.toLowerCase(), "img");
  assert.ok(img.className.includes("home-tile-frame"), img.className);
  assert.ok(!tile.className.includes("no-art"), "the chip stands down");
});

test("the frame outranks the box art; the art outranks the chip", async () => {
  const app = await loadApp();
  seedLibrary(app, ["A.gba", "B.gba", "C.gb"]);
  app.idb.set("frame:A.gba", new Blob([u8(1)]));
  app.idb.set("art:A.gba", new Blob([u8(2)]));
  app.idb.set("art:B.gba", new Blob([u8(3)]));
  await app.api.refreshHomeRecent();
  await settle();

  const [a, b, c] = grid(app).children;
  assert.ok(thumbOf(a).children[0].className.includes("home-tile-frame"));
  assert.ok(thumbOf(b).children[0].className.includes("home-tile-art"));
  // Never opened, no art: the chip, and the caption does not repeat it.
  const chip = thumbOf(c).children[0];
  assert.ok(chip.className.includes("sys-chip"), chip.className);
  assert.equal(chip.textContent, "GB");
  assert.ok(c.className.includes("no-art"));
  assert.equal(captionOf(c).children[0].textContent, "C");
});

test("the frame is per-game inventory: evicted, deleted and renamed with the game", async () => {
  const app = await loadApp();
  assert.ok(app.api.allPerGameKeys("A.gba").includes("frame:A.gba"));
  app.idb.set("frame:A.gba", u8(1));
  await app.api.evictLocalRom("A.gba");
  assert.equal(app.idb.get("frame:A.gba"), undefined, "evicted with the ROM");
});

test("the frame is not something Drive mirrors", async () => {
  const app = await loadApp();
  assert.equal(app.api.parseDriveFileName("frame:A.gba"), null);
});

test("storeLastFrame is a no-op without a running game or a wasm runtime", async () => {
  const app = await loadApp();
  await app.runIn("storeLastFrame({ force: true })");
  assert.equal([...app.idb.keys()].filter((k) => k.startsWith("frame:")).length, 0);
  app.api.currentRomName = "A.gba";
  app.api.currentOriginalName = "A.gba";
  await app.runIn("storeLastFrame({ force: true })"); // Module is undefined here
  assert.equal([...app.idb.keys()].filter((k) => k.startsWith("frame:")).length, 0);
});

test("storeLastFrame writes frame:<name> from the framebuffer", async () => {
  const app = await loadApp();
  app.api.currentRomName = "A.gba";
  app.api.currentOriginalName = "A.gba";
  // A wasm stand-in: a 240x160 RGBA framebuffer at offset 0 of `memory`,
  // and a canvas whose toBlob yields a JPEG.
  const fb = new Uint8Array(240 * 160 * 4);
  app.runIn(`
    globalThis.Module = { _wasm_fb_ptr: () => 16, memory: { buffer: new ArrayBuffer(16 + ${fb.length}) } };
    const realCreate = document.createElement.bind(document);
    document.createElement = (tag) => {
      const el = realCreate(tag);
      if (tag === "canvas") el.toBlob = (cb, type) => cb(new Blob([new Uint8Array([0xff, 0xd8])], { type }));
      return el;
    };
  `);
  await app.runIn("storeLastFrame({ force: true })");
  const stored = app.idb.get("frame:A.gba");
  assert.ok(stored instanceof Blob, "a Blob was stored");
  assert.equal(stored.type, "image/jpeg");

  // The tick skips an unchanged picture; a change writes again.
  app.idb.delete("frame:A.gba");
  await app.runIn("storeLastFrame()");
  assert.equal(app.idb.get("frame:A.gba"), undefined, "unchanged: skipped");
  app.runIn("new Uint8Array(Module.memory.buffer, 16, 4).set([9, 9, 9, 255])");
  await app.runIn("storeLastFrame()");
  assert.ok(app.idb.get("frame:A.gba") instanceof Blob, "changed: written");
});
