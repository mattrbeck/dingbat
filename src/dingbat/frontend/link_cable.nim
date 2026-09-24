## The Link Cable window's socket side, apart from its drawing: pairing
## (zero-config on 127.0.0.1, manual Host/Join under Advanced), the HELLO
## hand-off to gba/netlink.nim, and ending a link. No SDL, ImGui or GL, so
## tests/desktop_netlink_test.nim drives it over real loopback sockets.
##
## Nothing here waits on the network: accepts are polled, connects are
## non-blocking (one attempt per LINK_PROBE_INTERVAL_MS of wall time, each
## checked on later iterations), and the HELLO handshake is polled too
## (begin_net_link / poll_hello), so the window keeps drawing, and Cancel,
## closing it or loading a game end the wait, whatever the peer does.

import std/[net, nativesockets, monotimes, strutils]
when defined(windows):
  from std/winlean import SOL_SOCKET, SO_EXCLUSIVEADDRUSE, TFdSet, FD_ZERO,
                          FD_SET, FD_ISSET, Timeval
import ../gba/[gba, netlink]

const
  LINK_DEFAULT_PORT* = 47810
  LINK_AUTO_HOST* = "127.0.0.1"
    ## Auto-pairing finds another window on this machine only; the Join
    ## box's address is for Advanced > Join.
  LINK_PROBE_INTERVAL_MS* = 150
    ## One connect attempt per this much wall time (~6/s).
  LINK_AUTO_CONNECT_TRIES* = 3
    ## Auto-pair: refused probes before this side hosts instead (~0.5 s).
  LINK_JOIN_GIVE_UP_MS* = 5000
    ## Manual Join: stop retrying a host that refuses, or never answers,
    ## after this long.

type
  LinkSetup* = enum
    lsNone        ## no link setup in progress
    lsListening   ## hosting: waiting for a peer to connect
    lsConnecting  ## joining: connect attempts spread over time
    lsHandshake   ## connected: waiting for the peer's HELLO

  LinkCable* = object
    setup*: LinkSetup
    auto*: bool
      ## Zero-config pairing: probe LINK_AUTO_HOST, failing that host,
      ## until a peer appears. `setup` still tracks the socket phase.
    auto_port*: int         ## the port auto-pairing uses (tests move it)
    port*: cint             ## Advanced: the Host/Join port input
    host_buf*: array[64, char]  ## Advanced: the Join address input
    status*: string         ## last error / status line shown in the window
    hello_timeout_ms*: int  ## how long a handshake waits for the peer's HELLO
    delay_ms*: int          ## --netlink-delay-ms: simulated send latency
    window_prev: bool       ## the window was open last iteration
    server: Socket
    conn: Socket            ## a connect attempt still in progress
    conn_ms: int64          ## when that attempt began
    pending: NetLink        ## lsHandshake: the handshake being polled
    pending_gba: GBA        ## the core it will drive
    probes: int             ## connect attempts since this setup began
    started_ms: int64       ## wall time of the first attempt
    next_probe_ms: int64

proc init_link_cable*(): LinkCable =
  result = LinkCable(auto_port: LINK_DEFAULT_PORT, port: LINK_DEFAULT_PORT,
                     hello_timeout_ms: 30_000)
  for i, c in LINK_AUTO_HOST: result.host_buf[i] = c

proc link_now_ms*(): int64 =
  ## Wall time for service_setup's retry pacing.
  getMonoTime().ticks div 1_000_000

proc probes*(lc: LinkCable): int =
  ## Connect attempts since this setup began.
  lc.probes

proc join_host*(lc: LinkCable): string =
  for c in lc.host_buf:
    if c == '\0': break
    result.add c

proc set_join_host*(lc: var LinkCable; host: string) =
  ## Fill the Join address box (`--connect HOST:PORT`); truncated to fit.
  for i in 0 ..< lc.host_buf.len:
    lc.host_buf[i] = if i < min(host.len, lc.host_buf.len - 1): host[i] else: '\0'

proc close_server(lc: var LinkCable) =
  if lc.server != nil:
    try: lc.server.close()
    except CatchableError: discard
    lc.server = nil

proc close_conn(lc: var LinkCable) =
  if lc.conn != nil:
    try: lc.conn.close()
    except CatchableError: discard
    lc.conn = nil

