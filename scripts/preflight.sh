#!/usr/bin/env bash
#
# Checks this host and compose/.env before anything starts, so a problem
# surfaces now rather than halfway through a maintenance window — as a
# container that exits, an unhealthy service, or a log line nobody reads.
#
#   ./scripts/preflight.sh
#   ./scripts/preflight.sh --offline              skip the registry reachability check
#   ./scripts/preflight.sh --target-version 1.2.0 check against a version about to be installed
#   ./scripts/preflight.sh --host-only            the host alone, before any configuration exists
#
# Exit 0: nothing blocks an install. Exit 1: at least one ✗ line must be fixed.
# Warnings (!) are worth reading and never fail the run.
#
# It starts, stops and pulls nothing. The one thing it may change is a
# configuration from 1.0, which it carries forward once and announces (see
# migrate_legacy_env in lib.sh) — the same step install.sh and upgrade.sh take.

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# A check that fails must not end the run: the point is to list every problem.
set +e

OFFLINE=0
HOST_ONLY=0
TARGET_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --offline)        OFFLINE=1; shift ;;
    --target-version) TARGET_VERSION="${2:-}"; shift 2 ;;
    --host-only)      HOST_ONLY=1; shift ;;
    -h|--help)        sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "unknown option: $1" "Run with --help." ;;
  esac
done

MIN_APP_VERSION=1.1.0
FAILURES=0
WARNINGS=0
fail()   { printf '  %s%s%s %s\n' "$C_RED" "$MARK_BAD" "$C_OFF" "$*"; FAILURES=$((FAILURES + 1)); }
advise() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_OFF" "$*"; WARNINGS=$((WARNINGS + 1)); }
detail() { printf '      %s\n' "$*"; }

summary() {
  printf '\n'
  if [ "${FAILURES}" -gt 0 ]; then
    printf '%s%s %s problem(s) must be fixed first.%s' "$C_RED" "$MARK_BAD" "${FAILURES}" "$C_OFF"
    [ "${WARNINGS}" -gt 0 ] && printf ' %s(%s warning(s))%s' "$C_YELLOW" "${WARNINGS}" "$C_OFF"
    printf '\n\n  Fix the %s lines above and run ./scripts/preflight.sh again.\n\n' "${MARK_BAD}"
    exit 1
  fi
  printf '%s%s preflight passed.%s' "$C_GREEN" "$MARK_OK" "$C_OFF"
  [ "${WARNINGS}" -gt 0 ] && printf ' %s%s warning(s) — review them above.%s' "$C_YELLOW" "${WARNINGS}" "$C_OFF"
  printf '\n\n'
  exit 0
}

