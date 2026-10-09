// DS games in the real app, headless Chromium: a .nds through Add a game,
// both screens on the canvas, the stylus reaching the core at the pixel the
// pointer is over, sound flowing, and a battery save the game wrote coming
// back after a reload. Needs both wasm builds and the DS test ROMs:
//
//   nim c -d:emscripten src/dingbat_wasm.nim       # web/em.{js,wasm}
//   nim c -d:emscripten src/dingbat_nds_wasm.nim   # web/nds/nds.{js,wasm}
//   tests/nds/tools/build_fb.sh && tests/nds/tools/build_save.sh
//   (built/touch_test.nds: tests/nds/README.md)
//   node --test e2e/nds.e2e.mjs                    # from web/
//
// DINGBAT_NDS_BENCH=<a .nds> also times that game's frames unpaced (the
// figure docs/nds/web.md quotes for SoulSilver).

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { createRequire } from "node:module";
import { serveWeb, WEB, builtWeb, sleep } from "./devices.mjs";

const require = createRequire(join(WEB, "package.json"));
const playwright = require("playwright");
const ROMS = process.env.DINGBAT_NDS_ROMS || join(homedir(), ".cache/dingbat-nds/roms");
const rom = (p) => join(ROMS, p);
const NEED = ["fb_both.nds", "snd_tone.nds", "save_write.nds", "built/touch_test.nds",
              "built/simple.nds"];
const missing = [
  ...(builtWeb() ? [] : ["web/em.wasm"]),
  ...(existsSync(join(WEB, "nds/nds.wasm")) ? [] : ["web/nds/nds.wasm"]),
  ...NEED.filter((p) => !existsSync(rom(p))),
];
const skip = missing.length ? "missing: " + missing.join(", ") : false;

let web, browser;
before(async () => {
  if (skip) return;
  web = await serveWeb();
  // Headless Chromium draws WebGL in software (a few frames a second at
  // the DS's backing size); on a Mac it can have the GPU.
  browser = await playwright.chromium.launch({ headless: true, args: [
    "--mute-audio", "--autoplay-policy=no-user-gesture-required",
    // A fake microphone (a beep), granted without asking: the mic test.
    "--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream",
    ...(process.platform === "darwin" ? ["--enable-gpu", "--use-angle=metal", "--ignore-gpu-blocklist"] : []),
  ] });
});
after(async () => { await browser?.close(); web?.close(); });

const newPage = async (ctx) => {
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(web.url);
  await page.waitForFunction(() => document.body.classList.contains("runtime-ready"),
                             null, { timeout: 30000 });
  return { page, errors };
};

// Through the visible "Add a game", as a person does it.
const addGame = async (page, path, name = path.split("/").pop()) => {
  const [chooser] = await Promise.all([
    page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click(),
  ]);
  await chooser.setFiles(existsSync(path) && !name.includes("/")
    ? path : { name, mimeType: "application/octet-stream", buffer: readFileSync(path) });
  await running(page);
};
const running = (page) => page.waitForFunction(() =>
  document.body.classList.contains("running") && ndsCoreGame !== null && !paused,
  null, { timeout: 60000 });
const framesPast = (page, n) => page.waitForFunction(
  (n) => ndsCore._nds_frame_count() >= n, n, { timeout: 60000 });

// The canvas as drawn: presented and read back in one task (no
// preserveDrawingBuffer). [r, g, b] at fractions of the canvas box.
const canvasAt = (page, points) => page.evaluate((points) => {
  drawGame();
  const c = document.createElement("canvas");
  c.width = canvasEl.width; c.height = canvasEl.height;
  const ctx = c.getContext("2d");
  ctx.drawImage(canvasEl, 0, 0);
  return points.map(([fx, fy]) =>
    [...ctx.getImageData(Math.floor(fx * c.width), Math.floor(fy * c.height), 1, 1).data].slice(0, 3));
}, points);

test("a DS game draws both screens through the presenter", { skip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, rom("fb_both.nds"));
  assert.equal(await page.evaluate(() => document.body.classList.contains("nds-mode")), true);
  await page.evaluate(() => setNdsLayout("stack"));
  await framesPast(page, 10);
  // fb_both: top = the fb_hello gradient (top-left blue, top-right red),
  // bottom = solid magenta 0x7C1F. Stacked with the gap: 392 rows.
  const [tl, tr, bottom] = await canvasAt(page, [[0.02, 0.02], [0.98, 0.02], [0.5, 0.75]]);
  assert.ok(tl[2] > 200 && tl[0] < 40, "top-left of the top screen is blue: " + tl);
  assert.ok(tr[0] > 200 && tr[2] < 40, "top-right of the top screen is red: " + tr);
  assert.deepEqual(bottom, [255, 0, 255], "the bottom screen is magenta");
  // Side by side: the bottom screen is the right half.
  await page.evaluate(() => setNdsLayout("side"));
  await sleep(100);
  const [right] = await canvasAt(page, [[0.75, 0.5]]);
  assert.deepEqual(right, [255, 0, 255]);
  assert.deepEqual(errors, []);
  await ctx.close();
});

test("the stylus lands on the bottom-screen pixel under the pointer", { skip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 800 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, rom("built/touch_test.nds"));
  await framesPast(page, 120);
  // touch_test prints the touch position at the bottom screen's top left.
  const textRows = () => page.evaluate(() => {
    const p = ndsCore._nds_fb_bottom();
    return Array.from(ndsCore.HEAPU8.subarray(p, p + 256 * 9 * 4));
  });
  const settle = () => page.evaluate((n) => new Promise((r) => {
    const f0 = ndsCore._nds_frame_count();
    const t = () => (ndsCore._nds_frame_count() >= f0 + n ? r() : requestAnimationFrame(t));
    t();
  }), 8);
  const P = [100, 80];
  // The client point of bottom-screen pixel P's centre, from the layout.
  const at = await page.evaluate(([x, y]) =>
    NdsUtil.clientPoint("bottom", x, y, canvasEl.getBoundingClientRect(), ndsLay), P);
  await page.mouse.move(at[0], at[1]);
  await page.mouse.down();
  await settle();
  const viaPointer = await textRows();
  await page.mouse.up();
  await settle();
  // The same pixel straight into the core; then another one.
  await page.evaluate(([x, y]) => ndsCore._nds_set_touch(x, y, 1), P);
  await settle();
  const direct = await textRows();
  await page.evaluate(() => ndsCore._nds_set_touch(30, 150, 1));
  await settle();
  const elsewhere = await textRows();
  await page.evaluate(() => ndsCore._nds_set_touch(0, 0, 0));
  assert.deepEqual(viaPointer, direct, "the pointer touched (100, 80)");
  assert.notDeepEqual(viaPointer, elsewhere, "and the readout tells points apart");
  assert.deepEqual(errors, []);
  await ctx.close();
});

// --- Display modes (docs/nds/web.md "Screens") ---------------------------------

// Every arrangement, swap, gap and turn the Screens panel offers.
const MODES = [];
for (const layout of ["stack", "side", "focus", "single"]) {
  for (const swap of [false, true]) {
    for (const rot of [0, 3, 1]) MODES.push({ layout, swap, rot, gap: "hinge" });
  }
}
MODES.push({ layout: "stack", swap: false, rot: 0, gap: "none" },
           { layout: "side", swap: false, rot: 0, gap: "console" },
           { layout: "auto", swap: false, rot: 0, gap: "hinge" });
