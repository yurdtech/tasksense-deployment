#!/usr/bin/env bash
#
# Does .env.example actually work?
#
#   tests/env-example.sh
#
# It shipped `LOG_LEVEL=info`. The application's levels are verbose, debug, log,
# warn, error and fatal — there is no "info" — so the file we tell operators to
# copy produced a system that would not start, and the wizard, which renders
# from that file, produced the same. docs/04-CONFIGURATION.md had it right the
# whole time. Nothing compared the two.
#
# Nothing could have: the only authority on which values are valid is the
# schema, and the schema is in the image. So this asks the image. It needs a
# pull, and skips loudly rather than quietly when it cannot get one — a
# credential-gated test that silently passes is worse than no test.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${TASKSENSE_TEST_IMAGE:-ghcr.io/yurdtech/tasksense:1.0.0}"

command -v docker >/dev/null 2>&1 || { printf '\n  SKIPPED: docker is not installed\n\n'; exit 0; }

printf '\n.env.example against the application it configures\n\n'

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  if ! docker pull -q "${IMAGE}" >/dev/null 2>&1; then
    printf '  \033[33mSKIPPED\033[0m — %s is not available here.\n' "${IMAGE}"
    printf '  Sign in first:  docker login ghcr.io -u yurdtech\n'
    printf '  Or point at another build:  TASKSENSE_TEST_IMAGE=… tests/env-example.sh\n\n'
    exit 0
  fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0
check() {
  if [ "$2" = "0" ]; then printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  \033[31m✗\033[0m %s\n%s\n' "$1" "$(printf '%s' "$3" | sed 's/^/      /')"; FAIL=$((FAIL + 1)); fi
}

# The example, plus the six values it deliberately leaves for the operator and
# the four compose supplies. Everything else is exactly as shipped — the point
# is to catch a default that cannot be used, not to test our own filling-in.
prepare() {
  local out="$1"
  sed -e 's/^STORAGE_SECRET=$/STORAGE_SECRET=0123456789012345678901234567890123456789/' \
      -e 's/^MONGO_PASSWORD=$/MONGO_PASSWORD=012345678901234567890123/' \
      "${ROOT}/compose/.env.example" > "${out}"
  {
    printf 'DEPLOYMENT_MODE=onprem\n'
    printf 'NODE_ENV=production\n'
    printf 'PORT=3000\n'
    printf 'MONGODB_URI=mongodb://placeholder:placeholder@mongo:27017/?authSource=admin\n'
  } >> "${out}"
}

prepare "${WORK}/example.env"

# `oidc` with no issuer configured parses the whole environment and then does
# nothing, which makes it the cheapest way to ask "would this have started?".
out="$(docker run --rm --env-file "${WORK}/example.env" "${IMAGE}" node dist/probe/cli.js oidc 2>&1)"
rc=$?
case "${out}" in
  *"Invalid environment configuration"*|*"nvalid enum value"*) rc=1 ;;
esac
check "every value in .env.example is one the application accepts" "${rc}" "${out}"

# And the file the wizard writes, which is rendered from the example and so
# inherits anything wrong with it.
TASKSENSE_ENV_FILE="${WORK}/example.env" "${ROOT}/scripts/wizard/configure.sh" \
  --render-only "${WORK}/rendered.env" >/dev/null 2>&1
{
  printf 'DEPLOYMENT_MODE=onprem\nNODE_ENV=production\nPORT=3000\n'
  printf 'MONGODB_URI=mongodb://placeholder:placeholder@mongo:27017/?authSource=admin\n'
} >> "${WORK}/rendered.env"

out="$(docker run --rm --env-file "${WORK}/rendered.env" "${IMAGE}" node dist/probe/cli.js oidc 2>&1)"
rc=$?
case "${out}" in
  *"Invalid environment configuration"*|*"nvalid enum value"*) rc=1 ;;
esac
check "and so is everything in the file the wizard renders from it" "${rc}" "${out}"

printf '\n  %s passed, %s failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
