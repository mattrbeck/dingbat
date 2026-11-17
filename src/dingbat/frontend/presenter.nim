## Draws the game picture and the UI into the window: Metal
## (presenter_metal.mm) on macOS, OpenGL 3.3 core (presenter_gl.nim) on
## Windows and Linux, chosen when building. One design for both: the same
## shader source (present_shader.nim), the same calls in the same order each
## present:
##
##   begin -> game_upload* -> draw_game | draw_logo -> [read] ->
##   imgui_new_frame ... imgui_render -> [read] -> present
##
## Rects are back-buffer pixels from the bottom left, as glViewport's.

import sdl3
import imguin/cimgui
import present_shader
import imgui_sdl3
export Look

type Backend* = enum pbGL, pbMetal

const backend* = when defined(macosx): pbMetal else: pbGL

when defined(macosx):
  import std/os
  import imgui_paths
  {.compile("vendor/imgui_impl_metal.mm", "-fobjc-arc").}
  {.compile("presenter_metal.mm", "-fobjc-arc").}
  {.passL: "-framework Metal -framework QuartzCore".}

  {.push cdecl, importc.}
  proc dbmtl_available(): cint
  proc dbmtl_init(layer: pointer; msl: cstring; readable, vsync: cint): cint
  proc dbmtl_device_name(): cstring
  proc dbmtl_logo_upload(px: pointer; w, h: cint)
  proc dbmtl_game_alloc(w, h: cint)
  proc dbmtl_game_upload(y0, w, h: cint; px: pointer)
  proc dbmtl_border_upload(px: pointer)
  proc dbmtl_begin(pw, ph: cint; r, g, b: cfloat)
  proc dbmtl_draw_game(x, y, w, h: cint; params: pointer)
  proc dbmtl_draw_logo(aspect, scale: cfloat)
  proc dbmtl_read(x, y, w, h: cint; rgb: ptr byte): cint
  proc dbmtl_present(): uint64
  proc dbmtl_shown_at(seq: uint64): cdouble
  proc dbmtl_waiting(): cint
  proc dbmtl_imgui_init()
  proc dbmtl_imgui_new_frame()
  proc dbmtl_imgui_render(dd: pointer)
  proc dbmtl_ui_texture(old: uint64; px: pointer; w, h, bgr555: cint): uint64
  proc dbmtl_ui_nearest(list: ptr ImDrawList; cmd: ptr ImDrawCmd)
  {.pop.}

  type MetalParams = object
    ## present_shader.nim's MSL Params block, byte for byte
    sgb_backdrop: array[4, float32]
    dmg_pal: array[16, float32]
    tex_width, tex_height, scan_width, scan_height: float32
    color_correct, panel_gbc, lcd_grid, subpixel, sgb_border, filter_mode,
      dmg_remap, pad0: int32

  var metal_view: MetalView
else:
  import presenter_gl

var frame_pw, frame_ph: int  # the present's back buffer, from begin

proc choose_backend*(): bool =
  ## Before the window: false if this machine cannot draw (macOS: no Metal
  ## device, which no Mac that runs macOS 11 lacks; a VM without a GPU might).
  when defined(macosx): dbmtl_available() != 0
  else: true

proc window_flags*(): uint64 =
  when defined(macosx): WINDOW_METAL
  else: gl_window_flags()

proc init*(window: Window; readable: bool): bool =
  ## After the window exists. `readable`: read() will be used (captures, the
  ## GUI driver), which a Metal layer must allow up front.
  when defined(macosx):
    metal_view = metal_CreateView(window)
    if metal_view == nil:
      echo "Failed to create a Metal view: ", $getError(); return false
    let vsync = getEnv("DINGBAT_METAL_VSYNC") != "0"
    dbmtl_init(metal_GetLayer(metal_view), cstring(PRESENT_MSL),
               cint(readable), cint(vsync)) != 0
  else:
    gl_init(window)

proc shutdown*() =
  when defined(macosx):
    if metal_view != nil: metal_DestroyView(metal_view)
  else:
    gl_shutdown()

proc logo_upload*(px: pointer; w, h: int) =
  when defined(macosx): dbmtl_logo_upload(px, cint(w), cint(h))
  else: gl_logo_upload(px, w, h)

proc game_alloc*(w, h: int) =
  ## The game texture's size: on a core load, and when a DS's HD scale moves.
  when defined(macosx): dbmtl_game_alloc(cint(w), cint(h))
  else: gl_game_alloc(w, h)

proc game_upload*(y0, w, h: int; px: pointer) =
  ## Rows y0 ..< y0+h of the game texture, BGR555 words. A present that
  ## uploads replaces the whole picture before it draws.
  when defined(macosx): dbmtl_game_upload(cint(y0), cint(w), cint(h), px)
  else: gl_game_upload(y0, w, h, px)