const setMode = (page, m) => page.evaluate(async (m) => {
  await setNdsDisplay({ swap: m.swap, rot: m.rot, gap: m.gap });
  await setNdsLayout(m.layout);
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
}, m);
const tag = (m) => `${m.layout} swap=${m.swap} rot=${m.rot} gap=${m.gap}`;

test("every arrangement draws each screen where the layout says, the right way up", { skip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 800 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, rom("fb_both.nds"));
  await framesPast(page, 10);
  for (const m of MODES) {
    await setMode(page, m);
    // Canvas fractions of screen pixels, through the same maths the stylus uses.
    const at = await page.evaluate(() => {
      const r = canvasEl.getBoundingClientRect();
      const f = (s, x, y) => {
        const p = NdsUtil.clientPoint(s, x, y, r, ndsLay);
        return p && [(p[0] - r.left) / r.width, (p[1] - r.top) / r.height];
      };
      return { tl: f("top", 8, 8), tr: f("top", 247, 8), bottom: f("bottom", 128, 96),
               shown: { top: !!ndsLay.rects.top, bottom: !!ndsLay.rects.bottom } };
    });
    const pts = [at.tl, at.tr, at.bottom].filter(Boolean);
    const px = await canvasAt(page, pts);
    let i = 0;
    if (at.shown.top) {
      const tl = px[i++], tr = px[i++];
      // fb_both's top screen: blue at its top left, red at its top right.
      assert.ok(tl[2] > 150 && tl[0] < 80, `${tag(m)}: top screen's top left is blue: ${tl}`);
      assert.ok(tr[0] > 150 && tr[2] < 80, `${tag(m)}: top screen's top right is red: ${tr}`);
    }
    if (at.shown.bottom) {
      assert.deepEqual(px[i++], [255, 0, 255], `${tag(m)}: the bottom screen is magenta`);
    }
  }
  // The console's gap is the stage's colour, not black.
  await setMode(page, { layout: "stack", swap: false, rot: 0, gap: "console" });
  const [gap] = await canvasAt(page, [[0.5, (192 + 45) / 474]]);
  const stage = await page.evaluate(() => ndsStageRgb().map((v) => Math.round(v * 255)));
  assert.deepEqual(gap, stage, "the gap is painted the stage's colour");
  // The filters still draw a turned screen (a flat colour stays flat).
  await page.evaluate(() => { upscaleFilter = "xbr"; updateCanvasScaling(); });
  await setMode(page, { layout: "focus", swap: true, rot: 3, gap: "hinge" });
  const [mid] = await canvasAt(page, [await page.evaluate(() => {
    const r = canvasEl.getBoundingClientRect(), p = NdsUtil.clientPoint("bottom", 128, 96, r, ndsLay);
    return [(p[0] - r.left) / r.width, (p[1] - r.top) / r.height];
  })]);
  assert.deepEqual(mid, [255, 0, 255], "xBR, turned, in Focus");
  assert.deepEqual(errors, []);
  await ctx.close();
});

test("the pointer touches the bottom-screen pixel under it in every arrangement", { skip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 800 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, rom("fb_both.nds"));
  await framesPast(page, 5);
  // What reaches the core (the stylus test above shows set_touch reaching the game).
  await page.evaluate(() => {
    window.__touches = [];
    const real = ndsCore._nds_set_touch;
    ndsCore._nds_set_touch = (x, y, d) => { window.__touches.push([x, y, d]); real(x, y, d); };
  });
  for (const m of MODES) {
    await setMode(page, m);
    for (const P of [[100, 80], [3, 188], [252, 4]]) {
      const at = await page.evaluate((P) =>
        NdsUtil.clientPoint("bottom", P[0], P[1], canvasEl.getBoundingClientRect(), ndsLay), P);
      await page.evaluate(() => { window.__touches = []; });
      if (!at) {
        // One screen showing the top: a click there touches nothing.
        const r = await page.evaluate(() => { const b = canvasEl.getBoundingClientRect();
                                              return [b.left + b.width / 2, b.top + b.height / 2]; });
        await page.mouse.click(r[0], r[1]);
        assert.deepEqual(await page.evaluate(() => window.__touches), [], tag(m));
        await page.evaluate(() => setNdsDisplay({ swap: false })); // the tap swapped
        break;
      }
      await page.mouse.move(at[0], at[1]);
      await page.mouse.down();
      await page.mouse.up();
      const got = await page.evaluate(() => window.__touches);
      assert.deepEqual(got[0], [P[0], P[1], 1], `${tag(m)} at ${P}`);
    }
  }
  assert.deepEqual(errors, []);
  await ctx.close();
});

// The rule for the touch controls: they never change size or place; only
// the screens take or give room.
const ctlRects = (page) => page.evaluate(async () => {
  // Past the controls' entrance (they rise into place as a game opens).
  await Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {})));
  return ["controls", "dpad", "ab", "lr", "select-start"].map((id) => {
    const r = document.getElementById(id).getBoundingClientRect();
    return [id, Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)];
  });
});
const boxes = (page) => page.evaluate(() => {
  const g = (el) => { const r = el.getBoundingClientRect();
                      return { l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height }; };
  return { canvas: g(canvasEl), stage: g(stageEl), bar: g(document.getElementById("topbar")),
           controls: g(document.getElementById("controls")),
           dpad: g(document.getElementById("dpad")), ab: g(document.getElementById("ab")),
           select: g(document.getElementById("select")), start: g(document.getElementById("start")) };
});

for (const vp of [{ width: 375, height: 812 }, { width: 390, height: 844 }]) {
  test(`phone upright ${vp.width}x${vp.height}: the bar hides for the screens, the controls never move`,
    { skip }, async () => {
      const ctx = await browser.newContext({ viewport: vp, isMobile: true, hasTouch: true,
                                             deviceScaleFactor: 2, serviceWorkers: "block" });
      const { page, errors } = await newPage(ctx);
      await addGame(page, rom("fb_both.nds"));
      await framesPast(page, 5);
      await setMode(page, { layout: "stack", swap: false, rot: 0, gap: "hinge" });
      await page.evaluate(() => setNdsDisplay({ barHide: false }));
      await sleep(300);
      const ref = await ctlRects(page);
      const shown = await boxes(page);
      assert.ok(shown.bar.b > 40, "the bar is on screen");
      // Select and Start are small circles, hit past their edge and on the
      // label under them; L and R are short.
      const small = await page.evaluate(() => {
        const at = (id, dx, dy) => { const r = document.getElementById(id).getBoundingClientRect();
                                     return document.elementFromPoint(r.left + r.width / 2 + dx, r.bottom + dy)?.id; };
        const sel = document.getElementById("select").getBoundingClientRect();
        return { w: sel.width, h: sel.height, label: at("select", 0, 10), side: at("start", 18, -14),
                 l: document.getElementById("l").getBoundingClientRect().height };
      });
      assert.deepEqual(small, { w: 28, h: 28, label: "select", side: "start", l: 28 });
      await page.evaluate(() => setNdsDisplay({ barHide: true }));
      await sleep(400);
      const hidden = await boxes(page);
      assert.ok(hidden.bar.b <= 0.5, "the bar went off the top: " + hidden.bar.b);
      assert.ok(hidden.canvas.h > shown.canvas.h + 20, `the screens grew: ${shown.canvas.h} -> ${hidden.canvas.h}`);
      for (const m of MODES) {
        await setMode(page, m);
        assert.deepEqual(await ctlRects(page), ref, `${tag(m)}: the controls stay put`);
        const b = await boxes(page);
        assert.ok(b.canvas.b <= b.controls.t + 0.5 && b.canvas.t >= b.stage.t - 0.5 &&
                  b.canvas.l >= -0.5 && b.canvas.r <= vp.width + 0.5, `${tag(m)}: the screens fit the stage`);
      }
      // A tap on the top screen brings the bar back over the stage, and
      // another takes it away; a tap on the touch screen is the game's.
      await setMode(page, { layout: "stack", swap: false, rot: 0, gap: "hinge" });
      await sleep(300);
      const tapAt = async (screen) => {
        const at = await page.evaluate((sc) => NdsUtil.clientPoint(sc, 128, 96,
          canvasEl.getBoundingClientRect(), ndsLay), screen);
        await page.touchscreen.tap(at[0], at[1]);
        await sleep(350);
      };
      await tapAt("bottom");
      assert.ok((await boxes(page)).bar.b <= 0.5, "the touch screen leaves the bar alone");
      await tapAt("top");
      assert.ok((await boxes(page)).bar.t >= -0.5, "pulled down");
      assert.deepEqual(await ctlRects(page), ref);
      await tapAt("top");
      assert.ok((await boxes(page)).bar.b <= 0.5, "and away");
      assert.deepEqual(errors, []);
      await ctx.close();
    });
}

