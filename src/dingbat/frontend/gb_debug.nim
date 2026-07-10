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
  discard igBegin("Palettes", addr d.palette_window, 0)
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
  discard igBegin("Tiles", addr d.tiles_window, 0)
  let (w, h) = d.build_tiles()
  upload_texture(d.tiles_tex, addr d.tiles_buf[0], w, h)
  if d.gb.cgb_enabled:
    igTextUnformatted("Bank 0", nil)
    igSameLine(cfloat(TILE_COLS * 8) * TILES_SCALE + 8, -1)
    igTextUnformatted("Bank 1", nil)
  debug_image(d.tiles_tex, float32(w) * TILES_SCALE, float32(h) * TILES_SCALE)
  igEnd()

proc render_windows*(d: GbDebug) =
  if d.palette_window:
    d.render_palette_window()
  if d.tiles_window:
    d.render_tiles_window()
