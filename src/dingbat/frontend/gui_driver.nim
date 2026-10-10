## Drive the desktop app from outside, as a user would: keys, mouse, text,
## file drops, window events, and screenshots of the whole window (menus
## and dialogs included). Built only with -d:gui_driver; nothing here exists
## in a normal build.
##
## DINGBAT_DRIVE=<dir> names a directory. Append lines to <dir>/cmd; each
## is `<id> <command> [args]`, run in order, one step per loop iteration,
## and acknowledged as `<id> ok` (or `<id> error <why>`) in <dir>/ack:
##
##   key <name> down|up [cmd] [ctrl] [shift] [alt] [caps] [repeat]
##                                     name as SDL_GetKeyFromName ("S", "Left",
##                                     "Return", "Tab", "`", "F12"), `_` for a
##                                     space, or a raw keycode (0x400000E3 = LGUI;
##                                     0x5A = 'Z', the key SDL 3 reports for z
##                                     under Shift or Caps Lock)
##   text <utf-8>                      text typed into a focused field
##   move <x> <y>                      mouse to window point (x, y)
##   down <x> <y> [right] / up <x> <y> [right]
##   click <x> <y> [right]             move, down, a few frames, up
##   wheel <dy>
##   drop <path>                       a file dropped on the window
##   window focus_lost|focus_gained|close
##   quit                              the window's close box / Cmd+Q path
##   frames <n>                        let n loop iterations run
##   sleep <ms>
##   shot <path.png>                   the next presented frame, whole window
##   state                             acked `ok fullscreen=0|1 window=WxH`
##   show                              show the window (fullscreen needs it)
##   fullscreen os                     macOS: AppKit's own toggle, what the
##                                     green button and Ctrl+Cmd+F do
##   pad attach                        plug in a virtual SDL gamepad
##   pad button <n> down|up            press/release its button n (SDL order)
##   pad axis <n> <value>              move its axis n (-32768..32767)
##   pad rumble                        acked `ok rumbles=<n> on=0|1`: rumble
##                                     requests it took, and whether the last
##                                     one was a buzz (not a stop)
##   pad detach                        unplug it
##
## The window is created hidden, so the user's real mouse and keyboard never
## reach it and it never takes focus from what they are doing; the menu bar,
## which normally shows only while the mouse is over the window, shows while
## the driver's mouse is in it.

import std/[os, strutils]
import sdl3
import imguin/glad/gl
import stb_image/write as stbiw

type
  Step = object
    id: string
    words: seq[string]
    rest: string      # the line after the command word, for `text`/`drop`

var
  drive_dir = ""
  cmd_pos = 0
  pending: seq[Step]
  wait_frames = 0
  wait_until = 0'u64
  shot_path = ""
  shot_id = ""
  mouse_x, mouse_y: cint
  mouse_in* = false
  dropped* = ""       # a `drop` path for handle_input (a pushed SDL drop
                      # event cannot own its path)
  texts: seq[string]  # `text` strings, alive until handle_input has read them
  pad_id: JoystickID  # the virtual gamepad (0 = none)
  pad_joy: Joystick
  pad_rumbles = 0     # rumble requests it took
  pad_rumble_on = false

proc pad_rumble_cb(userdata: pointer; low, high: uint16): bool {.cdecl.} =
  inc pad_rumbles
  pad_rumble_on = low != 0 or high != 0
  true

when defined(macosx):
  proc sel_registerName(name: cstring): pointer
    {.importc, header: "<objc/runtime.h>".}
  proc objc_msgSend() {.importc, header: "<objc/message.h>".}

  proc ns_toggle_fullscreen(window: Window) =
    ## `[nswindow toggleFullScreen:nil]`: the green button's own action.
    type Send = proc (self, op, arg: pointer) {.cdecl.}
    let ns = getPointerProperty(getWindowProperties(window),
                                PROP_WINDOW_COCOA_WINDOW_POINTER, nil)
    if ns == nil: raise newException(IOError, "no NSWindow")
    cast[Send](objc_msgSend)(ns, sel_registerName("toggleFullScreen:"), nil)

proc pad_cmd(w: seq[string]): string =
  ## A virtual gamepad, so hotplug, buttons, sticks and rumble go through
  ## SDL's own gamepad events. Returns the ack text.
  case w[1]
  of "attach":
    if pad_id != 0: raise newException(ValueError, "pad already attached")
    var desc = VirtualJoystickDesc(version: uint32(sizeof(VirtualJoystickDesc)),
                                   `type`: uint16(JOYSTICK_TYPE_GAMEPAD),
                                   naxes: 6, nbuttons: 15,
                                   button_mask: (1u32 shl 15) - 1, axis_mask: (1u32 shl 6) - 1,
                                   name: "dingbat virtual pad",
                                   Rumble: pad_rumble_cb)
    pad_id = attachVirtualJoystick(addr desc)
    if pad_id == 0: raise newException(IOError, "attach: " & $getError())
    pad_joy = openJoystick(pad_id)
    pad_rumbles = 0
    pad_rumble_on = false
    "ok id=" & $pad_id
  of "button":
    if not setJoystickVirtualButton(pad_joy, cint(parseInt(w[2])), w[3] == "down"):
      raise newException(IOError, $getError())
    "ok"
  of "axis":
    if not setJoystickVirtualAxis(pad_joy, cint(parseInt(w[2])), int16(parseInt(w[3]))):
      raise newException(IOError, $getError())
    "ok"
  of "rumble":
    "ok rumbles=" & $pad_rumbles & " on=" & $ord(pad_rumble_on)
  of "detach":
    closeJoystick(pad_joy)
    discard detachVirtualJoystick(pad_id)
    pad_id = 0
    "ok"
  else: raise newException(ValueError, "unknown pad command " & w[1])

