# GBA emulator main file
# All types are declared here; implementation files are `include`d.

import std/[options, times, os, strutils, math, sets]
from std/bitops import countLeadingZeroBits, countTrailingZeroBits
import ../common/[util, input, scheduler, emu, resampler, serialize, timestretch, cheats]
when defined(test_harness):
  import ../common/test_output
import ../common/lut_macros

when defined(pftrace):
  # MEASUREMENT PROBE (-d:pftrace): dump the ROM bus's activity inside each
  # mGBA-suite Timing measurement window — the span between TM0's enable and
  # disable writes, which is exactly what those tests report. Only windows that
  # contained a DMA grant are printed, so a whole suite run emits ~300 short
  # blocks: the DMA/ROM Timing rows, keyed by the burst's own src/dst/len and
  # by the WAITCNT the column selected. That turns 32 opaque failures into a
  # 256-row offline oracle, which is how the prefetch hand-off predicate in
  # bus.rom_access_cycles was derived and is how to re-derive it. Costs nothing
  # in a normal build; every call site is `when defined(pftrace)`.
  var pft_on*: bool
  var pft_dma*: bool
  var pft_lines*: seq[string]
  proc pft*(s: string) =
    # A real game leaves TM0 running for whole frames; bound the buffer so the
    # probe can be pointed at one without eating the heap.
    if pft_on and pft_lines.len < 4096: pft_lines.add(s)

# Include register definitions (provides PSR, DISPCNT, etc.)
include reg

# ==================== TYPE DECLARATIONS ====================
# All GBA types in one block for forward-reference support.

