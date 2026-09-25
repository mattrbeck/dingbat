# GBA emulator main file
# All types are declared here; implementation files are `include`d.

import std/[options, times, os, strutils, math, sets, tables]
from std/bitops import countLeadingZeroBits, countTrailingZeroBits
import ../common/[util, input, scheduler, emu, resampler, serialize, timestretch, cheats, atomicfile]
when defined(test_harness):
  import ../common/test_output
import ../common/lut_macros
import rtc_calendar
export rtc_calendar

when defined(pftrace):
  # -d:pftrace: dump ROM-bus activity inside each mGBA-suite Timing window
  # (between TM0's enable and disable writes) that contained a DMA grant; this
  # is how bus.rom_access_cycles' hand-off predicate is re-derived. Every call
  # site is `when defined(pftrace)`, so a normal build pays nothing. With
  # -d:pftrace_all too, every window prints, flushed at each TM0 read (the
  # alyosha timing rows read a running timer and never disable it).
  var pft_on*: bool
  var pft_dma*: bool

  var pft_lines*: seq[string]
  proc pft*(s: string) =
    # Bounded: a game can leave TM0 running for whole frames.
    if pft_on and pft_lines.len < 4096: pft_lines.add(s)

when defined(itrace):
  # -d:itrace: per-instruction trace to stderr, for chasing a cycle through a
  # test ROM. Starts when the PC first enters [ITRACE_LO, ITRACE_HI] (hex)
  # and runs ITRACE_N lines; timer, interrupt and DMA events interleave.
  var it_lo*, it_hi*: uint32
  var it_left* = -1
  var it_on*: bool
  proc it_init*() =
    if it_left == -1:
      it_lo = uint32(parseHexInt(getEnv("ITRACE_LO", "0")))
      it_hi = uint32(parseHexInt(getEnv("ITRACE_HI", "0")))
      it_left = parseInt(getEnv("ITRACE_N", "400"))
  proc itl*(s: string) =
    if it_on and it_left > 0:
      dec it_left
      stderr.writeLine(s)

when defined(bgtrace):
  var bgtrace_n*: int

when defined(dmacount):
  # -d:dmacount: per-frame H-blank DMA grant census. 160 visible lines means
  # 160 grants per armed channel; a repeating channel whose source pointer is
  # a per-frame accumulator (DKC2's per-line BG1 scroll table) drifts for the
  # rest of the frame on any miscount.
  var hdma_grants*: array[4, int]
  var hdma_frame*: int

include reg

# Renderer contention maps (contention.nim): 32-bit words covering a line's
# 1232 dots and the first 48 of the next.
const CONT_WORDS* = 40
# -d:CONTENTION=false: no renderer contention (every access as in blank)
const CONTENTION* {.booldefine.} = true

# All GBA types in one block for forward-reference support.

