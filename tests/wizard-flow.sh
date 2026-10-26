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

set -uo pipefail

# shellcheck source=helpers/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/common.sh"

command -v python3 >/dev/null 2>&1 || skip "python3 is not installed"
docker_usable || skip "no container daemon"

printf '\nwizard flow (through a pty, on bash 5)\n\n'

# bash:5 has no openssl, and generating a secret is one of the things under
# test here.
wizard_test_image || skip "could not build ${WIZARD_TEST_IMAGE}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# The answers, in the order the nine sections ask for them. A menu takes a bare
# digit; everything else takes a line.
VERSION="$(example_version)"
python3 - "${ROOT}" "${WORK}" "${VERSION}" <<'PY'
import os, pty, subprocess, sys, time

root, work, version = sys.argv[1], sys.argv[2], sys.argv[3]

answers = [
    version + "\n",                         # 1 TASKSENSE_VERSION
    "127.0.0.1\n",                          #   BIND_ADDRESS
    "3000\n",                               #   HTTP_PORT
    "https://tasksense.acme.internal\n",     # 2 APP_URL
    "infra@acme.internal\n",                 #   FIRST_ADMIN_EMAIL
    "n\n",                                  #   own certificate authority?
    "g\n",                                  # 3 STORAGE_SECRET: generate
    "1",                                    #   database: bring one with it
    "  tasksense  \n",                      #   MONGO_USER — pasted, with spaces
    "g\n",                                  #   MONGO_PASSWORD: generate
    "n\n",                                  #   licence key?
    "\n",                                   # 4 SESSION_TTL_HOURS: the offered default
    "1",                                    #   sign-in: LDAP (configured in the app, no prompts)
    "n\n",                                  # 5 mail?
    "25\n",                                 # 6 STORAGE_MAX_FILE_MB
    "y\n",                                  #   a Jira site backup to import?
    "\n",                                   #   JIRA_BACKUP_MAX_GB: the offered default
    "n\n",                                  # 7 AI features?
    "1",                                    # 8 log format: json
    "1",                                    #   log level: log
    "n\n",                                  #   metrics?
    "n\n",                                  #   API browser?
    "n\n",                                  #   egress allowlist?
    "2",                                    # 9 sizing: up to 200
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
value_of() { sed -n "s/^$2=//p" "$1" | tail -n1; }

[ -f "${OUT}" ] || { printf '  \033[31m✗\033[0m the wizard wrote nothing\n'; sed 's/^/      /' "${WORK}/transcript.txt" | tail -30; exit 1; }

# Every typed answer, in order — so a question inserted or removed above shows
# up here as a mismatch rather than as a silent one-place shift.
check "TASKSENSE_VERSION as typed" "${VERSION}" "$(value_of "${OUT}" TASKSENSE_VERSION)"
check "BIND_ADDRESS as typed" "127.0.0.1" "$(value_of "${OUT}" BIND_ADDRESS)"
check "HTTP_PORT as typed" "3000" "$(value_of "${OUT}" HTTP_PORT)"
check "APP_URL as typed" "https://tasksense.acme.internal" "$(value_of "${OUT}" APP_URL)"
check "CORS follows APP_URL without being asked" "https://tasksense.acme.internal" \
  "$(value_of "${OUT}" CORS_ALLOWED_ORIGINS)"
check "administrator" "infra@acme.internal" "$(value_of "${OUT}" FIRST_ADMIN_EMAIL)"
# Pasted with spaces around it. `IFS= read` keeps them, and nothing downstream
# would have complained — it produces a value that looks right and fails later.
check "MONGO_USER is trimmed of pasted whitespace" "tasksense" "$(value_of "${OUT}" MONGO_USER)"
# Choosing the bundled database must not leave a URI behind: compose falls back
# to the bundled one only when this is empty.
check "the bundled choice leaves MONGODB_URI unset" "" "$(value_of "${OUT}" MONGODB_URI)"

# The generated secrets: the length is the contract the application enforces.
SECRET="$(value_of "${OUT}" STORAGE_SECRET)"
check "STORAGE_SECRET is at least 32 characters" "ok" \
  "$([ "${#SECRET}" -ge 32 ] && echo ok || echo "only ${#SECRET}")"
check "STORAGE_SECRET is not the example's empty value" "ok" \
  "$([ -n "${SECRET}" ] && echo ok || echo empty)"
MONGO_PW="$(value_of "${OUT}" MONGO_PASSWORD)"
# A function, not a `case` inside $(…): bash 3.2 misparses the pattern's `)`.
uri_safe() { case "$1" in *[/:@?\#%+=]*) echo "contains a URI-reserved character" ;; *) echo ok ;; esac; }
check "MONGO_PASSWORD generated" "ok" "$([ "${#MONGO_PW}" -ge 24 ] && echo ok || echo "only ${#MONGO_PW}")"
# It is substituted into a MongoDB URI by the compose file. base64 emits / + and
# =, and the driver rejects all three there — two in three installs died on it.
check "and is safe to put inside a connection string" "ok" \
  "$(uri_safe "${MONGO_PW}")"

# Choosing LDAP writes NOTHING: there are no LDAP_* variables any more —
# directory sign-in is configured inside the application. The wizard's whole
# job here is to say where the setting moved.
check "no LDAP_URL written" "" "$(value_of "${OUT}" LDAP_URL)"
check "no LDAP_BIND_DN written" "" "$(value_of "${OUT}" LDAP_BIND_DN)"
check "no LDAP_BIND_PASSWORD written" "" "$(value_of "${OUT}" LDAP_BIND_PASSWORD)"

TRANSCRIPT="$(cat "${WORK}/transcript.txt" 2>/dev/null | tr -d '\r')"
check "points the operator at Admin → Authentication" "1" \
  "$(printf '%s' "${TRANSCRIPT}" | grep -q 'Admin → Authentication' && echo 1 || echo 0)"

# Declined sections leave nothing set.
check "no mail configured" "" "$(value_of "${OUT}" SMTP_HOST)"
check "no OIDC configured" "" "$(value_of "${OUT}" OIDC_ISSUER)"
check "no CA bundle configured" "" "$(value_of "${OUT}" NODE_EXTRA_CA_CERTS)"
check "AI off" "off" "$(value_of "${OUT}" AGENT_DISPATCHER)"

# Asked, with the recommended defaults offered.
check "session lifetime: the 12-hour default" "12" "$(value_of "${OUT}" SESSION_TTL_HOURS)"
check "API browser off" "false" "$(value_of "${OUT}" SWAGGER_ENABLED)"
check "the bundled database is the bundled-mongo profile" "none" "$(value_of "${OUT}" MONGODB_COMPRESSORS)"

# A Jira migration: the worker profile, and the API role that must go with it.
check "Jira import: the import-worker profile" "bundled-mongo,import-worker" "$(value_of "${OUT}" COMPOSE_PROFILES)"
check "and WORKER_ROLE=api with it" "api" "$(value_of "${OUT}" WORKER_ROLE)"
check "the backup ceiling's default" "20" "$(value_of "${OUT}" JIRA_BACKUP_MAX_GB)"

# Never asked, never on: no execution sandbox ships on-premise.
check "AGENT_EXECUTOR is off" "off" "$(value_of "${OUT}" AGENT_EXECUTOR)"
check "and the wizard never offers it" "0" "$(printf '%s' "$(tr -d '\r' < "${WORK}/transcript.txt")" | grep -c 'Enable the agent executor' || true)"

check "no <CHANGE_ME_…> placeholder is left" "0" "$(grep -c '^[A-Z_]*=.*<CHANGE_ME' "${OUT}" || true)"
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
check "the heap is about 75% of the app's limit" "3072" "$(value_of "${OUT}" APP_HEAP_MB)"
check "MongoDB's cache about half of its own" "2" "$(value_of "${OUT}" MONGO_CACHE_GB)"

# What install.sh will refuse to start without.
for key in TASKSENSE_VERSION APP_URL STORAGE_SECRET MONGO_USER MONGO_PASSWORD; do
  check "required present: ${key}" "1" "$(grep -c "^${key}=." "${OUT}")"
done

finish
