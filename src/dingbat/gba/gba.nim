# GBA emulator main file
# All types are declared here; implementation files are `include`d.

import std/[options, times, os, strutils, math, sets, tables]
from std/bitops import countLeadingZeroBits, countTrailingZeroBits
import ../common/[util, input, scheduler, emu, resampler, serialize, timestretch, cheats, atomicfile, psg]
when defined(test_harness):
  import ../common/test_output
elif not defined(emscripten):
  import ../common/audio_out
import ../common/lut_macros
import rtc_calendar
export rtc_calendar
import storage_chip
export storage_chip

# Optimised builds (-d:release, -d:danger) make the core quirky: no call
# tests Nim's error flag afterwards (with goto exceptions every call does,
# Defects included). Worth 3-4 % on web, ~10 % of host instructions natively.
# Cost: a failed check runs on until a caller outside the core tests the
# flag, so a wild index is a SIGSEGV, not an IndexDefect. Only a loaded state
# can cause one, so the loader range-checks every indexed field (savestate.nim;
# tools/statefuzz.nim, built -d:gba_quirky=false, finds misses). Procs that
# catch, and the file/state loaders, stay `quirky: off` (below and in bus.nim).
const gba_quirky {.booldefine.} = defined(release) or defined(danger)
const QUIRKY_CORE = gba_quirky
when QUIRKY_CORE:
  {.push quirky: on.}

when defined(pftrace):
  # -d:pftrace (off by default): dump ROM-bus activity in each mGBA-suite
  # Timing window (TM0 enable to disable) that holds a DMA grant, to re-derive
  # bus.rom_access_cycles' hand-off predicate. -d:pftrace_all prints every
  # window, flushed at each TM0 read (alyosha timing tests never disable TM0).
  var pft_on*: bool
  var pft_dma*: bool

  var pft_lines*: seq[string]
  proc pft*(s: string) =
    # Bounded: a game can leave TM0 running for whole frames.
    if pft_on and pft_lines.len < 4096: pft_lines.add(s)

when defined(itrace):
  # -d:itrace (off by default): per-instruction trace to stderr from the first
  # PC in [ITRACE_LO, ITRACE_HI] (hex) for ITRACE_N lines, with timer, IRQ and
  # DMA events interleaved.
  var it_lo*, it_hi*: uint32
  var it_left* = -1
  var it_skip* = 0
  var it_on*: bool
  proc it_init*() =
    if it_left == -1:
      it_lo = uint32(parseHexInt(getEnv("ITRACE_LO", "0")))
      it_hi = uint32(parseHexInt(getEnv("ITRACE_HI", "0")))
      it_left = parseInt(getEnv("ITRACE_N", "400"))
      it_skip = parseInt(getEnv("ITRACE_SKIP", "0"))
  proc itl*(s: string) =
    if it_on and it_left > 0:
      dec it_left
      stderr.writeLine(s)

when defined(bgtrace):
  var bgtrace_n*: int

when defined(dmacount):
  # -d:dmacount (off by default): per-frame H-blank DMA grant census; expect
  # 160 per armed channel. A miscount drifts a repeating channel's source for
  # the rest of the frame (DKC2's per-line BG1 scroll table).
  var hdma_grants*: array[4, int]
  var hdma_frame*: int

include reg

# Renderer contention maps (contention.nim): 32-bit words covering a line's
# 1232 dots and the first 48 of the next.
const CONT_WORDS* = 40
# -d:CONTENTION=false: no renderer contention (every access as in blank)
const CONTENTION* {.booldefine.} = true

const WL_VERDICT_SLOTS* = 256   # judge_loop's direct-mapped verdicts
const DYN_REST_SLOTS* = 256   # dyn_loop's direct-mapped rest (waitloop.nim)

