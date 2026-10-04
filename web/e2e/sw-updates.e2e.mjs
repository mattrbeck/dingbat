// The checkpoint worker (ckptworker.js) across app updates: a copy of web/
// served with a production sw.js (a real CACHE_VERSION, so cache-first, as
// deployed), its index.js and worker each carrying a build letter, so every
// step checks that the page and its worker are one build, and the one
// expected - a deploy applied mid-game, one left waiting, one applied while
// a checkpoint packs, Force update, no network, and a sw.js from before the
// worker existed.
//
//   node --test e2e/sw-updates.e2e.mjs            # from web/, after the wasm build
//
// Chromium and WebKit, as the other e2e files choose them.

import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { cp, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";
import { createRequire } from "node:module";
import { builtWeb, sleep, WEB } from "./devices.mjs";
import { synctestRom, SYNCTEST_NAME as GAME } from "./synctest-rom.mjs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");
// Not on CI unless asked (DINGBAT_E2E_CRASH=1), as crash-recovery.e2e.mjs:
// a step failed once in three runs on CI's Linux WebKit; steady locally.
const skip = !builtWeb() ? "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)"
  : process.env.CI && !process.env.DINGBAT_E2E_CRASH
    ? "flaky on CI's runners (DINGBAT_E2E_CRASH=1 runs it)" : false;
const ENGINES = process.env.DINGBAT_E2E_NO_CHROMIUM ? ["webkit"] : ["chromium", "webkit"];
const channel = process.env.DINGBAT_E2E_CHROMIUM_CHANNEL;

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".wasm": "application/wasm", ".json": "application/json",
  ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon",
  ".webmanifest": "application/manifest+json", ".txt": "text/plain" };

// The copied site, with a switch that drops every request: no network.
// (Playwright's setOffline breaks WebKit's service-worker navigations.)
const serveSite = (dir) => new Promise((resolve) => {
  let down = false;
  const server = createServer(async (req, res) => {
    if (down) { req.socket.destroy(); return; }
    let path = decodeURIComponent(new URL(req.url, "http://x").pathname);
    if (path.endsWith("/")) path += "index.html";
    const file = normalize(join(dir, path));
    if (!file.startsWith(normalize(dir))) { res.writeHead(403).end(); return; }
    try {
      if (!(await stat(file)).isFile()) throw 0;
      res.writeHead(200, { "Content-Type": TYPES[extname(file)] || "application/octet-stream",
                           "Cache-Control": "no-store" });
      res.end(await readFile(file));
    } catch { res.writeHead(404).end(); }
  });
  server.listen(0, "127.0.0.1", () => resolve({
    url: `http://127.0.0.1:${server.address().port}/`,
    offline: (v) => { down = v; },
    close: () => { server.closeAllConnections?.(); server.close(); },
  }));
});

