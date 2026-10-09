## The desktop's DS Beta (Settings > General > Advanced; docs/nds/desktop.md).
## Off (the default) the app is what it was: a .nds is no ROM to the file
## dialog or a drop, a zip holding only one has no ROM in it, the DS's
## bindings hold nothing, and the settings file is byte for byte the one a
## build without the setting writes. On, a DS game builds, runs and keeps
## its battery, firmware settings, states and rewind
## (src/dingbat/frontend/nds_game.nim), and draws its 3D at the 3D
## resolution set (HD 3D). The game checks need a homebrew ROM
## from ~/.cache/dingbat-nds/roms (never in the repo) and are skipped
## without one (CI).

import std/[os, strutils, tables, tempfiles]
import zippy/ziparchives
import dingbat/common/[config, input, rewind, serialize]
import dingbat/frontend/[game_load, held_input, nds_game]
import dingbat/nds/nds except Input
import dingbat/nds/savestate

var failures = 0

proc check(cond: bool; msg: string) =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg
    failures.inc

let dir = createTempDir("dingbat_nds_desktop_", "")
let ndsRoms = getEnv("DINGBAT_NDS_ROMS", getHomeDir() / ".cache/dingbat-nds/roms")

proc header_only_nds(): string =
  ## 512 bytes that pass the DS header check (the logo CRC), and nothing else.
  result = newString(0x200)
  result[0x15C] = char(0x56)
  result[0x15D] = char(0xCF)

proc zip_of(name, entry, data: string): string =
  result = dir / name
  let archive = ZipArchive()
  archive.contents[entry] = ArchiveEntry(contents: data)
  archive.writeZipArchive(result)

echo "Off: .nds files are no ROMs, as before"
block:
  check not is_rom_file("game.nds") and not is_rom_file("/x/GAME.NDS"),
        "a drop or the dialog's own check takes no .nds"
  check "nds" notin ROM_DIALOG_EXTS, "the Open ROM dialog lists no .nds"
  check ROM_DIALOG_EXTS == @["gba", "gb", "gbc", "cgb", "sgb", "zip"],
        "and lists what it did"
  let z = zip_of("only_ds.zip", "game.nds", header_only_nds())
  check extract_zip_rom(dir / "zip-cache", z) == "", "a zip of a DS game has no ROM in it"
  let mixed = dir / "mixed.zip"
  let archive = ZipArchive()
  archive.contents["a.nds"] = ArchiveEntry(contents: header_only_nds())
  archive.contents["b.gba"] = ArchiveEntry(contents: newString(0x400))
  archive.writeZipArchive(mixed)
  check extract_zip_rom(dir / "zip-cache", mixed).endsWith("b.gba"),
        "a zip with a GBA game beside it opens the GBA game"

echo "Off: the settings file is the one it was"
block:
  let cfg = new_config()
  check not cfg.ds_beta, "DS Beta defaults off"
  let path = dir / "off.yml"
  save_config_file(cfg, path)
  let text = readFile(path)
  # The key, quoted: a path in the file (the checkout's own) may hold "nds".
  check "\"nds\"" notin text, "a default file names nothing of the DS"
  check text.endsWith("  sgb_border: true\n"), "and ends where it always did"
  # Keys a build without DS Beta never wrote are still not written when
  # the DS's own settings are at their defaults
  let back = load_config_file(path)
  check not back.ds_beta and back.nds_keybindings == default_ds_keybindings() and
        back.nds_controller_bindings == default_ds_controller_bindings(),
        "and reads back with the DS's defaults"

echo "Off: the DS's X and Y keys hold nothing"
block:
  var h: HeldInput
  let d = cint(ord('d'))
  check route_key(h, default_keybindings(), d, true, false, false, false, false) == krNone,
        "D goes nowhere"
  check h.held() == {} and h.ds_held() == {}, "nothing is held"
  discard route_key(h, default_keybindings(), d, false, false, false, false, false)
  # With a DS game's bindings (passed only while one runs)
  discard route_key(h, default_keybindings(), d, true, false, false, false, false,
                    default_ds_keybindings())
  check h.ds_held() == {dsX} and h.held() == {}, "a DS game's D is X"
  check h.take_ds_changes() == ({dsX}, {}), "the core is told X"
  discard route_key(h, default_keybindings(), d, false, false, false, false, false)
  check h.ds_held() == {} and h.take_ds_changes() == ({}, {dsX}),
        "its release lets go whatever the bindings are by then"
  # A pad's X is the DS's X in a DS game, and A otherwise
  h.pad_added(7)
  h.pad_ds_button(7, 2, dsX, true)
  check h.ds_held() == {dsX} and h.held() == {}, "pad X holds DS X"
  h.pad_button(7, 2, false, A, false)
  h.pad_ds_button(7, 2, dsX, false)
  check h.ds_held() == {} and h.held() == {}, "and lets go"

