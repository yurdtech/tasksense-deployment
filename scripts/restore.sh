#!/usr/bin/env bash
#
# Restores an installation from a backup archive taken by backup.sh.
#
#   ./scripts/restore.sh backups/tasksense-20261016-120000Z.tar.gz
#   ./scripts/restore.sh <archive> --yes                 no questions (automation, upgrade.sh)
#   ./scripts/restore.sh <archive> --no-safety-backup    skip the copy of the current state
#
# This REPLACES the database and the uploaded files. In order:
#
#   1. stop the app and the worker — nothing writes while data is replaced
#   2. take a safety backup of the current state (unless --no-safety-backup),
#      so a restore aimed at the wrong host or the wrong archive is recoverable
#   3. drop the whole MONGODB_DB database, then restore the dump into it —
#      the bundled MongoDB, or your own (MONGODB_URI) through a tools container
#   4. replace the uploaded files on the data volume
#   5. start: the migrate step brings an older backup's schema forward, then
#      the application starts on it
#
# compose/.env is never overwritten. If the archive's configuration differs
# where it matters (STORAGE_SECRET), it is saved beside the backups for you to
# reconcile, and the restore says so.

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ARCHIVE=""
SAFETY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)           ASSUME_YES=1; shift ;;
    --no-safety-backup) SAFETY=0; shift ;;
    -h|--help)          sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)                 die "unknown option: $1" "Run with --help." ;;
    *)                  [ -z "${ARCHIVE}" ] || die "one archive at a time"; ARCHIVE="$1"; shift ;;
  esac
done
[ -n "${ARCHIVE}" ] || die "usage: restore.sh <archive.tar.gz> [--yes] [--no-safety-backup]" \
  "List available backups:  ls -lt ${BACKUPS_DIR}"
[ -f "${ARCHIVE}" ] || die "no such file: ${ARCHIVE}"
ARCHIVE="$(cd "$(dirname "${ARCHIVE}")" && pwd)/$(basename "${ARCHIVE}")"

detect_runtime
require_env_file
migrate_legacy_env

# The checksum backup.sh wrote beside it, when it is there: an archive that was
# copied off-host and back is worth checking before it replaces anything.
if [ -f "${ARCHIVE}.sha256" ]; then
  EXPECTED="$(awk '{print $1}' "${ARCHIVE}.sha256")"
  if command -v sha256sum >/dev/null 2>&1; then ACTUAL="$(sha256sum "${ARCHIVE}" | awk '{print $1}')"
  else ACTUAL="$(shasum -a 256 "${ARCHIVE}" | awk '{print $1}')"; fi
  [ "${EXPECTED}" = "${ACTUAL}" ] || die "${ARCHIVE} does not match its .sha256 — it is damaged or was changed" \
    "Use another copy. Nothing has been touched."
  ok "archive matches its checksum"
fi

umask 077
mkdir -p "${BACKUPS_DIR}"
STAGE="$(mktemp -d "${BACKUPS_DIR}/.tasksense-restore.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT
tar xzf "${ARCHIVE}" -C "${STAGE}" || die "could not read ${ARCHIVE} — is it a TaskSense backup?"
[ -f "${STAGE}/manifest.json" ] || [ -f "${STAGE}/app-data.tar.gz" ] \
  || die "${ARCHIVE} does not look like a TaskSense backup"

# `head -n1` matters: the manifest embeds the /version response too, which has
# its own "version" key, so an unrestricted match returns two values.
manifest_value() {
  sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "${STAGE}/manifest.json" 2>/dev/null | head -n1
}
BACKUP_VERSION="$(manifest_value version)"; BACKUP_VERSION="${BACKUP_VERSION:-unknown}"
BACKUP_DATE="$(manifest_value createdAt)"; BACKUP_DATE="${BACKUP_DATE:-unknown}"
SRC_DB="$(manifest_value database)"; SRC_DB="${SRC_DB:-tasksense}"
CONSISTENT="$(sed -n 's/.*"consistent": *\([a-z]*\).*/\1/p' "${STAGE}/manifest.json" 2>/dev/null | head -n1)"
CURRENT_VERSION="$(env_value TASKSENSE_VERSION)"
DB="$(mongo_db_name)"
HAS_DUMP=0; [ -f "${STAGE}/mongodb.archive.gz" ] && HAS_DUMP=1

if external_database; then
  TARGET_DESC="your own MongoDB $(uri_redacted "$(env_value MONGODB_URI)"), database ${DB}"
else
  TARGET_DESC="the bundled MongoDB, database ${DB}"
fi

step "Restore"
cat <<EOF
  Archive     ${ARCHIVE}
  Taken       ${BACKUP_DATE}$([ "${CONSISTENT}" = "false" ] && echo "  (live — the application was running)")
  From        TaskSense ${BACKUP_VERSION}, database ${SRC_DB}
  Into        TaskSense ${CURRENT_VERSION}, ${TARGET_DESC}