test("phone sideways: every arrangement stays clear of the control rails", { skip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 844, height: 390 }, isMobile: true,
                                         hasTouch: true, deviceScaleFactor: 2, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, rom("fb_both.nds"));
  await framesPast(page, 5);
  const ref = await ctlRects(page);
  for (const m of MODES) {
    await setMode(page, m);
    assert.deepEqual(await ctlRects(page), ref, `${tag(m)}: the controls stay put`);
    const b = await boxes(page);
    assert.ok(b.canvas.l >= b.dpad.r - 0.5 && b.canvas.r <= b.ab.l + 0.5,
              `${tag(m)}: between the d-pad and the face buttons`);
    const apart = (p, q) => p.r <= q.l + 0.5 || q.r <= p.l + 0.5 || p.b <= q.t + 0.5 || q.b <= p.t + 0.5;
    assert.ok(apart(b.canvas, b.select) && apart(b.canvas, b.start), `${tag(m)}: clear of Select and Start`);
  }
  assert.deepEqual(errors, []);
  await ctx.close();
});

test("the lid closes and opens, and the microphone and Blow reach the core", { skip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 800 }, serviceWorkers: "block",
                                         permissions: ["microphone"] });
  const { page, errors } = await newPage(ctx);
  await addGame(page, rom("fb_both.nds"));
  await framesPast(page, 5);
  assert.equal(await page.evaluate(() => typeof ndsCore._nds_set_lid + typeof ndsCore._nds_push_mic),
               "functionfunction", "the core exports both");
  await page.keyboard.press("KeyN");
  assert.equal(await page.locator("#nds-lid-open").isVisible(), true, "closed: the screens dim");
  await page.locator("#nds-lid-open").click();
  assert.equal(await page.locator("#nds-lid-open").isVisible(), false, "a tap opened it");
  await page.evaluate(() => {
    window.__mic = [];
    const real = ndsCore._nds_push_mic;
    ndsCore._nds_push_mic = (p, n, rate) => { window.__mic.push([n, rate]); real(p, n, rate); };
  });
  // Blow, held from the keyboard: a frame's noise at 16 kHz before each frame.
  await page.keyboard.down("KeyH");
  await sleep(800);
  await page.keyboard.up("KeyH");
  const blown = await page.evaluate(() => window.__mic.splice(0));
  assert.ok(blown.length >= 3 && blown.every(([n, r]) => r === 16000 && n === 268),
            "blown: " + JSON.stringify(blown.slice(0, 3)) + " x" + blown.length);
  await sleep(100);
  assert.equal(await page.evaluate(() => window.__mic.length), 0, "and no more once let go");
  // The microphone (Chromium's fake device), from the Screens panel.
  await page.locator("#nds-layout-btn").click();
  await page.locator('#nds-panel [data-nds-action="mic"]').click();
  await until(page, () => window.__mic.length > 5).catch(async (e) => {
    throw new Error(e.message + " " + JSON.stringify(await page.evaluate(() => [!!ndsMic,
      ndsMic && ndsMic.ctx.state, paused, ndsBlowers.size, window.__mic.length, ndsPanelOpen])));
  });
  const heard = await page.evaluate(() => ({ calls: window.__mic.slice(0, 3), rate: ndsMic.ctx.sampleRate,
    pressed: document.querySelector('#nds-panel [data-nds-action="mic"]').getAttribute("aria-pressed") }));
  assert.ok(heard.calls.every(([n, r]) => n === 1024 && r === heard.rate), JSON.stringify(heard));
  assert.equal(heard.pressed, "true");
  await page.locator('#nds-panel [data-nds-action="mic"]').click();
  assert.equal(await page.evaluate(() => ndsMic), null, "off again");
  assert.deepEqual(errors, []);
  await ctx.close();
});

// Until an async check in the page holds (waitForFunction does not await).
const until = async (page, fn, arg, ms = 15000) => {
  const end = Date.now() + ms;
  for (;;) {
    if (await page.evaluate(fn, arg)) return;
    if (Date.now() > end) throw new Error("timed out: " + fn);
    await sleep(250);
  }
};

test("the core's sound is the tone the ROM plays", { skip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, rom("snd_tone.nds"));
  await framesPast(page, 20);
  // snd_tone: a square left and a saw right, from the first frames.
  const peak = await page.evaluate(() => {
    paused = true;
    ndsCore._nds_audio_clear();
    ndsCore._nds_run_frame();
    const n = ndsCore._nds_audio_frames();
    const s = new Float32Array(ndsCore.HEAPU8.buffer, ndsCore._nds_audio_ptr(), n * 2);
    let l = 0, r = 0;
    for (let i = 0; i < n; i++) { l = Math.max(l, Math.abs(s[2 * i])); r = Math.max(r, Math.abs(s[2 * i + 1])); }
    ndsCore._nds_audio_clear();
    return { n, l, r };
  });
  assert.ok(peak.n > 500 && peak.n < 600, "a frame's samples (32728.5 / 59.83): " + peak.n);
  assert.ok(peak.l > 0.01 && peak.r > 0.01, "both channels sound: " + JSON.stringify(peak));
  assert.deepEqual(errors, []);
  await ctx.close();
});

