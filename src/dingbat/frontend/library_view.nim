## The desktop's home screen, in ImGui on every platform: the brand, then
## the library (library.nim) as a grid of tiles, or with no games a box to
## drop one on. Once a game has been played and closed, that game heads the
## page instead of the brand (the hero: Resume, Play) and stands down from
## the grid. It follows the web's home screen (web/index.html `#home`,
## `#hero`, web/styles.css "home-tile", "The hero", Night theme) in size,
## colour and behaviour: sizes here, text sizes too, are that page's CSS px,
## scaled by ui_px.
##
## No file reads or textures here. The app decodes pictures (`load_picture`)
## and owns textures (`make_texture`, `free_texture`); each is made once, the
## first time its tile is on screen, and kept until its file changes.
## The toasts over a game (web #toast) are drawn here too, in the page's look.

import std/[math, os, strutils, tables, times]
import imguin/cimgui
import library, util, ui_fonts
from presenter import ui_nearest_begin, ui_nearest_end
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
    # The hero
    hero*: LibGame            ## the game heading the page; path "" = none
    hero_session*: string     ## its session snapshot's file: Resume while it counts
    session_ok*: proc(session: string; g: LibGame): bool  ## counts (nil: is there)
    has_session: bool
    hero_missing: bool
    hero_rects: seq[TileRect] ## its picture and buttons as last drawn
    menu_rects: seq[TileRect] ## the open game menu's items as last drawn
    on_resume*: proc(path: string)  ## put the session back
    on_play*: proc(path: string)    ## boot from the in-game save
    on_find*: proc(path: string)    ## Find the File, for a game whose file is gone

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
  PAGE_PX = 13.5'f32  ## the page's text (web .button, #home-tagline)

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

proc text_at(dl: ptr ImDrawList; p: ImVec2; col: uint32; s: string) =
  ImDrawList_AddText_Vec2(dl, p, col, cstring(s), nil)

proc fit_text(s: string; avail: float32): string =
  ## s, or as much of it as fits with "…" after
  if calc_text_size(s).x <= avail: return s
  result = s
  while result.len > 0:
    result.setLen(result.len - 1)
    let t = result.strip(leading = false) & "…"
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

template with_font_value(face: Face; css: float32; e: untyped): untyped =
  push_font(face, css)
  let r = e
  igPopFont()
  r

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
    with_font(fBold, css):
      let ts = calc_text_size(mark)
      dl.text_at(v2(round(cx - ts.x * 0.5), round((la.y + lb.y - ts.y) * 0.5)),
                 rgb(0x0A0A14, 0.78 * alpha), mark)

# ──────────────────────────── State ────────────────────────────

proc new_library_view*(): LibraryView =
  LibraryView(sort: "recent")

proc free_art(v: LibraryView; a: TileArt) =
  if v.free_texture == nil: return
  if a.tex != 0: v.free_texture(a.tex)
  if a.blur != 0: v.free_texture(a.blur)

proc check_files*(v: LibraryView) =
  ## Which games' files are gone (a moved file, an unplugged drive), and
  ## whether the hero's session still counts (another window may have
  ## played the game since, or the game saved past it)
  v.missing.setLen(v.games.len)
  for i, g in v.games: v.missing[i] = not fileExists(g.path)
  v.has_session = v.hero_session.len > 0 and
    (if v.session_ok != nil: v.session_ok(v.hero_session, v.hero)
     else: fileExists(v.hero_session))
  v.hero_missing = v.hero.path.len > 0 and not fileExists(v.hero.path)
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

proc set_hero*(v: LibraryView; g: LibGame; session: string) =
  ## The game heading the page (path "" for none) and its session's file
  if g == v.hero and session == v.hero_session: return
  v.hero = g
  v.hero_session = session
  v.filter_key = "\0"
  if v.focus.startsWith("@"): v.focus = ""
  v.check_files()

proc query_text(v: LibraryView): string = $cast[cstring](addr v.query[0])

proc filtering(v: LibraryView): bool = v.query_text.len > 0 or v.systems.len > 0

proc bar_shown(v: LibraryView): bool =
  v.games.len >= BAR_MIN or v.filtering

proc hero_shown(v: LibraryView): bool =
  if v.hero.path.len == 0: return false
  for g in v.games:
    if g.path == v.hero.path: return true

proc solo(v: LibraryView): bool =
  ## The library is the hero's game alone: the hero is the library (web
  ## body.home-solo)
  v.hero_shown and v.games.len == 1

proc update_filter(v: LibraryView) =
  let q = v.query_text
  let key = q & "\n" & v.systems.join(",") & "\n" & v.hero.path
  if key == v.filter_key: return
  v.filter_key = key
  v.visible.setLen(0)
  # The hero's game is shown once: its tile stands down, except while a
  # search or filter runs (asked for by name, it must be found)
  let hidden = if v.filtering: "" else: v.hero.path
  for i, g in v.games:
    if hidden.len > 0 and g.path == hidden: continue
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
  # A few pixels of it: the bars beside a picture narrower than 3:2 (a Game
  # Boy's 10:9, a DS's two screens) and the hero's glow (web: blurred)
  block:
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

proc hero_buttons(v: LibraryView): seq[string] =
  ## The hero's row for the focus ring: its first button, then Play beside
  ## Resume (web padHomeItems)
  if not v.hero_shown: return
  result.add "@resume"
  if v.has_session: result.add "@play"

proc hero_primary(v: LibraryView) =
  ## The picture and the first button: Resume, or Play with no session
  if v.has_session:
    if v.on_resume != nil: v.on_resume(v.hero.path)
  elif v.on_play != nil: v.on_play(v.hero.path)

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
  ## Arrows or a pad's d-pad and stick move through the hero's buttons and
  ## the grid, Return or the pad's A presses, Start is the hero's first
  ## button, Escape or B lets go (web index.js "Gamepad support"). The first
  ## press only shows where it is: the hero's Resume, else the most recent
  ## game.
  let n = v.visible.len
  let row = v.hero_buttons()
  if (n == 0 and row.len == 0) or cols <= 0: return
  if igGetIO_Nil().WantTextInput: return
  if igIsPopupOpen_Str(nil, cint(ImGui_PopupFlags_AnyPopupId) or
                            cint(ImGui_PopupFlags_AnyPopupLevel)): return
  if not igIsWindowFocused(0): return
  let left = pressed([ImGui_Key_LeftArrow, ImGui_Key_GamepadDpadLeft, ImGui_Key_GamepadLStickLeft])
  let right = pressed([ImGui_Key_RightArrow, ImGui_Key_GamepadDpadRight, ImGui_Key_GamepadLStickRight])
  let up = pressed([ImGui_Key_UpArrow, ImGui_Key_GamepadDpadUp, ImGui_Key_GamepadLStickUp])
  let down = pressed([ImGui_Key_DownArrow, ImGui_Key_GamepadDpadDown, ImGui_Key_GamepadLStickDown])
  if row.len > 0 and igIsKeyPressed_Bool(ImGui_Key_GamepadStart, false):
    v.hero_primary()
    return
  let on_hero = v.focus.startsWith("@") and v.focus in row
  if on_hero and v.ring:
    let k = row.find(v.focus)
    if left and k > 0: v.focus = row[k - 1]
    elif right and k + 1 < row.len: v.focus = row[k + 1]
    elif down and n > 0:
      v.focus = v.games[v.visible[0]].path
      v.scroll_to_focus = true
    if igIsKeyPressed_Bool(ImGui_Key_Enter, false) or
       igIsKeyPressed_Bool(ImGui_Key_KeypadEnter, false) or
       igIsKeyPressed_Bool(ImGui_Key_Space, false) or
       igIsKeyPressed_Bool(ImGui_Key_GamepadFaceDown, false):
      if v.focus == "@play":
        if v.on_play != nil: v.on_play(v.hero.path)
      else: v.hero_primary()
    if igIsKeyPressed_Bool(ImGui_Key_Escape, false) or
       igIsKeyPressed_Bool(ImGui_Key_GamepadFaceRight, false):
      v.ring = false
    return
  var cur = v.focus_index()
  if (left or right or up or down) and row.len > 0 and
     (cur < 0 or not v.ring or (up and cur < cols)):
    # The first press, or up from the grid's first row: the hero
    v.focus = row[0]
    v.ring = true
    igSetScrollY_Float(0)
    return
  if n == 0: return
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
  push_font(fBold, PAGE_PX)
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
             rgb(ACCENT_INK), label)
  igPopFont()

