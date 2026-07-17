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
  # Per-core D-pad route from the Trade Center spawn (4,7, facing up) to the
  # console, ending facing it (pokecrystal maps/TradeCenter.asm bg_events):
  #   master (internal clock) → west seat (3,4): Left,Up,Up,Up, face Right
  #   guest  (external clock) → east seat (6,4): Right,Right,Up,Up,Up, face Left
  # Which core is which is discovered at run time (connStatus 0x02 = internal),
  # but here we just try: core 1 was the internal-clock master in earlier traces.
  const MOVE = 18  # frames to hold a direction for one tile step
  proc route(inp: seq[Input]; f, base: int): Input =
    let i = (f - base) div MOVE
    if i < inp.len: inp[i] else: SELECT  # SELECT = unused sentinel = no move
  let westRoute  = @[LEFT, UP, UP, UP, RIGHT]         # core 1 (master)
  let eastRoute  = @[RIGHT, RIGHT, UP, UP, UP, LEFT]  # core 0 (guest)
  let navEnd = enterF + max(westRoute.len, eastRoute.len) * MOVE

  var lastTransfers = 0
  var stall = 0
  var maxStallAfterTrade = 0
  var tradeStartFrame = -1
  for f in 0 ..< frames:
    for c in 0..1:
      for i in Input: link.cores[c].handle_input(i, false)
    if f < enterF:
      # phase 1: enter room (A-mash; keeps the dialog prompts synced)
      hold(A, (f mod 24) < 8)
    elif f < navEnd:
      # phase 2: walk each core to its console, ending facing it
      let d0 = route(eastRoute, f, enterF)
      let d1 = route(westRoute, f, enterF)
      if d0 != SELECT: link.cores[0].handle_input(d0, true)
      if d1 != SELECT: link.cores[1].handle_input(d1, true)
    else:
      # phase 3: press A at the console → initiate the party-data trade
      hold(A, (f mod 24) < 8)
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
