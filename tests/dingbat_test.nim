import std/[os, strutils, parseopt, net, nativesockets, monotimes, times]
import dingbat/gb/gb
import dingbat/gba/gba
import dingbat/gba/link
import dingbat/gba/netlink
import dingbat/common/test_output
import dingbat/common/rewind

type
  TestMode = enum
    tmSerial, tmSram, tmMooneye, tmMgba, tmMgbaSuite, tmScreenshot,
    tmStateRoundtrip, tmRewindTest, tmLinkTest, tmNetLink

# BGR555 -> 8-bit greyscale, mapping DMG_COLORS to the mealybug expected values.
# DMG_COLORS = [0x6BDF, 0x3ABF, 0x35BD, 0x2CEF] -> greyscale [0xFF, 0xAA, 0x55, 0x00]
proc bgr555_to_grey(c: uint16): uint8 =
  case c
  of 0x6BDF: 0xFF'u8
  of 0x3ABF: 0xAA'u8
  of 0x35BD: 0x55'u8
  of 0x2CEF: 0x00'u8
  else:
    # Fallback for non-DMG colors: generic BGR555 to greyscale
    let r = int(c and 0x1F) * 255 div 31
    let g = int((c shr 5) and 0x1F) * 255 div 31
    let b = int((c shr 10) and 0x1F) * 255 div 31
    uint8((r + g + b) div 3)

# BGR555 -> RGB using CGB-acid2 convention: (c << 3) | (c >> 2)
proc bgr555_to_rgb(c: uint16): array[3, uint8] =
  let r5 = int(c and 0x1F)
  let g5 = int((c shr 5) and 0x1F)
  let b5 = int((c shr 10) and 0x1F)
  [uint8((r5 shl 3) or (r5 shr 2)),
   uint8((g5 shl 3) or (g5 shr 2)),
   uint8((b5 shl 3) or (b5 shr 2))]

proc write_ppm(path: string; buf: seq[uint16]; w, h: int; color: bool) =
  var f = open(path, fmWrite)
  f.write("P6\n" & $w & " " & $h & "\n255\n")
  for pixel in buf:
    if color:
      let rgb = bgr555_to_rgb(pixel)
      f.write(char(rgb[0]))
      f.write(char(rgb[1]))
      f.write(char(rgb[2]))
    else:
      let grey = bgr555_to_grey(pixel)
      f.write(char(grey))
      f.write(char(grey))
      f.write(char(grey))
  f.close()

proc fb_hash(fb: seq[uint16]): uint32 =
  ## FNV-1a over the framebuffer bytes
  result = 0x811C9DC5'u32
  for v in fb:
    result = (result xor uint32(v and 0xFF)) * 0x01000193'u32
    result = (result xor uint32(v shr 8)) * 0x01000193'u32

# Save/load-state roundtrip: run `warmup` frames, save a state, run 60 more
# frames and record a framebuffer hash; then reconstruct a fresh emulator,
# load the state, run 60 frames and compare. Also re-saves both emulators'
# states and compares the files byte-for-byte, which covers all serialized
# internal state, not just the visible pixels. Exits 0 iff everything matches.
proc state_roundtrip(rom_path, bios_path: string; warmup: int): int =
  const POST_FRAMES = 60
  let state_path  = rom_path & ".roundtrip.state"
  let state_path1 = rom_path & ".roundtrip1.state"
  let state_path2 = rom_path & ".roundtrip2.state"
  defer:
    for p in [state_path, state_path1, state_path2]: removeFile(p)
  let ext = rom_path.splitFile().ext.toLowerAscii()
  var fb1, fb2: seq[uint16]
  if ext in [".gba", ".bin"]:
    let is_hle = bios_path == "hle" or bios_path == ""
    let actual_bios = if is_hle: "" else: bios_path
    proc make_gba(): GBA =
      result = new_gba(actual_bios, rom_path, run_bios = false, use_hle = is_hle)
      result.test_output = new_test_output()
      result.post_init()
    let emu1 = make_gba()
    for _ in 0 ..< warmup: emu1.step_frame()
    if not emu1.save_state(state_path):
      echo "ROUNDTRIP: save failed"; return 1
    let emu2 = make_gba()
    if not emu2.load_state(state_path):
      echo "ROUNDTRIP: load failed"; return 1
    for _ in 0 ..< POST_FRAMES: emu1.step_frame()
    for _ in 0 ..< POST_FRAMES: emu2.step_frame()
    fb1 = emu1.ppu.framebuffer
    fb2 = emu2.ppu.framebuffer
    if not emu1.save_state(state_path1) or not emu2.save_state(state_path2):
      echo "ROUNDTRIP: re-save failed"; return 1
  else:
    proc make_gb(): GB =
      result = new_gb("", rom_path, fifo = true, headless = true, run_bios = false)
      result.test_output = new_test_output()
      result.post_init()
    let emu1 = make_gb()
    for _ in 0 ..< warmup: emu1.step_frame()
    if not emu1.save_state(state_path):
      echo "ROUNDTRIP: save failed"; return 1
    let emu2 = make_gb()
    if not emu2.load_state(state_path):
      echo "ROUNDTRIP: load failed"; return 1
    for _ in 0 ..< POST_FRAMES: emu1.step_frame()
    for _ in 0 ..< POST_FRAMES: emu2.step_frame()
    fb1 = emu1.ppu.framebuffer
    fb2 = emu2.ppu.framebuffer
    if not emu1.save_state(state_path1) or not emu2.save_state(state_path2):
      echo "ROUNDTRIP: re-save failed"; return 1
  let h1 = fb_hash(fb1)
  let h2 = fb_hash(fb2)
  let fb_ok = fb1 == fb2
  let state_ok = readFile(state_path1) == readFile(state_path2)
  echo "ROUNDTRIP framebuffer: ", toHex(h1, 8), " vs ", toHex(h2, 8),
       (if fb_ok: " MATCH" else: " MISMATCH")
  echo "ROUNDTRIP full state:  ", (if state_ok: "MATCH" else: "MISMATCH")
  if fb_ok and state_ok: 0 else: 1

