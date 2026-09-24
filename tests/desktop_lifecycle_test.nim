## The desktop's game lifecycle (src/dingbat/frontend/game_load.nim, called by
## load_rom in src/dingbat.nim; formal/DesktopState/GameLifecycle.lean):
## a file that is not a ROM is refused before anything of the running game is
## touched, instead of an IndexDefect out of main(), and a .gb shorter than a
## cartridge plays, padded with $FF, in the core the web shares; a GBA game's
## battery is written when its core is dropped or the app quits, including one
## a state load restored while paused, and a write that fails is reported, not
## raised;
## a zip extracts to one cache folder however its path is spelled; a ROM path
## with no extension keeps its battery file beside it, not `<parent>.sav`.

import std/[os, hashes, strformat, strutils, tables, tempfiles]
import zippy/ziparchives
import dingbat/frontend/game_load
import dingbat/gb/gb
import dingbat/gba/gba
import dingbat/common/serialize

let dir = createTempDir("dingbat_lifecycle_", "")

proc opts(): CoreOptions =
  CoreOptions(headless: true, use_hle: true)

proc short_gb(n: int; cart_type = 0x00): string =
  ## The first `n` bytes of a 32 KiB cart that jumps to $0150 and runs NOPs
  ## to the end of the file and on into whatever lies past it, with marks at
  ## the bank edges. Past the file the core sees $FF: RST $38 over and over,
  ## whose pushes walk the stack through the whole address space, cartridge
  ## registers and RAM included, every eight frames or so.
  var rom = newString(0x8000)                 # $00 = NOP
  rom[0x101] = char(0xC3)                     # jp $0150
  rom[0x102] = char(0x50)
  rom[0x103] = char(0x01)
  rom[0x147] = char(cart_type)
  rom[0x1FFF] = char(0xA1)
  rom[0x3FFF] = char(0xB2)
  rom[0x4000] = char(0xC3)
  rom.setLen(min(n, rom.len))
  if n > 0x8000: rom.add(newString(n - 0x8000))
  rom

block short_gb_files_run:
  # The GB core as the web builds it (no size check in front): a file shorter
  # than a cart, or not a whole number of 16 KiB banks, ran off the end of
  # `rom` (IndexDefect in the constructor or at the first frame). It is now
  # padded with $FF to a power of two, at least 32 KiB, and plays.
  for (n, kind) in [(0, 0x00), (0x100, 0x00), (0x150, 0x00), (0x2000, 0x00),
                    (0x4000, 0x00), (0x4001, 0x00), (0x4001, 0x01),
                    (0x8001, 0x01), (0xC000, 0x01)]:
    let p = dir / "short.gb"
    let file = short_gb(n, kind)
    writeFile(p, file)
    let g = new_gb("", p, fifo = true, headless = true, run_bios = false)
    g.post_init()
    for _ in 0 ..< 30: g.run_until_frame()
    let rom = g.cartridge.rom
    var want = 0x8000
    while want < n: want = want shl 1
    doAssert rom.len == want, &"{n:#x}: {rom.len:#x}"
    for i in 0 ..< n: doAssert rom[i] == uint8(file[i]), &"{n:#x} @{i:#x}"
    for i in n ..< rom.len: doAssert rom[i] == 0xFF, &"{n:#x} @{i:#x}"
    # Every bank a mapper can select stays inside the image.
    for bank in [0, 1, 2, 3, 5, 0x1F]:
      g.cartridge.mbc_write(0x2000, uint8(bank))
      discard g.cartridge.mbc_read(0x4000)
      discard g.cartridge.mbc_read(0x7FFF)
    # Save states name the file as it is on disk, as they always did.
    let st = g.state_bytes()
    doAssert g.state_is_for(st)
    doAssert g.state_rom_identity() == fnv1a(file), &"{n:#x}"
    doAssert g.load_state_bytes(st)

