#!/usr/bin/env bash
#
# Restores an installation from a backup archive.
#
#   ./scripts/restore.sh backups/tasksense-20260801-120000Z.tar.gz
#
# This REPLACES the current database and uploaded files. It asks twice, and it
# takes a safety backup of what is there now before overwriting anything — so a
# restore aimed at the wrong host is recoverable.

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ARCHIVE="${1:-}"
[ -n "${ARCHIVE}" ] || die "usage: restore.sh <archive.tar.gz>" \
  "List available backups:  ls -lh ${ROOT_DIR}/backups"
[ -f "${ARCHIVE}" ] || die "no such file: ${ARCHIVE}"

detect_runtime
require_env_file

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
tar xzf "${ARCHIVE}" -C "${STAGE}" || die "could not read ${ARCHIVE} — is it a TaskSense backup?"
[ -f "${STAGE}/mongodb.archive.gz" ] || die "${ARCHIVE} has no database dump in it"

# `head -n1` matters: the manifest embeds the /version response too, which has
# its own "version" key, so an unrestricted match returns two values and every
# comparison below silently misbehaves.
manifest_value() {
  sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "${STAGE}/manifest.json" 2>/dev/null | head -n1
}
BACKUP_VERSION="$(manifest_value version)"; BACKUP_VERSION="${BACKUP_VERSION:-unknown}"
BACKUP_DATE="$(manifest_value createdAt)"; BACKUP_DATE="${BACKUP_DATE:-unknown}"
CURRENT_VERSION="$(env_value TASKSENSE_VERSION)"

step "Restore"
cat <<EOF
  Archive     ${ARCHIVE}
  Taken       ${BACKUP_DATE}
  From        TaskSense ${BACKUP_VERSION}
  Into        TaskSense ${CURRENT_VERSION}
EOF

# Restoring old data into a newer application is normal — startup migrations
# handle it. The reverse is not: a newer backup can contain shapes the older
# code does not understand, and it will not fail loudly, it will misbehave.
if [ "${BACKUP_VERSION}" != "unknown" ] && [ "${BACKUP_VERSION}" != "${CURRENT_VERSION}" ]; then
  OLDEST="$(printf '%s\n%s\n' "${BACKUP_VERSION}" "${CURRENT_VERSION}" | sort -V | head -n1)"
  if [ "${OLDEST}" = "${CURRENT_VERSION}" ]; then
    die "the backup is from ${BACKUP_VERSION}, newer than the installed ${CURRENT_VERSION}" \
        "Upgrade first, then restore:" \
        "  ./scripts/upgrade.sh ${BACKUP_VERSION}"
  fi
  warn "the backup predates the installed version — migrations will run on first start"
fi

printf '\n'
warn "this deletes the current database and uploaded files"
confirm "Continue?" || { info "cancelled"; exit 0; }
confirm "This host currently runs ${CURRENT_VERSION}. Overwrite its data — are you sure?" \
  || { info "cancelled"; exit 0; }

# ── Safety net ───────────────────────────────────────────────────────────────
step "Backing up current state first"
SAFETY="${ROOT_DIR}/backups/pre-restore-$(date -u +%Y%m%d-%H%M%SZ).tar.gz"
if "${SCRIPT_DIR}/backup.sh" --output "${ROOT_DIR}/backups" >/dev/null 2>&1; then
  ok "current state saved under ${ROOT_DIR}/backups"
else
  warn "could not back up the current state (the stack may not be running)"
  confirm "Proceed without a safety backup?" || { info "cancelled"; exit 0; }
fi

MONGO_USER="$(env_value MONGO_USER)"
MONGO_PASSWORD="$(env_value MONGO_PASSWORD)"

step "Stopping the application"
# Only the app: mongo has to stay up to receive the restore.
compose stop app

step "Database"
compose exec -T mongo mongorestore \
  --username "${MONGO_USER}" --password "${MONGO_PASSWORD}" \
  --authenticationDatabase admin \
  --drop --archive --gzip < "${STAGE}/mongodb.archive.gz" \
  || die "mongorestore failed — the application is still stopped" \
         "Your previous data is in ${SAFETY%/*}/"
ok "database restored"

if [ -f "${STAGE}/app-data.tar.gz" ]; then
  step "Files"
  compose start app >/dev/null
  sleep 3
  compose exec -T app tar xzf - -C /app/api < "${STAGE}/app-data.tar.gz" \
    || warn "could not restore uploaded files — the database is restored; see docs/10-TROUBLESHOOTING.md"
  ok "uploads restored"
  compose restart app
else
  compose start app
fi

step "Verifying"
if wait_for_health 180; then
  running_version | sed 's/^/  /'
  step "Restored"
else
  compose logs --tail 40 app || true
  die "the application did not come back healthy" \
      "Your pre-restore state is in ${ROOT_DIR}/backups/"
fi
