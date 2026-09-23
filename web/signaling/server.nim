## Signaling server for online link play; protocol twin of server.js (keep
## the two in sync). Zero dependencies: the WebSocket handshake and RFC 6455
## framing are inline on stdlib async sockets.
##
##   ./server [port]        # default 8790 (or $PORT)
##
## Wire protocol (JSON text messages; client side in netplay.js):
##   client -> server: {"t":"rendezvous","code":"PIKA"}  both peers send the code
##   server -> client: {"t":"waiting"}                   first arrival holds a room
##                     {"t":"paired","role":"host"}      first arrival's role
##                     {"t":"paired","role":"guest"}     second arrival's role
##                     {"t":"peer-closed"}               the other side is gone
##                     {"t":"error","msg":"..."}         then the socket closes
##   After "paired", only {"t":"sdp"} and {"t":"ice"} envelopes are relayed,
##   payloads uninspected, within a per-room byte budget; anything else closes
##   the room, so the server cannot carry game/save/ROM bytes.
##
## No TLS: a reverse proxy terminates wss:// and forwards plain ws://. The
## request path is ignored, except /oauth (below).
##
## Per-IP limits key on the direct peer address, except when that is localhost
## (reverse proxy): then the last X-Forwarded-For entry, the one the trusted
## proxy appended. SIGNAL_ALLOWED_ORIGINS (comma-separated) rejects upgrades
## from other Origins; a missing Origin is allowed (non-browser clients), so
## this is CSWSH protection only. SIGNAL_STATS=1 puts the live room count in
## the health line (test harness only).
##
## Google Drive token broker (plain HTTP, same port; see server.js for the
## why). Off unless GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET (or
## GOOGLE_OAUTH_CLIENT_SECRET_FILE) are set:
##   GET  /oauth           {"oauth":true}; 404 when not configured
##   POST /oauth/exchange  {"code","code_verifier","redirect_uri"}
##                         -> {"access_token","expires_in","refresh_token"}
##   POST /oauth/refresh   {"refresh_token"} -> {"access_token","expires_in"}
## Stateless: the refresh token lives on the client and is useless without
## the secret, which lives only here. Google is reached through the system
## curl, so this binary stays TLS-free and statically linkable.

import std/[asyncdispatch, asyncnet, nativesockets, tables, sets, json,
            strutils, times, os, hashes, sha1, base64, osproc, streams, uri]

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
  # Per-IP quotas: codes are short and user-chosen (pairing is first-come), so
  # one address must not be able to sweep the code space or eat the global caps.
  MaxConnsPerIp = 8          # concurrent live sockets per client IP
  MaxWaitingPerIp = 4        # unclaimed waiting rooms held per client IP
  RzWindowSec = 60.0         # rendezvous rate-limit window (fixed window)
  MaxRzPerWindow = 10        # rendezvous attempts per IP per window
  # Post-pair relay: envelope allowlist plus a lifetime per-room byte budget
  # (both directions). A real handshake is well under 32 KB; 256 KB leaves
  # headroom yet makes tunneling data through allowlisted envelopes useless.
  RelayTypes = ["sdp", "ice"]
  MaxRelayBytesPerRoom = 256 * 1024
  # Token broker: a device refreshes about once an hour, so 30 a minute per
  # IP only ever stops abuse. Bodies are a code or a token, well under 16 KB.
  OAuthWindowSec = 60.0
  MaxOAuthPerWindow = 30
  MaxHttpBody = 16 * 1024
  CurlTimeoutSec = 10

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
    # Last frame decoded by readFrame. Fields, not an async tuple return: a
    # string-bearing tuple returned across `await` miscompiles (use-after-free
    # in the future completion).
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
  oauthWindows = initTable[string, RzWin]() # ip -> token-broker calls this window

let statsEnabled = getEnv("SIGNAL_STATS") == "1"
let allowedOrigins = block:
  var s = initHashSet[string]()
  for part in getEnv("SIGNAL_ALLOWED_ORIGINS").split(','):
    let p = part.strip().toLowerAscii()
    if p.len > 0: s.incl p
  s

