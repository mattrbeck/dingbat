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
- **Two force-enabled checkers do NOT handshake** (verified 2026-07 with
  the phase-2 lockstep link: both cores force-enabled + auto-START). The
  parent broadcasts 0x6200 but the child answers 0x0000, never 0x720x —
  the checker's multi-play library has no slave-responder path (its send
  path requires being bus parent, and nothing arms SIOMLT_SEND on a
  child), so both units show COM: X FAIL. A PASS therefore requires a
  core sitting in the actual BIOS multiboot wait, which needs
  cartridge-less LLE boot support — deferred past phase 2.

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
  (Phase 3a realized exactly that shape in netlink.nim: the initiator's
  run_to-the-completion-cycle became "stall until the peer's REPLY for
  cycle X arrives"; see section 3a.)
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
- AGS COM PASS requires a second core in the BIOS multiboot wait, i.e.
  cartridge-less LLE boot support (two force-enabled checkers do not
  handshake — see the COM findings above); the deterministic assembly ROM
  above is the acceptance test.

### 3a. dingbat↔dingbat network link over TCP — DONE (2026-07)

Two dingbat processes run `tests/roms/linktest.gba` linked over a socket and
produce the same results as the in-process pair. Pieces:

- `src/dingbat/common/linkproto.nim` — transport-agnostic wire protocol
  (pure byte encode/decode, wasm-safe; see the message table below). A
  future browser bridge (phase 3b) speaks the same frames byte-for-byte
  over a WebRTC DataChannel.
- `src/dingbat/gba/netlink.nim` — native-only (`std/net` TCP, gated out of
  emscripten builds): `NetLink` + `RemoteSioDriver`. The local core runs
  normally on its own scheduler; the remote peer appears through the
  driver. Sockets are TCP_NODELAY and nonblocking after the handshake —
  sends buffer in userspace and drain opportunistically (a blocking send
  while the peer also sends is a deadlock), and teardown is half-close +
  drain-to-EOF (closing with unread beacons RSTs the connection, and an
  RST discards the peer's receive queue — it could lose our BYE).
- `tests/dingbat_test.nim --mode=netlink` with `--listen PORT` (unit 0,
  multi-mode parent candidate) or `--connect HOST:PORT` (unit 1), plus
  `--netlink-delay-ms N` to add artificial latency to every send. Each
  process asserts its own unit's EWRAM log from the linktest ROM and
  prints its own PASS/FAIL; run both and require PASS from both.

**Sync model (BGB-style timestamped bounded lead).** Neither side ever
drives the remote core. Each side free-runs its own scheduler but never
more than LEAD (= 16384) cycles ahead of the newest peer-clock report;
CLOCK beacons flow at least once per 4096 emulated cycles and immediately
when a side blocks. When a side would exceed the lead, it stalls its
*emulated* clock (blocking socket wait, emulator frozen) until a newer
peer clock arrives. Transfers anchor to explicit emulated cycles: the
initiator sends TRANSFER(clock=S, duration=D, data) and schedules its own
completion at S+D through the normal etSerial path (initiator timing/IRQ
are exactly single-core behavior); if the peer's REPLY hasn't arrived when
that fires, the initiator stalls at S+D — it never free-runs past a
pending exchange. The responder samples/answers at exactly cycle S when it
is behind S, or immediately when it is (boundedly, ≤ LEAD) past S, running
the busy window D cycles from its own clock — every ROM on either side
observes a hardware-plausible transfer, and latency can only slow
emulation, never desync it. All stalls funnel through `stall_wait`
(`NetLink.stalled` is the "waiting for peer" flag for frontends).

**Wire format.** TCP byte stream of frames: `u32le payload_length`, then
that many payload bytes; first payload byte is the message type. All
integers little-endian. Clocks are emulated cycles since link start
(u64le; ~16.78 MHz — a 32-bit clock would wrap in ~4 minutes).

| # | Message  | Payload layout (after the type byte) |
|---|----------|--------------------------------------|
| 1 | HELLO    | `u8 version` (=1), `u8 system` (0=GBA, 1=GB), `u8 unit` (0=listener, 1=connector), `u8 reserved`, `u32 rom_crc` (CRC-32/IEEE of the ROM file). First message both directions; validate version/system/ROM, units must differ. Reject politely with BYE(reason=2). |
| 2 | CLOCK    | `u64 clock`, `u8 sio_mode` (0=normal8, 1=normal32, 2=multi, 3=uart, 4=gpio, 5=joybus), `u8 flags` (bit0 = SO output level, bit1 = sender is blocked on us). Beacon; also carries the state the peer's status bits need (SD=1 in multi requires the peer in multi mode; normal-mode SI mirrors the peer's SO). |
| 3 | TRANSFER | `u64 clock` (start cycle S = sender's clock), `u32 duration` (cycles), `u8 mode` (same encoding as CLOCK, only 0/1/2 legal), `u8 reserved`, `u32 data` (initiator's outgoing word). Multi: parent's SIOMLT_SEND; the exchange completes at S+duration. Normal 8/32: master's SIODATA; the full-duplex swap happens at S+duration. |
| 4 | REPLY    | `u64 clock` (responder's clock when it answered), `u64 cycle` (echo of the TRANSFER's S — matches replies to rounds), `u8 mode`, `u8 flags` (bit0 = responder was in a compatible SIO mode; if 0 the initiator reads all-1s/absent), `u32 data` (responder's word). |
| 5 | BYE      | `u8 reason` (0 = finished, 1 = shutdown, 2 = HELLO mismatch). A finished peer's clock is treated as infinite (never stall on it again). |

Roles: the listener is unit 0 — the multi-mode parent *candidate* and the
head of the cable (ID bits/SI status derive from it) — but actual
initiator-ship is per-transfer: mode+role ride in SIOCNT (a normal-mode
master is whichever unit set internal clock), which is why TRANSFER
carries `mode` rather than assuming.

Measured with the linktest ROM (localhost, 2026-07): both units PASS in
~34 frames / ~50 ms wall, and 20/20 repeated runs pass. With
`--netlink-delay-ms 50` on both sides (≈100 ms RTT simulation) both units
still PASS — ~27 s wall for the same 34 frames (~405 stalls/side), i.e.
slower but never desynced.

Phase 3b (browser bridge) needs: a WebRTC DataChannel (or WebSocket
relay) producing/consuming the same frames — linkproto compiles under
emscripten already; a wasm-side NetLink equivalent whose socket pump is
event-driven (no blocking waits in the browser: the stall points must
become "pause emulation until message X arrives" callbacks); and a
signaling story for peer discovery. The GB core can join the same wire
format later (HELLO `system=1`) or speak the real BGB protocol instead.

### 3b. Internet play in the browser with room codes — DONE (2026-07-11)

Two browsers link the same GBA game over a WebRTC DataChannel that carries
the exact linkproto frames byte-for-byte; a room code is all a player
shares. Pieces:

- `src/dingbat/gba/netcore.nim` — the transport-independent protocol state
  machine extracted from netlink.nim (emscripten-clean). Non-blocking by
  construction: `feed(bytes)` ingests inbound frames and can unpark a
  stalled transfer, `take_outgoing()` hands queued frames to the transport,
  and `try_advance()` advances up to one slice of emulated time and returns
  `naProgress` (call again), `naFrame` (a video frame completed),
  `naStalled` (emulated clock parked on the peer — render the indicator,
  come back after `feed`), or `naHello` (handshake not yet validated). The
  HELLO handshake is part of the same flow (`hello: hsWait|hsDone|hsFailed`).
  The native TCP path (`netlink.nim`) is now a thin socket pump over this
  core, so there is ONE protocol implementation and the 3a acceptance gates
  still pass unchanged.
- Bounded lead is per-side and constructor-set: `NETLINK_LEAD` (16384
  cycles) suits a transport pumped every slice (the socket); the browser
  uses `NETLINK_LEAD_RAF` (3 frames ≈ 50 ms emulated) because JS only
  delivers DataChannel messages between requestAnimationFrame ticks, never
  mid-tick — a 1 ms lead there throttles each side to advancing ~1 ms of
  emulated time per real frame (~6% speed). The extra lead only widens the
  responder's sampling skew (still bounded, still hardware-plausible); it
  cannot desync, because transfers stay anchored to exact cycles.
- `src/dingbat_wasm.nim` — `netlink_init(rom, is_host, allow_crc_mismatch)`,
  `netlink_feed/drain/tick/stalled/peer_done/crc_mismatch/error_msg/exit`,
  plus a `wasm_ew16` EWRAM probe for the linktest acceptance hook. Online
  mode runs one core through the standard single-core render/audio/input
  paths (each side renders only itself); `netlink_tick` returns a status
  the RAF loop uses to drop wall-clock debt while stalled instead of
  replaying it as a frame burst.
- `web/netplay.js` — the JS bridge: `RTCPeerConnection` + a reliable,
  ordered DataChannel (`ordered: true`, default reliable) shuttling frames
  to/from the wasm exports each RAF. STUN-only for v1 (a strict-NAT pair
  gets a clear "could not connect peer-to-peer" error; TURN is a later
  add). `?linkdelay=NN` injects N ms of send latency (mirrors the native
  `--netlink-delay-ms`); `?signal=URL` overrides the signaling endpoint.
- `web/signaling/server.js` — a zero-dependency Node WebSocket rendezvous
  (`node server.js [port]`, default 8790). `create → code`, `join(code)`,
  then it relays the SDP offer/answer + ICE between exactly two sockets and
  closes; game traffic never touches it. Codes are 6 chars from an
  unambiguous alphabet (no 0/O/1/I/L), single-use, ~10-minute TTL.
- UI: GBA library tiles gain **HOST** / **JOIN** next to **2P**. Host shows
  the room code + "waiting for your friend"; join has a code field
  (accepts `KJ4-Q7N`, `kj4q7n`, spaces — all normalized). In session,
  `body.net-mode` hides the desync/reset-hazard controls (rewind, speed,
  save states, load-save, reset — reset can't reach the remote core), a
  subtle `⏳ waiting for peer` badge surfaces sustained stalls, and a peer
  departure (BYE, closed channel, ICE failure) toasts "your game keeps
  running" while the local core plays on — the game itself just sees a
  yanked cable.

**Same-ROM policy.** The linktest harness keeps the strict CRC check
(`strict_crc = true`); the web relaxes it to a warn-and-confirm
(`allow_crc_mismatch`), because cross-version pairs (Ruby↔Sapphire↔Emerald)
have different CRCs but are fully link-compatible, and blocking them would
defeat half the point of Pokémon trading. Compatible games negotiate their
own link handshake; incompatible ones fail that handshake themselves.

**Verified (2026-07-11, two browser contexts + the local signaling
server):** the linktest ROM reaches its `EWRAM[0x800]==0xCAFE` completion
with all 16 multi-mode rounds correct on both units, plain and under
`?linkdelay=50` (slower, never desynced). Pokémon Emerald (same version)
runs both sides into the overworld at full frame rate, each on its own
battery save. The cross-version relaxed-CRC confirm fires on both ends.

Not yet done: a deployed signaling URL (an ops choice — the web UI's
default guesses `wss://<host>/signal`), a TURN relay for strict-NAT pairs,
native clients joining the room system, and GB/GBC online (the GB core has
no SIO driver abstraction yet — GBA-only for 3b).

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
3. dingbat↔dingbat GBA network transport — native TCP DONE (phase 3a,
   2026-07; linkproto.nim + netlink.nim + --mode=netlink); browser WebRTC
   bridge with room codes DONE (phase 3b, 2026-07-11; netcore.nim +
   netplay.js + signaling server — see §3b). Next: BGB protocol for GB
   (first true cross-emulator interop).
4. JoyBus/TCP (Dolphin) and/or VBA-M protocol for GBA, per demand.

Sources: [mGBA multiplayer architecture](https://deepwiki.com/mgba-emu/mgba/9.3-multiplayer-support),
[mGBA #2379](https://github.com/mgba-emu/mgba/issues/2379),
[mGBA #2469](https://github.com/mgba-emu/mgba/issues/2469),
[Dolphin Integrated GBA](https://dolphin-emu.org/blog/2021/07/21/integrated-gba/),
[jbus (JoyBus over TCP)](https://github.com/AxioDL/jbus),
[BGB link protocol](https://bgb.bircd.org/bgblink.html),
[VBA-M linking discussion](https://github.com/visualboyadvance-m/visualboyadvance-m/discussions/1162).
