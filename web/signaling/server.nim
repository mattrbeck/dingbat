## Signaling server for dingbat online link play (multiplayer phase 3b).
##
## This is a byte-for-byte protocol twin of `server.js`, meant for deployment on
## a tiny VPS where Node's ~40-60 MB baseline RSS is the dominant cost. Compiled
## with `nim c -d:release --opt:size` (ideally against musl for a static binary),
## it runs in single-digit-MB RSS with no runtime dependency: one scp-able file.
##
## Zero third-party dependencies — the WebSocket handshake and RFC 6455 framing
## are implemented inline on Nim's stdlib async sockets (the same approach
## server.js takes on node's http server). Options:
##
##   ./server [port]        # default 8790
##
## Wire protocol (JSON text messages) — IDENTICAL to server.js, see netplay.js:
##   client -> server: {"t":"rendezvous","code":"PIKA"}  both peers send the code
##   server -> client: {"t":"waiting"}                   first arrival holds a room
##                     {"t":"paired","role":"host"}      first arrival's role
##                     {"t":"paired","role":"guest"}     second arrival's role
##                     {"t":"peer-closed"}               the other side is gone
##                     {"t":"error","msg":"..."}         then the socket closes
##   after "paired", ONLY {"t":"sdp",...} and {"t":"ice",...} envelopes are
##   relayed (their payloads are never inspected). Anything else — any other
##   type, non-JSON, or exceeding the per-room relay byte budget — closes the
##   room: this server connects peers and is structurally incapable of
##   carrying game/save/ROM bytes.
##
## TLS: none here by design. In production the browser connects to `wss://<host>/
## signal` (netplay.js), so a reverse proxy (Caddy/nginx) terminates TLS and
## forwards plain ws:// to this process. The path is ignored, so proxying any
## path here works.
##
## Abuse hardening (all mirrored in server.js — keep the twins in sync):
##   - Per-IP limits (rendezvous rate, concurrent sockets, waiting rooms) are
##     keyed on the direct peer address, EXCEPT when the direct peer is
##     localhost (the reverse-proxy case): then the LAST entry of
##     X-Forwarded-For — the one appended by our trusted local proxy — is used.
##     Earlier entries are client-supplied and forgeable, so they are ignored.
##   - SIGNAL_ALLOWED_ORIGINS (comma-separated) rejects WebSocket upgrades whose
##     Origin header is not listed. Unset = allow all (LAN/dev). A MISSING
##     Origin is always allowed: non-browser clients don't send one and the
##     header is trivially forgeable outside a browser anyway — this check is
##     CSWSH protection for browsers, nothing more.
##   - The health line is static; SIGNAL_STATS=1 restores the live room count
##     (used by the test harness; don't set it on a public deployment).

import std/[asyncdispatch, asyncnet, tables, sets, json, strutils, times, os,
            hashes, sha1, base64]

const
  WsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  RoomTtl = 600.0            # seconds an unclaimed waiting room is held (10 min)
  HandshakeTimeout = 30.0    # a socket that never sends `rendezvous` is dropped
  PingInterval = 30.0        # ping quiet-but-live sockets this often
  IdleTimeout = 90.0         # no inbound frame (incl. pong) for this long -> dead
  MaxMsgBytes = 64 * 1024    # SDP + ICE are a few KB; anything bigger is abuse
  MaxConns = 2000            # total live sockets; reject the upgrade past this
  MaxRooms = 1000            # total live rooms; reject new-room rendezvous past this
  MinCodeLen = 3             # short enough to say aloud, long enough to not collide
  # Per-IP quotas: one address must not be able to sweep the code space (codes
  # are user-chosen and short, so pairing is first-come) or eat the global caps.
  MaxConnsPerIp = 8          # concurrent live sockets per client IP
  MaxWaitingPerIp = 4        # unclaimed waiting rooms held per client IP
  RzWindowSec = 60.0         # rendezvous rate-limit window (fixed window)
  MaxRzPerWindow = 10        # rendezvous attempts per IP per window
  # Post-pair relay policy. The server's ONLY job after pairing is to carry
  # the WebRTC handshake; it must be structurally incapable of relaying game,
  # save, or ROM bytes (those belong on the peers' DataChannel). Two layers:
  #   1. Envelope allowlist: only {"t":"sdp"} / {"t":"ice"} messages are
  #      relayed. netplay.js sends nothing else post-pair ("rendezvous" is
  #      pre-pair only). Payloads are never inspected — the gate is the
  #      envelope type, so the server stays oblivious to what SDP/ICE mean.
  #   2. A cumulative per-room relayed-byte budget (both directions,
  #      lifetime). A real handshake is tiny: one SDP offer + answer (a few
  #      KB each) plus up to dozens of trickled ICE candidates (~200 B each)
  #      — well under 32 KB in practice. 256 KB is ~10x headroom for
  #      pathological SDP yet makes sustained data tunneling through
  #      allowlisted envelopes useless.
  # Violating either closes the room in the standard error style (error to
  # the sender, peer-closed to the peer): a peer sending non-signaling
  # traffic is either a bug or abuse, never something to relay.
  RelayTypes = ["sdp", "ice"]
  MaxRelayBytesPerRoom = 256 * 1024

