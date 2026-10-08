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

// On CI it has a runner to itself (test.yml's "crash recovery" shard). It
// flaked there beside the other e2e files, every run differently, until
// (1) a relaunch waited for the last browser on its profile to be gone (a
// WebKit network process still holding the storage left the next launch
// an empty or stale one), (2) a kill took the browser's whole tree, and
// (3) each "stored" was waited for rather than slept on.
const skip = !builtWeb() ? "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)" : false;
const ENGINES = process.env.DINGBAT_E2E_NO_CHROMIUM ? ["webkit"] : ["chromium", "webkit"];
const channel = process.env.DINGBAT_E2E_CHROMIUM_CHANNEL;
const launchOpts = (engine) => ({
  headless: true, viewport: { width: 1000, height: 800 },
  ...(engine === "chromium" && channel ? { channel } : {}),
});

let web = null;
const site = async () => (web ??= await serveWeb());

// Polled, not slept on: a fixed sleep long enough for a loaded CI runner is
// a waste everywhere else, and one that is not is a flake.
const until = async (cond, what, ms) => {
  const end = Date.now() + ms;
  for (;;) {
    if (await cond()) return;
    if (Date.now() > end) assert.fail("timed out waiting for " + (typeof what === "function" ? what() : what));
    await sleep(100);
  }
};
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
    // The last browser on this profile all gone first: a process of it still
    // holding the storage (WebKit's network process outlives its browser by
    // a while, on Linux after a SIGKILL of the rest, on a Mac after a close)
    // left the next launch an empty or stale IndexedDB - the CI flakes.
    await this.released();
    this.ctx = await playwright[this.engine].launchPersistentContext(this.dir, launchOpts(this.engine));
    await this.visit(this.ctx.pages()[0] || await this.ctx.newPage());
  }
  // The app opened in `page`, a tab of the running browser.
  async visit(page) {
    this.page = page;
    this.loads = 0; // launches on this page (running)
    // DINGBAT_E2E_SLOW=4: Chromium on a quarter of the CPU, as devices.mjs.
    const slow = Number(process.env.DINGBAT_E2E_SLOW || 0);
    if (slow > 1 && this.engine === "chromium") {
      await (await this.ctx.newCDPSession(this.page)).send("Emulation.setCPUThrottlingRate", { rate: slow });
    }
    await this.page.goto((await site()).url);
    await this.page.waitForFunction(() => typeof Module !== "undefined" && runtimeReady &&
      typeof db !== "undefined" && !!db, null, { timeout: 60000 });
    // The one-time offer to picture the library would open over the tile.
    await this.page.evaluate(() => dbPut(THUMBS_OFFER_KEY, Date.now()));
    await sleep(500);
  }
  // On screen and running, and the load finished: loadRom ends by running
  // 60 frames of benchmark (benchReport) inside the core, which go past the
  // counted frames below with whatever is held - so nothing is held until
  // this page's log says it has run once per launch.
  async running() {
    this.loads = (this.loads || 0) + 1;
    await this.page.waitForFunction((loads) => document.body.classList.contains("running") &&
      !document.body.classList.contains("home-flying") && !paused &&
      [...document.querySelectorAll("#log-entries p")]
        .filter((p) => p.textContent.includes("bench (load)")).length >= loads,
      this.loads, { timeout: 30000 });
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
  // The battery stored: IndexedDB's copy is the file the core wrote. The
  // page stores it once the file has held still for a look (watchBattery),
  // about a second after the game's last write - waited for, not slept on.
  async stored() {
    await until(() => this.page.evaluate(async () => {
      let file;
      try { file = FS.readFile(currentRomName.replace(/\.[^.]+$/, "") + ".sav"); } catch { return false; }
      const kept = await dbGet("save:" + currentOriginalName);
      return !!kept && kept.length === file.length && kept.every((b, i) => b === file[i]);
    }), "the battery stored", 10000);
  }
  // The processes using this profile: started with it, theirs, and any
  // holding a file in it (on a Mac, WebKit's network process is none of
  // the first two).
  procs() {
    const table = execSync("ps -axo pid=,ppid=,stat=,command=").toString().split("\n")
      .map((l) => l.trim().match(/^(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/)).filter(Boolean)
      .map(([, pid, ppid, stat, cmd]) => ({ pid: +pid, ppid: +ppid, stat, cmd }))
      .filter((p) => !p.stat.startsWith("Z"));
    const ours = new Set(table.filter((p) => p.cmd.includes(this.dir) && !p.cmd.includes("ps -axo"))
      .map((p) => p.pid));
    let holders = "";
    try { holders = execSync(`lsof -t +D ${JSON.stringify(this.dir)}`, { stdio: ["ignore", "pipe", "ignore"] }).toString(); }
    catch (e) { holders = e.stdout?.toString() || ""; } // exit 1: none
    for (const p of holders.split(/\s+/)) if (+p) ours.add(+p);
    for (let grew = true; grew;) {
      grew = false;
      for (const p of table) if (ours.has(p.ppid) && !ours.has(p.pid)) { ours.add(p.pid); grew = true; }
    }
    ours.delete(process.pid);
    const alive = new Set(table.map((p) => p.pid));
    return table.filter((p) => ours.has(p.pid) && alive.has(p.pid));
  }
  async released() {
    if (!this.dir) return;
    await until(() => this.procs().length === 0,
      () => "the last browser on the profile gone: " +
        JSON.stringify(this.procs().map((p) => p.cmd.slice(0, 80))), 30000);
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
    // What a crash count is made from, for a count that comes out wrong.
    this.diag = { beforeKill: await this.page.evaluate(async () => ({
      hidden: document.hidden, marked: playingMarked, playing: await dbGet("playing"),
    })).catch((e) => String(e)) };
    // Its whole tree: Linux WebKit's network process (which holds the
    // storage) is a child of the browser without the profile in its command
    // line, and outlived a kill of only the processes that had it.
    const procs = this.procs();
    this.diag.killed = procs.map((p) => p.cmd.split(/\s+/)[0].split("/").pop());
    assert.ok(procs.length > 0, "found the browser's processes to kill");
    for (const p of procs) { try { process.kill(p.pid, "SIGKILL"); } catch {} }
    await this.released();
    await this.ctx.close().catch(() => {});
  }
  // Launched again, and the game's tile tapped: where does it come back?
  // { tab: true }: in a new tab of the browser still running, not a
  // relaunch.
  async reopen({ tab = false } = {}) {
    if (tab) await this.visit(await this.ctx.newPage());
    else await this.open();
    const crashes = await this.page.evaluate((g) => crashStreak(g), GAME);
    if (this.diag) {
      this.diag.boot = await this.page.evaluate(async () => ({
        crashes: await dbGet("crashes"), playing: await dbGet("playing"),
        log: [...document.querySelectorAll("#log-entries p")].map((p) => p.textContent)
          .filter((t) => /unexpectedly|took in|checkpoint/.test(t)),
      })).catch((e) => String(e));
    }
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
    // A kill counted as a crash, with what the count was made from when it
    // is wrong. (On CI's Linux WebKit it came out one short now and then
    // while a kill left the network process running; see kill().)
    const expectCrashes = (p, got, want) => {
      if (got !== want) assert.fail(`crash count ${got}, wanted ${want}: ${JSON.stringify(p.diag)}`);
    };

    // The report that started it: a long session, no recent in-game save,
    // the browser crashed, and the relaunch went back to the last hide.
    scenario("a crash while playing resumes at the last checkpoint", async (p) => {
      await p.save(10); await p.stored();     // saved in game at 10
      await p.play(40);
      await p.checkpoint();                  // the minute's checkpoint, at 50
      await p.play(30);                      // 80 when the browser dies
      await p.kill();
      const got = await p.reopen();
      assert.equal(got.c, 50);
      expectCrashes(p, got.crashes, 1); // counted, and one crash asks nothing
    });

    scenario("a crash soon after an in-game save keeps that save", async (p) => {
      await p.save(10); await p.stored();
      await p.save(15);                      // 25 saved in game
      await p.stored();                      // stored once the file settles
      await p.kill();
      assert.equal((await p.reopen()).c, 25);
    });

    scenario("a crash after an in-game save with no checkpoint since boots on that save", async (p) => {
      await p.save(10); await p.stored();
      await p.checkpoint();                  // at 10, before the save below
      await p.save(20); await p.stored();     // 30 saved and stored
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
      await p.save(10); await p.stored();
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
      await p.save(10); await p.stored();
      await p.play(33);
      await p.page.click("#menu-btn");
      await p.page.click("#main-menu");
      await p.page.waitForFunction(() => document.body.classList.contains("paused"));
      await until(() => p.page.evaluate(async () => !unstoredSnap && !playingMarked &&
        !(pageId in ((await dbGet("playing")) || {}))), "the session and the run's end stored", 10000);
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
      await p.save(10); await p.stored();
      await p.play(27);                      // 37
      // The browser stays up: another tab keeps it (closing a context's
      // last tab quits the browser, and WebKit lands a quitting browser's
      // IndexedDB writes only now and then - the quit scenario below). The
      // game is then opened in a new tab, whose reads IndexedDB orders after
      // the closed tab's writes: nothing to wait out.
      const keeper = await p.ctx.newPage();
      await Promise.all([p.page.waitForEvent("close"), p.page.close({ runBeforeUnload: true })]);
      const got = await p.reopen({ tab: true });
      await keeper.close();
      assert.equal(got.c, 37);
      // Full Chromium on CI's Mac has handed the new tab the closed one's
      // mark before its clean-exit note (1, once): counted once, and one
      // crash asks nothing - as the quit below.
      assert.ok(got.crashes <= (engine === "chromium" ? 1 : 0), "crashes " + got.crashes);
    });

    // A quitting browser runs the close handlers but lands none of their
    // IndexedDB writes. Google Chrome (DINGBAT_E2E_CHROMIUM_CHANNEL=chrome)
    // keeps their localStorage - the last gasp - and resumes exactly; so
    // does full Chromium on a quiet machine, but not on CI's runner beside
    // the other e2e files, where Playwright's close does not wait for it.
    // WebKit and the headless shell fall back to the checkpoint.
    const exactQuit = engine === "chromium" && channel === "chrome";
    scenario("the browser quit mid-game is no crash, and resumes " +
             (exactQuit ? "exactly" : "no earlier than the checkpoint"), async (p) => {
      await p.save(10); await p.stored();
      await p.play(10);
      await p.checkpoint();                  // 20
      await p.play(17);                      // 37
      await sleep(300);
      await p.ctx.close();
      const got = await p.reopen();
      if (exactQuit) assert.equal(got.c, 37);
      else assert.ok(got.c === 20 || got.c === 37, "c=" + got.c);
      // Where the clean-exit note does not land (the headless shell; WebKit
      // or Chromium on a loaded machine), the quit counts once - and one
      // crash asks nothing: the tile above resumed without the sheet.
      assert.ok(got.crashes <= (exactQuit ? 0 : 1), "crashes " + got.crashes);
    });

    scenario("two kills in a row, right after resuming, ask first; an earlier moment resumes", async (p) => {
      await p.save(10); await p.stored();
      await p.play(20);
      await p.checkpoint();                  // 30
      await p.play(20);
      await p.checkpoint();                  // 50
      await p.kill();
      const first = await p.reopen();        // resumes 50 (and one frame of A: 51)
      assert.equal(first.c, 50);
      await p.kill();
      await p.open();
      const streak = await p.page.evaluate((g) => crashStreak(g), GAME);
      expectCrashes(p, streak, 2);
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
