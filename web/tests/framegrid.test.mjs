// web/framegrid.js, the game loops' clock: timestamps locked to the
// display's refreshes. What it must never do is lose or invent time (the
// game would run slow or fast), and what it is for is the frames per
// refresh staying even when the timestamps jitter.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const ctx = {};
vm.runInNewContext(readFileSync(new URL("../framegrid.js", import.meta.url), "utf8"), ctx);
const { FrameGrid } = ctx;

const FRAME = 1000 / 59.7275; // index.js FRAME_TIME

// Seeded noise, so a failure reproduces
const rng = (seed) => () => { seed = (seed * 16807) % 2147483647; return seed / 2147483647; };

// Feeds callbacks at `times` through a clock (or raw), as index.js does:
// returns the time given and the game frames each refresh ran at 1x (step
// FRAME, at most 2 a refresh) or 2x.
function play(times, { grid = true, speed = 1 } = {}) {
  const clock = FrameGrid.create();
  const step = FRAME / speed, maxF = 2 * speed;
  let last = 0, acc = 0, given = 0;
  const frames = [];
  for (const t of times) {
    if (last === 0) last = t;
    const iv = t - last;
    const add = grid ? clock.next(t, iv) : iv;
    last = t;
    given += add;
    acc += add;
    let n = 0;
    while (acc >= step && n < maxF) { acc -= step; n++; }
    if (acc > step * 2) acc = step * 2;
    frames.push(n);
  }
  return { given, frames, real: times[times.length - 1] - times[0], clock };
}
const vsyncs = (hz, n, jitter = 0, seed = 1, t0 = 1000) => {
  const r = rng(seed), p = 1000 / hz;
  return Array.from({ length: n }, (_, i) => t0 + i * p + (r() * 2 - 1) * jitter);
};
// Refreshes that ran other than floor/ceil of the ideal number of frames
const uneven = (frames, hz, speed) => {
  const ideal = (1000 / hz) / (FRAME / speed);
  return frames.slice(2).filter((f) => f < Math.floor(ideal) || f > Math.ceil(ideal)).length;
};

test("a clean 60 Hz display passes through exactly", () => {
  const { given, real, clock } = play(vsyncs(60, 3600));
  assert.ok(Math.abs(given - real) < 0.01, `given ${given} real ${real}`);
  assert.ok(Math.abs(clock.period() - 1000 / 60) < 0.001);
});

test("±2 ms jitter: even frames per refresh, time kept", () => {
  const times = vsyncs(60, 36000, 2, 7); // 10 minutes
  const raw = play(times, { grid: false }), grid = play(times);
  // (±2 ms is past what browsers were measured at: a few still land wrong)
  assert.ok(uneven(raw.frames, 60, 1) > 500, `raw ${uneven(raw.frames, 60, 1)}`);
  assert.ok(uneven(grid.frames, 60, 1) * 20 < uneven(raw.frames, 60, 1), `grid ${uneven(grid.frames, 60, 1)}`);
  assert.ok(Math.abs(grid.given - grid.real) < 5, `drift ${grid.given - grid.real} ms`);
  const raw2 = play(times, { grid: false, speed: 2 }), grid2 = play(times, { speed: 2 });
  assert.ok(uneven(grid2.frames, 60, 2) * 10 < uneven(raw2.frames, 60, 2));
});

test("Safari's whole-millisecond timestamps", () => {
  const times = vsyncs(60, 36000, 0.3, 3).map(Math.round);
  const raw = play(times, { grid: false }), grid = play(times);
  assert.ok(uneven(raw.frames, 60, 1) > 100, `raw ${uneven(raw.frames, 60, 1)}`);
  assert.ok(uneven(grid.frames, 60, 1) === 0, `grid ${uneven(grid.frames, 60, 1)}`);
  assert.ok(Math.abs(grid.given - grid.real) < 5);
});

test("a missed refresh counts as two", () => {
  const times = vsyncs(60, 200, 0.5, 2);
  times.splice(120, 1); // the callback for refresh 120 never came
  const clock = FrameGrid.create();
  let last = times[0], gap = 0;
  for (const t of times) { const g = clock.next(t, t - last); if (t === times[120]) gap = g; last = t; }
  assert.ok(Math.abs(gap - 2000 / 60) < 1, `gap ${gap}`);
});

test("a pause (interval 0) and a stall give their time unchanged", () => {
  const clock = FrameGrid.create();
  let t = 1000;
  for (let i = 0; i < 60; i++) { t += 1000 / 60; clock.next(t, i ? 1000 / 60 : 0); }
  assert.equal(clock.next(t + 5000, 0), 0);           // resume after a pause
  assert.equal(clock.next(t + 5181, 181), 181);       // a 181 ms stall
  const after = clock.next(t + 5181 + 1000 / 60, 1000 / 60);
  assert.ok(Math.abs(after - 1000 / 60) < 0.5);       // and back on the grid
});

test("a new refresh rate is learnt, and no time is lost meanwhile", () => {
  const a = vsyncs(60, 600, 0.3, 4);
  const b = vsyncs(48, 600, 0.3, 5, a[a.length - 1] + 1000 / 48);
  const { given, real, frames, clock } = play([...a, ...b]);
  assert.ok(Math.abs(clock.period() - 1000 / 48) < 0.05, `period ${clock.period()}`);
  assert.ok(Math.abs(given - real) < 5, `drift ${given - real}`);
  assert.equal(uneven(frames.slice(620), 48, 1), 0);
});

test("120 Hz to 60 Hz (ProMotion) needs no relearning", () => {
  const a = vsyncs(120, 600, 0.3, 6);
  const b = vsyncs(60, 600, 0.3, 8, a[a.length - 1] + 1000 / 60);
  const { given, real, frames } = play([...a, ...b]);
  assert.ok(Math.abs(given - real) < 5);
  assert.equal(uneven(frames.slice(605), 60, 1), 0);
});

test("a variable refresh rate never gains or loses time", () => {
  const r = rng(9);
  let t = 1000;
  const times = [t];
  for (let i = 0; i < 5000; i++) times.push(t += 7 + r() * 26);
  const { given, real } = play(times);
  assert.ok(Math.abs(given - real) < 5, `drift ${given - real}`);
});
