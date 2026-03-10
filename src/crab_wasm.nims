when defined(emscripten):
  --os:linux
  --cpu:wasm32
  --mm:arc
  --threads:off
  --cc:clang
  --clang.exe:emcc
  --clang.linkerexe:emcc
  --dynlibOverride:SDL2
  --opt:speed

  switch("passL", "-s WASM=1 -s USE_SDL=2 -s EXPORTED_RUNTIME_METHODS=ccall,cwrap -s EXPORTED_FUNCTIONS=_main,_initFromEmscripten,_loop_tick,_setInput,_getAudioBufferPtr,_getAudioBufferLen,_clearAudioBuffer -s EXPORT_ALL=1 -s ALLOW_MEMORY_GROWTH=1 -s ALLOW_TABLE_GROWTH=1 -s ENVIRONMENT=web -s MALLOC=emmalloc -O3 -o web/em.js")
