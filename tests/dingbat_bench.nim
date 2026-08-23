## Headless benchmark harness: run a ROM for N frames and report wall time.
## Build: nim c -d:test_harness -d:release --path:src -o:dingbat_bench tests/dingbat_bench.nim
## Usage: dingbat_bench <rom> [frames] [warmup_frames] [input_script]
##
## input_script drives the keypad so a benchmark can navigate menus into real
## gameplay and then play during the measured window, e.g.
## "600:START,700:A,900:RIGHT:120". Each entry presses the key at that frame
## and releases it 10 frames later, or after an optional hold duration.

import std/[os, strutils, times, monotimes]
import dingbat/gb/gb
import dingbat/gba/gba
import dingbat/common/input
import dingbat/common/test_output
import dingbat/common/rewind
import dingbat/common/scheduler
import dingbat/common/serialize
import dingbat/common/lcd_response

type InputEvent = tuple[frame: int, key: Input, pressed: bool]

# ---- Frame-sequence dump (DINGBAT_BENCH_DUMP_SEQ=<first>:<count>) ----
# Writes `count` consecutive framebuffers to DUMP_PATH as one file (an
# alternate-frame flicker cannot be judged from one screenshot).
# DINGBAT_BENCH_LCD=<off|on|dmg|cgb|agb|ags> runs them through the shipping
# panel model; the four panel names force one panel regardless of machine.
type SeqDump = object
  first, count: int
  fh: File
  open: bool
  lcd: LcdResponse

proc seq_dump_init(gba: bool; cgb: bool; sgb = false): SeqDump =
  let spec = getEnv("DINGBAT_BENCH_DUMP_SEQ")
  if spec.len == 0: return
  let parts = spec.split(':')
  result.first = parseInt(parts[0])
  result.count = if parts.len > 1: parseInt(parts[1]) else: 1
  result.fh = open(getEnv("DINGBAT_BENCH_DUMP_PATH", "/tmp/fbseq.bin"), fmWrite)
  result.open = true
  result.lcd.set_panel(
    parse_panel(getEnv("DINGBAT_BENCH_LCD", "off"), gba, cgb, sgb))

proc seq_dump_tick(d: var SeqDump; frame: int; fb: var seq[uint16]) =
  ## Called for EVERY frame, not just the dumped ones: the panel has to settle
  ## through the run-up or the first dumped frame would be freshly seeded and
  ## show no response at all.
  if d.count == 0: return
  let p = d.lcd.apply(cast[ptr UncheckedArray[uint16]](addr fb[0]), fb.len)
  if not d.open or frame < d.first or frame >= d.first + d.count: return
  discard d.fh.writeBuffer(p, fb.len * 2)
  if frame == d.first + d.count - 1:
    d.fh.close()
    d.open = false

proc seq_dump_done(d: SeqDump): bool =
  d.count > 0 and not d.open

proc parse_script(script: string): seq[InputEvent] =
  for entry in script.split(','):
    if entry.len == 0: continue
    let parts = entry.split(':')
    let frame = parseInt(parts[0])
    let key = parseEnum[Input](parts[1].toUpperAscii())
    let hold = if parts.len > 2: parseInt(parts[2]) else: 10
    result.add((frame, key, true))
    result.add((frame + hold, key, false))

# With DINGBAT_BENCH_HASH=1, print a rolling FNV-1a hash of the framebuffer
# after every frame, for pixel-exact A/B comparison between builds.
proc fnv(h: uint64; buf: seq[uint16]): uint64 =
  result = h
  for v in buf:
    result = (result xor uint64(v)) * 0x100000001B3'u64

