# HLE of the BIOS-resident MP2K sound driver (included by hle_bios.nim).
#
# Provenance. Every law here was established by running the real BIOS image
# inside dingbat and observing what it does -- register writes, RAM stores
# and reads, cycle stamps -- with probe ROMs that drive the driver through its
# SWIs (tools/biosdrv: *.c probes, tests/biosdrv_probe.nim, compare.py). No
# BIOS code was read or transcribed. Structure names follow GBATEK "BIOS
# Sound Functions" (SoundArea, SoundDriverMode's bit fields).
#
# Costs. The routines' time is charged as measured; "IWRAM" costs are for a
# SoundArea in IWRAM and every SoundArea access adds its region's wait over
# IWRAM's single cycle (sd_x: an EWRAM area pays +5 per word, +2 per
# byte/halfword, checked on Init, Mode, VSync, VSyncOff and ChannelClear).
#
# Routines that wait for VCOUNT (Init, Mode with a rate) or run long with
# the driver locked (Mode's and VSyncOff's buffer clear) run as stub-BIOS
# code, so IRQs land at their true cycle and the lock is visible to handlers:
# the HLE applies the effects, then parks the CPU in System mode (the mode
# the BIOS runs its routines in, IRQ mask from the caller) in a delay loop or
# the VCOUNT poll at SD_STUB, and a `swi 0` there traps back for the next
# phase (hle_swi 0x00). The caller's return state lives in a frame on the
# System stack and the phase in r9, so a save state taken mid-routine
# resumes it.

const
  SD_IDENT = 0x68736D53'u32       # SoundArea ident when idle ('Smsh')
  SD_INFO_PTR = 0x03007FF0'u32    # BIOS variable: the SoundArea pointer
  SD_BUF = 0x350'u32              # pcmBuffer offset in the SoundArea
  SD_BUF_BYTES = 0xC60'u32        # two 0x630-byte halves (FIFO A, FIFO B)
  SD_AREA_BYTES = 0xFB0'u32
  # Stub-BIOS continuation code (bus.nim new_bus), ARM:
  #   0x3900 subs r8, r8, #1 / bne 0x3900 / swi 0      delay loop
  #   0x3910 ldrh r1, [r0, #6] / cmp r1, #159 / beq 0x3928   VCOUNT check,
  #   0x391C ldrh r1, [r0, #6] / cmp r1, #159 / bne 0x391C   then the poll
  #   0x3928 swi 0
  # The real routine reads VCOUNT once, then polls every 7 cycles from 5
  # later (BD_IOREAD stamps); the stub's check-then-loop has that phase.
  SD_STUB_DELAY = 0x3900'u32
  SD_STUB_POLL = 0x3910'u32
  SD_TRAP_DELAY* = 0x3910'u32     # r15 while the delay loop's swi traps
  SD_TRAP_POLL* = 0x3930'u32      # r15 while the poll loop's swi traps
  # Phases (r9) of a routine parked in the stub
  SD_PH_INIT = 1'u32      # Init: setup done, rate registers next
  SD_PH_MODE_A = 2'u32    # Mode: buffer clear done, rate fields next
  SD_PH_POLL = 3'u32      # delay done, poll VCOUNT next
  SD_PH_VSOFF = 4'u32     # VSyncOff: buffer clear done, unlock and return
  SD_FRAME_WORDS = 10     # r2, r4-r9, r12, return address, caller CPSR

# Samples per V-blank for rate indices 1-15 (0 keeps the rate). 1-12 are
# GBATEK's table; 13 and 14 read 0xFFFF and 15 reads 31 on the real BIOS
# (mode probe, tools/biosdrv/mode.c and init.c).
const SD_SPV = [0'u32, 96, 132, 176, 224, 264, 304, 352, 448, 528, 608, 672,
                704, 0xFFFF, 0xFFFF, 31]

proc sd_area(cpu: CPU): uint32 {.inline.} =
  cpu.gba.bus.read_word_internal(SD_INFO_PTR)

