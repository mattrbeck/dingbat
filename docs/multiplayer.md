# Local multiplayer & cross-emulator link — investigation (2026-07)

Goal: link-cable multiplayer, ideally interoperable with other emulators.
This document maps the ecosystem, what dingbat has today, and a phased plan.

## What exists in the ecosystem

**GBA↔GBA, cross-emulator: there is no standard.** Each emulator that links
does so with its own mechanism:

- **mGBA**: local multiplayer only — up to 4 GBA cores *in one process*,
  coordinated by a lockstep driver (`GBASIOLockstep`). Player 0 is the clock
  master; secondaries run in bounded lockstep with it. No network transport;
  networked link is a long-open feature request
  ([#2379](https://github.com/mgba-emu/mgba/issues/2379),
  [#2469](https://github.com/mgba-emu/mgba/issues/2469)).
- **VBA-M**: the only emulator with GBA↔GBA link over TCP (localhost or LAN,
  up to 4 players). The protocol is bespoke, undocumented outside the source
  (`GBALink.cpp`), and known to be timing-fragile (it trades accuracy for
  latency tolerance with a "speed hack" option). It is the de-facto — and
  only — target if we want GBA↔GBA interop with another emulator today.
- **JoyBus over TCP** (GBA↔GameCube): the one *well-defined* cross-emulator
  link protocol in this space. Dolphin's "Integrated GBA" speaks it to GBA
  emulator instances (mGBA has it built in; VBA-M supported it historically;
  the standalone [jbus](https://github.com/AxioDL/jbus) library documents it,
  default port 5738). Implementing the GBA side would let dingbat act as the
  handheld for Dolphin (Four Swords Adventures, Final Fantasy CC, etc.).
- **GB/GBC: the BGB link protocol** is a genuine cross-emulator standard
  ([spec](https://bgb.bircd.org/bgblink.html)): TCP, fixed 8-byte packets
  (command + 3 data bytes + 32-bit timestamp in 2 MHz cycles), master sends
  `sync1` with the byte + SC bits, slave answers `sync2`, and both sides use
  the timestamp delta to decide when to stall for the peer. Implemented by
  BGB and Emulicious; dingbat's GB core could interoperate with both.

## What dingbat has today

`src/dingbat/gba/serial.nim` emulates the *registers* faithfully for the
no-cable case (mGBA suite SIO R/W 90/90, SIO timing 4/4): mode decoding
(normal 8/32, multi, UART, general-purpose, JoyBus), pin-state readback,
read masks, transfer duration for internal-clock normal transfers, the
serial IRQ. There is no link plumbing at all:

- External-clock normal transfers "never start" (no master to drive SC).
- Multi-mode start bit hangs forever by design (suite expects the timeout).
- No abstraction where a second party could inject/receive data.

Useful existing assets: the scheduler is deterministic; save states +
`stateroundtrip` give us serialization; the rewind ring buffer proves we can
snapshot cheaply (useful for any future rollback experiments).

## What's required, in dependency order

### 1. SIO driver abstraction (prerequisite for everything)

A `SioDriver` interface on `Serial`, mirroring mGBA's design:

- `attached(mode)` / `detached()` — RCNT/SIOCNT mode changes re-bind.
- `start(transfer)` — called on SIOCNT start-bit rising edge instead of the
  hardcoded no-cable behavior; the driver later completes the transfer
  (`finish(data, at_cycle)`), which fills SIODATA/SIOMULTI, clears busy,
  raises the IRQ. The current no-cable behavior becomes the null driver.
- Multi-mode needs roles: master (internal clock) initiates; slaves get a
  callback window to contribute their SIOMLT_SEND and all four slots are
  distributed on completion.

Cheap first client: a **loopback driver** (SO→SI, master-only) — this is
what the AGS aging cartridge's COM test expects from the factory loopback
plug, so it gives us an immediate hardware-verified test case.

#### COM test findings (2026-07, from AGB_CHECKER TCHK10 disassembly)

The loopback-plug theory above turned out to be wrong. What the checker
actually does (all addresses TCHK10, `AGB/AGS TEST PROGRAM Version 7.0`;
TCHK30 v9.0 behaves identically):

- **The aging program never runs the COM test.** The aging-mode entry point
  (0x8000478) unconditionally disables the interactive KEY INPUT test
  (0x80004BC: clear enable word of section 5 test 0) and the entire COM
  section (0x80004C4: `movs r0, #4; bl 0x8000C04` clears every enable word
  in section 4) before the first pass. There is no cable probe — the "-"
  next to COM on the aging screen is unconditional, on real hardware too.
  The per-test state lives in IWRAM (COM: 5 words at 0x3000234 =
  {enabled/attempts, passes, errors, handler=0x800AE31, name=0x801864C});
  the status renderer (0x8000E14) prints "-" when word 0 is 0.
- **The COM test itself ("MULTI PLAY SIO", handler 0x800AE30) is a
  two-unit multiboot test, not a loopback test.** It first shows
  "PREPARE CABLE(AGB-005) AND ANOTHER AGB … TURN ON ANOTHER AGB.
  PUSH START TO CONTINUE" (strings at 0x807A900..) and waits for START.
  It then DMAs a 1372-byte multiboot image from ROM 0x807AA6C (a valid
  cartridge header: ARM branch + Nintendo logo) into EWRAM and drives the
  SDK multi-play/multiboot library (init 0x8011534: RCNT=0, SIOCNT=0x2003 —
  multi mode, 115200 baud). The send path (0x8011CF4) requires
  `(SIOCNT & 0xFC) == 8` — SD=1, SI=0, ID=0, no error, i.e. "I am the
  parent of a ready bus" — then broadcasts 0x6200 once per frame, up to a
  120-frame timeout, expecting a BIOS multiboot slave to answer (0x720x in
  SIOMULTI1-3).
- **Loopback therefore cannot pass it.** The loopback driver's multi-mode
  status (parent, SD=1, ID=0) satisfies the library's bus-ready check and
  the transfers run and complete, but the parent only ever sees its own
  0x6200 echoed in SIOMULTI0 and 0xFFFF (absent) in slots 1-3, so the
  handshake times out. Verified empirically by force-enabling the test in
  the emulator (poke [0x3000234]=1, auto-press START): with the loopback
  driver it runs the full flow — 120 multi transfers of 0x6200 — and shows
  COM: X FAIL.
- **What a PASS needs**: a second unit speaking the BIOS multiboot slave
  protocol — either a second in-process GBA core sitting in the BIOS's
  multiboot wait (phase 2 below), or a small HLE "multiboot slave" SIO
  driver that answers 0x720x/0x610x. Even then the stock aging screen
  stays "-" unless the enable word is patched, because of the first bullet.

The loopback driver keeps its physically-sound semantics (normal mode:
SO→SI, a unit receives its own bits, SI reads back SO; multi mode: parent
of a single-unit bus, own word in SIOMULTI0, 0xFFFF elsewhere) and remains
the cheap deterministic driver-interface test; the AGS COM PASS is a
phase-2 target.

### 2. In-process local multiplayer (2–4 cores, one process) — DONE (phase 2, 2026-07)

Implemented in `src/dingbat/gba/link.nim`: a lockstep coordinator (`Link`)
plus a `LockstepSioDriver` bound per core. Design:

- **Bounded interleaved slicing**: `new_link(cores)` takes N post-init GBA
  instances (core 0 = multi-mode parent / cable head); `link.step_frame()`
  advances all cores one video frame by repeatedly advancing the core with
  the smallest clock in 512-cycle slices, so skew never exceeds the slice
  plus bounded overshoot (one instruction, one DMA burst, or one halted
  fast-forward to the next event — PPU events cap that at ~1232 cycles).
  The shortest multi round (115.2 kbps, 16 bits) is 2336 cycles, so a child
  is never a full round behind. The coordinator never uses `cpu.tick`'s
  halted branch (it drains to wake/frame-end, unbounded); it calls
  `scheduler.fast_forward()` per event instead.
- **Cross-core clocks**: schedulers stay strictly per-core. The coordinator
  compares int64 global times = per-core offset + `scheduler.cycles`; the
  per-frame `rebase` was extracted into `gba.end_frame()`, which returns the
  subtracted base to feed the offsets, keeping comparisons valid on wasm's
  uint32 `CycleCount`.
- **Deferred completion**: the initiating core (multi parent / normal-mode
  internal-clock master) schedules its completion through the normal
  etSerial path, so its timing and IRQ are exactly single-core behavior.
  Multi mode samples every unit's SIOMLT_SEND at the round's *start* time
  (children are first driven forward to it, then marked busy); when the
  parent's completion fires, every peer is driven forward to the completion
  cycle before the four SIOMULTI slots latch and busy/IRQ resolve on all
  units at the same emulated time. `Link.run_to` is the single
  network-transport boundary for phase 3: for a remote peer, "advance peer
  to cycle X" becomes "block until the peer reports it has reached X".
- **Status bits per GBATEK**: multi SI=0 parent / 1 child, SD=1 when every
  unit is in multi mode, ID = cable position; normal-mode SI mirrors the
  peer's SO. Normal 8/32 exchanges full-duplex at the master's completion
  cycle; per GBATEK the exchange happens whether or not the slave set its
  start bit — the slave only gets busy-clear/IRQ if it had started.
- **Acceptance test**: `tests/roms/linktest.s` (headerless ARM ROM, both
  units run the same image and derive their role from SI) — the parent
  sends 0xA000|round, the child answers 0xB000|round, 16 rounds; both log
  receive latches, role bits, and serial-IRQ counts to fixed EWRAM.
  `./dingbat_test tests/roms/linktest.gba tests/roms/linktest.gba
  --mode=linktest --timeout=60` runs both cores under the coordinator and
  asserts both units saw identical, correct rounds → PASS.

Still open from the original sketch (front-end work, not core):

- Frontend: N framebuffers/keypads. The web UI is likely the best first
  home (two canvases side by side, second player on a gamepad); native SDL
  needs a window/viewport story. Keypads already exist per core
  (`gba.handle_input`).
- Audio: only the focused player mixes; others muted (mGBA does the same).
  Linked cores currently just leave APU sync off.
- Save states / rewind of linked sessions are out of scope (single-core
  state format untouched); a link session should disable rewind or snapshot
  all cores atomically.
- AGS COM PASS (second core as BIOS multiboot slave) remains a stretch
  target; the deterministic assembly ROM above is the acceptance test.

### 3. Cross-emulator transports (pick per goal)

- **BGB protocol for the GB core** — best interop-per-effort in the whole
  space: documented, stable, two independent implementations to test
  against, and our GB core already passes the serial tests it needs. The
  timestamp discipline (2 MHz units, stall when peer is behind) maps
  directly onto our scheduler.
- **JoyBus/TCP for Dolphin** — well-defined, testable against Dolphin, and
  the JoyBus register plumbing (JOYCNT/JOY_RECV/JOY_TRANS/JOYSTAT) already
  exists in serial.nim. Scope: implement the jbus wire commands (RESET,
  STATUS, READ, WRITE) over TCP and wire them to those registers + IRQ.
- **VBA-M protocol for GBA↔GBA** — reverse-engineer `GBALink.cpp`
  (SFML-based TCP, server + up to 3 clients). Worth doing only if
  interop with VBA-M specifically is the goal; the protocol's loose sync
  means compatibility varies by game even between two VBA-M instances.
- **dingbat↔dingbat network link** — once the driver abstraction exists,
  a clean BGB-style protocol (timestamped lockstep over TCP) between two
  dingbat instances is straightforward and strictly more robust than the
  VBA-M route; it just doesn't interoperate with anything else.

### 4. Known hard parts

- **Latency vs. accuracy**: strict lockstep over a network stalls both
  emulators every transfer round-trip. Multi-mode games poll continuously
  during link screens; over localhost this is fine, over the internet it
  needs either tolerance hacks (VBA-M's approach) or rollback. Scope
  networked GBA↔GBA to LAN/localhost initially.
- **Timeouts**: games abort link handshakes when responses are late.
  In-process lockstep sidesteps this entirely; network transports must
  stall the *emulated clock* while waiting (BGB's timestamp mechanism),
  never let it run ahead.
- **Save-state/rewind interaction**: rewinding one linked player desyncs
  the pair; link sessions should disable rewind or snapshot both cores
  atomically.

## Suggested order

1. SIO driver abstraction + loopback driver — DONE (phase 1, 2026-07).
2. In-process 2-player lockstep — core DONE (phase 2, 2026-07; link.nim +
   linktest); web UI wiring pending.
3. BGB protocol for GB (first true cross-emulator interop), and/or a
   dingbat↔dingbat GBA network transport behind `Link.run_to` (phase 3).
4. JoyBus/TCP (Dolphin) and/or VBA-M protocol for GBA, per demand.

Sources: [mGBA multiplayer architecture](https://deepwiki.com/mgba-emu/mgba/9.3-multiplayer-support),
[mGBA #2379](https://github.com/mgba-emu/mgba/issues/2379),
[mGBA #2469](https://github.com/mgba-emu/mgba/issues/2469),
[Dolphin Integrated GBA](https://dolphin-emu.org/blog/2021/07/21/integrated-gba/),
[jbus (JoyBus over TCP)](https://github.com/AxioDL/jbus),
[BGB link protocol](https://bgb.bircd.org/bgblink.html),
[VBA-M linking discussion](https://github.com/visualboyadvance-m/visualboyadvance-m/discussions/1162).
