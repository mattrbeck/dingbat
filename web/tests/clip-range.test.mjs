// The clip range picker, driven against a stubbed wasm ring; assertions are
// on the two frame offsets that reach _clip_begin. Failures here are silent:
// an off-by-one in the "now" rule drops the last second, and an inverted
// range returns 0 and looks like "no history yet".

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadApp, settle, eq } from "./helpers.mjs";

// A ring of `n` anchors one second apart, newest first (clip_scrub_generate's
// shape). The newest anchor is itself up to a second behind the live frame;
// 20 frames of lag models that.
const NEWEST_LAG = 20;
const withRing = (app, n) =>
  app.runIn(`
    globalThis.clipBeginCalls = [];
    globalThis.Module = {
      memory: { buffer: new ArrayBuffer(64 * 1024) },
      _clip_scrub_generate: () => ${n},
      _clip_scrub_thumb_w: () => 4,
      _clip_scrub_thumb_h: () => 3,
      _clip_scrub_thumbs_ptr: () => 0,
      _clip_scrub_frames_ago: (i) => ${NEWEST_LAG} + i * 60,
      _clip_begin: (a, b) => { clipBeginCalls.push([a, b]); return a - b; },
      _clip_abort: () => {},
    };
    // Enough recorder for startClipExport to reach the wasm call.
    globalThis.MediaRecorder = class {
      static isTypeSupported() { return true; }
      constructor() { this.state = "recording"; this.mimeType = "video/webm"; }
      start() {}
      stop() {}
    };
    canvasEl.captureStream = () => ({ addTrack() {}, getAudioTracks: () => [] });
    0`);

// The fake DOM measures 0x0, which the strip floors at 120px, hiding the
// width bugs; give it a real width (a 393pt phone leaves the strip 277px).
const sizeStrip = (app, width, height = 44) => {
  const rect = { width, height, top: 0, left: 0, right: width, bottom: height,
                 x: 0, y: 0 };
  for (const id of ["clip-strip-wrap", "clip-strip"]) {
    app.document.getElementById(id).getBoundingClientRect = () => rect;
  }
};

// The track's width routes a press to one knob or the other (0 would route
// every press to knob 0). `left` is 0, so clientX is an offset into the box;
// knob travel is inset by CLIP_KNOB_W / 2 = 11px at each end.
const KNOB_PAD = 11;
const sizeTrack = (app, width) => {
  const rect = { width, height: 44, top: 0, left: 0, right: width, bottom: 44,
                 x: 0, y: 0 };
  app.document.getElementById("clip-range").getBoundingClientRect = () => rect;
};

const track = (app, x, type = "pointerdown") =>
  app.document.getElementById("clip-range")
     .dispatch(type, { clientX: KNOB_PAD + x, pointerId: 1 });

const knob = (app, which) =>
  app.document.getElementById("clip-slider-" + which);

// The preview caption is the readout of which knob the picker follows.
const following = (app) =>
  app.document.getElementById("clip-preview-label").textContent
    .startsWith("first") ? "start" : "end";

const open = async (n = 40, width = 0) => {
  const app = await loadApp();
  withRing(app, n);
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "Game.gba";
  if (width) sizeStrip(app, width);
  app.runIn("openClipScrubber()");
  await settle();
  return app;
};

const offscreen = (app, which) =>
  app.document.getElementById("clip-marker-" + which).classList.contains("offscreen");

const range = (app) => app.runIn("clipRangeFrames()");
const markers = (app) => [app.runIn("clipStrip.at(0)"), app.runIn("clipStrip.at(1)")];

test("it opens on the last ten seconds, ending at NOW rather than at the newest anchor",
  async () => {
    const app = await open();
    assert.equal(app.document.getElementById("clip-modal").classList.contains("open"), true);
    const r = range(app);
    // The newest sample is 20 frames old; reporting 20 there would shave the
    // last third of a second off every untouched clip.
    assert.equal(r.end, 0, "the newest sample must mean 'now', not 'the newest anchor'");
    assert.equal(r.start, NEWEST_LAG + 10 * 60,
                 "the in point should be the sample nearest 10s back");
    assert.equal(r.len, r.start, "length is start - end");
    assert.equal(app.document.getElementById("clip-save").disabled, false);
  });

