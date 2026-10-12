#!/bin/bash
# tools/ndswasm/build.sh OUTDIR NAME [nim flags...]: ndsrun as wasm
# (OUTDIR/ndsrun_NAME.{js,wasm}), built as the web DS core is (emcc -O3,
# -d:danger, emmalloc), for node (drive.mjs) and the browser (page.html):
# MEMFS, the driver writes the files in; Module.ndsrunHost gives the host
# counters. Run from the repository root.
out=$1; name=$2; shift 2
mkdir -p $out
nim c -d:emscripten -d:danger -d:test_harness --os:linux --cpu:wasm32 --mm:arc --threads:off \
  --cc:clang --clang.exe:emcc --clang.linkerexe:emcc --hints:off --warnings:off --path:src \
  --nimcache:$out/nimcache_$name -o:$out/ndsrun_$name.js --passC:-O3 \
  --passL:"-O3 -s WASM=1 -s MODULARIZE=1 -s EXPORT_NAME=createNdsrun -s INVOKE_RUN=0 -s FORCE_FILESYSTEM=1 -s EXPORTED_RUNTIME_METHODS=FS,callMain,ENV -s ALLOW_MEMORY_GROWTH=1 -s MAXIMUM_MEMORY=4GB -s STACK_SIZE=8MB -s ENVIRONMENT=web,node -s MALLOC=emmalloc -s EXIT_RUNTIME=1" \
  "$@" tools/ndsrun.nim
