// The game's real name, on the page title and the lock screen.
//
// Two things are checked here. First the cartridge-header parse, which is the
// fallback name and mirrors src/dingbat/common/romtitle.nim — the window
// boundaries are where this goes wrong (a CGB cart's manufacturer code
// appended to its title) and no ROM suite would ever notice. Second the
// now-playing surfaces: precedence between the library name and the header,
// document.title reverting at the library, and the Media Session play/pause
// handlers landing on the emulator's own pause state.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp } from "./helpers.mjs";

const EM = "—"; // em dash, as index.js joins with

// --- ROM builders ----------------------------------------------------------

const gbRom = (title, { cgb = false, manufacturer = "AXVE" } = {}) => {
  const rom = new Uint8Array(0x150);
  for (let i = 0; i < title.length && i < 16; i++) rom[0x134 + i] = title.charCodeAt(i);
  if (cgb) {
    for (let i = 0; i < 4; i++) rom[0x13f + i] = manufacturer.charCodeAt(i);
    rom[0x143] = 0xc0;
  }
  return rom;
};

const gbaRom = (title) => {
  const rom = new Uint8Array(0xc0);
  for (let i = 0; i < title.length && i < 12; i++) rom[0xa0 + i] = title.charCodeAt(i);
  // Game code at 0xAC, which must never be folded into the title.
  "BPEE".split("").forEach((c, i) => (rom[0xac + i] = c.charCodeAt(0)));
  return rom;
};

test("romHeaderTitle: window boundaries and sanitizing", async () => {
  const app = await loadApp();
  const t = app.api.romHeaderTitle;

  // GBA: 12 bytes at 0xA0, NUL-padded; the game code at 0xAC stays out.
  assert.equal(t(gbaRom("POKEMON EMER"), ".gba"), "POKEMON EMER");
  assert.equal(t(gbaRom("METROID4"), ".gba"), "METROID4");

  // GB, non-CGB cart: the full 16-byte field.
  assert.equal(t(gbRom("SUPER MARIOLAND"), ".gb"), "SUPER MARIOLAND");

  // GB, CGB cart: 11 bytes only — 0x13F-0x142 is the manufacturer code and
  // 0x143 the CGB flag. Reading 16 here yields "POKEMON_CRYAXVE".
  assert.equal(t(gbRom("POKEMON_CRYSTAL", { cgb: true }), ".gbc"), "POKEMON_CRY");

  // A short title in a CGB cart still stops at its NUL, not at the window end.
  assert.equal(t(gbRom("ZELDA", { cgb: true }), ".gbc"), "ZELDA");

  // Trailing spaces (the other common padding) are trimmed.
  assert.equal(t(gbaRom("KIRBY      "), ".gba"), "KIRBY");

  // All-zero header (rgbfix-less homebrew, this repo's own test ROMs).
  assert.equal(t(new Uint8Array(0x150), ".gb"), "");
  assert.equal(t(new Uint8Array(0xc0), ".gba"), "");

  // Non-ASCII garbage: dropped, never emitted into a window title. The 0xFF
  // run here has no NUL in it, so this is the "filter" arm, not the "stop" one.
  const junk = new Uint8Array(0x150).fill(0xff);
  junk[0x143] = 0x00; // not a CGB flag -> 16-byte window
  assert.equal(t(junk, ".gb"), "");
  const mixed = gbaRom("OK");
  mixed[0xa2] = 0x01;  // control char, dropped...
  mixed[0xa3] = 0x80;  // ...as is anything >= 0x80
  mixed[0xa4] = "!".charCodeAt(0);
  assert.equal(t(mixed, ".gba"), "OK!");

  // Truncated files never throw and never guess.
  assert.equal(t(new Uint8Array(0x140), ".gb"), "");
  assert.equal(t(new Uint8Array(0x40), ".gba"), "");
  assert.equal(t(null, ".gba"), "");
});

test("readFsRomHeader reads the header out of the emulator FS", async () => {
  const app = await loadApp();
  const rom = new Uint8Array(0x200000); // 2 MB, to make the point
  gbaRom("POKEMON EMER").forEach((b, i) => (rom[i] = b));
  app.sandbox.FS.files.set("rom.gba", rom);

  const head = app.api.readFsRomHeader("rom.gba");
  assert.equal(head.length, 0x150, "only the header is copied out");
  assert.equal(app.api.romHeaderTitle(head, ".gba"), "POKEMON EMER");

  // A missing file is a "" name, not an exception.
  assert.equal(app.api.readFsRomHeader("nope.gba"), null);
});

