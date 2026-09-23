# Findings: web frontend state machines (models against dd7ba741f)

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