// A libnds ROM (it waits for V-blank, so frames are cheap): the bare-metal
// ones spin both CPUs flat out and run slower than realtime in wasm.
test("sound flows to the app's audio graph, paced by its clock", { skip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, rom("built/simple.nds"));
  await page.waitForFunction(() => ndsOut && ndsOut.stats().state === "running" &&
                                    ndsOut.stats().sent > 16000, null, { timeout: 30000 });
  const a = await page.evaluate(() => ({ s: ndsOut.stats(), f: ndsCore._nds_frame_count(),
                                         t: performance.now() }));
  await sleep(3000);
  const b = await page.evaluate(() => ({ s: ndsOut.stats(), f: ndsCore._nds_frame_count(),
                                         t: performance.now() }));
  const secs = (b.t - a.t) / 1000;
  const rate = (b.s.sent - a.s.sent) / secs;
  const fps = (b.f - a.f) / secs;
  console.log(`  audio ${rate.toFixed(0)} frames/s, ${fps.toFixed(1)} fps, ` +
              `underruns ${b.s.underruns}, fill ${(b.s.fill / 32.7285).toFixed(0)} ms`);
  // Realtime: the core's 32728.5 Hz, give or take what the pacing smooths.
  assert.ok(rate > 30000 && rate < 35500, "audio at the core's rate: " + rate);
  assert.ok(fps > 54 && fps < 66, "frames at ~59.8 fps: " + fps);
  assert.deepEqual(errors, []);
  await ctx.close();
});

test("a battery save the game wrote is there after a reload", { skip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  // The card's chip, blank (512 bytes: a 0.5K EEPROM), as a new cart has it.
  await page.evaluate(() => dbPut("save:save_write.nds", new Uint8Array(512).fill(0xFF)));
  await addGame(page, rom("save_write.nds"));
  await framesPast(page, 30);
  // The 5 s autosave picks the write up.
  await until(page, async () => (await dbGet("save:save_write.nds"))?.[3] === 1);
  // A new page: the game from its library tile, booting on the stored save.
  // With DS save states the tile would resume the last session instead
  // (stateauto:, as for GB/GBA), so that snapshot goes first: this is about
  // a second boot reading the battery save.
  await page.reload();
  await page.waitForFunction(() => document.body.classList.contains("runtime-ready"),
                             null, { timeout: 30000 });
  await page.evaluate(() => dbDelete(autoStateKey("save_write.nds")));
  await page.locator(".home-tile, #hero-shot").locator("visible=true").first().click();
  await running(page);
  await framesPast(page, 30);
  await until(page, async () => (await dbGet("save:save_write.nds"))?.[3] === 2);
  // The game saw its first boot's save: the backdrop is blue (second boot).
  const [px] = await canvasAt(page, [[0.25, 0.25]]);
  assert.deepEqual(px, [0, 0, 255], "the game read back count 1, wrote 2: " + px);
  const saved = await page.evaluate(async () => [...(await dbGet("save:save_write.nds")).slice(0, 8)]);
  assert.deepEqual(saved.slice(0, 4), [0x44, 0x47, 0x42, 2]);
  assert.deepEqual(errors, []);
  await ctx.close();
});

test("an imported .dsv save loses its footer: the game reads it, the app stores the raw chip",
     { skip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  page.on("dialog", (d) => d.accept()); // the import's "overwrite?" questions
  await addGame(page, rom("save_write.nds"));
  await framesPast(page, 10);
  // save_write's chip with boot count 5, as a .dsv: the 512-byte image, then
  // the text footer (docs/nds/saves.md).
  const img = new Uint8Array(512).fill(0xFF);
  img.set([0x44, 0x47, 0x42, 5]);
  for (let i = 4; i < 8; i++) img[i] = ((5 ^ 0xA5) + i) & 0xFF;
  const foot = new TextEncoder().encode(
    "|<--Snip above here to create a raw sav by excluding this savedata footer:" +
    "\0".repeat(24) + "|-SAVE-|");
  const dsv = new Uint8Array(img.length + foot.length);
  dsv.set(img); dsv.set(foot, img.length);
  await page.locator("#menu-btn").click();
  await page.locator("#manage-saves").click();
  const [chooser] = await Promise.all([page.waitForEvent("filechooser"),
                                       page.locator("#load-save").click()]);
  await chooser.setFiles({ name: "save_write.dsv", mimeType: "application/octet-stream",
                           buffer: Buffer.from(dsv) });
  // The reboot: the game reads count 5 and writes 6; the app stores the chip.
  await until(page, async () => (await dbGet("save:save_write.nds"))?.[3] === 6, null, 30000);
  const saved = await page.evaluate(async () => (await dbGet("save:save_write.nds")).length);
  assert.equal(saved, 512, "stored as the 512-byte chip, footer gone");
  const [px] = await canvasAt(page, [[0.25, 0.25]]);
  assert.deepEqual(px, [255, 255, 255], "the game read count 5 (white: a later boot): " + px);
  assert.deepEqual(errors, []);
  await ctx.close();
});

test("a save state taken in the app resumes the same frames and sound", { skip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, rom("snd_tone.nds"));
  await framesPast(page, 60);
  const r = await page.evaluate(() => {
    paused = true;
    // 20 frames from here: the frame counter, both screens and the sound.
    const run = () => {
      ndsCore._nds_audio_clear();
      for (let i = 0; i < 20; i++) ndsCore._nds_run_frame();
      const a = ndsCore._nds_audio_ptr(), n = ndsCore._nds_audio_frames() * 2;
      const t = ndsCore._nds_fb_top(), b = ndsCore._nds_fb_bottom();
      return { frame: ndsCore._nds_frame_count(), n,
               audio: Array.from(new Float32Array(ndsCore.HEAPU8.buffer, a, n)),
               top: Array.from(ndsCore.HEAPU8.subarray(t, t + 256 * 192 * 4)).join(),
               bottom: Array.from(ndsCore.HEAPU8.subarray(b, b + 256 * 192 * 4)).join() };
    };
    const state = captureStateBytes();
    const first = run();
    const ok = applyStateBytes(state);
    const again = run();
    return { size: state?.length ?? 0, ok, first, again };
  });
  assert.ok(r.size > 0, "the app captured a DS state");
  assert.equal(r.ok, true, "the app applied it");
  assert.ok(r.first.n > 0, "the tone produced sound");
  assert.equal(r.again.frame, r.first.frame);
  assert.deepEqual(r.again.audio, r.first.audio, "the same sound after the load");
  assert.ok(r.again.top === r.first.top && r.again.bottom === r.first.bottom, "the same screens");
  assert.deepEqual(errors, []);
  await ctx.close();
});

