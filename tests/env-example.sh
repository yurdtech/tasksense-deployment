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
# schema, and the schema is in the image. So this asks the image — the version
# compose/.env.example pins. It needs that image, and skips loudly rather than
# quietly when it is not here and there is no GHCR_TOKEN to pull it with — a
# credential-gated test that silently passes is worse than no test.

set -uo pipefail

# shellcheck source=helpers/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/common.sh"

docker_usable || skip "no container daemon"

printf '\n.env.example against the application it configures\n\n'

IMAGE="$(app_test_image)" || skip "ghcr.io/yurdtech/tasksense:$(example_version) is not on this host and GHCR_TOKEN is not set.
  Sign in and set GHCR_TOKEN, or point at another build:  TASKSENSE_TEST_IMAGE=... tests/env-example.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

verdict() {  # verdict <name> <rc> <output>
  if [ "$2" = "0" ]; then printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  \033[31m✗\033[0m %s\n%s\n' "$1" "$(printf '%s' "$3" | sed 's/^/      /')"; FAIL=$((FAIL + 1)); fi
}

# The example with its <CHANGE_ME_…> values filled in, plus what compose
# supplies (the stack settings, and the MONGODB_URI it derives). Everything
# else exactly as shipped — the point is to catch a default that cannot be
# used, not to test our own filling-in.
stack_settings() {
  printf 'DEPLOYMENT_MODE=onprem\nNODE_ENV=production\nPORT=3000\n'
  printf 'MONGODB_URI=mongodb://placeholder:placeholder@mongo:27017/?authSource=admin\n'
  printf 'TMPDIR=/app/api/data/tmp\nMIGRATE_ON_BOOT=manual\n'
}
prepare() {
  fixture_env "$1"
  stack_settings >> "$1"
}

prepare "${WORK}/example.env"

# `oidc` with no issuer configured parses the whole environment and then does
# nothing, which makes it the cheapest way to ask "would this have started?".
out="$(docker run --rm --env-file "${WORK}/example.env" "${IMAGE}" node dist/probe/cli.js oidc 2>&1)"
rc=$?
case "${out}" in
  *"Invalid environment configuration"*|*"nvalid enum value"*) rc=1 ;;
esac
verdict "every value in .env.example is one the application accepts" "${rc}" "${out}"

# And the file the wizard writes, which is rendered from the example and so
# inherits anything wrong with it.
# The renderer needs bash 4; on a Mac's bash 3.2 it runs in bash:5 instead.
grep -v -e '^DEPLOYMENT_MODE=' -e '^NODE_ENV=' -e '^PORT=' -e '^MONGODB_URI=' -e '^TMPDIR=' -e '^MIGRATE_ON_BOOT=' \
  "${WORK}/example.env" > "${WORK}/answers.env"
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  TASKSENSE_ENV_FILE="${WORK}/answers.env" "${ROOT}/scripts/wizard/configure.sh" \
    --render-only "${WORK}/rendered.env" >/dev/null 2>&1
else
  docker run --rm --user "$(id -u):$(id -g)" -v "${ROOT}:/w:ro" -v "${WORK}:/out" -w /w \
    -e TASKSENSE_ENV_FILE=/out/answers.env bash:5 ./scripts/wizard/configure.sh --render-only /out/rendered.env >/dev/null 2>&1
fi
stack_settings >> "${WORK}/rendered.env"

out="$(docker run --rm --env-file "${WORK}/rendered.env" "${IMAGE}" node dist/probe/cli.js oidc 2>&1)"
rc=$?
case "${out}" in
  *"Invalid environment configuration"*|*"nvalid enum value"*) rc=1 ;;
esac
verdict "and so is everything in the file the wizard renders from it" "${rc}" "${out}"

finish
