#!/usr/bin/env bash
#
# The shapes the compose files have to take, checked against what compose
# would actually hand the daemon.
#
#   tests/compose-topologies.sh
#
#   bundled    COMPOSE_PROFILES=bundled-mongo,jira-sync      (the default)
#   external   COMPOSE_PROFILES=  + MONGODB_URI              (your own MongoDB)
#   worker     COMPOSE_PROFILES=bundled-mongo,import-worker  (+ WORKER_ROLE=api)
#   replicas   COMPOSE_PROFILES=bundled-mongo,import-worker,replicas,bundled-redis
#              with docker-compose.replicas.yml — and with your own Redis
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
# The replicas profile: the same, with the override the scripts add for it.
render_replicas() {
  TASKSENSE_ENV_FILE="$1" docker compose -f "${COMPOSE_FILE_PATH}" -f "${ROOT}/compose/docker-compose.replicas.yml" \
    --env-file "$1" config --format json 2>"${WORK}/err"
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

THEIRS="mongodb://ts:pw@mongo-0.acme.internal:27017,mongo-1.acme.internal:27017/?replicaSet=rs0&tls=true&tlsCAFile=/certs/corp-ca.pem&authSource=admin"
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
check "bundled: mongo, migrate, app, sync"      "app migrate mongo sync"   "$(q "${WORK}/bundled.json" 'sorted(s)')"
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
check "app: CORS defaults to APP_URL" "https://tasksense.acme.internal" "$(q "${WORK}/bundled.json" 'env("app","CORS_ALLOWED_ORIGINS")')"
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
fixture_env "${WORK}/mirror.env" "TASKSENSE_IMAGE=harbor.acme.internal/tasksense/tasksense" "MONGO_IMAGE=harbor.acme.internal/tasksense/mongo" "MONGO_VERSION=7.0.14"
render "${WORK}/mirror.env" > "${WORK}/mirror.json"
check "mirror: app, migrate and mongo all come from it" \
  "harbor.acme.internal/tasksense/tasksense:$(example_version) harbor.acme.internal/tasksense/tasksense:$(example_version) harbor.acme.internal/tasksense/mongo:7.0.14" \
  "$(q "${WORK}/mirror.json" '[s["app"]["image"], s["migrate"]["image"], s["mongo"]["image"]]')"

# ── replicas: several API processes, a load balancer, Redis ─────────────────
RPW="0123456789abcdef0123456789abcdef0123456789abcdef"
REPLICAS_PROFILES="COMPOSE_PROFILES=bundled-mongo,import-worker,replicas,bundled-redis"
fixture_env "${WORK}/replicas.env" "${REPLICAS_PROFILES}" "WORKER_ROLE=api" "BUNDLED_REDIS_PASSWORD=${RPW}" "APP_REPLICAS=4"
fixture_env "${WORK}/replicas-default.env" "${REPLICAS_PROFILES}" "WORKER_ROLE=api" "BUNDLED_REDIS_PASSWORD=${RPW}"
THEIR_REDIS="rediss://tasksense:pw@redis.acme.internal:6380/0"
fixture_env "${WORK}/replicas-own-redis.env" "COMPOSE_PROFILES=bundled-mongo,import-worker,replicas" "WORKER_ROLE=api" \
  "REDIS_URL=${THEIR_REDIS}" "TRUST_PROXY=3" "MONGODB_MAX_POOL_SIZE=40"
fixture_env "${WORK}/replicas-sentinel.env" "COMPOSE_PROFILES=bundled-mongo,import-worker,replicas" "WORKER_ROLE=api" \
  "REDIS_SENTINELS=redis-0.acme.internal:26379,redis-1.acme.internal:26379" "REDIS_SENTINEL_NAME=mymaster"
for t in replicas replicas-default replicas-own-redis replicas-sentinel; do
  render_replicas "${WORK}/${t}.env" > "${WORK}/${t}.json"
  check "${t}: docker compose config accepts it" "0" "$?"
  [ -s "${WORK}/err" ] && sed 's/^/      /' "${WORK}/err"
done

check "replicas: plus the load balancer and Redis" "app lb migrate mongo redis worker" "$(q "${WORK}/replicas.json" 'sorted(s)')"
check "replicas: APP_REPLICAS copies of the app" "4" "$(q "${WORK}/replicas.json" 's["app"]["deploy"]["replicas"]')"
check "replicas: three without APP_REPLICAS" "3" "$(q "${WORK}/replicas-default.json" 's["app"]["deploy"]["replicas"]')"
check "replicas: the copies have no fixed name (Compose names them)" "None" "$(q "${WORK}/replicas.json" 's["app"].get("container_name")')"
check "replicas: and no host port — the load balancer holds it" "None" "$(q "${WORK}/replicas.json" 's["app"].get("ports")')"
check "replicas: the API never lands imports itself" "api" "$(q "${WORK}/replicas.json" 'env("app","WORKER_ROLE")')"
check "replicas: two proxy hops (the host's and lb)" "2" "$(q "${WORK}/replicas.json" 'env("app","TRUST_PROXY")')"
check "replicas: a smaller pool per copy" "50" "$(q "${WORK}/replicas.json" 'env("app","MONGODB_MAX_POOL_SIZE")')"
check "replicas: the bundled Redis, with its password" "redis://:${RPW}@redis:6379" "$(q "${WORK}/replicas.json" 'env("app","REDIS_URL")')"
check "replicas: the worker publishes through the same Redis" "redis://:${RPW}@redis:6379" "$(q "${WORK}/replicas.json" 'env("worker","REDIS_URL")')"
check "replicas: the app waits for a healthy bundled Redis, if there is one" "service_healthy False" \
  "$(q "${WORK}/replicas.json" '[s["app"]["depends_on"]["redis"]["condition"], s["app"]["depends_on"]["redis"]["required"]]')"
check "replicas: and still for migrate" "service_completed_successfully" "$(q "${WORK}/replicas.json" 's["app"]["depends_on"]["migrate"]["condition"]')"
check "lb: published where the app was, loopback only" "127.0.0.1 39317 8080" \
  "$(q "${WORK}/replicas.json" '[s["lb"]["ports"][0]["host_ip"], s["lb"]["ports"][0]["published"], s["lb"]["ports"][0]["target"]]')"
check "lb: Caddy at a pinned tag" "caddy:2.10-alpine tasksense-lb" "$(q "${WORK}/replicas.json" '[s["lb"]["image"], s["lb"]["container_name"]]')"
check "lb: its configuration, read-only" "/etc/caddy/Caddyfile True" \
  "$(q "${WORK}/replicas.json" '[[v["target"], v.get("read_only")] for v in s["lb"]["volumes"]][0]')"
check "lb: read-only root, every capability dropped but the one its binary carries" "True ALL NET_BIND_SERVICE" \
  "$(q "${WORK}/replicas.json" '[s["lb"]["read_only"], s["lb"]["cap_drop"][0], s["lb"]["cap_add"][0]]')"
check "redis: pinned like the other images, no port, no volume" "redis:7-alpine None None" \
  "$(q "${WORK}/replicas.json" '[s["redis"]["image"], s["redis"].get("ports"), s["redis"].get("volumes")]')"
contains "redis: no snapshots, no AOF" "--save '' --appendonly no" "$(q "${WORK}/replicas.json" 's["redis"]["command"][0]')"
lacks "redis: the password is on no command line" "${RPW}" "$(q "${WORK}/replicas.json" '[s["redis"]["command"], s["redis"]["entrypoint"], s["redis"]["healthcheck"]["test"]]')"
check "redis: it travels in the environment instead" "${RPW}" "$(q "${WORK}/replicas.json" 'env("redis","REDISCLI_AUTH")')"
check "own Redis: no Redis container" "app lb migrate mongo worker" "$(q "${WORK}/replicas-own-redis.json" 'sorted(s)')"
check "own Redis: your URL wins" "${THEIR_REDIS}" "$(q "${WORK}/replicas-own-redis.json" 'env("app","REDIS_URL")')"
check "own Redis: and your hop count and pool size" "3 40" \
  "$(q "${WORK}/replicas-own-redis.json" '[env("app","TRUST_PROXY"), env("app","MONGODB_MAX_POOL_SIZE")]')"
check "sentinels: REDIS_URL is empty, which the application reads as unset" "" "$(q "${WORK}/replicas-sentinel.json" 'env("app","REDIS_URL")')"
check "sentinels: and they arrive from .env" "redis-0.acme.internal:26379,redis-1.acme.internal:26379 mymaster" \
  "$(q "${WORK}/replicas-sentinel.json" '[env("app","REDIS_SENTINELS"), env("app","REDIS_SENTINEL_NAME")]')"
check "without the override nothing of this exists" "None None" \
  "$(q "${WORK}/worker.json" '[s.get("lb"), env("app","REDIS_URL")]')"

# ── refusals ─────────────────────────────────────────────────────────────────
fixture_env "${WORK}/noversion.env" "TASKSENSE_VERSION="
render "${WORK}/noversion.env" >/dev/null; rc=$?
check "an unset TASKSENSE_VERSION is refused" "1" "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"
contains "naming the setting" "set TASKSENSE_VERSION in .env" "$(cat "${WORK}/err")"

ENV_PRESENT_AFTER=0; [ -f "${ROOT}/compose/.env" ] && ENV_PRESENT_AFTER=1
check "compose/.env was never created" "${ENV_PRESENT_BEFORE}" "${ENV_PRESENT_AFTER}"

finish
