import imguin/cimgui

var ui_scale* = 1.0'f32
  ## The menus' and windows' scale: the display's content scale where SDL
  ## sizes windows in pixels (Windows at 125% or 150%, X11 with Xft.dpi),
  ## 1 on a Mac, whose pixel density covers it. The app sets it
  ## (apply_ui_scale); ImGui's own sizes and font follow from the style.

proc ui_px*(v: float32): float32 =
  ## A size the UI code spells in pixels at 100%, at the current scale.
  v * ui_scale

proc help_marker*(desc: string) =
  igTextDisabled("(?)")
  if igIsItemHovered(0):
    if igBeginTooltip():
      igPushTextWrapPos(igGetFontSize() * 35.0'f32)
      igTextUnformatted(cstring(desc), nil)
      igPopTextWrapPos()
      igEndTooltip()
