-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models src/dingbat.nim: handle_input emu_pad_input push_held_input apply_trigger new_core_takes_held_input update_rumble render_imgui show_menu_bar update_fps_title load_rom process_pending_state main
-- @models src/dingbat/frontend/held_input.nim: held take_changes core_replaced bindable_key route_key pad_added pad_removed pad_button pad_stick pad_trigger trigger_held apply_trigger
-- @models src/dingbat/frontend/keybindings_widget.nim: wants_input key_released apply reset
-- @models src/dingbat/frontend/controller_widget.nim: wants_input button_released
-- @models src/dingbat/frontend/config_editor.nim: capturing_keys capturing_buttons render do_apply do_reset

/-
# Run/pause state and the input path of the desktop app (src/dingbat.nim)

Written against a2e038f82. Line numbers are src/dingbat.nim at a2e038f82
unless marked; Part 1 is the code as it was then. Part 2's fix shipped
(src/dingbat/frontend/held_input.nim).

## The loop

`main` (2107) runs one `while app.running` loop whose phases run in a fixed
order, and `pc` is the phase:

* `emu`     -- 2430-2486: `stepping = paused and pending_step`, `pending_step = false`;
               if `rewinding` (and no link) pop a rewind snapshot, else run one frame if
               `not paused or stepping` and (`stepping` or the pacing gate says due);
               a linked GBA goes through `netlink.step_frame()`; push rewind history.
               Then `process_pending_state()` (2522-2523): Quick Save.
* `input`   -- `handle_input()` (2546) drains every queued SDL event; any number of
               them, in any order the user produces.
* `post`    -- `update_rumble()` (2547), `update_link_auto()`, `service_link_setup()`
               (which may complete `finish_link`, 1826).
* `present` -- the present gate (2556); `render_imgui()` (2584), whose skip
               condition (1271-1283) returns before `igNewFrame`.
* `ui`      -- menu clicks and widget callbacks, which run inside `render_imgui`.
* `title`   -- `update_fps_title` (2602); loop back to `emu`.

User input is injected only where the code receives it: SDL events in `input`,
ImGui clicks in `ui` (reached only when the present ran and ImGui was not
skipped).

## What is abstracted, and why the properties survive it

* One GBA game is always loaded (`emu_kind = ekGBA`). The home screen has no
  core; the GB core's handler is the same code (1695-1707) except that Tab is
  not link-gated, and there is no GB link.
* Keys: the ones the properties need, with the default bindings (config.nim
  210-223): Z = A, S = R, Right = RIGHT; Grave = rewind; Tab / Shift+Tab; Cmd
  (Ctrl off macOS, MOD_KEY_MASK 39/42) with P / N / S = Pause / Frame Advance /
  Quick Save. Other shortcuts (R, L, F, Q, F9, F12, 1-6) only add behaviours.
  Inputs: A, R, RIGHT; the other seven behave like one of these.
* Pads: two pads, each with A, D-pad right, the left stick's right half and
  the right trigger. Controller bindings are the defaults (A -> A, DPAD_RIGHT ->
  RIGHT). `bound_button_held` reads SDL's live button state (`Phys`).
* `Phys` is the physical world as of the last SDL event handled. A key or button
  changes physically and its event is handled in the same `input` phase (SDL
  queues it in between, and nothing else reads it before `handle_input`), so an
  event's physical change and its handling are one model event.
* A KeyDown for a key already held is SDL's key repeat (`kev.repeat` is never
  read by handle_input).
* Focus loss (`focusLost`): SDL_SetKeyboardFocus(NULL) -> SDL_ResetKeyboard
  releases every held key in scancode order, each KeyUp carrying the modifier
  state at that moment (SDL 2.0.22 SDL_keyboard.c 562-574, 791): the modifier
  keys have the highest scancodes (224-231), so every other key is released
  while Cmd is still in `keysym.mod`.
* Pad removal: SDL_PrivateJoystickRemoved recentres the pad first (axes to
  zero, then buttons released, then hats; SDL_joystick.c 1302-1343) and then
  posts the removal, so the app sees those release events, then
  ControllerDeviceRemoved. SDL's own state is already at rest when the app
  handles them.
* `wck` is `io.WantCaptureKeyboard` as computed by the last `igNewFrame`
  (imgui.cpp 5515-5524: ActiveId != 0 or a modal open; keyboard navigation is
  not enabled). `imActive` is that condition now: `grab` is any ImGui press
  that holds ActiveId (a click held on a widget, a text field in Cheats / Link
  Cable / BIOS focused) or a modal (the state notice after a refused Quick
  Load, the file dialog). Closing a window is a click, which ends the grab.
  `mouseIdle` (the menu bar hiding after 3 s, 1215-1220) needs `wck = imActive`:
  three seconds of visible menu bar are many presents, so ImGui has caught up.
* `menuVis` = `show_menu_bar()`; `winOpen` = any other ImGui surface in the
  skip condition (overlay, debug windows, cheats, save states, link window,
  file dialog, state notice).
* Keybinding capture: `kbSel` = how many more releases `key_released` will
  take (the selection walks UP..R, 10 inputs, then becomes none); `kbVisible`
  = `keybindings.visible`, written only while Settings renders
  (config_editor.nim 99). Same for the controller tab (113). Rebinding
  (Apply of new bindings) is not modelled.
* The pacing gate (`scheduler_frame_due`, `gba_frame_due`) is the parameter
  `due`: it only decides whether a frame runs in this iteration, never how
  many; the rewind pop cadence (33 ms) is the same parameter.
* The link: `linkUp` is `finish_link` completing in `service_link_setup`
  (post phase) or the CLI; `linkLost` is `teardown_netlink` (step_frame error or
  peer BYE in `emu`, or Disconnect in the Link Cable window in `ui`).
* Counters (`frames`, `ranPaused`, `stepReqs`, `quickSaves`, `pops`, ...) are
  ghost state for stating the properties.

The fields `gz gs gright st1 st2 trigFF trigTurbo` belong to the fixed model
(Part 2) only; the code as written never sets them.

## Results

* (a) The core holds a button iff a physical source holds it: **broken** both
  ways. Stuck: a release eaten by the Cmd branch (also on Cmd+Tab), by
  WantCaptureKeyboard, or by a binding capture, which stays on after Settings
  is closed with its X. Dropped: keyboard, pads and the stick share each bit with
  no merge, the last pad's unplug releases the keyboard's keys, and a reset
  forgets held keys. `fix_no_stuck` / `fix_pads_seen` prove the fix.
* (b) Rewind only while Grave is held: **broken** the same ways
  (`bug_rewind_sticks_*`); then the game stays frozen. `fix_rewind_only_while_held`.
* (c) Frame advance runs one frame per request, only while paused: **kept**
  (`paused_frames_are_requested`); but the menu item and a link that starts
  after the request let that frame run through the link.
* (d) The menu shows what runs: the Fast Forward check mark always does (both
  read `apu.sync`); the 2x check mark does not once the trigger engages over 2x
  (`bug_trigger_with_2x_checks_both`); Tab's key repeat flips it. `fix_radio`.
* (e) Pause means no core frames: **kept** for frames (`paused_frames_are_requested`);
  rewind still applies snapshots while paused (`obs_rewind_while_paused`), and
  a paused linked side freezes its peer's whole app for up to 30 s
  (`obs_pause_while_linked`). Rewind is never active while linked
  (`no_rewind_while_linked`); rumble stops with pause at the next
  update_rumble (`no_rumble_while_paused`).
* Part 3: while render_imgui is skipped ImGui's input queue grows without
  bound, and a menu click then waits 2n frames behind n queued taps
  (`Backlog.click_waits`). Fixed: the skip drops the queue
  (`Backlog.regress_click_after_skip`).
-/
namespace DesktopState.RunInput

/-- Keys, in SDL scancode order: the order SDL_ResetKeyboard releases them. -/
inductive Key where
  | n | p | s | z | tab | bq | right | shift | cmd
  deriving DecidableEq, Repr

inductive Phase where
  | emu | input | post | present | ui | title
  deriving DecidableEq, Repr

/-- The physical world, as of the last SDL event handled. -/
structure Phys where
  kn : Bool      -- N held
  kp : Bool      -- P held
  ks : Bool      -- S held (bound to R)
  kz : Bool      -- Z held (bound to A)
  ktab : Bool    -- Tab held
  kbq : Bool     -- Grave (backquote) held: the rewind key
  kright : Bool  -- Right arrow held (bound to RIGHT)
  kshift : Bool  -- Shift held
  kcmd : Bool    -- Cmd (macOS) / Ctrl held: MOD_KEY_MASK
  pad1 : Bool    -- pad 1 open, in `controllers` (1561)
  pad2 : Bool
  p1a : Bool     -- pad 1 A (DEFAULT_CONTROLLER_MAPPING -> A)
  p1r : Bool     -- pad 1 D-pad right (-> RIGHT)
  p1st : Bool    -- pad 1 left stick past +STICK_DEADZONE on X
  p1tr : Bool    -- pad 1 right trigger past TRIGGER_THRESHOLD
  p2a : Bool
  p2r : Bool
  p2st : Bool
  p2tr : Bool

namespace Phys
def key (ph : Phys) : Key → Bool
  | .n => ph.kn | .p => ph.kp | .s => ph.ks | .z => ph.kz | .tab => ph.ktab
  | .bq => ph.kbq | .right => ph.kright | .shift => ph.kshift | .cmd => ph.kcmd
def setKey (ph : Phys) (k : Key) (d : Bool) : Phys :=
  match k with
  | .n => { ph with kn := d } | .p => { ph with kp := d } | .s => { ph with ks := d }
  | .z => { ph with kz := d } | .tab => { ph with ktab := d } | .bq => { ph with kbq := d }
  | .right => { ph with kright := d } | .shift => { ph with kshift := d }
  | .cmd => { ph with kcmd := d }
/-- `p = true` is pad 1. -/
def conn (ph : Phys) (p : Bool) : Bool := if p then ph.pad1 else ph.pad2
def setConn (ph : Phys) (p b : Bool) : Phys :=
  if p then { ph with pad1 := b } else { ph with pad2 := b }
def btn (ph : Phys) (p dpad : Bool) : Bool :=
  if p then (if dpad then ph.p1r else ph.p1a) else (if dpad then ph.p2r else ph.p2a)
def setBtn (ph : Phys) (p dpad d : Bool) : Phys :=
  if p then (if dpad then { ph with p1r := d } else { ph with p1a := d })
  else (if dpad then { ph with p2r := d } else { ph with p2a := d })
def stk (ph : Phys) (p : Bool) : Bool := if p then ph.p1st else ph.p2st
def setStk (ph : Phys) (p on : Bool) : Phys :=
  if p then { ph with p1st := on } else { ph with p2st := on }
def trg (ph : Phys) (p : Bool) : Bool := if p then ph.p1tr else ph.p2tr
def setTrg (ph : Phys) (p on : Bool) : Phys :=
  if p then { ph with p1tr := on } else { ph with p2tr := on }
/-- The pad at rest: SDL's recentred state, or a freshly opened pad. -/
def rest (ph : Phys) (p : Bool) : Phys :=
  if p then { ph with p1a := false, p1r := false, p1st := false, p1tr := false }
  else { ph with p2a := false, p2r := false, p2st := false, p2tr := false }
end Phys

/-- Some physical source holds A / R / RIGHT. -/
def physA (ph : Phys) : Bool := ph.kz || (ph.pad1 && ph.p1a) || (ph.pad2 && ph.p2a)
def physR (ph : Phys) : Bool := ph.ks
def physRight (ph : Phys) : Bool :=
  ph.kright || (ph.pad1 && (ph.p1r || ph.p1st)) || (ph.pad2 && (ph.p2r || ph.p2st))

