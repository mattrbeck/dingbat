import std/[os, strutils, parseopt, net, nativesockets, monotimes, times]
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
    tmMagenGreen, tmMagenNoRed

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
# logs its four receive latches, SIOCNT role bits, and serial-IRQ count to
# fixed EWRAM addresses. Runs both cores under the lockstep coordinator and
# asserts both units observed identical, correct rounds. Exits 0 iff all
# checks pass.
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
      let irqs = g.memory.wram[0][0x808]
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
# NO link, let them spin in the role-negotiate loop, then plug the lockstep
# link in mid-run — the deterministic analogue of the browser's "link cable
# detected -> attach" flow (netlink_attach in the wasm bridge). Because the
# ROM re-reads SI every pass, it picks up the freshly attached cable and
# completes the multi-mode rounds; the linktest ROM cannot do this (it
# latches its role at boot). Asserts with the multi-mode contract.
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

# Networked link acceptance (phase 3a of docs/multiplayer.md): two dingbat
# processes run the linktest ROM over TCP, one with --listen PORT (unit 0,
# multi-mode parent candidate) and one with --connect HOST:PORT (unit 1).
# Each process asserts its own unit's EWRAM log — run both and require PASS
# from both. --netlink-delay-ms N adds an artificial delay to every message
# send (internet-latency simulation); the test must still pass, just slower.
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

