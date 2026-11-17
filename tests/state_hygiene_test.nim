## A state loaded into a running core leaves it as a state loaded into a new
## one does. Run standalone: nimble test_statehygiene
##   (or ./dingbat_state_hygiene_test [filter], DINGBAT_HYGIENE_ALL=1 to list
##   every differing field, the allowed ones too)
##
## Every few frames of the state soak's cases (state_soak_test.nim, built with
## -d:soak_lib: every committed ROM and the seeded random programs, both
## cores), the core's payload is loaded back into the core itself and into a
## core built for it, and the two are compared field by field: every number,
## flag, enum, array and seq of the core's objects. A field that differs is
## one the payload does not carry and the load does not reset, so a running
## core keeps a value a new one does not have. The soak finds that only once
## it changes a replay; this finds it while it is still harmless (the DMG
## HALT start, 6469b34f, was such a field until a new frame boundary made it
## matter).
##
## Fields that may differ are listed in LoadScratch with the reason each is
## dead at a frame boundary. A field that differs and is not listed fails.

include state_soak_test
import std/[tables, sequtils]

const
  HygieneEvery = [5, 11, 3, 17, 7]   ## frames between checks, cycled
  HygieneRandomFrames = 600
  HygieneRomFrames = 300

  # Fields a load may leave as they were, each with why the value is dead at
  # a frame boundary (where every state is written): it is overwritten before
  # it is next read. Paths are component.field (nested: .sub).
  # A trailing `*` lists every field starting with the rest.
  WaitloopGba = "the GBA idle-loop detector's memory (waitloop.nim): a skip " &
    "changes nothing (playtest dingbat-nowl), and the load sets " &
    "wl_unsafe / entered_waitloop false / wl_bound_addr 0 / dyn_key 0, so the " &
    "first verdict after it cannot skip and rewrites these first"
  WaitloopGb = "the GB idle-loop skip (cpu.nim wl_*): it only jumps exact " &
    "repeats, and the load sets wl_head -1 / wl_edge false (no snapshot)"
  LoadScratch: seq[(string, string)] = @[
    # ---- slack: slots outside a live range
    ("sched.evbuf", "event slots at or past nevents: every reader stays below it"),
    ("ppu.fifo.data", "GB pixel FIFO slots outside head..tail; cleared at mode-3 entry"),
    ("ppu.fifo_sprite.data", "as ppu.fifo.data, the object FIFO"),
    ("ppu.walk_bgs", "GBA: only [0, walk_n) is read, rewritten by every composite"),
    ("ppu.walk_prios", "GBA: as walk_bgs"),
    # ---- GB, dead at a frame boundary (overwritten before the next read)
    ("cpu.cur_opcode", "set before every exec; the latched op after HALT/STOP falls in the same arm as 0"),
    ("mem.deferred_val", "read only under deferred_reg, drained every M-cycle (0 at a boundary)"),
    ("mem.pipe_val", "read only under pipe_reg, 0 at a boundary"),
    ("mem.write_count", "compared only with its own copies (wl_writes; off_wc, -1 after a load)"),
    ("gb.lyc_land_val", "read only while lyc_land_left >= 0; the load sets it -1"),
    ("gb.lyc_stop_saved", "read only while lyc_stop_lent; the load clears it"),
    ("gb.m0_tail_dot", "reset to -1 at every mode-3 entry, read only in mode 3"),
    ("gb.we_on_dot", "reset at every mode-3 entry, read only by mode-3 fetches"),
    ("gb.hdma_wake_dot", "read only at an awake edge after a wake, and every wake writes it"),
    ("gb.wd_ds_ly", "WIN_REVOKE_DS_PUSH record: read only while wd_ds_push (false after a load)"),
    ("gb.wd_fifo*", "as gb.wd_ds_ly"),
    ("ppu.wd_*", "the window-defer undo's copies: read only while win_defer > 0 or wd_ds_push, both reset by the load"),
    ("ppu.hdma_due_deadline", "read only while hdma_block_due; every set writes both"),
    ("ppu.hdma_due_dot", "as hdma_due_deadline"),
    ("ppu.hdma_kill_from", "its read is compiled out (HDMA_HALT_REQ = 1)"),
    ("ppu.vdma_tail_dot0", "ANDed with vdma_tail_busy, 0 after a load and per line"),
    ("ppu.vdma_lost", "read only when vdma_lost_dot == the dot; the load sets that -1"),
    ("ppu.scx_latch_slot", "read only while scx_latch_until >= 0; the load sets it -1"),
    ("ppu.m3_lead", "written at every mode 2 -> 3, read only in mode 3"),
    ("ppu.m3_hold", "as m3_lead"),
    ("ppu.lazy_dot", "read only while lazy_end > 0; the load sets it 0"),
    ("ppu.mix_run", "set 0 at mode 2 -> 3; after a load its HBlank reader gets an empty span"),
    ("ppu.fetch_scy", "written by a fetch's map read before its tile reads"),
    ("ppu.obj_fix_*", "read only inside obj_fix_from..obj_hi_dot, both off after a load and per line"),
    ("ppu.map_old", "read only while the dot < map_dot, int32.low after a load and per line"),
    ("ppu.win_pad_lx", "read only while win_pad != 0; the load zeroes it"),
    ("ppu.win_bg_push", "int32.low at every mode-3 entry, written by a mid-line window start before its abort reads it"),
    ("ppu.read_mode", "rewritten at the start of every PPU tick, before a CPU read samples it"),
    ("ppu.stat_wr_dot", "read only while a STAT write is parked (deferred_reg $FF41)"),
    ("ppu.stat_prev_mode", "read only within stat_chg_dot's window (-1024 after a load) or after a mode change"),
    ("serial.pre_*", "the pre-edge shifter: read only when edge_cycle is now; the load sets it high"),
    ("cpu.wl_*", WaitloopGb),
    ("gb.wl_mark", WaitloopGb),
    ("apu.dc_cap_left", "the output capacitor: shapes the presented stream only (mixed before it), settles in ~6 ms"),
    ("apu.dc_cap_right", "as dc_cap_left"),
    # ---- GBA, dead at a frame boundary
    ("bus.load_*", "every read is gated on load_size != 0; end_frame zeroes it, and a load writes them all with it"),
    ("bus.dma_bus_req", "set at every burst grant; read only while dma_active (false between instructions)"),
    ("bus.dma_bus_tail", "as dma_bus_req"),
    ("bus.dma_grant_now", "seeded and consumed within one burst"),
    ("bus.dma_bus_kept", "set per grant in run_pending before run_channel reads it"),
    ("dma.irq_was_set", "read only under irq_after_burst, cleared after the burst"),
    ("dma.fifo_rom_next", "read only with fifo_chain 1 or 3, which only a burst after the load arms (writing it first)"),
    ("cpu.ldm_glitch_*", "matter only under ldm_glitch, which the load zeroes"),
    ("gba.frame_start_cycles", "rewritten at every step_frame; read by the debugger only"),
    ("ppu.line_bg_enables", "set for every drawn line before a renderer reads it"),
    ("ppu.layer_palettes", "enabled BGs' rows cleared per line; disabled rows never read"),
    ("ppu.sprite_pixels", "reset for every drawn line"),
    ("ppu.bitmap_direct", "set false for every line"),
    ("ppu.bg2_direct_opaque", "cleared by every render_bitmap; read only under bitmap_direct"),
    ("ppu.bg2_direct", "read only where bg2_direct_opaque was set this line"),
    ("ppu.walk_n", "set by compute_layer_walk at the top of composite"),
    ("ppu.line_enables", "all 240 columns written by compute_line_enables right before the reads"),
    ("ppu.line_effects", "as line_enables"),
    # ---- GBA caches
    ("cpu.dyn_*", WaitloopGba), ("bus.dyn_*", WaitloopGba),
    ("cpu.identified_*", WaitloopGba), ("cpu.last_*", WaitloopGba),
    ("cpu.waitloop_first_load*", WaitloopGba), ("cpu.never_keys", WaitloopGba),
    ("cpu.branch_dest", WaitloopGba), ("cpu.branch_dest2", WaitloopGba),
    ("cpu.swi_count", WaitloopGba), ("cpu.irq_count", WaitloopGba),
    ("gba.last_dispatch_pc", WaitloopGba), ("gba.dispatch_count", WaitloopGba),
    ("gba.dma_bursts", WaitloopGba), ("gba.verdict_kinds", WaitloopGba),
    ("gba.dyn_kinds", WaitloopGba),
    ("bus.io_read", WaitloopGba), ("bus.volatile_read", WaitloopGba),
    ("bus.volatile_pc", WaitloopGba), ("bus.contended_access", WaitloopGba),
    ("ppu.cont_*", "GBA contention tables keyed by register state; the load sets the keys stale, rebuilt before use"),
    ("ppu.obj_line_mask", "derived from OAM; the load marks the object list dirty, rebuilt before use"),
    ("bus.fetch_mask", "read only when the page is fetch_key, installed with it (the load reinstalls or clears it)"),
    ("bus.dma_stall_total", "used only as a difference within one routine segment"),
    ("dma.fifo_xfer_cycle", "read only by the MP2K audio HLE's latency estimate (host audio; its slots drop on load)"),
    ("gba.payload_len_hint", "the next payload buffer's capacity"),
    ("storage.dirty", "battery-file bookkeeping, never read by emulation"),
    ("storage.eeprom_file_tail", "as storage.dirty"),
  ]

