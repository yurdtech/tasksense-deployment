#!/usr/bin/env bash
#
# A stand-in for curl, installed by tests/helpers/common.sh: the application's
# health and version endpoints answer, every other URL is "reachable".
#   FAKE_HEALTH_FAIL=1   health never answers
#   FAKE_SCHEMA          the schema state health reports (current)

url=""
for a in "$@"; do case "${a}" in http://*|https://*) url="${a}" ;; esac; done
case "${url}" in
  */api/v1/health*)
    [ "${FAKE_HEALTH_FAIL:-0}" = "1" ] && exit 7
    printf '{"status":"ok","schema":{"state":"%s"}}' "${FAKE_SCHEMA:-current}" ;;
  */api/v1/version*) printf '{"version":"fake"}' ;;
esac
exit 0
