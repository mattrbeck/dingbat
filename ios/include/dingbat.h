/*
 * C API of the dingbat emulator core for iOS (libdingbat.a).
 *
 * Implemented by src/dingbat_ios.nim + src/dingbat_ios_audio.c; built by
 * ios/build-core.sh. See src/dingbat_ios.nim for the full contracts.
 *
 * Threading: everything must be called from one thread (the app uses the
 * main thread), EXCEPT dingbat_audio_read / dingbat_audio_queued_frames /
 * dingbat_audio_sample_rate, which are realtime-safe and intended for the
 * CoreAudio render thread (AVAudioSourceNode render block).
 */

#ifndef DINGBAT_H
#define DINGBAT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Call before anything else (runs the Nim runtime init; repeat calls are
 * no-ops). */
void dingbat_init(void);

/* --- Loading --- */

/* Load a .gba/.gb/.gbc/.cgb/.sgb ROM from a writable path (battery save is
 * "<path minus extension>.sav" alongside). Optional BIOS/bootrom path or
 * NULL (GBA falls back to HLE BIOS). 0 = ok, -1 = missing, -2 = init failed. */
int dingbat_load_rom(const char *rom_path, const char *bios_path);

/* Persist ROM bytes to persist_path, then load from there. Adds -3 = write
 * failure to dingbat_load_rom's return codes. */
int dingbat_load_rom_bytes(const void *data, int len, const char *persist_path,
                           const char *bios_path);

/* Drop the core, flushing its battery save first unless flush is 0. */
void dingbat_unload(int flush);

/* Hard reset: flush battery save, reload the current ROM. 0 = ok. */
int dingbat_reset(void);

int dingbat_loaded(void);
int dingbat_is_gb(void);   /* 1 for the Game Boy core (GB or GBC) */
int dingbat_is_cgb(void);  /* 1 when that core runs in colour mode */

/* --- Options read at the next load/reset --- */
void dingbat_set_gba_bios_mode(int mode); /* 0 HLE, 1 real, 2 real boot + HLE SWIs */
void dingbat_set_gba_run_bios(int on);    /* show the boot intro (real BIOS) */
void dingbat_set_gb_model(int model);     /* 0 from header, 1 DMG, 2 CGB */
void dingbat_set_sgb(int on);             /* Super Game Boy for SGB carts */

/* --- Frames --- */

/* Run exactly one emulated frame (may block ~1ms in the audio-sync backstop
 * if called while dingbat_audio_ahead() is already 1). */
void dingbat_run_frame(void);

/* One frame with n frames of run-ahead (n <= 0 = dingbat_run_frame). */
void dingbat_run_frame_ahead(int n);

/* The picture to present: raw BGR555 (mask 0x7FFF), after the LCD response
 * when that is on. dingbat_fb_width() x dingbat_fb_height(). NULL with no
 * core. */
const uint16_t *dingbat_game_fb(void);

/* The core's own BGR555 framebuffer. */
const uint16_t *dingbat_framebuffer(void);

/* Colour-corrected RGBA8888 (bytes R,G,B,255) of the framebuffer, converted
 * on call (thumbnails, glow). NULL with no core. */
const uint32_t *dingbat_framebuffer_rgba(void);

int dingbat_fb_width(void);   /* 240 (GBA) or 160 (GB/GBC) */
int dingbat_fb_height(void);  /* 160 (GBA) or 144 (GB/GBC) */
int dingbat_out_width(void);  /* 256 with an SGB border, else fb width */
int dingbat_out_height(void); /* 224 with an SGB border, else fb height */

/* 1 when the last GBA frame was unchanged; the caller may skip the upload. */
int dingbat_frame_static(void);
int dingbat_panel_gbc(void);  /* 1 = CGB colour model, 0 = AGB */

/* --- Video --- */
void dingbat_set_color_correction(int on);
void dingbat_set_lcd_response(int on);
void dingbat_set_sgb_border(int on);
int dingbat_sgb_active(void);
int dingbat_sgb_border(void);              /* 1 = composite the border */
const uint16_t *dingbat_sgb_border_ptr(void); /* 256x224 BGR555, bit15 opaque */
int dingbat_sgb_border_gen(void);          /* bumps when the border changes */
int dingbat_sgb_backdrop(void);            /* BGR555 */

/* --- Input and sensors --- */

/* input_id: 0 UP, 1 DOWN, 2 LEFT, 3 RIGHT, 4 A, 5 B, 6 SELECT, 7 START,
 * 8 L, 9 R. pressed: 0/1. */
void dingbat_set_input(int input_id, int pressed);
int dingbat_is_stopped(void);    /* 1 while the GBA sleeps (Stop mode) */
int dingbat_rumble(void);        /* 1 while the cart's motor is on */
void dingbat_set_tilt(double x, double y);
int dingbat_cart_has_tilt(void); /* 0 none, 1 tilt, 2 gyro */
int dingbat_cart_has_camera(void);
int dingbat_camera_attach(void);           /* returns buffer length */
uint8_t *dingbat_camera_frame(void);       /* 128x120 luminance */
int dingbat_printer_poll(void);
int dingbat_printer_take(void);            /* height of a 160-wide print */
const uint8_t *dingbat_printer_take_ptr(void);

