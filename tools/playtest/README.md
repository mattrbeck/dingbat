# playtest — cross-emulator gameplay and save-file harness

Plays a game from a recorded script in dingbat and two reference emulators,
compares the screens at named checkpoints, saves in-game in each, compares the
battery files, then boots every emulator's save in every emulator.

```
tools/playtest/build.sh                                  # drivers + OCR tool -> bin/
tools/playtest/playtest.py run  ~/roms/game.gba          # needs scripts/<sha1>.play
tools/playtest/playtest.py run  f3ae088181bf583e55daf962a92bb46f4f1d07b7   # by sha1
tools/playtest/playtest.py suite [emerald ...]           # every script (or a filter)
```

Output lands in `out/runs/<title>-<sha1>/<timestamp>/` (`latest` symlink):
`results.json`, `report.html`, `cmp/*.png` side-by-side composites, every
emulator's environment directory and battery file. Exit status is 0 when every
dingbat variant passes.

## What a run checks

1. **`[new]`** — every emulator boots with no battery file, in its own
   directory (a ROM symlink plus whatever `.sav` the emulator writes beside
   it), and plays the script up to an in-game save. The emulator is then quit
   the way a user closes it, which flushes the save.
2. **Screens** — at each `checkpoint`, dingbat is classified against each
   reference (see `classify.py`): IDENTICAL, SLIP (the same frame within the
   checkpoint's hash window, offset reported), MINOR (≥98% identical pixels,
   tiny error, or a pure palette step), DIFFERENT (same layout and text,
   content differs), MAJOR, FAILED. A checkpoint where the two references
   disagree with each other at least as much is reported as not diagnostic.
3. **Save files** — size against the chip sizes named by the ROM's library ID
   string, trailers (bytes after the chip data), byte-diff ranges, and, for
   games with a decoder in `saves.py`, structural validity and the decoded
   player-chosen fields (Pokémon Gen 3: section checksums, name, gender).
4. **Cross-load** — `[load]` runs with each emulator's save seeded into each
   emulator. A cell passes when its checkpoints match that emulator's run with
   its own save, and booting must leave the battery file byte-identical.

## Scripts

`scripts/<rom sha1>.play` — the ROM itself is never committed; `@file` names
the file it was recorded on so `run <sha1>` can find it in the library
(`PLAYTEST_LIBRARY`, colon-separated; default `~/Documents/emu/gba` and its
`archive/roms`). The language is documented in `script.py`. Steps wait on
screen conditions (`until text "CONTINUE"`, `until stable 20`, `mash A until
text "GIRL"`) rather than fixed frame counts wherever pacing can differ between
emulators, so one script replays on all of them.

`@status` other than `ready` (e.g. `@status wip: stuck at intro`) makes
`suite` skip the script.

## Writing a script: live sessions

```
playtest.py serve emerald --rom ~/roms/emerald.gba &     # all three emulators, kept running
playtest.py do emerald 'wait 900' 'press START' look
playtest.py do emerald 'until text "NEW GAME" timeout=600' 'mark menu' look
playtest.py do emerald 'rewind menu'
playtest.py do emerald log                               # the recorded script so far
playtest.py do emerald stop                              # quits emulators, keeps saves
```

`look` writes a side-by-side PNG and prints each emulator's OCR text and the
guessed selected menu entry. A step that fails on any emulator is rolled back
everywhere (and a failure screenshot kept), so the recorded script always
reproduces the emulators' state. `serve --save FILE` seeds a battery file to
develop the `[load]` section.

## Pieces

| file | role |
|---|---|
| `drivers/*` | persistent headless driver per emulator, one line protocol (below) |
| `screenread.swift` | macOS Vision OCR over a PPM frame (`--serve` for a persistent process) |
| `screen.py` | OCR client + selected-entry heuristics (cursor glyph, cursor ink, highlighted box) |
| `script.py` / `runner.py` | script language and executor |
| `session.py` | live exploration daemon |
| `classify.py` / `img.py` | checkpoint verdicts, frame metrics, PNG composites |
| `saves.py` | battery-file description, comparison, game decoders |
| `pipeline.py` | `run`: the whole flow and report |
| `library.py` | ROM lookup by SHA-1 |

## Driver protocol

Each driver is started as `<driver> <rom> <bios.bin|hle> [--run-bios] [--rtc EPOCH]`,
prints `ready ...`, then answers one line per command with `ok [...]` or `err ...`:

| command | effect |
|---|---|
| `keys MASK` | set held keys; bits in KEYINPUT order A B SELECT START RIGHT LEFT UP DOWN R L |
| `run N` | run N frames; replies with the frame count |
| `runhash N` | run N frames; replies with each frame's framebuffer hash |
| `hash` | FNV-1a of the 15-bit framebuffer (identical frames hash identically in every driver) |
| `shot PATH` | write the framebuffer as a binary PPM |
| `state_save PATH` / `state_load PATH` | emulator-native save state |
| `savedata PATH` / `flush` / `peek ADDR LEN` | where supported |
| `quit` | flush the battery file and exit |

Every driver skips the BIOS intro by default, so frame 0 is the first game
frame everywhere. Drivers run with `TZ=UTC`; the RTC is frozen at the script's
`@rtc` epoch where the emulator allows it (dingbat, mGBA).