type
  Pipeline* = object
    buffer*: array[2, uint32]
    pos*:    int
    size*:   int


  StorageType* = enum
    stEEPROM, stSRAM, stFLASH, stFLASH512, stFLASH1M

  StorageObj* = object of RootObj
    memory*:    seq[byte]
    save_path*: string
    dirty*:     bool
  Storage* = ref StorageObj

  SRAM* = ref object of StorageObj

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
    # Absolute bus cycle until which the chip is programming (busy) after a
    # write; the ready-poll read returns 0 until then. Rebased each frame by
    # end_frame (like bus.rom_free_since); deliberately NOT serialized in
    # save states (reset to 0 on load — see load_storage_state).
    busy_until*:    CycleCount

  Interrupts* = ref object
    gba* {.cursor.}:    GBA
    reg_ie*: InterruptReg
    reg_if*: InterruptReg
    ime*:    bool
    # A register write just opened the last gate on a parked IF: recognition
    # (irq_line) is held off until gate_open_at (see IRQ_GATE_DELAY in
    # interrupts.nim). Deliberately NOT serialized: the window is ~12 cycles
    # (the recognizer event that closes it IS serialized), so a state load
    # inside it costs at most one slightly-early IRQ entry. gate_open_at is
    # rebased in end_frame with the other absolute-cycle anchors.
    gate_open_at*: CycleCount

  Keypad* = ref object
    gba* {.cursor.}:      GBA
    keyinput*: KEYINPUT
    keycnt*:   KEYCNT
    prev_irq_condition*: bool  # for edge-triggering the keypad IRQ

  MMIO* = ref object
    gba* {.cursor.}:     GBA
    waitcnt*: WAITCNT
    # POSTFLG (0x04000300): R/W bit0; the BIOS sets it to 1 at first boot.
    # Hardware-verified boot value 01 at ROM entry (gbaedge IDENT page).
    postflg*: uint8
    # Internal memory control (0x04000800, mirrored every 64K): stored for
    # readback only - the waitstate/WRAM-disable effects are deliberately
    # unimplemented. Reset value 0x0D000020 (hardware-verified, IDENT page;
    # dingbat previously returned open bus). Neither field is serialized:
    # postflg is effectively constant after boot and memctrl is write-rare;
    # a state load resets them to the boot values.
    memctrl*: uint32

  Timer* = ref object
    gba* {.cursor.}:          GBA
    tmcnt*:        array[4, TMCNT]
    tmd*:          array[4, uint16]
    tm*:           array[4, uint16]
    cycle_enabled*: array[4, CycleCount]
    # Reload writes latch one cycle late relative to an overflow: an overflow
    # on the cycle right after the write still reloads the old value
    tmd_prev*:        array[4, uint16]
    tmd_write_cycle*: array[4, CycleCount]

  # Link-cable driver interface. The base methods (in serial.nim) implement
  # the exact no-cable behavior, so the base type doubles as the null driver.
  # Drivers are frontend configuration, not emulated state: they are never
  # serialized, and after a save-state load the frontend's configured driver
  # simply remains bound.
  SioDriver* = ref object of RootObj

  Serial* = ref object
    gba* {.cursor.}:        GBA
    driver*:     SioDriver # bound link-cable driver (never nil, not serialized)
    # Multi-mode receive latches (SIOMULTI0-3). Filled only by drivers on
    # transfer completion; CPU writes never land here, so with the null
    # driver they stay 0 (matching no-cable hardware reads). Not serialized:
    # data received mid-link is session state that the next transfer after a
    # load refreshes.
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
    # Internal word count, copied from dmacnt_l when the channel is enabled
    # and reloaded from it at every repeat (GBATEK "DMA Transfer Channels":
    # the internal registers are loaded on enable, and repeat reloads the
    # count). A write to DMACNT_L after the enable write therefore does NOT
    # shorten or lengthen the burst already armed — it takes effect from the
    # next repeat. mGBA suite Misc "DMA count latching" is the fixture.
    count*:     array[4, uint16]
    # Latch per channel: https://github.com/mgba-emu/mgba/issues/2105
    latch*:     array[4, uint32]
    # Priority arbitration: bitmask of channels with a latched transfer
    # request (set by the trigger_* entry points, consumed by run_pending),
    # and the channel number of the innermost burst in progress (4 = none).
    # A pending channel only runs while its number is below current_priority;
    # a higher-priority request arriving mid-burst preempts via a nested
    # run_pending call. Always 0/4 between instructions, so not serialized.
    pending*:          uint8
    current_priority*: int
    # DMA3 video-capture "frame in progress" latch: set at the armed frame's
    # line 2, cleared (with the enable bit) at line 162. A channel armed
    # mid-frame waits for the NEXT frame's line 2 (gbaedge CAPDMA page).
    # Not serialized: a state load mid-capture-frame drops the rest of that
    # frame's triggers (capture DMA is rare and per-frame re-armed).
    video_active*:     bool
  RtcState* = enum
    rtcWaiting, rtcCommand, rtcReading, rtcWriting

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
    irq*:    bool
    m24*:    bool
    # Deterministic clock for netplay/rollback. Normally the RTC reads the host
    # wall-clock (real-time events in single-player). That is non-deterministic
    # across peers (different clocks AND time zones) and across a rollback
    # (re-reads a moving clock), so it desyncs a linked session. When
    # `deterministic` is on, the clock is a fixed UTC epoch both peers agree on
    # (seeded at connect), frozen for the session — a trade lasts minutes, so a
    # still clock is harmless, and it is bit-identical everywhere.
    deterministic*: bool
    epoch*:         int64   # unix seconds; the frozen clock when deterministic
    # Last minute (unix minutes) seen by the per-minute IRQ poll; the IRQ
    # fires when it changes. Deliberately NOT serialized (session state, like
    # the SIOMULTI receive latches): worst case is one spurious or missed
    # minute tick right after a state load, and rollback only runs with a
    # deterministic (frozen) clock where this value never changes.
    irq_minute*:    int64

  GPIO* = ref object
    gba* {.cursor.}:         GBA
    data*:        uint8
    direction*:   uint8
    allow_reads*: bool
    rtc*:         RTC
    # Z-axis gyro (WarioWare: Twisted!, game code RZW*): a serial ADC on the
    # same pins the RTC uses — the two never coexist, so gyro carts bypass
    # the RTC state machine entirely (GBATEK "GBA Cart Gyro Sensor").
    # 16-bit shift register = 4 dummy zeros + 12-bit sample, MSB out on each
    # falling clock edge. gyro_z is the live frontend input (-1..1, CW
    # positive); shift state is transient like the tilt latches.
    gyro_present*: bool
    gyro_z*:       float
    gyro_sample*:  uint16
    gyro_clock*:   bool
    gyro_out*:     uint8

  Bus* = ref object
    gba* {.cursor.}:        GBA
    # Cached to avoid a double pointer-chase on the per-fetch/per-MMIO hot
    # paths (bus_now, catch_up)
    sched*:      Scheduler
    cycles*:     int
    # Cycles already handed to the scheduler mid-instruction by catch_up so
    # MMIO accesses observe the exact cycle they occur on; cpu.tick folds this
    # into the instruction total and resets it
    synced*:     int
    bios*:       seq[byte]
    # True when no BIOS file was loaded and `bios` holds the HLE stub
    # (IRQ dispatcher, reset-vector boot code, sound-driver trampolines).
    # The HLE SWI paths that jump into stub code check this so they stay
    # inert when a real BIOS image is mapped (hle_after_bios mode).
    stub_bios*:  bool
    # True only for the duration of a genuinely BYTE-sized store (CPU strb /
    # DMA byte transfer). Halfword/word IO writes decompose into byte writes
    # internally, and a few registers treat real byte stores specially
    # (DISPSTAT's low byte ignores them; DMA CNT_H byte writes have quirks -
    # gbaedge IOBYTE/DMAEDGE pages). Transient within one store, never
    # serialized.
    byte_io_write*: bool
    wram_board*: seq[byte]
    wram_chip*:  seq[byte]
    gpio*:       GPIO
    # Tilt sensor (Yoshi's Universal Gravitation / Koro Koro Puzzle): byte
    # registers memory-mapped at 0x0E008000-0x0E008500 (GBATEK "GBA Cart
    # Tilt Sensor"), enabled by game code. Latches are transient sensor
    # samples re-taken every frame by the game — deliberately not serialized
    # (same convention as MBC7's accel: worst case one stale read after a
    # state load). tilt_in_* are the live frontend-fed inputs, -1..1.
    tilt_present*: bool
    tilt_armed*:   bool
    tilt_x*:       uint16
    tilt_y*:       uint16
    tilt_in_x*:    float
    tilt_in_y*:    float
    bios_latch*: uint32
    # Instruction-fetch fast path: direct pointer + mask + waitstates for the
    # page PC currently executes from (EWRAM/IWRAM/ROM). The buffers never
    # move and ROM is padded to the full 32 MB mirror, so a cached pointer
    # stays valid; writes to RAM-resident code are visible because fetches
    # read through the pointer into the live buffer.
    fetch_page*: uint32
    fetch_mask*: uint32
    fetch_c16*:  int
    fetch_c32*:  int
    fetch_ptr*:  ptr UncheckedArray[byte]
    # Cached ROM base pointer + length for the data-read path, so a ROM read
    # avoids chasing gba.cartridge.rom and can bounds-check cheaply (reads past
    # the ROM fall back to the open-bus pattern). Set when the cartridge loads.
    rom_ptr*:    ptr UncheckedArray[byte]
    rom_len*:    uint32
    # WAITCNT-derived cycle costs per page (nonseq/seq × 16/32-bit); pages
    # 0-7 are constant, 8-D come from the ROM waitstate fields, E-F from the
    # SRAM field. Recomputed on WAITCNT writes.
    wait16_n*: array[16, int8]
    wait16_s*: array[16, int8]
    wait32_n*: array[16, int8]
    wait32_s*: array[16, int8]
    prefetch_on*: bool
    # Per-page bitmap of the prefetch-hand-off stall (rom_access_cycles): bit
    # `e` is set when a prefetch halfword started `e` cycles ago is in its
    # final, uninterruptible cycle. Precomputed from wait16_s so the hot data
    # path needs a shift, not a division. Bit 63 covers e = 63; the buffer is
    # full (nothing in flight) by e = 8*s <= 72, so only the s = 9 tail needs
    # the modulo fallback.
    pf_commit*: array[16, uint64]
    # ROM bus bookkeeping for sequential-access detection and the prefetch
    # buffer: the address that would continue the current burst, and the
    # absolute cycle at which the ROM bus went idle (prefetch credit accrues
    # from that point while the CPU runs off other memory)
    rom_next_addr*:  uint32
    rom_free_since*: CycleCount
    # Second burst tracker + flag for DMA: a DMA's src and dst streams
    # interleave on the ROM bus yet each stays sequential on hardware, and
    # DMA sequentiality doesn't require back-to-back bus cycles
    rom_next_addr2*: uint32
    dma_active*:     bool
    # Prefetch hand-off to a DMA burst. `rom_free_since` is on the CPU's bus
    # clock while a granted DMA runs on the *event* clock, which tick_slow
    # rewinds to the due event's cycle (scheduler.nim) — so `now - rom_free_since`
    # at a DMA's ROM access is off by however much of the CPU's tick quota is
    # still held back, a skew that swings -2..+1 between otherwise identical
    # runs. The prefetcher's phase therefore cannot be read off that difference.
    # What IS exact is the burst's own elapsed time, so the grant cycle is
    # captured here and the phase counted forward from it.
    # Both are seeded at every grant and consumed inside the same burst, so
    # unlike the burst trackers above they need no serialization.
    dma_grant_now*:  CycleCount
    dma_first_rom*:  bool
    # True while the CPU fetch stream is unbroken: sequential ROM fetches
    # skip the absolute-time bookkeeping entirely. Any other cycle consumer
    # must "cool" the stream (recording rom_free_since) first.
    rom_hot*:        bool
    # True while a delayed immediate DMA is scheduled: data accesses catch
    # the scheduler up so the DMA preempts the CPU at its exact start cycle
    # (a read one instruction after the enable must see the DMA'd data)
    dma_pending*: bool
    # Open-bus latch left by DMA: the last word a DMA moved stays on the data
    # bus, so an unmapped-address read made by the DMA itself, or by the FIRST
    # CPU instruction executed after the burst returns the bus, sees that word
    # instead of the CPU prefetch (the CPU hasn't driven the bus in between).
    # dma_open_bus_armed is set when a burst hands the bus back and cleared at
    # the next instruction boundary (cpu.tick). Matches mGBA's gba->bus +
    # dmaPC-distance model. Hello Kitty Collection: Miracle Fashion Maker's
    # boot walks a NULL task list through open bus and only terminates when a
    # sound-FIFO DMA's final zero word appears in one of these reads.
    dma_open_bus*:       uint32
    dma_open_bus_armed*: bool

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
    # True between a PC write (pipeline flush) and the first opcode fetch at
    # the destination: hardware has not fetched anything there yet, so a write
    # landing near the new PC in that window (an immediate DMA granted right
    # after the branch) must be visible to the refill — the self-modifying-code
    # pipeline capture in write_*_internal has to stand down or it snapshots
    # stale memory (Golden Sun TLA DMAs a `bx pc` trampoline onto the stack
    # and branches to it before the transfer has run)
    refill_pending*: bool
    reg_banks*:   array[6, array[7, uint32]]
    spsr_banks*:  array[6, uint32]
    halted*:      bool
    stopped*:     bool  # Stop mode: halted, and only keypad/cartridge/SIO IRQs wake
    # Level-triggered IRQ signal (IE & IF != 0 and IME), maintained by
    # check_interrupts; sampled at instruction boundaries so events fired
    # mid-instruction can't redirect PC while an instruction executes
    irq_line*:    bool
    # Set when an interrupt wakes the CPU out of halt. Cleared at the first
    # instruction boundary after the wake. The vector sequence costs the same
    # out of halt as out of running execution (see cpu.irq), so nothing reads
    # this any more; it stays because it is part of the serialized CPU state.
    halt_wake*:   bool
    # HLE IntrWait state: while active, the CPU re-halts at resume_addr until
    # the user IRQ handler ORs one of the masked flags into the BIOS interrupt
    # flags mirror at 0x03007FF8
    intr_wait_active*:      bool
    intr_wait_mask*:        uint16
    intr_wait_resume_addr*: uint32
    # HLE Halt/Stop state: the real BIOS executes its SWI-dispatcher return
    # path (bx lr + register restore + movs pc, lr) AFTER the wake IRQ has
    # been serviced, so that cost must land after the wake, not at call time.
    # Charged once when execution reaches the instruction after the SWI.
    halt_resume_charge*:    int32
    halt_resume_addr*:      uint32
    # True when the parked charge belongs to a Halt/Stop SWI, whose entry
    # left the dispatcher's {r2, lr} frame live (System sp shifted down 8);
    # the resume must pop it. Interruptible decompression SWIs park charges
    # on the same fields but never shift sp, so their resume must not.
    halt_resume_pop*:       bool
    # Waitloop fields
    attempt_waitloop_detection*: bool
    cache_waitloop_results*:     bool
    branch_dest*:                uint32
    identified_waitloops*:       HashSet[uint32]
    identified_non_waitloops*:   HashSet[uint32]
    # One-entry cache in front of identified_non_waitloops: a hot game loop
    # re-analyzes the same backward branch every iteration (1 = no entry;
    # thumb addresses are always even)
    last_non_waitloop*:          uint32
    # And the same in front of identified_waitloops. A loop that IS a waitloop
    # re-enters analyze_loop on every one of its iterations and hit the
    # HashSet each time; `contains` was 1.4% of all samples on FireRed.
    # 0 = no entry (a waitloop start is always a ROM address).
    last_waitloop*:              uint32
    entered_waitloop*:           bool
    waitloop_instr_lut*:         seq[WLInstrKind]
    # Audio-HLE hook dispatch, collapsed to one hot-path compare. The MP2K
    # mixer hook, its bounded learning probe, and the Camelot "Bon" hook all
    # sit on the per-instruction path but fire at most once per frame, so
    # testing each one's enable flag + pointer + address every instruction
    # cost more than the mixing itself. Instead every arming site calls
    # refresh_hle_hook, which folds them into a single sentinel:
    #   0             -- nothing armed (and the zero-init value, so a freshly
    #                    constructed CPU is already in the disarmed state)
    #   NO_HLE_HOOK   -- the bounded MP2K learning probe is running
    #   anything else -- the pre-pipeline PC that fires a hook
    # One word, so the non-HLE path really is one load and one
    # perfectly-predicted branch. It was two of each while the probe lived in
    # a separate bool, and that second pair measured 2.5% of all retired
    # instructions on FireRed with audio HLE OFF.
    #
    # The three states cannot collide. A hook PC is a RAM instruction address,
    # so it is never 0; and the pre-pipeline PC can never be NO_HLE_HOOK,
    # which is the assumption the sentinel already rested on.
    hle_gate*:                   uint32

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
    # Count of frame boundaries reached but not yet consumed by a
    # step_frame/end_frame pair. A counter (not a bool) because one CPU
    # "instruction" can span several frames: HLE BIOS decompression SWIs run
    # atomically (faithful — the real BIOS keeps IRQs disabled throughout),
    # and the frames elapsing inside must not collapse into one or the
    # frontend's frame count drifts against real hardware.
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
    # Compositing scratch, recomputed each scanline: BGs that can contribute,
    # flattened into a single (priority, BG index)-ordered walk list, and
    # per-column window enable bits
    walk_bgs*:     array[4, int8]  # BG number of each walk entry
    walk_prios*:   array[4, int8]  # priority of each walk entry
    walk_n*:       int
    line_enables*: array[240, uint16]
    line_effects*: array[240, bool]
    line_sprite_blend*: bool  # any semi-transparent sprite pixel on this line
    line_obj_window*: bool    # any OBJ-window sprite pixel on this line
    # Per-line OBJ candidate list. obj_line_mask[line] is a 128-bit set (two
    # words, entry N = bit N&63 of word N>>6) of the OAM entries whose screen
    # bounding box covers that line -- i.e. exactly the entries that survive
    # render_sprites' vertical/horizontal reject tests. Games leave 0.2-1.7
    # sprites on a line, so iterating the set bits replaces a 128-entry scan.
    # Rebuilt lazily: obj_list_dirty is set by every path that can mutate OAM
    # (see oam_touched) and cleared by rebuild_obj_lines. obj_list_rebuilds
    # counts rebuilds within the current frame; past OBJ_LIST_REBUILD_LIMIT
    # the rest of the frame falls back to the straight scan, so a game that
    # DMAs OAM every H-blank cannot end up slower than the old code. Pure
    # scratch: derived from OAM alone, so it is not serialized.
    obj_line_mask*:     array[160, array[2, uint64]]
    obj_list_dirty*:    bool
    obj_list_rebuilds*: int
    # Render skipping: render_dirty is set by anything that can change the
    # picture (VRAM/PRAM/OAM writes, PPU register writes, Stop transitions).
    # When a full frame passes with no such change, the framebuffer already
    # holds exactly what every scanline would render, so rendering is skipped
    # until the next change. frame_static tells frontends the framebuffer is
    # unchanged so they can skip the texture upload too.
    render_dirty*: bool
    skip_render*:  bool
    frame_static*: bool
    # Speed mode: render only every (frameskip+1)th frame. A force-skipped
    # frame leaves render_dirty accumulated so the next rendered frame
    # repaints everything that changed meanwhile. 0 = off.
    frameskip*:    int
    fs_counter*:   int
    forced_skip*:  bool
    # Debug-UI layer visibility (bits 0-3 = BG0-3, bit 4 = OBJ; 1 = shown).
    # ANDed into the per-scanline enable computation only, so the per-pixel
    # compositing hot path is untouched.
    debug_layer_mask*: uint16
    # Forces composite() to build the per-column window tables even on lines
    # whose window state is provably uniform. Exists so the differential test
    # in tests/ppucomposite_test.nim can run the general path and the fast
    # path over the same registers and compare; nothing else sets it, and the
    # default (false = fast path allowed) is the zero value.
    disable_uniform_window*: bool

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
    # Absolute scheduler cycle of the next waveform step, or GBA_NO_STEP when
    # the channel has never been triggered (or was parked by RegisterRamReset).
    # Replaces a per-period scheduler event: the phase is advanced in closed
    # form when something observes it (see ch1_catchup and the observation-point
    # list in gba/apu.nim). NOT serialized as a field — savestate.nim converts
    # it to/from an etAPUChannel1 event so the state format is unchanged, which
    # is also what carries it through rollback/netplay LinkSnapshots.
    next_step*:          CycleCount
    # Delay the pending step was armed with. Only used to reproduce the old
    # scheduler's tie-break when a step lands on exactly an observer's cycle
    # (gba_steps_due); it differs from the current period across a mid-flight
    # frequency write and after a trigger. Transient — savestate.nim rebuilds
    # it from the period on load.
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
    # --- FIFO reconstruction (render-side, not serialized) ---
    # Real hardware feeds the FIFO latch to a high-rate PWM DAC + analog
    # low-pass; point-sampling the held latch at 32768 Hz folds zero-order-
    # hold images into the audible band as hiss. We reconstruct the band-
    # limited signal between timer-driven FIFO updates with a causal
    # Catmull-Rom cubic (Paul Bourke, "Cubic Interpolation"). hist[ch] holds
    # the last four latched samples (index 0 oldest .. 3 newest).
    # last_update_cycle is the scheduler-cycle timestamp of the newest latch
    # and inv_period the reciprocal of the measured update period in cycles —
    # together the exact fractional phase between updates at any FIFO rate.
    # inv_period 0 means "no period measured yet" (fresh boot / FIFO reset)
    # and falls back to the held latch. int64 timestamp so the per-frame
    # rebase subtraction can transiently go negative without wrap.
    # fifo_interp=false (the "hardware-accurate" setting) bypasses all of it
    # and emits the raw held latch — bit-true to the DAC's electrical output.
    hist*:            array[2, array[4, int16]]
    last_update_cycle*: array[2, int64]
    inv_period*:        array[2, float32]
    fifo_interp*:     bool   # cubic FIFO reconstruction (default on)

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
    # Master volume as an 8.8 fixed-point factor (256 = unity), precomputed
    # so queue-time scaling stays one integer multiply+shift per sample
    master_volume_factor*: int32
    master_muted*:      bool
    # 2x speed: drop every other stereo frame at the queue point so
    # audio-driven pacing runs emulation twice as fast
    turbo*:             bool
    turbo_parity:       bool  # emscripten per-sample decimation state
    # Pitch-correct fast-forward: when on, WSOLA time-stretch replaces the
    # every-other-sample decimation at 2x so audio keeps its pitch. Off = the
    # historical cheap decimation (bit-identical to before). Presentation-only:
    # not serialised, reset when turbo toggles on.
    pitch_correct_ff*:  bool
    stretch:            TimeStretch
    stretch_engaged:    bool  # tracks the stretch-path rising edge (auto-reset)
    audio_dev*:         uint32  # SDL2 AudioDeviceID (0 = not open)
    # Optional analog-output low-pass (models the GBA cap/speaker smoothing).
    # Off by default so output is bit-identical to the unfiltered path; when
    # on, a one-pole IIR runs on the final native mix (web uses a BiquadFilter
    # node in the AudioContext graph instead). lp_left/lp_right are the filter
    # state; presentation-only, not serialized.
    audio_lowpass*:     bool
    lp_left, lp_right:  float32
    left_resampler*:    Resampler[float32]
    right_resampler*:   Resampler[float32]
    resample_freq*:     int
    output_freq*:       int

  # EXPLORATORY: MP2K/M4A sound-engine HLE state (see mp2k.nim). Off by default.
  # Field names follow the m4a WaveData layout (loop_start, sample_count) from
  # the pret m4a_internal.h decompilation where they name a format field, and
  # our own terms for the resampler's private working state.
  Mp2kSampler* = object
    active*:      bool
    wave_data*:   uint32
    rom_off*:     uint32    # cached ROM byte offset of the sample data (in_rom)
    in_rom*:      bool      # sample bytes live in cartridge ROM (fast path)
    sample_count*: uint32   # WaveData.size (m4a_internal.h): number of source samples
    loop_start*:  uint32    # WaveData.loopStart (m4a_internal.h): loop restart index
    looping*:     bool
    freq*:        uint32
    compressed*:  bool      # m4a BDPCM ("compressed waveform"): TONEDATA_TYPE_CMP/REV
                            # routing with a compressed WaveData header (see mp2k.nim)
    use_pcm_rate*: bool     # TONEDATA_TYPE_FIX (type bit3): step at SoundInfo.pcmFreq
    reversed*:    bool      # TONEDATA_TYPE_REV (type bit4): play the sample backward
    start_off*:   uint32    # note-on sample start offset (SoundChannel.count at START)
    # BDPCM decoded-block cache, mirroring the real driver's block-at-a-time
    # decode into sDecodingBuffer keyed by a cached block index (SoundChannel
    # xpi; see SoundMainRAM_Unk2 in pret pokeemerald m4a_1.s):
    blk_index*:   uint32    # block number currently decoded in blk (0xFFFFFFFF = none)
    blk*:         array[64, int8]  # decoded s8 samples of that block
    # Private resampler working state: a forward-stepping polyphase resampler
    # keeps an integer read cursor, a fractional phase, and a short tap history.
    src_index*:   uint32    # integer sample read cursor (block/offset derived from this)
    phase_frac*:  float32   # fractional phase (mu) between fetched samples, 0..1
    need_fetch*:  bool      # a new source sample must be decoded this step
    hist_gap*:    uint32    # source samples skipped by a decimating (step > 1)
                            # advance; the next fetch backfills the tap history
                            # with the ADJACENT samples so interpolation always
                            # spans neighbouring source samples (like the real
                            # mixer), never stride-spaced fetches — which would
                            # act as a lowpass and gut bright decimated voices
    tap0*, tap1*, tap2*, tap3*: float32  # 4-tap history, s8 units, tap0 newest
    vol_l0*, vol_l1*: float32
    vol_r0*, vol_r1*: float32
    age*:         int       # frames since (re)trigger; 0 on the attack frame

  Mp2kHle* = ref object
    gba* {.cursor.}: GBA
    hook_addr*:  uint32     # learned SoundMainRAM entry PC (0xFFFFFFFF = not learned)
    entry_addr*: uint32     # hook_addr with the Thumb bit cleared (skip-mode return point)
    # Runtime-detection state (see mp2k.nim "Runtime detection"): the frame
    # poll arms `probing` once the SoundInfo ident magic appears; cpu.tick then
    # watches for the first RAM-fetched PC with r0 == &SoundInfo while the
    # engine lock is held — that is the mixer entry.
    probing*:    bool       # PC probe armed (only until the hook is learned)
    probe_sound_info*: uint32  # &SoundInfo cached for the probe's lock check
    probe_block*: array[8, uint32]  # invalidated candidates (mislearned PCs)
    probe_block_n*: int
    probe_fails*: int       # mislearn count; probing gives up at 8
    skip*:       bool       # EXPERIMENTAL perf probe: force-return the real mixer
    engaged*:    bool       # a valid SoundInfo has been observed at least once
    frame_seen*: bool
    # Frames since the learned mixer hook last fired (incremented by the frame
    # poll, zeroed by on_frame; saturates). When SoundMain stops running —
    # m4aSoundVSyncOff parks ident and a stock driver's SoundMain refuses to
    # run — the engine provably is not producing the FIFO stream, so
    # substitution must pass the real stream through (Disney's Lilo & Stitch
    # VSyncOffs its idle m4a at the title screen and re-points DMA1 at its own
    # streamer's buffer; substituting the dead engine's silence muted the
    # whole soundtrack). Reversible by design: the moment the mixer runs
    # again, substitution resumes — unlike fifo_foreign, no enhancement is
    # permanently sacrificed. See mp2k.nim `mixer_live`.
    hook_stale*: int32
    # Set by mp2k_state_loaded (save-state / rollback load): the shadow mixer
    # state is deliberately NOT serialized, so the next mixer pass must re-latch
    # every channel from the engine's SoundInfo — resuming mid-note channels at
    # the engine's current playback position instead of retriggering them.
    resync_pending*: bool
    samplers*:   array[12, Mp2kSampler]
    frame_len*:  int
    frame_pos*:  int
    compressed_skipped*: int
    dbg_compressed_used*: int   # frames*channels where a BDPCM voice was live
    dbg_skip_fires*: int
    dbg_hook_fires*: int
    dbg_overlay_triggers*: int  # overlay passthrough entries (idle->held)
    dbg_overlay_passes*: int    # mixer passes spent in overlay passthrough
    dbg_unlatches*: int         # fifo_foreign latches reversed by agreement
    dbg_probe_hits*: int   # probe prefilter passes (RAM PC + r0 == &SoundInfo)
    dbg_probe_ident*: uint32  # ident seen at the last probe hit
    dbg_out_energy*: float64
    dbg_out_count*:  int
    dbg_reverb*:     uint8
    dbg_pcm_rate*:   int
    pcm_sample_rate*: int
    reverb_strength*: uint8
    use_cubic*:      bool
    env_mode*:       int           # DIAG: 0=ramp,1=constant-current
    resample_mode*:  int           # DIAG: 0=cubic,1=linear,2=nearest(hold)
    makeup*:         float32        # DIAG: output makeup gain override (0 => built-in default)
    master_apply*:   int            # DIAG: 1 => re-apply SoundInfo.masterVolume (double-applies; wrong)
    # FIFO topology, observed from the live DMA registers each mixer pass (see
    # on_frame): some m4a vintages mix MONO — one pcmBuffer fed to a single
    # FIFO (e.g. Minish Cap: DMA1->FIFO A routed to both speakers, DMA2 off),
    # with a single per-channel volume at SoundChannel+0x0A and +0x0B unused.
    # 0 = stereo (L->FIFO A, R->FIFO B), 1 = mono via FIFO A, 2 = mono via B.
    mono_mode*:      int
    # Foreign FIFO feeder detected (see on_frame): some games ship the m4a
    # driver (for SFX/jingles) but stream their MUSIC into the DirectSound
    # FIFOs with their OWN code — e.g. Batman Vengeance / Altered Beast /
    # Army Men CPU-write the FIFO registers from a timer IRQ; no m4a
    # SoundChannel is ever active, so the shadow mixer would substitute
    # silence for real music. The m4a driver only ever feeds the FIFOs via
    # DMA1/2 in special timing sourcing its own pcmBuffer, so any other
    # sustained feeder means the engine does not own the audio stream:
    # substitution is latched off for the session (the shadow stays inert).
    fifo_foreign*:   bool
    foreign_streak*: int
    fifo_cpu_bytes*: int   # FIFO bytes written by anything but special DMA1/2
    fifo_cpu_last*:  int   # counter snapshot at the previous mixer pass
    # Real-vs-shadow energy comparison (the catch-all foreign signal: some
    # streamers fill pcmBuffer just-in-time mid-frame and erase it after the
    # DMA drains, invisible to any state poll). Accumulated per output sample
    # in apu.get_sample, evaluated per mixer pass in on_frame.
    # Split per FIFO side: some games overlay their own stream onto ONE half
    # of the engine's pcmBuffer (Kinniku Banzuke streams announcer speech into
    # the B half while m4a music plays), so a combined sum dilutes the signal.
    real_abs_a*:     int64  # sum |real FIFO A latch| since last mixer pass
    real_abs_b*:     int64  # sum |real FIFO B latch| since last mixer pass
    hle_abs_l*:      int64  # sum |shadow render L|   since last mixer pass
    hle_abs_r*:      int64  # sum |shadow render R|   since last mixer pass
    ab_n*:           int    # samples accumulated
    # Transient foreign-overlay passthrough (see on_frame): when the real
    # drained stream on either FIFO side carries sustained energy well above
    # our shadow render of the same side, the game is streaming audio the
    # engine (and therefore our shadow) does not produce — announcer speech,
    # voice-clip stingers — mixed AROUND the m4a channels into pcmBuffer or
    # the FIFOs just-in-time. While held, the real stream is emitted and the
    # shadow keeps rendering warm underneath (span-matched captures, seamless
    # resume). Reversible per pass — unlike fifo_foreign, no enhancement is
    # permanently sacrificed. Decremented on clean passes; re-armed on
    # evidence, so sentence-cadence speech does not flap.
    overlay_hold*:   int32
    # EXE3-class unlatch (see on_frame): while fifo_foreign is latched but m4a
    # channels are active, the shadow keeps rendering un-emitted so sustained
    # shadow-vs-real agreement can prove the engine owns the stream and re-arm
    # substitution. unlatch_watch mirrors "any sampler active" for apu's
    # watch-render branch; unlatch_agree counts consecutive agreement passes.
    unlatch_watch*:  bool
    unlatch_agree*:  int32
    dbg_real_avg*:   float32
    dbg_hle_avg*:    float32
    # Mixer passes since the shadow last produced audio. Gates energy-based
    # foreign evidence: for up to pcmDmaPeriod (<= 16) frames after a song
    # stops, the REAL ring legitimately drains audio our (1-frame-delayed)
    # shadow no longer renders — that tail must not count as foreign.
    shadow_quiet_age*: int
    # Faithful m4a reverb state: a shadow of the engine's pcmBuffer frame ring
    # (s8 pcmBuffer[PCM_DMA_BUF_SIZE * 2] in pret m4a_internal.h — a ring of
    # pcmDmaPeriod one-V-blank slots per stereo half) kept at our render rate.
    # See the "MP2K reverb" block in mp2k.nim render_sample for the algorithm.
    reverb_ring*:    seq[float32]  # rev_period slots x MP2K_REV_SLOT_LEN stereo samples
    rev_slot*:       int           # current frame slot (the one being overwritten)
    rev_pos*:        int           # intra-frame sample index within the slot
    rev_period*:     int           # ring length in V-blank frames = SoundInfo.pcmDmaPeriod
    # The ring is kept at the ENGINE's sample rate (pcmSamplesPerVBlank cells
    # per slot), exactly like the real pcmBuffer: our 32768 Hz wet output is
    # point-sampled into cells and the seed taps replay a cell across the
    # output samples it spans (zero-order hold — the same shape the real DMA/
    # DAC replay gives the drained buffer). Keeping the ring at our full
    # render rate made the recirculated content too broadband: the real
    # buffer's band-limited content self-correlates ~3.5x more at the
    # one-frame tap lag, and the 4-tap seed (two consecutive frames) turns
    # that correlation into loop gain — the high-reverb cluster's missing
    # tail energy (FireRed forced-reverb A/B: ratio 1.00 at reverb 50 sliding
    # to 0.91 at 100 before this).
    rev_spv*:        int           # cells per slot = SoundInfo.pcmSamplesPerVBlank
    rev_phase*:      float32       # cell-position accumulator (pcmFreq/32768 per sample)
    rev_cell*:       int           # last cell written this pass (-1 = none)
    rev_seed*:       float32       # seed held across the current cell's output samples
                                   # (SampleFreqSet: PCM_DMA_BUF_SIZE / pcmSamplesPerVBlank)
    # DirectSound double-buffer emulation: the real m4a driver mixes a pcmBuffer
    # one frame ahead of the DMA that plays it, so its FIFO output lags the mixer
    # pass by ~one frame. We render at the mixer pass, so without this the HLE
    # leads the hardware FIFO by a frame. This ring delays our output to match.
    out_delay*:      seq[int16]     # stereo output delay line (2 * db_delay slots)
    out_delay_w*:    int            # write cursor (in stereo frames)
    db_delay*:       int            # delay length in samples (0 disables)

  # Camelot "Bon" sound-driver HLE state (Golden Sun; see
  # gs_bon.nim). Off by default; shares the mp2k_hle enable flag but keeps its
  # own engaged state (the two HLEs are structurally mutually exclusive).
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
    rom_identity*: uint32  ## FNV-1a of the ROM as it came off disk, taken
                           ## once at load. The save-state ROM identity
                           ## reads THIS, never the live `rom` buffer:
                           ## cheats patch that buffer in place, so hashing
                           ## it made enabling a Game Genie code orphan the
                           ## player's save states. See gba_rom_checksum.
    rom*: seq[byte]        ## sized to the next power of two >= the ROM file
    rom_mask*: uint32      ## rom.len - 1 (rom.len is always a power of two)
    rom_size*: int         ## bytes actually read from the file, i.e. rom minus
                           ## the power-of-two zero pad (and minus the Classic
                           ## NES 4x mirrors). The netplay ROM CRC and the
                           ## save-state ROM identity are both taken over
                           ## exactly this range, so they match a peer (or an
                           ## older build) that hashed the file itself, and
                           ## neither moves if the allocation rule changes.

  GBA* = ref object of EmuObj
    bios_path*:  string
    rom_path*:   string
    run_bios*:   bool
    use_hle*:        bool
    hle_after_bios*: bool
    scheduler*:      Scheduler
    # Emulated cycle at which the current frame started, so a frame-progress
    # readout can be derived instead of counted. CPU.count_cycles used to
    # accumulate `max(1, total)` on EVERY instruction for one debug progress
    # bar; stubbing that add out measured 2.2% of all retired instructions.
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
    # EXPLORATORY: MP2K/M4A sound-engine HLE (off by default). See mp2k.nim.
    mp2k*:       Mp2kHle
    mp2k_hle*:   bool
    # Camelot "Bon" driver HLE (Golden Sun). See gs_bon.nim.
    gs_bon*:     GsBonHle
    # Speed mode (low-end devices): every memory access costs 2^underclock
    # times its real cycles (the scaling lives in the bus waitstate tables —
    # see update_waitcnt — so the hot path pays nothing). The emulated CPU
    # runs at roughly 1/2 (1) or 1/4 (2) speed against an unchanged
    # video/timer clock; CPU-bound games drop internal frames, idle-bound
    # games are unaffected. Set via set_underclock, 0 = off.
    underclock*: int
    dma*:        DMA
    serial*:     Serial
    cheats*:     CheatEngine
    cheat_hooks: MemHooks        # built once, reused each frame (see apply_cheats)
    when defined(test_harness):
      test_output*: TestOutput

