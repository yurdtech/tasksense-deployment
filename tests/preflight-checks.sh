#!/usr/bin/env bash
#
# Does preflight block what must be blocked, warn about what is merely unwise,
# and pass a good configuration?
#
#   tests/preflight-checks.sh
#
# Against a sandbox copy of the repository with a fake docker (whose `compose
# config` is the real one when the CLI is installed — it needs no daemon), so
# it is offline and safe to run anywhere. Lines are matched on preflight's
# ASCII marks: "x" blocks, "!" warns.

# shellcheck disable=SC2016  # the single-quoted snippets run in another shell

set -uo pipefail

# shellcheck source=helpers/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/common.sh"

printf '\npreflight\n\n'

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
sandbox "${WORK}"
ENV="${SANDBOX}/compose/.env"

RC=0
OUT=""
run_preflight() { OUT="$("${SANDBOX}/scripts/preflight.sh" --offline "$@" 2>&1)"; RC=$?; }

# Blocking lines outside the host's own resources, which depend on the machine
# running the test rather than on anything under test.
blockers() { printf '%s\n' "${OUT}" | grep '^  x ' | grep -vE 'CPU cores|GB memory|free on /' || true; }

blocks() {  # blocks <name> <expected text> [fixture overrides…]
  local name="$1" text="$2"; shift 2
  fixture_env "${ENV}" "$@"
  run_preflight
  check "${name}: exit 1" "1" "${RC}"
  contains "${name}: says why" "x ${text}" "${OUT}"
}

warns() {  # warns <name> <expected text> [fixture overrides…]
  local name="$1" text="$2"; shift 2
  fixture_env "${ENV}" "$@"
  run_preflight
  contains "${name}" "! ${text}" "${OUT}"
  check "${name}: and that alone blocks nothing" "" "$(blockers)"
}

# ── a good configuration passes ──────────────────────────────────────────────
fixture_env "${ENV}"
run_preflight
check "the example, filled in, has no blocking problem" "" "$(blockers)"
contains "it checks the compose file with this configuration" "docker-compose.yml is valid" "${OUT}"
lacks "and has nothing to say about Swagger or sessions" "! SESSION_TTL_HOURS" "${OUT}"

fixture_env "${ENV}" "COMPOSE_PROFILES=bundled-mongo,import-worker" "WORKER_ROLE=api"
run_preflight
check "the import worker with WORKER_ROLE=api passes" "" "$(blockers)"

mkdir -p "${SANDBOX}/compose/certs"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "${SANDBOX}/compose/certs/bank-ca.pem"
fixture_env "${ENV}" "COMPOSE_PROFILES=" "MONGO_USER=" "MONGO_PASSWORD=" "NODE_EXTRA_CA_CERTS=/certs/bank-ca.pem" \
  "MONGODB_URI=mongodb://ts:pw@mongo-0.abb.invalid:27017/?replicaSet=rs0&tls=true&tlsCAFile=/certs/bank-ca.pem&authSource=admin" \
  "MONGODB_COMPRESSORS=zlib" "MONGODB_TIMEOUT_MS=15000"
run_preflight
check "your own MongoDB with TLS and your CA passes" "" "$(blockers)"
contains "the CA file is found" "+ tlsCAFile /certs/bank-ca.pem is in compose/certs/" "${OUT}"
contains "the CA bundle is read" "+ NODE_EXTRA_CA_CERTS /certs/bank-ca.pem (1 certificate(s))" "${OUT}"
lacks "and the password never appears in what it prints" ":pw@" "${OUT}"

# ── the configuration file ───────────────────────────────────────────────────
blocks "a placeholder left in" "these still hold a <CHANGE_ME_…> placeholder: STORAGE_SECRET" \
  "STORAGE_SECRET=<CHANGE_ME_STORAGE_SECRET>"
