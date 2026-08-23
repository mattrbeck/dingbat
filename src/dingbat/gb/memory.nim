# GB Memory bus (included by gb.nim)

# -d:gb_dma_trace (diagnostic, compiled out of shipping builds; REGREAD and
# MODE are on hot paths): DMASTART (OAM DMA takes the bus), REGREAD (CPU reads
# of STAT/LY), MODE (PPU mode changes), FF55 (writes, with mode/hdma_active),
# HDMABLOCK (each block copy), VRAMRD (CPU VRAM reads with the lock state).

proc new_gb_memory*(gb: GB): GbMemory =
  # DMA (FF46) reads back the last written value; post-boot it's 0xFF on
  # DMG-family models, 0x00 on CGB (Pan Docs power-up sequence).
  result = GbMemory(wram_bank: 1, svbk_raw: 1, dma_position: 0xA1,
                    dma: if gb.cgb_enabled: 0x00'u8 else: 0xFF'u8)
  for i in 0 ..< 8:
    result.wram[i] = newSeq[uint8](0x1000)
  when GB_POWERUP_WRAM_PATTERN != 0:
    # Non-zero power-up WRAM (BullyGB InitRAMTest). A fixed xorshift, not a
    # seeded RNG: the screenshot, save-state and rollback gates need identical
    # bytes on every run.
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
  ## Apply the part of a CPU write that belongs on the M-cycle boundary rather
  ## than at the write's commit point (GbMemory.write_deferred). mem_write
  ## commits the byte at the top of its M-cycle to sit in phase with the mode-3
  ## pipeline; the STAT interrupt line and FF55 were already in phase, so their
  ## effect stays on the boundary (ppu_write_machinery classifies; gambatte
  ## m2enable/*_late_*, gbmicrotest lyc1_write_timing_*). IF is NOT deferred:
  ## the CPU's IF store lands ahead of the flags the PPU raises in the same
  ## M-cycle (gambatte miscmstatirq, lycEnable, m0enable, m1).
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
    ppu_write_machinery(gb.ppu, gb, reg, v)
  ppu_flush_stat_write(gb.ppu, gb)

proc skip_boot*(mem: GbMemory; gb: GB) =
  mem.bootrom = @[]
  # Post-boot register state (mooneye boot_hwio-*). NR52 first: sound-register
  # writes are dropped while the APU is off. The NR14 trigger starts channel 1
  # like the boot beep (NR52 = 0xF1); the beep has decayed by the handoff.
  mem.write_byte(gb, 0xFF26, 0xF1)
  mem.write_byte(gb, 0xFF10, 0x80)
  mem.write_byte(gb, 0xFF11, 0xBF)
  mem.write_byte(gb, 0xFF12, 0xF3)
  mem.write_byte(gb, 0xFF14, 0xBF)
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
  # SGB/SGB2 hand off late enough that channel 1 has shut off entirely
  # (boot_hwio-S: NR52 = 0xF0).
  gb.apu.channel1.current_volume = 0
  gb.apu.channel1.vol_env_is_updating = false
  if gb.boot_model in {bmSgb, bmSgb2}:
    gb.apu.channel1.enabled = false
  mem.write_byte(gb, 0xFF40, 0x91)
  mem.write_byte(gb, 0xFF42, 0x00)
  mem.write_byte(gb, 0xFF43, 0x00)
  mem.write_byte(gb, 0xFF45, 0x00)
  mem.write_byte(gb, 0xFF47, 0xFC)
  # OBP0/OBP1/DMA are the bytes no boot ROM writes, so they show the silicon's
  # power-on state and split on the machine, not the cart's CGB flag: $FF on
  # DMG/MGB/SGB, $00 on CGB/AGB (Pan Docs, "Console state after boot ROM
  # hand-off" for DMA; mooneye-wilbertpol misc/boot_hwio-C for all three).
  let cgb_silicon = gb.boot_model in {bmCgb0, bmCgbABCDE, bmAgb}
  let obp_boot = if cgb_silicon: 0x00'u8 else: 0xFF'u8
  mem.write_byte(gb, 0xFF48, obp_boot)
  mem.write_byte(gb, 0xFF49, obp_boot)
  mem.dma = obp_boot
  mem.write_byte(gb, 0xFF4A, 0x00)
  mem.write_byte(gb, 0xFF4B, 0x00)
  if gb.cgb_enabled:
    # The CGB boot ROM leaves the palette-index ports mid-sequence: BCPS =
    # 0xC8, OCPS = 0xD0 (mooneye misc/boot_hwio-C).
    mem.write_byte(gb, 0xFF68, 0xC8)
    mem.write_byte(gb, 0xFF6A, 0xD0)
  # P1 at handoff: DMG-family boot ROMs never touch it, so it reads $CF; the
  # CGB, SGB and AGB boot ROMs hand off $FF (mooneye misc/boot_hwio-C covers
  # cgb+agb). The gbedge p00 probe's $CF on an AGS is a flashcart menu's key
  # poll, not the boot ROM (docs/flashcart-runbook.md).
  if gb.boot_model in {bmDmg0, bmDmgABC, bmMgb}:
    gb.joypad.button_keys = true
    gb.joypad.direction_keys = true
  mem.write_byte(gb, 0xFFFF, 0x00)
  # None of the writes above is a CPU M-cycle, so nothing else consumes this.
  mem_flush_deferred(mem, gb)

# mem_read/mem_write and the M-cycle tick halves sit on clang's inline
# threshold across ~160 opcode call sites (~0.9% retired instructions,
# docs/gb_oam_dma_cost.md). hot_bus_inline (gb.nim) pins it: always_inline on
# clang, plain `inline` on gcc, where a failed always_inline is a hard error.