# ==================== INCLUDE IMPLEMENTATIONS ====================

# Forward declarations to handle circular include dependencies
proc irq*(cpu: CPU)
proc und*(cpu: CPU)
proc schedule_interrupt_check*(intr: Interrupts; delay: int = 0)
proc read_open_bus_value*(bus: Bus; address: uint32): uint8
proc rom_cool*(bus: Bus) {.inline.}
proc add_cycles*(bus: Bus; n: int) {.inline.}
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
proc write_half_internal*(bus: Bus; address: uint32; value: uint16)
proc write_word_internal*(bus: Bus; address: uint32; value: uint32)
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
proc mixer_hook*(m: Mp2kHle)
proc probe_pc*(m: Mp2kHle; pc: uint32) {.noinline.}
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
proc request_immediate*(dma: DMA)
proc trigger_video_capture*(dma: DMA; vcount: uint16)
proc catch_up(bus: Bus) {.inline.}
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
proc lsl*(cpu: CPU; word: uint32; bits: uint32; carry_out: ptr bool): uint32 {.inline.}
proc lsr*(cpu: CPU; word: uint32; bits: uint32; immediate: bool; carry_out: ptr bool): uint32 {.inline.}
proc asr*(cpu: CPU; word: uint32; bits: uint32; immediate: bool; carry_out: ptr bool): uint32 {.inline.}
proc ror*(cpu: CPU; word: uint32; bits: uint32; immediate: bool; carry_out: ptr bool): uint32 {.inline.}
proc sub*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 {.inline.}
proc sbc*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 {.inline.}
proc add*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 {.inline.}
proc adc*(cpu: CPU; operand_1, operand_2: uint32; set_conditions: bool): uint32 {.inline.}
proc clear_pipeline*(cpu: CPU)
proc read_instr*(cpu: CPU): uint32 {.inline.}
proc mode_bank*(m: CpuMode): int

