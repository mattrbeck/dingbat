// The hand-off as Matt described it, step for step (2026-09-30):
//
//    1. Device 1 plays the game
//    2. Device 1 returns to the home screen, the game paused
//    3. Device 1 syncs
//    4. Device 2 opens the emulator
//    5. Device 2 syncs
//    6. Device 2 SHOULD show Device 1's exact picture of the game
//    7. Device 2 taps the game, and it SHOULD resume at the same place
//    8. Device 2 plays
//    9. Device 2 returns to the home screen, the game paused
//   10. Device 2 syncs
//   11. Device 1 syncs
//   12. Device 1's paused game SHOULD show Device 2's picture
//   13. Device 1 taps Resume
//   14. Device 1 SHOULD pick up where Device 2 left off
//
// "Opens the emulator" (4) is run four ways: a device that has never had
// the game; one that played it before, opened afresh; one whose tab was
// open on the home screen all along; and one whose tab was open with its
// own older copy of the game still paused. "Plays" is run both saving in
// game (A) and not saving (B), the second being what only the session can
// carry. Pictures are held against screens (a stored picture is a JPEG);
// "the same place" is the whole framebuffer, exactly.
//
//   node --test e2e/fourteen-steps.e2e.mjs        # from web/, as handoff.e2e.mjs
//
// DINGBAT_E2E_PAIRS picks the devices (default "iphone+mac,mac+iphone").

import { test, describe, before, after, afterEach } from "node:test";
import assert from "node:assert/strict";
import {
  startRig, builtWeb, GAME, front, idle, addGame, play, playNoSave, mainMenu,
  syncNow, openFirstTile, resumeHero, awayAndBack, saveByte, hero,
  screenPrint, grid, gridDistance,
} from "./devices.mjs";

const PAIRS = (process.env.DINGBAT_E2E_PAIRS || "iphone+mac,mac+iphone")
  .split(",").map((p) => p.split("+"));
const OPENS = ["new", "reopened", "tab-open", "tab-paused"];
const PLAYS = ["saving", "not saving"];
// A stored picture is a JPEG of the screen: within this many greys (of
// 255, averaged over a 40x36 grid) it is that screen. Measured: a picture
// is 0.0-0.3 from its own screen, and two moments of the test game are 4
// to 140 apart - so a moment counts as new only beyond 3 * SAME.
const SAME = 2;

const skip = builtWeb() ? false : "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)";
let rig;
before(async () => { if (!skip) rig = await startRig(); });
after(async () => { await rig?.close(); });
afterEach(async () => { await rig?.endTest(); });

// Play until the screen is unlike every picture in `unlike`, so a picture
// check afterwards can only pass on the right one.
const playOn = async (d, saving, unlike = []) => {
  const step = saving ? play : playNoSave;
  const seen = [];
  await step(d, 40);
  for (let i = 0; i < 20; i++) {
    const g = await grid(d, "screen");
    seen.push(unlike.map((u) => gridDistance(g, u).toFixed(0)).join("/") +
              "@c" + (await saveByte(d)).live);
    if (process.env.DINGBAT_E2E_DEBUG) {
      console.log("    playOn", d.who, unlike.map((u) => gridDistance(g, u).toFixed(1)).join(" "),
                  await d.page.evaluate(() => [paused, document.body.className].join(" ")));
    }
    if (unlike.every((u) => gridDistance(g, u) > 3 * SAME)) {
      if (process.env.DINGBAT_E2E_DEBUG) console.log("    seen", seen.join(" "));
      return;
    }
    await step(d, 2); // the colour scheme is c / 2: one scheme on, every time
  }
  // What the game is doing, frame by frame, for the failure message.
  const state = await d.page.evaluate(async () => {
    const out = [];
    for (let i = 0; i < 8; i++) {
      await new Promise((r) => requestAnimationFrame(r));
      const fb = copyFramebuffer();
      Module._wasm_flush_save?.();
      let c = null;
      try { c = FS.readFile(currentRomName.replace(/\.[^.]+$/, "") + ".sav")[0]; } catch {}
      out.push((fb ? framebufferSig(fb.heap) % 100000 : "-") + ":" + c);
    }
    return { frames: out.join(" "), paused, rewindHeld, fastForward, runaheadFrames,
             clip: clipReplayActive, game: currentOriginalName, body: document.body.className };
  });
  if (process.env.DINGBAT_E2E_DEBUG) console.log("    seen", seen.join(" "));
  throw new Error("the screen never moved away from the earlier pictures: " + seen.join(" ") +
                  " | " + JSON.stringify(state));
};

