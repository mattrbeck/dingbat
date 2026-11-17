## The desktop game shader, written once and built two ways: GLSL 3.30 for
## the OpenGL presenter and Metal Shading Language for the macOS one. The
## body below is the common subset; each prelude maps its names (float3,
## the uniform block `u`, CTX_IN/CTX for the resources MSL must pass by
## hand, GAME/BORDER for a texel fetch, LT3) onto its language.
##
## Colour correction, one model per panel (panel_gbc):
##  - GBA: the ares colour model (ISC, see THIRD_PARTY_NOTICES.md): linearize
##    γ4.0, mix, re-gamma. Matches bgr555_to_rgb and the wasm LUT.
##  - GB/GBC: Pokefan531's "GBC-Color" model. The GBA curve would crush the
##    less washed-out CGB panel's colors.
## Upscale filters follow the public hq4x/xBR descriptions. Mirrored in
## web/glpresent.js's GLSL ES shader.

type Look* = object
  ## The game shader's inputs (the uniform block `u`), sent with every draw.
  color_correct*, panel_gbc*, lcd_grid*, subpixel*, sgb_border*, dmg_remap*: bool
  filter_mode*: int  ## 0 none, 1 hq4x, 2 xBR
  tex_width*, tex_height*: float32  ## the game texture's texels
  scan_width*, scan_height*: float32  ## the output picture's pixel pitch
  sgb_backdrop*: array[3, float32]  ## 0..1 RGB
  dmg_pal*: array[12, float32]  ## four 0..1 RGB shades, lightest first

