## The online link's network layer: libdatachannel's C API (WebRTC data
## channels) and rtc_shim.c's event queue, signaling WebSocket and goodbye
## POST. Everything arrives through poll_event on the main loop's thread.
##
## The static library comes from .github/scripts/build-webrtc.sh, by
## default into deps/webrtc at the repo root (`nimble webrtc`);
## -d:webrtc_prefix=DIR points elsewhere.

import std/os

# Plain string ops, not `/` or parentDir: cross-compiling for Windows, those
# use the target's '\' on the build host.
const
  this_file = currentSourcePath()
  repo_root = this_file[0 ..< this_file.len - "/src/dingbat/frontend/rtc.nim".len]
  webrtc_prefix {.strdefine.} = repo_root & "/deps/webrtc"
  webrtc_lib = webrtc_prefix & "/lib/libwebrtcdc.a"

when not fileExists(webrtc_lib):
  {.error: "online link: no " & webrtc_lib &
           " (build it with `nimble webrtc`, or pass -d:webrtc_prefix=DIR)".}

{.passC: "-I" & quoteShell(webrtc_prefix & "/include").}
{.compile: "rtc_shim.c".}
{.passL: quoteShell(webrtc_lib).}
when defined(macosx):
  {.passL: "-lc++".}
elif defined(windows):
  # winpthread static: a posix-threads mingw would otherwise import its DLL
  {.passL: "-lws2_32 -liphlpapi -lbcrypt -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic".}
else:
  {.passL: "-lstdc++ -lpthread".}

# The roots the signaling server's certificate must chain to: Let's
# Encrypt's (ISRG Root X1 and X2, Root YE and YR), which issue
# signal.dingbat.gg's.
const LINK_ROOTS = staticRead("link_roots.pem")

type
  ShimEvent = enum
    ## rtc_shim.c's EV_*
    seNone
    seLocalDesc = 1  ## pc: s1 sdp, s2 type
    seLocalCand      ## pc: s1 candidate, s2 mid
    seState          ## pc: a = RTC state
    seGathering      ## pc: a = gathering state
    seDataChannel    ## pc: a = the friend's channel
    seDcOpen         ## dc
    seDcClosed       ## dc
    seDcMessage      ## dc: data
    seDcLow          ## dc: buffered amount fell to the threshold
    seWsOpen         ## ws
    seWsClosed       ## ws: a = 1 if it had opened
    seWsMessage      ## ws: s1 text
    seHttpDone       ## request: a = HTTP status, 0 when it failed

  NetEvent* = object
    ## An event from the network threads. `id` is the peer connection (Pc*),
    ## data channel (Dc*), websocket (Ws*) or request (HttpDone) it is about.
    id*: int
    case
    of EvNone: discard
    of EvLocalDesc: sdp*, desc_type*: string
    of EvLocalCand: candidate*, mid*: string
    of EvPcState: state*: int          # an RTC_* state
    of EvPcGathering: gathering*: int  # RTC_GATHERING_*
    of EvDataChannel: channel*: int    # the friend's channel
    of EvDcOpen, EvDcClosed: discard
    of EvDcMessage: data*: string
    of EvDcLow: discard                # buffered amount fell to the threshold
    of EvWsOpen: discard
    of EvWsClosed: had_opened*: bool
    of EvWsMessage: text*: string
    of EvHttpDone: status*: int        # HTTP status, 0 when it failed

  CEvent {.bycopy.} = object
    kind, id, a: cint
    s1, s2: cstring
    data: ptr UncheckedArray[char]
    len: cint
    next: pointer

const
  RTC_CONNECTED* = 2
  RTC_DISCONNECTED* = 3
  RTC_FAILED* = 4
  RTC_CLOSED* = 5
  RTC_GATHERING_COMPLETE* = 2

proc dbn_init(pem: cstring; len: cint): cint {.importc, cdecl.}
proc dbn_poll(): ptr CEvent {.importc, cdecl.}
proc dbn_event_free(e: ptr CEvent) {.importc, cdecl.}
proc dbn_pc_create(ice: ptr cstring; n: cint): cint {.importc, cdecl.}
proc dbn_dc_create(pc: cint; label: cstring): cint {.importc, cdecl.}
proc dbn_ws_open(url: cstring): cint {.importc, cdecl.}
proc dbn_ws_send(id: cint; text: cstring; len: cint) {.importc, cdecl.}
proc dbn_ws_close(id: cint) {.importc, cdecl.}
proc dbn_https_post(url, body: cstring): cint {.importc, cdecl.}

