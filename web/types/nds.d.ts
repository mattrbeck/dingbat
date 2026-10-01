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
  _nds_fb_top(): number;
  _nds_fb_bottom(): number;
  _nds_set_button(id: number, pressed: number): void;
  _nds_set_touch(x: number, y: number, down: number): void;
  _nds_status(): number;
  _nds_audio_frames(): number;
  _nds_audio_ptr(): number;
  _nds_audio_clear(): void;
  _nds_save_size(): number;
  _nds_save_ptr(): number;
  _nds_save_dirty(): number;
  _nds_save_clean(): void;
  // Save states: built on another branch; absent from builds without them
  // (index.js "Nintendo DS" checks before use).
  _nds_state_size?: () => number;
  _nds_state_data?: () => number;
  _nds_state_load?: (ptr: number, len: number) => number;
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