// A slot and a checkpoint (the moments a crash leaves, and the session) are
// packed by the checkpoint worker, off the frame's thread; the undo a load
// keeps stays plain. And a checkpoint taken while a DS game runs is that
// game's: the GB/GBA core still holds the game played before it, whose
// state once went in as the DS game's checkpoint and session.
test("a DS game's slot, undo and checkpoint are its own states, packed off the page", { skip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  const gba = join(WEB, "..", "tests/roms/bootio.gba");
  const [chooser] = await Promise.all([
    page.waitForEvent("filechooser"),
    page.locator("#home-load, #lib-add, #home-solo-add").locator("visible=true").first().click(),
  ]);
  await chooser.setFiles(gba);
  await page.waitForFunction(() => document.body.classList.contains("running") &&
    currentOriginalName === "bootio.gba" && !paused, null, { timeout: 60000 });
  await page.evaluate(() => document.getElementById("main-menu").click());
  await addGame(page, rom("snd_tone.nds"));
  await framesPast(page, 60);
  const r = await page.evaluate(async () => {
    paused = true;
    const name = currentOriginalName;
    const run = () => {
      for (let i = 0; i < 20; i++) { ndsCore._nds_run_frame(); ndsCore._nds_audio_clear(); }
      const t = ndsCore._nds_fb_top(), b = ndsCore._nds_fb_bottom();
      return ndsCore._nds_frame_count() + ":" +
        Array.from(ndsCore.HEAPU8.subarray(t, t + 256 * 192 * 4)).join() +
        Array.from(ndsCore.HEAPU8.subarray(b, b + 256 * 192 * 4)).join();
    };
    const saved = await saveToSlot(1);
    const slot = await dbGet(slotStateKey(name, 1));
    const first = run();
    const loaded = await loadFromSlot(1);
    const again = run();
    const undo = stateUndoBytes;
    undoStateLoad();
    const undone = ndsCore._nds_frame_count();
    takeCheckpoint();
    await checkpointLanded();
    const ck = await dbGet(ckptKey(name, 0));
    const session = await dbGet(autoStateKey(name));
    return { saved, loaded, same: first === again, firstFrame: +first.split(":")[0], undone,
             slotCore: slot?.[12], slotPacked: !!(slot?.[15] & 0x80),
             undoPacked: !!(undo?.[15] & 0x80), undoCore: undo?.[12],
             ckCore: ck?.bytes?.[12], ckPacked: !!(ck?.bytes?.[15] & 0x80),
             ckLoads: !!ck?.bytes && applyStateBytes(ck.bytes),
             sessionCore: session?.bytes?.[12] };
  });
  assert.equal(r.saved, true, "slot 1 saved");
  assert.equal(r.slotCore, 2, "the slot holds a DS state");
  assert.equal(r.slotPacked, true, "packed (by the worker)");
  assert.equal(r.loaded, true, "slot 1 loaded");
  assert.ok(r.same, "the same 20 frames after the load");
  assert.equal(r.undoCore, 2);
  assert.equal(r.undoPacked, false, "the undo is kept plain");
  assert.equal(r.undone, r.firstFrame, "Undo goes back to before the load");
  assert.equal(r.ckCore, 2, "the checkpoint is the DS game's state, not the GBA game's");
  assert.equal(r.ckPacked, true);
  assert.equal(r.ckLoads, true, "and it loads");
  assert.equal(r.sessionCore, 2, "so is the session it leaves");
  assert.deepEqual(errors, []);
  await ctx.close();
});

// --- Power-off and the firmware (fw_power: tests/nds/tools/build_fw_power.sh).
// Each boot the ROM writes the firmware's nickname "FWTEST<n>" (n one more
// than the one it finds) and paints the top screen green (n = 1), blue
// (n = 2) or white; the bottom is yellow while it runs. START powers it off.
const FW_ROM = rom("fw_power.nds");
const fwSkip = skip || (existsSync(FW_ROM) ? false : "missing: fw_power.nds");
const SHOTS = process.env.DINGBAT_E2E_SHOTS; // a directory: screenshots of the new states
const shot = async (page, name) => { if (SHOTS) await page.screenshot({ path: join(SHOTS, name) }); };
const GREEN = [0, 255, 0], BLUE = [0, 0, 255], YELLOW = [255, 255, 0], BLACK = [0, 0, 0];
const screensAre = (page, top, bottom) => until(page, async ([top, bottom]) => {
  drawGame();
  const c = document.createElement("canvas");
  c.width = canvasEl.width; c.height = canvasEl.height;
  const ctx = c.getContext("2d");
  ctx.drawImage(canvasEl, 0, 0);
  const at = (fy) => [...ctx.getImageData(Math.floor(0.5 * c.width), Math.floor(fy * c.height), 1, 1).data].slice(0, 3);
  return JSON.stringify([at(0.25), at(0.75)]) === JSON.stringify([top, bottom]);
}, [top, bottom], 20000);
const fwName = (page) => page.evaluate(async () => {
  const rec = await dbGet("bios:ndsflash");
  return rec ? NdsUtil.fwReadUser(new Uint8Array(rec.data)).name : null;
});

test("a game that switches the DS off is shown off, and Restart switches it on", { skip: fwSkip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, FW_ROM);
  await page.evaluate(() => setNdsLayout("stack"));
  await screensAre(page, GREEN, YELLOW);
  // START: the ROM writes power manager register 0 bit 6.
  await page.keyboard.down("Enter");
  await page.waitForFunction(() => document.body.classList.contains("nds-off"), null, { timeout: 10000 });
  await page.keyboard.up("Enter");
  assert.equal(await page.locator("#nds-off").isVisible(), true);
  assert.match(await page.locator("#nds-off").innerText(), /The game turned the DS off/);
  await screensAre(page, BLACK, BLACK);
  await shot(page, "nds-off.png");
  // Nothing runs; the session to resume is gone; no state can be saved.
  const f0 = await page.evaluate(() => ndsCore._nds_frame_count());
  await sleep(400);
  assert.equal(await page.evaluate(() => ndsCore._nds_frame_count()), f0, "no frames while off");
  assert.equal(await page.evaluate(() => captureStateBytes()), null);
  await until(page, async () => !(await dbGet(autoStateKey("fw_power.nds"))));
  // Restart: on again. The flash kept what the first boot wrote (count 2).
  await page.locator("#nds-off-restart").click();
  await page.waitForFunction(() => !document.body.classList.contains("nds-off") &&
                                   ndsCore._nds_frame_count() > 5, null, { timeout: 10000 });
  assert.equal(await page.locator("#nds-off").isVisible(), false);
  await screensAre(page, BLUE, YELLOW);
  // Off again, then back to the library: the game closes.
  await page.keyboard.down("Enter");
  await page.waitForFunction(() => document.body.classList.contains("nds-off"), null, { timeout: 10000 });
  await page.keyboard.up("Enter");
  await page.locator("#nds-off-library").click();
  await page.waitForFunction(() => !document.body.classList.contains("running") && ndsCoreGame === null,
                             null, { timeout: 10000 });
  assert.equal(await page.evaluate(() => currentRomName), null);
  assert.deepEqual(errors, []);
  await ctx.close();
});

test("firmware settings a game wrote come back after a reload, and Settings edits them",
     { skip: fwSkip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, FW_ROM);
  await page.evaluate(() => setNdsLayout("stack"));
  await screensAre(page, GREEN, YELLOW); // the first boot found no FWTEST name
  // The 5 s autosave stores the flash the game wrote.
  await until(page, async () => {
    const rec = await dbGet("bios:ndsflash");
    return rec && NdsUtil.fwReadUser(new Uint8Array(rec.data)).name === "FWTEST1";
  });
  // A new page, the game from its tile (its resume snapshot dropped: this is
  // about a boot reading the firmware): it finds FWTEST1 and writes FWTEST2.
  await page.reload();
  await page.waitForFunction(() => document.body.classList.contains("runtime-ready"),
                             null, { timeout: 30000 });
  await page.evaluate(() => dbDelete(autoStateKey("fw_power.nds")));
  await page.locator(".home-tile, #hero-shot").locator("visible=true").first().click();
  await running(page);
  await page.evaluate(() => setNdsLayout("stack"));
  await screensAre(page, BLUE, YELLOW);
  await until(page, async () => {
    const rec = await dbGet("bios:ndsflash");
    return rec && NdsUtil.fwReadUser(new Uint8Array(rec.data)).name === "FWTEST2";
  });
  // Settings > Nintendo DS shows it, and an edit reaches the game's next boot.
  await page.locator("#menu-btn").click();
  await page.locator("#open-settings").click();
  await page.evaluate(() => selectSettingsTab("ds"));
  await page.waitForFunction(() => document.getElementById("nds-user-name").textContent === "FWTEST2",
                             null, { timeout: 10000 });
  assert.match(await page.locator("#nds-user-source").innerText(), /Changed by a game/);
  await page.locator("#nds-user").scrollIntoViewIfNeeded();
  await shot(page, "nds-settings-console.png");
  await page.locator("#nds-user-edit").click();
  await page.locator("#nds-user-name-in").fill("Matt");
  await page.locator("#nds-user-month").selectOption("7");
  await page.locator("#nds-user-day").selectOption("14");
  await page.locator("#nds-user-lang-in").selectOption("2");
  await shot(page, "nds-settings-edit.png");
  await page.locator("#nds-user-save").click();
  await page.waitForFunction(() => document.getElementById("nds-user-name").textContent === "Matt",
                             null, { timeout: 10000 });
  assert.equal(await page.locator("#nds-user-birthday").innerText(), "14 July");
  assert.equal(await page.locator("#nds-user-lang").innerText(), "French");
  assert.equal(await fwName(page), "Matt");
  await shot(page, "nds-settings-edited.png");
  // Reset in place (the game's flash took the edit): no FWTEST name, count 1.
  await page.keyboard.press("Escape");
  await page.evaluate(() => document.getElementById("reset").click());
  await screensAre(page, GREEN, YELLOW);
  await until(page, async () => {
    const rec = await dbGet("bios:ndsflash");
    const u = rec && NdsUtil.fwReadUser(new Uint8Array(rec.data));
    return u && u.name === "FWTEST1" && u.month === 7 && u.lang === 2;
  });
  assert.deepEqual(errors, []);
  await ctx.close();
});

