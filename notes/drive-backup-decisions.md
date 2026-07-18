# Google Drive backup — behavior decisions & pending tweaks

State as of 2026-07-18. The prototype (commits 2ea1561, 2e42e85) and the unit
test suite (f507a87, `web/tests/`, run with `node --test web/tests/*.test.mjs`)
are on main. The 42 tests exercise the real `web/index.js` in a node:vm harness
(fake DOM / fake IndexedDB / mocked Drive endpoints) — they pin the behaviors
below, so any tweak that changes a row should update the matching test.

## Current behavior (verified by tests)

| # | Scenario | Current behavior | Flag |
|---|----------|------------------|------|
| 1 | Fresh device, wants to restore from Drive | Unreachable: the only Drive UI entry is the "Manage ROMs and Saves" link, hidden while the recents grid is empty. Must load a ROM first. | FIX: breaks the device-switch story. Always show the link, or add a home-screen "Restore from Drive" affordance when a client ID is configured |
| 1b | Signed in, Drive empty | "Nothing is backed up on Drive yet."; restoring updates the grid live | ok |
| 2 | Save name exists both sides | Last writer wins both directions (backup PATCHes Drive, restore overwrites local behind "Overwrite?" showing Drive's date). No timestamps compared, no merge | consider: warn when overwriting a newer target |
| 2b | Same filename, different game/bytes | ROM identity = name + byte size; same size ⇒ assumed identical, never re-synced. GBA ROMs cluster at 4/8/16/32 MB | consider: content hash in Drive appProperties |
| 3 | Import .sav for a Drive-backed game | Local save + running game update immediately (reload); Drive only updates on next manual Back up | ok (manual-backup model) |
| 4 | Imported .sav name ≠ ROM name | Save re-keyed to the loaded ROM's full name; mismatch adds an extra confirm; original filename discarded | ok |
| 4b | Other .sav ingress | None: home-screen drop rejects .sav/.state ("Unsupported file") | maybe: drop-to-import while playing |
| 4c | Save states | Same keying (state:<rom name>, single slot). Export = <rom>.state. Imported .state applies to the core but is NOT persisted to the slot | decide: persist on import? |
| 5 | Delete locally, then Back up | Deletions never propagate; Drive keeps files forever; Restore resurrects deleted data | consider: "Delete from Drive" in restore list |
| 6 | ROM evicted by 20-game cap | Local rom:/art: dropped, saves kept; Drive copy remains and Restore brings it back | ok (feature) |
| 7 | Interrupted large-ROM upload | Can leave 0-byte rom: on Drive -> dead grid tile on restore; next backup self-heals | fix: skip size-0 rom downloads + uploads-list leftovers |
| 8 | Restore while game running | Blocked by disabled "In use" button — UI-only; gdriveRestoreGame itself has no guard | fix: one-line guard |
| 9 | X.gb vs X.gbc | No key collision (full-filename keys). Both export as X.sav (filename ambiguity only) | ok |
| 10 | Hostile ROM names (colons, quotes, "-p2") | Safe: client-side exact-name matching, prefix parsing can't misfire | ok |

## Storage-surfacing audit

Per-game data (ROM, art, battery save, P2 save, state, recency) is fully
visible + deletable via the two modals. Not surfaced as manageable data:

- BIOS blobs (`bios:gba`/`bios:gbc`) — visible/removable in Settings only
- Seven small settings records (system, audio, video, colorCorrect,
  keybindings, large-controls) — no "reset all settings"
- Service-worker asset cache — inflates the whole-origin "X MB used" hint
  (`navigator.storage.estimate()`) next to the library
- localStorage crumbs: `dingbat_last_update_check`, dev-only `gdrive_client_id`

Drive backup covers saves/states/ROMs, not art (restored games lose box art),
BIOS, or settings.

## Suggested tweak order

1. Fresh-device reachability (the point of the feature)
2. Running-game guard + 0-byte rom guards (trivial)
3. Delete-propagation ("Delete from Drive") + newer-target warning
4. Content-hash ROM identity (most invasive, most correct)