# ==================== IMPLEMENTATION INCLUDES ====================
# Textual includes, not imports: the whole GBA core compiles as this one
# module (a single C translation unit), so the files below share one
# namespace and the C compiler inlines across them without LTO — see
# notes/architecture.md. Cross-include calls are satisfied by the
# forward-declaration block above, which makes the order below mostly
# arbitrary; the verified exceptions:
#   * hle_bios before arm/arm and thumb/thumb — both SWI handlers call
#     hle_swi, defined in hle_bios.nim with no forward declaration above.
#   * arm/arm before arm/lut — `const armLut = armLutBuilder()` resolves the
#     arm_* handler names at compile time; a const cannot be forward-declared.

# CPU fetch pipeline
include pipeline
# Cartridge: ROM image, save memory, GPIO-attached RTC
include cartridge
include storage
include storage/sram
include storage/flash
include storage/eeprom
include rtc
include gpio
# Interrupt controller + keypad input
include interrupts
include keypad
# CPU decode/execute: idle-loop fast-forward, HLE BIOS, ARM + THUMB cores
# (ordering constraints above), stepping loop
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
  var realDmaCapture*: seq[int16] = @[]
  var dbgRetrigCount*: int = 0
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
include mmio

proc new_storage*(gba: GBA; rom_path: string): Storage =
  let save_path = rom_path[0 ..< rom_path.rfind('.')] & ".sav"
  var t = find_storage_type(rom_path)
  when defined(yoshi_eeprom_pin):
    # Tilt carts really save to EEPROM; the string scan can misread them as
    # SRAM (which then aliases save bytes under the tilt registers). Behind
    # a define until the pin-by-game-code policy is decided for real.
    if gba.cartridge != nil and
       gba.cartridge.game_code() in ["KYGE", "KYGJ", "KYGP", "KHPJ"]:
      t = stEEPROM
  result = case t
    of stEEPROM:                        new_eeprom(gba)
    of stSRAM:                          new_sram()
    of stFLASH, stFLASH512, stFLASH1M:  new_flash(t)
  result.save_path = save_path
  if fileExists(save_path):
    let f = open(save_path, fmRead)
    discard f.readBytes(result.memory, 0, result.memory.len)
    f.close()

