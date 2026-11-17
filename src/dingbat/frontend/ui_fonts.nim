## The desktop UI's fonts, the system's UI face as the web app's
## (web/styles.css --font-ui) and iOS's:
##
##   macOS    San Francisco and SF Mono, through CoreText (mac_font.mm)
##   Windows  Segoe UI, Segoe UI Semibold and Consolas, from %WINDIR%\Fonts
##   Linux    Inter (vendor/fonts, OFL; Linux has no standard UI font), and
##            ImGui's built-in ProggyClean for the monospaced text
##
## Inter is compiled in everywhere: a face that does not load (no Segoe UI
## under Wine) falls back to it, the monospaced one to ProggyClean.
##
## ImGui sizes a font by its line (ascent + descent). The UI code gives
## sizes as the web's CSS px, of the em: font_px turns one into ImGui's.

import std/os
import imguin/cimgui

when defined(macosx):
  import imgui_paths
  {.compile("mac_font.mm", "-fobjc-arc").}
  {.passL: "-framework AppKit -framework CoreText".}
  proc dingbat_mac_font(atlas: ptr ImFontAtlas; face: cint; line: ptr cfloat): ptr ImFont
    {.importc, cdecl.}

type Face* = enum
  fRegular, fBold, fMono   ## fBold is semibold (600), the web's headings and buttons

const
  BODY_PX* = 14'f32    ## the web's body text
  SMALL_PX* = 12'f32   ## hints, notes
  MONO_PX* = 13'f32    ## debug windows, the overlay
  PROGGY_PX = 13'f32   ## ProggyClean is crisp at 13 px only

const
  INTER_REGULAR_TTF = staticRead("vendor/fonts/Inter-Regular.ttf")
  INTER_SEMIBOLD_TTF = staticRead("vendor/fonts/Inter-SemiBold.ttf")
let
  INTER_REGULAR* = INTER_REGULAR_TTF
  INTER_SEMIBOLD* = INTER_SEMIBOLD_TTF

var
  faces*: array[Face, ptr ImFont]
  face_names*: array[Face, string]   ## what loaded, for the log
  line_em: array[Face, float32] = [1'f32, 1, 1]
  proggy_mono = false

proc ttf_line_em*(data: string): float32 =
  ## A TrueType/OpenType font's (hhea ascender - descender) / unitsPerEm, the
  ## line stb_truetype sizes it by; 0 when `data` is not one.
  if data.len < 12: return 0
  if data[0 .. 3] notin ["\0\1\0\0", "OTTO", "true"]: return 0
  proc u16(o: int): int = (ord(data[o]) shl 8) or ord(data[o + 1])
  proc i16(o: int): int = (let v = u16(o); if v >= 0x8000: v - 0x10000 else: v)
  proc u32(o: int): int = (u16(o) shl 16) or u16(o + 2)
  var head, hhea = -1
  for i in 0 ..< u16(4):
    let r = 12 + 16 * i
    if r + 16 > data.len: return 0
    case data[r .. r + 3]
    of "head": head = u32(r + 8)
    of "hhea": hhea = u32(r + 8)
    else: discard
  if head < 0 or hhea < 0 or head + 20 > data.len or hhea + 8 > data.len: return 0
  let upem = u16(head + 18)
  let line = i16(hhea + 4) - i16(hhea + 6)
  if upem <= 0 or line <= 0: 0 else: float32(line) / float32(upem)

proc add_ttf*(atlas: ptr ImFontAtlas; data: string; name: string): ptr ImFont =
  ## A font from its file's bytes (ImGui keeps a copy); nil if not a font
  if ttf_line_em(data) <= 0: return nil
  let cfg = ImFontConfig_ImFontConfig()
  cfg.FontDataOwnedByAtlas = false
  for i, c in name:
    if i < cfg.Name.len - 1: cfg.Name[i] = cschar(c)
  result = ImFontAtlas_AddFontFromMemoryTTF(atlas, unsafeAddr data[0], cint(data.len),
                                            16, cfg, nil)
  ImFontConfig_destroy(cfg)

proc add_proggy(atlas: ptr ImFontAtlas): ptr ImFont =
  when compiles(ImFontAtlas_AddFontDefaultBitmap(atlas, nil)):
    ImFontAtlas_AddFontDefaultBitmap(atlas, nil)
  else:
    ImFontAtlas_AddFontDefault(atlas, nil)

proc load_ui_fonts*(atlas: ptr ImFontAtlas) =
  ## The three faces into ImGui's atlas, the regular one first (ImGui's
  ## default font)
  proc put(f: Face; font: ptr ImFont; name: string; line: float32) =
    faces[f] = font
    face_names[f] = name
    line_em[f] = line
  when defined(macosx):
    for f in Face:
      var line: cfloat
      let font = dingbat_mac_font(atlas, cint(ord(f)), addr line)
      if font != nil and line > 0:
        put(f, font, ["SF", "SF Semibold", "SF Mono"][ord(f)], line)
  elif defined(windows):
    let dir = getEnv("WINDIR", "C:\\Windows") / "Fonts"
    for (f, file, name) in [(fRegular, "segoeui.ttf", "Segoe UI"),
                            (fBold, "seguisb.ttf", "Segoe UI Semibold"),
                            (fMono, "consola.ttf", "Consolas")]:
      var data = ""
      try: data = readFile(dir / file)
      except IOError: discard
      let font = atlas.add_ttf(data, name)
      if font != nil: put(f, font, name, ttf_line_em(data))
  for (f, data, name) in [(fRegular, INTER_REGULAR, "Inter"),
                          (fBold, INTER_SEMIBOLD, "Inter SemiBold")]:
    if faces[f] == nil: put(f, atlas.add_ttf(data, name), name, ttf_line_em(data))
  if faces[fMono] == nil:
    put(fMono, atlas.add_proggy(), "ProggyClean", 1)
    proggy_mono = true

proc font_px*(css: float32; face = fRegular): float32 =
  ## ImGui's size, before the UI scale, of `face` with an em of `css` px
  if face == fMono and proggy_mono: PROGGY_PX
  else: css * line_em[face]

proc push_font*(face: Face; css: float32) = igPushFont(faces[face], font_px(css, face))

template with_font*(face: Face; css: float32; body: untyped) =
  push_font(face, css)
  body
  igPopFont()