proc drop_pending(lc: var LinkCable) =
  if lc.pending != nil:
    lc.pending.abandon()
    lc.pending = nil
  lc.pending_gba = nil

proc cancel_setup*(lc: var LinkCable) =
  lc.close_server()
  lc.close_conn()
  lc.drop_pending()
  lc.setup = lsNone

proc begin_connecting(lc: var LinkCable) =
  lc.probes = 0
  lc.setup = lsConnecting

proc auto_start*(lc: var LinkCable; ready, linked: bool) =
  ## Probe for an existing host on LINK_AUTO_HOST first; service_setup
  ## flips to hosting if nobody answers.
  if not ready or linked or lc.auto or lc.setup != lsNone:
    return
  lc.auto = true
  lc.begin_connecting()
  lc.status = ""
  echo "NETLINK: auto-pair — probing ", LINK_AUTO_HOST, ":", lc.auto_port

proc auto_stop*(lc: var LinkCable) =
  if not lc.auto: return
  lc.cancel_setup()
  lc.auto = false

proc port_ok(lc: var LinkCable): bool =
  result = lc.port >= 1 and lc.port <= 65535
  if not result: lc.status = "The port must be between 1 and 65535"

proc start_host*(lc: var LinkCable; ready: bool) =
  ## Bind + listen (non-blocking); service_setup accepts the peer later.
  if not ready:
    lc.status = "Load a GBA ROM first"; return
  if not lc.port_ok(): return
  try:
    let server = newSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(lc.port))
    server.listen()
    server.getFd().setBlocking(false)
    lc.server = server
    lc.setup = lsListening
    lc.status = ""
    echo "NETLINK: hosting on port ", lc.port, " — waiting for a peer"
  except OSError as e:
    lc.status = "Couldn't host on port " & $lc.port & ": " & e.msg

proc start_join*(lc: var LinkCable; ready: bool) =
  ## Begin joining; service_setup runs the (non-freezing) connect retries.
  if not ready:
    lc.status = "Load a GBA ROM first"; return
  if not lc.port_ok(): return
  lc.begin_connecting()
  lc.status = ""

proc auto_listen(lc: var LinkCable): bool =
  ## Auto-pair host leg: bind + listen on the auto port; listener = unit 0.
  ## Two windows racing must not both end up listening, so the bind has to
  ## fail while another socket listens on the port. POSIX refuses that even
  ## with SO_REUSEADDR (measured on macOS), and SO_REUSEADDR lets the bind
  ## succeed over a finished session's TIME_WAIT (~30 s) or a live session's
  ## endpoint, which otherwise block re-pairing. Windows' SO_REUSEADDR would
  ## allow a second listener; SO_EXCLUSIVEADDRUSE is its "refuse" instead.
  var server: Socket
  try:
    server = newSocket(buffered = false)
    when defined(windows):
      setSockOptInt(server.getFd(), SOL_SOCKET, SO_EXCLUSIVEADDRUSE, 1)
    else:
      server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(lc.auto_port))
    server.listen()
    server.getFd().setBlocking(false)
    lc.server = server
    lc.setup = lsListening
    echo "NETLINK: auto-pair — hosting on port ", lc.auto_port
    true
  except OSError:
    if server != nil:
      try: server.close()
      except CatchableError: discard
    false  # port already taken (peer is hosting); caller keeps probing it

proc begin_handshake*(lc: var LinkCable; sock: Socket; id: int; gba: GBA;
                      rom_path: string) =
  ## A peer is connected: send our HELLO and wait for theirs in lsHandshake,
  ## which service_setup polls. Refused (the socket closed, `status` says
  ## why) when there is no GBA core to link or the ROM file can't be read.
  ## Auto-pairing stops either way, so the window shows the outcome rather
  ## than "Waiting to pair...".
  lc.auto = false
  lc.setup = lsNone
  if gba == nil:
    lc.status = "Load a GBA ROM first"
    try: sock.close()
    except CatchableError: discard
    return
  try:
    # Relaxed CRC: same-ROM sessions still match exactly, and cross-version
    # link games (e.g. Ruby<->Sapphire trades) with differing CRCs link fine.
    lc.pending = begin_net_link(gba, sock, id, crc32(readFile(rom_path)),
                                lc.delay_ms, allow_crc_mismatch = true,
                                hello_timeout_ms = lc.hello_timeout_ms)
  except CatchableError as e:
    # IOError (the ROM file moved since it was loaded) or OSError (socket
    # options): neither may end the app.
    echo "NETLINK: handshake failed: ", e.msg
    lc.status = "Handshake failed: " & e.msg
    try: sock.close()
    except CatchableError: discard
    return
  lc.pending_gba = gba
  lc.setup = lsHandshake
  lc.status = ""
  echo "NETLINK: connected as unit ", id, " — waiting for the peer's HELLO"

