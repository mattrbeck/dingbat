// iOS audio session: "playback" plays in Silent Mode but pauses other apps'
// audio; "ambient" mixes with it. The game takes "playback" only while it
// has something to play and Play in Silent Mode is on (the default).

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

// A started game with a fake Safari audio session.
const started = async () => {
  const app = await loadApp();
  app.runIn(`navigator.audioSession = { type: "auto" };
             currentRomName = "game.gba"; paused = false; audioSessionLive = true;
             applyAudioSession()`);
  return app;
};
const sessionType = (app) => app.runIn("navigator.audioSession.type");

test("a running game takes the playback session", async () => {
  const app = await started();
  assert.equal(sessionType(app), "playback");
});

test("the mute button lets other audio play, and unmuting takes it back", async () => {
  const app = await started();
  app.runIn("toggleMute(); applyAudioSession()");
  assert.equal(sessionType(app), "ambient");
  app.runIn("toggleMute(); applyAudioSession()");
  assert.equal(sessionType(app), "playback");
});

// The sliders' input handler is setVolume(Number(slider.value)).
test("dragging the slider to 0 does what mute does", async () => {
  const app = await started();
  app.runIn("setVolume(0); applyAudioSession()");
  assert.equal(app.runIn("volume"), 0);
  assert.equal(sessionType(app), "ambient");
  app.runIn("setVolume(30); applyAudioSession()");
  assert.equal(sessionType(app), "playback");
});

test("pausing lets other audio play, and resuming takes it back", async () => {
  const app = await started();
  app.runIn("paused = true; applyAudioSession()");
  assert.equal(sessionType(app), "ambient");
  app.runIn("paused = false; applyAudioSession()");
  assert.equal(sessionType(app), "playback");
});

test("with no game open the page does not take the session", async () => {
  const app = await started();
  app.runIn("currentRomName = null; applyAudioSession()");
  assert.equal(sessionType(app), "ambient");
});

test("Play in Silent Mode off keeps the ambient session while playing, and is saved", async () => {
  const app = await started();
  await app.runIn("loadAudioSettings()");   // no record: the default, on
  assert.equal(app.runIn("playInSilentToggle.checked"), true);
  app.runIn("playInSilentToggle.checked = false");
  await app.runIn(`playInSilentToggle.dispatch("change")`);
  assert.equal(sessionType(app), "ambient");
  await new Promise((r) => setTimeout(r, 300));   // the save is debounced 250 ms
  const rec = await app.runIn(`dbGet("audio")`);
  assert.equal(rec.playInSilent, false);
  app.runIn("playInSilent = true");
  await app.runIn("loadAudioSettings()");
  assert.equal(app.runIn("playInSilent"), false);
  assert.equal(app.runIn("playInSilentToggle.checked"), false);
});

test("before audio starts the page leaves the session alone", async () => {
  const app = await loadApp();
  app.runIn(`navigator.audioSession = { type: "auto" };
             currentRomName = "game.gba"; applyAudioSession()`);
  assert.equal(sessionType(app), "auto");
});
