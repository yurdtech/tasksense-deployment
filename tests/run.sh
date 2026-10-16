#!/usr/bin/env bash
#
# Everything, in order of how long it takes.
#
#   tests/run.sh
#
# Static analysis runs first: a syntax error makes every later failure a
# mystery. Then the offline suites — plain bash against a sandbox copy of the
# repository with a fake docker, runnable on a Mac's bash 3.2 with no daemon and
# no network. Then the ones that need a container daemon and cached images
# (bash:5, debian:12, redhat/ubi9-minimal, mongo:7), which skip themselves where
# they cannot run. Two need the application image and skip without it and
# without GHCR_TOKEN.

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

printf '\n\033[1m── bash -n\033[0m\n'
SYNTAX=0
for f in tasksense scripts/*.sh scripts/wizard/*.sh tests/*.sh tests/helpers/*.sh; do
  bash -n "${f}" || SYNTAX=1
done
if [ "${SYNTAX}" = "0" ]; then printf '  clean\n'; else FAILED+=("bash -n"); fi

# Offline: no daemon, no network.
run "lib helpers" ./tests/lib-helpers.sh
run "compose topologies" ./tests/compose-topologies.sh
run "preflight" ./tests/preflight-checks.sh
run "lifecycle" ./tests/lifecycle.sh
run "release tools" ./tests/release-tools.sh
run "draft" ./tests/draft.sh
run "external db" ./tests/external-db.sh

# A container daemon and cached base images.
run "fresh clone" ./tests/fresh-clone.sh
run "terminal" ./tests/terminal.sh
run "menu" ./tests/menu.sh
run "registry login" ./tests/registry-login.sh
run "renderer" ./tests/wizard-render.sh
run "stale volume" ./tests/stale-volume.sh
run "flow" ./tests/wizard-flow.sh

# The application image (or GHCR_TOKEN to pull it).
run ".env.example" ./tests/env-example.sh
run "mongo uri" ./tests/mongo-uri.sh

printf '\n'
if [ "${#FAILED[@]}" -gt 0 ]; then
  printf '\033[31mfailed: %s\033[0m\n\n' "${FAILED[*]}"
  exit 1
fi
printf '\033[32mall green\033[0m\n\n'