is_uint()   { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_number() { printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; }

# ══ 1. Container runtime ═════════════════════════════════════════════════════
step "Container runtime"

if ! ( detect_runtime ) >/dev/null 2>&1; then
  fail "no usable container runtime with compose support"
  detail "Install Docker Engine 24+ with the compose plugin ${COMPOSE_MIN_VERSION}+ (or Podman 4+ with docker-compose as its provider)."
  summary
fi
detect_runtime
ok "${RUNTIME} $("${RUNTIME}" --version 2>/dev/null | head -n1)"
RUNTIME_OK=1
if ! "${RUNTIME}" info >/dev/null 2>&1; then
  RUNTIME_OK=0
  fail "${RUNTIME} is installed but not usable by $(whoami) — is the service running, and are you in the right group?"
fi

CVER="$(compose_version)"
if [ -z "${CVER}" ]; then
  advise "could not read the compose version — ${COMPOSE_MIN_VERSION} or newer is required"
elif version_ge "${CVER}" "${COMPOSE_MIN_VERSION}"; then
  ok "${COMPOSE[*]} ${CVER}"
else
  fail "${COMPOSE[*]} ${CVER} is too old — ${COMPOSE_MIN_VERSION} or newer is required (for depends_on.required)"
  detail "Upgrade the docker-compose-plugin package; with Podman, install docker-compose as its compose provider."
fi

# ══ 2. Host resources ════════════════════════════════════════════════════════
step "Host resources"

if command -v nproc >/dev/null 2>&1; then CPUS="$(nproc)"; else CPUS="$(sysctl -n hw.ncpu 2>/dev/null || echo 0)"; fi
if [ "${CPUS}" -ge 2 ] 2>/dev/null; then ok "${CPUS} CPU cores"; else fail "${CPUS} CPU cores — 2 is the minimum"; fi

MEM_MB=0
if [ -r /proc/meminfo ]; then
  MEM_MB=$(($(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024))
elif command -v sysctl >/dev/null 2>&1; then
  MEM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
fi
if [ "${MEM_MB}" -ge 3500 ]; then ok "$((MEM_MB / 1024)) GB memory"
elif [ "${MEM_MB}" -eq 0 ]; then advise "could not determine memory"
else fail "$((MEM_MB / 1024)) GB memory — 4 GB is the minimum"; fi

free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}'; }

# -Pk, not -Pg: GNU and busybox df have no -g.
DISK_GB="$(free_gb /)"; DISK_GB="${DISK_GB:-0}"
if [ "${DISK_GB}" -ge 20 ]; then ok "${DISK_GB} GB free on /"
else fail "${DISK_GB} GB free on / — 20 GB is the minimum, and the database grows"; fi

check_registry() {
  local reg
  reg="$(registry_host)"
  if [ "${OFFLINE}" = "1" ]; then
    note "offline — registry reachability not checked"
  elif curl -sS -o /dev/null --max-time 8 "https://${reg}/v2/" 2>/dev/null; then
    ok "${reg} reachable"
  else
    advise "${reg} is not reachable — install from the offline bundle (--offline), or mirror the images (scripts/load-images.sh)"
  fi
}

if [ "${HOST_ONLY}" = "1" ]; then
  step "Network"
  check_registry
  note "host checks only — the configuration is checked once it exists"
  summary
fi

# ══ 3. Configuration file ════════════════════════════════════════════════════
step "Configuration — ${ENV_FILE}"

if [ ! -f "${ENV_FILE}" ]; then
  fail "no configuration at ${ENV_FILE}"
  detail "cp ${EXAMPLE_FILE} ${ENV_FILE} && chmod 600 ${ENV_FILE}"
  detail "then replace every <CHANGE_ME_…> value and run this again."
  summary
fi
ok "found"

# Before anything reads it: a 1.0 file has no COMPOSE_PROFILES, and read as-is
# it would describe a stack with no database.
migrate_legacy_env

# Edited on Windows and copied over: every value then ends in an invisible \r,
# and "tasksense\r" is not the password.
if grep -q $'\r' "${ENV_FILE}"; then
  fail "the file has Windows (CRLF) line endings — every value would carry a hidden carriage return"
  detail "Convert it:  sed -i 's/\\r\$//' ${ENV_FILE}"
fi

# Only active lines: a commented-out optional may keep its example text.
PLACEHOLDERS="$(placeholder_keys)"
if [ -n "${PLACEHOLDERS}" ]; then
  fail "these still hold a <CHANGE_ME_…> placeholder: $(printf '%s' "${PLACEHOLDERS}" | tr '\n' ' ')"
  detail "Each is explained in the file. Generate secrets with the command shown beside them."
else
  ok "no <CHANGE_ME_…> placeholders left"
fi

# A key defined twice silently uses the LAST definition — an easy way to end up
# on the wrong database after uncommenting an example below an existing line.
DUPES="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "${ENV_FILE}" | tr -d '=' | sort | uniq -d)"
if [ -n "${DUPES}" ]; then
  for d in ${DUPES}; do
    fail "${d} is defined more than once (lines $(grep -n "^${d}=" "${ENV_FILE}" | cut -d: -f1 | tr '\n' ' ')) — only the last one takes effect"
  done
else
  ok "no setting is defined twice"
fi

PERMS="$(stat -c '%a' "${ENV_FILE}" 2>/dev/null || stat -f '%Lp' "${ENV_FILE}" 2>/dev/null || echo '?')"
case "${PERMS}" in
  600|400) ok "mode ${PERMS}" ;;
  \?)      advise "could not read the file's permissions" ;;
  *)       advise "mode ${PERMS} — it holds the storage key and database credentials:  chmod 600 ${ENV_FILE}" ;;
