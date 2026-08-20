# GB Memory bus (included by gb.nim)

# ---- -d:gb_dma_trace --------------------------------------------------------
#
# Diagnostic DMA/mode trace (tools only; compiled out of every shipping build).
# Where `-d:gb_halt_trace` reports the dot a halt WAKES on, this reports the
# dots everything a woken handler then does lands on -- which is what turns a
# "this row moved" into an equation. Five line kinds, all with `ly` and the PPU
# dot, none of them filtered by GB_TRACE_LY:
#
#   DMASTART   the OAM DMA unit taking the bus (mem_dma_tick), i.e. the dot
#              every later `obj_oam_dma_read` is a function of
#   REGREAD    every CPU read of STAT or LY, with the value returned
#   MODE       every PPU mode change (ppu.nim `mode_flag=`)
#   FF55       every write to FF55, with the mode and `hdma_active` at that dot
#   HDMABLOCK  every HBlank or general-purpose block copy
#   VRAMRD     every CPU read of $8000-$9FFF, with the dot it is answered on,
#              both halves of the lock and the byte underneath it — which is
#              what the `hdma_start` family reads, and the line that measured
#              HDMA_VISIBLE_DOTS (gb.nim) by putting each ROM's read dot next to
#              its HDMABLOCK dot
#
# Written for the 2026-08-10 CGB_HALT_PPU_LEAD measurement, where the question
# was where a post-halt handler's OAM DMA and FF55 write land against the PPU's
# own edges; see docs/gb-failure-triage.md for what it produced. `REGREAD` and
# `MODE` are on hot paths and this is not a flag to leave on.

proc new_gb_memory*(gb: GB): GbMemory =
  # DMA (FF46) reads back the last written value; post-boot it's 0xFF on
  # DMG-family models, 0x00 on CGB (Pan Docs power-up sequence).
  result = GbMemory(wram_bank: 1, svbk_raw: 1, dma_position: 0xA1,
                    dma: if gb.cgb_enabled: 0x00'u8 else: 0xFF'u8)
  for i in 0 ..< 8:
    result.wram[i] = newSeq[uint8](0x1000)
  when GB_POWERUP_WRAM_PATTERN != 0:
    # Real WRAM does not power up as 8K of zeroes, and one test in the tree
    # checks exactly that: BullyGB's InitRAMTest walks $C000-$DFFF and reports
    # "Uninitialized RAM not randomized" if every byte is $00. It is the FIRST
    # of that ROM's nine tests and the ROM prints only the first failure, so an
    # all-zero fill did not merely cost that check — it hid the other eight
    # (bootreg, divtest, dmabusconflict, echoram, initvram_dmg, undoc_regs,
    # unused_io) behind it.
    #
    # A FIXED xorshift, not a seeded RNG: the point is to be non-uniform, not
    # to be unpredictable, and every determinism guarantee in this tree — the
    # byte-identical screenshot gates, save-state round-trips, the rollback
    # netplay core — needs two runs of the same ROM to start from the same
    # bytes. This is reproducible to the byte across runs, builds and hosts.
    var s: uint32 = 0x1234_5678'u32
    for b in 0 ..< 8:
      for j in 0 ..< 0x1000:
        s = s xor (s shl 13)
        s = s xor (s shr 17)
        s = s xor (s shl 5)
        result.wram[b][j] = uint8(s and 0xFF'u32)
  result.bootrom = @[]
  if gb.bootrom_path.len > 0 and gb.run_bios and fileExists(gb.bootrom_path):
    let raw = readFile(gb.bootrom_path)
    result.bootrom = newSeq[uint8](raw.len)
    for i in 0 ..< raw.len: result.bootrom[i] = uint8(raw[i])

proc mem_flush_deferred*(mem: GbMemory; gb: GB) =
  ## Apply the half of a CPU write that belongs on the M-cycle boundary rather
  ## than at the write's own commit point (see GbMemory.write_deferred).
  ##
  ## Which half that is follows from what the reorder in mem_write is FOR. The
  ## byte moved to the top of its M-cycle to put it in phase with the mode-3
  ## pixel pipeline, which is the one part of the PPU that was running an
  ## M-cycle ahead of the CPU. The interrupt machinery -- IF, and the STAT
  ## interrupt line that LCDC/STAT/LYC drive -- was already in phase, and a
  ## write's effect on it therefore has to stay exactly where it was:
  ##
  ## Two things qualify; ppu_write_machinery has the classification and the ROMs
  ## that settle each case.
  ##
  ##   * The whole store, for the two registers that gate a PPU event -- STAT's
  ##     source enables and FF55. See ppu_write_machinery.
  ##   * Just the STAT-line edge, for LCDC: the pipeline reads six of its bits,
  ##     so that byte has to move; only its effect on the mode machinery is
  ##     held back (gambatte m2enable/*_late_*, gbmicrotest lyc1_write_timing_*).
  ##
  ## The IF register was tried here too and does NOT belong: deferring an IF
  ## store to the boundary costs gambatte 18 rows (miscmstatirq, lycEnable,
  ## m0enable, m1) to buy one back (gbmicrotest oam_int_if_edge_d), so the CPU's
  ## IF store really does land ahead of the flags the PPU raises in the same
  ## M-cycle. IF is the one register here the PPU *writes* rather than reads,
  ## which is why it does not follow the rule above.
  ##
  ## Nothing here is live across an instruction boundary: every CPU write
  ## consumes it in the same M-cycle, and the few write_byte callers that are
  ## not a CPU M-cycle at all call this themselves. One flag rather than a per
  ## consumer test so the write path pays for it once.
  mem.write_deferred = false
  when CGB_WRITE_LATENCY_ANY:
    # A parked pipeline store the M-cycle's dots never got to (a post-boot
    # register write, a cheat poke -- neither is an M-cycle). mem_write's own
    # tail has already consumed the slot by the time it reaches here.
    if mem.pipe_reg != 0:
      let preg = int(mem.pipe_reg)
      let pval = mem.pipe_val
      mem.pipe_reg = 0
      ppu_apply_pipeline_write(gb.ppu, gb, preg, pval)
  if mem.deferred_reg != 0:
    let reg = int(mem.deferred_reg)
    let v   = mem.deferred_val
    mem.deferred_reg = 0
    ppu_write_machinery(gb.ppu, gb, reg, v)
  ppu_flush_stat_write(gb.ppu, gb)

proc skip_boot*(mem: GbMemory; gb: GB) =
  mem.bootrom = @[]
  # Initial APU/PPU register state after boot ROM (mooneye boot_hwio-*).
  # NR52 must be written first: while the APU is powered off every other
  # sound-register write is dropped. The NR14 write's trigger bit then starts
  # channel 1 exactly like the boot beep does, so NR52 reads back 0xF1 — but
  # the beep's envelope has decayed to silence by the handoff, so the live
  # volume is zeroed after the writes (keeps the boot silent, and CGB
  # PCM12/FF76 reads 0x00).
  mem.write_byte(gb, 0xFF26, 0xF1)
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
  # Beep aftermath: channel 1 stays flagged active (NR52 bit 0) but its
  # envelope has decayed to 0 by PC=0x100. On SGB/SGB2 the handoff happens so
  # much later that channel 1 has been shut off entirely (boot_hwio-S expects
  # NR52 = 0xF0).
  gb.apu.channel1.current_volume = 0
  gb.apu.channel1.vol_env_is_updating = false
  if gb.boot_model in {bmSgb, bmSgb2}:
    gb.apu.channel1.enabled = false
  mem.write_byte(gb, 0xFF40, 0x91)
  mem.write_byte(gb, 0xFF42, 0x00)
  mem.write_byte(gb, 0xFF43, 0x00)
  mem.write_byte(gb, 0xFF45, 0x00)
  mem.write_byte(gb, 0xFF47, 0xFC)
  mem.write_byte(gb, 0xFF48, 0xFF)
  mem.write_byte(gb, 0xFF49, 0xFF)
  mem.write_byte(gb, 0xFF4A, 0x00)
  mem.write_byte(gb, 0xFF4B, 0x00)
  if gb.cgb_enabled:
    # CGB boot ROM leaves the palette-index ports mid-sequence after writing
    # the (compatibility) palettes: BCPS = 0xC8, OCPS = 0xD0 (auto-increment
    # set; mooneye misc/boot_hwio-C).
    mem.write_byte(gb, 0xFF68, 0xC8)
    mem.write_byte(gb, 0xFF6A, 0xD0)
  # Joypad select lines at handoff are a PER-BOOT-ROM split. DMG-family boot
  # ROMs never touch P1 at all, so it is handed over in its reset state and
  # reads $CF (both select lines active). The CGB's, the SGB's AND the AGB's
  # hand off DESELECTED ($FF).
  #
  # **AGB was on the wrong side of this until 2026-08-19**, on the strength of
  # `gbedge` p00 IDENT byte $10 reading CF on a real AGS. Three independent
  # sources say $FF and that reading is the odd one out:
  #
  #   1. The boot ROM itself. The AGB boot ROM *is* the CGB boot ROM — SameBoy
  #      assembles it from cgb_boot.asm with `DEF AGB = 1` — and the
  #      `xor a / cpl / ldh [rJOYP], a` that writes $FF just before handoff is
  #      UNCONDITIONAL. All three `IF DEF(AGB)` blocks in that file are
  #      elsewhere, and the one next to the handoff changes only AF and B.
  #   2. mooneye `misc/boot_hwio-C`. Its `-C` token is the suite's own group
  #      for cgb+agb+ags, i.e. it asserts this register is the same on all
  #      three, and P1 is the ONLY byte it disagreed with us about.
  #   3. SameBoy at GB_MODEL_AGB_A with the real agb_boot.bin prints "Test OK"
  #      on that ROM, pixel-identical to its CGB run.
  #
  # And the $CF reading has a mechanism: $CF is BOTH select lines active, which
  # is not a state any boot ROM leaves — but it is exactly what a flashcart
  # menu leaves after writing $00 to poll "is any key held". The handoff
  # REGISTERS in that same probe are genuine (A=$11/B=$01 is the AGB pair, not
  # the MGB one), so the menu restores A-L and does not restore P1. On the MGB
  # the contamination is invisible because $CF is also the right answer there.
  # See docs/flashcart-runbook.md — this applies to every boot-state byte read
  # through a flashcart menu, not just this one.
  if gb.boot_model in {bmDmg0, bmDmgABC, bmMgb}:
    gb.joypad.button_keys = true
    gb.joypad.direction_keys = true
  mem.write_byte(gb, 0xFFFF, 0x00)
  # None of the writes above is a CPU M-cycle, so nothing consumes what they
  # leave deferred; apply it here instead (see mem_flush_deferred).
  mem_flush_deferred(mem, gb)

# mem_read/mem_write -- and the two halves of the M-cycle tick they are built
# from -- are reached from ~160 generated opcode bodies, and clang's
# inline-cost heuristic puts them right on its threshold: adding or removing a
# single compare on their hot path flips the decision for a large, arbitrary
# subset of those call sites. Measured on this tree, that cliff is worth ~0.9%
# of all retired instructions -- more than twice the cost of everything the OAM
# DMA model and the PPU's CPU lock put on this path combined (0.37% + 0.35%,
# measured additively with the decision pinned). Left to the heuristic it is a
# coin flip re-tossed by every future edit here, which is exactly how a hot-path
# change comes to measure as a 1-2% "regression" that has nothing to do with the
# work it added.
#
# So the decision is made here instead of being inherited. always_inline rather
# than a bare `inline` hint because the hint is what the heuristic is already
# free to ignore; the cost is +568 bytes of __text, and both a DMG and a CGB
# title retire ~0.9% fewer instructions (see docs/gb_oam_dma_cost.md).
# Scoped to clang deliberately, and it is the weaker-looking guard that is the
# careful one. GCC treats a failed always_inline as a hard ERROR rather than a
# dropped hint, so the attribute on a proc with ~160 call sites is a build that
# either works or does not exist -- and the gcc/mingw side of this (Linux and
# Windows CI) cannot be compiled here to find out. Those targets keep a plain
# `inline`, which is the same hint they effectively have today and cannot fail
# to build. macOS, iOS and the emscripten web build are all clang, so the
# measured win lands where the shipping builds are; if the wasm toolchain is
# not detected as clang it simply falls back with nothing lost.
#
# The when-block defining hot_bus_inline lives in gb.nim, just above the
# forward declarations of these procs: on the gcc side the pragma expands to
# `inline`, which Nim requires on the forward declaration as well.

proc mem_tick_bus*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true) {.hot_bus_inline.} =
  ## Everything an M-cycle advances EXCEPT the PPU: the scheduler, the timer
  ## (which also clocks the serial shifter) and the OAM DMA unit.
  ##
  ## Split out of mem_tick_components because a CPU *write* has to be applied
  ## between this half and the PPU half -- see mem_write. The OAM DMA unit is
  ## in this half rather than the PPU's because `dma_busy` decides which of the
  ## two write paths runs, so it has to be settled before the write.
  if from_cpu: mem.cycle_tick_count += cycles
  gb.scheduler.tick(cycles)
  timer_tick(gb.timer, gb, cycles)
  # Hoisted out of mem_dma_tick so an idle OAM DMA costs a flag test rather
  # than a call. The same guard still lives inside mem_dma_tick for any other
  # caller; neither flag can be set from inside its loop.
  if mem.requested_oam_dma or mem.dma_position <= 0xA0:
    mem_dma_tick(mem, gb, cycles)

