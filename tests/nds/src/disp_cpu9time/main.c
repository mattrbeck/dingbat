// disp_cpu9time: what the ARM9's own code fetches and data accesses cost,
// per memory region (GBATEK "DS Memory Timings": NDS9/CODE and NDS9/DATA
// tables, cache misses, TCM). A cascaded timer counts bus cycles (33.51
// MHz). Each loop below runs 256 and 512 passes and a cell is T(512) -
// T(256) = 256 x the bus cycles of one pass (hex), so call and timer
// overheads cancel; one ARM9 cycle is 0x80 in a cell.
//
// The protection unit is set up as a NitroSDK game has it: region 0 the
// whole 4 GB, uncached; region 1 main RAM 02000000h-023FFFFFh with the
// instruction and data caches and the write buffer (write-back); DTCM at
// 0B000000h (16 KB), ITCM at 0 (32 KB). The 02400000h mirror of main RAM
// is the uncached view.
//
// Page 1 (data; code from the instruction cache), columns: 8 x LDR,
// 8 x LDRH, 8 x STR, each with the SUBS/BGT pass around them:
//   IO   04000130h (KEYINPUT; STR to engine B BG3HOFS 0400101Ch, BG3 off)
//   TMR  04000100h timer 0 (STR to the stopped timer 2's reload)
//   CRD  040001A4h ROMCTRL (STR to the command bytes 040001A8h)
//   MU   main RAM uncached (02400000h + 2 MB)    MC  main RAM cached, hits
//   MM   cached main RAM, every LDR a miss (8 lines 1 KB apart, one set)
//   DTC  DTCM   ITC  ITCM (data)   WRM  shared WRAM (all 32K to the ARM9)
//   VRM  VRAM bank A (LCDC)   PAL  palette   OAM  OAM   BIO  BIOS (LDR only)
//   GBA  GBA slot (default EXMEMCNT; LDRH = LDR column only)
//   LMU  LDMIA 8 words main uncached | LMC cached | LMD DTCM (column 1)
//   UIO / UDT / UMC  I/O, DTCM, cached main RAM: 8 x (LDR + TST of the
//   loaded register), 8 x (LDR + TST of another), 8 x (LDRH + TST of it)
// Page 2 (code), columns: SUBS/BGT alone, 8 x MOV + SUBS/BGT, 8 x B to the
// next opcode + SUBS/BGT; rows: code run from the instruction cache (IC),
// uncached main RAM (MU), ITCM (IT), shared WRAM (WR), and 8 x MUL /
// 8 x NOP Thumb (TH) from the cache; then whether the CPU runs on during a
// DMA (rows DIT, DIC, DMU: see there); 8 x LDR from uncached main RAM or
// WRAM code (CU, CW). Page 2 shows from frame 60 ("P2").
// Every cell is also kept as a word at 02300100h + 4 x (page x 96 + row x 4
// + column), page 0 or 1, column 0-2 (tests/nds_compat_test.nim reads them).
// Built with build_3d.sh (disp_* ROMs).
#include "t3d.h"
#include "tm.h"

#define WRAMCNT R8(0x04000247)

typedef void (*loop_fn)(u32 passes, volatile void *data);