structure App where
  cA : Bool           -- the core sees A held: keypad.keyinput.a == 0 (keypad.nim 62-74)
  cR : Bool           -- ... R
  cRight : Bool       -- ... RIGHT
  stickR : Bool       -- stick_dirs[RIGHT] (1567): one array for every pad
  padFF : Bool        -- pad_ff_held (1568): one flag for every pad
  sync : Bool         -- gba_emu.apu.sync ("Fast Forward" is checked iff not sync)
  turbo : Bool        -- gba_emu.apu.turbo ("2x Speed")
  paused : Bool       -- app.paused
  pendingStep : Bool  -- app.pending_step
  pendingSave : Bool  -- app.pending_save
  rewinding : Bool    -- app.rewinding
  linked : Bool       -- app.netlink != nil
  hist : Nat          -- snapshots in app.rewind
  frames : Nat        -- ghost: core frames run (run_until_frame / step_frame)
  ranPaused : Nat     -- ghost: of those, run with app.paused
  ranPausedLinked : Nat -- ghost: of those, run paused through the link
  stepReqs : Nat      -- ghost: frame-advance requests accepted (pending_step := true)
  quickSaves : Nat    -- ghost: slot-0 saves by process_pending_state
  pops : Nat          -- ghost: rewind snapshots applied
  popsPaused : Nat    -- ghost: of those, applied with app.paused
  rumble : Bool       -- rumble_on (471)
  wck : Bool          -- io.WantCaptureKeyboard, from the last igNewFrame
  imActive : Bool     -- ImGui ActiveId != 0 or a modal popup open (what the next NewFrame reads)
  menuVis : Bool      -- show_menu_bar() (1215)
  winOpen : Bool      -- another ImGui surface in the skip condition is open
  settingsOpen : Bool -- app.ce.open
  kbTab : Bool        -- the Settings tab bar shows Keybindings (else Controller)
  kbVisible : Bool    -- app.ce.keybindings.visible
  ctlVisible : Bool   -- app.ce.controller.visible
  kbSel : Nat         -- key_released calls left before keybindings.selection is none
  ctlSel : Nat        -- button_released calls left before controller.selection is none
  gz : Bool           -- fix only: Z's press reached the game
  gs : Bool           -- fix only: S's press reached the game
  gright : Bool       -- fix only: Right's press reached the game
  st1 : Bool          -- fix only: pad 1's stick holds RIGHT
  st2 : Bool          -- fix only: pad 2's stick holds RIGHT
  trigFF : Bool       -- fix only: the trigger's pull turned fast forward on
  trigTurbo : Bool    -- fix only: 2x Speed before that pull
  pc : Phase

structure State where
  ph : Phys
  a : App

def init : State :=
  { ph := { kn := false, kp := false, ks := false, kz := false, ktab := false, kbq := false,
            kright := false, kshift := false, kcmd := false, pad1 := false, pad2 := false,
            p1a := false, p1r := false, p1st := false, p1tr := false,
            p2a := false, p2r := false, p2st := false, p2tr := false },
    a := { cA := false, cR := false, cRight := false, stickR := false, padFF := false,
           sync := true, turbo := false, paused := false, pendingStep := false,
           pendingSave := false, rewinding := false, linked := false, hist := 0,
           frames := 0, ranPaused := 0, ranPausedLinked := 0, stepReqs := 0, quickSaves := 0,
           pops := 0, popsPaused := 0, rumble := false, wck := false, imActive := false,
           menuVis := false, winOpen := false, settingsOpen := false, kbTab := true,
           kbVisible := false, ctlVisible := false, kbSel := 0, ctlSel := 0,
           gz := false, gs := false, gright := false, st1 := false, st2 := false,
           trigFF := false, trigTurbo := false, pc := .emu } }

