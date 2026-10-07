// The game presenter: web/glpresent.js's FRAG in Metal Shading Language, so
// the app draws the same picture as the web build (colour models, hq4x/xBR,
// LCD grid, RGB subpixels, Game Boy shade palettes, Super Game Boy border).
// Compiled at launch with makeLibrary(source:), so building the app needs
// no Metal toolchain.

let presentShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct VOut {
  float4 pos [[position]];
  float2 uv;
};

// Full-screen triangle; uv row 0 is the framebuffer's top row.
vertex VOut present_vertex(uint vid [[vertex_id]]) {
  float2 p = float2(float((vid << 1) & 2), float(vid & 2));
  VOut o;
  o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
  o.uv = float2(p.x, 1.0 - p.y);
  return o;
}

struct PresentUniforms {
  float2 texSize;      // game texel dimensions
  float scanWidth;     // OUTPUT pixel pitch (256x224 with a border)
  float scanHeight;
  int filter;          // 0 none, 1 hq4x, 2 xBR
  int colorCorrect;
  int panelGbc;
  int grid;
  int subpixel;
  int dmgRemap;
  int sgbBorder;
  int pad0;
  float4 sgbBackdrop;
  float4 dmgPal[4];    // sRGB 0..1, shade 0 (lightest) -> 3
};

constant float3 DMG_SHADE[4] = { float3(31.0, 30.0, 26.0),   // 0x6BDF
                                 float3(31.0, 21.0, 14.0),   // 0x3ABF
                                 float3(29.0, 13.0, 13.0),   // 0x35BD
                                 float3(15.0,  7.0, 11.0) }; // 0x2CEF

struct Ctx {
  texture2d<ushort, access::read> tex;
  constant PresentUniforms &u;
  int2 gmax;
};

static float3 fetchRGB(thread const Ctx &c, int2 p) {
  uint2 q = uint2(clamp(p, int2(0), c.gmax));
  uint packed = uint(c.tex.read(q).r) & 0x7FFFu;
  float3 col = float3(float(packed & 31u),
                      float((packed >> 5) & 31u),
                      float((packed >> 10) & 31u));
  if (c.u.dmgRemap != 0) {
    for (int i = 0; i < 3; i++) {
      float3 a = DMG_SHADE[i], b = DMG_SHADE[i + 1];
      float t = (a.y - col.y) / (a.y - b.y);
      if (t >= 0.0 && t <= 1.0) {
        if (all(abs(mix(a, b, t) - col) < float3(1.5)))
          return mix(c.u.dmgPal[i].rgb, c.u.dmgPal[i + 1].rgb, t);
        break;
      }
    }
  }
  return col / 31.0;
}

static float3 yuv(float3 c) {
  return float3(dot(c, float3( 0.299,  0.587,  0.114)),
                dot(c, float3(-0.169, -0.331,  0.500)),
                dot(c, float3( 0.500, -0.419, -0.081)));
}

static float df(float3 a, float3 b) {
  float3 d = abs(yuv(a) - yuv(b));
  return d.x * 48.0 + d.y * 7.0 + d.z * 6.0;
}

static bool similar(float3 a, float3 b) {
  float3 d = abs(yuv(a) - yuv(b));
  return d.x <= 48.0 / 255.0 && d.y <= 7.0 / 255.0 && d.z <= 6.0 / 255.0;
}

static float3 unpack555(uint packed) {
  return float3(float(packed & 31u),
                float((packed >> 5) & 31u),
                float((packed >> 10) & 31u)) / 31.0;
}

