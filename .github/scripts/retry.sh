#!/usr/bin/env bash
# Run a command, retrying on failure with exponential backoff. For idempotent
# network fetches only (nimble, choosenim, npm, playwright).
#
#   .github/scripts/retry.sh 3 npm ci
#   RETRY_DELAY=5 .github/scripts/retry.sh 5 curl -fsSL "$url" -o out
#
# First argument is the attempt count; delay starts at RETRY_DELAY seconds
# (default 15) and doubles each attempt.
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
