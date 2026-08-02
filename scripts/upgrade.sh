#!/usr/bin/env bash
#
# Upgrades to a new version, with a backup first and an automatic rollback if
# the new version does not come up healthy.
#
#   ./scripts/upgrade.sh 1.1.0
#   ./scripts/upgrade.sh 1.1.0 --offline    load the image from ./images
#
# What it does, in order: back up → pull → switch version → start → wait for
# health. If health never arrives it puts the previous version back and stops.
# Your data is never touched by a failed upgrade; the backup covers the case
# where a migration ran before the failure.

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TARGET="${1:-}"
[ -n "${TARGET}" ] || die "usage: upgrade.sh <version> [--offline]" \
  "Releases: https://github.com/yurdtech/tasksense-deployment/releases"
shift
OFFLINE=0
for arg in "$@"; do
  case "${arg}" in
    --offline) OFFLINE=1 ;;
    *) die "unknown option: ${arg}" ;;
  esac
done

detect_runtime
require_env_file
CURRENT="$(env_value TASKSENSE_VERSION)"

step "Upgrade ${CURRENT} → ${TARGET}"

[ "${CURRENT}" != "${TARGET}" ] || die "already on ${TARGET}"

# Refuse to jump versions. Migrations are written to run in order, and skipping
# a minor release means skipping its migration — which usually does not fail, it
# just leaves the database subtly wrong.
CURRENT_MAJOR="${CURRENT%%.*}"; TARGET_MAJOR="${TARGET%%.*}"
CURRENT_MINOR="$(printf '%s' "${CURRENT}" | cut -d. -f2)"
TARGET_MINOR="$(printf '%s' "${TARGET}" | cut -d. -f2)"
if [ "${CURRENT_MAJOR}" != "${TARGET_MAJOR}" ]; then
  warn "this crosses a major version — read the release notes before continuing"
  confirm "Continue?" || exit 0
elif [ "$((TARGET_MINOR - CURRENT_MINOR))" -gt 1 ] 2>/dev/null; then
  die "cannot go from ${CURRENT} straight to ${TARGET}" \
      "Upgrade one minor version at a time:" \
      "  ./scripts/upgrade.sh ${CURRENT_MAJOR}.$((CURRENT_MINOR + 1)).0" \
      "See docs/08-UPGRADE.md for the supported paths."
fi

step "Backup"
"${SCRIPT_DIR}/backup.sh" --output "${ROOT_DIR}/backups" \
  || die "backup failed — not upgrading" "An upgrade without a restore point is not worth the risk."

step "Fetching ${TARGET}"
if [ "${OFFLINE}" = "1" ]; then
  "${SCRIPT_DIR}/load-images.sh" --offline
else
  IMAGE="$(env_value TASKSENSE_IMAGE)"; IMAGE="${IMAGE:-ghcr.io/yurdtech/tasksense}"
  "${RUNTIME}" pull "${IMAGE}:${TARGET}" || die "could not pull ${IMAGE}:${TARGET}" \
    "Check the version exists, or use --offline with a release archive."
fi

# Record the rollback target where rollback.sh can find it, before changing .env.
printf '%s\n' "${CURRENT}" > "${ROOT_DIR}/.previous-version"

step "Switching"
# In place, keeping a copy: a botched sed on this file breaks every secret.
cp "${ENV_FILE}" "${ENV_FILE}.bak"
sed -i.tmp "s/^TASKSENSE_VERSION=.*/TASKSENSE_VERSION=${TARGET}/" "${ENV_FILE}" && rm -f "${ENV_FILE}.tmp"
ok "TASKSENSE_VERSION=${TARGET}"

compose_up

step "Verifying"
if wait_for_health 240; then
  running_version | sed 's/^/  /'
  rm -f "${ENV_FILE}.bak"
  step "Upgraded to ${TARGET}"
  note "roll back with:  ./scripts/rollback.sh"
  exit 0
fi

# ── Automatic rollback ───────────────────────────────────────────────────────
printf '\n'
warn "${TARGET} did not become healthy — rolling back to ${CURRENT}"
compose logs --tail 40 app || true

mv "${ENV_FILE}.bak" "${ENV_FILE}"
compose_up

if wait_for_health 240; then
  die "upgrade to ${TARGET} failed; ${CURRENT} is running again" \
      "Nothing was lost. The log above should say why ${TARGET} would not start." \
      "A backup from just before the attempt is in ${ROOT_DIR}/backups/."
fi

die "upgrade to ${TARGET} failed AND ${CURRENT} did not come back" \
    "Restore from the backup taken at the start of this run:" \
    "  ls -t ${ROOT_DIR}/backups/ | head -1" \
    "  ./scripts/restore.sh ${ROOT_DIR}/backups/<that file>"
