# shellcheck shell=bash
#
# Shared by the suites in tests/. Sourced, never run.
#
# The suites that use `sandbox` run the real scripts against a copy of this
# repository in a temporary directory, with fake `docker`, `curl`, `cosign` and
# `skopeo` first on PATH. That makes them offline (no daemon, no registry, no
# network) and lets them run on a developer's Mac under bash 3.2 as well as in
# CI — and nothing they do can touch compose/.env, backups/ or a container on
# the machine running them.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
HELPERS="${TESTS_DIR}/helpers"

PASS=0
FAIL=0

check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  \033[31m✗\033[0m %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

contains() {  # contains <name> <needle> <haystack>
  if printf '%s' "$3" | grep -qF -- "$2"; then printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %s\n      wanted to see: %s\n' "$1" "$2"
    printf '%s\n' "$3" | tail -n 25 | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  fi
}

lacks() {  # lacks <name> <needle> <haystack>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    printf '  \033[31m✗\033[0m %s\n      should not contain: %s\n' "$1" "$2"
    printf '%s\n' "$3" | grep -F -- "$2" | head -n 5 | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  else printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); fi
}

finish() {
  printf '\n  %s passed, %s failed\n\n' "${PASS}" "${FAIL}"
  [ "${FAIL}" -eq 0 ]
}

skip() { printf '\n  \033[33mSKIPPED\033[0m %s\n\n' "$*"; exit 0; }

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1"; }

# The version this repository pins — what the release stamps into the example.
example_version() { sed -n 's/^TASKSENSE_VERSION=//p' "${ROOT}/compose/.env.example" | tail -n1; }

# bash 5 with openssl and coreutils — what the wizard needs and the stock
# bash:5 image lacks. Built once and reused: rebuilt only when missing (always,
# on a fresh CI runner) or when TASKSENSE_TEST_REBUILD=1, so a machine that has
# it runs the wizard suites without reaching any registry.
WIZARD_TEST_IMAGE=tasksense-wizard-test
wizard_test_image() {
  if [ -z "${TASKSENSE_TEST_REBUILD:-}" ] && docker image inspect "${WIZARD_TEST_IMAGE}" >/dev/null 2>&1; then
    return 0
  fi
  docker build -q -t "${WIZARD_TEST_IMAGE}" - >/dev/null <<'DOCKERFILE'
FROM bash:5
RUN apk add --no-cache openssl coreutils ncurses
DOCKERFILE
}

# The application image, without pulling it unless there is a credential to
# pull with: tests that need it skip rather than reach a registry they cannot
# read. The version is the one compose/.env.example pins.
app_test_image() {
  local image="${TASKSENSE_TEST_IMAGE:-ghcr.io/yurdtech/tasksense:$(example_version)}"
  if docker image inspect "${image}" >/dev/null 2>&1; then printf '%s' "${image}"; return 0; fi
  [ -n "${GHCR_TOKEN:-}" ] || return 1
  docker pull -q "${image}" >/dev/null 2>&1 || return 1
  printf '%s' "${image}"
}

# A daemon that answers, not just a CLI.
docker_usable() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
# The compose CLI alone — `config` needs no daemon.
compose_cli() { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }

# fixture_env <out> [KEY=VALUE | -KEY]…
#
# compose/.env.example with its <CHANGE_ME_…> values filled in, then each
# override applied where the example documents it: KEY=VALUE replaces an active
# line, uncomments a `#KEY=` one, or is appended; -KEY deletes the active line.
fixture_env() {
  local out="$1" kv; shift
  sed -e 's/<CHANGE_ME_STORAGE_SECRET>/0123456789abcdefghijABCDEFGHIJ0123456789/' \
      -e 's/<CHANGE_ME_MONGO_PASSWORD>/0123456789abcdef0123456789abcdef/' \
      -e 's#<CHANGE_ME_APP_URL>#https://tasksense.abb.internal#' \
      -e 's/<CHANGE_ME_ADMIN_EMAIL>/infra@abb.internal/' \
      -e 's/^HTTP_PORT=.*/HTTP_PORT=39317/' \
      "${ROOT}/compose/.env.example" > "${out}"
  for kv in "$@"; do
    case "${kv}" in
      -*) awk -v k="${kv#-}" 'index($0, k "=") != 1' "${out}" > "${out}.tmp" && mv "${out}.tmp" "${out}" ;;
      *)
        FIX_K="${kv%%=*}" FIX_V="${kv#*=}" awk '
          BEGIN { k = ENVIRON["FIX_K"]; v = ENVIRON["FIX_V"]; done = 0 }
          { lines[NR] = $0 }
          END {
            for (i = 1; i <= NR; i++) if (index(lines[i], k "=") == 1) { lines[i] = k "=" v; done = 1 }
            if (!done) for (i = 1; i <= NR; i++) if (index(lines[i], "#" k "=") == 1) { lines[i] = k "=" v; done = 1; break }
            for (i = 1; i <= NR; i++) print lines[i]
            if (!done) print k "=" v
          }' "${out}" > "${out}.tmp" && mv "${out}.tmp" "${out}" ;;
    esac
  done
  chmod 600 "${out}"
}

# sandbox <dir> — a copy of the deployment files with the fakes on PATH.
#
# Exports what the fakes read: FAKE_LOG (one line per docker call, its full
# argv — what `ps` would show), FAKE_REAL_DOCKER (the real CLI, for `compose
# config`, which needs no daemon), HOME (with a stored ghcr.io credential, so
# registry sign-in stays quiet), and the scripts' ASCII marks so assertions do
# not depend on the locale.
sandbox() {
  local dir="$1"
  FAKE_REAL_DOCKER="${FAKE_REAL_DOCKER:-$(command -v docker 2>/dev/null || true)}"
  mkdir -p "${dir}/repo" "${dir}/bin" "${dir}/home/.docker"
  cp -R "${ROOT}/scripts" "${ROOT}/compose" "${dir}/repo/"
  cp "${ROOT}/tasksense" "${dir}/repo/"
  rm -f "${dir}/repo/compose/.env" "${dir}/repo/compose/.env.bak" "${dir}/repo/compose/.env.draft"
  cp "${HELPERS}/fake-docker.sh" "${dir}/bin/docker"
  cp "${HELPERS}/fake-curl.sh" "${dir}/bin/curl"
  chmod +x "${dir}/bin/docker" "${dir}/bin/curl"
  printf '{"auths":{"ghcr.io":{"auth":"eXVyZHRlY2g6dG9rZW4="}}}' > "${dir}/home/.docker/config.json"
  # The real CLI finds its compose plugin under ~/.docker on Docker Desktop;
  # a new HOME would hide it from `compose config`.
  [ -d "${HOME}/.docker/cli-plugins" ] && ln -s "${HOME}/.docker/cli-plugins" "${dir}/home/.docker/cli-plugins"
  : > "${dir}/docker.log"
  SANDBOX="${dir}/repo"
  export SANDBOX FAKE_LOG="${dir}/docker.log" FAKE_REAL_DOCKER
  export HOME="${dir}/home" PATH="${dir}/bin:${PATH}"
  export TASKSENSE_ASCII=1 NO_COLOR=1 CONTAINER_RUNTIME=docker
  unset TASKSENSE_ENV_FILE
}

# Every docker call since the sandbox was made, one per line.
docker_calls() { cat "${FAKE_LOG}"; }
# Line number of the first call matching an extended regex (0 if none).
call_line() { local n; n="$(grep -nE -- "$1" "${FAKE_LOG}" | head -n1 | cut -d: -f1)"; printf '%s' "${n:-0}"; }