proc mem_tick_ppu*(mem: GbMemory; gb: GB; cycles: int; ignore_speed = false) {.hot_bus_inline.} =
  ## The PPU half of an M-cycle. Dots, not CPU cycles: half as many of them per
  ## M-cycle in double speed, which is why the shift lives here.
  let ppu_cycles = if ignore_speed: cycles else: cycles shr mem.current_speed
  # Direct call for the shipping renderer; the scanline one still goes through
  # the method table (see GB.fifo_ppu).
  if gb.fifo_ppu != nil: fifo_tick(gb.fifo_ppu, gb, ppu_cycles)
  else: gb.ppu.tick(gb, ppu_cycles)

proc mem_tick_components*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true; ignore_speed = false) {.inline.} =
  ## Both halves, in the order every caller but mem_write wants them.
  ##
  ## The halves carry hot_bus_inline for the same reason mem_read/mem_write do,
  ## and it is not a nicety: this used to be one body inlined into the bus path,
  ## and splitting it left `mem_tick_bus` out of line behind clang's cost
  ## heuristic -- a call on all ~30M bus accesses of a frame-limited run, worth
  ## +0.9% of retired instructions on both a DMG and a CGB title.
  mem_tick_bus(mem, gb, cycles, from_cpu)
  mem_tick_ppu(mem, gb, cycles, ignore_speed)

when CGB_WRITE_LATENCY_ANY:
  # ---- CGB per-register write latency ---------------------------------------
  #
  # A CPU write to a pipeline register does not reach the CGB PPU on the same
  # dot it reaches the DMG one. dingbat commits a write's byte at the top of its
  # M-cycle (mem_write) and every DMG family that brackets one of these agrees
  # with that; on CGB each register is its OWN number of dots later, and the
  # M-cycle's dots are therefore run in pieces with the store dropped in between
  # them. **Every one of those numbers ships at 0 -- the measured table saying
  # why, and what has to be understood before they can be turned up, is at
  # CGB_WX_LATENCY in gb.nim.** This is the mechanism and the derivation; the
  # sweep that reads out any setting of it in ~40 s is tools/gbppu/cgbsweep.sh,
  # and tools/gbppu/famflip.py turns a family into its flip point per device.
  #
  # ---- Why per-register, and not one phase offset ---------------------------
  # The tempting model is a single CPU-to-PPU phase difference between the two
  # models. Two gambatte families with the IDENTICAL shape refuse it outright.
  # window/late_disable_{0,1,2} expects out0,out3,out3 on DMG and out0,out0,out3
  # on CGB -- the flip is one M-cycle LATER on CGB -- while
  # window/late_disable_early_scx03_wx12_{1,2,3} expects out0,out0,out3 on DMG
  # and out0,out3,out3 on CGB, one M-cycle EARLIER. One offset cannot move two
  # families of the same shape in opposite directions; independent per-register
  # latencies can, and the second family writes SCX and WX in the line where the
  # first writes only LCDC. A uniform offset was also measured rather than
  # argued: a flat 4 dots on all six takes gambatte 3561 -> 3539.
  #
  # Pan Docs does not document any of this -- it describes mode 3's length and
  # the window's 6-dot penalty with no DMG/CGB distinction at all -- so the
  # cross-checks here are gambatte's LCD::wxChange/wyChange/scxChange/scyChange/
  # lcdcChange (libgambatte/src/video.cpp), whose `+ ppu_.cgb()` and
  # `+ 2 * ppu_.cgb()` terms are the same six numbers, and SameBoy, whose DMG
  # display loop carries one extra PPU step the CGB one does not
  # (Core/display.c, the LCD-enable path) -- i.e. its DMG PPU also samples
  # earlier. Neither was transcribed, and neither is treated as an oracle: the
  # table in gb.nim is what each constant is scored against, and it is what
  # holds all six at 0.
  #
  # ---- What this is NOT ------------------------------------------------------
  # These are sub-M-cycle deltas. They only look like whole M-cycles because
  # they land on the CPU's 4-dot write grid, and the one genuine full-M-cycle
  # term is CGB_WY_LATCH_LATENCY. Nothing here is the `_ds_` axis: CGB's
  # CPU-to-PPU phase really is variable across 0..3 dots through a KEY1 speed
  # switch (which is what gambatte's CGB-only lcd_offset family enumerates), and
  # that is a different quantity from a register's own latency. The double-speed
  # M-cycle is only 2 dots long, so CGB_LATENCY_CAP is what stops a 2-dot
  # latency from being spent as a whole double-speed M-cycle and scored against
  # those rows.
  #
  # Two further model-specific window behaviours live next to this one and are
  # deliberately NOT here, because each is its own mechanism rather than a
  # latency: SameBoy's CGB-only fetcher-abort on a late window disable (which is
  # what the late_disable families want, and which an LCDC latency alone makes
  # worse), and mode 3 starting on dot 84 rather than 83 on CGB with the pixel
  # pipeline compensating by one dot (gambatte ppu.cpp) -- that one moves the
  # sample point for EVERY register at once and in the opposite direction, so it
  # has to land before these constants can be swept honestly.
  proc mem_tick_ppu_latched(mem: GbMemory; gb: GB) {.noinline.} =
    ## This M-cycle's PPU dots, with a parked pipeline store landing part way
    ## through them. Cold: one CPU write in some hundreds reaches here.
    let reg = int(mem.pipe_reg)
    let val = mem.pipe_val
    mem.pipe_reg = 0
    # 4 dots per normal-speed M-cycle, 2 per double-speed one (Pan Docs,
    # "Dots"). A latency past the end of the M-cycle saturates at `cap`; the
    # dots past that point belong to the next write's M-cycle, which is a
    # different quantity (see CGB_LATENCY_CAP).
    let mdots = 4 shr mem.current_speed
    let cap = mdots - CGB_LATENCY_CAP
    var done = 0
    template run(upto: int) =
      let n = min(upto, cap) - done
      if n > 0:
        mem_tick_ppu(mem, gb, n, ignore_speed = true)
        done += n
    template rest() =
      let n = mdots - done
      if n > 0: mem_tick_ppu(mem, gb, n, ignore_speed = true)
    case reg
    of 0xFF40:
      run(CGB_LCDC_TDSEL_LATENCY); ppu_store_lcdc_tdsel(gb.ppu, gb, val)
      run(CGB_LCDC_LATENCY);       ppu_store_lcdc(gb.ppu, gb, val)
    of 0xFF42:
      run(CGB_SCY_LATENCY); ppu_store_scy(gb.ppu, gb, val)
    of 0xFF43:
      run(CGB_SCX_LATENCY); ppu_store_scx(gb.ppu, gb, val)
    of 0xFF4A:
      run(CGB_WY_LATENCY)
      ppu_store_wy(gb.ppu, gb, val)
      run(CGB_WY_LATCH_LATENCY - int(mem.current_speed))
      ppu_latch_wy(gb.ppu, gb, val)
    of 0xFF4B:
      run(CGB_WX_LATENCY); ppu_store_wx(gb.ppu, gb, val)
    else: discard
    rest()

proc mem_reset_cycle_count*(mem: GbMemory) =
  mem.cycle_tick_count = 0

proc mem_tick_extra*(mem: GbMemory; gb: GB; total_expected: int) =
  let remaining = total_expected - mem.cycle_tick_count
  if remaining > 0: mem_tick_components(mem, gb, remaining)
  mem_reset_cycle_count(mem)

proc unusable_index(gb: GB; idx: int): int {.inline.} =
  ## Which cell of `mem.unusable` an address in `$FEA0..$FEFF` reaches. The
  ## C-class mask (`addr and not 0x18`) folds four addresses onto each cell;
  ## CGB-D keeps all 96 apart. See GbUnusableRegion in gb.nim for where the
  ## mask comes from -- Pan Docs states that one exists and declines to give
  ## its value, so `cgb-acid-hell`'s own readback is the source.
  let a = if gb.quirks.unusable_region == urRamMasked: idx and not 0x18 else: idx
  a - 0xFEA0