type
  Pipeline* = object
    buffer*: array[2, uint32]
    pos*:    int
    size*:   int


  StorageType* = enum
    stEEPROM, stSRAM, stFLASH, stFLASH512, stFLASH1M,
    stNone   # no backup chip on the cart (storage.nim find_storage_type)

  StorageObj* = object of RootObj
    memory*:    seq[byte]
    save_path*: string
    dirty*:     bool
    # Why the last battery write failed ("" once one lands), and whether the
    # frontend has yet to tell the player about this run of failures: it
    # clears `save_error_new`, write_save sets it again only after a write
    # has succeeded in between.
    save_error*:     string
    save_error_new*: bool
    # Battery-file RTC trailer (rtc_calendar.nim). rtc_cart: the ROM carries
    # the RTC library (storage.nim). `trailer` holds the 16 bytes found after
    # the chip data when the file had them; `rtc` is set on RTC carts and
    # supplies a fresh trailer on every write.
    rtc_cart*:    bool
    has_trailer*: bool
    trailer*:     array[16, byte]
    rtc* {.cursor.}: RTC
  Storage* = ref StorageObj

  SRAM* = ref object of StorageObj

  NoBackup* = ref object of StorageObj   # empty memory, no .sav

  FlashStateFlag* = enum
    fsReady, fsCmd1, fsCmd2, fsIdentification, fsPrepareWrite, fsPrepareErase, fsSetBank

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
    # Absolute cycle until which the chip is busy programming after a write;
    # rebased by end_frame. Not serialized (reset to 0 on state load).
    busy_until*:    CycleCount

  Interrupts* = ref object
    gba* {.cursor.}:    GBA
    reg_ie*: InterruptReg
    reg_if*: InterruptReg
    ime*:    bool
    # IRQ recognition is held off until this cycle after a register write
    # opens the last gate on a parked IF (IRQ_GATE_DELAY, interrupts.nim).
    # Rebased by end_frame; in the state's in-flight section (rev 9).
    gate_open_at*: CycleCount
    # A timer interrupt in the synchroniser (raise_synced, interrupts.nim):
    # raised at pipe_at (pipe_new: the IF bits it set), IE & IF sampled into
    # pipe_bits after that cycle's register writes, recognised at pipe_due.
    # Rebased by end_frame; in the state's in-flight section (rev 9), as is
    # the stall span below.
    pipe_raised*:  uint16
    pipe_new*:     uint16
    pipe_bits*:    uint16
    pipe_sampled*: bool
    pipe_at*:      CycleCount
    pipe_due*:     CycleCount
    # The span the last DMA burst stalled the running CPU (dma.run_pending),
    # for the synchroniser, which stops with it (DMA_STALLS_IRQ_SYNC).
    # stall_pushed: the burst delayed a recognition already under way.
    # Transient like the pipe; rebased by end_frame.
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
    # Internal memory control (0x04000800, mirrored every 64K): the EWRAM
    # wait field is live (bus.update_waitcnt); the disable and swap bits are
    # readback only. Reset value 0x0D000020 (gbaedge IDENT page). Both fields
    # are in the state's in-flight section (rev 9).
    memctrl*: uint32

  Timer* = ref object
    gba* {.cursor.}:          GBA
    tmcnt*:        array[4, TMCNT]
    tmd*:          array[4, uint16]
    tm*:           array[4, uint16]
    cycle_enabled*: array[4, CycleCount]
    # The count a cold enable found: reads before counting starts still see
    # it (TIMER_START_DELAY). With the reload latch below, in the state's
    # in-flight section (rev 9).
    tm_pre*:       array[4, uint16]
    # Reload writes latch one cycle late relative to an overflow: an overflow
    # on the cycle right after the write still reloads the old value
    tmd_prev*:        array[4, uint16]
    tmd_write_cycle*: array[4, CycleCount]

  # Link-cable driver. The base methods (serial.nim) are the no-cable
  # behaviour, so the base type is the null driver. Frontend configuration,
  # never serialized.
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
    # Scheduler cycle of the last FIFO transfer on channels 1/2 (mp2k.nim
    # measure_latency dates a ring slot's crossing from it)
    fifo_xfer_cycle*: array[4, int64]
    # Priority arbitration: bitmask of channels with a latched request, and
    # the channel of the innermost burst in progress (4 = none). A pending
    # channel runs only while its number is below current_priority; a
    # higher-priority request preempts via a nested run_pending. Always 0/4
    # between instructions, so not serialized.
    pending*:          uint8
    # When each armed immediate channel requests the bus (DMA_START_DELAY
    # after its enable write). Only read within that delay; in the state's
    # in-flight section (rev 9).
    imm_due*:          array[4, CycleCount]
    # HDMA_DROP_BUSY: until when each channel's burst holds the bus (its
    # last write and the hand-back; high(CycleCount) while it runs). An
    # H-blank request earlier than this is lost. Never ahead of the clock
    # between instructions, so not serialized: a load clears it.
    busy_until*:       array[4, CycleCount]
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
    # bit at line 162; a channel armed mid-frame waits for the next frame's
    # line 2 (gbaedge CAPDMA page). In the state's in-flight section (rev 9):
    # a capture runs across the frame boundary.
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
    # unix seconds + bias. Until the game writes the clock or a battery file
    # supplies one (bias_set false) the RTC shows host local time, or UTC in
    # deterministic mode. wday_bias shifts the weekday counter from the
    # date's own weekday (the chip's septenary counter is set independently).
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
    # Z-axis gyro (WarioWare: Twisted!, game code RZW*): a serial ADC on the
    # RTC pins, never coexisting with an RTC (GBATEK "GBA Cart Gyro Sensor").
    # 16-bit shift register = 4 zeros + 12-bit sample, MSB out per falling
    # clock edge. gyro_z is the live frontend input (-1..1, CW positive).
    gyro_present*: bool
    gyro_z*:       float
    gyro_sample*:  uint16
    gyro_clock*:   bool
    gyro_out*:     uint8
    # Solar sensor (Boktai 1/2, Shin Bokura no Taiyou; GBATEK "GBA Cart
    # Solar Sensor"), sharing the port with the RTC: bit 0 clocks a counter,
    # bit 1 resets it, bit 3 (input) reads 1 once the counter reaches the
    # light level. solar_level is the live frontend input: 0xE8 is dark,
    # smaller is brighter (GBATEK: ~0x50 in direct sunlight). The counter is
    # not serialized: a state loaded mid-measurement misreads one sample.
    solar_present*: bool
    solar_level*:   uint8
    solar_counter*: uint8
    solar_clock*:   bool

  Bus* = ref object
    gba* {.cursor.}:        GBA
    # Cached: avoids a double pointer-chase on the per-fetch/per-MMIO paths
    sched*:      Scheduler
    cycles*:     int
    # Cycles already handed to the scheduler mid-instruction by catch_up;
    # cpu.tick folds them into the instruction total and resets this
    synced*:     int
    bios*:       seq[byte]
    # No BIOS file loaded: `bios` holds the HLE stub. HLE SWI paths that jump
    # into stub code check this so they stay inert under a real BIOS.
    stub_bios*:  bool
    # MP2K HLE sound window (mp2k.nim "Runtime detection"): a work-RAM store
    # with (address - snd_wbase) < snd_wlen is offered to mp2k_sound_write
    # before it lands. snd_wlen 0 = closed.
    snd_wbase*:  uint32
    snd_wlen*:   uint32
    # True only during a genuine byte-sized store (strb / DMA byte). Wider IO
    # writes decompose into byte writes, and a few registers treat real byte
    # stores differently (gbaedge IOBYTE/DMAEDGE pages). Not serialized.
    byte_io_write*: bool
    wram_board*: seq[byte]
    wram_chip*:  seq[byte]
    # What 02000000-02FFFFFF reads and writes: the 256K board WRAM, or with
    # MEMCNT (0x04000800) bit 5 clear the 32K chip WRAM, at chip WRAM timing.
    # Derived from mmio.memctrl in update_waitcnt; a raw pointer, so the
    # switch costs the hot path nothing.
    ewram_off*:  bool
    ew_ptr*:     ptr UncheckedArray[byte]
    ew_mask*:    uint32
    gpio*:       GPIO
    # Tilt sensor (Yoshi's Universal Gravitation, Koro Koro Puzzle): byte
    # registers at 0x0E008000-0x0E008500 (GBATEK "GBA Cart Tilt Sensor").
    # Latches are per-frame samples, not serialized; tilt_in_* are the live
    # frontend inputs, -1..1.
    tilt_present*: bool
    tilt_armed*:   bool
    tilt_x*:       uint16
    tilt_y*:       uint16
    tilt_in_x*:    float
    tilt_in_y*:    float
    bios_latch*: uint32
    # Instruction-fetch fast path: pointer + mask + waitstates for the page PC
    # executes from. Buffers never move and ROM is padded to the full 32 MB
    # mirror, so the pointer stays valid; RAM code writes are visible because
    # fetches read the live buffer.
    fetch_page*: uint32
    # What the fetch fast path compares against: fetch_page, or invalid to
    # force the miss path without losing which page the CPU fetches from
    # (IRQ_LAST_WAITS's window; the prefetch logic reads fetch_page).
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
    # Per-page bitmap of the prefetch-hand-off stall (rom_access_cycles): bit
    # `e` is set when a prefetch halfword started `e` cycles ago is in its
    # final, uninterruptible cycle. Precomputed from wait16_s so the data
    # path needs a shift, not a division; the buffer is full by e = 8*s <= 72,
    # so only the s = 9 tail needs the modulo fallback.
    pf_commit*: array[16, uint64]
    # ROM bus bookkeeping: the address that would continue the current burst,
    # and the absolute cycle the ROM bus went idle (prefetch credit accrues
    # from there while the CPU runs off other memory)
    rom_next_addr*:  uint32
    rom_free_since*: CycleCount
    # Prefetch buffer states the rom_free_since credit cannot express
    # (rom_access_cycles). pf_paused: the buffer filled and the prefetcher
    # stopped until the CPU drains it; pf_count halfwords are left, and at 0
    # the next fetch is the CPU's own, nonsequential. pf_running: the
    # prefetcher has had a free bus cycle since the CPU's last own ROM
    # access; until it has, a branch to the next halfword is nonsequential.
    # rom_ahead: how far the console's fetch address leads the executing
    # instruction's, which is where dingbat fetches (8 ARM, 4 Thumb).
    pf_paused*:      bool
    pf_running*:     bool
    pf_count*:       int8
    rom_ahead*:      int8
    # A read whose value changes with time and no scheduler event (a running
    # timer's count, a PSG status, an EEPROM ready poll) happened since the
    # waitloop detector last looked; such a loop is never skipped.
    volatile_read*:  bool
    # Second burst tracker for DMA: src and dst streams interleave on the ROM
    # bus yet each stays sequential, without needing back-to-back bus cycles
    rom_next_addr2*: uint32
    dma_active*:     bool
    # SWP holds the bus from its read to its write: DMA requests granted in
    # between wait for the write (arm_single_data_swap). Never set between
    # instructions, so not serialized.
    swp_lock*:       bool
    # Prefetch hand-off to a DMA burst: rom_free_since is on the CPU's bus
    # clock while a granted DMA runs on the event clock (tick_slow rewinds to
    # the due event's cycle), so the prefetcher's phase is counted forward
    # from the grant cycle captured here instead. Seeded and consumed within
    # one burst; not serialized.
    dma_grant_now*:  CycleCount
    dma_first_rom*:  bool
    # True while the CPU fetch stream is unbroken: sequential ROM fetches skip
    # the absolute-time bookkeeping. Any other cycle consumer must "cool" the
    # stream (recording rom_free_since) first.
    rom_hot*:        bool
    # True while a delayed immediate DMA is scheduled: data accesses catch the
    # scheduler up so the DMA preempts the CPU at its exact start cycle (a
    # read one instruction after the enable must see the DMA'd data)
    # Every data access syncs the scheduler while either bit is set: bit 0 an
    # immediate DMA is armed, bit 1 a PPU-timed DMA request is close
    # (DMA_ACCESS_WINDOW). One test on the data path and none on fetches: the
    # window invalidates the fetch cache and rides its miss path. Bit 2 (with
    # bit 0): the armed immediate DMA's request found the CPU with an access
    # in flight and waits a cycle for it (IMM_IDLE_GRANT). Bit 3: an
    # interrupt is on its way to the CPU, whose accesses record where their
    # wait states lie (IRQ_LAST_WAITS).
    sync_bits*: uint8
    # IRQ_LAST_WAITS, recorded while bit 3 is set: where the last CPU access
    # ended and how many of its cycles were wait states.
    lw_end*:    CycleCount
    lw_waits*:  int
    access_end*: CycleCount         # end of the access a window sync is inside
    access_start*: CycleCount       # and its first cycle
    # IMM_ACCESS_WAIT: an immediate DMA's request landed in the CPU access
    # being synced; the accessor grants it once the access has taken effect.
    imm_post*: bool
    # and one that came due in a load or exactly as an access ended: the next CPU step
    # at that cycle hands over (an internal cycle through IMM_IDLE_GRANT's
    # path, a data access before it starts; a fetch leaves it to the
    # one-cycle retry).
    imm_pre*: bool
    access_rom*: bool               # the synced access is on the gamepak bus
    access_write*: bool             # and is a store
    dma_deferred_from*: CycleCount  # a deferred grant's original request cycle
    dma_deferred*: bool
    window_closing*: bool           # the request fired; the next fetch closes the window
    idle_until*: CycleCount         # end of the internal cycles a window sync is inside
    # IMM_IDLE_GRANT: the internal cycles the CPU charged last while an
    # immediate DMA was armed, [imm_idle_from, imm_idle_until). Only read
    # within DMA_START_DELAY of the arming write; not serialized.
    imm_idle_from*: CycleCount
    imm_idle_until*: CycleCount
    imm_at*: CycleCount             # when the armed immediate DMA requests the bus
    in_catch_up*: bool              # a dispatch from inside an access's sync (catch_up_slow)
    dma_end_at*: CycleCount         # when the last CPU-interrupting burst let go
    dma_held*: int                  # and how long it had held the bus
    # Open-bus latch left by DMA: the last word a DMA moved stays on the data
    # bus until the CPU's next bus access replaces it, so an unmapped read
    # sees that word only if it is the first access after the burst
    # (read_open_bus_value). dma_request_at is the cycle the latest burst was
    # requested at. Hardware: gbaedge DMAOPENBUS and HDMAPHASE on AGB SP
    # (docs/hwprobe-results-agb.md sessions 5-6). mGBA suite Misc "DMA
    # Prefetch Read" and three games need the word: Hello Kitty Collection:
    # Miracle Fashion Maker's boot (a sound-FIFO DMA's final zero word) and
    # Famicom Mini Metroid, whose table walk off the end of a ROM table stops
    # only on an H-blank DMA's word.
    dma_open_bus*:       uint32
    # The HLE SoundDriverMain's pass (hle_sound.nim sd_mix) computes the
    # pcmBuffer slot at once, but the real routine writes it byte by byte
    # over the pass: a sound DMA that drains that slot meanwhile (the first
    # passes after a start, when the ring has no lead) reads what the real
    # routine had written by then. The pass leaves its writes here, timed
    # from sd_tw_start (bus.nim sd_tw_word); a FIFO DMA read in the window
    # gets the byte as of its cycle. Not serialized: cleared on state load.
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
    # bytes, and r15 while it ran); 0 = none. A burst's first unmapped read
    # sees that load's value if the CPU has fetched nothing since. Written
    # only on the syncing access path; not serialized.
    load_addr*:          uint32
    load_size*:          int
    load_pc*:            uint32
    load_start*:         CycleCount
    load_end*:           CycleCount
    dma_bus_req*:        CycleCount  # when the burst in progress asked for the bus
    ldrsh_odd*:          bool
    dma_bus_fresh*:      bool  # no transfer of this burst has driven the bus yet
    iwram_latch*:        uint32  # the last word a DMA moved to or from IWRAM
    dma_request_at*:     CycleCount
    dma_has_run*:        bool
    # -d:obuslatch: the same bus modelled as a real 32-bit register instead
    # of a predicate -- halves written independently, driven by opcode
    # fetches and by the last word a DMA moved, read back whole. That is the
    # only shape that can return the half-DMA, half-opcode word an AGB SP
    # gives two NOPs after a burst (obuswint.s; docs/playtest-bugs.md
    # section 13). Not serialized: a save state reloads it on the next fetch.
    obus_latch*:         uint32
    # The cycle each half was last driven by an opcode fetch. A DMA is not
    # applied here but resolved against these at read time, because dingbat
    # defers an immediate DMA to the next data access: it runs in the right
    # CYCLE but the wrong ORDER, after fetches it should precede. Comparing
    # stamps per half keeps the timestamps that already pass the suite and
    # still lets the two halves answer differently, which is what DEAD6019
    # requires.
    obus_half_at*:       array[2, CycleCount]
    # -d:obusahead: the bus clock at the PREVIOUS instruction's start. The
    # real pipeline issued this opcode's fetch about one instruction before
    # dingbat charges it, so that is the cycle the fetch actually drove the
    # bus at. Timing-neutral: only the latch stamps move.
    obus_prev_at*:       CycleCount
    # Per page: true for palette RAM / VRAM / OAM while the renderer may
    # hold that memory, so an access there asks contention.nim how long it
    # waits (ppu.contend_mask_update). Derived, not serialized.
    contended*:          array[16, bool]

  WLInstrKind* = enum
    wlLongBranchLink, wlUnconditionalBranch, wlSoftwareInterrupt,
    wlConditionalBranch, wlMultipleLoadStore, wlPushPopRegisters,
    wlAddOffsetToStackPointer, wlLoadAddress, wlSpRelativeLoadStore,
    wlLoadStoreHalfword, wlLoadStoreImmediateOffset, wlLoadStoreSignExtended,
    wlLoadStoreRegisterOffset, wlPcRelativeLoad, wlHighRegBranchExchange,
    wlAluOperations, wlMoveCompareAddSubtract, wlAddSubtract,
    wlMoveShiftedRegister, wlUnimplemented

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
    # True between a PC write and the first opcode fetch at the destination:
    # a write landing near the new PC in that window (an immediate DMA granted
    # right after the branch) must be visible to the refill, so the
    # self-modifying-code pipeline capture in write_*_internal stands down
    # (Golden Sun TLA DMAs a `bx pc` trampoline onto the stack and branches
    # to it before the transfer has run)
    refill_pending*: bool
    reg_banks*:   array[7, array[7, uint32]]  # [6] = UNDEF_BANK, see cpu.nim
    spsr_banks*:  array[6, uint32]
    halted*:      bool
    stopped*:     bool  # Stop mode: halted, and only keypad/cartridge/SIO IRQs wake
    # Level-triggered IRQ signal (IE & IF != 0 and IME), maintained by
    # check_interrupts; sampled at instruction boundaries only
    irq_line*:    bool
    # When the synchroniser raised irq_line (IRQ_LAST_WAITS).
    irq_line_at*: CycleCount
    # Set when an IRQ wakes the CPU from halt. Nothing reads it any more; it
    # stays because it is serialized CPU state.
    halt_wake*:   bool
    # HLE IntrWait: while active, the CPU re-halts at resume_addr until the
    # user IRQ handler ORs a masked flag into the BIOS mirror at 0x03007FF8
    intr_wait_active*:      bool
    intr_wait_mask*:        uint16
    intr_wait_resume_addr*: uint32
    # HLE Halt/Stop: the real BIOS runs its SWI-dispatcher return path after
    # the wake IRQ is serviced, so its cost is charged when execution reaches
    # the instruction after the SWI.
    halt_resume_charge*:    int32
    halt_resume_addr*:      uint32
    # The parked charge belongs to a Halt/Stop SWI, whose entry left the
    # dispatcher's {r2, lr} frame live (System sp shifted down 8); the resume
    # must pop it. Decompression SWIs park charges here but never shift sp.
    halt_resume_pop*:       bool
    # An HLE CpuSet/CpuFastSet preempted by an IRQ rewinds onto its SWI with
    # the continuation in r0-r2 (hle_bios.nim); these name that SWI and
    # state so the re-dispatch is known as the same routine resuming (it
    # pays no dispatch or entry again, as the real one returns into its
    # loop). In the state's in-flight section (rev 9).
    copy_cont_pc*:          uint32
    copy_cont_regs*:        array[3, uint32]
    # Waitloop fields
    attempt_waitloop_detection*: bool
    cache_waitloop_results*:     bool
    branch_dest*:                uint32
    identified_waitloops*:       HashSet[uint32]
    identified_non_waitloops*:   HashSet[uint32]
    # One-entry caches in front of the two HashSets: a hot loop re-analyzes
    # the same backward branch every iteration (1 = no entry; thumb addresses
    # are even / 0 = no entry; a waitloop start is always a ROM address)
    last_non_waitloop*:          uint32
    last_waitloop*:              uint32
    entered_waitloop*:           bool
    # A waitloop's first memory load (0xFFFFFFFF: none), per cached start
    waitloop_first_load*:        Table[uint32, uint32]
    last_waitloop_first_load*:   uint32
    # Exact-skip bookkeeping (see waitloop.nim "Transparency"): the loop
    # whose branch was seen last, the bus time it was seen and the period
    # since the visit before; the dispatch count at that visit
    wl_addr*:                    uint32
    wl_time*:                    int64
    wl_period*:                  int64
    wl_dispatch_mark*:           uint32
    waitloop_instr_lut*:         seq[WLInstrKind]
    # The LDM^ glitch (arm/arm.nim, ldm_user_glitch): the current-bank
    # registers holding banked OR user for the one instruction after an LDM^,
    # their own values, and that instruction. Never serialized: a state is
    # taken with it settled (gba_state_payload).
    ldm_glitch*:       uint16
    ldm_glitch_instr*: uint32
    ldm_glitch_saved*: array[16, uint32]
    # Transient, within one instruction (never serialized): a return to
    # Thumb code refilled from the gamepak prefetcher's stream, at Thumb
    # width already, at ret_refill_at (cpu.refill_from_head), so
    # exception_return_restore must not redo it.
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
    # Frame boundaries reached but not yet consumed by step_frame/end_frame.
    # A counter, not a bool: an HLE decompression SWI runs atomically and can
    # span several frames.
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
    # Line-start latches (serialized from GBA payload rev 6). The mGBA suite
    # "Video tests" pin all three; the constants are its expected screens.
    # bg_enable_hist: DISPCNT's BG0-3 enables sampled on the last three
    # lines, newest in the low nibble. A BG draws only while its bit is set
    # now AND was set at the sample two lines ago, so an enable shows from
    # the third line after the write and a disable is immediate ("Layer
    # toggle" 1 and 2).
    bg_enable_hist*: uint16
    # Scheduler cycle of the current line's start, for the sample point
    # inside the line (BG_ENABLE_LATCH_CYCLE); rebased by end_frame, dated
    # from the pending line event on a state load.
    line_start_cycle*: int64
    # WIN0/WIN1 vertical state: set at the line start where VCOUNT equals
    # Y1, cleared where it equals Y2 (the clear wins on a tie). A Y2 that
    # VCOUNT never reaches leaves the window open into the next frame
    # ("Window offscreen reset").
    win0_inside*:  bool
    win1_inside*:  bool
    # OAM as the sprite scan sees it: copied from `oam` after each line is
    # drawn, so an OAM write moves sprites from the second line after it
    # ("OAM Update Delay"). oam_view_stale says a write is waiting.
    oam_view*:       seq[byte]
    oam_view_stale*: bool
    # Frame-start copies of the latches above, so render-skip notices a
    # latch that settles a frame after the register write that moved it.
    frame_start_latches*: uint32
    # BG enables for the line being drawn (scratch): DISPCNT and the delay.
    line_bg_enables*: uint16
    # A BG switched on after its line started (see midline_bg_enable):
    # DISPCNT's BG bits at the line start, and the cycle into the line each
    # BG's bit rose (-1: not this line). Derived, not serialized.
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
    # Per-line OBJ candidate set: obj_line_mask[line] is a 128-bit set (entry
    # N = bit N&63 of word N>>6) of the OAM entries whose bounding box covers
    # the line. Rebuilt lazily (obj_list_dirty, set via oam_touched); past
    # OBJ_LIST_REBUILD_LIMIT rebuilds in a frame the rest of the frame uses
    # the straight 128-entry scan. Derived from OAM, so not serialized.
    obj_line_mask*:     array[160, array[2, uint64]]
    obj_list_dirty*:    bool
    obj_list_rebuilds*: int
    # Render skipping: render_dirty is set by anything that can change the
    # picture; after a full frame without a change the framebuffer already
    # holds the next frame, so rendering is skipped. frame_static lets the
    # frontend skip the texture upload too.
    render_dirty*: bool
    skip_render*:  bool
    frame_static*: bool
    # Speed mode: render every (frameskip+1)th frame; a skipped frame leaves
    # render_dirty accumulated. 0 = off.
    frameskip*:    int
    fs_counter*:   int
    forced_skip*:  bool
    # Debug-UI layer visibility (bits 0-3 = BG0-3, bit 4 = OBJ; 1 = shown).
    # ANDed into the per-scanline enable computation only, so the per-pixel
    # compositing hot path is untouched.
    debug_layer_mask*: uint16
    # Forces composite() to build per-column window tables even on uniform
    # lines; only tests/ppucomposite_test.nim sets it.
    disable_uniform_window*: bool
    # Renderer contention (contention.nim): which dots of a line the
    # renderer holds BG VRAM / palette RAM / OBJ VRAM / OAM, one bit a dot.
    # Derived from registers and OAM on demand, keyed by what they depend
    # on; never serialized (a key that cannot occur forces a rebuild).
    cont_regs_stale*: bool          # DISPCNT/BGxCNT/BGxHOFS/BLDCNT written
    cont_bg_key*:   uint32
    cont_bg*:       array[CONT_WORDS, uint32]
    cont_pram_key*: uint32
    cont_pram*:     array[CONT_WORDS, uint32]
    cont_obj_key*:  int64
    cont_objv*:     array[CONT_WORDS, uint32]
    cont_oam*:      array[CONT_WORDS, uint32]

  SoundChannel* = ref object of RootObj
    gba* {.cursor.}:            GBA
    enabled*:        bool
    dac_enabled*:    bool
    length_counter*: int
    length_enable*:  bool

  VolumeEnvelopeChannel* = ref object of SoundChannel
    starting_volume*:          uint8
    envelope_add_mode*:        bool
    period_ve*:                uint8
    volume_envelope_timer*:    uint8
    current_volume*:           uint8
    volume_envelope_is_updating*: bool

  Channel1* = ref object of VolumeEnvelopeChannel
    wave_duty_position*: int
    # Absolute cycle of the next waveform step, or GBA_NO_STEP if never
    # triggered. Advanced in closed form at observation points (apu.nim)
    # rather than by a scheduler event. Not serialized as a field:
    # savestate.nim converts it to/from an etAPUChannel1 event.
    next_step*:          CycleCount
    # Delay the pending step was armed with; reproduces the scheduler's
    # tie-break when a step lands exactly on an observer's cycle
    # (gba_steps_due). In the state's in-flight section (rev 9); rebuilt
    # from the period on loading an older state.
    arm_delay*:          uint32
    sweep_period*:       uint8
    negate*:             bool
    shift_ch1*:          uint8
    sweep_timer*:        uint8
    frequency_shadow*:   uint16
    sweep_enabled*:      bool
    negate_has_been_used*: bool
    duty*:               uint8
    length_load*:        uint8
    frequency_ch1*:      uint16

  Channel2* = ref object of VolumeEnvelopeChannel
    wave_duty_position*: int
    next_step*:          CycleCount   # see Channel1.next_step
    arm_delay*:          uint32       # see Channel1.arm_delay
    duty*:               uint8
    length_load*:        uint8
    frequency_ch2*:      uint16

  Channel3* = ref object of SoundChannel
    next_step*:             CycleCount   # see Channel1.next_step
    arm_delay*:             uint32       # see Channel1.arm_delay
    wave_ram*:              array[2, seq[byte]]
    wave_ram_position*:     uint8
    wave_ram_sample_buffer*: uint8
    wave_ram_dimension*:    bool
    wave_ram_bank*:         uint8
    length_load_ch3*:       uint8
    volume_code*:           uint8
    volume_force*:          bool
    frequency_ch3*:         uint16

  Channel4* = ref object of VolumeEnvelopeChannel
    next_step*:     CycleCount   # see Channel1.next_step
    arm_delay*:     uint32       # see Channel1.arm_delay
    lfsr*:          uint16
    length_load_ch4*: uint8
    clock_shift*:   uint8
    width_mode*:    uint8
    divisor_code*:  uint8

  DMAChannels* = ref object
    gba* {.cursor.}:       GBA
    fifos*:     array[2, array[32, int8]]
    positions*: array[2, int]
    sizes*:     array[2, int]
    latches*:   array[2, int16]
    # FIFO reconstruction (render-side, not serialized): point-sampling the
    # held latch at 32768 Hz folds zero-order-hold images into the audible
    # band, so the signal between FIFO updates is rebuilt with a causal
    # Four-point cubic over hist (index 0 oldest .. 3 newest).
    # last_update_cycle timestamps the newest latch; inv_period is 1/measured
    # update period (0 = none yet: hold the latch). fifo_interp=false emits
    # the raw held latch.
    hist*:            array[2, array[4, int16]]
    last_update_cycle*: array[2, int64]
    inv_period*:        array[2, float32]
    fifo_interp*:     bool   # cubic FIFO reconstruction (default on)
    # MP2K HLE slot timing (mp2k.nim render_frame, not serialized): the
    # address each FIFO byte was read from by a special-timing sound DMA
    # (0 = any other source), and up to four ring addresses whose first
    # appearance at the DAC is stamped with the HLE's output clock
    # (watch_clock, -1 until it plays; watch_cyc, the scheduler cycle).
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
    # 2x speed: drop every other stereo frame at the queue point
    turbo*:             bool
    turbo_parity:       bool  # emscripten per-sample decimation state
    # Pitch-correct fast-forward: WSOLA time-stretch instead of 2x decimation.
    # Presentation-only, not serialised.
    pitch_correct_ff*:  bool
    stretch:            TimeStretch
    stretch_engaged:    bool  # tracks the stretch-path rising edge (auto-reset)
    audio_dev*:         uint32  # SDL2 AudioDeviceID (0 = not open)
    # Optional analog-output low-pass: one-pole IIR on the native mix (web
    # uses a BiquadFilter node). Off by default; presentation-only.
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
    # Pass detection (mp2k.nim "Runtime detection"): the SoundInfo the bus
    # window watches, whether its lock write has been seen with no ring store
    # yet, and the ring each FIFO DMA plays (len 0 = none)
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
    # Predictive mode (mp2k.nim predict_envelope): a pass's frame is rendered
    # at its own hook from the envelope the pass is about to compute, and
    # placed at the hardware's latency; falsified by the real bytes one hook
    # later, the HLE drops back to rendering one hook late.
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
    # Quality tier (mp2k.nim "Quality tier"): off = the driver's own
    # arithmetic (parity checks); on = un-floored output, ramped gains,
    # interpolated echo. fine_a/fine_b carry this sample's un-truncated
    # FIFO values for apu.nim to add the sub-LSB remainder after the DAC.
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
    # Events dispatched so far (wrapping) and cpu.r[15] at the last one;
    # the waitloop detector's staleness test (waitloop.nim)
    dispatch_count*:   uint32
    last_dispatch_pc*: uint32
    bios_path*:  string
    rom_path*:   string
    run_bios*:   bool
    use_hle*:        bool
    hle_after_bios*: bool
    scheduler*:      Scheduler
    # Emulated cycle at which the current frame started; frame progress is
    # derived from it rather than counted per instruction.
    frame_start_cycles*: CycleCount
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
    # Speed mode: every memory access costs 2^underclock times its real
    # cycles (scaled into the bus waitstate tables, see update_waitcnt)
    # against an unchanged video/timer clock. 0 = off.
    underclock*: int
    dma*:        DMA
    serial*:     Serial
    cheats*:     CheatEngine
    cheat_hooks: MemHooks        # built once, reused each frame (see apply_cheats)
    when defined(test_harness):
      test_output*: TestOutput

