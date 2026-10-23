## Display-capture survey (-d:nds_cap_survey, a measurement build;
## docs/nds/gpu3d.md, "Lazy capture"): for each capture into a bank (A-D),
## what reads the bank before the next capture into it. A capture whose
## bank only the display reads could be left to the host GPU, its bytes
## owed to the machine until something else reads them.
##
## Readers: the CPUs (and DMA) through the bus; the display (VRAM display
## mode) and capture source B per line; and, per frame, the bank mapped
## where a 2D engine or the 3D renderer may read it (coarse: mapped, not
## known to be read).

import std/[strutils, algorithm]
import ../mem/vram

type
  Reader* = enum
    rdCpu9 = "ARM9", rdDma9 = "ARM9 DMA or BIOS copy", rdCpu7 = "ARM7", rdDisplay = "VRAM display",
    rdCaptureB = "capture B", rdBg = "2D BG", rdObj = "2D OBJ", rdTexture = "3D texture"

var
  owed: array[4, bool]                  ## the bank holds a capture not yet overwritten
  seen: array[4, set[Reader]]
  lifetimes: array[1 shl (ord(high(Reader)) + 1), int]  ## by reader set
  cap_frames, frames: int
  configs: seq[(string, int)]
  copying: bool                         ## the last non-CPU read was from an owed bank
  copies: seq[(string, int)]            ## where those copies wrote (by area)

proc tally(t: var seq[(string, int)]; key: string) =
  for c in t.mitems:
    if c[0] == key:
      inc c[1]
      return
  t.add (key, 1)

proc note_read*(v: Vram; r: VramRegion; offset: int; who: Reader) =
  ## A bus read of `offset` in region r (in range for the region).
  let m = v.page_banks(r, offset shr 14)
  var hit = false
  for b in 0..3:
    if owed[b] and (m and (1'u16 shl b)) != 0:
      seen[b].incl who
      hit = true
  if who == rdDma9: copying = hit

proc note_copy_write*(a: uint32) =
  ## A non-CPU ARM9 write: where a copy out of an owed bank went.
  if not copying: return
  copying = false
  copies.tally(case a shr 24
               of 0x02: "main RAM"
               of 0x03: "shared WRAM"
               of 0x04: (if a in 0x04000400'u32 .. 0x040005FF'u32: "3D FIFO/commands" else: "I/O")
               of 0x05: "palette"
               of 0x06: (case (a shr 20) and 0xE
                         of 0x0: "VRAM engine A BG"
                         of 0x2: "VRAM engine B BG"
                         of 0x4: "VRAM engine A OBJ"
                         of 0x6: "VRAM engine B OBJ"
                         else: "VRAM LCDC")
               of 0x07: "OAM"
               else: "other")

proc note_bank*(b: int; who: Reader) =
  if b in 0..3 and owed[b]: seen[b].incl who

proc close(b: int) =
  if owed[b]: inc lifetimes[int(cast[uint8](seen[b]))]
  owed[b] = false
  seen[b] = {}

proc captured*(b: int; capc: uint32) =
  ## A frame's capture into bank b starts (its line 0).
  close(b)
  owed[b] = true
  inc cap_frames
  const SIZES = ["128x128", "256x64", "256x128", "256x192"]
  let src = (capc shr 29) and 3
  let a = if (capc and (1'u32 shl 24)) != 0: "3D" else: "2D+3D"
  let bsrc = if (capc and (1'u32 shl 25)) != 0: "main memory" else: "VRAM"
  let desc = SIZES[(capc shr 20) and 3] & " " &
             (case src
              of 0: "A " & a
              of 1: "B " & bsrc
              else: "A " & a & " + B " & bsrc)
  configs.tally(desc)

proc frame_start*(v: Vram; a_bg, a_obj, b_bg, b_obj, tex: bool) =
  ## Line 0: where each owed bank is mapped, and whether that user is on.
  inc frames
  for b in 0..3:
    if not owed[b]: continue
    let cnt = v.cnt[VramBank(b)]
    if (cnt and 0x80) == 0: continue
    let mst = int(cnt and (if b < 2: 3'u8 else: 7'u8))
    case mst
    of 1: (if a_bg: seen[b].incl rdBg)
    of 2: (if b < 2 and a_obj: seen[b].incl rdObj)
    of 3: (if tex: seen[b].incl rdTexture)
    of 4: (if b == 2 and b_bg: seen[b].incl rdBg elif b == 3 and b_obj: seen[b].incl rdObj)
    else: discard

proc report*(): string =
  for b in 0..3: close(b)
  result = "capture survey: " & $cap_frames & " of " & $frames & " frames capture\n"
  for (d, n) in configs: result.add "  capture " & d & ": " & $n & " frames\n"
  var rows: seq[(int, string)]
  for i, n in lifetimes:
    if n == 0: continue
    var names: seq[string]
    for r in Reader:
      if r in cast[set[Reader]](uint8(i)): names.add $r
    rows.add (n, if names.len == 0: "nothing" else: names.join(", "))
  rows.sort(proc (x, y: (int, string)): int = cmp(y[0], x[0]))
  for (n, s) in rows: result.add "  read by " & s & ": " & $n & " captures\n"
  for (d, n) in copies: result.add "  copied out to " & d & ": " & $n & " words\n"