proc cmp_fields[O](a, b: O; path: string; acc: var seq[string]) =
  for name, x, y in fieldPairs(a, b):
    let p = path & "." & name
    when x is SomeNumber or x is bool or x is enum or x is char or x is string:
      if x != y: acc.add(p)
    elif x is set:
      if x != y: acc.add(p)
    elif x is array or x is seq:
      when compiles(x == y):
        if x != y: acc.add(p)
    elif x is tuple:
      cmp_fields(x, y, p, acc)
    elif x is object:
      cmp_fields(x, y, p, acc)
    else: discard   # refs, procs, pointers: the components themselves

template cmp_ref(a, b: typed; label: string; acc: var seq[string]) =
  if not a.isNil and not b.isNil: cmp_fields(a[], b[], label, acc)

proc state_diff(a, b: GB): seq[string] =
  cmp_ref(a, b, "gb", result)
  cmp_ref(GbFifoPpu(a.ppu), GbFifoPpu(b.ppu), "ppu", result)
  cmp_ref(a.cpu, b.cpu, "cpu", result)
  cmp_ref(a.memory, b.memory, "mem", result)
  cmp_ref(a.timer, b.timer, "timer", result)
  cmp_ref(a.interrupts, b.interrupts, "irq", result)
  cmp_ref(a.scheduler, b.scheduler, "sched", result)
  cmp_ref(a.serial, b.serial, "serial", result)
  cmp_ref(a.joypad, b.joypad, "joy", result)
  cmp_ref(a.apu, b.apu, "apu", result)
  cmp_ref(a.cartridge, b.cartridge, "cart", result)

