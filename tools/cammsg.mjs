#!/usr/bin/env node
//
// cammsg — author the text the Game Boy Camera viewfinder shows when there is
// no webcam.
//
// The cart renders whatever the emulated sensor hands it. With no camera
// attached, web/index.js writes a rendered TEXT frame into that sensor buffer
// so the viewfinder explains itself instead of showing the cart's synthetic
// test pattern (which players read as a corrupted picture). The messages live
// in index.js as CAM_NOTICES — one "/"-delimited string each. This script
// takes a candidate message, tells you how it will actually be laid out, and
// renders it, so the wording can be changed without booting the emulator.
//
// Nothing here reimplements the app. The message splitter (camNoticeLines),
// the layout arithmetic (camFitLines), the painter (camDrawNotice) and the
// RGBA->grey conversion (camToGrey) are all lifted OUT of the real, unmodified
// web/index.js at run time: the splitter is called in the node:vm sandbox that
// web/tests/helpers.mjs builds, and the three canvas functions are shipped by
// source into a headless Chromium page and run against a real 2-D context. If
// index.js changes, this script changes with it; the two cannot drift.
//
// Usage:
//   node tools/cammsg.mjs "{tap} / {label} / in the top bar"
//   node tools/cammsg.mjs --all                  # every shipped notice
//   node tools/cammsg.mjs --notice prompt        # one shipped notice
//
//   "/"       is the line break
//   {tap}     -> "Tap" on a touch device, "Click" otherwise
//   {label}   -> the top-bar button's own label (CAM_ENABLE_LABEL in
//                index.js), so a message that names the button cannot go on
//                naming a button that has been renamed
//
// Options:
//   --touch / --click   only one pointing-device wording (default: both, when
//                       the message actually uses {tap})
//   --out DIR           where the PNGs go (default: $TMPDIR/dingbat-cammsg)
//   --scale N           preview upscale, nearest-neighbour (default 4)
//   --cart              ALSO run the frame through the real cart in the real
//                       app for a true viewfinder preview. Opt-in because it
//                       needs a built web/em.wasm, the Camera ROM, and ~20s
//                       per frame; everything else here takes about a second.
//   --rom PATH          Camera ROM for --cart (default: the one under
//                       ~/.claude/jobs/679eeb5e/tmp/testroms/)
//   --state PATH        save state for --cart, ideally one parked in SHOOT
//                       mode so the viewfinder is on screen (same default dir)
//
// Output per message: the lines, the px size each will be SET at, a warning
// for any line that falls below the legibility floor, a sha256 of the sensor
// bytes (the 112 rows the cart keeps — the same digest is how the notices were
// proven byte-identical across the move to "/"-delimited strings), and a PNG
// path. Exit status is 1 if any line fell below the floor, so this can gate.
//
// Requires Playwright (web/package.json devDependency): from a checkout's
// web/, `npm ci` then `npx playwright install chromium`.

import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { extname, join, resolve, basename } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { loadApp } from "../web/tests/helpers.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const REPO = resolve(HERE, "..");
const WEB = join(REPO, "web");

// --- The legibility floor ---------------------------------------------------
// Not a number anyone picked. It is measured off the five SHIPPED notices,
// every one of which was read back off the real cart and found legible:
//
//   $ node tools/cammsg.mjs --all
//   ... smallest type: 17.6px
//
// The floor case is "Enable camera" — 13 characters, wide enough that the
// fitter shrinks it from its 28px slot to 17.6px to stay inside the sensor's
// 128px. Next smallest is the five-line "blocked" notice at 17.9px. So 17.6px
// is the smallest size KNOWN to survive the MAC-GBD's edge enhancement and 4x4
// dither; below that is unproven and, well below it, mush. Warn at a hair
// under that, so the shipped set does not warn about itself.
//
// Rule of thumb while writing: ~14 characters is the widest line that holds.
// Re-derive whenever the shipped set changes — `--all` prints the minimum.
const MIN_PX = 17.5;

