---
name: playtest-train
description: Validate a dingbat core change against the 135-game playtest corpus (tools/playtest) through the shared test train instead of a private full suite -- especially when other agents are also testing. Use before landing any change to src/ or the playtest harness that could move a game's screens, audio or saves, and whenever you would otherwise run `playtest.py suite` over the whole corpus.
---

# The playtest train

A full playtest suite is 135 frozen-input game scripts in six emulator
configurations: 40-60 minutes at `--jobs 6`, and the whole machine. Several
agents each running one at once thrash it and all of them crawl. The train
runs the corpus **once** for everyone: every pending candidate is merged onto
one build, the four dingbat configurations play every game (the two
reference emulators are replayed from the cached baseline, not played), and
only the games that changed are replayed on each candidate alone to say
whose change it was.

Tool: `tools/playtest/train.py` (run from any checkout of the repo; state is
shared in `~/.cache/dingbat-train`).

## When to use what

| situation | do |
|---|---|
| iterating on one game or a handful | `playtest.py run <sha1>` or `playtest.py suite <filters...> --jobs 2` -- a subset is fine any time |
| "does my change move anything in the corpus?" | **the train** |
| before handing a core change to the lander | **the train** |
| a change touching only docs, web, other tools | nothing: the train would mark it `skipped` anyway |

**Never launch your own whole-corpus `playtest.py suite` while a train
exists or other agents are testing.** A full suite now waits for the train's
machine lock anyway (`--no-lock` exists for the lander's deliberate use, not
for yours).

## Before the train: CI's own tests

The train covers games, not unit tests. Run every test step CI runs, read
from `.github/workflows/test.yml` so the list cannot drift:

    python3 tools/ci_local.py            # ~4 min; --only <substr> for one step

A hand-picked gate list misses steps: the stub-BIOS commit (df656c3e)
passed build, runner, cycle laws and the corpus and still failed CI's OBJ-list
fuzz, which no gate list named. Revert timestamp-only `tests/results*.md`
changes afterwards.

## Submitting

Commit your change first (the train tests commits, not working trees). It
must be a commit on top of some `main`; the train merges `merge-base..ref`
onto the current `origin/main`.

```
python3 tools/playtest/train.py submit HEAD --name "eeprom 8k keep" --wait
```

`--wait` blocks until your verdict exists and exits **0** clean, **1**
changes found (printed), **2** could not merge or build. Nobody needs to
start a daemon: whoever is waiting when no train is running takes the lock
and drives the train for everyone in the queue. Run it in the background and
check on it rather than sleeping in a loop:

```
python3 tools/playtest/train.py submit HEAD --name X --wait > train-X.log 2>&1 &
python3 tools/playtest/train.py status       # queue, running train, stage, games done
python3 tools/playtest/train.py show <id>    # a verdict again (any part of the id)
```

A train takes about as long as one dingbat-only suite (roughly two thirds of
a full one) plus a few minutes per candidate when games changed; the first
train on a new `origin/main` also refreshes the baseline (dingbat only, the
references replayed). Don't resubmit while waiting: a new submission is a
new candidate.

## Reading a verdict

Every game is compared with the baseline per dingbat configuration on
pass/fail **and every hash**: each checkpoint frame and its hash window, the
`[new]` audio dump, the battery file, every `[load]` cell the configuration
writes or reads. A pixel moving at a checkpoint is a change even if nothing
flips.

| verdict / entry | meaning | you |
|---|---|---|
| `clean` | no game differs from the baseline in any hash | done |
| `skipped` | touches nothing the corpus builds from | done |
| `landed` | already in `origin/main` | done |
| **fixed** | a configuration went FAIL -> PASS | check it is the game you meant; cite it in the commit |
| **regressed** | PASS -> FAIL | yours until shown otherwise: open the runs it lists (`report.html` in each) |
| **mixed** | fixed in one configuration, regressed in another | as regressed |
| **neutral** | same pass/fail, different pixels/audio/save | explain it: an expected timing shift, or a hidden regression the verdicts did not catch |
| **interaction** | a change no candidate makes alone, or two candidates changing the same hash differently | tell the lander; rerun alone after the other lands |
| `conflict` | does not merge onto `origin/main` | rebase and resubmit |
| deferred | conflicts with an earlier candidate in the same train | nothing: it rides the next train first |
| `build-failed` | does not build on `origin/main` | fix and resubmit |

The report (`~/.cache/dingbat-train/runs/<run>/report.md`) lists, per
changed game, the baseline run, the combined run and your candidate's own
run directories: compare their `report.html` and `cmp/*.png`. Fixed games
show the problems they had; regressed ones the problems they have now.

Caveat: a game identical on the combined build is taken as identical on
every candidate (frozen inputs, deterministic core). Two changes that exactly
cancel would hide each other; that is the only blind spot.

## What the lander does with it

The orchestrating session lands candidates whose verdicts are `clean`, or
whose fixed/neutral changes are the intended ones, rebased onto `main` in
the order the train merged them. Regressions and interactions go back to
their agents (or wait for the other candidate to land, then rerun alone).
After landing, the next train's baseline is the new `origin/main`. The
lander may run `train.py baseline` after a landing to have it ready.

## Commands the lander also uses

```
python3 tools/playtest/train.py run                    # drive trains until the queue is empty
python3 tools/playtest/train.py baseline               # refresh the baseline of origin/main now
python3 tools/playtest/train.py baseline --commit X --suite out/suites/TAG   # adopt an existing suite
python3 tools/playtest/train.py run --only emerald kirby --jobs 2            # a subset train (testing)
```
