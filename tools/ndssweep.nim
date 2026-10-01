## DS compatibility sweep: run many ROMs headless in dingbat and in a
## reference core (tools/ndsref), with the same scripted inputs, and report
## per ROM whether it runs, how it differs and what looks broken.
##
##   nim c -d:release -d:test_harness --path:src -o:ndssweep tools/ndssweep.nim
##   ./ndssweep ROM_OR_DIR.. [--out DIR] [--frames 600] [--shots 30,115,240,360,600]
##       [--press SPEC] [--core melondsds | --no-ref] [--ndsref PATH]
##       [--jobs N] [--timeout SECS] [--bios DIR] [--only NAME,..]
##
## Every ROM gets DIR/<name>/: ours_<F>.png, ref_<F>.png, ours.json (the
## metrics below), ours.err (our stderr: unmapped accesses, ...), ref.wav.
## DIR/results.tsv and DIR/table.md hold the summary, one row per ROM.
##
## What ours.json records, from the run itself:
## - exceptions: undefined-instruction / abort exceptions per CPU and the pc
##   of the last one (a libnds program has no business taking either);
## - unmapped: accesses to unmapped memory or I/O;
## - hang: the ARM9 never halted over the last 120 frames, its pc stayed in
##   one 256-byte window and the screens did not change;
## - blank: a screen that is one colour at every shot;
## - frames_changed: how many frames differed from the one before;
## - audio peak / RMS of the whole run around its mean (DC removed); ms per frame (process CPU time, so
##   a loaded machine does not skew it).
## The reference run gives its shots and audio; the table compares the two:
##   ok              every shot identical
##   ok-phase        every shot identical to a reference frame at most
##                   PHASE frames away (the "offset" column: ref frame - ours)
##   differs         runs in both, shots differ (largest diff % shown)
##   broken          ours stayed blank where the reference did not, or
##                   crashed / hung with shots >= BROKEN_DIFF % off
##   broken-ref-too  the reference is blank too (or fails to load), and ours
##                   is blank, crashed or hung
##   ref-broken      the reference is blank (or fails to load), ours is not
##
## --press defaults to a generic "get past the title" script: START, A, a
## touch in the middle of the bottom screen, START, A, DOWN, A, B.
## --report rebuilds the table from an earlier run's files without running.
## `--one ROM --out DIR` runs only our side for one ROM (the sweep spawns
## itself that way, so a ROM that takes our core down takes only its run).

import std/[os, osproc, strutils, parseopt, json, monotimes, times, math, sequtils,
            algorithm, streams]
import zippy
import dingbat/nds/nds
import dingbat/nds/io/spi

const
  DEFAULT_PRESS = "START@120,A@180,A@240,TOUCH:128:96@300+4,START@360,A@420," &
                  "DOWN@450,A@480,B@540"
  DEFAULT_SHOTS = "30,115,240,360,600"
  HANG_WINDOW = 120
  PHASE = 2                    ## reference frames either side of each shot
  SILENT = 2.0 / 32768         ## AC peak below this: silent
  BROKEN_DIFF = 25.0           ## % of a screen: a crash/hang this far off is ours

# ---------------------------------------------------------------------------
# PNG in/out (8-bit RGB / RGBA, non-interlaced: what ndsref and we write)

proc crc32(data: openArray[uint8]): uint32 =
  var table {.global.}: array[256, uint32]
  if table[1] == 0:
    for i in 0'u32 .. 255:
      var c = i
      for _ in 0..7: c = if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
      table[i] = c
  result = 0xFFFFFFFF'u32
  for b in data: result = table[(result xor b) and 0xFF] xor (result shr 8)
  result = not result

proc be32(s: var seq[uint8]; v: uint32) =
  s.add uint8(v shr 24); s.add uint8(v shr 16); s.add uint8(v shr 8); s.add uint8(v)