// What a paused device left behind: its screen, exactly and as a grid, and
// its save.
const moment = async (d) => ({
  print: await screenPrint(d),
  grid: await grid(d, "screen"),
  save: (await saveByte(d)).live,
});

const looksLike = (picture, want, notWant, what) => {
  const near = gridDistance(picture, want);
  const far = Math.min(...notWant.map((n) => gridDistance(picture, n)));
  console.log(`    ${what}: ${near.toFixed(1)} from the right picture, ${far.toFixed(1)} from the nearest wrong one`);
  assert.ok(near <= SAME && near < far,
    `${what}: ${near.toFixed(1)} greys from the right picture, ` +
    `${far.toFixed(1)} from the nearest wrong one`);
};

for (const [kind1, kind2] of PAIRS) {
  for (const opens of OPENS) {
    for (const plays of PLAYS) {
      describe(`device 1 ${kind1}, device 2 ${kind2} (${opens}), ${plays}`, { skip }, () => {
        test("steps 1-14", async () => {
          const saving = plays === "saving";
          const drive = rig.drive();
          const earlier = [];   // pictures of moments that are NOT the one to show
          let d1, d2;

          // Before the story: device 2's own history with the game.
          if (opens === "reopened" || opens === "tab-paused") {
            d2 = await rig.device(drive, "device 2", kind2);
            await addGame(d2);
            await play(d2, 20);           // an older save of its own
            await playOn(d2, false);
            await mainMenu(d2);
            earlier.push(await grid(d2, "screen"));
            await syncNow(d2);
            d1 = await rig.device(drive, "device 1", kind1);
            await openFirstTile(d1);      // device 1 has the game from Drive
          } else {
            if (opens === "tab-open") d2 = await rig.device(drive, "device 2", kind2);
            d1 = await rig.device(drive, "device 1", kind1);
            await addGame(d1);
          }

          // 1-3
          await playOn(d1, saving, earlier);
          await mainMenu(d1);
          const one = await moment(d1);
          await syncNow(d1);

          // 4-5
          if (opens === "new") {
            d2 = await rig.device(drive, "device 2", kind2);
          } else if (opens === "reopened") {
            await d2.page.reload();
            await d2.page.waitForFunction(() => typeof db !== "undefined" && !!db &&
              typeof gdriveToken !== "undefined" && !!gdriveToken);
            await idle(d2);
          } else {
            await front(d2);
            await awayAndBack(d2);        // the tab comes back into view
          }
          await syncNow(d2);

          // 6
          const shown = await grid(d2, opens === "tab-paused" ? "hero" : "tile");
          looksLike(shown, one.grid, earlier.length ? earlier : [await blankOf(d2)],
                    "step 6, device 2 shows device 1's picture");

          // 7
          if (opens === "tab-paused") await resumeHero(d2);
          else await openFirstTile(d2);
          assert.equal(await screenPrint(d2), one.print,
            "step 7, device 2 resumes on device 1's exact screen");
          if (saving) assert.equal((await saveByte(d2)).live, one.save, "step 7, with its save");

          // 8-10
          await playOn(d2, saving, [one.grid, ...earlier]);
          await mainMenu(d2);
          const two = await moment(d2);
          await syncNow(d2);

          // 11-12
          await syncNow(d1);
          const h = await hero(d1);
          looksLike(await grid(d1, "hero"), two.grid, [one.grid, ...earlier],
                    `step 12, device 1's hero (${h.mode}, "${h.kicker}") shows device 2's picture`);

          // 13-14
          assert.equal(h.primary, "Resume", "step 13, the hero offers Resume");
          await resumeHero(d1);
          assert.equal(await screenPrint(d1), two.print,
            "step 14, device 1 is on device 2's exact screen");
          if (saving) assert.equal((await saveByte(d1)).live, two.save, "step 14, with its save");
          // WebKit reports the requests a reload cuts off as errors.
          const errors = [...d1.errors, ...d2.errors]
            .filter((e) => !e.includes("due to access control checks"));
          assert.deepEqual(errors, [], "no page errors: " + errors.join(" | "));
        });
      });
    }
  }
}

// What a device shows for a game with no picture at all: the placeholder.
// Only a stand-in "wrong picture" for step 6 when there is no earlier one.
const blankOf = async () => new Array(40 * 36).fill(0);
