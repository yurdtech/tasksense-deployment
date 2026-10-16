#!/usr/bin/env bash
#
# A stand-in for the docker CLI, installed as `docker` by tests/helpers/common.sh.
#
# Every call is appended to $FAKE_LOG as its argv — the thing `ps` would show
# — so a test can assert both the order of operations and that no secret was
# ever passed as an argument. When the caller handed a connection string over
# in the environment (TS_MONGO_URI), that is recorded separately in
# $FAKE_LOG.env, so a test can tell "passed safely" from "not passed at all".
#
# Behaviour is steered by environment variables:
#   FAKE_COMPOSE_VERSION   what `compose version --short` reports (2.29.7)
#   FAKE_RUNNING           space-separated container names that are running —
#                          until a `stop` names them; `compose up` starts them again
#   FAKE_DUMP_FAIL=1       mongodump fails
#   FAKE_PENDING           what `migrate … status` reports pending (0)
#   FAKE_BAD_VERSION       TASKSENSE_VERSION whose `migrate` / `up` fail
#   FAKE_BAD_STAGE         migrate | up — where that version fails (up)
#   FAKE_IMAGE_RC          exit code of `image inspect` (0: present)
#   FAKE_VOLUME_RC         exit code of `volume inspect` (0: present)
#   FAKE_REAL_DOCKER       the real CLI; `compose config` is passed to it

set -u
printf '%s\n' "$*" >> "${FAKE_LOG:?FAKE_LOG is not set}"
[ -n "${TS_MONGO_URI:-}" ] && printf 'TS_MONGO_URI=%s\n' "${TS_MONGO_URI}" >> "${FAKE_LOG}.env"

STOPPED="${FAKE_LOG}.stopped"
fake_dump() {
  if [ "${FAKE_DUMP_FAIL:-0}" = "1" ]; then echo "Failed: (Unauthorized) command find requires authentication" >&2; exit 1; fi
  head -c 4096 /dev/urandom
}

# The TASKSENSE_VERSION of the file compose was pointed at.
version_in() { sed -n 's/^TASKSENSE_VERSION=//p' "$1" 2>/dev/null | tail -n1; }

compose_cmd() {
  local envf="" sub="" a
  local -a orig=("$@")
  while [ $# -gt 0 ]; do
    case "$1" in
      --env-file) envf="$2"; shift 2 ;;
      -f|-p|--project-directory|--profile) shift 2 ;;
      -*) shift ;;
      *) sub="$1"; shift; break ;;
    esac
  done
  local bad=0
  if [ -n "${FAKE_BAD_VERSION:-}" ] && [ -n "${envf}" ] && [ "$(version_in "${envf}")" = "${FAKE_BAD_VERSION}" ]; then bad=1; fi
  case "${sub}" in
    version)
      case " $* " in *" --short "*) printf '%s\n' "${FAKE_COMPOSE_VERSION:-2.29.7}" ;;
        *) printf 'Docker Compose version v%s\n' "${FAKE_COMPOSE_VERSION:-2.29.7}" ;; esac ;;
    config)
      if [ -n "${FAKE_REAL_DOCKER:-}" ]; then exec "${FAKE_REAL_DOCKER}" compose "${orig[@]}"; fi
      case " $* " in *" --services "*) printf 'migrate\napp\n' ;; esac ;;
    run)
      for a in "$@"; do
        if [ "${a}" = "status" ]; then printf '%s pending\n' "${FAKE_PENDING:-0}"; return 0; fi
      done
      [ "${bad}" = "1" ] && [ "${FAKE_BAD_STAGE:-up}" = "migrate" ] && { echo "migration 007 failed" >&2; return 1; }
      return 0 ;;
    up)
      [ "${bad}" = "1" ] && [ "${FAKE_BAD_STAGE:-up}" = "up" ] && { echo 'service "app" exited (1)' >&2; return 1; }
      : > "${STOPPED}"
      return 0 ;;
    exec)
      case "$*" in
        *mongodump*) fake_dump ;;
        *mongorestore*) cat > /dev/null ;;
      esac
      return 0 ;;
    *) return 0 ;;
  esac
}

case "${1:-}" in
  --version) echo "Docker version 27.3.1, build fake" ;;
  info)
    case "$*" in
      *Architecture*) echo x86_64 ;;
      *DockerRootDir*) echo / ;;
      *GraphRoot*) echo / ;;
    esac ;;
  compose) shift; compose_cmd "$@"; exit $? ;;
  volume) [ "${2:-}" = "inspect" ] && exit "${FAKE_VOLUME_RC:-0}" ;;
  image) [ "${2:-}" = "inspect" ] && exit "${FAKE_IMAGE_RC:-0}" ;;
  container)
    name="${!#}"
    case " ${FAKE_RUNNING:-} " in *" ${name} "*) state=true ;; *) state=false ;; esac
    grep -qx "${name}" "${STOPPED}" 2>/dev/null && state=false
    case "$*" in *State.Running*) echo "${state}" ;; esac ;;
  load)
    archive="${3:-}"
    case "$(basename "${archive}")" in
      *mongo*) echo "Loaded image: mongo:7" ;;
      *) echo "Loaded image: ghcr.io/yurdtech/tasksense:${FAKE_LOADED_VERSION:-1.1.0}" ;;
    esac ;;
  run)
    case "$*" in
      *mongodump*) fake_dump ;;
      *mongorestore*) cat > /dev/null ;;
      *"--entrypoint tar"*) head -c 2048 /dev/urandom ;;
      *"tar xzf"*) cat > /dev/null ;;
    esac ;;
  stop)
    shift
    for a in "$@"; do case "${a}" in -t|[0-9]*) ;; *) printf '%s\n' "${a}" >> "${STOPPED}" ;; esac; done ;;
  *) : ;;   # pull, tag, push, login, logout, rm, exec: succeed quietly
esac
exit 0
