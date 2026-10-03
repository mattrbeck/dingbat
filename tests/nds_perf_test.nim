## DS speed-ups that must not change anything (docs/nds/perf.md): idle-loop
## skipping (arm/cpu.nim loop_edge, nds.nim quiet) and 3D frame reuse
## (gpu3d.nim render_frame). Each ROM runs on two machines, one with both
## on and one with both off; the whole machine state (the save-state
## payload), both screens and the sound must agree, and the fast machine
## must actually have skipped. Plus save states taken while skipping, odd
## run_until steps, and texture changes behind a reused frame.
##
## Test ROMs come from ${DINGBAT_NDS_ROMS:-~/.cache/dingbat-nds/roms}
## (tests/nds/README.md); BIOS dumps from $DINGBAT_NDS_BIOS when set (the HLE
## BIOS otherwise). A missing ROM skips its case.
##
## Run with: nimble test_ndsperf

import std/[os, strutils]
import dingbat/nds/[nds, savestate]
import dingbat/nds/gpu3d/gpu3d
import dingbat/nds/io/rtc
import dingbat/gba/rtc_calendar

var failures = 0

proc check(cond: bool; msg: string; detail = "") =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg, (if detail.len > 0: "  (" & detail & ")" else: "")
    failures.inc

let rom_dir = getEnv("DINGBAT_NDS_ROMS", getHomeDir() / ".cache/dingbat-nds/roms")
let bios_dir = getEnv("DINGBAT_NDS_BIOS")

proc file(p: string): seq[uint8] =
  if p.len == 0 or not fileExists(p): @[] else: cast[seq[uint8]](readFile(p))

proc machine(rom: string; skip: bool): NDS =
  let b = bios_dir
  result = new_nds(file(rom), file(b / "bios9.bin"), file(b / "bios7.bin"),
                   file(b / "firmware.bin"))
  result.rtc.set_fixed_clock(result.sched, to_calendar_seconds(2004, 1, 1, 0, 0, 0))
  result.arm9.wl_on = skip
  result.arm7.wl_on = skip
  result.gpu3d.reuse_on = skip
  result.gpu.engine_a.lc_on = skip
  result.gpu.engine_b.lc_on = skip

proc screens_equal(a, b: NDS): bool =
  a.gpu.top == b.gpu.top and a.gpu.bottom == b.gpu.bottom

proc first_diff(a, b: string): int =
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]: return i
  if a.len != b.len: min(a.len, b.len) else: -1

proc compare_runs(name, rom: string; frames: int; every = 10;
                  keys: seq[(int, NdsButton)] = @[]): NDS =
  ## Runs `rom` skip-on and skip-off frame by frame; returns the fast machine
  ## (nil when the ROM is missing).
  if not fileExists(rom):
    echo "  [SKIP] ", name, ": ", rom, " not found"
    return nil
  let a = machine(rom, true)
  let b = machine(rom, false)
  var same_state, same_screens, same_audio = true
  var where = ""
  for f in 0 ..< frames:
    for (at, k) in keys:
      if f == at: a.set_button(k, true); b.set_button(k, true)
      if f == at + 3: a.set_button(k, false); b.set_button(k, false)
    a.run_frame()
    b.run_frame()
    if same_screens and not screens_equal(a, b):
      same_screens = false; where.add " screens@" & $f
    if same_audio and a.spu.take_samples() != b.spu.take_samples():
      same_audio = false; where.add " audio@" & $f
    if same_state and (f mod every == every - 1 or f == frames - 1):
      let sa = a.state_payload()
      let sb = b.state_payload()
      if sa != sb:
        same_state = false
        where.add " state@" & $f & " byte " & $first_diff(sa, sb)
  check(same_state and same_screens and same_audio,
        name & ": " & $frames & " frames, skipping on == off (state, screens, sound)", where)
  a

proc pct(n: NDS; cycles: int64): string =
  formatFloat(100 * float(cycles) / float(max(n.sched.now, 1)), ffDecimal, 1) & "%"

echo "== idle-loop skipping"

