#!/usr/bin/env bash
# Shared helpers. Sourced by every script here; not meant to be run directly.
#
# Bash 3.2 compatible on purpose: the plain scripts run on an operator's Mac as
# well as on the server. No associative arrays, and every array that can be
# empty is expanded as ${a[@]+"${a[@]}"} — bash before 4.4 treats an empty
# "${a[@]}" as unbound under `set -u`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_DIR="${ROOT_DIR}/compose"
EXAMPLE_FILE="${COMPOSE_DIR}/.env.example"
# TASKSENSE_ENV_FILE points the scripts — and compose, which reads the same
# variable for `env_file:` — at a configuration kept somewhere else, such as
# /etc/tasksense/tasksense.env, or at a test fixture. Unset, it is compose/.env.
# Named for this project rather than something generic like ENV_FILE, which a
# stray export elsewhere in an operator's shell could collide with.
ENV_FILE="${TASKSENSE_ENV_FILE:-${COMPOSE_DIR}/.env}"
case "${ENV_FILE}" in /*) ;; *) ENV_FILE="${PWD}/${ENV_FILE}" ;; esac

# Fixed names from docker-compose.yml. Containers are addressed by name where
# compose's profile handling would get in the way (stopping a worker whose
# profile has just been switched off, for instance).
APP_CONTAINER=tasksense-app
WORKER_CONTAINER=tasksense-worker
MONGO_CONTAINER=tasksense-mongo
# shellcheck disable=SC2034  # read by preflight.sh
MIGRATE_CONTAINER=tasksense-migrate
# `name:` in docker-compose.yml — what Compose labels its containers with.
# shellcheck disable=SC2034  # read by preflight.sh
COMPOSE_PROJECT=tasksense
# shellcheck disable=SC2034  # read by backup.sh, restore.sh and the panel
APP_VOLUME="${APP_VOLUME:-tasksense-app-data}"
MONGO_VOLUME="${MONGO_VOLUME:-tasksense-mongo-data}"
DEFAULT_IMAGE=ghcr.io/yurdtech/tasksense

# Where upgrade.sh records what rollback.sh needs: line 1 the version it came
# from, line 2 `backup=<archive>` taken just before it. (Line 1 alone is the
# format 1.0 wrote, and is still read.)
STATE_FILE="${ROOT_DIR}/.previous-version"
BACKUPS_DIR="${ROOT_DIR}/backups"

# `depends_on: required: false` — what makes the bundled database optional —
# arrived in Docker Compose 2.20.
COMPOSE_MIN_VERSION=2.20.0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_OFF=""
fi

# A tick is three bytes. Printed to a terminal that is not in a UTF-8 locale it
# comes out as three replacement characters, which is how "✓ healthy" becomes
# "??? healthy" over a serial console or an ssh session that carried LC_ALL=C —
# both ordinary inside an enterprise network. Adopt a UTF-8 locale if the host has one; use
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
# some emulators reached over a corporate jump host do.
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

# A question whose safe answer is no. ASSUME_YES=1 (--yes) answers yes.
confirm() {
  local prompt="$1" reply
  if [ "${ASSUME_YES:-0}" = "1" ]; then return 0; fi
  [ -t 0 ] || return 1
  read -r -p "${prompt} [y/N] " reply
  [ "${reply}" = "y" ] || [ "${reply}" = "Y" ]
}

# A question whose safe answer is yes — restoring data after a failed
# upgrade, for instance. Enter, --yes and a missing terminal all mean yes.
confirm_yes() {
  local prompt="$1" reply
  if [ "${ASSUME_YES:-0}" = "1" ] || [ ! -t 0 ]; then return 0; fi
  read -r -p "${prompt} [Y/n] " reply
  case "${reply}" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
}

# ── Versions ─────────────────────────────────────────────────────────────────

semver_valid() {
  printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'
}

# version_cmp A B → prints -1, 0 or 1. Compares the numeric X.Y.Z only; a
# pre-release suffix sorts before its release (1.1.0-rc.1 < 1.1.0).
version_cmp() {
  local a="${1#v}" b="${2#v}" ai bi i
  local a_pre="" b_pre=""
  case "${a}" in *-*) a_pre="${a#*-}"; a="${a%%-*}" ;; esac
  case "${b}" in *-*) b_pre="${b#*-}"; b="${b%%-*}" ;; esac
  a="${a%%+*}"; b="${b%%+*}"
  for i in 1 2 3; do
    ai="$(printf '%s' "${a}" | cut -d. -f"${i}")"; ai="${ai:-0}"
    bi="$(printf '%s' "${b}" | cut -d. -f"${i}")"; bi="${bi:-0}"
    case "${ai}${bi}" in *[!0-9]*) ai=0; bi=0 ;; esac
    if [ "${ai}" -lt "${bi}" ]; then printf -- '-1'; return 0; fi
    if [ "${ai}" -gt "${bi}" ]; then printf '1'; return 0; fi
  done
  if [ -n "${a_pre}" ] && [ -z "${b_pre}" ]; then printf -- '-1'; return 0; fi
  if [ -z "${a_pre}" ] && [ -n "${b_pre}" ]; then printf '1'; return 0; fi
  if [ "${a_pre}" = "${b_pre}" ]; then printf '0'; return 0; fi
  if [ "$(printf '%s\n%s\n' "${a_pre}" "${b_pre}" | LC_ALL=C sort | head -n1)" = "${a_pre}" ]; then
    printf -- '-1'
  else
    printf '1'
  fi
}

version_ge() { [ "$(version_cmp "$1" "$2")" != "-1" ]; }

# ── Container runtime ────────────────────────────────────────────────────────
# Podman ships a compose-compatible CLI, and several enterprises forbid the Docker
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
        "Install Docker 24+ (with the compose plugin ${COMPOSE_MIN_VERSION}+) or Podman 4+, or set CONTAINER_RUNTIME."
  fi

  if "${RUNTIME}" compose version >/dev/null 2>&1; then
    COMPOSE=("${RUNTIME}" compose)
  elif command -v "${RUNTIME}-compose" >/dev/null 2>&1; then
    COMPOSE=("${RUNTIME}-compose")
  else
    die "${RUNTIME} has no compose support" \
        "Install the compose plugin (docker-compose-plugin ${COMPOSE_MIN_VERSION}+)."
  fi
  export RUNTIME
}

# The compose implementation's version, e.g. 2.29.7. Empty when it cannot say.
compose_version() {
  local out
  out="$("${COMPOSE[@]}" version --short 2>/dev/null || "${COMPOSE[@]}" version 2>/dev/null || true)"
  printf '%s' "${out}" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

# Run compose against this repo's stack, from any working directory, with the
# configuration the scripts read — including when TASKSENSE_ENV_FILE moved it.
compose() {
  if [ -f "${ENV_FILE}" ]; then
    ( cd "${COMPOSE_DIR}" && TASKSENSE_ENV_FILE="${ENV_FILE}" "${COMPOSE[@]}" --env-file "${ENV_FILE}" "$@" )
  else
    ( cd "${COMPOSE_DIR}" && "${COMPOSE[@]}" "$@" )
  fi
}

container_exists()  { "${RUNTIME}" container inspect "$1" >/dev/null 2>&1; }
container_running() {
  [ "$("${RUNTIME}" container inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

# The Compose project a container belongs to: its label, "-" when it exists
# but no Compose project made it (a plain `docker run`). Fails when there is
# no container by that name.
container_project() {
  local label
  label="$("${RUNTIME}" container inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$1" 2>/dev/null)" || return 1
  printf '%s' "${label:--}"
}

# Stop one container by name if it runs. Its restart policy (unless-stopped)
# then keeps it down until the next `compose up` that includes it.
stop_container() {
  local name="$1" reason="${2:-}"
  container_running "${name}" || return 0
  [ -n "${reason}" ] && note "stopping ${name} — ${reason}"
  "${RUNTIME}" stop -t 45 "${name}" >/dev/null
}

# The application tier: everything that writes to the database except the
# database. Stopped before a consistent backup or a restore, worker first so no
# landing is mid-write when the API goes.
stop_app_tier() {
  stop_container "${WORKER_CONTAINER}"
  stop_container "${APP_CONTAINER}"
}

# Bring the stack up as COMPOSE_PROFILES describes it.
#
# `compose up` never stops a service whose profile was switched off since the
# last run — its container just keeps running. A worker left running after the
# import-worker profile was removed would keep landing imports beside an API
# that now does the same; a bundled MongoDB left running after the move to an
# external one is a database nobody backs up. So those two are stopped here,
# by name, before anything starts.
compose_up() {
  if ! import_worker_enabled; then
    stop_container "${WORKER_CONTAINER}" "the import-worker profile is not in COMPOSE_PROFILES"
  fi
  if ! bundled_mongo_enabled; then
    stop_container "${MONGO_CONTAINER}" "the bundled-mongo profile is not in COMPOSE_PROFILES"
  fi
  # `up -d` waits for `migrate` to finish before it starts app and worker, and
  # fails — naming the service — if a migration fails.
  compose up -d
}

# Apply pending schema migrations with the configured version's image, as a
# one-shot run of the migrate service (the bundled MongoDB is started first and
# waited for, when it is part of this deployment).
run_migrations() {
  compose run --rm -T migrate
}

# How many migrations the configured version would apply. Empty when it cannot
# tell — which callers must treat as "possibly some".
migration_pending_count() {
  compose run --rm -T migrate node dist/database/migrations/cli.js status 2>/dev/null \
    | sed -n 's/^\([0-9][0-9]*\) pending.*/\1/p' | head -n1 || true
}

