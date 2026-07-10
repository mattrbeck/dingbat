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

  switch("passL", "-s WASM=1 -s USE_SDL=2 -s EXPORTED_RUNTIME_METHODS=ccall,cwrap -s EXPORTED_FUNCTIONS=_main,_initFromEmscripten,_loop_tick,_setInput,_isStopped,_benchFrames,_getAudioBufferPtr,_getAudioBufferLen,_clearAudioBuffer,_wasm_state_size,_wasm_state_data,_wasm_load_state,_wasm_set_turbo,_malloc,_free -s EXPORT_ALL=1 -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 -s ENVIRONMENT=web -s MALLOC=emmalloc -O3 -o web/em.js")
