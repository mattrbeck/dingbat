## HLE BIOS for both DS CPUs: the DS runs without Nintendo's BIOS dumps.
##
## Two halves:
##
## - A synthesized BIOS image per CPU (ARM9: 4 KB at 0xFFFF0000; ARM7:
##   16 KB at 0) holding real ARM code, assembled from hle_bios.s and
##   embedded through hle_bios_image.nim: the exception vectors, the IRQ
##   dispatcher (push r0-r3/r12/lr, call [DTCM+0x3FFC] / [0x0380FFFC], subs
##   pc, lr, #4), a GBATEK-shaped SWI dispatcher, and the SWIs that must run
##   as guest code because they block or call back into the game: IntrWait,
##   VBlankIntrWait, WaitByLoop and the ReadByCallback decompressors.
## - `hle_swi`, called by the CPU's swi_hook mixin before the SWI vector is
##   taken. It answers every other SWI in Nim and returns true; for the
##   guest-code ones it returns false and the SWI enters the image's
##   dispatcher like it would on the console.
##
## GBATEK ("BIOS Functions", the NDS7/NDS9 columns) is the spec; the
## algorithms shared with the GBA follow the GBA core's HLE (gba/hle_bios.nim),
## copied without its AGB cycle models since DS timing is a placeholder.
## Nothing here is taken from a BIOS dump: the GetSine/Pitch/VolumeTable
## values are generated from the formulas below, and
## tests/nds_hle_bios_test.nim runs every pure SWI against the real BIOS on
## the same inputs.
##
## Generic over the CPU's bus like arm/cpu.nim: `armv5(B)` selects the ARM9
## table; memory goes through the read/write mixins.

import std/math
import arm/cpu
import hle_bios_image

export hle_bios_image

const
  BIOS9_SIZE* = 4 * 1024
  BIOS7_SIZE* = 16 * 1024

proc hle_bios9_image*(): seq[uint8] =
  result = newSeq[uint8](BIOS9_SIZE)
  for i, b in HLE_BIOS9_CODE: result[i] = b

proc hle_bios7_image*(): seq[uint8] =
  result = newSeq[uint8](BIOS7_SIZE)
  for i, b in HLE_BIOS7_CODE: result[i] = b

# ---------------------------------------------------------------------------
# Tables (ARM7 SWIs 1Ah-1Ch), generated from formulas

const SINE_TABLE = block:
  ## GetSineTable: a quarter wave in 64 steps, sin(i * 90/64 degrees) in
  ## 1.15 fixed point with full scale 7FFFh, rounded (GBATEK: entries
  ## 0000h..7FF5h).
  var t: array[64, uint16]
  for i in 0 ..< 64:
    t[i] = uint16(round(sin(float(i) * PI / 128.0) * 32767.0))
  t

const PITCH_TABLE = block:
  ## GetPitchTable: one octave in 768 steps, 2^(i/768) - 1 in 0.16 fixed
  ## point, rounded (GBATEK: entries 0000h..FF8Ah). The SPU timer of a note
  ## is its base timer scaled by 1 + entry/10000h.
  var t: array[768, uint16]
  for i in 0 ..< 768:
    t[i] = uint16(round((pow(2.0, float(i) / 768.0) - 1.0) * 65536.0))
  t

const VOLUME_TABLE = block:
  ## GetVolumeTable: 724 steps of 0.1 dB, -72.3 dB .. 0 dB, as the SPU's
  ## 7-bit volume (GBATEK: entries 00h..7Fh) under a divider (the SPU's
  ## shift of 0, 1, 2 or 4) the caller picks from the index: each entry is
  ## the amplitude 10^((i - 723) / 200) times 128, scaled up by the
  ## largest of 16, 4, 2 that keeps it below full scale, rounded and
  ## clamped to 7Fh. Measured against the console BIOS's output, the last
  ## entry under each divider step (602, 662, 722) reads 126, one below
  ## what the formula rounds to; every other entry is the formula.
  var t: array[724, uint8]
  for i in 0 ..< 724:
    let a = pow(10.0, float(i - 723) / 200.0)
    var m = 1.0
    for k in [16.0, 4.0, 2.0]:
      if a * k < 1.0:
        m = k
        break
    t[i] = uint8(min(127.0, round(a * m * 128.0)))
  for i in [602, 662, 722]: t[i] = 126
  t