# ── Configuration ────────────────────────────────────────────────────────────

require_env_file() {
  [ -f "${ENV_FILE}" ] || die "no configuration at ${ENV_FILE}" \
    "cp ${EXAMPLE_FILE} ${ENV_FILE} && chmod 600 ${ENV_FILE}" \
    "then replace every <CHANGE_ME_…> value and run ./scripts/preflight.sh."
}

# Read one value out of .env without sourcing it: the file holds secrets that
# may contain characters the shell would interpret. The last definition wins,
# as it does for compose. Surrounding quotes and a Windows line ending are
# removed, as compose removes them.
#
# An absent file is "nothing is configured", not an error — the guided installer
# asks about the image registry before any .env exists. Without this guard GNU
# sed exits 2 on the missing file, `set -o pipefail` propagates it, and `set -e`
# ends the script with no message at all. It survives on Alpine, whose busybox
# sed is quieter, which is exactly the kind of difference that reaches a
# customer's RHEL host and not our test container.
env_value() {
  local key="$1" file="${2:-${ENV_FILE}}" value
  [ -f "${file}" ] || return 0
  value="$(sed -n "s/^${key}=//p" "${file}" | tail -n1 | tr -d '\r')"
  case "${value}" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s' "${value}"
}

# Is KEY assigned (even to nothing) on an active line?
env_has_key() {
  local key="$1" file="${2:-${ENV_FILE}}"
  [ -f "${file}" ] && grep -q "^${key}=" "${file}"
}

