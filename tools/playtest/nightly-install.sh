#!/bin/bash
# Installs (or re-installs) the nightly suite's launchd agent: nightly.sh at
# 03:00 every day, from a detached checkout of origin/main in
# ~/.cache/dingbat-nightly/tree (a worktree of DINGBAT_REPO, default
# ~/code/dingbat). A Mac asleep at 03:00 runs it on waking.
#
#   tools/playtest/nightly-install.sh             install and load
#   tools/playtest/nightly-install.sh --remove    unload and delete the agent
set -e
LABEL=com.matt.dingbat-nightly
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
ROOT=${DINGBAT_NIGHTLY_HOME:-$HOME/.cache/dingbat-nightly}
REPO=${DINGBAT_REPO:-$HOME/code/dingbat}
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = --remove ]; then
  rm -f "$PLIST"
  echo "removed $LABEL (the checkout and results stay in $ROOT)"
  exit 0
fi
mkdir -p "$ROOT/logs"
git -C "$REPO" fetch -q origin main
[ -d "$ROOT/tree" ] || git -C "$REPO" worktree add -q --detach "$ROOT/tree" origin/main
git -C "$ROOT/tree" checkout -q -f --detach origin/main
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ROOT/tree/tools/playtest/nightly.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DINGBAT_NIGHTLY_HOME</key><string>$ROOT</string>
    <key>DINGBAT_REPO</key><string>$REPO</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$ROOT/logs/launchd.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/launchd.log</string>
  <key>WorkingDirectory</key><string>$ROOT</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL: 03:00 daily; summaries in $ROOT/YYYY-MM-DD.txt"
