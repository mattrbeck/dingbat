/*
 * C API of the dingbat emulator core for iOS (libdingbat.a).
 *
 * Implemented by src/dingbat_ios.nim + src/dingbat_ios_audio.c; built by
 * ios/build-core.sh. See src/dingbat_ios.nim for the full contracts.
 *
 * Systems: Game Boy / Game Boy Color, Game Boy Advance and Nintendo DS, one
 * core at a time, picked by the ROM loaded. A DS game goes through the same
 * calls (frames, picture, input, audio ring, states, battery file) plus the
 * dingbat_nds_* ones; what the DS core lacks (rewind, clips, cheats,
 * run-ahead, link, SGB, tilt, camera, printer, rumble, MP2K) is a no-op, 0
 * or a refusal for a DS game, never a touch of the last GB/GBA game.
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

/* Load a .gba/.gb/.gbc/.cgb/.sgb/.nds ROM from a writable path (battery save
 * is "<path minus extension>.sav" alongside). Optional BIOS/bootrom path or
 * NULL (GBA falls back to HLE BIOS; ignored for a DS game, see
 * dingbat_set_nds_bios). 0 = ok, -1 = missing, -2 = init failed (for a DS
 * game also: the header fails the DS checks).
 * The core is picked by the extension: .gb/.gbc/.cgb/.sgb the Game Boy
 * core, .gba the GBA core, .nds the DS core; a file of any other name is a
 * DS game when its header passes GBATEK's checks (logo CRC CF56h at 15Ch,
 * or the header CRC16 at 15Eh: the web's NdsUtil.looksLikeNdsRom), else a
 * GBA game. One core at a time: loading a game flushes and drops whatever
 * ran before (GB/GBA or DS), and the old core is gone before the new ROM is
 * read. A DS game's .sav goes into the card's chip by the DS rules
 * (docs/nds/saves.md: 512 B / 8K / 64K / 32K / 128K name the chip, other
 * sizes are fitted to the chip the game addresses, a .dsv footer is
 * stripped; a fitted or stripped file is rewritten at the next flush). A DS
 * game boots with the lid open, on the BIOS/firmware of dingbat_set_nds_bios
 * and the flash of dingbat_set_nds_flash_path. */
int dingbat_load_rom(const char *rom_path, const char *bios_path);

/* Persist ROM bytes to persist_path, then load from there. Adds -3 = write
 * failure to dingbat_load_rom's return codes. */
int dingbat_load_rom_bytes(const void *data, int len, const char *persist_path,
                           const char *bios_path);

/* Drop the core, flushing its battery save first unless flush is 0 (DS:
 * the .sav and the firmware flash, as dingbat_flush_save). */
void dingbat_unload(int flush);

/* Hard reset: flush battery save, reload the current ROM. 0 = ok.
 * A DS game reboots in place (the power switch): the ROM is not read again,
 * the BIOS is the one the game started with (a dingbat_set_nds_bios change
 * waits for the next load), the firmware flash is the running console's
 * (what the game wrote is kept), the chip starts from the .sav just
 * flushed, the lid is open. It also switches on a DS the game switched
 * off. */
int dingbat_reset(void);

int dingbat_loaded(void);
int dingbat_is_gb(void);   /* 1 for the Game Boy core (GB or GBC) */
int dingbat_is_cgb(void);  /* 1 when that core runs in colour mode */
int dingbat_is_nds(void);  /* 1 for the Nintendo DS core */

/* --- Options read at the next load/reset --- */
void dingbat_set_gba_bios_mode(int mode); /* 0 HLE, 1 real, 2 real boot + HLE SWIs */
void dingbat_set_gba_run_bios(int on);    /* show the boot intro (real BIOS) */
void dingbat_set_gb_model(int model);     /* 0 from header, 1 DMG, 2 CGB */
void dingbat_set_sgb(int on);             /* Super Game Boy for SGB carts */

/* Nintendo DS dumps: paths of bios9.bin (4 KB), bios7.bin (16 KB) and
 * firmware.bin (128/256/512 KB), each NULL (or a missing file) for the
 * built-in one: the HLE BIOS for that CPU, the synthesized firmware. Read
 * when the next DS game loads (dingbat_reset keeps the BIOS the game
 * started with). Only read, never written. */
void dingbat_set_nds_bios(const char *bios9, const char *bios7, const char *firmware);

