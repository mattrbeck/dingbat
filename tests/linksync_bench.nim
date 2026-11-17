## What the link sync checks cost (gba/rollback.nim, gb/rollback.nim syncEvery):
## per game, a frame of the 2-core link, one fingerprint (both cores'
## state_bytes + sync_hash), the re-sync payload (pack_state), and two
## rollback sessions over a 3-step input delay with the checks on and off.
##
##   nim c -d:test_harness -d:release --path:src -o:linksync_bench tests/linksync_bench.nim
##   ./linksync_bench game.gba [game2.gbc ...]
## A .sav beside a ROM is read (copy it first: cores write it back).

import std/[os, strutils, monotimes, times, algorithm, strformat]
import dingbat/common/input
import dingbat/common/linksync
import dingbat/common/serialize
import dingbat/common/test_output
import dingbat/gba/gba
import dingbat/gba/link
import dingbat/gba/rollback
import dingbat/gb/gb
import dingbat/gb/link as gblink
import dingbat/gb/rollback as gbrb

proc ms(d: Duration): float = d.inNanoseconds.float / 1e6
proc median(xs: var seq[float]): float =
  xs.sort()
  xs[xs.len div 2]

proc p0(f: int): uint16 =
  ## Busy buttons, so both players' inputs change and predictions miss.
  var v = 0'u16
  if f mod 2 == 0: v = v or (1'u16 shl ord(A))
  if f mod 5 == 0: v = v or (1'u16 shl ord(RIGHT))
  if f mod 11 == 0: v = v or (1'u16 shl ord(START))
  v
proc p1(f: int): uint16 =
  var v = 0'u16
  if f mod 3 == 0: v = v or (1'u16 shl ord(B))
  if f mod 4 == 0: v = v or (1'u16 shl ord(LEFT))
  if f mod 13 == 0: v = v or (1'u16 shl ord(A))
  v

template bench_game(gameTitle: string; mkCore, newLink, newSess, rbAdv: untyped) {.dirty.} =
  # One game: everything above, printed as a block.
  block:
    let warm = 900
    let l = newLink(@[mkCore(), mkCore()])
    for f in 0 ..< warm:
      for i in 0 ..< 10:
        l.cores[0].handle_input(Input(i), ((p0(f) shr i) and 1) != 0)
        l.cores[1].handle_input(Input(i), ((p1(f) shr i) and 1) != 0)
      l.step_frame()
    # A frame of both cores.
    var frames: seq[float]
    for f in 0 ..< 600:
      let t = getMonoTime()
      for i in 0 ..< 10:
        l.cores[0].handle_input(Input(i), ((p0(f) shr i) and 1) != 0)
        l.cores[1].handle_input(Input(i), ((p1(f) shr i) and 1) != 0)
      l.step_frame()
      frames.add ms(getMonoTime() - t)
    # One fingerprint, and its parts.
    var fps, ser, hsh: seq[float]
    var img0, img1: string
    for r in 0 ..< 200:
      var t = getMonoTime()
      img0 = l.cores[0].state_bytes()
      img1 = l.cores[1].state_bytes()
      ser.add ms(getMonoTime() - t)
      t = getMonoTime()
      discard sync_hash(img1, sync_hash(img0))
      hsh.add ms(getMonoTime() - t)
      t = getMonoTime()
      var h = 0'u64
      for c in l.cores: h = sync_hash(c.state_bytes(), h)
      fps.add ms(getMonoTime() - t)
    # What the fingerprint of an earlier frame adds: the live state out, the
    # ring's in, and back (rollback.nim sync_flush).
    var swaps, after: seq[float]
    for r in 0 ..< 100:
      let t = getMonoTime()
      let live = l.capture_state()
      l.restore_state(live)
      swaps.add ms(getMonoTime() - t)
    # And a frame just after a swap, against one without (warm caches lost?).
    for r in 0 ..< 100:
      let live = l.capture_state()
      l.restore_state(live)
      let t = getMonoTime()
      l.step_frame()
      after.add ms(getMonoTime() - t)
    echo &"  state out and back in    {median(swaps):7.3f} ms; the frame after it {median(after):.3f} ms"
    var packs: seq[float]
    var packed = ""
    for r in 0 ..< 20:
      let t = getMonoTime()
      packed = pack_state(img0)
      packs.add ms(getMonoTime() - t)
    let frame = median(frames)
    let fpm = median(fps)
    let title = gameTitle
    echo title
    echo &"  frame, both cores        {frame:7.3f} ms (median of 600)"
    echo &"  fingerprint, both cores  {fpm:7.3f} ms = state_bytes {median(ser):.3f} + hash {median(hsh):.3f} (median of 200)"
    echo &"  state image per core     {img0.len div 1024} KB plain, {packed.len div 1024} KB packed ({median(packs):.2f} ms to pack): a re-sync sends one each way"
    echo &"  every 120 frames         {fpm / 120.0 * 1000.0:7.1f} us a frame on average = {fpm / 120.0 / frame * 100.0:.2f}% of a frame"
    # Two sessions, inputs 3 steps late, with the checks every 120 frames and
    # without; the time is both peers together, so halve it for one.
    proc session(every: int): (float, int, int) =
      let a = newSess(newLink(@[mkCore(), mkCore()]), 0, 12, every)
      let b = newSess(newLink(@[mkCore(), mkCore()]), 1, 12, every)
      var qab, qba: seq[(int, int, uint16)]
      const N = 1800
      var step = 0
      let t = getMonoTime()
      while (a.head < N or b.head < N) and step < N * 10:
        inc step
        var keep: seq[(int, int, uint16)]
        for m in qab:
          if m[0] <= step: b.feed_remote(m[1], m[2]) else: keep.add m
        qab = keep
        keep = @[]
        for m in qba:
          if m[0] <= step: a.feed_remote(m[1], m[2]) else: keep.add m
        qba = keep
        if a.head < N and a.tick(p0(a.head)) == rbAdv:
          qab.add((step + 3, a.head - 1, p0(a.head - 1)))
        if b.head < N and b.tick(p1(b.head)) == rbAdv:
          qba.add((step + 3, b.head - 1, p1(b.head - 1)))
      (ms(getMonoTime() - t), a.rollbacks + b.rollbacks, a.syncOut.len + b.syncOut.len)
    # Alternating, fastest of five each: the overhead, not the machine's noise.
    var on, off: seq[float]
    var rollbacks, prints = 0
    for r in 0 ..< 5:
      let (tOff, _, _) = session(0)
      let (tOn, rb, pr) = session(120)
      off.add tOff; on.add tOn
      rollbacks = rb; prints = pr
    let perOff = min(off) / 2.0 / 1800.0
    let perOn = min(on) / 2.0 / 1800.0
    echo &"  session, one peer        {perOff:7.3f} ms a frame checks off, {perOn:.3f} on " &
      &"(+{(perOn - perOff) / perOff * 100.0:.2f}%; 1800 frames, {rollbacks} rollbacks, {prints} fingerprints)"

let gbaBios = ""
for path in commandLineParams():
  let ext = path.splitFile.ext.toLowerAscii
  if ext == ".gba":
    proc mk(): GBA =
      result = new_gba(gbaBios, path, run_bios = false, use_hle = true)
      result.test_output = new_test_output()
      result.post_init()
    bench_game(path.extractFilename, mk, new_link, new_rollback_session, rbAdvanced)
  else:
    proc mkgb(): GB =
      result = new_gb("", path, true, false)
      result.post_init()
    bench_game(path.extractFilename, mkgb, new_gb_link, new_gb_rollback_session, grbAdvanced)
