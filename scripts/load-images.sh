#!/usr/bin/env bash
#
# Gets the container images — TaskSense and MongoDB, and the Redis and Caddy
# of the replicas profile — onto a host, or into your own registry, when this
# host cannot pull from ghcr.io.
#
#   ./scripts/load-images.sh --offline
#       Load ./images/*.tar from the offline bundle into this host's runtime.
#
#   ./scripts/load-images.sh --offline --registry harbor.corp.internal/tasksense
#       Load them, then push them into your registry — for an air-gapped site
#       with a Harbor, Nexus or Quay inside.
#
#   ./scripts/load-images.sh --registry harbor.corp.internal/tasksense [--version 1.1.0]
#       Copy them straight from ghcr.io and Docker Hub into your registry. Run it
#       from a machine that reaches both; it needs no compose/.env.
#
# Options:
#   --version V         the TaskSense version (default: compose/.env, else the
#                       version this bundle was released with)
#   --mongo-version M   the MongoDB tag (default: MONGO_VERSION in .env, else 7)
#   --dir DIR           where the image archives are (default ./images)
#   --update-env        also write TASKSENSE_IMAGE, MONGO_IMAGE, REDIS_IMAGE and
#                       CADDY_IMAGE into compose/.env
#
# The images land as <registry>/tasksense:<version>, <registry>/mongo:<tag>,
# <registry>/redis:<tag> and <registry>/caddy:<tag> — what TASKSENSE_IMAGE,
# MONGO_IMAGE, REDIS_IMAGE and CADDY_IMAGE=<registry>/<name> point at. The
# Redis and Caddy tags are REDIS_VERSION and CADDY_VERSION in .env, else the
# ones docker-compose.replicas.yml defaults to. See docs/13-REGISTRY-ACCESS.md.

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

OFFLINE=0
MIRROR=""
VERSION=""
MONGO_TAG=""
UPDATE_ENV=0
IMAGE_DIR="${ROOT_DIR}/images"
while [ $# -gt 0 ]; do
  case "$1" in
    --offline)       OFFLINE=1; shift ;;
    --registry)      MIRROR="${2:?--registry needs <host>/<path>}"; shift 2 ;;
    --version)       VERSION="${2:?--version needs a version}"; VERSION="${VERSION#v}"; shift 2 ;;
    --mongo-version) MONGO_TAG="${2:?--mongo-version needs a tag}"; shift 2 ;;
    --dir)           IMAGE_DIR="${2:?--dir needs a directory}"; shift 2 ;;
    --update-env)    UPDATE_ENV=1; shift ;;
    -h|--help)       sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown option: $1" "Run with --help." ;;
  esac
