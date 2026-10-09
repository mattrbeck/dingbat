when defined(emscripten):
  --os:linux
  --cpu:wasm32
  --mm:arc
  --threads:off
  --cc:clang
  --clang.exe:emcc
  --clang.linkerexe:emcc
  --define:danger
  --define:test_harness   # keep nim.cfg's SDL/GL link flags out

  # MODULARIZE: the page calls createNdsCore() and gets its own Module, so
  # the DS core can sit beside em.js's global Module in the main app.
  switch("passL", "-s WASM=1 -s MODULARIZE=1 -s EXPORT_NAME=createNdsCore -s EXPORTED_RUNTIME_METHODS=UTF8ToString,HEAPU8 -s EXPORTED_FUNCTIONS=_main,_nds_rom_alloc,_nds_boot,_nds_reboot,_nds_unload,_nds_load,_nds_run_frame,_nds_frame_count,_nds_powered_off,_nds_fb555_top,_nds_fb555_bottom,_nds_fb_top,_nds_fb_bottom,_nds_set_button,_nds_set_touch,_nds_set_lid,_nds_push_mic,_nds_status,_nds_audio_frames,_nds_audio_ptr,_nds_audio_clear,_nds_save_size,_nds_save_ptr,_nds_save_dirty,_nds_save_clean,_nds_insert_slot2,_nds_slot2_save_len,_nds_slot2_save_ptr,_nds_slot2_save_dirty,_nds_rumble,_nds_firmware_len,_nds_firmware_ptr,_nds_firmware_dirty,_nds_firmware_clean,_nds_synth_firmware,_nds_state_size,_nds_state_plain_size,_nds_state_data,_nds_state_load,_nds_state_load_keep,_nds_state_error_kind,_nds_state_error,_nds_load_cheats,_nds_rewind_enable,_nds_rewind_pop,_nds_rewind_depth,_nds_rewind_bytes,_nds_rewind_scrub_generate,_nds_rewind_scrub_thumb_w,_nds_rewind_scrub_thumb_h,_nds_rewind_scrub_thumbs_ptr,_nds_rewind_scrub_seconds_ago,_nds_rewind_scrub_state_size,_nds_rewind_scrub_save_differs,_nds_rewind_commit,_nds_runahead,_nds_payload_take,_nds_payload_restore,_nds_payload_restore_checked,_malloc,_free -s ALLOW_MEMORY_GROWTH=1 -s MAXIMUM_MEMORY=4GB -s ENVIRONMENT=web -s MALLOC=emmalloc -O3 -o web/nds/nds.js")
