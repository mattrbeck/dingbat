## The Nintendo DS: two CPUs on one timeline, their two bus maps, the shared
## devices, direct boot and the frame loop. Subsystems live in their own
## modules (arm/, mem/, gpu/, gpu3d/, io/); this module wires them together.
## The bus maps are in bus9.nim / bus7.nim and the boot path in boot.nim,
## included here so they see the NDS type. docs/nds/spec.md is the map.

import std/[os, strutils, sequtils]
import arm/[cpu, cp15]
import sched, timing
import mem/vram
import gpu/[gpu, engine2d]
import gpu3d/gpu3d
import io/[irq, timers, ipc, divsqrt, dma, input, spi, cart, spu, rtc, wifi, slot2, mic]
import hle_bios

export cpu, sched, gpu, engine2d, input, vram, cart, spu, slot2

# No proc here raises on purpose; `quirky` drops the error-flag test
# after every call (docs/nds/perf.md, "Error-flag checks").
{.push quirky: on.}

const
  DTLB_SIZE* = 256              ## ARM9 data TLB entries per direction (direct-mapped)
  DT_DTCM* = 0'u32              ## DtlbEntry.kind: DTCM
  DT_MAIN* = 1'u32              ## main RAM through the data cache
  DT_UNC* = 2'u32               ## main RAM past it (loads: nothing apart in the page)
  DT_UNC_BUF* = 3'u32           ## the same, stores write-buffered
  DTLB_LOG = 32                 ## fills remembered for a cheap `dtlb_off`

type
  NdsBoot* = enum
    nbDirect      ## load the card's binaries and start them (boot.nim)
    nbFirmware    ## run the real BIOSes and firmware from power-on

  Arm9Bus* = object
    nds* {.cursor.}: NDS
  Arm7Bus* = object
    nds* {.cursor.}: NDS
  Dma9Bus* = object
    ## The ARM9 DMA's view of the bus (io/dma.nim): the CPU's accesses
    ## without the data TLB (bus9.nim), TCMs invisible (`dma_access`)
    nds* {.cursor.}: NDS

  DtlbEntry* = object
    ## One ARM9 data TLB entry (bus9.nim `dtlb_fill9`): a 4 KB page whose
    ## accesses need no region decode
    tag*: uint32                ## the page (address shr 12), or NO_PAGE
    kind*: uint32               ## DT_DTCM, DT_MAIN, DT_UNC, DT_UNC_BUF
    base*: ptr UncheckedArray[uint8]  ## the page's bytes on the host

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
    pu_ok*: array[3, uint32]    ## protection unit: last page allowed per
                                ## fetch / read / write (bus9.nim)
    wait9*, wait7*: int64       ## bus cycles charged to the running instruction
    last_fetch9*, last_data9*: uint32  ## sequential-access tracking
    last_pc9*: uint32           ## the ARM9's last opcode address (branch check)
    last_fetch7*, last_data7*: uint32
    # sequential code fetch fast paths (bus9.nim / bus7.nim fetch32, fetch16);
    # derived from the state above, not saved (`fetch_paths_off`)
    fline9*: uint32             ## ARM9: the 32-byte line (address shr 5) whose
                                ## sequential fetches read `fptr9` at no cost, or NO_PAGE
    fptr9*: ptr UncheckedArray[uint8]
    fitcm9*: bool               ## that line is ITCM (else an instruction-cache line)
    fpage7*: uint32             ## ARM7: the 4 KB page (address shr 12) whose
                                ## sequential fetches read `fptr7`, or NO_PAGE
    fptr7*: ptr UncheckedArray[uint8]
    fseq7*: array[2, int64]     ## and what one costs there: 16-bit, 32-bit
    fjump7*: array[2, int64]    ## and a jump to an opcode there (with the refill)
    # ARM9 data TLB (bus9.nim read32 .. write32): pages whose loads / stores
    # take a short path; derived, not saved (`dtlb_off`)
    rtlb9*, wtlb9*: array[DTLB_SIZE, DtlbEntry]
    dtlb_log*, dtlb_dlog*: array[DTLB_LOG, uint16]  ## entries filled since
                                ## the last drop (bit 15: a store entry), so a
                                ## drop clears only those (the BIOS toggles the
                                ## PU thousands of times a frame in "The
                                ## Strongest Demo"); dlog: those whose kind the
                                ## data cache's enable decides
    dtlb_logged*, dtlb_dlogged*: int  ## how many; more than DTLB_LOG: all
    mmem_armed*: array[4, bool] ## DMA mode 4 channels running this frame
    frame_done*: bool
    sleeping*: bool             ## ARM7 HALTCNT sleep: every clock but the RTC's stopped
    line_start*: int64          ## master cycle the current line began
    unmapped_log*: int          ## first few unmapped accesses are logged
    unmapped_count*: int        ## all of them (tools/ndssweep.nim)
    idle_epoch*: uint64         ## bumped by anything a polling loop could see
                                ## change (arm/cpu.nim loop_edge; not saved)
    idle_epoch9*, idle_epoch7*: uint64  ## the same for what only that CPU
                                ## sees: its TCMs or WRAM, its devices' reads
    ev_epoch*: uint64           ## bumped by every event and `run_until` call:
                                ## only loops that read a device see it
    dev9*, dev7*: bool          ## that CPU read a device (I/O, VRAM, palette,
                                ## OAM, the GBA slot) since its loop took ev_epoch
    # long slices (`run_until`, `slice_cut`); not machine state (not saved)
    long_on*: bool              ## enabled (DINGBAT_NDS_NO_SKIP=1 clears it)
    long_slice: bool            ## a CPU is running one: the other is halted
    long_h9: bool               ## the halted one is the ARM9
    slice_from: int64           ## where its SLICE grid starts
    long_next: int64            ## the next event when it began
    cut_at: int64               ## the end of the step it was cut in (or high)
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
  NO_PAGE = 0xFFFF_FFFF'u32     ## pu_ok: nothing remembered

