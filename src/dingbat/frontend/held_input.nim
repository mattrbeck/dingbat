## What the player holds, from every source, and where a key event goes.
## No SDL, ImGui or GL here, so the tests build it headless; dingbat.nim
## feeds it the SDL events and applies what it returns.
##
## The core has one bit per input, but the keyboard, every open pad's buttons
## and every pad's left stick can each hold the same input. Each source's
## holds are kept apart, keyed by what was pressed (the key code, the pad
## button) together with the input that press meant, and the core is told
## their union. So a release lets go of exactly what its own press held,
## whatever the bindings are by then and whatever else holds that input.

import std/tables
import ../common/input

# SDL2 keycodes the router needs (SDL_keycode.h). Keys without a character
# are their scancode with bit 30 set.
const
  KEY_TAB*       = cint(9)
  KEY_BACKQUOTE* = cint(96)
  KEY_1*         = cint(49)
  KEY_F9*        = cint(0x40000042)
  KEY_F12*       = cint(0x40000045)

# The keys whose own press carries the shortcut modifier, so it always takes
# the shortcut branch: Cmd (LGUI, RGUI) on macOS, Ctrl (LCTRL, RCTRL) elsewhere
when defined(macosx):
  const SHORTCUT_KEYS* = [cint(0x400000E3), cint(0x400000E7)]
else:
  const SHORTCUT_KEYS* = [cint(0x400000E0), cint(0x400000E4)]

type
  PadHolds = object
    buttons: Table[cint, Input]  # held button -> the input its press meant
    stick:   set[Input]          # left-stick directions past the deadzone
    trigger: bool                # right trigger past the threshold

  HeldInput* = object
    keys:          Table[cint, Input]    # held key -> the input its press meant
    pads:          Table[int32, PadHolds]  # by joystick instance id
    told:          set[Input]            # what the core was last told is held
    trigger_seen:  bool                  # some pad's trigger, as last applied
    trigger_ff:    bool                  # that pull turned fast forward on
    turbo_before:  bool                  # 2x Speed before that pull

  Speed* = object
    ## The two speed toggles of the running core's APU
    sync*:  bool  ## paced by audio: "Fast Forward" is checked when false
    turbo*: bool  ## "2x Speed"

  KeyRoute* = enum
    krNone         ## nothing (more) to do
    krCapture      ## the Keybindings capture takes this release
    krShortcut     ## Cmd (macOS) / Ctrl + key, on its first press
    krMark         ## F9: playtest checkpoint
    krScreenshot   ## F12
    krRewind       ## backquote: rewind while `pressed`
    krFastForward  ## Tab (Shift+Tab for 2x)
    krChannel      ## 1-6: toggle an audio channel

  ModalKey* = enum
    ## What a key means to an open modal (frontend/notice.nim)
    mkNone     ## nothing
    mkDefault  ## Return / keypad Enter: the default button
    mkCancel   ## Escape: close, or the Cancel button

proc held*(h: HeldInput): set[Input] =
  ## Every input some key, pad button or stick holds
  for inp in h.keys.values: result.incl inp
  for pad in h.pads.values:
    for inp in pad.buttons.values: result.incl inp
    result = result + pad.stick

proc take_changes*(h: var HeldInput): tuple[pressed, released: set[Input]] =
  ## What the core must be told for it to hold exactly `held`
  let now = h.held()
  result = (now - h.told, h.told - now)
  h.told = now

proc core_replaced*(h: var HeldInput) =
  ## A fresh core holds nothing and runs at normal speed: the next
  ## take_changes presses what is still held, and a trigger still held
  ## engages fast forward again.
  h.told = {}
  h.trigger_seen = false
  h.trigger_ff = false

proc bindable_key*(key: cint): bool =
  ## Keys the game can never receive: the shortcut modifier (its own press
  ## takes the shortcut branch), and the keys handle_input claims first.
  key notin SHORTCUT_KEYS and key notin [KEY_F9, KEY_F12, KEY_BACKQUOTE]

