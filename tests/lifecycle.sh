#!/usr/bin/env bash
#
# install → backup → upgrade → (failure and recovery) → rollback → restore,
# driven through the real scripts against a fake docker.
#
#   tests/lifecycle.sh
#
# What is under test is what the scripts DO, in what order, and what they SAY:
# that a backup is taken with the application stopped, that a failure after the
# migrations restores the data instead of claiming nothing was lost, that a
# restore drops the whole database before restoring into it, and that no
# password ever reaches a command line — the fake records every argv, which is
# exactly what `ps` on the host would have shown.
#
# Offline, no daemon, bash 3.2 or newer. Each case runs in a fresh sandbox copy
# of the repository; preflight is replaced there by a stub that passes, because
# its own suite (tests/preflight-checks.sh) covers it and the host running this
# should not decide whether an upgrade test passes.

# shellcheck disable=SC2016,SC2012  # the single-quoted snippets run in another shell; backups are listed by our own names

set -uo pipefail

# shellcheck source=helpers/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/common.sh"

printf '\nlifecycle: install, backup, upgrade, rollback, restore\n\n'

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
CASE=0
PASSWORD="0123456789abcdef0123456789abcdef"
SECRET="0123456789abcdefghijABCDEFGHIJ0123456789"
CUR="$(example_version)"

fresh() {  # fresh [fixture overrides…] — a new sandbox with a configured .env
  CASE=$((CASE + 1))
  sandbox "${WORK}/case-${CASE}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${SANDBOX}/scripts/preflight.sh"
  fixture_env "${SANDBOX}/compose/.env" "$@"
  unset FAKE_RUNNING FAKE_PENDING FAKE_BAD_VERSION FAKE_BAD_STAGE FAKE_DUMP_FAIL FAKE_IMAGE_RC FAKE_SCHEMA
}
envv() { sed -n "s/^$1=//p" "${SANDBOX}/compose/.env" | tail -n1; }
newest() { ls -1t "${SANDBOX}"/backups/$1 2>/dev/null | head -n1; }
manifest() { tar xzOf "$1" ./manifest.json; }
before() {  # before <name> <regex-a> <regex-b> — the first call to a precedes the first to b
  local a b; a="$(call_line "$2")"; b="$(call_line "$3")"
  check "$1" "yes" "$([ "${a}" -gt 0 ] && [ "${b}" -gt 0 ] && [ "${a}" -lt "${b}" ] && echo yes || echo "no (lines ${a} and ${b})")"
}

# ══ install ══════════════════════════════════════════════════════════════════
printf '  install\n'

fresh
out="$("${SANDBOX}/scripts/install.sh" 2>&1)"; rc=$?
check "bundled: installs" "0" "${rc}"
contains "bundled: pulls what the profiles use" "compose --env-file ${SANDBOX}/compose/.env pull" "$(docker_calls)"
contains "bundled: brings the stack up with compose up -d" "compose --env-file ${SANDBOX}/compose/.env up -d" "$(docker_calls)"
lacks "and never with the old --no-deps special case" "--no-deps" "$(docker_calls)"

fresh "COMPOSE_PROFILES=" "MONGO_USER=" "MONGO_PASSWORD=" "MONGODB_URI=mongodb://ts:Sup3rS3cret@db.abb.invalid/?authSource=admin"
export FAKE_RUNNING="tasksense-mongo" FAKE_IMAGE_RC=1
out="$("${SANDBOX}/scripts/install.sh" 2>&1)"; rc=$?
check "external: installs without MONGO_USER / MONGO_PASSWORD" "0" "${rc}"
before "external: a bundled MongoDB left running from before is stopped first" "^stop -t 45 tasksense-mongo" " up -d$"
contains "external: the tools image backups need is fetched" "pull mongo:7" "$(docker_calls)"
lacks "external: the password is in no command line" "Sup3rS3cret" "$(docker_calls)"

fresh
export FAKE_RUNNING="tasksense-worker"
"${SANDBOX}/scripts/install.sh" >/dev/null 2>&1
before "a worker whose profile was switched off is stopped" "^stop -t 45 tasksense-worker" " up -d$"

fresh "MONGO_PASSWORD="
out="$("${SANDBOX}/scripts/install.sh" 2>&1)"; rc=$?
check "bundled without a password: refused" "1" "${rc}"
contains "naming it" "missing required values: MONGO_PASSWORD" "${out}"

