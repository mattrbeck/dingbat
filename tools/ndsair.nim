## Headless runner for several DS in one process on one radio (nds/air.nim):
## each machine its own ROM, inputs and save, all stepped in lockstep so
## their wifi hardware hears each other. docs/nds/wifi.md.
##
##   nim c -d:release -d:test_harness --path:src -o:ndsair tools/ndsair.nim
##   ./ndsair --frames 600 --out /tmp/air.png [--bios DIR] [--shots 100,200]
##       [--rtc 2004-01-01] [--trace-from F]
##       --rom A.nds [--press A@0-20] [--save A.sav]
##       --rom B.nds [--press ...] [--save B.sav]
##
## Options after a --rom apply to that machine; --press uses ndsrun's syntax
## (KEY@F[+D] or KEY@F-L, TOUCH:x:y@...). Machine i > 0 gets the firmware's
## MAC with its last byte xor i (CRC fixed up), so the consoles differ.
## Writes <out>_m<i>.png per machine (and <out>_m<i>_<F>.png per shot), and
## prints each console's wifi frame counts. Build with -d:wifilog for the
## register trace (station number in each line) from --trace-from on.

import std/[os, strutils, parseopt]
import dingbat/nds/[nds, air]
import dingbat/nds/io/[rtc, wifi]
import dingbat/gba/rtc_calendar
import ndsrun

type
  Hold = object
    button: NdsButton
    touch: bool
    x, y, first, last: int
  Machine = object
    rom, save: string
    holds: seq[Hold]

proc parse_holds(spec: string): seq[Hold] =
  for item in spec.split(','):
    if item.len == 0: continue
    let at = item.split('@')
    if at.len != 2: quit("--press wants KEY@FRAME[+DUR|-LAST]")
    var h = Hold()
    if '+' in at[1]:
      let fd = at[1].split('+')
      h.first = parseInt(fd[0]); h.last = h.first + parseInt(fd[1])
    else:
      let fl = at[1].split('-')
      h.first = parseInt(fl[0])
      h.last = if fl.len > 1: parseInt(fl[1]) else: h.first + 2
    let what = at[0].toUpperAscii
    if what.startsWith("TOUCH:"):
      let xy = what.split(':')
      h.touch = true; h.x = parseInt(xy[1]); h.y = parseInt(xy[2])
    else:
      const names = ["A", "B", "SELECT", "START", "RIGHT", "LEFT", "UP", "DOWN", "R", "L", "X", "Y"]
      let i = names.find(what)
      if i < 0: quit("unknown button " & what)
      h.button = NdsButton(i)
    result.add h

proc readbytes(p: string): seq[uint8] =
  if p.len == 0 or not fileExists(p): return @[]
  cast[seq[uint8]](readFile(p))

when isMainModule:
  var frames = 60
  var outp = "ndsair.png"
  var bios = getEnv("DINGBAT_NDS_BIOS")
  var shots: seq[int]
  var rtc_at = ""
  var ms: seq[Machine]
  var p = initOptParser(commandLineParams(), shortNoVal = {'h'}, longNoVal = @["help"])
  for kind, key, val in p.getopt():
    if kind notin {cmdLongOption, cmdShortOption}: quit("unexpected argument " & key)
    case key
    of "frames": frames = parseInt(val)
    of "out": outp = val
    of "bios": bios = val
    of "rtc": rtc_at = val
    of "shots":
      for f in val.split(','): shots.add parseInt(f)
    of "rom": ms.add Machine(rom: val)
    of "press", "save":
      if ms.len == 0: quit("--" & key & " before any --rom")
      if key == "press": ms[^1].holds.add parse_holds(val)
      else: ms[^1].save = val
    else: quit("unknown option --" & key)
  if ms.len == 0: quit("usage: ndsair --rom A.nds [--press ..] --rom B.nds .. [--frames N] [--out PNG]")
  let b9 = readbytes(if bios.len > 0: bios / "bios9.bin" else: "")
  let b7 = readbytes(if bios.len > 0: bios / "bios7.bin" else: "")
  var fw = readbytes(if bios.len > 0: bios / "firmware.bin" else: "")
  if fw.len == 0: fw = synth_firmware()
  var machines: seq[NDS]
  for i, m in ms:
    var mac: array[6, uint8]
    for k in 0..5: mac[k] = fw[0x36 + k]
    mac[5] = mac[5] xor uint8(i)
    let n = new_nds(readbytes(m.rom), b9, b7, firmware_with_mac(fw, mac))
    if rtc_at.len > 0:
      let d = rtc_at.replace('T', '-').replace(':', '-').split('-')
      var f: array[6, int]
      for k in 0 ..< min(6, d.len): f[k] = parseInt(d[k])
      n.rtc.set_fixed_clock(n.sched, to_calendar_seconds(f[0], f[1], f[2], f[3], f[4], f[5]))
    if m.save.len > 0 and fileExists(m.save):
      n.cart.backup.set_data(readbytes(m.save))
    machines.add n
  let link = new_air_link(machines)
  let base = outp.changeFileExt("")
  for f in 0 ..< frames:
    for i, m in ms:
      for h in m.holds:
        if f == h.first or f == h.last:
          if h.touch: machines[i].set_touch(h.x, h.y, f == h.first)
          else: machines[i].set_button(h.button, f == h.first)
    link.run_frames(1)
    if f + 1 in shots:
      for i, n in machines:
        write_png(base & "_m" & $i & "_" & $(f + 1) & ".png", 256, 384, n.screens_rgba())
  for i, n in machines:
    write_png(base & "_m" & $i & ".png", 256, 384, n.screens_rgba())
    echo "m", i, " ", ms[i].rom.extractFilename, ": channel ", n.wifi.channel,
         ", frames sent ", n.wifi.tx_frames, ", received ", n.wifi.rx_frames
    if ms[i].save.len > 0 and n.cart.backup.dirty:
      writeFile(ms[i].save, cast[string](n.cart.backup.data))
  echo "air: ", link.air.frames, " frames, ", link.air.late, " late"
