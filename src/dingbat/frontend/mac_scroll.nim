## Trackpad scrolling at the finger's speed in ImGui's windows (mac_scroll.m).
## Points scroll by as many points; a wheel mouse's line by 40, as Safari
## scrolls the web home screen.

import std/math
import sdl3
import imguin/cimgui

{.compile("mac_scroll.m", "-fobjc-arc").}

{.push cdecl, importc.}
proc dbsc_install(nswindow: pointer)
proc dbsc_take(px, py, lx, ly: var cdouble): cint
proc dbsc_feed*(dy: cdouble; precise: cint): cint
{.pop.}

const LINE_PT = 40.0

proc mac_scroll_install*(window: Window) =
  dbsc_install(getPointerProperty(getWindowProperties(window),
                                  PROP_WINDOW_COCOA_WINDOW_POINTER, nil))

proc mac_scroll_feed*() =
  ## Before ImGui's frame: the scroll since the last as wheel steps, sized to
  ## the window ImGui will scroll (its step is 5 lines of its font down, 2
  ## across, at most two thirds of the window).
  var px, py, lx, ly: cdouble
  if dbsc_take(px, py, lx, ly) == 0: return
  let g = igGetCurrentContext()
  let w = if g.WheelingWindow != nil: g.WheelingWindow else: g.HoveredWindow
  let st = igGetStyle()
  let fs = if w != nil: w.FontRefSize else: st.FontSizeBase * st.FontScaleDpi
  var step_y = 5 * fs
  var step_x = 2 * fs
  if w != nil:
    step_y = min(step_y, (w.InnerRect.Max.y - w.InnerRect.Min.y) * 0.67)
    step_x = min(step_x, (w.InnerRect.Max.x - w.InnerRect.Min.x) * 0.67)
  step_y = max(1, trunc(step_y))
  step_x = max(1, trunc(step_x))
  ImGuiIO_AddMouseWheelEvent(igGetIO_Nil(),
                             cfloat((px + lx * LINE_PT) / step_x),
                             cfloat((py + ly * LINE_PT) / step_y))
