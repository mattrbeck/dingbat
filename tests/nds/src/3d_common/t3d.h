// t3d: the shared harness of dingbat's 3D test ROMs (tests/nds/src/3d_*).
// No library: plain ARM9 code entered at 0x02000000 with IRQs off (the
// common2d crt0), so any direct-booting emulator runs them.
//
// Every ROM draws one static scene on the top screen (engine A, BG0 = 3D)
// and repeats it every frame, so any frame after the first few can be
// compared between emulators. The bottom screen is a text BG (engine B,
// VRAM H) with a legend, or register readouts for the status ROM.
//
// Geometry goes straight to the command ports (GBATEK "DS 3D Geometry
// Commands"), so each ROM states exactly which words reach the engine.
//
// Pixel space: t3d_proj_px() loads a projection under which a vertex at
// raw coordinates (PX(x), PX(y)) lands exactly on screen dot (x, y), top-left
// origin, for x in -128..383 and y in -128..319 (1/64-dot steps). It uses
// w = 3.0 so that the viewport transform divides exactly:
//   screen_x = (xx + ww) * 256 / (2 ww) = (xx + 12288) / 96
//   screen_y = (yy + ww) * 192 / (2 ww) = (yy + 12288) / 128  (bottom-up)
// and z toward the viewer (+8.0 = near plane, -8.0 = far plane).
#ifndef T3D_H
#define T3D_H

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef signed char s8;
typedef signed short s16;
typedef signed int s32;
typedef volatile u8 vu8;
typedef volatile u16 vu16;
typedef volatile u32 vu32;

#define R32(a) (*(vu32 *)(a))
#define R16(a) (*(vu16 *)(a))
#define R8(a) (*(vu8 *)(a))

#define FX(v) ((s32)((v) * 4096.0))
#define PX(p) ((s32)(p) * 64)
#define RGB(r, g, b) ((u16)((r) | ((g) << 5) | ((b) << 10)))

// POLYGON_ATTR
#define PA_LIGHTS(m) ((u32)(m))
#define PA_MODULATE (0u << 4)
#define PA_DECAL (1u << 4)
#define PA_TOON (2u << 4)
#define PA_SHADOW (3u << 4)
#define PA_BACK (1u << 6)
#define PA_FRONT (1u << 7)
#define PA_BOTH (3u << 6)
#define PA_XLU_DEPTH (1u << 11)
#define PA_FAR_RENDER (1u << 12)
#define PA_DOT_RENDER (1u << 13)
#define PA_DEPTH_EQ (1u << 14)
#define PA_FOG (1u << 15)
#define PA_ALPHA(a) ((u32)(a) << 16)
#define PA_ID(i) ((u32)(i) << 24)

// TEXIMAGE_PARAM
#define TP_ADDR(byte_ofs) ((u32)(byte_ofs) >> 3)
#define TP_REPS (1u << 16)
#define TP_REPT (1u << 17)
#define TP_FLIPS (1u << 18)
#define TP_FLIPT (1u << 19)
#define TP_SIZE(s, t) (((u32)(s) << 20) | ((u32)(t) << 23))   // log2(size/8)
#define TP_FMT(f) ((u32)(f) << 26)
#define TP_COL0 (1u << 29)
#define TP_XFORM(m) ((u32)(m) << 30)

enum { FMT_NONE, FMT_A3I5, FMT_4, FMT_16, FMT_256, FMT_4X4, FMT_A5I3, FMT_DIRECT };

// DISP3DCNT
#define D3_TEX (1u << 0)
#define D3_HIGHLIGHT (1u << 1)
#define D3_ALPHATEST (1u << 2)
#define D3_BLEND (1u << 3)
#define D3_AA (1u << 4)
#define D3_EDGE (1u << 5)
#define D3_FOG_ALPHA (1u << 6)
#define D3_FOG (1u << 7)
#define D3_FOG_SHIFT(s) ((u32)(s) << 8)
#define D3_REAR_BITMAP (1u << 14)