esac

VERSION="$(env_value TASKSENSE_VERSION)"
CHECK_VERSION="${TARGET_VERSION:-${VERSION}}"
if [ -z "${VERSION}" ]; then
  fail "TASKSENSE_VERSION is not set — pin the release you were given, e.g. ${MIN_APP_VERSION}"
elif [ "${VERSION}" = "latest" ]; then
  fail "TASKSENSE_VERSION=latest — pin an exact release, or a restart can silently change version"
elif ! semver_valid "${CHECK_VERSION}"; then
  fail "TASKSENSE_VERSION=${CHECK_VERSION} is not a release number (expected e.g. ${MIN_APP_VERSION})"
elif ! version_ge "${CHECK_VERSION%%-*}" "${MIN_APP_VERSION}"; then
  fail "TaskSense ${CHECK_VERSION} is older than this packaging supports (${MIN_APP_VERSION}+: migrate job, import worker)"
  detail "Upgrade with ./scripts/upgrade.sh ${MIN_APP_VERSION}, or use the deployment files released with ${CHECK_VERSION}."
else
  ok "TaskSense ${CHECK_VERSION}${TARGET_VERSION:+ (target; ${VERSION} configured now)}"
fi

APP_URL="$(env_value APP_URL)"
case "${APP_URL}" in
  https://*) ok "APP_URL ${APP_URL}" ;;
  http://*)  advise "APP_URL uses plain http — sign-in cookies and passwords would cross the network unencrypted" ;;
  *)         fail "APP_URL must start with https:// (found: '${APP_URL:-empty}')" ;;
esac
case "${APP_URL}" in */) advise "APP_URL ends in / — redirect URIs are built from it; drop the trailing slash" ;; esac

[ -n "$(env_value FIRST_ADMIN_EMAIL)" ] || advise "FIRST_ADMIN_EMAIL is empty — a fresh install then has no administrator"

SECRET="$(env_value STORAGE_SECRET)"
if [ -z "${SECRET}" ]; then fail "STORAGE_SECRET is empty — generate one with: openssl rand -base64 32"
elif [ "${#SECRET}" -lt 32 ]; then fail "STORAGE_SECRET is ${#SECRET} characters — 32 is the minimum"
else ok "STORAGE_SECRET set (${#SECRET} characters)"; fi

# The application validates these at boot and refuses to start on a bad one;
# a list here is cheaper than a container that exits. LOG_LEVEL=info is the
# value that once shipped in the example.
check_enum() {  # check_enum KEY allowed…
  local key="$1" value; shift
  env_has_key "${key}" || return 0
  value="$(env_value "${key}")"
  local a; for a in "$@"; do [ "${value}" = "${a}" ] && return 0; done
  fail "${key}=${value:-<empty>} is not accepted — one of: $*"
  [ -z "${value}" ] && detail "An empty value is not the same as unset: comment the line out to take the default."
}
check_enum LOG_LEVEL verbose debug log warn error fatal
check_enum LOG_FORMAT json text
check_enum AGENT_DISPATCHER on off
check_enum MONGODB_COMPRESSORS zlib none
check_enum RATE_LIMIT_STORE memory mongo
check_enum WORKER_ROLE all api

