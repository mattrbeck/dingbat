## The app's modal notices (src/dingbat/frontend/notice.nim: Open ROM, State,
## Settings, Save file) in a real Dear ImGui context with no window: Return,
## keypad Enter and Escape close a notice as OK does; a key pressed on the
## frame a notice appears, or the press that closed the one before it, does
## not; a held key closes one notice at most; and the keyboard is ImGui's
## (WantCaptureKeyboard) for as long as one is up, which is what keeps the
## key from the game (held_input.nim `modal_key_of`, desktop_input_test).
##
## Needs imguin (its C++ compiles into this binary; nothing else of the GUI:
## no SDL, no GL). CI's test job installs it (.github/scripts/
## install-test-deps.sh); also `nimble test_desktop`.

import imguin/cimgui
import dingbat/frontend/notice

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

igDestroyContext(nil)
echo "ok"
