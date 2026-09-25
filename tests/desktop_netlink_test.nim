## The desktop Link Cable over real loopback sockets
## (src/dingbat/frontend/link_cable.nim, src/dingbat/gba/netlink.nim), with a
## scripted peer: a raw socket speaking linkproto, so each case controls
## exactly what the other side sends. Guards formal/DESKTOP-FINDINGS.md 7, 8,
## 11, 20, 21, the Low link items, and that nothing in pairing waits on the
## network (--listen, the HELLO handshake, a connect). No GUI; linktest.gba
## is the core.

import std/[net, nativesockets, monotimes, times, strutils]
import dingbat/gba/[gba, netlink]
import dingbat/frontend/link_cable

when defined(windows):
  # The app runs under SDL, which raises the system timer to 1 ms
  # (SDL_HINT_TIMER_RESOLUTION); without it a 1 ms socket wait lasts a
  # whole 15.6 ms tick, and the one-thread pairing below crawls.
  proc timeBeginPeriod(ms: cuint): cuint {.stdcall, dynlib: "winmm", importc.}
  discard timeBeginPeriod(1)

var failures = 0

proc check(cond: bool; msg: string) =
  if cond:
    echo "  [PASS] ", msg
  else:
    echo "  [FAIL] ", msg
    failures.inc

const ROM = "tests/roms/linktest.gba"
# Ports away from LINK_DEFAULT_PORT, so a running dingbat is not disturbed.
const BASE_PORT = 47930

proc new_core(): GBA =
  result = new_gba("", ROM, run_bios = false, use_hle = true)
  result.post_init()

proc ms_since(t: MonoTime): int64 = (getMonoTime() - t).inMilliseconds

# ---- the scripted peer ----

type Peer = object
  sock: Socket
  dec: LinkDecoder

proc send(p: Peer; data: string) = p.sock.send(data)

proc hello(p: Peer) = p.send(encode_hello(LINK_SYSTEM_GBA, 1, 0))

