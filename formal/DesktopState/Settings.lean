-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models src/dingbat.nim: load_rom apply_color_correction apply_master_volume apply_fifo_interp apply_speed_mode render_imgui handle_input main
-- @models src/dingbat/frontend/config_editor.nim: new_config_editor do_reset do_apply do_factory_reset render
-- @models src/dingbat/frontend/keybindings_widget.nim: wants_input key_released load_preset render reset apply
-- @models src/dingbat/frontend/controller_widget.nim: wants_input button_released render reset apply
-- @models src/dingbat/frontend/bios_selection.nim: render reset apply
-- @models src/dingbat/frontend/video_widget.nim: reset apply
-- @models src/dingbat/frontend/file_explorer.nim: new_file_explorer render close
-- @models src/dingbat/frontend/cheats_widget.nim: attach
-- @models src/dingbat/common/config.nim: new_config parse_config load_config save_config key_name_to_code key_code_to_name

/-
# Settings: the config editor, the input-capture widgets, and config.nim

Written against a2e038f82 (branch lean-desktop-state). No Nim was changed.

| Nim                                                          | lines            |
|--------------------------------------------------------------|------------------|
| `ConfigEditor.render` (open edge -> do_reset, igBegin(&open),| config_editor    |
|   the tab bar sets each widget's `visible`, Apply / Revert / |   77-155         |
|   OK / Reset to Defaults + its modal)                        |                  |
| `do_reset` / `do_apply` / `do_factory_reset`                 | 35-75            |
| `KeybindingsWidget.wants_input` / `key_released`             | keybindings 24-39|
| `ControllerWidget.wants_input` / `button_released`           | controller 28-46 |
| `BiosSelection.render/reset/apply`                           | bios 30-82       |
| `VideoWidget.reset/apply`                                    | video 93-107     |
| `FileExplorer.render` (open flag, selected_idx, Open/Cancel) | file_explorer    |
|                                                              |   45-140         |
| `parse_config` / `load_config` / `save_config`               | config 315-491   |
| `load_rom`                                                   | dingbat 694-767  |
| `apply_*` procs                                              | dingbat 512-618  |
| `render_imgui` (skip condition, File / Emulation /           | dingbat          |
|   Audio-Video menus, fe.render("ROM"), ce.render)            |   1265-1545      |
| `handle_input` KeyDown/KeyUp routing, pad buttons, DropFile  | dingbat 1628-1776|
| `main`: CLI overrides into cfg, live_sync, the loop          | dingbat 2107-2609|

## The loop, as the model sees it

`main`'s `while app.running` loop is a program counter `pc`:

* `emu` -- phases 1-2 (emulate, `process_pending_state`). Nothing there
  writes this machine's state; the emulate phase only reads `cfg.rewind` and
  `cfg.speed_mode`. One event, `frame`, moves on to `input`.
* `input` -- phase 3, `handle_input`: any number of SDL events (`key`,
  `padBtn`, `drop`), then `endInput`. Phase 4 (`update_rumble`, link
  services) touches nothing here and is folded into `endInput`.
* `present` -- phase 5 is either `renderTop` (render_imgui runs: `igNewFrame`
  computes `io.WantCaptureKeyboard`, and `ConfigEditor.render`'s top runs:
  the open edge, `prev_open`, and the tab bar's `visible` flags), after which
  the `ui` pc takes ImGui clicks until `endFrame`; or `noRender`: no present
  this iteration (the present interval has not elapsed) or render_imgui's
  early return. Either way no widget code runs. `noRender` is always allowed:
  the loop spins at ~1 ms and presents only at the display rate.
* Clicks exist only at `pc = ui`, keys only at `pc = input`. So a flag set by
  a click is first read by `handle_input` in the NEXT iteration, and
  `WantCaptureKeyboard` is the value computed at the last NewFrame, which is
  before that frame's clicks.

## Abstractions, and why they do not affect the stated properties

* **Inputs** are `0..9` (`Input`: UP DOWN LEFT RIGHT A B SELECT START L R).
* **Keys** are classes, by how `handle_input` and `config.nim` treat them:
  `plain n` a key that has a KEYCODE_TABLE name and no hotkey (`plain 0..9`
  are the default keys: arrows, z, x, backspace, return, a, s); `unnamed` a
  key with no KEYCODE_TABLE name (every keypad key, and non-US letters such
  as e-acute or u-umlaut -- getKeyName still shows a name in the widget);
  `backquote`, `f9`, `f12` (checked before the bindings, 1668-1676); `tab`,
  `digit` (checked after the bindings, 1681/1691 on a GBA, 1698/1705 on a GB); `modKey`, the MOD_KEY
  modifier itself (LCtrl/RCtrl off macOS, LGui/RGui on macOS, 35-43). SDL2
  puts a modifier's own bit in `keysym.mod` on its KeyDown and clears it on
  its KeyUp; `modHeld` tracks that.
* **Bindings** are functions (`Table[cint, Input]`). `key_released` deletes
  the FIRST key bound to the selection; the model clears every key bound to
  it. They differ only on a hand-edited file that binds two keys to one
  input, and no property here depends on it.
* **Controller** buttons are `Nat`, named iff `< 15` (config 149-164). The
  widget refuses unnamed ones itself (controller 34), so they are not a
  finding; the pad is modelled only for the capture routing.
* **Config fields**: only the ones a property reads. Filter, LCD response,
  preserve-aspect and the SGB border are read by `render_game` at every
  present (1126, 1047 and 1152, 545, 1161), so they are live by construction and not
  modelled. Pitch correction, the low-pass and the MP2K HLE follow exactly the
  `fifo_interp` pattern (an apply proc that reads `speed_mode`, called from
  the menu, `load_rom` and `live_sync`), so `interp` stands for all four.
  `explorer_dir` is written only by the file explorer (and saved), never by a
  widget snapshot, so it is left out. Rumble (`gb_rumble`) is read live by
  `update_rumble` (1614).
* **The file**: `Disk.ok c` is "the file `save_config(c)` wrote";
  `loadDisk` is `parse_config` of it. The one lossy step is proved by a
  headless run (see `persist`). `Disk.bad` is a file `loadToJson` rejects
  (hand-edited, or cut short: `writeFile` truncates then writes).
* **Files** the explorer and drop can load: a GB ROM, a GBA ROM, and the
  GBA BIOS image `gba_bios.bin` (hidden by the ROM dialog's extension
  filter, not accepted by a drop).
* **Cores** keep the settings `load_rom` passes them and the fields the
  `apply_*` procs write. `gen` is the core's identity.
* **Not modelled**: the save-state slots, rewind history, link, debug
  windows (other machines); hotkey effects beyond "the key went to a hotkey"
  (`Route`); ImGui's ActiveId (a mouse-held widget also sets
  WantCaptureKeyboard -- it only adds `imgui` routes); a pad being
  unplugged (the Controller tab then clears its own selection, 72).

## Results

Refuted for the code as it is (`real`), each a concrete trace from `init`:
* (c) `bug_close_midcapture_eats_keys`, `_eats_quit`, `_eats_pad`,
  `bug_collapse_midcapture_eats_keys`: a capture outlives its window.
* (c) `bug_bound_f12_never_reaches_game`, `bug_bound_modifier_never_presses`.
* (b) `bug_numpad_binding_lost_on_restart`, `bug_cli_flag_persists`,
  `bug_bad_file_overwritten`.
* (a) `bug_real_bios_without_file`, `bug_run_bios_without_file`.
* `bug_rom_dialog_opens_hidden_selection`.
* (d) `bug_reset_defaults_keeps_interp_and_speed`.

Proved for the code as it is: `liveOK_real` (every live setting agrees with
cfg in every reachable state, Reset to Defaults included),
`cheatsOK_reachable`, `apply_menu_commute` / `apply_keeps_menu_fields` (the
Settings window and the menus cannot overwrite each other), `persist_idem`.

The fixes are the `Fix` switches; `fixed` turns them on. Proved for it:
`invF_reachable` and its corollaries `fixed_roundtrip`,
`fixed_bound_key_reaches_game`, `fixed_bios`, `fixed_never_loads_bios_as_rom`,
plus `fixed_closed_never_captures`, `fixed_reset_is_defaults`,
`liveOK_fixed`, and a `regress_*` replay of the traces.
`capture_fix_needs_both_halves` and
`bug_naive_reset_fix_leaves_core_in_speed_mode` show why each fix has the
parts it has.
-/
namespace DesktopState.Settings

/-! ## Keys, inputs, files -/

/-- `Input` (common/input.nim): UP DOWN LEFT RIGHT A B SELECT START L R = 0..9. -/
abbrev Inp := Nat

/-- key_released / button_released 35-39: the selection moves to the next
input, and ends after R. -/
def nextInp (i : Inp) : Option Inp := if i + 1 < 10 then some (i + 1) else none

inductive Key where
  | plain (n : Nat)   -- a KEYCODE_TABLE-named key no hotkey uses
  | unnamed           -- no KEYCODE_TABLE name: keypad keys, non-US letters
  | backquote | f9 | f12
  | tab | digit
  | modKey            -- LCtrl/RCtrl (Windows, Linux) or LGui/RGui (macOS)
  deriving DecidableEq, Repr

/-- `key_code_to_name(k) != ""` (config 130). -/
def Key.named : Key → Bool
  | .unnamed => false
  | _ => true

/-- Keys `handle_input` consumes before it looks at the bindings (1644-1681). -/
def Key.reserved : Key → Bool
  | .backquote | .f9 | .f12 | .modKey => true
  | _ => false

/-- The keys the finite checks below look at. -/
def allKeys : List Key :=
  (List.range 10).map Key.plain ++ [.unnamed, .backquote, .f9, .f12, .tab, .digit, .modKey]

/-- default_keybindings (config 212-223). -/
def defaultKb : Key → Option Inp
  | .plain n => if n < 10 then some n else none
  | _ => none

/-- default_controller_bindings (config 168-181, 196-199). -/
def defaultPad : Nat → Option Inp
  | 0 => some 4 | 1 => some 5 | 2 => some 4 | 3 => some 5 | 4 => some 6
  | 6 => some 7 | 9 => some 8 | 10 => some 9
  | 11 => some 0 | 12 => some 1 | 13 => some 2 | 14 => some 3
  | _ => none

inductive FileE where
  | gbRom | gbaRom
  | biosBin           -- gba_bios.bin
  deriving DecidableEq, Repr

inductive Kind where
  | gb | gba
  | junk              -- a file that is not a ROM, loaded as a GBA cart
  deriving DecidableEq, Repr

def FileE.kind : FileE → Kind
  | .gbRom => .gb
  | .gbaRom => .gba
  | .biosBin => .junk   -- load_rom 722: any extension but .gb/.gbc is a GBA cart

/-! ## Config and the file -/

structure Cfg where
  kb        : Key → Option Inp   -- cfg.keybindings
  pad       : Nat → Option Inp   -- cfg.controller_bindings
  useHle    : Bool               -- cfg.use_hle
  afterBios : Bool               -- cfg.hle_after_bios
  runBios   : Bool               -- cfg.run_bios
  biosFile  : Bool               -- cfg.bios_path names an existing file
  gbFifo    : Bool               -- cfg.gb_fifo
  sgb       : Bool               -- cfg.sgb_enable
  volume    : Nat                -- cfg.volume
  color     : Bool               -- cfg.color_correction
  interp    : Bool               -- cfg.fifo_interp (stands for the audio niceties)
  speed     : Bool               -- cfg.speed_mode
  rewind    : Bool               -- cfg.rewind
  recent    : Option FileE       -- cfg.recents[0]

