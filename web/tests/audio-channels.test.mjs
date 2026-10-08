// Settings › Audio › Channels: per-channel mutes, with or without a game.
// Every way in and out reaches wasm_set_channel_mutes; the top-bar reminder
// tracks them; they hold across game loads until turned back on.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const setup = async () => {
  const app = await loadApp();
  app.runIn(`
    var __mutes = [];
    Module._wasm_set_channel_mutes = (v) => __mutes.push(v);
  `);
  const calls = () => JSON.parse(app.runIn("JSON.stringify(__mutes)"));
  const el = (id) => app.document.getElementById(id);
  const chip = (i) => el("channel-chip-" + i);
  return { app, calls, el, chip };
};

test("each chip mutes its own channel and plays it again", async () => {
  const { calls, chip } = await setup();
  await chip(2).dispatch("click");        // Wave
  await chip(4).dispatch("click");        // Sample A
  await chip(2).dispatch("click");
  assert.deepEqual(calls(), [0b000100, 0b010100, 0b010000]);
  assert.equal(chip(4).getAttribute("aria-pressed"), "false");
  assert.equal(chip(2).getAttribute("aria-pressed"), "true");
});

test("Mute all silences the tone channels in one tap, and Turn on undoes it", async () => {
  const { app, calls } = await setup();
  const tone = app.document.getElementById("channels-all-tone");
  await tone.dispatch("click");
  assert.equal(tone.textContent, "Turn on");
  await tone.dispatch("click");
  assert.equal(tone.textContent, "Mute all");
  assert.deepEqual(calls(), [0b1111, 0]);
});

test("the top-bar reminder counts what is muted and hides when nothing is", async () => {
  const { el, chip } = await setup();
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

test("with no game loaded every channel can be muted", async () => {
  const { app, calls, chip } = await setup();
  assert.equal(app.api.currentRomName ?? "", "");
  for (const i of [0, 5]) await chip(i).dispatch("click");
  assert.deepEqual(calls(), [0b000001, 0b100001]);
  assert.equal(chip(5).getAttribute("aria-pressed"), "false");
});

test("mutes set before or between games hold across a load", async () => {
  const { app, calls, chip, el } = await setup();
  app.runIn(`Module.ccall = () => 0;`);
  await chip(3).dispatch("click");
  await app.runIn(`loadRom("B.gba", "B.gba")`);
  assert.equal(app.api.currentOriginalName, "B.gba");
  assert.deepEqual(calls(), [0b1000], "nothing turned the mute back off");
  assert.equal(chip(3).getAttribute("aria-pressed"), "false");
  assert.equal(el("channels-indicator").hidden, false);
});
