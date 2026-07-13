# Speculative rollback — investigation handoff

Status as of the end of the multiplayer-phase3b speculation work. Read this
before continuing; it captures what works, the open problem, how the engine is
built, and where to look next.

## TL;DR

The GBA network link works and is correct. Under real latency the *blocking*
path is unusably slow (per-round round-trip stall). We built GGPO-style
**speculative rollback** to fix that; it is **proven bit-identical to the
blocking path in a synthetic native test**, but in a **real Pokémon Emerald
trade under latency it does NOT recover the frame rate** — with
`?speculative=1&linkdelay=50` the trade still crawls (~1 fps), same as blocking.
That regression-in-the-real-world-but-pass-in-the-test gap is the open problem.

## What is proven / works

- **Base link (blocking + adaptive lead):** two Emerald saves complete a real
  trade on localhost (no latency) at full speed. Correct.
- **Adaptive lead** (`netcore.effective_lead`, commit `2f6f2e7`): tightens the
  bounded lead while a serial link mode is active so the Cable Club handshake
  converges. Without it the handshake never entered the Trade Center.
- **Speculation engine** (commit `e2d1395`): native `--mode=speclink` test
  passes — speculation ON reproduces the blocking-path EWRAM log **exactly**
  across delays 0/20/30/40/50 for multi / normal-8 / normal-32, and a
  forced-misprediction predictor rolls back every round and *still* matches.
  So the mechanism is correct.
- **Native host/guest link** (commits `ad7efe5` CLI, `289a5e5` in-app ImGui
  Host/Join window). Speculation is **not** wired into the native app (blocking
  path only), so native online play is slow under real latency.
- **Browser input wiring + opt-in** (commit `9b752a4`): host input routes
  through `note_input` so rollback replays it; speculation is off by default,
  enabled with `?speculative=1`.

## The open problem

`?speculative=1&linkdelay=50` in the browser Emerald Trade Center does not
recover fps — it still crawls. The user confirmed:
- `linkdelay=50` **without** `speculative` → ~1 fps (expected: blocking stall).
- `speculative=1&linkdelay=50` → speculation "doesn't seem to work" (still slow).

Meanwhile the native `speclink` test shows ON ≫ OFF under the same delay. So
something about the *real, continuous* Emerald trade differs from the *short*
synthetic test. **That is the thing to explain.**

## How speculation is built (src/dingbat/gba/netcore.nim)

Only the **initiator** speculates (`has_mastered = true`, set in `master_start`;
the responder keeps the tight `lead_active` and never blocks on a reply anyway).

- `master_complete` (transfer done, no REPLY yet): if `speculative` and within
  the window, `predict()` the responder's word, latch it, append to
  `round_log` (marked `predicted`), and **continue** instead of `reply_wait`.
- `predict(mode)`: returns `last_reply[mode and 7]` — **the same word the
  responder last actually sent for that mode.** Rationale: handshakes send runs
  of identical/slowly-changing words. `force_wrong` is a test hook.
- Checkpoints: at each `try_advance` `naFrame` boundary, push
  `(cycle, state_payload(gba), <netcore round snapshot>)`. Frame-granular
  because `state_payload` is only valid at frame boundaries.
- `feed` → `lmReply`: locate the `round_log` entry by cycle-order cursor
  (NOT by exact cycle — intra-frame timing drifts a few cycles across a restore,
  so matching is by order). Predicted+match → `advance_confirmed`. Predicted+
  mismatch → `rollback_and_replay(m.cycle)`: restore newest checkpoint ≤ that
  round, re-emulate forward re-supplying logged words + replaying `input_log`.
- Window: `SPEC_WINDOW_FRAMES = 8` (~130 ms). When
  `now() - confirmed_cycle > window_cycles`, park in `window_wait` = fall back
  to the blocking `reply_wait`. Worst case == today's behavior.
- Lead while speculating: `window_cycles + FRAME_CYCLES` (see `effective_lead`,
  ~line 250), so the master may run the window ahead.

Telemetry (`debug_state`, also `pred_stats()`):
`spec[hits=H misses=M rollbacks=R ckpts=C log=L window_wait=B confirmed=…]`

## FIRST STEP: gather telemetry from the real failing trade

Do this before changing anything. In the browser, with
`?speculative=1&linkdelay=50`, get both tabs into the Trade Center, then in each
tab's console read `Module._netlink_debug()` a few times over a couple seconds.
Note, for BOTH host (unit 0, the speculator) and guest (unit 1):
- `hits` vs `misses` → the **prediction hit rate**.
- `rollbacks` growth rate → how often it re-emulates.
- `window_wait` → whether it fell back to blocking.
- `now` advance rate → each side's actual speed (cycles/sec; realtime = 16.78e6).

That single measurement disambiguates the hypotheses below.

## Hypotheses (ranked)

