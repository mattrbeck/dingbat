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
// markers the way the sliders and presets do, and assert on the two numbers
// that actually reach _clip_begin.

import test from "node:test";
import assert from "node:assert/strict";
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

const open = async (n = 40) => {
  const app = await loadApp();
  withRing(app, n);
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "Game.gba";
  app.runIn("openClipScrubber()");
  await settle();
  return app;
};

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

test("the sliders and the strip are one state, not two", async () => {
  const app = await open();
  const startSlider = app.document.getElementById("clip-slider-start");
  const endSlider = app.document.getElementById("clip-slider-end");
  // Slider values run the other way from sample indices (right = newer), which
  // is the mapping most likely to be written backwards.
  startSlider.value = String(app.runIn("clipStrip.samples") - 1 - 25);
  await startSlider.dispatch("input");
  assert.equal(markers(app)[0], 25, "the strip must follow the slider");
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