inductive Ev where
  | emulate (due : Bool)          -- emu: the frame / rewind-pop phase, then process_pending_state
  | linkLost                      -- teardown_netlink (2464/2467), or Disconnect (ui)
  | key (k : Key) (down : Bool)   -- input: an SDL KeyDown (a repeat if held) / KeyUp
  | focusLost                     -- input: the window loses keyboard focus (Cmd+Tab ...)
  | padBtn (p dpad down : Bool)   -- input: ControllerButtonDown/Up
  | stick (p on : Bool)           -- input: ControllerAxisMotion on LEFTX (on = past the deadzone)
  | trig (p on : Bool)            -- input: ControllerAxisMotion on TRIGGERRIGHT
  | padAdd (p : Bool)             -- input: ControllerDeviceAdded
  | padRemove (p : Bool)          -- input: unplug: SDL's recentring events, then ControllerDeviceRemoved
  | mouseMove                     -- input: MouseMotion (1758): the menu bar shows
  | mouseIdle                     -- the menu bar hides (3 s idle, or the mouse leaves)
  | drop                          -- input: DropFile of a ROM -> load_rom (1761-1766)
  | drained                       -- input: the SDL queue is empty
  | linkUp                        -- post: service_link_setup -> finish_link (1826-1846)
  | post (motor : Bool)           -- post: update_rumble (motor = the cart's rumble motor)
  | present (due : Bool)          -- present: the present gate (2556), then render_imgui
  | menuPause | menuStep | menuFF | menu2x | menuReset   -- ui: Emulation menu (1328-1371)
  | grab | ungrab                 -- ui: ImGui takes / drops ActiveId (or a modal opens / closes)
  | openSettings | closeSettingsX | settingsOK | switchTab
  | pickKey (n : Nat)             -- ui: a Keybindings button: selection = that input
  | pickBtn (n : Nat)             -- ui: a Controller button
  | openWin | closeWin
  | uiDone                        -- ui: render_imgui returns
  | title (sec : Bool)            -- title: update_fps_title; back to emu
  deriving DecidableEq, Repr

/-! ## Part 1: the code as written -/

/-- The KeyDown/KeyUp arm of handle_input (1634-1690), given the modifier state
the event carries. -/
def keyA (a : App) (cmd shift : Bool) (k : Key) (down : Bool) : App :=
  if a.wck then a                                                     -- 1640: `continue`
  else if a.kbVisible && decide (a.kbSel > 0) then                    -- 1642-1643
    if down then a else { a with kbSel := a.kbSel - 1 }               -- key_released
  else if cmd then                                                    -- 1644-1667: on RELEASE
    if down then a else
    match k with
    | .p => { a with paused := !a.paused }                            -- 1649-1650
    | .n => if a.paused && !a.linked then                             -- 1651-1654
              { a with pendingStep := true, stepReqs := a.stepReqs + 1 } else a
    | .s => { a with pendingSave := true }                            -- 1655-1656
    | _ => a
  else
    match k with
    | .bq => { a with rewinding := down && !a.linked }                -- 1674-1677
    | .z => { a with cA := down }                                     -- 1679-1680
    | .s => { a with cR := down }
    | .right => { a with cRight := down }
    | .tab =>                                                         -- 1681-1690
      if down && !a.linked then
        if shift then
          { a with turbo := !a.turbo, sync := if !a.turbo then true else a.sync }
        else
          { a with sync := !a.sync, turbo := if !a.sync then a.turbo else false }
      else a
    | _ => a

/-- One SDL key event: the physical change, then handle_input with the
modifier state SDL puts in `keysym.mod` (the Cmd key's own KeyDown carries
Cmd; its KeyUp does not). -/
def keyStep (s : State) (k : Key) (d : Bool) : State :=
  let ph := s.ph.setKey k d
  { ph := ph, a := keyA s.a ph.kcmd ph.kshift k d }

/-- SDL_ResetKeyboard's release order. -/
def resetOrder : List Key := [.n, .p, .s, .z, .tab, .bq, .right, .shift, .cmd]

/-- Focus loss: a KeyUp for every held key, in scancode order. -/
def resetWith (f : State → Key → Bool → State) (s : State) : State :=
  resetOrder.foldl (fun s k => if s.ph.key k then f s k false else s) s

/-- bound_button_held(RIGHT) (1578-1583): any open pad's button bound to RIGHT. -/
def padHeldR (ph : Phys) : Bool := (ph.pad1 && ph.p1r) || (ph.pad2 && ph.p2r)

/-- The ControllerButtonDown/Up arm (1729-1738). -/
def padBtnA (a : App) (dpad down : Bool) : App :=
  if a.ctlVisible && decide (a.ctlSel > 0) then                       -- 1732-1733
    if down then a else { a with ctlSel := a.ctlSel - 1 }
  else if dpad then                                                   -- 1736-1738
    if down || !a.stickR then { a with cRight := down } else a
  else { a with cA := down }

/-- set_stick_dir(RIGHT, on) (1585-1590). -/
def setStick (ph : Phys) (a : App) (on : Bool) : App :=
  if a.stickR == on then a
  else if !on && padHeldR ph then { a with stickR := on }
  else { a with stickR := on, cRight := on }

/-- set_fast_forward(held) (1592-1602). -/
def setFF (a : App) (held : Bool) : App :=
  if held == a.padFF then a else { a with padFF := held, sync := !held }

/-- Unplugging pad `p`: SDL recentres it (axes, then buttons, then the hat that
carries the D-pad), then ControllerDeviceRemoved (1717-1727). -/
def removeA (ph : Phys) (a : App) (p : Bool) : Phys × App :=
  let ph0 := ph.rest p
  let a := if ph.stk p then setStick ph0 a false else a
  let a := if ph.trg p then setFF a false else a
  let a := if ph.btn p false then padBtnA a false false else a
  let a := if ph.btn p true then padBtnA a true false else a
  let ph1 := ph0.setConn p false
  if !ph1.pad1 && !ph1.pad2 then                                      -- 1723-1727
    (ph1, setFF { a with stickR := false, cA := false, cR := false, cRight := false } false)
  else (ph1, a)

/-- load_rom (694-767): a fresh core (keypad all released, apu.sync on,
turbo off), rewind cleared and `rewinding = false` (744-745), `paused = false`,
pending save/load dropped (763-765). stick_dirs and pad_ff_held are kept. -/
def loadA (a : App) : App :=
  { a with cA := false, cR := false, cRight := false, sync := true, turbo := false,
           rewinding := false, paused := false, pendingSave := false, hist := 0 }

/-- The rewind branch (2432-2450): a snapshot applied every 33 ms (`due`). -/
def popA (a : App) (due : Bool) : App :=
  if due && decide (a.hist > 0) then
    { a with hist := a.hist - 1, pops := a.pops + 1,
             popsPaused := if a.paused then a.popsPaused + 1 else a.popsPaused }
  else a

/-- One core frame (2451-2476: run_until_frame, or step_frame when linked) and
the rewind push (2479-2486, not while linked). -/
def frameA (a : App) : App :=
  { a with frames := a.frames + 1,
           ranPaused := if a.paused then a.ranPaused + 1 else a.ranPaused,
           ranPausedLinked :=
             if a.paused && a.linked then a.ranPausedLinked + 1 else a.ranPausedLinked,
           hist := if a.linked then a.hist else a.hist + 1 }

/-- process_pending_state's Quick Save (2522-2523, 929-933). -/
def pendingA (a : App) : App :=
  if a.pendingSave then { a with pendingSave := false, quickSaves := a.quickSaves + 1 } else a

/-- The emulate phase (2430-2486), then process_pending_state. -/
def emulateA (a : App) (due : Bool) : App :=
  let stepping := a.paused && a.pendingStep                           -- 2430
  let a' := { a with pendingStep := false }                           -- 2431
  let a'' :=
    if a'.rewinding && !a'.linked then popA a' due                    -- 2432
    else if (!a'.paused || stepping) && (stepping || due) then frameA a'  -- 2451, 2454
    else a'
  { pendingA a'' with pc := .input }

/-- render_imgui's skip condition (1271-1283). -/
def skip (a : App) : Bool :=
  !a.paused && !a.rewinding && !a.menuVis && !a.settingsOpen && !a.winOpen

/-- The present phase: no present, or render_imgui returning early (no
igNewFrame), or igNewFrame (WantCaptureKeyboard recomputed) and the Settings
window's tab bar writing `visible` (config_editor.nim 99, 113). -/
def presentA (a : App) (due : Bool) : App :=
  if !due || skip a then { a with pc := .title }
  else { a with wck := a.imActive,
                kbVisible := if a.settingsOpen then a.kbTab else a.kbVisible,
                ctlVisible := if a.settingsOpen then !a.kbTab else a.ctlVisible,
                pc := .ui }

/-- The "Fast Forward" item (1356-1360): checked = not sync; a click flips it. -/
def menuFFA (a : App) : App :=
  let ff := a.sync
  { a with sync := !ff, turbo := if ff then false else a.turbo }

/-- The "2x Speed" item (1353-1355). -/
def menu2xA (a : App) : App :=
  { a with turbo := !a.turbo, sync := if !a.turbo then true else a.sync }

def step (s : State) : Ev → State
  | .emulate due => { s with a := emulateA s.a due }
  | .linkLost => { s with a := { s.a with linked := false } }
  | .key k d => keyStep s k d
  | .focusLost => resetWith keyStep s
  | .padBtn p dp d => { ph := s.ph.setBtn p dp d, a := padBtnA s.a dp d }
  | .stick p on => let ph := s.ph.setStk p on; { ph := ph, a := setStick ph s.a on }
  | .trig p on => { ph := s.ph.setTrg p on, a := setFF s.a on }
  | .padAdd p => { s with ph := (s.ph.rest p).setConn p true }      -- 1709-1715
  | .padRemove p => let r := removeA s.ph s.a p; { ph := r.1, a := r.2 }
  | .mouseMove => { s with a := { s.a with menuVis := true } }
  | .mouseIdle => { s with a := { s.a with menuVis := false } }
  | .drop => { s with a := loadA s.a }
  | .drained => { s with a := { s.a with pc := .post } }
  -- finish_link: rewind.clear(), rewinding = false (1836-1837)
  | .linkUp => { s with a := { s.a with linked := true, rewinding := false, hist := 0 } }
  -- update_rumble (1614): rumble_on = gb_rumble and not paused and motor_on
  | .post motor => { s with a := { s.a with rumble := motor && !s.a.paused, pc := .present } }
  | .present due => { s with a := presentA s.a due }
  | .menuPause => { s with a := { s.a with paused := !s.a.paused } }   -- 1330-1331 (BoolPtr)
  | .menuStep =>                                                        -- 1332-1334
    { s with a := { s.a with pendingStep := true, stepReqs := s.a.stepReqs + 1 } }
  | .menuFF => { s with a := menuFFA s.a }
  | .menu2x => { s with a := menu2xA s.a }
  | .menuReset => { s with a := loadA s.a }                             -- 1370-1371
  | .grab => { s with a := { s.a with imActive := true } }
  | .ungrab => { s with a := { s.a with imActive := false } }
  -- File > Settings (1319); do_reset on the open edge drops both selections (config_editor 78-79)
  | .openSettings => { s with a := { s.a with settingsOpen := true, kbSel := 0, ctlSel := 0 } }
  -- the title-bar X (config_editor 92): only `open`; `visible` and the selections stay
  | .closeSettingsX => { s with a := { s.a with settingsOpen := false, imActive := false } }
  -- OK (136-138): do_apply clears both selections (keybindings_widget apply)
  | .settingsOK =>
    { s with a := { s.a with settingsOpen := false, imActive := false, kbSel := 0, ctlSel := 0 } }
  | .switchTab => { s with a := { s.a with kbTab := !s.a.kbTab } }
  | .pickKey n => { s with a := { s.a with kbSel := n } }
  | .pickBtn n => { s with a := { s.a with ctlSel := n } }
  | .openWin => { s with a := { s.a with winOpen := true } }
  | .closeWin => { s with a := { s.a with winOpen := false, imActive := false } }
  | .uiDone => { s with a := { s.a with pc := .title } }
  | .title _ => { s with a := { s.a with pc := .emu } }

/-- When the event can happen (the same for the code and for the fix). -/
def en (s : State) : Ev → Bool
  | .emulate _ => s.a.pc == .emu
  | .linkLost => s.a.linked && (s.a.pc == .emu || s.a.pc == .ui)
  | .key k d => s.a.pc == .input && (d || s.ph.key k)
  | .focusLost | .mouseMove | .drop | .drained => s.a.pc == .input
  | .mouseIdle => s.a.pc == .input && s.a.menuVis && s.a.wck == s.a.imActive
  | .padBtn p dp d => s.a.pc == .input && s.ph.conn p && s.ph.btn p dp != d
  | .stick p _ | .trig p _ | .padRemove p => s.a.pc == .input && s.ph.conn p
  | .padAdd p => s.a.pc == .input && !s.ph.conn p
  | .linkUp => s.a.pc == .post && !s.a.linked
  | .post _ => s.a.pc == .post
  | .present _ => s.a.pc == .present
  | .menuPause | .menuFF | .menu2x | .menuReset | .openSettings | .openWin =>
    s.a.pc == .ui && s.a.menuVis
  | .menuStep => s.a.pc == .ui && s.a.menuVis && s.a.paused   -- enabled iff paused (1333)
  | .grab => s.a.pc == .ui && (s.a.menuVis || s.a.settingsOpen || s.a.winOpen)
  | .ungrab => s.a.pc == .ui && s.a.imActive
  | .closeSettingsX | .settingsOK | .switchTab => s.a.pc == .ui && s.a.settingsOpen
  | .pickKey n => s.a.pc == .ui && s.a.settingsOpen && s.a.kbVisible && decide (1 ≤ n ∧ n ≤ 10)
  | .pickBtn n => s.a.pc == .ui && s.a.settingsOpen && s.a.ctlVisible && decide (1 ≤ n ∧ n ≤ 10)
  | .closeWin => s.a.pc == .ui && s.a.winOpen
  | .uiDone => s.a.pc == .ui
  | .title _ => s.a.pc == .title

inductive Reach (stp : State → Ev → State) : State → Prop
  | init : Reach stp init
  | step {s e} : Reach stp s → en s e = true → Reach stp (stp s e)

def run (stp : State → Ev → State) (s : State) : List Ev → Option State
  | [] => some s
  | e :: es => if en s e then run stp (stp s e) es else none

theorem run_reach {stp : State → Ev → State} {s t : State} {es : List Ev}
    (hs : Reach stp s) (h : run stp s es = some t) : Reach stp t := by
  induction es generalizing s with
  | nil => simp [run] at h; exact h ▸ hs
  | cons e es ih =>
    simp only [run] at h
    split at h
    · exact ih (Reach.step hs (by assumption)) h
    · cases h

/-- A trace from `init`, enabled at every step, that ends in a `bad` state. -/
def witnesses (stp : State → Ev → State) (es : List Ev) (bad : State → Bool) : Bool :=
  match run stp init es with
  | some s => bad s
  | none => false

theorem witness_sound {stp : State → Ev → State} {es : List Ev} {bad : State → Bool}
    (h : witnesses stp es bad = true) : ∃ s, Reach stp s ∧ bad s = true := by
  unfold witnesses at h
  split at h
  · exact ⟨_, run_reach Reach.init (by assumption), h⟩
  · cases h

/-- The core holds an input that no physical source holds: a stuck button. -/
def stuck (s : State) : Bool :=
  (s.a.cA && !physA s.ph) || (s.a.cR && !physR s.ph) || (s.a.cRight && !physRight s.ph)

/-- Finish the loop iteration without a present, from `input` back to `input`. -/
def idle : List Ev := [.drained, .post false, .present false, .title false, .emulate true]
/-- From `input` to `ui`, rendering ImGui. -/
def render : List Ev := [.drained, .post false, .present true]
/-- From `ui` back to `input`. -/
def back : List Ev := [.uiDone, .title false, .emulate true]

/-! ### Counterexamples on the code as written -/

/-- **Hold a game key, press Cmd, let go of the key first: the button sticks.**
The KeyUp carries Cmd in `keysym.mod`, so it takes the shortcut branch (1644),
which acts on releases and has no case for Z; the core never hears Z go up. -/
theorem bug_cmd_held_release_sticks_button :
    witnesses step [.emulate true, .key .z true, .key .cmd true, .key .z false, .key .cmd false,
                    .drained]
      (fun s => stuck s && s.a.cA && !s.ph.kz) = true := by decide

/-- ...and when the key is also a shortcut letter, its release fires the
shortcut the user never chorded: with the default bindings S is the R button,
so holding R, touching Cmd and letting go of S first is Quick Save, which
overwrites slot 0 at the next frame boundary, and R stays held. -/
theorem bug_cmd_held_release_fires_quick_save :
    witnesses step ([.emulate true, .key .s true, .key .cmd true, .key .s false, .key .cmd false]
                    ++ idle)
      (fun s => s.a.quickSaves == 1 && s.a.cR && !s.ph.ks) = true := by decide

/-- **Cmd+Tab away while holding a direction and R.** SDL releases the held keys
on focus loss in scancode order, S (22) and Right (79) before Cmd (227), so each
KeyUp carries Cmd: RIGHT and R stay held in the core when the player comes back,
and slot 0 has been overwritten by a Quick Save. -/
theorem bug_cmd_tab_away_sticks_and_quick_saves :
    witnesses step ([.emulate true, .key .right true, .key .s true, .key .cmd true, .focusLost]
                    ++ idle)
      (fun s => s.a.cRight && s.a.cR && !s.ph.kright && !s.ph.ks && !s.ph.kcmd &&
                s.a.quickSaves == 1) = true := by decide

/-- **Rewind sticks on.** Grave released while Cmd is held (or on Cmd+Tab):
`rewinding` stays true with the key up, the history drains, and from then on
the emulate phase takes the rewind branch every iteration, so the game never
runs another frame (frames stays 1) until Grave is tapped again. -/
theorem bug_rewind_sticks_after_cmd :
    witnesses step ([.emulate true, .key .bq true, .key .cmd true, .key .bq false,
                     .key .cmd false] ++ idle ++ idle ++ idle)
      (fun s => s.a.rewinding && !s.ph.kbq && s.a.frames == 1 && s.a.hist == 0 &&
                !s.a.paused) = true := by decide

theorem bug_rewind_sticks_on_cmd_tab :
    witnesses step [.emulate true, .key .bq true, .key .cmd true, .focusLost, .drained]
      (fun s => s.a.rewinding && !s.ph.kbq) = true := by decide

/-- **ImGui takes the keyboard between a press and its release.** Hold Right,
then click into an ImGui text field (Cheats, Link Cable) or get the state
notice (File > Quick Load with slot 0 empty): the next igNewFrame sets
WantCaptureKeyboard, and the `continue` at 1640 drops Right's KeyUp. -/
theorem bug_imgui_capture_swallows_release :
    witnesses step ([.emulate true, .mouseMove, .key .right true] ++ render ++ [.grab] ++ back
                    ++ render ++ back ++ [.key .right false, .drained])
      (fun s => stuck s && s.a.cRight && !s.ph.kright) = true := by decide

/-- **A binding capture takes the release of a key the game saw pressed.** Hold
Z, click a Keybindings button: Z's KeyUp becomes the new binding (1642-1643)
and A stays held in the running game behind the Settings window. -/
theorem bug_binding_capture_swallows_release :
    witnesses step ([.emulate true, .mouseMove, .key .z true] ++ render ++ [.openSettings] ++ back
                    ++ render ++ [.pickKey 10] ++ back ++ [.key .z false, .drained])
      (fun s => stuck s && s.a.cA) = true := by decide

/-- **Closing Settings with the X mid-capture leaves the capture on.** The X only
clears `open`; `keybindings.visible` is written only while Settings renders
(config_editor.nim 99) and the selection is cleared only by Apply/OK or the
next open, so `wants_input()` stays true: every key goes to the invisible
capture and none to the game, until ten releases have walked the selection
off the end (the keyboard seems dead, Cmd shortcuts included). -/
theorem bug_closed_settings_keeps_capturing_keys :
    witnesses step ([.emulate true, .mouseMove] ++ render ++ [.openSettings] ++ back
                    ++ render ++ [.pickKey 10, .closeSettingsX] ++ back ++ [.mouseIdle] ++ idle
                    ++ [.key .z true])
      (fun s => !s.a.settingsOpen && s.ph.kz && !s.a.cA && !s.a.wck && s.a.kbSel == 10)
      = true := by decide

/-- The same for the controller tab: pad buttons go to an invisible capture. -/
theorem bug_closed_settings_keeps_capturing_buttons :
    witnesses step ([.emulate true, .mouseMove] ++ render ++ [.openSettings, .switchTab] ++ back
                    ++ render ++ [.pickBtn 10, .closeSettingsX] ++ back
                    ++ [.padAdd true, .padBtn true false true])
      (fun s => !s.a.settingsOpen && s.ph.p1a && !s.a.cA) = true := by decide

/-! #### Two sources for one button -/

/-- Keyboard and pad share one bit with no merge: hold Z and pad A, let go of
pad A: the core releases A while Z is still down. -/
theorem bug_pad_release_drops_held_key :
    witnesses step [.emulate true, .padAdd true, .key .z true, .padBtn true false true,
                    .padBtn true false false, .drained]
      (fun s => s.ph.kz && !s.a.cA) = true := by decide

/-- Two pads (every pad feeds player 1): pad 2's release drops pad 1's A. -/
theorem bug_two_pads_release_drops_other :
    witnesses step [.emulate true, .padAdd true, .padAdd false, .padBtn true false true,
                    .padBtn false false true, .padBtn false false false, .drained]
      (fun s => s.ph.p1a && !s.a.cA) = true := by decide

/-- `stick_dirs` is one array for all pads: any axis event from pad 2's idle
stick (drift inside the deadzone) releases the direction pad 1's stick holds. -/
theorem bug_other_pad_stick_drops_direction :
    witnesses step [.emulate true, .padAdd true, .padAdd false, .stick true true,
                    .stick false false, .drained]
      (fun s => s.ph.p1st && !s.a.cRight) = true := by decide

/-- Unplugging the last pad releases every input (1726), keyboard-held ones too. -/
theorem bug_unplug_releases_keyboard :
    witnesses step [.emulate true, .padAdd true, .key .z true, .padRemove true, .drained]
      (fun s => s.ph.kz && !s.a.cA) = true := by decide

/-- A reset or ROM load gives a fresh core with nothing held; a key held across
it is not seen until it is pressed again (and the stick not until it recentres,
`stick_dirs` being kept). -/
theorem bug_reset_drops_held_input :
    witnesses step ([.emulate true, .mouseMove, .key .right true] ++ render ++ [.menuReset])
      (fun s => s.ph.kright && !s.a.cRight) = true := by decide

/-! #### Fast forward -/

/-- The radio the menu comment promises (1348-1351: "enabling either clears the
other"): the trigger writes `sync` only, so 2x Speed and Fast Forward are both
checked; what runs is fast forward (gba_frame_due: `not sync` wins). -/
def bothChecked (s : State) : Bool := !s.a.sync && s.a.turbo

theorem bug_trigger_with_2x_checks_both :
    witnesses step [.emulate true, .padAdd true, .key .shift true, .key .tab true,
                    .trig true true, .drained] bothChecked = true := by decide

/-- Tab is a toggle and handle_input ignores `repeat`: holding Tab flips fast
forward at the key-repeat rate, so a hold ends in either state. -/
theorem bug_tab_repeat_flips_fast_forward :
    witnesses step [.emulate true, .key .tab true, .key .tab true, .drained]
      (fun s => s.ph.ktab && s.a.sync) = true := by decide

/-- A trigger pull and release turns off a fast forward that Tab latched on. -/
theorem obs_trigger_release_cancels_tab_ff :
    witnesses step [.emulate true, .padAdd true, .key .tab true, .key .tab false,
                    .trig true true, .trig true false, .drained]
      (fun s => s.a.sync && !s.a.padFF) = true := by decide

/-! #### The link -/

/-- Tab is suppressed while linked (1681: "would run ahead of the peer")... -/
theorem link_tab_suppressed :
    witnesses step ([.emulate true, .drained, .linkUp, .post false, .present false,
                     .title false, .emulate true, .key .tab true, .drained])
      (fun s => s.a.linked && s.a.sync) = true := by decide

/-- ...but the Emulation menu's Fast Forward and 2x Speed are not, and neither
is the trigger. -/
theorem bug_menu_ff_while_linked :
    witnesses step ([.emulate true, .mouseMove, .drained, .linkUp, .post false, .present true,
                     .menuFF])
      (fun s => s.a.linked && !s.a.sync) = true := by decide

theorem bug_trigger_ff_while_linked :
    witnesses step ([.emulate true, .padAdd true, .drained, .linkUp, .post false,
                     .present false, .title false, .emulate true, .trig true true])
      (fun s => s.a.linked && !s.a.sync) = true := by decide

/-- Frame advance is suppressed on Cmd+N while linked (1652), but the menu item
(enabled iff paused, 1333) is not: a paused frame runs through the link. -/
theorem bug_menu_frame_advance_while_linked :
    witnesses step ([.emulate true, .mouseMove, .drained, .linkUp, .post false, .present true,
                     .menuPause] ++ back ++ render ++ [.menuStep] ++ back)
      (fun s => s.a.linked && s.a.paused && s.a.ranPausedLinked == 1) = true := by decide

/-- The Cmd+N guard is checked when the key is released, not when the step
runs: a link completing in the same iteration (post phase) gets the frame. -/
theorem bug_step_request_outlives_link_start :
    witnesses step ([.emulate true, .key .cmd true, .key .p true, .key .p false, .key .n true,
                     .key .n false, .key .cmd false, .drained, .linkUp, .post false,
                     .present false, .title false, .emulate true])
      (fun s => s.a.linked && s.a.ranPausedLinked == 1) = true := by decide

/-- Pause is not suppressed while linked (Cmd+P, the menu): the peer's
`step_frame` then stalls inside its own main loop (netlink.nim 123-147), with
no events handled and nothing presented, for up to STALL_TIMEOUT_MS = 30 s,
and then drops the link. -/
theorem obs_pause_while_linked :
    witnesses step ([.emulate true, .drained, .linkUp, .post false, .present false,
                     .title false, .emulate true, .key .cmd true, .key .p true, .key .p false])
      (fun s => s.a.linked && s.a.paused) = true := by decide

/-! #### Pause, rewind, frame advance, rumble -/

/-- Rewind while paused applies snapshots (2432 does not look at `paused`): no
frame runs, but the paused game's state moves backward. -/
theorem obs_rewind_while_paused :
    witnesses step ([.emulate true, .key .cmd true, .key .p true, .key .p false, .key .cmd false,
                     .key .bq true] ++ idle)
      (fun s => s.a.paused && s.a.popsPaused == 1 && s.a.frames == 1) = true := by decide

/-- A frame-advance request made while Grave is held is consumed (2431) by the
rewind branch and never runs. -/
theorem obs_step_dropped_while_rewinding :
    witnesses step ([.emulate true, .key .cmd true, .key .p true, .key .p false, .key .n true,
                     .key .n false, .key .cmd false, .key .bq true] ++ idle)
      (fun s => s.a.paused && s.a.stepReqs == 1 && s.a.ranPaused == 0 && !s.a.pendingStep)
      = true := by decide

/-- Pause from the menu leaves the rumble on until the next update_rumble,
one loop iteration later (at most a few ms, plus the 80 ms effect). -/
theorem obs_menu_pause_rumble_lag :
    witnesses step ([.emulate true, .mouseMove, .drained, .post true, .present true, .menuPause])
      (fun s => s.a.rumble && s.a.paused) = true := by decide

/-! ### What the code does keep -/

/-- * `steps`: every frame run while paused was a frame-advance request, one frame
  per request (a request still pending counts as not yet spent).
* `rum`: right after update_rumble, the rumble is off while paused.
* `rwl`: rewind is never active while linked. -/
structure Inv (s : State) : Prop where
  steps : s.a.ranPaused + (if s.a.pendingStep then 1 else 0) ≤ s.a.stepReqs
  rum   : s.a.pc = .present → s.a.rumble = true → s.a.paused = false
  rwl   : s.a.rewinding = true → s.a.linked = false

theorem inv_init : Inv init := by
  constructor <;> simp [init]

theorem keyA_pc (a : App) (c sh : Bool) (k : Key) (d : Bool) : (keyA a c sh k d).pc = a.pc := by
  unfold keyA; (repeat' split) <;> rfl

theorem keyA_inv (a : App) (c sh : Bool) (k : Key) (d : Bool)
    (h1 : a.ranPaused + (if a.pendingStep then 1 else 0) ≤ a.stepReqs)
    (h3 : a.rewinding = true → a.linked = false) :
    (keyA a c sh k d).ranPaused + (if (keyA a c sh k d).pendingStep then 1 else 0)
      ≤ (keyA a c sh k d).stepReqs ∧
    ((keyA a c sh k d).rewinding = true → (keyA a c sh k d).linked = false) := by
  unfold keyA
  (repeat' split) <;> simp_all <;> split at h1 <;> omega

/-- A focus loss is a run of key releases: whatever each one keeps, all keep. -/
theorem resetWith_pres (f : State → Key → Bool → State) (P : State → Prop)
    (hf : ∀ s k, P s → s.ph.key k = true → P (f s k false)) (s : State) (hs : P s) :
    P (resetWith f s) := by
  unfold resetWith
  suffices ∀ (l : List Key) (s : State), P s →
      P (l.foldl (fun s k => if s.ph.key k then f s k false else s) s) from this _ _ hs
  intro l
  induction l with
  | nil => intro s hs; exact hs
  | cons k l ih =>
    intro s hs
    simp only [List.foldl]
    apply ih
    split
    · exact hf s k hs (by assumption)
    · exact hs

theorem keyStep_inv (s : State) (k : Key) (d : Bool) (h : Inv s ∧ s.a.pc = .input) :
    Inv (keyStep s k d) ∧ (keyStep s k d).a.pc = .input := by
  obtain ⟨⟨h1, _, h3⟩, hpc⟩ := h
  obtain ⟨g1, g3⟩ := keyA_inv s.a (s.ph.setKey k d).kcmd (s.ph.setKey k d).kshift k d h1 h3
  have hp : (keyStep s k d).a.pc = .input := by simp [keyStep, keyA_pc, hpc]
  refine ⟨⟨g1, ?_, g3⟩, hp⟩
  intro h; rw [hp] at h; cases h

@[simp] theorem popA_eq (a : App) (due : Bool) :
    (popA a due).ranPaused = a.ranPaused ∧ (popA a due).pendingStep = a.pendingStep ∧
    (popA a due).stepReqs = a.stepReqs ∧ (popA a due).rewinding = a.rewinding ∧
    (popA a due).linked = a.linked := by
  unfold popA; split <;> simp

theorem pendingA_eq (a : App) :
    (pendingA a).ranPaused = a.ranPaused ∧ (pendingA a).pendingStep = a.pendingStep ∧
    (pendingA a).stepReqs = a.stepReqs ∧ (pendingA a).rewinding = a.rewinding ∧
    (pendingA a).linked = a.linked := by
  unfold pendingA; split <;> simp

theorem emulateA_inv (a : App) (due : Bool)
    (h1 : a.ranPaused + (if a.pendingStep then 1 else 0) ≤ a.stepReqs)
    (h3 : a.rewinding = true → a.linked = false) :
    (emulateA a due).ranPaused + (if (emulateA a due).pendingStep then 1 else 0)
      ≤ (emulateA a due).stepReqs ∧
    ((emulateA a due).rewinding = true → (emulateA a due).linked = false) ∧
    (emulateA a due).pc = .input := by
  unfold emulateA
  simp only [pendingA_eq]
  split
  · simp_all; split at h1 <;> omega
  · split
    · rename_i _ hc
      simp only [frameA] at *
      cases hp : a.paused <;> cases hs : a.pendingStep <;> simp_all <;> omega
    · simp_all; split at h1 <;> omega

theorem padBtnA_eq (a : App) (dp d : Bool) :
    (padBtnA a dp d).ranPaused = a.ranPaused ∧ (padBtnA a dp d).pendingStep = a.pendingStep ∧
    (padBtnA a dp d).stepReqs = a.stepReqs ∧ (padBtnA a dp d).rewinding = a.rewinding ∧
    (padBtnA a dp d).linked = a.linked ∧ (padBtnA a dp d).pc = a.pc := by
  unfold padBtnA; (repeat' split) <;> simp

theorem setStick_eq (ph : Phys) (a : App) (on : Bool) :
    (setStick ph a on).ranPaused = a.ranPaused ∧ (setStick ph a on).pendingStep = a.pendingStep ∧
    (setStick ph a on).stepReqs = a.stepReqs ∧ (setStick ph a on).rewinding = a.rewinding ∧
    (setStick ph a on).linked = a.linked ∧ (setStick ph a on).pc = a.pc := by
  unfold setStick; (repeat' split) <;> simp

theorem setFF_eq (a : App) (held : Bool) :
    (setFF a held).ranPaused = a.ranPaused ∧ (setFF a held).pendingStep = a.pendingStep ∧
    (setFF a held).stepReqs = a.stepReqs ∧ (setFF a held).rewinding = a.rewinding ∧
    (setFF a held).linked = a.linked ∧ (setFF a held).pc = a.pc := by
  unfold setFF; (repeat' split) <;> simp

theorem removeA_eq (ph : Phys) (a : App) (p : Bool) :
    (removeA ph a p).2.ranPaused = a.ranPaused ∧
    (removeA ph a p).2.pendingStep = a.pendingStep ∧
    (removeA ph a p).2.stepReqs = a.stepReqs ∧ (removeA ph a p).2.rewinding = a.rewinding ∧
    (removeA ph a p).2.linked = a.linked ∧ (removeA ph a p).2.pc = a.pc := by
  unfold removeA
  simp only
  (repeat' split) <;>
    simp [setFF_eq, setStick_eq, padBtnA_eq]

theorem presentA_pc (a : App) (due : Bool) : (presentA a due).pc ≠ .present := by
  unfold presentA; split <;> simp

set_option maxHeartbeats 1000000 in
theorem inv_step {s : State} {e : Ev} (h : Inv s) (he : en s e = true) :
    Inv (step s e) := by
  have ⟨h1, h2, h3⟩ := h
  cases e with
  | emulate due =>
    obtain ⟨g1, g3, gp⟩ := emulateA_inv s.a due h1 h3
    refine ⟨g1, fun hp => ?_, g3⟩
    simp only [step] at hp; rw [gp] at hp; cases hp
  | key k d =>
    simp only [en, Bool.and_eq_true, beq_iff_eq] at he
    exact (keyStep_inv s k d ⟨h, he.1⟩).1
  | focusLost =>
    simp only [en, beq_iff_eq] at he
    exact (resetWith_pres keyStep (fun s => Inv s ∧ s.a.pc = .input)
      (fun s k hs _ => keyStep_inv s k false hs) s ⟨h, he⟩).1
  | padBtn p dp d =>
    simp only [en, Bool.and_eq_true, beq_iff_eq] at he
    obtain ⟨e1, e2, e3, e4, e5, e6⟩ := padBtnA_eq s.a dp d
    refine ⟨?_, ?_, ?_⟩ <;> simp only [step, e1, e2, e3, e4, e5, e6, he.1.1] <;> simp_all
  | stick p on =>
    simp only [en, Bool.and_eq_true, beq_iff_eq] at he
    obtain ⟨e1, e2, e3, e4, e5, e6⟩ := setStick_eq (s.ph.setStk p on) s.a on
    refine ⟨?_, ?_, ?_⟩ <;> simp only [step, e1, e2, e3, e4, e5, e6, he.1] <;> simp_all
  | trig p on =>
    simp only [en, Bool.and_eq_true, beq_iff_eq] at he
    obtain ⟨e1, e2, e3, e4, e5, e6⟩ := setFF_eq s.a on
    refine ⟨?_, ?_, ?_⟩ <;> simp only [step, e1, e2, e3, e4, e5, e6, he.1] <;> simp_all
  | padRemove p =>
    simp only [en, Bool.and_eq_true, beq_iff_eq] at he
    obtain ⟨e1, e2, e3, e4, e5, e6⟩ := removeA_eq s.ph s.a p
    refine ⟨?_, ?_, ?_⟩ <;> simp only [step, e1, e2, e3, e4, e5, e6, he.1] <;> simp_all
  | present due =>
    have hp := presentA_pc s.a due
    refine ⟨?_, fun h => absurd h hp, ?_⟩ <;> simp only [step, presentA] <;> split <;> simp_all
  | menuStep =>
    refine ⟨?_, ?_, ?_⟩ <;> simp only [step, en] at he ⊢ <;> simp_all <;> split at h1 <;> omega
  | _ =>
    refine ⟨?_, ?_, ?_⟩ <;>
      simp only [step, en, loadA, menuFFA, menu2xA, Bool.and_eq_true, beq_iff_eq] at he ⊢ <;>
      first | exact h1 | simp_all

/-- **Kept (c)/(e): pause means no core frame runs, except exactly one per
frame-advance request.** Rewind pops do run while paused (obs_rewind_while_paused). -/
theorem inv_reach {s : State} (h : Reach step s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step _ he ih => exact inv_step ih he

theorem paused_frames_are_requested {s : State} (h : Reach step s) :
    s.a.ranPaused ≤ s.a.stepReqs := by
  have := (inv_reach h).steps; split at this <;> omega

/-- **Kept: rewind is never active while linked** (1676, 1837). -/
theorem no_rewind_while_linked {s : State} (h : Reach step s) (hr : s.a.rewinding = true) :
    s.a.linked = false := (inv_reach h).rwl hr

/-- **Kept (with a one-iteration lag): after update_rumble, no rumble while paused.** -/
theorem no_rumble_while_paused {s : State} (h : Reach step s) (hp : s.a.pc = .present)
    (hr : s.a.rumble = true) : s.a.paused = false := (inv_reach h).rum hp hr

/-! ## Part 2: the fix, designed, proved, and shipped

What shipped (`src/dingbat/frontend/held_input.nim`, called from handle_input;
tests/desktop_input_test.nim replays these traces on it):

1. **Releases first, unfiltered.** `route_key` drops a released key from the
   held keys (keycode -> the input its press meant) and ends a rewind on
   Grave's release before it looks at WantCaptureKeyboard, a binding capture
   or the Cmd bit. A press reaches the game only past those filters.
2. **Shortcuts on the press.** The Cmd branch acts on a press that is not a
   key repeat, so letting go of a held game key while Cmd is down (or SDL's
   focus-loss release) fires nothing.
3. **One merge.** The keyboard's holds, each pad's button holds and each
   pad's stick directions are kept apart (per joystick instance id) and the
   core is told their union after every key/button/axis/hotplug event
   (`push_held_input`) and at the end of load_rom (`new_core_takes_held_input`,
   so a key held across a reset is seen). A removed pad takes only its own
   holds. A pad button feeds the merge even while the Controller capture is
   recording its release (`padBtnF`).
4. **Trigger fast forward** (`apply_trigger`) reads every open pad's
   trigger. It is momentary: a pull turns fast forward on and clears 2x (the
   menu's radio); its release restores the speed from before the pull, unless
   the speed was changed during the hold. A pull while fast forward is already
   on (Tab latched it) or while linked does nothing, nor does its release.
   load_rom re-applies a held trigger.
5. **Link gating** (the netlink fix round's, modelled here): the Fast Forward /
   2x Speed menu items check `app.netlink == nil` like Tab; `stepping` requires
   `app.netlink == nil`, which covers the Frame Advance item and a link that
   comes up between the request and the frame.
6. **A capture ends with Settings.** handle_input consults a capture only
   while `app.ce.open` (`capturing_keys` / `capturing_buttons`);
   ConfigEditor.render clears both `visible` flags every frame before the tab
   bar sets them (so a collapsed window captures nothing), and drops both
   selections in the frame the window is closed.
7. Tab (and the other toggles) ignore key repeats.

`stepF` is `step` with these changes; the core's bits are recomputed by
`coreOf` after every event. -/

/-- 1: a release updates the held state before any filter. -/
def relF (a : App) : Key → App
  | .z => { a with gz := false }
  | .s => { a with gs := false }
  | .right => { a with gright := false }
  | .bq => { a with rewinding := false }
  | _ => a

/-- 2: the Cmd shortcuts, on the press. -/
def shortcutF (a : App) : Key → App
  | .p => { a with paused := !a.paused }
  | .n => if a.paused && !a.linked then
            { a with pendingStep := true, stepReqs := a.stepReqs + 1 } else a
  | .s => { a with pendingSave := true }
  | _ => a

/-- The game branch, on the press only (releases were applied first). -/
def pressF (a : App) (shift rep : Bool) : Key → App
  | .bq => { a with rewinding := !a.linked }
  | .z => { a with gz := true }
  | .s => { a with gs := true }
  | .right => { a with gright := true }
  | .tab =>                                                           -- 7: no repeats
    if rep || a.linked then a
    else if shift then { a with turbo := !a.turbo, sync := if !a.turbo then true else a.sync }
    else { a with sync := !a.sync, turbo := if !a.sync then a.turbo else false }
  | _ => a

/-- The filter chain of the fixed arm, after the release has been applied. -/
def keyF1 (a : App) (cmd shift rep : Bool) (k : Key) (down : Bool) : App :=
  if a.wck then a
  else if a.settingsOpen && a.kbVisible && decide (a.kbSel > 0) then
    if down then a else { a with kbSel := a.kbSel - 1 }
  else if cmd then
    if down && !rep then shortcutF a k else a
  else if down then pressF a shift rep k
  else a

def keyF (a : App) (cmd shift rep : Bool) (k : Key) (down : Bool) : App :=
  keyF1 (if down then a else relF a k) cmd shift rep k down

def keyStepF (s : State) (k : Key) (d : Bool) : State :=
  let rep := d && s.ph.key k
  let ph := s.ph.setKey k d
  { ph := ph, a := keyF s.a ph.kcmd ph.kshift rep k d }

/-- A pad button only feeds the merge (and a capture, while Settings is open,
still records its release). -/
def padBtnF (a : App) (down : Bool) : App :=
  if a.settingsOpen && a.ctlVisible && decide (a.ctlSel > 0) && !down then
    { a with ctlSel := a.ctlSel - 1 }
  else a

def trigHeld (ph : Phys) : Bool := (ph.pad1 && ph.p1tr) || (ph.pad2 && ph.p2tr)

/-- 4: the trigger fast forward (`apply_trigger`); `padFF` is the trigger as
last applied. -/
def ffF (ph : Phys) (a : App) : App :=
  let held := trigHeld ph
  if held == a.padFF then a
  else if held then
    if !a.sync || a.linked then { a with padFF := true }
    else { a with padFF := true, trigFF := true, trigTurbo := a.turbo, sync := false,
                  turbo := false }
  else if a.trigFF then
    if !a.sync then
      { a with padFF := false, trigFF := false, sync := true, turbo := a.trigTurbo }
    else { a with padFF := false, trigFF := false }
  else { a with padFF := false }

def setStF (a : App) (p on : Bool) : App :=
  if p then { a with st1 := on } else { a with st2 := on }

/-- 3: the merge written to the core. -/
def coreOf (ph : Phys) (a : App) : App :=
  { a with cA := a.gz || (ph.pad1 && ph.p1a) || (ph.pad2 && ph.p2a),
           cR := a.gs,
           cRight := a.gright || (ph.pad1 && ph.p1r) || (ph.pad2 && ph.p2r) || a.st1 || a.st2 }

/-- load_rom, then `new_core_takes_held_input`: the fresh core runs at normal
speed and the trigger is seen afresh, so one still pulled engages again. -/
def loadF (ph : Phys) (a : App) : App :=
  ffF ph { loadA a with padFF := false, trigFF := false }

/-- 5: a step request is spent without a frame when linked. -/
def emulateF (a : App) (due : Bool) : App :=
  emulateA { a with pendingStep := a.pendingStep && !a.linked } due

def stepF0 (s : State) : Ev → State
  | .emulate due => { s with a := emulateF s.a due }
  | .key k d => keyStepF s k d
  | .focusLost => resetWith keyStepF s
  | .padBtn p dp d => { ph := s.ph.setBtn p dp d, a := padBtnF s.a d }
  | .stick p on => { ph := s.ph.setStk p on, a := setStF s.a p on }
  | .trig p on => let ph := s.ph.setTrg p on; { ph := ph, a := ffF ph s.a }
  | .padRemove p =>
    let ph := (s.ph.rest p).setConn p false
    { ph := ph, a := ffF ph (setStF s.a p false) }
  | .drop | .menuReset => { s with a := loadF s.ph s.a }
  | .menuStep => if s.a.linked then s else step s .menuStep
  | .menuFF => if s.a.linked then s else step s .menuFF
  | .menu2x => if s.a.linked then s else step s .menu2x
  | .closeSettingsX =>                                                -- 6
    { s with a := { s.a with settingsOpen := false, imActive := false, kbSel := 0, ctlSel := 0 } }
  | e => step s e

def stepF (s : State) (e : Ev) : State :=
  let t := stepF0 s e
  { t with a := coreOf t.ph t.a }

/-- What the fixed code keeps, apart from the merge itself (which `coreOf`
establishes after every event). -/
structure InvF0 (s : State) : Prop where
  gz    : s.a.gz = true → s.ph.kz = true
  gs    : s.a.gs = true → s.ph.ks = true
  gr    : s.a.gright = true → s.ph.kright = true
  rw    : s.a.rewinding = true → s.ph.kbq = true
  st1   : s.a.st1 = true → s.ph.pad1 = true ∧ s.ph.p1st = true
  st2   : s.a.st2 = true → s.ph.pad2 = true ∧ s.ph.p2st = true
  radio : ¬ (s.a.sync = false ∧ s.a.turbo = true)
  capK  : s.a.kbSel ≠ 0 → s.a.settingsOpen = true
  capP  : s.a.ctlSel ≠ 0 → s.a.settingsOpen = true
  noLS  : s.a.ranPausedLinked = 0
  rwl   : s.a.rewinding = true → s.a.linked = false

/-! ### The fixed key arm, field by field -/

theorem keyF_frame (a : App) (c sh r : Bool) (k : Key) (d : Bool) :
    (keyF a c sh r k d).linked = a.linked ∧ (keyF a c sh r k d).settingsOpen = a.settingsOpen ∧
    (keyF a c sh r k d).ctlSel = a.ctlSel ∧ (keyF a c sh r k d).st1 = a.st1 ∧
    (keyF a c sh r k d).st2 = a.st2 ∧
    (keyF a c sh r k d).ranPausedLinked = a.ranPausedLinked ∧
    ((keyF a c sh r k d).kbSel ≠ 0 → a.kbSel ≠ 0) := by
  unfold keyF keyF1
  cases k <;> cases d <;> simp only [relF, shortcutF, pressF] <;> (repeat' split) <;>
    simp <;> omega

theorem keyF_gz (a : App) (c sh r : Bool) (k : Key) (d : Bool) :
    (keyF a c sh r k d).gz = true → (k = .z ∧ d = true) ∨ (a.gz = true ∧ (k = .z → d = true)) := by
  unfold keyF keyF1
  cases k <;> cases d <;> simp only [relF, shortcutF, pressF] <;> (repeat' split) <;> simp_all

theorem keyF_gs (a : App) (c sh r : Bool) (k : Key) (d : Bool) :
    (keyF a c sh r k d).gs = true → (k = .s ∧ d = true) ∨ (a.gs = true ∧ (k = .s → d = true)) := by
  unfold keyF keyF1
  cases k <;> cases d <;> simp only [relF, shortcutF, pressF] <;> (repeat' split) <;> simp_all

theorem keyF_gr (a : App) (c sh r : Bool) (k : Key) (d : Bool) :
    (keyF a c sh r k d).gright = true →
      (k = .right ∧ d = true) ∨ (a.gright = true ∧ (k = .right → d = true)) := by
  unfold keyF keyF1
  cases k <;> cases d <;> simp only [relF, shortcutF, pressF] <;> (repeat' split) <;> simp_all

theorem keyF_rw (a : App) (c sh r : Bool) (k : Key) (d : Bool) :
    (keyF a c sh r k d).rewinding = true →
      (k = .bq ∧ d = true ∧ a.linked = false) ∨
      (a.rewinding = true ∧ (k = .bq → d = true)) := by
  unfold keyF keyF1
  cases k <;> cases d <;> simp only [relF, shortcutF, pressF] <;> (repeat' split) <;> simp_all

theorem keyF_radio (a : App) (c sh r : Bool) (k : Key) (d : Bool)
    (h : ¬ (a.sync = false ∧ a.turbo = true)) :
    ¬ ((keyF a c sh r k d).sync = false ∧ (keyF a c sh r k d).turbo = true) := by
  unfold keyF keyF1
  cases k <;> cases d <;> simp only [relF, shortcutF, pressF] <;> (repeat' split) <;> simp_all

theorem setKey_key (ph : Phys) (k j : Key) (d : Bool) :
    (ph.setKey k d).key j = if k = j then d else ph.key j := by
  cases k <;> cases j <;> rfl

theorem keyStepF_inv (s : State) (k : Key) (d : Bool) (h : InvF0 s) : InvF0 (keyStepF s k d) := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
  obtain ⟨f1, f2, f3, f4, f5, f6, f7⟩ :=
    keyF_frame s.a (s.ph.setKey k d).kcmd (s.ph.setKey k d).kshift (d && s.ph.key k) k d
  have kz : (s.ph.setKey k d).kz = (if k = .z then d else s.ph.kz) := setKey_key s.ph k .z d
  have ks : (s.ph.setKey k d).ks = (if k = .s then d else s.ph.ks) := setKey_key s.ph k .s d
  have kr : (s.ph.setKey k d).kright = (if k = .right then d else s.ph.kright) :=
    setKey_key s.ph k .right d
  have kb : (s.ph.setKey k d).kbq = (if k = .bq then d else s.ph.kbq) := setKey_key s.ph k .bq d
  have p1 : (s.ph.setKey k d).pad1 = s.ph.pad1 := by cases k <;> rfl
  have p2 : (s.ph.setKey k d).pad2 = s.ph.pad2 := by cases k <;> rfl
  have q1 : (s.ph.setKey k d).p1st = s.ph.p1st := by cases k <;> rfl
  have q2 : (s.ph.setKey k d).p2st = s.ph.p2st := by cases k <;> rfl
  simp only [keyStepF]
  constructor
  · intro g; rw [kz]
    rcases keyF_gz _ _ _ _ _ _ g with ⟨rfl, rfl⟩ | ⟨g, hk⟩
    · rfl
    · split
      · next hz => exact hk hz
      · exact h1 g
  · intro g; rw [ks]
    rcases keyF_gs _ _ _ _ _ _ g with ⟨rfl, rfl⟩ | ⟨g, hk⟩
    · rfl
    · split
      · next hz => exact hk hz
      · exact h2 g
  · intro g; rw [kr]
    rcases keyF_gr _ _ _ _ _ _ g with ⟨rfl, rfl⟩ | ⟨g, hk⟩
    · rfl
    · split
      · next hz => exact hk hz
      · exact h3 g
  · intro g; rw [kb]
    rcases keyF_rw _ _ _ _ _ _ g with ⟨rfl, rfl, _⟩ | ⟨g, hk⟩
    · rfl
    · split
      · next hz => exact hk hz
      · exact h4 g
  · rw [f4, p1, q1]; exact h5
  · rw [f5, p2, q2]; exact h6
  · exact keyF_radio _ _ _ _ _ _ h7
  · intro g; rw [f2]; exact h8 (f7 g)
  · rw [f3, f2]; exact h9
  · rw [f6]; exact h10
  · intro g; rw [f1]
    rcases keyF_rw _ _ _ _ _ _ g with ⟨_, _, hl⟩ | ⟨g, _⟩
    · exact hl
    · exact h11 g

/-! ### The other events -/

theorem emulateA_frame (a : App) (due : Bool) :
    (emulateA a due).rewinding = a.rewinding ∧ (emulateA a due).linked = a.linked ∧
    (emulateA a due).sync = a.sync ∧ (emulateA a due).turbo = a.turbo ∧
    (emulateA a due).kbSel = a.kbSel ∧ (emulateA a due).ctlSel = a.ctlSel ∧
    (emulateA a due).settingsOpen = a.settingsOpen ∧
    (emulateA a due).gz = a.gz ∧ (emulateA a due).gs = a.gs ∧
    (emulateA a due).gright = a.gright ∧ (emulateA a due).st1 = a.st1 ∧
    (emulateA a due).st2 = a.st2 := by
  unfold emulateA pendingA
  simp only
  split <;> (try split) <;> (try split) <;> simp [popA, frameA] <;> split <;> simp

set_option linter.unusedSimpArgs false in
/-- 5: with the request dropped when linked, no paused frame runs linked. -/
theorem emulateF_rpl (a : App) (due : Bool) :
    (emulateF a due).ranPausedLinked = a.ranPausedLinked := by
  unfold emulateF emulateA pendingA
  cases hp : a.paused <;> cases hs : a.pendingStep <;> cases hl : a.linked <;>
    cases hr : a.rewinding <;> cases due <;>
    simp [hp, hs, hl, hr, popA, frameA] <;> (repeat' split) <;> simp

theorem ffF_radio (ph : Phys) (a : App) (h : ¬ (a.sync = false ∧ a.turbo = true)) :
    ¬ ((ffF ph a).sync = false ∧ (ffF ph a).turbo = true) := by
  unfold ffF
  cases h1 : trigHeld ph <;> cases h2 : a.padFF <;> cases h3 : a.linked <;>
    cases h4 : a.sync <;> cases h5 : a.trigFF <;> simp_all

theorem ffF_frame (ph : Phys) (a : App) :
    (ffF ph a).rewinding = a.rewinding ∧ (ffF ph a).linked = a.linked ∧
    (ffF ph a).kbSel = a.kbSel ∧ (ffF ph a).ctlSel = a.ctlSel ∧
    (ffF ph a).settingsOpen = a.settingsOpen ∧ (ffF ph a).gz = a.gz ∧ (ffF ph a).gs = a.gs ∧
    (ffF ph a).gright = a.gright ∧ (ffF ph a).st1 = a.st1 ∧ (ffF ph a).st2 = a.st2 ∧
    (ffF ph a).ranPausedLinked = a.ranPausedLinked := by
  unfold ffF
  cases h1 : trigHeld ph <;> cases h2 : a.padFF <;> cases h3 : a.linked <;>
    cases h4 : a.sync <;> cases h5 : a.trigFF <;> simp_all

theorem menuFFA_radio (a : App) (h : ¬ (a.sync = false ∧ a.turbo = true)) :
    ¬ ((menuFFA a).sync = false ∧ (menuFFA a).turbo = true) := by
  unfold menuFFA; cases hs : a.sync <;> cases ht : a.turbo <;> simp_all

theorem menu2xA_radio (a : App) (h : ¬ (a.sync = false ∧ a.turbo = true)) :
    ¬ ((menu2xA a).sync = false ∧ (menu2xA a).turbo = true) := by
  unfold menu2xA; cases hs : a.sync <;> cases ht : a.turbo <;> simp_all

theorem presentA_frame (a : App) (due : Bool) :
    (presentA a due).rewinding = a.rewinding ∧ (presentA a due).linked = a.linked ∧
    (presentA a due).sync = a.sync ∧ (presentA a due).turbo = a.turbo ∧
    (presentA a due).kbSel = a.kbSel ∧ (presentA a due).ctlSel = a.ctlSel ∧
    (presentA a due).settingsOpen = a.settingsOpen ∧
    (presentA a due).gz = a.gz ∧ (presentA a due).gs = a.gs ∧
    (presentA a due).gright = a.gright ∧ (presentA a due).st1 = a.st1 ∧
    (presentA a due).st2 = a.st2 ∧ (presentA a due).ranPausedLinked = a.ranPausedLinked := by
  unfold presentA; split <;> simp

set_option maxHeartbeats 4000000 in
theorem invF0_step {s : State} {e : Ev} (h : InvF0 s) (he : en s e = true) :
    InvF0 (stepF0 s e) := by
  cases e with
  | key k d => exact keyStepF_inv s k d h
  | focusLost =>
    exact resetWith_pres keyStepF InvF0 (fun s k hs _ => keyStepF_inv s k false hs) s h
  | emulate due =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
    have r := emulateF_rpl s.a due
    obtain ⟨e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12⟩ :=
      emulateA_frame { s.a with pendingStep := s.a.pendingStep && !s.a.linked } due
    simp only [emulateF] at r
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
      simp only [stepF0, emulateF, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12, r] <;>
      assumption
  | trig p on =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
    have hr := ffF_radio (s.ph.setTrg p on) s.a h7
    obtain ⟨e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11⟩ := ffF_frame (s.ph.setTrg p on) s.a
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
      simp only [stepF0, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11] <;>
      cases p <;> simp_all [Phys.setTrg]
  | padRemove p =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
    have hr := ffF_radio ((s.ph.rest p).setConn p false) (setStF s.a p false)
      (by cases p <;> simp_all [setStF])
    obtain ⟨e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11⟩ :=
      ffF_frame ((s.ph.rest p).setConn p false) (setStF s.a p false)
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
      simp only [stepF0, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11] <;>
      cases p <;> simp_all [setStF, Phys.rest, Phys.setConn]
  | present due =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
    obtain ⟨e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12, e13⟩ := presentA_frame s.a due
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
      simp only [stepF0, step, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12, e13] <;>
      assumption
  | stick p on =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
    simp only [en, Bool.and_eq_true, beq_iff_eq] at he
    cases p <;> simp only [Phys.conn] at he <;>
      refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
      simp only [stepF0, setStF, Phys.setStk] <;> simp_all
  | padAdd p =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
    simp only [en, Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true'] at he
    cases p <;> simp only [Phys.conn] at he <;>
      refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
      simp only [stepF0, step, Phys.rest, Phys.setConn] <;> simp_all
  | padBtn p dp d =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
    have hb : ∀ a : App, (padBtnF a d) = a ∨ (padBtnF a d) = { a with ctlSel := a.ctlSel - 1 } := by
      intro a; unfold padBtnF; split <;> simp
    have ep1 : (s.ph.setBtn p dp d).pad1 = s.ph.pad1 := by
      cases p <;> cases dp <;> rfl
    have ep2 : (s.ph.setBtn p dp d).pad2 = s.ph.pad2 := by
      cases p <;> cases dp <;> rfl
    have eq1 : (s.ph.setBtn p dp d).p1st = s.ph.p1st := by
      cases p <;> cases dp <;> rfl
    have eq2 : (s.ph.setBtn p dp d).p2st = s.ph.p2st := by
      cases p <;> cases dp <;> rfl
    have ek : ∀ j, (s.ph.setBtn p dp d).key j = s.ph.key j := by
      intro j; cases p <;> cases dp <;> rfl
    have ez := ek .z
    have es := ek .s
    have er := ek .right
    have eb := ek .bq
    simp only [Phys.key] at ez es er eb
    rcases hb s.a with hb | hb <;>
      refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
      simp only [stepF0, hb, ep1, ep2, eq1, eq2, ez, es, er, eb] <;>
      first | assumption | (intro g; exact h9 (by omega)) | simp_all
  | menuStep =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
    simp only [stepF0, step]
    split
    · exact ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩
    · exact ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩
  | menuFF =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
    simp only [stepF0, step]
    split
    · exact ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩
    · exact ⟨h1, h2, h3, h4, h5, h6, menuFFA_radio s.a h7, h8, h9, h10, h11⟩
  | menu2x =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
    simp only [stepF0, step]
    split
    · exact ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩
    · exact ⟨h1, h2, h3, h4, h5, h6, menu2xA_radio s.a h7, h8, h9, h10, h11⟩
  | drop | menuReset =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
    have hr := ffF_radio s.ph { loadA s.a with padFF := false, trigFF := false } (by simp [loadA])
    obtain ⟨e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11⟩ :=
      ffF_frame s.ph { loadA s.a with padFF := false, trigFF := false }
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
      simp only [stepF0, loadF, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11] <;>
      simp_all [loadA]
  | _ =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h
    simp only [en, Bool.and_eq_true, beq_iff_eq] at he
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp only [stepF0, step] <;>
      simp_all

theorem coreOf_frame (ph : Phys) (a : App) :
    (coreOf ph a).gz = a.gz ∧ (coreOf ph a).gs = a.gs ∧ (coreOf ph a).gright = a.gright ∧
    (coreOf ph a).rewinding = a.rewinding ∧ (coreOf ph a).st1 = a.st1 ∧
    (coreOf ph a).st2 = a.st2 ∧ (coreOf ph a).sync = a.sync ∧ (coreOf ph a).turbo = a.turbo ∧
    (coreOf ph a).kbSel = a.kbSel ∧ (coreOf ph a).ctlSel = a.ctlSel ∧
    (coreOf ph a).settingsOpen = a.settingsOpen ∧
    (coreOf ph a).ranPausedLinked = a.ranPausedLinked ∧ (coreOf ph a).linked = a.linked := by
  simp [coreOf]

/-- The fixed code's invariant: `InvF0` and the merge. -/
structure InvF (s : State) : Prop where
  base : InvF0 s
  core : s.a.cA = (s.a.gz || (s.ph.pad1 && s.ph.p1a) || (s.ph.pad2 && s.ph.p2a)) ∧
         s.a.cR = s.a.gs ∧
         s.a.cRight = (s.a.gright || (s.ph.pad1 && s.ph.p1r) || (s.ph.pad2 && s.ph.p2r) ||
                       s.a.st1 || s.a.st2)

theorem invF_init : InvF init := by
  refine ⟨⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, ?_⟩ <;> simp [init]

theorem invF_step {s : State} {e : Ev} (h : InvF s) (he : en s e = true) : InvF (stepF s e) := by
  have h0 := invF0_step h.base he
  obtain ⟨c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13⟩ :=
    coreOf_frame (stepF0 s e).ph (stepF0 s e).a
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11⟩ := h0
  refine ⟨⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, ?_⟩ <;>
    simp only [stepF, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13] <;>
    first | assumption | simp [coreOf]

theorem invF_reach {s : State} (h : Reach stepF s) : InvF s := by
  induction h with
  | init => exact invF_init
  | step _ he ih => exact invF_step ih he

/-- **(a), fixed: no stuck buttons.** Whatever the interleaving of keys, Cmd,
focus loss, ImGui focus, binding captures, pads, hotplug, pause, rewind and
loads, the core holds an input only while a physical source holds it. -/
theorem fix_no_stuck {s : State} (h : Reach stepF s) : stuck s = false := by
  obtain ⟨⟨h1, h2, h3, _, h5, h6, _⟩, c1, c2, c3⟩ := invF_reach h
  have eA : s.a.cA = true → physA s.ph = true := by
    intro hc; rw [c1] at hc
    simp only [physA, Bool.or_eq_true, Bool.and_eq_true] at hc ⊢
    rcases hc with (hc | hc) | hc <;> simp_all
  have eR : s.a.cR = true → physR s.ph = true := by
    intro hc; rw [c2] at hc; exact h2 hc
  have eRt : s.a.cRight = true → physRight s.ph = true := by
    intro hc; rw [c3] at hc
    simp only [physRight, Bool.or_eq_true, Bool.and_eq_true] at hc ⊢
    rcases hc with (((hc | hc) | hc) | hc) | hc <;> simp_all
  simp only [stuck]
  cases hA : s.a.cA <;> cases hR : s.a.cR <;> cases hRt : s.a.cRight <;> simp_all

/-- **(a), fixed: no dropped pad input.** Every open pad's held button and pushed
stick reaches the core (keys reach it unless ImGui or a binding capture took
their press). -/
theorem fix_pads_seen {s : State} (h : Reach stepF s) :
    ((s.ph.pad1 && s.ph.p1a) || (s.ph.pad2 && s.ph.p2a) → s.a.cA) = true ∧
    ((s.ph.pad1 && s.ph.p1r) || (s.ph.pad2 && s.ph.p2r) → s.a.cRight) = true := by
  obtain ⟨_, c1, _, c3⟩ := invF_reach h
  rw [c1, c3]
  cases s.a.gz <;> cases s.a.gright <;> cases s.a.st1 <;> cases s.a.st2 <;>
    cases s.ph.pad1 <;> cases s.ph.pad2 <;> cases s.ph.p1a <;> cases s.ph.p2a <;>
    cases s.ph.p1r <;> cases s.ph.p2r <;> decide

/-- **(b), fixed: rewind only while Grave is held.** -/
theorem fix_rewind_only_while_held {s : State} (h : Reach stepF s)
    (hr : s.a.rewinding = true) : s.ph.kbq = true := (invF_reach h).base.rw hr

/-- **(d), fixed: at most one of Fast Forward / 2x Speed is checked**, so the
checked item is what runs. -/
theorem fix_radio {s : State} (h : Reach stepF s) : bothChecked s = false := by
  have := (invF_reach h).base.radio
  simp only [bothChecked]
  cases h1 : s.a.sync <;> cases h2 : s.a.turbo <;> simp_all

/-- **Fixed: no paused frame runs through the link.** -/
theorem fix_no_linked_step {s : State} (h : Reach stepF s) : s.a.ranPausedLinked = 0 :=
  (invF_reach h).base.noLS

/-- **Fixed: a binding capture never outlives the Settings window.** -/
theorem fix_capture_needs_settings {s : State} (h : Reach stepF s) :
    (s.a.kbSel ≠ 0 → s.a.settingsOpen = true) ∧ (s.a.ctlSel ≠ 0 → s.a.settingsOpen = true) :=
  ⟨(invF_reach h).base.capK, (invF_reach h).base.capP⟩

/-! ### The traces again, on the fixed code -/

theorem regress_cmd_held_release :
    witnesses stepF ([.emulate true, .key .s true, .key .cmd true, .key .s false, .key .cmd false]
                     ++ idle)
      (fun s => !stuck s && s.a.quickSaves == 0) = true := by decide

theorem regress_cmd_tab_away :
    witnesses stepF ([.emulate true, .key .right true, .key .s true, .key .bq true, .key .cmd true,
                      .focusLost] ++ idle)
      (fun s => !stuck s && !s.a.rewinding && s.a.quickSaves == 0) = true := by decide

/-- Cmd+S still saves, once, on the press. -/
theorem regress_cmd_s_still_saves :
    witnesses stepF ([.emulate true, .key .cmd true, .key .s true, .key .s true, .key .s false,
                      .key .cmd false] ++ idle)
      (fun s => !stuck s && s.a.quickSaves == 1) = true := by decide

theorem regress_imgui_capture_swallows_release :
    witnesses stepF ([.emulate true, .mouseMove, .key .right true] ++ render ++ [.grab] ++ back
                     ++ render ++ back ++ [.key .right false, .drained])
      (fun s => !stuck s) = true := by decide

theorem regress_closed_settings_keeps_capturing :
    witnesses stepF ([.emulate true, .mouseMove] ++ render ++ [.openSettings] ++ back
                     ++ render ++ [.pickKey 10, .closeSettingsX] ++ back ++ [.mouseIdle] ++ idle
                     ++ [.key .z true])
      (fun s => s.a.cA && s.a.kbSel == 0) = true := by decide

theorem regress_two_sources :
    witnesses stepF [.emulate true, .padAdd true, .padAdd false, .key .z true,
                     .padBtn true false true, .padBtn false false true, .padBtn true false false,
                     .stick true true, .stick false false, .padRemove false, .drained]
      (fun s => s.a.cA && s.a.cRight && !stuck s) = true := by decide

theorem regress_reset_keeps_held_input :
    witnesses stepF ([.emulate true, .mouseMove, .key .right true] ++ render ++ [.menuReset])
      (fun s => s.a.cRight) = true := by decide

theorem regress_trigger_with_2x :
    witnesses stepF [.emulate true, .padAdd true, .key .shift true, .key .tab true,
                     .trig true true, .drained] (fun s => !bothChecked s && !s.a.sync) = true := by
  decide

theorem regress_menu_frame_advance_while_linked :
    witnesses stepF ([.emulate true, .mouseMove, .drained, .linkUp, .post false, .present true,
                      .menuPause] ++ back ++ render ++ [.menuStep] ++ back)
      (fun s => s.a.linked && s.a.paused && s.a.ranPausedLinked == 0) = true := by decide

/-- Grave let go with Cmd down: rewind ends and the game runs on. -/
theorem regress_rewind_sticks_after_cmd :
    witnesses stepF ([.emulate true, .key .bq true, .key .cmd true, .key .bq false,
                      .key .cmd false] ++ idle ++ idle ++ idle)
      (fun s => !s.a.rewinding && decide (1 < s.a.frames)) = true := by decide

/-- The capture still takes Z's release as the binding, and A is let go. -/
theorem regress_binding_capture_swallows_release :
    witnesses stepF ([.emulate true, .mouseMove, .key .z true] ++ render ++ [.openSettings] ++ back
                     ++ render ++ [.pickKey 10] ++ back ++ [.key .z false, .drained])
      (fun s => !stuck s && s.a.kbSel == 9) = true := by decide

theorem regress_closed_settings_keeps_capturing_buttons :
    witnesses stepF ([.emulate true, .mouseMove] ++ render ++ [.openSettings, .switchTab] ++ back
                     ++ render ++ [.pickBtn 10, .closeSettingsX] ++ back
                     ++ [.padAdd true, .padBtn true false true])
      (fun s => !s.a.settingsOpen && s.ph.p1a && s.a.cA) = true := by decide

theorem regress_tab_repeat :
    witnesses stepF [.emulate true, .key .tab true, .key .tab true, .drained]
      (fun s => s.ph.ktab && !s.a.sync) = true := by decide

/-- The trigger is momentary over a fast forward Tab latched... -/
theorem regress_trigger_release_keeps_tab_ff :
    witnesses stepF [.emulate true, .padAdd true, .key .tab true, .key .tab false,
                     .trig true true, .trig true false, .drained]
      (fun s => !s.a.sync && !s.a.padFF) = true := by decide

/-- ...and over 2x Speed, which its release brings back. -/
theorem regress_trigger_release_restores_2x :
    witnesses stepF [.emulate true, .padAdd true, .key .shift true, .key .tab true,
                     .trig true true, .trig true false, .drained]
      (fun s => s.a.sync && s.a.turbo) = true := by decide

theorem regress_trigger_ff_while_linked :
    witnesses stepF ([.emulate true, .padAdd true, .drained, .linkUp, .post false,
                      .present false, .title false, .emulate true, .trig true true])
      (fun s => s.a.linked && s.a.sync) = true := by decide

/-- A trigger held across a reset fast-forwards the fresh core. -/
theorem regress_trigger_held_across_reset :
    witnesses stepF ([.emulate true, .padAdd true, .trig true true, .mouseMove] ++ render
                     ++ [.menuReset])
      (fun s => !s.a.sync && s.a.trigFF) = true := by decide

/-- **Fixed: with Settings closed, no key or pad button goes to a capture**,
whatever the selections and `visible` flags still say. -/
theorem fix_closed_settings_never_captures (s : State) (h : s.a.settingsOpen = false)
    (k : Key) (p dp d : Bool) :
    (stepF s (.key k d)).a.kbSel = s.a.kbSel ∧
    (stepF s (.padBtn p dp d)).a.ctlSel = s.a.ctlSel := by
  constructor
  · simp only [stepF, stepF0, keyStepF, keyF, keyF1, coreOf]
    cases k <;> cases d <;> simp [relF, shortcutF, pressF, h] <;> (repeat' split) <;> simp
  · simp [stepF, stepF0, padBtnF, coreOf, h]

/-! ## Part 3: ImGui's input queue while render_imgui is skipped

`ImGui_ImplSDL2_ProcessEvent` (1631) runs for every SDL event, whatever
happens next, and appends to ImGui's input queue (io.AddKeyEvent /
AddMousePosEvent / AddMouseButtonEvent, imgui.cpp 1651-1986; AddKeyEvent only
drops an event equal to the key's latest state, so key repeats are dropped but
every press and release is kept). Only `igNewFrame` drains the queue
(UpdateInputEvents, imgui.cpp 10906), and render_imgui's skip condition
(1271-1283) returns before `igNewFrame`. So during play with the menu bar
hidden and no window open (the normal full-screen game view), every key event
piles up.

With the default `io.ConfigInputTrickleEventQueue`, one frame stops draining
at the second change of the same key, at a mouse move after any key change,
and at a second change of the same mouse button (imgui.cpp 10930, 10941, 10972).
Moving the mouse brings the menu bar back and so the next presents run
`igNewFrame`, but the move and the click on the menu sit behind the backlog:
with one key pressed n times, the click reaches ImGui on frame 2n + 1.

Checked against the real imgui 1.92.4 that dingbat links (imguin), headless:
3000 Z taps queued, then a move and a click: the click was seen on frame
6001 (the 6000th after the first), 50 s at 120 Hz. A long keyboard-only
session makes the menu bar ignore clicks for that long. -/
namespace Backlog

inductive IEv where
  | key (down : Bool)     -- a key event for Z (ImGuiKey_Z)
  | pos                   -- a mouse move
  | btn (down : Bool)     -- the left button

structure Q where
  queue : List IEv
  zDown : Bool            -- io.KeysData[Z].Down
  mouseDown : Bool        -- io.MouseDown[0]
  clicked : Bool          -- ImGui has seen the button go down
  frames : Nat            -- igNewFrame calls

/-- UpdateInputEvents with trickling (imgui.cpp 10906-11020), for one key, the
mouse position and one button. `kc`: the key changed this frame; `bc`: the
button changed this frame. Returns the rest of the queue and the new state. -/
def drain : List IEv → Bool → Bool → Bool → Bool → Bool → List IEv × Bool × Bool × Bool
  | [], _, _, z, m, c => ([], z, m, c)
  | e :: rest, kc, bc, z, m, c =>
    match e with
    | .key d =>
      if z != d && (kc || bc) then (e :: rest, z, m, c)              -- 10972
      else drain rest (kc || z != d) bc d m c
    | .pos =>
      if bc || kc then (e :: rest, z, m, c)                          -- 10930
      else drain rest kc bc z m c
    | .btn d =>
      if bc then (e :: rest, z, m, c)                                -- 10941
      else drain rest kc true z d (c || d)

/-- One igNewFrame. -/
def frame (q : Q) : Q :=
  let r := drain q.queue false false q.zDown q.mouseDown q.clicked
  { queue := r.1, zDown := r.2.1, mouseDown := r.2.2.1, clicked := r.2.2.2, frames := q.frames + 1 }

def iter : Nat → Q → Q
  | 0, q => q
  | k + 1, q => iter k (frame q)

/-- n presses of Z made while ImGui was skipped. -/
def taps : Nat → List IEv
  | 0 => []
  | n + 1 => .key true :: .key false :: taps n

/-- Then the player moves the mouse to the menu bar and clicks. -/
def click : List IEv := [.pos, .btn true, .btn false]

def start (n : Nat) : Q :=
  { queue := taps n ++ click, zDown := false, mouseDown := false, clicked := false, frames := 0 }

/-- The backlog grows by two events per tap for as long as ImGui is skipped. -/
theorem backlog_length (n : Nat) : (start n).queue.length = 2 * n + 3 := by
  simp only [start]
  induction n with
  | zero => rfl
  | succ n ih => simp [taps] at *; omega

/-- A tap costs two frames: the press, then the release. -/
theorem two_frames (t : List IEv) (ht : t.head? = some .pos ∨ t.head? = some (.key true))
    (m c : Bool) (f : Nat) :
    frame (frame { queue := .key true :: .key false :: t, zDown := false, mouseDown := m,
                   clicked := c, frames := f }) =
      { queue := t, zDown := false, mouseDown := m, clicked := c, frames := f + 2 } := by
  rcases t with _ | ⟨x, t⟩
  · simp at ht
  · simp at ht
    rcases ht with rfl | rfl <;> simp [frame, drain]

theorem taps_head (n : Nat) :
    (taps n ++ click).head? = some .pos ∨ (taps n ++ click).head? = some (.key true) := by
  cases n <;> simp [taps, click]

theorem iter_taps (n f : Nat) :
    iter (2 * n) { queue := taps n ++ click, zDown := false, mouseDown := false,
                   clicked := false, frames := f } =
      { queue := click, zDown := false, mouseDown := false, clicked := false,
        frames := f + 2 * n } := by
  induction n generalizing f with
  | zero => rfl
  | succ n ih =>
    have : 2 * (n + 1) = 2 * n + 1 + 1 := by omega
    rw [this]
    simp only [iter, taps, List.cons_append]
    rw [two_frames _ (taps_head n), ih]
    congr 1; omega

/-- **The click waits behind the backlog: n taps queued while ImGui was
skipped delay a menu click by 2n frames.** -/
theorem click_waits (n : Nat) :
    (iter (2 * n) (start n)).clicked = false ∧ (iter (2 * n + 1) (start n)).clicked = true := by
  have h := iter_taps n 0
  simp only [start] at *
  constructor
  · rw [h]
  · have : 2 * n + 1 = 1 + 2 * n := by omega
    rw [this]
    have e : ∀ k q, iter (1 + k) q = frame (iter k q) := by
      intro k; induction k with
      | zero => intro q; rfl
      | succ k ih => intro q; rw [show 1 + (k + 1) = (1 + k) + 1 by omega]; simp only [iter]; rw [ih]
    rw [e, h]
    simp [frame, drain, click]

/-! ### The fix: render_imgui's skip branch

While render_imgui skips igNewFrame it drops ImGui's queue on every skipped
present (`ImGuiIO_ClearEventsQueue`), and on the first one also clears the
key and mouse state (`ClearInputKeys` / `ClearInputMouse`), since a release
may be among what is dropped. Checked against imgui 1.92.4 headless: after
3000 queued taps the click is seen on the 2nd frame after the menu comes
back (the move's frame, then the click's), against the 6002nd before. -/

def skipF (q : Q) : Q := { q with queue := [], zDown := false, mouseDown := false }

theorem iter_one_add (k : Nat) (q : Q) : iter (1 + k) q = frame (iter k q) := by
  induction k generalizing q with
  | zero => rfl
  | succ k ih =>
    rw [show 1 + (k + 1) = (1 + k) + 1 by omega]; simp only [iter]; rw [ih]

/-- **Fixed:** however long the keyboard-only session was, a click that
follows the k taps made since the last skipped present (one loop iteration's
worth) is seen on frame 2k + 1. -/
theorem regress_click_after_skip (q : Q) (hc : q.clicked = false) (k : Nat) :
    (iter (2 * k) { skipF q with queue := taps k ++ click }).clicked = false ∧
    (iter (2 * k + 1) { skipF q with queue := taps k ++ click }).clicked = true := by
  have e : ({ skipF q with queue := taps k ++ click } : Q) =
      { queue := taps k ++ click, zDown := false, mouseDown := false, clicked := false,
        frames := q.frames } := by
    cases q; simp_all [skipF]
  rw [e]
  constructor
  · rw [iter_taps]
  · rw [show 2 * k + 1 = 1 + 2 * k by omega, iter_one_add, iter_taps]
    simp [frame, drain, click]

end Backlog

end DesktopState.RunInput
