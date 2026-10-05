# Findings: web frontend state machines (models against dd7ba741f)

## Status after the fix round (2026-09-23)

Every High and Medium item below is fixed. Each fix has a regression test in
`web/tests/` that replays the trace against the real `web/index.js` and fails
on the code before it. The models now describe the fixed code: each fixed
`bug_*` is a `regress_*` theorem, and the safety invariants are proved over
every interleaving of the real `step`.

| # | Fixed in | Regression tests |
|---|---|---|
| 1, 2, 3, 9 | ceda0c0ab, 2a0ab74a2, 5ae072e5d, 7e20ac602 | game-switch, library-races |
| 4, 5 | 82828e847, a4884469b | game-switch |
| 6, 7 | a29fd75a9 | library-races, drive-listing |
| 8, 10, 11 | 2dfade3a9 | sync-queue-races, drive-session |
| 12, 14 | 6d3e1a42b, 5e3b4f8ec | run-pause, link-pause |
| 13, 16 | 5fdef0fc7 | update-flow, sw-install |
| 15 | 18ee44cc5 | game-switch |
| UI pass: Resume vs in-flight load, Tab on home | 263ab540d | game-switch, run-pause |
| UI pass: Sync re-uploading a deleted game, orphans left on Drive | 780ce08b9 | library-races |
| UI pass: account switch publishing Drive-only games | c9ed53745 | drive-session |

**Driven through the real UI.** Headless Chromium ran every serious and
medium item's scenario through the visible UI, with the real wasm core. Drive
ran on two browser profiles against a fake Google that answers like the
Drive v3 and GIS documentation. The pass found three bugs and fixed them
(the last three rows). The results:
- The local scenarios (game switch, resume, close, import, reset, update in
  another tab, home-screen keys, clip export, modals, double taps,
  thumbnails, rename, delete, state slots, rewind) all pass.
- Drive scenarios D0-D8 (baseline, rename back, delete during upload,
  account switch mid-sync, signed-out quiet, token expiry, paging and a
  duplicate library, mixed builds with origin/main, game switch) all pass.
- On origin/main, the same scripts fail where this file says they should.

**Low items fixed along the way:**
- Resume and saves: Resume over an unflushed save, and the quota retry.
- Remote pause, link end, link setup error, and a load under the Report or
  Link modal; the netplay wake-lock leak.
- The thumbnail load-gap pixels.
- Found by reading: Drive listing paging, the duplicate `library` file, and a
  delete outranked by its own upload.

**New bugs the models found while modelling the fixed code, now fixed:**
- A rename chain across devices folding one game into another
  (`bug_mergeV1_chain_not_idempotent`).
- A sign-in whose account check failed going on to sync the previous
  account's queues.
- A rename's stale copy of the sync state dropping a save queued while its
  transaction ran.
- A reset undone by a pull landing mid-download.
- A clip export begun during a load running on into the new game.
- A load landing while a rollback session is set up but not yet started.
- A save import lost to the outgoing persist, or reverted by Resume.
- Closing a game dropping a paused core's dirty battery RAM.
- The SIO link path naming its game before its save was in.
- A Drive-only tile's download overriding a later tap.
- Shortcuts on the home screen acting on the hidden game (Tab, F5, F8, F9 and
  Backquote).

**Proved after the fix round:**
- The merge is idempotent on every input, rename markers included
  (`DriveLibrary.merge_idem`).
- No sync crosses a sign-out or an account switch
  (`DriveSession.Session.Safe`).
- `save:<g>` only ever holds game g's battery
  (`SavePersistence.provenance`).
- The run/pause invariant holds for every event
  (`RunPause.inv_reachable`; flights included since fbdb7975, see below).

**Still open, all low:**
- The Drive spinner with no token and pending work, and one denied popup
  counting as two strikes (`DriveSession`).
- Modals: the nested focus trap, the orphaned suspect-ROM promise, and the
  swallowed rename error (`Modals`).
- The manual-code retry, and a cancelled dial marking the server down
  (`Netplay`).
- Orphan `frame:` records (the batch racing a tombstone delete; a pull
  racing a rename, found 2026-10-05), and the batch overwriting a pulled
  frame (`Thumbnails`). A delete racing the frame chain or a pull is no
  longer reachable (see the re-audit at the end).
