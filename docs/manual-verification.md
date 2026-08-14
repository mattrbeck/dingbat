# Manual verification list

Things that shipped with unit-test coverage but still need a hands-on check
against the real world (live Google account, deployed https build, multiple
devices) that the harnesses can't provide. Check an item off — or just delete
it — once it's been seen working; add a dated entry whenever something lands
that needs the same treatment.

## "Clip that!" — range-based clip export (2026-08-14)

Retroactive clip capture grew from a hardcoded trailing 10 s to a picked range
over a ~60 s rolling window, on the rewind scrubber's film strip with two
markers. The replay's determinism has a real gate
(`tests/clip_replay_test.nim`, three ROMs, whole-machine-state hashes) and the
range arithmetic has one (`web/tests/clip-range.test.mjs`), but neither
harness has a MediaRecorder, a canvas, or a GPU — so everything about the
FILE is unproven, and so is the strip as a touch control.

- [ ] **The file is the range.** Pick a range with a recognisable event in it
      (a level transition works well), save, and play the .webm back. Expect
      the clip to start on the frame the in marker sat on and end on the out
      marker's — no leading frames of the live moment (`drawGame()` before
      `captureStream` is what prevents that), no tail running on to "now".
- [ ] **Audio is in it, and in sync.** Same clip: sound present from the first
      frame, still lined up at the end of a 60 s export.
- [ ] **A full minute exports.** "Everything" on a GBA game after a minute or
      more of play. Expect a ~60 s file, the banner counting to 100%, controls
      inert throughout, and the game resuming exactly where it was left.
- [ ] **On a phone (LAN https).** Drag each marker; they must not swap, the
      film must not carry momentum after the finger lifts, and tapping the
      strip must move the NEARER marker. Check portrait and landscape, and
      rotate with the picker open (the strip re-rasterises on resize).
- [ ] **Safari.** The recorder there produces .mp4 rather than .webm; confirm
      the file plays and the audio track is present.
- [ ] **Rewind OFF.** Turn rewind off in Settings (and/or turn speed mode on,
      which suspends it) and confirm the clip picker still shows a full strip.
      This is the case the clip ring's own thumbnails exist for.
- [ ] **iOS memory.** Play for several minutes on the phone with the 6 MB clip
      cap and confirm no tab reload / JIT demotion, and that the picker's
      oldest frame is still roughly a minute back on a GB game.
- [ ] **The rewind scrubber still behaves.** It was refactored onto the shared
      film-strip component; re-check the drag, the tap, the two-stage confirm
      and the save-loss warning.

## Drive sync: renames (2026-08-14, `3f9370a`)

Renames now mirror to Drive as in-place metadata renames, and a `ren` marker
in the shared library migrates other devices. All engine paths are
unit-tested (`web/tests/sync.test.mjs`, `rename.test.mjs`); what's unproven
is the real Drive API + two real devices.

- [ ] **Drive-only rename.** On a device that does NOT hold a game's bytes
      (Drive-only tile), rename it from Manage ROMs. Expect: rename succeeds
      immediately, the tile shows the new name, and after the sync flush the
      game still downloads on tap — under the new name, saves intact.
- [ ] **Two-device migration.** Rename a game on device A that device B holds
      locally (with a battery save). On B's next sync expect: a toast
      ("…renamed on another device"), NO "removed on another device" delete
      modal, and B's ROM/saves/states/cheats all answering to the new name.
- [ ] **No re-upload.** Rename a large downloaded ROM and watch the sync
      indicator: the flush should be near-instant (metadata PATCHes only),
      not a multi-MB upload.
- [ ] **Rename while playing elsewhere** (hardened 2026-08-15 after the first
      field test failed). Rename on A while B is mid-game on the same title,
      then switch back to B's tab. B's very next sync should migrate live:
      the game keeps running and now answers to the new name, the grid shows
      one installed tile, and the quick save survives — never an
      "uninstalled" tile over stranded old-name data.
- [ ] **The failed field flow, re-run.** Install + quick save in browser 1
      (leave the game open), rename from browser 2 where it was never
      downloaded, return to browser 1 and sync/reload. Expect one installed
      game under the new name with the quick save present, and no old-name
      files left on Drive afterwards.

## Drive sync: original ship (2026-07-23, `a023c79`) — still open

- [ ] **Two-device delete/tombstone round-trip** against a live account:
      delete on A, confirm B shows the "removed on another device" modal and
      that Restore really does re-upload. Unit-tested since day one, never
      seen live.
