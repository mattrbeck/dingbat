## The desktop UI's fonts, the system's UI face as the web app's
## (web/styles.css --font-ui) and iOS's:
##
##   macOS    San Francisco and SF Mono, through CoreText (mac_font.mm)
##   Windows  Segoe UI, Segoe UI Semibold and Consolas, from %WINDIR%\Fonts
##   Linux    Inter and JetBrains Mono (vendor/fonts, OFL; Linux has no
##            standard UI font)
##
## Inter and JetBrains Mono are compiled in on Windows and Linux: a face that
## does not load (no Segoe UI under Wine) falls back to them. macOS has SF
## everywhere, so neither: a face that does not load there is ImGui's
## ProggyClean.
##
## Windows and Linux draw them with FreeType (Dear ImGui's imgui_freetype,
## vendor/), hinted by each font's own TrueType instructions, linked
## statically from build-freetype.sh's prefix where there is one
## (-d:freetype_prefix=DIR names another), else the system's. The test
## builds (-d:test_harness) keep ImGui's stb_truetype and need no FreeType.
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

const FREETYPE* = not defined(macosx) and not defined(test_harness)
when FREETYPE:
  const freetype_prefix {.strdefine.} = ""
  const FT_ROOT =
    when freetype_prefix.len > 0: freetype_prefix
    elif defined(windows): "/usr/x86_64-w64-mingw32"   # the mingw sysroot, as SDL 3's
    elif fileExists("/usr/local/lib/libfreetype.a"): "/usr/local"
    else: "/usr"
  {.passC: "-I" & FT_ROOT & "/include/freetype2".}
  when fileExists(FT_ROOT & "/lib/libfreetype.a"):
    {.passL: FT_ROOT & "/lib/libfreetype.a".}
  else:
    {.passL: "-lfreetype".}
  {.compile: "vendor/imgui_freetype.cpp".}
  {.compile: "freetype_loader.cpp".}
  proc dingbat_freetype_loader(): ptr ImFontLoader {.importc, cdecl.}

type Face* = enum
  fRegular, fBold, fMono   ## fBold is semibold (600), the web's headings and buttons

const
  BODY_PX* = 14'f32    ## the web's body text
  SMALL_PX* = 12'f32   ## hints, notes
  MONO_PX* = 13'f32    ## debug windows, the overlay, cheat codes
  PROGGY_PX = 13'f32   ## ProggyClean is crisp at 13 px only

const FONT_DIR* = currentSourcePath().parentDir & "/vendor/fonts"  ## Inter's and JetBrains Mono's files
when not defined(macosx):
  const
    INTER_REGULAR_TTF = staticRead("vendor/fonts/Inter-Regular.ttf")
    INTER_SEMIBOLD_TTF = staticRead("vendor/fonts/Inter-SemiBold.ttf")
    JETBRAINS_MONO_TTF = staticRead("vendor/fonts/JetBrainsMono-Regular.ttf")
  let
    INTER_REGULAR* = INTER_REGULAR_TTF
    INTER_SEMIBOLD* = INTER_SEMIBOLD_TTF
    JETBRAINS_MONO* = JETBRAINS_MONO_TTF