for (const engine of ENGINES) {
  describe(`checkpoint worker across updates (${engine})`, { skip }, () => {
    let dir, site, browser, ctx, page;
    // A build: sw.js version, the letter index.js and the worker carry, and
    // whether this sw.js lists the worker.
    const setBuild = async (version, letter, { listsWorker = true } = {}) => {
      let sw = (await readFile(join(WEB, "sw.js"), "utf8"))
        .replace('const CACHE_VERSION = "dev";', `const CACHE_VERSION = "${version}";`);
      if (!listsWorker) sw = sw.replace('  "./ckptworker.js",\n', "");
      await writeFile(join(dir, "sw.js"), sw);
      await writeFile(join(dir, "version.txt"), version + "\n");
      await writeFile(join(dir, "index.js"),
        (await readFile(join(WEB, "index.js"), "utf8")) + `\nvar __build = "${letter}";\n`);
      await writeFile(join(dir, "ckptworker.js"), (await readFile(join(WEB, "ckptworker.js"), "utf8")) +
        `\nself.addEventListener("message", (e) => { if (e.data?.ping) self.postMessage({ pong: "${letter}" }); });\n`);
    };
    const booted = () => page.waitForFunction(
      () => typeof Module !== "undefined" && runtimeReady, null, { timeout: 60000 });
    // Which build the page is, and which its checkpoint worker is.
    const builds = () => page.evaluate(async () => {
      const w = getCkptWorker();
      const pong = !w ? "none" : await new Promise((resolve) => {
        const on = (e) => { if (e.data?.pong) { w.removeEventListener("message", on); resolve(e.data.pong); } };
        w.addEventListener("message", on);
        w.postMessage({ ping: 1 });
        setTimeout(() => resolve("no answer"), 5000);
      });
      return { page: typeof __build === "undefined" ? "?" : __build, worker: pong,
               controlled: !!navigator.serviceWorker.controller };
    });
    const expectBuild = async (want, why) => {
      const b = await builds();
      assert.deepEqual({ page: b.page, worker: b.worker }, { page: want, worker: want },
                       why + ": " + JSON.stringify(b));
      return b;
    };
    const playGame = async () => {
      if (await page.evaluate(() => !!currentRomName)) {
        if (await page.evaluate(() => paused)) await page.evaluate(() => resumeGame());
      } else if (await page.locator(".home-tile-launch").count()) {
        await page.locator(".home-tile-launch").first().click();
      } else {
        const [ch] = await Promise.all([page.waitForEvent("filechooser"),
          page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click()]);
        await ch.setFiles({ name: GAME, mimeType: "application/octet-stream", buffer: Buffer.from(synctestRom()) });
      }
      await page.waitForFunction(() => document.body.classList.contains("running") &&
        !document.body.classList.contains("home-flying") && !paused, null, { timeout: 30000 });
      await sleep(500);
    };
    // A deploy reaches the browser: the new sw.js installs and waits.
    const deploy = async (version, letter, o) => {
      await setBuild(version, letter, o);
      await page.evaluate(() => swRegistration.update());
      await page.waitForFunction(() => !!swRegistration.waiting, null, { timeout: 60000 });
    };
    const reloadedBy = async (fn) => {
      await Promise.all([page.waitForEvent("load", { timeout: 60000 }), page.evaluate(fn)]);
      await booted();
      await sleep(500);
    };
    const takeCheckpoint = () => page.evaluate(async () => {
      const before = (await dbGet(ckptIndexKey(currentOriginalName)))?.list.length || 0;
      runPlayMs = ckptLastAt + CHECKPOINT_PLAY_MS + 10;
      await takeCheckpoint();
      const idx = await dbGet(ckptIndexKey(currentOriginalName));
      const a = await dbGet(autoStateKey(currentOriginalName));
      return { kept: (idx?.list.length || 0) - before || (idx?.list.length ? 1 : 0),
               packed: !!a && isPackedState(a.bytes), worker: ckptWorker ? "up" : "none" };
    });

    before(async () => {
      if (skip) return;
      dir = await mkdtemp(join(tmpdir(), "dingbat-sw-"));
      await cp(WEB, dir, { recursive: true, filter: (p) =>
        !/[/\\](node_modules|tests|e2e)([/\\]|$)/.test(p.slice(WEB.length - 1)) });
      await setBuild("v1", "A");
      site = await serveSite(dir);
      browser = await playwright[engine].launch({
        headless: true, ...(engine === "chromium" && channel ? { channel } : {}) });
      ctx = await browser.newContext({ viewport: { width: 1000, height: 800 } });
      page = await ctx.newPage();
      await page.goto(site.url);
      await booted();
      await page.evaluate(() => dbPut(THUMBS_OFFER_KEY, Date.now()));
    });
    after(async () => {
      await browser?.close();
      site?.close();
      if (dir) await rm(dir, { recursive: true, force: true });
    });

    test("first visit, then from the service worker's cache: one build", async () => {
      await expectBuild("A", "first visit");
      await page.waitForFunction(() => !!navigator.serviceWorker.controller, null, { timeout: 30000 });
      await page.reload(); await booted();
      const b = await expectBuild("A", "controlled");
      assert.ok(b.controlled);
    });

    test("a deploy applied mid-game: page and worker both the new build", async () => {
      await playGame();
      await deploy("v2", "B");
      await reloadedBy(() => { applyUpdate(); });
      await expectBuild("B", "after the update");
    });

    test("a deploy left waiting keeps the running build, page and worker together", async () => {
      await deploy("v3", "C");
      await page.reload(); await booted();
      await expectBuild("B", "reloaded, update not applied");
      await reloadedBy(() => { applyUpdate(); });
      await expectBuild("C", "then applied");
    });

    test("a deploy applied while a checkpoint packs: new build, the session whole", async () => {
      await playGame();
      await page.evaluate(() => getCkptWorker());
      await deploy("v4", "D");
      await reloadedBy(() => {
        runPlayMs = ckptLastAt + CHECKPOINT_PLAY_MS + 10;
        takeCheckpoint();
        applyUpdate();
      });
      await expectBuild("D", "after the update");
      assert.ok(await page.evaluate(async (g) => {
        const a = await dbGet(autoStateKey(g));
        return !!a && looksLikeStateFile(a.bytes) && isPackedState(a.bytes);
      }, GAME), "the stored session is a whole packed state");
      await playGame();
    });

    test("Force update mid-game takes the changed files, worker included", async () => {
      await setBuild("v4", "E"); // the files change; sw.js does not
      await page.reload(); await booted();
      await expectBuild("D", "plain reload: still cached");
      await playGame();
      await reloadedBy(() => { forceUpdate(); });
      await expectBuild("E", "after Force update");
    });

    test("with no network the worker comes from the cache, and packs", async () => {
      site.offline(true);
      try {
        await page.goto(site.url); await booted(); // the app as launched: its bare URL
        await expectBuild("E", "offline");
        await playGame();
        const r = await takeCheckpoint();
        assert.equal(r.worker, "up");
        assert.ok(r.kept >= 1 && r.packed, JSON.stringify(r));
      } finally { site.offline(false); }
    });

    test("a sw.js that does not list the worker: network when online, the page when not", async () => {
      await deploy("v5", "F", { listsWorker: false });
      await reloadedBy(() => { applyUpdate(); });
      await expectBuild("F", "online");
      site.offline(true);
      try {
        await page.goto(site.url); await booted();
        await playGame();
        // The worker fails to load; the checkpoint after that runs on the page.
        await takeCheckpoint();
        await sleep(500);
        const r = await takeCheckpoint();
        assert.equal(r.worker, "none");
        assert.ok(r.kept >= 1 && r.packed, JSON.stringify(r));
      } finally { site.offline(false); }
    });
  });
}
