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

type InputEvent = tuple[frame: int, key: Input, pressed: bool]

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
    # DINGBAT_BENCH_STATE loads a .state image before the warmup, so a
    # benchmark can measure a specific in-game scene (a busy overworld or
    # battle) instead of whatever the boot intro happens to be showing. The
    # image must come from the same ROM — load_state_bytes rejects mismatches.
    let state_path = getEnv("DINGBAT_BENCH_STATE")
    if state_path.len > 0:
      if not emu.load_state_bytes(readFile(state_path)):
        echo "bench: state load REJECTED (ROM/version mismatch): ", state_path
        quit(1)
    if getEnv("DINGBAT_MP2K") == "1":
      emu.mp2k_hle = true
    if getEnv("DINGBAT_MP2K_SKIP") == "1":
      emu.mp2k_hle = true
      emu.mp2k.skip = true
    if getEnv("DINGBAT_MP2K_DUMP") == "1":
      # EXPLORATORY: verify MP2K detection + SoundInfo reading. Detection is
      # runtime-learned (mp2k.nim), so hook_addr stays 0xFFFFFFFF until the
      # engine's first mixer pass; the post-run summary prints the final value.
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
    let dump_frame = getEnv("DINGBAT_BENCH_DUMP")
    if dump_frame.len > 0:
      for f in 0 .. parseInt(dump_frame): run_scripted(f)
      let fh = open(getEnv("DINGBAT_BENCH_DUMP_PATH", "/tmp/fb.bin"), fmWrite)
      discard fh.writeBuffer(addr emu.ppu.framebuffer[0], emu.ppu.framebuffer.len * 2)
      fh.close()
      return
    for f in 0 ..< warmup: run_scripted(f)
    let start = getMonoTime()
    for i in 0 ..< frames: run_scripted(warmup + i)
    let elapsed = (getMonoTime() - start).inNanoseconds.float / 1e9
    echo rom_path.splitFile().name, ": ", frames, " frames in ",
         formatFloat(elapsed, ffDecimal, 3), "s = ",
         formatFloat(frames.float / elapsed, ffDecimal, 1), " fps (",
         formatFloat(frames.float / elapsed / 59.7275, ffDecimal, 2), "x realtime)"
    if emu.mp2k != nil and emu.mp2k_hle:
      echo "  mp2k: entry=0x", toHex(emu.mp2k.entry_addr, 8),
           " hook=0x", toHex(emu.mp2k.hook_addr, 8),
           " skip_fires=", emu.mp2k.dbg_skip_fires,
           " hook_fires=", emu.mp2k.dbg_hook_fires,
           " engaged=", emu.mp2k.engaged,
           " avg_out_energy=", (if emu.mp2k.dbg_out_count > 0:
             formatFloat(emu.mp2k.dbg_out_energy / emu.mp2k.dbg_out_count.float, ffDecimal, 4) else: "0")
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
    # DINGBAT_BENCH_RENDERER selects the GB pixel pipeline: "fifo" (the
    # shipping default, per-dot) or "scanline" (per-line). Anything else is
    # rejected rather than silently falling back, so a typo can't quietly
    # benchmark the wrong renderer.
    let renderer = getEnv("DINGBAT_BENCH_RENDERER", "fifo")
    if renderer notin ["fifo", "scanline"]:
      echo "bench: DINGBAT_BENCH_RENDERER must be fifo or scanline, got: ", renderer
      quit(1)
    let emu = new_gb("", rom_path, fifo = renderer == "fifo",
                     headless = true, run_bios = false)
    emu.test_output = test_out
    emu.post_init()
    # As on the GBA path: load an in-game scene rather than measuring whatever
    # the boot intro happens to be showing. A title screen exercises almost
    # none of the PPU or CPU that gameplay does.
    let state_path = getEnv("DINGBAT_BENCH_STATE")
    if state_path.len > 0:
      if not emu.load_state_bytes(readFile(state_path)):
        echo "bench: state load REJECTED (ROM/version mismatch): ", state_path
        quit(1)

    # The GB core emits frames while the LCD is off (see lcd_off_frame), so a
    # fixed frame count is NOT a fixed amount of work: a build that changes
    # frame-emission behaviour does different work for the same frame count.
    # Stepping the frame by hand (rather than through step_frame) lets the
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
      # APU channels up and moves their deadlines with the events, which is
      # what step_frame does. Calling the raw scheduler rebase here would
      # leave the channel deadlines pointing at pre-rebase cycles.
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
    let dump_frame = getEnv("DINGBAT_BENCH_DUMP")
    if dump_frame.len > 0:
      for f in 0 .. parseInt(dump_frame): run_scripted(f)
      let fh = open(getEnv("DINGBAT_BENCH_DUMP_PATH", "/tmp/fb.bin"), fmWrite)
      discard fh.writeBuffer(addr emu.ppu.framebuffer[0], emu.ppu.framebuffer.len * 2)
      fh.close()
      return

    for f in 0 ..< warmup: run_scripted(f)
    total_cycles = 0
    let start = getMonoTime()
    for i in 0 ..< frames: run_scripted(warmup + i)
    let elapsed = (getMonoTime() - start).inNanoseconds.float / 1e9
    echo rom_path.splitFile().name, ": ", frames, " frames in ",
         formatFloat(elapsed, ffDecimal, 3), "s = ",
         formatFloat(frames.float / elapsed, ffDecimal, 1), " fps (",
         formatFloat(frames.float / elapsed / 59.7275, ffDecimal, 2), "x realtime)"
    echo "  cycles=", total_cycles, " mcps=",
         formatFloat(total_cycles.float / elapsed / 1e6, ffDecimal, 2)

main()
