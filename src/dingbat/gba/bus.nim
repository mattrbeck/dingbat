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
  # EWRAM waits: 0x04000800 bits 24-27 (GBATEK "System Control"), waits =
  # 15 - field per halfword, a word twice. Field 13 (BIOS default) = 3/6.
  # AGB SP, gbaedge MEMCTL (docs/hwprobe-results-agb.md). Field 15 hangs
  # real hardware; here it is the fastest setting.
  block:
    let ws = int(bits_range(bus.gba.mmio.memctrl, 24, 27))
    let half = int8(1 + 15 - ws)
    bus.wait16_n[2] = half
    bus.wait16_s[2] = half
    bus.wait32_n[2] = 2 * half
    bus.wait32_s[2] = 2 * half
  # MEMCNT bit 5 clear: the board WRAM region reads and writes the chip
  # WRAM, at chip timing (AGB SP, payloads/memcnt.s; png183 memory t104-t106).
  # Derived state only: a state load restores the fetch page after this.
  let ewram_off = not bit(bus.gba.mmio.memctrl, 5)
  bus.ewram_off = ewram_off
  if ewram_off:
    bus.ew_ptr = cast[ptr UncheckedArray[byte]](addr bus.wram_chip[0])
    bus.ew_mask = 0x7FFF'u32
  else:
    bus.ew_ptr = cast[ptr UncheckedArray[byte]](addr bus.wram_board[0])
    bus.ew_mask = 0x3FFFF'u32
  if ewram_off:
    bus.wait16_n[2] = 1
    bus.wait16_s[2] = 1
    bus.wait32_n[2] = 1
    bus.wait32_s[2] = 1
  # MEMCNT bit 0 set swaps the low regions in pairs (swap_read_word): each
  # memory keeps its own timing at its new address.
  if bit(bus.gba.mmio.memctrl, 0):
    bus.sync_bits = bus.sync_bits or SB_SWAP
    for (a, b) in [(0, 2), (1, 3)]:
      swap(bus.wait16_n[a], bus.wait16_n[b])
      swap(bus.wait16_s[a], bus.wait16_s[b])
      swap(bus.wait32_n[a], bus.wait32_n[b])
      swap(bus.wait32_s[a], bus.wait32_s[b])
  else:
    bus.sync_bits = bus.sync_bits and not SB_SWAP
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
  # Prefetch hand-off lookup (see rom_access_cycles): bit e set iff a halfword
  # started e cycles ago is in its last cycle and the buffer is not yet full.
  for page in 0x8 .. 0xD:
    let s = int(bus.wait16_s[page])
    var m = 0'u64
    for e in 0 ..< min(64, 8 * s):
      if e mod s == s - 1: m = m or (1'u64 shl e)
    bus.pf_commit[page] = m

when defined(fetchprof):
  # -d:fetchprof (off by default): ROM access path counters. Indices:
  #   0/1 fetch_half hot/slow, 2/3 fetch_word hot/slow, 4/5 rac fetch/data,
  #   6 rac prefetch-hit, 7 plain-seq, 8 nonseq, 9 went hot after
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
  ## prefetcher off keeps the buffer: the halfword in flight completes, the
  ## CPU uses up what is buffered, then fetches nonsequentially (the drained
  ## pause state). Measured: AGBEEG aging cart toggle_prefetcher on hardware;
  ## landing the in-flight halfword at once reads low, dropping it 1 high.
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
    # Switched on after cycles off the ROM bus: the burst is broken, the
    # next fetch is nonsequential and the prefetcher starts behind it
    # (toggle_prefetcher enable half; crediting the write cycle reads low)
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
  ## At eight halfwords the prefetcher stops until the CPU has taken every
  ## one; the next fetch is the CPU's own, nonsequential (pf_serve_stopped).
  ## Pinned by alyosha prefetcher_full_* and prefetcher_branch_thumb_4;
  ## stopping at 7 or 9 fails them.
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

# A CPU data access is nonsequential unless back to back with the previous
# ROM access: ARM7TDMI data sheet, a load's or store's data cycle (and an
# LDM/STM's first transfer) has SEQ low. GBATEK "GamePak Prefetch": the
# prefetcher affects only opcode fetches. -d:ROM_DATA_NONSEQ=false treats an
# address-continuing data access as sequential under the prefetcher however
# long the CPU was off the bus; that runs Klonoa 2's HuffUnComp loads a frame
# early (docs/playtest-bugs.md §58).
const ROM_DATA_NONSEQ {.booldefine.} = true

proc rom_access_cycles(bus: Bus; address: uint32; is32: bool; fetch: bool): int {.inline.} =
  ## Cycle cost of a ROM-region (pages 8-D) access, tracking burst
  ## sequentiality and the prefetch buffer. Sequential = the address
  ## continues the previous ROM access; a CPU data access, and with the
  ## prefetch buffer off a fetch too, additionally breaks the burst whenever
  ## the CPU spent cycles off the ROM bus (ROM_DATA_NONSEQ).
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
      # Bus still hot from the previous DMA access (ROM-to-ROM write after
      # read) is sequential, except the DMA's first ROM access:
      # rom_next_addr == 1 is the cold sentinel seeded at DMA start
      seq = true
      bus.rom_next_addr2 = bus.rom_next_addr
      bus.rom_next_addr = address
    else:
      seq = false
      bus.rom_next_addr2 = bus.rom_next_addr
      bus.rom_next_addr = address
  elif fetch or not ROM_DATA_NONSEQ:
    seq = address == bus.rom_next_addr and
          (bus.prefetch_on or contiguous or (fetch and bus.pf_paused))
  else:
    seq = address == bus.rom_next_addr and contiguous
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
    # prefetcher, `elapsed mod s` cycles into a halfword. One in its
    # address/wait phase is abandoned free; one in its final cycle has
    # committed and the CPU waits that cycle. Nothing is in flight once the
    # buffer is full (8*s). Only while executing from the gamepak. Pinned by
    # the mGBA suite Timing "ROM" prefetch columns (LDR/LDM). `elapsed` is 0
    # when the waitloop fast-forward pushed rom_free_since past `now`.
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
    # Prefetch hand-off to a DMA burst: the same arbitration, at the burst's
    # FIRST ROM access (the prefetcher then stops for the burst). Phase is
    # counted from the grant, not `now - rom_free_since`: inside an event
    # dispatch tick_slow has rewound sched.cycles, so `now` lags the bus by
    # 0..3. The request is asserted the cycle before the access, so "final
    # cycle" ((k-1) mod s == s-1) is `k mod s == 0`. Pinned by the mGBA suite
    # DMA/ROM Timing tests (k = 2 for a ROM-read burst, 3 for ROM-write).
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
  ## * The first halfword of a 128 KiB block: the prefetcher acts full at a
  ##   0x20000 boundary (alyosha prefetcher/readme.txt; GBATEK has the block
  ##   start nonsequential). Pinned by alyosha bounday_test_1 and
  ##   prefetcher_boundary_1-4; buffer-served reads 8 short, no final-cycle
  ##   wait 1 short.
  ## * An ARM fetch with address bit 1 set (only via `bx`; cpu.read_instr
  ##   keeps the bit, as the console does). The gamepak returns the aligned
  ##   word, so the prefetcher's halfwords never match. Pinned by alyosha
  ##   prefetcher_branch_thumb_arm_3 (after an I/O load: N, not 2 from the
  ##   buffer). A fetch continuing an unbroken burst is plain S.
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
  ## Fetch-only copy of `rom_access_cycles` (too large for clang to inline;
  ## DMA trackers and hand-off are dead on a fetch). Kept in step by hand;
  ## the framebuffer-hash A/B and the mGBA Timing suite catch drift.
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
    when defined(itrace):
      let pf_rfs_in = bus.rom_free_since
      let pf_paused_in = bus.pf_paused
    if unbuffered:
      cost = bus.rom_fetch_unbuffered(now, page, when is32: 2 else: 1)
    else:
      cost = bus.pf_serve(now, page, when is32: 2 else: 1)
    when PF_WAIT_UNDER_BURST:
      if cost > 1:
        bus.pf_wait_from = now
        bus.pf_wait_to = now + CycleCount(cost)
    when defined(itrace):
      itl("  PFC a=" & toHex(address, 8) & " now=" & $now & " rfs=" & $pf_rfs_in &
          " paused=" & $pf_paused_in & " cnt=" & $bus.pf_count & " cost=" & $cost &
          " rfs_out=" & $bus.rom_free_since)
  else:
    cost =
      if address == bus.rom_next_addr and now == bus.rom_free_since:
        int(when is32: bus.wait32_s[page] else: bus.wait16_s[page])
      else:
        int(when is32: bus.wait32_n[page] else: bus.wait16_n[page])
    when defined(itrace):
      itl("  RFC a=" & toHex(address, 8) & " now=" & $now & " next=" & toHex(bus.rom_next_addr, 8) &
          " rfs=" & $bus.rom_free_since & " cost=" & $cost)
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

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}
proc contend_cost(bus: Bus; address: uint32; is32: bool; cost: int): int {.noinline.} =
  ## An access starting now: its cost plus the renderer's wait. The common
  ## case -- palette RAM or BG VRAM on a drawn line with the maps current --
  ## is answered here from the next 33+ dots of the map; everything else
  ## goes to contention.nim.
  bus.contended_access = true
  bus.dyn_cont = true
  let ppu {.cursor.} = bus.gba.ppu
  let dot = int(int64(bus.sched.cycles) + int64(bus.cycles) - ppu.line_start_cycle)
  if dot >= 0 and dot < 1232 and ppu.vcount < 160 and not ppu.cont_regs_stale and
     address < 0x10000000'u32:
    let page = bits_range(address, 24, 27)
    let wi = dot shr 5
    var win: uint64
    if page == 5:
      win = (uint64(ppu.cont_pram[wi]) or (uint64(ppu.cont_pram[wi + 1]) shl 32)) shr (dot and 31)
    elif page == 6 and (address and 0x1FFFF'u32) <
         (if ppu.dispcnt.bg_mode >= 3: 0x14000'u32 else: 0x10000'u32):
      win = (uint64(ppu.cont_bg[wi]) or (uint64(ppu.cont_bg[wi + 1]) shl 32)) shr (dot and 31)
    else:
      return bus.contend_slow(address, is32, cost)
    # the first free dot (a halfword's), and for a word the one after it
    let f1 = countTrailingZeroBits(not win)
    if f1 < 16:
      if not is32: return cost + f1
      let f2 = countTrailingZeroBits(not (win shr (f1 + 1)))
      if f2 < 16: return cost + f1 + f2
  bus.contend_slow(address, is32, cost)
{.pop.}

proc access_cycles(bus: Bus; address: uint32; is32: bool; fetch: bool): int {.inline.} =
  if bits_range(address, 28, 31) > 0:
    # Unmapped (open bus): one internal cycle, and the ROM burst trackers are
    # left alone
    return 1
  let page = int(bits_range(address, 24, 27))
  if page >= 0x8:
    if page <= 0xD:
      bus.rom_access_cycles(address, is32, fetch)
    else:
      int(bus.wait16_n[page])  # SRAM: 8-bit bus, same cost either way
  else:
    # Via the bus tables, which carry the MEMCNT EWRAM waits and region swap
    let c = int(if is32: bus.wait32_n[page] else: bus.wait16_n[page])
    # Palette RAM, VRAM and OAM while the renderer may hold them
    # (Bus.contended, contention.nim): the access waits for its dots
    if bus.contended[page]: bus.contend_cost(address, is32, c) else: c

proc write_stub_u32(bios: var seq[byte]; offset: int; value: uint32) =
  bios[offset + 0] = byte(value)
  bios[offset + 1] = byte(value shr 8)
  bios[offset + 2] = byte(value shr 16)
  bios[offset + 3] = byte(value shr 24)

{.push quirky: off.}   # opens the BIOS file (gba.nim, quirky)
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
    # UND: the real handler at 0x1C (hand-decoded from the BIOS image) saves
    # SPSR/CPSR on a stack at 0x03007FF0, calls the ROM's debug handler at
    # 0x09FE2000 / 0x09FFC000 only if header byte 09Ch == 0xA5 (0B4h bit 7
    # picks one), else restores and returns with subs pc, lr, #4. lr_und is
    # the instruction + 4, so it re-executes the faulting instruction (ARM)
    # or one halfword before it (Thumb) for ever, IRQs still breaking in.
    # Retail ROMs see only that loop, so the stub keeps only the `subs`; the
    # push/pop scribble at 0x03007FE0-0x03007FEF and sp_und are invisible.
    write_stub_u32(result.bios, 0x004, 0xEA000004'u32)
    # The prefetch-abort, data-abort and reserved vectors branch to the same
    # handler, as in the real BIOS. Only a jump there reaches one (a write of
    # 0x10 to r15: AGB SP returns through the handler; docs/hwprobe-sst.md,
    # x.mrs_r15)
    write_stub_u32(result.bios, 0x00C, 0xEA000002'u32)  # b 0x1C
    write_stub_u32(result.bios, 0x010, 0xEA000001'u32)  # b 0x1C
    write_stub_u32(result.bios, 0x014, 0xEA000000'u32)  # b 0x1C
    write_stub_u32(result.bios, 0x01C, 0xE25EF004'u32)
    write_stub_u32(result.bios, 0x018, 0xEA000042'u32)
    write_stub_u32(result.bios, 0x128, 0xE92D500F'u32)
    write_stub_u32(result.bios, 0x12C, 0xE3A00301'u32)
    write_stub_u32(result.bios, 0x130, 0xE28FE000'u32)
    write_stub_u32(result.bios, 0x134, 0xE510F004'u32)
    write_stub_u32(result.bios, 0x138, 0xE8BD500F'u32)
    write_stub_u32(result.bios, 0x13C, 0xE25EF004'u32)
    # Halt parks on the `bx lr` after its HALTCNT write (hle_halt), which
    # returns to the dispatcher at 0x170, run as instructions so a DMA or an
    # interrupt meets it between the same accesses as on the console. The
    # pops read the HLE's frame {caller CPSR, r12, return} (hle_bios
    # push_halt_svc_frame); the console pops {r11, r12, lr} after the SPSR,
    # so 0x184 is a trap that makes its three reads (cpu.hle_halt_return).
    write_stub_u32(result.bios, 0x1B4, 0xE12FFF1E'u32)  # bx lr
    write_stub_u32(result.bios, 0x170, 0xE8BD4004'u32)  # pop  {r2, lr}
    write_stub_u32(result.bios, 0x174, 0xE3A0C0D3'u32)  # mov  ip, #0xD3
    write_stub_u32(result.bios, 0x178, 0xE129F00C'u32)  # msr  cpsr_fc, ip
    write_stub_u32(result.bios, 0x17C, 0xE8BD4000'u32)  # pop  {lr}
    write_stub_u32(result.bios, 0x180, 0xE169F00E'u32)  # msr  spsr_fc, lr
    write_stub_u32(result.bios, 0x184, 0xEF000000'u32)  # swi 0 (pop {ip, lr})
    write_stub_u32(result.bios, 0x188, 0xE1B0F00E'u32)  # movs pc, lr
    # Never executed: the word the `movs` leaves in the BIOS latch (two
    # ahead), as every HLE return leaves it
    write_stub_u32(result.bios, 0x190, 0xE3A02004'u32)
    # The rest of the dispatcher after its `msr` and the Halt routine, as the
    # real BIOS has them: a Halt entered with an interrupt already pending
    # takes it at 0x164 and runs on from there (hle_bios halt_from_dispatcher)
    write_stub_u32(result.bios, 0x164, 0xE92D4004'u32)  # push {r2, lr}
    write_stub_u32(result.bios, 0x168, 0xE28FE000'u32)  # add  lr, pc, #0
    write_stub_u32(result.bios, 0x16C, 0xE12FFF1C'u32)  # bx   ip
    write_stub_u32(result.bios, 0x1A0, 0xE3A02000'u32)  # mov  r2, #0
    write_stub_u32(result.bios, 0x1A4, 0xEA000000'u32)  # b    0x1AC
    write_stub_u32(result.bios, 0x1AC, 0xE3A0C301'u32)  # mov  ip, #0x04000000
    write_stub_u32(result.bios, 0x1B0, 0xE5CC2301'u32)  # strb r2, [ip, #0x301]
    # Never executed: the words after the halt's `bx lr`, the default user
    # and IRQ stack tops (GBATEK, BIOS RAM usage). A halted CPU's last fetch
    # is the second; a DMA granted under the halt reads its upper half (AGB
    # SP, payloads/hdmaobus.s 0x300: 0300).
    # A CpuSet / CpuFastSet preempted by an interrupt parks here, in BIOS
    # code as on the console; the interrupt returns to this trap into the
    # HLE (hle_copy.nim, COPY_TRAP)
    write_stub_u32(result.bios, 0xBC8, 0xEF000000'u32)  # swi 0 (copy resume)
    # The decompression and unpack routines run as BIOS code here, one
    # instruction per address, each an ARM or a Thumb `swi 0` the HLE
    # executes by where it is (hle_unc.nim)
    for a in countup(int(UNC_ARM_LO), int(UNC_ARM_HI) - 4, 4):
      write_stub_u32(result.bios, a, 0xEF000000'u32)
    for a in countup(int(UNC_THUMB_LO), int(UNC_THUMB_HI) - 2, 2):
      result.bios[a] = 0x00'u8
      result.bios[a + 1] = 0xDF'u8
    # Below the IRQ handler, where the console has code, a `b .`: a routine
    # handed a source there finds a header of nonzero length, as on the
    # console (tools/biosdrv/swisp2.c, source 0x100)
    for a in countup(0x100, 0x124, 4):
      write_stub_u32(result.bios, a, 0xEAFFFFFE'u32)
    write_stub_u32(result.bios, 0x1B8, 0x03007F00'u32)
    write_stub_u32(result.bios, 0x1BC, 0x03007FA0'u32)
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
    # SoundGetJumpList (SWI 0x2A): the real BIOS's 36 sound-driver addresses
    # (copied to [r0] from BIOS 0x3738), for games that compare pointers.
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
    # SoundDriverMain's callback returns (hle_sound.nim sd_main): the real
    # routine calls SoundInfo +0x20 and +0x28 with lr 0x1DF1 / 0x1DF9, so
    # Thumb `swi 0` traps sit there. 0x1709, the default Init puts in the
    # SoundInfo function slots, returns at once.
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
  # Puzzle (GBATEK names the titles). The tilt window is intercepted before
  # storage regardless of the save heuristic.
  result.tilt_present = gba.cartridge != nil and
    gba.cartridge.game_code() in ["KYGE", "KYGJ", "KYGP", "KHPJ"]
  result.update_waitcnt(WAITCNT())  # reset-state waitstates

{.pop.}

proc bus_page(address: uint32): int {.inline.} =
  int(bits_range(address, 24, 27))

# Tilt sensor (0x0E008000-0x0E008500, GBATEK "GBA Cart Tilt Sensor"): write
# 0x55 to 0x8000 to arm, 0xAA to 0x8100 to latch a 12-bit sample per axis.
# Reads deliver low byte / high nibble; E008300h bit 7 is "ADC Status
# (0=Busy, 1=Ready)". Conversion time is undocumented, so ready is always
# set: assumed (no cart on the rig). The rest of the window reads 0xFF.
# Centres per GBATEK's calibration ("X ranged between 0x2AF to 0x477, center
# at 0x392", "Y ... 0x2C3 to 0x480, center at 0x3A0").

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

# Stores into PRAM, VRAM and OAM. Only one that changes what is there dirties
# the frame (ppu.render_dirty, the whole-frame render skip): a game that
# rewrites the same palette or OAM every frame draws the same picture.
proc vid_store16(ppu: PPU; buf: var seq[byte]; offset: uint32; val: uint16) {.inline.} =
  if read_u16_ptr(buf, offset) != val:
    ppu.render_dirty = true
    write_u16_ptr(buf, offset, val)

proc vid_store32(ppu: PPU; buf: var seq[byte]; offset: uint32; val: uint32) {.inline.} =
  if read_u32_ptr(buf, offset) != val:
    ppu.render_dirty = true
    write_u32_ptr(buf, offset, val)

# The OBJ contention map (contention.nim cont_build_obj) reads only attr0's
# Y, affine, double-size/disable and shape bits and attr1's size bits. A
# store that leaves those alone keeps the map (else H-blank DMA rewriting
# OAM every line rebuilds it on every access); one that moves an entry keeps
# it unless the entry is on the map's line (cont_obj_entry_moved).
const OAM_CONT_MASK16 = [0xC3FF'u16, 0xC000'u16, 0'u16, 0'u16]

proc oam_store16(ppu: PPU; offset: uint32; val: uint16) {.inline.} =
  ppu.oam_view_stale = true   # as every OAM store (serialized); see oam_touched
  let old = read_u16_ptr(ppu.oam, offset)
  if old != val:
    ppu.render_dirty = true
    write_u16_ptr(ppu.oam, offset, val)
    if ((old xor val) and OAM_CONT_MASK16[(offset shr 1) and 3]) != 0:
      let e = offset and not 7'u32
      let a0 = if (offset and 2) == 0: old else: read_u16_ptr(ppu.oam, e)
      let a1 = if (offset and 2) != 0: old else: read_u16_ptr(ppu.oam, e + 2)
      ppu.cont_obj_entry_moved(int(offset shr 3), a0, a1)

proc oam_store32(ppu: PPU; offset: uint32; val: uint32) {.inline.} =
  ppu.oam_view_stale = true   # as every OAM store (serialized); see oam_touched
  let old = read_u32_ptr(ppu.oam, offset)
  if old != val:
    ppu.render_dirty = true
    write_u32_ptr(ppu.oam, offset, val)
    # word 0 of an entry is attr0 | attr1 shl 16; word 1 (attr2, the
    # affine parameter) is never read by the map
    if (offset and 4) == 0 and ((old xor val) and 0xC000C3FF'u32) != 0:
      ppu.cont_obj_entry_moved(int(offset shr 3), uint16(old), uint16(old shr 16))

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
  when defined(cpu_testbus): return uint8(gba_testbus_peek(1, address))
  if bits_range(address, 28, 31) > 0:
    # 10000000-FFFFFFFF is not decoded: open bus, never a mirror. Minish Cap
    # reads an animation script through a NULL entry and escapes only
    # because the BIOS latch holds a non-zero prefetched opcode.
    return bus.read_open_bus_value(address)
  case bits_range(address, 24, 27)
  of 0x0:
    if bits_range(bus.gba.cpu.r[15], 24, 27) == 0:
      bus.bios[address and 0x3FFF'u32]
    elif (address and 0x00FFFFFF'u32) >= 0x4000'u32 and not bus.dma_active:
      # 00004000-00FFFFFF is unused memory: a CPU read gets open bus, not
      # the BIOS latch (GBATEK "Reading from Unused Memory")
      bus.read_open_bus_value(address)
    else:
      # Outside the BIOS, BIOS reads return the last fetched BIOS opcode
      # (GBATEK "Reading from BIOS Memory")
      let shift = (address and 3) * 8
      uint8(bus.bios_latch shr shift)
  of 0x1: bus.read_open_bus_value(address)
  of 0x2: bus.ew_ptr[address and bus.ew_mask]
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
  when defined(cpu_testbus): return uint16(gba_testbus_peek(2, address))
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
  of 0x2: read_u16_ptr_raw(bus.ew_ptr, address and bus.ew_mask)
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
  when defined(cpu_testbus): return gba_testbus_peek(4, address)
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
  of 0x2: read_u32_ptr_raw(bus.ew_ptr, address and bus.ew_mask)
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
  # Self-modifying code: a write to the two opcodes already fetched must not
  # affect execution, so snapshot them first. Not while a refill is pending:
  # the refill must see the write (Golden Sun TLA's stack trampoline)
  if not bus.gba.cpu.refill_pending and
     address <= bus.gba.cpu.r[15] and address >= bus.gba.cpu.r[15] - 4:
    bus.gba.cpu.fill_pipeline()
  case bits_range(address, 24, 27)
  of 0x2:
    sndWatch(bus, address, 1, uint32(value))
    bus.ew_ptr[address and bus.ew_mask] = value
    wcWatch(bus, address, 1)
  of 0x3:
    sndWatch(bus, address, 1, uint32(value))
    bus.wram_chip[address and 0x7FFF'u32] = value
    chipWatch(bus, address and 0x7FFF'u32, uint32(value), 1)
    wcWatch(bus, address, 1)
  of 0x4: bus.gba.mmio[address] = value
  of 0x5:
    bus.gba.ppu.vid_store16(bus.gba.ppu.pram, address and 0x3FE'u32, 0x0101'u16 * uint16(value))
  of 0x6:
    let limit: uint32 = if bus.gba.ppu.bitmap(): 0x13FFF'u32 else: 0x0FFFF'u32
    var a = 0x1FFFE'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    if a <= limit:
      bus.gba.ppu.vid_store16(bus.gba.ppu.vram, a, 0x0101'u16 * uint16(value))
  of 0x7: discard  # can't write bytes to oam
  of 0x8, 0xD:
    if address_in_gpio(address):
      bus.gpio[address] = value
    elif bus.gba.storage.eeprom_at(address):
      # STRB pulses /WR with the byte on every lane, so AD0 carries its bit
      # 0. Only the CPU stores bytes: a frame of its own (storage/eeprom.nim)
      bus.gba.storage[address] = value
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
    cast[ptr uint16](addr bus.ew_ptr[address and bus.ew_mask])[] = value
    wcWatch(bus, address, 2)
  of 0x3:
    sndWatch(bus, address, 2, uint32(value))
    write_u16_ptr(bus.wram_chip, address and 0x7FFF'u32, value)
    chipWatch(bus, address and 0x7FFF'u32, uint32(value), 2)
    wcWatch(bus, address, 2)
  of 0x4:
    if (address and 0xFFFFFF'u32) == 0x132'u32:
      # KEYCNT: one 16-bit store, so the keypad IRQ check never sees half
      bus.gba.keypad.write_keycnt16(value)
    else:
      bus.write_byte_internal(address, uint8(value))
      bus.write_byte_internal(address + 1, uint8(value shr 8))
  of 0x5:
    bus.gba.ppu.vid_store16(bus.gba.ppu.pram, address and 0x3FF'u32, value)
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    bus.gba.ppu.vid_store16(bus.gba.ppu.vram, a, value)
  of 0x7:
    bus.gba.ppu.oam_store16(address and 0x3FF'u32, value)
  of 0x8, 0xD:
    if address_in_gpio(address):
      bus.gpio[address] = uint8(value)
    elif bus.gba.storage.eeprom_at(address):
      bus.gba.storage[address] = uint8(value)
  of 0xE, 0xF:
    # 8-bit backup bus: STRH drives the halfword on both halves and the chip
    # latches the lane A0 selects, so an odd address stores the high byte
    # (GBATEK "GBA Cart Backup SRAM/FLASH"; jsmolka save/* test 6). Tilt too.
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
    cast[ptr uint32](addr bus.ew_ptr[address and bus.ew_mask])[] = value
    wcWatch(bus, address, 4)
  of 0x3:
    sndWatch(bus, address, 4, value)
    write_u32_ptr(bus.wram_chip, address and 0x7FFF'u32, value)
    chipWatch(bus, address and 0x7FFF'u32, value, 4)
    wcWatch(bus, address, 4)
  of 0x4:
    if (address and 0xFFFFFF'u32) == 0x130'u32:
      # Word store over KEYINPUT (read-only) + KEYCNT: KEYCNT in one store
      bus.write_byte_internal(address,     uint8(value))
      bus.write_byte_internal(address + 1, uint8(value shr 8))
      bus.gba.keypad.write_keycnt16(uint16(value shr 16))
    else:
      bus.write_byte_internal(address,     uint8(value))
      bus.write_byte_internal(address + 1, uint8(value shr 8))
      bus.write_byte_internal(address + 2, uint8(value shr 16))
      bus.write_byte_internal(address + 3, uint8(value shr 24))
  of 0x5:
    bus.gba.ppu.vid_store32(bus.gba.ppu.pram, address and 0x3FF'u32, value)
  of 0x6:
    var a = 0x1FFFF'u32 and address
    if a > 0x17FFF'u32: a -= 0x8000'u32
    bus.gba.ppu.vid_store32(bus.gba.ppu.vram, a, value)
  of 0x7:
    bus.gba.ppu.oam_store32(address and 0x3FF'u32, value)
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

# ---- MEMCNT bit 0: the swap ----
#
# With MEMCNT (0x04000800) bit 0 set the decoder swaps the low regions in
# pairs: 00xxxxxx board WRAM, 01xxxxxx chip WRAM, 02xxxxxx the BIOS (still
# read-protected), 03xxxxxx unused memory (AGB SP, payloads/memcnt.s cells
# 8-12). update_waitcnt sets SB_SWAP in bus.sync_bits, so accesses leave the
# fast path through its one test; pages 0-3 stay off the fetch cache.

proc swap_privileged(bus: Bus): bool {.inline.} =
  ## Whether the BIOS answers a read with its contents: when r15 is in the
  ## BIOS at its swapped home. Not by address, unlike HALTCNT (mmio.nim):
  ## on an AGB SP code in chip WRAM at 01xxxxxx or board WRAM at 00xxxxxx
  ## reads the latch (memcnt.s cells 14, 15). A fetch always gets them.
  (bus.swap_fetching and not bus.dma_active) or
    bits_range(bus.gba.cpu.r[15], 24, 31) == 0x02'u32

proc swap_bios_word(bus: Bus; address: uint32): uint32 =
  ## A word read of the BIOS at 02000000, as read_word_internal's page 0
  ## reads it at home.
  if bus.swap_privileged():
    read_u32_ptr(bus.bios, address and 0x3FFC'u32)
  elif (address and 0x00FFFFFF'u32) >= 0x4000'u32 and not bus.dma_active:
    bus.read_open_bus_word(address)
  else:
    bus.bios_latch

proc swap_low_word(bus: Bus; address: uint32): uint32 =
  ## The aligned word at `address` in page 2 or 3 of the swapped map.
  if bits_range(address, 24, 27) == 0x2: bus.swap_bios_word(address)
  else: bus.read_open_bus_word(address)

proc swap_read_byte(bus: Bus; address: uint32): uint8 {.noinline.} =
  if bits_range(address, 24, 27) < 0x2:
    bus.read_byte_internal(address xor 0x02000000'u32)
  else:
    uint8(bus.swap_low_word(address and not 3'u32) shr ((address and 3) * 8))

proc swap_read_half(bus: Bus; address: uint32): uint16 {.noinline.} =
  if bits_range(address, 24, 27) < 0x2:
    bus.read_half_internal(address xor 0x02000000'u32)
  else:
    uint16(bus.swap_low_word(address and not 3'u32) shr ((address and 2) * 8))

proc swap_read_word(bus: Bus; address: uint32): uint32 {.noinline.} =
  if bits_range(address, 24, 27) < 0x2:
    bus.read_word_internal(address xor 0x02000000'u32)
  else:
    bus.swap_low_word(address and not 3'u32)

template swap_smc(bus: Bus; address: uint32) =
  # write_*_internal's pipeline capture, made at the address the CPU fetched
  # from (it compares the translated one)
  let a = address and not 3'u32
  if not bus.gba.cpu.refill_pending and
     a <= bus.gba.cpu.r[15] and a >= bus.gba.cpu.r[15] - 4:
    bus.gba.cpu.fill_pipeline()

proc swap_write_byte(bus: Bus; address: uint32; value: uint8) {.noinline.} =
  if bits_range(address, 24, 27) < 0x2:   # the BIOS and unused memory ignore it
    bus.swap_smc(address)
    bus.write_byte_internal(address xor 0x02000000'u32, value)

proc swap_write_half(bus: Bus; address: uint32; value: uint16) {.noinline.} =
  if bits_range(address, 24, 27) < 0x2:
    bus.swap_smc(address)
    bus.write_half_internal(address xor 0x02000000'u32, value)

proc swap_write_word(bus: Bus; address: uint32; value: uint32) {.noinline.} =
  if bits_range(address, 24, 27) < 0x2:
    bus.swap_smc(address)
    bus.write_word_internal(address xor 0x02000000'u32, value)

proc read_byte_mapped(bus: Bus; address: uint32): uint8 =
  if address < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
    bus.swap_read_byte(address)
  else: bus.read_byte_internal(address)

proc read_half_mapped(bus: Bus; address: uint32): uint16 =
  if address < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
    bus.swap_read_half(address)
  else: bus.read_half_internal(address)

proc read_word_mapped(bus: Bus; address: uint32): uint32 =
  if address < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
    bus.swap_read_word(address)
  else: bus.read_word_internal(address)

proc write_byte_mapped(bus: Bus; address: uint32; value: uint8) =
  if address < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
    bus.swap_write_byte(address, value)
  else: bus.write_byte_internal(address, value)

proc write_half_mapped(bus: Bus; address: uint32; value: uint16) =
  if address < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
    bus.swap_write_half(address, value)
  else: bus.write_half_internal(address, value)

proc write_word_mapped(bus: Bus; address: uint32; value: uint32) =
  if address < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
    bus.swap_write_word(address, value)
  else: bus.write_word_internal(address, value)

# ---- Instruction-fetch fast path ----

proc fetch_half_miss(bus: Bus; address: uint32): uint16
proc fetch_word_miss(bus: Bus; address: uint32): uint32
proc swap_fetch_half(bus: Bus; address: uint32): uint16 {.noinline.}
proc swap_fetch_word(bus: Bus; address: uint32): uint32 {.noinline.}

proc imm_fetch_page(page: uint32): bool {.inline.} =
  ## IMM_FETCH_WAIT's pages: those whose fetches last more than a cycle and
  ## were measured (board WRAM, the gamepak). IWRAM fetches take one cycle,
  ## so no request lands inside one.
  page == 0x2 or (page >= 0x8 and page <= 0xD)

proc install_fetch_cache(bus: Bus; page: uint32): bool =
  when DMA_ACCESS_WINDOW:
    if (bus.sync_bits and 2) != 0: return false
  when IMM_FETCH_WAIT:
    if (bus.sync_bits and 1) != 0 and imm_fetch_page(page): return false
  when FIFO_FETCH_WINDOW:
    if (bus.sync_bits and 16) != 0 and imm_fetch_page(page): return false
  when IRQ_LAST_WAITS:
    if (bus.sync_bits and 8) != 0: return false
  # Only plain masked-read pages are cacheable: not BIOS, MMIO, open bus,
  # 0xD (possible EEPROM), or pages 0-3 under MEMCNT's swap
  case page
  of 0x2:
    if (bus.sync_bits and SB_SWAP) != 0: return false
    bus.fetch_ptr = bus.ew_ptr
    bus.fetch_mask = bus.ew_mask
  of 0x3:
    if (bus.sync_bits and SB_SWAP) != 0: return false
    bus.fetch_ptr = cast[ptr UncheckedArray[byte]](addr bus.wram_chip[0])
    bus.fetch_mask = 0x7FFF'u32
  of 0x8, 0x9, 0xA, 0xB, 0xC:
    bus.fetch_ptr = cast[ptr UncheckedArray[byte]](addr bus.gba.cartridge.rom[0])
    bus.fetch_mask = bus.gba.cartridge.rom_mask
  else:
    return false
  bus.fetch_page = page
  bus.fetch_key = page
  # Read only on the pages 2/3 fetch path
  bus.fetch_c16 = int(bus.wait16_n[int(page)])
  bus.fetch_c32 = int(bus.wait32_n[int(page)])
  true

const OBUS_LEAD {.intdefine.} = 0
const OBUS_BOUNDARY_HALF {.booldefine.} = true
  ## Thumb code in IWRAM/BIOS reading open bus right after a burst that won
  ## the bus from its own fetch sees half DMA word, half opcode
  ## (read_open_bus_word).
  ## -d:OBUS_LEAD=N (default 0, -d:obuslatch only): stamp latch halves N
  ## cycles ahead, for the next fetch the pipeline issues before dingbat
  ## charges it. The mGBA suite's Break test moves only in 34-read steps.

when defined(obuslatchdbg):
  # -d:obuslatchdbg (off by default): logs to OLAT_LOG, since the harness
  # owns stdout and stderr.
  var olat_file: File
  var olat_ready = false
  proc olat_log(msg: string) =
    if not olat_ready:
      olat_ready = olat_file.open(getEnv("OLAT_LOG", "/tmp/olat.txt"), fmAppend)
    if olat_ready:
      olat_file.writeLine(msg)
      olat_file.flushFile()

when defined(obuslatch):
  # -d:obuslatch (off by default): a real per-halfword open-bus latch
  # (docs/playtest-bugs.md §13). How much one access fills depends on the
  # memory (obusbus.s): IWRAM and BIOS fill the half address bit 1 selects,
  # OAM the aligned word, 16-bit memories (EWRAM, VRAM, gamepak) mirror.
  proc obus_stamp(bus: Bus): CycleCount {.inline.} =
    # The live bus clock: `sched.cycles - synced` is pinned until catch_up,
    # so every fetch in a run of NOPs would get the same stamp.
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

proc fetch_half_cached(bus: Bus; address: uint32; page: uint32): uint16 {.fetch_inline.} =
  ## The cached-page fetch: `page` is bus.fetch_page.
  if page >= 0x8:
    # While the fetch stream is hot, a sequential fetch is a plain S
    # access with no absolute-time bookkeeping
    if bus.rom_hot and address == bus.rom_next_addr:
      when defined(fetchprof): fetchprof[0].inc
      when defined(pftrace):
        pft("  HOT fetch16 a=" & toHex(address, 8) & " now=" & $bus.bus_now() &
            " cost=" & $int(bus.wait16_s[page]))
      when PF_WAIT_UNDER_BURST:
        if bus.prefetch_on:
          bus.pf_wait_from = bus.bus_now()
          bus.pf_wait_to = bus.pf_wait_from + CycleCount(bus.wait16_s[page])
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

proc fetch_half*(bus: Bus; address: uint32): uint16 {.fetch_inline.} =
  when defined(cpu_testbus): return uint16(gba_testbus_read(0, 2, address))
  let page = bits_range(address, 24, 27)
  if page == bus.fetch_key or bus.install_fetch_cache(page):
    bus.fetch_half_cached(address, page)
  else:
    bus.fetch_half_miss(address)

proc fetch_word_cached(bus: Bus; address: uint32; page: uint32): uint32 {.fetch_inline.} =
  ## The cached-page fetch: `page` is bus.fetch_page.
  if page >= 0x8:
    if bus.rom_hot and address == bus.rom_next_addr:
      when defined(fetchprof): fetchprof[2].inc
      when defined(pftrace):
        pft("  HOT fetch32 a=" & toHex(address, 8) & " now=" & $bus.bus_now() &
            " cost=" & $int(bus.wait32_s[page]))
      when PF_WAIT_UNDER_BURST:
        if bus.prefetch_on:
          bus.pf_wait_from = bus.bus_now()
          bus.pf_wait_to = bus.pf_wait_from + CycleCount(bus.wait32_s[page])
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

proc fetch_word*(bus: Bus; address: uint32): uint32 {.fetch_inline.} =
  when defined(cpu_testbus): return gba_testbus_read(0, 4, address)
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
  # Advance the scheduler to the current mid-instruction cycle so MMIO sees
  # timers and IF exactly. Skipped while an event handler runs (handlers stay
  # pure; the post-dispatch DMA pump arbitrates) and, in the accessors, while
  # a DMA burst runs (no preemption between its read and write; the DMA loop
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
  ## bus for them, so a DMA overlapping them costs nothing: AGB SP,
  ## payloads/dmaphase.s, a 4-cycle H-blank DMA costs a multiply 4..0 as its
  ## request moves from the last internal cycle back to the fetch, and a load
  ## 3 not 4 when granted just before its internal cycle.
  bus.rom_cool()
  # FIFO_DMA_WINDOW: the internal cycles after a refill's grant close its window
  let closing = (bus.sync_bits and 32) != 0
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
  if closing and (bus.sync_bits and 32) != 0: bus.sync_bits = bus.sync_bits and not 48'u8

# The sync_bits leg (all six accessors): an immediate DMA fires
# DMA_START_DELAY cycles after arming while the CPU runs on, and an access's
# cycles reach the scheduler only at instruction end, so an access after the
# burst's start would land before it. Catch-up during the armed window keeps
# the CPU-vs-DMA memory order cycle-exact.
when defined(biosdrvtrace):
  # -d:biosdrvtrace, for tests/biosdrv_probe.nim: every CPU/DMA access
  var bdMemHook*: proc(address: uint32; width: int; value: uint32) {.closure.}
  var bdReadHook*: proc(address: uint32; width: int) {.closure.}
  template bdWatch(a: uint32; w: int; v: uint32) =
    if bdMemHook != nil: bdMemHook(a, w, v)
  template bdWatchRead(a: uint32; w: int) =
    if bdReadHook != nil: bdReadHook(a, w)
else:
  template bdWatch(a: uint32; w: int; v: uint32) = discard
  template bdWatchRead(a: uint32; w: int) = discard

template load_sync(bus: Bus; address: uint32; cost: int; size: int;
                   access: untyped) =
  ## A timed load's sync leg (the three loads below): see the note above.
  if not IRQ_LAST_WAITS or bus_page(address) == 0x4 or (bus.sync_bits and 23) != 0:
    when DMA_READS_CPU_BUS:
      bus.load_addr = address
      bus.load_size = size
      bus.load_pc = bus.gba.cpu.r[15]
      when DMA_READS_IO_LOAD: bus.load_io_ok = false
      bus.load_end = bus.bus_now()
      bus.load_start = bus.load_end - CycleCount(cost)
    when IMM_ACCESS_WAIT:
      bus.access_rom = bus_page(address) >= 0x8
      bus.access_write = false
      if bus.imm_pre: bus.imm_pre_grant(cost)
    bus.catch_up_access(cost)
    when IMM_ACCESS_WAIT:
      if bus.imm_post:
        result = access
        bus.imm_post_grant()
        return

template store_sync(bus: Bus; address: uint32; cost: int; access: untyped) =
  ## A timed store's sync leg (the three stores below).
  when IRQ_LAST_WAITS:
    if (bus.sync_bits and 8) != 0: bus.note_waits(cost)
  if not IRQ_LAST_WAITS or bus_page(address) == 0x4 or (bus.sync_bits and 23) != 0:
    # A store ends the load's claim on the bus (dma_bus_word): a burst after
    # it sees the fetched opcode, not the load or the store's data
    # (dmaobus2.s variant 7)
    when DMA_READS_CPU_BUS: bus.load_size = 0
    when IMM_ACCESS_WAIT:
      bus.access_rom = bus_page(address) >= 0x8
      bus.access_write = true
      if bus.imm_pre: bus.imm_pre_grant(cost)
    bus.catch_up_access(cost)
    when IMM_ACCESS_WAIT:
      if bus.imm_post:
        access
        bus.imm_post_grant()
        return

# Each timed access takes its sync leg for MMIO or while a sync_bits window
# is open. MMIO has its own copy, so the SB_SWAP test costs it nothing.

proc io_loaded[T: uint8 | uint16 | uint32](bus: Bus; address: uint32; v: T): T {.inline.} =
  ## The value a CPU load read from an I/O register, in its byte lanes, kept
  ## for a burst that finds it on the bus (DMA_READS_IO_LOAD,
  ## Bus.dma_bus_word)
  when DMA_READS_CPU_BUS and DMA_READS_IO_LOAD:
    bus.load_io = uint32(v) shl ((address and uint32(4 - sizeof(T))) * 8)
    bus.load_io_ok = true
  v

proc `[]`*(bus: Bus; address: uint32): uint8 =
  when defined(cpu_testbus): return uint8(gba_testbus_read(1, 1, address))
  bdWatchRead(address, 1)
  bus.rom_cool()
  let cost = bus.access_cycles(address, is32 = false, fetch = false)
  bus.cycles += cost
  if bus_page(address) == 0x4:
    if not bus.dma_active:
      bus.load_sync(address, cost, (if bus.ldrsh_odd: 2 else: 1), bus.io_loaded(address, bus.read_byte_internal(address)))
      return bus.io_loaded(address, bus.read_byte_internal(address))
  elif bus.sync_bits != 0:
    if not bus.dma_active:
      bus.load_sync(address, cost, (if bus.ldrsh_odd: 2 else: 1), bus.read_byte_mapped(address))
    if address < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
      return bus.swap_read_byte(address)
  bus.read_byte_internal(address)

proc read_half*(bus: Bus; address: uint32): uint16 =
  when defined(cpu_testbus): return uint16(gba_testbus_read(1, 2, address))
  bdWatchRead(address, 2)
  bus.rom_cool()
  let cost = bus.access_cycles(address, is32 = false, fetch = false)
  bus.cycles += cost
  if bus_page(address) == 0x4:
    if not bus.dma_active:
      bus.load_sync(address, cost, 2, bus.io_loaded(address, bus.read_half_internal(address)))
      return bus.io_loaded(address, bus.read_half_internal(address))
  elif bus.sync_bits != 0:
    if not bus.dma_active:
      bus.load_sync(address, cost, 2, bus.read_half_mapped(address))
    if address < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
      return bus.swap_read_half(address)
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
  when defined(cpu_testbus): return gba_testbus_read(1, 4, address)
  bdWatchRead(address, 4)
  bus.rom_cool()
  let cost = bus.access_cycles(address, is32 = true, fetch = false)
  bus.cycles += cost
  if bus_page(address) == 0x4:
    if not bus.dma_active:
      bus.load_sync(address, cost, 4, bus.io_loaded(address, bus.read_word_internal(address)))
      return bus.io_loaded(address, bus.read_word_internal(address))
  elif bus.sync_bits != 0:
    if not bus.dma_active:
      bus.load_sync(address, cost, 4, bus.read_word_mapped(address))
    if address < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
      return bus.swap_read_word(address)
  bus.read_word_internal(address)

proc swap_fetch_half(bus: Bus; address: uint32): uint16 {.noinline.} =
  ## A fetch from pages 0-3 under MEMCNT's swap: priced as an uncached fetch
  ## (read_half), read through the swapped map. The BIOS latch follows r15
  ## when r15 is in the BIOS, including code in chip WRAM just below it
  ## (01FFFFF8, r15 02000000: png183 memory t108, memcnt.s cell 17).
  bus.swap_fetching = true
  result = bus.read_half(address)
  bus.swap_fetching = false
  let pc = bus.gba.cpu.r[15]
  if bits_range(pc, 24, 31) == 0x02'u32:
    let v = uint32(read_u16_ptr(bus.bios, pc and 0x3FFE'u32))
    bus.bios_latch = v or (v shl 16)

proc swap_fetch_word(bus: Bus; address: uint32): uint32 {.noinline.} =
  ## swap_fetch_half's ARM twin.
  bus.swap_fetching = true
  result = bus.read_word(address)
  bus.swap_fetching = false
  let pc = bus.gba.cpu.r[15]
  if bits_range(pc, 24, 31) == 0x02'u32:
    bus.bios_latch = read_u32_ptr(bus.bios, pc and 0x3FFC'u32)

proc imm_refill_handover*(bus: Bus) =
  ## IMM_FETCH_WAIT: the CPU's next bus step after a fetch an immediate DMA's
  ## request landed in (another fetch, or a branch's refill): the burst takes
  ## the bus first, and the step is priced after it (a gamepak fetch after a
  ## burst is nonsequential).
  if bus.imm_pre and not bus.dma_active: bus.imm_pre_grant(0)

template imm_fetch(bus: Bus; address: uint32; fetch: untyped) =
  ## IMM_FETCH_WAIT: while an immediate DMA's request is pending (the few
  ## cycles after its enable; dma.nim drops the fetch cache for them), a
  ## board-WRAM or gamepak fetch syncs to its end like a load, so a request
  ## landing inside it waits for the whole fetch (imm_pre) and the CPU's
  ## next step hands over (an internal cycle through IMM_IDLE_GRANT, a data
  ## access through imm_pre_grant, a fetch or a refill here).
  when IMM_FETCH_WAIT:
    if (bus.sync_bits and 3) == 1 and not bus.dma_active and
       imm_fetch_page(bits_range(address, 24, 27)):
      bus.imm_refill_handover()
      if (bus.sync_bits and 3) == 1 and not bus.dma_active:
        bus.sync_bits = bus.sync_bits and not 1'u8
        let before = bus.cycles
        result = fetch
        bus.sync_bits = bus.sync_bits or 1
        let cost = bus.cycles - before
        bus.fetch_key = 0xFFFFFFFF'u32
        bus.access_rom = false
        bus.access_write = false
        bus.catch_up_access(cost)
      else:
        result = fetch
      return

template fifo_fetch(bus: Bus; address: uint32; fetch: untyped) =
  ## FIFO_FETCH_WINDOW: while a sound-FIFO refill request is near (the
  ## FIFO_DMA_WINDOW window), a board-WRAM or gamepak opcode fetch syncs to
  ## its end like a data access, so a request landing inside it is held off
  ## to the fetch's end, or waits behind it, by defer_fifo_request's rule.
  when FIFO_FETCH_WINDOW:
    if (bus.sync_bits and 16) != 0 and not bus.dma_active and
       imm_fetch_page(bits_range(address, 24, 27)):
      bus.sync_bits = bus.sync_bits and not 16'u8
      let before = bus.cycles
      result = fetch
      bus.sync_bits = bus.sync_bits or 16
      let cost = bus.cycles - before
      bus.fetch_key = 0xFFFFFFFF'u32
      bus.access_rom = false
      bus.access_write = false
      # an interrupt's window wants the fetch's waits noted, as below
      when IRQ_LAST_WAITS:
        if (bus.sync_bits and 8) != 0: bus.note_waits(cost)
      let fstart = bus.bus_now() - CycleCount(cost)
      bus.catch_up_access(cost)
      when IRQ_LAST_WAITS:
        # A burst that ran inside the fetch (granted as it began) ends it:
        # an interrupt recognised under the burst fell in the fetch's waits
        # and is taken an instruction later, as one in a plain fetch's is.
        let fnow = bus.bus_now()
        if (bus.sync_bits and 8) != 0 and bus.dma_end_at > fstart and
           bus.dma_end_at <= fnow:
          bus.lw_end = fnow
          bus.lw_waits = int(fnow - fstart) - 1
      return

proc fetch_half_miss(bus: Bus; address: uint32): uint16 =
  bus.imm_fetch(address, bus.fetch_half(address))
  bus.fifo_fetch(address, bus.fetch_half(address))
  if (bus.sync_bits and (SB_SWAP or 2'u8)) != 0:
    if (bus.sync_bits and SB_SWAP) != 0 and address < 0x04000000'u32:
      return bus.swap_fetch_half(address)
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
  bus.imm_fetch(address, bus.fetch_word(address))
  bus.fifo_fetch(address, bus.fetch_word(address))
  if (bus.sync_bits and (SB_SWAP or 2'u8)) != 0:
    if (bus.sync_bits and SB_SWAP) != 0 and address < 0x04000000'u32:
      return bus.swap_fetch_word(address)
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

proc note_store(bus: Bus; address: uint32; width: int; value: uint32) {.noinline.} =
  ## dyn_loop's store tracking: count a CPU store unless it leaves memory as
  ## it was -- a work-RAM store of the value already there, nowhere near the
  ## code being fetched and outside the MP2K HLE's watched window (a push of
  ## the same registers to the same stack slots, every iteration).
  if int64(bus.sched.cycles) + int64(bus.cycles) > bus.dyn_deadline:
    # The armed loop has not come back: it was left. Stop paying for this.
    bus.track_changes = false
    bus.gba.cpu.dyn_key = 0
    return
  let page = address shr 24
  let pc = bus.gba.cpu.r[15]
  if (page == 2 or page == 3) and (address - bus.snd_wbase) >= bus.snd_wlen and
     not (address + 8 >= pc and address <= pc + 8):
    let same = case width
      of 1: uint32(bus.read_byte_internal(address)) == value
      of 2: uint32(bus.read_half_internal(address)) == (value and 0xFFFF'u32)
      else: bus.read_word_internal(address) == value
    if same: return
  inc bus.dyn_changes

proc `[]=`*(bus: Bus; address: uint32; value: uint8) =
  when defined(cpu_testbus):
    gba_testbus_write(1, address, uint32(value))
    return
  bdWatch(address, 1, uint32(value))
  if bus.track_changes: bus.note_store(address, 1, uint32(value))
  bus.rom_cool()
  let cost = bus.access_cycles(address, is32 = false, fetch = false)
  bus.cycles += cost
  if bus_page(address) == 0x4:
    if not bus.dma_active:
      bus.store_sync(address, cost):
        bus.byte_io_write = true
        bus.write_byte_internal(address, value)
        bus.byte_io_write = false
  elif bus.sync_bits != 0:
    if not bus.dma_active:
      bus.store_sync(address, cost):
        bus.byte_io_write = true
        bus.write_byte_mapped(address, value)
        bus.byte_io_write = false
    if address < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
      bus.swap_write_byte(address, value)
      return
  bus.byte_io_write = true
  bus.write_byte_internal(address, value)
  bus.byte_io_write = false

proc write_half*(bus: Bus; address: uint32; value: uint16) =
  when defined(cpu_testbus):
    gba_testbus_write(2, address, uint32(value))
    return
  bdWatch(address, 2, uint32(value))
  if bus.track_changes: bus.note_store(address, 2, uint32(value))
  bus.rom_cool()
  let cost = bus.access_cycles(address, is32 = false, fetch = false)
  bus.cycles += cost
  if bus_page(address) == 0x4:
    if not bus.dma_active:
      bus.store_sync(address, cost):
        bus.write_half_internal(address, value)
  elif bus.sync_bits != 0:
    if not bus.dma_active:
      bus.store_sync(address, cost):
        bus.write_half_mapped(address, value)
    if address < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
      bus.swap_write_half(address, value)
      return
  bus.write_half_internal(address, value)

proc write_word*(bus: Bus; address: uint32; value: uint32) =
  when defined(cpu_testbus):
    gba_testbus_write(4, address, value)
    return
  bdWatch(address, 4, value)
  if bus.track_changes: bus.note_store(address, 4, value)
  bus.rom_cool()
  let cost = bus.access_cycles(address, is32 = true, fetch = false)
  bus.cycles += cost
  if bus_page(address) == 0x4:
    if not bus.dma_active:
      bus.store_sync(address, cost):
        bus.write_word_internal(address, value)
  elif bus.sync_bits != 0:
    if not bus.dma_active:
      bus.store_sync(address, cost):
        bus.write_word_mapped(address, value)
    if address < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
      bus.swap_write_word(address, value)
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

proc code_home(bus: Bus; pc: uint32): uint32 =
  ## The page the memory code at `pc` is fetched from lives at unswapped and
  ## switched on: what the open bus's composition turns on. png183 memory
  ## t114: Thumb code at 02FFFFF8 with board WRAM off runs from the chip
  ## WRAM and leaves the chip WRAM's composition on the bus.
  result = bits_range(pc, 24, 27)
  if pc < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
    result = result xor 2
  if result == 0x2 and bus.ewram_off: result = 0x3

proc code_half(bus: Bus; a: uint32): uint32 =
  ## The halfword a fetch at `a` reads (the BIOS unprotected).
  if a < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
    let p = bits_range(a, 24, 27)
    if p == 0x2: uint32(read_u16_ptr(bus.bios, a and 0x3FFE'u32))
    elif p < 0x2: uint32(bus.read_half_internal(a xor 0x02000000'u32))
    else: 0'u32
  else: uint32(bus.read_half_internal(a))

proc code_word(bus: Bus; a: uint32): uint32 =
  if a < 0x04000000'u32 and (bus.sync_bits and SB_SWAP) != 0:
    let p = bits_range(a, 24, 27)
    if p == 0x2: read_u32_ptr(bus.bios, a and 0x3FFC'u32)
    elif p < 0x2: bus.read_word_internal(a xor 0x02000000'u32)
    else: 0'u32
  else: bus.read_word_internal(a)

proc read_open_bus_word*(bus: Bus; address: uint32): uint32 =
  ## The whole 32-bit latch, decided ONCE per access: the verdict runs
  ## catch-up, which can run a DMA, so per-byte verdicts tear (AGB SP,
  ## payloads/slotdma.s hop 2: FFFFFFFF, not 000000FF).
  log("Reading open bus at " & hex_str(address))
  when defined(obuslatch):
    # Each half shows the DMA's word if the burst was requested after that
    # half was last fetch-driven and no later than this read began.
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
  # GBATEK "Reading from Unused Memory": "returns the recently pre-fetched
  # opcode", which "might also change if a DMA transfer occurs". The DMA's
  # own unmapped reads see its latch. Otherwise the DMA's last word is seen
  # only by the CPU's first access after the burst; any later access, opcode
  # fetch included, replaces it (AGB SP, gbaedge DMAOPENBUS,
  # docs/hwprobe-results-agb.md session 5). So the word is seen when the
  # request came after this instruction's fetch began and no later than this
  # read began; due bursts run first so such a request is known.
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
  # KNOWN WRONG SHAPE: the latch is per halfword (AGB SP, payloads/obuswint.s,
  # Thumb, two NOPs after a burst: DEAD6019, half DMA word, half opcode), so
  # no all-or-nothing bound is right. fetch_start + 1 (obuswin.s, ARM in
  # IWRAM) fails mGBA suite `DMA Prefetch Read` and zeroes `DMA Prefetch
  # Break`. Left until the latch is modelled (docs/playtest-bugs.md §13).
  when defined(obusdbg):
    # -d:obusdbg (off by default): this window's cycle stamps per unmapped
    # word read, to compare with obuswin.s / obuswint.s.
    if bus.dma_has_run and (address and 3) == 0:
      echo "obus ", hex_str(address), " req=", bus.dma_request_at,
           " fetch=", fetch_start, " read=", read_start,
           " -> ", (if bus.dma_request_at > fetch_start and
                       bus.dma_request_at <= read_start: "DMA" else: "opcode")
  if bus.dma_has_run and bus.dma_request_at > fetch_start and
     bus.dma_request_at <= read_start:
    return bus.dma_open_bus
  when OBUS_BOUNDARY_HALF:
    # A burst requested exactly as this instruction began won the bus from
    # its opcode fetch (IMM_BOUNDARY_GRANT). Where a Thumb fetch drives only
    # its own half (IWRAM, BIOS) the other half keeps the DMA's word: the
    # obuswint.s DEAD6019 case above.
    if bus.dma_has_run and bus.dma_request_at == fetch_start and
       bus.gba.cpu.cpsr.thumb:
      let pc = bus.gba.cpu.r[15]
      let pc_region = bus.code_home(pc)
      if (pc_region == 0x0 or pc_region == 0x3) and bits_range(pc, 28, 31) == 0 and
         pc >= 2:
        let newer = bus.code_half(pc and not 1'u32)
        return if (pc and 2) != 0: (newer shl 16) or (bus.dma_open_bus and 0xFFFF'u32)
               else: (bus.dma_open_bus and 0xFFFF0000'u32) or newer
  bus.fetch_bus_word(bus.gba.cpu.r[15])

proc fetch_bus_word(bus: Bus; pc: uint32): uint32 =
  ## What the CPU's opcode fetches left on the data bus, `pc` being r15 as
  ## the instruction that made the last of them sees it.
  # PC in MMIO/unmapped memory would recurse back into this proc
  let pc_region = bus.code_home(pc)
  if pc_region == 0x1 or pc_region == 0x4 or pc_region > 0xD or
     bits_range(pc, 28, 31) > 0:  # PC itself in unmapped space would recurse
    return 0'u32
  let word: uint32 =
    if bus.gba.cpu.cpsr.thumb:
      # Thumb open bus depends on how much of the latch one fetch fills
      # (AGB SP, payloads/obusprobe.s and obusbus.s, the same block run from
      # each memory, display on or forced blank; docs/hwprobe-questions.md):
      #   IWRAM  the two newest fetches ($+2, $+4) each in the half its own
      #          address bit 1 selects (3E0260A8 at 0x030000F0, 61283E02 at
      #          0x030000FA), not in fetch order
      #   EWRAM, VRAM, gamepak (16-bit)  [$+4] in both halves; the mGBA
      #          suite's I/O and Timing tests from ROM code fail otherwise
      #   OAM    the aligned word holding $+4, as ARM code (not as IWRAM)
      # BIOS cannot run a payload: unmeasured, treated as IWRAM (same bus).
      if pc_region == 0x7:
        bus.read_word_internal(pc and not 3'u32)
      elif pc_region == 0x0 or pc_region == 0x3:
        # pc < 2 (a wild jump that wrapped): $+2 is at 0xFFFFFFFE, unmapped,
        # and its read would come back here with the same PC; the one
        # fetched halfword stands in for both
        let older = if pc < 2: bus.code_half(pc and not 1'u32)
                    else: bus.code_half((pc - 2) and not 1'u32)
        let newer = bus.code_half(pc and not 1'u32)
        if (pc and 2) != 0: (newer shl 16) or older
        else:               (older shl 16) or newer
      else:
        let opcode = bus.code_half(pc and not 1'u32)
        (opcode shl 16) or opcode
    else:
      bus.code_word(pc and not 3'u32)
  word

proc dma_bus_word(bus: Bus): uint32 =
  ## The data bus as a burst's first transfer finds it (DMA_READS_CPU_BUS):
  ## the CPU's data load if nothing was fetched since, else its fetched
  ## opcode. AGB SP, payloads/dmaobus.s, Thumb in IWRAM, burst right after
  ## the load: EWRAM ldrh / misaligned ldrsh FF24FF24, ldrb FFFFFFFF, ldr
  ## 11223344; no load 46C046C0. A 16-bit memory mirrors halfword/byte; OAM
  ## drives the aligned word (alyosha Bus/DMA_OAM_Bus); unused memory drives
  ## nothing (Bus/Unused_location_update_bus). Only side-effect-free memories
  ## are read back here.
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
    of 0x4:
      when DMA_READS_IO_LOAD:
        # The 32-bit I/O bus: a load of any width drives the whole word (AGB
        # SP, payloads/hdmaphase.s: ldrh/ldrb of VCOUNT leaves DISPSTAT 2E26
        # on the low half). Loaded lanes are the value read; the others are
        # read now, the burst's own word for any that read the bus back.
        if bits_range(a, 28, 31) == 0:
          # A burst granted as the load's access ends runs before the core
          # performs the read: the load's lanes as they read now.
          let lanes = if not bus.load_io_ok: 0'u32
                      else:
                        case bus.load_size
                        of 4: 0xFFFFFFFF'u32
                        of 2:
                          if (a and 1) != 0: 0xFF'u32 shl ((a and 3) * 8)  # ldrsh_odd's byte
                          else: 0xFFFF'u32 shl ((a and 2) * 8)
                        else: 0xFF'u32 shl ((a and 3) * 8)
          var w = bus.load_io and lanes
          bus.dma_bus_fresh = false
          for k in 0'u32 .. 3'u32:
            if (lanes and (0xFF'u32 shl (8 * k))) == 0:
              w = w or (uint32(bus.read_byte_internal((a and not 3'u32) + k)) shl (8 * k))
          bus.dma_bus_fresh = true
          return w
    of 0x3:
      if bits_range(a, 28, 31) == 0:
        let w = bus.read_word_internal(a and not 3'u32)
        if bus.load_size == 4: return w
        # IWRAM's 32-bit bus keeps what it last carried: a narrower load
        # drives only its lanes (alyosha Bus/DMA_IWRAM_Bus). The rest: the
        # fetched opcodes if code is in IWRAM, else the last DMA word through
        # IWRAM (CPU accesses are not tracked).
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
    let step = if bus.gba.cpu.cpsr.thumb: 2'u32 else: 4'u32
    pc -= step
    when DMA_SEES_REFILL_FETCH:
      # ... and when that instruction ended in a refill whose second fetch
      # had not begun at the request, the first is the newest on the bus
      if bus.gba.cpu.refill_pending and bus.dma_bus_tail > 0:
        let page = bits_range(bus.gba.cpu.r[15], 24, 27)
        let second = if bus.gba.cpu.cpsr.thumb: int(bus.wait16_s[page])
                     else: int(bus.wait32_s[page])
        if bus.dma_bus_tail >= second: pc -= step
  bus.fetch_bus_word(pc)

proc read_open_bus_value*(bus: Bus; address: uint32): uint8 =
  uint8(bus.read_open_bus_word(address) shr ((address and 3) * 8))