proc clock(p: Peer; clock: int64; mode = LINK_MODE_NORMAL8; flags = 0'u8) =
  p.send(encode_clock(clock, mode, flags))

proc read_msgs(p: var Peer; wait_ms: int): seq[LinkMsg] =
  ## Everything the peer received within wait_ms (stops early at EOF).
  let t0 = getMonoTime()
  while ms_since(t0) < wait_ms:
    var fds = @[p.sock.getFd()]
    if selectRead(fds, 10) <= 0: continue
    var buf: array[4096, char]
    let n = p.sock.recv(addr buf[0], buf.len)
    if n <= 0: break
    p.dec.feed(buf.toOpenArray(0, n - 1))
  var m: LinkMsg
  while p.dec.next(m): result.add m

proc connect_peer(port: int): Peer =
  result.sock = newSocket(buffered = false)
  result.sock.connect("127.0.0.1", Port(port))

proc host_and_pair(lc: var LinkCable; gba: GBA; port: int): (NetLink, Peer) =
  ## `lc` hosts on `port`; the peer connects and sends its HELLO, and lc
  ## accepts and finishes the handshake over the next few iterations.
  lc.port = cint(port)
  lc.start_host(ready = true)
  var peer = connect_peer(port)
  peer.hello()
  var nl: NetLink
  let t0 = getMonoTime()
  while nl == nil and ms_since(t0) < 2000:
    nl = lc.service_setup(gba, ROM, link_now_ms())
  (nl, peer)

# ---- 8: a malformed frame after the handshake ----

block:
  echo "8: a malformed frame from the peer ends the link, not the app"
  var lc = init_link_cable()
  let gba = new_core()
  var (nl, peer) = host_and_pair(lc, gba, BASE_PORT)
  check nl != nil, "paired with the scripted peer"
  peer.send("\x00\x00\x00\x00")  # payload length 0: not a legal frame
  var raised = ""
  try:
    for _ in 0 ..< 200:
      discard nl.step_frame_for(20)
  except NetLinkError as e:
    raised = "NetLinkError: " & e.msg
  except CatchableError as e:
    raised = "other " & $e.name & ": " & e.msg
  check raised.startsWith("NetLinkError"),
        "the bad frame raises NetLinkError, which the main loop catches (got " &
        raised & ")"
  lc.teardown(nl, "test")
  peer.sock.close()

# ---- 11: a paused peer is not a lost one; waiting never blocks the loop ----

block:
  echo "11: pausing freezes neither window, and never times the link out"
  var lc = init_link_cable()
  let gba = new_core()
  var (nl, peer) = host_and_pair(lc, gba, BASE_PORT + 1)
  check nl != nil, "paired with the scripted peer"
  # The peer's clock stays at 0: a frame waiting on it hands back to the
  # loop (input, drawing) instead of blocking until the stall clock ends.
  peer.clock(0)
  nl.stall_timeout_ms = 2000
  var worst = 0'i64
  var lost = false
  var c0 = getMonoTime()
  try:
    for _ in 0 ..< 5:
      c0 = getMonoTime()
      discard nl.step_frame_for(20)
      worst = max(worst, ms_since(c0))
  except NetLinkError:
    lost = true
    worst = max(worst, ms_since(c0))
  check not lost and worst < 200,
        "a stalled frame hands back to the loop (longest call " & $worst &
        " ms, budget 20)"
  # Now it says it paused. (Skipped if the frame blocks: that would hang.)
  nl.stall_timeout_ms = 300
  peer.clock(0, flags = LINK_CLOCK_PAUSED)
  let t0 = getMonoTime()
  try:
    while worst < 200 and ms_since(t0) < 1000:
      discard nl.step_frame_for(20)
  except NetLinkError:
    lost = true
  check not lost, "a peer paused for 1 s (over 3x the stall timeout) keeps the link"
  check nl.peer_paused, "the window can say the other player paused"
  # The peer resumes but never advances: now it is a lost peer.
  peer.clock(0)
  let t1 = getMonoTime()
  try:
    while ms_since(t1) < 3000:
      discard nl.step_frame_for(20)
  except NetLinkError:
    lost = true
  check lost and ms_since(t1) < 2000,
        "a resumed peer that stops answering still times out (" &
        $ms_since(t1) & " ms)"
  discard peer.read_msgs(50)  # drain what the host sent so far
  # This side's pause reaches the peer as CLOCK's paused bit.
  var (nl2, peer2) = host_and_pair(lc, new_core(), BASE_PORT + 2)
  discard peer2.read_msgs(100)
  nl2.set_paused(true)
  var got_paused = false
  for m in peer2.read_msgs(200):
    if m.kind == lmClock and (m.flags and LINK_CLOCK_PAUSED) != 0: got_paused = true
  check got_paused, "pausing sends a CLOCK with the paused bit"
  nl2.set_paused(false)
  var got_resumed = false
  for m in peer2.read_msgs(200):
    if m.kind == lmClock and (m.flags and LINK_CLOCK_PAUSED) == 0: got_resumed = true
  check got_resumed, "resuming sends a CLOCK without it"
  lc.teardown(nl, "")
  lc.teardown(nl2, "")
  peer.sock.close()
  peer2.sock.close()

# ---- 20: an exchange parked on a lost peer completes; BYE is sent ----

block:
  echo "20: ending the link mid-exchange unplugs the cable cleanly"
  var lc = init_link_cable()
  let gba = new_core()
  var (nl, peer) = host_and_pair(lc, gba, BASE_PORT + 3)
  check nl != nil, "paired with the scripted peer"
  # The peer is in multi mode and far ahead (no lead stall), and never
  # answers a TRANSFER: the parent's first round parks at S+D.
  peer.clock(high(int32).int64, mode = LINK_MODE_MULTI)
  let t0 = getMonoTime()
  while ms_since(t0) < 3000:
    if not nl.step_frame_for(20) and nl.stalled: break
  let busy_before = (gba.serial.siocnt and 0x80) != 0
  check nl.stalled and busy_before,
        "the parent's transfer is parked waiting for the REPLY (SIOCNT busy)"
  lc.teardown(nl, "peer connection lost")
  check nl == nil, "the link is gone"
  check (gba.serial.siocnt and 0x80) == 0,
        "the parked transfer completed as a pulled cable (SIOCNT not busy)"
  check lc.status.startsWith("Link ended: "),
        "the window says the link ended (" & lc.status & ")"
  var got_bye = false
  for m in peer.read_msgs(200):
    if m.kind == lmBye: got_bye = true
  check got_bye, "the peer got a BYE"
  peer.sock.close()

# ---- 7 and the ROM-file case: begin_handshake refuses rather than crash ----

block:
  echo "7: begin_handshake with no GBA core, or the ROM file gone"
  var lc = init_link_cable()
  let server = newSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(BASE_PORT + 4))
  server.listen()
  var a = newSocket(buffered = false)
  a.connect("127.0.0.1", Port(BASE_PORT + 4))
  var b: Socket
  server.accept(b)
  lc.auto = true
  lc.begin_handshake(a, 1, nil, ROM)
  check lc.setup == lsNone and lc.service_setup(nil, ROM, 0) == nil,
        "no GBA core (a GB game is loaded): refused, no crash"
  check not lc.auto, "auto-pairing stopped, so the window shows why"
  b.close()
  var c = newSocket(buffered = false)
  c.connect("127.0.0.1", Port(BASE_PORT + 4))
  var d: Socket
  server.accept(d)
  lc.begin_handshake(c, 1, new_core(), "/nonexistent/moved.gba")
  check lc.setup == lsNone and lc.status.startsWith("Handshake failed"),
        "ROM file moved away: refused with a status line, no crash"
  d.close()
  server.close()
  # Setup that outlives its GBA game is dropped, not handed a nil core.
  var lc2 = init_link_cable()
  lc2.port = cint(BASE_PORT + 5)
  lc2.start_host(ready = true)
  var e = connect_peer(BASE_PORT + 5)
  e.hello()
  check lc2.service_setup(nil, "", 0) == nil and lc2.setup == lsNone,
        "a pending Host with a GB game loaded is cancelled"
  e.sock.close()

