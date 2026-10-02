// 3d_render_timing: when the rendering engine reads its registers and when a
// SWAP_BUFFERS issued inside V-blank takes effect (GBATEK "DS 3D Overview":
// "Rendering starts 48 lines in advance (while still in the Vblank period)",
// "RDLINES_COUNT": rendering starts in scanline 214 into a 48-line cache,
// output begins after line 262; "SWAP_BUFFERS": not executed until the next
// V-blank, scanline 192).
//
// Phases of 20 frames each, the phase name on the bottom screen. Each repeats
// the same writes every frame, so a late frame of a phase shows its steady
// state on the top screen (BG0 = 3D only). Frame f is in phase f / 20.
//   0 CLR   no polygons; CLEAR_COLOR = blue at line 60, red at line 200,
//           green at line 230; SWAP_BUFFERS at line 100. A renderer that
//           reads the register per line, 48 lines ahead of the display,
//           shows red on lines 0-47 (rendered from 214 on), green down to
//           about line 108 (rendered while lines 0-60 are shown), blue below.
//   1 TOON  the same three writes to toon table entry 31 under a full-screen
//           toon-shaded quad (vertex red 31), CLEAR_COLOR black.
//   2 FOG   a full-screen fogged quad, fog density 127 in every entry, fog
//           colour yellow: DISP3DCNT fog off at line 60, on at 200, off at
//           230 (per line: fog on lines 0-47 only; read at V-blank start or
//           at line 0: no fog).
//   3 SWPD  each frame a full-screen quad in red or green (alternating) and
//           SWAP_BUFFERS at line 100, and the bottom screen's backdrop set to
//           the same colour at line 200: the two screens match when the swap
//           took effect at line 192 (control for SWPV).
//   4-16 L nnn  CLEAR_COLOR = blue at line 100, red at line nnn (in hex on
//           the bottom screen: 150, 191, 192, 193, 200, 213, 214, 215, 230,
//           262, 0, 1, 2), empty SWAP_BUFFERS at line 100. Which colour a
//           frame shows brackets the moment the renderer reads the register.
//   17 SWPV as SWPD but quad, swap and backdrop all written at line 200,
//           inside V-blank: the screens match if the swap took effect in this
//           V-blank, differ if it waited for the next line 192. Last, as it
//           leaves a swap pending behind every frame's commands.
#include "t3d.h"

#define RED RGB(31, 0, 0)
#define GREEN RGB(0, 31, 0)
#define BLUE RGB(0, 0, 31)
#define PAL_B_BG ((vu16 *)0x05000400)

static void wait_line(int l) {
  while (VCOUNT == l) {}
  while (VCOUNT != l) {}
}

static void full_quad(u16 c, u32 attr) {
  poly_attr(PA_FRONT | PA_BOTH | PA_ALPHA(31) | attr);
  color(c);
  begin(QUADS);
  vtx16(PX(-8), PX(-8), 0);
  vtx16(PX(-8), PX(200), 0);
  vtx16(PX(264), PX(200), 0);
  vtx16(PX(264), PX(-8), 0);
  end_vtxs();
}

static const int latch_lines[] = {150, 191, 192, 193, 200, 213, 214, 215, 230, 262, 0, 1, 2};
#define NLATCH ((int)(sizeof latch_lines / sizeof latch_lines[0]))

int main(void) {
  t3d_init("3d_render_timing");
  t3d_proj_px();
  for (int i = 0; i < 32; i++) fog_density(i, 127);
  fog_color(RGB(31, 31, 0), 31);
  fog_offset(0);
  u32 frame = 0;
  while (1) {
    int phase = frame / 20;
    u16 c = (frame & 1) ? RED : GREEN;
    if (frame % 20 == 0) {
      static const char *const names[] = {"CLR ", "TOON", "FOG ", "SWPD"};
      if (phase < 4) t3d_print(0, 2, names[phase]);
      else if (phase < 4 + NLATCH) {
        t3d_print(0, 2, "L   ");
        t3d_hex(2, 2, latch_lines[phase - 4], 3);
      } else if (phase == 4 + NLATCH) t3d_print(0, 2, "SWPV");
      else t3d_print(0, 2, "DONE");
    }
    if (phase == 0) {
      wait_line(60);
      clear_color(BLUE, 31, 0, 0);
      wait_line(100);
      swap_buffers(0);
      wait_line(200);
      clear_color(RED, 31, 0, 0);
      wait_line(230);
      clear_color(GREEN, 31, 0, 0);
    } else if (phase == 1) {
      clear_color(0, 31, 0, 0);
      DISP3DCNT = 0;                       // toon (not highlight) shading
      wait_line(60);
      toon_color(31, BLUE);
      wait_line(100);
      full_quad(RGB(31, 0, 0), PA_TOON);
      swap_buffers(0);
      wait_line(200);
      toon_color(31, RED);
      wait_line(230);
      toon_color(31, GREEN);
    } else if (phase == 2) {
      wait_line(60);
      DISP3DCNT = 0;
      wait_line(100);
      full_quad(RGB(0, 0, 31), PA_FOG);
      swap_buffers(0);
      wait_line(200);
      DISP3DCNT = D3_FOG;
      wait_line(230);
      DISP3DCNT = 0;
    } else if (phase == 3) {
      wait_line(100);
      full_quad(c, 0);
      swap_buffers(0);
      wait_line(200);
      PAL_B_BG[0] = c;
    } else if (phase < 4 + NLATCH) {
      int l = latch_lines[phase - 4];
      if (l < 100) {
        wait_line(l);
        clear_color(RED, 31, 0, 0);
        wait_line(100);
        clear_color(BLUE, 31, 0, 0);
        swap_buffers(0);
      } else {
        wait_line(100);
        clear_color(BLUE, 31, 0, 0);
        swap_buffers(0);
        wait_line(l);
        clear_color(RED, 31, 0, 0);
      }
    } else if (phase == 4 + NLATCH) {
      wait_line(200);
      full_quad(c, 0);
      swap_buffers(0);
      PAL_B_BG[0] = c;
    } else {
      wait_vblank();
    }
    frame++;
  }
}