fixture_env "${ENV}"; printf 'MONGO_USER=other\n' >> "${ENV}"
run_preflight
contains "a key defined twice" "x MONGO_USER is defined more than once" "${OUT}"
fixture_env "${ENV}"; sed 's/$/\r/' "${ENV}" > "${ENV}.crlf" && mv "${ENV}.crlf" "${ENV}"
run_preflight
contains "Windows line endings" "x the file has Windows (CRLF) line endings" "${OUT}"
blocks "a short STORAGE_SECRET" "STORAGE_SECRET is 10 characters" "STORAGE_SECRET=0123456789"
blocks "LOG_LEVEL=info, the value that once shipped" "LOG_LEVEL=info is not accepted" "LOG_LEVEL=info"
blocks "an enum set to nothing" "LOG_FORMAT=<empty> is not accepted" "LOG_FORMAT="
blocks "a number set to nothing" "SMTP_PORT=<empty> must be a positive whole number" "SMTP_PORT="
blocks "an optional URL set to nothing" "OIDC_ISSUER is set to nothing" "OIDC_ISSUER="
blocks "latest instead of a version" "TASKSENSE_VERSION=latest" "TASKSENSE_VERSION=latest"
blocks "a version older than this packaging" "TaskSense 1.0.0 is older than this packaging supports" "TASKSENSE_VERSION=1.0.0"
fixture_env "${ENV}" "TASKSENSE_VERSION=1.0.0"
run_preflight --target-version 1.1.0
contains "but not when that version is being upgraded away from" "+ TaskSense 1.1.0 (target; 1.0.0 configured now)" "${OUT}"

# ── security posture ─────────────────────────────────────────────────────────
blocks "AGENT_EXECUTOR=on" "AGENT_EXECUTOR=on — no execution sandbox ships on-premise" "AGENT_EXECUTOR=on"
blocks "AGENT_EXECUTOR=auto" "AGENT_EXECUTOR=auto" "AGENT_EXECUTOR=auto"
blocks "AGENT_EXECUTOR=unsafe-host" "AGENT_EXECUTOR=unsafe-host would run model-authored commands" "AGENT_EXECUTOR=unsafe-host"
warns "sessions that never expire" "SESSION_TTL_HOURS=0 — sessions never expire" "SESSION_TTL_HOURS=0"
warns "the 30-day default" "SESSION_TTL_HOURS is unset" "-SESSION_TTL_HOURS"
warns "Swagger left to the application's default (on)" "the API browser is ON" "-SWAGGER_ENABLED"
warns "metrics without a token" "METRICS_ENABLED is on but METRICS_TOKEN is empty" "METRICS_ENABLED=true"
warns "a non-loopback bind address" "BIND_ADDRESS=0.0.0.0" "BIND_ADDRESS=0.0.0.0"

# ── database topology ────────────────────────────────────────────────────────
blocks "bundled-mongo and MONGODB_URI both" "MONGODB_URI is set AND bundled-mongo is in COMPOSE_PROFILES" \
  "MONGODB_URI=mongodb://db.abb.invalid/"
blocks "neither" "no database: bundled-mongo is not in COMPOSE_PROFILES and MONGODB_URI is not set" \
  "COMPOSE_PROFILES=" "MONGO_USER=" "MONGO_PASSWORD="
blocks "a profile typo" "COMPOSE_PROFILES names 'bundled_mongo'" "COMPOSE_PROFILES=bundled_mongo"
blocks "a bundled password that breaks the URI" "MONGO_PASSWORD contains / : @ ? # % [ or ]" "MONGO_PASSWORD=ab/cd+ef=="
blocks "a CA named in the URI but missing" "MONGODB_URI names tlsCAFile=/certs/missing.pem, but compose/certs/missing.pem does not exist" \
  "COMPOSE_PROFILES=" "MONGO_USER=" "MONGO_PASSWORD=" "MONGODB_URI=mongodb://u:p@db.abb.invalid/?tls=true&tlsCAFile=/certs/missing.pem"
