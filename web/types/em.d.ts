// GENERATED FILE — do not edit by hand.
// Produced by: node web/types/gen-emdts.mjs
// Source of truth: src/dingbat_wasm.nim ({.exportc.} procs).
// CI runs `node web/types/gen-emdts.mjs --check` to keep this in sync.

/**
 * The emscripten Module object for the non-modularized em.js build.
 * Wasm exports appear as optional `_name` members: they exist only after the
 * runtime has initialized, which is why the app code guards on them.
 * All boundary values are numbers (pointers/ints/floats); cstring parameters
 * are char pointers when called directly — use ccall to pass JS strings.
 */
interface EmscriptenModule {
  // --- emscripten runtime members used by the front-end ---
  canvas?: HTMLCanvasElement | null;
  memory?: WebAssembly.Memory;
  HEAPU8?: Uint8Array;
  calledRun?: boolean;
  onRuntimeInitialized?: () => void | Promise<void>;
  instantiateWasm?(
    imports: WebAssembly.Imports,
    successCallback: (instance: WebAssembly.Instance, module: WebAssembly.Module) => void
  ): object;
  ccall?(
    name: string,
    returnType: string | null,
    argTypes: string[],
    args: unknown[]
  ): any;
  cwrap?(name: string, returnType: string | null, argTypes: string[]): Function;
  UTF8ToString?(ptr: number): string;
  _malloc?(size: number): number;
  _free?(ptr: number): void;

  // --- wasm exports generated from src/dingbat_wasm.nim ---
  _netlink_set_speculative?(on: number): void;
  _wasm_set_color_correction?(on: number): void;
  _wasm_set_gb_renderer?(fifo: number): void;
  _wasm_set_gba_bios_mode?(mode: number): void;
  _wasm_set_gba_run_bios?(on: number): void;
  _wasm_set_lcd_response?(on: number): void;
  _wasm_set_mp2k_hle?(on: number): void;
  _wasm_set_fifo_interp?(on: number): void;
  _wasm_set_speed_mode?(on: number): void;
  _wasm_mp2k_available?(): number;
  _wasm_hle_audio_active?(): number;
  _wasm_game_fb_ptr?(): number;
  _wasm_game_fb_raw_ptr?(): number;
  _wasm_sgb_enable?(on: number): void;
  _wasm_sgb_active?(): number;
  _wasm_sgb_border?(): number;
  _wasm_sgb_border_show?(on: number): void;
  _wasm_sgb_border_ptr?(): number;
  _wasm_sgb_border_gen?(): number;
  _wasm_sgb_backdrop?(): number;
  _wasm_out_w?(): number;
  _wasm_out_h?(): number;
  _wasm_panel_gbc?(): number;
  _wasm_glow_sample?(gw: number, gh: number, remap: number, p0: number, p1: number, p2: number, p3: number): number;
  _wasm_fb_ptr?(): number;
  _appendAudioSample?(left: number, right: number): void;
  _getAudioBufferPtr?(): number;
  _getAudioBufferLen?(): number;
  _clearAudioBuffer?(): void;
  _wasm_state_size?(): number;
  _wasm_state_data?(): number;
  _wasm_set_turbo?(on: number): void;
  _wasm_set_slowmo?(on: number): void;
  _wasm_set_pitch_correct_ff?(on: number): void;
  _wasm_state_error?(): number;
  _wasm_state_error_kind?(): number;
  _wasm_load_state?(data: number, len: number, keepRewind: number): number;
  _benchFrames?(n: number): void;
  _isStopped?(): number;
  _wasm_rumble?(): number;
  _wasm_set_tilt?(x: number, y: number): void;
  _wasm_cart_has_tilt?(): number;
  _clip_begin?(seconds: number): number;
  _clip_tick?(): number;
  _clip_abort?(): void;
  _printer_log_len?(): number;
  _printer_log_ptr?(): number;
  _printer_disconnect?(): void;
  _printer_poll?(): number;
  _printer_take?(): number;
  _printer_take_ptr?(): number;
  _wasm_cart_has_camera?(): number;
  _wasm_camera_attach?(): number;
  _wasm_camera_frame_ptr?(): number;
  _setInput?(inputId: number, pressed: number): void;
  _setKeybindingForInput?(inputId: number, keycode: number): void;
  _setRewindCapBytes?(n: number): void;
  _setRewindEnabled?(on: number): void;
  _loop_tick?(): void;
  _runahead_tick?(n: number): void;
  _wasm_rewind_pop?(): number;
  _wasm_rewind_scrub_generate?(maxSamples: number): number;
  _wasm_rewind_scrub_count?(): number;
  _wasm_rewind_scrub_thumb_w?(): number;
  _wasm_rewind_scrub_thumb_h?(): number;
  _wasm_rewind_scrub_thumbs_ptr?(): number;
  _wasm_rewind_scrub_seconds_ago?(sample: number): number;
  _wasm_rewind_scrub_state_size?(sample: number): number;
  _wasm_rewind_scrub_save_differs?(sample: number): number;
  _wasm_rewind_commit?(sample: number): number;
  _link_exit?(): void;
  _link_init?(rom1_path: number, rom2_path: number): number;
  _link_tick?(): void;
  _link_fb_ptr?(player: number): number;
  _link_input?(player: number, inputId: number, pressed: number): void;
  _rollback_exit?(): void;
  _rollback_exit_to_single?(): number;
  _rollback_init?(rom1_path: number, rom2_path: number, localPlayer: number, epoch: number): number;
  _rollback_tick?(localBits: number): number;
  _rollback_feed?(frame: number, bits: number): void;
  _rollback_fb_ptr?(): number;
  _rollback_head?(): number;
  _rollback_confirmed?(): number;
  _rollback_load_state?(player: number, data: number, len: number): number;
  _rollback_dump_size?(player: number): number;
  _rollback_dump_data?(): number;
  _rollback_transfers?(): number;
  _load_cheats?(text: number): number;
  _initFromEmscripten?(rom_path: number): void;
  _netlink_init?(rom_path: number, is_host: number, allow_crc_mismatch: number): number;
  _gba_awaiting_link?(): number;
  _netlink_attach?(is_host: number, allow_crc_mismatch: number): number;
  _netlink_exit?(): void;
  _netlink_feed?(data: number, len: number): number;
  _netlink_drain?(buf: number, cap: number): number;
  _netlink_tick?(): number;
  _netlink_stalled?(): number;
  _netlink_peer_done?(): number;
  _netlink_crc_mismatch?(): number;
  _netlink_error_msg?(): number;
  _netlink_debug?(): number;
  _wasm_ew16?(offset: number): number;
}

declare var Module: EmscriptenModule;

/** Emscripten's in-memory filesystem (global in the non-modularized build). */
declare var FS: {
  open(path: string, flags: string): object;
  write(stream: object, buf: Uint8Array, offset: number, length: number, position?: number): number;
  close(stream: object): void;
  readFile(path: string): Uint8Array;
  unlink(path: string): void;
};
