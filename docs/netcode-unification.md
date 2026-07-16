# Link-cable netcode: unification analysis & design

Status: analysis + two cross-ported fixes landed (2026-07-15). Full SIO-driver
unification assessed and deferred (see "Migration assessment").

This document maps the current link-cable netcode, corrects a stale assumption
about it, identifies the one genuine remaining duplication, and records what was
fixed vs. what a fuller unification would cost.

## TL;DR

The premise that the netcode is "implemented differently between the native and
browser paths" is **largely already resolved**. The online protocol is a single
transport-independent state machine (`gba/netcore.nim`) driven identically by the
native TCP transport and the browser bridge, over a single shared wire format
(`common/linkproto.nim`). JS shuttles opaque bytes; it does not re-implement the
protocol.

The real remaining duplication is on a **different axis**: the GBATEK link-cable
*hardware semantics* are encoded twice — once for the in-process lockstep link
(`gba/link.nim`, `LockstepSioDriver`) and once for the over-the-wire link
(`gba/netcore.nim`, `RemoteSioDriver`). This duplication is where a divergence
bug hid (fixed below). Fully collapsing the two is a multi-day, high-risk job
with modest payoff because the two are architecturally sync-vs-async; it is
deferred, with a concrete migration sketch here.

## Module map

| Module | Responsibility | Used by |
| --- | --- | --- |
| `common/linkproto.nim` | Wire format only: encode/decode length-prefixed LE frames (HELLO/CLOCK/TRANSFER/REPLY/BYE), `LinkDecoder`, CRC-32. Transport- and language-agnostic; compiles under emscripten. | netcore (both transports) |
| `gba/netcore.nim` | THE online protocol state machine. Non-blocking: `feed` bytes in, `take_outgoing` frames out, `try_advance` steps the local core. Bounded-lead sync, reply_wait/lead_wait stalls, cross-game drain fix, optional GGPO speculation+rollback. `RemoteSioDriver` resolves the cable over the wire. | native TCP + browser online |
| `gba/netlink.nim` | Native TCP transport adapter around netcore: nonblocking socket pump, blocking waits w/ timeout, latency sim (`--netlink-delay-ms`), half-close teardown. `{.error.}` under emscripten. | native `--mode=netlink` |
| `src/dingbat_wasm.nim` `netlink_*` exports | Browser transport adapter around netcore: `netlink_feed`/`netlink_drain`/`netlink_tick` shuttle bytes and drive frames from RAF; identical netcore interface to netlink.nim. | `web/netplay.js` (SIO path) |
| `gba/link.nim` | In-process lockstep link: owns N GBA cores, interleaves them in bounded slices, resolves the SIO cable in-process (`LockstepSioDriver`). `LinkSnapshot` capture/restore for rollback. | local 2P + rollback netplay |
| `gba/rollback.nim` | GGPO input-rollback session over a local 2-core `Link`: only inputs cross the wire, both cores run locally, predict+rollback hides latency. | browser online **default** |
| `web/netplay.js` | Browser glue: WebRTC DataChannel + room-code signaling, same-browser `LocalChannel` over BroadcastChannel, and the two online modes below. | web UI |
| `gba/serial.nim` | `SioDriver` base class + shared plumbing: `multi_transfer_cycles`/`normal_transfer_cycles`, `schedule_sio_completion`, `finish_sio_transfer`, default status/pin bits. | all drivers |

### The two production online paths (this is the real "divergence")

- **Native online** = SIO-over-network: `netcore` + `netlink.nim`.
- **Browser online (default)** = input-rollback: `rollback.nim` over `link.nim`
  (`web/netplay.js` `NET_ROLLBACK`, on unless `?rollback=0`). The netcore SIO
  path still exists in the browser but only behind `?rollback=0`.

These are two deliberately different netcode architectures, not gratuitous
drift. Rollback needs both cores local + full determinism and pays off for
latency-sensitive play; the SIO-over-wire path is the general fallback and the
only option native currently wires up. `tests/trade_repro.nim` exercises all
three wirings (`lockstep`, `netcore`, `rollback`) against the same comm-error
detector — it is the crown-jewel regression guard.

## What is genuinely shared vs. duplicated

Shared (good, no action):
- Wire format — one module, both transports, byte-for-byte.
- Online protocol/state-machine — one module (`netcore`), both transports.
- SIO driver plumbing — the `SioDriver` base in `serial.nim`.

Duplicated (the real finding): **link-cable hardware semantics**, encoded in both
`LockstepSioDriver` (link.nim) and `RemoteSioDriver` (netcore.nim):

1. Multi-mode SIOMULTI0-3 receive-latch layout (`own slot = our SIOMLT_SEND,
   peer slot = peer word, absent = 0xFFFF`): link.nim:174-182 vs
   netcore.nim:384-387 and 527-531.
2. Normal-mode full-duplex swap (32-bit whole register; 8-bit low byte;
   floating-high 0xFF/0xFFFFFFFF when the peer is not listening; master shifts
   both registers, slave gets busy-clear/IRQ only if it started): link.nim
   `complete_normal` (225-256) vs netcore.nim `slave_finish`/`master_finish`
   (380-408, 521-531).
