## A headless online-link player for end-to-end runs against the desktop
## app (tests/desktop_online_e2e.sh), a browser or a phone: it loads a ROM,
## joins CODE on the signaling server, plays random buttons to frame N,
## then logs both cores' checksum once the friend's inputs up to it are in
## (the app's DINGBAT_LINK_STOP_AT logs its own).
##
##   online_peer ROM CODE [--signal=URL] [--frames=N] [--timeout=S] [--warmup=F]
## (--warmup: frames the solo game runs before the snapshot)

import std/[os, monotimes, parseopt, random, strutils, times]
import dingbat/gba/gba
import dingbat/gb/gb
import dingbat/frontend/online_link
import dingbat/common/serialize

proc now_ms(): int64 = getMonoTime().ticks div 1_000_000

proc ew16(g: GBA; offset: int): uint16 =
  uint16(g.bus.wram_board[offset]) or (uint16(g.bus.wram_board[offset + 1]) shl 8)

proc main() =
  var args: seq[string]
  var signal = SIGNAL_URL
  var frames = 600
  var timeout = 90
  var warmup = 0
  var p = initOptParser(commandLineParams())
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument: args.add key
    of cmdLongOption, cmdShortOption:
      case key
      of "signal": signal = val
      of "frames": frames = parseInt(val)
      of "timeout": timeout = parseInt(val)
      of "warmup": warmup = parseInt(val)
      else: quit("unknown option --" & key, 2)
    of cmdEnd: discard
  if args.len != 2: quit("usage: online_peer ROM CODE [--signal URL] [--frames N]", 2)
  let rom = args[0]
  doAssert net_init()
  var solo_gba: GBA
  var solo_gb: GB
  if rom.toLowerAscii().endsWith(".gb") or rom.toLowerAscii().endsWith(".gbc"):
    solo_gb = new_gb("", rom, true, false)
    solo_gb.post_init()
    for i in 0 ..< warmup: solo_gb.run_until_frame()
  else:
    solo_gba = new_gba("", rom, false, true, false)
    solo_gba.post_init()
    for i in 0 ..< warmup: solo_gba.run_until_frame()
  var h: OnlineHooks
  var paused = false
  var double = false
  h.now_ms = now_ms
  h.log = proc(m: string) =
    echo "peer: ", m
    flushFile(stdout)
  h.capture = proc(): tuple[rom_path, state: string] =
    if solo_gb != nil: (rom, solo_gb.state_bytes()) else: (rom, solo_gba.state_bytes())
  h.make_gba = proc(r: string): GBA =
    result = new_gba("", r, false, true, false)
    result.post_init()
  h.make_gb = proc(r: string): GB =
    result = new_gb("", r, true, false)
    result.post_init()
  h.started = proc() = echo "peer: started"
  var ol: OnlineLink
  h.ended = proc() = discard ol.take_solo()
  h.remote_pause = proc(on: bool) = paused = on
  h.remote_speed = proc(on: bool) = double = on
  h.paused = proc(): bool = paused
  h.double = proc(): bool = double
  h.away = proc(): bool = false
  let tmp = getTempDir() / ("dingbat-online-peer-" & $getCurrentProcessId())
  ol = new_online_link(h, tmp / "cache", "", signal)
  ol.connect(args[1])
  var rng = initRand(4242)
  var bits = 0'u16
  let t0 = now_ms()
  var next_frame = 0'i64
  var said = false
  while now_ms() - t0 < timeout * 1000:
    ol.service()
    if not ol.active and not ol.started and ol.status_error:
      echo "peer: FAILED: ", ol.status
      quit(1)
    if ol.started:
      if ol.head < frames:
        let t = now_ms()
        if t >= next_frame:
          next_frame = max(next_frame + 16, t - 50)
          if rng.rand(15) == 0: bits = uint16(rng.rand(0x3ff))
          if not paused: discard ol.tick(bits)
      elif not said and ol.confirmed >= frames - 1:
        said = true
        echo "ONLINE CHECKSUM ", frames, " ", toHex(ol.checksum())
        # The web's rollback dump (web/e2e/link-native.e2e.mjs): head,
        # confirmed, then each core's state length and FNV-1a in hex.
        var dump = $ol.head & " " & $ol.confirmed
        for i in 0 .. 1:
          let st = if ol.rb_gba != nil: ol.rb_gba.link.cores[i].state_bytes()
                   else: ol.rb_gb.link.cores[i].state_bytes()
          var hex = toHex(fnv1a(st)).toLowerAscii()
          while hex.len > 1 and hex[0] == '0': hex = hex[1 .. ^1]
          dump.add " " & $st.len & ":" & hex
        echo "ONLINE DUMP ", dump
        if ol.rb_gba != nil:
          for i, c in ol.rb_gba.link.cores:
            echo "peer: core ", i, " linktest mark 0x", toHex(c.ew16(0x800), 4)
        echo "peer: transfers ", ol.transfers
        flushFile(stdout)
    elif said:
      echo "peer: session over"
      break
    sleep(1)
  ol.quitting()
  removeDir(tmp)
  if not said:
    echo "peer: FAILED: no checksum (started=", ol.started, " head=", ol.head,
         " confirmed=", ol.confirmed, " status=", ol.status, ")"
    quit(1)

main()
