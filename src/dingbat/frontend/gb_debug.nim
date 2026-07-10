import imguin/cimgui
import imguin/glad/gl
import ../gb/gb

type
  GbDebug* = ref object
    gb*:             GB
    palette_window*: bool
    tiles_window*:   bool
    bgmap_window*:   bool
    tiles_tex:       GLuint
    bgmap_tex:       GLuint
    tiles_buf:       seq[uint32]
    bgmap_buf:       seq[uint32]

proc new_gb_debug*(gb: GB): GbDebug =
  GbDebug(gb: gb)

proc any_window_open*(d: GbDebug): bool =
  d.palette_window or d.tiles_window or d.bgmap_window

proc render_menu_items*(d: GbDebug) =
  discard igMenuItem_BoolPtr("Palettes", nil, addr d.palette_window, true)
  discard igMenuItem_BoolPtr("Tiles", nil, addr d.tiles_window, true)
  discard igMenuItem_BoolPtr("BG Maps", nil, addr d.bgmap_window, true)

# ──────────────────────────── Palettes ────────────────────────────

const SWATCH_FLAGS = cint(ImGui_ColorEditFlags_NoAlpha) or
                     cint(ImGui_ColorEditFlags_NoPicker) or
                     cint(ImGui_ColorEditFlags_NoOptions) or
                     cint(ImGui_ColorEditFlags_NoInputs) or
                     cint(ImGui_ColorEditFlags_NoLabel) or
                     cint(ImGui_ColorEditFlags_NoSidePreview) or
                     cint(ImGui_ColorEditFlags_NoDragDrop)

proc pram_color(pram: array[64, uint8]; idx: int): uint16 =
  # Palette RAM is little-endian BGR555 pairs (red in the low 5 bits)
  uint16(pram[idx * 2]) or (uint16(pram[idx * 2 + 1]) shl 8)

proc swatch(c: uint16) =
  let col = ImVec4(x: cfloat(c and 0x1F'u16) / 31.0'f32,
                   y: cfloat((c shr 5) and 0x1F'u16) / 31.0'f32,
                   z: cfloat((c shr 10) and 0x1F'u16) / 31.0'f32,
                   w: 1.0'f32)
  discard igColorButton("", col, SWATCH_FLAGS, ImVec2(x: 18, y: 18))

proc dmg_palette_row(label: cstring; reg: array[4, uint8];
                     pram: array[64, uint8]) =
  igTextUnformatted(label, nil)
  igSameLine(56, -1)
  for i in 0 .. 3:
    swatch(pram_color(pram, int(reg[i])))
    igSameLine(0, 2)
  igText("= %02X", cuint(ppu_palette_from_array(reg)))

proc cgb_palette_grid(title: cstring; pram: array[64, uint8]) =
  igBeginGroup()
  igTextUnformatted(title, nil)
  for p in 0 .. 7:
    igText("%d", cint(p))
    igSameLine(24, -1)
    for c in 0 .. 3:
      swatch(pram_color(pram, p * 4 + c))
      if c < 3: igSameLine(0, 2)
  igEndGroup()

proc render_palette_window(d: GbDebug) =
  # igBegin returns false while collapsed: skip the content (igEnd is
  # still required)
  if igBegin("Palettes", addr d.palette_window, 0):
    let ppu = d.gb.ppu
    if d.gb.cgb_enabled:
      cgb_palette_grid("Background", ppu.pram)
      igSameLine(0, 24)
      cgb_palette_grid("Objects", ppu.obj_pram)
    else:
      dmg_palette_row("BGP", ppu.bgp, ppu.pram)
      dmg_palette_row("OBP0", ppu.obp0, ppu.obj_pram)
      dmg_palette_row("OBP1", ppu.obp1, ppu.obj_pram)
  igEnd()

# ──────────────────────────── Texture helpers ────────────────────────────

proc upload_texture(tex: var GLuint; buf: pointer; w, h: int) =
  # Preserve the GL_TEXTURE_2D binding: the game render path relies on the
  # game texture staying bound across frames (it never re-binds)
  var prev: GLint
  glGetIntegerv(GL_TEXTURE_BINDING_2D, addr prev)
  if tex == 0:
    glGenTextures(1, addr tex)
    glBindTexture(GL_TEXTURE_2D, tex)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_NEAREST))
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_NEAREST))
  else:
    glBindTexture(GL_TEXTURE_2D, tex)
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), GLsizei(w), GLsizei(h), 0,
               GL_RGBA, GL_UNSIGNED_BYTE, buf)
  glBindTexture(GL_TEXTURE_2D, GLuint(prev))