3. Status bits (multi SD "all ready"/SI cable-position; normal SI = peer SO):
   link.nim `sio_siocnt_status` (260-286) vs netcore.nim (823-842).

The two express the same GBATEK truth but are structured differently because one
is **synchronous** (advance the peer core in-process with `run_to`, then latch)
and the other is **asynchronous** (exchange TRANSFER/REPLY messages, latch at an
anchored cycle). link.nim also handles up to 4 cores; netcore is strictly 2.

## Divergence bugs

### Fixed: SIOMULTI recv latches not restored across netcore's speculative rollback

`Serial.multi_recv` is deliberately **not** carried by `state_payload`
(gba.nim:102-107 — session state refreshed by the next transfer). `link.nim`'s
rollback path accounts for this: `LinkSnapshot` explicitly captures/restores
`serial.multi_recv` (link.nim:340-364), a hard-won fix for the in-game
"communication error" desync.

`netcore.nim`'s speculative rollback checkpointed `state_payload()` +
`NetSnapshot` but `NetSnapshot` did **not** include `multi_recv`. A rollback
therefore restored the core without the receive latches, and the re-sim could
read a stale (post-speculation) SIOMULTI value before the frame's round
re-latched — the same divergence class, on the other path. The fix was never
cross-ported. **Cross-ported** in commit "restore SIOMULTI recv latches across
speculative rollback": `NetSnapshot` now carries `multi_recv`, captured in
`capture_snapshot` and restored in `restore_snapshot`. No-op on the
non-speculative production path; strictly more correct on the speculative path.

### Fixed: predictor arrays smaller than their index mask

`predict`/`note_reply` index `last_reply`/`peer_echo` with `int(mode) and 7`
(0..7) but the arrays were `array[6]`. A REPLY/TRANSFER with wire mode 6/7 (the
decoder validates message type, not the mode byte) indexed out of bounds — silent
under `-d:danger` (wasm). **Fixed** by sizing both to `array[8]` to match the
mask.

### Not a bug: the reply_wait/lead_wait deadlock fix (fab2636)

That fix lives inside `netcore.try_advance`, so it is shared by **both** the
native TCP and browser online transports automatically. The lockstep path
(link.nim) cannot hit that deadlock — it is single-process and never parks on a
remote REPLY. No cross-port needed. The lockstep path's analogous hazard (serial
IRQ coalescing) is fixed separately in `complete_multi` (link.nim:200-207) and
does not exist on netcore (each round completes via a discrete etSerial).

## Migration assessment (deferred work)

Goal if pursued: extract the GBATEK cable semantics into pure helpers on
`serial.nim` that both drivers call, so the hardware truth lives once.

Candidate seam — pure, side-effect-scoped helpers next to `Serial`:
- `latch_multi_recv(serial; self_slot, own, peer: uint16)` — the 4-line SIOMULTI
  layout (netcore uses it directly for 2P; link.nim's N-core `complete_multi`
  would fill a `multi_data[4]` and fan it out, so it benefits less).
- `normal_fullduplex(masterData, slaveData; is32) -> (masterIn, slaveIn)` — the
  swap + floating-high rules.
- status-bit helpers already partly live in the base `SioDriver`.

Effort/risk: the multi-recv and normal-swap helpers are a **safe within-file
dedup for netcore** (2 call sites each) and a partial fit for link.nim. Extracting
them is ~half a day and low risk. Collapsing the *drivers* themselves is **not**
advisable: their control flow is genuinely sync-vs-async and link.nim is N-core;
a shared driver would need a scheduling abstraction over "advance the peer" that
is `run_to` locally and "wait for a wire REPLY" remotely — that is effectively
what netcore's `RemoteSioDriver` + `try_advance` already are. Estimated multi-day
with real desync risk against `trade_repro`; payoff is modest (the semantics are
already only ~40 lines each). **Recommendation: extract the pure helpers if/when
either driver is next touched; do not rewrite the drivers.**

A larger, separate question is whether native online should adopt the browser's
input-rollback model (so both production paths share `link.nim` + `rollback.nim`
and netcore becomes the fallback only). That is a product/architecture decision,
out of scope for a mechanical refactor.

## Other simplification notes (not yet actioned)

- netcore.nim `replay_overruns*` carries a doc-comment block that describes both
  `replay_overrun` and `replay_cost` (netcore.nim ~1003-1009) — cosmetic.
- `WIRE_MULTI`/`WIRE_NORMAL8`/`WIRE_NORMAL32` in netcore alias the `LINK_MODE_*`
  constants for readability; harmless.

## Verification (both targets, at each step)

- Native test harness (`nim c -d:test_harness -d:release`) and wasm
  (`nimble wasm`) both build clean after each change.
- PASS: `linktest`, `normlinktest`, `norm32linktest`, `attachtest` (lockstep);
  `speclink` multi/normal/normal32 and `speclinkbench` (netcore speculative +
  rollback); `rollback`, `rollbacknet`; `netlink` two-process TCP (multi).
- `trade_repro.nim` requires the copyrighted ROMs and is not runnable here; the
  in-repo test ROMs above cover the same netcore/link/rollback code paths.