let oauthClientId = getEnv("GOOGLE_OAUTH_CLIENT_ID")
let oauthSecret = block:
  var v = getEnv("GOOGLE_OAUTH_CLIENT_SECRET")
  let f = getEnv("GOOGLE_OAUTH_CLIENT_SECRET_FILE")
  if v.len == 0 and f.len > 0:
    try: v = readFile(f).strip()
    except IOError: discard
  v
let oauthTokenUrl = getEnv("GOOGLE_OAUTH_TOKEN_URL",
                           "https://oauth2.googleapis.com/token")
let oauthEnabled = oauthClientId.len > 0 and oauthSecret.len > 0

proc bumpIp(t: var Table[string, int], ip: string) =
  t[ip] = t.getOrDefault(ip) + 1

proc dropIp(t: var Table[string, int], ip: string) =
  let n = t.getOrDefault(ip) - 1
  if n <= 0: t.del(ip) else: t[ip] = n

proc isLocalPeer(ip: string): bool =
  ip == "127.0.0.1" or ip == "::1" or ip == "::ffff:127.0.0.1"

# Behind the reverse proxy every direct peer is localhost; honor
# X-Forwarded-For only then, and only its last entry (the proxy's; earlier
# entries are client-supplied).
proc effectiveIp(c: Conn): string =
  if c.directIp.len == 0: return "?"
  if isLocalPeer(c.directIp) and c.hsXff.len > 0:
    let last = c.hsXff.split(',')[^1].strip()
    if last.len > 0: return last
  c.directIp

proc normalizeCode(raw: string): string =
  for ch in raw:
    if ch in {'A'..'Z', '0'..'9'}: result.add ch
    elif ch in {'a'..'z'}: result.add chr(ch.ord - 32)

# RFC 6455 accept key. Non-async so the digest temporary never lives in an
# async environment frame.
proc wsAccept(key: string): string =
  base64.encode(Sha1Digest(secureHash(key & WsGuid)))

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

proc need(c: Conn, n: int): Future[bool] {.async.} =
  while c.buf.len < n:
    let chunk = await c.sock.recv(4096)
    if chunk.len == 0: return false        # peer closed
    c.buf.add chunk
    c.lastRecv = epochTime()
  return true

# Decodes one frame into c.frFin/c.frOp/c.frPayload; false at EOF or on a
# protocol violation.
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

proc closeSock(c: Conn) =
  if c.closed: return
  c.closed = true
  conns.excl c
  # Every disconnect path funnels through here once: the single place the
  # per-IP socket count is released.
  if c.ipCounted:
    c.ipCounted = false
    dropIp(ipConns, c.ip)
  try: c.sock.close()
  except CatchableError: discard

proc notifyClosed(o: Conn) {.async.} =
  await o.sendText("""{"t":"peer-closed"}""")
  closeSock(o)

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

proc onText(c: Conn, text: string) {.async.} =
  if c.peer != nil:
    if not rooms.hasKey(c.code): return  # room already torn down; drop
    rooms[c.code].relayed += text.len
    if rooms[c.code].relayed > MaxRelayBytesPerRoom:
      await c.fail("signaling byte budget exceeded")
      return
    # Plain local string, never a string-bearing tuple across `await` (see
    # the Conn field comment).
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
  # Per-IP rendezvous rate limit, counted before any validation.
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
      # The host (first arrival) is the WebRTC offerer / SIO multi-mode parent.
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

# --- Drive token broker ----------------------------------------------------

proc originAllowed(origin: string): bool =
  allowedOrigins.len == 0 or origin.toLowerAscii() in allowedOrigins

proc httpReply(c: Conn, status, body, origin: string,
               extra = "") {.async.} =
  var head = "HTTP/1.1 " & status & "\r\nContent-Type: application/json\r\n" &
             "Cache-Control: no-store\r\n" & extra
  if origin.len > 0 and originAllowed(origin):
    head.add "Access-Control-Allow-Origin: " & origin & "\r\nVary: Origin\r\n"
  try:
    await c.sock.send(head & "Content-Length: " & $body.len &
      "\r\nConnection: close\r\n\r\n" & body)
  except CatchableError: discard