type
  Pipeline* = object
    buffer*: array[2, uint32]
    pos*:    int
    size*:   int


  StorageObj* = object of RootObj
    memory*:    seq[byte]
    save_path*: string
    dirty*:     bool
    # Why the last battery write failed ("" once one lands). save_error_new:
    # not yet shown; the frontend clears it, write_save sets it again only
    # after a success in between.
    save_error*:     string
    save_error_new*: bool
    # Battery-file RTC trailer (rtc_calendar.nim). rtc_cart: the ROM has the
    # RTC library (storage.nim). `trailer`: the 16 bytes after the chip data,
    # if present. `rtc` (RTC carts) supplies a fresh trailer on every write.
    rtc_cart*:    bool
    has_trailer*: bool
    trailer*:     array[16, byte]
    rtc* {.cursor.}: RTC
    # EEPROM only: the loaded file's bytes from 0x200 up to 0x2000. A 4 Kbit
    # chip uses 0x200, but 8 KB files are common; write_save puts these back
    # so playing never shortens such a file.
    eeprom_file_tail*: seq[byte]
    # Chips the ROM's library strings leave open (storage_chip.nim
    # storage_candidates); empty when they name one. Kept after the first
    # access settles the chip, so states from before it still load.
    candidates*: set[StorageType]
    # No backup library named (storage_chip.nim names_no_save_library): the
    # first save access chooses outright.
    no_save_library*: bool
  Storage* = ref StorageObj

  SRAM* = ref object of StorageObj

  NoBackup* = ref object of StorageObj   # empty memory, no .sav

  # Chip not yet chosen by the game's save accesses (storage/pending.nim): no
  # battery file, SRAM region reads as no chip. Replaces itself in gba.storage.
  PendingStorage* = ref object of StorageObj
    gba_ref* {.cursor.}: GBA
    # SRAM-region reads with no write yet (capped at SRAM_LOAD_READS); -1 once
    # a write came first. In the save state.
    sram_reads*: int
    # Where the EEPROM window starts: 0DFFFF00h on a ROM over 16 MB, whose
    # lower 0x0D addresses are ROM (GBATEK "GBA Cart Backup EEPROM")
    eeprom_floor*: uint32

  Flash* = ref object of StorageObj
    flash_type*: StorageType
    state*:      set[FlashStateFlag]
    bank*:       uint8
    id*:         uint16

  EepromStateFlag* = enum
    esReady, esRead, esReadIgnore, esWrite, esAddress, esWriteFinalBit,
    esLockAddress, esCmd1, esCmd2, esIdentification, esPrepareWrite, esPrepareErase, esSetBank

  EepromSize* = enum
    eeprom4k, eeprom64k

  EepromBuffer* = object
    size*:  int
    value*: uint64

  EEPROM* = ref object of StorageObj
    gba_ref* {.cursor.}: GBA   # non-owning back-ref (the GBA owns storage)
    eeprom_size*:   Option[EepromSize]
    state*:         set[EepromStateFlag]
    buffer*:        EepromBuffer
    address*:       uint32
    ignored_reads*: int
    read_bits*:     int
    wrote_bits*:    int
    # Absolute cycle the chip stays busy after a write until; rebased by
    # end_frame. Not serialized (0 after a state load).
    busy_until*:    CycleCount

  Interrupts* = ref object
    gba* {.cursor.}:    GBA
    reg_ie*: InterruptReg
    reg_if*: InterruptReg
    ime*:    bool
    # IRQ recognition held off until this cycle after a write opens the last
    # gate on a parked IF (IRQ_GATE_DELAY, interrupts.nim). Rebased by
    # end_frame; in the state's in-flight section.
    gate_open_at*: CycleCount
    # A timer interrupt in the synchroniser (raise_synced, interrupts.nim):
    # raised at pipe_at (pipe_new: the IF bits it set), IE & IF sampled into
    # pipe_bits after that cycle's register writes, recognised at pipe_due.
    # Rebased by end_frame; in the state's in-flight section, as is the
    # stall span below.
    pipe_raised*:  uint16
    pipe_new*:     uint16
    pipe_bits*:    uint16
    pipe_sampled*: bool
    pipe_at*:      CycleCount
    pipe_due*:     CycleCount
    # IRQ_PIPE_PER_SOURCE: a raise due after the one in flight waits here for
    # its own cycle (pipe2_due = pipe2_at + IRQ_SYNC_DELAY). Rebased by
    # end_frame.
    pipe2_raised*: uint16
    pipe2_new*:    uint16
    pipe2_at*:     CycleCount
    pipe2_due*:    CycleCount
    # Span the last DMA burst stalled the CPU (dma.run_pending); the
    # synchroniser stops with it (DMA_STALLS_IRQ_SYNC). stall_pushed: the
    # burst delayed a recognition under way. Rebased by end_frame.
    stall_from*:   CycleCount
    stall_to*:     CycleCount
    stall_pushed*: bool
    # IRQ_LAST_WAITS: when the pending etIrqWindowOpen / Close are due
    # (high(CycleCount) when none), so booking one needs no queue scan.
    # Transient; rebased by end_frame.
    win_open_at*:  CycleCount
    win_close_at*: CycleCount

  Keypad* = ref object
    gba* {.cursor.}:      GBA
    keyinput*: KEYINPUT
    keycnt*:   KEYCNT
    prev_irq_condition*: bool  # for edge-triggering the keypad IRQ

  MMIO* = ref object
    gba* {.cursor.}:     GBA
    waitcnt*: WAITCNT
    # POSTFLG (0x04000300): boot value 1 at ROM entry (gbaedge IDENT page).
    postflg*: uint8
    # Internal memory control (0x04000800, mirrored every 64K): EWRAM wait,
    # board WRAM enable (bit 5) and swap (bit 0) are live (bus.update_waitcnt).
    # Reset 0x0D000020 (gbaedge IDENT page). Both fields are in the state's
    # in-flight section.
    memctrl*: uint32

  Timer* = ref object
    gba* {.cursor.}:          GBA
    tmcnt*:        array[4, TMCNT]
    tmd*:          array[4, uint16]
    tm*:           array[4, uint16]
    cycle_enabled*: array[4, CycleCount]
    # The count a cold enable found: reads before counting starts see it
    # (TIMER_START_DELAY). In the state's in-flight section, as is the reload
    # latch below.
    tm_pre*:       array[4, uint16]
    # Reload writes latch one cycle late relative to an overflow: an overflow
    # on the cycle right after the write still reloads the old value
    tmd_prev*:        array[4, uint16]
    tmd_write_cycle*: array[4, CycleCount]

  # Link-cable driver; the base type (serial.nim) is the no-cable driver.
  # Frontend configuration, never serialized.
  SioDriver* = ref object of RootObj

  Serial* = ref object
    gba* {.cursor.}:        GBA
    driver*:     SioDriver # bound link-cable driver (never nil, not serialized)
    # SIOMULTI0-3 receive latches, written only by drivers on transfer
    # completion (0 with no cable). Not serialized.
    multi_recv*: array[4, uint16]
    siocnt*:     uint16    # 0x4000128 - SIO Control
    rcnt*:       uint16    # 0x4000134 - Mode Select / General Purpose
    siodata8*:   uint16    # 0x400012A - 8-bit data (shared with SIOMLT_SEND)
    siodata32*:  uint32    # 0x4000120 - 32-bit data (shared with SIOMULTI0/1)
    siomulti2*:  uint16    # 0x4000124
    siomulti3*:  uint16    # 0x4000126
    joycnt*:     uint16    # 0x4000140
    joy_recv*:   uint32    # 0x4000150
    joy_trans*:  uint32    # 0x4000154
    joystat*:    uint16    # 0x4000158

  DmaStartTiming* = enum
    dmaImmediate = 0, dmaVBlank = 1, dmaHBlank = 2, dmaSpecial = 3

  DmaAddressControl* = enum
    dmaIncrement = 0, dmaDecrement = 1, dmaFixed = 2, dmaIncrementReload = 3

  DMA* = ref object
    gba* {.cursor.}:       GBA
    dmasad*:    array[4, uint32]
    dmadad*:    array[4, uint32]
    src*:       array[4, uint32]
    dst*:       array[4, uint32]
    dmacnt_l*:  array[4, uint16]
    dmacnt_h*:  array[4, DMACNT]
    # Internal word count, loaded from dmacnt_l on enable and at each repeat
    # (GBATEK "DMA Transfer Channels"); a DMACNT_L write after enabling takes
    # effect from the next repeat. mGBA suite Misc "DMA count latching".
    count*:     array[4, uint16]
    # Latch per channel: https://github.com/mgba-emu/mgba/issues/2105
    latch*:     array[4, uint32]
    # Scheduler cycle of the last FIFO transfer on channels 1/2 (read by
    # mp2k.nim measure_latency)
    fifo_xfer_cycle*: array[4, int64]
    # Priority arbitration: bitmask of latched requests; current_priority is
    # the innermost burst's channel (4 = none). A pending channel runs only
    # if its number is below current_priority, preempting via a nested
    # run_pending. Always 0/4 between instructions, so not serialized.
    pending*:          uint8
    # DMA_PENDING_CHAIN: the requests already latched when the burst in
    # progress was granted (run_pending; transient, not serialized)
    pending_at_grant*: uint8
    # When each armed immediate channel requests the bus (DMA_START_DELAY
    # after its enable write). In the state's in-flight section.
    imm_due*:          array[4, CycleCount]
    # IMM_NEEDS_EDGE (dma.nim): channels switched to immediate timing while
    # enabled (no 0 -> 1 edge); they request nothing until a CNT_H store
    # disables or edge-enables them. Saved in the spare high nibble of the
    # DMA section's first FIFO hand-back byte.
    imm_blocked*:      uint8
    # HDMA_DROP_BUSY: until when each channel's burst holds the bus (last
    # write plus hand-back; high(CycleCount) while running). An H-blank
    # request before this is lost. Not serialized (never ahead of the clock
    # between instructions).
    busy_until*:       array[4, CycleCount]
    # FIFO_LEVEL_AT_OVERFLOW: the cycle each word of the last sound-FIFO burst
    # on channels 1/2 was written (index channel - 1). Not serialized.
    fifo_word_at*:     array[2, array[4, CycleCount]]
    # FIFO_HANDBACK_CHAIN (index channel - 1): 1 = a request landed in the
    # burst's hand-back cycle and is granted its first read; 2 = that word
    # is held in the latch, and the next burst writes it, then reads 3 more;
    # 3 = as 1, a cycle late with the CPU on the gamepak (FIFO_CART_CHAIN_LATE)
    fifo_chain*:       array[2, uint8]
    # ... and where the gamepak burst it continues had got to (bus.rom_next_addr)
    fifo_rom_next*:    array[2, uint32]
    # DMA_CHAIN: the burst that just ended handed the bus straight to the
    # next one, which starts without its lead cycle. Instruction scoped.
    chained*:          bool
    # DMA_IRQ_FROM_BUS_END: the burst just run raised its interrupt; run_pending
    # books the check. Instruction scoped, as is irq_was_set: the raise found
    # the IF bit already set (schedule_raise_check).
    irq_after_burst*:  bool
    irq_was_set*:      bool
    current_priority*: int
    # DMA3 video-capture frame latch: set at line 2, cleared with the enable
    # bit at line 162; a channel armed mid-frame waits for the next line 2
    # (gbaedge CAPDMA page). In the state's in-flight section: a capture
    # spans the frame boundary.
    video_active*:     bool
  RtcState* = enum
    rtcWaiting, rtcCommand, rtcReading, rtcWriting,
    rtcDone   # a strobe or parameter block has run; nothing more until CS drops

  RtcBuffer* = object
    size*:  int
    value*: uint64

  RTC* = ref object
    gba* {.cursor.}:    GBA
    sck*:    bool
    sio*:    bool
    cs*:     bool
    state*:  RtcState
    reg*:    int
    buffer*: RtcBuffer
    # Status register, R/W bits only (rtc_calendar S3511_STATUS_RW_BITS).
    # `irq` mirrors bit 3 (per-minute interrupt) for the poll scheduler.
    status*: uint8
    irq*:    bool
    # Netplay/rollback: when deterministic, the clock source is a frozen unix
    # epoch both peers agree on instead of the host wall clock.
    deterministic*: bool
    epoch*:         int64   # unix seconds; the frozen clock when deterministic
    # The chip's own clock (rtc.nim "Clock model"): calendar seconds = source
    # unix seconds + bias. While bias_set is false the RTC shows host local
    # time (UTC when deterministic). wday_bias offsets the weekday counter,
    # which the chip sets independently of the date.
    bias*:          int64
    bias_set*:      bool
    bias_host*:     bool   # bias came from a trailer that recorded host time
    wday_bias*:     int
    # Last unix minute seen by the per-minute IRQ poll. Not serialized (worst
    # case one spurious or missed tick after a state load).
    irq_minute*:    int64
    # The CPU drove SIO low against a read since the last falling SCK edge
    # (rtc.nim, Serial interface). Not serialized: it lives for one clock.
    pulled_low*:    bool

  GPIO* = ref object
    gba* {.cursor.}:         GBA
    data*:        uint8
    direction*:   uint8
    allow_reads*: bool
    rtc*:         RTC
    # Z-axis gyro (WarioWare: Twisted!, RZW*): a serial ADC on the RTC pins,
    # never with an RTC (GBATEK "GBA Cart Gyro Sensor"). Shift register = 4
    # zeros + 12-bit sample, MSB out per falling clock edge. gyro_z: live
    # frontend input (-1..1, CW positive).
    gyro_present*: bool
    gyro_z*:       float
    gyro_sample*:  uint16
    gyro_clock*:   bool
    gyro_out*:     uint8
    # Solar sensor (Boktai 1/2, Shin Bokura no Taiyou; GBATEK "GBA Cart
    # Solar Sensor"), shares the port with the RTC: bit 0 clocks a counter,
    # bit 1 resets it, bit 3 reads 1 once it reaches the light level.
    # solar_level: live input, 0xE8 dark, smaller brighter (~0x50 direct
    # sun). Counter not serialized: a mid-measurement load misreads once.
    solar_present*: bool
    solar_level*:   uint8
    solar_counter*: uint8
    solar_clock*:   bool

  Bus* = ref object
    gba* {.cursor.}:        GBA
    # Cached: avoids a double pointer-chase on the per-fetch/per-MMIO paths
    sched*:      Scheduler
    cycles*:     int
    # Cycles handed to the scheduler mid-instruction by catch_up; cpu.tick
    # folds them into the instruction total and resets this
    synced*:     int
    bios*:       seq[byte]
    # No BIOS file: `bios` holds the HLE stub. HLE SWI paths that jump into
    # stub code check this, staying inert under a real BIOS.
    stub_bios*:  bool
    # MP2K HLE sound window (mp2k.nim "Runtime detection"): a work-RAM store
    # with (address - snd_wbase) < snd_wlen is offered to mp2k_sound_write
    # before it lands. snd_wlen 0 = closed.
    snd_wbase*:  uint32
    snd_wlen*:   uint32
    # True only during a real byte store (strb / DMA byte); wider IO writes
    # decompose into byte writes, and some registers treat real byte stores
    # differently (gbaedge IOBYTE/DMAEDGE pages). Not serialized.
    byte_io_write*: bool
    wram_board*: seq[byte]
    wram_chip*:  seq[byte]
    # What 02000000-02FFFFFF maps: the 256K board WRAM, or with MEMCNT
    # (0x04000800) bit 5 clear the 32K chip WRAM at chip WRAM timing. Set from
    # mmio.memctrl in update_waitcnt; a raw pointer keeps the hot path free.
    ewram_off*:  bool
    ew_ptr*:     ptr UncheckedArray[byte]
    ew_mask*:    uint32
    gpio*:       GPIO
    # Tilt sensor (Yoshi's Universal Gravitation, Koro Koro Puzzle): byte
    # registers at 0x0E008000-0x0E008500 (GBATEK "GBA Cart Tilt Sensor").
    # Latches are per-frame, not serialized; tilt_in_*: live inputs, -1..1.
    tilt_present*: bool
    tilt_armed*:   bool
    tilt_x*:       uint16
    tilt_y*:       uint16
    tilt_in_x*:    float
    tilt_in_y*:    float
    bios_latch*: uint32
    # Instruction-fetch fast path: pointer + mask + waitstates for PC's page.
    # Buffers never move and ROM is padded to the full 32 MB mirror, so the
    # pointer stays valid; fetches read the live buffer, so code writes show.
    fetch_page*: uint32
    # What the fetch fast path compares against: fetch_page, or invalid to
    # force the miss path while keeping fetch_page (IRQ_LAST_WAITS's window;
    # the prefetch logic reads fetch_page).
    fetch_key*: uint32
    fetch_mask*: uint32
    fetch_c16*:  int
    fetch_c32*:  int
    fetch_ptr*:  ptr UncheckedArray[byte]
    # ROM base + length for the data-read path; reads past rom_len return the
    # open-bus pattern.
    rom_ptr*:    ptr UncheckedArray[byte]
    rom_len*:    uint32
    # WAITCNT-derived cycle costs per page (nonseq/seq x 16/32-bit); pages
    # 0-7 constant, 8-D from the ROM waitstate fields, E-F from SRAM's.
    wait16_n*: array[16, int8]
    wait16_s*: array[16, int8]
    wait32_n*: array[16, int8]
    wait32_s*: array[16, int8]
    prefetch_on*: bool
    # Per-page bitmap of the prefetch hand-off stall (rom_access_cycles): bit
    # `e` set when a prefetch halfword started `e` cycles ago is in its final,
    # uninterruptible cycle. Precomputed from wait16_s (a shift, not a
    # division); the buffer is full by e = 8*s <= 72, so only s = 9 needs the
    # modulo fallback.
    pf_commit*: array[16, uint64]
    # ROM bus bookkeeping: the address that would continue the current burst,
    # and the absolute cycle the ROM bus went idle (prefetch credit accrues
    # from there while the CPU runs off other memory)
    rom_next_addr*:  uint32
    rom_free_since*: CycleCount
    # Prefetch states the rom_free_since credit cannot express
    # (rom_access_cycles). pf_paused: buffer full, prefetcher stopped until
    # drained; pf_count halfwords left, and at 0 the next fetch is the CPU's
    # own, nonsequential. pf_running: the prefetcher has had a free bus cycle
    # since the CPU's last ROM access; until then a branch to the next
    # halfword is nonsequential. rom_ahead: how far the console's fetch
    # address leads the executing instruction's (8 ARM, 4 Thumb).
    pf_paused*:      bool
    pf_running*:     bool
    pf_count*:       int8
    rom_ahead*:      int8
    # Since the waitloop detector last looked, a read whose value changes with
    # no scheduler event (running timer, PSG status, EEPROM ready poll)
    # happened; such a loop is never skipped.
    volatile_read*:  bool
    volatile_pc*:    uint32   # r15 at the latest such read
    # dyn_loop's view since it last armed (waitloop.nim): IO classes read, a
    # volatile read, a contended access, and memory-changing stores (counted
    # only while track_changes)
    dyn_io*:         uint8
    dyn_vol*:        bool
    dyn_cont*:       bool
    track_changes*:  bool
    dyn_changes*:    uint32
    dyn_deadline*:   int64    # when the armed loop counts as left
    # Which IO registers were read since the waitloop detector last looked
    # (IO_PPU_STATUS, IO_KEYPAD, IO_OTHER; mmio.nim): the skip runs through
    # an event only if it changes none of them (cpu.nim, wl_crossable)
    io_read*:        uint8
    # A CPU access waited on the renderer (contend_cost, cpu.contend_refill)
    # since the waitloop detector last looked
    contended_access*: bool
    # Second burst tracker for DMA: src and dst streams interleave on the ROM
    # bus yet each stays sequential
    rom_next_addr2*: uint32
    dma_active*:     bool
    # SWP holds the bus from its read to its write: DMA granted in between
    # waits for the write (arm_single_data_swap). Not serialized.
    swp_lock*:       bool
    # Prefetch hand-off to a DMA burst: rom_free_since is on the CPU's bus
    # clock but a granted DMA runs on the event clock (tick_slow rewinds), so
    # the prefetcher's phase counts from this grant cycle instead. Lives
    # within one burst; not serialized.
    dma_grant_now*:  CycleCount
    dma_first_rom*:  bool
    # PF_WAIT_UNDER_BURST / FIFO_FETCH_GATE: the last gamepak opcode fetch that
    # waited on the prefetcher, [from, to) on the bus clock. Read only by a
    # burst granted inside it; not serialized.
    pf_wait_from*:   CycleCount
    pf_wait_to*:     CycleCount
    # True while the CPU fetch stream is unbroken: sequential ROM fetches skip
    # the absolute-time bookkeeping. Any other cycle consumer must "cool" the
    # stream (recording rom_free_since) first.
    rom_hot*:        bool
    # Data accesses sync the scheduler while bits 0/1 are set, so a DMA
    # preempts the CPU at its exact cycle (a read one instruction after an
    # enable sees the DMA'd data). One test on the data path, none on
    # fetches: the window invalidates the fetch cache and rides its miss path.
    # Bit 0: an immediate DMA is armed. Bit 1: a PPU-timed DMA request is
    # close (DMA_ACCESS_WINDOW). Bit 2 (with 0): the armed request found an
    # access in flight and waits a cycle (IMM_IDLE_GRANT). Bit 3: an IRQ is
    # on its way; accesses record where their wait states lie
    # (IRQ_LAST_WAITS). Bit 4: a sound FIFO refill is close; data accesses
    # and internal cycles sync, fetches stay fast (FIFO_DMA_WINDOW). Bit 5
    # (with 4): refill granted; the CPU's next internal cycles close the
    # window. Bit 6 (SB_SWAP): MEMCNT swap set, 00000000-03FFFFFF go through
    # the swapped map (bus.nim swap_read_word); set from mmio.memctrl in
    # update_waitcnt, never serialized.
    sync_bits*: uint8
    # A fetch is going through the swapped map: it reads the BIOS regardless
    # of PC (transient).
    swap_fetching*: bool
    # IRQ_LAST_WAITS, recorded while bit 3 is set: where the last CPU access
    # ended and how many of its cycles were wait states.
    lw_end*:    CycleCount
    lw_waits*:  int
    access_end*: CycleCount         # end of the access a window sync is inside
    access_start*: CycleCount       # and its first cycle
    # IMM_ACCESS_WAIT: an immediate DMA's request landed in the CPU access
    # being synced; the accessor grants it once the access has taken effect.
    imm_post*: bool
    # ... or one due in a load or exactly as an access ended: the next CPU
    # step at that cycle hands over (an internal cycle via IMM_IDLE_GRANT's
    # path, a data access before it starts; a fetch leaves it to the
    # one-cycle retry).
    imm_pre*: bool
    access_rom*: bool               # the synced access is on the gamepak bus
    access_write*: bool             # and is a store
    dma_deferred_from*: CycleCount  # a deferred grant's original request cycle
    dma_deferred*: bool
    window_closing*: bool           # the request fired; the next fetch closes the window
    dma_before_access*: bool        # FIFO_DMA_WINDOW: the grant came first; nothing ran under it
    dma_idle_edge*: bool            # FIFO_DMA_WINDOW: internal cycles ended on the grant; the last ran under it
    idle_until*: CycleCount         # end of the internal cycles a window sync is inside
    # IMM_IDLE_GRANT: the CPU's last internal cycles while an immediate DMA
    # was armed, [from, until). Read only within DMA_START_DELAY of the
    # arming write; not serialized.
    imm_idle_from*: CycleCount
    imm_idle_until*: CycleCount
    imm_at*: CycleCount             # when the armed immediate DMA requests the bus
    in_catch_up*: bool              # a dispatch from inside an access's sync (catch_up_slow)
    dma_end_at*: CycleCount         # when the last CPU-interrupting burst let go
    dma_held*: int                  # and how long it had held the bus
    # Running total of cycles DMA stalled the CPU; HLE BIOS cost models time
    # themselves net of it (hle_bios.nim hle_body_now). Differences only; not
    # serialized.
    dma_stall_total*: int64
    # Open-bus latch left by DMA: the last word moved stays on the data bus
    # until the CPU's next access, so only the first access after the burst
    # can read it unmapped (read_open_bus_value). dma_request_at: when the
    # latest burst was requested. AGB SP, gbaedge DMAOPENBUS and HDMAPHASE
    # (docs/dev/hwprobe-results-agb.md sessions 5-6); mGBA suite Misc "DMA
    # Prefetch Read". Games: Hello Kitty Collection: Miracle Fashion Maker's
    # boot (a sound-FIFO DMA's final zero) and Famicom Mini Metroid (a ROM
    # table walk stops only on an H-blank DMA's word).
    dma_open_bus*:       uint32
    # HLE SoundDriverMain (hle_sound.nim sd_mix) fills a pcmBuffer slot at
    # once; the real routine writes it byte by byte, and a sound DMA draining
    # that slot meanwhile (first passes after a start, ring has no lead) sees
    # the partial bytes. The pass leaves its writes here, timed from
    # sd_tw_start (bus.nim sd_tw_word); a FIFO DMA read in the window gets
    # the byte as of its cycle. Not serialized.
    sd_tw_active*:       bool
    sd_tw_start*:        CycleCount
    sd_tw_a0*:           uint32
    sd_tw_n*:            int
    sd_tw_pre*:          seq[uint8]     # the slot before the pass (A, then B)
    sd_tw_head*:         seq[int32]     # per byte: its first write, or -1
    sd_tw_tail*:         seq[int32]
    sd_tw_next*:         seq[int32]     # per write: the byte's next one
    sd_tw_t*:            seq[int32]     # per write: cycle from sd_tw_start
    sd_tw_v*:            seq[uint8]     # per write: the byte's new value
    # DMA_READS_CPU_BUS: the CPU's last synced data load (address, size in
    # bytes, r15); 0 = none. A burst's first unmapped read sees its value if
    # the CPU has fetched nothing since. Syncing path only; not serialized.
    load_addr*:          uint32
    load_size*:          int
    load_pc*:            uint32
    load_start*:         CycleCount
    load_end*:           CycleCount
    dma_bus_req*:        CycleCount  # when the burst in progress asked for the bus
    ldrsh_odd*:          bool
    dma_bus_fresh*:      bool  # no transfer of this burst has driven the bus yet
    # DMA_BUS_BACK_TO_BACK: the burst being granted follows another with no
    # CPU access between them (set by dma.run_pending per grant)
    dma_bus_kept*:       bool
    # DMA_BUS_WHILE_HALTED: the last burst let go of the bus with the CPU
    # halted, and the CPU has not run since (cleared by the wake)
    dma_bus_left*:       bool
    # DMA_READS_IO_LOAD: the value the CPU's last I/O register load read
    load_io*:            uint32
    load_io_ok*:         bool  # load_io is that load's (its read has happened)
    # DMA_SEES_REFILL_FETCH: cycles of the granting instruction still to run
    # after the request (set by its closing tick)
    dma_bus_tail*:       int
    iwram_latch*:        uint32  # the last word a DMA moved to or from IWRAM
    dma_request_at*:     CycleCount
    dma_has_run*:        bool
    # -d:obuslatch (off by default): open bus as a real 32-bit register, halves
    # driven independently by opcode fetches and DMA words. Only this shape
    # gives the half-DMA, half-opcode word an AGB SP returns two NOPs after a
    # burst (obuswint.s; docs/dev/playtest-bugs.md section 13). Not serialized.
    obus_latch*:         uint32
    # Cycle each half was last driven by an opcode fetch. DMA is resolved
    # against these at read time, not applied here: a deferred immediate DMA
    # runs in the right cycle but after fetches it should precede. Per-half
    # stamps let the halves answer differently (DEAD6019).
    obus_half_at*:       array[2, CycleCount]
    # -d:obusahead (off by default): bus clock at the previous instruction's
    # start, when the real pipeline drove this opcode's fetch. Only the latch
    # stamps move; timing-neutral.
    obus_prev_at*:       CycleCount
    # Per page: true for palette RAM / VRAM / OAM while the renderer may hold
    # it; accesses then ask contention.nim (ppu.contend_mask_update). Derived.
    contended*:          array[16, bool]

  WLInstrKind* = enum
    wlLongBranchLink, wlUnconditionalBranch, wlSoftwareInterrupt,
    wlConditionalBranch, wlMultipleLoadStore, wlPushPopRegisters,
    wlAddOffsetToStackPointer, wlLoadAddress, wlSpRelativeLoadStore,
    wlLoadStoreHalfword, wlLoadStoreImmediateOffset, wlLoadStoreSignExtended,
    wlLoadStoreRegisterOffset, wlPcRelativeLoad, wlHighRegBranchExchange,
    wlAluOperations, wlMoveCompareAddSubtract, wlAddSubtract,
    wlMoveShiftedRegister, wlUnimplemented

  WLTables* = ref object
    ## Out of CPU's own object: ~11 KB inside it measurably slowed the hot
    ## fields after it
    verdict_key*:  array[WL_VERDICT_SLOTS, uint32]
    verdict*:      array[WL_VERDICT_SLOTS, uint8]
    verdict_load*: array[WL_VERDICT_SLOTS, uint32]
    verdict_body*: array[WL_VERDICT_SLOTS, array[32, uint8]]
    rest_key*:     array[DYN_REST_SLOTS, uint32]
    rest*:         array[DYN_REST_SLOTS, int32]

  WLParsed* = object
    read_only*:  bool
    read_bits*:  uint16
    write_bits*: uint16

  CPU* = ref object
    gba* {.cursor.}:         GBA
    r*:           array[16, uint32]
    cpsr*:        PSR
    spsr*:        PSR
    pipeline*:    Pipeline
    # True between a PC write and the first fetch at the destination: a write
    # near the new PC then (an immediate DMA right after the branch) must
    # reach the refill, so write_*_internal's self-modifying-code capture
    # stands down (Golden Sun TLA DMAs a `bx pc` trampoline onto the stack
    # and branches to it before the transfer runs)
    refill_pending*: bool
    reg_banks*:   array[7, array[7, uint32]]  # [6] = UNDEF_BANK, see cpu.nim
    spsr_banks*:  array[6, uint32]
    halted_v:     bool  # these five: through their setters (cpu_slow below)
    stopped*:     bool  # Stop mode: halted, and only keypad/cartridge/SIO IRQs wake
    # Level-triggered IRQ signal (IE & IF != 0 and IME), maintained by
    # check_interrupts; sampled at instruction boundaries only
    irq_line_v:   bool
    # When the synchroniser raised irq_line (IRQ_LAST_WAITS).
    irq_line_at*: CycleCount
    # Set when an IRQ wakes the CPU from halt. Unread; kept for the state
    # format.
    halt_wake_v:  bool
    # HLE IntrWait: while active, the CPU re-halts at resume_addr until the
    # user IRQ handler ORs a masked flag into the BIOS mirror at 0x03007FF8
    intr_wait_active_v:     bool
    intr_wait_mask*:        uint16
    intr_wait_resume_addr*: uint32
    # HLE Halt/Stop: the real BIOS runs its dispatcher return path after the
    # wake IRQ is serviced, so that cost is charged on reaching the
    # instruction after the SWI.
    halt_resume_charge_v:   int32
    halt_resume_addr*:      uint32
    # The parked charge is a Halt/Stop SWI's, whose entry left the dispatcher's
    # {r2, lr} frame live (System sp - 8); the resume must pop it.
    # Decompression SWIs park charges here but never shift sp.
    halt_resume_pop*:       bool
    # Any of halted, irq_line, halt_wake, intr_wait_active or a parked
    # halt_resume_charge: tick's pre-opcode checks have work. Kept exact by
    # those five fields' setters.
    cpu_slow*:              bool
    # An HLE CpuSet/CpuFastSet preempted by an IRQ rewinds onto its SWI with
    # the continuation in r0-r2 (hle_bios.nim); these identify it so the
    # re-dispatch resumes without paying dispatch or entry again, as the real
    # one returns into its loop. In the state's in-flight section.
    copy_cont_pc*:          uint32
    copy_cont_regs*:        array[3, uint32]
    # Waitloop fields
    attempt_waitloop_detection*: bool
    cache_waitloop_results*:     bool
    branch_dest*:                uint32
    identified_waitloops*:       HashSet[uint32]
    identified_non_waitloops*:   HashSet[uint32]
    # One-entry caches in front of the HashSets: a hot loop re-analyzes the
    # same branch every iteration. last_non_waitloop 1 = empty (Thumb
    # addresses are even); last_waitloop 0 = empty (always a ROM address).
    last_non_waitloop*:          uint32
    last_waitloop*:              uint32
    # Loops the scan could not follow but might repeat (judge_loop, WL_DYN)
    identified_dyn_loops*:       HashSet[uint32]
    last_dyn_loop*:              uint32
    never_keys*:                 array[4, uint32]   # waitloop.note_never
    wlt*:                        WLTables   # judge_loop's and dyn_loop's tables
    branch_dest2*:               uint32             # the target before branch_dest
    wl_dyn*:                     bool
    entered_waitloop*:           bool
    # A waitloop's first memory load (0xFFFFFFFF: none), per cached start
    waitloop_first_load*:        Table[uint32, uint32]
    last_waitloop_first_load*:   uint32
    # Exact-skip bookkeeping (waitloop.nim "Transparency"): the last loop
    # branch seen, its bus time, the period since the visit before, and the
    # dispatch count then
    wl_addr*:                    uint32
    wl_time*:                    int64
    wl_period*:                  int64
    wl_dispatch_mark*:           uint32
    # At that visit: nothing since the visit before made an event after the
    # loop's read matter (WL_QUIET_EVENTS; waitloop_skip)
    wl_quiet*:                   bool
    # That visit's verdict: the loop may be skipped (waitloop_skip still
    # requires the iteration to have repeated exactly, below)
    wl_skip_ok*:                 bool
    # A loop whose current run read something volatile (waitloop.nim)
    wl_volatile_at*:             uint32
    wl_volatile_rest*:           int32
    # dyn_loop (waitloop.nim): the armed loop, when it armed, registers then
    # (r15's slot holds CPSR) and counters
    dyn_key*:                    uint32
    dyn_time*:                   int64
    dyn_regs*:                   array[16, uint32]
    dyn_mark_changes*:           uint32
    dyn_mark_swi*:               uint32
    dyn_mark_irq*:               uint32
    dyn_mark_dma*:               uint32
    dyn_mark_dispatch*:          uint32
    swi_count*:                  uint32
    irq_count*:                  uint32
    # Where the last judged iteration ended (the loop's start), which loop,
    # and the prefetcher's state there (waitloop_skip): an iteration starting
    # in the previous one's state and taking as long repeats until an event
    wl_bound*:                   int64
    wl_bound_addr*:              uint32
    wl_sig_next*:                uint32
    wl_sig_free*:                int64
    wl_sig_bits*:                uint32
    wl_bound_dma*:               uint32   # gba.dma_bursts there
    wl_verdict_dma*:             uint32   # ... and at the last verdict
    # Whether a skip may run through events the loop cannot observe
    # (cpu.wl_crossable). Off for cores in lockstep (link.nim, netcore.nim):
    # a longer skip changes their interleave. Configuration, not serialized.
    wl_cross_events*:            bool
    # The IO registers the iteration the last verdict closed read (io_read)
    wl_reads_io*:                uint8
    # ... or waited on the renderer (its cost then moves with the dot)
    wl_contended*:               bool
    waitloop_instr_lut*:         seq[WLInstrKind]
    # The LDM^ glitch (arm/arm.nim ldm_user_glitch): current-bank registers
    # reading banked OR user for the one instruction after an LDM^, their own
    # values, and that instruction. Not serialized: states are taken with it
    # settled (gba_state_payload).
    ldm_glitch*:       uint16
    ldm_glitch_instr*: uint32
    ldm_glitch_saved*: array[16, uint32]
    # Within one instruction: a return to Thumb already refilled from the
    # prefetcher's stream at Thumb width, at ret_refill_at
    # (cpu.refill_from_head); exception_return_restore must not redo it.
    ret_refilled_thumb*: bool
    ret_refill_at*: uint32

  SpritePixel* = object
    priority*: uint16
    palette*:  uint16
    blends*:   bool
    window*:   bool

  Sprite* = object
    attr0*:     uint16
    attr1*:     uint16
    attr2*:     uint16
    aff_param*: int16

  PPU* = ref object
    gba* {.cursor.}:          GBA
    framebuffer*:  seq[uint16]
    # Frame boundaries not yet consumed by step_frame/end_frame. A counter: an
    # atomic HLE decompression SWI can span several frames.
    frame*:        int
    layer_palettes*: array[4, array[240, uint8]]
    sprite_pixels*: array[240, SpritePixel]
    # BG2 line buffers for the direct-color bitmap modes (3 and 5)
    bitmap_direct*: bool
    bg2_direct*:        array[240, uint16]
    bg2_direct_opaque*: array[240, bool]
    pram*:         seq[byte]
    vram*:         seq[byte]
    oam*:          seq[byte]
    dispcnt*:      DISPCNT
    dispstat*:     DISPSTAT
    vcount*:       uint16
    bgcnt*:        array[4, BGCNT]
    bghofs*:       array[4, BGOFS]
    bgvofs*:       array[4, BGOFS]
    bgaff*:        array[2, array[4, BGAFF]]
    bgref*:        array[2, array[2, BGREF]]
    bgref_int*:    array[2, array[2, int32]]
    mosaic_bgref_int*: array[2, array[2, int32]]  # affine coords latched per mosaic block
    win0h*:        WINH
    win1h*:        WINH
    win0v*:        WINV
    win1v*:        WINV
    winin*:        WININ
    winout*:       WINOUT
    mosaic*:       MOSAIC
    bldcnt*:       BLDCNT
    bldalpha*:     BLDALPHA
    bldy*:         BLDY
    # Line-start latches, pinned by the mGBA suite "Video tests".
    # bg_enable_hist: DISPCNT's BG0-3 enables on the last three lines, newest
    # in the low nibble. A BG draws only if its bit is set now AND two lines
    # ago: an enable shows from the third line, a disable is immediate
    # ("Layer toggle" 1 and 2).
    bg_enable_hist*: uint16
    # Lines (counting this one) the renderer stays in forced blank after the
    # bit clears (FB_EXIT_HOLD_LINES): no BG/palette fetch, so no contention.
    # Saved in bg_enable_hist's spare bits 12-13.
    fb_hold*: uint8
    # Scheduler cycle of this line's start (for BG_ENABLE_LATCH_CYCLE);
    # rebased by end_frame, recomputed from the pending line event on load.
    line_start_cycle*: int64
    # WIN0/WIN1 vertical state: set at the line start where VCOUNT == Y1,
    # cleared where it == Y2 (clear wins a tie). An unreached Y2 leaves the
    # window open into the next frame ("Window offscreen reset").
    win0_inside*:  bool
    win1_inside*:  bool
    # OAM as the sprite scan sees it: copied from `oam` after each line, so a
    # write moves sprites from the second line after it ("OAM Update Delay").
    # oam_view_stale: a write is waiting.
    oam_view*:       seq[byte]
    oam_view_stale*: bool
    # Frame-start copies of the latches above, so render-skip notices a latch
    # that settles a frame after its register write.
    frame_start_latches*: uint32
    # BG enables for the line being drawn (scratch): DISPCNT and the delay.
    line_bg_enables*: uint16
    # Mid-line BG enable (midline_bg_enable): DISPCNT's BG bits at line start
    # and the cycle into the line each bit rose (-1: not this line). Derived.
    line_start_bg_bits*: uint16
    bg_enable_cycle*:    array[4, int32]
    # Compositing scratch, recomputed each scanline: contributing BGs as a
    # (priority, BG index)-ordered walk list, plus per-column window enables
    walk_bgs*:     array[4, int8]  # BG number of each walk entry
    walk_prios*:   array[4, int8]  # priority of each walk entry
    walk_n*:       int
    line_enables*: array[240, uint16]
    line_effects*: array[240, bool]
    line_sprite_blend*: bool  # any semi-transparent sprite pixel on this line
    line_obj_window*: bool    # any OBJ-window sprite pixel on this line
    # Per-line OBJ candidates: obj_line_mask[line] is a 128-bit set (entry N
    # = bit N&63 of word N>>6) of OAM entries whose box covers the line.
    # Rebuilt lazily (obj_list_dirty via oam_touched); past
    # OBJ_LIST_REBUILD_LIMIT rebuilds a frame, the rest of it uses the plain
    # 128-entry scan. Derived, not serialized.
    obj_line_mask*:     array[160, array[2, uint64]]
    obj_list_dirty*:    bool
    obj_list_rebuilds*: int
    # Render skipping: render_dirty is set by anything that can change the
    # picture; after a full unchanged frame, rendering is skipped.
    # frame_static lets the frontend skip the texture upload too.
    render_dirty*: bool
    skip_render*:  bool
    frame_static*: bool
    # Debug-UI layer visibility (bits 0-3 = BG0-3, bit 4 = OBJ; 1 = shown),
    # applied per scanline only, keeping the per-pixel path untouched.
    debug_layer_mask*: uint16
    # Forces composite() to build per-column window tables even on uniform
    # lines; only tests/ppucomposite_test.nim sets it.
    disable_uniform_window*: bool
    # Renderer contention (contention.nim): the dots of a line the renderer
    # holds BG VRAM / palette RAM / OBJ VRAM / OAM, one bit a dot. Built on
    # demand, keyed by inputs; never serialized (an impossible key forces a
    # rebuild).
    cont_regs_stale*: bool          # DISPCNT/BGxCNT/BGxHOFS/BLDCNT written
    cont_bg_key*:   uint32
    cont_bg*:       array[CONT_WORDS, uint32]
    cont_pram_key*: uint32
    cont_pram*:     array[CONT_WORDS, uint32]
    cont_obj_key*:  int64
    cont_objv*:     array[CONT_WORDS, uint32]
    cont_oam*:      array[CONT_WORDS, uint32]

  # ---- PSG channels: the shared PSG (common/psg.nim) ----
  SoundChannel* = PsgChannel
  VolumeEnvelopeChannel* = PsgEnvChannel
  Channel1* = PsgSweepSquare
  Channel2* = PsgSquare
  Channel3* = PsgWave
  Channel4* = PsgNoise

  DMAChannels* = ref object
    gba* {.cursor.}:       GBA
    fifos*:     array[2, array[32, int8]]
    positions*: array[2, int]
    sizes*:     array[2, int]
    latches*:   array[2, int16]
    # FIFO reconstruction (render-side, not serialized): point-sampling the
    # held latch at 32768 Hz folds zero-order-hold images into the audible
    # band, so a causal four-point cubic over hist (0 oldest .. 3 newest)
    # rebuilds the signal. last_update_cycle: newest latch's time;
    # inv_period: 1/measured update period (0 = none yet: hold the latch).
    hist*:            array[2, array[4, int16]]
    last_update_cycle*: array[2, int64]
    inv_period*:        array[2, float32]
    fifo_interp*:     bool   # cubic FIFO reconstruction (default on)
    # MP2K HLE slot timing (mp2k.nim render_frame, not serialized): source
    # address of each FIFO byte from a special-timing sound DMA (0 = other),
    # and up to four ring addresses whose first DAC appearance is stamped
    # (watch_clock: HLE output clock, -1 until played; watch_cyc: scheduler).
    tags*:        array[2, array[32, uint32]]
    watch_addr*:  array[4, uint32]
    watch_clock*: array[4, int]
    watch_cyc*:   array[4, int64]

  APU* = ref object
    gba* {.cursor.}:               GBA
    soundcnt_l*:        SOUNDCNT_L
    soundcnt_h*:        SOUNDCNT_H
    sound_enabled*:     bool
    soundbias*:         SOUNDBIAS
    buffer*:            seq[int16]
    buffer_pos*:        int
    frame_sequencer_stage*: int
    first_half_of_length_period*: bool
    # Cycle of the last SOUNDCNT_X master-on, or GBA_NO_STEP (dropped by a
    # rebase past it). Read only within PSG_POWER_ON_WINDOW. Not serialized:
    # a state saved in those 8 cycles loads without the window.
    power_on_at*: CycleCount
    channel1*:          Channel1
    channel2*:          Channel2
    channel3*:          Channel3
    channel4*:          Channel4
    dma_channels*:      DMAChannels
    sync*:              bool
    channel_mask*:      array[6, bool]  # PSG 1-4 + DMA A/B; true = enabled
    # Master volume as an 8.8 fixed-point factor (256 = unity)
    master_volume_factor*: int32
    master_muted*:      bool
    # Nobody hears this core (muted, volume 0, run-ahead lookahead, link
    # player 2): get_sample skips catch-up and mix (set_audio_silent). Not
    # serialised.
    silent*:            bool
    lookahead*:         bool  # run-ahead's unseen frames: nothing reaches the queue
    # 2x speed: drop every other stereo frame at the queue point
    turbo*:             bool
    turbo_parity:       bool  # emscripten per-sample decimation state
    # Pitch-correct fast-forward: WSOLA time-stretch instead of 2x decimation.
    # Presentation-only, not serialised.
    pitch_correct_ff*:  bool
    stretch:            TimeStretch
    stretch_engaged:    bool  # tracks the stretch-path rising edge (auto-reset)
    owns_audio*:        bool  # this core holds the audio queue (audio_out)
    # Optional analog-output low-pass: one-pole IIR on the native mix (web
    # uses a BiquadFilter node). Off by default.
    audio_lowpass*:     bool
    lp_left, lp_right:  float32
    left_resampler*:    Resampler[float32]
    right_resampler*:   Resampler[float32]
    resample_freq*:     int
    output_freq*:       int

  # MP2K/M4A sound-engine HLE state (mp2k.nim documents every mechanism;
  # comments here only locate it). Off by default.
  Mp2kChanSnap* = object
    status*, ctype*: uint8
    wave*, freq*, ct*: uint32
    pr*, pl*: uint8         # per-side volumes predicted for this pass (mp2k.nim predict_envelope)
    prf*, plf*: float32     # the same gains un-truncated (side/256 scale), for the quality tier
    prf2*, plf2*: float32   # ...and the NEXT pass's, by the same rules (the tier's continuous envelope)
    pvalid*: bool           # a prediction was made (checked one hook later)

  Mp2kSampler* = object
    active*:      bool
    wave_data*:   uint32
    rom_off*:     uint32    # cached ROM byte offset of the sample data (in_rom)
    in_rom*:      bool      # sample bytes live in cartridge ROM (fast path)
    sample_count*: uint32   # WaveData.size: number of source samples
    loop_start*:  uint32    # WaveData.loopStart: loop restart index
    looping*:     bool
    freq*:        uint32
    compressed*:  bool      # BDPCM decode selected (mp2k.nim TYPE_* table)
    use_pcm_rate*: bool     # TYPE_FIX: step at SoundInfo.pcmFreq
    reversed*:    bool      # TYPE_REV: play the sample backward
    start_off*:   uint32    # note-on sample start offset (SoundChannel.count at START)
    blk_index*:   uint32    # BDPCM block decoded in blk (0xFFFFFFFF = none)
    blk*:         array[64, int8]  # decoded s8 samples of that block
    src_index*:   uint32    # integer sample read cursor (block/offset derived from this)
    phase_frac*:  float32   # fractional phase (mu) between fetched samples, 0..1
    taps*:        array[128, float32] # window of 64 source samples at cursor-31 .. cursor+32, s8
                            # units (MP2K_TAP_OFF), starting at tap_base: the window slides
                            # through the buffer as the cursor advances (mp2k.nim fetch_taps)
    tap_base*:    int32     # index of the window's first tap in `taps`
    tap_i*:       uint32    # cursor the taps were fetched for (0xFFFFFFFF = none)
    ended*:       bool      # one-shot cursor ran past the end: silent (mp2k.nim advance_cursor)
    vol_l*, vol_r*: float32 # per-side gain for the frame being rendered (side/256)
    vol_l_to*, vol_r_to*: float32  # quality tier: gains at the END of the frame (next pass's)
    age*:         int       # frames since (re)trigger; 0 on the attack frame
    chk_off*:     uint32    # mp2kwav: non-zero start offset seen at note-on, checked next pass

  Mp2kHle* = ref object
    gba* {.cursor.}: GBA
    # Pass detection (mp2k.nim "Runtime detection"): the watched SoundInfo,
    # whether its lock write was seen with no ring store yet, and the ring
    # each FIFO DMA plays (len 0 = none)
    wsip*:       uint32
    armed*:      bool
    pass_streak*: int               # consecutive locked passes that stored into a ring (engaging needs 2)
    ring_base*:  array[2, uint32]
    ring_len*:   array[2, uint32]
    last_pass_cnt*:  int            # pcmDmaCounter at the previous pass (mixer_pass: same slot = replacement)
    last_pass_clock*: int64         # apu_clock at the previous pass
    last_frame_w*:   int            # fifo_w where the previous pass's frame starts (render_frame)
    pass_store*:     uint32         # address of the ring store that ran the current pass
    watch_pass*:     array[4, int]  # apu_clock at the pass each DMAChannels watch belongs to
    watch_slot*:     array[4, int]  # that pass's ring slot
    watch_pass_cyc*: array[4, int64] # scheduler cycle at that pass
    meas_valid*:     bool           # a pass's slot has been heard (render_frame)
    meas_play*:      float32        # output clock at which that slot's first sample sounds
    meas_pass*:      int            # apu_clock at that pass
    meas_slot*:      int            # its ring slot
    meas_cyc*:       int64          # scheduler cycle at that pass
    place_big*:      int            # a large placement error seen at the previous pass (0 = none)
    dbg_steps*:      int            # placement steps taken (sweep diagnostic)
    replace_pass*:   bool           # the pass being rendered replaces the previous pass's frame
    seq_late*:   int                # channels first seen ON without START (a start outside the driver's sequencer)
    engaged*:    bool       # a valid SoundInfo has been observed at least once
    frame_seen*: bool
    hook_stale*: int32      # frames since a mixer pass last ran (mp2k.nim mixer_live)
    resync_pending*: bool   # re-latch every channel at the engine's position (mp2k_state_loaded)
    samplers*:   array[12, Mp2kSampler]
    compressed_skipped*: int
    dbg_compressed_used*: int   # frames*channels where a BDPCM voice was live
    dbg_hook_fires*: int        # mixer passes seen
    dbg_replaced*: int          # passes that rewrote the previous pass's slot (mixer_pass)
    dbg_overlay_triggers*: int  # overlay passthrough entries (idle->held)
    dbg_overlay_passes*: int    # mixer passes spent in overlay passthrough
    dbg_unlatches*: int         # fifo_foreign latches reversed by agreement
    dbg_out_energy*: float64
    dbg_out_count*:  int
    dbg_reverb*:     uint8
    dbg_pcm_rate*:   int
    pcm_sample_rate*: int
    play_rate*:      float32        # the rate the sound DMA's timer plays the ring at (apply_pending)
    reverb_strength*: uint8
    use_cubic*:      bool
    resample_mode*:  int           # DIAG: 0=cubic,1=linear (the driver's own),2=hold
    # Snapshot of the pass that has just run, rendered one hook later with
    # the envelope it computed (mp2k.nim snapshot_pass / apply_pending)
    pend_valid*:     bool
    pend*:           array[12, Mp2kChanSnap]
    pend_reverb*:    uint8
    pend_rate*:      int
    pend_period*:    int
    pend_spv*:       int
    pend_cnt*:       int
    pend_maxc*:      int
    pend_mono*:      int
    pend_dma_src*:   uint32         # sound DMA replay cursor at the hook (mp2k.nim hw_latency)
    # Predictive mode (mp2k.nim predict_envelope): a pass's frame renders at
    # its own hook from the predicted envelope, placed at the hardware's
    # latency; if the real bytes one hook later disagree, the HLE falls back
    # to rendering one hook late.
    predict*:        bool
    pred_ok*, pred_bad*: int
    # Measured pass-to-DMA latency (mp2k.nim measure_latency): each pass's
    # slot start is watched until the sound DMA's cursor crosses it.
    apu_clock*:      int            # render_sample calls since init (APU samples)
    lat_slot*:       array[4, uint32]   # slot start addresses awaiting their crossing
    lat_at*:         array[4, int64]    # scheduler cycle at each one's hook
    lat_n*:          int
    lat_prev_src*:   uint32         # DMA cursor at the previous hook
    lat_avg*:        float32        # EMA of the measured latency, APU samples (0 = none yet)
    lat_count*:      int
    lat_hw_ref*:     int            # the phase estimate the measurements belong to (on_frame: a re-timed DMA restarts them)
    cnt_rate*:   int                # configuration the counter maximum was learnt under
    cnt_spv*:    int
    cnt_max*:        int            # largest pcmDmaCounter seen: the ring's real period
    # Slot the pass writes vs the counter formula (mp2k.nim learn_slot_offset)
    ring_copy*:      seq[uint8]
    ring_copy_valid*: bool
    ring_prev_slot*: int
    slot_off*:       int
    slot_off_vote*:  int
    slot_votes*:     int
    slot_locked*:    bool
    # Rendered-frame output FIFO (mp2k.nim render_frame / render_sample)
    fifo*:           seq[float32]   # stereo ring, MP2K_FIFO_CAP frames, latch scale
    mix_l*, mix_r*:  seq[float32]   # render_voices: the frame's per-side voice sums
    mix_ramp*:       seq[float32]   # render_voices: sample k's position k / frame_n in the gain ramp
    fifo_r*, fifo_w*: int           # read / write cursors (frames)
    fifo_acc*:       float32        # fractional frame-length carry
    fifo_err_avg*:   float32        # slow average of level - target (render_frame)
    fifo_trimming*:  bool           # trim engaged: runs until the average is ~0
    fifo_settle*:    int            # frames left in which the trim converges from any error (render_frame)
    fifo_settle_ref*: int           # the target the last settle converged to
    fifo_step_ref*:  int            # the target at the previous frame (render_frame: a moved target vs a jumped level)
    fifo_last_a*, fifo_last_b*: float32  # held across an underrun
    # Quality tier (mp2k.nim "Quality tier"): off = the driver's arithmetic
    # (parity checks); on = un-floored output, ramped gains, interpolated
    # echo. fine_a/fine_b: this sample's un-truncated FIFO values, for
    # apu.nim to add the sub-LSB remainder after the DAC.
    quality*:        bool
    fine_a*, fine_b*: float32
    frame_n*:        int            # output samples in the frame being rendered
    fifo_target*:    int            # level aimed for when a frame is pushed (the guard)
    fifo_primed*:    bool           # target-level silence pre-fill done
    mono_mode*:      int    # fed FIFO topology: 0 stereo, 1 mono via A, 2 mono via B (apply_pending)
    fifo_foreign*:   bool   # session latch: the engine does not own the FIFO stream (on_frame)
    foreign_streak*: int    # consecutive foreign-evidence passes
    fifo_cpu_bytes*: int   # FIFO bytes written by anything but special DMA1/2
    fifo_cpu_last*:  int   # counter snapshot at the previous mixer pass
    # Real-vs-shadow energy per FIFO side, accumulated in apu.get_sample and
    # evaluated per mixer pass in on_frame.
    real_abs_a*:     int64  # sum |real FIFO A latch| since last mixer pass
    real_abs_b*:     int64  # sum |real FIFO B latch| since last mixer pass
    hle_abs_l*:      int64  # sum |shadow render L|   since last mixer pass
    hle_abs_r*:      int64  # sum |shadow render R|   since last mixer pass
    ab_n*:           int    # samples accumulated
    overlay_hold*:   int32  # passes left emitting the real stream over the shadow (on_frame overlay)
    unlatch_watch*:  bool   # latched but channels active: render un-emitted (on_frame unlatch)
    unlatch_agree*:  int32  # consecutive agreeing passes toward unlatch
    dbg_real_avg*:   float32
    dbg_hle_avg*:    float32
    shadow_quiet_age*: int  # passes since the shadow last sounded (drain-tail grace, on_frame)
    # Shadow of the engine's pcmBuffer frame ring (mp2k.nim render_sample reverb block)
    reverb_ring*:    seq[float32]  # rev_period slots x MP2K_REV_SLOT_LEN stereo samples
    rev_slot*:       int           # current frame slot (the one being overwritten)
    rev_pos*:        int           # intra-frame sample index within the slot
    rev_period*:     int           # ring length in V-blank frames = SoundInfo.pcmDmaPeriod
    rev_spv*:        int           # cells per slot = SoundInfo.pcmSamplesPerVBlank (engine rate)
    rev_phase*:      float32       # cell-position accumulator (pcmFreq/32768 per sample)
    rev_cell*:       int           # last cell written this pass (-1 = none)
    rev_seed*:       float32       # seed held across the current cell's output samples
    rev_seed_prev*:  float32       # the previous cell's seed (quality: interpolated echo)

  # Camelot "Bon" sound-driver HLE state (Golden Sun; gs_bon.nim). Off by
  # default; shares the mp2k_hle enable flag with its own engaged state.
  GsBonSampler* = object
    active*:      bool
    synth*:       bool      # oscillator instrument (WaveData size==0 && loopStart==0)
    synth_kind*:  uint8     # 0=duty-modulated square, 1=saw, else triangle
    duty_base*, duty_step*, duty_depth*, duty_phase0*, duty_acc*: uint8
    duty_thresh*: uint32    # square duty threshold vs the 32-bit phase (per frame)
    phase_u*:     uint32    # oscillator phase accumulator (2^32 = one period)
    synth_step*:  uint32    # phase step per 32768 Hz output sample
    saw_step*:    uint32    # phase step per SOURCE-rate sample (saw IIR sim)
    saw_iir*:     int32     # saw shaper state (the driver's r2 = r9 + r2>>1)
    src_carry*:   float32   # source-rate clock remainder for the saw sim
    wave_data*:   uint32    # sample data start (WaveData + 16)
    rom_off*:     uint32
    in_rom*:      bool
    sample_count*: uint32   # WaveData.size
    loop_start*:  uint32    # WaveData.loopStart
    looping*:     bool
    freq*:        uint32    # channel playback rate, Hz
    freq_step*:   float32   # per-output-sample step (source samples or phase)
    src_index*:   uint32
    phase_frac*:  float32
    need_fetch*:  bool
    tap0*, tap1*, tap2*, tap3*: float32
    vol_l0*, vol_l1*: float32
    vol_r0*, vol_r1*: float32
    age*:         int

  GsRevModel* = enum
    ## Which reverb algorithm a Bon-driver build ships (see gs_bon.nim):
    grmParsedShift   # GS1: seed gains are runtime-patched asr instructions,
                     # live-parsed from the IWRAM code every frame

  GsBonHle* = ref object
    gba* {.cursor.}: GBA
    engaged*:    bool
    build*:      int        # index into gs_bon.nim's GS_BUILDS table
    fp_addr*:    uint32     # fingerprint match base found by the IWRAM scan;
                            # every per-build hook/parse address is an offset
                            # from this (regional builds relocate the block)
    hook_addr*:  uint32     # mixer per-channel entry PC (fingerprint-selected)
    sound_info*: uint32
    fp_fails*:   int        # fingerprint mismatches while the magic is present
    fp_give_up*: bool
    resync_pending*: bool
    samplers*:   array[12, GsBonSampler]
    frame_len*:  int
    frame_pos*:  int
    engaged_frames*: int
    dbg_hook_fires*: int
    dbg_synth_chframes*: int   # channel-frames where a synth instrument was live
    dbg_waves*: seq[uint32]    # distinct WaveData pointers observed (mp2kwav builds)
    reverb_strength*: uint8
    rev_period*: int        # DMA ring length in frames = SoundInfo.pcmDmaPeriod
    rev_model*:  GsRevModel # per-build reverb algorithm (set at engage)
    rev_insn_addr*: uint32  # grmParsedShift: addr of the runtime-patched reverb
                            # tap instructions (0 = reverb off, a DIAG state)
    rev_coef_new*: float32  # 1-frame same-side tap gain (parsed from live code)
    rev_coef_old*: float32  # (P+1)-frame cross-side tap gain (parsed from live code)
    src_rate*:   int        # SoundInfo.pcmFreq (the driver's native mix rate)
    div_freq*:   uint32     # SoundInfo divFreq: per-Hz resampler step (9.23)
    makeup*:     float32    # DIAG: output makeup gain override (0 => per-build)
    db_delay_ovr*: bool     # DIAG: harness set db_delay; engage must not touch it
    # grmParsedShift wet-history ring: rev_period+1 slots of GS_REV_SLOT_LEN
    # stereo samples (see gs_bon.nim gs_render_sample).
    rev_ring*:   seq[float32]
    rev_slot*:   int        # slot being written this mixer pass
    rev_pos*:    int        # intra-frame sample index within the slot
    out_delay*:  seq[int16]
    out_delay_w*: int
    db_delay*:   int

  Cartridge* = ref object
    rom_identity*: uint32  ## FNV-1a of the first 1 MB of the ROM as read
                           ## from disk, the state header's identity. The
                           ## save-state identities read these, never `rom`:
                           ## cheats patch that buffer in place
                           ## (gba_rom_checksum).
    rom_identity_whole*: uint32  ## FNV-1a of the whole file, the states'
                                 ## whole-ROM trailer (gba_whole_rom)
    rom*: seq[byte]        ## sized to the next power of two >= the ROM file
    rom_mask*: uint32      ## rom.len - 1
    rom_size*: int         ## bytes read from the file (no pad, no Classic NES
                           ## mirrors); the netplay CRC and the save-state
                           ## identity hash exactly this range

  GBA* = ref object of EmuObj
    # Events dispatched (wrapping) and cpu.r[15] at the last one: the
    # waitloop detector's staleness test (waitloop.nim)
    dispatch_count*:   uint32
    dma_bursts*:       uint32   # DMA bursts granted (waitloop_skip's steadiness)
    dyn_kinds*:        uint64   # event kinds dispatched since dyn_loop armed
    verdict_kinds*:    uint64   # ... and since analyze_loop's last verdict
    last_dispatch_pc*: uint32
    # WL_QUIET_EVENTS: since the detector last looked, something ran that
    # could change what a loop reads (an event not known to leave memory
    # alone, a DMA, an IO read). Not serialized: a state load sets it.
    wl_unsafe*:        bool
    bios_path*:  string
    rom_path*:   string
    run_bios*:   bool
    use_hle*:        bool
    hle_after_bios*: bool
    scheduler*:      Scheduler
    # Cycle the current frame started at; frame progress derives from it.
    frame_start_cycles*: CycleCount
    # Total end_frame has subtracted since power-on: rebased +
    # scheduler.cycles is an absolute clock for debug tools comparing runs
    # (tools/playtest dingbat_driver `trace`, tests/biosdrv_probe.nim). Not
    # serialized.
    rebased*: int64
    # Last state payload's length: the next buffer starts at that capacity
    # (savestate.nim)
    payload_len_hint: int
    cartridge*:  Cartridge
    storage*:    Storage
    mmio*:       MMIO
    timer*:      Timer
    keypad*:     Keypad
    bus*:        Bus
    interrupts*: Interrupts
    cpu*:        CPU
    ppu*:        PPU
    apu*:        APU
    # MP2K/M4A sound-engine HLE (off by default), mp2k.nim
    mp2k*:       Mp2kHle
    mp2k_hle*:   bool
    # Camelot "Bon" driver HLE (Golden Sun), gs_bon.nim
    gs_bon*:     GsBonHle
    dma*:        DMA
    serial*:     Serial
    cheats*:     CheatEngine
    cheat_hooks: MemHooks        # built once, reused each frame (see apply_cheats)
    when defined(test_harness):
      test_output*: TestOutput