test("gameDisplayName: library name wins, header is the fallback", async () => {
  const app = await loadApp();
  app.api.currentHeaderTitle = "POKEMON EMER";

  // Nothing loaded: the header alone is not a running game, but it IS the name
  // if one is running under an unhelpful filename.
  app.api.currentOriginalName = null;
  assert.equal(app.api.gameDisplayName(), "POKEMON EMER");

  // The library name is the nicer string and takes precedence.
  app.api.currentOriginalName = "Pokemon Emerald.gba";
  assert.equal(app.api.gameDisplayName(), "Pokemon Emerald");

  // No header, no library entry: empty, which callers read as "no game".
  app.api.currentHeaderTitle = "";
  app.api.currentOriginalName = null;
  assert.equal(app.api.gameDisplayName(), "");
});

test("document.title and Media Session follow the running game", async () => {
  const app = await loadApp();
  const ms = app.sandbox.navigator.mediaSession;

  // Library: plain product name, no metadata.
  assert.equal(app.document.title, "dingbat");
  assert.equal(ms.metadata, null);

  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "Pokemon Emerald.gba";
  app.api.currentHeaderTitle = "POKEMON EMER";
  app.api.paused = false;
  app.api.syncNowPlaying();

  assert.equal(app.document.title, "Pokemon Emerald " + EM + " dingbat");
  assert.equal(ms.metadata.title, "Pokemon Emerald");
  assert.equal(ms.metadata.artist, "dingbat");
  assert.ok(Array.isArray(ms.metadata.artwork), "artwork is always an array");
  assert.equal(ms.playbackState, "playing");

  // Pausing is a playbackState change, not a teardown.
  app.api.paused = true;
  app.api.syncNowPlaying();
  assert.equal(ms.playbackState, "paused");
  assert.equal(ms.metadata.title, "Pokemon Emerald");

  // Back at the library.
  app.api.currentRomName = null;
  app.api.currentOriginalName = null;
  app.api.currentHeaderTitle = "";
  app.api.syncNowPlaying();
  assert.equal(app.document.title, "dingbat");
  assert.equal(ms.metadata, null);
  assert.equal(ms.playbackState, "none");
});

test("lock-screen play/pause drives the emulator's own pause state", async () => {
  const app = await loadApp();
  const ms = app.sandbox.navigator.mediaSession;

  // Only play/pause/stop are claimed — no seek, no track skipping.
  const claimed = Object.keys(app.state.mediaActions).sort();
  assert.deepEqual(claimed, ["pause", "play", "stop"]);

  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "Pokemon Emerald.gba";
  app.api.paused = false;
  app.api.syncNowPlaying();

  app.state.mediaActions.pause();
  assert.equal(app.api.paused, true, "lock-screen Pause pauses the emulator");
  assert.equal(ms.playbackState, "paused");

  app.state.mediaActions.play();
  assert.equal(app.api.paused, false, "lock-screen Play resumes it");
  assert.equal(ms.playbackState, "playing");

  // With no game loaded the handlers are inert — they must not un-pause an
  // orphaned core sitting behind the home screen.
  app.api.currentRomName = null;
  app.api.paused = true;
  app.state.mediaActions.play();
  assert.equal(app.api.paused, true);
});

test("the pause button and the lock screen stay in step", async () => {
  const app = await loadApp();
  const ms = app.sandbox.navigator.mediaSession;
  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "Pokemon Emerald.gba";
  app.api.paused = false;
  app.api.syncNowPlaying();
  // The click path has a 350ms lockout vs the pointerup handler; a fresh vm's
  // performance.now() is still inside it (see pause-sync.test.mjs).
  app.runIn("pausePointerTs = -10000;");

  await app.elements.get("pause").dispatch("click");
  assert.equal(app.api.paused, true);
  assert.equal(ms.playbackState, "paused");

  await app.elements.get("pause").dispatch("click");
  assert.equal(app.api.paused, false);
  assert.equal(ms.playbackState, "playing");
});

test("no Media Session API: the page title still works, nothing throws", async () => {
  const app = await loadApp();
  delete app.sandbox.navigator.mediaSession;

  app.api.currentRomName = "rom.gb";
  app.api.currentOriginalName = "Link's Awakening.gb";
  app.api.syncNowPlaying();
  assert.equal(app.document.title, "Link's Awakening " + EM + " dingbat");
});

