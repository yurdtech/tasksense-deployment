#!/usr/bin/env bash
#
# Live connectivity checks, run before anything is installed.
#
#   scripts/wizard/probe.sh <candidate.env> [sample-username]
#
# Also sourceable, which is how the wizard uses it: probe_run leaves the names
# of the checks that failed in PROBE_FAILED, so the installer can offer to go
# back to exactly that section rather than making somebody repeat all nine.
#
# ── Why this runs inside the image ───────────────────────────────────────────
#
# The checks are the application's own code — `node dist/probe/cli.js`, which
# builds LdapService and the Mongo client from the same configuration parser the
# server uses. A checker written here in bash, with ldapsearch and openssl s_client,
# would be testing something adjacent to what the application does: its own idea
# of TLS verification, its own idea of how a filter is escaped. It could pass
# while the real thing fails, and a green check that lies is worse than no check
# — it moves the investigation to where the fault is not.
#
# The cost is that this step needs the image pulled first, which is why it comes
# after the pull rather than straight after the questions.

# shellcheck source=../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../ui.sh
. "${SCRIPT_DIR}/ui.sh"

PROBE_FAILED=()

probe_image() {
  local image version
  image="$(sed -n 's/^TASKSENSE_IMAGE=//p' "$1" | tail -n1)"
  version="$(sed -n 's/^TASKSENSE_VERSION=//p' "$1" | tail -n1)"
  printf '%s:%s' "${image:-ghcr.io/yurdtech/tasksense}" "${version:-latest}"
}

# The candidate .env holds site settings. The stack settings — the ones compose
# supplies rather than the operator — have to be added or the configuration
# parser rejects the file before any check can run.
probe_env_file() {
  local candidate="$1" out="$2" mongo_uri
  mongo_uri="$(sed -n 's/^MONGODB_URI=//p' "${candidate}" | tail -n1)"

  : > "${out}"
  chmod 600 "${out}"
  grep -v '^MONGODB_URI=' "${candidate}" >> "${out}"
  {
    printf 'DEPLOYMENT_MODE=onprem\n'
    printf 'NODE_ENV=production\n'
    printf 'PORT=3000\n'
    if [ -n "${mongo_uri}" ]; then
      printf 'MONGODB_URI=%s\n' "${mongo_uri}"
    else
      # The bundled database does not exist yet — the installer creates it. This
      # placeholder exists only to satisfy the environment contract, which
      # refuses the localhost default on-premise; the MongoDB check is skipped
      # in this case rather than run against it.
      printf 'MONGODB_URI=mongodb://placeholder:placeholder@mongo:27017/?authSource=admin\n'
    fi
  } >> "${out}"
}

# Older images have no probe. Installing an earlier version must still work, so
# this reports and skips rather than refusing.
probe_supported() {
  "${RUNTIME}" run --rm --entrypoint sh "$1" -c 'test -f dist/probe/cli.js' >/dev/null 2>&1
}

# One check, one container, one exit code. Running them separately rather than
# parsing `--json` keeps this free of a JSON parser in bash — and it is what
# lets a failure be attributed to the section that caused it.
probe_one() {
  local image="$1" envfile="$2" check="$3" sample="${4:-}" log
  log="$(mktemp)"

  local -a args=(run --rm --env-file "${envfile}")
  # LDAPS against an internal CA needs the CA visible inside the container, at
  # the path LDAP_TLS_CA names.
  [ -d "${COMPOSE_DIR}/certs" ] && args+=(-v "${COMPOSE_DIR}/certs:/certs:ro")
  args+=("${image}" node dist/probe/cli.js "${check}")
  [ -n "${sample}" ] && args+=(--user "${sample}")

  if "${RUNTIME}" "${args[@]}" >"${log}" 2>&1; then
    sed 's/^/  /' "${log}"
    rm -f "${log}"
    return 0
  fi
  sed 's/^/  /' "${log}"
  rm -f "${log}"
  return 1
}

# probe_run <candidate.env> [sample-username]
probe_run() {
  local candidate="$1" sample="${2:-}" image envfile
  PROBE_FAILED=()

  detect_runtime
  image="$(probe_image "${candidate}")"
  envfile="$(mktemp)"
  # The candidate holds the storage secret and the database password, so the
  # copy the container reads is no more readable than the original.
  probe_env_file "${candidate}" "${envfile}"

  if ! probe_supported "${image}"; then
    warn "this image has no connectivity checks (added in 1.1.0)"
    note "the installation will go ahead; a wrong directory setting will show up at first sign-in instead"
    rm -f "${envfile}"
    return 0
  fi

  local -a checks=()
  # Only what is configured. "Not configured" is not a fault, and asking the
  # probe about an unconfigured channel just prints a dash.
  grep -q '^LDAP_URL=' "${candidate}" && checks+=(ldap)
  grep -q '^OIDC_ISSUER=' "${candidate}" && checks+=(oidc)
  grep -q '^SMTP_HOST=' "${candidate}" && checks+=(smtp)
  grep -q '^MONGODB_URI=' "${candidate}" && checks+=(mongo)

  if [ "${#checks[@]}" -eq 0 ]; then
    note "nothing external to check — local passwords, in-app notifications, bundled database"
    rm -f "${envfile}"
    return 0
  fi

  local check
  for check in "${checks[@]}"; do
    if [ "${check}" = "ldap" ] && [ -z "${sample}" ]; then
      ui_text "The service account bind is checked on its own. Naming somebody who exists in the directory also tests LDAP_USER_FILTER and the group mapping — which is where the second class of mistake lives."
      ui_ask "A username to look up (optional)" "-" \
        "Any real account, for example the one you would sign in with. Nothing is written and no password is needed. Leave the dash to check the bind only."
      [ "${UI_VALUE}" != "-" ] && sample="${UI_VALUE}"
      printf '\n'
    fi

    if probe_one "${image}" "${envfile}" "${check}" "$([ "${check}" = "ldap" ] && printf '%s' "${sample}")"; then
      :
    else
      PROBE_FAILED+=("${check}")
    fi
  done

  rm -f "${envfile}"
  [ "${#PROBE_FAILED[@]}" -eq 0 ]
}

# Executed rather than sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ -n "${1:-}" ] || die "usage: probe.sh <candidate.env> [sample-username]"
  probe_run "$1" "${2:-}"
fi
