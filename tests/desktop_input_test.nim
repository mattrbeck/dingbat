## The desktop app's held input and key routing (src/dingbat/frontend/
## held_input.nim), driven with the event sequences that stuck buttons or
## fired shortcuts in the app: a key released while Cmd/Ctrl is down, while
## ImGui or a binding capture has the keyboard, or by SDL on a focus loss;
## the keyboard, two pads and their sticks sharing one input; a fresh core
## after a load; the trigger's fast forward; a held Tab; and bindings the
## game could never receive. The traces are the Lean model's
## (formal/DesktopState/RunInput.lean, bug_* / regress_*).

import std/tables
import dingbat/common/input
import dingbat/frontend/held_input

const
  KZ     = cint(122)          # bound to A (default bindings)
  KS     = cint(115)          # bound to R, and Cmd/Ctrl+S is Quick Save
  KRIGHT = cint(0x4000004F)   # bound to RIGHT
  KSHIFT = cint(0x400000E1)
  KMOD   = SHORTCUT_KEYS[0]   # Cmd on macOS, Ctrl elsewhere

let bindings = {KZ: Input.A, KS: Input.R, KRIGHT: Input.RIGHT}.toTable

var h: HeldInput
var core: set[Input]          # what the core has been told is held
var shortcuts: seq[cint]      # shortcut keys fired
var rewinding = false
var captured: seq[cint]       # releases the binding capture took

proc sync() =
  let (pressed, released) = h.take_changes()
  doAssert (pressed * released) == {}
  doAssert (pressed * core) == {} and (released - core) == {}
  core = core + pressed - released

proc key(k: cint; pressed: bool; repeat = false; modheld = false;
         imgui = false; capturing = false) =
  let r = h.route_key(bindings, k, pressed, repeat, modheld, imgui, capturing)
  sync()
  case r
  of krShortcut:
    # The modifier's own press routes here too; the app's shortcut table
    # has no entry for it
    if k notin SHORTCUT_KEYS: shortcuts.add k
  of krRewind: rewinding = pressed
  of krCapture: captured.add k
  else: discard

proc reset_all() =
  h = HeldInput()
  core = {}
  shortcuts = @[]
  rewinding = false
  captured = @[]

# -- Finding 6: a game key let go while Cmd/Ctrl is down -----------------------

block cmd_held_release:
  # Hold S (R), touch Cmd, let go of S first: R is released and no Quick Save
  reset_all()
  key(KS, true)
  doAssert core == {Input.R}
  key(KMOD, true, modheld = true)
  key(KS, false, modheld = true)
  key(KMOD, false)
  doAssert core == {}, "R stuck after its key was released with Cmd down"
  doAssert shortcuts.len == 0, "releasing S with Cmd down fired a shortcut"

block cmd_s_still_saves_once:
  # Cmd+S held long enough to repeat: one Quick Save, on the press
  reset_all()
  key(KMOD, true, modheld = true)
  key(KS, true, modheld = true)
  doAssert shortcuts == @[KS]
  key(KS, true, repeat = true, modheld = true)
  key(KS, false, modheld = true)
  key(KMOD, false)
  doAssert shortcuts == @[KS], "a key repeat or the release fired it again"
  doAssert core == {}, "the chorded S pressed R"

block cmd_tab_away:
  # Cmd+Tab away holding Right, S and backquote: SDL releases every held key
  # in scancode order, the modifier last, each release carrying Cmd
  reset_all()
  key(KRIGHT, true); key(KS, true); key(KEY_BACKQUOTE, true)
  doAssert core == {Input.RIGHT, Input.R} and rewinding
  key(KMOD, true, modheld = true)
  for k in [KS, KEY_BACKQUOTE, KRIGHT]:   # s(22) grave(53) right(79)
    key(k, false, modheld = true)
  key(KMOD, false)
  doAssert core == {}, "a key released on focus loss stayed held"
  doAssert not rewinding, "rewind stayed on after a focus loss"
  doAssert shortcuts.len == 0, "focus loss fired a shortcut"

block rewind_release_with_cmd:
  reset_all()
  key(KEY_BACKQUOTE, true)
  key(KMOD, true, modheld = true)
  key(KEY_BACKQUOTE, false, modheld = true)
  doAssert not rewinding, "rewind stuck on after backquote was let go"

# -- Finding 12: a release taken by ImGui or a binding capture -----------------

block imgui_takes_release:
  # Hold Right, click into a text field (WantCaptureKeyboard), let go
  reset_all()
  key(KRIGHT, true)
  key(KRIGHT, false, imgui = true)
  doAssert core == {}, "RIGHT stuck behind WantCaptureKeyboard"
  # ...and a press ImGui takes never reaches the game
  key(KZ, true, imgui = true)
  doAssert core == {}
  key(KZ, false)

block capture_takes_release:
  # Hold Z, click a Keybindings button: Z's release becomes the binding, and
  # the game lets go of A too
  reset_all()
  key(KZ, true)
  key(KZ, false, capturing = true)
  doAssert captured == @[KZ]
  doAssert core == {}, "A stuck after a binding capture took Z's release"
  # A press during a capture is the capture's, not the game's
  key(KS, true, capturing = true)
  doAssert core == {}
  doAssert shortcuts.len == 0

# -- Low: several sources for one input -----------------------------------------

block keyboard_and_pad:
  # Hold Z and pad A; let go of pad A: Z still holds A
  reset_all()
  h.pad_added(1)
  key(KZ, true)
  h.pad_button(1, 0, true, Input.A, true); sync()
  h.pad_button(1, 0, true, Input.A, false); sync()
  doAssert Input.A in core, "a pad release dropped the key the keyboard holds"
  key(KZ, false)
  doAssert core == {}