# ---- Hardware counters (macOS) ----
# Wall-clock fps cannot resolve a percent-level A/B: two builds differing
# only in code the ROM never executes measure ~1.3% apart from link layout.
# Instructions-retired counts work done, not where it lives.
# proc_pid_rusage(RUSAGE_INFO_V4) exposes the retired-instruction and cycle
# counters for the calling process without root or Xcode. Sampled around
# the measured window only. DINGBAT_BENCH_COUNTERS=1 turns the line on.
when defined(macosx):
  proc proc_pid_rusage(pid: cint; flavor: cint; buf: pointer): cint
    {.importc, header: "<libproc.h>".}

  proc getpid(): cint {.importc, header: "<unistd.h>".}

  # RUSAGE_INFO_V4 is 296 bytes / 37 u64 slots; ri_instructions and ri_cycles
  # are slots 31 and 32 (`offsetof(struct rusage_info_v4, ri_instructions)/8`).
  # Read as raw u64s so nothing here tracks the rest of <sys/resource.h>.
  const RiInstructionsSlot = 31
  const RiCyclesSlot = 32

  proc hw_counters(): (uint64, uint64) =
    ## (instructions, cycles) retired by this process so far, or (0, 0) if the
    ## kernel declines the request.
    var raw: array[0 .. 63, uint64]
    if proc_pid_rusage(getpid(), 4, addr raw[0]) != 0: return (0'u64, 0'u64)
    (raw[RiInstructionsSlot], raw[RiCyclesSlot])
else:
  proc hw_counters(): (uint64, uint64) = (0'u64, 0'u64)


# ---- Rewind capture cost ----
# DINGBAT_BENCH_REWIND selects what the frontends do:
#   off     no ring (the baseline)
#   native  maybe_push(payload): src/dingbat.nim passes no thumbnail proc
#   web     maybe_push(payload, thumb): src/dingbat_wasm.nim does
# DINGBAT_BENCH_REWIND_CAP overrides the ring cap in bytes (web: 16 MB on
# iOS, 64 MB elsewhere); DINGBAT_BENCH_REWIND_INTERVAL the snapshot interval.
const SCRUB_THUMB_W = 120
const GBA_SCRUB_THUMB_H = SCRUB_THUMB_W * 160 div 240
const GB_SCRUB_THUMB_H = SCRUB_THUMB_W * 144 div 160

proc rewind_mode(): string = getEnv("DINGBAT_BENCH_REWIND", "off")

proc make_bench_rewind(): Rewind =
  if rewind_mode() == "off": return nil
  let cap = parseInt(getEnv("DINGBAT_BENCH_REWIND_CAP", $REWIND_CAP_BYTES))
  let iv  = parseInt(getEnv("DINGBAT_BENCH_REWIND_INTERVAL", $REWIND_INTERVAL))
  new_rewind(cap, iv)

proc report_rewind(rw: Rewind; frames: int; elapsed: float) =
  if rw == nil: return
  let (d, l, t, k) = rw.mem_breakdown()
  echo "  rewind[", rewind_mode(), "]: snapshots=", rw.len,
       " mem=", formatFloat(rw.mem_used().float / 1048576.0, ffDecimal, 2), " MB",
       " (deltas ", formatFloat(d.float / 1048576.0, ffDecimal, 2),
       " latest ", formatFloat(l.float / 1048576.0, ffDecimal, 2),
       " thumbs ", formatFloat(t.float / 1048576.0, ffDecimal, 2),
       " keys ", formatFloat(k.float / 1048576.0, ffDecimal, 2), ")"
  when defined(rewindprof):
    let names = ["serialize", "xor", "compress", "thumb_grab", "thumb_zlib",
                 "key_zlib", "evict", "PUSH TOTAL", "pops"]
    let pushes = rewindprof_n[7]
    echo "  --- rewind profile over ", frames, " frames (", pushes, " pushes) ---"
    for i, n in names:
      if rewindprof_n[i] == 0 and rewindprof[i] == 0: continue
      let ms = rewindprof[i].float / 1e6
      echo "    ", n.alignLeft(11), " calls=", align($rewindprof_n[i], 6),
           "  total=", align(formatFloat(ms, ffDecimal, 2), 8), " ms",
           "  per_push=", align(formatFloat(if pushes > 0: ms / pushes.float else: 0.0, ffDecimal, 4), 8), " ms",
           "  per_frame=", align(formatFloat(ms / frames.float, ffDecimal, 4), 8), " ms",
           "  share_of_run=", formatFloat(ms / (elapsed * 1000.0) * 100.0, ffDecimal, 2), "%"
    echo "    payload bytes/push=", (if pushes > 0: rewindprof_bytes[0] div pushes else: 0),
         "  delta bytes/push=", (if pushes > 0: rewindprof_bytes[2] div pushes else: 0)