// --- Rewind, run-ahead and cheats (docs/nds/features.md) ----------------------
// Double_Buffer (libnds example) changes its screens every other frame.
// cheat_probe (tests/nds/tools/build_fb.sh) fills its top screen with the
// halfword at 0x02100000 every V-blank: red until a cheat writes it.
const MOVER = rom("built/Double_Buffer.nds");
const PROBE = rom("cheat_probe.nds");
const featSkip = skip || ([MOVER, PROBE].filter((p) => !existsSync(p)).map((p) => "missing: " + p)[0] ?? false);

// In the page: the frame counter, an FNV-1a of both screens as the presenter
// reads them (nds_fb555_*) and one of the sound the last frame made.
const HASHERS = () => {
  window.e2eSig = () => {
    const c = ndsCore;
    const fnv = (a, h = 0x811c9dc5) => {
      for (let i = 0; i < a.length; i++) h = Math.imul(h ^ a[i], 16777619);
      return h >>> 0;
    };
    let scr = 0x811c9dc5;
    for (const p of [c._nds_fb555_top(), c._nds_fb555_bottom()]) {
      scr = fnv(new Uint16Array(c.HEAPU8.buffer, p, 256 * 192), scr);
    }
    const n = c._nds_audio_frames();
    const snd = n > 0 ? fnv(new Uint32Array(c.HEAPU8.buffer, c._nds_audio_ptr(), n * 2)) : 0;
    return { f: c._nds_frame_count(), scr, snd };
  };
};

test("rewind on a DS game: held, it steps back through moments that happened", { skip: featSkip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, MOVER);
  await framesPast(page, 30);
  assert.equal(await page.evaluate(() => document.body.classList.contains("nds-rewind")), true);
  assert.equal(await page.locator("#rewind").isVisible(), true, "the rewind button is shown");
  await page.evaluate(HASHERS);
  const r = await page.evaluate(() => {
    paused = true;
    const c = ndsCore;
    c._nds_rewind_enable(0, 0);
    c._nds_rewind_enable(1, 0); // an empty ring from here
    const seen = {};
    for (let i = 0; i < 100; i++) {
      c._nds_run_frame();
      const s = e2eSig();
      seen[s.f] = s;
      c._nds_audio_clear();
    }
    const last = c._nds_frame_count();
    const depth = c._nds_rewind_depth();
    for (let i = 0; i < 3; i++) c._nds_rewind_pop();
    const back = e2eSig(); // the screens of the frame the snapshot followed
    const again = [];      // and on from there: the frames that were
    for (let i = 0; i < 15; i++) {
      c._nds_run_frame();
      again.push([e2eSig(), seen[c._nds_frame_count()]]);
      c._nds_audio_clear();
    }
    return { last, depth, back, was: seen[back.f], again };
  });
  assert.ok(r.depth >= 9, "about one snapshot every 10 frames: " + r.depth);
  assert.ok(r.back.f <= r.last - 20, `three pops went back 20+ frames: ${r.back.f} from ${r.last}`);
  assert.equal(r.back.scr, r.was.scr, `the screens are frame ${r.back.f}'s`);
  for (const [now, was] of r.again) assert.deepEqual(now, was, `frame ${now.f} replays as it was`);
  // Through the app: held, the frame counter runs backwards.
  await page.evaluate(() => { paused = false; });
  await framesPast(page, (await page.evaluate(() => ndsCore._nds_frame_count())) + 60);
  const before = await page.evaluate(() => ndsCore._nds_frame_count());
  const box = await page.locator("#rewind").boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await sleep(500);
  const during = await page.evaluate(() => ndsCore._nds_frame_count());
  await page.mouse.up();
  assert.ok(during < before - 20, `held for 0.5 s it went back: ${during} from ${before}`);
  await framesPast(page, during + 20);
  // Off in Settings: the ring goes, the button with it.
  await page.evaluate(() => { rewindToggle.checked = false; rewindToggle.dispatchEvent(new Event("change")); });
  await page.waitForFunction(() => ndsCore._nds_rewind_depth() === 0, null, { timeout: 5000 });
  assert.equal(await page.locator("#rewind").isVisible(), false);
  assert.deepEqual(errors, []);
  await ctx.close();
});

test("the rewind scrubber and Report a Bug's timeline show a DS game's moments", { skip: featSkip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, MOVER);
  await framesPast(page, 30);
  // Five seconds of moments, a thumbnail of both screens each second.
  const at = await page.evaluate(() => {
    paused = true;
    const c = ndsCore;
    c._nds_rewind_enable(0, 0);
    c._nds_rewind_enable(1, 0);
    for (let i = 0; i < 300; i++) { c._nds_run_frame(); c._nds_audio_clear(); }
    return c._nds_frame_count();
  });
  await page.evaluate(() => { paused = false; openRewindScrubber(); });
  assert.equal(await page.locator("#rewind-modal").evaluate((m) => m.classList.contains("open")), true,
               "the scrubber opens for a DS game");
  const strip = await page.evaluate(() => {
    rwStrip.setValue(0, rwStrip.samples - 1, true);
    const pv = document.getElementById("rewind-preview");
    return { n: rwStrip.samples, w: pv.width, h: pv.height, when: rwWhen.textContent,
             frames: ndsCore._nds_frame_count() };
  });
  assert.ok(strip.n >= 4, "a strip of moments: " + strip.n);
  assert.deepEqual([strip.w, strip.h], [80, 120], "each one both screens, upright");
  assert.match(strip.when, /s ago$/);
  assert.equal(strip.frames, at, "the game held still while the strip was open");
  await page.locator("#rewind-commit").click();
  await page.locator("#rewind-commit").click();
  const back = await page.evaluate(() => ndsCore._nds_frame_count());
  assert.ok(back <= at - 180, `committed to the oldest moment: frame ${back} from ${at}`);
  assert.equal(await page.locator("#rewind-modal").evaluate((m) => m.classList.contains("open")), false);
  const undone = await page.evaluate(() => {
    paused = true;
    rwUndoCommit();
    return ndsCore._nds_frame_count();
  });
  assert.equal(undone, at, "Undo puts the game back where it was");
  // Report a Bug: the same history, and the state of the moment picked.
  const report = await page.evaluate(() => {
    const c = ndsCore;
    for (let i = 0; i < 120; i++) { c._nds_run_frame(); c._nds_audio_clear(); }
    openReportModal();
    reportSlider.value = "0";
    reportSlider.dispatchEvent(new Event("input"));
    const n = reportSamples;
    const bytes = scrubApi().stateBytes(n - 1);
    const live = c._nds_frame_count();
    const head = bytes ? String.fromCharCode(...bytes.slice(0, 8)) : "";
    const ok = applyStateBytes(bytes);
    const was = c._nds_frame_count();
    closeReportModal();
    return { n, w: reportPreview.width, h: reportPreview.height, when: reportWhen.textContent,
             head, ok, live, was };
  });
  assert.ok(report.n >= 2, "the timeline has moments: " + report.n);
  assert.deepEqual([report.w, report.h], [80, 120]);
  assert.match(report.when, /s ago$/);
  assert.equal(report.head, "DGBSTATE", "the moment's state attaches");
  assert.ok(report.ok && report.was < report.live - 60, `and it is that moment: ${report.was} vs ${report.live}`);
  assert.deepEqual(errors, []);
  await ctx.close();
});