type
  Conn = ref object
    sock: AsyncSocket
    buf: string            # bytes read from the socket but not yet consumed
    frag: string           # payload of an in-progress fragmented message
    code: string           # room this socket belongs to ("" = none yet)
    peer: Conn             # set once paired; nil while unpaired
    closed: bool
    createdAt: float
    lastRecv: float        # epochTime of the last inbound frame (liveness proof)
    directIp: string       # the TCP peer address, captured at accept
    hsXff: string          # X-Forwarded-For header seen during the handshake
    ip: string             # effective client IP (directIp, or trusted XFF)
    ipCounted: bool        # true once this conn is counted in ipConns
    # Last frame decoded by readFrame. Kept as fields (not an async tuple return)
    # because a string-bearing tuple returned across `await` miscompiles under
    # Nim's async on this toolchain (use-after-free in the future completion).
    frFin: bool
    frOp: int
    frPayload: string

  Room = object
    host: Conn
    guest: Conn
    expireAt: float        # Inf once paired; a TTL deadline while waiting
    relayed: int           # lifetime bytes relayed post-pair, both directions

proc hash(c: Conn): Hash = hash(cast[pointer](c)) # identity hash for the live-set

type RzWin = tuple[start: float, count: int] # per-IP rendezvous rate window

var
  rooms = initTable[string, Room]()
  conns = initHashSet[Conn]()
  ipConns = initTable[string, int]()    # ip -> live post-handshake sockets
  ipWaiting = initTable[string, int]()  # ip -> unclaimed waiting rooms hosted
  rzWindows = initTable[string, RzWin]() # ip -> rendezvous attempts this window

let statsEnabled = getEnv("SIGNAL_STATS") == "1"
let allowedOrigins = block:
  var s = initHashSet[string]()
  for part in getEnv("SIGNAL_ALLOWED_ORIGINS").split(','):
    let p = part.strip().toLowerAscii()
    if p.len > 0: s.incl p
  s

# ---------------- per-IP bookkeeping ----------------

proc bumpIp(t: var Table[string, int], ip: string) =
  t[ip] = t.getOrDefault(ip) + 1

proc dropIp(t: var Table[string, int], ip: string) =
  let n = t.getOrDefault(ip) - 1
  if n <= 0: t.del(ip) else: t[ip] = n

proc isLocalPeer(ip: string): bool =
  ip == "127.0.0.1" or ip == "::1" or ip == "::ffff:127.0.0.1"

# The address per-IP limits key on. Behind the production reverse proxy every
# direct peer is localhost, so honor X-Forwarded-For then — but ONLY then, and
# only its LAST entry (the one appended by our trusted proxy; earlier entries
# are client-supplied and would let an attacker dodge the limits).
proc effectiveIp(c: Conn): string =
  if c.directIp.len == 0: return "?"
  if isLocalPeer(c.directIp) and c.hsXff.len > 0:
    let last = c.hsXff.split(',')[^1].strip()
    if last.len > 0: return last
  c.directIp

# Fold a user-typed code to the canonical form both peers must match on.
proc normalizeCode(raw: string): string =
  for ch in raw:
    if ch in {'A'..'Z', '0'..'9'}: result.add ch
    elif ch in {'a'..'z'}: result.add chr(ch.ord - 32)

# RFC 6455 handshake accept key: base64(SHA1(clientKey + GUID)). Kept as a
# plain (non-async) proc so the SHA1 digest temporary never lives in an async
# environment frame.
proc wsAccept(key: string): string =
  base64.encode(Sha1Digest(secureHash(key & WsGuid)))

# ---------------- WebSocket framing ----------------

