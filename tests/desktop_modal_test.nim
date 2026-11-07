## The app's modal notices (src/dingbat/frontend/notice.nim: Open ROM, State,
## Settings, Save file) in a real Dear ImGui context with no window: Return,
## keypad Enter and Escape close a notice as OK does; a key pressed on the
## frame a notice appears, or the press that closed the one before it, does
## not; a held key closes one notice at most; and the keyboard is ImGui's
## (WantCaptureKeyboard) for as long as one is up, which is what keeps the
## key from the game (held_input.nim `modal_key_of`, desktop_input_test).
## And every string the desktop draws has its characters in ImGui's built-in
## font (no em dash, curly quote or "…": those draw as "?"): src/dingbat.nim
## and every src/dingbat/frontend file, found at compile time, and by hand
## the core files whose messages it shows (CORE_SOURCES).
##
## Needs imguin (its C++ compiles into this binary; nothing else of the GUI:
## no SDL, no GL). CI's test job installs it (.github/scripts/
## install-test-deps.sh); also `nimble test_desktop`.

import std/[algorithm, macros, os, strutils, unicode]
import imguin/cimgui
import dingbat/frontend/notice

const SRC = currentSourcePath().parentDir.parentDir / "src"

const CORE_SOURCES = [
  # Shared with the web. Their messages reach the desktop's notices (State,
  # Settings, Save file), the Cheats window's error and the Link Cable
  # window; the desktop's own UI (src/dingbat.nim, every frontend file) is
  # listed at compile time.
  "dingbat/common/atomicfile.nim", "dingbat/common/cheats.nim",
  "dingbat/common/config.nim", "dingbat/common/fastpack.nim",
  "dingbat/common/linkproto.nim", "dingbat/common/lz4.nim",
  "dingbat/common/scheduler.nim", "dingbat/common/serialize.nim",
  "dingbat/gb/savestate.nim",
  "dingbat/gba/netcore.nim", "dingbat/gba/netlink.nim",
  "dingbat/gba/savestate.nim",
  "dingbat/nds/cheats.nim", "dingbat/nds/savestate.nim"]

proc scan_literals(n: NimNode; file: string; found: var NimNode) =
  ## Every non-ASCII string literal under n, as (file, line, text), but for
  ## echo arguments, triple-quoted (GLSL) sources and pragmas.
  case n.kind
  of nnkStrLit, nnkRStrLit:
    var ascii = true
    for c in n.strVal:
      if c.ord >= 0x80: ascii = false
    if not ascii:
      found.add newTree(nnkTupleConstr, newLit(file),
                        newLit(n.lineInfoObj.line), newLit(n.strVal))
  of nnkTripleStrLit, nnkPragma, nnkCommentStmt:
    discard
  of nnkCommand, nnkCall:
    if n[0].kind == nnkIdent and n[0].strVal in ["echo", "debugEcho"]:
      return
    for c in n: scan_literals(c, file, found)
  else:
    for c in n: scan_literals(c, file, found)

macro ui_string_literals(): untyped =
  ## The UI sources parsed (not compiled) at compile time.
  var files = @["dingbat.nim"]
  var frontend: seq[string]
  for kind, path in walkDir(SRC / "dingbat" / "frontend"):
    if kind == pcFile and path.endsWith(".nim"):
      frontend.add "dingbat/frontend/" & path.extractFilename
  doAssert frontend.len > 0, "no frontend sources under " & SRC
  frontend.sort()
  files.add frontend
  files.add CORE_SOURCES
  result = newNimNode(nnkBracket)
  for f in files:
    let tree = parseStmt(staticRead(SRC / f), f)
    scan_literals(tree, f, result)
  if result.len == 0:
    result = quote do: newSeq[(string, int, string)]()
  else:
    result = newCall(bindSym"@", result)

# imgui.cpp's default Windows IME hooks call imm32; the GUI build links it
# through nim.cfg, which -d:test_harness leaves out.
when defined(windows):
  {.passL: "-limm32".}

