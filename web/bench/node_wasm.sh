#!/bin/sh
# Build the headless bench harness (tests/dingbat_bench.nim) as wasm with the
# web build's flags (src/dingbat_wasm.nims: danger, arc, -O3, emmalloc) and
# run it under Node: the same V8 wasm engine as Chrome, as an ordinary
# foreground process (no headless-renderer QoS trap), with every
# DINGBAT_BENCH_* variable passed through to the harness.
#
#   web/bench/node_wasm.sh build <out.js> [nim flags...]   # from the repo root
#   DINGBAT_BENCH_STATE=scene.state node <out.js> rom.gba 1200 0
#
# Add --passL:--profiling-funcs to keep function names for `node --cpu-prof`.
# Throughput A/Bs: best of 5 or more, both builds interleaved, both orders.
set -e
[ "$1" = build ] || { echo "usage: $0 build <out.js> [nim flags...]"; exit 1; }
out=$2; shift 2
pre=$(mktemp -t node_wasm_pre)
# Emscripten's getenv reads its own ENV table, not process.env
printf 'Module.preRun = (Module.preRun || []).concat([function(){ for (var k in process.env) ENV[k] = process.env[k]; }]);\n' > "$pre"
nim c -d:emscripten -d:test_harness -d:danger --os:linux --cpu:wasm32 --mm:arc --threads:off \
  --cc:clang --clang.exe:emcc --clang.linkerexe:emcc --path:src \
  --nimcache:"$(dirname "$out")/nimcache_$(basename "$out" .js)" \
  --passL:"-s WASM=1 -s ENVIRONMENT=node -s NODERAWFS=1 -s ALLOW_MEMORY_GROWTH=1 -s STACK_SIZE=1048576 -s MALLOC=emmalloc -O3 --pre-js $pre" \
  "$@" -o:"$out" tests/dingbat_bench.nim
rm -f "$pre"
