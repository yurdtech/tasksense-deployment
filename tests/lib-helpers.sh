#!/usr/bin/env bash
#
# The helpers in scripts/lib.sh that every operator script leans on, and the
# one-time carry-over of a 1.0 configuration.
#
#   tests/lib-helpers.sh
#
# Plain bash with no container: lib.sh is bash 3.2 compatible on purpose, so
# this runs on a Mac as well as in CI, and needs nothing installed.

# shellcheck disable=SC2016,SC2012  # the single-quoted snippets run in another shell; backups are listed by our own names

set -uo pipefail

# shellcheck source=helpers/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/common.sh"

printf '\nlib.sh helpers\n\n'

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
sandbox "${WORK}"

# Run a snippet with lib.sh sourced, against a given configuration file.
lib() {  # lib <env-file> <snippet>
  TASKSENSE_ENV_FILE="$1" bash -c '. "$1/scripts/lib.sh"; eval "$2"' _ "${SANDBOX}" "$2" 2>&1
}

# ── versions ─────────────────────────────────────────────────────────────────
check "1.1.0 > 1.0.9"              "1"  "$(lib /dev/null 'version_cmp 1.1.0 1.0.9')"
check "1.10.0 > 1.9.0 (numeric)"   "1"  "$(lib /dev/null 'version_cmp 1.10.0 1.9.0')"
check "1.1.0-rc.1 < 1.1.0"         "-1" "$(lib /dev/null 'version_cmp 1.1.0-rc.1 1.1.0')"
check "equal"                      "0"  "$(lib /dev/null 'version_cmp v2.0.0 2.0.0')"
check "compose 2.19.1 is not >= 2.20.0" "no" "$(lib /dev/null 'version_ge 2.19.1 2.20.0 && echo yes || echo no')"
check "semver_valid refuses latest" "no" "$(lib /dev/null 'semver_valid latest && echo yes || echo no')"

# ── connection strings, handled without the password reaching argv ───────────
check "a URI without a path is left as it is" \
  "mongodb://u:p@h:27017/?replicaSet=rs0&authSource=admin" \
  "$(lib /dev/null 'mongo_uri_without_db "mongodb://u:p@h:27017/?replicaSet=rs0&authSource=admin"')"
check "a database in the path becomes authSource — it was the auth db" \
  "mongodb://u:p@h/?tls=true&authSource=mydb" \
  "$(lib /dev/null 'mongo_uri_without_db "mongodb://u:p@h/mydb?tls=true"')"
check "an explicit authSource (any case) is kept" \
  "mongodb://h1,h2/?AuthSource=y" "$(lib /dev/null 'mongo_uri_without_db "mongodb://h1,h2/x?AuthSource=y"')"
check "SRV URIs too" "mongodb+srv://u:p@c.abb.internal/" "$(lib /dev/null 'mongo_uri_without_db "mongodb+srv://u:p@c.abb.internal/"')"
check "first host of a seed list" "mongo-0.abb.internal 27018" \
  "$(lib /dev/null 'printf "%s %s" "$(uri_host "mongodb://u:p@mongo-0.abb.internal:27018,m1:27017/x")" "$(uri_port "mongodb://u:p@mongo-0.abb.internal:27018,m1:27017/x")"')"
check "default port" "27017" "$(lib /dev/null 'uri_port "mongodb://u:p@db.abb.internal/x"')"
check "credentials redacted for messages" "mongodb://***@h:1/x" "$(lib /dev/null 'uri_redacted "mongodb://u:s3cret@h:1/x?tls=true"')"

# ── reading and writing .env ─────────────────────────────────────────────────
printf 'A=1\nQUOTED="two words"\nCRLF=yes\r\n#OPT=commented\nA=2\n' > "${WORK}/read.env"
check "the last definition wins, as in compose" "2" "$(lib "${WORK}/read.env" 'env_value A')"
check "surrounding quotes are removed" "two words" "$(lib "${WORK}/read.env" 'env_value QUOTED')"
check "a Windows line ending is removed" "yes" "$(lib "${WORK}/read.env" 'env_value CRLF')"
check "a commented line is not a value" "" "$(lib "${WORK}/read.env" 'env_value OPT')"
check "an absent file is nothing configured, not an error" "ok" \
  "$(lib "${WORK}/nope.env" 'set -e; v="$(env_value A)"; echo ok')"

printf 'KEEP=1\nSET=old\n#UNCOMMENT=example\n' > "${WORK}/set.env"
chmod 600 "${WORK}/set.env"
lib /dev/null "env_set '${WORK}/set.env' SET 'p@ss/w&rd\\with=chars'; env_set '${WORK}/set.env' UNCOMMENT here; env_set '${WORK}/set.env' NEW appended" >/dev/null
check "env_set replaces in place, any characters intact" 'p@ss/w&rd\with=chars' "$(lib "${WORK}/set.env" 'env_value SET')"
check "env_set uncomments the documented line" "UNCOMMENT=here" "$(sed -n '3p' "${WORK}/set.env")"
check "env_set appends what is not there" "NEW=appended" "$(tail -n1 "${WORK}/set.env")"
check "env_set keeps the file's mode" "600" "$(mode_of "${WORK}/set.env")"
check "env_set touches nothing else" "KEEP=1" "$(head -n1 "${WORK}/set.env")"

# ── placeholders and required values ─────────────────────────────────────────
cp "${ROOT}/compose/.env.example" "${WORK}/example.env"
check "the example's placeholders are found" "APP_URL FIRST_ADMIN_EMAIL STORAGE_SECRET MONGO_PASSWORD" \
  "$(lib "${WORK}/example.env" 'placeholder_keys "$ENV_FILE"' | tr '\n' ' ' | sed 's/ $//')"
