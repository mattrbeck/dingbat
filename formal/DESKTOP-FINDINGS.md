# Findings: native desktop frontend (models against a2e038f82)

Five models in `DesktopState/` cover `src/dingbat.nim` and the ImGui widgets
in `src/dingbat/frontend/`, plus the core procs they call (battery-save
writers, save-state files, config, netlink). Line numbers are `src/dingbat.nim`
at a2e038f82 unless another file is named.

## Status after the fix round (2026-09-24)

Every High and Medium item is fixed. Most fixes have a test in one of five
new headless binaries, `tests/desktop_{input,settings,netlink,persist,lifecycle}_test.nim`
(run in CI, `nimble test_desktop`), each seen failing on the code before the
fix. Each model's fixed step was brought in line with what shipped, its
`regress_*` theorems re-proved, and every `bug_*` trace kept as the record of
the old code. Every row was also driven in the real app (below).

| # | Fixed in | Test |
|---|---|---|
| 1 | 91b1d741b, d13648556: a second window on a game another window has open is refused (OS locks, released when a window dies); e30b49f75: `save_config` writes only the keys this window changed | persist, settings |
| 2 | bd73cb6f6: slots named `<rom>-<identity>[.slotN].state`; the old name is read if it names this cart, never written | persist |
| 3 | 68fee8481, f813581a0 | GUI |
| 4 | 33eaa6d62: both cores catch the write error, retry, and a modal says so once | persist |
| 5 | c8c49151b, e356fe25a: the new core is built and checked before the old one is touched; a `.gb` too short for a header or an empty `.gba` is refused, a short `.gb` is padded with $FF as a cart bus reads | lifecycle |
| 6, 12 | 216e9a4d3: every release applies before any filter; shortcuts fire on the press, repeats ignored | input |
| 7 | 19eba0ba8 (`finish_link` refuses without a GBA core), ef20fc3a7 (`load_rom` ends the link) | netlink; GUI |
| 8 | 7ecfdab69 | netlink |
| 9 | ef20fc3a7 | GUI |
| 10 | 2902c8f39 (one gate in `load_state_slot`), fca2b4f2b (window's Load greyed) | GUI |
| 11 | 7ecfdab69, 19eba0ba8: a linked frame hands back to the loop after 8 ms; CLOCK carries a paused bit (older builds ignore it) | netlink |
| 13 | c89f94be0 | GUI |
| 14 | 72a8449f4 | settings |
| 15 | 216e9a4d3 | input |
| 16, 17 | 0dec4823b | settings |
| 18 | 650ab47af, 5eaac0759 (`.sav`, `.state`, `.cht`), e30b49f75 (config; a damaged file is moved to `dingbat.yml.bad`) | persist, settings |
| 19 | 1ceda7b87 | lifecycle |
| 20 | 7ecfdab69, 19eba0ba8, ef20fc3a7 | netlink |
| 21 | 19eba0ba8 | netlink |
| 22 | 2c7142cc8 | GUI |
| 23 | e30b49f75 | settings |

Lows fixed: held input merged per source and the fast-forward trigger
(216e9a4d3); rewind across a state load (421d78ef7); Quick Save mid-frame
(29c71dd3f) and dropped by a switch (489bc035f); Reset after Recent > Clear
(489bc035f); zip identity (46db6439f); extensionless paths (2a30130b8); every
Link Low listed below (19eba0ba8, 2902c8f39); the file dialog opening the BIOS
(03a7f027e); Reset to Defaults, frame size, Speed mode on GB (032f85e00);
fullscreen remembered where the OS restores windows (4f5f317b5: on macOS only
when "Close windows when quitting an application" is off, as AppKit apps do;
always on Windows and Linux); the Settings X asks before discarding edits
(c9a6b73b4).

Behaviour that changed on purpose: Cmd/Ctrl shortcuts fire on press, not
release; F9, F12 and the channel keys no longer repeat; `--hle`, `--run-bios`,
`--skip-bios` and a BIOS argument apply to that run only; a Game Boy file
shorter than a cartridge or not a whole number of banks reads $FF past its
end (the majority of emulators, and what rgbfix pads with) instead of
crashing, desktop and web; battery writes are fsync'd (about 0.3 ms per
128 KB write on this Mac, not measured on Windows); two windows can link on
one machine only with different games or a renamed copy of the ROM.

