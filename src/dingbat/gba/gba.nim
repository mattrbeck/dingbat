# GBA emulator main file
# All types are declared here; implementation files are `include`d.

import std/[options, times, os, strutils, math]
import ../common/[util, input, scheduler, emu, resampler]
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
    gba_ref*:       GBA
    eeprom_size*:   Option[EepromSize]
    state*:         set[EepromStateFlag]
    buffer*:        EepromBuffer
    address*:       uint32
    ignored_reads*: int
    read_bits*:     int
    wrote_bits*:    int

  Interrupts* = ref object
    gba*:    GBA
    reg_ie*: InterruptReg
    reg_if*: InterruptReg
    ime*:    bool

  Keypad* = ref object
    gba*:      GBA
    keyinput*: KEYINPUT
    keycnt*:   KEYCNT

  MMIO* = ref object
    gba*:     GBA
    waitcnt*: WAITCNT

  Timer* = ref object
    gba*:          GBA
    tmcnt*:        array[4, TMCNT]
    tmd*:          array[4, uint16]
    tm*:           array[4, uint16]
    cycle_enabled*: array[4, CycleCount]

  Serial* = ref object
    gba*:        GBA
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
    gba*:       GBA
    dmasad*:    array[4, uint32]
    dmadad*:    array[4, uint32]
    src*:       array[4, uint32]
    dst*:       array[4, uint32]
    dmacnt_l*:  array[4, uint16]
    dmacnt_h*:  array[4, DMACNT]
  RtcState* = enum
    rtcWaiting, rtcCommand, rtcReading, rtcWriting

  RtcBuffer* = object
    size*:  int
    value*: uint64

  RTC* = ref object
    gba*:    GBA
    sck*:    bool
    sio*:    bool
    cs*:     bool
    state*:  RtcState
    reg*:    int
    buffer*: RtcBuffer
    irq*:    bool
    m24*:    bool

  GPIO* = ref object
    gba*:         GBA
    data*:        uint8
    direction*:   uint8
    allow_reads*: bool
    rtc*:         RTC

  Bus* = ref object
    gba*:        GBA
    cycles*:     int
    bios*:       seq[byte]
    wram_board*: seq[byte]
    wram_chip*:  seq[byte]
    gpio*:       GPIO

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
    gba*:         GBA
    r*:           array[16, uint32]
    cpsr*:        PSR
    spsr*:        PSR
    pipeline*:    Pipeline
    reg_banks*:   array[6, array[7, uint32]]
    spsr_banks*:  array[6, uint32]
    halted*:      bool
    count_cycles*: int
    # Waitloop fields
    attempt_waitloop_detection*: bool
    cache_waitloop_results*:     bool
    branch_dest*:                uint32
    identified_waitloops*:       seq[uint32]
    identified_non_waitloops*:   seq[uint32]
    entered_waitloop*:           bool
    waitloop_instr_lut*:         seq[WLInstrKind]

  SpritePixel* = object
    priority*: uint16
    palette*:  uint16
    blends*:   bool
    window*:   bool

  GbaColor* = object
    palette*:          int
    layer*:            int
    special_handling*: bool

  Sprite* = object
    attr0*:     uint16
    attr1*:     uint16
    attr2*:     uint16
    aff_param*: int16

  PPU* = ref object
    gba*:          GBA
    framebuffer*:  seq[uint16]
    frame*:        bool
    layer_palettes*: array[4, seq[byte]]
    sprite_pixels*: array[240, SpritePixel]
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

  SoundChannel* = ref object of RootObj
    gba*:            GBA
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
    gba*:       GBA
    fifos*:     array[2, array[32, int8]]
    positions*: array[2, int]
    sizes*:     array[2, int]
    latches*:   array[2, int16]

  APU* = ref object
    gba*:               GBA
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
    audio_dev*:         uint32  # SDL2 AudioDeviceID (0 = not open)
    left_resampler*:    Resampler[float32]
    right_resampler*:   Resampler[float32]
    resample_freq*:     int
    output_freq*:       int

  Cartridge* = ref object
    rom*: seq[byte]

  GBA* = ref object of EmuObj
    bios_path*:  string
    rom_path*:   string
    run_bios*:   bool
    use_hle*:    bool
    scheduler*:  Scheduler
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
    dma*:        DMA
    serial*:     Serial
    when defined(test_harness):
      test_output*: TestOutput

