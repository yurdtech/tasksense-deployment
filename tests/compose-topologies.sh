#!/usr/bin/env bash
#
# The three shapes the compose file has to take, checked against what compose
# would actually hand the daemon.
#
#   tests/compose-topologies.sh
#
#   bundled    COMPOSE_PROFILES=bundled-mongo                (the default)
#   external   COMPOSE_PROFILES=  + MONGODB_URI              (your own MongoDB)
#   worker     COMPOSE_PROFILES=bundled-mongo,import-worker  (+ WORKER_ROLE=api)
#
# `docker compose config` needs the CLI and its compose plugin, not a daemon,
# and pulls nothing — so this runs offline. The configuration lives in a
# temporary file the compose file is pointed at through TASKSENSE_ENV_FILE;
# compose/.env is never written.

set -uo pipefail

# shellcheck source=helpers/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/common.sh"

compose_cli || skip "the docker CLI with the compose plugin is not installed"
command -v python3 >/dev/null 2>&1 || skip "python3 is not installed"

printf '\ncompose topologies\n\n'

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
COMPOSE_FILE_PATH="${ROOT}/compose/docker-compose.yml"

render() {  # render <env-file> → JSON on stdout, exit code of compose
  TASKSENSE_ENV_FILE="$1" docker compose -f "${COMPOSE_FILE_PATH}" --env-file "$1" config --format json 2>"${WORK}/err"
}

# q <json-file> <python expression over `c`, the rendered project>
q() {
  python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
s = c.get("services", {})
def env(svc, key): return (s.get(svc, {}).get("environment") or {}).get(key)
v = eval(sys.argv[2])
print(" ".join(map(str, v)) if isinstance(v, (list, tuple)) else v)
' "$1" "$2" 2>&1
}

ENV_PRESENT_BEFORE=0; [ -f "${ROOT}/compose/.env" ] && ENV_PRESENT_BEFORE=1

THEIRS="mongodb://ts:pw@mongo-0.abb.internal:27017,mongo-1.abb.internal:27017/?replicaSet=rs0&tls=true&tlsCAFile=/certs/bank-ca.pem&authSource=admin"
fixture_env "${WORK}/bundled.env"
fixture_env "${WORK}/external.env" "COMPOSE_PROFILES=" "MONGO_USER=" "MONGO_PASSWORD=" "MONGODB_URI=${THEIRS}"
fixture_env "${WORK}/worker.env" "COMPOSE_PROFILES=bundled-mongo,import-worker" "WORKER_ROLE=api" \
  "APP_HEAP_MB=3072" "WORKER_HEAP_MB=5120" "MONGO_CACHE_GB=2"

for t in bundled external worker; do
  render "${WORK}/${t}.env" > "${WORK}/${t}.json"
  check "${t}: docker compose config accepts it" "0" "$?"
  [ -s "${WORK}/err" ] && sed 's/^/      /' "${WORK}/err"
done

# ── which services run ───────────────────────────────────────────────────────
check "bundled: mongo, migrate, app"            "app migrate mongo"        "$(q "${WORK}/bundled.json" 'sorted(s)')"
check "external: no database container at all"  "app migrate"              "$(q "${WORK}/external.json" 'sorted(s)')"
check "worker: plus the import worker"          "app migrate mongo worker" "$(q "${WORK}/worker.json" 'sorted(s)')"

# ── the database the application is given ────────────────────────────────────
check "bundled: the URI is built from MONGO_USER / MONGO_PASSWORD" \
  "mongodb://tasksense:0123456789abcdef0123456789abcdef@mongo:27017/?authSource=admin" \
  "$(q "${WORK}/bundled.json" 'env("app","MONGODB_URI")')"
check "external: your URI wins over the bundled address" "${THEIRS}" "$(q "${WORK}/external.json" 'env("app","MONGODB_URI")')"
check "external: migrate uses it too" "${THEIRS}" "$(q "${WORK}/external.json" 'env("migrate","MONGODB_URI")')"
check "external: the dependency on mongo is optional, not an error" "False" \
  "$(q "${WORK}/external.json" 's["app"]["depends_on"]["mongo"]["required"]')"

# ── migrate: one-shot, before everything ─────────────────────────────────────
check "migrate runs the migration CLI" "node dist/database/migrations/cli.js up" "$(q "${WORK}/bundled.json" 's["migrate"]["command"]')"
check "and is not restarted" "no" "$(q "${WORK}/bundled.json" 's["migrate"]["restart"]')"
check "and has no healthcheck to fail" "True" "$(q "${WORK}/bundled.json" 's["migrate"]["healthcheck"]["disable"]')"
check "and waits for a healthy bundled mongo, if there is one" "service_healthy False" \
  "$(q "${WORK}/bundled.json" '[s["migrate"]["depends_on"]["mongo"]["condition"], s["migrate"]["depends_on"]["mongo"]["required"]]')"
check "the app starts only after migrate succeeded" "service_completed_successfully" \
  "$(q "${WORK}/bundled.json" 's["app"]["depends_on"]["migrate"]["condition"]')"
check "the worker too" "service_completed_successfully" \
  "$(q "${WORK}/worker.json" 's["worker"]["depends_on"]["migrate"]["condition"]')"

