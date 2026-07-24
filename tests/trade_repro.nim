# ============================================================================
# Cross-version trade reproduction harness  (MANUAL regression tool)
# ============================================================================
#
# WHAT THIS TESTS
#   Drives two REAL Pokemon ROMs (FireRed = core 0, Emerald = core 1), each
#   pre-positioned at the Cable Club, into the cross-version link trade and
#   verifies the multi-mode SIO exchange completes WITHOUT the "communication
#   error" teardown. It reproduces the trade over ALL THREE link code paths the
#   emulator implements, selected with --path=:
#
#     lockstep  link.nim direct: new_link([fr, em]) + step_frame().  Both cores
#               advance in perfect lockstep; the SIO cable is resolved in-process.
#     netcore   serial.nim NETCORE online path: two independent NetCore peers
#               (netcore.nim) shuttling frames through in-memory queues with a
#               configurable network delay (--delay), like run_spec_link.
#     rollback  the DEFAULT browser online path (web/netplay.js, NET_ROLLBACK):
#               ONE RollbackSession over a 2-core Link; core 0 = local player,
#               core 1's inputs arrive --delay frames late via feed_remote(),
#               forcing rollbacks so the trade exchange runs THROUGH re-simulation.
#
#   All three of these paths were fixed & verified; this tool is the regression
#   guard that they stay fixed. The three sub-paths share the same driving code
#   (ROM+save load, nav-script parsing, screenshot dump) and the same comm-error
#   detector; only the core wiring + per-frame advance differ.
#
# REQUIRES THE REAL ROMS  (copyrighted, NOT in the repo)
#   Positional args point at a FireRed .gba and an Emerald .gba, each with its
#   battery save as a sibling <rom>.sav (auto-loaded by new_gba). The saves must
#   already have both players standing at the Cable Club trade table. The trade
#   performs an in-game save, so RE-COPY the pristine .sav files before each run.
#   Because the ROMs cannot ship, this is a MANUAL tool — it is NOT part of CI or
#   the dingbat_test acceptance suite.
#
# BUILD
#   nim c -d:test_harness -d:release -d:linkTrace --path:src \
#     -o:trade_repro tests/trade_repro.nim
#   (-d:linkTrace compiles in the onCoalesce hook used for the optional coalesce
#    assertion; it is stripped from normal/production builds.)
#
# RUN
#   ./trade_repro --path=<lockstep|netcore|rollback> \
#     <fr.gba> <em.gba> <nav.txt> <frames> <shotdir> \
#     [--delay=N] [--shots=N] [--no-shots]
#
#   --path    which link path to exercise (also env TRADE_PATH). Required.
#   --delay   network / remote-input latency in frames (netcore & rollback only;
#             lockstep ignores it). Run each of 0 AND a positive value.
#   --shots   dump a PPM screenshot of both cores every N frames (default 300).
#   --no-shots   skip screenshots entirely.
#
# EXAMPLES  (roms/saves/nav under $D)
#   D=/path/to/tradedrive
#   ./trade_repro --path=lockstep $D/fr.gba $D/em.gba $D/nav_final.txt 3600 /tmp/ls
#   ./trade_repro --path=netcore  $D/fr.gba $D/em.gba $D/nav_final.txt 3600 /tmp/nc --delay=4
#   ./trade_repro --path=rollback $D/fr.gba $D/em.gba $D/nav_final.txt 3600 /tmp/rb --delay=4
#
# VERDICT
#   Each run prints one PASS/FAIL line. PASS = the link negotiation was reached
#   AND no comm error AND no deadlock. The comm-error signature is FireRed core 0
#   SIOCNT latching 0x2000 WITH gLinkStatus(@0x03003F20) bit 0x2000 set, OR
#   gLink.badChecksum(@0x03003FC1) going nonzero. A bare SIOCNT=0x2000 with
#   gLinkStatus=0 during the early handshake is a benign SIO_MULTI_MODE select,
#   NOT a failure, and is deliberately ignored.
# ============================================================================

