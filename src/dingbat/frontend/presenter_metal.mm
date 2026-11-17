// The macOS Metal presenter: presenter_metal.nim's C calls. One CAMetalLayer
// (SDL_Metal_GetLayer), one command buffer a present: the frame's draws are
// encoded into the layer's next drawable and committed with it at present.
//
// The game texture is a ring of R16Uint textures written with replaceRegion:
// a present that uploads takes the next one, so a texture the GPU may still
// be reading is never written. At most MAX_INFLIGHT presents are on the GPU
// (the semaphore) and RING > MAX_INFLIGHT, which keeps that true even for
// presents that reuse an older upload (a still GBA frame uploads nothing).
// Rarely changed textures (border, logo, ImGui images) are replaced whole
// instead: an in-flight command buffer keeps the old one alive.

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <string.h>
#include "vendor/imgui_impl_metal.h"

enum { RING = 3, MAX_INFLIGHT = 2 };

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static CAMetalLayer* layer;
static id<MTLRenderPipelineState> game_pso, logo_pso, ui_nearest_pso;
static id<MTLTexture> game_ring[RING];
static int game_cur, game_w, game_h;
static bool game_uploaded;  // this present has taken its ring slot
static id<MTLTexture> border_tex, logo_tex;
static dispatch_semaphore_t inflight;

// The present being built
static id<CAMetalDrawable> drawable;
static id<MTLTexture> target;      // the drawable's texture, or `spare` without one
static id<MTLTexture> spare;
static id<MTLCommandBuffer> cmd;
static id<MTLRenderCommandEncoder> enc;
static MTLRenderPassDescriptor* rpd;
static int frame_w, frame_h;
static bool in_frame;

static id<MTLTexture> new_texture(MTLPixelFormat fmt, int w, int h) {
  MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
      width:(NSUInteger)w height:(NSUInteger)h mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead;
  return [dev newTextureWithDescriptor:d];
}

static void fill(id<MTLTexture> t, int y0, int w, int h, const void* px, int bpp) {
  [t replaceRegion:MTLRegionMake2D(0, (NSUInteger)y0, (NSUInteger)w, (NSUInteger)h)
       mipmapLevel:0 withBytes:px bytesPerRow:(NSUInteger)(w * bpp)];
}

static id<MTLRenderPipelineState> pipeline(id<MTLLibrary> lib, NSString* v, NSString* f,
                                           bool blend) {
  MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
  d.vertexFunction = [lib newFunctionWithName:v];
  d.fragmentFunction = [lib newFunctionWithName:f];
  d.colorAttachments[0].pixelFormat = layer.pixelFormat;
  if (blend) {
    MTLRenderPipelineColorAttachmentDescriptor* a = d.colorAttachments[0];
    a.blendingEnabled = YES;
    a.sourceRGBBlendFactor = a.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    a.destinationRGBBlendFactor = a.destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
  }
  NSError* err = nil;
  id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
  if (!p) fprintf(stderr, "Metal pipeline %s: %s\n", f.UTF8String,
                  err.localizedDescription.UTF8String);
  return p;
}

// ImGui's vertex layout and projection (buffer 1), its blend; the image
// sampled nearest, as OpenGL's NEAREST textures are, where ImGui's own
// pipeline always filters linearly (the debug windows' tile views).
static const char* UI_NEAREST_MSL =
  "#include <metal_stdlib>\n"
  "using namespace metal;\n"
  "struct V { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]];\n"
  "           uchar4 col [[attribute(2)]]; };\n"
  "struct F { float4 pos [[position]]; float2 uv; float4 col; };\n"
  "vertex F ui_vert(V v [[stage_in]], constant float4x4& proj [[buffer(1)]]) {\n"
  "  F f;\n"
  "  f.pos = proj * float4(v.pos, 0.0, 1.0);\n"
  "  f.uv = v.uv;\n"
  "  f.col = float4(v.col) / 255.0;\n"
  "  return f;\n"
  "}\n"
  "fragment float4 ui_frag(F f [[stage_in]], texture2d<float> t [[texture(0)]]) {\n"
  "  constexpr sampler s(filter::nearest);\n"
  "  return f.col * t.sample(s, f.uv);\n"
  "}\n";