# env_set FILE KEY VALUE — set a value in place.
#
# Replaces the active line; failing that, uncomments the example's `#KEY=` line
# so the setting stays where the file documents it; failing that, appends. The
# value goes through the environment, never a sed or awk program, so a
# password full of / & \ arrives intact. The file keeps its inode and mode.
env_set() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  ENV_SET_KEY="${key}" ENV_SET_VALUE="${value}" awk '
    BEGIN { k = ENVIRON["ENV_SET_KEY"]; v = ENVIRON["ENV_SET_VALUE"]; active = 0; commented = 0 }
    { lines[NR] = $0 }
    index($0, k "=") == 1 { active = 1 }
    index($0, "#" k "=") == 1 && !commented { commented = NR }
    END {
      for (i = 1; i <= NR; i++) {
        if (active && index(lines[i], k "=") == 1) { print k "=" v; continue }
        if (!active && i == commented) { print k "=" v; continue }
        print lines[i]
      }
      if (!active && !commented) print k "=" v
    }' "${file}" > "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

require_env_values() {
  local key value missing=()
  for key in "$@"; do
    value="$(env_value "${key}")"
    [ -n "${value}" ] || missing+=("${key}")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "${ENV_FILE} is missing required values: ${missing[*]}" \
        "Each is described in the file itself and in docs/17-ENVIRONMENT.md."
  fi
}

# Active lines still holding the example's <CHANGE_ME_…> marker, by key.
placeholder_keys() {
  local file="${1:-${ENV_FILE}}"
  [ -f "${file}" ] || return 0
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=.*<CHANGE_ME' "${file}" | sed 's/=.*//' || true
}

# The required keys that are empty or still a placeholder, given which
# database the file describes. Used by the wizard's editor route.
unfinished_keys() {
  local file="${1:-${ENV_FILE}}" key value
  local -a required=(TASKSENSE_VERSION APP_URL FIRST_ADMIN_EMAIL STORAGE_SECRET)
  if ENV_FILE="${file}" bundled_mongo_enabled; then
    required+=(MONGO_USER MONGO_PASSWORD)
  else
    required+=(MONGODB_URI)
  fi
  for key in "${required[@]}"; do
    value="$(env_value "${key}" "${file}")"
    case "${value}" in
      ""|*"<CHANGE_ME"*) printf '%s\n' "${key}" ;;
    esac
  done
}