# Forward declarations to handle circular include dependencies
proc irq*(cpu: CPU)
proc irq_enter*(cpu: CPU)
proc und*(cpu: CPU)
proc run_pending*(dma: DMA)
proc schedule_interrupt_check*(intr: Interrupts; delay: int = 0)
proc window_open_event*(intr: Interrupts)
proc window_close_event*(intr: Interrupts)
proc window_ahead*(intr: Interrupts; raise_in: int)
proc unstall*(intr: Interrupts; ran: int)
proc imm_refill_handover*(bus: Bus)
proc read_open_bus_word*(bus: Bus; address: uint32): uint32
proc read_open_bus_value*(bus: Bus; address: uint32): uint8
when defined(obuslatch):
  proc obus_drive_word*(bus: Bus; value: uint32) {.inline.}
  proc obus_drive_half*(bus: Bus; address: uint32; value: uint16) {.inline.}
proc rom_cool*(bus: Bus) {.inline.}
# The prefetch serve sits on the ROM fetch slow path, which runs once per
# instruction outside a hot stream; clang left it out of line, costing ~1% of
# retired instructions. Pinned where the attribute exists (GCC makes a failed
# always_inline a hard error).
when defined(clang):
  {.pragma: pf_inline, codegenDecl: "__attribute__((always_inline)) inline $# $#$#".}