# Numbers. An active but empty line is read as 0 — which the application
# refuses for most of these, and which for SESSION_TTL_HOURS means "never".
for key in SMTP_PORT MONGODB_TIMEOUT_MS MONGODB_MAX_POOL_SIZE STORAGE_MAX_FILE_MB \
           STORAGE_MAX_VIDEO_FILE_MB JIRA_BACKUP_RETENTION_DAYS STATE_TASK_LIMIT \
           REPORTS_MAX_TASKS HTTP_PORT APP_HEAP_MB WORKER_HEAP_MB; do
  env_has_key "${key}" || continue
  value="$(env_value "${key}")"
  if ! is_uint "${value}" || [ "${value}" -eq 0 ]; then
    fail "${key}=${value:-<empty>} must be a positive whole number"
    [ -z "${value}" ] && detail "Comment the line out to take the default."
  fi
done
for key in MONGODB_OP_TIMEOUT_MS MONGODB_MIN_POOL_SIZE AUTOMATION_PROCESSING_MINUTES_PER_12H SESSION_TTL_HOURS; do
  env_has_key "${key}" || continue
  value="$(env_value "${key}")"
  [ -z "${value}" ] && continue   # reported below where it matters
  is_uint "${value}" || fail "${key}=${value} must be a whole number"
done
for key in JIRA_BACKUP_MAX_GB MONGO_CACHE_GB; do
  env_has_key "${key}" || continue
  value="$(env_value "${key}")"
  is_number "${value}" || fail "${key}=${value:-<empty>} must be a number, e.g. 20 or 0.5"
done

# Optional URLs: the application validates them as URLs when they are present
# at all, so `OIDC_ISSUER=` with nothing after it stops the boot.
for key in OIDC_ISSUER OIDC_REDIRECT_URI; do
  env_has_key "${key}" || continue
  value="$(env_value "${key}")"
  case "${value}" in
    https://*|http://*) ;;
    "") fail "${key} is set to nothing — comment the line out, or give the full URL" ;;
    *)  fail "${key}=${value} must be a full URL (https://…)" ;;
  esac
done

if [ -n "$(env_value MIGRATE_ON_BOOT)" ]; then
  note "MIGRATE_ON_BOOT in .env is ignored — the stack runs migrations in its own migrate step"
fi
# There are no LDAP_* variables any more — directory sign-in is configured
# inside the application. A leftover value is ignored; say so.
LEFTOVER="$(grep -oE '^LDAP_[A-Z_]*=' "${ENV_FILE}" | tr -d '=' | sort -u | tr '\n' ' ')"
if [ -n "${LEFTOVER}" ]; then
  note "ignored since 1.1 and safe to delete: ${LEFTOVER}— LDAP is configured in the app (Admin → Authentication)"
fi

# ══ 4. Security posture ══════════════════════════════════════════════════════
step "Security"

EXECUTOR="$(env_value AGENT_EXECUTOR)"
case "${EXECUTOR:-off}" in
  off) ok "AGENT_EXECUTOR=off" ;;
  on|auto)
    fail "AGENT_EXECUTOR=${EXECUTOR} — no execution sandbox ships on-premise; set AGENT_EXECUTOR=off"
    detail "The application refuses it at boot anyway. Off is the only supported value." ;;
  unsafe-host)
    fail "AGENT_EXECUTOR=unsafe-host would run model-authored commands on this server with no sandbox — set AGENT_EXECUTOR=off" ;;
  *)
    fail "AGENT_EXECUTOR=${EXECUTOR} is not a value the application accepts — set AGENT_EXECUTOR=off" ;;
esac

TTL="$(env_value SESSION_TTL_HOURS)"
if ! env_has_key SESSION_TTL_HOURS; then
  advise "SESSION_TTL_HOURS is unset — sign-ins last 720 h (30 days). Bank: SESSION_TTL_HOURS=12"
elif [ -z "${TTL}" ] || [ "${TTL}" = "0" ]; then
  advise "SESSION_TTL_HOURS=${TTL:-<empty>} — sessions never expire. Bank: SESSION_TTL_HOURS=12"
elif is_uint "${TTL}" && [ "${TTL}" -gt 24 ]; then
  advise "SESSION_TTL_HOURS=${TTL} — a sign-in lasts $((TTL / 24)) day(s). Bank: 12"
else
  ok "SESSION_TTL_HOURS=${TTL}"
