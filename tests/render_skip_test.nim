## The GBA whole-frame render skip against a twin that renders every line.
## The skip (ppu.nim `scanline`) reuses the last framebuffer while no write
## since the frame began changed anything the PPU draws from; a write that
## stores what was already there (a game's shadow registers, palette or
## OAM copied in every V-blank) does not count. Every case here runs two
## machines through the same frames, one with `render_dirty` forced on so
## it never skips, and requires identical framebuffers after every frame:
##   1. the GBA ROMs under tests/roms, plus any listed in
##      DINGBAT_RENDER_SKIP_ROMS (files or directories, ':'-separated);
##   2. a synthetic scene with pokes through the real bus paths: same-value
##      stores to every PPU register, PRAM, VRAM (halfword and byte) and OAM
##      must leave the frame skipped; changed ones must redraw it; and a
##      same-value BG2Y store mid-frame, which still resets the internal
##      reference point that advanced since V-blank, must redraw the lines
##      below it.
## And the frontend's skip (`ppu.no_draw`, a frame it will not show): a
## third machine on each ROM draws only some frames; it must run exactly as
## the others (the same state after every frame) and, on a frame it draws,
## show the same picture. Its rewind snapshots wait for a drawn frame, and
## each must hold its own frame's picture at the age frames_back gives.
## Run with: nimble test_renderskip

import std/[os, strutils]
import dingbat/gba/gba
import dingbat/common/rewind

var failures = 0

proc check(cond: bool; name: string; detail = "") =
  if cond:
    echo "  [PASS] ", name
  else:
    echo "  [FAIL] ", name, (if detail.len > 0: "  " & detail else: "")
    inc failures

proc first_diff(a, b: GBA): int =
  ## The first framebuffer index where the two differ, or -1.
  for i in 0 ..< a.ppu.framebuffer.len:
    if a.ppu.framebuffer[i] != b.ppu.framebuffer[i]: return i
  -1

proc frame(g: GBA; force: bool; line = -1; poke: proc(g: GBA) = nil) =
  ## step_frame's loop, with `poke` run at the first boundary on `line`.
  ## `force` makes this the twin that never skips.
  if force: g.ppu.render_dirty = true
  g.frame_start_cycles = g.scheduler.cycles
  var poked = poke == nil
  while g.ppu.frame == 0:
    if not poked and int(g.ppu.vcount) == line:
      poke(g)
      poked = true
    g.cpu.tick()
  g.end_frame()

proc fb_hash(g: GBA): uint64 =
  result = 0xCBF29CE484222325'u64
  for v in g.ppu.framebuffer: result = (result xor uint64(v)) * 0x100000001B3'u64

proc runs_as(c, b: GBA): bool =
  ## c's state is b's but for what only drawing writes: the picture, and
  ## the mosaic's latched affine point (latched again on line 0 of every
  ## drawn frame before anything reads it).
  let fb = c.ppu.framebuffer
  let mosaic = c.ppu.mosaic_bgref_int
  c.ppu.framebuffer = b.ppu.framebuffer
  c.ppu.mosaic_bgref_int = b.ppu.mosaic_bgref_int
  result = c.state_payload() == b.state_payload()
  c.ppu.framebuffer = fb
  c.ppu.mosaic_bgref_int = mosaic

# ---- 1. ROMs ----------------------------------------------------------------