# The fields tick tests before every opcode. Setters keep cpu_slow, so the
# common case is one test. Getters are procs, not templates, so `+=` can't
# skip the setter.
proc set_cpu_slow(cpu: CPU) {.inline.} =
  cpu.cpu_slow = cpu.halted_v or cpu.irq_line_v or cpu.halt_wake_v or
                 cpu.intr_wait_active_v or cpu.halt_resume_charge_v != 0
proc halted*(cpu: CPU): bool {.inline.} = cpu.halted_v
proc irq_line*(cpu: CPU): bool {.inline.} = cpu.irq_line_v
proc halt_wake*(cpu: CPU): bool {.inline.} = cpu.halt_wake_v
proc intr_wait_active*(cpu: CPU): bool {.inline.} = cpu.intr_wait_active_v
proc halt_resume_charge*(cpu: CPU): int32 {.inline.} = cpu.halt_resume_charge_v
proc `halted=`*(cpu: CPU; v: bool) {.inline.} =
  cpu.halted_v = v
  cpu.set_cpu_slow()
proc `irq_line=`*(cpu: CPU; v: bool) {.inline.} =
  cpu.irq_line_v = v
  cpu.set_cpu_slow()
proc `halt_wake=`*(cpu: CPU; v: bool) {.inline.} =
  cpu.halt_wake_v = v
  cpu.set_cpu_slow()
