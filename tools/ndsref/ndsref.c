/* ndsref: a headless libretro frontend for black-box DS reference runs.
 *
 * Loads a libretro core (a shared library), runs a ROM for N frames with no
 * window and no audio device, and writes the requested frames as 256x384
 * PNGs (top screen above bottom), the same layout tools/ndsrun.nim writes,
 * plus the whole run's audio as a WAV. See tools/ndsref/README.md.
 *
 * Only the public libretro API (libretro.h, MIT) is used. The core is a black
 * box: what it does is observed through its outputs, never its sources
 * (docs/oracles.md).
 */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#include "libretro.h"

#define DS_W 256
#define DS_H 192

static int verbose;
/* Our own output. Unless -v, the core's stdout/stderr go to /dev/null so
   its chatter doesn't mix with ours. */
static FILE *outf, *errf;

static void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(errf, "ndsref: ");
  vfprintf(errf, fmt, ap);
  fprintf(errf, "\n");
  va_end(ap);
  exit(2);
}

static char *xstrdup(const char *s) { return s ? strdup(s) : NULL; }

/* ---------------------------------------------------------------- options */

typedef struct {
  char *key, *desc, *def, *values, *cur; /* values: "a|b|c" */
  int user;                              /* cur came from --opt */
} Option;

static struct retro_subsystem_info subsys[16];
static int n_subsys;
static int rumble_log, cur_frame;
static uint16_t rumble_now[2];

static bool RETRO_CALLCONV set_rumble_state(unsigned port, enum retro_rumble_effect effect,
                                            uint16_t strength) {
  if (port == 0 && (unsigned)effect < 2 && rumble_now[effect] != strength) {
    rumble_now[effect] = strength;
    fprintf(outf, "rumble frame=%d %s=%u\n", cur_frame,
            effect == RETRO_RUMBLE_STRONG ? "strong" : "weak", strength);
  }
  return true;
}

static Option opts[512];
static int n_opts;
static struct { char *key, *val; int used; } user_opts[128];
static int n_user_opts;

static void add_user_opt(const char *kv_in) {
  char *kv = strdup(kv_in), *eq = strchr(kv, '=');
  if (!eq || n_user_opts == 128) die("an option wants KEY=VALUE (got '%s')", kv_in);
  *eq = 0;
  user_opts[n_user_opts].key = kv;
  user_opts[n_user_opts].val = eq + 1;
  n_user_opts++;
}

/* KEY=VALUE lines, '#' comments; later settings win over earlier ones. */
static int load_opts_file(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  char line[1024];
  while (fgets(line, sizeof line, f)) {
    char *s = line;
    while (*s == ' ' || *s == '\t') s++;
    s[strcspn(s, "\r\n")] = 0;
    if (*s == 0 || *s == '#') continue;
    add_user_opt(s);
  }
  fclose(f);
  return 1;
}

static Option *opt_find(const char *key) {
  for (int i = 0; i < n_opts; i++)
    if (strcmp(opts[i].key, key) == 0) return &opts[i];
  return NULL;
}

static void opt_define(const char *key, const char *desc, const char *def,
                       const char *values) {
  Option *o = opt_find(key);
  if (!o) {
    if (n_opts == (int)(sizeof opts / sizeof opts[0])) return;
    o = &opts[n_opts++];
    o->key = xstrdup(key);
  } else {
    free(o->desc); free(o->def); free(o->values);
  }
  o->desc = xstrdup(desc ? desc : "");
  o->def = xstrdup(def ? def : "");
  o->values = xstrdup(values ? values : "");
  if (!o->user) { free(o->cur); o->cur = xstrdup(o->def); }
  for (int i = 0; i < n_user_opts; i++)
    if (strcmp(user_opts[i].key, key) == 0) {
      free(o->cur);
      o->cur = xstrdup(user_opts[i].val);
      o->user = 1;
      user_opts[i].used = 1;
    }
}

/* SET_VARIABLES: { key, "Description; default|other|..." } */
static void opts_from_variables(const struct retro_variable *v) {
  for (; v && v->key; v++) {
    const char *semi = v->value ? strchr(v->value, ';') : NULL;
    char desc[512] = "", def[256] = "";
    const char *vals = "";
    if (semi) {
      snprintf(desc, sizeof desc, "%.*s", (int)(semi - v->value), v->value);
      vals = semi + 1;
      while (*vals == ' ') vals++;
      const char *bar = strchr(vals, '|');
      snprintf(def, sizeof def, "%.*s", bar ? (int)(bar - vals) : (int)strlen(vals), vals);
    }
    opt_define(v->key, desc, def, vals);
  }
}

static void join_values(const struct retro_core_option_value *vals, char *out, size_t n) {
  out[0] = 0;
  for (int i = 0; i < RETRO_NUM_CORE_OPTION_VALUES_MAX && vals[i].value; i++) {
    if (i) strncat(out, "|", n - strlen(out) - 1);
    strncat(out, vals[i].value, n - strlen(out) - 1);
  }
}

static void opts_from_v1(const struct retro_core_option_definition *d) {
  char buf[8192];
  for (; d && d->key; d++) {
    join_values(d->values, buf, sizeof buf);
    const char *def = d->default_value ? d->default_value : d->values[0].value;
    opt_define(d->key, d->desc, def, buf);
  }
}