test("an out point that is NOT the newest sample keeps its real age", async () => {
  const app = await open();
  app.runIn("clipStrip.setValue(1, 3, true)");
  const r = range(app);
  assert.equal(r.end, NEWEST_LAG + 3 * 60,
               "only sample 0 is special — sample 3 is its own age");
  assert.equal(r.len, r.start - r.end);
});

test("the markers cannot cross: dragging the in point past the out point pins it",
  async () => {
    const app = await open();
    app.runIn("clipStrip.setValue(1, 5, true, { max: clipStrip.at(0) - 1 })");
    app.runIn("clipStrip.setValue(0, 0, true, { min: clipStrip.at(1) + 1 })");
    const [inPt, outPt] = markers(app);
    assert.ok(inPt > outPt, `in point ${inPt} must stay older than out point ${outPt}`);
    assert.equal(inPt, outPt + 1, "it should pin one frame short, not invert");
    assert.ok(range(app).len > 0, "an inverted range would make len 0 and look like no history");
  });

test("the knobs and the strip are one state, not two", async () => {
  const app = await open();
  const startSlider = knob(app, "start");
  const endSlider = knob(app, "end");
  // Knob values run the other way from sample indices (right = newer).
  startSlider.value = String(app.runIn("clipStrip.samples") - 1 - 25);
  await startSlider.dispatch("input");
  assert.equal(markers(app)[0], 25, "the strip must follow the knob");
  app.runIn("clipStrip.setValue(0, 7, true, { min: clipStrip.at(1) + 1 }); clipRefresh()");
  assert.equal(Number(startSlider.value), app.runIn("clipStrip.samples") - 1 - 7);
  assert.equal(Number(endSlider.value), app.runIn("clipStrip.samples") - 1);
});

test("presets pick the sample nearest the wanted length, and pin the end to now",
  async () => {
    const app = await open();
    await app.document.getElementById("clip-preset-30").dispatch("click");
    eq(range(app), { start: NEWEST_LAG + 30 * 60, end: 0, len: NEWEST_LAG + 30 * 60 });
    await app.document.getElementById("clip-preset-all").dispatch("click");
    const r = range(app);
    assert.equal(r.start, NEWEST_LAG + 39 * 60, "'Everything' is the oldest sample");
    assert.equal(r.end, 0);
    await app.document.getElementById("clip-preset-10").dispatch("click");
    assert.equal(range(app).start, NEWEST_LAG + 10 * 60);
  });

// A ring shorter than the preset: the picker offers what exists.
test("a preset longer than the history clamps to what there is", async () => {
  const app = await open(6);
  await app.document.getElementById("clip-preset-30").dispatch("click");
  const r = range(app);
  assert.equal(r.start, NEWEST_LAG + 5 * 60, "the oldest sample is all there is");
  assert.ok(r.len > 0);
});

test("saving hands _clip_begin the selected range, in frames", async () => {
  const app = await open();
  await app.document.getElementById("clip-preset-30").dispatch("click");
  await app.document.getElementById("clip-save").dispatch("click");
  const calls = app.runIn("clipBeginCalls");
  eq(calls, [[NEWEST_LAG + 30 * 60, 0]]);
  assert.equal(app.document.getElementById("clip-modal").classList.contains("open"), false,
               "the picker closes before the replay takes the screen");
});

// The core is frozen while the picker is open, else the anchors age out
// from under the markers.
test("the game is paused while the picker is open, and left as it was after", async () => {
  const app = await loadApp();
  withRing(app, 40);
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "Game.gba";
  assert.equal(app.runIn("paused"), false);
  app.runIn("openClipScrubber()");
  assert.equal(app.runIn("paused"), true, "the ring must not move under the strip");
  await app.document.getElementById("clip-scrub-cancel").dispatch("click");
  assert.equal(app.runIn("paused"), false, "cancel restores the prior run state");
});

test("closing a picker that was never open cannot unpause a game", async () => {
  const app = await loadApp();
  withRing(app, 40);
  app.runIn("paused = true");
  app.runIn("closeClipScrubber()");
  assert.equal(app.runIn("paused"), true);
});

