#!/usr/bin/env bash
#
# Using a MongoDB the customer already runs.
#
#   tests/external-db.sh
#
# docs/04-CONFIGURATION.md once said of MONGODB_URI: "Point at your own cluster
# if you have one." It could not be done. The compose file set MONGODB_URI in
# its `environment:` block, which outranks `env_file:`, so a URI written into
# .env was read, ignored, and silently replaced with the bundled container's.
#
# Since 1.1 the bundled database is a compose profile: remove bundled-mongo from
# COMPOSE_PROFILES, set MONGODB_URI, and the database container is not part of
# the project at all — no `--no-deps` special case in the scripts. These check
# that against `docker compose config` (what the daemon would be handed; no
# daemon needed) and against the scripts' own idea of which kind of install
# this is. The last check needs a real MongoDB and runs only where a daemon is.

# shellcheck disable=SC2016  # the single-quoted snippets run in another shell

set -uo pipefail

# shellcheck source=helpers/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/common.sh"

printf '\nan external MongoDB\n\n'

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"; docker rm -f ts-empty-auth >/dev/null 2>&1 || true' EXIT

THEIRS="mongodb://tasksense:pw@mongo-0.bank.internal:27017,mongo-1.bank.internal:27017/?replicaSet=rs0&tls=true&authSource=admin"
external() { fixture_env "$1" "COMPOSE_PROFILES=" "MONGO_USER=" "MONGO_PASSWORD=" "MONGODB_URI=$2"; }

# ── 1. compose: theirs is used, and ours is not part of the project ──────────
if compose_cli; then
  cfg() { TASKSENSE_ENV_FILE="$1" docker compose -f "${ROOT}/compose/docker-compose.yml" --env-file "$1" config "${@:2}" 2>/dev/null; }
  uri_of() { cfg "$1" | awk '/MONGODB_URI:/ { $1=""; sub(/^ /,""); print; exit }'; }

  fixture_env "${WORK}/bundled.env"
  check "without MONGODB_URI the bundled database is addressed" \
    "mongodb://tasksense:0123456789abcdef0123456789abcdef@mongo:27017/?authSource=admin" "$(uri_of "${WORK}/bundled.env")"

  external "${WORK}/theirs.env" "${THEIRS}"
  check "with MONGODB_URI set, theirs is used" "${THEIRS}" "$(uri_of "${WORK}/theirs.env")"
  check "and the bundled host is nowhere in it" "0" "$(uri_of "${WORK}/theirs.env" | grep -c '@mongo:27017')"
  check "the database container is not in the project" "migrate app" "$(cfg "${WORK}/theirs.env" --services | tr '\n' ' ' | sed 's/ $//')"
  cfg "${WORK}/theirs.env" -q
  check "and the project is valid without it — depends_on is required: false" "0" "$?"

  # A cluster with no authentication is a connection string with no
  # credentials in it — and MONGO_USER / MONGO_PASSWORD left empty must not
  # make compose refuse the project, as `${MONGO_USER:?}` once did.
  external "${WORK}/noauth.env" "mongodb://mongo.bank.internal:27017/tasksense"
  cfg "${WORK}/noauth.env" -q
  check "an external database needs no bundled credentials" "0" "$?"
  check "and a passwordless connection string reaches the application" \
    "mongodb://mongo.bank.internal:27017/tasksense" "$(uri_of "${WORK}/noauth.env")"
else
  printf '  (the compose CLI is not installed — compose checks skipped)\n'
fi

# ── 2. the scripts know which kind of install it is ──────────────────────────
which_db() {
  TASKSENSE_ENV_FILE="$1" bash -c '. "$1/scripts/lib.sh"
    if bundled_mongo_enabled; then printf bundled; else printf external; fi
    if external_database; then printf " uri"; fi' _ "${ROOT}" 2>&1
}
external "${WORK}/theirs.env" "${THEIRS}"
check "profile off + URI: external" "external uri" "$(which_db "${WORK}/theirs.env")"
fixture_env "${WORK}/bundled.env"
check "the default: bundled" "bundled" "$(which_db "${WORK}/bundled.env")"
printf 'TASKSENSE_VERSION=1.0.0\nMONGODB_URI=%s\n' "${THEIRS}" > "${WORK}/legacy.env"
check "a 1.0 file, before it is carried over: the URI decides" "external uri" "$(which_db "${WORK}/legacy.env")"

# The credentials for a database somebody else administers are not ours to
# demand — install.sh once refused to start without them.
sandbox "${WORK}/sb"
printf '#!/usr/bin/env bash\nexit 0\n' > "${SANDBOX}/scripts/preflight.sh"
external "${SANDBOX}/compose/.env" "${THEIRS}"
out="$("${SANDBOX}/scripts/install.sh" 2>&1)"; rc=$?
check "install.sh accepts an external database without MONGO_USER or MONGO_PASSWORD" "0" "${rc}"
lacks "and starts it without the old --no-deps special case" "--no-deps" "$(docker_calls)"
fixture_env "${SANDBOX}/compose/.env" "MONGO_PASSWORD="
out="$("${SANDBOX}/scripts/install.sh" 2>&1)"
contains "while the bundled database still refuses to start without a password" "missing required values: MONGO_PASSWORD" "${out}"
PATH="${PATH//"${WORK}/sb/bin:"/}"

# ── 3. an empty pair does not open the bundled database ──────────────────────
#
# MONGO_USER / MONGO_PASSWORD have no `:?` guard (see §1). Asserted rather than
# assumed that this is safe: with --auth and no root user, the server creates
# nobody and authorises nothing, so the failure is a refused connection rather
# than an open database. Needs a daemon and mongo:7.
if docker_usable; then
  docker rm -f ts-empty-auth >/dev/null 2>&1
  docker run -d --name ts-empty-auth -e MONGO_INITDB_ROOT_USERNAME= -e MONGO_INITDB_ROOT_PASSWORD= \
    mongo:7 --auth --bind_ip_all >/dev/null 2>&1
  for _ in $(seq 1 30); do
    docker exec ts-empty-auth mongosh --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1 && break
    sleep 1
  done
  out="$(docker exec ts-empty-auth mongosh --quiet --eval 'db.getSiblingDB("tasksense").t.insertOne({a:1})' 2>&1)"
  docker rm -f ts-empty-auth >/dev/null 2>&1
  check "an unconfigured bundled database is unusable, not open" "1" "$(printf '%s' "${out}" | grep -c 'not authorized')"
else
  printf '  (no container daemon — the empty-credentials MongoDB check is skipped)\n'
fi

finish
