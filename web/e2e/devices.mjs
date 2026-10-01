// Several "devices" - browser contexts, each its own IndexedDB and
// localStorage, in Chromium or WebKit - running the real build (index.js +
// the wasm core) against one fake Drive (fakedrive.mjs). Actions go through
// the visible UI (Add a game, Menu > Main Menu, the account menu's Sync
// now, the hero's buttons, toasts); only the game's own input (holding A)
// and the observations read the page directly.

import { createServer } from "node:http";
import { readFile, stat, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { existsSync } from "node:fs";
import { extname, join, normalize } from "node:path";
import { createRequire } from "node:module";
import { makeDrive } from "./fakedrive.mjs";
import { synctestRom, SYNCTEST_NAME } from "./synctest-rom.mjs";

export const WEB = process.env.DINGBAT_WEB || new URL("..", import.meta.url).pathname;
const require = createRequire(join(WEB, "package.json"));
const playwright = require("playwright");

export const GAME = SYNCTEST_NAME;
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Built? em.js/em.wasm come from `nim c -d:emscripten src/dingbat_wasm.nim`.
export const builtWeb = () => existsSync(join(WEB, "em.wasm")) && existsSync(join(WEB, "em.js"));

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".wasm": "application/wasm", ".json": "application/json",
  ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon",
  ".webmanifest": "application/manifest+json", ".txt": "text/plain" };

// The web/ directory over http on 127.0.0.1: a secure context, no cache.
export const serveWeb = () => new Promise((resolve) => {
  const server = createServer(async (req, res) => {
    let path = decodeURIComponent(new URL(req.url, "http://x").pathname);
    if (path.endsWith("/")) path += "index.html";
    const file = normalize(join(WEB, path));
    if (!file.startsWith(normalize(WEB))) { res.writeHead(403).end(); return; }
    try {
      if (!(await stat(file)).isFile()) throw 0;
      res.writeHead(200, { "Content-Type": TYPES[extname(file)] || "application/octet-stream",
                           "Cache-Control": "no-store" });
      res.end(await readFile(file));
    } catch { res.writeHead(404).end(); }
  });
  server.listen(0, "127.0.0.1", () =>
    resolve({ url: `http://127.0.0.1:${server.address().port}/`, close: () => server.close() }));
});

// What each device is. The phone is WebKit with an iPhone's screen, touch
// and user agent, so the app calls it "iPhone"; the others are desktops.
// WebKit devices keep a profile on disk (`persistent`): a context without
// one behaves as Safari's private browsing does, where IndexedDB keeps no
// Blob - which is its own kind, "iphone-private".
// A Mac says so in its user agent whatever machine runs the test (on CI's
// Linux the browsers' own would make it a "PC").
const MAC_UA = {
  chromium: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
  webkit: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
          "(KHTML, like Gecko) Version/26.0 Safari/605.1.15",
};
const DESKTOP = { width: 1100, height: 860 };
const KINDS = {
  iphone: { engine: "webkit", descriptor: "iPhone 13 Mini", persistent: true },
  "iphone-private": { engine: "webkit", descriptor: "iPhone 13 Mini" },
  mac: { engine: "chromium", context: { viewport: DESKTOP, userAgent: MAC_UA.chromium } },
  "mac-webkit": { engine: "webkit", persistent: true,
                  context: { viewport: DESKTOP, userAgent: MAC_UA.webkit } },
};

// DINGBAT_E2E_NO_CHROMIUM=1: the Mac is WebKit too. CI sets it: its
// runners draw Chromium's WebGL in software at about three frames a second
// (e2e/speed-probe.mjs), where WebKit runs at sixty.
if (process.env.DINGBAT_E2E_NO_CHROMIUM) KINDS.mac = KINDS["mac-webkit"];

