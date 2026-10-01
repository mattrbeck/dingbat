## The Nintendo DS: two CPUs on one timeline, their two bus maps, the shared
## devices, direct boot and the frame loop. Subsystems live in their own
## modules (arm/, mem/, gpu/, gpu3d/, io/); this module wires them together.
## The bus maps are in bus9.nim / bus7.nim and the boot path in boot.nim,
## included here so they see the NDS type. docs/nds/spec.md is the map.

import std/[os, strutils]
import arm/[cpu, cp15]
import sched, timing
import mem/vram
import gpu/[gpu, engine2d]
import gpu3d/gpu3d
import io/[irq, timers, ipc, divsqrt, dma, input, spi, cart, spu, rtc, wifi, slot2]
import hle_bios

export cpu, sched, gpu, engine2d, input, vram, cart, spu, slot2

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
    hle_bios9*, hle_bios7*: bool  ## synthesized BIOS + HLE SWIs (hle_bios.nim)
    wramcnt*: uint8
    exmemcnt*: uint16           ## ARM9 EXMEMCNT; bits 7-15 are shared
    exmem7_lo*: uint16          ## ARM7 EXMEMSTAT bits 0-6 (its own copy)
    slot9_t*, slot7_t*: SlotTiming  ## GBA-slot access times from each CPU's bits 0-4
    slot2*: Slot2               ## what is in the GBA slot (io/slot2.nim)
    vcount_write*: int          ## VCOUNT written in lines 202-212, else -1
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
    tm*: MemTiming              ## ARM9 caches + cachability (timing.nim)
    wait9*, wait7*: int64       ## bus cycles charged to the running instruction
    last_fetch9*, last_data9*: uint32  ## sequential-access tracking
    last_fetch7*, last_data7*: uint32
    frame_done*: bool
    line_start*: int64          ## master cycle the current line began
    unmapped_log*: int          ## first few unmapped accesses are logged
    # -d:ndsdebug only (tools/ndsrun.nim flags)
    iolog*: bool                ## log I/O accesses to stderr
    watch*: uint32              ## log writes to this word (0 = off)
    io_last: string
    io_repeat: int

const
  MAIN_RAM_SIZE = 4 * 1024 * 1024
  ARM9_CYCLES_PER_INSTR = 1     ## one ARM9 clock; memory adds the rest (timing.nim)
  ARM7_CYCLES_PER_INSTR = 0     ## all ARM7 time is its fetch + data + internal cycles
  SLICE = 64                    ## max master cycles one CPU runs ahead

proc note_unmapped(n: NDS; who: string; a: uint32; write: bool) =
  if n.unmapped_log < 32:
    inc n.unmapped_log
    stderr.writeLine("nds " & who & ": unmapped " & (if write: "write " else: "read ") &
                     "0x" & toHex(a, 8))

