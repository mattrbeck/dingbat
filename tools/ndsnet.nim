## One DS per process, its wifi on an Air shared with a DS in another
## process over a TCP socket: the network prototype of nds/air.nim's
## lockstep (docs/nds/netwifi.md).
##
##   nim c -d:danger -d:test_harness --path:src -o:ndsnet tools/ndsnet.nim
##   ./ndsnet --listen 7070 --rom A.nds [--press A@0-10] [--save A.sav] ...
##   ./ndsnet --connect 127.0.0.1:7070 --rom B.nds ...
##       [--frames N] [--out PNG] [--bios DIR] [--rtc 2004-01-01]
##       [--shots F,..] [--lead-us 61] [--rtt-ms 0] [--log-every N] [--free-quiet]
##
## The listener is station 0, the connecting side station 1 (its firmware
## MAC's last byte xor 1, as ndsair numbers machines), so a pair here runs
## what `ndsair --rom A --rom B` runs in one process.
##
## Sync: both sides run in AIR_QUANTUM steps on one air clock and tell the
## other each step they finish (CLOCK). A side runs a step only while it
## ends no more than --lead-us of air time past the other's last CLOCK.
## Frames (FRAME) and hardware ACKs (ACK) go out as they happen, ahead of
## the CLOCK that covers them. With the default lead (one quantum, 61 us,
## less than the shortest preamble) every frame reaches the other side
## before its air time: the result is the in-process one, bit for bit. A
## longer lead runs further apart; frames then land late (counted).
##
## --free-quiet lets a side whose radio is quiet (wifi.radio_quiet: not
## listening, not sending) run on without waiting: the other's frames
## cannot reach it and it sends none. A radio that comes on inside a step
## may hear the other side's frames up to one quantum late (counted as
## late); everything else stays exact.
##
## --rtt-ms holds every received message until rtt/2 after it was sent
## (both processes on one host share the monotonic clock), to measure what
## a network's round trip costs.

import std/[os, strutils, parseopt, net, monotimes, times, deques, posix]
import dingbat/nds/[nds, air, sched]
import dingbat/nds/io/[rtc, wifi]
import dingbat/gba/rtc_calendar
import ndsrun, ndsair

const
  MK_HELLO = 1'u8
  MK_FRAME = 2'u8
  MK_ACK = 3'u8
  MK_CLOCK = 4'u8
  MK_DONE = 5'u8

type
  Msg = object
    release: int64          ## monotonic ns it may be looked at
    kind: uint8
    body: seq[uint8]
  Peer = ref object
    fd: SocketHandle
    sock: Socket
    inbuf: seq[uint8]
    queue: Deque[Msg]
    outbox: seq[uint8]
    one_way: int64          ## injected latency, ns
    clock: int64            ## the other side's air clock (CLOCK)
    done: bool
    sent, received, bytes_out: int
    drop_before: int64      ## frames that ended before this air time are dropped
    dropped: int

proc mono_ns(): int64 = getMonoTime().ticks

proc put8(b: var seq[uint8]; v: uint8) = b.add v
proc put16(b: var seq[uint8]; v: int) =
  b.add uint8(v and 0xFF); b.add uint8((v shr 8) and 0xFF)
proc put32(b: var seq[uint8]; v: int64) =
  for k in 0..3: b.add uint8((v shr (8 * k)) and 0xFF)
proc put64(b: var seq[uint8]; v: int64) =
  for k in 0..7: b.add uint8((v shr (8 * k)) and 0xFF)
proc get16(b: openArray[uint8]; o: int): int = int(b[o]) or (int(b[o + 1]) shl 8)
proc get32(b: openArray[uint8]; o: int): int64 =
  for k in 0..3: result = result or (int64(b[o + k]) shl (8 * k))
proc get64(b: openArray[uint8]; o: int): int64 =
  for k in 0..7: result = result or (int64(b[o + k]) shl (8 * k))