// Commands through their ports
static inline void mtx_mode(int m) { R32(0x04000440) = m; }
static inline void mtx_push(void) { R32(0x04000444) = 0; }
static inline void mtx_pop(int n) { R32(0x04000448) = n & 63; }
static inline void mtx_store(int n) { R32(0x0400044C) = n; }
static inline void mtx_restore(int n) { R32(0x04000450) = n; }
static inline void mtx_identity(void) { R32(0x04000454) = 0; }
static inline void mtx_load44(const s32 *m) { for (int i = 0; i < 16; i++) R32(0x04000458) = m[i]; }
static inline void mtx_load43(const s32 *m) { for (int i = 0; i < 12; i++) R32(0x0400045C) = m[i]; }
static inline void mtx_mult44(const s32 *m) { for (int i = 0; i < 16; i++) R32(0x04000460) = m[i]; }
static inline void mtx_mult43(const s32 *m) { for (int i = 0; i < 12; i++) R32(0x04000464) = m[i]; }
static inline void mtx_mult33(const s32 *m) { for (int i = 0; i < 9; i++) R32(0x04000468) = m[i]; }
static inline void mtx_scale(s32 x, s32 y, s32 z) { R32(0x0400046C) = x; R32(0x0400046C) = y; R32(0x0400046C) = z; }
static inline void mtx_trans(s32 x, s32 y, s32 z) { R32(0x04000470) = x; R32(0x04000470) = y; R32(0x04000470) = z; }
static inline void color(u16 c) { R32(0x04000480) = c; }
static inline u32 pack10(int x, int y, int z) { return (x & 0x3FF) | ((y & 0x3FF) << 10) | ((u32)(z & 0x3FF) << 20); }
static inline void normal(int x, int y, int z) { R32(0x04000484) = pack10(x, y, z); }   // 1.9
static inline void texcoord(int s, int t) { R32(0x04000488) = (u16)s | ((u32)(u16)t << 16); }   // 12.4
static inline void vtx16(s32 x, s32 y, s32 z) { R32(0x0400048C) = (u16)x | ((u32)(u16)y << 16); R32(0x0400048C) = (u16)z; }
static inline void vtx10(int x, int y, int z) { R32(0x04000490) = pack10(x, y, z); }   // 4.6
static inline void vtx_xy(s32 x, s32 y) { R32(0x04000494) = (u16)x | ((u32)(u16)y << 16); }
static inline void vtx_xz(s32 x, s32 z) { R32(0x04000498) = (u16)x | ((u32)(u16)z << 16); }
static inline void vtx_yz(s32 y, s32 z) { R32(0x0400049C) = (u16)y | ((u32)(u16)z << 16); }
static inline void vtx_diff(int x, int y, int z) { R32(0x040004A0) = pack10(x, y, z); }   // 0.9 (/8)
static inline void poly_attr(u32 a) { R32(0x040004A4) = a; }
static inline void tex_param(u32 p) { R32(0x040004A8) = p; }
static inline void pltt_base(u32 p) { R32(0x040004AC) = p; }
static inline void dif_amb(u32 v) { R32(0x040004C0) = v; }
static inline void spe_emi(u32 v) { R32(0x040004C4) = v; }
static inline void light_vector(int n, int x, int y, int z) { R32(0x040004C8) = pack10(x, y, z) | ((u32)n << 30); }
static inline void light_color(int n, u16 c) { R32(0x040004CC) = c | ((u32)n << 30); }
static inline void shininess(const u32 *t) { for (int i = 0; i < 32; i++) R32(0x040004D0) = t[i]; }
static inline void begin(int prim) { R32(0x04000500) = prim; }
static inline void end_vtxs(void) { R32(0x04000504) = 0; }
static inline void swap_buffers(u32 p) { R32(0x04000540) = p; }
static inline void viewport(int x1, int y1, int x2, int y2) { R32(0x04000580) = x1 | (y1 << 8) | (x2 << 16) | ((u32)y2 << 24); }
static inline void box_test(s32 x, s32 y, s32 z, s32 w, s32 h, s32 d) {
  R32(0x040005C0) = (u16)x | ((u32)(u16)y << 16);
  R32(0x040005C0) = (u16)z | ((u32)(u16)w << 16);
  R32(0x040005C0) = (u16)h | ((u32)(u16)d << 16);
}
static inline void pos_test(s32 x, s32 y, s32 z) { R32(0x040005C4) = (u16)x | ((u32)(u16)y << 16); R32(0x040005C4) = (u16)z; }
static inline void vec_test(int x, int y, int z) { R32(0x040005C8) = pack10(x, y, z); }