fi

SWAGGER="$(env_value SWAGGER_ENABLED)"
case "${SWAGGER}" in
  false|0) ok "SWAGGER_ENABLED=${SWAGGER} — no API browser" ;;
  *) advise "the API browser is ON at /api/v1/swagger and publishes the whole API surface — SWAGGER_ENABLED=false unless you are integrating" ;;
esac

case "$(env_value METRICS_ENABLED)" in
  true|1)
    if [ -z "$(env_value METRICS_TOKEN)" ]; then
      advise "METRICS_ENABLED is on but METRICS_TOKEN is empty — metrics stay off. Generate: openssl rand -hex 32"
    else
      ok "metrics on, behind a bearer token"
    fi ;;
esac

[ -n "$(env_value OWNER_EMAILS)" ] && advise "OWNER_EMAILS grants admin outside the app's audited role management — keep it empty"

BIND="$(env_value BIND_ADDRESS)"; BIND="${BIND:-127.0.0.1}"
case "${BIND}" in
  127.*|localhost|::1) ok "published on ${BIND} only — the reverse proxy on this host is the way in" ;;
  *) advise "BIND_ADDRESS=${BIND} — the plain-HTTP port is reachable beyond this host; firewall it to the proxy" ;;
esac

# ══ 5. Database ══════════════════════════════════════════════════════════════
step "Database"

PROFILES="$(env_profiles)"
for p in $(printf '%s' "${PROFILES}" | tr ',' ' '); do
  case "${p}" in
    bundled-mongo|import-worker) ;;
    *) fail "COMPOSE_PROFILES names '${p}', which is not a profile — use bundled-mongo and/or import-worker" ;;
  esac
done

MONGODB_URI="$(env_value MONGODB_URI)"
BUNDLED=0; profile_enabled bundled-mongo && BUNDLED=1
DB_NAME="$(mongo_db_name)"
case "${DB_NAME}" in
  *[!A-Za-z0-9_-]*) fail "MONGODB_DB=${DB_NAME} — use letters, digits, - and _ only" ;;
esac

if [ "${BUNDLED}" = "1" ] && [ -n "${MONGODB_URI}" ]; then
  fail "MONGODB_URI is set AND bundled-mongo is in COMPOSE_PROFILES — the bundled database would run unused"
  detail "Your own MongoDB: remove bundled-mongo from COMPOSE_PROFILES. The bundled one: comment out MONGODB_URI."
elif [ "${BUNDLED}" = "0" ] && [ -z "${MONGODB_URI}" ]; then
  fail "no database: bundled-mongo is not in COMPOSE_PROFILES and MONGODB_URI is not set"
  detail "Set COMPOSE_PROFILES=bundled-mongo, or MONGODB_URI to your own cluster — docs/16-EXTERNAL-DATABASES.md."
