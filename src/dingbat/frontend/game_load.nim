## The parts of the desktop's `load_rom` that need no window: building the
## next core without touching the running one, writing battery RAM out before
## a core is dropped, and where a zip's ROM is extracted to. No SDL, ImGui or
## GL here, so tests/desktop_lifecycle_test.nim builds headless.

import std/[os, hashes, strformat, strutils]
import ../common/inflate_bound
import ../common/[linkproto, rom_exts]
import ../gba/gba
import ../gb/gb

export rom_exts

# The Open ROM dialog's filter: what `is_rom_file` takes, without the dots.
const ROM_DIALOG_EXTS* = block:
  var exts: seq[string]
  for ext in ROM_EXTS: exts.add ext[1 .. ^1]
  exts.add "zip"
  exts

# With DS Beta on: DS games too (`.nds`, alone or inside a zip).
const
  NDS_ROM_EXT* = ".nds"
  ROM_EXTS_DS* = @ROM_EXTS & @[NDS_ROM_EXT]
  ROM_DIALOG_EXTS_DS* = @ROM_DIALOG_EXTS & @[NDS_ROM_EXT[1 .. ^1]]

# The smallest file taken as a ROM. Both cores run any length (GB pads with
# $FF, GBA reads open bus past the file), so this only rejects a GB file
# that cannot hold the header ($0100-$014F), or an empty file. GBA test ROMs
# as short as 56 bytes exist.
const
  GB_MIN_ROM  = 0x150
  GBA_MIN_ROM = 1

type
  CoreOptions* = object
    ## What `build_core` hands the constructors, from the config.
    gb_bootrom*:     string
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
  rom_path.splitFile().ext.toLowerAscii() in GB_ROM_EXTS

proc is_rom_file*(path: string): bool =
  ## A file dingbat opens by its name: a ROM of either core, or a zip.
  let ext = path.splitFile().ext.toLowerAscii()
  ext in ROM_EXTS or ext == ".zip"


proc build_core*(rom_path: string; o: CoreOptions): BuiltCore =
  ## Builds and post-inits the core for `rom_path` apart from the running
  ## game, which a bad file leaves as it was. A file under GB_MIN_ROM /
  ## GBA_MIN_ROM fails before a constructor runs.
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
      let g = new_gb(o.gb_bootrom, rom_path, o.headless, o.gb_run_bios)
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
  ## Writes the core's battery RAM if dirty. The core writes once a frame
  ## while running; this covers what no frame will: before the core is
  ## dropped (game switch, quit) and after a state loaded while paused
  ## (which marks the battery dirty). A failed write leaves the RAM dirty;
  ## returns `save_error`, "" when it landed or nothing was dirty.
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
  ## One folder per zip however its path is written (relative, absolute),
  ## so the .sav beside the extracted ROM is found again. crc32 of the
  ## canonical path, not `hashes.hash`, which the stdlib may change.
  let canon = canonical_path(zip_path)
  cache_root / &"{canon.splitFile().name}-{crc32(canon):08x}"

proc legacy_zip_cache_dir(cache_root, zip_path: string): string =
  ## Where earlier builds put it: keyed by the path as given.
  cache_root / &"{zip_path.splitFile().name}-{cast[uint32](hash(zip_path)):08x}"

const ZIP_ENTRY_MAX* = 512 * 1024 * 1024
  ## The most a zip's ROM may unpack to: the largest DS cartridge. Deflate
  ## can turn a megabyte into a gigabyte, and the size a zip gives for an
  ## entry is the zip's word for it.

type ZipError = object of CatchableError