1. **Low hit rate → rollback thrash (most likely).** The captured Emerald
   handshake cycles words `0x961e, 0xcafe, 0x11, 0x00, 0x00, …`
   (see `tests/local-emerald-link/`). "Same as last" mispredicts on each change
   (~3 of 8 rounds ≈ 37% miss). Each miss rolls back to the *frame-start*
   checkpoint and re-emulates up to a whole frame (~12 rounds). A miss every ~3
   rounds ⇒ the master re-runs each frame several times ⇒ **more** work than
   blocking. The native speclink test hides this: it is only **16 rounds total**,
   so the per-frame re-emulation cost never compounds the way a continuous trade
   does. Confirm via `hits/misses/rollbacks`.
2. **Window fills → back-pressure to blocking.** If rollbacks keep holding
   `confirmed_cycle` back, `now - confirmed > window_cycles` trips and
   `window_wait` engages → blocking. Check `window_wait=true`.
3. **Rollback re-emulation cost dominates.** `rollback_and_replay` re-runs whole
   frames (280896 cycles) on the CPU; frequent rollbacks = N× CPU work. Same
   root as #1.
4. **The responder (unit 1) is the bottleneck.** Speculation only helps unit 0.
   Unit 1's advance is gated by receiving the master's latency-delayed
   TRANSFERs; the two are coupled (the master's window can't confirm without the
   responder's REPLYs). Measure BOTH sides — if unit 1 crawls, master-only
   speculation can't win.
5. **Input replay overhead.** Long shot; `input_log` replay on each rollback.

## Concrete next experiments

1. **Measure (above).** Decide which hypothesis holds before coding.
2. **Better predictor** (if hit rate is low — `predict` is one small proc):
   - Predict the master's *own* outgoing word (the responder frequently echoes;
     in the capture the two matched exactly because same trainer).
   - Or a short pattern/history predictor (last-N, or per-round-index).
   Re-measure hit rate. A high hit rate should make rollbacks rare and recover
   fps without touching the rollback machinery.
3. **Cheaper rollback** (if cost dominates): checkpoint more often than
   per-frame (a lighter per-round snapshot of just the mutated state?), or
   re-emulate only the affected rounds instead of the whole frame. Hard —
   `state_payload` is frame-only, so this may need a new lighter snapshot path.
4. **Reproduce natively.** The speclink test is too short. Extend it (or drive
   the local Emerald replay in `tests/local-emerald-link/`) into a **continuous,
   hundreds-of-rounds** multi-mode exchange with a *cyclic* data pattern like
   Emerald's, and confirm ON is NOT faster than OFF — then debug natively
   instead of fighting the flaky browser harness.
5. **Consider responder-side speculation** only if #4 is confirmed.

## Reproduction

Browser (the real failing case):
1. `cp ~/Downloads/PokemonEmeraldShiny*.{gba,sav} web/`
2. `nim c -d:emscripten src/dingbat_wasm.nim`
3. `python3 web/serve.py &` and `(cd web/signaling && node server.js &)`
4. Two tabs at `http://localhost:8765/?speculative=1&linkdelay=50`; drop the ROM
   in each and seed its `.sav` into IndexedDB (`save:<romname>`); connect via
   **Link Cable → Host / Join**; walk both to the attendant → Trade Center.
   (See `tests/local-emerald-link/README.md` for the detailed recipe and the
   captured wire trace.)

Native (correct, fast — but short; extend it to reproduce the slowdown):
`nim c -d:test_harness -d:release --path:src -o:/tmp/dt tests/dingbat_test.nim`
`/tmp/dt tests/roms/linktest.gba --mode=speclink --timeout=7200`

## Files & commits (branch multiplayer-phase3b, unpushed)

- `src/dingbat/gba/netcore.nim` — the engine: `predict`, `master_complete`,
  `feed`(lmReply), `rollback_and_replay`, `advance_confirmed`, `try_advance`
  (window/lead), `debug_state`/`pred_stats`, `note_input`.
- `src/dingbat_wasm.nim` — `setInput`→`note_input`; `specEnabled` +
  `netlink_set_speculative`.
- `web/netplay.js` — `NET_SPECULATIVE` (`?speculative=1`) + setter call.
- `src/dingbat.nim` — native link (CLI `--listen/--connect` + ImGui window). No
  speculation.
- `tests/dingbat_test.nim` — `--mode=speclink`.
- `tests/local-emerald-link/` — **gitignored** (via `.git/info/exclude`):
  README recipe, captured wire trace (`emerald-cable-club-sync-trace.json`),
  and `replay_smoke.nim`. Needs the local (uncommitted) Emerald ROMs+saves in
  `~/Downloads/PokemonEmeraldShiny{1,2}.{gba,sav}`.

Commits: `2f6f2e7` adaptive lead · `e2d1395` speculation engine · `ad7efe5`
native CLI link · `289a5e5` native link window · `9b752a4` input wiring +
opt-in speculation.

## Key insight for whoever picks this up

The synthetic test passes because it is **short and adversarial-but-tiny** (16
rounds). The real trade is **long and cyclic**. The most likely failure is that
"same word as last" mispredicts on every word-change in Emerald's repeating
handshake, and frame-granular rollback re-emulates a full frame per miss — so
speculation does more work than it saves. **Measure the hit/miss/rollback
telemetry in the real trade first**; if the hit rate is low, fix the predictor
before touching the rollback machinery.
