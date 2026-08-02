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

# A tick is three bytes. Printed to a terminal that is not in a UTF-8 locale it
# comes out as three replacement characters, which is how "✓ healthy" becomes
# "??? healthy" over a serial console or an ssh session that carried LC_ALL=C —
# both ordinary inside a bank. Adopt a UTF-8 locale if the host has one; use
# ASCII if it does not, rather than printing rubbish either way.
if ! printf '%s' "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" | grep -qi 'utf-\{0,1\}8'; then
  if locale -a 2>/dev/null | grep -qi '^C\.utf-\{0,1\}8$'; then
    LC_ALL=C.UTF-8
    export LC_ALL
  fi
fi
# shellcheck disable=SC2034  # UI_UTF8 and MARK_BAD are read by ui.sh
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]*) UI_UTF8=1; MARK_OK="✓"; MARK_BAD="✗" ;;
  *)              UI_UTF8=0; MARK_OK="+"; MARK_BAD="x" ;;
esac
# TASKSENSE_ASCII=1 forces it, for a terminal that claims UTF-8 and is lying —
# some emulators reached over a bank's jump host do.
if [ "${TASKSENSE_ASCII:-0}" = "1" ]; then
  # shellcheck disable=SC2034  # read by ui.sh
  UI_UTF8=0
  MARK_OK="+"
  # shellcheck disable=SC2034  # read by ui.sh
  MARK_BAD="x"
fi

info()  { printf '%s\n' "$*"; }
step()  { printf '\n%s==>%s %s%s%s\n' "$C_BOLD" "$C_OFF" "$C_BOLD" "$*" "$C_OFF"; }
ok()    { printf '  %s%s%s %s\n' "$C_GREEN" "$MARK_OK" "$C_OFF" "$*"; }
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

# Is the database somebody else's?
#
# MONGODB_URI set in .env means an existing cluster — a replica set, a managed
# service, a DBA's server. The bundled container is then not wanted, and
# starting it anyway leaves a database running that nobody asked for, that
# nothing writes to, and that appears in every `docker ps` a security review
# runs.
external_database() {
  [ -n "$(env_value MONGODB_URI)" ]
}

# Bring the stack up, without the bundled database when it is not wanted.
#
# `--no-deps app` rather than a profile or a scale.
#
# A profile cannot express it: `depends_on: mongo` makes compose reject the whole
# project when the profiled service is disabled — "service app depends on
# undefined service mongo: invalid compose project".
#
# `--scale mongo=0` looked like the answer and is not portable. It works on
# Docker Desktop's compose and is ignored by the one on GitHub's runners, which
# started the database anyway; a customer's older compose would have done the
# same, and the symptom is the quiet one — an unwanted database running beside
# the cluster they told us to use.
#
# `--no-deps app` names what to start rather than what to leave out. It predates
# both of the above and does not depend on how a version treats a dependency it
# has been told to skip. If the stack ever gains a second service that belongs
# with the application, it has to be named here too.
compose_up() {
  if external_database; then
    compose up -d --no-deps app
  else
    compose up -d
  fi
}

# ── Registry access ──────────────────────────────────────────────────────────

# Where to ask for a registry token.
SUPPORT_EMAIL="${SUPPORT_EMAIL:-info@meiksense.io}"

# The account the tokens we issue belong to.
#
# GHCR authenticates the token and ignores the username entirely — verified:
# `docker login ghcr.io -u definitely-not-a-real-account` with a valid token
# succeeds and the pull works, while a valid username with a bad token gets
# `denied: denied`. So this is a default to save typing, not a credential.
REGISTRY_ACCOUNT="${REGISTRY_ACCOUNT:-yurdtech}"

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
        "  echo \"\$TASKSENSE_REGISTRY_TOKEN\" | ${RUNTIME} login ${host} -u ${REGISTRY_ACCOUNT} --password-stdin"
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

  # Defaulted, because it is not a credential and getting it "wrong" cannot
  # fail. Asking for it as though it mattered invites somebody to type their own
  # GitHub login, get denied for an unrelated reason, and spend the next ten
  # minutes on the one field that has no effect.
  read -r -p "  Username [${REGISTRY_ACCOUNT}]: " username
  username="${username:-${REGISTRY_ACCOUNT}}"

  # Silent: a token pasted into a terminal ends up in scrollback, and from
  # there into a screenshot in a ticket.
  printf '  Token:    '
  read -rs token
  printf '\n\n'
  [ -n "${token}" ] || die "no token given" "Ask for one at ${SUPPORT_EMAIL}."

  if printf '%s' "${token}" | "${RUNTIME}" login "${host}" -u "${username}" --password-stdin >/dev/null 2>&1; then
    ok "signed in to ${host}"
    return 0
  fi

  # Only the token can be wrong. Naming the username here would send somebody to
  # check a field the registry never looks at.
  die "${host} rejected that token" \
      "Check it was copied whole — they are long, and a truncated one fails exactly like an expired one." \
      "If it has expired, ask for a replacement at ${SUPPORT_EMAIL}." \
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

  # A stored credential is not a working one.
  #
  # Signing in to ghcr.io only proves the token is a token. Whether it can read
  # *this* package is a separate question the registry does not answer until the
  # pull — so a mistyped or wrong-scope token gets "Login Succeeded", is written
  # to config.json, and then every later run reports the operator as signed in
  # while nothing they do works. Say what is actually known, and offer the way out.
  if have_registry_login "${host}"; then
    note "a credential for ${host} is already stored on this host"
    note "whether it can read this image only shows at the pull"
    if ! confirm "  Sign in again with a different token?"; then
      return 0
    fi
    "${RUNTIME}" logout "${host}" >/dev/null 2>&1 || true
  fi

  prompt_registry_login "${host}"
}

# ── State left by earlier installs ───────────────────────────────────────────

# The volume named in docker-compose.yml.
MONGO_VOLUME="${MONGO_VOLUME:-tasksense-mongo-data}"

# MongoDB writes MONGO_INITDB_ROOT_USERNAME and _PASSWORD exactly once: when it
# first creates its data directory. An existing volume keeps whatever it was
# created with, and a new password in .env is simply ignored — the application
# then starts, fails to authenticate, and says "Authentication failed" without
# mentioning that a volume is involved at all.
#
# Which is a fair description of what happens after any install that did not
# finish: the second attempt uses a new password against the first attempt's
# database, and the error names neither.
mongo_volume_exists() {
  # An external database has no volume of ours, and its credentials are not
  # ours to explain.
  external_database && return 1
  "${RUNTIME}" volume inspect "${MONGO_VOLUME}" >/dev/null 2>&1
}

# What to say about it. Separate from the check so install.sh can print it after
# the fact and the wizard can print it before.
explain_stale_mongo_volume() {
  cat >&2 <<EOF

  ${C_BOLD}A MongoDB volume from an earlier install is on this host.${C_OFF}

  MongoDB sets its username and password only when it first creates its data
  directory. ${MONGO_VOLUME} already exists, so it kept the credentials it was
  created with, and the ones in ${ENV_FILE} are ignored — which is why
  authentication fails with a password that is demonstrably in the file.

  If that database holds nothing you need — an install that did not finish,
  most often — remove it and start again:

    ${COMPOSE[*]:-docker compose} -f ${COMPOSE_DIR}/docker-compose.yml down -v

  ${C_DIM}-v is the part that matters: without it the volume survives and the
  next attempt fails the same way.${C_OFF}

  If it holds data you need, put the original password back in ${ENV_FILE}
  instead. See docs/10-TROUBLESHOOTING.md.

EOF
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