EOF

# Old data into a newer application is normal — the migrate step brings it
# forward. The reverse is not: a newer backup can hold shapes the older code
# does not understand, and it will not fail loudly, it will misbehave.
if [ "${BACKUP_VERSION}" != "unknown" ] && [ "${BACKUP_VERSION}" != "${CURRENT_VERSION}" ]; then
  if [ "$(version_cmp "${BACKUP_VERSION}" "${CURRENT_VERSION}")" = "1" ]; then
    die "the backup is from ${BACKUP_VERSION}, newer than the configured ${CURRENT_VERSION}" \
        "Upgrade first, then restore:" \
        "  ./scripts/upgrade.sh ${BACKUP_VERSION}"
  fi
  note "the backup predates ${CURRENT_VERSION} — its migrations run when the application starts"
fi

if [ "${HAS_DUMP}" = "0" ]; then
  # 1.0 took no dump of an external database; such an archive is files and
  # configuration only.
  warn "this archive has no database dump — only the uploaded files will be restored; the database stays as it is"
fi

printf '\n'
warn "this replaces $([ "${HAS_DUMP}" = "1" ] && echo "database ${DB} and ")the uploaded files"
if [ "${HAS_DUMP}" = "1" ] && external_database; then
  warn "database ${DB} on your own MongoDB is DROPPED and recreated from the archive"
fi
confirm "Continue?" || { info "cancelled — nothing was changed"; exit 0; }
confirm "This host runs ${CURRENT_VERSION}. Overwrite its data with the archive from ${BACKUP_DATE}?" \
  || { info "cancelled — nothing was changed"; exit 0; }

# ── 1. Stop writers ──────────────────────────────────────────────────────────
step "Stopping the application"
stop_app_tier
ok "app and worker stopped"
RESTARTED=0
on_exit() {
  local rc=$?
  rm -rf "${STAGE}"
  if [ "${rc}" -ne 0 ] && [ "${RESTARTED}" = "0" ]; then
    printf '\n' >&2
    warn "the application is left STOPPED — the data may be half restored"
    [ -n "${SAFETY_ARCHIVE:-}" ] && warn "the state before this restore is in ${SAFETY_ARCHIVE}"
  fi
  return "${rc}"
}
trap on_exit EXIT

# ── 2. Safety net ────────────────────────────────────────────────────────────
SAFETY_ARCHIVE=""
if [ "${SAFETY}" = "1" ]; then
  step "Saving the current state first"
  RECORD="${STAGE}/safety-path"
  if "${SCRIPT_DIR}/backup.sh" --output "${BACKUPS_DIR}" --label pre-restore --keep 5 --record "${RECORD}" >/dev/null 2>&1; then
    SAFETY_ARCHIVE="$(cat "${RECORD}")"
    ok "current state saved: ${SAFETY_ARCHIVE}"
  else
    warn "could not back up the current state (is the database reachable?)"
    confirm "Proceed WITHOUT a safety backup?" || { info "cancelled — the application is stopped; start it with ./tasksense or ./scripts/install.sh"; RESTARTED=1; exit 0; }
  fi
else
  note "no safety backup (--no-safety-backup)"
fi

# ── 3. Database ──────────────────────────────────────────────────────────────
RENAME=""
if [ "${SRC_DB}" != "${DB}" ]; then
  # shellcheck disable=SC2016  # expanded inside the container
  RENAME=' --nsFrom "$TS_SRC_DB.*" --nsTo "$TS_DB.*"'
  note "the dump is of database ${SRC_DB}; it is restored as ${DB} (MONGODB_DB)"
fi
# shellcheck disable=SC2016  # expanded inside the container
RESTORE_ARGS='--archive --gzip --drop --stopOnError --nsInclude "$TS_SRC_DB.*"'"${RENAME}"