test("no history yet: the picker says so instead of offering an empty clip", async () => {
  const app = await loadApp();
  app.runIn(`
    globalThis.clipBeginCalls = [];
    globalThis.Module = {
      memory: { buffer: new ArrayBuffer(64) },
      _clip_scrub_generate: () => 0,
      _clip_scrub_thumb_w: () => 4,
      _clip_scrub_thumb_h: () => 3,
      _clip_scrub_thumbs_ptr: () => 0,
      _clip_scrub_frames_ago: () => 0,
      _clip_begin: (a, b) => { clipBeginCalls.push([a, b]); return 0; },
    };
    0`);
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "Game.gba";
  app.runIn("openClipScrubber()");
  await settle();
  assert.match(app.document.getElementById("clip-scrub-hint").textContent,
               /No gameplay history/);
  assert.equal(app.document.getElementById("clip-save").disabled, true);
  await app.document.getElementById("clip-save").dispatch("click");
  eq(app.runIn("clipBeginCalls"), [], "a disabled Save must not fire a replay");
});

// --- Framing ---------------------------------------------------------------
// Both brackets must be on the strip when it opens; frame width gives on a
// narrow wrap, not the framing.
for (const [device, width] of [["a 320pt phone", 208], ["a 393pt phone", 277],
                               ["a desktop panel", 400]]) {
  test(`the default selection fits the strip on ${device}`, async () => {
    const app = await open(40, width);
    assert.equal(offscreen(app, "start"), false, "the in point opened off-strip");
    assert.equal(offscreen(app, "end"), false, "the 'now' bracket opened off-strip");
    // The span the brackets enclose: ten anchors plus the end frames' pitch.
    assert.ok(app.runIn("clipStrip.pitch") * 11 <= width,
              "the ten-second selection is wider than the strip");
  });
}

test("a knob takes the view with it, whatever the last drag grabbed", async () => {
  const app = await open(40, 277);
  app.runIn("clipStrip.setActive(1)");
  // From the keyboard path, the strip must scroll to the marker the knob
  // moved.
  const slider = knob(app, "start");
  slider.value = "9";                       // sample 30 of 40, i.e. 30s back
  await slider.dispatch("input");
  assert.equal(app.runIn("clipStrip.at(0)"), 30);
  assert.equal(offscreen(app, "start"), false,
               "the strip stayed on the marker the last drag grabbed");
  assert.equal(following(app), "start");
  assert.equal(app.document.getElementById("clip-preview-label").textContent,
               "first frame of the clip");
});

// --- One track, two knobs --------------------------------------------------
// A press has to reach the knob aimed at, and a pair of knobs pushed together
// must still come apart.

test("a press on the track grabs the NEARER knob, and moves only that one",
  async () => {
    // 40 samples over a 277px track: 255px of travel, 6.54px a slot. Opens
    // with start on slot 29 (sample 10) and end on slot 39.
    const app = await open(40, 277);
    sizeTrack(app, 277);
    await track(app, 250);                  // 5px from the end knob at 255
    assert.equal(markers(app)[1], 1, "the press should have moved the end knob");
    assert.equal(markers(app)[0], 10, "...and left the start knob alone");
    assert.equal(following(app), "end", "the grabbed knob is the one to follow");

    const app2 = await open(40, 277);
    sizeTrack(app2, 277);
    await track(app2, 180);                 // 10px from the start knob at 190
    assert.equal(markers(app2)[0], 11, "the press should have moved the start knob");
    assert.equal(markers(app2)[1], 0, "...and left the end knob alone");
    assert.equal(following(app2), "start");
  });

// Blocking, not pushing: a knob driven into its neighbour stops one frame
// short (pushing would silently rewrite the other end).
test("a knob cannot cross its neighbour, and snaps back when it is stopped",
  async () => {
    const app = await open();
    const endSlider = knob(app, "end");
    endSlider.value = "20";
    await endSlider.dispatch("input");
    const [inPt, outPt] = markers(app);
    assert.equal(inPt, 10, "the neighbour must not be pushed along");
    assert.equal(outPt, 9, "it pins one frame short, it does not invert");
    // The refused knob must not be left showing a selection the strip and
    // readout don't describe.
    assert.equal(Number(endSlider.value), 30,
                 "a move clamped away has to snap the knob back");
    assert.ok(range(app).len > 0);
  });