static void opts_from_v2(const struct retro_core_options_v2 *o) {
  char buf[8192];
  if (!o) return;
  for (const struct retro_core_option_v2_definition *d = o->definitions; d && d->key; d++) {
    join_values(d->values, buf, sizeof buf);
    const char *def = d->default_value ? d->default_value : d->values[0].value;
    opt_define(d->key, d->desc, def, buf);
  }
}

/* ---------------------------------------------------------------- state */

static char workdir[1024], sysdir[1100], savedir[1100];
static unsigned pixfmt = RETRO_PIXEL_FORMAT_0RGB1555;
static uint8_t *frame_buf; /* last frame, as the core gave it (packed) */
static unsigned frame_w, frame_h, frame_bpp;
static size_t frame_cap;
static int frames_seen;

static int16_t *audio;
static size_t audio_len, audio_cap; /* in int16 values */
static double sample_rate, fps;

static uint16_t pad_bits;
static int touch_down, touch_x, touch_y;
static int layout_mode; /* 0 auto, 1 tb, 2 bt, 3 lr, 4 rl */
static unsigned devices_seen;

static struct retro_frame_time_callback frame_time_cb;

static void core_log(enum retro_log_level level, const char *fmt, ...) {
  if (!verbose && level < RETRO_LOG_ERROR) return;
  va_list ap;
  va_start(ap, fmt);
  fprintf(errf, "[core] ");
  vfprintf(errf, fmt, ap);
  va_end(ap);
}

static bool environment(unsigned cmd, void *data) {
  /* case labels are compared without the experimental flag */
#define EXP(x) ((x) & ~RETRO_ENVIRONMENT_EXPERIMENTAL)
  switch (cmd & ~RETRO_ENVIRONMENT_EXPERIMENTAL) {
  case EXP(RETRO_ENVIRONMENT_GET_CAN_DUPE):
    *(bool *)data = true;
    return true;
  case EXP(RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY):
    *(const char **)data = sysdir;
    return true;
  case EXP(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY):
    *(const char **)data = savedir;
    return true;
  case EXP(RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY):
    *(const char **)data = sysdir;
    return true;
  case EXP(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT):
    pixfmt = *(const enum retro_pixel_format *)data;
    if (verbose) fprintf(errf, "ndsref: pixel format %u\n", pixfmt);
    return pixfmt <= RETRO_PIXEL_FORMAT_RGB565;
  case EXP(RETRO_ENVIRONMENT_GET_LOG_INTERFACE):
    ((struct retro_log_callback *)data)->log = core_log;
    return true;
  case EXP(RETRO_ENVIRONMENT_SET_VARIABLES):
    opts_from_variables(data);
    return true;
  case EXP(RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION):
    *(unsigned *)data = 2;
    return true;
  case EXP(RETRO_ENVIRONMENT_SET_CORE_OPTIONS):
    opts_from_v1(data);
    return true;
  case EXP(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL):
    opts_from_v1(((const struct retro_core_options_intl *)data)->us);
    return true;
  case EXP(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2):
    opts_from_v2(data);
    return true;
  case EXP(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL):
    opts_from_v2(((const struct retro_core_options_v2_intl *)data)->us);
    return true;
  case EXP(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY):
  case EXP(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK):
    return true;
  case EXP(RETRO_ENVIRONMENT_GET_VARIABLE): {
    struct retro_variable *v = data;
    Option *o = opt_find(v->key);
    v->value = o ? o->cur : NULL;
    if (!o) {
      for (int i = 0; i < n_user_opts; i++)
        if (strcmp(user_opts[i].key, v->key) == 0) {
          v->value = user_opts[i].val;
          user_opts[i].used = 1;
        }
    }
    if (verbose > 1) fprintf(errf, "ndsref: get %s = %s\n", v->key, v->value ? v->value : "(null)");
    return v->value != NULL;
  }
  case EXP(RETRO_ENVIRONMENT_SET_VARIABLE): {
    const struct retro_variable *v = data;
    if (!v) return true;
    Option *o = opt_find(v->key);
    if (o && v->value) { free(o->cur); o->cur = xstrdup(v->value); }
    return o != NULL;
  }
  case EXP(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE):
    *(bool *)data = false;
    return true;
  case EXP(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO): {
    const struct retro_system_av_info *av = data;
    if (sample_rate != 0 && av->timing.sample_rate != sample_rate)
      fprintf(errf, "ndsref: core changed its sample rate %g -> %g mid-run\n",
              sample_rate, av->timing.sample_rate);
    sample_rate = av->timing.sample_rate;
    fps = av->timing.fps;
    return true;
  }
  case EXP(RETRO_ENVIRONMENT_SET_GEOMETRY):
  case EXP(RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS):
  case EXP(RETRO_ENVIRONMENT_SET_CONTROLLER_INFO):
  case EXP(RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO): {
    /* kept for --slot2: the descriptions stay the core's (static) strings */
    const struct retro_subsystem_info *si = data;
    n_subsys = 0;
    for (; si && si->ident && n_subsys < 16; si++) subsys[n_subsys++] = *si;
    return true;
  }
  case EXP(RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE):
    /* --rumble-log: the core's rumble requests are printed, frame by frame */
    if (!rumble_log) return false;
    ((struct retro_rumble_interface *)data)->set_rumble_state = set_rumble_state;
    return true;
  case EXP(RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL):
  case EXP(RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS):
  case EXP(RETRO_ENVIRONMENT_SET_MEMORY_MAPS):
  case EXP(RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS):
  case EXP(RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE):
  case EXP(RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME):
    return true;
  case EXP(RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK):
    frame_time_cb = *(const struct retro_frame_time_callback *)data;
    return true;
  case EXP(RETRO_ENVIRONMENT_GET_INPUT_BITMASKS):
    return true;
  case EXP(RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE):
    if (data) *(int *)data = 3;
    return true;
  case EXP(RETRO_ENVIRONMENT_GET_FASTFORWARDING):
    if (data) *(bool *)data = false;
    return true;
  case EXP(RETRO_ENVIRONMENT_GET_LANGUAGE):
    *(unsigned *)data = RETRO_LANGUAGE_ENGLISH;
    return true;
  case EXP(RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION):
    *(unsigned *)data = 1;
    return true;
  case EXP(RETRO_ENVIRONMENT_SET_MESSAGE):
    if (verbose) fprintf(errf, "[core msg] %s\n", ((const struct retro_message *)data)->msg);
    return true;
  case EXP(RETRO_ENVIRONMENT_SET_MESSAGE_EXT):
    if (verbose) fprintf(errf, "[core msg] %s\n", ((const struct retro_message_ext *)data)->msg);
    return true;
  case EXP(RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS):
    *(unsigned *)data = 1;
    return true;
  default:
    /* Refused: hardware rendering (so the core renders in software), VFS,
       rumble, sensors, the audio callback, JIT, and anything else. */
    if (verbose > 1) fprintf(errf, "ndsref: refused env %u (0x%x)\n", cmd & 0xFFFF, cmd);
    return false;
  }
}

