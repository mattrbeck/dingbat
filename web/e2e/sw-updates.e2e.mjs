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
import { fileFor, sha256, swAssets, writeManifest } from "../../.github/scripts/asset-manifest.mjs";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");
// Not on CI unless asked (DINGBAT_E2E_UPDATES=1). On its own shard there
// it still failed one run in two: after the "no network" test, Linux
// WebKit's next update() never settled (an install hung, not failed), and
// on the Mac a deploy while a checkpoint packs never reloaded the page.
// Steady locally, Chromium and WebKit.
const skip = !builtWeb() ? "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)"
  : process.env.CI && !process.env.DINGBAT_E2E_UPDATES
    ? "flaky on CI's runners (DINGBAT_E2E_UPDATES=1 runs it)" : false;
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
      writeManifest(dir); // as deploy-pages.yml, after every stamp
    };
    // Up, and its service worker registration in hand: an applyUpdate before
    // register() resolves finds none and takes the clean-slate path.
    const booted = () => page.waitForFunction(
      () => typeof Module !== "undefined" && runtimeReady &&
        (!("serviceWorker" in navigator) || !!swRegistration), null, { timeout: 60000 });
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
      // Asked until the new worker waits: right after the site comes back
      // from "offline" (its sockets dropped), WebKit's update() has
      // rejected with "TypeError: Internal error" (CI). What each ask came
      // to is kept for a deploy that never lands.
      await page.evaluate(() => { window.__updates = []; });
      try {
        await page.waitForFunction(() => {
          const reg = swRegistration;
          if (!reg.waiting && !reg.installing) {
            reg.update().then(() => {
              const w = reg.installing;
              window.__updates.push("asked: " + (w ? "installing" : reg.waiting ? "waiting" : "nothing new"));
              w?.addEventListener("statechange", () => window.__updates.push("worker " + w.state));
            }, (e) => window.__updates.push("rejected: " + e));
          }
          return !!reg.waiting;
        }, null, { timeout: 60000, polling: 1000 });
      } catch (e) {
        const seen = await page.evaluate(() => [...new Set(window.__updates)]).catch(() => []);
        throw new Error(`build ${letter} never waited: ${JSON.stringify(seen)}`);
      }
    };
    // Back from "offline" as a player is: the app opened again. A page left
    // as it was had WebKit's later updates fail (CI, Linux).
    const online = async () => {
      site.offline(false);
      await page.goto(site.url).catch(() => {});
      await booted().catch(() => {});
    };
    // The page `fn` reloads, booted: told apart from this one by a mark only
    // this one carries. Waiting for the next "load" event instead took a
    // late one of the reload before (CI: "then applied" still on build B).
    const reloadedBy = async (fn) => {
      await page.evaluate(() => { window.__beforeReload = true; });
      await page.evaluate(fn);
      await page.waitForFunction(() => !window.__beforeReload && typeof Module !== "undefined" &&
        runtimeReady, null, { timeout: 60000 });
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
      } finally { await online(); }
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
      } finally { await online(); }
    });
  });
}

// --- What the worker downloads ------------------------------------------
// Its install takes each asset from the first copy whose bytes hash to the
// deployed manifest (sw.js, collect): a dingbat-* cache, the HTTP cache,
// then the network. These count every request the site answers, the page's
// and the worker's, through a server that sends a ten-minute max-age as
// Pages does (so the HTTP cache is in play, as on dingbat.gg), and stage
// builds the way deploy-pages.yml does: this checkout's web/, and an older
// build (DINGBAT_E2E_OLD_REF, default origin/main) whose sw.js and index.js
// may predate the manifest.

const OLD_REF = process.env.DINGBAT_E2E_OLD_REF || "origin/main";
const REPO = join(WEB, "..");
const NEW_ASSETS = builtWeb() ? swAssets(readFileSync(join(WEB, "sw.js"), "utf8")) : [];

