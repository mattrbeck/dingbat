// Picking a game up on another device, end to end: two browsers running the
// real build against one fake Drive (devices.mjs, fakedrive.mjs).
//
//   cd web && npm ci && npx playwright install chromium webkit
//   nim c -d:emscripten src/dingbat_wasm.nim      # from the repo root
//   node --test e2e/*.e2e.mjs                    # from web/
//
// Each case runs for every pair in DINGBAT_E2E_PAIRS (default
// "iphone+mac,mac+mac": WebKit with an iPhone's screen and user agent, and
// desktop Chromium). The first device of a pair starts the game.

import { test, describe, before, after, afterEach } from "node:test";
import assert from "node:assert/strict";
import {
  startRig, builtWeb, GAME, sleep, front, idle, addGame, play, mainMenu, closeGame,
  syncNow, openFirstTile, resumeHero, tapToast, awayAndBack, playUntilUnlike, playNoSave,
  saveByte, screenPixel, hero, toasts, isPlaying, samePicture,
} from "./devices.mjs";

const PAIRS = (process.env.DINGBAT_E2E_PAIRS || "iphone+mac,mac+mac")
  .split(",").map((p) => p.split("+"));
const label = { iphone: "iPhone", mac: "Mac", "mac-webkit": "Mac" };

const skip = builtWeb() ? false : "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)";

let rig;
before(async () => { if (!skip) rig = await startRig(); });
after(async () => { await rig?.close(); });
afterEach(async () => { await rig?.endTest(); });

// Started on `a`: played until it saved, then the Main Menu, then Sync now.
const startOn = async (drive, kindA, frames = 30) => {
  const a = await rig.device(drive, "A", kindA);
  await addGame(a);
  await play(a, frames);
  await mainMenu(a);
  await syncNow(a);
  return a;
};

// The words another device is called by, from `here`'s side.
const calledFrom = (here, there) =>
  label[here] === label[there] ? "your other " + label[there] : "your " + label[there];

// Safari's private browsing keeps no Blob in IndexedDB, and every picture
// is one: a picture that cannot be kept must not stop the save arriving.
describe("iPhone in private browsing", { skip }, () => {
  test("still gets the other device's save, pictures or not", async () => {
    const drive = rig.drive();
    const a = await startOn(drive, "mac");
    const made = (await saveByte(a)).live;
    const b = await rig.device(drive, "B", "iphone-private");
    await syncNow(b);
    await openFirstTile(b);
    assert.equal((await saveByte(b)).live, made, "B plays on A's save");
    assert.ok(!(await toasts(b)).some((t) => t.startsWith("Couldn't download")), (await toasts(b)).join(" | "));
  });
});