block two_pads:
  # Pad 2's release does not drop pad 1's A; pad 2's idle stick does not
  # drop pad 1's stick; unplugging pad 2 keeps pad 1 and the keyboard
  reset_all()
  h.pad_added(1); h.pad_added(2)
  key(KZ, true)
  h.pad_button(1, 0, true, Input.A, true); sync()
  h.pad_button(2, 0, true, Input.A, true); sync()
  h.pad_button(2, 0, true, Input.A, false); sync()
  h.pad_stick(1, Input.RIGHT, true); sync()
  h.pad_stick(2, Input.RIGHT, false); sync()   # drift inside the deadzone
  doAssert core == {Input.A, Input.RIGHT}
  key(KZ, false)
  doAssert core == {Input.A, Input.RIGHT}, "pad 1's A lost to the keyboard's release"
  h.pad_removed(2); sync()
  doAssert core == {Input.A, Input.RIGHT}
  h.pad_removed(1); sync()
  doAssert core == {}, "unplugging pad 1 left its holds"

block unplug_keeps_keyboard:
  reset_all()
  h.pad_added(1)
  key(KZ, true)
  h.pad_button(1, 14, true, Input.RIGHT, true); sync()
  h.pad_removed(1); sync()
  doAssert core == {Input.A}, "unplugging the last pad released a held key"

block two_buttons_one_input:
  # Default mapping binds both a and x to A: letting go of one keeps A
  reset_all()
  h.pad_added(1)
  h.pad_button(1, 0, true, Input.A, true)
  h.pad_button(1, 2, true, Input.A, true); sync()
  h.pad_button(1, 2, true, Input.A, false); sync()
  doAssert core == {Input.A}

block stick_and_dpad:
  reset_all()
  h.pad_added(1)
  h.pad_stick(1, Input.RIGHT, true)
  h.pad_button(1, 14, true, Input.RIGHT, true); sync()
  h.pad_stick(1, Input.RIGHT, false); sync()
  doAssert core == {Input.RIGHT}, "recentring the stick dropped the d-pad's RIGHT"
  h.pad_button(1, 14, true, Input.RIGHT, false); sync()
  doAssert core == {}

block release_after_rebind:
  # A key released after Apply rebound it lets go of what its press held
  reset_all()
  key(KZ, true)
  var rebound = bindings
  rebound[KZ] = Input.B
  discard h.route_key(rebound, KZ, false, false, false, false, false); sync()
  doAssert core == {}

block fresh_core:
  # Reset or a new game: the fresh core hears the keys still held
  reset_all()
  key(KRIGHT, true)
  h.core_replaced(); core = {}; sync()
  doAssert core == {Input.RIGHT}, "a key held across a reset was not re-pressed"

# -- Low: fast forward -------------------------------------------------------------

block tab_repeat:
  reset_all()
  var toggles = 0
  for rep in [false, true, true, true]:
    if h.route_key(bindings, KEY_TAB, true, rep, false, false, false) == krFastForward:
      inc toggles
  doAssert toggles == 1, "holding Tab toggled fast forward on key repeat"
  doAssert h.route_key(bindings, KEY_TAB, false, false, false, false, false) == krNone

block trigger_clears_2x:
  reset_all()
  h.pad_added(1)
  var sp = Speed(sync: true, turbo: true)            # 2x Speed on
  h.pad_trigger(1, true); h.apply_trigger(sp, linked = false)
  doAssert not sp.sync and not sp.turbo, "trigger left 2x and fast forward both on"
  h.pad_trigger(1, false); h.apply_trigger(sp, linked = false)
  doAssert sp.sync and sp.turbo, "the release did not bring 2x back"

block trigger_keeps_tab_ff:
  reset_all()
  h.pad_added(1)
  var sp = Speed(sync: false, turbo: false)          # Tab latched fast forward
  h.pad_trigger(1, true); h.apply_trigger(sp, linked = false)
  h.pad_trigger(1, false); h.apply_trigger(sp, linked = false)
  doAssert not sp.sync, "the trigger's release cancelled Tab's fast forward"

block trigger_two_pads:
  reset_all()
  h.pad_added(1); h.pad_added(2)
  var sp = Speed(sync: true, turbo: false)
  h.pad_trigger(1, true); h.apply_trigger(sp, linked = false)
  h.pad_trigger(2, false); h.apply_trigger(sp, linked = false)
  doAssert not sp.sync, "pad 2's idle trigger ended pad 1's fast forward"
  h.pad_removed(1); h.apply_trigger(sp, linked = false)
  doAssert sp.sync

block trigger_linked:
  reset_all()
  h.pad_added(1)
  var sp = Speed(sync: true, turbo: false)
  h.pad_trigger(1, true); h.apply_trigger(sp, linked = true)
  doAssert sp.sync, "the trigger fast-forwarded a linked game"

block trigger_held_across_load:
  reset_all()
  h.pad_added(1)
  var sp = Speed(sync: true, turbo: false)
  h.pad_trigger(1, true); h.apply_trigger(sp, linked = false)
  h.core_replaced()
  sp = Speed(sync: true, turbo: false)               # the fresh core
  h.apply_trigger(sp, linked = false)
  doAssert not sp.sync, "a trigger held across a load stopped fast-forwarding"

# -- Finding 15: bindings the game can never receive -------------------------------

block unbindable:
  for k in SHORTCUT_KEYS: doAssert not bindable_key(k)
  for k in [KEY_F9, KEY_F12, KEY_BACKQUOTE]: doAssert not bindable_key(k)
  for k in [KZ, KS, KRIGHT, KSHIFT, KEY_TAB]: doAssert bindable_key(k)

echo "ok"
