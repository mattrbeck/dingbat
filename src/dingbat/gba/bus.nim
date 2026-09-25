# Bus implementation (included by gba.nim)

const ACCESS_TIMING_TABLE: array[2, array[16, int]] = [
  [1, 1, 3, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2],  # 8-bit / 16-bit
  [1, 1, 6, 1, 1, 2, 2, 1, 4, 4, 4, 4, 4, 4, 4, 4],  # 32-bit
]

# WAITCNT first-access (nonsequential) wait states and second-access
# (sequential) wait states, per GBATEK. Access cost = waits + 1.
const ROM_N_WAITS = [4, 3, 2, 8]
const ROM_S_WAITS = [[2, 1], [4, 1], [8, 1]]  # per wait-state region
const SRAM_WAITS  = [4, 3, 2, 8]

proc update_waitcnt*(bus: Bus; w: WAITCNT) =
  # Constant non-ROM timings
  for page in 0 .. 7:
    bus.wait16_n[page] = int8(ACCESS_TIMING_TABLE[0][page])
    bus.wait16_s[page] = int8(ACCESS_TIMING_TABLE[0][page])
    bus.wait32_n[page] = int8(ACCESS_TIMING_TABLE[1][page])
    bus.wait32_s[page] = int8(ACCESS_TIMING_TABLE[1][page])
  # EWRAM waits come from the internal memory control register (0x04000800
  # bits 24-27, GBATEK "System Control"): waits = 15 - field, one per
  # halfword, so a word costs twice. Field 13 (the BIOS default) is the
  # table's 3/6; 14 gives 2/4 and 4 gives 12/24 (hardware: gbaedge MEMCTL
  # on AGB SP, docs/hwprobe-results-agb.md). Field 15 hangs real hardware;
  # here it is the fastest setting.
  block:
    let ws = int(bits_range(bus.gba.mmio.memctrl, 24, 27))
    let half = int8(1 + 15 - ws)
    bus.wait16_n[2] = half
    bus.wait16_s[2] = half
    bus.wait32_n[2] = 2 * half
    bus.wait32_s[2] = 2 * half
  let n_first = [int(w.wait_state_0_first_access),
                 int(w.wait_state_1_first_access),
                 int(w.wait_state_2_first_access)]
  let n_second = [int(w.wait_state_0_second_access),
                  int(w.wait_state_1_second_access),
                  int(w.wait_state_2_second_access)]
  for ws in 0 .. 2:
    let n = ROM_N_WAITS[n_first[ws]] + 1
    let s = ROM_S_WAITS[ws][n_second[ws]] + 1
    for page in [8 + ws * 2, 9 + ws * 2]:
      bus.wait16_n[page] = int8(n)
      bus.wait16_s[page] = int8(s)
      bus.wait32_n[page] = int8(n + s)  # nonseq first half + seq second half
      bus.wait32_s[page] = int8(s + s)
  let sram = int8(SRAM_WAITS[int(w.sram_wait_control)] + 1)
  for page in [0xE, 0xF]:
    bus.wait16_n[page] = sram
    bus.wait16_s[page] = sram
    bus.wait32_n[page] = sram
    bus.wait32_s[page] = sram
  bus.prefetch_on = w.gamepack_prefetch_buffer
  # Speed-mode underclock: every access costs 2^underclock times its real
  # cycles; scaling these tables keeps the hot path free, and all prefetch
  # arithmetic runs in the same scaled units. int8 tables cap the shift at 2
  # (worst entry 18 shl 2 = 72).
  let uc = clamp(bus.gba.underclock, 0, 2)
  if uc > 0:
    for page in 0 .. 0xF:
      bus.wait16_n[page] = bus.wait16_n[page] shl uc
      bus.wait16_s[page] = bus.wait16_s[page] shl uc
      bus.wait32_n[page] = bus.wait32_n[page] shl uc
      bus.wait32_s[page] = bus.wait32_s[page] shl uc
  # Prefetch hand-off lookup (see rom_access_cycles): bit e set iff a halfword
  # started e cycles ago is in its last cycle and the buffer is not yet full.
  for page in 0x8 .. 0xD:
    let s = int(bus.wait16_s[page])
    var m = 0'u64
    for e in 0 ..< min(64, 8 * s):
      if e mod s == s - 1: m = m or (1'u64 shl e)
    bus.pf_commit[page] = m

proc set_underclock*(gba: GBA; n: int) =
  ## Speed-mode knob: 0 = off, 1 = half effective CPU speed, 2 = quarter.
  ## Rebuilds the waitstate tables and drops the fetch cache.
  gba.underclock = clamp(n, 0, 2)
  gba.bus.update_waitcnt(gba.mmio.waitcnt)
  gba.bus.fetch_page = 0xFFFFFFFF'u32
  gba.bus.fetch_key = 0xFFFFFFFF'u32

when defined(fetchprof):
  # -d:fetchprof: where the ROM access path goes on a real workload. Indices:
  #   0 fetch_half hot   1 fetch_half slow   2 fetch_word hot   3 fetch_word slow
  #   4 rac fetch calls  5 rac data calls
  #   6 rac prefetch-hit 7 rac plain-seq     8 rac nonseq
  #   9 rac went hot after
  var fetchprof*: array[16, uint64]

proc bus_now(bus: Bus): CycleCount {.inline.} =
  bus.sched.cycles + CycleCount(bus.cycles)

proc rom_cool*(bus: Bus) {.inline.} =
  # End an unbroken fetch stream: while hot, only the stream itself added
  # cycles, so "now" is exactly when the ROM bus went idle
  if bus.rom_hot:
    bus.rom_hot = false
    bus.rom_free_since = bus.bus_now()

proc add_cycles*(bus: Bus; n: int) {.inline.} =
  ## All cycle consumers outside the bus (I-cycles, pipeline refills, HLE
  ## costs) must go through this so the ROM fetch-stream bookkeeping stays
  ## consistent.
  bus.rom_cool()
  bus.cycles += n

proc write_waitcnt*(bus: Bus; w: WAITCNT) =
  ## A CPU write to WAITCNT, with PREFETCH_TOGGLE_LAW. Switching the
  ## prefetcher off does not discard the buffer: the halfword in flight
  ## completes, the CPU uses up what is buffered, and once it is empty its
  ## next fetch is nonsequential -- the drained pause state. AGBEEG aging
  ## cartridge toggle_prefetcher, measured on hardware: all 16 disable cells
  ## (WAITCNT 0x4000/4004/4010/4014 x 1-4 idle cycles) match; counting the
  ## in-flight halfword as landed at once reads 2/2/1/1 low, dropping it
  ## 1 high.
  if not PREFETCH_TOGGLE_LAW: discard
  elif bus.prefetch_on and not w.gamepack_prefetch_buffer and
     bus.fetch_page - 0x8 <= 5 and not bus.pf_paused:
    let now = bus.bus_now()
    let s = int(bus.wait16_s[bus.fetch_page])
    var have = 0
    if now > bus.rom_free_since:
      let gap = int(now - bus.rom_free_since)
      have = min(8, gap div s)
      if have < 8 and gap mod s != 0:
        # The halfword in flight lands at rom_free_since (pf_serve waits)
        have += 1
        bus.rom_free_since = now + CycleCount(s - gap mod s)
    bus.pf_paused = true
    bus.pf_count = int8(have)
    bus.rom_hot = false
  elif w.gamepack_prefetch_buffer and not bus.prefetch_on and
       bus.bus_now() > bus.rom_free_since:
    # Switched on after cycles off the ROM bus with it off: those cycles
    # broke the burst, so the next fetch is nonsequential, and the
    # prefetcher starts behind it (toggle_prefetcher's enable half: all 16
    # cells match; with the write cycle credited to the prefetcher, as
    # without the law, they read 3/2/4/3 low)
    bus.rom_next_addr = 1
    bus.rom_hot = false
    bus.pf_running = false
  bus.update_waitcnt(w)

proc pf_serve_stopped(bus: Bus; now: CycleCount; page: int; halves: int): int =
  ## pf_serve for a stopped prefetcher: the buffer filled (or WAITCNT
  ## switched it off) and the CPU is using up what it holds. Out of line: at
  ## most eight fetches per fill come here.
  let s = int(bus.wait16_s[page])
  if not bus.pf_paused:
    # The eighth halfword landed at rom_free_since + 8*s: stopped since
    bus.pf_paused = true
    bus.pf_count = 8
  # While stopped, rom_free_since is past `now` only for a halfword still in
  # flight when WAITCNT switched the prefetcher off (write_waitcnt)
  let wait = if bus.rom_free_since > now: int(bus.rom_free_since - now) else: 0
  if int(bus.pf_count) >= halves:
    bus.pf_count -= int8(halves)
    return max(1, wait)
  # Drained: the CPU reads what is missing itself, nonsequentially, and the
  # prefetcher restarts behind it on the next free cycle
  let missing = halves - int(bus.pf_count)
  bus.pf_paused = false
  bus.pf_running = false
  let cost = wait + int(bus.wait16_n[page]) + (missing - 1) * s
  bus.rom_free_since = now + CycleCount(cost)
  cost

proc pf_serve(bus: Bus; now: CycleCount; page: int; halves: int): int {.pf_inline.} =
  ## Cost of an opcode fetch of `halves` halfwords that continues the
  ## prefetcher's stream (prefetch on). The prefetcher reads one halfword per
  ## S time while the ROM bus is free, from rom_free_since; a fetch takes what
  ## it has (one cycle) or waits out the rest, and leftover credit carries to
  ## the next fetch. rom_free_since can sit ahead of `now` (the waitloop
  ## fast-forward discards a partial instruction's cycles): zero credit.
  ## Hardware (alyosha prefetcher_full_*, prefetcher_branch_thumb_4): at
  ## eight halfwords the prefetcher stops and stays stopped until the CPU has
  ## taken every one; the fetch after that is the CPU's own, nonsequential
  ## (pf_serve_stopped). Bracketed: stopping at 7 fails prefetcher_full_arm,
  ## _full_arm_2, _full_thumb and _branch_thumb_4; at 9, _full_arm,
  ## _full_arm_2 and _branch_thumb_4.
  if not bus.pf_paused:
    let s = int(bus.wait16_s[page])
    let need = halves * s
    if now <= bus.rom_free_since:
      # No free cycle since the ROM bus was last busy: nothing buffered, and
      # the halfwords come at S, whoever fetches them
      bus.rom_free_since += CycleCount(need)
      return need
    let gap = now - bus.rom_free_since
    if gap < CycleCount(8 * s):
      bus.pf_running = true
      bus.rom_free_since += CycleCount(need)
      return max(1, need - int(gap))  # a full buffer serves even a 32-bit fetch in one cycle
  bus.pf_serve_stopped(now, page, halves)

proc rom_access_cycles(bus: Bus; address: uint32; is32: bool; fetch: bool): int {.inline.} =
  ## Cycle cost of a ROM-region (pages 8-D) access, tracking burst
  ## sequentiality and the prefetch buffer. Sequential = the address
  ## continues the previous ROM access; with the prefetch buffer off the
  ## burst additionally breaks whenever the CPU spent cycles off the ROM bus.
  let page = int(bits_range(address, 24, 27))
  let now = bus.bus_now()
  let contiguous = now == bus.rom_free_since
  let was_paused = bus.pf_paused
  var seq: bool
  if bus.dma_active:
    # DMA: src and dst streams each keep their own burst (LRU pair of
    # trackers); no back-to-back requirement
    if address == bus.rom_next_addr:
      seq = true
    elif address == bus.rom_next_addr2:
      seq = true
      bus.rom_next_addr2 = bus.rom_next_addr
      bus.rom_next_addr = address  # promoted; advanced below
    elif contiguous and bus.rom_next_addr != 1:
      # ROM bus still hot from the previous DMA access (a ROM-to-ROM
      # transfer's write after its read) is sequential, except on the DMA's
      # very first ROM access: rom_next_addr == 1 is the cold sentinel seeded
      # at DMA start, and a fresh bus master's first access is non-sequential
      seq = true
      bus.rom_next_addr2 = bus.rom_next_addr
      bus.rom_next_addr = address
    else:
      seq = false
      bus.rom_next_addr2 = bus.rom_next_addr
      bus.rom_next_addr = address
  else:
    seq = address == bus.rom_next_addr and
          (bus.prefetch_on or contiguous or (fetch and bus.pf_paused))
  when defined(fetchprof):
    fetchprof[if fetch: 4 else: 5].inc
  var cost: int
  var new_free_since: CycleCount
  if seq and fetch and (bus.prefetch_on or bus.pf_paused):
    cost = bus.pf_serve(now, page, if is32: 2 else: 1)
    new_free_since = bus.rom_free_since
    when defined(fetchprof): fetchprof[6].inc
  else:
    # Anything but a prefetched fetch flushes the buffer and has the ROM bus
    # to itself: the prefetcher is idle until its next free cycle
    if seq:
      cost = int(if is32: bus.wait32_s[page] else: bus.wait16_s[page])
      when defined(fetchprof): fetchprof[7].inc
    else:
      cost = int(if is32: bus.wait32_n[page] else: bus.wait16_n[page])
      when defined(fetchprof): fetchprof[8].inc
    new_free_since = now + CycleCount(cost)
    bus.pf_running = false
    # A data access leaves the prefetcher stopped until the CPU's next
    # opcode fetch (alyosha prefetcher_branch_thumb_2: after a gamepak load
    # its I cycle fills nothing); "drained" says exactly that
    bus.pf_paused = not fetch and bus.prefetch_on
    bus.pf_count = 0
  if not fetch and not contiguous and bus.prefetch_on and not bus.dma_active and
     not was_paused and bus.fetch_page - 0x8 <= 5:
    # Prefetch hand-off: a CPU data access takes the ROM bus from the
    # prefetcher, which is `elapsed mod s` cycles into a halfword. A halfword
    # in its address/wait phase is abandoned free; one in its final cycle has
    # committed and the CPU waits that cycle out. Nothing is in flight once
    # the buffer is full (8*s cycles). Only while the CPU executes from the
    # gamepak. mGBA suite Timing "ROM" prefetch columns for LDR/LDM.
    # `elapsed` is 0 when the waitloop fast-forward pushed rom_free_since
    # past `now`.
    let elapsed = if now > bus.rom_free_since: int(now - bus.rom_free_since)
                  else: 0
    let commit =
      if elapsed < 64: ((bus.pf_commit[page] shr elapsed) and 1'u64) != 0
      else:
        let s = int(bus.wait16_s[page])
        elapsed < 8 * s and elapsed mod s == s - 1
    if commit:
      cost += 1
      new_free_since += 1
  elif not fetch and bus.dma_active and bus.dma_first_rom:
    # Prefetch hand-off to a DMA burst: the same arbitration, at the one
    # access where a burst can meet the prefetcher — its FIRST touch of the
    # ROM bus (the prefetcher is then stopped for the burst). The phase is
    # counted from the grant, not `now - rom_free_since`: a granted DMA runs
    # inside an event dispatch where tick_slow has rewound sched.cycles and
    # still holds back part of the CPU's tick quota, so `now` lags the bus by
    # 0..3 cycles. A burst asserts its request the cycle before the access,
    # so the halfword it lands on is k-1 cycles old and "final cycle"
    # ((k-1) mod s == s-1) is `k mod s == 0`. Pinned by the 32 mGBA suite
    # DMA/ROM Timing rows (k = 2 for a ROM-read burst, 3 for a ROM-write one).
    bus.dma_first_rom = false
    if bus.prefetch_on and not was_paused and bus.fetch_page - 0x8 <= 5:
      let s = int(bus.wait16_s[page])
      let k = int(now - bus.dma_grant_now)
      # Buffer full (8 halfwords): nothing in flight to arbitrate against
      let idle = if now > bus.rom_free_since: int(now - bus.rom_free_since)
                 else: 0
      if k mod s == 0 and idle < 8 * s:
        cost += 1
        new_free_since += 1
  when defined(pftrace):
    pft("  RAC " & (if fetch: "fetch" else: "data ") & (if is32: "32" else: "16") &
        " a=" & toHex(address, 8) & " now=" & $now & " rfs_in=" & $bus.rom_free_since &
        " seq=" & $seq & " dma=" & $bus.dma_active & " cost=" & $cost &
        " rfs_out=" & $new_free_since)
  bus.rom_next_addr = address + (if is32: 4'u32 else: 2'u32)
  bus.rom_free_since = new_free_since
  cost

proc rom_fetch_unbuffered(bus: Bus; now: CycleCount; page: int; halves: int): int {.noinline.} =
  ## An opcode fetch continuing the prefetcher's stream that the buffer
  ## cannot serve: the CPU fetches it itself, nonsequentially, as after a
  ## branch elsewhere -- after the halfword still in flight, and after one
  ## in its final cycle, which has committed (the flush in
  ## cpu.clear_pipeline). The prefetcher's bus phase runs on regardless.
  ## Two cases, both rare, so out of line:
  ##
  ## * The first halfword of a 128 KiB block. The prefetcher behaves as
  ##   though full at a 0x20000 boundary (alyosha prefetcher/readme.txt) and
  ##   GBATEK has the block start nonsequential. alyosha bounday_test_1 (six
  ##   Thumb `adds` across 0x08020000 behind two EWRAM loads) reads 8 cycles
  ##   short served from the buffer, 1 short without the final-cycle wait;
  ##   prefetcher_boundary_1-4, which branch to the boundary one cycle apart
  ##   and read in pairs, show the same phase.
  ## * An ARM fetch with address bit 1 set. Only a `bx` to such an address
  ##   puts the ARM PC there (cpu.read_instr keeps the bit, as the console
  ##   does: alyosha prefetcher_branch_thumb_arm_3 is written for `adr`
  ##   results two bytes past the label). The gamepak returns the aligned
  ##   word, but the prefetcher's halfwords never match the CPU's address.
  ##   prefetcher_branch_thumb_arm_3's second check: the ARM fetch after an
  ##   I/O load, 2 cycles from the buffer, is N (6) there. A fetch that
  ##   continues an unbroken burst (no cycle off the gamepak) is plain S.
  let s = int(bus.wait16_s[page])
  var wait = 0
  if bus.rom_free_since >= now:
    wait = int(bus.rom_free_since - now)
  elif not bus.pf_paused:
    let elapsed = int(now - bus.rom_free_since)
    if elapsed < 8 * s and elapsed mod s == s - 1: wait = 1
  let cost = wait + int(bus.wait16_n[page]) + (halves - 1) * s
  bus.rom_free_since = now + CycleCount(cost)
  bus.pf_paused = false
  bus.pf_running = false
  cost

proc rom_fetch_cycles(bus: Bus; address: uint32; page: int;
                      is32: static bool): int {.inline.} =
  ## Fetch-only specialisation of `rom_access_cycles` for the instruction
  ## fetch path: the general proc is too large for clang to inline, and the
  ## DMA trackers and prefetch hand-off are dead on a fetch. A duplicate of
  ## the fetch-relevant half, kept in step by hand; the framebuffer-hash A/B
  ## and the mGBA Timing suite catch drift.
  let now = bus.bus_now()
  var cost: int
  when defined(pftrace):
    let rfs_in = bus.rom_free_since
  if address == bus.rom_next_addr and (bus.prefetch_on or bus.pf_paused):
    # The console fetches rom_ahead bytes past the executing opcode, where
    # dingbat charges the fetch
    let unbuffered =
      ((address + uint32(bus.rom_ahead)) and 0x1FFFF'u32) == 0 or
      (when is32: (address and 2) != 0 and
                  (bus.pf_paused or now > bus.rom_free_since)
       else: false)
    if unbuffered:
      cost = bus.rom_fetch_unbuffered(now, page, when is32: 2 else: 1)
    else:
      cost = bus.pf_serve(now, page, when is32: 2 else: 1)
  else:
    cost =
      if address == bus.rom_next_addr and now == bus.rom_free_since:
        int(when is32: bus.wait32_s[page] else: bus.wait16_s[page])
      else:
        int(when is32: bus.wait32_n[page] else: bus.wait16_n[page])
    bus.rom_free_since = now + CycleCount(cost)
    bus.pf_paused = false
    bus.pf_running = false
  when defined(pftrace):
    pft("  RFC fetch" & (when is32: "32" else: "16") &
        " a=" & toHex(address, 8) & " now=" & $now & " rfs_in=" & $rfs_in &
        " cost=" & $cost & " rfs_out=" & $bus.rom_free_since & " paused=" & $bus.pf_paused &
        " cnt=" & $bus.pf_count)
  bus.rom_next_addr = address + (when is32: 4'u32 else: 2'u32)
  cost

proc access_cycles(bus: Bus; address: uint32; is32: bool; fetch: bool): int {.inline.} =
  if bits_range(address, 28, 31) > 0:
    # Unmapped (open bus): one internal cycle, and the ROM burst trackers are
    # left alone
    return 1
  let page = int(bits_range(address, 24, 27))
  if page >= 0x8:
    if page <= 0xD:
      when defined(flatrom):
        int(if is32: bus.wait32_s[page] else: bus.wait16_s[page])
      else:
        bus.rom_access_cycles(address, is32, fetch)
    else:
      int(bus.wait16_n[page])  # SRAM: 8-bit bus, same cost either way
  else:
    # Via the bus tables so the speed-mode underclock scaling applies
    int(if is32: bus.wait32_n[page] else: bus.wait16_n[page])

proc write_stub_u32(bios: var seq[byte]; offset: int; value: uint32) =
  bios[offset + 0] = byte(value)
  bios[offset + 1] = byte(value shr 8)
  bios[offset + 2] = byte(value shr 16)
  bios[offset + 3] = byte(value shr 24)

proc new_bus*(gba: GBA; bios_path: string): Bus =
  result = Bus(gba: gba)
  result.sched = gba.scheduler
  result.cycles = 0
  result.rom_ahead = 8
  result.fetch_page = 0xFFFFFFFF'u32  # no fetch page cached yet
  result.fetch_key = 0xFFFFFFFF'u32
  result.bios       = newSeq[byte](0x4000)
  result.wram_board = newSeq[byte](0x40000)
  result.wram_chip  = newSeq[byte](0x08000)
  # The ROM buffer never moves and is a fixed size, so a raw pointer is safe
  result.rom_ptr = cast[ptr UncheckedArray[byte]](addr gba.cartridge.rom[0])
  result.rom_len = uint32(gba.cartridge.rom.len)
  if bios_path != "" and fileExists(bios_path):
    let f = open(bios_path, fmRead)
    discard f.readBytes(result.bios, 0, result.bios.len)
    f.close()
  else:
    result.stub_bios = true
    # Minimal BIOS stub: IRQ vector at 0x18 branches to the handler at 0x128
    # (the real BIOS layout, so dispatch costs the same) which calls the user
    # handler at [0x03FFFFFC].
    #   0x004: b 0x1C                         EA000004  (UND vector)
    #   0x01C: subs pc, lr, #4                E25EF004
    #   0x018: b 0x128                        EA000042
    #   0x128: stmfd sp!, {r0-r3, r12, lr}   E92D500F
    #   0x12C: mov   r0, #0x04000000          E3A00301
    #   0x130: add   lr, pc, #0               E28FE000
    #   0x134: ldr   pc, [r0, #-4]            E510F004
    #   0x138: ldmfd sp!, {r0-r3, r12, lr}    E8BD500F
    #   0x13C: subs  pc, lr, #4               E25EF004
    # UND vector (same word as the real BIOS at 0x04: `b 0x1C`). The real
    # handler at 0x1C, hand-decoded from the BIOS image: ldr sp, =0x03007FF0;
    # push {r12, lr}; mrs r12, spsr; mrs lr, cpsr; push {r12, lr}; then it
    # tests the cartridge header's debug flag (ldrb [0x0800009C] == 0xA5,
    # GBATEK "Cartridge Header" entry 09Ch) and, only if set, calls the
    # ROM's debug handler at 0x09FE2000 / 0x09FFC000 (header byte 0B4h bit 7
    # picks one). Otherwise: ldr sp, =0x03007FE0; pop {r12, lr}; msr spsr,
    # r12; pop {r12, lr}; subs pc, lr, #4. Since lr_und is the undefined
    # instruction + 4, the return lands on the faulting instruction again
    # (ARM) or one halfword before it (Thumb) and the exception loops for
    # ever; the `subs pc` restores CPSR from SPSR either way, so IRQs still
    # break in at the boundary. Games without the debug flag (all retail
    # ROMs) observe only that loop. Left out of the stub: the push/pop
    # scribble at 0x03007FE0-0x03007FEF (between the SVC stack top and the
    # BIOS variables, written by nothing else) and sp_und, neither of which a
    # game can see while it hangs — the stub keeps only subs pc, lr, #4.
    write_stub_u32(result.bios, 0x004, 0xEA000004'u32)
    write_stub_u32(result.bios, 0x01C, 0xE25EF004'u32)
    write_stub_u32(result.bios, 0x018, 0xEA000042'u32)
    write_stub_u32(result.bios, 0x128, 0xE92D500F'u32)
    write_stub_u32(result.bios, 0x12C, 0xE3A00301'u32)
    write_stub_u32(result.bios, 0x130, 0xE28FE000'u32)
    write_stub_u32(result.bios, 0x134, 0xE510F004'u32)
    write_stub_u32(result.bios, 0x138, 0xE8BD500F'u32)
    write_stub_u32(result.bios, 0x13C, 0xE25EF004'u32)
    # Halt parks on the `bx lr` after its HALTCNT write (hle_halt), which
    # goes to the dispatcher's return at 0x170: a trap into the HLE
    # (cpu.hle_halt_return).
    write_stub_u32(result.bios, 0x1B4, 0xE12FFF1E'u32)  # bx lr
    write_stub_u32(result.bios, 0x170, 0xEF000000'u32)  # swi 0 (halt return)
    # Never executed: the two words after the IRQ return, so the two-ahead
    # pipeline latch reads the same values as the real BIOS leaves
    write_stub_u32(result.bios, 0x140, 0xE92D5800'u32)
    write_stub_u32(result.bios, 0x144, 0xE55EC002'u32)
    # Reset vector: games jump to 0 for a warm re-boot (Earthworm Jim 2's IRQ
    # dispatcher calls a NULL handler slot). The swi traps into the HLE
    # (pc == 8), which applies the boot's I/O effects and parks execution in
    # the wait loop below; a second trap re-enters the ROM (hle_swi 0x00).
    write_stub_u32(result.bios, 0x000, 0xEF000000'u32)  # swi 0 (boot trap)
    # Boot wait loop (r0 = 0x04000000, r2 = vblank count, set by the trap):
    # count r2 vcount==160 edges, then run to scanline 126 where the real
    # boot hands control to the ROM. Executing stub code keeps the wait
    # inside the per-frame loop and save/rollback-transparent.
    write_stub_u32(result.bios, 0x200, 0xE1D010B6'u32)  # ldrh r1, [r0, #6]
    write_stub_u32(result.bios, 0x204, 0xE35100A0'u32)  # cmp  r1, #160
    write_stub_u32(result.bios, 0x208, 0x1AFFFFFC'u32)  # bne  0x200
    write_stub_u32(result.bios, 0x20C, 0xE1D010B6'u32)  # ldrh r1, [r0, #6]
    write_stub_u32(result.bios, 0x210, 0xE35100A0'u32)  # cmp  r1, #160
    write_stub_u32(result.bios, 0x214, 0x0AFFFFFC'u32)  # beq  0x20C
    write_stub_u32(result.bios, 0x218, 0xE2522001'u32)  # subs r2, r2, #1
    write_stub_u32(result.bios, 0x21C, 0x1AFFFFF7'u32)  # bne  0x200
    write_stub_u32(result.bios, 0x220, 0xE1D010B6'u32)  # ldrh r1, [r0, #6]
    write_stub_u32(result.bios, 0x224, 0xE351007E'u32)  # cmp  r1, #126
    write_stub_u32(result.bios, 0x228, 0x1AFFFFFC'u32)  # bne  0x220
    write_stub_u32(result.bios, 0x22C, 0xEF000000'u32)  # swi 0 (boot finish)
    # SoundGetJumpList (SWI 0x2A): the 36 sound-driver function addresses the
    # real BIOS copies to [r0] (BIOS 0x3738), same values so games that
    # compare the pointers see the real thing. Entry 35 (0x23B0, channel
    # clear) is real code; the others trap into the HLE.
    const JUMP_LIST = [0x2665'u32, 0x26CF, 0x26EF, 0x2709, 0x271D, 0x2665,
                       0x2665, 0x2665, 0x2665, 0x274B, 0x2755, 0x2769,
                       0x277B, 0x27A9, 0x27BB, 0x27CF, 0x27E3, 0x27F5,
                       0x2805, 0x280F, 0x281F, 0x2665, 0x2665, 0x2837,
                       0x2665, 0x2665, 0x2665, 0x284B, 0x2665, 0x2629,
                       0x170B, 0x23E7, 0x1535, 0x159D, 0x23C7, 0x23B1]
    for i, v in JUMP_LIST:
      write_stub_u32(result.bios, 0x3738 + i * 4, v)
      # A Thumb `swi 0` at each entry: the HLE runs the function
      # (hle_sound.nim sd_jl_trap) and returns to lr
      let t = int(v and not 1'u32)
      result.bios[t]     = 0x00'u8
      result.bios[t + 1] = 0xDF'u8
    # Entry 35, the real routine at 0x23B0 (verbatim):
    #   mov ip, r4; movs r1-r4, #0; 4x stmia r0!, {r1-r4}; mov r4, ip; bx lr
    for i, h in [0x46A4'u16, 0x2100, 0x2200, 0x2300, 0x2400,
                 0xC01E, 0xC01E, 0xC01E, 0xC01E, 0x4664, 0x4770]:
      result.bios[0x23B0 + i * 2]     = uint8(h and 0xFF)
      result.bios[0x23B0 + i * 2 + 1] = uint8(h shr 8)
    # SoundDriverMain's callback returns (hle_sound.nim sd_main): the real
    # routine calls SoundInfo +0x20 and +0x28 with lr 0x1DF1 / 0x1DF9, so the
    # stub puts its `swi 0` traps (Thumb) at those addresses. The BIOS's
    # default for the SoundInfo function slots Init fills (0x1709) returns
    # at once.
    for a in [0x1DF0, 0x1DF8]:
      result.bios[a] = 0x00'u8
      result.bios[a + 1] = 0xDF'u8
    result.bios[0x1708] = 0x70'u8   # bx lr
    result.bios[0x1709] = 0x47'u8
    # Sound-driver continuations (hle_sound.nim): a delay loop and the
    # VCOUNT-159 poll, each closed by a `swi 0` trap back into the HLE
    write_stub_u32(result.bios, 0x3900, 0xE2588001'u32)  # subs r8, r8, #1
    write_stub_u32(result.bios, 0x3904, 0x1AFFFFFD'u32)  # bne  0x3900
    write_stub_u32(result.bios, 0x3908, 0xEF000000'u32)  # swi  0
    write_stub_u32(result.bios, 0x3910, 0xE1D010B6'u32)  # ldrh r1, [r0, #6]
    write_stub_u32(result.bios, 0x3914, 0xE351009F'u32)  # cmp  r1, #159
    write_stub_u32(result.bios, 0x3918, 0x0A000002'u32)  # beq  0x3928
    write_stub_u32(result.bios, 0x391C, 0xE1D010B6'u32)  # ldrh r1, [r0, #6]
    write_stub_u32(result.bios, 0x3920, 0xE351009F'u32)  # cmp  r1, #159
    write_stub_u32(result.bios, 0x3924, 0x1AFFFFFC'u32)  # bne  0x391C
    write_stub_u32(result.bios, 0x3928, 0xEF000000'u32)  # swi  0
    # TrackStop's return from the game's CgbOscOff: the real call's lr is
    # 0x2413 (the game sees it), so the Thumb `swi 0` trap sits there
    result.bios[0x2412] = 0x00'u8
    result.bios[0x2413] = 0xDF'u8
  result.gpio = new_gpio(gba)
  # Tilt carts cannot be probed at runtime, so detection is by game code:
  # KYG* = Yoshi's Universal Gravitation / Topsy-Turvy, KHPJ = Koro Koro
  # Puzzle (game codes from the ROM headers; GBATEK names the titles). The
  # tilt window is intercepted before storage regardless of the save
  # heuristic.
  result.tilt_present = gba.cartridge != nil and
    gba.cartridge.game_code() in ["KYGE", "KYGJ", "KYGP", "KHPJ"]
  result.update_waitcnt(WAITCNT())  # reset-state waitstates

proc bus_page(address: uint32): int {.inline.} =
  int(bits_range(address, 24, 27))

# Tilt sensor (0x0E008000-0x0E008500, GBATEK "GBA Cart Tilt Sensor"): write
# 0x55 to 0x8000 to arm, 0xAA to 0x8100 to latch a 12-bit sample per axis.
# Reads deliver low byte / high nibble. GBATEK's register table:
#   "E008300h (R) Upper 4 bits of X axis, and Bit7: ADC Status (0=Busy,
#    1=Ready)"
# and its sampling procedure begins "wait until [E008300h].Bit7=1 or until
# timeout". The conversion time is not documented and the ready bit is
# always set here: Assumed (no cart on the rig). Everything else in the
# window reads 0xFF. Centres per GBATEK's calibration ("X ranged between
# 0x2AF to 0x477, center at 0x392", "Y ... 0x2C3 to 0x480, center at 0x3A0").

const
  TILT_X_CENTER = 0x392
  TILT_Y_CENTER = 0x3A0
  TILT_RANGE    = 0xE0    # counts per 1.0 of frontend input

proc tilt_hit(bus: Bus; address: uint32): bool {.inline.} =
  bus.tilt_present and (address and 0xFFFF'u32) >= 0x8000'u32

proc tilt_sample(input: float; center: int): uint16 =
  uint16(max(0, min(0xFFF, center + int(TILT_RANGE.float * input))))

proc tilt_read(bus: Bus; address: uint32): uint8 =
  case address and 0xFF00'u32
  of 0x8200'u32: uint8(bus.tilt_x and 0xFF)
  of 0x8300'u32: uint8(((bus.tilt_x shr 8) and 0xF) or 0x80)  # bit7 = ready
  of 0x8400'u32: uint8(bus.tilt_y and 0xFF)
  of 0x8500'u32: uint8((bus.tilt_y shr 8) and 0xF)
  else: 0xFF'u8

proc tilt_write(bus: Bus; address: uint32; value: uint8) =
  case address and 0xFF00'u32
  of 0x8000'u32:
    if value == 0x55: bus.tilt_armed = true
  of 0x8100'u32:
    if value == 0xAA and bus.tilt_armed:
      bus.tilt_armed = false
      bus.tilt_x = tilt_sample(bus.tilt_in_x, TILT_X_CENTER)
      bus.tilt_y = tilt_sample(bus.tilt_in_y, TILT_Y_CENTER)
  else: discard

# ---- low-level pointer reads ----

proc read_u16_ptr(buf: seq[byte]; offset: uint32): uint16 {.inline.} =
  cast[ptr uint16](unsafeAddr buf[offset])[]

proc read_u32_ptr(buf: seq[byte]; offset: uint32): uint32 {.inline.} =
  cast[ptr uint32](unsafeAddr buf[offset])[]

proc read_u16_ptr_raw(p: ptr UncheckedArray[byte]; offset: uint32): uint16 {.inline.} =
  cast[ptr uint16](addr p[offset])[]

proc read_u32_ptr_raw(p: ptr UncheckedArray[byte]; offset: uint32): uint32 {.inline.} =
  cast[ptr uint32](addr p[offset])[]

proc write_u16_ptr(buf: var seq[byte]; offset: uint32; val: uint16) {.inline.} =
  cast[ptr uint16](addr buf[offset])[] = val

proc write_u32_ptr(buf: var seq[byte]; offset: uint32; val: uint32) {.inline.} =
  cast[ptr uint32](addr buf[offset])[] = val

# ROM reads: the buffer is sized to the next power of two >= the cart; reads
# past it return the open-bus pattern

proc rom_read8(bus: Bus; address: uint32): uint8 {.inline.} =
  let idx = address and 0x01FFFFFF'u32
  if idx < bus.rom_len: bus.rom_ptr[idx] else: rom_open_bus(idx)

proc rom_read16(bus: Bus; address: uint32): uint16 {.inline.} =
  let idx = address and 0x01FFFFFF'u32
  if idx + 1 < bus.rom_len: read_u16_ptr_raw(bus.rom_ptr, idx)
  else: uint16(rom_open_bus(idx)) or (uint16(rom_open_bus(idx + 1)) shl 8)

proc rom_read32(bus: Bus; address: uint32): uint32 {.inline.} =
  let idx = address and 0x01FFFFFF'u32
  if idx + 3 < bus.rom_len: read_u32_ptr_raw(bus.rom_ptr, idx)
  else:
    uint32(rom_open_bus(idx)) or (uint32(rom_open_bus(idx + 1)) shl 8) or
    (uint32(rom_open_bus(idx + 2)) shl 16) or (uint32(rom_open_bus(idx + 3)) shl 24)

# ---- internal read implementations ----

proc read_byte_internal*(bus: Bus; address: uint32): uint8 {.inline.} =
  if bits_range(address, 28, 31) > 0:
    # 10000000-FFFFFFFF is not decoded: open bus, never a mirror. Minish Cap
    # walks an animation script through a NULL entry into the BIOS open-bus
    # latch and escapes only because the bytes there are the non-zero
    # prefetched opcode.
    return bus.read_open_bus_value(address)
  case bits_range(address, 24, 27)
  of 0x0:
    if bits_range(bus.gba.cpu.r[15], 24, 27) == 0:
      bus.bios[address and 0x3FFF'u32]
    elif (address and 0x00FFFFFF'u32) >= 0x4000'u32 and not bus.dma_active:
      # Page-0 out-of-bounds (00004000-00FFFFFF) is unused memory: a CPU read
      # returns open bus, not the BIOS latch (GBATEK "Reading from Unused
      # Memory")
      bus.read_open_bus_value(address)
    else:
      # BIOS reads are latched to last successful read
      # https://rust-console.github.io/gbatek-gbaonly/#reading-from-bios-memory-00000000-00003fff
      let shift = (address and 3) * 8
      uint8(bus.bios_latch shr shift)
  of 0x1: bus.read_open_bus_value(address)
  of 0x2: bus.wram_board[address and 0x3FFFF'u32]
  of 0x3: bus.wram_chip[address and 0x7FFF'u32]
  of 0x4: bus.gba.mmio[address]
  of 0x5: bus.gba.ppu.pram[address and 0x3FF'u32]
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    bus.gba.ppu.vram[a]
  of 0x7: bus.gba.ppu.oam[address and 0x3FF'u32]
  of 0x8, 0x9, 0xA, 0xB, 0xC, 0xD:
    if address_in_gpio(address) and bus.gpio.allow_reads:
      bus.gpio[address]
    elif bus.gba.storage.eeprom_at(address):
      bus.gba.storage[address]
    else:
      bus.rom_read8(address)
  of 0xE, 0xF:
    if bus.tilt_hit(address): bus.tilt_read(address)
    else: bus.gba.storage[address]
  else: raise newException(Exception, "Unmapped bus read: " & hex_str(address))

proc read_half_internal*(bus: Bus; address: uint32): uint16 {.inline.} =
  let orig = address
  let address = address and not 1'u32
  if bits_range(address, 28, 31) > 0:  # unmapped: open bus, not a mirror
    return uint16(bus.read_open_bus_word(address) shr ((address and 2) * 8))
  case bits_range(address, 24, 27)
  of 0x0:
    if bits_range(bus.gba.cpu.r[15], 24, 27) == 0:
      read_u16_ptr(bus.bios, address and 0x3FFF'u32)
    elif (address and 0x00FFFFFF'u32) >= 0x4000'u32 and not bus.dma_active:
      # Page-0 out-of-bounds -> open bus (see read_byte_internal)
      uint16(bus.read_open_bus_word(address) shr ((address and 2) * 8))
    else:
      # BIOS latch (see read_byte_internal)
      let shift = (address and 2) * 8
      uint16(bus.bios_latch shr shift)
  of 0x1: uint16(bus.read_open_bus_word(address) shr ((address and 2) * 8))
  of 0x2: read_u16_ptr(bus.wram_board, address and 0x3FFFF'u32)
  of 0x3: read_u16_ptr(bus.wram_chip, address and 0x7FFF'u32)
  of 0x4:
    uint16(bus.read_byte_internal(address)) or
    (uint16(bus.read_byte_internal(address + 1)) shl 8)
  of 0x5: read_u16_ptr(bus.gba.ppu.pram, address and 0x3FF'u32)
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    read_u16_ptr(bus.gba.ppu.vram, a)
  of 0x7: read_u16_ptr(bus.gba.ppu.oam, address and 0x3FF'u32)
  of 0x8, 0x9, 0xA, 0xB, 0xC, 0xD:
    if address_in_gpio(address) and bus.gpio.allow_reads:
      uint16(bus.gpio[address])
    elif bus.gba.storage.eeprom_at(address):
      uint16(bus.gba.storage[address])
    else:
      bus.rom_read16(address)
  of 0xE, 0xF:
    if bus.tilt_hit(address): uint16(bus.tilt_read(orig)) * 0x0101'u16
    else: bus.gba.storage.read_half(orig)
  else: raise newException(Exception, "Unmapped bus read_half: " & hex_str(address))

proc read_word_internal*(bus: Bus; address: uint32): uint32 {.inline.} =
  let orig = address
  let address = address and not 3'u32
  if bits_range(address, 28, 31) > 0:  # unmapped: open bus, not a mirror
    return bus.read_open_bus_word(address)
  case bits_range(address, 24, 27)
  of 0x0:
    if bits_range(bus.gba.cpu.r[15], 24, 27) == 0:
      read_u32_ptr(bus.bios, address and 0x3FFF'u32)
    elif (address and 0x00FFFFFF'u32) >= 0x4000'u32 and not bus.dma_active:
      # Page-0 out-of-bounds -> open bus (see read_byte_internal)
      bus.read_open_bus_word(address)
    else:
      # BIOS latch (see read_byte_internal)
      bus.bios_latch
  of 0x1:
    bus.read_open_bus_word(address)
  of 0x2: read_u32_ptr(bus.wram_board, address and 0x3FFFF'u32)
  of 0x3: read_u32_ptr(bus.wram_chip, address and 0x7FFF'u32)
  of 0x4:
    uint32(bus.read_byte_internal(address)) or
    (uint32(bus.read_byte_internal(address + 1)) shl 8) or
    (uint32(bus.read_byte_internal(address + 2)) shl 16) or
    (uint32(bus.read_byte_internal(address + 3)) shl 24)
  of 0x5: read_u32_ptr(bus.gba.ppu.pram, address and 0x3FF'u32)
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    read_u32_ptr(bus.gba.ppu.vram, a)
  of 0x7: read_u32_ptr(bus.gba.ppu.oam, address and 0x3FF'u32)
  of 0x8, 0x9, 0xA, 0xB, 0xC, 0xD:
    if address_in_gpio(address) and bus.gpio.allow_reads:
      uint32(bus.gpio[address])
    elif bus.gba.storage.eeprom_at(address):
      uint32(bus.gba.storage[address])
    else:
      bus.rom_read32(address)
  of 0xE, 0xF:
    if bus.tilt_hit(address): uint32(bus.tilt_read(orig)) * 0x01010101'u32
    else: bus.gba.storage.read_word(orig)
  else: raise newException(Exception, "Unmapped bus read_word: " & hex_str(address))

when defined(linkTrace):
  # -d:linkTrace debug watch: fires on any IWRAM write covering wramWatchOff
  var onWramChipWrite*: proc(gba: GBA; off: int; val: uint32; width: int) = nil
  var wramWatchOff* = -1
  template chipWatch(bus: Bus; o: uint32; v: uint32; w: int) =
    if onWramChipWrite != nil and wramWatchOff >= 0 and
       int(o) <= wramWatchOff and wramWatchOff < int(o) + w:
      onWramChipWrite(bus.gba, int(o), v, w)
else:
  template chipWatch(bus: Bus; o: uint32; v: uint32; w: int) = discard

template sndWatch(bus: Bus; a: uint32; w: int; v: uint32) =
  # MP2K pass detection: one subtract and compare per work-RAM store.
  if (a - bus.snd_wbase) < bus.snd_wlen: bus.gba.mp2k.mp2k_sound_write(a, w, v)

when defined(mp2kwcensus):
  # -d:mp2kwcensus: every work-RAM store is offered to the MP2K write census
  # (mp2k.nim), which orders the driver's lock, hook and buffer writes.
  template wcWatch(bus: Bus; a: uint32; w: int) =
    if bus.gba.mp2k != nil: bus.gba.mp2k.mp2k_wc_write(a, w)
else:
  template wcWatch(bus: Bus; a: uint32; w: int) = discard

proc write_byte_internal*(bus: Bus; address: uint32; value: uint8) =
  if bits_range(address, 28, 31) > 0: return
  # Self-modifying-code pipeline capture: a write landing on the two opcodes
  # already fetched must not affect execution, so snapshot them first. Stands
  # down while a refill is pending: nothing has been fetched at the new PC yet
  # and the refill must observe the write (Golden Sun TLA's stack trampoline)
  if not bus.gba.cpu.refill_pending and
     address <= bus.gba.cpu.r[15] and address >= bus.gba.cpu.r[15] - 4:
    bus.gba.cpu.fill_pipeline()
  case bits_range(address, 24, 27)
  of 0x2:
    sndWatch(bus, address, 1, uint32(value))
    bus.wram_board[address and 0x3FFFF'u32] = value
    wcWatch(bus, address, 1)
  of 0x3:
    sndWatch(bus, address, 1, uint32(value))
    bus.wram_chip[address and 0x7FFF'u32] = value
    chipWatch(bus, address and 0x7FFF'u32, uint32(value), 1)
    wcWatch(bus, address, 1)
  of 0x4: bus.gba.mmio[address] = value
  of 0x5:
    bus.gba.ppu.render_dirty = true
    write_u16_ptr(bus.gba.ppu.pram, address and 0x3FE'u32, 0x0101'u16 * uint16(value))
  of 0x6:
    let limit: uint32 = if bus.gba.ppu.bitmap(): 0x13FFF'u32 else: 0x0FFFF'u32
    var a = 0x1FFFE'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    if a <= limit:
      bus.gba.ppu.render_dirty = true
      write_u16_ptr(bus.gba.ppu.vram, a, 0x0101'u16 * uint16(value))
  of 0x7: discard  # can't write bytes to oam
  of 0x8, 0xD:
    if address_in_gpio(address):
      bus.gpio[address] = value
    elif bus.gba.storage.eeprom_at(address):
      discard bus.gba.storage[address]  # eeprom write check
  of 0xE, 0xF:
    if bus.tilt_hit(address): bus.tilt_write(address, value)
    else: bus.gba.storage[address] = value
  else: log("Unmapped write: " & hex_str(address))

proc write_half_internal*(bus: Bus; address: uint32; value: uint16) =
  if bits_range(address, 28, 31) > 0: return
  let orig = address
  let address = address and not 1'u32
  if not bus.gba.cpu.refill_pending and
     address <= bus.gba.cpu.r[15] and address >= bus.gba.cpu.r[15] - 4:
    bus.gba.cpu.fill_pipeline()
  case bits_range(address, 24, 27)
  of 0x2:
    sndWatch(bus, address, 2, uint32(value))
    write_u16_ptr(bus.wram_board, address and 0x3FFFF'u32, value)
    wcWatch(bus, address, 2)
  of 0x3:
    sndWatch(bus, address, 2, uint32(value))
    write_u16_ptr(bus.wram_chip, address and 0x7FFF'u32, value)
    chipWatch(bus, address and 0x7FFF'u32, uint32(value), 2)
    wcWatch(bus, address, 2)
  of 0x4:
    if (address and 0xFFFFFF'u32) == 0x132'u32:
      # KEYCNT: atomic 16-bit store so the keypad IRQ check never sees a
      # half-written transient (write_keycnt16)
      bus.gba.keypad.write_keycnt16(value)
    else:
      bus.write_byte_internal(address, uint8(value))
      bus.write_byte_internal(address + 1, uint8(value shr 8))
  of 0x5:
    bus.gba.ppu.render_dirty = true
    write_u16_ptr(bus.gba.ppu.pram, address and 0x3FF'u32, value)
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    bus.gba.ppu.render_dirty = true
    write_u16_ptr(bus.gba.ppu.vram, a, value)
  of 0x7:
    bus.gba.ppu.render_dirty = true
    bus.gba.ppu.oam_touched()
    write_u16_ptr(bus.gba.ppu.oam, address and 0x3FF'u32, value)
  of 0x8, 0xD:
    if address_in_gpio(address):
      bus.gpio[address] = uint8(value)
    elif bus.gba.storage.eeprom_at(address):
      bus.gba.storage[address] = uint8(value)
  of 0xE, 0xF:
    # The backup chip is on an 8-bit bus: STRH drives the halfword onto both
    # halves of the data bus and the chip latches the lane A0 selects, so the
    # byte at `orig` is value >> (8 * (orig and 1)) — an odd address stores
    # the high byte (GBATEK "GBA Cart Backup SRAM/FLASH"; jsmolka
    # save/{sram,flash64,flash128} test 6). Applies to the tilt sensor too.
    let b = uint8(value shr (8'u32 * (orig and 1'u32)))
    if bus.tilt_hit(orig): bus.tilt_write(orig, b)
    else: bus.gba.storage[orig] = b
  else: log("Unmapped write half: " & hex_str(address))

proc write_word_internal*(bus: Bus; address: uint32; value: uint32) =
  if bits_range(address, 28, 31) > 0: return
  let orig = address
  let address = address and not 3'u32
  if not bus.gba.cpu.refill_pending and
     address <= bus.gba.cpu.r[15] and address >= bus.gba.cpu.r[15] - 4:
    bus.gba.cpu.fill_pipeline()
  case bits_range(address, 24, 27)
  of 0x2:
    sndWatch(bus, address, 4, value)
    write_u32_ptr(bus.wram_board, address and 0x3FFFF'u32, value)
    wcWatch(bus, address, 4)
  of 0x3:
    sndWatch(bus, address, 4, value)
    write_u32_ptr(bus.wram_chip, address and 0x7FFF'u32, value)
    chipWatch(bus, address and 0x7FFF'u32, value, 4)
    wcWatch(bus, address, 4)
  of 0x4:
    if (address and 0xFFFFFF'u32) == 0x130'u32:
      # Word store covering KEYINPUT (read-only) + KEYCNT: commit KEYCNT
      # atomically (write_keycnt16)
      bus.write_byte_internal(address,     uint8(value))
      bus.write_byte_internal(address + 1, uint8(value shr 8))
      bus.gba.keypad.write_keycnt16(uint16(value shr 16))
    else:
      bus.write_byte_internal(address,     uint8(value))
      bus.write_byte_internal(address + 1, uint8(value shr 8))
      bus.write_byte_internal(address + 2, uint8(value shr 16))
      bus.write_byte_internal(address + 3, uint8(value shr 24))
  of 0x5:
    bus.gba.ppu.render_dirty = true
    write_u32_ptr(bus.gba.ppu.pram, address and 0x3FF'u32, value)
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    bus.gba.ppu.render_dirty = true
    write_u32_ptr(bus.gba.ppu.vram, a, value)
  of 0x7:
    bus.gba.ppu.render_dirty = true
    bus.gba.ppu.oam_touched()
    write_u32_ptr(bus.gba.ppu.oam, address and 0x3FF'u32, value)
  of 0x8, 0xD:
    if address_in_gpio(address):
      bus.gpio[address] = uint8(value)
    elif bus.gba.storage.eeprom_at(address):
      bus.gba.storage[address] = uint8(value)
  of 0xE, 0xF:
    # Same lane select as write_half_internal; STR drives the word across all
    # four lanes, so A[1:0] picks the byte (jsmolka save/* test 8)
    let b = uint8(value shr (8'u32 * (orig and 3'u32)))
    if bus.tilt_hit(orig): bus.tilt_write(orig, b)
    else: bus.gba.storage[orig] = b
  else: log("Unmapped write word: " & hex_str(address))

# ---- Instruction-fetch fast path ----

proc window_fetch_sync(bus: Bus; cost: int)
proc fetch_half_miss(bus: Bus; address: uint32): uint16
proc fetch_word_miss(bus: Bus; address: uint32): uint32

proc install_fetch_cache(bus: Bus; page: uint32): bool =
  when DMA_ACCESS_WINDOW:
    if (bus.sync_bits and 2) != 0: return false
  when IRQ_LAST_WAITS:
    if (bus.sync_bits and 8) != 0: return false
  # Only pages whose fetches are plain masked reads are cacheable; BIOS,
  # MMIO, open bus and 0xD (possible EEPROM) take the generic path
  case page
  of 0x2:
    bus.fetch_ptr = cast[ptr UncheckedArray[byte]](addr bus.wram_board[0])
    bus.fetch_mask = 0x3FFFF'u32
  of 0x3:
    bus.fetch_ptr = cast[ptr UncheckedArray[byte]](addr bus.wram_chip[0])
    bus.fetch_mask = 0x7FFF'u32
  of 0x8, 0x9, 0xA, 0xB, 0xC:
    bus.fetch_ptr = cast[ptr UncheckedArray[byte]](addr bus.gba.cartridge.rom[0])
    bus.fetch_mask = bus.gba.cartridge.rom_mask
  else:
    return false
  bus.fetch_page = page
  bus.fetch_key = page
  # Via the bus tables so the underclock scaling applies; only consumed on
  # the non-ROM (pages 2/3) fetch path
  bus.fetch_c16 = int(bus.wait16_n[int(page)])
  bus.fetch_c32 = int(bus.wait32_n[int(page)])
  true

const OBUS_LEAD {.intdefine.} = 0
  ## -d:OBUS_LEAD=N: the pipeline issues the NEXT fetch while this
  ## instruction executes, so the last thing to drive the bus before a load's
  ## data cycle is a fetch dingbat has not charged yet. N cycles of lead
  ## model that; the exit of the mGBA suite's Break row is quantised in whole
  ## scanlines, so this moves it in steps of 34 reads or not at all.

when defined(obuslatchdbg):
  # The driver's stdout is the harness protocol and the python runner
  # captures its stderr, so a debug line only survives in a file.
  var olat_file: File
  var olat_ready = false
  proc olat_log(msg: string) =
    if not olat_ready:
      olat_ready = olat_file.open(getEnv("OLAT_LOG", "/tmp/olat.txt"), fmAppend)
    if olat_ready:
      olat_file.writeLine(msg)
      olat_file.flushFile()

when defined(obuslatch):
  # How much of the latch one access fills is a property of the memory, not
  # of the instruction set: obusbus.s runs the identical Thumb block from
  # four memories and gets three different answers. IWRAM and BIOS place a
  # halfword into the half its own address bit 1 selects; OAM drives the
  # whole aligned word from one access; the 16-bit memories -- EWRAM, VRAM
  # and the gamepak -- cannot fill both halves at once, and mirror.
  proc obus_stamp(bus: Bus): CycleCount {.inline.} =
    # The live bus clock, not the window's `sched.cycles - synced`: that one
    # is pinned until something calls catch_up, so a run of NOPs would stamp
    # every fetch with the same cycle and the halves could never disagree.
    when defined(obusahead): bus.obus_prev_at
    else: bus.sched.cycles + CycleCount(bus.cycles) + CycleCount(OBUS_LEAD)

  proc obus_drive_word*(bus: Bus; value: uint32) {.inline.} =
    bus.obus_latch = value
    let now = bus.obus_stamp()
    bus.obus_half_at[0] = now
    bus.obus_half_at[1] = now

  proc obus_drive_half*(bus: Bus; address: uint32; value: uint16) {.inline.} =
    let region = bits_range(address, 24, 27)
    let now = bus.obus_stamp()
    if region == 0x0 or region == 0x3:
      if (address and 2) != 0:
        bus.obus_latch = (bus.obus_latch and 0x0000FFFF'u32) or
                         (uint32(value) shl 16)
        bus.obus_half_at[1] = now
      else:
        bus.obus_latch = (bus.obus_latch and 0xFFFF0000'u32) or uint32(value)
        bus.obus_half_at[0] = now
    else:
      if region == 0x7:
        bus.obus_latch = bus.read_word_internal(address and not 3'u32)
      else:
        bus.obus_latch = uint32(value) or (uint32(value) shl 16)
      bus.obus_half_at[0] = now
      bus.obus_half_at[1] = now

proc fetch_half_cached(bus: Bus; address: uint32; page: uint32): uint16 {.inline.} =
  ## The cached-page fetch: `page` is bus.fetch_page.
  if page >= 0x8:
    when defined(flatrom):
      # -d:flatrom measurement probe: every ROM fetch is a flat S access;
      # not shippable
      bus.cycles += int(bus.wait16_s[page])
    else:
      # While the fetch stream is hot, a sequential fetch is a plain S
      # access with no absolute-time bookkeeping
      if bus.rom_hot and address == bus.rom_next_addr:
        when defined(fetchprof): fetchprof[0].inc
        when defined(pftrace):
          pft("  HOT fetch16 a=" & toHex(address, 8) & " now=" & $bus.bus_now() &
              " cost=" & $int(bus.wait16_s[page]))
        bus.cycles += int(bus.wait16_s[page])
        bus.rom_next_addr = address + 2
      else:
        when defined(fetchprof): fetchprof[1].inc
        bus.rom_cool()
        let c = if bus.dma_active:
                  bus.rom_access_cycles(address, is32 = false, fetch = true)
                else: bus.rom_fetch_cycles(address, int(page), is32 = false)
        bus.cycles += c
        # Go hot only when no prefetch credit is left over; leftover credit
        # must keep flowing through the slow path to be consumed
        if bus.rom_free_since == bus.bus_now():
          bus.rom_hot = true
          when defined(fetchprof): fetchprof[9].inc
  else:
    bus.cycles += bus.fetch_c16
  read_u16_ptr_raw(bus.fetch_ptr, (address and bus.fetch_mask) and not 1'u32)

proc fetch_half*(bus: Bus; address: uint32): uint16 {.inline.} =
  let page = bits_range(address, 24, 27)
  if page == bus.fetch_key or bus.install_fetch_cache(page):
    bus.fetch_half_cached(address, page)
  else:
    bus.fetch_half_miss(address)

proc fetch_word_cached(bus: Bus; address: uint32; page: uint32): uint32 {.inline.} =
  ## The cached-page fetch: `page` is bus.fetch_page.
  if page >= 0x8:
    when defined(flatrom):
      bus.cycles += int(bus.wait32_s[page])
    else:
      if bus.rom_hot and address == bus.rom_next_addr:
        when defined(fetchprof): fetchprof[2].inc
        when defined(pftrace):
          pft("  HOT fetch32 a=" & toHex(address, 8) & " now=" & $bus.bus_now() &
              " cost=" & $int(bus.wait32_s[page]))
        bus.cycles += int(bus.wait32_s[page])
        bus.rom_next_addr = address + 4
      else:
        when defined(fetchprof): fetchprof[3].inc
        bus.rom_cool()
        let c = if bus.dma_active:
                  bus.rom_access_cycles(address, is32 = true, fetch = true)
                else: bus.rom_fetch_cycles(address, int(page), is32 = true)
        bus.cycles += c
        if bus.rom_free_since == bus.bus_now():
          bus.rom_hot = true
          when defined(fetchprof): fetchprof[9].inc
  else:
    bus.cycles += bus.fetch_c32
  read_u32_ptr_raw(bus.fetch_ptr, (address and bus.fetch_mask) and not 3'u32)

proc fetch_word*(bus: Bus; address: uint32): uint32 {.inline.} =
  let page = bits_range(address, 24, 27)
  if page == bus.fetch_key or bus.install_fetch_cache(page):
    bus.fetch_word_cached(address, page)
  else:
    bus.fetch_word_miss(address)

# ---- Public read/write with cycle accounting ----

proc catch_up_slow(bus: Bus) =
  # Loops because a fired event can itself consume bus time (a DMA stalling
  # the CPU) that must also be ticked before the access observes the clock.
  bus.in_catch_up = true
  while bus.cycles > 0:
    let pending = bus.cycles
    bus.cycles = 0
    bus.synced += pending
    bus.gba.scheduler.tick(pending)
  bus.in_catch_up = false

proc catch_up(bus: Bus) {.inline.} =
  # Advance the scheduler to the current mid-instruction cycle so MMIO
  # accesses observe timers, IF flags etc. exactly. Skipped while an event
  # handler runs (handlers stay pure; the post-dispatch DMA pump arbitrates
  # deferred work) and, in the accessors below, while a DMA burst runs (a
  # transfer must not be preempted between its read and write; the DMA loop
  # drains due events at transfer boundaries).
  let s = bus.sched
  if s.dispatching: return
  let target = s.cycles + CycleCount(bus.cycles)
  if target < s.next_event:
    s.cycles = target
    bus.synced += bus.cycles
    bus.cycles = 0
  else:
    bus.catch_up_slow()

proc catch_up_access(bus: Bus; cost: int) {.inline.} =
  ## catch_up from inside a bus access whose cycles (`cost`) are already
  ## charged: the clock it syncs to is the access's END, and a DMA request
  ## that fires on the way there landed inside the access (gba.nim,
  ## defer_dma_request).
  bus.access_end = bus.bus_now()
  bus.access_start = bus.access_end - CycleCount(cost)
  bus.catch_up()

proc imm_post_grant(bus: Bus) {.noinline.} =
  ## IMM_ACCESS_WAIT: the CPU store an immediate DMA's request landed in has
  ## taken effect; the burst gets the bus now.
  bus.imm_post = false
  bus.sync_bits = bus.sync_bits and not 4'u8
  bus.gba.dma.request_immediate()
  # A SWP's read and write are one locked transaction: it pumps the request
  # after its write.
  if bus.swp_lock: return
  bus.gba.dma.run_pending()

proc imm_pre_grant(bus: Bus; cost: int) =
  ## IMM_ACCESS_WAIT: a data access at the cycle an immediate DMA's request
  ## came due (as the previous access ended) loses the bus to it; the burst
  ## runs before this access's cycles.
  bus.cycles -= cost
  bus.catch_up()                  # the one-cycle retry may take it here
  bus.cycles += cost
  if not bus.imm_pre: return
  bus.imm_pre = false
  bus.sync_bits = bus.sync_bits and not 4'u8
  bus.sched.clear(etDMA)
  bus.cycles -= cost
  bus.gba.dma.request_immediate(reschedule = true)
  # A SWP's write belongs to its read: SWP pumps the request after it.
  if not bus.swp_lock: bus.gba.dma.run_pending()
  bus.cycles += cost

proc window_fetch_sync(bus: Bus; cost: int) =
  bus.fetch_page = 0xFFFFFFFF'u32
  bus.fetch_key = 0xFFFFFFFF'u32   # stay on the miss path while the window is open
  # A request that fires inside this very fetch leaves the window open for
  # the internal cycles behind it; the fetch after that closes it.
  let closing = bus.window_closing
  bus.access_rom = true
  bus.access_write = false
  bus.catch_up_access(cost)
  when IMM_ACCESS_WAIT:
    if bus.imm_post: bus.imm_post_grant()
  if closing:
    bus.window_closing = false
    bus.sync_bits = bus.sync_bits and not 2'u8

proc idle_window*(bus: Bus; n: int) =
  ## Internal cycles with the access window open. The CPU does not need the
  ## bus for them, so a DMA that has it costs them nothing: on an AGB SP a
  ## one-halfword H-blank DMA (4 cycles) costs a run of multiplies 4, 3, 2, 1
  ## or 0 cycles as its request moves from the multiply's last internal cycle
  ## back to its fetch, and a load 3 rather than 4 when the grant falls just
  ## before its internal cycle (tests/roms/payloads/dmaphase.s).
  bus.rom_cool()
  var n = n
  let now = bus.bus_now()
  if bus.dma_end_at == now and bus.dma_held > 0:
    # The burst began as the access before these cycles ended.
    let ran = min(n, bus.dma_held)
    n -= ran
    bus.dma_held = 0
    # And the interrupt synchroniser ran with them: the CPU was not stalled.
    bus.gba.interrupts.unstall(ran)
  bus.cycles += n
  bus.idle_until = bus.bus_now()
  bus.catch_up()

# The sync_bits leg (identical in all six accessors): an immediate DMA
# fires DMA_START_DELAY cycles after arming while the CPU keeps executing; an
# accessor's data effect happens when it runs but its cycles reach the
# scheduler only at instruction end, so an access positioned after the
# burst's start would otherwise land before it. Forcing catch-up during the
# armed window keeps the CPU-vs-DMA memory order cycle-exact.
when defined(biosdrvtrace):
  # tests/biosdrv_probe.nim: every CPU/DMA store (address, width, value)
  var bdMemHook*: proc(address: uint32; width: int; value: uint32) {.closure.}
  var bdReadHook*: proc(address: uint32; width: int) {.closure.}
  template bdWatch(a: uint32; w: int; v: uint32) =
    if bdMemHook != nil: bdMemHook(a, w, v)
  template bdWatchRead(a: uint32; w: int) =
    if bdReadHook != nil: bdReadHook(a, w)
else:
  template bdWatch(a: uint32; w: int; v: uint32) = discard
  template bdWatchRead(a: uint32; w: int) = discard

proc `[]`*(bus: Bus; address: uint32): uint8 =
  bdWatchRead(address, 1)
  bus.rom_cool()
  let cost = bus.access_cycles(address, is32 = false, fetch = false)
  bus.cycles += cost
  if (bus_page(address) == 0x4 or bus.sync_bits != 0) and not bus.dma_active:
    if not IRQ_LAST_WAITS or bus_page(address) == 0x4 or (bus.sync_bits and 7) != 0:
      when DMA_READS_CPU_BUS:
        bus.load_addr = address
        bus.load_size = (if bus.ldrsh_odd: 2 else: 1)
        bus.load_pc = bus.gba.cpu.r[15]
        bus.load_end = bus.bus_now()
        bus.load_start = bus.load_end - CycleCount(cost)
      when IMM_ACCESS_WAIT:
        bus.access_rom = bus_page(address) >= 0x8
        bus.access_write = false
        if bus.imm_pre: bus.imm_pre_grant(cost)
      bus.catch_up_access(cost)
      when IMM_ACCESS_WAIT:
        if bus.imm_post:
          result = bus.read_byte_internal(address)
          bus.imm_post_grant()
          return
  bus.read_byte_internal(address)

proc read_half*(bus: Bus; address: uint32): uint16 =
  bdWatchRead(address, 2)
  bus.rom_cool()
  let cost = bus.access_cycles(address, is32 = false, fetch = false)
  bus.cycles += cost
  if (bus_page(address) == 0x4 or bus.sync_bits != 0) and not bus.dma_active:
    if not IRQ_LAST_WAITS or bus_page(address) == 0x4 or (bus.sync_bits and 7) != 0:
      when DMA_READS_CPU_BUS:
        bus.load_addr = address
        bus.load_size = 2
        bus.load_pc = bus.gba.cpu.r[15]
        bus.load_end = bus.bus_now()
        bus.load_start = bus.load_end - CycleCount(cost)
      when IMM_ACCESS_WAIT:
        bus.access_rom = bus_page(address) >= 0x8
        bus.access_write = false
        if bus.imm_pre: bus.imm_pre_grant(cost)
      bus.catch_up_access(cost)
      when IMM_ACCESS_WAIT:
        if bus.imm_post:
          result = bus.read_half_internal(address)
          bus.imm_post_grant()
          return
  bus.read_half_internal(address)

proc sd_tw_begin*(bus: Bus; a0: uint32; n: int) =
  ## A SoundDriverMain pass starts writing the slot at a0 (n bytes in each
  ## pcmBuffer half, the B half 0x630 on): record its writes from here.
  bus.sd_tw_active = true
  bus.sd_tw_start = bus.bus_now()
  bus.sd_tw_a0 = a0
  bus.sd_tw_n = n
  bus.sd_tw_pre.setLen(2 * n)
  bus.sd_tw_head.setLen(2 * n)
  bus.sd_tw_tail.setLen(2 * n)
  for i in 0 ..< n:
    bus.sd_tw_pre[i] = bus.read_byte_internal(a0 + uint32(i))
    bus.sd_tw_pre[n + i] = bus.read_byte_internal(a0 + 0x630'u32 + uint32(i))
  for i in 0 ..< 2 * n:
    bus.sd_tw_head[i] = -1
  bus.sd_tw_next.setLen(0)
  bus.sd_tw_t.setLen(0)
  bus.sd_tw_v.setLen(0)

proc sd_tw_rec*(bus: Bus; o: int; t: int; v: uint8) {.inline.} =
  ## The pass writes byte o (A half 0..n-1, B half n..2n-1) at cycle t.
  let e = int32(bus.sd_tw_t.len)
  bus.sd_tw_t.add(int32(t))
  bus.sd_tw_v.add(v)
  bus.sd_tw_next.add(-1)
  if bus.sd_tw_head[o] < 0: bus.sd_tw_head[o] = e
  else: bus.sd_tw_next[bus.sd_tw_tail[o]] = e
  bus.sd_tw_tail[o] = e

proc sd_tw_word*(bus: Bus; address: uint32; word: uint32): uint32 =
  ## A sound DMA's read of `word` at `address` during a pass: each byte of
  ## the slot as the real routine had it at this cycle.
  result = word
  let now = bus.bus_now()
  let dt = when CycleCount is uint32: int64(cast[int32](now - bus.sd_tw_start))
           else: cast[int64](now - bus.sd_tw_start)
  for k in 0'u32 .. 3'u32:
    let a = (address and not 3'u32) + k
    var o = -1
    let n = uint32(bus.sd_tw_n)
    if a >= bus.sd_tw_a0 and a < bus.sd_tw_a0 + n: o = int(a - bus.sd_tw_a0)
    elif a >= bus.sd_tw_a0 + 0x630'u32 and a < bus.sd_tw_a0 + 0x630'u32 + n:
      o = int(n + (a - bus.sd_tw_a0 - 0x630'u32))
    if o < 0: continue
    var v = bus.sd_tw_pre[o]
    var e = bus.sd_tw_head[o]
    while e >= 0 and int64(bus.sd_tw_t[e]) <= dt:
      v = bus.sd_tw_v[e]
      e = bus.sd_tw_next[e]
    result = (result and not (0xFF'u32 shl (8 * k))) or (uint32(v) shl (8 * k))

proc read_word*(bus: Bus; address: uint32): uint32 =
  bdWatchRead(address, 4)
  bus.rom_cool()
  let cost = bus.access_cycles(address, is32 = true, fetch = false)
  bus.cycles += cost
  if (bus_page(address) == 0x4 or bus.sync_bits != 0) and not bus.dma_active:
    if not IRQ_LAST_WAITS or bus_page(address) == 0x4 or (bus.sync_bits and 7) != 0:
      when DMA_READS_CPU_BUS:
        bus.load_addr = address
        bus.load_size = 4
        bus.load_pc = bus.gba.cpu.r[15]
        bus.load_end = bus.bus_now()
        bus.load_start = bus.load_end - CycleCount(cost)
      when IMM_ACCESS_WAIT:
        bus.access_rom = bus_page(address) >= 0x8
        bus.access_write = false
        if bus.imm_pre: bus.imm_pre_grant(cost)
      bus.catch_up_access(cost)
      when IMM_ACCESS_WAIT:
        if bus.imm_post:
          result = bus.read_word_internal(address)
          bus.imm_post_grant()
          return
  bus.read_word_internal(address)

proc fetch_half_miss(bus: Bus; address: uint32): uint16 =
  when DMA_ACCESS_WINDOW:
    if (bus.sync_bits and 2) != 0:
      # The window vetoed the fetch cache to get here. Charge the fetch the
      # way the fast path does, then sync to its end.
      bus.sync_bits = bus.sync_bits and not 2'u8
      let before = bus.cycles
      result = bus.fetch_half(address)
      bus.sync_bits = bus.sync_bits or 2
      bus.window_fetch_sync(bus.cycles - before)
      return
  when IRQ_LAST_WAITS:
    if (bus.sync_bits and 8) != 0:
      # An interrupt's window keeps fetches off the fast path: fetch as it
      # does (from the cached page when it still applies) and note the
      # fetch's wait states.
      let before = bus.cycles
      let page = bits_range(address, 24, 27)
      if page == bus.fetch_page:
        result = bus.fetch_half_cached(address, page)
      else:
        bus.sync_bits = bus.sync_bits and not 8'u8
        result = bus.fetch_half(address)
        bus.sync_bits = bus.sync_bits or 8
        bus.fetch_key = 0xFFFFFFFF'u32
      bus.note_waits(bus.cycles - before)
      return
  bus.read_half(address)

proc fetch_word_miss(bus: Bus; address: uint32): uint32 =
  when DMA_ACCESS_WINDOW:
    if (bus.sync_bits and 2) != 0:
      bus.sync_bits = bus.sync_bits and not 2'u8
      let before = bus.cycles
      result = bus.fetch_word(address)
      bus.sync_bits = bus.sync_bits or 2
      bus.window_fetch_sync(bus.cycles - before)
      return
  when IRQ_LAST_WAITS:
    if (bus.sync_bits and 8) != 0:
      # An interrupt's window keeps fetches off the fast path: fetch as it
      # does (from the cached page when it still applies) and note the
      # fetch's wait states.
      let before = bus.cycles
      let page = bits_range(address, 24, 27)
      if page == bus.fetch_page:
        result = bus.fetch_word_cached(address, page)
      else:
        bus.sync_bits = bus.sync_bits and not 8'u8
        result = bus.fetch_word(address)
        bus.sync_bits = bus.sync_bits or 8
        bus.fetch_key = 0xFFFFFFFF'u32
      bus.note_waits(bus.cycles - before)
      return
  bus.read_word(address)

proc `[]=`*(bus: Bus; address: uint32; value: uint8) =
  bdWatch(address, 1, uint32(value))
  bus.rom_cool()
  let cost = bus.access_cycles(address, is32 = false, fetch = false)
  bus.cycles += cost
  if (bus_page(address) == 0x4 or bus.sync_bits != 0) and not bus.dma_active:
    when IRQ_LAST_WAITS:
      if (bus.sync_bits and 8) != 0: bus.note_waits(cost)
    if not IRQ_LAST_WAITS or bus_page(address) == 0x4 or (bus.sync_bits and 7) != 0:
      # A store ends the load's claim on the bus (Bus.dma_bus_word): the
      # console shows a burst the fetched opcode after one, not the load
      # before it or the store's own data (dmaobus2.s variant 7)
      when DMA_READS_CPU_BUS: bus.load_size = 0
      when IMM_ACCESS_WAIT:
        bus.access_rom = bus_page(address) >= 0x8
        bus.access_write = true
        if bus.imm_pre: bus.imm_pre_grant(cost)
      bus.catch_up_access(cost)
      when IMM_ACCESS_WAIT:
        if bus.imm_post:
          bus.byte_io_write = true
          bus.write_byte_internal(address, value)
          bus.byte_io_write = false
          bus.imm_post_grant()
          return
  bus.byte_io_write = true
  bus.write_byte_internal(address, value)
  bus.byte_io_write = false

proc write_half*(bus: Bus; address: uint32; value: uint16) =
  bdWatch(address, 2, uint32(value))
  bus.rom_cool()
  let cost = bus.access_cycles(address, is32 = false, fetch = false)
  bus.cycles += cost
  if (bus_page(address) == 0x4 or bus.sync_bits != 0) and not bus.dma_active:
    when IRQ_LAST_WAITS:
      if (bus.sync_bits and 8) != 0: bus.note_waits(cost)
    if not IRQ_LAST_WAITS or bus_page(address) == 0x4 or (bus.sync_bits and 7) != 0:
      # A store ends the load's claim on the bus (Bus.dma_bus_word): the
      # console shows a burst the fetched opcode after one, not the load
      # before it or the store's own data (dmaobus2.s variant 7)
      when DMA_READS_CPU_BUS: bus.load_size = 0
      when IMM_ACCESS_WAIT:
        bus.access_rom = bus_page(address) >= 0x8
        bus.access_write = true
        if bus.imm_pre: bus.imm_pre_grant(cost)
      bus.catch_up_access(cost)
      when IMM_ACCESS_WAIT:
        if bus.imm_post:
          bus.write_half_internal(address, value)
          bus.imm_post_grant()
          return
  bus.write_half_internal(address, value)

proc write_word*(bus: Bus; address: uint32; value: uint32) =
  bdWatch(address, 4, value)
  bus.rom_cool()
  let cost = bus.access_cycles(address, is32 = true, fetch = false)
  bus.cycles += cost
  if (bus_page(address) == 0x4 or bus.sync_bits != 0) and not bus.dma_active:
    when IRQ_LAST_WAITS:
      if (bus.sync_bits and 8) != 0: bus.note_waits(cost)
    if not IRQ_LAST_WAITS or bus_page(address) == 0x4 or (bus.sync_bits and 7) != 0:
      # A store ends the load's claim on the bus (Bus.dma_bus_word): the
      # console shows a burst the fetched opcode after one, not the load
      # before it or the store's own data (dmaobus2.s variant 7)
      when DMA_READS_CPU_BUS: bus.load_size = 0
      when IMM_ACCESS_WAIT:
        bus.access_rom = bus_page(address) >= 0x8
        bus.access_write = true
        if bus.imm_pre: bus.imm_pre_grant(cost)
      bus.catch_up_access(cost)
      when IMM_ACCESS_WAIT:
        if bus.imm_post:
          bus.write_word_internal(address, value)
          bus.imm_post_grant()
          return
  bus.write_word_internal(address, value)

# For DMA write-word via uint32 subscript
proc `[]=`*(bus: Bus; address: uint32; value: uint32) =
  bus.write_word(address, value)

proc read_half_rotate*(bus: Bus; address: uint32): uint32 =
  let half = uint32(bus.read_half(address))
  let bits = (address and 1) * 8
  (half shr bits) or (half shl (32 - bits))

proc read_half_signed*(bus: Bus; address: uint32): uint32 =
  if bit(address, 0):
    # A misaligned LDRSH loads the byte, but over a halfword access
    # (DMA_READS_CPU_BUS: alyosha Bus/LDRSH_misaligned; dmaobus.s on an AGB
    # SP puts the whole halfword on the bus)
    bus.ldrsh_odd = true
    let b = bus[address]
    bus.ldrsh_odd = false
    uint32(cast[int32](cast[int8](b)))
  else:
    uint32(cast[int32](cast[int16](bus.read_half(address))))

proc read_word_rotate*(bus: Bus; address: uint32): uint32 =
  let word = bus.read_word(address)
  let bits = (address and 3) * 8
  (word shr bits) or (word shl (32 - bits))

proc fetch_bus_word(bus: Bus; pc: uint32): uint32
proc dma_bus_word(bus: Bus): uint32

proc read_open_bus_word*(bus: Bus; address: uint32): uint32 =
  ## The whole 32-bit latch, decided ONCE for an access. The verdict turns on
  ## when this read began, and working that out runs catch-up, which can run
  ## a DMA and move the clock -- so a word assembled from four byte-wide
  ## verdicts could tear: tests/roms/payloads/slotdma.s hop 2 read `000000FF`
  ## where an AGB SP reads `FFFFFFFF`, the DMA having landed after the first
  ## byte's verdict and before the second's.
  log("Reading open bus at " & hex_str(address))
  when defined(obuslatch):
    # Each half answers for itself: it shows the DMA's word if the burst was
    # requested after that half was last fetch-driven and no later than this
    # read began. Both halves agreeing reproduces the old all-or-nothing
    # answer; them disagreeing is DEAD6019, which no single predicate can
    # produce (docs/playtest-bugs.md section 13).
    if bus.dma_active:
      return bus.dma_open_bus
    let acc = if bits_range(address, 28, 31) > 0: 1
              else: int(bus.wait16_n[bits_range(address, 24, 27)])
    let started = bus.bus_now() - CycleCount(acc)
    if not bus.sched.dispatching:
      bus.catch_up()
    var seen = bus.obus_latch
    when defined(obuslatchdbg):
      if bus.dma_has_run:
        olat_log("a=" & hex_str(address) &
             " lat=" & hex_str(bus.obus_latch) &
             " h0=" & $bus.obus_half_at[0] & " h1=" & $bus.obus_half_at[1] &
             " req=" & $bus.dma_request_at & " started=" & $started &
             " dmaw=" & hex_str(bus.dma_open_bus))
    if bus.dma_has_run and bus.dma_request_at <= started:
      if bus.dma_request_at > bus.obus_half_at[0]:
        seen = (seen and 0xFFFF0000'u32) or (bus.dma_open_bus and 0xFFFF'u32)
      if bus.dma_request_at > bus.obus_half_at[1]:
        seen = (seen and 0x0000FFFF'u32) or
               (bus.dma_open_bus and 0xFFFF0000'u32)
    return seen
  # GBATEK "GBA Unpredictable Things", Reading from Unused Memory: unused
  # memory "returns the recently pre-fetched opcode", which "might also
  # change if a DMA transfer occurs". The DMA's own unmapped reads see its
  # latch. Otherwise the last word a DMA moved is still on the bus only for
  # the CPU's first access after the burst: a DMA is granted when the CPU
  # access in flight ends, and any later access, the opcode fetch included,
  # replaces the value (gbaedge DMAOPENBUS on AGB SP, docs/hwprobe-results-
  # agb.md session 5: "an opcode fetch also refreshes open bus"). So this
  # read sees the word when the request came after this instruction's fetch
  # began and no later than this read began; bursts due by now are run
  # first so a request inside this instruction is known.
  if bus.dma_active:
    when DMA_READS_CPU_BUS:
      if bus.dma_bus_fresh: return bus.dma_bus_word()
    return bus.dma_open_bus
  # The instruction's opcode fetch is its first charged access, and catch-up
  # moves exactly the cycles it ticks from `cycles` into `synced`, so the
  # fetch began at sched.cycles - synced throughout the instruction.
  let fetch_start = bus.sched.cycles - CycleCount(bus.synced)
  let access = if bits_range(address, 28, 31) > 0: 1
               else: int(bus.wait16_n[bits_range(address, 24, 27)])
  # An accessor that already synced (nothing left in `cycles`) recorded the
  # access's end; a DMA run by that sync has moved the clock past it.
  let read_end = if bus.cycles == 0: bus.access_end else: bus.bus_now()
  let read_start = read_end - CycleCount(access)
  if not bus.sched.dispatching:
    bus.catch_up()
  # This all-or-nothing window is known to be the wrong SHAPE, not merely
  # the wrong width, and tests/roms/payloads/obuswint.s is the measurement
  # that says so: from Thumb code, two NOPs after a burst, an AGB SP returns
  # DEAD6019 -- the DMA word's high half beside a freshly fetched opcode
  # halfword. The latch is per-halfword, a DMA fills both halves, and later
  # halfword fetches overwrite them one at a time into the half each one's
  # own address bit 1 selects (the same placement rule as the Thumb
  # composition below). A predicate that can only answer "the whole DMA word"
  # or "no DMA word" cannot produce that, so no lower bound is right: moving
  # this one to fetch_start + 1, which is what obuswin.s measures for ARM
  # code in IWRAM, costs `DMA Prefetch Read` and drives `DMA Prefetch Break`
  # to zero. Both left as they are until the latch itself is modelled
  # (docs/playtest-bugs.md section 13).
  when defined(obusdbg):
    # -d:obusdbg: the cycle stamps this window turns on, one line per unmapped
    # word read. obuswin.s and obuswint.s are the hardware column.
    if bus.dma_has_run and (address and 3) == 0:
      echo "obus ", hex_str(address), " req=", bus.dma_request_at,
           " fetch=", fetch_start, " read=", read_start,
           " -> ", (if bus.dma_request_at > fetch_start and
                       bus.dma_request_at <= read_start: "DMA" else: "opcode")
  if bus.dma_has_run and bus.dma_request_at > fetch_start and
     bus.dma_request_at <= read_start:
    return bus.dma_open_bus
  bus.fetch_bus_word(bus.gba.cpu.r[15])

proc fetch_bus_word(bus: Bus; pc: uint32): uint32 =
  ## What the CPU's opcode fetches left on the data bus, `pc` being r15 as
  ## the instruction that made the last of them sees it.
  # PC in MMIO/unmapped memory would recurse back into this proc
  let pc_region = bits_range(pc, 24, 27)
  if pc_region == 0x1 or pc_region == 0x4 or pc_region > 0xD or
     bits_range(pc, 28, 31) > 0:  # PC itself in unmapped space would recurse
    return 0'u32
  let word: uint32 =
    if bus.gba.cpu.cpsr.thumb:
      # A Thumb fetch is a halfword, so what the 32-bit bus holds has to be
      # made of two of them -- but only where the bus the code is fetched
      # over is 32 bits wide. There the two most recent fetches ($+2 and $+4,
      # and r15 reads $+4) each land in the half of the latch its own address
      # bit 1 selects, not in fetch order, so the halves come from two
      # different words and no single aligned read reproduces them.
      #
      # Measured on the AGB SP over the link rig (tests/roms/payloads/
      # obusprobe.s, code in IWRAM): the same load at 0x030000F0 reads
      # 3E0260A8 and at 0x030000FA reads 61283E02, where [$+2] = 3E02 in
      # both, [$+4] = 60A8 and 6128. dingbat duplicated [$+4] into both
      # halves, which is right only when the two happen to be equal.
      #
      # There are three cases, and bus width alone does not pick between
      # them: what matters is how much of the latch one fetch fills.
      # obusbus.s copies the identical Thumb block into four memories and
      # runs it from each, so the rows differ in the memory executed from and
      # in nothing else (same on an AGB SP with the display on and forced
      # blank, so the OAM row is not the PPU competing for the bus):
      #
      #   IWRAM 32-bit  3E026028  60A83E02   the two fetches, placed by bit 1
      #   EWRAM 16-bit  60286028  60A860A8   [$+4] duplicated into both halves
      #   VRAM  16-bit  60286028  60A860A8   the same
      #   OAM   32-bit  606E6028  60A83E02   the aligned WORD holding $+4
      #
      # A 16-bit bus cannot fill both halves from one fetch, so it mirrors --
      # which is also why the mGBA suite, reading its write-only registers
      # from ROM-resident Thumb code, wants the duplicate: composing there
      # costs 40 I/O rows and 6 Timing rows. OAM fills the whole latch from
      # one fetch, so Thumb code there composes exactly as ARM code does; it
      # was assumed to match IWRAM because both are 32 bits wide, and it does
      # not. BIOS is the one region left unmeasured -- a payload cannot
      # execute there -- and stays with IWRAM, the memory it shares a bus
      # with.
      if pc_region == 0x7:
        bus.read_word_internal(pc and not 3'u32)
      elif pc_region == 0x0 or pc_region == 0x3:
        # pc < 2 (a wild jump that wrapped): $+2 is at 0xFFFFFFFE, unmapped,
        # and its read would come back here with the same PC; the one
        # fetched halfword stands in for both
        let older = if pc < 2: uint32(bus.read_half_internal(pc and not 1'u32))
                    else: uint32(bus.read_half_internal((pc - 2) and not 1'u32))
        let newer = uint32(bus.read_half_internal(pc and not 1'u32))
        if (pc and 2) != 0: (newer shl 16) or older
        else:               (older shl 16) or newer
      else:
        let opcode = uint32(bus.read_half_internal(pc and not 1'u32))
        (opcode shl 16) or opcode
    else:
      bus.read_word_internal(pc and not 3'u32)
  word

proc dma_bus_word(bus: Bus): uint32 =
  ## The data bus as a burst's first transfer finds it (DMA_READS_CPU_BUS):
  ## the CPU's data load if that is the last thing the CPU did on the bus
  ## (it has fetched nothing since), else its fetched opcode. dmaobus.s on
  ## an AGB SP, Thumb in IWRAM, the burst granted right after the load:
  ## EWRAM ldrh / misaligned ldrsh FF24FF24, ldrb FFFFFFFF, ldr 11223344;
  ## no load 46C046C0. A 16-bit memory puts a halfword on both halves and a
  ## byte on all four lanes; OAM drives the aligned word (alyosha
  ## Bus/DMA_OAM_Bus). A load from unused memory drives nothing (alyosha
  ## Bus/Unused_location_update_bus), and only memories whose reads have no
  ## side effects are read back here.
  if bus.load_size != 0 and bus.load_pc == bus.gba.cpu.r[15] and
     bus.load_start < bus.dma_bus_req:
    let a = bus.load_addr
    case bits_range(a, 24, 27)
    of 0x2, 0x5, 0x6, 0x8, 0x9, 0xA, 0xB, 0xC:
      if bits_range(a, 28, 31) == 0 and
         not (bits_range(a, 24, 27) >= 0x8 and address_in_gpio(a)):
        case bus.load_size
        of 4: return bus.read_word_internal(a)
        of 2:
          let h = uint32(bus.read_half_internal(a))
          return h or (h shl 16)
        else: return uint32(bus.read_byte_internal(a)) * 0x01010101'u32
    of 0x7:
      if bits_range(a, 28, 31) == 0:
        return bus.read_word_internal(a and not 3'u32)
    of 0x3:
      if bits_range(a, 28, 31) == 0:
        let w = bus.read_word_internal(a and not 3'u32)
        if bus.load_size == 4: return w
        # IWRAM's bus is 32 bits wide and keeps what it last carried: a
        # narrower load drives only its own lanes (alyosha Bus/DMA_IWRAM_Bus,
        # ROM code: the other half is the word the previous DMA wrote there).
        # With the code itself in IWRAM that is its fetched opcodes; else the
        # last word a DMA moved through IWRAM, as CPU accesses are not
        # tracked.
        let other = if bits_range(bus.gba.cpu.r[15], 24, 27) == 3:
                      bus.fetch_bus_word(bus.gba.cpu.r[15])
                    else: bus.iwram_latch
        let mask = if bus.load_size == 2: 0xFFFF'u32 shl ((a and 2) * 8)
                   else: 0xFF'u32 shl ((a and 3) * 8)
        return (w and mask) or (other and not mask)
    else: discard
  # Granted from the scheduler tick that closes an instruction (nothing of
  # the instruction synced yet, cpu.tick), r15 has already moved on to the
  # next one, whose fetch has not happened.
  var pc = bus.gba.cpu.r[15]
  if bus.synced == 0 and not bus.gba.cpu.halted:
    pc -= (if bus.gba.cpu.cpsr.thumb: 2'u32 else: 4'u32)
  bus.fetch_bus_word(pc)

proc read_open_bus_value*(bus: Bus; address: uint32): uint8 =
  uint8(bus.read_open_bus_word(address) shr ((address and 3) * 8))