static void video_refresh(const void *data, unsigned w, unsigned h, size_t pitch) {
  if (!data) return; /* dupe: keep the last frame */
  unsigned bpp = pixfmt == RETRO_PIXEL_FORMAT_XRGB8888 ? 4 : 2;
  size_t need = (size_t)w * h * bpp;
  if (need > frame_cap) {
    frame_buf = realloc(frame_buf, need);
    frame_cap = need;
  }
  for (unsigned y = 0; y < h; y++)
    memcpy(frame_buf + (size_t)y * w * bpp, (const uint8_t *)data + y * pitch, (size_t)w * bpp);
  frame_w = w;
  frame_h = h;
  frame_bpp = bpp;
  frames_seen++;
}

static void audio_push(const int16_t *s, size_t n) {
  if (audio_len + n > audio_cap) {
    audio_cap = (audio_len + n) * 2;
    audio = realloc(audio, audio_cap * sizeof *audio);
  }
  memcpy(audio + audio_len, s, n * sizeof *s);
  audio_len += n;
}

static int want_audio;

static void audio_sample(int16_t l, int16_t r) {
  if (!want_audio) return;
  int16_t s[2] = {l, r};
  audio_push(s, 2);
}

static size_t audio_batch(const int16_t *data, size_t frames) {
  if (want_audio) audio_push(data, frames * 2);
  return frames;
}

static void input_poll(void) {}

/* Where the bottom screen sits in the core's frame, and at what scale. */
typedef struct { int ok, s, tx, ty, bx, by; } Geometry;

static Geometry geometry(void) {
  Geometry g = {0};
  int w = frame_w, h = frame_h;
  int mode = layout_mode;
  if (mode == 0) {
    if (w * 384 <= h * 256 + 256) mode = 1;      /* at least as tall as top/bottom */
    else if (w * 192 >= h * 512 - 512) mode = 3; /* at least as wide as side by side */
  }
  if (mode == 1 || mode == 2) {
    g.s = w / DS_W;
    if (g.s < 1 || h < 2 * DS_H * g.s) return g;
    int far = h - DS_H * g.s;
    g.tx = g.bx = (w - DS_W * g.s) / 2;
    g.ty = mode == 1 ? 0 : far;
    g.by = mode == 1 ? far : 0;
  } else if (mode == 3 || mode == 4) {
    g.s = h / DS_H;
    if (g.s < 1 || w < 2 * DS_W * g.s) return g;
    int far = w - DS_W * g.s;
    g.ty = g.by = (h - DS_H * g.s) / 2;
    g.tx = mode == 3 ? 0 : far;
    g.bx = mode == 3 ? far : 0;
  } else {
    return g;
  }
  g.ok = 1;
  return g;
}

static int16_t pointer_coord(int pixel, int size) {
  /* -0x7fff..0x7fff spans the frame; aim at the pixel's centre */
  double v = ((pixel + 0.5) / size) * 2.0 * 0x7fff - 0x7fff;
  return (int16_t)lround(v);
}

static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
  unsigned dev = device & RETRO_DEVICE_MASK;
  if (dev < 32 && !(devices_seen & (1u << dev))) {
    devices_seen |= 1u << dev;
    if (verbose) fprintf(errf, "ndsref: core polls device %u\n", dev);
  }
  if (port != 0) return 0;
  if (dev == RETRO_DEVICE_JOYPAD) {
    if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)pad_bits;
    return id < 16 ? (pad_bits >> id) & 1 : 0;
  }
  if (dev == RETRO_DEVICE_POINTER && index == 0) {
    Geometry g = geometry();
    switch (id) {
    case RETRO_DEVICE_ID_POINTER_PRESSED: return touch_down && g.ok;
    case RETRO_DEVICE_ID_POINTER_COUNT: return touch_down && g.ok;
    case RETRO_DEVICE_ID_POINTER_IS_OFFSCREEN: return !touch_down;
    case RETRO_DEVICE_ID_POINTER_X:
      return g.ok ? pointer_coord(g.bx + touch_x * g.s, frame_w) : 0;
    case RETRO_DEVICE_ID_POINTER_Y:
      return g.ok ? pointer_coord(g.by + touch_y * g.s, frame_h) : 0;
    }
  }
  return 0;
}