done
[ "${OFFLINE}" = "1" ] || [ -n "${MIRROR}" ] || die "choose --offline, --registry <host/path>, or both" "Run with --help."
MIRROR="${MIRROR%/}"
case "${MIRROR}" in */*|"") ;; *) die "--registry takes <host>/<path>, e.g. harbor.corp.internal/tasksense" ;; esac

detect_runtime

# The version: asked for, configured, or the one this bundle ships with — the
# release stamps it into .env.example, so a fresh bundle needs no .env at all.
[ -n "${VERSION}" ] || VERSION="$(env_value TASKSENSE_VERSION)"
[ -n "${VERSION}" ] || VERSION="$(env_value TASKSENSE_VERSION "${EXAMPLE_FILE}")"
[ -n "${MONGO_TAG}" ] || MONGO_TAG="$(env_value MONGO_VERSION)"
MONGO_TAG="${MONGO_TAG:-7}"
REDIS_TAG="$(env_value REDIS_VERSION)"; REDIS_TAG="${REDIS_TAG:-${REDIS_DEFAULT_TAG}}"
CADDY_TAG="$(env_value CADDY_VERSION)"; CADDY_TAG="${CADDY_TAG:-${CADDY_DEFAULT_TAG}}"

APP_SRC="${DEFAULT_IMAGE}:${VERSION}"
MONGO_SRC="docker.io/library/mongo:${MONGO_TAG}"
# Pulled only by the replicas profile, mirrored always: a mirror missing them is
# found out the day someone turns that profile on.
REDIS_SRC="docker.io/library/redis:${REDIS_TAG}"
CADDY_SRC="docker.io/library/caddy:${CADDY_TAG}"
MIRROR_PAIRS=(
  "${APP_SRC}|${MIRROR}/tasksense:${VERSION}"
  "${MONGO_SRC}|${MIRROR}/mongo:${MONGO_TAG}"
  "${REDIS_SRC}|${MIRROR}/redis:${REDIS_TAG}"
  "${CADDY_SRC}|${MIRROR}/caddy:${CADDY_TAG}"
)

push_pair() {  # push_pair <local-ref> <destination-ref>
  printf '  %s → %s\n' "$1" "$2"
  "${RUNTIME}" tag "$1" "$2" || die "could not tag $1"
  "${RUNTIME}" push "$2" >/dev/null || die "could not push $2" \
    "Sign in to the registry first:  ${RUNTIME} login ${MIRROR%%/*}"
}

# ── From the offline bundle ──────────────────────────────────────────────────
if [ "${OFFLINE}" = "1" ]; then
  step "Loading images from ${IMAGE_DIR}"
  [ -d "${IMAGE_DIR}" ] || die "no ${IMAGE_DIR} directory" \
    "This mode expects the offline bundle's layout:" \
    "  tar xzf tasksense-onprem-<version>.tar.gz" \
    "  cd tasksense-onprem-<version> && ./scripts/install.sh --offline"

  shopt -s nullglob
  ARCHIVES=("${IMAGE_DIR}"/*.tar "${IMAGE_DIR}"/*.tar.gz)
  shopt -u nullglob
  [ ${#ARCHIVES[@]} -gt 0 ] || die "no image archives in ${IMAGE_DIR}"

  # The bundle carries linux/amd64. Loading it on arm64 succeeds and then fails
  # at start with "exec format error", which reads as a broken image rather than
  # a wrong one. Say it here, where the fix is obvious.
  HOST_ARCH="$("${RUNTIME}" info --format '{{.Architecture}}' 2>/dev/null || uname -m)"
  case "${HOST_ARCH}" in
    x86_64 | amd64) : ;;
    *)
      BUNDLED="$(sed -n 's/^bundledArch=//p' "${ROOT_DIR}/VERSION" 2>/dev/null || true)"
      die "this host is ${HOST_ARCH}, and the offline bundle carries ${BUNDLED:-linux/amd64}" \
          "The images would load and then fail to start." \
          "" \
          "The registry serves both architectures. Either pull from it:" \
          "  docker login ghcr.io -u ${REGISTRY_ACCOUNT} && ./scripts/install.sh" \
          "" \
          "or mirror the right architecture into your own registry from a machine" \
          "that can reach ghcr.io:" \
          "  ./scripts/load-images.sh --registry <your-registry>/tasksense"
      ;;
  esac

  LOADED=()
  for archive in "${ARCHIVES[@]}"; do
    printf '  loading %s ... ' "$(basename "${archive}")"
    out="$("${RUNTIME}" load -i "${archive}" 2>&1)" || { printf 'failed\n'; die "failed to load ${archive}" "${out}"; }
    printf 'done\n'
    while IFS= read -r ref; do
      [ -n "${ref}" ] && LOADED+=("${ref}")
    done < <(printf '%s\n' "${out}" | sed -n 's/^Loaded image[^:]*: *//p')
  done
  ok "${#ARCHIVES[@]} image archive(s) loaded"
  [ "${#LOADED[@]}" -eq 0 ] || for ref in "${LOADED[@]}"; do note "${ref}"; done

  if [ -n "${MIRROR}" ]; then
    step "Pushing into ${MIRROR}"
    PUSHED=0
    [ "${#LOADED[@]}" -gt 0 ] || die "the archives named no image to push"
    for ref in "${LOADED[@]}"; do
      name="${ref##*/}"            # tasksense:1.1.0, mongo:7, redis:7-alpine, caddy:2.10-alpine
      case "${name%%:*}" in
        tasksense|mongo|redis|caddy) push_pair "${ref}" "${MIRROR}/${name}"; PUSHED=$((PUSHED + 1)) ;;
      esac
    done
    [ "${PUSHED}" -gt 0 ] || die "nothing to push — the archives named no tasksense, mongo, redis or caddy image"
    ok "${PUSHED} image(s) pushed"
  fi
