#!/bin/bash
# The nightly playtest suite: every game in every configuration (--emus all,
# so the occasional dingbat-bios-nowl too) on origin/main, in its own
# detached checkout. launchd runs it at 03:00 (com.matt.dingbat-nightly,
# installed by nightly-install.sh); a full suite waits for the machine-wide
# playtest lock, so it never overlaps a train.
#
#   tools/playtest/nightly.sh [FILTER...]   FILTER: a subset (a quick check)
#
# State in ~/.cache/dingbat-nightly (DINGBAT_NIGHTLY_HOME): tree/ (the
# checkout), out/ (suites, runs; a week kept), logs/DAY.log, DAY.txt (the
# summary). A notification only when something needs a look: a waitloop
# exactness failure, a game that newly fails, or the run itself failing.
set -u
ROOT=${DINGBAT_NIGHTLY_HOME:-$HOME/.cache/dingbat-nightly}
REPO=${DINGBAT_REPO:-$HOME/code/dingbat}
TREE=$ROOT/tree
export PATH="$HOME/.nimble/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
DAY=$(date +%F)
mkdir -p "$ROOT/logs"
LOG=$ROOT/logs/$DAY.log

notify() {
  osascript -e "display notification \"$1\" with title \"dingbat nightly\"" >/dev/null 2>&1 || true
}

if [ -z "${NIGHTLY_UPDATED:-}" ]; then
  # bring the checkout to origin/main, then run main's copy of this script
  {
    echo "== $(date) updating $TREE"
    git -C "$REPO" fetch -q origin main &&
      { [ -d "$TREE" ] || git -C "$REPO" worktree add -q --detach "$TREE" origin/main; } &&
      git -C "$TREE" checkout -q -f --detach origin/main
  } >>"$LOG" 2>&1 || { notify "could not update the checkout: $LOG"; exit 1; }
  NIGHTLY_UPDATED=1 exec /bin/bash "$TREE/tools/playtest/nightly.sh" "$@"
fi

cd "$TREE" || exit 1
echo "== $(date) main $(git rev-parse --short HEAD)" >>"$LOG"
if ! NIMCACHE=$ROOT/nimcache bash tools/playtest/build.sh >>"$LOG" 2>&1; then
  notify "the drivers did not build: $LOG"
  exit 1
fi
TAG=$DAY
[ $# -gt 0 ] && TAG=$DAY-subset
nice -n 10 python3 tools/playtest/playtest.py --out "$ROOT/out" suite "$@" --emus all --jobs 6 --tag "$TAG" >>"$LOG" 2>&1
python3 tools/playtest/nightly.py "$ROOT/out/suites/$TAG" "$ROOT/out/suites" >"$ROOT/$TAG.txt" 2>>"$LOG"
case $? in
  0) ;;
  2) notify "$(head -1 "$ROOT/$TAG.txt") -- $ROOT/$TAG.txt" ;;
  *) notify "the summary failed: $LOG" ;;
esac
echo "== $(date) done: $ROOT/$TAG.txt" >>"$LOG"
# a week of runs and logs
find "$ROOT/out/runs" -mindepth 2 -maxdepth 2 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null
find "$ROOT/out/suites" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null
find "$ROOT/logs" "$ROOT" -maxdepth 1 -name '*.txt' -mtime +30 -delete 2>/dev/null
find "$ROOT/logs" -name '*.log' -mtime +30 -delete 2>/dev/null
exit 0