proc debug_image(tex: GLuint; w, h: float32) =
  igImage(ImTextureRef(internal_TexData: nil, internal_TexID: ImTextureID(tex)),
          ImVec2(x: w, y: h), ImVec2(x: 0, y: 0), ImVec2(x: 1, y: 1))

proc bgr555_to_rgba8(c: uint16): uint32 =
  let r = (uint32(c) and 0x1F) * 255 div 31
  let g = ((uint32(c) shr 5) and 0x1F) * 255 div 31
  let b = ((uint32(c) shr 10) and 0x1F) * 255 div 31
  0xFF000000'u32 or (b shl 16) or (g shl 8) or r

const DMG_GREYS = [0xFFFFFFFF'u32, 0xFFAAAAAA'u32, 0xFF555555'u32, 0xFF000000'u32]

proc shade_rgba(d: GbDebug; color: uint8): uint32 =
  # DMG maps the 2-bit color through BGP; CGB tiles have no single palette,
  # so show the raw color index as a grey ramp
  if d.gb.cgb_enabled: DMG_GREYS[color]
  else: DMG_GREYS[d.gb.ppu.bgp[color]]

# ──────────────────────────── Tiles ────────────────────────────

const TILE_COLS = 16
const TILE_ROWS = 24  # 384 tiles per bank
const TILES_SCALE = 2.0'f32

proc build_tiles(d: GbDebug): (int, int) =
  let ppu = d.gb.ppu
  let banks = if d.gb.cgb_enabled: 2 else: 1
  let w = TILE_COLS * 8 * banks
  let h = TILE_ROWS * 8
  if d.tiles_buf.len != w * h: d.tiles_buf.setLen(w * h)
  for bank in 0 ..< banks:
    for t in 0 ..< TILE_COLS * TILE_ROWS:
      let px = (t mod TILE_COLS) * 8 + bank * TILE_COLS * 8
      let py = (t div TILE_COLS) * 8
      for row in 0 ..< 8:
        let b1 = ppu.vram[bank][t * 16 + row * 2]
        let b2 = ppu.vram[bank][t * 16 + row * 2 + 1]
        for col in 0 ..< 8:
          let shift = 7 - col
          let color = uint8((((b2 shr shift) and 1) shl 1) or
                            ((b1 shr shift) and 1))
          d.tiles_buf[(py + row) * w + px + col] = d.shade_rgba(color)
  (w, h)

proc render_tiles_window(d: GbDebug) =
  # Skip the decode + texture upload while collapsed
  if igBegin("Tiles", addr d.tiles_window, 0):
    let (w, h) = d.build_tiles()
    upload_texture(d.tiles_tex, addr d.tiles_buf[0], w, h)
    if d.gb.cgb_enabled:
      igTextUnformatted("Bank 0", nil)
      igSameLine(cfloat(TILE_COLS * 8) * TILES_SCALE + 8, -1)
      igTextUnformatted("Bank 1", nil)
    debug_image(d.tiles_tex, float32(w) * TILES_SCALE, float32(h) * TILES_SCALE)
  igEnd()

# ──────────────────────────── BG maps ────────────────────────────

const MAP_PX = 256
const MAP_SCALE = 2.0'f32

proc build_bg_map(d: GbDebug; map_base: int) =
  let ppu = d.gb.ppu
  let cgb = d.gb.cgb_enabled
  if d.bgmap_buf.len != MAP_PX * MAP_PX: d.bgmap_buf.setLen(MAP_PX * MAP_PX)
  let signed_mode = bg_window_tile_data(ppu) == 0
  for ty in 0 ..< 32:
    for tx in 0 ..< 32:
      let tn_addr = map_base + ty * 32 + tx
      let raw = ppu.vram[0][tn_addr]
      let tile_ptr = if signed_mode: 0x1000 + int(cast[int8](raw)) * 16
                     else: int(raw) * 16
      let attrs = if cgb: ppu.vram[1][tn_addr] else: 0'u8
      let bank = int((attrs shr 3) and 1)
      for row in 0 ..< 8:
        let y_row = if (attrs and 0x40) != 0: 7 - row else: row
        let b1 = ppu.vram[bank][tile_ptr + y_row * 2]
        let b2 = ppu.vram[bank][tile_ptr + y_row * 2 + 1]
        for col in 0 ..< 8:
          let shift = if (attrs and 0x20) != 0: col else: 7 - col
          let color = uint8((((b2 shr shift) and 1) shl 1) or
                            ((b1 shr shift) and 1))
          d.bgmap_buf[(ty * 8 + row) * MAP_PX + tx * 8 + col] =
            if cgb:
              bgr555_to_rgba8(pram_color(ppu.pram,
                                         int(attrs and 0b111) * 4 + int(color)))
            else:
              DMG_GREYS[ppu.bgp[color]]