export const startRig = async () => {
  const web = await serveWeb();
  const browsers = new Map();
  const browser = async (engine) => {
    if (!browsers.has(engine)) browsers.set(engine, await playwright[engine].launch({ headless: true }));
    return browsers.get(engine);
  };
  const contexts = [];
  const profiles = [];
  return {
    web,
    // A fresh Drive per test; devices made with it share it.
    drive: () => makeDrive(),
    device: async (drive, who, kind = "mac") => {
      const k = KINDS[kind];
      const opts = { serviceWorkers: "block",
                     ...(k.descriptor ? playwright.devices[k.descriptor] : {}), ...(k.context || {}) };
      let ctx;
      if (k.persistent) {
        const dir = await mkdtemp(join(tmpdir(), "dingbat-e2e-"));
        profiles.push(dir);
        ctx = await playwright[k.engine].launchPersistentContext(dir, { headless: true, ...opts });
      } else {
        ctx = await (await browser(k.engine)).newContext(opts);
      }
      contexts.push(ctx);
      // Every toast as it appears (they leave the screen after a few seconds).
      await ctx.addInitScript(() => {
        window.__toastLog = [];
        new MutationObserver(() => {
          for (const m of document.querySelectorAll("#toast .toast-msg")) {
            if (!m.__logged) { m.__logged = true; window.__toastLog.push(m.textContent); }
          }
        }).observe(document, { childList: true, subtree: true });
      });
      // WebKit does not show Playwright a request body that is a Blob (an
      // upload's multipart body is one), so bodies bound for Google are
      // read into bytes first. The same bytes go out either way.
      await ctx.addInitScript(() => {
        const send = window.fetch.bind(window);
        window.fetch = async (input, init) => {
          if (init?.body instanceof Blob && /googleapis\.com/.test(String(input))) {
            init = { ...init, body: await init.body.arrayBuffer() };
          }
          return send(input, init);
        };
      });
      await ctx.route(/googleapis\.com|accounts\.google\.com/, (route) => drive.handle(route, who));
      const page = ctx.pages()[0] || await ctx.newPage();
      // DINGBAT_E2E_SLOW=4: Chromium devices run on a quarter of the CPU, to
      // shake out waits that only hold on a fast machine (CI's are slower).
      const slow = Number(process.env.DINGBAT_E2E_SLOW || 0);
      if (slow > 1 && k.engine === "chromium") {
        await (await ctx.newCDPSession(page)).send("Emulation.setCPUThrottlingRate", { rate: slow });
      }
      const errors = [];
      page.on("pageerror", (e) => errors.push(e.message + " @ " + (e.stack || "").split("\n").slice(0, 3).join(" < ")));
      const d = { who, kind, ctx, page, errors };
      // Signed in: the record a sign-in leaves, with a token good for an hour.
      await page.goto(web.url);
      await page.waitForFunction(() => typeof db !== "undefined" && !!db);
      await page.evaluate(async () => {
        await dbPut("gdrive_sync", {
          queueUp: [], queueDel: [], queueRen: [], tomb: [], ren: [], sigs: {}, rmt: {},
          delTs: {}, acct: "acct1", parked: {}, connected: true, token: "tok",
          tokenExp: Date.now() + 3600e3, email: "player@example.com",
        });
        // The one-time offer to picture the library has been answered; it
        // would otherwise open over whatever the test taps next.
        await dbPut(THUMBS_OFFER_KEY, Date.now());
      });
      await page.reload();
      await page.waitForFunction(() => typeof db !== "undefined" && !!db &&
        typeof gdriveToken !== "undefined" && !!gdriveToken);
      await idle(d);
      return d;
    },
    // Contexts end with each test; the browsers with the rig.
    endTest: async () => {
      for (const c of contexts.splice(0)) await c.close().catch(() => {});
      for (const dir of profiles.splice(0)) await rm(dir, { recursive: true, force: true });
    },
    close: async () => {
      for (const b of browsers.values()) await b.close();
      web.close();
    },
  };
};

// ── Actions ────────────────────────────────────────────────────────────────

// The device being used is the one in front: a page behind another runs no
// animation frames, so its game would not run.
export const front = async (d) => { await d.page.bringToFront(); };

// Until the sync engine is quiet with nothing queued.
export const idle = async (d, timeout = 20000) => {
  await sleep(300);
  try {
    await d.page.waitForFunction(() => !syncBusy && !pullQueued &&
      syncState.queueUp.length === 0 && syncState.queueDel.length === 0, null, { timeout });
  } catch (e) {
    const left = await d.page.evaluate(() => JSON.stringify({
      busy: syncBusy, up: syncState.queueUp, del: syncState.queueDel, status: syncStatus }));
    throw new Error(`${d.who} never went quiet: ${left}`);
  }
  await sleep(200);
};