proc zip_first_rom*(zip: string; exts: openArray[string]): tuple[name, data: string] =
  ## The first entry of `zip` (a zip file's bytes) named with one of `exts`,
  ## unpacked: at most ZIP_ENTRY_MAX, and the size its directory entry gives.
  ## ("", "") when there is none. Stored and deflated entries; zip64 sizes
  ## and offsets are read (zippy writes every archive that way).
  proc u16(p: int): int =
    if p < 0 or p + 2 > zip.len: raise newException(ZipError, "the zip is cut short")
    int(uint8(zip[p])) or (int(uint8(zip[p + 1])) shl 8)
  proc u32(p: int): int = u16(p) or (u16(p + 2) shl 16)
  proc u64(p: int): int =
    # Nothing here is past 2^31; a larger value is damage.
    if u32(p + 4) != 0 or u32(p) < 0: raise newException(ZipError, "the zip is too large to read")
    u32(p)
  var eocd = -1
  for i in countdown(zip.len - 22, max(0, zip.len - 65557)):
    if u32(i) == 0x06054b50:
      eocd = i
      break
  if eocd < 0: raise newException(ZipError, "not a zip file")
  var p = u32(eocd + 16)
  var count = u16(eocd + 10)
  if eocd >= 20 and u32(eocd - 20) == 0x07064b50:
    # A zip64 end record, found through its locator.
    let z = u64(eocd - 20 + 8)
    if u32(z) != 0x06064b50: raise newException(ZipError, "the zip's directory is damaged")
    count = u64(z + 32)
    p = u64(z + 48)
  for _ in 0 ..< count:
    if u32(p) != 0x02014b50: break
    let name_len = u16(p + 28)
    if p + 46 + name_len > zip.len: raise newException(ZipError, "the zip is cut short")
    let name = zip[p + 46 ..< p + 46 + name_len]
    if not name.endsWith("/") and name.splitFile().ext.toLowerAscii() in exts:
      var (method_id, comp, size, lo) = (u16(p + 10), u32(p + 20), u32(p + 24), u32(p + 42))
      # Fields left at all ones are in the zip64 extra, in this order.
      var x = p + 46 + name_len
      let x_end = x + u16(p + 30)
      while x + 4 <= x_end:
        let (id, n) = (u16(x), u16(x + 2))
        if id == 1:
          var q = x + 4
          if size == 0xFFFFFFFF: (size = u64(q); q += 8)
          if comp == 0xFFFFFFFF: (comp = u64(q); q += 8)
          if lo == 0xFFFFFFFF: lo = u64(q)
          break
        x += 4 + n
      if size > ZIP_ENTRY_MAX: raise newException(ZipError, "the game in the zip is too large")
      if u32(lo) != 0x04034b50: raise newException(ZipError, "the zip's entry is damaged")
      let start = lo + 30 + u16(lo + 26) + u16(lo + 28)
      if comp < 0 or start + comp > zip.len: raise newException(ZipError, "the zip is cut short")
      var data: string
      case method_id
      of 0: data = zip[start ..< start + comp]
      of 8:
        if comp == 0: raise newException(ZipError, "the zip's entry is empty")
        # To the size the entry gives and no further: a longer one stops there.
        data = deflate_inflate_capped(unsafeAddr zip[start], comp, size, hint = size)
      else: raise newException(ZipError, "the zip uses a compression this cannot read")
      if data.len != size: raise newException(ZipError, "the game in the zip is not the size the zip gives")
      if crc32(data) != uint32(u32(p + 16)): raise newException(ZipError, "the game in the zip is damaged")
      return (name, data)
    p += 46 + name_len + u16(p + 30) + u16(p + 32)
  ("", "")

proc extract_zip_rom*(cache_root, zip_path: string;
                      exts: openArray[string] = ROM_EXTS): string =
  ## Extract the zip's first ROM (`exts`: `ROM_EXTS`, or `ROM_EXTS_DS` with
  ## DS Beta on) into its cache folder; returns its path ("" if none or
  ## unreadable). The folder is reused, so the .sav beside the ROM persists.
  try:
    let (entry, rom) = zip_first_rom(readFile(zip_path), exts)
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
    writeFile(dest, rom)
    dest
  except ZipError, InflateError, IOError, OSError:
    echo "Failed to read zip: ", getCurrentExceptionMsg()
    ""