**Driven in the real app** (2026-09-24, a `-d:gui_driver` build: hidden
window, injected keys/mouse/drops, whole-window screenshots, scratch HOME).
Each scenario was also run on main plus the driver as a control where the
old code had the bug:

| # | What was done | Fixed build | main |
|---|---|---|---|
| 6 | hold S (R), Cmd down, release S under Cmd, release Cmd | R released, no Quick Save | R stuck, slot 0 written |
| 12 | hold Right, Cmd+L with no quick save (modal), release Right | Right released | Right stuck |
| 13 | start a key capture in Settings, close with X, press Z | game gets A | Z eaten |
| 5 | drop a 0-byte `.gb` | "Open ROM" notice, game keeps running | IndexDefect, app dies |
| 3 | Quick Save, Save States window open, switch game | grid shows the new game's slots | grid keeps the old game's |
| 4 | ROM folder read-only, game writes its save at boot | "Save file" notice, app keeps running | IOError, app dies |
| 22 | 1000 key taps with the menu hidden, then click File | menu opens in 2 frames | not open after 10 frames |
| 10 | two windows linked: menus | Frame Advance, 2x, Fast Forward, Quick Load greyed | — |
| 11 | pause one linked window 37 s | other window draws and answers, "The other player has paused.", link kept, both resume | — |
| 20 | Disconnect; Cmd+Q while linked | peer shows "Link ended" at once | — |
| 7, 9 | drop another ROM into a linked window | both sides end the link | — |
| low | close and reopen Link Cable right after a link | re-paired in ~3 s | — |
| 1 | second window on the same file / via a symlinked folder / a same-named copy elsewhere / a renamed copy / after `kill -9` of the first | refused, refused, refused, opens, opens | — |
| 14 | bind Up to Keypad 8, restart | still bound, game gets Up | — |
| 15, 16 | bind F12; BIOS tab with no BIOS | refused; real-BIOS modes greyed | — |
| 18 | garbage `dingbat.yml` | notice, file kept as `dingbat.yml.bad` | — |
| 5 | drop 16 KiB, 8 KiB, 16 KiB+1 `.gb`; a 256-byte one; the 56-byte `inputrec.gba` | play; refused with notice; plays | — |
| low | saved fullscreen, macOS switch unset (this Mac); Settings X after an edit | starts windowed; asks, Discard drops the edit | — |

Not driven: going fullscreen (it would take over the screen) and the
macOS "restore windows" path (a system setting), pads (no device), Windows
and Linux.

**Found while driving, not in the audit:** on main, Link's Awakening died
about 30 s after boot with rewind on (the default): a GB APU channel
deadline behind the scheduler made `apu_arm_state_events` raise
RangeDefect in every rewind snapshot (the web, built without range checks,
kept running with its noise channel frozen). Since 25c4cc4f0; fixed in
fc686286c (the noise divisor stage settles before the frame rebase), guarded
by `tests/gbapu_rebase_test.nim`.

**Round 3, the items rounds 1-2 left open:**