- A force update's copy into the live cache is not atomic (`ServiceWorker`).
- The merge is still non-commutative on a same-millisecond rename tie and
  non-associative on `imp`.
- Two devices uploading the same save at once can leave duplicate save files
  on Drive.
- A set-up rollback session is not ended when 2P link mode starts; this is
  probably unreachable.
- **Fixed 2026-09-25 (c577df15, Matt's call: respect the delete, keep the
  old save restorable for 30 days): a deleted game loaded again got its
  deleted save back.** Device 1 deleted a game and loaded it again; device 2,
  not yet pulled, uploaded its old save and device 1 took it, because
  `mergeLibrary` dropped a tombstone once a newer entry existed. Library
  entries, tombstones and Drive files now carry a generation (new on a
  re-import after a delete; absent = 0, so old libraries merge as before); a
  save from an older generation is never applied, but kept as "a save from
  before you deleted this game" with Restore (swap, so undoable) in the
  game's menu and Manage Saves, for 30 days, then dropped everywhere.
  Deleting and re-importing on one device before a sync no longer cancels
  the queued Drive deletes. `DriveLibrary` Layer 3 models it
  (`bug_reimport_gets_deleted_save`, `regress_reimport_keeps_deleted_save_aside`);
  `web/tests/deleted-save.test.mjs` (8 tests, all failing on the old code)
  and the two-device UI rig guard it. The anchors of DriveSession,
  GameLifecycle, Modals, SavePersistence and Thumbnails now list functions
  this change touched: re-model them at the next audit. Kept aside, not
  lost: a new file an old build (no generation stamp) creates for a
  re-imported game, until that device's service worker updates.

## Re-audit at 03f88d6c (2026-10-05): GameLifecycle, RunPause, Modals

The three models follow the code at 03f88d6c (citations at that commit).

- **GameLifecycle.** The paused card is the hero's paused mode (it stays up,
  stale but inert, after a close until the library re-renders); a launch from
  the home screen can go back into the session at the boot (`launchRom`'s
  `resume`: the session read before `touchRecent`, applied in L4 only if taken
  with the battery just installed); going home stores the session and the
  save and dismisses the Resume offer; a hidden tab stores the save too; the
  pull's hand-off lets the game in memory go (no flush, only when its live
  battery is the stored save) and lands Drive's save; checkpoints store the
  session every minute of play. Every property still holds over every
  interleaving; new: `boot_resume_keeps_battery`, `handoff_drops_only_stored`.
- **Modals.** The clip export's progress panel is a trap owner that closes
  itself when the export ends. Without nesting it returns focus where it was
  (`single_progress_returns`). Found at 03f88d6c, **fixed in fbdb7975**: a
  file failing the ROM check dropped during an export put its prompt over
  the panel, and after Cancel and the export's end focus was on `<body>`
  (low). The drop is now refused while a clip records:
  `regress_drop_during_clip_export_loses_focus`; test "a file dropped while a
  clip records is refused (bug_drop_during_clip_export_loses_focus)" in
  `web/tests/run-pause.test.mjs`. Still open in the known nested-trap class:
  a sync begun before the export reaching its deleted-games prompt over the
  panel (`obs_tomb_over_progress_loses_focus`).
