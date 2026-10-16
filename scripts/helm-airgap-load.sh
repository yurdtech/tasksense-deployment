#!/usr/bin/env bash
#
# Loads the offline Helm bundle into your internal registry. Run it INSIDE the
# network, from the extracted bundle directory, signed in to that registry:
#
#   mkdir tasksense-bundle && tar -xzf tasksense-helm-airgap-<v>.tar.gz -C tasksense-bundle
#   cd tasksense-bundle
#   ./helm-airgap-load.sh harbor.bank.internal [--push-chart] [--dry-run]
#
#   <registry>     host[/project] the cluster pulls from — the value you then set
#                  as global.imageRegistry
#   --push-chart   also push the chart to oci://<registry>/charts (Harbor, Quay,
#                  Artifactory and Nexus all serve OCI charts)
#   --dry-run      verify and print the targets, push nothing
#
# Retag rule — the same one the chart applies with global.imageRegistry, so the
# two always agree:
#   ghcr.io/yurdtech/tasksense:1.1.0  ->  <registry>/yurdtech/tasksense:1.1.0   (source host replaced)
#   mongo:7                           ->  <registry>/library/mongo:7            (Docker Hub official image)
#
# Works with docker, podman, or skopeo alone (no daemon needed): whichever is
# installed, in that order. Exit 0 = everything pushed.

set -euo pipefail

REGISTRY=""
PUSH_CHART=0
DRY_RUN=0

die() { printf 'helm-airgap-load: %s\n' "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }
step() { printf '==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --push-chart) PUSH_CHART=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           die "unknown option: $1" "Run with --help." ;;
    *)            [ -z "${REGISTRY}" ] || die "one registry only (got ${REGISTRY} and $1)"; REGISTRY="$1"; shift ;;
  esac
done
[ -n "${REGISTRY}" ] || die "usage: helm-airgap-load.sh <registry> [--push-chart] [--dry-run]" \
  "e.g. ./helm-airgap-load.sh harbor.bank.internal"
REGISTRY="${REGISTRY%/}"
case "${REGISTRY}" in *://*) die "give the registry without a scheme (harbor.bank.internal, not https://…)" ;; esac

cd "$(dirname "${BASH_SOURCE[0]}")"
[ -f manifest.yaml ] && [ -f images.tar ] && [ -f checksums.sha256 ] \
  || die "run this from the extracted bundle directory (manifest.yaml, images.tar, checksums.sha256)"

# ── integrity first: nothing is loaded from a bundle that does not verify ─────

step "verify checksums"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c checksums.sha256 || die "checksum mismatch — the bundle is corrupt or was altered; do not use it"
else
  shasum -a 256 -c checksums.sha256 || die "checksum mismatch — the bundle is corrupt or was altered; do not use it"
fi

VERSION="$(awk '$1 == "version:" { print $2; exit }' manifest.yaml)"
CHART_TGZ="$(awk '$1 == "chart:" { print $2; exit }' manifest.yaml)"
CHART_VERSION="$(awk '$1 == "chartVersion:" { print $2; exit }' manifest.yaml)"
IMAGES=()
while IFS= read -r line; do IMAGES+=("${line}"); done < <(awk '/^images:/ { f = 1; next } /^[^ ]/ { f = 0 } f && /^  - / { print $2 }' manifest.yaml)
[ "${#IMAGES[@]}" -gt 0 ] || die "manifest.yaml lists no images"

# The chart's rule (tasksense.imageRef): a first path component containing a
# dot or a colon is a registry host and is replaced; a bare name is a Docker
# Hub official image and gains library/; user/name stays as it is.
target_for() {
  local image="$1" first rest
  case "${image}" in
    */*)
      first="${image%%/*}"; rest="${image#*/}"
      case "${first}" in
        *.*|*:*) printf '%s/%s' "${REGISTRY}" "${rest}" ;;
        *)       printf '%s/%s' "${REGISTRY}" "${image}" ;;
      esac
      ;;
    *) printf '%s/library/%s' "${REGISTRY}" "${image}" ;;
  esac
}

if command -v docker >/dev/null 2>&1; then TOOL=docker
elif command -v podman >/dev/null 2>&1; then TOOL=podman
elif command -v skopeo >/dev/null 2>&1; then TOOL=skopeo
else die "docker, podman or skopeo is required to push the images"
fi
step "using ${TOOL}"

if [ "${DRY_RUN}" = "0" ] && [ "${TOOL}" != "skopeo" ]; then
  step "load images.tar"
  "${TOOL}" load -i images.tar >/dev/null
fi

for image in "${IMAGES[@]}"; do
  target="$(target_for "${image}")"
  printf '  %s -> %s\n' "${image}" "${target}"
  [ "${DRY_RUN}" = "1" ] && continue
  if [ "${TOOL}" = "skopeo" ]; then
    skopeo copy --quiet "docker-archive:images.tar:${image}" "docker://${target}" \
      || die "push of ${target} failed" "Signed in?  skopeo login ${REGISTRY%%/*}"
  else
    source_ref="${image}"
    # podman stores short Docker Hub names fully qualified.
    if [ "${TOOL}" = "podman" ] && ! podman image exists "${source_ref}" 2>/dev/null; then
      source_ref="docker.io/$(case "${image}" in */*) printf '%s' "${image}" ;; *) printf 'library/%s' "${image}" ;; esac)"
    fi
    "${TOOL}" tag "${source_ref}" "${target}"
    "${TOOL}" push "${target}" >/dev/null \
      || die "push of ${target} failed" "Signed in?  ${TOOL} login ${REGISTRY%%/*}"
  fi
done

if [ "${PUSH_CHART}" = "1" ]; then
  command -v helm >/dev/null 2>&1 || die "--push-chart needs helm 3.8+"
  printf '  %s -> oci://%s/charts/tasksense:%s\n' "${CHART_TGZ}" "${REGISTRY}" "${CHART_VERSION}"
  if [ "${DRY_RUN}" = "0" ]; then
    helm push "${CHART_TGZ}" "oci://${REGISTRY}/charts" \
      || die "helm push failed" "Signed in?  helm registry login ${REGISTRY%%/*}"
  fi
fi

[ "${DRY_RUN}" = "1" ] && { step "dry run — nothing pushed"; exit 0; }

if [ "${PUSH_CHART}" = "1" ]; then
  CHART_REF="oci://${REGISTRY}/charts/tasksense --version ${CHART_VERSION}"
else
  CHART_REF="./${CHART_TGZ}"
fi

cat <<EOF

==> TaskSense ${VERSION} is in ${REGISTRY}. Install with (from this directory):

  kubectl create namespace tasksense
  kubectl create secret docker-registry tasksense-pull -n tasksense \\
    --docker-server=${REGISTRY%%/*} --docker-username=<robot account> --docker-password=<token>

  helm install tasksense ${CHART_REF} -n tasksense \\
    --set global.imageRegistry=${REGISTRY} \\
    --set 'imagePullSecrets[0].name=tasksense-pull' \\
    -f my-values.yaml --wait --timeout 30m

  OpenShift: add  -f values-openshift.yaml  BEFORE  -f my-values.yaml.
  Values, secrets and verification: docs/02-INSTALL-KUBERNETES.md (docs/03 for OpenShift).
EOF
