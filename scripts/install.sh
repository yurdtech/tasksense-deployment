#!/usr/bin/env bash
#
# Installs TaskSense on this host.
#
#   ./scripts/install.sh              pull the image from ghcr.io
#   ./scripts/install.sh --offline    load images from ./images (release archive)
#   ./scripts/install.sh --skip-preflight
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
    -h|--help)        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                die "unknown option: ${arg}" "Run with --help." ;;
  esac
done

detect_runtime
require_env_file
require_env_values TASKSENSE_VERSION APP_URL STORAGE_SECRET MONGO_USER MONGO_PASSWORD

VERSION="$(env_value TASKSENSE_VERSION)"

step "TaskSense ${VERSION}"
note "runtime: ${RUNTIME}   config: ${ENV_FILE}"

if [ "${SKIP_PREFLIGHT}" = "0" ]; then
  if [ "${OFFLINE}" = "1" ]; then "${SCRIPT_DIR}/preflight.sh" --offline
  else "${SCRIPT_DIR}/preflight.sh"; fi
fi

step "Images"
if [ "${OFFLINE}" = "1" ]; then
  "${SCRIPT_DIR}/load-images.sh" --offline
else
  compose pull || die "could not pull the image" \
    "If this host has no route to ghcr.io, install from a release archive:" \
    "  ./scripts/install.sh --offline" \
    "Or mirror the image into your own registry — docs/13-REGISTRY-ACCESS.md."
fi

step "Starting"
compose up -d

if ! wait_for_health 180; then
  printf '\n'
  compose logs --tail 40 app || true
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

  Next:
    1. Put a reverse proxy with TLS in front of $(health_url | sed 's|/api/v1/health||')
       Ready-made configs: examples/nginx.conf, examples/Caddyfile
    2. Sign in as the administrator. No password was set for that account —
       use your identity provider, or register with that address to choose one.
    3. Schedule backups:  docs/07-BACKUP-DR.md

  Logs:    ${COMPOSE[*]} -f compose/docker-compose.yml logs -f app
  Health:  curl $(health_url)
EOF
