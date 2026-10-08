# Writing a playtest script by playing the game

A script is a fixed input timeline: which keys, on which frames, plus named
checkpoints. You find the route by playing in a live session (looking at the
screen); the session records what you did as frames, so replaying it later
reads no screen at all.

Everything below runs from `tools/playtest/`.

## 1. Start a session

```
python3 playtest.py serve NAME --rom "/path/to/Game (U).gba" > out/serve-NAME.log 2>&1 &
```

Wait until the log says `ready`. The session boots the game in the three
official-BIOS emulators (`dingbat-bios`, `mgba`, `nba`) and keeps them running
**in lockstep**: every step ends with all three on the same frame after
identical input. NAME must be unique (another session using it is refused).

## 2. Play

```
python3 playtest.py do NAME 'wait 300' look
python3 playtest.py do NAME 'until text "PRESS START" timeout=1500 every=10' 'press START' look
python3 playtest.py do NAME 'mash A until text "NEW GAME" every=20' look
```

- Steps: `wait N`, `press KEYS [hold=6] [after=0]`, `hold KEYS`, `release`,
  `tap KEYS times=N [every=20] [hold=4]`, `until COND`, `mash KEYS until COND`,
  `checkpoint NAME`. Keys `A B SELECT START RIGHT LEFT UP DOWN R L`, combined
  with `+` (`press A+B`). Conditions: `text "STR"`, `notext "STR"`,
  `selected "STR"`, `stable N`, `changed`, `blank`, `notblank` (script.py).
- `look` writes a PNG (path printed) and prints each emulator's OCR text.
  **Read the PNG to see the screen.** When all three show the same frame it is
  one image labelled `all identical`; otherwise all three side by side.
- `until` / `mash` are recorded as what the *slowest* emulator needed (plus a
  few frames), the condition kept as a comment, so the script never needs to
  read the screen again.
- A step that fails on any emulator is rolled back on all of them and not
  recorded (a failure screenshot is printed). Nothing you try by mistake ends
  up in the script.
- `mark NAME` / `rewind NAME`: save states on all emulators. Use them to retry
  a hard section (a jump, a fight) as often as needed; rewinding also truncates
  the recorded script to the mark.
- `undo` drops the last recorded step (without rewinding the emulators).
- `log` prints the recorded script so far.

Batch several steps per `do` (a batch stops at the first failing step). Take a
`look` when you need to decide something, not after every press.

## 3. Checkpoints

`checkpoint NAME` screenshots every emulator (and hashes 30 frames either
side, so it advances 60 frames). Put 4-8 in `[new]` at screens worth
comparing: title, main menu, name entry, first gameplay, a menu over
gameplay, the save prompt, the save confirmation. 2-3 in `[load]`: the
continue/file screen showing the save, and the game resumed. Names are
lower_snake_case.

## 4. Reach a save, then stop

Play `[new]` until the game has written its battery save (the save
confirmation is on screen), then

```
python3 playtest.py do NAME stop
```

which quits every emulator the way a user closes it (flushing the battery
file) and copies the saves to `out/sessions/NAME/saves/<emu>.sav`. Check one
is really written (not blank):

```
python3 playtest.py saveinfo out/sessions/NAME/saves/*.sav
```

## 5. The [load] section

```
python3 playtest.py serve NAME-load --rom "/path/to/Game (U).gba" --save-dir out/sessions/NAME/saves > out/serve-NAME-load.log 2>&1 &
```

Each emulator boots the save it wrote itself. Play to the continue screen
(checkpoint), load the file, and checkpoint the resumed game. Do not save
again in `[load]`. `log`, then `stop`.

## 6. Write the script

`scripts/<sha1>.play` (`python3 playtest.py sha1 ROM`):

```
@title Game Name (USA)
@file Game Name (U).gba
@game BXXE
@chip EEPROM
@frozen dingbat-bios,mgba,nba
# One or two lines: the route (new game, name "AA", first save at ...).

[new]
...the [new] session's `log` output, unchanged...

[load]
...the [load] session's `log` output, unchanged...
```

`@file` is the exact archive file name (the run finds the ROM by it).

## 7. Check it

```
python3 playtest.py run <sha1> --emus dingbat-bios,mgba,nba --no-audio
```

replays the script with no screen reading at all. Every emulator should
complete `[new]`, write a save, and load the others' saves. Differences
between emulators are findings, not script bugs: note what you saw.

## When the first save is far away

Play to it: use `mark`/`rewind` freely; RPG dialogue, menus and early levels
are all doable. Look for an earlier save the game makes on its own (options,
high scores, a stage clear). If one emulator cannot follow (hangs, crashes,
or its random numbers send it somewhere else), that is a finding: note the
frame and what each emulator shows; you may restart the session without it
(`--emus dingbat-bios,mgba`) and say so in the script's comments.

If a save is truly out of reach, keep what you have: `@save skip: <why, and
where the first save is>` on a script whose `[new]` still plays a couple of
minutes of real gameplay with checkpoints (no `[load]`). A game with no
battery save at all (passwords) gets `@save none`.

## Rules

- Never write into the ROM library; the harness works on symlinks in `out/`.
- Do not edit the harness code or rebuild `bin/` (it kills running sessions).
- In script comments name emulators only by their keys (`mgba`, `nba`).
