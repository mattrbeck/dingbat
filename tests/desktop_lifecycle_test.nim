## The desktop's game lifecycle (src/dingbat/frontend/game_load.nim, called by
## load_rom in src/dingbat.nim; formal/DesktopState/GameLifecycle.lean):
## a file that is not a ROM is refused before anything of the running game is
## touched, instead of an IndexDefect out of main(); a GBA game's battery is
## written when its core is dropped or the app quits, including one a state
## load restored while paused, and a write that fails is reported, not raised;
## a zip extracts to one cache folder however its path is spelled.

import std/[os, hashes, strformat, tables, tempfiles]
import zippy/ziparchives
import dingbat/frontend/game_load
import dingbat/gb/gb
import dingbat/gba/gba

let dir = createTempDir("dingbat_lifecycle_", "")

proc opts(): CoreOptions =
  CoreOptions(headless: true, use_hle: true)

block short_roms_are_refused:
  # Zero bytes, a header's worth, and one byte short of the smallest cart:
  # each one crashed the app (in the constructor or at the first frame).
  for n in [0, 0x150, 0x7FFF]:
    let p = dir / "short.gb"
    writeFile(p, newString(n))
    let b = build_core(p, opts())
    doAssert b.error.len > 0 and b.gb == nil and b.gba == nil, $n
  for n in [0, 0xBF]:
    let p = dir / "short.gba"
    writeFile(p, newString(n))
    let b = build_core(p, opts())
    doAssert b.error.len > 0 and b.gb == nil and b.gba == nil, $n

block missing_file_is_refused:
  let b = build_core(dir / "gone.gba", opts())
  doAssert b.error.len > 0 and b.gba == nil

block good_roms_build:
  let gbp = dir / "ok.gb"
  writeFile(gbp, newString(0x8000))
  let g = build_core(gbp, opts())
  doAssert g.error == "" and g.gb != nil and g.gba == nil
  g.gb.run_until_frame()
  let gbap = dir / "ok.gba"
  writeFile(gbap, newString(0x400))
  let a = build_core(gbap, opts())
  doAssert a.error == "" and a.gba != nil and a.gb == nil

proc sram_rom(name: string): string =
  ## A GBA ROM the storage scan reads as a 32 KiB SRAM cart.
  var rom = newString(0x400)
  let tag = "SRAM_V113"
  for i, c in tag: rom[0x200 + i] = c
  result = dir / name
  writeFile(result, rom)

block gba_battery_flushed:
  # The per-frame write never sees the last frame's change, nor a battery a
  # state load restored while paused; the flush on a switch and at quit does.
  let b = build_core(sram_rom("flush.gba"), opts())
  let g = b.gba
  doAssert g != nil and g.storage.save_path == dir / "flush.sav"
  g.storage.memory[0] = 1
  g.storage.dirty = true
  doAssert flush_batteries(g, nil) == ""
  doAssert not g.storage.dirty and readFile(dir / "flush.sav")[0] == char(1)
  let st = dir / "flush.state"
  doAssert g.save_state(st)
  g.storage.memory[0] = 2
  g.storage.dirty = true
  doAssert flush_batteries(g, nil) == ""
  doAssert readFile(dir / "flush.sav")[0] == char(2)
  doAssert g.load_state(st)          # paused Quick Load: no frame runs after
  doAssert flush_batteries(g, nil) == ""
  doAssert readFile(dir / "flush.sav")[0] == char(1)

block gba_battery_write_failure_is_reported:
  # A folder dingbat cannot write: the error comes back, the RAM stays dirty
  # for the next try, and nothing is raised out of the caller.
  let g = build_core(sram_rom("ro.gba"), opts()).gba
  g.storage.save_path = dir / "no-such-folder" / "ro.sav"
  g.storage.memory[0] = 7
  g.storage.dirty = true
  doAssert flush_batteries(g, nil).len > 0
  doAssert g.storage.dirty

block gb_battery_flushed:
  var rom = newString(0x8000)
  rom[0x147] = char(0x03)   # MBC1 + RAM + battery
  rom[0x149] = char(0x02)   # 8 KiB
  writeFile(dir / "gbflush.gb", rom)
  let g = build_core(dir / "gbflush.gb", opts()).gb
  g.cartridge.ram[0] = 9
  g.cartridge.ram_dirty = true
  doAssert flush_batteries(nil, g) == ""
  doAssert readFile(dir / "gbflush.sav")[0] == char(9)

block zip_one_identity:
  # `dingbat z.zip` from a terminal and dragging the same zip in used to
  # extract to two folders, each with its own .sav.
  let zdir = dir / "zips"
  createDir(zdir)
  var entries = initTable[string, string]()
  entries["Z.gba"] = newString(0x400)
  writeFile(zdir / "z.zip", createZipArchive(entries))
  let cache = dir / "cache"
  let absolute = extract_zip_rom(cache, zdir / "z.zip")
  let here = getCurrentDir()
  setCurrentDir(zdir)
  let relative = extract_zip_rom(cache, "z.zip")
  setCurrentDir(here)
  doAssert absolute.len > 0 and absolute.extractFilename() == "Z.gba"
  doAssert relative == absolute, relative & " vs " & absolute

block zip_adopts_earlier_folder:
  # The folder an earlier build made (keyed by `hash` of the path as given)
  # holds the zip's save; the new key takes it over rather than orphan it.
  let zip = dir / "zips" / "z.zip"
  let cache = dir / "cache2"
  let old = cache / &"z-{cast[uint32](hash(zip)):08x}"
  createDir(old)
  writeFile(old / "Z.sav", "progress")
  let rom = extract_zip_rom(cache, zip)
  doAssert rom.len > 0 and readFile(rom.parentDir / "Z.sav") == "progress"
  doAssert not dirExists(old)

removeDir(dir)
echo "ok"
