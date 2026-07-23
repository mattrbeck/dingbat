# GBA emulator main file
# All types are declared here; implementation files are `include`d.

import std/[options, times, os, strutils, math, sets]
from std/bitops import countLeadingZeroBits, countTrailingZeroBits
import ../common/[util, input, scheduler, emu, resampler, serialize, timestretch, cheats]
when defined(test_harness):
  import ../common/test_output
import lut_macros

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

  Keypad* = ref object
    gba* {.cursor.}:      GBA
    keyinput*: KEYINPUT
    keycnt*:   KEYCNT
    prev_irq_condition*: bool  # for edge-triggering the keypad IRQ

  MMIO* = ref object
    gba* {.cursor.}:     GBA
    waitcnt*: WAITCNT

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
    wram_board*: seq[byte]
    wram_chip*:  seq[byte]
    gpio*:       GPIO
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
    # True while the CPU fetch stream is unbroken: sequential ROM fetches
    # skip the absolute-time bookkeeping entirely. Any other cycle consumer
    # must "cool" the stream (recording rom_free_since) first.
    rom_hot*:        bool
    # True while a delayed immediate DMA is scheduled: data accesses catch
    # the scheduler up so the DMA preempts the CPU at its exact start cycle
    # (a read one instruction after the enable must see the DMA'd data)
    dma_pending*: bool

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
    # Set when an interrupt wakes the CPU out of halt; the next IRQ taken
    # skips the exception-entry overhead (hardware vectors 2 cycles faster
    # out of halt than out of running execution). Consumed/cleared at the
    # first instruction boundary after the wake.
    halt_wake*:   bool
    # Tracks whether the instruction that just completed was an exception
    # return (subs pc, lr / ldmfd {..., pc}^ — a CPSR-restoring PC write). An
    # IRQ recognized at the very next boundary overlaps one of the return's two
    # pipeline-refill fetches with the IRQ vector fetch, so back-to-back
    # exception re-entries vector 1 cycle faster than an IRQ interrupting a
    # straight-line instruction stream. This makes the mGBA count-up test's
    # repeated overflow->IRQ->return->IRQ chain accumulate the correct frozen
    # timer value (each extra re-entry was otherwise 1 cycle too slow).
    instr_exc_return*:      bool
    last_instr_exc_return*: bool
    count_cycles*: int
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
    entered_waitloop*:           bool
    waitloop_instr_lut*:         seq[WLInstrKind]

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
    frame*:        bool
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
    # Render skipping: render_dirty is set by anything that can change the
    # picture (VRAM/PRAM/OAM writes, PPU register writes, Stop transitions).
    # When a full frame passes with no such change, the framebuffer already
    # holds exactly what every scanline would render, so rendering is skipped
    # until the next change. frame_static tells frontends the framebuffer is
    # unchanged so they can skip the texture upload too.
    render_dirty*: bool
    skip_render*:  bool
    frame_static*: bool
    # Debug-UI layer visibility (bits 0-3 = BG0-3, bit 4 = OBJ; 1 = shown).
    # ANDed into the per-scanline enable computation only, so the per-pixel
    # compositing hot path is untouched.
    debug_layer_mask*: uint16

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
    duty*:               uint8
    length_load*:        uint8
    frequency_ch2*:      uint16

  Channel3* = ref object of SoundChannel
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
    # the last four latched samples (index 0 oldest .. 3 newest);
    # samples_since counts 32768 Hz reads since the last FIFO update, and
    # update_interval is the read count spanning the previous update period
    # (the phase denominator).
    hist*:            array[2, array[4, int16]]
    samples_since*:   array[2, int32]
    update_interval*: array[2, float32]
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
    # Faithful m4a reverb state: a shadow of the engine's pcmBuffer frame ring
    # (s8 pcmBuffer[PCM_DMA_BUF_SIZE * 2] in pret m4a_internal.h — a ring of
    # pcmDmaPeriod one-V-blank slots per stereo half) kept at our render rate.
    # See the "MP2K reverb" block in mp2k.nim render_sample for the algorithm.
    reverb_ring*:    seq[float32]  # rev_period slots x MP2K_REV_SLOT_LEN stereo samples
    rev_slot*:       int           # current frame slot (the one being overwritten)
    rev_pos*:        int           # intra-frame sample index within the slot
    rev_period*:     int           # ring length in V-blank frames = SoundInfo.pcmDmaPeriod
                                   # (SampleFreqSet: PCM_DMA_BUF_SIZE / pcmSamplesPerVBlank)
    # DirectSound double-buffer emulation: the real m4a driver mixes a pcmBuffer
    # one frame ahead of the DMA that plays it, so its FIFO output lags the mixer
    # pass by ~one frame. We render at the mixer pass, so without this the HLE
    # leads the hardware FIFO by a frame. This ring delays our output to match.
    out_delay*:      seq[int16]     # stereo output delay line (2 * db_delay slots)
    out_delay_w*:    int            # write cursor (in stereo frames)
    db_delay*:       int            # delay length in samples (0 disables)

  Cartridge* = ref object
    rom*: seq[byte]        ## sized to the next power of two >= the ROM file
    rom_mask*: uint32      ## rom.len - 1 (rom.len is always a power of two)

  GBA* = ref object of EmuObj
    bios_path*:  string
    rom_path*:   string
    run_bios*:   bool
    use_hle*:        bool
    hle_after_bios*: bool
    scheduler*:      Scheduler
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
proc new_mp2k*(gba: GBA): Mp2kHle
proc init_mp2k*(m: Mp2kHle)
proc mixer_hook*(m: Mp2kHle)
proc probe_pc*(m: Mp2kHle; pc: uint32) {.noinline.}
proc mp2k_frame_poll*(m: Mp2kHle)
proc render_sample*(m: Mp2kHle): tuple[l: int16, r: int16]
proc trigger_hdma*(dma: DMA)
proc trigger_vdma*(dma: DMA)
proc request_immediate*(dma: DMA)
proc trigger_video_capture*(dma: DMA; vcount: uint16)
proc catch_up(bus: Bus) {.inline.}
proc serial_transfer_complete*(serial: Serial)
proc trigger_fifo*(dma: DMA; fifo_channel: int)
proc bitmap*(ppu: PPU): bool
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

