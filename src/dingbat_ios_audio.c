/*
 * iOS audio backend, compiled in by src/dingbat_ios.nim. The cores reach
 * audio only through common/audio_out.nim, which on iOS imports the
 * dingbat_audio_open/put/queued/clear/wait functions below (link-time
 * dependencies) instead of SDL: a mutex-guarded ring buffer, keeping the APU
 * sources identical to the desktop build.
 *
 * Producer: the emulator thread, via dingbat_audio_put (GBA int16 stereo, GB
 * float32 stereo, both 32768 Hz; the DS float32 stereo at 32728 Hz; the
 * format is whatever the last dingbat_audio_open() asked for). Consumer: the
 * CoreAudio render thread calls dingbat_audio_read(), which converts to
 * float32 and never touches the Nim runtime. The shell paces emulation by
 * the display clock (as the web does by requestAnimationFrame); the two
 * clocks drift, so the reader resamples by a hair (dynamic rate control, at
 * most 1.5%) to hold the ring at a target depth: no gaps when the consumer
 * briefly outpaces the producer, no creeping latency when it lags. If the
 * audio engine stops mid-frame (interruption, route change),
 * dingbat_audio_wait() drops the queue after ~250 ms so emulation never
 * deadlocks.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

/* audio_out.nim's SampleFormat */
#define FMT_S16 0
#define FMT_F32 1

/* 256 KiB ring: ~2 s of s16 stereo or ~1 s of f32 stereo at 32768 Hz. Pacing
 * keeps occupancy near two APU buffers; overflow drops the oldest bytes. */
#define RING_CAP (256 * 1024)

static uint8_t  g_ring[RING_CAP];
static size_t   g_head = 0;      /* read position  */
static size_t   g_size = 0;      /* bytes queued   */
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static int      g_format = FMT_S16;
static int      g_freq   = 32768;
static int      g_paused = 1;
static int      g_stall_ms = 0;  /* consecutive waited ms without a drain */
static int      g_stretch = 0;   /* slow motion: every frame queued twice */

/* Where queued samples go: 0 the speakers (the ring), 1 the capture buffer
 * only (a clip's replay, which is not heard), 2 nowhere (its silent
 * pre-roll), 3 both (Record, which captures what is heard). The capture
 * buffer is float32 stereo whatever the APU queued, and is read from the
 * main thread, the same thread that queues. */
static int      g_mode = 0;
static float   *g_cap = NULL;
static size_t   g_cap_frames = 0;    /* frames held */
static size_t   g_cap_alloc = 0;     /* frames allocated */

static size_t bytes_per_frame(void) {
  return g_format == FMT_F32 ? 8 : 4; /* stereo */
}

/* Dynamic rate control, reader side (render thread only, under g_lock).
 * Target depth: one video frame's worth of samples (they arrive in a burst
 * while the frame emulates) plus the render quantum and some slack for a
 * late display tick. The integral term carries the steady offset between
 * the clocks (60 Hz vs the GBA's 59.73 is +0.46%), so the depth settles on
 * the target instead of above it. */
#define DRC_TARGET   g_target   /* frames at 32768 Hz */
#define DRC_GAIN     0.02       /* ratio change per unit of relative depth error */
#define DRC_IGAIN    0.0004     /* the integral's step per callback, per unit error */
#define DRC_IMAX     0.01
#define DRC_MAX      0.015      /* never more than 1.5% off pitch */
#define DRC_CAP      (3 * DRC_TARGET) /* beyond: drop back to the target (a stall's backlog) */
static int      g_target = 832; /* ~25 ms; slow motion asks for more */
static int      g_free = 0;      /* fast-forward: no rate control, play what is there */
static int      g_primed = 0;    /* playing; else waiting for the ring to refill */
static double   g_fill = 832;    /* smoothed depth */
static double   g_t = 0;
static double   g_integ = 0;     /* the clocks' steady offset, learnt */         /* position between hist[1] and hist[2] */
static float    g_hist[4][2];    /* x[-1], x[0], x[1], x[2] for Catmull-Rom */
static unsigned g_underruns = 0;

/* Pop one stereo frame as float; 0 when the ring is empty. */
static int pop_frame(float out[2]) {
  size_t bpf = bytes_per_frame();
  if (g_size < bpf) return 0;
  for (int c = 0; c < 2; c++) {
    if (g_format == FMT_F32) {
      uint8_t b[4];
      for (int i = 0; i < 4; i++) b[i] = g_ring[(g_head + i) % RING_CAP];
      memcpy(&out[c], b, 4);
      g_head = (g_head + 4) % RING_CAP;
      g_size -= 4;
    } else {
      uint8_t lo = g_ring[g_head % RING_CAP];
      uint8_t hi = g_ring[(g_head + 1) % RING_CAP];
      out[c] = (float)(int16_t)((uint16_t)lo | ((uint16_t)hi << 8)) / 32768.0f;
      g_head = (g_head + 2) % RING_CAP;
      g_size -= 2;
    }
  }
  return 1;
}

