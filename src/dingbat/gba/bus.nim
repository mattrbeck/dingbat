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
  # Prefetch hand-off lookup (see rom_access_cycles): bit e set iff a halfword
  # started e cycles ago is in its last cycle and the buffer is not yet full.
  for page in 0x8 .. 0xD:
    let s = int(bus.wait16_s[page])
    var m = 0'u64
    for e in 0 ..< min(64, 8 * s):
      if e mod s == s - 1: m = m or (1'u64 shl e)
    bus.pf_commit[page] = m

when defined(fetchprof):
  # EXPLORATORY (branch-only): where the ROM access path actually goes on a
  # real workload. Indices:
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
  # End an unbroken fetch stream: while hot, no cycles can have been added
  # by anything except the stream itself, so "now" is exactly when the ROM
  # bus went idle.
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
    # DMA: src and dst streams each keep their own burst; no back-to-back
    # requirement. LRU pair of trackers handles the interleaving. (Hot-bus
    # accesses are also sequential-timed — the `contiguous` branch below.)
    if address == bus.rom_next_addr:
      seq = true
    elif address == bus.rom_next_addr2:
      seq = true
      bus.rom_next_addr2 = bus.rom_next_addr
      bus.rom_next_addr = address  # promoted; advanced below
    elif contiguous and bus.rom_next_addr != 1:
      # ROM bus still hot from the previous DMA access (e.g. a ROM-to-ROM
      # transfer's write right after its read) → sequential. But NOT on the
      # DMA's very first ROM access: rom_next_addr == 1 is the cold sentinel
      # seeded at DMA start, and a DMA is a fresh bus master whose first
      # access to each stream is always non-sequential regardless of how hot
      # the CPU left the bus.
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
      # Prefetch hit: the buffer worked ahead while the ROM bus was free,
      # one halfword per S-access time (buffer holds up to 8 halfwords).
      # Leftover credit carries over to the next fetch, so back-to-back
      # buffer hits stay cheap until the buffer drains.
      # rom_free_since can sit ahead of `now`: the waitloop fast-forward
      # discards a partial instruction's cycles after bookkeeping already
      # anticipated them. Unsigned subtraction would wrap (and crashed
      # Pokémon FireRed with a RangeDefect); treat it as zero credit.
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
    # Prefetch hand-off. A CPU *data* access to the gamepak takes the ROM bus
    # away from the prefetcher, which has been streaming halfwords since
    # rom_free_since (so it is `elapsed mod s` cycles into the halfword it is
    # currently fetching). A halfword still in its address/wait phase is
    # abandoned for free, but one already in its final cycle has its data
    # committed on the bus and cannot be recalled — the CPU waits that one
    # cycle out. Once the buffer is full (8 halfwords, 8*s cycles) nothing is
    # in flight at all. Only fires while the CPU executes from the gamepak:
    # the prefetcher does not run otherwise. This is the whole of the
    # mGBA-suite Timing "ROM" prefetch-column shortfall for LDR/LDM (see the
    # commit message for the per-row derivation); DMA hand-off is a separate,
    # still-open case.
    # `elapsed` is 0 when the waitloop fast-forward has pushed rom_free_since
    # past `now` (same unsigned-wrap guard as the prefetch-hit branch above).
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
  bus.rom_next_addr = address + (if is32: 4'u32 else: 2'u32)
  bus.rom_free_since = new_free_since
  cost

proc rom_fetch_cycles(bus: Bus; address: uint32; page: int;
                      is32: static bool): int {.inline.} =
  ## Fetch-only specialisation of `rom_access_cycles`, for the CPU instruction
  ## fetch path in `fetch_half`/`fetch_word`.
  ##
  ## Why it exists: `rom_access_cycles` is marked {.inline.} but is far too
  ## large for clang to honour that, so every slow-path instruction fetch pays
  ## a real call — and it is the single hottest non-inlined leaf in the
  ## profile (7.9% of all samples on FireRed, 569 of its 600 samples reached
  ## from `fetch_half`). Two of the three branch clusters in it are dead on a
  ## fetch: the DMA burst trackers (a DMA is not the CPU, and the caller
  ## routes `dma_active` back to the general proc) and the prefetch hand-off,
  ## which is `not fetch` by construction. What is left is small enough to
  ## inline, and `is32` being static folds the remaining selects away.
  ##
  ## This is a *duplicate* of the fetch-relevant half of `rom_access_cycles`,
  ## not a refactor of it, so the two must be kept in step by hand. The
  ## framebuffer-hash A/B and the mGBA Timing suite are what catch a drift.
  let now = bus.bus_now()
  let contiguous = now == bus.rom_free_since
  var cost: int
  var new_free_since: CycleCount
  if address == bus.rom_next_addr and (bus.prefetch_on or contiguous):
    if bus.prefetch_on and not contiguous:
      let s = int(bus.wait16_s[page])
      let credit = if now > bus.rom_free_since:
                     min(int(now - bus.rom_free_since), 8 * s)
                   else: 0
      let need = when is32: 2 * s else: s
      cost = max(1, need - credit)
      let done = now + CycleCount(cost)
      let floor = if done > CycleCount(8 * s): done - CycleCount(8 * s) else: 0
      new_free_since = max(bus.rom_free_since + CycleCount(need), floor)
    else:
      cost = int(when is32: bus.wait32_s[page] else: bus.wait16_s[page])
      new_free_since = now + CycleCount(cost)
  else:
    cost = int(when is32: bus.wait32_n[page] else: bus.wait16_n[page])
    new_free_since = now + CycleCount(cost)
  bus.rom_next_addr = address + (when is32: 4'u32 else: 2'u32)
  bus.rom_free_since = new_free_since
  cost

proc access_cycles(bus: Bus; address: uint32; is32: bool; fetch: bool): int {.inline.} =
  if bits_range(address, 28, 31) > 0:
    # Unmapped (open bus): nothing on the external bus responds, so the
    # access completes in one internal cycle and must not disturb the ROM
    # burst trackers.
    return 1
  let page = int(bits_range(address, 24, 27))
  if page >= 0x8:
    if page <= 0xD:
      bus.rom_access_cycles(address, is32, fetch)
    else:
      int(bus.wait16_n[page])  # SRAM: 8-bit bus, same cost either way
  else:
    ACCESS_TIMING_TABLE[int(is32)][page]

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
  # Cache the ROM base + length (the cartridge is loaded before the bus). The
  # buffer never moves and is a fixed size, so a raw pointer stays valid.
  result.rom_ptr = cast[ptr UncheckedArray[byte]](addr gba.cartridge.rom[0])
  result.rom_len = uint32(gba.cartridge.rom.len)
  if bios_path != "" and fileExists(bios_path):
    let f = open(bios_path, fmRead)
    discard f.readBytes(result.bios, 0, result.bios.len)
    f.close()
  else:
    result.stub_bios = true
    # Minimal BIOS stub: IRQ vector at 0x18 branches to the handler at 0x128
    # (matching the real BIOS layout, so IRQ dispatch costs the same 3-cycle
    # branch) which dispatches to the user handler at [0x03FFFFFC].
    #   0x004: b 0x1C                         EA000004  (UND vector)
    #   0x01C: subs pc, lr, #4                E25EF004
    #   0x018: b 0x128                        EA000042
    #   0x128: stmfd sp!, {r0-r3, r12, lr}   E92D500F
    #   0x12C: mov   r0, #0x04000000          E3A00301
    #   0x130: add   lr, pc, #0               E28FE000
    #   0x134: ldr   pc, [r0, #-4]            E510F004
    #   0x138: ldmfd sp!, {r0-r3, r12, lr}    E8BD500F
    #   0x13C: subs  pc, lr, #4               E25EF004
    # UND vector (same word as the real BIOS at 0x04): the real handler's
    # non-debug path restores SPSR and returns with subs pc, lr, #4 — the
    # register save/restore nets out, so the stub keeps only the return
    # (mGBA's HLE BIOS undefBase does the same)
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
    # Reset vector: games jump to 0x00000000 to trigger a warm re-boot
    # (Earthworm Jim 2's IRQ dispatcher calls a NULL handler slot; on
    # hardware the BIOS boot re-runs the logo sequence and re-enters the
    # ROM). The swi traps into the HLE (recognized by pc == 8), which
    # applies the boot's I/O effects and parks execution in the wait loop
    # below; a second trap at the end re-enters the ROM (see hle_swi 0x00).
    write_stub_u32(result.bios, 0x000, 0xEF000000'u32)  # swi 0 (boot trap)
    # Boot wait loop (r0 = 0x04000000, r2 = vblank count, set by the trap):
    # count r2 vcount==160 edges, then run to scanline 126, where the real
    # boot hands control to the ROM. Executing stub code keeps the ~271-frame
    # wait inside the normal per-frame loop and makes the state
    # save/rollback-transparent (the whole continuation is PC + r0-r2).
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
    # SoundGetJumpList (SWI 0x2A) support: the table of 36 sound-driver
    # function addresses the real BIOS copies to [r0] (BIOS 0x3738), with
    # the same values as the real BIOS so games that stash or compare the
    # pointers see the real thing. The stub carries executable code at those
    # addresses: entry 35 (0x23B0, "channel clear": zeroes 16 words at r0,
    # preserving r4 via ip like the real routine) is implemented because
    # Cyberdrive Zoids calls it during sound-driver init; the remaining
    # entries return immediately (bx lr) — the driver work they would do is
    # the BIOS-resident MP2K engine, which the HLE does not model.
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
    # SoundDriverMain dispatch (SWI 0x1C jumps here; thumb, at the real
    # routine's address 0x1DC4): the lock/callback portion of the BIOS
    # SoundMain — check the SoundInfo ident magic at [0x03007FF0], lock
    # (ident+1), call the game-registered hooks [info+32]([info+36]) and
    # [info+40](info) (the ROM-resident music player: Cyberdrive Zoids'
    # main loop blocks until these have run), unlock and return. The BIOS
    # PCM mixer that follows in the real routine is not modeled.
    # The stub runs in SVC mode with the SVC stack and banked lr, like the
    # real routine under the real dispatcher (hle_swi 0x1C stages the mode
    # switch); the closing `swi 0` traps are the dispatcher's `movs pc, lr`
    # exit, which the HLE performs (restore SPSR_svc, return to lr_svc).
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
  # Tilt carts can't be probed at runtime (the game just reads the registers
  # and believes whatever comes back), so detection is by game code:
  # KYG* = Yoshi's Universal Gravitation / Topsy-Turvy, KHPJ = Koro Koro
  # Puzzle. Note these carts really save to EEPROM; save-type pinning is a
  # separate change — the tilt window below is intercepted before storage
  # regardless of what the save heuristic decided.
  result.tilt_present = gba.cartridge != nil and
    gba.cartridge.game_code() in ["KYGE", "KYGJ", "KYGP", "KHPJ"]
  result.update_waitcnt(WAITCNT())  # reset-state waitstates

proc bus_page(address: uint32): int {.inline.} =
  int(bits_range(address, 24, 27))

# ---- Tilt sensor (0x0E008000-0x0E008500, GBATEK "GBA Cart Tilt Sensor") ----
# Two-step sampling handshake mirroring MBC7's: write 0x55 to 0x8000 to arm,
# 0xAA to 0x8100 to latch a 12-bit sample per axis. Reads deliver the sample
# split low byte / high nibble; X's high read carries an ADC-ready flag in
# bit 7 (always ready here, like mGBA). Everything else in the window reads
# 0xFF. Centers/range per GBATEK's example calibration.

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

# ---- ROM reads (bounds-checked; past the ROM returns the open-bus pattern) ----
# The ROM buffer is sized to the next power of two >= the cart, not a flat 32 MB.
# In-bounds reads (all instruction fetches and virtually all data reads) take the
# fast path; the branch predicts perfectly, so this is free in practice.

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
    # 10000000-FFFFFFFF is not decoded by the cartridge/bus at all: reads
    # return open bus, never a mirror of the low regions. Minish Cap relies
    # on this (it walks an animation script through a NULL sprite entry into
    # the BIOS open-bus latch 0xE55EC002 and only escapes the walk because
    # the bytes it reads there are the non-zero prefetched opcode).
    return bus.read_open_bus_value(address)
  case bits_range(address, 24, 27)
  of 0x0:
    if bits_range(bus.gba.cpu.r[15], 24, 27) == 0:
      bus.bios[address and 0x3FFF'u32]
    elif (address and 0x00FFFFFF'u32) >= 0x4000'u32 and not bus.dma_active:
      # Page-0 out-of-bounds (00004000-00FFFFFF) is unused memory, not BIOS:
      # a CPU read returns the open-bus value (the prefetched opcode), not the
      # protected-BIOS latch (GBATEK "Reading from Unused Memory").
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
  # Debug watch (trade-repro harness, -d:linkTrace): fires on any IWRAM write
  # covering `wramWatchOff`. Compiled out entirely in normal builds.
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
  # the hardware pipeline has already fetched must not affect execution, so
  # snapshot the pre-write values. Stand down while a refill is pending (right
  # after a PC write): nothing has been fetched at the new PC yet, and the
  # refill must observe the write (Golden Sun TLA's DMA-built stack trampoline)
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
      # KEYCNT: keep the 16-bit store atomic so the keypad IRQ check never
      # observes a half-written transient (see write_keycnt16).
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
    # The backup chip is on an 8-bit bus, so a halfword store moves exactly one
    # byte. STRH drives the halfword onto BOTH halves of the 32-bit data bus,
    # and the chip latches only the lane its A0 line selects, so the byte that
    # lands at `orig` is value >> (8 * (orig and 1)): an ODD address stores the
    # high byte, not the low one. (GBATEK "GBA Cart Backup SRAM/FLASH" — 8-bit
    # bus; jsmolka save/{sram,flash64,flash128} test 6 asserts both halves.)
    # Note this is the byte the *device* sees, so it applies to the tilt sensor
    # sharing the bus as well; every real tilt access is at an even address, so
    # that arm is unchanged in practice.
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
      # atomically (see write_keycnt16).
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
    # Same 8-bit-bus lane select as write_half_internal, but STR drives the
    # word unrotated across all four lanes, so A[1:0] picks the byte:
    # value >> (8 * (orig and 3)). jsmolka save/* test 8 walks all four.
    let b = uint8(value shr (8'u32 * (orig and 3'u32)))
    if bus.tilt_hit(orig): bus.tilt_write(orig, b)
    else: bus.gba.storage[orig] = b
  else: log("Unmapped write word: " & hex_str(address))

# ---- Instruction-fetch fast path ----

proc install_fetch_cache(bus: Bus; page: uint32): bool =
  # Only pages whose fetches are plain masked memory reads are cacheable.
  # BIOS (latch + PC checks), MMIO, open bus, and 0xD (possible EEPROM
  # mapping) always take the generic path.
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
  bus.fetch_c16 = ACCESS_TIMING_TABLE[0][int(page)]
  bus.fetch_c32 = ACCESS_TIMING_TABLE[1][int(page)]
  true

proc fetch_half*(bus: Bus; address: uint32): uint16 {.inline.} =
  let page = bits_range(address, 24, 27)
  if page == bus.fetch_page or bus.install_fetch_cache(page):
    if page >= 0x8:
      # Straight-line execution fast path: while the fetch stream is hot
      # (unbroken), a sequential fetch is a plain S access and needs no
      # absolute-time bookkeeping at all
      if bus.rom_hot and address == bus.rom_next_addr:
        when defined(fetchprof): fetchprof[0].inc
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
      if bus.rom_hot and address == bus.rom_next_addr:
        when defined(fetchprof): fetchprof[2].inc
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
  # accesses observe/affect timers, IF flags, etc. at the exact cycle they
  # happen. Skipped while an event handler runs (handlers must stay pure so
  # the DMA pump, which runs after dispatch, arbitrates all deferred work).
  # The accessors below additionally skip it while a DMA burst runs
  # (dma_active): a transfer must not be preempted between its read and
  # write — the DMA loop drains due events at transfer boundaries instead
  # (timer reads stay exact regardless: get_current_tm includes bus.cycles).
  # The common no-event-due case stays inline; event dispatch takes the
  # slow path.
  let s = bus.sched
  if s.dispatching: return
  let target = s.cycles + CycleCount(bus.cycles)
  if target < s.next_event:
    s.cycles = target
    bus.synced += bus.cycles
    bus.cycles = 0
  else:
    bus.catch_up_slow()

# The dma_pending leg of the catch-up condition (identical in all six
# accessors below): arming an immediate DMA schedules etDMA a few cycles out
# (DMA_START_DELAY, dma.nim) and the CPU keeps executing until it fires. An
# accessor's data effect happens the moment it runs, but its cycles normally
# reach the scheduler only at instruction end — so an access positioned after
# the burst's start cycle would land BEFORE the burst (which runs inside this
# catch_up: the etDMA dispatch latches requests, the post-dispatch pump runs
# them), inverting the CPU-vs-DMA memory order that hardware's bus takeover
# enforces. Forcing catch-up on every access during the armed window keeps
# the interleaving cycle-exact; MMIO (page 0x4) already catches up
# unconditionally for timer/IF exactness.
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
  bus.write_byte_internal(address, value)

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
  # A DMA is the last bus master to have driven the data bus: reads of
  # unmapped space made by the DMA itself, or by the first CPU instruction
  # after the burst hands the bus back, return the last word the DMA moved
  # (the CPU prefetcher hasn't overwritten the latch yet). Matches mGBA's
  # gba->bus / dmaPC model and hardware (GBATEK "Reading from Unused Memory":
  # "after DMA: recently transferred data").
  if bus.dma_active or bus.dma_open_bus_armed:
    return uint8(bus.dma_open_bus shr shift)
  let pc = bus.gba.cpu.r[15]
  # Guard: if PC is in MMIO, unmapped memory, or otherwise unreadable, avoid
  # infinite recursion (region 0x1 reads recurse back into this proc)
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