/* ---------------------------------------------------------------- PNG/WAV */

static void be32(uint8_t *p, uint32_t v) {
  p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

static void png_chunk(FILE *f, const char *type, const uint8_t *data, uint32_t len) {
  uint8_t hdr[8];
  be32(hdr, len);
  memcpy(hdr + 4, type, 4);
  fwrite(hdr, 1, 8, f);
  if (len) fwrite(data, 1, len, f);
  uLong crc = crc32(0, (const Bytef *)type, 4);
  if (len) crc = crc32(crc, data, len);
  uint8_t c[4];
  be32(c, (uint32_t)crc);
  fwrite(c, 1, 4, f);
}

static void write_png(const char *path, int w, int h, const uint8_t *rgb) {
  size_t rawlen = (size_t)(w * 3 + 1) * h;
  uint8_t *raw = malloc(rawlen);
  for (int y = 0; y < h; y++) {
    raw[y * (w * 3 + 1)] = 0;
    memcpy(raw + y * (w * 3 + 1) + 1, rgb + (size_t)y * w * 3, (size_t)w * 3);
  }
  uLongf zlen = compressBound(rawlen);
  uint8_t *z = malloc(zlen);
  if (compress2(z, &zlen, raw, rawlen, 6) != Z_OK) die("zlib failed");
  FILE *f = fopen(path, "wb");
  if (!f) die("cannot write %s: %s", path, strerror(errno));
  static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
  fwrite(sig, 1, 8, f);
  uint8_t ihdr[13];
  be32(ihdr, w);
  be32(ihdr + 4, h);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = ihdr[11] = ihdr[12] = 0;
  png_chunk(f, "IHDR", ihdr, 13);
  png_chunk(f, "IDAT", z, (uint32_t)zlen);
  png_chunk(f, "IEND", NULL, 0);
  fclose(f);
  free(raw);
  free(z);
}

static void pixel_rgb(int x, int y, uint8_t *o) {
  const uint8_t *p = frame_buf + ((size_t)y * frame_w + x) * frame_bpp;
  if (frame_bpp == 4) {
    uint32_t v = p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
    o[0] = v >> 16; o[1] = v >> 8; o[2] = v;
    return;
  }
  uint16_t v = p[0] | p[1] << 8;
  unsigned r, g, b;
  if (pixfmt == RETRO_PIXEL_FORMAT_RGB565) {
    r = v >> 11; g = (v >> 5) & 63; b = v & 31;
    o[1] = g << 2 | g >> 4;
  } else {
    r = (v >> 10) & 31; g = (v >> 5) & 31; b = v & 31;
    o[1] = g << 3 | g >> 2;
  }
  o[0] = r << 3 | r >> 2;
  o[2] = b << 3 | b >> 2;
}

static int depth5;

/* --depth5: keep each channel's top 5 bits and widen them the way
   tools/ndsrun.nim does ((c << 3) | (c >> 2)), so a core that widens 5- or
   6-bit colour differently still compares exactly. */
static void to_depth5(uint8_t *o) {
  for (int k = 0; k < 3; k++) {
    unsigned c = o[k] >> 3;
    o[k] = c << 3 | c >> 2;
  }
}

static int dump_frame(const char *path) {
  if (!frame_buf) { fprintf(errf, "ndsref: no frame yet for %s\n", path); return 0; }
  Geometry g = geometry();
  if (!g.ok) {
    fprintf(errf, "ndsref: frame %ux%u is not a top/bottom or side-by-side layout; "
                    "pick one with --opt (see --list-opts) or --layout\n", frame_w, frame_h);
    return 0;
  }
  uint8_t *rgb = malloc(DS_W * DS_H * 2 * 3);
  for (int y = 0; y < DS_H; y++)
    for (int x = 0; x < DS_W; x++) {
      pixel_rgb(g.tx + x * g.s, g.ty + y * g.s, rgb + (y * DS_W + x) * 3);
      pixel_rgb(g.bx + x * g.s, g.by + y * g.s, rgb + ((DS_H + y) * DS_W + x) * 3);
      if (depth5) {
        to_depth5(rgb + (y * DS_W + x) * 3);
        to_depth5(rgb + ((DS_H + y) * DS_W + x) * 3);
      }
    }
  write_png(path, DS_W, DS_H * 2, rgb);
  free(rgb);
  return 1;
}

static void le(FILE *f, uint32_t v, int n) {
  for (int i = 0; i < n; i++) fputc((v >> (8 * i)) & 0xFF, f);
}

static void write_wav(const char *path) {
  FILE *f = fopen(path, "wb");
  if (!f) die("cannot write %s", path);
  uint32_t rate = (uint32_t)lround(sample_rate);
  uint32_t bytes = (uint32_t)(audio_len * 2);
  fwrite("RIFF", 1, 4, f); le(f, 36 + bytes, 4);
  fwrite("WAVEfmt ", 1, 8, f); le(f, 16, 4);
  le(f, 1, 2); le(f, 2, 2); le(f, rate, 4); le(f, rate * 4, 4); le(f, 4, 2); le(f, 16, 2);
  fwrite("data", 1, 4, f); le(f, bytes, 4);
  for (size_t i = 0; i < audio_len; i++) le(f, (uint16_t)audio[i], 2);
  fclose(f);
}

/* ---------------------------------------------------------------- input */

typedef struct { int touch, button, x, y, first, last; } Press;
static Press presses[4096];
static int n_presses;

static int button_id(const char *s) {
  static const struct { const char *n; int id; } t[] = {
    {"A", RETRO_DEVICE_ID_JOYPAD_A}, {"B", RETRO_DEVICE_ID_JOYPAD_B},
    {"SELECT", RETRO_DEVICE_ID_JOYPAD_SELECT}, {"START", RETRO_DEVICE_ID_JOYPAD_START},
    {"RIGHT", RETRO_DEVICE_ID_JOYPAD_RIGHT}, {"LEFT", RETRO_DEVICE_ID_JOYPAD_LEFT},
    {"UP", RETRO_DEVICE_ID_JOYPAD_UP}, {"DOWN", RETRO_DEVICE_ID_JOYPAD_DOWN},
    {"R", RETRO_DEVICE_ID_JOYPAD_R}, {"L", RETRO_DEVICE_ID_JOYPAD_L},
    {"X", RETRO_DEVICE_ID_JOYPAD_X}, {"Y", RETRO_DEVICE_ID_JOYPAD_Y}};
  for (size_t i = 0; i < sizeof t / sizeof t[0]; i++)
    if (strcasecmp(t[i].n, s) == 0) return t[i].id;
  die("unknown button %s", s);
  return -1;
}

/* "KEY@F[+D|-L]" items, comma separated; KEY may be TOUCH:x:y. Held from
   frame F (0-based, applied before that frame runs), released at frame
   F+D (default D = 2) or L - the tools/ndsrun.nim --press syntax. */
static void parse_presses(const char *spec, int force_touch) {
  char *dup = strdup(spec), *save = NULL;
  for (char *item = strtok_r(dup, ",", &save); item; item = strtok_r(NULL, ",", &save)) {
    char *at = strchr(item, '@');
    if (!at) die("--press/--touch want KEY@FRAME[+DUR|-LAST]");
    *at = 0;
    if (n_presses == 4096) die("too many presses");
    Press *p = &presses[n_presses++];
    memset(p, 0, sizeof *p);
    char *when = at + 1, *plus = strchr(when, '+'), *minus = strchr(when, '-');
    p->first = atoi(when);
    p->last = plus ? p->first + atoi(plus + 1) : minus ? atoi(minus + 1) : p->first + 2;
    const char *what = item;
    int touch = force_touch;
    if (strncasecmp(what, "TOUCH:", 6) == 0) { what += 6; touch = 1; }
    if (touch) {
      if (sscanf(what, "%d:%d", &p->x, &p->y) != 2) die("touch wants X:Y@F");
      p->touch = 1;
    } else {
      p->button = button_id(what);
    }
  }
  free(dup);
}

static void apply_presses(int f) {
  for (int i = 0; i < n_presses; i++) {
    Press *p = &presses[i];
    if (f != p->first && f != p->last) continue;
    int down = f == p->first;
    if (p->touch) {
      touch_down = down;
      if (down) { touch_x = p->x; touch_y = p->y; }
    } else if (down) {
      pad_bits |= 1u << p->button;
    } else {
      pad_bits &= ~(1u << p->button);
    }
  }
}

/* ---------------------------------------------------------------- files */

static void mkdirs(const char *path) {
  char tmp[1200];
  snprintf(tmp, sizeof tmp, "%s", path);
  for (char *p = tmp + 1; *p; p++)
    if (*p == '/') { *p = 0; mkdir(tmp, 0755); *p = '/'; }
  mkdir(tmp, 0755);
}

static int copy_file(const char *from, const char *to) {
  FILE *a = fopen(from, "rb");
  if (!a) return 0;
  char dir[1200];
  snprintf(dir, sizeof dir, "%s", to);
  char *slash = strrchr(dir, '/');
  if (slash) { *slash = 0; mkdirs(dir); }
  FILE *b = fopen(to, "wb");
  if (!b) die("cannot write %s", to);
  char buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, a)) > 0) fwrite(buf, 1, n, b);
  fclose(a);
  fclose(b);
  return 1;
}