static id<MTLRenderPipelineState> ui_nearest_pipeline(void) {
  NSError* err = nil;
  id<MTLLibrary> lib = [dev newLibraryWithSource:@(UI_NEAREST_MSL) options:nil error:&err];
  if (!lib) return nil;
  MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
  vd.attributes[0].offset = offsetof(ImDrawVert, pos);
  vd.attributes[0].format = MTLVertexFormatFloat2;
  vd.attributes[1].offset = offsetof(ImDrawVert, uv);
  vd.attributes[1].format = MTLVertexFormatFloat2;
  vd.attributes[2].offset = offsetof(ImDrawVert, col);
  vd.attributes[2].format = MTLVertexFormatUChar4;
  vd.layouts[0].stride = sizeof(ImDrawVert);
  MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
  d.vertexFunction = [lib newFunctionWithName:@"ui_vert"];
  d.fragmentFunction = [lib newFunctionWithName:@"ui_frag"];
  d.vertexDescriptor = vd;
  MTLRenderPipelineColorAttachmentDescriptor* a = d.colorAttachments[0];
  a.pixelFormat = layer.pixelFormat;
  a.blendingEnabled = YES;
  a.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  a.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  a.sourceAlphaBlendFactor = MTLBlendFactorOne;
  a.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  return [dev newRenderPipelineStateWithDescriptor:d error:&err];
}

extern "C" int dbmtl_init(void* sdl_layer, const char* msl, int readable, int vsync) {
  layer = (__bridge CAMetalLayer*)sdl_layer;
  dev = layer.device ? layer.device : MTLCreateSystemDefaultDevice();
  if (!dev) { fprintf(stderr, "No Metal device\n"); return 0; }
  layer.device = dev;
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  // Captures and the GUI driver's shots read the drawable back
  layer.framebufferOnly = readable ? NO : YES;
  // A present is shown at the next refresh. Without display sync it is shown
  // at once, mid-scan: the picture tears (OpenGL's swap interval 0 never
  // did, the compositor waited for it). main()'s frame scheduler still paces,
  // never presenting faster than the display refreshes.
  layer.displaySyncEnabled = vsync ? YES : NO;
  queue = [dev newCommandQueue];
  MTLCompileOptions* opts = [MTLCompileOptions new];
  // pow() and the colour models as the GLSL computes them, not approximated
  if (@available(macOS 15.0, *)) opts.mathMode = MTLMathModeSafe;
  else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    opts.fastMathEnabled = NO;
#pragma clang diagnostic pop
  }
  NSError* err = nil;
  id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:msl]
                                         options:opts error:&err];
  if (!lib) {
    fprintf(stderr, "Metal shader error: %s\n", err.localizedDescription.UTF8String);
    return 0;
  }
  game_pso = pipeline(lib, @"game_vert", @"game_frag", false);
  logo_pso = pipeline(lib, @"logo_vert", @"logo_frag", true);
  if (!game_pso || !logo_pso) return 0;
  ui_nearest_pso = ui_nearest_pipeline();
  border_tex = new_texture(MTLPixelFormatR16Uint, 256, 224);
  inflight = dispatch_semaphore_create(MAX_INFLIGHT);
  rpd = [MTLRenderPassDescriptor new];
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  return 1;
}

extern "C" int dbmtl_available(void) {
  @autoreleasepool { return MTLCreateSystemDefaultDevice() != nil; }
}

extern "C" const char* dbmtl_device_name(void) { return dev.name.UTF8String; }

extern "C" void dbmtl_logo_upload(const void* px, int w, int h) {
  logo_tex = new_texture(MTLPixelFormatRGBA8Unorm, w, h);
  fill(logo_tex, 0, w, h, px, 4);
}

extern "C" void dbmtl_game_alloc(int w, int h) {
  for (int i = 0; i < RING; i++) {
    game_ring[i] = new_texture(MTLPixelFormatR16Uint, w, h);
    // Black until the first upload, as GL's undefined storage reads on macOS
    NSUInteger n = (NSUInteger)w * (NSUInteger)h;
    uint16_t* z = (uint16_t*)calloc(n, 2);
    fill(game_ring[i], 0, w, h, z, 2);
    free(z);
  }
  game_w = w; game_h = h; game_cur = 0;
}

extern "C" void dbmtl_game_upload(int y0, int w, int h, const void* px) {
  if (!game_ring[0] || w != game_w) return;
  if (!game_uploaded) {
    // A present uploads the whole picture (one call, or the DS's two
    // halves): the next slot needs nothing from the last.
    game_cur = (game_cur + 1) % RING;
    game_uploaded = true;
  }
  fill(game_ring[game_cur], y0, w, h, px, 2);
}