// --- Playwright resolution ---------------------------------------------------
// Playwright is a devDependency of web/package.json only, and a git worktree
// does not get the main checkout's node_modules — so try this checkout first,
// then walk out to the shared checkout that .claude/worktrees/* live under.
let pw;
const pwCandidates = [
  join(WEB, "package.json"),
  join(REPO, "..", "..", "..", "web", "package.json"), // .claude/worktrees/<name>
];
try {
  pw = await import("playwright");
} catch {
  for (const c of pwCandidates) {
    if (pw || !existsSync(c)) continue;
    try { pw = createRequire(c)("playwright"); } catch {}
  }
}
if (!pw) {
  console.error("Playwright not found. From a checkout's web/: `npm ci` then " +
    "`npx playwright install chromium`.");
  process.exit(2);
}

// --- args -------------------------------------------------------------------
const argv = process.argv.slice(2);
const TAKES_VALUE = new Set(["out", "scale", "notice", "rom", "state"]);
const has = (name) => argv.includes("--" + name);
const arg = (name, dflt) => {
  const i = argv.indexOf("--" + name);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : dflt;
};
const positional = [];
for (let i = 0; i < argv.length; i++) {
  if (!argv[i].startsWith("--")) { positional.push(argv[i]); continue; }
  if (TAKES_VALUE.has(argv[i].slice(2))) i++;   // skip its value
}

const TESTROMS = "/Users/matt/.claude/jobs/679eeb5e/tmp/testroms/";
const OUT = arg("out", join(tmpdir(), "dingbat-cammsg"));
const SCALE = Math.max(1, parseInt(arg("scale", "4"), 10) || 4);
const CART = has("cart");
const ROM = arg("rom", TESTROMS + "gbcamera.gb");
const STATE = arg("state", TESTROMS + "gbcam-corrupt.state");

if (has("help") || has("h")) {
  console.log(await readFile(new URL(import.meta.url), "utf8")
    .then((s) => s.split("\n").filter((l) => l.startsWith("//")).join("\n")));
  process.exit(0);
}

// --- the app's own message layer --------------------------------------------
// helpers.mjs evaluates the real web/index.js in a node:vm with a stubbed DOM;
// runIn() then reaches into that context, so CAM_NOTICES / camNoticeLines /
// CAM_ENABLE_LABEL below are literally the app's.
const app = await loadApp();
const NOTICES = app.runIn("({...CAM_NOTICES})");
const ENABLE_LABEL = app.runIn("CAM_ENABLE_LABEL");

// One preview job = one message under one pointing-device wording.
const jobs = [];
const addJob = (name, text) => {
  // Register the candidate as a notice so the app's OWN splitter handles it,
  // placeholders and all. CAM_NOTICES is a const binding but a mutable object.
  app.runIn(`CAM_NOTICES.__preview = ${JSON.stringify(text)}`);
  const wordings = has("touch") ? [true] : has("click") ? [false]
    : /\{tap\}/.test(text) ? [false, true] : [false];
  for (const touch of wordings) {
    jobs.push({
      name, text, touch,
      label: name + (wordings.length > 1 ? (touch ? " (Tap)" : " (Click)") : ""),
      lines: app.runIn(`camNoticeLines("__preview", ${touch})`),
    });
  }
};

if (has("all")) {
  for (const k of Object.keys(NOTICES)) addJob(k, NOTICES[k]);
} else if (has("notice")) {
  const k = arg("notice", "");
  if (!NOTICES[k]) {
    console.error(`no such notice "${k}". Known: ${Object.keys(NOTICES).join(", ")}`);
    process.exit(2);
  }
  addJob(k, NOTICES[k]);
} else if (positional.length) {
  addJob("message", positional.join(" "));
} else {
  console.error('usage: node tools/cammsg.mjs "{tap} / {label} / in the top bar"' +
    "   (also: --all, --notice <kind>, --help)");
  process.exit(2);
}

