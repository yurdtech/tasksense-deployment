#!/usr/bin/env bash
#
# Installs TaskSense on this host, as compose/.env describes it.
#
#   ./scripts/install.sh                   pull the images (ghcr.io, or your mirror)
#   ./scripts/install.sh --offline         load them from ./images (offline bundle)
#   ./scripts/install.sh --skip-preflight  you ran ./scripts/preflight.sh already
#
# What runs is COMPOSE_PROFILES: bundled-mongo for the database beside the app,
# nothing for your own MongoDB (MONGODB_URI), import-worker for a separate
# Jira-import process. The migrate step runs first, every time; the app starts
# only once it has succeeded.
#
# Safe to re-run: it starts what is not running and leaves existing data alone.

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

OFFLINE=0
SKIP_PREFLIGHT=0
for arg in "$@"; do
  case "${arg}" in
    --offline)        OFFLINE=1 ;;
    --skip-preflight) SKIP_PREFLIGHT=1 ;;
    -h|--help)        sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "unknown option: ${arg}" "Run with --help." ;;
  esac
done

detect_runtime
require_env_file
migrate_legacy_env

# MONGO_USER and MONGO_PASSWORD create and address the bundled database. With
# your own they are not used at all, and demanding them would mean inventing
# credentials for a server somebody else administers.
if bundled_mongo_enabled; then
  require_env_values TASKSENSE_VERSION APP_URL STORAGE_SECRET MONGO_USER MONGO_PASSWORD
else
  require_env_values TASKSENSE_VERSION APP_URL STORAGE_SECRET MONGODB_URI
fi

VERSION="$(env_value TASKSENSE_VERSION)"

step "TaskSense ${VERSION}"
note "runtime: ${RUNTIME}   config: ${ENV_FILE}"
PROFILES="$(env_profiles)"
note "profiles: ${PROFILES:-(none)}"
if bundled_mongo_enabled; then
  note "database: bundled MongoDB container ($(mongo_image))"
else
  note "database: your own — $(uri_redacted "$(env_value MONGODB_URI)")"
fi
if import_worker_enabled; then note "import worker: on — Jira landings run in their own process"; fi

if [ "${SKIP_PREFLIGHT}" = "0" ]; then
  if [ "${OFFLINE}" = "1" ]; then "${SCRIPT_DIR}/preflight.sh" --offline
  else "${SCRIPT_DIR}/preflight.sh"; fi \
    || die "preflight found problems — nothing was installed" "Fix the lines marked ${MARK_BAD} above, then run this again."
fi

step "Images"
if [ "${OFFLINE}" = "1" ]; then
  "${SCRIPT_DIR}/load-images.sh" --offline
else
  ensure_registry_login
  # Pulls what the enabled profiles use: the application image (app, migrate,
  # worker) and, with bundled-mongo, the database.
  compose pull || die "could not pull the images" \
    "If this host has no route to ghcr.io, install from the offline bundle:" \
    "  ./scripts/install.sh --offline" \
    "Or mirror the images into your own registry — docs/13-REGISTRY-ACCESS.md."
fi
if ! bundled_mongo_enabled; then
  # Not started, but backup.sh and restore.sh run mongodump/mongorestore from
  # it against your MongoDB. Better fetched now than discovered at 2am.
  ensure_image "$(mongo_image)" >/dev/null 2>&1 \
    || warn "could not fetch $(mongo_image) — backups of your MongoDB need it (set MONGO_IMAGE to your mirror)"
fi

step "Starting"
if ! compose_up; then
  printf '\n'
  compose logs --tail 40 migrate 2>/dev/null || true
  LOG="$(compose logs --tail 40 migrate 2>&1 || true)"
  case "${LOG}" in *"Authentication failed"*) explain_stale_mongo_volume ;; esac
  die "the stack did not start — the migrate step (shown above) or a container failed" \
      "A configuration error is reported in full on the first lines. See docs/10-TROUBLESHOOTING.md."
fi

if ! wait_for_health 180; then
  printf '\n'
  LOG="$(compose logs --tail 40 app 2>&1 || true)"
  printf '%s\n' "${LOG}"

  # One symptom is worth naming, because the message the driver produces is
  # true and useless: the password in .env really is the password, and it
  # really is refused.
  case "${LOG}" in
    *"Authentication failed"*) explain_stale_mongo_volume ;;
  esac

  die "the application did not become healthy within 180s" \
      "The log above usually says why. A configuration error is reported in full" \
      "on the first lines. See docs/10-TROUBLESHOOTING.md."
fi

step "Installed"
running_version | sed 's/^/  /'
ADMIN="$(env_value FIRST_ADMIN_EMAIL)"
URL="$(env_value APP_URL)"
cat <<EOF

  TaskSense is running.

  Address        ${URL}
  Administrator  ${ADMIN:-<FIRST_ADMIN_EMAIL not set>}
  Containers     $(compose ps --format '{{.Name}}' 2>/dev/null | tr '\n' ' ')

  Next:
    1. Put a reverse proxy with TLS in front of $(health_url | sed 's|/api/v1/health||')
       Ready-made configs: examples/nginx.conf, examples/Caddyfile
    2. Sign in as the administrator. No password was set for that account —
       use your identity provider, or claim it with "Create account".
    3. Schedule backups:  ./scripts/backup.sh from cron — docs/07-BACKUP-DR.md

  Logs:    ${COMPOSE[*]} -f compose/docker-compose.yml logs -f app
  Health:  curl $(health_url)
EOF
