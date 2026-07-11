# TCP transport for the network link (phase 3a of docs/multiplayer.md):
# a socket pump around the transport-independent protocol state machine in
# gba/netcore.nim. All sync/stall/transfer logic lives there — this module
# only shuttles bytes, provides the blocking waits a native frontend wants
# (with timeouts), simulates latency (--netlink-delay-ms), and tears the
# connection down gracefully.
#
# STALL POINTS (frontends surface "waiting for peer"): stall_pump — every
# blocking wait funnels through it, driven by NetCore's `stalled` flag.

when defined(emscripten):
  {.error: "netlink needs std/net; the wasm build talks to a browser " &
           "bridge speaking the same linkproto wire format instead — see " &
           "the netlink_* exports in src/dingbat_wasm.nim".}

import std/[net, nativesockets, monotimes, times, os]
when not defined(windows):
  from std/posix import EAGAIN, EWOULDBLOCK, EINTR, SHUT_WR
  from std/posix as posix import nil
import netcore
import gba

export netcore

const
  STALL_TIMEOUT_MS = 30_000
    ## A single stall longer than this means the peer is gone; give up.
  HELLO_TIMEOUT_MS = 30_000

type
  NetLinkError* = object of CatchableError

  NetLink* = ref object
    core*: NetCore
    gba: GBA
    sock: Socket
    # Outgoing delay queue (--netlink-delay-ms latency simulation). Empty
    # and bypassed when delay_ms == 0.
    delay_ms: int
    outq: seq[tuple[due: MonoTime, data: string]]
    # Bytes released for sending but not yet accepted by the (nonblocking)
    # socket. We must NEVER block in send: with both sides emitting beacons,
    # two blocking sends into full kernel buffers deadlock the pair. Drained
    # opportunistically on every pump/flush.
    wire_out: string
    wire_pos: int

# Accessors kept from the pre-netcore API
proc id*(nl: NetLink): int = nl.core.id
proc peer_done*(nl: NetLink): bool = nl.core.peer_done
proc stalled*(nl: NetLink): bool = nl.core.stalled
proc stall_count*(nl: NetLink): int = nl.core.stall_count
proc send_bye*(nl: NetLink; reason = LINK_BYE_FINISHED) =
  nl.core.send_bye(reason)

# ---------------- wire helpers ----------------

proc is_transient(err: OSErrorCode): bool =
  when defined(windows):
    err.int32 == 10035  # WSAEWOULDBLOCK
  else:
    err.int32 == EAGAIN.int32 or err.int32 == EWOULDBLOCK.int32

proc try_drain(nl: NetLink) =
  ## Push as much of wire_out into the socket as it will take right now.
  while nl.wire_pos < nl.wire_out.len:
    let n = nl.sock.send(addr nl.wire_out[nl.wire_pos],
                         nl.wire_out.len - nl.wire_pos)
    if n > 0:
      nl.wire_pos += n
    else:
      let err = osLastError()
      when not defined(windows):
        if err.int32 == EINTR.int32: continue
      if err.is_transient(): break  # kernel buffer full; retry on next flush
      raise newException(NetLinkError, "peer connection lost: " & osErrorMsg(err))
  if nl.wire_pos >= nl.wire_out.len:
    nl.wire_out.setLen(0)
    nl.wire_pos = 0
  elif nl.wire_pos > 65536:
    nl.wire_out = nl.wire_out[nl.wire_pos .. ^1]
    nl.wire_pos = 0

proc flush_outgoing(nl: NetLink) =
  # Collect frames the core queued since the last flush, subjecting them to
  # the artificial delay (gameplay traffic only: the handshake is setup).
  for data in nl.core.take_outgoing():
    if nl.delay_ms <= 0 or nl.core.hello != hsDone:
      nl.wire_out.add data
    else:
      nl.outq.add((getMonoTime() + initDuration(milliseconds = nl.delay_ms),
                   data))
  if nl.outq.len > 0:
    let t = getMonoTime()
    var i = 0
    while i < nl.outq.len and nl.outq[i].due <= t:
      nl.wire_out.add nl.outq[i].data
      inc i
    if i > 0:
      nl.outq = nl.outq[i .. ^1]
  nl.try_drain()

# ---------------- receive pump ----------------

