#!/bin/bash
# Build and run a libFuzzer target of tests/fuzz/fuzz.nim.
#
#   tools/fuzz.sh <gbstate|gbastate|inflate|zip> [seconds] [libFuzzer args...]
#
# FUZZ_MODE=danger (the default) builds as the web build is, with no runtime
# checks, under AddressSanitizer: a read or write outside a buffer stops the
# run. FUZZ_MODE=release keeps Nim's checks, as iOS and the desktop have
# them: an index or range Defect stops the run.
#
# Needs a clang that ships libFuzzer (Apple's does not: Homebrew's llvm, or
# any Linux clang). The corpus is kept in $FUZZ_DIR/<target>-<mode>, seeded
# from the genuine states and streams the target writes itself; an input
# that stops a run is left in $FUZZ_DIR as crash-*, and one kept as a
# regression goes in tests/fuzz/regress/<target>/, which every run replays
# first.
set -euo pipefail
cd "$(dirname "$0")/.."

target=${1:?target: gbstate, gbastate, inflate or zip}
seconds=${2:-60}
shift; shift || true
mode=${FUZZ_MODE:-danger}
dir=${FUZZ_DIR:-.fuzz}

clang=${FUZZ_CLANG:-}
if [ -z "$clang" ]; then
  if [ -x /opt/homebrew/opt/llvm/bin/clang ]; then clang=/opt/homebrew/opt/llvm/bin/clang
  else clang=$(command -v clang); fi
fi

bin="$dir/fuzz_${target}_${mode}"
corpus="$dir/${target}-${mode}"
mkdir -p "$corpus" "$dir/nimcache"

nim c --cc:clang --clang.exe:"$clang" --clang.linkerexe:"$clang" \
  -d:"$mode" -d:useMalloc -d:noSignalHandler -d:test_harness \
  -d:fuzz_target="$target" --noMain:on --hints:off --warnings:off \
  --passC:"-fsanitize=fuzzer-no-link,address -g -fno-omit-frame-pointer" \
  --passL:"-fsanitize=fuzzer,address" \
  --path:src --nimcache:"$dir/nimcache/${target}-${mode}" \
  -o:"$bin" tests/fuzz/fuzz.nim

DINGBAT_FUZZ_SEEDS="$corpus" "$bin" -runs=0 -artifact_prefix="$dir/seedstep-" 2>/dev/null || true   # it exits from inside the fuzzer, which libFuzzer calls an error

regress="tests/fuzz/regress/$target"
if [ -d "$regress" ] && [ -n "$(ls -A "$regress")" ]; then
  "$bin" -rss_limit_mb=4096 "$regress"/*
fi

# A state is a few hundred KiB, and one cut short is refused at once:
# -len_control=0 mutates the seeds at their own length from the start. A
# hang is a finding too.
exec "$bin" -max_total_time="$seconds" -max_len=1048576 -len_control=0 -timeout=20 \
  -rss_limit_mb=4096 -artifact_prefix="$dir/" -print_final_stats=1 "$@" "$corpus"
