// A browser that dies, or quits, with a game on screen (index.js
// "Checkpoints", "Crashes", "Last gasp"): the real build, the browser
// process killed with SIGKILL or closed, then launched again on the same
// profile. The game is e2e's test ROM: its counter c goes up a frame while
// A or B is held, and A also writes c to the battery save - so after each
// relaunch the game is opened from its tile and c read back exactly.
//
//   node --test e2e/crash-recovery.e2e.mjs        # from web/, after the wasm build
//
// Chromium and WebKit, as the other e2e files choose them
// (DINGBAT_E2E_NO_CHROMIUM, DINGBAT_E2E_CHROMIUM_CHANNEL).

import { test, describe, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execSync } from "node:child_process";
import { createRequire } from "node:module";
import { serveWeb, builtWeb, sleep, WEB } from "./devices.mjs";
import { synctestRom, SYNCTEST_NAME as GAME } from "./synctest-rom.mjs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");

const skip = builtWeb() ? false : "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)";
const ENGINES = process.env.DINGBAT_E2E_NO_CHROMIUM ? ["webkit"] : ["chromium", "webkit"];
const channel = process.env.DINGBAT_E2E_CHROMIUM_CHANNEL;
const launchOpts = (engine) => ({
  headless: true, viewport: { width: 1000, height: 800 },
  ...(engine === "chromium" && channel ? { channel } : {}),
});

let web = null;
const site = async () => (web ??= await serveWeb());
after(() => web?.close());

// One player on one browser profile, which outlives the browser.
class Player {
  constructor(engine) { this.engine = engine; }
  async start() {
    this.dir = await mkdtemp(join(tmpdir(), "dingbat-crash-"));
    await this.open();
    const [chooser] = await Promise.all([this.page.waitForEvent("filechooser"),
      this.page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click()]);
    await chooser.setFiles({ name: GAME, mimeType: "application/octet-stream",
                             buffer: Buffer.from(synctestRom()) });
    await this.running();
  }
  async open() {
    this.ctx = await playwright[this.engine].launchPersistentContext(this.dir, launchOpts(this.engine));
    this.page = this.ctx.pages()[0] || await this.ctx.newPage();
    await this.page.goto((await site()).url);
    await this.page.waitForFunction(() => typeof Module !== "undefined" && runtimeReady &&
      typeof db !== "undefined" && !!db, null, { timeout: 60000 });
    // The one-time offer to picture the library would open over the tile.
    await this.page.evaluate(() => dbPut(THUMBS_OFFER_KEY, Date.now()));
    await sleep(500);
  }
  running() {
    return this.page.waitForFunction(() => document.body.classList.contains("running") &&
      !document.body.classList.contains("home-flying") && !paused, null, { timeout: 30000 });
  }
  // A button held for exactly `frames` emulated frames, let go on the last.
  hold(input, frames) {
    return this.page.evaluate(([input, frames]) => new Promise((resolve) => {
      const step = Module._loop_tick;
      let ran = 0;
      Module._loop_tick = (...a) => {
        if (ran >= frames) return step(...a);
        Module._setInput(input, 1);
        const r = step(...a);
        if (++ran === frames) {
          Module._setInput(input, 0);
          Module._loop_tick = step;
          setTimeout(resolve, 0);
        }
        return r;
      };
    }), [input, frames]);
  }
  save(frames) { return this.hold(4, frames); }   // A: plays and saves in game
  play(frames) { return this.hold(5, frames); }   // B: plays, saves nothing
  // c as the core has it: one frame of A writes c + 1 to the battery.
  async counter() {
    await this.save(1);
    return this.page.evaluate(() => {
      Module._wasm_flush_save?.();
      return FS.readFile(currentRomName.replace(/\.[^.]+$/, "") + ".sav")[0] - 1;
    });
  }
  // The minute's checkpoint, taken now and landed.
  checkpoint() {
    return this.page.evaluate(() => {
      runPlayMs = ckptLastAt + CHECKPOINT_PLAY_MS + 10;
      return takeCheckpoint();
    });
  }
  // The browser dies: every process on this profile, SIGKILL, no page event.
  async kill() {
    const pids = execSync("ps -axo pid=,command=").toString().split("\n")
      .filter((l) => l.includes(this.dir) && !l.includes("ps -axo"))
      .map((l) => Number(l.trim().split(/\s+/)[0])).filter((p) => p && p !== process.pid);
    assert.ok(pids.length > 0, "found the browser's processes to kill");
    for (const p of pids) { try { process.kill(p, "SIGKILL"); } catch {} }
    await sleep(2000);
    await this.ctx.close().catch(() => {});
  }
  // Launched again, and the game's tile tapped: where does it come back?
  async reopen() {
    await this.open();
    const crashes = await this.page.evaluate((g) => crashStreak(g), GAME);
    await this.page.locator(".home-tile-launch").first().click();
    await this.running();
    await sleep(300);
    return { crashes, c: await this.counter() };
  }
  async end() {
    await this.ctx?.close().catch(() => {});
    await rm(this.dir, { recursive: true, force: true });
  }
}