// On screen and running: past the opening flight, which holds the game
// (paused) until the picture lands - longer on a slow machine.
const running = (d) => d.page.waitForFunction(
  () => document.body.classList.contains("running") &&
        !document.body.classList.contains("home-flying") && !paused,
  null, { timeout: 20000 });

// Hold a button (input id: A 4, B 5) for `frames` frames the game really
// ran: counted on the page, so a slow machine or a held game is waited out
// rather than played through.
const hold = async (d, input, frames) => {
  await front(d);
  await running(d);
  // Counted at the core: every emulated frame is a _loop_tick call.
  await d.page.evaluate(([input, frames]) => new Promise((resolve, reject) => {
    const step = Module._loop_tick;
    let ran = 0;
    let give = 0;
    const done = (err) => {
      Module._loop_tick = step;
      Module._setInput(input, 0);
      clearTimeout(give);
      if (err) reject(err); else resolve(ran);
    };
    Module._loop_tick = (...a) => {
      Module._setInput(input, 1); // held through anything that lets go of it
      const r = step(...a);
      if (++ran === frames) setTimeout(done, 0);
      return r;
    };
    Module._setInput(input, 1);
    give = setTimeout(() => done(new Error("the game ran " + ran + " frames")), 30000);
  }), [input, frames]);
  await sleep(100);
};

export const addGame = async (d) => {
  await front(d);
  const [chooser] = await Promise.all([
    d.page.waitForEvent("filechooser"),
    d.page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click(),
  ]);
  await chooser.setFiles({ name: GAME, mimeType: "application/octet-stream",
                           buffer: Buffer.from(synctestRom()) });
  await running(d);
  await sleep(400);
};

// Playing: A held for `frames` frames writes the battery save each frame.
export const play = (d, frames) => hold(d, 4, frames);

// Playing without saving: B moves the game on and writes nothing to the
// battery, so only the session can carry where it got to.
export const playNoSave = (d, frames) => hold(d, 5, frames);

// Playing on until the screen is not `unlike` (another device's): the test
// ROM has four shades, so two devices can show the same one by chance, and
// a picture check between them would then prove nothing.
export const playUntilUnlike = async (d, frames, unlike) => {
  await play(d, frames);
  for (let i = 0; i < 16 && samePicture(await screenPixel(d), unlike); i++) await play(d, 5);
  if (samePicture(await screenPixel(d), unlike)) throw new Error("screen never left " + unlike);
};

export const mainMenu = async (d) => {
  await front(d);
  await d.page.click("#menu-btn");
  await d.page.click("#main-menu");
  await d.page.waitForFunction(() => document.body.classList.contains("paused"));
  await sleep(700);
};

export const closeGame = async (d) => {
  await d.page.click("#hero-close");
  await sleep(500);
};

// Sync now from the account menu (or the empty library's own Sync).
export const syncNow = async (d) => {
  await front(d);
  const slot = await d.page.evaluate(() =>
    getComputedStyle(document.getElementById("account-slot")).display !== "none");
  if (slot) {
    await d.page.click("#account-btn");
    await d.page.click("#account-sync");
  } else {
    await d.page.click("#home-drive");
  }
  await idle(d);
  await d.page.keyboard.press("Escape").catch(() => {});
  await sleep(300);
};

export const openFirstTile = async (d) => {
  await front(d);
  await d.page.locator(".home-tile-launch").first().click();
  await running(d);
  await sleep(500);
};

export const resumeHero = async (d) => {
  await front(d);
  await d.page.click("#hero-resume");
  await running(d);
  await sleep(600);
};

export const tapToast = async (d, label) => {
  await d.page.locator("#toast .toast-item button", { hasText: label }).first().click();
  await sleep(500);
};

// The tab put away and brought back, as a phone does when you switch apps:
// the hide's snapshot and its flush, then the return's flush and pull.
// `settle: false` returns as the tab comes back, before its sync ends (a
// toast it raises is up for seconds, not for as long as a slow sync).
export const awayAndBack = async (d, { settle = true } = {}) => {
  await d.page.evaluate(() => {
    const set = (v) => {
      Object.defineProperty(document, "visibilityState", { value: v, configurable: true });
      Object.defineProperty(document, "hidden", { value: v === "hidden", configurable: true });
      document.dispatchEvent(new Event("visibilitychange"));
    };
    window.__setVisibility = set;
    set("hidden");
  });
  await sleep(2600); // the debounced flush of what hiding queued
  await d.page.evaluate(() => window.__setVisibility("visible"));
  if (settle) await idle(d);
};