const PRESENT_BODY = """
// The four grey codes a black-and-white core writes (gb.nim DMG_COLORS), in
// 5-bit units, lightest first.
float dmg_shade(int i) {
  return i == 0 ? 31.0 : i == 1 ? 21.0 : i == 2 ? 10.0 : 0.0;
}

// A black-and-white game's four greys (gb.nim DMG_COLORS) in the shade
// palette, as web/glpresent.js fetchRGB: a pixel between two shades (the LCD
// response settling) mixes their entries; one off the ramp keeps its colour.
float3 srctex(CTX_IN float2 uv) {
  // A filter's neighbour past the picture's edge reads the edge texel, as the
  // web's and iOS's do, not the opposite edge's. uv.y runs in [-1, 0] (top
  // row at -1), so the texel row is (uv.y + 1) * height; the clamped point is
  // put back in that range, where the wrapping fetch below reads it.
  float2 size = float2(u.tex_width, u.tex_height);
  float2 p = clamp(float2(uv.x, uv.y + 1.0) * size, float2(0.5), size - 0.5);
  float3 c = GAME(float2(p.x / size.x, p.y / size.y - 1.0)).rgb;
  if (u.dmg_remap) {
    float3 v = c * 31.0;
    for (int i = 0; i < 3; i++) {
      float a = dmg_shade(i), b = dmg_shade(i + 1);
      float t = (a - v.g) / (a - b);
      if (t >= 0.0 && t <= 1.0) {
        if (all(LT3(abs(float3(mix(a, b, t)) - v), float3(1.5))))
          return mix(u.dmg_pal[i].rgb, u.dmg_pal[i + 1].rgb, t);
        break;
      }
    }
  }
  return c;
}

// BT.601 YUV; the perceptual space both filters classify edges in.
float3 yuv(float3 c) {
  return float3(dot(c, float3( 0.299,  0.587,  0.114)),
                dot(c, float3(-0.169, -0.331,  0.500)),
                dot(c, float3( 0.500, -0.419, -0.081)));
}
// xBR weighted color distance: 48*|dY| + 7*|dU| + 6*|dV|.
float df(float3 a, float3 b) {
  float3 d = abs(yuv(a) - yuv(b));
  return d.x * 48.0 + d.y * 7.0 + d.z * 6.0;
}
// hqx similar/different test: per-channel YUV thresholds 48,7,6 (8-bit units).
bool similar(float3 a, float3 b) {
  float3 d = abs(yuv(a) - yuv(b));
  return d.x <= 48.0/255.0 && d.y <= 7.0/255.0 && d.z <= 6.0/255.0;
}
// Sample the source texel-neighborhood around uv and smooth the pixel-art edge
// the fragment sits on. filter_mode picks the algorithm.
float3 upscale(CTX_IN float2 uv, float2 tsz) {
  float3 E = srctex(CTX uv);
  if (u.filter_mode == 0) return E;
  float2 t  = 1.0 / tsz;
  float2 fp = fract(uv * tsz);               // sub-texel position, 0.5 = center
  float sx = fp.x < 0.5 ? -1.0 : 1.0;        // which diagonal corner we're in
  float sy = fp.y < 0.5 ? -1.0 : 1.0;
  float lx = sx > 0.0 ? fp.x : 1.0 - fp.x;   // corner-local: 0.5 at center..1 far
  float ly = sy > 0.0 ? fp.y : 1.0 - fp.y;
  // ramp across the anti-diagonal through the active corner (lv2-style AA)
  float w = smoothstep(0.15, 0.85, lx + ly - 1.0);
  float3 Ph = srctex(CTX uv + t * float2(sx, 0.0));  // horizontal edge neighbor
  float3 Pv = srctex(CTX uv + t * float2(0.0, sy));  // vertical edge neighbor
  float3 X  = srctex(CTX uv + t * float2(sx, sy));   // diagonal neighbor

  if (u.filter_mode == 1) {                  // hq4x-style (threshold + 3px blend)
    if (!similar(E, Ph) && !similar(E, Pv) && similar(Ph, Pv))
      return mix(E, 0.5 * (Ph + Pv), w);
    return E;
  }
  // filter_mode == 2: xBR-lv2 edge-directed interpolation
  float3 C  = srctex(CTX uv + t * float2( sx, -sy));
  float3 G  = srctex(CTX uv + t * float2(-sx,  sy));
  float3 F4 = srctex(CTX uv + t * float2( 2.0 * sx, 0.0));
  float3 H5 = srctex(CTX uv + t * float2( 0.0, 2.0 * sy));
  float3 D  = srctex(CTX uv + t * float2(-sx, 0.0));
  float3 I5 = srctex(CTX uv + t * float2( sx, 2.0 * sy));
  float3 I4 = srctex(CTX uv + t * float2( 2.0 * sx, sy));
  float3 B  = srctex(CTX uv + t * float2( 0.0, -sy));
  float wd_red  = df(E, C) + df(E, G) + df(X, F4) + df(X, H5) + 4.0 * df(Pv, Ph);
  float wd_blue = df(Pv, D) + df(Pv, I5) + df(Ph, I4) + df(Ph, B) + 4.0 * df(E, X);
  if (wd_red < wd_blue) {
    float3 px = df(E, Ph) <= df(E, Pv) ? Ph : Pv;
    return mix(E, px, w);
  }
  return E;
}

float3 correct(CTX_IN float3 c) {
  float outGamma = 2.2;
  if (u.panel_gbc) {
    float3 lin = pow(c, float3(2.2)) * 0.94;
    return pow(clamp(float3(
      0.82 * lin.r + 0.240 * lin.g - 0.060 * lin.b,
      0.125 * lin.r + 0.665 * lin.g + 0.210 * lin.b,
      0.195 * lin.r + 0.075 * lin.g + 0.730 * lin.b), 0.0, 1.0),
      float3(1.0 / outGamma));
  }
  float lcdGamma = 4.0;
  float3 lin = pow(c, float3(lcdGamma));
  return pow(float3(
      0.0 * lin.b +  50.0 * lin.g + 240.0 * lin.r,
     30.0 * lin.b + 230.0 * lin.g +  10.0 * lin.r,
    220.0 * lin.b +  10.0 * lin.g +  50.0 * lin.r) / 255.0,
    float3(1.0 / outGamma));
}

// The Game Boy layer, with every filter the no-border path applies.
float3 gb_layer(CTX_IN float2 uv) {
  float3 raw = upscale(CTX uv, float2(u.tex_width, u.tex_height));
  // A shade palette is display colour already: no panel model on it.
  return u.color_correct && !u.dmg_remap ? correct(CTX raw) : raw;
}

float4 present(CTX_IN float2 tex_coord) {
  float3 rgb;
  if (u.sgb_border) {
    float4 b = BORDER(tex_coord);
    if (b.a > 0.5) {
      // Border art is native SNES output, not an LCD panel: no colour
      // correction, and the upscale filters stay off it (they are tuned for
      // 2bpp pixel art and smear 4bpp tiles).
      rgb = b.rgb;
    } else {
      // tex_coord.y runs 0 -> -1 (the vertex shader flips there), so the
      // window rectangle has to be worked out in un-flipped space and the
      // result flipped back for the sampler.
      float2 up = float2(tex_coord.x, -tex_coord.y) * float2(256.0, 224.0);
      float2 guv = (up - float2(48.0, 40.0)) / float2(160.0, 144.0);
      rgb = (guv.x >= 0.0 && guv.x < 1.0 && guv.y >= 0.0 && guv.y < 1.0)
            ? gb_layer(CTX float2(guv.x, -guv.y)) : u.sgb_backdrop.rgb;
    }
  } else {
    rgb = gb_layer(CTX tex_coord);
  }
  // "LCD grid": a thin dark seam between every pixel, on BOTH axes — the
  // pixel matrix a reflective Game Boy LCD really shows (scanlines were a CRT
  // idiom; no handheld panel has them). The seam is the trailing quarter of
  // each cell and darkens gently, so the grid reads as texture rather than as
  // bars. fract() of the negative tex_coord.y still lands in [0,1).
  if (u.lcd_grid &&
      (fract(tex_coord.x * u.scan_width) > 0.75 ||
       fract(tex_coord.y * u.scan_height) > 0.75)) {
    rgb *= 0.85;
  }
  // "RGB subpixels": draw the display's own structure — each emulated pixel
  // splits into three vertical R/G/B stripes over a darkened row gap, the way
  // a GBC/GBA TFT's subpixel triad looks up close (a DMG panel has no
  // subpixels, so there this is a stylised look, not a simulation). The
  // off-stripes keep half and a 1.35 gain rebalances overall brightness;
  // min() stops the gain pushing whites into hue shifts.
  if (u.subpixel) {
    int stripe = int(fract(tex_coord.x * u.scan_width) * 3.0);
    float3 m = stripe == 0 ? float3(1.0, 0.5, 0.5)
             : stripe == 1 ? float3(0.5, 1.0, 0.5)
             :               float3(0.5, 0.5, 1.0);
    rgb = min(rgb * m * 1.35, float3(1.0));
    if (fract(tex_coord.y * u.scan_height) > 0.85) rgb *= 0.7;
  }
  return float4(rgb, 1.0);
}
"""

