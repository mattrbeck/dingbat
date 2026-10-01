// Audio defaults rev 2 turned pitch-correct fast-forward and the analog
// filter on. Every audio change saves all six fields, so a record from
// before rev 2 holds `false` for both whether or not anyone chose it: it
// takes the new defaults once. A rev-2 record's `false` is a choice.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const loadWith = async (app, record) => {
  await app.runIn(`dbPut("audio", ${JSON.stringify(record)})`);
  await app.runIn("loadAudioSettings()");
  return JSON.parse(app.runIn(
    "JSON.stringify({ pitchCorrectFF, audioLowpass, volume, " +
    "pcff: pcffToggle.checked, lp: lowpassToggle.checked })"));
};

test("a fresh install (no audio record) has both on", async () => {
  const app = await loadApp();
  await app.runIn("loadAudioSettings()");
  const s = JSON.parse(app.runIn(
    "JSON.stringify({ pitchCorrectFF, audioLowpass, pcff: pcffToggle.checked, lp: lowpassToggle.checked })"));
  assert.deepEqual(s, { pitchCorrectFF: true, audioLowpass: true, pcff: true, lp: true });
});

test("a record from before rev 2 takes the new defaults and keeps the rest", async () => {
  const app = await loadApp();
  const s = await loadWith(app, { volume: 40, muted: false, pitchCorrectFF: false,
                                  audioLowpass: false, mp2kHle: false, fifoInterp: true });
  assert.deepEqual(s, { pitchCorrectFF: true, audioLowpass: true, volume: 40, pcff: true, lp: true });
});

test("at rev 2, off stays off", async () => {
  const app = await loadApp();
  const s = await loadWith(app, { rev: 2, volume: 40, muted: false, pitchCorrectFF: false,
                                  audioLowpass: false, mp2kHle: false, fifoInterp: true });
  assert.deepEqual(s, { pitchCorrectFF: false, audioLowpass: false, volume: 40, pcff: false, lp: false });
});

test("a save writes the rev, so the choice survives the next load", async () => {
  const app = await loadApp();
  app.runIn("pitchCorrectFF = false; audioLowpass = false; saveAudioSettings()");
  await new Promise((r) => setTimeout(r, 300));   // the save is debounced 250 ms
  const rec = await app.runIn(`dbGet("audio")`);
  assert.equal(rec.rev, 2);
  assert.equal(rec.pitchCorrectFF, false);
  assert.equal(rec.audioLowpass, false);
});
