#!/usr/bin/env bash
#
# Takes a full, restorable backup: database, uploaded files and configuration.
#
#   ./scripts/backup.sh                         → backups/tasksense-<timestamp>.tar.gz
#   ./scripts/backup.sh --output /mnt/nfs/tasksense
#   ./scripts/backup.sh --no-config             omit .env (it holds secrets)
#   ./scripts/backup.sh --stop-app              stop app and worker during the dump, then start them again
#   ./scripts/backup.sh --keep 30               keep the newest 30 archives of this kind (default 14, 0 = all)
#   ./scripts/backup.sh --label pre-upgrade     → tasksense-pre-upgrade-<timestamp>.tar.gz
#
# Both database layouts: the bundled MongoDB is dumped inside its container;
# your own (MONGODB_URI) through a throwaway MongoDB-tools container
# ($MONGO_IMAGE) that reaches it the way the application does — its account
# needs read on MONGODB_DB (the application's readWrite covers it). No password appears on a
# command line here, either way.
#
# Without --stop-app the dump is taken live: fine for a nightly copy, but a
# write landing mid-dump may be half in it. upgrade.sh stops the application
# first, so the copy it restores from is exact.
#
# This is the disaster-recovery path. The application's own nightly
# per-workspace snapshots exclude credentials and file contents; they cannot
# rebuild an installation. This can. The archive holds the database and, unless
# --no-config, STORAGE_SECRET: store it where you would store a database dump
# (docs/07-BACKUP-DR.md).

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

OUTPUT_DIR="${BACKUPS_DIR}"
INCLUDE_CONFIG=1
STOP_APP=0
KEEP=14
LABEL=""
RECORD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output)     OUTPUT_DIR="${2:?--output needs a directory}"; shift 2 ;;
    --no-config)  INCLUDE_CONFIG=0; shift ;;
    --stop-app)   STOP_APP=1; shift ;;
    --keep)       KEEP="${2:?--keep needs a number}"; shift 2 ;;
    --label)      LABEL="${2:?--label needs a name}"; shift 2 ;;
    # For upgrade.sh and restore.sh: write the archive's path to this file.
    --record)     RECORD="${2:?--record needs a file}"; shift 2 ;;
    -h|--help)    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown option: $1" "Run with --help." ;;
  esac
done
case "${KEEP}" in ''|*[!0-9]*) die "--keep takes a number (0 keeps everything)" ;; esac
case "${LABEL}" in *[!a-z0-9-]*) die "--label takes lower-case letters, digits and -" ;; esac

detect_runtime
require_env_file
migrate_legacy_env

umask 077
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
STAMP="$(date -u +%Y%m%d-%H%M%SZ)"
NAME="tasksense-${LABEL:+${LABEL}-}${STAMP}.tar.gz"
ARCHIVE="${OUTPUT_DIR}/${NAME}"
# Staged beside the archive, not in /tmp: a dump is as large as the database,
# and /tmp is often a small tmpfs.
STAGE="$(mktemp -d "${OUTPUT_DIR}/.tasksense-backup.XXXXXX")"

VERSION="$(env_value TASKSENSE_VERSION)"
DB="$(mongo_db_name)"
STARTED_MONGO=0
STOPPED_APP=0

finish() {
  local rc=$?
  rm -rf "${STAGE}"
  if [ "${STARTED_MONGO}" = "1" ]; then
    "${RUNTIME}" stop -t 60 "${MONGO_CONTAINER}" >/dev/null 2>&1 || true
  fi
  if [ "${STOPPED_APP}" = "1" ]; then
    step "Starting the application again"
    if ! { compose_up >/dev/null && wait_for_health 180; }; then
      warn "the application did not come back healthy — ./scripts/install.sh, or docs/10-TROUBLESHOOTING.md"
    fi
  fi
  [ "${rc}" -eq 0 ] || rm -f "${ARCHIVE}"
  return "${rc}"
}
trap finish EXIT

step "Backing up TaskSense ${VERSION}"

if [ "${STOP_APP}" = "1" ]; then
  if container_running "${APP_CONTAINER}" || container_running "${WORKER_CONTAINER}"; then
    step "Stopping the application for a consistent copy"
    stop_app_tier
    STOPPED_APP=1
    ok "app and worker stopped"
  fi
fi
if container_running "${APP_CONTAINER}" || container_running "${WORKER_CONTAINER}"; then
  CONSISTENT=false
else
  CONSISTENT=true
fi

# ── Database ─────────────────────────────────────────────────────────────────
step "Database ${DB}"

if external_database; then
  DB_MODE=external
  URI="$(env_value MONGODB_URI)"
  DB_SOURCE="$(uri_redacted "${URI}")"
  note "your own MongoDB: ${DB_SOURCE}, via $(mongo_image)"
  # `--db` beside a URI that names a database is refused, so the path goes and
  # the database is named on its own; mongo_uri_without_db keeps the auth db.
  # shellcheck disable=SC2016  # $CFG and $TS_DB expand inside the container
  TS_DB="${DB}" with_mongo_tools "$(mongo_uri_without_db "${URI}")" \
    "${MONGO_CFG_FROM_URI}"$'\n''mongodump --quiet --config "$CFG" --db "$TS_DB" --archive --gzip' \
    > "${STAGE}/mongodb.archive.gz" \
    || die "mongodump against your MongoDB failed — nothing was written" \
           "The account needs read on ${DB} — the application's readWrite is enough, see docs/16-EXTERNAL-DATABASES.md; the output above names the cause." \
           "Reachability and TLS: ./scripts/preflight.sh. docs/16-EXTERNAL-DATABASES.md."
