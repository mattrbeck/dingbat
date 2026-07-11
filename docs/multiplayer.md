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

### 2. In-process local multiplayer (2–4 cores, one process)

The mGBA model, adapted: N `GBA` instances, one designated clock master.

- Scheduling: run each core in bounded slices so no core gets ahead of a
  possible transfer start. mGBA bounds the skew to a small cycle window
  (SIO transfers at 9.6 kbps take ~1750 cycles/byte, so slices of ~1024
  cycles are safe and cheap). On a transfer start, the master stalls until
  every slave has reached the transfer's start cycle, then all cores resolve
  the exchange at the same emulated time.
- Frontend: N framebuffers/keypads. The web UI is likely the best first
  home (two canvases side by side, second player on a gamepad); native SDL
  needs a window/viewport story.
- Audio: only the focused player mixes; others muted (mGBA does the same).
- Determinism makes this testable headlessly: two cores, scripted inputs,
  assert on RAM/framebuffer (e.g. Pokémon link trade completes).

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

1. SIO driver abstraction + loopback driver (small; AGS COM as the test).
2. In-process 2-player lockstep + web UI (the actual "local multiplayer").
3. BGB protocol for GB (first true cross-emulator interop).
4. JoyBus/TCP (Dolphin) and/or VBA-M protocol for GBA, per demand.

Sources: [mGBA multiplayer architecture](https://deepwiki.com/mgba-emu/mgba/9.3-multiplayer-support),
[mGBA #2379](https://github.com/mgba-emu/mgba/issues/2379),
[mGBA #2469](https://github.com/mgba-emu/mgba/issues/2469),
[Dolphin Integrated GBA](https://dolphin-emu.org/blog/2021/07/21/integrated-gba/),
[jbus (JoyBus over TCP)](https://github.com/AxioDL/jbus),
[BGB link protocol](https://bgb.bircd.org/bgblink.html),
[VBA-M linking discussion](https://github.com/visualboyadvance-m/visualboyadvance-m/discussions/1162).