else:
  {.pragma: pf_inline, inline.}
proc pf_serve(bus: Bus; now: CycleCount; page: int; halves: int): int {.pf_inline.}

# A branch into the gamepak refills N then S, in that order (cpu.clear_pipeline).
const ROM_REFILL_ORDERED* {.booldefine.} = true
const ROM_REFILL_ORDERED_PF* {.booldefine.} = true
const DMA_KEEPS_PREFETCH* {.booldefine.} = true
  ## A DMA that never touches the gamepak leaves the prefetcher running: the
  ## CPU's stream is not broken and the burst's cycles are prefetch time
  ## (tests/roms/payloads/slotdma.s at WAITCNT 0x4000).
const PREFETCH_TOGGLE_LAW* {.booldefine.} = true
  ## WAITCNT switching the prefetcher off keeps the buffer until the CPU
  ## drains it; switching it on after idle cycles breaks the burst
  ## (bus.write_waitcnt). Measured on hardware by the AGBEEG aging cartridge
  ## (toggle_prefetcher, 32/32 cells); with it alyosha timing/prefetch_enable,
  ## ppu/start_up and ppu/start_up_vbl_irq_halt read right too.
const HALT_WAKE_RUNS_ONE* {.booldefine.} = true
  ## An interrupt that wakes a halted CPU is taken one instruction after the
  ## wake, not at it (cpu.tick; tests/roms/payloads/wakeirq.s).