// ── Observations ───────────────────────────────────────────────────────────

// The game's battery byte: as the core holds it, and as stored.
export const saveByte = async (d) => d.page.evaluate(async (game) => {
  let live = null;
  if (currentRomName) {
    Module._wasm_flush_save?.();
    try { live = FS.readFile(currentRomName.replace(/\.[^.]+$/, "") + ".sav")[0]; } catch {}
  }
  const stored = (await dbGet("save:" + game))?.[0] ?? null;
  return { live, stored };
}, GAME);

// The colour at (2,2) of the game's screen, and of the hero's picture.
export const screenPixel = async (d) => d.page.evaluate(() => {
  const fb = copyFramebuffer();
  if (!fb) return null;
  const i = (2 * fb.w + 2) * 4;
  return Array.from(fb.heap.slice(i, i + 3));
});
export const hero = async (d) => d.page.evaluate(() => {
  const el = document.getElementById("hero");
  let pixel = null;
  try {
    pixel = Array.from(document.getElementById("hero-canvas").getContext("2d")
      .getImageData(2, 2, 1, 1).data.slice(0, 3));
  } catch {}
  return {
    shown: !el.hidden, mode: el.dataset.mode,
    kicker: document.getElementById("hero-state").textContent,
    primary: document.getElementById("hero-resume-label").textContent,
    pixel,
  };
});
// Every toast shown so far on this page, gone from the screen or not.
export const toasts = async (d) => d.page.evaluate(() => window.__toastLog.slice());
export const isPlaying = async (d) =>
  d.page.evaluate(() => document.body.classList.contains("running"));

// The game's screen exactly: a fingerprint of the whole framebuffer.
export const screenPrint = async (d) => d.page.evaluate(() => {
  const fb = copyFramebuffer();
  return fb ? framebufferSig(fb.heap) : null;
});

// A picture as a 40x36 grid of greys, so a stored JPEG (a tile, the hero)
// can be held against a screen. `of`: "screen" (the framebuffer), "hero",
// or "tile" (the picture on the game's tile in the grid).
export const grid = async (d, of) => d.page.evaluate(async ({ of, game }) => {
  const c = document.createElement("canvas");
  c.width = 160; c.height = 144;
  const ctx = c.getContext("2d");
  if (of === "screen") {
    const fb = copyFramebuffer();
    if (!fb) return null;
    const src = document.createElement("canvas");
    src.width = fb.w; src.height = fb.h;
    const rgba = new Uint8ClampedArray(fb.heap);
    for (let i = 3; i < rgba.length; i += 4) rgba[i] = 255; // the core's alpha means nothing
    const img = new ImageData(rgba, fb.w, fb.h);
    src.getContext("2d").putImageData(img, 0, 0);
    ctx.drawImage(src, 0, 0, 160, 144);
  } else if (of === "hero") {
    ctx.drawImage(document.getElementById("hero-canvas"), 0, 0, 160, 144);
  } else {
    const img = document.querySelector(`.home-tile[data-rom="${game}"] .home-tile-thumb img`);
    if (!img) return null;
    await img.decode?.().catch(() => {});
    ctx.drawImage(img, 0, 0, 160, 144);
  }
  const px = ctx.getImageData(0, 0, 160, 144).data;
  const out = [];
  for (let y = 0; y < 36; y++) {
    for (let x = 0; x < 40; x++) {
      let s = 0;
      for (let dy = 0; dy < 4; dy++) {
        for (let dx = 0; dx < 4; dx++) {
          const i = ((y * 4 + dy) * 160 + x * 4 + dx) * 4;
          s += (px[i] + px[i + 1] + px[i + 2]) / 3;
        }
      }
      out.push(s / 16);
    }
  }
  return out;
}, { of, game: GAME });
// Mean grey difference between two grids (0 = the same picture).
export const gridDistance = (a, b) => (!a || !b) ? Infinity
  : a.reduce((s, v, i) => s + Math.abs(v - b[i]), 0) / a.length;

// Two pictures of the same screen, allowing for JPEG.
export const samePicture = (a, b) => !!a && !!b && a.every((v, i) => Math.abs(v - b[i]) <= 8);
