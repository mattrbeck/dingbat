#!/usr/bin/env bash
# The nimble packages the Test Suite job needs, each installed from outside
# the checkout (inside it nimble resolves the whole project graph, the GUI
# packages with it) and each proven by importing it, with retries:
#   zippy   the harness and runner (zipped ROMs)
#   yaml    the desktop settings test (common/config.nim)
#   imguin  the desktop modal test (Dear ImGui, driven headless), the
#           version dingbat.nimble pins
# nimble has died partway on the Windows runner with a zero exit, so an
# attempt counts only once the import compiles.
#
# imguin's install failed with "Access is denied" on the Windows runner in
# July 2026 (d201f335b). There, and only there, a failed imguin is a warning
# that sets DINGBAT_NO_IMGUIN=1 for the later steps (build-tests.sh skips
# the modal test, test.yml skips its step); anywhere else it fails the job.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
scratch=${RUNNER_TEMP:-${TMPDIR:-/tmp}}

if [ "${1:-}" = --one ]; then
  # --one <package[@version]> <module>: one attempt, for retry.sh
  cd "$scratch" || exit 1
  nimble install -y "$2" || exit 1
  check="depcheck_${2%%@*}.nim"
  printf 'import %s\n' "$3" > "$check"
  nim check --hints:off "$check" || exit 1
  rm -f "$check"
  exit 0
fi

export RETRY_DELAY=${RETRY_DELAY:-10}
"$here/retry.sh" 3 bash "$0" --one zippy zippy/ziparchives || exit 1
"$here/retry.sh" 3 bash "$0" --one yaml yaml/tojson || exit 1
if "$here/retry.sh" 3 bash "$0" --one imguin@1.92.4.0 imguin/cimgui; then
  exit 0
fi
if [ "${RUNNER_OS:-}" = Windows ]; then
  echo "::warning::imguin did not install; the desktop modal test is skipped on this runner"
  echo "DINGBAT_NO_IMGUIN=1" >> "${GITHUB_ENV:-/dev/null}"
  exit 0
fi
exit 1