proc sendFrame(c: Conn, opcode: int, payload: string) {.async.} =
  if c.closed: return
  var frame = newStringOfCap(payload.len + 10)
  frame.add chr(0x80 or opcode)            # FIN + opcode
  let n = payload.len
  if n < 126:
    frame.add chr(n)                       # server frames are never masked
  elif n < 65536:
    frame.add chr(126)
    frame.add chr((n shr 8) and 0xff)
    frame.add chr(n and 0xff)
  else:
    frame.add chr(127)
    for i in countdown(7, 0): frame.add chr((n shr (i * 8)) and 0xff)
  frame.add payload
  try:
    await c.sock.send(frame)
  except CatchableError:
    c.closed = true

proc sendText(c: Conn, s: string): Future[void] = c.sendFrame(0x1, s)

# Ensure at least `n` bytes sit in c.buf, pulling from the socket as needed.
proc need(c: Conn, n: int): Future[bool] {.async.} =
  while c.buf.len < n:
    let chunk = await c.sock.recv(4096)
    if chunk.len == 0: return false        # peer closed
    c.buf.add chunk
    c.lastRecv = epochTime()
  return true

# Decode one frame into c.frFin/c.frOp/c.frPayload; returns false at EOF / on a
# protocol violation (the caller then disconnects).
proc readFrame(c: Conn): Future[bool] {.async.} =
  if not await c.need(2): return false
  let b0 = c.buf[0].ord
  let b1 = c.buf[1].ord
  c.frFin = (b0 and 0x80) != 0
  c.frOp = b0 and 0x0f
  let masked = (b1 and 0x80) != 0
  var length = b1 and 0x7f
  var off = 2
  if length == 126:
    if not await c.need(4): return false
    length = (c.buf[2].ord shl 8) or c.buf[3].ord
    off = 4
  elif length == 127:
    if not await c.need(10): return false
    var big = 0'u64
    for i in 2 .. 9: big = (big shl 8) or c.buf[i].uint64
    if big > MaxMsgBytes.uint64: return false # abuse -> disconnect
    length = big.int
    off = 10
  if length > MaxMsgBytes: return false
  var mask: array[4, int]
  if masked:
    if not await c.need(off + 4): return false
    for i in 0 .. 3: mask[i] = c.buf[off + i].ord
    off += 4
  if not await c.need(off + length): return false
  var payload = newString(length)
  for i in 0 ..< length:
    var v = c.buf[off + i].ord
    if masked: v = v xor mask[i and 3]
    payload[i] = chr(v)
  c.buf = c.buf[off + length .. ^1]        # consume the frame
  c.frPayload = payload
  return true

# ---------------- connection + room teardown ----------------

proc closeSock(c: Conn) =
  if c.closed: return
  c.closed = true
  conns.excl c
  # Every disconnect path funnels through here exactly once (the c.closed guard
  # above), so this is the single place the per-IP socket count is released.
  if c.ipCounted:
    c.ipCounted = false
    dropIp(ipConns, c.ip)
  try: c.sock.close()
  except CatchableError: discard

proc notifyClosed(o: Conn) {.async.} =
  await o.sendText("""{"t":"peer-closed"}""")
  closeSock(o)

# Called whenever a connection goes away: free its room and warn the survivor.
proc teardown(c: Conn) =
  if c.code.len > 0 and rooms.hasKey(c.code):
    let room = rooms[c.code]
    if room.host == c or room.guest == c:
      rooms.del(c.code)
      # A room deleted while still guestless was counted in ipWaiting.
      if room.guest == nil: dropIp(ipWaiting, room.host.ip)
      let other = if room.host == c: room.guest else: room.host
      if other != nil and not other.closed:
        asyncCheck notifyClosed(other)
  closeSock(c)

proc fail(c: Conn, msg: string) {.async.} =
  await c.sendText("""{"t":"error","msg":"""" & msg & "\"}")
  teardown(c)

# ---------------- signaling state machine ----------------