proc poll_socket(nl: NetLink; timeout_ms: int): bool =
  ## Pull whatever bytes are available into the protocol core, waiting up to
  ## timeout_ms for the first byte. Returns true if anything arrived.
  var fds = @[nl.sock.getFd()]
  if selectRead(fds, timeout_ms) <= 0: return false
  var buf: array[4096, char]
  let n = nl.sock.recv(addr buf[0], buf.len)
  if n < 0:
    if osLastError().is_transient(): return false  # select/recv race
    raise newException(NetLinkError,
      "peer connection lost: " & osErrorMsg(osLastError()))
  if n == 0:
    if nl.core.peer_done: return false  # orderly close after BYE
    raise newException(NetLinkError, "peer disconnected")
  nl.core.feed(buf.toOpenArray(0, n - 1))
  true

proc pump(nl: NetLink; timeout_ms = 0) =
  ## Nonblocking (timeout 0) or bounded-wait socket service: flush delayed
  ## sends, ingest bytes (the core dispatches every complete message —
  ## including latching a parked master completion), flush its responses.
  nl.flush_outgoing()
  discard nl.poll_socket(timeout_ms)
  nl.flush_outgoing()

# ---------------- frame loop ----------------

proc step_frame*(nl: NetLink) =
  ## Advance the local core one video frame, servicing the socket between
  ## slices. STALL POINT: when the core parks (peer lead exceeded, or a
  ## transfer completion waiting on the peer's REPLY) this blocks — emulated
  ## clock frozen — until socket traffic unparks it or the timeout expires.
  var stall_deadline: MonoTime
  var stalling = false
  while true:
    let r = nl.core.try_advance()
    nl.flush_outgoing()
    case r
    of naFrame:
      return
    of naProgress:
      stalling = false
      nl.pump(0)
    of naStalled:
      if not stalling:
        stalling = true
        stall_deadline = getMonoTime() +
                         initDuration(milliseconds = STALL_TIMEOUT_MS)
      nl.pump(1)
      if getMonoTime() > stall_deadline:
        raise newException(NetLinkError,
          "stalled waiting for peer for " & $STALL_TIMEOUT_MS & " ms")
    of naHello:
      raise newException(NetLinkError,
        "link not established: " & nl.core.hello_error)

# ---------------- construction & handshake ----------------

proc new_net_link*(gba: GBA; sock: Socket; id: int; rom_crc: uint32;
                   delay_ms = 0): NetLink =
  ## Wire a post-init core to a connected TCP socket and perform the HELLO
  ## handshake (blocking, not subject to the artificial delay — it is setup,
  ## not gameplay traffic). id 0 = listener = multi-mode unit 0.
  sock.setSockOpt(OptNoDelay, true, level = cint(IPPROTO_TCP))
  result = NetLink(gba: gba, sock: sock, delay_ms: delay_ms)
  result.core = new_net_core(gba, id, rom_crc)
  result.flush_outgoing()  # our HELLO (blocking socket: sends immediately)
  let deadline = getMonoTime() + initDuration(milliseconds = HELLO_TIMEOUT_MS)
  while result.core.hello == hsWait:
    try:
      discard result.poll_socket(50)
    except LinkProtoError as e:
      raise newException(NetLinkError, "bad handshake: " & e.msg)
    if getMonoTime() > deadline:
      raise newException(NetLinkError, "timed out waiting for peer HELLO")
  result.flush_outgoing()  # BYE on rejection / first CLOCK on acceptance
  if result.core.hello == hsFailed:
    raise newException(NetLinkError, result.core.hello_error)
  # Handshake done (blocking sends were fine for it); from here on sends must
  # never block — see wire_out.
  sock.getFd().setBlocking(false)

proc close*(nl: NetLink) =
  ## Graceful teardown. Flush our remaining bytes (the peer may still need
  ## our final BYE), half-close, then drain the peer until EOF: closing with
  ## unread beacons in the kernel buffer would RST the connection, and an
  ## RST discards receive queues — the peer could lose our BYE.
  let deadline = getMonoTime() + initDuration(milliseconds = 3000)
  while (nl.outq.len > 0 or nl.wire_pos < nl.wire_out.len or
         nl.core.has_outgoing()) and getMonoTime() < deadline:
    try:
      nl.flush_outgoing()
    except NetLinkError:
      nl.sock.close()
      return  # peer already gone; nothing left to flush to
    sleep(1)
  when not defined(windows):
    discard posix.shutdown(nl.sock.getFd(), SHUT_WR)
  while getMonoTime() < deadline:
    var fds = @[nl.sock.getFd()]
    if selectRead(fds, 50) <= 0: continue
    var buf: array[4096, char]
    if nl.sock.recv(addr buf[0], buf.len) <= 0: break  # EOF/error: peer gone
  nl.sock.close()
