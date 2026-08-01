#!/usr/bin/env bash
#
# Drives the configuration flow the way a person does: through a terminal.
#
#   tests/wizard-flow.sh
#
# The renderer test (wizard-render.sh) checks what comes out. This checks the
# part it cannot reach — the questions themselves. ui_ask, ui_secret, ui_menu
# and ui_yesno all read from a terminal, so a test that pipes into them proves
# nothing: they refuse a pipe on purpose. This allocates a real pty.
#
# It runs in a container rather than on the developer's machine, because that is
# also the bash-4 check: macOS ships bash 3.2, every supported host does not.
#
# Needs docker and python3. Skips itself, loudly, without them.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=tasksense-wizard-test

for tool in docker python3; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf '\n  SKIPPED: %s is not installed\n\n' "${tool}"
    exit 0
  }
done

printf '\nwizard flow (through a pty, on bash 5)\n\n'

# bash:5 has no openssl, and generating a secret is one of the things under
# test here.
docker build -q -t "${IMAGE}" - >/dev/null <<'DOCKERFILE'
FROM bash:5
RUN apk add --no-cache openssl coreutils ncurses
DOCKERFILE

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# The answers, in the order the nine sections ask for them. A menu takes a bare
# digit; everything else takes a line.
python3 - "${ROOT}" "${WORK}" <<'PY'
import os, pty, subprocess, sys, time

root, work = sys.argv[1], sys.argv[2]

answers = [
    "1.0.0\n",                              # TASKSENSE_VERSION
    "127.0.0.1\n",                          # BIND_ADDRESS
    "3000\n",                               # HTTP_PORT
    "https://tasksense.abb.internal\n",     # APP_URL
    "infra@abb.internal\n",                 # FIRST_ADMIN_EMAIL
    "g\n",                                  # STORAGE_SECRET: generate
    "  tasksense  \n",                      # MONGO_USER — pasted, with spaces
    "g\n",                                  # MONGO_PASSWORD: generate
    "n\n",                                  # licence key?
    "1",                                    # sign-in: LDAP  (menu, no newline)
    "ldaps://dc01.abb.internal:636\n",      # LDAP_URL
    "CN=svc-tasksense,OU=Service Accounts,DC=abb,DC=internal\n",
    "bind-secret\n",                        # LDAP_BIND_PASSWORD
    "DC=abb,DC=internal\n",                 # LDAP_BASE_DN
    "(sAMAccountName={{username}})\n",      # LDAP_USER_FILTER
    "y\n",                                  # own CA?
    " /certs/abb-ca.crt\n",                 # LDAP_TLS_CA — pasted, leading space
    "n\n",                                  # group map?
    "n\n",                                  # mail?
    "25\n",                                 # STORAGE_MAX_FILE_MB
    "n\n",                                  # AI features?
    "1",                                    # log format: json
    "1",                                    # log level: log
    "n\n",                                  # metrics?
    "n\n",                                  # egress allowlist?
    "2",                                    # sizing: up to 200
]

# --user matters, and not only for tidiness. The wizard writes the candidate
# with mode 600 — it holds the storage key and the database password. Written by
# root inside the container, that file lands on a Linux host owned by root and
# unreadable to the user running this, and every assertion below fails on
# "Permission denied" rather than on anything real. It passes on macOS, where
# Docker Desktop maps ownership to the calling user. Same shape as the other two
# platform bugs this suite exists for.
cmd = [
    "docker", "run", "--rm", "-i", "-t",
    "--user", f"{os.getuid()}:{os.getgid()}",
    "-v", f"{root}:/w", "-v", f"{work}:/out", "-w", "/w",
    "-e", "TERM=xterm", "-e", "HOME=/tmp",
    "tasksense-wizard-test",
    "./scripts/wizard/configure.sh", "--collect", "/out/candidate.env",
]

primary, secondary = pty.openpty()
proc = subprocess.Popen(cmd, stdin=secondary, stdout=secondary, stderr=secondary, close_fds=True)
os.close(secondary)
os.set_blocking(primary, False)

transcript = bytearray()

def drain(idle=0.6, limit=60):
    """Read until the wizard stops printing, i.e. it is waiting for an answer.

    Answering on a fixed cadence instead would drift the moment a validator
    rejects something and re-asks — and the drift is invisible, because every
    later answer still lands on *a* question. Ask this test how it knows the
    answers lined up and the honest reply has to be more than "it looked right"."""
    last = time.time()
    end = last + limit
    while time.time() - last < idle and time.time() < end:
        try:
            chunk = os.read(primary, 65536)
            if chunk:
                transcript.extend(chunk)
                last = time.time()
                continue
        except (BlockingIOError, OSError):
            pass
        if proc.poll() is not None:
            break
        time.sleep(0.05)

for answer in answers:
    if proc.poll() is not None:
        break
    drain()
    os.write(primary, answer.encode())
drain(idle=2.0)

proc.wait(timeout=30)
open(os.path.join(work, "transcript.txt"), "wb").write(bytes(transcript))
sys.exit(0 if proc.returncode == 0 else 1)
PY