for (const [kindA, kindB] of PAIRS) {
  describe(`${kindA} → ${kindB}`, { skip }, () => {

    test("a save made just before Main Menu goes up with Sync now", async () => {
      const drive = rig.drive();
      const a = await rig.device(drive, "A", kindA);
      await addGame(a);
      await play(a, 30);
      const made = (await saveByte(a)).live;
      await mainMenu(a);
      await syncNow(a);       // well inside the 5 s autosave
      assert.equal(drive.get("save:" + GAME)?.bytes[0], made, "Drive has the save just made");
      assert.ok(drive.session(GAME), "and the session of that moment");
    });

    test("the paused hero says when its moment has reached Drive", async () => {
      const drive = rig.drive();
      const a = await rig.device(drive, "A", kindA);
      await addGame(a);
      await play(a, 20);
      await mainMenu(a);
      assert.match((await hero(a)).kicker, /^Paused · (Syncing…|Synced)$/);
      await idle(a);        // no Sync tap: Main Menu queued it
      assert.equal((await hero(a)).kicker, "Paused · Synced");
      assert.ok(drive.session(GAME));
    });

    test("the other device opens the game where it was paused", async () => {
      const drive = rig.drive();
      const a = await startOn(drive, kindA);
      const mine = await screenPixel(a);
      const at = { save: (await saveByte(a)).live, screen: await screenPixel(a) };
      const b = await rig.device(drive, "B", kindB);    // a fresh visit pulls on its own
      await openFirstTile(b);
      assert.equal((await saveByte(b)).live, at.save, "B has A's save");
      assert.ok(samePicture(await screenPixel(b), at.screen), "and is at A's paused screen");
    });

    for (const leftAs of ["paused", "closed"]) {
      test(`back on the first device, left ${leftAs}: the hero and Resume are the other's`, async () => {
        const drive = rig.drive();
        const a = await startOn(drive, kindA);
        const mine = await screenPixel(a);
        if (leftAs === "closed") { await closeGame(a); await syncNow(a); }
        const b = await rig.device(drive, "B", kindB);
        await syncNow(b);
        await openFirstTile(b);
        await playUntilUnlike(b, 45, mine);
        const there = { save: (await saveByte(b)).live };
        await mainMenu(b);
        there.screen = await screenPixel(b);
        await syncNow(b);

        await syncNow(a);
        const h = await hero(a);
        assert.equal(h.mode, "closed", "A's stale copy is not offered as paused");
        assert.ok(samePicture(h.pixel, there.screen), `A's hero shows B's screen (${h.pixel} vs ${there.screen})`);
        assert.ok(h.kicker.startsWith("On " + calledFrom(kindA, kindB) + " · "), h.kicker);
        assert.equal(h.primary, "Resume");
        if (leftAs === "paused") {
          assert.ok((await toasts(a)).some((t) => t.includes("since — Resume picks up there")));
        }
        await resumeHero(a);
        assert.equal((await saveByte(a)).live, there.save, "Resume carries B's save");
        assert.ok(samePicture(await screenPixel(a), there.screen), "and lands on B's screen");
      });
    }

    test("a device left paused hands over on its own when its tab comes back", async () => {
      const drive = rig.drive();
      const a = await startOn(drive, kindA);
      const mine = await screenPixel(a);
      const b = await rig.device(drive, "B", kindB);
      await openFirstTile(b);
      await playUntilUnlike(b, 40, mine);
      const there = { save: (await saveByte(b)).live };
      await mainMenu(b);
      there.screen = await screenPixel(b);
      await syncNow(b);
      const theirs = drive.session(GAME);

      await front(a);
      await awayAndBack(a);
      assert.equal(drive.session(GAME).ts, theirs.ts, "A's away-and-back sent no old moment over B's");
      const h = await hero(a);
      assert.equal(h.mode, "closed");
      assert.ok(samePicture(h.pixel, there.screen), "A's hero turned to B's screen");
      await resumeHero(a);
      assert.equal((await saveByte(a)).live, there.save);
    });

    test("resumed before the sync landed: Switch is offered, and takes the other's moment", async () => {
      const drive = rig.drive();
      const a = await startOn(drive, kindA);
      const mine = await screenPixel(a);
      const b = await rig.device(drive, "B", kindB);
      await openFirstTile(b);
      await playUntilUnlike(b, 40, mine);
      const there = { save: (await saveByte(b)).live };
      await mainMenu(b);
      there.screen = await screenPixel(b);
      await syncNow(b);
      const theirs = drive.session(GAME);

      await resumeHero(a);        // A goes back into its own copy first
      await playNoSave(a, 30);    // and plays on, saving nothing
      await awayAndBack(a, { settle: false });
      await a.page.locator("#toast .toast-item button", { hasText: "Switch" }).first()
        .waitFor({ timeout: 30000 });
      assert.ok((await toasts(a)).some((t) => t.includes("since you opened it here")), "told");
      assert.ok(await isPlaying(a), "not yanked out of the game");
      await tapToast(a, "Switch");
      await idle(a);
      const h = await hero(a);
      assert.equal(h.mode, "closed", await a.page.evaluate(() => JSON.stringify({
        loaded: currentOriginalName, stash: handoffStash?.game ?? null, paused,
        body: document.body.className, toasts: window.__toastLog })));
      assert.ok(samePicture(h.pixel, there.screen), "A shows B's moment");
      assert.equal(drive.session(GAME).ts, theirs.ts, "and B's session is Drive's copy again");
      await resumeHero(a);
      assert.equal((await saveByte(a)).live, there.save);
    });

    test("kept playing instead: nothing is lost, and this device's later moment wins", async () => {
      const drive = rig.drive();
      const a = await startOn(drive, kindA);
      const mine = await screenPixel(a);
      const b = await rig.device(drive, "B", kindB);
      await openFirstTile(b);
      await playUntilUnlike(b, 40, mine);
      await mainMenu(b);
      await syncNow(b);
      const theirs = drive.session(GAME);

      await resumeHero(a);
      await playNoSave(a, 30);
      await awayAndBack(a);       // offered; not taken
      await playNoSave(a, 10);    // playing on in this copy
      await mainMenu(a);
      await idle(a);
      const now = drive.session(GAME);
      assert.ok(now.ts > theirs.ts && now.by !== theirs.by, "A's later moment is Drive's now");
      assert.equal((await hero(a)).kicker, "Paused · Synced");
    });
  });
}