# ══ backup ═══════════════════════════════════════════════════════════════════
printf '\n  backup\n'

fresh
export FAKE_RUNNING="tasksense-app tasksense-mongo"
out="$("${SANDBOX}/scripts/backup.sh" 2>&1)"; rc=$?
A="$(newest 'tasksense-[0-9]*Z.tar.gz')"
check "bundled: a backup is written" "0" "${rc}"
check "readable by its owner only" "600" "$(mode_of "${A}")"
check "with a checksum beside it" "ok" "$(cd "$(dirname "${A}")" && { sha256sum -c "$(basename "${A}").sha256" >/dev/null 2>&1 || shasum -a 256 -c "$(basename "${A}").sha256" >/dev/null 2>&1; } && echo ok)"
check "holding the dump, the files, the configuration and a manifest" "./app-data.tar.gz ./env ./manifest.json ./mongodb.archive.gz" \
  "$(tar tzf "${A}" | grep -v '^\./$' | sort | tr '\n' ' ' | sed 's/ $//')"
M="$(manifest "${A}")"
contains "manifest: version" "\"version\": \"${CUR}\"" "${M}"
contains "manifest: the bundled database, by name" "\"dbMode\": \"bundled\"" "${M}"
contains "manifest: which database" "\"database\": \"tasksense\"" "${M}"
contains "manifest: taken live — the app was running" "\"consistent\": false" "${M}"
contains "the dump runs inside the mongo container" "exec -T -e TS_DB=tasksense mongo sh -c" "$(docker_calls)"
contains "the files come from the volume, read-only, with no network" "run --rm --network none --entrypoint tar -v tasksense-app-data:/app/api/data:ro" "$(docker_calls)"
contains "the upload staging area is left out" "--exclude=data/tmp" "$(docker_calls)"
lacks "no password in any command line" "${PASSWORD}" "$(docker_calls)"
lacks "nor the storage secret" "${SECRET}" "$(docker_calls)"

fresh
export FAKE_RUNNING="tasksense-app tasksense-worker tasksense-mongo"
"${SANDBOX}/scripts/backup.sh" --stop-app >/dev/null 2>&1
A="$(newest 'tasksense-[0-9]*Z.tar.gz')"
contains "--stop-app: consistent" "\"consistent\": true" "$(manifest "${A}")"
before "--stop-app: the worker is stopped before the dump" "^stop -t 45 tasksense-worker" "mongodump"
before "--stop-app: and the app" "^stop -t 45 tasksense-app" "mongodump"
before "--stop-app: and both started again after" "mongodump" " up -d$"

fresh "COMPOSE_PROFILES=" "MONGO_USER=" "MONGO_PASSWORD=" "MONGODB_DB=tasks_prod" \
  "MONGODB_URI=mongodb://ts:Sup3rS3cret@db.abb.invalid:27017/admin?replicaSet=rs0&tls=true&tlsCAFile=/certs/bank-ca.pem"
out="$("${SANDBOX}/scripts/backup.sh" 2>&1)"; rc=$?
A="$(newest 'tasksense-[0-9]*Z.tar.gz')"
check "external: a backup is written" "0" "${rc}"
contains "external: dumped through a throwaway tools container" "run --rm -i -e TS_MONGO_URI -e TS_DB -e TS_SRC_DB -v ${SANDBOX}/compose/certs:/certs:ro --entrypoint sh mongo:7 -c" "$(docker_calls)"
lacks "external: the password is in no command line" "Sup3rS3cret" "$(docker_calls)"
contains "external: the URI travelled in the environment instead" "Sup3rS3cret" "$(cat "${FAKE_LOG}.env" 2>/dev/null)"
contains "external: without the path database, which stays the auth database" \
  "TS_MONGO_URI=mongodb://ts:Sup3rS3cret@db.abb.invalid:27017/?replicaSet=rs0&tls=true&tlsCAFile=/certs/bank-ca.pem&authSource=admin" \
  "$(cat "${FAKE_LOG}.env" 2>/dev/null)"
M="$(manifest "${A}")"
contains "manifest: external, the database named by MONGODB_DB" "\"database\": \"tasks_prod\"" "${M}"
lacks "manifest: no password in it" "Sup3rS3cret" "${M}"

fresh
export FAKE_RUNNING="tasksense-mongo" FAKE_DUMP_FAIL=1
out="$("${SANDBOX}/scripts/backup.sh" 2>&1)"; rc=$?
check "a failed dump fails the backup" "1" "${rc}"
check "and leaves no archive that looks like one" "" "$(newest 'tasksense-*.tar.gz')"

