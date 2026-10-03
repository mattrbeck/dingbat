# playtest — cross-emulator gameplay and save-file harness

Plays a game from a recorded input timeline in dingbat and two reference
emulators, compares the screens at named checkpoints and the audio throughout,
saves in-game in each, compares the battery files, then boots every
emulator's save in every emulator.

dingbat runs four ways, so a difference can be pinned on one feature:

| name | BIOS | waitloop skipping |
|---|---|---|
| `dingbat` | HLE (the shipped default) | on |
| `dingbat-nowl` | HLE | off |
| `dingbat-bios` | official | on |
| `dingbat-bios-nowl` | official | off |

The references (`mgba`, `nba`) always run the official BIOS.

```
tools/playtest/build.sh                                  # drivers + OCR tool -> bin/
tools/playtest/playtest.py run  ~/roms/game.gba          # needs scripts/<sha1>.play
tools/playtest/playtest.py run  f3ae088181bf583e55daf962a92bb46f4f1d07b7   # by sha1
tools/playtest/playtest.py suite [emerald ...] --jobs 2  # every script (or a filter)
tools/playtest/report.py out/suites/<tag>                # findings.json: who stands alone where
```

Output lands in `out/runs/<title>-<sha1>/<timestamp>/` (`latest` symlink):
`results.json`, `report.html`, `cmp/*.png` side-by-side composites, every
emulator's environment directory and battery file, `audio/*.wav` clips of
differing audio. Exit status is 0 when every dingbat variant passes. A suite
writes `out/suites/<tag>/index.json` (one row per game, logs beside it); a
second suite with the same `--tag` extends it.

`report.py` reduces a suite to findings: at each checkpoint the six emulators
fall into groups that show the same screen, and a finding is a grouping
(reported where it first appears) with the group that stands alone named as
the suspect: `dingbat`, `dingbat:hle-bios`, `dingbat:waitloop`, `mgba`,
`nba`, or `unclear`. Audio, save files and each save's readers are grouped the
same way.

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
   emulator (once per distinct save file: the dingbat configurations usually
   write identical ones). A cell passes when its checkpoints match that
   emulator's run with its own save, and booting must leave the battery file
   byte-identical.
5. **Audio** — every driver dumps its output (`--audio`, s16le stereo at
   32768 Hz) for the whole `[new]` run; `audio.py` compares quarter-second
   windows aligned by emulated frame (level after each emulator's own gain,
   band shape, stereo width) and counts a window against dingbat only where
   the references agree. Only features and clips of differing spans are kept.

## Scripts

`scripts/<rom sha1>.play` — the ROM itself is never committed; `@file` names
the file it was recorded on so `run <sha1>` can find it in the library
(`PLAYTEST_LIBRARY`, colon-separated; default `~/Documents/emu/gba` and its
`archive/roms`). The language is documented in `script.py`.

Scripts are **frozen**: a fixed input timeline (`wait`, `press`, `hold`,
`tap`, `checkpoint`) that reads no screen, so every emulator gets the same
keys on the same frames and a screen that differs at a checkpoint is a
finding. They are written by playing in a live session (below; AUTHORING.md is
the full how-to), where conditions such as `until text "CONTINUE"` or `mash A
until text "GIRL"` are resolved on the slowest emulator and recorded as frames,
the condition kept as a comment. `playtest.py freeze` converts an older
condition script the same way (`freeze_all.py` for every one), keeping the
original in `scripts/source/`.

`@status` other than `ready` (e.g. `@status wip: stuck at intro`) makes
`suite` skip the script. `@save none` marks a game with no battery save,
`@save skip: why` a script that stops before the first save (play and audio
are still compared). `@frozen` names the emulators the timeline was resolved
on.

## Writing a script: live sessions

```
playtest.py serve emerald --rom ~/roms/emerald.gba &     # all three emulators, kept running
playtest.py do emerald 'wait 900' 'press START' look
playtest.py do emerald 'until text "NEW GAME" timeout=600' 'mark menu' look
playtest.py do emerald 'rewind menu'
playtest.py do emerald log                               # the recorded script so far
playtest.py do emerald stop                              # quits emulators, keeps saves
```

