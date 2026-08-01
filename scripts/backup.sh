#!/usr/bin/env bash
#
# Takes a full, restorable backup: database, uploaded files and configuration.
#
#   ./scripts/backup.sh                    → ./backups/tasksense-<timestamp>.tar.gz
#   ./scripts/backup.sh --output /mnt/nfs/tasksense
#   ./scripts/backup.sh --no-config        omit .env (it holds secrets)
#
# This is the disaster-recovery path. The application also writes its own
# nightly per-workspace snapshots, but those are a convenience for undoing a
# mistake inside the app — they deliberately exclude credentials, token hashes
# and uploaded file contents, so they cannot rebuild an installation. This can.
#
# The archive contains database passwords and the storage encryption key. Store
# it where you would store a database dump, and see docs/07-BACKUP-DR.md for
# encrypting it at rest.

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

OUTPUT_DIR="${ROOT_DIR}/backups"
INCLUDE_CONFIG=1
while [ $# -gt 0 ]; do
  case "$1" in
    --output)     OUTPUT_DIR="$2"; shift 2 ;;
    --no-config)  INCLUDE_CONFIG=0; shift ;;
    -h|--help)    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown option: $1" "Run with --help." ;;
  esac
done

detect_runtime
require_env_file

STAMP="$(date -u +%Y%m%d-%H%M%SZ)"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
ARCHIVE="${OUTPUT_DIR}/tasksense-${STAMP}.tar.gz"
mkdir -p "${OUTPUT_DIR}"

MONGO_USER="$(env_value MONGO_USER)"
MONGO_PASSWORD="$(env_value MONGO_PASSWORD)"
VERSION="$(env_value TASKSENSE_VERSION)"

step "Backing up TaskSense ${VERSION}"

# ── Database ─────────────────────────────────────────────────────────────────
# mongodump runs inside the container: the database publishes no port, and this
# way the host needs no MongoDB tooling installed.
step "Database"
compose exec -T mongo mongodump \
  --username "${MONGO_USER}" --password "${MONGO_PASSWORD}" \
  --authenticationDatabase admin \
  --db tasksense --archive --gzip > "${STAGE}/mongodb.archive.gz" \
  || die "mongodump failed" "Is the stack running?  ${COMPOSE[*]} ps"

DB_BYTES="$(wc -c < "${STAGE}/mongodb.archive.gz" | tr -d ' ')"
[ "${DB_BYTES}" -gt 1024 ] || die "the database dump is only ${DB_BYTES} bytes — refusing to write a backup that cannot restore"
ok "database dumped ($((DB_BYTES / 1024)) KB compressed)"

# ── Uploaded files and app data ──────────────────────────────────────────────
step "Files"
compose exec -T app tar czf - -C /app/api data > "${STAGE}/app-data.tar.gz" \
  || die "could not archive the application data volume"
ok "uploads and snapshots archived ($(( $(wc -c < "${STAGE}/app-data.tar.gz") / 1024 )) KB)"

# ── Configuration ────────────────────────────────────────────────────────────
if [ "${INCLUDE_CONFIG}" = "1" ]; then
  cp "${ENV_FILE}" "${STAGE}/env"
  ok "configuration included"
  warn "this archive contains MONGO_PASSWORD and STORAGE_SECRET in clear text"
else
  note "configuration omitted (--no-config)"
  warn "without STORAGE_SECRET a restore cannot decrypt stored provider credentials — keep that value somewhere safe"
fi

# ── Manifest ─────────────────────────────────────────────────────────────────
# restore.sh reads this to refuse a restore into an older version.
cat > "${STAGE}/manifest.json" <<EOF
{
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "version": "${VERSION}",
  "host": "$(hostname)",
  "includesConfig": $([ "${INCLUDE_CONFIG}" = "1" ] && echo true || echo false),
  "contents": ["mongodb.archive.gz", "app-data.tar.gz"$([ "${INCLUDE_CONFIG}" = "1" ] && echo ', "env"')],
  "runningVersion": $(running_version || echo null)
}
EOF

tar czf "${ARCHIVE}" -C "${STAGE}" .
chmod 600 "${ARCHIVE}"

step "Done"
ok "${ARCHIVE}"
note "$(du -h "${ARCHIVE}" | cut -f1)"
printf '\n  Restore with:  ./scripts/restore.sh %s\n\n' "${ARCHIVE}"
