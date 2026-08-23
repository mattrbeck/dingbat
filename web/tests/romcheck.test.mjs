// ROM header check: garbage behind a ROM extension prompts (and never
// enters the library on decline); real ROMs and this repo's headerless test
// ROMs load silently.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadApp, u8, eq, settle, fakeFile } from "./helpers.mjs";

const readRom = (rel) => new Uint8Array(readFileSync(new URL(rel, import.meta.url)));

// Correct logo prefix + checksum, no 0xEA branch at byte 3.
const gbaWithHeader = ({ breakLogo = false, breakChecksum = false } = {}) => {
  const rom = new Uint8Array(0xc0 + 16).fill(0x11);
  rom[3] = 0x00; // deliberately not an ARM branch
  const logo = [0x24, 0xff, 0xae, 0x51, 0x69, 0x9a, 0xa2, 0x21];
  logo.forEach((b, i) => (rom[0x04 + i] = b));
  let sum = 0;
  for (let i = 0xa0; i <= 0xbc; i++) sum += rom[i];
  rom[0xbd] = -(sum + 0x19) & 0xff;
  if (breakLogo) rom[0x04] ^= 0xff;
  if (breakChecksum) rom[0xbd] ^= 0xff;
  return rom;
};

const gbWithChecksum = () => {
  const rom = new Uint8Array(0x150).fill(0x22); // logo region wrong on purpose
  let chk = 0;
  for (let i = 0x134; i <= 0x14c; i++) chk = (chk - rom[i] - 1) & 0xff;
  rom[0x14d] = chk;
  return rom;
};

test("looksLikeValidRom: rule matrix", async () => {
  const app = await loadApp();
  const ok = (bytes, ext) => app.api.looksLikeValidRom(bytes, ext);

  assert.ok(ok(u8(0, 0, 0, 0xea), ".gba"), "ARM branch entry alone");
  assert.ok(ok(gbaWithHeader({ breakChecksum: true }), ".gba"), "logo alone");
  assert.ok(ok(gbaWithHeader({ breakLogo: true }), ".gba"), "checksum alone");
  assert.ok(!ok(gbaWithHeader({ breakLogo: true, breakChecksum: true }), ".gba"));
  assert.ok(!ok(new TextEncoder().encode("this is not a rom, just some text"), ".gba"));
  assert.ok(!ok(u8(1, 2), ".gba"), "too short for anything");

  // GB/GBC: checksum arm (logo deliberately wrong).
  assert.ok(ok(gbWithChecksum(), ".gb"));
  assert.ok(!ok(new Uint8Array(0x150).fill(0x22), ".gbc"), "no logo, bad checksum");
  assert.ok(!ok(u8(1, 2, 3), ".gb"), "shorter than the header");

  // Raw objcopy output: .gba passes only via the ARM-branch arm, .gb/.gbc
  // via the rgbfix'd checksum.
  assert.ok(ok(readRom("../../tests/roms/linktest.gba"), ".gba"));
  assert.ok(ok(readRom("../../tests/roms/inputrec.gba"), ".gba"), "56-byte ROM");
  assert.ok(ok(readRom("../../tests/roms/gblinktest.gb"), ".gb"));
  assert.ok(ok(readRom("../../tests/roms/gbhdmatest.gbc"), ".gbc"));
});

test("garbage .gba prompts; decline loads nothing and adds nothing", async () => {
  const app = await loadApp();
  app.runIn("Module.ccall = () => {}");
  const modal = app.document.getElementById("rom-warn-modal");

  app.api.handleRomFile(fakeFile("NotAGame.gba", u8(1, 2, 3, 4, 5)));
  await settle();
  assert.ok(modal.classList.contains("open"), "prompt shown");
  assert.match(app.document.getElementById("rom-warn-text").textContent,
    /NotAGame\.gba.*doesn't look like a valid GBA ROM/);

  await app.document.getElementById("rom-warn-cancel").click();
  await settle();
  assert.ok(!modal.classList.contains("open"), "prompt closed");
  assert.equal(app.idb.size, 0, "nothing stored, no library entry");
});

test("garbage .gba prompts; Load Anyway proceeds exactly as before", async () => {
  const app = await loadApp();
  app.runIn("Module.ccall = () => {}");
  const modal = app.document.getElementById("rom-warn-modal");

  app.api.handleRomFile(fakeFile("Weird.gba", u8(1, 2, 3, 4, 5)));
  await settle();
  assert.ok(modal.classList.contains("open"));

  await app.document.getElementById("rom-warn-load").click();
  await settle();
  await settle();
  assert.ok(!modal.classList.contains("open"));
  eq(app.idb.get("rom:Weird.gba"), { name: "Weird.gba", data: u8(1, 2, 3, 4, 5) });
  eq(app.idb.get("recent").map((r) => r.name), ["Weird.gba"]);
});

test("Escape declines the prompt like Cancel", async () => {
  const app = await loadApp();
  const modal = app.document.getElementById("rom-warn-modal");

  app.api.handleRomFile(fakeFile("NotAGame.gbc", new Uint8Array(0x200).fill(7)));
  await settle();
  assert.ok(modal.classList.contains("open"));
  assert.match(app.document.getElementById("rom-warn-text").textContent,
    /Game Boy Color ROM/);

  await app.dispatchDoc("keydown", { key: "Escape" });
  await settle();
  assert.ok(!modal.classList.contains("open"));
  assert.equal(app.idb.size, 0);
});

test("repo homebrew .gba (no logo, no checksum) loads without a prompt", async () => {
  const app = await loadApp();
  app.runIn("Module.ccall = () => {}");
  const modal = app.document.getElementById("rom-warn-modal");

  app.api.handleRomFile(fakeFile("linktest.gba", readRom("../../tests/roms/linktest.gba")));
  await settle();
  await settle();
  assert.ok(!modal.classList.contains("open"), "no prompt for homebrew");
  eq(app.idb.get("recent").map((r) => r.name), ["linktest.gba"]);
});

test("valid-headered ROM loads without a prompt", async () => {
  const app = await loadApp();
  app.runIn("Module.ccall = () => {}");
  const modal = app.document.getElementById("rom-warn-modal");

  app.api.handleRomFile(fakeFile("Real Game.gba", gbaWithHeader()));
  await settle();
  await settle();
  assert.ok(!modal.classList.contains("open"));
  eq(app.idb.get("recent").map((r) => r.name), ["Real Game.gba"]);
});