block:
  # fb_both: both CPUs end in `B .`; the frames go on being drawn
  let n = compare_runs("fb_both", rom_dir / "fb_both.nds", 120)
  if n != nil:
    check(n.arm9.wl_skipped > n.sched.now div 2 and n.arm7.wl_skipped > n.sched.now div 2,
          "fb_both: most of both CPUs' time skipped",
          "arm9 " & n.pct(n.arm9.wl_skipped) & ", arm7 " & n.pct(n.arm7.wl_skipped))

block:
  # snd_tone: sound running from timers and the SPU while the CPUs spin
  let n = compare_runs("snd_tone", rom_dir / "snd_tone.nds", 120)
  if n != nil:
    check(n.arm9.wl_skipped > 0 or n.arm7.wl_skipped > 0, "snd_tone: some time skipped",
          "arm9 " & n.pct(n.arm9.wl_skipped) & ", arm7 " & n.pct(n.arm7.wl_skipped))

# libnds programs (halting and polling, IRQs, IPC, the console), the CPU
# test ROMs (loops of every shape) and the peripheral suite (timers, SPI and
# RTC busy flags polled)
for (name, path, frames) in [
    ("hello_world", "homebrew-ex/hello_world.nds", 120),
    ("pxi", "homebrew-ex/pxi.nds", 120),
    ("timercallback", "homebrew-ex/timercallback.nds", 120),
    ("armwrestler", "armwrestler.nds", 120),
    ("arm7wrestler", "arm7wrestler.nds", 120),
    ("periph_suite", "periph_suite.nds", 240),
    ("snd_suite", "snd_suite.nds", 240),
    # render registers changed mid-frame and inside V-blank: frame reuse
    # must see the per-line re-renders (docs/nds/accuracy.md)
    ("3d_render_timing", "3d/3d_render_timing.nds", 380),
    # exits through the power manager: the machine stops, screens black
    ("colecods power-off", "homebrew/colecods.nds", 30)]:
  discard compare_runs(name, rom_dir / path, frames)

block:
  # keys pressed mid-run: a loop polling KEYINPUT must see them on time
  discard compare_runs("keyboard_async + keys", rom_dir / "homebrew-ex/keyboard_async.nds", 180,
                       keys = @[(40, nbA), (70, nbDown), (100, nbStart)])

block:
  # odd run_until steps land anywhere in a skipped stretch
  let rom = rom_dir / "fb_both.nds"
  if fileExists(rom):
    let a = machine(rom, true)
    let b = machine(rom, false)
    var ok = true
    for i in 0 ..< 3000:
      let t = a.sched.now + 61 + int64(i mod 7) * 997
      a.run_until(t)
      b.run_until(t)
      if i mod 250 == 0 and a.state_payload() != b.state_payload(): ok = false
    check(ok and a.state_payload() == b.state_payload(),
          "fb_both: odd run_until steps, skipping on == off")

block:
  # a state saved while a loop is being skipped loads into a fresh machine
  # that goes on exactly as the one that saved it (nothing hidden is lost)
  let rom = rom_dir / "fb_both.nds"
  if fileExists(rom):
    let a = machine(rom, true)
    for _ in 0 ..< 30: a.run_frame()
    a.run_until(a.sched.now + 500_017)
    let st = a.state_bytes()
    let c = machine(rom, true)
    check(c.load_state_bytes(st), "fb_both: state taken mid-skip loads")
    for _ in 0 ..< 30:
      a.run_frame()
      c.run_frame()
    check(a.state_payload() == c.state_payload() and screens_equal(a, c),
          "fb_both: the loaded machine runs on identically")

echo "== 3D frame reuse"

block:
  let n = compare_runs("Textured_Cube", rom_dir / "homebrew-ex/Textured_Cube.nds", 90)
  if n != nil:
    check(n.gpu3d.reused > 30, "Textured_Cube: unchanged frames reused",
          $n.gpu3d.reused & " reused")

