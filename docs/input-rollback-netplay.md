# Input-rollback netplay + cross-ROM transmission — implementation handoff

Status: **design + partial foundation**, as of 2026-07-13 (branch
`multiplayer-phase3b`). Read `docs/speculative-rollback-handoff.md` first for how
we got here. This doc is the forward plan for a future implementer.

## Why this architecture (the short version)

The SIO-word speculation approach is a **dead end for real trades** and has been
disabled (`web/netplay.js` `NET_SPECULATIVE = false`). Reason: the master
predicts the peer's SIO reply, keeps running, and puts the *next* transfer —
built from that prediction — on the wire. In a real trade the outgoing word
depends on the received word, so a misprediction ships bytes the guest already
consumed and can't be recalled → the guest's game raises "link error". Proven
deterministically by `tests/roms/speclinkdep.gba` (`--mode=speclinkbench`): the
`round_out == out_word` divergence assert fires; the wasm builds `-d:danger`
(asserts off) so it silently corrupts instead of crashing.

**The correct design** (what real rollback netcode does for deterministic games):

- Run **both GBA cores locally on each peer** (reuse the existing local 2-core
  lockstep engine, `src/dingbat/gba/link.nim`). The SIO cable is resolved
  **locally** at full speed — it never touches the network.
- Network **only the two players' button inputs** (a ~1-byte bitmask per player
  per frame, mostly "no change").
- **Predict** the remote player's input (repeat last), and **roll back**
  (restore a per-frame checkpoint, re-simulate with the corrected input) when a
  late input arrives mispredicted. Reuse `state_payload`/`apply_state_payload`.

Consequences: no per-round RTT (SIO is local); bandwidth drops ~100× (inputs vs
~420 SIO rounds/s + ~6500 CLOCK beacons/s); latency only affects rare menu taps,
hidden by prediction/rollback.

## What already exists

- **Local 2-core lockstep** (`link.nim`): `new_link([core0, core1])`,
  `step_frame()` advances both one video frame, SIO resolved by
  `LockstepSioDriver`. Verified full-speed with Pokémon Ruby (local 2P mode).
- **Rollback primitives** (`link.nim`, added this work):
  `capture_state()`/`restore_state()` (LinkSnapshot = both cores' `state_payload`
  + link offsets + multi round state), and `state_checksum()` (FNV over the
  cores only — deliberately NOT offsets, which are a local clock bias).
- **Validation harness**: `tests/dingbat_test.nim --mode=rollback` +
  `tests/roms/inputrec.gba` (an input-TIMELINE-sensitive ROM: its EWRAM
  accumulator folds each KEYINPUT sample with a counter, so a wrong-then-
  corrected input must replay faithfully or the result differs). The harness
  runs a local GGPO simulation: player 0 known immediately, player 1 delayed N
  frames + predicted, rolled back on misprediction, then compared to a
  ground-truth run where every input was known upfront.
- **Transport** (from phase 3b): WebRTC DataChannel between two browsers, shared
  code rendezvous (`web/signaling/server.js` relays only SDP/ICE — game data is
  always P2P). Auto-detect link activity via `sio_mode() == smMulti`.

## ✅ BLOCKER — RESOLVED (2026-07-13)

The `--mode=rollback` full predict+rollback loop now passes bit-identically (90
frames, ~78 rollbacks). Root cause was a **savestate completeness bug**:
`save_bus_state`/`load_bus_state` did not serialize the ROM **burst/prefetch
timing trackers** — `rom_next_addr`, `rom_next_addr2`, `rom_free_since`,
`rom_hot`, `dma_active`. These persist across frame boundaries (the CPU keeps
fetching from ROM), so after a restore the first ROM access was mistimed
sequential-vs-nonsequential by a few cycles; the frame then ended a few cycles
off, the CPU stopped at a different loop position, and it compounded. Fixed by
serializing them (savestate bumped to **v3**). This also silently improved
normal save/load and rewind fidelity (they had the same latent one-access
mistiming). The harness's check (5), "restore-older-onto-newer + replay", is the
regression guard, and `--mode=rollback` is now in CI.

Lesson for the next determinism bug: any state that PERSISTS across a frame
boundary and affects emulation MUST be serialized; "rebuilt caches" is only safe
for state that is genuinely re-derived each frame. Grep the Bus/PPU/APU/DMA/
timer types for fields written by emulation but absent from `save_*_state`.

## Cross-ROM transmission — the requirements (the reason for this doc)

Same-version trades can avoid sending ROMs (each peer loads its own copy). But
**cross-version trades** (Ruby↔Sapphire, Emerald↔FireRed, …) require each peer
to run the *other* player's core locally, which needs the other player's ROM. We
**cannot** assume the peer already has it. So ROM bytes must be exchanged.

### 1. Connect-time manifest handshake (over the DataChannel)

After the DataChannel opens, before starting the cores, each peer sends a
manifest:

```
{ t:"manifest", romChecksum, romSize, romTitle, saveSize, buildId }
```

