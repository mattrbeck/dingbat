## Drive the desktop app from outside, as a user would: keys, mouse, text,
## file drops, window events, and screenshots of the whole window (menus
## and dialogs included). Built only with -d:gui_driver; nothing here exists
## in a normal build.
##
## DINGBAT_DRIVE=<dir> names a directory. Append lines to <dir>/cmd; each
## is `<id> <command> [args]`, run in order, one step per loop iteration,
## and acknowledged as `<id> ok` (or `<id> error <why>`) in <dir>/ack:
##
##   key <name> down|up [cmd] [ctrl] [shift] [alt] [repeat]
##                                     name as SDL_GetKeyFromName ("S", "Left",
##                                     "Return", "Tab", "`", "F12"), `_` for a
##                                     space, or a raw keycode (0x400000E3 = LGUI)
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
##
## The window is created hidden, so the user's real mouse and keyboard never
## reach it and it never takes focus from what they are doing; the menu bar,
## which normally shows only while the mouse is over the window, shows while
## the driver's mouse is in it.

import std/[os, strutils]
import sdl2
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
  wait_until = 0'u32
  shot_path = ""
  shot_id = ""
  mouse_x, mouse_y: cint
  mouse_in* = false
  dropped* = ""       # a `drop` path for handle_input (a pushed SDL drop
                      # event cannot own its path under sdl2-compat)

proc driver_enabled*(): bool = drive_dir.len > 0

proc driver_init*() =
  drive_dir = getEnv("DINGBAT_DRIVE")
  if drive_dir.len > 0:
    createDir(drive_dir)
    writeFile(drive_dir / "ack", "")
    if not fileExists(drive_dir / "cmd"): writeFile(drive_dir / "cmd", "")

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
  if pushEvent(addr e) < 0:
    raise newException(IOError, "SDL_PushEvent: " & $getError())

proc push_key(window: WindowPtr; w: seq[string]) =
  if w.len < 3: raise newException(ValueError, "key <name> down|up")
  let sym = if w[1].startsWith("0x"): cint(parseHexInt(w[1]))   # raw SDL keycode
            else: getKeyFromName(cstring(w[1].replace('_', ' ')))  # Left_Shift
  if sym == 0: raise newException(ValueError, "unknown key " & w[1])
  var mods = 0'i16
  var repeat = false
  for m in w[3 .. ^1]:
    case m
    of "cmd": mods = mods or 0x0400'i16      # KMOD_LGUI
    of "ctrl": mods = mods or 0x0040'i16     # KMOD_LCTRL
    of "shift": mods = mods or 0x0001'i16    # KMOD_LSHIFT
    of "alt": mods = mods or 0x0100'i16      # KMOD_LALT
    of "repeat": repeat = true
    else: raise newException(ValueError, "unknown modifier " & m)
  var e: Event
  let k = cast[KeyboardEventPtr](addr e)
  let down = w[2] == "down"
  k.kind = if down: KeyDown else: KeyUp
  k.windowID = window.getID()
  k.state = if down: 1 else: 0
  k.repeat = repeat
  k.keysym.sym = sym
  k.keysym.scancode = getScancodeFromKey(sym)
  k.keysym.modstate = mods
  push(e)

proc push_text(window: WindowPtr; s: string) =
  var e: Event
  let t = cast[TextInputEventPtr](addr e)
  t.kind = TextInput
  t.windowID = window.getID()
  for i, c in s:
    if i >= t.text.len - 1: break
    t.text[i] = c
  push(e)

proc push_motion(window: WindowPtr; x, y: cint) =
  var e: Event
  let m = cast[MouseMotionEventPtr](addr e)
  m.kind = MouseMotion
  m.windowID = window.getID()
  m.x = x
  m.y = y
  m.xrel = x - mouse_x
  m.yrel = y - mouse_y
  mouse_x = x
  mouse_y = y
  mouse_in = true
  push(e)

proc push_button(window: WindowPtr; x, y: cint; down, right: bool) =
  var e: Event
  let b = cast[MouseButtonEventPtr](addr e)
  b.kind = if down: MouseButtonDown else: MouseButtonUp
  b.windowID = window.getID()
  b.button = if right: 3 else: 1
  b.state = if down: 1 else: 0
  b.clicks = 1
  b.x = x
  b.y = y
  push(e)

proc push_window(window: WindowPtr; what: string) =
  var e: Event
  let w = cast[WindowEventPtr](addr e)
  w.kind = WindowEvent
  w.windowID = window.getID()
  w.event = case what
    of "focus_lost": WindowEvent_FocusLost
    of "focus_gained": WindowEvent_FocusGained
    of "close": WindowEvent_Close
    else: raise newException(ValueError, "unknown window event " & what)
  push(e)

proc run(window: WindowPtr; s: Step): bool =
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
    let m = cast[MouseWheelEventPtr](addr e)
    m.kind = MouseWheel
    m.windowID = window.getID()
    m.y = cint(parseInt(w[1]))
    push(e)
  of "drop":
    dropped = s.rest  # handle_input takes it where SDL's drop would arrive
  of "window": push_window(window, w[1])
  of "quit":
    var e: Event
    e.kind = QuitEvent
    push(e)
  of "frames":
    wait_frames = parseInt(w[1])
    return false
  of "sleep":
    wait_until = getTicks() + uint32(parseInt(w[1]))
    return false
  of "shot":
    shot_path = w[1]
    shot_id = s.id
    return false
  else: raise newException(ValueError, "unknown command " & w[0])
  true

var waiting: Step
var is_waiting = false

proc driver_poll*(window: WindowPtr) =
  ## Top of every loop iteration: run steps until one has to wait.
  if drive_dir.len == 0: return
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
        if s.id.len > 0 and s.words[0] != "click": ack(s.id, "ok")
      else:
        waiting = s
        is_waiting = true
        return
    except CatchableError as e:
      if s.id.len > 0: ack(s.id, "error " & e.msg)

proc driver_frame*(window: WindowPtr) =
  ## After the UI is drawn, before the swap: take a pending screenshot.
  if shot_path.len == 0: return
  var w, h: cint
  window.glGetDrawableSize(w, h)
  var pix = newSeq[byte](int(w) * int(h) * 3)
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  glReadPixels(0, 0, GLsizei(w), GLsizei(h), GL_RGB, GL_UNSIGNED_BYTE, addr pix[0])
  var flipped = newSeq[byte](pix.len)
  let stride = int(w) * 3
  for row in 0 ..< int(h):
    copyMem(addr flipped[row * stride], addr pix[(int(h) - 1 - row) * stride], stride)
  var ww, wh: cint
  window.getSize(ww, wh)
  if stbiw.writePNG(shot_path, int(w), int(h), 3, flipped):
    ack(shot_id, "ok " & $w & "x" & $h & " px, window " & $ww & "x" & $wh & " pt")
  else:
    ack(shot_id, "error could not write " & shot_path)
  shot_path = ""