/* --- Saves --- */

/* Flush battery-backed save RAM to disk now (call on background/exit). */
void dingbat_flush_save(void);

/* --- Audio and speed --- */

/* volume 0..100 (+ mute flag); 100/unmuted is bit-identical passthrough. */
void dingbat_set_volume(int volume, int mute);
void dingbat_set_channel_mutes(int bits);
void dingbat_set_fast_forward(int enabled); /* nonzero: no audio-sync pacing */
void dingbat_set_turbo(int on);             /* 2x */
void dingbat_set_slowmo(int on);            /* 0.5x */
void dingbat_set_pitch_correct_ff(int on);
void dingbat_set_mp2k_hle(int on);          /* "Improve audio quality" */
void dingbat_set_fifo_interp(int on);
int dingbat_mp2k_available(void);
int dingbat_hle_audio_active(void);

/* 1 when queued audio is comfortably ahead of playback. Pacing contract:
 * each display tick, run frames while this returns 0 (bounded by a small
 * cap); the 32768 Hz audio clock then paces emulation to real time. */
int dingbat_audio_ahead(void);

/* --- Save states --- */

/* dingbat_state_size() serializes (with a thumbnail trailer) into a
 * retained buffer and returns its length (0 = no core); read it via
 * dingbat_state_data() before the next size call. dingbat_load_state()
 * returns 1 on success, 0 if the image was rejected (core untouched; why in
 * dingbat_state_error_kind: 1 not a state, 2 wrong core, 3 wrong ROM, 4 too
 * new, 5 truncated, 6 corrupt, 7 no file). */
int dingbat_state_size(void);
const void *dingbat_state_data(void);
int dingbat_load_state(const void *data, int len, int keep_rewind);
int dingbat_state_error_kind(void);
const char *dingbat_state_error(void);

/* --- Rewind --- */
void dingbat_set_rewind(int on, int cap_bytes);
int dingbat_rewind_pop(void);              /* 1 = stepped back */
int dingbat_rewind_scrub_generate(int max_samples);
int dingbat_rewind_scrub_thumb_w(void);
int dingbat_rewind_scrub_thumb_h(void);
const void *dingbat_rewind_scrub_thumbs(void); /* BGR555, w*h*2 per sample */
int dingbat_rewind_scrub_seconds_ago(int sample); /* tenths */
int dingbat_rewind_scrub_save_differs(int sample);
/* Sample's full .state image into the dingbat_state_data() buffer; its
 * length, 0 when gone. The live core is left as it was. */
int dingbat_rewind_scrub_state_size(int sample);
int dingbat_rewind_commit(int sample);

/* --- Cheats --- */
/* Replace the cheat list with .cht text; returns parse errors or "". */
const char *dingbat_load_cheats(const char *text);

/* --- Clips ("Clip that!") --- */
/* The core keeps a state each second and the inputs of every frame for the
 * last minute; a replay re-emulates a range of it exactly. */
void dingbat_set_clip_cap(int bytes);
int dingbat_clip_history_frames(void);
int dingbat_clip_scrub_generate(int max_samples);   /* newest first */
int dingbat_clip_scrub_thumb_w(void);
int dingbat_clip_scrub_thumb_h(void);
const void *dingbat_clip_scrub_thumbs(void);          /* BGR555 */
int dingbat_clip_scrub_frames_ago(int sample);
/* Arm a replay of [start_ago, end_ago) frames before now: frames it runs,
 * or 0. Step it with dingbat_clip_tick (frames left, -1 = done and the live
 * game is back); dingbat_clip_abort restores the live game early. */
int dingbat_clip_begin(int start_ago, int end_ago);
int dingbat_clip_tick(void);
void dingbat_clip_abort(void);

/* Audio routing: 0 play, 1 capture only, 2 drop, 3 play and capture. */
void dingbat_audio_set_mode(int mode);
int dingbat_audio_get_mode(void);
int dingbat_audio_capture_take(float *dst, int max_frames);
int dingbat_audio_captured_frames(void);
void dingbat_audio_capture_clear(void);

/* --- audio pull API (realtime-safe, see src/dingbat_ios_audio.c) --- */

/* Fill dst with up to max_frames interleaved float32 stereo frames at
 * dingbat_audio_sample_rate(); returns frames written (caller zero-fills the
 * remainder). Returns 0 while audio is paused or the ring is empty. */
int dingbat_audio_read(float *dst, int max_frames);

int dingbat_audio_queued_frames(void);
void dingbat_audio_clear(void);     /* main thread: drop queued audio */
int dingbat_audio_sample_rate(void); /* 32768 */

#ifdef __cplusplus
}
#endif

#endif /* DINGBAT_H */