for (const engine of ENGINES) {
  describe(`crash recovery (${engine})`, { skip }, () => {
    const scenario = (name, body) => test(name, async () => {
      const p = new Player(engine);
      try { await p.start(); await body(p); } finally { await p.end(); }
    });

    // The report that started it: a long session, no recent in-game save,
    // the browser crashed, and the relaunch went back to the last hide.
    scenario("a crash while playing resumes at the last checkpoint", async (p) => {
      await p.save(10); await sleep(1500);   // saved in game at 10
      await p.play(40);
      await p.checkpoint();                  // the minute's checkpoint, at 50
      await p.play(30);                      // 80 when the browser dies
      await p.kill();
      const got = await p.reopen();
      assert.equal(got.c, 50);
      assert.equal(got.crashes, 1, "counted, and one crash asks nothing");
    });

    scenario("a crash 1.5 s after an in-game save keeps that save", async (p) => {
      await p.save(10); await sleep(1500);
      await p.save(15);                      // 25 saved in game
      await sleep(1500);                     // stored once the file settles
      await p.kill();
      assert.equal((await p.reopen()).c, 25);
    });

    scenario("a crash after an in-game save with no checkpoint since boots on that save", async (p) => {
      await p.save(10); await sleep(1500);
      await p.checkpoint();                  // at 10, before the save below
      await p.save(20); await sleep(1500);   // 30 saved and stored
      await p.play(10);
      await p.kill();
      assert.equal((await p.reopen()).c, 30, "never the checkpoint from before the save");
    });

    scenario("a checkpoint after an in-game save carries that save", async (p) => {
      await p.save(30);                      // saved, not yet stored ...
      await p.checkpoint();                  // ... the checkpoint stores it
      await p.play(25);
      await p.kill();
      assert.equal((await p.reopen()).c, 30);
    });

    scenario("a crash while a checkpoint packs leaves the one before it whole", async (p) => {
      await p.save(10); await sleep(1500);
      await p.play(20);
      await p.checkpoint();                  // 30, landed
      await p.play(20);                      // 50
      await p.page.evaluate(() => {
        runPlayMs = ckptLastAt + CHECKPOINT_PLAY_MS + 10;
        takeCheckpoint();                    // not waited for
      });
      await p.kill();
      const got = await p.reopen();
      assert.ok(got.c === 30 || got.c === 50, "c=" + got.c);
    });

    scenario("a crash on the home screen after Main Menu resumes there, and is no crash", async (p) => {
      await p.save(10); await sleep(1500);
      await p.play(33);
      await p.page.click("#menu-btn");
      await p.page.click("#main-menu");
      await p.page.waitForFunction(() => document.body.classList.contains("paused"));
      await sleep(500);
      await p.kill();
      const got = await p.reopen();
      assert.equal(got.c, 43);
      assert.equal(got.crashes, 0);
    });

    scenario("a game never saved in resumes at its checkpoint", async (p) => {
      await p.play(20);
      await p.checkpoint();
      await p.play(10);
      await p.kill();
      assert.equal((await p.reopen()).c, 20);
    });

    scenario("the tab closed mid-game resumes exactly, and is no crash", async (p) => {
      await p.save(10); await sleep(1500);
      await p.play(27);                      // 37
      await p.page.close({ runBeforeUnload: true });
      await sleep(1000);
      await p.ctx.close();
      const got = await p.reopen();
      assert.equal(got.c, 37);
      assert.equal(got.crashes, 0);
    });

    // A quitting browser runs the close handlers but lands none of their
    // IndexedDB writes. Chromium proper - Chrome, or DINGBAT_E2E_CHROMIUM_
    // CHANNEL=chromium as on CI's macOS runner - keeps their localStorage
    // (the last gasp) and resumes exactly; WebKit, and Playwright's headless
    // shell, do not, and fall back to the checkpoint.
    const exactQuit = engine === "chromium" && !!channel;
    scenario("the browser quit mid-game is no crash, and resumes " +
             (exactQuit ? "exactly" : "no earlier than the checkpoint"), async (p) => {
      await p.save(10); await sleep(1500);
      await p.play(10);
      await p.checkpoint();                  // 20
      await p.play(17);                      // 37
      await sleep(300);
      await p.ctx.close();
      const got = await p.reopen();
      if (exactQuit) assert.equal(got.c, 37);
      else assert.ok(got.c === 20 || got.c === 37, "c=" + got.c);
      // The headless shell keeps nothing a closing page writes: its close is
      // a kill, counted once (one crash asks nothing).
      assert.ok(got.crashes <= (engine === "chromium" && !channel ? 1 : 0), "crashes " + got.crashes);
    });

    scenario("two kills in a row, right after resuming, ask first; an earlier moment resumes", async (p) => {
      await p.save(10); await sleep(1500);
      await p.play(20);
      await p.checkpoint();                  // 30
      await p.play(20);
      await p.checkpoint();                  // 50
      await p.kill();
      const first = await p.reopen();        // resumes 50 (and one frame of A: 51)
      assert.equal(first.c, 50);
      await p.kill();
      await p.open();
      assert.equal(await p.page.evaluate((g) => crashStreak(g), GAME), 2);
      await p.page.locator(".home-tile-launch").first().click();
      await p.page.waitForFunction(() =>
        document.getElementById("moments-modal").classList.contains("open"), null, { timeout: 10000 });
      assert.equal(await p.page.evaluate(() => !!currentRomName), false, "nothing resumed yet");
      await p.page.waitForFunction(() =>
        document.querySelectorAll("#moments-grid .state-slot").length >= 2);
      await p.page.locator("#moments-grid .state-slot").last().click();
      await p.page.click("#moments-resume");
      await p.running();
      await sleep(300);
      assert.equal(await p.counter(), 30, "the earlier moment");
    });
  });
}
