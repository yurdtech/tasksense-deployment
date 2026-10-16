#!/usr/bin/env bash
#
# Goes back to the version that ran before the last upgrade — with its data.
#
#   ./scripts/rollback.sh                 previous version + the backup upgrade.sh took before it
#   ./scripts/rollback.sh --app-only      previous version only; the database stays as it is
#   ./scripts/rollback.sh 1.1.0 --app-only
#   ./scripts/rollback.sh --yes           no questions
#
# By default this restores the backup upgrade.sh recorded just before the
# upgrade, because the newer version's migrations may have changed the
# database into a shape the older one cannot read. Everything users changed
# since that backup is lost — a safety backup of the current state is taken
# first, so that is recoverable too.
#
# --app-only switches the image back and leaves the data alone. Use it only
# when you know no migration ran, or the release notes say the older version
# reads the newer schema: otherwise the older code runs against data it does
# not understand, and it misbehaves rather than failing loudly.

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TARGET=""
APP_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app-only) APP_ONLY=1; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         die "unknown option: $1" "Run with --help." ;;
    *)          [ -z "${TARGET}" ] || die "one version at a time"; TARGET="${1#v}"; shift ;;
  esac
done

detect_runtime
require_env_file
migrate_legacy_env

CURRENT="$(env_value TASKSENSE_VERSION)"
RECORDED="$(recorded_previous_version)"
if [ -z "${TARGET}" ]; then
  [ -n "${RECORDED}" ] || die "no previous version recorded in ${STATE_FILE}" \
    "Name one explicitly:  ./scripts/rollback.sh <version> [--app-only]"
  TARGET="${RECORDED}"
fi
semver_valid "${TARGET}" || die "${TARGET} is not a release number"
[ "${TARGET}" != "${CURRENT}" ] || die "${CURRENT} is already the configured version"
[ "$(version_cmp "${TARGET}" "${CURRENT}")" = "-1" ] || die "${TARGET} is newer than ${CURRENT} — that is an upgrade:" \
  "  ./scripts/upgrade.sh ${TARGET}"

# 1.0 has no separate import worker (dist/worker.js arrived in 1.1).
if import_worker_enabled && [ "$(version_cmp "${TARGET%%-*}" 1.1.0)" = "-1" ]; then
  die "${TARGET} has no import worker, and the import-worker profile is on" \
      "In ${ENV_FILE}: remove import-worker from COMPOSE_PROFILES and set WORKER_ROLE=all, then run this again."
fi

BACKUP=""
if [ "${APP_ONLY}" = "0" ]; then
  [ "${TARGET}" = "${RECORDED}" ] && BACKUP="$(recorded_pre_upgrade_backup)"
  if [ -z "${BACKUP}" ] || [ ! -f "${BACKUP}" ]; then
    die "no pre-upgrade backup of ${TARGET} is recorded${BACKUP:+ (${BACKUP} is gone)}" \
        "Restore one yourself — the newest from before the upgrade:" \
        "  ls -lt ${BACKUPS_DIR}/tasksense-pre-upgrade-*.tar.gz" \
        "  then: set TASKSENSE_VERSION=${TARGET} in ${ENV_FILE} and ./scripts/restore.sh <archive>" \
        "Or switch the application only, keeping today's data:  ./scripts/rollback.sh ${TARGET} --app-only"
  fi
fi

step "Roll back ${CURRENT} → ${TARGET}"
if [ "${APP_ONLY}" = "1" ]; then
  warn "APPLICATION ONLY: the database stays as ${CURRENT} left it"
  warn "if ${CURRENT}'s migrations changed it, ${TARGET} runs against data it may not understand"
  note "to go back WITH the data from before the upgrade, run this without --app-only"
else
  BACKUP_DATE="$(tar xzOf "${BACKUP}" ./manifest.json 2>/dev/null | sed -n 's/.*"createdAt": *"\([^"]*\)".*/\1/p' | head -n1)"
  cat <<EOF
  Restores    ${BACKUP}
  Taken       ${BACKUP_DATE:-unknown}, just before the upgrade to ${CURRENT}
EOF
  warn "everything users changed since ${BACKUP_DATE:-that backup} is LOST (a safety backup of the current state is taken first)"
fi
confirm "Continue?" || { info "cancelled — nothing was changed"; exit 0; }

IMAGE="$(app_image "${TARGET}")"
if ! "${RUNTIME}" image inspect "${IMAGE}" >/dev/null 2>&1; then
  ensure_registry_login
  "${RUNTIME}" pull "${IMAGE}" || die "${IMAGE} is not on this host and could not be pulled — nothing was changed" \
    "Offline: ./scripts/load-images.sh --offline from the ${TARGET} bundle first."
fi

if [ "${APP_ONLY}" = "1" ]; then
  stop_app_tier
  env_set "${ENV_FILE}" TASKSENSE_VERSION "${TARGET}"
  ok "TASKSENSE_VERSION=${TARGET}"
  compose_up || { compose logs --tail 40 migrate app || true; die "${TARGET} did not start" "Put ${CURRENT} back:  ./scripts/upgrade.sh ${CURRENT}"; }
  if ! wait_for_health 240; then
    compose logs --tail 40 app || true
    die "${TARGET} did not come up healthy" \
        "Most likely the database has been migrated past what ${TARGET} understands." \
        "Roll back with the data instead:  ./scripts/rollback.sh ${TARGET}   (needs the pre-upgrade backup)" \
        "Or return to ${CURRENT}:  ./scripts/upgrade.sh ${CURRENT}"
  fi
  case "$(schema_state)" in
    ahead) warn "the application reports the schema as AHEAD of ${TARGET}: the database was migrated by ${CURRENT}" ;;
  esac
else
  env_set "${ENV_FILE}" TASKSENSE_VERSION "${TARGET}"
  ok "TASKSENSE_VERSION=${TARGET}"
  if ! "${SCRIPT_DIR}/restore.sh" --yes "${BACKUP}"; then
    die "the restore did not complete — TASKSENSE_VERSION is ${TARGET}" \
        "The output above says why. The state from before this rollback is in ${BACKUPS_DIR}/tasksense-pre-restore-*.tar.gz" \
        "Back to ${CURRENT} with that data:  set TASKSENSE_VERSION=${CURRENT}, then ./scripts/restore.sh <that archive>"
  fi
fi

# Consumed: a second rollback would otherwise "restore" the same backup over
# whatever happened since.
rm -f "${STATE_FILE}"
step "Rolled back to ${TARGET}"
running_version | sed 's/^/  /'
note "to move forward again: ./scripts/upgrade.sh ${CURRENT}"