- **RunPause.** The off-screen export: Cancel and a load landing mid-encode
  both restore `paused` once, and the encode's tail does not touch it again
  (`clip_cancel_restores_pause`, `clip_load_mid_encode`,
  `clip_cancel_then_tail`). **Found at 03f88d6c, fixed in fbdb7975 (low-medium):
  a flight's hold was a plain `paused = true`.** `holdForFlight` (resume from the hero, or a launch
  from the home screen, for the 460 ms the picture flies) writes the global
  every pausing surface snapshots as the player's choice, and
  `releaseFlight` unpauses whenever `body.running` and the button is unlit:
  - an overlay opened during the flight (Rewind double-tap, Report a Bug,
    Clip that!) records the flight's pause; the landing runs the game behind
    it, and closing it freezes the game under a Pause icon
    (`bug_overlay_in_flight_runs_behind`, `bug_overlay_in_flight_sticks_paused`);
  - the Link Cable modal opened during the flight does not freeze the game,
    which then runs behind it (`bug_link_modal_in_flight_runs_behind`);
  - Pause / Space / Period during the flight unpauses (Period frame-steps)
    instead of pausing (`bug_pause_in_flight_lost`).
  The fix: `playerPaused()` reads the pause button while a flight holds the
  game, and `takePlayerPause()` also takes the run state over from the
  flight; every snapshot and toggle takes it (`openReportModal`,
  `openRewindScrubber`, `openClipScrubber`, `startClipExport`, `togglePause`,
  netplay's `netFrozeGame`), and Period asks `playerPaused()`. The model
  follows it; the invariant holds over every reachable state again
  (`inv_reachable`, `pause_tap_flips`), and the traces are
  `regress_overlay_in_flight_runs_behind`,
  `regress_overlay_in_flight_sticks_paused`,
  `regress_link_modal_in_flight_runs_behind`, `regress_pause_in_flight_lost`.
  Tests in `web/tests/run-pause.test.mjs`: "Report a Bug opened mid-flight
  keeps the game frozen, and closing it runs it (bug_overlay_in_flight_runs_behind,
  bug_overlay_in_flight_sticks_paused)", "Pause pressed mid-flight pauses, and
  the landing keeps it (bug_pause_in_flight_lost)", "Period mid-flight pauses
  rather than stepping the held game". The Link Cable case
  (`netplay.js`) has the model's regression only, no browser test.

The rest of this file is the original audit, as found at dd7ba741f.

---

Every item below is a `bug_*` theorem in `WebState/`: a concrete event trace from
the initial state, run through the model and checked by `decide`. Each trace was
then re-read against the JS for browser ordering (IndexedDB issue order, the
`frameStoreChain`, microtask vs task), and model-only orders were dropped. The
items marked *hand-checked* were also re-read by the coordinating session. Where
a file has a `fix`/`stepF` variant, the proposed fix is proved to close the bug
under every interleaving, not just on the one trace.

Line numbers are `web/index.js` unless marked. No JS was changed.

## High: saves and library data lost or cross-contaminated

1. **All games share one `rom.sav`, and switching games never clears it.**
   *Hand-checked.* `SavePersistence.bug_switch_writes_other_games_save`,
   `GameLifecycle.bug_stale_sav_inherited`.
   - Trace: play A (it saves), go home, tap B, which has no save on this
     device.
   - Why it happens: `launchRom` writes every ROM as `rom.<ext>` (4494), and
     `restoreSave` returns early when there is no `save:B` (5271). So B boots
     on A's battery RAM, including its RTC trailer.
   - Result: the next 5 s tick writes A's bytes to `save:B` and uploads them to
     Drive. Sibling games (Gold/Silver, Ruby/Sapphire) load each other's save.
   - Fix: `restoreSave` unlinks `rom.sav` when there is no stored save.

2. **The outgoing GB core flushes over the incoming game's save.** *Hand-checked.*
   `SavePersistence.bug_gb_init_flush_replaces_save`.
   - Why it happens: `initFromEmscripten` (src/dingbat_wasm.nim 1706) calls
     `stateGb.cartridge.mbc_save()` after `restoreSave` has written B's save to
     `rom.sav`.
   - When it triggers: A's GB cart RAM is dirty when you switch, for instance
     after any state load while paused.
   - Result: B boots on A's RAM, and the next tick makes that permanent,
     including on Drive.
   - Fix: drop that `mbc_save`, since JS has already persisted A.

3. **A Drive pull that lands during a load gets overwritten by the stale local
   save, and Drive loses the newer copy.**
   `SavePersistence.bug_pull_overwritten_by_stale_flush`,
   `GameLifecycle.bug_pull_mid_load_loses_remote_save`.
   - Why it happens: the pull checks `isRomLoaded` (3005) before
     `await driveDownload` (3007), not after it. Meanwhile the boot reads the old
     save, and the first tick writes it back.
   - Result: `flushSyncInner` then uploads that stale save over the other
     device's newer one.
   - Fix: re-check after the download; set `lastSaveSig` in `restoreSave`.

4. **Launching a game during a rollback link session writes the session's
   save into the new game.** `Netplay.bug_launch_during_rollback_corrupts_save`.
   - Why it happens: `loadRom` only tears down `if (netMode)` (7886), and
     `netMode` is false once rollback starts. On disconnect, `rbTeardown` runs
     `persistSave(rbrom, currentOriginalName)`, and by then that name belongs to
     the new game.
   - Fix: `if (netMode || rollbackMode)` at 7886, 11206 and 11227.

5. **Closing the tab during a rollback session loses that session's saves.**
   `Netplay.bug_pagehide_in_rollback_loses_progress`. It has the same guard as
   #4 and the same fix.

6. **Renaming a game and then renaming it back makes its Drive files flip
   names on every sync, and a save can be lost.**
   `DriveLibrary.bug_rename_undo_oscillates`, `bug_rename_undo_loses_save`,
   `bug_rename_into_retired_name`, root cause `bug_merge_not_idempotent`.
   - Why it happens: rename markers never retire. `renameGame` writes the new
     entry without `imp` (3283), and `imp` is the only thing that spends a
     marker. Renaming another game into a previously vacated name drops that
     game from the library and moves its save onto the wrong ROM.
   - Fix: `list.unshift({ name: newName, ts, imp: ts })`.

7. **A delete, import or rename made during an in-flight sync is undone.**
   `DriveLibrary.bug_delete_during_flush_resurrects` (and `_permanent`),
   `bug_delete_during_pull_resurrects`, `bug_import_during_pull_orphans`,
   `bug_rename_during_pull_orphans`.
   - Why it happens: `syncState.tomb/ren = lib.*` (2802, 3031) and
     `dbPut("recent", …)` (3048) assign a library that was merged before the
     awaits.
   - Result: a "Deleted from all your devices" game comes back, and no
     tombstone remains anywhere. On iOS, closing the file picker fires
     visibilitychange, which syncs mid-import.
   - Fix: re-merge with the current local state in the same synchronous
     segment as the assignment.

## Medium

8. **A second save of a key during that key's own upload never reaches Drive.**
   *Hand-checked.* `DriveSession.bug_redirty_dropped`.
   - Why it happens: `markUpload` is a no-op while the name is queued (2656),
     and the flush filters the name out after the upload (2799).
   - Fix: a `syncRemarked` set that keeps the name queued (proved with
     `fix_no_lost_upload`).
9. **Close during a switch, and double taps.**
   - **Close during a switch:** `GameLifecycle.bug_unload_race_writes_incoming_save`
     (critical when it hits, narrow window). Tapping the card's × while
     another game is loading writes the incoming save into the outgoing key.
   - **Double taps:** `bug_double_tap_boots_wrong_rom`,
     `bug_double_tap_resume_point_of_other_rom` and
     `bug_double_tap_overwrites_resume_point` (the same tile tapped twice
     replaces the real resume point).
   - **Page closed mid-switch:** `bug_pagehide_in_load_gap` and
     `SavePersistence.bug_switch_window_overwrites_save`.
   - Fix set, proved in `stepF`: a `loadGen` token checked after every await;
     name the game in the same segment as `initFromEmscripten`; unload detaches
     synchronously.
10. **A signed-out tab keeps syncing.** `DriveSession.bug_renewal_resurrects_token`,
    `bug_signed_out_tab_keeps_syncing`.
    - Why it happens: a renewal popup armed before "Sign out" grants a token
      afterwards, and nothing checks `connected`. The poll gates on
      `syncActive()`, not `driveLinked()`.
11. **One flush writes across two accounts.** `DriveSession.bug_flush_crosses_accounts`.
    Sign out and in as a different account during the first upload, and the
    old flush writes account 1's library and tombstones into account 2. Fix:
    a session epoch checked after each await.
12. **Space on the home screen unpauses the hidden game.** *Hand-checked.*
    `RunPause.bug_space_on_home_runs_game`. `shortcutKeyHandler` never checks
    `body.running`.
13. **Updating in one tab reloads another tab mid-game.**
    `ServiceWorker.bug_update_in_one_tab_reloads_the_other_midgame`. The
    `controllerchange` handler (79) reloads unconditionally.
14. **Clip export leaves the game running with the Resume icon showing.**
    `RunPause.bug_clip_export_drops_pause`. `startClipExport` sets
    `paused = false` (8471), and nothing restores it.
15. **Reset save is undone by a flush in its gap.** `SavePersistence.bug_reset_undone_by_flush`.
    Fix: detach before deleting.
16. **The service-worker install can cache a mix of two builds.**
    `ServiceWorker.bug_install_across_deploy_mixes_cache`. A deploy (or CDN
    lag) lands between asset fetches.

## Low

- **Resume and saves.** Resume over an unflushed in-game save:
  `SavePersistence.bug_resume_over_unflushed_save`,
  `GameLifecycle.bug_resume_restores_older_battery`. It compares against
  IndexedDB, not the live `rom.sav`. The quota retry re-puts an older save:
  `bug_quota_retry_writes_older_save`.
- **Remote and link pause** (`RunPause`): remote resume under the report modal
  or on home; link end keeps the Resume icon or unpauses on home; a link setup
  error thaws the game under the modal; `loadRom` under the report or Link
  modal. The netplay wake lock can leak (`bug_link_modal_wake_lock_leak`).
  **`index.js`'s own wake lock is proved correct.**
- **Drive lamp and renewal** (`DriveSession`): the spinner turns forever with
  no token and pending work (a gamepad-only player past one hour). One denied
  popup counts as two strikes.
- **Thumbnails** (`Thumbnails`):
  - During a switch, a tab switch files the old core's pixels as `frame:<new>`
    (`bug_switch_files_old_pixels_under_new_name`).
  - A delete racing a store, a pull or the batch leaves an orphan `frame:`
    record, which then blocks renaming to that name.
  - The batch overwrites a frame just pulled from Drive.
  - The menu can revoke a displayed URL.
- **Modals** (`Modals`):
  - A nested modal (the tombstone prompt over Settings) steals the single
    focus trap, so Settings loses Tab containment and focus return.
  - A second suspect-ROM drop orphans the first promise.
  - Escape during "Renaming…" swallows the rename's error.
- **Netplay** (`Netplay`):
  - A manual-code retry closes its own channel.
  - A cancelled dial's `onerror` marks the server down.
- **Service worker:** a force update serves a half-written cache.
- **Merge algebra:** the merge is non-commutative on a same-millisecond
  rename tie and non-associative on `imp` across a delete (both very low).

## Found by reading, not modelled

- `driveListAll` (2100) reads one page of 1000 files and ignores
  `nextPageToken`. *Hand-checked.* A large library (up to about 22 Drive files
  per game) can miss the `library` file, and then `writeDriveLibrary` creates a
  second one.
- Two devices syncing for the first time can each create a `library` file.
- `markDelete` during an in-flight upload of the same key: the delete is then
  "outranked" and dropped (2773-2779).

## What is proved to hold

Each file lists its theorems. The headline ones:

- **Thumbnails:** a tile never shows another game's picture; stale fetches
  paint nothing; object URLs are revoked at most once and never while on
  screen; nothing leaks.
- **Drive:** at most one sync job runs at a time; a failed upload stays queued;
  renewal attempts never outnumber user gestures (so the old offline microtask
  loop cannot recur); the lamp is not spinning when the queue is quiet.
  Tombstones are never invented, and the Drive lost-update race only delays a
  tombstone, never loses it. `renameGame`'s key move is atomic. The merge is
  commutative, idempotent and associative without rename markers.
- **Run/pause:** the wake lock is held iff running and visible, and a late
  grant is released.
- **Netplay:** at most one live signaling socket; the redial ladder is bounded
  and never faster than 1 s; every channel that loses the race is closed.
- **Service worker:** it never reloads without a click and shows the prompt at
  most once per page.
- **Modals:** the tombstone prompt settles exactly once on every exit path.

## Picking a game up on another device (2026-10-01, `WebState/Handoff`)

Models the hand-off shipped in 43b30d1c (main 11025707): the session as a
Drive file, the flush's hold-back of a session another device wrote unseen,
the pull's hand-off of the game held in memory (taken at home when fully
sent, else offered as Switch), `switchToHandoff`, and what the home screen
shows. Two devices, one game, one Drive; every await that matters is an
event boundary, and a Sync tapped while a job runs queues behind it.

