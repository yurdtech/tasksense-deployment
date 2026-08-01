#!/usr/bin/env bash
#
# Reinstalling over an old database volume.
#
#   tests/stale-volume.sh
#
# MongoDB writes its username and password exactly once, when it first creates
# its data directory. Every later start ignores MONGO_INITDB_ROOT_PASSWORD
# entirely. So the second attempt at an install — with a new password, against
# the first attempt's volume — fails with:
#
#   Error: Cannot reach MongoDB at mongodb://tasksense:235ca6…@mongo:27017/…:
#   MongoServerError: Authentication failed.
#
# which is true and useless. The password in .env really is the password, and it
# really is refused. Nothing in that sentence mentions a volume, and the volume
# is the whole story.
#
# The first case here is the behaviour, checked against a real mongo. The rest
# check that we say so.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v docker >/dev/null 2>&1 || { printf '\n  SKIPPED: docker is not installed\n\n'; exit 0; }

printf '\nreinstalling over an old database volume\n\n'

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  \033[31m✗\033[0m %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

VOL=tasksense-test-stale-vol
cleanup() { docker rm -f ts-stale >/dev/null 2>&1; docker volume rm -f "${VOL}" >/dev/null 2>&1; }
trap cleanup EXIT
cleanup

# ── 1. the behaviour itself ──────────────────────────────────────────────────
# Asserted rather than assumed. If a future mongo image starts honouring a
# changed password, the warning below becomes wrong and should be removed —
# this is what would tell us.

docker volume create "${VOL}" >/dev/null
docker run -d --name ts-stale -v "${VOL}:/data/db" \
  -e MONGO_INITDB_ROOT_USERNAME=tasksense -e MONGO_INITDB_ROOT_PASSWORD=first-password \
  mongo:7 --auth --bind_ip_all >/dev/null 2>&1
for _ in $(seq 1 40); do
  docker exec ts-stale mongosh --quiet -u tasksense -p first-password --authenticationDatabase admin \
    --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1 && break
  sleep 1
done
docker rm -f ts-stale >/dev/null 2>&1

# Same volume, new password — exactly what a second install attempt does.
docker run -d --name ts-stale -v "${VOL}:/data/db" \
  -e MONGO_INITDB_ROOT_USERNAME=tasksense -e MONGO_INITDB_ROOT_PASSWORD=second-password \
  mongo:7 --auth --bind_ip_all >/dev/null 2>&1
sleep 6

docker exec ts-stale mongosh --quiet -u tasksense -p second-password --authenticationDatabase admin \
  --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1
check "the new password is refused by the existing volume" "1" "$?"

docker exec ts-stale mongosh --quiet -u tasksense -p first-password --authenticationDatabase admin \
  --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1
check "and the one it was created with still works" "0" "$?"

cleanup

# ── 2. that we notice ────────────────────────────────────────────────────────

out="$(docker run --rm -v "${ROOT}:/w:ro" -w /w -e MONGO_VOLUME="${VOL}" bash:5 bash -c '
  {
    echo "#!/usr/bin/env bash"
    echo "case \"\$1 \$2\" in"
    echo "  \"compose version\") exit 0 ;;"
    echo "  \"volume inspect\") exit 0 ;;"   # pretend the volume is there
    echo "esac"
    echo "exit 0"
  } > /tmp/docker && chmod +x /tmp/docker && export PATH=/tmp:$PATH
  . scripts/lib.sh
  detect_runtime
  if mongo_volume_exists; then echo "FOUND"; fi
  explain_stale_mongo_volume
' 2>&1)"

check "the volume is detected" "1" "$(printf '%s' "${out}" | grep -c '^FOUND$')"
# Matched against the text with its line breaks removed: the message is wrapped
# for a terminal, and a phrase that reads as one sentence is not one line.
FLAT="$(printf '%s' "${out}" | tr '\n' ' ' | tr -s ' ')"
check "the explanation names the cause, not the symptom" "1" \
  "$(printf '%s' "${FLAT}" | grep -c 'only when it first creates its data directory')"
check "and gives the command, with the flag that matters" "1" \
  "$(printf '%s' "${out}" | grep -c 'down -v')"
check "and says what -v does, since omitting it repeats the failure" "1" \
  "$(printf '%s' "${out}" | grep -c 'without it the volume survives')"
check "and covers the case where the data is wanted" "1" \
  "$(printf '%s' "${out}" | grep -c 'original password back')"

# Absent volume, no noise: most installs are on a clean host and must not be
# told about a problem they do not have.
out="$(docker run --rm -v "${ROOT}:/w:ro" -w /w -e MONGO_VOLUME=definitely-not-here bash:5 bash -c '
  {
    echo "#!/usr/bin/env bash"
    echo "case \"\$1 \$2\" in"
    echo "  \"compose version\") exit 0 ;;"
    echo "  \"volume inspect\") exit 1 ;;"
    echo "esac"
    echo "exit 0"
  } > /tmp/docker && chmod +x /tmp/docker && export PATH=/tmp:$PATH
  . scripts/lib.sh
  detect_runtime
  if mongo_volume_exists; then echo "FOUND"; else echo "ABSENT"; fi
' 2>&1)"
check "and says nothing when there is no volume" "1" "$(printf '%s' "${out}" | grep -c '^ABSENT$')"

printf '\n  %s passed, %s failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