# POSTs a form to Google through curl. The secret goes in on stdin, never on
# the command line (argv is world-readable). Returns curl's output with the
# HTTP status on the last line ("000" when Google was never reached).
proc curlPost(url, form: string): Future[string] {.async.} =
  var p: Process
  try:
    p = startProcess("curl", args = ["-sS", "--max-time", $CurlTimeoutSec,
      "-H", "Content-Type: application/x-www-form-urlencoded",
      "--data-binary", "@-", "-w", "\n%{http_code}", url],
      options = {poUsePath, poStdErrToStdOut})
  except CatchableError:
    return "\n000"
  try:
    p.inputStream.write(form)
    p.inputStream.close()
    # Polled, not waited on: the event loop keeps serving while curl runs.
    var waited = 0
    while p.peekExitCode() == -1:
      if waited > (CurlTimeoutSec + 5) * 1000:
        p.kill()
        discard p.waitForExit()
        break
      await sleepAsync(20)
      waited += 20
    result = p.outputStream.readAll()
  except CatchableError:
    result = "\n000"
  p.close()

proc formEncode(fields: openArray[(string, string)]): string =
  for (k, v) in fields:
    if result.len > 0: result.add '&'
    result.add encodeUrl(k, usePlus = false) & "=" & encodeUrl(v, usePlus = false)

# Google's reply cut down to what the client needs, under the status the
# client acts on: 200, 400 (the grant is dead: drop the refresh token) or 502.
proc brokerCall(c: Conn, form, origin: string, keepRefresh: bool) {.async.} =
  let raw = await curlPost(oauthTokenUrl, form)
  let nl = raw.rfind('\n')
  let code = if nl >= 0: raw[nl + 1 .. ^1].strip() else: "000"
  let body = if nl >= 0: raw[0 ..< nl] else: ""
  var j: JsonNode
  try: j = parseJson(body)
  except CatchableError: j = nil
  if code == "200" and j != nil and j.kind == JObject and
      j{"access_token"}.getStr("").len > 0:
    var o = %*{"access_token": j{"access_token"}.getStr(""),
               "expires_in": j{"expires_in"}.getInt(3600)}
    if keepRefresh and j{"refresh_token"}.getStr("").len > 0:
      o["refresh_token"] = %j{"refresh_token"}.getStr("")
    await c.httpReply("200 OK", $o, origin)
  elif (code == "400" or code == "401") and j != nil and j.kind == JObject:
    let err = j{"error"}.getStr("invalid_grant")
    await c.httpReply("400 Bad Request", $(%*{"error": err}), origin)
  else:
    await c.httpReply("502 Bad Gateway", """{"error":"upstream"}""", origin)

proc handleOAuth(c: Conn, meth, path, origin: string,
                 contentLength: int) {.async.} =
  if origin.len > 0 and not originAllowed(origin):
    await c.httpReply("403 Forbidden", """{"error":"origin"}""", "")
    return
  if not oauthEnabled:
    await c.httpReply("404 Not Found", """{"error":"oauth_disabled"}""", origin)
    return
  if meth == "OPTIONS":
    await c.httpReply("204 No Content", "", origin,
      "Access-Control-Allow-Methods: GET, POST\r\n" &
      "Access-Control-Allow-Headers: Content-Type\r\n" &
      "Access-Control-Max-Age: 86400\r\n")
    return
  if meth == "GET" and path == "/oauth":
    await c.httpReply("200 OK", """{"oauth":true}""", origin)
    return
  if meth != "POST" or path notin ["/oauth/exchange", "/oauth/refresh"]:
    await c.httpReply("404 Not Found", """{"error":"not_found"}""", origin)
    return
  let ip = c.effectiveIp()
  let now = epochTime()
  var w = oauthWindows.getOrDefault(ip, (start: now, count: 0))
  if now - w.start >= OAuthWindowSec: w = (start: now, count: 0)
  w.count.inc
  oauthWindows[ip] = w
  if w.count > MaxOAuthPerWindow:
    await c.httpReply("429 Too Many Requests", """{"error":"rate"}""", origin)
    return
  if contentLength < 0 or contentLength > MaxHttpBody:
    await c.httpReply("413 Payload Too Large", """{"error":"size"}""", origin)
    return
  while c.buf.len < contentLength:
    let chunk = await c.sock.recv(4096)
    if chunk.len == 0: return
    c.buf.add chunk
  var j: JsonNode
  try: j = parseJson(c.buf[0 ..< contentLength])
  except CatchableError: j = nil
  if j == nil or j.kind != JObject:
    await c.httpReply("400 Bad Request", """{"error":"bad_request"}""", origin)
    return
  if path == "/oauth/refresh":
    let rt = j{"refresh_token"}.getStr("")
    if rt.len == 0:
      await c.httpReply("400 Bad Request", """{"error":"bad_request"}""", origin)
      return
    await c.brokerCall(formEncode({"grant_type": "refresh_token",
      "client_id": oauthClientId, "client_secret": oauthSecret,
      "refresh_token": rt}), origin, false)
  else:
    let code = j{"code"}.getStr("")
    let verifier = j{"code_verifier"}.getStr("")
    let redirect = j{"redirect_uri"}.getStr("")
    # Google checks the redirect URI against its own allowlist too; this
    # keeps a foreign page from using the broker for its own redirect.
    var redirectOk = redirect.len > 0
    if redirectOk and allowedOrigins.len > 0:
      redirectOk = false
      for o in allowedOrigins:
        if redirect.toLowerAscii().startsWith(o & "/"): redirectOk = true
    if code.len == 0 or not redirectOk:
      await c.httpReply("400 Bad Request", """{"error":"bad_request"}""", origin)
      return
    var fields = @{"grant_type": "authorization_code",
      "client_id": oauthClientId, "client_secret": oauthSecret,
      "code": code, "redirect_uri": redirect}
    if verifier.len > 0: fields.add ("code_verifier", verifier)
    await c.brokerCall(formEncode(fields), origin, true)