// The loops (r0 = passes, r1 = data). Position independent: the code rows
// run copies of them.
#define LOOP8(name, op)                                   \
  __asm__(".arm\n.global " #name "\n" #name ":\n"         \
          "1:\n" op "\n" op "\n" op "\n" op "\n"          \
          op "\n" op "\n" op "\n" op "\n"                 \
          "subs r0, r0, #1\nbgt 1b\nbx lr\n.global " #name "_end\n" #name "_end:\n");
LOOP8(l_ldr8, "ldr r2, [r1]")
LOOP8(l_ldrh8, "ldrh r2, [r1]")
LOOP8(l_str8, "str r2, [r1]")
LOOP8(l_mov8, "mov r2, r2")
LOOP8(l_mul8, "mul r2, r3, r3")
// a load whose result the next opcode uses, or not (the interlock)
LOOP8(l_ldr_use8, "ldr r2, [r1]\ntst r2, #1")
LOOP8(l_ldr_free8, "ldr r2, [r1]\ntst r3, #1")
LOOP8(l_ldrh_use8, "ldrh r2, [r1]\ntst r2, #1")
__asm__(".arm\n.global l_nop\nl_nop:\n1:\nsubs r0, r0, #1\nbgt 1b\nbx lr\n"
        ".global l_nop_end\nl_nop_end:\n");
__asm__(".arm\n.global l_b8\nl_b8:\n1:\n"
        "b 2f\n2: b 3f\n3: b 4f\n4: b 5f\n5: b 6f\n6: b 7f\n7: b 8f\n8: b 9f\n9:\n"
        "subs r0, r0, #1\nbgt 1b\nbx lr\n.global l_b8_end\nl_b8_end:\n");
// 8 loads 1 KB apart: one cache set (4 ways), so every load misses
__asm__(".arm\n.global l_miss8\nl_miss8:\n1:\n"
        "ldr r2, [r1]\nldr r2, [r1, #0x400]\nldr r2, [r1, #0x800]\nldr r2, [r1, #0xC00]\n"
        "add r3, r1, #0x1000\n"
        "ldr r2, [r3]\nldr r2, [r3, #0x400]\nldr r2, [r3, #0x800]\nldr r2, [r3, #0xC00]\n"
        "subs r0, r0, #1\nbgt 1b\nbx lr\n");
__asm__(".arm\n.global l_ldm8\nl_ldm8:\npush {r4-r11}\n1:\n"
        "ldmia r1, {r4-r11}\nsubs r0, r0, #1\nbgt 1b\npop {r4-r11}\nbx lr\n");
// Thumb: 8 x MOV r2, r2 + SUB/BGT
__asm__(".syntax unified\n.thumb\n.global l_thumb8\n.thumb_func\nl_thumb8:\n1:\n"
        "movs r2, r2\nmovs r2, r2\nmovs r2, r2\nmovs r2, r2\n"
        "movs r2, r2\nmovs r2, r2\nmovs r2, r2\nmovs r2, r2\n"
        "subs r0, #1\nbgt 1b\nbx lr\n.arm\n");

void l_ldr8(u32, volatile void *);
void l_ldr8_end(void);
void l_ldrh8(u32, volatile void *);
void l_str8(u32, volatile void *);
void l_mov8(u32, volatile void *);
void l_mov8_end(void);
void l_mul8(u32, volatile void *);
void l_nop(u32, volatile void *);
void l_nop_end(void);
void l_b8(u32, volatile void *);
void l_b8_end(void);
void l_miss8(u32, volatile void *);
void l_ldr_use8(u32, volatile void *);
void l_ldr_free8(u32, volatile void *);
void l_ldrh_use8(u32, volatile void *);
void l_ldm8(u32, volatile void *);
void l_thumb8(u32, volatile void *);

static u32 timed(loop_fn f, u32 passes, volatile void *data) {
  u32 t0 = clock_now();
  f(passes, data);
  return clock_now() - t0;
}

static u32 slope(loop_fn f, volatile void *data) {
  timed(f, 4, data);   // fill the caches
  return timed(f, 512, data) - timed(f, 256, data);
}

static void mpu_setup(void) {
  u32 r;
  __asm__ volatile(
      "mov %0, #0\n\t"
      "mcr p15, 0, %0, c7, c5, 0\n\t"   // invalidate I-cache
      "mcr p15, 0, %0, c7, c6, 0\n\t"   // invalidate D-cache
      "mcr p15, 0, %0, c6, c2, 0\n\t"
      "mcr p15, 0, %0, c6, c3, 0\n\t"
      "mcr p15, 0, %0, c6, c4, 0\n\t"
      "mcr p15, 0, %0, c6, c5, 0\n\t"
      "mcr p15, 0, %0, c6, c6, 0\n\t"
      "mcr p15, 0, %0, c6, c7, 0\n\t"
      "mov %0, #0x3F\n\t"
      "mcr p15, 0, %0, c6, c0, 0\n\t"   // region 0: 4 GB
      "mov %0, #0x02000000\n\t"
      "orr %0, %0, #0x2B\n\t"
      "mcr p15, 0, %0, c6, c1, 0\n\t"   // region 1: main RAM 4 MB
      "mov %0, #2\n\t"
      "mcr p15, 0, %0, c2, c0, 0\n\t"   // data-cachable: region 1
      "mcr p15, 0, %0, c2, c0, 1\n\t"   // instruction-cachable: region 1
      "mcr p15, 0, %0, c3, c0, 0\n\t"   // write buffer: region 1
      "mov %0, #0x33\n\t"
      "mcr p15, 0, %0, c5, c0, 2\n\t"   // data access R/W
      "mcr p15, 0, %0, c5, c0, 3\n\t"   // code access R/W
      "mov %0, #0x0B000000\n\t"
      "orr %0, %0, #0x0A\n\t"
      "mcr p15, 0, %0, c9, c1, 0\n\t"   // DTCM 0B000000h, 16 KB
      "mov %0, #0x0C\n\t"
      "mcr p15, 0, %0, c9, c1, 1\n\t"   // ITCM 0, 32 KB
      "mrc p15, 0, %0, c1, c0, 0\n\t"
      "orr %0, %0, #0x50000\n\t"        // DTCM, ITCM
      "orr %0, %0, #0x1000\n\t"         // I-cache
      "orr %0, %0, #0x5\n\t"            // protection unit, D-cache
      "mcr p15, 0, %0, c1, c0, 0\n\t"
      : "=r"(r));
}

static void copy_code(void *dst, void (*start)(void), void (*end)(void)) {
  u32 *d = dst;
  for (u32 *s = (u32 *)start; s < (u32 *)end; s++) *d++ = *s;
}

static void clean_dcache(void) {
  // clean + invalidate every line by set/way (4 ways x 32 sets)
  for (u32 way = 0; way < 4; way++)
    for (u32 set = 0; set < 32; set++) {
      u32 v = (way << 30) | (set << 5);
      __asm__ volatile("mcr p15, 0, %0, c7, c14, 2" : : "r"(v));
    }
  u32 z = 0;
  __asm__ volatile("mcr p15, 0, %0, c7, c10, 4\n\tmcr p15, 0, %0, c7, c5, 0" : : "r"(z));
}

struct drow { const char *name; u32 ld; u32 st; int h; };

#define CELLS ((volatile u32 *)0x02300100)
static int page;

static void out(int x, int y, u32 v) {
  t3d_hex(x, y, v, 6);
  CELLS[page * 96 + y * 4 + (x - 5) / 7] = v;
}

int main(void) {
  t3d_init("disp_cpu9time: ARM9 access cycles");
  VRAMCNT(0) = 0x80;                       // A: LCDC (0x06800000)
  WRAMCNT = 0;                             // shared WRAM: all 32K to the ARM9
  mpu_setup();
  clock_start();
  R16(0x0400010A) = 0;                     // timer 2 stopped
  static const struct drow rows[] = {
      {"IO", 0x04000130, 0x0400101C, 1},  {"TMR", 0x04000100, 0x04000108, 1},
      {"CRD", 0x040001A4, 0x040001A8, 1}, {"MU", 0x02600000, 0x02600000, 1},
      {"MC", 0x02200000, 0x02200000, 1},  {"DTC", 0x0B000100, 0x0B000100, 1},
      {"ITC", 0x00006000, 0x00006000, 1}, {"WRM", 0x03000000, 0x03000000, 1},
      {"VRM", 0x06800000, 0x06800000, 1}, {"PAL", 0x05000000, 0x05000000, 1},
      {"OAM", 0x07000000, 0x07000000, 1}, {"BIO", 0xFFFF0000, 0, 1},
      {"GBA", 0x08000000, 0, 0},
  };
  t3d_print(0, 1, "     LDR    LDRH   STR");
  int y = 2;
  for (u32 i = 0; i < sizeof rows / sizeof rows[0]; i++, y++) {
    const struct drow *r = &rows[i];
    t3d_print(0, y, r->name);
    out(5, y, slope(l_ldr8, (volatile void *)r->ld));
    if (r->h) out(12, y, slope(l_ldrh8, (volatile void *)r->ld));
    if (r->st) out(19, y, slope(l_str8, (volatile void *)r->st));
  }
  t3d_print(0, y, "MM");
  out(5, y++, slope(l_miss8, (volatile void *)0x02210000));
  t3d_print(0, y, "LMU");
  out(5, y, slope(l_ldm8, (volatile void *)0x02600000));
  out(12, y, slope(l_ldm8, (volatile void *)0x02200000));
  out(19, y++, slope(l_ldm8, (volatile void *)0x0B000100));
  // LDR + TST of the loaded register / of another, LDRH + TST of it:
  // I/O (KEYINPUT), DTCM, cached main RAM
  static const u32 ua[3] = {0x04000130, 0x0B000100, 0x02200000};
  static const char *un[3] = {"UIO", "UDT", "UMC"};
  for (int i = 0; i < 3; i++, y++) {
    t3d_print(0, y, un[i]);
    out(5, y, slope(l_ldr_use8, (volatile void *)ua[i]));
    out(12, y, slope(l_ldr_free8, (volatile void *)ua[i]));
    out(19, y, slope(l_ldrh_use8, (volatile void *)ua[i]));
  }
  t3d_print(0, 22, "DONE");
  for (int f = 0; f < 60; f++) wait_vblank();

  // page 2: code
  page = 1;
  for (int r = 0; r < 24; r++) t3d_print(0, r, "                                ");
  t3d_print(0, 0, "P2   NOP    MOV8   B8");
  // copies: ITCM 0x1000.., shared WRAM 0x03001000.. (each loop its own slot)
  u8 *itcm = (u8 *)0x00001000, *wram = (u8 *)0x03001000;
  loop_fn fn[3] = {l_nop, l_mov8, l_b8};
  void (*ends[3])(void) = {l_nop_end, l_mov8_end, l_b8_end};
  for (int k = 0; k < 3; k++) {
    copy_code(itcm + k * 0x100, (void (*)(void))fn[k], ends[k]);
    copy_code(wram + k * 0x100, (void (*)(void))fn[k], ends[k]);
  }
  clean_dcache();   // the copies to memory, the I-cache empty
  static const char *names[4] = {"IC", "MU", "IT", "WR"};
  for (int row = 0; row < 4; row++) {
    t3d_print(0, 2 + row, names[row]);
    for (int k = 0; k < 3; k++) {
      loop_fn f = fn[k];
      if (row == 1) f = (loop_fn)((u32)fn[k] + 0x400000);   // uncached mirror
      if (row == 2) f = (loop_fn)(itcm + k * 0x100);
      if (row == 3) f = (loop_fn)(wram + k * 0x100);
      out(5 + k * 7, 2 + row, slope(f, 0));
    }
  }
  t3d_print(0, 6, "MUL");
  out(5, 6, slope(l_mul8, 0));
  t3d_print(0, 7, "TH");
  out(5, 7, slope((loop_fn)((u32)l_thumb8 | 1), 0));
  // Does the CPU run on while a DMA holds the bus? (GBATEK "DS DMA
  // Transfers": "The CPU can be kept running during DMA, provided that it
  // is accessing only TCM (or cached memory)".) DMA0 moves 4000h words
  // main RAM -> VRAM (immediate); the CPU then runs 8000h passes of the
  // SUBS/BGT loop and reads the clock. Columns: the DMA alone, the loop
  // alone, both; rows: the loop from ITCM (DIT), the cache (DIC),
  // uncached main RAM (DMU).
  static const char *dn[3] = {"DIT", "DIC", "DMU"};
  for (int row = 0; row < 3; row++) {
    loop_fn f = row == 0 ? (loop_fn)itcm : row == 1 ? l_nop : (loop_fn)((u32)l_nop + 0x400000);
    t3d_print(0, 9 + row, dn[row]);
    for (int k = 0; k < 3; k++) {
      f(4, 0);    // warm
      DMA_SAD(0) = 0x02100000;
      DMA_DAD(0) = 0x06800000;
      u32 t0 = clock_now();
      if (k != 1) DMA_CNT(0) = (1u << 31) | (1u << 26) | 0x4000;
      if (k != 0) f(0x8000, 0);
      u32 t1 = clock_now();
      out(5 + k * 7, 9 + row, t1 - t0);
    }
  }
  // 8 x LDR with the code elsewhere: uncached main RAM (CU) or shared
  // WRAM (CW), data in I/O (KEYINPUT), DTCM, cached main RAM (GBATEK: "When
  // executing code in uncached main ram, and accessing data ... execution
  // time is typically codetime+datatime-2")
  t3d_print(0, 13, "     IO     DTCM   MC");
  copy_code(wram + 0x300, (void (*)(void))l_ldr8, l_ldr8_end);
  clean_dcache();
  static const u32 cd[3] = {0x04000130, 0x0B000100, 0x02200000};
  for (int row = 0; row < 2; row++) {
    loop_fn f = row == 0 ? (loop_fn)((u32)l_ldr8 + 0x400000) : (loop_fn)(wram + 0x300);
    t3d_print(0, 14 + row, row == 0 ? "CU" : "CW");
    for (int k = 0; k < 3; k++) out(5 + k * 7, 14 + row, slope(f, (volatile void *)cd[k]));
  }
  t3d_print(0, 22, "DONE");
  while (1) wait_vblank();
}