for (name, path, frames) in [
    ("Simple_Tri", "homebrew-ex/Simple_Tri.nds", 60),
    ("3d_texfmt", "3d/3d_texfmt.nds", 60),
    ("3d_rearbitmap", "3d/3d_rearbitmap.nds", 60),
    ("3d_fog", "3d/3d_fog.nds", 60),
    ("disp_capture", "3d/disp_capture.nds", 60),
    ("3d_timing_rdlines", "3d/3d_timing_rdlines.nds", 60)]:
  discard compare_runs(name, rom_dir / path, frames)

block:
  # a texture changed behind a reused frame: banks A-D taken to LCDC,
  # rewritten, given back to the texture slots (as games load textures);
  # the next frame must be drawn again, as with reuse off
  let rom = rom_dir / "homebrew-ex/Textured_Cube.nds"
  if fileExists(rom):
    let a = machine(rom, true)
    let b = machine(rom, false)
    for _ in 0 ..< 40:
      a.run_frame(); b.run_frame()
    let reused_before = a.gpu3d.reused
    for n in [a, b]:
      let bus = Arm9Bus(nds: n)
      let saved = read32(bus, 0x0400_0240'u32)
      write32(bus, 0x0400_0240'u32, 0x8080_8080'u32)      # A-D: LCDC
      for i in 0'u32 ..< 0x8000: write32(bus, 0x0680_0000'u32 + i * 4, i * 0x0001_0001'u32)
      write32(bus, 0x0400_0240'u32, saved)
    a.run_frame(); b.run_frame()
    check(a.gpu3d.reused == reused_before, "Textured_Cube: a remap forces a fresh render")
    for _ in 0 ..< 5:
      a.run_frame(); b.run_frame()
    check(a.state_payload() == b.state_payload() and screens_equal(a, b),
          "Textured_Cube: rewritten textures, reuse on == off")
    # and a loaded state never reuses the frame the machine had before
    let st = a.state_bytes()
    let c = machine(rom, true)
    for _ in 0 ..< 3: c.run_frame()
    check(c.load_state_bytes(st), "Textured_Cube: state loads over a running machine")
    for _ in 0 ..< 10:
      a.run_frame(); c.run_frame()
    check(a.state_payload() == c.state_payload() and screens_equal(a, c),
          "Textured_Cube: the loaded machine draws what the saving one does")

echo "== 2D line reuse"

block:
  let n = compare_runs("scrolling (lines)", rom_dir / "homebrew-ex/scrolling.nds", 60)
  if n != nil:
    check(n.gpu.engine_a.lc_reused + n.gpu.engine_b.lc_reused > 80 * 192,
          "scrolling: unchanged lines reused",
          $n.gpu.engine_a.lc_reused & " + " & $n.gpu.engine_b.lc_reused & " reused")

# scrolling, affine and rotscale BGs, sprites (affine, extended palettes),
# windows (mid-frame and H-blank driven), bitmaps, 3D under 2D, capture
for (name, path, frames) in [
    ("2d_text", "2d_text.nds", 60),
    ("2d_bitmap", "2d_bitmap.nds", 60),
    ("2d_sprites", "2d_sprites.nds", 60),
    ("window-basic", "window/window-basic.nds", 60),
    ("window-hblank", "window/window-hblank.nds", 60),
    ("window-midframe", "window/window-midframe.nds", 60),
    ("scrolling", "homebrew-ex/scrolling.nds", 120),
    ("rotation", "homebrew-ex/rotation.nds", 120),
    ("rotscale_text", "homebrew-ex/rotscale_text.nds", 120),
    ("sprite_rotate", "homebrew-ex/sprite_rotate.nds", 120),
    ("sprite_extended_palettes", "homebrew-ex/sprite_extended_palettes.nds", 60),
    ("animate_simple", "homebrew-ex/animate_simple.nds", 120),
    ("16bit_color_bmp", "homebrew-ex/16bit_color_bmp.nds", 60),
    ("2Dplus3D", "homebrew-ex/2Dplus3D.nds", 120),
    ("Mixed_Text_3D", "homebrew-ex/Mixed_Text_3D.nds", 120)]:
  discard compare_runs(name, rom_dir / path, frames)

block:
  # memory changed behind reused lines, through the bus as a program (or
  # DMA) would: a palette entry of each engine, an OAM entry, a BG map entry
  # in VRAM, a remap; the next frame must equal the one drawn without reuse
  let rom = rom_dir / "homebrew-ex/scrolling.nds"
  if fileExists(rom):
    let a = machine(rom, true)
    let b = machine(rom, false)
    for _ in 0 ..< 30:
      a.run_frame(); b.run_frame()
    var same = true
    var where = ""
    proc poke(what: string; f: proc (bus: Arm9Bus)) =
      for n in [a, b]: f(Arm9Bus(nds: n))
      for _ in 0 ..< 2:
        a.run_frame(); b.run_frame()
        if not screens_equal(a, b) and same:
          same = false; where = what
    poke("A palette", proc (bus: Arm9Bus) = write16(bus, 0x0500_0002'u32, 0x001F))
    poke("B palette", proc (bus: Arm9Bus) = write16(bus, 0x0500_0402'u32, 0x7C00))
    poke("B backdrop", proc (bus: Arm9Bus) = write16(bus, 0x0500_0400'u32, 0x03E0))
    poke("B OBJ setup", proc (bus: Arm9Bus) =   # bank I as B's OBJ VRAM, solid tiles, OBJs on
      write8(bus, 0x0400_0249'u32, 0x82)
      for i in 0'u32 ..< 0x1000: write16(bus, 0x0660_0000'u32 + i * 2, 0x1111)
      write16(bus, 0x0500_0602'u32, 0x03FF)
      write16(bus, 0x0400_1000'u32, uint16(read16(bus, 0x0400_1000'u32) or 0x1000))
      write32(bus, 0x0700_0400'u32, 0x4000_0010'u32)                    # 16x16 at (0, 16)
      write16(bus, 0x0700_0404'u32, 0x0001))
    # OAM alone changes from here on: the lines the OBJ leaves and enters
    poke("OBJ moved", proc (bus: Arm9Bus) = write16(bus, 0x0700_0400'u32, 0x0060))
    poke("OBJ grown", proc (bus: Arm9Bus) = write16(bus, 0x0700_0402'u32, 0x8000))
    poke("OBJ affine, double size", proc (bus: Arm9Bus) = write16(bus, 0x0700_0400'u32, 0x0330))
    poke("affine parameter", proc (bus: Arm9Bus) = write16(bus, 0x0700_0406'u32, 0x7FFF))
    poke("OBJ wraps past line 255", proc (bus: Arm9Bus) = write16(bus, 0x0700_0400'u32, 0x03F0))
    poke("OBJ hidden", proc (bus: Arm9Bus) = write16(bus, 0x0700_0400'u32, 0x0200))
    poke("BG VRAM", proc (bus: Arm9Bus) =
      for i in 0'u32 ..< 0x800: write16(bus, 0x0600_0000'u32 + i * 2, uint16(i * 7))
      for i in 0'u32 ..< 0x800: write16(bus, 0x0620_0000'u32 + i * 2, uint16(i * 5)))
    poke("remap", proc (bus: Arm9Bus) =
      let saved = read32(bus, 0x0400_0240'u32)
      write32(bus, 0x0400_0240'u32, 0x8080_8080'u32)
      write32(bus, 0x0400_0240'u32, saved))
    for _ in 0 ..< 3:
      a.run_frame(); b.run_frame()
    check(same and a.state_payload() == b.state_payload() and screens_equal(a, b),
          "scrolling: palette, OAM and VRAM changed behind reused lines, reuse on == off",
          "screens differ after the " & where & " change")
    # a loaded state never reuses the lines the machine had before
    let st = a.state_bytes()
    let c = machine(rom, true)
    for _ in 0 ..< 3: c.run_frame()
    check(c.load_state_bytes(st), "scrolling: state loads over a running machine")
    for _ in 0 ..< 5:
      a.run_frame(); c.run_frame()
    check(a.state_payload() == c.state_payload() and screens_equal(a, c),
          "scrolling: the loaded machine draws what the saving one does")

echo ""
if failures == 0:
  echo "All DS perf checks passed"
else:
  echo failures, " DS perf check(s) FAILED"
  quit(1)