else
  # ── Straight from the public registries into the mirror ──────────────────
  [ -n "${VERSION}" ] || die "which version? Pass --version, e.g. --version 1.1.0"
  step "Mirroring TaskSense ${VERSION}, MongoDB ${MONGO_TAG}, Redis ${REDIS_TAG} and Caddy ${CADDY_TAG} into ${MIRROR}"

  # skopeo copies registry to registry without a local daemon and keeps the
  # multi-architecture index; pull/tag/push would flatten it to whichever
  # architecture this machine happens to be.
  if command -v skopeo >/dev/null 2>&1; then
    for pair in "${MIRROR_PAIRS[@]}"; do
      src="${pair%%|*}"; dst="${pair##*|}"
      printf '  %s → %s\n' "${src}" "${dst}"
      skopeo copy --all "docker://${src}" "docker://${dst}" \
        || die "skopeo copy failed for ${src}" \
               "Signed in to both?  skopeo login ghcr.io -u ${REGISTRY_ACCOUNT}  and  skopeo login ${MIRROR%%/*}"
    done
  else
    warn "skopeo not found — falling back to pull/tag/push (this machine's architecture only)"
    ensure_registry_login ghcr.io
    for pair in "${MIRROR_PAIRS[@]}"; do
      src="${pair%%|*}"; dst="${pair##*|}"
      "${RUNTIME}" pull "${src}" >/dev/null || die "could not pull ${src}"
      push_pair "${src}" "${dst}"
    done
  fi
fi

if [ -n "${MIRROR}" ]; then
  if [ "${UPDATE_ENV}" = "1" ]; then
    require_env_file
    env_set "${ENV_FILE}" TASKSENSE_IMAGE "${MIRROR}/tasksense"
    env_set "${ENV_FILE}" MONGO_IMAGE "${MIRROR}/mongo"
    env_set "${ENV_FILE}" REDIS_IMAGE "${MIRROR}/redis"
    env_set "${ENV_FILE}" CADDY_IMAGE "${MIRROR}/caddy"
    [ "${MONGO_TAG}" != "7" ] && env_set "${ENV_FILE}" MONGO_VERSION "${MONGO_TAG}"
    ok "${ENV_FILE}: TASKSENSE_IMAGE=${MIRROR}/tasksense, MONGO_IMAGE=${MIRROR}/mongo, REDIS_IMAGE=${MIRROR}/redis, CADDY_IMAGE=${MIRROR}/caddy"
  else
    step "Mirrored"
    cat <<EOF

  Point the installation at your mirror — these lines, in compose/.env (the
  last two matter with the replicas profile only):

    TASKSENSE_IMAGE=${MIRROR}/tasksense
    MONGO_IMAGE=${MIRROR}/mongo
$([ "${MONGO_TAG}" != "7" ] && printf '    MONGO_VERSION=%s\n' "${MONGO_TAG}")
    REDIS_IMAGE=${MIRROR}/redis
    CADDY_IMAGE=${MIRROR}/caddy

  (or run this again with --update-env). Then:  ./scripts/install.sh
EOF
  fi
fi