proc state_diff(a, b: GBA): seq[string] =
  cmp_ref(a, b, "gba", result)
  cmp_ref(a.cpu, b.cpu, "cpu", result)
  cmp_ref(a.bus, b.bus, "bus", result)
  cmp_ref(a.ppu, b.ppu, "ppu", result)
  cmp_ref(a.apu, b.apu, "apu", result)
  cmp_ref(a.dma, b.dma, "dma", result)
  cmp_ref(a.timer, b.timer, "timer", result)
  cmp_ref(a.interrupts, b.interrupts, "irq", result)
  cmp_ref(a.scheduler, b.scheduler, "sched", result)
  cmp_ref(a.mmio, b.mmio, "mmio", result)
  cmp_ref(a.keypad, b.keypad, "keypad", result)
  cmp_ref(a.serial, b.serial, "serial", result)
  cmp_ref(a.storage, b.storage, "storage", result)
  cmp_ref(a.cartridge, b.cartridge, "cart", result)

let list_all = existsEnv("DINGBAT_HYGIENE_ALL")
var allowed_seen: seq[string]
var all_seen: CountTable[string]

proc listed(field, entry: string): bool =
  if entry.endsWith("*"): field.startsWith(entry[0 ..< ^1])
  else: field == entry or field.startsWith(entry & ".")