fresh
export FAKE_RUNNING="tasksense-mongo"
"${SANDBOX}/scripts/backup.sh" --label pre-upgrade >/dev/null 2>&1
for _ in 1 2 3; do "${SANDBOX}/scripts/backup.sh" --keep 2 >/dev/null 2>&1; sleep 1; done
check "--keep 2 keeps two" "2" "$(ls -1 "${SANDBOX}"/backups/tasksense-[0-9]*Z.tar.gz | wc -l | tr -d ' ')"
check "and their checksums only" "2" "$(ls -1 "${SANDBOX}"/backups/tasksense-[0-9]*Z.tar.gz.sha256 | wc -l | tr -d ' ')"
check "and never touches a different kind" "1" "$(ls -1 "${SANDBOX}"/backups/tasksense-pre-upgrade-*Z.tar.gz | wc -l | tr -d ' ')"

# ══ restore ══════════════════════════════════════════════════════════════════
printf '\n  restore\n'

fresh "COMPOSE_PROFILES=bundled-mongo,import-worker" "WORKER_ROLE=api"
export FAKE_RUNNING="tasksense-mongo"
"${SANDBOX}/scripts/backup.sh" >/dev/null 2>&1
A="$(newest 'tasksense-[0-9]*Z.tar.gz')"
: > "${FAKE_LOG}"
export FAKE_RUNNING="tasksense-app tasksense-worker tasksense-mongo"
out="$("${SANDBOX}/scripts/restore.sh" "${A}" --yes --no-safety-backup 2>&1)"; rc=$?
check "restores" "0" "${rc}"
before "1. the worker stops first" "^stop -t 45 tasksense-worker" "^stop -t 45 tasksense-app"
before "2. then the app, before the database is touched" "^stop -t 45 tasksense-app" "dropDatabase"
before "3. the whole database is dropped before the restore" "dropDatabase" "mongorestore"
before "4. the database before the files" "mongorestore" "tar xzf"
before "5. and only then does anything start" "tar xzf" " up -d$"
contains "the restore is limited to the dumped database" '--nsInclude "$TS_SRC_DB.*"' "$(docker_calls)"
lacks "no password in any command line" "${PASSWORD}" "$(docker_calls)"

fresh
export FAKE_RUNNING="tasksense-mongo"
"${SANDBOX}/scripts/backup.sh" >/dev/null 2>&1
A="$(newest 'tasksense-[0-9]*Z.tar.gz')"
"${SANDBOX}/scripts/restore.sh" "${A}" --yes >/dev/null 2>&1
check "a safety backup of the current state is taken by default" "1" "$(ls -1 "${SANDBOX}"/backups/tasksense-pre-restore-*Z.tar.gz 2>/dev/null | wc -l | tr -d ' ')"

fresh
export FAKE_RUNNING="tasksense-mongo"
"${SANDBOX}/scripts/backup.sh" >/dev/null 2>&1
A="$(newest 'tasksense-[0-9]*Z.tar.gz')"
fixture_env "${SANDBOX}/compose/.env" "STORAGE_SECRET=a-different-secret-that-is-at-least-32-chars"
out="$("${SANDBOX}/scripts/restore.sh" "${A}" --yes --no-safety-backup 2>&1)"
contains "a different STORAGE_SECRET is called out" "STORAGE_SECRET in the archive differs" "${out}"
check "and the archive's configuration kept for reconciling" "1" "$(ls -1 "${SANDBOX}"/backups/env-from-* 2>/dev/null | wc -l | tr -d ' ')"
check "while compose/.env is left alone" "a-different-secret-that-is-at-least-32-chars" "$(envv STORAGE_SECRET)"

fixture_env "${SANDBOX}/compose/.env" "TASKSENSE_VERSION=1.0.9"
out="$("${SANDBOX}/scripts/restore.sh" "${A}" --yes 2>&1)"; rc=$?
check "a backup from a newer version is refused" "1" "${rc}"
contains "with the way forward" "Upgrade first, then restore" "${out}"

printf 'garbage' > "${A}.bad.tar.gz"; cp "${A}.sha256" "${A}.bad.tar.gz.sha256"
out="$("${SANDBOX}/scripts/restore.sh" "${A}.bad.tar.gz" --yes 2>&1)"; rc=$?
check "an archive that fails its checksum is refused before anything happens" "1" "${rc}"