proc item_rect(): (ImVec2, ImVec2) =
  ## The last item's corners (imguin's out-param or by-value binding)
  var a, b: ImVec2
  when compiles(igGetItemRectMin(addr a)):
    igGetItemRectMin(addr a)
    igGetItemRectMax(addr b)
  else:
    let p = igGetItemRectMin()
    let q = igGetItemRectMax()
    a = ImVec2(x: p.x, y: p.y)
    b = ImVec2(x: q.x, y: q.y)
  (a, b)

proc menu_item(v: LibraryView; title: string; enabled = true): bool =
  result = igMenuItem_Bool(cstring(title), nil, false, enabled)
  let (a, b) = item_rect()
  v.menu_rects.add TileRect(name: title, x: a.x, y: a.y, w: b.x - a.x, h: b.y - a.y)

proc game_menu(v: LibraryView; id: string; g: LibGame; missing, hero: bool) =
  ## What the web's tile menu has that the desktop can do: the hero's adds
  ## Resume, a game whose file is gone Find the File
  igPushStyleColor_U32(cint(ImGui_Col_PopupBg), rgb(SURF2))
  igPushStyleColor_U32(cint(ImGui_Col_Border), border2())
  igPushStyleColor_U32(cint(ImGui_Col_HeaderHovered), rgb(ACCENT, 0.18))
  if igBeginPopup(cstring(id), 0):
    v.menu_rects.setLen(0)
    igTextDisabled("%s", cstring(g.display_name))
    if missing: igTextDisabled("The file is not there any more.")
    igSeparator()
    if hero and v.has_session and v.menu_item("Resume", not missing) and
       v.on_resume != nil:
      v.on_resume(g.path)
    # Play is from the in-game save, as the hero's; a click is the setting's
    if v.menu_item("Play", not missing) and v.on_play != nil: v.on_play(g.path)
    if missing and v.menu_item("Find the File...") and v.on_find != nil:
      v.on_find(g.path)
    if v.menu_item("Remove from Library") and v.on_remove != nil:
      v.on_remove(g.path)
    igEndPopup()
  igPopStyleColor(3)

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
    if art.blur != 0 and abs(art.w / art.h - 1.5) > 0.02:
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
    with_font(fBold, 10):
      let cs = calc_text_size(g.system)
      dl.text_at(v2(round(chip_a.x + (chip_w - cs.x) * 0.5), round(cy - cs.y * 0.5)),
                 fade(lk.fg, alpha), g.system)
  let name_x = pa.x + ui_px(10)
  with_font(fRegular, 13):
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
  v.game_menu("##menu", g, missing, hero = false)
  igPopID()
  v.tiles.add TileRect(name: g.display_name, path: g.path, x: a.x, y: a.y,
                       w: track, h: tile_h, missing: missing,
                       picture: art.state == asReady)

