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
  result.long_on = skip

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

echo "== long slices"

# nds.nim run_long / slice_cut: one CPU halted with no interrupt to wake
# it, the other runs straight to the next event, stopping on the SLICE grid
# when it wakes the halted one, books or moves an event, or puts the
# machine to sleep. Small programs on both CPUs do each of those after a
# loop of 1..40 passes (so the access falls at every point of a step) and
# run with long slices on and off: the whole state must agree.

proc tiny_rom(): seq[uint8] =
  ## A header plus two "b ." loops: ARM9 at 0x02000000, ARM7 at 0x037F8000.
  result = newSeq[uint8](0x400)
  proc w32(r: var seq[uint8]; o: int; v: uint32) =
    for i in 0..3: r[o + i] = uint8(v shr (8 * i))
  result.w32(0x20, 0x200); result.w32(0x24, 0x0200_0000); result.w32(0x28, 0x0200_0000)
  result.w32(0x2C, 4)
  result.w32(0x30, 0x300); result.w32(0x34, 0x037F_8000); result.w32(0x38, 0x037F_8000)
  result.w32(0x3C, 4)
  result.w32(0x200, 0xEAFF_FFFE'u32)
  result.w32(0x300, 0xEAFF_FFFE'u32)

const
  LOOP = [0xE251_1001'u32, 0x1AFF_FFFD'u32]     # SUBS r1, r1, #1; BNE back
  IO = 0xE3A0_0301'u32                          # MOV r0, #0x04000000
  ACK_HANDLER = [IO, 0xE280_0C02'u32, 0xE280_0014'u32,   # r0 = IF
                 0xE3A0_1801'u32, 0xE580_1000'u32,       # IF = bit 16 (IPC sync)
                 0xE3A0_1008'u32, 0xE580_1000'u32,       # IF = bit 3 (timer 0)
                 0xE285_5001'u32, 0xE12F_FF1E'u32]       # r5 += 1; BX LR

proc long_case(name: string; runner9: bool; body: openArray[uint32];
               setup: proc (n: NDS) {.nimcall.}) =
  ## The running CPU (ARM9 or ARM7) runs MOV r1, #passes; LOOP; `body`;
  ## then MOV r1, #200; LOOP; B . -- the other is halted.
  var same = true
  var where = ""
  for passes in 1'u32 .. 40:
    var ms: array[2, NDS]
    for k in 0..1:
      let n = new_nds(tiny_rom(), @[], @[], @[])
      n.rtc.set_fixed_clock(n.sched, to_calendar_seconds(2004, 1, 1, 0, 0, 0))
      n.arm9.wl_on = k == 0; n.arm7.wl_on = k == 0; n.long_on = k == 0
      let code = if runner9: 0x0210_0000'u32 else: 0x0380_1000'u32
      var prog = @[0xE3A0_1000'u32 or passes] & @LOOP & @body &
                 @[0xE3A0_10C8'u32] & @LOOP & @[0xEAFF_FFFE'u32]
      let b7 = Arm7Bus(nds: n)
      for i, w in prog: b7.write32(code + uint32(4 * i), w)
      for i, w in ACK_HANDLER:
        b7.write32(0x0210_1000'u32 + uint32(4 * i), w)    # ARM9's handler
        b7.write32(0x0380_2000'u32 + uint32(4 * i), w)    # ARM7's
      Arm9Bus(nds: n).write32(0x0080_3FFC'u32, 0x0210_1000'u32)   # DTCM + 3FFCh
      b7.write32(0x0380_FFFC'u32, 0x0380_2000'u32)
      for c in [n.irq9, n.irq7]: c.ime = 1; c.ie = 0; c.iff = 0
      if runner9:
        n.arm9.set_cpsr(0x1F); n.arm9.next_pc = code
        n.arm7.set_cpsr(0x1F); n.arm7.halted = true
      else:
        n.arm7.set_cpsr(0x1F); n.arm7.next_pc = code
        n.arm9.set_cpsr(0x1F); n.arm9.halted = true
      setup(n)
      for _ in 0 ..< 3: n.run_until(n.sched.now + 7000)
      ms[k] = n
    if ms[0].state_payload() != ms[1].state_payload():
      same = false
      where.add " " & $passes
  check(same, name & ": long slices give the step loop's state", "differs after" & where)

# IPCSYNC bit 13 to the other CPU, whose IPCSYNC bit 14 and IE bit 16 are on
const SYNC_IRQ = [IO, 0xE280_0E18'u32, 0xE3A0_2A02'u32, 0xE580_2000'u32]
long_case("ARM9 wakes the halted ARM7", true, SYNC_IRQ, proc (n: NDS) =
  Arm7Bus(nds: n).write16(0x0400_0180'u32, 0x4000); n.irq7.ie = 1'u32 shl 16)
long_case("ARM7 wakes the halted ARM9", false, SYNC_IRQ, proc (n: NDS) =
  Arm9Bus(nds: n).write16(0x0400_0180'u32, 0x4000); n.irq9.ie = 1'u32 shl 16)
# timer 0, reload FFF0h, enabled with its IRQ: an event booked mid-run
const TIMER = [IO, 0xE280_0C01'u32, 0xE3A0_18C0'u32, 0xE381_1CFF'u32,
               0xE381_10F0'u32, 0xE580_1000'u32]
long_case("ARM9 books a timer event", true, TIMER, proc (n: NDS) = n.irq9.ie = 8)
long_case("ARM7 books a timer event", false, TIMER, proc (n: NDS) = n.irq7.ie = 8)
# HALTCNT = sleep: the step loop stops at the end of that step
long_case("ARM7 goes to sleep", false,
          [IO, 0xE280_0C03'u32, 0xE280_0001'u32, 0xE3A0_10C0'u32, 0xE5C0_1000'u32],
          proc (n: NDS) = discard)
# DMA0 (r3 SAD, r4 DAD, r5 CNT): 400 words, fixed destination, into TM0CNT:
# the timer is booked and the DMA holds the CPU past the next event, so the
# run ends at the access that booked it (its `attn` never looked at)
proc dma_setup(n: NDS; cpu9: bool) =
  for i in 0'u32 ..< 400: Arm7Bus(nds: n).write32(0x0220_0000'u32 + 4 * i, 0x00C0_FFF0'u32)
  let r = if cpu9: addr n.arm9.r else: addr n.arm7.r
  r[3] = 0x0220_0000'u32; r[4] = 0x0400_0100'u32; r[5] = 0x8440_0000'u32 or 400
  if cpu9: n.irq9.ie = 8 else: n.irq7.ie = 8
const DMA = [IO, 0xE280_00B0'u32, 0xE880_0038'u32]
long_case("ARM9 DMA books an event and stalls the CPU", true, DMA,
          proc (n: NDS) = n.dma_setup(true))
long_case("ARM7 DMA books an event and stalls the CPU", false, DMA,
          proc (n: NDS) = n.dma_setup(false))

echo "== passable events"

# arm/cpu.nim loop_edge: events and frontend calls bump `ev_epoch`, which
# only a loop that read a device must see; a loop polling RAM stays proven.
# Each rule here, broken, lets the skipping machine run ahead of the one
# that executes every pass. The CPU without code is halted with no
# interrupt to wake it, so the one spinning runs straight to each event.

proc pass_case(name: string; code9, code7: openArray[uint32];
               setup: proc (n: NDS) {.nimcall.}; frames = 8) =
  ## The ARM9 runs `code9` at 0x02100000, the ARM7 `code7` at 0x03801000
  ## (each with r3 = 0x02180000, a RAM word); skipping on and off, the
  ## state compared every frame.
  var ms: array[2, NDS]
  for k in 0..1:
    let n = new_nds(tiny_rom(), @[], @[], @[])
    n.rtc.set_fixed_clock(n.sched, to_calendar_seconds(2004, 1, 1, 0, 0, 0))
    n.arm9.wl_on = k == 0; n.arm7.wl_on = k == 0; n.long_on = k == 0
    let b7 = Arm7Bus(nds: n)
    for i, w in code9: b7.write32(0x0210_0000'u32 + uint32(4 * i), w)
    for i, w in code7: b7.write32(0x0380_1000'u32 + uint32(4 * i), w)
    for i, w in ACK_HANDLER:
      b7.write32(0x0210_1000'u32 + uint32(4 * i), w)
      b7.write32(0x0380_2000'u32 + uint32(4 * i), w)
    Arm9Bus(nds: n).write32(0x0080_3FFC'u32, 0x0210_1000'u32)
    b7.write32(0x0380_FFFC'u32, 0x0380_2000'u32)
    for c in [n.irq9, n.irq7]: c.ime = 1; c.ie = 0; c.iff = 0
    n.arm9.set_cpsr(0x1F); n.arm9.next_pc = 0x0210_0000'u32; n.arm9.r[3] = 0x0218_0000'u32
    n.arm7.set_cpsr(0x1F); n.arm7.next_pc = 0x0380_1000'u32; n.arm7.r[3] = 0x0218_0000'u32
    n.arm9.halted = code9.len == 0
    n.arm7.halted = code7.len == 0
    setup(n)
    ms[k] = n
  var same = true
  var at = -1
  for f in 0 ..< frames:
    ms[0].run_frame(); ms[1].run_frame()
    if same and ms[0].state_payload() != ms[1].state_payload():
      same = false; at = f
  check(same, name, "differs at frame " & $at)
  check(ms[0].arm9.wl_skipped + ms[0].arm7.wl_skipped > 0, name & ": the fast machine skipped")

const
  # loop: LDR r1, [r3]; CMP r1, #0; BEQ loop  (a RAM word nothing sets)
  RAM_WAIT = [0xE593_1000'u32, 0xE351_0000'u32, 0x0AFF_FFFC'u32]
  # r2 = 100; wait: until VCOUNT == r2 (a steady register: its reads bump
  # no epoch); then r6 += timer 0's counter (when it saw the line), r2 += 1,
  # back to 100 after 189
  VCOUNT_WAIT = [IO, 0xE3A0_2064'u32,
                 0xE1D0_10B6'u32, 0xE151_0002'u32, 0x1AFF_FFFC'u32,   # wait: LDRH VCOUNT; CMP; BNE
                 0xE280_4C01'u32, 0xE1D4_50B0'u32, 0xE086_6005'u32,   # r6 += TM0CNT_L
                 0xE282_2001'u32, 0xE352_00BE'u32, 0x03A0_2064'u32,   # r2 += 1; == 190: 100
                 0xEAFF_FFF5'u32]                                     # B wait

proc timer0_on(n: NDS; arm9: bool) =
  if arm9: Arm9Bus(nds: n).write32(0x0400_0100'u32, 0x0080_0000'u32)
  else: Arm7Bus(nds: n).write32(0x0400_0100'u32, 0x0080_0000'u32)

pass_case("an ARM9 loop polling VCOUNT ends when the line changes", VCOUNT_WAIT, [],
          proc (n: NDS) = n.timer0_on(true))
pass_case("an ARM7 loop polling VCOUNT ends when the line changes", [], VCOUNT_WAIT,
          proc (n: NDS) = n.timer0_on(false))
# H-blank DMA, repeating, copying 4 unchanging words: memory stays the same,
# but each transfer holds the bus (dma_stall) for less than a pass of
# repeats would take
pass_case("a RAM loop held by H-blank DMA keeps its timing", RAM_WAIT, [],
          proc (n: NDS) =
            let b = Arm9Bus(nds: n)
            b.write32(0x0400_00B0'u32, 0x0220_0000'u32)
            b.write32(0x0400_00B4'u32, 0x0221_0000'u32)
            b.write32(0x0400_00B8'u32, 0x9600_0004'u32))
# the ARM9 spins on RAM; a timer IRQ, which leaves the loop proven, runs a
# handler that wakes the halted ARM7 (IPCSYNC): the interrupt is work, so
# the machine is not quiet (nds.nim quiet) and the wake lands in its step
const
  WAKE_HANDLER = [IO, 0xE3A0_1A02'u32, 0xE580_1180'u32,   # IPCSYNC: IRQ to the ARM7
                  0xE280_0C02'u32, 0xE280_0014'u32,
                  0xE3A0_1008'u32, 0xE580_1000'u32,       # IF = timer 0
                  0xE285_5001'u32, 0xE12F_FF1E'u32]       # r5 += 1; BX LR
  WOKEN_HANDLER = [IO, 0xE280_4C01'u32, 0xE1D4_50B0'u32, 0xE086_6005'u32,   # r6 += TM0CNT_L
                   0xE280_0C02'u32, 0xE280_0014'u32,
                   0xE3A0_1801'u32, 0xE580_1000'u32,      # IF = IPC sync
                   0xE12F_FF1E'u32]
  HALT_LOOP = [IO, 0xE280_0C03'u32, 0xE3A0_1080'u32,      # r0 = HALTCNT - 1, r1 = halt
               0xE5C0_1001'u32, 0xEAFF_FFFD'u32]          # loop: STRB r1, [r0, #1]; B loop
pass_case("an interrupt taken in a RAM loop is work", RAM_WAIT, HALT_LOOP,
          proc (n: NDS) =
            for i, w in WAKE_HANDLER:
              Arm7Bus(nds: n).write32(0x0210_1000'u32 + uint32(4 * i), w)
            for i, w in WOKEN_HANDLER:                     # the ARM7 notes when it woke
              Arm7Bus(nds: n).write32(0x0380_2000'u32 + uint32(4 * i), w)
            n.timer0_on(false)
            n.irq9.ie = 8
            n.irq7.ie = 1'u32 shl 16
            Arm7Bus(nds: n).write16(0x0400_0180'u32, 0x4000)              # ARM7 IPC IRQ on
            Arm9Bus(nds: n).write32(0x0400_0100'u32, 0x00C0_C000'u32))   # timer 0, IRQ

block:
  # a state loaded over a machine spinning in a proven RAM loop: the loaded
  # memory differs, so the proof must not survive the load (after_load)
  proc spin_machine(): NDS =
    result = new_nds(tiny_rom(), @[], @[], @[])
    result.rtc.set_fixed_clock(result.sched, to_calendar_seconds(2004, 1, 1, 0, 0, 0))
    for i, w in @RAM_WAIT & @[0xE3A0_2005'u32, 0xE583_2004'u32, 0xEAFF_FFFE'u32]:
      Arm7Bus(nds: result).write32(0x0210_0000'u32 + uint32(4 * i), w)   # then [r3+4] = 5
    result.arm9.set_cpsr(0x1F); result.arm9.next_pc = 0x0210_0000'u32
    result.arm9.r[3] = 0x0218_0000'u32
  let a = spin_machine()
  for _ in 0 ..< 3: a.run_frame()
  check(a.arm9.idle_now(), "the loop is proven")
  let c = spin_machine()
  check(c.load_state_bytes(a.state_bytes()), "state loads")
  c.main_ram[0x18_0000] = 1                                   # the flag, set behind the CPU's back
  let s1 = c.state_bytes()
  let d = spin_machine()
  check(a.load_state_bytes(s1) and d.load_state_bytes(s1), "the flag-set state loads")
  for _ in 0 ..< 2:
    a.run_frame(); d.run_frame()
  check(a.state_payload() == d.state_payload() and a.main_ram[0x18_0004] == 5,
        "loaded over the spinning machine, it runs as on a fresh one")

echo ""
if failures == 0:
  echo "All DS perf checks passed"
else:
  echo failures, " DS perf check(s) FAILED"
  quit(1)