# ==================== GBA PROCS ====================

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

proc gba_dispatch(gba: GBA): proc(kind: EventType) {.closure.} =
  # Capture a non-owning ref: this closure is stored on the GBA's scheduler, so
  # an owning capture would form a reference cycle back to the GBA.
  let gba {.cursor.} = gba
  result = proc(kind: EventType) =
    case kind
    of etAPUFrameSeq:   gba.apu.tick_frame_sequencer()
    of etAPUSample:     gba.apu.get_sample()
    # The PSG no longer schedules per-waveform-period channel events — each
    # channel carries a next_step deadline advanced in closed form at the points
    # that can observe it (see gba/apu.nim). These arms stay reachable only for a
    # state saved by an older build, whose etAPUChannel* events gba_apply_state
    # drains into next_step before the first tick; if one ever slips through,
    # dropping it is strictly better than restarting an event chain that nothing
    # reads.
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
    of etDMA:           gba.dma.request_immediate()
    of etRtcSecond:     gba.rtc_irq_poll()
    of etHandleInput, etIME, etCameraDone, etGbLycEdge: discard

proc post_init*(gba: GBA) =
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
  # Capture a non-owning ref so the pump closure (stored on the GBA's scheduler)
  # doesn't form a reference cycle back to the GBA.
  let g {.cursor.} = gba
  gba.scheduler.pump = proc() =
    # While a DMA burst is running, its own drain dispatched this event with
    # the clock rewound to the event's cycle; the request must instead be
    # granted at the burst's current transfer boundary, so leave it latched —
    # the burst loop runs run_pending itself after its drain completes.
    if g.dma.pending != 0 and not g.bus.dma_active:
      g.dma.run_pending()
  gba.handle_saves()
  # EXPLORATORY: MP2K HLE. Detection is runtime-driven (per-frame poll + PC
  # probe, see mp2k.nim); nothing runs unless gba.mp2k_hle is set.
  gba.mp2k = new_mp2k(gba)
  gba.mp2k.init_mp2k()
  # Camelot "Bon" HLE (Golden Sun) is compiled-in but DORMANT unless built
  # with -d:gsbon: its shadow mixer nails the tones (peaks to 0.1 Hz) but
  # frame-quantizes note attacks, which reads as "crinkly" on percussion —
  # a net negative for listening until note events are captured at sub-frame
  # precision. Every consumer site nil-checks gs_bon, so skipping creation
  # is the whole off-switch; the module still compiles (no bitrot) and the
  # "Enhanced music synthesis" setting then governs only the m4a MP2K HLE.
  when defined(gsbon):
    gba.gs_bon = new_gs_bon(gba)
    gba.gs_bon.init_gs_bon()
  if not gba.run_bios:
    gba.cpu.skip_bios()

