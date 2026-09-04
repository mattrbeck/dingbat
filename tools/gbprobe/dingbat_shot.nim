## gbprobe's dingbat leg.
##
##   dingbat_shot <rom> <model> <frames> <out.ppm> [buttons]
##
## [buttons] drives the combined cart's menu (probes_all_check.sh): a comma
## separated list of steps, each "<n>" or "<n>:<keys>", meaning hold those keys
## for n frames. Keys are u d l r a b s(tart) e(select). The steps run FIRST and
## <frames> then runs with nothing held, so <frames> stays the page's own count.
##
##   model: dmg | dmg0 | mgb | sgb | sgb2 | cgb0 | cgbab | cgbc | cgbd | cgbe
##          | cgb (= cgbc, dingbat's shipping CGB default) | agb
##
## Same contract as sameboy_shot and docboy_shot: one ROM, one model, N frames
## from power-on, one P6 PPM out, so `cmp` on two PPMs is meaningful. DMG
## frames are normalised to the shared four-shade grey ramp; CGB frames are
## the raw RGB555 expanded to 8 bits per channel.
##
## Runs skip-boot. The probe ROMs re-anchor on an LYC=0 STAT interrupt every
## frame, so power-on phase differences between the legs do not reach the
## measurement. Build: see build.sh.

import std/[os, strutils]
import dingbat/gb/gb

const GREY4 = [0xFF'u8, 0xAD'u8, 0x52'u8, 0x00'u8]

proc revision_of(token: string): (GbRevision, bool) =
  case token.toLowerAscii()
  of "dmg0":            (grDmg0, false)
  of "dmg", "dmgabc":   (grDmgABC, false)
  of "mgb":             (grMgb, false)
  of "sgb":             (grSgb, false)
  of "sgb2":            (grSgb2, false)
  of "cgb0":            (grCgb0, true)
  of "cgbab", "cgba", "cgbb": (grCgbAB, true)
  of "cgbc", "cgb":     (grCgbC, true)
  of "cgbd":            (grCgbD, true)
  of "cgbe":            (grCgbE, true)
  of "agb":             (grAgb, true)
  else:
    stderr.writeLine "unknown model " & token
    quit(2)

proc press(emu: GB; keys: string) =
  let j = emu.joypad
  j.up = 'u' in keys; j.down = 'd' in keys
  j.left = 'l' in keys; j.right = 'r' in keys
  j.a = 'a' in keys; j.b = 'b' in keys
  j.start = 's' in keys; j.jselect = 'e' in keys
  joypad_update(j, emu)

proc write_ppm(path: string; buf: seq[uint16]; dmg: bool) =
  var f = open(path, fmWrite)
  f.write("P6\n160 144\n255\n")
  for pixel in buf:
    if dmg:
      # In DMG mode palette RAM only holds DMG_COLORS, so the shade index is
      # recoverable; an unknown value falls through so it shows as a
      # difference rather than being quantised away.
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

proc main() =
  let args = commandLineParams()
  if args.len notin {4, 5}:
    echo "usage: dingbat_shot <rom> <model> <frames> <out.ppm> [buttons]"
    quit(2)
  let (rev, want_cgb) = revision_of(args[1])
  let frames = parseInt(args[2])

  # The probe ROMs carry the CGB-compatible header flag ($80), so the model
  # token is what decides which machine they run on, not the cartridge.
  let emu = new_gb("", args[0], fifo = true, headless = true, run_bios = false,
                   force_cgb = want_cgb, force_dmg = not want_cgb)
  emu.gb_set_revision(rev)
  emu.post_init()

  if args.len == 5 and args[4].len > 0:
    for step in args[4].split(','):
      let parts = step.split(':')
      emu.press(if parts.len > 1: parts[1] else: "")
      for _ in 0 ..< parseInt(parts[0]):
        emu.step_frame()
    emu.press("")

  for _ in 0 ..< frames:
    emu.step_frame()
  write_ppm(args[3], emu.ppu.framebuffer, not emu.cgb_enabled)

main()
