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
  system_data: array[Face, string]  ## the files' bytes, which ImGui reads for as long as it runs

proc ttf_table(data: string; tag: string): int =
  ## Where a TrueType/OpenType font's table is; -1 if `data` has none
  if data.len < 12 or data[0 .. 3] notin ["\0\1\0\0", "OTTO", "true"]: return -1
  for i in 0 ..< ((ord(data[4]) shl 8) or ord(data[5])):
    let r = 12 + 16 * i
    if r + 16 > data.len: return -1
    if data[r .. r + 3] == tag:
      return (ord(data[r + 8]) shl 24) or (ord(data[r + 9]) shl 16) or
             (ord(data[r + 10]) shl 8) or ord(data[r + 11])
  -1

proc u16(data: string; o: int): int =
  if o < 0 or o + 2 > data.len: -1 else: (ord(data[o]) shl 8) or ord(data[o + 1])

proc ttf_line_em*(data: string): float32 =
  ## A font's (hhea ascender - descender) / unitsPerEm, the line
  ## stb_truetype sizes it by; 0 when `data` is not one.
  let head = ttf_table(data, "head")
  let hhea = ttf_table(data, "hhea")
  if head < 0 or hhea < 0 or head + 20 > data.len or hhea + 8 > data.len: return 0
  proc i16(o: int): int = (let v = data.u16(o); if v >= 0x8000: v - 0x10000 else: v)
  let upem = data.u16(head + 18)
  let line = i16(hhea + 4) - i16(hhea + 6)
  if upem <= 0 or line <= 0: 0 else: float32(line) / float32(upem)

proc stb_cmap_format*(data: string): int =
  ## The format of the character map stb_truetype would read (the last
  ## Unicode or Windows Unicode one); -1 for none. It asserts on any but
  ## 0, 4, 6, 12 and 13 at the first glyph looked up.
  let cmap = ttf_table(data, "cmap")
  result = -1
  if cmap < 0: return
  for i in 0 ..< max(0, data.u16(cmap + 2)):
    let rec = cmap + 4 + 8 * i
    let platform = data.u16(rec)
    if platform == 0 or (platform == 3 and data.u16(rec + 2) in [1, 10]):
      let off = cmap + ((data.u16(rec + 4) shl 16) or data.u16(rec + 6))
      result = data.u16(off)

proc add_ttf*(atlas: ptr ImFontAtlas; data: string; name: string): ptr ImFont =
  ## A font from its file's bytes, which must outlive the atlas (ImGui 1.92
  ## reads them in place); nil if not one stb_truetype can read
  if ttf_line_em(data) <= 0: return nil
  let fmt = stb_cmap_format(data)
  if fmt notin [0, 4, 6, 12, 13]:
    echo "UI font ", name, ": character map format ", fmt, ", not loaded"
    return nil
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
      try: system_data[f] = readFile(dir / file)
      except IOError: discard
      let font = atlas.add_ttf(system_data[f], name)
      if font != nil: put(f, font, name, ttf_line_em(system_data[f]))
  # The globals themselves, not copies: ImGui reads them in place
  if faces[fRegular] == nil:
    put(fRegular, atlas.add_ttf(INTER_REGULAR, "Inter"), "Inter", ttf_line_em(INTER_REGULAR))
  if faces[fBold] == nil:
    put(fBold, atlas.add_ttf(INTER_SEMIBOLD, "Inter SemiBold"), "Inter SemiBold",
        ttf_line_em(INTER_SEMIBOLD))
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