# ---- 21: retries count wall time, not loop iterations ----

block:
  echo "21: connect retries are paced by wall time"
  var lc = init_link_cable()
  lc.port = cint(BASE_PORT + 6)  # nothing listens here
  lc.start_join(ready = true)
  let gba = new_core()
  for _ in 0 ..< 1000:
    discard lc.service_setup(gba, ROM, 0)
  check lc.probes == 1, "1000 iterations in the same millisecond make one attempt (" &
        $lc.probes & ")"
  check lc.setup == lsConnecting, "and a Join is still trying"
  discard lc.service_setup(gba, ROM, LINK_PROBE_INTERVAL_MS - 1)
  discard lc.service_setup(gba, ROM, LINK_PROBE_INTERVAL_MS)
  when defined(windows):
    # Windows retries a refused localhost connect for about 2 s before
    # reporting it, so the first attempt may still be in flight here: the
    # pacing law is "no more than one attempt per interval".
    check lc.probes in 1 .. 2, "the next attempt waits LINK_PROBE_INTERVAL_MS (" &
          $lc.probes & ")"
  else:
    check lc.probes == 2, "the next attempt waits LINK_PROBE_INTERVAL_MS"
  discard lc.service_setup(gba, ROM, LINK_JOIN_GIVE_UP_MS - 1)
  check lc.setup == lsConnecting, "Join keeps trying for its five seconds"
  discard lc.service_setup(gba, ROM, LINK_JOIN_GIVE_UP_MS)
  check lc.setup == lsNone and lc.status.startsWith("Couldn't reach"),
        "and then gives up with a status line"
  # Auto-pair: three refused probes (~0.5 s), then host.
  var la = init_link_cable()
  la.auto_port = BASE_PORT + 7
  la.auto_start(ready = true, linked = false)
  var t = 0'i64
  for _ in 0 ..< 100:
    discard la.service_setup(gba, ROM, t)
  check la.setup == lsConnecting, "auto-pair does not host after 100 same-ms iterations"
  while la.setup == lsConnecting and t < 2000:
    t += 10
    discard la.service_setup(gba, ROM, t)
  check la.setup == lsListening and t >= 2 * LINK_PROBE_INTERVAL_MS,
        "auto-pair hosts after " & $LINK_AUTO_CONNECT_TRIES & " probes (" & $t & " ms)"
  la.auto_stop()

