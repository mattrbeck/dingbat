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

  switch("passL", "-s WASM=1 -s USE_SDL=2 -s EXPORTED_RUNTIME_METHODS=ccall,cwrap,UTF8ToString -s EXPORTED_FUNCTIONS=_main,_initFromEmscripten,_loop_tick,_setInput,_isStopped,_benchFrames,_getAudioBufferPtr,_getAudioBufferLen,_clearAudioBuffer,_wasm_state_size,_wasm_state_data,_wasm_load_state,_wasm_set_turbo,_wasm_rewind_pop,_link_init,_link_exit,_link_tick,_link_fb_ptr,_link_input,_netlink_init,_netlink_attach,_gba_awaiting_link,_netlink_exit,_netlink_tick,_netlink_feed,_netlink_drain,_netlink_stalled,_netlink_peer_done,_netlink_crc_mismatch,_netlink_error_msg,_netlink_debug,_wasm_ew16,_malloc,_free -s EXPORT_ALL=1 -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 -s ENVIRONMENT=web -s MALLOC=emmalloc -O3 -o web/em.js")
