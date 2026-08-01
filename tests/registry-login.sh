#!/usr/bin/env bash
#
# A stored registry credential is not a working one.
#
#   tests/registry-login.sh
#
# `docker login ghcr.io` succeeds for any token GitHub recognises. Whether that
# token can read *this* package is a different question, and the registry does
# not answer it until the pull. So a mistyped token gets "Login Succeeded", is
# written to config.json, and every later run of the installer reported the
# operator as already signed in while nothing they did worked. That is how it
# was found: by somebody installing for real, not by a test.
#
# These run against a stubbed docker, because what is under test is the
# conclusion the installer draws from the runtime's answers, not the runtime.
# They run through a pty, because prompt_registry_login refuses a pipe on
# purpose — the last case checks that too.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in docker python3; do
  command -v "${tool}" >/dev/null 2>&1 || { printf '\n  SKIPPED: %s is not installed\n\n' "${tool}"; exit 0; }
done

printf '\nregistry login\n\n'

PASS=0
FAIL=0
check() {
  if printf '%s' "$3" | grep -qF "$2"; then
    printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %s\n      wanted to see: %s\n%s\n' "$1" "$2" "$(printf '%s' "$3" | sed 's/^/        /')"
    FAIL=$((FAIL + 1))
  fi
}
refute() {
  if printf '%s' "$3" | grep -qF "$2"; then
    printf '  \033[31m✗\033[0m %s\n      should not have said: %s\n' "$1" "$2"; FAIL=$((FAIL + 1))
  else
    printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
  fi
}

# run_case <config-has-ghcr: yes|no> <answer to "sign in again?">
run_case() {
  python3 "${ROOT}/tests/helpers/pty-run.py" "${ROOT}" "$1" "$2"
}

# ── 1. a credential is already stored ────────────────────────────────────────

out="$(run_case yes n)"

refute "does not claim the stored credential works" "already signed in" "${out}"
check  "says only that something is stored" "already stored on this host" "${out}"
check  "names where it would actually be proven" "only shows at the pull" "${out}"
check  "offers a way to replace it" "Sign in again with a different token?" "${out}"
refute "declining does not then ask for a token anyway" "Registry access" "${out}"
refute "and leaves the stored credential alone" "logout ghcr.io" "${out}"

# ── 2. replacing it ──────────────────────────────────────────────────────────

out="$(run_case yes y)"

check "accepting drops the old credential before asking for another" "logout ghcr.io" "${out}"
check "and then signs in with the new one" "login ghcr.io -u yurdtech" "${out}"
check "and then asks for a new one" "Registry access" "${out}"
check "with somewhere to get one" "info@meiksense.io" "${out}"
check "and a default username, since it is not a credential" "Username [yurdtech]" "${out}"

# ── 3. nothing stored ────────────────────────────────────────────────────────

out="$(run_case no n)"

check  "asks straight away when there is nothing stored" "Registry access" "${out}"
refute "and does not offer to replace what is not there" "Sign in again" "${out}"

# ── 4. no terminal ───────────────────────────────────────────────────────────
# Refusing a pipe is deliberate: the alternative is waiting forever for a token
# nobody can see it asking for, which reads as a hang rather than as a mistake.

out="$(docker run --rm -i -v "${ROOT}:/w:ro" -w /w bash:5 bash -s </dev/null 2>&1 <<'INNER'
set -uo pipefail
export HOME=/tmp/home
mkdir -p "${HOME}/.docker" /tmp/bin
printf '{"auths":{}}' > "${HOME}/.docker/config.json"
{
  echo '#!/usr/bin/env bash'
  echo 'case "$1" in compose) [ "$2" = version ] && exit 0 ;; esac'
  echo 'exit 0'
} > /tmp/bin/docker
chmod +x /tmp/bin/docker
export PATH=/tmp/bin:$PATH
. scripts/lib.sh
detect_runtime
ensure_registry_login
INNER
)"

check "refuses a pipe instead of hanging on an invisible prompt" "there is no terminal to ask on" "${out}"
check "and shows the command to run beforehand" "docker login ghcr.io -u yurdtech" "${out}"

printf '\n  %s passed, %s failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