// Run from a state with and without run-ahead n: [plain, ahead] frames.
const aheadRuns = (page, n) => page.evaluate((n) => {
  paused = true;
  const c = ndsCore;
  c._nds_rewind_enable(0, 0);
  const state = captureStateBytes();
  const play = (ahead) => {
    applyStateBytes(state);
    c._nds_audio_clear();
    const own = [], shown = [];
    for (let i = 0; i < 90; i++) {
      c._nds_run_frame();
      own.push(e2eSig());
      c._nds_audio_clear();
      if (ahead) {
        c._nds_runahead(ahead);
        shown.push(e2eSig());
      }
    }
    return { own, shown };
  };
  return { plain: play(0), ahead: play(n) };
}, n);

test("run-ahead shows the frame n on, and leaves the game's own frames and sound as they were",
     { skip: featSkip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  // Double_Buffer: the screens change every other frame.
  await addGame(page, MOVER);
  await framesPast(page, 30);
  await page.evaluate(HASHERS);
  let r = await aheadRuns(page, 2);
  assert.ok(new Set(r.plain.own.map((s) => s.scr)).size > 40, "the screens change as it runs");
  assert.deepEqual(r.ahead.own, r.plain.own, "every frame as without run-ahead");
  for (let i = 0; i + 2 < 90; i++) {
    assert.equal(r.ahead.shown[i].scr, r.plain.own[i + 2].scr, `step ${i} shows frame ${i + 2}'s screens`);
    assert.equal(r.ahead.shown[i].f, r.plain.own[i].f, "the machine is back where it was");
  }
  // The tone: the sound is the sound there was, none of the lookahead's.
  // The app's Run-ahead choice reaches a DS game.
  await page.evaluate(() => { applyRunahead(1); paused = false; });
  await framesPast(page, (await page.evaluate(() => ndsCore._nds_frame_count())) + 30);
  await page.evaluate(() => applyRunahead(0));
  assert.deepEqual(errors, []);
  await ctx.close();
  const ctx2 = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const tone = await newPage(ctx2);
  await addGame(tone.page, rom("snd_tone.nds"));
  await framesPast(tone.page, 30);
  await tone.page.evaluate(HASHERS);
  r = await aheadRuns(tone.page, 3);
  assert.ok(r.plain.own.every((s) => s.snd !== 0), "the tone sounds every frame");
  assert.deepEqual(r.ahead.own, r.plain.own, "every frame and its sound as without run-ahead");
  assert.deepEqual(tone.errors, []);
  await ctx2.close();
});

const fillCheat = async (page, name, codes) => {
  await page.locator("#cheat-name").fill(name);
  await page.locator("#cheat-codes").fill(codes);
  await page.locator("#cheat-add").click();
};
const openCheats = (page) => page.evaluate(() => openCheatsModal());
const closeCheats = (page) => page.locator("#cheats-close").click();
const RED = [255, 0, 0], WHITE = [255, 255, 255], MAGENTA = [255, 0, 255];

test("Action Replay DS and CodeBreaker DS codes change the game, and stay with it", { skip: featSkip }, async () => {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 }, serviceWorkers: "block" });
  const { page, errors } = await newPage(ctx);
  await addGame(page, PROBE);
  await page.evaluate(() => setNdsLayout("stack"));
  await screensAre(page, RED, MAGENTA);
  assert.equal(await page.evaluate(() => document.body.classList.contains("nds-cheats")), true);
  await page.locator("#menu-btn").click();
  await page.locator("#open-cheats").click();
  await page.waitForFunction(() => document.getElementById("cheats-modal").classList.contains("open"));
  assert.match(await page.locator("#cheat-format-hint").innerText(), /Action Replay DS/);
  // What the engine refuses says why and is not added.
  await fillCheat(page, "self", "C4000000 00000000");
  assert.match(await page.locator("#cheat-error").innerText(), /C4/);
  await fillCheat(page, "junk", "0210000 1234");
  assert.match(await page.locator("#cheat-error").innerText(), /hex/);
  // AR: a word write. Blue.
  await fillCheat(page, "Blue", "02100000 00007C00");
  await closeCheats(page);
  await screensAre(page, BLUE, MAGENTA);
  // AR: IF A held (KEYINPUT bit 0 clear) THEN green ENDIF; later in the
  // list, so it wins while A is down.
  await openCheats(page);
  await fillCheat(page, "Green on A", "94000130 FFFE0000\n12100000 000003E0\nD0000000 00000000");
  await closeCheats(page);
  await page.evaluate(() => ndsCore._nds_set_button(0, 1));
  await screensAre(page, GREEN, MAGENTA);
  await page.evaluate(() => ndsCore._nds_set_button(0, 0));
  await screensAre(page, BLUE, MAGENTA);
  // AR: the data register summed in a loop (7 x 1249h = 7FFFh), then
  // written at the offset register. White.
  await openCheats(page);
  await fillCheat(page, "White by loop", "D5000000 00000000\nC0000000 00000006\n" +
    "D4000000 00001249\nD1000000 00000000\nD3000000 02100000\nD7000000 00000000");
  await closeCheats(page);
  await screensAre(page, WHITE, MAGENTA);
  // CodeBreaker DS: the unencrypted header (the header CRC, the game code),
  // then a halfword write. Last in the list: yellow.
  const hdr = readFileSync(PROBE);
  const crc = hdr.readUInt16LE(0x15E).toString(16).toUpperCase().padStart(4, "0");
  const code = hdr.readUInt32BE(0x0C).toString(16).toUpperCase().padStart(8, "0");
  await openCheats(page);
  await fillCheat(page, "CB yellow", `8000${crc} ${code}\n12100000 000003FF`);
  assert.equal(await page.locator("#cheat-error").isVisible(), false, "the CodeBreaker list parsed");
  await closeCheats(page);
  await screensAre(page, YELLOW, MAGENTA);
  // Switched off in the list: the white is on top again.
  await openCheats(page);
  await page.locator("#cheats-list .cheat-row input[type=checkbox]").nth(3).uncheck();
  await closeCheats(page);
  await screensAre(page, WHITE, MAGENTA);
  // The list is the game's: after a reload it is back, and running.
  await page.reload();
  await page.waitForFunction(() => document.body.classList.contains("runtime-ready"), null, { timeout: 30000 });
  await page.evaluate(() => dbDelete(autoStateKey("cheat_probe.nds")));
  await page.locator(".home-tile, #hero-shot").locator("visible=true").first().click();
  await running(page);
  await page.evaluate(() => setNdsLayout("stack"));
  await screensAre(page, WHITE, MAGENTA);
  assert.equal(await page.evaluate(() => cheatList.length), 4);
  await shot(page, "nds-cheats.png");
  assert.deepEqual(errors, []);
  await ctx.close();
});