proc handshake(c: Conn): Future[bool] {.async.} =
  while true:
    let idx = c.buf.find("\r\n\r\n")
    if idx >= 0:
      let head = c.buf[0 ..< idx]
      c.buf = c.buf[idx + 4 .. ^1]
      var key, origin: string
      var isWs = false
      var contentLength = 0
      let reqLine = head.splitLines()[0].splitWhitespace()
      let meth = if reqLine.len > 0: reqLine[0] else: ""
      var path = if reqLine.len > 1: reqLine[1] else: "/"
      let q = path.find('?')
      if q >= 0: path = path[0 ..< q]
      for line in head.splitLines():
        let colon = line.find(':')
        if colon < 0: continue
        let name = line[0 ..< colon].strip().toLowerAscii()
        let val = line[colon + 1 .. ^1].strip()
        if name == "sec-websocket-key": key = val
        elif name == "origin": origin = val
        elif name == "x-forwarded-for": c.hsXff = val
        elif name == "content-length":
          try: contentLength = parseInt(val)
          except ValueError: contentLength = -1
        elif name == "upgrade" and val.toLowerAscii().contains("websocket"):
          isWs = true
      if not isWs and (path == "/oauth" or path.startsWith("/oauth/")):
        await c.handleOAuth(meth, path, origin, contentLength)
        return false
      if key.len == 0 or not isWs:
        # Not a WebSocket upgrade: health probe. The room count is only
        # reported under SIGNAL_STATS=1 (a live count is a recon gift).
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
      # CSWSH guard; a missing Origin is allowed (see the header comment).
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
    # Per-IP socket cap, counted after the handshake (the effective IP may
    # come from X-Forwarded-For); pre-handshake sockets are bounded by
    # MaxConns and the handshake timeout. Released once, in closeSock.
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

# Reaps silent sockets (half-open TCP), pings quiet ones, drops sockets that
# never rendezvous, expires waiting rooms.
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
    # Prune stale rate windows so the table cannot grow under an IP-hopping scan.
    var staleIps: seq[string]
    for ip, w in rzWindows:
      if now - w.start >= RzWindowSec: staleIps.add ip
    for ip in staleIps: rzWindows.del ip
    staleIps.setLen 0
    for ip, w in oauthWindows:
      if now - w.start >= OAuthWindowSec: staleIps.add ip
    for ip in staleIps: oauthWindows.del ip

proc serve(port: Port) {.async.} =
  # buffered = false: Conn.buf does the framing, and asyncnet's buffered read
  # path corrupts a send that follows a recv on the same accepted socket
  # (Nim 2.2.x / macOS).
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
    # The level must be explicit: at the default SOL_SOCKET, TCP_NODELAY's
    # value decodes as SO_DEBUG, which is EPERM on Linux without CAP_NET_ADMIN.
    sock.setSockOpt(OptNoDelay, true, level = cint(IPPROTO_TCP))
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
