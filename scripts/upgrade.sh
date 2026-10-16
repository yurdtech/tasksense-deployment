#!/usr/bin/env bash
#
# Upgrades to a newer version, with a consistent backup first and a way back
# if the new version fails.
#
#   ./scripts/upgrade.sh 1.2.0
#   ./scripts/upgrade.sh 1.2.0 --offline    load the images from ./images (offline bundle)
#   ./scripts/upgrade.sh 1.2.0 --yes        no questions; on failure, restore automatically
#
# In order:
#
#   1. preflight against the target version
#   2. fetch the target images — while the old version is still serving
#   3. stop the app and the worker, then back up (database, files, .env), so
#      the copy is exact: nothing writes after it is taken
#   4. switch TASKSENSE_VERSION and run the target's migrations (one-shot)
#   5. start, and wait for health
#
# If anything fails before step 4, the old version is started again and
# nothing has changed. If it fails after the migrations ran, the database may
# already be in the new version's shape, which the old one may not read — so
# the pre-upgrade backup is restored together with the old version (asked,
# default yes; automatic with --yes). Skipping releases is fine: migrations
# apply in order. Going back to an older version is rollback.sh, not this.

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TARGET=""
OFFLINE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --offline) OFFLINE=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "unknown option: $1" "Run with --help." ;;
    *)         [ -z "${TARGET}" ] || die "one version at a time"; TARGET="${1#v}"; shift ;;
  esac
done
[ -n "${TARGET}" ] || die "usage: upgrade.sh <version> [--offline] [--yes]" \
  "Releases: https://github.com/yurdtech/tasksense-deployment/releases"
semver_valid "${TARGET}" || die "${TARGET} is not a release number" "Use the version from the release page, e.g. 1.2.0 — without a leading v."

detect_runtime
require_env_file
migrate_legacy_env
CURRENT="$(env_value TASKSENSE_VERSION)"

step "Upgrade ${CURRENT} → ${TARGET}"

[ "${CURRENT}" != "${TARGET}" ] || die "already on ${TARGET}"
semver_valid "${CURRENT}" || die "TASKSENSE_VERSION=${CURRENT} in ${ENV_FILE} is not a release number" \
  "Set it to the version that is actually installed, then run this again."
case "$(version_cmp "${TARGET}" "${CURRENT}")" in
  -1) die "${TARGET} is older than the installed ${CURRENT} — that is a rollback, not an upgrade" \
          "  ./scripts/rollback.sh            back to the version before the last upgrade, with its data" \
          "  ./scripts/rollback.sh ${TARGET}" ;;
esac
if [ "${CURRENT%%.*}" != "${TARGET%%.*}" ]; then
  warn "this crosses a major version — read the release notes for ${TARGET} before continuing"
  confirm "Continue?" || { info "cancelled — nothing was changed"; exit 0; }
fi
CUR_MINOR="$(printf '%s' "${CURRENT}" | cut -d. -f2)"; TGT_MINOR="$(printf '%s' "${TARGET}" | cut -d. -f2)"
if [ "${CURRENT%%.*}" = "${TARGET%%.*}" ] && [ $((TGT_MINOR - CUR_MINOR)) -gt 1 ] 2>/dev/null; then
  note "skipping releases is fine — every migration in between is applied, in order"
fi

# What has happened so far, so the message on the way out is the truth.
STAGE_REACHED=checks       # checks → stopped → backed-up → switched → migrating → starting → done
PENDING=""
BACKUP=""
RECORD="$(mktemp)"

on_exit() {
  local rc=$?
  rm -f "${RECORD}"
  if [ "${rc}" -ne 0 ] && [ "${STAGE_REACHED}" != "done" ] && [ "${STAGE_REACHED}" != "reported" ]; then
    printf '\n' >&2
    warn "the upgrade stopped at: ${STAGE_REACHED}"
    case "${STAGE_REACHED}" in
      checks)     warn "nothing was changed" ;;
      stopped)    warn "the application is stopped; nothing else changed — start it: ./tasksense, or ${COMPOSE[*]} up -d" ;;
      backed-up)  warn "the application is stopped; the database is untouched. Backup: ${BACKUP}" ;;
      *)          warn "TASKSENSE_VERSION may be ${TARGET} and migrations may have run. Backup: ${BACKUP:-none}"
                  warn "to go back with that data: ./scripts/rollback.sh" ;;
    esac
  fi
  return "${rc}"
}
trap on_exit EXIT

# ── 1. Preflight ─────────────────────────────────────────────────────────────
PREFLIGHT_ARGS=(--target-version "${TARGET}")
[ "${OFFLINE}" = "1" ] && PREFLIGHT_ARGS+=(--offline)
"${SCRIPT_DIR}/preflight.sh" "${PREFLIGHT_ARGS[@]}" || die "preflight failed — nothing was changed" \
  "Fix the lines marked ${MARK_BAD} above and run the upgrade again."

# ── 2. Images, while the old version still serves ────────────────────────────
step "Fetching ${TARGET}"
TARGET_IMAGE="$(app_image "${TARGET}")"
if [ "${OFFLINE}" = "1" ]; then
  "${SCRIPT_DIR}/load-images.sh" --offline || die "could not load the images — nothing was changed"
  "${RUNTIME}" image inspect "${TARGET_IMAGE}" >/dev/null 2>&1 || die "the offline bundle does not contain ${TARGET_IMAGE}" \
    "Unpack the bundle for ${TARGET} here (its images/ directory), then run this again."
else
  ensure_registry_login
  ensure_image "${TARGET_IMAGE}" || die "could not pull ${TARGET_IMAGE} — nothing was changed" \
    "Check the version exists, or use --offline with the offline bundle."
