## The Nintendo DS: two CPUs on one timeline, their two bus maps, the shared
## devices, direct boot and the frame loop. Subsystems live in their own
## modules (arm/, mem/, gpu/, gpu3d/, io/); this module wires them together.
## The bus maps are in bus9.nim / bus7.nim and the boot path in boot.nim,
## included here so they see the NDS type. docs/nds/spec.md is the map.

import std/[os, strutils]
import arm/[cpu, cp15]
import sched
import mem/vram
import gpu/[gpu, engine2d]
import gpu3d/gpu3d
import io/[irq, timers, ipc, divsqrt, dma, input, spi, cart, spu, rtc, wifi]

export cpu, sched, gpu, engine2d, input, vram, spu

type
  Arm9Bus* = object
    nds* {.cursor.}: NDS
  Arm7Bus* = object
    nds* {.cursor.}: NDS

  NDS* = ref object
    sched*: NdsScheduler
    arm9*: ArmCpu[Arm9Bus]
    arm7*: ArmCpu[Arm7Bus]
    cp15*: Cp15
    main_ram*: seq[uint8]       ## 4 MB, 0x02000000 (mirrored to 0x02FFFFFF)
    shared_wram*: seq[uint8]    ## 32 KB, split by WRAMCNT
    arm7_wram*: seq[uint8]      ## 64 KB, 0x03800000
    itcm*: seq[uint8]           ## 32 KB
    dtcm*: seq[uint8]           ## 16 KB
    bios9*: seq[uint8]          ## 4 KB at 0xFFFF0000
    bios7*: seq[uint8]          ## 16 KB at 0x00000000
    wramcnt*: uint8
    exmemcnt*: uint16
    postflg9*, postflg7*: uint8
    powcnt2*: uint16
    biosprot*: uint32
    gpu*: Gpu
    gpu3d*: Gpu3d
    irq9*, irq7*: IrqCtl
    timers9*, timers7*: Timers
    dma9*, dma7*: Dma
    ipc*: Ipc
    divsqrt*: DivSqrt
    input*: Input
    spi*: Spi
    cart*: Cart
    spu*: Spu
    rtc*: Rtc
    wifi*: Wifi
    frame_done*: bool
    line_start*: int64          ## master cycle the current line began
    unmapped_log*: int          ## first few unmapped accesses are logged

const
  MAIN_RAM_SIZE = 4 * 1024 * 1024
  ARM9_CYCLES_PER_INSTR = 2     ## placeholder timing (docs/nds/spec.md)
  ARM7_CYCLES_PER_INSTR = 4
  SLICE = 64                    ## max master cycles one CPU runs ahead

proc note_unmapped(n: NDS; who: string; a: uint32; write: bool) =
  if n.unmapped_log < 32:
    inc n.unmapped_log
    stderr.writeLine("nds " & who & ": unmapped " & (if write: "write " else: "read ") &
                     "0x" & toHex(a, 8))

template rd16(s: seq[uint8]; i: int): uint32 =
  uint32(s[i]) or (uint32(s[i + 1]) shl 8)
template rd32(s: seq[uint8]; i: int): uint32 =
  uint32(s[i]) or (uint32(s[i + 1]) shl 8) or (uint32(s[i + 2]) shl 16) or (uint32(s[i + 3]) shl 24)
template wr16(s: var seq[uint8]; i: int; v: uint32) =
  s[i] = uint8(v); s[i + 1] = uint8(v shr 8)
template wr32(s: var seq[uint8]; i: int; v: uint32) =
  s[i] = uint8(v); s[i + 1] = uint8(v shr 8); s[i + 2] = uint8(v shr 16); s[i + 3] = uint8(v shr 24)

include bus9, bus7, boot

# ---------------------------------------------------------------------------
# Display timing events

proc dispstat_irqs(n: NDS; s: DispStat; c: IrqCtl; src: IrqSource) =
  case src
  of irqVBlank: (if s.vblank_irq: c.raise_irq(src))
  of irqHBlank: (if s.hblank_irq: c.raise_irq(src))
  of irqVCount: (if s.vcount_irq: c.raise_irq(src))
  else: discard

proc on_hblank(n: NDS) =
  let g = n.gpu
  g.in_hblank = true
  if g.vcount < VISIBLE_LINES:
    g.render_line(g.vcount)
    n.dma9.trigger(Arm9Bus(nds: n), dtHBlank)
  n.dispstat_irqs(g.stat9, n.irq9, irqHBlank)
  n.dispstat_irqs(g.stat7, n.irq7, irqHBlank)

proc on_line_end(n: NDS) =
  let g = n.gpu
  g.in_hblank = false
  inc g.vcount
  if g.vcount == LINES: g.vcount = 0
  n.line_start = n.sched.now
  if g.vcount == VISIBLE_LINES:
    g.in_vblank = true
    inc g.frame_count
    n.frame_done = true
    n.dispstat_irqs(g.stat9, n.irq9, irqVBlank)
    n.dispstat_irqs(g.stat7, n.irq7, irqVBlank)
    n.dma9.trigger(Arm9Bus(nds: n), dtVBlank)
    n.dma7.trigger(Arm7Bus(nds: n), dtVBlank)
    n.gpu3d.on_vblank()
  elif g.vcount == LINES - 1:
    g.in_vblank = false
  elif g.vcount == 0:
    n.dma9.trigger(Arm9Bus(nds: n), dtDisplayStart)
  if g.vcount == int(g.stat9.vcount_setting): n.dispstat_irqs(g.stat9, n.irq9, irqVCount)
  if g.vcount == int(g.stat7.vcount_setting): n.dispstat_irqs(g.stat7, n.irq7, irqVCount)
  n.sched.schedule(n.line_start + HBLANK_CYCLES, evHBlank)
  n.sched.schedule(n.line_start + LINE_CYCLES, evLineEnd)

