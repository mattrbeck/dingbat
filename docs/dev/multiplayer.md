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
| `src/dingbat/gba/netcore.nim` | transport-independent protocol state machine (handshake, bounded lead, speculation — `docs/dev/speculative-rollback-handoff.md`) |
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
emulation; it cannot desync it. `NetLink.stalled` is the flag behind the
"Waiting for your friend" line.

The native stall clock (`NetLink.stall_timeout_ms`, 30 s) ends a link whose
peer went silent. A paused side keeps reading its socket and sets CLOCK's
paused bit, and the other side's stall clock does not run while that bit is
set, so a pause never drops the link. The desktop steps a linked frame with
`step_frame_for` (hands back to the UI loop after a few ms parked on the
peer, resuming the frame next call) rather than the blocking `step_frame`,
so waiting on the peer never freezes the window. Unplugging the core
(`NetLink.shutdown`, or any driver swap) completes an exchange parked on a
REPLY as a pulled cable, as a BYE does.

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
| 2 | CLOCK | `u64 clock`, `u8 sio_mode` (0 normal8, 1 normal32, 2 multi, 3 uart, 4 gpio, 5 joybus), `u8 flags` (bit0 SO level, bit1 sender blocked on us, bit2 sender's user paused: a stall on it is not a lost peer; older builds ignore the bit) |
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
  signaling endpoint (loopback, LAN and `.local` pages only).
* `web/signaling/server.nim` (deployed; ~7 MB RSS) and `server.js` are
  protocol twins: both players send `rendezvous` with the code they agreed
  and their page's id; the first holds the room (`waiting`, ~10 min TTL), the
  second pairs (`paired` host/guest), the server relays SDP/ICE between the
  two sockets, and either leaving tells the other `peer-closed`. A page that
  redials with its id takes back its own stale seat (a socket that died
  unseen, e.g. a suspended phone) instead of being paired with it or told the
  code is in use. The client goes back to waiting on the code whenever a
  pairing ends before linking, and gives the NAT verdict only after two
  pairings that exchanged descriptions and never opened; the machine is
  modelled in `tools/formal/WebState/LinkPairing.lean`. Room/connection caps,
  handshake timeout, keepalive + idle reaper. Build: `nim c -d:release -d:test_harness
  --opt:size -o:signalsrv web/signaling/server.nim` (`-d:test_harness` skips
  the repo's SDL/GL link flags; static Linux builds need musl). TLS terminates
  at the reverse proxy. Both pass `server.test.mjs` (`SIGNAL_CMD=./signalsrv`).
* In session the web hides rewind, speed, states, load-save and reset
  (`body.net-mode`); a peer departure toasts and the local core plays on.

## Sync checks (online rollback link)

Both sides of an online link run both games (`gba/rollback.nim`,
`gb/rollback.nim`) and only inputs cross, so two builds whose cores differ,
or a determinism bug, can drift apart silently. Builds that check now say
so in the HELLO: `[21]` core id (`common/linksync.nim CORE_ID`, the git trees
of `gba/`, `gb/`, `common/`, the same on web, iOS and desktop when the
core source is), `[29]` build time (the commit's, `BUILD_TIME`), `[33]`
bit 0 "checks", `[34]` the GBA BIOS mode and `[35]` its image's hash u32
(`linksync.bios_identity`, 0 = none). Older builds read the first 21 bytes
and are sent none of the following. Web (`netplay.js`), iOS (`NetLink.swift`) and desktop
(`frontend/online_link.nim`) each implement it; the desktop restarts on
fresh cores as its session start builds them and hands the app the new
local one (`OnlineHooks.resynced`).

* **Fingerprint.** Every 120 frames the engine hashes both cores' portable
  state images (`state_bytes`; the in-process snapshot pads cycle counters
  to the host's width, so web and iOS would never agree on it) once that
  frame is final (`confirmed >= f - 1`), from the ring slot or the live
  state (`sync_flush`). Once each: hashing as frames are simulated paid
  again on every replay (9 ms ticks on Emerald in wasm). Polled by
  `rollback_sync_poll` / `dingbat_rollback_sync_poll`.
* **RB_SYNC** `[16][gen][frame u32][hash u64]`, 14 bytes every ~2 s; both
  sides compare at the same frame.
* **Re-sync** on a difference: each proposes to stop 60 frames ahead
  (**RB_RESYNC** `[17][gen][frame]`); both stop at the later (`rbAtBarrier`);
  at it, with every input to it in, each sends its own game's state, packed
  (**RB_RESYNC_BEGIN/CHUNK** 18/19); with the friend's in hand each restarts
  the session from the two states (`rollback_init` and both loads, as at the
  start; frame counts back to 0) and says so (**RB_RESYNC_READY** 20). Each
  player's own game is never touched, only its copy of the friend's.
  Restarting the moment the friend's state is complete (if ours went) keeps
  every input in its session: the friend's new inputs travel behind its
  state. A drop during a re-sync ends the session.
* **The GBA BIOS** is the one setting that changes emulated state. Played
  from boot, HLE with an image and without one run the same (23 games,
  6000 frames); but a state saved inside a BIOS call under one mapping
  doesn't run on under the other, and a session loads each side's state
  into both sides' cores. Golden Sun and Metroid Fusion wait in Halt at
  every frame's end, and seven more games (Ruby, Mother 3, Superstar Saga,
  ...) in IntrWait: such a state hangs on the other mapping. Two HELLOs
  that name different BIOSes both build their session cores on HLE without
  an image (`bios_force_hle`, the same answer on both sides), so the two
  sides never run apart; a state the image player saved inside a BIOS call
  still doesn't load right there until a cross-mapping load works (the
  HLE Halt frame and the stub's IntrWait addresses; open). An older friend
  names none and each runs its own, as before.
  Volume, filters, 2x, channel toggles, MP2K HLE, FIFO interpolation,
  palettes and LCD effects stay out of the state (audited); MP2K HLE on one
  side and off on the other is by design harmless but not tested.
* **A state transfer's announced length** is capped at 8 MB (start and
  re-sync): a bad one ends the session.
* **A fingerprint read from the ring** loads a checkpoint and the live state
  back; both go unheard (`owns_audio` off, `buffer_pos` kept), else the
  native audio queue would be cleared every 120 frames.
* **A drop just after a restart**, while the friend's READY is still on the
  way, ends this side (its re-sync isn't finished) while the friend, done,
  redials until the goodbye note ends it too. Rare (one round trip) and it
  ends cleanly; resuming there would need the READY treated as implied.
* **Three re-syncs in 10 minutes** show why: different core ids, "different
  versions of dingbat's emulator", naming the older by build time; the same
  core, "keeps drifting out of sync … report a bug".
* **Model:** `tools/formal/WebState/LinkSync.lean` proves an older friend is
  sent nothing new, own games are untouched, and no side plays past the
  stop before restarting; traces show a re-sync back in step (proposals
  equal or apart) and that a restart waiting for a later frame would feed
  the friend's new input into the old session. That every input reaches
  its own session in general is argued here and tested
  (`web/tests/link-sync.test.mjs`), not proved.
* **Tests:** `dingbat_test --mode=rollbacksync` (CI: real cores, agreement
  with ground truth, a poked copy caught, a re-sync from both own states);
  `tests/gb_rollback_keys_test.nim` (GB fingerprints equal on two peers at
  uneven latencies); `web/tests/link-sync.test.mjs` (the protocol on two
  pages); `web/e2e/link-sync.e2e.mjs` (two real wasm cores in Chromium:
  agreement, a set-back copy caught and re-synced, cost;
  `DINGBAT_SYNC_ROM=` for a real game); `web/e2e/link-native.e2e.mjs` (a
  browser and the desktop link: wasm and native fingerprints agree at every
  check for GBA, GB and a cross-game pair, either side hosting, and a copy
  set back on either side is caught, re-synced, identical after);
  `tests/desktop_online_link_test.nim` (two desktop links, GB and GBA
  re-syncs, the BIOS rule); `tests/linksync_bench.nim` (native cost).
  Opt-in, outside CI: `DINGBAT_GBA_BIOS=` + `DINGBAT_BIOS_GAME=` (a real
  BIOS in the browser, none native: in step; the control without the rule
  mismatches at the first check); `DINGBAT_SOAK_ROM=` [+ `DINGBAT_SOAK_MIN`]
  in both e2e files (random buttons for N minutes, 40 ms late one way
  between browsers). Measured 2026-11-17: Emerald 20 min between browsers
  and Golden Sun 20 min browser vs native, 600/600 fingerprints agreeing
  each, cores identical at the end. `tests/trade_repro.nim --resync-at=N`
  (lockstep) rebuilds both cores as a re-sync does: the FireRed/Emerald
  Cable Club trade went on without a communication error at all ten points
  tried (frames 1200-4180, through the block exchange and both standby
  barriers). A main build against this one (web-web both hosting, desktop
  peer-web) links as before and is sent none of 16-20.
* **Cost** (M-series Mac): a fingerprint is 1.8 ms on Emerald in wasm, 0.4 ms
  on Crystal (native 1.76 / 0.39, of which serializing is ~85%), once every
  120 frames; sync messages are ~6 B/s against ~0.4 KB/s of inputs; a
  re-sync sends 25-105 KB each way and takes ~1 s, most of it the 60-frame
  margin.

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
