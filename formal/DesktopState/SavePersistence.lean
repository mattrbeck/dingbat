-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models src/dingbat.nim: flush_saves load_rom current_rom_path cheat_file_path save_cheats load_cheats on_cheats_changed state_file_path save_state_slot load_state_slot delete_state_slot refresh_state_slots process_pending_state render_state_notice poll_battery_notice render_battery_notice render_imgui handle_input finish_link teardown_netlink main
-- @models src/dingbat/frontend/save_states_widget.nim: mark_stale render
-- @models src/dingbat/frontend/notice.nim: modal_key render_notice
-- @models src/dingbat/frontend/persist.nim: poll dismiss state_file_name legacy_state_file_name state_read_path state_delete_paths
-- @models src/dingbat/frontend/game_load.nim: flush_batteries extract_zip_rom
-- @models src/dingbat/frontend/game_lock.nim: files_key states_key try_lock claim_files claim_states abandon commit
-- @models src/dingbat/common/atomicfile.nim: write_file_atomic
-- @models src/dingbat/common/config.nim: load_config save_config
-- @models src/dingbat/common/serialize.nim: parse_state_payload read_state_payload write_state_file
-- @models src/dingbat/gba/storage.nim: write_save
-- @models src/dingbat/gba/gba.nim: new_storage handle_saves
-- @models src/dingbat/gb/gb.nim: mbc_save mbc_load handle_saves
-- @models src/dingbat/gba/savestate.nim: save_state load_state
-- @models src/dingbat/gb/savestate.nim: save_state load_state
-- @models src/dingbat/gb/mbc/mbc.nim: load_cartridge
-- @models src/dingbat/gba/netlink.nim: step_frame

/-
# Desktop: what the native app writes to disk for a game, and when

Written against a2e038f82 (branch lean-desktop-state). Line numbers are
`src/dingbat.nim` unless a file is named.

Everything the desktop persists for a game, and the frame-loop phases that
write or read it:

* **Battery save** `<rom dir>/<rom name minus extension>.sav` (gba.nim 1358
  `new_storage`, gb mbc.nim 156). The core reads it once, when it is built
  (`new_storage` 1377-1385, gb `mbc_load` 3247; both accept a file of any
  length and take `min(len, chip size)` bytes). A running core rewrites the
  whole file with `writeFile` from its `etSaves` event, once per emulated frame
  while the RAM is dirty: GBA `handle_saves` (gba.nim 1530) ->
  `storage.write_save` (storage.nim 90-95), which is **not** in a try; GB
  `handle_saves` (gb.nim 3494) -> `mbc_save` (3228-3246), which catches
  IOError/OSError, reports once and keeps the RAM dirty. `flush_gb_save`
  (477-481) calls `mbc_save` again from `load_rom` (702, the outgoing game) and
  after the main loop (2606). There is no GBA counterpart.
* **Save states** `config_dir/states/<rom file name>[.slotN].state`
  (`state_file_path` 823-831: the ROM's file name, not its folder or contents).
  `save_state_slot` (833-842) -> core `save_state` (gba savestate.nim 984-997,
  gb 1032-1047) -> `write_state_file` (serialize.nim 305-319, `writeFile`), all
  errors caught and turned into `false`. `load_state_slot` (844-853) -> core
  `load_state` -> `read_state_payload` (serialize.nim 409-416) ->
  `parse_state_payload` (358-392): refused as `srkNoFile`, `srkTruncated`,
  hash mismatch, or `srkWrongRom` when the header's ROM identity (a hash of
  the ROM file: the first 1 MB for GBA, savestate.nim 867; all of it for GB,
  943) differs from the loaded cart's. An applied state marks the battery RAM
  dirty (gba savestate.nim 665, gb 755).
* **Cheats** `<rom dir>/<rom name minus extension>.cht` (`cheat_file_path`
  777-781), read by `load_rom` (735), rewritten by `on_cheats_changed`
  (818-821) -> `save_cheats` (795-805), removed when the list is empty.
* **Config** `~/.config/dingbat/dingbat.yml`: `load_config` (config.nim
  415-425) once in `main` (2163), which then applies `--hle`,
  `--hle-after-bios`, a BIOS path argument and `--run-bios` to that same
  object (2164-2175); `save_config` (config.nim 445-491) writes the whole object
  from `load_rom` (761) and from every settings change (menu items 1304-1425,
  config_editor.nim 46, file_explorer.nim 82/123).

The main loop (`main`, 2426-2605) runs these phases in a fixed order:
emulate (a rewind pop 2432-2450, else one frame 2451-2478 and a rewind push
2479-2486), `process_pending_state` (2522-2523), `handle_input` (2546),
`update_link_auto`/`service_link_setup` (2548-2549), then, when a present is
due, `render_imgui` (2584), inside which the menu (1293-1470), the file
explorer (1473), the state notice (1476), the Save States window (1512) and
the Link Cable window (1514) run their clicks, in that order.

## Model

`pc` is the loop's program counter per process. An event is accepted only in
the phase where the code receives it: SDL keys and drops in `input`, a new
link in `link`, menu clicks in `menu`, Save States / Link window clicks in
`win` (after the window's `render` entry, `mDone`, has run its `on_open`
refresh). Anything else leaves the state unchanged.

There are **two processes** (`app false`, `app true`) sharing one file system:
the Link Cable window's zero-config mode pairs two dingbat processes on
127.0.0.1 (`link_auto_start` 1924, `service_link_setup` 1986), and nothing
stops both from loading the same ROM file (fixed: `lock`). Their events
interleave freely.

The environment chooses each write's outcome (`Io`): it succeeds, the open
fails (`denied`: a read-only folder or file), it fails part way (`full`: a
full disk; `writeFile` has already truncated the file), or the machine loses
power part way (`power`: the file is left truncated, every process stops).

A `Fix` selects the code: `real` is a2e038f82; `fixed` turns on every
proposed change at once. Each flag is one small Nim change:

| flag | change | closes | proved by |
|---|---|---|---|
| `linkGate` | `process_pending_state`, `on_load` and File > Quick Load refuse while `app.netlink != nil` | `bug_menu_quick_load_while_linked`, `bug_window_load_while_linked`, `bug_quick_load_races_link` | `loads_ok` |
| `staleView` | `load_rom` calls `app.save_states.mark_stale()` | `bug_window_shows_previous_games_slots`, `bug_window_delete_hidden_slot` | `fi_ok` (`ViewJ`, `blind = []`) |
| `identity` | `state_file_path` adds the ROM identity (`state_rom_identity`) to the name; the old name is only ever read, and only when its header names this cart | `bug_same_name_state_overwritten` | `st_ok` |
| `lock` | `load_rom` refuses a ROM whose `.sav`/`.cht` (same folder, same name minus extension) or save-state slots (same file name, same ROM identity) another live window holds: an OS lock per name (`frontend/game_lock.nim`), taken before the `.sav` is read and before anything of the running game goes, released when the process ends or after a switch to another game | `bug_two_windows_lost_update` | `fi_ok` (`Excl`, `BaseJ`, `clobbers = []`), `two_windows_distinct` |
| `catchIo` | `write_save` catches IOError/OSError like `mbc_save`; both record it (`save_error`) and the app shows it until a write lands (`batErr`) | `bug_gba_save_error_crashes`, `gb_save_error_unseen` | `clean_ok`, `regress_gba_save_error` |
| `flushGba` | `flush_gb_save` also flushes the GBA battery | `bug_gba_quit_drops_battery` | `clean_ok` |
| `atomic` | every `writeFile` of a persisted file goes through `write_file_atomic` (temp, fsync, rename over `path`); a failed Quick Save says the slot is unchanged | `bug_truncated_sav_accepted`, `bug_failed_quick_save_destroys_previous`, `failed_quick_save_silent` | `clean_ok`, `regress_failed_quick_save_says_so` |
| `cliOver` | CLI BIOS flags are kept out of `app.cfg`; `save_config` re-reads the file and writes only the keys its caller changed | `bug_cli_flag_persisted`, `bug_two_windows_config_lost` | `cfg_ok` |
| `rewindClear` | an applied state load clears `app.rewind` | `bug_rewind_crosses_state_load` | `rewind_ok` |
| `finishFrame` | `teardown_netlink` finishes a frame the link left torn (`run_until_frame`) before anything else runs; this machine's only torn frame is the NetLinkError one | `bug_state_saved_mid_frame` | `mid_ok` |

The real code keeps: a state is only ever applied from a whole file made for
the cart it goes into (`loads_ok`, any `Fix`), and the refusal notice is never
skipped (`notice_drawn`). Every load happens in phase 2 or in the window
phase, both after a completed frame, except after a link loss mid-frame
(`bug_state_saved_mid_frame`).

## Abstractions (and why they do not change the properties)

* A ROM is its folder, its name, its extension and its contents (`game`, which
  stands both for the cartridge and for its save-state ROM identity; distinct
  games are assumed to hash differently, so the model is exact for
  `srkWrongRom` except for the GBA 1 MB window noted in the report). A zip is
  its cache folder (`extract_zip_rom` 500-503 keys it by the zip's full path)
  and its inner entry's name, which is what `state_file_path` sees.
* Battery RAM is a `Bat`: the game that wrote it, a version stamp from a global
  clock, and whether it is whole. A core is its game, a timeline id (fresh at
  every boot and state load), its battery RAM and the dirty flag.
* A frame's `etSaves` flush is placed at the start of the frame, before the
  frame's own RAM writes (`w`). The event is scheduled every 280896 cycles
  (70224 dots) from boot, i.e. once per frame at a fixed phase; RAM written
  after that phase in a frame is flushed by the next frame, which is what
  this placement says. Writes before it in the same frame are the same
  behaviour as writes after it in the previous frame.
* Frame pacing, turbo, frame advance and the 33 ms rewind cadence only decide
  whether a phase-1 event is a frame, a pop or `idle`; all three are allowed
  whenever the code would allow them. The rewind ring pushes after every frame
  (`maybe_push` pushes every Nth frame, a subset).
* Nine slots are any `Nat`. The thumbnail a slot shows is the file it was read
  from (`viewFiles`); `used` is `viewFiles k ≠ none`.
* ImGui's skip condition (1272-1283) is `imguiSkipped`; the menu is visible
  whenever the user moves the mouse, so menu clicks are allowed in every
  present. A modal notice blocks menu and window clicks until OK, or
  (since round 3) Return or Escape, all three in the present phase
  (`noticeOk`). `WantCaptureKeyboard` (1640) is not modelled: it only removes
  key events, and no trace below needs a key while an ImGui window has focus.
* Config is two fields: `hle` (the BIOS mode the CLI can set: `gba.hle`,
  `run_bios`, `hle_after_bios`, `gba.bios`) and `vol` (any GUI setting).
  Recents are not modelled (they only ride along in the same write).
* Netlink traffic, SIO, the peer, audio and video are not modelled: `linked`
  is `app.netlink != nil`, `setup` is `app.link_setup != lsNone`, and
  `linkLost` is `step_frame` raising NetLinkError part way through a frame
  (netlink.nim 69/110/145). `load_rom` while linked (it does not tear the link
  down) is outside this machine.
* The config file and `.cht` are always written whole here (their truncation
  is argued in the report, not modelled); `.cht` is modelled only for its
  identity (`wrongCht`, the same name as the `.sav`).
* The lock (`lock`) is the other process's `cur` while it is live: game_lock.nim
  takes both locks inside `load_rom` and swaps them where `cur` changes, and
  the OS drops them when the process ends (`dead`, `exited`). A folder is its
  real path, and on macOS and Windows its name's case does not count (the
  lock keys fold it), which only refuses more. Not modelled: a lock file that
  cannot be made (an unwritable config folder), where `load_rom` goes ahead
  unlocked, as every build before this one did.
* Ghost fields (`base`, `loads`, `clobbers`, `foreign`, `blind`, `dropped`,
  `truncs`, `crashes`, `staleRewind`, `midSaves`, `userHle`, `userVol`,
  `wrongBoot`, `wrongCht`) only record what happened; no code reads them.
-/
namespace DesktopState.SavePersistence

set_option linter.unusedSimpArgs false

/-! ## Maps -/

/-- `f` with `k ↦ v`. -/
def upd {κ α : Type} [DecidableEq κ] (f : κ → α) (k : κ) (v : α) : κ → α :=
  fun x => if x = k then v else f x

@[simp] theorem upd_same {κ α : Type} [DecidableEq κ] (f : κ → α) (k : κ) (v : α) :
    upd f k v k = v := by simp [upd]

theorem upd_apply {κ α : Type} [DecidableEq κ] (f : κ → α) (k : κ) (v : α) (x : κ) :
    upd f k v x = if x = k then v else f x := rfl

/-! ## Files and cores -/

/-- A ROM file on disk. -/
structure Rom where
  dir  : Nat   -- its folder (a zip: config_dir/zip-cache/<zip name>-<hash of zip path>)
  base : Nat   -- file name without extension (a zip: the inner entry's)
  ext  : Nat   -- 0 = .gba, 1 = .gb, 2 = .gbc
  game : Nat   -- its contents: the cartridge, and gba_rom_checksum / gb_rom_checksum
deriving DecidableEq, Repr

/-- `load_rom` 704-705: `.gb`/`.gbc` build a GB core, anything else a GBA core. -/
def Rom.gba (r : Rom) : Bool := r.ext == 0

/-- A battery file path: `<dir>/<base>.sav` (and `.cht`). -/
abbrev SavPath := Nat × Nat

/-- A save-state file name under `config_dir/states`: the ROM identity (0 in
    the real code's names, which carry none), the ROM's file name (`base`,
    `ext`) and the slot. -/
abbrev StPath := Nat × Nat × Nat × Nat

/-- A battery image. -/
structure Bat where
  game  : Nat    -- the game whose cart RAM this is
  ver   : Nat    -- when it was written (global clock)
  whole : Bool   -- false: a `writeFile` that stopped part way
deriving DecidableEq, Repr

/-- The emulator core (`app.gba_emu` / `app.gb_emu`), as far as persistence sees it. -/
structure Core where
  game  : Nat          -- the cart it was built for
  line  : Nat          -- timeline: fresh at boot and at every applied state load
  ram   : Option Bat   -- cart battery RAM (none = blank, no .sav read)
  dirty : Bool         -- gba `storage.dirty` / gb `cart.ram_dirty`
deriving DecidableEq, Repr

/-- A `.state` file. -/
structure StF where
  ident : Nat    -- header rom_checksum (serialize.nim 377)
  core  : Core   -- the payload
  whole : Bool   -- false: shorter than its payload_len (srkTruncated) / hash mismatch
deriving DecidableEq, Repr

/-- `Config` (config.nim), the two fields that matter here. -/
structure Cfg where
  hle : Bool   -- gba.hle / run_bios / hle_after_bios / gba.bios: what the CLI can set
  vol : Nat    -- any GUI setting (volume, rewind, filter, ...)
deriving DecidableEq, Repr

def Cfg.dflt : Cfg := ⟨false, 0⟩

/-- Where a process's main loop is (`main` 2426-2605). -/
inductive Phase where
  | off     -- not running
  | emu     -- 2432-2486: rewind pop / one frame / nothing, then the rewind push
  | pend    -- 2522-2523: process_pending_state
  | input   -- 2546: handle_input (every queued SDL event)
  | link    -- 2548-2549: update_link_auto, service_link_setup
  | pres    -- 2556: is a present due?
  | menu    -- render_imgui 1293-1476: menu bar, file explorer
  | win     -- render_imgui 1511-1514: Save States and Link Cable windows
  | dead    -- killed: an uncaught exception left main(), or the power went
  | exited  -- left the loop normally (2606-2607)
deriving DecidableEq, Repr

/-- What happens to one `writeFile`. -/
inductive Io where
  | ok      -- written
  | denied  -- open(fmWrite) fails: read-only folder/file; nothing written, IOError
  | full    -- the write fails part way (disk full): file truncated, IOError
  | power   -- the machine dies part way: file truncated, every process gone
deriving DecidableEq, Repr

/-- One dingbat process's `AppState`, as far as this machine reads or writes it. -/
structure App where
  pc        : Phase
  cur       : Option Rom      -- current_rom_path() (769), emu_kind != ekNone
  core      : Option Core     -- app.gba_emu / app.gb_emu
  paused    : Bool            -- app.paused
  running   : Bool            -- app.running
  pendSave  : Bool            -- app.pending_save
  pendLoad  : Bool            -- app.pending_load
  linked    : Bool            -- app.netlink != nil
  setup     : Bool            -- app.link_setup != lsNone (auto-pair / host / join in progress)
  mid       : Bool            -- the core stopped inside a frame: step_frame raised (2459-2465)
  rewind    : List Core       -- app.rewind (newest first)
  rewinding : Bool            -- app.rewinding
  notice    : Bool            -- app.state_notice != "" (the modal)
  win       : Bool            -- app.save_states.window
  wasOpen   : Bool            -- save_states.was_open (save_states_widget.nim 26)
  view      : Option Rom      -- whose slots the grid was last filled from (refresh_state_slots 890)
  viewFiles : Nat → Option StF -- slots[k]: the file each thumbnail/label was read from
  cfg       : Cfg             -- app.cfg (the same ref as ce.cfg / fe.cfg)
  over      : Bool            -- fixed code only: this run's CLI BIOS override, never persisted
  batErr    : Bool            -- fixed code only: the core's `save_error` is set (the last battery
                              -- write failed), which the app shows (`poll_battery_notice`)
  base      : Option Bat      -- ghost: the .sav content this process last read or wrote

def App.off : App :=
  { pc := .off, cur := none, core := none, paused := false, running := true,
    pendSave := false, pendLoad := false, linked := false, setup := false, mid := false, rewind := [],
    rewinding := false, notice := false, win := false, wasOpen := false, view := none,
    viewFiles := fun _ => none, cfg := Cfg.dflt, over := false, batErr := false, base := none }

structure St where
  app     : Bool → App             -- the two processes
  sav     : SavPath → Option Bat   -- .sav files
  cht     : SavPath → Option Nat   -- .cht files: the game whose cheat list it holds
  st      : StPath → Option StF    -- .state files
  cfgDisk : Option Cfg             -- dingbat.yml
  clock   : Nat
  -- ghost state (not in the Nim; for stating properties)
  loads     : List (Bool × Rom × StF)          -- applied state loads: linked?, into, file
  wrongBoot : List (Rom × Bat)                 -- a core built on another game's .sav
  wrongCht  : List (Rom × Nat)                 -- a ROM that read another game's .cht
  clobbers  : List (SavPath × Option Bat × Bat) -- a .sav write over content its writer never saw
  foreign   : List (StPath × StF × StF)        -- a .state write over another game's state
  blind     : List StPath                      -- a window Save/Delete on a file its grid did not show
  dropped   : List Bat                         -- dirty battery RAM thrown away at a switch or quit
  truncs    : Nat                              -- writes that left a truncated file
  crashes   : Nat                              -- processes killed by an uncaught exception
  staleRewind : Nat                            -- rewind pops onto another timeline
  userHle   : Bool                             -- the BIOS mode the user last chose in Settings
  userVol   : Nat                              -- the GUI setting the user last chose
  midSaves  : Nat                              -- state files written from a core stopped mid-frame

def init : St :=
  { app := fun _ => App.off, sav := fun _ => none, cht := fun _ => none, st := fun _ => none,
    cfgDisk := none, clock := 1, loads := [], wrongBoot := [], wrongCht := [], clobbers := [],
    foreign := [], blind := [], dropped := [], truncs := 0, crashes := 0, staleRewind := 0,
    userHle := false, userVol := 0, midSaves := 0 }

/-- The code: every flag false is a2e038f82; every flag true is the proposed fix. -/
structure Fix where
  linkGate    : Bool  -- no state load while linked, wherever it is asked for
  staleView   : Bool  -- load_rom marks the Save States window stale
  identity    : Bool  -- state files named by ROM identity and file name, not by file name alone
  lock        : Bool  -- a second window on a game's files is refused
  catchIo     : Bool  -- write_save's IOError caught, like mbc_save's
  flushGba    : Bool  -- the GBA battery is flushed at a switch and at quit, like GB's
  atomic      : Bool  -- every writeFile goes to a temp file, then renames over
  cliOver     : Bool  -- CLI BIOS flags kept out of app.cfg; save_config writes only its keys
  rewindClear : Bool  -- an applied state load clears the rewind ring
  finishFrame : Bool  -- after a link loss mid-frame, the torn frame is run to its end first
deriving DecidableEq, Repr

def real : Fix := ⟨false, false, false, false, false, false, false, false, false, false⟩
def fixed : Fix := ⟨true, true, true, true, true, true, true, true, true, true⟩

/-! ## Paths -/

/-- gba.nim 1358 / gb mbc.nim 156: `rom_path[0 ..< rom_path.rfind('.')] & ".sav"`;
    cheat_file_path 777-781 the same with `.cht`. -/
def savPath (r : Rom) : SavPath := (r.dir, r.base)

/-- state_file_path 823-831: `config_dir/states/<rom.extractFilename()>[.slotN].state`.
    Fixed: named by the ROM identity as well, what shipped
    (frontend/persist.nim `state_file_name`):
    `<rom file name>-<identity>[.slotN].state`. It also reads, never writes, an older build's
    `<rom file name>[.slotN].state` when the slot has no file of its own and
    that file's header names this cart (`state_read_path`, and Delete removes
    it too). The model's `init` holds no such files (every run starts on an
    empty disk), so that fallback is not modelled; its loads are guarded by the
    same header check as any other (`loads_ok`) and it never shows or deletes
    another game's file (tests/desktop_persist_test.nim). -/
