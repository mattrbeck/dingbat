# Drives two linked GB cores from the Cable Club counter INTO an actual party-
# data trade (walk to the table, initiate), monitoring the serial-transfer
# stream for a stall — reproduces the "Please Wait!" trade hang natively.
#   nim c -d:test_harness -d:release -d:gbLinkTrace --path:src \
#     -o:gb_trade_nav tests/gb_trade_nav.nim
#   ./gb_trade_nav <rom1> <rom2> <frames> <shotdir> [--enter=N] [--up=N] [--a2=N]
import std/[os, strutils]
import dingbat/gb/gb
import dingbat/gb/link
import dingbat/common/input

proc bgr_rgb(c: uint16): array[3, uint8] =
  let r = int(c and 0x1F); let g = int((c shr 5) and 0x1F); let b = int((c shr 10) and 0x1F)
  [uint8((r shl 3) or (r shr 2)), uint8((g shl 3) or (g shr 2)), uint8((b shl 3) or (b shr 2))]
proc write_ppm(path: string; buf: seq[uint16]) =
  var f = open(path, fmWrite)
  f.write("P6\n" & $GB_WIDTH & " " & $GB_HEIGHT & "\n255\n")
  for px in buf:
    let c = bgr_rgb(px); f.write(char(c[0])); f.write(char(c[1])); f.write(char(c[2]))
  f.close()
proc make_gb(rom: string): GB =
  enable_deterministic_gb_rtc(1_700_000_000)
  result = new_gb("", rom, fifo = true, headless = true, run_bios = false)
  result.post_init()

proc main() =
  var pos: seq[string]
  var enterF = 760   # A-mash: intro+Continue+attendant → into the room
  var upF = 60       # then walk UP toward the trade table
  var a2F = 40       # then A-mash again to initiate the trade at the table
  for a in commandLineParams():
    if a.startsWith("--enter="): enterF = parseInt(a[8..^1])
    elif a.startsWith("--up="): upF = parseInt(a[5..^1])
    elif a.startsWith("--a2="): a2F = parseInt(a[5..^1])
    else: pos.add a
  let rom1 = pos[0]; let rom2 = pos[1]; let frames = parseInt(pos[2]); let shotdir = pos[3]
  createDir(shotdir)
  let link = new_gb_link(@[make_gb(rom1), make_gb(rom2)])

  proc hold(inp: Input; on: bool) =
    for c in 0..1: link.cores[c].handle_input(inp, on)
  var lastTransfers = 0
  var stall = 0
  var maxStallAfterTrade = 0
  var tradeStartFrame = -1
  for f in 0 ..< frames:
    # phase 1: enter room (A-mash; identical timing works for two DIFFERENT
    # games — they're already asymmetric — and keeps the dialog prompts synced)
    if f < enterF:
      hold(A, (f mod 24) < 8)
    elif f < enterF + upF:
      hold(A, false); hold(UP, (f mod 8) < 5)   # walk up to the table
    else:
      hold(UP, false); hold(A, (f mod 24) < 8)  # initiate trade at the table
    link.step_frame()
    if link.transfers != lastTransfers:
      if tradeStartFrame < 0 and link.transfers > 40: tradeStartFrame = f
      lastTransfers = link.transfers; stall = 0
    else:
      inc stall
      if tradeStartFrame >= 0: maxStallAfterTrade = max(maxStallAfterTrade, stall)
    if f mod 150 == 0 or f == frames-1:
      for c in 0..1: write_ppm(shotdir / ("c" & $c & "_f" & align($f,5,'0') & ".ppm"),
                               link.cores[c].ppu.framebuffer)
      echo "frame ", f, ": transfers=", link.transfers, " stall=", stall
  echo "DONE transfers=", link.transfers, " tradeStart=", tradeStartFrame,
       " maxStallAfterTrade=", maxStallAfterTrade
  for c in 0..1: write_ppm(shotdir / ("c" & $c & "_final.ppm"), link.cores[c].ppu.framebuffer)

main()