block short_roms_are_refused:
  # A .gb too short to hold a cartridge header is not a ROM; one that holds
  # the header builds (the core pads it, above).
  for n in [0, 0x14F]:
    let p = dir / "short.gb"
    writeFile(p, newString(n))
    let b = build_core(p, opts())
    doAssert b.error.len > 0 and b.gb == nil and b.gba == nil, $n
  for n in [0x150, 0x4000]:
    let p = dir / "short.gb"
    writeFile(p, short_gb(n))
    let b = build_core(p, opts())
    doAssert b.error == "" and b.gb != nil, $n
    for _ in 0 ..< 30: b.gb.run_until_frame()
  # A .gba is refused only when empty: its core reads open bus past any file,
  # and this repo's own test ROMs include a 56-byte one.
  block:
    let p = dir / "short.gba"
    writeFile(p, "")
    let b = build_core(p, opts())
    doAssert b.error.len > 0 and b.gb == nil and b.gba == nil
  for n in [1, 0xBF]:
    let p = dir / "short.gba"
    writeFile(p, newString(n))
    let b = build_core(p, opts())
    doAssert b.error == "" and b.gba != nil, $n
    for _ in 0 ..< 5: b.gba.run_until_frame()
  let inputrec = dir / "inputrec.gba"     # a copy: nothing written in tests/
  copyFile(currentSourcePath().parentDir / "roms" / "inputrec.gba", inputrec)
  doAssert getFileSize(inputrec) == 56
  let b = build_core(inputrec, opts())
  doAssert b.error == "" and b.gba != nil
  for _ in 0 ..< 5: b.gba.run_until_frame()

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

block gb_extensions_pick_the_gb_core:
  # `.cgb` and `.sgb` are Game Boy carts too: they went to the GBA core (a
  # screen of noise), the file dialog hid them and a drop ignored them.
  # `.dmg` stays out: on macOS it is a disk image.
  for name in ["color.cgb", "super.sgb", "LOUD.CGB", "plain.gbc"]:
    let p = dir / name
    writeFile(p, short_gb(0x8000))
    doAssert is_gb_rom(p) and is_rom_file(p), name
    let b = build_core(p, opts())
    doAssert b.error == "" and b.gb != nil and b.gba == nil, name
    b.gb.run_until_frame()
    doAssert name.splitFile.ext.toLowerAscii()[1 .. ^1] in ROM_DIALOG_EXTS, name
  doAssert not is_gb_rom(dir / "a.gba") and is_rom_file(dir / "a.gba")
  doAssert is_rom_file(dir / "a.ZIP") and not is_gb_rom(dir / "a.zip")
  doAssert not is_rom_file(dir / "installer.dmg") and not is_rom_file(dir / "a.txt")
  doAssert "gba" in ROM_DIALOG_EXTS and "zip" in ROM_DIALOG_EXTS
  # The first ROM in a zip, whichever of the names it has.
  var entries = initTable[string, string]()
  entries["readme.txt"] = "hi"
  entries["Color.cgb"] = short_gb(0x8000)
  writeFile(dir / "color.zip", createZipArchive(entries))
  let rom = extract_zip_rom(dir / "cgbcache", dir / "color.zip")
  doAssert rom.extractFilename() == "Color.cgb", rom
  doAssert build_core(rom, opts()).gb != nil

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

block extensionless_paths:
  # The command line takes any path; with no extension, "up to the last dot"
  # cut into the folder name ("<dir>/d.sav") or left ".sav" in the cwd.
  let sub = dir / "d.x"
  createDir(sub)
  var rom = newString(0x400)
  for i, c in "SRAM_V113": rom[0x200 + i] = c
  writeFile(sub / "game", rom)
  let a = build_core(sub / "game", opts()).gba
  doAssert a != nil and a.storage.save_path == sub / "game.sav", a.storage.save_path
  var gbrom = newString(0x8000)
  gbrom[0x147] = char(0x03)
  gbrom[0x149] = char(0x02)
  writeFile(sub / "gbgame", gbrom)
  let g = new_gb("", sub / "gbgame", fifo = true, headless = true, run_bios = false)
  doAssert g.cartridge.sav_path == sub / "gbgame.sav", g.cartridge.sav_path

removeDir(dir)
echo "ok"