proc driver_enabled*(): bool = drive_dir.len > 0

proc driver_init*() =
  drive_dir = getEnv("DINGBAT_DRIVE")
  if drive_dir.len > 0:
    createDir(drive_dir)
    writeFile(drive_dir / "ack", "")
    if not fileExists(drive_dir / "cmd"): writeFile(drive_dir / "cmd", "")
    # The hidden window never has keyboard focus, and without it SDL drops
    # gamepad presses (releases still pass)
    discard setHint(HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1")

proc ack(id, msg: string) =
  let f = open(drive_dir / "ack", fmAppend)
  f.writeLine(id & " " & msg)
  f.close()

proc read_new_lines() =
  let path = drive_dir / "cmd"
  let data = readFile(path)
  if data.len <= cmd_pos: return
  var last_nl = data.rfind('\n')
  if last_nl < cmd_pos: return  # a line still being written
  for line in data[cmd_pos .. last_nl].splitLines():
    let t = line.strip()
    if t.len == 0: continue
    let parts = t.splitWhitespace()
    if parts.len < 2:
      ack(parts[0], "error no command")
      continue
    let head = parts[0] & " " & parts[1]
    let rest = if t.len > head.len: t[head.len .. ^1].strip() else: ""
    pending.add Step(id: parts[0], words: parts[1 .. ^1], rest: rest)
  cmd_pos = last_nl + 1

proc push(e: var Event) =
  if not pushEvent(e):
    raise newException(IOError, "SDL_PushEvent: " & $getError())

proc push_key(window: Window; w: seq[string]) =
  if w.len < 3: raise newException(ValueError, "key <name> down|up")
  let sym = if w[1].startsWith("0x"): Keycode(parseHexInt(w[1]))   # raw SDL keycode
            else: getKeyFromName(cstring(w[1].replace('_', ' ')))  # Left_Shift
  if sym == 0: raise newException(ValueError, "unknown key " & w[1])
  var mods = Keymod(0)
  var repeat = false
  for m in w[3 .. ^1]:
    case m
    of "cmd": mods = mods or Keymod(KMOD_LGUI)
    of "ctrl": mods = mods or Keymod(KMOD_LCTRL)
    of "shift": mods = mods or Keymod(KMOD_LSHIFT)
    of "alt": mods = mods or Keymod(KMOD_LALT)
    of "caps": mods = mods or Keymod(KMOD_CAPS)
    of "repeat": repeat = true
    else: raise newException(ValueError, "unknown modifier " & m)
  var e: Event
  let down = w[2] == "down"
  e.key.type = if down: EVENT_KEY_DOWN else: EVENT_KEY_UP
  e.key.windowID = window.getWindowID()
  e.key.down = down
  e.key.repeat = repeat
  e.key.key = sym
  var no_mods = Keymod(0)
  e.key.scancode = getScancodeFromKey(sym, no_mods)
  e.key.mod = mods
  push(e)

proc push_text(window: Window; s: string) =
  texts.add s
  var e: Event
  e.text.type = EVENT_TEXT_INPUT
  e.text.windowID = window.getWindowID()
  e.text.text = cstring(texts[^1])
  push(e)

proc push_motion(window: Window; x, y: cint) =
  var e: Event
  e.motion.type = EVENT_MOUSE_MOTION
  e.motion.windowID = window.getWindowID()
  e.motion.x = cfloat(x)
  e.motion.y = cfloat(y)
  e.motion.xrel = cfloat(x - mouse_x)
  e.motion.yrel = cfloat(y - mouse_y)
  mouse_x = x
  mouse_y = y
  mouse_in = true
  push(e)

proc push_button(window: Window; x, y: cint; down, right: bool) =
  var e: Event
  e.button.type = if down: EVENT_MOUSE_BUTTON_DOWN else: EVENT_MOUSE_BUTTON_UP
  e.button.windowID = window.getWindowID()
  e.button.button = if right: 3 else: 1
  e.button.down = down
  e.button.clicks = 1
  e.button.x = cfloat(x)
  e.button.y = cfloat(y)
  push(e)

proc push_window(window: Window; what: string) =
  var e: Event
  e.window.type = case what
    of "focus_lost": EVENT_WINDOW_FOCUS_LOST
    of "focus_gained": EVENT_WINDOW_FOCUS_GAINED
    of "close": EVENT_WINDOW_CLOSE_REQUESTED
    else: raise newException(ValueError, "unknown window event " & what)
  e.window.windowID = window.getWindowID()
  push(e)

proc run(window: Window; s: Step): bool =
  ## One step. False when it must wait (the ack comes later).
  let w = s.words
  case w[0]
  of "key": push_key(window, w)
  of "text": push_text(window, s.rest)
  of "move": push_motion(window, cint(parseInt(w[1])), cint(parseInt(w[2])))
  of "down", "up":
    let x = cint(parseInt(w[1]))
    let y = cint(parseInt(w[2]))
    push_motion(window, x, y)
    push_button(window, x, y, w[0] == "down", w.len > 3 and w[3] == "right")
  of "click":
    let x = cint(parseInt(w[1]))
    let y = cint(parseInt(w[2]))
    let right = w.len > 3 and w[3] == "right"
    push_motion(window, x, y)
    push_button(window, x, y, true, right)
    # the release a few frames later, as a hand would
    pending.insert(Step(id: "", words: @["up", w[1], w[2]] &
                        (if right: @["right"] else: @[])), 0)
    pending.insert(Step(id: "", words: @["frames", "3"]), 0)
    pending.insert(Step(id: "", words: @["frames", "3"]), 0)
    ack(s.id, "ok")
    return true
  of "wheel":
    var e: Event
    e.wheel.type = EVENT_MOUSE_WHEEL
    e.wheel.windowID = window.getWindowID()
    e.wheel.y = cfloat(parseInt(w[1]))
    push(e)
  of "drop":
    dropped = s.rest  # handle_input takes it where SDL's drop would arrive
  of "window": push_window(window, w[1])
  of "quit":
    var e: Event
    e.quit.type = EVENT_QUIT
    push(e)
  of "frames":
    wait_frames = parseInt(w[1])
    return false
  of "sleep":
    wait_until = getTicks() + uint64(parseInt(w[1]))
    return false
  of "shot":
    shot_path = w[1]
    shot_id = s.id
    return false
  of "state":
    var ww, wh: cint
    discard window.getWindowSize(ww, wh)
    let fs = (getWindowFlags(window) and WINDOW_FULLSCREEN) != 0
    ack(s.id, "ok fullscreen=" & $ord(fs) & " window=" & $ww & "x" & $wh)
    return true
  of "show":
    discard showWindow(window)
  of "fullscreen":
    when defined(macosx): ns_toggle_fullscreen(window)
    else: raise newException(ValueError, "fullscreen os: macOS only")
  of "pad":
    ack(s.id, pad_cmd(w))
    return true
  else: raise newException(ValueError, "unknown command " & w[0])
  true

var waiting: Step
var is_waiting = false

proc driver_poll*(window: Window) =
  ## Top of every loop iteration: run steps until one has to wait.
  if drive_dir.len == 0: return
  texts.setLen(0)   # last iteration's handle_input has read them
  if is_waiting:
    if waiting.words[0] == "frames":
      if wait_frames > 0: dec wait_frames
      if wait_frames > 0: return
    elif waiting.words[0] == "sleep":
      if getTicks() < wait_until: return
    elif waiting.words[0] == "shot":
      if shot_path.len > 0: return   # driver_frame acks it
    if waiting.id.len > 0 and waiting.words[0] != "shot": ack(waiting.id, "ok")
    is_waiting = false
  read_new_lines()
  while pending.len > 0:
    let s = pending[0]
    pending.delete(0)
    try:
      if run(window, s):
        if s.id.len > 0 and s.words[0] notin ["click", "state", "pad"]: ack(s.id, "ok")
      else:
        waiting = s
        is_waiting = true
        return
    except CatchableError as e:
      if s.id.len > 0: ack(s.id, "error " & e.msg)

proc driver_frame*(window: Window) =
  ## After the UI is drawn, before the swap: take a pending screenshot.
  if shot_path.len == 0: return
  var w, h: cint
  discard window.getWindowSizeInPixels(w, h)
  var pix = newSeq[byte](int(w) * int(h) * 3)
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  glReadPixels(0, 0, GLsizei(w), GLsizei(h), GL_RGB, GL_UNSIGNED_BYTE, addr pix[0])
  var flipped = newSeq[byte](pix.len)
  let stride = int(w) * 3
  for row in 0 ..< int(h):
    copyMem(addr flipped[row * stride], addr pix[(int(h) - 1 - row) * stride], stride)
  var ww, wh: cint
  discard window.getWindowSize(ww, wh)
  if stbiw.writePNG(shot_path, int(w), int(h), 3, flipped):
    ack(shot_id, "ok " & $w & "x" & $h & " px, window " & $ww & "x" & $wh & " pt")
  else:
    ack(shot_id, "error could not write " & shot_path)
  shot_path = ""