proc log_io(n: NDS; who: string; a, v, mask: uint32; write: bool; pc: uint32) =
  ## -d:ndsdebug: one line per I/O access, repeats folded into a count.
  let line = who & (if write: " W " else: " R ") & toHex(a, 8) & " = " & toHex(v, 8) &
             (if write and mask != 0xFFFF_FFFF'u32: " mask " & toHex(mask, 8) else: "") &
             " pc=" & toHex(pc, 8)
  if line == n.io_last:
    inc n.io_repeat
    return
  if n.io_repeat > 0: stderr.writeLine("  (x" & $(n.io_repeat + 1) & ")")
  n.io_last = line
  n.io_repeat = 0
  stderr.writeLine(line)

template watch_write(n: NDS; who: string; cpu: untyped; a, v: uint32) =
  when defined(ndsdebug):
    if n.watch != 0 and (a and not 3'u32) == n.watch:
      stderr.writeLine(who & " watch W " & toHex(a, 8) & " = " & toHex(v, 8) &
                       " pc=" & toHex(cpu.cur_pc, 8) & " line=" & $n.gpu.vcount)

proc slot2_read(n: NDS; a: uint32; is9: bool; width: static int): uint32 =
  ## The GBA slot (io/slot2.nim) as one CPU sees it: the CPU that EXMEMCNT.7
  ## gives it to reads the device or open bus, the other reads zeros
  ## (GBATEK "GBA Slot"). The ROM region is a 16-bit bus (a word is two
  ## halfword accesses), the SRAM region an 8-bit one, whose byte a 16/32-bit
  ## load reads repeated (as on the GBA: Assumed for the DS).
  let owner9 = (n.exmemcnt and 0x80) == 0
  if owner9 != is9: return 0
  let s {.cursor.} = n.slot2
  if a >= 0x0A00_0000'u32:
    let b = s.ram_read8(a)
    result = when width == 32: b * 0x0101_0101'u32 elif width == 16: b * 0x0101'u32 else: b
  else:
    let rom_n = int(if is9: n.slot9_t.rom_n else: n.slot7_t.rom_n)
    result =
      when width == 32:
        s.rom_read16(a and not 3'u32, rom_n) or (s.rom_read16((a and not 3'u32) + 2, rom_n) shl 16)
      elif width == 16: s.rom_read16(a and not 1'u32, rom_n)
      else: (s.rom_read16(a and not 1'u32, rom_n) shr ((a and 1) * 8)) and 0xFF
  when defined(ndsdebug):
    if n.iolog:
      n.log_io(if is9: "9" else: "7", a, result, 0xFFFF_FFFF'u32, false,
               if is9: n.arm9.cur_pc else: n.arm7.cur_pc)

proc slot2_write(n: NDS; a: uint32; v: uint32; is9: bool; width: static int) =
  ## Stores from the CPU that does not own the slot go nowhere (Assumed: its
  ## reads see zeros, GBATEK). A store to the 8-bit SRAM bus keeps the byte
  ## its address selects (GBA rule, Assumed for the DS).
  let owner9 = (n.exmemcnt and 0x80) == 0
  when defined(ndsdebug):
    if n.iolog:
      n.log_io(if is9: "9" else: "7", a, v, 0xFFFF_FFFF'u32, true,
               if is9: n.arm9.cur_pc else: n.arm7.cur_pc)
  if owner9 != is9: return
  let s {.cursor.} = n.slot2
  if a >= 0x0A00_0000'u32:
    let b = when width == 8: uint8(v) else: uint8(v shr (8 * (a and (width div 8 - 1))))
    s.ram_write8(a, b)
  else:
    when width == 32:
      s.rom_write(a and not 3'u32, v and 0xFFFF, 16)
      s.rom_write((a and not 3'u32) + 2, v shr 16, 16)
    else: s.rom_write(a, v, width)

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
# Burst-mode DMA

const
  GX_DMA_BURST = 112          ## words per geometry-FIFO request (GBATEK)
  MMEM_LINE_WORDS = 128       ## one line of main-memory display, 256 px

proc gx_dma(n: NDS) =
  ## ARM9 DMA mode 7: bursts into the geometry FIFO while it is less than
  ## half full; at most one block per channel per call (a repeating channel
  ## goes on at the next request).
  let bus = Arm9Bus(nds: n)
  for i in 0..3:
    var left = n.dma9.ch[i].cur_count
    while left > 0 and n.dma9.ch[i].enabled and n.dma9.timing(i) == dtGxFifo and
          n.gpu3d.fifo_wants_dma():
      let units = min(left, GX_DMA_BURST)
      n.dma9.transfer_units(bus, i, units)
      left -= units

proc mmem_dma(n: NDS) =
  ## ARM9 DMA mode 4: feed one line of main-memory display (engine A
  ## display mode 3) through the display FIFO, a channel block at a time.
  if n.gpu.engine_a.display_mode() != 3: return
  let bus = Arm9Bus(nds: n)
  for i in 0..3:
    var left = uint32(MMEM_LINE_WORDS)
    while left > 0 and n.dma9.ch[i].enabled and n.dma9.timing(i) == dtMainMemDisplay:
      let units = min(left, n.dma9.ch[i].cur_count)
      n.dma9.transfer_units(bus, i, units)
      left -= units

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
  if n.vcount_write >= 0:
    g.vcount = n.vcount_write
    n.vcount_write = -1
  else:
    inc g.vcount
    if g.vcount == LINES: g.vcount = 0
  n.line_start = n.sched.now
  g.start_line()
  if g.vcount == VISIBLE_LINES:
    g.in_vblank = true
    inc g.frame_count
    n.frame_done = true
    n.dispstat_irqs(g.stat9, n.irq9, irqVBlank)
    n.dispstat_irqs(g.stat7, n.irq7, irqVBlank)
    n.dma9.trigger(Arm9Bus(nds: n), dtVBlank)
    n.dma7.trigger(Arm7Bus(nds: n), dtVBlank)
    n.gpu3d.on_vblank()
    n.gx_dma()             # the swap drained the FIFO
  elif g.vcount == LINES - 1:
    g.in_vblank = false
  elif g.vcount == 0:
    n.dma9.trigger(Arm9Bus(nds: n), dtDisplayStart)
  if g.vcount < VISIBLE_LINES: n.mmem_dma()
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
  of evCartDone:
    n.cart.word_ready()
    if n.cart.owner_arm7: n.dma7.trigger(Arm7Bus(nds: n), dtCart)
    else: n.dma9.trigger(Arm9Bus(nds: n), dtCart)
  of evSpuSample:
    n.spu.tick(Arm7Bus(nds: n))
    n.spu.next_tick += SPU_TICK_CYCLES
    n.sched.schedule(n.spu.next_tick, evSpuSample)
  of evGxFifo: discard
  of evWifi: n.wifi.on_event()

# ---------------------------------------------------------------------------
# Construction and the frame loop

proc read_file_bytes(path: string): seq[uint8] =
  if path.len == 0 or not fileExists(path): return @[]
  let s = readFile(path)
  result = newSeq[uint8](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc new_nds*(rom: seq[uint8]; bios9, bios7, firmware: seq[uint8];
              force_hle = false): NDS =
  ## A missing BIOS dump (or `force_hle`) gets the HLE BIOS for that CPU.
  let n = NDS(sched: new_nds_scheduler(), vcount_write: -1)
  n.main_ram = newSeq[uint8](MAIN_RAM_SIZE)
  n.shared_wram = newSeq[uint8](32 * 1024)
  n.arm7_wram = newSeq[uint8](64 * 1024)
  n.itcm = newSeq[uint8](32 * 1024)
  n.dtcm = newSeq[uint8](16 * 1024)
  n.hle_bios9 = force_hle or bios9.len < BIOS9_SIZE
  n.hle_bios7 = force_hle or bios7.len < BIOS7_SIZE
  n.bios9 = if n.hle_bios9: hle_bios9_image() else: bios9
  n.bios7 = if n.hle_bios7: hle_bios7_image() else: bios7
  n.irq9 = IrqCtl()
  n.irq7 = IrqCtl()
  n.input = Input()
  n.gpu = new_gpu()
  n.gpu3d = new_gpu3d(n.gpu.vram, n.irq9)
  n.gpu.gpu3d = n.gpu3d
  n.timers9 = Timers(sched: n.sched, irq: n.irq9, first_event: evTimer9_0)
  n.timers7 = Timers(sched: n.sched, irq: n.irq7, first_event: evTimer7_0)
  n.dma9 = new_dma(true, n.irq9)
  n.dma7 = new_dma(false, n.irq7)
  n.ipc = new_ipc(n.irq9, n.irq7)
  n.divsqrt = new_divsqrt(n.sched)
  n.spi = new_spi(if firmware.len > 0: firmware else: synth_firmware(), n.irq7, n.input)
  n.spi.sched = n.sched
  n.cart = new_cart(rom, n.irq9, n.irq7, n.sched)
  n.spu = new_spu()
  n.rtc = new_rtc()
  n.wifi = new_wifi(n.sched, n.irq7)
  n.slot2 = new_slot2()
  n.arm9 = new_arm_cpu(Arm9Bus(nds: n), ARM9_CYCLES_PER_INSTR)
  n.arm7 = new_arm_cpu(Arm7Bus(nds: n), ARM7_CYCLES_PER_INSTR)
  n.cp15.reset()
  n.tm.init_timing()
  n.tm.update_regions(n.cp15)
  n.last_fetch9 = NO_ADDR; n.last_data9 = NO_ADDR
  n.last_fetch7 = NO_ADDR; n.last_data7 = NO_ADDR
  n.direct_boot()
  n.sched.schedule(HBLANK_CYCLES, evHBlank)
  n.sched.schedule(LINE_CYCLES, evLineEnd)
  n.sched.schedule(n.spu.next_tick, evSpuSample)
  n

proc load_nds*(rom_path: string; bios_dir = ""): NDS =
  ## Load a ROM; BIOS/firmware come from `bios_dir` (bios9.bin, bios7.bin,
  ## firmware.bin), else $DINGBAT_NDS_BIOS, else none (firmware synthesized,
  ## HLE BIOS). DINGBAT_NDS_HLE=1 forces the HLE BIOS even with dumps.
  let dir = if bios_dir.len > 0: bios_dir else: getEnv("DINGBAT_NDS_BIOS")
  new_nds(read_file_bytes(rom_path),
          read_file_bytes(dir / "bios9.bin"), read_file_bytes(dir / "bios7.bin"),
          read_file_bytes(dir / "firmware.bin"),
          force_hle = getEnv("DINGBAT_NDS_HLE") == "1")

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
  n.slot2.end_frame()

proc insert_slot2*(n: NDS; kind: Slot2Kind; rom: seq[uint8] = @[];
                   save: seq[uint8] = @[]) =
  ## Put a device in the GBA slot (`rom`/`save` for s2GbaCart; s2Empty
  ## ejects). Before the first instruction runs this is power-on insertion,
  ## and the boot info the firmware leaves about the slot (0x027FFC30) is
  ## rewritten to match.
  case kind
  of s2Empty: n.slot2.eject()
  of s2GbaCart: n.slot2.insert_gba(rom, save)
  of s2RumblePak: n.slot2.insert_rumble_pak()
  of s2ExpansionPak: n.slot2.insert_expansion_pak()
  if n.arm9.instr_count == 0:
    let info = n.slot2.gba_header_info()
    for i in 0 ..< 12: n.main_ram[0x3FFC30 + i] = info[i]

proc slot2_save*(n: NDS): seq[uint8] =
  ## The slot-2 GBA cart's backup chip contents (empty without one), in the
  ## .sav layout GBA emulators use; clears the dirty flag.
  n.slot2.dirty = false
  n.slot2.save

proc slot2_rumble*(n: NDS): int =
  ## Rumble strength 0..255 for the frontend (Rumble Pak or a GBA cart's
  ## GPIO motor); 0 with nothing rumbling.
  n.slot2.rumble()

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
