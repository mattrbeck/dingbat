# GB/GBC emulator main file
# All types are declared here; implementation files are `include`d.

import std/[bitops, os, strutils, times]
import ../common/[input, scheduler, emu, resampler, serialize, timestretch, cheats]
when defined(test_harness):
  import ../common/test_output

# ==================== TYPE DECLARATIONS ====================
# All GB types in one block for forward-reference support.

type
  # ---- Cartridge / MBC ----
  CgbFlag* = enum
    cgbNone, cgbSupport, cgbExclusive

  # Boot-state model. Selects the per-hardware-revision CPU register / DIV
  # seed table applied at the boot-ROM handoff (skip_boot). Real users only
  # ever get bmDmgABC (any DMG/SGB cart) or bmCgbABCDE (any CGB cart) — those
  # reproduce the values dingbat has always used. The other variants exist so
  # the mooneye boot_regs-*/boot_div-* acceptance ROMs (which each target one
  # specific hardware revision) can be driven by the test harness via --model.
  # Sources: mooneye-test-suite acceptance/misc boot_regs-*.s / boot_div-*.s
  # asserts, and Pan Docs "Power-Up Sequence".
  GbBootModel* = enum
    bmDmg0       # original DMG (no serial number)
    bmDmgABC     # DMG rev A/B/C  (dingbat default DMG)
    bmMgb        # Game Boy Pocket / Light
    bmSgb        # Super Game Boy
    bmSgb2       # Super Game Boy 2
    bmCgb0       # original CGB
    bmCgbABCDE   # CGB rev A..E   (dingbat default CGB)
    bmAgb        # Game Boy Advance / SP running a GB(C) cart

  Mbc* = ref object of RootObj
    gb_ref*:       GB
    rom*:          seq[uint8]
    ram*:          seq[uint8]
    sav_path*:     string
    has_battery*:  bool
    ram_dirty*:    bool
    save_error_reported*: bool

  MbcRom* = ref object of Mbc

  Mbc1* = ref object of Mbc
    ram_enabled*: bool
    mode*:        uint8
    reg1*:        uint8   # 5-bit rom bank lo
    reg2*:        uint8   # 2-bit secondary
    multicart*:   bool    # MBC1M: only 4 bits of reg1 are wired; reg2 shifts by 4

  Mbc2* = ref object of Mbc
    ram_enabled*: bool
    rom_bank*:    uint8

  Mbc3* = ref object of Mbc
    ram_enabled*:    bool
    rom_bank_num*:   uint8
    ram_bank_num*:   uint8
    # MBC3 real-time clock
    has_rtc*:            bool
    rtc_live*:           array[5, uint8]  # S, M, H, DL, DH
    rtc_latched*:        array[5, uint8]
    rtc_latch_prev*:     uint8
    rtc_halt_remaining*: int  # scheduler cycles left on the pending tick while halted

  Mbc5* = ref object of Mbc
    ram_enabled*:    bool
    rom_bank_num*:   uint16
    ram_bank_num*:   uint8

  # ---- CPU ----
  GbCpu* = ref object
    af*:         uint16
    bc*:         uint16
    de*:         uint16
    hl*:         uint16
    pc*:         uint16
    sp*:         uint16
    ime*:        bool
    halted*:     bool
    halt_bug*:   bool
    cached_hl*:  int   # -1 = invalid

  # ---- Interrupts ----
  GbInterrupts* = ref object
    vblank_interrupt*:   bool
    lcd_stat_interrupt*: bool
    timer_interrupt*:    bool
    serial_interrupt*:   bool
    joypad_interrupt*:   bool
    vblank_enabled*:     bool
    lcd_stat_enabled*:   bool
    timer_enabled*:      bool
    serial_enabled*:     bool
    joypad_enabled*:     bool
    top_3_ie_bits*:      uint8

  # ---- Serial ----
  GbSerialDriver* = ref object of RootObj
    ## Whatever is plugged into the link port (see serial.nim). The base
    ## instance is the no-cable default; a link coordinator subclasses it.

  GbSerial* = ref object
    sb*:             uint8   # 0xFF01 shift register
    sc*:             uint8   # 0xFF02 control (bits 7, 1 [CGB], 0)
    out_latch*:      uint8   # outgoing byte latched at transfer start
    bits_remaining*: int     # 8..1 while a started transfer has bits left
    clock_history*:  uint8   # per-cycle samples of the DIV clock bit; bit 0
                             # = newest (see serial.nim: the shift clock is
                             # the divider tap delayed by 4 cycles)
    shifting*:       bool    # cached: internal-clock transfer in progress
    driver*:         GbSerialDriver

  # ---- Timer ----
  GbTimer* = ref object
    tdiv*:         uint16
    tima*:         uint8
    tma*:          uint8
    enabled*:      bool
    clock_select*: uint8
    bit_for_tima*: int
    previous_bit*: bool
    countdown*:    int

  # ---- Joypad ----
  GbJoypad* = ref object
    button_keys*:    bool
    direction_keys*: bool
    down*:           bool
    up*:             bool
    left*:           bool
    right*:          bool
    start*:          bool
    jselect*:        bool
    b*:              bool
    a*:              bool

  # ---- PPU pixel types ----
  GbPixel* = object
    color*:     uint8
    palette*:   uint8
    oam_idx*:   uint8
    obj_to_bg*: uint8

  GbPixelFifo* = object
    data: array[16, GbPixel]
    head: int
    tail: int
    size: int

  GbSprite* = object
    y*:          uint8
    x*:          uint8
    tile_num*:   uint8
    attributes*: uint8
    oam_idx*:    uint8

  # ---- PPU (base + subclasses) ----
  GbPpu* = ref object of RootObj
    # registers
    lcd_control*:   uint8   # 0xFF40
    lcd_status*:    uint8   # 0xFF41
    scy*:           uint8   # 0xFF42
    scx*:           uint8   # 0xFF43
    ly*:            uint8   # 0xFF44
    lyc*:           uint8   # 0xFF45
    bgp*:           array[4, uint8]   # 0xFF47
    obp0*:          array[4, uint8]   # 0xFF48
    obp1*:          array[4, uint8]   # 0xFF49
    wy*:            uint8   # 0xFF4A
    wx*:            uint8   # 0xFF4B
    vram_bank*:     uint8
    # CGB palette RAM
    pram*:              array[64, uint8]
    palette_index*:     uint8
    auto_increment*:    bool
    obj_pram*:          array[64, uint8]
    obj_palette_index*: uint8
    obj_auto_increment*: bool
    # VRAM (2 banks)
    vram*:          array[2, seq[uint8]]
    sprite_table*:  seq[uint8]         # OAM 160 bytes
    # HDMA
    hdma1*, hdma2*, hdma3*, hdma4*, hdma5*: uint8
    hdma_src*:      uint16
    hdma_dst*:      uint16
    hdma_pos*:      uint16
    hdma_active*:   bool
    # window state
    window_trigger*:     bool
    current_window_line*: int
    old_stat_flag*:      bool
    first_line*:         bool
    cycle_counter*:      int32
    # STAT mode bits as observed by a CPU read. A read M-cycle samples the bus
    # value at the START of the cycle, but the emulator ticks the PPU forward by
    # the whole M-cycle before read_byte runs; this latch snapshots the mode at
    # each tick entry so STAT reads see the pre-advance mode (mooneye
    # intr_2_mode0/mode3_timing, which read STAT one M-cycle after the mode-2
    # interrupt and must still observe the old mode).
    read_mode*:          uint8
    # output
    framebuffer*:   seq[uint16]   # 160×144 BGR555
    frame*:         bool
    ran_bios*:      bool

  GbScanlinePpu* = ref object of GbPpu
    scanline_color_vals*: array[160, tuple[color: uint8, priority: bool]]

  FetchStage* = enum
    fsSleep, fsGetTile, fsGetTileDataLow, fsGetTileDataHigh, fsPushPixel

  GbFifoPpu* = ref object of GbPpu
    fifo*:                GbPixelFifo
    fifo_sprite*:         GbPixelFifo
    fetch_counter*:       int
    fetch_counter_sprite*: int
    fetcher_x*:           int
    lx*:                  int32
    smooth_scroll_sampled*: bool
    dropped_first_fetch*: bool
    fetching_window*:     bool
    fetching_sprite*:     bool
    sprite_fetch_phase*:  int
    bg_pixels_pushed*:    bool
    scx_penalty_remaining*: int
    tile_num*:            uint8
    tile_attrs*:          uint8
    tile_data_low*:       uint8
    tile_data_high*:      uint8
    sprites*:             seq[GbSprite]

  # ---- APU Channels (base types) ----
  GbSoundChannel* = ref object of RootObj
    enabled*:        bool
    dac_enabled*:    bool
    length_counter*: int
    length_enable*:  bool

  GbVolumeEnvChannel* = ref object of GbSoundChannel
    starting_volume*:        uint8
    envelope_add_mode*:      bool
    period*:                 uint8
    volume_envelope_timer*:  uint8
    current_volume*:         uint8
    vol_env_is_updating*:    bool

  GbChannel1* = ref object of GbVolumeEnvChannel
    wave_duty_position*: int
    sweep_period*:       uint8
    negate*:             bool
    shift*:              uint8
    sweep_timer*:        uint8
    frequency_shadow*:   uint16
    sweep_enabled*:      bool
    negate_used*:        bool
    duty*:               uint8
    length_load*:        uint8
    frequency*:          uint16

  GbChannel2* = ref object of GbVolumeEnvChannel
    wave_duty_position*: int
    duty*:               uint8
    length_load*:        uint8
    frequency*:          uint16

  GbChannel3* = ref object of GbSoundChannel
    wave_ram*:               array[16, uint8]
    wave_ram_position*:      uint8
    wave_ram_sample_buffer*: uint8
    length_load*:            uint8
    volume_code*:            uint8
    volume_code_shift*:      uint8
    frequency*:              uint16

  GbChannel4* = ref object of GbVolumeEnvChannel
    lfsr*:         uint16
    length_load*:  uint8
    clock_shift*:  uint8
    width_mode*:   uint8
    divisor_code*: uint8

  GbApu* = ref object
    sound_enabled*:       bool
    buffer*:              seq[float32]
    buffer_pos*:          int
    frame_sequencer_stage*: int
    first_half_of_length_period*: bool
    left_enable*:         bool
    left_volume*:         uint8
    right_enable*:        bool
    right_volume*:        uint8
    nr51*:                uint8
    sync*:                bool
    channel_mask*:        array[4, bool]  # pulse 1/2, wave, noise; true = enabled
    # Master volume as a precomputed factor (1.0 = unity), applied per
    # buffer at the queue point
    master_volume_factor*: float32
    master_muted*:        bool
    # 2x speed: drop every other stereo frame at the queue point so
    # audio-driven pacing runs emulation twice as fast
    turbo*:               bool
    turbo_parity:         bool  # emscripten per-sample decimation state
    # Pitch-correct fast-forward (WSOLA); presentation-only, see the GBA APU.
    pitch_correct_ff*:    bool
    stretch:              TimeStretch
    stretch_engaged:      bool
    audio_dev*:           uint32
    channel1*:            GbChannel1
    channel2*:            GbChannel2
    channel3*:            GbChannel3
    channel4*:            GbChannel4
    left_resampler*:      Resampler[float32]
    right_resampler*:     Resampler[float32]
    resample_freq*:       int
    output_freq*:         int

  # ---- Memory ----
  GbMemory* = ref object
    wram*:                 array[8, seq[uint8]]
    wram_bank*:            uint8
    hram*:                 array[0x7F, uint8]
    bootrom*:              seq[uint8]
    cycle_tick_count*:     int
    ff72*, ff73*, ff74*, ff75*: uint8
    dma*:                  uint8
    current_dma_source*:   uint16
    internal_dma_timer*:   int
    dma_position*:         int
    requested_oam_dma*:    bool
    next_dma_counter*:     uint8
    requested_speed_switch*: bool
    current_speed*:        uint8

  # ---- Main GB type ----
  GB* = ref object of EmuObj
    bootrom_path*:   string
    rom_path*:       string
    cgb_enabled*:    bool
    fifo*:           bool
    headless*:       bool
    run_bios*:       bool
    cartridge*:      Mbc
    rom_size*:       uint32
    ram_size*:       int
    cgb_flag*:       CgbFlag
    boot_model*:     GbBootModel
    rom_title*:      string
    scheduler*:      Scheduler
    cpu*:            GbCpu
    interrupts*:     GbInterrupts
    joypad*:         GbJoypad
    ppu*:            GbPpu
    timer*:          GbTimer
    serial*:         GbSerial
    memory*:         GbMemory
    apu*:            GbApu
    cheats*:         CheatEngine
    when defined(test_harness):
      test_output*:  TestOutput