| Item | Fixed in | Test | Driven |
|---|---|---|---|
| `--listen` froze the app up to 120 s before the loop; the HELLO handshake (30 s) and a manual Join's connect blocked the loop | 0c5a726c2: all run in the loop with wall-clock deadlines, the status line and Cancel; the core stays on its own cable until the peer's HELLO | netlink (a silent peer, a SYN-dropping listener, two cables pairing in one thread) | `--listen` opens at once hosting; `--connect` pairs; a silent peer: menus work, 30.0 s later "Handshake failed", BYE sent |
| Link Cable window too short for its hint | 74b99475b: minimum height = last frame's content | scratch ImGui run | fits, no scrollbar |
| `.cgb`/`.sgb` went to the GBA core (web: "Unsupported file") | 1f1e69ec3, f3f0377cf: one extension list; not `.dmg` (a macOS disk image) | lifecycle, web romcheck | both open in the GB core |
| notices ignored Return/Escape | 9d141938e: Return/Enter/Escape = OK; "Discard changes?"/"Reset settings?": Escape = Cancel, Return does nothing; a key pressed as a notice appears is ignored | input, modal (needs imguin: `nimble test_desktop`, not CI) | Return and Escape close the State notice; the game saw neither |
| green-button fullscreen untracked; a GB game left a GBA-shaped window after fullscreen | 3e802556e | settings | not driven (would take over the screen) |

