# iOS display pacing: CADisplayLink vs CAMetalDisplayLink

Prototype on branch `ios-metal-link`. Measured 2026-11-03 on an iPhone 13
mini (60 Hz, iOS 27.0.1), Debug build, muted, by the `-ff-trace` tool:
every number below is a drawable's real `presentedTime`, not a GPU or CPU
time.

**What shipped** (branch `ios-ds-metal-link`): a DS game on iOS 17+ is
paced by the metal link (latency 1), chosen when the game opens; GB/GBA
and iOS 16 keep the CADisplayLink; the fast-forward next-frame check runs
on both. The metal link stops while paused. The prototype's switches
(`-metal-link`, `-metal-link-ff`, `-ff-no-predict`, `-early-start`,
`-probe-*`) stay on branch `ios-metal-link`; the shipped build has
`-no-metal-link` (Debug: a DS game on the CADisplayLink, for A/B). Round 4
below has its numbers.

## The three modes

- **CADisplayLink** (main today): a CADisplayLink calls the tick ~2-4 ms
  before a refresh; the tick runs its frames and presents into the
  MTKView's next drawable.
- **Metal link** (`-metal-link 1`): a `CAMetalDisplayLink` on the picture's
  layer asking for 1 frame of latency (iOS 17+). Each update hands over a
  drawable with a planned presentation time; the tick runs and presents
  into it.
- **Hybrid** (`-metal-link-ff 1`): the metal link in fast-forward, the
  CADisplayLink otherwise, swapped when fast-forward turns on or off.

## Findings

1. **The metal link is a fixed 2 refreshes (33.3 ms) from the start of a
   tick to the glass**, at every speed, for every game. Pictures land
   within 0.2 ms of the planned time. Asking for less than 1 frame of
   latency behaves as 1; the default (2) is 50 ms.
2. **The CADisplayLink's latency depends on the frame's cost.** Its tick
   starts ~3.9 ms before the refresh at 1x. When the frame and its present
   finish inside that window the picture is on glass ~20 ms after the
   tick; when they don't, ~37 ms; a DS frame (whose present waits ~10 ms
   on the GPU) ~46 ms. On this phone a cheap scene (the toggle ROM, 2.5 ms)
   made the window and Emerald's opening (3.9 ms) did not. A faster phone
   makes the window more often.
3. **Pacing is even in both** once the metal link presents every update
   (finding 5). Back-to-back pictures one refresh apart in all but a
   handful of thousands, both modes, 1x, 2x and fast-forward, GBA and DS.
4. **The hybrid's switch costs a refresh.** Half its fast-forward on/off
   switches skip one (12 of 24); neither single link does (0 of 24 and
   1 of 24).
5. **Bug found and fixed:** handing an update's drawable back unpresented
   (an unchanged frame) made iOS drop the next present: about half the
   pictures after a still one were never shown, a press's response among
   them. The metal link now presents every update (the same picture again
   when nothing changed).
6. **Fast-forward's next-frame check** (run another frame only if one as
   costly as the recent ones still fits) is needed by the metal link: DS
   frames ran up to 8 ms past the budget and 80-100 refreshes a run were
   missed without it. With it: none. It costs ~8% of DS fast-forward speed.
   It helps the CADisplayLink too: Emerald fast-forward presented after
   its target 355 and 0 times a run without it (49.0 and 34.7 ms to glass),
   0 and 0 with it (36.1 and 36.1 ms). DS still presents late on the
   CADisplayLink in some runs (411 of 720), its present waiting on the GPU.
   Every CADisplayLink number below is with the check.
7. **Fast-forward speed:** the metal link leaves a 3 ms reserve before its
   work deadline, 13.6 ms of frames a refresh against the CADisplayLink's
   16.4 ms (its tick arrives early), so GBA fast-forward is ~13% slower.
   A 1 ms reserve recovers it on GBA (0-1 pictures never shown a run) but
   not on DS (10-38 never shown).

## Numbers

### Tick start to glass (median ms; every frame of the scene moves)

| | CADisplayLink | Metal link | Hybrid |
|---|---|---|---|
| Emerald opening, 1x | 37.2 / 37.2 | 33.3 / 33.2 | 37.2 / 37.2 |
| Emerald, 2x | 37.2 / 37.2 | 33.2 / 33.2 | 37.3 / 37.3 |
| Emerald, fast-forward | 36.1 / 36.2 | 33.3 / 33.3 | 33.3 / 33.3 |
| SoulSilver opening, 1x | 45.7 / 45.5 | 33.3 / 33.2 | 37.3 / 45.3 |
| SoulSilver, 2x | 47.1 / 46.9 | 33.3 / 33.3 | 37.2 / 47.0 |
| SoulSilver, fast-forward | 48.1 / 48.0 | 33.3 / 33.3 | 33.3 / 33.3 |
| Toggle ROM (2.5 ms frames), 1x | 20.5 | 33.2 | (= CADisplayLink) |

Two runs each, interleaved; p90 is within 1.5 ms of the median except where
two values differ (the CADisplayLink's hybrid runs sit on either side of its
window).

### Press to glass (toggle ROM: the backdrop turns white the frame after A, nothing else changes)

| | CADisplayLink p50 / p90 | Metal link p50 / p90 |
|---|---|---|
| 1x | 29.7 / 38.2, 29.0 / 39.2 | 42.1 / 44.3, 41.0 / 44.4 |
| 2x | 30.3 / 47.9, 31.0 / 47.0 | 39.5 / 44.3, 40.8 / 44.7 |
| fast-forward | 35.6 / 35.9, 35.9 / 36.1 | 35.7 / 36.0, 35.7 / 35.9 |