**Proved** (the file's header lists every theorem):
- Matt's fourteen steps, for all four ways device 2 opens (never opened,
  reopened, tab open on the library, tab paused on an older moment), saving
  in game or not: device 2 shows and resumes device 1's moment on device
  1's save, then device 1 shows and resumes device 2's. Also on the shipped
  code: the story itself has no race.
- Over every state: a tap never rolls the save back (a session is resumed
  only where it was taken with the stored save); Drive's session changes only
  when an upload lands, and an upload starts only from a read whose listing
  showed nothing this device had not seen (or Switch waived it); a pull lets
  the game in memory go only at home, unmoved, with nothing waiting to go up
  (fixed code), and then always does, landing every file as downloaded; a
  pull that lands a file redraws the closed hero from what is stored.
- Convergence over 686 histories (three moves, alternating devices, out of:
  sync stopped mid-pull, play, play and save, Close, Sync, page killed and
  reopened, Switch): syncing each device in turn, both resume the same
  moment on the same save as Drive's copy, each hero showing where a tap
  goes.

**Found and fixed.** Each trace is a `bug_*` theorem on the shipped code and
a `regress_*` theorem on the fixed one, and each has a test in
`web/tests/handoff.test.mjs` that fails on 11025707:

| # | Severity | What happened | Fix |
|---|---|---|---|
| H1 | Medium | **Switch tapped while this device's own session was uploading** (the offer schedules that upload 2 s later; a GBA session is ~500 KB, so a tap a few seconds in lands mid-upload). The upload's completion took the key off the queue, so the chosen copy never went up: Drive kept the moment the player had just turned down, the other device picked *that* up, and the two diverged until a later Sync. | `switchToHandoff` marks what it re-queues as saved again (`syncRemarked`). |
| H2 | Medium | **Close tapped while a Sync downloaded the other device's session.** The pull went on as if the game were still held: it offered Switch (a no-op by then) and marked the session seen, so the files pass skipped it. The closed device resumed its own older moment until the other device uploaded again. No conflict needed: one player, paused on device 1, played on device 2, came back, tapped Sync then Close. | The hand-off section acts only on a game still held by the player's leave (`stillHeld`); a game closed meanwhile is left to the files pass. |
| H3 | Low | **Resume tapped during `heldGameIsSent`'s read** (an IndexedDB get, a few ms). The pull had decided "at home" before it, and unloaded the game the player had just gone back into. | `heldGameIsSent` asks after its read; the caller checks `running` and `loadGen` in the run that takes the hand-off. |

