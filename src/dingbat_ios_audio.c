/*
 * iOS audio backend for the dingbat core, compiled into libdingbat.a via a
 * {.compile.} pragma in src/dingbat_ios.nim.
 *
 * The emulator core's APUs (src/dingbat/gba/apu.nim, src/dingbat/gb/apu.nim)
 * talk to audio exclusively through a handful of SDL2 C functions declared
 * with `importc` — they are *link-time* dependencies, not source ones. On iOS
 * there is no SDL2; instead this file provides those exact symbols, backed by
 * a mutex-guarded ring buffer. That keeps the core sources byte-identical to
 * the desktop build (zero `when defined(ios)` edits in the APUs) while giving
 * the Swift shell a pull-style API for AVAudioSourceNode.
 *
 * Producer: the emulator thread. The GBA APU queues int16 stereo frames and
 * the GB APU queues float32 stereo frames, both at 32768 Hz, via
 * SDL_QueueAudio. The active sample format is whatever the last
 * SDL_OpenAudio() call asked for.
 *
 * Consumer: the CoreAudio render thread calls dingbat_audio_read() from the
 * AVAudioSourceNode render block. It converts to float32 and never touches
 * the Nim runtime, so it is safe off the main thread.
 *
 * Pacing: the core's audio-sync model is "block in get_sample() while more
 * than two APU buffers are queued". The Swift shell avoids ever hitting that
 * blocking loop by checking dingbat_audio_ahead() before each frame (same as
 * the desktop main loop). If the shell misbehaves — or the audio engine stops
 * mid-frame (interruption, route change) — SDL_Delay() self-heals: after
 * ~250 ms without the consumer draining anything it drops the queued audio,
 * so emulation can stall at worst briefly, never deadlock.
 */

#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

/* Matches the SDL_AudioSpec mirror declared in the APU modules. */
typedef struct {
  int      freq;
  uint16_t format;
  uint8_t  channels;
  uint8_t  silence;
  uint16_t samples;
  uint16_t padding;
  uint32_t size;
  void    *callback;
  void    *userdata;
} DINGBAT_SDL_AudioSpec;

#define AUDIO_S16LSB 0x8010
#define AUDIO_F32LSB 0x8120

/* 256 KiB ring: ~2 s of s16 stereo or ~1 s of f32 stereo at 32768 Hz.
 * The pacing loop keeps occupancy near two APU buffers (~4-8 KiB), so the
 * capacity is pure headroom; overflow drops the oldest bytes. */
#define RING_CAP (256 * 1024)

static uint8_t  g_ring[RING_CAP];
static size_t   g_head = 0;      /* read position  */
static size_t   g_size = 0;      /* bytes queued   */
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static uint16_t g_format = AUDIO_S16LSB;
static int      g_freq   = 32768;
static int      g_paused = 1;
static int      g_stall_ms = 0;  /* consecutive SDL_Delay ms without a drain */

static size_t bytes_per_frame(void) {
  return g_format == AUDIO_F32LSB ? 8 : 4; /* stereo */
}

/* ---- SDL2 audio symbols the core links against ---- */

int SDL_OpenAudio(DINGBAT_SDL_AudioSpec *desired, DINGBAT_SDL_AudioSpec *obtained) {
  (void)obtained;
  pthread_mutex_lock(&g_lock);
  if (desired) {
    g_format = desired->format;
    g_freq   = desired->freq;
  }
  g_head = 0;
  g_size = 0;
  g_paused = 1;
  pthread_mutex_unlock(&g_lock);
  return 0;
}

uint32_t SDL_OpenAudioDevice(void *device, int iscapture,
                             DINGBAT_SDL_AudioSpec *desired,
                             DINGBAT_SDL_AudioSpec *obtained,
                             int allowed_changes) {
  (void)device; (void)iscapture; (void)allowed_changes;
  return SDL_OpenAudio(desired, obtained) == 0 ? 1 : 0;
}

