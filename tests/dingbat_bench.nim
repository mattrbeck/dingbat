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
  else:
    let emu = new_gb("", rom_path, fifo = true, headless = true, run_bios = false)
    emu.test_output = test_out
    emu.post_init()
    for _ in 0 ..< warmup: emu.step_frame()
    let start = getMonoTime()
    for _ in 0 ..< frames: emu.step_frame()
    let elapsed = (getMonoTime() - start).inNanoseconds.float / 1e9
    echo rom_path.splitFile().name, ": ", frames, " frames in ",
         formatFloat(elapsed, ffDecimal, 3), "s = ",
         formatFloat(frames.float / elapsed, ffDecimal, 1), " fps (",
         formatFloat(frames.float / elapsed / 59.7275, ffDecimal, 2), "x realtime)"

main()
