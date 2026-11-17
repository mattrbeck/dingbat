## The desktop's home screen, in ImGui on every platform: the brand, then
## the library (library.nim) as a grid of tiles, or with no games a box to
## drop one on. It follows the web's home screen (web/index.html `#home`,
## web/styles.css "home-tile", Night theme) in size, colour and behaviour:
## sizes here are that page's CSS px, scaled by ui_px.
##
## No file reads or GL here. The app decodes pictures (`load_picture`) and
## owns textures (`make_texture`, `free_texture`); each is made once, the
## first time its tile is on screen, and kept until its file changes.

import std/[math, os, strutils, tables, times]
import imguin/cimgui
import library, util
from save_states_widget import calc_text_size

type
  Picture* = object
    w*, h*: int
    rgba*: seq[byte]   ## w * h * 4

  ArtState = enum asUnread, asNone, asReady
  TileArt = object
    src: string
    time: Time
    state: ArtState
    tex, blur: uint64  ## the picture, and a few pixels of it for the bars beside it
    w, h: float32

  TileRect* = object
    ## Where a tile was last drawn, in window points (gui_driver's `home dump`)
    name*, path*: string
    x*, y*, w*, h*: float32
    missing*, picture*: bool

  LibraryView* = ref object
    games: seq[LibGame]       ## the library's games in its sort
    missing: seq[bool]        ## parallel to games
    visible: seq[int]         ## indices into games the search and chips leave
    filter_key: string        ## what `visible` was worked out for
    art: Table[string, TileArt]
    focus: string             ## the focused game's path; "" none
    ring: bool                ## focus moved by keys or a pad: draw it
    scroll_to_focus: bool
    query: array[96, char]
    systems: seq[string]      ## chips pressed
    last_check: float
    tiles*: seq[TileRect]
    logo_tex*: uint64
    logo_w*, logo_h*: float32 ## the logo's pixels; drawn at 2x
    ds_beta*: bool
    sort*: string
    pictures_dir*, states_dir*: string
    load_picture*: proc(path: string; g: LibGame): Picture
    make_texture*: proc(p: Picture): uint64
    free_texture*: proc(tex: uint64)
    on_open*: proc(path: string)
    on_add*: proc()
    on_remove*: proc(path: string)
    on_sort*: proc(sort: string)

const
  BAR_MIN = 9          ## search, chips and sort above this many games (web LIB_BAR_MIN)
  CHECK_EVERY = 2.0    ## seconds between looks for files that went away
  LOADS_PER_FRAME = 2  ## pictures decoded in one frame, so a big library never stalls one
  CAPTION_H = 40'f32
  HEAD_H = 34'f32
  BAR_H = 32'f32
  BAR_GAP = 8'f32     ## between the bar's two rows when its chips wrap
  BRAND_H = 112'f32
  BRAND_SMALL_H = 19'f32   ## a small window's brand: the bat at 1x and the name beside it
  SMALL_WINDOW = 420'f32   ## narrower or shorter than this (CSS px), the small brand
  DROP_H = 185'f32

# ──────────────────────────── Colours (web Night theme) ────────────────────────────