def stPath (fx : Fix) (r : Rom) (k : Nat) : StPath :=
  (if fx.identity then r.game else 0, r.base, r.ext, k)

/-! ## Helpers -/

def setA (s : St) (i : Bool) (a : App) : St := { s with app := upd s.app i a }

def live (a : App) : Bool :=
  match a.pc with
  | .off | .dead | .exited => false
  | _ => true

/-- Power lost: every process stops where it is. -/
def powerDown (s : St) : St := { s with app := fun j => { s.app j with pc := .dead } }

/-- One `writeFile(path, v)`: the new map and whether it raised / killed the
    machine. `atomic`: the fixed code writes a temp file and renames it over,
    so a failure leaves the old file. -/
inductive Out where
  | ok | raised | died
deriving DecidableEq, Repr

def wr {κ α : Type} [DecidableEq κ] (atomic : Bool) (f : κ → Option α) (k : κ) (v cut : α) :
    Io → (κ → Option α) × Out
  | .ok => (upd f k (some v), .ok)
  | .denied => (f, .raised)
  | .full => (if atomic then f else upd f k (some cut), .raised)
  | .power => (if atomic then f else upd f k (some cut), .died)

/-- Did this write leave a truncated file? -/
def cuts (atomic : Bool) : Io → Bool
  | .full | .power => !atomic
  | _ => false

/-- Did this write raise (and the process live on)? -/
def Io.raises : Io → Bool
  | .denied | .full => true
  | _ => false

/-- The per-frame battery flush (`etSaves`): gba `handle_saves` (gba.nim 1530-1532)
    -> `storage.write_save` (storage.nim 90-95, no try: an IOError leaves
    `run_until_frame` (2470) / `step_frame` (2460, which catches only
    NetLinkError), the main loop and `main()`); gb `handle_saves` (gb.nim
    3494-3498) -> `mbc_save` (3228-3246: caught, reported once, RAM stays dirty).
    Fixed (`catchIo`): both catch it, keep the RAM dirty and record the error
    (`save_error`), which the app shows until a write lands (`batErr`); the
    once-per-run notice and its dismissal are tests/desktop_persist_test.nim's. -/
def flushFrame (fx : Fix) (s : St) (i : Bool) (io : Io) : St :=
  let a := s.app i
  match a.cur, a.core with
  | some r, some c =>
    match c.dirty, c.ram with
    | true, some b =>
      let p := savPath r
      let s1 := { s with clobbers := if s.sav p = a.base then s.clobbers
                                     else s.clobbers ++ [(p, s.sav p, b)] }
      let w := wr fx.atomic s.sav p b { b with whole := false } io
      let s2 := { s1 with sav := w.1, truncs := s1.truncs + (if cuts fx.atomic io then 1 else 0) }
      let a2 := { a with base := w.1 p,
                         core := some (if w.2 = .ok then { c with dirty := false } else c),
                         batErr := fx.catchIo && w.2 = .raised }
      match w.2 with
      | .ok => setA s2 i a2
      | .raised =>
        if r.gba && !fx.catchIo then
          setA { s2 with crashes := s2.crashes + 1 } i { a2 with pc := .dead }  -- uncaught
        else setA s2 i a2                                                       -- mbc_save 3243-3246
      | .died => powerDown s2
    | _, _ => s
  | _, _ => s

