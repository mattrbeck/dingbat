# Link cable: architecture and wire protocol

Companion to `docs/link-usage.md` (the user-facing entry points). This file
is the reference for the link layers and the network wire format.

## Layers

| piece | role |
|---|---|
| `src/dingbat/gba/serial.nim` | SIO registers (normal 8/32, multi, UART, GPIO, JoyBus); `SioDriver` is consulted on transfer start and completes a transfer later (`finish(data, at_cycle)` fills SIODATA/SIOMULTI, clears busy, raises the IRQ). The null driver is the no-cable behaviour (mGBA suite SIO R/W, SIO timing) |
| loopback driver | SO→SI, master-only; multi mode = parent of a single-unit bus (own word in SIOMULTI0, `0xFFFF` elsewhere). The deterministic driver-interface test |
| `src/dingbat/gba/link.nim` | in-process lockstep coordinator, 2–4 cores |
| `src/dingbat/gb/serial.nim`, `src/dingbat/gb/link.nim` | the GB equivalents (`GbSerialDriver`, two-core coordinator) |
| `src/dingbat/common/linkproto.nim` | wire encode/decode, wasm-safe |
| `src/dingbat/gba/netcore.nim` | transport-independent protocol state machine (handshake, bounded lead, speculation — `docs/speculative-rollback-handoff.md`) |
| `src/dingbat/gba/netlink.nim` | native TCP pump over `netcore` |
| `web/netplay.js`, `web/signaling/` | WebRTC DataChannel bridge and the rendezvous server |

## In-process lockstep (`gba/link.nim`)

* `new_link(cores)` takes N post-init cores (core 0 = multi parent / cable
  head). `step_frame()` advances the core with the smallest global clock in
  512-cycle slices, so skew never exceeds a slice plus one bounded overshoot
  (an instruction, a DMA burst, or a halted fast-forward to the next event —
  PPU events cap that at ~1232 cycles). The shortest multi round (115.2 kbps,
  16 bits) is 2336 cycles, so a child is never a full round behind. The
  coordinator never uses `cpu.tick`'s halted branch (unbounded); it calls
  `scheduler.fast_forward()` per event.
* Schedulers stay per-core; the coordinator compares int64 global times
  (per-core offset + `scheduler.cycles`). `gba.end_frame()` returns the
  subtracted rebase so comparisons stay valid on wasm's uint32 `CycleCount`.
* Deferred completion: the initiator schedules completion through the normal
  `etSerial` path (its timing and IRQ are exactly single-core). Multi mode
  samples every unit's SIOMLT_SEND at the round's start; at completion every
  peer is driven to the completion cycle before the four slots latch and
  busy/IRQ resolve on all units at the same emulated time. `Link.run_to` is
  the network-transport boundary: for a remote peer, "advance peer to cycle X"
  becomes "stall until the peer reports X".
* Status bits per GBATEK, "SIO Multi-Player Mode": SI = 0 parent / 1 child,
  SD = 1 when every unit is in multi mode, ID = cable position; normal-mode SI
  mirrors the peer's SO. Normal 8/32 exchanges full-duplex at the master's
  completion whether or not the slave set its start bit; the slave only gets
  busy-clear/IRQ if it had started (GBATEK, "SIO Normal Mode").
* Acceptance: `tests/roms/linktest.s` (both units run the same image, role
  from SI; parent sends `0xA000|round`, child `0xB000|round`, 16 rounds).
  `dingbat_test linktest.gba linktest.gba --mode=linktest`.

