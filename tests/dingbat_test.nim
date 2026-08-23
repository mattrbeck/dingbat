import std/[os, strutils, parseopt, net, nativesockets, monotimes, times, tables]
import png_reader
import dingbat/gb/gb
import dingbat/gb/link as gblink
import dingbat/gba/gba
import dingbat/gba/link
import dingbat/gba/rollback
import dingbat/gba/netlink
import dingbat/common/test_output
import dingbat/common/rewind
import dingbat/common/input
import std/algorithm  # FuzzARM failure-class rollup

type
  TestMode = enum
    tmSerial, tmSram, tmMooneye, tmMgba, tmMgbaSuite, tmScreenshot,
    tmStateRoundtrip, tmRewindTest, tmLinkTest, tmNormLinkTest,
    tmNorm32LinkTest, tmAttachTest, tmNetLink, tmSpecLink, tmSpecLinkBench,
    tmRollback, tmRollbackNet, tmGbLinkTest, tmJsmolka, tmFuzzArm,
    tmMagenGreen, tmMagenNoRed, tmGambatte, tmMicrotest

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

# Save/load-state roundtrip: save after `warmup` frames, run 60 more on the
# original and on a fresh emulator that loaded the state, and compare both
# the framebuffers and the re-saved state files byte for byte.
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
proc ew32(g: GBA; offset: int): uint32 =
  uint32(g.ew16(offset)) or (uint32(g.ew16(offset + 2)) shl 16)
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

# --- normlinktest ROM helpers (tests/roms/normlinktest.s EWRAM contract) ---
# Normal-mode (8-bit) full-duplex link: unit 0 = master (internal clock),
# unit 1 = slave (external clock). Master sends 0xC0|round, slave answers
# 0xD0|round; the swap lands each unit's byte in the other's SIODATA8, so
# every unit logs the PEER's byte per round.

const NORMLINK_ROUNDS = 16

proc check_normlink_unit(g: GBA; unit: int; prefix: string): int =
  var failures = 0
  template check(cond: bool; msg: string) =
    if not cond:
      echo prefix, " FAIL: ", msg
      inc failures
  let who = (if unit == 0: "master" else: "slave")
  # Internal-clock bit (SIOCNT bit 0): set on the master, clear on the slave.
  let ictl = g.ew16(0x804) and 0x0001'u16
  let expected_ictl = (if unit == 0: 0x0001'u16 else: 0x0000'u16)
  check ictl == expected_ictl,
    who & " internal-clock bit: got " & $ictl & ", expected " & $expected_ictl
  # Full-duplex swap: the master receives the slave's byte and vice-versa.
  for k in 0 ..< NORMLINK_ROUNDS:
    let got = g.ew16(k * 2)
    let expected = (if unit == 0: 0xD0'u16 else: 0xC0'u16) or uint16(k)
    check got == expected,
      who & " round " & $k & " received byte: got 0x" & toHex(got, 4) &
      ", expected 0x" & toHex(expected, 4)
  let irqs = g.ew16(0x808)
  check irqs == uint16(NORMLINK_ROUNDS),
    who & " serial IRQ count: got " & $irqs & ", expected " & $NORMLINK_ROUNDS
  failures

# Normal 32-bit variant: unit 0 master sends 0xA5A50000|round, unit 1 slave
# answers 0x5A5A0000|round; the full-duplex swap of the 32-bit SIODATA32
# register lands each unit's word in the other's, logged at 0x000+4*round.
proc check_norm32link_unit(g: GBA; unit: int; prefix: string): int =
  var failures = 0
  template check(cond: bool; msg: string) =
    if not cond:
      echo prefix, " FAIL: ", msg
      inc failures
  proc ew32(g: GBA; off: int): uint32 =
    uint32(g.ew16(off)) or (uint32(g.ew16(off + 2)) shl 16)
  let who = (if unit == 0: "master" else: "slave")
  let ictl = g.ew16(0x804) and 0x0001'u16
  let expected_ictl = (if unit == 0: 0x0001'u16 else: 0x0000'u16)
  check ictl == expected_ictl,
    who & " internal-clock bit: got " & $ictl & ", expected " & $expected_ictl
  for k in 0 ..< NORMLINK_ROUNDS:
    let got = g.ew32(k * 4)
    let expected = (if unit == 0: 0x5A5A0000'u32 else: 0xA5A50000'u32) or uint32(k)
    check got == expected,
      who & " round " & $k & " received word: got 0x" & toHex(got, 8) &
      ", expected 0x" & toHex(expected, 8)
  let irqs = g.ew16(0x808)
  check irqs == uint16(NORMLINK_ROUNDS),
    who & " serial IRQ count: got " & $irqs & ", expected " & $NORMLINK_ROUNDS
  failures

type LinkContract = enum
  lcMulti    ## linktest.gba: multi-player rounds
  lcNormal   ## normlinktest.gba: normal 8-bit full-duplex rounds
  lcNormal32 ## norm32linktest.gba: normal 32-bit full-duplex rounds

proc check_link_unit(g: GBA; unit: int; prefix: string;
                     contract: LinkContract): int =
  case contract
  of lcMulti: check_linktest_unit(g, unit, prefix)
  of lcNormal: check_normlink_unit(g, unit, prefix)
  of lcNormal32: check_norm32link_unit(g, unit, prefix)

proc link_rounds(contract: LinkContract): int =
  case contract
  of lcMulti: LINKTEST_ROUNDS
  of lcNormal, lcNormal32: NORMLINK_ROUNDS

proc link_desc(contract: LinkContract): string =
  case contract
  of lcMulti: "multi-mode rounds, both directions, IDs and IRQs verified"
  of lcNormal: "normal 8-bit full-duplex rounds, master/slave swap and IRQs verified"
  of lcNormal32: "normal 32-bit full-duplex rounds, master/slave swap and IRQs verified"

# Two-core lockstep link acceptance (tests/roms/linktest.s): the multi-mode
# parent sends 0xA000|round, the child answers 0xB000|round, and each unit
# logs its receive latches, SIOCNT role bits and serial-IRQ count to EWRAM.
proc link_test(rom1, rom2, bios_path: string; timeout: int;
               contract = lcMulti): int =
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
    let who = (if i == 0: "unit 0" else: "unit 1")
    if not g.linktest_finished():
      echo "LINKTEST FAIL: ", who, " never finished (done flag missing after ",
        frames, " frames)"
      inc failures
  if failures == 0:
    for i, g in cores:
      failures += check_link_unit(g, i, "LINKTEST", contract)
  echo "LINKTEST unit 0: ",
       (if cores[0].linktest_finished(): "complete" else: "incomplete"),
       ", unit 1: ",
       (if cores[1].linktest_finished(): "complete" else: "incomplete"),
       " (", frames, " frames)"
  if failures == 0:
    echo "LINKTEST: PASS (", link_rounds(contract), " ", link_desc(contract), ")"
    0
  else:
    echo "LINKTEST: FAIL (", failures, " failed checks)"
    1

# GB two-core lockstep link acceptance (tests/roms/gblinktest.py): the
# harness pokes each unit's role into WRAM 0xC7FF (0 = master, 1 = slave),
# then the units exchange 16 full-duplex bytes — master sends 0xC0|round,
# slave answers 0xD0|round — logging the peer's byte at 0xC000+round, the
# serial-IF count at 0xC808, and 0xCAFE at 0xC800 when done.
proc gb_link_test(rom1, rom2: string; timeout: int): int =
  proc make_gb(rom: string; role: uint8): GB =
    result = new_gb("", rom, fifo = true, headless = true, run_bios = false)
    result.test_output = new_test_output()
    result.post_init()
    result.memory.wram[0][0x7FF] = role
  let cores = @[make_gb(rom1, 0), make_gb(rom2, 1)]
  # The ROM only INCREMENTS its serial-IF counter at 0xC808 and WRAM does not
  # power up zeroed, so read it as a delta from the power-on byte. Not fixed
  # in the ROM: its fnv1a is the save-state identity of fixtures pinned in
  # tests/savestate_compat_test.nim.
  let irq_base = @[cores[0].memory.wram[0][0x808], cores[1].memory.wram[0][0x808]]
  let lnk = new_gb_link(cores)

  proc done(g: GB): bool =
    g.memory.wram[0][0x800] == 0xFE'u8 and g.memory.wram[0][0x801] == 0xCA'u8

  var frames = 0
  while frames < timeout and not (cores[0].done() and cores[1].done()):
    lnk.step_frame()
    inc frames

  var failures = 0
  template check(cond: bool; msg: string) =
    if not cond:
      echo "GBLINKTEST FAIL: ", msg
      inc failures
  for i, g in cores:
    let who = (if i == 0: "master" else: "slave")
    check g.done(), who & " never finished (" & $frames & " frames)"
  if failures == 0:
    for i, g in cores:
      let who = (if i == 0: "master" else: "slave")
      for r in 0 ..< 16:
        let got = g.memory.wram[0][r]
        let expected = (if i == 0: 0xD0'u8 else: 0xC0'u8) or uint8(r)
        check got == expected,
          who & " round " & $r & " received byte: got 0x" & toHex(got) &
          ", expected 0x" & toHex(expected)
      let irqs = int(g.memory.wram[0][0x808]) - int(irq_base[i])
      check irqs == 16, who & " serial-IF count: got " & $irqs & ", expected 16"
  echo "GBLINKTEST: master ", (if cores[0].done(): "complete" else: "incomplete"),
       ", slave ", (if cores[1].done(): "complete" else: "incomplete"),
       " (", frames, " frames, ", lnk.transfers, " transfers)"
  if failures == 0:
    echo "GBLINKTEST: PASS (16 full-duplex rounds, both directions and IF counts verified)"
    0
  else:
    echo "GBLINKTEST: FAIL (", failures, " failed checks)"
    1