proc main() =
  let args = commandLineParams()
  if args.len < 1:
    echo "Usage: dingbat_bench <rom> [frames] [warmup]"
    quit(1)
  let rom_path = args[0]
  let frames = if args.len > 1: parseInt(args[1]) else: 600
  let warmup = if args.len > 2: parseInt(args[2]) else: 120
  let script = if args.len > 3: parse_script(args[3]) else: @[]

  let ext = rom_path.splitFile().ext.toLowerAscii()
  let test_out = new_test_output()

  if ext in [".gba", ".bin"]:
    # DINGBAT_BENCH_BIOS points at a real BIOS image; default is HLE
    let bios = getEnv("DINGBAT_BENCH_BIOS")
    let emu = new_gba(bios, rom_path, run_bios = false, use_hle = bios.len == 0)
    emu.test_output = test_out
    emu.post_init()
    # DINGBAT_BENCH_STATE loads a .state image before the warmup, to measure
    # a specific in-game scene; it must come from the same ROM.
    let state_path = getEnv("DINGBAT_BENCH_STATE")
    if state_path.len > 0:
      if not emu.load_state_bytes(readFile(state_path)):
        echo "bench: state load REJECTED (ROM/version mismatch): ", state_path
        quit(1)
    # DINGBAT_NO_WAITLOOP=1 turns off idle-loop fast-forwarding, which snaps
    # scheduler.cycles to the next pending event and so moves emulated timing
    # when a change only REMOVES scheduler events. Set it on both builds to
    # A/B a scheduler change.
    if getEnv("DINGBAT_NO_WAITLOOP") == "1":
      emu.cpu.attempt_waitloop_detection = false
    # Speed-mode knobs, for bucket-by-bucket A/B measurement
    if getEnv("DINGBAT_BENCH_FRAMESKIP").len > 0:
      emu.ppu.frameskip = parseInt(getEnv("DINGBAT_BENCH_FRAMESKIP"))
    if getEnv("DINGBAT_BENCH_UNDERCLOCK").len > 0:
      emu.set_underclock(parseInt(getEnv("DINGBAT_BENCH_UNDERCLOCK")))
    if getEnv("DINGBAT_MP2K") == "1":
      emu.mp2k_hle = true
    if getEnv("DINGBAT_MP2K_SKIP") == "1":
      emu.mp2k_hle = true
      emu.mp2k.skip = true
    if getEnv("DINGBAT_MP2K_DUMP") == "1":
      # Exploratory: MP2K detection + SoundInfo dump. Detection is
      # runtime-learned (mp2k.nim), so hook_addr stays 0xFFFFFFFF until the
      # engine's first mixer pass.
      emu.mp2k_hle = true
      for f in 0 ..< warmup:
        for ev in script:
          if ev.frame == f: emu.handle_input(ev.key, ev.pressed)
        emu.step_frame()
      var proc_bytes = "SoundMainRAM prologue @entry: "
      for k in 0'u32 ..< 12'u32:
        proc_bytes.add toHex(emu.bus.read_half_internal(emu.mp2k.entry_addr + k*2), 4) & " "
      echo proc_bytes
      let sip = emu.bus.read_word_internal(0x03007FF0'u32)
      echo "SoundInfo ptr @03007FF0 = 0x", toHex(sip, 8)
      if (sip shr 24) != 0:
        let magic = emu.bus.read_word_internal(sip)
        echo "  magic = 0x", toHex(magic, 8), "  (ok=", magic == 0x68736D54'u32, ")"
        echo "  maxChans=", emu.bus.read_byte_internal(sip + 6),
             " masterVol=", emu.bus.read_byte_internal(sip + 7)
        echo "  engaged=", emu.mp2k.engaged, " compressed_skipped=", emu.mp2k.compressed_skipped
        var active = 0
        for i in 0 ..< 12:
          let cb = sip + 0x50'u32 + uint32(i) * 64
          let status = emu.bus.read_byte_internal(cb)
          if (status and 0xC7'u8) != 0:
            active.inc
            let wave = emu.bus.read_word_internal(cb + 0x24)
            echo "  ch", i, " status=0x", toHex(status, 2),
                 " type=0x", toHex(emu.bus.read_byte_internal(cb + 1), 2),
                 " envVol=", emu.bus.read_byte_internal(cb + 9),
                 " freq=", emu.bus.read_word_internal(cb + 0x20),
                 " wave=0x", toHex(wave, 8)
        echo "  active channels = ", active
      return
    if getEnv("DINGBAT_BENCH_HASH") == "1":
      var h = 0xCBF29CE484222325'u64
      for f in 0 ..< warmup + frames:
        for ev in script:
          if ev.frame == f: emu.handle_input(ev.key, ev.pressed)
        emu.step_frame()
        h = fnv(h, emu.ppu.framebuffer)
        echo f, " ", toHex(h)
      return
    template run_scripted(f: int) =
      for ev in script:
        if ev.frame == f: emu.handle_input(ev.key, ev.pressed)
      emu.step_frame()
    var sq = seq_dump_init(gba = true, cgb = false)
    if sq.count > 0:
      var f = 0
      while not sq.seq_dump_done() and f < 1_000_000:
        run_scripted(f)
        sq.seq_dump_tick(f, emu.ppu.framebuffer)
        f.inc
      echo "bench: dumped ", sq.count, " frames from ", sq.first
      return
    let dump_frame = getEnv("DINGBAT_BENCH_DUMP")
    if dump_frame.len > 0:
      for f in 0 .. parseInt(dump_frame): run_scripted(f)
      let fh = open(getEnv("DINGBAT_BENCH_DUMP_PATH", "/tmp/fb.bin"), fmWrite)
      discard fh.writeBuffer(addr emu.ppu.framebuffer[0], emu.ppu.framebuffer.len * 2)
      fh.close()
      return
    for f in 0 ..< warmup: run_scripted(f)
    let rw = make_bench_rewind()
    let mode = rewind_mode()
    template rewind_tick() =
      if rw != nil:
        if mode == "web":
          discard rw.maybe_push(
            proc(): string = emu.state_payload(),
            proc(): RewindThumb =
              RewindThumb(w: SCRUB_THUMB_W, h: GBA_SCRUB_THUMB_H,
                          pixels: downscale_bgr555(emu.ppu.framebuffer, 240, 160,
                                                   SCRUB_THUMB_W, GBA_SCRUB_THUMB_H)))
        else:
          discard rw.maybe_push(proc(): string = emu.state_payload())
    let (ins0, cyc0) = hw_counters()
    let start = getMonoTime()
    for i in 0 ..< frames:
      run_scripted(warmup + i)
      rewind_tick()
    let elapsed = (getMonoTime() - start).inNanoseconds.float / 1e9
    let (ins1, cyc1) = hw_counters()
    echo rom_path.splitFile().name, ": ", frames, " frames in ",
         formatFloat(elapsed, ffDecimal, 3), "s = ",
         formatFloat(frames.float / elapsed, ffDecimal, 1), " fps (",
         formatFloat(frames.float / elapsed / 59.7275, ffDecimal, 2), "x realtime)"
    if getEnv("DINGBAT_BENCH_COUNTERS") == "1":
      echo "  instructions=", ins1 - ins0, " hwcycles=", cyc1 - cyc0
    report_rewind(rw, frames, elapsed)
    # DINGBAT_BENCH_REWIND_VERIFY=1: pop every retained snapshot, apply it to
    # the live core, re-serialize and require the bytes back; covers the
    # codec, the delta chain and the core's load path on a real game.
    if rw != nil and getEnv("DINGBAT_BENCH_REWIND_VERIFY") == "1":
      var checked = 0
      var bad = 0
      while true:
        let snap = rw.pop()
        if snap.len == 0: break
        emu.apply_state_payload(snap)
        if emu.state_payload() != snap: bad.inc
        checked.inc
      echo "  rewind verify: ", checked, " snapshots restored, ", bad, " mismatches",
           (if bad == 0: "  OK" else: "  *** FAILED ***")
    if emu.mp2k != nil and emu.mp2k_hle:
      echo "  mp2k: entry=0x", toHex(emu.mp2k.entry_addr, 8),
           " hook=0x", toHex(emu.mp2k.hook_addr, 8),
           " skip_fires=", emu.mp2k.dbg_skip_fires,
           " hook_fires=", emu.mp2k.dbg_hook_fires,
           " engaged=", emu.mp2k.engaged,
           " avg_out_energy=", (if emu.mp2k.dbg_out_count > 0:
             formatFloat(emu.mp2k.dbg_out_energy / emu.mp2k.dbg_out_count.float, ffDecimal, 4) else: "0")
    when defined(fetchprof):
      let names = ["fh_hot", "fh_slow", "fw_hot", "fw_slow", "rac_fetch", "rac_data",
                   "rac_pfhit", "rac_seq", "rac_nonseq", "rac_went_hot",
                   "rac_pfhit_full", "rac_pfhit_nocredit"]
      echo "--- fetch profile (per ", frames, " frames) ---"
      for i, n in names:
        echo n, ": ", gba.fetchprof[i]
    when defined(pcprofile):
      var tot = 0'u64
      for r in 0..15: tot += gba.prof_cycles[r]
      let names = ["BIOS", "unused", "EWRAM", "IWRAM", "MMIO", "PRAM", "VRAM", "OAM",
                   "ROM0", "ROM0h", "ROM1", "ROM1h", "ROM2", "ROM2h", "SRAM", "SRAMh"]
      echo "--- PC cycle profile (region: cycles, %) ---"
      for r in 0..15:
        if gba.prof_cycles[r] > 0:
          echo names[r], ": ", gba.prof_cycles[r], "  ",
            formatFloat(gba.prof_cycles[r].float * 100.0 / tot.float, ffDecimal, 2), "%"
      echo "--- IWRAM per-1KB (addr: cycles, % of total) ---"
      for b in 0..31:
        if gba.prof_iwram[b] > 0:
          echo toHex(0x03000000'u32 + uint32(b) * 1024, 8), ": ", gba.prof_iwram[b], "  ",
            formatFloat(gba.prof_iwram[b].float * 100.0 / tot.float, ffDecimal, 2), "%"
  else:
    # DINGBAT_BENCH_RENDERER: "fifo" (the shipping per-dot default) or
    # "scanline". Anything else is rejected rather than silently falling back.
    let renderer = getEnv("DINGBAT_BENCH_RENDERER", "fifo")
    if renderer notin ["fifo", "scanline"]:
      echo "bench: DINGBAT_BENCH_RENDERER must be fifo or scanline, got: ", renderer
      quit(1)
    let emu = new_gb("", rom_path, fifo = renderer == "fifo",
                     headless = true, run_bios = false)
    emu.test_output = test_out
    emu.post_init()
    # As on the GBA path: load an in-game scene; a title screen exercises
    # almost none of the PPU or CPU that gameplay does.
    let state_path = getEnv("DINGBAT_BENCH_STATE")
    if state_path.len > 0:
      if not emu.load_state_bytes(readFile(state_path)):
        echo "bench: state load REJECTED (ROM/version mismatch): ", state_path
        quit(1)
    # Speed-mode knob (scanline renderer only — the FIFO PPU ignores it)
    if getEnv("DINGBAT_BENCH_FRAMESKIP").len > 0:
      emu.ppu.frameskip = parseInt(getEnv("DINGBAT_BENCH_FRAMESKIP"))

    # The GB core emits frames while the LCD is off (lcd_off_frame), so a fixed
    # frame count is not a fixed amount of work. Stepping by hand lets the
    # rebase return value be summed into an exact emulated-cycle total, which
    # IS comparable across builds.
    var total_cycles = 0'u64
    template run_scripted(f: int) =
      for ev in script:
        if ev.frame == f: emu.handle_input(ev.key, ev.pressed)
      emu.apply_cheats()
      while not emu.ppu.frame:
        emu.cpu.tick(emu)
      emu.ppu.frame = false
      # gb_rebase, not scheduler.rebase: it also catches the lazily-advanced
      # APU channels up and moves their deadlines with the events, as
      # step_frame does.
      total_cycles += uint64(emu.gb_rebase())

    if getEnv("DINGBAT_BENCH_HASH") == "1":
      var h = 0xCBF29CE484222325'u64
      for f in 0 ..< warmup + frames:
        run_scripted(f)
        h = fnv(h, emu.ppu.framebuffer)
        echo f, " ", toHex(h)
      return
    # Writes a .state after the warmup, so a scripted run can manufacture the
    # in-game scene that later runs load with DINGBAT_BENCH_STATE.
    let save_path = getEnv("DINGBAT_BENCH_SAVESTATE")
    if save_path.len > 0:
      for f in 0 ..< warmup: run_scripted(f)
      if not emu.save_state(save_path): quit(1)
      echo "bench: wrote state after ", warmup, " frames: ", save_path
      return
    var sq = seq_dump_init(gba = false, cgb = emu.cgb_enabled,
                           sgb = emu.sgb_active())
    if sq.count > 0:
      var f = 0
      while not sq.seq_dump_done() and f < 1_000_000:
        run_scripted(f)
        sq.seq_dump_tick(f, emu.ppu.framebuffer)
        f.inc
      echo "bench: dumped ", sq.count, " frames from ", sq.first
      return
    let dump_frame = getEnv("DINGBAT_BENCH_DUMP")
    if dump_frame.len > 0:
      for f in 0 .. parseInt(dump_frame): run_scripted(f)
      let fh = open(getEnv("DINGBAT_BENCH_DUMP_PATH", "/tmp/fb.bin"), fmWrite)
      discard fh.writeBuffer(addr emu.ppu.framebuffer[0], emu.ppu.framebuffer.len * 2)
      fh.close()
      return

    for f in 0 ..< warmup: run_scripted(f)
    let rw = make_bench_rewind()
    let mode = rewind_mode()
    template rewind_tick() =
      if rw != nil:
        if mode == "web":
          discard rw.maybe_push(
            proc(): string = emu.state_payload(),
            proc(): RewindThumb =
              RewindThumb(w: SCRUB_THUMB_W, h: GB_SCRUB_THUMB_H,
                          pixels: downscale_bgr555(emu.ppu.framebuffer, 160, 144,
                                                   SCRUB_THUMB_W, GB_SCRUB_THUMB_H)))
        else:
          discard rw.maybe_push(proc(): string = emu.state_payload())
    total_cycles = 0
    let (ins0, cyc0) = hw_counters()
    let start = getMonoTime()
    for i in 0 ..< frames:
      run_scripted(warmup + i)
      rewind_tick()
    let elapsed = (getMonoTime() - start).inNanoseconds.float / 1e9
    let (ins1, cyc1) = hw_counters()
    echo rom_path.splitFile().name, ": ", frames, " frames in ",
         formatFloat(elapsed, ffDecimal, 3), "s = ",
         formatFloat(frames.float / elapsed, ffDecimal, 1), " fps (",
         formatFloat(frames.float / elapsed / 59.7275, ffDecimal, 2), "x realtime)"
    report_rewind(rw, frames, elapsed)
    if rw != nil and getEnv("DINGBAT_BENCH_REWIND_VERIFY") == "1":
      var checked = 0
      var bad = 0
      while true:
        let snap = rw.pop()
        if snap.len == 0: break
        emu.apply_state_payload(snap)
        if emu.state_payload() != snap: bad.inc
        checked.inc
      echo "  rewind verify: ", checked, " snapshots restored, ", bad, " mismatches",
           (if bad == 0: "  OK" else: "  *** FAILED ***")
    echo "  cycles=", total_cycles, " mcps=",
         formatFloat(total_cycles.float / elapsed / 1e6, ffDecimal, 2)
    # Emulated cycles are the "same work?" check; instructions are the
    # layout-immune cost measure. A/B is only meaningful when cycles match.
    if getEnv("DINGBAT_BENCH_COUNTERS") == "1":
      echo "  instructions=", ins1 - ins0, " hwcycles=", cyc1 - cyc0,
           " ins_per_emucycle=",
           formatFloat((ins1 - ins0).float / total_cycles.float, ffDecimal, 5)

main()
