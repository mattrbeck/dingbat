// Settings › Audio › Channels: per-channel mutes for the loaded game. Every
// way in and out reaches wasm_set_channel_mutes; the top-bar reminder tracks
// them; loading a game clears them.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const setup = async (channels) => {
  const app = await loadApp();
  app.runIn(`
    var __mutes = [];
    Module._wasm_audio_channels = () => ${channels};
    Module._wasm_set_channel_mutes = (v) => __mutes.push(v);
  `);
  const calls = () => JSON.parse(app.runIn("JSON.stringify(__mutes)"));
  const el = (id) => app.document.getElementById(id);
  const chip = (i) => el("channel-chip-" + i);
  return { app, calls, el, chip };
};

test("each chip mutes its own channel and plays it again", async () => {
  const { calls, chip } = await setup(6);
  await chip(2).dispatch("click");        // Wave
  await chip(4).dispatch("click");        // Sample A
  await chip(2).dispatch("click");
  assert.deepEqual(calls(), [0b000100, 0b010100, 0b010000]);
  assert.equal(chip(4).getAttribute("aria-pressed"), "false");
  assert.equal(chip(2).getAttribute("aria-pressed"), "true");
});

test("Mute all silences the tone channels in one tap, and Turn on undoes it", async () => {
  const { app, calls } = await setup(6);
  const tone = app.document.getElementById("channels-all-tone");
  await tone.dispatch("click");
  assert.equal(tone.textContent, "Turn on");
  await tone.dispatch("click");
  assert.equal(tone.textContent, "Mute all");
  assert.deepEqual(calls(), [0b1111, 0]);
});

test("the top-bar reminder counts what is muted and hides when nothing is", async () => {
  const { el, chip } = await setup(6);
  assert.equal(el("channels-indicator").hidden, true);
  await chip(0).dispatch("click");
  await chip(1).dispatch("click");
  assert.equal(el("channels-indicator").hidden, false);
  assert.equal(el("channels-indicator-label").textContent, "2");
  assert.equal(el("channels-foot").hidden, false);
  await el("channels-reset").dispatch("click");
  assert.equal(el("channels-indicator").hidden, true);
  assert.equal(el("channels-foot").hidden, true);
});

test("a Game Boy game shows four channels and no sample group", async () => {
  const { app, el } = await setup(4);
  app.runIn("renderChannels()");
  assert.equal(el("channels-sample").hidden, true);
  assert.equal(el("channels-tone").hidden, false);
  assert.equal(el("channels-tone-label").textContent, "Channels");
});

test("loading another game clears the mutes", async () => {
  const { app, calls, chip, el } = await setup(6);
  app.runIn(`Module.ccall = () => 0;`);
  await chip(3).dispatch("click");
  await app.runIn(`loadRom("B.gba", "B.gba")`);
  assert.equal(app.api.currentOriginalName, "B.gba");
  assert.equal(calls().at(-1), 0, "the new game starts with every channel playing");
  assert.equal(el("channels-indicator").hidden, true);
});