/-- The battery flush at a switch (load_rom 702) or at quit (2606):
    `flush_gb_save` (477-481) -> `mbc_save`. GBA: nothing (fixed: the same
    flush). Assumed to succeed (its failures are the frame flush's). -/
def flushOut (fx : Fix) (s : St) (i : Bool) : St :=
  let a := s.app i
  match a.cur, a.core with
  | some r, some c =>
    match c.dirty, c.ram with
    | true, some b =>
      if r.gba && !fx.flushGba then { s with dropped := s.dropped ++ [b] }
      else
        let p := savPath r
        let s1 := { s with clobbers := if s.sav p = a.base then s.clobbers
                                       else s.clobbers ++ [(p, s.sav p, b)] }
        setA { s1 with sav := upd s1.sav p (some b) } i
          { a with base := some b, core := some { c with dirty := false } }
    | _, _ => s
  | _, _ => s

/-- `o` holds something whose `g` is not `x`. -/
def differs {α : Type} (o : Option α) (g : α → Nat) (x : Nat) : Bool :=
  match o with
  | some v => g v != x
  | none => false

/-- The same `.sav` and `.cht`: game_lock.nim `files_key` (the folder, symlinks
    resolved, and the name minus the extension). -/
def sameFiles (r r' : Rom) : Bool := r.dir == r'.dir && r.base == r'.base

/-- The same save-state slots: game_lock.nim `states_key` (the file name and
    the ROM identity, in any folder). -/
def sameStates (r r' : Rom) : Bool := r.game == r'.game && r.base == r'.base && r.ext == r'.ext

/-- Two ROMs whose files would collide. -/
def conflict (r r' : Rom) : Bool := sameFiles r r' || sameStates r r'

/-- Fixed code only: the other process holds the lock `same` names for `r`.
    A lock is held from the load that took it until the process ends or its
    next successful switch: exactly while that process is live with the game
    as `cur` (`load_rom` commits the new game's locks where `cur` changes). -/
def holds (s : St) (i : Bool) (same : Rom → Rom → Bool) (r : Rom) : Bool :=
  let o := s.app (!i)
  live o && (match o.cur with
    | some r' => same r r'
    | none => false)

/-- Ghost only: a core built on another game's battery file, a cheat list
    read from another game's `.cht`. -/
def noteBoot (s : St) (r : Rom) (ram : Option Bat) : St :=
  { s with
    wrongBoot := if differs ram Bat.game r.game then s.wrongBoot ++ [(r, ram.getD ⟨0, 0, true⟩)]
                 else s.wrongBoot
    wrongCht := if differs (s.cht (savPath r)) id r.game
                then s.wrongCht ++ [(r, (s.cht (savPath r)).getD 0)] else s.wrongCht }

@[simp] theorem noteBoot_app (s : St) (r : Rom) (b : Option Bat) : (noteBoot s r b).app = s.app := rfl
@[simp] theorem noteBoot_sav (s : St) (r : Rom) (b : Option Bat) : (noteBoot s r b).sav = s.sav := rfl
@[simp] theorem noteBoot_st (s : St) (r : Rom) (b : Option Bat) : (noteBoot s r b).st = s.st := rfl
@[simp] theorem noteBoot_cht (s : St) (r : Rom) (b : Option Bat) : (noteBoot s r b).cht = s.cht := rfl
@[simp] theorem noteBoot_clock (s : St) (r : Rom) (b : Option Bat) : (noteBoot s r b).clock = s.clock := rfl
@[simp] theorem noteBoot_cfgDisk (s : St) (r : Rom) (b : Option Bat) :
    (noteBoot s r b).cfgDisk = s.cfgDisk := rfl
@[simp] theorem noteBoot_loads (s : St) (r : Rom) (b : Option Bat) : (noteBoot s r b).loads = s.loads := rfl
@[simp] theorem noteBoot_clobbers (s : St) (r : Rom) (b : Option Bat) :
    (noteBoot s r b).clobbers = s.clobbers := rfl
@[simp] theorem noteBoot_foreign (s : St) (r : Rom) (b : Option Bat) :
    (noteBoot s r b).foreign = s.foreign := rfl
@[simp] theorem noteBoot_blind (s : St) (r : Rom) (b : Option Bat) : (noteBoot s r b).blind = s.blind := rfl
@[simp] theorem noteBoot_dropped (s : St) (r : Rom) (b : Option Bat) :
    (noteBoot s r b).dropped = s.dropped := rfl
@[simp] theorem noteBoot_truncs (s : St) (r : Rom) (b : Option Bat) : (noteBoot s r b).truncs = s.truncs := rfl
@[simp] theorem noteBoot_crashes (s : St) (r : Rom) (b : Option Bat) :
    (noteBoot s r b).crashes = s.crashes := rfl
@[simp] theorem noteBoot_staleRewind (s : St) (r : Rom) (b : Option Bat) :
    (noteBoot s r b).staleRewind = s.staleRewind := rfl
@[simp] theorem noteBoot_userHle (s : St) (r : Rom) (b : Option Bat) :
    (noteBoot s r b).userHle = s.userHle := rfl
@[simp] theorem noteBoot_userVol (s : St) (r : Rom) (b : Option Bat) :
    (noteBoot s r b).userVol = s.userVol := rfl

/-- `load_rom` (694-766). Fixed (`lock`): after the running game's battery
    is flushed, refused (a notice, the running game left as it is) when
    another window holds this ROM's `.sav`/`.cht` (`claim_files`, before the
    new core reads the `.sav`) or, once the core is built, its save-state
    slots (`claim_states`); nothing between the two changes what this
    machine sees. -/
def loadRom (fx : Fix) (s0 : St) (i : Bool) (r : Rom) : St :=
  let s := flushOut fx s0 i                                    -- 702 flush_gb_save
  if fx.lock && holds s i conflict r then s else
  let a := s.app i
  -- new_storage 1377-1385 / mbc_load 3247: whatever .sav is there, any length
  let disk := s.sav (savPath r)
  let s := noteBoot s r disk                                   -- 735 load_cheats
  let a' := { a with cur := some r, core := some ⟨r.game, s.clock, disk, false⟩,
                     base := disk, batErr := false,
                     rewind := [], rewinding := false,                 -- 744-745
                     paused := false, pendSave := false, pendLoad := false,  -- 763-765
                     wasOpen := if fx.staleView then false else a.wasOpen }
  -- 761 save_config(app.cfg): the whole object, CLI edits included.
  -- Fixed: writes only recents, leaving every other key as the file has it.
  let cfgD := if fx.cliOver then some (s.cfgDisk.getD Cfg.dflt) else some a.cfg
  setA { s with clock := s.clock + 1, cfgDisk := cfgD } i a'

/-- `main` 2107-2296: options, `load_config` (2163) and the CLI edits to that
    same object (2164-2175), then `load_rom(rom_path)` (2296). `cli`: any of
    `--hle`, `--hle-after-bios`, `--run-bios`, a BIOS path argument. -/
def launch (fx : Fix) (s : St) (i : Bool) (cli : Bool) (ro : Option Rom) : St :=
  let cfg0 := s.cfgDisk.getD Cfg.dflt
  let a := { App.off with pc := .emu,
                          cfg := (if cli && !fx.cliOver then { cfg0 with hle := true } else cfg0),
                          over := cli && fx.cliOver }
  let s := setA s i a
  match ro with
  | some r => loadRom fx s i r
  | none => s

/-- `save_state_slot` (833-842) -> core `save_state` -> `write_state_file`
    (serialize.nim 305-319): `writeFile`, every error caught (returns false). -/
def saveSlot (fx : Fix) (s : St) (i : Bool) (k : Nat) (io : Io) : St :=
  let a := s.app i
  match a.cur, a.core with
  | some r, some c =>
    let p := stPath fx r k
    let f : StF := ⟨r.game, c, true⟩
    let s1 := { s with foreign := if differs (s.st p) StF.ident r.game
                                  then s.foreign ++ [(p, (s.st p).getD f, f)] else s.foreign }
    let w := wr fx.atomic s.st p f { f with whole := false } io
    let s2 := { s1 with st := w.1, truncs := s1.truncs + (if cuts fx.atomic io then 1 else 0),
                        midSaves := s1.midSaves + (if a.mid then 1 else 0) }
    if w.2 = .died then powerDown s2 else s2
  | _, _ => s

/-- `load_state_slot` (844-853) -> core `load_state` (gba savestate.nim
    999-1012, gb 1049-1062) -> `read_state_payload`: refused unless the file
    is there, whole, and made for this cart; an applied state marks the
    battery dirty (gba 665, gb 755). The rewind ring is left as it is.
    Fixed: refused while linked; the ring is cleared. Returns whether it applied. -/
def loadSlot (fx : Fix) (s : St) (i : Bool) (k : Nat) : St × Bool :=
  let a := s.app i
  if fx.linkGate && a.linked then (s, false) else
  match a.cur, a.core with
  | some r, some _ =>
    match s.st (stPath fx r k) with
    | some f =>
      if f.whole && f.ident == r.game then
        (setA { s with clock := s.clock + 1, loads := s.loads ++ [(a.linked, r, f)] } i
           { a with core := some { f.core with line := s.clock, dirty := true },
                    rewind := if fx.rewindClear then [] else a.rewind }, true)
      else (s, false)
    | none => (s, false)
  | _, _ => (s, false)

/-- `refresh_state_slots` (890-923), the window's `on_open` (2272). -/
def refresh (fx : Fix) (s : St) (i : Bool) : St :=
  let a := s.app i
  match a.cur with
  | some r => setA s i { a with view := some r, viewFiles := fun k => s.st (stPath fx r k) }
  | none => setA s i { a with view := none, viewFiles := fun _ => none }

/-- The end of a loop iteration: `while app.running` (2426), else leave the
    loop and `flush_gb_save()` (2606). -/
def loopEnd (fx : Fix) (s : St) (i : Bool) : St :=
  let a := s.app i
  if a.running then setA s i { a with pc := .emu }
  else
    let s1 := flushOut fx s i
    setA s1 i { s1.app i with pc := .exited }

/-- `process_pending_state` (925-939), gated at 2522 on a loaded ROM. The real
    code discards a failed Quick Save's result; fixed (`atomic`), the slot
    still holds its previous file and the notice says so (`QUICK_SAVE_FAILED`). -/
def pendStep (fx : Fix) (s : St) (i : Bool) (io : Io) : St :=
  let a := s.app i
  if a.cur.isNone || !(a.pendSave || a.pendLoad) then setA s i { a with pc := .input } else
  let s1 :=
    if a.pendSave then                                         -- 929-933
      let s' := saveSlot fx (setA s i { a with pendSave := false }) i 0 io
      setA s' i { s'.app i with wasOpen := false,              -- mark_stale
                                notice := (s'.app i).notice || (fx.atomic && io.raises) }
    else s
  if (s1.app i).pc = .dead then s1 else
  let a1 := s1.app i
  let s2 :=
    if a1.pendLoad then                                        -- 934-938
      let r := loadSlot fx (setA s1 i { a1 with pendLoad := false }) i 0
      if r.2 then r.1 else setA r.1 i { r.1.app i with notice := true }
    else s1
  setA s2 i { s2.app i with pc := .input }

/-- ImGui's skip condition (1272-1283), with every debug/overlay/explorer
    window closed; `menuVisible` is `show_menu_bar()` (mouse over, recently moved). -/
def imguiSkipped (a : App) (menuVisible : Bool) : Bool :=
  a.cur.isSome && !a.paused && !a.rewinding && !menuVisible && !a.win && !a.notice

/-! ## Events -/

inductive Ev where
  -- process start
  | launch (i : Bool) (cli : Bool) (r : Option Rom) -- `dingbat [flags] [ROM]` (main 2107)
  -- phase emu
  | frame (i : Bool) (w : Bool) (io : Io) -- one frame (2451-2478): the etSaves flush (outcome io),
                                          -- then the game writes its battery RAM (w); rewind push 2479-2486
  | rewindPop (i : Bool)                  -- 2432-2450
  | linkLost (i : Bool)                   -- the peer drops inside a linked frame: step_frame
                                          -- raises NetLinkError (netlink.nim 69/110/145) mid-frame;
                                          -- main catches it and tears the link down (2462-2464)
  | idle (i : Bool)                       -- nothing emulated (paused, not due)
  -- phase pend
  | pend (i : Bool) (io : Io)             -- 2522-2523 (io: the Quick Save's write)
  -- phase input (handle_input 1628-1770)
  | keySave (i : Bool)                    -- Ctrl+S 1655-1656
  | keyLoad (i : Bool)                    -- Ctrl+L 1657-1660 (refused while linked)
  | drop (i : Bool) (r : Rom)             -- DropFile 1761-1767 -> load_rom
  | keyPause (i : Bool)                   -- Ctrl+P 1649-1650
  | rewindKey (i : Bool) (held : Bool)    -- ` 1674-1677
  | quit (i : Bool)                       -- Ctrl+Q / QuitEvent 1769
  | inputDone (i : Bool)
  -- phase link
  | linkUp (i : Bool)                     -- service_link_setup -> finish_link 1826-1848
  | linkIdle (i : Bool)
  -- phase pres
  | present (i : Bool)                    -- 2556-2584: render_imgui runs
  | noPresent (i : Bool)
  -- phase menu (render_imgui 1293-1476)
  | mQuickSave (i : Bool)                 -- 1308-1310
  | mQuickLoad (i : Bool)                 -- 1311-1313 (no link check)
  | mStates (i : Bool)                    -- 1314-1315
  | mOpen (i : Bool) (r : Rom)            -- File > Recent 1297-1300 / Open ROM 1473 / Reset 1370
  | mLink (i : Bool)                      -- 1377-1379 + update_link_auto 2094: auto-pair starts
  | mSetHle (i : Bool) (b : Bool)         -- Settings > BIOS (bios_selection.nim 79-82, config_editor.nim 46)
  | mSetVol (i : Bool) (v : Nat)          -- any setting: 1386-1425 save_config(app.cfg)
  | mCheat (i : Bool)                     -- a cheat edit: on_cheats_changed 818-821
  | noticeOk (i : Bool)                   -- the modal's OK, Return or Escape (notice.nim render_notice)
  | mDone (i : Bool)                      -- the Save States window's render entry (widget 69-75)
  -- phase win
  | wSave (i : Bool) (k : Nat) (io : Io)  -- widget 191-193: on_save then on_open
  | wLoad (i : Bool) (k : Nat)            -- widget 195-198 (enabled when slots[k].used)
  | wDelete (i : Bool) (k : Nat)          -- widget 180-184 (enabled when slots[k].used), then on_open
  | wClose (i : Bool)                     -- the window's close box
  | disconnect (i : Bool)                 -- Link Cable window's Disconnect 2066-2068 / peer gone
  | presentDone (i : Bool)
deriving DecidableEq, Repr

/-- Accept `f` only in phase `ph` of process `i`. -/
def at_ (s : St) (i : Bool) (ph : Phase) (f : St) : St :=
  if (s.app i).pc = ph then f else s

/-- Menu/window clicks: render_imgui ran, and no modal is up. -/
def click (s : St) (i : Bool) (ph : Phase) (f : St) : St :=
  if (s.app i).pc = ph && !(s.app i).notice then f else s

def step (fx : Fix) (s : St) : Ev → St
  | .launch i cli ro =>
      match (s.app i).pc with
      | .off | .dead | .exited => launch fx s i cli ro
      | _ => s
  | .frame i w io =>
      let a := s.app i
      if a.pc = .emu && a.cur.isSome && a.core.isSome && !a.paused &&
         !(a.rewinding && !a.linked) then
        let s1 := flushFrame fx s i io
        let a1 := s1.app i
        if a1.pc = .dead then s1 else
        match a1.core with
        | some c =>
          let c' := if w then { c with ram := some ⟨c.game, s1.clock, true⟩, dirty := true } else c
          setA { s1 with clock := s1.clock + 1 } i
            { a1 with core := some c', pc := .pend, mid := false,
                      rewind := if a1.linked then a1.rewind else c' :: a1.rewind }
        | none => s1
      else s
  | .rewindPop i =>
      let a := s.app i
      if a.pc = .emu && a.rewinding && a.cur.isSome && !a.linked then
        match a.rewind, a.core with
        | h :: t, some c =>
          setA { s with staleRewind := s.staleRewind + (if h.line = c.line then 0 else 1) } i
            { a with core := some { h with dirty := true }, rewind := t, pc := .pend }
        | _, _ => setA s i { a with pc := .pend }
      else s
  | .linkLost i =>
      let a := s.app i
      if a.pc = .emu && a.linked && a.cur.isSome && a.core.isSome && !a.paused then
        setA s i { a with linked := false, mid := !fx.finishFrame, pc := .pend }
      else s
  | .idle i => at_ s i .emu (setA s i { s.app i with pc := .pend })
  | .pend i io => at_ s i .pend (pendStep fx s i io)
  | .keySave i =>
      let a := s.app i
      at_ s i .input (if a.cur.isSome then setA s i { a with pendSave := true } else s)
  | .keyLoad i =>
      let a := s.app i
      at_ s i .input (if a.cur.isSome && !a.linked then setA s i { a with pendLoad := true } else s)
  | .drop i r => at_ s i .input (loadRom fx s i r)
  | .keyPause i => at_ s i .input (setA s i { s.app i with paused := !(s.app i).paused })
  | .rewindKey i held =>
      let a := s.app i
      at_ s i .input (setA s i { a with rewinding := held && a.cur.isSome && !a.linked })
  | .quit i => at_ s i .input (setA s i { s.app i with running := false })
  | .inputDone i => at_ s i .input (setA s i { s.app i with pc := .link })
  | .linkUp i =>
      let a := s.app i
      at_ s i .link
        (if a.setup then
           setA s i { a with linked := true, setup := false, rewind := [], rewinding := false, pc := .pres }
         else setA s i { a with pc := .pres })
  | .linkIdle i => at_ s i .link (setA s i { s.app i with pc := .pres })
  | .present i => at_ s i .pres (setA s i { s.app i with pc := .menu })
  | .noPresent i => at_ s i .pres (loopEnd fx s i)
  | .mQuickSave i =>
      let a := s.app i
      click s i .menu (if a.cur.isSome then setA s i { a with pendSave := true } else s)
  | .mQuickLoad i =>
      let a := s.app i
      click s i .menu
        (if a.cur.isSome && !(fx.linkGate && a.linked) then setA s i { a with pendLoad := true } else s)
  | .mStates i =>
      let a := s.app i
      click s i .menu (if a.cur.isSome then setA s i { a with win := true } else s)
  | .mOpen i r => click s i .menu (loadRom fx s i r)
  | .mLink i =>
      let a := s.app i
      click s i .menu
        (match a.cur with
         | some r => if r.gba && !a.linked then setA s i { a with setup := true } else s
         | none => s)
  | .mSetHle i b =>
      let a := s.app i
      let cfg := { a.cfg with hle := b }
      click s i .menu
        (setA { s with userHle := b,
                       cfgDisk := (if fx.cliOver then some { s.cfgDisk.getD Cfg.dflt with hle := b }
                                   else some cfg) } i
           { a with cfg := cfg, over := false })
  | .mSetVol i v =>
      let a := s.app i
      let cfg := { a.cfg with vol := v }
      click s i .menu
        (setA { s with userVol := v,
                       cfgDisk := (if fx.cliOver then some { s.cfgDisk.getD Cfg.dflt with vol := v }
                                   else some cfg) } i
           { a with cfg := cfg })
  | .mCheat i =>
      let a := s.app i
      click s i .menu
        (match a.cur with
         | some r => { s with cht := upd s.cht (savPath r) (some r.game) }
         | none => s)
  | .noticeOk i =>
      let a := s.app i
      at_ s i .menu (setA s i { a with notice := false })
  | .mDone i =>
      let a := s.app i
      at_ s i .menu
        (if !a.win then setA s i { a with wasOpen := false, pc := .win }
         else if !a.wasOpen then
           let s1 := refresh fx s i
           setA s1 i { s1.app i with wasOpen := true, pc := .win }
         else setA s i { a with pc := .win })
  | .wSave i k io =>
      let a := s.app i
      click s i .win
        (if !a.win then s else
         match a.cur with
         | some r =>
           let p := stPath fx r k
           let s0 := { s with blind := if s.st p = a.viewFiles k then s.blind else s.blind ++ [p] }
           let s1 := saveSlot fx s0 i k io
           if (s1.app i).pc = .dead then s1 else refresh fx s1 i
         | none => s)
  | .wLoad i k =>
      let a := s.app i
      click s i .win
        (if a.win && (a.viewFiles k).isSome then (loadSlot fx s i k).1 else s)
  | .wDelete i k =>
      let a := s.app i
      click s i .win
        (if !(a.win && (a.viewFiles k).isSome) then s else
         match a.cur with
         | some r =>
           let p := stPath fx r k
           let s0 := { s with blind := if s.st p = a.viewFiles k || s.st p = none then s.blind
                                       else s.blind ++ [p] }
           refresh fx { s0 with st := upd s0.st p none } i
         | none => s)
  | .wClose i => click s i .win (setA s i { s.app i with win := false })
  | .disconnect i =>
      let a := s.app i
      click s i .win (if a.linked then setA s i { a with linked := false } else s)
  | .presentDone i => at_ s i .win (loopEnd fx s i)

def run (fx : Fix) (s : St) : List Ev → St
  | [] => s
  | e :: es => run fx (step fx s e) es

inductive Reachable (fx : Fix) : St → Prop
  | init : Reachable fx init
  | step {s : St} (e : Ev) : Reachable fx s → Reachable fx (step fx s e)

theorem run_reachable (fx : Fix) (s : St) (es : List Ev) (h : Reachable fx s) :
    Reachable fx (run fx s es) := by
  induction es generalizing s with
  | nil => exact h
  | cons e es ih => exact ih _ (Reachable.step e h)

/-! ## Scripted iterations -/

/-- The tail of one iteration after phase 1, with `inp` in handle_input,
    `men` in the menu and `wins` in the windows. -/
def iter (i : Bool) (em : Ev) (inp men wins : List Ev) (lk : Ev := .linkIdle i) : List Ev :=
  [em, .pend i .ok] ++ inp ++ [.inputDone i, lk, .present i] ++ men ++ [.mDone i] ++ wins ++
    [.presentDone i]


/-! # Proofs

Each section proves one safety property of the fixed code for every
reachable state (every interleaving of both windows' events and every write
outcome). `loads_ok` also holds for the real code. -/

section Ghost

@[simp] theorem cuts_true (io : Io) : cuts true io = false := by cases io <;> rfl
@[simp] theorem fixed_atomic : fixed.atomic = true := rfl
@[simp] theorem fixed_catchIo : fixed.catchIo = true := rfl
@[simp] theorem fixed_flushGba : fixed.flushGba = true := rfl

@[simp] theorem setA_app (s : St) (i : Bool) (a : App) : (setA s i a).app = upd s.app i a := rfl
@[simp] theorem setA_crashes (s : St) (i : Bool) (a : App) : (setA s i a).crashes = s.crashes := rfl
@[simp] theorem setA_dropped (s : St) (i : Bool) (a : App) : (setA s i a).dropped = s.dropped := rfl
@[simp] theorem setA_truncs (s : St) (i : Bool) (a : App) : (setA s i a).truncs = s.truncs := rfl

theorem flushFrame_ghost (s : St) (i : Bool) (io : Io) :
    (flushFrame fixed s i io).crashes = s.crashes ∧ (flushFrame fixed s i io).dropped = s.dropped ∧
    (flushFrame fixed s i io).truncs = s.truncs := by
  cases io <;> simp only [flushFrame, fixed_atomic, cuts_true, wr] <;> repeat' split
  all_goals simp_all [setA, powerDown, fixed]

theorem flushOut_ghost (s : St) (i : Bool) :
    (flushOut fixed s i).crashes = s.crashes ∧ (flushOut fixed s i).dropped = s.dropped ∧
    (flushOut fixed s i).truncs = s.truncs := by
  simp only [flushOut]
  repeat' split
  all_goals simp_all [setA, fixed]

theorem loadRom_ghost (s : St) (i : Bool) (r : Rom) :
    (loadRom fixed s i r).crashes = s.crashes ∧ (loadRom fixed s i r).dropped = s.dropped ∧
    (loadRom fixed s i r).truncs = s.truncs := by
  have h := flushOut_ghost s i
  simp only [loadRom]
  repeat' split
  all_goals simp_all [setA, fixed]

theorem launch_ghost (s : St) (i : Bool) (c : Bool) (ro : Option Rom) :
    (launch fixed s i c ro).crashes = s.crashes ∧ (launch fixed s i c ro).dropped = s.dropped ∧
    (launch fixed s i c ro).truncs = s.truncs := by
  simp only [launch]
  split
  · exact loadRom_ghost _ _ _
  · simp

theorem saveSlot_ghost (s : St) (i : Bool) (k : Nat) (io : Io) :
    (saveSlot fixed s i k io).crashes = s.crashes ∧ (saveSlot fixed s i k io).dropped = s.dropped ∧
    (saveSlot fixed s i k io).truncs = s.truncs := by
  cases io <;> simp only [saveSlot, fixed_atomic, cuts_true, wr] <;> repeat' split
  all_goals simp_all [powerDown]

theorem loadSlot_ghost (s : St) (i : Bool) (k : Nat) :
    (loadSlot fixed s i k).1.crashes = s.crashes ∧ (loadSlot fixed s i k).1.dropped = s.dropped ∧
    (loadSlot fixed s i k).1.truncs = s.truncs := by
  simp only [loadSlot]
  repeat' split
  all_goals simp_all

theorem refresh_ghost (s : St) (i : Bool) :
    (refresh fixed s i).crashes = s.crashes ∧ (refresh fixed s i).dropped = s.dropped ∧
    (refresh fixed s i).truncs = s.truncs := by
  simp only [refresh]
  split <;> simp

theorem loopEnd_ghost (s : St) (i : Bool) :
    (loopEnd fixed s i).crashes = s.crashes ∧ (loopEnd fixed s i).dropped = s.dropped ∧
    (loopEnd fixed s i).truncs = s.truncs := by
  have h := flushOut_ghost s i
  simp only [loopEnd]
  split <;> simp_all

theorem pendStep_ghost (s : St) (i : Bool) (io : Io) :
    (pendStep fixed s i io).crashes = s.crashes ∧ (pendStep fixed s i io).dropped = s.dropped ∧
    (pendStep fixed s i io).truncs = s.truncs := by
  simp only [pendStep]
  split
  · simp
  · generalize hs1 : (if (s.app i).pendSave = true then _ else s) = s1
    have h1 : s1.crashes = s.crashes ∧ s1.dropped = s.dropped ∧ s1.truncs = s.truncs := by
      subst hs1; split
      · have := saveSlot_ghost (setA s i { s.app i with pendSave := false }) i 0 io
        simp_all
      · simp
    split
    · exact h1
    · generalize hs2 : (if (s1.app i).pendLoad = true then _ else s1) = s2
      have h2 : s2.crashes = s1.crashes ∧ s2.dropped = s1.dropped ∧ s2.truncs = s1.truncs := by
        subst hs2; split
        · have := loadSlot_ghost (setA s1 i { s1.app i with pendLoad := false }) i 0
          split <;> simp_all
        · simp
      simp_all

theorem step_ghost (s : St) (e : Ev) :
    (step fixed s e).crashes = s.crashes ∧ (step fixed s e).dropped = s.dropped ∧
    (step fixed s e).truncs = s.truncs := by
  cases e <;> simp only [step, at_, click] <;> repeat' split
  all_goals simp_all [launch_ghost, loadRom_ghost, flushFrame_ghost, saveSlot_ghost, loadSlot_ghost,
    refresh_ghost, loopEnd_ghost, pendStep_ghost]

/-- **Proved (fixed):** no process is killed by a battery-write error, no
    dirty battery RAM is dropped at a switch or quit, and no write leaves a
    truncated file. -/
theorem clean_ok {s : St} (h : Reachable fixed s) :
    s.crashes = 0 ∧ s.dropped = [] ∧ s.truncs = 0 := by
  induction h with
  | init => exact ⟨rfl, rfl, rfl⟩
  | step e _ ih =>
    rename_i s0 _
    obtain ⟨h1, h2, h3⟩ := step_ghost s0 e
    exact ⟨by rw [h1]; exact ih.1, by rw [h2]; exact ih.2.1, by rw [h3]; exact ih.2.2⟩

end Ghost

section Loads

@[simp] theorem setA_loads (s : St) (i : Bool) (a : App) : (setA s i a).loads = s.loads := rfl

theorem flushFrame_loads (fx : Fix) (s : St) (i : Bool) (io : Io) :
    (flushFrame fx s i io).loads = s.loads := by
  cases io <;> simp only [flushFrame, wr] <;> repeat' split
  all_goals simp_all [powerDown]

theorem flushOut_loads (fx : Fix) (s : St) (i : Bool) : (flushOut fx s i).loads = s.loads := by
  simp only [flushOut]
  repeat' split
  all_goals simp_all

theorem loadRom_loads (fx : Fix) (s : St) (i : Bool) (r : Rom) :
    (loadRom fx s i r).loads = s.loads := by
  have h := flushOut_loads fx s i
  simp only [loadRom]
  repeat' split
  all_goals simp_all

theorem launch_loads (fx : Fix) (s : St) (i : Bool) (c : Bool) (ro : Option Rom) :
    (launch fx s i c ro).loads = s.loads := by
  simp only [launch]
  split
  · simp [loadRom_loads]
  · simp

theorem saveSlot_loads (fx : Fix) (s : St) (i : Bool) (k : Nat) (io : Io) :
    (saveSlot fx s i k io).loads = s.loads := by
  cases io <;> simp only [saveSlot, wr] <;> repeat (first | split | simp_all [powerDown])

theorem refresh_loads (fx : Fix) (s : St) (i : Bool) : (refresh fx s i).loads = s.loads := by
  simp only [refresh]
  split <;> simp

theorem loopEnd_loads (fx : Fix) (s : St) (i : Bool) : (loopEnd fx s i).loads = s.loads := by
  have h := flushOut_loads fx s i
  simp only [loopEnd]
  split <;> simp_all

/-- Every applied state load: a whole file, made for the cart it went into;
    in the fixed code also never while linked. -/
def LoadsInv (fx : Fix) (s : St) : Prop :=
  ∀ x ∈ s.loads, x.2.2.whole = true ∧ x.2.2.ident = x.2.1.game ∧ (fx.linkGate = true → x.1 = false)

theorem loadSlot_loads (fx : Fix) (s : St) (i : Bool) (k : Nat) :
    (loadSlot fx s i k).1.loads = s.loads ∨
    ∃ r f, (loadSlot fx s i k).1.loads = s.loads ++ [((s.app i).linked, r, f)] ∧
      f.whole = true ∧ f.ident = r.game ∧ (fx.linkGate = true → (s.app i).linked = false) := by
  simp only [loadSlot]
  repeat' split
  all_goals first
    | exact Or.inl rfl
    | (right; refine ⟨_, _, rfl, ?_⟩; simp_all)

theorem loadsInv_of (fx : Fix) {s t : St} (i : Bool) (h : LoadsInv fx s)
    (ht : t.loads = s.loads ∨
      ∃ r f, t.loads = s.loads ++ [((s.app i).linked, r, f)] ∧
        f.whole = true ∧ f.ident = r.game ∧ (fx.linkGate = true → (s.app i).linked = false)) :
    LoadsInv fx t := by
  rcases ht with ht | ⟨r, f, ht, hw, hi, hl⟩
  · rw [LoadsInv, ht]; exact h
  · intro x hx
    rw [ht, List.mem_append] at hx
    rcases hx with hx | hx
    · exact h x hx
    · simp at hx; subst hx; exact ⟨hw, hi, hl⟩

theorem loadsInv_congr {fx : Fix} {s t : St} (h : LoadsInv fx s) (ht : t.loads = s.loads) :
    LoadsInv fx t := by
  rw [LoadsInv, ht]; exact h

theorem pendStep_loads (fx : Fix) (s : St) (i : Bool) (io : Io) (h : LoadsInv fx s) :
    LoadsInv fx (pendStep fx s i io) := by
  simp only [pendStep]
  split
  · exact loadsInv_congr h rfl
  · generalize hs1 : (if (s.app i).pendSave = true then _ else s) = s1
    have h1 : LoadsInv fx s1 := by
      subst hs1; split
      · exact loadsInv_congr h (by simp [saveSlot_loads])
      · exact h
    split
    · exact h1
    · generalize hs2 : (if (s1.app i).pendLoad = true then _ else s1) = s2
      have h2 : LoadsInv fx s2 := by
        subst hs2; split
        · have h1' : LoadsInv fx (setA s1 i { s1.app i with pendLoad := false }) :=
            loadsInv_congr h1 rfl
          have := loadsInv_of fx i h1' (loadSlot_loads fx _ i 0)
          split
          · exact this
          · exact loadsInv_congr this rfl
        · exact h1
      exact loadsInv_congr h2 rfl

theorem step_loads (fx : Fix) (s : St) (e : Ev) (h : LoadsInv fx s) : LoadsInv fx (step fx s e) := by
  cases e <;> simp only [step, at_, click] <;> repeat' split
  all_goals first
    | exact h
    | exact pendStep_loads _ _ _ _ h
    | exact loadsInv_of fx _ h (loadSlot_loads _ _ _ _)
    | (apply loadsInv_congr h; simp_all [launch_loads, loadRom_loads, flushFrame_loads,
          saveSlot_loads, refresh_loads, loopEnd_loads])

/-- **Proved (real code too):** a state is only ever applied from a whole
    file whose header names the cart it goes into (`parse_state_payload`'s
    checks); in the fixed code, also never while linked. -/
theorem loads_ok (fx : Fix) {s : St} (h : Reachable fx s) : LoadsInv fx s := by
  induction h with
  | init => intro x hx; simp [init] at hx
  | step e _ ih => exact step_loads fx _ e ih

end Loads

/-! ## The fixed code: configuration -/

section Cfg

/-- The config file holds what the user chose in Settings (the BIOS mode and
    any GUI setting), and nothing a command line or another window put there. -/
def CfgInv (s : St) : Prop :=
  (s.cfgDisk.getD Cfg.dflt).hle = s.userHle ∧ (s.cfgDisk.getD Cfg.dflt).vol = s.userVol

theorem flushFrame_cfg (s : St) (i : Bool) (io : Io) :
    (flushFrame fixed s i io).cfgDisk = s.cfgDisk ∧ (flushFrame fixed s i io).userHle = s.userHle ∧ (flushFrame fixed s i io).userVol = s.userVol := by
  cases io <;> simp only [flushFrame, wr, fixed_atomic, cuts_true] <;>
    repeat (first | split | simp_all [powerDown, setA])

theorem flushOut_cfg (s : St) (i : Bool) :
    (flushOut fixed s i).cfgDisk = s.cfgDisk ∧ (flushOut fixed s i).userHle = s.userHle ∧ (flushOut fixed s i).userVol = s.userVol := by
  simp only [flushOut] <;> repeat (first | split | simp_all [powerDown, setA])

theorem saveSlot_cfg (s : St) (i : Bool) (k : Nat) (io : Io) :
    (saveSlot fixed s i k io).cfgDisk = s.cfgDisk ∧ (saveSlot fixed s i k io).userHle = s.userHle ∧ (saveSlot fixed s i k io).userVol = s.userVol := by
  cases io <;> simp only [saveSlot, wr, fixed_atomic, cuts_true] <;>
    repeat (first | split | simp_all [powerDown, setA])

theorem loadSlot_cfg (s : St) (i : Bool) (k : Nat) :
    ((loadSlot fixed s i k).1).cfgDisk = s.cfgDisk ∧ ((loadSlot fixed s i k).1).userHle = s.userHle ∧ ((loadSlot fixed s i k).1).userVol = s.userVol := by
  simp only [loadSlot] <;> repeat (first | split | simp_all [powerDown, setA])

theorem refresh_cfg (s : St) (i : Bool) :
    (refresh fixed s i).cfgDisk = s.cfgDisk ∧ (refresh fixed s i).userHle = s.userHle ∧ (refresh fixed s i).userVol = s.userVol := by
  simp only [refresh] <;> repeat (first | split | simp_all [powerDown, setA])

theorem loadRom_cfg (s : St) (i : Bool) (r : Rom) :
    (loadRom fixed s i r).cfgDisk.getD Cfg.dflt = s.cfgDisk.getD Cfg.dflt ∧
    (loadRom fixed s i r).userHle = s.userHle ∧ (loadRom fixed s i r).userVol = s.userVol := by
  have h := flushOut_cfg s i
  simp only [loadRom] <;> repeat (first | split | simp_all [setA, fixed])

theorem launch_cfg (s : St) (i : Bool) (c : Bool) (ro : Option Rom) :
    (launch fixed s i c ro).cfgDisk.getD Cfg.dflt = s.cfgDisk.getD Cfg.dflt ∧
    (launch fixed s i c ro).userHle = s.userHle ∧ (launch fixed s i c ro).userVol = s.userVol := by
  simp only [launch]
  split <;> simp [loadRom_cfg, setA]

theorem loopEnd_cfg (s : St) (i : Bool) :
    (loopEnd fixed s i).cfgDisk = s.cfgDisk ∧ (loopEnd fixed s i).userHle = s.userHle ∧
    (loopEnd fixed s i).userVol = s.userVol := by
  have h := flushOut_cfg s i
  simp only [loopEnd] <;> repeat (first | split | simp_all [setA])

theorem pendStep_cfg (s : St) (i : Bool) (io : Io) :
    (pendStep fixed s i io).cfgDisk = s.cfgDisk ∧ (pendStep fixed s i io).userHle = s.userHle ∧
    (pendStep fixed s i io).userVol = s.userVol := by
  have h1 := fun t => saveSlot_cfg t i 0 io
  have h2 := fun t => loadSlot_cfg t i 0
  simp only [pendStep] <;> repeat (first | split | simp_all [setA])

theorem cfgInv_congr {s t : St} (h : CfgInv s) (h1 : t.cfgDisk.getD Cfg.dflt = s.cfgDisk.getD Cfg.dflt)
    (h2 : t.userHle = s.userHle) (h3 : t.userVol = s.userVol) : CfgInv t := by
  unfold CfgInv at *; rw [h1, h2, h3]; exact h

theorem step_cfg (s : St) (e : Ev) (h : CfgInv s) : CfgInv (step fixed s e) := by
  cases e <;> simp only [step, at_, click] <;> repeat' split
  all_goals first
    | exact h
    | (apply cfgInv_congr h <;>
        simp_all [launch_cfg, loadRom_cfg, flushFrame_cfg, saveSlot_cfg, loadSlot_cfg, refresh_cfg,
          loopEnd_cfg, pendStep_cfg, setA] <;> done)
    | (simp_all [CfgInv, setA, fixed])

/-- **Proved (fixed):** the config file only ever holds what the user chose in
    Settings; a command-line flag, and a second window's stale copy, never
    reach it. -/
theorem cfg_ok {s : St} (h : Reachable fixed s) : CfgInv s := by
  induction h with
  | init => simp [CfgInv, init, Cfg.dflt]
  | step e _ ih => exact step_cfg _ e ih

end Cfg

/-! ## The fixed code: save-state files are named by the game they hold -/

section StIdent

/-- Every `.state` file sits under its own game's name, and no save has
    replaced another game's state. -/
def StInv (s : St) : Prop :=
  s.foreign = [] ∧ ∀ p f, s.st p = some f → f.ident = p.1

theorem flushFrame_st (s : St) (i : Bool) (io : Io) :
    (flushFrame fixed s i io).st = s.st ∧ (flushFrame fixed s i io).foreign = s.foreign := by
  cases io <;> simp only [flushFrame, wr, fixed_atomic, cuts_true] <;>
    repeat (first | split | simp_all [powerDown, setA])

theorem flushOut_st (s : St) (i : Bool) :
    (flushOut fixed s i).st = s.st ∧ (flushOut fixed s i).foreign = s.foreign := by
  simp only [flushOut] <;> repeat (first | split | simp_all [powerDown, setA])

theorem loadSlot_st (s : St) (i : Bool) (k : Nat) :
    ((loadSlot fixed s i k).1).st = s.st ∧ ((loadSlot fixed s i k).1).foreign = s.foreign := by
  simp only [loadSlot] <;> repeat (first | split | simp_all [powerDown, setA])

theorem refresh_st (s : St) (i : Bool) :
    (refresh fixed s i).st = s.st ∧ (refresh fixed s i).foreign = s.foreign := by
  simp only [refresh] <;> repeat (first | split | simp_all [powerDown, setA])

theorem loadRom_st (s : St) (i : Bool) (r : Rom) :
    (loadRom fixed s i r).st = s.st ∧ (loadRom fixed s i r).foreign = s.foreign := by
  have h := flushOut_st s i
  simp only [loadRom] <;> repeat (first | split | simp_all [setA])

theorem launch_st (s : St) (i : Bool) (c : Bool) (ro : Option Rom) :
    (launch fixed s i c ro).st = s.st ∧ (launch fixed s i c ro).foreign = s.foreign := by
  simp only [launch]
  split <;> simp [loadRom_st, setA]

theorem loopEnd_st (s : St) (i : Bool) :
    (loopEnd fixed s i).st = s.st ∧ (loopEnd fixed s i).foreign = s.foreign := by
  have h := flushOut_st s i
  simp only [loopEnd] <;> repeat (first | split | simp_all [setA])

theorem stInv_congr {s t : St} (h : StInv s) (h1 : t.st = s.st) (h2 : t.foreign = s.foreign) :
    StInv t := by
  unfold StInv at *; rw [h1, h2]; exact h

theorem differs_st {s : St} (h : ∀ p f, s.st p = some f → f.ident = p.1) (r : Rom)
    (k : Nat) : differs (s.st (stPath fixed r k)) StF.ident r.game = false := by
  unfold differs
  split
  · rename_i f hf
    have := h _ _ hf
    simp [stPath, fixed] at this
    simp [this]
  · rfl

theorem st_upd_ok {s : St} (hs : ∀ p f, s.st p = some f → f.ident = p.1) (r : Rom)
    (k : Nat) (c : Core) :
    ∀ q f, upd s.st (stPath fixed r k) (some ⟨r.game, c, true⟩) q = some f → f.ident = q.1 := by
  intro q f hq
  simp only [upd_apply] at hq
  split at hq
  · rename_i hqe
    subst hqe; simp at hq; subst hq; simp [stPath, fixed]
  · exact hs q f hq

theorem saveSlot_stInv (s : St) (i : Bool) (k : Nat) (io : Io) (h : StInv s) :
    StInv (saveSlot fixed s i k io) := by
  obtain ⟨hf, hs⟩ := h
  cases hcur : (s.app i).cur with
  | none => simp only [saveSlot, hcur]; exact ⟨hf, hs⟩
  | some r =>
    cases hcore : (s.app i).core with
    | none => simp only [saveSlot, hcur, hcore]; exact ⟨hf, hs⟩
    | some c =>
      have hd := differs_st hs r k
      have hup := st_upd_ok hs r k c
      cases io <;> simp [saveSlot, hcur, hcore, hd, wr, powerDown] <;> exact ⟨hf, by assumption⟩

theorem refresh_stInv {s : St} (i : Bool) (h : StInv s) : StInv (refresh fixed s i) :=
  stInv_congr h (refresh_st s i).1 (refresh_st s i).2

theorem pendStep_stInv (s : St) (i : Bool) (io : Io) (h : StInv s) :
    StInv (pendStep fixed s i io) := by
  simp only [pendStep]
  split
  · exact stInv_congr h rfl rfl
  · generalize hs1 : (if (s.app i).pendSave = true then _ else s) = s1
    have h1 : StInv s1 := by
      subst hs1; split
      · refine stInv_congr (saveSlot_stInv _ i 0 io ?_) rfl rfl
        exact stInv_congr h rfl rfl
      · exact h
    split
    · exact h1
    · generalize hs2 : (if (s1.app i).pendLoad = true then _ else s1) = s2
      have h2 : StInv s2 := by
        subst hs2; split
        · have := loadSlot_st (setA s1 i { s1.app i with pendLoad := false }) i 0
          split
          · exact stInv_congr h1 this.1 this.2
          · exact stInv_congr h1 this.1 this.2
        · exact h1
      exact stInv_congr h2 rfl rfl

theorem stInv_del {s : St} (h : StInv s) (p : StPath) : StInv { s with st := upd s.st p none } := by
  refine ⟨h.1, fun q f hq => ?_⟩
  simp only [upd_apply] at hq
  split at hq
  · cases hq
  · exact h.2 q f hq

theorem step_stInv (s : St) (e : Ev) (h : StInv s) : StInv (step fixed s e) := by
  cases e <;> simp only [step, at_, click] <;> repeat' split
  all_goals first
    | exact h
    | exact pendStep_stInv _ _ _ h
    | (apply stInv_congr h <;>
        simp_all [launch_st, loadRom_st, flushFrame_st, loadSlot_st, refresh_st, loopEnd_st, setA]
        <;> done)
    | exact saveSlot_stInv _ _ _ _ (stInv_congr h rfl rfl)
    | exact refresh_stInv _ (saveSlot_stInv _ _ _ _ (stInv_congr h rfl rfl))
    | exact refresh_stInv _ (stInv_del (stInv_congr h rfl rfl) _)

/-- **Proved (fixed):** every save-state file holds a state of the game it
    is named after, and no save ever replaces another game's state. -/
theorem st_ok {s : St} (h : Reachable fixed s) : StInv s := by
  induction h with
  | init => exact ⟨rfl, fun p f hp => by simp [init] at hp⟩
  | step e _ ih => exact step_stInv _ e ih

end StIdent

/-! ## The fixed code: rewind never crosses a state load -/

section Rewind

/-- The timelines of an app's core and of its rewind ring. -/
def lr (a : App) : Option Nat × List Nat := (a.core.map Core.line, a.rewind.map Core.line)

/-- Every snapshot in the ring is from the core's own timeline. -/
def RewOK (a : App) : Prop := ∀ l, (lr a).1 = some l → ∀ x ∈ (lr a).2, x = l

def RewInv (s : St) : Prop := s.staleRewind = 0 ∧ ∀ j, RewOK (s.app j)

theorem rewInv_of {s t : St} (h : RewInv s) (h1 : t.staleRewind = s.staleRewind)
    (h2 : ∀ j, lr (t.app j) = lr (s.app j)) : RewInv t := by
  refine ⟨h1 ▸ h.1, fun j => ?_⟩
  unfold RewOK; rw [h2 j]; exact h.2 j

theorem rewInv_fresh {s t : St} (i : Bool) (h : RewInv s) (h1 : t.staleRewind = s.staleRewind)
    (h2 : ∀ j, j ≠ i → lr (t.app j) = lr (s.app j)) (h3 : (t.app i).rewind = []) : RewInv t := by
  refine ⟨h1 ▸ h.1, fun j => ?_⟩
  by_cases hj : j = i
  · subst hj; intro l _ x hx; simp [lr, h3] at hx
  · unfold RewOK; rw [h2 j hj]; exact h.2 j

theorem flushFrame_lr (s : St) (i : Bool) (io : Io) :
    (flushFrame fixed s i io).staleRewind = s.staleRewind ∧ ∀ j, lr ((flushFrame fixed s i io).app j) = lr (s.app j) := by
  cases io <;> simp only [flushFrame, wr, fixed_atomic, cuts_true] <;>
    repeat (first | split | simp_all [powerDown, setA, lr, upd_apply])

theorem flushOut_lr (s : St) (i : Bool) :
    (flushOut fixed s i).staleRewind = s.staleRewind ∧ ∀ j, lr ((flushOut fixed s i).app j) = lr (s.app j) := by
  simp only [flushOut] <;> repeat (first | split | simp_all [powerDown, setA, lr, upd_apply])

theorem saveSlot_lr (s : St) (i : Bool) (k : Nat) (io : Io) :
    (saveSlot fixed s i k io).staleRewind = s.staleRewind ∧ ∀ j, lr ((saveSlot fixed s i k io).app j) = lr (s.app j) := by
  cases io <;> simp only [saveSlot, wr, fixed_atomic, cuts_true] <;>
    repeat (first | split | simp_all [powerDown, setA, lr, upd_apply])

theorem refresh_lr (s : St) (i : Bool) :
    (refresh fixed s i).staleRewind = s.staleRewind ∧ ∀ j, lr ((refresh fixed s i).app j) = lr (s.app j) := by
  simp only [refresh] <;> repeat (first | split | simp_all [powerDown, setA, lr, upd_apply])


theorem rewInv_setA {s : St} (i : Bool) {a : App} (h : RewInv s) (ha : RewOK a) :
    RewInv (setA s i a) := by
  refine ⟨h.1, fun j => ?_⟩
  simp only [setA_app, upd_apply]
  split
  · exact ha
  · exact h.2 j

theorem rewOK_of {a b : App} (h : RewOK a) (e : lr b = lr a) : RewOK b := by
  unfold RewOK; rw [e]; exact h

theorem rewInv_setA_lr {s : St} (i : Bool) {a : App} (h : RewInv s) (e : lr a = lr (s.app i)) :
    RewInv (setA s i a) := rewInv_setA i h (rewOK_of (h.2 i) e)

theorem rewInv_ff {s : St} (i : Bool) (io : Io) (h : RewInv s) : RewInv (flushFrame fixed s i io) :=
  rewInv_of h (flushFrame_lr s i io).1 (flushFrame_lr s i io).2
theorem rewInv_fo {s : St} (i : Bool) (h : RewInv s) : RewInv (flushOut fixed s i) :=
  rewInv_of h (flushOut_lr s i).1 (flushOut_lr s i).2
theorem rewInv_ss {s : St} (i : Bool) (k : Nat) (io : Io) (h : RewInv s) :
    RewInv (saveSlot fixed s i k io) :=
  rewInv_of h (saveSlot_lr s i k io).1 (saveSlot_lr s i k io).2
theorem rewInv_rf {s : St} (i : Bool) (h : RewInv s) : RewInv (refresh fixed s i) :=
  rewInv_of h (refresh_lr s i).1 (refresh_lr s i).2

theorem loadRom_rew (s : St) (i : Bool) (r : Rom) (h : RewInv s) : RewInv (loadRom fixed s i r) := by
  have h0 := rewInv_fo i h
  simp only [loadRom]
  generalize flushOut fixed s i = s0 at h0 ⊢
  split
  · exact h0
  · refine rewInv_setA i ?_ ?_
    · apply rewInv_of h0 <;> (try intro) <;> repeat (first | split | simp_all)
    · intro l _ x hx; simp [lr] at hx

theorem rewOK_empty (a : App) (h : a.rewind = []) : RewOK a := by
  intro l _ x hx; simp [lr, h] at hx

theorem launch_rew (s : St) (i : Bool) (c : Bool) (ro : Option Rom) (h : RewInv s) :
    RewInv (launch fixed s i c ro) := by
  simp only [launch]
  split
  · exact loadRom_rew _ i _ (rewInv_setA i h (rewOK_empty _ rfl))
  · exact rewInv_setA i h (rewOK_empty _ rfl)

theorem loadSlot_rew (s : St) (i : Bool) (k : Nat) (h : RewInv s) :
    RewInv (loadSlot fixed s i k).1 := by
  simp only [loadSlot]
  repeat' split
  all_goals first
    | exact h
    | (refine rewInv_setA i ⟨h.1, h.2⟩ ?_
       intro l _ x hx; simp_all [lr, fixed])

theorem loopEnd_rew (s : St) (i : Bool) (h : RewInv s) : RewInv (loopEnd fixed s i) := by
  simp only [loopEnd]
  split
  · exact rewInv_setA_lr i h rfl
  · exact rewInv_setA_lr i (rewInv_fo i h) rfl

theorem pendStep_rew (s : St) (i : Bool) (io : Io) (h : RewInv s) : RewInv (pendStep fixed s i io) := by
  simp only [pendStep]
  split
  · exact rewInv_setA_lr i h rfl
  · generalize hs1 : (if (s.app i).pendSave = true then _ else s) = s1
    have h1 : RewInv s1 := by
      subst hs1; split
      · exact rewInv_setA_lr i (rewInv_ss i 0 io (rewInv_setA_lr i h rfl)) rfl
      · exact h
    split
    · exact h1
    · generalize hs2 : (if (s1.app i).pendLoad = true then _ else s1) = s2
      have h2 : RewInv s2 := by
        subst hs2; split
        · have := loadSlot_rew _ i 0 (rewInv_setA_lr i h1 (a := { s1.app i with pendLoad := false }) rfl)
          split
          · exact this
          · exact rewInv_setA_lr i this rfl
        · exact h1
      exact rewInv_setA_lr i h2 rfl

theorem rewOK_frame (a : App) (c : Core) (hc : a.core = some c) (h : RewOK a) (c' : Core)
    (hl : c'.line = c.line) (ph : Phase) (m : Bool) (rw : List Core)
    (hrw : rw = a.rewind ∨ rw = c' :: a.rewind) :
    RewOK { a with core := some c', pc := ph, mid := m, rewind := rw } := by
  have hok : ∀ y ∈ a.rewind, y.line = c.line := fun y hy =>
    h c.line (by simp [lr, hc]) y.line (List.mem_map_of_mem hy)
  intro l hl' x hx
  simp only [lr, Option.map_some, Option.some.injEq] at hl'
  subst hl'
  simp only [lr, List.mem_map] at hx
  obtain ⟨y, hy, rfl⟩ := hx
  rcases hrw with rfl | rfl
  · rw [hl]; exact hok y hy
  · simp only [List.mem_cons] at hy
    rcases hy with rfl | hy
    · rfl
    · rw [hl]; exact hok y hy

theorem rewOK_pop (a : App) (hd : Core) (tl : List Core) (c : Core) (hr : a.rewind = hd :: tl)
    (hc : a.core = some c) (h : RewOK a) :
    hd.line = c.line ∧ RewOK { a with core := some { hd with dirty := true }, rewind := tl, pc := .pend } := by
  have hok : ∀ y ∈ a.rewind, y.line = c.line := fun y hy =>
    h c.line (by simp [lr, hc]) y.line (List.mem_map_of_mem hy)
  have hh : hd.line = c.line := hok hd (by simp [hr])
  refine ⟨hh, ?_⟩
  intro l hl' x hx
  simp only [lr, Option.map_some, Option.some.injEq] at hl'
  subst hl'
  simp only [lr, List.mem_map] at hx
  obtain ⟨y, hy, rfl⟩ := hx
  rw [hh]; exact hok y (by simp [hr, hy])

theorem step_rew (s : St) (e : Ev) (h : RewInv s) : RewInv (step fixed s e) := by
  cases e
  case frame i w io =>
    simp only [step]
    split
    · have h1 := rewInv_ff i io h
      generalize flushFrame fixed s i io = s1 at h1 ⊢
      split
      · exact h1
      · split
        · rename_i c hc
          exact rewInv_setA i ⟨h1.1, h1.2⟩
            (rewOK_frame _ c hc (h1.2 i) _ (by split <;> rfl) _ _ _ (by split <;> simp))
        · exact h1
    · exact h
  case rewindPop i =>
    simp only [step]
    split
    · split
      · rename_i hd tl c hr hc
        obtain ⟨hh, hok⟩ := rewOK_pop _ hd tl c hr hc (h.2 i)
        exact rewInv_setA i ⟨by simp [h.1, hh], h.2⟩ hok
      · exact rewInv_setA_lr i h rfl
    · exact h
  case linkUp i =>
    simp only [step, at_]
    repeat' split
    all_goals first
      | exact h
      | exact rewInv_setA_lr i h rfl
      | exact rewInv_setA i h (by intro l _ x hx; simp [lr] at hx)
  all_goals simp only [step, at_, click] <;> repeat' split
  all_goals first
    | exact h
    | exact rewInv_setA_lr _ h rfl
    | exact launch_rew _ _ _ _ h
    | exact loadRom_rew _ _ _ h
    | exact pendStep_rew _ _ _ h
    | exact loopEnd_rew _ _ h
    | exact (loadSlot_rew _ _ _ h)
    | exact rewInv_of h rfl (fun _ => rfl)
    | exact rewInv_rf _ (rewInv_setA_lr _ h rfl)
    | exact rewInv_setA_lr _ (rewInv_rf _ h) rfl
    | exact rewInv_ss _ _ _ (rewInv_of h rfl (fun _ => rfl))
    | exact rewInv_rf _ (rewInv_ss _ _ _ (rewInv_of h rfl (fun _ => rfl)))
    | exact rewInv_rf _ (rewInv_of h rfl (fun _ => rfl))

/-- **Proved (fixed):** hold-to-rewind only ever steps back through the
    loaded state's own past. -/
theorem rewind_ok {s : St} (h : Reachable fixed s) : RewInv s := by
  induction h with
  | init => exact ⟨rfl, fun j l hl => by simp [init, lr, App.off] at hl⟩
  | step e _ ih => exact step_rew _ e ih

end Rewind

/-! ## The fixed code: two windows, one file each; the grid shows the truth -/

section Excl

/-- Two live windows never run games whose files collide. -/
def Excl (s : St) : Prop :=
  ∀ j r r', live (s.app j) = true → live (s.app !j) = true → (s.app j).cur = some r →
    (s.app !j).cur = some r' → conflict r r' = false

/-- A live window's `.sav` is exactly what it last read or wrote. -/
def BaseJ (s : St) (j : Bool) : Prop :=
  live (s.app j) = true → ∀ r, (s.app j).cur = some r →
    s.sav (savPath r) = (s.app j).base

/-- A live window whose Save States grid is marked fresh shows its current
    game's slot files, exactly as they are on disk. -/
def ViewJ (s : St) (j : Bool) : Prop :=
  live (s.app j) = true → ∀ r, (s.app j).cur = some r → (s.app j).wasOpen = true →
    (s.app j).view = some r ∧ ∀ k, (s.app j).viewFiles k = s.st (stPath fixed r k)

/-- In the window phase an open Save States window has been refreshed. -/
def WinJ (s : St) (j : Bool) : Prop :=
  (s.app j).pc = .win → (s.app j).win = true → (s.app j).wasOpen = true

def FI (s : St) : Prop :=
  Excl s ∧ (∀ j, BaseJ s j) ∧ (∀ j, ViewJ s j) ∧ (∀ j, WinJ s j) ∧ s.clobbers = [] ∧ s.blind = []

/-- `FI` with `ViewJ` for `i` left out: what holds between a change to `i`'s
    own slot files and the refresh (or `mark_stale`) that follows it. -/
def FIx (s : St) (i : Bool) : Prop :=
  Excl s ∧ (∀ j, BaseJ s j) ∧ ViewJ s (!i) ∧ (∀ j, WinJ s j) ∧ s.clobbers = [] ∧ s.blind = []

theorem conflict_symm (r r' : Rom) : conflict r r' = conflict r' r := by
  have e : ∀ x y : Nat, (x == y) = (y == x) := fun x y => by
    by_cases h : x = y
    · subst h; rfl
    · rw [beq_false_of_ne h, beq_false_of_ne (Ne.symm h)]
  simp only [conflict, sameFiles, sameStates, e r.dir, e r.base, e r.game, e r.ext]

theorem savPath_eq {r r' : Rom} (h : savPath r = savPath r') : conflict r r' = true := by
  simp [savPath] at h
  obtain ⟨h1, h2⟩ := h
  simp [conflict, sameFiles, h1, h2]

theorem stPath_eq {r r' : Rom} {k k' : Nat}
    (h : stPath fixed r k = stPath fixed r' k') : conflict r r' = true := by
  simp [stPath, fixed] at h
  obtain ⟨h1, h2, h3, _⟩ := h
  simp [conflict, sameStates, h1, h2, h3]

/-- Two live windows' files are distinct. -/
theorem distinct {s : St} (h : Excl s) {j : Bool} {r r' : Rom} (hl : live (s.app j) = true)
    (hl' : live (s.app !j) = true) (hc : (s.app j).cur = some r) (hc' : (s.app !j).cur = some r') :
    savPath r ≠ savPath r' ∧ ∀ k k', stPath fixed r k ≠ stPath fixed r' k' := by
  constructor
  · intro he
    have := h j r r' hl hl' hc hc'
    rw [savPath_eq he] at this; cases this
  · intro k k' he
    have := h j r r' hl hl' hc hc'
    rw [stPath_eq he] at this; cases this

/-- What `FI` reads of an app, apart from `base`. -/
structure SameNB (a b : App) : Prop where
  live : live a = live b
  cur : a.cur = b.cur
  view : a.view = b.view
  files : a.viewFiles = b.viewFiles
  wasOpen : a.wasOpen = b.wasOpen
  win : a.win = b.win
  pcwin : a.pc = .win → b.pc = .win

theorem SameNB.rfl' (a : App) : SameNB a a := ⟨rfl, rfl, rfl, rfl, rfl, rfl, id⟩

theorem sameNB_upd {f : Bool → App} {i : Bool} {a : App} (h : SameNB a (f i)) (j : Bool) :
    SameNB (upd f i a j) (f j) := by
  simp only [upd_apply]
  split
  · rename_i hj; subst hj; exact h
  · exact SameNB.rfl' _

theorem other_eq {i j : Bool} (h : j ≠ i) : j = !i := by cases i <;> cases j <;> simp_all

/-- `FI` moves along any change that keeps what it reads of every app (but
    `base`), keeps the state files and ghosts, and re-establishes `BaseJ`. -/
theorem fi_transfer {s t : St} (h : FI s) (hA : ∀ j, SameNB (t.app j) (s.app j))
    (hB : ∀ j, BaseJ t j) (hst : t.st = s.st) (hc : t.clobbers = s.clobbers)
    (hb : t.blind = s.blind) : FI t := by
  obtain ⟨hx, _, hv, hw, hcl, hbl⟩ := h
  refine ⟨?_, hB, ?_, ?_, hc ▸ hcl, hb ▸ hbl⟩
  · intro j r r' hl hl' hcur hcur'
    rw [(hA j).live] at hl; rw [(hA !j).live] at hl'
    rw [(hA j).cur] at hcur; rw [(hA !j).cur] at hcur'
    exact hx j r r' hl hl' hcur hcur'
  · intro j hl r hcur hwo
    rw [(hA j).live] at hl; rw [(hA j).cur] at hcur; rw [(hA j).wasOpen] at hwo
    rw [(hA j).view, (hA j).files, hst]
    exact hv j hl r hcur hwo
  · intro j hpc hwin
    have hpc' := (hA j).pcwin hpc; rw [(hA j).win] at hwin
    rw [(hA j).wasOpen]
    exact hw j hpc' hwin

theorem base_congr {s t : St} (hbase : ∀ j, BaseJ s j) (hA : ∀ j, SameNB (t.app j) (s.app j))
    (hb : ∀ j, (t.app j).base = (s.app j).base) (hsav : t.sav = s.sav) : ∀ j, BaseJ t j := by
  intro j hl r hc
  rw [(hA j).live] at hl; rw [(hA j).cur] at hc
  rw [hsav, hb j]
  exact hbase j hl r hc

theorem fi_congr {s t : St} (h : FI s) (hA : ∀ j, SameNB (t.app j) (s.app j))
    (hb : ∀ j, (t.app j).base = (s.app j).base) (hsav : t.sav = s.sav)
    (hst : t.st = s.st) (hc : t.clobbers = s.clobbers) (hbl : t.blind = s.blind) : FI t :=
  fi_transfer h hA (base_congr h.2.1 hA hb hsav) hst hc hbl

theorem fi_setA {s : St} {i : Bool} {a : App} (h : FI s) (ha : SameNB a (s.app i))
    (hb : a.base = (s.app i).base) : FI (setA s i a) :=
  fi_congr h (sameNB_upd ha) (fun j => by simp only [setA_app, upd_apply]; split <;> simp_all) rfl rfl rfl rfl

theorem fi_powerDown {s : St} (h : FI s) : FI (powerDown s) := by
  obtain ⟨_, _, _, _, hcl, hbl⟩ := h
  refine ⟨?_, ?_, ?_, ?_, hcl, hbl⟩
  · intro j r r' hl; simp [powerDown, live] at hl
  · intro j hl; simp [powerDown, live] at hl
  · intro j hl; simp [powerDown, live] at hl
  · intro j hpc; simp [powerDown] at hpc

/-- A write of `v` to live window `i`'s own `.sav`, recorded as its new base. -/
theorem base_write {s t : St} {i : Bool} {r : Rom} {v : Bat} (hx : Excl s)
    (hbase : ∀ j, BaseJ s j) (hl : live (s.app i) = true) (hc : (s.app i).cur = some r)
    (hA : ∀ j, SameNB (t.app j) (s.app j)) (hbi : (t.app i).base = some v)
    (hbo : (t.app !i).base = (s.app !i).base)
    (hsav : t.sav = upd s.sav (savPath r) (some v)) : ∀ j, BaseJ t j := by
  intro j hl' r1 hc1
  rw [(hA j).live] at hl'; rw [(hA j).cur] at hc1
  rw [hsav]
  by_cases hj : j = i
  · subst hj
    rw [hc] at hc1; cases hc1
    rw [upd_same, hbi]
  · have hj' := other_eq hj; subst hj'
    have hne : savPath r1 ≠ savPath r :=
      Ne.symm (distinct hx hl (by simpa using hl') hc (by simpa using hc1)).1
    simp only [upd_apply, hne, ite_false, hbo]
    exact hbase _ hl' r1 hc1

theorem live_of_pc {a : App} {ph : Phase} (h : a.pc = ph)
    (hp : ph ≠ .off ∧ ph ≠ .dead ∧ ph ≠ .exited) : live a = true := by
  unfold live; rw [h]; cases ph <;> simp_all

/-- The app `i` with only non-`FI` fields and `base` changed. -/
theorem sameNB_upd_i {s : St} {i : Bool} {a : App} (h : SameNB a (s.app i)) :
    ∀ j, SameNB ((setA s i a).app j) (s.app j) := sameNB_upd h

theorem setA_other {s : St} {i : Bool} {a : App} : (setA s i a).app (!i) = s.app (!i) := by
  simp [setA, upd_apply]

theorem setA_self {s : St} {i : Bool} {a : App} : (setA s i a).app i = a := by
  simp [setA]

/-- A flush of window `i`'s dirty battery to its own file (the per-frame
    `etSaves` flush, `flush_gb_save`, and in the fixed code the GBA flush at a
    switch or quit), from a state satisfying `FI`: no clobber, and `FI` again. -/
theorem fi_flushWrite {s : St} {i : Bool} {r : Rom} {b : Bat} (h : FI s)
    (hl : live (s.app i) = true) (hc : (s.app i).cur = some r) (a : App)
    (ha : SameNB a (s.app i)) (hab : a.base = some b) (tr : Nat) :
    FI (setA { s with sav := upd s.sav (savPath r) (some b), truncs := tr } i a) := by
  refine fi_transfer h (sameNB_upd_i ha) ?_ rfl rfl rfl
  exact base_write h.1 h.2.1 hl hc (sameNB_upd_i ha) (by rw [setA_self]; exact hab)
    (by rw [setA_other]) rfl

theorem flushFrame_F {s : St} {i : Bool} (io : Io) (h : FI s) (hpc : (s.app i).pc = .emu) :
    FI (flushFrame fixed s i io) := by
  have hl : live (s.app i) = true := live_of_pc hpc (by simp)
  simp only [flushFrame]
  cases hcur : (s.app i).cur with
  | none => exact h
  | some r =>
    cases hcore : (s.app i).core with
    | none => exact h
    | some c =>
      simp only
      cases hd : c.dirty <;> cases hram : c.ram
      all_goals try exact h
      rename_i bat
      have hb := h.2.1 i hl r hcur
      simp only [hb, ite_true]
      cases io
      all_goals simp only [wr, fixed_atomic, fixed_catchIo, cuts_true, Bool.not_true, Bool.and_false,
        Bool.false_eq_true, ite_false, ite_true, reduceCtorEq]
      · refine fi_flushWrite h hl hcur _ ?_ ?_ _
        · exact ⟨rfl, by simp [hcur], rfl, rfl, rfl, rfl, id⟩
        · simp
      · refine fi_setA (fi_congr h (fun _ => SameNB.rfl' _) (fun _ => rfl) rfl rfl rfl rfl) ?_ ?_
        · exact ⟨rfl, by simp [hcur], rfl, rfl, rfl, rfl, id⟩
        · simp [hb]
      · refine fi_setA (fi_congr h (fun _ => SameNB.rfl' _) (fun _ => rfl) rfl rfl rfl rfl) ?_ ?_
        · exact ⟨rfl, by simp [hcur], rfl, rfl, rfl, rfl, id⟩
        · simp [hb]
      · exact fi_powerDown (fi_congr h (fun _ => SameNB.rfl' _) (fun _ => rfl) rfl rfl rfl rfl)

theorem flushOut_F {s : St} {i : Bool} (h : FI s) (hl : live (s.app i) = true) :
    FI (flushOut fixed s i) := by
  simp only [flushOut]
  cases hcur : (s.app i).cur with
  | none => exact h
  | some r =>
    cases hcore : (s.app i).core with
    | none => exact h
    | some c =>
      simp only
      cases hd : c.dirty <;> cases hram : c.ram
      all_goals try exact h
      rename_i bat
      have hb := h.2.1 i hl r hcur
      simp only [hb, ite_true, fixed_flushGba, Bool.not_true, Bool.and_false, Bool.false_eq_true, ite_false]
      refine fi_flushWrite h hl hcur _ ?_ ?_ s.truncs
      · exact ⟨rfl, by simp [hcur], rfl, rfl, rfl, rfl, id⟩
      · rfl

/-- What `flushOut` leaves of every app: all `FI` reads but `base`, and the phase. -/
theorem flushOut_app (s : St) (i : Bool) (j : Bool) :
    SameNB ((flushOut fixed s i).app j) (s.app j) ∧ ((flushOut fixed s i).app j).pc = (s.app j).pc ∧
    ((flushOut fixed s i).app j).running = (s.app j).running ∧
    (j ≠ i → (flushOut fixed s i).app j = s.app j) := by
  simp only [flushOut]
  repeat' split
  all_goals first
    | exact ⟨SameNB.rfl' _, rfl, rfl, fun _ => rfl⟩
    | (simp only [setA_app, upd_apply]
       split
       · rename_i hj; subst hj
         exact ⟨⟨rfl, rfl, rfl, rfl, rfl, rfl, id⟩, rfl, rfl, fun h => absurd rfl h⟩
       · exact ⟨SameNB.rfl' _, rfl, rfl, fun _ => rfl⟩)

theorem flushOut_rest (s : St) (i : Bool) :
    (flushOut fixed s i).st = s.st ∧ (flushOut fixed s i).blind = s.blind := by
  simp only [flushOut] <;> repeat (first | split | simp_all [setA])

/-- A boot of ROM `r` in live window `i` (not in the window phase), which the
    lock let through (no live window has a colliding game), from a state
    satisfying `FI`. -/
theorem fi_boot {s t : St} {i : Bool} {r : Rom} (h : FI s) (hw : (s.app i).pc ≠ .win)
    (ha_pc : (t.app i).pc = (s.app i).pc) (ha_cur : (t.app i).cur = some r)
    (key : live (s.app !i) = true → ∀ r', (s.app !i).cur = some r' → conflict r r' = false)
    (ha_base : (t.app i).base = s.sav (savPath r)) (ha_wo : (t.app i).wasOpen = false)
    (ho : t.app (!i) = s.app (!i)) (hsav : t.sav = s.sav) (hst : t.st = s.st)
    (hcl : t.clobbers = s.clobbers) (hbl : t.blind = s.blind) : FI t := by
  obtain ⟨hx, hbase, hv, hwj, hcl0, hbl0⟩ := h
  refine ⟨?_, ?_, ?_, ?_, hcl ▸ hcl0, hbl ▸ hbl0⟩
  · intro j r1 r2 hl1 hl2 hc1 hc2
    by_cases hj : j = i
    · subst hj
      rw [ho] at hl2 hc2
      rw [ha_cur] at hc1; cases hc1
      exact key hl2 r2 hc2
    · have hj' := other_eq hj; subst hj'
      simp only [Bool.not_not] at hl2 hc2
      rw [ho] at hl1 hc1
      rw [ha_cur] at hc2; cases hc2
      rw [conflict_symm]; exact key hl1 r1 hc1
  · intro j hl1 r1 hc1
    by_cases hj : j = i
    · subst hj
      rw [ha_cur] at hc1; cases hc1
      rw [hsav, ha_base]
    · have hj' := other_eq hj; subst hj'
      rw [ho] at hl1 hc1 ⊢; rw [hsav]; exact hbase _ hl1 r1 hc1
  · intro j hl1 r1 hc1 hwo
    by_cases hj : j = i
    · subst hj; rw [ha_wo] at hwo; cases hwo
    · have hj' := other_eq hj; subst hj'
      rw [ho] at hl1 hc1 hwo ⊢; rw [hst]; exact hv _ hl1 r1 hc1 hwo
  · intro j hpc hwin
    by_cases hj : j = i
    · subst hj; rw [ha_pc] at hpc; exact absurd hpc hw
    · have hj' := other_eq hj; subst hj'
      rw [ho] at hpc hwin ⊢; exact hwj _ hpc hwin

/-- What `holds` reads is the other window's app. -/
theorem holds_false {s : St} {i : Bool} {same : Rom → Rom → Bool} {r : Rom}
    (h : holds s i same r = false) (hl : live (s.app !i) = true) {r' : Rom}
    (hc : (s.app !i).cur = some r') : same r r' = false := by
  simp only [holds, hl, hc, Bool.true_and] at h; exact h

theorem loadRom_F {s : St} {i : Bool} (r : Rom) (h : FI s) (hl : live (s.app i) = true)
    (hw : (s.app i).pc ≠ .win) : FI (loadRom fixed s i r) := by
  have h0 := flushOut_F h hl
  have hA := flushOut_app s i i
  have hlock : fixed.lock = true := rfl
  simp only [loadRom, hlock, Bool.true_and]
  generalize flushOut fixed s i = s0 at h0 hA ⊢
  split
  · exact h0
  · rename_i hs
    simp only [Bool.not_eq_true] at hs
    refine fi_boot (r := r) h0 (by rw [hA.2.1]; exact hw) ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_
    · simp [setA, upd_apply]
    · simp [setA, upd_apply]
    · exact fun hl' _ hc' => holds_false hs hl' hc'
    all_goals simp [setA, upd_apply, fixed]

theorem fi_to_fix {s : St} (i : Bool) (h : FI s) : FIx s i :=
  ⟨h.1, h.2.1, h.2.2.1 _, h.2.2.2.1, h.2.2.2.2.1, h.2.2.2.2.2⟩

theorem fix_dead {s : St} {i : Bool} (h : FIx s i) (hl : live (s.app i) = false) : FI s := by
  obtain ⟨hx, hb, hv, hw, hc, hbl⟩ := h
  refine ⟨hx, hb, fun j => ?_, hw, hc, hbl⟩
  by_cases hj : j = i
  · subst hj; intro hl'; rw [hl] at hl'; cases hl'
  · have := other_eq hj; subst this; exact hv

/-- An app `i` that is not running (killed or left the loop). -/
theorem fi_offline {s : St} {i : Bool} {a : App} (h : FI s) (hl : live a = false) (hw : a.pc ≠ .win) :
    FI (setA s i a) := by
  obtain ⟨hx, hb, hv, hwj, hc, hbl⟩ := h
  have hi : (setA s i a).app i = a := setA_self
  have ho : (setA s i a).app (!i) = s.app (!i) := setA_other
  refine ⟨?_, ?_, ?_, ?_, hc, hbl⟩
  · intro j r r' hl1 hl2 hc1 hc2
    by_cases hj : j = i
    · subst hj; rw [hi, hl] at hl1; cases hl1
    · have := other_eq hj; subst this
      simp only [Bool.not_not] at hl2; rw [hi, hl] at hl2; cases hl2
  · intro j hl1
    by_cases hj : j = i
    · subst hj; rw [hi, hl] at hl1; cases hl1
    · have := other_eq hj; subst this; rw [ho] at hl1 ⊢; exact hb _ hl1
  · intro j hl1
    by_cases hj : j = i
    · subst hj; rw [hi, hl] at hl1; cases hl1
    · have := other_eq hj; subst this; rw [ho] at hl1 ⊢; exact hv _ hl1
  · intro j hpc
    by_cases hj : j = i
    · subst hj; rw [hi] at hpc; exact absurd hpc hw
    · have := other_eq hj; subst this; rw [ho] at hpc ⊢; exact hwj _ hpc

/-- A fresh app with no game loaded. -/
theorem fi_fresh {s : St} {i : Bool} {a : App} (h : FI s) (hc : a.cur = none) (hw : a.pc ≠ .win) :
    FI (setA s i a) := by
  obtain ⟨hx, hb, hv, hwj, hcl, hbl⟩ := h
  have hi : (setA s i a).app i = a := setA_self
  have ho : (setA s i a).app (!i) = s.app (!i) := setA_other
  refine ⟨?_, ?_, ?_, ?_, hcl, hbl⟩
  · intro j r r' hl1 hl2 hc1 hc2
    by_cases hj : j = i
    · subst hj; rw [hi, hc] at hc1; cases hc1
    · have := other_eq hj; subst this
      simp only [Bool.not_not] at hc2; rw [hi, hc] at hc2; cases hc2
  · intro j hl1 r hc1
    by_cases hj : j = i
    · subst hj; rw [hi, hc] at hc1; cases hc1
    · have := other_eq hj; subst this; rw [ho] at hl1 hc1 ⊢; exact hb _ hl1 r hc1
  · intro j hl1 r hc1
    by_cases hj : j = i
    · subst hj; rw [hi, hc] at hc1; cases hc1
    · have := other_eq hj; subst this; rw [ho] at hl1 hc1 ⊢; exact hv _ hl1 r hc1
  · intro j hpc
    by_cases hj : j = i
    · subst hj; rw [hi] at hpc; exact absurd hpc hw
    · have := other_eq hj; subst this; rw [ho] at hpc ⊢; exact hwj _ hpc

theorem launch_F {s : St} {i : Bool} (c : Bool) (ro : Option Rom) (h : FI s) :
    FI (launch fixed s i c ro) := by
  simp only [launch]
  split
  · rename_i r
    refine loadRom_F r (fi_fresh h rfl (by simp)) ?_ ?_
    · rw [setA_self]; rfl
    · rw [setA_self]; simp
  · exact fi_fresh h rfl (by simp)

theorem loadSlot_F {s : St} (i : Bool) (k : Nat) (h : FI s) : FI (loadSlot fixed s i k).1 := by
  simp only [loadSlot]
  repeat' split
  all_goals first
    | exact h
    | exact fi_setA (fi_congr h (fun _ => SameNB.rfl' _) (fun _ => rfl) rfl rfl rfl rfl)
        ⟨rfl, rfl, rfl, rfl, rfl, rfl, id⟩ rfl

/-- Replacing app `i` by one that keeps what `Excl` and `BaseJ` read and
    satisfies `ViewJ i` and `WinJ i` itself, from `FIx s i`. -/
theorem fix_setA_view {s : St} {i : Bool} {a : App} (h : FIx s i)
    (hl : live a = live (s.app i)) (hc : a.cur = (s.app i).cur)
    (hb : a.base = (s.app i).base)
    (hW : a.pc = .win → a.win = true → a.wasOpen = true)
    (hV : live a = true → ∀ r, a.cur = some r → a.wasOpen = true →
      a.view = some r ∧ ∀ k, a.viewFiles k = s.st (stPath fixed r k)) :
    FI (setA s i a) := by
  obtain ⟨hx, hbj, hv, hwj, hcl, hbl⟩ := h
  have hi : (setA s i a).app i = a := setA_self
  have ho : (setA s i a).app (!i) = s.app (!i) := setA_other
  refine ⟨?_, ?_, ?_, ?_, hcl, hbl⟩
  · intro j r1 r2 hl1 hl2 hc1 hc2
    by_cases hj : j = i
    · subst hj
      rw [hi] at hl1 hc1; rw [ho] at hl2 hc2
      rw [hl] at hl1; rw [hc] at hc1
      exact hx j r1 r2 hl1 hl2 hc1 hc2
    · have := other_eq hj; subst this
      simp only [Bool.not_not] at hl2 hc2
      rw [hi] at hl2 hc2; rw [ho] at hl1 hc1
      rw [hl] at hl2; rw [hc] at hc2
      exact hx (!i) r1 r2 hl1 (by simpa using hl2) hc1 (by simpa using hc2)
  · intro j hl1 r1 hc1
    by_cases hj : j = i
    · subst hj
      rw [hi] at hl1 hc1 ⊢; rw [hl] at hl1; rw [hc] at hc1; rw [hb]
      exact hbj j hl1 r1 hc1
    · have := other_eq hj; subst this
      rw [ho] at hl1 hc1 ⊢; exact hbj _ hl1 r1 hc1
  · intro j
    by_cases hj : j = i
    · subst hj; unfold ViewJ; rw [hi]; exact hV
    · have := other_eq hj; subst this
      intro hl1 r1 hc1 hw1; rw [ho] at hl1 hc1 hw1 ⊢; exact hv hl1 r1 hc1 hw1
  · intro j
    by_cases hj : j = i
    · subst hj; unfold WinJ; rw [hi]; exact hW
    · have := other_eq hj; subst this
      intro hpc1 hwin1; rw [ho] at hpc1 hwin1 ⊢; exact hwj _ hpc1 hwin1

theorem fix_refresh {s : St} {i : Bool} (h : FIx s i) : FI (refresh fixed s i) := by
  simp only [refresh]
  split
  · rename_i r hcur
    refine fix_setA_view h rfl rfl rfl (h.2.2.2.1 i) ?_
    intro _ r1 hc1 _
    simp only [hcur] at hc1; cases hc1
    exact ⟨rfl, fun _ => rfl⟩
  · rename_i hcur
    refine fix_setA_view h rfl rfl rfl (h.2.2.2.1 i) ?_
    intro _ r1 hc1; simp only [hcur] at hc1; cases hc1

theorem fi_refresh {s : St} (i : Bool) (h : FI s) : FI (refresh fixed s i) := fix_refresh (fi_to_fix i h)

/-- `mark_stale` (or a load_rom in the fixed code) outside the window phase. -/
theorem fix_stale {s : St} {i : Bool} (h : FIx s i) (hw : (s.app i).pc ≠ .win) (n : Bool) :
    FI (setA s i { s.app i with wasOpen := false, notice := n }) :=
  fix_setA_view h rfl rfl rfl (fun hp => absurd hp hw) (fun _ _ _ hwo => by cases hwo)

theorem fi_allDead {t : St} (hd : ∀ j, (t.app j).pc = .dead) (hcl : t.clobbers = [])
    (hbl : t.blind = []) : FI t := by
  have hl : ∀ j, live (t.app j) = false := fun j => by simp [live, hd j]
  refine ⟨?_, ?_, ?_, ?_, hcl, hbl⟩
  · intro j r r' hl1; rw [hl] at hl1; cases hl1
  · intro j hl1; rw [hl] at hl1; cases hl1
  · intro j hl1; rw [hl] at hl1; cases hl1
  · intro j hpc; rw [hd] at hpc; cases hpc

/-- A change to window `i`'s own slot file `stPath r k` only. -/
theorem fix_stWrite {s t : St} {i : Bool} {r : Rom} {k : Nat} (h : FI s)
    (hl : live (s.app i) = true) (hc : (s.app i).cur = some r)
    (happ : t.app = s.app) (hsav : t.sav = s.sav) (hcl : t.clobbers = s.clobbers)
    (hbl : t.blind = s.blind) (hst : ∀ q, q ≠ stPath fixed r k → t.st q = s.st q) :
    FIx t i := by
  obtain ⟨hx, hb, hv, hw, hcl0, hbl0⟩ := h
  refine ⟨?_, ?_, ?_, ?_, hcl ▸ hcl0, hbl ▸ hbl0⟩
  · intro j; rw [happ]; exact hx j
  · intro j hl1 r1 hc1; rw [happ] at hl1 hc1 ⊢; rw [hsav]; exact hb j hl1 r1 hc1
  · intro hl1 r1 hc1 hwo
    rw [happ] at hl1 hc1 hwo ⊢
    obtain ⟨h1, h2⟩ := hv (!i) hl1 r1 hc1 hwo
    refine ⟨h1, fun k' => ?_⟩
    rw [h2 k', hst]
    exact (distinct hx hl hl1 hc hc1).2 k k' ∘ Eq.symm
  · intro j; unfold WinJ; rw [happ]; exact hw j

theorem saveSlot_F {s : St} {i : Bool} (k : Nat) (io : Io) (h : FI s) (hl : live (s.app i) = true) :
    FIx (saveSlot fixed s i k io) i := by
  simp only [saveSlot]
  cases hcur : (s.app i).cur with
  | none => exact fi_to_fix i h
  | some r =>
    cases hcore : (s.app i).core with
    | none => exact fi_to_fix i h
    | some c =>
      simp only
      have hst : ∀ (v : Option StF), ∀ q, q ≠ stPath fixed r k →
          upd s.st (stPath fixed r k) v q = s.st q := fun v q hq => by
        simp only [upd_apply, hq, ite_false]
      cases io <;> simp only [wr, fixed_atomic, ite_true, reduceCtorEq, ite_false]
      all_goals first
        | exact fix_stWrite (k := k) h hl hcur rfl rfl rfl rfl (hst _)
        | exact fix_stWrite (k := k) h hl hcur rfl rfl rfl rfl (fun _ _ => rfl)
        | exact fi_to_fix i (fi_allDead (fun j => rfl) h.2.2.2.2.1 h.2.2.2.2.2)

theorem saveSlot_pc (s : St) (i : Bool) (k : Nat) (io : Io) (j : Bool) :
    ((saveSlot fixed s i k io).app j).pc = (s.app j).pc ∨ ((saveSlot fixed s i k io).app j).pc = .dead := by
  simp only [saveSlot]
  cases io <;> simp only [wr, fixed_atomic, ite_true, reduceCtorEq, ite_false] <;> repeat' split
  all_goals first | exact Or.inl rfl | exact Or.inr rfl

theorem fix_saved {s : St} {i : Bool} (h : FIx s i) :
    FI (if (s.app i).pc = .dead then s else refresh fixed s i) := by
  split
  · exact fix_dead h (by simp [live, *])
  · exact fix_refresh h

theorem loopEnd_F {s : St} {i : Bool} (h : FI s) (hl : live (s.app i) = true) :
    FI (loopEnd fixed s i) := by
  simp only [loopEnd]
  split
  · exact fi_setA h ⟨by rw [hl]; rfl, rfl, rfl, rfl, rfl, rfl, fun hp => by cases hp⟩ rfl
  · exact fi_offline (flushOut_F h hl) (by simp [live]) (by simp)

theorem pendStep_F {s : St} {i : Bool} (io : Io) (h : FI s) (hpc : (s.app i).pc = .pend) :
    FI (pendStep fixed s i io) := by
  have hl : live (s.app i) = true := live_of_pc hpc (by simp)
  simp only [pendStep]
  split
  · exact fi_setA h ⟨by rw [hl]; rfl, rfl, rfl, rfl, rfl, rfl, fun hp => by cases hp⟩ rfl
  · generalize hs1 : (if (s.app i).pendSave = true then _ else s) = s1
    have h1 : FI s1 ∧ ((s1.app i).pc = .pend ∨ (s1.app i).pc = .dead) := by
      subst hs1; split
      · have h0 : FI (setA s i { s.app i with pendSave := false }) :=
          fi_setA h ⟨rfl, rfl, rfl, rfl, rfl, rfl, id⟩ rfl
        have hs := saveSlot_F 0 io h0 (by rw [setA_self]; exact hl)
        have hp := saveSlot_pc (setA s i { s.app i with pendSave := false }) i 0 io i
        have hx : ((setA s i { s.app i with pendSave := false }).app i).pc = .pend := by
          rw [setA_self]; exact hpc
        rw [hx] at hp
        refine ⟨fix_stale hs (by rcases hp with hp | hp <;> rw [hp] <;> simp) _, ?_⟩
        rw [setA_self]; exact hp
      · exact ⟨h, Or.inl hpc⟩
    obtain ⟨h1, hp1⟩ := h1
    split
    · exact h1
    · rename_i hnd
      have hp1' : (s1.app i).pc = .pend := by rcases hp1 with hp1 | hp1; exact hp1; exact absurd hp1 hnd
      generalize hs2 : (if (s1.app i).pendLoad = true then _ else s1) = s2
      have h2 : FI s2 ∧ (s2.app i).pc = .pend := by
        subst hs2; split
        · have h0 : FI (setA s1 i { s1.app i with pendLoad := false }) :=
            fi_setA h1 ⟨rfl, rfl, rfl, rfl, rfl, rfl, id⟩ rfl
          have hL := loadSlot_F i 0 h0
          have hLp : ((loadSlot fixed (setA s1 i { s1.app i with pendLoad := false }) i 0).1.app i).pc =
              .pend := by
            simp only [loadSlot]; repeat' split
            all_goals simp [setA, hp1']
          split
          · exact ⟨hL, hLp⟩
          · exact ⟨fi_setA hL ⟨rfl, rfl, rfl, rfl, rfl, rfl, id⟩ rfl, by rw [setA_self]; exact hLp⟩
        · exact ⟨h1, hp1'⟩
      obtain ⟨h2, hp2⟩ := h2
      exact fi_setA h2 ⟨by simp [live, hp2], rfl, rfl, rfl, rfl, rfl, fun hp => by cases hp⟩ rfl

theorem flushFrame_pc (s : St) (i : Bool) (io : Io) :
    ((flushFrame fixed s i io).app i).pc = (s.app i).pc ∨ ((flushFrame fixed s i io).app i).pc = .dead := by
  cases io <;> simp only [flushFrame, wr, fixed_atomic, cuts_true, fixed_catchIo] <;> repeat' split
  all_goals first | exact Or.inl rfl | exact Or.inr rfl | simp_all [setA, powerDown]

theorem refresh_view (s : St) (i : Bool) :
    (refresh fixed s i).st = s.st ∧ ∀ r, ((refresh fixed s i).app i).cur = some r →
      ((refresh fixed s i).app i).view = some r ∧
      ∀ k, ((refresh fixed s i).app i).viewFiles k = s.st (stPath fixed r k) := by
  simp only [refresh]
  split
  · rename_i r0 hcur
    refine ⟨rfl, fun r hr => ?_⟩
    simp only [setA_self] at hr ⊢
    rw [hcur] at hr; cases hr
    exact ⟨rfl, fun _ => rfl⟩
  · rename_i hcur
    refine ⟨rfl, fun r hr => ?_⟩
    simp only [setA_self] at hr; rw [hcur] at hr; cases hr

theorem refresh_app (s : St) (i : Bool) :
    live ((refresh fixed s i).app i) = live (s.app i) ∧ ((refresh fixed s i).app i).cur = (s.app i).cur ∧
    ((refresh fixed s i).app i).base = (s.app i).base ∧
    ((refresh fixed s i).app i).pc = (s.app i).pc := by
  simp only [refresh]; split <;> simp [setA_self, live]

/-- The Save States grid a click lands on shows the files on disk. -/
theorem view_at_click {s : St} {i : Bool} {r : Rom} (h : FI s) (hpc : (s.app i).pc = .win)
    (hwin : (s.app i).win = true) (hc : (s.app i).cur = some r) (k : Nat) :
    (s.app i).viewFiles k = s.st (stPath fixed r k) :=
  (h.2.2.1 i (live_of_pc hpc (by simp)) r hc (h.2.2.2.1 i hpc hwin)).2 k

theorem step_F (s : St) (e : Ev) (h : FI s) : FI (step fixed s e) := by
  cases e
  case launch i c ro =>
    simp only [step]; split <;> first | exact launch_F c ro h | exact h
  case frame i w io =>
    simp only [step]
    split
    · rename_i hcond
      have hpc : (s.app i).pc = .emu := by simp at hcond; exact hcond.1.1.1.1
      have h1 := flushFrame_F io h hpc
      have hp1 := flushFrame_pc s i io
      rw [hpc] at hp1
      generalize flushFrame fixed s i io = s1 at h1 hp1 ⊢
      split
      · exact h1
      · rename_i hnd
        have hp1' : (s1.app i).pc = .emu := by rcases hp1 with hp1 | hp1; exact hp1; exact absurd hp1 hnd
        split
        · exact fi_setA (fi_congr h1 (fun _ => SameNB.rfl' _) (fun _ => rfl) rfl rfl rfl rfl)
            ⟨by simp [live, hp1'], rfl, rfl, rfl, rfl, rfl, fun hp => by cases hp⟩ rfl
        · exact h1
    · exact h
  case mStates i =>
    simp only [step, click]
    repeat' split
    all_goals first
      | exact h
      | exact fix_setA_view (fi_to_fix i h) rfl rfl rfl (fun hp => by simp_all) (h.2.2.1 i)
  case mDone i =>
    simp only [step, at_]
    split
    · rename_i hpc
      have hl : live (s.app i) = true := live_of_pc hpc (by simp)
      have hlw : ∀ a : App, a.pc = .win → live a = true := fun a ha => live_of_pc ha (by simp)
      split
      · exact fix_setA_view (fi_to_fix i h) (by rw [hl]; rfl) rfl rfl (fun _ hw => by simp_all)
          (fun _ _ _ hwo => by cases hwo)
      · split
        · have h1 := fi_refresh i h
          obtain ⟨hst, hv⟩ := refresh_view s i
          obtain ⟨ha1, ha2, ha3, _⟩ := refresh_app s i
          refine fix_setA_view (fi_to_fix i h1) (by rw [ha1, hl]; rfl) rfl rfl (fun _ _ => rfl) ?_
          intro _ r hr _
          obtain ⟨hv1, hv2⟩ := hv r hr
          exact ⟨hv1, fun k => by rw [hv2 k, hst]⟩
        · rename_i hwin hwo
          exact fix_setA_view (fi_to_fix i h) (by rw [hl]; rfl) rfl rfl (fun _ _ => by simpa using hwo)
            (fun _ r hc hw1 => h.2.2.1 i hl r hc hw1)
    · exact h
  case wSave i k io =>
    simp only [step, click]
    split
    · rename_i hcl
      have hpc : (s.app i).pc = .win := by simp at hcl; exact hcl.1
      have hl : live (s.app i) = true := live_of_pc hpc (by simp)
      split
      · exact h
      · rename_i hwin
        simp only [Bool.not_eq_true', Bool.not_eq_false] at hwin
        split
        · rename_i r hcur
          have hv := view_at_click h hpc (by simpa using hwin) hcur k
          simp only [hv, ite_true]
          have h0 : FI { s with blind := s.blind } := h
          exact fix_saved (saveSlot_F k io h0 hl)
        · exact h
    · exact h
  case wDelete i k =>
    simp only [step, click]
    split
    · rename_i hcl
      have hpc : (s.app i).pc = .win := by simp at hcl; exact hcl.1
      have hl : live (s.app i) = true := live_of_pc hpc (by simp)
      split
      · exact h
      · rename_i hwin
        split
        · rename_i r hcur
          have hv := view_at_click h hpc (by simp_all) hcur k
          simp only [hv, true_or, decide_true, Bool.true_or, ite_true]
          refine fix_refresh (fix_stWrite (k := k) h hl hcur rfl rfl rfl rfl ?_)
          intro q hq; simp only [upd_apply, hq, ite_false]
        · exact h
    · exact h
  case wClose i =>
    simp only [step, click]
    split
    · exact fix_setA_view (fi_to_fix i h) rfl rfl rfl (fun _ hw => by cases hw) (h.2.2.1 i)
    · exact h
  case drop i r =>
    simp only [step, at_]; split
    · rename_i hpc; exact loadRom_F r h (live_of_pc hpc (by simp)) (by simp [hpc])
    · exact h
  case mOpen i r =>
    simp only [step, click]; split
    · rename_i hpc
      have hpc' : (s.app i).pc = .menu := by simp at hpc; exact hpc.1
      exact loadRom_F r h (live_of_pc hpc' (by simp)) (by simp [hpc'])
    · exact h
  case noPresent i =>
    simp only [step, at_]; split
    · rename_i hpc; exact loopEnd_F h (live_of_pc hpc (by simp))
    · exact h
  case presentDone i =>
    simp only [step, at_]; split
    · rename_i hpc; exact loopEnd_F h (live_of_pc hpc (by simp))
    · exact h
  all_goals simp only [step, at_, click]
  all_goals repeat' split
  all_goals first
    | exact h
    | exact fi_setA h ⟨by simp_all [live], rfl, rfl, rfl, rfl, rfl, fun hp => by simp_all⟩ rfl
    | exact pendStep_F _ h (by simp_all)
    | exact loadRom_F _ h (live_of_pc (by simp_all) (by simp)) (by simp_all)
    | exact loopEnd_F h (live_of_pc (by simp_all) (by simp))
    | exact (loadSlot_F _ _ h)
    | exact fi_congr h (fun _ => SameNB.rfl' _) (fun _ => rfl) rfl rfl rfl rfl

/-- **Proved (fixed):** under every interleaving of two windows: no two live
    windows write the same battery file; a battery write never replaces
    content its writer has not seen (`clobbers = []`); every click in the
    Save States window lands on a grid that shows the current game's files
    as they are on disk (`blind = []`). -/
theorem fi_ok {s : St} (h : Reachable fixed s) : FI s := by
  induction h with
  | init =>
    refine ⟨?_, ?_, ?_, ?_, rfl, rfl⟩
    · intro j r r' hl; simp [init, App.off, live] at hl
    · intro j hl; simp [init, App.off, live] at hl
    · intro j hl; simp [init, App.off, live] at hl
    · intro j hpc; simp [init, App.off] at hpc
  | step e _ ih => exact step_F _ e ih

/-- **Proved (fixed):** two live windows never write the same `.sav` or
    `.cht` (both named by `savPath`) nor the same save-state file. -/
theorem two_windows_distinct {s : St} (h : Reachable fixed s) {r r' : Rom}
    (hl : live (s.app false) = true) (hl' : live (s.app true) = true)
    (hc : (s.app false).cur = some r) (hc' : (s.app true).cur = some r') :
    savPath r ≠ savPath r' ∧ ∀ k k', stPath fixed r k ≠ stPath fixed r' k' :=
  distinct (j := false) (fi_ok h).1 hl hl' hc hc'

end Excl

/-! ## The fixed code: no state is written from inside a frame -/

section Mid

/-- No core is stopped inside a frame, and no state file was written from one. -/
def MidInv (s : St) : Prop := s.midSaves = 0 ∧ ∀ j, (s.app j).mid = false

theorem midInv_of {s t : St} (h : MidInv s) (h1 : t.midSaves = s.midSaves)
    (h2 : ∀ j, (t.app j).mid = (s.app j).mid) : MidInv t :=
  ⟨h1 ▸ h.1, fun j => (h2 j).trans (h.2 j)⟩

theorem midInv_setA {s : St} (i : Bool) {a : App} (h : MidInv s) (ha : a.mid = false) :
    MidInv (setA s i a) := by
  refine ⟨h.1, fun j => ?_⟩
  simp only [setA_app, upd_apply]; split
  · exact ha
  · exact h.2 j

theorem flushFrame_mid (s : St) (i : Bool) (io : Io) :
    (flushFrame fixed s i io).midSaves = s.midSaves ∧ ∀ j, ((flushFrame fixed s i io).app j).mid = (s.app j).mid := by
  cases io <;> simp only [flushFrame, wr, fixed_atomic, cuts_true] <;>
    repeat (first | split | simp_all [powerDown, setA, upd_apply])

theorem flushOut_mid (s : St) (i : Bool) :
    (flushOut fixed s i).midSaves = s.midSaves ∧ ∀ j, ((flushOut fixed s i).app j).mid = (s.app j).mid := by
  simp only [flushOut] <;> repeat (first | split | simp_all [powerDown, setA, upd_apply])

theorem loadSlot_mid (s : St) (i : Bool) (k : Nat) :
    ((loadSlot fixed s i k).1).midSaves = s.midSaves ∧ ∀ j, (((loadSlot fixed s i k).1).app j).mid = (s.app j).mid := by
  simp only [loadSlot] <;> repeat (first | split | simp_all [powerDown, setA, upd_apply])

theorem refresh_mid (s : St) (i : Bool) :
    (refresh fixed s i).midSaves = s.midSaves ∧ ∀ j, ((refresh fixed s i).app j).mid = (s.app j).mid := by
  simp only [refresh] <;> repeat (first | split | simp_all [powerDown, setA, upd_apply])

theorem saveSlot_midInv (s : St) (i : Bool) (k : Nat) (io : Io) (h : MidInv s) :
    MidInv (saveSlot fixed s i k io) := by
  have hi := h.2 i
  refine midInv_of h ?_ ?_
  · cases io <;> simp only [saveSlot, wr, fixed_atomic, cuts_true] <;>
      repeat (first | split | simp_all [powerDown, setA, upd_apply])
  · intro j
    cases io <;> simp only [saveSlot, wr, fixed_atomic, cuts_true] <;>
      repeat (first | split | simp_all [powerDown, setA, upd_apply])

theorem loadRom_midInv (s : St) (i : Bool) (r : Rom) (h : MidInv s) : MidInv (loadRom fixed s i r) := by
  have h0 := midInv_of h (flushOut_mid s i).1 (flushOut_mid s i).2
  simp only [loadRom]
  generalize flushOut fixed s i = s0 at h0 ⊢
  split
  · exact h0
  · exact midInv_setA i ⟨h0.1, h0.2⟩ (h0.2 i)

theorem launch_midInv (s : St) (i : Bool) (c : Bool) (ro : Option Rom) (h : MidInv s) :
    MidInv (launch fixed s i c ro) := by
  simp only [launch]
  split
  · exact loadRom_midInv _ i _ (midInv_setA i h rfl)
  · exact midInv_setA i h rfl

theorem loopEnd_midInv (s : St) (i : Bool) (h : MidInv s) : MidInv (loopEnd fixed s i) := by
  simp only [loopEnd]
  split
  · exact midInv_setA i h (h.2 i)
  · have h0 := midInv_of h (flushOut_mid s i).1 (flushOut_mid s i).2
    exact midInv_setA i h0 (h0.2 i)

theorem pendStep_midInv (s : St) (i : Bool) (io : Io) (h : MidInv s) : MidInv (pendStep fixed s i io) := by
  simp only [pendStep]
  split
  · exact midInv_setA i h (h.2 i)
  · generalize hs1 : (if (s.app i).pendSave = true then _ else s) = s1
    have h1 : MidInv s1 := by
      subst hs1; split
      · have := saveSlot_midInv _ i 0 io (midInv_setA i h (a := { s.app i with pendSave := false }) (h.2 i))
        exact midInv_setA i this (this.2 i)
      · exact h
    split
    · exact h1
    · generalize hs2 : (if (s1.app i).pendLoad = true then _ else s1) = s2
      have h2 : MidInv s2 := by
        subst hs2; split
        · have h1' := midInv_setA i h1 (a := { s1.app i with pendLoad := false }) (h1.2 i)
          have := midInv_of h1' (loadSlot_mid _ i 0).1 (loadSlot_mid _ i 0).2
          split
          · exact this
          · exact midInv_setA i this (this.2 i)
        · exact h1
      exact midInv_setA i h2 (h2.2 i)

theorem midInv_ff {s : St} (i : Bool) (io : Io) (h : MidInv s) : MidInv (flushFrame fixed s i io) :=
  midInv_of h (flushFrame_mid s i io).1 (flushFrame_mid s i io).2
theorem midInv_rf {s : St} (i : Bool) (h : MidInv s) : MidInv (refresh fixed s i) :=
  midInv_of h (refresh_mid s i).1 (refresh_mid s i).2

theorem step_midInv (s : St) (e : Ev) (h : MidInv s) : MidInv (step fixed s e) := by
  cases e <;> simp only [step, at_, click] <;> repeat' split
  all_goals first
    | exact h
    | exact midInv_setA _ h (h.2 _)
    | exact midInv_setA _ h rfl
    | exact launch_midInv _ _ _ _ h
    | exact loadRom_midInv _ _ _ h
    | exact pendStep_midInv _ _ _ h
    | exact loopEnd_midInv _ _ h
    | exact midInv_of h (loadSlot_mid _ _ _).1 (loadSlot_mid _ _ _).2
    | exact midInv_of h rfl (fun _ => rfl)
    | exact midInv_ff _ _ h
    | exact midInv_setA _ (midInv_ff _ _ h) rfl
    | exact saveSlot_midInv _ _ _ _ (midInv_of h rfl (fun _ => rfl))
    | exact midInv_rf _ (saveSlot_midInv _ _ _ _ (midInv_of h rfl (fun _ => rfl)))
    | exact midInv_rf _ (midInv_of h rfl (fun _ => rfl))
    | exact midInv_setA _ (midInv_rf _ h) ((midInv_rf _ h).2 _)

/-- **Proved (fixed):** no state file is ever written from a core stopped
    inside a frame. -/
theorem mid_ok {s : St} (h : Reachable fixed s) : MidInv s := by
  induction h with
  | init => exact ⟨rfl, fun _ => rfl⟩
  | step e _ ih => exact step_midInv _ e ih

end Mid

/-! ## What the real code keeps -/

/-- **Proved (real code):** ImGui is never skipped while the state notice is
    set (render_imgui 1282), nor while the game is paused, so a refused Quick
    Load is always drawn at the next present. -/
theorem notice_drawn (a : App) (mv : Bool) (h : a.notice = true ∨ a.paused = true) :
    imguiSkipped a mv = false := by
  unfold imguiSkipped; rcases h with h | h <;> simp [h]

/-! # Counterexamples (the code at a2e038f82)

Each trace is a run of the real code from the initial state; each is checked
by the kernel. `F` is one frame of window 0; `iter` is the rest of one loop
iteration (process_pending_state, handle_input, link, render_imgui). -/

/-! ## ROMs used by the traces -/

/-- `~/roms/usa/Pokemon.gba` -/
def romA : Rom := ⟨0, 5, 0, 100⟩
/-- `~/roms/hacks/Pokemon.gba`: another game, same file name, another folder. -/
def romB : Rom := ⟨1, 5, 0, 200⟩
/-- `~/roms/usa/Golden Sun.gba` -/
def romC : Rom := ⟨0, 6, 0, 300⟩
/-- `~/roms/Tetris.gb` -/
def romG : Rom := ⟨0, 7, 1, 400⟩
/-- `~/roms/Tetris.gbc`: another game, same name, same folder. -/
def romH : Rom := ⟨0, 7, 2, 500⟩

/-- One iteration of process `false` with nothing but phase 1 = `e`. -/
def F (w : Bool := false) (io : Io := .ok) : Ev := .frame false w io

def tLinkMenu : List Ev :=
  [.launch false false (some romA)] ++
  iter false (F) [.keySave false] [.mLink false] [] ++
  iter false (F) [] [.mQuickLoad false] [] (.linkUp false) ++
  iter false (F) [] [] []

def tLinkWindow : List Ev :=
  [.launch false false (some romA)] ++
  iter false (F) [.keySave false] [.mLink false, .mStates false] [] ++
  iter false (F) [] [] [.wLoad false 0] (.linkUp false)

def tLinkRace : List Ev :=
  [.launch false false (some romA)] ++
  iter false (F) [.keySave false] [.mLink false] [] ++
  iter false (F) [.keyLoad false] [] [] (.linkUp false) ++
  iter false (F) [] [] []

def tSameName : List Ev :=
  [.launch false false (some romA)] ++
  iter false (F) [.keySave false] [] [] ++
  iter false (F) [.drop false romB] [] [] ++
  iter false (F) [.keySave false] [] [] ++
  iter false (F) [.drop false romA] [] [] ++
  iter false (F) [.keyLoad false] [] [] ++
  [F, .pend false .ok]

def tStalePre : List Ev :=
  [.launch false false (some romA)] ++
  iter false (F) [] [.mStates false] [.wSave false 1 .ok] ++
  iter false (F) [] [] [.wClose false] ++
  iter false (F) [.drop false romC] [] [] ++
  iter false (F) [] [.mStates false] [.wSave false 1 .ok] ++
  [F, .pend false .ok, .drop false romA, .inputDone false, .linkIdle false, .present false,
   .mDone false]

def tStale : List Ev := tStalePre ++ [.wDelete false 1]

def tGbaCrash (r : Rom) : List Ev :=
  [.launch false false (some r)] ++
  iter false (F true) [] [] [] ++
  [F false .denied]

def tQuit (r : Rom) : List Ev :=
  [.launch false false (some r)] ++
  iter false (F true) [.quit false] [] []

def tPower : List Ev :=
  [.launch false false (some romA)] ++
  iter false (F true) [] [] [] ++
  iter false (F true) [] [] [] ++
  [F false .power, .launch false false (some romA)]

def tStateCut : List Ev :=
  [.launch false false (some romA)] ++
  iter false (F) [.keySave false] [] [] ++
  iter false (F) [.keySave false] [] [] ++
  [F, .pend false .full, .keyLoad false, .inputDone false, .linkIdle false, .noPresent false,
   F, .pend false .ok]

def tCli : List Ev :=
  [.launch false true (some romA), F, .pend false .ok, .quit false, .inputDone false,
   .linkIdle false, .noPresent false, .launch false false (some romA)]

def tRewind : List Ev :=
  [.launch false false (some romA)] ++
  iter false (F) [.keySave false] [] [] ++
  iter false (F) [.keyLoad false] [] [] ++
  iter false (F) [.rewindKey false true] [] [] ++
  [.rewindPop false]

def tTwo : List Ev :=
  [.launch false false (some romA), .launch true false (some romA),
   F true, .pend false .ok, .inputDone false, .linkIdle false, .noPresent false,
   F,
   .frame true true .ok, .pend true .ok, .inputDone true, .linkIdle true, .noPresent true,
   .frame true false .ok]

def tTwoCfg : List Ev :=
  [.launch false false (some romA), .launch true false (some romC),
   F, .pend false .ok, .inputDone false, .linkIdle false, .present false, .mSetVol false 7,
   .mDone false, .presentDone false,
   .frame true false .ok, .pend true .ok, .drop true romA]

def tMid : List Ev :=
  [.launch false false (some romA)] ++
  iter false (F) [] [.mLink false] [] ++
  iter false (F) [.keySave false] [] [] (.linkUp false) ++
  [.linkLost false, .pend false .ok]

def tBasename : List Ev :=
  [.launch false false (some romG)] ++
  iter false (F true) [] [] [] ++
  iter false (F) [.drop false romH] [] [] ++
  iter false (F true) [] [] [] ++
  iter false (F) [.drop false romG] [] []


/-- **Loading a state while linked, from the File menu.** Ctrl+L refuses while
    linked (1658-1660), File > Quick Load does not (1311-1313), and
    `process_pending_state` (934-938) loads whatever is pending. The pair
    desyncs; the Link window itself says save-state load is paused while
    linked (2065). -/
theorem bug_menu_quick_load_while_linked :
    Reachable real (run real init tLinkMenu) ∧
    (run real init tLinkMenu).loads.map (·.1) = [true] ∧
    ((run real init tLinkMenu).app false).linked = true :=
  ⟨run_reachable _ _ _ .init, by decide +kernel, by decide +kernel⟩

/-- **Loading a state while linked, from the Save States window.** `on_load`
    (2274-2279) calls `load_state_slot` with no link check. -/
theorem bug_window_load_while_linked :
    Reachable real (run real init tLinkWindow) ∧
    (run real init tLinkWindow).loads.map (·.1) = [true] :=
  ⟨run_reachable _ _ _ .init, by decide +kernel⟩

/-- **Ctrl+L just before the link comes up.** The key is checked against
    `app.netlink` in `handle_input` (phase 3); the link is established in
    `service_link_setup` in phase 4 of the same iteration; the load runs in
    phase 2 of the next, linked. Window: one loop iteration (at most a frame). -/
theorem bug_quick_load_races_link :
    Reachable real (run real init tLinkRace) ∧
    (run real init tLinkRace).loads.map (·.1) = [true] :=
  ⟨run_reachable _ _ _ .init, by decide +kernel⟩

/-- **Two ROMs with the same file name share their save-state files.**
    `state_file_path` (823-831) uses only `rom.extractFilename()`. B's Quick
    Save replaces A's Quick slot; A's Quick Load is then refused
    (`srkWrongRom`, serialize.nim 377) and A's state is gone. -/
theorem bug_same_name_state_overwritten :
    Reachable real (run real init tSameName) ∧
    (run real init tSameName).foreign.length = 1 ∧
    ((run real init tSameName).st (stPath real romA 0)).map (·.ident) = some 200 ∧
    ((run real init tSameName).app false).notice = true ∧
    (run real init tSameName).loads = [] :=
  ⟨run_reachable _ _ _ .init, by decide +kernel, by decide +kernel, by decide +kernel, by decide +kernel⟩

/-- **The Save States window keeps the previous game's slots after a ROM
    switch.** `on_open` runs only on the window's open edge (widget 69-75);
    `load_rom` does not call `mark_stale`. -/
theorem bug_window_shows_previous_games_slots :
    Reachable real (run real init tStalePre) ∧
    ((run real init tStalePre).app false).pc = .win ∧
    ((run real init tStalePre).app false).win = true ∧
    ((run real init tStalePre).app false).view = some romC ∧
    ((run real init tStalePre).app false).cur = some romA :=
  ⟨run_reachable _ _ _ .init, by decide +kernel, by decide +kernel, by decide +kernel, by decide +kernel⟩

/-- **... and its Delete deletes a slot the grid does not show.** Delete is
    enabled from the stale `used` flag (widget 180) and acts on the current
    game's file: A's slot 2 is deleted while the grid showed C's. -/
theorem bug_window_delete_hidden_slot :
    Reachable real (run real init tStale) ∧
    (run real init tStale).blind = [stPath real romA 1] ∧
    (run real init tStale).st (stPath real romA 1) = none ∧
    ((run real init tStale).st (stPath real romC 1)).isSome = true :=
  ⟨run_reachable _ _ _ .init, by decide +kernel, by decide +kernel, by decide +kernel⟩

/-- **A GBA battery write that fails kills the app.** `write_save`
    (storage.nim 93-95) is not in a try; the IOError leaves
    `run_until_frame` and `main()`. The game's progress is lost. -/
theorem bug_gba_save_error_crashes :
    Reachable real (run real init (tGbaCrash romA)) ∧
    ((run real init (tGbaCrash romA)).app false).pc = .dead ∧
    (run real init (tGbaCrash romA)).crashes = 1 ∧
    (run real init (tGbaCrash romA)).sav (savPath romA) = none :=
  ⟨run_reachable _ _ _ .init, by decide +kernel, by decide +kernel, by decide +kernel⟩

/-- The same failure on a GB cart is caught (`mbc_save` 3243-3246). -/
theorem gb_save_error_survives :
    ((run real init (tGbaCrash romG)).app false).pc = .pend ∧
    (run real init (tGbaCrash romG)).crashes = 0 := by decide +kernel

/-- **GBA battery RAM written in the last frame is not flushed at quit (or at a
    ROM switch).** `flush_gb_save` (477-481) covers GB only. -/
theorem bug_gba_quit_drops_battery :
    Reachable real (run real init (tQuit romA)) ∧
    ((run real init (tQuit romA)).app false).pc = .exited ∧
    (run real init (tQuit romA)).dropped.length = 1 ∧
    (run real init (tQuit romA)).sav (savPath romA) = none :=
  ⟨run_reachable _ _ _ .init, by decide +kernel, by decide +kernel, by decide +kernel⟩

theorem gb_quit_flushes :
    (run real init (tQuit romG)).sav (savPath romG) = some ⟨400, 2, true⟩ := by decide +kernel

/-- **A truncated `.sav` replaces the good one and is accepted.** `writeFile`
    truncates first; power lost mid-write leaves a short file, and
    `new_storage` / `mbc_load` read whatever length is there. -/
theorem bug_truncated_sav_accepted :
    Reachable real (run real init tPower) ∧
    (run real init tPower).sav (savPath romA) = some ⟨100, 3, false⟩ ∧
    ((run real init tPower).app false).core.map (·.ram) = some (some ⟨100, 3, false⟩) :=
  ⟨run_reachable _ _ _ .init, by decide +kernel, by decide +kernel⟩

/-- **A failed Quick Save destroys the previous state, silently.** The
    truncated file is refused on load (`srkTruncated`), but the good one it
    replaced is gone; the failed save itself shows nothing
    (`process_pending_state` 931 discards the result). -/
theorem bug_failed_quick_save_destroys_previous :
    Reachable real (run real init tStateCut) ∧
    ((run real init tStateCut).st (stPath real romA 0)).map (·.whole) = some false ∧
    (run real init tStateCut).truncs = 1 ∧
    ((run real init tStateCut).app false).notice = true ∧
    (run real init tStateCut).loads = [] :=
  ⟨run_reachable _ _ _ .init, by decide +kernel, by decide +kernel, by decide +kernel, by decide +kernel⟩

/-- **A one-off command-line BIOS flag becomes permanent.** `main` writes the
    flags into the loaded config (2164-2175) and `load_rom` saves it (761). The
    next plain launch runs with it. -/
theorem bug_cli_flag_persisted :
    Reachable real (run real init tCli) ∧
    (run real init tCli).cfgDisk = some ⟨true, 0⟩ ∧
    (run real init tCli).userHle = false ∧
    ((run real init tCli).app false).cfg.hle = true :=
  ⟨run_reachable _ _ _ .init, by decide +kernel, by decide +kernel, by decide +kernel⟩

/-- **Rewind after a state load walks into the timeline the load replaced.**
    Neither `process_pending_state` nor `on_load` clears `app.rewind`. -/
theorem bug_rewind_crosses_state_load :
    Reachable real (run real init tRewind) ∧ (run real init tRewind).staleRewind = 1 :=
  ⟨run_reachable _ _ _ .init, by decide +kernel⟩

/-- **Two windows on the same ROM file: last writer wins.** Both read
    `Pokemon.sav` at boot; window 0 saves (v3); window 1, still on the boot
    image, saves (v5) over it. Window 0's save is gone from disk while it
    keeps running. -/
theorem bug_two_windows_lost_update :
    Reachable real (run real init tTwo) ∧
    (run real init tTwo).clobbers.length = 1 ∧
    (run real init tTwo).sav (savPath romA) = some ⟨100, 5, true⟩ ∧
    ((run real init tTwo).app false).base = some ⟨100, 3, true⟩ :=
  ⟨run_reachable _ _ _ .init, by decide +kernel, by decide +kernel, by decide +kernel⟩

/-- **Two windows: a setting changed in one is reverted by the other's next
    ROM load** (`save_config` writes the whole object, 761). -/
theorem bug_two_windows_config_lost :
    Reachable real (run real init tTwoCfg) ∧
    (run real init tTwoCfg).cfgDisk = some ⟨false, 0⟩ ∧ (run real init tTwoCfg).userVol = 7 :=
  ⟨run_reachable _ _ _ .init, by decide +kernel, by decide +kernel⟩

/-- **Same name, different extension, same folder: one `.sav`.**
    `Tetris.gb` and `Tetris.gbc` both use `Tetris.sav` (gb mbc.nim 156): each
    boots on the other's battery and writes over it. (Not fixed below: every
    emulator uses this convention; see the report.) -/
theorem bug_same_basename_shares_sav :
    Reachable real (run real init tBasename) ∧
    (run real init tBasename).wrongBoot.length = 2 ∧
    (run real init tBasename).sav (savPath romG) = some ⟨500, 5, true⟩ :=
  ⟨run_reachable _ _ _ .init, by decide +kernel, by decide +kernel⟩

/-- **A Quick Save queued just before the peer drops is written from inside a
    frame.** `step_frame` raises NetLinkError mid-frame (a reset connection,
    EOF, or a 30 s stall); main tears the link down (2462-2464) and goes on to
    `process_pending_state`, whose comment (2521) promises a frame boundary.
    The GBA state format assumes one (gba savestate.nim 3). Window: the key
    press in the iteration before the failing frame. -/
theorem bug_state_saved_mid_frame :
    Reachable real (run real init tMid) ∧ (run real init tMid).midSaves = 1 :=
  ⟨run_reachable _ _ _ .init, by decide +kernel⟩

/-! # Regressions: the same traces through the fixed code -/

theorem regress_link_loads :
    (run fixed init tLinkMenu).loads = [] ∧ (run fixed init tLinkWindow).loads = [] ∧
    (run fixed init tLinkRace).loads = [] := by decide +kernel

theorem regress_same_name :
    (run fixed init tSameName).foreign = [] ∧ (run fixed init tSameName).loads.length = 1 ∧
    ((run fixed init tSameName).app false).notice = false := by decide +kernel

theorem regress_window_view :
    ((run fixed init tStalePre).app false).view = some romA ∧ (run fixed init tStale).blind = [] := by
  decide +kernel

/-- The failed write is survived and shown; the next frame retries it, and a
    write that lands takes the notice down and saves the RAM the failure kept. -/
def tGbaRecover : List Ev :=
  tGbaCrash romA ++ [.pend false .ok, .inputDone false, .linkIdle false, .noPresent false, F]

theorem regress_gba_save_error :
    ((run fixed init (tGbaCrash romA)).app false).pc = .pend ∧
    (run fixed init (tGbaCrash romA)).crashes = 0 ∧
    ((run fixed init (tGbaCrash romA)).app false).batErr = true ∧
    ((run fixed init tGbaRecover).app false).batErr = false ∧
    (run fixed init tGbaRecover).sav (savPath romA) = some ⟨100, 2, true⟩ := by decide +kernel

/-- The real code's GB flush survives the same failure but tells only stdout. -/
theorem gb_save_error_unseen : ((run real init (tGbaCrash romG)).app false).batErr = false := by
  decide +kernel

theorem regress_gb_save_error_shown : ((run fixed init (tGbaCrash romG)).app false).batErr = true := by
  decide +kernel

theorem regress_gba_quit :
    (run fixed init (tQuit romA)).dropped = [] ∧
    (run fixed init (tQuit romA)).sav (savPath romA) = some ⟨100, 2, true⟩ := by decide +kernel

theorem regress_power :
    (run fixed init tPower).sav (savPath romA) = some ⟨100, 2, true⟩ := by decide +kernel

theorem regress_state_cut :
    (run fixed init tStateCut).loads.length = 1 ∧ (run fixed init tStateCut).truncs = 0 := by
  decide +kernel

/-- Two Quick Saves, the second cut short by a full disk. -/
def tSaveCut : List Ev :=
  [.launch false false (some romA)] ++
  iter false (F) [.keySave false] [] [] ++
  iter false (F) [.keySave false] [] [] ++
  [F, .pend false .full]

/-- The real code says nothing and leaves the slot truncated ... -/
theorem failed_quick_save_silent :
    ((run real init tSaveCut).app false).notice = false ∧
    ((run real init tSaveCut).st (stPath real romA 0)).map (·.whole) = some false := by
  decide +kernel

/-- ... the fixed code keeps the slot's previous state whole and says so. -/
theorem regress_failed_quick_save_says_so :
    ((run fixed init tSaveCut).app false).notice = true ∧
    ((run fixed init tSaveCut).st (stPath fixed romA 0)).map (·.whole) = some true := by
  decide +kernel

theorem regress_cli :
    (run fixed init tCli).cfgDisk = some ⟨false, 0⟩ ∧ ((run fixed init tCli).app false).cfg.hle = false := by
  decide +kernel

theorem regress_rewind : (run fixed init tRewind).staleRewind = 0 := by decide +kernel

/-- The second window's `dingbat Pokemon.gba` is refused (`load_rom`'s notice,
    the window open with no game); the first window's save stays on disk. -/
theorem regress_two_windows :
    (run fixed init tTwo).clobbers = [] ∧
    ((run fixed init tTwo).app true).cur = none ∧
    ((run fixed init tTwo).app true).pc = .emu ∧
    (run fixed init tTwo).sav (savPath romA) = some ⟨100, 2, true⟩ ∧
    (run fixed init tTwoCfg).cfgDisk = some ⟨false, 7⟩ ∧
    ((run fixed init tTwoCfg).app true).cur = some romC := by decide +kernel

/-- `~/roms/usa/Pokemon copy.gba`: the same game under another name. -/
def romCopy : Rom := ⟨0, 8, 0, 100⟩
/-- `~/roms/backup/Pokemon.gba`: the same game under the same name elsewhere. -/
def romBak : Rom := ⟨2, 5, 0, 100⟩

/-- `tTwo` with window 1 opening `r`. -/
def tTwoOf (r : Rom) : List Ev :=
  [.launch false false (some romA), .launch true false (some r),
   F true, .pend false .ok, .inputDone false, .linkIdle false, .noPresent false,
   F,
   .frame true true .ok, .pend true .ok, .inputDone true, .linkIdle true, .noPresent true,
   .frame true false .ok]

/-- What the refusal notice suggests: a copy under another name runs, on a
    `.sav` of its own. -/
theorem regress_copy_other_name :
    (run fixed init (tTwoOf romCopy)).clobbers = [] ∧
    ((run fixed init (tTwoOf romCopy)).app true).cur = some romCopy ∧
    (run fixed init (tTwoOf romCopy)).sav (savPath romA) = some ⟨100, 3, true⟩ ∧
    (run fixed init (tTwoOf romCopy)).sav (savPath romCopy) = some ⟨100, 5, true⟩ := by
  decide +kernel

/-- A copy under the same file name in another folder has its own `.sav` but
    the same save-state slots: refused. -/
theorem regress_copy_same_name :
    ((run fixed init (tTwoOf romBak)).app true).cur = none ∧
    (run fixed init (tTwoOf romBak)).clobbers = [] := by decide +kernel

/-- The lock goes with the process: once window 0 has quit, window 1 opens
    the game. -/
theorem regress_open_after_quit :
    ((run fixed init (tQuit romA ++ [.launch true false (some romA)])).app true).cur = some romA := by
  decide +kernel

theorem regress_mid : (run fixed init tMid).midSaves = 0 := by decide +kernel

end DesktopState.SavePersistence
