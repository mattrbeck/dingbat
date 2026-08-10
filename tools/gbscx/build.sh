#!/bin/bash
# Builds BOTH test binaries into the worktree root, which is where the runner
# shells out to (getCurrentDir()/dingbat_test). Extra -d: flags are passed
# through, so `build.sh -d:gb_m3_len` builds an instrumented pair.
set -e
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$WORKTREE"
nim c -d:test_harness -d:release --path:src "$@" -o:dingbat_test tests/dingbat_test.nim
nim c -d:test_harness -d:release --path:src --path:tests "$@" -o:dingbat_test_runner tests/dingbat_test_runner.nim
echo "BUILD_OK $*"
