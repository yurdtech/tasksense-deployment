#!/usr/bin/env bash
# Shared helpers. Sourced by every script here; not meant to be run directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_DIR="${ROOT_DIR}/compose"
ENV_FILE="${COMPOSE_DIR}/.env"

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

# ── Configuration ────────────────────────────────────────────────────────────
require_env_file() {
  [ -f "${ENV_FILE}" ] || die "no configuration at ${ENV_FILE}" \
    "cp ${COMPOSE_DIR}/.env.example ${ENV_FILE}" \
    "then edit it — the values marked REQUIRED have no defaults."
}

# Read one value out of .env without sourcing it: the file holds secrets that
# may contain characters the shell would interpret.
env_value() {
  local key="$1"
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