/* Where this device's DS firmware flash is kept, or NULL for nowhere (what
 * a game writes then lasts until the game closes). A real DS's flash holds
 * the user settings (name, birthday, language, Nintendo WFC connections)
 * that a game or the DS menu writes, shared by every game: one file per
 * device, not per game (docs/nds/web.md "Firmware settings").
 * - Written by dingbat_flush_save, dingbat_unload(1), dingbat_reset and
 *   loading another game, when the game wrote the flash. The file is this
 *   API's own format (the image, then a short trailer naming the firmware
 *   it was written on): treat it as opaque. Deleting it (no DS game loaded)
 *   resets the console's settings.
 * - Read at each DS load, and used only when it was written on the same
 *   firmware: the same dump (by its contents) or the built-in one. On a
 *   dump the written image boots whole; the dump file itself stays as given,
 *   so another dump (or none) starts from its own settings. On the built-in
 *   firmware only the user area (the three Wi-Fi connections and both user
 *   settings copies) is laid over this build's synthesized image.
 * Set it before loading a DS game (it is read at the load). */
void dingbat_set_nds_flash_path(const char *path);

/* --- Frames --- */

/* Run exactly one emulated frame (may block ~1ms in the audio-sync backstop
 * if called while dingbat_audio_ahead() is already 1). */
void dingbat_run_frame(void);

/* One frame with n frames of run-ahead (n <= 0 = dingbat_run_frame). */
void dingbat_run_frame_ahead(int n);

/* The picture to present: raw BGR555 (mask 0x7FFF), after the LCD response
 * when that is on. dingbat_fb_width() x dingbat_fb_height(). NULL with no
 * core.
 * DS: one contiguous 256x384 buffer, the top screen (rows 0-191) over the
 * bottom, touch screen (rows 192-383), no gap: the shell splits and
 * arranges them. Copied from the core once per frame (and after a load,
 * reset or state load), so it holds still until the next of those. No LCD
 * response and no colour correction on the DS (its own panels; the web
 * applies neither): present the BGR555 straight. Switched off: black. */
const uint16_t *dingbat_game_fb(void);

/* The core's own BGR555 framebuffer (DS: the same 256x384 composite). */
const uint16_t *dingbat_framebuffer(void);

/* Colour-corrected RGBA8888 (bytes R,G,B,255) of the framebuffer, converted
 * on call (thumbnails, glow). NULL with no core. DS: the 256x384 composite,
 * converted straight (5 to 8 bits a channel, no correction). */
const uint32_t *dingbat_framebuffer_rgba(void);

/* DS only: the top screen alone, 256x192 RGBA8888 (R first, straight), for
 * the library picture (the web's is the top screen). Converted on call,
 * valid until the next call; NULL unless a DS game is loaded. */
const uint32_t *dingbat_nds_top_rgba(void);

int dingbat_fb_width(void);   /* 240 (GBA), 160 (GB/GBC) or 256 (DS) */
int dingbat_fb_height(void);  /* 160 (GBA), 144 (GB/GBC) or 384 (DS: both screens) */
/* Ambient glow: the composited picture point-sampled into gw x gh RGBA8888
 * (R first); remap 1 swaps the four DMG shades for p0..p3 (0xAABBGGRR).
 * DS: samples the 256x384 composite, straight colours, remap ignored. */
const uint32_t *dingbat_glow_sample(int gw, int gh, int remap,
                                    uint32_t p0, uint32_t p1, uint32_t p2, uint32_t p3);
int dingbat_out_width(void);  /* 256 with an SGB border, else fb width */
int dingbat_out_height(void); /* 224 with an SGB border, else fb height */

/* 1 when the last GBA frame was unchanged; the caller may skip the upload.
 * Always 0 for GB and DS games. */
int dingbat_frame_static(void);
int dingbat_panel_gbc(void);  /* 1 = CGB colour model, 0 = AGB (and DS) */

/* --- Video (colour correction and the LCD response model the GBA/GB
 * panels; a DS picture ignores both, the Super Game Boy calls return 0) --- */
void dingbat_set_color_correction(int on);
void dingbat_set_lcd_response(int on);
void dingbat_set_sgb_border(int on);
int dingbat_sgb_active(void);
int dingbat_sgb_border(void);              /* 1 = composite the border */
const uint16_t *dingbat_sgb_border_ptr(void); /* 256x224 BGR555, bit15 opaque */
int dingbat_sgb_border_gen(void);          /* bumps when the border changes */
int dingbat_sgb_backdrop(void);            /* BGR555 */

/* --- Input and sensors (tilt, camera and printer: GB/GBA carts only, all
 * 0 / no-ops for a DS game) --- */

/* input_id: 0 UP, 1 DOWN, 2 LEFT, 3 RIGHT, 4 A, 5 B, 6 SELECT, 7 START,
 * 8 L, 9 R; for a DS game also 10 X, 11 Y (ignored by the other cores).
 * pressed: 0/1. */
