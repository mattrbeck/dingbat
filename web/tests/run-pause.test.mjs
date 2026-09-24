// Who may unpause the core. Every pausing surface (the home screen, Report a
// Bug, the clip picker, the peer in a rollback session) writes the one global
// `paused`, so each of these replays a trace from formal/WebState/RunPause.lean
// in which some other writer used to undo it: the game ran behind the surface
// meant to freeze it, or the pause button's icon stopped saying what the core
// does.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle } from "./helpers.mjs";

// A game on screen: what loadRom leaves behind, without booting a core.
const inGame = async (extra = "") => {
  const app = await loadApp();
  app.runIn(`
    currentRomName = "rom.gba";
    currentOriginalName = "Game.gba";
    document.body.classList.add("has-game", "running");
    // The click path has a 350ms lockout vs pointerup; back-date the stamp.
    pausePointerTs = -10000;
    ${extra}
    0`);
  return app;
};

const paused = (app) => app.runIn("paused");
// What the pause button shows: its paused class is the Resume icon.
const icon = (app) =>
  app.runIn('pauseButton.classList.contains("paused")') ? "Resume" : "Pause";

// A key as the document's capture listener sees it.
const key = (app, code) =>
  app.dispatchDoc("keydown", { code, target: app.document.body, repeat: false });

test("Space on the home screen leaves the hidden game paused (bug_space_on_home_runs_game)",
  async () => {
    const app = await inGame();
    app.runIn("showMainMenu()");
    assert.equal(paused(app), true, "the home screen froze the game");
    await key(app, "Space");
    assert.equal(paused(app), true, "Space must not run the game behind the library");
  });

test("Period on the home screen does not step the hidden game", async () => {
  const app = await inGame(`
    globalThis.__ticks = 0;
    globalThis.Module = { _loop_tick: () => { __ticks++; } };
  `);
  app.runIn("showMainMenu()");
  await key(app, "Period");
  assert.equal(app.runIn("__ticks"), 0, "frame advance must not step a game nobody can see");
  assert.equal(paused(app), true);
});

test("Space and Period still work in the game view", async () => {
  const app = await inGame(`
    globalThis.__ticks = 0;
    globalThis.Module = { _loop_tick: () => { __ticks++; } };
  `);
  await key(app, "Space");
  assert.equal(paused(app), true, "Space pauses");
  await key(app, "Period");
  assert.equal(app.runIn("__ticks"), 1, "Period steps a paused game one frame");
  await key(app, "Space");
  assert.equal(paused(app), false, "Space resumes");
});

// --- Clip export -------------------------------------------------------------

// Enough of the wasm clip ring and MediaRecorder for the export to arm (the
// clip-range tests' stubs).
const CLIP_STUBS = `
  globalThis.Module = {
    memory: { buffer: new ArrayBuffer(64 * 1024) },
    _clip_scrub_generate: () => 40,
    _clip_scrub_thumb_w: () => 4,
    _clip_scrub_thumb_h: () => 3,
    _clip_scrub_thumbs_ptr: () => 0,
    _clip_scrub_frames_ago: (i) => 20 + i * 60,
    _clip_begin: (a, b) => a - b,
    _clip_abort: () => {},
  };
  globalThis.MediaRecorder = class {
    static isTypeSupported() { return true; }
    constructor() { this.state = "recording"; this.mimeType = "video/webm"; }
    start() {}
    stop() { this.state = "inactive"; }
  };
  canvasEl.captureStream = () => ({ addTrack() {}, getAudioTracks: () => [] });
`;

const exportClip = async (app) => {
  app.runIn("openClipScrubber()");
  await settle();
  await app.document.getElementById("clip-save").dispatch("click");
  assert.equal(app.runIn("clipReplayActive"), true, "the export armed");
  assert.equal(paused(app), false, "the replay runs whatever the game was doing");
  app.runIn("finishRetroClip(true)"); // the tick, once clip_tick reports the log exhausted
};

test("a clip exported from a paused game leaves it paused (bug_clip_export_drops_pause)",
  async () => {
    const app = await inGame(CLIP_STUBS);
    await app.document.getElementById("pause").dispatch("click");
    assert.equal(paused(app), true);
    await exportClip(app);
    assert.equal(paused(app), true, "the game the player paused must not carry on after the export");
    assert.equal(icon(app), "Resume");
  });

test("a clip exported from a running game leaves it running", async () => {
  const app = await inGame(CLIP_STUBS);
  await exportClip(app);
  assert.equal(paused(app), false);
  assert.equal(icon(app), "Pause");
});

// --- The peer's pause in a rollback session ----------------------------------

const linked = () => inGame(`
  globalThis.__relayed = [];
  window.rbSendPause = (on) => __relayed.push(on);
  rollbackMode = true;
`);

test("the peer resuming under Report a Bug leaves the core frozen, and closing it resumes " +
     "(bug_remote_resume_under_report_*)", async () => {
  const app = await linked();
  app.runIn("window.applyRemotePause(true)");
  app.runIn("openReportModal()");
  app.runIn("window.applyRemotePause(false)");
  assert.equal(paused(app), true, "the core must not run under the report");
  assert.equal(icon(app), "Pause", "the button shows the run state closing the report gives back");
  app.runIn("closeReportModal()");
  assert.equal(paused(app), false, "closing the report follows the peer, who resumed");
  assert.equal(icon(app), "Pause");
  assert.deepEqual(JSON.parse(app.runIn("JSON.stringify(__relayed)")), [], "nothing echoes back");
});

test("the peer pausing under Report a Bug is what closing it gives back", async () => {
  const app = await linked();
  app.runIn("openReportModal()");
  app.runIn("window.applyRemotePause(true)");
  app.runIn("closeReportModal()");
  assert.equal(paused(app), true);
  assert.equal(icon(app), "Resume");
});

test("the peer pausing and resuming leaves a game on the home screen frozen " +
     "(bug_remote_resume_on_home_runs)", async () => {
  const app = await linked();
  app.runIn("showMainMenu()");
  app.runIn("window.applyRemotePause(true)");
  app.runIn("window.applyRemotePause(false)");
  assert.equal(paused(app), true, "the core must not run behind the library");
});
