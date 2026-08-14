# Manual verification list

Things that shipped with unit-test coverage but still need a hands-on check
against the real world (live Google account, deployed https build, multiple
devices) that the harnesses can't provide. Check an item off — or just delete
it — once it's been seen working; add a dated entry whenever something lands
that needs the same treatment.

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
- [ ] **Rename while playing elsewhere.** Rename on A while B is mid-game on
      the same title. B's pull should defer (game keeps running under the old
      name) and complete the migration on the first sync after the game is
      closed.

## Drive sync: original ship (2026-07-23, `a023c79`) — still open

- [ ] **Two-device delete/tombstone round-trip** against a live account:
      delete on A, confirm B shows the "removed on another device" modal and
      that Restore really does re-upload. Unit-tested since day one, never
      seen live.