proc write_png(path: string; w, h: int; rgb: seq[uint32]) =
  ## `rgb`: 0x00BBGGRR per pixel.
  var raw: seq[uint8]
  for y in 0 ..< h:
    raw.add 0
    for x in 0 ..< w:
      let p = rgb[y * w + x]
      raw.add uint8(p); raw.add uint8(p shr 8); raw.add uint8(p shr 16)
  var png = @[0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  proc chunk(png: var seq[uint8]; kind: string; data: seq[uint8]) =
    png.be32(uint32(data.len))
    var body: seq[uint8]
    for c in kind: body.add uint8(c)
    body.add data
    png.add body
    png.be32(crc32(body))
  var ihdr: seq[uint8]
  ihdr.be32(uint32(w)); ihdr.be32(uint32(h))
  ihdr.add [8'u8, 2, 0, 0, 0]
  png.chunk("IHDR", ihdr)
  png.chunk("IDAT", compress(raw, dataFormat = dfZlib))
  png.chunk("IEND", @[])
  writeFile(path, cast[string](png))

proc read_png(path: string; w, h: var int): seq[uint32] =
  ## 0x00BBGGRR per pixel; empty on any error.
  if not fileExists(path): return
  let d = cast[seq[uint8]](readFile(path))
  if d.len < 8: return
  var pos = 8
  var idat: seq[uint8]
  var ctype = 0
  proc u32(d: seq[uint8]; i: int): int =
    (int(d[i]) shl 24) or (int(d[i + 1]) shl 16) or (int(d[i + 2]) shl 8) or int(d[i + 3])
  while pos + 8 <= d.len:
    let ln = u32(d, pos)
    let kind = cast[string](d[pos + 4 ..< pos + 8])
    let body = pos + 8
    if kind == "IHDR":
      w = u32(d, body); h = u32(d, body + 4)
      if d[body + 8] != 8 or d[body + 12] != 0: return
      ctype = int(d[body + 9])
    elif kind == "IDAT": idat.add d[body ..< body + ln]
    elif kind == "IEND": break
    pos = body + ln + 4
  let bpp = case ctype
            of 2: 3
            of 6: 4
            else: return
  let raw = cast[seq[uint8]](uncompress(idat, dataFormat = dfZlib))
  let stride = w * bpp
  var prev = newSeq[uint8](stride)
  var cur = newSeq[uint8](stride)
  result = newSeq[uint32](w * h)
  var p = 0
  for y in 0 ..< h:
    let f = raw[p]; inc p
    for i in 0 ..< stride:
      let x = raw[p + i]
      let a = if i >= bpp: int(cur[i - bpp]) else: 0
      let b = int(prev[i])
      let c = if i >= bpp: int(prev[i - bpp]) else: 0
      cur[i] = case f
        of 0: x
        of 1: uint8((int(x) + a) and 0xFF)
        of 2: uint8((int(x) + b) and 0xFF)
        of 3: uint8((int(x) + (a + b) div 2) and 0xFF)
        else:
          let pp = a + b - c
          let pa = abs(pp - a)
          let pb = abs(pp - b)
          let pc = abs(pp - c)
          let pr = if pa <= pb and pa <= pc: a elif pb <= pc: b else: c
          uint8((int(x) + pr) and 0xFF)
    p += stride
    for x in 0 ..< w:
      result[y * w + x] = uint32(cur[x * bpp]) or (uint32(cur[x * bpp + 1]) shl 8) or
                          (uint32(cur[x * bpp + 2]) shl 16)
    swap(prev, cur)

proc ac_stats(s: openArray[float32]): (float, float) =
  ## Peak and RMS around the mean: SOUNDBIAS puts a DC level on the output
  ## (bias - 200h, docs/oracles.md) that some cores filter away, and a
  ## program that only sets the bias is silent, not loud.
  if s.len == 0: return (0.0, 0.0)
  var mean = 0.0
  for x in s: mean += float(x)
  mean /= float(s.len)
  var peak, sumsq = 0.0
  for x in s:
    let d = float(x) - mean
    peak = max(peak, abs(d))
    sumsq += d * d
  (peak, sqrt(sumsq / float(s.len)))

proc wav_stats(path: string): (float, float, int) =
  ## (peak, RMS) of a 16-bit WAV as a fraction of full scale, DC removed
  ## (see ac_stats), and its sample-frame count.
  if not fileExists(path): return (-1.0, -1.0, 0)
  let d = readFile(path)
  if d.len < 44: return (-1.0, -1.0, 0)
  var v: seq[float32]
  var i = 44
  while i + 1 < d.len:
    v.add float32(cast[int16](uint16(ord(d[i])) or (uint16(ord(d[i + 1])) shl 8))) / 32768
    i += 2
  let (peak, rms) = ac_stats(v)
  (peak, rms, v.len div 2)

# ---------------------------------------------------------------------------
# Our side: one ROM

type Press = object
  button: NdsButton
  touch: bool
  x, y, first, last: int

proc parse_presses(spec: string): seq[Press] =
  ## ndsrun's syntax: KEY@F[+D|-L], TOUCH:x:y@F..
  for item in spec.split(','):
    if item.len == 0: continue
    let at = item.split('@')
    var p = Press()
    if '+' in at[1]:
      let fd = at[1].split('+')
      p.first = parseInt(fd[0]); p.last = p.first + parseInt(fd[1])
    else:
      let fl = at[1].split('-')
      p.first = parseInt(fl[0])
      p.last = if fl.len > 1: parseInt(fl[1]) else: p.first + 2
    let what = at[0].toUpperAscii
    if what.startsWith("TOUCH:"):
      let xy = what.split(':')
      p.touch = true; p.x = parseInt(xy[1]); p.y = parseInt(xy[2])
    else:
      p.button = case what
        of "A": nbA
        of "B": nbB
        of "SELECT": nbSelect
        of "START": nbStart
        of "RIGHT": nbRight
        of "LEFT": nbLeft
        of "UP": nbUp
        of "DOWN": nbDown
        of "R": nbR
        of "L": nbL
        of "X": nbX
        of "Y": nbY
        else: quit("unknown button " & what)
    result.add p

proc frame_rgb(n: NDS): seq[uint32] =
  result = newSeq[uint32](256 * 384)
  for i in 0 ..< 256 * 192:
    result[i] = bgr555_to_rgba(n.gpu.top[i]) and 0xFFFFFF
    result[256 * 192 + i] = bgr555_to_rgba(n.gpu.bottom[i]) and 0xFFFFFF

proc screen_hash(px: openArray[uint16]): uint64 =
  result = 1469598103934665603'u64
  for c in px: result = (result xor uint64(c)) * 1099511628211'u64

proc one_colour(px: openArray[uint32]; lo, hi: int): bool =
  for i in lo + 1 ..< hi:
    if px[i] != px[lo]: return false
  true

proc run_one(rom, outdir, bios, press: string; frames: int; shots: seq[int]) =
  createDir(outdir)
  let presses = parse_presses(press)
  let t0 = cpuTime()
  let n = load_nds(rom, bios)
  var audio: seq[float32]
  var prev_hash = (0'u64, 0'u64)
  var changed = 0
  var last_change = 0
  var halted9_at = -1          # last frame the ARM9 was seen halted
  var pcs: seq[uint32]
  var blank_top, blank_bottom = true
  var shot_info = newJArray()
  var halts = 0
  for f in 0 ..< frames:
    for p in presses:
      if f == p.first or f == p.last:
        if p.touch: n.set_touch(p.x, p.y, f == p.first)
        else: n.set_button(p.button, f == p.first)
    # sample the ARM9 a few times per frame for the hang check
    n.frame_done = false
    let limit = n.sched.now + 2 * FRAME_CYCLES
    var k = 0
    while not n.frame_done and n.sched.now < limit:
      n.run_until(min(limit, n.sched.now + LINE_CYCLES))
      inc k
      if (k and 31) == 0:
        if n.arm9.halted: halted9_at = f; inc halts
        else: pcs.add n.arm9.next_pc
    if n.arm9.halted: halted9_at = f
    audio.add n.spu.take_samples()
    let h = (screen_hash(n.gpu.top), screen_hash(n.gpu.bottom))
    if h != prev_hash:
      if f > 0: inc changed
      last_change = f
      prev_hash = h
    if frames - f == HANG_WINDOW: pcs.setLen(0)
    if f + 1 in shots:
      let px = n.frame_rgb()
      write_png(outdir / "ours_" & $(f + 1) & ".png", 256, 384, px)
      let bt = one_colour(px, 0, 256 * 192)
      let bb = one_colour(px, 256 * 192, 256 * 384)
      blank_top = blank_top and bt
      blank_bottom = blank_bottom and bb
      shot_info.add %*{"frame": f + 1, "blank_top": bt, "blank_bottom": bb}
  let secs = cpuTime() - t0
  let (peak, rms) = ac_stats(audio)
  var hang = false
  if halted9_at < frames - HANG_WINDOW and pcs.len > 0 and
     last_change < frames - HANG_WINDOW:
    hang = pcs.max - pcs.min < 256
  let j = %*{
    "rom": rom, "frames": frames, "ms_per_frame": secs * 1000 / float(frames),
    "exc9": n.arm9.exc_count, "exc9_pc": toHex(n.arm9.exc_pc, 8),
    "exc7": n.arm7.exc_count, "exc7_pc": toHex(n.arm7.exc_pc, 8),
    "mode9": toHex(n.arm9.cpsr and 0x1F, 2), "mode7": toHex(n.arm7.cpsr and 0x1F, 2),
    "pc9": toHex(n.arm9.next_pc, 8), "pc7": toHex(n.arm7.next_pc, 8),
    "instrs9": n.arm9.instr_count, "instrs7": n.arm7.instr_count,
    "unmapped": n.unmapped_count, "hang": hang,
    "power_off": (n.spi.pm_regs[0] and 0x40) != 0,
    "hang_pc": (if pcs.len > 0: toHex(pcs[^1], 8) else: ""),
    "frames_changed": changed, "last_change": last_change,
    "blank_top": blank_top, "blank_bottom": blank_bottom,
    "audio_peak": peak, "audio_rms": rms, "shots": shot_info}
  writeFile(outdir / "ours.json", $j)

# ---------------------------------------------------------------------------
# The sweep

type
  Job = object
    cmd: string
    args: seq[string]
    err: string                ## stderr file
    deadline: float

proc run_pool(jobs: seq[Job]; width: int; timeout: float) =
  ## Run the jobs `width` at a time; kill any that outlives `timeout` s.
  var running: seq[(Process, Job, MonoTime)]
  var next = 0
  while next < jobs.len or running.len > 0:
    while running.len < width and next < jobs.len:
      let jb = jobs[next]
      inc next
      let p = startProcess(jb.cmd, args = jb.args,
                           options = {poStdErrToStdOut})
      running.add (p, jb, getMonoTime())
    var i = 0
    var any = false
    while i < running.len:
      let (p, jb, t) = running[i]
      let code = p.peekExitCode()
      let late = (getMonoTime() - t).inMilliseconds.float / 1000 > timeout
      if code != -1 or late:
        if code == -1:
          p.kill(); discard p.waitForExit()
          writeFile(jb.err & ".timeout", "killed after " & $timeout & " s\n")
        let o = p.outputStream.readAll()
        writeFile(jb.err, o)
        p.close()
        running.delete(i)
        any = true
      else: inc i
    if not any: sleep(50)

proc diff_pct(a, b: seq[uint32]): (float, float) =
  ## Mismatched pixels per screen, percent.
  if a.len != 256 * 384 or b.len != a.len: return (-1.0, -1.0)
  var t, m = 0
  for i in 0 ..< 256 * 192:
    if a[i] != b[i]: inc t
    if a[256 * 192 + i] != b[256 * 192 + i]: inc m
  (t * 100 / (256 * 192), m * 100 / (256 * 192))

proc fmt1(x: float): string = formatFloat(x, ffDecimal, 2)

proc sweep(roms: seq[string]; outdir, bios, press, core, ndsref: string;
           frames: int; shots: seq[int]; width: int; timeout: float; report_only = false) =
  createDir(outdir)
  let self = getAppFilename()
  let shots_s = shots.mapIt($it).join(",")
  # the reference also shoots +-PHASE frames around each shot, so a run that
  # is only a frame or two out of phase is told apart from a real difference
  var ref_shots: seq[int]
  for f in shots:
    for k in -PHASE .. PHASE:
      if f + k >= 1 and f + k <= frames and f + k notin ref_shots: ref_shots.add f + k
  let ref_shots_s = ref_shots.mapIt($it).join(",")
  var jobs: seq[Job]
  for rom in roms:
    let d = outdir / rom.splitFile.name
    createDir(d)
    var args = @["--one", rom, "--out", d, "--frames", $frames, "--shots", shots_s,
                 "--press", press]
    if bios.len > 0: args.add ["--bios", bios]
    jobs.add Job(cmd: self, args: args, err: d / "ours.err")
    if core.len > 0:
      # a ROM with its ARM9 binary in the cart's secure area is moved for
      # the reference (tools/ndsref/README.md, --relocate)
      var r = rom
      let hdr = readFile(rom)
      if hdr.len > 0x30:
        let off = uint32(ord(hdr[0x20])) or (uint32(ord(hdr[0x21])) shl 8) or
                  (uint32(ord(hdr[0x22])) shl 16) or (uint32(ord(hdr[0x23])) shl 24)
        if off >= 0x4000'u32 and off < 0x8000'u32:
          r = d / "reloc.nds"
          discard execCmd(quoteShell(currentSourcePath().parentDir / "ndsref" / "ndsreloc") & " " &
                          quoteShell(rom) & " " & quoteShell(r))
      var rargs = @["--core", core, r, "--frames", $frames, "--shots", ref_shots_s,
                    "--press", press, "--depth5", "--no-final", "--out", d / "ref",
                    "--wav", d / "ref.wav"]
      if bios.len > 0: rargs.add ["--bios", bios]
      jobs.add Job(cmd: ndsref, args: rargs, err: d / "ref.err")
  if not report_only: run_pool(jobs, width, timeout)

  # --- the table
  var tsv = "rom\tstatus\tdiff_max\taligned_max\tdiffs\tours\tref\taudio_ours\taudio_ref\tunmapped\texc\tms_frame\tnotes\n"
  var md = "| ROM | status | diff % | aligned diff % (offset) | ours | reference | audio RMS ours / ref | ms/frame |\n" &
           "|---|---|---|---|---|---|---|---|\n"
  for rom in roms:
    let name = rom.splitFile.name
    let d = outdir / name
    var notes: seq[string]
    var ours_flags: seq[string]
    var ref_flags: seq[string]
    var j: JsonNode
    try: j = parseFile(d / "ours.json")
    except CatchableError:
      j = nil
    var status = ""
    var diffs: seq[string]
    var dmax = 0.0
    var amax = 0.0             # worst shot after the best phase offset
    var offsets: seq[int]
    var ref_blank_all = true
    var ref_loaded = false
    var ours_blank_all = true
    for f in shots:
      var w, h, w2, h2: int
      let a = read_png(d / "ours_" & $f & ".png", w, h)
      let b = read_png(d / "ref_" & $f & ".png", w2, h2)
      if b.len == 256 * 384:
        ref_loaded = true
        if not (one_colour(b, 0, 256 * 192) and one_colour(b, 256 * 192, 256 * 384)):
          ref_blank_all = false
      if a.len == 256 * 384 and not (one_colour(a, 0, 256 * 192) and
                                     one_colour(a, 256 * 192, 256 * 384)):
        ours_blank_all = false
      if a.len == 256 * 384 and b.len == a.len:
        # ours | reference, for looking at
        var side = newSeq[uint32](516 * 384)
        for y in 0 ..< 384:
          for x in 0 ..< 256:
            side[y * 516 + x] = a[y * 256 + x]
            side[y * 516 + 260 + x] = b[y * 256 + x]
          for x in 256 ..< 260: side[y * 516 + x] = 0xFF00FF
        write_png(d / "side_" & $f & ".png", 516, 384, side)
      let (t, m) = diff_pct(a, b)
      if t >= 0:
        diffs.add fmt1(t) & "/" & fmt1(m)
        dmax = max(dmax, max(t, m))
        var best = t + m
        var bestk = 0
        for k in -PHASE .. PHASE:
          if k == 0: continue
          var w3, h3: int
          let c = read_png(d / "ref_" & $(f + k) & ".png", w3, h3)
          let (t2, m2) = diff_pct(a, c)
          if t2 >= 0 and t2 + m2 < best: best = t2 + m2; bestk = k
        if bestk != 0:
          var w3, h3: int
          let (t2, m2) = diff_pct(a, read_png(d / "ref_" & $(f + bestk) & ".png", w3, h3))
          amax = max(amax, max(t2, m2))
        else: amax = max(amax, max(t, m))
        offsets.add bestk
      else: diffs.add "-"
    let (rpeak, rrms, _) = wav_stats(d / "ref.wav")
    var arms = -1.0
    var unm = 0
    var exc = 0
    var msf = 0.0
    if j == nil:
      ours_flags.add "no-result"
      if fileExists(d / "ours.err.timeout"): ours_flags.add "timeout"
    else:
      arms = j["audio_rms"].getFloat
      unm = j["unmapped"].getInt
      exc = j["exc9"].getInt + j["exc7"].getInt
      msf = j["ms_per_frame"].getFloat
      if j["exc9"].getInt > 0: ours_flags.add "exc9@" & j["exc9_pc"].getStr
      if j["exc7"].getInt > 0: ours_flags.add "exc7@" & j["exc7_pc"].getStr
      if j["power_off"].getBool: ours_flags.add "power-off"
      elif j["hang"].getBool: ours_flags.add "hang@" & j["hang_pc"].getStr
      if ours_blank_all: ours_flags.add "blank"
      elif j["blank_top"].getBool: ours_flags.add "top-blank"
      elif j["blank_bottom"].getBool: ours_flags.add "bottom-blank"
      if j["frames_changed"].getInt == 0: ours_flags.add "static"
      if j["audio_peak"].getFloat < SILENT: ours_flags.add "silent"
      if unm > 0: ours_flags.add "unmapped:" & $unm
    if core.len > 0:
      if not ref_loaded: ref_flags.add "no-result"
      elif ref_blank_all: ref_flags.add "blank"
      if rpeak < SILENT: ref_flags.add "silent"
    # a program that exits powers the DS off (PM register 0 bit 6, GBATEK
    # "DS Power Management"); our screens keep the last picture, so a
    # power-off is not counted as a hang
    # an exception or a hang is "broken" only when the picture is far from
    # the reference's too: a program that crashes the same way on both
    # (a libnds exception screen on each) is a difference, not our bug
    let off = j != nil and j["power_off"].getBool
    let stuck = exc > 0 or (j != nil and j["hang"].getBool and not off)
    let ours_broken = j == nil or (ours_blank_all and not ref_blank_all) or
                      (stuck and (core.len == 0 or amax >= BROKEN_DIFF))
    let silent_only = j != nil and j["audio_peak"].getFloat < SILENT and rpeak > 0.01
    if core.len == 0:
      status = if ours_broken: "broken" else: "ran"
    elif not ref_loaded or ref_blank_all:
      status = if ours_broken or ours_blank_all or stuck: "broken-ref-too" else: "ref-broken"
    elif ours_broken: status = "broken"
    elif dmax == 0 and not silent_only: status = "ok"
    elif amax == 0 and not silent_only: status = "ok-phase"
    else:
      status = "differs"
      if silent_only: notes.add "silent in ours"
    if off: notes.add "exits: our screens keep the last picture after the power-off"
    let ours_s = if ours_flags.len > 0: ours_flags.join(" ") else: "-"
    let ref_s = if ref_flags.len > 0: ref_flags.join(" ") else: "-"
    let offs = offsets.deduplicate.filterIt(it != 0)
    let aligned = fmt1(amax) & (if offs.len > 0: " (" & offs.mapIt((if it > 0: "+" else: "") & $it).join(",") & ")" else: "")
    tsv.add [name, status, fmt1(dmax), aligned, diffs.join(" "), ours_s, ref_s,
             formatFloat(arms, ffDecimal, 4), formatFloat(rrms, ffDecimal, 4),
             $unm, $exc, formatFloat(msf, ffDecimal, 2), notes.join("; ")].join("\t") & "\n"
    md.add "| " & name & " | " & status & " | " & fmt1(dmax) & " | " & aligned & " | " &
           ours_s & " | " & ref_s & " | " & formatFloat(arms, ffDecimal, 3) &
           " / " & formatFloat(rrms, ffDecimal, 3) & " | " & formatFloat(msf, ffDecimal, 2) & " |\n"
  writeFile(outdir / "results.tsv", tsv)
  writeFile(outdir / "table.md", md)
  stdout.write md

when isMainModule:
  var roms: seq[string]
  var one = ""
  var outdir = "ndssweep_out"
  var frames = 600
  var shots_s = DEFAULT_SHOTS
  var press = DEFAULT_PRESS
  var core = "melondsds"
  var ndsref = ""
  var bios = ""
  var width = max(1, countProcessors() - 1)
  var timeout = 300.0
  var only: seq[string]
  var report_only = false
  var p = initOptParser(commandLineParams(), longNoVal = @["no-ref", "report"])
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument: roms.add key
    of cmdLongOption, cmdShortOption:
      case key
      of "one": one = val
      of "out": outdir = val
      of "frames": frames = parseInt(val)
      of "shots": shots_s = val
      of "press": press = val
      of "core": core = val
      of "no-ref": core = ""
      of "ndsref": ndsref = val
      of "bios": bios = val
      of "jobs": width = parseInt(val)
      of "timeout": timeout = parseFloat(val)
      of "only": only = val.split(',')
      of "report": report_only = true
      else: quit("unknown option --" & key)
    of cmdEnd: discard
  let shots = shots_s.split(',').mapIt(parseInt(it))
  if one.len > 0:
    run_one(one, outdir, bios, press, frames, shots)
    quit(0)
  var files: seq[string]
  for r in roms:
    if dirExists(r):
      for f in walkDirRec(r):
        if f.toLowerAscii.endsWith(".nds"): files.add f
    else: files.add r
  if only.len > 0: files = files.filterIt(it.splitFile.name in only)
  files.sort()
  if files.len == 0: quit("usage: ndssweep ROM_OR_DIR.. [--out DIR] (see the header)")
  if core.len > 0 and ndsref.len == 0:
    ndsref = getAppFilename().parentDir / "ndsref"
    if not fileExists(ndsref): ndsref = currentSourcePath().parentDir / "ndsref" / "ndsref"
    if not fileExists(ndsref): quit("ndsref not found: build it (sh tools/ndsref/build.sh) or pass --ndsref")
  sweep(files, outdir, bios, press, core, ndsref, frames, shots, width, timeout, report_only)