# The quad: a 4-vertex strip over the viewport. tex_coord.y runs 0 at the
# bottom to -1 at the top, so with REPEAT wrapping row 0 of the texture (the
# picture's top row) lands at the top.

const GLSL_PRELUDE = """
#version 330 core
#define float2 vec2
#define float3 vec3
#define float4 vec4
#define CTX_IN
#define CTX
#define LT3(a, b) lessThan(a, b)
// SGB border: a 256x224 RGB5_A1 layer drawn over the whole quad, with the
// Game Boy window composited into the 160x144 rect at (48, 40). Alpha 0 is
// SNES colour 0 -- transparent, so the window (or the backdrop) shows through.
#define GAME(uv) texture(input_texture, uv)
#define BORDER(uv) texture(border_texture, uv)
uniform sampler2D input_texture;
uniform sampler2D border_texture;
struct Params {
  vec3 sgb_backdrop;
  vec3 dmg_pal[4];
  float tex_width;
  float tex_height;
  // The pixel pitches the LCD-grid and RGB-subpixel looks use. Equal to the
  // game texture's dims without a border; with one they are the OUTPUT dims
  // (256x224), because the SGB border and the Game Boy window are both native
  // pixels of the same picture. Feed tex_width/tex_height here instead and the
  // border gets a 160x144 grid stretched over 256x224.
  float scan_width;
  float scan_height;
  bool color_correct;
  bool panel_gbc;
  bool lcd_grid;
  bool subpixel;
  bool sgb_border;
  int filter_mode;   // 0 = none, 1 = hq4x, 2 = xBR
  bool dmg_remap;
};
uniform Params u;
"""

const GLSL_FRAG_MAIN = """
in vec2 tex_coord;
out vec4 frag_color;
void main() { frag_color = present(tex_coord); }
"""

const GAME_VERT_GLSL* = """
#version 330 core
out vec2 tex_coord;
const vec2 vertices[4] = vec2[](vec2(-1.0,-1.0),vec2(1.0,-1.0),vec2(-1.0,1.0),vec2(1.0,1.0));
void main() {
  gl_Position = vec4(vertices[gl_VertexID], 0.0, 1.0);
  tex_coord = (vertices[gl_VertexID] + 1.0) / vec2(2.0, -2.0);
}
"""

