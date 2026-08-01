#!/usr/bin/env bash
#
# Everything, in order of how long it takes.
#
#   tests/run.sh
#
# Static analysis runs first: a syntax error makes every later failure a
# mystery. Then the renderer, which needs nothing; then the flow, which needs a
# container and a pty and skips itself where it cannot run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}" || exit 1

FAILED=()

run() {
  printf '\n\033[1m── %s\033[0m\n' "$1"; shift
  "$@" || FAILED+=("$1")
}

if command -v shellcheck >/dev/null 2>&1; then
  printf '\n\033[1m── shellcheck\033[0m\n'
  # -P SCRIPTDIR so `source=../lib.sh` resolves from the script, not the caller.
  if shellcheck -x -P SCRIPTDIR tasksense scripts/*.sh scripts/wizard/*.sh tests/*.sh; then
    printf '  clean\n'
  else
    FAILED+=(shellcheck)
  fi
else
  printf '\n  shellcheck not installed — skipped\n'
fi

run "fresh clone" ./tests/fresh-clone.sh
run "terminal" ./tests/terminal.sh
run "menu" ./tests/menu.sh
run "registry login" ./tests/registry-login.sh
run "renderer" ./tests/wizard-render.sh
run "flow" ./tests/wizard-flow.sh

printf '\n'
if [ "${#FAILED[@]}" -gt 0 ]; then
  printf '\033[31mfailed: %s\033[0m\n\n' "${FAILED[*]}"
  exit 1
fi
printf '\033[32mall green\033[0m\n\n'