echo "On: the settings come back"
block:
  let cfg = new_config()
  cfg.ds_beta = true
  cfg.nds_bios9_path = "/b/bios9.bin"
  cfg.nds_bios7_path = "/b/bios7.bin"
  cfg.nds_firmware_path = "/b/firmware.bin"
  cfg.nds_keybindings = {cint(ord('i')): dsX, cint(ord('u')): dsY}.toTable
  cfg.nds_controller_bindings = initTable[cint, DsInput]()
  let path = dir / "on.yml"
  save_config_file(cfg, path)
  let back = load_config_file(path)
  check back.ds_beta, "DS Beta"
  check back.nds_bios9_path == "/b/bios9.bin" and back.nds_bios7_path == "/b/bios7.bin" and
        back.nds_firmware_path == "/b/firmware.bin", "the dumps"
  check back.nds_keybindings == cfg.nds_keybindings, "the keys"
  check back.nds_controller_bindings.len == 0, "no pad buttons (unbound stays unbound)"
  check back.nds_hd == 1, "the 3D resolution stays native"
  check same_file(back, cfg), "the same file"
  # Turned off again, the section goes and the file is a default one
  back.ds_beta = false
  back.nds_bios9_path = ""; back.nds_bios7_path = ""; back.nds_firmware_path = ""
  back.nds_keybindings = default_ds_keybindings()
  back.nds_controller_bindings = default_ds_controller_bindings()
  save_config_file(back, path)
  save_config_file(new_config(), dir / "default.yml")
  let a = readFile(path).splitLines()
  let b = readFile(dir / "default.yml").splitLines()
  check "\"nds\"" notin readFile(path) and a.len == b.len, "off again: no DS section"
  # A second window's DS Beta survives this one's save
  let other = load_config_file(path)
  other.ds_beta = true
  save_config_file(other, path)
  back.volume = 40
  save_config_file(back, path)
  let merged = load_config_file(path)
  check merged.ds_beta and merged.volume == 40, "another window's DS Beta is kept"
  # Reset to Defaults keeps the dumps, as it keeps the GBA BIOS
  merged.nds_bios9_path = "/b/bios9.bin"
  merged.reset_to_defaults()
  check not merged.ds_beta and merged.nds_bios9_path == "/b/bios9.bin",
        "Reset to Defaults: DS Beta off, the dumps kept"

echo "The DS 3D resolution is in the file only when it is not native"
block:
  let cfg = new_config()
  check cfg.nds_hd == 1, "native by default"
  let path = dir / "hd.yml"
  cfg.nds_hd = 3
  save_config_file(cfg, path)
  let text = readFile(path)
  check "\nnds:\n  hd: 3\n" in text, "3x is written under nds: hd"
  check "beta" notin text, "on its own (DS Beta is not written with it)"
  let back = load_config_file(path)
  check back.nds_hd == 3 and same_file(back, cfg), "and reads back"
  back.nds_hd = 1
  save_config_file(back, path)
  save_config_file(new_config(), dir / "hd_default.yml")
  check readFile(path).splitLines().len == readFile(dir / "hd_default.yml").splitLines().len and
        "\"nds\"" notin readFile(path) and "hd:" notin readFile(path),
        "native again: the line goes"
  writeFile(path, readFile(dir / "hd_default.yml") & "nds:\n  hd: 9\n")
  check load_config_file(path).nds_hd == 4, "a value past 4x reads as 4x"
  let r = load_config_file(path)
  r.reset_to_defaults()
  check r.nds_hd == 1, "Reset to Defaults: native"

echo "On: .nds files open"
block:
  check "nds" in ROM_DIALOG_EXTS_DS and ".nds" in ROM_EXTS_DS, "the dialog lists .nds"
  let z = dir / "only_ds.zip"
  let got = extract_zip_rom(dir / "zip-cache", z, ROM_EXTS_DS)
  check got.endsWith("game.nds") and fileExists(got), "a zip's DS game is extracted"
  check is_nds_file(dir / "x.nds"), ".nds is a DS game by its name"
  writeFile(dir / "renamed.bin", header_only_nds())
  check is_nds_file(dir / "renamed.bin"), "another name's file by its header"
  writeFile(dir / "not.bin", newString(0x200))
  check not is_nds_file(dir / "not.bin"), "a file without the header is not"
  check not is_nds_file(dir / "zero.gba"), "a GBA name never is"
  writeFile(dir / "bad.nds", "not a DS game")
  let bad = build_nds(dir / "bad.nds", NdsPaths())
  check bad.game == nil and bad.error.len > 0, "a .nds that is no DS ROM is refused: " & bad.error

