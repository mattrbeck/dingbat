## Serialize-while-running soak for both cores, with range checks ON.
## Run standalone: nimble test_statesoak   (or ./dingbat_state_soak_test [filter])
##
## The web build is -d:danger, so a core bug that only surfaces as a Defect
## (RangeDefect, OverflowDefect, IndexDefect) is silent there and fatal on
## desktop. fc686286c was one: a GB noise-channel deadline wrapped at the
## frame rebase, the next NR43 write turned it into a far-future LFSR
## deadline, and every state payload after that raised RangeDefect in
## apu_arm_state_events (the desktop rewind ring died; the web froze the
## noise). No committed ROM kept the noise running across a frame boundary
## and then rewrote NR43, so nothing caught it for six weeks.
##
## This drives each core the way the rewind ring does, but every frame: a
## payload built and pushed into a real Rewind ring (interval 1) after each
## frame, and now and then a rewind (pop, apply) followed by a replay of the
## frames it undid. Checked:
##   - no Defect or exception from step_frame / state_payload / apply, and a
##     payload the core wrote loads again;
##   - apply(p) then state_payload() gives back p;
##   - the replayed frames reproduce the live run's payloads byte for byte.
##
## Inputs:
##   (a) every ROM committed under tests/roms (copied to a temp folder, so no
##       .sav lands beside them), each for RomFrames frames;
##   (b) a seeded random program per core (GB as DMG and as CGB, on both PPUs
##       for one seed; GBA) that writes random values to the APU / timer /
##       DMA / PPU / interrupt registers at random points in the frame, with
##       delay loops of random length between clusters, halts that wake on
##       V-blank, OAM DMA and (CGB) HDMA and speed switches, (GBA) DMA incl.
##       sound-FIFO and video-capture timing; on top of that the harness pokes
##       random APU / timer / PPU values at the frame boundary itself, where
##       the rebase has just run.
## Everything is a pure function of the seed: a failure prints the case and
## seed, and `./dingbat_state_soak_test <case>` reruns just that case.
##
## Known core issues this soak found, reported as [KNOWN] rather than failed
## until they are fixed (DINGBAT_SOAK_STRICT=1 fails on every one):
##   - GB: a payload written on the frame the LCD is switched on (LY 0, mode
##     2) is refused by load_ppu_state (KnownRefusal).
##   - Replays of the random programs diverge: state the payload does not
##     carry. GB: apu.noise_phase (with the other fields held for the batched
##     GB_PAYLOAD_VERSION bump), ppu.stat_drop_pending living past its
##     M-cycle. GBA: bus.sync_bits bit 1, dma.video_active (KnownReplay),
##     cpu.irq_line forced low on load with a check pending, the IRQ
##     synchroniser's pipe/stall stamps with the bus DMA stamps.
##   - GBA: an H-blank DMA burst longer than a line books an interrupt check
##     per line that each burst pushes back, until the event queue overflows
##     (AssertionDefect here, an out-of-bounds write under -d:danger). The
##     program keeps H-blank bursts short unless strict.

import std/[os, strutils, strformat, times]
import dingbat/gb/gb
import dingbat/gba/gba
import dingbat/common/[rewind, serialize]

const
  RomFrames = 150         ## per committed ROM
  RandomFrames = 1200     ## per random-program case
  RewindMin = 25          ## frames between rewinds: RewindMin + rand(RewindSpan)
  RewindSpan = 60
  RewindMaxDepth = 20     ## snapshots undone per rewind: 1 + rand(RewindMaxDepth)

  KnownRefusal = "PPU mode 2 on line 0"
    ## GB: the frame after the LCD is switched on ends at LY 0 in mode 2, and
    ## load_ppu_state refuses every mode-2 state (b5dddb0c), so a payload the
    ## core wrote cannot be loaded. Reported, not failed, until the core is
    ## fixed; DINGBAT_SOAK_STRICT=1 fails on it.

  KnownReplay = [
    ("gbaedge-auto.gba", "DMA3 video capture runs across the frame boundary " &
     "and dma.video_active is not in the payload")]
    ## Committed ROMs whose replay is known to diverge, and why. Every other
    ## committed ROM must replay bit for bit.
  RandomReplayKnown = "machine state the payload does not carry"
    ## The random programs reach several (see the header); reported only.