proc `intr_wait_active=`*(cpu: CPU; v: bool) {.inline.} =
  cpu.intr_wait_active_v = v
  cpu.set_cpu_slow()
proc `halt_resume_charge=`*(cpu: CPU; v: int32) {.inline.} =
  cpu.halt_resume_charge_v = v
  cpu.set_cpu_slow()

# Forward declarations to handle circular include dependencies
proc irq*(cpu: CPU)
proc irq_enter*(cpu: CPU)
proc und*(cpu: CPU)
proc run_pending*(dma: DMA)
proc schedule_interrupt_check*(intr: Interrupts; delay: int = 0)
proc window_open_event*(intr: Interrupts)
proc window_close_event*(intr: Interrupts)
proc fifo_window_open*(dc: DMAChannels)
proc window_ahead*(intr: Interrupts; raise_in: int)
proc unstall*(intr: Interrupts; ran: int)
proc imm_refill_handover*(bus: Bus)
proc read_open_bus_word*(bus: Bus; address: uint32): uint32
proc read_open_bus_value*(bus: Bus; address: uint32): uint8
when defined(obuslatch):
  proc obus_drive_word*(bus: Bus; value: uint32) {.inline.}
  proc obus_drive_half*(bus: Bus; address: uint32; value: uint16) {.inline.}