proc rgb(c: uint32; a = 1.0'f32): uint32 =
  ## 0xRRGGBB to ImGui's ABGR
  let r = (c shr 16) and 0xFF
  let g = (c shr 8) and 0xFF
  let b = c and 0xFF
  (uint32(round(clamp(a, 0, 1) * 255)) shl 24) or (b shl 16) or (g shl 8) or r

proc fade(col: uint32; a: float32): uint32 =
  ## col with its alpha times a
  let alpha = float32(col shr 24) * a
  (col and 0x00FFFFFF'u32) or (uint32(round(clamp(alpha, 0, 255))) shl 24)

const
  STAGE = 0x07050C'u32
  SURF1 = 0x171126'u32
  SURF2 = 0x201834'u32
  SURF3 = 0x2C2146'u32
  SURF_HOVER = 0x352858'u32
  TEXT = 0xEFEAF8'u32
  DIM = 0xA89CC4'u32
  FAINT = 0x8C80A8'u32
  ACCENT = 0xB79CFF'u32
  ACCENT2 = 0xCBB6FF'u32
  ACCENT_INK = 0x1D1238'u32
  WHITE = 0xFFFFFF'u32

proc border(): uint32 = rgb(WHITE, 0.08)
proc border2(): uint32 = rgb(WHITE, 0.14)

proc stage_rgb*(): (float32, float32, float32) =
  ## The page behind the home screen, for the window's clear colour
  (float32((STAGE shr 16) and 0xFF) / 255, float32((STAGE shr 8) and 0xFF) / 255,
   float32(STAGE and 0xFF) / 255)

type SysLook = object
  fg, bg: uint32           ## the chip
  cart_top, cart_bottom: uint32

proc look(system: string): SysLook =
  case system
  of "GB":  SysLook(fg: rgb(0x74D47F), bg: rgb(0x5FBF6A, 0.16),
                    cart_top: rgb(0x9A9EA8), cart_bottom: rgb(0x6E727C))
  of "GBC": SysLook(fg: rgb(0x5FD6DE), bg: rgb(0x4FD0D8, 0.16),
                    cart_top: rgb(0x8F6FE6), cart_bottom: rgb(0x5B3FC0))
  of "DS":  SysLook(fg: rgb(0xFF9F80), bg: rgb(0xFF8060, 0.16),
                    cart_top: rgb(0x5D6170), cart_bottom: rgb(0x3C3F4B))
  else:     SysLook(fg: rgb(0xB3A7FF), bg: rgb(0x8A7DFF, 0.16),
                    cart_top: rgb(0x6B7488), cart_bottom: rgb(0x464E5E))

# ──────────────────────────── Drawing helpers ────────────────────────────

proc v2(x, y: float32): ImVec2 = ImVec2(x: x, y: y)

proc dflags(f: auto): ImDrawFlags = ImDrawFlags(cint(f))

proc hairline(): float32 =
  ## One device pixel, in points
  let s = igGetIO_Nil().DisplayFramebufferScale.x
  if s > 0: 1 / s else: 1

# imguin's bindings differ between the versions dev machines and CI hold
# (thickness and flags swapped, popups returning bool): exactly one branch
# of each compiles.
proc add_rect(dl: ptr ImDrawList; a, b: ImVec2; col: uint32; rounding, thick: float32) =
  let f = dflags(ImDrawFlags_RoundCornersAll)
  when compiles(ImDrawList_AddRect(dl, a, b, col, rounding, f, thick)):
    ImDrawList_AddRect(dl, a, b, col, rounding, f, thick)
  else:
    ImDrawList_AddRect(dl, a, b, col, rounding, thick, f)

proc path_stroke(dl: ptr ImDrawList; col: uint32; thick: float32) =
  let f = dflags(ImDrawFlags_None)
  when compiles(ImDrawList_PathStroke(dl, col, f, thick)):
    ImDrawList_PathStroke(dl, col, f, thick)
  else:
    ImDrawList_PathStroke(dl, col, thick, f)

proc open_popup(id: string) =
  when typeof(igOpenPopup_Str(cstring(id), 0)) is bool:
    discard igOpenPopup_Str(cstring(id), 0)
  else:
    igOpenPopup_Str(cstring(id), 0)

proc open_popup_on_right_click(id: string) =
  let f = cint(ImGui_PopupFlags_MouseButtonRight)
  when typeof(igOpenPopupOnItemClick(cstring(id), f)) is bool:
    discard igOpenPopupOnItemClick(cstring(id), f)
  else:
    igOpenPopupOnItemClick(cstring(id), f)

proc shade(dl: ptr ImDrawList; start: cint; a, b: ImVec2; top, bottom: uint32) =
  ## A top-to-bottom gradient over what was drawn since `start`
  igShadeVertsLinearColorGradientKeepAlpha(dl, start, dl.VtxBuffer.Size,
                                           a, v2(a.x, b.y), top, bottom)

proc fill_gradient(dl: ptr ImDrawList; a, b: ImVec2; top, bottom: uint32;
                   rounding: float32; corners = ImDrawFlags_RoundCornersAll) =
  let start = dl.VtxBuffer.Size
  ImDrawList_AddRectFilled(dl, a, b, top, rounding, dflags(corners))
  dl.shade(start, a, b, top, bottom)

proc text_at(dl: ptr ImDrawList; p: ImVec2; col: uint32; s: string; bold = false) =
  ImDrawList_AddText_Vec2(dl, p, col, cstring(s), nil)
  if bold: ImDrawList_AddText_Vec2(dl, v2(p.x + hairline(), p.y), col, cstring(s), nil)

proc fit_text(s: string; avail: float32): string =
  ## s, or as much of it as fits with "..." after
  if calc_text_size(s).x <= avail: return s
  result = s
  while result.len > 0:
    result.setLen(result.len - 1)
    let t = result.strip(leading = false) & "..."
    if calc_text_size(t).x <= avail: return t

proc dashed_rect(dl: ptr ImDrawList; a, b: ImVec2; r: float32; col: uint32;
                 dash, gap: float32) =
  ## A rounded outline, its straight runs dashed
  let thick = max(1'f32, hairline())
  for (c, a0) in [(v2(a.x + r, a.y + r), PI), (v2(b.x - r, a.y + r), 1.5 * PI),
                  (v2(b.x - r, b.y - r), 0.0), (v2(a.x + r, b.y - r), 0.5 * PI)]:
    ImDrawList_PathArcTo(dl, c, r, float32(a0), float32(a0 + 0.5 * PI), 0)
    dl.path_stroke(col, thick)
  proc run(p, q: ImVec2) =
    let len = max(abs(q.x - p.x), abs(q.y - p.y))
    var t = 0'f32
    while t < len:
      let e = min(len, t + dash)
      let f0 = t / len
      let f1 = e / len
      ImDrawList_AddLine(dl, v2(p.x + (q.x - p.x) * f0, p.y + (q.y - p.y) * f0),
                         v2(p.x + (q.x - p.x) * f1, p.y + (q.y - p.y) * f1), col, thick)
      t = e + gap
  run(v2(a.x + r, a.y), v2(b.x - r, a.y))
  run(v2(b.x, a.y + r), v2(b.x, b.y - r))
  run(v2(b.x - r, b.y), v2(a.x + r, b.y))
  run(v2(a.x, b.y - r), v2(a.x, a.y + r))

template with_size(size: float32; body: untyped) =
  ## ImGui's font at `size` (its unscaled px; the UI scale applies on top)
  igPushFont(nil, size)
  body
  igPopFont()

template with_size_value(size: float32; e: untyped): untyped =
  igPushFont(nil, size)
  let r = e
  igPopFont()
  r

proc label_font(css: float32): float32 =
  ## The built-in font is drawn crisp at 13 px and its multiples
  if css >= 19.5: 26 else: 13

# ──────────────────────────── The cartridge ────────────────────────────

proc draw_cart(dl: ptr ImDrawList; box_a, box_b: ImVec2; g: LibGame; alpha: float32) =
  ## A picture-less tile's stand-in: its system's cartridge, a GBA one wide,
  ## the others tall with a corner cut, and the game's mark on the label
  ## (web styles.css ".lib-cart").
  let bw = box_b.x - box_a.x
  let lk = look(g.system)
  let gb_like = g.system in ["GB", "GBC", "DS"]
  let (wf, aspect, pad_f, lw, lh, cut_x, cut_y) =
    case g.system
    of "GB", "GBC": (0.25'f32, 6'f32 / 5, 0.07'f32, 0.76'f32, 0.48'f32, 0.80'f32, 0.14'f32)
    of "DS": (0.28'f32, 35'f32 / 33, 0.08'f32, 0.78'f32, 0.46'f32, 0.84'f32, 0.12'f32)
    else: (0.40'f32, 5'f32 / 8, 0.05'f32, 0.64'f32, 0.50'f32, 1'f32, 0'f32)
  let w = bw * wf
  let h = w * aspect
  let cx = (box_a.x + box_b.x) * 0.5
  let cy = (box_a.y + box_b.y) * 0.5
  let a = v2(cx - w * 0.5, cy - h * 0.5)
  let b = v2(cx + w * 0.5, cy + h * 0.5)
  let top = fade(lk.cart_top, alpha)
  let bottom = fade(lk.cart_bottom, alpha)
  if gb_like:
    let r = w * 0.10
    let start = dl.VtxBuffer.Size
    ImDrawList_PathLineTo(dl, v2(a.x + w * 0.04, a.y))
    ImDrawList_PathLineTo(dl, v2(a.x + w * cut_x, a.y))
    ImDrawList_PathLineTo(dl, v2(b.x, a.y + h * cut_y))
    ImDrawList_PathArcTo(dl, v2(b.x - r, b.y - r), r, 0, float32(0.5 * PI), 0)
    ImDrawList_PathArcTo(dl, v2(a.x + r, b.y - r), r, float32(0.5 * PI), float32(PI), 0)
    ImDrawList_PathLineTo(dl, v2(a.x, a.y + w * 0.04))
    ImDrawList_PathFillConvex(dl, top)
    dl.shade(start, a, b, top, bottom)
  else:
    # The shadow under it, soft enough at a few steps
    for k in 1 .. 4:
      let o = float32(k) * bw * 0.012
      ImDrawList_AddRectFilled(dl, v2(a.x - o * 0.5, a.y + o * 1.2),
                               v2(b.x + o * 0.5, b.y + o * 1.6),
                               rgb(0, 0.07 * alpha), h * 0.14 + o, dflags(ImDrawFlags_RoundCornersAll))
    dl.fill_gradient(a, b, top, bottom, h * 0.14)
  # The highlight along its top edge
  ImDrawList_AddLine(dl, v2(a.x + w * 0.08, a.y + hairline()),
                     v2(a.x + w * (if gb_like: cut_x - 0.04 else: 0.92), a.y + hairline()),
                     rgb(WHITE, 0.16 * alpha), hairline())
  let pad = bw * pad_f
  let label_w = w * lw
  let label_h = (h - pad) * lh
  let la = v2(cx - label_w * 0.5, a.y + pad)
  let lb = v2(cx + label_w * 0.5, a.y + pad + label_h)
  ImDrawList_AddRectFilled(dl, la, lb, fade(lk.fg, alpha), ui_px(4),
                           dflags(ImDrawFlags_RoundCornersAll))
  let mark = cart_label(g.display_name)
  if mark.len > 0:
    let css = (if gb_like: clamp(bw / ui_scale * 0.046, 8, 20)
               else: clamp(bw / ui_scale * 0.054, 9, 22))
    with_size(label_font(css)):
      let ts = calc_text_size(mark)
      dl.text_at(v2(round(cx - ts.x * 0.5), round((la.y + lb.y - ts.y) * 0.5)),
                 rgb(0x0A0A14, 0.78 * alpha), mark, bold = true)

# ──────────────────────────── State ────────────────────────────

proc new_library_view*(): LibraryView =
  LibraryView(sort: "recent")

proc free_art(v: LibraryView; a: TileArt) =
  if v.free_texture == nil: return
  if a.tex != 0: v.free_texture(a.tex)
  if a.blur != 0: v.free_texture(a.blur)

proc check_files*(v: LibraryView) =
  ## Which games' files are gone (a moved file, an unplugged drive)
  v.missing.setLen(v.games.len)
  for i, g in v.games: v.missing[i] = not fileExists(g.path)
  v.last_check = epochTime()

proc rescan_pictures*(v: LibraryView) =
  ## Each game's newest picture; one whose file changed is read again.
  var keep: Table[string, TileArt]
  for g in v.games:
    let (src, t) = newest_picture(g, v.pictures_dir, v.states_dir)
    var a = v.art.getOrDefault(g.path, TileArt(state: asNone))
    if a.src != src or a.time != t:
      v.free_art(a)
      a = TileArt(src: src, time: t, state: if src.len > 0: asUnread else: asNone)
    keep[g.path] = a
    v.art.del(g.path)
  for _, a in v.art: v.free_art(a)
  v.art = keep

proc set_games*(v: LibraryView; games: seq[LibGame]) =
  ## The library changed (a game opened or removed, the sort, DS Beta)
  v.games = games
  v.filter_key = "\0"   # work `visible` out again
  v.check_files()
  v.rescan_pictures()

proc query_text(v: LibraryView): string = $cast[cstring](addr v.query[0])

proc bar_shown(v: LibraryView): bool =
  v.games.len >= BAR_MIN or v.query_text.len > 0 or v.systems.len > 0

proc update_filter(v: LibraryView) =
  let q = v.query_text
  let key = q & "\n" & v.systems.join(",")
  if key == v.filter_key: return
  v.filter_key = key
  v.visible.setLen(0)
  for i, g in v.games:
    if v.systems.len > 0 and g.system notin v.systems: continue
    if not search_match(q, g.display_name): continue
    v.visible.add i

proc load_art(v: LibraryView; g: LibGame; a: var TileArt) =
  a.state = asNone
  if v.load_picture == nil or v.make_texture == nil: return
  let p = v.load_picture(a.src, g)
  if p.w <= 0 or p.h <= 0 or p.rgba.len != p.w * p.h * 4: return
  a.tex = v.make_texture(p)
  a.w = float32(p.w)
  a.h = float32(p.h)
  a.state = asReady
  # Narrower than 3:2 (a Game Boy's 10:9, a DS's two screens): the bars
  # beside it are the picture again, a few pixels stretched (web: blurred)
  if abs(a.w / a.h - 1.5) > 0.02:
    const bw = 12
    let bh = max(1, int(round(bw * a.h / a.w)))
    var small = Picture(w: bw, h: bh, rgba: newSeq[byte](bw * bh * 4))
    for y in 0 ..< bh:
      for x in 0 ..< bw:
        var sum: array[4, int]
        var n = 0
        let (x0, x1) = (x * p.w div bw, max(x * p.w div bw + 1, (x + 1) * p.w div bw))
        let (y0, y1) = (y * p.h div bh, max(y * p.h div bh + 1, (y + 1) * p.h div bh))
        for sy in countup(y0, y1 - 1, max(1, (y1 - y0) div 4)):
          for sx in countup(x0, x1 - 1, max(1, (x1 - x0) div 4)):
            for c in 0 .. 3: sum[c] += int(p.rgba[(sy * p.w + sx) * 4 + c])
            inc n
        for c in 0 .. 3:
          small.rgba[(y * bw + x) * 4 + c] = byte(sum[c] div max(1, n))
    a.blur = v.make_texture(small)

# ──────────────────────────── Keys and pads ────────────────────────────

proc focus_index(v: LibraryView): int =
  ## Where the focused game is in the grid; -1 when it is not shown
  if v.focus.len == 0: return -1
  for k, gi in v.visible:
    if v.games[gi].path == v.focus: return k
  -1

proc pressed(keys: openArray[ImGuiKey]): bool =
  for k in keys:
    if igIsKeyPressed_Bool(k, true): return true

proc nav_input(v: LibraryView; cols: int) =
  ## Arrows or a pad's d-pad and stick move through the grid, Return or the
  ## pad's A opens, Escape or B lets go (web index.js "Gamepad support").
  ## The first press only shows where it is: the most recent game.
  let n = v.visible.len
  if n == 0 or cols <= 0: return
  if igGetIO_Nil().WantTextInput: return
  if igIsPopupOpen_Str(nil, cint(ImGui_PopupFlags_AnyPopupId) or
                            cint(ImGui_PopupFlags_AnyPopupLevel)): return
  if not igIsWindowFocused(0): return
  let left = pressed([ImGui_Key_LeftArrow, ImGui_Key_GamepadDpadLeft, ImGui_Key_GamepadLStickLeft])
  let right = pressed([ImGui_Key_RightArrow, ImGui_Key_GamepadDpadRight, ImGui_Key_GamepadLStickRight])
  let up = pressed([ImGui_Key_UpArrow, ImGui_Key_GamepadDpadUp, ImGui_Key_GamepadLStickUp])
  let down = pressed([ImGui_Key_DownArrow, ImGui_Key_GamepadDpadDown, ImGui_Key_GamepadLStickDown])
  var cur = v.focus_index()
  if left or right or up or down:
    if cur < 0 or not v.ring:
      cur = max(0, cur)
    else:
      let (row, col) = (cur div cols, cur mod cols)
      let last_row = (n - 1) div cols
      if left and col > 0: dec cur
      elif right and col < cols - 1 and cur + 1 < n: inc cur
      elif up and row > 0: cur -= cols
      elif down and row < last_row: cur = min(n - 1, cur + cols)
    v.focus = v.games[v.visible[cur]].path
    v.ring = true
    v.scroll_to_focus = true
  if cur >= 0 and v.ring and
     (igIsKeyPressed_Bool(ImGui_Key_Enter, false) or
      igIsKeyPressed_Bool(ImGui_Key_KeypadEnter, false) or
      igIsKeyPressed_Bool(ImGui_Key_Space, false) or
      igIsKeyPressed_Bool(ImGui_Key_GamepadFaceDown, false)):
    if v.on_open != nil: v.on_open(v.focus)
  if igIsKeyPressed_Bool(ImGui_Key_Escape, false) or
     igIsKeyPressed_Bool(ImGui_Key_GamepadFaceRight, false):
    v.ring = false

# ──────────────────────────── Buttons ────────────────────────────

proc button_at(id: string; a, b: ImVec2): bool =
  igSetCursorScreenPos(a)
  igInvisibleButton(cstring(id), v2(b.x - a.x, b.y - a.y), 0)

proc plus_icon(dl: ptr ImDrawList; c: ImVec2; size: float32; col: uint32) =
  let h = size * 7 / 24
  let t = ui_px(1.6)
  ImDrawList_AddLine(dl, v2(c.x - h, c.y), v2(c.x + h, c.y), col, t)
  ImDrawList_AddLine(dl, v2(c.x, c.y - h), v2(c.x, c.y + h), col, t)

proc add_button_w(icon_only: bool): float32 =
  if icon_only: ui_px(HEAD_H) else: ui_px(16 + 15 + 6 + 16) + calc_text_size("Add a game").x

proc add_button(v: LibraryView; dl: ptr ImDrawList; id: string; right, mid_y: float32;
                icon_only: bool) =
  ## The head's "+ Add a game" (web .button.lib-add); just the + where the
  ## head has no room for its words
  let label = "Add a game"
  let ts = calc_text_size(label)
  let w = add_button_w(icon_only)
  let a = v2(right - w, mid_y - ui_px(HEAD_H / 2))
  let b = v2(right, mid_y + ui_px(HEAD_H / 2))
  let clicked = button_at(id, a, b)
  let hot = igIsItemHovered(0)
  dl.fill_gradient(a, b, rgb(if hot: SURF_HOVER else: SURF3),
                   rgb(if hot: SURF3 else: SURF2), ui_px(8))
  dl.add_rect(a, b, border2(), ui_px(8), 1)
  if icon_only:
    dl.plus_icon(v2((a.x + b.x) * 0.5, mid_y), ui_px(15), rgb(TEXT))
    igSetItemTooltip("Add a game")
  else:
    dl.plus_icon(v2(a.x + ui_px(16 + 7.5), mid_y), ui_px(15), rgb(TEXT))
    dl.text_at(v2(a.x + ui_px(16 + 15 + 6), round(mid_y - ts.y * 0.5)), rgb(TEXT), label)
  if clicked and v.on_add != nil: v.on_add()

proc primary_button(v: LibraryView; dl: ptr ImDrawList; id, label: string;
                    cx, top: float32): bool =
  ## The empty state's pill (web .button-primary)
  let ts = calc_text_size(label)
  let w = ts.x + ui_px(56)
  let h = ui_px(44)
  let a = v2(round(cx - w * 0.5), top)
  let b = v2(a.x + w, top + h)
  result = button_at(id, a, b)
  let hot = igIsItemHovered(0)
  # A faint glow under it
  ImDrawList_AddRectFilled(dl, v2(a.x + ui_px(6), a.y + ui_px(4)),
                           v2(b.x - ui_px(6), b.y + ui_px(4)),
                           rgb(ACCENT, 0.10), h * 0.5, dflags(ImDrawFlags_RoundCornersAll))
  dl.fill_gradient(a, b, rgb(if hot: 0xD7C8FF'u32 else: ACCENT2),
                   rgb(if hot: ACCENT2 else: ACCENT), h * 0.5)
  dl.add_rect(a, b, rgb(ACCENT, 0.6), h * 0.5, 1)
  ImDrawList_AddLine(dl, v2(a.x + h * 0.5, a.y + hairline()),
                     v2(b.x - h * 0.5, a.y + hairline()), rgb(WHITE, 0.35), hairline())
  dl.text_at(v2(round(cx - ts.x * 0.5), round(a.y + (h - ts.y) * 0.5)),
             rgb(ACCENT_INK), label, bold = true)

# ──────────────────────────── One tile ────────────────────────────

proc draw_tile(v: LibraryView; dl: ptr ImDrawList; k: int; a: ImVec2;
               track, tile_h: float32; loads: var int) =
  let gi = v.visible[k]
  let g = v.games[gi]
  let missing = gi < v.missing.len and v.missing[gi]
  let b = v2(a.x + track, a.y + tile_h)
  igPushID_Int(cint(gi))
  # The corner menu button first: where the two overlap it takes the click
  let more_r = ui_px(13.5)
  let more_c = v2(b.x - ui_px(6) - more_r, a.y + ui_px(6) + more_r)
  let hot = igIsMouseHoveringRect(a, b, true) and igIsWindowHovered(0)
  var more_clicked = false
  if hot:
    more_clicked = button_at("##more", v2(more_c.x - more_r, more_c.y - more_r),
                             v2(more_c.x + more_r, more_c.y + more_r))
  let more_hot = hot and igIsItemHovered(0)
  let clicked = button_at("##tile", a, b)
  let pressing = igIsItemActive()
  if hot and not more_hot:
    igSetItemTooltip("%s", cstring(
      if missing: g.display_name & " - the file is not there any more:\n" & g.path
      else: g.path.extractFilename()))
  open_popup_on_right_click("##menu")
  if more_clicked: open_popup("##menu")
  if clicked:
    v.focus = g.path
    v.ring = false
    if v.on_open != nil: v.on_open(g.path)
  let menu_open = igIsPopupOpen_Str("##menu", 0)
  let y_off = if pressing and not more_hot: ui_px(1) else: 0'f32
  let ta = v2(a.x, a.y + y_off)
  let tb = v2(b.x, b.y + y_off)
  let r = ui_px(8)
  let lit = hot or menu_open
  # The card
  dl.fill_gradient(ta, tb, rgb(if lit: SURF3 else: SURF2),
                   rgb(if lit: SURF2 else: SURF1), r)
  let alpha = if missing and not hot: 0.72'f32 else: 1'f32
  let inset = 1'f32
  let pa = v2(ta.x + inset, ta.y + inset)
  let pb = v2(tb.x - inset, ta.y + inset + (track - 2 * inset) / 1.5)
  var art = v.art.getOrDefault(g.path, TileArt(state: asNone))
  if art.state == asUnread and loads < LOADS_PER_FRAME:
    inc loads
    v.load_art(g, art)
    v.art[g.path] = art
  if art.state == asReady:
    ImDrawList_AddRectFilled(dl, pa, pb, rgb(0, alpha), r - inset,
                             dflags(ImDrawFlags_RoundCornersTop))
    let bw = pb.x - pa.x
    let bh = pb.y - pa.y
    let s = min(bw / art.w, bh / art.h)
    let (dw, dh) = (art.w * s, art.h * s)
    let tint = rgb(WHITE, alpha)
    if art.blur != 0:
      # Cover: the middle of the small copy, filling the box
      let ar = art.w / art.h
      let (u0, u1, v0, v1) =
        if ar > 1.5: (0.5 - 0.75 / ar, 0.5 + 0.75 / ar, 0'f32, 1'f32)
        else: (0'f32, 1'f32, 0.5 - ar / 3, 0.5 + ar / 3)
      ImDrawList_AddImageRounded(dl, ImTextureRef(internal_TexID: ImTextureID(art.blur)),
                                 pa, pb, v2(u0, v0), v2(u1, v1),
                                 rgb(0x8C8C8C, alpha), r - inset,
                                 dflags(ImDrawFlags_RoundCornersTop))
    let ia = v2(round(pa.x + (bw - dw) * 0.5), round(pa.y + (bh - dh) * 0.5))
    ImDrawList_AddImageRounded(dl, ImTextureRef(internal_TexID: ImTextureID(art.tex)),
                               ia, v2(ia.x + dw, ia.y + dh), v2(0, 0), v2(1, 1), tint,
                               r - inset, dflags(ImDrawFlags_RoundCornersTop))
  else:
    ImDrawList_AddRectFilled(dl, pa, pb, fade(look(g.system).bg, alpha), r - inset,
                             dflags(ImDrawFlags_RoundCornersTop))
    dl.draw_cart(pa, pb, g, alpha)
  # The caption: name, then the system's chip
  let cy = pb.y + ui_px(CAPTION_H) * 0.5
  let chip_w = ui_px(34)
  let chip_h = ui_px(24)
  let chip_a = v2(tb.x - inset - ui_px(10) - chip_w, cy - chip_h * 0.5)
  if g.system.len > 0:
    let lk = look(g.system)
    ImDrawList_AddRectFilled(dl, chip_a, v2(chip_a.x + chip_w, chip_a.y + chip_h),
                             fade(lk.bg, alpha), ui_px(5), dflags(ImDrawFlags_RoundCornersAll))
    let cs = calc_text_size(g.system)
    dl.text_at(v2(round(chip_a.x + (chip_w - cs.x) * 0.5), round(cy - cs.y * 0.5)),
               fade(lk.fg, alpha), g.system)
  let name_x = pa.x + ui_px(10)
  let name = fit_text(g.display_name, chip_a.x - ui_px(8) - name_x)
  let ns = calc_text_size(name)
  dl.text_at(v2(name_x, round(cy - ns.y * 0.5)), rgb(TEXT, alpha), name)
  # The edge: dashed for a file that is not there, as the web's
  if missing:
    dl.dashed_rect(ta, tb, r, if lit: border2() else: rgb(WHITE, 0.12),
                   ui_px(4), ui_px(3))
  else:
    dl.add_rect(ta, tb, if lit: border2() else: border(), r, 1)
  if v.ring and v.focus == g.path:
    let o = ui_px(2) + ui_px(1.5)
    dl.add_rect(v2(ta.x - o, ta.y - o), v2(tb.x + o, tb.y + o), rgb(ACCENT),
                       r + o, ui_px(3))
  if hot or menu_open:
    ImDrawList_AddCircleFilled(dl, more_c, more_r,
                               rgb(0, if more_hot or menu_open: 0.75 else: 0.55), 0)
    if more_hot or menu_open:
      ImDrawList_AddCircle(dl, more_c, more_r, border2(), 0, 1)
    let dc = if more_hot or menu_open: rgb(ACCENT) else: rgb(DIM)
    for dx in [-1'f32, 0, 1]:
      ImDrawList_AddCircleFilled(dl, v2(more_c.x + dx * ui_px(4.4), more_c.y),
                                 ui_px(1.3), dc, 8)
  # Its menu: what the web's tile menu has that the desktop can do
  igPushStyleColor_U32(cint(ImGui_Col_PopupBg), rgb(SURF2))
  igPushStyleColor_U32(cint(ImGui_Col_Border), border2())
  igPushStyleColor_U32(cint(ImGui_Col_HeaderHovered), rgb(ACCENT, 0.18))
  if igBeginPopup("##menu", 0):
    igTextDisabled("%s", cstring(g.display_name))
    if missing: igTextDisabled("The file is not there any more.")
    igSeparator()
    if igMenuItem_Bool("Play", nil, false, not missing) and v.on_open != nil:
      v.on_open(g.path)
    if igMenuItem_Bool("Remove from Library", nil, false, true) and v.on_remove != nil:
      v.on_remove(g.path)
    igEndPopup()
  igPopStyleColor(3)
  igPopID()
  v.tiles.add TileRect(name: g.display_name, path: g.path, x: a.x, y: a.y,
                       w: track, h: tile_h, missing: missing,
                       picture: art.state == asReady)

# ──────────────────────────── The bar (above BAR_MIN games) ────────────────────────────

proc chip_counts(v: LibraryView): seq[(string, int)] =
  ## Each system in the library and its games; no chips for only one
  for s in ["GBA", "GBC", "GB", "DS"]:
    var n = 0
    for g in v.games:
      if g.system == s: inc n
    if n > 0: result.add (s, n)
  if result.len < 2: result.setLen(0)

proc chip_w(s: string; n: int): float32 =
  calc_text_size(s).x + calc_text_size($n).x + ui_px(20 + 6)

proc sort_width(width: float32): float32 =
  ## Room for "Last played" and the combo's arrow, at most 40% of the bar
  min(max(ui_px(120), calc_text_size("Last played").x + ui_px(20) + igGetFrameHeight()),
      width * 0.4)

proc bar_wraps(v: LibraryView; width: float32): bool =
  ## The chips take a row of their own when the field would be squeezed
  ## (web: on a phone, and two tiles wide)
  let counts = v.chip_counts()
  if counts.len == 0: return false
  var chips = 0'f32
  for (s, n) in counts: chips += chip_w(s, n) + ui_px(6)
  width - sort_width(width) - chips - ui_px(8) < ui_px(200)

proc draw_bar(v: LibraryView; dl: ptr ImDrawList; x0, y, width: float32; wrap: bool) =
  ## Search, a chip per system (when there are two or more), and the sort
  let h = ui_px(BAR_H)
  let counts = v.chip_counts()
  var i = 0
  while i < v.systems.len:
    var present = false
    for (s, _) in counts:
      if s == v.systems[i]: present = true
    if present: inc i else: v.systems.delete(i)
  let sort_w = sort_width(width)
  var chips_w = 0'f32
  for (s, n) in counts: chips_w += chip_w(s, n) + ui_px(6)
  let search_w = if wrap: width - sort_w - ui_px(8)
                 else: width - sort_w - chips_w - ui_px(8)
  # The field
  igPushStyleVar_Vec2(cint(ImGui_StyleVar_FramePadding),
                      v2(ui_px(30), (h - igGetFontSize()) * 0.5))
  igPushStyleVar_Float(cint(ImGui_StyleVar_FrameRounding), ui_px(8))
  igPushStyleVar_Float(cint(ImGui_StyleVar_FrameBorderSize), 1)
  igPushStyleColor_U32(cint(ImGui_Col_FrameBg), rgb(SURF2))
  igPushStyleColor_U32(cint(ImGui_Col_FrameBgHovered), rgb(SURF2))
  igPushStyleColor_U32(cint(ImGui_Col_FrameBgActive), rgb(SURF2))
  igPushStyleColor_U32(cint(ImGui_Col_Border), border2())
  igPushStyleColor_U32(cint(ImGui_Col_Text), rgb(TEXT))
  igPushStyleColor_U32(cint(ImGui_Col_TextDisabled), rgb(FAINT))
  igSetCursorScreenPos(v2(x0, y))
  igSetNextItemWidth(search_w)
  discard igInputTextWithHint("##search", "Search", cast[cstring](addr v.query[0]),
                              csize_t(v.query.len),
                              cint(ImGui_InputTextFlags_EscapeClearsAll), nil, nil)
  let mag = v2(x0 + ui_px(17), y + h * 0.5 - ui_px(1))
  ImDrawList_AddCircle(dl, mag, ui_px(5), rgb(FAINT), 0, ui_px(1.5))
  ImDrawList_AddLine(dl, v2(mag.x + ui_px(3.6), mag.y + ui_px(3.6)),
                     v2(mag.x + ui_px(7), mag.y + ui_px(7)), rgb(FAINT), ui_px(1.5))
  # The chips, beside the field or on the row under it
  var cx = if wrap: x0 else: x0 + search_w + ui_px(8)
  let cy = if wrap: y + h + ui_px(BAR_GAP) else: y
  block:
    for (s, n) in counts:
      let on = s in v.systems
      let ls = calc_text_size(s)
      let w = chip_w(s, n)
      if wrap and cx + w > x0 + width: break
      let ca = v2(cx, cy + ui_px(2))
      let cb = v2(cx + w, cy + h - ui_px(2))
      if button_at("##chip" & s, ca, cb):
        if on: v.systems.delete(v.systems.find(s)) else: v.systems.add s
      let hot = igIsItemHovered(0)
      let rr = (cb.y - ca.y) * 0.5
      ImDrawList_AddRectFilled(dl, ca, cb, if on: rgb(ACCENT, 0.12) else: rgb(SURF2), rr,
                               dflags(ImDrawFlags_RoundCornersAll))
      dl.add_rect(ca, cb, if on: rgb(ACCENT, 0.5) elif hot: rgb(WHITE, 0.24)
                                     else: border2(), rr, 1)
      let ty = round(cy + (h - ls.y) * 0.5)
      dl.text_at(v2(ca.x + ui_px(10), ty), if on: rgb(ACCENT) elif hot: rgb(TEXT) else: rgb(DIM),
                 s, bold = true)
      dl.text_at(v2(ca.x + ui_px(16) + ls.x, ty), if on: rgb(ACCENT, 0.8) else: rgb(FAINT), $n)
      cx += w + ui_px(6)
  # The sort
  const names = ["Last played", "A-Z", "System"]
  let cur = max(0, SORTS.find(v.sort))
  igPushStyleVar_Vec2(cint(ImGui_StyleVar_FramePadding),
                      v2(ui_px(10), (h - igGetFontSize()) * 0.5))
  igPushStyleColor_U32(cint(ImGui_Col_Button), rgb(SURF2))
  igPushStyleColor_U32(cint(ImGui_Col_ButtonHovered), rgb(SURF3))
  igPushStyleColor_U32(cint(ImGui_Col_PopupBg), rgb(SURF2))
  igPushStyleColor_U32(cint(ImGui_Col_HeaderHovered), rgb(ACCENT, 0.18))
  igPushStyleColor_U32(cint(ImGui_Col_Header), rgb(ACCENT, 0.12))
  igSetCursorScreenPos(v2(x0 + width - sort_w, y))
  igSetNextItemWidth(sort_w)
  if igBeginCombo("##sort", cstring(names[cur]), 0):
    for k, label in names:
      if igSelectable_Bool(cstring(label), k == cur, 0, v2(0, 0)) and k != cur:
        v.sort = SORTS[k]
        if v.on_sort != nil: v.on_sort(v.sort)
    igEndCombo()
  igPopStyleColor(5)
  igPopStyleVar(1)
  igPopStyleColor(6)
  igPopStyleVar(3)

# ──────────────────────────── The page ────────────────────────────

proc draw*(v: LibraryView; rom_types: string) =
  ## The whole home screen, under whatever the app draws over it.
  ## `rom_types`: what the drop box says can be opened.
  let vp = igGetMainViewport()
  if vp == nil: return
  if v.games.len > 0 and epochTime() - v.last_check > CHECK_EVERY: v.check_files()
  v.update_filter()
  v.tiles.setLen(0)
  let pos = vp[].WorkPos
  let size = vp[].WorkSize
  igSetNextWindowPos(pos, cint(ImGui_Cond_Always), v2(0, 0))
  igSetNextWindowSize(size, cint(ImGui_Cond_Always))
  igPushStyleVar_Vec2(cint(ImGui_StyleVar_WindowPadding), v2(0, 0))
  igPushStyleVar_Float(cint(ImGui_StyleVar_WindowBorderSize), 0)
  igPushStyleVar_Float(cint(ImGui_StyleVar_WindowRounding), 0)
  igPushStyleVar_Float(cint(ImGui_StyleVar_ScrollbarSize), ui_px(10))
  igPushStyleColor_U32(cint(ImGui_Col_WindowBg), rgb(STAGE))
  igPushStyleColor_U32(cint(ImGui_Col_ScrollbarBg), 0)
  igPushStyleColor_U32(cint(ImGui_Col_ScrollbarGrab), border2())
  igPushStyleColor_U32(cint(ImGui_Col_ScrollbarGrabHovered), rgb(WHITE, 0.22))
  igPushStyleColor_U32(cint(ImGui_Col_ScrollbarGrabActive), rgb(WHITE, 0.28))
  let flags = cint(ImGui_WindowFlags_NoTitleBar) or cint(ImGui_WindowFlags_NoResize) or
              cint(ImGui_WindowFlags_NoMove) or cint(ImGui_WindowFlags_NoCollapse) or
              cint(ImGui_WindowFlags_NoSavedSettings) or
              cint(ImGui_WindowFlags_NoBringToFrontOnFocus)
  let shown = igBegin("##home", nil, flags)
  igPopStyleColor(5)
  igPopStyleVar(4)
  if not shown:
    igEnd()
    return
  let dl = igGetWindowDrawList()
  let s = ui_scale
  let scroll = igGetScrollY()
  let inner_w = size.x - (if igGetScrollMaxY() > 0: ui_px(10) else: 0)
  let css_w = inner_w / s
  let avail = size.y / s
  template X(q: float32): float32 = pos.x + q * s
  template Y(q: float32): float32 = pos.y - scroll + q * s
  let n = v.visible.len
  let gutter = if css_w < 360: 16'f32 else: LIB_PAD
  let lay = grid_layout(css_w, max(1, n), gutter)
  let tile_h = (lay.track - 2) / 1.5 + CAPTION_H + 2
  let rows = (n + lay.cols - 1) div max(1, lay.cols)
  let bar = v.games.len > 0 and v.bar_shown()
  let wrap = bar and v.bar_wraps(lay.width * s)
  let bar_h = if not bar: 0'f32 elif wrap: 2 * BAR_H + BAR_GAP + 12 else: BAR_H + 12
  let body_h =
    if v.games.len == 0: DROP_H
    else: HEAD_H + 10 + bar_h +
          (if n == 0: 20'f32 else: float32(rows) * tile_h + float32(rows - 1) * LIB_GAP)
  let small = css_w < SMALL_WINDOW or avail < SMALL_WINDOW
  let brand_h = if small: BRAND_SMALL_H else: BRAND_H
  let inner_h = brand_h + 26 + body_h
  let top = gutter + max(0, (avail - 2 * gutter - inner_h) * 0.5)
  let total = max(avail, inner_h + 2 * gutter)
  let mid = css_w * 0.5
  v.nav_input(lay.cols)

  # The brand: the bat, the name and what it is, or in a small window the
  # bat and the name on one line
  let name_w = with_size_value(26, calc_text_size("dingbat").x)
  if small:
    let ns = calc_text_size("dingbat")
    let lw = v.logo_w * s
    let gap = ui_px(8)
    let x0 = round(X(mid) - (lw + gap + ns.x) * 0.5)
    if v.logo_tex != 0:
      ImDrawList_AddImage(dl, ImTextureRef(internal_TexID: ImTextureID(v.logo_tex)),
                          v2(x0, round(Y(top))), v2(x0 + lw, round(Y(top)) + v.logo_h * s),
                          v2(0, 0), v2(1, 1), 0xFFFFFFFF'u32)
    dl.text_at(v2(x0 + lw + gap, round(Y(top + BRAND_SMALL_H * 0.5) - ns.y * 0.5)),
               rgb(TEXT), "dingbat", bold = true)
  else:
    if v.logo_tex != 0:
      let lw = v.logo_w * 2
      let lh = v.logo_h * 2
      ImDrawList_AddImage(dl, ImTextureRef(internal_TexID: ImTextureID(v.logo_tex)),
                          v2(round(X(mid - lw * 0.5)), round(Y(top))),
                          v2(round(X(mid - lw * 0.5)) + lw * s, round(Y(top)) + lh * s),
                          v2(0, 0), v2(1, 1), 0xFFFFFFFF'u32)
    with_size(26):
      let ts = calc_text_size("dingbat")
      dl.text_at(v2(round(X(mid) - name_w * 0.5), round(Y(top + 55 + 17.5) - ts.y * 0.5)),
                 rgb(TEXT), "dingbat", bold = true)
    let tagline = "a game boy & game boy advance emulator"
    let tg = calc_text_size(tagline)
    dl.text_at(v2(round(X(mid) - tg.x * 0.5), round(Y(top + 96 + 8) - tg.y * 0.5)),
               rgb(FAINT), tagline)
  let body = top + brand_h + 26

  if v.games.len == 0:
    # Nothing yet: drop a file, or pick one
    let w = min(560'f32, css_w - 2 * gutter)
    let a = v2(X(mid - w * 0.5), Y(body))
    let b = v2(X(mid + w * 0.5), Y(body + DROP_H))
    dl.dashed_rect(a, b, ui_px(18), border2(), ui_px(3), ui_px(3))
    let ic = v2(X(mid), Y(body + 24 + 11))
    let ink = rgb(TEXT, 0.9)
    let t = ui_px(1.6)
    let k = ui_px(1)
    ImDrawList_AddLine(dl, v2(ic.x, ic.y + 4 * k), v2(ic.x, ic.y - 7 * k), ink, t)
    ImDrawList_AddLine(dl, v2(ic.x - 4 * k, ic.y - 3 * k), v2(ic.x, ic.y - 7 * k), ink, t)
    ImDrawList_AddLine(dl, v2(ic.x + 4 * k, ic.y - 3 * k), v2(ic.x, ic.y - 7 * k), ink, t)
    ImDrawList_PathLineTo(dl, v2(ic.x - 7 * k, ic.y + 2 * k))
    ImDrawList_PathLineTo(dl, v2(ic.x - 7 * k, ic.y + 8 * k))
    ImDrawList_PathLineTo(dl, v2(ic.x + 7 * k, ic.y + 8 * k))
    ImDrawList_PathLineTo(dl, v2(ic.x + 7 * k, ic.y + 2 * k))
    dl.path_stroke(ink, t)
    let title = "Drop a game file anywhere in this window"
    let ts = calc_text_size(title)
    dl.text_at(v2(round(X(mid) - ts.x * 0.5), round(Y(body + 60 + 8.5) - ts.y * 0.5)),
               rgb(DIM), title)
    if v.primary_button(dl, "##add_first", "Add a game", X(mid), round(Y(body + 91))) and
       v.on_add != nil:
      v.on_add()
    let hs = calc_text_size(rom_types)
    dl.text_at(v2(round(X(mid) - hs.x * 0.5), round(Y(body + 149 + 8) - hs.y * 0.5)),
               rgb(FAINT), rom_types)
  else:
    # The head: "LIBRARY  3 games", and Add a game
    let x0 = mid - lay.width * 0.5
    let hy = Y(body + HEAD_H / 2)
    let label = "LIBRARY"
    let ls = calc_text_size(label)
    dl.text_at(v2(X(x0), round(hy - ls.y * 0.5)), rgb(FAINT), label, bold = true)
    let count = if n == v.games.len: $n & (if n == 1: " game" else: " games")
                else: $n & " of " & $v.games.len
    let cs = calc_text_size(count)
    # A narrow head keeps the label; the count, then the button's words, go
    let room = lay.width * s - ls.x - ui_px(10)
    let icon_only = room < add_button_w(false)
    if room - add_button_w(icon_only) >= cs.x + ui_px(10):
      dl.text_at(v2(X(x0) + ls.x + ui_px(10), round(hy - ls.y * 0.5)), rgb(FAINT), count)
    v.add_button(dl, "##add", X(x0 + lay.width), hy, icon_only)
    var gy = body + HEAD_H + 10
    if bar:
      v.draw_bar(dl, X(x0), Y(gy), lay.width * s, wrap)
      gy += bar_h
    if n == 0:
      let none = "No games match."
      let ns = calc_text_size(none)
      dl.text_at(v2(round(X(mid) - ns.x * 0.5), Y(gy)), rgb(DIM), none)
    let gx = mid - lay.grid_w * 0.5
    let fk = v.focus_index()
    if v.scroll_to_focus and fk >= 0:
      v.scroll_to_focus = false
      let fy = (gy + float32(fk div lay.cols) * (tile_h + LIB_GAP)) * s
      let pad = gutter * s
      if fy - pad < scroll: igSetScrollY_Float(max(0, fy - pad))
      elif fy + tile_h * s + pad > scroll + size.y:
        igSetScrollY_Float(fy + tile_h * s + pad - size.y)
    var loads = 0
    for k in 0 ..< n:
      let (row, col) = (k div lay.cols, k mod lay.cols)
      let tx = gx + float32(col) * (lay.track + LIB_GAP)
      let ty = gy + float32(row) * (tile_h + LIB_GAP)
      # Off screen: nothing to draw or read
      if Y(ty + tile_h) < pos.y or Y(ty) > pos.y + size.y: continue
      v.draw_tile(dl, k, v2(round(X(tx)), round(Y(ty))), round(lay.track * s),
                  round(tile_h * s), loads)
  # The scroll height
  igSetCursorPos(v2(0, max(0, total * s - 1)))
  igDummy(v2(1, 1))
  # A click on the page lets go of the focus ring
  if igIsWindowHovered(0) and igIsMouseClicked_Bool(ImGuiMouseButton(ImGui_MouseButton_Left), false) and
     not igIsAnyItemHovered():
    v.ring = false
  igEnd()

proc dump*(v: LibraryView): string =
  ## The tiles as last drawn, one a line (gui_driver `home dump`):
  ## `<name>|x y w h|missing|picture`
  for t in v.tiles:
    result.add t.name & "|" & $int(t.x) & " " & $int(t.y) & " " & $int(t.w) & " " &
               $int(t.h) & "|" & (if t.missing: "missing" else: "present") & "|" &
               (if t.picture: "picture" else: "cart") & "\n"
  if v.games.len == 0: result.add "empty\n"
