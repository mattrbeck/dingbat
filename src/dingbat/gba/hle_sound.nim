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
  SD_PH_SM_DONE = 5'u32   # SoundDriverMain: mixing time spent, unlock and return
  # SoundDriverMain's callback returns (the real routine's lr values, 0x1DF1
  # and 0x1DF9, hold Thumb `swi 0` traps in the stub): r15 while they trap
  SD_TRAP_SM_FUNC* = 0x1DF4'u32
  SD_TRAP_SM_CGB* = 0x1DFC'u32
  SD_FRAME_WORDS = 9      # r4-r9, r12, return address, caller CPSR

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
  var rem = cycles - (4 * n - 2)
  if rem == 3:
    # Three I-cycles ahead of the loop come out as four in some trap
    # contexts (BD_SWEEP: a Thumb trap, every fourth delay one long); a pass
    # more and one back is exact in all of them
    inc n
    rem = -1
  if rem != 0: cpu.gba.bus.add_cycles(rem)
  cpu.r[8] = uint32(n)
  cpu.sd_stub_goto(SD_STUB_DELAY, step)

proc sd_park(cpu: CPU) =
  ## Park the SWI's caller: its return state goes in a frame on the System
  ## stack below the dispatcher's {r2, lr} (hle_swi wrote that residue; r2
  ## comes back from it), and the CPU switches to System mode with the
  ## caller's IRQ mask, where the BIOS runs its routines. The frame is as
  ## deep as the real routine's pushes (nine words: SoundDriverMain's
  ## callbacks see the same sp; smain.c).
  let step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
  let ret = cpu.r[15] - step
  let caller = uint32(cpu.cpsr)
  # hle_swi charged the return's refill up front (N + S + S16 - 1 in the
  # caller's region); a parked routine pays its refill on the way out
  # instead. What stays is the dispatcher's `ldrb` of the SWI number from the
  # caller's code, N16 there (romcall.c: ARM and Thumb, ROM at WAITCNT 0,
  # 0x4317, 0x000C and 0x0018, EWRAM; the IWRAM caller is the calibration's
  # zero).
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
  for i, v in [cpu.r[4], cpu.r[5], cpu.r[6], cpu.r[7], cpu.r[8], cpu.r[9],
               cpu.r[12], ret, caller]:
    bus.write_word_internal(fb + uint32(i * 4), v)
  cpu.switch_mode(modeSYS)
  cpu.cpsr = toPSR(0x1F'u32 or (caller and 0x80'u32))
  cpu.r[13] = fb

proc sd_enter(cpu: CPU; phase: uint32; delay: int; r4 = 0'u32; r5 = 0'u32) =
  ## Park the caller and run `delay` cycles of stub delay before `phase`.
  let step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
  cpu.sd_park()
  cpu.r[4] = r4
  cpu.r[5] = r5
  cpu.r[9] = phase
  cpu.sd_delay(delay, step)