# ---- Low: auto probes 127.0.0.1; a failed auto handshake is shown ----

block:
  echo "Low: auto-pair probes 127.0.0.1 and reports a failed handshake"
  let listener = newSocket(buffered = false)
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(BASE_PORT + 8))
  listener.listen()
  var lc = init_link_cable()
  lc.auto_port = BASE_PORT + 8
  lc.hello_timeout_ms = 300
  const typed = "256.1.1.1"  # what an earlier Join left in the box
  for i, c in typed: lc.host_buf[i] = c
  lc.update_auto(window = true, ready = true, linked = false)
  check lc.auto and lc.setup == lsConnecting, "opening the window starts auto-pairing"
  # The listener never sends HELLO: the handshake times out.
  let gba = new_core()
  var nl: NetLink
  let t0 = getMonoTime()
  while nl == nil and lc.setup != lsNone and ms_since(t0) < 3000:
    nl = lc.service_setup(gba, ROM, ms_since(t0))
  var fds = @[listener.getFd()]
  check selectRead(fds, 0) > 0, "the probe went to 127.0.0.1, not the Join box's address"
  check nl == nil and not lc.auto and lc.status.startsWith("Handshake failed"),
        "the failed handshake ends auto-pairing with a reason, not \"Waiting to pair...\""
  listener.close()

# ---- Low: a closed window hosts nothing ----

block:
  echo "Low: closing the window stops a manual Host"
  var lc = init_link_cable()
  lc.auto_port = BASE_PORT + 11
  lc.update_auto(window = true, ready = true, linked = false)
  lc.auto_stop(); lc.cancel_setup()
  lc.port = cint(BASE_PORT + 9)
  lc.start_host(ready = true)
  check lc.setup == lsListening, "Advanced > Host game listens"
  lc.update_auto(window = false, ready = true, linked = false)
  check lc.setup == lsNone, "closing the window ends the Host"
  let probe = newSocket(buffered = false)
  var freed = true
  try:
    probe.setSockOpt(OptReuseAddr, true)
    probe.bindAddr(Port(BASE_PORT + 9))
    probe.listen()
  except OSError:
    freed = false
  probe.close()
  check freed, "and its listening socket is closed"

# ---- Low: re-pairing right after a session (TIME_WAIT) ----

block:
  echo "Low: auto-pair can host again right after a session"
  var lc = init_link_cable()
  lc.auto_port = BASE_PORT + 10
  lc.hello_timeout_ms = 2000
  let gba = new_core()
  lc.auto_start(ready = true, linked = false)
  var t = 0'i64
  while lc.setup == lsConnecting and t < 2000:
    t += LINK_PROBE_INTERVAL_MS
    discard lc.service_setup(gba, ROM, t)
  check lc.setup == lsListening, "auto-pair hosts"
  # A second listener on the port is still refused: the race breaker.
  let rival = newSocket(buffered = false)
  var rival_bound = true
  try:
    rival.setSockOpt(OptReuseAddr, true)
    rival.bindAddr(Port(BASE_PORT + 10))
    rival.listen()
  except OSError:
    rival_bound = false
  rival.close()
  check not rival_bound, "a second listener on the auto port is refused"
  var peer = connect_peer(BASE_PORT + 10)
  peer.hello()
  var nl: NetLink
  while nl == nil and t < 4000:
    t += 10
    nl = lc.service_setup(gba, ROM, t)
  check nl != nil, "the peer paired"
  # The host closes first, so its end of the port sits in TIME_WAIT.
  lc.teardown(nl, "")
  peer.sock.close()
  lc.auto_start(ready = true, linked = false)
  let t_end = t + 2000
  while lc.setup == lsConnecting and t < t_end:
    t += LINK_PROBE_INTERVAL_MS
    discard lc.service_setup(gba, ROM, t)
  when not defined(windows):
    # Measured on macOS (SO_REUSEADDR). Windows binds with
    # SO_EXCLUSIVEADDRUSE instead, whose TIME_WAIT rules are not measured.
    check lc.setup == lsListening, "and hosts again at once, TIME_WAIT or not"
  lc.auto_stop()

