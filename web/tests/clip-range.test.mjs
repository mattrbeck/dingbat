// "Clip that!" — the range picker in front of retroactive clip capture.
//
// The core replays whatever frame range it is handed (tests/clip_replay_test.nim
// proves that replay is bit-identical). Everything that can go wrong on THIS
// side is arithmetic between a film strip and two frame offsets, and all of it
// is silent: an off-by-one in the "now" rule silently drops the last second —
// which is usually the second you wanted — and a marker allowed to cross its
// neighbour hands the core an inverted range that just returns 0 and looks
// like "no history yet".
//
// So these drive the real modal against a stubbed wasm ring: open it, move the
// markers every way the UI can — the two knobs of the range slider, a press on
// its track, the presets — and assert on the two numbers that actually reach
// _clip_begin.
//
// The slider is one track with two knobs (two <input type="range"> stacked on
// one rail), so it brings its own failure mode along: two knobs sitting on top
// of each other, one of which can no longer be grabbed. That has its own test
// below.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadApp, settle, eq } from "./helpers.mjs";

// A clip ring holding `n` anchors one second apart, newest first — the shape
// clip_scrub_generate hands back. Sample i is i seconds old, EXCEPT that the
// newest anchor is itself up to a second behind the live frame, which is the
// whole reason the "now" rule below exists; 20 frames of lag models that.
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
    // Enough of a recorder for startClipExport to get past codec negotiation
    // and reach the wasm call; nothing here records anything.
    globalThis.MediaRecorder = class {
      static isTypeSupported() { return true; }
      constructor() { this.state = "recording"; this.mimeType = "video/webm"; }
      start() {}
      stop() {}
    };
    canvasEl.captureStream = () => ({ addTrack() {}, getAudioTracks: () => [] });
    0`);

// The fake DOM measures everything as 0x0, which the strip floors at 120px —
// wide enough to hide exactly the bug these width tests are about. Give the
// strip a real width instead; `width` is the CSS px the wrap gets on the
// device being modelled (a 393pt phone leaves the modal's strip 277px).
const sizeStrip = (app, width, height = 44) => {
  const rect = { width, height, top: 0, left: 0, right: width, bottom: height,
                 x: 0, y: 0 };
  for (const id of ["clip-strip-wrap", "clip-strip"]) {
    app.document.getElementById(id).getBoundingClientRect = () => rect;
  }
};

// Same problem for the range slider's track: its width is what routes a press
// to one knob or the other, and 0 would route every press to knob 0. `left` is
// 0, so a clientX is just an offset into the box — and the knobs' travel is
// inset by half a knob (CLIP_KNOB_W / 2 = 11px) at each end, exactly as a
// native range input insets its thumb.
const KNOB_PAD = 11;
const sizeTrack = (app, width) => {
  const rect = { width, height: 44, top: 0, left: 0, right: width, bottom: 44,
                 x: 0, y: 0 };
  app.document.getElementById("clip-range").getBoundingClientRect = () => rect;
};

// A press/drag on the track, at `x` px into it (past the knob inset).
const track = (app, x, type = "pointerdown") =>
  app.document.getElementById("clip-range")
     .dispatch(type, { clientX: KNOB_PAD + x, pointerId: 1 });

const knob = (app, which) =>
  app.document.getElementById("clip-slider-" + which);

// Which knob the picker is following — the preview caption is the readout of
// exactly that, so asserting on it also proves the caption tracks the knob.
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
    // The out point sits on the newest sample, and that sample is 20 frames
    // old. Reporting 20 there would quietly shave the most recent third of a
    // second off every clip made without touching the controls.
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
    // Now try to drag the in point (older) forward past the out point.
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
  // Knob values run the other way from sample indices (right = newer), which
  // is the mapping most likely to be written backwards.
  startSlider.value = String(app.runIn("clipStrip.samples") - 1 - 25);
  await startSlider.dispatch("input");
  assert.equal(markers(app)[0], 25, "the strip must follow the knob");
  // ...and back: moving the strip re-writes the slider rather than leaving it
  // showing a moment that is no longer selected.
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

// A ring shorter than the preset asks for. The picker must offer what exists
// rather than an empty range — this is the state every session is in for its
// first minute.
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

// The core is frozen while the picker is open: the ring keeps rolling
// otherwise, and the strip on screen would be pointing at anchors that have
// aged out from under the markers by the time Save is pressed.
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
  // The global Escape handler calls every modal's closer blindly.
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
// The picker opens on the last ten seconds, so BOTH brackets have to be on the
// strip when it opens or the control does not read as a range at all — and a
// bracket the strip drops (`.offscreen`, the marker's line hidden) is the
// picker saying "the clip carries on past here", which is a lie about the very
// selection it opened with. Frame width is what has to give on a narrow wrap,
// not the framing: the preview above the strip is what a frame is identified
// from, and it is full size regardless.
for (const [device, width] of [["a 320pt phone", 208], ["a 393pt phone", 277],
                               ["a desktop panel", 400]]) {
  test(`the default selection fits the strip on ${device}`, async () => {
    const app = await open(40, width);
    assert.equal(offscreen(app, "start"), false, "the in point opened off-strip");
    assert.equal(offscreen(app, "end"), false, "the 'now' bracket opened off-strip");
    // The span the two brackets enclose, which is what actually has to fit:
    // ten one-second anchors, plus the pitch between the outer edges of the
    // two end frames.
    assert.ok(app.runIn("clipStrip.pitch") * 11 <= width,
              "the ten-second selection is wider than the strip");
  });
}

test("a knob takes the view with it, whatever the last drag grabbed", async () => {
  const app = await open(40, 277);
  // A drag on the "now" bracket leaves it as the marker the strip follows.
  app.runIn("clipStrip.setActive(1)");
  // Now pull the in point back to a selection far longer than the strip can
  // show, from the keyboard/AT path. The marker the KNOB moved is the one the
  // player is looking for, so the strip has to scroll to it — otherwise the
  // knob is nudging something that is not on screen.
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
// The picker used to carry two full-width sliders labelled "Start" and "End".
// It is one track with two knobs now, which buys the shape of the selection
// back (it is the same span the two brackets above enclose) and costs two
// things that have to be tested for: a press has to reach the knob the player
// aimed at, and a pair of knobs pushed together must still come apart.

test("a press on the track grabs the NEARER knob, and moves only that one",
  async () => {
    // 40 samples over a 277px track: the knobs travel 255px, 6.54px a slot.
    // The picker opens with start on slot 29 (sample 10) and end on slot 39.
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
// short of it. Pushing would silently rewrite the end of a range that was
// already chosen, and an inverted range reaches the core as a length of 0 and
// looks exactly like "no history yet".
test("a knob cannot cross its neighbour, and snaps back when it is stopped",
  async () => {
    const app = await open();
    const endSlider = knob(app, "end");
    // Drag the end (newer) knob left, past the start knob's own slot 29.
    endSlider.value = "20";
    await endSlider.dispatch("input");
    const [inPt, outPt] = markers(app);
    assert.equal(inPt, 10, "the neighbour must not be pushed along");
    assert.equal(outPt, 9, "it pins one frame short, it does not invert");
    // The knob asked to go to slot 20 and was refused. Leaving it there would
    // show a selection that is not the one the strip and the readout describe.
    assert.equal(Number(endSlider.value), 30,
                 "a move clamped away has to snap the knob back");
    assert.ok(range(app).len > 0);
  });

// The classic dual-slider failure: with two inputs stacked on one track, the
// one on top swallows every press where they overlap and the knob underneath
// is unreachable forever. Presses here are routed by distance instead, and an
// exact tie goes to whichever knob still has somewhere to go.
test("two knobs pushed together can still be pulled apart", async () => {
  // 178px track = 156px of travel over 39 slots = exactly 4px a slot, so the
  // midpoint between two adjacent knobs is an exact tie rather than a near one.
  const app = await open(40, 178);
  sizeTrack(app, 178);
  // Pin the pair against the "now" end: end on slot 39, start one short of it.
  app.runIn("clipStrip.setValue(1, 0, true); " +
            "clipStrip.setValue(0, 1, true, { min: 1 }); clipRefresh()");
  assert.deepEqual([Number(knob(app, "start").value), Number(knob(app, "end").value)],
                   [38, 39], "the knobs should be one slot apart");
  // Press exactly between them. The end knob is jammed against the top of its
  // range, so the start knob is the only one that can go anywhere.
  await track(app, 154);
  assert.equal(following(app), "start", "the tie must go to the knob with room");
  assert.deepEqual(markers(app), [1, 0], "the press itself moves nothing");
  // ...and it drags, which is the whole point: the pair comes apart.
  await track(app, 100, "pointermove");
  assert.deepEqual(markers(app), [14, 0]);
  await track(app, 100, "pointerup");
});

// A slot index read aloud is meaningless. aria-valuetext is where the moment
// goes, in words — "8.4s" is read out as a letter.
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
    // Percentages of the knobs' travel, not of the box: the rail is inset by
    // half a knob at each end, so anything else drifts off them at the edges.
    assert.equal(fill.style.left, (29 / 39) * 100 + "%");
    assert.equal(fill.style.right, "0%", "the end knob is pinned to 'now'");
    assert.equal(knob(app, "start").classList.contains("on-top"), true);
    assert.equal(knob(app, "end").classList.contains("on-top"), false);
    app.runIn("clipSetActive(1); clipRefresh()");
    assert.equal(knob(app, "end").classList.contains("on-top"), true,
                 "the knob being moved has to be the visible one");
  });

// --- Menu visibility -------------------------------------------------------
// Both clip menu items are governed by the same four rules — shown once a game
// is running, hidden in every linked mode (a retroactive replay rewinds the
// core, and a forward recording outlives the link) — and #record-clip once
// missed all four because each of its selectors was written `body.has-game
// body.has-game #record-clip`. A body inside a body matches nothing, so the
// item was invisible in single-player and would have been visible in link,
// rollback and net modes the moment the first one was fixed on its own.
const css = () => readFileSync(new URL("../styles.css", import.meta.url), "utf8");

test("#record-clip is governed by every rule #clip-last is", () => {
  const src = css();
  const misses = [];
  // Selector lists, stripped of their declaration blocks and comments.
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
      // `body.x body.y` can never match: a document has one body element.
      if (/\bbody\b[^,{]*\s\bbody\b/.test(sel)) dead.push(sel);
    }
  }
  assert.deepEqual(dead, [], "dead selectors (a body inside a body matches nothing)");
});
