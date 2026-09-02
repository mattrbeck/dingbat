# GBA emulator main file
# All types are declared here; implementation files are `include`d.

import std/[options, times, os, strutils, math, sets]
from std/bitops import countLeadingZeroBits, countTrailingZeroBits
import ../common/[util, input, scheduler, emu, resampler, serialize, timestretch, cheats]
when defined(test_harness):
  import ../common/test_output
import ../common/lut_macros

when defined(pftrace):
  # -d:pftrace: dump ROM-bus activity inside each mGBA-suite Timing window
  # (between TM0's enable and disable writes) that contained a DMA grant; this
  # is how bus.rom_access_cycles' hand-off predicate is re-derived. Every call
  # site is `when defined(pftrace)`, so a normal build pays nothing.
  var pft_on*: bool
  var pft_dma*: bool
  var pft_lines*: seq[string]
  proc pft*(s: string) =
    # Bounded: a game can leave TM0 running for whole frames.
    if pft_on and pft_lines.len < 4096: pft_lines.add(s)

include reg

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
    # Not serialized (a ~12-cycle window); rebased by end_frame.
    gate_open_at*: CycleCount

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
    # Internal memory control (0x04000800, mirrored every 64K): readback only;
    # the waitstate/WRAM-disable effects are unimplemented. Reset value
    # 0x0D000020 (gbaedge IDENT page). Neither field is serialized.
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
    # Priority arbitration: bitmask of channels with a latched request, and
    # the channel of the innermost burst in progress (4 = none). A pending
    # channel runs only while its number is below current_priority; a
    # higher-priority request preempts via a nested run_pending. Always 0/4
    # between instructions, so not serialized.
    pending*:          uint8
    current_priority*: int
    # DMA3 video-capture frame latch: set at line 2, cleared with the enable
    # bit at line 162; a channel armed mid-frame waits for the next frame's
    # line 2 (gbaedge CAPDMA page). Not serialized.
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
    # Netplay/rollback: when deterministic, the clock is a frozen UTC epoch
    # both peers agree on instead of the host wall-clock.
    deterministic*: bool
    epoch*:         int64   # unix seconds; the frozen clock when deterministic
    # Last unix minute seen by the per-minute IRQ poll. Not serialized (worst
    # case one spurious or missed tick after a state load).
    irq_minute*:    int64

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
    # True only during a genuine byte-sized store (strb / DMA byte). Wider IO
    # writes decompose into byte writes, and a few registers treat real byte
    # stores differently (gbaedge IOBYTE/DMAEDGE pages). Not serialized.
    byte_io_write*: bool
    wram_board*: seq[byte]
    wram_chip*:  seq[byte]
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
    # Second burst tracker for DMA: src and dst streams interleave on the ROM
    # bus yet each stays sequential, without needing back-to-back bus cycles
    rom_next_addr2*: uint32
    dma_active*:     bool
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
    dma_pending*: bool
    # Open-bus latch left by DMA: the last word a DMA moved stays on the data
    # bus, so an unmapped read by the DMA itself or by the first CPU
    # instruction after the burst sees that word instead of the CPU prefetch
    # (GBATEK "GBA Unpredictable Things" only says the value "might also
    # change if a DMA transfer occurs"). Armed when a burst hands the bus
    # back, cleared at the next instruction boundary (cpu.tick); the
    # one-instruction window is assumed. mGBA suite Misc "DMA Prefetch Read"
    # fails without it. Hello Kitty Collection: Miracle Fashion Maker's boot
    # terminates only when a sound-FIFO DMA's final zero word shows up here.
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
    # True between a PC write and the first opcode fetch at the destination:
    # a write landing near the new PC in that window (an immediate DMA granted
    # right after the branch) must be visible to the refill, so the
    # self-modifying-code pipeline capture in write_*_internal stands down
    # (Golden Sun TLA DMAs a `bx pc` trampoline onto the stack and branches
    # to it before the transfer has run)
    refill_pending*: bool
    reg_banks*:   array[6, array[7, uint32]]
    spsr_banks*:  array[6, uint32]
    halted*:      bool
    stopped*:     bool  # Stop mode: halted, and only keypad/cartridge/SIO IRQs wake
    # Level-triggered IRQ signal (IE & IF != 0 and IME), maintained by
    # check_interrupts; sampled at instruction boundaries only
    irq_line*:    bool
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
    waitloop_instr_lut*:         seq[WLInstrKind]
    # Audio-HLE hook dispatch folded into one sentinel by refresh_hle_hook so
    # the per-instruction path is one load and one branch:
    #   0             -- nothing armed (zero-init = disarmed)
    #   NO_HLE_HOOK   -- the bounded MP2K learning probe is running
    #   anything else -- the pre-pipeline PC that fires a hook
    # A hook PC is a RAM address (never 0) and the pre-pipeline PC is never
    # NO_HLE_HOOK, so the states cannot collide.
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
    # (gba_steps_due). Rebuilt from the period on load.
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
    need_fetch*:  bool      # a new source sample must be decoded this step
    hist_gap*:    uint32    # source samples skipped by a decimating advance (mp2k.nim render_sample)
    tap0*, tap1*, tap2*, tap3*: float32  # 4-tap history, s8 units, tap0 newest
    vol_l0*, vol_l1*: float32
    vol_r0*, vol_r1*: float32
    age*:         int       # frames since (re)trigger; 0 on the attack frame

  Mp2kHle* = ref object
    gba* {.cursor.}: GBA
    hook_addr*:  uint32     # learned mixer entry PC (0xFFFFFFFF = not learned)
    entry_addr*: uint32     # hook_addr with the Thumb bit cleared (skip-mode return point)
    probing*:    bool       # PC probe armed (mp2k.nim "Runtime detection")
    probe_sound_info*: uint32  # &SoundInfo cached for the probe's lock check
    probe_block*: array[8, uint32]  # invalidated candidates (mislearned PCs)
    probe_block_n*: int
    probe_fails*: int       # mislearn count; probing gives up at 8
    skip*:       bool       # EXPERIMENTAL perf probe: force-return the real mixer
    engaged*:    bool       # a valid SoundInfo has been observed at least once
    frame_seen*: bool
    hook_stale*: int32      # frames since the hook last fired (mp2k.nim mixer_live)
    resync_pending*: bool   # re-latch every channel at the engine's position (mp2k_state_loaded)
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
    mono_mode*:      int    # fed FIFO topology: 0 stereo, 1 mono via A, 2 mono via B (on_frame)
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
    # DirectSound double-buffer delay (mp2k.nim render_sample)
    out_delay*:      seq[int16]     # stereo output delay line (2 * db_delay slots)
    out_delay_w*:    int            # write cursor (in stereo frames)
    db_delay*:       int            # delay length in samples (0 disables)

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
    rom_identity*: uint32  ## FNV-1a of the ROM as read from disk. The
                           ## save-state identity reads this, never `rom`:
                           ## cheats patch that buffer in place
                           ## (gba_rom_checksum).
    rom*: seq[byte]        ## sized to the next power of two >= the ROM file
    rom_mask*: uint32      ## rom.len - 1
    rom_size*: int         ## bytes read from the file (no pad, no Classic NES
                           ## mirrors); the netplay CRC and the save-state
                           ## identity hash exactly this range

  GBA* = ref object of EmuObj
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

