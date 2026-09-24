-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models src/dingbat.nim: flush_gb_save extract_zip_rom load_rom state_file_path cheat_file_path save_state_slot load_state_slot delete_state_slot refresh_state_slots process_pending_state render_imgui handle_input teardown_netlink finish_link link_auto_start link_auto_stop link_start_host service_link_setup render_link_window update_link_auto main
-- @models src/dingbat/frontend/save_states_widget.nim: render mark_stale
-- @models src/dingbat/gba/gba.nim: new_storage handle_saves
-- @models src/dingbat/gba/storage.nim: write_save
-- @models src/dingbat/gb/gb.nim: mbc_save new_gb handle_saves
-- @models src/dingbat/gb/mbc/mbc.nim: load_cartridge

/-
# The desktop game lifecycle: loading, switching, resetting and quitting

Models the native frontend (`src/dingbat.nim`, SDL2 + Dear ImGui) at commit
a2e038f82 (branch lean-desktop-state); line numbers are at that commit.

| Nim                                                          | lines       |
|--------------------------------------------------------------|-------------|
| `flush_gb_save` (GB core only)                               | 477-481     |
| `extract_zip_rom` (cache dir `<zip stem>-<hash(zip_path)>`)  | 485-510     |
| `load_rom`: not found 695-696, zip 698-701, flush 702,       | 694-765     |
|   GB `new_gb`+`post_init` 704-720, GBA `new_gba` 721-731,    |             |
|   cheats 732-735, rewind cleared 743-745, recents 755-761,   |             |
|   paused / pending_save / pending_load cleared 763-765       |             |
| `state_file_path`: `config_dir/states/<rom file name>`       | 823-831     |
| `cheat_file_path`: `<rom path minus ext>.cht`                | 777-781     |
| `save_state_slot` / `load_state_slot` / `delete_state_slot`  | 833-889     |
| `refresh_state_slots` (the Save States grid)                 | 890-923     |
| `process_pending_state`                                      | 925-940     |
| `render_imgui`: File > Recent 1297-1300, Clear 1302-1304,    | 1265-1560   |
|   Quick Save/Load 1308-1313, Save States 1314, Exit 1322,    |             |
|   Emulation > Reset 1366-1371, Link Cable 1377-1379,         |             |
|   File > Open ROM (file explorer callback) 1473-1474         |             |
| `handle_input`: Ctrl+R 1647-1648, Ctrl+P 1649, Ctrl+S 1655,  | 1628-1772   |
|   Ctrl+L 1657-1660, Ctrl+Q 1665, backquote 1674-1677,        |             |
|   DropFile 1761-1767, QuitEvent 1769-1770                    |             |
| `teardown_netlink` / `finish_link`                           | 1806-1848   |
| `link_auto_start` / `link_auto_stop` / `link_start_host`     | 1924-1957   |
| `service_link_setup` / `render_link_window` / `update_link_auto` | 1986-2104 |
| `main`: CLI load 2294-2296, the loop 2426-2605, rewind pop   | 2107-2609   |
|   2432-2450, frame 2451-2475, link lost 2456-2468, rewind    |             |
|   push 2478-2486, pending 2522-2523, input 2546,             |             |
|   link 2548-2549, present 2556-2584, after the loop 2606     |             |
| Save States widget callbacks                                 | 2269-2280   |
| save_states_widget.nim `render` (opens: `on_open`; Save,     | 69-205      |
|   Delete, Load act on `w.selected` of the grid as last filled) |           |
| gba.nim `new_storage` (`<rom path minus ext>.sav`)           | 1357-1385   |
| gba.nim `handle_saves` (every 280896 cycles) / storage.nim   | 1530-1532,  |
|   `write_save` (no try: writeFile's IOError propagates)      | 90-95       |
| gb.nim `mbc_save` (catches IOError/OSError) / `handle_saves` | 3228-3244,  |
|   (every 70224 cycles)                                       | 3494-3498   |
| gb/mbc/mbc.nim `load_cartridge` (`rom[0x0147]` unchecked)     | 116-130     |
| netcore.nim `new_net_core` (`gba.set_sio_driver`, gba nil = SIGSEGV) | 893-910 |

## The main loop is a program counter

One `while app.running` iteration runs its phases in a fixed order (`Phase`):
`emu` (rewind pop, or one frame, or the netlink's frame), `pend`
(`process_pending_state`), `input` (`handle_input` drains every queued SDL
event: any number of `drop`/`ctrl*`/`quit` events), `link`
(`update_link_auto` + `service_link_setup`), `present` (`render_imgui`: menu
clicks and widget callbacks, any number), `tail` (loop test; after the loop,
`flush_gb_save`). An event is accepted only in its phase (`Ev.phase`);
`rmFile` (the file system) may act at any time. Nothing is concurrent: the
desktop is single-threaded and synchronous, so these phase boundaries are the
only interleaving points.

## Abstractions, and why they do not affect the stated properties

* **Files.** A fixed universe of paths (`Path`) chosen to exhibit every
  identity the code derives from a path: two games in one folder; a game with
  the same stem and another extension (`/r/P.gb`, `/r/P.gbc`); a game with the
  same file name in another folder (`/s/A.gba`); a zero-byte `.gb`; a GBA game
  in a folder dingbat cannot write; one zip reached by a relative and by an
  absolute path (the CLI takes paths as typed; drag-and-drop and the file
  explorer give absolute ones); a zip with no ROM. `savKey`, `stateKey` and
  `extract` compute exactly what `new_storage`/`load_cartridge`,
  `state_file_path` and `extract_zip_rom` compute for those paths. The `.cht`
  sidecar (`cheat_file_path`) uses the same stem as the `.sav`, so everything
  said about `savKey` holds for cheats too.
* **Battery bytes** are a `Sav` = (the game whose code produced them, a
  fresh version number). A core's cart RAM (`Storage.memory` / `Mbc.ram`) and
  dirty flag (`Storage.dirty` / `Mbc.ram_dirty`) are `Core.ram`/`Core.dirty`.
* **A frame** (`frame due early late`): `due` is the audio/pacing gate (or,
  while rewinding, the 33 ms pop cadence); the running cart may write its
  battery before this frame's `etSaves` event (`early`, flushed by it) and/or
  after it (`late`, left dirty until the next frame's). `etSaves` recurs every
  280896 (GBA) / 70224 (GB) cycles, one frame, so a write is on disk within
  one frame of emulation, but not before the core is dropped. Frame advance
  is a `due` frame; timing and audio are not modelled.
* **Save states** carry (the ROM identity, the cart RAM). The core's header
  check (`serialize.nim` 373-377, `srkWrongRom`) refuses a state of another
  ROM; that is `loadSlot`'s game test. Two slots stand for the nine.
* **The link** is `idle` / `setup auto` (listening or connecting, auto-pair or
  manual) / `linked`. `netlink.gba` is the core bound at `finish_link`; when a
  `load_rom` replaces the app's core while linked, the old core lives on only
  in the netlink: that is `orphan`. The handshake, sockets, rollback and
  bounded lead are Netplay's business; here only which core the link drives
  matters.
* **Exceptions.** An uncaught Nim exception or a nil dereference ends the
  process: `crash` (pc `done`); whatever dirty battery the live cores held is
  gone (`lost`). The IndexDefect from a short `.gb` (checked headlessly against
  `new_gb`), the IOError from `write_save` into a read-only folder (checked
  headlessly against `write_save`) and the SIGSEGV of `finish_link` with no
  GBA core are the three crash sites in this machine's code paths.
* **Not modelled:** GL, window size, lcd_resp, input log, audio, debug
  windows (recreated per load, no persisted state), the cheats widget's
  edit buffers (cosmetic), fast-forward/turbo/channel masks (the new core's
  APU starts at defaults; nothing persisted). `pending_step` is harmless
  across a load (`paused` is cleared). Config file writes other than
  `recents`, and a second dingbat instance, are the Config machine's.
* `lost`, `unseenDelete`, `pendFor`, `Core.id` and `hist`'s tag are ghosts.
  `curPath` is a ghost in `step` (the path of the last successful load) and the
  proposed `app.cur_path` in the fixed step.

## Contents

* `stepX fix`: `step := stepX false` is the code; `stepF := stepX true` is the
  proposed fix (see "The fix").
* Kept by the code, for every reachable state: `pend_current` (a pending Quick
  Save/Load always acts on the game it was asked of), `hist_current` (rewind
  never applies another game's snapshot), `reset_target` (while a game runs,
  `recents[0]` is its path, or recents is empty), `failed_lookup_keeps_game`
  (a missing file or a zip without a ROM changes nothing), `reset_restarts`
  (when unlinked, Reset puts a fresh core of the same game in).
* Counterexamples against `step` (all by `decide`), ranked in the report:
  `bug_gba_switch_drops_dirty_battery`, `bug_gba_quit_drops_dirty_battery`,
  `bug_gba_paused_state_load_not_persisted` (with `gb_same_trace_persists`),
  `bug_empty_gb_crashes`, `bug_readonly_gba_crashes`,
  `bug_reset_while_linked_runs_outgoing_core`, `bug_gb_switch_keeps_link`,
  `bug_link_setup_crash_after_gb_switch`, `bug_save_states_grid_stale_delete`,
  `bug_reset_after_clear_is_noop`, `bug_quick_save_dropped_by_switch`, and the
  identity ones `bug_battery_shared_by_stem`, `bug_state_slot_shared_by_file_name`,
  `bug_zip_identity_split`.
* The fix: `fixF_safe` (no crash, no lost battery, the link never drives a
  core that is not the app's, the grid always shows the running game's slots,
  no unseen delete) for every state `stepF` reaches, `resetF_restarts`, and a
  `regress_*` for each lifecycle counterexample. The identity bugs are in the
  names, not the control flow: `stateKeyF_*`/`zipKeyF_one_identity` state
  what keys that would not collide give.
* `Keep` is proved for both steps at once (`keep_stepX fix`).
-/

namespace DesktopState.GameLifecycle

set_option maxRecDepth 100000

/-! ## Files and the identities derived from them -/

/-- ROM contents: what a save state's header checks (`rom_identity`). -/
inductive Game | A | B | C | P1 | P2 | X | R | Z
  deriving DecidableEq, Repr

inductive Sys | gba | gb
  deriving DecidableEq, Repr

/-- The paths the model's user can hand to `load_rom`. -/
inductive Path
  | aGba   -- /r/A.gba            game A
  | bGba   -- /r/B.gba            game B
  | cGb    -- /r/C.gb             game C
  | pGb    -- /r/P.gb             game P1
  | pGbc   -- /r/P.gbc            game P2 (another game with the same stem)
  | xGba   -- /s/A.gba            game X (same file name as /r/A.gba, other folder)
  | eGb    -- /r/E.gb             a zero-byte (or < 0x148-byte) .gb file
  | roGba  -- /ro/R.gba           game R, in a folder dingbat cannot write
  | zRel   -- z.zip               /r/z.zip as typed on the CLI from /r (holds Z.gba)
  | zAbs   -- /r/z.zip            the same zip, dragged or picked in the explorer
  | zNone  -- /r/n.zip            a zip with no .gba/.gb/.gbc entry
  | zcRel  -- config_dir/zip-cache/z-<hash("z.zip")>/Z.gba       (extracted)
  | zcAbs  -- config_dir/zip-cache/z-<hash("/r/z.zip")>/Z.gba    (extracted)
  deriving DecidableEq, Repr

def Path.isZip : Path → Bool
  | .zRel | .zAbs | .zNone => true
  | _ => false

/-- `extract_zip_rom` (485-510): the cache dir is keyed by the zip path *as
given* (`hash(zip_path)`, 503); "" (none) when the zip holds no ROM. -/
def extract : Path → Option Path
  | .zRel => some .zcRel
  | .zAbs => some .zcAbs
  | _ => none

/-- `load_rom` 698-701: the file the core is built from. -/
def romOf (p : Path) : Option Path := if p.isZip then extract p else some p

/-- `load_rom` 703-704: `.gb`/`.gbc` build a GB core, anything else a GBA core. -/
def sysOf : Path → Sys
  | .cGb | .pGb | .pGbc | .eGb => .gb
  | _ => .gba

/-- The game in a ROM file; `none`: the constructor raises (the zero-byte
`.gb`: `load_cartridge` reads `rom[0x0147]`, an IndexDefect, which no
`except` in the frontend catches). -/
def gameOf : Path → Option Game
  | .aGba => some .A
  | .bGba => some .B
  | .cGb => some .C
  | .pGb => some .P1
  | .pGbc => some .P2
  | .xGba => some .X
  | .roGba => some .R
  | .zcRel | .zcAbs => some .Z
  | _ => none

/-- Battery file names: `rom_path[0 ..< rom_path.rfind('.')] & ".sav"`
(gba.nim 1358, mbc.nim 156). -/
inductive SavKey | rA | rB | rC | rP | sA | rE | roR | zcRel | zcAbs | other
  deriving DecidableEq, Repr

def savKey : Path → SavKey
  | .aGba => .rA
  | .bGba => .rB
  | .cGb => .rC
  | .pGb | .pGbc => .rP          -- /r/P.sav for both
  | .xGba => .sA
  | .eGb => .rE
  | .roGba => .roR
  | .zcRel => .zcRel
  | .zcAbs => .zcAbs
  | _ => .other

/-- Whether `writeFile` on that battery file succeeds. -/
def writable : SavKey → Bool
  | .roR => false
  | _ => true

/-- State file names: `config_dir/states/<rom file name>[.slotN].state`
(`state_file_path` 823-831: `rom.extractFilename()`, no folder). -/
inductive StKey | aGba | bGba | cGb | pGb | pGbc | eGb | rGba | zGba | other
  deriving DecidableEq, Repr

def stateKey : Path → StKey
  | .aGba | .xGba => .aGba       -- both are "A.gba"
  | .bGba => .bGba
  | .cGb => .cGb
  | .pGb => .pGb
  | .pGbc => .pGbc
  | .eGb => .eGb
  | .roGba => .rGba
  | .zcRel | .zcAbs => .zGba     -- the zip entry's own name
  | _ => .other

inductive Slot | q | s1     -- slot 0 (Quick) and one numbered slot
  deriving DecidableEq, Repr

/-! ## State -/

structure Sav where
  owner : Game
  ver : Nat
  deriving DecidableEq, Repr

/-- A save state file: the ROM it was made in and the cart RAM inside it. -/
structure Snap where
  game : Game
  ram : Option Sav
  deriving DecidableEq, Repr

/-- A core object (`GBA` / `GB`). -/
structure Core where
  id : Nat           -- ghost: which `new_gba`/`new_gb` built it
  rom : Path         -- gba.rom_path / gb.rom_path (for a zip: the cache file)
  game : Game
  sys : Sys
  ram : Option Sav   -- Storage.memory / Mbc.ram (with RTC trailer)
  dirty : Bool       -- Storage.dirty / Mbc.ram_dirty
  deriving DecidableEq, Repr

inductive Link
  | idle                  -- link_setup = lsNone, netlink = nil
  | setup (auto : Bool)   -- lsListening / lsConnecting; auto = app.link_auto
  | linked                -- app.netlink != nil
  deriving DecidableEq, Repr

inductive Phase | emu | pend | input | link | present | tail | done
  deriving DecidableEq, Repr

structure St where
  pc : Phase               -- where the main loop is
  running : Bool           -- app.running
  crashed : Bool           -- an exception or SIGSEGV left main()
  cur : Option Core        -- app.gba_emu / app.gb_emu (the one app.emu_kind names)
  orphan : Option Core     -- netlink.gba when it is no longer the app's core
  link : Link              -- app.link_setup / app.link_auto / app.netlink
  linkWin : Bool           -- app.link_window
  paused : Bool            -- app.paused
  pendSave : Bool          -- app.pending_save
  pendLoad : Bool          -- app.pending_load
  pendFor : Option Nat     -- ghost: the core current when a pending flag was set
  rewinding : Bool         -- app.rewinding
  hist : Option (Nat × Option Sav) -- app.rewind: (ghost: core id of the snapshots, cart RAM in the newest)
  ssWin : Bool             -- app.save_states.window
  ssShows : Option StKey   -- ghost: whose files the grid was last filled from
  ssUsed : Slot → Bool     -- app.save_states.slots[i].used, as last filled
  recents : List Path      -- app.cfg.recents (saved by save_config)
  curPath : Option Path    -- ghost in `step`; the proposed app.cur_path in `stepF`
  sav : SavKey → Option Sav            -- battery files on disk
  states : StKey → Slot → Option Snap  -- state files on disk
  present : Path → Bool    -- fileExists
  clock : Nat              -- source of fresh battery versions
  nextId : Nat             -- ghost: next core id
  lost : Bool              -- ghost: a dirty battery (writable file) was dropped unwritten
  unseenDelete : Bool      -- ghost: Delete removed a state file the grid did not show

/-- Start-up with the recents list `rs` read from the config file (any list,
including entries for files that no longer exist). -/
def initR (rs : List Path) : St where
  pc := .emu
  running := true
  crashed := false
  cur := none
  orphan := none
  link := .idle
  linkWin := false
  paused := false
  pendSave := false
  pendLoad := false
  pendFor := none
  rewinding := false
  hist := none
  ssWin := false
  ssShows := none
  ssUsed := fun _ => false
  recents := rs
  curPath := none
  sav := fun _ => none
  states := fun _ _ => none
  present := fun p => match p with
    | .zcRel | .zcAbs => false
    | _ => true
  clock := 0
  nextId := 1
  lost := false
  unseenDelete := false

def init : St := initR []

inductive Ev
  -- phase `emu` (main loop 2430-2486)
  | frame (due early late : Bool)
  | peerGone            -- step_frame raises / the peer's BYE (2456-2468)
  -- phase `pend`
  | pend                -- process_pending_state (2522-2523)
  -- phase `input`: SDL events drained by handle_input
  | drop (p : Path)     -- DropFile (1761-1767); also the CLI load (2296)
  | ctrlR | ctrlP | ctrlS | ctrlL
  | quit                -- Ctrl/Cmd+Q (1665) or QuitEvent (window close, 1769)
  | rewindKey (held : Bool)
  | endInput
  -- phase `link`
  | service (peer : Bool) -- update_link_auto + service_link_setup; peer: a peer answers
  -- phase `present`: ImGui clicks inside render_imgui
  | recent (i : Nat) | openFile (p : Path) | clear | reset | exit
  | quickSave | quickLoad
  | ssOpen | ssClose | ssSave (i : Slot) | ssDelete (i : Slot) | ssLoad (i : Slot)
  | linkOpen | linkHost | linkClose | disconnect
  | endPresent
  -- phase `tail`
  | loopTop
  -- the environment, at any time
  | rmFile (p : Path)
  deriving DecidableEq, Repr

def Ev.phase : Ev → Option Phase
  | .frame .. | .peerGone => some .emu
  | .pend => some .pend
  | .drop _ | .ctrlR | .ctrlP | .ctrlS | .ctrlL | .quit | .rewindKey _ | .endInput => some .input
  | .service _ => some .link
  | .loopTop => some .tail
  | .rmFile _ => none
  | _ => some .present

/-! ## Helpers -/

def upd {α β : Type} [DecidableEq α] (f : α → β) (a : α) (v : β) : α → β :=
  fun x => if x = a then v else f x

def updSt (f : StKey → Slot → Option Snap) (k : StKey) (i : Slot) (v : Option Snap) :
    StKey → Slot → Option Snap :=
  fun k' i' => if k' = k ∧ i' = i then v else f k' i'

/-- `recs.delete(idx); recs.insert(path, 0); setLen(8)` (755-759). -/
def addRecent (p : Path) (rs : List Path) : List Path := (p :: rs.erase p).take 8

/-- The cart writes its battery RAM. -/
def write (c : Core) (v : Nat) : Core := { c with ram := some ⟨c.game, v⟩, dirty := true }

/-- A dirty core whose battery could have been written. -/
def dirtyW : Option Core → Bool
  | some c => c.dirty && writable (savKey c.rom)
  | none => false

/-- One battery flush: GBA `handle_saves` → `write_save` (storage.nim 90-95),
GB `mbc_save` (gb.nim 3228-3244). Returns the files, the core, and whether it
raised: GB catches IOError/OSError (the RAM stays dirty, one stdout line);
GBA's `writeFile` raises IOError out of `run_until_frame` and `main`. With
`fix`, GBA catches it too. -/
def flushX (fix : Bool) (sv : SavKey → Option Sav) (c : Core) :
    (SavKey → Option Sav) × Core × Bool :=
  if c.dirty then
    if writable (savKey c.rom) then (upd sv (savKey c.rom) c.ram, { c with dirty := false }, false)
    else (sv, c, !fix && c.sys == .gba)
  else (sv, c, false)

/-- The process dies: nothing more runs; dirty battery RAM is gone. -/
def crash (s : St) : St :=
  { s with crashed := true, pc := .done, lost := s.lost || dirtyW s.cur || dirtyW s.orphan }

/-- One `run_until_frame` of `c` (see the header). -/
def runFrame (fix : Bool) (s : St) (c : Core) (early late : Bool) : St × Core × Bool :=
  let c1 := if early then write c s.clock else c
  let r := flushX fix s.sav c1
  let c3 := if late && !r.2.2 then write r.2.1 (s.clock + 1) else r.2.1
  ({ s with sav := r.1, clock := s.clock + 2 }, c3, r.2.2)

/-- `flush_gb_save` (477-481): the GB core only. The fix flushes whichever
core is loaded (and catches the GBA write's IOError). -/
def flushCur (fix : Bool) (s : St) : St :=
  match s.cur with
  | some c =>
    if fix || c.sys == .gb then
      let r := flushX true s.sav c
      { s with sav := r.1, cur := some r.2.1 }
    else s
  | none => s

/-- `load_rom` replaces `app.gba_emu`/`app.gb_emu` (707, 714, 723, 726). The
outgoing core is released, unless the netlink still holds it (`NetLink.gba`,
netlink.nim 30): then it lives on as the core the link drives. -/
def dropCur (s : St) : St :=
  match s.cur with
  | none => s
  | some o =>
    if s.link == .linked && s.orphan.isNone then { s with orphan := some o }
    else { s with lost := s.lost || dirtyW (some o) }

/-- `teardown_netlink` (1806-1818), with `link_cancel_setup`: the link is
gone, and with it the netlink's reference to its core. -/
def teardown (s : St) : St :=
  { s with link := .idle, orphan := none, lost := s.lost || dirtyW s.orphan }

def snapOf (c : Core) : Snap := ⟨c.game, c.ram⟩

/-- `refresh_state_slots` (890-923) for the running game. -/
def refresh (s : St) : St :=
  match s.cur with
  | some c =>
    let k := stateKey c.rom
    { s with ssShows := some k, ssUsed := fun i => (s.states k i).isSome }
  | none => { s with ssShows := none, ssUsed := fun _ => false }

/-- `load_state_slot` (844-853): the core refuses another ROM's state
(`srkWrongRom`) and a missing file; restoring marks the battery dirty
(gba savestate.nim 665, gb savestate.nim 755). -/
def loadSlot (s : St) (c : Core) (i : Slot) : St :=
  match s.states (stateKey c.rom) i with
  | some sn => if sn.game = c.game then { s with cur := some { c with ram := sn.ram, dirty := true } } else s
  | none => s

/-- `save_state_slot` (833-842). -/
def saveSlot (s : St) (c : Core) (i : Slot) : St :=
  { s with states := updSt s.states (stateKey c.rom) i (some (snapOf c)) }

/-- `process_pending_state` (925-940): Quick Save, then Quick Load, slot 0. -/
def processPending (s : St) : St :=
  match s.cur with
  | none => s
  | some c =>
    let s1 := if s.pendSave then saveSlot s c .q else s
    let s2 := if s.pendLoad then loadSlot s1 c .q else s1
    { s2 with pendSave := false, pendLoad := false, pendFor := none }

/-- The fix services a pending Quick Save on the outgoing core, which is at a
frame boundary wherever `load_rom` runs (phases input and present). -/
def savePending (s : St) : St :=
  if s.pendSave then
    match s.cur with
    | some c => saveSlot s c .q
    | none => s
  else s

/-- The new core is in (707-731, 743-745, 755-765). -/
def swapIn (s : St) (p r : Path) (g : Game) : St :=
  let c : Core := { id := s.nextId, rom := r, game := g, sys := sysOf r,
                    ram := s.sav (savKey r), dirty := false }
  { s with cur := some c, nextId := s.nextId + 1, hist := none, rewinding := false,
           paused := false, pendSave := false, pendLoad := false, pendFor := none,
           recents := addRecent p s.recents, curPath := some p }

/-- `load_rom(p)` (694-765). With `fix`: validate the ROM before touching
anything, save a pending Quick Save, tear the link down, flush whichever core
is loaded, then swap, and mark the Save States grid stale. -/
def loadRomX (fix : Bool) (s : St) (p : Path) : St :=
  if s.present p = false then s                                    -- 695-696
  else match romOf p with
  | none => s                                                      -- 701
  | some r =>
    let s1 := { s with present := upd s.present r true }           -- extraction wrote r
    if fix then
      match gameOf r with
      | none => s1                                                 -- "not a ROM" notice
      | some g => refresh (swapIn (dropCur (flushCur true (teardown (savePending s1)))) p r g)
    else
      let s2 := flushCur false s1                                  -- 702
      match gameOf r with
      | none => crash s2                                           -- new_gb raises
      | some g => swapIn (dropCur s2) p r g

/-- `finish_link` (1826-1848) from `service_link_setup`: binds `app.gba_emu`;
with a GB game loaded that is nil, and `new_net_core`'s
`gba.set_sio_driver` dereferences it. -/
def finishLink (s : St) : St :=
  match s.cur with
  | some c =>
    if c.sys == .gba then { s with link := .linked, hist := none, rewinding := false } else crash s
  | none => crash s

/-- Reset: `load_rom(app.cfg.recents[0])` (1371, 1648); the fix loads
`app.cur_path`. -/
def resetX (fix : Bool) (s : St) : St :=
  if fix then
    match s.curPath with
    | some p => loadRomX true s p
    | none => s
  else
    match s.recents with
    | p :: _ => loadRomX false s p
    | [] => s

/-- Main loop 2430-2486: rewind pop, else a frame of the app's core, or,
linked with a GBA core loaded, of the netlink's core; then the rewind push. -/
def frameX (fix : Bool) (s : St) (due early late : Bool) : St :=
  let s0 := { s with pc := .pend }
  if !due then s0
  else if s.rewinding && s.cur.isSome && s.link != .linked then
    match s.cur, s.hist with                                       -- 2432-2450
    | some c, some (_, r) => { s0 with cur := some { c with ram := r, dirty := true } }
    | _, _ => s0
  else if s.paused then s0
  else match s.cur with
    | none => s0
    | some c =>
      if c.sys == .gba && s.link == .linked then                   -- 2455-2468
        match s.orphan with
        | some o =>
          let r := runFrame fix s0 o early late
          if r.2.2 then crash { r.1 with orphan := some r.2.1 } else { r.1 with orphan := some r.2.1 }
        | none =>
          let r := runFrame fix s0 c early late
          if r.2.2 then crash { r.1 with cur := some r.2.1 } else { r.1 with cur := some r.2.1 }
      else
        let r := runFrame fix s0 c early late                      -- 2469-2475
        if r.2.2 then crash { r.1 with cur := some r.2.1 }
        else { r.1 with cur := some r.2.1,
                        hist := if s.link == .linked then s.hist else some (c.id, r.2.1.ram) } -- 2478-2486

/-- After the loop (2606): `flush_gb_save()`; the fix flushes either core. -/
def exitX (fix : Bool) (s : St) : St :=
  let s1 := flushCur fix s
  { s1 with pc := .done, lost := s1.lost || dirtyW s1.cur || dirtyW s1.orphan }

def isGba (s : St) : Bool :=
  match s.cur with
  | some c => c.sys == .gba
  | none => false

def body (fix : Bool) (s : St) : Ev → St
  | .frame due early late => frameX fix s due early late
  | .peerGone =>                                                   -- 2462-2468
    if s.link == .linked && isGba s && !s.paused then { teardown s with pc := .pend } else s
  | .pend =>                                                       -- 2522-2523
    let s := { s with pc := .input }
    if (s.pendSave || s.pendLoad) && s.cur.isSome then processPending s else s
  | .drop p => loadRomX fix s p                                    -- 1761-1767
  | .ctrlR => resetX fix s                                         -- 1647-1648
  | .ctrlP => { s with paused := !s.paused }                       -- 1649-1650
  | .ctrlS =>                                                      -- 1655-1656
    match s.cur with
    | some c => { s with pendSave := true, pendFor := some c.id }
    | none => s
  | .ctrlL =>                                                      -- 1657-1660
    match s.cur with
    | some c => if s.link != .linked then { s with pendLoad := true, pendFor := some c.id } else s
    | none => s
  | .quit => { s with running := false }                           -- 1665, 1769
  | .rewindKey b =>                                                -- 1674-1677
    { s with rewinding := b && s.cur.isSome && s.link != .linked }
  | .endInput => { s with pc := .link }
  | .service peer =>                                               -- 2548-2549
    let s := { s with pc := .present }
    match s.link with
    | .setup _ => if peer then finishLink s else s
    | _ => s
  | .recent i =>                                                   -- 1297-1300
    match s.recents[i]? with
    | some p => loadRomX fix s p
    | none => s
  | .openFile p => loadRomX fix s p                                -- 1473-1474
  | .clear => { s with recents := [] }                             -- 1302-1304
  | .reset => resetX fix s                                         -- 1366-1371
  | .exit => { s with running := false }                           -- 1322-1323
  | .quickSave =>                                                  -- 1308-1310
    match s.cur with
    | some c => { s with pendSave := true, pendFor := some c.id }
    | none => s
  | .quickLoad =>                                                  -- 1311-1313 (not disabled while linked)
    match s.cur with
    | some c => { s with pendLoad := true, pendFor := some c.id }
    | none => s
  | .ssOpen => if s.cur.isSome then refresh { s with ssWin := true } else s -- 1314; widget on_open
  | .ssClose => { s with ssWin := false }
  | .ssSave i =>                                                   -- widget Save, on_save + on_open
    match s.cur with
    | some c => if s.ssWin then refresh (saveSlot s c i) else s
    | none => s
  | .ssDelete i =>                                                 -- widget Delete (enabled by slots[i].used)
    match s.cur with
    | some c =>
      if s.ssWin && s.ssUsed i then
        let k := stateKey c.rom
        let unseen := s.ssShows != some k && (s.states k i).isSome
        refresh { s with states := updSt s.states k i none, unseenDelete := s.unseenDelete || unseen }
      else s
    | none => s
  | .ssLoad i =>                                                   -- widget Load, on_load
    match s.cur with
    | some c => if s.ssWin && s.ssUsed i then loadSlot s c i else s
    | none => s
  | .linkOpen =>                                                   -- 1377-1379 (GBA only), 2094-2100
    if isGba s then
      if s.linkWin then
        { s with linkWin := false, link := if s.link == .setup true then .idle else s.link }
      else
        { s with linkWin := true, link := if s.link == .idle then .setup true else s.link }
    else s
  | .linkHost =>                                                   -- 2042-2043 (link_ready only)
    if s.linkWin && isGba s && s.link != .linked then { s with link := .setup false } else s
  | .linkClose =>                                                  -- window X; 2101-2102
    { s with linkWin := false, link := if s.link == .setup true then .idle else s.link }
  | .disconnect =>                                                 -- 2066-2068
    if s.linkWin && s.link == .linked then teardown s else s
  | .endPresent => { s with pc := .tail }
  | .loopTop => if s.running then { s with pc := .emu } else exitX fix s  -- 2426, 2606
  | .rmFile p => { s with present := upd s.present p false }

def stepX (fix : Bool) (s : St) (e : Ev) : St :=
  match e.phase with
  | none => body fix s e
  | some ph => if ph = s.pc then body fix s e else s

/-- The code. -/
def step : St → Ev → St := stepX false
/-- The proposed fix. -/
def stepF : St → Ev → St := stepX true

/-- The core the main loop advances: linked with a GBA game loaded, the
netlink's core (2455-2460); otherwise the app's. -/
def driven (s : St) : Option Core :=
  if s.link == .linked && isGba s then
    match s.orphan with
    | some o => some o
    | none => s.cur
  else s.cur

def run (s : St) (es : List Ev) : St := es.foldl step s
def runF (s : St) (es : List Ev) : St := es.foldl stepF s

inductive Reachable : St → Prop
  | init (rs : List Path) : Reachable (initR rs)
  | step {s} (e : Ev) : Reachable s → Reachable (step s e)

inductive ReachableF : St → Prop
  | init (rs : List Path) : ReachableF (initR rs)
  | step {s} (e : Ev) : ReachableF s → ReachableF (stepF s e)

/-! ## Traces

`iter f ins ui`: one main-loop iteration from phase `emu`: the frame event
`f`, the pending check, the SDL events `ins`, the link service (no peer),
the ImGui clicks `ui`, and the loop test. -/

def iter (f : Ev) (ins ui : List Ev) : List Ev :=
  [f, .pend] ++ ins ++ [.endInput, .service false] ++ ui ++ [.endPresent, .loopTop]

/-- A frame that is not due. -/
def idle : Ev := .frame false false false
/-- A frame in which the cart writes its battery before the frame's etSaves. -/
def wEarly : Ev := .frame true true false
/-- A frame in which the cart writes its battery after the frame's etSaves. -/
def wLate : Ev := .frame true false true

/-! ## Counterexamples against the code -/

/-- **GBA battery dropped on a switch.** A GBA game writes its save in the
frame before the user drops another ROM: `load_rom` flushes only a GB core
(702), and the GBA core is released with the write still in RAM. -/
theorem bug_gba_switch_drops_dirty_battery :
    let s := run init (iter idle [.drop .aGba] [] ++ iter wLate [.drop .bGba] [])
    s.lost = true ∧ s.sav .rA = none := by decide

/-- **GBA battery dropped at quit.** After the loop only `flush_gb_save` runs
(2606). -/
theorem bug_gba_quit_drops_dirty_battery :
    let s := run init (iter idle [.drop .aGba] [] ++ iter wLate [.quit] [])
    s.pc = .done ∧ s.crashed = false ∧ s.lost = true ∧ s.sav .rA = none := by decide

/-- The paused trigger: play A (its save reaches disk), Quick Save, play on
(a newer save reaches disk), pause, Quick Load, quit. The state's battery was
restored into the core, marked dirty, and never written: a paused core runs
no `etSaves`, and nothing flushes a GBA core at quit. -/
def pausedLoadTrace (p : Path) : List Ev :=
  iter idle [.drop p] [] ++ iter wEarly [.ctrlS] [] ++ iter idle [] [] ++
  iter wEarly [.ctrlP] [] ++ iter idle [.ctrlL] [] ++ iter idle [.quit] []

theorem bug_gba_paused_state_load_not_persisted :
    let s := run init (pausedLoadTrace .aGba)
    s.lost = true ∧ s.sav .rA = some ⟨.A, 2⟩ ∧ s.states .aGba .q = some ⟨.A, some ⟨.A, 0⟩⟩ := by
  decide

/-- The same steps on a GB game do write the restored battery at quit. -/
theorem gb_same_trace_persists :
    let s := run init (pausedLoadTrace .cGb)
    s.lost = false ∧ s.sav .rC = some ⟨.C, 0⟩ := by decide

/-- **A short `.gb` kills the app.** Dropping a zero-byte (or truncated)
`.gb` raises IndexDefect in `load_cartridge` (checked headlessly: "index out
of bounds, the container is empty"); nothing catches it. -/
theorem bug_empty_gb_crashes :
    let s := run init (iter idle [.drop .aGba] [] ++ iter idle [.drop .eGb] [])
    s.crashed = true ∧ s.pc = .done := by decide

/-- **A GBA game in a read-only folder kills the app at its first save.**
`write_save` has no `try` (checked headlessly: IOError "cannot open: …/g.sav"). -/
theorem bug_readonly_gba_crashes :
    let s := run init (iter idle [.drop .roGba] [] ++ [wEarly])
    s.crashed = true := by decide

/-- Link A to a peer (the Link Cable window auto-pairs). -/
def linkA : List Ev :=
  iter idle [.drop .aGba] [.linkOpen] ++
  [idle, .pend, .endInput, .service true, .endPresent, .loopTop]

/-- **Reset while linked drives the old core.** `load_rom` never tears the link
down; `netlink.gba` is still the outgoing core, and the main loop's ekGBA
branch steps `app.netlink` (2460), not `app.gba_emu`. The new core never runs
(the screen freezes on its first frame), the old one keeps playing the link
with no input and keeps writing `A.sav`, which the new core read before. -/
theorem bug_reset_while_linked_runs_outgoing_core :
    let s := run init (linkA ++ iter idle [.ctrlR] [] ++ iter wEarly [] [])
    s.link = .linked ∧ (s.cur.map Core.id, s.orphan.map Core.id) = (some 2, some 1) ∧
    (driven s).map Core.id = some 1 ∧
    s.cur.bind Core.ram = none ∧ s.sav .rA = some ⟨.A, 0⟩ := by decide

/-- **Switching to a GB game while linked keeps the link.** Linked, the Link
Cable window closed, a GB ROM is dropped. The netlink is never stepped again
(ekGB branch) and never torn down; rewind and Ctrl+L stay disabled for the GB
game (`app.netlink != nil`), and the only Disconnect button is in the Link
Cable window, whose menu item is disabled for a GB game. -/
def gbWhileLinked : List Ev :=
  linkA ++ iter idle [] [.linkClose] ++ iter idle [.drop .cGb] [] ++ [idle, .pend]

theorem bug_gb_switch_keeps_link :
    let s := run init gbWhileLinked
    s.pc = .input ∧ s.link = .linked ∧ s.cur.map Core.sys = some .gb ∧ s.orphan.isSome ∧
    (step s (.rewindKey true)).rewinding = false ∧ (step s .ctrlL).pendLoad = false ∧
    (run s [.endInput, .service false, .linkOpen]).linkWin = false ∧
    (run s [.endInput, .service false, .endPresent, .loopTop, .peerGone]).link = .linked := by
  decide

/-- **A link set up for a GBA game completes after a switch to GB: SIGSEGV.**
Open Link Cable (auto-pair starts), drop a GB ROM with the window still open,
and let the peer arrive: `finish_link` hands `app.gba_emu = nil` to
`new_net_core`, which calls `gba.set_sio_driver`. -/
theorem bug_link_setup_crash_after_gb_switch :
    let s := run init (iter idle [.drop .aGba] [.linkOpen] ++
                       [idle, .pend, .drop .cGb, .endInput, .service true])
    s.crashed = true := by decide

/-- **The Save States grid keeps the previous game's slots.** `load_rom` does
not refresh or close the window; its grid (and which slots are `used`, which
enables Delete and Load) belongs to the old game, while Save, Load and Delete
act on the new game's files (`state_file_path` of the current ROM). Here B's
slot 2 is deleted from a window showing A's thumbnail in that slot. -/
theorem bug_save_states_grid_stale_delete :
    let s := run init (iter idle [.drop .bGba] [.ssOpen, .ssSave .s1, .ssClose] ++
                       iter idle [.drop .aGba] [.ssOpen, .ssSave .s1] ++
                       iter idle [.drop .bGba] [.ssDelete .s1])
    s.unseenDelete = true ∧ s.states .bGba .s1 = none ∧ s.states .aGba .s1 ≠ none := by decide

/-- **Reset does nothing after File > Recent > Clear.** Reset is
`load_rom(recents[0])`, guarded by `recents.len > 0`. -/
theorem bug_reset_after_clear_is_noop :
    let s := run init (iter idle [.drop .aGba] [.clear] ++ iter wEarly [] [])
    (step (run s [idle, .pend]) .ctrlR).cur = (run s [idle, .pend]).cur ∧
    s.cur.map Core.id = some 1 := by decide

/-- **A Quick Save pressed just before a switch is dropped** (both in one
`handle_input` batch, or Ctrl+S then a menu load in the same iteration):
`load_rom` clears `pending_save` (764). Sub-frame window. -/
theorem bug_quick_save_dropped_by_switch :
    let s := run init (iter idle [.drop .aGba] [] ++ iter idle [.ctrlS, .drop .bGba] [] ++
                       iter idle [] [])
    s.states .aGba .q = none ∧ s.states .bGba .q = none := by decide

/-! ### Identity: which file each game's artefacts go to -/

/-- **Same stem, other extension: one `.sav`.** `/r/P.gb` and `/r/P.gbc` both
use `/r/P.sav` (and `/r/P.cht`): P2 boots on P1's battery and its first save
replaces it. -/
theorem bug_battery_shared_by_stem :
    let s1 := run init (iter idle [.drop .pGb] [] ++ iter wEarly [.drop .pGbc] [])
    let s2 := run s1 [wEarly]
    s1.cur.map Core.game = some .P2 ∧ s1.cur.bind Core.ram = some ⟨.P1, 0⟩ ∧
    s2.sav .rP = some ⟨.P2, 2⟩ := by decide

/-- **Same file name, other folder: one set of state slots.** `/r/A.gba` and
`/s/A.gba` (game X) share `states/A.gba.state`: X's Quick Save replaces A's
(the ROM check then refuses it in A: "belongs to a different game"). -/
theorem bug_state_slot_shared_by_file_name :
    let s1 := run init (iter idle [.drop .aGba] [.quickSave] ++ iter idle [.drop .xGba] [.quickSave])
    let s2 := run s1 (iter idle [] [])
    (s1.states .aGba .q).map Snap.game = some .A ∧ (s2.states .aGba .q).map Snap.game = some .X := by
  decide

/-- **One zip, two identities.** The zip cache is keyed by the path string
as given, so `dingbat z.zip` from a terminal and dragging `/r/z.zip` extract to
different folders: the save made in one is not there in the other. -/
theorem bug_zip_identity_split :
    let s := run init (iter idle [.drop .zRel] [] ++ iter wEarly [.drop .zAbs] [])
    s.cur.map Core.game = some .Z ∧ s.cur.bind Core.ram = none ∧ s.sav .zcRel = some ⟨.Z, 0⟩ := by
  decide

/-! ## What the code keeps

`Keep` holds in every state either step reaches: pending Quick Save/Load and
the rewind history always belong to the running core, the running core was
built from what its path names, and `recents[0]` (when there is one) and the
ghost `curPath` name the running game. -/

/-- What identifies a core object: which constructor call, from which file. -/
def key (c : Core) : Nat × Path × Game × Sys := (c.id, c.rom, c.game, c.sys)

structure Keep (s : St) : Prop where
  pend : s.pendSave = true ∨ s.pendLoad = true → ∃ c, s.cur = some c ∧ s.pendFor = some c.id
  hist : ∀ i r, s.hist = some (i, r) → ∃ c, s.cur = some c ∧ c.id = i
  core : ∀ c, s.cur = some c → c.id < s.nextId ∧ gameOf c.rom = some c.game ∧ c.sys = sysOf c.rom
  recent : ∀ c, s.cur = some c → s.recents = [] ∨ ∃ p rest, s.recents = p :: rest ∧ romOf p = some c.rom
  path : ∀ c, s.cur = some c → ∃ p, s.curPath = some p ∧ romOf p = some c.rom

/-- `t` agrees with `s` on what `Keep` reads, except that pending flags may
be cleared or set for the running core, and the history may be emptied or
refilled from the running core. -/
structure Same (s t : St) : Prop where
  cur : t.cur.map key = s.cur.map key
  recents : t.recents = s.recents
  curPath : t.curPath = s.curPath
  nextId : t.nextId = s.nextId
  pend : t.pendSave = true ∨ t.pendLoad = true →
    ((s.pendSave = true ∨ s.pendLoad = true) ∧ t.pendFor = s.pendFor) ∨
    ∃ c, s.cur = some c ∧ t.pendFor = some c.id
  hist : ∀ i r, t.hist = some (i, r) → s.hist = some (i, r) ∨ ∃ c, s.cur = some c ∧ c.id = i

theorem map_key_fwd {s t : St} (h : t.cur.map key = s.cur.map key) {c : Core}
    (hc : s.cur = some c) : ∃ c', t.cur = some c' ∧ key c' = key c := by
  rw [hc] at h
  cases ht : t.cur with
  | none => rw [ht] at h; cases h
  | some c' => rw [ht] at h; exact ⟨c', rfl, Option.some.inj h⟩

theorem map_key_bwd {s t : St} (h : t.cur.map key = s.cur.map key) {c' : Core}
    (hc : t.cur = some c') : ∃ c, s.cur = some c ∧ key c' = key c := by
  rw [hc] at h
  cases hs : s.cur with
  | none => rw [hs] at h; cases h
  | some c => rw [hs] at h; exact ⟨c, rfl, Option.some.inj h⟩

theorem key_eq {c c' : Core} (h : key c' = key c) :
    c'.id = c.id ∧ c'.rom = c.rom ∧ c'.game = c.game ∧ c'.sys = c.sys := by
  simp only [key, Prod.mk.injEq] at h
  exact h

theorem keep_of_same {s t : St} (h : Keep s) (hs : Same s t) : Keep t where
  pend := by
    intro hp
    rcases hs.pend hp with ⟨hp', hf⟩ | ⟨c, hc, hf⟩
    · obtain ⟨c, hc, hcf⟩ := h.pend hp'
      obtain ⟨c', hc', hk⟩ := map_key_fwd hs.cur hc
      exact ⟨c', hc', by rw [hf, hcf, (key_eq hk).1]⟩
    · obtain ⟨c', hc', hk⟩ := map_key_fwd hs.cur hc
      exact ⟨c', hc', by rw [hf, (key_eq hk).1]⟩
  hist := by
    intro i r hh
    rcases hs.hist i r hh with hh' | ⟨c, hc, hi⟩
    · obtain ⟨c, hc, hi⟩ := h.hist i r hh'
      obtain ⟨c', hc', hk⟩ := map_key_fwd hs.cur hc
      exact ⟨c', hc', by rw [(key_eq hk).1, hi]⟩
    · obtain ⟨c', hc', hk⟩ := map_key_fwd hs.cur hc
      exact ⟨c', hc', by rw [(key_eq hk).1, hi]⟩
  core := by
    intro c' hc'
    obtain ⟨c, hc, hk⟩ := map_key_bwd hs.cur hc'
    obtain ⟨h1, h2, h3, h4⟩ := key_eq hk
    obtain ⟨k1, k2, k3⟩ := h.core c hc
    rw [hs.nextId, h1, h2, h3, h4]
    exact ⟨k1, k2, k3⟩
  recent := by
    intro c' hc'
    obtain ⟨c, hc, hk⟩ := map_key_bwd hs.cur hc'
    rw [hs.recents, (key_eq hk).2.1]
    exact h.recent c hc
  path := by
    intro c' hc'
    obtain ⟨c, hc, hk⟩ := map_key_bwd hs.cur hc'
    rw [hs.curPath, (key_eq hk).2.1]
    exact h.path c hc

/-- The usual case: nothing `Keep` reads changes but the running core's
RAM/dirty flag. -/
theorem same_of {s t : St} (hc : t.cur.map key = s.cur.map key) (hr : t.recents = s.recents)
    (hp : t.curPath = s.curPath) (hn : t.nextId = s.nextId) (hps : t.pendSave = s.pendSave)
    (hpl : t.pendLoad = s.pendLoad) (hpf : t.pendFor = s.pendFor) (hh : t.hist = s.hist) :
    Same s t where
  cur := hc
  recents := hr
  curPath := hp
  nextId := hn
  pend := fun h => Or.inl ⟨by rw [hps, hpl] at h; exact h, hpf⟩
  hist := fun i r h => Or.inl (by rw [hh] at h; exact h)

theorem keep_eqs {s t : St} (h : Keep s) (hc : t.cur = s.cur) (hr : t.recents = s.recents)
    (hp : t.curPath = s.curPath) (hn : t.nextId = s.nextId) (hps : t.pendSave = s.pendSave)
    (hpl : t.pendLoad = s.pendLoad) (hpf : t.pendFor = s.pendFor) (hh : t.hist = s.hist) :
    Keep t :=
  keep_of_same h (same_of (by rw [hc]) hr hp hn hps hpl hpf hh)

theorem flushX_key (fix : Bool) (sv : SavKey → Option Sav) (c : Core) :
    key (flushX fix sv c).2.1 = key c := by
  unfold flushX
  split
  · split <;> rfl
  · rfl

theorem write_key (c : Core) (v : Nat) : key (write c v) = key c := rfl

theorem runFrame_key (fix : Bool) (s : St) (c : Core) (early late : Bool) :
    key (runFrame fix s c early late).2.1 = key c := by
  simp only [runFrame]
  generalize hc1 : (if early then write c s.clock else c) = c1
  have h1 : key c1 = key c := by rw [← hc1]; split <;> rfl
  generalize hr : flushX fix s.sav c1 = r
  have h2 : key r.2.1 = key c := by rw [← hr, flushX_key]; exact h1
  split
  · rw [write_key]; exact h2
  · exact h2

theorem keep_crash {s : St} (h : Keep s) : Keep (crash s) :=
  keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl

theorem keep_flushCur (fix : Bool) {s : St} (h : Keep s) : Keep (flushCur fix s) := by
  unfold flushCur
  split
  · rename_i c hc
    split
    · exact keep_of_same h (same_of (by simp [hc, flushX_key]) rfl rfl rfl rfl rfl rfl rfl)
    · exact h
  · exact h

theorem keep_dropCur {s : St} (h : Keep s) : Keep (dropCur s) := by
  unfold dropCur
  split
  · exact h
  · split
    · exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
    · exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl

theorem keep_teardown {s : St} (h : Keep s) : Keep (teardown s) :=
  keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl

theorem keep_refresh {s : St} (h : Keep s) : Keep (refresh s) := by
  unfold refresh
  split
  · exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
  · exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl

theorem keep_saveSlot {s : St} (c : Core) (i : Slot) (h : Keep s) : Keep (saveSlot s c i) :=
  keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl

theorem keep_savePending {s : St} (h : Keep s) : Keep (savePending s) := by
  unfold savePending
  split
  · split
    · exact keep_saveSlot _ _ h
    · exact h
  · exact h

theorem keep_loadSlot {s : St} {c : Core} (i : Slot) (h : Keep s) (hc : s.cur = some c) :
    Keep (loadSlot s c i) := by
  unfold loadSlot
  split
  · split
    · exact keep_of_same h (same_of (by rw [hc]; rfl) rfl rfl rfl rfl rfl rfl rfl)
    · exact h
  · exact h

theorem keep_clear_pend {s : St} (h : Keep s) :
    Keep { s with pendSave := false, pendLoad := false, pendFor := none } where
  pend := fun hp => by simp at hp
  hist := h.hist
  core := h.core
  recent := h.recent
  path := h.path

theorem keep_processPending {s : St} (h : Keep s) : Keep (processPending s) := by
  unfold processPending
  split
  · exact h
  · rename_i c hc
    dsimp only
    have h1 : Keep (if s.pendSave = true then saveSlot s c .q else s) := by
      split
      · exact keep_saveSlot _ _ h
      · exact h
    have hc1 : (if s.pendSave = true then saveSlot s c .q else s).cur = some c := by
      split
      · exact hc
      · exact hc
    have h2 : Keep (if s.pendLoad = true then
        loadSlot (if s.pendSave = true then saveSlot s c .q else s) c .q
        else (if s.pendSave = true then saveSlot s c .q else s)) := by
      split
      · exact keep_loadSlot _ h1 hc1
      · exact h1
    exact keep_clear_pend h2

theorem addRecent_head (p : Path) (rs : List Path) : ∃ rest, addRecent p rs = p :: rest :=
  ⟨(rs.erase p).take 7, rfl⟩

theorem keep_swapIn (s : St) {p r : Path} {g : Game} (hr : romOf p = some r)
    (hg : gameOf r = some g) : Keep (swapIn s p r g) where
  pend := fun hp => by simp [swapIn] at hp
  hist := fun i r hh => by simp [swapIn] at hh
  core := by
    intro c hc
    simp only [swapIn, Option.some.injEq] at hc
    subst hc
    exact ⟨Nat.lt_succ_self _, hg, rfl⟩
  recent := by
    intro c hc
    simp only [swapIn, Option.some.injEq] at hc
    subst hc
    obtain ⟨rest, hrest⟩ := addRecent_head p s.recents
    exact Or.inr ⟨p, rest, hrest, hr⟩
  path := by
    intro c hc
    simp only [swapIn, Option.some.injEq] at hc
    subst hc
    exact ⟨p, rfl, hr⟩

theorem keep_loadRomX (fix : Bool) {s : St} (p : Path) (h : Keep s) : Keep (loadRomX fix s p) := by
  unfold loadRomX
  split
  · exact h
  · split
    · exact h
    · rename_i r hr
      have h1 : Keep { s with present := upd s.present r true } :=
        keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
      dsimp only
      split
      · split
        · exact h1
        · rename_i g hg
          exact keep_refresh (keep_swapIn _ hr hg)
      · split
        · exact keep_crash (keep_flushCur _ h1)
        · rename_i g hg
          exact keep_swapIn _ hr hg

theorem keep_finishLink {s : St} (h : Keep s) : Keep (finishLink s) := by
  unfold finishLink
  split
  · split
    · exact keep_of_same h ⟨rfl, rfl, rfl, rfl, fun hp => Or.inl ⟨hp, rfl⟩,
        fun i r hh => by simp at hh⟩
    · exact keep_crash h
  · exact keep_crash h

theorem keep_resetX (fix : Bool) {s : St} (h : Keep s) : Keep (resetX fix s) := by
  unfold resetX
  split
  · split
    · exact keep_loadRomX _ _ h
    · exact h
  · split
    · exact keep_loadRomX _ _ h
    · exact h

theorem keep_frameX (fix : Bool) {s : St} (due early late : Bool) (h : Keep s) :
    Keep (frameX fix s due early late) := by
  have h0 : Keep { s with pc := .pend } := keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
  unfold frameX
  dsimp only
  split
  · exact h0
  · split
    · split
      · rename_i c _ hc _
        exact keep_of_same h0 (same_of (by rw [hc]; rfl) rfl rfl rfl rfl rfl rfl rfl)
      · exact h0
    · split
      · exact h0
      · split
        · exact h0
        · rename_i c hc
          split
          · split
            · rename_i o _
              split
              · exact keep_crash (keep_eqs h0 rfl rfl rfl rfl rfl rfl rfl rfl)
              · exact keep_eqs h0 rfl rfl rfl rfl rfl rfl rfl rfl
            · split
              · exact keep_crash (keep_of_same h0 (same_of (by simp [hc, runFrame_key])
                  rfl rfl rfl rfl rfl rfl rfl))
              · exact keep_of_same h0 (same_of (by simp [hc, runFrame_key])
                  rfl rfl rfl rfl rfl rfl rfl)
          · split
            · exact keep_crash (keep_of_same h0 (same_of (by simp [hc, runFrame_key])
                rfl rfl rfl rfl rfl rfl rfl))
            · refine keep_of_same h0 ⟨by simp [hc, runFrame_key], rfl, rfl, rfl,
                fun hp => Or.inl ⟨hp, rfl⟩, ?_⟩
              intro i r hh
              split at hh
              · exact Or.inl hh
              · simp only [Option.some.injEq, Prod.mk.injEq] at hh
                exact Or.inr ⟨c, hc, hh.1⟩

theorem keep_exitX (fix : Bool) {s : St} (h : Keep s) : Keep (exitX fix s) :=
  keep_eqs (keep_flushCur fix h) rfl rfl rfl rfl rfl rfl rfl rfl

theorem keep_setPend {s : St} {c : Core} (h : Keep s) (hc : s.cur = some c) (a b : Bool) :
    Keep { s with pendSave := a || s.pendSave, pendLoad := b || s.pendLoad, pendFor := some c.id } :=
  keep_of_same h ⟨rfl, rfl, rfl, rfl, fun _ => Or.inr ⟨c, hc, rfl⟩,
    fun _ _ hh => Or.inl hh⟩

theorem keep_body (fix : Bool) {s : St} (e : Ev) (h : Keep s) : Keep (body fix s e) := by
  cases e with
  | frame due early late => exact keep_frameX fix due early late h
  | peerGone =>
    simp only [body]
    split
    · exact keep_eqs (keep_teardown h) rfl rfl rfl rfl rfl rfl rfl rfl
    · exact h
  | pend =>
    simp only [body]
    split
    · exact keep_processPending (keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl)
    · exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
  | drop p => exact keep_loadRomX fix p h
  | ctrlR => exact keep_resetX fix h
  | ctrlP => exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
  | ctrlS =>
    simp only [body]
    split
    · rename_i c hc
      have := keep_setPend h hc true false
      simpa using this
    · exact h
  | ctrlL =>
    simp only [body]
    split
    · rename_i c hc
      split
      · have := keep_setPend h hc false true
        simpa using this
      · exact h
    · exact h
  | quit => exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
  | rewindKey b => exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
  | endInput => exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
  | service peer =>
    simp only [body]
    have h0 : Keep { s with pc := .present } := keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
    split
    · split
      · exact keep_finishLink h0
      · exact h0
    · exact h0
  | recent i =>
    simp only [body]
    split
    · exact keep_loadRomX fix _ h
    · exact h
  | openFile p => exact keep_loadRomX fix p h
  | clear => exact ⟨h.pend, h.hist, h.core, fun _ _ => Or.inl rfl, h.path⟩
  | reset => exact keep_resetX fix h
  | exit => exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
  | quickSave =>
    simp only [body]
    split
    · rename_i c hc
      have := keep_setPend h hc true false
      simpa using this
    · exact h
  | quickLoad =>
    simp only [body]
    split
    · rename_i c hc
      have := keep_setPend h hc false true
      simpa using this
    · exact h
  | ssOpen =>
    simp only [body]
    split
    · exact keep_refresh (keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl)
    · exact h
  | ssClose => exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
  | ssSave i =>
    simp only [body]
    split
    · split
      · exact keep_refresh (keep_saveSlot _ _ h)
      · exact h
    · exact h
  | ssDelete i =>
    simp only [body]
    split
    · split
      · exact keep_refresh (keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl)
      · exact h
    · exact h
  | ssLoad i =>
    simp only [body]
    split
    · rename_i c hc
      split
      · exact keep_loadSlot _ h hc
      · exact h
    · exact h
  | linkOpen =>
    simp only [body]
    split
    · split
      · exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
      · exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
    · exact h
  | linkHost =>
    simp only [body]
    split
    · exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
    · exact h
  | linkClose => exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
  | disconnect =>
    simp only [body]
    split
    · exact keep_teardown h
    · exact h
  | endPresent => exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
  | loopTop =>
    simp only [body]
    split
    · exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl
    · exact keep_exitX fix h
  | rmFile p => exact keep_eqs h rfl rfl rfl rfl rfl rfl rfl rfl

theorem keep_stepX (fix : Bool) {s : St} (e : Ev) (h : Keep s) : Keep (stepX fix s e) := by
  unfold stepX
  split
  · exact keep_body fix e h
  · split
    · exact keep_body fix e h
    · exact h

theorem keep_init (rs : List Path) : Keep (initR rs) where
  pend := fun hp => by simp [initR] at hp
  hist := fun i r hh => by simp [initR] at hh
  core := fun c hc => by simp [initR] at hc
  recent := fun c hc => by simp [initR] at hc
  path := fun c hc => by simp [initR] at hc

theorem keep_reachable {s : St} (h : Reachable s) : Keep s := by
  induction h with
  | init rs => exact keep_init rs
  | step e _ ih => exact keep_stepX false e ih

theorem keep_reachableF {s : St} (h : ReachableF s) : Keep s := by
  induction h with
  | init rs => exact keep_init rs
  | step e _ ih => exact keep_stepX true e ih

/-- A pending Quick Save/Load always acts on the game it was asked of: the
flags are set only with a core loaded, and `load_rom` clears them (764-765). -/
theorem pend_current {s : St} (h : Reachable s) (hp : s.pendSave = true ∨ s.pendLoad = true) :
    ∃ c, s.cur = some c ∧ s.pendFor = some c.id :=
  (keep_reachable h).pend hp

/-- Rewind never applies another game's snapshot: `load_rom` clears the
history (744) and only the app's own core pushes to it. -/
theorem hist_current {s : St} (h : Reachable s) {i : Nat} {r : Option Sav}
    (hh : s.hist = some (i, r)) : ∃ c, s.cur = some c ∧ c.id = i :=
  (keep_reachable h).hist i r hh

/-- While a game runs, `recents[0]` names it, unless the list was cleared. -/
theorem reset_target {s : St} (h : Reachable s) {c : Core} (hc : s.cur = some c) :
    s.recents = [] ∨ ∃ p rest, s.recents = p :: rest ∧ romOf p = some c.rom :=
  (keep_reachable h).recent c hc

/-- A missing file (695-696), or a zip with no ROM in it (701), changes nothing:
the running game keeps running. -/
theorem failed_lookup_keeps_game (fix : Bool) (s : St) (p : Path)
    (h : s.present p = false ∨ romOf p = none) : loadRomX fix s p = s := by
  unfold loadRomX
  rcases h with h | h
  · simp [h]
  · split
    · rfl
    · simp [h]

theorem flushCur_nextId (fix : Bool) (s : St) : (flushCur fix s).nextId = s.nextId := by
  unfold flushCur; split
  · split <;> rfl
  · rfl

theorem dropCur_nextId (s : St) : (dropCur s).nextId = s.nextId := by
  unfold dropCur; split
  · rfl
  · split <;> rfl

theorem flushCur_link (fix : Bool) (s : St) : (flushCur fix s).link = s.link := by
  unfold flushCur; split
  · split <;> rfl
  · rfl

theorem dropCur_link (s : St) : (dropCur s).link = s.link := by
  unfold dropCur; split
  · rfl
  · split <;> rfl

/-- **Reset restarts the running game** when `recents` is not empty and the
file is still there: a fresh core (new object, clean battery read from disk)
of the same ROM file, and, unlinked, it is the core the loop runs. -/
theorem reset_restarts {s : St} (h : Reachable s) (hpc : s.pc = .input) {c : Core}
    (hc : s.cur = some c) (hne : s.recents ≠ [])
    (hp : ∀ p rest, s.recents = p :: rest → s.present p = true) :
    ∃ c', (step s .ctrlR).cur = some c' ∧ c'.game = c.game ∧ c'.rom = c.rom ∧ c'.id ≠ c.id ∧
      c'.dirty = false ∧ (step s .ctrlR).link = s.link := by
  have K := keep_reachable h
  obtain ⟨hid, hg, _⟩ := K.core c hc
  rcases K.recent c hc with hr | ⟨p, rest, hrec, hro⟩
  · exact absurd hr hne
  have hstep : step s .ctrlR = loadRomX false s p := by
    simp [step, stepX, Ev.phase, hpc, body, resetX, hrec]
  rw [hstep]
  unfold loadRomX
  simp only [hp p rest hrec, hro, hg, Bool.true_eq_false, ite_false, Bool.false_eq_true]
  refine ⟨_, rfl, rfl, rfl, ?_, rfl, ?_⟩
  · simp only [dropCur_nextId, flushCur_nextId]
    exact Nat.ne_of_gt hid
  · simp only [swapIn, dropCur_link, flushCur_link]

/-! ## The fix

`stepF` is the code with these changes (Nim, at a2e038f82):

1. `flush_gb_save` (477) becomes `flush_saves`: flush `app.gb_emu`'s
   `mbc_save` *and* `app.gba_emu.storage.write_save()`, the latter in
   `try: … except IOError, OSError:` (and the same `try` in gba.nim
   `handle_saves` 1530-1532, as `mbc_save` already has), so a read-only
   folder is a notice, not a crash. Called where `flush_gb_save` is (702, 2606).
2. `load_rom` (694): validate before touching anything: the ROM file is at
   least 0x150 bytes (GB) / 0xC0 (GBA), and `new_gb`/`new_gba` + `post_init`
   run inside `try … except CatchableError` into locals; on failure show a
   notice and return with the old game running. Only then: service a pending
   Quick Save (`if app.pending_save: process_pending_state()` restricted to the
   save), `link_auto_stop(); link_cancel_setup(); teardown_netlink()`
   (forward-declared: they are defined at 1806-1957), `flush_saves()`, swap
   the cores, and `app.save_states.mark_stale(); app.save_states.notice = ""`.
3. Reset (1371, 1648) loads `app.cur_path`, set by `load_rom` on success,
   instead of `app.cfg.recents[0]`.
4. (Belt and braces, not needed by the proofs:) `finish_link` returns false
   unless `link_ready()`.
-/

structure Safe (s : St) : Prop where
  nocrash : s.crashed = false
  nolost : s.lost = false
  noorphan : s.orphan = none
  linkGba : s.link ≠ .idle → isGba s = true
  grid : s.ssWin = true → s.ssShows = s.cur.map (fun c => stateKey c.rom)
  seen : s.unseenDelete = false

theorem isGba_of_key {s t : St} (h : t.cur.map key = s.cur.map key) : isGba t = isGba s := by
  unfold isGba
  cases ht : t.cur with
  | none =>
    cases hs : s.cur with
    | none => rfl
    | some c => rw [ht, hs] at h; cases h
  | some c' =>
    cases hs : s.cur with
    | none => rw [ht, hs] at h; cases h
    | some c =>
      rw [ht, hs] at h
      have := (key_eq (Option.some.inj h)).2.2.2
      simp [this]

theorem shows_of_key {s t : St} (h : t.cur.map key = s.cur.map key) :
    t.cur.map (fun c => stateKey c.rom) = s.cur.map (fun c => stateKey c.rom) := by
  cases ht : t.cur with
  | none =>
    cases hs : s.cur with
    | none => rfl
    | some c => rw [ht, hs] at h; cases h
  | some c' =>
    cases hs : s.cur with
    | none => rw [ht, hs] at h; cases h
    | some c =>
      rw [ht, hs] at h
      have := (key_eq (Option.some.inj h)).2.1
      simp [this]

theorem safe_eqs {s t : St} (h : Safe s) (hc : t.cur.map key = s.cur.map key)
    (hcr : t.crashed = s.crashed) (hl : t.lost = s.lost) (ho : t.orphan = s.orphan)
    (hk : t.link = s.link) (hw : t.ssWin = s.ssWin) (hsh : t.ssShows = s.ssShows)
    (hu : t.unseenDelete = s.unseenDelete) : Safe t where
  nocrash := by rw [hcr]; exact h.nocrash
  nolost := by rw [hl]; exact h.nolost
  noorphan := by rw [ho]; exact h.noorphan
  linkGba := by rw [hk, isGba_of_key hc]; exact h.linkGba
  grid := by rw [hw, hsh, shows_of_key hc]; exact h.grid
  seen := by rw [hu]; exact h.seen

/-- `safe_eqs` for an update that leaves the core objects alone. -/
theorem safe_same {s t : St} (h : Safe s) (hc : t.cur = s.cur)
    (hcr : t.crashed = s.crashed) (hl : t.lost = s.lost) (ho : t.orphan = s.orphan)
    (hk : t.link = s.link) (hw : t.ssWin = s.ssWin) (hsh : t.ssShows = s.ssShows)
    (hu : t.unseenDelete = s.unseenDelete) : Safe t :=
  safe_eqs h (by rw [hc]) hcr hl ho hk hw hsh hu

theorem flushX_true_ok (sv : SavKey → Option Sav) (c : Core) : (flushX true sv c).2.2 = false := by
  unfold flushX
  split
  · split
    · rfl
    · simp
  · rfl

theorem runFrame_true_ok (s : St) (c : Core) (early late : Bool) :
    (runFrame true s c early late).2.2 = false := by
  simp only [runFrame]; exact flushX_true_ok _ _

theorem flushX_true_clean (sv : SavKey → Option Sav) (c : Core) :
    dirtyW (some (flushX true sv c).2.1) = false := by
  unfold flushX dirtyW
  by_cases hd : c.dirty = true
  · by_cases hw : writable (savKey c.rom) = true
    · simp [hd, hw]
    · simp [hd, hw]
  · simp [hd]

theorem dirtyW_none : dirtyW none = false := rfl

theorem flushX_true_clean' (sv : SavKey → Option Sav) (c : Core) :
    (flushX true sv c).2.1.dirty = true → writable (savKey (flushX true sv c).2.1.rom) = false := by
  have := flushX_true_clean sv c
  simp [dirtyW] at this
  exact this

theorem safe_frameF {s : St} (due early late : Bool) (h : Safe s) :
    Safe (frameX true s due early late) := by
  have h0 : Safe { s with pc := .pend } := safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
  unfold frameX
  dsimp only
  split
  · exact h0
  · split
    · split
      · rename_i c _ hc _
        exact safe_eqs h0 (by rw [hc]; rfl) rfl rfl rfl rfl rfl rfl rfl
      · exact h0
    · split
      · exact h0
      · split
        · exact h0
        · rename_i c hc
          split
          · split
            · rename_i o ho
              exact absurd ho (by rw [h.noorphan]; simp)
            · split
              · rename_i hb; rw [runFrame_true_ok] at hb; cases hb
              · exact safe_eqs h0 (by simp [hc, runFrame_key]) rfl rfl rfl rfl rfl rfl rfl
          · split
            · rename_i hb; rw [runFrame_true_ok] at hb; cases hb
            · exact safe_eqs h0 (by simp [hc, runFrame_key]) rfl rfl rfl rfl rfl rfl rfl

theorem refresh_shows (s : St) : (refresh s).ssShows = s.cur.map (fun c => stateKey c.rom) := by
  unfold refresh; split <;> simp [*]

theorem refresh_cur (s : St) : (refresh s).cur = s.cur := by
  unfold refresh; split <;> rfl

/-- `refresh` touches only the grid, and then the grid shows the running game. -/
theorem safe_refresh {s : St} (h1 : s.crashed = false) (h2 : s.lost = false)
    (h3 : s.orphan = none) (h4 : s.link ≠ .idle → isGba s = true)
    (h6 : s.unseenDelete = false) : Safe (refresh s) where
  nocrash := by unfold refresh; split <;> exact h1
  nolost := by unfold refresh; split <;> exact h2
  noorphan := by unfold refresh; split <;> exact h3
  linkGba := by
    have : isGba (refresh s) = isGba s := by unfold isGba; rw [refresh_cur]
    rw [this]; unfold refresh; split <;> exact h4
  grid := fun _ => by rw [refresh_shows, refresh_cur]
  seen := by unfold refresh; split <;> exact h6

set_option linter.unusedSimpArgs false in
/-- The fixed `load_rom` from a safe state lands in a safe state. -/
theorem safe_loadRomF {s : St} (p : Path) (h : Safe s) : Safe (loadRomX true s p) := by
  unfold loadRomX
  split
  · exact h
  · split
    · exact h
    · rename_i r hr
      dsimp only
      simp only [ite_true]
      split
      · exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
      · rename_i g hg
        have ho := h.noorphan
        have hcr := h.nocrash
        have hl := h.nolost
        have hu := h.seen
        cases hps : s.pendSave <;> cases hc : s.cur <;>
          exact safe_refresh
            (by simp [savePending, teardown, flushCur, dropCur, swapIn, saveSlot, hps, hc, hcr])
            (by simp [savePending, teardown, flushCur, dropCur, swapIn, saveSlot, hps, hc, hl, ho,
                      dirtyW] <;> exact flushX_true_clean' _ _)
            (by simp [savePending, teardown, flushCur, dropCur, swapIn, saveSlot, hps, hc])
            (by simp [savePending, teardown, flushCur, dropCur, swapIn, saveSlot, hps, hc])
            (by simp [savePending, teardown, flushCur, dropCur, swapIn, saveSlot, hps, hc, hu])

theorem finishLink_gba {s : St} (h : isGba s = true) :
    finishLink s = { s with link := .linked, hist := none, rewinding := false } := by
  unfold finishLink
  unfold isGba at h
  split
  · rename_i c hc; rw [hc] at h; simp [h]
  · rename_i hc; rw [hc] at h; cases h

theorem safe_exitF {s : St} (h : Safe s) : Safe (exitX true s) := by
  have ho := h.noorphan
  have hl := h.nolost
  unfold exitX flushCur
  cases hc : s.cur with
  | none =>
    exact safe_same h rfl rfl (by simp [hc, hl, ho, dirtyW]) rfl rfl rfl rfl rfl
  | some c =>
    refine safe_eqs h (by simp [hc, flushX_key]) rfl ?_ rfl rfl rfl rfl rfl
    simp [hl, ho, dirtyW]
    exact flushX_true_clean' _ _

theorem safe_bodyF {s : St} (e : Ev) (h : Safe s) : Safe (body true s e) := by
  cases e with
  | frame due early late => exact safe_frameF due early late h
  | peerGone =>
    simp only [body]
    split
    · exact ⟨h.nocrash, by simp [teardown, h.nolost, h.noorphan, dirtyW], rfl,
        fun hk => absurd rfl hk, h.grid, h.seen⟩
    · exact h
  | pend =>
    simp only [body]
    have h0 : Safe { s with pc := .input } := safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
    split
    · unfold processPending
      split
      · exact h0
      · rename_i c hc
        dsimp only
        have hc1 : (if s.pendSave = true then saveSlot { s with pc := .input } c .q
            else { s with pc := .input }).cur = some c := by
          split
          · exact hc
          · exact hc
        have h1 : Safe (if s.pendSave = true then saveSlot { s with pc := .input } c .q
            else { s with pc := .input }) := by
          split
          · exact safe_same h0 rfl rfl rfl rfl rfl rfl rfl rfl
          · exact h0
        have h2 : Safe (if s.pendLoad = true then
            loadSlot (if s.pendSave = true then saveSlot { s with pc := .input } c .q
              else { s with pc := .input }) c .q
            else (if s.pendSave = true then saveSlot { s with pc := .input } c .q
              else { s with pc := .input })) := by
          split
          · unfold loadSlot
            split
            · split
              · exact safe_eqs h1 (by rw [hc1]; rfl) rfl rfl rfl rfl rfl rfl rfl
              · exact h1
            · exact h1
          · exact h1
        exact safe_same h2 rfl rfl rfl rfl rfl rfl rfl rfl
    · exact h0
  | drop p => exact safe_loadRomF p h
  | ctrlR =>
    simp only [body, resetX, ite_true]
    split
    · exact safe_loadRomF _ h
    · exact h
  | ctrlP => exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
  | ctrlS =>
    simp only [body]
    split
    · exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
    · exact h
  | ctrlL =>
    simp only [body]
    split
    · split
      · exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
      · exact h
    · exact h
  | quit => exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
  | rewindKey b => exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
  | endInput => exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
  | service peer =>
    simp only [body]
    have h0 : Safe { s with pc := .present } := safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
    split
    · rename_i a hk
      split
      · have hg : isGba { s with pc := .present } = true := h.linkGba (by rw [hk]; simp)
        rw [finishLink_gba hg]
        exact ⟨h.nocrash, h.nolost, h.noorphan, fun _ => hg, h.grid, h.seen⟩
      · exact h0
    · exact h0
  | recent i =>
    simp only [body]
    split
    · exact safe_loadRomF _ h
    · exact h
  | openFile p => exact safe_loadRomF p h
  | clear => exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
  | reset =>
    simp only [body, resetX, ite_true]
    split
    · exact safe_loadRomF _ h
    · exact h
  | exit => exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
  | quickSave =>
    simp only [body]
    split
    · exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
    · exact h
  | quickLoad =>
    simp only [body]
    split
    · exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
    · exact h
  | ssOpen =>
    simp only [body]
    split
    · exact safe_refresh h.nocrash h.nolost h.noorphan h.linkGba h.seen
    · exact h
  | ssClose =>
    exact ⟨h.nocrash, h.nolost, h.noorphan, h.linkGba, (fun hw => by simp [body] at hw), h.seen⟩
  | ssSave i =>
    simp only [body]
    split
    · split
      · exact safe_refresh h.nocrash h.nolost h.noorphan h.linkGba h.seen
      · exact h
    · exact h
  | ssDelete i =>
    simp only [body]
    split
    · rename_i c hc
      split
      · rename_i hw
        have hw' : s.ssWin = true := by simp at hw; exact hw.1
        have hsh : s.ssShows = some (stateKey c.rom) := by rw [h.grid hw', hc]; rfl
        exact safe_refresh h.nocrash h.nolost h.noorphan h.linkGba (by simp [hsh, h.seen])
      · exact h
    · exact h
  | ssLoad i =>
    simp only [body]
    split
    · rename_i c hc
      split
      · unfold loadSlot
        split
        · split
          · exact safe_eqs h (by rw [hc]; rfl) rfl rfl rfl rfl rfl rfl rfl
          · exact h
        · exact h
      · exact h
    · exact h
  | linkOpen =>
    simp only [body]
    split
    · rename_i hg
      split
      · exact ⟨h.nocrash, h.nolost, h.noorphan, fun _ => hg, h.grid, h.seen⟩
      · exact ⟨h.nocrash, h.nolost, h.noorphan, fun _ => hg, h.grid, h.seen⟩
    · exact h
  | linkHost =>
    simp only [body]
    split
    · rename_i hc
      have hg : isGba s = true := by simp at hc; exact hc.1.2
      exact ⟨h.nocrash, h.nolost, h.noorphan, fun _ => hg, h.grid, h.seen⟩
    · exact h
  | linkClose =>
    refine ⟨h.nocrash, h.nolost, h.noorphan, ?_, h.grid, h.seen⟩
    intro hk
    simp only [body] at hk ⊢
    split at hk
    · exact absurd rfl hk
    · exact h.linkGba hk
  | disconnect =>
    simp only [body]
    split
    · exact ⟨h.nocrash, by simp [teardown, h.nolost, h.noorphan, dirtyW], rfl,
        fun hk => absurd rfl hk, h.grid, h.seen⟩
    · exact h
  | endPresent => exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
  | loopTop =>
    simp only [body]
    split
    · exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl
    · exact safe_exitF h
  | rmFile p => exact safe_same h rfl rfl rfl rfl rfl rfl rfl rfl

theorem safe_stepF {s : St} (e : Ev) (h : Safe s) : Safe (stepF s e) := by
  unfold stepF stepX
  split
  · exact safe_bodyF e h
  · split
    · exact safe_bodyF e h
    · exact h

theorem safe_init (rs : List Path) : Safe (initR rs) where
  nocrash := rfl
  nolost := rfl
  noorphan := rfl
  linkGba := fun hk => absurd rfl hk
  grid := fun hw => by cases hw
  seen := rfl

/-- **The fix is safe on every path:** no crash, no dirty battery dropped on
a switch or at quit, the link never drives a core that is not the app's (and
is set up or up only with a GBA game in), the Save States grid always shows
the running game's slots, and Delete never removes a file the grid did not
show. -/
theorem fixF_safe {s : St} (h : ReachableF s) : Safe s := by
  induction h with
  | init rs => exact safe_init rs
  | step e _ ih => exact safe_stepF e ih

/-- With the fix, Reset restarts the running game (whatever became of
`recents`), and the fresh core is the one the loop runs. -/
theorem savePending_nextId (s : St) : (savePending s).nextId = s.nextId := by
  unfold savePending; split
  · split <;> rfl
  · rfl

theorem savePending_link (s : St) : (savePending s).link = s.link := by
  unfold savePending; split
  · split <;> rfl
  · rfl

theorem refresh_link (s : St) : (refresh s).link = s.link := by
  unfold refresh; split <;> rfl

theorem driven_of_link_idle {t : St} (h : t.link = .idle) : driven t = t.cur := by
  unfold driven; rw [h]; rfl

theorem resetF_restarts {s : St} (h : ReachableF s) (hpc : s.pc = .input) {c : Core}
    (hc : s.cur = some c) (hp : ∀ p, s.curPath = some p → s.present p = true) :
    ∃ c', (stepF s .ctrlR).cur = some c' ∧ c'.game = c.game ∧ c'.rom = c.rom ∧
      c'.id ≠ c.id ∧ driven (stepF s .ctrlR) = some c' := by
  have K := keep_reachableF h
  obtain ⟨hid, hg, _⟩ := K.core c hc
  obtain ⟨p, hcp, hro⟩ := K.path c hc
  have hstep : stepF s .ctrlR = loadRomX true s p := by
    simp [stepF, stepX, Ev.phase, hpc, body, resetX, hcp]
  rw [hstep]
  unfold loadRomX
  simp only [hp p hcp, hro, hg, Bool.true_eq_false, ite_false, ite_true]
  rw [refresh_cur]
  refine ⟨_, rfl, rfl, rfl, ?_, ?_⟩
  · dsimp only [swapIn]
    rw [dropCur_nextId, flushCur_nextId]
    show (savePending _).nextId ≠ c.id
    rw [savePending_nextId]
    exact Nat.ne_of_gt hid
  · have hl : (refresh (swapIn (dropCur (flushCur true (teardown (savePending
        { s with present := upd s.present c.rom true })))) p c.rom c.game)).link = .idle := by
      rw [refresh_link]
      show (dropCur _).link = .idle
      rw [dropCur_link, flushCur_link]
      rfl
    rw [driven_of_link_idle hl, refresh_cur]
    rfl

/-! ### The counterexamples, replayed against the fix -/

theorem regress_gba_switch_drops_dirty_battery :
    let s := runF init (iter idle [.drop .aGba] [] ++ iter wLate [.drop .bGba] [])
    s.lost = false ∧ s.sav .rA = some ⟨.A, 1⟩ := by decide

theorem regress_gba_quit_drops_dirty_battery :
    let s := runF init (iter idle [.drop .aGba] [] ++ iter wLate [.quit] [])
    s.pc = .done ∧ s.lost = false ∧ s.sav .rA = some ⟨.A, 1⟩ := by decide

theorem regress_gba_paused_state_load_not_persisted :
    let s := runF init (pausedLoadTrace .aGba)
    s.lost = false ∧ s.sav .rA = some ⟨.A, 0⟩ := by decide

theorem regress_empty_gb_crashes :
    let s := runF init (iter idle [.drop .aGba] [] ++ iter idle [.drop .eGb] [])
    s.crashed = false ∧ s.cur.map Core.game = some .A ∧ s.recents = [.aGba] := by decide

theorem regress_readonly_gba_crashes :
    let s := runF init (iter idle [.drop .roGba] [] ++ [wEarly])
    s.crashed = false := by decide

theorem regress_reset_while_linked_runs_outgoing_core :
    let s := runF init (linkA ++ iter idle [.ctrlR] [] ++ iter wEarly [] [])
    s.link = .idle ∧ s.orphan = none ∧ s.cur.map Core.id = some 2 ∧
    (driven s).map Core.id = some 2 ∧ s.cur.bind Core.ram = some ⟨.A, 0⟩ := by decide

theorem regress_gb_switch_keeps_link :
    let s := runF init gbWhileLinked
    s.link = .idle ∧ s.orphan = none ∧ (runF s [.rewindKey true]).rewinding = true := by decide

theorem regress_link_setup_crash_after_gb_switch :
    let s := runF init (iter idle [.drop .aGba] [.linkOpen] ++
                        [idle, .pend, .drop .cGb, .endInput, .service true])
    s.crashed = false ∧ s.link = .idle := by decide

theorem regress_save_states_grid_stale_delete :
    let s := runF init (iter idle [.drop .bGba] [.ssOpen, .ssSave .s1, .ssClose] ++
                        iter idle [.drop .aGba] [.ssOpen, .ssSave .s1] ++
                        iter idle [.drop .bGba] [])
    s.unseenDelete = false ∧ s.ssShows = some .bGba := by decide

theorem regress_reset_after_clear_is_noop :
    let s := runF init (iter idle [.drop .aGba] [.clear] ++ iter wEarly [] [])
    ((stepF (runF s [idle, .pend]) .ctrlR).cur.map Core.id) = some 2 := by decide

theorem regress_quick_save_dropped_by_switch :
    let s := runF init (iter idle [.drop .aGba] [] ++ iter idle [.ctrlS, .drop .bGba] [] ++
                        iter idle [] [])
    (s.states .aGba .q).map Snap.game = some .A ∧ s.states .bGba .q = none := by decide

/-! ### Identity keys that would not collide (not part of `stepF`)

The identity bugs are not in `load_rom`'s control flow but in the names.
Keying state files by the ROM identity the state header already checks
(`states/<file name>-<rom_identity as hex>.state`, falling back to the old
name for loading), and the zip cache by `absolutePath(zip_path)` hashed with a
stable function (crc32, not `hashes.hash`, whose value is the standard
library's to change), would give: -/

def stateKeyF (p : Path) : StKey × Option Game := (stateKey p, gameOf p)
def zipKeyF : Path → Option Path
  | .zRel | .zAbs => some .zcAbs
  | p => extract p

theorem stateKeyF_separates : stateKeyF .aGba ≠ stateKeyF .xGba := by decide
theorem stateKeyF_game {p q : Path} (h : stateKeyF p = stateKeyF q) : gameOf p = gameOf q :=
  (Prod.mk.inj h).2
theorem zipKeyF_one_identity : zipKeyF .zRel = zipKeyF .zAbs := rfl

end DesktopState.GameLifecycle