proc read_unusable(mem: GbMemory; gb: GB; idx: int): uint8 {.inline.} =
  ## `$FEA0..$FEFF`, the prohibited tail of the OAM page. Three models, one per
  ## GbUnusableRegion member; the quote from Pan Docs' "FEA0-FEFF range" that
  ## each comes from is at the enum.
  ##
  ## NOT modelled, and the same before this split as after it: Pan Docs' "This
  ## area returns $FF when OAM is blocked" for a CPU read during mode 2/3.
  ## dingbat answers the model below there instead. The OAM lock for this range
  ## has never existed (`mem_read_open` says so at its docstring: the OAM lock
  ## lives inside `ppu_read`, which only `$FE00..$FE9F` reaches), so leaving it
  ## alone keeps this change to the revision axis it is about. The OAM-DMA
  ## case IS handled and always was -- `mem_read_busy` answers $FF for the
  ## whole page. `cgb-acid-hell`, the one ROM known to read this range for its
  ## value, waits for STAT bit 1 to clear before every access, so it is not
  ## sensitive to the gap.
  case gb.quirks.unusable_region
  of urZero:       0x00'u8
  of urNibbleEcho:
    # "returns the high nibble of the lower address byte twice, e.g. FEAx
    # returns $AA" -- Pan Docs, verbatim but for its FFAx/FEAx typo.
    let nib = uint8((idx shr 4) and 0x0F)
    (nib shl 4) or nib
  of urRamMasked, urRamPlain:
    mem.unusable[unusable_index(gb, idx)]

proc write_unusable(mem: GbMemory; gb: GB; idx: int; val: uint8) {.inline.} =
  ## The write half of read_unusable. Only the two RAM models keep the byte;
  ## on DMG and on CGB-E-and-later the store goes nowhere.
  case gb.quirks.unusable_region
  of urZero, urNibbleEcho: discard
  of urRamMasked, urRamPlain:
    mem.unusable[unusable_index(gb, idx)] = val