when HDMA_STEAL_LEAD_DOTS >= 0:
  proc mem_land_hdma_due(mem: GbMemory; gb: GB) {.noinline.} =
    ## An owed HBlank block (requested HDMA_STEAL_LEAD_DOTS dots after the
    ## mode-0 edge) taking the bus on the M-cycle boundary the CPU just reached.
    let ppu = gb.ppu
    if ppu.hdma_active and (ppu.lcd_status and 3'u8) == 0'u8:
      ppu_step_hdma(ppu, gb, in_cpu_cycle = true)
    else:
      ppu.hdma_block_due = false

proc mem_tick_bus*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true;
                   defer_hdma = false) {.hot_bus_inline.} =
  ## Everything an M-cycle advances except the PPU: scheduler, timer (which
  ## clocks the serial shifter) and the OAM DMA unit. Split from the PPU half
  ## because a CPU write is applied between them (mem_write), and `dma_busy`
  ## must be settled before the write picks its path.
  if from_cpu: mem.cycle_tick_count += cycles
  when HDMA_STEAL_LEAD_DOTS >= 0:
    # An owed block whose deadline has passed goes before this M-cycle.
    # `defer_hdma`: a CPU write commits its byte at the top of its M-cycle, so
    # a write on the grant boundary reaches the register before the block
    # copies (gambatte dma/hdma_late_destl, hdma_late_wrambank); a read samples
    # at the bottom and loses the race (dma/hdma_start_*_2). mem_write lands
    # the block itself, after the byte.
    if unlikely(gb.ppu.hdma_block_due) and from_cpu and not defer_hdma and
       gb.ppu.cycle_counter >= gb.ppu.hdma_due_deadline:
      mem_land_hdma_due(mem, gb)
  gb.scheduler.tick(cycles)
  timer_tick(gb.timer, gb, cycles)
  # Guard hoisted out of mem_dma_tick so an idle DMA costs a test, not a call.
  if mem.requested_oam_dma or mem.dma_position <= 0xA0:
    mem_dma_tick(mem, gb, cycles)

proc mem_tick_ppu*(mem: GbMemory; gb: GB; cycles: int; ignore_speed = false) {.hot_bus_inline.} =
  ## The PPU half of an M-cycle, in dots (half as many in double speed).
  let ppu_cycles = if ignore_speed: cycles else: cycles shr mem.current_speed
  # Direct call for the shipping renderer; the scanline one uses the method table.
  if gb.fifo_ppu != nil: fifo_tick(gb.fifo_ppu, gb, ppu_cycles)
  else: gb.ppu.tick(gb, ppu_cycles)
  when CGB_LYC_EDGE_DEFER and CGB_LYC_EDGE_POLL:
    # A CGB LYC write's STAT edge, one M-cycle boundary after its byte landed.
    # Harness control; shipping books a scheduler event (CGB_LYC_EDGE_POLL).
    if unlikely(mem.lyc_edge_owed):
      mem.lyc_edge_owed = false
      ppu_handle_stat_interrupt(gb.ppu, gb)


proc mem_tick_components*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true; ignore_speed = false) {.inline.} =
  ## Both halves, in the order every caller but mem_write wants them. The
  ## halves carry hot_bus_inline because splitting them left mem_tick_bus out
  ## of line on every bus access (+0.9% retired instructions).
  mem_tick_bus(mem, gb, cycles, from_cpu)
  mem_tick_ppu(mem, gb, cycles, ignore_speed)

when CGB_WRITE_LATENCY_ANY:
  # CGB per-register write latency: a pipeline-register write reaches the CGB
  # PPU a register-specific number of dots later than the DMG one, so the
  # M-cycle's dots run in pieces with the store between them. One phase offset
  # cannot do it: gambatte window/late_disable_{0,1,2} and
  # window/late_disable_early_scx03_wx12_* flip in opposite directions between
  # DMG and CGB. Not in Pan Docs. Every latency ships at 0 (CGB_WX_LATENCY in
  # gb.nim); CGB_LATENCY_CAP keeps one from filling a 2-dot double-speed M-cycle.
  proc mem_tick_ppu_latched(mem: GbMemory; gb: GB) {.noinline.} =
    ## This M-cycle's PPU dots with a parked pipeline store landing part way
    ## through them. Cold path.
    let reg = int(mem.pipe_reg)
    let val = mem.pipe_val
    mem.pipe_reg = 0
    # 4 dots per M-cycle, 2 in double speed. A latency past the M-cycle's end
    # saturates at `cap` (CGB_LATENCY_CAP).
    let mdots = 4 shr mem.current_speed
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
      run(CGB_LCDC_TDSEL_LATENCY); ppu_store_lcdc_tdsel(gb.ppu, gb, val)
      run(CGB_LCDC_LATENCY);       ppu_store_lcdc(gb.ppu, gb, val)
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
  ## Which cell of `mem.unusable` an address in `$FEA0..$FEFF` reaches: the
  ## C-class mask folds four addresses onto a cell, CGB-D keeps all 96 apart.
  ## Pan Docs says a mask exists but not its value; cgb-acid-hell's readback
  ## is the source (GbUnusableRegion in gb.nim).
  let a = if gb.quirks.unusable_region == urRamMasked: idx and not 0x18 else: idx
  a - 0xFEA0