echo "On: the touch screen under the mouse"
block:
  # A 768x1152 picture at (16, 8)
  let view = (16, 8, 768, 1152)
  let t = touch_point(16 + 3 * 100, 8 + 3 * (192 + 50), view)
  check t.bottom and t.x == 100 and t.y == 50, "a point on the bottom screen"
  check not touch_point(16 + 300, 8 + 3 * 100, view).bottom, "the top screen is not touched"
  let off = touch_point(5000, 8 + 3 * 300, view)
  check not off.bottom and off.x == 255 and off.y == 108, "off the edge: clamped"

proc staged(name: string): string =
  ## A copy of test ROM `name` in the temp dir, without a battery file.
  result = dir / name.extractFilename
  copyFile(ndsRoms / name, result)
  removeFile(result.changeFileExt("sav"))

echo "On: a DS game runs"
if not fileExists(ndsRoms / "homebrew-ex/dual_screen.nds"):
  echo "  skip (no ", ndsRoms / "homebrew-ex/dual_screen.nds", ")"
else:
  let rom = staged("homebrew-ex/dual_screen.nds")
  let flash = dir / "nds" / "flash.bin"
  let built = build_nds(rom, NdsPaths(flash: flash))
  check built.error == "" and built.game != nil, "builds: " & built.error
  let g = built.game
  for _ in 0 ..< 120: g.run_frame(100, true, true)
  check g.core.gpu.frame_count >= 120, "frames run"
  var pic: seq[uint16]
  g.compose(pic)
  check pic.len == 256 * 384, "one 256x384 picture"
  var top, bottom = 0
  for i in 0 ..< 256 * 192:
    if (pic[i] and 0x7FFF) != 0: inc top
    if (pic[256 * 192 + i] and 0x7FFF) != 0: inc bottom
  check top > 0 and bottom > 0, "both screens drew: " & $top & " / " & $bottom
  # Buttons, X/Y, the stylus and the lid reach the core
  g.press(A, true)
  check (g.core.input.keyinput() and 1) == 0, "A reaches KEYINPUT"
  g.press(A, false)
  g.press(dsY, true)
  check (g.core.input.extkeyin() and 2) == 0, "Y reaches EXTKEYIN"
  g.press(dsY, false)
  g.set_touch(100, 50, true)
  check g.core.input.touching and g.core.input.touch_x == 100, "the stylus touches"
  g.set_lid(true)
  check g.core.input.lid_closed and not g.core.input.touching, "the lid closes and the touch lifts"
  g.set_touch(100, 50, true)
  check not g.core.input.touching, "no touch on a closed console"
  g.set_lid(false)
  check not g.core.input.lid_closed, "and opens"
  # Save states in a slot file
  let slot = dir / "states" / "dual_screen.state"
  check g.save_state_file(slot) and readFile(slot).startsWith("DGBSTATE"), "a state is written"
  let stamp = g.core.state_payload()
  for _ in 0 ..< 30: g.run_frame(100, true, true)
  check g.load_state_file(slot) and g.core.state_payload() == stamp, "and loads back"
  check not g.load_state_file(dir / "nothing.state") and last_state_reject_kind == srkNoFile,
        "an empty slot says so"
  writeFile(dir / "junk.state", "junk")
  check not g.load_state_file(dir / "junk.state") and last_state_reject_kind == srkNotAState,
        "junk is not a state"
  # Rewind: the aligned payloads go round the ring and back
  let ring = new_rewind(REWIND_CAP_BYTES, key_every = 0)
  var marks: seq[string]
  for i in 0 ..< 40:
    g.run_frame(100, true, true)
    if ring.maybe_push(proc(): string = g.core.state_payload(aligned = true)):
      marks.add g.core.state_payload()
  check ring.len >= 3, "rewind keeps snapshots: " & $ring.len
  discard ring.pop()
  let back = ring.pop()
  check back.len > 0 and g.core.load_own_payload(back) and
        g.core.state_payload() == marks[^2], "a popped snapshot is the frame it was"
  # The battery file and the firmware flash
  check g.flush() == "" and not fileExists(g.save_path), "nothing written while nothing changed"
  g.core.cart.backup.data = newSeq[uint8](512)
  g.core.cart.backup.data[3] = 0x5A
  g.core.cart.backup.dirty = true
  g.core.spi.firmware_dirty = true
  g.core.spi.firmware[0x3FE00 + 6] = 0x41   # the nickname's first letter
  check g.flush() == "" and fileExists(g.save_path) and fileExists(flash),
        "the chip and the flash are written"
  check readFile(g.save_path).len == 512 and readFile(g.save_path)[3] == '\x5A',
        "the battery file is the chip"
  let again = build_nds(rom, NdsPaths(flash: flash)).game
  check again != nil and again.core.cart.backup.data.len > 0 and
        again.core.cart.backup.data[3] == 0x5A, "the next boot starts from it"
  check again.core.spi.firmware[0x3FE00 + 6] == 0x41,
        "and from the flash the last game wrote"

