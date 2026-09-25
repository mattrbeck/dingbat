# MMIO implementation (included by gba.nim)

proc new_mmio*(gba: GBA): MMIO =
  result = MMIO(gba: gba)
  result.waitcnt = WAITCNT()
  result.memctrl = 0x0D000020'u32  # GBATEK, "System Control"

when defined(biosdrvtrace):
  var bdIoReadHook*: proc(address: uint32) {.closure.}

proc `[]`*(mmio: MMIO; address: uint32): uint8 =
  let io_addr = 0xFFFFFF'u32 and address
  when WL_QUIET_EVENTS: mmio.gba.wl_unsafe = true
  when defined(biosdrvtrace):
    if bdIoReadHook != nil: bdIoReadHook(address)
  case io_addr
  of 0x000..0x055: mmio.gba.ppu[io_addr]
  of 0x060..0x0A7:
    # PSG state advances on lazily caught-up deadlines, not events
    mmio.gba.bus.volatile_read = true
    mmio.gba.apu[io_addr]
  of 0x0B0..0x0DF: mmio.gba.dma[io_addr]
  of 0x100..0x10F: mmio.gba.timer[io_addr]
  of 0x120..0x12B, 0x134..0x15B: mmio.gba.serial[io_addr]
  of 0x130..0x133: mmio.gba.keypad[io_addr]
  of 0x200..0x203, 0x208..0x209: mmio.gba.interrupts[io_addr]
  of 0x204..0x205: read(mmio.waitcnt, io_addr and 1)
  of 0x206..0x207, 0x20A..0x20B, 0x302..0x303: 0'u8
  of 0x300: mmio.postflg
  else:
    # Internal memory control: 0x04000800, mirrored every 64K of IO space
    if (io_addr and 0xFFFF'u32) in 0x800'u32..0x803'u32:
      return read(mmio.memctrl, io_addr and 3)
    when defined(test_harness):
      if mmio.gba.test_output != nil and mmio.gba.test_output.mgba_debug_enable == 0xC0DE'u16:
        if io_addr == 0xFFF780'u32: return 0xEA'u8  # low byte of 0x1DEA
        elif io_addr == 0xFFF781'u32: return 0x1D'u8  # high byte
    mmio.gba.bus.read_open_bus_value(io_addr)

when defined(biosdrvtrace):
  # tests/biosdrv_probe.nim: every I/O byte write, before it lands
  var bdIoHook*: proc(address: uint32; value: uint8) {.closure.}

proc `[]=`*(mmio: MMIO; address: uint32; value: uint8) =
  let io_addr = 0xFFFFFF'u32 and address
  when defined(biosdrvtrace):
    if bdIoHook != nil: bdIoHook(address, value)
  case io_addr
  of 0x000..0x055: mmio.gba.ppu[io_addr] = value
  of 0x060..0x0A7: mmio.gba.apu[io_addr] = value
  of 0x0B0..0x0DF:
    mmio.gba.dma[io_addr] = value
    when defined(breakirq):
      # -d:breakirq: empty libgba's interrupt table as the mGBA suite's
      # `DMA Prefetch Break` arms its DMA -- the state a console is in when
      # Misc is opened straight from the menu, rather than after the twelve
      # suites our auto-run puts in front of it (the last of which leaves a
      # TIMER1 handler the V-blank dispatch has to step over). An experiment.
      if io_addr == 0x0DF and mmio.gba.cpu.r[15] >= 0x08005F90'u32 and
         mmio.gba.cpu.r[15] < 0x08005FB0'u32:
        stderr.writeLine("breakirq: table was " &
          hex_str(mmio.gba.bus.read_word_internal(0x03003368'u32)) & " " &
          hex_str(mmio.gba.bus.read_word_internal(0x0300336C'u32)) & " " &
          hex_str(mmio.gba.bus.read_word_internal(0x03003374'u32)))
        mmio.gba.bus.write_word_internal(0x03003368'u32, 0)
        mmio.gba.bus.write_word_internal(0x0300336C'u32, 0)
    when defined(breakwait):
      # -d:breakwait -d:BREAKWAIT=N: run the mGBA suite's `DMA Prefetch Break`
      # loop under another WAITCNT, as a flashcart loader that left its own
      # setting behind would. An experiment, never a default.
      const BREAKWAIT {.intdefine.} = 0
      if io_addr == 0x0DF and mmio.gba.cpu.r[15] >= 0x08005F90'u32 and
         mmio.gba.cpu.r[15] < 0x08005FB0'u32:
        write(mmio.waitcnt, uint8(BREAKWAIT and 0xFF), 0)
        write(mmio.waitcnt, uint8(BREAKWAIT shr 8), 1)
        mmio.gba.bus.update_waitcnt(mmio.waitcnt)
  of 0x100..0x10F: mmio.gba.timer[io_addr] = value
  of 0x120..0x12B, 0x134..0x15B: mmio.gba.serial[io_addr] = value
  of 0x130..0x133: mmio.gba.keypad[io_addr] = value
  of 0x200..0x203, 0x208..0x209: mmio.gba.interrupts[io_addr] = value
  of 0x204..0x205:
    write(mmio.waitcnt, value, io_addr and 1)
    mmio.gba.bus.write_waitcnt(mmio.waitcnt)
  of 0x300:
    mmio.postflg = value and 1
  of 0x301:
    # HALTCNT answers only to BIOS code; a byte write from ROM or RAM is
    # ignored. Hardware (haltprobe on an AGB SP, docs/playtest-bugs.md
    # section 18): through SWI 2 the CPU halts 4931 cycles and comes back on
    # the V-count match four lines later, and dingbat agrees to the cycle --
    # but a `strb` to 0x04000301 from IWRAM does not halt it at all, it stays
    # on the same scanline, and mGBA agrees. We honoured the write from
    # anywhere, so a game could halt itself by a route hardware ignores.
    # SWI 2 is unaffected: hle_bios sets cpu.halted directly.
    # What counts is where the newest fetch (r15) was made, by address, not
    # which memory answered it: with MEMCNT's swap on, a `strb` from the
    # chip WRAM at 01007000 or 01FFFFF0 (r15 01FFFFF8) halts the CPU and one
    # from 01FFFFF8 (r15 02000000, where the BIOS now is) does not
    # (tests/roms/payloads/haltswap.s on an AGB SP; png183 memory t110/t111).
    # The BIOS's read protection goes by memory instead (bus.nim,
    # swap_privileged).
    if mmio.gba.cpu.r[15] >= 0x02000000'u32: return
    # Entering the halt stalls the CPU HALT_ENTRY_STALL cycles, and an
    # interrupt the CPU had already recognised by the write is taken at the
    # boundary after them, with no halt and no wake instruction (alyosha
    # irq/halt_pc_2..4, a timer overflowing across Halt's HALTCNT write:
    # recognised on or before the write's cycle, the handler finds the
    # BIOS's `bx lr` not yet run, 2 cycles after the write; recognised a
    # cycle after it, `bx lr` has run, from 2 cycles after the write).
    let seen = mmio.gba.cpu.irq_line and not bit(value, 7)
    mmio.gba.bus.add_cycles(HALT_ENTRY_STALL)
    if seen: return
    mmio.gba.cpu.halted = true
    mmio.gba.cpu.stopped = bit(value, 7)
    # Stop blanks the LCD without a memory write.
    if mmio.gba.cpu.stopped:
      mmio.gba.ppu.render_dirty = true
    # Wake immediately if an enabled interrupt is already pending.
    mmio.gba.interrupts.schedule_interrupt_check()
  else:
    if (io_addr and 0xFFFF'u32) in 0x800'u32..0x803'u32:
      # Internal memory control: the EWRAM wait field, the board WRAM
      # enable (bit 5) and the swap (bit 0) are live (see update_waitcnt).
      let was = mmio.memctrl and 0x21'u32
      write(mmio.memctrl, value, io_addr and 3)
      mmio.gba.bus.update_waitcnt(mmio.waitcnt)
      if (mmio.memctrl and 0x21'u32) != was:
        # the cached fetch page may point at the other RAM, or at a region
        # the swap moved
        mmio.gba.bus.fetch_page = 0xFFFFFFFF'u32
        mmio.gba.bus.fetch_key = 0xFFFFFFFF'u32
      return
    when defined(test_harness):
      if mmio.gba.test_output != nil:
        if io_addr == 0xFFF780'u32:
          mmio.gba.test_output.mgba_debug_enable =
            (mmio.gba.test_output.mgba_debug_enable and 0xFF00'u16) or uint16(value)
        elif io_addr == 0xFFF781'u32:
          mmio.gba.test_output.mgba_debug_enable =
            (mmio.gba.test_output.mgba_debug_enable and 0x00FF'u16) or (uint16(value) shl 8)
        elif io_addr == 0x999990'u32:
          mmio.gba.test_output.agbeeg_log.add(char(value))
        elif io_addr >= 0xFFF600'u32 and io_addr <= 0xFFF6FF'u32:
          let off = int(io_addr - 0xFFF600'u32)
          mmio.gba.test_output.mgba_debug_buffer[off] = value
        elif io_addr >= 0xFFF700'u32 and io_addr <= 0xFFF701'u32:
          var s = ""
          for b in mmio.gba.test_output.mgba_debug_buffer:
            if b == 0: break
            s.add(char(b))
          mmio.gba.test_output.mgba_debug_output.add(s & "\n")
          mmio.gba.test_output.mgba_debug_buffer = default(array[256, uint8])
          mmio.gba.test_output.mgba_debug_pos = 0