static int rm_entry(const char *path, const struct stat *sb, int flag, struct FTW *ftw) {
  (void)sb; (void)flag; (void)ftw;
  return remove(path);
}

static uint8_t *read_file(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (!f) die("cannot open %s", path);
  fseek(f, 0, SEEK_END);
  *len = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *d = malloc(*len ? *len : 1);
  if (fread(d, 1, *len, f) != *len) die("short read %s", path);
  fclose(f);
  return d;
}

/* --core NAME without a slash: NAME, NAME_libretro.dylib/.so/.dll in
   $NDSREF_CORES or ~/.cache/dingbat-nds/cores. */
static const char *resolve_core(const char *name) {
  static char path[1200];
  if (strchr(name, '/')) return name;
  const char *exts[] = {"", "_libretro.dylib", "_libretro.so", "_libretro.dll", ".dylib", ".so"};
  char dirs[2][1024];
  int nd = 0;
  if (getenv("NDSREF_CORES")) snprintf(dirs[nd++], 1024, "%s", getenv("NDSREF_CORES"));
  if (getenv("HOME")) snprintf(dirs[nd++], 1024, "%s/.cache/dingbat-nds/cores", getenv("HOME"));
  for (int d = 0; d < nd; d++)
    for (size_t e = 0; e < sizeof exts / sizeof exts[0]; e++) {
      snprintf(path, sizeof path, "%s/%s%s", dirs[d], name, exts[e]);
      struct stat st;
      if (stat(path, &st) == 0 && S_ISREG(st.st_mode)) return path;
    }
  die("core '%s' not found (give a path, or put NAME_libretro.* in $NDSREF_CORES "
      "or ~/.cache/dingbat-nds/cores)", name);
  return NULL;
}