extern "C" void dbmtl_border_upload(const void* px) {
  border_tex = new_texture(MTLPixelFormatR16Uint, 256, 224);
  fill(border_tex, 0, 256, 224, px, 2);
}

static void end_encoder(void) {
  if (enc) { [enc endEncoding]; enc = nil; }
}

static id<MTLRenderCommandEncoder> encoder(void) {
  if (!enc) {
    enc = [cmd renderCommandEncoderWithDescriptor:rpd];
    // Later passes this present draw over what is there
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
  }
  return enc;
}

extern "C" void dbmtl_begin(int pw, int ph, float r, float g, float b) {
  if (in_frame) return;
  in_frame = true;
  game_uploaded = false;
  dispatch_semaphore_wait(inflight, DISPATCH_TIME_FOREVER);
  frame_w = pw < 1 ? 1 : pw;
  frame_h = ph < 1 ? 1 : ph;
  CGSize want = CGSizeMake(frame_w, frame_h);
  if (!CGSizeEqualToSize(layer.drawableSize, want)) layer.drawableSize = want;
  @autoreleasepool { drawable = [layer nextDrawable]; }
  target = drawable.texture;
  if (!target) {
    // No drawable (none came within a second): draw into a stand-in of the
    // same size, so ImGui's frame and any read go on as usual
    if (!spare || (int)spare.width != frame_w || (int)spare.height != frame_h) {
      MTLTextureDescriptor* d = [MTLTextureDescriptor
          texture2DDescriptorWithPixelFormat:layer.pixelFormat
          width:(NSUInteger)frame_w height:(NSUInteger)frame_h mipmapped:NO];
      d.usage = MTLTextureUsageRenderTarget;
      d.storageMode = MTLStorageModePrivate;
      spare = [dev newTextureWithDescriptor:d];
    }
    target = spare;
  }
  cmd = [queue commandBuffer];
  rpd.colorAttachments[0].texture = target;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1.0);
}

// The 128-byte Params block of present_shader.nim's MSL
typedef struct {
  float sgb_backdrop[4];
  float dmg_pal[16];
  float tex_width, tex_height, scan_width, scan_height;
  int32_t color_correct, panel_gbc, lcd_grid, subpixel, sgb_border, filter_mode,
          dmg_remap, pad0;
} Params;

static void set_viewport(id<MTLRenderCommandEncoder> e, int x, int y, int w, int h) {
  // (x, y) is from the bottom left, as OpenGL's glViewport
  MTLViewport v = { (double)x, (double)(frame_h - y - h), (double)w, (double)h, 0.0, 1.0 };
  [e setViewport:v];
}