# jsmolka's gba-tests (github.com/jsmolka/gba-tests) share one protocol, in
# lib/macros.inc: every ROM keeps its verdict in r12, branches to a common
# `eval` on the FIRST failing check with r12 = that check's number, and then
# spins forever in `idle: b idle`. `m_test_eval` brackets its own work in
# stmfd/ldmfd {r0-r12}, so r12 still holds the verdict once the spin is
# reached: 0 = every check passed, N = check N failed (and nothing after it
# ran — these ROMs abort on first failure by design).
#
# Reading r12 rather than OCR-ing the rendered "Failed test NNN" is deliberate:
# the on-screen report is itself produced by SWI 6 (Div) plus a mode-4 blit, so
# scoring off pixels makes every result depend on the BIOS and PPU as well as
# on the thing under test. r12 is the ROM's own verdict.
proc jsmolka_test(rom_path, bios_path: string; timeout_frames: int): int =
  let is_hle = bios_path == "hle" or bios_path == ""
  let actual_bios = if is_hle: "" else: bios_path
  let emu = new_gba(actual_bios, rom_path, run_bios = false, use_hle = is_hle)
  emu.test_output = new_test_output()
  emu.post_init()
  # The save/ ROMs check what an *untouched* backup chip reads back (SRAM's
  # first check wants 0xFF), and every ROM that writes one would otherwise
  # drop a .sav next to the ROM for the next run to load back as "power-on"
  # state. Detach the file: new_storage has already applied the power-on fill,
  # and write_save is a no-op on an empty path.
  emu.storage.save_path = ""

  # The spin is a one-instruction self-branch, so once it is reached r15 is
  # constant at every frame boundary. Two frames of a stationary PC is the
  # done signal; anything still executing (including the m_vsync wait in
  # `eval`) moves it.
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
# FuzzARM ships five prebuilt ROMs, each 10000 randomly generated ARM/Thumb
# instruction tests (data processing with every shift type, multiplies,
# load/stores). The ROM's own reporting is threefold: a mode-4 render of the
# failing instruction, a structured 16-word dump at the base of eWRAM, and a
# "press any button to continue" gate. This mode drives the third and reads
# the second, so the verdict never depends on the PPU, the BIOS or a pinned
# frame hash — and, crucially, it can report *every* failing test rather than
# just the first, which is the whole point of a randomized suite.
#
# The protocol (asm/run_tests.asm upstream):
#   * on a mismatch the ROM writes 16 words to 0x02000000 and then spins in
#     `wait_until_keys_up` / `wait_until_key_down`, reading KEYINPUT;
#   * pressing any button other than L/R resumes at the next test;
#   * when the last test is done it draws "End of testing" and falls into a
#     one-instruction self-branch in main.asm.
# KEYINPUT is the ONLY input register the ROM ever touches (upstream README:
# "I do not use any SWIs/DMAs/Timers/IRQs/Weird IO registers (Only DISPCNT and
# KEYINPUT)"), so `keyinput_reads` moving across a frame is an exact "a failure
# report is on screen right now" signal — no address table, no disassembly.
#
# eWRAM layout, 16 words at 0x02000000 (upstream README + the store sequence in
# _test_error). Words 10 and 14 are never stored; they are the documented
# "0000 0000" padding.
#   0      'AAAA' / 'TTTT'   ARM or Thumb state
#   1-3    opcode text, 12 ASCII chars ("tst lsl     ", "smull       ", ...)
#   4-6    initial r0, r1, r2      7   initial CPSR
#   8-9    got r3, r4              11  got CPSR
#   12-13  expected r3, r4         15  expected CPSR
# r3 is the shifted operand and r4 the result, so which of the three differs
# already separates a barrel-shifter bug from an ALU bug from a flag bug.
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
  ## Address of `mainloop: b mainloop` (main.asm) — the one-instruction self
  ## branch the ROM falls into after "End of testing". Encoded 0xEAFFFFFE and,
  ## in all five prebuilt ROMs, the only word in the image with that value (the
  ## generated test table is random data, so a collision is ~1e-5 likely; the
  ## uniqueness check below is what keeps this honest anyway).
  ##
  ## Do NOT score "finished" as "PC unchanged across two frame boundaries" the
  ## way the jsmolka mode does. This ROM never waits on vblank, so a frame
  ## boundary lands at an arbitrary point in a tight drawing loop, and two
  ## consecutive boundaries landing on the same instruction is common — it
  ## silently truncated whole runs (ARM_Any scored 10000/10000 while executing
  ## only a few hundred tests). Returns 0 if the marker is not unique.
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
  ## Recover how many tests the ROM was generated with, straight out of the
  ## image. `run_tests` opens with `stmdb sp!, {r0-r12, lr}` (0xE92D5FFF),
  ## then the four-instruction `set_word r11, MEM_ROM + tests` macro, then
  ## `ldmia r11!, {r12}` — so ORing those four rotated immediates gives the
  ## address of the count word the ROM itself reads. Returns 0 if the pattern
  ## is gone (a regenerated ROM whose layout moved); only the printed total
  ## depends on it, never the verdict.
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

  # Triage rollup, grouped by state + opcode + which of r3/r4/CPSR disagreed
  # (and for CPSR, which flags). Stderr, not stdout: the runner captures only
  # stdout, so results.md stays a one-liner while a CI log keeps the detail.
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

  let total_str = if total > 0: $total else: "?"
  if capped:
    echo "<=" & (if total > 0: $(total - fails.len) else: "?") & "/" & total_str &
         " passed (stopped after " & $fails.len & " failures)"
    return 1
  if not finished:
    echo "timed out after " & $frames & " frames (" & $fails.len &
         " failures so far)"
    return 1
  if fails.len == 0:
    echo total_str & "/" & total_str & " passed"
    return 0
  echo (if total > 0: $(total - fails.len) else: "?") & "/" & total_str &
       " passed (" & $fails.len & " failed)"
  return 1