proc sd_ident(cpu: CPU; area: uint32): uint32 {.inline.} =
  ## The ident word the routines check. A null (BIOS-region) pointer reads
  ## the BIOS itself, which never matches.
  if area < 0x02000000'u32:
    let o = int(area and 0x3FFC'u32)
    let b = cpu.gba.bus.bios
    return uint32(b[o]) or (uint32(b[o + 1]) shl 8) or (uint32(b[o + 2]) shl 16) or
           (uint32(b[o + 3]) shl 24)
  cpu.gba.bus.read_word_internal(area)

# Register results. Every routine leaves r3 = 0x170 (the dispatcher's return
# address) unless noted; a refusal leaves the ident word it read in r0, r1 or
# r3 (guard.c: all seven idents, null and valid pointers).
const SD_R3 = 0x170'u32

proc sd_x(cpu: CPU; area: uint32; word: bool): int {.inline.} =
  ## Extra cycles of one SoundArea access over IWRAM's single cycle.
  let page = int(bits_range(area, 24, 27))
  if word: int(cpu.gba.bus.wait32_n[page]) - 1 else: int(cpu.gba.bus.wait16_n[page]) - 1

proc sd_div_cost(n, d: uint32): int {.inline.} =
  ## The driver divides with the same loop as SWI 6 (Div): each of its four
  ## divisions costs div_body_cycles plus a fixed call overhead (rate-sweep
  ## intervals between the stores, mode.c/init.c, exact on all 15 rates).
  div_body_cycles(n, d)

type SdRate = object
  spv, period, freq, divfreq, reload: uint32
  cost: int   # the four divisions' input-dependent part

proc sd_rate(index: int): SdRate =
  ## SoundDriverMode's rate fields (GBATEK: samples per V-blank from the rate
  ## index; the rest derived): period = 1584 / spv (pcmBuffer half / spv),
  ## freq = (spv * 597275 + 5000) / 10000 in 32-bit arithmetic (index 13's
  ## 48771 is the wrapped product), divfreq = (2^24 / freq + 1) >> 1, and
  ## Timer 0 reloads 0x10000 - 280896 / spv (one frame's cycles per sample).
  ## Every value matched the real BIOS's stores for all 15 indices.
  let spv = SD_SPV[index and 15]
  result.spv = spv
  result.period = (1584'u32 div spv) and 0xFF
  let prod = spv * 597275'u32 + 5000'u32
  result.freq = prod div 10000'u32
  result.divfreq = ((16777216'u32 div result.freq) + 1) shr 1
  result.reload = (0x10000'u32 - 280896'u32 div spv) and 0xFFFF
  result.cost = sd_div_cost(1584, spv) + sd_div_cost(prod, 10000) +
                sd_div_cost(16777216, result.freq) + sd_div_cost(280896, spv)

proc sd_write_rate_fields(cpu: CPU; area: uint32; index: int): SdRate =
  let bus = cpu.gba.bus
  result = sd_rate(index)
  bus.write_byte_internal(area + 0x08, uint8(index))
  bus.write_word_internal(area + 0x10, result.spv)
  bus.write_byte_internal(area + 0x0B, uint8(result.period))
  bus.write_word_internal(area + 0x14, result.freq)
  bus.write_word_internal(area + 0x18, result.divfreq)

proc sd_rate_registers(cpu: CPU; r: SdRate) =
  ## Timer 0 stopped and reloaded for the new rate, both sound DMAs armed
  ## (repeat, 32-bit, FIFO timing); the timer starts on line 159.
  let bus = cpu.gba.bus
  bus.write_half(0x04000102'u32, 0)
  bus.write_half(0x04000100'u32, uint16(r.reload))
  bus.write_half(0x040000C6'u32, 0xB600'u16)
  bus.write_half(0x040000D2'u32, 0xB600'u16)

proc sd_clear_buffer(cpu: CPU; area: uint32) =
  for o in countup(0'u32, SD_BUF_BYTES - 4, 4):
    cpu.gba.bus.write_word_internal(area + SD_BUF + o, 0)

# --- Stub continuation ---

# Net cost of a trap's own swi: hle_swi charged the dispatch and a refill for
# it, which the real routine does not run. Fitted with SD_ENTRY_SKEW from the
# first VCOUNT poll, which Init reaches through one trap and Mode through
# two: at 45 / 47 Init's poll lands a cycle late / early and Mode's two.
const SD_TRAP_COST {.intdefine.} = 46

proc sd_stub_goto(cpu: CPU; target: uint32; step: uint32) {.inline.} =
  discard cpu.set_reg(15, target - step)

proc sd_delay(cpu: CPU; cycles: int; step: uint32) =
  ## Run `cycles` in the stub's delay loop (4 per pass, 2 for the last),
  ## then trap. The remainder the loop cannot express is charged up front.
  var n = (cycles + 2) div 4
  if n < 1: n = 1
  let rem = cycles - (4 * n - 2)
  if rem > 0: cpu.idle(rem)
  cpu.r[8] = uint32(n)
  cpu.sd_stub_goto(SD_STUB_DELAY, step)

proc sd_enter(cpu: CPU; phase: uint32; delay: int; r4 = 0'u32; r5 = 0'u32) =
  ## Park the SWI's caller: save its return state on the System stack below
  ## the dispatcher frame, switch to System mode with the caller's IRQ mask,
  ## and run `delay` cycles of stub delay before phase `phase`.
  let step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
  let ret = cpu.r[15] - step
  let caller = uint32(cpu.cpsr)
  # hle_swi charged the return's refill up front (N + S + S16 - 1 in the
  # caller's region); a parked routine pays its refill on the way out
  # instead. What stays is the dispatcher's `ldrb` of the SWI number from the
  # caller's code, N16 there (romcall.c: ARM and Thumb, ROM at WAITCNT 0 and
  # 0x4317, EWRAM; the IWRAM caller is the calibration's zero).
  block:
    let bus = cpu.gba.bus
    let page = int(bits_range(ret, 24, 27))
    let refill = if cpu.cpsr.thumb:
        int(bus.wait16_n[page]) + 2 * int(bus.wait16_s[page]) - 1
      else:
        int(bus.wait32_n[page]) + int(bus.wait32_s[page]) + int(bus.wait16_s[page]) - 1
    bus.add_cycles(-(refill - 2) + (int(bus.wait16_n[page]) - 1))
  let fb = cpu.sys_sp() - 8 - uint32(SD_FRAME_WORDS * 4)
  let bus = cpu.gba.bus
  for i, v in [cpu.r[2], cpu.r[4], cpu.r[5], cpu.r[6], cpu.r[7], cpu.r[8],
               cpu.r[9], cpu.r[12], ret, caller]:
    bus.write_word_internal(fb + uint32(i * 4), v)
  cpu.switch_mode(modeSYS)
  cpu.cpsr = toPSR(0x1F'u32 or (caller and 0x80'u32))
  cpu.r[13] = fb
  cpu.r[4] = r4
  cpu.r[5] = r5
  cpu.r[9] = phase
  cpu.sd_delay(delay, step)

proc sd_leave(cpu: CPU; exit_cost: int) =
  ## Return to the parked caller (a trap is executing: ARM step 4).
  let bus = cpu.gba.bus
  let fb = cpu.r[13]
  var v: array[SD_FRAME_WORDS, uint32]
  for i in 0 ..< SD_FRAME_WORDS: v[i] = bus.read_word_internal(fb + uint32(i * 4))
  cpu.r[2] = v[0]; cpu.r[4] = v[1]; cpu.r[5] = v[2]; cpu.r[6] = v[3]
  cpu.r[7] = v[4]; cpu.r[8] = v[5]; cpu.r[9] = v[6]; cpu.r[12] = v[7]
  cpu.r[13] = fb + uint32(SD_FRAME_WORDS * 4) + 8
  let caller = v[9]
  cpu.switch_mode(cast[CpuMode](caller and 0x1F'u32))
  cpu.cpsr = toPSR(caller)
  # The exit path's cost; the refill into the caller's code region is the
  # pipeline's own (set_reg below). Into the cartridge the real return's
  # refill costs N - S less than that refill charges (romcall.c at WAITCNT
  # 0, 0x4317, 0x000C and 0x0018: 2, 2, 6 and 1 cycles, ARM and Thumb).
  let page = int(bits_range(v[8], 24, 27))
  var adj = 0
  if page >= 0x8 and page <= 0xD:
    adj = int(bus.wait16_n[page]) - int(bus.wait16_s[page])
  bus.add_cycles(exit_cost - adj)
  bus.bios_latch = 0xE3A02004'u32
  cpu.sd_stub_goto(v[8], 4)

# --- The routines ---

# Cycle model, measured on the real BIOS with an IWRAM SoundArea and an
# IWRAM ARM caller (the probe wrappers; romcall.c covers the other caller
# regions, sd_x the other SoundArea regions). Offsets from the wrapper's
# pre-SWI marker, read off BD_MEMTRACE/BD_IOREAD stamps:
#  - the first VCOUNT poll: Init 7893, Mode with a rate and no other field
#    6427; both include the four rate divisions (sd_rate.cost; rate 4 = 531),
#    so the constants hold the rest. Exact for all 15 rate indices and all
#    16 field subsets (init.c, mode.c).
#  - the lock stores: Mode's ident drops from +2 back to +1 at 5739, VSyncOff
#    unlocks at 5672 (both only split a delay: the totals do not move).
# The HLE-side constants below were fitted against those; each is exact and
# a cycle either way shows: SD_ENTRY_SKEW 74/76 moves every parked
# routine's first poll one cycle early/late; SD_POLL_TIMER -4/-2 moves the
# Timer 0 start (6 cycles after the poll that sees line 159) one cycle
# early/late; SD_POLL_EXIT 38/40 and SD_VSOFF_EXIT 43/45 move the caller's
# next instruction (Mode 72, Init 74 cycles after the timer start; VSyncOff
# 5734 in all) one cycle early/late.
const
  SD_INIT_POLL0 {.intdefine.} = 7893 - 531
  SD_MODE_POLL0 {.intdefine.} = 6427 - 531
  SD_MODE_CLEAR_END {.intdefine.} = 5739
  SD_VSOFF_UNLOCK {.intdefine.} = 5672
  SD_POLL_EXIT {.intdefine.} = 39
  SD_VSOFF_EXIT {.intdefine.} = 44
  SD_ENTRY_SKEW {.intdefine.} = 75
  SD_POLL_TIMER {.intdefine.} = -3

proc sd_init(cpu: CPU) =
  let bus = cpu.gba.bus
  let area = cpu.r[0]
  bus.write_half(0x040000C6'u32, 0)
  bus.write_half(0x040000D2'u32, 0)
  bus.write_half(0x04000084'u32, 0x008F'u16)
  bus.write_half(0x04000082'u32, 0xA90E'u16)
  bus[0x04000089'u32] = (bus.read_byte_internal(0x04000089'u32) and 0x3F'u8) or 0x40'u8
  bus.write_word(0x040000BC'u32, area + SD_BUF)
  bus.write_word(0x040000C0'u32, 0x040000A0'u32)
  bus.write_word(0x040000C8'u32, area + SD_BUF + 0x630)
  bus.write_word(0x040000CC'u32, 0x040000A4'u32)
  bus.write_word_internal(SD_INFO_PTR, area)
  for o in countup(0'u32, SD_AREA_BYTES - 4, 4):
    bus.write_word_internal(area + o, 0)
  bus.write_byte_internal(area + 6, 8)
  bus.write_byte_internal(area + 7, 15)
  bus.write_word_internal(area + 0x38, 0x2425)
  for o in [0x28'u32, 0x2C, 0x30, 0x3C]:
    bus.write_word_internal(area + o, 0x1709)
  bus.write_word_internal(area + 0x34, 0x3738)
  # Area accesses: the clear (1004 words), six pointer words, the rate
  # fields (three words, two bytes) and the spv read back; two byte fields
  let x = 1014 * cpu.sd_x(area, true) + 4 * cpu.sd_x(area, false)
  let r = sd_rate(4)
  cpu.sd_enter(SD_PH_INIT, SD_INIT_POLL0 + r.cost + x - SD_ENTRY_SKEW)

proc sd_mode(cpu: CPU) =
  let bus = cpu.gba.bus
  let area = cpu.sd_area()
  let mode = cpu.r[0]
  let ident = cpu.sd_ident(area)
  cpu.r[3] = SD_R3
  if area < 0x02000000'u32 or ident != SD_IDENT:
    cpu.r[1] = ident
    cpu.idle(29)
    return
  cpu.r[1] = 0
  bus.write_word_internal(area, SD_IDENT + 1)
  # 143 cycles with no field set; per field, measured over all 16 subsets
  var cost = 143 - 82 + 2 * cpu.sd_x(area, true)
  if (mode and 0xFF'u32) != 0:
    bus.write_byte_internal(area + 5, uint8(mode and 0x7F))
    cost += 2 + cpu.sd_x(area, false)
  if (mode and 0xF00'u32) != 0:
    bus.write_byte_internal(area + 6, uint8((mode shr 8) and 0xF))
    for i in 0'u32 ..< 12'u32:
      bus.write_byte_internal(area + 0x50 + i * 0x40, 0)
    cost += 87 + 13 * cpu.sd_x(area, false)
  if (mode and 0xF000'u32) != 0:
    bus.write_byte_internal(area + 7, uint8((mode shr 12) and 0xF))
    cost += 1 + cpu.sd_x(area, false)
  if (mode and 0xF00000'u32) != 0:
    let hi = bus.read_byte_internal(0x04000089'u32)
    let nhi = (hi and 0x3F'u8) or uint8(((mode shr 20) and 3) shl 6)
    bus[0x04000089'u32] = nhi
    cpu.r[1] = uint32(nhi)
    cost += 12  # + the register write's own cycle
  let index = int((mode shr 16) and 0xF)
  if index == 0:
    bus.write_word_internal(area, SD_IDENT)
    cpu.r[0] = mode
    cpu.idle(cost + cpu.sd_x(area, true))
    return
  # Rate change: the VSyncOff body (nested lock, DMA off, counter 0, buffer
  # clear), then the rate fields and registers, then line 159
  bus.write_word_internal(area, SD_IDENT + 2)
  bus.write_half(0x040000C6'u32, 0)
  bus.write_half(0x040000D2'u32, 0)
  bus.write_byte_internal(area + 4, 0)
  cpu.sd_clear_buffer(area)
  let x_clear = 792 * cpu.sd_x(area, true) + 4 * cpu.sd_x(area, true) + cpu.sd_x(area, false)
  cpu.sd_enter(SD_PH_MODE_A, SD_MODE_CLEAR_END + (cost - (143 - 82)) + x_clear - SD_ENTRY_SKEW,
               area, uint32(index))

proc sd_vsync(cpu: CPU) =
  let bus = cpu.gba.bus
  let area = cpu.sd_area()
  let ident = cpu.sd_ident(area)
  if area < 0x02000000'u32 or ident != SD_IDENT:
    cpu.r[0] = area
    cpu.r[1] = 0
    cpu.r[3] = ident
    cpu.idle(16)
    return
  let old = bus.read_byte_internal(area + 4)
  let cnt = (old - 1'u8)
  bus.write_byte_internal(area + 4, cnt)
  if old <= 1:
    # 125 cycles: the counter restarts at pcmDmaPeriod and both sound DMAs
    # are restarted (disable, re-enable: the source reloads)
    bus.write_byte_internal(area + 4, bus.read_byte_internal(area + 0x0B))
    bus.write_half(0x040000C6'u32, 0)
    bus.write_half(0x040000D2'u32, 0)
    bus.write_half(0x040000C6'u32, 0xB600'u16)
    bus.write_half(0x040000D2'u32, 0xB600'u16)
    cpu.r[0] = 0
    cpu.r[1] = 0xB600
    cpu.r[3] = 0x040000D2'u32
    cpu.idle(125 - 82 - 4 + cpu.sd_x(area, true) + 4 * cpu.sd_x(area, false))
  else:
    cpu.r[0] = area
    cpu.r[1] = uint32(cnt)
    cpu.r[3] = SD_IDENT
    cpu.idle(105 - 82 + cpu.sd_x(area, true) + 2 * cpu.sd_x(area, false))

proc sd_vsync_off(cpu: CPU) =
  let bus = cpu.gba.bus
  let area = cpu.sd_area()
  let ident = cpu.sd_ident(area)
  if area < 0x02000000'u32 or (ident != SD_IDENT and ident != SD_IDENT + 1):
    cpu.r[0] = ident
    cpu.r[1] = 0
    cpu.r[3] = SD_R3
    # An ident below 'Smsh' is refused three cycles sooner (two compares)
    cpu.idle(if area >= 0x02000000'u32 and ident < SD_IDENT: 27 else: 30)
    return
  bus.write_word_internal(area, ident + 1)
  bus.write_half(0x040000C6'u32, 0)
  bus.write_half(0x040000D2'u32, 0)
  bus.write_byte_internal(area + 4, 0)
  cpu.sd_clear_buffer(area)
  let x = 792 * cpu.sd_x(area, true) + 3 * cpu.sd_x(area, true) + cpu.sd_x(area, false)
  cpu.sd_enter(SD_PH_VSOFF, SD_VSOFF_UNLOCK + x - SD_ENTRY_SKEW, area)

proc sd_vsync_on(cpu: CPU) =
  # No SoundArea check: both sound DMAs are armed as they stand
  let bus = cpu.gba.bus
  bus.write_half(0x040000C6'u32, 0xB600'u16)
  bus.write_half(0x040000D2'u32, 0xB600'u16)
  cpu.r[0] = 0x040000C0'u32
  cpu.r[1] = 0xB600
  cpu.idle(9 - 2)  # 91 cycles around the swi; the two writes charged 2

proc sd_channel_clear(cpu: CPU) =
  let bus = cpu.gba.bus
  let area = cpu.sd_area()
  let ident = cpu.sd_ident(area)
  cpu.r[1] = 0
  cpu.r[3] = SD_R3
  if area < 0x02000000'u32 or ident != SD_IDENT:
    cpu.r[0] = ident
    cpu.idle(31)
    return
  for i in 0'u32 ..< 12'u32:
    bus.write_byte_internal(area + 0x50 + i * 0x40, 0)
  cpu.r[0] = area + 0x350
  cpu.idle(232 - 82 + 4 * cpu.sd_x(area, true) + 12 * cpu.sd_x(area, false))

proc sd_trap(cpu: CPU): bool =
  ## A stub-continuation trap (hle_swi 0x00 at SD_TRAP_DELAY/SD_TRAP_POLL).
  ## False: not ours.
  let bus = cpu.gba.bus
  if cpu.r[15] == SD_TRAP_DELAY:
    bus.add_cycles(-SD_TRAP_COST)
    case cpu.r[9]
    of SD_PH_INIT:
      let area = bus.read_word_internal(SD_INFO_PTR)
      let r = cpu.sd_write_rate_fields(area, 4)
      cpu.sd_rate_registers(r)
      cpu.r[0] = 0x04000000'u32
      cpu.sd_stub_goto(SD_STUB_POLL, 4)
    of SD_PH_MODE_A:
      let area = cpu.r[4]
      bus.write_word_internal(area, SD_IDENT + 1)
      let r = cpu.sd_write_rate_fields(area, int(cpu.r[5]))
      cpu.sd_rate_registers(r)
      cpu.r[9] = SD_PH_POLL
      let x = 4 * cpu.sd_x(area, true) + 2 * cpu.sd_x(area, false)
      cpu.sd_delay(SD_MODE_POLL0 - SD_MODE_CLEAR_END + r.cost + x, 4)
    of SD_PH_POLL:
      cpu.r[0] = 0x04000000'u32
      cpu.sd_stub_goto(SD_STUB_POLL, 4)
    of SD_PH_VSOFF:
      let area = cpu.r[4]
      bus.write_word_internal(area, bus.read_word_internal(area) - 1)
      cpu.r[0] = bus.read_word_internal(area)
      cpu.r[1] = area + SD_AREA_BYTES
      cpu.r[3] = SD_R3
      cpu.sd_leave(SD_VSOFF_EXIT + cpu.sd_x(area, true))
    else:
      return false
    return true
  if cpu.r[15] == SD_TRAP_POLL:
    bus.add_cycles(-SD_TRAP_COST + SD_POLL_TIMER)
    bus.write_half(0x04000102'u32, 0x0080'u16)
    let area = bus.read_word_internal(SD_INFO_PTR)
    bus.write_word_internal(area, SD_IDENT)
    cpu.r[0] = if cpu.r[9] == SD_PH_INIT: SD_IDENT else: 0x80'u32
    cpu.r[1] = 0x9F
    cpu.r[3] = SD_R3
    # Init's exit runs two cycles longer than Mode's
    let tail = if cpu.r[9] == SD_PH_INIT: 2 else: 0
    cpu.sd_leave(SD_POLL_EXIT + tail + cpu.sd_x(area, true))
    return true
  false
