# GB Memory bus (included by gb.nim)

# -d:gb_dma_trace: diagnostic, off by default (REGREAD and MODE sit on hot
# paths). Logs DMASTART, REGREAD (STAT/LY), MODE, FF55, HDMABLOCK, VRAMRD.

const SVBK_READS_WRITTEN* {.booldefine.} = true
  ## true: $FF70 reads back the three bits last stored ($F8 after a stored 0
  ## and at hand-off). false: the bank mapped at $D000 ($F9 for both).
  ## true matches the AGS read of gbedge p00 (docs/dev/flashcart-runbook.md) and
  ## DocBoy cgb/boot/boot_regs_cgb. docs/dev/gb-derivations.md, "SVBK readback".

proc new_gb_memory*(gb: GB): GbMemory =
  # DMA (FF46) reads back the last written value; post-boot it's 0xFF on
  # DMG-family models, 0x00 on CGB (Pan Docs power-up sequence).
  result = GbMemory(wram_bank: 1, dma_position: 0xA1,
                    dma: if gb.cgb_enabled: 0x00'u8 else: 0xFF'u8)
  for i in 0 ..< 8:
    result.wram[i] = newSeq[uint8](0x1000)
  when GB_POWERUP_WRAM_PATTERN != 0:
    # Non-zero power-up WRAM (BullyGB InitRAMTest). Fixed xorshift, not a
    # seeded RNG: screenshot, save-state and rollback gates need identical bytes.
    var s: uint32 = 0x1234_5678'u32
    for b in 0 ..< 8:
      for j in 0 ..< 0x1000:
        s = s xor (s shl 13)
        s = s xor (s shr 17)
        s = s xor (s shl 5)
        result.wram[b][j] = uint8(s and 0xFF'u32)
  result.bootrom = @[]
  if gb.bootrom_path.len > 0 and gb.run_bios and fileExists(gb.bootrom_path):
    let raw = readFile(gb.bootrom_path)
    result.bootrom = newSeq[uint8](raw.len)
    for i in 0 ..< raw.len: result.bootrom[i] = uint8(raw[i])

proc mem_flush_deferred*(mem: GbMemory; gb: GB) =
  ## Apply the part of a CPU write that belongs on the M-cycle boundary
  ## (GbMemory.write_deferred). mem_write commits the byte at the top of its
  ## M-cycle, in phase with the mode-3 pipeline; the STAT line and FF55 effects
  ## stay on the boundary (ppu_write_machinery classifies; gambatte
  ## m2enable/*_late_*). IF is NOT deferred: the CPU's IF store lands ahead of
  ## flags the PPU raises in the same M-cycle (gambatte miscmstatirq).
  mem.write_deferred = false
  when CGB_WRITE_LATENCY_ANY:
    # A pipeline store no M-cycle ran the dots for (post-boot write, cheat poke).
    if mem.pipe_reg != 0:
      let preg = int(mem.pipe_reg)
      let pval = mem.pipe_val
      mem.pipe_reg = 0
      ppu_apply_pipeline_write(gb.ppu, gb, preg, pval)
  if mem.deferred_reg != 0:
    let reg = int(mem.deferred_reg)
    let v   = mem.deferred_val
    mem.deferred_reg = 0
    when CGB_LYC153_SRC_HOLD:
      # A CGB STAT write's enables still see the 153 match held through the
      # snapback (CGB_LYC153_SRC_HOLD, gb.nim).
      if reg == 0xFF41 and gb.cgb_enabled:
        gb.stat_hold = STAT_LYC153_HELD
        ppu_write_machinery(gb.ppu, gb, reg, v)
        ppu_flush_stat_write(gb.ppu, gb)
        gb.stat_hold = 0
        return
    ppu_write_machinery(gb.ppu, gb, reg, v)
  ppu_flush_stat_write(gb.ppu, gb)

const BOOT_FS_STAGE_DMG* {.intdefine.} = 1
const BOOT_FS_STAGE_CGB* {.intdefine.} = 0
  ## The frame sequencer's next step (0-7) at the boot hand-off, per boot ROM
  ## (the boot ROM powered the APU on at its start). Pinned by gambatte
  ## sound/ch2_init_env_counter_timing_*; every other stage fails some.
  ## DINGBAT_BOOT_FS_STAGE overrides it in the test build.

const BOOT_CH1_PHASE_DMG_T* {.intdefine.} = 728
const BOOT_CH1_PHASE_CGB_T* {.intdefine.} = 1612
  ## T-cycles into channel 1's 2016-cycle duty cycle (frequency $7C1, duty 2)
  ## at the boot hand-off, per boot ROM: the beep's second note is still
  ## stepping (NR52 reads $F1). Pinned by gambatte sound/ch1_init_pos_*: only
  ## these values pass all of them. DINGBAT_BOOT_CH1_PHASE overrides it in the
  ## test build.
const BOOT_CH1_PHASE_CGB_COMPAT_T* {.intdefine.} = 1600
  ## The same for the CGB boot ROM over a DMG cart, which no test covers:
  ## measured by running the boot ROM, 12 T earlier than over a CGB cart on
  ## every header path skip-boot models (cgb_boot_header_t).

const BOOT_STACK_RESIDUE_CGB = [0x71'u8, 0x02, 0x4D, 0x01, 0xC1, 0xFF, 0x0D,
                                0x00, 0xD3, 0x05, 0xF9]
const BOOT_STACK_RESIDUE_CGB_COMPAT = [0x71'u8, 0x02, 0x4D, 0x01, 0x00, 0xFF,
                                       0x0D, 0x00, 0xF5, 0x05, 0xF9]
const BOOT_STACK_RESIDUE_DMG = [0x39'u8, 0x01, 0x2E]

proc skip_boot_hram(mem: GbMemory; gb: GB) =
  ## What the boot ROM leaves in HRAM, otherwise random at power-up (Pan
  ## Docs, "Power Up Sequence"; dingbat: zero). Measured by running each boot
  ## ROM; DocBoy `boot_hram` reads the same. Its fixed $FFFE byte is not
  ## written by any boot ROM, so it stays zero.
  ## * CGB: the logo check buffer, the cart's header $0104-$0133 at
  ##   $FF80-$FFAF (the cart's own bytes, checked half or not).
  ## * Stack residue: CGB $FFF2-$FFFC (DMG cart differs in two bytes), DMG ABC
  ##   $FFFA-$FFFC.
  case gb.boot_model
  of bmCgbABCDE:
    for i in 0 ..< 0x30:
      if 0x104 + i < gb.cartridge.rom.len:
        mem.hram[i] = gb.cartridge.rom[0x104 + i]
    let residue = if gb.cgb_flag != cgbNone: BOOT_STACK_RESIDUE_CGB
                  else: BOOT_STACK_RESIDUE_CGB_COMPAT
    for i, b in residue: mem.hram[0xFFF2 - 0xFF80 + i] = b
  of bmDmgABC:
    for i, b in BOOT_STACK_RESIDUE_DMG: mem.hram[0xFFFA - 0xFF80 + i] = b
  else: discard

proc skip_boot*(mem: GbMemory; gb: GB) =
  mem.bootrom = @[]
  # Post-boot register state (mooneye boot_hwio-*). NR52 first: sound writes
  # are dropped while the APU is off. NR14 triggers channel 1 like the boot
  # beep (NR52 = 0xF1), decayed by the hand-off.
  mem.write_byte(gb, 0xFF26, 0xF1)
  mem.write_byte(gb, 0xFF10, 0x80)
  mem.write_byte(gb, 0xFF11, 0xBF)
  mem.write_byte(gb, 0xFF12, 0xF3)
  # The beep's second note: NR13 = $C1, NR14 = $87 (both boot ROMs), so
  # frequency $7C1, one duty step every 252 T. NR13 is write-only; only
  # gambatte sound/ch1_init_pos_* see it (they retrigger without writing it).
  mem.write_byte(gb, 0xFF13, 0xC1)
  mem.write_byte(gb, 0xFF14, 0xBF)
  block:
    # Duty position at the hand-off from BOOT_CH1_PHASE_*_T.
    var phase = (if gb.boot_model == bmCgbABCDE and gb.cgb_flag == cgbNone:
                   BOOT_CH1_PHASE_CGB_COMPAT_T
                 elif gb.boot_model in {bmCgb0, bmCgbABCDE, bmAgb}:
                   BOOT_CH1_PHASE_CGB_T else: BOOT_CH1_PHASE_DMG_T)
    when defined(test_harness):
      let env = getEnv("DINGBAT_BOOT_CH1_PHASE")
      if env.len > 0: phase = parseInt(env)
    let ch = gb.apu.channel1
    const step = 252
    phase = phase mod (8 * step)
    ch.wave_duty_position = phase div step
    ch.sample_bit = PSG_DUTY[ch.duty][ch.wave_duty_position]
    ch.next_step = gb.scheduler.cycles + CycleCount(step - phase mod step)
    # post_init aims the sequencer's next edge from the divider phase
    # timer.skip_boot seeds.
    var stage = (if gb.boot_model in {bmCgb0, bmCgbABCDE, bmAgb}:
                   BOOT_FS_STAGE_CGB else: BOOT_FS_STAGE_DMG)
    when defined(test_harness):
      let env_stage = getEnv("DINGBAT_BOOT_FS_STAGE")
      if env_stage.len > 0: stage = parseInt(env_stage)
    gb.apu.frame_sequencer_stage = stage and 7
    # The matching length gate: the next step skips the length counter when
    # the next stage is odd (Pan Docs, "Obscure Behavior": an NRx4 length
    # enable then clocks it once). Re-derived here: the NR52 write above used
    # a divider not yet seeded. DocBoy dmg/apu ch1_length_timer_delay*.
    gb.apu.first_half_of_length_period = (gb.apu.frame_sequencer_stage and 1) == 1
  mem.write_byte(gb, 0xFF16, 0x3F)
  mem.write_byte(gb, 0xFF17, 0x00)
  mem.write_byte(gb, 0xFF19, 0xBF)
  mem.write_byte(gb, 0xFF1A, 0x7F)
  mem.write_byte(gb, 0xFF1B, 0xFF)
  mem.write_byte(gb, 0xFF1C, 0x9F)
  mem.write_byte(gb, 0xFF1E, 0xBF)
  mem.write_byte(gb, 0xFF20, 0xFF)
  mem.write_byte(gb, 0xFF21, 0x00)
  mem.write_byte(gb, 0xFF22, 0x00)
  mem.write_byte(gb, 0xFF23, 0xBF)
  mem.write_byte(gb, 0xFF24, 0x77)
  mem.write_byte(gb, 0xFF25, 0xF3)
  # SGB/SGB2 hand off with channel 1 off (boot_hwio-S: NR52 = 0xF0).
  gb.apu.channel1.current_volume = 0
  gb.apu.channel1.vol_env_is_updating = false
  if gb.boot_model in {bmSgb, bmSgb2}:
    gb.apu.channel1.enabled = false
  mem.write_byte(gb, 0xFF40, 0x91)
  mem.write_byte(gb, 0xFF42, 0x00)
  mem.write_byte(gb, 0xFF43, 0x00)
  mem.write_byte(gb, 0xFF45, 0x00)
  mem.write_byte(gb, 0xFF47, 0xFC)
  # OBP0/OBP1/DMA: no boot ROM writes them, so they split on the silicon,
  # not the cart's CGB flag: $FF DMG/MGB/SGB, $00 CGB/AGB (Pan Docs for DMA;
  # mooneye-wilbertpol misc/boot_hwio-C for all three).
  let cgb_silicon = gb.boot_model in {bmCgb0, bmCgbABCDE, bmAgb}
  let obp_boot = if cgb_silicon: 0x00'u8 else: 0xFF'u8
  mem.write_byte(gb, 0xFF48, obp_boot)
  mem.write_byte(gb, 0xFF49, obp_boot)
  mem.dma = obp_boot
  mem.write_byte(gb, 0xFF4A, 0x00)
  mem.write_byte(gb, 0xFF4B, 0x00)
  if gb.cgb_enabled:
    # Palette-index ports where the boot ROM's palette writes stopped,
    # auto-increment on. DMG cart: mooneye misc/boot_hwio-C. CGB cart: DocBoy
    # cgb/boot/boot_regs_cgb and a boot ROM run.
    let native_cart = gb.cgb_flag != cgbNone
    mem.write_byte(gb, 0xFF68, if native_cart: 0xC0 else: 0xC8)
    mem.write_byte(gb, 0xFF6A, if native_cart: 0xC1 else: 0xD0)
    # SVBK: the boot ROM never stores to it, so it hands off holding 0 with
    # bank 1 mapped (reads $F8, SVBK_READS_WRITTEN).
  # P1 at hand-off. The select lines power up low (new_gb_joypad: $CF); boot
  # ROMs that never write P1 hand that off: DMG-family, and CGB/AGB over a CGB
  # cart (Pan Docs: $C7 or $CF; the AGS read $CF under gbedge p00). So a cart
  # that leaves P1 alone wakes STOP on a key press (Pan Docs: STOP ends on a
  # P10-P13 line going low, only possible in a selected group).
  # Both groups deselected ($FF): SGB (packets ride on P1), and CGB/AGB over a
  # DMG cart (its palette key poll ends deselected; mooneye misc/boot_hwio-C,
  # boot_hwio-S).
  if gb.boot_model in {bmSgb, bmSgb2} or (cgb_silicon and gb.cgb_flag == cgbNone):
    gb.joypad.button_keys = false
    gb.joypad.direction_keys = false
  mem.write_byte(gb, 0xFFFF, 0x00)
  skip_boot_hram(mem, gb)
  # None of the writes above is a CPU M-cycle, so nothing else consumes this.
  mem_flush_deferred(mem, gb)

# mem_read/mem_write and the tick halves sit on clang's inline threshold
# across ~160 call sites (~0.9% retired instructions, docs/dev/gb_oam_dma_cost.md).
# hot_bus_inline (gb.nim) pins it: always_inline on clang, `inline` on gcc,
# where a failed always_inline is a hard error.

when HDMA_STEAL_LEAD_DOTS >= 0:
  proc mem_land_hdma_due(mem: GbMemory; gb: GB) {.noinline.} =
    ## An owed HBlank block (HDMA_STEAL_LEAD_DOTS after the mode-0 edge)
    ## taking the bus on this M-cycle boundary.
    let ppu = gb.ppu
    if ppu.hdma_active and (ppu.lcd_status and 3'u8) == 0'u8:
      ppu_step_hdma(ppu, gb, in_cpu_cycle = true)
    else:
      ppu.hdma_block_due = false

proc mem_tick_bus*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true;
                   defer_hdma = false) {.hot_bus_inline.} =
  ## Everything an M-cycle advances except the PPU: scheduler, timer (which
  ## clocks serial) and OAM DMA. Split from the PPU half because mem_write
  ## applies a CPU write between them, after `dma_busy` is settled.
  if from_cpu: mem.cycle_tick_count += cycles
  when HDMA_STEAL_LEAD_DOTS >= 0:
    # An owed block past its deadline goes before this M-cycle.
    # `defer_hdma`: a write on the grant boundary reaches its register before
    # the block copies (gambatte dma/hdma_late_*); mem_write lands the block
    # after the byte. A read samples at the bottom and loses the race
    # (dma/hdma_start_*_2).
    if unlikely(gb.ppu.hdma_block_due) and from_cpu and not defer_hdma and
       gb.ppu.cycle_counter >= gb.ppu.hdma_due_deadline:
      mem_land_hdma_due(mem, gb)
  gb.scheduler.tick(cycles)
  timer_tick(gb.timer, gb, cycles)
  # Guard hoisted out of mem_dma_tick so an idle DMA costs a test, not a call.
  if mem.requested_oam_dma or mem.dma_position <= 0xA0:
    mem_dma_tick(mem, gb, cycles)

template mem_mdots*(mem: GbMemory): int =
  ## One M-cycle's PPU dots: 4, 2 at double speed, 0 while the PPU sits out
  ## a leaf switch's restart (GbMemory.ppu_mdot_shift).
  4 shr mem.ppu_mdot_shift

proc mem_tick_ppu*(mem: GbMemory; gb: GB; cycles: int; ignore_speed = false) {.hot_bus_inline.} =
  ## The PPU half of an M-cycle, in dots (half as many in double speed).
  # During a leaf switch's restart (SPEED_SWITCH_LEAF_PPU) the shift rounds
  # every M-cycle to no dots; callers splitting an M-cycle use mem_mdots.
  let ppu_cycles = if ignore_speed: cycles else: cycles shr mem.ppu_mdot_shift
  fifo_tick(gb.fifo_ppu, gb, ppu_cycles)
  when CGB_LYC_EDGE_DEFER and CGB_LYC_EDGE_POLL:
    # A CGB LYC write's STAT edge, one M-cycle after its byte landed.
    # Harness control, off by default; shipping books a scheduler event.
    if unlikely(mem.lyc_edge_owed):
      mem.lyc_edge_owed = false
      ppu_handle_stat_interrupt(gb.ppu, gb)


proc mem_tick_components*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true; ignore_speed = false) {.inline.} =
  ## Both halves, in order (mem_write splits them). The halves carry
  ## hot_bus_inline: without it mem_tick_bus went out of line (+0.9% retired
  ## instructions).
  mem_tick_bus(mem, gb, cycles, from_cpu)
  mem_tick_ppu(mem, gb, cycles, ignore_speed)

when CGB_WRITE_LATENCY_ANY:
  # CGB per-register write latency: a pipeline-register write reaches the
  # CGB PPU a register-specific number of dots later than on DMG, so the
  # M-cycle's dots run in pieces with the store between. One phase offset
  # fails: gambatte window/late_disable_* flip opposite ways on DMG and CGB.
  # Not in Pan Docs. Tests per value at the CGB_*_LATENCY knobs (gb.nim); six
  # independent numbers rather than one per bus is assumed.
  proc mem_tick_ppu_latched(mem: GbMemory; gb: GB) {.noinline.} =
    ## This M-cycle's PPU dots with a parked pipeline store landing part way
    ## through them. Cold path.
    let reg = int(mem.pipe_reg)
    let val = mem.pipe_val
    mem.pipe_reg = 0
    # A latency past the M-cycle's end saturates at `cap` (CGB_LATENCY_CAP).
    let mdots = mem_mdots(mem)
    let cap = mdots - CGB_LATENCY_CAP
    var done = 0
    template run(upto: int) =
      let n = min(upto, cap) - done
      if n > 0:
        mem_tick_ppu(mem, gb, n, ignore_speed = true)
        done += n
    template rest() =
      let n = mdots - done
      if n > 0: mem_tick_ppu(mem, gb, n, ignore_speed = true)
    case reg
    of 0xFF40:
      run(CGB_LCDC_LATENCY); ppu_store_lcdc(gb.ppu, gb, val)
    of 0xFF42:
      run(CGB_SCY_LATENCY); ppu_store_scy(gb.ppu, gb, val)
    of 0xFF43:
      run(CGB_SCX_LATENCY); ppu_store_scx(gb.ppu, gb, val)
    of 0xFF4A:
      run(CGB_WY_LATENCY)
      ppu_store_wy(gb.ppu, gb, val)
      run(CGB_WY_LATCH_LATENCY - int(mem.current_speed))
      ppu_latch_wy(gb.ppu, gb, val)
    of 0xFF4B:
      run(CGB_WX_LATENCY); ppu_store_wx(gb.ppu, gb, val)
    else: discard
    rest()

proc mem_reset_cycle_count*(mem: GbMemory) =
  mem.cycle_tick_count = 0

proc mem_tick_extra*(mem: GbMemory; gb: GB; total_expected: int) =
  let remaining = total_expected - mem.cycle_tick_count
  if remaining > 0: mem_tick_components(mem, gb, remaining)
  mem_reset_cycle_count(mem)

proc unusable_index(gb: GB; idx: int): int {.inline.} =
  ## The `mem.unusable` cell for `$FEA0..$FEFF`: the C-class mask folds four
  ## addresses per cell, CGB-D keeps all 96. Pan Docs gives no mask value;
  ## cgb-acid-hell's readback is the source (GbUnusableRegion, gb.nim).
  let a = if gb.quirks.unusable_region == urRamMasked: idx and not 0x18 else: idx
  a - 0xFEA0

proc read_unusable(mem: GbMemory; gb: GB; idx: int): uint8 {.noinline.} =
  ## `$FEA0..$FEFF`, one model per GbUnusableRegion member. Pan Docs: "This
  ## area returns $FF when OAM is blocked", the same lock as an OAM read
  ## (cpu_oam_open; DocBoy dmg/memory/not_usable_read_*). CPU only: DMA
  ## sources never land here, and during OAM DMA mem_read_busy answers $FF.
  ## Out of line: read_byte is hot, this page is not.
  if not cpu_oam_open(gb.ppu, is_write = false,
                      open_late = gb.quirks.oam_read_open_late,
                      ds = mem.current_speed != 0):
    return 0xFF'u8
  case gb.quirks.unusable_region
  of urZero:       0x00'u8
  of urNibbleEcho:
    # Pan Docs: "returns the high nibble of the lower address byte twice".
    let nib = uint8((idx shr 4) and 0x0F)
    (nib shl 4) or nib
  of urRamMasked, urRamPlain:
    mem.unusable[unusable_index(gb, idx)]

proc write_unusable(mem: GbMemory; gb: GB; idx: int; val: uint8) {.inline.} =
  ## The write half of read_unusable; only the two RAM models keep the byte.
  case gb.quirks.unusable_region
  of urZero, urNibbleEcho: discard
  of urRamMasked, urRamPlain:
    mem.unusable[unusable_index(gb, idx)] = val

proc read_byte*(mem: GbMemory; gb: GB; idx: int): uint8 =
  # The CGB boot ROM is 0x900 bytes with the cartridge header showing through
  # at 0x100..0x1FF; the DMG one is a flat 0x100.
  if mem.bootrom.len > 0 and idx < mem.bootrom.len and
     (idx < 0x100 or idx >= 0x200):
    return mem.bootrom[idx]
  case idx
  of 0x0000..0x3FFF: mbc_read_rom_lo(gb.cartridge, idx)
  of 0x4000..0x7FFF: mbc_read_rom_hi(gb.cartridge, idx)
  of 0x8000..0x9FFF: ppu_read(gb.ppu, gb, idx)
  of 0xA000..0xBFFF: mbc_read(gb.cartridge, idx)
  of 0xC000..0xCFFF: mem.wram[0][idx - 0xC000]
  of 0xD000..0xDFFF: mem.wram[mem.wram_bank][idx - 0xD000]
  of 0xE000..0xFDFF: read_byte(mem, gb, idx - 0x2000)
  of 0xFE00..0xFE9F: ppu_read(gb.ppu, gb, idx)
  of 0xFEA0..0xFEFF: read_unusable(mem, gb, idx)
  of 0xFF00:         joypad_read(gb.joypad, gb)
  of 0xFF01..0xFF02: serial_read(gb.serial, gb, idx)
  of 0xFF04..0xFF07: timer_read(gb.timer, idx)
  of 0xFF0F:
    when defined(gb_if_trace):
      echo "IFREAD ly=", gb.fifo_ppu.ly, " dot=", gb.fifo_ppu.cycle_counter,
           " if=", toHex(irq_read(gb.interrupts, idx), 2)
    irq_read(gb.interrupts, idx)
  of 0xFF10..0xFF3F: apu_read(gb.apu, idx, gb)
  of 0xFF46:         mem.dma  # always the last written value (mooneye oam_dma/reg_read)
  of 0xFF40..0xFF45, 0xFF47..0xFF4B:
    when defined(gb_dma_trace):
      if idx == 0xFF41 or idx == 0xFF44:
        echo "REGREAD a=", toHex(idx, 4), " ly=", gb.fifo_ppu.ly,
             " dot=", gb.fifo_ppu.cycle_counter,
             " v=", toHex(ppu_read(gb.ppu, gb, idx), 2)
    when defined(gb_phase_trace):
      if idx == 0xFF44:
        echo "LYREAD v=", ppu_read(gb.ppu, gb, idx), " ly=", gb.ppu.ly,
             " cc=", gb.ppu.cycle_counter, " mode=", gb.ppu.mode_flag
    ppu_read(gb.ppu, gb, idx)
  of 0xFF4D:
    if gb.cgb_native:
      0x7E'u8 or (uint8(mem.current_speed) shl 7) or (if mem.requested_speed_switch: 1'u8 else: 0'u8)
    else: 0xFF'u8
  of 0xFF4F:         ppu_read(gb.ppu, gb, idx)
  of 0xFF51..0xFF55: ppu_read(gb.ppu, gb, idx)
  of 0xFF68..0xFF6B: ppu_read(gb.ppu, gb, idx)
  of 0xFF56:
    # Infrared, CGB only. Bits 0/6/7 R/W; bit 1 reads 1 (no IR signal
    # modelled); bits 2-5 read set.
    if gb.cgb_native: (mem.rp and 0xC1'u8) or 0x3E'u8 else: 0xFF'u8
  of 0xFF70:
    # Pan Docs: bits 0-2 read/write. A stored 0 maps bank 1 but reads 0: the
    # 0 -> 1 substitution is in the bank decode (SVBK_READS_WRITTEN).
    if gb.cgb_native:
      0xF8'u8 or (when SVBK_READS_WRITTEN: mem.svbk else: mem.wram_bank)
    else: 0xFF'u8
  of 0xFF6C:
    # OPRI: $FF in compatibility mode (DocBoy cgb_dmg_mode/ppu/opri_write_read).
    if gb.cgb_native: 0xFE'u8 or mem.opri else: 0xFF'u8
  # FF72-FF77 exist on CGB/AGB even in compat mode, except FF74 (mooneye
  # misc/bits/unused_hwio-C); DMG reads 0xFF (acceptance/bits/unused_hwio-GS).
  of 0xFF72: (if gb.cgb_enabled: mem.ff72 else: 0xFF'u8)
  of 0xFF73: (if gb.cgb_enabled: mem.ff73 else: 0xFF'u8)
  of 0xFF74:
    if gb.cgb_native: mem.ff74 else: 0xFF'u8
  of 0xFF75: (if gb.cgb_enabled: mem.ff75 or 0x8F'u8 else: 0xFF'u8)
  # PCM12/PCM34: the channels' current 4-bit outputs (CH1/CH3 low nibble,
  # off channels 0). Channels advance lazily; the catch-up makes the read see
  # this cycle's phase (SameSuite apu/*).
  of 0xFF76:
    if gb.cgb_enabled:
      apu_catchup_all(gb.apu, gb)
      apu_env_late_due(gb.apu, gb)
      var lo = sq_dac_input(gb.apu.channel1)
      var hi = sq_dac_input(gb.apu.channel2)
      # CGB 0/A/B/C: a read on a rising duty step answers 0
      # (GbQuirks.pcm_read_edge_zero); channel 2 by PCM12_CH2_EDGE_ZERO.
      if gb.quirks.pcm_read_edge_zero:
        if sq_pcm_edge_zero(gb.apu.channel1, gb): lo = 0
        when PCM12_CH2_EDGE_ZERO:
          if sq_pcm_edge_zero(gb.apu.channel2, gb): hi = 0
      lo or (hi shl 4)
    else: 0xFF'u8
  of 0xFF77:
    if gb.cgb_enabled:
      apu_catchup_all(gb.apu, gb)
      apu_env_late_due(gb.apu, gb)
      gb.apu.channel3.ch3_dac_input() or (gb.apu.channel4.ch4_dac_input() shl 4)
    else: 0xFF'u8
  of 0xFF80..0xFFFE: mem.hram[idx - 0xFF80]
  of 0xFFFF:         irq_read(gb.interrupts, idx)
  else: 0xFF'u8

proc console_is_cgb*(gb: GB): bool {.inline.} =
  ## The console, not the mode: bus topology is the machine's (cgb_enabled is
  ## cleared for a DMG cart in compat mode).
  gb.boot_model in {bmCgb0, bmCgbABCDE, bmAgb}

proc dma_bus_of*(gb: GB; idx: int): uint8 {.inline.} =
  ## Which bus serves an address (GbDmaBus). WRAM is on the external bus on DMG.
  case idx
  of 0x0000..0x7FFF, 0xA000..0xBFFF: uint8(dbExternal)
  of 0x8000..0x9FFF:                 uint8(dbVideo)
  of 0xC000..0xFDFF:
    if console_is_cgb(gb): uint8(dbWram) else: uint8(dbExternal)
  else:                              uint8(dbNone)

const
  # What lands in OAM when a CPU write collides with the DMA on its bus: what
  # the DMA's source does to the data lines (mem_write_busy).
  DriveTristate* = 0'u8   # cartridge: sees /WR and lets go; OAM gets the CPU's byte
  DriveSource*   = 1'u8   # DMG WRAM: keeps driving; the two wire-AND
  DriveZero*     = 2'u8   # CGB video bus: the DMA loses the cycle and stores $00
  DriveIsolated* = 3'u8   # CGB WRAM bus: the DMA's read completes; only the CPU's access is lost

proc dma_drive_of*(gb: GB; idx: int): uint8 {.inline.} =
  case idx
  of 0x8000..0x9FFF: (if console_is_cgb(gb): DriveZero else: DriveTristate)
  of 0xC000..0xFDFF: (if console_is_cgb(gb): DriveIsolated else: DriveSource)
  else:              DriveTristate

proc mem_read_open(mem: GbMemory; gb: GB; idx: int): uint8 {.inline.} =
  ## A CPU read that reaches the bus, with the VRAM lock applied. CPU only:
  ## OAM DMA and HDMA use read_byte/write_byte unlocked. The OAM read lock is
  ## inside ppu_read.
  when defined(gb_dma_trace):
    if (idx and 0xE000) == 0x8000:
      echo "VRAMRD ly=", gb.ppu.ly, " dot=", gb.ppu.cycle_counter,
           " idx=", toHex(idx, 4), " latch=", gb.ppu.read_mode and 3'u8,
           " live=", gb.ppu.lcd_status and 3'u8,
           " open=", (if cpu_vram_open(gb.ppu, is_write = false,
                                       cgb = gb.cgb_enabled): 1 else: 0),
           " val=", toHex(read_byte(mem, gb, idx), 2)
  if (idx and 0xE000) == 0x8000:
    # One of the two points a held HBlank block can become visible at
    # (HDMA_VISIBLE_DOTS): this read samples after its M-cycle's dots.
    when HDMA_VISIBLE_DOTS != 0:
      if gb.ppu.hdma_bytes_held: ppu_land_hdma_if_due(gb.ppu, gb)
    if not cpu_vram_open(gb.ppu, is_write = false,
                         cgb = gb.cgb_enabled,
                         ds = mem.current_speed != 0): return 0xFF'u8
  read_byte(mem, gb, idx)

const OAMDMA_WRAM_A12* {.intdefine.} = 1
  ## On CGB a non-colliding CPU access to $C000-$FDFF during an external-bus
  ## OAM DMA keeps its A0-A11 but takes A12 (the WRAM half select) from the
  ## DMA's source. Pinned by gambatte oamdma/*busy*. Not on DMG, where WRAM
  ## shares the external bus and the access collides.

proc dma_wram_addr(mem: GbMemory; gb: GB; idx: int): int {.inline.} =
  ## `idx` with the WRAM half-select taken from a running CGB external-bus DMA
  ## (OAMDMA_WRAM_A12); identity otherwise.
  when OAMDMA_WRAM_A12 != 0:
    if idx >= 0xC000 and idx <= 0xFDFF and
       mem.dma_bus == uint8(dbExternal) and console_is_cgb(gb):
      let folded = if idx >= 0xE000: idx - 0x2000 else: idx
      # Raw source A12: an $E000 source goes out unfolded (mem_dma_tick).
      let a12 = (int(mem.current_dma_source) shr 12) and 1
      return (folded and not 0x1000) or (a12 shl 12)
  idx

proc mem_read_busy(mem: GbMemory; gb: GB; idx: int): uint8 {.noinline.} =
  ## Cold path: a CPU read while OAM DMA owns a bus. On that bus the CPU
  ## latches the byte the DMA moves this M-cycle; other buses and IO/HRAM/IE
  ## are untouched (Pan Docs, "OAM DMA Transfer"). The whole OAM page reads $FF.
  if idx >= 0xFE00 and idx <= 0xFEFF: return 0xFF'u8
  if dma_bus_of(gb, idx) == mem.dma_bus:
    # CGB video bus: the CPU takes the cycle, the DMA stores $00 in OAM.
    if mem.dma_drive == DriveZero:
      ppu_write(gb.ppu, gb, 0xFE00 + mem.dma_position - 1, 0'u8)
    return mem.dma_latch
  # No collision: an ordinary CPU read, but on CGB the DMA still drives A12.
  mem_read_open(mem, gb, dma_wram_addr(mem, gb, idx))

when IF_READ_SAMPLE_T < 4:
  proc mem_tick_if_read(mem: GbMemory; gb: GB) {.noinline.} =
    ## One M-cycle for the $FF0F read, latched IF_READ_SAMPLE_T dots in
    ## (gb.nim, irq_read). Do not split every M-cycle in mem_tick_components
    ## instead: +19.5% retired instructions (fifo_tick's idle span swallows
    ## whole M-cycles).
    when IF_READ_SAMPLE_T < 0:
      # Harness control, off by default: sample ahead of the whole M-cycle,
      # timer and serial included.
      irq_latch_mcycle(gb.interrupts)
      mem_tick_components(mem, gb, 4)
    else:
      mem_tick_bus(mem, gb, 4)
      let dots = mem_mdots(mem)
      var head = min(dots, IF_READ_SAMPLE_T shr mem.current_speed)
      when IF_READ_M2_144_TIE_DS != 0:
        # An IF read whose M-cycle starts on the line-144 OAM pulse's dot
        # sees it (IF_READ_M2_144_TIE_DS).
        if mem.current_speed != 0 and gb.ppu.ly == 143'u8 and
           gb.ppu.cycle_counter == M2_144_EARLY_DOT_DS:
          head = 1
      if head <= 0:
        irq_latch_mcycle(gb.interrupts)
        mem_tick_ppu(mem, gb, dots, ignore_speed = true)
      else:
        mem_tick_ppu(mem, gb, head, ignore_speed = true)
        # fifo_tick re-snapshots `read_mode`; keep the head's latch and take
        # only the tail's LY-advanced bit, or the split alone moves gambatte
        # oam_access/vram_m3 postread tests.
        let head_rm = gb.ppu.read_mode
        irq_latch_mcycle(gb.interrupts)
        if dots > head:
          mem_tick_ppu(mem, gb, dots - head, ignore_speed = true)
          gb.ppu.read_mode = head_rm or (gb.ppu.read_mode and LY_JUST_CHANGED)
    # The serial IF bit rises after the read's sample point
    # (SERIAL_CPU_SAMPLE_T, gb.nim).
    when SERIAL_CPU_SAMPLE_T < 4:
      serial_if_latch_fixup(gb)

proc mem_read*(mem: GbMemory; gb: GB; idx: int): uint8 {.hot_bus_inline.} =
  when defined(cpu_testbus):
    mem_tick_components(mem, gb, 4)
    return gb_testbus_read(idx)
  when IF_READ_SAMPLE_T < 4:
    if idx == 0xFF0F: mem_tick_if_read(mem, gb)
    else:             mem_tick_components(mem, gb, 4)
  else:
    mem_tick_components(mem, gb, 4)
  # A running DMA owns the bus and is decided first.
  when defined(gb_io_trace):
    # Diagnostic, off by default: every I/O read with the PPU's position
    # (LY left out: wait loops spam it).
    if idx >= 0xFF00 and idx != 0xFF44 or idx >= 0xFE00 and idx < 0xFEA0:
      let v = if mem.dma_busy: mem_read_busy(mem, gb, idx)
              else: mem_read_open(mem, gb, idx)
      echo "IOR ", toHex(idx, 4), "=", toHex(v, 2), " ly=", gb.ppu.ly,
           " dot=", gb.ppu.cycle_counter, " mode=", (gb.ppu.lcd_status and 3),
           " ds=", mem.current_speed
      return v
  if mem.dma_busy: return mem_read_busy(mem, gb, idx)
  mem_read_open(mem, gb, idx)

proc mem_read_oam_bug(mem: GbMemory; gb: GB; idx: int) {.noinline.} =
  if not mem.dma_busy: oam_bug_access(gb, obRead, uint16(idx))

proc mem_read_data*(mem: GbMemory; gb: GB; idx: int): uint8 {.inline.} =
  ## A CPU data read (not a fetch). An OAM-page read during the scan
  ## scrambles OAM (oam_bug_access, ppu.nim), sampled before the M-cycle's
  ## dots; not while OAM DMA owns the page. Fetches skip this: PC in OAM is
  ## not modelled, and the test costs +0.4..0.9% retired instructions.
  when not defined(cpu_testbus):
    if unlikely((idx and 0xFF00) == 0xFE00): mem_read_oam_bug(mem, gb, idx)
  mem_read(mem, gb, idx)

proc mem_dma_classify(mem: GbMemory; gb: GB) =
  ## Which bus the OAM DMA unit drives for `current_dma_source`.
  let raw_src = int(mem.current_dma_source)
  if raw_src >= 0xE000 and console_is_cgb(gb):
    # CGB: a source at or above $E000 goes to the external bus, open bus.
    mem.dma_bus     = uint8(dbExternal)
    mem.dma_drive   = DriveTristate
    mem.dma_openbus = true
  else:
    # DMG: at or above $E000 fetches through the echo (mooneye oam_dma/sources-GS).
    var bus_src = raw_src
    if bus_src >= 0xE000: bus_src = bus_src and not 0x2000
    mem.dma_bus     = dma_bus_of(gb, bus_src)
    mem.dma_drive   = dma_drive_of(gb, bus_src)
    mem.dma_openbus = false

proc mem_dma_transfer*(mem: GbMemory; source: uint8) =
  mem.dma         = source
  mem.requested_oam_dma = true
  mem.next_dma_counter  = 0

proc write_byte*(mem: GbMemory; gb: GB; idx: int; val: uint8) =
  inc mem.write_count
  # VRAM, OAM and I/O feed the pipeline; a deferred mode 3 runs first.
  if (idx >= 0x8000 and idx < 0xA000) or (idx >= 0xFE00 and idx < 0xFF80):
    fifo_sync(gb)
  # FF50: any write with bit 0 set unmaps the boot ROM.
  when defined(gb_io_trace):
    # Diagnostic, off by default: every I/O write's commit dot.
    if idx >= 0xFF00 or idx >= 0xFE00 and idx < 0xFEA0:
      echo "IOW ", toHex(idx, 4), "=", toHex(val, 2), " ly=", gb.ppu.ly,
           " dot=", gb.ppu.cycle_counter, " mode=", (gb.ppu.lcd_status and 3),
           " ds=", mem.current_speed
  if idx == 0xFF50 and (val and 1) != 0:
    mem.bootrom = @[]
    # A DMG cart drops out of CGB mode but the machine stays a CGB (timing,
    # STAT-write glitch), so cgb_enabled is not cleared.
    gb_sync_cgb_native(gb)
    # VBK goes with the CGB register set: map attributes read zero from here.
    if not gb.cgb_native: gb.ppu.vram_bank = 0
  case idx
  of 0x0000..0x7FFF:
    mbc_write(gb.cartridge, idx, val)
    # Every banking register is written through this window (mbc_sync_rom_map).
    mbc_sync_rom_map(gb.cartridge)
  of 0x8000..0x9FFF: ppu_write(gb.ppu, gb, idx, val)
  of 0xA000..0xBFFF: mbc_write(gb.cartridge, idx, val)
  of 0xC000..0xCFFF: mem.wram[0][idx - 0xC000] = val
  of 0xD000..0xDFFF: mem.wram[mem.wram_bank][idx - 0xD000] = val
  of 0xE000..0xFDFF: write_byte(mem, gb, idx - 0x2000, val)
  of 0xFE00..0xFE9F: ppu_write(gb.ppu, gb, idx, val)
  of 0xFEA0..0xFEFF: write_unusable(mem, gb, idx, val)
  of 0xFF00:         joypad_write(gb.joypad, gb, val)
  of 0xFF01..0xFF02: serial_write(gb.serial, gb, idx, val)
  of 0xFF04..0xFF07: timer_write(gb.timer, gb, idx, val)
  of 0xFF0F:
    irq_write(gb.interrupts, idx, val)
    # Where in the M-cycle the write meets the serial shifter (SERIAL_CPU_SAMPLE_T).
    when SERIAL_CPU_SAMPLE_T < 4: serial_if_write_fixup(gb)
  of 0xFF10..0xFF3F: apu_write(gb.apu, idx, val, gb)
  of 0xFF46:
    when OAMDMA_RESTART_HANDOVER != 0:
      # A write under a running transfer hands the bus to the new source
      # page at once (OAMDMA_RESTART_HANDOVER, gb.nim); the old transfer's
      # remaining bytes are untouched (no test says where they come from).
      # The restart follows on its usual delay.
      if mem.dma_busy:
        let old_src  = mem.current_dma_source
        let old_open = mem.dma_openbus
        mem.current_dma_source = uint16(val) shl 8
        mem_dma_classify(mem, gb)
        mem.current_dma_source = old_src
        mem.dma_openbus        = old_open
    mem_dma_transfer(mem, val)
  of 0xFF40..0xFF45, 0xFF47..0xFF4B:
    when CGB_LYC_CMP_LATCH:
      # A CGB LYC write in flight borrows two PPU stops (LYC_STOP_FOLDED,
      # fifo_ppu.nim): release them for this write, re-arm after.
      if gb.lyc_land_left >= 0: lyc_stop_release(gb.fifo_ppu, gb)
      ppu_write(gb.ppu, gb, idx, val)
      if gb.lyc_land_left >= 0: lyc_stop_arm(gb.fifo_ppu, gb)
    else:
      ppu_write(gb.ppu, gb, idx, val)
  of 0xFF4D:
    if gb.cgb_native: mem.requested_speed_switch = (val and 0x1) != 0
  of 0xFF4F:         ppu_write(gb.ppu, gb, idx, val)
  of 0xFF51..0xFF55: ppu_write(gb.ppu, gb, idx, val)
  of 0xFF68..0xFF6B: ppu_write(gb.ppu, gb, idx, val)
  of 0xFF56:
    if gb.cgb_native: mem.rp = val and 0xC1
  of 0xFF70:
    if gb.cgb_native:
      mem.svbk = val and 0x7
      mem.wram_bank = if mem.svbk == 0: 1'u8 else: mem.svbk
  of 0xFF6C:
    if gb.cgb_native: mem.opri = val and 0x01
  of 0xFF72: mem.ff72 = val
  of 0xFF73: mem.ff73 = val
  of 0xFF74:
    if gb.cgb_native: mem.ff74 = val
  of 0xFF75: mem.ff75 = val or 0x8F
  of 0xFF80..0xFFFE: mem.hram[idx - 0xFF80] = val
  of 0xFFFF:         irq_write(gb.interrupts, idx, val)
  else: discard

proc mem_write_open(mem: GbMemory; gb: GB; idx: int; val: uint8;
                    sampled_late = false) {.inline.} =
  ## A CPU write that reaches the bus; dropped when the VRAM/OAM window is
  ## shut. Both locks live here: ppu_write has none, and OAM DMA writes
  ## through write_byte unlocked. A write samples the latched mode, a read
  ## the live one (cpu_oam_open).
  if (idx and 0xE000) == 0x8000:
    # The other landing point for a held HBlank block: before this write
    # changes VRAM.
    when HDMA_VISIBLE_DOTS != 0:
      if gb.ppu.hdma_bytes_held: ppu_land_hdma_if_due(gb.ppu, gb)
    if not cpu_vram_open(gb.ppu, is_write = true, cgb = gb.cgb_enabled,
                            ds = mem.current_speed != 0'u8): return
  elif idx >= 0xFE00 and idx <= 0xFE9F:
    # `mcycle_dots`: the span ahead of the sample point (whole cycle for a
    # start-of-cycle sample, 0 for end-of-cycle).
    if not cpu_oam_open(gb.ppu, is_write = true,
                        mcycle_dots = (if sampled_late: 0'i32
                                       else: int32(4 shr mem.current_speed)),
                        ds = mem.current_speed != 0'u8,
                        cgb = gb.cgb_enabled): return
  write_byte(mem, gb, idx, val)

proc mem_write_busy(mem: GbMemory; gb: GB; idx: int; val: uint8) {.noinline.} =
  ## Cold-path counterpart of mem_read_busy. A CPU write onto the DMA's bus
  ## never reaches its destination; the CPU co-drives the DMA's data lines,
  ## and the Drive* table says what lands in OAM (gambatte oamdma/*busy*).
  if idx >= 0xFE00 and idx <= 0xFEFF: return
  if dma_bus_of(gb, idx) == mem.dma_bus:
    # dma_busy implies dma_position in 1..0xA0: position-1 is this M-cycle's slot.
    if mem.dma_drive != DriveIsolated:
      let driven =
        case mem.dma_drive
        of DriveSource: val and mem.dma_latch
        of DriveZero:   0'u8
        else:           val
      mem.dma_latch = driven
      ppu_write(gb.ppu, gb, 0xFE00 + mem.dma_position - 1, driven)
    return
  # No collision: an ordinary CPU write, but on CGB the DMA still drives A12.
  mem_write_open(mem, gb, dma_wram_addr(mem, gb, idx), val)

proc mem_write_tail(mem: GbMemory; gb: GB) {.noinline.} =
  ## The end of a CPU write that left work for the M-cycle: a CGB pipeline
  ## store part way through the dots, then the boundary work.
  when CGB_WRITE_LATENCY_ANY:
    if mem.pipe_reg != 0: mem_tick_ppu_latched(mem, gb)
    else:                 mem_tick_ppu(mem, gb, 4)
  else:
    mem_tick_ppu(mem, gb, 4)
  mem_flush_deferred(mem, gb)

const IF_WRITE_LAND_DOTS* {.intdefine.} = 1
  ## Dots into its M-cycle at which a CPU write to IF lands: a request the
  ## PPU raises in those dots is overwritten by the write (0 = top of the
  ## M-cycle). Default 1: a request on the write's first dot is lost, one on
  ## its second survives. Pinned both sides by gambatte `*_ifw_*` and DocBoy
  ## `dmg/interrupts/*_reset_if_*`.
const IF_WRITE_LAND_DOTS_DS* {.intdefine.} = 1
  ## The same in double speed, in dots. Default 1 (half the M-cycle), pinned
  ## both sides by gambatte `*_ifw_ds_*`.
  ## Clean-room: derived from test ROM sources/outputs and dingbat's own trace
  ## runs; no emulator source consulted.
const VRAM_WRITE_M3_END_DOTS* {.intdefine.} = 3
  ## Dots into its M-cycle at which a VRAM write issued in mode 3 asks the
  ## lock: a mode 3 ending in those dots lets it through (0 = off, ask at the
  ## top). Default 3, pinned both sides by gambatte vramw_m3end/*.
const VRAM_WRITE_M3_END_DOTS_DS* {.intdefine.} = 0
  ## The same at double speed, in dots; 1 fails gambatte vramw_m3end/*_ds_*.
proc mem_write_vram_m3(mem: GbMemory; gb: GB; idx: int; val: uint8) {.noinline.} =
  ## A mode-3 VRAM write asks the lock VRAM_WRITE_M3_END_DOTS into its M-cycle.
  let dots = mem_mdots(mem)
  let pre = min(dots, if mem.current_speed != 0'u8: VRAM_WRITE_M3_END_DOTS_DS
                      else: VRAM_WRITE_M3_END_DOTS)
  if pre > 0: mem_tick_ppu(mem, gb, pre, ignore_speed = true)
  mem_write_open(mem, gb, idx, val)
  if dots - pre > 0: mem_tick_ppu(mem, gb, dots - pre, ignore_speed = true)
  if mem.write_deferred: mem_flush_deferred(mem, gb)

proc mem_write*(mem: GbMemory; gb: GB; idx: int; val: uint8) {.hot_bus_inline.} =
  ## A CPU write commits at the START of its M-cycle, before its PPU dots:
  ## the VRAM/OAM lock is decided on the mode at the start (cpu_vram_open),
  ## and data landing after the dots would sit one M-cycle behind its lock
  ## (M3_PIPE_MCYCLES, fifo_ppu). Reads sample via the read_mode latch. The
  ## bus half runs first because dma_busy selects the write path.
  when defined(cpu_testbus):
    mem_tick_components(mem, gb, 4)
    gb_testbus_write(idx, val)
    return
  when HDMA_STEAL_LEAD_DOTS >= 0:
    mem_tick_bus(mem, gb, 4, defer_hdma = HDMA_WRITE_DEFER_LO <= idx and
                                          idx <= HDMA_WRITE_DEFER_HI)
  else:
    mem_tick_bus(mem, gb, 4)
  if mem.dma_busy:
    mem_write_busy(mem, gb, idx, val)
  elif idx >= 0xFE00 and idx <= 0xFEFF:
    # The PPU has not moved yet (mem_tick_bus): the OAM bug's sample point.
    oam_bug_access(gb, obWrite, uint16(idx), val)
    if OAM_WRITE_SAMPLE_END != 0 and idx <= 0xFE9F:
      # An OAM write asks its lock after the dots, like a read
      # (OAM_WRITE_SAMPLE_END, gb.nim).
      mem_tick_ppu(mem, gb, 4)
      mem_write_open(mem, gb, idx, val, sampled_late = true)
      if mem.write_deferred: mem_flush_deferred(mem, gb)
      return
    mem_write_open(mem, gb, idx, val)
  elif IF_WRITE_LAND_DOTS != 0 and idx == 0xFF0F:
    # IF_WRITE_LAND_DOTS.
    let dots = mem_mdots(mem)
    let pre = min(dots, if mem.current_speed != 0'u8: IF_WRITE_LAND_DOTS_DS
                        else: min(IF_WRITE_LAND_DOTS, dots - 1))
    if pre > 0: mem_tick_ppu(mem, gb, pre, ignore_speed = true)
    mem_write_open(mem, gb, idx, val)
    mem_tick_ppu(mem, gb, dots - pre, ignore_speed = true)
    if mem.write_deferred: mem_flush_deferred(mem, gb)
    return
  elif VRAM_WRITE_M3_END_DOTS != 0 and (idx and 0xE000) == 0x8000 and
       (gb.ppu.lcd_status and 3'u8) == 3'u8:
    mem_write_vram_m3(mem, gb, idx, val)
    return
  else:
    mem_write_open(mem, gb, idx, val)
  when HDMA_STEAL_LEAD_DOTS >= 0:
    # An owed HBlank block takes the bus after the byte (see mem_tick_bus).
    if unlikely(gb.ppu.hdma_block_due) and
       HDMA_WRITE_DEFER_LO <= idx and idx <= HDMA_WRITE_DEFER_HI and
       gb.ppu.cycle_counter >= gb.ppu.hdma_due_deadline:
      mem_land_hdma_due(mem, gb)
  # One flag for everything landing after the byte (pipeline store, STAT
  # edge), so the common path pays one test.
  if mem.write_deferred: mem_write_tail(mem, gb)
  else:                  mem_tick_ppu(mem, gb, 4)

proc mem_write_head*(mem: GbMemory; gb: GB; idx: int; val: uint8;
                     head_t: int): int {.noinline.} =
  ## mem_write for the interrupt dispatch's last push, stopped `head_t` CPU
  ## T-cycles into the PPU half so the caller can clear IF there
  ## (dispatch_interrupt, IRQ_SAMPLE_T); returns the dots left for
  ## mem_write_rest. A push that defers work (a PPU register under SP) runs
  ## whole, and the clear follows the M-cycle.
  when defined(cpu_testbus):
    mem_tick_components(mem, gb, 4)
    gb_testbus_write(idx, val)
    return 0
  mem_tick_bus(mem, gb, 4)
  if mem.dma_busy:
    mem_write_busy(mem, gb, idx, val)
  elif idx >= 0xFE00 and idx <= 0xFEFF:
    oam_bug_access(gb, obWrite, uint16(idx), val)
    if OAM_WRITE_SAMPLE_END != 0 and idx <= 0xFE9F:
      mem_tick_ppu(mem, gb, 4)
      mem_write_open(mem, gb, idx, val, sampled_late = true)
      if mem.write_deferred: mem_flush_deferred(mem, gb)
      return 0
    mem_write_open(mem, gb, idx, val)
  else:
    mem_write_open(mem, gb, idx, val)
  if mem.write_deferred:
    mem_write_tail(mem, gb)
    return 0
  let dots = mem_mdots(mem)
  let head = clamp(head_t shr mem.current_speed, 0, dots)
  if head > 0: mem_tick_ppu(mem, gb, head, ignore_speed = true)
  dots - head

proc mem_write_rest*(mem: GbMemory; gb: GB; rest: int) {.inline.} =
  ## The dots mem_write_head left.
  if rest > 0: mem_tick_ppu(mem, gb, rest, ignore_speed = true)

proc mem_read_word*(mem: GbMemory; gb: GB; idx: int): uint16 =
  # A word at $FFFF wraps to $0000 (gambatte oamdma/*busypopFFFF).
  uint16(mem_read(mem, gb, idx)) or
    (uint16(mem_read(mem, gb, (idx + 1) and 0xFFFF)) shl 8)

proc mem_write_word*(mem: GbMemory; gb: GB; idx: int; val: uint16) =
  # Only LD (nn),SP: low byte first (Game Boy: Complete Technical Reference).
  # Pushes go high byte first and do their own.
  mem_write(mem, gb, idx,                  uint8(val and 0xFF))
  mem_write(mem, gb, (idx + 1) and 0xFFFF, uint8(val shr 8))

proc mem_vdma_bus_capture*(mem: GbMemory; gb: GB; src_lo: uint8; val: uint8) =
  ## An in-flight OAM DMA stores what the external bus carries; under a VRAM
  ## DMA that is a block byte at the block's SOURCE address. Called from the
  ## block copy: it is not clocked by OAM DMA bus cycles (gambatte
  ## dma/hdma_transition_oamdma_1 HALTs across the block). Past $A0 there is
  ## no port. VDMA_OAM_BUS_CAPTURE, gb.nim.
  if mem.dma_position <= 0xA0 and src_lo < 0xA0'u8:
    mem.dma_latch = val
    write_byte(mem, gb, 0xFE00 + int(src_lo), val)

proc mem_dma_release_frozen(mem: GbMemory; gb: GB) {.noinline.} =
  ## A frozen OAM DMA that stored its last byte gives OAM back
  ## (OAMDMA_FROZEN_RELEASE, gb.nim): the step past $A0 needs no bus cycle.
  when OAMDMA_FROZEN_RELEASE != 0:
    when defined(gb_dma_trace):
      echo "DMAFROZEN pos=", mem.dma_position, " ly=", gb.ppu.ly,
           " dot=", gb.ppu.cycle_counter
    if mem.dma_position == 0xA0:
      inc mem.dma_position
      when OAM_SCAN_DMA_LOCK != 0:
        if mem.dma_busy: fifo_oam_lock_change(gb.fifo_ppu, gb, taking = false)
      mem.dma_busy = false

proc mem_dma_tick*(mem: GbMemory; gb: GB; cycles: int) =
  # Idle exit: neither flag can be set inside the loop (~8-12% of a profile).
  if not mem.requested_oam_dma and mem.dma_position > 0xA0: return
  when OAMDMA_HALT_PAUSE != 0:
    var cycles = cycles
    # Clocked by bus cycles; HALT stops them OAMDMA_HALT_GRACE M-cycles in.
    # OAMDMA_WAKE_EXTRA is added at the wake: that M-cycle's bus half runs
    # with `halted` still set (OAMDMA_HALT_PAUSE).
    if gb.cpu.halted:
      # A VRAM DMA makes its own bus cycles, so the unit keeps stepping
      # (storing nothing; VDMA_OAM_BUS_CAPTURE).
      if VDMA_OAM_BUS_CAPTURE == 0 or not mem.vdma_bus_hold:
        when OAMDMA_HALT_GRACE != 0:
          if not mem.dma_was_halted and gb.dma_halt_grace < uint8(OAMDMA_HALT_GRACE):
            inc gb.dma_halt_grace
          else:
            mem.dma_was_halted = true
            mem_dma_release_frozen(mem, gb)
            return
        else:
          mem.dma_was_halted = true
          mem_dma_release_frozen(mem, gb)
          return
    elif mem.dma_was_halted:
      mem.dma_was_halted = false
      when OAMDMA_HALT_GRACE != 0: gb.dma_halt_grace = 0
      when OAMDMA_HALT_PAUSE == 1: cycles += OAMDMA_WAKE_EXTRA
    else:
      when OAMDMA_HALT_GRACE != 0: gb.dma_halt_grace = 0
      when OAMDMA_HALT_PAUSE == 3: return
  for _ in 0 ..< cycles:
    if mem.requested_oam_dma:
      inc mem.next_dma_counter
      if mem.next_dma_counter == (when CGB_OAM_DMA_START_T != 8:
                                    (if console_is_cgb(gb): CGB_OAM_DMA_START_T
                                     else: 8)
                                  else: 8):
        when defined(gb_dma_trace):
          echo "DMASTART ly=", gb.fifo_ppu.ly,
               " dot=", gb.fifo_ppu.cycle_counter,
               " src=", toHex(uint16(mem.dma) shl 8, 4)
        when OAM_SCAN_DMA_LOCK != 0:
          # The transfer takes OAM; a running mode-2 scan reads nothing until
          # it is given back.
          fifo_oam_lock_change(gb.fifo_ppu, gb, taking = true)
        mem.requested_oam_dma  = false
        mem.current_dma_source = uint16(mem.dma) shl 8
        mem.dma_position       = 0
        mem.internal_dma_timer = 0
        mem.dma_busy           = false
        # The bus is fixed for the whole transfer; classify the source once.
        mem_dma_classify(mem, gb)
    if mem.dma_position <= 0xA0:
      if (mem.internal_dma_timer and 3) == 0:
        if mem.dma_position < 0xA0:
          # Under a VRAM DMA the position steps but nothing lands here
          # (mem_vdma_bus_capture).
          if VDMA_OAM_BUS_CAPTURE == 0 or not mem.vdma_bus_hold:
            # The latch is what a colliding CPU read sees.
            if mem.dma_openbus:
              mem.dma_latch = 0xFF'u8
            else:
              var src = int(mem.current_dma_source) + mem.dma_position
              if src >= 0xE000: src = src and not 0x2000
              mem.dma_latch = read_byte(mem, gb, src)
            write_byte(mem, gb, 0xFE00 + mem.dma_position, mem.dma_latch)
        inc mem.dma_position
        when OAM_SCAN_DMA_LOCK != 0:
          if mem.dma_position > 0xA0 and mem.dma_busy:
            # The transfer gives OAM back on this dot.
            fifo_oam_lock_change(gb.fifo_ppu, gb, taking = false)
        mem.dma_busy = mem.dma_position <= 0xA0
      inc mem.internal_dma_timer

const SPEED_SWITCH_FREEZES_OAM_DMA* {.intdefine.} = 1
  ## OAM DMA does not step through a speed-switch stall: no bus cycles while
  ## the CPU clock is off (as at HALT). The timer is a separate domain and
  ## keeps counting. Pinned by gambatte oamdma/oamdmasrcC0_speedchange_readC000
  ## and dma/hdma_transition_speedchange_oamdma.
const SPEED_SWITCH_OAM_DMA_HANDBACK_T* {.intdefine.} = 4
  ## Bus cycles the unit is still clocked for across the stall: the hand-back
  ## M-cycle.

const SPEED_SWITCH_STALL_CPU* {.intdefine.} = 131072
  ## The stall in cycles of the CPU clock at the speed switched TO, so a
  ## to-single switch takes twice the real time. 2^17: gambatte
  ## speedchange_tima00_* count +128 TIMA ticks at TAC=$04. Pinned to one
  ## M-cycle both sides by daid speed_switch_timing_* and AGE spsw-*. Pan Docs
  ## ("FF4D — KEY1") says 2050 M-cycles; the tests measure 2^17.

const SPEED_SWITCH_PPU_EXTRA_DOTS* {.intdefine.} = 12 - 4 * CGB_HALT_PPU_LEAD
  ## Dots the PPU advances across the stall beyond the CPU clock's count.
  ## daid speed_switch_timing_ly/_stat pin 65548 dots across a to-double
  ## switch (65536 + 12); those ROMs HALT before the STOP, so 12 is 8 for the
  ## switch plus the halt-exit M-cycle CGB_HALT_PPU_LEAD (gb.nim) owns. The
  ## gambatte speedchange*_ly44_m3* ladder, which never halts, measures 8.
  ## Tied to the lead so they move together. Pinned to one dot both sides.

const SS_EXTRA_SINGLE_SAME* = -9999
  ## Sentinel for SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE ("same as double"),
  ## outside any legal dot count since the value may be negative.

const SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE* {.intdefine.} =
  when CGB_HALT_PPU_LEAD != 0: 3 else: SS_EXTRA_SINGLE_SAME
  ## The same for a switch ending in SINGLE speed; the sentinel means "use
  ## SPEED_SWITCH_PPU_EXTRA_DOTS" (the split needs CGB_HALT_PPU_LEAD). The
  ## ly44_m3 ladder measures 8, 11, 19, 22, 30 dots = A, A+B, 2A+B, 2A+2B,
  ## 3A+2B, so A = 8, B = 3: a to-single switch leaves the PPU grid 3 dots
  ## off the CPU's. Open: gambatte lcd_offset wants A+B = 0 mod 4.

const SPEED_SWITCH_STALL_RUNS_CPU_CLOCK* {.intdefine.} = 1
  ## Whether the timer/serial/OAM-DMA domain runs during the stall. It does
  ## (gambatte speedchange_tima00_*). Pan Docs' "DIV does not tick" is about
  ## the STOP leaves; the switch leaf is a HALT (Pan Docs' STOP chart). DIV
  ## is still reset at the switch, before the stall.

proc spsw_extra_dots(mem: GbMemory): int {.inline.} =
  ## SPEED_SWITCH_PPU_EXTRA_DOTS for the speed just switched TO.
  const extra_single =
    when SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE != SS_EXTRA_SINGLE_SAME:
      SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE
    else: SPEED_SWITCH_PPU_EXTRA_DOTS
  if mem.current_speed == 1: SPEED_SWITCH_PPU_EXTRA_DOTS else: extra_single

proc mem_tick_stalled(mem: GbMemory; gb: GB; cycles: int;
                      first_chunk = true; ppu_hold = 0) =
  ## mem_tick_components for the speed-switch stall: no fetch, CPU-clock
  ## domain per SPEED_SWITCH_STALL_RUNS_CPU_CLOCK, PPU at real-time rate.
  ## `ppu_hold`: first-chunk dots not run here (already run by the entry
  ## check, or held for the wake: SPEED_SWITCH_HALT_PPU_LEAD).
  gb.scheduler.tick(cycles)
  when SPEED_SWITCH_STALL_RUNS_CPU_CLOCK != 0:
    timer_tick(gb.timer, gb, cycles)
    when SPEED_SWITCH_FREEZES_OAM_DMA == 0:
      mem_dma_tick(mem, gb, cycles)
    elif SPEED_SWITCH_OAM_DMA_HANDBACK_T != 0:
      # Once per stall: the hand-back is at the grant.
      if first_chunk:
        mem_dma_tick(mem, gb, SPEED_SWITCH_OAM_DMA_HANDBACK_T)
        # Frozen from here to the stall's end, as under a HALT.
        if not mem.requested_oam_dma: mem_dma_release_frozen(mem, gb)
  # `current_speed` is already the speed switched TO: 1 = ended in double.
  let extra = if first_chunk: spsw_extra_dots(mem) else: 0
  let ppu_cycles = (cycles shr mem.current_speed) + extra - ppu_hold
  fifo_tick(gb.fifo_ppu, gb, ppu_cycles)
  # The APU's share of the same oscillator restart (APU_SPSW_EXTRA_DOTS).
  if first_chunk:
    gb.apu.apu_stall_extra(gb, (if mem.current_speed == 1: APU_SPSW_EXTRA_DOTS
                                else: APU_SPSW_EXTRA_DOTS_SINGLE))
    gb.apu.apu_spsw_rephase(gb)
  when CGB_LYC_EDGE_DEFER and CGB_LYC_EDGE_POLL:
    # As in mem_tick_ppu.
    if unlikely(mem.lyc_edge_owed):
      mem.lyc_edge_owed = false
      ppu_handle_stat_interrupt(gb.ppu, gb)


const SPEED_SWITCH_STALL_ENDS_ON_IRQ* {.intdefine.} = 1
  ## An interrupt during the stall ends it, as it ends any HALT. c-sp
  ## speed-switch/caution/spsw-interrupts-*: a timer overflowing mid-stall
  ## reads DIV = $10 on hardware; a full 2^17 stall can only give $00.
const SPEED_SWITCH_HALT_PPU_LEAD* {.intdefine.} = 1
  ## The stall is the switch leaf's CGB HALT, so it holds the PPU back like
  ## any CGB halt (CGB_HALT_PPU_LEAD, gb.nim): its first M-cycle runs no dots
  ## and the wake pays them back. No-op for a stall that runs out; a STAT or
  ## VBlank wake lands one M-cycle later, a timer wake does not move. DocBoy
  ## `double_speed/interrupts/speed_switch_to_*_interrupt_*` (CGB E); timer
  ## half: c-sp `spsw-interrupts-*` (hardware-checked).
const SPEED_SWITCH_ENTRY_IRQ_CHECK* {.intdefine.} = 1
  ## Whether the stall's HALT also checks for an interrupt before its first
  ## M-cycle, so a request rising inside STOP (after the leaf choice saw none)
  ## ends it with no stall cycle spent. By then the PPU has run the switch's
  ## extra dots less the held-back ones (6 into double speed, none into
  ## single; the 6 pinned both sides). DocBoy
  ## `speed_switch_to_double_interrupt_*_aligned_with_stop_nops_*` (CGB E).
proc mem_stall_until_irq(mem: GbMemory; gb: GB; stall_cycles: int;
                         ppu_debt: var int): int =
  ## The stall in M-cycle steps, stopping once an interrupt is ready; the
  ## first step carries the once-per-stall work. `ppu_debt`: dots held back
  ## (SPEED_SWITCH_HALT_PPU_LEAD) for the caller to pay at the wake.
  const step = 4
  # IE = 0 cannot wake: one call instead of 32768 steps (most games switch
  # with IE = 0).
  let irq = gb.interrupts
  if not (irq.vblank_enabled or irq.lcd_stat_enabled or irq.timer_enabled or
          irq.serial_enabled or irq.joypad_enabled):
    mem_tick_stalled(mem, gb, stall_cycles)
    return stall_cycles
  let hold =
    when SPEED_SWITCH_HALT_PPU_LEAD != 0: CGB_HALT_PPU_LEAD_DOTS shr mem.current_speed
    else: 0
  var pre = 0
  when SPEED_SWITCH_ENTRY_IRQ_CHECK != 0:
    # SPEED_SWITCH_ENTRY_IRQ_CHECK.
    pre = max(0, spsw_extra_dots(mem) - hold)
    if pre > 0: fifo_tick(gb.fifo_ppu, gb, pre)
    if interrupt_ready(gb.interrupts):
      # Woken before the first M-cycle: only the once-per-stall work. Into
      # single speed the extra dots are fewer than the held-back ones, so the
      # wake owes that much less.
      let short = min(0, spsw_extra_dots(mem) - hold - pre)
      mem_tick_stalled(mem, gb, 0, first_chunk = true,
                       ppu_hold = hold + pre + short)
      ppu_debt = hold + short
      return 0
  var done = 0
  while done < stall_cycles:
    let n = min(step, stall_cycles - done)
    let first = done == 0
    mem_tick_stalled(mem, gb, n, first_chunk = first,
                     ppu_hold = (if first: hold + pre else: 0))
    done += n
    if interrupt_ready(gb.interrupts):
      # As a halt, the latch misses a serial request this M-cycle's tap
      # edge raised (SERIAL_HALT_TAIL_BLIND, serial.nim).
      when SERIAL_CPU_SAMPLE_T < 4 and SERIAL_HALT_TAIL_BLIND != 0:
        if not halt_serial_tail_blind(gb): break
      else:
        break
  ppu_debt = hold
  done

const STOP_RTC_RUNS* {.intdefine.} = 1
  ## Whether a cartridge clock (MBC3, HuC3, TAMA5) keeps counting in STOP.
  ## Pan Docs, "MBC3": the "RTC requires an external 32.768 kHz Quartz
  ## Oscillator", so stopping the console's oscillator cannot stop it. STOP
  ## freezes the scheduler, so each STOP step moves the RTC-second event on
  ## by hand. DocBoy `mbc/mbc3/interactive/mbc3_rtc_gb_stopped_recover`.

proc mem_tick_stopped*(mem: GbMemory; gb: GB) =
  ## One step in STOP mode: the machine clock is stopped (Pan Docs, "Using the
  ## STOP Instruction"); only a cartridge clock ticks (STOP_RTC_RUNS). The rest
  ## paces the frontend: step_frame waits for `frame`, which a frozen PPU
  ## never sets.
  let ppu = gb.ppu
  ppu.dots_since_frame += int32(4 shr mem.current_speed)
  if ppu.dots_since_frame >= DOTS_PER_FRAME:
    ppu.dots_since_frame = 0
    ppu.frame = true
  when STOP_RTC_RUNS != 0:
    let due = gb.scheduler.pending_at(etRtcSecond)
    if due != high(CycleCount):
      if due <= gb.scheduler.cycles + 4:
        # The tick reschedules itself a second on from the frozen clock.
        gb.scheduler.clear(etRtcSecond)
        if gb.cartridge of Mbc3: Mbc3(gb.cartridge).rtc_tick()
        elif gb.cartridge of Huc3: Huc3(gb.cartridge).huc3_rtc_tick()
        elif gb.cartridge of Tama5: Tama5(gb.cartridge).tama5_rtc_tick()
      else:
        gb.scheduler.advance_pending(etRtcSecond, gb.scheduler.cycles, 4)
  when defined(test_harness):
    # The harness's timed input keeps its clock running in STOP (joypad.nim).
    if gb_harness_input != nil: gb_harness_input(gb, true)

proc stop_panel(mem: GbMemory; gb: GB) =
  ## The panel during STOP (Pan Docs; daid stop_instr*): DMG blanks white;
  ## CGB with the LCD on shows black, except in mode 3, where the image
  ## holds. The mode is sampled on the STOP fetch.
  let ppu = gb.ppu
  if not ppu.lcd_enabled or not gb.cgb_enabled:
    ppu_blank_frame(ppu, gb)
  elif ppu.mode_flag != 3:
    for i in 0 ..< ppu.framebuffer.len: ppu.framebuffer[i] = 0'u16
    ppu.frame = true
    ppu.dots_since_frame = 0

const SPEED_SWITCH_IME0_LEAF_HOLD_T* {.intdefine.} = 8
  ## SPEED_SWITCH_IRQ_LEAF_HOLD_T for the leaf Pan Docs' STOP chart defines:
  ## a switch with an interrupt pending and IME clear ("STOP is a 1-byte
  ## opcode, mode doesn't change, DIV is reset, CPU speed changes"). c-sp's
  ## measurements behind SPEED_SWITCH_IRQ_LEAF_HOLD_T are on the IME-set
  ## "glitches" leaf. DocBoy `*_aligned_with_stop_nops_*` (CGB E, IME clear)
  ## want 5..8 T; 4 and 9 fail. CGB B/C unmeasured, same value. On the glitch
  ## leaf DocBoy's `*_ime1_*` want 8 where c-sp's CGB-E measurement says 4
  ## (docs/dev/gb-failure-triage.md I7).

const STOP_MODE_OPERAND_MCYCLE* {.intdefine.} = 1
  ## 1: the two-byte STOP-mode leaf runs its operand M-cycle, whole machine
  ## ticking, before the clock stops; the DIV reset lands at its end, one
  ## M-cycle after the fetch (as SPEED_SWITCH_DIV_RESET_T). 2: tick only the
  ## divider. 0: reset at the fetch. DocBoy `*stop_read_tima_*` read TIMA one
  ## higher after the wake (the 262 kHz tap rises in that M-cycle; 1 or 2
  ## pass); `dma/interactive/dma_stop_during_transfer_timing_round2` wants the
  ## OAM DMA one byte further on, which only 1 gives.

proc stop_instr*(mem: GbMemory; gb: GB): bool =
  ## STOP ($10). Returns whether the byte after the opcode is consumed. Pan
  ## Docs' STOP flow chart ("Reducing Power Consumption"), sampled at the fetch:
  ##
  ##   button held ─ IRQ pending → 1 byte, mode unchanged, DIV not reset
  ##               └ no IRQ      → 2 bytes, HALT mode,     DIV not reset
  ##   no button ─ no switch ─ IRQ pending → 1 byte,  STOP mode, DIV reset
  ##             │            └ no IRQ     → 2 bytes, STOP mode, DIV reset
  ##             └ switch ─ no IRQ      → 2 bytes, HALT mode, DIV reset, speed changes
  ##                      └ IRQ pending → 1 byte, mode unchanged, DIV reset, speed changes
  ##
  ## A held button beats a requested switch. The chart's IME split on the
  ## last leaf ("glitches non-deterministically") takes the defined leaf. Not
  ## modelled: whether the skipped byte is read, and an oscillator restart
  ## delay on leaving STOP mode.
  # The speed switch and stop_panel reach the pipeline and the idle horizon.
  fifo_sync(gb)
  gb.wl_mark = gb.scheduler.cycles
  let button_held = joypad_lines(gb.joypad) != 0x0F'u8
  let irq_pending = interrupt_ready(gb.interrupts)
  # The second byte is consumed exactly when no interrupt is pending.
  result = not irq_pending

  if button_held:
    # No DIV reset, no switch, no STOP mode: a plain HALT or a one-byte nothing.
    if not irq_pending: gb.cpu.halted = true
    return

  if mem.requested_speed_switch and gb.cgb_enabled:
    mem.requested_speed_switch = false
    when HDMA_SPEEDSWITCH_KILL_W != 0 and HDMA_HALT_REQ == 0:
      # HDMA_SPEEDSWITCH_KILL_W: armed only while a transfer exists.
      if gb.ppu.hdma_active: gb.ppu.hdma_kill_from = gb.ppu.cycle_counter
    # The switch resets DIV (Pan Docs' chart), through the timer so the
    # divider's consumers see a write at the old speed
    # (SPEED_SWITCH_DIV_RESET_T, timer.nim).
    timer_speed_switch_div_reset(gb.timer, gb)
    let old_speed = mem.current_speed
    mem.current_speed = mem.current_speed xor 1
    mem.ppu_mdot_shift = int(mem.current_speed)
    # The channels' next_step deadlines live outside the scheduler's events.
    gb.apu.apu_rescale_speed(gb, old_speed, mem.current_speed)
    gb.scheduler.set_speed(mem.current_speed)
    # Re-aim the DIV-APU edge at the NEW speed: set_speed's rescale would
    # also scale the tap's lag (APU_SPSW_TAP_LAG_T, apu.nim).
    gb.scheduler.clear(etAPUFrameSeq)
    gb.scheduler.schedule(apu_div_phase(gb.timer, gb), etAPUFrameSeq)
    # The switch leaf's HALT; skipped when an interrupt is pending (the
    # chart's "1 byte, mode doesn't change" leaf).
    when SPEED_SWITCH_IRQ_LEAF_HOLD_T != 0:
      if irq_pending:
        # Oscillator restart on the aborted-halt leaf: T-cycles the divider owes.
        let hold =
          if not gb.cpu.ime: SPEED_SWITCH_IME0_LEAF_HOLD_T
          elif gb.quirks.spsw_irq_leaf_hold_short: SPEED_SWITCH_IRQ_LEAF_HOLD_T div 2
          else: SPEED_SWITCH_IRQ_LEAF_HOLD_T
        gb.timer.hold_t = hold
        when SPEED_SWITCH_LEAF_PPU != 0:
          if hold > 0 and (not gb.cpu.ime or SPEED_SWITCH_LEAF_PPU_IME1 != 0):
            # The PPU sits out the restart, then takes the switch's extra
            # dots (SPEED_SWITCH_LEAF_PPU).
            fifo_tick(gb.fifo_ppu, gb, spsw_extra_dots(mem))
            mem.ppu_mdot_shift = PPU_SIT_OUT
    if not irq_pending:
      # In cycles of the new-speed CPU clock (the scheduler's domain).
      const stall_cycles = SPEED_SWITCH_STALL_CPU
      var spent = stall_cycles
      var ppu_debt = 0
      when HDMA_HALT_REQ != 0:
        # A halt for the VRAM DMA: its edge detector stops with the CPU
        # clock; a request the STOP's execute cycle meets is taken there
        # (HDMA_HALT_REQ, gb.nim).
        let ppu = gb.ppu
        let hdma_live = ppu.hdma_active
        when defined(gb_dma_trace):
          echo "STOPSW ly=", ppu.ly, " dot=", ppu.cycle_counter,
               " mode=", (ppu.lcd_status and 3'u8), " to=", mem.current_speed,
               " due=", (if ppu.hdma_block_due: 1 else: 0),
               " dl=", ppu.hdma_due_deadline
        if hdma_live:
          gb.hdma_switch_stall = true
          ppu.hdma_halt_dot = ppu.cycle_counter
          if ppu.hdma_block_due and ppu.hdma_due_deadline != high(int32) and
             not gb.gdma_req and not gb.hdma_start_req:
            if ppu.hdma_due_deadline <= ppu.cycle_counter + hdma_halt_mdots(gb):
              ppu_hdma_halt_takenuest(ppu, gb)
            else:
              ppu.hdma_due_deadline = high(int32)
          else:
            gb.hdma_halt_open = true
      when SPEED_SWITCH_STALL_RUNS_CPU_CLOCK != 0:
        # The divider runs, so the DIV-APU event needs no lifting.
        when SPEED_SWITCH_STALL_ENDS_ON_IRQ != 0:
          spent = mem_stall_until_irq(mem, gb, stall_cycles, ppu_debt)
        else:
          mem_tick_stalled(mem, gb, stall_cycles)
      else:
        # The divider is frozen: lift the DIV-APU event over the stall and
        # re-aim it from the reset divider.
        gb.scheduler.clear(etAPUFrameSeq)
        mem_tick_stalled(mem, gb, stall_cycles)
        gb.scheduler.schedule(apu_div_phase(gb.timer, gb), etAPUFrameSeq)
      when HDMA_HALT_REQ != 0:
        if hdma_live:
          # The stall's end is the wake (cpu_halt_wake): the taken block's
          # bytes, or a block that came due while its HBlank lasts. A stall
          # that ran out has paid the PPU's lead.
          gb.hdma_switch_stall   = false
          gb.hdma_halt_open = false
          when defined(gb_dma_trace):
            echo "STALLEND ly=", ppu.ly, " dot=", ppu.cycle_counter,
                 " mode=", (ppu.lcd_status and 3'u8), " debt=", ppu_debt
          let lead_paid =
            int32(CGB_HALT_PPU_LEAD_DOTS shr mem.current_speed) - int32(ppu_debt)
          when HDMA_WAKE_BLIND_DOTS > 0:
            # Only a stall an interrupt ends has a wake M-cycle for the edge
            # detector to miss (HDMA_WAKE_BLIND_DOTS, gb.nim).
            gb.hdma_wake_dot =
              if spent < stall_cycles: ppu.cycle_counter
              else: ppu.cycle_counter - int32(HDMA_WAKE_BLIND_DOTS) - 1'i32
          if gb.hdma_halt_taken:
            ppu_hdma_pay_halt_request(ppu, gb)
            gb.hdma_latch_run = true
          else:
            ppu_hdma_wake(ppu, gb, lead_paid)
      if ppu_debt != 0:
        # The wake pays the held-back dots (as at a HALT's, cpu.nim).
        mem_tick_ppu(mem, gb, ppu_debt, ignore_speed = true)
      # Charged to the instruction so mem_tick_extra does not repeat it.
      mem.cycle_tick_count += spent
    return

  # The two STOP-mode leaves: DIV reset through the FF04 write path.
  when STOP_MODE_OPERAND_MCYCLE == 1:
    if result: mem_tick_components(mem, gb, 4)
  elif STOP_MODE_OPERAND_MCYCLE == 2:
    if result: timer_tick(gb.timer, gb, SPEED_SWITCH_DIV_RESET_T)
  timer_write(gb.timer, gb, 0xFF04, 0)
  # `halted` + `locked` as cpu_lock (no interrupt ends this); `stopped`: the
  # machine is stopped and a P10-P13 line going low ends it (cpu.nim tick).
  gb.cpu.halted  = true
  gb.cpu.locked  = true
  gb.cpu.stopped = true
  stop_panel(mem, gb)
