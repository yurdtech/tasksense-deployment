#!/usr/bin/env bash
#
# The wizard must not become a second way to configure TaskSense.
#
# Everything the installer writes goes through configure.sh's renderer, and the
# renderer's contract is: the file it produces is .env.example with values
# filled in — same keys, same order, same comments, nothing invented and
# nothing dropped. If that ever stops being true we have two configuration
# formats, one of them undocumented, and a support call about a missing setting
# has no good answer.
#
#   tests/wizard-render.sh
#
# Runs in a temporary directory. Touches nothing in compose/.

set -euo pipefail

# shellcheck source=helpers/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/common.sh"

# The code under test needs bash 4, and macOS ships 3.2. Re-run inside a
# container rather than skipping: a test that quietly does nothing on the
# machine most of this was written on is worse than no test.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] && [ -z "${TASKSENSE_TEST_CONTAINER:-}" ]; then
  docker_usable || skip "needs bash 4 (this is ${BASH_VERSION}) or a container daemon to run bash:5"
  exec docker run --rm -e TASKSENSE_TEST_CONTAINER=1 \
    -v "${ROOT}:/w" -w /w bash:5 ./tests/wizard-render.sh
fi

EXAMPLE="${ROOT}/compose/.env.example"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Every key the file mentions, commented or not, in order.
keys_of() { sed -n 's/^#\{0,1\}\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$1"; }
# Only the keys that are actually set.
active_keys_of() { sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$1"; }
value_of() { sed -n "s/^$2=//p" "$1" | tail -n1; }

render() {  # render <answers-file> <output>
  TASKSENSE_ENV_FILE="$1" "${ROOT}/scripts/wizard/configure.sh" --render-only "$2"
}

printf '\nwizard renderer\n\n'

# ── 1. A full answer set ─────────────────────────────────────────────────────
# What the wizard collects for an OIDC installation with the bundled database
# and the import worker. (LDAP is configured in the application, so no LDAP_*
# answers exist for the renderer to place.)

cat > "${WORK}/answers.env" <<EOF
TASKSENSE_VERSION=$(example_version)
COMPOSE_PROFILES=bundled-mongo,import-worker
WORKER_ROLE=api
BIND_ADDRESS=127.0.0.1
HTTP_PORT=3000
APP_URL=https://tasksense.abb.internal
CORS_ALLOWED_ORIGINS=https://tasksense.abb.internal
FIRST_ADMIN_EMAIL=infra@abb.internal
NODE_EXTRA_CA_CERTS=/certs/abb-ca.pem
STORAGE_SECRET=Zt7xKQm2vN8pLdR4sYcW1jH6bF0aGuEo9iTnMkPx3vQ=
MONGO_USER=tasksense
MONGO_PASSWORD=hV2mQ8sLpX4tZnB7kRdY
MONGODB_COMPRESSORS=none
SESSION_TTL_HOURS=12
OIDC_ISSUER=https://sso.abb.internal/realms/corporate
OIDC_CLIENT_ID=tasksense
OIDC_CLIENT_SECRET=s3cr{e}t=with,braces=and.equals
STORAGE_MAX_FILE_MB=25
JIRA_BACKUP_MAX_GB=40
AGENT_EXECUTOR=off
AGENT_DISPATCHER=off
SWAGGER_ENABLED=false
LOG_FORMAT=json
LOG_LEVEL=log
APP_HEAP_MB=3072
APP_CPU_LIMIT=2
APP_MEMORY_LIMIT=4g
MONGO_CACHE_GB=2
MONGO_CPU_LIMIT=2
MONGO_MEMORY_LIMIT=4g
EOF

render "${WORK}/answers.env" "${WORK}/rendered.env"

# The claim, stated as a test: same keys, same order, none lost, none invented.
check "key set matches .env.example exactly" \
  "$(keys_of "${EXAMPLE}")" "$(keys_of "${WORK}/rendered.env")"

check "no key is lost" "0" \
  "$(comm -23 <(keys_of "${EXAMPLE}" | sort -u) <(keys_of "${WORK}/rendered.env" | sort -u) | wc -l | tr -d ' ')"

check "no key is invented" "0" \
  "$(comm -13 <(keys_of "${EXAMPLE}" | sort -u) <(keys_of "${WORK}/rendered.env" | sort -u) | wc -l | tr -d ' ')"

check "the example names no key twice — the renderer would uncomment both" "" \
  "$(keys_of "${EXAMPLE}" | sort | uniq -d)"

# The answers actually landed.
check "APP_URL written" "https://tasksense.abb.internal" "$(value_of "${WORK}/rendered.env" APP_URL)"
check "STORAGE_SECRET written" "Zt7xKQm2vN8pLdR4sYcW1jH6bF0aGuEo9iTnMkPx3vQ=" \
  "$(value_of "${WORK}/rendered.env" STORAGE_SECRET)"
check "profiles written" "bundled-mongo,import-worker" "$(value_of "${WORK}/rendered.env" COMPOSE_PROFILES)"
check "and the worker's role with them" "api" "$(value_of "${WORK}/rendered.env" WORKER_ROLE)"
check "the CA bundle is uncommented where the example documents it" "1" \
  "$(active_keys_of "${WORK}/rendered.env" | grep -c '^NODE_EXTRA_CA_CERTS$')"
check "no <CHANGE_ME_…> placeholder survives a full answer set" "0" \
  "$(grep -c '^[A-Z_]*=.*<CHANGE_ME' "${WORK}/rendered.env" || true)"

# An optional the operator answered is uncommented; one they did not stays
# commented, so the file still documents it in place.
check "answered optional is active" "1" \
  "$(active_keys_of "${WORK}/rendered.env" | grep -c '^OIDC_ISSUER$')"
check "unanswered optional stays commented" "0" \
  "$(active_keys_of "${WORK}/rendered.env" | grep -c '^SMTP_HOST$' || true)"

# A value containing = , { } survives — secrets and URLs are full of such
# characters, and a naive sed-based renderer mangles them.
check "OIDC_CLIENT_SECRET survives its braces, commas and equals signs" \
  "s3cr{e}t=with,braces=and.equals" \
  "$(value_of "${WORK}/rendered.env" OIDC_CLIENT_SECRET)"

# The comments are the reason for rendering the example rather than emitting a
# minimal file. Losing them would make .env unreadable to the next operator.
#
# Prose only: `#OIDC_ISSUER=` is a commented-out setting, and answering it is
# supposed to uncomment it. Counting those as comments would make this test fail
# for the renderer doing its job.
prose_comments() { grep -c '^#\([^A-Z]\|$\)' "$1"; }
check "explanatory comments are preserved" \
  "$(prose_comments "${EXAMPLE}")" "$(prose_comments "${WORK}/rendered.env")"

check "written mode 600" "600" "$(mode_of "${WORK}/rendered.env")"

# ── 2. Your own MongoDB: the example's ACTIVE placeholders are emptied ───────
# MONGO_PASSWORD ships as <CHANGE_ME_…> and COMPOSE_PROFILES as bundled-mongo.
# An empty answer for either must be written empty — copying the example line
# would leave a placeholder preflight refuses, or a database nobody wants.

grep -v -e '^COMPOSE_PROFILES=' -e '^WORKER_ROLE=' -e '^MONGO_USER=' -e '^MONGO_PASSWORD=' "${WORK}/answers.env" > "${WORK}/external.env"
cat >> "${WORK}/external.env" <<'EOF'
COMPOSE_PROFILES=
WORKER_ROLE=all
MONGO_USER=
MONGO_PASSWORD=
MONGODB_URI=mongodb://ts:pw@mongo-0.abb.internal:27017/?replicaSet=rs0&tls=true&tlsCAFile=/certs/abb-ca.pem&authSource=admin
MONGODB_COMPRESSORS=zlib
MONGODB_TIMEOUT_MS=15000
EOF
render "${WORK}/external.env" "${WORK}/rendered-external.env"
check "COMPOSE_PROFILES is written empty, not left at bundled-mongo" "1" \
  "$(grep -c '^COMPOSE_PROFILES=$' "${WORK}/rendered-external.env")"
check "MONGO_PASSWORD is written empty, not left a placeholder" "1" \
  "$(grep -c '^MONGO_PASSWORD=$' "${WORK}/rendered-external.env")"
check "the URI lands where the example documents it" "1" \
  "$(active_keys_of "${WORK}/rendered-external.env" | grep -c '^MONGODB_URI$')"
check "and the network-tuned timeout is uncommented" "15000" "$(value_of "${WORK}/rendered-external.env" MONGODB_TIMEOUT_MS)"
check "still no placeholder" "0" "$(grep -c '^[A-Z_]*=.*<CHANGE_ME' "${WORK}/rendered-external.env" || true)"
check "and still the example's key set" "$(keys_of "${EXAMPLE}")" "$(keys_of "${WORK}/rendered-external.env")"

# ── 3. A hand-added setting is not silently dropped ──────────────────────────
# Someone sets something we do not ship a default for, then reconfigures. The
# worst outcome is that it disappears and the symptom appears somewhere else.

cp "${WORK}/answers.env" "${WORK}/answers-extra.env"
printf 'STATE_COMMENT_LIMIT=20000\n' >> "${WORK}/answers-extra.env"
render "${WORK}/answers-extra.env" "${WORK}/rendered-extra.env"

check "hand-added setting is kept" "20000" \
  "$(value_of "${WORK}/rendered-extra.env" STATE_COMMENT_LIMIT)"
check "and it is labelled as not being from the example" "1" \
  "$(grep -c 'Settings added on this host' "${WORK}/rendered-extra.env")"

# ── 4. Rendering is idempotent ───────────────────────────────────────────────
# Reconfiguring twice must not accumulate anything. `./tasksense` → Configure is
# a normal thing to do repeatedly.

render "${WORK}/rendered.env" "${WORK}/rendered-twice.env"
check "second render is identical to the first" "" \
  "$(diff "${WORK}/rendered.env" "${WORK}/rendered-twice.env" || true)"
render "${WORK}/rendered-external.env" "${WORK}/rendered-external-twice.env"
check "including one with emptied placeholders" "" \
  "$(diff "${WORK}/rendered-external.env" "${WORK}/rendered-external-twice.env" || true)"

# ── 5. Nothing the application requires is missing ───────────────────────────
# install.sh refuses to start without these; the wizard must always produce them.

for key in TASKSENSE_VERSION APP_URL STORAGE_SECRET MONGO_USER MONGO_PASSWORD COMPOSE_PROFILES; do
  check "required: ${key}" "1" "$(active_keys_of "${WORK}/rendered.env" | grep -c "^${key}$")"
done

finish
