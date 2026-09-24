## The parts of the desktop's `load_rom` that need no window: building the
## next core without touching the running one, writing battery RAM out before
## a core is dropped, and where a zip's ROM is extracted to. No SDL, ImGui or
## GL here, so tests/desktop_lifecycle_test.nim builds headless.

import std/[os, hashes, strformat, strutils]
import zippy/ziparchives
import ../common/linkproto
import ../gba/gba
import ../gb/gb

const ROM_EXTS* = [".gba", ".gb", ".gbc"]

# The smallest file taken as a ROM. Both cores run any length (the GB core
# pads to a whole cartridge with $FF, the GBA core reads open bus past the
# file), so this is only what is too short to be a game: a Game Boy file
# that cannot hold the cartridge header ($0100-$014F), or an empty file.
# GBA test ROMs as short as 56 bytes exist, header or not.
const
  GB_MIN_ROM  = 0x150
  GBA_MIN_ROM = 1

type
  CoreOptions* = object
    ## What `build_core` hands the constructors, from the config.
    gb_bootrom*:     string
    gb_fifo*:        bool
    headless*:       bool
    gb_run_bios*:    bool
    sgb*:            bool
    bios_path*:      string
    run_bios*:       bool
    use_hle*:        bool
    hle_after_bios*: bool

  BuiltCore* = object
    ## Exactly one of `gba`/`gb` is set, or neither and `error` says why.
    gba*:    GBA
    gb*:     GB
    error*:  string  ## one sentence for the player
    detail*: string  ## the underlying message, for the log / a hint line

proc is_gb_rom*(rom_path: string): bool =
  rom_path.splitFile().ext.toLowerAscii() in [".gb", ".gbc"]

proc build_core*(rom_path: string; o: CoreOptions): BuiltCore =
  ## Builds and post-inits the core for `rom_path` into a value of its own, so
  ## a file that is not a ROM leaves the running game as it was. A file too
  ## short to be a game (GB_MIN_ROM) is refused before a constructor runs.
  let name = rom_path.extractFilename()
  let gb = is_gb_rom(rom_path)
  var size = 0'i64
  try:
    size = getFileSize(rom_path)
  except CatchableError as e:
    return BuiltCore(error: &"Couldn't read {name}.", detail: e.msg)
  if size < (if gb: GB_MIN_ROM else: GBA_MIN_ROM):
    let what = if gb: "Game Boy" else: "Game Boy Advance"
    return BuiltCore(error: &"{name} isn't a {what} ROM: the file is too short.",
                     detail: &"{size} bytes")
  try:
    if gb:
      let g = new_gb(o.gb_bootrom, rom_path, o.gb_fifo, o.headless, o.gb_run_bios)
      # Super Game Boy is opt-in from config but header-gated in the core: a
      # cart without the SGB flag, or one that is CGB-capable, gets nothing.
      g.sgb_requested = o.sgb
      g.post_init()
      result.gb = g
    else:
      let g = new_gba(o.bios_path, rom_path, o.run_bios, o.use_hle, o.hle_after_bios)
      g.post_init()
      result.gba = g
  except CatchableError as e:
    result = BuiltCore(error: &"Couldn't load {name}.", detail: e.msg)

proc flush_batteries*(gba: GBA; gb: GB): string =
  ## Writes the loaded core's battery RAM if the game changed it. The core
  ## writes once a frame while running; this covers what no frame will: the
  ## last frame's write before the core is dropped for another game or at
  ## quit, and a state loaded while paused (restoring one marks the battery
  ## dirty). `mbc_save` / `write_save` catch a failed write (the RAM stays
  ## dirty, `save_error` says why); returns that reason, "" when the write
  ## landed or nothing was dirty.
  if gb != nil:
    gb.cartridge.mbc_save()
    if gb.cartridge.save_error.len > 0: return gb.cartridge.save_error
  if gba != nil and gba.storage != nil:
    gba.storage.write_save()
    return gba.storage.save_error
  ""

proc canonical_path(path: string): string =
  ## The file's one absolute name: relative parts and symlinks resolved.
  try: expandFilename(path)
  except OSError: absolutePath(path)

proc zip_cache_dir*(cache_root, zip_path: string): string =
  ## One folder per zip file however its path was spelled (relative from a
  ## terminal, absolute from a drop or the file dialog), so the .sav written
  ## next to the extracted ROM is found again. crc32 of the canonical path,
  ## not `hashes.hash`, whose value is the standard library's to change.
  let canon = canonical_path(zip_path)
  cache_root / &"{canon.splitFile().name}-{crc32(canon):08x}"

proc legacy_zip_cache_dir(cache_root, zip_path: string): string =
  ## Where earlier builds put it: keyed by the path as given.
  cache_root / &"{zip_path.splitFile().name}-{cast[uint32](hash(zip_path)):08x}"

proc extract_zip_rom*(cache_root, zip_path: string): string =
  ## Extract the first GBA/GB/GBC ROM in a zip into its cache folder and
  ## return its path ("" if none / unreadable). Re-opening the same zip
  ## reuses the folder, which keeps the emulator's .sav (written next to the
  ## ROM) persistent across sessions.
  try:
    let reader = openZipArchive(zip_path)
    defer: reader.close()
    var entry = ""
    for name in reader.walkFiles:
      if name.splitFile().ext.toLowerAscii() in ROM_EXTS:
        entry = name
        break
    if entry == "":
      echo "No ROM found in zip: ", zip_path
      return ""
    let dest_dir = zip_cache_dir(cache_root, zip_path)
    if not dirExists(dest_dir):
      # Earlier builds keyed the folder by `hash` of the path as given;
      # adopt one, since it holds this zip's save.
      for spelling in [absolutePath(zip_path), canonical_path(zip_path), zip_path]:
        let old = legacy_zip_cache_dir(cache_root, spelling)
        if dirExists(old):
          try:
            moveDir(old, dest_dir)
            break
          except OSError: discard
    createDir(dest_dir)
    let dest = dest_dir / entry.extractFilename()
    writeFile(dest, reader.extractFile(entry))
    dest
  except ZippyError, IOError, OSError:
    echo "Failed to read zip: ", getCurrentExceptionMsg()
    ""
