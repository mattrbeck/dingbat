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