proc rtcSetRemoteDescription(pc: cint; sdp, typ: cstring): cint {.importc, cdecl.}
proc rtcAddRemoteCandidate(pc: cint; cand, mid: cstring): cint {.importc, cdecl.}
proc rtcSendMessage(id: cint; data: pointer; size: cint): cint {.importc, cdecl.}
proc rtcGetBufferedAmount(id: cint): cint {.importc, cdecl.}
proc rtcSetBufferedAmountLowThreshold(id: cint; amount: cint): cint {.importc, cdecl.}
proc rtcIsOpen(id: cint): bool {.importc, cdecl.}
proc rtcClose(id: cint): cint {.importc, cdecl.}
proc rtcDelete(id: cint): cint {.importc, cdecl.}
proc rtcClosePeerConnection(pc: cint): cint {.importc, cdecl.}
proc rtcDeletePeerConnection(pc: cint): cint {.importc, cdecl.}

var net_ready = false

proc net_init*(): bool =
  ## Once, before any other call here. false: the roots did not parse (the
  ## WebRTC side still works; every wss:// dial will fail).
  if net_ready: return true
  net_ready = true
  dbn_init(cstring(LINK_ROOTS), cint(LINK_ROOTS.len)) == 0

proc poll_event*(e: var NetEvent): bool =
  ## The next event from the network threads, if any.
  let c = dbn_poll()
  if c == nil: return false
  let id = int(c.id)
  let a = int(c.a)
  let s1 = if c.s1 != nil: $c.s1 else: ""
  let s2 = if c.s2 != nil: $c.s2 else: ""
  e = case ShimEvent(c.kind)
    of seNone: EvNone(id: id)
    of seLocalDesc: EvLocalDesc(id: id, sdp: s1, desc_type: s2)
    of seLocalCand: EvLocalCand(id: id, candidate: s1, mid: s2)
    of seState: EvPcState(id: id, state: a)
    of seGathering: EvPcGathering(id: id, gathering: a)
    of seDataChannel: EvDataChannel(id: id, channel: a)
    of seDcOpen: EvDcOpen(id: id)
    of seDcClosed: EvDcClosed(id: id)
    of seDcMessage:
      var data = newString(int(c.len))
      if c.len > 0: copyMem(addr data[0], c.data, int(c.len))
      EvDcMessage(id: id, data: data)
    of seDcLow: EvDcLow(id: id)
    of seWsOpen: EvWsOpen(id: id)
    of seWsClosed: EvWsClosed(id: id, had_opened: a == 1)
    of seWsMessage: EvWsMessage(id: id, text: s1)
    of seHttpDone: EvHttpDone(id: id, status: a)
  dbn_event_free(c)
  true

proc pc_create*(ice_servers: openArray[string]): int =
  ## A peer connection, every callback wired; -1 on failure.
  var urls = newSeq[cstring](ice_servers.len)
  for i, s in ice_servers: urls[i] = cstring(s)
  int(dbn_pc_create(if urls.len > 0: addr urls[0] else: nil, cint(urls.len)))

proc dc_create*(pc: int; label: string): int =
  ## The offerer's reliable, ordered channel (it makes the offer); -1 on
  ## failure.
  int(dbn_dc_create(cint(pc), cstring(label)))

proc set_remote_description*(pc: int; sdp, typ: string): bool =
  rtcSetRemoteDescription(cint(pc), cstring(sdp), cstring(typ)) >= 0

proc add_remote_candidate*(pc: int; cand, mid: string) =
  if cand.len > 0:
    discard rtcAddRemoteCandidate(cint(pc), cstring(cand),
                                  cstring(if mid.len > 0: mid else: "0"))

proc dc_send*(dc: int; data: string): bool =
  ## One binary message; false if the channel is not open.
  if dc < 0 or not rtcIsOpen(cint(dc)): return false
  rtcSendMessage(cint(dc), if data.len > 0: unsafeAddr data[0] else: nil,
                 cint(data.len)) >= 0

proc dc_is_open*(dc: int): bool = dc >= 0 and rtcIsOpen(cint(dc))

proc dc_buffered*(dc: int): int =
  if dc < 0: 0 else: max(0, int(rtcGetBufferedAmount(cint(dc))))

proc dc_set_low_threshold*(dc, n: int) =
  if dc >= 0: discard rtcSetBufferedAmountLowThreshold(cint(dc), cint(n))

proc dc_free*(dc: int) =
  if dc >= 0:
    discard rtcClose(cint(dc))
    discard rtcDelete(cint(dc))

proc pc_free*(pc: int) =
  ## Blocks until libdatachannel has finished any callback in flight.
  if pc >= 0:
    discard rtcClosePeerConnection(cint(pc))
    discard rtcDeletePeerConnection(cint(pc))

proc ws_open*(url: string): int = int(dbn_ws_open(cstring(url)))

proc ws_send*(ws: int; text: string) =
  if ws >= 0: dbn_ws_send(cint(ws), cstring(text), cint(text.len))

proc ws_close*(ws: int) =
  ## Our own close: no evWsClosed for it.
  if ws >= 0: dbn_ws_close(cint(ws))

proc https_post*(url, body: string): int =
  int(dbn_https_post(cstring(url), cstring(body)))