OUT="${WORK}/candidate.env"
PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}
value_of() { sed -n "s/^$2=//p" "$1" | tail -n1; }

[ -f "${OUT}" ] || { printf '  \033[31m✗\033[0m the wizard wrote nothing\n'; sed 's/^/      /' "${WORK}/transcript.txt" | tail -30; exit 1; }

# Every typed answer, in order — so a question inserted or removed above shows
# up here as a mismatch rather than as a silent one-place shift.
check "TASKSENSE_VERSION as typed" "1.0.0" "$(value_of "${OUT}" TASKSENSE_VERSION)"
check "BIND_ADDRESS as typed" "127.0.0.1" "$(value_of "${OUT}" BIND_ADDRESS)"
check "HTTP_PORT as typed" "3000" "$(value_of "${OUT}" HTTP_PORT)"
check "APP_URL as typed" "https://tasksense.abb.internal" "$(value_of "${OUT}" APP_URL)"
check "CORS follows APP_URL without being asked" "https://tasksense.abb.internal" \
  "$(value_of "${OUT}" CORS_ALLOWED_ORIGINS)"
check "administrator" "infra@abb.internal" "$(value_of "${OUT}" FIRST_ADMIN_EMAIL)"
# Pasted with spaces around it. `IFS= read` keeps them, and nothing downstream
# would have complained — it produces a value that looks right and fails later.
check "MONGO_USER is trimmed of pasted whitespace" "tasksense" "$(value_of "${OUT}" MONGO_USER)"

# The generated secrets: the length is the contract the application enforces.
SECRET="$(value_of "${OUT}" STORAGE_SECRET)"
check "STORAGE_SECRET is at least 32 characters" "ok" \
  "$([ "${#SECRET}" -ge 32 ] && echo ok || echo "only ${#SECRET}")"
check "STORAGE_SECRET is not the example's empty value" "ok" \
  "$([ -n "${SECRET}" ] && echo ok || echo empty)"
MONGO_PW="$(value_of "${OUT}" MONGO_PASSWORD)"
check "MONGO_PASSWORD generated" "ok" "$([ "${#MONGO_PW}" -ge 24 ] && echo ok || echo "only ${#MONGO_PW}")"

# The menu selection routed to the LDAP sub-flow, and the awkward characters
# made it through a terminal intact.
check "LDAP_URL" "ldaps://dc01.abb.internal:636" "$(value_of "${OUT}" LDAP_URL)"
check "LDAP_BIND_DN keeps its commas and equals signs" \
  "CN=svc-tasksense,OU=Service Accounts,DC=abb,DC=internal" "$(value_of "${OUT}" LDAP_BIND_DN)"
check "LDAP_USER_FILTER keeps its braces" "(sAMAccountName={{username}})" \
  "$(value_of "${OUT}" LDAP_USER_FILTER)"

# The one that was actually reported: a leading space here is invisible, has no
# validator to catch it, and surfaces as "no such file or directory, open
# ' /certs/abb-ca.crt'" long afterwards.
check "LDAP_TLS_CA is trimmed" "/certs/abb-ca.crt" "$(value_of "${OUT}" LDAP_TLS_CA)"

# And the file is not on this host, so it says so while the path is still in
# the operator's head rather than leaving it to the live checks.
TRANSCRIPT="$(cat "${WORK}/transcript.txt" 2>/dev/null | tr -d '\r')"
check "warns that the CA file is not in compose/certs" "1" \
  "$(printf '%s' "${TRANSCRIPT}" | grep -c 'no abb-ca.crt in' || true)"

# Declined sections leave nothing set.
check "no mail configured" "" "$(value_of "${OUT}" SMTP_HOST)"
check "no OIDC configured" "" "$(value_of "${OUT}" OIDC_ISSUER)"
check "AI off" "off" "$(value_of "${OUT}" AGENT_DISPATCHER)"
check "log format" "json" "$(value_of "${OUT}" LOG_FORMAT)"
# Asked for, not copied from .env.example. It was copied, and the example held
# a value the application rejects — see tests/env-example.sh.
check "log level is one the application accepts" "log" "$(value_of "${OUT}" LOG_LEVEL)"

# The sizing menu.
# docs/11-SIZING.md gives 4 cores and 8 GB for 200 users, for the host; the
# wizard splits that between the two containers, as the same page says to.
check "sizing chose the 200-user row" "2" "$(value_of "${OUT}" APP_CPU_LIMIT)"
check "app memory is half the host's 8 GB" "4g" "$(value_of "${OUT}" APP_MEMORY_LIMIT)"
check "mongo gets the other half" "4g" "$(value_of "${OUT}" MONGO_MEMORY_LIMIT)"

# What install.sh will refuse to start without.
for key in TASKSENSE_VERSION APP_URL STORAGE_SECRET MONGO_USER MONGO_PASSWORD; do
  check "required present: ${key}" "1" "$(grep -c "^${key}=." "${OUT}")"
done

printf '\n  %s passed, %s failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