# ── Topology ─────────────────────────────────────────────────────────────────

# COMPOSE_PROFILES, without spaces.
env_profiles() { env_value COMPOSE_PROFILES | tr -d ' '; }

profile_enabled() {
  case ",$(env_profiles)," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

# Is the database somebody else's? MONGODB_URI set means the application talks
# to that cluster, whatever else is running — compose prefers it over the
# bundled address.
external_database() {
  [ -n "$(env_value MONGODB_URI)" ]
}

# Does this deployment run the bundled MongoDB container?
#
# No configuration yet means the default, which is yes. A configuration with no
# COMPOSE_PROFILES line is a 1.0 one, from before the profiles existed: there
# the bundled database ran exactly when MONGODB_URI was empty.
bundled_mongo_enabled() {
  [ -f "${ENV_FILE}" ] || return 0
  if env_has_key COMPOSE_PROFILES; then
    profile_enabled bundled-mongo
  elif external_database; then
    return 1
  fi
}

import_worker_enabled() {
  [ -f "${ENV_FILE}" ] || return 1
  profile_enabled import-worker
}

mongo_db_name() {
  local db; db="$(env_value MONGODB_DB)"
  printf '%s' "${db:-tasksense}"
}

# image:tag of the application, for the configured version or the one given.
app_image() {
  local image version="${1:-}"
  image="$(env_value TASKSENSE_IMAGE)"
  [ -n "${version}" ] || version="$(env_value TASKSENSE_VERSION)"
  printf '%s:%s' "${image:-${DEFAULT_IMAGE}}" "${version}"
}

# image:tag of MongoDB — the bundled server, and the mongodump/mongorestore
# used for an external database.
mongo_image() {
  local image version
  image="$(env_value MONGO_IMAGE)"; version="$(env_value MONGO_VERSION)"
  printf '%s:%s' "${image:-mongo}" "${version:-7}"
}

# ── Carrying a 1.0 configuration forward ─────────────────────────────────────
#
# 1.0 had no profiles: the scripts started `--no-deps app` when MONGODB_URI was
# set, and the whole stack otherwise. From 1.1 the bundled database is the
# bundled-mongo profile, so a 1.0 .env read as-is would run NO database — the
# application would then fail to reach `mongo:27017` and say only that.
#
# And 1.1 serves the API browser unless SWAGGER_ENABLED=false, where 1.0 served
# it only when asked. A 1.0 install that never asked is kept that way.
#
# Applied once, announced, with a copy of the original kept under backups/.
# Called by install.sh, upgrade.sh and preflight.sh, so whichever an operator
# runs first after updating these files, the configuration is right before
# compose reads it.
migrate_legacy_env() {
  local file="${1:-${ENV_FILE}}" profiles keep stamp
  [ -f "${file}" ] || return 0
  grep -q '^COMPOSE_PROFILES=' "${file}" && return 0

  if [ -n "$(env_value MONGODB_URI "${file}")" ]; then profiles=""; else profiles="bundled-mongo"; fi

  stamp="$(date -u +%Y%m%d-%H%M%SZ)"
  mkdir -p "${BACKUPS_DIR}"
  keep="${BACKUPS_DIR}/env-before-1.1-${stamp}"
  ( umask 077; cp "${file}" "${keep}" )

  {
    printf '\n\n'
    printf '# ── Added on %s: this file predates 1.1 ─────────────────────────\n' "${stamp}"
    printf '# The bundled MongoDB is a compose profile since 1.1. Empty means your own\n'
    printf '# MongoDB (MONGODB_URI). See compose/.env.example, section 2.\n'
    printf 'COMPOSE_PROFILES=%s\n' "${profiles}"
  } >> "${file}"
  if ! env_has_key SWAGGER_ENABLED "${file}"; then
    {
      printf '# 1.0 served the API browser only when asked; 1.1 serves it unless this\n'
      printf '# says false. Kept as it was.\n'
      printf 'SWAGGER_ENABLED=false\n'
    } >> "${file}"
  fi

  step "Configuration carried over from 1.0"
  ok "COMPOSE_PROFILES=${profiles}  ($([ -n "${profiles}" ] && echo "bundled MongoDB, as before" || echo "your own MongoDB, as before"))"
  grep -q '^SWAGGER_ENABLED=false$' "${file}" && ok "SWAGGER_ENABLED=false  (the API browser stays off, as before)"
  note "the original is kept at ${keep}"
  note "compare with compose/.env.example for the settings 1.1 added — every one has a default"
}

# ── MongoDB connection strings ───────────────────────────────────────────────
#
# Handled with parameter expansion only. A connection string carries a
# password, and anything passed as an argument to a command is visible in `ps`
# to every user on the host.

# The URI without a database in its path, for mongodump/mongorestore — which
# are then told the database with --db / --nsInclude, and refuse both at once.
# A database in the path was also the authentication database when no
# authSource was given; it is kept as authSource, so the credentials still
# authenticate where they did. The application keeps using the original URI.
mongo_uri_without_db() {
  local uri="$1" scheme rest authority path="" query="" lower
  scheme="${uri%%://*}"
  rest="${uri#*://}"
  case "${rest}" in *\?*) query="${rest#*\?}"; rest="${rest%%\?*}" ;; esac
  authority="${rest%%/*}"
  case "${rest}" in */*) path="${rest#*/}" ;; esac
  if [ -n "${path}" ]; then
    lower="$(printf '%s' "&${query}" | tr '[:upper:]' '[:lower:]')"
    case "${lower}" in
      *"&authsource="*) ;;
      *) query="${query:+${query}&}authSource=${path}" ;;
    esac
  fi
  printf '%s://%s/%s' "${scheme}" "${authority}" "${query:+?${query}}"
}

