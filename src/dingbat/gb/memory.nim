# GB Memory bus (included by gb.nim)

proc cgb_native*(gb: GB): bool =
  ## True when the CGB-only half of the IO map is exposed. A DMG cart on CGB
  ## hardware runs in DMG-compatibility mode where KEY1/HDMA/SVBK/BCPD/OCPD/
  ## FF74 read as unmapped (mooneye misc/bits/unused_hwio-C); the boot ROM
  ## itself always runs native (it switches modes at handoff via KEY0).
  gb.cgb_enabled and (gb.cgb_flag != cgbNone or gb.memory.bootrom.len > 0)

proc new_gb_memory*(gb: GB): GbMemory =
  # DMA (FF46) reads back the last written value; post-boot it's 0xFF on
  # DMG-family models, 0x00 on CGB (Pan Docs power-up sequence).
  result = GbMemory(wram_bank: 1, dma_position: 0xA1,
                    dma: if gb.cgb_enabled: 0x00'u8 else: 0xFF'u8)
  for i in 0 ..< 8:
    result.wram[i] = newSeq[uint8](0x1000)
  result.bootrom = @[]
  if gb.bootrom_path.len > 0 and gb.run_bios and fileExists(gb.bootrom_path):
    let raw = readFile(gb.bootrom_path)
    result.bootrom = newSeq[uint8](raw.len)
    for i in 0 ..< raw.len: result.bootrom[i] = uint8(raw[i])

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
  # DMG-family boot ROMs leave both joypad select lines active (P1 reads
  # 0xCF); SGB/CGB/AGB hand off with neither selected (P1 reads 0xFF).
  if gb.boot_model in {bmDmg0, bmDmgABC, bmMgb}:
    gb.joypad.button_keys = true
    gb.joypad.direction_keys = true
  mem.write_byte(gb, 0xFFFF, 0x00)

proc mem_tick_components*(mem: GbMemory; gb: GB; cycles: int; from_cpu = true; ignore_speed = false) {.inline.} =
  if from_cpu: mem.cycle_tick_count += cycles
  gb.scheduler.tick(cycles)
  let ppu_cycles = if ignore_speed: cycles else: cycles shr mem.current_speed
  # Direct call for the shipping renderer; the scanline one still goes through
  # the method table (see GB.fifo_ppu).
  if gb.fifo_ppu != nil: fifo_tick(gb.fifo_ppu, gb, ppu_cycles)
  else: gb.ppu.tick(gb, ppu_cycles)
  timer_tick(gb.timer, gb, cycles)
  # Hoisted out of mem_dma_tick so an idle OAM DMA costs a flag test rather
  # than a call. The same guard still lives inside mem_dma_tick for any other
  # caller; neither flag can be set from inside its loop.
  if mem.requested_oam_dma or mem.dma_position <= 0xA0:
    mem_dma_tick(mem, gb, cycles)

proc mem_reset_cycle_count*(mem: GbMemory) =
  mem.cycle_tick_count = 0

proc mem_tick_extra*(mem: GbMemory; gb: GB; total_expected: int) =
  let remaining = total_expected - mem.cycle_tick_count
  if remaining > 0: mem_tick_components(mem, gb, remaining)
  mem_reset_cycle_count(mem)

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
  of 0xFEA0..0xFEFF: 0x00'u8
  of 0xFF00:         joypad_read(gb.joypad)
  of 0xFF01..0xFF02: serial_read(gb.serial, gb, idx)
  of 0xFF04..0xFF07: timer_read(gb.timer, idx)
  of 0xFF0F:         irq_read(gb.interrupts, idx)
  of 0xFF10..0xFF3F: apu_read(gb.apu, idx, gb)
  of 0xFF46:         mem.dma  # always the last written value (mooneye oam_dma/reg_read)
  of 0xFF40..0xFF45, 0xFF47..0xFF4B: ppu_read(gb.ppu, gb, idx)
  of 0xFF4D:
    if gb.cgb_native:
      0x7E'u8 or (uint8(mem.current_speed) shl 7) or (if mem.requested_speed_switch: 1'u8 else: 0'u8)
    else: 0xFF'u8
  of 0xFF4F:         ppu_read(gb.ppu, gb, idx)
  of 0xFF51..0xFF55: ppu_read(gb.ppu, gb, idx)
  of 0xFF68..0xFF6B: ppu_read(gb.ppu, gb, idx)
  of 0xFF70:
    if gb.cgb_native: 0xF8'u8 or mem.wram_bank else: 0xFF'u8
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
  if (idx and 0xE000) == 0x8000 and not cpu_vram_open(gb.ppu, is_write = false):
    return 0xFF'u8
  read_byte(mem, gb, idx)

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
  # No collision, so this is an ordinary CPU read and still owes the PPU's lock.
  mem_read_open(mem, gb, idx)

