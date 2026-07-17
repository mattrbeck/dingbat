# GB Memory bus (included by gb.nim)

proc cgb_native*(gb: GB): bool =
  ## True when the CGB-only half of the IO map is exposed. A DMG cart on CGB
  ## hardware runs in DMG-compatibility mode where KEY1/HDMA/SVBK/BCPD/OCPD/
  ## FF74 read as unmapped (mooneye misc/bits/unused_hwio-C); the boot ROM
  ## itself always runs native (it switches modes at handoff via KEY0).
  gb.cgb_enabled and (gb.cgb_flag != cgbNone or gb.memory.bootrom.len > 0)

proc new_gb_memory*(gb: GB): GbMemory =
  result = GbMemory(wram_bank: 1, dma_position: 0xA1)
  for i in 0 ..< 8:
    result.wram[i] = newSeq[uint8](0x1000)
  result.bootrom = @[]
  if gb.bootrom_path.len > 0 and gb.run_bios and fileExists(gb.bootrom_path):
    let raw = readFile(gb.bootrom_path)
    result.bootrom = newSeq[uint8](raw.len)
    for i in 0 ..< raw.len: result.bootrom[i] = uint8(raw[i])

proc skip_boot*(mem: GbMemory; gb: GB) =
  mem.bootrom = @[]
  # Initial APU/PPU register state after boot ROM
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
  mem.write_byte(gb, 0xFF26, 0xF1)
  mem.write_byte(gb, 0xFF40, 0x91)
  mem.write_byte(gb, 0xFF42, 0x00)
  mem.write_byte(gb, 0xFF43, 0x00)
  mem.write_byte(gb, 0xFF45, 0x00)
  mem.write_byte(gb, 0xFF47, 0xFC)
  mem.write_byte(gb, 0xFF48, 0xFF)
  mem.write_byte(gb, 0xFF49, 0xFF)
  mem.write_byte(gb, 0xFF4A, 0x00)
  mem.write_byte(gb, 0xFF4B, 0x00)
  mem.write_byte(gb, 0xFFFF, 0x00)

proc mem_tick_components*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true; ignore_speed = false) =
  if from_cpu: mem.cycle_tick_count += cycles
  gb.scheduler.tick(cycles)
  let ppu_cycles = if ignore_speed: cycles else: cycles shr mem.current_speed
  gb.ppu.tick(gb, ppu_cycles)
  timer_tick(gb.timer, gb, cycles)
  mem_dma_tick(mem, gb, cycles)

proc mem_reset_cycle_count*(mem: GbMemory) =
  mem.cycle_tick_count = 0

proc mem_tick_extra*(mem: GbMemory; gb: GB; total_expected: int) =
  let remaining = total_expected - mem.cycle_tick_count
  if remaining > 0: mem_tick_components(mem, gb, remaining)
  mem_reset_cycle_count(mem)

proc read_byte*(mem: GbMemory; gb: GB; idx: int): uint8 =
  if mem.bootrom.len > 0 and (idx < 0x100 or (idx >= 0x200 and idx < 0x900)):
    return mem.bootrom[idx]
  case idx
  of 0x0000..0x3FFF: mbc_read(gb.cartridge, idx)
  of 0x4000..0x7FFF: mbc_read(gb.cartridge, idx)
  of 0x8000..0x9FFF: ppu_read(gb.ppu, gb, idx)
  of 0xA000..0xBFFF: mbc_read(gb.cartridge, idx)
  of 0xC000..0xCFFF: mem.wram[0][idx - 0xC000]
  of 0xD000..0xDFFF: mem.wram[mem.wram_bank][idx - 0xD000]
  of 0xE000..0xFDFF: read_byte(mem, gb, idx - 0x2000)
  of 0xFE00..0xFE9F: ppu_read(gb.ppu, gb, idx)
  of 0xFEA0..0xFEFF: 0x00'u8
  of 0xFF00:         joypad_read(gb.joypad)
  of 0xFF01..0xFF02: serial_read(gb.serial, gb, idx)
  of 0xFF04..0xFF07: timer_read(gb.timer, idx)
  of 0xFF0F:         irq_read(gb.interrupts, idx)
  of 0xFF10..0xFF3F: apu_read(gb.apu, idx)
  of 0xFF40..0xFF4B: ppu_read(gb.ppu, gb, idx)
  of 0xFF4D:
    if gb.cgb_native:
      0x7E'u8 or (uint8(mem.current_speed) shl 7) or (if mem.requested_speed_switch: 1'u8 else: 0'u8)
    else: 0xFF'u8
  of 0xFF4F:         ppu_read(gb.ppu, gb, idx)
  of 0xFF51..0xFF55: ppu_read(gb.ppu, gb, idx)
  of 0xFF68..0xFF6B: ppu_read(gb.ppu, gb, idx)
  of 0xFF70:
    if gb.cgb_native: 0xF8'u8 or mem.wram_bank else: 0xFF'u8
  of 0xFF72: mem.ff72
  of 0xFF73: mem.ff73
  of 0xFF74:
    if gb.cgb_native: mem.ff74 else: 0xFF'u8
  of 0xFF75: mem.ff75
  of 0xFF76: 0x00'u8
  of 0xFF77: 0x00'u8
  of 0xFF80..0xFFFE: mem.hram[idx - 0xFF80]
  of 0xFFFF:         irq_read(gb.interrupts, idx)
  else: 0xFF'u8