const IRQ_FETCH_VIA_PREFETCH* {.booldefine.} = true
  ## The IRQ entry's in-flight gamepak fetch comes from the prefetcher when
  ## it runs on the interrupted stream (cpu.irq).
const IRQ_INFLIGHT_AFTER_BURST* {.booldefine.} = true
  ## An IRQ entry's in-flight gamepak fetch right after a DMA burst is
  ## nonsequential and costs N - 1, as EWRAM's does (cpu.irq_enter).
const PF_RUNS_OFF_ROM* {.booldefine.} = true
  ## The gamepak prefetcher keeps fetching while the CPU runs from the BIOS
  ## or RAM: it goes on at the address the CPU would have fetched next, and a
  ## branch back to that address takes what it fetched (cpu.clear_pipeline).
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
const DMA_LEAD_CYCLES* {.intdefine.} = 1
  ## Of a burst's two hand-off cycles, how many come before its first
  ## transfer; the rest follow its last. One and one: with both in front the
  ## DMA's own writes landed a cycle late, which only showed once a timer
  ## stop was put where tmrw.s measures it -- every DMA-written stop stamp
  ## (halthb.s, breakram.s, dmaphase.s, slotdma.s) had been absorbing it.
  ## A PPU-timed DMA is granted at the end of the bus access in flight, not
  ## at its request (tests/roms/payloads/dmaphase.s, hdmastamp.s). Knowing
  ## where accesses end costs a scheduler sync per access, so it is paid only
  ## from the H-blank's start to the request, and only with such a DMA armed.
