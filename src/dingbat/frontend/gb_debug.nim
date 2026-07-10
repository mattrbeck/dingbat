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

proc render_windows*(d: GbDebug) =
  if d.palette_window:
    d.render_palette_window()
