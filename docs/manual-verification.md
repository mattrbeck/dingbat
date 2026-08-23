# Manual verification list

Things that shipped with unit-test coverage but still need a hands-on check
the harnesses cannot provide (live Google account, deployed https build,
real devices). Delete an item once it has been seen working; add one
whenever something lands that needs the same treatment.

## "Clip that!" — range-based clip export

Gated: replay determinism (`tests/clip_replay_test.nim`), range arithmetic
(`web/tests/clip-range.test.mjs`). Not gated: the FILE, the strip as touch.

- [ ] **The file is the range.** Pick a range around a level transition;
      the .webm starts on the in marker's frame and ends on the out marker's,
      no leading live frames, no tail to "now".
- [ ] **Audio in sync** through a 60 s export; **a full minute exports**
      (banner to 100 %, controls inert, game resumes where it was).
- [ ] **Phone (LAN https).** Markers never swap, no momentum after lift, a
      tap moves the NEARER marker; portrait, landscape, rotate with the
      picker open.
- [ ] **Safari** produces .mp4; confirm it plays with audio.
- [ ] **Rewind off** (or speed mode on): the picker still shows a full strip.
- [ ] **iOS memory**: several minutes with the 6 MB clip cap, no reload or
      JIT demotion; oldest frame still ~a minute back on a GB game.
- [ ] **Rewind scrubber** (shared film-strip component): drag, tap,
      two-stage confirm, save-loss warning.

## Input display overlay

Settings → Controls → "Show inputs on screen" (`I` key);
`web/tests/input-display.test.mjs`.

- [ ] **iPhone LAN test.** With touch controls up the overlay is absent — no
      reserved space, touch buttons unchanged. Pair a Bluetooth controller:
      overlay bottom-left inside the safe area.
- [ ] **OBS capture** shows the overlay; the app's own Record Clip does not
      (canvas.captureStream — deliberate).
- [ ] **Legible at stream size**; **device themes** (`--pad-*` /
      `--btn-ab-*` / `--pill-*` tokens) spot-checked on two loud ones.
- [ ] **L/R present for .gba, gone for GB/GBC** with no gap.

## Drive sync: renames

Engine paths unit-tested (`web/tests/sync.test.mjs`, `rename.test.mjs`).

- [ ] **Drive-only rename**: immediate, still downloads after the flush,
      saves intact. **No re-upload**: a large ROM's rename flushes instantly.
- [ ] **Two-device migration**: rename on A; B's next sync toasts "renamed
      on another device", no delete modal, ROM/saves/states/cheats answer to
      the new name.
- [ ] **Rename while playing elsewhere**: B mid-game, A renames; B's next
      sync migrates live — one installed tile, quick save intact, no
      old-name files left on Drive.

## Drive sync: original ship

- [ ] **Two-device delete/tombstone round-trip** against a live account:
      delete on A, B shows "removed on another device", Restore re-uploads.
