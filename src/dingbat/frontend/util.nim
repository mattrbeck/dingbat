import imguin/[cimgui, impl_opengl, impl_sdl3]

# Display a "(?)" mark which shows a tooltip when hovered.
proc help_marker*(desc: string) =
  igTextDisabled("(?)")
  if igIsItemHovered(0):
    if igBeginTooltip():
      igPushTextWrapPos(igGetFontSize() * 35.0'f32)
      igTextUnformatted(cstring(desc), nil)
      igPopTextWrapPos()
      igEndTooltip()
