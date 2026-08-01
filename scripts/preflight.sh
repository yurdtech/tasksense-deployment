#!/usr/bin/env bash
#
# Checks a host before installing, so problems surface now rather than halfway
# through a maintenance window.
#
#   ./scripts/preflight.sh
#
# Exits non-zero if anything would block an install. Warnings are things worth
# knowing about that will not stop you.

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FAILURES=0
fail() { printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; FAILURES=$((FAILURES + 1)); }

step "Container runtime"
detect_runtime
ok "${RUNTIME} $("${RUNTIME}" --version | head -n1)"
if ! "${RUNTIME}" info >/dev/null 2>&1; then
  fail "${RUNTIME} is installed but not usable by $(whoami) — is the service running, and are you in the right group?"
else
  ok "$(printf '%s' "${COMPOSE[*]}") available"
fi

step "Resources"
if command -v nproc >/dev/null 2>&1; then CPUS="$(nproc)"; else CPUS="$(sysctl -n hw.ncpu 2>/dev/null || echo 0)"; fi
if [ "${CPUS}" -ge 2 ] 2>/dev/null; then ok "${CPUS} CPU cores"; else fail "${CPUS} CPU cores — 2 is the minimum"; fi

MEM_MB=0
if [ -r /proc/meminfo ]; then
  MEM_MB=$(($(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024))
elif command -v sysctl >/dev/null 2>&1; then
  MEM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
fi
if [ "${MEM_MB}" -ge 3500 ]; then ok "$((MEM_MB / 1024)) GB memory"
elif [ "${MEM_MB}" -eq 0 ]; then warn "could not determine memory"
else fail "$((MEM_MB / 1024)) GB memory — 4 GB is the minimum"; fi

DISK_GB=$(df -Pg / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
[ -z "${DISK_GB}" ] && DISK_GB=0
if [ "${DISK_GB}" -ge 20 ]; then ok "${DISK_GB} GB free on /"
else fail "${DISK_GB} GB free on / — 20 GB is the minimum, and the database grows"; fi

step "Network"
require_env_file 2>/dev/null || warn "no .env yet — skipping port and URL checks"
if [ -f "${ENV_FILE}" ]; then
  PORT="$(env_value HTTP_PORT)"; PORT="${PORT:-3000}"
  if command -v ss >/dev/null 2>&1; then LISTENERS="$(ss -ltn 2>/dev/null || true)"
  else LISTENERS="$(netstat -an 2>/dev/null | grep LISTEN || true)"; fi
  if printf '%s' "${LISTENERS}" | grep -qE "[:.]${PORT}\b"; then
    fail "port ${PORT} is already in use — change HTTP_PORT in .env or stop what is holding it"
  else
    ok "port ${PORT} is free"
  fi

  APP_URL="$(env_value APP_URL)"
  case "${APP_URL}" in
    https://*) ok "APP_URL uses https" ;;
    http://*)  warn "APP_URL uses plain http — sign-in cookies and passwords would cross the network unencrypted" ;;
    *)         fail "APP_URL must start with http:// or https:// (found: '${APP_URL:-empty}')" ;;
  esac

  LDAP_URL="$(env_value LDAP_URL)"
  case "${LDAP_URL}" in
    ldap://*) fail "LDAP_URL uses ldap:// — the bind password would be sent in clear text. Use ldaps://" ;;
    ldaps://*) ok "LDAP_URL uses ldaps" ;;
  esac
fi

step "Registry"
if [ "${1:-}" = "--offline" ]; then
  note "offline mode — skipping registry reachability"
elif curl -fsS --max-time 8 https://ghcr.io/v2/ >/dev/null 2>&1; then
  ok "ghcr.io reachable"
else
  warn "ghcr.io not reachable — install with --offline using a release archive, or mirror the image (scripts/load-images.sh)"
fi

step "Secrets"
if [ -f "${ENV_FILE}" ]; then
  PERMS="$(stat -c '%a' "${ENV_FILE}" 2>/dev/null || stat -f '%Lp' "${ENV_FILE}" 2>/dev/null || echo '?')"
  case "${PERMS}" in
    600|400) ok ".env permissions ${PERMS}" ;;
    ?)       warn "could not read .env permissions" ;;
    *)       warn ".env is mode ${PERMS} and holds database and directory passwords — chmod 600 ${ENV_FILE}" ;;
  esac
  SECRET="$(env_value STORAGE_SECRET)"
  if [ -z "${SECRET}" ]; then fail "STORAGE_SECRET is empty — generate one with: openssl rand -base64 32"
  elif [ "${#SECRET}" -lt 32 ]; then fail "STORAGE_SECRET is ${#SECRET} characters — 32 is the minimum"
  else ok "STORAGE_SECRET set (${#SECRET} characters)"; fi
  [ -n "$(env_value MONGO_PASSWORD)" ] || fail "MONGO_PASSWORD is empty — generate one with: openssl rand -base64 24"
fi

printf '\n'
if [ "${FAILURES}" -gt 0 ]; then
  die "${FAILURES} check(s) failed — fix them before installing"
fi
ok "preflight passed"