**Open, by design** (two devices made progress without syncing in between;
proved as traces so the behaviour is stated, not implied):
- `edge_concurrent_play_held_wins`: the device that syncs last while holding
  the game wins; the other's in-game save is gone everywhere.
- `edge_closed_copy_yields`: a save made just before the page was killed
  (queued, unsent) is overwritten by the boot pull when the other device
  saved and synced meanwhile.
- `edge_listing_race`: Drive has no compare-and-swap, so a flush can write
  over a session uploaded after its listing (both devices flushing within
  the same second).

Keeping the overwritten save aside (the 30-day `oldsave:` mechanism) would
make all three recoverable.

**Found by reading, fixed (2026-10-01):** a session file on Drive written
for an older generation of the game (a delete and re-import racing another
device's upload) was never marked seen, so the flush held this device's
session back on every pass and the lamp stayed on "Syncing…". The hold-back
now applies only when `fileGen(r0) >= gen`; regression test "a session from
a deleted generation of the game does not hold this one back" in
web/tests/handoff.test.mjs. The model has no generations, so this one is
guarded by the test alone.

**Parallel sync (2026-10-01), re-checked against the model, not re-modelled:**
the flush now sends up to `SYNC_PARALLEL` keys at once (`runPool`) and the
pull starts its downloads ahead (`downloadAhead`), still checking and
writing each file in listing order. Each key's flush segment touches only
that key's queue entry, `sigs`, `rmt` and delete stamp, and the model
already lets any event fall between a key's read, its upload and its
landing, so two keys in flight together reach no state one key at a time
could not. A prefetched download is read nearer its listing, which the
abstraction ("a pull reads a file's bytes at the listing") already assumes.
Two unit tests that pinned one-at-a-time order were restated as their end
state: a key saved again or deleted while the flush sends others is on
Drive with its newest bytes, or off it, after the next flush. The library
is no longer written when the merge leaves its text unchanged
(`libraryUnchanged`); `DriveLibrary`'s anchors were stale before this.

**Abstractions:** listed in the file's header. Bytes are opaque (compression
is invisible here), one game, both devices hold its ROM, loads are atomic.