static void drop_frames(size_t n) {
  size_t bytes = n * bytes_per_frame();
  if (bytes > g_size) bytes = g_size;
  g_head = (g_head + bytes) % RING_CAP;
  g_size -= bytes;
}

/* ---- The audio_out.nim calls the cores make ---- */

void dingbat_audio_open(int format, int freq, int play) {
  pthread_mutex_lock(&g_lock);
  g_format = format;
  g_freq   = freq;
  g_head = 0;
  g_size = 0;
  g_paused = !play;
  pthread_mutex_unlock(&g_lock);
}

static void queue_locked(const void *data, uint32_t len);

static void capture(const void *data, uint32_t len) {
  size_t bpf = g_format == FMT_F32 ? 8 : 4;
  size_t n = len / bpf;
  if (g_cap_frames + n > g_cap_alloc) {
    size_t want = g_cap_alloc ? g_cap_alloc * 2 : 32768;
    while (want < g_cap_frames + n) want *= 2;
    float *p = realloc(g_cap, want * 2 * sizeof(float));
    if (!p) return;
    g_cap = p;
    g_cap_alloc = want;
  }
  float *dst = g_cap + g_cap_frames * 2;
  if (g_format == FMT_F32) {
    memcpy(dst, data, n * 8);
  } else {
    const int16_t *src = data;
    for (size_t i = 0; i < n * 2; i++) dst[i] = (float)src[i] / 32768.0f;
  }
  g_cap_frames += n;
}

void dingbat_audio_put(const void *data, uint32_t len) {
  if (data == NULL || len == 0 || len > RING_CAP / 2) return;
  if (g_mode == 2) return;
  if (g_mode == 1 || g_mode == 3) capture(data, len);
  if (g_mode == 1) return;
  pthread_mutex_lock(&g_lock);
  if (g_stretch) {
    /* Each stereo frame twice: the ring fills twice as fast, so audio-sync
     * pacing runs the core at half speed, an octave down. */
    size_t bpf = bytes_per_frame();
    uint8_t pair[16];
    for (uint32_t off = 0; off + bpf <= len; off += (uint32_t)bpf) {
      memcpy(pair, (const uint8_t *)data + off, bpf);
      memcpy(pair + bpf, (const uint8_t *)data + off, bpf);
      queue_locked(pair, (uint32_t)(2 * bpf));
    }
  } else {
    queue_locked(data, len);
  }
  pthread_mutex_unlock(&g_lock);
}

static void queue_locked(const void *data, uint32_t len) {
  if (g_size + len > RING_CAP) { /* drop oldest to make room */
    size_t drop = g_size + len - RING_CAP;
    g_head = (g_head + drop) % RING_CAP;
    g_size -= drop;
  }
  size_t tail = (g_head + g_size) % RING_CAP;
  size_t first = RING_CAP - tail;
  if (first > len) first = len;
  memcpy(g_ring + tail, data, first);
  memcpy(g_ring, (const uint8_t *)data + first, len - first);
  g_size += len;
}

uint32_t dingbat_audio_queued(void) {
  pthread_mutex_lock(&g_lock);
  uint32_t s = (uint32_t)g_size;
  pthread_mutex_unlock(&g_lock);
  return s;
}

/* Drop whatever is queued (unsynced play keeps only the freshest; a frame
 * stepped while paused plays nothing). */
void dingbat_audio_clear(void) {
  pthread_mutex_lock(&g_lock);
  g_head = 0;
  g_size = 0;
  pthread_mutex_unlock(&g_lock);
}

void dingbat_audio_wait(uint32_t ms) {
  /* Only reached from the cores' audio-sync backstop loops. Drop the queue
   * after 250 ms without a drain so the emulator thread cannot spin forever. */
  usleep(ms * 1000);
  g_stall_ms += (int)ms;
  if (g_stall_ms >= 250) {
    dingbat_audio_clear();
    g_stall_ms = 0;
  }
}

/* ---- Pull API for the Swift shell (AVAudioSourceNode render block) ---- */

/* Fills dst with up to max_frames interleaved float32 stereo frames and
 * returns the count; the caller zero-fills the rest. Realtime-safe: one
 * mutex, no allocation, no Nim runtime. */