# Run a shell script inside a throwaway MongoDB-tools container that can reach
# the external database. The connection string is handed over in the
# environment (TS_MONGO_URI, named but not valued on the command line) and the
# script turns it into a --config file, so it never appears in `ps` on this
# host or inside the container. compose/certs is mounted at /certs, as for the
# application, so a tlsCAFile in the URI resolves the same way.
#
#   with_mongo_tools <uri> <script> [docker-run options…]   (stdin/stdout passed through)
with_mongo_tools() {
  local uri="$1" script="$2"; shift 2
  local -a args=(run --rm -i -e TS_MONGO_URI -e TS_DB -e TS_SRC_DB -v "${COMPOSE_DIR}/certs:/certs:ro")
  case "${uri}" in *host.docker.internal*) args+=(--add-host host.docker.internal:host-gateway) ;; esac
  TS_MONGO_URI="${uri}" "${RUNTIME}" "${args[@]}" "$@" --entrypoint sh "$(mongo_image)" -c "${script}"
}

# Shell, run inside a mongo container: write a credential from the container's
# environment into a mode-600 tools config file named by $CFG, removed on exit.
# The YAML value is single-quoted with embedded quotes doubled, so any
# password survives. (`read -d ''` rather than $(cat <<…): bash 3.2 misparses
# quotes in a here-document inside a command substitution.)
# shellcheck disable=SC2034  # used by backup.sh and restore.sh
read -r -d '' MONGO_CFG_FROM_URI <<'SH' || true
set -e
umask 077
CFG="$(mktemp)"
trap 'rm -f "$CFG"' EXIT
q="$(printf '%s' "$TS_MONGO_URI" | sed "s/'/''/g")"
printf "uri: '%s'\n" "$q" > "$CFG"
unset TS_MONGO_URI q
SH
# shellcheck disable=SC2034  # used by backup.sh and restore.sh
read -r -d '' MONGO_CFG_FROM_ROOT_PASSWORD <<'SH' || true
set -e
umask 077
CFG="$(mktemp)"
trap 'rm -f "$CFG"' EXIT
q="$(printf '%s' "$MONGO_INITDB_ROOT_PASSWORD" | sed "s/'/''/g")"
printf "password: '%s'\n" "$q" > "$CFG"
unset q
SH