proc onText(c: Conn, text: string) {.async.} =
  if c.peer != nil:
    # Paired: relay ONLY allowlisted signaling envelopes, within the room's
    # lifetime byte budget (see RelayTypes above). fail() tears the room down
    # and peer-closes the other side — the standard room-death funnel.
    if not rooms.hasKey(c.code): return  # room already torn down; drop
    rooms[c.code].relayed += text.len
    if rooms[c.code].relayed > MaxRelayBytesPerRoom:
      await c.fail("signaling byte budget exceeded")
      return
    # Parse just the envelope type, into a plain local string (never a
    # string-bearing tuple across `await` — see the Conn field comment).
    var relayT = ""
    try:
      relayT = parseJson(text){"t"}.getStr("")
    except CatchableError:
      await c.fail("not JSON")
      return
    if relayT notin RelayTypes:
      await c.fail("only sdp/ice signaling is relayed")
      return
    await c.peer.sendText(text)
    return
  var t, codeRaw: string
  try:
    let j = parseJson(text)
    t = j{"t"}.getStr("")
    codeRaw = j{"code"}.getStr("")
  except CatchableError:
    await c.fail("not JSON")
    return
  if t != "rendezvous":
    await c.fail("expected rendezvous")
    return
  # Per-IP rendezvous rate limit (counted before any validation): codes are
  # short and user-chosen, so an attacker sweeping the code space — or racing
  # a legitimate guest for the peer slot — needs many quick attempts, while
  # real use is ~one per session.
  let rzNow = epochTime()
  var w = rzWindows.getOrDefault(c.ip, (start: rzNow, count: 0))
  if rzNow - w.start >= RzWindowSec: w = (start: rzNow, count: 0)
  w.count.inc
  rzWindows[c.ip] = w
  if w.count > MaxRzPerWindow:
    await c.fail("too many attempts — wait a minute and try again")
    return
  if c.code.len > 0:
    await c.fail("already in a room")
    return
  let code = normalizeCode(codeRaw)
  if code.len < MinCodeLen:
    await c.fail("code too short")
    return
  if not rooms.hasKey(code):
    # First to arrive with this code: host it and wait for the peer.
    if rooms.len >= MaxRooms:
      await c.fail("server busy — try again shortly")
      return
    if ipWaiting.getOrDefault(c.ip) >= MaxWaitingPerIp:
      await c.fail("too many open codes from your address — try again shortly")
      return
    c.code = code
    rooms[code] = Room(host: c, guest: nil, expireAt: epochTime() + RoomTtl)
    bumpIp(ipWaiting, c.ip)
    await c.sendText("""{"t":"waiting"}""")
  else:
    var room = rooms[code]
    if room.guest == nil:
      # Second arrival: pair as guest. Two peers per code, no more. The host
      # (first arrival) is the WebRTC offerer / SIO multi-mode parent.
      room.guest = c
      room.expireAt = Inf
      rooms[code] = room
      dropIp(ipWaiting, room.host.ip)  # no longer an unclaimed waiting room
      c.code = code
      c.peer = room.host
      room.host.peer = c
      await room.host.sendText("""{"t":"paired","role":"host"}""")
      await c.sendText("""{"t":"paired","role":"guest"}""")
    else:
      await c.fail("that code is already in use — pick another")

# ---------------- HTTP upgrade + per-connection loop ----------------

proc handshake(c: Conn): Future[bool] {.async.} =
  while true:
    let idx = c.buf.find("\r\n\r\n")
    if idx >= 0:
      let head = c.buf[0 ..< idx]
      c.buf = c.buf[idx + 4 .. ^1]
      var key, origin: string
      var isWs = false
      for line in head.splitLines():
        let colon = line.find(':')
        if colon < 0: continue
        let name = line[0 ..< colon].strip().toLowerAscii()
        let val = line[colon + 1 .. ^1].strip()
        if name == "sec-websocket-key": key = val
        elif name == "origin": origin = val
        elif name == "x-forwarded-for": c.hsXff = val
        elif name == "upgrade" and val.toLowerAscii().contains("websocket"):
          isWs = true
      if key.len == 0 or not isWs:
        # Not a WebSocket upgrade: answer the health probe and hang up. The
        # body is static — a live room count is a (mild) recon gift, so it is
        # only reported when SIGNAL_STATS=1 (test harness / private ops).
        let body = if statsEnabled:
                     "dingbat signaling server: " & $rooms.len &
                       " live room(s). Connect via WebSocket.\n"
                   else:
                     "dingbat signaling server. Connect via WebSocket.\n"
        try:
          await c.sock.send("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" &
            "Content-Length: " & $body.len & "\r\nConnection: close\r\n\r\n" & body)
        except CatchableError: discard
        return false
      # Optional CSWSH guard: when an allowlist is configured, reject browser
      # upgrades from foreign origins. A missing Origin is deliberately allowed
      # (non-browser clients; see the header comment).
      if allowedOrigins.len > 0 and origin.len > 0 and
          origin.toLowerAscii() notin allowedOrigins:
        try:
          await c.sock.send("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n" &
            "Connection: close\r\n\r\n")
        except CatchableError: discard
        return false
      let accept = wsAccept(key)
      await c.sock.send(
        "HTTP/1.1 101 Switching Protocols\r\n" &
        "Upgrade: websocket\r\n" &
        "Connection: Upgrade\r\n" &
        "Sec-WebSocket-Accept: " & accept & "\r\n\r\n")
      return true
    if c.buf.len > 8192: return false      # header block absurdly large
    let chunk = await c.sock.recv(1024)
    if chunk.len == 0: return false
    c.buf.add chunk
    c.lastRecv = epochTime()

