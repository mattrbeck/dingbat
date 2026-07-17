# Reproduce a stuck GB link trade OFFLINE from two dumped save states.
#
# Take the two core states captured in the browser at the "Please Wait!" hang
# (dumpLinkStates() → core0.state / core1.state), load each onto its matching
# ROM, wire them into a lockstep GbLink, and step — monitoring the serial
# transfer stream. If the trade stalls here (transfers stop) it reproduces the
# browser hang deterministically, isolating it from the online/rollback layer.
#
#   nim c -d:test_harness -d:release -d:gbLinkTrace --path:src \
#     -o:gb_trade_states tests/gb_trade_states.nim
#   ./gb_trade_states <rom0> <state0> <rom1> <state1> <frames> <shotdir>
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

proc load(rom, state: string): GB =
  enable_deterministic_gb_rtc(1_700_000_000)  # freeze; state carries the value
  result = new_gb("", rom, fifo = true, headless = true, run_bios = false)
  result.post_init()
  if not result.load_state_bytes(readFile(state)):
    raise newException(ValueError, "failed to load state " & state & " onto " & rom)

proc main() =
  let p = commandLineParams()
  if p.len < 6:
    echo "usage: gb_trade_states <rom0> <state0> <rom1> <state1> <frames> <shotdir>"
    quit(1)
  let frames = parseInt(p[4]); let shotdir = p[5]
  createDir(shotdir)
  let link = new_gb_link(@[load(p[0], p[1]), load(p[2], p[3])])

  var lastTransfers = -1
  var stall = 0
  var maxStall = 0
  for f in 0 ..< frames:
    # No input (the trade "Please Wait!" runs with the players idle).
    link.step_frame()
    if link.transfers != lastTransfers:
      lastTransfers = link.transfers; stall = 0
    else:
      inc stall; maxStall = max(maxStall, stall)
    if f mod 60 == 0 or f == frames - 1:
      for c in 0..1: write_ppm(shotdir / ("c" & $c & "_f" & align($f,5,'0') & ".ppm"),
                               link.cores[c].ppu.framebuffer)
      echo "frame ", f, ": transfers=", link.transfers, " stall=", stall
  for c in 0..1: write_ppm(shotdir / ("c" & $c & "_final.ppm"), link.cores[c].ppu.framebuffer)
  echo "DONE transfers=", link.transfers, " maxStall=", maxStall,
       (if maxStall > 300: "  <-- STALLED (trade hang reproduced)" else: "")

main()