proc allowed(field: string): bool =
  for (f, _) in LoadScratch:
    if listed(field, f): return true

proc hygiene[T](label: string; make: proc(): T; frames: int; seed: uint64;
                poke: proc(e: T; seed: uint64; frame: int) {.nimcall.}) =
  let emu = make()
  var next = HygieneEvery[0]
  var checks = 0
  var bad: seq[string]
  try:
    for f in 0 ..< frames:
      if poke != nil: poke(emu, seed, f)
      emu.step_frame()
      if f + 1 < next: continue
      inc checks
      next = f + 1 + HygieneEvery[checks mod HygieneEvery.len]
      let p = emu.state_payload()
      let twin = make()
      twin.apply_state_payload(p)
      emu.apply_state_payload(p)
      for field in state_diff(emu, twin):
        all_seen.inc(field)
        if allowed(field):
          if field notin allowed_seen: allowed_seen.add(field)
        elif field notin bad:
          bad.add(field)
          echo &"    {label}: after frame {f}, {field} differs from a new core's"
  except CatchableError, Defect:
    let e = getCurrentException()
    fail(&"{label}: {e.name}: {e.msg}")
    return
  if bad.len > 0:
    fail(&"{label}: {bad.len} field(s) a load leaves as they were: {bad.join(\", \")}")
  else:
    echo &"  [PASS] {label}: {checks} loads"

when isMainModule:
  if paramCount() >= 1: only = paramStr(1)
  let tmp = getTempDir() / &"dingbat_state_hygiene_{getCurrentProcessId()}"
  createDir(tmp)
  let t_start = epochTime()

  let roms_dir = currentSourcePath().parentDir / "roms"
  var roms: seq[string]
  for path in walkDirRec(roms_dir):
    let ext = path.splitFile().ext.toLowerAscii()
    if ext in [".gb", ".gbc", ".gba"]: roms.add(path)
  doAssert roms.len > 0, "no ROMs under " & roms_dir
  for i, path in roms:
    let rel = path.relativePath(roms_dir).replace('\\', '/')
    let label = "rom " & rel
    if not wanted(label): continue
    let copy = tmp / &"{i}_{path.extractFilename()}"
    copyFile(path, copy)
    if path.splitFile().ext.toLowerAscii() == ".gba":
      hygiene(label, gba_maker(copy), HygieneRomFrames, fnv(rel), nil)
    else:
      hygiene(label, gb_maker(copy), HygieneRomFrames, fnv(rel), nil)

  for seed in [0x6B01'u64, 0x6B02, 0x6B03]:
    for cgb in [false, true]:
      let label = &"random gb {(if cgb: \"cgb\" else: \"dmg\")} {seed:#x}"
      if not wanted(label): continue
      let path = tmp / &"random_{seed:x}_{ord(cgb)}.gb"
      writeFile(path, gb_program(seed, cgb))
      hygiene(label, gb_maker(path), HygieneRandomFrames, seed, gb_harness_poke)

  for seed in [0xA901'u64, 0xA902, 0xA903]:
    let label = &"random gba {seed:#x}"
    if not wanted(label): continue
    let path = tmp / &"random_{seed:x}.gba"
    writeFile(path, gba_program(seed))
    hygiene(label, gba_maker(path), HygieneRandomFrames, seed, gba_harness_poke)

  try: removeDir(tmp)
  except OSError: discard

  if list_all:
    echo "every field that differed (loads):"
    all_seen.sort()
    for k, v in all_seen: echo &"  {v:5} {k}"
  for (f, _) in LoadScratch:
    if not allowed_seen.anyIt(listed(it, f)):
      echo &"  note: {f} is listed in LoadScratch but never differed"
  echo &"state hygiene: {epochTime() - t_start:.1f}s"
  if failures == 0: echo "ALL STATE HYGIENE CHECKS PASS"
  else:
    echo failures, " FAILURE(S)"
    quit(1)