proc handle_saves*(gba: GBA) =
  gba.scheduler.schedule(280896, etSaves)
  gba.storage.write_save()

proc end_frame*(gba: GBA): CycleCount {.discardable.} =
  ## Frame-boundary bookkeeping: clear the frame flag and rebase the
  ## scheduler and timer cycle references to prevent uint32 overflow on
  ## WASM. The low 10 bits stay so free-running timer prescaler phase (up to
  ## 1024 cycles) is preserved across the rebase. Returns the subtracted
  ## base so a link coordinator (link.nim) can keep cross-core cycle
  ## comparisons valid across rebases.
  if gba.ppu.frame > 0: dec gba.ppu.frame
  # The PSG channels' next_step deadlines are ABSOLUTE cycles held outside the
  # scheduler's event array, so they have to move with the events. Catching them
  # up first is what makes the subtraction safe (every deadline is then strictly
  # in the future) AND doubles as the staleness valve: no deadline is ever more
  # than one frame behind, which bounds channel 4's shift loop and keeps the
  # wasm build's uint32 cycle counter from wrapping under a channel nobody has
  # looked at. end_frame is the single funnel for every GBA rebase (step_frame,
  # link.nim, netcore.nim), so this covers them all.
  gba.apu.apu_catchup_all()
  let base = gba.scheduler.rebase(keep_phase_mask = 1023)
  gba.apu.apu_rebase(base)
  for i in 0..3:
    if gba.timer.cycle_enabled[i] >= base:
      gba.timer.cycle_enabled[i] -= base
    elif gba.timer.tmcnt[i].enable and not gba.timer.tmcnt[i].cascade:
      # Anchor predates the rebase base: advance it by whole periods (which
      # keeps prescaler phase) and compensate the counter value. No overflow
      # can hide in the skipped window - the overflow event would have fired
      # and re-anchored.
      let period = CycleCount(TIMER_PERIODS[gba.timer.tmcnt[i].frequency])
      let deficit = base - gba.timer.cycle_enabled[i]
      let k = (deficit + period - 1) div period
      gba.timer.cycle_enabled[i] = gba.timer.cycle_enabled[i] + k * period - base
      gba.timer.tm[i] += uint16(k)
    else:
      # Cascade/disabled: the anchor is unused while in this mode; keep it in
      # range without touching the counter
      gba.timer.cycle_enabled[i] = 0
    if gba.timer.tmd_write_cycle[i] >= base:
      gba.timer.tmd_write_cycle[i] -= base
    else:
      gba.timer.tmd_write_cycle[i] = 0
  if gba.bus.rom_free_since >= base:
    gba.bus.rom_free_since -= base
  else:
    gba.bus.rom_free_since = 0
  if gba.interrupts.gate_open_at >= base:
    gba.interrupts.gate_open_at -= base
  else:
    gba.interrupts.gate_open_at = 0
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
  # EXPLORATORY: MP2K HLE — cheap per-frame presence poll + probe arming (runs
  # only when the HLE is enabled; see mp2k.nim "Runtime detection").
  if gba.mp2k_hle and gba.mp2k != nil:
    gba.mp2k.mp2k_frame_poll()
  # Camelot "Bon" HLE (Golden Sun) — same enable flag, its own
  # magic + code-fingerprint detection (see gs_bon.nim).
  if gba.mp2k_hle and gba.gs_bon != nil:
    gba.gs_bon.gs_frame_poll()
  # Fold whatever the polls just armed (and any external mp2k_hle toggle) into
  # the CPU's single hot-path hook sentinel. Unconditional: this is also what
  # disarms the hook when the setting is turned off or a driver tears down.
  gba.refresh_hle_hook()
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