Left alone, with reasons: saves an older build wrote for an extensionless
ROM (`<parent>.sav`) are not migrated, because that name is also the save of
a different game (`/g/v1.2/zelda` wrote `/g/v1.sav`, which is `/g/v1.gba`'s)
and a `.sav` carries no ROM identity. GBA state identity still hashes the
first 1 MB: a whole-ROM identity would make every new state of a large cart
unreadable to older builds (stale web tabs, Drive-synced devices), the
version churn avoided so far; a compatible route is an optional trailer
carrying the whole-ROM hash, if wanted. Same stem sharing `.sav` stays (every
emulator does it; two windows on the same stem are now refused). A hostname
typed into Join still resolves by a blocking DNS lookup.

| File | Machine |
|---|---|
| `GameLifecycle` | load_rom and its callers (CLI, drop, Open, Recent, Reset), zip cache, flush on switch/quit, what leaks between games |
| `RunInput` | pause, frame advance, rewind, fast forward / 2x, keyboard + pad held state, ImGui capture, the skipped-ImGui backlog |
| `SavePersistence` | .sav / .state / .cht / config writes, Save States window, two processes sharing one file system, torn writes |
| `NetLink` | Link Cable setup, auto-pair race, two processes on one socket, pause/quit/BYE, game switch while linked |
| `Settings` | config editor, key/pad capture, BIOS selection, file dialog, load/save_config round trip, live vs next-load settings |

## How the desktop differs, and what that did to the method

The desktop app is one synchronous loop: no awaits, no IndexedDB, no Drive,
no service worker; audio is `SDL_QueueAudio`, so there is no callback thread.
Each iteration runs emulate → pending states → `handle_input` (all queued SDL
events) → rumble/link service → present (`render_imgui`, where menu clicks and
widget callbacks, including `load_rom`, run). The models make that phase order
a program counter: SDL events land only in the input phase, ImGui clicks only
in the present phase and only when ImGui is not skipped. That removes almost
every interleaving the web audit lived on. What replaces it:

- **Set in one phase, consumed in another.** A flag checked when a key is
  pressed but not when it is serviced, a link completing between the two.
- **Uncaught exceptions are crashes.** Nim exceptions not caught propagate out
  of `main()`; the models give that its own terminal state and record what is
  lost on disk.
- **Blocking calls freeze the whole app.** A socket wait in `step_frame` or
  `establish_netlink` stops event handling and drawing.
- **The file system is shared state between processes.** The Link Cable's
  zero-config mode pairs two dingbat windows on one machine; they share every
  file the app writes.
- **Held input has several sources** (keyboard, several pads, the stick, the
  trigger) and several filters that can eat one half of a press.
- **The environment is nondeterministic** at each place the code touches it:
  a write can fail to open, stop part-way or be cut by a power loss; a peer
  can send anything or vanish.

## High: data lost or the app dies

1. **Two windows on the same ROM file overwrite each other's save**
   (`SavePersistence.bug_two_windows_lost_update`, `bug_two_windows_config_lost`).
   Both read `<rom>.sav` at boot and each rewrites the whole file every frame
   its battery RAM is dirty, so one window's in-game save is replaced by the
   other's older image. Save-state slots, `.cht` and `dingbat.yml` are shared
   the same way; each `load_rom` writes its stale copy of the config over the
   other's. Steps: two windows, same `.gba` (trading with yourself, the flow
   the Link Cable is for), save in A, later save in B: A's progress is gone.
   The desktop's nearest match to the web's shared `rom.sav`.
   Fix (proved, `fi_ok`/`cfg_ok`): an advisory lock on the `.sav` path in
   `load_rom`; a second window runs on `<name>-p2.sav` (seeded from the main
   file, like the web's 2P mode) and says so in the title; `save_config`
   re-reads and writes only the keys its caller changed.

2. **Two ROMs with the same file name share save-state slots**
   (`SavePersistence.bug_same_name_state_overwritten`,
   `GameLifecycle.bug_state_slot_shared_by_file_name`). `state_file_path`
   (823-831) uses only `extractFilename()`. Loading the wrong one is refused
   (`srkWrongRom`), but saving silently replaces the other game's slot.
   Same for two zips whose inner entries share a name. Fix (proved,
   `st_ok`): `<name>-<rom identity>[.slotN].state`, reading the old name as
   a fallback only.

3. **The Save States window keeps the previous game's grid after a ROM
   switch, and Save/Delete act on slots it is not showing**
   (`SavePersistence.bug_window_delete_hidden_slot`,
   `GameLifecycle.bug_save_states_grid_stale_delete`). `load_rom` never marks
   the widget stale. Steps: window open, switch game via Recent or a drop,
   Delete slot 2: the new game's slot 2 goes, unseen. Fix: `mark_stale()` and
   clear the notice in `load_rom`.

4. **A failed GBA battery write kills the app**
   (`SavePersistence.bug_gba_save_error_crashes`,
   `GameLifecycle.bug_readonly_gba_crashes`, confirmed headless).
   `write_save` (storage.nim 90-95) has no `try`; the IOError leaves
   `run_until_frame` and `main`. Read-only ROM folder, read-only `.sav`, full
   disk, or on Windows a sync client locking the file. GB's `mbc_save`
   catches it but only prints to stdout, so the player never learns nothing
   is being saved. Fix: `try` like `mbc_save`, and a visible notice for both.

5. **A short or empty `.gb` kills the app**
   (`GameLifecycle.bug_empty_gb_crashes`, confirmed headless: IndexDefect at
   mbc.nim 130). `load_rom` has no `try` and assigns the new core before it
   is known to be good. Fix: build the core into locals inside `try`, assign
   only after `post_init`; on failure keep the old game and show a notice.

6. **Releasing a game key while Cmd/Ctrl is down sticks the button, and can
   fire a shortcut** (`RunInput.bug_cmd_held_release_sticks_button`,
   `bug_cmd_held_release_fires_quick_save`,
   `bug_cmd_tab_away_sticks_and_quick_saves`). The modifier branch
   (1644-1667) acts on key release and has no case for game keys. Hold S (R
   button by default), touch Cmd, let go of S: a Quick Save overwrites slot 0
   and R stays held. Cmd+Tab away while holding keys does the same to every
   held key (SDL releases them with Cmd still down; read from SDL 2.0.22's
   source, not run). Fix: apply every release of a bound key (and backquote)
   before any filter; fire shortcuts on press, ignoring repeats.

7. **Link setup still running after a switch to a GB game crashes when the
   peer connects** (`NetLink.bug_gb_switch_during_setup_crashes`,
   `GameLifecycle.bug_link_setup_crash_after_gb_switch`). `finish_link`
   hands `app.gba_emu = nil` to `new_net_core` (netcore.nim 910). Steps: open
   Link Cable (it starts hosting), drop a `.gb`, a second window opens Link
   Cable. Fix: `load_rom` tears down the link and any setup (fix set below);
   `finish_link` refuses unless `link_ready()`.

8. **Any peer that completes a handshake can crash the app with one bad
   frame** (read and confirmed, not modelled). `poll_socket` (netlink.nim
   111) calls `core.feed`, which raises `LinkProtoError`; the main loop
   catches only `NetLinkError`. Fix: convert in `poll_socket`, as the
   handshake path already does (netlink.nim 167).

## Medium

9. **Loading another game while linked leaves the link on the old core**
   (`NetLink.bug_reset_while_linked_drives_hidden_core`,
   `bug_gb_switch_keeps_dead_link`, and the same in GameLifecycle). The
   linked branch steps `app.netlink`, whose core is the old one: the picture
   freezes, the old game plays on unseen (its audio comes out), and on a
   Reset its writes to the same `.sav` race the new core's. After a switch to
   GB the link is never stepped or closed, the peer stalls 30 s, and the only
   Disconnect button is in a window whose menu item is disabled for GB.

10. **Save states load while linked** (`NetLink.bug_menu_quick_load_while_linked`,
    `bug_slot_load_while_linked`, `SavePersistence.bug_window_load_while_linked`,
    `bug_quick_load_races_link`). Only Ctrl+L is gated (1658); File > Quick
    Load (1311) and the Save States window's Load (2274) are not, though the
    Link window says state loads are paused. Replaces the linked core
    mid-session and can wedge a transfer in flight. Also Ctrl+L released in
    the iteration the link completes (about 1 ms window).

11. **Pausing one side freezes the other player's whole window for 30 s,
    then drops the link** (`NetLink.bug_peer_pause_freezes_other_window`,
    `bug_peer_pause_ends_link`). The peer's `step_frame` blocks in `pump(1)`
    with no events or drawing; Quit and Disconnect do nothing. Anything that
    stops a loop does it (dragging the window on macOS). No desync. Fix
    (proved, `pstepF`): `step_frame` returns to the loop when stalled, keeps
    its deadline across calls, the paused side keeps pumping, and a "paused"
    bit in the CLOCK message suspends the peer's stall timer.

12. **Key releases are swallowed, so buttons and rewind stick**
    (`RunInput.bug_imgui_capture_swallows_release`,
    `bug_binding_capture_swallows_release`, `bug_rewind_sticks_after_cmd`).
    `WantCaptureKeyboard` (1640) and binding capture (1642) drop the release
    of a key the game saw pressed: hold Right, click a text field or hit an
    empty-slot Quick Load (the modal), let go: the character keeps walking.
    Rewind stuck on drains history, then freezes the game under
    "<< Rewinding". Same fix as 6.

13. **A key capture outlives the Settings window**
    (`Settings.bug_close_midcapture_eats_keys`, `..._eats_quit`,
    `..._collapse_...`, `..._pad`; `RunInput.bug_closed_settings_keeps_capturing_keys`).
    Close or collapse Settings mid-capture and the next (up to ten) key
    releases, Cmd+Q included, go to the hidden widget. Fix needs both halves
    (`capture_fix_needs_both_halves`): gate on `app.ce.open` at 1642/1732,
    and clear `visible` at the top of `ConfigEditor.render`.

14. **Keypad and non-US key bindings are lost on restart, leaving the input
    with no key** (`Settings.bug_numpad_binding_lost_on_restart`, confirmed
    headless). `save_config` writes `  : up` for keys not in KEYCODE_TABLE
    (config.nim 453); `parse_config` drops it. Fix: write unnamed codes
    numerically; `fixed_roundtrip` proves load(save(cfg)) = cfg.

15. **Bindings are accepted that the game can never receive**
    (`Settings.bug_bound_modifier_never_presses`,
    `bug_bound_f12_never_reaches_game`). Ctrl/Cmd (the press carries its own
    modifier bit and takes the shortcut branch), F9, F12, backquote. The
    widget shows the binding. Fix: refuse them in `key_released`.

16. **"Real BIOS" or "Run BIOS intro" with no BIOS file hangs every GBA
    game** (`Settings.bug_real_bios_without_file`, `bug_run_bios_without_file`,
    confirmed headless). The help text says a BIOS is embedded; the stub has
    no SWI handler. Fix: fall back to HLE when the path is empty or missing,
    and disable those controls.

17. **One-off command-line flags become permanent**
    (`Settings.bug_cli_flag_persists`, `SavePersistence.bug_cli_flag_persisted`).
    `--hle`, `--hle-after-bios`, `--run-bios` and a BIOS argument are written
    into `cfg` (2164-2175) and saved by the next `load_rom`. `--skip-bios`
    cannot undo a persisted `--run-bios`. Fix: keep overrides in AppState.

18. **Torn writes** (`SavePersistence.bug_truncated_sav_accepted`,
    `bug_failed_quick_save_destroys_previous`, `Settings.bug_bad_file_overwritten`).
    Every writer truncates then writes. A power loss while a game saves
    leaves a short `.sav` that loads as valid; a full disk during Quick Save
    destroys the previous good state with no message; an unparseable
    `dingbat.yml` silently becomes defaults and the next save makes that
    permanent. Fix: one `write_file_atomic` (temp, fsync, rename) for `.sav`,
    `.state`, `.cht` and config; move a bad config aside.

19. **GBA battery is not flushed on switch or quit**
    (`GameLifecycle.bug_gba_switch_drops_dirty_battery`,
    `bug_gba_quit_drops_dirty_battery`, `bug_gba_paused_state_load_not_persisted`).
    `flush_gb_save` flushes GB only. Running, the loss is the last frame's
    writes. Paused, it needs no timing: pause, Quick Load, quit: the loaded
    state's battery never reaches disk (GB does write it).

20. **A peer lost mid-transfer leaves the game's link busy; quitting sends
    no BYE** (`NetLink.bug_lost_peer_leaves_transfer_busy`,
    `bug_quit_while_linked_sends_no_bye`). The BYE path completes a waiting
    exchange as a pulled cable; the error path does not. Nothing after the
    loop calls `teardown_netlink`, so every quit takes the peer's error path.

21. **Link retry timers count loop iterations, not time** (read, not
    modelled). About 100 connects a second instead of "~6/sec", and a manual
    Join gives up after about 0.3 s instead of "~5 s" (2012, 2026, 2029).

22. **The menu ignores clicks after long keyboard-only play**
    (`RunInput.Backlog.click_waits`, measured on imgui 1.92.4). Events queue
    in ImGui while `render_imgui` is skipped; n queued taps delay a click by
    2n frames (3000 taps ≈ 50 s at 120 Hz).

23. **An unwritable config folder crashes every ROM load** (read). No
    `save_config` call site catches its `writeFile`.

## Low

- Held input from several sources is not merged: a pad release drops a key
  the keyboard holds, pad 2 releases pad 1's button, pad 2's stick drift
  releases pad 1's direction, unplugging the last pad releases keyboard keys
  (`RunInput.bug_pad_release_drops_held_key` and neighbours).
- Fast forward: the trigger leaves both 2x and Fast Forward checked; holding
  Tab toggles on key repeat; releasing the trigger cancels a Tab-latched fast
  forward.
- Link gating is inconsistent (menu Fast Forward/2x/Frame Advance and the
  trigger are not gated). `lead_bounded` proves none of them desyncs, so the
  gating is for UX, not sync.
- Same name, different extension (`Tetris.gb`, `Tetris.gbc`) share `.sav`
  and `.cht` (`bug_battery_shared_by_stem`); every emulator does this.
- The zip cache is keyed by the path as typed and by the stdlib `hash`, so
  a relative and an absolute path give two saves; moving the zip orphans
  its save (`bug_zip_identity_split`).
- Reset does nothing after Recent > Clear (`bug_reset_after_clear_is_noop`).
- A Quick Save pressed in the same iteration as a load is dropped
  (`bug_quick_save_dropped_by_switch`).
- Rewind after a state load steps back into the replaced timeline
  (`bug_rewind_crosses_state_load`); the web clears the ring.
- A Quick Save queued just before the peer drops is written mid-frame
  (`bug_state_saved_mid_frame`).
- Link: a failed accept leaks the listener, which can freeze both auto-pair
  windows; a failed auto handshake leaves "Waiting to pair..." forever; the
  window keeps saying "Linked as" after a lost link; auto-pair probes the
  last typed host, not 127.0.0.1; a manual Host keeps listening after the
  window closes; TIME_WAIT blocks re-hosting on 47810 for about 31 s; the
  ROM file moved away crashes `finish_link`; `--connect host:x` crashes;
  the `link_auto_listen` comment about macOS SO_REUSEADDR is wrong
  (measured).
- The file dialog can open the BIOS as a ROM (`selected_idx` survives
  between dialogs); Reset to Defaults skips Audio interpolation and Speed
  mode; the window's X discards edits without asking; Speed mode on a GB
  game waits for the next load without saying so; frame size and
  fullscreen are not saved.
- GBA state identity hashes only the first 1 MB of the ROM, so a hack that
  differs past 1 MB accepts the original's states.
- Extensionless CLI ROM paths save to `<parent>.sav` or `./.sav`.

## Proved to hold for the code as it is

- A pending Quick Save/Load always applies to the game it was asked of;
  rewind never applies another game's snapshot (`GameLifecycle.pend_current`,
  `hist_current`).