# ==================== FETCHER ORDER ====================
const FETCHER_ORDER*: array[8, FetchStage] = [
  fsSleep, fsGetTile, fsSleep, fsGetTileDataLow,
  fsSleep, fsGetTileDataHigh, fsSleep, fsPushPixel,
]

# DMG default colors (BGR555)
const DMG_COLORS*: array[4, uint16] = [0x6BDF'u16, 0x3ABF'u16, 0x35BD'u16, 0x2CEF'u16]

const GB_WIDTH*  = 160
const GB_HEIGHT* = 144
const GB_CLOCK_SPEED* = 4194304

# Queue-push block, in float32s (128 stereo frames = 3.9 ms); small so
# audio-sync pacing sees a fine-grained queue level (see gba/apu.nim)
const GB_APU_BUFFER_SIZE* = 256
# Audio-sync pacing levels in bytes of queued f32 stereo (8 bytes/frame);
# fixed rather than derived from the push block: 4096 B = 512 frames ≈ 15.6 ms.
# The backstop is runaway protection only — far above the normal operating
# range so it never blocks emulation mid-frame (see gba/apu.nim)
const GB_SYNC_AHEAD_BYTES*    = 4096'u32
const GB_SYNC_BACKSTOP_BYTES* = 32768'u32
const GB_SAMPLE_RATE*     = 32768
const GB_SAMPLE_PERIOD*   = GB_CLOCK_SPEED div GB_SAMPLE_RATE
const GB_FRAME_SEQ_RATE*  = 512
const GB_FRAME_SEQ_PERIOD* = GB_CLOCK_SPEED div GB_FRAME_SEQ_RATE