# ==================== INCLUDE IMPLEMENTATIONS ====================

# Forward declarations to handle circular include dependencies
proc irq*(cpu: CPU)
proc und*(cpu: CPU)
proc schedule_interrupt_check*(intr: Interrupts)
proc read_open_bus_value*(bus: Bus; address: uint32): uint8
proc `[]`*(bus: Bus; address: uint32): uint8
proc `[]=`*(bus: Bus; address: uint32; value: uint8)
proc read_half*(bus: Bus; address: uint32): uint16
proc read_word*(bus: Bus; address: uint32): uint32
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
proc trigger_hdma*(dma: DMA)
proc trigger_vdma*(dma: DMA)
proc serial_transfer_complete*(serial: Serial)
proc trigger_fifo*(dma: DMA; fifo_channel: int)
proc bitmap*(ppu: PPU): bool
proc draw*(ppu: PPU)
proc scanline*(ppu: PPU)
proc start_line*(ppu: PPU)
proc start_hblank*(ppu: PPU)
proc end_hblank*(ppu: PPU)
proc write_half*(bus: Bus; address: uint32; value: uint16)
proc write_word*(bus: Bus; address: uint32; value: uint32)
proc fill_pipeline*(cpu: CPU) {.inline.}
proc read_half_internal*(bus: Bus; address: uint32): uint16 {.inline.}
proc check_cond*(cpu: CPU; cond: uint32): bool {.inline.}
proc step_arm*(cpu: CPU) {.inline.}
proc step_thumb*(cpu: CPU) {.inline.}
proc set_reg*(cpu: CPU; reg: int; value: uint32): uint32 {.discardable, inline.}
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

proc new_gba*(bios_path, rom_path: string; run_bios: bool; use_hle: bool = false): GBA =
  result = GBA(
    bios_path: bios_path,
    rom_path:  rom_path,
    run_bios:  run_bios,
    use_hle:   use_hle,
  )
  result.scheduler = new_scheduler()
  result.cartridge = new_cartridge(rom_path)

proc handle_saves*(gba: GBA)

proc gba_dispatch(gba: GBA): proc(kind: EventType) {.closure.} =
  result = proc(kind: EventType) =
    case kind
    of etAPUFrameSeq:   gba.apu.tick_frame_sequencer()
    of etAPUSample:     gba.apu.get_sample()
    of etAPUChannel1:   gba.apu.channel1.ch1_step()
    of etAPUChannel2:   gba.apu.channel2.ch2_step()
    of etAPUChannel3:   gba.apu.channel3.ch3_step()
    of etAPUChannel4:   gba.apu.channel4.ch4_step()
    of etPPUStartLine:  gba.ppu.start_line()
    of etPPUStartHBlank: gba.ppu.start_hblank()
    of etPPUEndHBlank:  gba.ppu.end_hblank()
    of etSaves:         gba.handle_saves()
    of etInterrupts:    gba.interrupts.check_interrupts()
    of etTimer0:        gba.timer.timer_overflow_event(0)
    of etTimer1:        gba.timer.timer_overflow_event(1)
    of etTimer2:        gba.timer.timer_overflow_event(2)
    of etTimer3:        gba.timer.timer_overflow_event(3)
    of etSerial:        gba.serial.serial_transfer_complete()
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
  gba.handle_saves()
  if not gba.run_bios:
    gba.cpu.skip_bios()

proc handle_saves*(gba: GBA) =
  gba.scheduler.schedule(280896, etSaves)
  gba.storage.write_save()

proc step_frame*(gba: GBA) =
  gba.cpu.count_cycles = 0
  while not gba.ppu.frame:
    gba.cpu.tick()
  gba.ppu.frame = false
  # Rebase scheduler and timer cycle references to prevent uint32 overflow on WASM
  let base = gba.scheduler.cycles
  gba.scheduler.rebase()
  for i in 0..3:
    if gba.timer.cycle_enabled[i] >= base:
      gba.timer.cycle_enabled[i] -= base
    else:
      gba.timer.cycle_enabled[i] = 0

method run_until_frame*(gba: GBA) = gba.step_frame()

proc handle_input*(gba: GBA; input: Input; pressed: bool) =
  gba.keypad.handle_input(input, pressed)

method toggle_sync*(gba: GBA) =
  gba.apu.toggle_sync()
