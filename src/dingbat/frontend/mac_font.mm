// The macOS system font (San Francisco, SF Mono) for ImGui, rasterised by
// CoreText: an ImFontLoader (ImGui 1.92's font backend interface). Read from
// the system at run time, never copied: SF's licence forbids redistribution.
// stb_truetype cannot pick SFNS.ttf's weight or optical size (it reads the
// variable font's default, Display Regular); CoreText picks the Text cut at
// UI sizes, as AppKit draws it.
//
// Sizes are ImGui's: a font's size is its line (ascent + descent), as
// stb_truetype's ScaleForPixelHeight. A glyph CoreText lacks is drawn from
// the font it falls back to (a Japanese game name), while
// FontSrcContainsGlyph answers for SF alone (the UI strings' glyph check).

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#include <math.h>
#include "imgui.h"
#include "imgui_internal.h"

enum { FACE_REGULAR, FACE_BOLD, FACE_MONO };

static NSFont* face_font(int face, CGFloat size) {
  switch (face) {
    case FACE_BOLD: return [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
    case FACE_MONO: return [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
    default: return [NSFont systemFontOfSize:size weight:NSFontWeightRegular];
  }
}

// A line's height per em, from a reference size
static float line_em(int face) {
  CTFontRef f = (__bridge CTFontRef)face_font(face, 100);
  return (float)((CTFontGetAscent(f) + CTFontGetDescent(f)) / 100.0);
}

struct SrcData { int face; float line_em; CTFontRef ref; };
struct BakedData { CTFontRef font; };   // at the baked size's em, in points

static bool src_init(ImFontAtlas*, ImFontConfig* src) {
  SrcData* d = IM_NEW(SrcData);
  d->face = src->FontNo;
  d->line_em = line_em(d->face);
  d->ref = (CTFontRef)CFBridgingRetain(face_font(d->face, 100));
  src->FontLoaderData = d;
  return true;
}

static void src_destroy(ImFontAtlas*, ImFontConfig* src) {
  SrcData* d = (SrcData*)src->FontLoaderData;
  if (d) { CFRelease(d->ref); IM_DELETE(d); }
  src->FontLoaderData = NULL;
}

static int utf16(ImWchar c, UniChar out[2]) {
  unsigned int u = (unsigned int)c;
  if (u < 0x10000) { out[0] = (UniChar)u; return 1; }
  u -= 0x10000;
  out[0] = (UniChar)(0xD800 + (u >> 10));
  out[1] = (UniChar)(0xDC00 + (u & 0x3FF));
  return 2;
}

static bool src_contains(ImFontAtlas*, ImFontConfig* src, ImWchar c) {
  SrcData* d = (SrcData*)src->FontLoaderData;
  UniChar ch[2];
  CGGlyph g[2] = {0, 0};
  int n = utf16(c, ch);
  return CTFontGetGlyphsForCharacters(d->ref, ch, g, n) && g[0] != 0;
}

static bool baked_init(ImFontAtlas*, ImFontConfig* src, ImFontBaked* baked, void* data) {
  SrcData* d = (SrcData*)src->FontLoaderData;
  BakedData* b = (BakedData*)data;
  CGFloat em = baked->Size / d->line_em;
  b->font = (CTFontRef)CFBridgingRetain(face_font(d->face, em));
  if (!src->MergeMode) {
    baked->Ascent = ceilf((float)CTFontGetAscent(b->font));
    baked->Descent = floorf(-(float)CTFontGetDescent(b->font));
  }
  return true;
}

static void baked_destroy(ImFontAtlas*, ImFontConfig*, ImFontBaked*, void* data) {
  BakedData* b = (BakedData*)data;
  if (b->font) CFRelease(b->font);
  b->font = NULL;
}

static bool load_glyph(ImFontAtlas* atlas, ImFontConfig* src, ImFontBaked* baked, void* data,
                       ImWchar c, ImFontGlyph* out_glyph, float* out_advance_x) {
  BakedData* b = (BakedData*)data;
  UniChar ch[2];
  CGGlyph g[2] = {0, 0};
  int n = utf16(c, ch);
  CTFontRef font = b->font;
  CTFontRef fallback = NULL;
  if (!CTFontGetGlyphsForCharacters(font, ch, g, n) || g[0] == 0) {
    CFStringRef s = CFStringCreateWithCharacters(NULL, ch, n);
    fallback = CTFontCreateForString(font, s, CFRangeMake(0, n));
    CFRelease(s);
    if (!fallback || !CTFontGetGlyphsForCharacters(fallback, ch, g, n) || g[0] == 0) {
      if (fallback) CFRelease(fallback);
      return false;
    }
    font = fallback;
  }
  CGSize adv;
  CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, g, &adv, 1);
  if (out_advance_x) {
    *out_advance_x = (float)adv.width;
    if (fallback) CFRelease(fallback);
    return true;
  }
  out_glyph->Codepoint = c;
  out_glyph->AdvanceX = (float)adv.width;

  // Rasterised at the display's density, oversampled across as
  // stb_truetype's loader is at small sizes, then box-filtered so ImGui's
  // linear sampling between those columns stays even
  int os_h, os_v;
  ImFontAtlasBuildGetOversampleFactors(src, baked, &os_h, &os_v);
  const float density = src->RasterizerDensity * baked->RasterizerDensity;
  const float sx = density * os_h, sy = density;
  CGRect box = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, g, NULL, 1);
  if (box.size.width > 0 && box.size.height > 0) {
    const int x0 = (int)floor(box.origin.x * sx) - 1;
    const int x1 = (int)ceil((box.origin.x + box.size.width) * sx) + 1;
    const int y0 = (int)floor(box.origin.y * sy) - 1;           // y up from the baseline
    const int y1 = (int)ceil((box.origin.y + box.size.height) * sy) + 1;
    const int gw = x1 - x0, h = y1 - y0;
    const int w = gw + os_h - 1;
    ImFontAtlasRectId pack_id = ImFontAtlasPackAddRect(atlas, w, h);
    if (pack_id == ImFontAtlasRectId_Invalid) {
      if (fallback) CFRelease(fallback);
      return false;
    }
    ImTextureRect* r = ImFontAtlasPackGetRect(atlas, pack_id);
    ImVector<unsigned char>& buf = atlas->Builder->TempBuffer;
    buf.resize(w * h * 2);
    unsigned char* raster = buf.Data;
    unsigned char* pixels = buf.Data + w * h;
    memset(raster, 0, w * h);
    CGContextRef ctx = CGBitmapContextCreate(raster, w, h, 8, w, NULL, kCGImageAlphaOnly);
    CGContextSetAllowsAntialiasing(ctx, true);
    CGContextSetShouldAntialias(ctx, true);
    CGContextSetAllowsFontSmoothing(ctx, false);
    CGContextSetShouldSmoothFonts(ctx, false);
    CGContextSetAllowsFontSubpixelPositioning(ctx, true);
    CGContextSetShouldSubpixelPositionFonts(ctx, true);
    CGContextScaleCTM(ctx, sx, sy);
    CGPoint at = CGPointMake(-x0 / sx, -y0 / sy);
    CTFontDrawGlyphs(font, g, &at, 1, ctx);
    CGContextRelease(ctx);
    // The bitmap's first row is its top; a box filter os_h wide across
    for (int y = 0; y < h; y++) {
      const unsigned char* src_row = raster + y * w;
      unsigned char* dst_row = pixels + y * w;
      int sum = 0;
      for (int x = 0; x < w; x++) {
        if (x < gw) sum += src_row[x];
        if (x - os_h >= 0 && x - os_h < gw) sum -= src_row[x - os_h];
        dst_row[x] = (unsigned char)(sum / os_h);
      }
    }
    // (the filter moves the picture (os_h - 1) / 2 columns right)
    const float ox = ((float)x0 - (os_h - 1) * 0.5f) / sx, oy = IM_ROUND(baked->Ascent) - (float)y1 / sy;
    out_glyph->X0 = ox;
    out_glyph->Y0 = oy;
    out_glyph->X1 = ox + (float)w / sx;
    out_glyph->Y1 = oy + (float)h / sy;
    out_glyph->Visible = true;
    out_glyph->PackId = pack_id;
    ImFontAtlasBakedSetFontGlyphBitmap(atlas, baked, src, out_glyph, r, pixels,
                                       ImTextureFormat_Alpha8, w);
  }
  if (fallback) CFRelease(fallback);
  return true;
}

static const ImFontLoader* loader() {
  static ImFontLoader l;
  if (!l.Name) {
    l.Name = "CoreText";
    l.FontSrcInit = src_init;
    l.FontSrcDestroy = src_destroy;
    l.FontSrcContainsGlyph = src_contains;
    l.FontBakedInit = baked_init;
    l.FontBakedDestroy = baked_destroy;
    l.FontBakedLoadGlyph = load_glyph;
    l.FontBakedSrcLoaderDataSize = sizeof(BakedData);
  }
  return &l;
}

// face: 0 regular, 1 semibold, 2 mono. *line: a line's height per em.
extern "C" ImFont* dingbat_mac_font(ImFontAtlas* atlas, int face, float* line) {
  ImFontConfig cfg;
  cfg.FontLoader = loader();
  cfg.FontNo = face;
  cfg.SizePixels = 16;   // a reference only; every size is the baked one
  snprintf(cfg.Name, sizeof(cfg.Name), "%s", face == FACE_BOLD ? "SF Semibold" :
           face == FACE_MONO ? "SF Mono" : "SF");
  *line = line_em(face);
  return atlas->AddFont(&cfg);
}