void dingbat_set_input(int input_id, int pressed);
/* 1 while the GBA sleeps (Stop mode) or the DS sleeps (the game's sleep
 * mode, which most games enter while the lid is shut). */
int dingbat_is_stopped(void);
int dingbat_rumble(void);        /* 1 while the cart's motor is on (DS: 0) */

/* DS stylus on the bottom screen: x 0..255, y 0..191 in that screen's own
 * pixels (clamped), down 1 while touching (call again as it moves), down 0
 * to lift. Ignored while the lid is closed (a closed console has no touch
 * screen to reach). No-op unless a DS game is loaded. */
void dingbat_nds_touch(int x, int y, int down);

/* DS hinge: closed 1 / open 0. Opening raises the ARM7's lid interrupt;
 * most games sleep while it is shut (dingbat_is_stopped 1; time and the
 * audio clock go on, silent). Closing lifts the stylus. Every DS boot
 * (load, reset) starts open and sets this back to open; a state load tells
 * the core the lid as last set here, not as the state had it. */
void dingbat_nds_set_lid(int closed);

/* DS microphone: n mono int16 samples at `rate` Hz, queued behind what is
 * queued; the core plays them out against emulated time and keeps at most
 * 250 ms. Push them about as fast as they are recorded, nothing while
 * paused. No-op unless a DS game is loaded. */
void dingbat_nds_push_mic(const int16_t *samples, int n, int rate);

/* 1 once the DS game switched the console off (power manager register 0
 * bit 6). Off: both screens black, no sound, frames change nothing (but
 * keep the audio clock running, so pacing holds), dingbat_state_size
 * returns 0; the battery and flash go out at the next flush as usual. Only
 * dingbat_reset (the web's Restart) or a load turns it back on. Check it
 * after frames run, a load, a reset and a state load. */
int dingbat_nds_powered_off(void);
void dingbat_set_tilt(double x, double y);
int dingbat_cart_has_tilt(void); /* 0 none, 1 tilt, 2 gyro */
int dingbat_cart_has_camera(void);
int dingbat_camera_attach(void);           /* returns buffer length */
uint8_t *dingbat_camera_frame(void);       /* 128x120 luminance */
int dingbat_printer_poll(void);
int dingbat_printer_take(void);            /* height of a 160-wide print */
const uint8_t *dingbat_printer_take_ptr(void);

/* --- Saves --- */

/* Flush battery-backed save RAM to disk now (call on background/exit). DS:
 * the card's chip to the .sav when the game wrote it, and the firmware
 * flash to dingbat_set_nds_flash_path's file when the game wrote that; a
 * chip the game has not touched writes nothing. */
void dingbat_flush_save(void);

/* --- Audio and speed --- */

/* Every core's sound goes into the one ring dingbat_audio_read drains. A
 * DS game's is the SPU's stereo at 32728 Hz (33513982 / 1024 = 32728.5,
 * rounded down to the nearest whole Hz; the reader's rate control covers
 * the rest), ~547 frames per video frame queued after each frame; the
 * GB/GBA cores' is 32768 Hz. The rate moves with the core: read
 * dingbat_audio_sample_rate() after each dingbat_load_rom and rebuild the
 * output format when it changed. */

/* volume 0..100 (+ mute flag); 100/unmuted is bit-identical passthrough. */
void dingbat_set_volume(int volume, int mute);
/* Bit i mutes channel i (GB/GBA PSG and FIFO channels); no effect on DS. */
void dingbat_set_channel_mutes(int bits);
void dingbat_set_fast_forward(int enabled); /* nonzero: no audio-sync pacing */
void dingbat_set_turbo(int on);             /* 2x */
void dingbat_set_slowmo(int on);            /* 0.5x */
void dingbat_set_pitch_correct_ff(int on);
void dingbat_set_mp2k_hle(int on);          /* "Improve audio quality" (GBA) */
void dingbat_set_fifo_interp(int on);       /* GBA */
int dingbat_mp2k_available(void);           /* GBA; 0 otherwise */
int dingbat_hle_audio_active(void);         /* GBA; 0 otherwise */

/* 1 when queued audio is comfortably ahead of playback. Pacing contract:
 * each display tick, run frames while this returns 0 (bounded by a small
 * cap); the audio clock (32768 Hz; DS 32728 Hz) then paces emulation to
 * real time (the DS's 59.83 frames a second). It holds for a DS that
 * sleeps or is switched off too: each frame then queues a frame of
 * silence. */
int dingbat_audio_ahead(void);

/* --- Save states --- */