# ---- nothing in pairing waits on the network ----

proc silent_listener(port: int): Socket =
  ## A host that accepts (the kernel does) but never says HELLO.
  result = newSocket(buffered = false)
  result.setSockOpt(OptReuseAddr, true)
  result.bindAddr(Port(port))
  result.listen()

proc join(lc: var LinkCable; port: int) =
  lc.set_join_host("127.0.0.1")
  lc.port = cint(port)
  lc.start_join(ready = true)

block:
  echo "Open: a peer that never answers HELLO does not stop the loop"
  let listener = silent_listener(BASE_PORT + 12)
  var lc = init_link_cable()
  lc.hello_timeout_ms = 600
  let gba = new_core()
  lc.join(BASE_PORT + 12)
  var nl: NetLink
  var worst = 0'i64
  var saw_handshake = false
  var plugged = false
  let t0 = getMonoTime()
  while nl == nil and lc.setup != lsNone and ms_since(t0) < 5000:
    let c0 = getMonoTime()
    nl = lc.service_setup(gba, ROM, ms_since(t0))
    worst = max(worst, ms_since(c0))
    if lc.setup == lsHandshake:
      saw_handshake = true
      # The game keeps running single-player meanwhile, on its own cable.
      gba.run_until_frame()
      if gba.serial.driver of RemoteSioDriver: plugged = true
  let took = ms_since(t0)
  check saw_handshake, "connected, then waited for the HELLO in its own phase"
  check worst < 100, "no call waited on the peer (longest " & $worst & " ms)"
  check nl == nil and lc.setup == lsNone and
        lc.status.startsWith("Handshake failed") and
        "timed out" in lc.status,
        "gave up with a reason (" & lc.status & ")"
  check took >= 600 and took < 2000,
        "at the handshake's deadline, counted in wall time (" & $took & " ms)"
  check not plugged and not (gba.serial.driver of RemoteSioDriver),
        "the game ran on its own cable throughout: the link never plugged in"
  listener.close()

block:
  echo "Open: Cancel, closing the window, or another game end a handshake"
  let listener = silent_listener(BASE_PORT + 13)
  let gba = new_core()
  for how in ["Cancel", "window closed", "another game"]:
    var lc = init_link_cable()
    lc.join(BASE_PORT + 13)
    let t0 = getMonoTime()
    while lc.setup != lsHandshake and ms_since(t0) < 2000:
      discard lc.service_setup(gba, ROM, ms_since(t0))
    var peer: Peer
    listener.accept(peer.sock)
    case how
    of "Cancel": lc.cancel_setup()
    of "window closed":
      lc.update_auto(window = true, ready = true, linked = false)
      lc.update_auto(window = false, ready = true, linked = false)
    else: discard lc.service_setup(new_core(), ROM, ms_since(t0))
    check lc.setup == lsNone and lc.service_setup(gba, ROM, ms_since(t0)) == nil,
          how & ": the handshake is over"
    var kinds: seq[LinkMsgKind]
    for m in peer.read_msgs(300): kinds.add m.kind
    check kinds == @[lmHello, lmBye],
          how & ": the peer got our HELLO, then a BYE (" & $kinds & ")"
    var fds = @[peer.sock.getFd()]
    var buf: array[16, char]
    check selectRead(fds, 200) > 0 and peer.sock.recv(addr buf[0], buf.len) == 0,
          how & ": and the socket is closed"
    peer.sock.close()
  listener.close()

