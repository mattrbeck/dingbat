# ARM instruction handlers (included by gba.nim)

proc mul32(a, b: int32): int32 {.inline.} =
  ## Wrapping 32-bit multiply matching ARM `mul` instruction (low 32 bits).
  cast[int32](cast[uint32](cast[int64](a) * cast[int64](b)))

proc bios_arctan(cpu: CPU) =
  ## GBA BIOS ArcTan (SWI 0x09) polynomial approximation.
  ## Matches the real BIOS: 32-bit wrapping arithmetic, ASR shifts.
  ## Input:  r0 = tan value in 1.14 fixed-point (signed).
  ## Output: r0 = arctan result (0x4000 = pi/2),
  ##         r1 = -(input^2 >> 14),  r3 = polynomial accumulator.
  let a = cast[int32](cpu.r[0])
  var r1 = mul32(a, a)
  r1 = ashr(r1, 14)
  r1 = -r1  # neg_a_sq
  const ARCTAN_COEFFS = [0xA9'i32, 0x0390, 0x091C, 0x0FB6, 0x16AA, 0x2081, 0x3651, 0xA2F9]
  var r3 = mul32(ARCTAN_COEFFS[0], r1)
  r3 = ashr(r3, 14)
  for i in 1 ..< ARCTAN_COEFFS.len - 1:
    r3 = r3 + ARCTAN_COEFFS[i]; r3 = mul32(r3, r1); r3 = ashr(r3, 14)
  r3 = r3 + ARCTAN_COEFFS[^1]
  cpu.r[0] = cast[uint32](ashr(mul32(r3, a), 16))
  cpu.r[1] = cast[uint32](r1)
  cpu.r[3] = cast[uint32](r3)

proc hle_div(cpu: CPU; numer_reg, denom_reg: int) =
  let numer = int64(cast[int32](cpu.r[numer_reg]))
  let denom = int64(cast[int32](cpu.r[denom_reg]))
  # The real BIOS divide loops once per quotient bit; calibrated against the
  # mGBA suite's "BIOS Division" timing tests
  block:
    let n = uint32(abs(numer) and 0xFFFFFFFF)
    let d = uint32(abs(denom) and 0xFFFFFFFF)
    if d != 0:
      let quot_bits = max(0, countLeadingZeroBits(d) - countLeadingZeroBits(max(n, 1'u32)) - 1)
      cpu.idle(19 + quot_bits * 13)
  if denom == 0:
    cpu.r[0] = if numer < 0: 0xFFFFFFFF'u32 else: 1'u32
    cpu.r[1] = uint32(numer and 0xFFFFFFFF)
    cpu.r[3] = 1'u32
  else:
    let quot = numer div denom
    let rem = numer mod denom
    cpu.r[0] = cast[uint32](uint32(quot and 0xFFFFFFFF))
    cpu.r[1] = cast[uint32](uint32(rem and 0xFFFFFFFF))
    cpu.r[3] = uint32(abs(quot) and 0xFFFFFFFF)

# BIOS interrupt flags mirror at 0x03007FF8. User IRQ handlers OR the
# interrupts they service into this halfword; IntrWait consumes it.
proc read_intr_mirror(cpu: CPU): uint16 {.inline.} =
  uint16(cpu.gba.bus.wram_chip[0x7FF8]) or (uint16(cpu.gba.bus.wram_chip[0x7FF9]) shl 8)

proc write_intr_mirror(cpu: CPU; value: uint16) {.inline.} =
  cpu.gba.bus.wram_chip[0x7FF8] = uint8(value)
  cpu.gba.bus.wram_chip[0x7FF9] = uint8(value shr 8)

proc hle_intr_wait(cpu: CPU; discard_old: bool; mask: uint16) =
  ## IntrWait per GBATEK: forcefully sets IME=1, then halts until the user
  ## IRQ handler ORs a masked flag into the BIOS mirror at 0x03007FF8.
  ## With discard_old=false, returns immediately if a masked flag is already
  ## set. Matched mirror flags are acknowledged (cleared) on return.
  cpu.gba.interrupts.ime = true
  let mirror = cpu.read_intr_mirror()
  if discard_old:
    cpu.write_intr_mirror(mirror and not mask)
  else:
    let hit = mirror and mask
    if hit != 0:
      cpu.write_intr_mirror(mirror and not hit)
      return
  cpu.intr_wait_active = true
  cpu.intr_wait_mask = mask
  # Address of the instruction following the SWI (r15 is pipeline-ahead)
  cpu.intr_wait_resume_addr = if cpu.cpsr.thumb: cpu.r[15] - 2 else: cpu.r[15] - 4
  cpu.halted = true
  # Wake immediately if an enabled interrupt is already pending
  cpu.gba.interrupts.schedule_interrupt_check()

proc check_intr_wait*(cpu: CPU) =
  ## Called when execution reaches the instruction after an IntrWait SWI
  ## (i.e. the user IRQ handler has returned). Re-halts unless a requested
  ## flag has appeared in the BIOS interrupt flags mirror.
  let hit = cpu.read_intr_mirror() and cpu.intr_wait_mask
  if hit != 0:
    cpu.write_intr_mirror(cpu.read_intr_mirror() and not hit)
    cpu.intr_wait_active = false
    # The IRQ handler ran through the (stub) BIOS and rewrote the open-bus
    # latch; the real BIOS's IntrWait exit path leaves 0xE3A02004
    cpu.gba.bus.bios_latch = 0xE3A02004'u32
    # Cost of the real BIOS's wake path (mirror check, register restore,
    # return to caller). Keeps code after IntrWait phase-aligned with the
    # free-running timer prescaler (mGBA suite Timer count-up tests).
    # 44 = exactly what the real BIOS executes from the IRQ handler's return
    # to the caller's first instruction: bl 0x358 (3) + flag check/ack
    # subroutine (15) + beq not taken (1) + pop {r4,lr} (4) + bx lr (3) +
    # dispatcher restore 0x170-0x184 (12) + movs pc, lr (3+refill 2, IWRAM)
    cpu.gba.bus.add_cycles(44)  # INTRWAIT_TUNE
  else:
    cpu.halted = true

# Cycle cost of the real BIOS's SWI entry/dispatch/return path (exception
# entry, register saves, jump-table dispatch, return), excluding the
# caller-side pipeline refill which is charged region-dependently below.
# Calibrated against the mGBA suite's BIOS timing tests (IWRAM column).
const SWI_HLE_BASE = 48

# The part of a Halt/Stop SWI the real BIOS executes AFTER the wake IRQ has
# been serviced: bx lr (3) + pop {r2, lr} (4) + mov (1) + msr (1) +
# ldm {fp} (3) + msr SPSR (1) + pop {fp, ip, lr} (5) + movs pc, lr with an
# IWRAM/BIOS-width refill (3). Deferring it keeps post-wake measurements
# (mGBA suite SIO timing tests) aligned with the real-BIOS execution order.
const HALT_RETURN_COST = 21

proc hle_swi*(cpu: CPU; swi_num: uint32) =
  ## HLE BIOS dispatch for the most common GBA SWI calls.
  ## Only used when no real BIOS file is provided.
  cpu.idle(SWI_HLE_BASE)
  # BIOS open-bus latch: the last opcode the real BIOS fetches before
  # returning (GBATEK "Reading from BIOS memory"; the mGBA suite verifies
  # 0xE3A02004 after VBlankIntrWait on hardware)
  cpu.gba.bus.bios_latch = 0xE3A02004'u32
  # The return refills the caller's pipeline: one nonsequential + one
  # sequential fetch in the caller's region
  block:
    let bus = cpu.gba.bus
    let page = int(bits_range(cpu.r[15], 24, 27))
    if cpu.cpsr.thumb:
      bus.add_cycles(int(bus.wait16_n[page]) + int(bus.wait16_s[page]))
    else:
      bus.add_cycles(int(bus.wait32_n[page]) + int(bus.wait32_s[page]))
    # Plus one more sequential halfword slot; the residual every non-IWRAM
    # column showed against hardware (exactly S16 - 1)
    bus.add_cycles(int(bus.wait16_s[page]) - 1)
    # The swi flushed the ROM fetch stream; forget burst/prefetch state
    bus.rom_hot = false
    bus.rom_next_addr = 1  # never matches (halfword-aligned addresses)
    bus.rom_free_since = bus.gba.scheduler.cycles + CycleCount(bus.cycles)
  case swi_num
  of 0x00:  # SoftReset
    let return_flag = cpu.gba.bus.wram_chip[0x7FFA]
    for i in 0x7E00 ..< 0x8000:
      cpu.gba.bus.wram_chip[i] = 0
    # Enter system mode through switch_mode so the live r13/r14 rebank; a
    # direct CPSR write would leave the previous mode's registers active
    cpu.switch_mode(modeSYS)
    cpu.cpsr = cast[PSR](uint32(modeSYS))
    for i in 0 .. 12:
      cpu.r[i] = 0
    cpu.r[13] = 0x03007F00'u32
    cpu.r[14] = 0
    cpu.reg_banks[mode_bank(modeUSR)][5] = 0x03007F00'u32
    cpu.reg_banks[mode_bank(modeIRQ)][5] = 0x03007FA0'u32
    cpu.reg_banks[mode_bank(modeIRQ)][6] = 0
    cpu.reg_banks[mode_bank(modeSVC)][5] = 0x03007FE0'u32
    cpu.reg_banks[mode_bank(modeSVC)][6] = 0
    cpu.intr_wait_active = false
    let reset_addr = if return_flag == 0: 0x08000000'u32 else: 0x02000000'u32
    discard cpu.set_reg(15, reset_addr)
  of 0x02:  # Halt
    # Move the BIOS's post-wake return cost out of the upfront charge and
    # onto the resume boundary (see HALT_RETURN_COST)
    cpu.gba.bus.add_cycles(-HALT_RETURN_COST)
    cpu.halt_resume_charge = HALT_RETURN_COST
    cpu.halt_resume_addr = if cpu.cpsr.thumb: cpu.r[15] - 2 else: cpu.r[15] - 4
    cpu.halted = true
    # Halt exits when IE & IF is nonzero (IME is don't care), including
    # interrupts that were already pending on entry
    cpu.gba.interrupts.schedule_interrupt_check()
  of 0x03:  # Stop
    # Peripherals keep running (hardware stops sound/video/timers), but the
    # wake sources are faithful: only keypad/cartridge/SIO interrupts
    cpu.gba.bus.add_cycles(-HALT_RETURN_COST)
    cpu.halt_resume_charge = HALT_RETURN_COST
    cpu.halt_resume_addr = if cpu.cpsr.thumb: cpu.r[15] - 2 else: cpu.r[15] - 4
    cpu.halted = true
    cpu.stopped = true
    # Stop blanks the LCD without any memory write; force a re-render
    cpu.gba.ppu.render_dirty = true
    cpu.gba.interrupts.schedule_interrupt_check()
  of 0x06: hle_div(cpu, 0, 1)  # Div
  of 0x07: hle_div(cpu, 1, 0)  # DivArm (swapped inputs)
  of 0x04:  # IntrWait(discard_flags, intr_flags)
    cpu.hle_intr_wait(cpu.r[0] != 0, uint16(cpu.r[1]))
  of 0x05:  # VBlankIntrWait = IntrWait(1, 1)
    cpu.hle_intr_wait(true, 1'u16)
  of 0x08:  # Sqrt
    # Input-dependent cost of the real BIOS routine. The hardware algorithm
    # is unknown (the bundled replacement BIOS uses a different one), so this
    # is a monotone piecewise-linear fit through the mGBA suite's three
    # "BIOS Sqrt" timing datapoints (inputs 0, 0xFF, 0x12345678).
    block:
      let b = 32 - countLeadingZeroBits(max(cpu.r[0], 1'u32))
      let extra = if cpu.r[0] == 0: 48
                  elif b <= 8: 48 + (115 * b + 4) div 8
                  else: 163 + (916 * (b - 8) + 10) div 21
      cpu.idle(extra)
    let val = cpu.r[0]
    if val == 0:
      cpu.r[0] = 0
    else:
      var result_val: uint32 = 0
      var bit_val: uint32 = 1'u32 shl 30
      var num = val
      while bit_val > num:
        bit_val = bit_val shr 2
      while bit_val != 0:
        if num >= result_val + bit_val:
          num -= result_val + bit_val
          result_val = (result_val shr 1) + bit_val
        else:
          result_val = result_val shr 1
        bit_val = bit_val shr 2
      cpu.r[0] = result_val
  of 0x09:  # ArcTan
    cpu.idle(48)  # fixed-iteration polynomial in the real BIOS
    bios_arctan(cpu)
  of 0x0A:  # ArcTan2
    ## Matches real BIOS: full 32-bit signed inputs, same branching logic.
    let x = cast[int32](cpu.r[0])
    let y = cast[int32](cpu.r[1])
    if y == 0:
      if x >= 0:
        cpu.r[0] = 0
      else:
        cpu.r[0] = 0x8000'u32
    elif x == 0:
      if y >= 0:
        cpu.r[0] = 0x4000'u32
      else:
        cpu.r[0] = 0xC000'u32
    else:
      if y > 0:
        if x > 0:
          if x >= y:
            cpu.r[0] = cast[uint32]((int64(y) shl 14) div int64(x))
            bios_arctan(cpu)
          else:
            cpu.r[0] = cast[uint32]((int64(x) shl 14) div int64(y))
            bios_arctan(cpu)
            cpu.r[0] = 0x4000'u32 - cpu.r[0]
        else: # x < 0
          if -x >= y:
            cpu.r[0] = cast[uint32]((int64(y) shl 14) div int64(x))
            bios_arctan(cpu)
            cpu.r[0] = cpu.r[0] + 0x8000'u32
          else:
            cpu.r[0] = cast[uint32]((int64(x) shl 14) div int64(y))
            bios_arctan(cpu)
            cpu.r[0] = 0x4000'u32 - cpu.r[0]
      else: # y < 0
        if x > 0:
          if x >= -y:
            cpu.r[0] = cast[uint32]((int64(y) shl 14) div int64(x))
            bios_arctan(cpu)
            cpu.r[0] = cpu.r[0] + 0x10000'u32
          else:
            cpu.r[0] = cast[uint32]((int64(x) shl 14) div int64(y))
            bios_arctan(cpu)
            cpu.r[0] = 0xC000'u32 - cpu.r[0]
        else: # x <= 0
          if -x > -y:
            cpu.r[0] = cast[uint32]((int64(y) shl 14) div int64(x))
            bios_arctan(cpu)
            cpu.r[0] = cpu.r[0] + 0x8000'u32
          else:
            cpu.r[0] = cast[uint32]((int64(x) shl 14) div int64(y))
            bios_arctan(cpu)
            cpu.r[0] = 0xC000'u32 - cpu.r[0]
    cpu.r[3] = 0x170'u32
  of 0x0B:  # CpuSet
    var src = cpu.r[0]
    var dst = cpu.r[1]
    let ctrl = cpu.r[2]
    let count = bits_range(ctrl, 0, 20)
    let fill = bit(ctrl, 24)
    let word_mode = bit(ctrl, 26)
    # Loop overhead of the real BIOS copy loop beyond the bus accesses
    cpu.idle(int(count))
    # Addresses are NOT aligned: normal memory aligns on the bus anyway, and
    # SRAM (8-bit bus) genuinely sees the unaligned byte address. Reads from
    # the protected BIOS/unused region return 0 (hardware-verified by the
    # mGBA suite memory tests).
    let src_protected = bits_range(src, 24, 27) <= 0x1
    if word_mode:
      let fill_val = if src_protected: 0'u32 else: cpu.gba.bus.read_word(src)
      for i in 0'u32 ..< count:
        let val = if fill: fill_val
                  elif src_protected: 0'u32
                  else: cpu.gba.bus.read_word(src)
        cpu.gba.bus.write_word(dst, val)
        if not fill: src += 4
        dst += 4
    else:
      # The real BIOS uses ldrh: an odd source address reads rotated, so the
      # stored halfword is the addressed byte (ldrh+strh; hardware-verified)
      let fill_val = if src_protected: 0'u16
                     else: uint16(cpu.gba.bus.read_half_rotate(src))
      for i in 0'u32 ..< count:
        let val = if fill: fill_val
                  elif src_protected: 0'u16
                  else: uint16(cpu.gba.bus.read_half_rotate(src))
        cpu.gba.bus.write_half(dst, val)
        if not fill: src += 2
        dst += 2
    cpu.r[0] = src
    cpu.r[1] = dst
  of 0x01:  # RegisterRamReset
    let flags = cpu.r[0]
    if bit(flags, 0):  # Clear 256K EWRAM
      for i in 0 ..< 0x40000: cpu.gba.bus.wram_board[i] = 0
    if bit(flags, 1):  # Clear 32K IWRAM (except last 0x200)
      for i in 0 ..< 0x7E00: cpu.gba.bus.wram_chip[i] = 0
    if bit(flags, 2):  # Clear palette
      for i in 0 ..< 0x400: cpu.gba.ppu.pram[i] = 0
    if bit(flags, 3):  # Clear VRAM
      for i in 0 ..< 0x18000: cpu.gba.ppu.vram[i] = 0
    if bit(flags, 4):  # Clear OAM
      for i in 0 ..< 0x400: cpu.gba.ppu.oam[i] = 0
    if bit(flags, 5):  # Reset SIO
      cpu.gba.serial.siocnt = 0
      cpu.gba.serial.rcnt = 0
    if bit(flags, 6):  # Reset sound (0x4000060–0x4000084)
      cpu.gba.scheduler.clear(etAPUChannel1)
      cpu.gba.scheduler.clear(etAPUChannel2)
      cpu.gba.scheduler.clear(etAPUChannel3)
      cpu.gba.scheduler.clear(etAPUChannel4)
      cpu.gba.scheduler.clear(etAPUFrameSeq)
      cpu.gba.scheduler.clear(etAPUSample)
      cpu.gba.apu.sound_enabled = true
      # Real BIOS clears 0x60–0xAF per GBATEK (includes wave RAM at 0x90–0x9F)
      for offset in 0x60'u32..0x84'u32:
        cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
      for offset in 0x90'u32..0x9F'u32:
        cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
      for ch in 0..1:
        for i in 0..31: cpu.gba.apu.dma_channels.fifos[ch][i] = 0
        cpu.gba.apu.dma_channels.positions[ch] = 0
        cpu.gba.apu.dma_channels.sizes[ch]     = 0
        cpu.gba.apu.dma_channels.latches[ch]   = 0
      cpu.gba.apu.soundcnt_h = SOUNDCNT_H()
    if bit(flags, 7):  # Reset all other I/O (except SIO and sound)
      for offset in 0x000'u32..0x05F'u32:
        cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
      for offset in 0x0B0'u32..0x11F'u32:
        cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
      for offset in 0x130'u32..0x133'u32:
        cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
      for offset in 0x15C'u32..0x1FF'u32:
        cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
      # The real BIOS leaves the display in forced blank, not zeroed
      cpu.gba.bus.write_half(0x04000000'u32, 0x0080'u16)
    # Simulate cycle cost with APU events suppressed
    var hle_cycles = 0
    if bit(flags, 0): hle_cycles += 192000
    if bit(flags, 1): hle_cycles += 2000
    if bit(flags, 2): hle_cycles += 500
    if bit(flags, 3): hle_cycles += 48000
    if bit(flags, 4): hle_cycles += 500
    if bit(flags, 5) or bit(flags, 6) or bit(flags, 7): hle_cycles += 5000
    cpu.gba.bus.add_cycles(hle_cycles)
    # Re-schedule APU events after cycle advance
    if bit(flags, 6):
      cpu.gba.apu.tick_frame_sequencer()
      cpu.gba.apu.get_sample()
  of 0x0C:  # CpuFastSet
    var src = cpu.r[0]
    var dst = cpu.r[1]
    let src_protected = bits_range(src, 24, 27) <= 0x1
    let ctrl = cpu.r[2]
    let count = (bits_range(ctrl, 0, 20) + 7) and not 7'u32  # round up to multiple of 8
    # Loop overhead of the real BIOS ldmia/stmia loop beyond the bus accesses
    # (calibrated against the mGBA suite "CpuSet" timing test, which uses
    # swi 0xC despite its name)
    cpu.idle(int(count) + 5)
    let fill = bit(ctrl, 24)
    let fill_val = if src_protected: 0'u32 else: cpu.gba.bus.read_word(src)
    for i in 0'u32 ..< count:
      let val = if fill: fill_val
                elif src_protected: 0'u32
                else: cpu.gba.bus.read_word(src)
      cpu.gba.bus.write_word(dst, val)
      if not fill: src += 4
      dst += 4
    cpu.r[0] = src
    cpu.r[1] = dst
  of 0x0D:  # GetBiosChecksum
    cpu.r[0] = 0xBAAE187F'u32
  of 0x0E:  # BgAffineSet
    var src = cpu.r[0]
    var dst = cpu.r[1]
    let count = cpu.r[2]
    for i in 0'u32 ..< count:
      let center_org_x = cast[int32](cpu.gba.bus.read_word(src))
      let center_org_y = cast[int32](cpu.gba.bus.read_word(src + 4))
      let display_cx = int32(cast[int16](cpu.gba.bus.read_half(src + 8)))
      let display_cy = int32(cast[int16](cpu.gba.bus.read_half(src + 10)))
      let scale_x = cast[int16](cpu.gba.bus.read_half(src + 12))
      let scale_y = cast[int16](cpu.gba.bus.read_half(src + 14))
      let angle = cpu.gba.bus.read_half(src + 16)
      let theta = float64(angle) / 32768.0 * PI
      let cos_t = cos(theta)
      let sin_t = sin(theta)
      let pa = cast[int16](int32(float64(scale_x) * cos_t))
      let pb = cast[int16](int32(-float64(scale_x) * sin_t))
      let pc = cast[int16](int32(float64(scale_y) * sin_t))
      let pd = cast[int16](int32(float64(scale_y) * cos_t))
      let start_x = int32(center_org_x) - (int32(pa) * display_cx + int32(pb) * display_cy)
      let start_y = int32(center_org_y) - (int32(pc) * display_cx + int32(pd) * display_cy)
      cpu.gba.bus.write_half(dst, cast[uint16](pa))
      cpu.gba.bus.write_half(dst + 2, cast[uint16](pb))
      cpu.gba.bus.write_half(dst + 4, cast[uint16](pc))
      cpu.gba.bus.write_half(dst + 6, cast[uint16](pd))
      cpu.gba.bus.write_word(dst + 8, cast[uint32](start_x))
      cpu.gba.bus.write_word(dst + 12, cast[uint32](start_y))
      src += 20
      dst += 16
  of 0x0F:  # ObjAffineSet
    var src = cpu.r[0]
    var dst = cpu.r[1]
    var count = cpu.r[2]
    let dst_stride = cpu.r[3]
    while count > 0:
      let sx = cast[int32](cast[int16](cpu.gba.bus.read_half(src)))
      let sy = cast[int32](cast[int16](cpu.gba.bus.read_half(src + 2)))
      let angle = uint32(cpu.gba.bus.read_half(src + 4))
      src += 8
      # GBA angle: 0x0000..0xFFFF = 0..2*pi
      let theta = float64(angle) / 32768.0 * 3.14159265358979323846
      let cos_val = cast[int16](int32(float64(sx) * cos(theta)))
      let sin_val = cast[int16](int32(float64(sx) * sin(theta)))
      let cos_val_y = cast[int16](int32(float64(sy) * cos(theta)))
      let sin_val_y = cast[int16](int32(float64(sy) * sin(theta)))
      cpu.gba.bus.write_half(dst, uint16(cos_val));             dst += dst_stride  # pa
      cpu.gba.bus.write_half(dst, uint16(cast[uint16](-sin_val))); dst += dst_stride  # pb
      cpu.gba.bus.write_half(dst, uint16(sin_val_y));           dst += dst_stride  # pc
      cpu.gba.bus.write_half(dst, uint16(cos_val_y));           dst += dst_stride  # pd
      count -= 1
  of 0x11:  # LZ77UnCompWram (8-bit writes)
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    var dst = cpu.r[1]
    var remaining = decomp_len
    while remaining > 0:
      let flags = cpu.gba.bus[src]; src += 1
      for i in 0 ..< 8:
        if remaining == 0: break
        if bit(flags, 7 - i):
          # Compressed block
          let b1 = uint32(cpu.gba.bus[src]); src += 1
          let b2 = uint32(cpu.gba.bus[src]); src += 1
          let length = (b1 shr 4) + 3
          let offset = ((b1 and 0xF) shl 8) or b2
          for j in 0'u32 ..< length:
            if remaining == 0: break
            cpu.gba.bus[dst] = cpu.gba.bus[dst - offset - 1]
            dst += 1; remaining -= 1
        else:
          # Uncompressed byte
          cpu.gba.bus[dst] = cpu.gba.bus[src]
          src += 1; dst += 1; remaining -= 1
  of 0x12:  # LZ77UnCompVram (16-bit writes)
    # Decompress into a local buffer first, then copy to VRAM via halfword
    # writes.  Direct VRAM decompression breaks back-references because
    # bytes are buffered into halfwords and not flushed until the second
    # byte arrives — reads of the unflushed byte hit stale VRAM.
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    var buf = newSeq[uint8](decomp_len)
    var buf_pos: uint32 = 0
    while buf_pos < decomp_len:
      let flags = cpu.gba.bus[src]; src += 1
      for i in 0 ..< 8:
        if buf_pos >= decomp_len: break
        if bit(flags, 7 - i):
          let b1 = uint32(cpu.gba.bus[src]); src += 1
          let b2 = uint32(cpu.gba.bus[src]); src += 1
          let length = (b1 shr 4) + 3
          let offset = ((b1 and 0xF) shl 8) or b2
          for j in 0'u32 ..< length:
            if buf_pos >= decomp_len: break
            buf[buf_pos] = buf[buf_pos - offset - 1]
            buf_pos += 1
        else:
          buf[buf_pos] = cpu.gba.bus[src]
          src += 1; buf_pos += 1
    # Write to destination using halfword writes
    var dst = cpu.r[1]
    var idx: uint32 = 0
    while idx < decomp_len:
      if idx + 1 < decomp_len:
        cpu.gba.bus.write_half(dst, uint16(buf[idx]) or (uint16(buf[idx + 1]) shl 8))
        dst += 2; idx += 2
      else:
        cpu.gba.bus.write_half(dst, uint16(buf[idx]))
        dst += 2; idx += 1
  of 0x10:  # BitUnPack
    var src = cpu.r[0]
    var dst = cpu.r[1]
    let info = cpu.r[2]
    let src_len = uint32(cpu.gba.bus.read_half(info))
    let src_width = uint32(cpu.gba.bus[info + 2])
    let dest_width = uint32(cpu.gba.bus[info + 3])
    let data_offset = cpu.gba.bus.read_word(info + 4)
    let offset_val = data_offset and 0x7FFFFFFF'u32
    let zero_flag = bit(data_offset, 31)
    var out_word: uint32 = 0
    var out_bits: uint32 = 0
    let src_mask = (1'u32 shl src_width) - 1
    # dest_width may be 32, where a plain shift would be undefined
    let dest_mask = if dest_width >= 32: 0xFFFFFFFF'u32
                    else: (1'u32 shl dest_width) - 1
    for i in 0'u32 ..< src_len:
      let byte_val = uint32(cpu.gba.bus[src]); src += 1
      var bit_pos: uint32 = 0
      while bit_pos < 8:
        let val = (byte_val shr bit_pos) and src_mask
        var expanded: uint32
        if val != 0 or zero_flag:
          expanded = val + offset_val
        else:
          expanded = 0
        out_word = out_word or ((expanded and dest_mask) shl out_bits)
        out_bits += dest_width
        if out_bits >= 32:
          cpu.gba.bus.write_word(dst, out_word)
          dst += 4
          out_word = 0
          out_bits = 0
        bit_pos += src_width
  of 0x13:  # HuffUnComp
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let data_size = header and 0xF  # 4 or 8 bits
    let decomp_len = header shr 8
    src += 4
    let tree_size = uint32(cpu.gba.bus[src])
    let tree_start = src + 1
    let data_start = src + (tree_size * 2) + 2
    # Align data start to 4-byte boundary
    var data_pos = (data_start + 3) and not 3'u32
    var dst = cpu.r[1]
    var written: uint32 = 0
    var out_word: uint32 = 0
    var out_bits: uint32 = 0
    var cur_node = tree_start
    var cur_word: uint32 = 0
    var bits_left: int = 0
    while written < decomp_len:
      if bits_left == 0:
        cur_word = cpu.gba.bus.read_word(data_pos)
        data_pos += 4
        bits_left = 32
      let cur_bit = (cur_word shr 31) and 1
      cur_word = cur_word shl 1
      bits_left -= 1
      let node_val = uint32(cpu.gba.bus[cur_node])
      let child_offset = node_val and 0x3F
      let right_is_leaf = bit(node_val, 6)
      let left_is_leaf = bit(node_val, 7)
      let next_addr = (cur_node and not 1'u32) + (child_offset + 1) * 2
      let is_right = cur_bit == 1
      let child_addr = next_addr + (if is_right: 1'u32 else: 0'u32)
      let is_leaf = if is_right: right_is_leaf else: left_is_leaf
      if is_leaf:
        let leaf_val = uint32(cpu.gba.bus[child_addr])
        if data_size == 4:
          out_word = out_word or (leaf_val shl out_bits)
          out_bits += 4
        else:
          out_word = out_word or (leaf_val shl out_bits)
          out_bits += 8
        if out_bits >= 32:
          cpu.gba.bus.write_word(dst, out_word)
          dst += 4
          written += 4
          out_word = 0
          out_bits = 0
        cur_node = tree_start
      else:
        cur_node = child_addr
  of 0x14:  # RLUnCompWram (8-bit writes)
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    var dst = cpu.r[1]
    var written: uint32 = 0
    while written < decomp_len:
      let flag = uint32(cpu.gba.bus[src]); src += 1
      if bit(flag, 7):
        # Compressed run
        let length = (flag and 0x7F) + 3
        let val = cpu.gba.bus[src]; src += 1
        for j in 0'u32 ..< length:
          if written >= decomp_len: break
          cpu.gba.bus[dst] = val
          dst += 1; written += 1
      else:
        # Uncompressed run
        let length = (flag and 0x7F) + 1
        for j in 0'u32 ..< length:
          if written >= decomp_len: break
          cpu.gba.bus[dst] = cpu.gba.bus[src]
          src += 1; dst += 1; written += 1
  of 0x15:  # RLUnCompVram (16-bit writes)
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    var dst = cpu.r[1]
    var written: uint32 = 0
    var out_buf: uint16 = 0
    var out_idx: uint32 = 0
    while written < decomp_len:
      let flag = uint32(cpu.gba.bus[src]); src += 1
      if bit(flag, 7):
        # Compressed run
        let length = (flag and 0x7F) + 3
        let val = cpu.gba.bus[src]; src += 1
        for j in 0'u32 ..< length:
          if written >= decomp_len: break
          if (out_idx and 1) == 0:
            out_buf = uint16(val)
          else:
            out_buf = out_buf or (uint16(val) shl 8)
            cpu.gba.bus.write_half(dst and not 1'u32, out_buf)
          dst += 1; written += 1; out_idx += 1
      else:
        # Uncompressed run
        let length = (flag and 0x7F) + 1
        for j in 0'u32 ..< length:
          if written >= decomp_len: break
          let val = cpu.gba.bus[src]; src += 1
          if (out_idx and 1) == 0:
            out_buf = uint16(val)
          else:
            out_buf = out_buf or (uint16(val) shl 8)
            cpu.gba.bus.write_half(dst and not 1'u32, out_buf)
          dst += 1; written += 1; out_idx += 1
  of 0x16:  # Diff8bitUnFilterWram (8-bit writes)
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    var dst = cpu.r[1]
    var written: uint32 = 0
    var prev = cpu.gba.bus[src]; src += 1
    cpu.gba.bus[dst] = prev
    dst += 1; written += 1
    while written < decomp_len:
      let diff = cpu.gba.bus[src]; src += 1
      prev = uint8((uint32(prev) + uint32(diff)) and 0xFF)
      cpu.gba.bus[dst] = prev
      dst += 1; written += 1
  of 0x17:  # Diff8bitUnFilterVram (16-bit writes)
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    var dst = cpu.r[1]
    var written: uint32 = 0
    var out_buf: uint16 = 0
    var out_idx: uint32 = 0
    var prev = cpu.gba.bus[src]; src += 1
    # Output first byte
    out_buf = uint16(prev)
    out_idx += 1
    dst += 1; written += 1
    while written < decomp_len:
      let diff = cpu.gba.bus[src]; src += 1
      prev = uint8((uint32(prev) + uint32(diff)) and 0xFF)
      if (out_idx and 1) == 0:
        out_buf = uint16(prev)
      else:
        out_buf = out_buf or (uint16(prev) shl 8)
        cpu.gba.bus.write_half(dst and not 1'u32, out_buf)
      dst += 1; written += 1; out_idx += 1
  of 0x18:  # Diff16bitUnFilter
    var src = cpu.r[0]
    let header = cpu.gba.bus.read_word(src)
    let decomp_len = header shr 8
    src += 4
    var dst = cpu.r[1]
    var written: uint32 = 0
    var prev = cpu.gba.bus.read_half(src); src += 2
    cpu.gba.bus.write_half(dst, prev)
    dst += 2; written += 2
    while written < decomp_len:
      let diff = cpu.gba.bus.read_half(src); src += 2
      prev = uint16((uint32(prev) + uint32(diff)) and 0xFFFF)
      cpu.gba.bus.write_half(dst, prev)
      dst += 2; written += 2
  of 0x19:  # SoundBias(r0): 0 sets SOUNDBIAS=0x000, else SOUNDBIAS=0x200.
    # bias_level is the 9-bit field at register bits 1-9, so the 0x200 register
    # value is bias_level 0x100 (not 0x200, which would truncate to 0).
    cpu.gba.apu.soundbias.bias_level = if cpu.r[0] == 0: 0x000'u16 else: 0x100'u16
  of 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x20, 0x21, 0x22, 0x23, 0x24, 0x28, 0x29:
    discard  # Sound driver / music player stubs (games use their own engine)
  of 0x1F:  # MidiKey2Freq
    let base_freq = cpu.gba.bus.read_word(cpu.r[0] + 4)
    let key = cast[int32](cpu.r[1])
    let pitch = cast[int32](cpu.r[2])
    # BIOS reference key is 180 (not middle-C 60): WaveData.freq stores the
    # sample rate scaled up 10 octaves, and MidiKey2Freq divides it back down by
    # (180 - key - pitch/256) semitones. Using 60 made every note 120 semitones
    # (2^10 = 1024x) too high, so the M4A mixer strode through sample data ~1000x
    # too fast -> aliased screeching (Metroid Fusion intro).
    let exponent = (float64(key) - 180.0 + float64(pitch) / 256.0) / 12.0
    let freq = float64(base_freq) * pow(2.0, exponent)
    cpu.r[0] = uint32(freq)
  of 0x25:  # MultiBoot
    cpu.r[0] = 1'u32  # Return failure (link cable not emulated)
  else:
    echo "unimplemented SWI: 0x", toHex(swi_num, 2)

proc exception_return_restore*(cpu: CPU) =
  ## CPSR <- SPSR after an instruction that loaded r15 with the S bit set
  ## (subs pc, lr, #4 / ldmfd sp!, {..., pc}^). Assumes set_reg(15) already
  ## ran, so the pipeline offset is corrected when returning to thumb.
  cpu.instr_exc_return = true
  if cpu.spsr.thumb:
    cpu.r[15] -= 4
    # set_reg(15) already refilled the pipeline at ARM width; a return to
    # thumb refills with two halfword fetches instead. Charge the
    # difference (zero in IWRAM/BIOS, -6 in EWRAM/default ROM).
    let page = int(bits_range(cpu.r[15], 24, 27))
    cpu.gba.bus.add_cycles(2 * (int(cpu.gba.bus.wait16_s[page]) -
                                int(cpu.gba.bus.wait32_s[page])))
  let old_spsr = uint32(cpu.spsr)
  let was_irq_disabled = cpu.cpsr.irq_disable
  let new_mode = cast[CpuMode](cpu.spsr.mode)
  cpu.switch_mode(new_mode)
  cpu.cpsr = cast[PSR](old_spsr)
  let bank = mode_bank(new_mode)
  cpu.spsr = cast[PSR](if bank == 0: uint32(cpu.cpsr) else: cpu.spsr_banks[bank])
  if was_irq_disabled and not cpu.cpsr.irq_disable:
    cpu.gba.interrupts.schedule_interrupt_check()

proc arm_unimplemented*(cpu: CPU; instr: uint32) =
  cpu.und()
  cpu.step_arm()

proc arm_unused*(cpu: CPU; instr: uint32) =
  cpu.und()
  cpu.step_arm()

proc rotate_register*(cpu: CPU; instr: uint32; carry_out: ptr bool; allow_register_shifts: bool): uint32 =
  let reg        = int(bits_range(instr, 0, 3))
  let shift_type = int(bits_range(instr, 5, 6))
  let immediate  = not (allow_register_shifts and bit(instr, 4))
  var shift_amount: uint32
  if immediate:
    shift_amount = bits_range(instr, 7, 11)
  else:
    let shift_register = int(bits_range(instr, 8, 11))
    shift_amount = cpu.r[shift_register] and 0xFF'u32
  case shift_type
  of 0b00: cpu.lsl(cpu.r[reg], shift_amount, carry_out)
  of 0b01: cpu.lsr(cpu.r[reg], shift_amount, immediate, carry_out)
  of 0b10: cpu.asr(cpu.r[reg], shift_amount, immediate, carry_out)
  of 0b11: cpu.ror(cpu.r[reg], shift_amount, immediate, carry_out)
  else: raise newException(Exception, "Impossible shift type: " & hex_str(uint8(shift_type)))

proc immediate_offset*(cpu: CPU; instr: uint32; carry_out: ptr bool): uint32 =
  let rotate = bits_range(instr, 8, 11)
  let imm    = bits_range(instr, 0, 7)
  cpu.ror(imm, rotate shl 1, false, carry_out)

type ArmAluOp* = enum
  AND, EOR, SUB, RSB,
  ADD, ADC, SBC, RSC,
  TST, TEQ, CMP, CMN,
  ORR, MOV, BIC, MVN

proc arm_multiply*[accumulate, set_cond: static bool](cpu: CPU; instr: uint32) =
  let rd  = int(bits_range(instr, 16, 19))
  let rn  = int(bits_range(instr, 12, 15))
  let rs  = int(bits_range(instr, 8, 11))
  let rm  = int(bits_range(instr, 0, 3))
  let acc = when accumulate: cpu.r[rn] else: 0'u32
  cpu.idle(mul_i_cycles(cpu.r[rs], true) + (when accumulate: 1 else: 0))
  discard cpu.set_reg(rd, cpu.r[rm] * cpu.r[rs] + acc)
  when set_cond: cpu.set_neg_and_zero_flags(cpu.r[rd])
  if rd != 15: cpu.step_arm()

proc arm_multiply_long*[signed, accumulate, set_cond: static bool](cpu: CPU; instr: uint32) =
  let rdhi = int(bits_range(instr, 16, 19))
  let rdlo = int(bits_range(instr, 12, 15))
  let rs   = int(bits_range(instr, 8, 11))
  let rm   = int(bits_range(instr, 0, 3))
  var res: uint64 =
    when signed:
      cast[uint64](int64(cast[int32](cpu.r[rm])) * int64(cast[int32](cpu.r[rs])))
    else:
      uint64(cpu.r[rm]) * uint64(cpu.r[rs])
  cpu.idle(mul_i_cycles(cpu.r[rs], signed) + (when accumulate: 2 else: 1))
  when accumulate:
    res += (uint64(cpu.r[rdhi]) shl 32) or uint64(cpu.r[rdlo])
  discard cpu.set_reg(rdhi, uint32(res shr 32))
  discard cpu.set_reg(rdlo, uint32(res))
  when set_cond:
    cpu.cpsr.negative = bit(cpu.r[rdhi], 31)
    cpu.cpsr.zero     = (res == 0)
    # ARM7TDMI "meaningless" carry flag: determined by the Booth multiplier internals.
    # For long multiply, the carry depends on the number of Booth iterations and
    # the interaction of Rm/Rs bit patterns in the carry-save adder.
    block:
      let rs_val = cpu.r[rs]
      let rm_val = cpu.r[rm]
      when signed:
        var rs33 = uint64(rs_val)
        if bit(rs_val, 31): rs33 = rs33 or 0x1_00000000'u64
        let four_iters = not ((rs33 shr 8) == 0 or (rs33 shr 8) == 0x1FFFFFF'u64 or
                              (rs33 shr 16) == 0 or (rs33 shr 16) == 0x1FFFF'u64 or
                              (rs33 shr 24) == 0 or (rs33 shr 24) == 0x1FF'u64)
        cpu.cpsr.carry = four_iters and (bit(rm_val, 31) xor bit(rs_val, 31))
      else:
        let four_iters = rs_val > 0xFFFFFF'u32
        if four_iters and ((rs_val shr 29) == 7):
          # Rs bits [31:29] all set: Booth chunk 15 cancels, carry from chunk 16
          cpu.cpsr.carry = bit(rm_val, 30)
        else:
          cpu.cpsr.carry = four_iters and bit(rm_val, 31)
  if rdhi != 15 and rdlo != 15: cpu.step_arm()

proc arm_single_data_swap*[byte_quantity: static bool](cpu: CPU; instr: uint32) =
  let rn = int(bits_range(instr, 16, 19))
  let rd = int(bits_range(instr, 12, 15))
  let rm = int(bits_range(instr, 0, 3))
  when byte_quantity:
    let tmp = cpu.gba.bus[cpu.r[rn]]
    cpu.gba.bus[cpu.r[rn]] = uint8(cpu.r[rm])
    discard cpu.set_reg(rd, uint32(tmp))
  else:
    let tmp = cpu.gba.bus.read_word_rotate(cpu.r[rn])
    cpu.gba.bus.write_word(cpu.r[rn], cpu.r[rm])
    discard cpu.set_reg(rd, tmp)
  cpu.idle(1)
  if rd != 15: cpu.step_arm()

proc arm_branch_exchange*(cpu: CPU; instr: uint32) =
  let address = cpu.r[int(bits_range(instr, 0, 3))]
  cpu.cpsr.thumb = bit(address, 0)
  discard cpu.set_reg(15, address)

proc arm_halfword_data_transfer*[pre, add, immediate, write_back, load: static bool,
                                  sh: static uint32](cpu: CPU; instr: uint32) =
  let rn     = int(bits_range(instr, 16, 19))
  let rd     = int(bits_range(instr, 12, 15))
  let offset =
    when immediate:
      (bits_range(instr, 8, 11) shl 4) or bits_range(instr, 0, 3)
    else:
      cpu.r[int(bits_range(instr, 0, 3))]
  var address = cpu.r[rn]
  when pre:
    when add: address += offset
    else:     address -= offset
  when sh == 0b00:
    raise newException(Exception, "HalfwordDataTransfer sh=00: " & hex_str(instr))
  elif sh == 0b01:  # ldrh/strh
    when load:
      let value = cpu.gba.bus.read_half_rotate(address)
      cpu.idle(1)
      discard cpu.set_reg(rd, value)
    else:
      cpu.gba.bus.write_half(address, uint16(cpu.r[rd] and 0xFFFF'u32))
      if rd == 15:
        cpu.gba.bus.write_half(address, uint16(cpu.gba.bus.read_half(address)) + 4)
  elif sh == 0b10:  # ldrsb
    let value = uint32(cast[int32](cast[int8](cpu.gba.bus[address])))
    cpu.idle(1)
    discard cpu.set_reg(rd, value)
  else:  # sh == 0b11, ldrsh
    let value = cpu.gba.bus.read_half_signed(address)
    cpu.idle(1)
    discard cpu.set_reg(rd, value)
  when not pre:
    when add: address += offset
    else:     address -= offset
  when write_back or not pre:
    if rd != rn or not load:
      discard cpu.set_reg(rn, address)
  if not (load and rd == 15): cpu.step_arm()

proc arm_single_data_transfer*[imm_flag, pre_addressing, add_offset, byte_quantity,
                                 write_back, load, bit0: static bool](cpu: CPU; instr: uint32) =
  var carry_out = false
  let rn = int(bits_range(instr, 16, 19))
  let rd = int(bits_range(instr, 12, 15))
  let offset =
    when imm_flag:
      cpu.rotate_register(bits_range(instr, 0, 11), addr carry_out, allow_register_shifts = false)
    else:
      bits_range(instr, 0, 11)
  var address = cpu.r[rn]
  when pre_addressing:
    when add_offset: address += offset
    else:            address -= offset
  when load:
    let value =
      when byte_quantity:
        uint32(cpu.gba.bus[address])
      else:
        cpu.gba.bus.read_word_rotate(address)
    cpu.idle(1)
    discard cpu.set_reg(rd, value)
  else:
    when byte_quantity:
      cpu.gba.bus[address] = uint8(cpu.r[rd])
    else:
      cpu.gba.bus.write_word(address, cpu.r[rd])
    if rd == 15:
      cpu.gba.bus.write_word(address, cpu.gba.bus.read_word(address) + 4)
  when not pre_addressing:
    when add_offset: address += offset
    else:            address -= offset
  when write_back or not pre_addressing:
    if rd != rn or not load:
      discard cpu.set_reg(rn, address)
  if not (load and rd == 15): cpu.step_arm()

proc arm_block_data_transfer*[pre_address, add, s_bit, write_back, load: static bool](cpu: CPU; instr: uint32) =
  let rn = int(bits_range(instr, 16, 19))
  var list = bits_range(instr, 0, 15)
  var saved_mode: uint32 = 0
  var user_bank = false
  when s_bit:
    # LDM with the S bit and r15 in the list is an exception return: the
    # registers load into the current mode's banks and CPSR is restored from
    # SPSR after pc loads. Every other S-bit form transfers the user bank.
    if not (load and bit(list, 15)):
      user_bank = true
      saved_mode = cpu.cpsr.mode
      cpu.switch_mode(modeUSR)
  var address  = cpu.r[rn]
  var bits_set = count_set_bits(list)
  if bits_set == 0:
    bits_set = 16
    list = 0x8000'u32
  let step       = when add: 4 else: -4
  let final_addr = uint32(int(address) + bits_set * step)
  when add:
    when pre_address: address += 4
  else:
    address = final_addr
    when not pre_address: address += 4
  var first_transfer = false
  for idx in 0..15:
    if bit(list, idx):
      when load:
        let value = cpu.gba.bus.read_word(address)
        if idx == 15: cpu.idle(1)  # the I cycle precedes the pipeline refill
        discard cpu.set_reg(idx, value)
      else:
        cpu.gba.bus.write_word(address, cpu.r[idx])
        if idx == 15:
          cpu.gba.bus.write_word(address, cpu.gba.bus.read_word(address) + 4)
      address += 4
      when write_back:
        if not first_transfer and not (load and bit(list, rn)):
          discard cpu.set_reg(rn, final_addr)
      first_transfer = true
  when load:
    if not bit(list, 15): cpu.idle(1)  # I cycle after the last transfer
  when s_bit:
    if user_bank:
      cpu.switch_mode(cast[CpuMode](saved_mode))
    else:
      cpu.exception_return_restore()
  if not (load and bit(list, 15)): cpu.step_arm()

proc arm_branch*[link: static bool](cpu: CPU; instr: uint32) =
  let offset = cast[int32](bits_range(instr, 0, 23) shl 8) shr 6
  when link: discard cpu.set_reg(14, cpu.r[15] - 4)
  discard cpu.set_reg(15, uint32(int(cpu.r[15]) + offset))

proc arm_software_interrupt*(cpu: CPU; instr: uint32) =
  let use_hle = cpu.gba.use_hle or (cpu.gba.hle_after_bios and cpu.r[15] >= 0x08000000'u32)
  let swi_num = bits_range(instr, 16, 23)
  if use_hle:
    cpu.hle_swi(swi_num)
    cpu.step_arm()
  else:
    let lr = cpu.r[15] - 4
    let old_cpsr = cpu.cpsr
    cpu.switch_mode(modeSVC)
    cpu.spsr = old_cpsr
    discard cpu.set_reg(14, lr)
    cpu.cpsr.irq_disable = true
    discard cpu.set_reg(15, 0x08'u32)

proc arm_psr_transfer*[imm_flag, spsr, msr: static bool](cpu: CPU; instr: uint32) =
  let mode     = cast[CpuMode](cpu.cpsr.mode)
  let has_spsr = mode != modeUSR and mode != modeSYS
  when msr:
    var mask: uint32 = 0
    if bit(instr, 19): mask = mask or 0xFF000000'u32
    if bit(instr, 18): mask = mask or 0x00FF0000'u32
    if bit(instr, 17): mask = mask or 0x0000FF00'u32
    if bit(instr, 16): mask = mask or 0x000000FF'u32
    var carry_out = false
    let value =
      when imm_flag:
        cpu.immediate_offset(bits_range(instr, 0, 11), addr carry_out) and mask
      else:
        cpu.r[int(bits_range(instr, 0, 3))] and mask
    when spsr:
      if has_spsr:
        cpu.spsr = cast[PSR]((uint32(cpu.spsr) and not mask) or value)
    else:
      let thumb = cpu.cpsr.thumb
      let was_irq_disabled = cpu.cpsr.irq_disable
      if (mask and 0xFF) > 0:
        cpu.switch_mode(cast[CpuMode](value and 0x1F'u32))
      cpu.cpsr = cast[PSR]((uint32(cpu.cpsr) and not mask) or value)
      cpu.cpsr.thumb = thumb
      if was_irq_disabled and not cpu.cpsr.irq_disable:
        cpu.gba.interrupts.schedule_interrupt_check()
  else:  # MRS
    let rd = int(bits_range(instr, 12, 15))
    if spsr and has_spsr:
      discard cpu.set_reg(rd, uint32(cpu.spsr))
    else:
      discard cpu.set_reg(rd, uint32(cpu.cpsr))
  when not msr:
    if bits_range(instr, 12, 15) != 15: cpu.step_arm()
  else:
    cpu.step_arm()

proc arm_data_processing*[imm_flag: static bool, opcode: static ArmAluOp,
                            set_cond, bit4: static bool](cpu: CPU; instr: uint32) =
  const pc_reads_12_ahead = not imm_flag and bit4
  when pc_reads_12_ahead:
    cpu.r[15] += 4
    cpu.idle(1)  # register-specified shift costs one internal cycle
  var barrel_carry = cpu.cpsr.carry
  let rn = int(bits_range(instr, 16, 19))
  let rd = int(bits_range(instr, 12, 15))
  let operand_2 =
    when imm_flag:
      cpu.immediate_offset(bits_range(instr, 0, 11), addr barrel_carry)
    else:
      cpu.rotate_register(bits_range(instr, 0, 11), addr barrel_carry, allow_register_shifts = true)
  when opcode == AND:
    discard cpu.set_reg(rd, cpu.r[rn] and operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  elif opcode == EOR:
    discard cpu.set_reg(rd, cpu.r[rn] xor operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  elif opcode == SUB:
    discard cpu.set_reg(rd, cpu.sub(cpu.r[rn], operand_2, set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == RSB:
    discard cpu.set_reg(rd, cpu.sub(operand_2, cpu.r[rn], set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == ADD:
    discard cpu.set_reg(rd, cpu.add(cpu.r[rn], operand_2, set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == ADC:
    discard cpu.set_reg(rd, cpu.adc(cpu.r[rn], operand_2, set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == SBC:
    discard cpu.set_reg(rd, cpu.sbc(cpu.r[rn], operand_2, set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == RSC:
    discard cpu.set_reg(rd, cpu.sbc(operand_2, cpu.r[rn], set_cond))
    if rd != 15: cpu.step_arm()
  elif opcode == TST:
    cpu.set_neg_and_zero_flags(cpu.r[rn] and operand_2)
    cpu.cpsr.carry = barrel_carry
    cpu.step_arm()
  elif opcode == TEQ:
    cpu.set_neg_and_zero_flags(cpu.r[rn] xor operand_2)
    cpu.cpsr.carry = barrel_carry
    cpu.step_arm()
  elif opcode == CMP:
    discard cpu.sub(cpu.r[rn], operand_2, set_cond)
    cpu.step_arm()
  elif opcode == CMN:
    discard cpu.add(cpu.r[rn], operand_2, set_cond)
    cpu.step_arm()
  elif opcode == ORR:
    discard cpu.set_reg(rd, cpu.r[rn] or operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  elif opcode == MOV:
    discard cpu.set_reg(rd, operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  elif opcode == BIC:
    discard cpu.set_reg(rd, cpu.r[rn] and not operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  else:  # MVN
    discard cpu.set_reg(rd, not operand_2)
    when set_cond:
      cpu.set_neg_and_zero_flags(cpu.r[rd])
      cpu.cpsr.carry = barrel_carry
    if rd != 15: cpu.step_arm()
  when pc_reads_12_ahead: cpu.r[15] -= 4
  if rd == 15 and set_cond:
    cpu.exception_return_restore()
