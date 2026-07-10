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

/* Call once before anything else (runs the Nim runtime init). */
void dingbat_init(void);

/* Load a .gba/.gb/.gbc ROM from a writable path (battery save is created as
 * "<path minus extension>.sav" alongside). Optional BIOS/bootrom path or
 * NULL (GBA falls back to HLE BIOS). 0 = ok, -1 = missing, -2 = init failed. */
int dingbat_load_rom(const char *rom_path, const char *bios_path);

/* Persist ROM bytes to persist_path, then load from there. Adds -3 = write
 * failure to dingbat_load_rom's return codes. */
int dingbat_load_rom_bytes(const void *data, int len, const char *persist_path,
                           const char *bios_path);

/* Hard reset: flush battery save, reload the current ROM. 0 = ok. */
int dingbat_reset(void);

/* Run exactly one emulated frame (may block ~1ms in the audio-sync backstop
 * if called while dingbat_audio_ahead() is already 1). */
void dingbat_run_frame(void);

/* Raw BGR555 framebuffer, dingbat_fb_width() x dingbat_fb_height().
 * NULL when no ROM is loaded. */
const uint16_t *dingbat_framebuffer(void);

/* Color-corrected RGBA8888 (bytes: R,G,B,255) conversion of the framebuffer,
 * computed on call. NULL when no ROM is loaded. */
const uint32_t *dingbat_framebuffer_rgba(void);

int dingbat_fb_width(void);   /* 240 (GBA) or 160 (GB/GBC) */
int dingbat_fb_height(void);  /* 160 (GBA) or 144 (GB/GBC) */

/* 1 when the last GBA frame was unchanged; the caller may skip the upload. */
int dingbat_frame_static(void);

/* input_id: 0 UP, 1 DOWN, 2 LEFT, 3 RIGHT, 4 A, 5 B, 6 SELECT, 7 START,
 * 8 L, 9 R. pressed: 0/1. */
void dingbat_set_input(int input_id, int pressed);

/* 1 while the GBA is in Stop (sleep) mode. */
int dingbat_is_stopped(void);

/* Flush battery-backed save RAM to disk now (call on background/exit). */
void dingbat_flush_save(void);

/* volume 0..100 (+ mute flag); 100/unmuted is bit-identical passthrough. */
void dingbat_set_volume(int volume, int mute);

/* Nonzero disables audio-sync pacing for fast-forward. */
void dingbat_set_fast_forward(int enabled);

/* 1 when queued audio is comfortably ahead of playback. Pacing contract:
 * each display tick, run frames while this returns 0 (bounded by a small
 * cap); the 32768 Hz audio clock then paces emulation to real time. */
int dingbat_audio_ahead(void);

/* Save states: dingbat_state_size() serializes into a retained buffer and
 * returns its length (0 = no core); read it via dingbat_state_data() before
 * the next size call. dingbat_load_state() returns 1 on success, 0 if the
 * image was rejected (core untouched). */
int dingbat_state_size(void);
const void *dingbat_state_data(void);
int dingbat_load_state(const void *data, int len);

/* --- audio pull API (realtime-safe, see src/dingbat_ios_audio.c) --- */

/* Fill dst with up to max_frames interleaved float32 stereo frames at
 * dingbat_audio_sample_rate(); returns frames written (caller zero-fills the
 * remainder). Returns 0 while audio is paused or the ring is empty. */
int dingbat_audio_read(float *dst, int max_frames);

int dingbat_audio_queued_frames(void);
int dingbat_audio_sample_rate(void); /* 32768 */

#ifdef __cplusplus
}
#endif

#endif /* DINGBAT_H */