const DMA_STALLS_IRQ_SYNC* {.booldefine.} = true
  ## The stall gives back internal cycles the CPU ran under the burst
  ## (Interrupts.unstall); without it alyosha Interactions
  ## Internal_Cycle_DMA_IRQ_7/_ldr_IWRAM/_MUL_IRQ go red. The access the
  ## CPU was waiting to make is IRQ_LAST_WAITS's.
const IRQ_LAST_WAITS* {.booldefine.} = true
  ## An interrupt is taken after an instruction only if it was recognised
  ## before the wait states of that instruction's last bus access; one
  ## recognised during them waits for the next instruction. A wait-stated
  ## access is one stretched cycle, and the core samples the interrupt as
  ## that cycle begins. tests/roms/payloads/irqwait.s on an AGB SP: a TM0
  ## interrupt breaks into a NOP sled one NOP later from EWRAM (ARM: five
  ## wait states per fetch, Thumb: two) than the cycle count alone says,
  ## at every phase, and identically from IWRAM (no waits). Also alyosha
  ## ppu/start_up_vbl_irq (a cartridge VCOUNT poll, one instruction later
  ## than from Halt) and, through the first fetch after a DMA burst,
  ## Interactions Internal_Cycle_DMA_IRQ/_ST/_ST_p3/_br, which a tail on the
  ## burst's stall used to carry. Nearly free while nothing is on its way:
  ## a window (bus.sync_bits bit 3), opened by schedule_interrupt_check and,
  ## IRQ_WINDOW_LEAD cycles early, ahead of a timer's or the PPU's raise,
  ## has the CPU's fetches and stores note their wait states until no check
  ## is left to run. FireRed, same work: +0.06% retired instructions.
const DMA_READS_CPU_BUS* {.booldefine.} = true
  ## A DMA read of unmapped memory returns what is on the data bus: the last
  ## word the burst itself moved, or, for its first transfer, the CPU's last
  ## bus transaction -- its data load if that came after its last opcode
  ## fetch, else the fetched opcode (Bus.dma_bus_word).
const IMM_BOUNDARY_GRANT* {.booldefine.} = true
  ## An immediate DMA whose request (two cycles after the enable) falls
  ## exactly between two instructions is granted there, ahead of the next
  ## opcode fetch, instead of waiting a cycle as for an access in flight.
  ## dmaobus2.s on an AGB SP, the enable store followed by one-cycle
  ## instructions from IWRAM: the burst's word is the opcodes fetched
  ## before the third instruction (Thumb 31033104, ARM E2811004), one fetch
  ## earlier than without it (31053104, E2811005); from EWRAM, where the
  ## request lands inside a 3-cycle fetch, both agree. Off: those two cells
  ## (HLE and real BIOS) read one fetch late; on, alyosha
  ## prefetcher/prefetcher_dma and AGBEEG cpu_runs_idles_during_dma turn
  ## green and nothing else moves.
const DMA_CHAIN* {.booldefine.} = true
  ## An immediate DMA whose request comes due while another burst holds the
  ## bus follows it with no cycles between: the pair pays one lead and one
  ## hand-back. tests/roms/payloads/tmrdma.s on an AGB SP: DMA1 armed, DMA0
  ## armed by the next store (its request lands in DMA1's burst); DMA0 reads
  ## the timer DMA1 enabled on the very next cycle (old count, new control),
  ## and the CPU is back two cycles sooner than for two separate bursts.
const IMM_ACCESS_WAIT* {.booldefine.} = true
  ## An immediate DMA whose request lands inside a CPU data access that
  ## began before it waits for that access to end, and the access sees
  ## memory as it was before the burst; an access beginning on the request
  ## cycle loses the bus to it. tests/roms/payloads/dmastart.s on an AGB SP,
  ## the enable store followed from IWRAM by one instruction: an EWRAM ldr,
  ## ldrh or str there (data from the next cycle on) delays the burst by its
  ## length less one and reads the old word, while a nop before the ldr, or
  ## an ldm's second access, lets the burst in first.
const IMM_FETCH_WAIT* {.booldefine.} = true
  ## An immediate DMA whose request lands inside a CPU instruction fetch
  ## waits for the whole fetch, as for a data access (IMM_ACCESS_WAIT), and
  ## takes the bus as it ends. On an AGB SP: Hades-Tests dma-start-delay's
  ## own code run from board WRAM (tests/roms/payloads/hadesdsd.s): the DMA
  ## reads TM0 3 cycles later than the one-cycle retry gave, after the whole
  ## 6-cycle ARM fetch, while the CPU is back on the same cycle; and a Thumb
  ## store executed from the empty cartridge slot (slotimm.s): the request
  ## lands in the next opcode's 5-cycle gamepak fetch and the DMA reads TM0
  ## 2 cycles later than the retry gave, at the fetch's end; with the
  ## prefetcher on the fetch is 2 cycles and the burst starts at its end,
  ## a cycle sooner than the retry. The ROM rows of dma-start-delay (ARM,
  ## N+S fetches, with and without the prefetcher) turn green with it.
const IMM_IDLE_GRANT* {.booldefine.} = true
  ## An immediate DMA requests the bus two cycles after its enable write. If
  ## the CPU is running internal cycles then, the burst starts there and
  ## those cycles run under it; if the CPU has a gamepak access in flight,
  ## the burst starts on the third cycle, as it always did (mGBA suite
  ## Trivial DMA; any other access: IMM_ACCESS_WAIT). tests/roms/payloads/irqstorm.s on an AGB SP: the enable
  ## is followed by an IWRAM `ldr`, whose internal cycle is the enable's
  ## third, and the CPU comes out of every burst (1 to 4096 words) a cycle
  ## sooner than a third-cycle start gives -- the timer interrupt it then
  ## takes is a cycle earlier at every period. hades dma-start-delay's two
  ## IWRAM rows turn green with it. Off: irqstorm's ten DMA cells read one
  ## late.