fresh "COMPOSE_PROFILES=" "MONGO_USER=" "MONGO_PASSWORD=" "MONGODB_URI=mongodb://ts:Sup3rS3cret@db.abb.invalid/?authSource=admin"
"${SANDBOX}/scripts/backup.sh" >/dev/null 2>&1
A="$(newest 'tasksense-[0-9]*Z.tar.gz')"
: > "${FAKE_LOG}"; rm -f "${FAKE_LOG}.env"
out="$("${SANDBOX}/scripts/restore.sh" "${A}" --yes --no-safety-backup 2>&1)"; rc=$?
check "external: restores into your MongoDB" "0" "${rc}"
contains "external: drop and restore in one tools container" "dropDatabase" "$(docker_calls)"
lacks "external: the password is in no command line" "Sup3rS3cret" "$(docker_calls)"

# ══ upgrade ══════════════════════════════════════════════════════════════════
printf '\n  upgrade\n'
NEXT="$(printf '%s' "${CUR}" | awk -F. '{ printf "%d.%d.0", $1, $2 + 1 }')"
SKIP="$(printf '%s' "${CUR}" | awk -F. '{ printf "%d.%d.0", $1, $2 + 3 }')"

fresh
out="$("${SANDBOX}/scripts/upgrade.sh" 1.0.5 2>&1)"; rc=$?
check "a lower version is refused" "1" "${rc}"
contains "and pointed at rollback.sh" "that is a rollback, not an upgrade" "${out}"
out="$("${SANDBOX}/scripts/upgrade.sh" "${CUR}" 2>&1)"; rc=$?
check "the same version is refused" "1" "${rc}"
out="$("${SANDBOX}/scripts/upgrade.sh" next 2>&1)"; rc=$?
check "a non-version is refused" "1" "${rc}"
check "and none of them changed anything" "${CUR}" "$(envv TASKSENSE_VERSION)"

fresh
export FAKE_RUNNING="tasksense-app tasksense-mongo" FAKE_PENDING=2 FAKE_IMAGE_RC=1
out="$("${SANDBOX}/scripts/upgrade.sh" "${NEXT}" 2>&1)"; rc=$?
check "upgrades" "0" "${rc}"
check "TASKSENSE_VERSION is switched" "${NEXT}" "$(envv TASKSENSE_VERSION)"
before "the new image is fetched while the old version still serves" "^pull ghcr.io/yurdtech/tasksense:${NEXT}" "^stop -t 45 tasksense-app"
before "the app is stopped before the backup" "^stop -t 45 tasksense-app" "mongodump"
before "the backup is taken before the migrations" "mongodump" "run --rm -T migrate$"
before "the migrations run before the app starts" "run --rm -T migrate$" " up -d$"
B="$(newest 'tasksense-pre-upgrade-*Z.tar.gz')"
contains "the pre-upgrade backup is exact" "\"consistent\": true" "$(manifest "${B}")"
check "the way back is recorded" "${CUR} backup=${B}" "$(tr '\n' ' ' < "${SANDBOX}/.previous-version" | sed 's/ $//')"
contains "and named" "./scripts/rollback.sh" "${out}"

fresh
out="$(FAKE_PENDING=0 "${SANDBOX}/scripts/upgrade.sh" "${SKIP}" 2>&1)"; rc=$?
check "skipping releases is allowed" "0" "${rc}"
contains "and explained" "every migration in between is applied, in order" "${out}"

fresh
export FAKE_RUNNING="tasksense-app tasksense-mongo" FAKE_PENDING=3 FAKE_BAD_VERSION="${NEXT}" FAKE_BAD_STAGE=up
out="$("${SANDBOX}/scripts/upgrade.sh" "${NEXT}" 2>&1)"; rc=$?
check "a version that fails after its migrations: exit 1" "1" "${rc}"
contains "the data is restored, not left migrated" "with the database restored" "${out}"
contains "and the claim that nothing was lost says why it is true" "the application was stopped before the backup was taken" "${out}"
before "the pre-upgrade backup is what is restored" "run --rm -T migrate$" "mongorestore"
check "the previous version is configured again" "${CUR}" "$(envv TASKSENSE_VERSION)"

