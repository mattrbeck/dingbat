// A game added from a zip, end to end: its tile and the hero say the zip's
// name, on this device after a reload and on another device through Drive,
// while its save and session stay the ROM's (docs/dev/home-screen.md, "A
// game from a zip").
//
//   cd web && npm ci && npx playwright install chromium webkit
//   nim c -d:emscripten src/dingbat_wasm.nim      # from the repo root
//   node --test e2e/zip-title.e2e.mjs            # from web/
//
// Runs for every pair in DINGBAT_E2E_PAIRS (default "iphone+mac,mac+mac").

import { test, describe, before, after, afterEach } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { createRequire } from "node:module";
import {
  startRig, builtWeb, sleep, front, play, mainMenu, syncNow, openFirstTile, saveByte,
  WEB, GAME,
} from "./devices.mjs";
import { synctestRom } from "./synctest-rom.mjs";

createRequire(join(WEB, "package.json"))("./zipwrite.js"); // globalThis.ZipWrite
const ZIP = "Sync Test Collection.zip";
const TITLE = "Sync Test Collection";

const PAIRS = (process.env.DINGBAT_E2E_PAIRS || "iphone+mac,mac+mac")
  .split(",").map((p) => p.split("+"));

const skip = builtWeb() ? false : "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)";

let rig;
before(async () => { if (!skip) rig = await startRig(); });
after(async () => { await rig?.close(); });
afterEach(async () => { await rig?.endTest(); });

// `answer`: the button clicked when another game has the ROM's name; the
// Keep both line as it read is returned.
const addZip = async (d, { name = ZIP, rom = synctestRom(), answer = null } = {}) => {
  await front(d);
  const [chooser] = await Promise.all([
    d.page.waitForEvent("filechooser"),
    d.page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click(),
  ]);
  const zip = Buffer.concat(globalThis.ZipWrite.build([{ name: GAME, data: rom }], new Date()));
  await chooser.setFiles({ name, mimeType: "application/zip", buffer: zip });
  let asked = null;
  if (answer) {
    await d.page.locator("#rom-clash-modal.open").waitFor({ timeout: 20000 });
    asked = await d.page.locator("#rom-clash-both-sub").textContent();
    await d.page.click("#" + answer);
  }
  await d.page.waitForFunction(() => document.body.classList.contains("running") &&
    !document.body.classList.contains("home-flying") && !paused, null, { timeout: 20000 });
  await sleep(400);
  return asked;
};
// Another game under the ROM's name: one byte past its code changed.
const otherRom = (b) => { const r = synctestRom(); r[r.length - 1] = b; return r; };
const GAME2 = GAME.replace(/(\.[^.]+)$/, " (2)$1");
const names = (d) => d.page.evaluate(() => ({
  hero: document.getElementById("hero").hidden ? null : document.getElementById("hero-name").textContent,
  tiles: [...document.querySelectorAll(".home-tile")].map((t) =>
    [t.dataset.rom, t.querySelector(".home-tile-name").textContent]),
}));
const keysNaming = (d, s) => d.page.evaluate(async (s) =>
  (await dbKeys()).filter((k) => typeof k === "string" && k.includes(s)), s);

for (const [kindA, kindB] of PAIRS) {
  describe(`${kindA} → ${kindB}`, { skip }, () => {
    test("a zip's game is shown under the zip's name and keeps the ROM's save", async () => {
      const drive = rig.drive();
      const a = await rig.device(drive, "A", kindA);
      await addZip(a);
      assert.equal(await a.page.evaluate(() => currentOriginalName), GAME);
      await play(a, 30);
      await mainMenu(a);
      assert.equal((await names(a)).hero, TITLE, "the paused hero");
      await syncNow(a);
      const save = (await saveByte(a)).stored;
      assert.ok(save != null, "the game saved");
      eq(await keysNaming(a, TITLE), [], "nothing is stored under the zip's name");
      assert.ok((await keysNaming(a, "stateauto:" + GAME)).length, "the session is the ROM's");

      // A fresh visit: the stored entry still names it.
      await a.page.reload();
      await a.page.waitForFunction(() => typeof db !== "undefined" && !!db &&
        document.querySelector(".home-tile"));
      eq((await names(a)).tiles, [[GAME, TITLE]]);
      await openFirstTile(a);
      eq(await saveByte(a), { live: save, stored: save }, "opened on its own save");

      // Another device: the Drive-only tile, then the download.
      const b = await rig.device(drive, "B", kindB);
      await syncNow(b);
      eq((await names(b)).tiles, [[GAME, TITLE]]);
      await openFirstTile(b);
      eq(await saveByte(b), { live: save, stored: save }, "the download keeps the save");
      await mainMenu(b);
      assert.equal((await names(b)).hero, TITLE);

      // A third device, the game only on Drive: the same zip with another
      // ROM (Drive's digest tells them apart), Keep both. It goes beside it
      // under the zip's name, numbered as its file.
      const c = await rig.device(drive, "C", kindA);
      await syncNow(c);
      const asked = await addZip(c, { rom: otherRom(1), answer: "rom-clash-both" });
      assert.match(asked, new RegExp("“" + TITLE + " \\(2\\)”"), "the question names it as its tile");
      assert.equal(await c.page.evaluate(() => currentOriginalName), GAME2);
      await mainMenu(c);
      eq((await names(c)).tiles.sort(), [[GAME2, TITLE + " (2)"], [GAME, TITLE]]);

      // Another zip, Replace: the game takes that zip's name.
      await addZip(c, { name: "Other Pack.zip", rom: otherRom(2), answer: "rom-clash-replace" });
      assert.equal(await c.page.evaluate(() => currentOriginalName), GAME);
      await mainMenu(c);
      eq((await names(c)).tiles.sort(), [[GAME2, TITLE + " (2)"], [GAME, "Other Pack"]]);
      // WebKit reports the requests a reload cuts off as errors.
      const errors = [...a.errors, ...b.errors, ...c.errors]
        .filter((e) => !e.includes("due to access control checks"));
      assert.deepEqual(errors, [], "no page errors: " + errors.join(" | "));
    });
  });
}

const eq = (a, b, msg) => assert.deepEqual(a, b, msg);