proc route_key*(h: var HeldInput; bindings: Table[cint, Input]; key: cint;
                pressed, repeat, shortcut_mod, imgui_keyboard,
                capturing: bool): KeyRoute =
  ## One KeyDown (`pressed`) or KeyUp. A release lets go of what its press
  ## held before anything filters the keyboard: whatever has the keyboard now
  ## (an ImGui text field or modal, a binding capture, Cmd/Ctrl held) got it
  ## after the game saw the press, and a release it swallowed would leave the
  ## button, or rewind, held with nobody holding it. Everything else acts on
  ## the press, so letting go of a key while Cmd/Ctrl is down, or SDL
  ## releasing every held key when the window loses focus, fires nothing.
  if not pressed:
    h.keys.del(key)
    if key == KEY_BACKQUOTE: return krRewind
  if imgui_keyboard: return krNone
  if capturing: return (if pressed: krNone else: krCapture)
  if not pressed: return krNone
  if shortcut_mod: return (if repeat: krNone else: krShortcut)
  if key == KEY_F9: return (if repeat: krNone else: krMark)
  if key == KEY_F12: return (if repeat: krNone else: krScreenshot)
  if key == KEY_BACKQUOTE: return krRewind
  if bindings.hasKey(key):
    h.keys[key] = bindings[key]
    return krNone
  # Toggles: a key held down repeats, and must not flip them back and forth
  if repeat: return krNone
  if key == KEY_TAB: return krFastForward
  if key >= KEY_1 and key < KEY_1 + 6: return krChannel
  krNone

proc modal_key_of*(appearing, escape, enter: bool): ModalKey =
  ## A key press (not a repeat) as an open modal takes it. The game never
  ## gets it: a modal sets ImGui's WantCaptureKeyboard, so `route_key` gives
  ## the press to nothing, and the release comes once the modal is gone and
  ## lets go of nothing. A press on the frame the modal appears is not for
  ## it: that is the press that closed the one before (a queued notice opens
  ## the frame the one ahead of it closes), or one the game was given.
  if appearing: mkNone
  elif escape: mkCancel
  elif enter: mkDefault
  else: mkNone

proc pad_added*(h: var HeldInput; pad: int32) =
  h.pads[pad] = PadHolds()

proc pad_removed*(h: var HeldInput; pad: int32) =
  ## SDL recentres an unplugged pad before it says so; whatever is left of
  ## this pad goes with it, and nothing any other source holds
  h.pads.del(pad)

proc pad_button*(h: var HeldInput; pad: int32; button: cint; bound: bool;
                 inp: Input; pressed: bool) =
  ## A button press holds its bound input (`inp`, when `bound`); its release
  ## lets go of whatever the press held
  if pad notin h.pads: return
  if not pressed: h.pads[pad].buttons.del(button)
  elif bound: h.pads[pad].buttons[button] = inp

proc pad_stick*(h: var HeldInput; pad: int32; dir: Input; active: bool) =
  ## One direction of this pad's left stick, past the deadzone or not
  if pad notin h.pads: return
  if active: h.pads[pad].stick.incl dir
  else: h.pads[pad].stick.excl dir

proc pad_trigger*(h: var HeldInput; pad: int32; on: bool) =
  if pad notin h.pads: return
  h.pads[pad].trigger = on

proc trigger_held*(h: HeldInput): bool =
  for pad in h.pads.values:
    if pad.trigger: return true
  false

proc apply_trigger*(h: var HeldInput; s: var Speed; linked: bool) =
  ## The right trigger is fast forward while held, from any pad. A pull
  ## while fast forward is already on (Tab latched it) or while linked (it
  ## would run ahead of the peer) changes nothing, and neither does its
  ## release. A pull clears 2x Speed, as the menu's radio does; the release
  ## brings back the speed before the pull, unless the speed was changed
  ## during the hold.
  let pulled = h.trigger_held()
  if pulled == h.trigger_seen: return
  h.trigger_seen = pulled
  if pulled:
    if not s.sync or linked: return
    h.trigger_ff = true
    h.turbo_before = s.turbo
    s.sync = false
    s.turbo = false
  elif h.trigger_ff:
    h.trigger_ff = false
    if not s.sync:
      s.sync = true
      s.turbo = h.turbo_before