proc dispatch(n: NDS; ev: NdsEvent) =
  case ev
  of evHBlank: n.on_hblank()
  of evLineEnd: n.on_line_end()
  of evTimer9_0 .. evTimer9_3: n.timers9.on_event(ev)
  of evTimer7_0 .. evTimer7_3: n.timers7.on_event(ev)
  of evSpuSample:
    n.spu.tick(Arm7Bus(nds: n))
    n.spu.next_tick += SPU_TICK_CYCLES
    n.sched.schedule(n.spu.next_tick, evSpuSample)
  of evCartDone, evGxFifo: discard

# ---------------------------------------------------------------------------
# Construction and the frame loop

proc read_file_bytes(path: string): seq[uint8] =
  if path.len == 0 or not fileExists(path): return @[]
  let s = readFile(path)
  result = newSeq[uint8](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc new_nds*(rom: seq[uint8]; bios9, bios7, firmware: seq[uint8]): NDS =
  let n = NDS(sched: new_nds_scheduler())
  n.main_ram = newSeq[uint8](MAIN_RAM_SIZE)
  n.shared_wram = newSeq[uint8](32 * 1024)
  n.arm7_wram = newSeq[uint8](64 * 1024)
  n.itcm = newSeq[uint8](32 * 1024)
  n.dtcm = newSeq[uint8](16 * 1024)
  n.bios9 = bios9
  n.bios7 = bios7
  if n.bios9.len < 4096: n.bios9.setLen(4096)
  if n.bios7.len < 16384: n.bios7.setLen(16384)
  n.irq9 = IrqCtl()
  n.irq7 = IrqCtl()
  n.input = Input()
  n.gpu = new_gpu()
  n.gpu3d = new_gpu3d()
  n.timers9 = Timers(sched: n.sched, irq: n.irq9, first_event: evTimer9_0)
  n.timers7 = Timers(sched: n.sched, irq: n.irq7, first_event: evTimer7_0)
  n.dma9 = new_dma(true, n.irq9)
  n.dma7 = new_dma(false, n.irq7)
  n.ipc = new_ipc(n.irq9, n.irq7)
  n.divsqrt = DivSqrt()
  n.spi = new_spi(if firmware.len > 0: firmware else: synth_firmware(), n.irq7, n.input)
  n.cart = new_cart(rom, n.irq9, n.irq7)
  n.spu = new_spu()
  n.rtc = Rtc()
  n.wifi = Wifi()
  n.arm9 = new_arm_cpu(Arm9Bus(nds: n), ARM9_CYCLES_PER_INSTR)
  n.arm7 = new_arm_cpu(Arm7Bus(nds: n), ARM7_CYCLES_PER_INSTR)
  n.cp15.reset()
  n.direct_boot()
  n.sched.schedule(HBLANK_CYCLES, evHBlank)
  n.sched.schedule(LINE_CYCLES, evLineEnd)
  n.sched.schedule(n.spu.next_tick, evSpuSample)
  n

proc load_nds*(rom_path: string; bios_dir = ""): NDS =
  ## Load a ROM; BIOS/firmware come from `bios_dir` (bios9.bin, bios7.bin,
  ## firmware.bin), else $DINGBAT_NDS_BIOS, else none (firmware synthesized;
  ## without BIOS images, SWIs and IRQ vectors hit zeros -- TODO(bios): HLE).
  let dir = if bios_dir.len > 0: bios_dir else: getEnv("DINGBAT_NDS_BIOS")
  new_nds(read_file_bytes(rom_path),
          read_file_bytes(dir / "bios9.bin"), read_file_bytes(dir / "bios7.bin"),
          read_file_bytes(dir / "firmware.bin"))

proc run_until*(n: NDS; target: int64) =
  var ev: NdsEvent
  var at: int64
  while n.sched.now < target:
    var slice_end = min(target, n.sched.next_at())
    let both_halted = n.arm9.halted and n.arm7.halted
    if not both_halted: slice_end = min(slice_end, n.sched.now + SLICE)
    let start = n.sched.now
    if n.arm9.cycles < slice_end: n.arm9.run(slice_end)
    n.sched.now = start
    if n.arm7.cycles < slice_end: n.arm7.run(slice_end)
    n.sched.now = slice_end
    while n.sched.pop_due(ev, at):
      n.dispatch(ev)

proc run_frame*(n: NDS) =
  ## Run to the start of the next V-blank (line 192).
  n.frame_done = false
  let limit = n.sched.now + 2 * FRAME_CYCLES
  while not n.frame_done and n.sched.now < limit:
    n.run_until(min(limit, n.sched.now + LINE_CYCLES))

proc set_button*(n: NDS; b: NdsButton; pressed: bool) =
  if pressed: n.input.held.incl(b) else: n.input.held.excl(b)
  n.input.check_keypad_irq(n.input.keycnt9, n.irq9)
  n.input.check_keypad_irq(n.input.keycnt7, n.irq7)

proc set_touch*(n: NDS; x, y: int; down: bool) =
  n.input.touching = down
  n.input.touch_x = clamp(x, 0, 255)
  n.input.touch_y = clamp(y, 0, 191)

proc bgr555_to_rgba*(c: uint16): uint32 {.inline.} =
  ## Little-endian RGBA8888 (R in the low byte), alpha opaque.
  let r = uint32(c and 0x1F)
  let g = uint32((c shr 5) and 0x1F)
  let b = uint32((c shr 10) and 0x1F)
  ((r shl 3) or (r shr 2)) or (((g shl 3) or (g shr 2)) shl 8) or
    (((b shl 3) or (b shr 2)) shl 16) or 0xFF00_0000'u32