# POST_BOOT_VRAM — the initial VRAM state after the boot ROM finishes
const POST_BOOT_VRAM*: array[384, uint8] = [
  0x00'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0xF0, 0x00, 0xF0, 0x00, 0xFC, 0x00, 0xFC, 0x00, 0xFC, 0x00, 0xFC, 0x00, 0xF3, 0x00, 0xF3, 0x00,
  0x3C, 0x00, 0x3C, 0x00, 0x3C, 0x00, 0x3C, 0x00, 0x3C, 0x00, 0x3C, 0x00, 0x3C, 0x00, 0x3C, 0x00,
  0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF3, 0x00, 0xF3, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xCF, 0x00, 0xCF, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x0F, 0x00, 0x3F, 0x00, 0x3F, 0x00, 0x0F, 0x00, 0x0F, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0xC0, 0x00, 0x0F, 0x00, 0x0F, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x00, 0xF0, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF3, 0x00, 0xF3, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0xC0, 0x00,
  0x03, 0x00, 0x03, 0x00, 0x03, 0x00, 0x03, 0x00, 0x03, 0x00, 0x03, 0x00, 0xFF, 0x00, 0xFF, 0x00,
  0xC0, 0x00, 0xC0, 0x00, 0xC0, 0x00, 0xC0, 0x00, 0xC0, 0x00, 0xC0, 0x00, 0xC3, 0x00, 0xC3, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x00, 0xFC, 0x00,
  0xF3, 0x00, 0xF3, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00,
  0x3C, 0x00, 0x3C, 0x00, 0xFC, 0x00, 0xFC, 0x00, 0xFC, 0x00, 0xFC, 0x00, 0x3C, 0x00, 0x3C, 0x00,
  0xF3, 0x00, 0xF3, 0x00, 0xF3, 0x00, 0xF3, 0x00, 0xF3, 0x00, 0xF3, 0x00, 0xF3, 0x00, 0xF3, 0x00,
  0xF3, 0x00, 0xF3, 0x00, 0xC3, 0x00, 0xC3, 0x00, 0xC3, 0x00, 0xC3, 0x00, 0xC3, 0x00, 0xC3, 0x00,
  0xCF, 0x00, 0xCF, 0x00, 0xCF, 0x00, 0xCF, 0x00, 0xCF, 0x00, 0xCF, 0x00, 0xCF, 0x00, 0xCF, 0x00,
  0x3C, 0x00, 0x3C, 0x00, 0x3F, 0x00, 0x3F, 0x00, 0x3C, 0x00, 0x3C, 0x00, 0x0F, 0x00, 0x0F, 0x00,
  0x3C, 0x00, 0x3C, 0x00, 0xFC, 0x00, 0xFC, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x00, 0xFC, 0x00,
  0xFC, 0x00, 0xFC, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00, 0xF0, 0x00,
  0xF3, 0x00, 0xF3, 0x00, 0xF3, 0x00, 0xF3, 0x00, 0xF3, 0x00, 0xF3, 0x00, 0xF0, 0x00, 0xF0, 0x00,
  0xC3, 0x00, 0xC3, 0x00, 0xC3, 0x00, 0xC3, 0x00, 0xC3, 0x00, 0xC3, 0x00, 0xFF, 0x00, 0xFF, 0x00,
  0xCF, 0x00, 0xCF, 0x00, 0xCF, 0x00, 0xCF, 0x00, 0xCF, 0x00, 0xCF, 0x00, 0xC3, 0x00, 0xC3, 0x00,
]