proc handleClient(c: Conn) {.async.} =
  conns.incl c
  try:
    if not await handshake(c):
      closeSock(c)
      return
    # Per-IP concurrent-socket cap. Counted only after the handshake (the
    # effective IP may come from the proxy's X-Forwarded-For header, so it is
    # not known earlier); pre-handshake sockets are bounded by MaxConns and
    # the handshake timeout. Released in closeSock, once, on every path.
    c.ip = c.effectiveIp()
    if ipConns.getOrDefault(c.ip) >= MaxConnsPerIp:
      await c.fail("too many connections from your address — try again shortly")
      return
    bumpIp(ipConns, c.ip)
    c.ipCounted = true
    while not c.closed:
      if not await readFrame(c): break
      case c.frOp
      of 0x8: break                        # close
      of 0x9: await c.sendFrame(0xA, c.frPayload) # ping -> pong
      of 0xA: discard                       # pong: liveness already noted
      of 0x0, 0x1, 0x2:                     # continuation / text / binary
        if c.frOp != 0x0: c.frag = c.frPayload
        else: c.frag.add c.frPayload
        if c.frag.len > MaxMsgBytes: break
        if c.frFin:
          let msg = c.frag
          c.frag = ""
          await c.onText(msg)
      else: break                          # unknown opcode
  except CatchableError:
    discard
  teardown(c)

# ---------------- liveness reaper ----------------
# Reap sockets gone silent (a half-open TCP the OS hasn't noticed), nudge quiet
# ones with a ping, drop sockets that never rendezvous, and expire waiting rooms.
proc reaper() {.async.} =
  while true:
    await sleepAsync(int(PingInterval * 1000))
    let now = epochTime()
    var snapshot: seq[Conn]
    for c in conns: snapshot.add c
    for c in snapshot:
      if c.closed: continue
      if c.code.len == 0 and c.peer == nil and now - c.createdAt > HandshakeTimeout:
        teardown(c)
        continue
      let idle = now - c.lastRecv
      if idle > IdleTimeout: teardown(c)
      elif idle > PingInterval: asyncCheck c.sendFrame(0x9, "")
    var expired: seq[string]
    for code, room in rooms:
      if room.guest == nil and now > room.expireAt: expired.add code
    for code in expired:
      let host = rooms[code].host
      rooms.del code
      dropIp(ipWaiting, host.ip)      # expired while guestless -> was counted
      asyncCheck (proc(): Future[void] {.async.} =
        await host.fail("nobody joined — try again"))()
    # Rate-limit windows older than the window length are dead weight; prune
    # them here so the table can't grow without bound under an IP-hopping scan.
    var staleIps: seq[string]
    for ip, w in rzWindows:
      if now - w.start >= RzWindowSec: staleIps.add ip
    for ip in staleIps: rzWindows.del ip

# ---------------- listen loop ----------------

proc serve(port: Port) {.async.} =
  # buffered = false: we do our own framing buffer (Conn.buf), and asyncnet's
  # buffered read path corrupts a send that follows a recv on the same accepted
  # socket (observed on Nim 2.2.x / macOS) — the exact request/response shape
  # every connection here uses. Unbuffered sidesteps it and suits us anyway.
  var server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(port)
  server.listen()
  echo "dingbat signaling server listening on ws://localhost:", port.int
  asyncCheck reaper()
  while true:
    let sock = await server.accept()
    if conns.len >= MaxConns:
      sock.close()                          # shed load rather than grow unbounded
      continue
    sock.setSockOpt(OptNoDelay, true)         # TCP_NODELAY: relay setup promptly
    var peerIp = ""
    try: peerIp = sock.getPeerAddr()[0]
    except CatchableError: discard            # peer already gone; treated as "?"
    let now = epochTime()
    let c = Conn(sock: sock, createdAt: now, lastRecv: now, directIp: peerIp)
    asyncCheck handleClient(c)

when isMainModule:
  var port = 8790
  if paramCount() >= 1:
    try: port = parseInt(paramStr(1))
    except ValueError: discard
  elif existsEnv("PORT"):
    try: port = parseInt(getEnv("PORT"))
    except ValueError: discard
  waitFor serve(Port(port))