proc send(p: Peer; kind: uint8; body: openArray[uint8]) =
  ## Queue a message: [len u32][kind][sent ns i64][body].
  p.outbox.put32(int64(body.len + 9))
  p.outbox.put8(kind)
  p.outbox.put64(mono_ns())
  p.outbox.add body
  inc p.sent

proc flush(p: Peer) =
  var o = 0
  while o < p.outbox.len:
    let n = posix.send(p.fd, p.outbox[o].addr, p.outbox.len - o, 0'i32)
    if n < 0:
      if errno == EAGAIN or errno == EINTR: continue
      quit("send: " & $strerror(errno))
    o += n
  p.bytes_out += p.outbox.len
  p.outbox.setLen(0)

proc read_some(p: Peer; timeout_us: int64) =
  ## Wait up to `timeout_us` (-1: forever) for bytes, read what is there and
  ## queue each whole message with its release time.
  var rfds: TFdSet
  FD_ZERO(rfds)
  FD_SET(p.fd, rfds)
  var tv: Timeval
  var ptv: ptr Timeval = nil
  if timeout_us >= 0:
    tv.tv_sec = posix.Time(timeout_us div 1_000_000)
    tv.tv_usec = Suseconds(timeout_us mod 1_000_000)
    ptv = tv.addr
  let r = posix.select(cint(p.fd) + 1, rfds.addr, nil, nil, ptv)
  if r <= 0: return
  var buf: array[65536, uint8]
  let n = posix.recv(p.fd, buf[0].addr, buf.len, 0'i32)  # select said readable: no wait
  if n == 0:
    p.done = true            # closed: the other side ended
    p.clock = high(int64) div 2
    return
  if n < 0: return
  p.inbuf.add buf.toOpenArray(0, n - 1)
  var o = 0
  while p.inbuf.len - o >= 4:
    let len = int(get32(p.inbuf, o))
    if p.inbuf.len - o - 4 < len: break
    let kind = p.inbuf[o + 4]
    let sent = get64(p.inbuf, o + 5)
    p.queue.addLast Msg(release: sent + p.one_way, kind: kind,
                        body: p.inbuf[o + 13 ..< o + 4 + len])
    o += 4 + len
  if o > 0: p.inbuf = p.inbuf[o .. ^1]

proc encode(f: AirFrame): seq[uint8] =
  result.put32(f.sender); result.put32(f.serial)
  result.put8(uint8(ord(f.kind))); result.put8(uint8(f.channel))
  result.put16(int(f.rate)); result.put8(uint8(f.aid))
  result.put64(f.start); result.put64(f.data_at); result.put64(f.stop)
  result.put16(f.bytes.len)
  result.add f.bytes

proc decode(b: seq[uint8]): AirFrame =
  result = AirFrame(sender: int(get32(b, 0)), serial: int(get32(b, 4)),
                    kind: FrameKind(b[8]), channel: int(b[9]), rate: uint16(get16(b, 10)),
                    aid: int(b[12]), start: get64(b, 13), data_at: get64(b, 21),
                    stop: get64(b, 29))
  let n = get16(b, 37)
  result.bytes = b[39 ..< 39 + n]

proc handle(p: Peer; air: Air; m: Msg) =
  inc p.received
  case m.kind
  of MK_FRAME:
    let f = decode(m.body)
    # ended while this side ran ahead with its radio quiet (--free-quiet)
    if f.stop < p.drop_before: inc p.dropped
    else: air.post_remote(f)
  of MK_ACK: air.ack_remote(int(get32(m.body, 0)), int(get32(m.body, 4)))
  of MK_CLOCK: p.clock = get64(m.body, 0)
  of MK_DONE:
    p.done = true
    p.clock = high(int64) div 2   # stopped: nothing more will come
  else: discard

proc take_released(p: Peer; air: Air) =
  let now = mono_ns()
  while p.queue.len > 0 and p.queue[0].release <= now:
    p.handle(air, p.queue.popFirst())

when isMainModule:
  var frames = 60
  var outp = "ndsnet.png"
  var bios = getEnv("DINGBAT_NDS_BIOS")
  var shots: seq[int]
  var rtc_at, rom, save, connect = ""
  var listen = -1
  var holds: seq[Hold]
  var lead_us = 0.0
  var rtt_ms = 0.0
  var log_every = 0
  var free_quiet = false
  var p = initOptParser(commandLineParams(), shortNoVal = {'h'}, longNoVal = @["help"])
  for kind, key, val in p.getopt():
    if kind notin {cmdLongOption, cmdShortOption}: quit("unexpected argument " & key)
    case key
    of "frames": frames = parseInt(val)
    of "out": outp = val
    of "bios": bios = val
    of "rtc": rtc_at = val
    of "shots":
      for f in val.split(','): shots.add parseInt(f)
    of "rom": rom = val
    of "press": holds.add parse_holds(val)
    of "save": save = val
    of "listen": listen = parseInt(val)
    of "connect": connect = val
    of "lead-us": lead_us = parseFloat(val)
    of "free-quiet": free_quiet = true
    of "rtt-ms": rtt_ms = parseFloat(val)
    of "log-every": log_every = parseInt(val)
    else: quit("unknown option --" & key)
  if (listen < 0) == (connect.len == 0):
    quit("usage: ndsnet (--listen PORT | --connect HOST:PORT) --rom R.nds [...]")
  let station = if listen >= 0: 0 else: 1
  let b9 = readbytes(if bios.len > 0: bios / "bios9.bin" else: "")
  let b7 = readbytes(if bios.len > 0: bios / "bios7.bin" else: "")
  var fw = readbytes(if bios.len > 0: bios / "firmware.bin" else: "")
  if fw.len == 0: fw = synth_firmware()
  var mac: array[6, uint8]
  for k in 0..5: mac[k] = fw[0x36 + k]
  mac[5] = mac[5] xor uint8(station)
  let n = new_nds(readbytes(rom), b9, b7, firmware_with_mac(fw, mac))
  if rtc_at.len > 0:
    let d = rtc_at.replace('T', '-').replace(':', '-').split('-')
    var f: array[6, int]
    for k in 0 ..< min(6, d.len): f[k] = parseInt(d[k])
    n.rtc.set_fixed_clock(n.sched, to_calendar_seconds(f[0], f[1], f[2], f[3], f[4], f[5]))
  if save.len > 0 and fileExists(save):
    n.cart.backup.set_data(readbytes(save))

  # connect
  var sock: Socket
  if listen >= 0:
    let srv = newSocket()
    srv.setSockOpt(OptReuseAddr, true)
    srv.bindAddr(Port(listen), "127.0.0.1")
    srv.listen()
    var client: Socket
    srv.accept(client)
    sock = client
    srv.close()
  else:
    let hp = connect.split(':')
    sock = newSocket()
    var tries = 0
    while true:
      try:
        sock.connect(hp[0], Port(parseInt(hp[1])))
        break
      except OSError:
        inc tries
        if tries > 200: quit("connect failed")
        sock.close()
        sock = newSocket()
        sleep(50)
  sock.setSockOpt(OptNoDelay, true, level = IPPROTO_TCP.cint)
  let peer = Peer(fd: sock.getFd, sock: sock, one_way: int64(rtt_ms * 500_000.0))

  # the air: this console, numbered `station`; the clocks taken as one at
  # the larger start (ndsair's new_air_link does the same)
  let radio = new_air()
  radio.base = station
  var hello: seq[uint8]
  hello.put32(station)
  hello.put64(n.sched.now)
  peer.send(MK_HELLO, hello)
  peer.flush()
  var peer_start = -1'i64
  while peer_start < 0:
    peer.read_some(-1)
    while peer.queue.len > 0:
      let m = peer.queue.popFirst()
      if m.kind == MK_HELLO: peer_start = get64(m.body, 4)
  let start = max(n.sched.now, peer_start)
  n.wifi.attach(radio, n.spi.firmware, start - n.sched.now)
  peer.clock = start
  radio.on_post = proc (f: AirFrame) {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      peer.send(MK_FRAME, encode(f))
  radio.on_ack = proc (sender, serial: int) {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      var b: seq[uint8]
      b.put32(sender); b.put32(serial)
      peer.send(MK_ACK, b)

  # at least one quantum, or neither side could take a step
  let lead = max(AIR_QUANTUM, int64(lead_us * float(MASTER_HZ) / 1e6))
  let off = n.wifi.air_offset
  var now = start
  var stalls = 0
  var free_steps = 0
  var stall_ns = 0'i64
  let t0 = mono_ns()
  let base = outp.changeFileExt("")
  proc tell_clock(c: int64) =
    var b: seq[uint8]
    b.put64(c)
    peer.send(MK_CLOCK, b)
    peer.flush()
  for f in 0 ..< frames:
    for h in holds:
      if f == h.first or f == h.last:
        if h.touch: n.set_touch(h.x, h.y, f == h.first)
        else: n.set_button(h.button, f == h.first)
    n.frame_done = false
    let frame_end = now + FRAME_CYCLES
    while now < frame_end:
      let q = min(frame_end, now + AIR_QUANTUM)
      peer.drop_before = now - lead
      peer.take_released(radio)
      if q > peer.clock + lead and free_quiet and n.wifi.radio_quiet():
        inc free_steps
      elif q > peer.clock + lead:
        inc stalls
        let s0 = mono_ns()
        while q > peer.clock + lead:
          let wait = if peer.queue.len > 0: max(0'i64, (peer.queue[0].release - mono_ns()) div 1000)
                     else: -1'i64
          peer.read_some(wait)
          peer.take_released(radio)
        stall_ns += mono_ns() - s0
      n.run_until(q - off)
      now = q
      tell_clock(now)
    if f + 1 in shots:
      write_png(base & "_" & $(f + 1) & ".png", 256, 384, n.screens_rgba())
    if log_every > 0 and (f + 1) mod log_every == 0:
      let el = float(mono_ns() - t0) / 1e9
      echo "frame ", f + 1, ": ", formatFloat(float(f + 1) / el, ffDecimal, 1), " fps, rx frames ",
           n.wifi.rx_frames, ", tx frames ", n.wifi.tx_frames
  let elapsed = float(mono_ns() - t0) / 1e9
  peer.send(MK_DONE, @[])
  peer.flush()
  while not peer.done:
    peer.read_some(-1)
    peer.take_released(radio)
    while peer.queue.len > 0 and not peer.done:
      peer.handle(radio, peer.queue.popFirst())
  write_png(base & ".png", 256, 384, n.screens_rgba())
  echo "station ", station, " ", rom.extractFilename, ": channel ", n.wifi.channel,
       ", frames sent ", n.wifi.tx_frames, ", received ", n.wifi.rx_frames
  echo "station ", station, " ", n.digest()
  echo "station ", station, " res ", n.res_words()
  echo "air: ", radio.frames, " frames, ", radio.late, " late"
  echo "sync: lead ", formatFloat(float(lead) * 1e6 / float(MASTER_HZ), ffDecimal, 1), " us, rtt ",
       rtt_ms, " ms, ", frames, " frames in ", formatFloat(elapsed, ffDecimal, 3), " s = ",
       formatFloat(float(frames) / elapsed, ffDecimal, 2), " fps (",
       formatFloat(float(frames) / elapsed / 59.8261 * 100, ffDecimal, 2), " % speed), ",
       stalls, " stalls, ", free_steps, " quiet steps, ", formatFloat(float(stall_ns) / 1e9, ffDecimal, 3), " s stalled, ",
       peer.dropped, " frames dropped (sent while quiet here), ", peer.sent, " msgs sent, ", peer.received, " received, ", peer.bytes_out, " bytes out"
  if save.len > 0 and n.cart.backup.dirty:
    writeFile(save, cast[string](n.cart.backup.data))
  sock.close()