- `romChecksum`: reuse `gba_rom_checksum` (FNV over the first 1 MB) or a full
  hash — must uniquely identify the ROM image the peer is running.
- `buildId`: emulator build identifier. **Abort with a clear message if the two
  builds differ** — determinism requires identical emulation. (Bake a build hash
  into the wasm; compare here.)
- Decide roles/core-order deterministically and IDENTICALLY on both sides:
  e.g. **core 0 = host's game, core 1 = guest's game** (host = first to the
  rendezvous, already the WebRTC offerer). Both peers MUST agree.

### 2. ROM availability + request

- On receiving the peer's manifest, check the local ROM library (web:
  IndexedDB `blobs` store — see `web/index.js` `openDB`/`dbGet`; keys are
  currently `save:<name>`; add `rom:<checksum>` entries) for a ROM whose
  checksum matches `peer.romChecksum`.
- If present → use it locally, send `{t:"rom-have", checksum}`.
- If absent → send `{t:"rom-need", checksum}`. The peer then streams its ROM.

### 3. Chunked ROM/save transfer with flow control

- ROMs are up to 32 MB; DataChannel messages are size-limited (~256 KB safe) and
  the send buffer bloats. Chunk (e.g. 64–128 KB) and respect backpressure:
  pause when `dc.bufferedAmount` exceeds a high-water mark, resume on
  `bufferedamountlow` (`dc.bufferedAmountLowThreshold`). Do NOT blast the whole
  ROM into `dc.send` at once.
- Message shape: `{t:"rom-chunk", checksum, seq, total}` + a following binary
  frame, or length-prefixed binary. Reassemble in order (DataChannel is
  reliable+ordered) and **verify the reassembled checksum** before use; abort on
  mismatch.
- Saves are tiny (32–128 KB) — send whole. A save is the user's own game data,
  not Nintendo IP; the ROM is the sensitive artifact.
- Show transfer progress in the UI (a 16 MB ROM over a home connection is
  several seconds). Persist a received ROM to the library so a second trade with
  the same partner skips the transfer.

### 4. Deterministic dual-core boot + t=0 agreement

- Both peers construct the SAME `new_link([core0, core1])` from the exchanged
  ROM+save pairs, boot deterministically (skip-BIOS or identical HLE; no
  wall-clock/RNG in init), and **exchange a `state_checksum()` at frame 0**.
  Abort if they differ — that means a determinism gap, and it is far better to
  fail loudly at t=0 than to corrupt a trade later.

## Determinism requirements (audit these — desyncs live here)

The whole model rests on both machines emulating identically given the same
inputs. Known hazards:

1. **RTC wall-clock — DONE (2026-07-13).** `src/dingbat/gba/rtc.nim` used to read
   `local(now())` (real wall-clock AND local time zone). Fixed: an RTC
   `deterministic` mode + `epoch` (UTC unix seconds), serialized (savestate v3),
   enabled via `enable_deterministic_rtc(gba, epoch)`. When on, the clock is a
   frozen shared UTC epoch — identical on both peers, stable across rollback.
   Single-player still reads wall-clock (default off). **Remaining wiring:** the
   session must call `enable_deterministic_rtc` on BOTH cores with the SAME epoch
   (exchange one peer's `epoch` in the connect manifest). Freezing (not
   advancing) is fine for a minutes-long trade; if a longer session ever needs
   the clock to advance, drive `epoch` from a serialized emulated-frame counter.
2. **Scheduler serialization under rollback** — the BLOCKER above.
3. **Uninitialized memory** — GBA WRAM/VRAM/OAM/palette are deterministic from
   reset; confirm no path reads allocation garbage. (The rollback byte-diff hunt
   is a good lens: any non-deterministic byte in `state_payload` will show up.)
4. **Audio/APU** — must be bit-deterministic in state; the local 2P mode already
   plays only P1 audio, and rollback must suppress audio during re-simulation
   (don't emit re-simulated samples).
5. **Any other `std/times` / RNG / float-nondeterminism** in the core — grep for
   `epochTime`, `now(`, `getMonoTime`, `Math.random`-equivalents.

## Rendering / audio / UX

- Each peer renders only **its own** core's framebuffer (the player sees their
  own game). Reuse the per-core RGBA framebuffer path from local 2P mode
  (`link_fb_ptr`), but here show only the local player's core.
- Audio from the local core only; suppress during rollback re-simulation.
- Auto-end the session when **both** cores have left `sio_mode() == smMulti` for
  a debounce window (a few seconds, to ride over menu transitions) — the player
  never has to manually disconnect.
- Desync detection: exchange `state_checksum()` every K frames (over the
  confirmed frame, not a predicted one). On mismatch, surface a clear error and
  stop rather than silently corrupt — this is the safety net for any determinism
  gap that slips through.

## Legal note (maintainer's call)