proc run_rom(src: string; frames: int) =
  # Each machine on its own copy: a save chip writes its .sav beside the ROM
  var g: array[3, GBA]
  for i in 0 .. 2:
    let dir = getTempDir() / "dingbat_render_skip" / $i
    createDir(dir)
    let path = dir / src.extractFilename
    copyFile(src, path)
    removeFile(path.changeFileExt(".sav"))
    g[i] = new_gba("", path, run_bios = false, use_hle = true)
    g[i].post_init()
  let (a, b, c) = (g[0], g[1], g[2])
  let path = src
  var static_frames = 0
  var bad = -1
  var ran_off = -1
  var drew_off = -1
  var drawn = 0
  let rw = new_rewind()
  var pictures: seq[uint64] = @[]   # b's picture after each frame
  var newest = -1                   # the frame of c's newest snapshot
  for f in 0 ..< frames:
    a.frame(force = false)
    b.frame(force = true)
    pictures.add b.fb_hash()
    # c: runs of up to six undrawn frames, as fast-forward makes
    c.ppu.no_draw = not (f mod 4 == 3 or f mod 7 == 0)
    c.frame(force = false)
    if rw.maybe_push(proc(): string = c.state_payload(), ready = not c.ppu.no_draw):
      newest = f
    if a.ppu.frame_static: inc static_frames
    if bad < 0 and first_diff(a, b) >= 0: bad = f
    if ran_off < 0 and not c.runs_as(b): ran_off = f
    if not c.ppu.no_draw:
      inc drawn
      if drew_off < 0 and first_diff(c, b) >= 0: drew_off = f
  check(bad < 0, path.extractFilename & " (" & $static_frames & "/" & $frames &
        " frames skipped)", if bad >= 0: "first differs at frame " & $bad else: "")
  check(ran_off < 0, path.extractFilename & ": undrawn frames run the same",
        if ran_off >= 0: "state first differs after frame " & $ran_off else: "")
  check(drew_off < 0, path.extractFilename & ": drawn frames (" & $drawn & "/" &
        $frames & ") show the same picture",
        if drew_off >= 0: "first differs at frame " & $drew_off else: "")
  # Every snapshot, applied, shows its own frame's picture (c is done with)
  var snap_off = -1
  for i in 0 ..< rw.len:
    let f = newest - rw.frames_back(i)
    c.apply_state_payload(rw.snapshot_at(i))
    if snap_off < 0 and (f < 0 or c.fb_hash() != pictures[f]): snap_off = f
  check(snap_off < 0 and rw.len > frames div 12, path.extractFilename & ": " & $rw.len &
        " rewind snapshots, each with its frame's picture",
        if snap_off >= 0: "first wrong at frame " & $snap_off else: "")

# ---- 2. Synthetic scene -------------------------------------------------------

const IO = 0x04000000'u32

proc make_rom(): string =
  # ARM `b .` at the entry point: the CPU spins and the PPU draws only what
  # the test puts in memory
  result = getTempDir() / "dingbat_render_skip_synthetic.gba"
  var rom = newString(0x8000)
  rom[0] = '\xFE'; rom[1] = '\xFF'; rom[2] = '\xFF'; rom[3] = '\xEA'
  writeFile(result, rom)