// --- the app's own canvas layer ---------------------------------------------
// Shipped by source into the page: these three are pure functions of a 2-D
// context, so running them there is running the app's rendering exactly.
const PREAMBLE = app.runIn(`
  "const CAM_W = " + CAM_W + ", CAM_H = " + CAM_H + ";\\n" +
  "const CAM_VIEW_TOP = " + CAM_VIEW_TOP + ", CAM_VIEW_H = " + CAM_VIEW_H + ";\\n" +
  "const camFitLines = " + camFitLines + ";\\n" +
  "const camDrawNotice = " + camDrawNotice + ";\\n" +
  "const camToGrey = " + camToGrey + ";\\n"`);

// Runs in the page. Returns the fit report, the sensor bytes, and a PNG.
const RENDER = (lines, scale, preamble) => {
  const fn = new Function(preamble + `
    const cnv = document.createElement("canvas");
    cnv.width = CAM_W; cnv.height = CAM_H;
    const ctx = cnv.getContext("2d", { willReadFrequently: true });
    const fits = camFitLines(ctx, arguments[0]).map((f) => ({ ...f }));
    camDrawNotice(ctx, arguments[0]);
    const img = ctx.getImageData(0, 0, CAM_W, CAM_H).data;
    const grey = new Uint8Array(CAM_W * CAM_H);
    camToGrey(img, grey);
    // Nearest-neighbour upscale for a preview a human can look at; the bytes
    // reported above are always the true 1x sensor frame.
    const big = document.createElement("canvas");
    big.width = CAM_W * arguments[1]; big.height = CAM_H * arguments[1];
    const bg = big.getContext("2d");
    bg.imageSmoothingEnabled = false;
    bg.drawImage(cnv, 0, 0, big.width, big.height);
    return { fits, grey: Array.from(grey), png: big.toDataURL("image/png"),
             w: CAM_W, h: CAM_H, top: CAM_VIEW_TOP, viewH: CAM_VIEW_H };
  `);
  return fn(lines, scale);
};

// --- optional: through the real cart ----------------------------------------
const MIME = {
  ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".css": "text/css", ".wasm": "application/wasm", ".json": "application/json",
  ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon",
  ".webmanifest": "application/manifest+json",
};

const startServer = () => new Promise((res) => {
  const srv = createServer(async (req, rq) => {
    try {
      let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
      if (p === "/") p = "/index.html";
      const file = join(WEB, p);
      if (!file.startsWith(WEB)) { rq.writeHead(403); return rq.end(); }
      const body = await readFile(file);
      rq.writeHead(200, {
        "Content-Type": MIME[extname(file).toLowerCase()] || "application/octet-stream",
        "Cache-Control": "no-store",
      });
      rq.end(body);
    } catch { rq.writeHead(404); rq.end("not found"); }
  });
  // Port 0: the OS picks a free one, so this never collides with a dev server.
  srv.listen(0, "127.0.0.1", () => res({ srv, port: srv.address().port }));
});