if [ "${HAS_DUMP}" = "1" ]; then
  step "Database ${DB}"
  if external_database; then
    # Dropped first, whole: mongorestore --drop only replaces the collections
    # that are in the archive, and would leave any others behind. mongosh reads
    # the URI from the environment; the tools read it from a config file.
    # shellcheck disable=SC2016  # expanded inside the container
    DROP_JS='const r = new Mongo(process.env.TS_MONGO_URI).getDB(process.env.TS_DB).dropDatabase(); if (!r.ok) quit(1);'
    # shellcheck disable=SC2016  # expanded inside the container
    INNER="set -e"$'\n'"mongosh --nodb --quiet --norc --eval '${DROP_JS}' >/dev/null"$'\n'"${MONGO_CFG_FROM_URI}"$'\n''mongorestore --quiet --config "$CFG" '"${RESTORE_ARGS}"
    TS_DB="${DB}" TS_SRC_DB="${SRC_DB}" with_mongo_tools "$(mongo_uri_without_db "$(env_value MONGODB_URI)")" "${INNER}" \
      < "${STAGE}/mongodb.archive.gz" \
      || die "restoring into your MongoDB failed — the application is still stopped" \
             "The account needs readWrite and dbAdmin on ${DB} (dbAdmin carries dropDatabase) — see docs/16-EXTERNAL-DATABASES.md; the output above names the cause." \
             "${SAFETY_ARCHIVE:+The state before this restore: ${SAFETY_ARCHIVE}}"
  else
    if ! container_running "${MONGO_CONTAINER}"; then
      compose up -d --wait mongo >/dev/null || die "could not start the bundled MongoDB" "${COMPOSE[*]} logs mongo"
    fi
    compose exec -T -e TS_DB="${DB}" mongo mongosh --quiet --norc --eval \
      'db.getSiblingDB("admin").auth(process.env.MONGO_INITDB_ROOT_USERNAME, process.env.MONGO_INITDB_ROOT_PASSWORD); const r = db.getSiblingDB(process.env.TS_DB).dropDatabase(); if (!r.ok) quit(1);' >/dev/null \
      || die "could not drop database ${DB} in the bundled MongoDB — the application is still stopped" \
             "${COMPOSE[*]} logs mongo"
    # shellcheck disable=SC2016  # expanded inside the container
    compose exec -T -e TS_DB="${DB}" -e TS_SRC_DB="${SRC_DB}" mongo sh -c \
      "${MONGO_CFG_FROM_ROOT_PASSWORD}"$'\n''mongorestore --quiet --config "$CFG" --username "$MONGO_INITDB_ROOT_USERNAME" --authenticationDatabase admin '"${RESTORE_ARGS}" \
      < "${STAGE}/mongodb.archive.gz" \
      || die "mongorestore failed — the application is still stopped" \
             "${SAFETY_ARCHIVE:+The state before this restore: ${SAFETY_ARCHIVE}}"
  fi
  ok "database ${DB} dropped and restored"
fi

# ── 4. Files ─────────────────────────────────────────────────────────────────
if [ -f "${STAGE}/app-data.tar.gz" ]; then
  step "Files"
  # Into the volume through a throwaway container: the application is
  # stopped, and its own container has a read-only root anyway. Everything is
  # replaced except data/tmp, the upload staging area.
  # shellcheck disable=SC2016  # runs inside the container
  "${RUNTIME}" run --rm -i --network none --entrypoint sh -v "${APP_VOLUME}:/app/api/data" "$(app_image)" -c \
    'set -e; find /app/api/data -mindepth 1 -maxdepth 1 ! -name tmp -exec rm -rf {} +; tar xzf - -C /app/api' \
    < "${STAGE}/app-data.tar.gz" \
    || die "could not restore the uploaded files — the database is restored, the application is still stopped" \
           "See docs/10-TROUBLESHOOTING.md."
  ok "uploaded files restored"
fi

# ── Configuration ────────────────────────────────────────────────────────────
if [ -f "${STAGE}/env" ]; then
  if [ "$(env_value STORAGE_SECRET "${STAGE}/env")" != "$(env_value STORAGE_SECRET)" ]; then
    KEPT="${BACKUPS_DIR}/env-from-$(basename "${ARCHIVE}" .tar.gz)"
    cp "${STAGE}/env" "${KEPT}"
    chmod 600 "${KEPT}"
    warn "STORAGE_SECRET in the archive differs from ${ENV_FILE}"
    note "credentials stored in the database were encrypted with the archive's value and will not decrypt"
    note "the archive's configuration is saved at ${KEPT} — put its STORAGE_SECRET into ${ENV_FILE}, then restart"
  fi
fi

# ── 5. Start ─────────────────────────────────────────────────────────────────
step "Starting"
RESTARTED=1
compose_up || {
  compose logs --tail 40 migrate app 2>/dev/null || true
  die "the stack did not start — the log above names the cause" \
      "${SAFETY_ARCHIVE:+The state before this restore: ${SAFETY_ARCHIVE}}"
}

step "Verifying"
if wait_for_health 240; then
  running_version | sed 's/^/  /'
  step "Restored"
  ok "data from ${BACKUP_DATE} is live"
  if [ -n "${SAFETY_ARCHIVE}" ]; then note "the state before this restore: ${SAFETY_ARCHIVE}"; fi
else
  compose logs --tail 40 app || true
  die "the application did not come back healthy" \
      "${SAFETY_ARCHIVE:+The state before this restore: ${SAFETY_ARCHIVE}}"
fi
