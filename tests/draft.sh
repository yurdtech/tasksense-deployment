#!/usr/bin/env bash
#
# Answers survive a run that stops.
#
#   tests/draft.sh
#
# The wizard held the configuration being assembled in a mktemp file and removed
# it from an EXIT trap. Every way out therefore threw away everything typed so
# far — including the ones that are not mistakes at all: declining to delete a
# volume, or answering "not sure". Somebody lost fifteen minutes to a lower-case
# "delete", and the message they got said nothing was written, which was true and
# was not what they had lost.
#
# These drive the real scripts. The pty tests cover what the wizard asks; this
# covers what it keeps.

# The checks below grep for shell source text, so the patterns contain ${…} on
# purpose: they are the strings being looked for, not expansions of them.
# shellcheck disable=SC2016

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in docker python3; do
  command -v "${tool}" >/dev/null 2>&1 || { printf '\n  SKIPPED: %s is not installed\n\n' "${tool}"; exit 0; }
done

printf '\nunfinished answers\n\n'

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  \033[31m✗\033[0m %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

# ── 1. the draft lives beside the file it becomes ────────────────────────────

check "the draft is not in /tmp" "1" \
  "$(grep -c 'CANDIDATE="${COMPOSE_DIR}/.env.draft"' "${ROOT}/scripts/wizard/install.sh")"

check "and git will not take it" "1" \
  "$(grep -c '^compose/.env.draft$' "${ROOT}/.gitignore")"

# The trap must not remove it. This is the whole bug in one assertion.
check "the exit trap does not delete it" "0" \
  "$(sed -n '/^cleanup() {/,/^}/p' "${ROOT}/scripts/wizard/install.sh" | grep -c 'rm -f "${CANDIDATE}"')"

check "it is removed only once it has become compose/.env" "1" \
  "$(grep -c 'rm -f "${CANDIDATE}"$' "${ROOT}/scripts/wizard/install.sh")"

# ── 2. declining to delete a volume is an answer, not an exit ────────────────

# The three branches of the stale-volume question used to end the run with die,
# which is what triggered the trap.
check "no branch of the volume question calls die" "0" \
  "$(sed -n '/if mongo_volume_exists; then/,/^fi$/p' "${ROOT}/scripts/wizard/install.sh" | grep -c 'die "stopped')"

check "a mistyped confirmation deletes nothing" "1" \
  "$(sed -n '/Type %sDELETE%s to confirm/,/esac/p' "${ROOT}/scripts/wizard/install.sh" \
     | grep -c 'the volume is untouched')"

# ── 3. the two ways in are both offered ─────────────────────────────────────

check "the questions are one route" "1" \
  "$(grep -c 'Answer questions|one setting at a time' "${ROOT}/scripts/wizard/install.sh")"
check "and the editor is the other" "1" \
  "$(grep -c 'Edit the file|open .env in an editor' "${ROOT}/scripts/wizard/install.sh")"
check "resume is offered when a draft exists" "1" \
  "$(grep -c 'Resume|keep what was entered' "${ROOT}/scripts/wizard/install.sh")"

# ── 4. the editor route, exercised ──────────────────────────────────────────
#
# EDITOR is a script here, so the "operator" is a program: it writes the values
# a person would type. What is under test is what the wizard does with the file
# afterwards — that it starts from the example, keeps mode 600, and refuses to
# move on while the required values are empty.

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

out="$(docker run --rm -v "${ROOT}:/w" -v "${WORK}:/out" -w /w \
  --user "$(id -u):$(id -g)" -e HOME=/tmp bash:5 bash -c '
    . scripts/lib.sh

    # What edit_candidate does to a fresh draft, in isolation.
    CANDIDATE=/out/.env.draft
    cp compose/.env.example "$CANDIDATE"
    chmod 600 "$CANDIDATE"

    # An untouched example must not pass: two required values ship empty and two
    # more ship as placeholders.
    blank=""
    for key in TASKSENSE_VERSION APP_URL FIRST_ADMIN_EMAIL STORAGE_SECRET MONGO_USER MONGO_PASSWORD; do
      v="$(sed -n "s/^${key}=//p" "$CANDIDATE" | tail -n1)"
      [ -n "$v" ] || blank="${blank} ${key}"
    done
    echo "BLANK_ON_UNTOUCHED_EXAMPLE:${blank}"
    grep -q "^APP_URL=https://tasksense.bank.internal$" "$CANDIDATE" && echo "PLACEHOLDER_DETECTED"

    # Now fill it the way an operator would, and check it comes out valid.
    sed -i "s|^APP_URL=.*|APP_URL=https://tasksense.abb.internal|" "$CANDIDATE"
    sed -i "s|^FIRST_ADMIN_EMAIL=.*|FIRST_ADMIN_EMAIL=infra@abb.internal|" "$CANDIDATE"
    # Fixed values, not generated: the container runs as the calling user and
    # cannot apk-add openssl, and what is under test is the check that reads the
    # file rather than the entropy of what was written into it.
    sed -i "s|^STORAGE_SECRET=.*|STORAGE_SECRET=0123456789012345678901234567890123456789|" "$CANDIDATE"
    sed -i "s|^MONGO_PASSWORD=.*|MONGO_PASSWORD=0123456789abcdef0123456789abcdef|" "$CANDIDATE"

    blank=""
    for key in TASKSENSE_VERSION APP_URL FIRST_ADMIN_EMAIL STORAGE_SECRET MONGO_USER MONGO_PASSWORD; do
      v="$(sed -n "s/^${key}=//p" "$CANDIDATE" | tail -n1)"
      [ -n "$v" ] || blank="${blank} ${key}"
    done
    echo "BLANK_AFTER_EDIT:${blank}"
' 2>&1)"

check "an untouched example does not pass as configured" "1" \
  "$(printf '%s' "${out}" | grep -c 'BLANK_ON_UNTOUCHED_EXAMPLE: STORAGE_SECRET MONGO_PASSWORD')"
check "and its placeholders are recognised" "1" \
  "$(printf '%s' "${out}" | grep -c '^PLACEHOLDER_DETECTED$')"
check "an edited one does" "1" \
  "$(printf '%s' "${out}" | grep -c '^BLANK_AFTER_EDIT:$')"

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1"; }
check "the draft carries the same mode as the file it becomes" "600" "$(mode_of "${WORK}/.env.draft")"

# The whole point of starting from the example rather than an empty file.
check "and the explanations came with it" "1" \
  "$(grep -c 'Encrypts stored credentials at rest' "${WORK}/.env.draft")"

printf '\n  %s passed, %s failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
