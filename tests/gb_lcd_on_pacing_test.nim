## Frame pacing across an LCD enable (LCD_ON_FRAME_DOTS, ppu.nim). Run
## standalone:
##   nimble test_gblcdonpacing
##
## The hardware side is fixed: an enable restarts the PPU at line 0, so its
## first vblank is 144 lines (65664 dots) on, wherever the last one was. What
## is open is whether the core hands the frontend a frame at the enable. With
## d dots gone since the last present, waiting makes one interval of
## d + 65664 dots and pushing makes one of d and one of 65664; the rule under
## test picks whichever leaves every interval nearest the 70224-dot frame
## period, which puts the threshold at 70224 - 65664 / 2 = 37392 and keeps
## every interval within 65664 / 2 = 32832 dots of a period.
##
## No ROM on disk: each program waits for vblank, switches the LCD off, idles
## for a swept time (0 to about two frames, in steps of 1/64 frame) and
## switches it on again. The test measures every step_frame in dots
## (-d:gb_dot_counter) and asks that
##   - no interval is further from 70224 dots than 32832 (plus the length of
##     an instruction),
##   - both answers occur across the sweep (some enables push, some wait),
##   - an enable pushes exactly when more than LCD_ON_FRAME_DOTS dots have
##     gone by.
## Building with -d:LCD_ON_FRAME_DOTS=<other> fails the first check once the
## value is more than an instruction or so from 37392, on the long side below
## it and on the short side above it.

import std/os
import dingbat/gb/gb

const
  FRAME = 70224
  FIRST_VBLANK = 144 * 456
  SLACK = 64       # one instruction, and step_frame's run to the end of mode 3

var failures = 0
var checks = 0
proc check(cond: bool; msg: string) =
  inc checks
  if not cond:
    inc failures
    if failures <= 40: echo "  [FAIL] ", msg

proc program(idle: int): seq[int] =
  ## `idle` turns of a 7-M-cycle (28-dot) loop with the LCD off.
  @[0xF3,                         # di
    0xF0, 0x44, 0xFE, 0x90,       # wait: ldh a,[LY]; cp 144
    0x20, 0xFA,                   #   jr nz,wait
    0xAF, 0xE0, 0x40,             # xor a; ldh [LCDC],a      LCD off in vblank
    0x01, idle and 0xFF, idle shr 8,  # ld bc,idle
    0x0B, 0x78, 0xB1, 0x20, 0xFB, #   dec bc; ld a,b; or c; jr nz
    0x3E, 0x91, 0xE0, 0x40,       # ld a,$91; ldh [LCDC],a   LCD on
    0x18, 0xFE]                   # jr -2

proc make_rom(code: openArray[int]; cgb: bool): string =
  var rom = newString(0x8000)
  for v in [0x40, 0x48, 0x50, 0x58, 0x60]: rom[v] = char(0xD9)
  for i, b in [0x00, 0xC3, 0x50, 0x01]: rom[0x100 + i] = char(b)
  rom[0x143] = char(if cgb: 0x80 else: 0x00)
  for i, b in code: rom[0x150 + i] = char(b and 0xFF)
  var sum = 0
  for a in 0x134 .. 0x14C: sum = sum - int(uint8(rom[a])) - 1
  rom[0x14D] = char(sum and 0xFF)
  result = getTempDir() / "dingbat_lcdon_pacing.gb"
  writeFile(result, rom)

var worst_long, worst_short = 0
var pushed, waited = 0

proc run(idle: int; cgb: bool) =
  let path = make_rom(program(idle), cgb)
  defer:
    removeFile(path)
    removeFile(path.changeFileExt("sav"))
  let emu = new_gb("", path, headless = true, run_bios = false)
  emu.post_init()
  # Up to the frame that ends on the first vblank the program waits for (the
  # hand-off is mid-frame, which is not what is measured here).
  emu.step_frame()
  # The program switches the LCD off within a few instructions of that
  # vblank, so the first frame from here that ends with the LCD on is the
  # one the enable fell in.
  var enabled = false
  for f in 1 .. 6:
    let before = gb_total_dots
    emu.step_frame()
    let gap = int(gb_total_dots - before)
    let dev = gap - FRAME
    if dev > worst_long: worst_long = dev
    if -dev > worst_short: worst_short = -dev
    check(abs(dev) <= FIRST_VBLANK div 2 + SLACK,
          "idle " & $idle & (if cgb: " cgb" else: " dmg") & " frame " & $f &
          ": " & $gap & " dots, " & $dev & " from a frame period")
    if emu.ppu.lcd_enabled and not enabled:
      enabled = true
      # It ended at the enable (line 0) if the core pushed, at the first
      # vblank if it waited.
      let at_enable = emu.ppu.ly == 0
      if at_enable: inc pushed else: inc waited
      # Dots since the last present when the enable landed.
      let d = if at_enable: gap else: gap - FIRST_VBLANK
      if LCD_ON_FRAME_DOTS != 0 and abs(d - LCD_ON_FRAME_DOTS) > SLACK:
        check(at_enable == (d > LCD_ON_FRAME_DOTS),
              "idle " & $idle & ": enable " & $d & " dots after a present " &
              (if at_enable: "pushed" else: "waited"))
  check(enabled, "idle " & $idle & ": the LCD came back on")

for cgb in [false, true]:
  var idle = 1
  while idle < 2 * FRAME div 28:
    run(idle, cgb)
    idle += FRAME div 28 div 64

check(pushed > 0 and waited > 0,
      "the sweep reaches both answers (" & $pushed & " pushed, " & $waited & " waited)")
echo "LCD_ON_FRAME_DOTS = ", LCD_ON_FRAME_DOTS, ": ", pushed, " enables pushed a frame, ",
     waited, " waited; longest interval +", worst_long, " dots, shortest -",
     worst_short, " against a ", FRAME, "-dot frame"
if failures == 0:
  echo "ALL ", checks, " LCD-ON PACING CHECKS PASSED"
else:
  echo failures, " of ", checks, " LCD-ON PACING CHECKS FAILED"
  quit(1)