block:
  echo "Open: a Join to a host that drops SYNs does not stop the loop"
  # A listener whose backlog is full: the kernel drops further SYNs, as a
  # firewalled or vanished host does, so a connect gets no answer at all.
  let full = newSocket(buffered = false)
  full.setSockOpt(OptReuseAddr, true)
  full.bindAddr(Port(BASE_PORT + 14))
  full.listen(1)
  var fill: seq[Socket]
  var blackhole = false
  for _ in 0 ..< 32:
    let s = newSocket(buffered = false)
    try:
      s.connect("127.0.0.1", Port(BASE_PORT + 14), timeout = 200)
      fill.add s
    except TimeoutError:
      s.close()
      blackhole = true
      break
    except OSError:
      s.close()
      break
  if not blackhole:
    echo "  (this OS refuses rather than drops a SYN to a full backlog: skipped)"
  else:
    var lc = init_link_cable()
    lc.join(BASE_PORT + 14)
    let gba = new_core()
    var worst = 0'i64
    var t = 0'i64
    let t0 = getMonoTime()
    while lc.setup == lsConnecting and ms_since(t0) < 3000:
      let c0 = getMonoTime()
      discard lc.service_setup(gba, ROM, t)
      worst = max(worst, ms_since(c0))
      t += 50  # the Join's give-up clock, fast-forwarded
    check worst < 100, "no call waited on the unanswered connect (longest " &
          $worst & " ms)"
    check lc.setup == lsNone and lc.status.startsWith("Couldn't reach"),
          "and the Join gave up after its " & $LINK_JOIN_GIVE_UP_MS &
          " ms with a reason (" & lc.status & ")"
  for s in fill: s.close()
  full.close()

block:
  echo "Open: --listen and --connect start at once; the loop pairs them"
  var host = init_link_cable()
  var guest = init_link_cable()
  let t0 = getMonoTime()
  check host.start_cli(BASE_PORT + 15, "", ready = true) and
        guest.start_cli(0, "127.0.0.1:" & $(BASE_PORT + 15), ready = true),
        "both open the window on their status"
  check ms_since(t0) < 100 and host.setup == lsListening and
        guest.setup == lsConnecting,
        "--listen hosts and --connect joins without waiting for the peer (" &
        $ms_since(t0) & " ms)"
  check guest.join_host() == "127.0.0.1" and int(guest.port) == BASE_PORT + 15,
        "--connect fills the Join box"
  # One thread, both windows' loops interleaved: only possible when neither
  # the accept, the connect nor the handshake waits on the other side.
  let ga = new_core()
  let gb = new_core()
  var la, lb: NetLink
  var worst = 0'i64
  while (la == nil or lb == nil) and ms_since(t0) < 5000:
    let c0 = getMonoTime()
    if la == nil: la = host.service_setup(ga, ROM, ms_since(t0))
    if lb == nil: lb = guest.service_setup(gb, ROM, ms_since(t0))
    worst = max(worst, ms_since(c0))
  check la != nil and lb != nil and la.id == 0 and lb.id == 1,
        "the two paired as host and guest"
  check worst < 100, "no iteration waited on the other (longest " & $worst & " ms)"
  check ga.serial.driver of RemoteSioDriver and gb.serial.driver of RemoteSioDriver,
        "both cores now talk through the link"
  var frames = 0
  let t1 = getMonoTime()
  while frames < 30 and ms_since(t1) < 5000:
    if la.step_frame_for(8): inc frames
    discard lb.step_frame_for(8)
  check frames == 30, "and the link runs frames (" & $frames & " in " &
        $ms_since(t1) & " ms)"
  host.teardown(la, "")
  guest.teardown(lb, "")
  var bad = init_link_cable()
  check not bad.start_cli(BASE_PORT + 16, "", ready = false) and bad.setup == lsNone,
        "a GB game: no link, the game runs single-player"
  check bad.start_cli(0, "host:x", ready = true) and bad.setup == lsNone and
        bad.status.startsWith("--connect wants HOST:PORT"),
        "a bad --connect is shown in the window, not a crash"

# ---- Low: --connect HOST:x ----

block:
  echo "Low: --connect parsing"
  check not parse_host_port("host:x").ok, "a non-numeric port is refused, not a crash"
  check not parse_host_port("host").ok, "no colon is refused"
  check not parse_host_port("host:70000").ok, "an out-of-range port is refused"
  let r = parse_host_port("10.0.0.2:47810")
  check r.ok and r.host == "10.0.0.2" and r.port == 47810, "HOST:PORT parses"

if failures > 0:
  echo failures, " check(s) failed"
  quit(1)
echo "ok"
