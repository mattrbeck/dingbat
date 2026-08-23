# Speculative rollback over the network link

`src/dingbat/gba/netcore.nim`. Off by default; `netlink_set_speculative` /
`?speculative=1` on the web. Bench: `tests/roms/speclinkbench.gba` with
`--mode=speclinkbench` (in CI); correctness gate `--mode=speclink`.

## Why

The blocking link stalls the initiator one round-trip per transfer. Cable
Club handshakes poll continuously, so under real latency a trade crawls
(~1 fps at 50 ms). Speculation predicts the responder's word, continues, and
rolls back on a mismatch — GGPO's trick applied to SIO rounds.

## How it is built

Only the **initiator** speculates (`has_mastered`, set in `master_start`;
the responder never blocks on a reply).

* `master_complete` with no REPLY yet: if within the window, `predict()` the
  word, latch it, append to `round_log` marked predicted, continue instead
  of `reply_wait`.
* `predict(mode)`: the **echo predictor** — once the responder has mirrored
  us `ECHO_CONFIRM` rounds in a row for that mode (`peer_echo`), predict our
  own outgoing word; otherwise the responder's last word for that mode.
  Symmetric "all players ready" syncs echo, so this hits 198/200 rounds
  where last-word hit 99/200. `echo_predict` is a bench hook; `force_wrong`
  a test hook.
* Checkpoints at each `try_advance` `naFrame`: `(cycle, state_payload,
  round snapshot)`. Frame-granular because `state_payload` is valid only at
  frame boundaries.
* `feed` → `lmReply`: match the `round_log` entry by cycle **order**, not
  exact cycle (intra-frame timing drifts a few cycles across a restore).
  Match → `advance_confirmed`; mismatch → `rollback_and_replay`: restore the
  newest checkpoint ≤ that round and re-emulate, re-supplying logged words
  and replaying `input_log` (host input routes through `note_input`).
* Window: `SPEC_WINDOW_FRAMES = 8` (~130 ms). Past it, `window_wait` parks in
  the blocking `reply_wait`, so the worst case is the blocking path. The lead
  while speculating is `window_cycles + FRAME_CYCLES` (`effective_lead`).
* Two invariants, each once a crash: `advance_confirmed` clamps
  `confirmed_cycle` to an in-flight round's start so its checkpoint is not
  pruned; the log is retained back to `replay_start(checkpoints[0])` so a
  round straddling the oldest checkpoint can re-fire.
* `replay_overrun` counts replays that ran past the log (the lossy
  idle-latch fallback → divergence). The echo predictor keeps it at 0 at
  delays 0 and 50; `replay_overruns()` exposes it.

Telemetry: `Module._netlink_debug()` / `pred_stats()` →
`spec[hits misses rollbacks ckpts log window_wait confirmed]`. Read it on
**both** sides before changing anything: hit rate, rollback growth,
`window_wait`, and the advance rate of `now` (realtime = 16.78e6 cycles/s).

## What the tests measure

`--mode=speclink` proves bit-identity with the blocking path (ON reproduces
the EWRAM log exactly at delays 0–50 for multi / normal-8 / normal-32, and a
forced-misprediction predictor still matches) but its speed proxy counts
steps/stalls, **not** rollback re-emulation — which is how a predictor that
rolled back every third round of a cyclic handshake looked fine.
`speclinkbench` reports `replay_cyc`, `overrun` and cpu-ms over a 200-round
symmetric handshake; that is the number to watch.

## Open

* A real asymmetric trade may push the echo predictor into many rollbacks;
  the next step is rollback-during-replay / checkpoint regeneration, or
  sub-frame checkpoints (`state_payload` is frame-only, so that needs a
  lighter snapshot path).
* The native app links blocking-only; speculation is wasm-side.
* Responder-side speculation only if measurement shows unit 1 is the
  bottleneck (its advance is gated by the master's delayed TRANSFERs).