fi
if bundled_mongo_enabled || external_database; then
  # The bundled server, or the tools that back up your own MongoDB.
  ensure_image "$(mongo_image)" >/dev/null 2>&1 || warn "$(mongo_image) is not on this host — the backup step needs it"
fi
ok "${TARGET_IMAGE}"

# ── 3. Stop, then back up ────────────────────────────────────────────────────
step "Stopping the application"
stop_app_tier
STAGE_REACHED=stopped
ok "app and worker stopped — the backup that follows is exact"

restart_current() {
  env_set "${ENV_FILE}" TASKSENSE_VERSION "${CURRENT}"
  compose_up >/dev/null 2>&1 && wait_for_health 240
}

step "Backup"
if ! "${SCRIPT_DIR}/backup.sh" --output "${BACKUPS_DIR}" --label pre-upgrade --keep 5 --record "${RECORD}"; then
  STAGE_REACHED=reported
  if restart_current; then
    die "the backup failed, so nothing was upgraded — ${CURRENT} is running again" \
        "Nothing was changed. An upgrade without a restore point is not worth the risk; fix the cause above first."
  fi
  die "the backup failed, and ${CURRENT} did not come back up" \
      "Nothing was migrated. Start it and read why:  ${COMPOSE[*]} up -d && ${COMPOSE[*]} logs app"
fi
BACKUP="$(cat "${RECORD}")"
record_upgrade_state "${CURRENT}" "${BACKUP}"
STAGE_REACHED=backed-up

# ── 4. Switch and migrate ────────────────────────────────────────────────────
step "Switching to ${TARGET}"
cp "${ENV_FILE}" "${ENV_FILE}.bak"
env_set "${ENV_FILE}" TASKSENSE_VERSION "${TARGET}"
STAGE_REACHED=switched
ok "TASKSENSE_VERSION=${TARGET}"

step "Migrations"
PENDING="$(migration_pending_count)"
if [ -n "${PENDING}" ]; then note "${PENDING} migration(s) pending"; else note "could not count the pending migrations — assuming some"; fi
STAGE_REACHED=migrating
MIGRATE_OK=1
run_migrations || MIGRATE_OK=0

# ── Failure after the switch ─────────────────────────────────────────────────
recover() {
  local what="$1"
  STAGE_REACHED=reported
  printf '\n'
  warn "${what}"
  compose logs --tail 40 migrate app 2>/dev/null || true
  stop_app_tier || true

  if [ "${PENDING}" = "0" ]; then
    # Nothing was pending, so no migration touched the database.
    if restart_current; then
      rm -f "${ENV_FILE}.bak"
      die "the upgrade to ${TARGET} failed; ${CURRENT} is running again" \
          "Nothing was lost: no migration was pending, so the database is as ${CURRENT} left it." \
          "The log above should say why ${TARGET} would not start. Backup from just before: ${BACKUP}"
    fi
    die "the upgrade to ${TARGET} failed, AND ${CURRENT} did not come back" \
        "No migration ran, so the data is ${CURRENT}'s. Start it and read the log:  ${COMPOSE[*]} up -d; ${COMPOSE[*]} logs app" \
        "Backup from just before: ${BACKUP}"
  fi

  printf '\n'
  warn "${TARGET}'s migrations ran$([ -n "${PENDING}" ] && echo " (${PENDING} pending)") — the database may already be in a shape ${CURRENT} cannot read"
  note "the backup taken just before, with the application stopped, has every change users made: ${BACKUP}"
  if confirm_yes "Restore that backup and go back to ${CURRENT}?"; then
    env_set "${ENV_FILE}" TASKSENSE_VERSION "${CURRENT}"
    if "${SCRIPT_DIR}/restore.sh" --yes --no-safety-backup "${BACKUP}"; then
      rm -f "${ENV_FILE}.bak"
      die "the upgrade to ${TARGET} failed; ${CURRENT} is running again with the database restored" \
          "Nothing was lost: the application was stopped before the backup was taken, and no user could write after it." \
          "The log above should say why ${TARGET} failed. Send it with ./scripts/collect-diagnostics.sh to ${SUPPORT_EMAIL}."
    fi
    die "the upgrade to ${TARGET} failed, and restoring the backup failed too" \
        "The application is stopped. Restore by hand once the cause above is fixed:" \
        "  ./scripts/restore.sh ${BACKUP}"
  fi
  die "the upgrade to ${TARGET} failed — left as it is, for investigation" \
      "The application is stopped, TASKSENSE_VERSION=${TARGET}, and the database has ${TARGET}'s migrations." \
      "Back to ${CURRENT} with the data from before:  ./scripts/rollback.sh" \
      "Or retry once the cause is fixed:  ${COMPOSE[*]} up -d"
}

[ "${MIGRATE_OK}" = "1" ] || recover "the migrations of ${TARGET} failed"
ok "schema migrated"

# ── 5. Start and verify ──────────────────────────────────────────────────────
step "Starting ${TARGET}"
STAGE_REACHED=starting
compose_up || recover "${TARGET} did not start"

step "Verifying"
wait_for_health 240 || recover "${TARGET} did not become healthy within 240s"

STAGE_REACHED=done
running_version | sed 's/^/  /'
case "$(schema_state)" in
  ahead) warn "the application reports the schema as AHEAD of ${TARGET} — tell ${SUPPORT_EMAIL}" ;;
esac
rm -f "${ENV_FILE}.bak"
step "Upgraded to ${TARGET}"
note "backup from just before: ${BACKUP}"
note "back to ${CURRENT}, with that backup's data:  ./scripts/rollback.sh"