// The site with a request log and a way to hold one request back (a deploy
// landing while the worker downloads).
const serveCounted = (dir) => new Promise((resolve) => {
  const log = [];
  const holds = [];
  let down = false;
  const server = createServer(async (req, res) => {
    if (down) { req.socket.destroy(); return; }
    const url = new URL(req.url, "http://x");
    for (const h of holds) {
      if (!h.done && h.re.test(url.pathname + url.search)) { h.hit(); await h.gate; }
    }
    let path = decodeURIComponent(url.pathname);
    if (path.endsWith("/")) path += "index.html";
    const file = normalize(join(dir, path));
    if (!file.startsWith(normalize(dir))) { res.writeHead(403).end(); return; }
    try {
      if (!(await stat(file)).isFile()) throw 0;
      const body = await readFile(file);
      log.push({ path: url.pathname, query: url.search, bytes: body.length });
      res.writeHead(200, { "Content-Type": TYPES[extname(file)] || "application/octet-stream",
                           "Cache-Control": "max-age=600" });
      res.end(body);
    } catch {
      log.push({ path: url.pathname, query: url.search, bytes: 0, missing: true });
      res.writeHead(404).end();
    }
  });
  server.listen(0, "127.0.0.1", () => resolve({
    url: `http://127.0.0.1:${server.address().port}/`,
    log,
    offline: (v) => { down = v; },
    // Holds the first request matching `re` until release(); `seen` once it arrives.
    hold: (re) => {
      let hit, open;
      const h = { re, done: false, seen: new Promise((r) => { hit = r; }),
                  gate: new Promise((r) => { open = r; }) };
      h.hit = () => { h.done = true; hit(); };
      h.release = () => open();
      holds.push(h);
      return h;
    },
    close: () => { server.closeAllConnections?.(); server.close(); },
  }));
});

// `src` (a web/ directory) staged into `dir` as a deploy: sw.js and
// version.txt stamped with `version`, index.js marked with `letter`, and the
// manifest: this checkout's (`manifest` true), an older build's own script's
// (a path to it), or none (false: a build from before it). `tamper` rewrites
// files after the manifest, as a stale edge serving another object would.
const stage = async (src, dir, version, letter, { manifest = true, tamper = null } = {}) => {
  await cp(src, dir, { recursive: true, force: true, filter: (p) =>
    !/[/\\](node_modules|tests|e2e|bench|types|signaling)([/\\]|$)/.test(p.slice(src.length - 1)) });
  // The cores are not in git.
  for (const f of ["em.js", "em.wasm", "nds/nds.js", "nds/nds.wasm"]) {
    if (existsSync(join(WEB, f))) await cp(join(WEB, f), join(dir, f));
  }
  const sw = (await readFile(join(src, "sw.js"), "utf8"))
    .replace('const CACHE_VERSION = "dev";', `const CACHE_VERSION = "${version}";`);
  await writeFile(join(dir, "sw.js"), sw);
  await writeFile(join(dir, "version.txt"), version);
  await writeFile(join(dir, "index.js"),
    (await readFile(join(src, "index.js"), "utf8")) + `\nvar __build = "${letter}";\n`);
  await rm(join(dir, "asset-manifest.json"), { force: true });
  if (manifest === true) writeManifest(dir);
  else if (manifest) execFileSync(process.execPath, [manifest, dir], { stdio: "pipe" });
  if (tamper) await tamper(dir);
};

// An older build's web/ and its manifest script (null when it predates
// one), out of the repository.
const oldWeb = async () => {
  const out = await mkdtemp(join(tmpdir(), "dingbat-old-"));
  const tar = execFileSync("git", ["-C", REPO, "archive", OLD_REF, "web", ".github/scripts"],
    { maxBuffer: 1 << 30 });
  execFileSync("tar", ["-x", "-C", out], { input: tar });
  // Its real path: the script runs only when argv[1] is its own URL's path,
  // and the Mac's temp dir is a symlink (/var -> /private/var).
  const script = join(realpathSync(out), ".github/scripts/asset-manifest.mjs");
  return { web: join(out, "web"), script: existsSync(script) ? script : false, root: out };
};
const oldStage = (old, dir, version, letter) =>
  stage(old.web, dir, version, letter, { manifest: old.script });

// Bare path -> how many times the site sent it.
const tally = (entries) => {
  const t = {};
  for (const e of entries) t[e.path] = (t[e.path] || 0) + 1;
  return t;
};
// The asset downloads in a slice of the log: everything but the update
// check's and the install's small probes (sw.js, version.txt, the manifest).
const PROBES = new Set(["/sw.js", "/version.txt", "/asset-manifest.json"]);
const assetGets = (site, from = 0) => site.log.slice(from).filter((e) => !PROBES.has(e.path));
const assetPath = (u) => (u === "./" ? "/" : u.slice(1));
const digestsOf = (dir) => Object.fromEntries(swAssets(readFileSync(join(dir, "sw.js"), "utf8"))
  .map((u) => [u, sha256(readFileSync(join(dir, fileFor(u))))]));

