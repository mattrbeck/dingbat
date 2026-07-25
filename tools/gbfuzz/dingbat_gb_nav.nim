## Headless dingbat GB/GBC runner for cross-emulator screenshot comparison.
## Same CLI contract as sameboy_runner.c / mgba_gb_runner.c, plus save states.
##
## Usage: dingbat_gb_nav <rom.gb> <bootromdir|none> <outprefix> <script> <shots>
##                       [--state] [--scanline]
##   script: comma-separated FRAME:KEY[:HOLD] ("" for none)
##   shots:  comma-separated frames; writes <outprefix>.f<frame>.ppm
##   --state:    also save_state to <outprefix>.f<frame>.state at each shot
##   --scanline: use the scanline PPU (default is the FIFO PPU, which is what
##               the native and web frontends ship)
##
## Build: nim c -d:release --path:src -o:tools/gbfuzz/dingbat_gb_nav \
##            tools/gbfuzz/dingbat_gb_nav.nim

import std/[os, strutils, strformat]
import dingbat/gb/gb
import dingbat/common/input

type InputEvent = tuple[frame: int, key: Input, pressed: bool]

# Shared four-shade DMG ramp (see the C runners): dingbat renders DMG through
# a green LCD palette, SameBoy and mGBA through their own, so every runner
# normalises to one ramp and DMG titles can be compared byte-for-byte.
const GREY4 = [0xFF'u8, 0xAD'u8, 0x52'u8, 0x00'u8]

proc parse_script(script: string): seq[InputEvent] =
  for entry in script.split(','):
    if entry.len == 0: continue
    let parts = entry.split(':')
    let frame = parseInt(parts[0])
    let key = parseEnum[Input](parts[1].toUpperAscii())
    let hold = if parts.len > 2: parseInt(parts[2]) else: 10
    result.add((frame, key, true))
    result.add((frame + hold, key, false))

proc write_ppm(path: string; buf: seq[uint16]; dmg: bool) =
  var f = open(path, fmWrite)
  f.write("P6\n160 144\n255\n")
  for pixel in buf:
    if dmg:
      # In DMG mode the palette RAM only ever holds DMG_COLORS, so the shade
      # index is recoverable. An unknown value means the PPU wrote a colour it
      # should not have — fall through to the generic path so it shows up as a
      # difference rather than being silently quantised away.
      var shade = -1
      for i, c in DMG_COLORS:
        if c == pixel: shade = i; break
      if shade >= 0:
        let v = char(GREY4[shade])
        f.write(v); f.write(v); f.write(v)
        continue
    let r5 = pixel and 0x1F
    let g5 = (pixel shr 5) and 0x1F
    let b5 = (pixel shr 10) and 0x1F
    f.write(char(uint8((r5 shl 3) or (r5 shr 2))))
    f.write(char(uint8((g5 shl 3) or (g5 shr 2))))
    f.write(char(uint8((b5 shl 3) or (b5 shr 2))))
  f.close()

proc write_dump(path: string; emu: GB) =
  ## Companion to the SameBoy runner's GBFUZZ_DUMP: the PPU-visible memory
  ## behind a shot, in the same layout, so the two can be diffed directly.
  var f = open(path, fmWrite)
  discard f.writeBuffer(unsafeAddr emu.ppu.sprite_table[0], emu.ppu.sprite_table.len)
  for bank in 0 .. 1:
    discard f.writeBuffer(unsafeAddr emu.ppu.vram[bank][0], emu.ppu.vram[bank].len)
  discard f.writeBuffer(unsafeAddr emu.ppu.pram[0], emu.ppu.pram.len)
  discard f.writeBuffer(unsafeAddr emu.ppu.obj_pram[0], emu.ppu.obj_pram.len)
  # Work RAM and HRAM too — see the SameBoy runner: this is where a CPU-level
  # divergence shows up before it reaches VRAM.
  for bank in 0 .. 7:
    discard f.writeBuffer(unsafeAddr emu.memory.wram[bank][0], emu.memory.wram[bank].len)
  discard f.writeBuffer(unsafeAddr emu.memory.hram[0], emu.memory.hram.len)
  f.close()

proc main() =
  let args = commandLineParams()
  if args.len < 5:
    echo "Usage: dingbat_gb_nav <rom> <bootromdir|none> <outprefix> <script> <shots> " &
         "[--state] [--scanline]"
    quit(2)
  let rom_path = args[0]
  let bootdir = args[1]
  let prefix = args[2]
  let script = parse_script(args[3])
  var shots: seq[int]
  for tok in args[4].split(','):
    if tok.len > 0: shots.add(parseInt(tok))
  let flags = args[5 .. ^1]
  let want_state = "--state" in flags
  # GBFUZZ_SCANLINE runs the whole sweep on the scanline renderer, to
  # separate renderer bugs from core bugs.
  let fifo = "--scanline" notin flags and getEnv("GBFUZZ_SCANLINE") == ""

  # All three runners play the boot ROM out of <bootromdir> by default and
  # count frame 0 from power-on, so no emulator's skip-boot shortcut can show
  # up as animation-phase drift. GBFUZZ_SKIP_BIOS=1 selects dingbat's shipping
  # default instead (calibrated post-boot state, no boot ROM).
  let run_bios = getEnv("GBFUZZ_SKIP_BIOS") == "" and bootdir != "none"
  var bootrom = ""
  if run_bios:
    # 0x143 bit 7 picks the model, exactly as the other two runners do.
    var hdr = newSeq[uint8](0x150)
    let fh = open(rom_path, fmRead)
    discard fh.readBuffer(addr hdr[0], hdr.len)
    fh.close()
    bootrom = bootdir / (if (hdr[0x143] and 0x80) != 0: "cgb_boot.bin" else: "dmg_boot.bin")

  let emu = new_gb(bootrom, rom_path, fifo = fifo, headless = true,
                   run_bios = run_bios)
  emu.post_init()
  let dmg = not emu.cgb_enabled

  if getEnv("GBFUZZ_BOOT_FRAMES") != "":
    var n = 0
    while n < 1000 and emu.memory.bootrom.len > 0:
      emu.step_frame(); inc n
    echo "boot_frames ", n
    quit(0)

  var max_frame = 0
  for s in shots: max_frame = max(max_frame, s)

  for f in 0 .. max_frame:
    for ev in script:
      if ev.frame == f: emu.handle_input(ev.key, ev.pressed)
    emu.step_frame()
    if f in shots:
      write_ppm(&"{prefix}.f{f:04}.ppm", emu.ppu.framebuffer, dmg)
      if getEnv("GBFUZZ_DUMP") != "":
        write_dump(&"{prefix}.f{f:04}.mem", emu)
      if want_state:
        if not emu.save_state(&"{prefix}.f{f:04}.state"):
          stderr.writeLine "save_state failed at frame " & $f

main()