- A failed lookup (missing file, zip with no ROM) changes nothing; unlinked
  Reset restarts the running game (`failed_lookup_keeps_game`,
  `reset_restarts`).
- A state is only applied from a whole file whose header names the loaded
  cart (`SavePersistence.loads_ok`); the refusal notice is always drawn
  (`notice_drawn`).
- Frame advance runs exactly one frame and only while paused; pause runs no
  frames; rewind never runs while linked; rumble stops while paused
  (`RunInput`).
- While linked, nothing the local user does can put the two clocks more
  than a frame apart (`NetLink.lead_bounded`); two auto-pairing windows
  never both host and never pair as the same unit (`race_inv`).
- The menus and the Settings window never overwrite each other's fields;
  the live core always agrees with `cfg` for colour, volume, frameskip and
  interpolation, Reset to Defaults included; the Cheats window always edits
  the running core (`Settings.liveOK_real`, `apply_menu_commute`,
  `cheatsOK_reachable`).

Each model also carries a fixed `step` with its invariants proved over every
interleaving, and a `regress_*` theorem per `bug_*`, so the fixes above are
designed, not guessed.

## Do the web findings apply?

| Web finding | Desktop |
|---|---|
| All games share one `rom.sav` | Not as such (`.sav` sits next to the ROM). Other forms: two windows on one file (1), same-name state slots (2), same stem (low) |
| Outgoing GB flush overwrites the incoming save | No: flushed to its own path before the new core exists |
| Drive pull / sync races, tombstones, renames, account switch | No Drive. The same lost-update shape is (1) |
| Launch or close during a rollback session | Different form: `load_rom` never ends the link (7, 9); quit sends no BYE (20) |
| Double taps, close mid-switch, load token | No: `load_rom` is synchronous |
| Paused core's dirty battery dropped on close | Yes, for GBA (19) |
| Thumbnails filed under the new game | Different form: the stale Save States grid (3) |
| Game keys acting outside the game view | Different form: filters eat releases (6, 12, 13) |
| Remote pause, wake lock, AudioContext | No such features; the missing pause propagation is (11) |
| Nested modal focus trap, prompt promises | No: ImGui keeps a popup stack. Nearest is (13) |
| Service-worker update flow | No service worker |

## Not verified

The audit itself ran nothing in the desktop app; the fix round drove it
afterwards (the status section above). Items marked "confirmed headless" were
checked against the real Nim procs in scratch programs; the ImGui backlog
against the real imgui; SO_REUSEADDR and TIME_WAIT with sockets on macOS. The
Cmd+Tab release order comes from reading SDL 2.0.22's source (the driven
check injects the events it describes, not a real app switch). Windows and
Linux behaviour is modelled from the code, not observed.