// --- Live presentation and artwork freshness --------------------------------
// A game is live media, not a track: the Now Playing card must not show a
// timeline, and the picture on it must not be a frozen title screen an hour in.

test("the card is declared live media, not a 0:00 / 0:00 track", async () => {
  const app = await loadApp();
  const ms = app.sandbox.navigator.mediaSession;

  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "Pokemon Emerald.gba";
  app.api.paused = false;
  app.api.syncNowPlaying();

  // +Infinity duration is the spec's "indefinite / live stream". The visible
  // effect is the scrubber disappearing.
  assert.ok(ms.positionState, "position state is declared while running");
  assert.equal(ms.positionState.duration, Infinity);
  assert.equal(ms.positionState.position, 0);
  assert.equal(ms.positionState.playbackRate, 1);

  // A paused game is still live media (a paused stream, not a finite track):
  // pause is expressed through playbackState alone.
  app.api.paused = true;
  app.api.syncNowPlaying();
  assert.equal(ms.playbackState, "paused");
  assert.equal(ms.positionState.duration, Infinity);

  // Back at the library the claim is withdrawn, not left standing.
  app.api.paused = false;
  app.api.currentRomName = null;
  app.api.currentOriginalName = null;
  app.api.syncNowPlaying();
  assert.equal(ms.positionState, null, "cleared, not still claiming a live game");
  assert.ok(ms.positionCalls > 0);
});

test("an engine that rejects a non-finite duration is not fatal", async () => {
  const app = await loadApp();
  const ms = app.sandbox.navigator.mediaSession;
  const calls = [];
  ms.setPositionState = (init) => {
    calls.push(init);
    if (init && !Number.isFinite(init.duration)) throw new TypeError("bad duration");
  };

  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "Pokemon Emerald.gba";
  app.api.paused = false;
  app.api.syncNowPlaying();

  assert.equal(calls.length, 2, "the throwing call falls back to a clear");
  assert.equal(calls[1], undefined, "which is setPositionState() with no argument");
  // And the throw stays inside the position-state helper: the metadata, which
  // is the whole point of the block, still lands.
  assert.equal(ms.metadata.title, "Pokemon Emerald");
  assert.equal(ms.playbackState, "playing");
});

test("no setPositionState in the engine: everything else still publishes", async () => {
  const app = await loadApp();
  const ms = app.sandbox.navigator.mediaSession;
  delete ms.setPositionState;

  app.api.currentRomName = "rom.gb";
  app.api.currentOriginalName = "Link's Awakening.gb";
  app.api.paused = false;
  app.api.syncNowPlaying();
  assert.equal(ms.metadata.title, "Link's Awakening");
  assert.equal(ms.playbackState, "playing");
});

test("snapshot artwork refreshes on a timer; box art and paused games do not", async () => {
  const app = await loadApp();
  const ms = app.sandbox.navigator.mediaSession;
  const N = app.api.NOWPLAYING_SNAPSHOT_TICKS;
  assert.ok(N >= 10, "the refresh interval is in poll ticks (~1 s each)");

  app.api.currentRomName = "rom.gba";
  app.api.currentOriginalName = "Pokemon Emerald.gba";
  app.api.paused = false;
  app.api.nowPlayingArtURL = null;   // no box art -> the artwork IS the snapshot
  app.api.syncNowPlaying();
  let meta = ms.metadata;
  assert.ok(meta);

  // Publishing rebuilds MediaMetadata, so object identity is the observation
  // point: same object == the poll stayed free.
  for (let i = 0; i < N - 1; i++) app.api.nowPlayingPoll();
  assert.equal(ms.metadata, meta, "no churn between refreshes");

  app.api.nowPlayingPoll();
  assert.notEqual(ms.metadata, meta, "the snapshot is re-published on the tick");
  meta = ms.metadata;

  // The counter restarts, rather than republishing every tick from here on.
  app.api.nowPlayingPoll();
  assert.equal(ms.metadata, meta, "and the interval starts over");

  // Box art held: a stable object URL, so a re-publish could only ever produce
  // an identical card.
  app.api.nowPlayingArtURL = "blob:boxart";
  for (let i = 0; i < N * 2; i++) app.api.nowPlayingPoll();
  assert.equal(ms.metadata, meta, "box art is never re-published on a timer");

  // Paused: the frozen frame is the CORRECT picture of a frozen game.
  app.api.nowPlayingArtURL = null;
  app.api.paused = true;
  app.api.nowPlayingPoll();          // picks up the pause through syncNowPlaying
  meta = ms.metadata;
  for (let i = 0; i < N * 2; i++) app.api.nowPlayingPoll();
  assert.equal(ms.metadata, meta, "a paused game never re-captures");

  // Nothing running at all: no captures behind the home screen either.
  app.api.paused = false;
  app.api.currentRomName = null;
  app.api.currentOriginalName = null;
  app.api.nowPlayingPoll();
  meta = ms.metadata;
  for (let i = 0; i < N * 2; i++) app.api.nowPlayingPoll();
  assert.equal(ms.metadata, meta);
});