void SDL_CloseAudio(void) {
  pthread_mutex_lock(&g_lock);
  g_head = 0;
  g_size = 0;
  g_paused = 1;
  pthread_mutex_unlock(&g_lock);
}

void SDL_CloseAudioDevice(uint32_t dev) { (void)dev; SDL_CloseAudio(); }

void SDL_PauseAudio(int pause_on) { g_paused = pause_on; }

void SDL_PauseAudioDevice(uint32_t dev, int pause_on) {
  (void)dev;
  SDL_PauseAudio(pause_on);
}

int SDL_QueueAudio(uint32_t dev, const void *data, uint32_t len) {
  (void)dev;
  if (data == NULL || len == 0 || len > RING_CAP) return 0;
  pthread_mutex_lock(&g_lock);
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
  pthread_mutex_unlock(&g_lock);
  return 0;
}

uint32_t SDL_GetQueuedAudioSize(uint32_t dev) {
  (void)dev;
  pthread_mutex_lock(&g_lock);
  uint32_t s = (uint32_t)g_size;
  pthread_mutex_unlock(&g_lock);
  return s;
}

void SDL_ClearQueuedAudio(uint32_t dev) {
  (void)dev;
  pthread_mutex_lock(&g_lock);
  g_head = 0;
  g_size = 0;
  pthread_mutex_unlock(&g_lock);
}

void SDL_Delay(uint32_t ms) {
  /* Only reached from the APUs' audio-sync backstop loops. Self-heal a
   * stalled consumer (stopped audio engine) by dropping the queue after
   * 250 ms so the emulator thread can never spin forever. */
  usleep(ms * 1000);
  g_stall_ms += (int)ms;
  if (g_stall_ms >= 250) {
    SDL_ClearQueuedAudio(0);
    g_stall_ms = 0;
  }
}

/* ---- Pull API for the Swift shell (AVAudioSourceNode render block) ---- */

/* Fills dst with up to max_frames interleaved float32 stereo frames.
 * Returns the number of frames written; the caller zero-fills the rest.
 * Realtime-safe: one mutex (uncontended in practice, held only for memcpy)
 * and no allocation, no Nim runtime. */
int dingbat_audio_read(float *dst, int max_frames) {
  if (dst == NULL || max_frames <= 0) return 0;
  pthread_mutex_lock(&g_lock);
  if (g_paused) {
    pthread_mutex_unlock(&g_lock);
    return 0;
  }
  size_t bpf = bytes_per_frame();
  size_t frames = g_size / bpf;
  if (frames > (size_t)max_frames) frames = (size_t)max_frames;
  for (size_t f = 0; f < frames; f++) {
    for (int c = 0; c < 2; c++) {
      if (g_format == AUDIO_F32LSB) {
        uint8_t b[4];
        for (int i = 0; i < 4; i++) b[i] = g_ring[(g_head + i) % RING_CAP];
        float v;
        memcpy(&v, b, 4);
        dst[f * 2 + c] = v;
        g_head = (g_head + 4) % RING_CAP;
        g_size -= 4;
      } else {
        uint8_t lo = g_ring[g_head % RING_CAP];
        uint8_t hi = g_ring[(g_head + 1) % RING_CAP];
        int16_t v = (int16_t)((uint16_t)lo | ((uint16_t)hi << 8));
        dst[f * 2 + c] = (float)v / 32768.0f;
        g_head = (g_head + 2) % RING_CAP;
        g_size -= 2;
      }
    }
  }
  if (frames > 0) g_stall_ms = 0; /* consumer is alive */
  pthread_mutex_unlock(&g_lock);
  return (int)frames;
}

int dingbat_audio_queued_frames(void) {
  pthread_mutex_lock(&g_lock);
  int frames = (int)(g_size / bytes_per_frame());
  pthread_mutex_unlock(&g_lock);
  return frames;
}

int dingbat_audio_sample_rate(void) { return g_freq; }