const DMA_REGRAB* {.intdefine.} = 0
  ## A PPU-timed request landing within this many cycles of the last burst's
  ## end is granted at once, not deferred to the end of the CPU access in
  ## flight. It was 1, fitted to alyosha DMA_pause_timing_end_4 while that
  ## row's immediate burst (armed from ROM) started a cycle early; with the
  ## gamepak fetch waited out (IMM_FETCH_WAIT) _end_4's request lands on the
  ## burst's last cycle and _end_3's one after it, and 0 holds both.
proc add_cycles*(bus: Bus; n: int) {.inline.}
proc idle_window*(bus: Bus; n: int)
proc `[]`*(bus: Bus; address: uint32): uint8
proc `[]=`*(bus: Bus; address: uint32; value: uint8)
proc read_half*(bus: Bus; address: uint32): uint16
proc read_word*(bus: Bus; address: uint32): uint32
proc fetch_half*(bus: Bus; address: uint32): uint16 {.inline.}
proc fetch_word*(bus: Bus; address: uint32): uint32 {.inline.}
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
proc timer_overflow*(apu: APU; timer: int)
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
proc imm_pre_grant(bus: Bus; cost: int) {.noinline.}
proc serial_transfer_complete*(serial: Serial)
proc trigger_fifo*(dma: DMA; fifo_channel: int)
proc bitmap*(ppu: PPU): bool
proc oam_touched*(ppu: PPU) {.inline.}
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
proc contend_slow(bus: Bus; address: uint32; is32: bool; cost: int): int {.noinline, raises: [].}
proc hle_halt_return*(cpu: CPU)
proc read_instr*(cpu: CPU): uint32 {.inline.}
# The bank an undefined CPSR mode pattern selects: r13 and r14 read 0 there
# and the mode field holds the pattern (hardware: gbaedge UNDMODE on AGB SP,
# patterns 15/1A/1E, docs/hwprobe-results-agb.md). It is zeroed on entry,
# so nothing written in it survives; r8-r12 and the SPSR are unprobed and
# follow the user bank. Never serialized (always empty at a boundary).
const UNDEF_BANK* = 6
proc mode_bank*(m: CpuMode): int

# Textual includes: the whole GBA core compiles as one module so the C
# compiler inlines across files (notes/architecture.md). The forward
# declarations above make the order mostly arbitrary; the exceptions:
#   * hle_bios before arm/arm and thumb/thumb — both SWI handlers call
#     hle_swi, which has no forward declaration.
#   * arm/arm before arm/lut — `const armLut = armLutBuilder()` resolves the
#     arm_* handlers at compile time; a const cannot be forward-declared.

# CPU fetch pipeline
template note_waits*(bus: Bus; cost: int) =
  ## IRQ_LAST_WAITS: a CPU access of `cost` cycles just ended.
  bus.lw_end = bus.sched.cycles + CycleCount(bus.cycles)
  bus.lw_waits = cost - 1

include pipeline
# Cartridge: ROM image, save memory, GPIO-attached RTC
include cartridge
include storage
include storage/sram
include storage/flash
include storage/eeprom
include storage/none
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
  # Pass placement oracle (DINGBAT_PASSDUMP): each FIFO byte tagged with the
  # address the sound DMA read it from; per rendered pass, the capture index
  # the HLE placed its frame at and the index at which the byte the pass's
  # first ring store wrote (kind 0) / the model's slot start (kind 1) left
  # the FIFO.
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
  # Note-on with a non-zero SoundChannel.count: did the engine start the
  # sample at that offset (honoured) or at 0 (ignored)? Judged one pass later
  # from the count it left (apply_pending).
  var dbgStartHonoured*: int = 0
  var dbgStartIgnored*: int = 0
  var dbgStartUnclear*: int = 0
# Audio: PSG channels 1-4 + the two FIFO (DMA) channels, then the mixer
include apu/abstract_channels
include apu/channel1
include apu/channel2
include apu/channel3
include apu/channel4
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

proc new_storage*(gba: GBA; rom_path: string): Storage =
  # changeFileExt, not "up to the last dot": an extensionless path (the
  # command line takes any) would otherwise name `<parent>.sav` or `.sav`
  let save_path = rom_path.changeFileExt(".sav")
  let content = readFile(rom_path)
  var t = find_storage_type(content)
  when defined(yoshi_eeprom_pin):
    # Tilt carts save to EEPROM but the string scan can misread them as SRAM
    # (which aliases save bytes under the tilt registers). Behind a define
    # until the pin-by-game-code policy is decided.
    if gba.cartridge != nil and
       gba.cartridge.game_code() in ["KYGE", "KYGJ", "KYGP", "KHPJ"]:
      t = stEEPROM
  result = case t
    of stEEPROM:                        new_eeprom(gba)
    of stSRAM:                          new_sram()
    of stFLASH, stFLASH512, stFLASH1M:  new_flash(t)
    of stNone:                          NoBackup()
  result.rtc_cart = rom_has_rtc(content)
  if t == stNone:
    return   # no chip: no battery file is read or written
  result.save_path = save_path
  if fileExists(save_path):
    let data = readFile(save_path)
    # A trailing RTC record (rtc_calendar.nim "Trailer location") is never
    # chip data, even when it does not decode as a clock: the chip bytes are
    # everything before it, read up to the chip's size as before.
    let toff = trailer_offset(data.len)
    let chip_len = if toff >= 0: toff else: data.len
    if toff >= 0:
      result.has_trailer = true
      for i in 0 ..< RTC_TRAILER_LEN: result.trailer[i] = uint8(data[toff + i])
    let n = min(chip_len, result.memory.len)
    if n > 0: copyMem(addr result.memory[0], unsafeAddr data[0], n)

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

proc handle_saves*(gba: GBA)

proc defer_dma_request(gba: GBA; kind: EventType): bool =
  ## A PPU-timed DMA request that lands inside a CPU bus access is granted at
  ## the access's end. Only a window sync knows where that is; a halted CPU,
  ## an internal cycle or a closed window leave access_end in the past.
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

