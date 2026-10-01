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

  switch("passL", "-s WASM=1 -s EXPORTED_RUNTIME_METHODS=ccall,cwrap,UTF8ToString,HEAPU8 -s EXPORTED_FUNCTIONS=_main,_nds_load,_nds_run_frame,_nds_fb_top,_nds_fb_bottom,_nds_set_button,_nds_set_touch,_nds_status,_malloc,_free -s ALLOW_MEMORY_GROWTH=1 -s ENVIRONMENT=web -s MALLOC=emmalloc -O3 -o web/nds/nds.js")