proc read_byte*(mem: GbMemory; gb: GB; idx: int): uint8 =
  # The CGB boot ROM is 0x900 bytes with a hole at 0x100..0x1FF, where the
  # cartridge header shows through; the DMG one is a flat 0x100. Bounding by
  # the actual length is what keeps a DMG boot ROM from being read past its
  # end for every address up to 0x8FF.
  if mem.bootrom.len > 0 and idx < mem.bootrom.len and
     (idx < 0x100 or idx >= 0x200):
    return mem.bootrom[idx]
  case idx
  of 0x0000..0x3FFF: mbc_read_rom_lo(gb.cartridge, idx)
  of 0x4000..0x7FFF: mbc_read_rom_hi(gb.cartridge, idx)
  of 0x8000..0x9FFF: ppu_read(gb.ppu, gb, idx)
  of 0xA000..0xBFFF: mbc_read(gb.cartridge, idx)
  of 0xC000..0xCFFF: mem.wram[0][idx - 0xC000]
  of 0xD000..0xDFFF: mem.wram[mem.wram_bank][idx - 0xD000]
  of 0xE000..0xFDFF: read_byte(mem, gb, idx - 0x2000)
  of 0xFE00..0xFE9F: ppu_read(gb.ppu, gb, idx)
  of 0xFEA0..0xFEFF: read_unusable(mem, gb, idx)
  of 0xFF00:         joypad_read(gb.joypad, gb)
  of 0xFF01..0xFF02: serial_read(gb.serial, gb, idx)
  of 0xFF04..0xFF07: timer_read(gb.timer, idx)
  of 0xFF0F:
    when defined(gb_if_trace):
      if gb.fifo_ppu != nil:
        echo "IFREAD ly=", gb.fifo_ppu.ly, " dot=", gb.fifo_ppu.cycle_counter,
             " if=", toHex(irq_read(gb.interrupts, idx), 2)
    irq_read(gb.interrupts, idx)
  of 0xFF10..0xFF3F: apu_read(gb.apu, idx, gb)
  of 0xFF46:         mem.dma  # always the last written value (mooneye oam_dma/reg_read)
  of 0xFF40..0xFF45, 0xFF47..0xFF4B:
    when defined(gb_dma_trace):
      if (idx == 0xFF41 or idx == 0xFF44) and gb.fifo_ppu != nil:
        echo "REGREAD a=", toHex(idx, 4), " ly=", gb.fifo_ppu.ly,
             " dot=", gb.fifo_ppu.cycle_counter,
             " v=", toHex(ppu_read(gb.ppu, gb, idx), 2)
    when defined(gb_phase_trace):
      if idx == 0xFF44:
        echo "LYREAD v=", ppu_read(gb.ppu, gb, idx), " ly=", gb.ppu.ly,
             " cc=", gb.ppu.cycle_counter, " mode=", gb.ppu.mode_flag
    ppu_read(gb.ppu, gb, idx)
  of 0xFF4D:
    if gb.cgb_native:
      0x7E'u8 or (uint8(mem.current_speed) shl 7) or (if mem.requested_speed_switch: 1'u8 else: 0'u8)
    else: 0xFF'u8
  of 0xFF4F:         ppu_read(gb.ppu, gb, idx)
  of 0xFF51..0xFF55: ppu_read(gb.ppu, gb, idx)
  of 0xFF68..0xFF6B: ppu_read(gb.ppu, gb, idx)
  of 0xFF56:
    # Infrared port, CGB mode only. Bits 0/6/7 R/W; bit 1 reads 1 (no IR
    # signal is ever modeled); bits 2-5 read set. Silicon: $3E at handoff.
    if gb.cgb_native: (mem.rp and 0xC1'u8) or 0x3E'u8 else: 0xFF'u8
  of 0xFF70:
    if gb.cgb_native: 0xF8'u8 or mem.svbk_raw else: 0xFF'u8
  # FF72-FF77 only exist on CGB/AGB hardware (present even in DMG-compat
  # mode, unlike FF74 — mooneye misc/bits/unused_hwio-C); on DMG they are
  # unmapped and read 0xFF (acceptance/bits/unused_hwio-GS).
  of 0xFF72: (if gb.cgb_enabled: mem.ff72 else: 0xFF'u8)
  of 0xFF73: (if gb.cgb_enabled: mem.ff73 else: 0xFF'u8)
  of 0xFF74:
    if gb.cgb_native: mem.ff74 else: 0xFF'u8
  of 0xFF75: (if gb.cgb_enabled: mem.ff75 or 0x8F'u8 else: 0xFF'u8)
  # PCM12/PCM34: read-only mirrors of the four channels' CURRENT 4-bit digital
  # output, low nibble first (CH1/CH3), high nibble second (CH2/CH4). Officially
  # undocumented but present on every CGB, and the only way software can observe
  # APU state at cycle resolution — SameSuite's whole apu/ directory is built on
  # them. Off channels read 0.
  #
  # The catch-up is load-bearing, not defensive: the channels advance lazily, so
  # their wave position is only materialized at an observation point. These
  # registers ARE an observation point — the single thing they exist to expose
  # is the phase at this exact cycle, which is precisely what a stale channel
  # does not have. Reading without syncing first returns the output from
  # whenever the channel was last touched, which is the one wrong answer these
  # tests are built to catch.
  of 0xFF76:
    if gb.cgb_enabled:
      apu_catchup_all(gb.apu, gb)
      gb.apu.channel1.ch1_dac_input() or (gb.apu.channel2.ch2_dac_input() shl 4)
    else: 0xFF'u8
  of 0xFF77:
    if gb.cgb_enabled:
      apu_catchup_all(gb.apu, gb)
      gb.apu.channel3.ch3_dac_input() or (gb.apu.channel4.ch4_dac_input() shl 4)
    else: 0xFF'u8
  of 0xFF80..0xFFFE: mem.hram[idx - 0xFF80]
  of 0xFFFF:         irq_read(gb.interrupts, idx)
  else: 0xFF'u8

proc console_is_cgb*(gb: GB): bool {.inline.} =
  ## The *console*, not the mode. Bus topology is a property of the machine, so
  ## this reads boot_model (which names the hardware) rather than cgb_enabled
  ## (which the boot-ROM handoff clears for a DMG cart in compatibility mode).
  gb.boot_model in {bmCgb0, bmCgbABCDE, bmAgb}

proc dma_bus_of*(gb: GB; idx: int): uint8 {.inline.} =
  ## Which bus serves a 16-bit address. See GbDmaBus. WRAM folds into the
  ## external bus on DMG, which is the whole of the DMG/CGB difference.
  case idx
  of 0x0000..0x7FFF, 0xA000..0xBFFF: uint8(dbExternal)
  of 0x8000..0x9FFF:                 uint8(dbVideo)
  of 0xC000..0xFDFF:
    if console_is_cgb(gb): uint8(dbWram) else: uint8(dbExternal)
  else:                              uint8(dbNone)

const
  # What lands in OAM when the CPU collides with the DMA on its bus, which is
  # decided by what the DMA's *source* does to the data lines in that M-cycle.
  # See mem_write_busy for the derivation.
  DriveTristate* = 0'u8   # cartridge: /WR tells it this is a write, it lets go
                          #            of the lines, so OAM gets the CPU's byte
  DriveSource*   = 1'u8   # DMG WRAM: keeps driving its read data alongside the
                          #           CPU, so the two wire-AND
  DriveZero*     = 2'u8   # CGB video bus: separately arbitrated, the DMA loses
                          #                the cycle entirely and stores $00
  DriveIsolated* = 3'u8   # CGB WRAM bus: also arbitrated, but the DMA's own
                          #               read still completes — OAM is correct
                          #               and only the CPU's access is lost

proc dma_drive_of*(gb: GB; idx: int): uint8 {.inline.} =
  case idx
  of 0x8000..0x9FFF: (if console_is_cgb(gb): DriveZero else: DriveTristate)
  of 0xC000..0xFDFF: (if console_is_cgb(gb): DriveIsolated else: DriveSource)
  else:              DriveTristate

proc mem_read_open(mem: GbMemory; gb: GB; idx: int): uint8 {.inline.} =
  ## A CPU read that actually reaches the bus, with the PPU's own lock applied.
  ##
  ## Only the CPU comes through here: mem_read/mem_write are the CPU's entry
  ## points, while the OAM DMA unit and HDMA drive the bus themselves and go
  ## straight to read_byte/write_byte. That is the whole of the CPU-vs-DMA
  ## distinction, and it is why this lives here rather than in ppu_read — the
  ## DMA unit reaches VRAM through read_byte and must keep its access.
  ##
  ## OAM has no counterpart here because its read lock sits inside ppu_read,
  ## where cpu_oam_open's read/write asymmetry is already handled.
  when defined(gb_dma_trace):
    if (idx and 0xE000) == 0x8000:
      echo "VRAMRD ly=", gb.ppu.ly, " dot=", gb.ppu.cycle_counter,
           " idx=", toHex(idx, 4), " latch=", gb.ppu.read_mode and 3'u8,
           " live=", gb.ppu.lcd_status and 3'u8,
           " open=", (if cpu_vram_open(gb.ppu, is_write = false): 1 else: 0),
           " val=", toHex(read_byte(mem, gb, idx), 2)
  if (idx and 0xE000) == 0x8000:
    # This read samples after its M-cycle's dots, so it is one of the two points
    # a held HBlank DMA block can become visible at -- see HDMA_VISIBLE_DOTS,
    # and ppu_land_hdma_if_due for why the landing is looked for here rather
    # than counted out on every tick.
    when HDMA_VISIBLE_DOTS != 0:
      if gb.ppu.hdma_bytes_held: ppu_land_hdma_if_due(gb.ppu, gb)
    if not cpu_vram_open(gb.ppu, is_write = false): return 0xFF'u8
  read_byte(mem, gb, idx)

const OAMDMA_WRAM_A12* {.intdefine.} = 1
  ## **On CGB the OAM DMA shares the ADDRESS bus, not just the data bus.**
  ##
  ## The CGB splits the data path so the CPU can keep using WRAM while the DMA
  ## drives the external bus — that carve-out is `dma_bus_of` below and it is
  ## right. What it misses is that the WRAM array's half-select still hangs off
  ## the main address bus, and during the transfer the DMA controller is the one
  ## driving that. So a *non-colliding* CPU access to `$C000-$FDFF` reaches real
  ## memory with the CPU's own A0-A11 and region decode, but takes **A12 — the
  ## "fixed bank 0 half" vs "SVBK-banked half" select — from the DMA's source
  ## address**.
  ##
  ## The suite proves this by construction rather than by fitting. gambatte ships
  ## two templates per (source, stem) pair: one that pre-loads the stack cells at
  ## their true addresses, and one that pre-loads them at the true address **with
  ## bit 12 flipped** — and it emits the flipped form exactly when
  ## `A12(DMA source) != A12(the CPU's WRAM address)`. Over all 314 `busy*` ROMs
  ## that predicate picks out the failing set with **0 mismatches**, and
  ## resolving each store through the echo fold and comparing against
  ## `(cell and not $1000) or (A12(src) shl 12)` matches all 64 with 0
  ## mismatches. Two ROMs with the same stem and different source pages
  ## (`src7F00_busypopDFFF` vs `src0000_busypopDFFF`) expect the byte from
  ## different halves; only the source's A12 tells them apart.
  ##
  ## Bracketed on five sides, each by rows that pass today:
  ##  * *untouched* (what this tree did): refused by all 64.
  ##  * *WRAM conflicts like any same-bus access*: refused by the 116 passing
  ##    external-source rows, and by the expected values themselves — they are
  ##    the live `$55`/`$AA` data, never the `$00` source filler or the `$FF` a
  ##    latch read would give.
  ##  * *the whole address comes from the DMA*: refused because the low bits are
  ##    the CPU's — with the DMA at `$7F9E` a read of `$DFFF` returns half-offset
  ##    `$FFF`, not `$F9E`.
  ##  * *any running DMA does it*: refused by the 40 video-source and 40
  ##    WRAM-source rows, all green with the direct template.
  ##  * *it happens on DMG too*: refused by the perfect 312/312 DMG column — a
  ##    DMG folds WRAM into `dbExternal`, so the access collides outright and
  ##    A12 never becomes observable.
  ##
  ## **This is the resolution of the parked `$D000` bucket** (triage bucket 16,
  ## "CGB `$D000` window aliases `$C000`", 64 rows, declined pending hardware).
  ## Forcing `$D000-$DFFF -> wram[0]` scored +64/-2 and contradicted the two
  ## ROMs that pin banking, so it was rightly refused. The contradiction was an
  ## artefact of reading an address-bus effect as a banking rule: the alias only
  ## holds while an external-bus OAM DMA is running, and it goes the other way
  ## too (a `$C000` access is pushed *up* to `$D000` when the source's A12 is
  ## set). No hardware dump is needed.

proc dma_wram_addr(mem: GbMemory; gb: GB; idx: int): int {.inline.} =
  ## `idx` with the WRAM half-select taken from the running DMA, per
  ## OAMDMA_WRAM_A12. Identity unless a CGB external-bus DMA is live and `idx`
  ## is in the WRAM window; the echo is folded first, then A12 is substituted.
  when OAMDMA_WRAM_A12 != 0:
    if idx >= 0xC000 and idx <= 0xFDFF and
       mem.dma_bus == uint8(dbExternal) and console_is_cgb(gb):
      let folded = if idx >= 0xE000: idx - 0x2000 else: idx
      # The RAW source A12, not the echo-folded one: an $E000 source goes out
      # on the external bus unfolded (the carve-out at mem_dma_tick), so
      # $E000 -> 0 and $F000 -> 1.
      let a12 = (int(mem.current_dma_source) shr 12) and 1
      return (folded and not 0x1000) or (a12 shl 12)
  idx

proc mem_read_busy(mem: GbMemory; gb: GB; idx: int): uint8 {.noinline.} =
  ## Cold path: a CPU read issued while the OAM DMA unit is running. Kept out
  ## of line so the common case is a predictable not-taken branch over a call.
  ##
  ## The DMA unit holds one bus for the whole transfer. A CPU read that lands
  ## on that same bus never reaches memory: the bus is already carrying the
  ## byte the DMA is moving into OAM this M-cycle, and that is what the CPU
  ## latches. Reads on any other bus — and on none at all (IO, HRAM, IE) — are
  ## untouched, which is exactly the CGB carve-out Pan Docs describes and why a
  ## cartridge-sourced DMA leaves the video bus alone.
  ##
  ## The whole OAM page reads $FF while the unit owns OAM, not just $FE00-$FE9F.
  if idx >= 0xFE00 and idx <= 0xFEFF: return 0xFF'u8
  if dma_bus_of(gb, idx) == mem.dma_bus:
    # On the CGB video bus the CPU takes the cycle outright: it still gets the
    # byte, but the DMA is left with nothing to store and OAM takes a $00. That
    # costs the transfer a byte even though the CPU only *read*.
    if mem.dma_drive == DriveZero:
      ppu_write(gb.ppu, gb, 0xFE00 + mem.dma_position - 1, 0'u8)
    return mem.dma_latch
  # No collision, so this is an ordinary CPU read and still owes the PPU's lock
  # -- but on CGB the DMA is still driving A12 at the WRAM array.
  mem_read_open(mem, gb, dma_wram_addr(mem, gb, idx))

when IF_READ_SAMPLE_T < 4:
  proc mem_tick_if_read(mem: GbMemory; gb: GB) {.noinline.} =
    ## One M-cycle for a read that latches its byte part way through the dots
    ## rather than after all of them: the $FF0F read, and only it. See
    ## IF_READ_SAMPLE_T in gb.nim and the write-up at irq_read.
    ##
    ## Spelled here, behind an address test in mem_read, rather than in
    ## mem_tick_components where it started. Splitting EVERY M-cycle's dots in
    ## two costs **+19.5% of all retired instructions** on Pokemon Blue
    ## (5.675 G -> 6.779 G, DINGBAT_BENCH_COUNTERS, min of three): fifo_tick's
    ## lazy idle span is written to swallow a whole M-cycle at a time and two
    ## half-M-cycles defeat it, and mem_tick_components is inlined into the bus
    ## path where the extra body pushes it off clang's threshold. A ROM reads
    ## $FF0F a few hundred times a frame, so paying the split there and one
    ## compare everywhere else is the same model for none of the cost.
    mem_tick_bus(mem, gb, 4)
    let dots = 4 shr mem.current_speed
    let head = min(dots, IF_READ_SAMPLE_T shr mem.current_speed)
    if head <= 0:
      irq_latch_mcycle(gb.interrupts)
      mem_tick_ppu(mem, gb, dots, ignore_speed = true)
      return
    mem_tick_ppu(mem, gb, head, ignore_speed = true)
    # fifo_tick re-snapshots `read_mode` on every entry, so the tail call would
    # otherwise re-latch the STAT/VRAM/OAM read mode part way through the
    # M-cycle. Keep the head's latch -- the one this M-cycle owns -- and let the
    # tail contribute only its LY-advanced bit. Without this the split alone
    # moves twelve gambatte rows (oam_access / vram_m3 `postread`, cgbpal_m3,
    # window `*busyread`) that have nothing to do with IF; with it,
    # `-d:gb_if_split_control` scores the baseline exactly.
    let head_rm = gb.ppu.read_mode
    irq_latch_mcycle(gb.interrupts)
    if dots > head:
      mem_tick_ppu(mem, gb, dots - head, ignore_speed = true)
      gb.ppu.read_mode = head_rm or (gb.ppu.read_mode and LY_JUST_CHANGED)

proc mem_read*(mem: GbMemory; gb: GB; idx: int): uint8 {.hot_bus_inline.} =
  when IF_READ_SAMPLE_T < 4:
    if idx == 0xFF0F: mem_tick_if_read(mem, gb)
    else:             mem_tick_components(mem, gb, 4)
  else:
    mem_tick_components(mem, gb, 4)
  # A running DMA owns the bus, so it is decided first and it decides
  # everything: a CPU access it collides with never reaches memory at all, and
  # one it does not collide with is an ordinary CPU access (mem_read_busy falls
  # through to the same mem_read_open). The old three-term OAM predicate
  # this replaced is subsumed by mem_read_busy, which answers 0xFF for the whole
  # OAM page rather than just 0xFE00-0xFE9F.
  if mem.dma_busy: return mem_read_busy(mem, gb, idx)
  mem_read_open(mem, gb, idx)

proc mem_dma_transfer*(mem: GbMemory; source: uint8) =
  mem.dma         = source
  mem.requested_oam_dma = true
  mem.next_dma_counter  = 0

proc write_byte*(mem: GbMemory; gb: GB; idx: int; val: uint8) =
  # Any write with bit 0 set unmaps the boot ROM, permanently. The CGB boot
  # ROM ends with 0x11 but the DMG one writes 0x01, so testing for 0x11 left
  # a DMG boot ROM mapped forever and the cartridge never started.
  if idx == 0xFF50 and (val and 1) != 0:
    mem.bootrom = @[]
    # Handoff. A DMG cart drops out of CGB mode here (the real boot ROM does it
    # a few instructions earlier, via KEY0) — but it does NOT stop being a CGB.
    # This used to clear cgb_enabled, which handed a DMG-compatibility CGB the
    # DMG's timing and the DMG's STAT-write glitch as well as its picture.
    gb_sync_cgb_native(gb)
    # VBK goes with the rest of the CGB register set, so bank 1 is frozen at
    # whatever the boot ROM left in it (nothing) and the map attributes the
    # fetcher reads out of it are all zero from here on.
    if not gb.cgb_native: gb.ppu.vram_bank = 0
  case idx
  of 0x0000..0x7FFF:
    mbc_write(gb.cartridge, idx, val)
    # Resync point 1 of 3 (see mbc_sync_rom_map): every banking register on
    # every mapper with a flat map is written through this window.
    mbc_sync_rom_map(gb.cartridge)
  of 0x8000..0x9FFF: ppu_write(gb.ppu, gb, idx, val)
  of 0xA000..0xBFFF: mbc_write(gb.cartridge, idx, val)
  of 0xC000..0xCFFF: mem.wram[0][idx - 0xC000] = val
  of 0xD000..0xDFFF: mem.wram[mem.wram_bank][idx - 0xD000] = val
  of 0xE000..0xFDFF: write_byte(mem, gb, idx - 0x2000, val)
  of 0xFE00..0xFE9F: ppu_write(gb.ppu, gb, idx, val)
  of 0xFEA0..0xFEFF: write_unusable(mem, gb, idx, val)
  of 0xFF00:         joypad_write(gb.joypad, gb, val)
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
  of 0xFF56:
    if gb.cgb_native: mem.rp = val and 0xC1
  of 0xFF70:
    if gb.cgb_native:
      mem.svbk_raw = val and 0x7
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

proc mem_write_open(mem: GbMemory; gb: GB; idx: int; val: uint8) {.inline.} =
  ## Counterpart of mem_read_open: a CPU write that reaches the bus. Dropped
  ## rather than deferred when the window is shut, and only for the CPU — the
  ## OAM DMA unit writes OAM through write_byte and must not be locked out of
  ## it. Both locks are here, unlike the read side, because ppu_write has no
  ## OAM lock of its own (a write samples the latched mode, a read the live one
  ## — see cpu_oam_open).
  if (idx and 0xE000) == 0x8000:
    # The other point a held block can land at, and the reason it is looked for
    # here at all: this write is about to change VRAM, and a block still in the
    # holding buffer would land on top of it afterwards. A write commits BEFORE
    # its M-cycle's dots, so a block whose dots have not run yet still waits --
    # and then loses that race, which is the one ordering this model gives up.
    when HDMA_VISIBLE_DOTS != 0:
      if gb.ppu.hdma_bytes_held: ppu_land_hdma_if_due(gb.ppu, gb)
    if not cpu_vram_open(gb.ppu, is_write = true): return
  elif idx >= 0xFE00 and idx <= 0xFE9F:
    if not cpu_oam_open(gb.ppu, is_write = true,
                        mcycle_dots = int32(4 shr mem.current_speed)): return
  write_byte(mem, gb, idx, val)

proc mem_write_busy(mem: GbMemory; gb: GB; idx: int; val: uint8) {.noinline.} =
  ## Cold path counterpart of mem_read_busy — the same collision seen from the
  ## other side. A CPU write onto the bus the DMA owns never reaches its
  ## destination; instead the CPU is one of the drivers of the data lines the
  ## DMA is latching, so it lands in OAM at this M-cycle's position.
  ##
  ## What arrives there is whatever the drivers agree on, which is why the
  ## source region matters and not just the bus:
  ##   * cartridge source — the cart sees /WR and stops driving, so OAM gets
  ##     the CPU's byte unmodified;
  ##   * WRAM source — WRAM keeps driving its read data alongside the CPU, and
  ##     the two wire-AND;
  ##   * video source — the same tri-state story on DMG, but on CGB the video
  ##     bus is separately arbitrated and the DMA latches $00.
  if idx >= 0xFE00 and idx <= 0xFEFF: return
  if dma_bus_of(gb, idx) == mem.dma_bus:
    # dma_busy is only true for dma_position in 1 .. 0xA0, so position-1 is
    # always the OAM slot the unit filled at the top of this M-cycle.
    if mem.dma_drive != DriveIsolated:
      let driven =
        case mem.dma_drive
        of DriveSource: val and mem.dma_latch
        of DriveZero:   0'u8
        else:           val
      mem.dma_latch = driven
      ppu_write(gb.ppu, gb, 0xFE00 + mem.dma_position - 1, driven)
    return
  # No collision, so this is an ordinary CPU write and still owes both locks --
  # but on CGB the DMA is still driving A12 at the WRAM array.
  mem_write_open(mem, gb, dma_wram_addr(mem, gb, idx), val)

proc mem_write_tail(mem: GbMemory; gb: GB) {.noinline.} =
  ## The end of a CPU write that left something for the M-cycle to finish: a
  ## CGB pipeline store that lands part way through the dots, and then whatever
  ## belongs on the boundary after them. Off the hot path behind the single
  ## `write_deferred` test mem_write already paid for, so an ordinary write
  ## costs no more than it did before either of them existed.
  when CGB_WRITE_LATENCY_ANY:
    if mem.pipe_reg != 0: mem_tick_ppu_latched(mem, gb)
    else:                 mem_tick_ppu(mem, gb, 4)
  else:
    mem_tick_ppu(mem, gb, 4)
  mem_flush_deferred(mem, gb)

proc mem_write*(mem: GbMemory; gb: GB; idx: int; val: uint8) {.hot_bus_inline.} =
  ## A CPU write commits at the START of its M-cycle, so the byte is applied
  ## BEFORE that M-cycle's PPU dots, not after them.
  ##
  ## The lock and the data are one event on hardware. dingbat decides the
  ## VRAM/OAM lock on the mode at the start of the M-cycle (see cpu_vram_open),
  ## so the byte has to land at the start of the M-cycle too; running the dots
  ## first put the data one M-cycle behind its own lock, and that skew is the
  ## whole of the mode-3 fetch-phase error the pipeline used to be moved to
  ## compensate for (M3_PIPE_MCYCLES in fifo_ppu).
  ##
  ## Reads are NOT reordered: a read has no data to commit, and its own
  ## sample point is already modelled by the read_mode latch.
  #
  # The bus half runs first regardless, because the bus owner decides
  # everything: mem.dma_busy selects which of the two write paths runs, and
  # mem_write_busy reads the DMA position this M-cycle just filled.
  mem_tick_bus(mem, gb, 4)
  # Same ordering as mem_read: the bus owner decides first.
  if mem.dma_busy:
    mem_write_busy(mem, gb, idx, val)
  else:
    mem_write_open(mem, gb, idx, val)
  # Whatever of this write does not land where the byte did -- a CGB pipeline
  # store a dot or two into these dots, an IF store or a STAT interrupt-line
  # edge on the boundary after them. One flag covers all of it, so the write
  # path pays a single test and the dots stay inlined on the common side of it.
  if mem.write_deferred: mem_write_tail(mem, gb)
  else:                  mem_tick_ppu(mem, gb, 4)

proc mem_read_word*(mem: GbMemory; gb: GB; idx: int): uint16 =
  # The address bus is 16 bits: a word access at $FFFF reaches $0000 for its
  # second byte, it does not run off the end of the map. (gambatte
  # oamdma/oamdma_src*_busypopFFFF and busypush0001, whose stack straddles the
  # wrap; before the mask the high byte went to $10000 and was discarded.)
  uint16(mem_read(mem, gb, idx)) or
    (uint16(mem_read(mem, gb, (idx + 1) and 0xFFFF)) shl 8)

proc mem_write_word*(mem: GbMemory; gb: GB; idx: int; val: uint16) =
  mem_write(mem, gb, (idx + 1) and 0xFFFF, uint8(val shr 8))
  mem_write(mem, gb, idx,                  uint8(val and 0xFF))

proc mem_dma_tick*(mem: GbMemory; gb: GB; cycles: int) =
  # Idle exit. This runs for every 4 T-cycles of every memory access, and an
  # OAM DMA is in flight for 160 of the ~70000 dots in a frame — the rest of
  # the time the loop spins purely to re-test two flags. Neither flag can be
  # *set* from inside the loop (requested_oam_dma is armed by a write to
  # 0xFF46 and dma_position is only reset alongside it), so an idle entry
  # means an idle span: bit-identical, ~8-12% of a profile.
  if not mem.requested_oam_dma and mem.dma_position > 0xA0: return
  for _ in 0 ..< cycles:
    if mem.requested_oam_dma:
      inc mem.next_dma_counter
      if mem.next_dma_counter == (when CGB_OAM_DMA_START_T != 8:
                                    (if console_is_cgb(gb): CGB_OAM_DMA_START_T
                                     else: 8)
                                  else: 8):
        when defined(gb_dma_trace):
          # Diagnostic (tools only; compiled out of every shipping build). The
          # PPU dot the OAM DMA unit takes the bus on -- the quantity every
          # `obj_oam_dma_read` on a later line is a function of, and the one
          # `strikethrough` pins to a single byte. See CGB_HALT_PPU_LEAD.
          if gb.fifo_ppu != nil:
            echo "DMASTART ly=", gb.fifo_ppu.ly,
                 " dot=", gb.fifo_ppu.cycle_counter,
                 " src=", toHex(uint16(mem.dma) shl 8, 4)
        when OAM_SCAN_DMA_LOCK != 0:
          # The transfer takes OAM on this dot. A mode-2 scan that is still
          # running has read everything up to here for real, and reads nothing
          # after it until the transfer gives OAM back.
          if gb.fifo_ppu != nil:
            fifo_oam_lock_change(gb.fifo_ppu, gb, taking = true)
        mem.requested_oam_dma  = false
        mem.current_dma_source = uint16(mem.dma) shl 8
        mem.dma_position       = 0
        mem.internal_dma_timer = 0
        mem.dma_busy           = false
        # The bus is fixed for the whole transfer, so classify the source once
        # here instead of per access.
        let raw_src = int(mem.current_dma_source)
        if raw_src >= 0xE000 and console_is_cgb(gb):
          # The echo is a DMG-family behaviour of this unit. On CGB a source at
          # or above $E000 is driven onto the external bus, where neither the
          # cartridge nor WRAM answers, so every byte transferred is open bus.
          mem.dma_bus     = uint8(dbExternal)
          mem.dma_drive   = DriveTristate
          mem.dma_openbus = true
        else:
          # Sources at or above $E000 fetch through the echo, so they are WRAM
          # sources (mooneye oam_dma/sources-GS).
          var bus_src = raw_src
          if bus_src >= 0xE000: bus_src = bus_src and not 0x2000
          mem.dma_bus     = dma_bus_of(gb, bus_src)
          mem.dma_drive   = dma_drive_of(gb, bus_src)
          mem.dma_openbus = false
    if mem.dma_position <= 0xA0:
      if (mem.internal_dma_timer and 3) == 0:
        if mem.dma_position < 0xA0:
          # The OAM DMA unit drives the external bus directly: on DMG, sources
          # at or above 0xE000 read WRAM (the echo extends over 0xE000-0xFFFF,
          # so 0xFE00/0xFF00 sources fetch 0xDE00/0xDF00 — mooneye sources-GS).
          # The latch is the byte now on the DMA's bus for this M-cycle: what a
          # colliding CPU read observes in place of its own address.
          if mem.dma_openbus:
            mem.dma_latch = 0xFF'u8
          else:
            var src = int(mem.current_dma_source) + mem.dma_position
            if src >= 0xE000: src = src and not 0x2000
            mem.dma_latch = read_byte(mem, gb, src)
          write_byte(mem, gb, 0xFE00 + mem.dma_position, mem.dma_latch)
        inc mem.dma_position
        # dma_position is now >= 1, so this is exactly the old
        # `dma_position > 0 and dma_position <= 0xA0` predicate.
        when OAM_SCAN_DMA_LOCK != 0:
          if mem.dma_position > 0xA0 and mem.dma_busy and gb.fifo_ppu != nil:
            # The transfer gives OAM back on this dot. See fifo_oam_lock_change.
            fifo_oam_lock_change(gb.fifo_ppu, gb, taking = false)
        mem.dma_busy = mem.dma_position <= 0xA0
      inc mem.internal_dma_timer

const SPEED_SWITCH_STALL_T* {.intdefine.} = 65548
  ## How long the CPU clock is stopped by a KEY1 speed switch, in T-cycles of
  ## the 4.194304 MHz base clock, i.e. real time (~15.6 ms) — the CPU clock is
  ## what is stopped, so it cannot be the unit of its own stall.
  ##
  ## **Superseded by `SPEED_SWITCH_STALL_CPU` when that is nonzero** (which is
  ## the shipping configuration); kept so the real-time reading stays swept.

const SPEED_SWITCH_STALL_CPU* {.intdefine.} = 131072
  ## The stall measured in cycles of the CPU clock **at the speed being switched
  ## TO**, which is the unit three independent gambatte observables agree on.
  ## Nonzero replaces the real-time `SPEED_SWITCH_STALL_T` reading entirely.
  ##
  ## The old reading held the PPU to a constant 65548 dots in BOTH directions
  ## (`SPEED_SWITCH_STALL_T shl current_speed` cycles, shifted straight back
  ## down for the PPU). This one gives 65540 dots switching to double and
  ## **131080** switching back to single — twice as long in real time, because
  ## the stall is counted in the new CPU clock's own cycles.
  ##
  ## Derived three ways, all on the `speedchange` family, which runs N
  ## back-to-back `STOP`/`LDH ($4D),A` pairs and then reads one observable:
  ##
  ##  * **TIMA.** `speedchange_tima00_{1a,1b,2a,2b}` run TAC = $04, one tick per
  ##    1024 CPU cycles, and want `80,81,81,82` where a frozen timer gives
  ##    `00,01,01,02`: **+0x80 = 128 ticks = 131072 CPU cycles**, and the
  ##    `1a`/`1b` pair brackets it to a single M-cycle. 65540 would give 64.
  ##  * **The second switch is not the first.** `speedchange2_tima00_{2a,2b}`
  ##    want **+1**, not +256 — so the switch that ends in SINGLE speed also
  ##    contributes 128 ticks, i.e. 131072 cycles of a clock running half as
  ##    fast, i.e. twice the real time. This is the row that refuses "fixed real
  ##    time" outright, and no setting of `SPEED_SWITCH_STALL_T` can satisfy it.
  ##  * **LY.** `speedchange_ly44_m3_ly` passes at $39 (0x44 + 143 lines),
  ##    confirming ~65540 dots for one to-double switch; `speedchange2_..._ly_1`
  ##    wants $25 = 37 where the constant-dots model answers $2F = 47, exactly
  ##    ten lines out. 0x44 + 431 lines is 37 (mod 154) and 431 lines is
  ##    196536 dots = 65540 + 131080 — the two directions, added.
  ##
  ## The value is **2^17 exactly**. Swept over the 553 rows of
  ## `speedchange` + `sound` + `dma`, one build per value, against a baseline of
  ## 351:
  ##
  ##   STALL_CPU  131064 131068 *131072* 131076 131080 131084 131088 131096
  ##   rows        348    351     367     355    364    352    362    347
  ##
  ## The surface is jagged rather than unimodal -- neighbouring values move
  ## different sub-families, which is what the old `SPEED_SWITCH_STALL_T` note
  ## already observed -- but 131072 is the maximum and is the only round number
  ## in the range, so the +8 the old real-time constant carried over 65540 is
  ## not a real part of the quantity.

const SPEED_SWITCH_PPU_EXTRA_DOTS* {.intdefine.} = 12 - 4 * CGB_HALT_PPU_LEAD
  ## **The PPU advances further across the stall than the CPU clock does, and
  ## daid's three speed-switch frames are what separate the two quantities.**
  ##
  ## The default is tied to `CGB_HALT_PPU_LEAD` (gb.nim) because the two are one
  ## measurement split between two files -- see the 2026-08-13 section at the
  ## bottom. At the shipping `CGB_HALT_PPU_LEAD = 0` this is 12 and nothing
  ## below changes; turn the lead on and it is 8, which is the value the switch
  ## itself measures once the halt stops being charged to it.
  ##
  ## They contradict each other under any single "the stall is N cycles" model,
  ## and that contradiction is the measurement:
  ##
  ##  * `speed_switch_timing_div` is pixel-exact only when the CPU-domain stall
  ##    is a whole multiple of 256, because it reads DIV back and the residue
  ##    sets the divider's phase for everything after. 131072 = 2^17 gives 0;
  ##    131096 leaves 24 and costs 226 pixels.
  ##  * `speed_switch_timing_ly` and `_stat` are pixel-exact only when the PPU
  ##    advances **65548** dots across a switch INTO double speed -- the count
  ##    the old real-time `SPEED_SWITCH_STALL_T` happened to encode. At 65536
  ##    (2^17 cycles shifted down) they cost 452 and 575 pixels.
  ##
  ## Both are native-CGB carts scored against captures, so neither is a
  ## tolerance artefact, and no value of one constant satisfies both: 131072
  ## gives div 0 / ly 452 / stat 575, 131096 gives div 226 / ly 0 / stat 0.
  ## Two quantities, and this is the difference between them -- the PPU keeps
  ## being clocked through a re-alignment the CPU clock is not yet counting,
  ## which is the mechanism `SPEED_SWITCH_STALL_T`'s own note already named as
  ## unmodelled ("the 6-cycle switch countdown plus the PPU re-alignment
  ## freeze") and never had an instrument for.
  ##
  ## 12 dots is what closes the gap in the to-double direction: 65536 + 12 is
  ## exactly the 65548 the two frames pin, which is why this is the derived
  ## value and not a fitted one. The to-single direction has no pixel witness in
  ## this tree, so it takes the same 12 rather than a second free constant.
  ## (**Both of those sentences are superseded below.** The 12 is the to-double
  ## 8 plus a halt M-cycle these two frames also carry, and the to-single
  ## direction does have a witness — it just is not a pixel one.)
  ##
  ## Bracketed on both sides by those same frames, one build per dot:
  ##
  ##   EXTRA_DOTS      11    *12*   13    14    15    16
  ##   daid ly px     109     0      0     0     0    125
  ##   daid stat px     0     0      0     0   233    233
  ##
  ## so [12,14] is the legal window and 11 and 15 close it from either end.
  ## gambatte is flat across that window (1138 / 1137 / 1138 rows of
  ## speedchange+sound+dma+oamdma), so it has no say between them and the dot
  ## count is what picks 12.
  ##
  ## ---- gambatte is NOT flat across it, and the direction splits (2026-08-13)
  ##
  ## The sentence above is true of the four subdirectories as a TOTAL and false
  ## of the family that measures this quantity, which is why nobody had seen it.
  ##
  ## `speedchange{,2..5}[_nop]_ly44_m3[_nopxK]_m3stat[_scxS]_{1,2}` is a ladder
  ## in SWITCH COUNT: N back-to-back `LDH ($4D),A ; STOP` pairs and then one
  ## STAT read, with `_1` and `_2` one CPU M-cycle apart across the mode 3 -> 0
  ## edge. A per-switch error of d dots therefore shows up as N*d, so the ladder
  ## divides the residual by N -- and none of these ROMs halts, which is what
  ## makes them the only witness in the tree that sees the switch on its own.
  ## Swept one build per dot over all 55 rows (`tools/gbppu/sssweep.sh`, full
  ## table in docs/gb-failure-triage.md bucket 13), the value of THIS constant
  ## at which each rung's `_1` and `_2` are both green is
  ##
  ##       N  ends in  1 M-cyc  green at    => total PPU lead over N switches
  ##       1  double    2 dots  8, 9         8
  ##       2  single    4 dots  5, 6        11
  ##       3  double    2 dots  6           19
  ##       4  single    4 dots  5 / 6       22
  ##       5  double    2 dots  6           30
  ##
  ## and the totals in the last column are the measurement: their successive
  ## differences are **+3, +8, +3, +8**, alternating exactly with the direction
  ## each switch ends in. One constant cannot produce that (N=1 wants 8 per
  ## switch and N=5 wants 6, and every window above is narrower than the 2 dots
  ## that would take); two constants produce it with nothing left over. See
  ## `SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE`.
  ##
  ## The 8 is not a new quantity. **It is this 12 minus the CGB halt-exit
  ## M-cycle that `CGB_HALT_PPU_LEAD` (gb.nim) owns**, and that constant's own
  ## note already recorded, from the other side, that the daid window moves to
  ## 65544..65545 -- i.e. to exactly this 8 -- when it is turned on. daid's two
  ## ROMs each take one halt before their STOP (`halt` at $019B in
  ## `speed_switch_timing_ly.gbc`, IME clear, waiting for the first vblank after
  ## an LCD enable) and everything they sample hangs off that wake, so what they
  ## pin is halt-lead + switch-extra; the `ly44_m3` ladder pins switch-extra
  ## alone. 4 + 8 = 12, and the two instruments never disagree by a dot.
  ##
  ## The halt is also the ONLY carrier those 4 dots can have, which is a
  ## measurement and not an assumption: `LCD_ON_HEAD_START` = 1 and = 9 (the
  ## `1 mod 4` neighbours of the shipping 5) move daid's `_ly` and `_stat` by
  ## **zero** pixels each, because a halt re-anchors the CPU to a PPU event and
  ## a whole-M-cycle shift of the PPU before it cancels out. Only something that
  ## moves the PPU relative to the CPU ACROSS the wake survives, and that is
  ## what `CGB_HALT_PPU_LEAD` is.
  ##
  ## **What the pair is worth, whole gambatte suite, baseline 4183/5005:**
  ##
  ##   A=8 B=3 alone                   4228   daid ly/stat 109 px each -- refused
  ##   A=8 B=3 + CGB_HALT_PPU_LEAD=1   4224   daid green; +75 / -34
  ##   A=12 B=-1 (sum kept, split not) 4205   daid green; +33 / -11 -- a fit
  ##
  ## so it ships OFF, tied to the lead, and lands the day bucket 22 does.

const SS_EXTRA_SINGLE_SAME* = -9999
  ## Sentinel for `SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE`: a value well outside any
  ## legal dot count, so the constant below stays free to take a NEGATIVE one
  ## (which is a reading the sweep has to be able to express — see its note).

const SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE* {.intdefine.} =
  when CGB_HALT_PPU_LEAD != 0: 3 else: SS_EXTRA_SINGLE_SAME
  ## The same quantity for a switch that ends in SINGLE speed. The sentinel
  ## means "use `SPEED_SWITCH_PPU_EXTRA_DOTS` for both directions", which is
  ## what the shipping build does and what every reading before 2026-08-13
  ## assumed; it is the default only while `CGB_HALT_PPU_LEAD` is 0, because the
  ## split is not expressible without the lead (see the neighbour's note).
  ##
  ## **The two directions do not cost the same, and the `ly44_m3` switch-count
  ## ladder is what separates them.** With A the to-double extra and B the
  ## to-single one, N switches alternate A, B, A, B, ... from single speed, so
  ## the ladder's five rungs measure A, A+B, 2A+B, 2A+2B and 3A+2B. Measured
  ## (the neighbour's table): 8, 11, 19, 22, 30 -- five equations, two unknowns,
  ## over-determined, consistent, and solving to
  ##
  ##       A = 8   and   B = 3
  ##
  ## Two of the five rungs are enough (N=1 gives A, N=5 then gives B); the other
  ## three are predictions and all three hold. Swept directly as well, one build
  ## per dot, on the four speed-switch-carrying subdirectories (1310 rows,
  ## baseline 1072), which is a strict two-sided maximum on each axis:
  ##
  ##       A (B=3)   6     7   *8*    9    10          ...12 = 1072
  ##       rows    1078  1085  1116  1092  1077
  ##
  ##       B (A=8)   0     1     2   *3*    4     5     6     7     8
  ##       rows    1088  1084  1091  1116  1096  1082  1083  1086  1083
  ##
  ## and at (8, 3) **all 55 `ly44_m3` rows are green and none is lost** -- the
  ## family goes from 14/55 to 55/55, on every rung, at every SCX and every NOP
  ## count. B = 4 breaks 20 of them and B = 2 breaks 14, so the odd value is
  ## pinned by the ROMs and not chosen.
  ##
  ## B being ODD is the substantive part: a to-single switch leaves the PPU's
  ## dot grid 3 dots -- not a whole M-cycle -- from where the CPU's resumes, so
  ## the machine really does come out of a switch on a sub-M-cycle offset. That
  ## is what `lcd_offset` exists to measure and where this model's one open
  ## residual is: those ROMs want A+B congruent to 0 mod 4 where the ladder says
  ## 11, and 11 rows of them (plus their `lcdoffset1` grafts in `window`,
  ## `m2enable` and `lycEnable`) are the cost of the pair. The `lcd_offset`
  ## ruler cannot arbitrate, because it contradicts ITSELF at that resolution:
  ## `offset1_lyc99int_m0stat_count_scx1_ds` wants A+B odd and
  ## `offset1_lyc99int_m0irq_count_scx1_ds` -- same offset, same SCX, same
  ## device, the STAT flag and the IRQ of the same mode-0 edge -- wants it even.
  ## That is the known "mode-0 STAT raise is one dot early" defect (finding 6 in
  ## docs/gb-failure-triage.md) seen from inside the instrument.

const SPEED_SWITCH_STALL_RUNS_CPU_CLOCK* {.intdefine.} = 1
  ## Whether the timer/serial/OAM-DMA domain runs during the stall.
  ##
  ## It does, and the TIMA rows above are the proof: they can only see +128
  ## ticks if the timer counted through the stall. This is not a contradiction
  ## with Pan Docs' "`DIV` does not tick" — that sentence is about the STOP
  ## leaves, where the whole machine's clock stops. The speed-switch leaf is a
  ## HALT (Pan Docs' own chart calls it that), and in a halt the CPU clock
  ## keeps running for everything except instruction fetch. So the rule is
  ## simply: **the stall is an ordinary halt, and everything that runs during a
  ## halt runs during it.** DIV is still reset at the switch itself, before the
  ## stall starts, which is what makes the tick count come out round.
  ##
  ## 65548 = 2^16 + 12. The nearby 65540 = 2^16 + 4 is a ripple-counter length,
  ## not a fitted number, and three independent sources land on it:
  ##
  ##   * SameBoy times the switch with `speed_switch_halt_countdown = 0x20008`
  ##     (Core/sm83_cpu.c, `stop`). Its cycle unit is half a dot in both speed
  ##     modes (`GB_advance_cycles` doubles only in single speed, and one
  ##     M-cycle is always 4 units), so 0x20008 = 131080 units = 65540 dots.
  ##   * gambatte's three LY rows across the switch (speedchange_ly44_m3_ly,
  ##     speedchange_ly97_ly, dma/hdma_late_m3speedchange_ly) all want the PPU
  ##     to advance exactly 143 scanlines from three different starting LYs.
  ##     143 * 456 = 65208, and 65540 dots is 143.7 lines — the same line, and
  ##     the same answer from every starting line, which is what says this is a
  ##     fixed stall and not a frame reset.
  ##   * Running the eleven blargg cpu_instrs ROMs against SameBoy through the
  ##     real CGB boot ROM (`sameboy_runner` vs `--mode=screenshot`, frame
  ##     1200, both playing the boot ROM). Blargg's console races the PPU after
  ##     the switch — see the section in tests/README.md — which makes the
  ##     frame a high-resolution probe of exactly this constant. Swept:
  ##
  ##         8200 -> 8/11    32768 -> 6/11   65208 -> 8/11   65536 -> 11/11
  ##        65540 -> 11/11  65544 -> 11/11   65664 -> 8/11   66000 -> 11/11
  ##       131072 -> 8/11
  ##
  ##     i.e. the eleven-of-eleven region sits around 2^16, and 0x20008's 65540
  ##     is inside it. The probe is noisy by nature (65664 dips), so it is a
  ##     confirmation of the SameBoy constant, not the source of it.
  ##
  ## Pan Docs' "FF4D — KEY1" says 2050 M-cycles (8200 T-cycles), which is what
  ## this constant used to be. That figure is eight times short of what all
  ## three sources above measure, and it is the outlier; the earlier note here
  ## kept it because sweeping the constant against gambatte alone produced no
  ## clean optimum (2682 at 8200, 2692 near 65 664, jagged in between).
  ##
  ## What the change costs and buys, on the gambatte suite: total 3248 -> 3253,
  ## made of speedchange 108 -> 111 (including speedchange_ly44_m3_ly and
  ## speedchange_ly97_ly, two of the three rows the old note named), dma
  ## 105 -> 108 (three hdma_late_m3speedchange_ly rows), and oamdma 681 -> 680
  ## (oamdma_late_speedchange_stat_1, also a speed-switch row). Everything that
  ## moved is in the speed-switch family. The churn inside speedchange is
  ## sub-M-cycle alignment: SameBoy additionally models a 6-cycle switch
  ## countdown and a PPU re-alignment freeze, which this does not.
  ##
  ## The eight dots between 65540 and 65548 are that missing countdown, and
  ## daid's speed_switch_timing_ly.gbc / _stat.gbc measure them directly. Both
  ## write 128 (resp. 64) back-to-back `ld a,[rLY]` / `ld a,[rSTAT]` reads into
  ## WRAM starting the instruction after the STOP, which samples the PPU every
  ## 8 dots of real time and pins where in a line — and in a frame — the CPU
  ## comes back. At 65540 every transition in both buffers lands exactly one
  ## sample late; the value that puts all of them where the hardware has them
  ## is 65548, and the window is only two dots wide:
  ##
  ##       65540..65543  ly and stat both a sample early
  ##       65544..65547  stat lands, ly still a sample early
  ##       65548..65549  both correct  <-
  ##       65550..65551  stat a sample late
  ##       65552+        ly a sample late as well
  ##
  ## (The observable is really the total PPU advance across the STOP, 65550
  ## dots: the stall plus the opcode's own 4 CPU cycles, which are 2 dots at
  ## the post-switch double speed. Splitting it differently between the two
  ## would move this constant by the same amount the other way.)
  ##
  ## It is worth 8 gambatte rows as well — speedchange 106 -> 112 and oamdma
  ## 680 -> 681, nothing else moving, no row lost — which is what says this is
  ## the countdown and not a fit to one ROM. daid's speed_switch_timing_div.gbc
  ## passes on both values; DIV is reset either way, so it cannot see this.
  ##
  ## ---- Half of those 8 dots is not the countdown (2026-08-10) --------------
  ##
  ## It is the CGB's halt-exit M-cycle, and this constant has been absorbing it.
  ## Both daid ROMs take exactly ONE halt each — LY 144, vblank, IME clear,
  ## traced with `-d:gb_halt_trace` — and everything they sample hangs off that
  ## wake, so what they really pin is the whole PPU advance from the wake to the
  ## reads, this stall included. Turn `CGB_HALT_PPU_LEAD` (gb.nim) on and the
  ## two-dot "both correct" window slides down by exactly one M-cycle. Wrong
  ## pixels of 23040, one build per cell, at LEAD = 1:
  ##
  ##       stall    ly    stat      (`_div` is 0 at every cell — DIV is reset
  ##       65540   109     109       either way, so it cannot see this)
  ##       65542   109       0
  ##       65543   109       0
  ##       65544     0       0   <-  the pair, = 65548 - 4
  ##       65545     0       0
  ##       65546     0     233
  ##       65548   125     233       i.e. what `main` is, with the lead on
  ##
  ## Same two-dot window as the table above, moved by exactly this M-cycle, and
  ## the ROMs agree on it from both sides. (65545 is inside the window and is
  ## still not the value: an odd stall wrecks the dot alignment everywhere else,
  ## costing 118 gambatte rows, 95 of them in `sprites`.) That leaves 65544 =
  ## 65540 + 4, i.e. the unexplained countdown halves to one M-cycle and moves
  ## TOWARDS SameBoy's sourced 65540 rather than away from it, and it is
  ## worth 4 net gambatte `speedchange` rows on top of what LEAD itself buys.
  ##
  ## This constant therefore stays at 65548 for exactly as long as
  ## CGB_HALT_PPU_LEAD stays at 0. They move together or not at all: 65544 with
  ## the lead off puts `speed_switch_timing_ly` a sample early (109 wrong
  ## pixels) while gaining the same 4 `speedchange` rows, which is the shape of
  ## a constant being fitted to a suite past the ROM that measures it.

proc mem_tick_stalled(mem: GbMemory; gb: GB; cycles: int) =
  ## mem_tick_components for the speed-switch stall, where the CPU clock is
  ## off. Pan Docs splits the machine into exactly the two domains this needs:
  ## the CPU, "Timer and Divider Registers", the Serial Port and OAM DMA all
  ## run at the CPU clock (they are the things that go twice as fast in double
  ## speed), while the LCD controller, HDMA and the sound timings keep running
  ## at the same real-time rate either way. The stall stops the first group —
  ## "`DIV` does not tick" is Pan Docs stating that outright — and leaves the
  ## second running, which is what makes the PPU keep drawing (differently per
  ## mode, hence gambatte's speedchange/*_m3_* family) while the CPU is out.
  ##
  ## **That reading of the split is wrong for the speed-switch leaf, and
  ## `SPEED_SWITCH_STALL_RUNS_CPU_CLOCK` is where it is corrected.** Pan Docs'
  ## "`DIV` does not tick" is about the STOP leaves, where the machine's whole
  ## clock stops. The switch leaf is a HALT, and gambatte's
  ## `speedchange_tima00_*` rows count 128 TIMA ticks across one switch — which
  ## only a running timer can produce. So the CPU-clock domain runs here too,
  ## and this proc is then just `mem_tick_components` with the fetch left out.
  gb.scheduler.tick(cycles)
  when SPEED_SWITCH_STALL_RUNS_CPU_CLOCK != 0:
    timer_tick(gb.timer, gb, cycles)
    mem_dma_tick(mem, gb, cycles)
  # `current_speed` is already the speed being switched TO, so this picks the
  # extra by DIRECTION: 1 is a switch that ended in double speed.
  const extra_single =
    when SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE != SS_EXTRA_SINGLE_SAME:
      SPEED_SWITCH_PPU_EXTRA_DOTS_SINGLE
    else: SPEED_SWITCH_PPU_EXTRA_DOTS
  let extra =
    if mem.current_speed == 1: SPEED_SWITCH_PPU_EXTRA_DOTS else: extra_single
  let ppu_cycles = (cycles shr mem.current_speed) + extra
  if gb.fifo_ppu != nil: fifo_tick(gb.fifo_ppu, gb, ppu_cycles)
  else: gb.ppu.tick(gb, ppu_cycles)

proc mem_tick_stopped*(mem: GbMemory; gb: GB) =
  ## One step of the emulator while the CPU is in STOP mode (see stop_instr).
  ##
  ## STOP is "VERY low power standby mode" (Pan Docs, "Using the STOP
  ## Instruction"): the clock the whole machine runs on is stopped, not just
  ## the CPU's. Nothing ticks here — not the scheduler, not the PPU, not the
  ## timer, not the APU — which is the difference between this and the
  ## speed-switch stall above, where only the CPU-clock domain is out.
  ##
  ## What is left is pure frontend pacing. `step_frame` runs cpu.tick until the
  ## PPU sets `frame`, and a frozen PPU never will; without this the emulator
  ## would stop presenting and hang the moment a ROM executed STOP. The panel
  ## keeps whatever stop_panel left in the framebuffer, and that image is
  ## re-presented once per frame's worth of real time.
  let ppu = gb.ppu
  ppu.dots_since_frame += int32(4 shr mem.current_speed)
  if ppu.dots_since_frame >= DOTS_PER_FRAME:
    ppu.dots_since_frame = 0
    ppu.frame = true

proc stop_panel(mem: GbMemory; gb: GB) =
  ## What the screen shows for as long as the machine is in STOP mode. Pan Docs
  ## ("Using the STOP Instruction") describes exactly three cases, and daid's
  ## stop_instr.gb / stop_instr_gbc_mode3.gb are a reference frame for each:
  ##
  ##  * DMG: the PPU is stopped with the rest of the machine, so the panel is
  ##    driven with nothing and blanks — white, the same thing the frontend
  ##    sees with the LCD switched off. (Pan Docs also warns that a real DMG
  ##    left with its LCD enabled across a STOP draws "a horizontal black line
  ##    on the screen and very likely damag[es] the hardware"; that is the
  ##    panel's analogue behaviour on the way down, not something a frame
  ##    buffer can represent, and daid's DMG reference frame is plain white.)
  ##  * CGB with the LCD on: "leaving the LCD enabled when invoking STOP will
  ##    result in a black screen".
  ##  * CGB, "[e]xcept if the LCD is in Mode 3, where it will keep drawing the
  ##    current screen" — the panel holds the image it already has, so the
  ##    framebuffer is left alone.
  ##
  ## The mode is sampled here, on the STOP fetch, which is the M-cycle the ROM
  ## aimed at: stop_instr_gbc_mode3.gb polls STAT until it reads mode 3 and
  ## executes STOP immediately after.
  let ppu = gb.ppu
  if not ppu.lcd_enabled or not gb.cgb_enabled:
    ppu_blank_frame(ppu, gb)
  elif ppu.mode_flag != 3:
    for i in 0 ..< ppu.framebuffer.len: ppu.framebuffer[i] = 0'u16
    ppu.frame = true
    ppu.dots_since_frame = 0

proc stop_instr*(mem: GbMemory; gb: GB): bool =
  ## STOP ($10). Returns whether the byte after the opcode is consumed — STOP's
  ## length is not fixed, and that is the point of most of what follows.
  ##
  ## Pan Docs' "The bizarre case of the Game Boy STOP instruction, before even
  ## considering timing" (Reducing_Power_Consumption, the flow chart in
  ## imgs/stop_diagram.svg, credited to Lior Halphon) is the whole spec of this
  ## opcode. It is a decision tree over three things sampled at the fetch —
  ## whether a button is held on a line SELECTED in P1, whether a KEY1 speed
  ## switch is pending, and whether an interrupt is pending (IE & IF != 0) —
  ## with IME asked once below that. Transcribed leaf by leaf:
  ##
  ##   button held ─ IRQ pending → 1 byte, mode unchanged, DIV not reset
  ##               └ no IRQ      → 2 bytes, HALT mode,     DIV not reset
  ##   no button ─ no switch ─ IRQ pending → 1 byte,  STOP mode, DIV reset
  ##             │            └ no IRQ     → 2 bytes, STOP mode, DIV reset
  ##             └ switch ─ no IRQ      → 2 bytes, HALT mode, DIV reset, speed changes
  ##                      └ IRQ pending → 1 byte, mode unchanged, DIV reset,
  ##                                      speed changes  (see the IME note below)
  ##
  ## Two things fall out of that tree that are worth naming, because they are
  ## the reason it exists:
  ##
  ##  * a held button beats everything, including a requested speed switch.
  ##    That is why every speed-switching ROM writes $30 to P1 first (daid's
  ##    speed_switch_timing_*.gbc do exactly that, `ld a, P1F_GET_NONE`), and
  ##    why it is checked before KEY1 here rather than after.
  ##  * the switch leaves are HALT mode, not a special state: the hardware
  ##    performs the switch by halting with a countdown, so a pending interrupt
  ##    ends that halt at once — which is why the IRQ-pending switch leaf has
  ##    no stall and the CPU simply carries on at the new speed.
  ##
  ## The chart's last question, IME on the switch-with-IRQ-pending leaf, splits
  ## into the leaf above and "the CPU glitches non-deterministically, oops!".
  ## Nothing deterministic can be emulated for the glitch side, so both sides
  ## take the defined leaf; no test ROM in this tree reaches either.
  ##
  ## Not modelled, and unmeasured here: whether the skipped byte is actually
  ## READ (it would matter only for a bus conflict), and whether leaving STOP
  ## mode costs the oscillator a restart delay.
  let button_held = joypad_lines(gb.joypad) != 0x0F'u8
  let irq_pending = interrupt_ready(gb.interrupts)
  # `true` = 2-byte STOP. Every leaf agrees: the second byte is consumed
  # exactly when no interrupt is pending.
  result = not irq_pending

  if button_held:
    # Left branch: no DIV reset, no speed switch, no STOP mode. Either a plain
    # HALT (which an interrupt would have ended anyway, hence only here) or a
    # one-byte nothing, letting the byte after $10 execute as an opcode.
    if not irq_pending: gb.cpu.halted = true
    return

  if mem.requested_speed_switch and gb.cgb_enabled:
    mem.requested_speed_switch = false
    # Pan Docs' STOP chart: entering STOP resets DIV. Go through the FF04
    # write path rather than zeroing tdiv, so the divider's consumers see the
    # reset the way they see any other one — the APU frame sequencer steps
    # early if its tap was high, a shifting serial byte sees its tap fall, and
    # a TIMA edge is checked. Done BEFORE the speed change so those taps are
    # read at the speed the write happened at; `speed_mode=` below then
    # rescales the re-aimed frame-sequencer event along with everything else.
    #
    # ...through timer.nim's own entry point rather than `timer_write` direct,
    # because WHEN in the opcode this reset lands is a measured quantity of its
    # own: see SPEED_SWITCH_DIV_RESET_T there.
    timer_speed_switch_div_reset(gb.timer, gb)
    let old_speed = mem.current_speed
    mem.current_speed = mem.current_speed xor 1
    # The APU channels' next_step deadlines live outside the scheduler's event
    # array, so rescale them the same way `speed_mode=` rescales events.
    gb.apu.apu_rescale_speed(gb, old_speed, mem.current_speed)
    gb.scheduler.`speed_mode=`(mem.current_speed)
    # The stall — the HALT mode the chart's switch leaf names, with its
    # countdown. `SPEED_SWITCH_STALL_T` T-cycles of real time is
    # `SPEED_SWITCH_STALL_T shl current_speed` cycles of the (new) CPU clock,
    # which is the domain the scheduler counts in; mem_tick_stalled shifts it
    # back down for the PPU.
    #
    # It is skipped when an interrupt is already pending, because that halt is
    # an ordinary one: IE & IF != 0 means it never starts. That is the chart's
    # "1 byte, mode doesn't change, DIV is reset, CPU speed changes" leaf — the
    # switch still happens, it just costs nothing.
    #
    # The DIV-APU frame sequencer is the one scheduler event that is NOT
    # real-time: it models a falling edge of the divider's own tap, and the
    # divider is frozen. Lift it over the stall and re-aim it from the (reset,
    # still zero) divider afterwards, which is exactly Pan Docs' "`DIV` does
    # not tick, so *some* audio events are not processed".
    if not irq_pending:
      # The stall, in cycles of the CPU clock the switch lands in — which is
      # the domain the scheduler counts in, so no shift is needed. See
      # SPEED_SWITCH_STALL_CPU for the three observables that pin the unit.
      let stall_cycles =
        when SPEED_SWITCH_STALL_CPU != 0: SPEED_SWITCH_STALL_CPU
        else: SPEED_SWITCH_STALL_T shl mem.current_speed
      when SPEED_SWITCH_STALL_RUNS_CPU_CLOCK != 0:
        # The divider runs, so the DIV-APU tap needs no lifting: the frame
        # sequencer is clocked by the same counter every other event is.
        mem_tick_stalled(mem, gb, stall_cycles)
      else:
        gb.scheduler.clear(etAPUFrameSeq)
        mem_tick_stalled(mem, gb, stall_cycles)
        gb.scheduler.schedule(apu_div_phase(gb.timer, gb), etAPUFrameSeq)
      # The stall is not part of the STOP opcode's own 4 T-cycles: charge it to
      # the instruction so mem_tick_extra does not try to make it up again.
      mem.cycle_tick_count += stall_cycles
    return

  # No button, no speed switch: the two STOP-mode leaves. DIV is reset on both.
  # Same FF04 write path as the switch above, and for the same reason.
  timer_write(gb.timer, gb, 0xFF04, 0)
  # STOP mode. `halted` and `locked` are exactly cpu_lock's pair — the first
  # stops the fetch/dispatch, the second says no interrupt ends this — and
  # `stopped` on top of them says the rest of the machine is stopped too, and
  # that a P10-P13 line going low DOES end it. See cpu.nim's tick for why this
  # rides on `locked` rather than standing on its own.
  gb.cpu.halted  = true
  gb.cpu.locked  = true
  gb.cpu.stopped = true
  stop_panel(mem, gb)
