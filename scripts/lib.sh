#!/usr/bin/env bash
# Shared helpers. Sourced by every script here; not meant to be run directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_DIR="${ROOT_DIR}/compose"
# TASKSENSE_ENV_FILE exists so the tests can point the configuration reader at a
# fixture. Nothing in normal operation sets it, and it is named for this project
# rather than something generic like ENV_FILE, which a stray export elsewhere in
# an operator's shell could collide with.
ENV_FILE="${TASKSENSE_ENV_FILE:-${COMPOSE_DIR}/.env}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_OFF=""
fi

info()  { printf '%s\n' "$*"; }
step()  { printf '\n%s==>%s %s%s%s\n' "$C_BOLD" "$C_OFF" "$C_BOLD" "$*" "$C_OFF"; }
ok()    { printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn()  { printf '  %s!%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
note()  { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

die() {
  printf '\n%serror:%s %s\n' "$C_RED" "$C_OFF" "$1" >&2
  shift
  # Remaining arguments are guidance: what the operator should do about it.
  for line in "$@"; do printf '       %s\n' "$line" >&2; done
  exit 1
}

confirm() {
  local prompt="$1" reply
  if [ "${ASSUME_YES:-0}" = "1" ]; then return 0; fi
  read -r -p "${prompt} [y/N] " reply
  [ "${reply}" = "y" ] || [ "${reply}" = "Y" ]
}

# ── Container runtime ────────────────────────────────────────────────────────
# Podman ships a compose-compatible CLI, and several banks forbid the Docker
# daemon outright, so accept either rather than assuming Docker.
detect_runtime() {
  if [ -n "${CONTAINER_RUNTIME:-}" ]; then
    RUNTIME="${CONTAINER_RUNTIME}"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME=docker
  elif command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
  else
    die "no container runtime found" \
        "Install Docker 24+ or Podman 4+, or set CONTAINER_RUNTIME."
  fi

  if "${RUNTIME}" compose version >/dev/null 2>&1; then
    COMPOSE=("${RUNTIME}" compose)
  elif command -v "${RUNTIME}-compose" >/dev/null 2>&1; then
    COMPOSE=("${RUNTIME}-compose")
  else
    die "${RUNTIME} has no compose support" \
        "Install the compose plugin (docker-compose-plugin / podman-compose)."
  fi
  export RUNTIME
}

# Run compose against this repo's stack, from any working directory.
compose() {
  ( cd "${COMPOSE_DIR}" && "${COMPOSE[@]}" "$@" )
}

# ── Registry access ──────────────────────────────────────────────────────────

# Where to ask for a registry token.
SUPPORT_EMAIL="${SUPPORT_EMAIL:-info@meiksense.io}"

# The registry the configured image comes from. An image mirrored into your own
# registry needs no token from us, so everything below skips.
registry_host() {
  local image
  image="$(env_value TASKSENSE_IMAGE 2>/dev/null)"
  image="${image:-ghcr.io/yurdtech/tasksense}"
  case "${image}" in
    */*/*) printf '%s' "${image%%/*}" ;;
    *) printf 'docker.io' ;;
  esac
}

# Whether a credential for this registry is already stored. Docker and Podman
# keep them in different files, and Podman falls back to Docker's.
have_registry_login() {
  local host="$1" file
  for file in "${HOME}/.docker/config.json" "${XDG_RUNTIME_DIR:-/run/user/$(id -u 2>/dev/null || echo 0)}/containers/auth.json"; do
    [ -f "${file}" ] || continue
    grep -q "\"${host}\"" "${file}" 2>/dev/null && return 0
  done
  return 1
}

# Asks for a token and signs in.
#
# The alternative — letting `pull` fail with `denied: denied` — is a poor first
# experience: it is the correct error for the wrong audience. Somebody
# installing this for the first time has been sent a token by email and has no
# reason to know that `docker login` is the missing step, or which of the three
# plausible usernames to use.
prompt_registry_login() {
  local host="$1" username token

  if [ ! -t 0 ]; then
    die "not signed in to ${host}, and there is no terminal to ask on" \
        "Sign in first, then run this again:" \
        "  echo \"\$TASKSENSE_REGISTRY_TOKEN\" | ${RUNTIME} login ${host} -u <username> --password-stdin"
  fi

  step "Registry access"
  cat <<EOF

  The TaskSense image is private. You need a registry token — it grants read
  access to this one package and nothing else.

  ${C_BOLD}Do not have one yet?${C_OFF}  Ask at ${C_BOLD}${SUPPORT_EMAIL}${C_OFF}
  Include the organisation the licence is for, and who should receive it.

  ${C_DIM}Already installed elsewhere? The same token works — it is per customer,
  not per machine.${C_OFF}

EOF

  read -r -p "  Username: " username
  [ -n "${username}" ] || die "no username given" "It is the account name sent with your token, not your own GitHub login."

  # Silent: a token pasted into a terminal ends up in scrollback, and from
  # there into a screenshot in a ticket.
  printf '  Token:    '
  read -rs token
  printf '\n\n'
  [ -n "${token}" ] || die "no token given" "Ask for one at ${SUPPORT_EMAIL}."

  if printf '%s' "${token}" | "${RUNTIME}" login "${host}" -u "${username}" --password-stdin >/dev/null 2>&1; then
    ok "signed in to ${host} as ${username}"
    return 0
  fi

  die "${host} rejected those credentials" \
      "The username is the account name sent with your token, not your own GitHub login." \
      "If the token has expired, ask for a replacement at ${SUPPORT_EMAIL}." \
      "See docs/13-REGISTRY-ACCESS.md."
}

# Called before pulling. Silent when a credential is already stored, or when the
# image comes from somewhere that does not need one.
ensure_registry_login() {
  local host
  host="$(registry_host)"

  # Only our registry needs a token. A mirrored image is the customer's own
  # problem to authenticate, and they have already done it if it works.
  if [ "${host}" != "ghcr.io" ]; then
    note "image comes from ${host} — no TaskSense token needed"
    return 0
  fi

  if have_registry_login "${host}"; then
    ok "already signed in to ${host}"
    return 0
  fi

  prompt_registry_login "${host}"
}

# ── Configuration ────────────────────────────────────────────────────────────
require_env_file() {
  [ -f "${ENV_FILE}" ] || die "no configuration at ${ENV_FILE}" \
    "cp ${COMPOSE_DIR}/.env.example ${ENV_FILE}" \
    "then edit it — the values marked REQUIRED have no defaults."
}

# Read one value out of .env without sourcing it: the file holds secrets that
# may contain characters the shell would interpret.
#
# An absent file is "nothing is configured", not an error — the guided installer
# asks about the image registry before any .env exists. Without this guard GNU
# sed exits 2 on the missing file, `set -o pipefail` propagates it, and `set -e`
# ends the script with no message at all. It survives on Alpine, whose busybox
# sed is quieter, which is exactly the kind of difference that reaches a
# customer's RHEL host and not our test container.
env_value() {
  local key="$1"
  [ -f "${ENV_FILE}" ] || return 0
  sed -n "s/^${key}=//p" "${ENV_FILE}" | tail -n1
}

require_env_values() {
  local key value missing=()
  for key in "$@"; do
    value="$(env_value "${key}")"
    [ -n "${value}" ] || missing+=("${key}")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "${ENV_FILE} is missing required values: ${missing[*]}" \
        "Each is described in the file itself and in docs/04-CONFIGURATION.md."
  fi
}

# ── Health ───────────────────────────────────────────────────────────────────
health_url() {
  local port bind
  port="$(env_value HTTP_PORT)"; port="${port:-3000}"
  bind="$(env_value BIND_ADDRESS)"; bind="${bind:-127.0.0.1}"
  # 0.0.0.0 is a bind address, not something you can connect to.
  [ "${bind}" = "0.0.0.0" ] && bind=127.0.0.1
  printf 'http://%s:%s/api/v1/health' "${bind}" "${port}"
}

# Poll until the application answers, or give up. Returns non-zero on timeout so
# the caller can decide whether that means "roll back" or "report and stop".
wait_for_health() {
  local timeout="${1:-180}" url elapsed=0
  url="$(health_url)"
  printf '  waiting for %s ' "${url}"
  while [ "${elapsed}" -lt "${timeout}" ]; do
    if curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; then
      printf '\n'; ok "healthy after ${elapsed}s"; return 0
    fi
    printf '.'; sleep 3; elapsed=$((elapsed + 3))
  done
  printf '\n'
  return 1
}

running_version() {
  local port bind
  port="$(env_value HTTP_PORT)"; port="${port:-3000}"
  bind="$(env_value BIND_ADDRESS)"; bind="${bind:-127.0.0.1}"
  [ "${bind}" = "0.0.0.0" ] && bind=127.0.0.1
  curl -fsS --max-time 5 "http://${bind}:${port}/api/v1/version" 2>/dev/null || true
}