const GAME_FRAG_GLSL* = GLSL_PRELUDE & PRESENT_BODY & GLSL_FRAG_MAIN

const LOGO_VERT_GLSL* = """
#version 330 core
out vec2 tex_coord;
uniform float aspect;
uniform float scale;
const vec2 vertices[4] = vec2[](vec2(-1.0,-1.0),vec2(1.0,-1.0),vec2(-1.0,1.0),vec2(1.0,1.0));
void main() {
  vec2 scaled_xy = vec2(vertices[gl_VertexID]) * scale;
  gl_Position = vec4(scaled_xy.x, scaled_xy.y * aspect, 0.0, 1.0);
  tex_coord = (vertices[gl_VertexID] + 1.0) / vec2(2.0, -2.0);
}
"""

const LOGO_FRAG_GLSL* = """
#version 330 core
in vec2 tex_coord;
out vec4 frag_color;
uniform sampler2D input_texture;
void main() { frag_color = texture(input_texture, tex_coord); }
"""

# Metal: the game and border textures are R16Uint holding the core's BGR555
# words as they are (bit 15 the border's opaque flag), read texel by texel
# with OpenGL's NEAREST + REPEAT rule, so both presenters pick the same texel
# for every fragment and see the same v / 31 levels. Params is 128 bytes,
# laid out to need no padding; MetalParams in presenter.nim mirrors it.
const MSL_PRELUDE = """
#include <metal_stdlib>
using namespace metal;
#define CTX_IN constant Params& u, texture2d<ushort, access::read> input_texture, texture2d<ushort, access::read> border_texture,
#define CTX u, input_texture, border_texture,
#define LT3(a, b) ((a) < (b))
#define GAME(uv) texel555(input_texture, uv)
#define BORDER(uv) texel555(border_texture, uv)
struct Params {
  float4 sgb_backdrop;
  float4 dmg_pal[4];
  float tex_width;
  float tex_height;
  float scan_width;
  float scan_height;
  int color_correct;
  int panel_gbc;
  int lcd_grid;
  int subpixel;
  int sgb_border;
  int filter_mode;
  int dmg_remap;
  int pad0;
};

float4 texel555(texture2d<ushort, access::read> t, float2 uv) {
  int2 size = int2(t.get_width(), t.get_height());
  int2 i = int2(floor(uv * float2(size)));
  i = ((i % size) + size) % size;
  uint v = uint(t.read(uint2(i)).r);
  return float4(float(v & 31u) / 31.0, float((v >> 5) & 31u) / 31.0,
                float((v >> 10) & 31u) / 31.0, float(v >> 15));
}
"""

const MSL_MAIN = """
struct QuadOut {
  float4 pos [[position]];
  float2 tex_coord;
};

constant float2 QUAD[4] = { float2(-1.0, -1.0), float2(1.0, -1.0),
                            float2(-1.0,  1.0), float2(1.0,  1.0) };

vertex QuadOut game_vert(uint vid [[vertex_id]]) {
  QuadOut o;
  o.pos = float4(QUAD[vid], 0.0, 1.0);
  o.tex_coord = (QUAD[vid] + 1.0) / float2(2.0, -2.0);
  return o;
}

fragment float4 game_frag(QuadOut in [[stage_in]],
                          constant Params& u [[buffer(0)]],
                          texture2d<ushort, access::read> input_texture [[texture(0)]],
                          texture2d<ushort, access::read> border_texture [[texture(1)]]) {
  return present(u, input_texture, border_texture, in.tex_coord);
}

struct LogoParams { float aspect; float scale; };

vertex QuadOut logo_vert(uint vid [[vertex_id]], constant LogoParams& p [[buffer(0)]]) {
  QuadOut o;
  float2 xy = QUAD[vid] * p.scale;
  o.pos = float4(xy.x, xy.y * p.aspect, 0.0, 1.0);
  o.tex_coord = (QUAD[vid] + 1.0) / float2(2.0, -2.0);
  return o;
}

fragment float4 logo_frag(QuadOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
  constexpr sampler s(filter::nearest, address::repeat);
  return tex.sample(s, in.tex_coord);
}
"""

const PRESENT_MSL* = MSL_PRELUDE & PRESENT_BODY & MSL_MAIN
