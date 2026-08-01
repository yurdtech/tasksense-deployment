#!/usr/bin/env bash
#
# Goes back to the version that was running before the last upgrade.
#
#   ./scripts/rollback.sh
#   ./scripts/rollback.sh 1.0.0     roll back to a specific version
#
# This changes the application version only. It does not restore data — if the
# newer version ran a migration, rolling the code back leaves a database the
# older version may not understand. When in doubt, restore the backup that
# upgrade.sh took instead: ./scripts/restore.sh

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

detect_runtime
require_env_file

CURRENT="$(env_value TASKSENSE_VERSION)"
TARGET="${1:-}"
if [ -z "${TARGET}" ]; then
  [ -f "${ROOT_DIR}/.previous-version" ] || die "no previous version recorded" \
    "Name one explicitly:  ./scripts/rollback.sh <version>"
  TARGET="$(cat "${ROOT_DIR}/.previous-version")"
fi

step "Roll back ${CURRENT} → ${TARGET}"
warn "this reverts the application only — data and schema changes stay as they are"
note "to undo a migration too, restore a backup instead: ls -t ${ROOT_DIR}/backups/"
confirm "Continue?" || { info "cancelled"; exit 0; }

IMAGE="$(env_value TASKSENSE_IMAGE)"; IMAGE="${IMAGE:-ghcr.io/yurdtech/tasksense}"
if ! "${RUNTIME}" image inspect "${IMAGE}:${TARGET}" >/dev/null 2>&1; then
  "${RUNTIME}" pull "${IMAGE}:${TARGET}" || die "${TARGET} is not available locally or in the registry"
fi

sed -i.tmp "s/^TASKSENSE_VERSION=.*/TASKSENSE_VERSION=${TARGET}/" "${ENV_FILE}" && rm -f "${ENV_FILE}.tmp"
compose up -d

if wait_for_health 240; then
  running_version | sed 's/^/  /'
  printf '%s\n' "${CURRENT}" > "${ROOT_DIR}/.previous-version"
  step "Rolled back to ${TARGET}"
else
  compose logs --tail 40 app || true
  die "${TARGET} did not come up healthy" \
      "Most likely the database has already been migrated past what ${TARGET} understands." \
      "Restore the backup from before the upgrade:" \
      "  ls -t ${ROOT_DIR}/backups/ | head -3"
fi