fresh
export FAKE_RUNNING="tasksense-app tasksense-mongo" FAKE_PENDING=1 FAKE_BAD_VERSION="${NEXT}" FAKE_BAD_STAGE=migrate
out="$("${SANDBOX}/scripts/upgrade.sh" "${NEXT}" 2>&1)"; rc=$?
check "a failed migration: exit 1" "1" "${rc}"
contains "names the failure" "the migrations of ${NEXT} failed" "${out}"
contains "and restores the backup" "with the database restored" "${out}"

fresh
export FAKE_RUNNING="tasksense-app tasksense-mongo" FAKE_PENDING=0 FAKE_BAD_VERSION="${NEXT}" FAKE_BAD_STAGE=up
out="$("${SANDBOX}/scripts/upgrade.sh" "${NEXT}" 2>&1)"; rc=$?
check "a failure with nothing pending: exit 1" "1" "${rc}"
contains "says nothing was lost, and why that is true" "no migration was pending, so the database is as ${CUR} left it" "${out}"
lacks "and restores nothing it does not need to" "mongorestore" "$(docker_calls)"
check "the previous version is configured again" "${CUR}" "$(envv TASKSENSE_VERSION)"

fresh
export FAKE_RUNNING="tasksense-app tasksense-mongo" FAKE_DUMP_FAIL=1
out="$("${SANDBOX}/scripts/upgrade.sh" "${NEXT}" 2>&1)"; rc=$?
check "a failed backup stops the upgrade" "1" "${rc}"
contains "before anything changed" "the backup failed, so nothing was upgraded" "${out}"
check "the version is untouched" "${CUR}" "$(envv TASKSENSE_VERSION)"
lacks "and no migration ran" "run --rm -T migrate" "$(docker_calls)"

# ══ rollback ═════════════════════════════════════════════════════════════════
printf '\n  rollback\n'

fresh
export FAKE_RUNNING="tasksense-app tasksense-mongo" FAKE_PENDING=2
"${SANDBOX}/scripts/upgrade.sh" "${NEXT}" >/dev/null 2>&1
B="$(newest 'tasksense-pre-upgrade-*Z.tar.gz')"
: > "${FAKE_LOG}"
out="$("${SANDBOX}/scripts/rollback.sh" --yes 2>&1)"; rc=$?
check "rolls back" "0" "${rc}"
check "to the recorded version" "${CUR}" "$(envv TASKSENSE_VERSION)"
contains "with the data: the pre-upgrade backup is restored" "Restores    ${B}" "${out}"
contains "after saying what that costs" "everything users changed since" "${out}"
contains "the restore ran" "mongorestore" "$(docker_calls)"
check "a safety copy of the newer state is taken first" "1" "$(ls -1 "${SANDBOX}"/backups/tasksense-pre-restore-*Z.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
check "and the record is consumed" "no" "$([ -f "${SANDBOX}/.previous-version" ] && echo yes || echo no)"

fresh
export FAKE_RUNNING="tasksense-app tasksense-mongo" FAKE_PENDING=2
"${SANDBOX}/scripts/upgrade.sh" "${NEXT}" >/dev/null 2>&1
: > "${FAKE_LOG}"
out="$(FAKE_SCHEMA=ahead "${SANDBOX}/scripts/rollback.sh" --app-only --yes 2>&1)"; rc=$?
check "--app-only rolls the application back" "0" "${rc}"
contains "with an explicit warning" "APPLICATION ONLY: the database stays as ${NEXT} left it" "${out}"
contains "and the schema state reported" "schema as AHEAD of ${CUR}" "${out}"
lacks "and no data restored" "mongorestore" "$(docker_calls)"

fresh
printf '%s\n' "1.0.0" > "${SANDBOX}/.previous-version"
out="$("${SANDBOX}/scripts/rollback.sh" --yes 2>&1)"; rc=$?
check "no recorded backup: refused" "1" "${rc}"
contains "with both ways forward named" "--app-only" "${out}"

fresh "COMPOSE_PROFILES=bundled-mongo,import-worker" "WORKER_ROLE=api"
out="$("${SANDBOX}/scripts/rollback.sh" 1.0.0 --app-only --yes 2>&1)"; rc=$?
check "back to 1.0 with the import worker on: refused" "1" "${rc}"
contains "because 1.0 has none" "has no import worker" "${out}"

out="$("${SANDBOX}/scripts/rollback.sh" "${NEXT}" --app-only --yes 2>&1)"; rc=$?
check "a newer version is not a rollback" "1" "${rc}"

finish