proc rom_cool*(bus: Bus) {.inline.}
proc wl_passable(gba: GBA; kind: EventType): bool
proc dyn_loop*(cpu: CPU; start_addr, end_addr: uint32; arm: bool)
# pf_serve is on the ROM fetch slow path (once per instruction outside a hot
# stream); clang left it out of line, ~1% of retired instructions. Forced on
# clang only (GCC makes a failed always_inline a hard error).
when defined(clang):
  {.pragma: pf_inline, inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".}
else:
  {.pragma: pf_inline, inline.}
proc pf_serve(bus: Bus; now: CycleCount; page: int; halves: int): int {.pf_inline.}

# A branch into the gamepak refills N then S, in that order (cpu.clear_pipeline).
const ROM_REFILL_ORDERED* {.booldefine.} = true
const BRANCH_COMMIT_WAIT* {.booldefine.} = true
  ## A branch out of a gamepak stream waits out a prefetch halfword in its
  ## final cycle (cpu.clear_pipeline). Off: Final Fight One lands 9.7k
  ## cycles sooner, still a frame behind the reference runs
  ## (docs/dev/playtest-bugs.md section 29).
const ROM_REFILL_ORDERED_PF* {.booldefine.} = true
const DMA_KEEPS_PREFETCH* {.booldefine.} = true
  ## A DMA that never touches the gamepak leaves the prefetcher running: the
  ## CPU's stream is not broken and the burst's cycles are prefetch time
  ## (tests/roms/payloads/slotdma.s at WAITCNT 0x4000).
const PREFETCH_TOGGLE_LAW* {.booldefine.} = true
  ## WAITCNT switching the prefetcher off keeps the buffer until the CPU
  ## drains it; switching it on after idle cycles breaks the burst
  ## (bus.write_waitcnt). Hardware: AGBEEG aging cartridge
  ## (toggle_prefetcher). Pinned by alyosha timing/prefetch_enable.
const HALT_WAKE_RUNS_ONE* {.booldefine.} = true
  ## An interrupt that wakes a halted CPU is taken one instruction after the
  ## wake, not at it (cpu.tick; tests/roms/payloads/wakeirq.s).
const IRQ_FETCH_VIA_PREFETCH* {.booldefine.} = true
  ## The IRQ entry's in-flight gamepak fetch comes from the prefetcher when
  ## it runs on the interrupted stream (cpu.irq).
const FIFO_FETCH_WINDOW* {.booldefine.} = true
  ## FIFO_DMA_WINDOW's rule (a refill request landing in a CPU access begun
  ## before its request cycle is granted at the access's end; one begun on
  ## it waits the whole burst) applied to opcode fetches from board WRAM and
  ## the gamepak too: the grant waits for any access in flight (slotdma.s).
  ## While a FIFO window is open (FIFO_WINDOW_LEAD cycles before a request)
  ## those fetches leave the fetch cache and sync to their end, as
  ## IMM_FETCH_WAIT's do. AGB SP, kit3 (flash cart, 3/1) and the empty-slot
  ## 4/2 sled: with the prefetcher off the interrupt lands on the sled's
  ## 4-cycle grid after the burst, which a mid-fetch grant cannot give
  ## (docs/dev/hwprobe-questions.md, fifo_6). Pinned by alyosha fifo_dma/*.
const FIFO_IRQ_PF_EXTRA* {.intdefine.} = 1
  ## With FIFO_FETCH_WINDOW: a FIFO burst's end interrupt comes a cycle later
  ## when the CPU runs from the gamepak through the prefetcher (AGB SP, kit3
  ## 3/1 and empty-slot 4/2 DMA-end cells: every phase but the request-cycle
  ## one reads a cycle short without it). That phase (the prefetcher wait
  ## began the cycle before the grant) is PF_WAIT_UNDER_BURST's: no extra.
const PF_WAIT_UNDER_BURST* {.booldefine.} = true
  ## A sound-FIFO burst off the gamepak, granted while the CPU waits on the
  ## prefetcher for an opcode, with the wait begun the cycle before the
  ## grant or later: the wait runs under the burst (the prefetcher fills,
  ## DMA_KEEPS_PREFETCH). A wait begun that cycle before also gives the CPU
  ## the cycle back, and its interrupt synchroniser: an IRQ raised under the
  ## burst is recognised a cycle sooner. A wait begun earlier is
  ## FIFO_FETCH_WINDOW's. AGB SP, payloads/f6q.s and f6slot.s (empty-slot NV
  ## sled 4/2; kit3 cart sled 3/1): the phase whose fetch begins a cycle
  ## before the grant (d = 2, 6, 10) reads the handler 5 cycles sooner than
  ## a wait frozen at the grant. Refuted: resuming a wait begun before the
  ## stop after the burst (354 cells lost).
const IRQ_FETCH_STOPPED_BUFFER* {.booldefine.} = true
  ## A full, stopped prefetch buffer still holding the in-flight opcode
  ## serves the IRQ entry's fetch, as a running one does
  ## (IRQ_FETCH_VIA_PREFETCH). AGB SP, f6q.s: TM3's IRQ just after a 30-cycle
  ## FIFO burst (which filled the buffer) enters 7 cycles sooner than an N
  ## fetch gives.
const IRQ_INFLIGHT_SEQ* {.booldefine.} = true
  ## An IRQ entry's in-flight gamepak fetch not served by the prefetcher
  ## costs N or S as the stream makes it, less the cycle the entry overlaps
  ## (also after a burst or a prefetcher-stopping load); off, a flat 2*S16
  ## (cpu.irq_enter).
const PF_RUNS_OFF_ROM* {.booldefine.} = true
  ## The gamepak prefetcher keeps fetching while the CPU runs from BIOS or
  ## RAM, at the address the CPU would have fetched next; a branch back
  ## there takes what it fetched (cpu.clear_pipeline).
const THUMB_RESTORE_RUNS_NEXT* {.booldefine.} = true
  ## A Thumb `cmp pc` whose SPSR restore clears T still runs the next
  ## halfword as Thumb before ARM takes over (thumb.nim).
const S_BIT_IRQ_LATE* {.booldefine.} = true
  ## An S-bit CPSR restore that sets I still lets an interrupt already
  ## recognised be taken after it (arm.exception_return_restore).
const HALT_ENTRY_STALL* {.intdefine.} = 2
  ## Cycles a HALTCNT write stalls the CPU before the halt can end (mmio.nim).
const HALT_WAKE_INSTR_COST* = 3
  ## What that instruction costs in Nintendo's BIOS: `bx lr` after Halt's
  ## HALTCNT write, `bl` after IntrWait's. The HLE charges it by number.
const IRQ_ENTRY_EXTRA* {.intdefine.} = 1
  ## Cycles an IRQ entry costs beyond its pipeline refill (cpu.irq).
const DMA_ACCESS_WINDOW* {.booldefine.} = true
const REFILL_WINDOW_SPLIT* {.booldefine.} = true
  ## With the access window open, a pipeline refill outside the gamepak is
  ## two fetches a PPU-timed DMA can be granted between (cpu.window_refill),
  ## not one block. AGB SP, hdmalag.s configuration 29: DMA1 (3 words) and
  ## DMA3 (302 halfwords) every H-blank leave an IWRAM `blo` loop 3 cycles a
  ## line, and every burst starts on its H-blank's cycle, 20 lines running
  ## (docs/dev/playtest-bugs.md section 42). ppu.start_hblank clears a leftover
  ## `window_closing` so the next line's window opens.
const SB_SWAP* = 64'u8
  ## bus.sync_bits bit 6: MEMCNT's swap is on (bus.nim, swap_read_word).
const DMA_LEAD_CYCLES* {.intdefine.} = 1
  ## Of a burst's two hand-off cycles, how many come before its first
  ## transfer; the rest follow its last. Both in front lands the DMA's
  ## writes a cycle late (payloads/tmrw.s timer-stop stamps).
  ## DMA_ACCESS_WINDOW: a PPU-timed DMA is granted at the end of the bus
  ## access in flight, not at its request (payloads/dmaphase.s, hdmastamp.s).
  ## That needs a scheduler sync per access, paid only from the H-blank's
  ## start to the request, with such a DMA armed.
const DMA_STALLS_IRQ_SYNC* {.booldefine.} = true
  ## The stall gives back internal cycles the CPU ran under the burst
  ## (Interrupts.unstall); pinned by alyosha Interactions
  ## Internal_Cycle_DMA_IRQ_*. The access the CPU was waiting to make is
  ## IRQ_LAST_WAITS's.
# The output sample clock (apu.nim); the waitloop skip reads the period too
const APU_SAMPLE_RATE*    = 32768
const CPU_CLOCK_SPEED*    = 1 shl 24
const APU_SAMPLE_PERIOD*  = CPU_CLOCK_SPEED div APU_SAMPLE_RATE
const WL_VOLATILE_REST* = 32
  ## Iterations of a loop not judged after one read something volatile
const WL_BODY_MAX* = 30
  ## Longest Thumb loop body (bytes before its branch) the waitloop detector
  ## judges; Adventures of Mr. Bean's IO poll is 22
const DYN_BODY_MAX* = 512
  ## The longest loop (bytes before its branch) the dynamic check takes on
const DYN_FIRST* = 1024
  ## Cycles an armed dynamic check waits for its loop's first return; after
  ## that, twice its period
const DYN_REST* = 64
  ## Arrivals a loop that failed the dynamic check is not checked again
const WL_ARM_BODY_MAX* = 32
  ## The same for ARM loops (eight instructions before the branch)
const WL_CROSS_PERIOD_MAX* = 46
  ## Longest loop period a skip crosses anything but output samples in
  ## (cpu.wl_crossable): shorter than every booking a passable handler makes
  ## (wl_passable) besides its +0 and +2 chains, so none lands inside the
  ## skipped iteration. The shortest is HBLANK_FLAG_DELAY (47).
const
  IO_PPU_STATUS* = 1'u8   ## DISPSTAT, VCOUNT (bus.io_read)
  IO_KEYPAD*     = 2'u8   ## KEYINPUT, KEYCNT: change only between frames
  IO_OTHER*      = 128'u8
const WL_QUIET_EVENTS* {.booldefine.} = true
  ## An event after the loop's load is harmless to the waitloop detector if
  ## it writes no memory, no DMA ran, and the loop read no IO
  ## (waitloop.analyze_loop).
const IRQ_LAST_WAITS* {.booldefine.} = true
  ## An interrupt is taken after an instruction only if recognised before
  ## the wait states of its last bus access; one recognised during them
  ## waits an instruction (a wait-stated access is one stretched cycle,
  ## sampled as it begins). AGB SP, payloads/irqwait.s: a TM0 IRQ breaks
  ## into a NOP sled one NOP later from EWRAM (ARM 5 waits per fetch, Thumb
  ## 2) than cycles alone say, at every phase; from IWRAM (no waits), not.
  ## Pinned by alyosha ppu/start_up_vbl_irq and Interactions
  ## Internal_Cycle_DMA_IRQ*. Cost only while an IRQ is on its way: a window
  ## (bus.sync_bits bit 3), opened by schedule_interrupt_check or
  ## IRQ_WINDOW_LEAD cycles before a timer/PPU raise, has fetches and stores
  ## note their wait states. FireRed: +0.06% retired instructions.
const DMA_READS_CPU_BUS* {.booldefine.} = true
  ## A DMA read of unmapped memory returns what is on the data bus: the last
  ## word the burst itself moved, or, for its first transfer, the CPU's last
  ## bus transaction -- its data load if that came after its last opcode
  ## fetch, else the fetched opcode (Bus.dma_bus_word).
const DMA_BUS_BACK_TO_BACK* {.booldefine.} = true
  ## Bursts granted back to back with no CPU access between (two channels on
  ## one H-blank, a chained immediate pair): the later burst's first
  ## unmapped read gets the earlier one's last word, not the CPU's last
  ## transaction. AGB SP, payloads/hdmalag.s and hdmaobus.s (second channel
  ## reads the first's word every line, CPU in a NOP sled or halted).
  ## Phantasy Star Collection's Master System player needs it: DMA2 copies
  ## write-only BG1VOFS to BG0VOFS right after DMA1 writes it
  ## (docs/dev/playtest-bugs.md section 28).
const DMA_BUS_WHILE_HALTED* {.booldefine.} = true
  ## A halted CPU drives nothing, so the bus keeps the last DMA word until
  ## the CPU runs: a burst granted while the CPU stayed halted since the
  ## previous one reads that word first, not the opcode fetched before the
  ## halt. AGB SP, payloads/hdmaobus.s: an H-blank DMA reading write-only
  ## BG1VOFS ahead of the channel writing X_k there reads X_(k-1) under a
  ## halt (cells 0x301-0x305); the BIOS's fetched literal (0x0300) only on
  ## the first line (0x300).
const DMA_READS_IO_LOAD* {.booldefine.} = true
  ## DMA_READS_CPU_BUS's data load includes an I/O register's: the burst
  ## finds the value the CPU read. AGB SP, hdmaobus.s: an H-blank DMA reading
  ## write-only BG1VOFS while the CPU polls VCOUNT with `ldrh` reads the line
  ## number (cell 0x306, line 46: 002E), not the `bne` opcode (1AFF). The I/O
  ## bus is 32 bits: hdmaphase.s, an `ldrh`/`ldrb` of VCOUNT leaves DISPSTAT
  ## on the other half too (Bus.dma_bus_word).
const DMA_SEES_REFILL_FETCH* {.booldefine.} = true
  ## A refill is two fetches; a burst requested between them finds the first
  ## on the bus. The core charges the refill as one block with r15 past both,
  ## so a burst granted by a branch's closing tick with a refill fetch still
  ## to start reads one fetch further back. AGB SP, hdmaphase.s (H-blank DMA
  ## reading write-only I/O against an IWRAM `bne` loop): a request one
  ## cycle before the loop's end reads the branch target, not the second
  ## opcode (n = 1 cases, every load width, either half).
const IMM_BOUNDARY_GRANT* {.booldefine.} = true
  ## An immediate DMA whose request (two cycles after the enable) falls
  ## exactly between instructions is granted there, ahead of the next fetch,
  ## not a cycle later as for an access in flight. AGB SP, dmaobus2.s
  ## (enable store, then one-cycle IWRAM instructions): the burst's word is
  ## the opcodes fetched before the third instruction (Thumb 31033104, ARM
  ## E2811004), not one fetch later (31053104, E2811005). Pinned by alyosha
  ## prefetcher/prefetcher_dma and AGBEEG cpu_runs_idles_during_dma.
const IMM_FAST_FETCH_GRANT* {.booldefine.} = true
  ## An immediate DMA whose request comes due inside an IWRAM or BIOS
  ## instruction, in no synced access (a branch's refill), is granted on
  ## that cycle: those one-cycle fetches start with the request and lose the
  ## bus (IMM_ACCESS_WAIT's rule). AGB SP, payloads/dmairqk.s (DMA3 armed by
  ## a word or CNT_H store, k NOPs, branch into an IWRAM sled): with k = 0, 1
  ## the end interrupt lands on the same cycle as with k >= 2; dmairqv.s's
  ## d >= 2 cells agree. Off: 28 cells read one to three cycles late.
const DMA_CHAIN* {.booldefine.} = true
  ## An immediate DMA due while another burst holds the bus follows it
  ## directly: the pair pays one lead and one hand-back. AGB SP,
  ## payloads/tmrdma.s (DMA0 armed during DMA1's burst): DMA0 reads the
  ## timer DMA1 enabled on the next cycle (old count, new control), and the
  ## CPU is back two cycles sooner than for separate bursts.
const DMA_PENDING_CHAIN* {.booldefine.} = true
  ## DMA_CHAIN for a request already latched at a burst's grant: the next
  ## grant follows with no hand-back or lead. A request arriving during the
  ## burst still pays both (unmeasured; chaining it moved Pokemon Mystery
  ## Dungeon - Red Rescue Team's timing-seeded quiz under the real BIOS).
  ## AGB SP, two channels on one H-blank: hdmalag.s, the second's first read
  ## is the cycle after the first's last write; hdmaphase.s, a one-halfword
  ## reader and writer hold the CPU 10 cycles (reader alone 6), not 12.
const IMM_ACCESS_WAIT* {.booldefine.} = true
  ## An immediate DMA whose request lands inside a CPU data access begun
  ## before it waits for the access to end, which sees pre-burst memory; an
  ## access beginning on the request cycle loses the bus. AGB SP,
  ## payloads/dmastart.s: an EWRAM ldr/ldrh/str right after the enable store
  ## delays the burst by its length less one and reads the old word; a nop
  ## before the ldr, or an ldm's second access, lets the burst in first.
const IMM_FETCH_WAIT* {.booldefine.} = true
  ## An immediate DMA whose request lands inside an instruction fetch waits
  ## for the whole fetch (as IMM_ACCESS_WAIT) and takes the bus as it ends.
  ## AGB SP: payloads/hadesdsd.s (Hades-Tests dma-start-delay from board
  ## WRAM) reads TM0 after the whole 6-cycle ARM fetch, CPU back on the same
  ## cycle; slotimm.s (Thumb store from the empty slot) has the request in a
  ## 5-cycle gamepak fetch and the DMA at its end (prefetcher on: 2-cycle
  ## fetch, burst at its end). Pinned by Hades dma-start-delay's ROM cases.
const IMM_IDLE_GRANT* {.booldefine.} = true
  ## An immediate DMA requests the bus two cycles after its enable write. If
  ## the CPU is in internal cycles then, the burst starts there and they run
  ## under it; with a gamepak access in flight it starts on the third cycle
  ## (mGBA suite Trivial DMA; other accesses: IMM_ACCESS_WAIT). AGB SP,
  ## payloads/irqstorm.s (enable, then an IWRAM `ldr` whose internal cycle is
  ## the third): the CPU leaves every burst (1 to 4096 words) a cycle sooner
  ## than a third-cycle start gives. Pinned by Hades dma-start-delay's IWRAM
  ## cases.
const DMA_REGRAB* {.intdefine.} = 0
  ## A PPU-timed request landing within this many cycles of the last burst's
  ## end is granted at once, not deferred to the end of the CPU access in
  ## flight. 0 is pinned by alyosha DMA_pause_timing_end_3/_4.
proc add_cycles*(bus: Bus; n: int) {.inline.}
proc idle_window*(bus: Bus; n: int)
proc `[]`*(bus: Bus; address: uint32): uint8
proc `[]=`*(bus: Bus; address: uint32; value: uint8)
proc read_half*(bus: Bus; address: uint32): uint16
proc read_word*(bus: Bus; address: uint32): uint32
# clang left fetch_half/fetch_word out of line (two calls per fetch). Forcing
# them inline: -3.4% retired instructions on FireRed native, +4% fps on web
# (clang only: GCC makes a failed always_inline a hard error).
when defined(clang):
  {.pragma: fetch_inline, inline, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".}
else:
  {.pragma: fetch_inline, inline.}
proc fetch_half*(bus: Bus; address: uint32): uint16 {.fetch_inline.}
proc fetch_word*(bus: Bus; address: uint32): uint32 {.fetch_inline.}
proc read_word_rotate*(bus: Bus; address: uint32): uint32
proc read_half_rotate*(bus: Bus; address: uint32): uint32
proc read_half_signed*(bus: Bus; address: uint32): uint32
proc read_byte_internal*(bus: Bus; address: uint32): uint8 {.inline.}
proc read_word_internal*(bus: Bus; address: uint32): uint32 {.inline.}
proc write_byte_internal*(bus: Bus; address: uint32; value: uint8)
proc write_half_internal*(bus: Bus; address: uint32; value: uint16)
proc write_word_internal*(bus: Bus; address: uint32; value: uint32)
proc sd_tw_begin*(bus: Bus; a0: uint32; n: int)
proc sd_tw_rec*(bus: Bus; o: int; t: int; v: uint8) {.inline.}
proc sd_tw_word*(bus: Bus; address: uint32; word: uint32): uint32
proc `[]`*(mmio: MMIO; address: uint32): uint8
proc `[]=`*(mmio: MMIO; address: uint32; value: uint8)
proc timer_overflow*(apu: APU; timer: int): bool
proc tick_frame_sequencer*(apu: APU)
proc get_sample*(apu: APU)
proc apu_park_steps*(apu: APU)
proc apu_catchup_all*(apu: APU) {.inline.}
proc apu_next_step*(apu: APU): CycleCount {.inline.}
proc new_mp2k*(gba: GBA): Mp2kHle
proc init_mp2k*(m: Mp2kHle)
proc render_frame(m: Mp2kHle)
proc mp2k_sound_write*(m: Mp2kHle; a: uint32; w: int; v: uint32) {.noinline.}
when defined(mp2kwcensus):
  proc mp2k_wc_write*(m: Mp2kHle; a: uint32; w: int) {.noinline.}
proc mp2k_frame_poll*(m: Mp2kHle)
proc mixer_live*(m: Mp2kHle): bool
proc render_sample*(m: Mp2kHle): tuple[l: int16, r: int16]
proc new_gs_bon*(gba: GBA): GsBonHle
proc init_gs_bon*(g: GsBonHle)
proc gs_mixer_hook*(g: GsBonHle)
proc gs_frame_poll*(g: GsBonHle)
proc gs_render_sample*(g: GsBonHle): tuple[l: int16, r: int16]
proc trigger_hdma*(dma: DMA)
proc trigger_vdma*(dma: DMA)
proc request_immediate*(dma: DMA; reschedule = false)
proc trigger_video_capture*(dma: DMA; vcount: uint16)
proc catch_up(bus: Bus) {.inline.}
proc catch_up_access(bus: Bus; cost: int) {.inline.}
proc imm_post_grant(bus: Bus) {.noinline.}
proc window_fetch_sync(bus: Bus; cost: int)
proc imm_pre_grant(bus: Bus; cost: int) {.noinline.}
proc serial_transfer_complete*(serial: Serial)
proc trigger_fifo*(dma: DMA; fifo_channel: int)
proc bitmap*(ppu: PPU): bool
proc oam_touched*(ppu: PPU) {.inline.}
proc cont_obj_entry_moved(ppu: PPU; e: int; old0, old1: uint16)
proc draw*(ppu: PPU)
proc scanline*(ppu: PPU)
proc start_line*(ppu: PPU)
proc start_hblank*(ppu: PPU)
proc set_hblank_flag*(ppu: PPU)
proc end_hblank*(ppu: PPU)
proc write_half*(bus: Bus; address: uint32; value: uint16)
proc write_word*(bus: Bus; address: uint32; value: uint32)
proc fill_pipeline*(cpu: CPU) {.inline.}
proc read_half_internal*(bus: Bus; address: uint32): uint16 {.inline.}
proc check_cond*(cpu: CPU; cond: uint32): bool {.inline.}
proc step_arm*(cpu: CPU) {.inline.}
proc step_thumb*(cpu: CPU) {.inline.}
proc set_reg*(cpu: CPU; reg: int; value: uint32): uint32 {.discardable, inline.}
proc idle*(cpu: CPU; n: int) {.inline.}
proc mul_i_cycles*(rs: uint32; signed_early_term: bool): int {.inline.}
proc set_neg_and_zero_flags*(cpu: CPU; value: uint32) {.inline.}
proc switch_mode*(cpu: CPU; new_mode: CpuMode)
proc undef_mode_tick*(cpu: CPU)
proc lsl*(cpu: CPU; word: uint32; bits: uint32; carry_out: ptr bool): uint32 {.inline.}
proc lsr*(cpu: CPU; word: uint32; bits: uint32; immediate: bool; carry_out: ptr bool): uint32 {.inline.}
proc asr*(cpu: CPU; word: uint32; bits: uint32; immediate: bool; carry_out: ptr bool): uint32 {.inline.}
proc ror*(cpu: CPU; word: uint32; bits: uint32; immediate: bool; carry_out: ptr bool): uint32 {.inline.}
proc sub*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 {.inline.}
proc sbc*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 {.inline.}
proc add*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 {.inline.}
proc adc*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 {.inline.}
proc clear_pipeline*(cpu: CPU)
# Renderer contention's wait for one access (contention.nim)
proc contend_wait(bus: Bus; address: uint32; is32: bool; cost: int): int
proc contend_wait_ahead*(bus: Bus; address: uint32; is32: bool; ahead: int): int
proc contend_slow(bus: Bus; address: uint32; is32: bool; cost: int): int {.noinline, raises: [].}
proc hle_halt_return*(cpu: CPU)
proc exception_return_restore*(cpu: CPU)
proc read_instr*(cpu: CPU): uint32 {.inline.}
# The bank an undefined CPSR mode pattern selects: r13 and r14 read 0 and the
# mode field holds the pattern (AGB SP, gbaedge UNDMODE, patterns 15/1A/1E,
# docs/dev/hwprobe-results-agb.md). Zeroed on entry, so nothing written survives;
# r8-r12 and SPSR are unprobed and follow the user bank. Never serialized.
const UNDEF_BANK* = 6
# The stub BIOS's room for the HLE's decompression and unpack routines
# (hle_unc.nim, filled in bus.nim new_bus): ARM instructions, then Thumb ones
const UNC_ARM_LO* = 0x0C00'u32
const UNC_ARM_HI* = 0x1530'u32
const UNC_THUMB_LO* = 0x3A00'u32
const UNC_THUMB_HI* = 0x4000'u32
proc mode_bank*(m: CpuMode): int

# Textual includes: the core is one module so the C compiler inlines across
# files (docs/dev/notes/architecture.md). Order is free except:
#   * hle_bios before arm/arm and thumb/thumb: both SWI handlers call
#     hle_swi, which has no forward declaration.
#   * arm/arm before arm/lut: `const armLut = armLutBuilder()` resolves the
#     arm_* handlers at compile time; a const cannot be forward-declared.

# CPU fetch pipeline
template note_waits*(bus: Bus; cost: int) =
  ## IRQ_LAST_WAITS: a CPU access of `cost` cycles just ended.
  bus.lw_end = bus.sched.cycles + CycleCount(bus.cycles)
  # An uncached fetch that synced on the way (a FIFO window inside the IRQ
  # one) already handed its cycles over and reads as 0: no waits to note,
  # and a state carries 0..1023.
  bus.lw_waits = max(cost - 1, 0)

when defined(cpu_testbus):
  # -d:cpu_testbus, the single-instruction test build
  # (tests/singlestep_test.nim): every CPU access goes here instead of the
  # memory map. `kind`: 0 opcode fetch, 1 load. `peek`: untimed reads
  # (read_*_internal). `refill`: clear_pipeline, charging the two refill
  # fetches without making them. Compiled out of every other build.
  var gba_testbus_read*: proc(kind, size: int; address: uint32): uint32 {.nimcall.}
  var gba_testbus_write*: proc(size: int; address, value: uint32) {.nimcall.}
  var gba_testbus_peek*: proc(size: int; address: uint32): uint32 {.nimcall.}
  var gba_testbus_idle*: proc(n: int) {.nimcall.}
  var gba_testbus_refill*: proc() {.nimcall.}

include pipeline
# Cartridge: ROM image, save memory, GPIO-attached RTC
{.push quirky: off.}
include cartridge
include storage
{.pop.}
include storage/sram
include storage/flash
include storage/eeprom
include storage/none
include storage/pending
include rtc
include gpio
# Interrupt controller + keypad input
include interrupts
include keypad
# CPU decode/execute: idle-loop fast-forward, HLE BIOS, ARM + THUMB cores
include waitloop
include hle_bios
include arm/arm
include arm/lut
include thumb/thumb
include cpu
when defined(mp2kwav):  # throwaway A/B capture buffers (see mp2k.nim)
  var mp2kWavCapture*: seq[int16] = @[]
  var dbgFifoEmpty*: array[2, int]
  var dbgFifoServed*: array[2, int]
  var dbgFifoDrop*: array[2, int]
  var dbgFifoWrites*: array[2, int]
  # Pass placement oracle (DINGBAT_PASSDUMP): FIFO bytes tagged with their DMA
  # source; per pass, the capture index the HLE placed its frame at and the
  # index where the pass's first ring store (kind 0) / the model's slot
  # start (kind 1) left the FIFO.
  var dbgPassStore*: uint32 = 0
  var dbgWatch*: seq[tuple[a: uint32, pass: int, kind: int]] = @[]
  var dbgPassPlaced*: seq[int] = @[]
  var dbgPassReal*: seq[array[2, int]] = @[]
  var dbgPassInfo*: seq[string] = @[]
  var realDmaCapture*: seq[int16] = @[]
  var dbgRetrigCount*: int = 0
  var dbgHookCapIdx*: seq[int] = @[]   # HLE capture length (stereo frames) at each mixer hook
  var dbgHookDmaSrc*: seq[uint32] = @[] # DMA1 internal source cursor at each mixer hook
  var dbgHookDmaSrc2*: seq[uint32] = @[] # DMA2's
  var dbgLatDump*: int = 0
  var dbgHookRing*: seq[uint8] = @[]     # the A half (up to 1584 bytes) as the hook saw it
  var dbgHookSad*: seq[uint32] = @[]    # DMA1 source register at each hook
  var dbgHookSad2*: seq[uint32] = @[]
  var dbgHookCnt*: seq[int] = @[]        # SoundInfo.pcmDmaCounter at each mixer hook
  # Note-on with non-zero SoundChannel.count: did the engine start there
  # (honoured) or at 0 (ignored)? Judged a pass later (apply_pending).
  var dbgStartHonoured*: int = 0
  var dbgStartIgnored*: int = 0
  var dbgStartUnclear*: int = 0
# Audio: PSG channels 1-4 + the two FIFO (DMA) channels, then the mixer
include apu/psg_host
include ../common/psg_channels
include apu/dma_channels
include apu
# Scheduler-driven peripherals: timers, SIO, DMA
include timer
include serial
include dma
# Memory system: bus decode, waitstates, prefetch, open bus
include bus
# Sound-driver HLE shadow mixers (runtime-detected; inert unless enabled)
include mp2k
include gs_bon

proc set_audio_silent*(gba: GBA; on: bool) =
  ## Whether anybody hears this core (APU.silent). Call between frames. The
  ## sound-driver HLEs render nothing while silent, so un-silencing
  ## re-latches their voices from the engine's state, as a state load does.
  if gba.apu.silent and not on:
    if gba.mp2k != nil: gba.mp2k.mp2k_state_loaded()
    if gba.gs_bon != nil: gba.gs_bon.gs_state_loaded()
  gba.apu.silent = on

# Sprite accessor procs (needed by ppu)
proc obj_shape*(s: Sprite): uint32 = bits_range(s.attr0, 14, 15)
proc color_mode_8bpp*(s: Sprite): bool = bit(s.attr0, 13)
proc obj_mode*(s: Sprite): uint32 = bits_range(s.attr0, 10, 11)
proc attr0_bit_9*(s: Sprite): bool = bit(s.attr0, 9)
proc affine*(s: Sprite): bool = bit(s.attr0, 8)
proc affine_mode*(s: Sprite): uint32 = bits_range(s.attr0, 8, 9)
proc y_coord*(s: Sprite): uint32 = bits_range(s.attr0, 0, 7)
proc obj_size*(s: Sprite): uint32 = bits_range(s.attr1, 14, 15)
proc attr1_bits_9_13*(s: Sprite): int = int(bits_range(s.attr1, 9, 13))
proc x_coord*(s: Sprite): uint32 = bits_range(s.attr1, 0, 8)
proc tile_idx*(s: Sprite): uint32 = bits_range(s.attr2, 0, 9)
proc priority*(s: Sprite): uint32 = bits_range(s.attr2, 10, 11)
proc palette_bank*(s: Sprite): uint32 = bits_range(s.attr2, 12, 15)

# Video, then the I/O register dispatch over everything above
include ppu
include contention
include mmio

{.push quirky: off.}
proc new_storage*(gba: GBA; rom_path: string): Storage =
  # changeFileExt, not "up to the last dot": an extensionless path would
  # otherwise give `<parent>.sav` or `.sav`
  let save_path = rom_path.changeFileExt(".sav")
  let content = readFile(rom_path)
  var t = find_storage_type(content)
  when defined(yoshi_eeprom_pin):
    # -d:yoshi_eeprom_pin (off by default): tilt carts save to EEPROM but the
    # string scan can misread them as SRAM (aliasing the tilt registers).
    # Pending a pin-by-game-code policy.
    if gba.cartridge != nil and
       gba.cartridge.game_code() in ["KYGE", "KYGJ", "KYGP", "KHPJ"]:
      t = stEEPROM
  # Several candidate chips: the battery file's size picks one; with no file,
  # the game's save accesses do (storage/pending.nim). A file of no chip's
  # size keeps the scan's guess.
  let candidates = storage_candidates(content)
  let data = if fileExists(save_path): readFile(save_path) else: ""
  var pending = false
  if candidates.card > 1:
    if data.len == 0:
      pending = true
    else:
      let toff = trailer_offset(data.len)
      let chip_len = if toff >= 0: toff else: data.len
      let by_size =
        if chip_len in [0x200, 0x2000]: stEEPROM
        elif chip_len == 0x8000: stSRAM
        elif chip_len == 0x10000: flash_candidate({stFLASH512, stFLASH} * candidates)
        elif chip_len == 0x20000: (if stFLASH1M in candidates: stFLASH1M else: stNone)
        else: stNone
      if by_size != stNone and by_size in candidates:
        t = by_size
  result = if pending: new_pending_storage(gba) else: chip_of(t, gba)
  result.candidates = candidates
  result.no_save_library = names_no_save_library(content)
  result.rtc_cart = rom_has_rtc(content)
  if t == stNone and not pending:
    return   # no chip: no battery file is read or written
  result.save_path = save_path
  if pending:
    return   # no battery file to load
  if data.len > 0:
    # A trailing RTC record (rtc_calendar.nim "Trailer location") is never
    # chip data, even when it does not decode as a clock.
    let toff = trailer_offset(data.len)
    let chip_len = if toff >= 0: toff else: data.len
    if toff >= 0:
      result.has_trailer = true
      for i in 0 ..< RTC_TRAILER_LEN: result.trailer[i] = uint8(data[toff + i])
    let n = min(chip_len, result.memory.len)
    if n > 0: copyMem(addr result.memory[0], unsafeAddr data[0], n)
    if t == stEEPROM and n > 0x200:
      result.eeprom_file_tail = newSeq[byte](n - 0x200)
      copyMem(addr result.eeprom_file_tail[0], unsafeAddr data[0x200], n - 0x200)

proc new_gba*(bios_path, rom_path: string; run_bios: bool; use_hle: bool = false; hle_after_bios: bool = false): GBA =
  result = GBA(
    bios_path:       bios_path,
    rom_path:        rom_path,
    run_bios:        run_bios,
    use_hle:         use_hle,
    hle_after_bios:  hle_after_bios,
  )
  result.scheduler = new_scheduler()
  result.cartridge = new_cartridge(rom_path)
  result.cheats    = new_cheat_engine(cpGBA)
{.pop.}

proc handle_saves*(gba: GBA)

proc defer_dma_request(gba: GBA; kind: EventType): bool =
  ## A PPU-timed DMA request inside a CPU bus access is granted at the
  ## access's end. Only a window sync knows where that is; a halted CPU, an
  ## internal cycle or a closed window leave access_end in the past.
  when DMA_ACCESS_WINDOW:
    let bus = gba.bus
    if bus.dma_deferred and gba.scheduler.cycles != bus.access_end:
      bus.dma_deferred = false       # a deferral whose grant found no channel
    if (bus.sync_bits and 2) != 0 and not gba.cpu.halted and
       bus.access_end > gba.scheduler.cycles and
       gba.scheduler.cycles > bus.dma_end_at + CycleCount(DMA_REGRAB):
      bus.dma_deferred = true
      bus.dma_deferred_from = gba.scheduler.cycles
      gba.scheduler.schedule(int(bus.access_end - gba.scheduler.cycles), kind)
      return true
  false

proc defer_fifo_request(gba: GBA; kind: EventType): bool =
  ## FIFO_DMA_WINDOW (gba/apu/dma_channels.nim). The refill request takes the
  ## bus a cycle before this event (FIFO_DMA_REQUEST_DELAY counts to the
  ## first cycle the CPU can lose): an access begun before that cycle holds
  ## the burst off to its end, and an internal cycle on it runs under the
  ## burst; an access begun on it or on this one waits the whole burst. AGB
  ## SP, tests/roms/dbsuite fifodma: EWRAM loads one cycle apart cost the
  ## burst less their internal cycle when holding it off, the whole burst
  ## when begun on it.
  when DMA_ACCESS_WINDOW:
    let bus = gba.bus
    let now = gba.scheduler.cycles
    if bus.dma_deferred and now != bus.access_end:
      bus.dma_deferred = false
    if (bus.sync_bits and 16) != 0 and not gba.cpu.halted:
      if bus.access_end > now:
        if bus.access_start + 2 <= now and now > bus.dma_end_at + CycleCount(DMA_REGRAB):
          bus.dma_deferred = true
          bus.dma_deferred_from = now
          gba.scheduler.schedule(int(bus.access_end - now), kind)
          return true
        bus.dma_before_access = true
      elif bus.access_end == now:
        if bus.access_start + 1 == now: bus.dma_before_access = true
      elif bus.idle_until == now:
        bus.dma_idle_edge = true
  false

static: doAssert WL_CROSS_PERIOD_MAX < HBLANK_FLAG_DELAY

proc wl_passable(gba: GBA; kind: EventType): bool =
  ## Whether a waitloop skip may dispatch `kind` inside a skipped iteration
  ## (cpu.wl_crossable has already required no IO or contended reads, no
  ## open window, no pending IRQ). True only if the handler reads neither
  ## CPU nor bus (so cannot tell where in the loop the CPU is), writes no
  ## memory, raises no IRQ, requests no DMA, opens no window, ends no frame,
  ## and books nothing non-passable inside the iteration (EndHBlank's
  ## StartLine at +0 is passable; SetHBlankFlag's HDMARequest at +2 is
  ## whenever SetHBlankFlag is).
  let ppu = gba.ppu
  let st = ppu.dispstat
  case kind
  of etAPUSample, etAPUFrameSeq, etPPUStartLine: true
  of etPPUStartHBlank:
    # It opens the H-blank / V-blank DMA window. The IRQ windows it books
    # (IRQ_LAST_WAITS) are only bookings: IrqWindowOpen is not passable, and
    # the H-blank one lands 31 cycles on (wl_crossable keeps the period under).
    not (ppu.vcount < 160 and gba.dma.armed(2)) and
      not (ppu.vcount == 159 and gba.dma.armed(1))
  of etPPUSetHBlankFlag:
    not st.hblank_irq_enable and
      (ppu.vcount >= 160 or (not gba.bus.dma_deferred and not gba.dma.armed(2)))
  of etHDMARequest:
    # defer_dma_request reads the CPU's access only for a deferral or with a
    # window open; trigger_hdma requests nothing with no channel armed
    not gba.bus.dma_deferred and not gba.dma.armed(2)
  of etPPUEndHBlank:
    # Not lines 160, 227 or 0 (contention and flags change there); no V-count
    # match to raise, no video capture to request
    let next = (int(ppu.vcount) + 1) mod 228
    next != 0 and next != 160 and next != 227 and
      not (st.vcounter_irq_enable and next == int(st.vcount_setting)) and
      not (gba.dma.dmacnt_h[3].enable and gba.dma.dmacnt_h[3].start_timing == 3)
  of etTimer0, etTimer1, etTimer2, etTimer3:
    let tim = gba.timer
    let num = ord(kind) - ord(etTimer0)
    let c = tim.tmcnt[num]
    if c.irq_enable: return false
    if num < 3 and tim.tmcnt[num + 1].cascade and tim.tmcnt[num + 1].enable:
      return false
    # Its next overflow lands past the iteration (either reload it may take)
    let reload = max(tim.tmd[num], tim.tmd_prev[num])
    if (0x10000 - int(reload)) * TIMER_PERIODS[c.frequency] < 2 * WL_CROSS_PERIOD_MAX + 2:
      return false
    if num <= 1 and (gba.apu.sound_enabled or not FIFO_MASTER_RESET):
      # A FIFO it drives neither asks for a refill nor books a window for
      # one (dma_channels.timer_overflow): 17 bytes or more before the pop
      let sh = gba.apu.soundcnt_h
      for ch in 0 .. 1:
        let t = if ch == 0: int(sh.dma_sound_a_timer) else: int(sh.dma_sound_b_timer)
        if t == num and gba.apu.dma_channels.sizes[ch] < 17: return false
    true
  else: false

proc gba_dispatch(gba: GBA): proc(kind: EventType) {.closure.} =
  # Non-owning capture: the closure lives on the GBA's scheduler
  let gba {.cursor.} = gba
  result = proc(kind: EventType) =
    gba.dyn_kinds = gba.dyn_kinds or (1'u64 shl ord(kind))
    gba.verdict_kinds = gba.verdict_kinds or (1'u64 shl ord(kind))
    if kind == etFifoWindow:
      # Changes nothing a program can read (FIFO_DMA_WINDOW), so a waitloop
      # need not count it
      gba.apu.dma_channels.fifo_window_open()
      when WL_QUIET_EVENTS: gba.wl_unsafe = true   # but it opens a window
      return
    # Waitloop exactness: when, and at which PC, the last event ran
    inc gba.dispatch_count
    gba.last_dispatch_pc = gba.cpu.r[15]
    # WL_QUIET_EVENTS: PPU line events, APU clocks, the interrupt controller,
    # timers and IRQ windows write no memory (a video-capture DMA marks
    # itself, dma.run_channel; the MP2K render only reads; a FIFO refill is
    # its own event). Every other arm calls wl_mark, as does whatever opens
    # or closes an access window or raises an IF bit, in place
    # (interrupts.nim, ppu.start_hblank, the FIFO window): Duke Nukem Advance
    # (U) [f_5]'s timer overflows open the FIFO window and drew a different
    # frame 251 otherwise. Testing per dispatch instead costs Golden Sun 0.3%.
    template wl_mark() =
      when WL_QUIET_EVENTS: gba.wl_unsafe = true
    case kind
    of etAPUFrameSeq:   gba.apu.tick_frame_sequencer()
    of etAPUSample:     gba.apu.get_sample()
    # PSG channels use next_step deadlines (apu.nim); these arms only serve
    # events in older states, which gba_apply_state drains first.
    of etAPUChannel1, etAPUChannel2, etAPUChannel3, etAPUChannel4: wl_mark()
    of etPPUStartLine:     gba.ppu.start_line()
    of etPPUStartHBlank:   gba.ppu.start_hblank()
    of etPPUSetHBlankFlag: gba.ppu.set_hblank_flag()
    of etPPUEndHBlank:     gba.ppu.end_hblank()
    of etSaves:
      wl_mark()
      gba.handle_saves()
    of etInterrupts:    gba.interrupts.check_interrupts()
    of etTimer0:        gba.timer.timer_overflow_event(0)
    of etTimer1:        gba.timer.timer_overflow_event(1)
    of etTimer2:        gba.timer.timer_overflow_event(2)
    of etTimer3:        gba.timer.timer_overflow_event(3)
    of etSerial:
      wl_mark()
      gba.serial.serial_transfer_complete()
    of etDMA:
      wl_mark()
      when IMM_IDLE_GRANT:
        let bus = gba.bus
        let now = gba.scheduler.cycles
        var at_boundary = false
        when IMM_BOUNDARY_GRANT:
          # Due exactly as an instruction ends (the CPU's closing tick, not an
          # access's sync): the request wins the bus from the next fetch.
          at_boundary = not bus.in_catch_up and gba.scheduler.tick_left == 0 and
                        not gba.cpu.halted
        var in_access = false
        var access_starts = false
        var at_end = false
        when IMM_ACCESS_WAIT:
          # Measured for IWRAM/EWRAM/IO data accesses and (IMM_FETCH_WAIT)
          # EWRAM and gamepak fetches; a gamepak data access keeps the
          # one-cycle wait (none can be in flight at W+2).
          if bus.in_catch_up and not bus.access_rom and not gba.cpu.halted and
             bus.access_start <= now and now <= bus.access_end:
            if bus.access_start == now: access_starts = now < bus.access_end
            elif now < bus.access_end: in_access = true
            else: at_end = true
        if (bus.sync_bits and 4) == 0 and in_access and bus.access_write:
          # A store under way takes effect first; its accessor grants the
          # burst at its end.
          bus.sync_bits = bus.sync_bits or 4
          bus.imm_at = bus.access_end
          bus.imm_post = true
        elif (bus.sync_bits and 4) == 0 and in_access:
          # A load under way reads memory as it was; the CPU's next step at
          # its end hands over (its internal cycle, run under the burst, or an
          # ldm's next access).
          bus.sync_bits = bus.sync_bits or 4
          bus.imm_at = bus.access_end
          bus.imm_pre = true
          gba.scheduler.schedule(int(bus.access_end - now) + 1, etDMA)
        elif (bus.sync_bits and 4) == 0 and at_end and bus.access_write:
          # A store's last cycle: the fetch after it would lose the bus.
          bus.sync_bits = bus.sync_bits or 4
          bus.imm_at = now
          bus.imm_post = true
        elif (bus.sync_bits and 4) == 0 and at_end:
          bus.sync_bits = bus.sync_bits or 4
          bus.imm_at = now
          bus.imm_pre = true
          gba.scheduler.schedule(1, etDMA)
        elif (bus.sync_bits and 4) == 0 and access_starts:
          # An access starting on the request cycle loses the bus to it.
          gba.dma.request_immediate()
        elif (bus.sync_bits and 4) == 0 and not at_boundary and
           not (bus.imm_idle_from <= now and now < bus.imm_idle_until) and
           not (IMM_FAST_FETCH_GRANT and not bus.in_catch_up and not gba.cpu.halted and
                (bus.fetch_page == 0x3 or bus.fetch_page == 0x0)):
          bus.sync_bits = bus.sync_bits or 4
          gba.scheduler.schedule(1, etDMA)
        else:
          bus.sync_bits = bus.sync_bits and not 4'u8
          bus.imm_pre = false
          gba.dma.request_immediate()
      else:
        gba.dma.request_immediate()
    of etRtcSecond:
      wl_mark()
      gba.rtc_irq_poll()
    of etHDMARequest:
      wl_mark()
      if not gba.defer_dma_request(kind): gba.dma.trigger_hdma()
    of etVDMARequest:
      wl_mark()
      if not gba.defer_dma_request(kind): gba.dma.trigger_vdma()
    of etLdmGlitch:
      wl_mark()
      gba.cpu.ldm_glitch_restore()
    of etFifoARequest, etFifoBRequest:
      wl_mark()
      let f = (if kind == etFifoARequest: 0 else: 1)
      let d = gba.dma.dmacnt_h[f + 1]
      if d.enable and d.start_timing == 3:  # Special: a sound DMA to request
        if not gba.defer_fifo_request(kind): gba.dma.trigger_fifo(f)
    of etUndefMode:
      wl_mark()
      gba.cpu.undef_mode_tick()
    of etFifoWindow:    discard   # handled above
    of etIrqWindowOpen:  gba.interrupts.window_open_event()
    of etIrqWindowClose: gba.interrupts.window_close_event()
    of etKeypadIrq:
      wl_mark()
      gba.keypad.keypad_irq_event()
    of etHandleInput, etIME, etCameraDone, etGbLycEdge: wl_mark()

# Timer prescaler phase at ROM entry when the BIOS boot is skipped: the
# prescaler runs free from power-on and is counted from scheduler cycle 0.
# Pinned mod 64 by alyosha timer/timer (passes only at 8 mod 64). Bits above
# 64 are unpinned; 776 is nearest the LLE boot's entry (795 mod 1024:
# 75,997,979 cycles to the first ROM fetch).
const SKIP_BIOS_PRESCALER_PHASE {.intdefine.} = 776

{.push quirky: off.}
proc post_init*(gba: GBA) =
  if not gba.run_bios:
    gba.scheduler.cycles = CycleCount(SKIP_BIOS_PRESCALER_PHASE)
  gba.storage    = new_storage(gba, gba.rom_path)
  gba.mmio       = new_mmio(gba)
  gba.timer      = new_timer(gba)
  gba.keypad     = new_keypad(gba)
  gba.bus        = new_bus(gba, gba.bios_path)
  gba.interrupts = new_interrupts(gba)
  gba.cpu        = new_cpu(gba)
  gba.ppu        = new_ppu(gba)
  gba.apu        = new_apu(gba)
  gba.dma        = new_dma(gba)
  gba.serial     = new_serial(gba)
  gba.scheduler.dispatch = gba_dispatch(gba)
  # Non-owning capture: the pump closure lives on the GBA's scheduler
  let g {.cursor.} = gba
  gba.scheduler.pump = proc() =
    # Inside a DMA burst (clock rewound to the event's cycle) the request
    # stays latched; the burst loop runs run_pending at its next transfer
    if g.dma.pending != 0 and not g.bus.dma_active and not g.bus.swp_lock:
      g.dma.run_pending()
  gba.handle_saves()
  # MP2K HLE: runtime-detected (mp2k.nim); nothing runs unless gba.mp2k_hle
  gba.mp2k = new_mp2k(gba)
  gba.mp2k.init_mp2k()
  # Camelot "Bon" HLE only with -d:gsbon (off by default): its shadow mixer
  # frame-quantizes note attacks, audibly worse on percussion. Consumers
  # nil-check gs_bon, so not creating it is the off-switch.
  when defined(gsbon):
    gba.gs_bon = new_gs_bon(gba)
    gba.gs_bon.init_gs_bon()
  if not gba.run_bios:
    # The state the BIOS leaves at ROM entry: the whole register/RAM diff
    # between a full BIOS boot and a skipped one, the same for every ROM.
    gba.cpu.skip_bios()
    # Link port in general-purpose mode (the BIOS's last RCNT write is
    # 0x8000); from RCNT = 0 Sonic Advance 1 and 2 hang at boot
    gba.serial.rcnt = 0x8000
    # PSG and both DMA channels at full volume (the BIOS's FIFO reset bits
    # are write-only).
    gba.apu.soundcnt_h = cast[SOUNDCNT_H](0x000E'u16)
    # The BIOS clears wave RAM; a cold Channel3 holds the GB power-on pattern
    for i in 0 ..< 2 * PSG_WAVE_BANK:
      gba.apu.channel3.wave_ram[i] = 0
    gba.ppu.skip_boot_phase()
{.pop.}

proc handle_saves*(gba: GBA) =
  gba.scheduler.schedule(280896, etSaves)
  gba.storage.write_save()

proc end_frame*(gba: GBA): CycleCount {.discardable.} =
  ## Frame-boundary bookkeeping: rebase the scheduler and every absolute-cycle
  ## anchor so uint32 cycles cannot overflow on WASM, keeping the low 10 bits
  ## (timer prescaler phase). Returns the base, for link.nim's cross-core
  ## comparisons.
  if gba.ppu.frame > 0: dec gba.ppu.frame
  # PSG next_step deadlines are absolute cycles outside the scheduler: catch
  # up first (all deadlines then lie ahead) and move them with the events.
  # This also bounds how far an unobserved channel lags. end_frame is the
  # only GBA rebase.
  gba.apu.apu_catchup_all()
  # Channel 4's divisor deadline can be in the past (catch-up stops at the
  # last LFSR shift): settle it before the clock moves (as gb_rebase).
  ch4_advance_divisor(gba.apu.channel4, gba)
  let base = gba.scheduler.rebase(keep_phase_mask = 1023)
  gba.rebased += int64(base)
  when defined(switrace): (swtBase += int64(base); inc swtFrame)
  gba.apu.apu_rebase(base)
  # FIFO transfer stamps and the MP2K HLE's slot hooks are absolute too
  for c in 1..2: gba.dma.fifo_xfer_cycle[c] -= int64(base)
  gba.ppu.line_start_cycle -= int64(base)
  if gba.mp2k != nil:
    for i in 0 ..< gba.mp2k.lat_n: gba.mp2k.lat_at[i] -= int64(base)
    for k in 0 .. 3:
      gba.mp2k.watch_pass_cyc[k] -= int64(base)
      gba.apu.dma_channels.watch_cyc[k] -= int64(base)
    gba.mp2k.meas_cyc -= int64(base)
  for i in 0..3:
    if gba.timer.cycle_enabled[i] >= base:
      gba.timer.cycle_enabled[i] -= base
    elif gba.timer.tmcnt[i].enable and not gba.timer.tmcnt[i].cascade:
      # Anchor predates the base: fold the ticks over (anchor, base] into the
      # counter and anchor on cycle 0, in the same prescaler period (base is
      # a multiple of 1024). No overflow can hide there: its event would have
      # re-anchored. The anchor must not land after the rebased clock, or an
      # early read takes the "not started yet" path and answers the reload
      # (payloads/envrestart.s waits on TM2).
      let period = CycleCount(TIMER_PERIODS[gba.timer.tmcnt[i].frequency])
      let k = base div period - gba.timer.cycle_enabled[i] div period
      gba.timer.cycle_enabled[i] = 0
      gba.timer.tm[i] += uint16(k)
    else:
      # Cascade/disabled: the anchor is unused; keep it in range
      gba.timer.cycle_enabled[i] = 0
    if gba.timer.tmd_write_cycle[i] >= base:
      gba.timer.tmd_write_cycle[i] -= base
    else:
      gba.timer.tmd_write_cycle[i] = 0
  if gba.bus.rom_free_since >= base:
    gba.bus.rom_free_since -= base
  else:
    gba.bus.rom_free_since = 0
  # The post-DMA open-bus window compares this stamp with scheduler cycles;
  # unrebased, it would hold the window shut until the next burst.
  if gba.bus.dma_request_at >= base:
    gba.bus.dma_request_at -= base
  else:
    gba.bus.dma_request_at = 0
  if gba.bus.idle_until >= base: gba.bus.idle_until -= base
  else: gba.bus.idle_until = 0
  gba.bus.imm_idle_from = 0
  gba.bus.load_size = 0   # its stamps are not rebased; a frame edge ends it
  gba.bus.pf_wait_to = 0  # PF_WAIT_UNDER_BURST: one instruction's; a frame edge ends it
  gba.bus.imm_idle_until = 0
  if gba.bus.imm_at >= base: gba.bus.imm_at -= base
  else: gba.bus.imm_at = 0
  if gba.bus.dma_end_at >= base: gba.bus.dma_end_at -= base
  else: gba.bus.dma_end_at = 0
  if gba.bus.access_end >= base:
    gba.bus.access_end -= base
  else:
    gba.bus.access_end = 0
  if gba.bus.access_start >= base: gba.bus.access_start -= base
  else: gba.bus.access_start = 0
  for ch in 0..3:
    if gba.dma.imm_due[ch] >= base: gba.dma.imm_due[ch] -= base
    else: gba.dma.imm_due[ch] = 0
    if gba.dma.busy_until[ch] >= base: gba.dma.busy_until[ch] -= base
    else: gba.dma.busy_until[ch] = 0
  for f in 0..1:
    for i in 0..3:
      if gba.dma.fifo_word_at[f][i] >= base: gba.dma.fifo_word_at[f][i] -= base
      else: gba.dma.fifo_word_at[f][i] = 0
  if gba.interrupts.gate_open_at >= base:
    gba.interrupts.gate_open_at -= base
  else:
    gba.interrupts.gate_open_at = 0
  # IRQ_LAST_WAITS compares these with the clock at the next boundary. The
  # frame ends four cycles before the V-blank IRQ is recognised, so unrebased
  # they would never match for it (alyosha irq/IRQ_sub_2_slow).
  if gba.cpu.irq_line_at >= base: gba.cpu.irq_line_at -= base
  else: gba.cpu.irq_line_at = 0
  if gba.bus.lw_end >= base: gba.bus.lw_end -= base
  else:
    gba.bus.lw_end = 0
    gba.bus.lw_waits = 0
  if gba.interrupts.stall_to >= base:
    gba.interrupts.stall_from -= min(gba.interrupts.stall_from, base)
    gba.interrupts.stall_to -= base
  else:
    gba.interrupts.stall_from = 0
    gba.interrupts.stall_to = 0
  for t in [addr gba.interrupts.win_open_at, addr gba.interrupts.win_close_at]:
    if t[] != high(CycleCount): t[] = (if t[] >= base: t[] - base else: 0)
  if gba.interrupts.pipe_due >= base:
    gba.interrupts.pipe_at -= min(gba.interrupts.pipe_at, base)
    gba.interrupts.pipe_due -= base
  else:
    gba.interrupts.pipe_raised = 0
  if gba.interrupts.pipe2_due >= base:
    gba.interrupts.pipe2_at -= min(gba.interrupts.pipe2_at, base)
    gba.interrupts.pipe2_due -= base
  else:
    gba.interrupts.pipe2_raised = 0
  if gba.storage of EEPROM:
    let ep = EEPROM(gba.storage)
    if ep.busy_until >= base:
      ep.busy_until -= base
    else:
      ep.busy_until = 0
  base

proc apply_cheats*(gba: GBA) =
  ## Push every enabled RAM-write cheat into memory. Run once per frame.
  if gba.cheats == nil or gba.cheats.cheats.len == 0: return
  if gba.cheat_hooks.read8 == nil:   # build the capturing closures once
    let bus = gba.bus
    gba.cheat_hooks = MemHooks(
      read8:   proc(a: uint32): uint8  = bus.read_byte_internal(a),
      read16:  proc(a: uint32): uint16 = bus.read_half_internal(a),
      read32:  proc(a: uint32): uint32 = bus.read_word_internal(a),
      write8:  proc(a: uint32; v: uint8)  = bus.write_byte_internal(a, v),
      write16: proc(a: uint32; v: uint16) = bus.write_half_internal(a, v),
      write32: proc(a: uint32; v: uint32) = bus.write_word_internal(a, v),
    )
  gba.cheats.apply_ram(gba.cheat_hooks)

proc refresh_cheat_rom_patches*(gba: GBA) =
  ## Apply (or re-apply) Game Genie / GSA_PATCH ROM edits. Call at load and
  ## whenever the cheat set changes.
  if gba.cheats != nil:
    gba.cheats.apply_rom(gba.cartridge.rom)

const FRAME_STEP_LIMIT* = 16 * 280896
  ## The most CPU steps one step_frame takes: sixteen frames of cycles, where
  ## a step is a cycle or more. A machine a loaded state has stopped (a file's
  ## or a link peer's) never ends its frame; the frame gives up here instead
  ## of holding the app.

proc step_frame*(gba: GBA) =
  gba.apply_cheats()
  if gba.mp2k_hle and gba.mp2k != nil:
    gba.mp2k.mp2k_frame_poll()
  if gba.mp2k_hle and gba.gs_bon != nil:
    gba.gs_bon.gs_frame_poll()
  # The MP2K sound window closes when the setting is off (the frame poll
  # opens it while a driver is published)
  if not gba.mp2k_hle: gba.bus.snd_wlen = 0
  gba.frame_start_cycles = gba.scheduler.cycles
  var steps = FRAME_STEP_LIMIT
  while gba.ppu.frame == 0 and steps > 0:
    gba.cpu.tick()
    dec steps
  gba.end_frame()

method run_until_frame*(gba: GBA) = gba.step_frame()

proc handle_input*(gba: GBA; input: Input; pressed: bool) =
  gba.keypad.handle_input(input, pressed)

method toggle_sync*(gba: GBA) =
  gba.apu.toggle_sync()

# Save-state visitor over every component above (also serves rewind/rollback)
{.push quirky: off.}
include savestate
{.pop.}
when QUIRKY_CORE:
  {.pop.}   # quirky: on, from the top