The GB coordinator resolves a transfer byte-duplex at the master's 8th shift
edge (peer run to that cycle, master's start-latched byte swapped with the
slave's staged SB, completion semantics per whether each side had started).
Shift clock from the divider (bit 8 = 8192 Hz; CGB fast clock bit 3 =
262144 Hz); timing pinned by mooneye `boot_sclk_align-dmgABCmgb` and the
gambatte serial rows. `tests/roms/gblinktest.gb` (`--mode=gblinktest`)
exchanges 16 rounds both ways; `tests/gb_trade_repro.nim --mode=stability`
runs two Crystal cores bit-identically through the CGB speed switch.

Open: audio mixes only the focused player; save states/rewind of a linked
session snapshot nothing atomically (disable them, as the UI does).

## Network sync model (`netcore`)

Neither side drives the remote core. Each side free-runs its own scheduler
but never more than LEAD cycles past the newest peer CLOCK; beacons flow at
least every 4096 emulated cycles and immediately when a side blocks. A side
that would exceed the lead stalls its **emulated** clock. Transfers anchor to
explicit cycles: the initiator sends TRANSFER(S, D, data), schedules its own
completion at S+D, and stalls there if the REPLY has not arrived. The
responder answers at exactly S when behind it, or immediately when (boundedly)
past it, running the busy window D from its own clock. Latency slows
emulation; it cannot desync it. `NetLink.stalled` is the "waiting for peer"
flag for frontends.

`NETLINK_LEAD` (16384 cycles) suits a transport pumped every slice (native
socket). The browser uses `NETLINK_LEAD_RAF` (3 frames ≈ 50 ms) because JS
delivers DataChannel messages only between rAF ticks; a 1 ms lead there
throttles each side to ~6 % speed. `effective_lead` tightens the lead while a
serial mode is active so cable-club handshakes converge.

`netcore` is non-blocking: `feed(bytes)` ingests frames and can unpark a
stalled transfer, `take_outgoing()` drains, `try_advance()` returns
`naProgress` / `naFrame` / `naStalled` / `naHello`. Native sockets are
`TCP_NODELAY` and nonblocking after the handshake (a blocking send while the
peer also sends deadlocks); teardown is half-close + drain-to-EOF (an RST
discards the peer's receive queue and can lose BYE).

### Wire format

TCP byte stream (or a reliable ordered DataChannel) of frames:
`u32le payload_length`, then the payload; first payload byte is the type.
Little-endian throughout. Clocks are emulated cycles since link start, u64.

| # | Message | Payload after the type byte |
|---|---|---|
| 1 | HELLO | `u8 version` (=1), `u8 system` (0 GBA, 1 GB), `u8 unit` (0 listener, 1 connector), `u8 reserved`, `u32 rom_crc` (CRC-32/IEEE of the ROM file). First both ways; mismatch → BYE(2) |
| 2 | CLOCK | `u64 clock`, `u8 sio_mode` (0 normal8, 1 normal32, 2 multi, 3 uart, 4 gpio, 5 joybus), `u8 flags` (bit0 SO level, bit1 sender blocked on us) |
| 3 | TRANSFER | `u64 clock` (start S), `u32 duration`, `u8 mode` (0/1/2), `u8 reserved`, `u32 data` (initiator's word) |
| 4 | REPLY | `u64 clock`, `u64 cycle` (echo of S), `u8 mode`, `u8 flags` (bit0 responder was in a compatible mode; else the initiator reads all-1s/absent), `u32 data` |
| 5 | BYE | `u8 reason` (0 finished, 1 shutdown, 2 HELLO mismatch). A finished peer's clock is treated as infinite |

The listener is unit 0 (multi parent candidate, cable head); initiator-ship
is per transfer because mode and role ride in SIOCNT, which is why TRANSFER
carries `mode`.

**Same-ROM policy.** `--mode=netlink` keeps `strict_crc`; the web relaxes to
warn-and-confirm (`allow_crc_mismatch`) because Ruby/Sapphire/Emerald have
different CRCs and link fine; incompatible games fail their own handshake.

## Harnesses

* `dingbat_test --mode=netlink --listen PORT` / `--connect HOST:PORT`,
  `--netlink-delay-ms N` (each process asserts its own unit's EWRAM log).
* Web: `?linkdelay=NN` injects send latency; `?signal=URL` overrides the
  signaling endpoint.
* `web/signaling/server.nim` (deployed; ~7 MB RSS) and `server.js` are
  byte-for-byte protocol twins: `create → code`, `join(code)`, relay
  SDP/ICE between two sockets, close. Six-char codes from an unambiguous
  alphabet, single-use, ~10 min TTL; room/connection caps, handshake timeout,
  keepalive + idle reaper. Build: `nim c -d:release -d:test_harness
  --opt:size -o:signalsrv web/signaling/server.nim` (`-d:test_harness` skips
  the repo's SDL/GL link flags; static Linux builds need musl). TLS terminates
  at the reverse proxy. Both pass `server.test.mjs` (`SIGNAL_CMD=./signalsrv`).
* In session the web hides rewind, speed, states, load-save and reset
  (`body.net-mode`); a peer departure toasts and the local core plays on.

## Not built

* **GB/GBC online**: the GB serial driver is not hooked to `linkproto`
  (HELLO `system=1` is reserved for it).
* **BGB link protocol** ([spec](https://bgb.bircd.org/bgblink.html)): the one
  cross-emulator GB standard — 8-byte packets with a 2 MHz timestamp,
  `sync1`/`sync2`, stall on the peer's timestamp. Maps directly onto the GB
  driver; best interop per effort.
* **JoyBus over TCP** for Dolphin's Integrated GBA
  ([jbus](https://github.com/AxioDL/jbus), port 5738): the JoyBus registers
  exist in `serial.nim`; RESET/STATUS/READ/WRITE over TCP are not wired.
* **GB↔GBA heterogeneous link**: both layers resolve a transfer as one byte
  each way, so a bridge driver pairs them; the new piece is clock-rate
  weighting in the coordinator (GB ×4, GBA ×1, GB double-speed ×2). Gen 2 ↔
  Gen 3 Pokémon never traded on hardware regardless.
* **TURN relay** for strict-NAT pairs (STUN only today); native clients
  joining the room system.
* **AGS aging cartridge COM PASS**: its "MULTI PLAY SIO" test is a two-unit
  multiboot test (parent broadcasts `0x6200` expecting a BIOS multiboot slave
  to answer `0x720x`), not a loopback test, and the aging entry point
  disables it unconditionally. A PASS needs a core sitting in the real BIOS
  multiboot wait (cartridge-less LLE boot); two force-enabled checkers do not
  handshake.