# Mid-game attach acceptance (tests/roms/attachtest.s): boot two cores with
# no link, then plug the lockstep link in mid-run (the analogue of the
# browser's netlink_attach). The ROM re-reads SI every pass, so it picks up
# the cable; the linktest ROM latches its role at boot and cannot.
proc attach_test(rom, bios_path: string; timeout, attach_after: int): int =
  let is_hle = bios_path == "hle" or bios_path == ""
  let actual_bios = if is_hle: "" else: bios_path
  proc make_gba(): GBA =
    result = new_gba(actual_bios, rom, run_bios = false, use_hle = is_hle)
    result.test_output = new_test_output()
    result.post_init()
  let cores = @[make_gba(), make_gba()]
  # Phase 1: run cable-less (each core keeps its default no-cable driver) —
  # the ROM sits in its negotiate loop, both units reading SI=1 and waiting.
  for _ in 0 ..< attach_after:
    for g in cores:
      g.step_frame()
  # Phase 2: plug the cable in mid-run. new_link rebinds each core's SIO
  # driver to the lockstep coordinator without touching CPU/memory state.
  let lnk = new_link(cores)
  # Phase 3: run linked until both finish.
  var frames = 0
  while frames < timeout and
        not (cores[0].linktest_finished() and cores[1].linktest_finished()):
    lnk.step_frame()
    inc frames

  var failures = 0
  for i, g in cores:
    let who = (if i == 0: "unit 0" else: "unit 1")
    if not g.linktest_finished():
      echo "ATTACHTEST FAIL: ", who, " never finished (done flag missing ",
        attach_after, " cable-less + ", frames, " linked frames)"
      inc failures
  if failures == 0:
    for i, g in cores:
      failures += check_link_unit(g, i, "ATTACHTEST", lcMulti)
  echo "ATTACHTEST: attached after ", attach_after, " cable-less frames, ",
       "finished in ", frames, " linked frames"
  if failures == 0:
    echo "ATTACHTEST: PASS (mid-run attach, ", LINKTEST_ROUNDS,
         " multi-mode rounds after the cable was plugged in)"
    0
  else:
    echo "ATTACHTEST: FAIL (", failures, " failed checks)"
    1

# Networked link acceptance: two dingbat processes run the linktest ROM over
# TCP, one with --listen PORT (unit 0) and one with --connect HOST:PORT
# (unit 1); each asserts its own unit's EWRAM log. --netlink-delay-ms N
# delays every send.
proc netlink_test(rom, bios_path: string; listen_port: int; connect_to: string;
                  timeout, delay_ms: int; contract = lcMulti): int =
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
      let failures = check_link_unit(emu, id, "NETLINK LINKTEST", contract)
      echo "NETLINK ", who, " rounds complete: ", frames, " frames, ",
           elapsed_ms, " ms, ", nl.stall_count, " stalls"
      if failures == 0:
        echo "NETLINK LINKTEST: PASS (unit ", id, ", ", link_rounds(contract),
             " ", link_desc(contract), ", over TCP)"
        verdict = 0
      else:
        echo "NETLINK LINKTEST: FAIL (", failures, " failed checks)"
    nl.close()
  except NetLinkError as e:
    echo "NETLINK LINKTEST: FAIL — ", e.msg
  verdict

# jsmolka's gba-tests share one protocol (lib/macros.inc): r12 holds the
# verdict, the ROM branches to `eval` on the FIRST failing check with r12 =
# that check's number, then spins in `idle: b idle`; r12 survives the spin
# (0 = all passed). Read r12 rather than the rendered "Failed test NNN": the
# on-screen report goes through SWI 6 and a mode-4 blit, so pixels would
# make the verdict depend on the BIOS and PPU too.
proc jsmolka_test(rom_path, bios_path: string; timeout_frames: int): int =
  let is_hle = bios_path == "hle" or bios_path == ""
  let actual_bios = if is_hle: "" else: bios_path
  let emu = new_gba(actual_bios, rom_path, run_bios = false, use_hle = is_hle)
  emu.test_output = new_test_output()
  emu.post_init()
  # The save/ ROMs check what an untouched backup chip reads back, so detach
  # the .sav: new_storage has applied the power-on fill and write_save is a
  # no-op on an empty path.
  emu.storage.save_path = ""

  # The spin is a one-instruction self-branch, so r15 is constant at frame
  # boundaries once reached; two stationary frames is the done signal.
  var prev_pc = not 0'u32
  var stable = 0
  var frames = 0
  while frames < timeout_frames:
    try:
      emu.step_frame()
    except CatchableError:
      echo "Emulator exception at frame ", frames, ": ", getCurrentExceptionMsg()
      return 1
    inc frames
    let pc = emu.cpu.r[15]
    if pc == prev_pc:
      inc stable
      if stable >= 2: break
    else:
      stable = 0
      prev_pc = pc

  if stable < 2:
    echo "TIMEOUT after ", frames, " frames (never reached the idle spin)"
    return 1
  let verdict = emu.cpu.r[12]
  if verdict == 0:
    echo "All tests passed"
    return 0
  echo "Failed test ", verdict
  return 1

# ==================== DenSinH/FuzzARM ====================
#
# Five prebuilt ROMs, each 10000 randomly generated ARM/Thumb instruction
# tests. This mode drives the ROM's "press any button to continue" gate and
# reads its 16-word eWRAM dump, so every failing test is reported and the
# verdict never depends on the PPU, the BIOS or a frame hash.
#
# Protocol (asm/run_tests.asm upstream): on a mismatch the ROM writes 16
# words to 0x02000000 and spins in wait_until_keys_up / wait_until_key_down
# reading KEYINPUT; any button other than L/R resumes; after the last test
# it draws "End of testing" and falls into a one-instruction self-branch.
# KEYINPUT is the only input register the ROM touches, so `keyinput_reads`
# moving across a frame means a failure report is on screen.
#
# eWRAM layout, 16 words at 0x02000000 (words 10 and 14 are padding):
#   0      'AAAA' / 'TTTT'   ARM or Thumb state
#   1-3    opcode text, 12 ASCII chars
#   4-6    initial r0, r1, r2      7   initial CPSR
#   8-9    got r3, r4              11  got CPSR
#   12-13  expected r3, r4         15  expected CPSR
# r3 is the shifted operand and r4 the result, so which differs separates a
# barrel-shifter bug from an ALU bug from a flag bug.
type
  FuzzArmFail = object
    state: char           # 'A' (ARM) or 'T' (Thumb)
    opcode: string        # e.g. "tst lsl", "smull", "strh/ldrsh"
    r0, r1, r2, cpsr_in: uint32
    got_r3, got_r4, got_cpsr: uint32
    exp_r3, exp_r4, exp_cpsr: uint32

proc fa_hex(v: uint32): string = v.toHex(8)

proc fa_word(b: seq[byte]; off: int): uint32 =
  uint32(b[off]) or (uint32(b[off + 1]) shl 8) or
  (uint32(b[off + 2]) shl 16) or (uint32(b[off + 3]) shl 24)

proc fuzzarm_done_addr(rom_path: string): uint32 =
  ## Address of `mainloop: b mainloop` (0xEAFFFFFE), the self-branch the ROM
  ## falls into after "End of testing"; 0 if the word is not unique in the
  ## image. Do NOT score "finished" as a PC unchanged across two frame
  ## boundaries: this ROM never waits on vblank, so boundaries land mid-loop
  ## and repeat, which silently truncated whole runs.
  let data =
    try: readFile(rom_path)
    except CatchableError: return 0
  var found = 0'u32
  var hits = 0
  var off = 0
  while off + 4 <= data.len:
    if uint32(uint8(data[off])) == 0xFE'u32 and uint32(uint8(data[off + 1])) == 0xFF'u32 and
       uint32(uint8(data[off + 2])) == 0xFF'u32 and uint32(uint8(data[off + 3])) == 0xEA'u32:
      inc hits
      found = 0x08000000'u32 + uint32(off)
    off += 4
  if hits == 1: found else: 0

proc fuzzarm_test_count(rom_path: string): int =
  ## The test count, read out of the image: `run_tests` opens with
  ## `stmdb sp!, {r0-r12, lr}` (0xE92D5FFF) then `set_word r11, tests` (four
  ## rotated immediates) then `ldmia r11!, {r12}`. 0 if the pattern is gone;
  ## only the printed total depends on it.
  let data =
    try: readFile(rom_path)
    except CatchableError: return 0
  proc word(off: int): uint32 =
    uint32(uint8(data[off])) or (uint32(uint8(data[off + 1])) shl 8) or
    (uint32(uint8(data[off + 2])) shl 16) or (uint32(uint8(data[off + 3])) shl 24)
  var off = 0
  while off + 24 <= data.len:
    if word(off) == 0xE92D5FFF'u32:
      var addr_val = 0'u32
      for k in 1 .. 4:
        let w = word(off + 4 * k)
        let imm = w and 0xFF'u32
        let rot = (w shr 8) and 0xF'u32
        addr_val = addr_val or (if rot == 0: imm
                                else: (imm shr (2 * rot)) or (imm shl (32 - 2 * rot)))
      let rel = int(addr_val) - 0x08000000
      if rel >= 0 and rel + 4 <= data.len:
        return int(word(rel))
      return 0
    off += 4
  0