echo "On: HD 3D (the 3D resolution)"
if not fileExists(ndsRoms / "built/Simple_Quad.nds"):
  echo "  skip (no ", ndsRoms / "built/Simple_Quad.nds", ")"
else:
  let rom = staged("built/Simple_Quad.nds")
  let plain = build_nds(rom, NdsPaths()).game
  let g = build_nds(rom, NdsPaths()).game
  check plain != nil and g != nil, "builds"
  check g.hd_scale == 1 and g.screen_size() == (256, 384), "native: 256x384"
  check g.top_screen() == (addr g.core.gpu.top[0]) and
        g.bottom_screen() == (addr g.core.gpu.bottom[0]), "the presenter uploads the 1x screens"
  for _ in 0 ..< 30:
    plain.run_frame(100, true, true)
    g.run_frame(100, true, true)
  g.set_hd(2)
  check g.hd_scale == 2 and g.screen_size() == (512, 768), "2x: a 512x768 picture"
  check g.core.gpu.hd_top.len == 512 * 384 and g.core.gpu.hd_bottom.len == 512 * 384 and
        g.top_screen() == (addr g.core.gpu.hd_top[0]) and
        g.bottom_screen() == (addr g.core.gpu.hd_bottom[0]),
        "the presenter uploads the HD screens, 512x384 each"
  var pic, hd: seq[uint16]
  g.compose(pic)
  g.compose(hd, hd = true)
  var scaled_up = true
  for y in 0 ..< 768:
    for x in 0 ..< 512:
      if hd[y * 512 + x] != pic[(y div 2) * 256 + x div 2]: scaled_up = false
  check hd.len == 512 * 768 and scaled_up,
        "turned on, the HD picture is the 1x one scaled up until a frame draws"
  for _ in 0 ..< 30:
    plain.run_frame(100, true, true)
    g.run_frame(100, true, true)
  var want: seq[uint16]
  plain.compose(want)
  g.compose(pic)
  # (Not the whole state: two boots differ by the wall clock's RTC)
  check pic == want, "the 1x screens are what they are without HD"
  g.compose(hd, hd = true)
  var sharper, lit = 0
  for y in 0 ..< 768:
    for x in 0 ..< 512:
      let v = hd[y * 512 + x]
      if (v and 0x7FFF) != 0: inc lit
      if v != pic[(y div 2) * 256 + x div 2]: inc sharper
  check lit > 0 and sharper > 0, "the 3D is drawn at 2x: " & $sharper & " dots finer than 1x"
  # States, rewind: the scale is kept
  let slot = dir / "states" / "Simple_Quad.state"
  check g.save_state_file(slot), "a state is written"
  for _ in 0 ..< 5: g.run_frame(100, true, true)
  check g.load_state_file(slot) and g.hd_scale == 2 and g.screen_size() == (512, 768) and
        g.core.gpu.hd_top.len == 512 * 384, "a state load keeps 2x"
  let snap = g.rewind_payload()
  for _ in 0 ..< 5: g.run_frame(100, true, true)
  check g.rewind_apply(snap) and g.hd_scale == 2, "a rewind keeps 2x"
  g.run_frame(100, true, true)
  check g.core.gpu.hd_top.len == 512 * 384, "and the next frame draws at 2x"
  g.set_hd(1)
  check g.hd_scale == 1 and g.screen_size() == (256, 384) and
        g.top_screen() == (addr g.core.gpu.top[0]), "back to native: 256x384"
  g.compose(hd, hd = true)
  check hd.len == 256 * 384, "and the screenshot is 1x"
  g.set_hd(7)
  check g.hd_scale == 4 and g.screen_size() == (1024, 1536), "past 4x is 4x"

removeDir(dir)
if failures > 0:
  echo failures, " failure(s)"
  quit(1)
echo "all passed"
