## The desktop's online link (src/dingbat/frontend/online_link.nim) between
## two links in this process, over real WebRTC data channels and a local
## signaling server (web/signaling/server.js, so node must be on PATH).
## Each side's game is its own solo core, snapshotted as the app would.
## Checks: pairing, the rollback cores agreeing bit for bit, the link itself
## working through them (attachtest.gba's rounds), a cross-game ROM
## transfer, a dropped connection resuming, Disconnect handing each player
## back a solo core, and a Game Boy pair.

import std/[os, osproc, monotimes, times, net, strutils, random]
import dingbat/gba/gba
import dingbat/gb/gb
import dingbat/frontend/online_link

var failures = 0

proc check(cond: bool; msg: string) =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg
    failures.inc

proc now_ms(): int64 = getMonoTime().ticks div 1_000_000

const
  ATTACH_ROM = "tests/roms/attachtest.gba"
  GB_ROM = "tests/roms/gblinktest.gb"
  ROUNDS = 16

proc ew16(g: GBA; offset: int): uint16 =
  uint16(g.bus.wram_board[offset]) or (uint16(g.bus.wram_board[offset + 1]) shl 8)

proc rounds_ok(g: GBA): bool =
  ## attachtest.gba's EWRAM contract (tests/roms/attachtest.s): done mark,
  ## and every round's two receive latches.
  if g.ew16(0x800) != 0xCAFE'u16: return false
  for k in 0 ..< ROUNDS:
    if g.ew16(k * 2) != (0xA000'u16 or uint16(k)): return false
    if g.ew16(0x400 + k * 2) != (0xB000'u16 or uint16(k)): return false
  true

type Side = ref object
  name: string
  rom: string
  solo_gba: GBA
  solo_gb: GB
  ol: OnlineLink
  started, ended: int
  paused, double: bool
  rng: Rand
  bits: uint16

proc make_side(name, rom, tmp: string; port: int): Side =
  let s = Side(name: name, rom: rom, rng: initRand(ord(name[0]) * 7919))
  if rom.endsWith(".gb"):
    s.solo_gb = new_gb("", rom, true, false)
    s.solo_gb.post_init()
    for i in 0 ..< 20: s.solo_gb.run_until_frame()
  else:
    s.solo_gba = new_gba("", rom, false, true, false)
    s.solo_gba.post_init()
    for i in 0 ..< 20: s.solo_gba.run_until_frame()
  var hooks: OnlineHooks
  hooks.now_ms = now_ms
  hooks.log = proc(m: string) = echo "    ", name, ": ", m
  hooks.capture = proc(): tuple[rom_path, state: string] =
    if s.solo_gb != nil: (s.rom, s.solo_gb.state_bytes())
    else: (s.rom, s.solo_gba.state_bytes())
  hooks.make_gba = proc(p: string): GBA =
    result = new_gba("", p, false, true, false)
    result.post_init()
  hooks.make_gb = proc(p: string): GB =
    result = new_gb("", p, true, false)
    result.post_init()
  hooks.started = proc() = inc s.started
  hooks.ended = proc() =
    inc s.ended
    let (a, b) = s.ol.take_solo()
    if a != nil: s.solo_gba = a
    if b != nil: s.solo_gb = b
  hooks.remote_pause = proc(on: bool) = s.paused = on
  hooks.remote_speed = proc(on: bool) = s.double = on
  hooks.paused = proc(): bool = s.paused
  hooks.double = proc(): bool = s.double
  hooks.away = proc(): bool = false
  s.ol = new_online_link(hooks, tmp / name / "cache", tmp / name / "live.json",
                         "ws://127.0.0.1:" & $port)
  s

proc service(sides: openArray[Side]) =
  for s in sides: s.ol.service()

proc wait_until(sides: openArray[Side]; ms: int; cond: proc(): bool): bool =
  let t0 = now_ms()
  while now_ms() - t0 < ms:
    sides.service()
    if cond(): return true
    sleep(2)
  false

proc pair(a, b: Side; code: string): bool =
  a.ol.connect(code)
  b.ol.connect(code)
  wait_until([a, b], 20000, proc(): bool = a.ol.started and b.ol.started)

proc run_frames(a, b: Side; n: int; ms = 60000): bool =
  ## Both sides to frame `n` with random buttons, then until each has the
  ## other's every input: the two pairs of cores are then in the same state.
  let t0 = now_ms()
  while now_ms() - t0 < ms:
    for s in [a, b]:
      if s.ol.started and s.ol.head < n:
        # New buttons every frame: nearly every frame rolls back.
        discard s.ol.tick(uint16(s.rng.rand(0x3ff)))
    [a, b].service()
    if a.ol.head >= n and b.ol.head >= n and
       a.ol.confirmed >= n - 1 and b.ol.confirmed >= n - 1:
      return true
    sleep(1)
  false

proc start_server(port: int): Process =
  result = startProcess("node", args = ["web/signaling/server.js", $port],
                        options = {poUsePath, poParentStreams})
  for i in 0 ..< 100:
    try:
      let sock = newSocket()
      sock.connect("127.0.0.1", Port(port), 200)
      sock.close()
      return
    except CatchableError:
      sleep(50)
  raise newException(IOError, "signaling server didn't start")

proc main() =
  doAssert net_init()
  randomize()
  let port = 20000 + rand(20000)
  let tmp = getTempDir() / ("dingbat-online-test-" & $getCurrentProcessId())
  removeDir(tmp)
  createDir(tmp)
  let server = start_server(port)
  defer:
    server.terminate()
    discard server.waitForExit()
    server.close()
    removeDir(tmp)

  echo "== same game: pairing, rollback agreement, the link through it =="
  block:
    let a = make_side("a", ATTACH_ROM, tmp, port)
    let b = make_side("b", ATTACH_ROM, tmp, port)
    check pair(a, b, "SAME" & $port), "both sides paired and started"
    check a.started == 1 and b.started == 1, "started once each"
    check a.ol.rb_local != b.ol.rb_local, "one side hosts, the other joins"
    check run_frames(a, b, 600), "600 frames confirmed on both sides"
    check a.ol.checksum() == b.ol.checksum(), "both sides' cores agree"
    check rounds_ok(a.ol.rb_gba.link.cores[0]) and rounds_ok(a.ol.rb_gba.link.cores[1]),
      "attachtest rounds completed over the rollback link"
    let before = a.ol.transfers
    check before > 0, "the cable carried transfers (" & $before & ")"

    echo "== a dropped connection resumes =="
    let dropped_head = a.ol.head
    a.ol.debug_drop()
    check wait_until([a, b], 30000, proc(): bool =
      not a.ol.reconnecting and not b.ol.reconnecting and a.ol.started and b.ol.started),
      "both sides reconnected"
    check run_frames(a, b, dropped_head + 300), "300 more frames confirmed after the resume"
    check a.ol.checksum() == b.ol.checksum(), "still in agreement after the resume"

    echo "== Disconnect hands each player back a solo core =="
    a.ol.disconnect()
    check wait_until([a, b], 10000, proc(): bool = not b.ol.active), "the friend saw the BYE"
    check a.ended == 1 and b.ended == 1, "both sides ended once"
    check a.solo_gba != nil and b.solo_gba != nil and not a.ol.rb_active and
          not b.ol.rb_active, "each side keeps its own core"
    var told = false
    for t in b.ol.toasts:
      if "Your friend disconnected" in t: told = true
    check told, "the friend was told why"
    check not fileExists(tmp / "a" / "live.json") and not fileExists(tmp / "b" / "live.json"),
      "no relaunch goodbye left behind"

  echo "== cross-game: each side's ROM crosses =="
  block:
    let other = tmp / "other" / "attachtest-b.gba"
    createDir(other.parentDir)
    writeFile(other, readFile(ATTACH_ROM) & "\xff\xff\xff\xff")
    let a = make_side("c", ATTACH_ROM, tmp, port)
    let b = make_side("d", other, tmp, port)
    check pair(a, b, "CROSS" & $port), "cross-game pair started"
    check fileExists(tmp / "c" / "cache" / ("rbrom" & $(1 - a.ol.rb_local) & ".gba")),
      "the friend's ROM was written to the cache"
    check readFile(tmp / "c" / "cache" / ("rbrom" & $(1 - a.ol.rb_local) & ".gba")).len ==
          readFile(other).len, "it is the friend's game, not ours"
    check run_frames(a, b, 300), "300 frames confirmed"
    check a.ol.checksum() == b.ol.checksum(), "cross-game cores agree"
    b.ol.disconnect()
    discard wait_until([a, b], 10000, proc(): bool = not a.ol.active)

  echo "== Game Boy =="
  block:
    let a = make_side("e", GB_ROM, tmp, port)
    let b = make_side("f", GB_ROM, tmp, port)
    check pair(a, b, "GAMEBOY" & $port), "GB pair started"
    check run_frames(a, b, 600), "600 GB frames confirmed"
    check a.ol.checksum() == b.ol.checksum(), "GB cores agree"
    a.ol.disconnect()
    check wait_until([a, b], 10000, proc(): bool = not b.ol.active), "GB friend saw the BYE"
    check a.solo_gb != nil and b.solo_gb != nil, "GB solo cores back"

  echo "== the idle window: only once the cable has carried traffic =="
  block:
    # A server of its own: the server takes 10 rendezvous a minute per IP.
    let port = port + 1
    let server = start_server(port)
    defer:
      server.terminate()
      discard server.waitForExit()
      server.close()
    proc play(sides: openArray[Side]; ms: int): bool =
      ## Both play (held buttons) for `ms`; false once either session ended.
      let t0 = now_ms()
      while now_ms() - t0 < ms:
        for s in sides:
          if s.ol.started: discard s.ol.tick(0)
          s.ol.watch_idle(running = true)
        sides.service()
        if not sides[0].ol.started or not sides[1].ol.started: return false
        sleep(16)
      true
    # attachtest.gba runs its 16 rounds, then leaves the cable quiet.
    let a = make_side("i", ATTACH_ROM, tmp, port)
    let b = make_side("j", ATTACH_ROM, tmp, port)
    check pair(a, b, "IDLE" & $port), "busy-then-quiet pair started"
    for s in [a, b]: s.ol.idle_limit = 3000
    check not play([a, b], 20000), "a cable that went quiet ended the link"
    var idled = false
    for t in a.ol.toasts & b.ol.toasts:
      if "Link idle" in t: idled = true
    check idled, "as the idle window, said so"
    check a.ol.transfers == 0 and b.ol.transfers == 0 and a.solo_gba != nil and b.solo_gba != nil,
      "both back on their own games"
    # linktest.gba settles its link roles at boot, unlinked: it never clocks
    # the cable once linked.
    let c = make_side("k", "tests/roms/linktest.gba", tmp, port)
    let d = make_side("l", "tests/roms/linktest.gba", tmp, port)
    check pair(c, d, "UNUSED" & $port), "never-used pair started"
    for s in [c, d]: s.ol.idle_limit = 3000
    check play([c, d], 6000), "a cable never used stays linked past the window"
    c.ol.disconnect()
    discard wait_until([c, d], 10000, proc(): bool = not d.ol.active)

  echo "== a bad code and an unreachable server fail in the window =="
  block:
    let a = make_side("g", ATTACH_ROM, tmp, port)
    a.ol.connect("x!")
    check a.ol.status_error and not a.ol.active, "a code under 3 characters is refused"
    let dead = new_online_link(a.ol.hooks, tmp / "h", "", "ws://127.0.0.1:1")
    dead.connect("NOSERVER")
    check wait_until([a], 10000, proc(): bool =
      dead.service(); dead.status_error), "no server: an error, not a hang"
    check "linking server" in dead.status, "it names the server (" & dead.status & ")"


main()  # returns first: its defer stops the signaling server
if failures > 0:
  echo failures, " FAILED"
  quit(1)
echo "ALL PASS"