else
  DB_MODE=bundled
  DB_SOURCE="bundled"
  if ! container_running "${MONGO_CONTAINER}"; then
    note "the bundled MongoDB is stopped — starting it for the dump only"
    compose up -d --wait mongo >/dev/null || die "could not start the bundled MongoDB" "${COMPOSE[*]} logs mongo"
    STARTED_MONGO=1
  fi
  # Inside the container, which publishes no port, so the host needs no
  # MongoDB tooling. The root password is read from the container's own
  # environment into a config file — never an argument, which `ps` would show.
  # shellcheck disable=SC2016  # expanded inside the container
  compose exec -T -e TS_DB="${DB}" mongo sh -c \
    "${MONGO_CFG_FROM_ROOT_PASSWORD}"$'\n''mongodump --quiet --config "$CFG" --username "$MONGO_INITDB_ROOT_USERNAME" --authenticationDatabase admin --db "$TS_DB" --archive --gzip' \
    > "${STAGE}/mongodb.archive.gz" \
    || die "mongodump failed — nothing was written" "${COMPOSE[*]} logs mongo"
fi

DB_BYTES="$(wc -c < "${STAGE}/mongodb.archive.gz" | tr -d ' ')"
# An empty archive is a few dozen bytes of header: a dump that "succeeded" with
# nothing in it — the wrong database name, most often — must not pass as a backup.
[ "${DB_BYTES}" -gt 256 ] || die "the dump of ${DB} is only ${DB_BYTES} bytes — refusing to write a backup that cannot restore" \
  "Is MONGODB_DB the database the application uses? ($(mongo_db_name))"
ok "database dumped ($((DB_BYTES / 1024)) KB compressed)"

# ── Uploaded files and app data ──────────────────────────────────────────────
# From the volume itself, in a throwaway container, so it works whether or not
# the application is running. data/tmp is the upload staging area — Jira
# backups of many gigabytes in transit — and is not data.
step "Files"
"${RUNTIME}" volume inspect "${APP_VOLUME}" >/dev/null 2>&1 \
  || die "there is no ${APP_VOLUME} volume — has TaskSense ever been started on this host?"
"${RUNTIME}" run --rm --network none --entrypoint tar -v "${APP_VOLUME}:/app/api/data:ro" "$(app_image)" \
  czf - -C /app/api --exclude=data/tmp data > "${STAGE}/app-data.tar.gz" \
  || die "could not archive the ${APP_VOLUME} volume"
ok "uploads and in-app snapshots archived ($(( $(wc -c < "${STAGE}/app-data.tar.gz") / 1024 )) KB)"

# ── Configuration ────────────────────────────────────────────────────────────
if [ "${INCLUDE_CONFIG}" = "1" ]; then
  cp "${ENV_FILE}" "${STAGE}/env"
  ok "configuration included"
  warn "this archive contains STORAGE_SECRET and database credentials in clear text"
else
  note "configuration omitted (--no-config)"
  warn "without STORAGE_SECRET a restore cannot decrypt stored provider credentials — keep that value somewhere safe"
fi

# ── Manifest ─────────────────────────────────────────────────────────────────
# restore.sh reads it to refuse a restore into an older version and to name
# the database the dump came from. Flat keys first: they are read with sed.
RUNNING="$(running_version)"
cat > "${STAGE}/manifest.json" <<EOF
{
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "version": "${VERSION}",
  "host": "$(hostname)",
  "dbMode": "${DB_MODE}",
  "database": "${DB}",
  "dbSource": "${DB_SOURCE}",
  "consistent": ${CONSISTENT},
  "includesConfig": $([ "${INCLUDE_CONFIG}" = "1" ] && echo true || echo false),
  "contents": ["mongodb.archive.gz", "app-data.tar.gz"$([ "${INCLUDE_CONFIG}" = "1" ] && echo ', "env"')],
  "runningVersion": ${RUNNING:-null}
}
EOF

tar czf "${ARCHIVE}" -C "${STAGE}" .
chmod 600 "${ARCHIVE}"
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "${OUTPUT_DIR}" && sha256sum "${NAME}" > "${NAME}.sha256" )
else
  ( cd "${OUTPUT_DIR}" && shasum -a 256 "${NAME}" > "${NAME}.sha256" )
fi
[ -n "${RECORD}" ] && printf '%s\n' "${ARCHIVE}" > "${RECORD}"

# ── Rotation ─────────────────────────────────────────────────────────────────
# Only archives of the same kind: a nightly --keep never removes the copy an
# upgrade took, and the reverse.
if [ "${KEEP}" -gt 0 ]; then
  if [ -n "${LABEL}" ]; then PATTERN="tasksense-${LABEL}-[0-9]*Z.tar.gz"; else PATTERN="tasksense-[0-9]*Z.tar.gz"; fi
  # shellcheck disable=SC2012,SC2086  # our own sortable names; the pattern is meant to glob
  OLD="$(cd "${OUTPUT_DIR}" && ls -1 ${PATTERN} 2>/dev/null | sort -r | tail -n +$((KEEP + 1)) || true)"
  for f in ${OLD}; do
    rm -f "${OUTPUT_DIR}/${f}" "${OUTPUT_DIR}/${f}.sha256"
    note "rotated out ${f}"
  done
fi

step "Done"
ok "${ARCHIVE}"
note "$(du -h "${ARCHIVE}" | cut -f1)$([ "${CONSISTENT}" = "true" ] && echo ", taken with the application stopped" || echo ", taken live")"
printf '\n  Restore with:  ./scripts/restore.sh %s\n\n' "${ARCHIVE}"