# ==================== alloncm/MagenTests ====================
#
# CGB test ROMs (MIT) whose verdict is the screen colour, not a reference
# image. src/common.asm fixes the palette: WHITE $FFFF, RED $001F,
# GREEN $03E0, BLUE $7C00, and each ROM's README entry says what they mean.
#
# Deliberately NOT scored by screenshot comparison: the repo's images/ holds a
# 641x574 upscale, a 318x295 SameBoy window grab, two 15x17 swatches and a
# photo of real hardware — nothing that is a 160x144 frame — so there is no
# bundled reference to diff against, and a self-generated frame hash would be
# a golden with nothing behind it. Counting the ROM's own documented colours
# is the ROM's own contract.
#
#   magen-green: "the screen should be all green"; red and blue are the two
#     named failure modes (for hblank_vram_dma: red = the HBlank HDMA never
#     ran, blue = it ran while the CPU was halted).
#   magen-nored: bg_oam_priority draws a pattern, and its stated result is
#     "5 green squares and 3 half green and half blue squares with no red
#     lines" — so the machine-checkable part is the absence of red. Weaker
#     than the other six by construction. (For the record, dingbat renders
#     exactly 416 green and 96 blue pixels, which is 5*8*8 + 3*(8*8/2) and
#     3*(8*8/2) — i.e. the described geometry to the pixel — but the gate
#     stays on the documented rule rather than baking those counts in.)
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

