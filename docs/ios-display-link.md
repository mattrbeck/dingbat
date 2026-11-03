# iOS display pacing: CADisplayLink vs CAMetalDisplayLink

Prototype on branch `ios-metal-link`. Measured 2026-11-03 on an iPhone 13
mini (60 Hz, iOS 27.0.1), Debug build, muted, by the `-ff-trace` tool:
every number below is a drawable's real `presentedTime`, not a GPU or CPU
time.

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