enum { TRIS, QUADS, TRI_STRIP, QUAD_STRIP };

// Render registers
#define DISP3DCNT R16(0x04000060)
#define GXSTAT R32(0x04000600)
#define RAM_COUNT R32(0x04000604)

static inline void clear_color(u16 c, int alpha, int id, int fog) {
  R32(0x04000350) = c | ((u32)alpha << 16) | ((u32)id << 24) | (fog ? 0x8000u : 0);
}
static inline void clear_depth(u16 d) { R16(0x04000354) = d; }
static inline void edge_color(int i, u16 c) { R16(0x04000330 + 2 * i) = c; }
static inline void toon_color(int i, u16 c) { R16(0x04000380 + 2 * i) = c; }
static inline void alpha_ref(int a) { R16(0x04000340) = a; }
static inline void fog_color(u16 c, int alpha) { R32(0x04000358) = c | ((u32)alpha << 16); }
static inline void fog_offset(u16 o) { R16(0x0400035C) = o; }
static inline void fog_density(int i, int d) { R8(0x04000360 + i) = d; }

// 2D side
#define POWCNT1 R16(0x04000304)
#define VCOUNT R16(0x04000006)
#define VRAMCNT(n) R8(0x04000240 + (n))   // A..G = 0..6, H = 8, I = 9
#define BLDCNT_A R16(0x04000050)
#define BLDALPHA_A R16(0x04000052)
#define BLD_ALPHA_BG0_OVER_BACKDROP 0x2041   // BG0 1st target, backdrop 2nd, alpha mode
#define PAL_A_BG ((vu16 *)0x05000000)
#define IF9 R32(0x04000214)
#define IME R32(0x04000208)

// Maths without a library (float, soft-float through libgcc)
float sinf(float x);
float cosf(float x);
float tanf(float x);
float sqrtf(float x);

// Harness
void t3d_print(int col, int row, const char *s);   // bottom screen, 32x24 cells
void t3d_hex(int col, int row, u32 v, int digits);
void wait_vblank(void);                   // until the start of the next V-blank
void t3d_init(const char *title);        // power, displays, console, 3D reset
void t3d_proj_px(void);                   // pixel-space projection (above)
void t3d_proj_persp(float fovy_deg, float aspect, float n, float f);
void t3d_reset_matrices(void);            // position, vector, texture = identity; mode 1
void t3d_wait_idle(void);                 // until GXSTAT.27 clears
void t3d_frame(u32 swap_param);           // SWAP_BUFFERS + wait for V-blank

// VRAM upload: a bank in LCDC mode for the CPU, then back to its 3D slot.
// Texture slots 0-3 = banks A-D, palette = bank E (slots 0-3).
u8 *t3d_tex_begin(void);                  // A-D to LCDC; returns slot 0's address (0x6800000)
void t3d_tex_end(int nslots);             // A.. to texture slots 0..nslots-1
u16 *t3d_pal_begin(void);                 // E to LCDC
void t3d_pal_end(void);                   // E to texture palette
void t3d_copy16(void *dst, const void *src, int bytes);   // VRAM takes no byte writes
u16 t3d_hue(int i, int n);                // n distinct bright colours

// Drawing helpers in pixel space (t3d_proj_px)
void quad_px(int x0, int y0, int x1, int y1, s32 z);   // axis-aligned, anticlockwise
void quad_tex_px(int x0, int y0, int x1, int y1, s32 z, int s0, int t0, int s1, int t1);  // texcoords in texels
void tri_px(int x0, int y0, int x1, int y1, int x2, int y2, s32 z);

#endif