import std/[os, strutils]
import dingbat/gba/gba
import dingbat/gba/link
import dingbat/gba/netcore    # NetCore online path (also re-exports crc32)
import dingbat/gba/rollback   # RollbackSession input-rollback path
import dingbat/common/input

# ---------------------------------------------------------------- nav script --

type Cmd = object
  frame, core: int
  held: set[Input]

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
    of "L": result.incl L
    of "R": result.incl R
    of "NONE", "-": discard
    else: discard

# Nav line: "<frame> <core> <tok...>" sets that core's HELD buttons from <frame>
# onward (persists until the next line for that core). E.g. "120 0 A START".
proc loadScript(path: string): seq[Cmd] =
  if path.len == 0 or not fileExists(path):
    raise newException(IOError, "nav script not found: " & path)
  for line in lines(path):
    let s = line.strip()
    if s.len == 0 or s.startsWith("#"): continue
    let parts = s.splitWhitespace()
    if parts.len < 3: continue
    result.add Cmd(frame: parseInt(parts[0]), core: parseInt(parts[1]),
                   held: parseButtons(parts[2 .. ^1]))

# Expand the (sorted) command list into per-core, per-frame held-button sets:
# heldPerFrame[core][f] is what core `core` holds while running frame f.
proc expandHeld(cmds: seq[Cmd]; frames: int): array[2, seq[set[Input]]] =
  for c in 0 .. 1: result[c] = newSeq[set[Input]](frames)
  var held: array[2, set[Input]]
  var si = 0
  for f in 0 ..< frames:
    while si < cmds.len and cmds[si].frame <= f:
      if cmds[si].core in {0, 1}: held[cmds[si].core] = cmds[si].held
      inc si
    for c in 0 .. 1: result[c][f] = held[c]