~30 presses a run, every one answered in the first tick after it. This ROM
is light enough for the CADisplayLink's 20 ms window (finding 2); a scene
that misses the window adds ~17 ms to its column.

### Pacing

| | CADisplayLink | Metal link |
|---|---|---|
| Refreshes missed, all scene runs | 2 of ~13,000 | 7 of ~17,000 |
| Pictures presented but never shown | 1-2 a run | 0 (after the fix; ~50% after a still frame before it) |
| Fast-forward on/off switches skipping a refresh | 0 of 24 | 1 of 24 (hybrid: 12 of 24) |

### Fast-forward speed (fps, same scene, two runs)

| | CADisplayLink | Metal link, 3 ms reserve | Metal link, 1 ms reserve |
|---|---|---|---|
| Emerald | 837 / 833 | 733 / 723 | 865 / 792 (0-1 never shown) |
| SoulSilver | 379 / 329 | 350 / 348 | 377 / 372 (10-37 never shown) |
| SoulSilver, metal link without the next-frame check | | 381 / 381 (85 / 77 refreshes missed) | |

## Not covered

Real-finger touches (the scripted press skips UIKit's touch delivery), link
play, rewind, a ProMotion or newer phone, the iOS 16 fallback, Release
builds.

## Reproducing

`ios/e2e/mkabtoggle.py` makes the toggle ROM. On a device: a Debug build
with `-ff-trace` and a scene plan (`-ff-scene "1x:8,2x:6,ff:5,1x:6"`,
`-ff-scene-warm 2`, `-ff-scene-taps`) plus the mode's switch; pull
Documents/fftrace.txt and summarise with `ios/e2e/ffscene.py` (per speed and
per switch) and `ios/e2e/fftrace.py --speed 1x|2x|ff` (presses).

## Round 3: DS's drawable wait, and starting 1x frames early

**DS on the CADisplayLink waits for a drawable.** In some sessions a DS
present spends ~10 ms in `nextDrawable` (its GPU work is 1.0 ms), which
puts the picture a refresh late (tick to glass 45-48 ms); in others the
wait is ~1.5 ms (37 ms). The state held across consecutive app launches
and then cleared, and did not follow the drawable's size (3x, 2.5x, 2x,
1.5x and 1x each landed in either state), the stylus overlay or the
stage layers. Skipping one present when the wait stays long
(`-probe-drain`) could not be tested in the long-wait state (it did not
recur); in the short-wait state DS on the CADisplayLink is 37 ms against
the metal link's 33. The metal link was 33 ms in every DS run, including
the long-wait sessions.

**The handover deadline.** Over every CADisplayLink 1x tick: a present
ending 1-3 ms before the refresh shows one refresh later in 75-95% of
ticks; one ending at or after it, two. The callback comes 3.85 ms before
the refresh, so the one-refresh case needs the frame and present in
~2 ms on this phone (Emerald's opening takes ~3.9 ms; even the toggle
ROM's empty loop takes 2.2 ms at 1x clocks, against ~1.2 ms an Emerald
frame in fast-forward).

**Starting 1x frames early does not help** (`-early-start`: a timer runs
the refresh's frames its recent cost plus 1.5 ms before the refresh).
The frames ran 6.1-6.3 ms before the refresh, but the present then
waited 1.7-2.2 ms for a drawable, which came free only ~0.7 ms before
the refresh, and the picture still landed a refresh later (tick to glass
39-40 ms against the callback's 37). Draining one present first did not
change it. With one present each refresh the drawable a present needs is
the one the refresh it aims for gives back, so the one-refresh case
happens only when the system keeps a spare drawable, which an app does
not choose. (A first version learnt its lead from the present's end,
drawable wait included, and ran away to 12.6 ms early: earlier starts
waited longer.)

## Round 4: the shipped DS-only metal link

The shipped build, Pokémon SoulSilver, scene `1x:10,2x:6,ff:8,pause:2,1x:8`
after 8 s warm, three runs each of the metal link and `-no-metal-link`,
alternating (iPhone 13 mini, Debug, muted). This session was in the
long-wait state: the CADisplayLink's DS present waited 9.7-9.9 ms for a
drawable in every run.

| | metal link (3 runs) | CADisplayLink (3 runs) |
|---|---|---|
| 1x tick to glass, p50 / p90 ms | 33.3 / 33.4 | 37.3-45.0 / 45.8-45.9 |
| 2x tick to glass, p50 ms | 33.2 | 47.2-47.3 |
| fast-forward tick to glass, p50 ms | 33.2-33.3 | 48.0-48.2 |
| fast-forward fps | 355, 361, 361 | 330, 329, 330 |
| refreshes missed (1x+2x+ff, ~1800 ticks a run) | 2, 0, 0 | 0, 1, 0 |
| pictures never shown | 0, 0, 1 | 0, 0, 0 |
| speed switches: worst picture gap | 1 refresh | 1 refresh |
| after the pause: first picture, refreshes skipped | 55-65 ms, 1-2 | 47-59 ms, 1-2 |

GB/GBA in the same build are unchanged: Emerald 1x 37.3 ms and
fast-forward 911 fps; the toggle ROM 1x 20.5 ms.

The metal link's one cost: a still DS picture (sleeping, powered off, a
menu that does not move) is drawn and presented every refresh, where the
CADisplayLink presents only on a change (every update's drawable must be
presented, above). In play both present every refresh.