# ──────────────────────────── The hero ────────────────────────────
#
# web/styles.css "The hero", closed (`#hero[data-mode="closed"]`): the game's
# last picture in a faint glow of its own colours, dimmed a little as a
# memory; over its name "LAST PLAYED" with the lamp out and the system's
# chip; Resume (the session goes back in) and Play (from the in-game save),
# or Play alone with no session; then the game's menu. From 760 px the
# picture is left of the words, the block the library's width; under that
# the words go under the picture. A hero that is the whole library is its
# own centred block, a size up.

const
  HERO_KICKER_H = 18'f32
  HERO_GAP = 12'f32        ## kicker, name and buttons
  HERO_BUTTON_H = 48'f32
  HERO_KICKER_PX = 12'f32  ## web #hero-kicker
  HERO_BUTTON_PX = 15'f32  ## web #hero-actions .button
  HERO_RADIUS = 14'f32
  HERO_DIM = 0xD1D1D1'u32  ## web: brightness(0.82) on a closed game's picture

type HeroLayout = object
  row: bool                ## the picture beside the words
  x, w: float32            ## the block's left edge and width
  frame_w, frame_h, gap, body_w, body_h, h, name_css: float32

proc hero_aspect(v: LibraryView; art: TileArt): float32 =
  ## The picture's own shape (a DS picture: its top screen, as the web's
  ## paused hero shows), else the system's screen's for its cartridge
  if art.state == asReady and art.w > 0 and art.h > 0:
    if art.h > art.w * 1.2: art.w / (art.h * 0.5) else: art.w / art.h
  else:
    case v.hero.system
    of "GBA": 1.5'f32
    of "DS": 4'f32 / 3
    else: 10'f32 / 9