proc fuzzarm_test(rom_path, bios_path: string; timeout_frames, max_fails: int): int =
  let is_hle = bios_path == "hle" or bios_path == ""
  let actual_bios = if is_hle: "" else: bios_path
  let emu = new_gba(actual_bios, rom_path, run_bios = false, use_hle = is_hle)
  emu.test_output = new_test_output()
  emu.post_init()
  emu.storage.save_path = ""   # never drop a .sav next to a downloaded ROM

  let total = fuzzarm_test_count(rom_path)
  let done_addr = fuzzarm_done_addr(rom_path)
  if done_addr == 0:
    stderr.writeLine("  warning: no unique `b .` end marker in " & rom_path &
                     "; falling back to a stalled-PC heuristic")
  var fails: seq[FuzzArmFail]
  # Ack state machine. 0 = watching for a failure report; 1 = A is held for
  # this frame so the ROM leaves wait_until_key_down. Two frames per failure:
  # the held frame runs on until the *next* failure parks in wait_until_keys_up,
  # and the frame after (A released) clears that gate and re-reads KEYINPUT.
  var acking = false
  keyinput_reads = 0
  var prev_reads = 0
  var prev_pc = not 0'u32
  var stable = 0
  var frames = 0
  var capped = false
  var finished = false

  while frames < timeout_frames:
    try:
      emu.step_frame()
    except CatchableError:
      stderr.writeLine("Emulator exception at frame " & $frames & ": " &
                       getCurrentExceptionMsg())
      return 1
    inc frames
    let delta = keyinput_reads - prev_reads
    prev_reads = keyinput_reads
    if acking:
      emu.handle_input(A, false)
      acking = false
      continue
    if delta > 0:
      let w = emu.bus.wram_board
      var op = ""
      for i in 4 ..< 16:
        op.add(char(w[i]))
      fails.add(FuzzArmFail(
        state: char(w[0]),
        opcode: op.strip(),
        r0: fa_word(w, 16), r1: fa_word(w, 20), r2: fa_word(w, 24),
        cpsr_in: fa_word(w, 28),
        got_r3: fa_word(w, 32), got_r4: fa_word(w, 36), got_cpsr: fa_word(w, 44),
        exp_r3: fa_word(w, 48), exp_r4: fa_word(w, 52), exp_cpsr: fa_word(w, 60)))
      let f = fails[^1]
      stderr.writeLine("  fail " & $fails.len & "  " &
        (if f.state == 'T': "THUMB " else: "ARM   ") & f.opcode &
        "  in r0=" & fa_hex(f.r0) & " r1=" & fa_hex(f.r1) & " r2=" & fa_hex(f.r2) &
        " cpsr=" & fa_hex(f.cpsr_in) &
        "  got r3=" & fa_hex(f.got_r3) & " r4=" & fa_hex(f.got_r4) &
        " cpsr=" & fa_hex(f.got_cpsr) &
        "  exp r3=" & fa_hex(f.exp_r3) & " r4=" & fa_hex(f.exp_r4) &
        " cpsr=" & fa_hex(f.exp_cpsr))
      if fails.len >= max_fails:
        capped = true
        break
      emu.handle_input(A, true)
      acking = true
      stable = 0
      prev_pc = not 0'u32
      continue
    # Nothing waiting on input: either still testing, or parked on the
    # one-instruction self-branch after "End of testing". r15 leads the
    # executing instruction by the pipeline depth, so accept the marker
    # address plus one prefetch's worth.
    let pc = emu.cpu.r[15]
    if done_addr != 0:
      if pc >= done_addr and pc <= done_addr + 8:
        finished = true
        break
    elif pc == prev_pc:
      # Fallback only (marker not unique): demand a long stall, because a
      # single repeated frame-boundary PC means nothing in this ROM.
      inc stable
      if stable >= 60:
        finished = true
        break
    else:
      stable = 0
      prev_pc = pc

  # Triage rollup by state + opcode + which of r3/r4/CPSR (and which flags)
  # disagreed. Stderr, so the one-line verdict stays the last stdout line.
  if fails.len > 0:
    var groups: seq[(string, int)]
    for f in fails:
      var tag = ""
      if f.got_r3 != f.exp_r3: tag.add(" r3")
      if f.got_r4 != f.exp_r4: tag.add(" r4")
      if f.got_cpsr != f.exp_cpsr:
        tag.add(" cpsr:")
        let diff = f.got_cpsr xor f.exp_cpsr
        for (bit, name) in [(31, "N"), (30, "Z"), (29, "C"), (28, "V")]:
          if (diff and (1'u32 shl bit)) != 0: tag.add(name)
      let key = (if f.state == 'T': "THUMB " else: "ARM   ") & f.opcode & "  [" &
                tag.strip() & "]"
      var found = false
      for i in 0 ..< groups.len:
        if groups[i][0] == key:
          groups[i][1] += 1
          found = true
          break
      if not found: groups.add((key, 1))
    groups.sort(proc (a, b: (string, int)): int = cmp(b[1], a[1]))
    stderr.writeLine("  --- FuzzARM failure classes (" & $fails.len & " failures, " &
                     $groups.len & " classes) ---")
    for (key, n) in groups:
      stderr.writeLine("  " & align($n, 6) & "  " & key)

  # The verdict line carries a "FUZZARM: " marker so the runner can find it by
  # content. Do NOT let it identify the summary as "the last line" instead:
  # stdout is block-buffered when piped and stderr is not, so the storage
  # layer's early "Backup type could not be identified" can be flushed *after*
  # the whole triage once both streams are merged.
  let total_str = if total > 0: $total else: "?"
  let passed_str = if total > 0: $(total - fails.len) else: "?"
  if capped:
    echo "FUZZARM: <=" & passed_str & "/" & total_str &
         " passed (stopped after " & $fails.len & " failures)"
    return 1
  if not finished:
    echo "FUZZARM: timed out after " & $frames & " frames (" & $fails.len &
         " failures so far)"
    return 1
  if fails.len == 0:
    echo "FUZZARM: " & total_str & "/" & total_str & " passed"
    return 0
  echo "FUZZARM: " & passed_str & "/" & total_str &
       " passed (" & $fails.len & " failed)"
  return 1

# ==================== alloncm/MagenTests ====================
#
# CGB test ROMs whose verdict is the screen colour (src/common.asm: WHITE
# $FFFF, RED $001F, GREEN $03E0, BLUE $7C00; each README entry says what
# they mean). Not a screenshot comparison: the repo ships no 160x144
# reference frame, and a self-generated hash would be a golden with nothing
# behind it.
#   magen-green: "the screen should be all green"; red and blue are the two
#     named failure modes (hblank_vram_dma: red = the HBlank HDMA never ran,
#     blue = it ran while the CPU was halted).
#   magen-nored: bg_oam_priority draws a pattern whose stated result is
#     "... with no red lines", so the machine-checkable part is the absence
#     of red.
proc magen_test(rom_path: string; timeout_frames: int;
                require_all_green: bool): int =
  const
    MagenWhite = 0x7FFF'u16
    MagenRed   = 0x001F'u16
    MagenGreen = 0x03E0'u16
    MagenBlue  = 0x7C00'u16
  let emu = new_gb("", rom_path, fifo = true, headless = true, run_bios = false)
  emu.test_output = new_test_output()
  emu.post_init()
  for _ in 0 ..< timeout_frames:
    emu.step_frame()
  var white, red, green, blue, other = 0
  for px in emu.ppu.framebuffer:
    case px and 0x7FFF'u16
    of MagenWhite: inc white
    of MagenRed: inc red
    of MagenGreen: inc green
    of MagenBlue: inc blue
    else: inc other
  let total = emu.ppu.framebuffer.len
  let good = if require_all_green: green else: total - red
  let pct = 100.0 * float(good) / float(total)
  var why = ""
  if require_all_green and green != total:
    if blue > 0: why = "; blue = the operation ran while the CPU was halted"
    elif red > 0: why = "; red = the operation did not run at all"
  echo pct.formatFloat(ffDecimal, 1) & "% correct (" & $good & "/" & $total &
       " pixels; white " & $white & " red " & $red & " green " & $green &
       " blue " & $blue & " other " & $other & why & ")"
  if good == total: 0 else: 1

# Rewind verification: snapshot while running forward as the frontend does,
# then pop backward and require byte-exact payloads through the XOR-delta
# chain (a few steps back and all the way to the oldest) and a resumable
# emulator.
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

# Speculative-rollback acceptance: two NetCores in-process through a
# deterministic coordinator with a fixed per-message latency in coordinator
# iterations (not wall-clock), so OFF/ON runs are directly comparable. The
# bar is the EWRAM round log, which is timing-tolerant by construction;
# speculation must reproduce it bit-for-bit even under forced mispredicts.

proc ewram_log_hash(g: GBA): uint32 =
  ## FNV-1a over the EWRAM region the link ROMs log to (0x000..0x810: both
  ## receive-latch tables, role snapshot, IRQ count, done flag).
  result = 0x811C9DC5'u32
  for off in 0 ..< 0x810:
    result = (result xor uint32(g.bus.wram_board[off])) * 0x01000193'u32

type SpecRun = object
  hash0, hash1: uint32
  fail0, fail1: int
  done0, done1: bool
  stalls0, stalls1, steps: int
  hits, misses, rollbacks: int
  replay_cycles: int64  # honest CPU cost: cycles re-emulated by rollbacks
  replay_overrun: int   # rollbacks that outran the log (lossy → diverges)
  cpu_ms: float         # wall/CPU time of the whole run
  dbg0: string

# Deterministic two-core coordinator. `delay` is the per-message latency in
# coordinator iterations (post-handshake only, like netlink's --netlink-delay).
# `mispredict` forces the master to guess wrong for the first N rounds.
# `echo_predict` picks the predictor (true = echo-aware, false = plain last-word).
proc run_spec_link(rom, bios_path: string; contract: LinkContract;
                   speculative: bool; delay, mispredict, timeout_frames: int;
                   echo_predict = true; check_contract = true): SpecRun =
  let is_hle = bios_path == "hle" or bios_path == ""
  let actual_bios = if is_hle: "" else: bios_path
  proc make_gba(): GBA =
    result = new_gba(actual_bios, rom, run_bios = false, use_hle = is_hle)
    result.test_output = new_test_output()
    result.post_init()
  let g0 = make_gba()
  let g1 = make_gba()
  let crc = crc32(readFile(rom))
  # Only the initiator (unit 0) predicts; the responder runs the blocking
  # path either way, as a real frontend would enable it.
  let nc0 = new_net_core(g0, 0, crc, strict_crc = true, speculative = speculative)
  let nc1 = new_net_core(g1, 1, crc, strict_crc = true, speculative = false)
  nc0.set_echo_predict(echo_predict)
  if mispredict > 0: nc0.force_mispredict(mispredict)

  # In-flight message queues: (deliver_at_step, frame_bytes).
  var q01, q10: seq[(int, string)]  # 0->1 and 1->0
  var step = 0
  proc collect(src: NetCore; dst: var seq[(int, string)]) =
    let due = step + (if src.hello == hsDone and delay > 0: delay else: 0)
    for f in src.take_outgoing(): dst.add((due, f))
  proc deliver(q: var seq[(int, string)]; dst: NetCore) =
    var keep: seq[(int, string)]
    for (due, data) in q:
      if due <= step: dst.feed(data) else: keep.add((due, data))
    q = keep

  let cap = timeout_frames * 400  # generous iteration bound
  let t0 = cpuTime()
  while step < cap:
    inc step
    deliver(q01, nc1)
    deliver(q10, nc0)
    let r0 = nc0.try_advance()
    collect(nc0, q01)
    let r1 = nc1.try_advance()
    collect(nc1, q10)
    if r0 == naStalled: inc result.stalls0
    if r1 == naStalled: inc result.stalls1
    # Done once both ROMs finished AND every latched round is confirmed by a
    # real reply. Beacons flow forever while the ROMs spin, so do not wait
    # for the queues to empty.
    let settled = (not speculative) or nc0.all_confirmed
    if g0.linktest_finished() and g1.linktest_finished() and settled:
      break
  result.cpu_ms = (cpuTime() - t0) * 1000.0
  result.steps = step
  result.done0 = g0.linktest_finished()
  result.done1 = g1.linktest_finished()
  result.hash0 = ewram_log_hash(g0)
  result.hash1 = ewram_log_hash(g1)
  if check_contract:
    result.fail0 = check_link_unit(g0, 0, "SPECLINK", contract)
    result.fail1 = check_link_unit(g1, 1, "SPECLINK", contract)
  (result.hits, result.misses, result.rollbacks) = nc0.pred_stats()
  result.replay_cycles = nc0.replay_cost()
  result.replay_overrun = nc0.replay_overruns()
  result.dbg0 = nc0.debug_state()

proc spec_link_test(rom, bios_path: string; contract: LinkContract;
                    delay, timeout_frames: int): int =
  ## Self-contained: run the blocking path (reference), then speculation ON at
  ## a couple of latencies, then ON with forced mispredictions — all must
  ## reproduce the reference EWRAM log and pass the ROM contract.
  var verdict = 0
  template require(cond: bool; msg: string) =
    if not cond:
      echo "SPECLINK FAIL: ", msg
      verdict = 1

  let base = run_spec_link(rom, bios_path, contract, false, delay, 0, timeout_frames)
  require(base.done0 and base.done1, "reference (spec OFF) never finished")
  require(base.fail0 == 0 and base.fail1 == 0, "reference contract checks failed")
  echo "SPECLINK reference (OFF, delay ", delay, "): unit0 hash ",
       toHex(base.hash0, 8), ", unit1 hash ", toHex(base.hash1, 8),
       ", ", base.steps, " steps, ", base.stalls0, "+", base.stalls1, " stalls"

  for d in @[0, delay]:
    let on = run_spec_link(rom, bios_path, contract, true, d, 0, timeout_frames)
    require(on.done0 and on.done1, "spec ON (delay " & $d & ") never finished/settled")
    require(on.fail0 == 0 and on.fail1 == 0,
      "spec ON (delay " & $d & ") contract checks failed")
    require(on.hash0 == base.hash0 and on.hash1 == base.hash1,
      "spec ON (delay " & $d & ") EWRAM log differs from blocking path (unit0 " &
      toHex(on.hash0, 8) & " vs " & toHex(base.hash0, 8) & ", unit1 " &
      toHex(on.hash1, 8) & " vs " & toHex(base.hash1, 8) & ")")
    echo "SPECLINK ON  (delay ", d, "): MATCH, ", on.steps, " steps, ",
         on.stalls0, "+", on.stalls1, " stalls, hits=", on.hits,
         " misses=", on.misses, " rollbacks=", on.rollbacks

  # Forced-misprediction recovery: predictor returns wrong words for the first
  # 20 rounds; rollback must still land on the reference log.
  let bad = run_spec_link(rom, bios_path, contract, true, delay, 20, timeout_frames)
  require(bad.done0 and bad.done1, "forced-mispredict run never finished/settled")
  require(bad.fail0 == 0 and bad.fail1 == 0, "forced-mispredict contract checks failed")
  require(bad.hash0 == base.hash0 and bad.hash1 == base.hash1,
    "forced-mispredict EWRAM log differs from blocking path (rollback did not recover)")
  require(bad.rollbacks > 0, "forced mispredict produced no rollbacks (hook inert?)")
  echo "SPECLINK ON  (delay ", delay, ", forced mispredict): MATCH, ",
       bad.steps, " steps, hits=", bad.hits, " misses=", bad.misses,
       " rollbacks=", bad.rollbacks

  # Speed proxy: reply_wait/lead stalls should collapse under latency.
  let on_hi = run_spec_link(rom, bios_path, contract, true, delay, 0, timeout_frames)
  echo "SPECLINK speed (delay ", delay, "): OFF ", base.stalls0 + base.stalls1,
       " stalls / ", base.steps, " steps  vs  ON ",
       on_hi.stalls0 + on_hi.stalls1, " stalls / ", on_hi.steps, " steps"
  require(on_hi.stalls0 <= base.stalls0,
    "speculation did not reduce master stalls under latency")

  if verdict == 0:
    echo "SPECLINK: PASS (blocking-path-identical under speculation + rollback recovery, ",
         link_desc(contract), ")"
  else:
    echo "SPECLINK: FAIL"
  verdict

proc spec_link_bench(rom, bios_path: string; contract: LinkContract;
                     delay, timeout_frames: int): int =
  ## Speculation benchmark on the long symmetric speclinkbench handshake:
  ## OFF, then ON with the old "same as last" predictor and with the shipped
  ## echo-aware one, at 0 and `delay` latency. Reports `replay_cyc` (cycles
  ## re-emulated by rollbacks), `overrun` (rollbacks that outran the log) and
  ## CPU ms; asserts the shipped predictor is bit-identical to the blocking
  ## path and cuts the old predictor's re-emulation.
  var verdict = 0
  template require(cond: bool; msg: string) =
    if not cond:
      echo "SPECBENCH FAIL: ", msg
      verdict = 1

  proc report(tag: string; r, base: SpecRun) =
    echo "SPECBENCH ", tag,
      ": steps=", r.steps, " hits=", r.hits, " misses=", r.misses,
      " rollbacks=", r.rollbacks, " replay_cyc=", r.replay_cycles,
      " overrun=", r.replay_overrun,
      " match=", (r.hash0 == base.hash0 and r.hash1 == base.hash1),
      " cpu=", formatFloat(r.cpu_ms, ffDecimal, 1), "ms"

  let base = run_spec_link(rom, bios_path, contract, false, delay, 0,
                           timeout_frames, check_contract = false)
  require(base.done0 and base.done1, "reference (OFF) never finished")
  report("OFF        (delay " & $delay & ")", base, base)

  for d in @[0, delay]:
    let new_p = run_spec_link(rom, bios_path, contract, true, d, 0,
                              timeout_frames, echo_predict = true,
                              check_contract = false)
    report("ON new-pred (delay " & $d & ")", new_p, base)
    let old_p = run_spec_link(rom, bios_path, contract, true, d, 0,
                              timeout_frames, echo_predict = false,
                              check_contract = false)
    report("ON old-pred (delay " & $d & ")", old_p, base)
    # Shipped predictor: MUST be exactly the blocking path, with no lossy overrun.
    require(new_p.hash0 == base.hash0 and new_p.hash1 == base.hash1,
      "NEW predictor (delay " & $d & ") diverged from blocking path")
    require(new_p.replay_overrun == 0,
      "NEW predictor (delay " & $d & ") hit the lossy replay-overrun path")
    # The whole point: at real latency the echo predictor eliminates the rollback
    # re-emulation the old one wastes on the symmetric handshake.
    if d > 0:
      require(new_p.misses < old_p.misses,
        "NEW predictor did not cut mispredictions vs OLD (delay " & $d & ")")
      require(new_p.replay_cycles * 4 < old_p.replay_cycles,
        "NEW predictor did not slash re-emulation vs OLD (delay " & $d &
        "): new " & $new_p.replay_cycles & " vs old " & $old_p.replay_cycles)
      if old_p.hash0 != base.hash0 or old_p.hash1 != base.hash1:
        echo "SPECBENCH note: OLD predictor diverged under thrash (overrun=",
          old_p.replay_overrun, ") — extreme rollback outran the log; the echo ",
          "predictor avoids the regime entirely."

  if verdict == 0:
    echo "SPECBENCH: PASS (echo predictor bit-identical AND cuts rollback re-emulation, ",
         link_desc(contract), ")"
  else:
    echo "SPECBENCH: FAIL"
  verdict

proc rollback_test(rom, bios_path: string): int =
  ## Input-rollback netplay model: run BOTH cores locally, network only the
  ## two players' inputs, predict the remote input and roll back when a late
  ## input mispredicts; the SIO cable is resolved locally. Uses inputrec.gba,
  ## whose accumulator depends on the exact input timeline. Also checks the
  ## primitives: determinism, capture/restore, chained restore, frame(-1)
  ## capture, and restore-older-onto-newer-then-replay.
  const
    FRAMES = 90
    DELAY = 3        # remote input lands this many frames late (predict meanwhile)
  let is_hle = bios_path == "hle" or bios_path == ""
  let actual_bios = if is_hle: "" else: bios_path
  proc make_link(): Link =
    proc mk(): GBA =
      result = new_gba(actual_bios, rom, run_bios = false, use_hle = is_hle)
      result.test_output = new_test_output()
      result.post_init()
    new_link(@[mk(), mk()])

  # Deterministic per-frame held-buttons for each player. Player 1 changes often
  # so the "repeat last" predictor misses a lot → the rollback path is exercised.
  var script: array[FRAMES, array[2, set[Input]]]
  for f in 0 ..< FRAMES:
    var s0, s1: set[Input]
    if f mod 2 == 0: s0.incl A
    if f mod 5 == 0: s0.incl RIGHT
    if f mod 3 == 0: s0.incl START
    if f mod 3 == 0: s1.incl B
    if f mod 4 == 0: s1.incl LEFT
    if f mod 7 == 0: s1.incl UP
    if f mod 11 == 0: s1.incl A
    script[f] = [s0, s1]

  proc apply(link: Link; s0, s1: set[Input]) =
    for inp in Input:
      link.cores[0].handle_input(inp, inp in s0)
      link.cores[1].handle_input(inp, inp in s1)

  # Ground truth: every input known upfront.
  let truth = make_link()
  for f in 0 ..< FRAMES:
    truth.apply(script[f][0], script[f][1])
    truth.step_frame()
  let want_sum = truth.state_checksum()

  # Foundation checks — the rollback machinery primitives (all pass today).
  var foundation = true
  proc note(name: string; ok: bool) =
    echo "ROLLBACK ", (if ok: "ok  " else: "FAIL"), " ", name
    if not ok: foundation = false
  block: # (1) determinism: a second identical run must match.
    let t2 = make_link()
    for f in 0 ..< FRAMES: t2.apply(script[f][0], script[f][1]); t2.step_frame()
    note("determinism", t2.state_checksum() == want_sum)
  block: # (2) capture/restore round-trip (older snapshot onto newer state).
    let l = make_link()
    for f in 0 ..< 20: l.apply(script[f][0], script[f][1]); l.step_frame()
    let snap = l.capture_state()
    for f in 20 ..< 40: l.apply(script[f][0], script[f][1]); l.step_frame()
    let sumA = l.state_checksum()
    l.restore_state(snap)
    for f in 20 ..< 40: l.apply(script[f][0], script[f][1]); l.step_frame()
    note("restore round-trip", l.state_checksum() == sumA)
  block: # (3) chained restore: continuous vs snapshot-restore-snapshot-restore.
    let cont = make_link()
    for f in 0 ..< 20: cont.apply(script[f][0], script[f][1]); cont.step_frame()
    let sumCont = cont.state_checksum()
    let l = make_link()
    for f in 0 ..< 10: l.apply(script[f][0], script[f][1]); l.step_frame()
    l.restore_state(l.capture_state())
    for f in 10 ..< 15: l.apply(script[f][0], script[f][1]); l.step_frame()
    l.restore_state(l.capture_state())
    for f in 15 ..< 20: l.apply(script[f][0], script[f][1]); l.step_frame()
    note("chained restore", l.state_checksum() == sumCont)
  block: # (4) capture on a never-stepped core (frame -1), restore, replay.
    let a = make_link()
    for f in 0 ..< 5: a.apply(script[f][0], script[f][1]); a.step_frame()
    let b = make_link()
    b.restore_state(b.capture_state())
    for f in 0 ..< 5: b.apply(script[f][0], script[f][1]); b.step_frame()
    note("frame(-1) capture", a.state_checksum() == b.state_checksum())
  block: # (5) THE failing pattern: restore an OLDER snapshot onto a link that was
    #      advanced with DIFFERENT (predicted) inputs, then replay with real input.
    let l = make_link()
    for f in 0 ..< 10: l.apply(script[f][0], script[f][1]); l.step_frame()
    let snap10 = l.capture_state()
    for f in 10 ..< 14: l.apply(script[f][0], {}); l.step_frame()  # predict empty p1
    l.restore_state(snap10)                                        # older onto newer
    l.apply(script[10][0], script[10][1]); l.step_frame()          # replay frame 10 real
    let sumR = l.state_checksum()
    let c = make_link()
    for f in 0 ..< 10: c.apply(script[f][0], script[f][1]); c.step_frame()
    c.apply(script[10][0], script[10][1]); c.step_frame()
    note("restore-older-onto-newer + replay", sumR == c.state_checksum())
  block: # (6) SIOMULTI0-3 receive latches survive capture/restore: they are
    #      NOT in state_payload, and a rollback that skipped them replays stale
    #      link words. inputrec.gba never drives SIO, so set them directly.
    let l = make_link()
    l.cores[0].serial.multi_recv = [0x1111'u16, 0x2222, 0x3333, 0x4444]
    l.cores[1].serial.multi_recv = [0xAAAA'u16, 0xBBBB, 0xCCCC, 0xDDDD]
    let snap = l.capture_state()
    l.cores[0].serial.multi_recv = [0'u16, 0, 0, 0]                 # a live round clobbers
    l.cores[1].serial.multi_recv = [0xFFFF'u16, 0xFFFF, 0xFFFF, 0xFFFF]
    l.restore_state(snap)
    note("multi_recv restored",
      l.cores[0].serial.multi_recv == [0x1111'u16, 0x2222, 0x3333, 0x4444] and
      l.cores[1].serial.multi_recv == [0xAAAA'u16, 0xBBBB, 0xCCCC, 0xDDDD])

  # Rollback run: player 0 local; player 1 remote, arriving DELAY frames
  # late, predicted as "repeat last confirmed" until it does. Invariant:
  # `confCkpt` is the state at the confirmed frontier and contains ONLY real
  # inputs; predictions live ahead of it, and a rollback restores confCkpt
  # and replays (never a prediction-tainted checkpoint).
  let link = make_link()
  var used1: array[FRAMES, set[Input]]     # p1 input actually applied per frame
  var confirmed = -1                        # highest frame with REAL p1 applied
  var confCkpt = link.capture_state()       # state AT `confirmed` (pure real)
  var present = -1                          # highest frame simulated
  var rollbacks = 0

  proc predictP1(k: int): set[Input] =
    if k <= confirmed: script[k][1]                 # real
    elif confirmed >= 0: script[confirmed][1]       # predict: repeat last real
    else: {}

  proc stepFrame(k: int) =
    used1[k] = predictP1(k)
    link.apply(script[k][0], used1[k])
    link.step_frame()

  for f in 0 ..< FRAMES:
    stepFrame(f)                    # advance presentation with prediction
    present = f
    let g = f - DELAY               # remote input for frame g is now known
    if g >= 0 and g > confirmed:
      var wrong = false
      for k in (confirmed + 1) .. g:
        if used1[k] != script[k][1]: wrong = true; break
      if wrong: inc rollbacks
      # Advance the confirmed frontier: restore the pure confCkpt, replay the
      # now-real frames confirmed+1..g, re-snapshot the (still pure) frontier at
      # g, then replay g+1..present with prediction to restore the presentation.
      link.restore_state(confCkpt)
      for k in (confirmed + 1) .. g:
        link.apply(script[k][0], script[k][1])
        link.step_frame()
        used1[k] = script[k][1]
      confirmed = g
      confCkpt = link.capture_state()
      for k in (g + 1) .. present: stepFrame(k)

  # Drain: every remote input is known; replay the tail from the frontier.
  if confirmed < FRAMES - 1:
    link.restore_state(confCkpt)
    for k in (confirmed + 1) ..< FRAMES:
      link.apply(script[k][0], script[k][1])
      link.step_frame()
    confirmed = FRAMES - 1
  let got_sum = link.state_checksum()
  let loopMatches = rollbacks > 0 and got_sum == want_sum and
    truth.cores[0].ew32(0) == link.cores[0].ew32(0) and
    truth.cores[1].ew32(0) == link.cores[1].ew32(0)
  echo "ROLLBACK ", (if loopMatches: "ok  " else: "FAIL"),
    " full input-rollback loop (", FRAMES, " frames, delay ", DELAY, ", ",
    rollbacks, " rollbacks; prediction+rollback bit-identical to inputs-known-upfront)"
  if foundation and loopMatches:
    echo "ROLLBACK: PASS"
    return 0
  echo "ROLLBACK: FAIL"
  1

proc rollback_net_test(rom, bios_path: string): int =
  ## Two RollbackSessions, peer A driving player 0 and peer B player 1, each
  ## with its own 2-core link, exchanging only per-frame inputs over DELAY.
  ## Both must match a ground-truth run with all inputs known upfront and
  ## agree with each other.
  const
    FRAMES = 120
    DELAY = 3          # inputs arrive this many coordinator steps late
    MAXAHEAD = 12
  let is_hle = bios_path == "hle" or bios_path == ""
  let actual_bios = if is_hle: "" else: bios_path
  proc make_link(): Link =
    proc mk(): GBA =
      result = new_gba(actual_bios, rom, run_bios = false, use_hle = is_hle)
      result.test_output = new_test_output()
      result.post_init()
    new_link(@[mk(), mk()])

  # Per-frame held-buttons per player, as a bitmask (bit i = Input(i)). Both
  # players change often so both peers exercise the rollback path.
  proc mask(s: set[Input]): uint16 =
    for i in s: result = result or (1'u16 shl int(i))
  var p0, p1: array[FRAMES, uint16]
  for f in 0 ..< FRAMES:
    var s0, s1: set[Input]
    if f mod 2 == 0: s0.incl A
    if f mod 5 == 0: s0.incl RIGHT
    if f mod 7 == 0: s0.incl START
    if f mod 3 == 0: s1.incl B
    if f mod 4 == 0: s1.incl LEFT
    if f mod 9 == 0: s1.incl UP
    p0[f] = mask(s0); p1[f] = mask(s1)

  # Ground truth: one link, both inputs applied every frame.
  proc applyMask(link: Link; f: int) =
    for i in 0 ..< 10:
      link.cores[0].handle_input(Input(i), ((p0[f] shr i) and 1) != 0)
      link.cores[1].handle_input(Input(i), ((p1[f] shr i) and 1) != 0)
  let truth = make_link()
  for f in 0 ..< FRAMES: truth.applyMask(f); truth.step_frame()
  let want = truth.state_checksum()

  # Two peers. A = player 0 local, B = player 1 local.
  let a = new_rollback_session(make_link(), 0, MAXAHEAD)
  let b = new_rollback_session(make_link(), 1, MAXAHEAD)
  var q_ab, q_ba: seq[(int, int, uint16)]  # (deliver_at, frame, bits)
  var step = 0
  let cap = FRAMES * 20
  while (a.head < FRAMES or b.head < FRAMES or
         a.confirmed < FRAMES - 1 or b.confirmed < FRAMES - 1) and step < cap:
    inc step
    var keepAB: seq[(int, int, uint16)]
    for m in q_ab:
      if m[0] <= step: b.feed_remote(m[1], m[2]) else: keepAB.add m
    q_ab = keepAB
    var keepBA: seq[(int, int, uint16)]
    for m in q_ba:
      if m[0] <= step: a.feed_remote(m[1], m[2]) else: keepBA.add m
    q_ba = keepBA
    if a.head < FRAMES and a.tick(p0[a.head]) == rbAdvanced:
      q_ab.add((step + DELAY, a.head - 1, p0[a.head - 1]))  # A ships player-0 input
    if b.head < FRAMES and b.tick(p1[b.head]) == rbAdvanced:
      q_ba.add((step + DELAY, b.head - 1, p1[b.head - 1]))  # B ships player-1 input

  var ok = true
  template check(cond: bool; msg: string) =
    if not cond:
      echo "ROLLBACKNET FAIL: ", msg
      ok = false
  check(a.head == FRAMES and b.head == FRAMES, "peers did not both reach the end")
  check(a.confirmed == FRAMES - 1 and b.confirmed == FRAMES - 1, "peers did not fully confirm")
  check(a.rollbacks > 0 and b.rollbacks > 0, "no rollbacks — test would be vacuous")
  check(a.checksum() == want, "peer A diverged from ground truth")
  check(b.checksum() == want, "peer B diverged from ground truth")
  check(a.checksum() == b.checksum(), "the two peers disagree (desync)")
  if ok:
    echo "ROLLBACKNET: PASS (", FRAMES, " frames, delay ", DELAY,
      "; A rollbacks=", a.rollbacks, " stalls=", a.stalls,
      ", B rollbacks=", b.rollbacks, " stalls=", b.stalls,
      "; both peers bit-identical to ground truth)"
    return 0
  echo "ROLLBACKNET: FAIL"
  1

# ==================== gambatte suite (batched) ====================
#
# sinamas' gambatte ROMs from the c-sp/game-boy-test-roms bundle, scored by
# the bundle's `gambatte/game-boy-test-roms-howto.md` rules:
#   * every ROM runs exactly 15 LCD frames from the post-boot state, then
#     the frame is read;
#   * the device is in the filename: `dmg08` = DMG, `cgb04c` = CGB; most
#     carry both and are two tests. Nearly all ship a CGB header even for
#     the DMG half, so the DMG run needs force_dmg;
#   * the expected value is `_out<hex>` (1..20 digits, may differ per
#     device), rendered as 8x8 glyphs along the top-left row; an `x` prefix
#     (`_xout0`, `_xdmg08`) means "not a test";
#   * some ROMs instead ship <rom>_dmg08.png / _cgb04c.png /
#     _dmg08_cgb04c.png and are scored on the whole frame.
# Batched: one process scores a whole list file (~5,000 runs of 15 frames).

# Hex-digit glyph bitmaps: 8 rows, one byte per row, bit 7 = leftmost,
# 1 = black. Harvested from the ROMs' own rendered output with
# `--mode=gambatte --dump-tiles` over ROMs that name the digit they draw,
# NOT copied from gambatte-core (GPL-2.0; this tree is MIT). Regenerate the
# same way if a bundle changes the font.
const GambatteGlyphs: array[16, array[8, uint8]] = [
  [0x00'u8, 0x7F'u8, 0x41'u8, 0x41'u8, 0x41'u8, 0x41'u8, 0x41'u8, 0x7F'u8],  # 0
  [0x00'u8, 0x08'u8, 0x08'u8, 0x08'u8, 0x08'u8, 0x08'u8, 0x08'u8, 0x08'u8],  # 1
  [0x00'u8, 0x7F'u8, 0x01'u8, 0x01'u8, 0x7F'u8, 0x40'u8, 0x40'u8, 0x7F'u8],  # 2
  [0x00'u8, 0x7F'u8, 0x01'u8, 0x01'u8, 0x3F'u8, 0x01'u8, 0x01'u8, 0x7F'u8],  # 3
  [0x00'u8, 0x41'u8, 0x41'u8, 0x41'u8, 0x7F'u8, 0x01'u8, 0x01'u8, 0x01'u8],  # 4
  [0x00'u8, 0x7F'u8, 0x40'u8, 0x40'u8, 0x7E'u8, 0x01'u8, 0x01'u8, 0x7E'u8],  # 5
  [0x00'u8, 0x7F'u8, 0x40'u8, 0x40'u8, 0x7F'u8, 0x41'u8, 0x41'u8, 0x7F'u8],  # 6
  [0x00'u8, 0x7F'u8, 0x01'u8, 0x02'u8, 0x04'u8, 0x08'u8, 0x10'u8, 0x10'u8],  # 7
  [0x00'u8, 0x3E'u8, 0x41'u8, 0x41'u8, 0x3E'u8, 0x41'u8, 0x41'u8, 0x3E'u8],  # 8
  [0x00'u8, 0x7F'u8, 0x41'u8, 0x41'u8, 0x7F'u8, 0x01'u8, 0x01'u8, 0x7F'u8],  # 9
  [0x00'u8, 0x08'u8, 0x22'u8, 0x41'u8, 0x7F'u8, 0x41'u8, 0x41'u8, 0x41'u8],  # A
  [0x00'u8, 0x7E'u8, 0x41'u8, 0x41'u8, 0x7E'u8, 0x41'u8, 0x41'u8, 0x7E'u8],  # B
  [0x00'u8, 0x3E'u8, 0x41'u8, 0x40'u8, 0x40'u8, 0x40'u8, 0x41'u8, 0x3E'u8],  # C
  [0x00'u8, 0x7E'u8, 0x41'u8, 0x41'u8, 0x41'u8, 0x41'u8, 0x41'u8, 0x7E'u8],  # D
  [0x00'u8, 0x7F'u8, 0x40'u8, 0x40'u8, 0x7F'u8, 0x40'u8, 0x40'u8, 0x7F'u8],  # E
  [0x00'u8, 0x7F'u8, 0x40'u8, 0x40'u8, 0x7F'u8, 0x40'u8, 0x40'u8, 0x40'u8],  # F
]

const GambatteFrames* = 15

proc gambatte_pixel(c: uint16; cgb: bool): uint32 =
  ## One pixel as the 24-bit RGB gambatte's runner compares, masked to
  ## 0xF8F8F8 (top 5 bits per channel). CGB: gambatte's documented
  ## colour-correction formulae; white lands on 0xF8F8F8 only, so glyph
  ## matching stays exact. DMG: plain grey shades, mapped as the
  ## mealybug/acid2 screenshot path does.
  if cgb:
    let r = int(c and 0x1F)
    let g = int((c shr 5) and 0x1F)
    let b = int((c shr 10) and 0x1F)
    let rr = uint32((r * 13 + g * 2 + b) shr 1)
    let gg = uint32((g * 3 + b) shl 1)
    let bb = uint32((r * 3 + g * 2 + b * 11) shr 1)
    ((rr shl 16) or (gg shl 8) or bb) and 0xF8F8F8'u32
  else:
    let s = uint32(bgr555_to_grey(c))
    ((s shl 16) or (s shl 8) or s) and 0xF8F8F8'u32

proc gambatte_tile(fb: seq[uint16]; col: int; cgb: bool): array[8, uint8] =
  ## The 8x8 tile at glyph column `col` of the screen's top row, as a
  ## bit-per-pixel mask (bit 7 = leftmost, 1 = black). A tile holding anything
  ## other than pure black and pure white comes back as all-ones, which no
  ## glyph can equal (every glyph's row 0 is blank).
  for y in 0 ..< 8:
    var bits = 0'u8
    for x in 0 ..< 8:
      let p = gambatte_pixel(fb[y * GB_WIDTH + col * 8 + x], cgb)
      if p == 0'u32: bits = bits or (0x80'u8 shr x)
      elif p != 0xF8F8F8'u32:
        return [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    result[y] = bits

proc gambatte_digit(t: array[8, uint8]): char =
  for i in 0 ..< 16:
    if GambatteGlyphs[i] == t:
      return "0123456789ABCDEF"[i]
  '?'

proc gambatte_run(rom: string; cgb: bool; frames: int): GB =
  result = new_gb("", rom, fifo = true, headless = true, run_bios = false,
                  force_cgb = cgb, force_dmg = not cgb)
  result.test_output = new_test_output()
  result.post_init()
  # Read-only fixtures in a shared cache dir: detach the battery file before
  # a frame runs, or it becomes the next run's power-on state.
  result.cartridge.sav_path = ""
  for _ in 0 ..< frames: result.step_frame()

proc gambatte_batch(list_path, out_path: string; frames, dump_tiles: int): int =
  ## Scores a list of gambatte tests in one process. Each line is
  ## `<dmg|cgb>\t<hex|png>\t<expected>\t<rom path>`; one
  ## `GAM <index> <PASS|FAIL> <detail>` line comes back per input, in order.
  ##
  ## Verdicts go to `--out=<file>` when given. The runner launches one shard
  ## per core and does not drain their stdout, so thousands of verdicts into
  ## an inherited pipe block forever; shell redirection cannot substitute,
  ## because poEvalCommand is not a shell on Windows (`> out.txt 2>&1` becomes
  ## three argv entries this parser absorbs).
  var out_file: File
  let to_file = out_path.len > 0
  if to_file and not out_file.open(out_path, fmWrite):
    echo "GAMBATTE: cannot open --out file ", out_path
    return 1
  defer:
    if to_file: out_file.close()

  var entries: seq[(string, string, string, string)]
  for line in lines(list_path):
    if line.len == 0: continue
    let f = line.split('\t')
    if f.len != 4:
      echo "GAMBATTE: malformed list line: ", line
      return 1
    entries.add((f[0], f[1], f[2], f[3]))

  var png_cache = initTable[string, PngImage]()
  var passes = 0
  for idx, (dev, kind, expected, rom) in entries:
    let cgb = dev == "cgb"
    var ok = false
    var detail = ""
    try:
      let emu = gambatte_run(rom, cgb, frames)
      let fb = emu.ppu.framebuffer
      # DINGBAT_GAM_DUMP=<dir> writes each scored frame as a PPM in the
      # comparison's colour space, to see WHERE a png row disagrees.
      let dump_dir = getEnv("DINGBAT_GAM_DUMP")
      if dump_dir.len > 0:
        var f = open(dump_dir / ($idx & "_" & dev & "_" &
                                 rom.extractFilename.changeFileExt("") & ".ppm"),
                     fmWrite)
        f.write("P6\n" & $GB_WIDTH & " " & $GB_HEIGHT & "\n255\n")
        for i in 0 ..< GB_WIDTH * GB_HEIGHT:
          let p = gambatte_pixel(fb[i], cgb)
          f.write(char((p shr 16) and 0xFF))
          f.write(char((p shr 8) and 0xFF))
          f.write(char(p and 0xFF))
        f.close()
      if dump_tiles > 0:
        var rows: seq[string]
        for col in 0 ..< dump_tiles:
          let t = gambatte_tile(fb, col, cgb)
          var s = ""
          for b in t: s.add(toHex(b, 2))
          rows.add(s)
        echo "TILES ", idx, " ", rom.extractFilename, " ", rows.join(" ")
      case kind
      of "hex":
        var got = ""
        for col in 0 ..< expected.len:
          got.add(gambatte_digit(gambatte_tile(fb, col, cgb)))
        ok = got == expected.toUpperAscii()
        detail = if ok: got else: "got " & got & ", expected " & expected.toUpperAscii()
      of "png":
        if not png_cache.hasKey(expected):
          png_cache[expected] = read_png(expected)
        let img = png_cache[expected]
        if img.width != GB_WIDTH or img.height != GB_HEIGHT or img.channels != 3:
          detail = "bad reference image " & expected
        else:
          var diff = 0
          for i in 0 ..< GB_WIDTH * GB_HEIGHT:
            let want = ((uint32(img.pixels[i * 3]) shl 16) or
                        (uint32(img.pixels[i * 3 + 1]) shl 8) or
                         uint32(img.pixels[i * 3 + 2])) and 0xF8F8F8'u32
            if gambatte_pixel(fb[i], cgb) != want: inc diff
          ok = diff == 0
          detail = if ok: "png match"
                   else: $diff & "/" & $(GB_WIDTH * GB_HEIGHT) & " pixels differ"
      else:
        detail = "unknown kind " & kind
    except CatchableError:
      detail = "exception: " & getCurrentExceptionMsg()
    if ok: inc passes
    let verdict = "GAM " & $idx & " " & (if ok: "PASS" else: "FAIL") & " " & detail
    if to_file: out_file.writeLine(verdict) else: echo verdict
  let done = "GAMBATTE-DONE " & $passes & "/" & $entries.len
  if to_file: out_file.writeLine(done) else: echo done
  0

# ==================== GBMicrotest (batched) ====================
#
# 513 ROMs of two frames each, so process spawn dominated a process-per-ROM
# run; one process per core over a list instead. Safe for these ROMs: they
# are no_save, write no files, and each gets a fresh GB.

proc microtest_run(rom: string; frames: int): GB =
  ## One GBMicrotest ROM, built and stepped exactly as the single-ROM path does
  ## (`--mode=microtest` with `--nosave`, which is how the runner invokes it).
  result = new_gb("", rom, fifo = true, headless = true, run_bios = false)
  result.test_output = new_test_output()
  result.post_init()
  # `--nosave` in the single-ROM path: blank the RAM mbc_load just filled and
  # detach the battery, so a .sav never lands beside a shared-cache fixture.
  for i in 0 ..< result.cartridge.ram.len: result.cartridge.ram[i] = 0
  result.cartridge.sav_path = ""
  for _ in 0 ..< frames:
    if result.test_output.finished: break
    result.step_frame()

proc microtest_batch(list_path, out_path: string): int =
  ## Scores a list of GBMicrotest ROMs in one process. Each line is
  ## `<frames>\t<rom path>`; one
  ## `MT <index> <PASS|FAIL> actual=0x.. expected=0x.. verdict=0x..` line
  ## comes back per input, in order. Only $FF82 is scored; $FF80/$FF81 are
  ## reported for triage, since some ROMs leave actual == expected on a
  ## failure. `--out` for the same reason gambatte_batch has one.
  var out_file: File
  let to_file = out_path.len > 0
  if to_file and not out_file.open(out_path, fmWrite):
    echo "MICROTEST: cannot open --out file ", out_path
    return 1
  defer:
    if to_file: out_file.close()

  var entries: seq[(int, string)]
  for line in lines(list_path):
    if line.len == 0: continue
    let f = line.split('\t')
    if f.len != 2:
      echo "MICROTEST: malformed list line: ", line
      return 1
    var frames: int
    try: frames = parseInt(f[0])
    except ValueError:
      echo "MICROTEST: bad frame count: ", line
      return 1
    entries.add((frames, f[1]))

  for idx, (frames, rom) in entries:
    var ok = false
    var detail = ""
    try:
      let emu = microtest_run(rom, frames)
      let actual   = emu.memory.hram[0]   # $FF80
      let expected = emu.memory.hram[1]   # $FF81
      let verdict  = emu.memory.hram[2]   # $FF82
      ok = verdict == 0x01'u8
      detail = "actual=0x" & toHex(actual) & " expected=0x" & toHex(expected) &
               " verdict=0x" & toHex(verdict)
    except CatchableError:
      detail = "exception: " & getCurrentExceptionMsg()
    let line = "MT " & $idx & " " & (if ok: "PASS" else: "FAIL") & " " & detail
    if to_file: out_file.writeLine(line) else: echo line
  0

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
  var link_contract = lcMulti
  var attach_after = 10
  var force_cgb = false
  var force_dmg = false    # --dmg: run a CGB-flagged cart on DMG hardware
  var force_sgb = false    # --sgb: run the cart in a Super Game Boy
  var no_save = false      # --nosave: blank cart RAM and detach the .sav file
  var screen_check = false # --screen-check: panel settled + not blank (see below)
  var ed_breakpoint = false  # --ed-breakpoint: 0xED ends a run (wilbertpol mooneye)
  var bb_breakpoint = false  # --bb-breakpoint: LD B,B always ends a run (AGE)
  var model_override = ""  # mooneye per-model boot table (--model=dmg0|mgb|sgb|sgb2|cgb0|agb...)
  var max_fails = 500      # fuzzarm mode: cap on reported failures per ROM
  var list_path = ""       # gambatte mode: batch list file
  var out_path = ""        # gambatte mode: verdict file (see gambatte_batch)
  var gambatte_frames = GambatteFrames
  var dump_tiles = 0       # gambatte mode: dump the first N top-row tiles

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
        of "normlinktest": mode = tmNormLinkTest
        of "norm32linktest": mode = tmNorm32LinkTest
        of "attachtest": mode = tmAttachTest
        of "netlink": mode = tmNetLink
        of "speclink": mode = tmSpecLink
        of "speclinkbench": mode = tmSpecLinkBench
        of "rollback": mode = tmRollback
        of "rollbacknet": mode = tmRollbackNet
        of "gblinktest": mode = tmGbLinkTest
        of "jsmolka": mode = tmJsmolka
        of "fuzzarm": mode = tmFuzzArm
        of "magen-green": mode = tmMagenGreen
        of "magen-nored": mode = tmMagenNoRed
        of "gambatte": mode = tmGambatte
        of "microtest": mode = tmMicrotest
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
      of "cgb":
        force_cgb = true
      of "dmg":
        force_dmg = true
      of "sgb":
        force_sgb = true
      of "nosave":
        no_save = true
      of "screen-check":
        screen_check = true
      of "ed-breakpoint":
        ed_breakpoint = true
      of "bb-breakpoint":
        bb_breakpoint = true
      of "model":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        model_override = v.toLowerAscii()
      of "cgb-rev":
        # Sugar over --model for the CGB axis: --cgb-rev=D is --model=cgbd.
        # Same variable, so the two cannot disagree.
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        v = v.toLowerAscii()
        if v.len == 1 and v[0] in {'0', 'a'..'e'}:
          model_override = "cgb" & v
        else:
          model_override = v
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
      of "link-contract":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        case v.toLowerAscii()
        of "multi": link_contract = lcMulti
        of "normal": link_contract = lcNormal
        of "normal32": link_contract = lcNormal32
        else:
          echo "Unknown link contract: ", v, " (use multi, normal, or normal32)"
          quit(1)
      of "attach-after":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        attach_after = parseInt(v)
      of "max-fails":
        # fuzzarm: cap on reported failures; each costs two frames of
        # button-ack.
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        max_fails = parseInt(v)
      of "list":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        list_path = v
      of "out":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        out_path = v
      of "gambatte-frames":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        gambatte_frames = parseInt(v)
      of "dump-tiles":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        dump_tiles = parseInt(v)

  if mode == tmGambatte:
    if list_path.len == 0:
      echo "gambatte mode wants --list=<file> (see gambatte_batch)"
      quit(1)
    quit(gambatte_batch(list_path, out_path, gambatte_frames, dump_tiles))

  # microtest takes EITHER one ROM (the original path, still used by hand) or
  # --list for the batched sweep the runner drives.
  if mode == tmMicrotest and list_path.len > 0:
    quit(microtest_batch(list_path, out_path))

  if rom_path.len == 0:
    echo "Usage: dingbat_test <rom_path> --mode <serial|sram|mooneye|mgba|mgba-suite|jsmolka|fuzzarm|microtest|screenshot|stateroundtrip> [--timeout <frames>] [--frames <warmup>] [--screenshot <path.ppm>] [--max-fails <n>] [--nosave] [--screen-check] [--cgb|--dmg|--sgb] [--cgb-rev <0|A|B|C|D|E>] [--model <token>]"
    quit(1)

  if mode == tmStateRoundtrip:
    quit(state_roundtrip(rom_path, bios_path, warmup_frames))
  if mode == tmRewindTest:
    quit(rewind_test(rom_path, bios_path))
  if mode == tmJsmolka:
    quit(jsmolka_test(rom_path, bios_path, timeout_frames))
  if mode == tmFuzzArm:
    quit(fuzzarm_test(rom_path, bios_path, timeout_frames, max_fails))
  if mode in {tmMagenGreen, tmMagenNoRed}:
    quit(magen_test(rom_path, timeout_frames, mode == tmMagenGreen))
  if mode in {tmLinkTest, tmNormLinkTest, tmNorm32LinkTest}:
    # Second positional arg is core 2's ROM; defaults to running the same
    # ROM on both cores. The normal-mode variants run the same coordinator
    # with their own EWRAM contract.
    let rom2 = if rom_path2.len > 0: rom_path2 else: rom_path
    let contract = case mode
      of tmNormLinkTest: lcNormal
      of tmNorm32LinkTest: lcNormal32
      else: lcMulti
    quit(link_test(rom_path, rom2, bios_path, timeout_frames, contract))
  if mode == tmGbLinkTest:
    let rom2 = if rom_path2.len > 0: rom_path2 else: rom_path
    quit(gb_link_test(rom_path, rom2, timeout_frames))
  if mode == tmAttachTest:
    quit(attach_test(rom_path, bios_path, timeout_frames, attach_after))
  if mode == tmSpecLink:
    let delay = if netlink_delay > 0: netlink_delay else: 20
    quit(spec_link_test(rom_path, bios_path, link_contract, delay, timeout_frames))
  if mode == tmSpecLinkBench:
    let delay = if netlink_delay > 0: netlink_delay else: 50
    quit(spec_link_bench(rom_path, bios_path, link_contract, delay, timeout_frames))
  if mode == tmRollback:
    quit(rollback_test(rom_path, bios_path))
  if mode == tmRollbackNet:
    quit(rollback_net_test(rom_path, bios_path))
  if mode == tmNetLink:
    if (listen_port > 0) == (connect_to.len > 0):
      echo "netlink mode needs exactly one of --listen PORT or --connect HOST:PORT"
      quit(1)
    quit(netlink_test(rom_path, bios_path, listen_port, connect_to,
                      timeout_frames, netlink_delay, link_contract))

  let ext = rom_path.splitFile().ext.toLowerAscii()
  let is_gba = ext in [".gba", ".bin"]
  let test_out = new_test_output()
  test_out.ed_breakpoint = ed_breakpoint
  test_out.bb_breakpoint = bb_breakpoint

  if is_gba:
    let is_hle = bios_path == "hle" or bios_path == ""
    let actual_bios = if is_hle: "" else: bios_path
    let emu = new_gba(actual_bios, rom_path, run_bios = false, use_hle = is_hle)
    emu.test_output = test_out
    emu.post_init()
    # Same knob as dingbat_bench: idle-loop fast-forward snaps scheduler.cycles
    # to the next event, so a spin loop's exit cycle depends on what is
    # queued. Off, a real timing error is separable from sampling resolution.
    if getEnv("DINGBAT_NO_WAITLOOP") == "1":
      emu.cpu.attempt_waitloop_detection = false
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
    # External screenshot suites name the DEVICE per row, so in
    # --mode=screenshot the absence of --cgb means "run on a DMG", or a cart
    # with $0143 = $80 is silently scored on the wrong hardware (the same
    # contract as --mode=gambatte). Other modes let the header pick.
    let dmg = force_dmg or (mode == tmScreenshot and not force_cgb)
    let emu = new_gb("", rom_path, fifo = true, headless = true, run_bios = false,
                     force_cgb = force_cgb, force_dmg = dmg)
    if force_sgb:
      # --sgb names the device the way --cgb does; the core still header-gates
      # it (src/dingbat.nim's load_rom sets this from cfg.sgb_enable), so a
      # cart without the SGB flag pair runs as a plain DMG.
      emu.sgb_requested = true
    if model_override.len > 0:
      # One token selects the whole machine: gb_revision_from_name -> GbRevision,
      # and gb_set_revision derives the boot table and quirk set from it.
      let (rev, ok) = gb_revision_from_name(model_override)
      if not ok:
        echo "Unknown model: ", model_override
        quit(1)
      emu.gb_set_revision(rev)
    emu.test_output = test_out
    emu.post_init()
    if no_save:
      # A battery-backed suite ROM otherwise drops a .sav next to the ROM in
      # the shared cache dir and the next run loads it as power-on state.
      # Blank the RAM (mbc_load already ran in new_gb) and detach the file.
      for i in 0 ..< emu.cartridge.ram.len: emu.cartridge.ram[i] = 0
      emu.cartridge.sav_path = ""
    if mode == tmSram:
      # blargg's SRAM-reporting ROMs must run against a blank battery: a .sav
      # from an earlier run is loaded at construction and its finished status
      # byte would be read as this run's verdict.
      for i in 0 ..< emu.cartridge.ram.len: emu.cartridge.ram[i] = 0
      emu.cartridge.sav_path = ""
    for frame in 0 ..< timeout_frames:
      if test_out.finished: break
      emu.step_frame()
      if mode == tmSerial and test_out.serial_buffer.len > 0:
        if test_out.serial_buffer.contains("Passed") or
           test_out.serial_buffer.contains("Failed"):
          test_out.finished = true
      if mode == tmSram and emu.cartridge.ram.len >= 4:
        # Signature "DEB061" at $A001..$A003 marks the result block valid, but
        # blargg's framework writes it up front with status $80 = "still
        # running" and only replaces that byte with the verdict (0 = pass) when
        # the test ends. Latching $80 scores every test as a failure.
        if emu.cartridge.ram[1] == 0xDE'u8 and
           emu.cartridge.ram[2] == 0xB0'u8 and
           emu.cartridge.ram[3] == 0x61'u8 and
           emu.cartridge.ram[0] != 0x80'u8:
          test_out.sram_status = emu.cartridge.ram[0]
          var text = ""
          for i in 4 ..< emu.cartridge.ram.len:
            let b = emu.cartridge.ram[i]
            if b == 0: break
            text.add(char(b))
          test_out.sram_text = text
          test_out.finished = true
    # --screen-check: the weakest GB screen assertion that holds however the
    # ROM's console races the PPU. No glyph comparison: blargg's console blits
    # with the LCD on behind a bounded VBlank wait that routinely times out at
    # CGB double speed, so cells land in mode 3 and are refused, and which
    # ones depends on sub-scanline phase (tests/README.md, "blargg's on-screen
    # text is NOT an oracle"). What must hold: the panel settles and shows
    # more than one shade.
    if screen_check:
      # The serial verdict arrives before the console has finished drawing it,
      # so give the panel a bounded settling budget rather than sampling
      # immediately: 10 identical frames in a row, within 240 frames.
      var prev = emu.ppu.framebuffer
      var run = 0
      var stable = false
      for _ in 0 ..< 240:
        emu.step_frame()
        if emu.ppu.framebuffer == prev: inc run else: run = 0
        prev = emu.ppu.framebuffer
        if run >= 10:
          stable = true
          break
      var shades = 0
      var seen: seq[uint16]
      for px in emu.ppu.framebuffer:
        if px notin seen:
          seen.add(px)
          inc shades
          if shades > 1: break
      if not stable:
        echo "SCREENCHECK: FAIL (framebuffer never settled within 240 frames of the verdict)"
        quit(1)
      if shades < 2:
        echo "SCREENCHECK: FAIL (framebuffer is one flat colour)"
        quit(1)
      # Silent on success: this line would otherwise land in every cpu_instrs
      # row's output column in results.md.

    # Screenshot mode: write framebuffer as PPM after running
    if mode == tmScreenshot and screenshot_path.len > 0:
      write_ppm(screenshot_path, emu.ppu.framebuffer, GB_WIDTH, GB_HEIGHT, color_mode)
      echo screenshot_path
      quit(0)
    # GBMicrotest: the ROM writes $FF80 actual, $FF81 expected, $FF82 verdict
    # ($01 pass / $FF fail) and keeps running, so run --timeout frames and
    # read HRAM. Only $FF82 is scored: some tests leave $FF80 == $FF81 on a
    # failure.
    if mode == tmMicrotest:
      let actual   = emu.memory.hram[0]   # $FF80
      let expected = emu.memory.hram[1]   # $FF81
      let verdict  = emu.memory.hram[2]   # $FF82
      echo "MICROTEST actual=0x", toHex(actual), " expected=0x", toHex(expected),
           " verdict=0x", toHex(verdict)
      if verdict == 0x01'u8:
        echo "MICROTEST: PASS"
        quit(0)
      echo "MICROTEST: FAIL"
      quit(1)

  # Determine result
  var passed = false
  var output = ""

  case mode
  of tmSerial:
    output = test_out.serial_buffer
    passed = output.contains("Passed")
  of tmSram:
    output = test_out.sram_text
    # `finished` says the ROM actually reported: sram_status is only latched
    # out of a valid "DEB061" block and its 0 initializer is blargg's PASS
    # code, so a ROM that hangs or outruns its budget (blargg's standalone
    # 7-timing_effect) would otherwise score a pass on saying nothing.
    passed = test_out.finished and test_out.sram_status == 0
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
  of tmMicrotest:
    echo "microtest mode is Game Boy only"
    quit(1)
  of tmStateRoundtrip, tmRewindTest, tmLinkTest, tmNormLinkTest,
     tmNorm32LinkTest, tmAttachTest, tmNetLink, tmSpecLink, tmSpecLinkBench,
     tmRollback, tmRollbackNet, tmGbLinkTest, tmJsmolka, tmFuzzArm,
     tmMagenGreen, tmMagenNoRed, tmGambatte:
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