extern "C" void dbmtl_draw_game(int x, int y, int w, int h, const void* params) {
  if (!in_frame || !game_ring[0] || w <= 0 || h <= 0) return;
  id<MTLRenderCommandEncoder> e = encoder();
  set_viewport(e, x, y, w, h);
  [e setRenderPipelineState:game_pso];
  [e setFragmentBytes:params length:sizeof(Params) atIndex:0];
  [e setFragmentTexture:game_ring[game_cur] atIndex:0];
  [e setFragmentTexture:border_tex atIndex:1];
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

extern "C" void dbmtl_draw_logo(float aspect, float scale) {
  if (!in_frame || !logo_tex) return;
  id<MTLRenderCommandEncoder> e = encoder();
  set_viewport(e, 0, 0, frame_w, frame_h);
  float p[2] = { aspect, scale };
  [e setRenderPipelineState:logo_pso];
  [e setVertexBytes:p length:sizeof(p) atIndex:0];
  [e setFragmentTexture:logo_tex atIndex:0];
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

extern "C" int dbmtl_read(int x, int y, int w, int h, uint8_t* rgb) {
  // What is drawn so far this present, (x, y, w, h) from the bottom left, as
  // RGB rows top first. Waits for the GPU; the present goes on in a new
  // command buffer over the same texture.
  if (!in_frame || w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > frame_w ||
      y + h > frame_h) return 0;
  encoder();  // a present with no draws yet still clears
  end_encoder();
  NSUInteger stride = (NSUInteger)w * 4;
  id<MTLBuffer> buf = [dev newBufferWithLength:stride * (NSUInteger)h
                                       options:MTLResourceStorageModeShared];
  id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
  [blit copyFromTexture:target sourceSlice:0 sourceLevel:0
           sourceOrigin:MTLOriginMake((NSUInteger)x, (NSUInteger)(frame_h - y - h), 0)
             sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
               toBuffer:buf destinationOffset:0 destinationBytesPerRow:stride
destinationBytesPerImage:stride * (NSUInteger)h];
  [blit endEncoding];
  [cmd commit];
  [cmd waitUntilCompleted];
  bool ok = cmd.status == MTLCommandBufferStatusCompleted;
  const uint8_t* bgra = (const uint8_t*)buf.contents;
  for (NSUInteger i = 0, n = (NSUInteger)w * (NSUInteger)h; i < n; i++) {
    rgb[i * 3 + 0] = bgra[i * 4 + 2];
    rgb[i * 3 + 1] = bgra[i * 4 + 1];
    rgb[i * 3 + 2] = bgra[i * 4 + 0];
  }
  cmd = [queue commandBuffer];
  return ok ? 1 : 0;
}

// When each present reached the glass (CACurrentMediaTime seconds, 0 = not
// yet or never shown), by its number; for DINGBAT_FRAME_TRACE. A ring: 18
// minutes at 60 Hz.
enum { SHOWN_RING = 1 << 16 };
static double shown_at[SHOWN_RING];
static uint64_t present_seq;

extern "C" uint64_t dbmtl_present(void) {
  if (!in_frame) return 0;
  encoder();  // clear even when nothing was drawn
  end_encoder();
  uint64_t seq = ++present_seq;
  shown_at[seq % SHOWN_RING] = 0;
  if (drawable) {
    [drawable addPresentedHandler:^(id<MTLDrawable> d) {
      shown_at[seq % SHOWN_RING] = d.presentedTime;
    }];
    [cmd presentDrawable:drawable];
  }
  dispatch_semaphore_t s = inflight;
  [cmd addCompletedHandler:^(id<MTLCommandBuffer> _) { dispatch_semaphore_signal(s); }];
  [cmd commit];
  cmd = nil; drawable = nil; target = nil;
  rpd.colorAttachments[0].texture = nil;
  in_frame = false;
  return seq;
}

extern "C" double dbmtl_shown_at(uint64_t seq) {
  return seq + SHOWN_RING > present_seq ? shown_at[seq % SHOWN_RING] : 0;
}

extern "C" void dbmtl_imgui_init(void) { ImGui_ImplMetal_Init(dev); }

extern "C" void dbmtl_imgui_new_frame(void) {
  if (in_frame) ImGui_ImplMetal_NewFrame(rpd);
}

extern "C" void dbmtl_imgui_render(void* draw_data) {
  if (!in_frame) return;
  ImGui_ImplMetal_RenderDrawData((ImDrawData*)draw_data, cmd, encoder());
}


// An ImDrawList callback: the images after it sample nearest, until
// ImDrawCallback_ResetRenderState puts ImGui's pipeline back.
extern "C" void dbmtl_ui_nearest(const ImDrawList*, const ImDrawCmd*) {
  if (enc && ui_nearest_pso) [enc setRenderPipelineState:ui_nearest_pso];
}

extern "C" uint64_t dbmtl_ui_texture(uint64_t old, const void* px, int w, int h,
                                     int bgr555) {
  // A fresh texture each time (see the top); `old`'s reference is dropped.
  if (old) CFRelease((CFTypeRef)(uintptr_t)old);
  id<MTLTexture> t;
  if (bgr555) {
    // ImGui's shader samples RGBA8: the 555 words expanded here
    t = new_texture(MTLPixelFormatRGBA8Unorm, w, h);
    const uint16_t* s = (const uint16_t*)px;
    NSUInteger n = (NSUInteger)w * (NSUInteger)h;
    uint8_t* rgba = (uint8_t*)malloc(n * 4);
    for (NSUInteger i = 0; i < n; i++) {
      uint16_t v = s[i];
      rgba[i * 4 + 0] = (uint8_t)(((v & 31) * 255 + 15) / 31);
      rgba[i * 4 + 1] = (uint8_t)((((v >> 5) & 31) * 255 + 15) / 31);
      rgba[i * 4 + 2] = (uint8_t)((((v >> 10) & 31) * 255 + 15) / 31);
      rgba[i * 4 + 3] = 255;
    }
    fill(t, 0, w, h, rgba, 4);
    free(rgba);
  } else {
    t = new_texture(MTLPixelFormatRGBA8Unorm, w, h);
    fill(t, 0, w, h, px, 4);
  }
  return (uint64_t)(uintptr_t)(__bridge_retained void*)t;
}