proc poll_handshake(lc: var LinkCable): NetLink =
  ## lsHandshake, once per iteration, never waiting: the new link once the
  ## peer's HELLO is in; nil while it is awaited, or when the handshake
  ## failed (refused, the peer hung up, or hello_timeout_ms of wall time
  ## passed), with `status` saying why.
  if lc.setup != lsHandshake: return nil
  let nl = lc.pending
  try:
    if not nl.poll_hello(): return nil
  except CatchableError as e:
    echo "NETLINK: handshake failed: ", e.msg
    lc.status = "Handshake failed: " & e.msg
    lc.drop_pending()
    lc.setup = lsNone
    return nil
  lc.pending = nil
  lc.pending_gba = nil
  lc.setup = lsNone
  echo "NETLINK: linked as unit ", nl.id,
       (if nl.id == 0: " (host)" else: " (guest)"),
       (if lc.delay_ms > 0: ", +" & $lc.delay_ms & " ms send delay" else: "")
  lc.status = "Linked as " & (if nl.id == 0: "host (unit 0)" else: "guest (unit 1)")
  nl

proc connect_state(sock: Socket): int =
  ## A non-blocking connect: 1 connected, -1 failed, 0 still in progress.
  var fds = @[sock.getFd()]
  if selectWrite(fds, 0) > 0:
    return (if getSockOptInt(sock.getFd(), SOL_SOCKET, SO_ERROR) == 0: 1 else: -1)
  when defined(windows):
    # Windows reports a failed connect in the exception set, not as writable.
    var ex: TFdSet
    FD_ZERO(ex)
    FD_SET(sock.getFd(), ex)
    var tv = Timeval(tv_sec: 0, tv_usec: 0)
    if winlean.select(0, nil, nil, addr ex, addr tv) > 0 and
       FD_ISSET(sock.getFd(), ex) != 0:
      return -1
  0

proc start_connect(host: string; port: int): (Socket, int) =
  ## Begin a connect that never waits: the socket and its connect_state.
  let sock = newSocket(buffered = false)
  try:
    # timeout 0: std/net starts the connect non-blocking and raises
    # TimeoutError if it has not finished at once, leaving it in progress.
    sock.connect(host, Port(port), timeout = 0)
    (sock, 1)
  except TimeoutError:
    (sock, 0)
  except OSError:
    try: sock.close()
    except CatchableError: discard
    (Socket(nil), -1)