/* ---------------------------------------------------------------- main */

static void usage(void) {
  fprintf(errf,
    "usage: ndsref --core CORE ROM [options]\n"
    "  --core PATH|NAME   a libretro core (NAME: NAME_libretro.* in $NDSREF_CORES\n"
    "                     or ~/.cache/dingbat-nds/cores)\n"
    "  --frames N         frames to run (default 60)\n"
    "  --out PREFIX       writes PREFIX.png (last frame) and PREFIX_<F>.png (default ndsref_out)\n"
    "  --shots F1,F2,..   also write PREFIX_<F>.png after frame F\n"
    "  --press KEY@F[+D|-L],..  hold KEY (A B X Y L R START SELECT UP DOWN LEFT RIGHT,\n"
    "                     or TOUCH:x:y) from frame F for D frames (default 2)\n"
    "  --touch X:Y@F[+D|-L],..  stylus at bottom-screen pixel (X, Y)\n"
    "  --wav OUT.wav      all audio at the core's sample rate\n"
    "  --bios DIR         copy bios7.bin, bios9.bin, firmware.bin into the system dir\n"
    "  --sysfile NAME=PATH  copy PATH to <system dir>/NAME (any name the core wants)\n"
    "  --opt KEY=VALUE    set a core option (repeatable)\n"
    "  --opts-file FILE   KEY=VALUE lines (repeatable); CORE.opts next to the core\n"
    "                     is read first unless --no-core-opts\n"
    "  --list-opts        print the core's options (key, default, values) and exit\n"
    "  --layout auto|tb|bt|lr|rl  how the core's frame holds the two screens\n"
    "  --sram FILE        load the cart's save memory from FILE (not written back)\n"
    "  --slot2 FILE[,SAVE] load ROM plus a GBA ROM (and its save) through the\n"
    "                     core's two-cart subsystem (-v lists the subsystems)\n"
    "  --rumble-log       print every rumble strength change with its frame\n"
    "  --workdir DIR      system/ and save/ dirs here (default: a temp dir, removed)\n"
    "  --no-final         don't write PREFIX.png\n"
    "  --depth5           reduce PNG colour to 5 bits per channel, widened as ndsrun does\n"
    "  -v / -vv           core log, polled devices / every option read\n");
  exit(2);
}