# ---------------------------------------------------------------------------
# Helpers

proc bios_src_ok(src, length: uint32): bool {.inline.} =
  ## The ARM7 BIOS's check before a copy or decompression reads memory
  ## (GBATEK "BIOS Memory Copy": it silently does nothing when the source
  ## start or end reaches into the BIOS area); the GBA BIOS's test. The
  ## ARM9 BIOS has no such check.
  if length == 0: return false
  if (src and 0x0E000000'u32) == 0: return false
  ((src + (length and 0x01FFFFFF'u32)) and 0x0E000000'u32) != 0

proc src_ok[B](cpu: ArmCpu[B]; src, length: uint32): bool {.inline.} =
  mixin armv5
  when armv5(B): true else: bios_src_ok(src, length)

proc hle_div[B](cpu: ArmCpu[B]) =
  ## Div (09h): r0 / r1 -> r0 quotient, r1 remainder, r3 |quotient|. A
  ## zero denominator answers (+-1, numerator, 1): what the DS BIOS returns
  ## for numerators 0 and +-1 (as the GBA's does); for larger ones it loops
  ## for ever (GBATEK), where the HLE keeps the game running instead.
  let numer = int64(cast[int32](cpu.r[0]))
  let denom = int64(cast[int32](cpu.r[1]))
  if denom == 0:
    cpu.r[0] = if numer < 0: 0xFFFFFFFF'u32 else: 1'u32
    cpu.r[1] = uint32(numer and 0xFFFFFFFF)
    cpu.r[3] = 1
  else:
    let q = numer div denom
    cpu.r[0] = uint32(q and 0xFFFFFFFF)
    cpu.r[1] = uint32((numer mod denom) and 0xFFFFFFFF)
    cpu.r[3] = uint32(abs(q) and 0xFFFFFFFF)

proc hle_sqrt[B](cpu: ArmCpu[B]) =
  ## Sqrt (0Dh), the GBA BIOS's routine (gba/hle_bios.nim SWI 08h) and the
  ## same scratch left in r1/r3: Newton from the power of two at or above
  ## sqrt(x), x_next = (x_n + x / x_n) / 2, stopping at the first step that
  ## fails to decrease. r0 = the root, r1 = the rejected average, r3 = the
  ## last quotient (x = 0 runs a second pass whose 0/0 gives quotient 1).
  let x = cpu.r[0]
  var estimate = 1'u32
  var scaled = x
  while scaled > estimate:
    scaled = scaled shr 1
    estimate = estimate shl 1
  var root, quotient: uint32
  while true:
    root = estimate
    quotient = if estimate == 0: 1'u32 else: x div estimate
    estimate = uint32((uint64(estimate) + uint64(quotient)) shr 1)
    if estimate >= root: break
  cpu.r[0] = root
  cpu.r[1] = estimate
  cpu.r[3] = quotient

proc hle_cpu_set[B](cpu: ArmCpu[B]) =
  ## CpuSet (0Bh): r2 bits 0-20 count, 24 fill, 26 32-bit units. The word
  ## form walks r0/r1 (ldmia/stmia; a fill pops its one source word), the
  ## halfword form indexes and leaves them.
  mixin read16, read32, write16, write32
  var src = cpu.r[0]
  var dst = cpu.r[1]
  let ctrl = cpu.r[2]
  let count = ctrl and 0x1FFFFF'u32
  let fill = (ctrl and (1'u32 shl 24)) != 0
  if (ctrl and (1'u32 shl 26)) != 0:
    if not cpu.src_ok(src, count shl 2): return
    let v = read32(cpu.bus, src and not 3'u32)
    if fill: src += 4
    for _ in 0'u32 ..< count:
      write32(cpu.bus, dst and not 3'u32,
              if fill: v else: read32(cpu.bus, src and not 3'u32))
      if not fill: src += 4
      dst += 4
    cpu.r[0] = src
    cpu.r[1] = dst
  else:
    if not cpu.src_ok(src, count shl 1): return
    let v = read16(cpu.bus, src and not 1'u32)
    for _ in 0'u32 ..< count:
      write16(cpu.bus, dst and not 1'u32,
              uint16(if fill: v else: read16(cpu.bus, src and not 1'u32)))
      if not fill: src += 2
      dst += 2

proc hle_cpu_fast_set[B](cpu: ArmCpu[B]) =
  ## CpuFastSet (0Ch): words, any count on the DS (no rounding up to 8).
  ## r0 (copies only) and r1 come back past the block. GBATEK's bug, the
  ## 8-word bursts covering only the first `count` bytes, shows in r3: a
  ## fill leaves the fill word there, a copy the second word of the last
  ## burst, ceil((count and not 7) / 32) bursts in (none: r3 untouched).
  mixin read32, write32
  var src = cpu.r[0] and not 3'u32
  var dst = cpu.r[1] and not 3'u32
  let ctrl = cpu.r[2]
  let count = ctrl and 0x1FFFFF'u32
  let fill = (ctrl and (1'u32 shl 24)) != 0
  if not cpu.src_ok(src, count shl 2): return
  let bursts = ((count and not 7'u32) + 31) div 32
  var v = read32(cpu.bus, src)
  for i in 0'u32 ..< count:
    if not fill:
      v = read32(cpu.bus, src)
      src += 4
      if bursts > 0 and i == 8 * (bursts - 1) + 1: cpu.r[3] = v
    write32(cpu.bus, dst, v)
    dst += 4
  if count > 0:
    if fill: cpu.r[3] = v
    else: cpu.r[0] = src
    cpu.r[1] = dst

proc hle_crc16[B](cpu: ArmCpu[B]) =
  ## GetCRC16 (0Eh): r0 initial, r1 address, r2 length in bytes, read as
  ## halfwords; r0 = CRC, r1 = the end, r3 = the last halfword read. The
  ## ARM7's reads are not checked against the BIOS area (GBATEK).
  mixin read16
  var crc = cpu.r[0] and 0xFFFF
  var a = cpu.r[1] and not 1'u32
  let n = cpu.r[2] shr 1
  for _ in 0'u32 ..< n:
    let h = read16(cpu.bus, a)
    a += 2
    cpu.r[3] = h
    crc = crc xor h
    for _ in 0 ..< 16:
      crc = if (crc and 1) != 0: (crc shr 1) xor 0xA001'u32 else: crc shr 1
  cpu.r[0] = crc
  if n > 0: cpu.r[1] = a

proc hle_bit_unpack[B](cpu: ArmCpu[B]) =
  ## BitUnPack (10h): r0 source, r1 destination, r2 info {u16 source
  ## length, u8 source width, u8 destination width, u32 offset | zero flag}.
  ## r0/r1 come back past what was read and written, r3 = 0 (the emptied
  ## output word).
  mixin read8, read16, read32, write32
  var src = cpu.r[0]
  var dst = cpu.r[1]
  let info = cpu.r[2]
  let src_len = read16(cpu.bus, info and not 1'u32)
  if not cpu.src_ok(src, src_len): return
  let src_width = read8(cpu.bus, info + 2)
  let dst_width = read8(cpu.bus, info + 3)
  let data_offset = read32(cpu.bus, (info + 4) and not 3'u32)
  if src_width notin [1'u32, 2, 4, 8] or dst_width notin [1'u32, 2, 4, 8, 16, 32]:
    return
  let offset = data_offset and 0x7FFFFFFF'u32
  let zero_flag = (data_offset and 0x80000000'u32) != 0
  let src_mask = (1'u32 shl src_width) - 1
  let dst_mask = if dst_width >= 32: 0xFFFFFFFF'u32 else: (1'u32 shl dst_width) - 1
  var out_word = 0'u32
  var out_bits = 0'u32
  for _ in 0'u32 ..< src_len:
    let b = read8(cpu.bus, src)
    src += 1
    var bit = 0'u32
    while bit < 8:
      let v = (b shr bit) and src_mask
      let e = if v != 0 or zero_flag: v + offset else: 0'u32
      out_word = out_word or ((e and dst_mask) shl out_bits)
      out_bits += dst_width
      if out_bits >= 32:
        write32(cpu.bus, dst and not 3'u32, out_word)
        dst += 4
        out_word = 0
        out_bits = 0
      bit += src_width
  cpu.r[0] = src
  cpu.r[1] = dst
  cpu.r[3] = out_word

# The DS decompressors finish the token they are in: a back-reference or a
# run that crosses the header's size is written out whole, so the output
# can overrun the size by up to 17 (LZ77) or 129 (RL) bytes, as on the
# console. The size is only checked between tokens.

proc hle_lz77_8bit[B](cpu: ArmCpu[B]) =
  ## LZ77UnCompReadNormalWrite8bit (11h). r0/r1 come back past the stream
  ## and the output.
  mixin read8, read32, write8
  var src = cpu.r[0]
  let header = read32(cpu.bus, src and not 3'u32)
  src += 4
  if not cpu.src_ok(src, header shr 8): return
  var remaining = int64(header shr 8)
  var dst = cpu.r[1]
  while remaining > 0:
    let flags = read8(cpu.bus, src)
    src += 1
    for i in 0 ..< 8:
      if (flags and (0x80'u32 shr i)) != 0:
        let b1 = read8(cpu.bus, src)
        let b2 = read8(cpu.bus, src + 1)
        src += 2
        let length = (b1 shr 4) + 3
        let disp = (((b1 and 0xF) shl 8) or b2) + 1
        for _ in 0'u32 ..< length:
          write8(cpu.bus, dst, uint8(read8(cpu.bus, dst - disp)))
          dst += 1
        remaining -= int64(length)
      else:
        write8(cpu.bus, dst, uint8(read8(cpu.bus, src)))
        src += 1
        dst += 1
        remaining -= 1
      if remaining <= 0: break
  cpu.r[0] = src
  cpu.r[1] = dst

proc hle_rl_8bit[B](cpu: ArmCpu[B]) =
  ## RLUnCompReadNormalWrite8bit (14h). r1 comes back past the output, and
  ## on the ARM9 r0 past the stream.
  mixin armv5, read8, read32, write8
  var src = cpu.r[0]
  let header = read32(cpu.bus, src and not 3'u32)
  src += 4
  if not cpu.src_ok(src, header shr 8): return
  var remaining = int64(header shr 8)
  var dst = cpu.r[1]
  while remaining > 0:
    let flag = read8(cpu.bus, src)
    src += 1
    if (flag and 0x80) != 0:
      let length = (flag and 0x7F) + 3
      let v = read8(cpu.bus, src)
      src += 1
      for _ in 0'u32 ..< length:
        write8(cpu.bus, dst, uint8(v))
        dst += 1
      remaining -= int64(length)
    else:
      let length = (flag and 0x7F) + 1
      for _ in 0'u32 ..< length:
        write8(cpu.bus, dst, uint8(read8(cpu.bus, src)))
        src += 1
        dst += 1
      remaining -= int64(length)
  when armv5(B): cpu.r[0] = src
  cpu.r[1] = dst

proc hle_diff8[B](cpu: ArmCpu[B]) =
  ## Diff8bitUnFilterWrite8bit (16h, ARM9). r0/r1 come back past the data.
  mixin read8, read32, write8
  var src = cpu.r[0]
  let header = read32(cpu.bus, src and not 3'u32)
  let length = header shr 8
  src += 4
  if length == 0: return
  var dst = cpu.r[1]
  var v = 0'u32
  for i in 0'u32 ..< length:
    v = if i == 0: read8(cpu.bus, src) else: (v + read8(cpu.bus, src)) and 0xFF
    src += 1
    write8(cpu.bus, dst, uint8(v))
    dst += 1
  cpu.r[0] = src
  cpu.r[1] = dst

proc hle_diff16[B](cpu: ArmCpu[B]) =
  ## Diff16bitUnFilter (18h, ARM9). r0/r1 come back past the data.
  mixin read16, read32, write16
  var src = cpu.r[0]
  let header = read32(cpu.bus, src and not 3'u32)
  let length = header shr 8
  src += 4
  if length < 2: return
  var dst = cpu.r[1]
  var v = 0'u32
  var done = 0'u32
  while done < length:
    let d = read16(cpu.bus, src and not 1'u32)
    v = if done == 0: d else: (v + d) and 0xFFFF
    src += 2
    write16(cpu.bus, dst and not 1'u32, uint16(v))
    dst += 2
    done += 2
  cpu.r[0] = src
  cpu.r[1] = dst

proc hle_soft_reset[B](cpu: ArmCpu[B]) =
  ## SoftReset (00h): clear the BIOS RAM area, reset the stacks and r0-r12,
  ## lr/spsr of SVC and IRQ, enter System mode (IRQs on, FIQs off, as on
  ## the console) and `bx [return address]`.
  ## The ARM9 also sets CP15 control to 0x12078 and invalidates both
  ## caches, the data cache without cleaning it (GBATEK "BIOS Reset
  ## Functions": "flushes caches"; the ARM9 BIOS's routine at 0xFFFF0778,
  ## called from its SoftReset, writes control then C7,C5,0 and C7,C6,0
  ## and drains the write buffer).
  mixin armv5, read32, write32, cp15_read, cp15_write
  var sp_svc, sp_irq, sp_sys, clear_base, entry_ptr: uint32
  when armv5(B):
    cp15_write(cpu.bus, 0, 1, 0, 0, 0x00012078'u32)
    cp15_write(cpu.bus, 0, 7, 5, 0, 0)
    cp15_write(cpu.bus, 0, 7, 6, 0, 0)
    let dtcm = cp15_read(cpu.bus, 0, 9, 1, 0) and 0xFFFFF000'u32
    sp_svc = 0x00803FC0'u32; sp_irq = 0x00803FA0'u32; sp_sys = 0x00803EC0'u32
    clear_base = dtcm + 0x3E00
    entry_ptr = 0x027FFE24'u32
  else:
    sp_svc = 0x0380FFDC'u32; sp_irq = 0x0380FFB0'u32; sp_sys = 0x0380FF00'u32
    clear_base = 0x0380FE00'u32
    entry_ptr = 0x027FFE34'u32
  for i in countup(0'u32, 0x1FC, 4): write32(cpu.bus, clear_base + i, 0)
  for (m, sp) in [(mSVC, sp_svc), (mIRQ, sp_irq)]:
    cpu.set_cpsr(uint32(m) or FLAG_I or FLAG_F)
    cpu.r[13] = sp
    cpu.r[14] = 0
    cpu.spsr = 0x10   # an MSR of 0: mode bit 4 is wired high on both cores
  cpu.set_cpsr(uint32(mSYS) or FLAG_F)
  cpu.r[13] = sp_sys
  for i in 0..12: cpu.r[i] = 0
  let entry = read32(cpu.bus, entry_ptr)
  cpu.r[14] = entry
  cpu.jump_interwork(entry)

# ---------------------------------------------------------------------------
# Dispatch

proc hle_overhead[B](cpu: ArmCpu[B]; comment, r2: uint32) =
  ## The cycles the console's BIOS spends on top of the memory accesses the
  ## Nim code makes (those go through the bus and are charged there): SWI
  ## entry and return plus the loop's instructions. Measured by running the
  ## BIOS dumps' own code in this core (timing.nim; ARM9 with protection
  ## unit and caches on, as programs run) on 8/64/512-unit calls and fitted
  ## as base + per unit; master cycles. Without it an HLE run drifted a
  ## frame ahead of the real BIOS (nds-examples allocation_test, which
  ## copies its sprites with CpuSet; docs/nds/compat.md).
  mixin armv5
  let units = int64(r2 and 0x1FFFFF)
  let fill = (r2 and (1'u32 shl 24)) != 0
  let word = (r2 and (1'u32 shl 26)) != 0
  var c: int64
  when armv5(B):
    case comment
    of 0x0B: c = 300 + units * (if fill: (if word: 6 else: 7) else: (if word: 8 else: 9))
    of 0x0C: c = 300 + units * (if fill: 4 else: 5)
    of 0x09: c = 620
    of 0x0D: c = 1200
    of 0x0E: c = 360 + int64(r2) * 54
    else: c = 0
    cpu.icycles += c
  else:
    case comment
    of 0x0B: c = 150 + units * (if fill: (if word: 26 else: 28) else: (if word: 14 else: 16))
    of 0x0C: c = 170 + units * (if fill: 19 else: 2)
    of 0x09: c = 640
    of 0x0D: c = 1600
    of 0x0E: c = 120 + int64(r2) * 114
    else: c = 0
    cpu.icycles += c div 2   # ARM7 clocks: step doubles them

proc hle_swi*[B](cpu: ArmCpu[B]; comment: uint32): bool =
  ## Run SWI `comment` in Nim (true), or leave it to the BIOS image's SWI
  ## vector (false: the guest-code SWIs in hle_bios.s). Unknown numbers,
  ## which the console sends to the debug handler, do nothing.
  mixin armv5, read32, write8, write16, write32, cp15_write, data_cached
  result = true
  cpu.hle_overhead(comment, cpu.r[2])
  case comment
  of 0x00: cpu.hle_soft_reset()
  of 0x03, 0x04, 0x05, 0x12, 0x13, 0x15: return false
  of 0x06:  # Halt
    when armv5(B):
      cpu.r[0] = 0
      cp15_write(cpu.bus, 0, 7, 0, 4, 0)
    else:
      write8(cpu.bus, 0x04000301'u32, 0x80'u8)
  of 0x09: cpu.hle_div()
  of 0x0B: cpu.hle_cpu_set()
  of 0x0C: cpu.hle_cpu_fast_set()
  of 0x0D: cpu.hle_sqrt()
  of 0x0E: cpu.hle_crc16()
  of 0x0F:  # IsDebugger: a retail 4 MB console; the BIOS's probe scribbles
            # a halfword it leaves zero. On the ARM9 with the data cache
            # over the probe (the scratch halfword or its mirror 4 MB below)
            # it reports 8 MB (GBATEK "IsDebugger": "Fails on ARM9 when
            # cache is enabled (always returns 8MB state)"; the real BIOS
            # does the same under bus9.nim's data cache)
    let scratch = (when armv5(B): 0x027FFFF8'u32 else: 0x027FFFFA'u32)
    write16(cpu.bus, scratch, 0)
    cpu.r[0] = (if data_cached(cpu.bus, scratch) or data_cached(cpu.bus, scratch - 0x40_0000):
                  1'u32 else: 0'u32)
    cpu.r[1] = 0
  of 0x10: cpu.hle_bit_unpack()
  of 0x11: cpu.hle_lz77_8bit()
  of 0x14: cpu.hle_rl_8bit()
  of 0x16:
    when armv5(B): cpu.hle_diff8()
  of 0x18:
    when armv5(B): cpu.hle_diff16()
  of 0x07:  # Sleep (ARM7)
    when not armv5(B): write8(cpu.bus, 0x04000301'u32, 0xC0'u8)
  of 0x08:  # SoundBias (ARM7): ramp SOUNDBIAS to 0 or 0x200 (at once here,
            # the r1 delay per step is not spent); r3 = the register
    when not armv5(B):
      write16(cpu.bus, 0x04000504'u32, if cpu.r[0] == 0: 0'u16 else: 0x200'u16)
      cpu.r[3] = 0x04000504'u32
  of 0x1A:  # GetSineTable (ARM7)
    when not armv5(B): cpu.r[0] = SINE_TABLE[cpu.r[0] and 63]
  of 0x1B:  # GetPitchTable (ARM7)
    when not armv5(B): cpu.r[0] = PITCH_TABLE[int(cpu.r[0] mod 768)]
  of 0x1C:  # GetVolumeTable (ARM7)
    when not armv5(B): cpu.r[0] = VOLUME_TABLE[int(cpu.r[0] mod 724)]
  of 0x1F:
    when armv5(B): write32(cpu.bus, 0x04000300'u32, cpu.r[0])   # CustomPost
    else: write8(cpu.bus, 0x04000301'u32, uint8(cpu.r[2]))       # CustomHalt
  else: discard