proc service_setup*(lc: var LinkCable; gba: GBA; rom_path: string;
                    now_ms: int64): NetLink =
  ## Per main-loop iteration: poll the pending accept, connect or handshake,
  ## or start the next connect attempt when one is due. Returns the new link
  ## when a peer paired. Never waits on the network.
  if lc.setup != lsNone and gba == nil:
    # Setup outlived its GBA game: nothing can be linked any more.
    lc.auto_stop()
    lc.cancel_setup()
    return nil
  case lc.setup
  of lsListening:
    var fds = @[lc.server.getFd()]
    if selectRead(fds, 0) <= 0: return nil
    var sock: Socket
    try:
      lc.server.accept(sock)
    except OSError as e:
      lc.close_server()
      if lc.auto:
        # Fall back to probing for a peer instead of surfacing an error.
        lc.begin_connecting()
      else:
        lc.status = "Accept failed: " & e.msg
        lc.setup = lsNone
      return nil
    lc.close_server()
    lc.begin_handshake(sock, 0, gba, rom_path)
    return lc.poll_handshake()
  of lsConnecting:
    if lc.probes == 0 and lc.conn == nil:
      lc.started_ms = now_ms
      lc.next_probe_ms = now_ms
    let host = if lc.auto: LINK_AUTO_HOST else: lc.join_host()
    let port = if lc.auto: lc.auto_port else: int(lc.port)
    if not lc.auto and lc.probes > 0 and
       now_ms - lc.started_ms >= LINK_JOIN_GIVE_UP_MS:
      # Refused throughout, or an attempt still unanswered (a host that
      # drops SYNs would hold a blocking connect for over a minute).
      lc.close_conn()
      lc.status = "Couldn't reach " & host & ":" & $port
      lc.setup = lsNone
      return nil
    var state: int
    if lc.conn != nil:
      state = connect_state(lc.conn)
      if state == 0 and lc.auto and now_ms - lc.conn_ms >= LINK_PROBE_INTERVAL_MS:
        state = -1  # 127.0.0.1 answers at once: a silent probe found nobody
      if state == 0: return nil
    else:
      if now_ms < lc.next_probe_ms: return nil
      lc.next_probe_ms = now_ms + LINK_PROBE_INTERVAL_MS
      inc lc.probes
      (lc.conn, state) = start_connect(host, port)
      lc.conn_ms = now_ms
      if state == 0: return nil
    if state < 0:
      lc.close_conn()
      if lc.auto and lc.probes >= LINK_AUTO_CONNECT_TRIES:
        # After a few quick probes with no host answering, become the host.
        # If the bind is refused (a peer grabbed the port first, or a
        # simultaneous-start race), keep probing so we reach that peer.
        if not lc.auto_listen():
          lc.probes = 0
      return nil
    let sock = lc.conn
    lc.conn = nil
    lc.begin_handshake(sock, 1, gba, rom_path)
    return lc.poll_handshake()
  of lsHandshake:
    if gba != lc.pending_gba:
      # Another game under the handshake: it would link the wrong core.
      lc.cancel_setup()
      return nil
    return lc.poll_handshake()
  of lsNone:
    return nil

proc update_auto*(lc: var LinkCable; window, ready, linked: bool) =
  ## Drive pairing off the Link Cable window: opening it starts auto-pairing
  ## (nothing else in progress); while it is closed nothing hosts or joins,
  ## so a peer can't link to a window nobody is looking at.
  if window and not lc.window_prev:
    if ready and not linked and lc.setup == lsNone:
      lc.auto_start(ready, linked)
  elif not window:
    lc.auto_stop()
    lc.cancel_setup()
  lc.window_prev = window

proc teardown*(lc: var LinkCable; nl: var NetLink; why = "") =
  ## End the link: BYE to the peer, close, unplug the core. `why` (empty for
  ## the user's own Disconnect) becomes the window's "Link ended" line.
  if nl == nil: return
  nl.shutdown()
  nl = nil
  lc.status = if why.len > 0: "Link ended: " & why else: ""

proc parse_host_port*(s: string): tuple[host: string, port: int, ok: bool] =
  ## `--connect HOST:PORT`. ok = false for a missing colon or a port that is
  ## not a number in 1..65535.
  let colon = s.rfind(':')
  if colon < 0: return
  try:
    let port = parseInt(s[colon + 1 .. ^1])
    if port >= 1 and port <= 65535:
      result = (s[0 ..< colon], port, true)
  except ValueError:
    discard

proc start_cli*(lc: var LinkCable; listen_port: int; connect_to: string;
                ready: bool): bool =
  ## `--listen PORT` / `--connect HOST:PORT`: Advanced > Host / Join, begun
  ## before the main loop and serviced by it (service_setup) like the
  ## window's, never waiting here. true: open the window on the status.
  if not ready:
    echo "NETLINK: link mode needs a GBA ROM; continuing single-player"
    return false
  if listen_port > 0:
    lc.port = cint(min(listen_port, 65536))  # port_ok refuses > 65535
    lc.start_host(true)
  else:
    let (host, port, ok) = parse_host_port(connect_to)
    if not ok:
      echo "NETLINK: --connect wants HOST:PORT, got ", connect_to
      lc.status = "--connect wants HOST:PORT, got " & connect_to
    else:
      lc.set_join_host(host)
      lc.port = cint(port)
      echo "NETLINK: joining ", connect_to
      lc.start_join(true)
  true