## Re-audit at 03f88d6c (2026-10-05): SavePersistence, ServiceWorker, Netplay

The three models follow 03f88d6c again; SavePersistence follows the fix of its three new findings, 87eea59f (line numbers at that commit).

- **SavePersistence** now models the checkpoints (`takeCheckpoint`,
  `storeCheckpoint` and its guard, `addCheckpoint`'s epoch re-check, the
  moments sheet's forced resume), the hero's Resume that boots straight into
  the session (`loadRom`'s `opts.resume`), the session epochs, quota
  evictions that free checkpoints before ROMs, the Saves panel's Reset as its
  own path, and the Drive pull's delete-queue check. `provenance`,
  `resume_only_on_sig_match` (the boot-time resume included) and
  `persist_marks_upload` still hold over every interleaving.
  `open_pull_resurrects_reset_save` was already fixed by 6dd57564 (the pull
  checks the delete queue); it is now `regress_pull_resurrects_reset_save`.
  On the fixed code it also proves, for every reachable state, that the
  stored session is the newest snapshot ever stored for its game and was
  taken since the session was last deleted (`session_newest_and_current`,
  which C2 broke), and, for every state, that a quota retry writes only if
  nothing took a later number for the save (`retry_gives_way`, with
  `persistCall_seq_mono` and the `*_takes_number` lemmas; C1) and that a pull skips a
  save whose delete is queued, both Resets queue it as they wipe, and the
  queue is not sent mid-pull (`pull_respects_queue`, `reset_queues_at_once`,
  `flush_waits_for_pulls`; C3). `NoResurrect` is not claimed for every
  state: the model stamps a pull's bytes when it starts, so a pull begun
  after a Drive flush sent a Delete's queued delete looks like a
  resurrection when it lands, where in the JS it is another device's newer
  save.
- **ServiceWorker** adds the update a save state from a newer build asks for
  (`updateForNewerState`: `applyUpdate` with the game loaded and no
  confirm). `no_forced_midgame` and `no_reload_without_a_click` still hold,
  with that load counted as the player's ask; another tab's game is still
  never reloaded (`newer_state_update_reloads_only_its_tab`). The new
  `ASSETS` (clipmux.js, flap.png, ckptworker.js) change nothing modelled.
- **Netplay**: citations only. `loadRom`'s resume runs in the solo commit,
  after any session has ended, and keeps the solo core on its own game.

**New, all Low (narrow windows), all fixed in 87eea59f.** Each was reproduced against the real `web/index.js` (C1's Import variant from the model only), and each `bug_*` below is now a `regress_*` theorem whose trace ends safely:

| # | What happened | Trace (now `regress_*`) | Fix (87eea59f) | Tests |
|---|---|---|---|---|
| C1 | **A quota retry after a checkpoint eviction puts the old save back.** `dbPutRoomy` frees other games' checkpoints first and retries at once, but asks `superseded()` only `if (freed && …)`, and `freed` counts ROMs. A newer persist, a Reset, a Delete or an Import landing while the checkpoints are deleted is overwritten; after Reset or Import the reboot boots on the old save, after Delete the deleted save is back and queued for Drive. | `SavePersistence.bug_ckpt_evict_retry_writes_older_save`, `bug_ckpt_evict_retry_undoes_reset`, `bug_ckpt_evict_retry_resurrects_deleted_save`, `bug_ckpt_evict_retry_over_import` | `retried`, set in the `catch` before either eviction, replaces `freed` in the `superseded()` check. | web/tests/ckpt-evict.test.mjs |
| C2 | **A checkpoint's session lands over a newer one, or after a Reset.** `storeCheckpoint` checks `sessionSnapTs`/the epoch, then (battery not yet stored) `await persistSave`, then puts the session without checking again. Main Menu, a hide, a close or a switch in that await is replaced by the older moment; a Reset or Delete gets the pre-reset session back (carrying the wiped battery's signature; `addCheckpoint` re-checks, so the moment itself stays out). | `bug_ckpt_store_over_newer_session`, `bug_ckpt_store_undoes_session_reset` | `stale()` (ts, epoch, `sessionHeldFor`) checked at entry and again right after `await persistSave`. | web/tests/ckpt-store.test.mjs |
| C3 | **The Saves panel's Reset is undone by a pull landing in it.** `resetCurrentSaveFile` detaches and deletes, but queues its Drive deletes (`markDelete`) only after its awaits; a pull that started downloading the save before the game was tapped passes all three of its checks (not loaded, not loading, not queued), writes it back, and the reboot boots on it. `resetGameAction` queues first and is safe (`reset_game_action_holds_off_pull`). | `bug_file_reset_undone_by_pull` | The three `markDelete`s run right after `retireSavePuts`, before the first await. | web/tests/reset-pull.test.mjs |

## Re-audit at 03f88d6c (2026-10-05): `Handoff` and `Thumbnails`

**Handoff.** The crash checkpoints (6ee01e88..096edd3e) made a second writer
of the session: while a game runs, every 60 s of play `takeCheckpoint`
copies the moment and `storeCheckpoint` writes it from the worker's
callback, giving way only to a newer snapshot or a delete (`sessionSnapTs`,
the session epoch), asked once, before its `await persistSave`. The model
now has the checkpoint segment by segment, `sessionUnsent`, the
`ckptInFlight` gate in `persistAutoState`, the `playing` mark and
`noteCrashedRuns`' re-queue at boot. Every earlier theorem still holds on
the code at 03f88d6c (`Code.fixed`), including both convergence checks
over the first audit's moves. Two new counterexamples, both open:

| # | Severity | What happens | Proposed fix |
|---|---|---|---|
| H4 | Medium | **Switch tapped while a checkpoint packs** (`bug_checkpoint_after_switch`). `takeHandoff` moves neither `sessionSnapTs` nor the epoch, so the checkpoint, still "the newest", lands after the hand-off and writes the turned-down moment over the chosen session; Switch's own re-send (the key queued again, its `sigs` forgotten) then sends it to Drive. Both devices resume the moment the player turned down. Needs the tap within the pack (tens to hundreds of ms after a checkpoint, once per minute of play). | `takeHandoff` moves the session epoch (`sessionEpochs.set(game, sessionEpoch(game) + 1)`, as `deleteKeys` does) before it writes; with H5's re-check, which catches a checkpoint already past its first check. |
| H5 | Low | **Main Menu (or a hide, or Close) while a checkpoint awaits `persistSave`** (`bug_checkpoint_over_main_menu`). The checkpoint asked before that await and writes its older moment over the snapshot just taken; the game, unmoved, never takes the newer one again, so that moment goes to Drive, the other device and the next Resume. The lost play is what ran between the checkpoint and the tap (well under a second), and only when the game had saved in game within about a second before the checkpoint. | `storeCheckpoint` asks again (`sessionSnapTs`, epoch, `sessionHeldFor`) after `await persistSave`, right before its session put. |

`Code.proposed` is the code with both fixes: the two traces end safely
(`proposed_*`), and with a checkpoint move added to the convergence check
(1024 histories) it converges where 03f88d6c does not
(`proposed_converges_*`, `fixed_diverges_with_checkpoints`).

**Thumbnails.** Re-modelled from its stamp (43e81209). Since 43b30d1c the
hide stores only a changed screen, now its own event; `deleteGameEverywhere`
queues its Drive deletes before its wipe and the pull skips a file whose
delete is queued (6dd57564, which the model had not followed).
- No longer reachable, now `regress_*`: a delete racing the frame chain
  (Delete starts from home, where the game is paused on the screen Main Menu
  stored, so a hide during the unload stores nothing), and a delete racing a
  pull's frame download.
- Still open: the batch racing a pull's tombstone delete
  (`bug_thumbs_resurrects_frame`), the batch overwriting a pulled frame,
  the menu revoking a displayed URL.
- New, low: **a pull racing a rename** (`bug_pull_after_rename_orphans_frame`).
  The pull's write segment asks about the delete queue and the game in
  memory, not a rename, so a frame downloading while its game is renamed
  lands under the old name: an orphan that makes a later rename to that name
  fail. The same window writes a save or a session under the old name
  (`DriveLibrary`'s, not modelled here). Fix: the model's fix (2), a
  synchronous set of names a delete or rename has retired, checked in the
  pull's write segment.
