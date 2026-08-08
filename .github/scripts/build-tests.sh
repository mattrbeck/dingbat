#!/usr/bin/env bash
# Build every test binary at once instead of one after another.
#
# These are eight independent `nim c` invocations over the same tree, and CI
# used to run them in series as separate steps. On the Windows runner that was
# ~145s of a ~250s job with three of the four cores idle the whole time: Nim's
# semantic pass is single-threaded per invocation, so the only way to use the
# rest of the machine is to run several compilers at once. Measured on an
# 8-core box: 52s in series, 26s together.
#
# Each target gets its OWN --nimcache. Nim keys the default cache on the
# project name, and two concurrent builds sharing a directory would interleave
# writes to the same generated C. (A shared cache is also NOT a shortcut worth
# taking for its own sake: pointing all five unit tests at one directory saved
# nothing measurable, because the per-project semantic pass — not the C
# compile — is what costs.)
#
# Do NOT add --parallelBuild:N to stop each compiler from also using every
# core. Measured, same box: default 26s, --parallelBuild:2 36s,
# --parallelBuild:1 42s. The C stage is a large enough share that starving it
# costs more than the oversubscription it avoids.
#
# -d:test_harness is what keeps nim.cfg from adding the GUI SDL2/OpenGL link
# flags, which are `-lGL` on Linux and a hardcoded mingw-cross path to
# libSDL2.a on Windows — neither exists on a GitHub runner, so without it these
# never link. They still link on a dev Mac (Homebrew SDL2), which is why that
# only ever fails in CI. See tests/README.md.
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

# Wait on every build even after one fails, so a run reports ALL the broken
# targets rather than whichever happened to be waited on first.
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