// Boot the app, drop the Camera ROM in through the app's own file handler,
// load a save state so the cart is already showing its viewfinder, then push
// the candidate text in as a notice — through camShowNotice, the same call the
// app makes. The screenshot is the emulated LCD: dither, edge enhancement and
// all. This is the only slow path in the script, hence --cart.
const cartPreview = async (browser, port, job, dir) => {
  const ctx = await browser.newContext({
    serviceWorkers: "block", viewport: { width: 900, height: 800 },
    deviceScaleFactor: 2, hasTouch: job.touch, isMobile: job.touch,
  });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("  page error:", e.message));
  await page.goto(`http://127.0.0.1:${port}/index.html`);
  await page.waitForFunction(
    () => typeof Module !== "undefined" && Module._wasm_camera_attach &&
          typeof handleDroppedFile === "function", null, { timeout: 60000 });
  const rom64 = (await readFile(ROM)).toString("base64");
  await page.evaluate(async (b) => {
    handleDroppedFile(new File(
      [Uint8Array.from(atob(b), (c) => c.charCodeAt(0))], "gbcamera.gb"));
    await new Promise((r) => setTimeout(r, 1000));
    const warn = document.getElementById("rom-warn-modal");
    if (warn.classList.contains("open"))
      document.getElementById("rom-warn-load").click();
  }, rom64);
  await page.waitForTimeout(2500);
  if (existsSync(STATE)) {
    const st = (await readFile(STATE)).toString("base64");
    const ok = await page.evaluate(async (b) =>
      applyStateBytes(Uint8Array.from(atob(b), (c) => c.charCodeAt(0))), st);
    if (!ok) console.log("  (save state rejected by the core — " +
      "the cart may not be in shoot mode)");
    await page.waitForTimeout(2500);
  }
  // Feed the ALREADY-EXPANDED lines back through the notice path, so the
  // placeholder wording chosen above is exactly what the cart draws.
  await page.evaluate((text) => {
    CAM_NOTICES.__preview = text;
    camNoticeShown = null;
    camShowNotice("__preview");
  }, job.lines.join(" / "));
  // The cart's exposure loop needs a few captures to settle on the new scene.
  await page.waitForTimeout(3500);
  await page.evaluate(() => {
    for (const b of document.querySelectorAll(".toast-close")) b.click();
  });
  const path = join(dir, `${job.name}${job.touch ? "-tap" : ""}-cart.png`);
  await page.locator("#canvas").screenshot({ path });
  await ctx.close();
  return path;
};

// --- run ---------------------------------------------------------------------
await mkdir(OUT, { recursive: true });
const browser = await pw.chromium.launch();
const page = await browser.newPage();
await page.evaluate(`window.RENDER_FN = ${RENDER.toString()}`);
let server = null;
if (CART) {
  if (!existsSync(join(WEB, "em.wasm"))) {
    console.error("--cart needs a built web/em.wasm in this checkout.");
    process.exit(2);
  }
  if (!existsSync(ROM)) {
    console.error(`--cart needs the Camera ROM; not at ${ROM} (pass --rom).`);
    process.exit(2);
  }
  server = await startServer();
}

let worst = Infinity, warned = 0;
console.log(`button label: "${ENABLE_LABEL}"   floor: ${MIN_PX}px   out: ${OUT}\n`);

for (const job of jobs) {
  const r = await page.evaluate(([l, s, p]) => window.RENDER_FN(l, s, p),
    [job.lines, SCALE, PREAMBLE]);

  const grey = Uint8Array.from(r.grey);
  // The MAC-GBD keeps only the middle 112 of the sensor's 120 rows (it drops
  // CAM_SENSOR_EXTRA/2 = 4 at each end), so hash what the cart can actually
  // see — a change confined to the discarded bands is not a change.
  const kept = grey.subarray(r.top * r.w, (r.top + r.viewH) * r.w);
  const sha = createHash("sha256").update(kept).digest("hex").slice(0, 16);

  const png = join(OUT, `${job.name}${job.touch ? "-tap" : ""}.png`);
  await writeFile(png, Buffer.from(r.png.split(",")[1], "base64"));

  console.log(`${job.label}   ${JSON.stringify(job.text)}`);
  for (const f of r.fits) {
    const px = f.px;
    worst = Math.min(worst, px);
    const flag = px < MIN_PX ? "  <-- TOO SMALL, will turn to mush" : "";
    if (px < MIN_PX) warned++;
    console.log(`  ${String(px.toFixed(1)).padStart(6)}px  ` +
      `${JSON.stringify(f.text)}${flag}`);
  }
  console.log(`  sensor sha256 ${sha}   ${png}`);
  if (CART) console.log(`  cart preview  ${
    await cartPreview(browser, server.port, job, OUT)}`);
  console.log();
}

console.log(`smallest type: ${worst.toFixed(1)}px` +
  (warned ? `   ${warned} line(s) below the ${MIN_PX}px floor` : "   all legible"));

await browser.close();
server?.srv.close();
// helpers.mjs leaves fake timers/handles in its vm sandbox; nothing else is
// pending, so leave deliberately rather than hanging on them.
process.exit(warned ? 1 : 0);