proc mask(s: set[Input]): uint16 =
  for i in s: result = result or (1'u16 shl int(i))

# Push a held-set change into a core as press/release edges.
proc applyHeld(g: GBA; oldH, newH: set[Input]) =
  for i in Input:
    let w = i in newH
    if w != (i in oldH): g.handle_input(i, w)

# ---------------------------------------------------------- IWRAM + PPM dump --

# IWRAM (0x03000000) readers — bus.wram_chip, offset = addr & 0x7FFF.
proc iw32(g: GBA; adr: int): uint32 =
  let o = adr and 0x7FFF
  uint32(g.bus.wram_chip[o]) or (uint32(g.bus.wram_chip[o+1]) shl 8) or
    (uint32(g.bus.wram_chip[o+2]) shl 16) or (uint32(g.bus.wram_chip[o+3]) shl 24)
proc iw16(g: GBA; adr: int): uint16 =
  let o = adr and 0x7FFF
  uint16(g.bus.wram_chip[o]) or (uint16(g.bus.wram_chip[o+1]) shl 8)
proc iw8(g: GBA; adr: int): uint8 = g.bus.wram_chip[adr and 0x7FFF]

proc dumpPPM(g: GBA; path: string) =
  let fb = g.ppu.framebuffer
  var f = open(path, fmWrite)
  f.write("P6\n240 160\n255\n")
  for c in fb:
    f.write(char((c and 0x1F) shl 3))          # R
    f.write(char(((c shr 5) and 0x1F) shl 3))   # G
    f.write(char(((c shr 10) and 0x1F) shl 3))  # B
  f.close()

# ---------------------------------------------------- comm-error detector -----

# FireRed rev1 (BPRE 1.1) gLink fields.
const
  G_STATUS = 0x03003F20   # gLinkStatus; bit 0x2000 = LINK_STAT_ERROR_CHECKSUM
  G_BADCHK = 0x03003FC1   # gLink.badChecksum (nonzero once a checksum mismatch hits)

# Watches FireRed (core 0) for the trade "communication error" teardown. The
# link is "live" once SIOCNT enters an active multi transfer mode (0x6xxx) or
# gLinkStatus's low byte is populated — i.e. the Cable Club handshake happened.
# From then on, a SIOCNT reset to 0x2000 WITH gLinkStatus bit 0x2000, or any
# nonzero badChecksum, is the real failure. A bare 0x2000 with gLinkStatus=0 is
# the benign SIO_MULTI_MODE select seen mid-handshake and is ignored.
type CommState = object
  linkLive*: bool       ## reached the Cable Club link negotiation
  commError*: bool
  errFrame*: int
  errKind*: string

proc observe(cs: var CommState; g0: GBA; f: int) =
  let sio = g0.serial.siocnt
  let st = iw32(g0, G_STATUS)
  let bad = iw8(g0, G_BADCHK)
  if (sio and 0x6000'u16) == 0x6000'u16 or (st and 0x00FF'u32) != 0:
    cs.linkLive = true
  if cs.commError: return
  let teardown = cs.linkLive and sio == 0x2000'u16 and (st and 0x2000'u32) != 0
  if teardown or bad != 0'u8:
    cs.commError = true
    cs.errFrame = f
    cs.errKind =
      if teardown: "teardown siocnt=0x2000 gLinkStatus=" & toHex(st, 8)
      else: "badChecksum=" & toHex(bad, 2)

# ------------------------------------------------------------------ verdict ---

type Verdict = object
  path: string
  reachedLink: bool
  commError: bool
  errFrame: int
  errKind: string
  deadlock: bool
  framesRun: int
  summary: string       ## concise per-path metrics line

proc pass(v: Verdict): bool =
  v.reachedLink and not v.commError and not v.deadlock

proc report(v: Verdict) =
  echo "---- ", v.path, " ----"
  echo "  ", v.summary
  echo "  reached-link=", v.reachedLink, " commError=", v.commError,
    (if v.commError: " @f" & $v.errFrame & " (" & v.errKind & ")" else: ""),
    " deadlock=", v.deadlock, " framesRun=", v.framesRun
  if v.pass:
    echo v.path.toUpperAscii(), ": PASS (reached trade negotiation, no comm error, no deadlock)"
  else:
    let why =
      if not v.reachedLink: "never reached link negotiation"
      elif v.commError: "communication error"
      elif v.deadlock: "deadlock / did not complete"
      else: "unknown"
    echo v.path.toUpperAscii(), ": FAIL (", why, ")"

# --------------------------------------------------------------- shared cfg ---

type Config = object
  rom0, rom1: string
  held: array[2, seq[set[Input]]]   # heldPerFrame[core][frame]
  frames: int
  shotdir: string
  shotEvery: int
  shots: bool
  delay: int

proc mk(rom: string): GBA =
  result = new_gba("", rom, run_bios = false, use_hle = true)
  result.post_init()
  result.enable_deterministic_rtc(1_700_000_000'i64)

proc shoot(cfg: Config; g0, g1: GBA; f: int) =
  if not cfg.shots: return
  if f mod cfg.shotEvery != 0 and f != cfg.frames: return
  dumpPPM(g0, cfg.shotdir / "c0_f" & align($f, 5, '0') & ".ppm")
  dumpPPM(g1, cfg.shotdir / "c1_f" & align($f, 5, '0') & ".ppm")

# ------------------------------------------------------------ path: lockstep --

proc runLockstep(cfg: Config): Verdict =
  result.path = "lockstep"
  let g0 = mk(cfg.rom0)
  let g1 = mk(cfg.rom1)
  let lnk = new_link(@[g0, g1])
  # Optional assertion: the multi-mode drain fix must leave zero coalescing
  # (an unserviced serial IRQ at the next transfer). Available under -d:linkTrace.
  var coalesce = 0
  when defined(linkTrace):
    onCoalesce = proc(core: int) = inc coalesce
  var cs: CommState
  var prev: array[2, set[Input]]
  for f in 0 ..< cfg.frames:
    for c in 0 .. 1:
      applyHeld(lnk.cores[c], prev[c], cfg.held[c][f]); prev[c] = cfg.held[c][f]
    lnk.step_frame()
    cs.observe(g0, f)
    shoot(cfg, g0, g1, f + 1)
  when defined(linkTrace):
    onCoalesce = nil
  result.reachedLink = cs.linkLive
  result.commError = cs.commError
  result.errFrame = cs.errFrame
  result.errKind = cs.errKind
  result.framesRun = cfg.frames
  result.summary = "frames=" & $cfg.frames & " coalesceEvents=" & $coalesce
  if coalesce != 0:
    result.summary.add " (WARN: expected 0 coalesce events)"

# ------------------------------------------------------------- path: netcore --

proc runNetcore(cfg: Config): Verdict =
  result.path = "netcore"
  let g0 = mk(cfg.rom0)
  let g1 = mk(cfg.rom1)
  let crc0 = crc32(readFile(cfg.rom0))
  let crc1 = crc32(readFile(cfg.rom1))
  # strict_crc=false is REQUIRED for cross-version (different CRCs, link-compatible).
  let nc0 = new_net_core(g0, 0, crc0, strict_crc = false)
  let nc1 = new_net_core(g1, 1, crc1, strict_crc = false)
  let cores = @[g0, g1]

  # In-flight message queues (deliver_at_step, frame_bytes) — like run_spec_link.
  var q01, q10: seq[(int, string)]
  var step = 0
  proc collect(src: NetCore; dst: var seq[(int, string)]) =
    let due = step + (if src.hello == hsDone and cfg.delay > 0: cfg.delay else: 0)
    for fr in src.take_outgoing(): dst.add((due, fr))
  proc deliver(q: var seq[(int, string)]; dst: NetCore) =
    var keep: seq[(int, string)]
    for (due, data) in q:
      if due <= step: dst.feed(data) else: keep.add((due, data))
    q = keep

  # Per-core nav cadence: before running frame k, hold heldPerFrame[c][k].
  var prev: array[2, set[Input]]
  var framedone: array[2, int]
  proc setHeld(c, f: int) =
    let nf = cfg.held[c][min(f, cfg.frames - 1)]
    applyHeld(cores[c], prev[c], nf); prev[c] = nf
  setHeld(0, 0); setHeld(1, 0)

  var cs: CommState
  var lastProgress = 0
  var iter = 0
  let cap = cfg.frames * 200 + 100_000
  const STUCK = 200_000
  while iter < cap:
    inc iter
    inc step
    deliver(q01, nc1)
    deliver(q10, nc0)
    let r0 = nc0.try_advance()
    collect(nc0, q01)
    let r1 = nc1.try_advance()
    collect(nc1, q10)
    if r1 == naFrame:
      inc framedone[1]; setHeld(1, framedone[1]); lastProgress = iter
    if r0 == naFrame:
      inc framedone[0]; setHeld(0, framedone[0]); lastProgress = iter
      cs.observe(g0, framedone[0])
      shoot(cfg, g0, g1, framedone[0])
    if framedone[0] >= cfg.frames and framedone[1] >= cfg.frames: break
    if iter - lastProgress > STUCK:
      result.deadlock = true
      break

  result.reachedLink = cs.linkLive
  result.commError = cs.commError
  result.errFrame = cs.errFrame
  result.errKind = cs.errKind
  result.framesRun = framedone[0]
  result.summary = "delay=" & $cfg.delay & " f0=" & $framedone[0] &
    " f1=" & $framedone[1] & " steps=" & $step &
    " stalls=" & $nc0.stall_count & "+" & $nc1.stall_count

# ------------------------------------------------------------ path: rollback --

proc runRollback(cfg: Config): Verdict =
  result.path = "rollback"
  let g0 = mk(cfg.rom0)
  let g1 = mk(cfg.rom1)
  let lnk = new_link(@[g0, g1])
  let sess = new_rollback_session(lnk, 0, max_ahead = max(12, cfg.delay + 6))
  # Precompute per-frame input masks: core 0 local (drives tick), core 1 remote.
  var p0 = newSeq[uint16](cfg.frames)
  var p1 = newSeq[uint16](cfg.frames)
  for f in 0 ..< cfg.frames:
    p0[f] = mask(cfg.held[0][f])
    p1[f] = mask(cfg.held[1][f])

  var coalesce = 0
  when defined(linkTrace):
    onCoalesce = proc(core: int) = inc coalesce

  var cs: CommState
  var fedUpTo = -1
  var steps = 0
  let stepCap = cfg.frames * 4 + 1000
  while sess.confirmed < cfg.frames - 1 and steps < stepCap:
    inc steps
    if sess.head < cfg.frames:
      let stt = sess.tick(p0[sess.head])
      if stt == rbStalled:
        if fedUpTo + 1 < cfg.frames:
          inc fedUpTo
          sess.feed_remote(fedUpTo, p1[fedUpTo])
        continue
    # Release remote inputs DELAY frames behind the local head.
    let due = if sess.head < cfg.frames: sess.head - 1 - cfg.delay else: cfg.frames - 1
    while fedUpTo < due and fedUpTo + 1 < cfg.frames:
      inc fedUpTo
      sess.feed_remote(fedUpTo, p1[fedUpTo])
    let cf = sess.head - 1
    if cf >= 0:
      cs.observe(g0, cf)
      if (cf + 1) mod cfg.shotEvery == 0: shoot(cfg, g0, g1, cf + 1)

  when defined(linkTrace):
    onCoalesce = nil
  # Deadlock: ran out of the step budget before every frame confirmed.
  result.deadlock = sess.confirmed < cfg.frames - 1
  result.reachedLink = cs.linkLive
  result.commError = cs.commError
  result.errFrame = cs.errFrame
  result.errKind = cs.errKind
  result.framesRun = sess.head
  result.summary = "delay=" & $cfg.delay & " head=" & $sess.head &
    " confirmed=" & $sess.confirmed & " rollbacks=" & $sess.rollbacks &
    " stalls=" & $sess.stalls & " coalesceEvents=" & $coalesce
  if coalesce != 0:
    result.summary.add " (WARN: expected 0 coalesce events)"

# ---------------------------------------------------------------------- main --

when isMainModule:
  var pathSel = getEnv("TRADE_PATH")
  # env PATH is only honoured if it happens to name a valid path (never the
  # system PATH), so the shell's PATH does not accidentally select a mode.
  if pathSel.len == 0 and getEnv("PATH") in ["lockstep", "netcore", "rollback"]:
    pathSel = getEnv("PATH")
  var pos: seq[string]
  var delay = 0
  var shotEvery = 300
  var shots = true
  for a in commandLineParams():
    if a.startsWith("--path="): pathSel = a[7 .. ^1]
    elif a.startsWith("--delay="): delay = parseInt(a[8 .. ^1])
    elif a.startsWith("--shots="): shotEvery = parseInt(a[8 .. ^1])
    elif a == "--no-shots": shots = false
    elif a.startsWith("--"):
      echo "unknown flag: ", a
      quit 1
    else: pos.add a

  if pos.len < 5 or pathSel notin ["lockstep", "netcore", "rollback"]:
    echo "usage: trade_repro --path=<lockstep|netcore|rollback> " &
      "<fr.gba> <em.gba> <nav.txt> <frames> <shotdir> [--delay=N] [--shots=N] [--no-shots]"
    quit 1

  var cfg = Config(
    rom0: pos[0], rom1: pos[1],
    frames: parseInt(pos[3]),
    shotdir: pos[4],
    shotEvery: shotEvery, shots: shots, delay: delay)
  cfg.held = expandHeld(loadScript(pos[2]), cfg.frames)
  if cfg.shots: createDir(cfg.shotdir)

  echo "trade_repro path=", pathSel, " frames=", cfg.frames,
    " delay=", cfg.delay, " fr=", cfg.rom0, " em=", cfg.rom1
  let v =
    case pathSel
    of "lockstep": runLockstep(cfg)
    of "netcore": runNetcore(cfg)
    else: runRollback(cfg)
  report(v)
  quit(if v.pass: 0 else: 1)
