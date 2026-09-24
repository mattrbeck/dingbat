## The app's modal notices (a sentence for the player, until OK) and the keys
## every modal answers: Return for its default button, Escape to close or
## cancel. Only the ImGui core here, no SDL or GL, so
## tests/desktop_modal_test.nim drives it headless.
##
## The game never sees these keys (held_input.nim `modal_key_of`).

import imguin/cimgui
import held_input
export ModalKey

proc modal_key*(): ModalKey =
  ## Inside a BeginPopupModal: this frame's Escape or Return, as the modal
  ## takes it (held_input.nim `modal_key_of`). Repeats are not presses, so a
  ## held key closes one modal at most.
  modal_key_of(appearing = igIsWindowAppearing(),
               escape = igIsKeyPressed_Bool(ImGui_Key_Escape, false),
               enter = igIsKeyPressed_Bool(ImGui_Key_Enter, false) or
                       igIsKeyPressed_Bool(ImGui_Key_KeypadEnter, false))

proc render_notice*(popup: string; text, hint: var string) =
  ## A modal sentence for the user, until OK, Return, Escape or the X clears
  ## `text`.
  if text.len == 0:
    # Cleared from outside (a battery write landed): ImGui keeps a popup
    # open until it is closed from inside it.
    if igIsPopupOpen_Str(cstring(popup), 0) and
       igBeginPopupModal(cstring(popup), nil,
                         cint(ImGui_WindowFlags_AlwaysAutoResize)):
      igCloseCurrentPopup()
      igEndPopup()
    return
  if not igIsPopupOpen_Str(cstring(popup), 0):
    igOpenPopup_Str(cstring(popup), 0)
  var center = ImVec2(x: 0, y: 0)
  let vp = igGetMainViewport()
  if vp != nil:
    when compiles(ImGuiViewport_GetCenter(addr center, vp)):
      ImGuiViewport_GetCenter(addr center, vp)
    else:
      let c = ImGuiViewport_GetCenter(vp)
      center = ImVec2(x: c.x, y: c.y)
  igSetNextWindowPos(center, cint(ImGui_Cond_Appearing), ImVec2(x: 0.5, y: 0.5))
  igSetNextWindowSizeConstraints(ImVec2(x: 380, y: 0), ImVec2(x: 560, y: 400),
                                 nil, nil)
  var stay_open = true
  if igBeginPopupModal(cstring(popup), addr stay_open,
                       cint(ImGui_WindowFlags_AlwaysAutoResize)):
    igPushTextWrapPos(0)
    igTextUnformatted(cstring(text), nil)
    if hint.len > 0:
      igSpacing()
      # Through "%s", not as the format string: the hint carries core wording
      # built from the FILE's own bytes, and a '%' in there would read
      # arguments that were never pushed.
      igTextDisabled("%s", cstring(hint))
    igPopTextWrapPos()
    igSpacing()
    # OK is the only button: Return and Escape both mean it
    if igButton("OK", ImVec2(x: 120, y: 0)) or modal_key() != mkNone:
      text = ""
      hint = ""
      igCloseCurrentPopup()
    igEndPopup()
  if not stay_open:
    text = ""
    hint = ""
