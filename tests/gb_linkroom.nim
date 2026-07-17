# ============================================================================
# GB Cable-Club link-room driver  (MANUAL debugging tool)
# ============================================================================
#
# Drives two real GB/GBC saves — each pre-positioned at the Cable Club trade
# counter — through the link handshake under the in-process lockstep GB link
# (gb/link.nim), and reports whether BOTH cores get past "Please wait." into
# the trade room. Built to debug the asymmetric-handshake bug (one side links,
# the other times out).
#
# BUILD  (-d:gbLinkTrace compiles in the per-transfer hook)
#   nim c -d:test_harness -d:release -d:gbLinkTrace --path:src \
#     -o:gb_linkroom tests/gb_linkroom.nim
#
# RUN
#   ./gb_linkroom <rom1> <rom2> <frames> <shotdir> [--mash=A] [--trace=N]
#
# Each ROM loads its sibling <rom>.sav. Both cores are mashed with A (talk to
# the attendant / confirm the link). --trace=N dumps the first N serial
# transfers. Screenshots of both cores are written every 120 frames.
# ============================================================================

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
    let c = bgr_rgb(px)
    f.write(char(c[0])); f.write(char(c[1])); f.write(char(c[2]))
  f.close()

proc make_gb(rom: string): GB =
  result = new_gb("", rom, fifo = true, headless = true, run_bios = false)
  result.post_init()

var traceRemaining = 0

proc main() =
  var pos: seq[string]
  var traceN = 0
  for a in commandLineParams():
    if a.startsWith("--trace="): traceN = parseInt(a[8 .. ^1])
    elif a.startsWith("--"): discard
    else: pos.add a
  if pos.len < 4:
    echo "usage: gb_linkroom <rom1> <rom2> <frames> <shotdir> [--trace=N]"
    quit(1)
  let rom1 = pos[0]; let rom2 = pos[1]
  let frames = parseInt(pos[2]); let shotdir = pos[3]
  createDir(shotdir)
  traceRemaining = traceN

  let link = new_gb_link(@[make_gb(rom1), make_gb(rom2)])

  when defined(gbLinkTrace):
    onGbTransfer = proc(master: int; master_out, slave_out: uint8;
                        slave_sc: uint8; slave_got_irq: bool) =
      if traceRemaining > 0:
        dec traceRemaining
        echo "xfer m=", master, " m_out=", toHex(master_out),
             " s_out=", toHex(slave_out), " s_sc=", toHex(slave_sc),
             " s_irq=", slave_got_irq

  # hSerialConnectionStatus ($FFCB): 0xFF not established, 0x01 external
  # clock, 0x02 internal clock. hSerialReceive ($FFCE): last byte received.
  proc hram(c, addr16: int): uint8 = link.cores[c].memory.hram[addr16 - 0xFF80]
  var lastStatus = [0'u8, 0]
  var lastTransfers = 0
  var stalledFrames = 0
  let skew = getEnv("GB_INPUT_SKEW").len > 0
  for f in 0 ..< frames:
    # Mash A on both cores: talk to the attendant, confirm the link prompts.
    # With GB_INPUT_SKEW, core 1's mash is phase-shifted so the two cores
    # don't press identically (models two humans / breaks perfect symmetry).
    for c in 0 .. 1:
      let ph = if c == 1 and skew: (f + 11) else: f
      link.cores[c].handle_input(A, (ph mod 24) < 8)
    link.step_frame()
    for c in 0 .. 1:
      let st = hram(c, 0xFFCB)
      if st != lastStatus[c]:
        echo "frame ", f, " core ", c, " connStatus ",
             toHex(lastStatus[c]), " -> ", toHex(st),
             " (recv=", toHex(hram(c, 0xFFCE)), ")"
        lastStatus[c] = st
    if link.transfers != lastTransfers:
      lastTransfers = link.transfers
      stalledFrames = 0
    else:
      inc stalledFrames
    if f mod 120 == 0:
      for c in 0 .. 1:
        write_ppm(shotdir / ("c" & $c & "_f" & align($f, 5, '0') & ".ppm"),
                  link.cores[c].ppu.framebuffer)
      echo "frame ", f, ": transfers=", link.transfers,
           " (stalled ", stalledFrames, "f)"
  for c in 0 .. 1:
    write_ppm(shotdir / ("c" & $c & "_final.ppm"), link.cores[c].ppu.framebuffer)
  echo "DONE: ", link.transfers, " total transfers over the cable"
  when defined(gbLinkTrace):
    echo "both-internal (peer also clocking) transfers: ", bothInternalCount,
         " of ", link.transfers

main()
