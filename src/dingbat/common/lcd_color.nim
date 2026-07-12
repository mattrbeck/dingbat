# GBA LCD color correction shared by the SDL-less embedding shells (wasm, iOS).
#
# Matches the desktop game shader exactly: linearize the 15-bit BGR555 channels
# with lcdGamma 4.0, mix channels through a fixed 3x3 matrix, then re-gamma with
# outGamma 2.2. The renderer APIs on these shells have no shader hook, but the
# BGR555 domain is only 0x8000 entries, so it is precomputed exhaustively into a
# BGR555 -> RGBA8888 table. Keep the constants here in sync with the GLSL in
# src/dingbat.nim if the correction is ever retuned.

import std/math

# Fixed-size, statically allocated (not GC heap), so it is safe to hold at
# module scope in the wasm build. Built once via init_lcd_color().
var color_lut: array[0x8000, uint32]

proc init_lcd_color*() =
  for i in 0 ..< 0x8000:
    let r = pow(float64(i and 0x1F) / 31.0, 4.0)
    let g = pow(float64((i shr 5) and 0x1F) / 31.0, 4.0)
    let b = pow(float64((i shr 10) and 0x1F) / 31.0, 4.0)
    let mixed = [
      (  0.0 * b +  50.0 * g + 255.0 * r) / 255.0,
      ( 30.0 * b + 230.0 * g +  10.0 * r) / 255.0,
      (220.0 * b +  10.0 * g +  50.0 * r) / 255.0,
    ]
    var rgb: array[3, uint32]
    for c in 0 .. 2:
      rgb[c] = uint32(min(255.0, round(pow(mixed[c], 1.0 / 2.2) * 255.0)))
    color_lut[i] = 0xFF000000'u32 or (rgb[2] shl 16) or (rgb[1] shl 8) or rgb[0]

proc convert_bgr555_rgba*(fb: ptr UncheckedArray[uint16]; dst: ptr UncheckedArray[uint32];
                          pixels: int) {.inline.} =
  ## Apply the correction LUT over `pixels` BGR555 source values into `dst`.
  ## Call init_lcd_color() once before the first use.
  for i in 0 ..< pixels:
    dst[i] = color_lut[fb[i] and 0x7FFF]
