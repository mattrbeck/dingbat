## The app's modal notices (src/dingbat/frontend/notice.nim: a game that
## won't open, State, Settings, Save file) in a real Dear ImGui context with
## no window: Return, keypad Enter and Escape close a notice as OK does; a
## key pressed on the frame a notice appears, or the press that closed the
## one before it, does not; a held key closes one notice at most; and the
## keyboard is ImGui's (WantCaptureKeyboard) for as long as one is up, which
## is what keeps the key from the game (held_input.nim `modal_key_of`,
## desktop_input_test).
## And every string the desktop draws has its characters in every UI font it
## may draw with (ui_fonts.nim): this platform's (SF on macOS, Segoe UI on
## Windows) and the bundled Inter and JetBrains Mono, which Linux and
## Windows' fallback use; a character one lacks draws as "?" (stb_truetype
## answers here; FreeType reads the same character map). src/dingbat.nim
## and every file under src/dingbat, found at compile time (the core's
## messages reach the notices, the Cheats and Link Cable windows too).
##
## Needs imguin (its C++ compiles into this binary; nothing else of the GUI:
## no SDL, no GL). CI's test job installs it (.github/scripts/
## install-test-deps.sh); also `nimble test_desktop`.

import std/[algorithm, macros, os, strutils, unicode]
import imguin/cimgui
import dingbat/frontend/notice
import dingbat/frontend/ui_fonts

const SRC = currentSourcePath().parentDir.parentDir / "src"

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
  var below: seq[string]
  for path in walkDirRec(SRC / "dingbat"):
    if path.endsWith(".nim"):
      below.add path.relativePath(SRC).replace('\\', '/')
  doAssert below.len > 0, "no sources under " & SRC
  below.sort()
  files.add below
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
load_ui_fonts(io.Fonts)
# macOS builds no Inter or JetBrains Mono in (SF is always there); they are
# read from their files
when defined(macosx):
  let inter_data = [readFile(FONT_DIR / "Inter-Regular.ttf"),
                    readFile(FONT_DIR / "Inter-SemiBold.ttf")]
  let mono_data = readFile(FONT_DIR / "JetBrainsMono-Regular.ttf")
else:
  let inter_data = [INTER_REGULAR, INTER_SEMIBOLD]
  let mono_data = JETBRAINS_MONO
let inter = [io.Fonts.add_ttf(inter_data[0], "Inter"),
             io.Fonts.add_ttf(inter_data[1], "Inter SemiBold")]
let mono = io.Fonts.add_ttf(mono_data, "JetBrains Mono")
doAssert inter[0] != nil and inter[1] != nil, "the bundled Inter does not load"
doAssert mono != nil, "the bundled JetBrains Mono does not load"
igGetStyle().FontSizeBase = font_px(BODY_PX)

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
      render_notice("Couldn't open the game##notice", second, second_hint)
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
  # Every string literal in the desktop's UI sources, and in the core files
  # whose messages it shows (a State notice, a cheat's error, the Link Cable
  # window's "Handshake failed: ..."), must have each character in the
  # regular and semibold faces loaded here and in Inter: "…", curly quotes
  # and dashes are in all of them. The files that draw monospaced text (the
  # debug windows, Cheats) are checked against this platform's monospaced
  # face and JetBrains Mono too. Log lines (echo), GLSL sources
  # ("""...""") and compile-time pragmas never reach ImGui and are skipped.
  frame()
  echo "fonts: ", face_names.join(", "), ", Inter, Inter SemiBold, JetBrains Mono"
  var missing: seq[string]
  for (file, line, s) in ui_string_literals():
    var fonts = @[faces[fRegular], faces[fBold], inter[0], inter[1]]
    if file.endsWith("_debug.nim") or file.endsWith("cheats_widget.nim"):
      fonts.add [faces[fMono], mono]
    block one:
      for r in s.runes:
        for f in fonts:
          if r.int > 0xFFFF or not ImFont_IsGlyphInFont(f, ImWchar(r.int)):
            missing.add file & ":" & $line & ": U+" & r.int.toHex(4) &
                        " in \"" & s & "\""
            break one
  doAssert missing.len == 0,
    "characters a UI font can't draw:\n  " & missing.join("\n  ")
  # The check can fail: none of them has a CJK ideograph
  for f in [faces[fRegular], inter[0], mono]:
    doAssert not ImFont_IsGlyphInFont(f, ImWchar(0x4E00))

block the_fonts_load:
  # The system's faces where it has them, Inter otherwise; never none
  for f in Face: doAssert faces[f] != nil, $f & " did not load"
  when defined(macosx): doAssert face_names[fRegular] == "SF", face_names[fRegular]
  elif defined(windows): doAssert face_names[fRegular] == "Segoe UI", face_names[fRegular]
  else:
    doAssert face_names[fRegular] == "Inter", face_names[fRegular]
    doAssert face_names[fMono] == "JetBrains Mono", face_names[fMono]
  doAssert ttf_line_em(inter_data[0]) > 1 and ttf_line_em("not a font") == 0
  # Their capitals already sit in the middle of their lines (add_ttf moves
  # a font's that do not)
  for data in [inter_data[0], inter_data[1], mono_data]:
    doAssert abs(ttf_cap_low_em(data)) < 0.01, $ttf_cap_low_em(data)
  doAssert ttf_cap_low_em("not a font") == 0

igDestroyContext(nil)
echo "ok"