// Two stacked inputs: the top one would swallow every press where they
// overlap. Presses are routed by distance; an exact tie goes to whichever
// knob still has somewhere to go.
test("two knobs pushed together can still be pulled apart", async () => {
  // 178px track = 156px travel over 39 slots = 4px a slot, so the midpoint
  // between adjacent knobs is an exact tie.
  const app = await open(40, 178);
  sizeTrack(app, 178);
  app.runIn("clipStrip.setValue(1, 0, true); " +
            "clipStrip.setValue(0, 1, true, { min: 1 }); clipRefresh()");
  assert.deepEqual([Number(knob(app, "start").value), Number(knob(app, "end").value)],
                   [38, 39], "the knobs should be one slot apart");
  // The end knob is jammed at the top of its range, so the tie goes to start.
  await track(app, 154);
  assert.equal(following(app), "start", "the tie must go to the knob with room");
  assert.deepEqual(markers(app), [1, 0], "the press itself moves nothing");
  await track(app, 100, "pointermove");
  assert.deepEqual(markers(app), [14, 0]);
  await track(app, 100, "pointerup");
});

// aria-valuetext carries the moment in words; "8.4s" is read out as a letter.
test("each knob announces its moment in words", async () => {
  const app = await open();
  const said = (which) => knob(app, which).getAttribute("aria-valuetext");
  assert.equal(said("start"), "10 seconds ago");
  assert.equal(said("end"), "now", "the newest sample is 'now', as everywhere else");
  app.runIn("clipStrip.setValue(1, 3, true); clipRefresh()");
  assert.equal(said("end"), "3 seconds ago");

  const long = await open(100);
  await long.document.getElementById("clip-preset-all").dispatch("click");
  assert.equal(long.document.getElementById("clip-slider-start")
                   .getAttribute("aria-valuetext"), "1 minute 39 seconds ago");
});

test("the highlighted span runs between the two knobs, and the moving knob is on top",
  async () => {
    const app = await open();
    const fill = app.document.getElementById("clip-range-fill");
    // Percentages of the knobs' travel, not of the box (the rail is inset by
    // half a knob at each end).
    assert.equal(fill.style.left, (29 / 39) * 100 + "%");
    assert.equal(fill.style.right, "0%", "the end knob is pinned to 'now'");
    assert.equal(knob(app, "start").classList.contains("on-top"), true);
    assert.equal(knob(app, "end").classList.contains("on-top"), false);
    app.runIn("clipSetActive(1); clipRefresh()");
    assert.equal(knob(app, "end").classList.contains("on-top"), true,
                 "the knob being moved has to be the visible one");
  });

// --- Menu visibility -------------------------------------------------------
// Both clip items: shown once a game runs, hidden in every linked mode. Pins
// the `body.has-game body.has-game #record-clip` selector bug (a body inside
// a body matches nothing).
const css = () => readFileSync(new URL("../styles.css", import.meta.url), "utf8");

test("#record-clip is governed by every rule #clip-last is", () => {
  const src = css();
  const misses = [];
  for (const m of src.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{[^{}]*\}/g)) {
    const sels = m[1].split(",").map((s) => s.trim()).filter(Boolean);
    for (const sel of sels) {
      if (!sel.endsWith("#clip-last")) continue;
      const ctx = sel.slice(0, -"#clip-last".length);
      if (!sels.includes(ctx + "#record-clip")) misses.push(sel);
    }
  }
  assert.deepEqual(misses, [],
    "these rules reach #clip-last but not #record-clip:\n  " + misses.join("\n  "));
});

test("no selector repeats `body.<mode>` inside itself", () => {
  const src = css().replace(/\/\*[\s\S]*?\*\//g, "");
  const dead = [];
  for (const m of src.matchAll(/([^{}]+)\{[^{}]*\}/g)) {
    for (const sel of m[1].split(",").map((s) => s.trim())) {
      if (/\bbody\b[^,{]*\s\bbody\b/.test(sel)) dead.push(sel);
    }
  }
  assert.deepEqual(dead, [], "dead selectors (a body inside a body matches nothing)");
});