# mem_read/mem_write are reached from ~160 generated opcode bodies, and clang's
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
when defined(clang):
  {.pragma: hot_bus_inline,
    codegenDecl: "__attribute__((always_inline)) inline $# $#$#".}
else:
  {.pragma: hot_bus_inline, inline.}

proc mem_read*(mem: GbMemory; gb: GB; idx: int): uint8 {.hot_bus_inline.} =
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
    gb.cgb_enabled = gb.cgb_flag != cgbNone
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
  of 0xFEA0..0xFEFF: discard
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
  of 0xFF70:
    if gb.cgb_native:
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
    if not cpu_vram_open(gb.ppu, is_write = true): return
  elif idx >= 0xFE00 and idx <= 0xFE9F:
    if not cpu_oam_open(gb.ppu, is_write = true): return
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
  # No collision, so this is an ordinary CPU write and still owes both locks.
  mem_write_open(mem, gb, idx, val)

proc mem_write*(mem: GbMemory; gb: GB; idx: int; val: uint8) {.hot_bus_inline.} =
  mem_tick_components(mem, gb, 4)
  # Same ordering as mem_read: the bus owner decides first.
  if mem.dma_busy:
    mem_write_busy(mem, gb, idx, val)
    return
  mem_write_open(mem, gb, idx, val)

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
      if mem.next_dma_counter == 8:
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
        mem.dma_busy = mem.dma_position <= 0xA0
      inc mem.internal_dma_timer

const SPEED_SWITCH_STALL_T* = 65540
  ## How long the CPU clock is stopped by a KEY1 speed switch, in T-cycles of
  ## the 4.194304 MHz base clock, i.e. real time (~15.6 ms) — the CPU clock is
  ## what is stopped, so it cannot be the unit of its own stall.
  ##
  ## 65540 = 2^16 + 4. It is a ripple-counter length, not a fitted number, and
  ## three independent sources land on it:
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
  ## So: no timer_tick (which also drives the serial shift clock) and no
  ## mem_dma_tick; the scheduler and the PPU advance as usual.
  gb.scheduler.tick(cycles)
  let ppu_cycles = cycles shr mem.current_speed
  if gb.fifo_ppu != nil: fifo_tick(gb.fifo_ppu, gb, ppu_cycles)
  else: gb.ppu.tick(gb, ppu_cycles)

proc stop_instr*(mem: GbMemory; gb: GB) =
  if mem.requested_speed_switch and gb.cgb_enabled:
    mem.requested_speed_switch = false
    # Pan Docs' STOP chart: entering STOP resets DIV. Go through the FF04
    # write path rather than zeroing tdiv, so the divider's consumers see the
    # reset the way they see any other one — the APU frame sequencer steps
    # early if its tap was high, a shifting serial byte sees its tap fall, and
    # a TIMA edge is checked. Done BEFORE the speed change so those taps are
    # read at the speed the write happened at; `speed_mode=` below then
    # rescales the re-aimed frame-sequencer event along with everything else.
    timer_write(gb.timer, gb, 0xFF04, 0)
    let old_speed = mem.current_speed
    mem.current_speed = mem.current_speed xor 1
    # The APU channels' next_step deadlines live outside the scheduler's event
    # array, so rescale them the same way `speed_mode=` rescales events.
    gb.apu.apu_rescale_speed(gb, old_speed, mem.current_speed)
    gb.scheduler.`speed_mode=`(mem.current_speed)
    # The stall. 8200 T-cycles of real time is `8200 shl current_speed` cycles
    # of the (new) CPU clock, which is the domain the scheduler counts in;
    # mem_tick_stalled shifts it back down for the PPU.
    #
    # The DIV-APU frame sequencer is the one scheduler event that is NOT
    # real-time: it models a falling edge of the divider's own tap, and the
    # divider is frozen. Lift it over the stall and re-aim it from the (reset,
    # still zero) divider afterwards, which is exactly Pan Docs' "`DIV` does
    # not tick, so *some* audio events are not processed".
    gb.scheduler.clear(etAPUFrameSeq)
    mem_tick_stalled(mem, gb, SPEED_SWITCH_STALL_T shl mem.current_speed)
    gb.scheduler.schedule(apu_div_phase(gb.timer, gb), etAPUFrameSeq)
    # The stall is not part of the STOP opcode's own 4 T-cycles: charge it to
    # the instruction so mem_tick_extra does not try to make it up again.
    mem.cycle_tick_count += SPEED_SWITCH_STALL_T shl mem.current_speed
