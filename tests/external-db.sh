#!/usr/bin/env bash
#
# Using a MongoDB the customer already runs.
#
#   tests/external-db.sh
#
# docs/04-CONFIGURATION.md said of MONGODB_URI: "Point at your own cluster if you
# have one." It could not be done. The compose file set MONGODB_URI in its
# `environment:` block, which outranks `env_file:`, so a URI written into .env
# was read, ignored, and silently replaced with the bundled container's — no
# error, no warning, and an installation quietly using the wrong database.
#
# These check the two halves of the fix against `docker compose config`, which
# is what the daemon is actually handed: that a URI in .env wins, and that the
# bundled database can be left unstarted rather than running unused beside a
# cluster nobody asked it to duplicate.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v docker >/dev/null 2>&1 || { printf '\n  SKIPPED: docker is not installed\n\n'; exit 0; }

printf '\nan external MongoDB\n\n'

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  \033[31m✗\033[0m %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

# compose/.env is the operator's file and must survive this.
ENV="${ROOT}/compose/.env"
BACKUP=""
if [ -f "${ENV}" ]; then BACKUP="$(mktemp)"; cp "${ENV}" "${BACKUP}"; fi
restore() {
  if [ -n "${BACKUP}" ]; then cp "${BACKUP}" "${ENV}"; rm -f "${BACKUP}"; else rm -f "${ENV}"; fi
}
trap restore EXIT

write_env() {  # write_env [extra lines…]
  sed -e 's/^STORAGE_SECRET=$/STORAGE_SECRET=0123456789012345678901234567890123456789/' \
      -e 's/^MONGO_PASSWORD=$/MONGO_PASSWORD=0123456789abcdef0123456789abcdef/' \
      "${ROOT}/compose/.env.example" > "${ENV}"
  for line in "$@"; do printf '%s\n' "${line}" >> "${ENV}"; done
}

uri_of() {
  docker compose -f "${ROOT}/compose/docker-compose.yml" config 2>/dev/null \
    | awk '/MONGODB_URI:/ { $1=""; sub(/^ /,""); print; exit }'
}

# ── 1. the bundled default, unchanged ────────────────────────────────────────

write_env
check "without MONGODB_URI the bundled database is addressed" \
  "mongodb://tasksense:0123456789abcdef0123456789abcdef@mongo:27017/?authSource=admin" "$(uri_of)"

# ── 2. an operator's own cluster wins ────────────────────────────────────────

THEIRS="mongodb://tasksense:pw@mongo-0.bank.internal:27017,mongo-1.bank.internal:27017/?replicaSet=rs0&tls=true&authSource=admin"
write_env "MONGODB_URI=${THEIRS}"
check "with MONGODB_URI set, theirs is used" "${THEIRS}" "$(uri_of)"

# The whole failure, stated once: it is not enough that the value is in the
# file, it has to reach the container.
check "and the bundled host is nowhere in it" "0" \
  "$(printf '%s' "$(uri_of)" | grep -c '@mongo:27017')"

# ── 3. the bundled database is not started ───────────────────────────────────
#
# Against a stand-in image, not ours.
#
# `--dry-run` still resolves images, so on a machine where ghcr.io/…/tasksense
# is not cached it stops at "Image … Error not found" and narrates nothing
# further. The first version of this checked for "tasksense-app  Created" and
# passed only where the image happened to be pulled — and the mongo assertion
# beside it then passed for no reason at all, because the run never got that
# far. What is under test here is the compose wiring, so the application's image
# is deliberately something any machine can fetch.
STANDIN=("TASKSENSE_IMAGE=busybox" "TASKSENSE_VERSION=latest")

write_env "MONGODB_URI=${THEIRS}" "${STANDIN[@]}"
out="$(cd "${ROOT}/compose" && docker compose up -d --scale mongo=0 --dry-run 2>&1)"

# --dry-run narrates both "Creating" and "Created"; match the finished one.
check "the application is created" "1" "$(printf '%s' "${out}" | grep -c 'tasksense-app  *Created')"
check "and the database container is not" "0" "$(printf '%s' "${out}" | grep -c 'tasksense-mongo')"

# The reason --scale is used rather than a compose profile: a profiled service
# in depends_on makes compose reject the entire project, so the two assertions
# above could never both hold. This is that difference, asserted.
( cd "${ROOT}/compose" && docker compose config >/dev/null 2>&1 )
check "and the project is still valid with the database scaled away" "0" "$?"

# Without --scale the database is part of the plan, so the check above is
# measuring the flag rather than the absence of a service.
out="$(cd "${ROOT}/compose" && docker compose up -d --dry-run 2>&1)"
check "unscaled, the bundled database would be created" "1" \
  "$(printf '%s' "${out}" | grep -c 'tasksense-mongo  *Created')"

# ── 4. the scripts know which of the two it is ───────────────────────────────

probe() {  # probe <expect: external|bundled>
  docker run --rm -v "${ROOT}:/w:ro" -w /w bash:5 bash -c '
    . scripts/lib.sh
    if external_database; then echo external; else echo bundled; fi' 2>/dev/null
}

write_env "MONGODB_URI=${THEIRS}"
check "external_database says external" "external" "$(probe)"
write_env
check "and bundled when there is no URI" "bundled" "$(probe)"

# The credentials for a database somebody else administers are not ours to
# demand — install.sh used to refuse to start without them.
write_env "MONGODB_URI=${THEIRS}" "MONGO_USER=" "MONGO_PASSWORD="
out="$(docker run --rm -v "${ROOT}:/w:ro" -w /w bash:5 bash -c '
  . scripts/lib.sh
  if external_database; then
    require_env_values TASKSENSE_VERSION APP_URL STORAGE_SECRET
  else
    require_env_values TASKSENSE_VERSION APP_URL STORAGE_SECRET MONGO_USER MONGO_PASSWORD
  fi
  echo ACCEPTED' 2>&1)"
check "an external database needs no MONGO_USER or MONGO_PASSWORD" "1" \
  "$(printf '%s' "${out}" | grep -c '^ACCEPTED$')"

printf '\n  %s passed, %s failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