proc hero_layout(css_w, lib_x, lib_w, avail_x, avail_w, avail_h: float32; solo: bool;
                 aspect: float32): HeroLayout =
  ## `avail_h`: the window's height less its gutters. A window shorter than
  ## the hero would be (a game's own size, 720 x 480 for a GBA at 3x) takes a
  ## smaller picture, at the block's left edge, rather than scrolling it away.
  result.row = css_w >= 760
  var basis = 0'f32
  if result.row:
    if solo:
      result.frame_w = clamp(css_w * 0.36, 320, 480)
      result.gap = 48
      basis = 380
      result.name_css = clamp(css_w * 0.032, 30, 42)
      result.w = min(avail_w, result.frame_w + result.gap + basis)
      result.x = avail_x + (avail_w - result.w) * 0.5
    else:
      result.frame_w = clamp(css_w * 0.30, 280, 384)
      result.gap = 40
      basis = 460
      result.name_css = clamp(css_w * 0.028, 28, 36)
      result.w = lib_w
      result.x = lib_x
  else:
    result.w = lib_w
    result.x = lib_x
    result.frame_w = lib_w
    result.gap = 16
    result.name_css = clamp(css_w * 0.065, 24, 30)
    result.body_w = lib_w
  let ar = max(0.1'f32, aspect)
  result.body_h = HERO_KICKER_H + HERO_GAP + result.name_css * 1.1 + HERO_GAP + 2 +
                  HERO_BUTTON_H
  let room = if result.row: avail_h else: avail_h - result.gap - result.body_h
  result.frame_w = min(result.frame_w, max(160'f32, room * ar))
  result.frame_h = result.frame_w / ar
  if result.row:
    if solo:
      result.w = min(avail_w, result.frame_w + result.gap + basis)
      result.x = avail_x + (avail_w - result.w) * 0.5
    result.body_w = max(0'f32, min(basis, result.w - result.frame_w - result.gap))
  result.h = if result.row: max(result.frame_h, result.body_h)
             else: result.frame_h + result.gap + result.body_h

proc pill(dl: ptr ImDrawList; a, b: ImVec2; primary, hot: bool) =
  ## A round-ended button: the accent one (web .button-primary) or the
  ## surface one (.button)
  let r = (b.y - a.y) * 0.5
  if primary:
    ImDrawList_AddRectFilled(dl, v2(a.x + ui_px(6), a.y + ui_px(4)),
                             v2(b.x - ui_px(6), b.y + ui_px(4)),
                             rgb(ACCENT, 0.10), r, dflags(ImDrawFlags_RoundCornersAll))
    dl.fill_gradient(a, b, rgb(if hot: 0xD7C8FF'u32 else: ACCENT2),
                     rgb(if hot: ACCENT2 else: ACCENT), r)
    dl.add_rect(a, b, rgb(ACCENT, 0.6), r, 1)
    ImDrawList_AddLine(dl, v2(a.x + r, a.y + hairline()), v2(b.x - r, a.y + hairline()),
                       rgb(WHITE, 0.35), hairline())
  else:
    dl.fill_gradient(a, b, rgb(if hot: SURF_HOVER else: SURF3),
                     rgb(if hot: SURF3 else: SURF2), r)
    dl.add_rect(a, b, border2(), r, 1)

proc ring_around(dl: ptr ImDrawList; a, b: ImVec2; r: float32) =
  ## The focus ring (web :focus-visible): the accent, a gap out
  let o = ui_px(2) + ui_px(1.5)
  dl.add_rect(v2(a.x - o, a.y - o), v2(b.x + o, b.y + o), rgb(ACCENT), r + o, ui_px(3))

proc spaced_text(dl: ptr ImDrawList; p: ImVec2; col: uint32; s: string;
                 spacing: float32): float32 =
  ## Text with letter-spacing (the kicker's 0.16em); returns its width
  var x = p.x
  for i, c in s:
    let ch = $c
    dl.text_at(v2(round(x), p.y), col, ch)
    x += calc_text_size(ch).x + (if i + 1 < s.len: spacing else: 0)
  x - p.x

proc spaced_width(s: string; spacing: float32): float32 =
  for i, c in s:
    result += calc_text_size($c).x + (if i + 1 < s.len: spacing else: 0)

proc draw_hero(v: LibraryView; dl: ptr ImDrawList; hl: HeroLayout; ox, oy: float32;
               loads: var int) =
  ## The hero at (ox, oy), the block's top left in window points
  let s = ui_scale
  let g = v.hero
  var art = v.art.getOrDefault(g.path, TileArt(state: asNone))
  if art.state == asUnread and loads < LOADS_PER_FRAME:
    inc loads
    v.load_art(g, art)
    v.art[g.path] = art
  v.hero_rects.setLen(0)
  # The picture: Resume or Play, as the first button
  let fy = oy + (if hl.row: (hl.h - hl.frame_h) * 0.5 * s else: 0)
  let fa = v2(round(ox), round(fy))
  let fb = v2(round(ox + hl.frame_w * s), round(fy + hl.frame_h * s))
  if button_at("##hero_shot", fa, fb): v.hero_primary()
  let shot_hot = igIsItemHovered(0)
  igSetItemTooltip("%s", cstring((if v.has_session: "Resume " else: "Play ") & g.display_name))
  let r = ui_px(HERO_RADIUS)
  if art.state == asReady and art.blur != 0:
    # The glow: the picture's few pixels, faint, spread past the frame and
    # feathered in layers (web: blur(36px) at opacity 0.14)
    let (gw, gh) = (fb.x - fa.x, fb.y - fa.y)
    let ga = v2(fa.x - 0.08 * gw, fa.y - 0.10 * gh)
    let gb = v2(fb.x + 0.08 * gw, fb.y + 0.10 * gh)
    const layers = 18
    for k in 0 ..< layers:
      let e = (float32(k) - layers / 2) * ui_px(3)
      ImDrawList_AddImageRounded(dl, ImTextureRef(internal_TexID: ImTextureID(art.blur)),
                                 v2(ga.x - e, ga.y - e), v2(gb.x + e, gb.y + e),
                                 v2(0, 0), v2(1, 1), rgb(WHITE, 0.14 / layers),
                                 max(0'f32, ui_px(30) + e), dflags(ImDrawFlags_RoundCornersAll))
  # Its shadow, under it (0 20px 50px -14px)
  for k in 1 .. 3:
    let e = float32(k) * ui_px(10) - ui_px(14)
    ImDrawList_AddRectFilled(dl, v2(fa.x - e, fa.y + ui_px(20) - e),
                             v2(fb.x + e, fb.y + ui_px(20) + e), rgb(0, 0.14),
                             r + max(0'f32, e), dflags(ImDrawFlags_RoundCornersAll))
  if art.state == asReady:
    ImDrawList_AddRectFilled(dl, fa, fb, rgb(0), r, dflags(ImDrawFlags_RoundCornersAll))
    let top_half = art.h > art.w * 1.2
    ImDrawList_AddImageRounded(dl, ImTextureRef(internal_TexID: ImTextureID(art.tex)),
                               v2(fa.x + 1, fa.y + 1), v2(fb.x - 1, fb.y - 1), v2(0, 0),
                               v2(1, if top_half: 0.5 else: 1), rgb(HERO_DIM), r - 1,
                               dflags(ImDrawFlags_RoundCornersAll))
  else:
    # Never pictured: its cartridge, as on its tile
    ImDrawList_AddRectFilled(dl, fa, fb, look(g.system).bg, r, dflags(ImDrawFlags_RoundCornersAll))
    dl.draw_cart(fa, fb, g, 1)
  dl.add_rect(fa, fb, rgb(WHITE, if shot_hot: 0.28 else: 0.14), r, 1)
  v.hero_rects.add TileRect(name: "@picture", path: g.path, x: fa.x, y: fa.y,
                            w: fb.x - fa.x, h: fb.y - fa.y, missing: v.hero_missing,
                            picture: art.state == asReady)
  # The words
  let bx = if hl.row: ox + (hl.frame_w + hl.gap) * s else: ox
  let by = if hl.row: oy + (hl.h - hl.body_h) * 0.5 * s
           else: oy + (hl.frame_h + hl.gap) * s
  let bw = hl.body_w * s
  let kc = by + HERO_KICKER_H * 0.5 * s
  ImDrawList_AddCircleFilled(dl, v2(bx + ui_px(4), kc), ui_px(4), rgb(FAINT, 0.55), 0)
  let kicker = "LAST PLAYED"
  push_font(fBold, HERO_KICKER_PX)
  let ks = calc_text_size(kicker)
  let kw = dl.spaced_text(v2(bx + ui_px(8 + 10), round(kc - ks.y * 0.5)), rgb(DIM), kicker,
                          ui_px(HERO_KICKER_PX * 0.16))
  igPopFont()
  if g.system.len > 0:
    let lk = look(g.system)
    let ca = v2(bx + ui_px(18 + 10) + kw, kc - ui_px(9))
    let cb = v2(ca.x + ui_px(34), kc + ui_px(9))
    ImDrawList_AddRectFilled(dl, ca, cb, lk.bg, ui_px(5), dflags(ImDrawFlags_RoundCornersAll))
    with_font(fBold, 10):
      let cs = calc_text_size(g.system)
      dl.text_at(v2(round(ca.x + (ui_px(34) - cs.x) * 0.5), round(kc - cs.y * 0.5)), lk.fg,
                 g.system)
  let name_y = by + (HERO_KICKER_H + HERO_GAP) * s
  let name_h = hl.name_css * 1.1 * s
  with_font(fBold, hl.name_css):
    let name = fit_text(g.display_name, bw)
    let ns = calc_text_size(name)
    dl.text_at(v2(bx, round(name_y + (name_h - ns.y) * 0.5)), rgb(TEXT), name)
  # The buttons: Resume (or Play, with no session), Play, the menu
  let ay = round(name_y + name_h + (HERO_GAP + 2) * s)
  let bh = ui_px(HERO_BUTTON_H)
  let first = if v.has_session: "Resume" else: "Play"
  let fs = with_font_value(fBold, HERO_BUTTON_PX, calc_text_size(first))
  let ps = with_font_value(fRegular, HERO_BUTTON_PX, calc_text_size("Play"))
  let more_w = bh
  let play_w = if v.has_session: ui_px(44) + ps.x else: 0'f32
  var first_w = ui_px(22 + 15 + 8 + 22) + fs.x
  if not hl.row:
    # A phone's Resume takes the row (web flex: 1 1 auto)
    first_w = max(first_w, bw - more_w - ui_px(10) -
                           (if play_w > 0: play_w + ui_px(10) else: 0))
  var x = round(bx)
  template button(id, focus_id: string; width: float32; primary: bool; body: untyped) =
    block:
      let a {.inject.} = v2(x, ay)
      let b {.inject.} = v2(round(x + width), ay + bh)
      let clicked {.inject.} = button_at(id, a, b)
      let hot {.inject.} = igIsItemHovered(0)
      dl.pill(a, b, primary, hot)
      body
      if v.ring and v.focus == focus_id: dl.ring_around(a, b, bh * 0.5)
      if focus_id.len > 0:
        v.hero_rects.add TileRect(name: focus_id, path: g.path, x: a.x, y: a.y,
                                  w: b.x - a.x, h: b.y - a.y)
      x = b.x + ui_px(10)
  button("##hero_first", "@resume", first_w, true):
    # The play triangle, then the word
    let cy = (a.y + b.y) * 0.5
    let t = ui_px(15)
    let ix = if hl.row: a.x + ui_px(22)
             else: round((a.x + b.x - (t + ui_px(8) + fs.x)) * 0.5)
    ImDrawList_AddTriangleFilled(dl, v2(ix + t * 0.27, cy - t * 0.42),
                                 v2(ix + t * 0.27, cy + t * 0.42), v2(ix + t * 0.85, cy),
                                 rgb(ACCENT_INK))
    with_font(fBold, HERO_BUTTON_PX):
      dl.text_at(v2(round(ix + t + ui_px(8)), round(cy - fs.y * 0.5)), rgb(ACCENT_INK), first)
    if clicked: v.hero_primary()
  if v.has_session:
    button("##hero_play", "@play", play_w, false):
      with_font(fRegular, HERO_BUTTON_PX):
        dl.text_at(v2(round((a.x + b.x - ps.x) * 0.5), round((a.y + b.y - ps.y) * 0.5)),
                   rgb(TEXT), "Play")
      igSetItemTooltip("Start the game from its in-game save")
      if clicked and v.on_play != nil: v.on_play(g.path)
  button("##hero_more", "", more_w, false):
    let c = v2((a.x + b.x) * 0.5, (a.y + b.y) * 0.5)
    let menu_open = igIsPopupOpen_Str("##heromenu", 0)
    for dx in [-1'f32, 0, 1]:
      ImDrawList_AddCircleFilled(dl, v2(c.x + dx * ui_px(7), c.y), ui_px(2),
                                 rgb(if hot or menu_open: TEXT else: DIM), 8)
    igSetItemTooltip("More for this game")
    if clicked: open_popup("##heromenu")
  v.game_menu("##heromenu", g, v.hero_missing, hero = true)

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
  with_font_value(fBold, 11, calc_text_size(s).x) +
    with_font_value(fRegular, 11, calc_text_size($n).x) + ui_px(20 + 6)

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
  push_font(fRegular, 13)
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
      let ls = with_font_value(fBold, 11, calc_text_size(s))
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
      with_font(fBold, 11):
        dl.text_at(v2(ca.x + ui_px(10), ty),
                   if on: rgb(ACCENT) elif hot: rgb(TEXT) else: rgb(DIM), s)
      with_font(fRegular, 11):
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
  igPopFont()

# ──────────────────────────── The page ────────────────────────────

proc draw*(v: LibraryView; rom_types: string) =
  ## The whole home screen, under whatever the app draws over it.
  ## `rom_types`: what the drop box says can be opened.
  let vp = igGetMainViewport()
  if vp == nil: return
  if v.games.len > 0 and epochTime() - v.last_check > CHECK_EVERY: v.check_files()
  v.update_filter()
  v.tiles.setLen(0)
  v.menu_rects.setLen(0)
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
  push_font(fRegular, PAGE_PX)
  let s = ui_scale
  let scroll = igGetScrollY()
  let inner_w = size.x - (if igGetScrollMaxY() > 0: ui_px(10) else: 0)
  let css_w = inner_w / s
  let avail = size.y / s
  template X(q: float32): float32 = pos.x + q * s
  template Y(q: float32): float32 = pos.y - scroll + q * s
  let n = v.visible.len
  let gutter = if css_w < 360: 16'f32 else: LIB_PAD
  let hero = v.hero_shown
  let solo = v.solo
  let lay = grid_layout(css_w, max(1, n), gutter, under_hero = hero)
  let tile_h = (lay.track - 2) / 1.5 + CAPTION_H + 2
  let rows = (n + lay.cols - 1) div max(1, lay.cols)
  let bar = v.games.len > 0 and v.bar_shown() and not solo
  let wrap = bar and v.bar_wraps(lay.width * s)
  let bar_h = if not bar: 0'f32 elif wrap: 2 * BAR_H + BAR_GAP + 12 else: BAR_H + 12
  # Under a hero the library begins at a rule (web .home-recent-head)
  let rule_h = if hero: 20'f32 else: 0'f32
  let body_h =
    if v.games.len == 0: DROP_H
    elif solo: HEAD_H   # Add a game, under the hero
    else: rule_h + HEAD_H + 10 + bar_h +
          (if n == 0: 20'f32 else: float32(rows) * tile_h + float32(rows - 1) * LIB_GAP)
  let small = css_w < SMALL_WINDOW or avail < SMALL_WINDOW
  var hl: HeroLayout
  if hero:
    hl = hero_layout(css_w, css_w * 0.5 - lay.width * 0.5, lay.width, gutter,
                     css_w - 2 * gutter, avail - 2 * gutter, solo,
                     v.hero_aspect(v.art.getOrDefault(v.hero.path, TileArt(state: asNone))))
  # The brand stands down for the hero (web body.home-card #home-brand)
  let brand_h = if hero: hl.h elif small: BRAND_SMALL_H else: BRAND_H
  let inner_h = brand_h + 26 + body_h
  let top = gutter + max(0, (avail - 2 * gutter - inner_h) * 0.5)
  let total = max(avail, inner_h + 2 * gutter)
  let mid = css_w * 0.5
  v.nav_input(lay.cols)

  # The brand: the bat, the name and what it is, or in a small window the
  # bat and the name on one line; the hero in its place
  let name_w = with_font_value(fBold, 30, calc_text_size("dingbat").x)
  var loads = 0
  if hero:
    v.draw_hero(dl, hl, X(hl.x), Y(top), loads)
  elif small:
    let ns = with_font_value(fBold, 17, calc_text_size("dingbat"))
    let lw = v.logo_w * s
    let gap = ui_px(8)
    let x0 = round(X(mid) - (lw + gap + ns.x) * 0.5)
    if v.logo_tex != 0:
      ui_nearest_begin()
      ImDrawList_AddImage(dl, ImTextureRef(internal_TexID: ImTextureID(v.logo_tex)),
                          v2(x0, round(Y(top))), v2(x0 + lw, round(Y(top)) + v.logo_h * s),
                          v2(0, 0), v2(1, 1), 0xFFFFFFFF'u32)
      ui_nearest_end()
    with_font(fBold, 17):
      dl.text_at(v2(x0 + lw + gap, round(Y(top + BRAND_SMALL_H * 0.5) - ns.y * 0.5)),
                 rgb(TEXT), "dingbat")
  else:
    if v.logo_tex != 0:
      let lw = v.logo_w * 2
      let lh = v.logo_h * 2
      ui_nearest_begin()
      ImDrawList_AddImage(dl, ImTextureRef(internal_TexID: ImTextureID(v.logo_tex)),
                          v2(round(X(mid - lw * 0.5)), round(Y(top))),
                          v2(round(X(mid - lw * 0.5)) + lw * s, round(Y(top)) + lh * s),
                          v2(0, 0), v2(1, 1), 0xFFFFFFFF'u32)
      ui_nearest_end()
    with_font(fBold, 30):
      let ts = calc_text_size("dingbat")
      dl.text_at(v2(round(X(mid) - name_w * 0.5), round(Y(top + 55 + 17.5) - ts.y * 0.5)),
                 rgb(TEXT), "dingbat")
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
    with_font(fRegular, 14):
      let ts = calc_text_size(title)
      dl.text_at(v2(round(X(mid) - ts.x * 0.5), round(Y(body + 60 + 8.5) - ts.y * 0.5)),
                 rgb(DIM), title)
    if v.primary_button(dl, "##add_first", "Add a game", X(mid), round(Y(body + 91))) and
       v.on_add != nil:
      v.on_add()
    with_font(fRegular, 13):
      let hs = calc_text_size(rom_types)
      dl.text_at(v2(round(X(mid) - hs.x * 0.5), round(Y(body + 149 + 8) - hs.y * 0.5)),
                 rgb(FAINT), rom_types)
  elif solo:
    # The hero is the library: its head's Add a game under it
    let w = add_button_w(false)
    v.add_button(dl, "##add", X(mid) + w * 0.5, Y(body + HEAD_H / 2), false)
  else:
    # The head: "LIBRARY  3 games", and Add a game
    let x0 = mid - lay.width * 0.5
    if hero:
      ImDrawList_AddLine(dl, v2(X(x0), round(Y(body))), v2(X(x0 + lay.width), round(Y(body))),
                         border(), max(1'f32, hairline()))
    let hy = Y(body + rule_h + HEAD_H / 2)
    let label = "LIBRARY"
    let ls = with_font_value(fBold, 11, calc_text_size(label))
    with_font(fBold, 11):
      dl.text_at(v2(X(x0), round(hy - ls.y * 0.5)), rgb(FAINT), label)
    let count = if not v.filtering:
                  $v.games.len & (if v.games.len == 1: " game" else: " games")
                else: $n & " of " & $v.games.len
    let cs = with_font_value(fRegular, 11, calc_text_size(count))
    # A narrow head keeps the label; the count, then the button's words, go
    let room = lay.width * s - ls.x - ui_px(6)
    let icon_only = room < add_button_w(false)
    if room - add_button_w(icon_only) >= cs.x + ui_px(10):
      with_font(fRegular, 11):
        dl.text_at(v2(X(x0) + ls.x + ui_px(6), round(hy - cs.y * 0.5)), rgb(FAINT), count)
    v.add_button(dl, "##add", X(x0 + lay.width), hy, icon_only)
    var gy = body + rule_h + HEAD_H + 10
    if bar:
      v.draw_bar(dl, X(x0), Y(gy), lay.width * s, wrap)
      gy += bar_h
    if n == 0:
      let none = "No games match."
      let ns = calc_text_size(none)
      dl.text_at(v2(round(X(mid) - ns.x * 0.5), Y(gy)), rgb(DIM), none)
    # Under a hero a short library's tiles start at its left edge, the hero's
    let gx = if hero: x0 else: mid - lay.grid_w * 0.5
    let fk = v.focus_index()
    if v.scroll_to_focus and fk >= 0:
      v.scroll_to_focus = false
      let fy = (gy + float32(fk div lay.cols) * (tile_h + LIB_GAP)) * s
      let pad = gutter * s
      if fy - pad < scroll: igSetScrollY_Float(max(0, fy - pad))
      elif fy + tile_h * s + pad > scroll + size.y:
        igSetScrollY_Float(fy + tile_h * s + pad - size.y)
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
  igPopFont()
  igEnd()

proc dump*(v: LibraryView): string =
  ## The page as last drawn, one a line (gui_driver `home dump`), in window
  ## points. Each tile: `<name>|x y w h|missing|picture`. The hero, first:
  ## `@hero|<name>|<its buttons>`, then `@picture|x y w h|missing|picture`
  ## and a line per button (`@resume`, `@play`). An open game menu's items:
  ## `@menu <title>|x y w h`.
  proc rect(t: TileRect): string =
    $int(t.x) & " " & $int(t.y) & " " & $int(t.w) & " " & $int(t.h)
  if v.hero_shown and v.hero_rects.len > 0:
    result.add "@hero|" & v.hero.display_name & "|" &
               (if v.has_session: "resume play" else: "play") & "\n"
    for t in v.hero_rects:
      result.add t.name & "|" & rect(t)
      if t.name == "@picture":
        result.add "|" & (if t.missing: "missing" else: "present") & "|" &
                   (if t.picture: "picture" else: "cart")
      result.add "\n"
  for t in v.tiles:
    result.add t.name & "|" & rect(t) & "|" & (if t.missing: "missing" else: "present") &
               "|" & (if t.picture: "picture" else: "cart") & "\n"
  for t in v.menu_rects: result.add "@menu " & t.name & "|" & rect(t) & "\n"
  if v.games.len == 0: result.add "empty\n"

# ──────────────────────────── Toasts ────────────────────────────
# Short notes over the bottom of the window, the web's (#toast,
# .toast-item): a pill per note, newest on top so an older one's button never
# moves, three at most. A plain one is gone after 2.2 s and takes no clicks;
# an offer (a button) after 8 s, the whole pill its button, × to dismiss.
# An offer of the game's (`game`) goes when the game does.

type
  Toast = object
    msg, label: string
    fn: proc()
    game: bool
    until: float
    id: int
  ToastRect = object
    text: string          ## "<message>|<button>"
    pill, close: TileRect ## close.w 0: none

var
  toasts: seq[Toast]      ## newest first
  toast_rects: seq[ToastRect]
  toast_ids = 0

const TOAST_MAX = 3

proc push_toast(t: Toast) =
  for i in countdown(toasts.high, 0):
    if toasts[i].msg == t.msg and toasts[i].label == t.label: toasts.delete(i)
  var t = t
  inc toast_ids
  t.id = toast_ids
  toasts.insert(t, 0)
  if toasts.len > TOAST_MAX: toasts.setLen(TOAST_MAX)

proc show_toast*(msg: string) =
  push_toast(Toast(msg: msg, until: epochTime() + 2.2))

proc show_offer*(msg, label: string; fn: proc(); game = true) =
  ## A toast with a button (web showActionToast)
  push_toast(Toast(msg: msg, label: label, fn: fn, game: game,
                   until: epochTime() + 8.0))

proc toasts_up*(): bool = toasts.len > 0

proc dismiss_game_toasts*() =
  for i in countdown(toasts.high, 0):
    if toasts[i].game: toasts.delete(i)

proc draw_toasts*() =
  ## Last in the frame, over everything the app draws
  toast_rects.setLen(0)
  let now = epochTime()
  for i in countdown(toasts.high, 0):
    if toasts[i].until <= now: toasts.delete(i)
  let vp = igGetMainViewport()
  if vp == nil or toasts.len == 0: return
  let pos = vp[].WorkPos
  let size = vp[].WorkSize
  push_font(fRegular, 13)
  let max_w = min(ui_px(480), size.x - ui_px(16))
  var bottom = pos.y + size.y - ui_px(20)
  var run: proc() = nil
  var gone = -1
  # The oldest at the bottom
  for i in countdown(toasts.high, 0):
    let t = toasts[i]
    let offer = t.label.len > 0
    let label_w = if offer: with_font_value(fBold, 13, calc_text_size(t.label).x) +
                            ui_px(24) else: 0'f32
    let close_w = if offer: ui_px(24) else: 0'f32
    let gaps = if offer: ui_px(20) else: 0'f32
    let room = max(ui_px(40), max_w - ui_px(32) - label_w - close_w - gaps)
    let msg = fit_text(t.msg, room)
    let ts = calc_text_size(msg)
    let w = ui_px(32) + ts.x + label_w + close_w + gaps
    let h = max(ts.y, if offer: ui_px(24) else: 0'f32) + ui_px(16)
    let r = min(ui_px(16), h * 0.5)
    let a = v2(round(pos.x + (size.x - w) * 0.5), round(bottom - h))
    let b = v2(a.x + w, a.y + h)
    bottom = a.y - ui_px(8)
    var rec = ToastRect(text: t.msg & "|" & t.label,
                        pill: TileRect(x: a.x, y: a.y, w: w, h: h))
    igSetNextWindowPos(a, cint(ImGui_Cond_Always), v2(0, 0))
    igSetNextWindowSize(v2(w, h), cint(ImGui_Cond_Always))
    igPushStyleVar_Vec2(cint(ImGui_StyleVar_WindowPadding), v2(0, 0))
    igPushStyleVar_Float(cint(ImGui_StyleVar_WindowBorderSize), 0)
    var flags = cint(ImGui_WindowFlags_NoDecoration) or cint(ImGui_WindowFlags_NoMove) or
                cint(ImGui_WindowFlags_NoSavedSettings) or cint(ImGui_WindowFlags_NoNav) or
                cint(ImGui_WindowFlags_NoFocusOnAppearing) or
                cint(ImGui_WindowFlags_NoBackground)
    if not offer: flags = flags or cint(ImGui_WindowFlags_NoInputs)
    if igBegin(cstring("##toast" & $t.id), nil, flags):
      # The whole window is the pill: its shadow goes on the page's layer
      let shadow = igGetBackgroundDrawList(vp)
      for k in 1 .. 4:
        let e = ui_px(float32(k) * 2)
        ImDrawList_AddRectFilled(shadow, v2(a.x - e, a.y - e + ui_px(6)),
                                 v2(b.x + e, b.y + e + ui_px(6)), rgb(0, 0.07),
                                 r + e, dflags(ImDrawFlags_RoundCornersAll))
      let dl = igGetWindowDrawList()
      dl.fill_gradient(a, b, rgb(SURF3), rgb(SURF2), r)
      dl.add_rect(a, b, border2(), r, 1)
      ImDrawList_AddLine(dl, v2(a.x + r, a.y + hairline()), v2(b.x - r, a.y + hairline()),
                         rgb(WHITE, 0.09), hairline())
      let mid = (a.y + b.y) * 0.5
      dl.text_at(v2(a.x + ui_px(16), round(mid - ts.y * 0.5)), rgb(TEXT), msg)
      if offer:
        let ca = v2(b.x - ui_px(10) - close_w, mid - ui_px(12))
        let cb = v2(ca.x + close_w, ca.y + ui_px(24))
        let la = v2(ca.x - ui_px(10) - label_w, mid - ui_px(11))
        let lb = v2(la.x + label_w, mid + ui_px(11))
        # The × first: where it sits it takes the click from the pill
        let closed = button_at("##close", ca, cb)
        let close_hot = igIsItemHovered(0)
        let clicked = button_at("##pill", a, b)
        let hot = igIsItemHovered(0) and not close_hot
        ImDrawList_AddRectFilled(dl, la, lb, rgb(if hot: SURF_HOVER else: SURF1),
                                 ui_px(11), dflags(ImDrawFlags_RoundCornersAll))
        dl.add_rect(la, lb, border2(), ui_px(11), 1)
        with_font(fBold, 13):
          let ls = calc_text_size(t.label)
          dl.text_at(v2(round((la.x + lb.x - ls.x) * 0.5), round(mid - ls.y * 0.5)),
                     rgb(ACCENT), t.label)
        with_font(fRegular, 17):
          let xs = calc_text_size("×")
          dl.text_at(v2(round((ca.x + cb.x - xs.x) * 0.5), round(mid - xs.y * 0.5)),
                     rgb(TEXT, if close_hot: 1.0 else: 0.6), "×")
        rec.close = TileRect(x: ca.x, y: ca.y, w: close_w, h: ui_px(24))
        if closed: gone = i
        elif clicked:
          gone = i
          run = t.fn
    igEnd()
    igPopStyleVar(2)
    toast_rects.insert(rec, 0)
  igPopFont()
  if gone >= 0: toasts.delete(gone)
  if run != nil: run()

proc toast_dump*(): string =
  ## The toasts as last drawn, newest first (gui_driver `toast dump`), in
  ## window points: `<message>|<button>|x y w h` (no button for a plain
  ## one), an offer's × after it as `@close|x y w h`; `none` with none
  proc rect(t: TileRect): string =
    $int(t.x) & " " & $int(t.y) & " " & $int(t.w) & " " & $int(t.h)
  for t in toast_rects:
    result.add t.text & "|" & rect(t.pill) & "\n"
    if t.close.w > 0: result.add "@close|" & rect(t.close) & "\n"
  if result.len == 0: result = "none\n"