# ==================== PIXEL FIFO HELPERS ====================

proc fifo_push*(f: var GbPixelFifo; p: GbPixel) {.inline.} =
  f.data[f.tail] = p
  f.tail = (f.tail + 1) and 15
  inc f.size

proc fifo_shift*(f: var GbPixelFifo): GbPixel {.inline.} =
  result = f.data[f.head]
  f.head = (f.head + 1) and 15
  dec f.size

proc fifo_clear*(f: var GbPixelFifo) {.inline.} =
  f.head = 0; f.tail = 0; f.size = 0

proc fifo_get*(f: var GbPixelFifo; idx: int): GbPixel {.inline.} =
  f.data[(f.head + idx) and 15]

proc fifo_set*(f: var GbPixelFifo; idx: int; p: GbPixel) {.inline.} =
  f.data[(f.head + idx) and 15] = p

# ==================== CPU REGISTER ACCESSORS ====================

proc a*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.af shr 8)
proc `a=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.af = (cpu.af and 0x00FF'u16) or (uint16(v) shl 8)
proc f*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.af and 0xF0)
proc `f=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.af = (cpu.af and 0xFF00'u16) or uint16(v and 0xF0)
proc b*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.bc shr 8)
proc `b=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.bc = (cpu.bc and 0x00FF'u16) or (uint16(v) shl 8)
proc c*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.bc and 0xFF)
proc `c=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.bc = (cpu.bc and 0xFF00'u16) or uint16(v)
proc d*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.de shr 8)
proc `d=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.de = (cpu.de and 0x00FF'u16) or (uint16(v) shl 8)
proc e*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.de and 0xFF)
proc `e=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.de = (cpu.de and 0xFF00'u16) or uint16(v)
proc h*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.hl shr 8)
proc `h=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.hl = (cpu.hl and 0x00FF'u16) or (uint16(v) shl 8)
proc l*(cpu: GbCpu): uint8 {.inline.} = uint8(cpu.hl and 0xFF)
proc `l=`*(cpu: GbCpu; v: uint8) {.inline.} =
  cpu.hl = (cpu.hl and 0xFF00'u16) or uint16(v)

# Flags: Z=bit7, N=bit6, H=bit5, C=bit4
proc fz*(cpu: GbCpu): bool {.inline.} = (cpu.af and 0x0080'u16) != 0
proc `fz=`*(cpu: GbCpu; v: bool) {.inline.} =
  if v: cpu.af = cpu.af or 0x0080'u16
  else: cpu.af = cpu.af and not 0x0080'u16
proc fn*(cpu: GbCpu): bool {.inline.} = (cpu.af and 0x0040'u16) != 0
proc `fn=`*(cpu: GbCpu; v: bool) {.inline.} =
  if v: cpu.af = cpu.af or 0x0040'u16
  else: cpu.af = cpu.af and not 0x0040'u16
proc fh*(cpu: GbCpu): bool {.inline.} = (cpu.af and 0x0020'u16) != 0
proc `fh=`*(cpu: GbCpu; v: bool) {.inline.} =
  if v: cpu.af = cpu.af or 0x0020'u16
  else: cpu.af = cpu.af and not 0x0020'u16
proc fc*(cpu: GbCpu): bool {.inline.} = (cpu.af and 0x0010'u16) != 0
proc `fc=`*(cpu: GbCpu; v: bool) {.inline.} =
  if v: cpu.af = cpu.af or 0x0010'u16
  else: cpu.af = cpu.af and not 0x0010'u16

# ==================== MBC HELPERS (shared) ====================

proc mbc_rom_bank_offset*(cart: Mbc; bank_num: int): int =
  (bank_num * 0x4000) mod int(cart.rom.len)

proc mbc_rom_offset*(idx: int): int = idx - 0x4000

proc mbc_ram_bank_offset*(cart: Mbc; bank_num: int): int =
  if cart.ram.len == 0: return 0
  (bank_num * 0x2000) mod cart.ram.len

proc mbc_ram_offset*(idx: int): int = idx - 0xA000

const RTC_SECOND_CYCLES* = 4194304  # one RTC tick per emulated second

# Deterministic-RTC override for lockstep/rollback netplay. With two peers the
# MBC3 clock must NOT read the local wall clock (it would differ between peers)
# and must NOT free-run (the tick count differs between a straight run and its
# rollback re-simulation — a determinism gap that diverges Crystal's DIV/RTC-
# seeded RNG). When set >= 0 it is the shared "now" (unix seconds) both peers
# pass at connect: the load-time catch-up uses it, and the clock is then FROZEN
# (no ticks). Mirrors the GBA core's enable_deterministic_rtc. -1 = real clock,
# free-running (single-player default).
var gbRtcNowOverride*: int64 = -1

proc enable_deterministic_gb_rtc*(epoch: int64) =
  ## Freeze the MBC3 RTC to a shared epoch. Both peers must pass the SAME
  ## value. Call before loading the cartridge/state.
  gbRtcNowOverride = epoch

proc gb_rtc_now(): int64 {.inline.} =
  if gbRtcNowOverride >= 0: gbRtcNowOverride else: getTime().toUnix()

proc gb_rtc_frozen(): bool {.inline.} = gbRtcNowOverride >= 0

proc rtc_halted*(cart: Mbc3): bool =
  (cart.rtc_live[4] and 0x40) != 0

proc rtc_schedule_full*(cart: Mbc3) =
  if gb_rtc_frozen(): return  # deterministic mode: clock frozen, never ticks
  cart.gb_ref.scheduler.clear(etRtcSecond)
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)

proc rtc_remaining*(cart: Mbc3): int =
  ## Scheduler cycles until the pending RTC tick
  let s = cart.gb_ref.scheduler
  for ev in s.events:
    if ev.kind == etRtcSecond:
      return int(ev.cycles - s.cycles)
  RTC_SECOND_CYCLES

proc rtc_increment(cart: Mbc3) =
  # Hardware counters roll over at their natural boundaries with carry, but
  # out-of-range values (writable because registers are wider than needed)
  # count up to the register limit and wrap without carrying
  let s = cart.rtc_live[0] and 0x3F
  if s != 59:
    cart.rtc_live[0] = if s == 63: 0'u8 else: s + 1
    return
  cart.rtc_live[0] = 0
  let m = cart.rtc_live[1] and 0x3F
  if m != 59:
    cart.rtc_live[1] = if m == 63: 0'u8 else: m + 1
    return
  cart.rtc_live[1] = 0
  let h = cart.rtc_live[2] and 0x1F
  if h != 23:
    cart.rtc_live[2] = if h == 31: 0'u8 else: h + 1
    return
  cart.rtc_live[2] = 0
  let day = (uint16(cart.rtc_live[4] and 1) shl 8) or uint16(cart.rtc_live[3])
  let new_day = (day + 1) and 0x1FF
  cart.rtc_live[3] = uint8(new_day and 0xFF)
  cart.rtc_live[4] = (cart.rtc_live[4] and 0xC0) or uint8(new_day shr 8)
  if day == 511:  # day counter overflow: sticky carry flag
    cart.rtc_live[4] = cart.rtc_live[4] or 0x80

proc rtc_tick*(cart: Mbc3) =
  if gb_rtc_frozen(): return  # deterministic mode: clock frozen
  cart.gb_ref.scheduler.schedule_gb(RTC_SECOND_CYCLES, etRtcSecond)
  cart.rtc_increment()

proc rtc_catch_up(cart: Mbc3; elapsed: int64) =
  ## Advance the clock by wall time that passed while the emulator was off
  if cart.rtc_halted() or elapsed <= 0: return
  let secs  = int64(cart.rtc_live[0] and 0x3F) + elapsed
  cart.rtc_live[0] = uint8(secs mod 60)
  let mins  = int64(cart.rtc_live[1] and 0x3F) + secs div 60
  cart.rtc_live[1] = uint8(mins mod 60)
  let hours = int64(cart.rtc_live[2] and 0x1F) + mins div 60
  cart.rtc_live[2] = uint8(hours mod 24)
  let days  = (int64(cart.rtc_live[4] and 1) shl 8) + int64(cart.rtc_live[3]) + hours div 24
  cart.rtc_live[3] = uint8(days and 0xFF)
  cart.rtc_live[4] = (cart.rtc_live[4] and 0xC0) or uint8((days shr 8) and 1)
  if days > 511:
    cart.rtc_live[4] = cart.rtc_live[4] or 0x80

proc rtc_footer(cart: Mbc3): string =
  ## BGB/VBA-compatible .sav footer: live regs, latched regs, unix timestamp
  proc add_u32(s: var string; v: uint32) =
    for i in 0 .. 3: s.add(char((v shr (8 * i)) and 0xFF))
  result = ""
  for i in 0 .. 4: result.add_u32(uint32(cart.rtc_live[i]))
  for i in 0 .. 4: result.add_u32(uint32(cart.rtc_latched[i]))
  let ts = uint64(gb_rtc_now())
  for i in 0 .. 7: result.add(char((ts shr (8 * i)) and 0xFF))

proc rtc_load_footer(cart: Mbc3; data: string) =
  proc get_u32(data: string; off: int): uint32 =
    for i in 0 .. 3: result = result or (uint32(data[off + i]) shl (8 * i))
  let base = cart.ram.len
  let extra = data.len - base
  if extra < 44: return  # no footer
  for i in 0 .. 4: cart.rtc_live[i]    = uint8(get_u32(data, base + i * 4) and 0xFF)
  for i in 0 .. 4: cart.rtc_latched[i] = uint8(get_u32(data, base + 20 + i * 4) and 0xFF)
  var ts: int64 = int64(get_u32(data, base + 40))
  if extra >= 48:
    ts = ts or (int64(get_u32(data, base + 44)) shl 32)
  cart.rtc_catch_up(gb_rtc_now() - ts)

proc mbc_save*(cart: Mbc) =
  if cart.ram_dirty and cart.has_battery and cart.sav_path.len > 0 and cart.ram.len > 0:
    try:
      var data = cast[string](cart.ram)
      if cart of Mbc3 and Mbc3(cart).has_rtc:
        data.add(rtc_footer(Mbc3(cart)))
      writeFile(cart.sav_path, data)
      cart.ram_dirty = false
    except IOError, OSError:
      if not cart.save_error_reported:
        cart.save_error_reported = true
        echo "Failed to write save file: ", cart.sav_path

proc mbc_load*(cart: Mbc) =
  if cart.has_battery and cart.sav_path.len > 0 and fileExists(cart.sav_path):
    let data = readFile(cart.sav_path)
    for i in 0 ..< min(data.len, cart.ram.len):
      cart.ram[i] = uint8(data[i])
    if cart of Mbc3 and Mbc3(cart).has_rtc:
      rtc_load_footer(Mbc3(cart), data)

# ==================== INCLUDES ====================
include mbc/mbc
include mbc/rom
include mbc/mbc1
include mbc/mbc2
include mbc/mbc3
include mbc/mbc5
include apu/abstract_channels
include apu/channel1
include apu/channel2
include apu/channel3
include apu/channel4
include apu
# Forward declaration needed by serial.nim/ppu.nim (defined in memory.nim)
proc cgb_native*(gb: GB): bool
include interrupts
include serial
include timer
include joypad
# Forward declarations needed by ppu.nim (defined in memory.nim included later)
proc mem_tick_components*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true; ignore_speed = false)
proc mem_dma_tick*(mem: GbMemory; gb: GB; cycles: int)
proc read_byte*(mem: GbMemory; gb: GB; idx: int): uint8
proc write_byte*(mem: GbMemory; gb: GB; idx: int; val: uint8)
include ppu
include scanline_ppu
include fifo_ppu
include memory
# Forward declarations needed by opcodes.nim (defined in cpu.nim included later)
proc cpu_memory_at_hl*(cpu: GbCpu; gb: GB): uint8
proc `cpu_memory_at_hl=`*(cpu: GbCpu; gb: GB; val: uint8)
proc cpu_inc_pc*(cpu: GbCpu)
proc cpu_halt*(cpu: GbCpu; gb: GB)
include cb_opcodes
include opcodes
include cpu

# ==================== NEW_GB + POST_INIT ====================

proc new_gb*(bootrom_path: string; rom_path: string; fifo: bool; headless: bool; run_bios: bool; force_cgb = false): GB =
  ## force_cgb runs a DMG-flagged cart in CGB mode (a DMG cart inserted in a
  ## Game Boy Color) — mooneye's misc/ tests assert that hardware's behavior.
  result = GB(
    bootrom_path: bootrom_path,
    rom_path:     rom_path,
    fifo:         fifo,
    headless:     headless,
    run_bios:     run_bios,
  )
  result.cartridge = load_cartridge(rom_path)
  result.cheats = new_cheat_engine(cpGB)
  let cgb_byte = result.cartridge.rom[0x0143]
  result.cgb_flag = case cgb_byte
    of 0x80'u8: cgbSupport
    of 0xC0'u8: cgbExclusive
    else:       cgbNone
  result.cgb_enabled = (bootrom_path.len > 0 and run_bios) or
                       result.cgb_flag != cgbNone or force_cgb
  # Default boot model reproduces dingbat's long-standing DMG/CGB boot values.
  # The test harness may override this (via --model) before post_init to drive
  # the model-specific mooneye boot_regs/boot_div acceptance ROMs.
  result.boot_model = if result.cgb_enabled: bmCgbABCDE else: bmDmgABC
  result.rom_title = block:
    var s = ""
    for i in 0x0134 ..< 0x013F:
      let ch = result.cartridge.rom[i]
      if ch >= 0x20'u8 and ch <= 0x7E'u8: s.add(char(ch))
    s.strip()
  result.rom_size = 0x8000'u32 shl result.cartridge.rom[0x0148]
  result.ram_size = case result.cartridge.rom[0x0149]
    of 0x01: 0x0800
    of 0x02: 0x2000
    of 0x03: 0x2000 * 4
    of 0x04: 0x2000 * 16
    of 0x05: 0x2000 * 8
    else:    0

proc gb_skip_boot(gb: GB) =
  # IF reads 0xE1 at PC=0x100 on DMG and CGB (gambatte
  # display_startstate/irq): the boot ROM leaves a VBlank interrupt pending
  gb.interrupts.vblank_interrupt = true
  gb.cpu.skip_boot(gb)
  gb.memory.skip_boot(gb)
  gb.ppu.skip_boot(gb)
  gb.timer.skip_boot(gb)

proc handle_saves*(gb: GB) =
  ## Flush battery-backed cart RAM once per frame (when dirty) so progress
  ## isn't lost if the emulator exits without the game disabling cart RAM
  gb.scheduler.schedule_gb(70224, etSaves)
  gb.cartridge.mbc_save()

proc gb_dispatch(gb: GB): proc(kind: EventType) {.closure.} =
  result = proc(kind: EventType) =
    case kind
    of etAPUFrameSeq:  tick_frame_sequencer(gb.apu, gb)
    of etAPUSample:    get_sample(gb.apu, gb)
    of etAPUChannel1:  ch1_step(gb.apu.channel1, gb)
    of etAPUChannel2:  ch2_step(gb.apu.channel2, gb)
    of etAPUChannel3:  ch3_step(gb.apu.channel3, gb)
    of etAPUChannel4:  ch4_step(gb.apu.channel4, gb)
    of etIME:          gb.cpu.ime = true
    of etSaves:        gb.handle_saves()
    of etRtcSecond:
      if gb.cartridge of Mbc3: Mbc3(gb.cartridge).rtc_tick()
    else: discard

proc post_init*(gb: GB) =
  gb.scheduler  = new_scheduler()
  gb.interrupts = new_gb_interrupts()
  gb.apu        = new_gb_apu(gb, gb.headless)
  gb.joypad     = new_gb_joypad()
  if gb.fifo:
    gb.ppu = new_gb_fifo_ppu(gb)
  else:
    gb.ppu = new_gb_scanline_ppu(gb)
  gb.timer  = new_gb_timer()
  gb.serial = new_gb_serial()
  gb.memory = new_gb_memory(gb)
  gb.cpu    = new_gb_cpu()
  gb.scheduler.dispatch = gb_dispatch(gb)
  gb.cartridge.gb_ref = gb
  if gb.cartridge of Mbc3:
    let c = Mbc3(gb.cartridge)
    if c.has_rtc and not c.rtc_halted():
      c.rtc_schedule_full()
  gb.handle_saves()
  if gb.bootrom_path.len == 0 or not gb.run_bios:
    gb_skip_boot(gb)

proc apply_cheats*(gb: GB) =
  ## Push every enabled RAM-write cheat into memory. Run once per frame.
  if gb.cheats == nil or gb.cheats.cheats.len == 0: return
  let mem = gb.memory
  gb.cheats.apply_ram(MemHooks(
    read8: proc(a: uint32): uint8 =
      read_byte(mem, gb, int(a and 0xFFFF)),
    read16: proc(a: uint32): uint16 =
      uint16(read_byte(mem, gb, int(a and 0xFFFF))) or
      (uint16(read_byte(mem, gb, int((a + 1) and 0xFFFF))) shl 8),
    read32: proc(a: uint32): uint32 =
      var v = 0'u32
      for i in 0u32 ..< 4u32:
        v = v or (uint32(read_byte(mem, gb, int((a + i) and 0xFFFF))) shl (i * 8))
      v,
    write8: proc(a: uint32; v: uint8) =
      write_byte(mem, gb, int(a and 0xFFFF), v),
    write16: proc(a: uint32; v: uint16) =
      write_byte(mem, gb, int(a and 0xFFFF), uint8(v))
      write_byte(mem, gb, int((a + 1) and 0xFFFF), uint8(v shr 8)),
    write32: proc(a: uint32; v: uint32) =
      for i in 0u32 ..< 4u32:
        write_byte(mem, gb, int((a + i) and 0xFFFF), uint8(v shr (i * 8))),
  ))

proc refresh_cheat_rom_patches*(gb: GB) =
  ## Apply (or re-apply) Game Genie ROM edits. Call at load and whenever the
  ## cheat set changes.
  if gb.cheats != nil:
    gb.cheats.apply_rom(gb.cartridge.rom)

proc step_frame*(gb: GB) =
  gb.apply_cheats()
  while not gb.ppu.frame:
    gb.cpu.tick(gb)
  gb.ppu.frame = false
  gb.scheduler.rebase()

method run_until_frame*(gb: GB) = gb.step_frame()

method handle_input*(gb: GB; inp: Input; pressed: bool) {.base.} =
  gb.joypad.handle_input(inp, pressed)

method toggle_sync*(gb: GB) =
  gb.apu.toggle_sync()

include savestate