`serve` runs the official-BIOS emulators (`dingbat-bios`, `mgba`, `nba`) in
lockstep: every step ends with all of them on the same frame after the same
input. `look` writes a PNG (one frame when they all agree, side by side when
not) and prints each emulator's OCR text and the guessed selected menu entry.
A step that fails on any emulator is rolled back everywhere, held keys
included (and a failure screenshot kept), so the recorded script always
reproduces the emulators' state; rewinding to a mark forgets the marks made
after it. `serve --save-dir DIR` boots each emulator with the save it wrote
itself (a stopped session's `saves/`) to develop the `[load]` section.
`saveinfo` says whether a battery file holds data. `statecheck.py` checks that
saving (and loading) a state changes nothing in any emulator.

## Writing a script: recording a human

Build the desktop app from this tree (`nimble build -d:release`), then:

```
playtest.py record <rom or sha1> --section new     # play to an in-game save, quit the app
playtest.py record <rom or sha1> --section load    # boots with that save: continue into the game, quit
```

Each recording gets its own directory, `out/recordings/<sha1>/<section>-<time>/`
(ROM symlink, the app's `game.sav`, `input.log`, `<section>.play`), so nothing
touches your library or normal saves; `--section load` starts from the latest
`new` recording's save. While playing: **F9** marks a screen worth checking
(it becomes a checkpoint); don't load states or rewind (the log marks the rest
unusable); fast-forward is fine. The app's RTC is frozen at the harness epoch
while recording.

Underneath, `DINGBAT_INPUT_LOG=<file>` makes the desktop app log keypad changes
per emulated frame, a framebuffer hash every 60 frames, marks, and the end
frame. `record` prints the next command when the app quits:
`playtest.py convert LOG --rom ROM --section S [--save SEED]` replays the log
headless in dingbat with the same BIOS mode and **checks every hash** (if the
replay diverges from what you saw, the script stops there and says at which
frame), then writes your inputs on exactly the frames you pressed them:
`press` / `hold` / `release` and `wait`, a checkpoint at every F9 mark, one a
minute into any unmarked stretch, and one at the end. It reads no screen text:
every emulator gets the same input timeline, so a checkpoint that differs is a
finding (an emulator that reaches a screen late has a timing difference), not
something the script should wait out. Add `@title`/`@file` and save it as
`scripts/<sha1>.play`.

## Game list

`games.json` is the target list: the popular library plus carts whose save
hardware is ambiguous or unusual (several or no library ID strings, 4Kbit vs
64Kbit EEPROM, RTC, tilt/solar sensors), each with its SHA-1 and the ID strings
found in the ROM.

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
| `freeze.py` / `freeze_all.py` | condition script -> frozen input timeline |
| `audio.py` | audio features, comparison, WAV clips |
| `report.py` | suite -> findings (who stands alone at each difference) |
| `statecheck.py` | save-state round-trip check per emulator |

## Driver protocol

Each driver is started as `<driver> <rom> <bios.bin|hle> [--run-bios] [--rtc EPOCH] [--audio PATH]`
(dingbat also `--no-waitloop`, `--mp2k-hle` for the apps' Enhanced audio setting,
`--no-fifo-interp` for the raw FIFO latches), prints `ready ...`, then answers one line per
command with `ok [...]` or `err ...`:

| command | effect |
|---|---|
| `keys MASK` | set held keys; bits in KEYINPUT order A B SELECT START RIGHT LEFT UP DOWN R L |
| `run N` | run N frames; replies with the frame count |
| `runhash N` | run N frames; replies with each frame's framebuffer hash |
| `hash` | FNV-1a of the 15-bit framebuffer (identical frames hash identically in every driver) |
| `shot PATH` | write the framebuffer as a binary PPM |
| `state_save PATH` / `state_load PATH` | emulator-native save state |
| `savedata PATH` / `flush` | where supported (not the second reference) |
| `peek ADDR LEN` | LEN bytes as hex: any address (dingbat, mGBA); work RAM, IWRAM and I/O only (the second reference, through its save-state copy and I/O peek calls) |
| `rtc_get` | read the cartridge RTC over the GPIO port as a game does: DATE_TIME register bytes and the status byte, hex (dingbat, mGBA) |
| `rtc_set YYMMDDWWHHMMSS` | DATE_TIME write of those register bytes (dingbat, mGBA — mGBA ignores clock writes) |
| `poke8 ADDR VAL` | bus write, e.g. a flash command that dirties the save (mGBA) |
| `chmask N` | output-only channel mutes, bits 0-3 PSG 1-4, 4 FIFO A, 5 FIFO B, a set bit plays (dingbat: `APU.channel_mask`; mGBA: its public `enableAudioChannel`); the frames are unaffected |
| `apulog PATH` / `apulog off` | log every byte written to 0x04000060-0x0400008F as `FRAME CYCLE_IN_FRAME ADDR VALUE` (dingbat: `bin/dingbat_driver_trace`, built with the core's passive `-d:biosdrvtrace` I/O hook, selected with `PLAYTEST_DINGBAT_DRIVER`; mGBA: the CPU's stores, wrapped) |
| `trace N PATH` | N single instruction steps, one line each to PATH: `PC CYCLES VCOUNT T/A` (r15 before the step, master-clock cycles it took), `FRAME` at each frame end (dingbat, mGBA). dingbat's r15 leads the instruction by 4 (Thumb), mGBA's by 2 |
| `runto PC` | step until r15 == PC; replies r0..r15 (dingbat) |
| `pft PC N PATH` | run to r15 == PC, then N steps with the `-d:pftrace` prefetch log to PATH (dingbat built with `-d:pftrace`) |
| `quit` | flush the battery file and exit |

`peek` in dingbat is untimed (it used to charge wait states, so peeking every
frame moved the game's own timing); the second reference's leaves its audio
byte-identical with a peek every frame. Comparing two emulators' instruction
traces of the same code is how docs/playtest-bugs.md section 29 found
which loops cost what.

`rtc_crosscheck.py [rom]` uses these to prove the battery-save RTC trailer
carries a cart clock between dingbat and mGBA in both directions, on frozen
and wall clocks (see `src/dingbat/gba/rtc_calendar.nim` for the format).

Every driver skips the BIOS intro by default, so frame 0 is the first game
frame everywhere. Drivers run with `TZ=UTC`; the RTC is frozen at the script's
`@rtc` epoch where the emulator allows it (dingbat, mGBA).
