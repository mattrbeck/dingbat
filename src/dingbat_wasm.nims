when defined(emscripten):
  --os:linux
  --cpu:wasm32
  --mm:arc
  --threads:off
  --cc:clang
  --clang.exe:emcc
  --clang.linkerexe:emcc
  --dynlibOverride:SDL2
  --define:danger

  # STACK_SIZE: emcc's default shadow stack is 64KB; camera_capture alone
  # keeps ~120KB of sensor arrays on the stack (fine on native's 8MB), so a
  # Pocket Camera cart's first capture trapped the whole instance with
  # "memory access out of bounds". 1MB matches typical native headroom.
  switch("passL", "-s STACK_SIZE=1048576 -s WASM=1 -s USE_SDL=2 -s EXPORTED_RUNTIME_METHODS=ccall,cwrap,UTF8ToString -s EXPORTED_FUNCTIONS=_main,_initFromEmscripten,_loop_tick,_runahead_tick,_setInput,_isStopped,_benchFrames,_getAudioBufferPtr,_getAudioBufferLen,_clearAudioBuffer,_wasm_rumble,_wasm_state_size,_wasm_state_data,_wasm_load_state,_wasm_set_turbo,_wasm_set_slowmo,_wasm_set_pitch_correct_ff,_wasm_set_tilt,_wasm_cart_has_tilt,_clip_begin,_clip_tick,_clip_abort,_wasm_cart_has_camera,_wasm_camera_attach,_wasm_camera_frame_ptr,_printer_disconnect,_printer_poll,_printer_take,_printer_take_ptr,_printer_log_len,_printer_log_ptr,_wasm_set_color_correction,_wasm_set_gb_renderer,_wasm_set_gba_bios_mode,_wasm_set_gba_run_bios,_wasm_set_frame_blend,_wasm_set_mp2k_hle,_wasm_mp2k_available,_wasm_hle_audio_active,_wasm_fb_ptr,_wasm_game_fb_ptr,_wasm_panel_gbc,_wasm_rewind_pop,_wasm_rewind_scrub_generate,_wasm_rewind_scrub_count,_wasm_rewind_scrub_thumb_w,_wasm_rewind_scrub_thumb_h,_wasm_rewind_scrub_thumbs_ptr,_wasm_rewind_scrub_seconds_ago,_wasm_rewind_scrub_state_size,_setRewindCapBytes,_link_init,_link_exit,_link_tick,_link_fb_ptr,_link_input,_rollback_init,_rollback_exit,_rollback_exit_to_single,_rollback_tick,_rollback_feed,_rollback_fb_ptr,_rollback_head,_rollback_confirmed,_rollback_load_state,_rollback_transfers,_rollback_dump_size,_rollback_dump_data,_netlink_init,_netlink_set_speculative,_netlink_attach,_gba_awaiting_link,_netlink_exit,_netlink_tick,_netlink_feed,_netlink_drain,_netlink_stalled,_netlink_peer_done,_netlink_crc_mismatch,_netlink_error_msg,_netlink_debug,_wasm_ew16,_load_cheats,_malloc,_free -s EXPORT_ALL=1 -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 -s ENVIRONMENT=web -s MALLOC=emmalloc -O3 -o web/em.js")
