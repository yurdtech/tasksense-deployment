#!/usr/bin/env bash
#
# Gets the container images onto a host that cannot pull from ghcr.io.
#
#   ./scripts/load-images.sh --offline
#       Load from ./images/*.tar (the layout inside a release archive).
#
#   ./scripts/load-images.sh --registry harbor.bank.internal/tasksense
#       Copy the images into your own registry, then point .env at it.
#       Run this from a machine that CAN reach both ghcr.io and the mirror.
#
# Three ways in, because networks differ: some sites have no route out at all,
# some run a mirror, some allow a proxy. See docs/13-REGISTRY-ACCESS.md.

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

MODE=""
MIRROR=""
IMAGE_DIR="${ROOT_DIR}/images"
while [ $# -gt 0 ]; do
  case "$1" in
    --offline)  MODE=offline; shift ;;
    --registry) MODE=registry; MIRROR="$2"; shift 2 ;;
    --dir)      IMAGE_DIR="$2"; shift 2 ;;
    -h|--help)  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "unknown option: $1" "Run with --help." ;;
  esac
done
[ -n "${MODE}" ] || die "choose a mode: --offline or --registry <host/path>" "Run with --help."

detect_runtime

if [ "${MODE}" = "offline" ]; then
  step "Loading images from ${IMAGE_DIR}"
  [ -d "${IMAGE_DIR}" ] || die "no ${IMAGE_DIR} directory" \
    "This mode expects the layout inside a release archive:" \
    "  tar xzf tasksense-onprem-<version>.tar.gz" \
    "  cd tasksense-onprem-<version> && ./scripts/install.sh --offline"

  shopt -s nullglob
  ARCHIVES=("${IMAGE_DIR}"/*.tar "${IMAGE_DIR}"/*.tar.gz)
  shopt -u nullglob
  [ ${#ARCHIVES[@]} -gt 0 ] || die "no image archives in ${IMAGE_DIR}"

  for archive in "${ARCHIVES[@]}"; do
    printf '  loading %s ... ' "$(basename "${archive}")"
    "${RUNTIME}" load -i "${archive}" >/dev/null || die "failed to load ${archive}"
    printf 'done\n'
  done
  ok "${#ARCHIVES[@]} image archive(s) loaded"
  "${RUNTIME}" images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | grep -iE 'tasksense|mongo' || true
  exit 0
fi

# ── Mirror into the customer's own registry ──────────────────────────────────
step "Mirroring into ${MIRROR}"
require_env_file
VERSION="$(env_value TASKSENSE_VERSION)"
MONGO_VERSION="$(env_value MONGO_VERSION)"; MONGO_VERSION="${MONGO_VERSION:-7}"

# skopeo copies between registries without a local daemon and preserves the
# multi-architecture index; falling back to pull/tag/push would flatten it to
# whichever architecture this machine happens to be.
if command -v skopeo >/dev/null 2>&1; then
  for pair in "ghcr.io/yurdtech/tasksense:${VERSION}|${MIRROR}/tasksense:${VERSION}" \
              "docker.io/library/mongo:${MONGO_VERSION}|${MIRROR}/mongo:${MONGO_VERSION}"; do
    src="${pair%%|*}"; dst="${pair##*|}"
    printf '  %s → %s\n' "${src}" "${dst}"
    skopeo copy --all "docker://${src}" "docker://${dst}" || die "skopeo copy failed for ${src}"
  done
else
  warn "skopeo not found — falling back to pull/tag/push (single architecture only)"
  for pair in "ghcr.io/yurdtech/tasksense:${VERSION}|${MIRROR}/tasksense:${VERSION}" \
              "mongo:${MONGO_VERSION}|${MIRROR}/mongo:${MONGO_VERSION}"; do
    src="${pair%%|*}"; dst="${pair##*|}"
    "${RUNTIME}" pull "${src}"
    "${RUNTIME}" tag "${src}" "${dst}"
    "${RUNTIME}" push "${dst}"
  done
fi

step "Mirrored"
cat <<EOF

  Point the installation at your mirror — in compose/.env:

    TASKSENSE_IMAGE=${MIRROR}/tasksense
    MONGO_IMAGE=${MIRROR}/mongo

  Then:  ./scripts/install.sh
EOF