proc outline_scroll_viewport(d: GbDebug; img_pos: ImVec2) =
  # SCX/SCY viewport, drawn wrapped: clip to the image and stamp the rect at
  # the four wrap offsets so the parts that cross the map edge reappear
  let ppu = d.gb.ppu
  let side = cfloat(MAP_PX) * MAP_SCALE
  let img_max = ImVec2(x: img_pos.x + side, y: img_pos.y + side)
  let dl = igGetWindowDrawList()
  let col = igGetColorU32_Vec4(ImVec4(x: 1.0, y: 0.2, z: 0.2, w: 1.0))
  ImDrawList_PushClipRect(dl, img_pos, img_max, true)
  for wx in 0 .. 1:
    for wy in 0 .. 1:
      let x0 = img_pos.x + (cfloat(ppu.scx) - cfloat(wx * MAP_PX)) * MAP_SCALE
      let y0 = img_pos.y + (cfloat(ppu.scy) - cfloat(wy * MAP_PX)) * MAP_SCALE
      let p0 = ImVec2(x: x0, y: y0)
      let p1 = ImVec2(x: x0 + 160 * MAP_SCALE, y: y0 + 144 * MAP_SCALE)
      # imguin <= 1.92.4 orders AddRect params (rounding, flags, thickness);
      # later versions swapped to (rounding, thickness, flags)
      when compiles(ImDrawList_AddRect(dl, p0, p1, col, 0, 0, 2.0)):
        ImDrawList_AddRect(dl, p0, p1, col, 0, 0, 2.0)
      else:
        ImDrawList_AddRect(dl, p0, p1, col, 0, 2.0, 0)
  ImDrawList_PopClipRect(dl)

proc render_bg_map_tab(d: GbDebug; label: cstring; map_base: int;
                       is_bg_map: bool) =
  if igBeginTabItem(label, nil, 0):
    d.build_bg_map(map_base)
    upload_texture(d.bgmap_tex, addr d.bgmap_buf[0], MAP_PX, MAP_PX)
    var img_pos = ImVec2(x: 0, y: 0)
    # imguin <= 1.92.4 uses a pOut out-param; later versions return by value
    when compiles(igGetCursorScreenPos(addr img_pos)):
      igGetCursorScreenPos(addr img_pos)
    else:
      let p = igGetCursorScreenPos()
      img_pos = ImVec2(x: p.x, y: p.y)
    debug_image(d.bgmap_tex, cfloat(MAP_PX) * MAP_SCALE, cfloat(MAP_PX) * MAP_SCALE)
    if is_bg_map:
      d.outline_scroll_viewport(img_pos)
    igEndTabItem()

proc render_bgmap_window(d: GbDebug) =
  # Skip the decode + texture upload while collapsed
  if igBegin("BG Maps", addr d.bgmap_window, 0):
    let ppu = d.gb.ppu
    let bg_map_hi = bg_tile_map(ppu) != 0
    igText("LCDC: BG map %s   window map %s   tile data %s",
           (if bg_map_hi: cstring"0x9C00" else: cstring"0x9800"),
           (if window_tile_map(ppu) != 0: cstring"0x9C00" else: cstring"0x9800"),
           (if bg_window_tile_data(ppu) != 0: cstring"0x8000 (unsigned)"
            else: cstring"0x8800 (signed)"))
    igText("SCX: %3d  SCY: %3d", cint(ppu.scx), cint(ppu.scy))
    if igBeginTabBar("BgMapTabBar", 0):
      d.render_bg_map_tab("0x9800", 0x1800, not bg_map_hi)
      d.render_bg_map_tab("0x9C00", 0x1C00, bg_map_hi)
      igEndTabBar()
  igEnd()

proc render_windows*(d: GbDebug) =
  if d.palette_window:
    d.render_palette_window()
  if d.tiles_window:
    d.render_tiles_window()
  if d.bgmap_window:
    d.render_bgmap_window()
