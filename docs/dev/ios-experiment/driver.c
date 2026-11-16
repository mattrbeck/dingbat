// Minimal driver proving a Swift/ObjC-style consumer of libdingbat_core.a:
// init, load ROM, run 120 frames, checksum the BGR555 framebuffer.
#include <stdio.h>
#include <stdint.h>
#include <time.h>

extern void dingbat_init(void);
extern int  dingbat_load_rom(const char *rom, const char *bios);
extern void dingbat_run_frame(void);
extern uint16_t *dingbat_framebuffer(void);
extern int  dingbat_fb_width(void);
extern int  dingbat_fb_height(void);

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: driver <rom>\n"); return 2; }
  dingbat_init();
  int rc = dingbat_load_rom(argv[1], NULL);
  if (rc != 0) { fprintf(stderr, "load_rom failed: %d\n", rc); return 1; }
  for (int i = 0; i < 120; i++) dingbat_run_frame();
  uint16_t *fb = dingbat_framebuffer();
  int w = dingbat_fb_width(), h = dingbat_fb_height();
  uint32_t sum = 0;
  int nonblack = 0;
  for (int i = 0; i < w * h; i++) { sum = sum * 31 + fb[i]; if (fb[i] & 0x7FFF) nonblack++; }
  printf("OK %dx%d fbhash=%08x nonblack=%d/%d\n", w, h, sum, nonblack, w * h);
  // Bench: 1000 frames, report multiple of realtime (59.73 fps).
  struct timespec t0, t1;
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (int i = 0; i < 1000; i++) dingbat_run_frame();
  clock_gettime(CLOCK_MONOTONIC, &t1);
  double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
  printf("BENCH 1000 frames in %.3fs = %.0f fps (%.1fx realtime)\n",
         secs, 1000.0 / secs, (1000.0 / secs) / 59.73);
  return 0;
}