for (const engine of ENGINES) {
  describe(`what the service worker downloads (${engine})`, { skip }, () => {
    let browser, site, dir, oldSrc;

    const open = async () => {
      const ctx = await browser.newContext({ viewport: { width: 1000, height: 800 } });
      return { ctx, page: await ctx.newPage() };
    };
    const booted = (page) => page.waitForFunction(
      () => typeof Module !== "undefined" && runtimeReady && !!swRegistration, null, { timeout: 60000 });
    const installedFresh = async (page) => {
      await booted(page);
      await page.waitForFunction(() => !!navigator.serviceWorker.controller &&
        swRegistration.active?.state === "activated", null, { timeout: 60000 });
    };
    const letter = (page) => page.evaluate(() => typeof __build === "undefined" ? "?" : __build);
    // The asset caches (sw.js's pointer, dingbat-live, left out; a worker
    // from before it has none), and the live one as the pointer names it.
    const cacheKeys = (page) => page.evaluate(async () =>
      (await caches.keys()).filter((k) => k !== "dingbat-live").sort());
    const livePointer = (page) => page.evaluate(async () => {
      const p = await caches.open("dingbat-live");
      const keys = await p.keys();
      return Object.fromEntries(await Promise.all(keys.map(async (r) =>
        [new URL(r.url).pathname.split("/").pop(), await (await p.match(r)).text()])));
    });
    // A Force update's cache becomes the only one once its grace is over.
    const onlyCache = (page, re) => page.waitForFunction(async (src) => {
      const k = (await caches.keys()).filter((x) => x !== "dingbat-live");
      return k.length === 1 && new RegExp(src).test(k[0]);
    }, re.source, { timeout: 30000, polling: 500 });
    // What the cache `name` holds of the DS core.
    const ndsHeld = (page, name) => page.evaluate(async (n) => {
      const c = await caches.open(n);
      return Promise.all(["nds/nds.js", "nds/nds.wasm"].map(async (u) => !!(await c.match(u))));
    }, name);
    // The DS core as a DS game loads it (index.js loadNdsCore): its script,
    // then the nds.wasm it fetches. Whether it came up.
    const loadDs = (page) => page.evaluate(() => loadNdsCore().then(() => true, () => false));
    // update() until a worker waits.
    const untilWaiting = (page) => page.waitForFunction(() => {
      const reg = swRegistration;
      if (!reg.waiting && !reg.installing) reg.update().catch(() => {});
      return !!reg.waiting;
    }, null, { timeout: 60000, polling: 500 });
    const reloadedBy = async (page, fn) => {
      await page.evaluate(() => { window.__beforeReload = true; });
      await page.evaluate(fn);
      await page.waitForFunction(() => !window.__beforeReload && typeof Module !== "undefined" &&
        runtimeReady, null, { timeout: 60000 });
    };

    before(async () => {
      if (skip) return;
      dir = await mkdtemp(join(tmpdir(), "dingbat-swdl-"));
      oldSrc = await oldWeb();
      site = await serveCounted(dir);
      browser = await playwright[engine].launch({
        headless: true, ...(engine === "chromium" && channel ? { channel } : {}) });
    });
    after(async () => {
      await browser?.close();
      site?.close();
      if (dir) await rm(dir, { recursive: true, force: true });
      if (oldSrc) await rm(oldSrc.root, { recursive: true, force: true });
    });

    test("a first visit downloads each asset once, the worker's install included; " +
         "an index.js-only update downloads index.js alone; a deploy mid-install fails it; " +
         "Force update downloads everything once", async () => {
      await stage(WEB, dir, "n1", "N1");
      const { ctx, page } = await open();
      try {
        const from = site.log.length;
        await page.goto(site.url);
        await installedFresh(page);
        const first = assetGets(site, from);
        const t = tally(first);
        // The page's own loads (bare URLs) and the worker's (under ?v=):
        // each downloads a file at most once.
        const page1 = tally(first.filter((e) => !e.query));
        const worker1 = tally(first.filter((e) => e.query === "?v=n1"));
        for (const [who, c] of [["the page", page1], ["the worker", worker1]]) {
          const twice = Object.entries(c).filter(([, n]) => n > 1);
          assert.deepEqual(twice, [], who + " downloaded more than once: " + JSON.stringify(c));
        }
        assert.ok(!worker1["/"] || !worker1["/index.html"], "index.html came as / and as itself");
        // And the worker takes what the page loaded from the HTTP cache.
        // Chromium shares it between the page and its worker; Playwright's
        // WebKit does not (each context's worker has a cache of its own), so
        // there the page's loads come a second time, as they did everywhere
        // before the manifest.
        if (engine === "chromium") {
          const twice = Object.entries(t).filter(([, n]) => n > 1);
          assert.deepEqual(twice, [], "downloaded more than once: " + JSON.stringify(t));
          assert.ok(!(t["/"] && t["/index.html"]), "index.html came as / and as itself: " + JSON.stringify(t));
        }
        for (const u of NEW_ASSETS) {
          if (u === "./index.html" || u === "./version.txt") continue;
          assert.ok(t[assetPath(u)] >= 1, u + " never downloaded: " + JSON.stringify(t));
        }
        assert.equal(tally(site.log.slice(from))["/asset-manifest.json"], 1);
        console.log(`# ${engine} first visit: ${first.length} asset downloads, ` +
                    `${first.reduce((n, e) => n + e.bytes, 0)} bytes (uncompressed)`);

        // An update that changes index.js and nothing else the app runs.
        const u0 = site.log.length;
        await stage(WEB, dir, "n2", "N2");
        await untilWaiting(page);
        const got = assetGets(site, u0).map((e) => e.path + e.query);
        assert.deepEqual(got, ["/index.js?v=n2"], "an index.js-only update");
        await reloadedBy(page, () => { applyUpdate(); });
        assert.equal(await letter(page), "N2");
        assert.deepEqual(await cacheKeys(page), ["dingbat-n2"]);

        // A deploy lands while the install waits on index.js: n3's install
        // gets n4's bytes for it and fails; n4's then installs.
        const held = site.hold(/^\/index\.js\?v=n3$/);
        await stage(WEB, dir, "n3", "N3");
        await page.evaluate(() => {
          window.__states = [];
          swRegistration.update().then(() => {
            const w = swRegistration.installing;
            w?.addEventListener("statechange", () => window.__states.push(w.state));
          });
        });
        await held.seen;
        await stage(WEB, dir, "n4", "N4");
        held.release();
        await page.waitForFunction(() => window.__states.includes("redundant"), null, { timeout: 30000 });
        assert.equal(await page.evaluate(() => !!swRegistration.waiting), false, "nothing of n3's waits");
        assert.equal(await letter(page), "N2");
        await untilWaiting(page);
        await reloadedBy(page, () => { applyUpdate(); });
        assert.equal(await letter(page), "N4");
        assert.deepEqual(await cacheKeys(page), ["dingbat-n4"]);

        // Force update: the files change under the same sw.js.
        await stage(WEB, dir, "n4", "N5");
        const f0 = site.log.length;
        await reloadedBy(page, () => { forceUpdate(); });
        // What the worker now serves is the new build, and the reloaded page
        // runs it, Chromium included: the worker keeps its copies no-cache
        // (sw.js `asked`), so the page's memory cache does not hand back the
        // index.js it ran before, which the same worker had served it under
        // Pages' max-age=600.
        assert.ok(await page.evaluate(async () =>
          (await (await fetch("index.js")).text()).includes('var __build = "N5"')));
        assert.equal(await letter(page), "N5");
        const fg = assetGets(site, f0).filter((e) => /^\?v=\d+$/.test(e.query));
        const ft = tally(fg);
        assert.deepEqual(Object.entries(ft).filter(([, n]) => n > 1), [], JSON.stringify(ft));
        // Every asset but version.txt (a probe here) and ./ (index.html's bytes).
        assert.equal(fg.length, NEW_ASSETS.length - 2, "every asset downloaded again: " + JSON.stringify(ft));
      } finally {
        await ctx.close();
      }
    });

    test("an old build's page and worker update to the new build, downloading only what changed",
      async () => {
        await oldStage(oldSrc, dir, "o1", "O1");
        const { ctx, page } = await open();
        try {
          await page.goto(site.url);
          await installedFresh(page);
          assert.equal(await letter(page), "O1");
          const before = digestsOf(dir);

          const u0 = site.log.length;
          await stage(WEB, dir, "n10", "N10");
          // The old page's own update check, then its Update button's path.
          await page.evaluate(() => checkForUpdate());
          await page.waitForFunction(() => updateAvailable, null, { timeout: 30000 });
          await untilWaiting(page);
          const now = digestsOf(dir);
          const want = NEW_ASSETS.filter((u) => u !== "./" && u !== "./version.txt" && before[u] !== now[u])
            .map(assetPath).sort();
          const got = assetGets(site, u0).filter((e) => e.query === "?v=n10").map((e) => e.path).sort();
          assert.deepEqual(got, want, "only the files that changed");
          await reloadedBy(page, () => { applyUpdate(); });
          assert.equal(await letter(page), "N10");
          assert.deepEqual(await cacheKeys(page), ["dingbat-n10"]);
          assert.ok(await page.evaluate(() => !!navigator.serviceWorker.controller));
        } finally {
          await ctx.close();
        }
      });

    test("an old page's Force update under its old worker brings the new page in, " +
         "whose own worker then installs from that cache", async () => {
      await oldStage(oldSrc, dir, "o2", "O2");
      const { ctx, page } = await open();
      try {
        await page.goto(site.url);
        await installedFresh(page);
        // The new build deploys; the old worker's Force update (its own
        // version-probed reinstall) puts it into the old worker's cache.
        await stage(WEB, dir, "n11", "N11");
        await reloadedBy(page, () => { forceUpdate(); });
        assert.equal(await letter(page), "N11", "the new page, under the old worker");
        // The new page's registration finds sw.js new: its install reuses
        // the old worker's cache, which holds these very bytes now.
        const u0 = site.log.length;
        await booted(page);
        await untilWaiting(page);
        const got = assetGets(site, u0).filter((e) => e.query === "?v=n11").map((e) => e.path);
        if (engine === "chromium") assert.deepEqual(got, [], "the new worker had every asset already");
        // Playwright's WebKit sometimes runs a second install job of the
        // same sw.js beside the first, and that one has downloaded index.js
        // (never a file the two builds share): bytes, not correctness.
        else assert.ok(got.every((p) => p === "/index.js"), JSON.stringify(got));
        await reloadedBy(page, () => { applyUpdate(); });
        assert.equal(await letter(page), "N11");
        assert.deepEqual(await cacheKeys(page), ["dingbat-n11"]);
      } finally {
        await ctx.close();
      }
    });

    test("an old page left under the new worker by another tab's Update: " +
         "its Force update is answered by the new worker", async () => {
      await oldStage(oldSrc, dir, "o3", "O3");
      const { ctx, page } = await open();
      try {
        await page.goto(site.url);
        await installedFresh(page);
        const other = await ctx.newPage();
        await other.goto(site.url);
        await booted(other);
        // This tab has a game in progress, so the other tab's Update leaves
        // it on its page (controllerchange) with its button saying Reload.
        await page.evaluate(() => { currentRomName = "a game"; });
        await stage(WEB, dir, "n12", "N12");
        await untilWaiting(other);
        await reloadedBy(other, () => { applyUpdate(); });
        assert.equal(await letter(other), "N12");
        await page.waitForFunction(() => updateActivated, null, { timeout: 30000 });
        assert.equal(await letter(page), "O3", "the game's tab kept its page");
        await stage(WEB, dir, "n12", "N13"); // index.js changes under the same sw.js
        await page.evaluate(() => { currentRomName = null; });
        await reloadedBy(page, () => { forceUpdate(); });
        assert.equal(await letter(page), "N13");
        // Committed to a cache of its own, the pointer moved there, the
        // install's cache dropped after its grace.
        await onlyCache(page, /^dingbat-n12-\d+-[a-z0-9]+$/);
        assert.deepEqual(Object.keys(await livePointer(page)), ["n12"]);
        assert.match((await livePointer(page)).n12, /^dingbat-n12-/);
      } finally {
        await ctx.close();
      }
    });

    test("a load of the app with a query right after a deploy boots the worker's build, " +
         "online and offline", async () => {
      await stage(WEB, dir, "q1", "Q1");
      const { ctx, page } = await open();
      try {
        await page.goto(site.url);
        await installedFresh(page);
        await stage(WEB, dir, "q2", "Q2"); // deployed, not installed
        for (const q of ["?2p", "?gpu3d=1"]) {
          const from = site.log.length;
          await page.goto(site.url + q);
          await booted(page);
          assert.equal(await letter(page), "Q1", q + ": the worker's build");
          const shell = site.log.slice(from).filter((e) => (e.path === "/" || e.path === "/index.html") && !e.query.startsWith("?v="));
          assert.deepEqual(shell, [], q + ": index.html came from the network");
        }
        assert.ok(await page.evaluate(() => document.body.classList.contains("debug-2p")) === false);
        site.offline(true);
        try {
          await page.goto(site.url + "?2p");
          await booted(page);
          assert.equal(await letter(page), "Q1", "offline");
          assert.ok(await page.evaluate(() => document.body.classList.contains("debug-2p")),
                    "the page read its own query");
        } finally { site.offline(false); }
      } finally {
        await ctx.close();
      }
    });

    test("a DS core cached under one build survives an update that leaves it alone, " +
         "downloading none of it; a tampered nds.wasm is refused", async () => {
      await stage(WEB, dir, "d1", "D1");
      const { ctx, page } = await open();
      try {
        await page.goto(site.url);
        await installedFresh(page);
        const l0 = site.log.length;
        assert.ok(await loadDs(page), "the DS core loads");
        const got = tally(site.log.slice(l0));
        assert.equal(got["/nds/nds.js"], 1);
        assert.equal(got["/nds/nds.wasm"], 1);
        assert.deepEqual(await ndsHeld(page, "dingbat-d1"), [true, true], "kept once checked");

        // An update changing index.js alone: the new install takes the DS
        // core along from d1's cache.
        const u0 = site.log.length;
        await stage(WEB, dir, "d2", "D2");
        await untilWaiting(page);
        const dl = assetGets(site, u0).map((e) => e.path);
        assert.ok(!dl.some((p) => p.startsWith("/nds/nds.")), "downloaded: " + JSON.stringify(dl));
        await reloadedBy(page, () => { applyUpdate(); });
        assert.equal(await letter(page), "D2");
        assert.deepEqual(await cacheKeys(page), ["dingbat-d2"]);
        assert.deepEqual(await ndsHeld(page, "dingbat-d2"), [true, true]);
        const l1 = site.log.length;
        assert.ok(await loadDs(page), "offline-ready: from the cache");
        assert.ok(!site.log.slice(l1).some((e) => e.path.startsWith("/nds/")));

        // A build whose served nds.wasm is not the one its manifest names
        // (an edge still on another object): refused, nothing kept.
        // d3 changes nds.wasm, but the server still sends d2's (an edge on
        // the previous object, the browser's HTTP cache too): its install
        // carries nds.js over and finds no nds.wasm with its digest; the
        // DS start downloads one, under the bare URL and then a fresh one,
        // and refuses both.
        const wasm = join(dir, "nds/nds.wasm");
        await stage(WEB, dir, "d3", "D3", { manifest: false });
        const orig = await readFile(wasm);
        const changed = Buffer.from(orig);
        changed[changed.length - 1] ^= 1;
        await writeFile(wasm, changed);
        writeManifest(dir);
        await writeFile(wasm, orig);
        await untilWaiting(page);
        await reloadedBy(page, () => { applyUpdate(); });
        assert.equal(await letter(page), "D3");
        assert.deepEqual(await ndsHeld(page, "dingbat-d3"), [true, false], "only nds.js carried over");
        const l2 = site.log.length;
        const ok = await page.evaluate(() => fetch("nds/nds.wasm").then((r) => r.ok, () => false));
        assert.equal(ok, false, "a nds.wasm that is not this build's is not served");
        assert.equal(await loadDs(page), false, "nor does the DS core load on it");
        const tries = site.log.slice(l2).filter((e) => e.path === "/nds/nds.wasm").map((e) => e.query);
        assert.ok(tries.some((q) => /^\?v=/.test(q)), "retried under a fresh URL: " + JSON.stringify(tries));
        assert.deepEqual(await ndsHeld(page, "dingbat-d3"), [true, false], "nothing kept");
        // The edge catches up: the next try gets it.
        await writeFile(wasm, changed);
        assert.ok(await page.evaluate(() => fetch("nds/nds.wasm").then((r) => r.ok, () => false)));
        assert.deepEqual(await ndsHeld(page, "dingbat-d3"), [true, true]);
        await writeFile(wasm, orig);
      } finally {
        await ctx.close();
      }
    });

    test("an old build's worker that fetched the DS core: the new install carries it over; " +
         "a Force update from the old page under the old worker, then the new worker installs", async () => {
      await oldStage(oldSrc, dir, "o4", "O4");
      const { ctx, page } = await open();
      try {
        await page.goto(site.url);
        await installedFresh(page);
        assert.equal(await letter(page), "O4");
        assert.ok(await loadDs(page), "the old page's DS core");
        // The old worker keeps whatever the network gave, in its own cache.
        assert.deepEqual(await ndsHeld(page, "dingbat-o4"), [true, true]);

        const u0 = site.log.length;
        await stage(WEB, dir, "n20", "N20");
        await page.evaluate(() => checkForUpdate());
        await page.waitForFunction(() => updateAvailable, null, { timeout: 30000 });
        await untilWaiting(page);
        const dl = assetGets(site, u0).map((e) => e.path);
        assert.ok(!dl.some((p) => p.startsWith("/nds/nds.")), "downloaded: " + JSON.stringify(dl));
        await reloadedBy(page, () => { applyUpdate(); });
        assert.equal(await letter(page), "N20");
        assert.deepEqual(await cacheKeys(page), ["dingbat-n20"]);
        assert.deepEqual(await ndsHeld(page, "dingbat-n20"), [true, true], "carried over");
      } finally {
        await ctx.close();
      }

      // A fresh visitor on the old build; the new one deploys and the old
      // page's Force update runs in the old worker (0b7f1b57's reinstall,
      // one put per asset into its own cache).
      await oldStage(oldSrc, dir, "o5", "O5");
      const t = await open();
      try {
        await t.page.goto(site.url);
        await installedFresh(t.page);
        assert.ok(await loadDs(t.page));
        await stage(WEB, dir, "n21", "N21");
        await reloadedBy(t.page, () => { forceUpdate(); });
        assert.equal(await letter(t.page), "N21", "the new page, under the old worker");
        await booted(t.page);
        const u0 = site.log.length;
        await untilWaiting(t.page);
        const dl = assetGets(site, u0).filter((e) => e.query === "?v=n21").map((e) => e.path);
        if (engine === "chromium") assert.deepEqual(dl, [], "every asset held already");
        else assert.ok(dl.every((p) => p === "/index.js"), JSON.stringify(dl));
        await reloadedBy(t.page, () => { applyUpdate(); });
        assert.equal(await letter(t.page), "N21");
        assert.deepEqual(await cacheKeys(t.page), ["dingbat-n21"]);
        assert.deepEqual(await ndsHeld(t.page, "dingbat-n21"), [true, true], "the DS core too");
      } finally {
        await t.ctx.close();
      }
    });

    // Stopping a worker needs CDP.
    test("a Force update interrupted mid-commit leaves the old build working", { skip: engine !== "chromium" },
      async () => {
        await stage(WEB, dir, "k1", "K1");
        const { ctx, page } = await open();
        try {
          await page.goto(site.url);
          await installedFresh(page);
          const cdp = await ctx.newCDPSession(page);
          await cdp.send("ServiceWorker.enable");
          // The new files; the worker's download of em.wasm held, and the
          // worker stopped while it waits.
          await stage(WEB, dir, "k1", "K2");
          const held = site.hold(/^\/em\.wasm\?v=\d+$/);
          await page.evaluate(() => {
            navigator.serviceWorker.controller.postMessage({ type: "reinstall", nonce: Date.now() });
          });
          await held.seen;
          await cdp.send("ServiceWorker.stopAllWorkers");
          held.release();
          // What a commit stopped part-way leaves: a cache of its own with
          // some of the new build in it, the pointer not moved.
          await page.evaluate(async () => {
            const c = await caches.open("dingbat-k1-1-partial");
            await c.put("index.js", new Response('var __build = "K2-partial";'));
          });
          await page.reload();
          await booted(page);
          assert.equal(await letter(page), "K1", "the old build, whole");
          assert.ok(await page.evaluate(async () =>
            (await (await fetch("em.wasm")).arrayBuffer()).byteLength > 0));
          const ptr = await livePointer(page);
          assert.equal(ptr.k1, "dingbat-k1", "the pointer never moved");
          // A Force update now lands, and clears what that one left.
          await reloadedBy(page, () => { forceUpdate(); });
          assert.ok(await page.evaluate(async () =>
            (await (await fetch("index.js")).text()).includes('var __build = "K2"')));
          await onlyCache(page, /^dingbat-k1-\d+-[a-z0-9]+$/);
          await page.goto(site.url);
          await booted(page);
          assert.equal(await letter(page), "K2");
        } finally {
          await ctx.close();
        }
      });
  });
}