var failures = 0
var only = ""             # case-name filter from the command line
let strict = existsEnv("DINGBAT_SOAK_STRICT")
  ## Known core issues fail instead of being reported, and the GBA program
  ## may run H-blank DMA bursts longer than a line (see gba_program).

proc fail(msg: string) =
  echo "  [FAIL] ", msg
  inc failures

# ---- deterministic PRNG (splitmix64): independent of std/random's version --

type Rng = object
  s: uint64

proc next(r: var Rng): uint64 =
  r.s += 0x9E3779B97F4A7C15'u64
  var z = r.s
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc below(r: var Rng; n: int): int = int(r.next() mod uint64(max(n, 1)))
proc chance(r: var Rng; pct: int): bool = r.below(100) < pct
proc byte8(r: var Rng): uint8 = uint8(r.next() and 0xFF)
proc half16(r: var Rng): uint16 = uint16(r.next() and 0xFFFF)
proc word32(r: var Rng): uint32 = uint32(r.next() and 0xFFFF_FFFF'u64)

proc mix(seed: uint64; frame: int): Rng =
  ## The harness's per-frame poke stream: a function of (seed, frame) only,
  ## so a replay after a rewind pokes exactly what the live run poked.
  var r = Rng(s: seed xor (uint64(frame) * 0xD1B54A32D192ED03'u64))
  discard r.next()
  r

proc diff_note(a, b: string): string =
  ## Where two payloads differ: first offset, bytes differing, lengths.
  var first = -1
  var n = 0
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]:
      if first < 0: first = i
      inc n
  &"first difference at byte {first} of {a.len} vs {b.len}, {n} bytes differ"

proc fnv(s: string): uint64 =
  result = 0xcbf29ce484222325'u64
  for c in s:
    result = (result xor uint64(uint8(c))) * 0x100000001b3'u64

# ---- GB: register values ---------------------------------------------------

proc gb_reg_write(r: var Rng; cgb, harness: bool): (uint8, uint8) =
  ## One (FF00+lo, value) store to an APU / timer / PPU register (and, for
  ## the program, IE/IF and the CGB banks). Values lean towards "on" so the
  ## channels, timer and LCD mostly run.
  let pick = r.below(100)
  if pick < 22:
    # Channel 4, the fc686286c register set: NR43 rewritten while it runs.
    let lo = uint8(0x20 + r.below(4))
    var v = r.byte8()
    case lo
    of 0x21: (if r.chance(85): v = v or 0x10)          # DAC on
    of 0x23:
      v = v and 0x3F
      if r.chance(60): v = v or 0x80                     # trigger
      if r.chance(25): v = v or 0x40                     # length enable
    else: discard
    return (lo, v)
  if pick < 48:
    const regs = [0x10, 0x11, 0x12, 0x13, 0x14, 0x16, 0x17, 0x18, 0x19,
                  0x1A, 0x1B, 0x1C, 0x1D, 0x1E]
    let lo = uint8(regs[r.below(regs.len)])
    var v = r.byte8()
    case lo
    of 0x12, 0x17: (if r.chance(85): v = v or 0x10)
    of 0x1A: v = (if r.chance(80): 0x80'u8 else: 0'u8)
    of 0x14, 0x19, 0x1E:
      v = v and 0x47
      if r.chance(55): v = v or 0x80
      if r.chance(25): v = v or 0x40
    else: discard
    return (lo, v)
  if pick < 53:
    let lo = uint8(0x24 + r.below(3))
    var v = r.byte8()
    if lo == 0x26: v = (if r.chance(92): 0x80'u8 else: 0'u8)
    return (lo, v)
  if pick < 58:
    return (uint8(0x30 + r.below(16)), r.byte8())       # wave RAM
  if pick < 72:
    let lo = uint8(0x04 + r.below(4))
    var v = r.byte8()
    if lo == 0x07: (if r.chance(70): v = v or 0x04)     # TAC enable
    return (lo, v)
  if pick < 93 or harness:
    var regs = @[0x40, 0x41, 0x42, 0x43, 0x45, 0x47, 0x48, 0x49, 0x4A, 0x4B]
    if cgb: regs.add([0x4F, 0x68, 0x69, 0x6A, 0x6B, 0x70])
    let lo = uint8(regs[r.below(regs.len)])
    var v = r.byte8()
    case lo
    of 0x40: (if r.chance(90): v = v or 0x80)
    of 0x45: v = uint8(r.below(154))
    else: discard
    return (lo, v)
  let lo = if r.chance(50): 0xFF'u8 else: 0x0F'u8    # IE / IF
  (lo, r.byte8() and 0x1F)

proc gb_harness_poke(gb: GB; seed: uint64; frame: int) =
  ## At the frame boundary, straight after gb_rebase: 0-3 register stores,
  ## applied as the cheat engine applies its RAM writes.
  var r = mix(seed, frame)
  if r.chance(45): return
  for _ in 0 ..< 1 + r.below(3):
    let (lo, v) = gb_reg_write(r, gb.cgb_enabled, harness = true)
    write_byte(gb.memory, gb, 0xFF00 + int(lo), v)
  mem_flush_deferred(gb.memory, gb)

# ---- GB: the random program -------------------------------------------------

proc gb_program(seed: uint64; cgb: bool): string =
  ## A 32 KB ROM-only cart: vectors hold RETI, the entry copies an OAM-DMA
  ## routine into HRAM, then straight-line clusters of register stores, each
  ## followed by a delay loop, and a jump back to the first cluster.
  var r = Rng(s: seed)
  var rom = newString(0x8000)
  var pc = 0
  proc emit(bs: varargs[int]) =
    for b in bs:
      rom[pc] = char(b and 0xFF)
      inc pc
  for v in [0x40, 0x48, 0x50, 0x58, 0x60]: rom[v] = char(0xD9)   # reti
  pc = 0x100
  emit(0x00, 0xC3, 0x50, 0x01)                     # nop; jp $0150
  rom[0x143] = char(if cgb: 0x80 else: 0x00)
  pc = 0x150
  emit(0xF3, 0x31, 0xFE, 0xFF)                     # di; ld sp, $FFFE
  # HRAM $FF80: ldh ($46),a; ld a,$28; dec a; jr nz,-3; ret
  const dma = [0xE0, 0x46, 0x3E, 0x28, 0x3D, 0x20, 0xFD, 0xC9]
  for i, b in dma: emit(0x3E, b, 0xE0, 0x80 + i)
  let loop_start = pc
  while pc < 0x7F00:
    let kind = r.below(100)
    if kind < 4:
      emit(0xF3, 0x3E, r.below(0xE0), 0xCD, 0x80, 0xFF)   # di; ld a,src; call $FF80
    elif kind < 9:
      emit(if r.chance(60): 0xFB else: 0xF3)                # ei / di
    elif kind < 11:
      # Halt until V-blank: IE has bit 0, the LCD is on, IME is set.
      emit(0x3E, int(r.byte8() and 0x1F) or 1, 0xE0, 0xFF)
      emit(0x3E, int(r.byte8()) or 0x80, 0xE0, 0x40)
      emit(0xFB, 0x76, 0x00)
    elif cgb and kind < 14:
      # HDMA: source, VRAM destination, then mode/length (bit 7 = H-blank).
      emit(0x3E, r.below(0xE0), 0xE0, 0x51)
      emit(0x3E, int(r.byte8() and 0xF0), 0xE0, 0x52)
      emit(0x3E, r.below(0x20), 0xE0, 0x53)
      emit(0x3E, int(r.byte8() and 0xF0), 0xE0, 0x54)
      emit(0x3E, int(r.byte8()) and (if r.chance(60): 0xFF else: 0x0F), 0xE0, 0x55)
    elif cgb and kind < 15:
      emit(0x3E, 0x01, 0xE0, 0x4D, 0x10, 0x00)          # KEY1 = 1; stop: switch speed
    else:
      for _ in 0 ..< 1 + r.below(6):
        let (lo, v) = gb_reg_write(r, cgb, harness = false)
        emit(0x3E, int(v), 0xE0, int(lo))
    # Delay: ld bc,n; dec bc; ld a,b; or c; jr nz,-5 (7 M-cycles a pass,
    # ~2500 passes a frame at single speed).
    let n = if r.chance(55): 1 + r.below(400) else: 400 + r.below(6000)
    emit(0x01, n and 0xFF, n shr 8, 0x0B, 0x78, 0xB1, 0x20, 0xFB)
  emit(0xC3, loop_start and 0xFF, loop_start shr 8)
  var sum = 0
  for a in 0x134 .. 0x14C: sum = sum - int(uint8(rom[a])) - 1
  rom[0x14D] = char(sum and 0xFF)
  rom

# ---- GBA: register values ---------------------------------------------------

type GbaStore = object
  off: uint32     # offset from 0x04000000
  val: uint32
  width: int      # 2 or 4

proc gba_reg_write(r: var Rng): GbaStore =
  ## One store to a sound / timer / PPU register (no DMA, no interrupts: the
  ## harness pokes these at the frame boundary too).
  let pick = r.below(100)
  if pick < 45:
    const regs = [0x60, 0x62, 0x64, 0x68, 0x6C, 0x70, 0x72, 0x74, 0x78, 0x7C,
                  0x80, 0x82, 0x84, 0x88]
    let off = uint32(regs[r.below(regs.len)])
    var v = uint32(r.half16())
    case off
    of 0x64, 0x6C, 0x74, 0x7C:
      v = v and 0x47FF
      if r.chance(55): v = v or 0x8000                  # trigger
    of 0x84: v = (if r.chance(92): 0x80'u32 else: 0'u32)
    of 0x70: v = v and 0xE0
    else: discard
    return GbaStore(off: off, val: v, width: 2)
  if pick < 52:
    return GbaStore(off: 0x90'u32 + 2'u32 * uint32(r.below(8)), val: r.half16(), width: 2)
  if pick < 58:
    return GbaStore(off: 0xA0'u32 + 4'u32 * uint32(r.below(2)), val: r.word32(), width: 4)
  if pick < 75:
    let t = uint32(r.below(4)) * 4
    if r.chance(40): return GbaStore(off: 0x100 + t, val: r.half16(), width: 2)
    var v = uint32(r.byte8()) and 0xC7
    if r.chance(75): v = v or 0x80                      # enable
    return GbaStore(off: 0x102 + t, val: v, width: 2)
  const ppu = [0x00, 0x02, 0x04, 0x08, 0x0A, 0x0C, 0x0E, 0x10, 0x12, 0x14,
               0x16, 0x18, 0x1A, 0x1C, 0x1E, 0x20, 0x22, 0x24, 0x26, 0x28,
               0x2C, 0x30, 0x32, 0x34, 0x36, 0x38, 0x3C, 0x40, 0x42, 0x44,
               0x46, 0x48, 0x4A, 0x4C, 0x50, 0x52, 0x54]
  let off = uint32(ppu[r.below(ppu.len)])
  var v = uint32(r.half16())
  if off == 0x00 and r.chance(90): v = v and not 0x80'u32  # mostly not forced blank
  if off == 0x04: v = (v and 0xFF38) or (if r.chance(50): 0x08'u32 else: 0'u32)
  GbaStore(off: off, val: v, width: 2)

proc gba_harness_poke(gba: GBA; seed: uint64; frame: int) =
  var r = mix(seed, frame)
  if r.chance(45): return
  for _ in 0 ..< 1 + r.below(3):
    let s = gba_reg_write(r)
    if s.width == 4: gba.bus.write_word_internal(0x04000000'u32 + s.off, s.val)
    else: gba.bus.write_half_internal(0x04000000'u32 + s.off, uint16(s.val))

# ---- GBA: the random program (ARM) ------------------------------------------

proc gba_program(seed: uint64): string =
  ## ARM code from 0x08000000: an IRQ handler that acknowledges IF and sets
  ## the BIOS wait flags, then clusters of register stores (r4 = 0x04000000,
  ## r6 = +0x100, r7 = +0x200, value in r5) and DMA programs (address in r9),
  ## VBlankIntrWait now and then, delay loops (r8) between clusters.
  var r = Rng(s: seed)
  var code: seq[uint32]
  proc emit(w: uint32) = code.add(w)
  proc mov_imm(rd: int; imm8, rot: uint32) =
    emit(0xE3A00000'u32 or (uint32(rd) shl 12) or (rot shl 8) or imm8)
  proc orr_imm(rd, rn: int; imm8, rot: uint32) =
    emit(0xE3800000'u32 or (uint32(rn) shl 16) or (uint32(rd) shl 12) or
         (rot shl 8) or imm8)
  proc add_imm(rd, rn: int; imm8, rot: uint32) =
    emit(0xE2800000'u32 or (uint32(rn) shl 16) or (uint32(rd) shl 12) or
         (rot shl 8) or imm8)
  proc load(rd: int; v: uint32) =
    mov_imm(rd, v and 0xFF, 0)
    if ((v shr 8) and 0xFF) != 0: orr_imm(rd, rd, (v shr 8) and 0xFF, 12)
    if ((v shr 16) and 0xFF) != 0: orr_imm(rd, rd, (v shr 16) and 0xFF, 8)
    if ((v shr 24) and 0xFF) != 0: orr_imm(rd, rd, (v shr 24) and 0xFF, 4)
  proc strh(rd, rn: int; off: uint32) =
    emit(0xE1C000B0'u32 or (uint32(rn) shl 16) or (uint32(rd) shl 12) or
         ((off shr 4) shl 8) or (off and 0xF))
  proc str(rd, rn: int; off: uint32) =
    emit(0xE5800000'u32 or (uint32(rn) shl 16) or (uint32(rd) shl 12) or off)
  proc store(s: GbaStore) =
    # r4/r6/r7 cover offsets 0x000-0x0FF / 0x100-0x1FF / 0x200-0x2FF
    let base = if s.off >= 0x200: 7 elif s.off >= 0x100: 6 else: 4
    let off = s.off and 0xFF
    load(5, s.val)
    if s.width == 4: str(5, base, off) else: strh(5, base, off)

  # 0x08000000: b init (the handler sits right after it)
  emit(0xEA000000'u32 or 11)                     # skip the 12-word handler
  let handler = uint32(code.len * 4)
  mov_imm(0, 4, 4)                               # r0 = 0x04000000
  add_imm(0, 0, 2, 12)                           # r0 += 0x200
  emit(0xE5901000'u32)                           # ldr r1, [r0]  (IE | IF << 16)
  emit(0xE0011821'u32)                           # and r1, r1, r1, lsr #16
  emit(0xE1C010B2'u32)                           # strh r1, [r0, #2]  (ack IF)
  mov_imm(2, 3, 4)                               # r2 = 0x03000000
  orr_imm(2, 2, 0x7F, 12)                        # r2 |= 0x7F00
  orr_imm(2, 2, 0xF8, 0)                         # r2 |= 0xF8  -> 0x03007FF8
  emit(0xE1D230B0'u32)                           # ldrh r3, [r2]
  emit(0xE1833001'u32)                           # orr r3, r3, r1
  emit(0xE1C230B0'u32)                           # strh r3, [r2]
  emit(0xE12FFF1E'u32)                           # bx lr
  doAssert code.len == 13
  # init
  mov_imm(4, 4, 4)                               # r4 = 0x04000000
  add_imm(6, 4, 1, 12)                           # r6 = r4 + 0x100
  add_imm(7, 4, 2, 12)                           # r7 = r4 + 0x200
  load(0, 0x08000000'u32 + handler)
  load(1, 0x03007FFC'u32)
  str(0, 1, 0)                                   # user IRQ handler
  let loop_start = code.len
  while code.len * 4 < 0x30000:
    let kind = r.below(100)
    if kind < 14:
      # One DMA channel, enable last. Destinations stay out of IWRAM (the
      # handler pointer and the stacks live there) and away from region ends.
      let ch = uint32(r.below(4))
      let base = 0xB0'u32 + 12 * ch
      var src: uint32
      case r.below(5)
      of 0: src = 0x08000000'u32 + (uint32(r.below(0x30000)) and not 3'u32)
      of 1: src = 0x02000000'u32 + (uint32(r.below(0x3F000)) and not 3'u32)
      of 2: src = 0x03000000'u32 + (uint32(r.below(0x7000)) and not 3'u32)
      of 3: src = 0x06000000'u32 + (uint32(r.below(0x17000)) and not 3'u32)
      else: src = 0x04000000'u32 + (uint32(r.below(0x60)) and not 3'u32)
      var timing = uint32(r.below(4))
      var count = uint32(1 + r.below(if r.chance(70): 0x40 else: 0x400))
      var dst: uint32
      var ctl = uint32(r.half16()) and 0x07E0         # dst/src ctrl, repeat, 32-bit
      if (ctl and 0x0180) == 0x0180: ctl = ctl and not 0x0100'u32  # src ctrl 3 is prohibited
      if timing == 3 and (ch == 1 or ch == 2):
        dst = 0x040000A0'u32 + 4 * uint32(r.below(2)) # sound FIFO
        ctl = (ctl or 0x0600) and not 0x0060'u32      # repeat, 32-bit, dest ignored
        count = 4
      else:
        if timing == 3 and ch == 0: timing = uint32(r.below(3))
        case r.below(4)
        of 0: dst = 0x02010000'u32 + (uint32(r.below(0x20000)) and not 3'u32)
        of 1: dst = 0x06004000'u32 + (uint32(r.below(0x10000)) and not 3'u32)
        of 2:
          dst = 0x05000100'u32 + (uint32(r.below(0x200)) and not 3'u32)
          count = min(count, 0x40)
        else:
          dst = 0x07000100'u32 + (uint32(r.below(0x200)) and not 3'u32)
          count = min(count, 0x40)
      # An H-blank burst longer than a line piles up interrupt checks until
      # the event queue overflows (reported; strict mode lets it happen).
      if timing == 2 and not strict: count = min(count, 0x40)
      ctl = ctl or (timing shl 12)
      if r.chance(30): ctl = ctl or 0x4000             # IRQ at the end
      if r.chance(85): ctl = ctl or 0x8000             # enable
      load(9, 0x04000000'u32 + base)
      load(5, src); str(5, 9, 0)
      load(5, dst); str(5, 9, 4)
      load(5, count); strh(5, 9, 8)
      load(5, ctl); strh(5, 9, 10)
    elif kind < 20:
      # Interrupt enables and IME; IF write-1-to-clear
      store(GbaStore(off: 0x200, val: uint32(r.half16()) and 0x3FFF, width: 2))
      if r.chance(50): store(GbaStore(off: 0x208, val: uint32(r.below(2)), width: 2))
      if r.chance(30): store(GbaStore(off: 0x202, val: uint32(r.half16()), width: 2))
    elif kind < 22:
      store(GbaStore(off: 0x204, val: uint32(r.half16()) and 0x5FFF, width: 2))  # WAITCNT
    elif kind < 25:
      # VBlankIntrWait: IE has V-blank, DISPSTAT asks for it
      store(GbaStore(off: 0x200, val: (uint32(r.half16()) and 0x3FFF) or 1, width: 2))
      store(GbaStore(off: 0x04, val: (uint32(r.half16()) and 0xFF38) or 8, width: 2))
      emit(0xEF050000'u32)                             # swi 0x05
    else:
      for _ in 0 ..< 1 + r.below(6): store(gba_reg_write(r))
    # Delay: r8 = n; subs r8, r8, #1; bne -1
    let n = if r.chance(55): uint32(1 + r.below(1500)) else: uint32(1500 + r.below(40000))
    load(8, n)
    emit(0xE2588001'u32)                               # subs r8, r8, #1
    emit(0x1AFFFFFD'u32)                               # bne (back one)
  let back = int32(loop_start) - int32(code.len) - 2
  emit(0xEA000000'u32 or (cast[uint32](back) and 0xFFFFFF))
  result = newString(code.len * 4)
  for i, w in code:
    for b in 0 .. 3: result[i * 4 + b] = char((w shr (8 * b)) and 0xFF)

# ---- the soak itself ---------------------------------------------------------

proc known(label, what: string) =
  ## A known core issue (see KnownRefusal and the header): reported, and a
  ## failure only under DINGBAT_SOAK_STRICT=1.
  if strict: fail(label & ": " & what)
  else: echo "  [KNOWN] ", label, ": ", what

proc soak[T](label: string; make: proc(): T; frames: int; seed: uint64;
             poke: proc(e: T; seed: uint64; frame: int) {.nimcall.};
             replay_known: string) =
  ## Run `frames` frames with a payload pushed into a Rewind ring after each
  ## one, rewinding and replaying now and then; each rewind's payload is also
  ## loaded into a core built for it (a state loaded after a restart, or on
  ## another device), which must replay as the rewound core does. `make`
  ## builds and post-inits a core. Stops at the first failure.
  let emu = make()
  var r = Rng(s: seed xor 0x5EED'u64)
  var ring = new_rewind(interval = 1)
  var live = newSeq[uint64](frames)
  var recent: array[RewindMaxDepth + 2, string]   # live payloads, for notes
  var f = 0
  var next_rewind = RewindMin + r.below(RewindSpan)
  var stage = "step_frame"
  var rewinds, replayed = 0
  var diverged, refused, twin_diverged = false
  var distinct_seen: seq[uint64]
  proc run_frame(g: int): string =
    if poke != nil: poke(emu, seed, g)
    stage = "step_frame"
    emu.step_frame()
    stage = "state_payload"
    result = emu.state_payload()
    stage = "rewind push"
    ring.push(result)
    recent[g mod recent.len] = result
  let t0 = epochTime()
  try:
    while f < frames:
      let p = run_frame(f)
      live[f] = fnv(p)
      if distinct_seen.len < 64 and live[f] notin distinct_seen:
        distinct_seen.add(live[f])
      inc f
      if f < next_rewind or ring.len <= 2: continue
      next_rewind = f + RewindMin + r.below(RewindSpan)
      # The desktop's rewind: the first pop is the current state, each
      # further one a frame older.
      let depth = 1 + r.below(min(RewindMaxDepth, ring.len - 2))
      stage = "rewind pop"
      var snap = ""
      for _ in 0 .. depth: snap = ring.pop()
      stage = "apply_state_payload"
      try:
        emu.apply_state_payload(snap)
      except StateError as e:
        # A payload this core wrote a moment ago must load.
        if KnownRefusal notin e.msg or strict: raise
        if not refused:
          refused = true
          known(label, &"a payload the core wrote after frame {f - 1 - depth} " &
                &"is refused: {e.msg}")
        # The apply stopped partway: back to where the run was, and on.
        let cur = recent[(f - 1) mod recent.len]
        emu.apply_state_payload(cur)
        ring.push(cur)
        continue
      stage = "state_payload after apply"
      let again = emu.state_payload()
      if again != snap:
        fail(&"{label} seed {seed}: apply then state_payload is not the " &
             &"applied payload (rewound to after frame {f - 1 - depth}): " &
             diff_note(snap, again))
        return
      stage = "apply_state_payload (new core)"
      let twin = make()
      twin.apply_state_payload(snap)
      var twin_ok = true
      for g in f - depth ..< f:
        let before = recent[g mod recent.len]
        let q = run_frame(g)
        inc replayed
        stage = "step_frame (new core)"
        if poke != nil: poke(twin, seed, g)
        twin.step_frame()
        let tq = twin.state_payload()
        if twin_ok and tq != q:
          twin_ok = false
          let what = &"the payload loaded into a new core diverged from " &
                     &"the rewound core at frame {g}: " & diff_note(q, tq)
          if replay_known.len == 0:
            fail(&"{label} seed {seed}: " & what)
            return
          if not twin_diverged:
            twin_diverged = true
            known(label, what & " (" & replay_known & ")")
            if strict: return
        if fnv(q) != live[g]:
          let what = &"replay after a rewind of {depth} diverged at frame " &
                     &"{g}: " & diff_note(before, q)
          if replay_known.len == 0:
            fail(&"{label} seed {seed}: " & what)
            return
          if not diverged:
            diverged = true
            known(label, what & " (" & replay_known & ")")
            if strict: return
          live[g] = fnv(q)   # the run goes on from the replayed history
      inc rewinds
  except Defect as e:
    fail(&"{label} seed {seed}: {e.name} in {stage} at frame {f}: {e.msg}")
    return
  except CatchableError as e:
    fail(&"{label} seed {seed}: {e.name} in {stage} at frame {f}: {e.msg}")
    return
  if distinct_seen.len < 8:
    fail(&"{label}: only {distinct_seen.len} distinct states in {frames} " &
         "frames; the soak is not exercising anything")
    return
  echo &"  [PASS] {label}: {frames} frames, {rewinds} rewinds, " &
       &"{replayed} replayed ({epochTime() - t0:.1f}s)"

proc wanted(label: string): bool = only.len == 0 or label.contains(only)

proc gb_maker(path: string; fifo: bool): proc(): GB =
  result = proc(): GB =
    result = new_gb("", path, fifo = fifo, headless = true, run_bios = false)
    result.post_init()

proc gba_maker(path: string): proc(): GBA =
  result = proc(): GBA =
    result = new_gba("", path, run_bios = false, use_hle = true)
    result.post_init()

proc known_replay(rel: string): string =
  ## Why a committed ROM's replay is known to diverge; "" = it must match.
  for (name, why) in KnownReplay:
    if rel == name: return why
  ""

# ---- cases -----------------------------------------------------------------

when not defined(soak_lib):

  if paramCount() >= 1: only = paramStr(1)

  let tmp = getTempDir() / &"dingbat_state_soak_{getCurrentProcessId()}"
  createDir(tmp)
  let t_start = epochTime()

  # (a) committed ROMs
  let roms_dir = currentSourcePath().parentDir / "roms"
  var roms: seq[string]
  for path in walkDirRec(roms_dir):
    let ext = path.splitFile().ext.toLowerAscii()
    if ext in [".gb", ".gbc", ".gba"]: roms.add(path)
  doAssert roms.len > 0, "no ROMs under " & roms_dir
  for i, path in roms:
    let rel = path.relativePath(roms_dir).replace('\\', '/')   # one seed per ROM on every OS
    let label = "rom " & rel
    if not wanted(label): continue
    # A copy per ROM: the cores load and write <rom>.sav beside the file.
    let copy = tmp / &"{i}_{path.extractFilename()}"
    copyFile(path, copy)
    let seed = fnv(rel)
    if path.splitFile().ext.toLowerAscii() == ".gba":
      soak(label, gba_maker(copy), RomFrames, seed, nil,
           replay_known = known_replay(rel))
    else:
      soak(label, gb_maker(copy, fifo = true), RomFrames, seed, nil,
           replay_known = known_replay(rel))

  # (b) random programs
  const gb_seeds = [0x6B01'u64, 0x6B02, 0x6B03]
  for seed in gb_seeds:
    for cgb in [false, true]:
      for fifo in [true, false]:
        if not fifo and seed != gb_seeds[0]: continue    # scanline PPU: one seed
        let label = &"random gb {(if cgb: \"cgb\" else: \"dmg\")}" &
                    &"{(if fifo: \"\" else: \" scanline\")} {seed:#x}"
        if not wanted(label): continue
        let path = tmp / &"random_{seed:x}_{ord(cgb)}.gb"
        writeFile(path, gb_program(seed, cgb))
        soak(label, gb_maker(path, fifo), RandomFrames, seed, gb_harness_poke,
             replay_known = RandomReplayKnown)

  for seed in [0xA901'u64, 0xA902, 0xA903]:
    let label = &"random gba {seed:#x}"
    if not wanted(label): continue
    let path = tmp / &"random_{seed:x}.gba"
    writeFile(path, gba_program(seed))
    soak(label, gba_maker(path), RandomFrames, seed, gba_harness_poke,
         replay_known = RandomReplayKnown)

  try: removeDir(tmp)
  except OSError: discard

  echo &"state soak: {epochTime() - t_start:.1f}s"
  if failures == 0: echo "ALL STATE SOAK CHECKS PASS"
  else:
    echo failures, " FAILURE(S)"
    quit(1)
