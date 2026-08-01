#!/usr/bin/env bash
#
# What a customer's very first command does, on the distributions they run.
#
#   tests/fresh-clone.sh
#
# A cloned repository has no compose/.env, and the guided installer reads
# settings before it writes any — which registry the image comes from, what
# version is pinned, what the address is. Every one of those goes through
# env_value.
#
# This runs on GNU sed, deliberately. Alpine's busybox sed is quiet about a
# missing file; GNU sed exits 2, `set -o pipefail` propagates it and `set -e`
# ends the script with no output whatsoever. The whole class of bug is invisible
# in an Alpine test container and fatal on the RHEL host a bank actually uses,
# so the test has to run where the customer does.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v docker >/dev/null 2>&1 || {
  printf '\n  SKIPPED: docker is not installed\n\n'
  exit 0
}

printf '\nfresh clone (no compose/.env)\n\n'

PASS=0
FAIL=0
report() {
  if [ "$2" = "0" ]; then
    printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %s — exit %s\n' "$1" "$2"; FAIL=$((FAIL + 1))
  fi
}

[ -f "${ROOT}/compose/.env" ] && {
  printf '  \033[31m✗\033[0m compose/.env exists here; this test needs a clean tree\n\n'
  exit 1
}

# Debian and RHEL: the two families every supported host belongs to.
for image in debian:12 redhat/ubi9-minimal; do
  printf '\n  %s\n' "${image}"

  # Each helper the installer calls before a configuration exists. Run under the
  # same flags the scripts set, so a silent abort is a failure here too.
  docker run --rm -v "${ROOT}:/w:ro" -w /w "${image}" /bin/bash -c '
    set -euo pipefail
    . scripts/lib.sh
    env_value TASKSENSE_VERSION >/dev/null
    env_value APP_URL >/dev/null
    registry_host >/dev/null
    health_url >/dev/null
    running_version >/dev/null
    have_registry_login ghcr.io || true
  ' >/dev/null 2>&1
  report "the helpers the installer calls before .env exists" "$?"

  # registry_host has to reach its default rather than dying on the way.
  actual="$(docker run --rm -v "${ROOT}:/w:ro" -w /w "${image}" /bin/bash -c '
    set -euo pipefail; . scripts/lib.sh; registry_host' 2>/dev/null)"
  if [ "${actual}" = "ghcr.io" ]; then
    printf '  \033[32m✓\033[0m registry defaults to ghcr.io\n'; PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m registry defaults to ghcr.io — got [%s]\n' "${actual}"; FAIL=$((FAIL + 1))
  fi

  # And the entry point itself answers instead of dying without a word.
  out="$(docker run --rm -v "${ROOT}:/w:ro" -w /w "${image}" ./tasksense status 2>&1)"
  if printf '%s' "${out}" | grep -q 'nothing is installed here'; then
    printf '  \033[32m✓\033[0m ./tasksense status explains itself\n'; PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m ./tasksense status said: %s\n' "${out:-<nothing at all>}"; FAIL=$((FAIL + 1))
  fi
done

printf '\n  %s passed, %s failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
