// The boot's Drive pull, end to end: two browsers running the real build
// against one fake Drive (devices.mjs, fakedrive.mjs). The second device
// boots with Google held back, so the pull is visibly out: its account
// slot turns the ring from the page's first parse, and a game tapped
// meanwhile waits ("Checking Drive…") for the other device's newer moment
// instead of opening on the older copy here (docs/home-screen.md, "The
// first sync").
//
//   cd web && npm ci && npx playwright install chromium webkit
//   nim c -d:emscripten src/dingbat_wasm.nim      # from the repo root
//   node --test e2e/boot-sync.e2e.mjs            # from web/
//
// Runs for every pair in DINGBAT_E2E_PAIRS (default "iphone+mac,mac+mac").

import { test, describe, before, after, afterEach } from "node:test";
import assert from "node:assert/strict";
import {
  startRig, builtWeb, sleep, front, addGame, play, mainMenu, closeGame,
  syncNow, openFirstTile, saveByte, toasts,
} from "./devices.mjs";

const PAIRS = (process.env.DINGBAT_E2E_PAIRS || "iphone+mac,mac+mac")
  .split(",").map((p) => p.split("+"));

const skip = builtWeb() ? false : "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)";

let rig;
before(async () => { if (!skip) rig = await startRig(); });
after(async () => { await rig?.close(); });
afterEach(async () => { await rig?.endTest(); });

for (const [kindA, kindB] of PAIRS) {
  describe(`${kindA} → ${kindB}`, { skip }, () => {
    test("a boot with the pull out rings, and a tap opens on the other device's newer moment", async () => {
      const drive = rig.drive();
      const a = await rig.device(drive, "A", kindA);
      const b = await rig.device(drive, "B", kindB);
      await addGame(a); await play(a, 30); await mainMenu(a); await syncNow(a);
      // B holds the game itself: downloaded from its tile, played, closed.
      await syncNow(b); await openFirstTile(b);
      await mainMenu(b); await closeGame(b); await syncNow(b);
      // A plays on: Drive's session and save are newer than B's. (A sees
      // B's session first, or its own would wait on it as an unseen write.)
      await syncNow(a);
      await front(a);
      await a.page.click("#hero-resume");
      await sleep(800);
      await play(a, 90); await mainMenu(a); await syncNow(a);
      const aSave = (await saveByte(a)).stored;
      assert.notEqual((await saveByte(b)).stored, aSave, "B's copy is the older one");

      // B boots with every Google request held until the gate opens.
      let open;
      const gate = new Promise((r) => { open = r; });
      await b.ctx.route(/googleapis\.com/, async (route) => { await gate; await route.fallback(); });
      await front(b);
      await b.page.reload({ waitUntil: "domcontentloaded" });
      // Drawn by index.html's hint script, before index.js has read anything.
      assert.deepEqual(await b.page.evaluate(() => ({
        shown: !document.getElementById("account-slot").hidden,
        sync: document.getElementById("account-btn").dataset.sync,
      })), { shown: true, sync: "syncing" });
      await b.page.waitForFunction(() => typeof syncStatus !== "undefined" && syncStatus === "syncing");
      assert.equal(await b.page.evaluate(() => document.getElementById("account-btn").dataset.sync),
                   "syncing", "index.js keeps the ring the hint drew");

      await b.page.locator("#hero-resume:visible, .home-tile-launch").first().click();
      await b.page.waitForFunction(() =>
        [document.querySelector(".home-tile-load-label")?.textContent,
         document.getElementById("hero-resume")?.textContent].some((t) => t?.includes("Checking Drive")));
      assert.equal(await b.page.evaluate(() => document.body.classList.contains("running")), false,
                   "held: not opened on the older copy");

      open();
      await b.page.waitForFunction(() => document.body.classList.contains("running"), null, { timeout: 20000 });
      await b.page.waitForFunction(() => syncStatus !== "syncing", null, { timeout: 20000 });
      await sleep(1500);
      assert.equal((await saveByte(b)).live, aSave, "opened on A's save");
      assert.ok(!(await toasts(b)).some((t) => t.includes("since you opened it here")),
                "no Switch offered over play");
      // WebKit reports the requests a reload cuts off as errors.
      const errors = b.errors.filter((e) => !e.includes("due to access control checks"));
      assert.deepEqual(errors, [], "no page errors: " + errors.join(" | "));
    });
  });
}
