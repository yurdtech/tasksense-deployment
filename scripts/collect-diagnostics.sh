#!/usr/bin/env bash
#
# Bundles what support needs to diagnose a problem, with secrets removed.
#
#   ./scripts/collect-diagnostics.sh
#
# Collects: versions, container status, resource usage, recent logs, and your
# configuration with every secret replaced by <redacted>. Review the archive
# before sending it — it is a plain tarball and you can open it.
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
compose logs --tail 500 mongo > "${STAGE}/mongo.log" 2>&1 || true
ok "logs (last 2000 lines)"

# Redact anything that looks like a credential. Allowlist by key name rather
# than pattern-matching values: a password can look like anything, but the key
# it sits under is predictable.
if [ -f "${ENV_FILE}" ]; then
  sed -E 's/^([A-Z_]*(PASSWORD|SECRET|TOKEN|KEY|PASS)[A-Z_]*)=.*/\1=<redacted>/' \
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