proc gba_dispatch(gba: GBA): proc(kind: EventType) {.closure.} =
  # Non-owning capture: the closure lives on the GBA's scheduler
  let gba {.cursor.} = gba
  result = proc(kind: EventType) =
    # Waitloop exactness: when, and at which PC, the last event ran
    inc gba.dispatch_count
    gba.last_dispatch_pc = gba.cpu.r[15]
    case kind
    of etAPUFrameSeq:   gba.apu.tick_frame_sequencer()
    of etAPUSample:     gba.apu.get_sample()
    # PSG channels carry next_step deadlines instead of per-period events
    # (apu.nim); these arms remain only for events in a state saved by an
    # older build, which gba_apply_state drains into next_step first.
    of etAPUChannel1, etAPUChannel2, etAPUChannel3, etAPUChannel4: discard
    of etPPUStartLine:     gba.ppu.start_line()
    of etPPUStartHBlank:   gba.ppu.start_hblank()
    of etPPUSetHBlankFlag: gba.ppu.set_hblank_flag()
    of etPPUEndHBlank:     gba.ppu.end_hblank()
    of etSaves:         gba.handle_saves()
    of etInterrupts:    gba.interrupts.check_interrupts()
    of etTimer0:        gba.timer.timer_overflow_event(0)
    of etTimer1:        gba.timer.timer_overflow_event(1)
    of etTimer2:        gba.timer.timer_overflow_event(2)
    of etTimer3:        gba.timer.timer_overflow_event(3)
    of etSerial:        gba.serial.serial_transfer_complete()
    of etDMA:
      when IMM_IDLE_GRANT:
        let bus = gba.bus
        let now = gba.scheduler.cycles
        var at_boundary = false
        when IMM_BOUNDARY_GRANT:
          # Due exactly as an instruction ends (the CPU's closing tick, not
          # an access's sync): the request finds the next fetch not yet
          # started, and wins the bus from it.
          at_boundary = not bus.in_catch_up and gba.scheduler.tick_left == 0 and
                        not gba.cpu.halted
        var in_access = false
        var access_starts = false
        var at_end = false
        when IMM_ACCESS_WAIT:
          # Measured for IWRAM/EWRAM/IO data accesses and (IMM_FETCH_WAIT)
          # EWRAM and gamepak fetches; a gamepak data access keeps the
          # one-cycle wait (none can be in flight at W+2 after the enable).
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
          # its end hands over (its internal cycle, which runs under the
          # burst, or an ldm's next access), as for one ending on the request.
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
           not (bus.imm_idle_from <= now and now < bus.imm_idle_until):
          bus.sync_bits = bus.sync_bits or 4
          gba.scheduler.schedule(1, etDMA)
        else:
          bus.sync_bits = bus.sync_bits and not 4'u8
          bus.imm_pre = false
          gba.dma.request_immediate()
      else:
        gba.dma.request_immediate()
    of etRtcSecond:     gba.rtc_irq_poll()
    of etHDMARequest:
      if not gba.defer_dma_request(kind): gba.dma.trigger_hdma()
    of etVDMARequest:
      if not gba.defer_dma_request(kind): gba.dma.trigger_vdma()
    of etLdmGlitch:     gba.cpu.ldm_glitch_restore()
    of etFifoARequest:  gba.dma.trigger_fifo(0)
    of etFifoBRequest:  gba.dma.trigger_fifo(1)
    of etUndefMode:     gba.cpu.undef_mode_tick()
    of etIrqWindowOpen:  gba.interrupts.window_open_event()
    of etIrqWindowClose: gba.interrupts.window_close_event()
    of etHandleInput, etIME, etCameraDone, etGbLycEdge: discard

# Timer prescaler phase at ROM entry when the BIOS boot is skipped. The
# prescaler runs free from power-on (timer.nim) and this core counts it from
# scheduler cycle 0, so a skip-BIOS start at cycle 0 put every /64, /256 and
# /1024 tick in the wrong place. alyosha timer/timer reads a /64 timer ten
# times across three ticks straight after entry: it passes only at 8 mod 64
# (7 misses the first tick, 9 catches the third a read early). The bits above
# 64 are not pinned by any row; 776 is the value nearest the LLE boot's
# own entry (795 mod 1024 here: 75,997,979 cycles to the first ROM fetch).
const SKIP_BIOS_PRESCALER_PHASE {.intdefine.} = 776

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
    # Inside a DMA burst the clock is rewound to the event's cycle; the
    # request stays latched and the burst loop runs run_pending at its next
    # transfer boundary
    if g.dma.pending != 0 and not g.bus.dma_active and not g.bus.swp_lock:
      g.dma.run_pending()
  gba.handle_saves()
  # MP2K HLE: runtime-detected (mp2k.nim); nothing runs unless gba.mp2k_hle
  gba.mp2k = new_mp2k(gba)
  gba.mp2k.init_mp2k()
  # Camelot "Bon" HLE is dormant unless built with -d:gsbon: its shadow mixer
  # frame-quantizes note attacks, audibly worse on percussion. Every consumer
  # nil-checks gs_bon, so not creating it is the off-switch.
  when defined(gsbon):
    gba.gs_bon = new_gs_bon(gba)
    gba.gs_bon.init_gs_bon()
  if not gba.run_bios:
    # The state the BIOS leaves at ROM entry. Derived by logging every I/O
    # write a full BIOS boot makes and then diffing the two boot paths'
    # registers and RAM at ROM entry: what is set below is the whole
    # difference, and it is the same for every ROM.
    gba.cpu.skip_bios()
    # Link port in general-purpose mode (the BIOS's last RCNT write is
    # 0x8000); from RCNT = 0 Sonic Advance 1 and 2 hang at boot
    gba.serial.rcnt = 0x8000
    # PSG and both DMA channels at full volume. The FIFO reset bits the BIOS
    # writes alongside these are write-only.
    gba.apu.soundcnt_h = cast[SOUNDCNT_H](0x000E'u16)
    # The BIOS clears wave RAM; a cold Channel3 holds the GB power-on pattern
    for bank in 0..1:
      for idx in 0 ..< WAVE_RAM_SIZE:
        gba.apu.channel3.wave_ram[bank][idx] = 0
    gba.ppu.skip_boot_phase()

proc handle_saves*(gba: GBA) =
  gba.scheduler.schedule(280896, etSaves)
  gba.storage.write_save()

proc end_frame*(gba: GBA): CycleCount {.discardable.} =
  ## Frame-boundary bookkeeping: rebase the scheduler and every absolute-cycle
  ## anchor so uint32 cycles cannot overflow on WASM; the low 10 bits are kept
  ## so timer prescaler phase survives. Returns the subtracted base for
  ## link.nim's cross-core cycle comparisons.
  if gba.ppu.frame > 0: dec gba.ppu.frame
  # PSG next_step deadlines are absolute cycles held outside the scheduler:
  # catch them up first (every deadline then lies in the future) and move
  # them with the events. This also bounds how far behind an unobserved
  # channel can fall. end_frame is the single funnel for every GBA rebase.
  gba.apu.apu_catchup_all()
  let base = gba.scheduler.rebase(keep_phase_mask = 1023)
  gba.apu.apu_rebase(base)
  # FIFO transfer stamps and the MP2K HLE's pending slot hooks are absolute
  # cycles too (mp2k.nim measure_latency)
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
      # Anchor predates the base: advance it by whole periods (keeping
      # prescaler phase) and compensate the counter. No overflow can hide in
      # the skipped window: its event would have fired and re-anchored.
      let period = CycleCount(TIMER_PERIODS[gba.timer.tmcnt[i].frequency])
      let deficit = base - gba.timer.cycle_enabled[i]
      let k = (deficit + period - 1) div period
      gba.timer.cycle_enabled[i] = gba.timer.cycle_enabled[i] + k * period - base
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
  # The post-DMA open-bus window bounds this stamp against cycles taken from
  # the scheduler, so it has to move with the scheduler. Left behind it sat a
  # whole frame in the future, and the window then could not open again until
  # the next burst re-stamped it.
  if gba.bus.dma_request_at >= base:
    gba.bus.dma_request_at -= base
  else:
    gba.bus.dma_request_at = 0
  if gba.bus.idle_until >= base: gba.bus.idle_until -= base
  else: gba.bus.idle_until = 0
  gba.bus.imm_idle_from = 0
  gba.bus.load_size = 0   # its stamps are not rebased; a frame edge ends it
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
  if gba.interrupts.gate_open_at >= base:
    gba.interrupts.gate_open_at -= base
  else:
    gba.interrupts.gate_open_at = 0
  # IRQ_LAST_WAITS compares these with the scheduler's clock at the next
  # boundary. The frame ends on line 160, four cycles before the V-blank
  # interrupt is recognised, so left behind they never matched for it: every
  # V-blank interrupt skipped the rule (alyosha irq/IRQ_sub_2_slow).
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
  while gba.ppu.frame == 0:
    gba.cpu.tick()
  gba.end_frame()

method run_until_frame*(gba: GBA) = gba.step_frame()

proc handle_input*(gba: GBA; input: Input; pressed: bool) =
  gba.keypad.handle_input(input, pressed)

method toggle_sync*(gba: GBA) =
  gba.apu.toggle_sync()

# Save-state visitor over every component above (also serves rewind/rollback)
include savestate
