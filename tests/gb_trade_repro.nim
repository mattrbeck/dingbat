# ============================================================================
# GB/GBC link-trade reproduction harness (MANUAL regression tool)
# ============================================================================
#
# Drives two REAL Game Boy Color ROMs through the in-process lockstep GB link
# (gb/link.nim), the same byte-duplex serial path gblinktest.gb proves in
# the abstract, under a real game's link protocol.
#
#   --mode=stability   Boot both cores from power-on with an identical input
#       script and step them under the lockstep coordinator for <frames>;
#       they must stay bit-identical (checksummed every frame). Needs no
#       saves; does not reach an in-game trade (Gen 2 gates the Cable Club
#       behind owning Pokemon).
#   --mode=trade   REQUIRES two battery saves (siblings <rom>.sav) positioned
#       at the Cable Club Trade Center table plus a per-core nav script.
#       Reports whether the serial handshake completed (link.transfers
#       advancing) without the game tearing the link down. The saves need
#       the copyrighted ROMs, so this is MANUAL, not CI (like
#       tests/trade_repro.nim).
#
# BUILD
#   nim c -d:test_harness -d:release --path:src -o:gb_trade_repro \
#     tests/gb_trade_repro.nim
# RUN
#   ./gb_trade_repro --mode=stability <rom> <frames> [--shots=DIR]
#   ./gb_trade_repro --mode=trade <rom1> <rom2> <nav1.txt> <nav2.txt> \
#     <frames> [--shots=DIR]
#   Nav line: "<frame> <tok...>" sets that core's HELD buttons from <frame>
#   onward. Tokens: A B UP DOWN LEFT RIGHT START SELECT NONE(-).
# ============================================================================

import std/[os, strutils]
import dingbat/gb/gb
import dingbat/gb/link
import dingbat/common/input

proc parseButtons(toks: seq[string]): set[Input] =
  for t in toks:
    case t.toUpperAscii()
    of "A": result.incl A
    of "B": result.incl B
    of "UP": result.incl UP
    of "DOWN": result.incl DOWN
    of "LEFT": result.incl LEFT
    of "RIGHT": result.incl RIGHT
    of "START": result.incl START
    of "SELECT": result.incl SELECT
    else: discard

proc loadScript(path: string): seq[tuple[frame: int; held: set[Input]]] =
  if path.len == 0: return
  if not fileExists(path):
    raise newException(IOError, "nav script not found: " & path)
  for line in lines(path):
    let s = line.strip()
    if s.len == 0 or s.startsWith("#"): continue
    let parts = s.splitWhitespace()
    if parts.len < 2: continue
    result.add((parseInt(parts[0]), parseButtons(parts[1 .. ^1])))

proc bgr555_to_rgb(c: uint16): array[3, uint8] =
  let r5 = int(c and 0x1F)
  let g5 = int((c shr 5) and 0x1F)
  let b5 = int((c shr 10) and 0x1F)
  [uint8((r5 shl 3) or (r5 shr 2)),
   uint8((g5 shl 3) or (g5 shr 2)),
   uint8((b5 shl 3) or (b5 shr 2))]

proc write_ppm(path: string; buf: seq[uint16]) =
  var f = open(path, fmWrite)
  f.write("P6\n" & $GB_WIDTH & " " & $GB_HEIGHT & "\n255\n")
  for pixel in buf:
    let rgb = bgr555_to_rgb(pixel)
    f.write(char(rgb[0])); f.write(char(rgb[1])); f.write(char(rgb[2]))
  f.close()

type Driver = object
  cmds: seq[tuple[frame: int; held: set[Input]]]
  held: set[Input]
  si: int

proc apply(link: GbLink; d: var openArray[Driver]; f: int) =
  for c in 0 ..< link.cores.len:
    while d[c].si < d[c].cmds.len and d[c].cmds[d[c].si].frame <= f:
      let want = d[c].cmds[d[c].si].held
      for inp in Input:
        if inp in want and inp notin d[c].held: link.cores[c].handle_input(inp, true)
        if inp notin want and inp in d[c].held: link.cores[c].handle_input(inp, false)
      d[c].held = want
      inc d[c].si

