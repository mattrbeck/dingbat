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

when defined(fetchprof):
  # -d:fetchprof: where the ROM access path goes on a real workload. Indices:
  #   0 fetch_half hot   1 fetch_half slow   2 fetch_word hot   3 fetch_word slow
  #   4 rac fetch calls  5 rac data calls
  #   6 rac prefetch-hit 7 rac plain-seq     8 rac nonseq
  #   9 rac went hot after
  #  10 rac prefetch-hit with credit >= need (cost floor 1)
  #  11 rac prefetch-hit with zero credit
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

proc rom_access_cycles(bus: Bus; address: uint32; is32: bool; fetch: bool): int {.inline.} =
  ## Cycle cost of a ROM-region (pages 8-D) access, tracking burst
  ## sequentiality and the prefetch buffer. Sequential = the address
  ## continues the previous ROM access; with the prefetch buffer off the
  ## burst additionally breaks whenever the CPU spent cycles off the ROM bus.
  let page = int(bits_range(address, 24, 27))
  let now = bus.bus_now()
  let contiguous = now == bus.rom_free_since
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
    seq = address == bus.rom_next_addr and (bus.prefetch_on or contiguous)
  when defined(fetchprof):
    fetchprof[if fetch: 4 else: 5].inc
  var cost: int
  var new_free_since: CycleCount
  if seq:
    if fetch and bus.prefetch_on and not contiguous:
      # Prefetch hit: the buffer worked ahead while the ROM bus was free, one
      # halfword per S-access time (up to 8); leftover credit carries to the
      # next fetch. rom_free_since can sit ahead of `now` (the waitloop
      # fast-forward discards a partial instruction's cycles): zero credit,
      # never an unsigned wrap.
      let s = int(bus.wait16_s[page])
      let credit = if now > bus.rom_free_since:
                     min(int(now - bus.rom_free_since), 8 * s)
                   else: 0
      let need = if is32: 2 * s else: s
      cost = max(1, need - credit)  # a full buffer serves even a 32-bit fetch in one cycle
      let done = now + CycleCount(cost)
      let floor = if done > CycleCount(8 * s): done - CycleCount(8 * s) else: 0
      new_free_since = max(bus.rom_free_since + CycleCount(need), floor)
      when defined(fetchprof):
        fetchprof[6].inc
        if credit >= need: fetchprof[10].inc
        if credit == 0: fetchprof[11].inc
    else:
      cost = int(if is32: bus.wait32_s[page] else: bus.wait16_s[page])
      new_free_since = now + CycleCount(cost)
      when defined(fetchprof): fetchprof[7].inc
  else:
    cost = int(if is32: bus.wait32_n[page] else: bus.wait16_n[page])
    new_free_since = now + CycleCount(cost)
    when defined(fetchprof): fetchprof[8].inc
  if not fetch and not contiguous and bus.prefetch_on and not bus.dma_active and
     bus.fetch_page - 0x8 <= 5:
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
    if bus.prefetch_on and bus.fetch_page - 0x8 <= 5:
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

