#!/usr/bin/env bash
# Build every test binary at once: nine independent `nim c` runs, and Nim's
# semantic pass is single-threaded per invocation.
#
# Each target gets its own --nimcache: Nim keys the default cache on the
# project name, and concurrent builds sharing one interleave writes.
# Do NOT add --parallelBuild:N — starving the C stage costs more than the
# oversubscription it avoids.
# -d:test_harness keeps nim.cfg from adding the GUI SDL2/OpenGL link flags,
# which resolve on a dev Mac but not on a runner. See tests/README.md.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"

nimcache_root="$root/.nimcache-tests"
log_dir="$root/.build-logs"
mkdir -p "$log_dir"

names=()
pids=()

# build <name> <output binary> <source> [extra nim flags...]
build() {
  local name=$1 out=$2 src=$3
  shift 3
  nim c --nimcache:"$nimcache_root/$name" -d:test_harness -d:release --path:src \
    "$@" -o:"$out" "$src" >"$log_dir/$name.log" 2>&1 &
  names+=("$name")
  pids+=($!)
}

build harness         dingbat_test                  tests/dingbat_test.nim
build runner          dingbat_test_runner           tests/dingbat_test_runner.nim --path:tests
build ppucomposite    dingbat_ppucomposite_test     tests/ppucomposite_test.nim
build ppubgunpack     dingbat_ppubgunpack_test      tests/ppubgunpack_test.nim
build ppuobjlist      dingbat_ppuobjlist_test       tests/ppuobjlist_test.nim
build savestatecompat dingbat_savestate_compat_test tests/savestate_compat_test.nim
build rewind          dingbat_rewind_test           tests/rewind_test.nim
build lcdresponse     dingbat_lcdresponse_test      tests/lcdresponse_test.nim
build savefooter      dingbat_savefooter_test       tests/savefooter_test.nim
build clipreplay      dingbat_clipreplay_test       tests/clip_replay_test.nim

# Wait on every build even after one fails so all broken targets are reported.
rc=0
for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    echo "::group::BUILD FAILED: ${names[$i]}"
    cat "$log_dir/${names[$i]}.log"
    echo "::endgroup::"
    rc=1
  fi
done

if [ "$rc" -eq 0 ]; then
  echo "built ${#names[@]} test binaries in ${SECONDS}s: ${names[*]}"
else
  echo "one or more test binaries failed to build (logs above)"
fi
exit "$rc"
