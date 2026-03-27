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
  var r3 = mul32(0xA9'i32, r1)
  r3 = ashr(r3, 14)
  r3 = r3 + 0x0390'i32; r3 = mul32(r3, r1); r3 = ashr(r3, 14)
  r3 = r3 + 0x091C'i32; r3 = mul32(r3, r1); r3 = ashr(r3, 14)
  r3 = r3 + 0x0FB6'i32; r3 = mul32(r3, r1); r3 = ashr(r3, 14)
  r3 = r3 + 0x16AA'i32; r3 = mul32(r3, r1); r3 = ashr(r3, 14)
  r3 = r3 + 0x2081'i32; r3 = mul32(r3, r1); r3 = ashr(r3, 14)
  r3 = r3 + 0x3651'i32; r3 = mul32(r3, r1); r3 = ashr(r3, 14)
  r3 = r3 + 0xA2F9'i32
  cpu.r[0] = cast[uint32](ashr(mul32(r3, a), 16))
  cpu.r[1] = cast[uint32](r1)
  cpu.r[3] = cast[uint32](r3)

proc hle_swi*(cpu: CPU; swi_num: uint32) =
  ## HLE BIOS dispatch for the most common GBA SWI calls.
  ## Only used when no real BIOS file is provided.
  case swi_num
  of 0x00:  # SoftReset
    let return_flag = cpu.gba.bus.wram_chip[0x7FFA]
    for i in 0x7E00 ..< 0x8000:
      cpu.gba.bus.wram_chip[i] = 0
    for i in 0 .. 12:
      cpu.r[i] = 0
    cpu.reg_banks[mode_bank(modeUSR)][5] = 0x03007F00'u32
    cpu.reg_banks[mode_bank(modeIRQ)][5] = 0x03007FA0'u32
    cpu.reg_banks[mode_bank(modeSVC)][5] = 0x03007FE0'u32
    cpu.cpsr = cast[PSR](uint32(modeSYS))
    let reset_addr = if return_flag == 0: 0x08000000'u32 else: 0x02000000'u32
    discard cpu.set_reg(15, reset_addr)
  of 0x02:  # Halt
    cpu.halted = true
  of 0x03:  # Stop
    cpu.halted = true
  of 0x06:  # Div
    let numer = int64(cast[int32](cpu.r[0]))
    let denom = int64(cast[int32](cpu.r[1]))
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
  of 0x07:  # DivArm (swapped inputs)
    let numer = int64(cast[int32](cpu.r[1]))
    let denom = int64(cast[int32](cpu.r[0]))
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
  of 0x04:  # IntrWait(discard_flags, intr_flags)
    let discard_flags = cpu.r[0]
    let intr_mask = uint16(cpu.r[1])
    if discard_flags != 0:
      cpu.gba.interrupts.reg_if =
        cast[InterruptReg](uint16(cpu.gba.interrupts.reg_if) and not intr_mask)
    cpu.gba.interrupts.reg_ie =
      cast[InterruptReg](uint16(cpu.gba.interrupts.reg_ie) or intr_mask)
    cpu.halted = true
  of 0x05:  # VBlankIntrWait
    cpu.gba.interrupts.reg_if.vblank = false
    cpu.gba.interrupts.reg_ie.vblank = true
    cpu.halted = true
  of 0x08:  # Sqrt
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
    if word_mode:
      src = src and not 3'u32
      dst = dst and not 3'u32
      let fill_val = cpu.gba.bus.read_word(src)
      for i in 0'u32 ..< count:
        let val = if fill: fill_val else: cpu.gba.bus.read_word(src)
        cpu.gba.bus.write_word(dst, val)
        if not fill: src += 4
        dst += 4
    else:
      dst = dst and not 1'u32
      let fill_val = if bit(src, 0): uint16(cpu.gba.bus[src])
                     else: cpu.gba.bus.read_half(src)
      for i in 0'u32 ..< count:
        let val = if fill: fill_val
                  elif bit(src, 0): uint16(cpu.gba.bus[src])
                  else: cpu.gba.bus.read_half(src)
        cpu.gba.bus.write_half(dst, val)
        if not fill: src += 2
        dst += 2
    cpu.r[0] = src
    cpu.r[1] = dst
  of 0x01:  # RegisterRamReset
    let flags = cpu.r[0]
    echo "HLE RegisterRamReset: flags=0x", toHex(flags, 2), " pc=0x", toHex(cpu.r[15] - 8, 8)
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
      # The real BIOS sweeps 0x60–0x84: zeroes SOUNDCNT_L (0x80), SOUNDCNT_H (0x82),
      # then writes 0 to SOUNDCNT_X (0x84) which internally clears 0x60–0x81 and
      # disables sound. It does NOT touch SOUNDBIAS (0x88), wave RAM (0x90), or
      # FIFO addresses (0xA0) — games rely on SOUNDBIAS keeping its power-on default.
      cpu.gba.apu.sound_enabled = true
      for offset in 0x60'u32..0x84'u32:
        cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
      # 0xA0–0xA7 (FIFOs) are write-gated after sound is disabled; reset directly
      for ch in 0..1:
        for i in 0..31: cpu.gba.apu.dma_channels.fifos[ch][i] = 0
        cpu.gba.apu.dma_channels.positions[ch] = 0
        cpu.gba.apu.dma_channels.sizes[ch]     = 0
        cpu.gba.apu.dma_channels.latches[ch]   = 0
      # SOUNDCNT_H bits 11/15 (FIFO reset triggers) are masked in the bus write handler;
      # no bus path can fully zero them — reset directly
      cpu.gba.apu.soundcnt_h = SOUNDCNT_H()
    if bit(flags, 7):  # Reset other I/O: LCD (0x000–0x05F) and DMA/timer/etc. (0x0B0–0x1FF)
      for offset in 0x000'u32..0x05F'u32:
        cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
      for offset in 0x0B0'u32..0x1FF'u32:
        cpu.gba.bus[0x04000000'u32 + offset] = 0x00'u8
      # NOTE: 0x200–0x20B (IE, IF, IME) are NOT part of the real BIOS sweep — stop at 0x1FF
    # Simulate the cycle cost of the real BIOS RegisterRamReset.
    # The real BIOS uses CpuSet (STMIA loops) to clear memory:
    #   EWRAM: 64K words × ~3 cyc/word (2 wait-state)  ≈ 192K
    #   IWRAM: ~2K words × ~1 cyc/word                  ≈   2K
    #   VRAM:  24K words × ~2 cyc/word                  ≈  48K
    #   Palette+OAM+I/O+overhead                         ≈   8K
    # Total ≈ 250K cycles for flags=0xFF.
    # Without this, HLE is instantaneous and VBlank/timer scheduling diverges
    # from the real BIOS path, causing audio buffer fill timing mismatches.
    var hle_cycles = 0
    if bit(flags, 0): hle_cycles += 192000  # EWRAM
    if bit(flags, 1): hle_cycles += 2000    # IWRAM
    if bit(flags, 2): hle_cycles += 500     # Palette
    if bit(flags, 3): hle_cycles += 48000   # VRAM
    if bit(flags, 4): hle_cycles += 500     # OAM
    if bit(flags, 5) or bit(flags, 6) or bit(flags, 7): hle_cycles += 5000  # I/O sweeps + overhead
    cpu.gba.bus.cycles += hle_cycles
    echo "  post-reset: snd_en=", cpu.gba.apu.sound_enabled,
         " sndcnt_h=0x", toHex(uint16(cpu.gba.apu.soundcnt_h), 4),
         " soundbias=0x", toHex(uint16(cpu.gba.apu.soundbias), 4),
         " bias_level=", cpu.gba.apu.soundbias.bias_level,
         " dma1.en=", cpu.gba.dma.dmacnt_h[1].enable,
         " dma1.sad=0x", toHex(cpu.gba.dma.dmasad[1], 8),
         " tm0.en=", cpu.gba.timer.tmcnt[0].enable,
         " tm0.tmd=", cpu.gba.timer.tmd[0],
         " ie=0x", toHex(uint16(cpu.gba.interrupts.reg_ie), 4),
         " ime=", cpu.gba.interrupts.ime
  of 0x0C:  # CpuFastSet
    var src = cpu.r[0] and not 3'u32
    var dst = cpu.r[1] and not 3'u32
    let ctrl = cpu.r[2]
    let count = (bits_range(ctrl, 0, 20) + 7) and not 7'u32  # round up to multiple of 8
    let fill = bit(ctrl, 24)
    let fill_val = cpu.gba.bus.read_word(src)
    for i in 0'u32 ..< count:
      let val = if fill: fill_val else: cpu.gba.bus.read_word(src)
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
      let pa = int16(float64(scale_x) * cos_t)
      let pb = int16(-float64(scale_x) * sin_t)
      let pc = int16(float64(scale_y) * sin_t)
      let pd = int16(float64(scale_y) * cos_t)
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
      let cos_val = int16(float64(sx) * cos(theta))
      let sin_val = int16(float64(sx) * sin(theta))
      let cos_val_y = int16(float64(sy) * cos(theta))
      let sin_val_y = int16(float64(sy) * sin(theta))
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
        out_word = out_word or ((expanded and ((1'u32 shl dest_width) - 1)) shl out_bits)
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
  of 0x19:  # SoundBias
    cpu.gba.apu.soundbias.bias_level = uint16(cpu.r[0] and 0x3FF)
  of 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x20, 0x21, 0x22, 0x23, 0x24, 0x28, 0x29:
    discard  # Sound driver / music player stubs (games use their own engine)
  of 0x1F:  # MidiKey2Freq
    let base_freq = cpu.gba.bus.read_word(cpu.r[0] + 4)
    let key = cast[int32](cpu.r[1])
    let pitch = cast[int32](cpu.r[2])
    let exponent = (float64(key) - 60.0 + float64(pitch) / 256.0) / 12.0
    let freq = float64(base_freq) * pow(2.0, exponent)
    cpu.r[0] = uint32(freq)
  of 0x25:  # MultiBoot
    cpu.r[0] = 1'u32  # Return failure (link cable not emulated)
  else:
    echo "unimplemented SWI: 0x", toHex(swi_num, 2)

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
      discard cpu.set_reg(rd, cpu.gba.bus.read_half_rotate(address))
    else:
      cpu.gba.bus.write_half(address, uint16(cpu.r[rd] and 0xFFFF'u32))
      if rd == 15:
        cpu.gba.bus.write_half(address, uint16(cpu.gba.bus.read_half(address)) + 4)
  elif sh == 0b10:  # ldrsb
    discard cpu.set_reg(rd, uint32(cast[int32](cast[int8](cpu.gba.bus[address]))))
  else:  # sh == 0b11, ldrsh
    discard cpu.set_reg(rd, cpu.gba.bus.read_half_signed(address))
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
    when byte_quantity:
      discard cpu.set_reg(rd, uint32(cpu.gba.bus[address]))
    else:
      discard cpu.set_reg(rd, cpu.gba.bus.read_word_rotate(address))
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
  when s_bit:
    if bit(list, 15):
      raise newException(Exception, "todo: handle cases with r15 in list")
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
        discard cpu.set_reg(idx, cpu.gba.bus.read_word(address))
      else:
        cpu.gba.bus.write_word(address, cpu.r[idx])
        if idx == 15:
          cpu.gba.bus.write_word(address, cpu.gba.bus.read_word(address) + 4)
      address += 4
      when write_back:
        if not first_transfer and not (load and bit(list, rn)):
          discard cpu.set_reg(rn, final_addr)
      first_transfer = true
  when s_bit:
    cpu.switch_mode(cast[CpuMode](saved_mode))
  if not (load and bit(list, 15)): cpu.step_arm()

proc arm_branch*[link: static bool](cpu: CPU; instr: uint32) =
  let offset = cast[int32](bits_range(instr, 0, 23) shl 8) shr 6
  when link: discard cpu.set_reg(14, cpu.r[15] - 4)
  discard cpu.set_reg(15, uint32(int(cpu.r[15]) + offset))

# BISECT: SWI numbers that use HLE when --hle is active; all others route through real BIOS.
# Start empty (all real BIOS) to confirm the fix, then add SWIs back to narrow down the culprit.
# Suggested groups: {0x00'u8..0x03'u8} | {0x06'u8..0x0A'u8} | {0x0B'u8, 0x0C'u8} | {0x0D'u8..0x11'u8}
const hle_swi_set: set[uint8] = {0x00'u8..0x0A'u8, 0x0B'u8..0x18'u8}

proc arm_software_interrupt*(cpu: CPU; instr: uint32) =
  let use_hle = cpu.gba.use_hle or (cpu.gba.hle_after_bios and cpu.r[15] >= 0x08000000'u32)
  let swi_num = bits_range(instr, 16, 23)
  if use_hle and uint8(swi_num) in hle_swi_set:
    cpu.hle_swi(swi_num)
    cpu.step_arm()
  else:
    let lr = cpu.r[15] - 4
    cpu.switch_mode(modeSVC)
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
  when pc_reads_12_ahead: cpu.r[15] += 4
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
    if cpu.spsr.thumb: cpu.r[15] -= 4
    let old_spsr = uint32(cpu.spsr)
    let was_irq_disabled = cpu.cpsr.irq_disable
    let new_mode = cast[CpuMode](cpu.spsr.mode)
    cpu.switch_mode(new_mode)
    cpu.cpsr = cast[PSR](old_spsr)
    let bank = mode_bank(new_mode)
    cpu.spsr = cast[PSR](if bank == 0: uint32(cpu.cpsr) else: cpu.spsr_banks[bank])
    if was_irq_disabled and not cpu.cpsr.irq_disable:
      cpu.gba.interrupts.schedule_interrupt_check()