proc setup(g: GBA) =
  let bus = g.bus
  # Mode 1: BG0 text (4bpp, char 0, screen 31), BG2 affine (8bpp, char 1,
  # screen 16, 256x256), sprites on, 1D OBJ mapping
  bus.write_half_internal(IO + 0x00, 0x1541)
  bus.write_half_internal(IO + 0x08, 0x1F00)
  bus.write_half_internal(IO + 0x0C, 0x5084)
  bus.write_half_internal(IO + 0x20, 0x0100)  # BG2PA
  bus.write_half_internal(IO + 0x26, 0x0100)  # BG2PD
  for i in 1'u32 .. 255:
    bus.write_half_internal(0x05000000'u32 + 2 * i, uint16((i * 37) and 0x7FFF))
    bus.write_half_internal(0x05000200'u32 + 2 * i, uint16((i * 91) and 0x7FFF))
  # BG0 tile 1, every map entry on it
  for i in 0'u32 ..< 16:
    bus.write_word_internal(0x06000020'u32 + 4 * i, 0x12345678'u32 + i * 0x01010101'u32)
  for i in 0'u32 ..< 1024:
    bus.write_half_internal(0x0600F800'u32 + 2 * i, 1)
  # BG2: tiles 0-255 at char 1 (0x4000 on) are row-numbered, the 32x32 map
  # at screen 16 (0x8000) names tile = row, so each line of the picture
  # shows which BG row it came from
  for t in 0'u32 ..< 32:
    for p in 0'u32 ..< 16:
      bus.write_word_internal(0x06004000'u32 + 64 * t + 4 * p,
                              (t * 8 + p div 2 + 1) * 0x01010101'u32)
  for r in 0'u32 ..< 32:
    for c in 0'u32 ..< 16:
      bus.write_half_internal(0x06008000'u32 + 32 * r + 2 * c, uint16(r or (r shl 8)))
  # One 16x16 sprite at (60, 40), tile 2 of OBJ VRAM
  for i in 0'u32 ..< 32:
    bus.write_word_internal(0x06010040'u32 + 4 * i, 0x11223344'u32 + i)
  bus.write_half_internal(0x07000000, 40)
  bus.write_half_internal(0x07000002, 0x4000 or 60)
  bus.write_half_internal(0x07000004, 2)
  for i in 1'u32 ..< 128:   # the rest hidden
    bus.write_half_internal(0x07000000'u32 + 8 * i, 0x0200)

proc pair(): (GBA, GBA) =
  let rom = make_rom()
  let a = new_gba("", rom, run_bios = false, use_hle = true)
  a.post_init()
  let b = new_gba("", rom, run_bios = false, use_hle = true)
  b.post_init()
  a.setup(); b.setup()
  for i in 0 ..< 4:          # settle, so the next clean frame skips
    a.frame(false); b.frame(true)
  (a, b)

proc same_frames(a, b: GBA; n: int; line: int; poke: proc(g: GBA);
                 name: string; expect_static: bool) =
  ## n frames with `poke` on `line` in each; frames must match, and the
  ## skipping machine must skip (or redraw) every one of them.
  var bad = -1
  var statics = 0
  for f in 0 ..< n:
    a.frame(false, line, poke)
    b.frame(true, line, poke)
    if a.ppu.frame_static: inc statics
    if bad < 0 and first_diff(a, b) >= 0: bad = f
  check(bad < 0, name & ": frames match", if bad >= 0: "frame " & $bad else: "")
  if expect_static:
    check(statics == n, name & ": every frame skipped", $statics & "/" & $n)
  else:
    check(statics == 0, name & ": every frame redrawn", $statics & "/" & $n)

proc synthetic() =
  echo "synthetic scene"
  var (a, b) = pair()
  same_frames(a, b, 3, -1, nil, "no writes", expect_static = true)

  # Same-value stores to every PPU register but the affine reference points
  # (below) and DISPSTAT, with the values setup and the boot left there
  let same_regs = proc(g: GBA) =
    let bus = g.bus
    bus.write_half_internal(IO + 0x00, 0x1541)
    bus.write_half_internal(IO + 0x08, 0x1F00)
    bus.write_half_internal(IO + 0x0C, 0x5084)
    for r in [0x10'u32, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x1C, 0x1E, 0x22, 0x24,
              0x32, 0x34, 0x40, 0x42, 0x44, 0x46, 0x48, 0x4A, 0x4C, 0x50,
              0x52, 0x54]:
      bus.write_half_internal(IO + r, 0)
    # PA and PD of both affine BGs are 0x100 (the BIOS leaves BG3's so)
    for r in [0x20'u32, 0x26, 0x30, 0x36]:
      bus.write_half_internal(IO + r, 0x0100)
  same_frames(a, b, 3, 0, same_regs, "same-value registers at V-blank's end",
              expect_static = true)
  same_frames(a, b, 3, 200, same_regs, "same-value registers in V-blank",
              expect_static = true)
  let same_mem = proc(g: GBA) =
    let bus = g.bus
    bus.write_half_internal(0x0600F800, 2)   # BG0 map entry 0 changed...
    bus.write_half_internal(0x0600F800, 1)   # ...and put back
  same_frames(a, b, 3, 100, same_mem, "VRAM changed and restored mid-frame",
              expect_static = false)
  let same_mem2 = proc(g: GBA) =
    let bus = g.bus
    bus.write_half_internal(0x05000002, uint16(37))
    bus.write_word_internal(0x05000200, (91'u32 shl 16))
    bus.write_half_internal(0x0600F800, 1)
    bus.write_word_internal(0x06008020, 0x01010101'u32)   # BG2 map row 1
    bus.write_byte_internal(0x06004000, 1)   # 0x0101: what is there
    bus.write_word_internal(0x07000000, 40'u32 or ((0x4000'u32 or 60) shl 16))
    bus.write_half_internal(0x07000004, 2)
  # one redrawn frame for the changed-and-restored ones above, then static
  a.frame(false); b.frame(true)
  same_frames(a, b, 3, 100, same_mem2, "same-value PRAM/VRAM/OAM mid-frame",
              expect_static = true)

  # Changed values redraw
  var k = 0'u16
  let pal = proc(g: GBA) = g.bus.write_half_internal(0x05000002, 0x7C00'u16 xor k)
  for i in 0 ..< 3:
    k = uint16(i + 1)
    same_frames(a, b, 1, 120, pal, "palette change mid-frame #" & $i, expect_static = false)
  # A raster effect (a palette change at line 120 every frame) across
  # undrawn frames: each drawn frame shows it as a machine that draws all
  var raster_bad = -1
  for f in 0 ..< 12:
    k = uint16(f + 20)
    a.ppu.no_draw = f mod 3 != 2
    a.frame(false, 120, pal)
    b.frame(true, 120, pal)
    if not a.ppu.no_draw and raster_bad < 0 and first_diff(a, b) >= 0: raster_bad = f
  a.ppu.no_draw = false
  check(raster_bad < 0, "undrawn frames around a mid-frame palette change: drawn frames match",
        if raster_bad >= 0: "frame " & $raster_bad else: "")
  # ...and once it stops, an undrawn changed frame then static ones
  a.ppu.no_draw = true
  a.frame(false); b.frame(true)
  a.ppu.no_draw = false
  same_frames(a, b, 1, -1, nil, "after an undrawn changed frame, the next is drawn whole",
              expect_static = false)
  same_frames(a, b, 1, -1, nil, "and the one after skips as static again",
              expect_static = true)
  var x = 60'u16
  let obj = proc(g: GBA) = g.bus.write_half_internal(0x07000002, 0x4000'u16 or x)
  for i in 0 ..< 3:
    x = uint16(61 + i)
    same_frames(a, b, 1, 30, obj, "sprite moved mid-frame #" & $i, expect_static = false)
  let hofs = proc(g: GBA) = g.bus.write_half_internal(IO + 0x10, uint16(k))
  for i in 0 ..< 3:
    k = uint16(i + 5)
    same_frames(a, b, 1, 70, hofs, "BG0HOFS change mid-frame #" & $i, expect_static = false)
  let vram = proc(g: GBA) = g.bus.write_byte_internal(0x06000020, uint8(k))
  for i in 0 ..< 3:
    k = uint16(i + 9)
    same_frames(a, b, 1, 50, vram, "VRAM byte change mid-frame #" & $i, expect_static = false)

  # The affine reference: BG2Y written with the value it already holds,
  # 80 lines into the frame, moves the internal point back to it
  (a, b) = pair()
  for g in [a, b]: g.bus.write_half_internal(IO + 0x00, 0x1441)  # BG2 + OBJ only
  for i in 0 ..< 2: a.frame(false); b.frame(true)
  same_frames(a, b, 2, -1, nil, "affine scene settles", expect_static = true)
  let refy = proc(g: GBA) =
    g.bus.write_half_internal(IO + 0x2C, 0)
    g.bus.write_half_internal(IO + 0x2E, 0)
  same_frames(a, b, 3, 80, refy, "same-value BG2Y mid-frame", expect_static = false)
  # The same store in V-blank finds the point already reloaded: no change
  a.frame(false); b.frame(true)
  same_frames(a, b, 3, 200, refy, "same-value BG2Y in V-blank", expect_static = true)

when isMainModule:
  echo "ROMs"
  var roms: seq[string]
  for f in walkFiles(currentSourcePath.parentDir / "roms" / "*.gba"): roms.add f
  for item in getEnv("DINGBAT_RENDER_SKIP_ROMS").split(':'):
    if item.len == 0: continue
    if dirExists(item):
      for f in walkFiles(item / "*.gba"): roms.add f
    else:
      roms.add item
  let frames = parseInt(getEnv("DINGBAT_RENDER_SKIP_FRAMES", "300"))
  for r in roms: run_rom(r, frames)
  synthetic()
  if failures == 0:
    echo "render_skip: all passed"
    quit(0)
  else:
    echo "render_skip: ", failures, " FAILED"
    quit(1)