/* dingbat_state_size() serializes (with a thumbnail trailer) into a
 * retained buffer and returns its length (0 = no core); read it via
 * dingbat_state_data() before the next size call. dingbat_load_state()
 * returns 1 on success, 0 if the image was rejected (core untouched; why in
 * dingbat_state_error_kind: 1 not a state, 2 wrong core, 3 wrong ROM, 4 too
 * new, 5 truncated, 6 corrupt, 7 no file, 8 incompatible: a DS state of
 * this game that this build cannot restore, from a build with another DS
 * state layout or made on the other BIOS, a dump vs the HLE one).
 * DS: the DS state format (docs/nds/savestate.md) in the same container;
 * its thumbnail trailer is both screens at half size, 128x192 BGR555, top
 * over bottom (read w and h from the trailer). A state carries the card's
 * chip, so loading one marks the battery dirty (written at the next flush,
 * as for GB/GBA). The size is 0 while the DS is switched off. A load keeps
 * the lid as dingbat_nds_set_lid last set it, and can switch an off DS on
 * (or a running one off: check dingbat_nds_powered_off). keep_rewind does
 * nothing for a DS game (no rewind). */
int dingbat_state_size(void);
const void *dingbat_state_data(void);
int dingbat_load_state(const void *data, int len, int keep_rewind);
int dingbat_state_error_kind(void);
const char *dingbat_state_error(void);

/* --- Rewind ---
 * GB/GBA only. For a DS game there is no ring: the on/off setting is kept
 * for the next GB/GBA game, pop, scrub and commit return 0. */
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
/* Replace the cheat list with .cht text; returns parse errors or "".
 * A DS game has no cheat engine: "" and nothing applied. */
const char *dingbat_load_cheats(const char *text);

/* --- Clips ("Clip that!") --- */
/* The core keeps a state each second and the inputs of every frame for the
 * last minute; a replay re-emulates a range of it exactly. GB/GBA only: a
 * DS game keeps no history (dingbat_clip_history_frames 0, the strip
 * empty, begin 0, tick -1). Run-ahead is GB/GBA only too:
 * dingbat_run_frame_ahead runs one plain frame for a DS game. */
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

/* Online link (input rollback): both players' cores run here, only inputs
 * cross the network. rom0 is the host's game, rom1 the guest's; this
 * player's own game at its real path so its battery save is the game's.
 * While a session runs its local core serves the picture, audio and save
 * calls; frames, input, states, rewind, cheats and reset refuse. GB/GBA
 * only: a DS ROM on either side is refused (0) before anything is touched,
 * so a running DS game keeps running. */
int dingbat_rollback_init(const char *rom0, const char *rom1, int local_player, double epoch);
int dingbat_rollback_load_state(int player, const void *data, int len);
int dingbat_rollback_tick(int local_bits);    /* frame to send, -1 = stalled */
void dingbat_rollback_feed(int frame, int bits);
int dingbat_rollback_active(void);
int dingbat_rollback_transfers(void);         /* cable activity counter */
void dingbat_rollback_exit(void);
int dingbat_rollback_exit_to_single(void);    /* keep playing, cable unplugged */
int dingbat_rollback_head(void);
int dingbat_rollback_confirmed(void);
/* Debug: core `player`'s full state (desync checks); data valid until the next call. */
int dingbat_rollback_dump_size(int player);
const void *dingbat_rollback_dump_data(void);

/* Local 2P: two cores of one ROM on the cable. Player 1 on rom0 (the
 * game's own file: its save, its sound), player 2 on rom1 (its own .sav,
 * silent). Player 1's picture is dingbat_game_fb(); while it runs, solo
 * frames, input, states, rewind, cheats and reset refuse. GB/GBA only: a
 * DS ROM is refused (0) with nothing touched. */
int dingbat_link_init(const char *rom0, const char *rom1);
void dingbat_link_tick(void);
const uint16_t *dingbat_link_fb(int player);
const uint32_t *dingbat_link_rgba(int player);   /* colour-corrected, R first */
void dingbat_link_input(int player, int input_id, int pressed);
int dingbat_link_active(void);
void dingbat_link_flush_saves(void);
void dingbat_link_exit(void);

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
/* Fast-forward: play the ring as it comes, no rate control. Main thread. */
void dingbat_audio_set_free(int on);
/* The audio ring's target depth in frames at 32768 Hz (default 832, ~25 ms;
 * the same count serves the DS's 32728 Hz). */
void dingbat_audio_set_target(int frames);
int dingbat_audio_underruns(void);  /* times the reader ran dry (diagnostics) */
void dingbat_audio_clear(void);     /* main thread: drop queued audio */
int dingbat_audio_sample_rate(void); /* 32768; 32728 after a DS game loads */

#ifdef __cplusplus
}
#endif

#endif /* DINGBAT_H */