discard igCreateContext(nil)
let io = igGetIO_Nil()
io.DisplaySize = ImVec2(x: 800, y: 600)
io.DeltaTime = 1.0 / 60.0
# The atlas is built by ImGui itself and handed to a renderer that is not
# there; nothing here draws.
io.BackendFlags = io.BackendFlags or cint(ImGui_BackendFlags_RendererHasTextures)
discard ImFontAtlas_AddFontDefault(io.Fonts, nil)

var first, first_hint, second, second_hint: string
var wants_keyboard = false

proc frame(n = 1) =
  ## One iteration of the app's present phase, as render_imgui orders them:
  ## the second notice waits for the first (render_load_notice).
  for _ in 0 ..< n:
    igNewFrame()
    wants_keyboard = io.WantCaptureKeyboard
    render_notice("State##notice", first, first_hint)
    if first.len == 0:
      render_notice("Open ROM##notice", second, second_hint)
    igRender()

proc key(k: ImGuiKey; down: bool) = ImGuiIO_AddKeyEvent(io, k, down)

proc tap(k: ImGuiKey) =
  key(k, true); frame()
  key(k, false); frame()

for k in [ImGui_Key_Enter, ImGui_Key_KeypadEnter, ImGui_Key_Escape]:
  first = "No quick save yet."
  first_hint = "Slot 0 is empty."
  frame(3)
  doAssert first.len > 0 and wants_keyboard
  tap(k)
  doAssert first == "" and first_hint == "", $k & " left the notice up"
  frame(2)
  doAssert not wants_keyboard, "the keyboard stayed ImGui's after the notice"

block pressed_as_it_appears:
  # The game's Start (Return) pressed on the frame a battery notice pops up
  first = "Can't write the save file."
  key(ImGui_Key_Enter, true)
  frame()
  key(ImGui_Key_Enter, false)
  frame(3)
  doAssert first.len > 0, "a press from before the notice closed it"
  tap(ImGui_Key_Escape)
  doAssert first == ""

block queued_notice_survives:
  # One Return closes the notice in front; the one queued behind it opens
  # that frame and stays until a press of its own
  first = "A state from another game."
  second = "Couldn't load game.gb."
  frame(3)
  tap(ImGui_Key_Enter)
  doAssert first == ""
  frame(3)
  doAssert second.len > 0, "the Return that closed the first notice closed the second"
  doAssert wants_keyboard
  tap(ImGui_Key_Enter)
  doAssert second == ""

block held_key_closes_one:
  first = "One."
  second = "Two."
  frame(3)
  key(ImGui_Key_Escape, true)
  frame(120)                      # two seconds held: key repeats
  key(ImGui_Key_Escape, false)
  frame()
  doAssert first == "" and second.len > 0, "a held Escape closed both"
  tap(ImGui_Key_Escape)
  doAssert second == ""

block nothing_else_closes:
  # No key, no click: it waits
  first = "Still here."
  frame(30)
  doAssert first.len > 0

block every_ui_string_has_a_glyph:
  # The desktop draws with ImGui's built-in ProggyClean (it loads no other),
  # which has U+0020-00FF and little else: an em dash, a curly quote or "…"
  # draws as "?". Every string literal in the desktop's UI sources, and in
  # the core files whose messages it shows (a State notice, a cheat's error,
  # the Link Cable window's "Handshake failed: ..."), must have each
  # character in that font. Log lines (echo), GLSL sources ("""...""") and
  # compile-time pragmas never reach ImGui and are skipped.
  frame()
  let font = igGetFont()
  var missing: seq[string]
  for (file, line, s) in ui_string_literals():
    for r in s.runes:
      if r.int > 0xFFFF or not ImFont_IsGlyphInFont(font, ImWchar(r.int)):
        missing.add file & ":" & $line & ": U+" & r.int.toHex(4) &
                    " in \"" & s & "\""
        break
  doAssert missing.len == 0,
    "characters the desktop's font can't draw:\n  " & missing.join("\n  ")

igDestroyContext(nil)
echo "ok"