include pipeline
include cartridge
include storage
include storage/sram
include storage/flash
include storage/eeprom
include rtc
include gpio
include interrupts
include keypad
include waitloop
include arm/arm
include arm/lut
include thumb/thumb
include cpu
when defined(mp2kwav):  # throwaway A/B capture buffers (see mp2k.nim)
  var mp2kWavCapture*: seq[int16] = @[]
  var realDmaCapture*: seq[int16] = @[]
  var dbgRetrigCount*: int = 0
include apu/abstract_channels
include apu/channel1
include apu/channel2
include apu/channel3
include apu/channel4
include apu/dma_channels
include apu
include timer
include serial
include dma
include bus
include mp2k

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

include ppu
include mmio

proc new_storage*(gba: GBA; rom_path: string): Storage =
  let save_path = rom_path[0 ..< rom_path.rfind('.')] & ".sav"
  let t = find_storage_type(rom_path)
  echo "Backup type: ", t, ", save path: ", save_path
  var existing_save_size: int64 = -1
  if fileExists(save_path):
    existing_save_size = getFileSize(save_path)
  result = case t
    of stEEPROM:                        new_eeprom(gba, existing_save_size)
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
    of etAPUChannel1:   gba.apu.channel1.ch1_step()
    of etAPUChannel2:   gba.apu.channel2.ch2_step()
    of etAPUChannel3:   gba.apu.channel3.ch3_step()
    of etAPUChannel4:   gba.apu.channel4.ch4_step()
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
    of etHandleInput, etIME: discard

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
  gba.ppu.frame = false
  let base = gba.scheduler.rebase(keep_phase_mask = 1023)
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
  gba.cpu.count_cycles = 0
  while not gba.ppu.frame:
    gba.cpu.tick()
  gba.end_frame()

method run_until_frame*(gba: GBA) = gba.step_frame()

proc handle_input*(gba: GBA; input: Input; pressed: bool) =
  gba.keypad.handle_input(input, pressed)

method toggle_sync*(gba: GBA) =
  gba.apu.toggle_sync()

include savestate