proc sd_leave(cpu: CPU; exit_cost: int) =
  ## Return to the parked caller (a trap is executing: ARM or Thumb stub).
  let step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
  let bus = cpu.gba.bus
  let fb = cpu.r[13]
  var v: array[SD_FRAME_WORDS, uint32]
  for i in 0 ..< SD_FRAME_WORDS: v[i] = bus.read_word_internal(fb + uint32(i * 4))
  cpu.r[4] = v[0]; cpu.r[5] = v[1]; cpu.r[6] = v[2]; cpu.r[7] = v[3]
  cpu.r[8] = v[4]; cpu.r[9] = v[5]; cpu.r[12] = v[6]
  let usp = fb + uint32(SD_FRAME_WORDS * 4) + 8
  cpu.r[2] = bus.read_word_internal(usp - 8)   # the dispatcher's pop
  cpu.r[14] = bus.read_word_internal(usp - 4)  # ... of the System lr too
  cpu.r[13] = usp
  let caller = v[8]
  cpu.switch_mode(cast[CpuMode](caller and 0x1F'u32))
  cpu.cpsr = toPSR(caller)
  # The exit path's cost; the refill into the caller's code region is the
  # pipeline's own (set_reg below). Into the cartridge the real return's
  # refill costs N - S less than that refill charges (romcall.c at WAITCNT
  # 0, 0x4317, 0x000C and 0x0018: 2, 2, 6 and 1 cycles, ARM and Thumb).
  let page = int(bits_range(v[7], 24, 27))
  var adj = 0
  if page >= 0x8 and page <= 0xD:
    adj = int(bus.wait16_n[page]) - int(bus.wait16_s[page])
  bus.add_cycles(exit_cost - adj)
  bus.bios_latch = 0xE3A02004'u32
  cpu.sd_stub_goto(v[7], step)

proc sd_call(cpu: CPU; target, arg, ret_lr: uint32; step: uint32) =
  ## Call guest code at `target` (bit 0 = Thumb) with r0 = arg, returning to
  ## the stub trap at ret_lr, as the BIOS's `bx` calls do. The real call
  ## reaches the callee later than this jump's own refill by an amount that
  ## depends on the callee's region and ISA (callee.c: a store at the
  ## callee's top, stamped, for ARM and Thumb callees in IWRAM, EWRAM and
  ## the cartridge at two WAITCNT settings, and the BIOS's own 0x1709):
  ## 8 in the cartridge, 20 for ARM in EWRAM, 10 otherwise (callee2.c:
  ## sixteen IWRAM addresses). Deviation: an ARM callee at the very start of
  ## IWRAM (0x03000000) was reached 10 cycles sooner by the real call in the
  ## probes, and this does not model that.
  let thumb = (target and 1'u32) != 0
  let page = bits_range(target, 24, 27)
  let late =
    if page >= 0x8 and page <= 0xD: 8
    elif page == 0x2 and not thumb: 20
    else: 10
  cpu.idle(late)
  cpu.r[0] = arg
  cpu.r[14] = ret_lr
  cpu.cpsr.thumb = thumb
  cpu.sd_stub_goto(target and not 1'u32, step)

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
  SD_MAIN_TO_FUNC {.intdefine.} = 18
  SD_MAIN_TO_CGB {.intdefine.} = 20
  SD_FUNC_TO_CGB {.intdefine.} = 6
  SD_MIX_BASE {.intdefine.} = 435
  SD_MAIN_EXIT {.intdefine.} = 60
  SD_TRAP_COST_T {.intdefine.} = 56
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

# --- SoundDriverMain: the PCM mixer ---
#
# Laws (mix*.c probe scenarios, the driver's own pcmBuffer after each pass):
#  - the pass fills slot period - (counter - 1) of both pcmBuffer halves, or
#    slot 0 when the counter is 0 or 1; signed, unchecked (a counter above
#    period + 1 lands below the ring, smain.c).
#  - reverb 0 clears the slot; otherwise each byte pair becomes
#    (A + B + A' + B') * reverb >> 9 of this slot and the next (slot 0 after
#    the ring's last), and a result whose byte is negative gets one added
#    (revfit*: 15k bytes, reverb 127-255, overflowing ones included; a plain
#    floor misses 40%, truncation toward zero 1%).
#  - channels 0 .. maxChans-1 (SoundInfo +6, at most 12; 0 means 256) are
#    visited; one with none of START/STOP/IEC/ENV (0xC7) set is skipped.
#  - envelope per pass: START sets attack (phase 3) and ev 0 and falls into
#    attack; attack adds the rate, reaching 255 moves to decay (2); decay is
#    ev * rate >> 8, reaching sustain or below clamps to it and moves to
#    sustain (1); the gain is v = ev * (master + 1) >> 4, right = v * vr >> 8,
#    left = v * vl >> 8.
#  - each output byte adds sample * gain >> 8 (floor), wrapping at 8 bits;
#    FIFO A (first half) takes the right gain, B the left.
#  - fixed-rate channels (type & 8) take one source sample per output;
#    others step a phase accumulator: before each output, while acc >=
#    pcmFreq take the next sample and subtract; after it add the channel's
#    frequency (+0x20). The accumulator lives at +0x1C. Their output is
#    interpolated: s0 + ((s1 - s0) * (acc * divFreq) >> 23), s1 being the
#    byte after s0 in memory (interp*.c: 0 misses in 45k outputs at rates
#    1-12; truncating acc * divFreq by up to 3 bits first is
#    indistinguishable, by 4 or more is not; a true division is not).
#  - a sample's end: count (+0x18) reaches 0 after the last byte is taken;
#    a looping sample (WaveData +2 bit 14, status bit 0x10 from START)
#    restarts at loopStart with count = size - loopStart; a one-shot one
#    stops the channel (status 0) and the pass mixes nothing more of it,
#    leaving +0x18/+0x1C/+0x28 as they were before the pass.
#  - release (STOP): ev = ev * rate >> 8; at or below the echo volume
#    (+0x0C) the channel stops when that is 0, else holds it with IEC set
#    for echo-length (+0x0D) more passes, decremented each pass, stopping at
#    0. START with STOP just stops. A stopped channel mixes nothing that pass
#    and keeps its ev/er/el.

proc sd_s8(bus: Bus; a: uint32): int {.inline.} =
  int(cast[int8](bus.read_byte_internal(a)))

proc sd_adv_cost(n: int): int {.inline.} =
  ## The resampler's cost for taking n source samples before an output,
  ## beyond an output that takes none: 9 per four, 3 for a pair, 6 for a
  ## single, 9 to enter, 4 more below four (tres/tfast/tfast2: every n from 1
  ## to 30, three memory settings, exact).
  if n == 0: return 0
  result = 9 + 9 * (n shr 2) + 3 * ((n shr 1) and 1) + 6 * (n and 1)
  if n < 4: result += 4

proc sd_wrap_cost(n, k: int): int {.inline.} =
  ## Extra cost of a loop wrap on the k-th (1-based) of n advances. The
  ## advances go in fours, then a pair, then a single; a wrap costs by the
  ## group it lands in, and every group after it costs more (twrap, twrap2:
  ## n 1-16, every position): single 7; pair 20; four 34; each later four
  ## +31, a later pair +17, a later single +4.
  let fours = n shr 2
  let pair = (n shr 1) and 1
  let single = n and 1
  if k <= fours * 4:
    let later = fours - 1 - (k - 1) div 4
    result = 34 + 31 * later + (if pair != 0: 17 else: 0) + (if single != 0: 4 else: 0)
  elif k <= fours * 4 + 2 * pair:
    result = 20 + (if single != 0: 4 else: 0)
  else:
    result = 7

# The mixer's cost model (mix*.c probes, the real BIOS's store and read
# stamps: tools/biosdrv/mixfit.py). Cycles are split into the mixer's own
# (constants here, measured with the SoundArea in IWRAM) and its memory
# accesses, charged at their regions' waits: aw/ab a word/byte of the
# SoundArea, sw a word of the WaveData header, sb a byte (or the flags
# halfword) of the sample. A channel's span runs from its status read to the
# next channel's; its first output is inside its setup.
type SdPath = tuple[base, aw, ab, sw, sb: int]
const
  # fixed-rate, looping sample; by envelope path (status before > after)
  SD_P_SUS: SdPath = (107, 2, 14, 2, 1)        # 11>11: 144 at WAITCNT 0
  SD_P_DEC_REACH: SdPath = (117, 2, 17, 2, 1)  # 12>11: 157
  SD_P_ENV_STEP: SdPath = (112, 2, 15, 2, 1)   # 13>13, 12>12: 150-151
  SD_P_ATK_REACH: SdPath = (114, 2, 15, 2, 1)  # 13>12: 152
  SD_P_REL: SdPath = (106, 2, 16, 2, 1)        # x>5x: 145
  SD_P_REL_IEC: SdPath = (114, 2, 18, 2, 1)    # 13>57: 155
  SD_P_IEC: SdPath = (97, 2, 16, 2, 1)         # 57>57: 136
  SD_P_START: SdPath = (116, 5, 18, 3, 2)      # 80>12: 173
  SD_P_START_ATK: SdPath = (115, 5, 17, 3, 2)  # 80>13: 171
  # a one-shot sample skips the loop bookkeeping: 10 fewer cycles and two
  # header words (14 and two when starting); resampled channels add 28 (27
  # when starting), two SoundArea words and the second sample byte
  SD_OUT_FIX = 22       # per output beyond the first, + 4 ab + 1 sb
  SD_OUT_RES = 31       # the same resampled, + 4 ab + 2 sb + advances
  SD_WRAP_FIX = 8
  SD_TAIL_FIX = 32      # last output to the next status read, + 3 aw + 1 ab
  SD_TAIL_RES = 29      # + 4 aw + 1 ab
  SD_TAIL_END = 33      # a one-shot end mid-pass (+18 resampled), + aw + 2 ab
  SD_VISIT = 21         # an idle channel, + aw + ab
  SD_OFF = 30           # a channel the envelope stops (approximate)
  SD_MIX_PRE {.intdefine.} = 400
  SD_MIX_POST {.intdefine.} = 70

proc sd_mix(cpu: CPU; area: uint32): int =
  ## Mixes one pass into pcmBuffer; returns its cycle cost.
  let bus = cpu.gba.bus
  template n16(a: uint32): int = int(bus.wait16_n[int(bits_range(a, 24, 27))])
  template n32(a: uint32): int = int(bus.wait32_n[int(bits_range(a, 24, 27))])
  let aw = n32(area)
  let ab = n16(area)
  let spv = bus.read_word_internal(area + 0x10)
  let cnt = int(bus.read_byte_internal(area + 4))
  let period = int(bus.read_byte_internal(area + 0x0B))
  let reverb = int(bus.read_byte_internal(area + 5))
  let slot = if cnt >= 2: period - cnt + 1 else: 0
  let a0 = area + SD_BUF + cast[uint32](int32(slot) * int32(spv))
  let b0 = a0 + 0x630
  # (the slot multiply takes a cycle more for 256 samples or more)
  # (the SoundInfo reads before the mix: three words, four bytes)
  result = SD_MIX_PRE + 3 * (aw - 1) + 4 * (ab - 1)
  if cnt >= 2:
    result += 6
    if spv >= 256: result += 1
  if reverb == 0:
    for i in 0'u32 ..< spv:
      bus.write_byte_internal(b0 + i, 0)
      bus.write_byte_internal(a0 + i, 0)
    # word stores, 16 bytes of each half per 20 cycles (smain.c: rates 1, 4,
    # 12), the 4 or 8 bytes over a multiple of 16 for 2 or 6 more (rates 2
    # and 5: mix_interp4/5)
    result += int(spv div 16) * (12 + 8 * aw)
    let rest = int(spv and 15)
    if rest != 0: result += (rest div 4) * (2 + 2 * aw) - 2
  else:
    # The other tap is the next slot, the ring's first after its last
    let nxt = if slot + 1 < period: spv else: cast[uint32](-int32(slot) * int32(spv))
    for i in 0'u32 ..< spv:
      let x = bus.sd_s8(b0 + i) + bus.sd_s8(a0 + i) + bus.sd_s8(b0 + nxt + i) +
              bus.sd_s8(a0 + nxt + i)
      var y = uint8((ashr(x * reverb, 9)) and 0xFF)
      if y >= 0x80'u8: y += 1   # a negative byte moves one step toward zero
      bus.write_byte_internal(b0 + i, y)
      bus.write_byte_internal(a0 + i, y)
    # four byte reads and two stores a sample: 28 each (smain.c)
    result += int(spv) * (22 + 6 * ab) - 1
  let pcmfreq = bus.read_word_internal(area + 0x14)
  let divfreq = bus.read_word_internal(area + 0x18)
  let master = int(bus.read_byte_internal(area + 7))
  # maxChans above 12 visits 12; 0 counts down from 256 (misc.c; Cyberdrive
  # Zoids keeps 50 there and the real BIOS visits 12)
  var nch = int(bus.read_byte_internal(area + 6))
  if nch > 12: nch = 12
  if nch == 0: nch = 256
  for c in 0 ..< nch:
    let ch = area + 0x50 + uint32(c) * 0x40
    var st = bus.read_byte_internal(ch)
    if (st and 0xC7'u8) == 0:
      result += SD_VISIT + aw + ab
      continue
    let wav = bus.read_word_internal(ch + 0x24)
    var ev = int(bus.read_byte_internal(ch + 9))
    var off = false
    let started = (st and 0x80'u8) != 0
    var path: SdPath
    if started:
      if (st and 0x40'u8) != 0:
        bus.write_byte_internal(ch, 0)   # note-on and note-off together
        result += SD_OFF + aw + 2 * ab
        continue
      st = 0x03'u8
      if (bus.read_half_internal(wav + 2) and 0x4000'u16) != 0: st = st or 0x10'u8
      ev = 0
      bus.write_word_internal(ch + 0x18, bus.read_word_internal(wav + 12))
      bus.write_word_internal(ch + 0x28, wav + 16)
      bus.write_word_internal(ch + 0x1C, 0)
    if (st and 0x04'u8) != 0:
      # Pseudo-echo hold: the level stays at the echo volume for echo-length
      # more passes
      let n = bus.read_byte_internal(ch + 0x0D) - 1
      bus.write_byte_internal(ch + 0x0D, n)
      if n == 0: off = true
      path = SD_P_IEC
    elif (st and 0x40'u8) != 0:
      ev = (ev * int(bus.read_byte_internal(ch + 7))) shr 8
      let evol = int(bus.read_byte_internal(ch + 0x0C))
      path = SD_P_REL
      if ev <= evol:
        if evol == 0: off = true
        else:
          st = st or 0x04'u8
          ev = evol
          path = SD_P_REL_IEC
    else:
      case st and 3
      of 3:
        ev += int(bus.read_byte_internal(ch + 4))
        path = if started: SD_P_START_ATK else: SD_P_ENV_STEP
        if ev >= 255:
          ev = 255
          st = (st and not 3'u8) or 2
          path = if started: SD_P_START else: SD_P_ATK_REACH
      of 2:
        ev = (ev * int(bus.read_byte_internal(ch + 5))) shr 8
        let sus = int(bus.read_byte_internal(ch + 6))
        path = SD_P_ENV_STEP
        if ev <= sus:
          ev = sus
          st = (st and not 3'u8) or 1
          path = SD_P_DEC_REACH
      else:
        path = SD_P_SUS
    if off:
      bus.write_byte_internal(ch, 0)
      result += SD_OFF + aw + 3 * ab
      continue
    bus.write_byte_internal(ch, st)
    bus.write_byte_internal(ch + 9, uint8(ev))
    let v = (ev * (master + 1)) shr 4
    let er = (v * int(bus.read_byte_internal(ch + 2))) shr 8
    let el = (v * int(bus.read_byte_internal(ch + 3))) shr 8
    bus.write_byte_internal(ch + 0x0A, uint8(er))
    bus.write_byte_internal(ch + 0x0B, uint8(el))
    # Mix
    var count = bus.read_word_internal(ch + 0x18)
    var cur = bus.read_word_internal(ch + 0x28)
    let fixed = (bus.read_byte_internal(ch + 1) and 0x08'u8) != 0
    let freq = bus.read_word_internal(ch + 0x20)
    var acc = bus.read_word_internal(ch + 0x1C)
    let loops = (st and 0x10'u8) != 0
    let lstart = bus.read_word_internal(wav + 8)
    let size = bus.read_word_internal(wav + 12)
    # The channel's setup (with its first output)
    var sw = path.sw
    var cc = path.base
    if not loops:
      if started:
        cc -= 14
      else:
        cc -= 10
      sw -= 2
    var caw = path.aw
    var csb = path.sb
    if not fixed:
      cc += (if started: 27 else: 28)
      caw += 2
      csb += 1
    let sw_c = n32(wav)
    result += cc + caw * aw + path.ab * ab + sw * sw_c
    var alive = true
    var wrap_extra = 0
    var k = 0
    template advance(nadv: int) =
      inc cur
      dec count
      inc k
      if count == 0:
        if loops:
          cur = wav + 16 + lstart
          count = size - lstart
          wrap_extra += (if fixed: SD_WRAP_FIX else: sd_wrap_cost(nadv, k))
        else:
          alive = false
    var outs = 0
    var src_b = n16(cur)
    for i in 0'u32 ..< spv:
      var nadv = 0
      if not fixed:
        # count this output's advances first (the cost depends on the count)
        var t = acc
        while t >= pcmfreq:
          t -= pcmfreq
          inc nadv
        k = 0
        while acc >= pcmfreq and alive:
          acc -= pcmfreq
          advance(nadv)
      if not alive: break
      src_b = n16(cur)
      if i > 0:
        # the output's own cost (its first is part of the setup)
        if fixed: result += SD_OUT_FIX + 4 * ab + src_b
        else: result += SD_OUT_RES + 4 * ab + 2 * src_b + sd_adv_cost(nadv)
      elif not fixed and nadv > 0:
        result += sd_adv_cost(nadv) - 13
      if not fixed:
        # the weight's multiplies end early: acc below 256, divFreq below 256
        # (rates 10-12; interp3/6)
        if acc < 256: result -= 1
        if divfreq < 256: result -= 1
      result += wrap_extra
      wrap_extra = 0
      if i == 0: result += csb * src_b
      var smp = bus.sd_s8(cur)
      if not fixed:
        # Linear interpolation toward the next byte in memory (past a loop
        # end too: it reads beyond the sample, it does not wrap), weighted
        # by acc * divFreq (SoundInfo +0x18, ~2^23 / pcmFreq) >> 23
        let x = int32(cast[int32](acc * divfreq))
        smp += int(ashr(int32(bus.sd_s8(cur + 1) - smp) * x, 23))
      let ya = (bus.sd_s8(a0 + i) + ashr(smp * er, 8)) and 0xFF
      let yb = (bus.sd_s8(b0 + i) + ashr(smp * el, 8)) and 0xFF
      bus.write_byte_internal(b0 + i, uint8(yb))
      bus.write_byte_internal(a0 + i, uint8(ya))
      inc outs
      if fixed:
        k = 0
        advance(1)
        if not alive: break
      else:
        acc += freq
    if not alive:
      # A one-shot sample ran out: the channel stops; its position fields
      # keep their values from before the pass
      bus.write_byte_internal(ch, 0)
      result += SD_TAIL_END + (if fixed: 0 else: 18) + aw + 2 * ab
      continue
    result += wrap_extra
    if fixed: result += SD_TAIL_FIX + 3 * aw + ab
    else: result += SD_TAIL_RES + 4 * aw + ab
    bus.write_word_internal(ch + 0x18, count)
    bus.write_word_internal(ch + 0x28, cur)
    if not fixed: bus.write_word_internal(ch + 0x1C, acc)
  result += SD_MIX_POST

proc sd_main(cpu: CPU) =
  ## SoundDriverMain (SWI 0x1C): lock, call SoundInfo +0x20 with +0x24 when
  ## set, call +0x28 with the SoundInfo (always: a zero there jumps to the
  ## reset vector on the real BIOS too), mix, unlock (smain.c).
  let area = cpu.sd_area()
  let ident = cpu.sd_ident(area)
  if area < 0x02000000'u32 or ident != SD_IDENT:
    cpu.r[0] = area
    cpu.r[1] = 0
    cpu.r[3] = ident
    cpu.idle(14)
    return
  let bus = cpu.gba.bus
  let step = if cpu.cpsr.thumb: 2'u32 else: 4'u32
  bus.write_word_internal(area, SD_IDENT + 1)
  cpu.sd_park()
  cpu.r[4] = area
  let fn = bus.read_word_internal(area + 0x20)
  # The callbacks see the flags of the routine's last compare: C for the
  # first, C and Z for +0x28 when +0x20 was skipped (smain.c)
  if fn != 0:
    cpu.cpsr = toPSR((uint32(cpu.cpsr) and 0x0FFFFFFF'u32) or 0x20000000'u32)
    cpu.idle(SD_MAIN_TO_FUNC + 4 * cpu.sd_x(area, true))
    cpu.sd_call(fn, bus.read_word_internal(area + 0x24), 0x1DF1, step)
  else:
    cpu.cpsr = toPSR((uint32(cpu.cpsr) and 0x0FFFFFFF'u32) or 0x60000000'u32)
    cpu.idle(SD_MAIN_TO_CGB + 4 * cpu.sd_x(area, true))
    cpu.sd_call(bus.read_word_internal(area + 0x28), area, 0x1DF9, step)

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
    of SD_PH_SM_DONE:
      let area = cpu.r[4]
      bus.write_word_internal(area, SD_IDENT)
      # r0 = &pcmDmaCounter; the real routine's r1 is its last mixing
      # scratch (0, the reverb, a SoundInfo field address), not modelled
      cpu.r[0] = area + 4
      cpu.r[1] = 0
      cpu.r[3] = SD_R3
      cpu.sd_leave(SD_MAIN_EXIT + cpu.sd_x(area, true))
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
  if cpu.r[15] == SD_TRAP_SM_FUNC:
    bus.add_cycles(-SD_TRAP_COST_T)
    let area = cpu.r[4]
    cpu.cpsr = toPSR((uint32(cpu.cpsr) and 0x0FFFFFFF'u32) or 0x20000000'u32)
    cpu.idle(SD_FUNC_TO_CGB + cpu.sd_x(area, true))
    cpu.sd_call(bus.read_word_internal(area + 0x28), area, 0x1DF9, 2)
    return true
  if cpu.r[15] == SD_TRAP_SM_CGB:
    bus.add_cycles(-SD_TRAP_COST_T)
    let area = cpu.r[4]
    let cost = cpu.sd_mix(area)
    cpu.r[9] = SD_PH_SM_DONE
    cpu.cpsr.thumb = false
    cpu.sd_delay(cost - SD_MIX_BASE, 2)
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