ROM transmission is strictly peer-to-peer (never through our servers; signaling
only relays SDP/ICE), user-initiated, and between two people who each own their
copy. It is nonetheless transmitting copyrighted ROM bytes. Options to consider:
require both to already own the ROM (a one-time consent/attestation prompt),
prefer the local-library path so ROMs cross only when genuinely needed, and keep
ROMs off any server/log. The decision is the maintainer's; the architecture
supports "never transmit — require local ROM" as a config if preferred (at the
cost of blocking cross-version trades when a peer lacks the partner's ROM).

## Suggested implementation sequence

1. ✅ **Rollback determinism bug** (was the blocker). `--mode=rollback` full loop
   passes; the bus ROM-timing serialization fix also cured a latent rewind bug.
2. ✅ **Deterministic RTC** (`enable_deterministic_rtc`, savestate v3).
3. ✅ **Transport-agnostic rollback session** — `src/dingbat/gba/rollback.nim`
   (`RollbackSession`: owns the Link, per-frame input ring, prediction, rollback
   to the confirmed frontier only on a real misprediction, checksum). Proven by
   `--mode=rollback` (one-sided) and `--mode=rollbacknet` (TWO independent
   sessions exchange only inputs over a delay → both bit-identical to ground
   truth AND each other). Both in CI.
4. ✅ **Wasm exports + browser smoke-test** — `rollback_init(rom0, rom1,
   localPlayer, epoch)` / `rollback_tick(localBits)` (→ frame to ship, or -1
   stalled) / `rollback_feed(frame, bits)` / `rollback_fb_ptr` (local core RGBA)
   / `rollback_head` / `rollback_confirmed` / `rollback_exit`. Smoke-tested in
   Chrome: **0.35 ms/frame** sustained incl. rollbacks (well under the 16 ms
   budget), renders, no hangs. GOTCHA fixed: the audio-mute wrappers must be set
   via a helper PROC, not an inline for-loop — a loop-body closure aliases the
   last iteration's `orig`, cross-wires the two cores' event dispatch, and hangs.
5. ✅ **JS rollback loop + input networking — DONE, verified in-browser.**
   `web/index.js`: `rollbackMode` RAF branch (read local buttons → `rollback_tick`
   → ship `(frame,bits)` → blit `rollback_fb_ptr` to link-canvas-0); input funnels
   (`routeP1Input`, gamepad) capture into `localButtons`; `enter/leaveRollbackMode`.
   `web/netplay.js`: `NET_ROLLBACK` (default on; `?rollback=0` = old SIO path).
   Connect handshake over the DataChannel (binary frames: 0 hello[epoch,romHash],
   1 save[len,bytes], 2 input[frame,bits]): on DataChannel open both send hello+
   save; on having the peer's hello (→ shared host epoch) + save, write both
   ROMs (same bytes, same-version) + both saves, `rollback_init`, enter rollback
   mode. `?linkdelay=NN` delays outgoing input (test). Same-version ROM-hash
   guard (mismatch → clear error). **Verified: two Chrome tabs, goodboy, shared
   code → 60 fps at 0 ms AND 59–60 fps at linkdelay=50 (was ~1 fps), renders, no
   errors, prediction window absorbs latency (head leads confirmed by 3–5).**
6. **Manifest + ROM/save exchange** over the DataChannel (chunked, backpressure,
   checksum-verified, library-cached) — enables cross-version. Saves already
   cross (fine ≤128 KB / Emerald); ROMs (≤32 MB) need chunking + backpressure.
7. **Cross-version end-to-end**: Ruby↔Sapphire trade over injected latency.

## Recommended follow-ups (not blocking the fast trade)

- **Desync detection:** exchange `state_checksum()` every ~K confirmed frames;
  on mismatch, stop with a clear error instead of corrupting. (A wasm
  `rollback_checksum` export + a periodic RB_CHECKSUM message.) The engine is
  proven deterministic natively, but a real cross-machine trade should carry
  this safety net.
- **Large-save chunking:** a 128 KB save sends as one DataChannel frame today
  (works); very large payloads / ROMs need chunking + `bufferedAmountLow`.
- **Teardown polish:** `rbTeardown` persists the local player's post-trade save;
  confirm across a full Emerald trade + disconnect.

## Files

- `src/dingbat/gba/link.nim` — Link engine + rollback primitives
  (`capture_state`/`restore_state`/`state_checksum`).
- `src/dingbat/gba/rtc.nim` — RTC (wall-clock, needs the deterministic fix).
- `src/dingbat/gba/savestate.nim` — `state_payload`/`apply_state_payload` (the
  scheduler section is where the rollback bug lives).
- `tests/dingbat_test.nim` `--mode=rollback` + `tests/roms/inputrec.{s,gba}` —
  the validation harness.
- `tests/roms/speclinkdep.{s,gba}` — the safety probe proving SIO-word
  speculation desyncs (why we pivoted).
- `web/netplay.js` — transport + shared-code UI (speculation disabled).
- `web/signaling/server.js` — SDP/ICE relay (rendezvous).