var
  faces*: array[Face, ptr ImFont]
  face_names*: array[Face, string]   ## what loaded, for the log
  line_em: array[Face, float32] = [1'f32, 1, 1]
  proggy: array[Face, bool]  ## drawn in ProggyClean, crisp at its one size
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

proc i16(data: string; o: int): int =
  let v = data.u16(o)
  if v >= 0x8000: v - 0x10000 else: v

proc ttf_line_em*(data: string): float32 =
  ## A font's (hhea ascender - descender) / unitsPerEm, the line
  ## stb_truetype and FreeType size it by; 0 when `data` is not one.
  let head = ttf_table(data, "head")
  let hhea = ttf_table(data, "hhea")
  if head < 0 or hhea < 0 or head + 20 > data.len or hhea + 8 > data.len: return 0
  let upem = data.u16(head + 18)
  let line = data.i16(hhea + 4) - data.i16(hhea + 6)
  if upem <= 0 or line <= 0: 0 else: float32(line) / float32(upem)

proc ttf_cap_low_em*(data: string): float32 =
  ## How far below the middle of its line (em) a font's capitals sit:
  ## (ascender + descender - capHeight) / 2 (the descender negative), from
  ## hhea and OS/2; 0 without a capHeight. Segoe UI's tall ascender puts
  ## them 0.064 em low; Inter's and JetBrains Mono's are within 0.005.
  let head = ttf_table(data, "head")
  let hhea = ttf_table(data, "hhea")
  let os2 = ttf_table(data, "OS/2")
  if head < 0 or hhea < 0 or os2 < 0 or data.u16(os2) < 2 or
     os2 + 90 > data.len or hhea + 8 > data.len: return 0
  let upem = data.u16(head + 18)
  let cap = data.i16(os2 + 88)
  if upem <= 0 or cap <= 0: return 0
  float32(data.i16(hhea + 4) + data.i16(hhea + 6) - cap) / float32(2 * upem)

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
  ## reads them in place), its capitals centred in its line; nil if not one
  ## the loader can read
  let line = ttf_line_em(data)
  if line <= 0: return nil
  let fmt = stb_cmap_format(data)
  if not FREETYPE and fmt notin [0, 4, 6, 12, 13]:
    echo "UI font ", name, ": character map format ", fmt, ", not loaded"
    return nil
  let cfg = ImFontConfig_ImFontConfig()
  cfg.FontDataOwnedByAtlas = false
  for i, c in name:
    if i < cfg.Name.len - 1: cfg.Name[i] = cschar(c)
  # In the 16 px line's units; ImGui scales it to each size and rounds it
  # to a whole pixel (PixelSnapV)
  cfg.GlyphOffset.y = -ttf_cap_low_em(data) * 16 / line
  result = ImFontAtlas_AddFontFromMemoryTTF(atlas, unsafeAddr data[0], cint(data.len),
                                            16, cfg, nil)
  ImFontConfig_destroy(cfg)

proc add_proggy(atlas: ptr ImFontAtlas): ptr ImFont =
  when compiles(ImFontAtlas_AddFontDefaultBitmap(atlas, nil)):
    ImFontAtlas_AddFontDefaultBitmap(atlas, nil)
  else:
    ImFontAtlas_AddFontDefault(atlas, nil)

proc load_ui_fonts*(atlas: ptr ImFontAtlas) =
  ## The three faces into ImGui's atlas; the regular one is ImGui's default
  proc put(f: Face; font: ptr ImFont; name: string; line: float32) =
    faces[f] = font
    face_names[f] = name
    line_em[f] = line
  when FREETYPE:
    ImFontAtlas_SetFontLoader(atlas, dingbat_freetype_loader())
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
  when not defined(macosx):
    # The globals themselves, not copies: ImGui reads them in place
    for (f, data, name) in [(fRegular, addr INTER_REGULAR, "Inter"),
                            (fBold, addr INTER_SEMIBOLD, "Inter SemiBold"),
                            (fMono, addr JETBRAINS_MONO, "JetBrains Mono")]:
      if faces[f] == nil:
        put(f, atlas.add_ttf(data[], name), name, ttf_line_em(data[]))
  var pc: ptr ImFont
  for f in Face:
    if faces[f] == nil:
      if pc == nil: pc = atlas.add_proggy()
      put(f, pc, "ProggyClean", 1)
      proggy[f] = true
  igGetIO_Nil().FontDefault = faces[fRegular]

proc font_px*(css: float32; face = fRegular): float32 =
  ## ImGui's size, before the UI scale, of `face` with an em of `css` px
  if proggy[face]: PROGGY_PX
  else: css * line_em[face]

proc push_font*(face: Face; css: float32) = igPushFont(faces[face], font_px(css, face))

template with_font*(face: Face; css: float32; body: untyped) =
  push_font(face, css)
  body
  igPopFont()