check "every example placeholder uses the one marker" "4" "$(grep -c '^[A-Z_]*=<CHANGE_ME_[A-Z_]*>$' "${ROOT}/compose/.env.example")"
fixture_env "${WORK}/filled.env"
check "a filled-in file has none" "" "$(lib "${WORK}/filled.env" 'placeholder_keys "$ENV_FILE"')"
check "and nothing unfinished" "" "$(lib "${WORK}/filled.env" 'unfinished_keys "$ENV_FILE"')"
fixture_env "${WORK}/ext-unfinished.env" "COMPOSE_PROFILES=" "MONGO_USER=" "MONGO_PASSWORD="
check "your own MongoDB needs MONGODB_URI, not MONGO_PASSWORD" "MONGODB_URI" \
  "$(lib "${WORK}/ext-unfinished.env" 'unfinished_keys "$ENV_FILE"')"

# ── topology ─────────────────────────────────────────────────────────────────
check "no configuration yet means the default: bundled" "bundled" \
  "$(lib "${WORK}/none.env" 'bundled_mongo_enabled && echo bundled || echo external')"
check "the profile decides once it is set" "external" \
  "$(lib "${WORK}/ext-unfinished.env" 'bundled_mongo_enabled && echo bundled || echo external')"
printf 'TASKSENSE_VERSION=1.0.0\nMONGODB_URI=mongodb://db.abb.internal/x\n' > "${WORK}/legacy-ext.env"
check "a 1.0 file without profiles: the URI decides, as it did then" "external" \
  "$(lib "${WORK}/legacy-ext.env" 'bundled_mongo_enabled && echo bundled || echo external')"
fixture_env "${WORK}/worker.env" "COMPOSE_PROFILES=bundled-mongo, import-worker"
check "profiles tolerate a space after the comma" "yes" \
  "$(lib "${WORK}/worker.env" 'import_worker_enabled && echo yes || echo no')"
check "the configured images" "ghcr.io/yurdtech/tasksense:$(example_version) mongo:7" \
  "$(lib "${WORK}/filled.env" 'echo "$(app_image) $(mongo_image)"')"
check "memory sizes" "6144 1536 2048" "$(lib /dev/null 'echo "$(size_to_mb 6g) $(size_to_mb 1536mb) $(size_to_mb 2G)"')"

# ── carrying a 1.0 configuration forward ─────────────────────────────────────
printf '\n  1.0 → 1.1 carry-over\n'

printf 'TASKSENSE_VERSION=1.0.0\nMONGO_USER=tasksense\nMONGO_PASSWORD=abc\n#SWAGGER_ENABLED=1\n' > "${SANDBOX}/compose/.env"
chmod 600 "${SANDBOX}/compose/.env"
out="$(lib "${SANDBOX}/compose/.env" 'migrate_legacy_env')"
check "a bundled 1.0 install gets COMPOSE_PROFILES=bundled-mongo" "bundled-mongo" "$(lib "${SANDBOX}/compose/.env" 'env_value COMPOSE_PROFILES')"
check "and keeps the API browser off, as 1.0 had it" "false" "$(lib "${SANDBOX}/compose/.env" 'env_value SWAGGER_ENABLED')"
contains "and says so" "Configuration carried over from 1.0" "${out}"
check "the original is kept under backups/, mode 600" "600" "$(mode_of "$(ls "${SANDBOX}"/backups/env-before-1.1-* | head -n1)")"
check "the file keeps its mode" "600" "$(mode_of "${SANDBOX}/compose/.env")"
before="$(cat "${SANDBOX}/compose/.env")"
out="$(lib "${SANDBOX}/compose/.env" 'migrate_legacy_env')"
check "running it again changes nothing" "${before}" "$(cat "${SANDBOX}/compose/.env")"
check "and says nothing" "" "${out}"

printf 'TASKSENSE_VERSION=1.0.0\nMONGODB_URI=mongodb://u:p@db.abb.internal/?authSource=admin\nSWAGGER_ENABLED=true\n' > "${SANDBOX}/compose/.env"
lib "${SANDBOX}/compose/.env" 'migrate_legacy_env' >/dev/null
check "an external 1.0 install gets an empty COMPOSE_PROFILES" "1" "$(grep -c '^COMPOSE_PROFILES=$' "${SANDBOX}/compose/.env")"
check "an explicit SWAGGER_ENABLED is left alone" "true" "$(lib "${SANDBOX}/compose/.env" 'env_value SWAGGER_ENABLED')"
check "and is not duplicated" "1" "$(grep -c '^SWAGGER_ENABLED=' "${SANDBOX}/compose/.env")"

fixture_env "${SANDBOX}/compose/.env"
before="$(cat "${SANDBOX}/compose/.env")"
lib "${SANDBOX}/compose/.env" 'migrate_legacy_env' >/dev/null
check "a 1.1 configuration is never touched" "${before}" "$(cat "${SANDBOX}/compose/.env")"

# ── the in-container credential file ─────────────────────────────────────────
# What runs inside the mongo container, run here by sh: the secret goes from
# the environment into a YAML file, quoted so that any password survives.
out="$(TS_MONGO_URI="mongodb://u:it's%2Fpw@h/" sh -c "$(lib /dev/null 'printf "%s" "$MONGO_CFG_FROM_URI"')"'
cat "$CFG"; ls -l "$CFG" | cut -c1-10' 2>&1)"
contains "the URI lands in a tools config, quotes doubled" "uri: 'mongodb://u:it''s%2Fpw@h/'" "${out}"
contains "readable by its owner only" "-rw-------" "${out}"

finish
