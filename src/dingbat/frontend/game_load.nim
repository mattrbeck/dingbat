## The parts of the desktop's `load_rom` that need no window: building the
## next core without touching the running one. No SDL, ImGui or GL here, so
## tests/desktop_lifecycle_test.nim builds headless.

import std/[os, strformat, strutils]
import ../gba/gba
import ../gb/gb

# The smallest file each core can run. Every Game Boy cartridge is at least
# 32 KiB and the core reads the whole 0x0000-0x7FFF window unchecked (a
# shorter file is an IndexDefect as soon as the CPU runs past its end); a GBA
# cartridge header ends at 0xBF.
const
  GB_MIN_ROM  = 0x8000
  GBA_MIN_ROM = 0xC0

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
  ## short for its core is refused before a constructor indexes past its end.
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