# Textual includes: the whole GBA core compiles as one module so the C
# compiler inlines across files (notes/architecture.md). The forward
# declarations above make the order mostly arbitrary; the exceptions:
#   * hle_bios before arm/arm and thumb/thumb — both SWI handlers call
#     hle_swi, which has no forward declaration.
#   * arm/arm before arm/lut — `const armLut = armLutBuilder()` resolves the
#     arm_* handlers at compile time; a const cannot be forward-declared.

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
  result.save_path = save_path
  if fileExists(save_path):
    let f = open(save_path, fmRead)
    discard f.readBytes(result.memory, 0, result.memory.len)
    f.close()

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
  # Non-owning capture: the closure lives on the GBA's scheduler
  let gba {.cursor.} = gba
  result = proc(kind: EventType) =
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
  # Non-owning capture: the pump closure lives on the GBA's scheduler
  let g {.cursor.} = gba
  gba.scheduler.pump = proc() =
    # Inside a DMA burst the clock is rewound to the event's cycle; the
    # request stays latched and the burst loop runs run_pending at its next
    # transfer boundary
    if g.dma.pending != 0 and not g.bus.dma_active:
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
    gba.cpu.skip_bios()

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
  if gba.mp2k_hle and gba.mp2k != nil:
    gba.mp2k.mp2k_frame_poll()
  if gba.mp2k_hle and gba.gs_bon != nil:
    gba.gs_bon.gs_frame_poll()
  # Unconditional: this is also what disarms the hook when the setting is
  # turned off or a driver tears down
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