const BENCH = process.env.DINGBAT_NDS_BENCH;
test("unpaced frame time of DINGBAT_NDS_BENCH", { skip: skip || !BENCH || !existsSync(BENCH || "") },
  async () => {
    const ctx = await browser.newContext({ viewport: { width: 1000, height: 800 }, serviceWorkers: "block" });
    const { page } = await newPage(ctx);
    await addGame(page, BENCH, BENCH.split("/").pop());
    await framesPast(page, 600); // past the boot, into the title
    const r = await page.evaluate(() => {
      paused = true;
      const runs = [ndsBench(300), ndsBench(300), ndsBench(300)];
      return { runs, heapMB: ndsCore.HEAPU8.length / 1048576, frame: ndsCore._nds_frame_count() };
    });
    console.log(`  ${BENCH.split("/").pop()}: ${r.runs.map((m) => m.toFixed(2)).join(", ")} ms/frame ` +
                `(${(1000 / Math.min(...r.runs)).toFixed(0)} fps unpaced) at frame ${r.frame}, ` +
                `wasm heap ${r.heapMB.toFixed(0)} MB`);
    await ctx.close();
  });

// The same game (local only: commercial ROMs never go in the repo): from
// frame 1500, 300 frames plain, with run-ahead 1 and with run-ahead 3 plus
// the rewind ring must be the same frames and sound; the run-ahead frame
// shown is the next one; after 5 rewind pops the next 40 frames replay as
// they were. Then what rewind and run-ahead cost (docs/nds/features.md).
test("run-ahead and rewind leave DINGBAT_NDS_BENCH's frames as they were, and what they cost",
  { skip: skip || !BENCH || !existsSync(BENCH || "") }, async () => {
    const ctx = await browser.newContext({ viewport: { width: 1000, height: 800 }, serviceWorkers: "block" });
    const { page, errors } = await newPage(ctx);
    await addGame(page, BENCH, BENCH.split("/").pop());
    await page.evaluate(HASHERS);
    const r = await page.evaluate(() => {
      paused = true;
      const c = ndsCore;
      c._nds_rewind_enable(0, 0);
      for (let i = 0; i < 1500; i++) { c._nds_run_frame(); c._nds_audio_clear(); }
      const key = (s) => `${s.f}:${s.scr}:${s.snd}`;
      const state = captureStateBytes();
      const play = (ahead, ring) => {
        applyStateBytes(state);
        c._nds_rewind_enable(ring ? 1 : 0, 0);
        c._nds_audio_clear();
        const own = [], shown = [];
        for (let i = 0; i < 300; i++) {
          c._nds_run_frame();
          own.push(key(e2eSig()));
          c._nds_audio_clear();
          if (ahead) { c._nds_runahead(ahead); shown.push(e2eSig().scr); }
        }
        return { own, shown };
      };
      const plain = play(0, false), a1 = play(1, false), a3 = play(3, true);
      const seen = Object.fromEntries(a3.own.map((k) => [k.split(":")[0], k]));
      for (let i = 0; i < 5; i++) c._nds_rewind_pop();
      const replay = [];
      for (let i = 0; i < 40; i++) {
        c._nds_run_frame();
        const k = key(e2eSig());
        replay.push([k, seen[k.split(":")[0]]]);
        c._nds_audio_clear();
      }
      // Cost: the fastest of N (the machine may be shared: the minimum resists
      // load), the same-frame A/B alternated in one loop.
      const med = (a) => Math.min(...a);
      const time = (f, n) => Array.from({ length: n }, () => { const t = performance.now(); f(); return performance.now() - t; });
      const run = () => { c._nds_run_frame(); c._nds_audio_clear(); };
      c._nds_rewind_enable(0, 0);
      applyStateBytes(state);
      const cost = { payloadMB: c._nds_payload_take() / 1048576,
                     take: med(time(() => c._nds_payload_take(), 60)),
                     restore: med(time(() => c._nds_payload_restore(), 60)),
                     stateMB: state.length / 1048576,
                     stateSave: med(time(() => captureStateBytes(), 10)),
                     // a slot's save on the page: the plain image out, the
                     // packing in the checkpoint worker
                     slotSaveOnPage: med(time(() => captureStateBytesAsync(), 10)) };
      // The same frame each time: plain, right after a restore, and with
      // run-ahead 1 after it.
      const warm = [], cold = [], ahead = [];
      for (let i = 0; i < 90; i++) {
        applyStateBytes(state); run(); run();
        const k = i % 3;
        if (k === 1) { c._nds_payload_take(); c._nds_payload_restore(); }
        const t = performance.now();
        run();
        if (k === 2) c._nds_runahead(1);
        [warm, cold, ahead][k].push(performance.now() - t);
      }
      cost.frame = med(warm); cost.frameAfterRestore = med(cold); cost.frameAndAhead1 = med(ahead);
      c._nds_rewind_enable(1, 0);
      const ft = time(run, 600);
      cost.pushFrame = med(ft.filter((_, i) => i % 10 === 9));
      cost.plainFrame = med(ft.filter((_, i) => i % 10 !== 9));
      cost.ringMBper10s = c._nds_rewind_bytes() / 1048576;
      cost.pop = med(time(() => c._nds_rewind_pop(), 30));
      return { plain, a1, a3, replay, cost,
               distinct: new Set(plain.own.map((k) => k.split(":")[1])).size,
               sounding: plain.own.filter((k) => !k.endsWith(":0")).length };
    });
    assert.ok(r.distinct > 20 && r.sounding > 200, `a moving, sounding stretch: ${r.distinct} screens, ${r.sounding} frames of sound`);
    assert.deepEqual(r.a1.own, r.plain.own, "run-ahead 1: the same frames and sound");
    assert.deepEqual(r.a3.own, r.plain.own, "run-ahead 3 and the ring: the same frames and sound");
    for (let i = 0; i + 1 < 300; i++) assert.equal(String(r.a1.shown[i]), r.plain.own[i + 1].split(":")[1]);
    for (const [now, was] of r.replay) if (was) assert.equal(now, was, "after a rewind the frames replay");
    const f = (x) => (typeof x === "number" ? x.toFixed(2) : x);
    console.log("  " + BENCH.split("/").pop() + ": " +
                Object.entries(r.cost).map(([k, v]) => `${k} ${f(v)}`).join(", ") + " (ms, MB)");
    assert.deepEqual(errors, []);
    await ctx.close();
  });