blocks "a CA outside /certs" "tlsCAFile=/etc/ssl/ca.pem is not under /certs" \
  "COMPOSE_PROFILES=" "MONGO_USER=" "MONGO_PASSWORD=" "MONGODB_URI=mongodb://u:p@db.abb.invalid/?tls=true&tlsCAFile=/etc/ssl/ca.pem"
blocks "localhost from inside a container" "MONGODB_URI points at localhost" \
  "COMPOSE_PROFILES=" "MONGO_USER=" "MONGO_PASSWORD=" "MONGODB_URI=mongodb://u:p@localhost:27017/"

# ── import worker ────────────────────────────────────────────────────────────
blocks "the worker beside an API that also lands imports" "the import-worker profile is on but WORKER_ROLE=all" \
  "COMPOSE_PROFILES=bundled-mongo,import-worker"
blocks "WORKER_ROLE=api with no worker to land them" "WORKER_ROLE=api but the import-worker profile is off" "WORKER_ROLE=api"
blocks "WORKER_ROLE=worker for the API" "WORKER_ROLE=worker is not accepted" "WORKER_ROLE=worker"

# ── certificates ─────────────────────────────────────────────────────────────
blocks "NODE_EXTRA_CA_CERTS that is not there" "NODE_EXTRA_CA_CERTS=/certs/nope.pem, but compose/certs/nope.pem does not exist" \
  "NODE_EXTRA_CA_CERTS=/certs/nope.pem"
blocks "NODE_EXTRA_CA_CERTS on the host's path" "NODE_EXTRA_CA_CERTS=/etc/pki/ca.pem is not under /certs" \
  "NODE_EXTRA_CA_CERTS=/etc/pki/ca.pem"
printf 'not a certificate\n' > "${SANDBOX}/compose/certs/junk.pem"
blocks "a file that is not a PEM certificate" "compose/certs/junk.pem is not a PEM certificate" "NODE_EXTRA_CA_CERTS=/certs/junk.pem"

# ── the host's tools ─────────────────────────────────────────────────────────
fixture_env "${ENV}"
OUT="$(FAKE_COMPOSE_VERSION=2.17.3 "${SANDBOX}/scripts/preflight.sh" --offline 2>&1)"; RC=$?
check "compose older than 2.20: exit 1" "1" "${RC}"
contains "compose older than 2.20: says why" "x docker compose 2.17.3 is too old — 2.20.0 or newer is required" "${OUT}"

if [ -n "${FAKE_REAL_DOCKER}" ] && "${FAKE_REAL_DOCKER}" compose version >/dev/null 2>&1; then
  fixture_env "${ENV}" "TASKSENSE_VERSION="
  run_preflight
  contains "a configuration compose cannot read is reported with compose's words" "set TASKSENSE_VERSION in .env" "${OUT}"
fi

# ── a 1.0 configuration is carried forward first ─────────────────────────────
fixture_env "${ENV}" "-COMPOSE_PROFILES" "-SWAGGER_ENABLED" "TASKSENSE_VERSION=1.0.0"
run_preflight --target-version 1.1.0
contains "a 1.0 file is carried over before it is checked" "Configuration carried over from 1.0" "${OUT}"
check "and then passes" "" "$(blockers)"
check "with the bundled database it always had" "1" "$(grep -c '^COMPOSE_PROFILES=bundled-mongo$' "${ENV}")"

# ── before any configuration exists ──────────────────────────────────────────
rm -f "${ENV}"
run_preflight
check "no .env at all: exit 1" "1" "${RC}"
contains "and how to make one" "x no configuration at" "${OUT}"
OUT="$("${SANDBOX}/scripts/preflight.sh" --offline --host-only 2>&1)"; RC=$?
check "--host-only checks the host alone" "" "$(blockers)"
contains "and says that is what it did" "host checks only" "${OUT}"

finish
