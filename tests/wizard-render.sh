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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The code under test needs bash 4, and macOS ships 3.2. Re-run inside a
# container rather than skipping: a test that quietly does nothing on the
# machine most of this was written on is worse than no test.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] && [ -z "${TASKSENSE_TEST_CONTAINER:-}" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    printf '\n  SKIPPED: needs bash 4 (this is %s) and docker is not installed\n\n' "${BASH_VERSION}"
    exit 0
  fi
  exec docker run --rm -e TASKSENSE_TEST_CONTAINER=1 \
    -v "${ROOT}:/w" -w /w bash:5 ./tests/wizard-render.sh
fi

EXAMPLE="${ROOT}/compose/.env.example"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    printf '  \033[32m✓\033[0m %s\n' "${name}"
    PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %s\n' "${name}"
    printf '      expected: %s\n      actual:   %s\n' "${expected}" "${actual}"
    FAIL=$((FAIL + 1))
  fi
}

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
# What the wizard collects from somebody installing with Active Directory.

cat > "${WORK}/answers.env" <<'EOF'
TASKSENSE_VERSION=1.0.0
BIND_ADDRESS=127.0.0.1
HTTP_PORT=3000
APP_URL=https://tasksense.abb.internal
CORS_ALLOWED_ORIGINS=https://tasksense.abb.internal
FIRST_ADMIN_EMAIL=infra@abb.internal
STORAGE_SECRET=Zt7xKQm2vN8pLdR4sYcW1jH6bF0aGuEo9iTnMkPx3vQ=
MONGO_USER=tasksense
MONGO_PASSWORD=hV2mQ8sLpX4tZnB7kRdY
LDAP_URL=ldaps://dc01.abb.internal:636
LDAP_BIND_DN=CN=svc-tasksense,OU=Service Accounts,DC=abb,DC=internal
LDAP_BIND_PASSWORD=bind-secret
LDAP_BASE_DN=DC=abb,DC=internal
LDAP_USER_FILTER=(sAMAccountName={{username}})
STORAGE_MAX_FILE_MB=25
AGENT_EXECUTOR=off
AGENT_DISPATCHER=off
LOG_FORMAT=json
LOG_LEVEL=info
APP_CPU_LIMIT=4
APP_MEMORY_LIMIT=8g
MONGO_CPU_LIMIT=4
MONGO_MEMORY_LIMIT=8g
EOF

render "${WORK}/answers.env" "${WORK}/rendered.env"

# The claim, stated as a test: same keys, same order, none lost, none invented.
check "key set matches .env.example exactly" \
  "$(keys_of "${EXAMPLE}")" "$(keys_of "${WORK}/rendered.env")"

check "no key is lost" "0" \
  "$(comm -23 <(keys_of "${EXAMPLE}" | sort -u) <(keys_of "${WORK}/rendered.env" | sort -u) | wc -l | tr -d ' ')"

check "no key is invented" "0" \
  "$(comm -13 <(keys_of "${EXAMPLE}" | sort -u) <(keys_of "${WORK}/rendered.env" | sort -u) | wc -l | tr -d ' ')"

# The answers actually landed.
check "APP_URL written" "https://tasksense.abb.internal" "$(value_of "${WORK}/rendered.env" APP_URL)"
check "STORAGE_SECRET written" "Zt7xKQm2vN8pLdR4sYcW1jH6bF0aGuEo9iTnMkPx3vQ=" \
  "$(value_of "${WORK}/rendered.env" STORAGE_SECRET)"

# An optional the operator answered is uncommented; one they did not stays
# commented, so the file still documents it in place.
check "answered optional is active" "1" \
  "$(active_keys_of "${WORK}/rendered.env" | grep -c '^LDAP_URL$')"
check "unanswered optional stays commented" "0" \
  "$(active_keys_of "${WORK}/rendered.env" | grep -c '^OIDC_ISSUER$' || true)"

# A value containing = and { } survives — LDAP filters and DNs are full of both,
# and a naive sed-based renderer mangles them.
check "LDAP_USER_FILTER survives intact" "(sAMAccountName={{username}})" \
  "$(value_of "${WORK}/rendered.env" LDAP_USER_FILTER)"
check "LDAP_BIND_DN survives its commas and equals signs" \
  "CN=svc-tasksense,OU=Service Accounts,DC=abb,DC=internal" \
  "$(value_of "${WORK}/rendered.env" LDAP_BIND_DN)"

# The comments are the reason for rendering the example rather than emitting a
# minimal file. Losing them would make .env unreadable to the next operator.
#
# Prose only: `#LDAP_URL=` is a commented-out setting, and answering it is
# supposed to uncomment it. Counting those as comments would make this test fail
# for the renderer doing its job.
prose_comments() { grep -c '^#\([^A-Z]\|$\)' "$1"; }
check "explanatory comments are preserved" \
  "$(prose_comments "${EXAMPLE}")" "$(prose_comments "${WORK}/rendered.env")"

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1"; }
check "written mode 600" "600" "$(mode_of "${WORK}/rendered.env")"

# ── 2. A hand-added setting is not silently dropped ──────────────────────────
# Someone sets something we do not ship a default for, then reconfigures. The
# worst outcome is that it disappears and the symptom appears somewhere else.

cp "${WORK}/answers.env" "${WORK}/answers-extra.env"
printf 'NODE_EXTRA_CA_CERTS=/certs/bank-ca.pem\n' >> "${WORK}/answers-extra.env"
render "${WORK}/answers-extra.env" "${WORK}/rendered-extra.env"

check "hand-added setting is kept" "/certs/bank-ca.pem" \
  "$(value_of "${WORK}/rendered-extra.env" NODE_EXTRA_CA_CERTS)"
check "and it is labelled as not being from the example" "1" \
  "$(grep -c 'Settings added on this host' "${WORK}/rendered-extra.env")"

# ── 3. Rendering is idempotent ───────────────────────────────────────────────
# Reconfiguring twice must not accumulate anything. `./tasksense` → Configure is
# a normal thing to do repeatedly.

render "${WORK}/rendered.env" "${WORK}/rendered-twice.env"
check "second render is identical to the first" "" \
  "$(diff "${WORK}/rendered.env" "${WORK}/rendered-twice.env" || true)"

# ── 4. Nothing the application requires is missing ───────────────────────────
# install.sh refuses to start without these; the wizard must always produce them.

for key in TASKSENSE_VERSION APP_URL STORAGE_SECRET MONGO_USER MONGO_PASSWORD; do
  check "required: ${key}" "1" "$(active_keys_of "${WORK}/rendered.env" | grep -c "^${key}$")"
done

printf '\n  %s passed, %s failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