proc note_unmapped(n: NDS; who: string; a: uint32; write: bool) =
  inc n.unmapped_count
  inc n.idle_epoch9; inc n.idle_epoch7   # the count changes (rare: either CPU)
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
  # GPIO, RTC: values that change on their own; the other CPU reads zeros
  if is9: inc n.idle_epoch9 else: inc n.idle_epoch7
  if is9: n.arm9.attn = true else: n.arm7.attn = true   # the slot's IRQ (arm/cpu.nim run)
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
  if is9: n.arm9.attn = true else: n.arm7.attn = true   # the slot's IRQ (arm/cpu.nim run)
  let s {.cursor.} = n.slot2
  if a >= 0x0A00_0000'u32:
    let b = when width == 8: uint8(v) else: uint8(v shr (8 * (a and (width div 8 - 1))))
    s.ram_write8(a, b)
  else:
    when width == 32:
      s.rom_write(a and not 3'u32, v and 0xFFFF, 16)
      s.rom_write((a and not 3'u32) + 2, v shr 16, 16)
    else: s.rom_write(a, v, width)

proc dtlb_clear(n: NDS; log: var array[DTLB_LOG, uint16]; logged: var int) {.inline.} =
  for k in 0 ..< min(logged, DTLB_LOG):
    let i = int(log[k] and 0x7FFF)
    if (log[k] and 0x8000) != 0: n.wtlb9[i].tag = NO_PAGE
    else: n.rtlb9[i].tag = NO_PAGE
  logged = 0

proc dtlb_off*(n: NDS) =
  ## The ARM9 data TLB starts over (bus9.nim dtlb_fill9): a CP15 write that
  ## changes the TCMs or cachability, WRAMCNT, a state load. Only the
  ## entries filled since need clearing (`dtlb_log`, `dtlb_dlog`).
  if n.dtlb_logged > DTLB_LOG or n.dtlb_dlogged > DTLB_LOG:
    for i in 0 ..< DTLB_SIZE:
      n.rtlb9[i].tag = NO_PAGE
      n.wtlb9[i].tag = NO_PAGE
    n.dtlb_logged = 0
    n.dtlb_dlogged = 0
  else:
    n.dtlb_clear(n.dtlb_log, n.dtlb_logged)
    n.dtlb_clear(n.dtlb_dlog, n.dtlb_dlogged)

proc dtlb_dc_switched*(n: NDS) =
  ## The data cache was switched on or off (control bit 2, or the
  ## protection unit's bit 0): the entries that depend on it go -- cached
  ## main RAM, and uncached pages a region makes cachable (`dtlb_dlog`);
  ## DTCM and pages no region caches stay (a BIOS that toggles the PU in a
  ## loop keeps them: "The Strongest Demo").
  if n.dtlb_dlogged > DTLB_LOG: n.dtlb_off()
  else: n.dtlb_clear(n.dtlb_dlog, n.dtlb_dlogged)

proc fetch_paths_off*(n: NDS) =
  ## Both CPUs' sequential fetch fast paths start over (bus9.nim fetch32,
  ## bus7.nim fetch32), and the ARM9 data TLB: a CP15 write, WRAMCNT, a
  ## state load.
  n.fline9 = NO_PAGE
  n.fpage7 = NO_PAGE
  n.dtlb_off()

proc page_apart_now(n: NDS; p: int) {.inline.} =
  ## Main RAM page p is about to hold a memory side apart from what the CPU
  ## reads, or a kept instruction-cache line: code there is read the slow
  ## way, and so are uncached loads (the data TLB's DT_UNC entries; every
  ## mirror of the page has the same TLB index).
  if (n.fline9 shr 19) == 2 and int((n.fline9 shr 7) and 0x3FF) == p: n.fline9 = NO_PAGE
  if (n.fpage7 shr 12) == 2 and int(n.fpage7 and 0x3FF) == p: n.fpage7 = NO_PAGE
  let e = addr n.rtlb9[p and (DTLB_SIZE - 1)]
  if (e.tag shr 12) == 2 and int(e.tag and 0x3FF) == p: e.tag = NO_PAGE

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

proc gx_dma(n: NDS) =
  ## ARM9 DMA mode 7: bursts into the geometry FIFO while it is less than
  ## half full; at most one block per channel per call (a repeating channel
  ## goes on at the next request).
  let bus = Dma9Bus(nds: n)
  for i in 0..3:
    var left = n.dma9.ch[i].cur_count
    while left > 0 and n.dma9.ch[i].enabled and n.dma9.timing(i) == dtGxFifo and
          n.gpu3d.fifo_wants_dma():
      let units = min(left, GX_DMA_BURST)
      n.dma9.transfer_units(bus, i, units)
      left -= units

proc gx_service(n: NDS; appended = false) =
  ## After anything that moves the geometry FIFO: run the engine up to now,
  ## raise the level-triggered FIFO IRQ, let DMA mode 7 refill it, and book
  ## evGxFifo for when the FIFO next drops below half (DMA, IRQ mode 1) or
  ## empties (IRQ mode 2). With nothing listening the engine just runs
  ## lazily. `appended`: only writes happened since the last booking, which
  ## can only push the crossing later, so a booked wake-up stands.
  let g = n.gpu3d
  let mode = g.fifo_irq_mode
  let want_dma = n.dma9.waiting(dtGxFifo)
  if mode == 0 and not want_dma: return
  if appended and n.sched.is_scheduled(evGxFifo): return
  g.catch_up(n.sched.now)
  g.update_irq()
  if want_dma: n.gx_dma()
  var at = high(int64)
  if want_dma or mode == 1: at = g.wake_at(128)
  if mode == 2: at = min(at, g.wake_at(1))
  if at == high(int64): n.sched.cancel(evGxFifo)
  else: n.sched.schedule(max(at, n.sched.now + 1), evGxFifo)

proc mmem_request(ctx: pointer): bool {.nimcall.} =
  ## ARM9 DMA mode 4: the main-memory display FIFO has room for 4 words;
  ## the first channel armed for this frame moves one block (its count:
  ## GBATEK sets it to 4, larger blocks overflow the FIFO and the rest is
  ## dropped). A channel enabled mid-frame waits for the next frame
  ## ("Transfer starts at next frame", GBATEK).
  let n = cast[NDS](ctx)
  for i in 0..3:
    if n.mmem_armed[i] and n.dma9.ch[i].enabled and n.dma9.timing(i) == dtMainMemDisplay:
      n.dma9.transfer_units(Dma9Bus(nds: n), i, n.dma9.ch[i].cur_count)
      return true
  false

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
    n.dma9.trigger(Dma9Bus(nds: n), dtHBlank)
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
  # the next line 192, for a write stalled behind a pending swap
  let to_vblank = (VISIBLE_LINES - g.vcount + LINES) mod LINES
  n.gpu3d.next_vblank = n.line_start + int64(if to_vblank == 0: LINES else: to_vblank) * LINE_CYCLES
  g.start_line()
  if g.vcount == VISIBLE_LINES:
    g.in_vblank = true
    inc g.frame_count
    n.frame_done = true
    n.dispstat_irqs(g.stat9, n.irq9, irqVBlank)
    n.dispstat_irqs(g.stat7, n.irq7, irqVBlank)
    n.dma9.trigger(Dma9Bus(nds: n), dtVBlank)
    n.dma7.trigger(Arm7Bus(nds: n), dtVBlank)
    n.gpu3d.on_vblank()
    n.gx_service()         # the swap releases the FIFO
  elif g.vcount == LINES - 1:
    g.in_vblank = false
  elif g.vcount == 0:
    n.dma9.trigger(Dma9Bus(nds: n), dtDisplayStart)
    for i in 0..3:
      n.mmem_armed[i] = n.dma9.ch[i].enabled and n.dma9.timing(i) == dtMainMemDisplay
  if g.vcount == int(g.stat9.vcount_setting): n.dispstat_irqs(g.stat9, n.irq9, irqVCount)
  if g.vcount == int(g.stat7.vcount_setting): n.dispstat_irqs(g.stat7, n.irq7, irqVCount)
  n.sched.schedule(n.line_start + HBLANK_CYCLES, evHBlank)
  n.sched.schedule(n.line_start + LINE_CYCLES, evLineEnd)

proc dispatch(n: NDS; ev: NdsEvent) =
  inc n.ev_epoch              # devices; memory changes bump idle_epoch (arm/cpu.nim)
  case ev
  of evHBlank: n.on_hblank()
  of evLineEnd: n.on_line_end()
  of evTimer9_0 .. evTimer9_3: n.timers9.on_event(ev)
  of evTimer7_0 .. evTimer7_3: n.timers7.on_event(ev)
  of evCartDone:
    n.cart.word_ready()
    if n.cart.owner_arm7: n.dma7.trigger(Arm7Bus(nds: n), dtCart)
    else: n.dma9.trigger(Dma9Bus(nds: n), dtCart)
  of evSpuSample:
    n.spu.tick(Arm7Bus(nds: n))
    n.spu.next_tick += SPU_TICK_CYCLES
    n.sched.schedule(n.spu.next_tick, evSpuSample)
  of evGxFifo: n.gx_service()
  of evWifi: n.wifi.on_event()
  of evSpi: n.spi.transfer_end()
  of evRtc: n.rtc.on_event()

# ---------------------------------------------------------------------------
# Construction and the frame loop

{.pop.}   # file reading raises: the caller sees an IOError at once

proc read_file_bytes(path: string): seq[uint8] =
  if path.len == 0 or not fileExists(path): return @[]
  let s = readFile(path)
  result = newSeq[uint8](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc can_firmware_boot*(bios9, bios7, firmware: seq[uint8]): bool =
  ## A firmware boot runs the real BIOSes and the real firmware: all three
  ## dumps are needed (the synthesized firmware has no boot code).
  bios9.len >= BIOS9_SIZE and bios7.len >= BIOS7_SIZE and firmware.len >= 256 * 1024

proc new_nds*(rom: sink seq[uint8]; bios9, bios7, firmware: seq[uint8];
              force_hle = false; boot = nbDirect): NDS =
  ## A missing BIOS dump (or `force_hle`) gets the HLE BIOS for that CPU.
  ## `boot = nbFirmware` starts from power-on in the real BIOS + firmware
  ## (an empty `rom` = no card: the firmware menu); without all three dumps
  ## it says so on stderr and direct-boots instead.
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
  n.gpu3d.sched = n.sched
  n.gpu3d.next_vblank = int64(VISIBLE_LINES) * LINE_CYCLES
  n.gpu.gpu3d = n.gpu3d
  n.gpu.mmem_req = mmem_request
  n.gpu.mmem_ctx = cast[pointer](n)
  n.timers9 = Timers(sched: n.sched, irq: n.irq9, first_event: evTimer9_0)
  n.timers7 = Timers(sched: n.sched, irq: n.irq7, first_event: evTimer7_0)
  n.dma9 = new_dma(true, n.irq9)
  n.dma7 = new_dma(false, n.irq7)
  n.ipc = new_ipc(n.irq9, n.irq7)
  n.divsqrt = new_divsqrt(n.sched)
  n.spi = new_spi(if firmware.len > 0: firmware else: synth_firmware(), n.irq7, n.input)
  n.spi.set_sched(n.sched)
  n.cart = new_cart(rom, n.irq9, n.irq7, n.sched)
  n.cart.set_key1_table(key1_table_from_bios7(bios7))
  n.spu = new_spu()
  n.rtc = new_rtc()
  n.rtc.sched = n.sched
  n.rtc.irq = n.irq7
  n.wifi = new_wifi(n.sched, n.irq7)
  n.slot2 = new_slot2()
  n.arm9 = new_arm_cpu(Arm9Bus(nds: n), ARM9_CYCLES_PER_INSTR)
  n.arm7 = new_arm_cpu(Arm7Bus(nds: n), ARM7_CYCLES_PER_INSTR)
  # DINGBAT_NDS_NO_SKIP=1: execute every idle loop pass and draw every 3D
  # frame, for checking that skipping changes nothing (docs/nds/perf.md)
  let skip = getEnv("DINGBAT_NDS_NO_SKIP") != "1"
  n.arm9.wl_on = skip
  n.arm7.wl_on = skip
  n.gpu3d.reuse_on = skip
  n.gpu.engine_a.lc_on = skip
  n.gpu.engine_b.lc_on = skip
  n.long_on = skip
  n.cp15.reset()
  n.tm.init_timing()
  n.tm.update_regions(n.cp15)
  n.pu_ok = [NO_PAGE, NO_PAGE, NO_PAGE]
  n.last_fetch9 = NO_ADDR; n.last_data9 = NO_ADDR; n.last_pc9 = NO_ADDR
  n.dtlb_logged = DTLB_LOG + 1         # every entry (tags start at 0, a page)
  n.dtlb_dlogged = 0
  n.fetch_paths_off()
  n.last_fetch7 = NO_ADDR; n.last_data7 = NO_ADDR
  if boot == nbFirmware and not force_hle and can_firmware_boot(bios9, bios7, firmware):
    n.firmware_boot()
  else:
    if boot == nbFirmware:
      stderr.writeLine("nds: firmware boot needs bios9.bin, bios7.bin and firmware.bin " &
                       "dumps (and no forced HLE); direct boot instead")
    n.direct_boot()
  n.sched.schedule(HBLANK_CYCLES, evHBlank)
  n.sched.schedule(LINE_CYCLES, evLineEnd)
  n.sched.schedule(n.spu.next_tick, evSpuSample)
  n

proc load_nds*(rom_path: string; bios_dir = ""; boot = nbDirect): NDS =
  ## Load a ROM; BIOS/firmware come from `bios_dir` (bios9.bin, bios7.bin,
  ## firmware.bin), else $DINGBAT_NDS_BIOS, else none (firmware synthesized,
  ## HLE BIOS). DINGBAT_NDS_HLE=1 forces the HLE BIOS even with dumps.
  ## An empty `rom_path` is an empty card slot.
  let dir = if bios_dir.len > 0: bios_dir else: getEnv("DINGBAT_NDS_BIOS")
  new_nds(read_file_bytes(rom_path),
          read_file_bytes(dir / "bios9.bin"), read_file_bytes(dir / "bios7.bin"),
          read_file_bytes(dir / "firmware.bin"),
          force_hle = getEnv("DINGBAT_NDS_HLE") == "1", boot = boot)

{.push quirky: on.}

# ---------------------------------------------------------------------------
# Sleep (GBATEK "DS Power Control", HALTCNT; "BIOS Halt Functions", Stop/Sleep)

const SLEEP_WAKE = (1'u32 shl ord(irqSerial)) or (1'u32 shl ord(irqKeypad)) or
                   (1'u32 shl ord(irqGbaSlot)) or (1'u32 shl ord(irqLid))
  ## What ends sleep, as far as IE allows: the GBA's Stop list (keypad, game
  ## pak, general-purpose SIO, which carries the RTC) plus the hinge.

proc wake_pending(n: NDS): bool {.inline.} =
  (n.irq7.ie and n.irq7.iff and SLEEP_WAKE) != 0

proc asleep*(n: NDS): bool {.inline.} = n.sleeping or n.spi.power_off

proc powered_off*(n: NDS): bool {.inline.} =
  ## The power manager's register 0 bit 6 was written ("DS System Power:
  ## Shut Down", GBATEK "DS Power Management Device"): the machine is off
  ## and stays off (only a new machine turns it on again).
  n.spi.power_off

proc show_power_off(n: NDS) =
  ## Powered off, the LCDs are unpowered: both screens black (the reference
  ## runs go black when a program shuts down: docs/oracles.md). Cheap
  ## enough to repeat on every call while off, which also covers a state
  ## loaded in that condition.
  for i in 0 ..< 256 * 192:
    n.gpu.top[i] = 0
    n.gpu.bottom[i] = 0

proc wake_from_sleep(n: NDS) =
  if n.sleeping and n.wake_pending(): n.sleeping = false

proc sleep_for(n: NDS; cycles: int64) =
  ## Asleep, both CPUs, video, sound, timers and DMA stand still (Assumed
  ## for the ARM9 and video: GBATEK says "most of the hardware ... paused"),
  ## so the master clock does not move; the RTC's crystal runs on and an
  ## alarm can end the sleep. Powered off (power manager), nothing ends it.
  if n.spi.power_off: return
  n.wake_from_sleep()
  if not n.sleeping: return
  n.rtc.sleep_advance(cycles, proc(): bool = n.wake_pending())
  n.wake_from_sleep()

proc slice_cut(n: NDS): int64 {.noinline.} =
  ## In a long slice (`run_until`), after anything the running CPU does
  ## that the SLICE-step loop would have acted on at the end of the step it
  ## happened in -- the halted CPU's interrupt arriving, an event booked or
  ## moved, the ARM7 going to sleep (or the machine off) -- the run ends at
  ## the end of that step: the next point on the SLICE grid from where the
  ## long slice began after the access (`sched.now`: the clock of the
  ## access that did it). Called when `attn` is set (arm/cpu.nim run): every
  ## such action is an I/O access, a SWI or a CP15 write.
  let wakes = if n.long_h9: irq_wake(Arm9Bus(nds: n)) else: irq_wake(Arm7Bus(nds: n))
  if wakes or n.sched.next_at() != n.long_next or n.asleep():
    let c = max(n.sched.now, n.slice_from)
    n.cut_at = min(n.cut_at, n.slice_from + SLICE * ((c - n.slice_from) div SLICE + 1))
  n.cut_at

proc slice_cut*(b: Arm9Bus): int64 {.inline.} =
  if b.nds.long_slice: b.nds.slice_cut() else: high(int64)
proc slice_cut*(b: Arm7Bus): int64 {.inline.} =
  if b.nds.long_slice: b.nds.slice_cut() else: high(int64)

proc run_long(n: NDS; slice_end: int64; h9: bool) =
  ## One CPU halted with no interrupt to wake it, the other running: the
  ## running one goes straight to `slice_end` (the next event) instead of in
  ## SLICE steps, unless it does something the step loop would have acted
  ## on (`slice_cut`); then it stops where that step ends, and the halted
  ## one is left where the steps would have left it. The step loop ran the
  ## ARM9 first in each step: a halted ARM7 woken by the ARM9 wakes at the
  ## start of the step the ARM9 woke it in, a halted ARM9 woken by the ARM7
  ## at the end of it (the next step). Between steps nothing else happens
  ## (no event is due), and each CPU's own execution does not depend on
  ## where its run calls end, so the result is the steps' result.
  let start = n.sched.now
  n.long_slice = true
  n.long_h9 = h9
  n.slice_from = start
  n.long_next = n.sched.next_at()
  n.cut_at = high(int64)
  var e = slice_end
  if h9:
    if n.arm7.cycles < slice_end: n.arm7.run(slice_end)
    discard n.slice_cut()       # the last access (its `attn` is not looked at
    n.long_slice = false        # when it took the clock past the end)
    e = min(e, n.cut_at)
    n.arm9.cycles = max(n.arm9.cycles, e)   # halted to the end of the last step
  else:
    if n.arm9.cycles < slice_end: n.arm9.run(slice_end)
    discard n.slice_cut()
    n.long_slice = false
    if n.cut_at != high(int64):
      # the ARM7 sat out the steps before the one it was cut in, then gets it
      e = min(e, n.cut_at)
      n.arm7.cycles = max(n.arm7.cycles, n.cut_at - SLICE)
      n.sched.now = n.cut_at - SLICE
      if n.arm7.cycles < e: n.arm7.run(e)
    else:
      n.arm7.cycles = max(n.arm7.cycles, slice_end)
  n.sched.now = e

proc quiet(n: NDS): bool {.inline.} =
  ## Neither CPU can change anything the other or the devices see before
  ## the next event: each is halted with no interrupt to wake it, or spins
  ## in a loop proven to be a no-op (arm/cpu.nim loop_edge) with nothing
  ## touched since and no interrupt it will take (an event that leaves the
  ## loop proven may raise one: the handler then runs, which is work).
  ## Interleaving them in SLICE steps until then would give the same result
  ## as running each straight to the event.
  template spins(c: untyped; bus: untyped): bool =
    c.idle_now() and not (irq_line(bus) and (c.cpsr and FLAG_I) == 0)
  (spins(n.arm9, Arm9Bus(nds: n)) or (n.arm9.halted and not irq_wake(Arm9Bus(nds: n)))) and
    (spins(n.arm7, Arm7Bus(nds: n)) or (n.arm7.halted and not irq_wake(Arm7Bus(nds: n))))

proc run_until*(n: NDS; target: int64) =
  ## Asleep, `target - now` is spent as sleep and the master clock stays.
  var ev: NdsEvent
  var at: int64
  inc n.ev_epoch              # the frontend may have changed keys, touch, ...
  if n.asleep():
    n.sleep_for(max(0'i64, target - n.sched.now))
    if n.spi.power_off: n.show_power_off()
    return
  while n.sched.now < target:
    if n.asleep():            # the ARM7 went to sleep (or off) in the last slice
      if n.spi.power_off: n.show_power_off()
      return
    var slice_end = min(target, n.sched.next_at())
    let both_halted = n.arm9.halted and n.arm7.halted
    if not both_halted and not n.quiet():
      let h9 = n.arm9.halted and not irq_wake(Arm9Bus(nds: n))
      let h7 = n.arm7.halted and not irq_wake(Arm7Bus(nds: n))
      if (h9 or h7) and n.long_on and slice_end - n.sched.now > SLICE and
         n.arm9.trace == 0 and n.arm7.trace == 0:
        n.run_long(slice_end, h9)
        while n.sched.pop_due(ev, at):
          n.dispatch(ev)
        continue
      slice_end = min(slice_end, n.sched.now + SLICE)
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
  if n.asleep():
    # a frame's worth of sleep; the screens show what they last showed
    n.sleep_for(FRAME_CYCLES)
    if n.spi.power_off: n.show_power_off()
    if n.asleep(): return
  let limit = n.sched.now + 2 * FRAME_CYCLES
  while not n.frame_done and n.sched.now < limit:
    n.run_until(min(limit, n.sched.now + LINE_CYCLES))
    if n.asleep():
      if n.spi.power_off: n.show_power_off()
      break
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

proc set_lid*(n: NDS; closed: bool) =
  ## Close or open the hinge (EXTKEYIN bit 7; opening raises IF.22).
  n.input.set_lid(closed, n.irq7)

proc push_mic*(n: NDS; samples: openArray[int16]; rate: int) =
  ## Queue microphone input (mono, `rate` Hz) behind what is queued; the
  ## ARM7 reads it through the TSC's AUX channel (io/mic.nim).
  n.spi.mic.push(samples, rate)

proc set_battery_low*(n: NDS; low: bool) = n.spi.battery_low = low
proc set_external_power*(n: NDS; on: bool) = n.spi.ext_power = on

proc backlight*(n: NDS; top: bool): bool =
  ## Whether the power manager has that screen's backlight on.
  n.spi.backlight(top)

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

{.pop.}
