#!/usr/bin/env bash
# Run a command, retrying it on failure with exponential backoff.
#
# Everything CI fetches over the network is a coin flip we make dozens of times
# a day: nimble hitting github.com/gitlab.com for package tags (a gitlab 502
# failed a Windows build), choosenim, npm, playwright's browser download. Each
# is idempotent, so a retry is always safe and a single transient 5xx/timeout
# should never be a red build.
#
#   .github/scripts/retry.sh 3 npm ci
#   RETRY_DELAY=5 .github/scripts/retry.sh 5 curl -fsSL "$url" -o out
#
# The first argument is the attempt count; the rest is the command. Delay
# starts at RETRY_DELAY seconds (default 15) and doubles each attempt.
set -uo pipefail

tries=${1:?usage: retry.sh <attempts> <command>...}
shift
delay=${RETRY_DELAY:-15}

for ((attempt = 1; attempt <= tries; attempt++)); do
  "$@" && exit 0
  status=$?
  if ((attempt == tries)); then
    echo "::error::'$*' failed after $tries attempt(s) (exit $status)"
    exit "$status"
  fi
  echo "attempt $attempt/$tries of '$*' failed (exit $status); retrying in ${delay}s"
  sleep "$delay"
  delay=$((delay * 2))
done