proc rom_fetch_cycles(bus: Bus; address: uint32; page: int;
                      is32: static bool): int {.inline.} =
  ## Fetch-only specialisation of `rom_access_cycles` for the instruction
  ## fetch path: the general proc is too large for clang to inline, and the
  ## DMA trackers and prefetch hand-off are dead on a fetch. A duplicate of
  ## the fetch-relevant half, kept in step by hand; the framebuffer-hash A/B
  ## and the mGBA Timing suite catch drift.
  let now = bus.bus_now()
  let contiguous = now == bus.rom_free_since
  var cost: int
  var new_free_since: CycleCount
  if address == bus.rom_next_addr and (bus.prefetch_on or contiguous):
    if bus.prefetch_on and not contiguous:
      # Same arithmetic as rom_access_cycles' prefetch-hit branch, with the
      # `floor` term hoisted into the one case that can reach it: for gap <=
      # cap, max(rom_free_since + need, done - cap) is always the first term
      # (gap < need: done == rom_free_since + need; gap >= need: cost = 1 and
      # gap+1-cap <= 1 <= need). Only a gap longer than a full buffer can
      # raise the floor.
      let s = int(bus.wait16_s[page])
      let cap = 8 * s
      let need = when is32: 2 * s else: s
      if now <= bus.rom_free_since:
        # Waitloop fast-forward pushed rom_free_since past `now`: no credit
        cost = need
        new_free_since = bus.rom_free_since + CycleCount(need)
      else:
        let gap = int(now - bus.rom_free_since)
        if gap <= cap:
          cost = max(1, need - gap)
          new_free_since = bus.rom_free_since + CycleCount(need)
        else:
          cost = max(1, need - cap)
          let done = now + CycleCount(cost)
          let floor = if done > CycleCount(cap): done - CycleCount(cap) else: 0
          new_free_since = max(bus.rom_free_since + CycleCount(need), floor)
    else:
      cost = int(when is32: bus.wait32_s[page] else: bus.wait16_s[page])
      new_free_since = now + CycleCount(cost)
  else:
    cost = int(when is32: bus.wait32_n[page] else: bus.wait16_n[page])
    new_free_since = now + CycleCount(cost)
  when defined(pftrace):
    pft("  RFC fetch" & (when is32: "32" else: "16") &
        " a=" & toHex(address, 8) & " now=" & $now & " rfs_in=" & $bus.rom_free_since &
        " cost=" & $cost & " rfs_out=" & $new_free_since)
  bus.rom_next_addr = address + (when is32: 4'u32 else: 2'u32)
  bus.rom_free_since = new_free_since
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
  result.fetch_page = 0xFFFFFFFF'u32  # no fetch page cached yet
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
    # clear) is implemented because Cyberdrive Zoids calls it; the rest
    # return immediately (the BIOS-resident MP2K engine is not modeled).
    const JUMP_LIST = [0x2665'u32, 0x26CF, 0x26EF, 0x2709, 0x271D, 0x2665,
                       0x2665, 0x2665, 0x2665, 0x274B, 0x2755, 0x2769,
                       0x277B, 0x27A9, 0x27BB, 0x27CF, 0x27E3, 0x27F5,
                       0x2805, 0x280F, 0x281F, 0x2665, 0x2665, 0x2837,
                       0x2665, 0x2665, 0x2665, 0x284B, 0x2665, 0x2629,
                       0x170B, 0x23E7, 0x1535, 0x159D, 0x23C7, 0x23B1]
    for i, v in JUMP_LIST:
      write_stub_u32(result.bios, 0x3738 + i * 4, v)
      # bx lr at each entry (halfword-aligned thumb targets)
      let t = int(v and not 1'u32)
      result.bios[t]     = 0x70'u8
      result.bios[t + 1] = 0x47'u8
    # Entry 35, the real routine at 0x23B0 (verbatim):
    #   mov ip, r4; movs r1-r4, #0; 4x stmia r0!, {r1-r4}; mov r4, ip; bx lr
    for i, h in [0x46A4'u16, 0x2100, 0x2200, 0x2300, 0x2400,
                 0xC01E, 0xC01E, 0xC01E, 0xC01E, 0x4664, 0x4770]:
      result.bios[0x23B0 + i * 2]     = uint8(h and 0xFF)
      result.bios[0x23B0 + i * 2 + 1] = uint8(h shr 8)
    # SoundDriverMain dispatch (SWI 0x1C, thumb at the real 0x1DC4): the
    # lock/callback part of the BIOS SoundMain — check the SoundInfo ident at
    # [0x03007FF0], lock, call the game hooks [info+32]([info+36]) and
    # [info+40](info) (Cyberdrive Zoids' main loop blocks until they run),
    # unlock. The PCM mixer is not modeled. Runs in SVC mode like the real
    # routine (hle_swi 0x1C stages the switch); the closing `swi 0` traps are
    # the dispatcher's `movs pc, lr` exit, performed by the HLE.
    #   ldr r2, =0x03007FF0; ldr r0, [r2]; ldr r2, =magic; ldr r3, [r0]
    #   cmp r3, r2; bne ret; adds r3, #1; str r3, [r0]      ; lock
    #   push {r4, lr}; adds r4, r0, #0
    #   ldr r3, [r4, #32]; cmp r3, #0; beq 1f
    #   ldr r0, [r4, #36]; bl call
    # 1: ldr r3, [r4, #40]; cmp r3, #0; beq 2f
    #   adds r0, r4, #0; bl call
    # 2: ldr r2, =magic; str r2, [r4]                        ; unlock
    #   pop {r4}; pop {r3}; mov lr, r3; swi 0
    # call: bx r3      ret: swi 0
    for i, h in [0x4A0F'u16, 0x6810, 0x4A0F, 0x6803, 0x4293, 0xD116,
                 0x3301, 0x6003, 0xB510, 0x1C04, 0x6A23, 0x2B00,
                 0xD002, 0x6A60, 0xF000, 0xF80C, 0x6AA3, 0x2B00,
                 0xD002, 0x1C20, 0xF000, 0xF806, 0x4A05, 0x6022,
                 0xBC10, 0xBC08, 0x469E, 0xDF00, 0x4718, 0xDF00,
                 0x0000, 0x0000]:
      result.bios[0x1DC4 + i * 2]     = uint8(h and 0xFF)
      result.bios[0x1DC4 + i * 2 + 1] = uint8(h shr 8)
    write_stub_u32(result.bios, 0x1E04, 0x03007FF0'u32)
    write_stub_u32(result.bios, 0x1E08, 0x68736D53'u32)
  result.gpio = new_gpio(gba)
  # Tilt carts cannot be probed at runtime, so detection is by game code:
  # KYG* = Yoshi's Universal Gravitation / Topsy-Turvy, KHPJ = Koro Koro
  # Puzzle. The tilt window is intercepted before storage regardless of the
  # save heuristic.
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
    return uint16(bus.read_open_bus_value(address)) or
           (uint16(bus.read_open_bus_value(address or 1)) shl 8)
  case bits_range(address, 24, 27)
  of 0x0:
    if bits_range(bus.gba.cpu.r[15], 24, 27) == 0:
      read_u16_ptr(bus.bios, address and 0x3FFF'u32)
    elif (address and 0x00FFFFFF'u32) >= 0x4000'u32 and not bus.dma_active:
      # Page-0 out-of-bounds -> open bus (see read_byte_internal)
      uint16(bus.read_open_bus_value(address)) or (uint16(bus.read_open_bus_value(address or 1)) shl 8)
    else:
      # BIOS latch (see read_byte_internal)
      let shift = (address and 2) * 8
      uint16(bus.bios_latch shr shift)
  of 0x1: uint16(bus.read_open_bus_value(address)) or (uint16(bus.read_open_bus_value(address or 1)) shl 8)
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
    let v = bus.read_open_bus_value(address)
    return uint32(v) or (uint32(bus.read_open_bus_value(address or 1)) shl 8) or
           (uint32(bus.read_open_bus_value(address or 2)) shl 16) or
           (uint32(bus.read_open_bus_value(address or 3)) shl 24)
  case bits_range(address, 24, 27)
  of 0x0:
    if bits_range(bus.gba.cpu.r[15], 24, 27) == 0:
      read_u32_ptr(bus.bios, address and 0x3FFF'u32)
    elif (address and 0x00FFFFFF'u32) >= 0x4000'u32 and not bus.dma_active:
      # Page-0 out-of-bounds -> open bus (see read_byte_internal)
      let v = bus.read_open_bus_value(address)
      uint32(v) or (uint32(bus.read_open_bus_value(address or 1)) shl 8) or
      (uint32(bus.read_open_bus_value(address or 2)) shl 16) or
      (uint32(bus.read_open_bus_value(address or 3)) shl 24)
    else:
      # BIOS latch (see read_byte_internal)
      bus.bios_latch
  of 0x1:
    let v = bus.read_open_bus_value(address)
    uint32(v) or (uint32(bus.read_open_bus_value(address or 1)) shl 8) or
    (uint32(bus.read_open_bus_value(address or 2)) shl 16) or
    (uint32(bus.read_open_bus_value(address or 3)) shl 24)
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
  of 0x2: bus.wram_board[address and 0x3FFFF'u32] = value
  of 0x3:
    bus.wram_chip[address and 0x7FFF'u32] = value
    chipWatch(bus, address and 0x7FFF'u32, uint32(value), 1)
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
  of 0x2: write_u16_ptr(bus.wram_board, address and 0x3FFFF'u32, value)
  of 0x3:
    write_u16_ptr(bus.wram_chip, address and 0x7FFF'u32, value)
    chipWatch(bus, address and 0x7FFF'u32, uint32(value), 2)
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
  of 0x2: write_u32_ptr(bus.wram_board, address and 0x3FFFF'u32, value)
  of 0x3:
    write_u32_ptr(bus.wram_chip, address and 0x7FFF'u32, value)
    chipWatch(bus, address and 0x7FFF'u32, value, 4)
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

proc install_fetch_cache(bus: Bus; page: uint32): bool =
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
  # Via the bus tables so the underclock scaling applies; only consumed on
  # the non-ROM (pages 2/3) fetch path
  bus.fetch_c16 = int(bus.wait16_n[int(page)])
  bus.fetch_c32 = int(bus.wait32_n[int(page)])
  true

proc fetch_half*(bus: Bus; address: uint32): uint16 {.inline.} =
  let page = bits_range(address, 24, 27)
  if page == bus.fetch_page or bus.install_fetch_cache(page):
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
  else:
    bus.read_half(address)

proc fetch_word*(bus: Bus; address: uint32): uint32 {.inline.} =
  let page = bits_range(address, 24, 27)
  if page == bus.fetch_page or bus.install_fetch_cache(page):
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
  else:
    bus.read_word(address)

# ---- Public read/write with cycle accounting ----

proc catch_up_slow(bus: Bus) =
  # Loops because a fired event can itself consume bus time (a DMA stalling
  # the CPU) that must also be ticked before the access observes the clock.
  while bus.cycles > 0:
    let pending = bus.cycles
    bus.cycles = 0
    bus.synced += pending
    bus.gba.scheduler.tick(pending)

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

# The dma_pending leg (identical in all six accessors): an immediate DMA
# fires DMA_START_DELAY cycles after arming while the CPU keeps executing; an
# accessor's data effect happens when it runs but its cycles reach the
# scheduler only at instruction end, so an access positioned after the
# burst's start would otherwise land before it. Forcing catch-up during the
# armed window keeps the CPU-vs-DMA memory order cycle-exact.
proc `[]`*(bus: Bus; address: uint32): uint8 =
  bus.rom_cool()
  bus.cycles += bus.access_cycles(address, is32 = false, fetch = false)
  if (bus_page(address) == 0x4 or bus.dma_pending) and not bus.dma_active: bus.catch_up()
  bus.read_byte_internal(address)

proc read_half*(bus: Bus; address: uint32): uint16 =
  bus.rom_cool()
  bus.cycles += bus.access_cycles(address, is32 = false, fetch = false)
  if (bus_page(address) == 0x4 or bus.dma_pending) and not bus.dma_active: bus.catch_up()
  bus.read_half_internal(address)

proc read_word*(bus: Bus; address: uint32): uint32 =
  bus.rom_cool()
  bus.cycles += bus.access_cycles(address, is32 = true, fetch = false)
  if (bus_page(address) == 0x4 or bus.dma_pending) and not bus.dma_active: bus.catch_up()
  bus.read_word_internal(address)

proc `[]=`*(bus: Bus; address: uint32; value: uint8) =
  bus.rom_cool()
  bus.cycles += bus.access_cycles(address, is32 = false, fetch = false)
  if (bus_page(address) == 0x4 or bus.dma_pending) and not bus.dma_active: bus.catch_up()
  bus.byte_io_write = true
  bus.write_byte_internal(address, value)
  bus.byte_io_write = false

proc write_half*(bus: Bus; address: uint32; value: uint16) =
  bus.rom_cool()
  bus.cycles += bus.access_cycles(address, is32 = false, fetch = false)
  if (bus_page(address) == 0x4 or bus.dma_pending) and not bus.dma_active: bus.catch_up()
  bus.write_half_internal(address, value)

proc write_word*(bus: Bus; address: uint32; value: uint32) =
  bus.rom_cool()
  bus.cycles += bus.access_cycles(address, is32 = true, fetch = false)
  if (bus_page(address) == 0x4 or bus.dma_pending) and not bus.dma_active: bus.catch_up()
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
    uint32(cast[int32](cast[int8](bus[address])))
  else:
    uint32(cast[int32](cast[int16](bus.read_half(address))))

proc read_word_rotate*(bus: Bus; address: uint32): uint32 =
  let word = bus.read_word(address)
  let bits = (address and 3) * 8
  (word shr bits) or (word shl (32 - bits))

proc read_open_bus_value*(bus: Bus; address: uint32): uint8 =
  log("Reading open bus at " & hex_str(address))
  let shift = (address and 3) * 8
  # A DMA is the last bus master to have driven the data bus: unmapped reads
  # by the DMA itself, or by the first CPU instruction after the burst,
  # return the last word it moved. GBATEK "GBA Unpredictable Things",
  # Reading from Unused Memory: unused memory "returns the recently
  # pre-fetched opcode", and, of that value, "Theoretically, this might also
  # change if a DMA transfer occurs" — GBATEK says no more. The mGBA suite
  # pins the existence of the latch: Misc "DMA Prefetch Read" is the one
  # row that flips (PASS -> FAIL, 4/12 -> 3/12) when this branch is removed
  # (measured on the 2026-09-01 audit build); the DMA section's R+0x10
  # rows and Misc "DMA Prefetch Break" (still red) do not depend on it.
  # The exact window — the DMA's own reads plus exactly one CPU instruction
  # after the burst — is Assumed; no ROM pins its length. Hello Kitty
  # Collection: Miracle Fashion Maker's boot needs at least this much.
  if bus.dma_active or bus.dma_open_bus_armed:
    return uint8(bus.dma_open_bus shr shift)
  let pc = bus.gba.cpu.r[15]
  # PC in MMIO/unmapped memory would recurse back into this proc
  let pc_region = bits_range(pc, 24, 27)
  if pc_region == 0x1 or pc_region == 0x4 or pc_region > 0xD or
     bits_range(pc, 28, 31) > 0:  # PC itself in unmapped space would recurse
    return 0'u8
  let word: uint32 =
    if bus.gba.cpu.cpsr.thumb:
      let opcode = uint32(bus.read_half_internal(pc and not 1'u32))
      (opcode shl 16) or opcode
    else:
      bus.read_word_internal(pc and not 3'u32)
  uint8(word shr shift)