int dingbat_audio_read(float *dst, int max_frames) {
  if (dst == NULL || max_frames <= 0) return 0;
  pthread_mutex_lock(&g_lock);
  if (g_paused) {
    pthread_mutex_unlock(&g_lock);
    return 0;
  }
  size_t bpf = bytes_per_frame();
  size_t depth = g_size / bpf;
  int n = 0;
  if (g_free) {
    /* Fast-forward: whatever the last chunk was, as it comes. */
    float f[2];
    while (n < max_frames && pop_frame(f)) { dst[2 * n] = f[0]; dst[2 * n + 1] = f[1]; n++; }
    g_primed = 0;
    if (n > 0) g_stall_ms = 0;
    pthread_mutex_unlock(&g_lock);
    return n;
  }
  if (depth > DRC_CAP) {
    drop_frames(depth - DRC_TARGET);
    depth = DRC_TARGET;
    g_fill = DRC_TARGET;
  }
  if (!g_primed) {
    /* After a gap, wait until most of the target is back: one clean start
     * instead of a stutter of tiny underruns. */
    if (depth < (DRC_TARGET * 3) / 4) {
      pthread_mutex_unlock(&g_lock);
      return 0;
    }
    for (int i = 1; i < 4; i++) pop_frame(g_hist[i]);
    g_hist[0][0] = g_hist[1][0]; g_hist[0][1] = g_hist[1][1];
    g_t = 0;
    g_fill = (double)depth;
    g_primed = 1;
  }
  /* Smoothed depth -> a ratio a fraction of a percent either side of 1.
   * Deeper than the target: consume a little faster, and the reverse. */
  g_fill += ((double)depth - g_fill) * 0.08;
  double err = (g_fill - DRC_TARGET) / DRC_TARGET;
  g_integ += err * DRC_IGAIN;
  if (g_integ > DRC_IMAX) g_integ = DRC_IMAX;
  if (g_integ < -DRC_IMAX) g_integ = -DRC_IMAX;
  double step = 1.0 + err * DRC_GAIN + g_integ;
  if (step > 1.0 + DRC_MAX) step = 1.0 + DRC_MAX;
  if (step < 1.0 - DRC_MAX) step = 1.0 - DRC_MAX;
  for (; n < max_frames; n++) {
    /* Catmull-Rom between x[0] and x[1]. */
    float t = (float)g_t, t2 = t * t, t3 = t2 * t;
    for (int c = 0; c < 2; c++) {
      float p0 = g_hist[0][c], p1 = g_hist[1][c], p2 = g_hist[2][c], p3 = g_hist[3][c];
      dst[2 * n + c] = 0.5f * ((2.0f * p1) + (-p0 + p2) * t +
                               (2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3) * t2 +
                               (-p0 + 3.0f * p1 - 3.0f * p2 + p3) * t3);
    }
    g_t += step;
    int dry = 0;
    while (g_t >= 1.0) {
      g_t -= 1.0;
      memmove(g_hist[0], g_hist[1], sizeof(g_hist[0]) * 3);
      if (!pop_frame(g_hist[3])) { dry = 1; break; }
    }
    if (dry) {
      /* Ran dry: the rest of this buffer is silence, then a clean restart. */
      g_primed = 0;
      g_underruns++;
      n++;
      break;
    }
  }
  if (n > 0) g_stall_ms = 0; /* consumer is alive */
  pthread_mutex_unlock(&g_lock);
  return n;
}

/* The depth to hold, in frames: ~25 ms by default. Slow motion delivers a
 * frame's 33 ms of sound in one burst, so it needs more. Main thread. */
void dingbat_audio_set_target(int frames) {
  pthread_mutex_lock(&g_lock);
  g_target = frames < 256 ? 256 : frames;
  pthread_mutex_unlock(&g_lock);
}

void dingbat_audio_set_free(int on) {
  pthread_mutex_lock(&g_lock);
  g_free = on != 0;
  pthread_mutex_unlock(&g_lock);
}

int dingbat_audio_underruns(void) { return (int)g_underruns; }

int dingbat_audio_queued_frames(void) {
  pthread_mutex_lock(&g_lock);
  int frames = (int)(g_size / bytes_per_frame());
  pthread_mutex_unlock(&g_lock);
  return frames;
}

int dingbat_audio_sample_rate(void) { return g_freq; }

void dingbat_audio_set_stretch(int on) {
  pthread_mutex_lock(&g_lock);
  g_stretch = on != 0;
  pthread_mutex_unlock(&g_lock);
}

void dingbat_audio_set_mode(int mode) { g_mode = mode; }
int dingbat_audio_get_mode(void) { return g_mode; }

/* Move up to max_frames captured frames (float32 stereo, interleaved) into
 * dst; returns how many. Main thread. */
int dingbat_audio_capture_take(float *dst, int max_frames) {
  size_t n = g_cap_frames < (size_t)max_frames ? g_cap_frames : (size_t)max_frames;
  if (n == 0 || dst == NULL) return 0;
  memcpy(dst, g_cap, n * 8);
  memmove(g_cap, g_cap + n * 2, (g_cap_frames - n) * 8);
  g_cap_frames -= n;
  return (int)n;
}

int dingbat_audio_captured_frames(void) { return (int)g_cap_frames; }

void dingbat_audio_capture_clear(void) { g_cap_frames = 0; }
