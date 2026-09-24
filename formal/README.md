# Lean models of the web frontend's state machines

Each file in `WebState/` models one state machine in `web/` (mostly
`web/index.js`), states the properties the code is meant to keep, and proves
them, or proves by a concrete trace that the code does not keep them.

Check everything with `lake build` from this directory (Lean 4.34, no Mathlib),
then `lake env lean AxiomAudit.lean`, which fails if any theorem rests on
`sorry`, `native_decide` or an axiom beyond Lean's standard three. CI runs both
(`.github/workflows/lean.yml`). Check one file with
`lake env lean WebState/<File>.lean`.

| File | Machine |
|---|---|
| `GameLifecycle` | launchRom / loadRom / resumeGame / unloadGame, paused card, resume toast |
| `RunPause` | `paused`, pausing overlays, remote pause, Screen Wake Lock, AudioContext |
| `SavePersistence` | `rom.sav` ↔ `save:<game>`, persistSave, auto-state, slots, reset, import |
| `DriveSession` | token renewal, sign in/out, the upload queue, the sync lamp |
| `DriveLibrary` | mergeLibrary algebra, tombstones, renames, pull/flush commits across two devices |
| `Thumbnails` | storeLastFrame, grid picture fetches, object URLs, the picture batch |
| `Modals` | the focus trap, promise-returning prompts |
| `Netplay` | web/netplay.js signaling, redial ladder, channel race, rollback entry/exit |
| `ServiceWorker` | update check, web/sw.js install/activate/fetch, reload on controllerchange |

`FINDINGS.md` ranks every counterexample the models found.

## How a model is built

- **One file per machine**, namespace `WebState.<File>`. No imports beyond
  Lean core, so files build independently.
- **State** is a `structure` holding exactly the JS variables (module `let`s,
  IndexedDB keys, DOM flags) the machine reads or writes. Each field's comment
  names the JS variable.
- **Events** are an `inductive`. An `async` function is split at every `await`:
  each segment between awaits is one atomic event, because JS runs a segment
  to completion but anything can run between segments. A call in flight is a
  value in the state (a pending continuation carrying the locals it
  captured), and its resumption is a separate event the scheduler may fire
  at any time, including after other user taps, timers, `visibilitychange`,
  `pagehide`, network responses and other in-flight continuations. Modelling
  an `await` as instantaneous hides exactly the bugs worth finding here.
- **`step : State → Event → State`** (or a `Step` relation when the JS is
  nondeterministic, e.g. a fetch that may succeed or fail). Every branch
  carries a comment with the JS function name and line numbers at the commit
  the model was written against.
- **`Reachable`** is the inductive closure of `step` from `init`.

## What gets proved

- **Invariants**: `Inv init`, `Inv s → Inv (step s e)`, hence
  `Reachable s → Safety s`. Safety properties are the ones the code's
  comments, commit messages or user-facing behaviour promise.
- **Progress**, where it matters, as a state property: e.g. "with nothing in
  flight, the sync lamp is not spinning".
- **Refutations**: when the code does not keep a property it means to, the
  file proves a concrete counterexample: an explicit `List Event` whose run
  from `init` reaches a bad state, checked by `decide`/`rfl`, and named
  `bug_<what>`. The report says whether that trace is reachable in a browser
  and how to reproduce it.
- **Regressions**: once the JS is fixed, the model's `step` follows the fixed
  code (the header names the commit), the invariant the bug broke is proved
  for every reachable state where the model allows, and each `bug_*` trace
  becomes a `regress_*` theorem showing the same trace now ends safely.

No `sorry`, `axiom`, `native_decide` or `admit` anywhere: `lake build` must be
clean for the proofs to mean anything.

## Staying honest

A model is only as good as its match with the JS. Each file's header lists
what it abstracts away and why that does not affect the stated properties.

The models are an audit's snapshot, not a contract every commit keeps; the
regression tests are that. Every bug these models found has a test in
`web/tests/` that replays its trace against the real `web/index.js`, and those
run on every push. `lean.yml` only builds the proofs when `formal/` changes.

To start the next audit, run `node formal/anchors.mjs`. Each model's
`-- @models` lines name the JS functions it describes, and `anchors.json`
holds a token hash of each one as it was when the model last matched the
code; comments and whitespace do not count. The script lists the models whose
functions have changed since. Model those machines again from the current
code with the method above, turn any new counterexample into a fix and a test,
then `node formal/anchors.mjs --update`.
