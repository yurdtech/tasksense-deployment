#!/usr/bin/env bash
#
# The database password ends up inside a URI. Most of them did not survive it.
#
#   tests/mongo-uri.sh
#
# compose/docker-compose.yml builds the connection string by substitution:
#
#   MONGODB_URI: mongodb://${MONGO_USER}:${MONGO_PASSWORD}@mongo:27017/…
#
# and the wizard generated the password with `openssl rand -base64 24`. base64
# emits `+`, `/` and `=`; a URI reads `/` as structure, so the driver refused
# the whole string — "MongoParseError: Password contains unescaped characters" —
# before opening a socket. Two in three generated passwords contained one, so
# most installations died at first boot, and the message names neither the
# setting nor the fact that we chose the value.
#
# Nothing caught it because the wizard skips the MongoDB check when the bundled
# database is used: there is nothing running yet to connect to. That is still
# right, and it is why this asks a different question — not "does it connect?"
# but "would the driver even accept what we built?".

set -uo pipefail

# shellcheck source=helpers/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/common.sh"
DRAWS="${DRAWS:-100}"

docker_usable || skip "no container daemon"

printf '\nMongoDB connection string\n\n'

# ── 1. what the generator produces ───────────────────────────────────────────
# Through ui_secret itself, not a copy of it: the point is what the wizard
# generates, and a test that reimplemented the generator would pass while the
# wizard shipped something else.

# openssl is not in bash:5, and without it ui_generate_secret used to return an
# empty string — which every assertion below then passed, because an empty
# password makes a URI that parses. It refuses now, and the length check is here
# to catch the same shape of silence if it ever returns. The wizard's test
# image has openssl, so nothing is installed at run time.
wizard_test_image || skip "could not build ${WIZARD_TEST_IMAGE}"
PASSWORDS="$(docker run --rm -v "${ROOT}:/w:ro" -w /w -e DRAWS="${DRAWS}" "${WIZARD_TEST_IMAGE}" bash -c '
  . scripts/lib.sh
  . scripts/ui.sh
  # ui_generate_secret is the function ui_secret calls. Reimplementing it here
  # would test this file rather than the installer — and did: an earlier version
  # of this test passed against a branch where the fix had not applied at all.
  for _ in $(seq 1 "${DRAWS}"); do ui_generate_secret uri 24; printf "\n"; done
')"

unsafe="$(printf '%s\n' "${PASSWORDS}" | grep -c '[/:@?#][]%+=]' || true)"
check "none of ${DRAWS} generated passwords contain a URI-reserved character" "0" "${unsafe}"

count="$(printf '%s\n' "${PASSWORDS}" | grep -c '^[0-9a-f]\{48\}$' || true)"
check "all ${DRAWS} are 48 hex characters, and none is empty" "${DRAWS}" "${count}"

# The old generator, for contrast — so this test documents what it is defending
# against rather than merely asserting the present behaviour.
OLD="$(for _ in $(seq 1 "${DRAWS}"); do openssl rand -base64 24 | tr -d '\n'; printf '\n'; done)"
old_unsafe="$(printf '%s\n' "${OLD}" | grep -c '[/+=]' || true)"
if [ "${old_unsafe}" -gt 0 ]; then
  printf '  \033[32m✓\033[0m for contrast: %s of %s base64 passwords would have been rejected\n' "${old_unsafe}" "${DRAWS}"
  PASS=$((PASS + 1))
else
  printf '  \033[31m✗\033[0m base64 produced nothing unsafe in %s draws — suspicious\n' "${DRAWS}"
  FAIL=$((FAIL + 1))
fi

# ── 2. the driver's own verdict ──────────────────────────────────────────────

if ! IMAGE="$(app_test_image)"; then
  printf '\n  \033[33mSKIPPED\033[0m the driver check — ghcr.io/yurdtech/tasksense:%s is not here and GHCR_TOKEN is not set.\n' "$(example_version)"
  finish
  exit $?
fi

# Ask the same driver that rejected it, with the same URI compose builds.
VERDICT="$(printf '%s\n' "${PASSWORDS}" | head -20 | docker run --rm -i --entrypoint node "${IMAGE}" -e '
  const { MongoClient } = require("mongodb");
  let input = "";
  process.stdin.on("data", (d) => (input += d)).on("end", () => {
    let rejected = 0;
    for (const password of input.split("\n").filter(Boolean)) {
      const uri = `mongodb://tasksense:${password}@mongo:27017/?authSource=admin`;
      try { new MongoClient(uri); } catch { rejected += 1; }
    }
    console.log(rejected);
  });
')"
check "the driver accepts every URI built from them" "0" "${VERDICT}"

# And that it still rejects the shape that started this, so a green run here
# means the check works rather than that the check stopped looking.
VERDICT="$(printf 'aB3+xY/9zQ==\n' | docker run --rm -i --entrypoint node "${IMAGE}" -e '
  const { MongoClient } = require("mongodb");
  let input = "";
  process.stdin.on("data", (d) => (input += d)).on("end", () => {
    let rejected = 0;
    for (const password of input.split("\n").filter(Boolean)) {
      try { new MongoClient(`mongodb://tasksense:${password}@mongo:27017/?authSource=admin`); } catch { rejected += 1; }
    }
    console.log(rejected);
  });
')"
check "and still rejects the base64 password that caused this" "1" "${VERDICT}"

finish