int main(int argc, char **argv) {
  const char *core_arg = NULL, *rom = NULL, *outp = "ndsref_out", *wav = NULL,
             *bios = NULL, *workdir_arg = NULL;
  const char *sram = NULL, *slot2 = NULL;
  int frames = 60, list_opts = 0, no_final = 0, no_core_opts = 0;
  const char *cli_opts[128], *opt_files[16];
  int n_cli_opts = 0, n_opt_files = 0;
  outf = stdout;
  errf = stderr;
  int shots[1024], n_shots = 0;
  const char *sysfiles[64];
  int n_sysfiles = 0;

  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
#define NEXT() (i + 1 < argc ? argv[++i] : (usage(), (char *)NULL))
    if (!strcmp(a, "--core")) core_arg = NEXT();
    else if (!strcmp(a, "--frames")) frames = atoi(NEXT());
    else if (!strcmp(a, "--out")) outp = NEXT();
    else if (!strcmp(a, "--wav")) wav = NEXT();
    else if (!strcmp(a, "--sram")) sram = NEXT();
    else if (!strcmp(a, "--slot2")) slot2 = NEXT();
    else if (!strcmp(a, "--rumble-log")) rumble_log = 1;
    else if (!strcmp(a, "--bios")) bios = NEXT();
    else if (!strcmp(a, "--workdir")) workdir_arg = NEXT();
    else if (!strcmp(a, "--sysfile")) { if (n_sysfiles < 64) sysfiles[n_sysfiles++] = NEXT(); }
    else if (!strcmp(a, "--press")) parse_presses(NEXT(), 0);
    else if (!strcmp(a, "--touch")) parse_presses(NEXT(), 1);
    else if (!strcmp(a, "--list-opts")) list_opts = 1;
    else if (!strcmp(a, "--no-final")) no_final = 1;
    else if (!strcmp(a, "--depth5")) depth5 = 1;
    else if (!strcmp(a, "-v")) verbose = 1;
    else if (!strcmp(a, "-vv")) verbose = 2;
    else if (!strcmp(a, "--layout")) {
      const char *m = NEXT();
      const char *names[] = {"auto", "tb", "bt", "lr", "rl"};
      layout_mode = -1;
      for (int k = 0; k < 5; k++) if (!strcmp(m, names[k])) layout_mode = k;
      if (layout_mode < 0) usage();
    } else if (!strcmp(a, "--shots")) {
      char *s = strdup(NEXT()), *save = NULL;
      for (char *t = strtok_r(s, ",", &save); t && n_shots < 1024; t = strtok_r(NULL, ",", &save))
        shots[n_shots++] = atoi(t);
      free(s);
    } else if (!strcmp(a, "--opt")) {
      cli_opts[n_cli_opts++] = NEXT();
      if (n_cli_opts == 128) die("too many --opt");
    } else if (!strcmp(a, "--opts-file")) {
      opt_files[n_opt_files++] = NEXT();
      if (n_opt_files == 16) die("too many --opts-file");
    } else if (!strcmp(a, "--no-core-opts")) {
      no_core_opts = 1;
    } else if (!strcmp(a, "-h") || !strcmp(a, "--help")) usage();
    else if (a[0] == '-') die("unknown option %s", a);
    else rom = a;
  }
  if (!core_arg) usage();
  if (!rom && !list_opts) usage();

  const char *core_path = resolve_core(core_arg);
  /* option layers: CORE.opts beside the core, then --opts-file, then --opt */
  if (!no_core_opts) {
    char side[1200];
    snprintf(side, sizeof side, "%s", core_path);
    char *dot = strrchr(side, '.'), *slash = strrchr(side, '/');
    if (dot && (!slash || dot > slash)) *dot = 0;
    strncat(side, ".opts", sizeof side - strlen(side) - 1);
    if (load_opts_file(side)) fprintf(errf, "options: %s\n", side);
  }
  for (int k = 0; k < n_opt_files; k++)
    if (!load_opts_file(opt_files[k])) die("cannot read %s", opt_files[k]);
  for (int k = 0; k < n_cli_opts; k++) add_user_opt(cli_opts[k]);

  outf = fdopen(dup(1), "w");
  errf = fdopen(dup(2), "w");
  setvbuf(errf, NULL, _IONBF, 0);
  if (!verbose) {
    int nul = open("/dev/null", O_WRONLY);
    dup2(nul, 1);
    dup2(nul, 2);
    close(nul);
  }

  /* scratch dirs: never the user's own system/save dirs */
  int temp_workdir = workdir_arg == NULL;
  if (workdir_arg) {
    snprintf(workdir, sizeof workdir, "%s", workdir_arg);
    mkdirs(workdir);
  } else {
    const char *t = getenv("TMPDIR");
    snprintf(workdir, sizeof workdir, "%s/ndsref.XXXXXX", t && *t ? t : "/tmp");
    if (!mkdtemp(workdir)) die("mkdtemp failed");
  }
  snprintf(sysdir, sizeof sysdir, "%s/system", workdir);
  snprintf(savedir, sizeof savedir, "%s/save", workdir);
  mkdirs(sysdir);
  mkdirs(savedir);
  if (bios) {
    const char *names[] = {"bios7.bin", "bios9.bin", "firmware.bin"};
    for (int k = 0; k < 3; k++) {
      char from[1200], to[1200];
      snprintf(from, sizeof from, "%s/%s", bios, names[k]);
      snprintf(to, sizeof to, "%s/%s", sysdir, names[k]);
      if (!copy_file(from, to)) fprintf(errf, "ndsref: no %s in %s\n", names[k], bios);
    }
  }
  for (int k = 0; k < n_sysfiles; k++) {
    char name[1024], to[1200];
    snprintf(name, sizeof name, "%s", sysfiles[k]);
    char *eq = strchr(name, '=');
    if (!eq) die("--sysfile wants NAME=PATH");
    *eq = 0;
    snprintf(to, sizeof to, "%s/%s", sysdir, name);
    if (!copy_file(eq + 1, to)) die("cannot read %s", eq + 1);
  }

  void *lib = dlopen(core_path, RTLD_NOW | RTLD_LOCAL);
  if (!lib) die("dlopen %s: %s", core_path, dlerror());