static float3 upscale(thread const Ctx &c, float2 uv) {
  float2 pos = uv * c.u.texSize;
  int2 base = int2(floor(pos));
  float3 E = fetchRGB(c, base);
  if (c.u.filter == 0) return E;
  float2 fp = fract(pos);
  int sx = fp.x < 0.5 ? -1 : 1;
  int sy = fp.y < 0.5 ? -1 : 1;
  float lx = sx > 0 ? fp.x : 1.0 - fp.x;
  float ly = sy > 0 ? fp.y : 1.0 - fp.y;
  float w = smoothstep(0.15, 0.85, lx + ly - 1.0);
  float3 Ph = fetchRGB(c, base + int2(sx, 0));
  float3 Pv = fetchRGB(c, base + int2(0, sy));
  float3 X  = fetchRGB(c, base + int2(sx, sy));

  if (c.u.filter == 1) {
    if (!similar(E, Ph) && !similar(E, Pv) && similar(Ph, Pv))
      return mix(E, 0.5 * (Ph + Pv), w);
    return E;
  }
  float3 C  = fetchRGB(c, base + int2( sx, -sy));
  float3 G  = fetchRGB(c, base + int2(-sx,  sy));
  float3 F4 = fetchRGB(c, base + int2( 2 * sx, 0));
  float3 H5 = fetchRGB(c, base + int2( 0, 2 * sy));
  float3 D  = fetchRGB(c, base + int2(-sx, 0));
  float3 I5 = fetchRGB(c, base + int2( sx, 2 * sy));
  float3 I4 = fetchRGB(c, base + int2( 2 * sx, sy));
  float3 B  = fetchRGB(c, base + int2( 0, -sy));
  float wd_red  = df(E, C) + df(E, G) + df(X, F4) + df(X, H5) + 4.0 * df(Pv, Ph);
  float wd_blue = df(Pv, D) + df(Pv, I5) + df(Ph, I4) + df(Ph, B) + 4.0 * df(E, X);
  if (wd_red < wd_blue) {
    float3 px = df(E, Ph) <= df(E, Pv) ? Ph : Pv;
    return mix(E, px, w);
  }
  return E;
}

// The panel colour model, applied to the Game Boy layer only.
static float3 shade(constant PresentUniforms &u, float3 c) {
  if (u.colorCorrect != 0 && u.dmgRemap == 0) {
    if (u.panelGbc != 0) {
      float3 lin = pow(c, float3(2.2)) * 0.94;
      return pow(clamp(float3(
        0.82 * lin.r + 0.125 * lin.g + 0.195 * lin.b,
        0.24 * lin.r + 0.665 * lin.g + 0.075 * lin.b,
       -0.06 * lin.r + 0.210 * lin.g + 0.730 * lin.b), 0.0, 1.0),
        float3(1.0 / 2.2));
    }
    float3 lin = pow(c, float3(4.0));
    return pow(float3(
        0.0 * lin.b +  50.0 * lin.g + 240.0 * lin.r,
       30.0 * lin.b + 230.0 * lin.g +  10.0 * lin.r,
      220.0 * lin.b +  10.0 * lin.g +  50.0 * lin.r) / 255.0,
      float3(1.0 / 2.2));
  }
  return c;
}

fragment float4 present_fragment(VOut in [[stage_in]],
                                 texture2d<ushort, access::read> tex [[texture(0)]],
                                 texture2d<ushort, access::read> border [[texture(1)]],
                                 constant PresentUniforms &u [[buffer(0)]]) {
  Ctx c = { tex, u, int2(u.texSize) - int2(1) };
  float2 uv = in.uv;
  float3 rgb;
  if (u.sgbBorder != 0) {
    int2 bp = clamp(int2(uv * float2(256.0, 224.0)), int2(0), int2(255, 223));
    uint bw = uint(border.read(uint2(bp)).r);
    if ((bw & 0x8000u) != 0u) {
      rgb = unpack555(bw & 0x7FFFu);
    } else {
      float2 guv = (uv * float2(256.0, 224.0) - float2(48.0, 40.0)) / float2(160.0, 144.0);
      rgb = (guv.x >= 0.0 && guv.x < 1.0 && guv.y >= 0.0 && guv.y < 1.0)
            ? shade(u, upscale(c, guv)) : u.sgbBackdrop.rgb;
    }
  } else {
    rgb = shade(u, upscale(c, uv));
  }
  // "LCD grid": a thin dark seam on both axes between every pixel.
  if (u.grid != 0 &&
      (fract(uv.x * u.scanWidth) > 0.75 || fract(uv.y * u.scanHeight) > 0.75)) {
    rgb *= 0.85;
  }
  // "RGB subpixels": three vertical stripes per pixel over a darkened gap.
  if (u.subpixel != 0) {
    int stripe = int(fract(uv.x * u.scanWidth) * 3.0);
    float3 m = stripe == 0 ? float3(1.0, 0.5, 0.5)
             : stripe == 1 ? float3(0.5, 1.0, 0.5)
             :               float3(0.5, 0.5, 1.0);
    rgb = min(rgb * m * 1.35, float3(1.0));
    if (fract(uv.y * u.scanHeight) > 0.85) rgb *= 0.7;
  }
  return float4(rgb, 1.0);
}
"""#