/-- new_config (config 286-313). -/
def defaults : Cfg :=
  { kb := defaultKb, pad := defaultPad, useHle := true, afterBios := false,
    runBios := false, biosFile := false, gbFifo := true, sgb := false,
    volume := 100, color := true, interp := true, speed := false, rewind := true,
    recent := none }

/-- `parse_config(loadToJson(save_config(c)))`. save_config writes each binding
as `key_code_to_name(k): input` (452-453); an unnamed key is written as
`  : a`, which YAML reads as the key "", which `key_name_to_code` maps to -1,
which parse_config drops (399-402). Run headless against the real
config.nim (a scratch program calling save_config then load_config under a
scratch HOME): KP_1 and e-acute bound to A and B came back as neither, the
other eight bindings and every other field intact, and the file still
parsed. Controller buttons: save writes only named ones (456-458), and the
widget binds only named ones. Everything else round-trips (bools, the
clamped volume, the recents list through yaml_str's quoting). -/
def persist (c : Cfg) : Cfg :=
  { c with kb := fun k => if k.named then c.kb k else none,
           pad := fun b => if b < 15 then c.pad b else none }

inductive Disk where
  | missing           -- no ~/.config/dingbat/dingbat.yml
  | ok (c : Cfg)      -- the file save_config(c) wrote
  | bad               -- a file loadToJson rejects

/-- load_config (config 415-425): any exception -> new_config(), silently. -/
def loadDisk : Disk → Cfg
  | .missing => defaults
  | .ok c => persist c
  | .bad => defaults

/-- The command-line overrides `main` writes INTO cfg (2164-2175). -/
structure Cli where
  hle       : Bool := false          -- --hle
  afterBios : Bool := false          -- --hle-after-bios
  runBios   : Bool := false          -- --run-bios
  biosArg   : Option Bool := none    -- `dingbat BIOS ROM`: some (the file exists)

def cliApply (a : Cli) (c : Cfg) : Cfg :=
  let c := if a.hle then { c with useHle := true, runBios := false } else c        -- 2164-2166
  let c := if a.afterBios then { c with afterBios := true, runBios := true } else c -- 2167-2169
  let c := match a.biosArg with                                                     -- 2170-2174
    | some ex => if !a.hle && !a.afterBios then { c with biosFile := ex, useHle := false }
                 else { c with biosFile := ex }
    | none => c
  if a.runBios then { c with runBios := true } else c                               -- 2175

/-! ## The editor, the explorer, the core -/

inductive Tab where
  | kb | video | pad | bios
  deriving DecidableEq, Repr

structure Ed where
  isOpen     : Bool             -- ConfigEditor.open
  prevOpen   : Bool             -- ConfigEditor.prev_open
  collapsed  : Bool             -- ImGui's collapsed state of "Settings" (igBegin returns false)
  tab        : Tab              -- ImGui's selected tab of "SettingsTabBar"
  kbVis      : Bool             -- keybindings.visible
  kbSel      : Option Inp       -- keybindings.selection
  kbEdit     : Key → Option Inp -- keybindings.editing
  padVis     : Bool             -- controller.visible
  padSel     : Option Inp       -- controller.selection
  padEdit    : Nat → Option Inp -- controller.editing
  bMode      : Nat              -- bios.bios_mode (0 HLE, 1 real BIOS, 2 real init + HLE SWIs)
  bRun       : Bool             -- bios.run_bios
  bFile      : Bool             -- bios.bios_buf names an existing file
  vFifo      : Bool             -- video.gb_renderer == 0
  vSgb       : Bool             -- video.sgb_enable
  resetPopup : Bool             -- the "Reset settings?" modal is open

/-- new_config_editor (config_editor 23-32): widgets are created empty; the
first open's do_reset fills them. The first tab is ImGui's default. -/
def initEd : Ed :=
  { isOpen := false, prevOpen := false, collapsed := false, tab := .kb,
    kbVis := false, kbSel := none, kbEdit := fun _ => none,
    padVis := false, padSel := none, padEdit := fun _ => none,
    bMode := 0, bRun := false, bFile := false, vFifo := false, vSgb := false,
    resetPopup := false }

inductive Dlg where
  | none | rom | bios
  deriving DecidableEq, Repr

structure Fe where
  dlg : Dlg             -- fe.open, and which popup (the "ROM" or "GBA BIOS" modal) it is
  sel : Option FileE    -- entries[selected_idx] when that entry is a file

structure Core where
  kind      : Kind
  gen       : Nat       -- identity of this load
  fifo      : Bool      -- GB: the FIFO renderer (new_gb's `fifo` argument)
  sgb       : Bool      -- gb_emu.sgb_requested
  hle       : Bool      -- gba.use_hle
  afterBios : Bool      -- gba.hle_after_bios
  runBios   : Bool      -- gba.run_bios
  biosFile  : Bool      -- a BIOS image is mapped (not bus.stub_bios)
  volume    : Nat       -- apu master volume
  interp    : Bool      -- GBA apu fifo_interp (effective)
  frameskip : Bool      -- ppu.frameskip = 1 (+ GBA underclock)

inductive Pc where
  | emu | input | present | ui
  deriving DecidableEq, Repr

/-- Where one KeyDown/KeyUp goes in handle_input. -/
inductive Route where
  | imgui          -- 1640: io.WantCaptureKeyboard -> continue
  | capture        -- 1642: the Keybindings widget takes it
  | modHotkey      -- 1644: Cmd/Ctrl + R P N S L F Q
  | mark           -- 1668: F9
  | shot           -- 1671: F12
  | rewind         -- 1674: backquote
  | game (i : Inp) -- 1679 / 1696: the core's handle_input
  | ff             -- 1681: Tab
  | chan           -- 1691: 1..6
  | none
  deriving DecidableEq, Repr

structure S where
  pc          : Pc
  cfg         : Cfg
  disk        : Disk
  ed          : Ed
  fe          : Fe
  core        : Option Core      -- app.gba_emu / app.gb_emu
  gen         : Nat              -- loads so far
  cheatsGen   : Option Nat       -- app.cheats.engine: which core's CheatEngine
  shaderColor : Bool             -- the `color_correct` GL uniform
  wck         : Bool             -- io.WantCaptureKeyboard, as of the last igNewFrame
  modHeld     : Bool             -- MOD_KEY bit of SDL's modstate
  lastRoute   : Route            -- where the last key event went

/-! ## The fixes, as switches (all off = the code at a2e038f82) -/

structure Fix where
  /-- wants_input also requires the editor to be open. -/
  openGate : Bool := false
  /-- render clears `visible` every frame before the tab bar sets it. -/
  visGate : Bool := false
  /-- key_released refuses keys it cannot save or that never reach the game. -/
  captureFilter : Bool := false
  /-- do_factory_reset also resets fifo_interp and speed_mode, and live_sync
  calls apply_speed_mode. -/
  resetAll : Bool := false
  /-- resets them WITHOUT apply_speed_mode (to show that half is needed). -/
  resetNaive : Bool := false
  /-- load_rom maps "no BIOS image" to HLE and no intro. -/
  biosGate : Bool := false
  /-- fe.render clears the selection when a dialog opens. -/
  feFresh : Bool := false

def real : Fix := {}
def fixed : Fix :=
  { openGate := true, visGate := true, captureFilter := true, resetAll := true, biosGate := true,
    feFresh := true }
def naive : Fix := { resetNaive := true }

/-! ## Helpers: the Nim procs -/

/-- save_config (config 445-491). -/
def save (s : S) : S := { s with disk := .ok s.cfg }

/-- apply_master_volume (570-574). -/
def applyVolume (s : S) : S :=
  { s with core := s.core.map fun c => { c with volume := s.cfg.volume } }

/-- apply_fifo_interp (596-600): GBA core only. -/
def applyInterp (s : S) : S :=
  { s with core := s.core.map fun c =>
      if c.kind = .gb then c else { c with interp := s.cfg.interp && !s.cfg.speed } }

/-- apply_speed_mode (602-618): frameskip on either core, then the audio niceties. -/
def applySpeed (s : S) : S :=
  applyInterp { s with core := s.core.map fun c => { c with frameskip := s.cfg.speed } }

/-- apply_color_correction (512-515). -/
def applyColor (s : S) : S := { s with shaderColor := s.cfg.color }

/-- load_rom (694-767), after its early returns. The cheats widget is
re-attached to the new core (732); recents[0] := the file and the whole cfg
is saved (755-761). -/
def loadRom (fx : Fix) (s : S) (f : FileE) : S :=
  let c := s.cfg
  let hle := if fx.biosGate then c.useHle || !c.biosFile else c.useHle
  let rb  := if fx.biosGate then c.runBios && c.biosFile else c.runBios
  let core : Core :=
    { kind := f.kind, gen := s.gen + 1,
      fifo := c.gbFifo && !c.speed,                     -- 707-709
      sgb := c.sgb,                                     -- 712
      hle := hle, afterBios := c.afterBios, runBios := rb,
      biosFile := c.biosFile,                           -- 723, bus.nim 370
      volume := c.volume,                               -- 736 apply_master_volume
      interp := c.interp && !c.speed,                   -- 739 apply_fifo_interp
      frameskip := c.speed }                            -- 741 apply_speed_mode
  save { s with core := some core, gen := s.gen + 1, cheatsGen := some (s.gen + 1),
                cfg := { c with recent := some f } }

/-- The widgets' reset() procs, i.e. do_reset (config_editor 35-39). -/
def edLoad (c : Cfg) (e : Ed) : Ed :=
  { e with kbSel := none, kbEdit := c.kb,                          -- keybindings 81-85
           padSel := none, padEdit := c.pad,                       -- controller 95-100
           bMode := if c.afterBios then 2 else if c.useHle then 0 else 1,  -- bios 66-76
           bRun := c.runBios, bFile := c.biosFile,
           vFifo := c.gbFifo, vSgb := c.sgb }                      -- video 93-99

/-- The widgets' apply() procs (config_editor 41-45), before save_config. -/
def edStore (e : Ed) (c : Cfg) : Cfg :=
  { c with kb := e.kbEdit, pad := e.padEdit,                       -- keybindings 87-90, controller 102-107
           biosFile := e.bFile, runBios := e.bRun,                 -- bios 78-82
           useHle := e.bMode == 0, afterBios := e.bMode == 2,
           gbFifo := e.vFifo, sgb := e.vSgb }                      -- video 101-107

/-- do_apply (config_editor 41-46). -/
def doApply (s : S) : S :=
  save { s with cfg := edStore s.ed s.cfg, ed := { s.ed with kbSel := none, padSel := none } }

/-- do_factory_reset's cfg writes (config_editor 52-71). fifo_interp and
speed_mode are not among them. -/
def factoryCfg (fx : Fix) (c : Cfg) : Cfg :=
  let r := fx.resetAll || fx.resetNaive
  { c with kb := defaults.kb, pad := defaults.pad, runBios := defaults.runBios,
           useHle := defaults.useHle, afterBios := defaults.afterBios,
           gbFifo := defaults.gbFifo, volume := defaults.volume,
           color := defaults.color, sgb := defaults.sgb, rewind := defaults.rewind,
           interp := if r then defaults.interp else c.interp,
           speed := if r then defaults.speed else c.speed }

/-- do_factory_reset (51-75): cfg writes, do_reset, do_apply (saves), then
live_sync (main 2235-2241: color, volume, pitch, low-pass, interp, mp2k). -/
def factoryReset (fx : Fix) (s : S) : S :=
  let s1 := { s with cfg := factoryCfg fx s.cfg }
  let s2 := doApply { s1 with ed := edLoad s1.cfg s1.ed }
  let s3 := applyInterp (applyVolume (applyColor s2))
  let s4 := if fx.resetAll then applySpeed s3 else s3
  { s4 with ed := { s4.ed with resetPopup := false } }

/-- The top of ConfigEditor.render (77-99): the open edge reloads the
widgets, `prev_open` follows `open`, and while the window is open and
expanded the tab bar sets each widget's `visible` (99, 106, 113, 120).
Closed (82) or collapsed (igBegin false, 92) leaves `visible` as it was. -/
def ceTop (fx : Fix) (c : Cfg) (e : Ed) : Ed :=
  let e1 := if e.isOpen && !e.prevOpen then edLoad c e else e
  let live := e1.isOpen && !e1.collapsed
  { e1 with prevOpen := e1.isOpen,
            kbVis := if live then e1.tab == .kb else if fx.visGate then false else e1.kbVis,
            padVis := if live then e1.tab == .pad else if fx.visGate then false else e1.padVis }

/-- KeybindingsWidget.wants_input (24-25). -/
def wantsKb (fx : Fix) (s : S) : Bool :=
  (!fx.openGate || s.ed.isOpen) && s.ed.kbVis && s.ed.kbSel.isSome

/-- ControllerWidget.wants_input (28-29). -/
def wantsPad (fx : Fix) (s : S) : Bool :=
  (!fx.openGate || s.ed.isOpen) && s.ed.padVis && s.ed.padSel.isSome

/-- handle_input's KeyDown/KeyUp routing (1636-1700); `mods` is the event's
MOD_KEY bit. -/
def keyRoute (fx : Fix) (s : S) (k : Key) (mods : Bool) : Route :=
  if s.wck then .imgui
  else if wantsKb fx s then .capture
  else if mods then .modHotkey
  else match k with
    | .f9 => .mark
    | .f12 => .shot
    | .backquote => .rewind
    | _ =>
      match s.core with
      | none => .none                                   -- ekNone: no branch
      | some _ =>
        match s.cfg.kb k with
        | some i => .game i
        | none =>
          match k with
          | .tab => .ff
          | .digit => .chan
          | _ => .none

/-- key_released (keybindings 27-39), with the proposed filter. -/
def captureKey (fx : Fix) (e : Ed) (k : Key) : Ed :=
  match e.kbSel with
  | none => e
  | some sel =>
    if fx.captureFilter && (!k.named || k.reserved) then e
    else { e with kbEdit := fun k' => if k' = k then some sel
                                      else if e.kbEdit k' = some sel then none else e.kbEdit k',
                  kbSel := nextInp sel }

/-- button_released (controller 31-46). -/
def capturePad (e : Ed) (b : Nat) : Ed :=
  if b ≥ 15 then e else
  match e.padSel with
  | none => e
  | some sel =>
    { e with padEdit := fun b' => if b' = b then some sel
                                  else if e.padEdit b' = some sel then none else e.padEdit b',
             padSel := nextInp sel }

/-- One KeyDown (`down`) / KeyUp. -/
def onKey (fx : Fix) (s : S) (k : Key) (down : Bool) : S :=
  let mods := if k = .modKey then down else s.modHeld
  let r := keyRoute fx s k mods
  { s with modHeld := mods, lastRoute := r,
           ed := if r = .capture && !down then captureKey fx s.ed k else s.ed }

/-- ControllerButtonDown/Up (1729-1737): no WantCaptureKeyboard gate. -/
def onPad (fx : Fix) (s : S) (b : Nat) (down : Bool) : S :=
  { s with ed := if wantsPad fx s && !down then capturePad s.ed b else s.ed }

/-- The app as `main` leaves it before the loop (2160-2256), from whatever
file is on disk: load_config, the CLI overrides written into cfg,
new_file_explorer (selected_idx 0 is a directory), new_config_editor,
apply_color_correction (2287). A quit (the loop's end) or a crash, then a
relaunch, is this with the old disk. -/
def launch (d : Disk) (a : Cli) (gen : Nat) : S :=
  let c := cliApply a (loadDisk d)
  { pc := .emu, cfg := c, disk := d, ed := initEd, fe := { dlg := .none, sel := none },
    core := none, gen := gen, cheatsGen := none, shaderColor := c.color, wck := false,
    modHeld := false, lastRoute := .none }

def init : S := launch .missing {} 0

/-! ## Events and the step -/

inductive Ev where
  -- the loop
  | frame | endInput | renderTop | noRender | endFrame
  -- SDL, in handle_input
  | key (k : Key) (down : Bool)
  | padBtn (b : Nat) (down : Bool)
  | drop (f : FileE)
  -- ImGui: menus (render_imgui 1290-1470)
  | menuSettings
  | menuSpeed | menuInterp | menuColor | menuRewind
  | menuVolume (v : Nat)
  | menuOpenRom | menuReset | menuClearRecent
  -- ImGui: the Settings window
  | winClose | winCollapse (b : Bool) | selectTab (t : Tab)
  | bindKey (i : Inp) | bindPad (i : Inp) | kbPresetDefault
  | setBiosMode (m : Nat) | setRunBios (b : Bool) | biosBrowse
  | setFifo (b : Bool) | setSgb (b : Bool)
  | apply | revert | ok | resetDefaults | resetConfirm | resetCancel
  -- ImGui: the file explorer modal
  | feSelect (f : FileE) | feNavigate | feOpen | feCancel
  -- the environment
  | restart (a : Cli)      -- quit or crash, then launch again (with these flags)
  | corruptFile            -- the file stops parsing (a hand edit, a cut-short write)

/-- No modal popup is up, so the menu bar and the Settings window take clicks. -/
def uiFree (s : S) : Bool := s.pc == .ui && !s.ed.resetPopup && s.fe.dlg == .none
/-- The Settings window's title bar takes clicks. -/
def inWin (s : S) : Bool := uiFree s && s.ed.isOpen
/-- A tab's contents take clicks. -/
def inTab (s : S) (t : Tab) : Bool :=
  inWin s && !s.ed.collapsed && s.ed.tab == t && (t != .kb || s.ed.kbVis) &&
    (t != .pad || s.ed.padVis)

def gbaCore (s : S) : Bool :=
  match s.core with
  | some c => c.kind != .gb
  | none => false

/-- The ROM dialog lists directories and .gba/.gb/.gbc/.zip (1473); the BIOS
dialog lists every file (bios 59). -/
def shown : Dlg → FileE → Bool
  | .rom, .biosBin => false
  | .none, _ => false
  | _, _ => true

/-- `none` = the event cannot happen in this state. -/
def stepO (fx : Fix) (s : S) : Ev → Option S
  | .frame => if s.pc == .emu then some { s with pc := .input } else none
  | .endInput => if s.pc == .input then some { s with pc := .present } else none
  | .renderTop =>
    -- igNewFrame computes WantCaptureKeyboard from the popups open now
    -- (imgui.cpp 5515-5521: ActiveId or a modal), then ce.render's top.
    if s.pc == .present then
      some { s with pc := .ui, wck := s.ed.resetPopup || s.fe.dlg != .none,
                    ed := ceTop fx s.cfg s.ed }
    else none
  | .noRender => if s.pc == .present then some { s with pc := .emu } else none
  | .endFrame => if s.pc == .ui then some { s with pc := .emu } else none
  | .key k d => if s.pc == .input then some (onKey fx s k d) else none
  | .padBtn b d => if s.pc == .input then some (onPad fx s b d) else none
  | .drop f =>
    -- DropFile (1761-1768): ROM extensions and .zip only
    if s.pc == .input && f != .biosBin then some (loadRom fx s f) else none
  | .menuSettings =>
    -- 1319: open = true; ce.render runs later in the same frame (1478)
    if uiFree s then some { s with ed := ceTop fx s.cfg { s.ed with isOpen := true } } else none
  | .menuSpeed =>
    -- 1342-1347: flip, (rewind.clear), apply_speed_mode, save
    if uiFree s then
      some (save (applySpeed { s with cfg := { s.cfg with speed := !s.cfg.speed } }))
    else none
  | .menuInterp =>
    -- 1404-1409: enabled for a GBA core outside speed mode
    if uiFree s && gbaCore s && !s.cfg.speed then
      some (save (applyInterp { s with cfg := { s.cfg with interp := !s.cfg.interp } }))
    else none
  | .menuColor =>
    -- 1422-1425
    if uiFree s then
      some (save (applyColor { s with cfg := { s.cfg with color := !s.cfg.color } }))
    else none
  | .menuRewind =>
    -- 1335-1339: enabled outside speed mode
    if uiFree s && !s.cfg.speed then
      some (save { s with cfg := { s.cfg with rewind := !s.cfg.rewind } })
    else none
  | .menuVolume v =>
    -- 1383-1390: the slider applies live, saves when released
    if uiFree s && v ≤ 100 then
      some (save (applyVolume { s with cfg := { s.cfg with volume := v } }))
    else none
  | .menuOpenRom =>
    -- 1296 open_rom, then fe.render("ROM", true, ...) (1473): fe.open, igOpenPopup
    if uiFree s then
      some { s with fe := { dlg := .rom, sel := if fx.feFresh then none else s.fe.sel } }
    else none
  | .menuReset =>
    -- 1370-1371: load_rom(recents[0]) when there is one
    if uiFree s then
      some (match s.cfg.recent with
            | some f => loadRom fx s f
            | none => s)
    else none
  | .menuClearRecent =>
    if uiFree s then some (save { s with cfg := { s.cfg with recent := none } }) else none
  | .winClose =>
    -- igBegin's X writes ed.open = false (92); nothing else runs
    if inWin s then some { s with ed := { s.ed with isOpen := false } } else none
  | .winCollapse b =>
    if inWin s then some { s with ed := { s.ed with collapsed := b } } else none
  | .selectTab t =>
    if inWin s && !s.ed.collapsed then some { s with ed := { s.ed with tab := t } } else none
  | .bindKey i =>
    -- keybindings 76-77
    if inTab s .kb && i < 10 then some { s with ed := { s.ed with kbSel := some i } } else none
  | .bindPad i =>
    -- controller 88-89
    if inTab s .pad && i < 10 then some { s with ed := { s.ed with padSel := some i } } else none
  | .kbPresetDefault =>
    -- keybindings 43-47, 52-53
    if inTab s .kb then some { s with ed := { s.ed with kbEdit := defaultKb, kbSel := none } }
    else none
  | .setBiosMode m =>
    if inTab s .bios && m < 3 then some { s with ed := { s.ed with bMode := m } } else none
  | .setRunBios b =>
    if inTab s .bios then some { s with ed := { s.ed with bRun := b } } else none
  | .biosBrowse =>
    -- bios 45, 59: fe.render("GBA BIOS", browse, ...)
    if inTab s .bios then
      some { s with fe := { dlg := .bios, sel := if fx.feFresh then none else s.fe.sel } }
    else none
  | .setFifo b => if inTab s .video then some { s with ed := { s.ed with vFifo := b } } else none
  | .setSgb b => if inTab s .video then some { s with ed := { s.ed with vSgb := b } } else none
  | .apply => if inWin s && !s.ed.collapsed then some (doApply s) else none
  | .revert =>
    if inWin s && !s.ed.collapsed then some { s with ed := edLoad s.cfg s.ed } else none
  | .ok =>
    if inWin s && !s.ed.collapsed then
      some (let s' := doApply s; { s' with ed := { s'.ed with isOpen := false } })
    else none
  | .resetDefaults =>
    if inWin s && !s.ed.collapsed then some { s with ed := { s.ed with resetPopup := true } }
    else none
  | .resetConfirm =>
    if s.pc == .ui && s.ed.resetPopup then some (factoryReset fx s) else none
  | .resetCancel =>
    if s.pc == .ui && s.ed.resetPopup then some { s with ed := { s.ed with resetPopup := false } }
    else none
  | .feSelect f =>
    -- file_explorer 104-108
    if s.pc == .ui && shown s.fe.dlg f then some { s with fe := { s.fe with sel := some f } }
    else none
  | .feNavigate =>
    -- 113-125: selected_idx := 0 (".." or a directory sorts first), explorer_dir saved
    if s.pc == .ui && s.fe.dlg != .none then
      some (save { s with fe := { s.fe with sel := none } })
    else none
  | .feOpen =>
    -- 128-132: entries[selected_idx] if it is a file, NOT re-checked against the filter
    if s.pc == .ui && s.fe.dlg != .none then
      some (match s.fe.sel with
        | none => s
        | some f =>
          let s' := { s with fe := { s.fe with dlg := .none } }
          match s.fe.dlg with
          | .rom => loadRom fx s' f                                   -- 1473-1474
          | _ => { s' with ed := { s'.ed with bFile := true } })      -- bios 59-64
    else none
  | .feCancel =>
    if s.pc == .ui && s.fe.dlg != .none then some { s with fe := { s.fe with dlg := .none } }
    else none
  | .restart a => some (launch s.disk a s.gen)
  | .corruptFile => some { s with disk := .bad }

def step (fx : Fix) (s : S) (e : Ev) : S := (stepO fx s e).getD s

inductive Reachable (fx : Fix) : S → Prop
  | init : Reachable fx init
  | step {s} (e : Ev) : Reachable fx s → Reachable fx (step fx s e)

/-- A trace, failing if any event is not possible where it lands. -/
def run (fx : Fix) (s : S) : List Ev → Option S
  | [] => some s
  | e :: es => match stepO fx s e with
    | some s' => run fx s' es
    | none => none

theorem run_reachable (fx : Fix) : ∀ (es : List Ev) (s t : S),
    Reachable fx s → run fx s es = some t → Reachable fx t := by
  intro es
  induction es with
  | nil => intro s t hs h; simp [run] at h; subst h; exact hs
  | cons e es ih =>
    intro s t hs h
    simp only [run] at h
    split at h
    · rename_i s' he
      have : step fx s e = s' := by simp [step, he]
      exact ih s' t (this ▸ Reachable.step e hs) h
    · cases h

/-! ## Trace building blocks -/

/-- One loop iteration with no keys and a drawn frame whose clicks are `cs`. -/
def iter (cs : List Ev) : List Ev := [.frame, .endInput, .renderTop] ++ cs ++ [.endFrame]
/-- One loop iteration whose input phase sees `ks`, with no ImGui frame. -/
def keys (ks : List Ev) : List Ev := [.frame] ++ ks ++ [.endInput, .noRender]
def tap (k : Key) : List Ev := [.key k true, .key k false]

/-- Launch, drop a GBA ROM, open Settings (Keybindings is the first tab). -/
def openSettingsGba : List Ev :=
  keys [.drop .gbaRom] ++ iter [.menuSettings]

/-! ## (c) A capture in progress outlives the window -/

/-- Close the Settings window with its X while a key is being captured: the
keyboard stays captured. The next key the player presses -- here the default
A key, and then Cmd/Ctrl+Q -- goes to the hidden widget, not to the game or
the hotkeys. -/
def trCloseMidCapture : List Ev :=
  openSettingsGba ++ iter [.bindKey 0, .winClose] ++ keys (tap (.plain 4))

theorem bug_close_midcapture_eats_keys :
    ((run real init trCloseMidCapture).map fun s =>
      (s.ed.isOpen, s.lastRoute, s.ed.kbSel)) = some (false, .capture, some 1) := by
  decide

/-- The same player then tries Cmd/Ctrl+Q to quit: eaten too (the capture
test comes before the modifier test, 1642-1644). -/
theorem bug_close_midcapture_eats_quit :
    ((run real init (trCloseMidCapture ++ keys [.key .modKey true, .key (.plain 20) true,
        .key (.plain 20) false])).map fun s => s.lastRoute) = some .capture := by
  decide

set_option maxRecDepth 8000 in
/-- It ends by itself only once the selection has walked past R: up to ten key
releases (here, from UP, ten taps). The widget's edits are thrown away by the
next open's do_reset, so cfg never changes. -/
theorem obs_capture_walks_off_after_ten :
    ((run real init (openSettingsGba ++ iter [.bindKey 0, .winClose] ++
        keys ((List.range 10).flatMap fun _ => tap (.plain 4)) ++ keys (tap (.plain 4)))).map
      fun s => (s.ed.kbSel, s.lastRoute, s.cfg.kb (.plain 4))) = some (none, .game 4, some 4) := by
  decide

/-- Collapsing the window (double-click its title bar) does the same while it
stays open: igBegin returns false, the tab bar does not run, `visible` stays. -/
theorem bug_collapse_midcapture_eats_keys :
    ((run real init (openSettingsGba ++ iter [.bindKey 0, .winCollapse true] ++
        iter [] ++ keys (tap (.plain 4)))).map fun s => (s.ed.collapsed, s.lastRoute)) =
      some (true, .capture) := by
  decide

/-- The controller capture has the same hole: pad presses go nowhere. -/
theorem bug_close_midcapture_eats_pad :
    ((run real init (openSettingsGba ++ iter [.selectTab .pad] ++ iter [.bindPad 4, .winClose] ++
        keys [.padBtn 0 true])).map fun s => (s.ed.isOpen, wantsPad real s)) =
      some (false, true) := by
  decide

/-- The two halves of the fix are each needed.
* Clearing `visible` in render alone (`visGate`) does not stop the close
  trace: after the X, render may never run again (render_imgui's early
  return when nothing is open and the menu bar has hidden, 1271-1283; here
  every later iteration is `noRender`), and in any case the next
  `handle_input` comes before the next render.
* Testing `open` alone (`openGate`) does not stop the collapse trace: the
  window is still open. -/
theorem capture_fix_needs_both_halves :
    ((run { visGate := true } init trCloseMidCapture).map fun s => s.lastRoute) =
      some .capture ∧
    ((run { openGate := true } init trCloseMidCapture).map fun s => s.lastRoute) =
      some (.game 4) ∧
    ((run { openGate := true } init (openSettingsGba ++ iter [.bindKey 0, .winCollapse true] ++
        iter [] ++ keys (tap (.plain 4)))).map fun s => s.lastRoute) = some .capture ∧
    ((run { visGate := true } init (openSettingsGba ++ iter [.bindKey 0, .winCollapse true] ++
        iter [] ++ keys (tap (.plain 4)))).map fun s => s.lastRoute) = some (.game 4) := by
  decide

/-- With the fix: after the window closes, no key or pad button is captured. -/
theorem fixed_closed_never_captures (s : S) (h : s.ed.isOpen = false) :
    wantsKb fixed s = false ∧ wantsPad fixed s = false := by
  simp [wantsKb, wantsPad, fixed, h]

theorem regress_close_midcapture :
    ((run fixed init trCloseMidCapture).map fun s => s.lastRoute) = some (.game 4) := by
  decide

/-- Collapse, fixed: the next frame's render clears `visible`. -/
theorem regress_collapse_midcapture :
    ((run fixed init (openSettingsGba ++ iter [.bindKey 0, .winCollapse true] ++
        iter [] ++ keys (tap (.plain 4)))).map fun s => s.lastRoute) = some (.game 4) := by
  decide

/-! ## (c) A capture accepts keys the game can never receive -/

/-- Bind START to F12 (or F9, or backquote) in the Keybindings tab and press
OK. The widget shows F12 next to START, cfg has it, and F12 still takes a
screenshot: START is never pressed (1671 comes before 1679). -/
def trBindF12 : List Ev :=
  openSettingsGba ++ iter [.bindKey 7] ++ keys (tap .f12) ++ iter [.ok] ++ keys [.key .f12 true]

theorem bug_bound_f12_never_reaches_game :
    ((run real init trBindF12).map fun s => (s.cfg.kb .f12, s.lastRoute)) =
      some (some 7, .shot) := by
  decide

/-- Bind B to Ctrl (Windows/Linux) or Cmd (macOS). Its KeyDown carries its own
modifier bit, so it takes the hotkey branch (1644), which acts only on
releases: B is never pressed. The release does reach the game. -/
def trBindMod : List Ev :=
  openSettingsGba ++ iter [.bindKey 5] ++ keys (tap .modKey) ++ iter [.ok] ++
    keys [.key .modKey true]

theorem bug_bound_modifier_never_presses :
    ((run real init trBindMod).map fun s => (s.cfg.kb .modKey, s.lastRoute)) =
      some (some 5, .modHotkey) := by
  decide

/-- Binding Tab (or 1-6) works: the binding is tested first. The menu still
labels Fast Forward "Tab" (1357), which no longer fast-forwards. -/
theorem obs_bound_tab_shadows_fast_forward :
    ((run real init (openSettingsGba ++ iter [.bindKey 5] ++ keys (tap .tab) ++ iter [.ok] ++
        keys [.key .tab true])).map fun s => s.lastRoute) = some (.game 5) := by
  decide

theorem regress_bound_f12 :
    ((run fixed init trBindF12).map fun s => (s.cfg.kb .f12, s.cfg.kb (.plain 7), s.lastRoute)) =
      some (none, some 7, .shot) := by
  decide

/-! ## (b) save_config(load_config(f)) and what survives a restart -/

/-- Bind UP to a keypad key (the widget shows "Keypad 8"), press OK, quit,
start again: UP has no key at all. The arrow key it replaced was unbound by
the capture (keybindings 33), and the keypad key did not survive the file. -/
def trNumpad : List Ev :=
  openSettingsGba ++ iter [.bindKey 0] ++ keys (tap .unnamed) ++ iter [.ok] ++ [.restart {}]

def keysFor (c : Cfg) (i : Inp) : List Key := allKeys.filter fun k => c.kb k == some i

theorem bug_numpad_binding_lost_on_restart :
    ((run real init (openSettingsGba ++ iter [.bindKey 0] ++ keys (tap .unnamed) ++
        iter [.ok])).map fun s => keysFor s.cfg 0) = some [.unnamed] ∧
    ((run real init trNumpad).map fun s => keysFor s.cfg 0) = some [] := by
  decide

/-- The round trip loses only unnamed keys: `persist` is idempotent, and it
is the identity on a cfg whose bound keys all have names. -/
theorem persist_idem (c : Cfg) : persist (persist c) = persist c := by
  simp only [persist]
  congr 1
  · funext k; split <;> simp_all
  · funext b; split <;> simp_all

def KbNamed (c : Cfg) : Prop := ∀ k i, c.kb k = some i → k.named = true

theorem persist_id_of_named (c : Cfg) (h : KbNamed c) (hp : ∀ b i, c.pad b = some i → b < 15) :
    persist c = c := by
  cases c with
  | mk kb pad a b c' d e f g h' i j k' l =>
    simp only [persist, Cfg.mk.injEq, and_true]
    constructor
    · funext x
      cases hx : kb x with
      | none => simp
      | some v => simp [h x v hx]
    · funext x
      cases hx : pad x with
      | none => simp
      | some v => simp [hp x v hx]

/-- The CLI overrides are written into cfg (2164-2175) and saved by the next
save_config -- here the recents update of the ROM load. A user who chose the
real BIOS in Settings, then once ran `dingbat --hle game.gba`, is on HLE for
good: the Settings window now shows HLE, and nothing said so. -/
def trCliChoose : List Ev :=
  openSettingsGba ++ iter [.selectTab .bios] ++ iter [.biosBrowse] ++
    iter [.feSelect .biosBin, .feOpen] ++ iter [.setBiosMode 1, .ok] ++ [.restart {}]
def trCli : List Ev :=
  trCliChoose ++ [.restart { hle := true }] ++ keys [.drop .gbaRom] ++ [.restart {}]

theorem bug_cli_flag_persists :
    ((run real init trCliChoose).map fun s => (s.cfg.useHle, s.cfg.biosFile)) =
      some (false, true) ∧
    ((run real init trCli).map fun s => s.cfg.useHle) = some true := by
  decide

/-- A config file that no longer parses is replaced by the defaults on the
first save_config (a ROM load's recents update), with no message: every
binding, the recents, the BIOS path and the volume are gone. -/
theorem bug_bad_file_overwritten :
    ((run real init (iter [.menuVolume 40] ++ [.corruptFile, .restart {}] ++
        keys [.drop .gbRom])).map fun s =>
      (match s.disk with | .ok c => c.volume | _ => 0)) = some 100 := by
  decide

/-! ## (a) BIOS settings the running app cannot honour -/

/-- "Real BIOS" with no BIOS file (the help text says a BIOS is embedded) is
accepted, saved, and loaded: the core maps the 16 KB IRQ-only stub
(bus.nim 370-375) and sends every SWI to its vector 0x08 (arm.nim 626-636),
which the stub does not implement. Run headless (new_gba("", rom,
run_bios = false, use_hle = false), what load_rom builds here): Advance Wars
showed 2 distinct frames in 900, against 714 with HLE -- the game hangs at
its first BIOS call. -/
def trRealNoFile : List Ev :=
  openSettingsGba ++ iter [.selectTab .bios] ++ iter [.setBiosMode 1, .ok] ++
    keys [.drop .gbaRom]

theorem bug_real_bios_without_file :
    ((run real init trRealNoFile).map fun s =>
      s.core.map fun c => (c.kind, c.hle, c.afterBios, c.biosFile)) =
      some (some (.gba, false, false, false)) := by
  decide

/-- "Run BIOS intro" with no file: the core boots at 0 into the same stub.
Headless: PC parked at 0x1C, one (black) frame in 900. -/
theorem bug_run_bios_without_file :
    ((run real init (openSettingsGba ++ iter [.selectTab .bios] ++
        iter [.setRunBios true, .ok] ++ keys [.drop .gbaRom])).map fun s =>
      s.core.map fun c => (c.runBios, c.biosFile)) = some (some (true, false)) := by
  decide

theorem regress_real_bios_without_file :
    ((run fixed init trRealNoFile).map fun s =>
      s.core.map fun c => (c.hle, c.runBios)) = some (some (true, false)) := by
  decide

/-- The capture fixes, replayed: the keypad key and Ctrl are refused, the
input keeps its old key, and the capture stays on that input. -/
theorem regress_numpad_and_modifier :
    ((run fixed init trNumpad).map fun s => keysFor s.cfg 0) = some [.plain 0] ∧
    ((run fixed init trBindMod).map fun s => (s.cfg.kb .modKey, keysFor s.cfg 5)) =
      some (none, [.plain 5]) := by
  decide

/-! ## The file explorer's remembered selection -/

/-- Pick the BIOS through Settings > BIOS > Browse, then File > Open ROM in
the same folder and press Open with nothing highlighted: the BIOS
selection is still `selected_idx` (the ROM dialog merely hides the row), so
Open loads gba_bios.bin as a GBA cartridge, replaces the running game, and
puts the BIOS at the top of Recent (so Reset reloads it). -/
def trFeStale : List Ev :=
  openSettingsGba ++ iter [.selectTab .bios] ++ iter [.biosBrowse] ++
    iter [.feSelect .biosBin, .feOpen] ++ iter [.ok] ++ iter [.menuOpenRom] ++ iter [.feOpen]

theorem bug_rom_dialog_opens_hidden_selection :
    ((run real init trFeStale).map fun s =>
      (s.core.map (·.kind), s.cfg.recent)) = some (some .junk, some .biosBin) := by
  decide

theorem regress_rom_dialog_opens_hidden_selection :
    ((run fixed init trFeStale).map fun s =>
      (s.core.map (·.kind), s.fe.dlg)) = some (some .gba, .rom) := by
  decide

/-! ## (d) Reset to Defaults -/

/-- "Restore all settings to their defaults?" leaves Audio interpolation off
and Speed mode on: do_factory_reset lists neither. -/
theorem bug_reset_defaults_keeps_interp_and_speed :
    ((run real init (openSettingsGba ++ iter [.menuInterp] ++ iter [.menuSpeed] ++
        iter [.resetDefaults] ++ iter [.resetConfirm])).map fun s =>
      (s.cfg.interp, s.cfg.speed)) = some (false, true) := by
  decide

/-- Resetting speed_mode in cfg without calling apply_speed_mode (live_sync
does not) leaves the running GBA core frameskipping and underclocked while
the menu shows Speed mode off. -/
theorem bug_naive_reset_fix_leaves_core_in_speed_mode :
    ((run naive init (openSettingsGba ++ iter [.menuSpeed] ++ iter [.resetDefaults] ++
        iter [.resetConfirm])).map fun s =>
      (s.cfg.speed, s.core.map (·.frameskip))) = some (false, some true) := by
  decide

theorem regress_reset_defaults :
    ((run fixed init (openSettingsGba ++ iter [.menuInterp] ++ iter [.menuSpeed] ++
        iter [.resetDefaults] ++ iter [.resetConfirm])).map fun s =>
      (s.cfg.interp, s.cfg.speed, s.core.map fun c => (c.interp, c.frameskip))) =
      some (true, false, some (true, false)) := by
  decide

/-! ## Other observations -/

/-- The X is Cancel: edits made before it are dropped at the next open (the
open edge's do_reset). No prompt; the Revert button does the same. -/
theorem obs_close_discards_edits :
    ((run real init (openSettingsGba ++ iter [.selectTab .video] ++ iter [.setFifo false] ++
        iter [.winClose] ++ iter [.menuSettings])).map fun s =>
      (s.ed.vFifo, s.cfg.gbFifo)) = some (true, true) := by
  decide

/-- Speed mode on a running GB game: the menu item is checked, cfg and the
file say on, but the FIFO renderer (which ignores frameskip) keeps running
until the next load. The menu label does not say "next load" (the code
comment at 1340 does). -/
theorem obs_speed_mode_waits_for_gb_load :
    ((run real init (keys [.drop .gbRom] ++ iter [.menuSpeed])).map fun s =>
      (s.cfg.speed, s.core.map (·.fifo))) = some (true, some true) := by
  decide

/-- Emulation > Reset after File > Recent > Clear does nothing, silently. -/
theorem obs_reset_noop_after_clear :
    ((run real init (keys [.drop .gbaRom] ++ iter [.menuClearRecent] ++ iter [.menuReset])).map
      fun s => (s.core.map (·.gen), s.gen)) = some (some 1, 1) := by
  decide

/-! ## What holds, for the code as it is -/

/-- (a)/(d): every setting applied live agrees with cfg: the colour uniform,
and the running core's volume, frameskip and (GBA) FIFO interpolation. This
holds through the menus, the Settings window's Apply/OK, a ROM load, a
relaunch and Reset to Defaults (live_sync). -/
def LiveOK (s : S) : Prop :=
  s.shaderColor = s.cfg.color ∧
  ∀ c, s.core = some c →
    c.volume = s.cfg.volume ∧ c.frameskip = s.cfg.speed ∧
    (c.kind = .gb ∨ c.interp = (s.cfg.interp && !s.cfg.speed))

/-- The Cheats window edits the running core's engine (attach in every load,
732-734). -/
def CheatsOK (s : S) : Prop := s.cheatsGen = s.core.map (·.gen)

/-! ### Field lemmas -/

section fields
variable (s : S)
@[simp] theorem save_cfg : (save s).cfg = s.cfg := rfl
@[simp] theorem save_core : (save s).core = s.core := rfl
@[simp] theorem save_color : (save s).shaderColor = s.shaderColor := rfl
@[simp] theorem save_ed : (save s).ed = s.ed := rfl
@[simp] theorem save_fe : (save s).fe = s.fe := rfl
@[simp] theorem save_disk : (save s).disk = .ok s.cfg := rfl
@[simp] theorem save_cheats : (save s).cheatsGen = s.cheatsGen := rfl
@[simp] theorem applyVolume_cfg : (applyVolume s).cfg = s.cfg := rfl
@[simp] theorem applyVolume_color : (applyVolume s).shaderColor = s.shaderColor := rfl
@[simp] theorem applyVolume_ed : (applyVolume s).ed = s.ed := rfl
@[simp] theorem applyVolume_fe : (applyVolume s).fe = s.fe := rfl
@[simp] theorem applyVolume_disk : (applyVolume s).disk = s.disk := rfl
@[simp] theorem applyInterp_cfg : (applyInterp s).cfg = s.cfg := rfl
@[simp] theorem applyInterp_color : (applyInterp s).shaderColor = s.shaderColor := rfl
@[simp] theorem applyInterp_ed : (applyInterp s).ed = s.ed := rfl
@[simp] theorem applyInterp_fe : (applyInterp s).fe = s.fe := rfl
@[simp] theorem applyInterp_disk : (applyInterp s).disk = s.disk := rfl
@[simp] theorem applySpeed_cfg : (applySpeed s).cfg = s.cfg := rfl
@[simp] theorem applySpeed_color : (applySpeed s).shaderColor = s.shaderColor := rfl
@[simp] theorem applySpeed_ed : (applySpeed s).ed = s.ed := rfl
@[simp] theorem applySpeed_fe : (applySpeed s).fe = s.fe := rfl
@[simp] theorem applySpeed_disk : (applySpeed s).disk = s.disk := rfl
@[simp] theorem applyColor_cfg : (applyColor s).cfg = s.cfg := rfl
@[simp] theorem applyColor_core : (applyColor s).core = s.core := rfl
@[simp] theorem applyColor_color : (applyColor s).shaderColor = s.cfg.color := rfl
@[simp] theorem applyColor_ed : (applyColor s).ed = s.ed := rfl
@[simp] theorem applyColor_fe : (applyColor s).fe = s.fe := rfl
@[simp] theorem applyColor_disk : (applyColor s).disk = s.disk := rfl

theorem core_applyVolume (c : Core) (h : (applyVolume s).core = some c) :
    ∃ c0, s.core = some c0 ∧ c = { c0 with volume := s.cfg.volume } := by
  cases h0 : s.core with
  | none => simp [applyVolume, h0] at h
  | some c0 => simp [applyVolume, h0] at h; exact ⟨c0, rfl, h.symm⟩

theorem core_applyInterp (c : Core) (h : (applyInterp s).core = some c) :
    ∃ c0, s.core = some c0 ∧
      c = if c0.kind = .gb then c0 else { c0 with interp := s.cfg.interp && !s.cfg.speed } := by
  cases h0 : s.core with
  | none => simp [applyInterp, h0] at h
  | some c0 => simp only [applyInterp, h0, Option.map_some, Option.some.injEq] at h; exact ⟨c0, rfl, h.symm⟩

theorem core_applySpeed (c : Core) (h : (applySpeed s).core = some c) :
    ∃ c0, s.core = some c0 ∧
      c = if c0.kind = .gb then { c0 with frameskip := s.cfg.speed }
          else { c0 with frameskip := s.cfg.speed, interp := s.cfg.interp && !s.cfg.speed } := by
  cases h0 : s.core with
  | none => simp [applySpeed, applyInterp, h0] at h
  | some c0 =>
    simp only [applySpeed, applyInterp, h0, Option.map_some, Option.some.injEq] at h
    refine ⟨c0, rfl, ?_⟩
    rw [← h]
end fields

/-! ### LiveOK -/

theorem liveOK_applyVolume (t : S) (hc : t.shaderColor = t.cfg.color)
    (h : ∀ c, t.core = some c → c.frameskip = t.cfg.speed ∧
      (c.kind = .gb ∨ c.interp = (t.cfg.interp && !t.cfg.speed))) : LiveOK (applyVolume t) := by
  refine ⟨hc, ?_⟩
  intro c hc'
  obtain ⟨c0, h0, rfl⟩ := core_applyVolume t c hc'
  obtain ⟨a, b⟩ := h c0 h0
  exact ⟨rfl, a, b⟩

theorem liveOK_applyInterp (t : S) (hc : t.shaderColor = t.cfg.color)
    (h : ∀ c, t.core = some c → c.volume = t.cfg.volume ∧ c.frameskip = t.cfg.speed) :
    LiveOK (applyInterp t) := by
  refine ⟨hc, ?_⟩
  intro c hc'
  obtain ⟨c0, h0, rfl⟩ := core_applyInterp t c hc'
  obtain ⟨a, b⟩ := h c0 h0
  by_cases hk : c0.kind = .gb
  · rw [ite_eq_left hk]; exact ⟨a, b, Or.inl hk⟩
  · rw [ite_eq_right hk]; exact ⟨a, b, Or.inr rfl⟩

theorem liveOK_applySpeed (t : S) (hc : t.shaderColor = t.cfg.color)
    (h : ∀ c, t.core = some c → c.volume = t.cfg.volume) : LiveOK (applySpeed t) := by
  refine ⟨hc, ?_⟩
  intro c hc'
  obtain ⟨c0, h0, rfl⟩ := core_applySpeed t c hc'
  have a := h c0 h0
  by_cases hk : c0.kind = .gb
  · rw [ite_eq_left hk]; exact ⟨a, rfl, Or.inl hk⟩
  · rw [ite_eq_right hk]; exact ⟨a, rfl, Or.inr rfl⟩

theorem liveOK_applyColor (t : S)
    (h : ∀ c, t.core = some c → c.volume = t.cfg.volume ∧ c.frameskip = t.cfg.speed ∧
      (c.kind = .gb ∨ c.interp = (t.cfg.interp && !t.cfg.speed))) : LiveOK (applyColor t) :=
  ⟨rfl, h⟩

theorem liveOK_loadRom (fx : Fix) (s : S) (f : FileE) (hc : s.shaderColor = s.cfg.color) :
    LiveOK (loadRom fx s f) := by
  refine ⟨hc, ?_⟩
  intro c hc'
  simp only [loadRom, save, Option.some.injEq] at hc'
  subst hc'
  exact ⟨rfl, rfl, Or.inr rfl⟩

theorem liveOK_launch (d : Disk) (a : Cli) (g : Nat) : LiveOK (launch d a g) := by
  refine ⟨rfl, ?_⟩
  intro c hc; simp [launch] at hc

theorem liveOK_save {s : S} (h : LiveOK s) : LiveOK (save s) := h

/-- Changing nothing LiveOK reads keeps it. -/
theorem liveOK_of_eq {s t : S} (h : LiveOK s) (hc : t.shaderColor = s.shaderColor)
    (hcore : t.core = s.core) (h1 : t.cfg.color = s.cfg.color) (h2 : t.cfg.volume = s.cfg.volume)
    (h3 : t.cfg.speed = s.cfg.speed) (h4 : t.cfg.interp = s.cfg.interp) : LiveOK t := by
  refine ⟨by rw [hc, h1]; exact h.1, ?_⟩
  intro c hc'
  rw [hcore] at hc'
  obtain ⟨a, b, d⟩ := h.2 c hc'
  exact ⟨by rw [h2]; exact a, by rw [h3]; exact b, by rw [h4, h3]; exact d⟩

theorem onKey_shape (fx : Fix) (s : S) (k : Key) (d : Bool) :
    ∃ e m r, onKey fx s k d = { s with ed := e, modHeld := m, lastRoute := r } :=
  ⟨_, _, _, rfl⟩

theorem onPad_shape (fx : Fix) (s : S) (b : Nat) (d : Bool) :
    ∃ e, onPad fx s b d = { s with ed := e } := ⟨_, rfl⟩

theorem doApply_live (s : S) :
    (doApply s).core = s.core ∧ (doApply s).shaderColor = s.shaderColor ∧
    (doApply s).cfg.color = s.cfg.color ∧ (doApply s).cfg.volume = s.cfg.volume ∧
    (doApply s).cfg.speed = s.cfg.speed ∧ (doApply s).cfg.interp = s.cfg.interp ∧
    (doApply s).cheatsGen = s.cheatsGen :=
  ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem liveOK_factory (fx : Fix) (hfx : fx.resetNaive = true → fx.resetAll = true) (s : S)
    (h : LiveOK s) : LiveOK (factoryReset fx s) := by
  let s2 := doApply { s with cfg := factoryCfg fx s.cfg, ed := edLoad (factoryCfg fx s.cfg) s.ed }
  have h2core : s2.core = s.core := rfl
  unfold factoryReset
  cases hA : fx.resetAll
  · have hN : fx.resetNaive = false := by
      cases hN : fx.resetNaive
      · rfl
      · exact absurd (hfx hN) (by simp [hA])
    have hsp : s2.cfg.speed = s.cfg.speed := by
      simp [s2, doApply, save, edStore, factoryCfg, hA, hN]
    simp only [Bool.false_eq_true, ite_false]
    apply liveOK_of_eq (s := applyInterp (applyVolume (applyColor s2)))
    · apply liveOK_applyInterp
      · rfl
      · intro c hc
        obtain ⟨c0, h0, rfl⟩ := core_applyVolume _ c hc
        refine ⟨rfl, ?_⟩
        rw [applyColor_core, h2core] at h0
        obtain ⟨_, b, _⟩ := h.2 c0 h0
        show c0.frameskip = s2.cfg.speed
        rw [hsp, b]
    all_goals rfl
  · simp only [ite_true]
    apply liveOK_of_eq (s := applySpeed (applyInterp (applyVolume (applyColor s2))))
    · apply liveOK_applySpeed
      · rfl
      · intro c hc
        obtain ⟨c0, h0, rfl⟩ := core_applyInterp _ c hc
        obtain ⟨c1, h1, rfl⟩ := core_applyVolume _ c0 h0
        by_cases hk : c1.kind = .gb
        · rw [ite_eq_left hk]; rfl
        · rw [ite_eq_right hk]; rfl
    all_goals rfl

theorem liveOK_stepO (fx : Fix) (hfx : fx.resetNaive = true → fx.resetAll = true)
    {s t : S} (h : LiveOK s) (e : Ev) (he : stepO fx s e = some t) : LiveOK t := by
  have hc := h.1
  cases e <;> simp only [stepO] at he <;> (try split at he) <;> (try cases he) <;>
    first
    | exact h
    | exact liveOK_loadRom fx s _ hc
    | exact liveOK_factory fx hfx s h
    | exact liveOK_launch _ _ _
    | (obtain ⟨_, _, _, hk⟩ := onKey_shape fx s _ _; rw [hk]; exact h)
    | (obtain ⟨_, hk⟩ := onPad_shape fx s _ _; rw [hk]; exact h)
    | exact liveOK_save (liveOK_applySpeed _ hc (fun c hc' => (h.2 c hc').1))
    | exact liveOK_save (liveOK_applyInterp _ hc (fun c hc' => ⟨(h.2 c hc').1, (h.2 c hc').2.1⟩))
    | exact liveOK_save (liveOK_applyColor _ (fun c hc' => h.2 c hc'))
    | exact liveOK_save (liveOK_applyVolume _ hc (fun c hc' => ⟨(h.2 c hc').2.1, (h.2 c hc').2.2⟩))
    | (split <;> first
        | exact h
        | exact liveOK_loadRom fx _ _ hc
        | (split <;> first | exact h | exact liveOK_loadRom fx _ _ hc))
    | skip
  all_goals done

theorem reachable_induct {P : S → Prop} (fx : Fix) (h0 : P init)
    (hs : ∀ s t e, P s → stepO fx s e = some t → P t) : ∀ s, Reachable fx s → P s := by
  intro s hr
  induction hr with
  | init => exact h0
  | step e _ ih =>
    simp only [step]
    cases h : stepO fx _ e with
    | none => simpa using ih
    | some t => exact hs _ _ _ ih h

theorem liveOK_init : LiveOK init := liveOK_launch _ _ _

/-- (a)/(d), proved: for the code as it is (and for the fixed code), every
live setting agrees with cfg in every reachable state. The live side is
consistent after Reset to Defaults; what Reset does not do is reset two
settings (`bug_reset_defaults_keeps_interp_and_speed`). -/
theorem liveOK_reachable (fx : Fix) (hfx : fx.resetNaive = true → fx.resetAll = true) :
    ∀ s, Reachable fx s → LiveOK s :=
  reachable_induct fx liveOK_init fun _ _ e h he => liveOK_stepO fx hfx h e he

theorem liveOK_real : ∀ s, Reachable real s → LiveOK s :=
  liveOK_reachable real (by intro h; cases h)
theorem liveOK_fixed : ∀ s, Reachable fixed s → LiveOK s :=
  liveOK_reachable fixed (fun _ => rfl)

/-! ### The Cheats window follows the core -/

section gens
variable (s : S)
theorem gen_applyVolume : (applyVolume s).core.map (·.gen) = s.core.map (·.gen) := by
  cases h : s.core <;> simp [applyVolume, h]
theorem gen_applyInterp : (applyInterp s).core.map (·.gen) = s.core.map (·.gen) := by
  cases h : s.core with
  | none => simp [applyInterp, h]
  | some c => simp only [applyInterp, h, Option.map_some]; split <;> rfl
theorem gen_applySpeed : (applySpeed s).core.map (·.gen) = s.core.map (·.gen) := by
  unfold applySpeed
  rw [gen_applyInterp]
  cases s.core <;> simp
end gens

theorem cheatsOK_factory (fx : Fix) (s : S) (h : CheatsOK s) : CheatsOK (factoryReset fx s) := by
  unfold factoryReset CheatsOK
  split
  · show s.cheatsGen = _
    rw [gen_applySpeed, gen_applyInterp, gen_applyVolume]; exact h
  · show s.cheatsGen = _
    rw [gen_applyInterp, gen_applyVolume]; exact h

theorem cheatsOK_save {t : S} (h : CheatsOK t) : CheatsOK (save t) := h
theorem cheatsOK_applySpeed {t : S} (h : CheatsOK t) : CheatsOK (applySpeed t) := by
  unfold CheatsOK; rw [gen_applySpeed]; exact h
theorem cheatsOK_applyInterp {t : S} (h : CheatsOK t) : CheatsOK (applyInterp t) := by
  unfold CheatsOK; rw [gen_applyInterp]; exact h
theorem cheatsOK_applyVolume {t : S} (h : CheatsOK t) : CheatsOK (applyVolume t) := by
  unfold CheatsOK; rw [gen_applyVolume]; exact h

theorem cheatsOK_stepO (fx : Fix) {s t : S} (h : CheatsOK s) (e : Ev)
    (he : stepO fx s e = some t) : CheatsOK t := by
  cases e <;> simp only [stepO] at he <;> (try split at he) <;> (try cases he) <;>
    first
    | exact h
    | rfl
    | exact cheatsOK_factory fx s h
    | exact cheatsOK_save (cheatsOK_applySpeed h)
    | exact cheatsOK_save (cheatsOK_applyInterp h)
    | exact cheatsOK_save (cheatsOK_applyVolume h)
    | (split <;> first | exact h | rfl | (split <;> first | exact h | rfl))

/-- The Cheats window always edits (and on_change saves) the running core's
engine, across every ROM switch. -/
theorem cheatsOK_reachable (fx : Fix) : ∀ s, Reachable fx s → CheatsOK s :=
  reachable_induct fx rfl fun _ _ e h he => cheatsOK_stepO fx h e he

/-! ### The Settings window and the menus cannot overwrite each other -/

/-- do_apply writes only widget-owned fields, and the menus write only
theirs, so a menu change made while Settings is open survives its Apply,
and an Apply survives any later menu change, in either order. -/
theorem apply_menu_commute (e : Ed) (c : Cfg) (v : Nat) :
    edStore e { c with speed := !c.speed } = { edStore e c with speed := !(edStore e c).speed } ∧
    edStore e { c with interp := !c.interp } = { edStore e c with interp := !(edStore e c).interp } ∧
    edStore e { c with color := !c.color } = { edStore e c with color := !(edStore e c).color } ∧
    edStore e { c with rewind := !c.rewind } = { edStore e c with rewind := !(edStore e c).rewind } ∧
    edStore e { c with volume := v } = { edStore e c with volume := v } ∧
    edStore e { c with recent := none } = { edStore e c with recent := none } :=
  ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- The one writer of both sets is Reset to Defaults, on purpose. -/
theorem apply_keeps_menu_fields (e : Ed) (c : Cfg) :
    (edStore e c).speed = c.speed ∧ (edStore e c).interp = c.interp ∧
    (edStore e c).color = c.color ∧ (edStore e c).volume = c.volume ∧
    (edStore e c).rewind = c.rewind ∧ (edStore e c).recent = c.recent :=
  ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩

/-! ## The fixed code: what the fixes buy -/

def KbOk (k : Key) : Bool := k.named && !k.reserved

def CfgGood (c : Cfg) : Prop :=
  (∀ k i, c.kb k = some i → KbOk k = true) ∧ (∀ b i, c.pad b = some i → b < 15) ∧
  c.recent ≠ some .biosBin

def DiskGood : Disk → Prop
  | .ok c => CfgGood c
  | _ => True

def CoreGood (c : Core) : Prop :=
  c.kind ≠ .junk ∧
  (c.kind = .gb ∨ ((c.hle || c.afterBios || c.biosFile) = true ∧ (!c.runBios || c.biosFile) = true))

structure InvF (s : S) : Prop where
  cfg     : CfgGood s.cfg
  disk    : DiskGood s.disk
  kbEdit  : ∀ k i, s.ed.kbEdit k = some i → KbOk k = true
  padEdit : ∀ b i, s.ed.padEdit b = some i → b < 15
  fe      : s.fe.dlg = .rom → s.fe.sel ≠ some .biosBin
  core    : ∀ c, s.core = some c → CoreGood c

theorem cfgGood_defaults : CfgGood defaults := by
  refine ⟨?_, ?_, by simp [defaults]⟩
  · intro k i h
    cases k with
    | plain n => rfl
    | _ => simp [defaults, defaultKb] at h
  · intro b i h
    simp only [defaults] at h
    match b, h with
    | 0, _ | 1, _ | 2, _ | 3, _ | 4, _ | 6, _ | 9, _ | 10, _ | 11, _ | 12, _ | 13, _
    | 14, _ => decide

theorem cfgGood_persist (c : Cfg) (h : CfgGood c) : CfgGood (persist c) := by
  refine ⟨?_, ?_, h.2.2⟩
  · intro k i hk
    simp only [persist] at hk
    split at hk
    · exact h.1 k i hk
    · cases hk
  · intro b i hb
    simp only [persist] at hb
    split at hb
    · assumption
    · cases hb

theorem cliApply_keep (a : Cli) (c : Cfg) :
    (cliApply a c).kb = c.kb ∧ (cliApply a c).pad = c.pad ∧ (cliApply a c).recent = c.recent := by
  unfold cliApply
  cases a with
  | mk h ab rb ba =>
    cases h <;> cases ab <;> cases rb <;> cases ba <;> simp

theorem cfgGood_cli (a : Cli) (c : Cfg) (h : CfgGood c) : CfgGood (cliApply a c) := by
  obtain ⟨h1, h2, h3⟩ := cliApply_keep a c
  exact ⟨by rw [h1]; exact h.1, by rw [h2]; exact h.2.1, by rw [h3]; exact h.2.2⟩

theorem cfgGood_loadDisk (d : Disk) (h : DiskGood d) : CfgGood (loadDisk d) := by
  cases d with
  | missing => exact cfgGood_defaults
  | ok c => exact cfgGood_persist c h
  | bad => exact cfgGood_defaults

theorem invF_launch (d : Disk) (a : Cli) (g : Nat) (h : DiskGood d) : InvF (launch d a g) where
  cfg := cfgGood_cli a _ (cfgGood_loadDisk d h)
  disk := h
  kbEdit := by intro k i hk; simp [launch, initEd] at hk
  padEdit := by intro b i hb; simp [launch, initEd] at hb
  fe := by simp [launch]
  core := by intro c hc; simp [launch] at hc

theorem invF_init : InvF init := invF_launch _ _ _ trivial

/-- InvF reads only cfg, disk, the widgets' edits, the explorer and the core. -/
theorem invF_same {s t : S} (h : InvF s) (h1 : t.cfg = s.cfg) (h2 : t.disk = s.disk)
    (h3 : t.ed.kbEdit = s.ed.kbEdit) (h4 : t.ed.padEdit = s.ed.padEdit) (h5 : t.fe = s.fe)
    (h6 : t.core = s.core) : InvF t := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [h1]; exact h.cfg
  · rw [h2]; exact h.disk
  · rw [h3]; exact h.kbEdit
  · rw [h4]; exact h.padEdit
  · rw [h5]; exact h.fe
  · rw [h6]; exact h.core

theorem invF_save {s : S} (h : InvF s) : InvF (save s) :=
  ⟨h.cfg, h.cfg, h.kbEdit, h.padEdit, h.fe, h.core⟩

theorem invF_applyVolume {s : S} (h : InvF s) : InvF (applyVolume s) := by
  refine ⟨h.cfg, h.disk, h.kbEdit, h.padEdit, h.fe, ?_⟩
  intro c hc
  obtain ⟨c0, h0, rfl⟩ := core_applyVolume s c hc
  exact h.core c0 h0

theorem invF_applyInterp {s : S} (h : InvF s) : InvF (applyInterp s) := by
  refine ⟨h.cfg, h.disk, h.kbEdit, h.padEdit, h.fe, ?_⟩
  intro c hc
  obtain ⟨c0, h0, rfl⟩ := core_applyInterp s c hc
  split
  · exact h.core c0 h0
  · exact h.core c0 h0

theorem invF_applySpeed {s : S} (h : InvF s) : InvF (applySpeed s) := by
  refine ⟨h.cfg, h.disk, h.kbEdit, h.padEdit, h.fe, ?_⟩
  intro c hc
  obtain ⟨c0, h0, rfl⟩ := core_applySpeed s c hc
  split
  · exact h.core c0 h0
  · exact h.core c0 h0

theorem invF_applyColor {s : S} (h : InvF s) : InvF (applyColor s) :=
  ⟨h.cfg, h.disk, h.kbEdit, h.padEdit, h.fe, h.core⟩

theorem invF_loadRom {s : S} (h : InvF s) (f : FileE) (hf : f ≠ .biosBin) :
    InvF (loadRom fixed s f) where
  cfg := ⟨h.cfg.1, h.cfg.2.1, by simp [loadRom, save]; exact hf⟩
  disk := ⟨h.cfg.1, h.cfg.2.1, by simp; exact hf⟩
  kbEdit := h.kbEdit
  padEdit := h.padEdit
  fe := h.fe
  core := by
    intro c hc
    simp only [loadRom, save, Option.some.injEq] at hc
    subst hc
    refine ⟨by cases f <;> simp_all [FileE.kind], ?_⟩
    cases f with
    | gbRom => exact Or.inl rfl
    | _ =>
      refine Or.inr ⟨?_, ?_⟩ <;>
      cases s.cfg.useHle <;> cases s.cfg.biosFile <;> cases s.cfg.runBios <;> simp [fixed]

def FeGood (s : S) : Prop := s.fe.dlg = .rom → s.fe.sel ≠ some .biosBin

theorem invF_mk' {s t : S} (h : InvF s) (h1 : CfgGood t.cfg) (h2 : DiskGood t.disk)
    (h3 : t.ed.kbEdit = s.ed.kbEdit) (h4 : t.ed.padEdit = s.ed.padEdit) (h5 : FeGood t)
    (h6 : t.core = s.core) : InvF t := by
  refine ⟨h1, h2, ?_, ?_, h5, ?_⟩
  · rw [h3]; exact h.kbEdit
  · rw [h4]; exact h.padEdit
  · rw [h6]; exact h.core

theorem invF_ceTop' {s t : S} (h : InvF s) (e : Ed)
    (he1 : ∀ k i, e.kbEdit k = some i → KbOk k = true)
    (he2 : ∀ b i, e.padEdit b = some i → b < 15)
    (ht : t.ed = ceTop fixed s.cfg e) (hc : t.cfg = s.cfg) (hd : t.disk = s.disk)
    (hf : t.fe = s.fe) (hco : t.core = s.core) : InvF t := by
  have key : (ceTop fixed s.cfg e).kbEdit = e.kbEdit ∨ (ceTop fixed s.cfg e).kbEdit = s.cfg.kb := by
    unfold ceTop; dsimp only; split
    · exact Or.inr rfl
    · exact Or.inl rfl
  have key2 : (ceTop fixed s.cfg e).padEdit = e.padEdit ∨
      (ceTop fixed s.cfg e).padEdit = s.cfg.pad := by
    unfold ceTop; dsimp only; split
    · exact Or.inr rfl
    · exact Or.inl rfl
  refine ⟨by rw [hc]; exact h.cfg, by rw [hd]; exact h.disk, ?_, ?_,
    by rw [hf]; exact h.fe, by rw [hco]; exact h.core⟩
  · intro k i hk
    rw [ht] at hk
    rcases key with k' | k'
    · exact he1 k i (by rw [← k']; exact hk)
    · exact h.cfg.1 k i (by rw [← k']; exact hk)
  · intro b i hb
    rw [ht] at hb
    rcases key2 with k' | k'
    · exact he2 b i (by rw [← k']; exact hb)
    · exact h.cfg.2.1 b i (by rw [← k']; exact hb)

theorem invF_ceTop {s : S} (h : InvF s) (e : Ed)
    (he1 : ∀ k i, e.kbEdit k = some i → KbOk k = true)
    (he2 : ∀ b i, e.padEdit b = some i → b < 15) :
    InvF { s with ed := ceTop fixed s.cfg e } := by
  have key : (ceTop fixed s.cfg e).kbEdit = e.kbEdit ∨ (ceTop fixed s.cfg e).kbEdit = s.cfg.kb := by
    unfold ceTop; dsimp only; split
    · exact Or.inr rfl
    · exact Or.inl rfl
  have key2 : (ceTop fixed s.cfg e).padEdit = e.padEdit ∨
      (ceTop fixed s.cfg e).padEdit = s.cfg.pad := by
    unfold ceTop; dsimp only; split
    · exact Or.inr rfl
    · exact Or.inl rfl
  refine ⟨h.cfg, h.disk, ?_, ?_, h.fe, h.core⟩
  · intro k i hk
    rcases key with k' | k'
    · exact he1 k i (by rw [← k']; exact hk)
    · exact h.cfg.1 k i (by rw [← k']; exact hk)
  · intro b i hb
    rcases key2 with k' | k'
    · exact he2 b i (by rw [← k']; exact hb)
    · exact h.cfg.2.1 b i (by rw [← k']; exact hb)

theorem invF_doApply {s : S} (h : InvF s) : InvF (doApply s) := by
  have hc : CfgGood (edStore s.ed s.cfg) := ⟨h.kbEdit, h.padEdit, h.cfg.2.2⟩
  exact { cfg := hc, disk := hc, kbEdit := h.kbEdit, padEdit := h.padEdit, fe := h.fe,
          core := h.core }

theorem invF_factory {s : S} (h : InvF s) : InvF (factoryReset fixed s) := by
  have hf : CfgGood (factoryCfg fixed s.cfg) :=
    ⟨cfgGood_defaults.1, cfgGood_defaults.2.1, h.cfg.2.2⟩
  have h1 : InvF { s with cfg := factoryCfg fixed s.cfg, ed := edLoad (factoryCfg fixed s.cfg) s.ed } :=
    { cfg := hf, disk := h.disk, kbEdit := hf.1, padEdit := hf.2.1, fe := h.fe, core := h.core }
  have h4 := invF_applySpeed (invF_applyInterp (invF_applyVolume (invF_applyColor (invF_doApply h1))))
  unfold factoryReset
  exact { h4 with }

theorem captureKey_good (e : Ed) (k : Key)
    (he : ∀ k i, e.kbEdit k = some i → KbOk k = true) :
    ∀ k' i, (captureKey fixed e k).kbEdit k' = some i → KbOk k' = true := by
  intro k' i hk
  unfold captureKey at hk
  split at hk
  · exact he k' i hk
  · simp only [fixed, Bool.true_and] at hk
    split at hk
    · exact he k' i hk
    · rename_i hno
      simp only at hk
      split at hk
      · rename_i hkk; subst hkk
        simp only [KbOk]
        revert hno; cases k'.named <;> cases k'.reserved <;> simp
      · split at hk
        · cases hk
        · exact he k' i hk

theorem capturePad_good (e : Ed) (b : Nat)
    (he : ∀ b i, e.padEdit b = some i → b < 15) :
    ∀ b' i, (capturePad e b).padEdit b' = some i → b' < 15 := by
  intro b' i hb
  unfold capturePad at hb
  split at hb
  · exact he b' i hb
  · rename_i hlt
    split at hb
    · exact he b' i hb
    · simp only at hb
      split at hb
      · rename_i hbb; subst hbb; omega
      · split at hb
        · cases hb
        · exact he b' i hb

theorem captureKey_padEdit (fx : Fix) (e : Ed) (k : Key) :
    (captureKey fx e k).padEdit = e.padEdit := by
  unfold captureKey; split
  · rfl
  · split <;> rfl

theorem capturePad_kbEdit (e : Ed) (b : Nat) : (capturePad e b).kbEdit = e.kbEdit := by
  unfold capturePad; split
  · rfl
  · split <;> rfl

theorem invF_onKey {s : S} (h : InvF s) (k : Key) (d : Bool) : InvF (onKey fixed s k d) := by
  obtain ⟨b, hb⟩ : ∃ b : Bool,
      (onKey fixed s k d).ed = if b then captureKey fixed s.ed k else s.ed := ⟨_, rfl⟩
  refine ⟨h.cfg, h.disk, ?_, ?_, h.fe, h.core⟩
  · rw [hb]; cases b
    · exact h.kbEdit
    · exact captureKey_good s.ed k h.kbEdit
  · rw [hb]; cases b
    · exact h.padEdit
    · simp only [ite_true]; rw [captureKey_padEdit]; exact h.padEdit

theorem invF_onPad {s : S} (h : InvF s) (b : Nat) (d : Bool) : InvF (onPad fixed s b d) := by
  obtain ⟨c, hc⟩ : ∃ c : Bool,
      (onPad fixed s b d).ed = if c then capturePad s.ed b else s.ed := ⟨_, rfl⟩
  refine ⟨h.cfg, h.disk, ?_, ?_, h.fe, h.core⟩
  · rw [hc]; cases c
    · exact h.kbEdit
    · simp only [ite_true]; rw [capturePad_kbEdit]; exact h.kbEdit
  · rw [hc]; cases c
    · exact h.padEdit
    · exact capturePad_good s.ed b h.padEdit

theorem shown_rom {f : FileE} (h : shown .rom f = true) : f ≠ .biosBin := by
  cases f <;> simp_all [shown]

theorem invF_stepO {s t : S} (h : InvF s) (e : Ev) (he : stepO fixed s e = some t) : InvF t := by
  have same : InvF s → ∀ {t : S}, t.cfg = s.cfg → t.disk = s.disk → t.ed.kbEdit = s.ed.kbEdit →
      t.ed.padEdit = s.ed.padEdit → t.fe = s.fe → t.core = s.core → InvF t :=
    fun h _ h1 h2 h3 h4 h5 h6 => invF_same h h1 h2 h3 h4 h5 h6
  cases e with
  | restart a => simp only [stepO] at he; cases he; exact invF_launch _ _ _ h.disk
  | corruptFile =>
    simp only [stepO] at he; cases he; exact ⟨h.cfg, trivial, h.kbEdit, h.padEdit, h.fe, h.core⟩
  | renderTop =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_ceTop' h _ h.kbEdit h.padEdit rfl rfl rfl rfl rfl
  | menuSettings =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_ceTop' h { s.ed with isOpen := true } h.kbEdit h.padEdit rfl rfl rfl rfl rfl
  | key k d => simp only [stepO] at he; split at he <;> cases he; exact invF_onKey h k d
  | padBtn b d => simp only [stepO] at he; split at he <;> cases he; exact invF_onPad h b d
  | drop f =>
    simp only [stepO] at he; split at he <;> cases he
    rename_i hc
    exact invF_loadRom h f (by simp at hc; exact hc.2)
  | menuSpeed =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_save (invF_applySpeed (invF_mk' h h.cfg h.disk rfl rfl h.fe rfl))
  | menuInterp =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_save (invF_applyInterp (invF_mk' h h.cfg h.disk rfl rfl h.fe rfl))
  | menuColor =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_save (invF_applyColor (invF_mk' h h.cfg h.disk rfl rfl h.fe rfl))
  | menuVolume v =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_save (invF_applyVolume (invF_mk' h h.cfg h.disk rfl rfl h.fe rfl))
  | menuRewind =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_save (invF_mk' h h.cfg h.disk rfl rfl h.fe rfl)
  | menuClearRecent =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_save (invF_mk' h ⟨h.cfg.1, h.cfg.2.1, by simp⟩ h.disk rfl rfl h.fe rfl)
  | menuOpenRom =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_mk' h h.cfg h.disk rfl rfl (by simp [FeGood, fixed]) rfl
  | menuReset =>
    simp only [stepO] at he; split at he <;> cases he
    split
    · rename_i f hf
      exact invF_loadRom h f (fun hb => h.cfg.2.2 (hb ▸ hf))
    · exact same h rfl rfl rfl rfl rfl rfl
  | kbPresetDefault =>
    simp only [stepO] at he; split at he <;> cases he
    exact ⟨h.cfg, h.disk, cfgGood_defaults.1, h.padEdit, h.fe, h.core⟩
  | biosBrowse =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_mk' h h.cfg h.disk rfl rfl (by simp [FeGood]) rfl
  | apply =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_doApply h
  | ok =>
    simp only [stepO] at he; split at he <;> cases he
    have h' := invF_doApply h
    exact invF_mk' h' h'.cfg h'.disk rfl rfl h'.fe rfl
  | revert =>
    simp only [stepO] at he; split at he <;> cases he
    exact ⟨h.cfg, h.disk, h.cfg.1, h.cfg.2.1, h.fe, h.core⟩
  | resetConfirm =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_factory h
  | feSelect f =>
    simp only [stepO] at he; split at he <;> cases he
    rename_i hc
    refine invF_mk' h h.cfg h.disk rfl rfl ?_ rfl
    intro hd
    simp only [Bool.and_eq_true] at hc
    have := shown_rom (hd ▸ hc.2)
    simpa using this
  | feNavigate =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_save (invF_mk' h h.cfg h.disk rfl rfl (by simp [FeGood]) rfl)
  | feOpen =>
    simp only [stepO] at he; split at he <;> cases he
    split
    · exact same h rfl rfl rfl rfl rfl rfl
    · rename_i f hsel
      split
      · rename_i hd
        refine invF_loadRom (s := { s with fe := { s.fe with dlg := .none } })
          (invF_mk' h h.cfg h.disk rfl rfl (by simp [FeGood]) rfl) f ?_
        intro hb; exact h.fe hd (hb ▸ hsel)
      · exact invF_mk' h h.cfg h.disk rfl rfl (by simp [FeGood]) rfl
  | feCancel =>
    simp only [stepO] at he; split at he <;> cases he
    exact invF_mk' h h.cfg h.disk rfl rfl (by simp [FeGood]) rfl
  | _ =>
    simp only [stepO] at he; split at he <;> cases he
    exact same h rfl rfl rfl rfl rfl rfl

theorem invF_reachable : ∀ s, Reachable fixed s → InvF s :=
  reachable_induct fixed invF_init fun _ _ e h he => invF_stepO h e he

/-- (b), fixed: whatever a user binds, save then load gives it back (the
file round trip is the identity on every reachable cfg). -/
theorem fixed_roundtrip (s : S) (hs : Reachable fixed s) : loadDisk (.ok s.cfg) = s.cfg := by
  have h := (invF_reachable s hs).cfg
  exact persist_id_of_named s.cfg (fun k i hk => by
    have := h.1 k i hk; simp only [KbOk, Bool.and_eq_true] at this; exact this.1) h.2.1

/-- (c), fixed: with no capture, no ImGui modal and no modifier held, every
bound key reaches the game as its input. -/
theorem fixed_bound_key_reaches_game (s : S) (hs : Reachable fixed s) (k : Key) (i : Inp)
    (hk : s.cfg.kb k = some i) (hw : s.wck = false) (hc : wantsKb fixed s = false)
    (hcore : s.core.isSome = true) : keyRoute fixed s k false = .game i := by
  have hok := (invF_reachable s hs).cfg.1 k i hk
  cases hco : s.core with
  | none => simp [hco] at hcore
  | some c =>
    cases k <;> simp_all [keyRoute, KbOk, Key.named, Key.reserved]

/-- (a), fixed: every GBA core has something to answer its BIOS calls, and
boots the intro only from a real image. -/
theorem fixed_bios (s : S) (hs : Reachable fixed s) (c : Core) (hc : s.core = some c) :
    c.kind = .gb ∨ ((c.hle || c.afterBios || c.biosFile) = true ∧ (!c.runBios || c.biosFile) = true) :=
  ((invF_reachable s hs).core c hc).2

/-- The explorer, fixed: nothing but a ROM is ever loaded as one. -/
theorem fixed_never_loads_bios_as_rom (s : S) (hs : Reachable fixed s) (c : Core)
    (hc : s.core = some c) : c.kind ≠ .junk :=
  ((invF_reachable s hs).core c hc).1

/-- (d), fixed: Reset to Defaults restores every modelled setting (and keeps
the BIOS path and the recents, as its popup says). -/
theorem fixed_reset_is_defaults (c : Cfg) :
    let r := factoryCfg fixed c
    r.kb = defaults.kb ∧ r.pad = defaults.pad ∧ r.useHle = defaults.useHle ∧
    r.afterBios = defaults.afterBios ∧ r.runBios = defaults.runBios ∧
    r.gbFifo = defaults.gbFifo ∧ r.sgb = defaults.sgb ∧ r.volume = defaults.volume ∧
    r.color = defaults.color ∧ r.interp = defaults.interp ∧ r.speed = defaults.speed ∧
    r.rewind = defaults.rewind ∧ r.biosFile = c.biosFile ∧ r.recent = c.recent :=
  ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- The same statement for the code as it is fails exactly on those two. -/
theorem real_reset_keeps (c : Cfg) :
    (factoryCfg real c).interp = c.interp ∧ (factoryCfg real c).speed = c.speed :=
  ⟨rfl, rfl⟩

end DesktopState.Settings