#define SYM(name) __typeof__(&name) p_##name = (__typeof__(&name))dlsym(lib, #name); \
  if (!p_##name) die("core lacks " #name)
  SYM(retro_set_environment);
  SYM(retro_set_video_refresh);
  SYM(retro_set_audio_sample);
  SYM(retro_set_audio_sample_batch);
  SYM(retro_set_input_poll);
  SYM(retro_set_input_state);
  SYM(retro_init);
  SYM(retro_deinit);
  SYM(retro_get_system_info);
  SYM(retro_get_system_av_info);
  SYM(retro_set_controller_port_device);
  SYM(retro_load_game);
  SYM(retro_unload_game);
  SYM(retro_run);
  SYM(retro_get_memory_data);
  SYM(retro_get_memory_size);

  struct retro_system_info si = {0};
  p_retro_get_system_info(&si);
  fprintf(errf, "core: %s %s\n", si.library_name, si.library_version);

  p_retro_set_environment(environment);
  p_retro_set_video_refresh(video_refresh);
  p_retro_set_audio_sample(audio_sample);
  p_retro_set_audio_sample_batch(audio_batch);
  p_retro_set_input_poll(input_poll);
  p_retro_set_input_state(input_state);
  p_retro_init();

  int rc = 0;
  if (rom) {
    size_t len;
    uint8_t *data = read_file(rom, &len);
    char abs[4096];
    if (!realpath(rom, abs)) snprintf(abs, sizeof abs, "%s", rom);
    struct retro_game_info gi = {abs, data, len, NULL};
    if (slot2) {
      /* the first subsystem taking two or more files: DS ROM, GBA ROM,
         then (optional) the GBA save, in the core's declared order */
      __typeof__(&retro_load_game_special) p_special =
          (__typeof__(&retro_load_game_special))dlsym(lib, "retro_load_game_special");
      if (!p_special) die("core lacks retro_load_game_special");
      int k = 0;
      for (; k < n_subsys; k++) {
        if (verbose) {
          fprintf(errf, "subsystem %u '%s' (%s):", subsys[k].id, subsys[k].ident, subsys[k].desc);
          for (unsigned r = 0; r < subsys[k].num_roms; r++)
            fprintf(errf, " [%s%s .%s]", subsys[k].roms[r].desc,
                    subsys[k].roms[r].required ? "" : "?", subsys[k].roms[r].valid_extensions);
          fprintf(errf, "\n");
        }
        if (subsys[k].num_roms >= 2) break;
      }
      if (k == n_subsys) die("core declares no two-cart subsystem");
      char gpath[4096], spath[4096] = "";
      snprintf(gpath, sizeof gpath, "%s", slot2);
      char *comma = strchr(gpath, ',');
      if (comma) { *comma = 0; snprintf(spath, sizeof spath, "%s", comma + 1); }
      struct retro_game_info infos[3] = {{0}};
      size_t glen, slen = 0;
      uint8_t *gdata = read_file(gpath, &glen), *sdata = NULL;
      char gabs[4096], sabs[4096];
      if (!realpath(gpath, gabs)) snprintf(gabs, sizeof gabs, "%s", gpath);
      infos[0] = gi;
      infos[1] = (struct retro_game_info){gabs, gdata, glen, NULL};
      unsigned num = 2;
      if (spath[0] && subsys[k].num_roms >= 3) {
        sdata = read_file(spath, &slen);
        if (!realpath(spath, sabs)) snprintf(sabs, sizeof sabs, "%s", spath);
        infos[2] = (struct retro_game_info){sabs, sdata, slen, NULL};
        num = 3;
      }
      if (!p_special(subsys[k].id, infos, num)) die("core refused the %s subsystem", subsys[k].ident);
    } else if (!p_retro_load_game(&gi)) die("core refused to load %s", rom);
    p_retro_set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
    if (sram) {
      /* --sram: the cart's save memory starts as this file (read only; the
         run never writes it back) */
      size_t slen, cap = p_retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
      uint8_t *sd = read_file(sram, &slen), *dst = p_retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
      if (!dst || cap == 0) die("core exposes no save memory for --sram");
      memcpy(dst, sd, slen < cap ? slen : cap);
      fprintf(errf, "sram: %zu of %zu bytes from %s\n", slen < cap ? slen : cap, cap, sram);
      free(sd);
    }
    struct retro_system_av_info av = {0};
    p_retro_get_system_av_info(&av);
    sample_rate = av.timing.sample_rate;
    fps = av.timing.fps;
    fprintf(errf, "av: %ux%u (max %ux%u) %.6f fps, %.3f Hz audio\n",
            av.geometry.base_width, av.geometry.base_height, av.geometry.max_width,
            av.geometry.max_height, fps, sample_rate);
  }

  for (int i = 0; i < n_user_opts; i++)
    if (!user_opts[i].used && !opt_find(user_opts[i].key))
      fprintf(errf, "ndsref: warning: the core declared no option '%s'\n", user_opts[i].key);
  for (int i = 0; i < n_opts; i++)
    if (opts[i].user && opts[i].values[0]) {
      char pat[1024];
      snprintf(pat, sizeof pat, "|%s|", opts[i].values);
      char want[512];
      snprintf(want, sizeof want, "|%s|", opts[i].cur);
      if (!strstr(pat, want))
        fprintf(errf, "ndsref: warning: '%s' is not one of %s's values (%s)\n",
                opts[i].cur, opts[i].key, opts[i].values);
    }

  if (list_opts) {
    for (int i = 0; i < n_opts; i++)
      fprintf(outf, "%s = %s%s\n    values: %s\n    %s\n", opts[i].key, opts[i].cur,
             opts[i].user ? " (set)" : "", opts[i].values, opts[i].desc);
    goto done;
  }

  want_audio = wav != NULL;
  char prefix[2048];
  snprintf(prefix, sizeof prefix, "%s", outp);
  size_t pl = strlen(prefix);
  if (pl > 4 && !strcasecmp(prefix + pl - 4, ".png")) prefix[pl - 4] = 0;

  for (int f = 0; f < frames; f++) {
    cur_frame = f;
    apply_presses(f);
    if (frame_time_cb.callback)
      frame_time_cb.callback(frame_time_cb.reference ? frame_time_cb.reference
                                                     : (retro_usec_t)(1e6 / (fps ? fps : 60)));
    p_retro_run();
    for (int k = 0; k < n_shots; k++)
      if (shots[k] == f + 1) {
        char path[2100];
        snprintf(path, sizeof path, "%s_%d.png", prefix, f + 1);
        if (!dump_frame(path)) rc = 1;
      }
  }
  if (!no_final) {
    char path[2100];
    snprintf(path, sizeof path, "%s.png", prefix);
    if (!dump_frame(path)) rc = 1;
  }
  if (wav) {
    write_wav(wav);
    fprintf(outf, "audio: %zu frames at %.3f Hz -> %s\n", audio_len / 2, sample_rate, wav);
  }
  fprintf(outf, "frames=%d video=%ux%u fmt=%u frames_drawn=%d -> %s\n", frames, frame_w, frame_h,
         pixfmt, frames_seen, prefix);
  p_retro_unload_game();

done:
  p_retro_deinit();
  if (temp_workdir) nftw(workdir, rm_entry, 16, FTW_DEPTH | FTW_PHYS);
  fflush(outf);
  return rc;
}