# --- linktest ROM helpers (tests/roms/linktest.s EWRAM contract) ---

proc ew16(g: GBA; offset: int): uint16 =
  uint16(g.bus.wram_board[offset]) or (uint16(g.bus.wram_board[offset + 1]) shl 8)
proc linktest_finished(g: GBA): bool = g.ew16(0x800) == 0xCAFE'u16

const LINKTEST_ROUNDS = 16

# Assert one unit's EWRAM log from the linktest ROM: role bits, both
# receive-latch slots for every round, and the serial IRQ count. Returns the
# number of failed checks (also echoed with the given prefix).
proc check_linktest_unit(g: GBA; unit: int; prefix: string): int =
  var failures = 0
  template check(cond: bool; msg: string) =
    if not cond:
      echo prefix, " FAIL: ", msg
      inc failures
  let who = (if unit == 0: "parent" else: "child")
  # Role bits (SIOCNT snapshot, busy bit masked): SI=0/SD=1/ID=0 on the
  # parent; SI=1/SD=1/ID=1 on the child.
  let role = g.ew16(0x804) and 0x7C'u16
  let expected_role = (if unit == 0: 0x08'u16 else: 0x1C'u16)
  check role == expected_role,
    who & " SIOCNT role bits: got 0x" & toHex(role, 2) &
    ", expected 0x" & toHex(expected_role, 2)
  # The unit must have seen every round's SIOMULTI0/1 slots.
  for k in 0 ..< LINKTEST_ROUNDS:
    let slot0 = g.ew16(k * 2)
    let slot1 = g.ew16(0x400 + k * 2)
    check slot0 == (0xA000'u16 or uint16(k)),
      who & " round " & $k & " SIOMULTI0: got 0x" & toHex(slot0, 4)
    check slot1 == (0xB000'u16 or uint16(k)),
      who & " round " & $k & " SIOMULTI1: got 0x" & toHex(slot1, 4)
  let irqs = g.ew16(0x808)
  check irqs == uint16(LINKTEST_ROUNDS),
    who & " serial IRQ count: got " & $irqs & ", expected " & $LINKTEST_ROUNDS
  failures

# Two-core lockstep link acceptance (tests/roms/linktest.s): the multi-mode
# parent sends 0xA000|round, the child answers 0xB000|round, and each unit
# logs its four receive latches, SIOCNT role bits, and serial-IRQ count to
# fixed EWRAM addresses. Runs both cores under the lockstep coordinator and
# asserts both units observed identical, correct rounds. Exits 0 iff all
# checks pass.
proc link_test(rom1, rom2, bios_path: string; timeout: int): int =
  let is_hle = bios_path == "hle" or bios_path == ""
  let actual_bios = if is_hle: "" else: bios_path
  proc make_gba(rom: string): GBA =
    result = new_gba(actual_bios, rom, run_bios = false, use_hle = is_hle)
    result.test_output = new_test_output()
    result.post_init()
  let cores = @[make_gba(rom1), make_gba(rom2)]
  let lnk = new_link(cores)

  var frames = 0
  while frames < timeout and
        not (cores[0].linktest_finished() and cores[1].linktest_finished()):
    lnk.step_frame()
    inc frames

  var failures = 0
  for i, g in cores:
    let who = (if i == 0: "parent" else: "child")
    if not g.linktest_finished():
      echo "LINKTEST FAIL: ", who, " never finished (done flag missing after ",
        frames, " frames)"
      inc failures
  if failures == 0:
    for i, g in cores:
      failures += check_linktest_unit(g, i, "LINKTEST")
  echo "LINKTEST parent rounds: ",
       (if cores[0].linktest_finished(): "complete" else: "incomplete"),
       ", child rounds: ",
       (if cores[1].linktest_finished(): "complete" else: "incomplete"),
       " (", frames, " frames)"
  if failures == 0:
    echo "LINKTEST: PASS (", LINKTEST_ROUNDS, " multi-mode rounds, both directions, IDs and IRQs verified)"
    0
  else:
    echo "LINKTEST: FAIL (", failures, " failed checks)"
    1

# Networked link acceptance (phase 3a of docs/multiplayer.md): two dingbat
# processes run the linktest ROM over TCP, one with --listen PORT (unit 0,
# multi-mode parent candidate) and one with --connect HOST:PORT (unit 1).
# Each process asserts its own unit's EWRAM log — run both and require PASS
# from both. --netlink-delay-ms N adds an artificial delay to every message
# send (internet-latency simulation); the test must still pass, just slower.
proc netlink_test(rom, bios_path: string; listen_port: int; connect_to: string;
                  timeout, delay_ms: int): int =
  let is_hle = bios_path == "hle" or bios_path == ""
  let actual_bios = if is_hle: "" else: bios_path
  let emu = new_gba(actual_bios, rom, run_bios = false, use_hle = is_hle)
  emu.test_output = new_test_output()
  emu.post_init()

  var sock: Socket
  var id = 0
  if listen_port > 0:
    let server = newSocket(buffered = false)
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(listen_port))
    server.listen()
    echo "NETLINK: listening on port ", listen_port
    var fds = @[server.getFd()]
    if selectRead(fds, 30_000) <= 0:
      echo "NETLINK: FAIL — no peer connected within 30 s"
      return 1
    server.accept(sock)
    server.close()
    id = 0
  else:
    let colon = connect_to.rfind(':')
    if colon < 0:
      echo "NETLINK: FAIL — --connect wants HOST:PORT, got ", connect_to
      return 1
    let host = connect_to[0 ..< colon]
    let port = Port(parseInt(connect_to[colon + 1 .. ^1]))
    var connected = false
    for attempt in 0 ..< 40:  # the listener may still be starting up
      sock = newSocket(buffered = false)
      try:
        sock.connect(host, port)
        connected = true
        break
      except OSError:
        sock.close()
        sleep(250)
    if not connected:
      echo "NETLINK: FAIL — could not connect to ", connect_to
      return 1
    id = 1
  let who = (if id == 0: "parent" else: "child")

  var frames = 0
  var verdict = 1
  try:
    let nl = new_net_link(emu, sock, id, crc32(readFile(rom)), delay_ms)
    echo "NETLINK: linked as unit ", id, " (", who, ")",
         (if delay_ms > 0: ", +" & $delay_ms & " ms send delay" else: "")
    let t0 = getMonoTime()
    var sent_done = false
    while frames < timeout:
      nl.step_frame()
      inc frames
      if emu.linktest_finished() and not sent_done:
        nl.send_bye()  # tell the peer we are done; keep beaconing until it is
        sent_done = true
      if sent_done and nl.peer_done:
        break
    let elapsed_ms = (getMonoTime() - t0).inMilliseconds
    if not emu.linktest_finished():
      echo "NETLINK LINKTEST FAIL: ", who, " never finished (done flag ",
           "missing after ", frames, " frames)"
    else:
      let failures = check_linktest_unit(emu, id, "NETLINK LINKTEST")
      echo "NETLINK ", who, " rounds complete: ", frames, " frames, ",
           elapsed_ms, " ms, ", nl.stall_count, " stalls"
      if failures == 0:
        echo "NETLINK LINKTEST: PASS (unit ", id, ", ", LINKTEST_ROUNDS,
             " multi-mode rounds over TCP, role and IRQs verified)"
        verdict = 0
      else:
        echo "NETLINK LINKTEST: FAIL (", failures, " failed checks)"
    nl.close()
  except NetLinkError as e:
    echo "NETLINK LINKTEST: FAIL — ", e.msg
  verdict

# Rewind verification: run forward taking snapshots exactly like the
# frontend does, then pop backward and require byte-exact payload
# reconstruction through the XOR-delta chain — both a few steps back and all
# the way to the oldest snapshot — and that the emulator resumes from the
# rewound state. Exits 0 iff everything matches.
proc rewind_test(rom_path, bios_path: string): int =
  const TOTAL_FRAMES = 300
  let ext = rom_path.splitFile().ext.toLowerAscii()
  let rw = new_rewind()
  var ref_first = ""   # payload of the very first snapshot
  var ref_mid = ""     # payload of snapshot 20
  var snapshots = 0

  template drive(emu: untyped) =
    for f in 1 .. TOTAL_FRAMES:
      emu.step_frame()
      if rw.maybe_push(proc(): string = emu.state_payload()):
        inc snapshots
        if snapshots == 1:  ref_first = emu.state_payload()
        if snapshots == 20: ref_mid = emu.state_payload()
    echo "REWIND history:    ", rw.len, " snapshots in ", rw.mem_used(),
         " bytes (", ref_mid.len, " bytes/full snapshot)"
    # Pop back to snapshot 20 (pops return newest first)
    var popped = ""
    for _ in 1 .. (snapshots - 19):
      popped = rw.pop()
    let mid_ok = popped == ref_mid
    echo "REWIND mid-chain:  ", (if mid_ok: "MATCH" else: "MISMATCH")
    # Apply and make sure the emulator resumes from there
    emu.apply_state_payload(popped)
    let apply_ok = emu.state_payload() == ref_mid
    for _ in 1 .. 10: emu.step_frame()
    echo "REWIND apply:      ", (if apply_ok: "MATCH" else: "MISMATCH")
    # Walk the rest of the chain to the oldest snapshot
    var last = ""
    while true:
      let s = rw.pop()
      if s.len == 0: break
      last = s
    let full_ok = last == ref_first
    echo "REWIND full chain: ", (if full_ok: "MATCH" else: "MISMATCH")
    if mid_ok and apply_ok and full_ok: return 0 else: return 1

  if ext in [".gba", ".bin"]:
    let is_hle = bios_path == "hle" or bios_path == ""
    let actual_bios = if is_hle: "" else: bios_path
    let emu = new_gba(actual_bios, rom_path, run_bios = false, use_hle = is_hle)
    emu.test_output = new_test_output()
    emu.post_init()
    drive(emu)
  else:
    let emu = new_gb("", rom_path, fifo = true, headless = true, run_bios = false)
    emu.test_output = new_test_output()
    emu.post_init()
    drive(emu)

proc main() =
  var rom_path = ""
  var rom_path2 = ""
  var bios_path = ""
  var mode = tmSerial
  var timeout_frames = 1800
  var warmup_frames = 600
  var screenshot_path = ""
  var color_mode = false
  var sio_driver = "null"
  var listen_port = 0
  var connect_to = ""
  var netlink_delay = 0

  var p = initOptParser(commandLineParams())
  var positional = 0
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdArgument:
      if positional == 0:
        rom_path = p.key
        inc positional
      elif positional == 1:
        rom_path2 = p.key
        inc positional
    of cmdLongOption, cmdShortOption:
      case p.key
      of "mode":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        case v.toLowerAscii()
        of "serial": mode = tmSerial
        of "sram": mode = tmSram
        of "mooneye": mode = tmMooneye
        of "mgba": mode = tmMgba
        of "mgba-suite": mode = tmMgbaSuite
        of "screenshot": mode = tmScreenshot
        of "stateroundtrip": mode = tmStateRoundtrip
        of "rewindtest": mode = tmRewindTest
        of "linktest": mode = tmLinkTest
        of "netlink": mode = tmNetLink
        else:
          echo "Unknown mode: ", v
          quit(1)
      of "timeout":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        timeout_frames = parseInt(v)
      of "frames":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        warmup_frames = parseInt(v)
      of "screenshot":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        screenshot_path = v
      of "color":
        color_mode = true
      of "bios":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        bios_path = v
      of "sio":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        case v.toLowerAscii()
        of "null": sio_driver = "null"
        of "loopback": sio_driver = "loopback"
        else:
          echo "Unknown sio driver: ", v
          quit(1)
      of "listen":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        listen_port = parseInt(v)
      of "connect":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        connect_to = v
      of "netlink-delay-ms":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        netlink_delay = parseInt(v)

  if rom_path.len == 0:
    echo "Usage: dingbat_test <rom_path> --mode <serial|sram|mooneye|mgba|mgba-suite|screenshot|stateroundtrip> [--timeout <frames>] [--frames <warmup>] [--screenshot <path.ppm>]"
    quit(1)

  if mode == tmStateRoundtrip:
    quit(state_roundtrip(rom_path, bios_path, warmup_frames))
  if mode == tmRewindTest:
    quit(rewind_test(rom_path, bios_path))
  if mode == tmLinkTest:
    # Second positional arg is core 2's ROM; defaults to running the same
    # ROM on both cores.
    let rom2 = if rom_path2.len > 0: rom_path2 else: rom_path
    quit(link_test(rom_path, rom2, bios_path, timeout_frames))
  if mode == tmNetLink:
    if (listen_port > 0) == (connect_to.len > 0):
      echo "netlink mode needs exactly one of --listen PORT or --connect HOST:PORT"
      quit(1)
    quit(netlink_test(rom_path, bios_path, listen_port, connect_to,
                      timeout_frames, netlink_delay))

  let ext = rom_path.splitFile().ext.toLowerAscii()
  let is_gba = ext in [".gba", ".bin"]
  let test_out = new_test_output()

  if is_gba:
    let is_hle = bios_path == "hle" or bios_path == ""
    let actual_bios = if is_hle: "" else: bios_path
    let emu = new_gba(actual_bios, rom_path, run_bios = false, use_hle = is_hle)
    emu.test_output = test_out
    emu.post_init()
    if sio_driver == "loopback":
      emu.set_sio_driver(LoopbackSioDriver())
    for frame in 0 ..< timeout_frames:
      if test_out.finished: break
      try:
        emu.step_frame()
      except:
        stderr.writeLine("Emulator exception at frame " & $frame & ": " & getCurrentExceptionMsg())
        break
      if mode == tmMgba and test_out.mgba_debug_output.len > 0:
        let output = test_out.mgba_debug_output
        if output.contains("FAIL") or output.contains("PASS") or
           output.contains("fail") or output.contains("pass"):
          test_out.finished = true
      if mode == tmMgbaSuite and test_out.mgba_debug_output.contains("ALL DONE"):
        test_out.finished = true
    # Screenshot mode: write the 240x160 GBA framebuffer as PPM after running
    if mode == tmScreenshot and screenshot_path.len > 0:
      write_ppm(screenshot_path, emu.ppu.framebuffer, 240, 160, color_mode)
      echo screenshot_path
      quit(0)
  else:
    let emu = new_gb("", rom_path, fifo = true, headless = true, run_bios = false)
    emu.test_output = test_out
    emu.post_init()
    for frame in 0 ..< timeout_frames:
      if test_out.finished: break
      emu.step_frame()
      if mode == tmSerial and test_out.serial_buffer.len > 0:
        if test_out.serial_buffer.contains("Passed") or
           test_out.serial_buffer.contains("Failed"):
          test_out.finished = true
      if mode == tmSram and emu.cartridge.ram.len >= 4:
        if emu.cartridge.ram[1] == 0xDE'u8 and
           emu.cartridge.ram[2] == 0xB0'u8 and
           emu.cartridge.ram[3] == 0x61'u8:
          test_out.sram_status = emu.cartridge.ram[0]
          var text = ""
          for i in 4 ..< emu.cartridge.ram.len:
            let b = emu.cartridge.ram[i]
            if b == 0: break
            text.add(char(b))
          test_out.sram_text = text
          test_out.finished = true
    # Screenshot mode: write framebuffer as PPM after running
    if mode == tmScreenshot and screenshot_path.len > 0:
      write_ppm(screenshot_path, emu.ppu.framebuffer, GB_WIDTH, GB_HEIGHT, color_mode)
      echo screenshot_path
      quit(0)

  # Determine result
  var passed = false
  var output = ""

  case mode
  of tmSerial:
    output = test_out.serial_buffer
    passed = output.contains("Passed")
  of tmSram:
    output = test_out.sram_text
    passed = test_out.sram_status == 0
  of tmMooneye:
    passed = test_out.mooneye_result == 0
    output = if passed: "Mooneye: PASS" else: "Mooneye: FAIL"
  of tmMgba:
    output = test_out.mgba_debug_output
    passed = output.contains("PASS") or output.contains("pass")
  of tmMgbaSuite:
    output = test_out.mgba_debug_output
    passed = output.contains("ALL DONE")
  of tmScreenshot:
    echo "Screenshot mode requires --screenshot path"
    quit(1)
  of tmStateRoundtrip, tmRewindTest, tmLinkTest, tmNetLink:
    discard  # handled (and exited) above

  if output.len > 0:
    echo output
  if not test_out.finished:
    echo "TIMEOUT after ", timeout_frames, " frames"
  if passed:
    quit(0)
  else:
    quit(1)

main()