# ── app ──────────────────────────────────────────────────────────────────────
check "app: MIGRATE_ON_BOOT is manual — migrate did it" "manual" "$(q "${WORK}/bundled.json" 'env("app","MIGRATE_ON_BOOT")')"
check "app: heap from APP_HEAP_MB" "--max-old-space-size=1536" "$(q "${WORK}/bundled.json" 'env("app","NODE_OPTIONS")')"
check "app: heap follows a changed APP_HEAP_MB" "--max-old-space-size=3072" "$(q "${WORK}/worker.json" 'env("app","NODE_OPTIONS")')"
check "app: staging on the data volume" "/app/api/data/tmp" "$(q "${WORK}/bundled.json" 'env("app","TMPDIR")')"
check "migrate: the same TMPDIR" "/app/api/data/tmp" "$(q "${WORK}/bundled.json" 'env("migrate","TMPDIR")')"
check "app: WORKER_ROLE from .env" "all" "$(q "${WORK}/bundled.json" 'env("app","WORKER_ROLE")')"
check "app: WORKER_ROLE=api beside the worker" "api" "$(q "${WORK}/worker.json" 'env("app","WORKER_ROLE")')"
check "app: CORS defaults to APP_URL" "https://tasksense.abb.internal" "$(q "${WORK}/bundled.json" 'env("app","CORS_ALLOWED_ORIGINS")')"
check "app: on-premise contract forced" "onprem production" \
  "$(q "${WORK}/bundled.json" '[env("app","DEPLOYMENT_MODE"), env("app","NODE_ENV")]')"
check "app: published on the loopback address only" "127.0.0.1 39317 3000" \
  "$(q "${WORK}/bundled.json" '[s["app"]["ports"][0]["host_ip"], s["app"]["ports"][0]["published"], s["app"]["ports"][0]["target"]]')"
check "app: 45 s to finish in-flight work on stop" "45s" "$(q "${WORK}/bundled.json" 's["app"]["stop_grace_period"]')"
check "app: read-only root, no capabilities, no privilege escalation" "True ALL no-new-privileges:true" \
  "$(q "${WORK}/bundled.json" '[s["app"]["read_only"], s["app"]["cap_drop"][0], s["app"]["security_opt"][0]]')"
check "app: memory limit applied" "2147483648" "$(q "${WORK}/bundled.json" 's["app"]["deploy"]["resources"]["limits"]["memory"]')"
check "app: logs rotate" "50m 5" "$(q "${WORK}/bundled.json" '[s["app"]["logging"]["options"]["max-size"], s["app"]["logging"]["options"]["max-file"]]')"
check "app: the CA directory is mounted read-only at /certs" "/certs True" \
  "$(q "${WORK}/bundled.json" '[[v["target"], v.get("read_only")] for v in s["app"]["volumes"] if v["target"]=="/certs"][0]')"

# ── worker ───────────────────────────────────────────────────────────────────
check "worker: runs the worker entry point" "node dist/worker.js" "$(q "${WORK}/worker.json" 's["worker"]["command"]')"
check "worker: WORKER_ROLE is forced to worker" "worker" "$(q "${WORK}/worker.json" 'env("worker","WORKER_ROLE")')"
check "worker: heap from WORKER_HEAP_MB" "--max-old-space-size=5120" "$(q "${WORK}/worker.json" 'env("worker","NODE_OPTIONS")')"
check "worker: publishes no port" "None" "$(q "${WORK}/worker.json" 's["worker"].get("ports")')"
check "worker: shares the data volume with the API" "tasksense-app-data" \
  "$(q "${WORK}/worker.json" '[c["volumes"][v["source"]]["name"] for v in s["worker"]["volumes"] if v["target"]=="/app/api/data"][0]')"
check "worker: 6 GB limit by default" "6442450944" "$(q "${WORK}/worker.json" 's["worker"]["deploy"]["resources"]["limits"]["memory"]')"
check "worker: 45 s to checkpoint on stop" "45s" "$(q "${WORK}/worker.json" 's["worker"]["stop_grace_period"]')"

# ── mongo ────────────────────────────────────────────────────────────────────
check "mongo: cache size from MONGO_CACHE_GB" "--wiredTigerCacheSizeGB 2" \
  "$(q "${WORK}/worker.json" '" ".join(s["mongo"]["command"][-2:])')"
check "mongo: publishes no port" "None" "$(q "${WORK}/bundled.json" 's["mongo"].get("ports")')"

# ── a mirror moves both images ───────────────────────────────────────────────
fixture_env "${WORK}/mirror.env" "TASKSENSE_IMAGE=harbor.abb.internal/tasksense/tasksense" "MONGO_IMAGE=harbor.abb.internal/tasksense/mongo" "MONGO_VERSION=7.0.14"
render "${WORK}/mirror.env" > "${WORK}/mirror.json"
check "mirror: app, migrate and mongo all come from it" \
  "harbor.abb.internal/tasksense/tasksense:$(example_version) harbor.abb.internal/tasksense/tasksense:$(example_version) harbor.abb.internal/tasksense/mongo:7.0.14" \
  "$(q "${WORK}/mirror.json" '[s["app"]["image"], s["migrate"]["image"], s["mongo"]["image"]]')"

# ── refusals ─────────────────────────────────────────────────────────────────
fixture_env "${WORK}/noversion.env" "TASKSENSE_VERSION="
render "${WORK}/noversion.env" >/dev/null; rc=$?
check "an unset TASKSENSE_VERSION is refused" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
contains "naming the setting" "set TASKSENSE_VERSION in .env" "$(cat "${WORK}/err")"

ENV_PRESENT_AFTER=0; [ -f "${ROOT}/compose/.env" ] && ENV_PRESENT_AFTER=1
check "compose/.env was never created" "${ENV_PRESENT_BEFORE}" "${ENV_PRESENT_AFTER}"

finish