proc read_unusable(mem: GbMemory; gb: GB; idx: int): uint8 {.inline.} =
  ## `$FEA0..$FEFF`, one model per GbUnusableRegion member (Pan Docs, "FEA0-FEFF
  ## range"). Pan Docs' "$FF when OAM is blocked" in mode 2/3 is not modelled
  ## (the OAM lock lives in ppu_read; cgb-acid-hell avoids those modes). The
  ## OAM-DMA case is: mem_read_busy answers $FF for the whole page.
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
      if gb.fifo_ppu != nil:
        echo "IFREAD ly=", gb.fifo_ppu.ly, " dot=", gb.fifo_ppu.cycle_counter,
             " if=", toHex(irq_read(gb.interrupts, idx), 2)
    irq_read(gb.interrupts, idx)
  of 0xFF10..0xFF3F: apu_read(gb.apu, idx, gb)
  of 0xFF46:         mem.dma  # always the last written value (mooneye oam_dma/reg_read)
  of 0xFF40..0xFF45, 0xFF47..0xFF4B:
    when defined(gb_dma_trace):
      if (idx == 0xFF41 or idx == 0xFF44) and gb.fifo_ppu != nil:
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
    # Infrared port, CGB only. Bits 0/6/7 R/W; bit 1 reads 1 (no IR signal is
    # modelled); bits 2-5 read set.
    if gb.cgb_native: (mem.rp and 0xC1'u8) or 0x3E'u8 else: 0xFF'u8
  of 0xFF70:
    if gb.cgb_native: 0xF8'u8 or mem.svbk_raw else: 0xFF'u8
  # FF72-FF77 exist on CGB/AGB silicon even in DMG-compat mode, except FF74
  # (mooneye misc/bits/unused_hwio-C); on DMG they read 0xFF
  # (acceptance/bits/unused_hwio-GS).
  of 0xFF72: (if gb.cgb_enabled: mem.ff72 else: 0xFF'u8)
  of 0xFF73: (if gb.cgb_enabled: mem.ff73 else: 0xFF'u8)
  of 0xFF74:
    if gb.cgb_native: mem.ff74 else: 0xFF'u8
  of 0xFF75: (if gb.cgb_enabled: mem.ff75 or 0x8F'u8 else: 0xFF'u8)
  # PCM12/PCM34: the four channels' current 4-bit outputs (CH1/CH3 low nibble,
  # CH2/CH4 high; off channels read 0). The channels advance lazily, so the
  # catch-up is what makes the read see this cycle's phase (SameSuite apu/*).
  of 0xFF76:
    if gb.cgb_enabled:
      apu_catchup_all(gb.apu, gb)
      var lo = gb.apu.channel1.ch1_dac_input()
      var hi = gb.apu.channel2.ch2_dac_input()
      # CGB 0/A/B/C: a read on a rising duty step answers 0 for that channel
      # (GbQuirks.pcm_read_edge_zero).
      if gb.quirks.pcm_read_edge_zero:
        if gb.apu.channel1.ch1_pcm_edge_zero(gb): lo = 0
        if gb.apu.channel2.ch2_pcm_edge_zero(gb): hi = 0
      lo or (hi shl 4)
    else: 0xFF'u8
  of 0xFF77:
    if gb.cgb_enabled:
      apu_catchup_all(gb.apu, gb)
      gb.apu.channel3.ch3_dac_input() or (gb.apu.channel4.ch4_dac_input() shl 4)
    else: 0xFF'u8
  of 0xFF80..0xFFFE: mem.hram[idx - 0xFF80]
  of 0xFFFF:         irq_read(gb.interrupts, idx)
  else: 0xFF'u8

proc console_is_cgb*(gb: GB): bool {.inline.} =
  ## The console, not the mode: bus topology is the machine's, so this reads
  ## boot_model rather than cgb_enabled (cleared for a DMG cart in compat mode).
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
  # What lands in OAM when a CPU write collides with the DMA on its bus, decided
  # by what the DMA's source does to the data lines (mem_write_busy).
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
  ## A CPU read that reaches the bus, with the PPU's VRAM lock applied. Only
  ## the CPU comes through here: the OAM DMA unit and HDMA go straight to
  ## read_byte/write_byte and must keep their access. The OAM read lock sits
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
    # This read samples after its M-cycle's dots, so it is one of the two
    # points a held HBlank block can become visible at (HDMA_VISIBLE_DOTS).
    when HDMA_VISIBLE_DOTS != 0:
      if gb.ppu.hdma_bytes_held: ppu_land_hdma_if_due(gb.ppu, gb)
    if not cpu_vram_open(gb.ppu, is_write = false,
                         cgb = gb.cgb_enabled,
                         ds = mem.current_speed != 0): return 0xFF'u8
  read_byte(mem, gb, idx)

const OAMDMA_WRAM_A12* {.intdefine.} = 1
  ## On CGB the OAM DMA drives the address bus too: a non-colliding CPU access
  ## to $C000-$FDFF during an external-bus DMA uses its own A0-A11 but takes
  ## A12 (the bank-0 / SVBK-banked half select) from the DMA's source address.
  ## gambatte oamdma/*busy* pins it by construction: the suite emits a
  ## bit-12-flipped template exactly when A12(source) != A12(CPU address).
  ## Not on DMG, where WRAM shares the external bus and the access collides.

proc dma_wram_addr(mem: GbMemory; gb: GB; idx: int): int {.inline.} =
  ## `idx` with the WRAM half-select taken from a running CGB external-bus DMA
  ## (OAMDMA_WRAM_A12); identity otherwise.
  when OAMDMA_WRAM_A12 != 0:
    if idx >= 0xC000 and idx <= 0xFDFF and
       mem.dma_bus == uint8(dbExternal) and console_is_cgb(gb):
      let folded = if idx >= 0xE000: idx - 0x2000 else: idx
      # The raw source A12: an $E000 source goes out on the external bus
      # unfolded (mem_dma_tick), so $E000 -> 0 and $F000 -> 1.
      let a12 = (int(mem.current_dma_source) shr 12) and 1
      return (folded and not 0x1000) or (a12 shl 12)
  idx

proc mem_read_busy(mem: GbMemory; gb: GB; idx: int): uint8 {.noinline.} =
  ## Cold path: a CPU read while the OAM DMA unit owns a bus. A read on that
  ## bus never reaches memory; the CPU latches the byte the DMA is moving this
  ## M-cycle. Other buses and IO/HRAM/IE are untouched (Pan Docs, "OAM DMA
  ## Transfer"). The whole OAM page reads $FF, not just $FE00-$FE9F.
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
    ## One M-cycle for the $FF0F read, whose byte latches IF_READ_SAMPLE_T dots
    ## in (gb.nim, irq_read). Behind an address test rather than splitting
    ## every M-cycle in mem_tick_components: that costs +19.5% retired
    ## instructions, because fifo_tick's idle span swallows whole M-cycles.
    when IF_READ_SAMPLE_T < 0:
      # Harness control: the read samples ahead of the whole M-cycle, timer and
      # serial shifter included (IF_READ_SAMPLE_T in gb.nim).
      irq_latch_mcycle(gb.interrupts)
      mem_tick_components(mem, gb, 4)
    else:
      mem_tick_bus(mem, gb, 4)
      let dots = 4 shr mem.current_speed
      let head = min(dots, IF_READ_SAMPLE_T shr mem.current_speed)
      if head <= 0:
        irq_latch_mcycle(gb.interrupts)
        mem_tick_ppu(mem, gb, dots, ignore_speed = true)
      else:
        mem_tick_ppu(mem, gb, head, ignore_speed = true)
        # fifo_tick re-snapshots `read_mode` on entry; keep the head's latch
        # (this M-cycle's) and take only the tail's LY-advanced bit, or the
        # split alone moves gambatte oam_access/vram_m3 postread rows.
        let head_rm = gb.ppu.read_mode
        irq_latch_mcycle(gb.interrupts)
        if dots > head:
          mem_tick_ppu(mem, gb, dots - head, ignore_speed = true)
          gb.ppu.read_mode = head_rm or (gb.ppu.read_mode and LY_JUST_CHANGED)
    # The serial IF bit rises on the M-cycle's last T-cycle, after the read's
    # sample point (SERIAL_CPU_SAMPLE_T in gb.nim).
    when SERIAL_CPU_SAMPLE_T < 4:
      serial_if_latch_fixup(gb)

proc mem_read*(mem: GbMemory; gb: GB; idx: int): uint8 {.hot_bus_inline.} =
  when IF_READ_SAMPLE_T < 4:
    if idx == 0xFF0F: mem_tick_if_read(mem, gb)
    else:             mem_tick_components(mem, gb, 4)
  else:
    mem_tick_components(mem, gb, 4)
  # A running DMA owns the bus and is decided first.
  if mem.dma_busy: return mem_read_busy(mem, gb, idx)
  mem_read_open(mem, gb, idx)

proc mem_dma_transfer*(mem: GbMemory; source: uint8) =
  mem.dma         = source
  mem.requested_oam_dma = true
  mem.next_dma_counter  = 0

proc write_byte*(mem: GbMemory; gb: GB; idx: int; val: uint8) =
  # Any write with bit 0 set unmaps the boot ROM (the CGB boot ROM writes
  # 0x11, the DMG one 0x01).
  if idx == 0xFF50 and (val and 1) != 0:
    mem.bootrom = @[]
    # Handoff: a DMG cart drops out of CGB mode but the machine stays a CGB
    # (timing, STAT-write glitch), so cgb_enabled is not cleared here.
    gb_sync_cgb_native(gb)
    # VBK goes with the CGB register set: bank 1 is frozen at what the boot
    # ROM left (nothing), so the map attributes read as zero from here on.
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
  of 0xFF46:         mem_dma_transfer(mem, val)
  of 0xFF40..0xFF45, 0xFF47..0xFF4B: ppu_write(gb.ppu, gb, idx, val)
  of 0xFF4D:
    if gb.cgb_native: mem.requested_speed_switch = (val and 0x1) != 0
  of 0xFF4F:         ppu_write(gb.ppu, gb, idx, val)
  of 0xFF51..0xFF55: ppu_write(gb.ppu, gb, idx, val)
  of 0xFF68..0xFF6B: ppu_write(gb.ppu, gb, idx, val)
  of 0xFF56:
    if gb.cgb_native: mem.rp = val and 0xC1
  of 0xFF70:
    if gb.cgb_native:
      mem.svbk_raw = val and 0x7
      mem.wram_bank = val and 0x7
      if mem.wram_bank == 0: mem.wram_bank = 1
  of 0xFF72: mem.ff72 = val
  of 0xFF73: mem.ff73 = val
  of 0xFF74:
    if gb.cgb_native: mem.ff74 = val
  of 0xFF75: mem.ff75 = val or 0x8F
  of 0xFF80..0xFFFE: mem.hram[idx - 0xFF80] = val
  of 0xFFFF:         irq_write(gb.interrupts, idx, val)
  else: discard

proc mem_write_open(mem: GbMemory; gb: GB; idx: int; val: uint8) {.inline.} =
  ## A CPU write that reaches the bus; dropped when the VRAM/OAM window is
  ## shut. Both locks are here because ppu_write has none of its own (a write
  ## samples the latched mode, a read the live one; cpu_oam_open), and the OAM
  ## DMA unit writes through write_byte unlocked.
  if (idx and 0xE000) == 0x8000:
    # The other point a held HBlank block can land at: this write is about to
    # change VRAM and a held block would otherwise land on top of it.
    when HDMA_VISIBLE_DOTS != 0:
      if gb.ppu.hdma_bytes_held: ppu_land_hdma_if_due(gb.ppu, gb)
    if not cpu_vram_open(gb.ppu, is_write = true): return
  elif idx >= 0xFE00 and idx <= 0xFE9F:
    if not cpu_oam_open(gb.ppu, is_write = true,
                        mcycle_dots = int32(4 shr mem.current_speed)): return
  write_byte(mem, gb, idx, val)

proc mem_write_busy(mem: GbMemory; gb: GB; idx: int; val: uint8) {.noinline.} =
  ## Cold path counterpart of mem_read_busy. A CPU write onto the bus the DMA
  ## owns never reaches its destination; the CPU co-drives the data lines the
  ## DMA latches, so what the Drive* table says lands in OAM at this M-cycle's
  ## position (gambatte oamdma/*busy*).
  if idx >= 0xFE00 and idx <= 0xFEFF: return
  if dma_bus_of(gb, idx) == mem.dma_bus:
    # dma_busy holds only for dma_position in 1..0xA0, so position-1 is the
    # slot filled at the top of this M-cycle.
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
  ## The end of a CPU write that left something for the M-cycle to finish: a
  ## CGB pipeline store part way through the dots, then the boundary work.
  when CGB_WRITE_LATENCY_ANY:
    if mem.pipe_reg != 0: mem_tick_ppu_latched(mem, gb)
    else:                 mem_tick_ppu(mem, gb, 4)
  else:
    mem_tick_ppu(mem, gb, 4)
  mem_flush_deferred(mem, gb)

proc mem_write*(mem: GbMemory; gb: GB; idx: int; val: uint8) {.hot_bus_inline.} =
  ## A CPU write commits at the START of its M-cycle, before its PPU dots: the
  ## VRAM/OAM lock is decided on the mode at the start of the M-cycle
  ## (cpu_vram_open), and data landing after the dots sat one M-cycle behind
  ## its own lock (M3_PIPE_MCYCLES in fifo_ppu). Reads are not reordered;
  ## their sample point is the read_mode latch. The bus half runs first
  ## because dma_busy selects the write path.
  when HDMA_STEAL_LEAD_DOTS >= 0:
    mem_tick_bus(mem, gb, 4, defer_hdma = HDMA_WRITE_DEFER_LO <= idx and
                                          idx <= HDMA_WRITE_DEFER_HI)
  else:
    mem_tick_bus(mem, gb, 4)
  if mem.dma_busy:
    mem_write_busy(mem, gb, idx, val)
  else:
    mem_write_open(mem, gb, idx, val)
  when HDMA_STEAL_LEAD_DOTS >= 0:
    # An owed HBlank block takes the bus after the byte (see mem_tick_bus).
    if unlikely(gb.ppu.hdma_block_due) and
       HDMA_WRITE_DEFER_LO <= idx and idx <= HDMA_WRITE_DEFER_HI and
       gb.ppu.cycle_counter >= gb.ppu.hdma_due_deadline:
      mem_land_hdma_due(mem, gb)
  # One flag covers everything that lands later than the byte (pipeline
  # store, STAT-line edge), so the common path pays a single test.
  if mem.write_deferred: mem_write_tail(mem, gb)
  else:                  mem_tick_ppu(mem, gb, 4)

proc mem_read_word*(mem: GbMemory; gb: GB; idx: int): uint16 =
  # A word access at $FFFF wraps to $0000 for its second byte (gambatte
  # oamdma/oamdma_src*_busypopFFFF, busypush0001).
  uint16(mem_read(mem, gb, idx)) or
    (uint16(mem_read(mem, gb, (idx + 1) and 0xFFFF)) shl 8)

proc mem_write_word*(mem: GbMemory; gb: GB; idx: int; val: uint16) =
  mem_write(mem, gb, (idx + 1) and 0xFFFF, uint8(val shr 8))
  mem_write(mem, gb, idx,                  uint8(val and 0xFF))

proc mem_vdma_bus_capture*(mem: GbMemory; gb: GB; src_lo: uint8; val: uint8) =
  ## The OAM DMA unit's write port driven by a VRAM DMA: an in-flight OAM
  ## transfer stores whatever the external bus carries, and under a VRAM DMA
  ## that is a block byte at the block's SOURCE address. Called from the block
  ## copy, not mem_dma_tick, because it is not clocked by the OAM DMA's own bus
  ## cycles (gambatte dma/hdma_transition_oamdma_1 HALTs across the block).
  ## Past $A0 there is no port to drive (oamdma/oamdmasrcC000_hdmasrc0000).
  ## See VDMA_OAM_BUS_CAPTURE in gb.nim.
  if mem.dma_position <= 0xA0 and src_lo < 0xA0'u8:
    mem.dma_latch = val
    write_byte(mem, gb, 0xFE00 + int(src_lo), val)

proc mem_dma_tick*(mem: GbMemory; gb: GB; cycles: int) =
  # Idle exit: neither flag can be set inside the loop (~8-12% of a profile).
  if not mem.requested_oam_dma and mem.dma_position > 0xA0: return
  when OAMDMA_HALT_PAUSE != 0:
    var cycles = cycles
    # The unit is clocked by bus cycles and HALT stops them. The wake M-cycle
    # is the hand-back and does clock it; added here because that M-cycle's
    # bus half runs with `halted` still set (OAMDMA_HALT_PAUSE).
    if gb.cpu.halted:
      # A VRAM DMA makes bus cycles of its own, so the unit keeps stepping
      # (storing nothing; VDMA_OAM_BUS_CAPTURE). `dma_was_halted` stays set
      # so the wake still pays the hand-back.
      if VDMA_OAM_BUS_CAPTURE == 0 or not mem.vdma_bus_hold:
        mem.dma_was_halted = true
        return
    elif mem.dma_was_halted:
      mem.dma_was_halted = false
      when OAMDMA_HALT_PAUSE == 1: cycles += 4
      when OAMDMA_HALT_PAUSE == 3: return
  for _ in 0 ..< cycles:
    if mem.requested_oam_dma:
      inc mem.next_dma_counter
      if mem.next_dma_counter == (when CGB_OAM_DMA_START_T != 8:
                                    (if console_is_cgb(gb): CGB_OAM_DMA_START_T
                                     else: 8)
                                  else: 8):
        when defined(gb_dma_trace):
          if gb.fifo_ppu != nil:
            echo "DMASTART ly=", gb.fifo_ppu.ly,
                 " dot=", gb.fifo_ppu.cycle_counter,
                 " src=", toHex(uint16(mem.dma) shl 8, 4)
        when OAM_SCAN_DMA_LOCK != 0:
          # The transfer takes OAM on this dot; a running mode-2 scan reads
          # nothing more until it is given back.
          if gb.fifo_ppu != nil:
            fifo_oam_lock_change(gb.fifo_ppu, gb, taking = true)
        mem.requested_oam_dma  = false
        mem.current_dma_source = uint16(mem.dma) shl 8
        mem.dma_position       = 0
        mem.internal_dma_timer = 0
        mem.dma_busy           = false
        # The bus is fixed for the whole transfer; classify the source once.
        let raw_src = int(mem.current_dma_source)
        if raw_src >= 0xE000 and console_is_cgb(gb):
          # On CGB a source at or above $E000 goes out on the external bus
          # where nothing answers: every byte is open bus.
          mem.dma_bus     = uint8(dbExternal)
          mem.dma_drive   = DriveTristate
          mem.dma_openbus = true
        else:
          # DMG: sources at or above $E000 fetch through the echo (mooneye
          # oam_dma/sources-GS).
          var bus_src = raw_src
          if bus_src >= 0xE000: bus_src = bus_src and not 0x2000
          mem.dma_bus     = dma_bus_of(gb, bus_src)
          mem.dma_drive   = dma_drive_of(gb, bus_src)
          mem.dma_openbus = false
    if mem.dma_position <= 0xA0:
      if (mem.internal_dma_timer and 3) == 0:
        if mem.dma_position < 0xA0:
          # Under a VRAM DMA the slot passes and the position steps, but the
          # lines are the VRAM DMA's, so nothing lands here
          # (mem_vdma_bus_capture, VDMA_OAM_BUS_CAPTURE).
          if VDMA_OAM_BUS_CAPTURE == 0 or not mem.vdma_bus_hold:
            # The latch is what a colliding CPU read sees. The echo covers
            # $E000-$FFFF (mooneye oam_dma/sources-GS).
            if mem.dma_openbus:
              mem.dma_latch = 0xFF'u8
            else:
              var src = int(mem.current_dma_source) + mem.dma_position
              if src >= 0xE000: src = src and not 0x2000
              mem.dma_latch = read_byte(mem, gb, src)
            write_byte(mem, gb, 0xFE00 + mem.dma_position, mem.dma_latch)
        inc mem.dma_position
        when OAM_SCAN_DMA_LOCK != 0:
          if mem.dma_position > 0xA0 and mem.dma_busy and gb.fifo_ppu != nil:
            # The transfer gives OAM back on this dot.
            fifo_oam_lock_change(gb.fifo_ppu, gb, taking = false)
        mem.dma_busy = mem.dma_position <= 0xA0
      inc mem.internal_dma_timer

const SPEED_SWITCH_FREEZES_OAM_DMA* {.intdefine.} = 1
  ## The OAM DMA unit does not step through a speed-switch stall: it is
  ## clocked by bus cycles and there are none while the CPU clock is off (as
  ## at HALT, OAMDMA_HALT_PAUSE). The timer is a separate domain and keeps
  ## counting. gambatte oamdma/oamdmasrcC0_speedchange_readC000 and
  ## dma/hdma_transition_speedchange_oamdma.
const SPEED_SWITCH_OAM_DMA_HANDBACK_T* {.intdefine.} = 4
  ## Bus cycles the unit is still clocked for across the stall: the hand-back
  ## M-cycle, the one OAMDMA_HALT_PAUSE charges at a HALT wake. 4 and 8 each
  ## satisfy one of the two rows above; 4 is the HALT path's value.
const SPEED_SWITCH_STALL_T* {.intdefine.} = 65548
  ## The speed-switch stall in T-cycles of the 4.194304 MHz base clock (real
  ## time). Superseded by SPEED_SWITCH_STALL_CPU when that is nonzero (shipping).

const SPEED_SWITCH_STALL_CPU* {.intdefine.} = 131072
  ## The stall in cycles of the CPU clock at the speed switched TO; nonzero
  ## replaces SPEED_SWITCH_STALL_T. 2^17: gambatte speedchange_tima00_* count
  ## +128 TIMA ticks at TAC=$04 across one switch; speedchange2_tima00_* show
  ## the to-single switch costs the same count of a half-rate clock (twice the
  ## real time); speedchange2_*_ly_1 wants the two directions' dots added.
  ## Pan Docs ("FF4D — KEY1") says 2050 M-cycles; these rows measure 2^17.

const SPEED_SWITCH_PPU_EXTRA_DOTS* {.intdefine.} = 12 - 4 * CGB_HALT_PPU_LEAD
  ## Dots the PPU advances across the stall beyond the CPU clock's own count.
  ## daid speed_switch_timing_ly/_stat pin 65548 PPU dots across a to-double
  ## switch (65536 + 12) while _div pins the CPU stall to a multiple of 256.
  ## Those ROMs each HALT once before the STOP, so the 12 is 8 for the switch
  ## plus the halt-exit M-cycle CGB_HALT_PPU_LEAD (gb.nim) owns; the gambatte
  ## speedchange*_ly44_m3* switch-count ladder, which never halts, measures
  ## 8 alone. Tied to the lead so the two move together.

const SS_EXTRA_SINGLE_SAME* = -9999
  ## Sentinel for SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE, outside any legal dot
  ## count so the constant can take a negative value.

const SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE* {.intdefine.} =
  when CGB_HALT_PPU_LEAD != 0: 3 else: SS_EXTRA_SINGLE_SAME
  ## The same quantity for a switch ending in SINGLE speed; the sentinel means
  ## "use SPEED_SWITCH_PPU_EXTRA_DOTS for both", which ships because the split
  ## needs CGB_HALT_PPU_LEAD. The ly44_m3 ladder's rungs measure A, A+B, 2A+B,
  ## 2A+2B, 3A+2B = 8, 11, 19, 22, 30 dots, so A = 8, B = 3. B odd means a
  ## to-single switch leaves the PPU grid 3 dots from the CPU's; gambatte
  ## lcd_offset wants A+B = 0 mod 4 and is the open residual.

const SPEED_SWITCH_STALL_RUNS_CPU_CLOCK* {.intdefine.} = 1
  ## Whether the timer/serial/OAM-DMA domain runs during the stall. It does:
  ## gambatte speedchange_tima00_* see +128 TIMA ticks across a switch. Pan
  ## Docs' "DIV does not tick" is about the STOP leaves; the switch leaf is a
  ## HALT (Pan Docs' STOP chart) and everything that runs in a halt runs here.
  ## DIV is still reset at the switch, before the stall.

proc mem_tick_stalled(mem: GbMemory; gb: GB; cycles: int;
                      first_chunk = true) =
  ## mem_tick_components for the speed-switch stall: no fetch, the CPU-clock
  ## domain per SPEED_SWITCH_STALL_RUNS_CPU_CLOCK, and the PPU at its
  ## real-time rate (gambatte speedchange/*_m3_*).
  gb.scheduler.tick(cycles)
  when SPEED_SWITCH_STALL_RUNS_CPU_CLOCK != 0:
    timer_tick(gb.timer, gb, cycles)
    when SPEED_SWITCH_FREEZES_OAM_DMA == 0:
      mem_dma_tick(mem, gb, cycles)
    elif SPEED_SWITCH_OAM_DMA_HANDBACK_T != 0:
      # Once per stall, not per chunk: the hand-back is at the grant.
      if first_chunk: mem_dma_tick(mem, gb, SPEED_SWITCH_OAM_DMA_HANDBACK_T)
  # `current_speed` is already the speed switched TO: 1 = ended in double.
  const extra_single =
    when SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE != SS_EXTRA_SINGLE_SAME:
      SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE
    else: SPEED_SWITCH_PPU_EXTRA_DOTS
  let extra =
    if not first_chunk: 0
    elif mem.current_speed == 1: SPEED_SWITCH_PPU_EXTRA_DOTS else: extra_single
  let ppu_cycles = (cycles shr mem.current_speed) + extra
  if gb.fifo_ppu != nil: fifo_tick(gb.fifo_ppu, gb, ppu_cycles)
  else: gb.ppu.tick(gb, ppu_cycles)
  when CGB_LYC_EDGE_DEFER and CGB_LYC_EDGE_POLL:
    # As in mem_tick_ppu.
    if unlikely(mem.lyc_edge_owed):
      mem.lyc_edge_owed = false
      ppu_handle_stat_interrupt(gb.ppu, gb)


const SPEED_SWITCH_STALL_ENDS_ON_IRQ* {.intdefine.} = 1
  ## An interrupt arriving during the stall ends it, as it ends any HALT.
  ## c-sp speed-switch/caution/spsw-interrupts-*: a 262 kHz timer overflowing
  ## mid-stall reads DIV = $10 on hardware, which a stall that runs to
  ## completion (2^17 cycles, 16-bit divider) can only answer as $00.
proc mem_stall_until_irq(mem: GbMemory; gb: GB; stall_cycles: int): int =
  ## The stall in M-cycle steps, stopping as soon as an interrupt is ready;
  ## only the first step carries the once-per-stall work.
  const step = 4
  # IE = 0 cannot wake, so the whole stall is one call (most games switch
  # with IE = 0, and 2^17 cycles is 32768 steps).
  let irq = gb.interrupts
  if not (irq.vblank_enabled or irq.lcd_stat_enabled or irq.timer_enabled or
          irq.serial_enabled or irq.joypad_enabled):
    mem_tick_stalled(mem, gb, stall_cycles)
    return stall_cycles
  var done = 0
  while done < stall_cycles:
    let n = min(step, stall_cycles - done)
    mem_tick_stalled(mem, gb, n, first_chunk = done == 0)
    done += n
    if interrupt_ready(gb.interrupts): break
  done

proc mem_tick_stopped*(mem: GbMemory; gb: GB) =
  ## One step in STOP mode: the whole machine clock is stopped (Pan Docs,
  ## "Using the STOP Instruction"), so nothing ticks. This only paces the
  ## frontend: step_frame waits for `frame`, which a frozen PPU never sets.
  let ppu = gb.ppu
  ppu.dots_since_frame += int32(4 shr mem.current_speed)
  if ppu.dots_since_frame >= DOTS_PER_FRAME:
    ppu.dots_since_frame = 0
    ppu.frame = true

proc stop_panel(mem: GbMemory; gb: GB) =
  ## The panel during STOP (Pan Docs, "Using the STOP Instruction"; daid
  ## stop_instr.gb, stop_instr_gbc_mode3.gb): DMG blanks white; CGB with the
  ## LCD on shows black, except in mode 3, where the current image holds. The
  ## mode is sampled on the STOP fetch, which is what the mode-3 ROM aims at.
  let ppu = gb.ppu
  if not ppu.lcd_enabled or not gb.cgb_enabled:
    ppu_blank_frame(ppu, gb)
  elif ppu.mode_flag != 3:
    for i in 0 ..< ppu.framebuffer.len: ppu.framebuffer[i] = 0'u16
    ppu.frame = true
    ppu.dots_since_frame = 0

proc stop_instr*(mem: GbMemory; gb: GB): bool =
  ## STOP ($10). Returns whether the byte after the opcode is consumed. Pan
  ## Docs' STOP flow chart ("Reducing Power Consumption", imgs/stop_diagram.svg)
  ## over what is sampled at the fetch:
  ##
  ##   button held ─ IRQ pending → 1 byte, mode unchanged, DIV not reset
  ##               └ no IRQ      → 2 bytes, HALT mode,     DIV not reset
  ##   no button ─ no switch ─ IRQ pending → 1 byte,  STOP mode, DIV reset
  ##             │            └ no IRQ     → 2 bytes, STOP mode, DIV reset
  ##             └ switch ─ no IRQ      → 2 bytes, HALT mode, DIV reset, speed changes
  ##                      └ IRQ pending → 1 byte, mode unchanged, DIV reset, speed changes
  ##
  ## A held button beats a requested switch, so it is tested first. The
  ## chart's IME split on the last leaf ("glitches non-deterministically")
  ## takes the defined leaf. Not modelled: whether the skipped byte is read,
  ## and an oscillator restart delay on leaving STOP mode.
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
    when HDMA_SPEEDSWITCH_KILL_W != 0:
      # Armed only while a transfer exists to lose (HDMA_SPEEDSWITCH_KILL_W).
      if gb.ppu.hdma_active: gb.ppu.hdma_kill_from = gb.ppu.cycle_counter
    # Pan Docs' chart: the switch resets DIV. Through the timer's own entry
    # point so the divider's consumers (frame sequencer, serial, TIMA edge)
    # see it as a write, at the old speed; where in the opcode it lands is
    # SPEED_SWITCH_DIV_RESET_T in timer.nim.
    timer_speed_switch_div_reset(gb.timer, gb)
    let old_speed = mem.current_speed
    mem.current_speed = mem.current_speed xor 1
    # The channels' next_step deadlines live outside the scheduler's events.
    gb.apu.apu_rescale_speed(gb, old_speed, mem.current_speed)
    gb.scheduler.`speed_mode=`(mem.current_speed)
    # Re-aim the DIV-APU edge at the NEW speed: the aim above went through
    # `speed_mode=`'s rescale, which would also scale the tap's lag
    # (APU_SPSW_TAP_LAG_T in timer.nim).
    gb.scheduler.clear(etAPUFrameSeq)
    gb.scheduler.schedule(apu_div_phase(gb.timer, gb), etAPUFrameSeq)
    # The switch leaf's HALT with its countdown; skipped when an interrupt is
    # already pending (the chart's "1 byte, mode doesn't change" leaf).
    when SPEED_SWITCH_IRQ_LEAF_HOLD_T != 0:
      if irq_pending:
        # Oscillator restart on the aborted-halt leaf: the divider owes these
        # T-cycles (SPEED_SWITCH_IRQ_LEAF_HOLD_T).
        let hold =
          if gb.quirks.spsw_irq_leaf_hold_short: SPEED_SWITCH_IRQ_LEAF_HOLD_T div 2
          else: SPEED_SWITCH_IRQ_LEAF_HOLD_T
        gb.timer.hold_t = hold
    if not irq_pending:
      # In cycles of the CPU clock the switch lands in, the scheduler's domain.
      let stall_cycles =
        when SPEED_SWITCH_STALL_CPU != 0: SPEED_SWITCH_STALL_CPU
        else: SPEED_SWITCH_STALL_T shl mem.current_speed
      var spent = stall_cycles
      when SPEED_SWITCH_STALL_RUNS_CPU_CLOCK != 0:
        # The divider runs, so the DIV-APU event needs no lifting.
        when SPEED_SWITCH_STALL_ENDS_ON_IRQ != 0:
          spent = mem_stall_until_irq(mem, gb, stall_cycles)
        else:
          mem_tick_stalled(mem, gb, stall_cycles)
      else:
        # The DIV-APU event models the frozen divider's tap: lift it over the
        # stall and re-aim it from the reset divider.
        gb.scheduler.clear(etAPUFrameSeq)
        mem_tick_stalled(mem, gb, stall_cycles)
        gb.scheduler.schedule(apu_div_phase(gb.timer, gb), etAPUFrameSeq)
      # Charge the stall to the instruction so mem_tick_extra does not repeat it.
      mem.cycle_tick_count += spent
    return

  # The two STOP-mode leaves: DIV reset through the FF04 write path.
  timer_write(gb.timer, gb, 0xFF04, 0)
  # `halted` + `locked` is cpu_lock's pair (no interrupt ends this); `stopped`
  # says the rest of the machine is stopped too and a P10-P13 line going low
  # does end it (cpu.nim tick).
  gb.cpu.halted  = true
  gb.cpu.locked  = true
  gb.cpu.stopped = true
  stop_panel(mem, gb)
