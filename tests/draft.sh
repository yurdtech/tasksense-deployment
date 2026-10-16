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

# shellcheck source=helpers/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/common.sh"

printf '\nunfinished answers\n\n'

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
VOLUME_BRANCH="$(sed -n '/mongo_volume_exists; then/,/^fi$/p' "${ROOT}/scripts/wizard/install.sh")"
check "the volume question is still there to look at" "1" "$([ -n "${VOLUME_BRANCH}" ] && echo 1 || echo 0)"
check "no branch of the volume question calls die" "0" "$(printf '%s' "${VOLUME_BRANCH}" | grep -c 'die "stopped' || true)"
check "and it asks about the candidate, not a compose/.env that may not exist" "1" \
  "$(grep -c 'ENV_FILE="${CANDIDATE}" mongo_volume_exists' "${ROOT}/scripts/wizard/install.sh")"

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
# What edit_candidate does to a fresh draft — copy the example, keep it 600 —
# and the check it then makes, which is lib.sh's unfinished_keys and
# placeholder_keys: the same ones preflight uses, so the editor route cannot
# hand the installer a file preflight would refuse. Run on the host: lib.sh is
# bash 3.2 compatible.

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
CANDIDATE="${WORK}/.env.draft"
cp "${ROOT}/compose/.env.example" "${CANDIDATE}"
chmod 600 "${CANDIDATE}"

unfinished() { TASKSENSE_ENV_FILE="${CANDIDATE}" bash -c '. "$1/scripts/lib.sh"; unfinished_keys "$ENV_FILE" | tr "\n" " "' _ "${ROOT}"; }
placeholders() { TASKSENSE_ENV_FILE="${CANDIDATE}" bash -c '. "$1/scripts/lib.sh"; placeholder_keys "$ENV_FILE" | tr "\n" " "' _ "${ROOT}"; }

check "an untouched example does not pass as configured" "APP_URL FIRST_ADMIN_EMAIL STORAGE_SECRET MONGO_PASSWORD " "$(unfinished)"
check "and its placeholders are recognised" "APP_URL FIRST_ADMIN_EMAIL STORAGE_SECRET MONGO_PASSWORD " "$(placeholders)"

# Now fill it the way an operator would.
fixture_env "${CANDIDATE}"
check "an edited one does" "" "$(unfinished)"
check "with no placeholder left" "" "$(placeholders)"

# Your own MongoDB through the editor: the URI is what is required then.
fixture_env "${CANDIDATE}" "COMPOSE_PROFILES=" "MONGO_USER=" "MONGO_PASSWORD="
check "your own MongoDB without a URI is unfinished" "MONGODB_URI " "$(unfinished)"

check "the draft carries the same mode as the file it becomes" "600" "$(mode_of "${CANDIDATE}")"

# The whole point of starting from the example rather than an empty file.
check "and the explanations came with it" "1" \
  "$(grep -c 'Encrypts stored credentials' "${CANDIDATE}")"

finish