proc make_gb(rom: string): GB =
  result = new_gb("", rom, fifo = true, headless = true, run_bios = false)
  result.post_init()

proc fb_hash(fb: seq[uint16]): uint32 =
  result = 0x811C9DC5'u32
  for v in fb:
    result = (result xor uint32(v and 0xFF)) * 0x01000193'u32
    result = (result xor uint32(v shr 8)) * 0x01000193'u32

proc stability(rom: string; frames: int; shotdir: string): int =
  ## Two identical cores, identical input, stepped under the lockstep
  ## coordinator. They must stay bit-identical; fail on first divergence.
  let link = new_gb_link(@[make_gb(rom), make_gb(rom)])
  # Mash A identically on both cores so game logic runs past the title.
  var press = false
  for f in 0 ..< frames:
    # toggle A every 20 frames on BOTH cores
    if f mod 20 == 0:
      press = not press
      for c in 0 ..< 2: link.cores[c].handle_input(A, press)
    link.step_frame()
    let h0 = fb_hash(link.cores[0].ppu.framebuffer)
    let h1 = fb_hash(link.cores[1].ppu.framebuffer)
    if h0 != h1:
      echo "STABILITY FAIL: cores diverged at frame ", f,
           " (", toHex(h0, 8), " vs ", toHex(h1, 8), ")"
      return 1
  if shotdir.len > 0:
    createDir(shotdir)
    write_ppm(shotdir / "core0.ppm", link.cores[0].ppu.framebuffer)
  echo "STABILITY: PASS (", frames, " frames, two Crystal cores bit-identical ",
       "under the lockstep link, ", link.transfers, " serial transfers)"
  0

proc trade(rom1, rom2, nav1, nav2: string; frames: int; shotdir: string): int =
  let link = new_gb_link(@[make_gb(rom1), make_gb(rom2)])
  var drivers: array[2, Driver]
  drivers[0].cmds = loadScript(nav1)
  drivers[1].cmds = loadScript(nav2)
  if shotdir.len > 0: createDir(shotdir)
  var max_transfers = 0
  var link_seen_frame = -1
  for f in 0 ..< frames:
    apply(link, drivers, f)
    link.step_frame()
    if link.transfers > max_transfers:
      max_transfers = link.transfers
      if link_seen_frame < 0: link_seen_frame = f
    if shotdir.len > 0 and f mod 300 == 0:
      for c in 0 ..< 2:
        write_ppm(shotdir / ("c" & $c & "_f" & align($f, 6, '0') & ".ppm"),
                  link.cores[c].ppu.framebuffer)
  if shotdir.len > 0:
    for c in 0 ..< 2:
      write_ppm(shotdir / ("c" & $c & "_final.ppm"), link.cores[c].ppu.framebuffer)
  echo "TRADE: ", max_transfers, " serial transfers over the cable",
       (if link_seen_frame >= 0: " (link first active at frame " & $link_seen_frame & ")" else: ""),
       "; flush saves and inspect screenshots to confirm the in-game trade."
  if max_transfers > 0: 0 else: 1

proc main() =
  var mode = "stability"
  var shotdir = ""
  var pos: seq[string]
  for arg in commandLineParams():
    if arg.startsWith("--mode="): mode = arg[7 .. ^1]
    elif arg.startsWith("--shots="): shotdir = arg[8 .. ^1]
    else: pos.add arg
  case mode
  of "stability":
    if pos.len < 2:
      echo "usage: gb_trade_repro --mode=stability <rom> <frames> [--shots=DIR]"
      quit(1)
    quit(stability(pos[0], parseInt(pos[1]), shotdir))
  of "trade":
    if pos.len < 5:
      echo "usage: gb_trade_repro --mode=trade <rom1> <rom2> <nav1> <nav2> <frames> [--shots=DIR]"
      quit(1)
    quit(trade(pos[0], pos[1], pos[2], pos[3], parseInt(pos[4]), shotdir))
  else:
    echo "unknown mode: ", mode, " (use stability or trade)"
    quit(1)

main()