# Speculative-rollback acceptance (docs/multiplayer.md phase 3c): drives two
# NetCores in-process through a deterministic coordinator that shuttles wire
# frames between them with a fixed per-message latency (measured in coordinator
# iterations, not wall-clock, so runs are reproducible and OFF/ON are directly
# comparable). The committed linktest.gba self-drives 16 multi-mode rounds.
#
# The correctness bar is the EWRAM round log (round data + role bits + serial
# IRQ count) — timing-tolerant by construction, so it isolates *what the games
# exchanged* from the exact cycle skew the wider speculative lead introduces.
# Speculation must reproduce it bit-for-bit vs the blocking path, even when the
# predictor is forced to mispredict (rollback must recover).

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
  # Speculation is a master-side feature: only the initiator (unit 0, the
  # multi-mode parent / normal-mode internal-clock master) predicts. The
  # responder runs the ordinary blocking path either way, so it stays bit-
  # identical without the responder-side checkpoint cost — this mirrors how a
  # real frontend would enable it.
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
    # Terminate once both ROMs are done AND (for speculation) every latched
    # round has been confirmed by a real REPLY — i.e. the visible state has
    # settled to the blocking path. Beacons keep flowing forever while the
    # ROMs spin, so we must NOT wait for the queues to empty; but a reply that
    # is still in flight keeps all_confirmed false, so we drain those first.
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
  ## Honest speculation benchmark. Runs a long, symmetric handshake (the
  ## speclinkbench ROM) OFF, then ON with the OLD "same as last" predictor and
  ## ON with the NEW echo-aware predictor, at 0 ms and `delay` latency. Reports
  ## the metric the SPECLINK speed proxy is blind to: `replay_cyc` (cycles the
  ## master RE-EMULATED on rollbacks), `overrun` (rollbacks that outran the log
  ## → lossy divergence), and CPU ms. Hard-asserts the SHIPPED echo predictor
  ## stays bit-identical to the blocking path AND slashes the re-emulation the
  ## old "same as last" predictor wastes on the symmetric handshake. The old
  ## predictor is REPORTED (it is the thing being replaced) — under heavy thrash
  ## it drives so many deep rollbacks it even loses bit-identity (overrun>0),
  ## which is itself the argument for a predictor that keeps rollbacks rare.
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
  ## Harness for the INPUT-ROLLBACK netplay model (the correct architecture for a
  ## deterministic 2-player link): run BOTH cores locally, network only the two
  ## players' inputs, predict the remote input and roll back when a late input
  ## mispredicts. The SIO cable is resolved locally, so there is no RTT problem
  ## and no unrecallable speculative bytes (the flaw that desyncs the SIO-word
  ## scheme, see speclinkdep). Uses inputrec.gba, whose accumulator depends on
  ## the exact input TIMELINE, so a wrong-then-corrected input must replay
  ## faithfully or the result differs. Also checks the machinery primitives
  ## (determinism, capture/restore round-trip, chained restore, frame(-1)
  ## capture, and restore-older-onto-newer-then-replay — the pattern a rollback
  ## actually performs). All pass once the bus ROM burst/prefetch timing
  ## trackers are serialized (savestate v3); before that, a restore mistimed the
  ## first ROM access by a few cycles and the frame ended off-by-a-few-cycles.
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
  block: # (6) SIOMULTI0-3 receive latches survive capture/restore. They back the
    #      game's link reads (serial.nim read path) but are NOT in state_payload
    #      (savestate refreshes them next transfer), so a rollback that didn't
    #      snapshot them would replay stale link words — an in-game "communication
    #      error" mid-trade under real latency (frequent rollbacks). inputrec.gba
    #      never drives SIO, so set the latches directly to exercise the path.
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

  # Rollback run: player 0 local (always known); player 1 remote, arriving DELAY
  # frames late, predicted as "repeat last confirmed" until it does.
  #
  # The invariant that makes this correct and simple: `confCkpt` is the state at
  # the confirmed frontier and contains ONLY real inputs, because it is produced
  # exclusively by replaying real inputs from the previous confCkpt. Predictions
  # only ever live AHEAD of the frontier; a rollback restores confCkpt (never a
  # prediction-tainted checkpoint) and replays. This is the crux GGPO gets right
  # and the naive "roll back to the mispredicted frame" gets wrong.
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
  ## Two-sided end-to-end test of the RollbackSession (the transport-agnostic
  ## netplay engine). Two independent sessions — peer A drives player 0, peer B
  ## drives player 1 — each run their OWN 2-core link, exchange only per-frame
  ## inputs over a DELAY, predict the peer and roll back on mispredictions. Both
  ## must converge to the same state as a ground-truth run where every input was
  ## known upfront, and must agree with each other (the peer desync check).
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
  var model_override = ""  # mooneye per-model boot table (--model=dmg0|mgb|sgb|sgb2|cgb0|agb...)
  var max_fails = 500      # fuzzarm mode: cap on reported failures per ROM

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
      of "model":
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        model_override = v.toLowerAscii()
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
        # fuzzarm mode: stop after this many reported failures. Each one costs
        # two emulated frames of button-ack, so an emulator that fails most of
        # the 10000 tests would otherwise take minutes.
        var v = p.val
        if v.len == 0: p.next(); v = p.key
        max_fails = parseInt(v)

  if rom_path.len == 0:
    echo "Usage: dingbat_test <rom_path> --mode <serial|sram|mooneye|mgba|mgba-suite|jsmolka|fuzzarm|screenshot|stateroundtrip> [--timeout <frames>] [--frames <warmup>] [--screenshot <path.ppm>] [--max-fails <n>]"
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
    let emu = new_gb("", rom_path, fifo = true, headless = true, run_bios = false,
                     force_cgb = force_cgb)
    if model_override.len > 0:
      emu.boot_model = case model_override
        of "dmg0": bmDmg0
        of "dmg", "dmgabc", "dmgabcmgb": bmDmgABC
        of "mgb": bmMgb
        of "sgb", "s": bmSgb
        of "sgb2": bmSgb2
        of "cgb0": bmCgb0
        of "cgb", "cgbabcde", "c": bmCgbABCDE
        of "agb", "ags", "a": bmAgb
        else:
          echo "Unknown model: ", model_override
          quit(1)
    emu.test_output = test_out
    emu.post_init()
    if mode == tmSram:
      # blargg's SRAM-reporting ROMs (dmg_sound/cgb_sound/oam_bug/...) must run
      # against a blank battery and must not leave one behind: a .sav dropped
      # next to the ROM by an earlier run is loaded back at construction, and
      # its finished status byte is read as *this* run's verdict before the ROM
      # has executed an instruction. Wipe the RAM and detach the save file.
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
  of tmStateRoundtrip, tmRewindTest, tmLinkTest, tmNormLinkTest,
     tmNorm32LinkTest, tmAttachTest, tmNetLink, tmSpecLink, tmSpecLinkBench,
     tmRollback, tmRollbackNet, tmGbLinkTest, tmJsmolka, tmFuzzArm,
     tmMagenGreen, tmMagenNoRed:
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