elif [ "${BUNDLED}" = "1" ]; then
  ok "bundled MongoDB ($(mongo_image)), database ${DB_NAME}"
  MUSER="$(env_value MONGO_USER)"; MPASS="$(env_value MONGO_PASSWORD)"
  [ -n "${MUSER}" ] || fail "MONGO_USER is empty — the bundled database needs an account"
  if [ -z "${MPASS}" ]; then
    fail "MONGO_PASSWORD is empty — generate one with: openssl rand -hex 24"
  else
    case "${MPASS}" in
      *[/:@?\#%]*|*'['*|*']'*)
        fail "MONGO_PASSWORD contains / : @ ? # % [ or ] — it is placed inside a connection string, which ends early at those"
        detail "Use a hex password:  openssl rand -hex 24" ;;
    esac
  fi
  [ "$(env_value MONGODB_COMPRESSORS)" = "zlib" ] && note "MONGODB_COMPRESSORS=zlib costs CPU for nothing on the same host — none is enough here"

  if [ "${RUNTIME_OK}" = "1" ] && "${RUNTIME}" volume inspect "${MONGO_VOLUME}" >/dev/null 2>&1; then
    if container_running "${MONGO_CONTAINER}" && [ -n "${MUSER}" ] && [ -n "${MPASS}" ]; then
      # The credentials travel in the environment, not as arguments: anything
      # on a command line is visible in `ps` to every user on this host.
      if TS_CHECK_USER="${MUSER}" TS_CHECK_PASS="${MPASS}" "${RUNTIME}" exec \
           -e TS_CHECK_USER -e TS_CHECK_PASS "${MONGO_CONTAINER}" mongosh --quiet --norc --eval \
           'db.getSiblingDB("admin").auth(process.env.TS_CHECK_USER, process.env.TS_CHECK_PASS).ok' >/dev/null 2>&1; then
        ok "the running bundled MongoDB accepts MONGO_USER / MONGO_PASSWORD"
      else
        fail "the existing bundled MongoDB does NOT accept MONGO_USER / MONGO_PASSWORD from .env"
        detail "They apply only when ${MONGO_VOLUME} is first created. Put the original values back —"
        detail "docs/10-TROUBLESHOOTING.md, \"Authentication failed\", has the reset procedure."
      fi
    else
      note "${MONGO_VOLUME} exists — it keeps the credentials it was created with; changing MONGO_PASSWORD now has no effect on it"
    fi
  fi
else
  case "${MONGODB_URI}" in
    mongodb://*|mongodb+srv://*) ok "your own MongoDB: $(uri_redacted "${MONGODB_URI}"), database ${DB_NAME}" ;;
    *) fail "MONGODB_URI must start with mongodb:// or mongodb+srv://" ;;
  esac
  case "${MONGODB_URI}" in
    mongodb+srv://*)
      note "SRV record — the members are resolved by DNS from inside the containers; not probed from here" ;;
    mongodb://*)
      MH="$(uri_host "${MONGODB_URI}")"; MP="$(uri_port "${MONGODB_URI}" 27017)"
      if [ "${MH}" = "localhost" ] || [ "${MH#127.}" != "${MH}" ]; then
        fail "MONGODB_URI points at ${MH} — inside a container that is the container itself; use this host's address"
      elif [ "${MH}" = "host.docker.internal" ]; then
        advise "host.docker.internal resolves only on Docker Desktop — on a Linux server use this host's address"
      elif tcp_reachable "${MH}" "${MP}" 5; then
        ok "${MH}:${MP} accepts TCP connections from this host"
      else
        advise "cannot open a TCP connection to ${MH}:${MP} from this host — firewall, DNS, or the server's bind address"
        detail "If only the container network is allowed through, this is expected."
      fi ;;
  esac
  case "${MONGODB_URI}" in
    *[?\&]tlsCAFile=*)
      CA="${MONGODB_URI#*tlsCAFile=}"; CA="${CA%%&*}"
      case "${CA}" in
        /certs/*)
          if [ -f "${COMPOSE_DIR}/certs/${CA#/certs/}" ]; then
            ok "tlsCAFile ${CA} is in compose/certs/"
          else
            fail "MONGODB_URI names tlsCAFile=${CA}, but compose/certs/${CA#/certs/} does not exist"
            detail "Copy the CA PEM there — the containers see compose/certs as /certs."
          fi ;;
        *) fail "tlsCAFile=${CA} is not under /certs — the containers only see compose/certs, mounted at /certs" ;;
      esac ;;
    *[?\&]tls=true*|*[?\&]ssl=true*)
      [ -z "$(env_value NODE_EXTRA_CA_CERTS)" ] && note "TLS without tlsCAFile or NODE_EXTRA_CA_CERTS trusts public CAs only — add your CA if the server's certificate is internal" ;;
  esac
  [ "$(env_value MONGODB_COMPRESSORS)" = "none" ] && note "MONGODB_COMPRESSORS=none — across a network, zlib is usually much faster"
  TMO="$(env_value MONGODB_TIMEOUT_MS)"
  if [ -z "${TMO}" ] || { is_uint "${TMO}" && [ "${TMO}" -lt 15000 ]; }; then
    note "MONGODB_TIMEOUT_MS is ${TMO:-5000 (default)} — across a network, 15000 is the bank recommendation"
  fi
  if [ -n "$(env_value MONGO_PASSWORD)" ]; then
    note "MONGO_USER / MONGO_PASSWORD are unused with your own MongoDB — leave them empty"
  fi
  if [ "${RUNTIME_OK}" = "1" ] && ! "${RUNTIME}" image inspect "$(mongo_image)" >/dev/null 2>&1; then
    note "backups of your MongoDB use the $(mongo_image) image for mongodump — install.sh fetches it"
  fi
fi

# ══ 6. Import worker ═════════════════════════════════════════════════════════
step "Import worker"

ROLE="$(env_value WORKER_ROLE)"; ROLE="${ROLE:-all}"
if profile_enabled import-worker; then
  if [ "${ROLE}" = "api" ]; then
    ok "import-worker on, and the API runs with WORKER_ROLE=api"
  else
    fail "the import-worker profile is on but WORKER_ROLE=${ROLE} — set WORKER_ROLE=api"
    detail "With both processes in 'all' mode, the API would run the same landings the worker runs."
  fi
else
  case "${ROLE}" in
    all) ok "off — the API runs every workload itself (WORKER_ROLE=all)" ;;
    api)
      fail "WORKER_ROLE=api but the import-worker profile is off — nothing would run Jira landings"
      detail "Add import-worker to COMPOSE_PROFILES, or set WORKER_ROLE=all." ;;
  esac
fi

JIRA_GB="$(env_value JIRA_BACKUP_MAX_GB)"; JIRA_GB="${JIRA_GB:-20}"
NEED_GB="$(awk -v g="${JIRA_GB}" 'BEGIN { printf "%d", (g * 2) + 0.999 }')"
DATA_ROOT=""
if [ "${RUNTIME_OK}" = "1" ]; then
  DATA_ROOT="$("${RUNTIME}" info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [ -n "${DATA_ROOT}" ] || DATA_ROOT="$("${RUNTIME}" info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)"
fi
ROOT_FREE=""
[ -n "${DATA_ROOT}" ] && ROOT_FREE="$(free_gb "${DATA_ROOT}")"
if [ -z "${ROOT_FREE}" ]; then
  DATA_ROOT="/"; ROOT_FREE="${DISK_GB}"
fi
if [ "${ROOT_FREE}" -ge "${NEED_GB}" ] 2>/dev/null; then
  ok "${ROOT_FREE} GB free under ${DATA_ROOT} (volumes) — room for a ${JIRA_GB} GB Jira backup and its landing"
else
  advise "${ROOT_FREE} GB free under ${DATA_ROOT}, where the data volume lives — a ${JIRA_GB} GB Jira backup needs about ${NEED_GB} GB (JIRA_BACKUP_MAX_GB × 2)"
fi

# Limits against the host, and heaps against their limits.
APP_MEM="$(size_to_mb "$(env_value APP_MEMORY_LIMIT)")"; APP_MEM="${APP_MEM:-2048}"
TOTAL_MB="${APP_MEM}"
[ "${BUNDLED}" = "1" ] && { M="$(size_to_mb "$(env_value MONGO_MEMORY_LIMIT)")"; TOTAL_MB=$((TOTAL_MB + ${M:-2048})); }
WORKER_MEM="$(size_to_mb "$(env_value WORKER_MEMORY_LIMIT)")"; WORKER_MEM="${WORKER_MEM:-6144}"
profile_enabled import-worker && TOTAL_MB=$((TOTAL_MB + WORKER_MEM))
if [ "${MEM_MB}" -gt 0 ] && [ "${TOTAL_MB}" -gt "${MEM_MB}" ]; then
  advise "the containers' memory limits add up to $((TOTAL_MB / 1024)) GB, more than this host's $((MEM_MB / 1024)) GB"
fi
heap_check() {  # heap_check HEAP_KEY default LIMIT_MB label
  local heap; heap="$(env_value "$1")"; heap="${heap:-$2}"
  is_uint "${heap}" || return 0
  if [ "${heap}" -gt $(( $3 * 85 / 100 )) ]; then
    advise "$1=${heap} leaves too little of the ${4}'s $3 MB limit for anything but the heap — keep it near 75%"
  fi
}
heap_check APP_HEAP_MB 1536 "${APP_MEM}" "API"
profile_enabled import-worker && heap_check WORKER_HEAP_MB 4096 "${WORKER_MEM}" "worker"
if [ "${BUNDLED}" = "1" ]; then
  CACHE="$(env_value MONGO_CACHE_GB)"; CACHE="${CACHE:-1}"
  MLIM="$(size_to_mb "$(env_value MONGO_MEMORY_LIMIT)")"; MLIM="${MLIM:-2048}"
  if is_number "${CACHE}" && awk -v c="${CACHE}" -v l="${MLIM}" 'BEGIN { exit !(c * 1024 > l * 0.6) }'; then
    advise "MONGO_CACHE_GB=${CACHE} is more than 60% of MONGO_MEMORY_LIMIT — MongoDB is then OOM-killed under load"
  fi
fi

# ══ 7. Certificates ══════════════════════════════════════════════════════════
step "Certificates"

[ -d "${COMPOSE_DIR}/certs" ] || advise "compose/certs/ is missing — recreate it (it is mounted at /certs)"
EXTRA_CA="$(env_value NODE_EXTRA_CA_CERTS)"
if [ -z "${EXTRA_CA}" ]; then
  note "NODE_EXTRA_CA_CERTS unset — outbound TLS trusts public CAs only"
else
  case "${EXTRA_CA}" in
    /certs/*)
      CA_FILE="${COMPOSE_DIR}/certs/${EXTRA_CA#/certs/}"
      if [ ! -f "${CA_FILE}" ]; then
        fail "NODE_EXTRA_CA_CERTS=${EXTRA_CA}, but compose/certs/${EXTRA_CA#/certs/} does not exist"
      elif ! grep -q 'BEGIN CERTIFICATE' "${CA_FILE}"; then
        fail "compose/certs/${EXTRA_CA#/certs/} is not a PEM certificate (no BEGIN CERTIFICATE line)"
      else
        ok "NODE_EXTRA_CA_CERTS ${EXTRA_CA} ($(grep -c 'BEGIN CERTIFICATE' "${CA_FILE}") certificate(s))"
      fi ;;
    *) fail "NODE_EXTRA_CA_CERTS=${EXTRA_CA} is not under /certs — the containers only see compose/certs, mounted at /certs" ;;
  esac
fi

# ══ 8. Network ═══════════════════════════════════════════════════════════════
step "Network"

PORT="$(env_value HTTP_PORT)"; PORT="${PORT:-3000}"
PROBE_ADDR="${BIND}"; case "${PROBE_ADDR}" in 0.0.0.0|localhost|::) PROBE_ADDR=127.0.0.1 ;; esac
if is_uint "${PORT}" && tcp_reachable "${PROBE_ADDR}" "${PORT}" 2; then
  if [ "${RUNTIME_OK}" = "1" ] && container_running "${APP_CONTAINER}"; then
    ok "port ${PORT} is held by TaskSense itself — a restart or upgrade replaces it"
  else
    fail "port ${PORT} on ${PROBE_ADDR} is already in use — change HTTP_PORT or stop what is holding it"
  fi
else
  ok "port ${PORT} is free"
fi

check_registry

# ══ 9. Compose file ══════════════════════════════════════════════════════════
step "Compose file"

if CFG_ERR="$(compose config -q 2>&1)"; then
  ok "docker-compose.yml is valid with this configuration ($(compose config --services 2>/dev/null | tr '\n' ' '))"
else
  fail "compose cannot read the stack with this configuration:"
  printf '%s\n' "${CFG_ERR}" | sed 's/^/      /'
fi

summary