proc mem_read*(mem: GbMemory; gb: GB; idx: int): uint8 =
  mem_tick_components(mem, gb, 4)
  if (mem.dma_position > 0 and mem.dma_position <= 0xA0) and
     (idx >= 0xFE00 and idx <= 0xFE9F):
    return 0xFF'u8
  read_byte(mem, gb, idx)

proc mem_dma_transfer*(mem: GbMemory; source: uint8) =
  mem.dma         = source
  mem.requested_oam_dma = true
  mem.next_dma_counter  = 0

proc write_byte*(mem: GbMemory; gb: GB; idx: int; val: uint8) =
  if idx == 0xFF50 and val == 0x11:
    mem.bootrom = @[]
    gb.cgb_enabled = gb.cgb_flag != cgbNone
  case idx
  of 0x0000..0x7FFF: mbc_write(gb.cartridge, idx, val)
  of 0x8000..0x9FFF: ppu_write(gb.ppu, gb, idx, val)
  of 0xA000..0xBFFF: mbc_write(gb.cartridge, idx, val)
  of 0xC000..0xCFFF: mem.wram[0][idx - 0xC000] = val
  of 0xD000..0xDFFF: mem.wram[mem.wram_bank][idx - 0xD000] = val
  of 0xE000..0xFDFF: write_byte(mem, gb, idx - 0x2000, val)
  of 0xFE00..0xFE9F: ppu_write(gb.ppu, gb, idx, val)
  of 0xFEA0..0xFEFF: discard
  of 0xFF00:         joypad_write(gb.joypad, val)
  of 0xFF01..0xFF02: serial_write(gb.serial, gb, idx, val)
  of 0xFF04..0xFF07: timer_write(gb.timer, gb, idx, val)
  of 0xFF0F:         irq_write(gb.interrupts, idx, val)
  of 0xFF10..0xFF3F: apu_write(gb.apu, idx, val, gb)
  of 0xFF46:         mem_dma_transfer(mem, val)
  of 0xFF40..0xFF45, 0xFF47..0xFF4B: ppu_write(gb.ppu, gb, idx, val)
  of 0xFF4D:
    if gb.cgb_native: mem.requested_speed_switch = (val and 0x1) != 0
  of 0xFF4F:         ppu_write(gb.ppu, gb, idx, val)
  of 0xFF51..0xFF55: ppu_write(gb.ppu, gb, idx, val)
  of 0xFF68..0xFF6B: ppu_write(gb.ppu, gb, idx, val)
  of 0xFF70:
    if gb.cgb_native:
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

proc mem_write*(mem: GbMemory; gb: GB; idx: int; val: uint8) =
  mem_tick_components(mem, gb, 4)
  if (mem.dma_position > 0 and mem.dma_position <= 0xA0) and
     (idx >= 0xFE00 and idx <= 0xFE9F):
    return
  write_byte(mem, gb, idx, val)

proc mem_read_word*(mem: GbMemory; gb: GB; idx: int): uint16 =
  uint16(mem_read(mem, gb, idx)) or (uint16(mem_read(mem, gb, idx + 1)) shl 8)

proc mem_write_word*(mem: GbMemory; gb: GB; idx: int; val: uint16) =
  mem_write(mem, gb, idx + 1, uint8(val shr 8))
  mem_write(mem, gb, idx,     uint8(val and 0xFF))

proc mem_dma_tick*(mem: GbMemory; gb: GB; cycles: int) =
  for _ in 0 ..< cycles:
    if mem.requested_oam_dma:
      inc mem.next_dma_counter
      if mem.next_dma_counter == 8:
        mem.requested_oam_dma  = false
        mem.current_dma_source = uint16(mem.dma) shl 8
        mem.dma_position       = 0
        mem.internal_dma_timer = 0
    if mem.dma_position <= 0xA0:
      if (mem.internal_dma_timer and 3) == 0:
        if mem.dma_position < 0xA0:
          write_byte(mem, gb,
            0xFE00 + mem.dma_position,
            read_byte(mem, gb, int(mem.current_dma_source) + mem.dma_position))
        inc mem.dma_position
      inc mem.internal_dma_timer

proc stop_instr*(mem: GbMemory; gb: GB) =
  if mem.requested_speed_switch and gb.cgb_enabled:
    mem.requested_speed_switch = false
    mem.current_speed = mem.current_speed xor 1
    gb.scheduler.`speed_mode=`(mem.current_speed)