// --- The iOS backing element ------------------------------------------------
// WebKit hangs Now Playing off a *media element*, so iOS gets a silent one for
// the life of the page. Backing it with a MediaStream rather than a 0.25 s WAV
// is what makes the card render as live: a stream-backed element has an
// infinite intrinsic duration, a file-backed one reports the file's.

const fakeAudioCtx = () => {
  const nodes = [];
  const node = (kind, extra = {}) => {
    const n = {
      kind, out: null, inputs: [],
      connect(to) { this.out = to; to.inputs.push(this); },
      ...extra,
    };
    nodes.push(n);
    return n;
  };
  return {
    nodes,
    createMediaStreamDestination: () => node("dest", { stream: { id: "silent-stream" } }),
    createGain: () => node("gain", { gain: { value: 1 } }),
    createConstantSource: () => node("const", {
      started: false,
      start() { this.started = true; },
    }),
  };
};

test("the iOS backing element is a silent MediaStream, not a file", async () => {
  const app = await loadApp();
  const ctx = fakeAudioCtx();
  const el = app.api.makeSilentLoopEl(ctx);

  assert.equal(el.srcObject && el.srcObject.id, "silent-stream",
               "backed by the stream (infinite duration => the live card style)");
  assert.equal(el.src, undefined, "and by no media file at all");
  // Muting is NOT how this element is kept quiet: iOS has historically declined
  // to count a muted element towards Now Playing.
  assert.notEqual(el.muted, true);

  const dest = ctx.nodes.find((n) => n.kind === "dest");
  const gain = ctx.nodes.find((n) => n.kind === "gain");
  const src = ctx.nodes.find((n) => n.kind === "const");
  assert.equal(gain.gain.value, 0, "silent by construction");
  assert.equal(src.out, gain, "the one source runs through that zero gain");
  assert.equal(gain.out, dest);
  assert.ok(src.started, "a source that never starts produces no stream data");
  // The game's own audio must never be routed in here — it is already audible
  // through the context destination, and a tap would double it.
  assert.equal(dest.inputs.length, 1);
});

test("no MediaStream support: the silent WAV loop is still the fallback", async () => {
  const app = await loadApp();

  // An AudioContext without createMediaStreamDestination (or none at all,
  // pre-unlock) takes the file path.
  for (const ctx of [{}, null, undefined]) {
    const el = app.api.makeSilentLoopEl(ctx);
    assert.equal(el.srcObject, null);
    assert.ok(String(el.src).startsWith("blob:"), "falls back to the silent WAV");
    assert.equal(el.loop, true, "which must loop, being 0.25 s long");
  }

  // A media element with no srcObject property at all (older WebKit) also
  // falls back, even though the context could have provided a stream.
  app.sandbox.Audio = class {
    constructor(src) { this.src = src; this.loop = false; this.paused = true; }
    play() { this.paused = false; return Promise.resolve(); }
    pause() { this.paused = true; }
  };
  const el = app.api.makeSilentLoopEl(fakeAudioCtx());
  assert.ok(String(el.src).startsWith("blob:"));
  assert.equal(el.srcObject, undefined);
});

test("the backing element is iOS-only", async () => {
  const app = await loadApp();
  // Desktop: no ringer switch to defeat, and a permanent "this tab is playing
  // audio" indicator would be a regression.
  assert.equal(app.api.needsSilentLoop(), false);
  app.sandbox.navigator.userAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15";
  assert.equal(app.api.needsSilentLoop(), true);
});
