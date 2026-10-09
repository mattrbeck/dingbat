// Hand-written: the DS core's module (web/nds/nds.js, built MODULARIZE'd
// from src/dingbat_nds_wasm.nim; its exports are listed in
// src/dingbat_nds_wasm.nims). Not generated like em.d.ts: keep it in step
// with those two files by hand.

interface NdsCoreModule {
  HEAPU8: Uint8Array;
  UTF8ToString(ptr: number): string;
  _malloc(n: number): number;
  _free(p: number): void;
  _nds_rom_alloc(len: number): number;
  _nds_boot(b9: number, b9Len: number, b7: number, b7Len: number,
            fw: number, fwLen: number, save: number, saveLen: number): number;
  _nds_reboot(save: number, saveLen: number): number;
  _nds_unload(): void;
  _nds_load(rom: number, romLen: number, b9: number, b9Len: number,
            b7: number, b7Len: number, fw: number, fwLen: number): number;
  _nds_run_frame(): void;
  _nds_frame_count(): number;
  _nds_fb555_top(): number;
  _nds_fb555_bottom(): number;
  // HD 3D (docs/nds/hd3d.md): k = 1 (off) .. 4; the HD screens are
  // (256k x 192k) BGR555, 0 while off. Optional: an older core lacks them.
  _nds_set_hd?: (k: number) => void;
  _nds_hd_scale?: () => number;
  _nds_hd_fb555_top?: () => number;
  _nds_hd_fb555_bottom?: () => number;
  _nds_fb_top(): number;
  _nds_fb_bottom(): number;
  _nds_set_button(id: number, pressed: number): void;
  _nds_set_touch(x: number, y: number, down: number): void;
  // The hinge (1 closed, 0 open) and the microphone: `n` mono int16 samples
  // at `ptr`, `rate` Hz, queued behind what is queued (io/mic.nim). Optional:
  // the page still runs a build without them (no lid, no microphone).
  _nds_set_lid?: (closed: number) => void;
  _nds_push_mic?: (ptr: number, n: number, rate: number) => void;
  _nds_status(): number;
  _nds_audio_frames(): number;
  _nds_audio_ptr(): number;
  _nds_audio_clear(): void;
  _nds_save_size(): number;
  _nds_save_ptr(): number;
  _nds_save_dirty(): number;
  _nds_save_clean(): void;
  // Power-off (power manager register 0 bit 6): 1 once the program shut the
  // DS down; nds_reboot switches it on again. Optional, like the firmware
  // calls below: index.js "Nintendo DS" runs on a build without them.
  _nds_powered_off?: () => number;
  // The firmware flash (io/spi.nim): its length, where it is, whether the
  // program wrote it since nds_firmware_clean. nds_reboot keeps it.
  _nds_firmware_len?: () => number;
  _nds_firmware_ptr?: () => number;
  _nds_firmware_dirty?: () => number;
  _nds_firmware_clean?: () => void;
  // The built-in (synthesized) firmware, 256 KB at the returned pointer;
  // needs no core.
  _nds_synth_firmware?: () => number;
  // Save states (docs/nds/savestate.md); optional so index.js "Nintendo DS"
  // still runs on a build without them. nds_state_size(thumbnail) packs the
  // machine into a retained buffer (a 128x192 thumbnail trailer when
  // thumbnail != 0) and returns its length; nds_state_load returns 1 or 0.
  _nds_state_size?: (thumbnail?: number) => number;
  // The same image left plain (no thumbnail), for a worker to pack.
  _nds_state_plain_size?: () => number;
  _nds_state_data?: () => number;
  _nds_state_load?: (ptr: number, len: number) => number;
  _nds_state_load_keep?: (ptr: number, len: number, keepRewind: number) => number;
  _nds_state_error_kind?: () => number;
  _nds_state_error?: () => number;
  // Rewind, run-ahead and cheats (docs/nds/features.md); optional like the
  // states. nds_rewind_enable(on, capBytes; 0 = default) keeps a ring the
  // frames feed; nds_rewind_pop steps back 10 frames (1 = applied).
  // nds_runahead(n) runs n frames ahead of the last frame run and back,
  // and the screens show the future until the next frame (1 = done).
  // nds_load_cheats(utf8Ptr, len) replaces the list from .cht text and
  // returns the refused cheats as "name: why" lines.
  _nds_rewind_enable?: (on: number, capBytes: number) => void;
  _nds_rewind_pop?: () => number;
  _nds_rewind_depth?: () => number;
  _nds_rewind_bytes?: () => number;
  // The scrubber and Report a Bug's timeline: the GB/GBA core's
  // wasm_rewind_scrub_* / wasm_rewind_commit for the DS ring.
  _nds_rewind_scrub_generate?: (maxSamples: number) => number;
  _nds_rewind_scrub_thumb_w?: () => number;
  _nds_rewind_scrub_thumb_h?: () => number;
  _nds_rewind_scrub_thumbs_ptr?: () => number;
  _nds_rewind_scrub_seconds_ago?: (sample: number) => number;
  _nds_rewind_scrub_state_size?: (sample: number) => number;
  _nds_rewind_scrub_save_differs?: (sample: number) => number;
  _nds_rewind_commit?: (sample: number) => number;
  _nds_runahead?: (n: number) => number;
  _nds_load_cheats?: (ptr: number, len: number) => number;
  // The bare payload into a buffer and back (benches: what rewind and
  // run-ahead cost). take returns its length; restore 1 = ok.
  _nds_payload_take?: () => number;
  _nds_payload_restore?: () => number;
  _nds_payload_restore_checked?: () => number;
}

declare function createNdsCore(moduleArg?: {
  locateFile?: (path: string, prefix?: string) => string;
}): Promise<NdsCoreModule>;

interface Window {
  // web/serve.py --dev: cache-busting stamps for the wasm builds.
  DINGBAT_ASSET_V?: { em?: string; nds?: string };
  // Published from Module.onRuntimeInitialized: where the DS audio joins.
  appAudioOut?: () => { ctx: AudioContext; dest: AudioNode } | null;
  // Unpaced DS frame cost in ms (console / Playwright).
  ndsBench?: (frames?: number) => number | null;
}