proc border_upload*(px: pointer) =
  ## The SGB border layer: 256x224 BGR555 words, bit 15 opaque.
  when defined(macosx): dbmtl_border_upload(px)
  else: gl_border_upload(px)

proc begin*(window: Window; r, g, b: float32) =
  ## Start a present: the whole back buffer cleared to (r, g, b).
  var pw, ph: cint
  discard getWindowSizeInPixels(window, pw, ph)
  frame_pw = int(pw)
  frame_ph = int(ph)
  when defined(macosx): dbmtl_begin(pw, ph, r, g, b)
  else: gl_begin(frame_pw, frame_ph, r, g, b)

proc draw_game*(x, y, w, h: int; look: Look) =
  when defined(macosx):
    var p = MetalParams(
      tex_width: look.tex_width, tex_height: look.tex_height,
      scan_width: look.scan_width, scan_height: look.scan_height,
      color_correct: int32(look.color_correct), panel_gbc: int32(look.panel_gbc),
      lcd_grid: int32(look.lcd_grid), subpixel: int32(look.subpixel),
      sgb_border: int32(look.sgb_border), filter_mode: int32(look.filter_mode),
      dmg_remap: int32(look.dmg_remap))
    for i in 0 .. 2: p.sgb_backdrop[i] = look.sgb_backdrop[i]
    for s in 0 .. 3:
      for i in 0 .. 2: p.dmg_pal[s * 4 + i] = look.dmg_pal[s * 3 + i]
    dbmtl_draw_game(cint(x), cint(y), cint(w), cint(h), addr p)
  else:
    gl_draw_game(x, y, w, h, frame_pw, frame_ph, look)

proc draw_logo*(aspect, scale: float32) =
  ## The home screen's logo over the whole window, alpha-blended.
  when defined(macosx): dbmtl_draw_logo(aspect, scale)
  else: gl_draw_logo(aspect, scale)

proc read*(x, y, w, h: int): seq[byte] =
  ## What this present has drawn so far in (x, y, w, h): RGB, top row first.
  ## Empty if it could not be read.
  when defined(macosx):
    if w <= 0 or h <= 0: return
    result = newSeq[byte](w * h * 3)
    if dbmtl_read(cint(x), cint(y), cint(w), cint(h), addr result[0]) == 0:
      result.setLen(0)
  else:
    result = gl_read(x, y, w, h)

proc present*(window: Window): uint64 =
  ## The present's number for shown_at (0: OpenGL, which cannot tell).
  when defined(macosx): result = dbmtl_present()
  else: gl_present(window)

proc waiting*(): int =
  ## Presents not yet on the glass (0 on OpenGL, which cannot tell)
  when defined(macosx): int(dbmtl_waiting())
  else: 0

proc shown_at*(seq: uint64; freq: uint64): uint64 =
  ## When present `seq` reached the glass, in performance-counter ticks of
  ## `freq` per second (both count mach_absolute_time on macOS); 0 unknown.
  when defined(macosx):
    if seq != 0:
      let t = dbmtl_shown_at(seq)
      if t > 0: return uint64(t * float(freq))

proc imgui_init*(window: Window) =
  when defined(macosx):
    discard ImGui_ImplSDL3_InitForMetal(window)
    dbmtl_imgui_init()
  else:
    gl_imgui_init(window)

proc imgui_new_frame*() =
  when defined(macosx): dbmtl_imgui_new_frame()
  else: gl_imgui_new_frame()

proc imgui_render*(dd: ptr ImDrawData) =
  when defined(macosx): dbmtl_imgui_render(dd)
  else: gl_imgui_render(dd)

proc ui_texture*(tex: var uint64; px: pointer; w, h: int; bgr555, linear: bool) =
  ## Create or refill an ImGui image (its ImTextureID in `tex`, 0 = none):
  ## w x h BGR555 words or RGBA8. ImGui's Metal backend always samples
  ## linearly: there a nearest image is drawn between ui_nearest_begin/end.
  when defined(macosx):
    tex = dbmtl_ui_texture(tex, px, cint(w), cint(h), cint(bgr555))
  else:
    gl_ui_texture(tex, px, w, h, bgr555, linear)

proc ui_nearest_begin*() =
  ## ImGui images drawn from here to ui_nearest_end sample nearest, as their
  ## `linear = false` textures do on OpenGL.
  when defined(macosx):
    ImDrawList_AddCallback(igGetWindowDrawList(), dbmtl_ui_nearest, nil, 0)

proc ui_nearest_end*() =
  when defined(macosx):
    # ImDrawCallback_ResetRenderState
    ImDrawList_AddCallback(igGetWindowDrawList(), cast[ImDrawCallback](-8), nil, 0)

proc info*(): seq[string] =
  ## The overlay's lines about what draws.
  when defined(macosx): @["Metal", "  Device: " & $dbmtl_device_name()]
  else: gl_info()
