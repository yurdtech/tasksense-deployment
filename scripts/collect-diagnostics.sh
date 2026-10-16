#!/usr/bin/env bash
#
# Bundles what support needs to diagnose a problem, with secrets removed.
#
#   ./scripts/collect-diagnostics.sh
#
# Collects: versions, container status, resource usage, recent logs of every
# service (app, worker, migrate, mongo), the migration status, the preflight
# report, and your configuration with every secret replaced by <redacted>.
# Review the archive before sending it — it is a plain tarball you can open.
#
# It does NOT include your database, uploaded files, or any task content.

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

detect_runtime

STAMP="$(date -u +%Y%m%d-%H%M%SZ)"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
OUT="${ROOT_DIR}/tasksense-diagnostics-${STAMP}.tar.gz"

step "Collecting"

{
  echo "collected: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host:      $(hostname)"
  echo "kernel:    $(uname -a)"
  echo "runtime:   $("${RUNTIME}" --version 2>&1 | head -n1)"
  echo "compose:   $("${COMPOSE[@]}" version 2>&1 | head -n1)"
  echo "profiles:  $(env_profiles 2>/dev/null)"
  echo "database:  $(if bundled_mongo_enabled; then echo bundled; else uri_redacted "$(env_value MONGODB_URI)"; fi)"
  echo
  echo "== running version =="
  running_version || echo "(unreachable)"
  echo
  echo "== disk =="
  df -h 2>/dev/null || true
  echo
  echo "== memory =="
  free -h 2>/dev/null || vm_stat 2>/dev/null || true
} > "${STAGE}/system.txt" 2>&1
ok "system information"

compose ps > "${STAGE}/containers.txt" 2>&1 || true
"${RUNTIME}" stats --no-stream >> "${STAGE}/containers.txt" 2>&1 || true
ok "container status"

compose logs --tail 2000 app > "${STAGE}/app.log" 2>&1 || true
compose logs --tail 200 migrate > "${STAGE}/migrate.log" 2>&1 || true
import_worker_enabled && { compose logs --tail 2000 worker > "${STAGE}/worker.log" 2>&1 || true; }
bundled_mongo_enabled && { compose logs --tail 500 mongo > "${STAGE}/mongo.log" 2>&1 || true; }
ok "logs (last 2000 lines per service)"

# Which migrations are applied and pending — the first question on any
# upgrade ticket. Redacted by the CLI itself (it never prints the password).
if [ -f "${ENV_FILE}" ]; then
  compose run --rm -T migrate node dist/database/migrations/cli.js status > "${STAGE}/migrations.txt" 2>&1 || true
  NO_COLOR=1 "${SCRIPT_DIR}/preflight.sh" --offline > "${STAGE}/preflight.txt" 2>&1 || true
  ok "migration status and preflight report"
fi

# Redact anything that looks like a credential. Allowlist by key name rather
# than pattern-matching values: a password can look like anything, but the key
# it sits under is predictable.
if [ -f "${ENV_FILE}" ]; then
  # Second expression: credentials embedded in URIs (MONGODB_URI and the
  # like), which no key name matches.
  sed -E -e 's/^([A-Z_]*(PASSWORD|SECRET|TOKEN|KEY|PASS)[A-Z_]*)=.*/\1=<redacted>/' \
         -e 's#(://)[^@/[:space:]]+@#\1<redacted>@#g' \
      "${ENV_FILE}" > "${STAGE}/env.redacted"
  ok "configuration (secrets redacted)"

  if grep -qE '=<redacted>' "${STAGE}/env.redacted"; then
    note "$(grep -cE '=<redacted>' "${STAGE}/env.redacted") value(s) redacted"
  fi
fi

tar czf "${OUT}" -C "${STAGE}" .
chmod 600 "${OUT}"

step "Done"
ok "${OUT}"
cat <<EOF

  Please review it before sending — logs can contain user names, email
  addresses and task titles:

    tar tzf ${OUT}
    tar xzOf ${OUT} ./env.redacted

  Send to your support contact with a description of what you expected and
  what happened instead.
EOF