# The first host and its port, for a reachability check. Credentials ignored.
uri_host() {
  local u="${1#*://}"
  u="${u##*@}"; u="${u%%/*}"; u="${u%%\?*}"; u="${u%%,*}"
  case "${u}" in \[*) u="${u#\[}"; printf '%s' "${u%%]*}"; return ;; esac
  printf '%s' "${u%%:*}"
}
uri_port() {
  local u="${1#*://}" default="${2:-27017}"
  u="${u##*@}"; u="${u%%/*}"; u="${u%%\?*}"; u="${u%%,*}"
  case "${u}" in \[*\]:*) printf '%s' "${u##*:}"; return ;; \[*) printf '%s' "${default}"; return ;; esac
  case "${u}" in *:*) printf '%s' "${u##*:}" ;; *) printf '%s' "${default}" ;; esac
}
# For messages and manifests: the URI with its credentials replaced.
uri_redacted() {
  local uri="$1" scheme rest
  scheme="${uri%%://*}"; rest="${uri#*://}"
  case "${rest%%/*}" in *@*) rest="***@${rest#*@}" ;; esac
  printf '%s://%s' "${scheme}" "${rest%%\?*}"
}

# Can this host open a TCP connection to host:port? Bounded, because a
# firewall that drops rather than refuses would otherwise hold it for minutes —
# and `timeout` is not on every host (macOS has none).
tcp_reachable() {
  local host="$1" port="$2" secs="${3:-5}" pid ticks=0
  ( exec 3<>"/dev/tcp/${host}/${port}" ) >/dev/null 2>&1 &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${ticks}" -ge $((secs * 10)) ]; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      return 1
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "${pid}"
}

# A compose memory size (512m, 2g, 6G, 1536mb) in MiB. Empty when unreadable.
size_to_mb() {
  local v n unit
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  v="${v%b}"
  n="${v%[kmg]}"; unit="${v#"${n}"}"
  case "${n}" in ''|*[!0-9]*) return 0 ;; esac
  case "${unit}" in
    g) printf '%s' $((n * 1024)) ;;
    m) printf '%s' "${n}" ;;
    k) printf '%s' $((n / 1024)) ;;
    "") printf '%s' $((n / 1024 / 1024)) ;;
  esac
}

# ── Registry access ──────────────────────────────────────────────────────────

# Where to ask for a registry token.
SUPPORT_EMAIL="${SUPPORT_EMAIL:-info@yurdtech.az}"

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
  image="${image:-${DEFAULT_IMAGE}}"
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
# image comes from somewhere that does not need one. The host defaults to the
# configured image's; load-images.sh names ghcr.io explicitly, because it reads
# from there even when .env already points at the mirror it is filling.
ensure_registry_login() {
  local host="${1:-}"
  [ -n "${host}" ] || host="$(registry_host)"

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
    if [ ! -t 0 ] || ! confirm "  Sign in again with a different token?"; then
      return 0
    fi
    "${RUNTIME}" logout "${host}" >/dev/null 2>&1 || true
  fi

  prompt_registry_login "${host}"
}

# Pull one image, or say plainly that it is already here.
ensure_image() {
  local image="$1"
  if "${RUNTIME}" image inspect "${image}" >/dev/null 2>&1; then
    note "${image} is already on this host"
    return 0
  fi
  "${RUNTIME}" pull "${image}"
}

# ── State left by earlier installs ───────────────────────────────────────────

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
  # Without the bundled database there is no volume of ours, and the
  # credentials of somebody else's server are not ours to explain.
  bundled_mongo_enabled || return 1
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

# ── Upgrade state ────────────────────────────────────────────────────────────

record_upgrade_state() {  # record_upgrade_state <previous-version> <backup-archive>
  printf '%s\nbackup=%s\n' "$1" "$2" > "${STATE_FILE}"
}
recorded_previous_version() {
  [ -f "${STATE_FILE}" ] || return 0
  head -n1 "${STATE_FILE}" | tr -d '\r'
}
recorded_pre_upgrade_backup() {
  [ -f "${STATE_FILE}" ] || return 0
  sed -n 's/^backup=//p' "${STATE_FILE}" | tail -n1
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

# "current", "ahead" (the database was migrated by a newer release than the one
# running — what an application-only rollback leaves), or empty when unknown.
schema_state() {
  curl -fsS --max-time 5 "$(health_url)" 2>/dev/null \
    | tr -d ' \n' | sed -n 's/.*"schema":{[^}]*"state":"\([a-z]*\)".*/\1/p' || true
}

running_version() {
  local port bind
  port="$(env_value HTTP_PORT)"; port="${port:-3000}"
  bind="$(env_value BIND_ADDRESS)"; bind="${bind:-127.0.0.1}"
  [ "${bind}" = "0.0.0.0" ] && bind=127.0.0.1
  curl -fsS --max-time 5 "http://${bind}:${port}/api/v1/version" 2>/dev/null || true
}
