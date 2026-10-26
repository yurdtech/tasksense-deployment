#!/usr/bin/env bash
#
# Builds the offline bundle for a Helm install in a network that cannot reach
# ghcr.io: the chart package, every image the chart references (the TaskSense
# image and the mongo image the backup Jobs use), the OpenShift overlay, the
# loader, a manifest with image digests, and SHA-256 checksums of all of it.
#
#   scripts/helm-airgap-bundle.sh [--version 1.1.0] [--platform linux/amd64] [-o dist]
#
#   --version <v>         TaskSense version to bundle (default: the chart's appVersion)
#   --chart-version <v>   chart version to stamp into the package (default: Chart.yaml)
#   --from-oci            pull the published chart (oci://ghcr.io/yurdtech/charts/tasksense)
#                         instead of packaging ./helm/tasksense
#   --mongo-image <ref>   backup image (default: backup.image in values.yaml, e.g. mongo:7)
#   --platform <p>        image platform (default linux/amd64 — what the cluster nodes run)
#   -o, --out <dir>       where the bundle goes (default ./dist)
#
# Run it on a machine with internet access that is signed in to the registry:
#   echo "$TOKEN" | docker login ghcr.io -u yurdtech --password-stdin
#   echo "$TOKEN" | helm registry login ghcr.io -u yurdtech --password-stdin   (--from-oci)
#
# Inside the network, scripts/helm-airgap-load.sh (shipped in the bundle) checks
# the checksums and pushes the images to your registry under the same paths the
# chart's global.imageRegistry expects. docs/02-INSTALL-KUBERNETES.md, "Air-gapped".

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${ROOT_DIR}/helm/tasksense"
OCI_CHART="oci://ghcr.io/yurdtech/charts/tasksense"
APP_IMAGE_REPO="ghcr.io/yurdtech/tasksense"

VERSION=""
CHART_VERSION=""
FROM_OCI=0
MONGO_IMAGE=""
PLATFORM="linux/amd64"
OUT_DIR="${ROOT_DIR}/dist"

die() { printf 'helm-airgap-bundle: %s\n' "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }
step() { printf '==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version)       VERSION="${2:?--version needs a value}"; shift 2 ;;
    --chart-version) CHART_VERSION="${2:?--chart-version needs a value}"; shift 2 ;;
    --from-oci)      FROM_OCI=1; shift ;;
    --mongo-image)   MONGO_IMAGE="${2:?--mongo-image needs a value}"; shift 2 ;;
    --platform)      PLATFORM="${2:?--platform needs a value}"; shift 2 ;;
    -o|--out)        OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
    -h|--help)       sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown argument: $1" "Run with --help." ;;
  esac
done

command -v helm >/dev/null 2>&1 || die "helm is required" "Install Helm 3.8+ (OCI support)."
command -v docker >/dev/null 2>&1 || die "docker is required" "It pulls and saves the images."
if command -v sha256sum >/dev/null 2>&1; then SHA=(sha256sum); else SHA=(shasum -a 256); fi

# ── versions ─────────────────────────────────────────────────────────────────

chart_field() { awk -v k="$1" '$1 == k":" { v = $2; gsub(/"/, "", v); print v; exit }' "${CHART_DIR}/Chart.yaml"; }

[ -n "${CHART_VERSION}" ] || CHART_VERSION="$(chart_field version)"
[ -n "${VERSION}" ] || VERSION="$(chart_field appVersion)"
if [ -z "${CHART_VERSION}" ] || [ -z "${VERSION}" ]; then
  die "could not read version/appVersion from ${CHART_DIR}/Chart.yaml"
fi

if [ -z "${MONGO_IMAGE}" ]; then
  # backup.image.{repository,tag} in values.yaml — the image the chart renders.
  MONGO_IMAGE="$(awk '
    /^backup:/ { b = 1; next }
    /^[^ #]/   { b = 0 }
    b && /^  image:/ { i = 1; next }
    b && i && /^  [^ ]/ { i = 0 }
    b && i && /^    repository:/ { r = $2 }
    b && i && /^    tag:/ { t = $2; gsub(/"/, "", t) }
    END { if (r != "" && t != "") print r ":" t }
  ' "${CHART_DIR}/values.yaml")"
  [ -n "${MONGO_IMAGE}" ] || die "could not read backup.image from ${CHART_DIR}/values.yaml" "Pass --mongo-image mongo:7."
fi

IMAGES=("${APP_IMAGE_REPO}:${VERSION}" "${MONGO_IMAGE}")

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
mkdir -p "${OUT_DIR}"

step "TaskSense ${VERSION}, chart ${CHART_VERSION}, platform ${PLATFORM}"

# ── chart ────────────────────────────────────────────────────────────────────

CHART_TGZ="tasksense-${CHART_VERSION}.tgz"
if [ "${FROM_OCI}" = "1" ]; then
  step "pull ${OCI_CHART} --version ${CHART_VERSION}"
  helm pull "${OCI_CHART}" --version "${CHART_VERSION}" -d "${STAGE}" >/dev/null \
    || die "helm pull failed" "Sign in first: helm registry login ghcr.io -u yurdtech --password-stdin"
else
  step "package ${CHART_DIR}"
  helm lint "${CHART_DIR}" -f "${CHART_DIR}/ci/default-values.yaml" >/dev/null \
    || die "the chart does not lint" "Run: helm lint ${CHART_DIR} -f ${CHART_DIR}/ci/default-values.yaml"
  helm package "${CHART_DIR}" --version "${CHART_VERSION}" --app-version "${VERSION}" -d "${STAGE}" >/dev/null
fi
[ -f "${STAGE}/${CHART_TGZ}" ] || die "expected ${CHART_TGZ} after packaging"

# The overlay must sit next to the chart: `-f values-openshift.yaml` needs a file.
cp "${CHART_DIR}/values-openshift.yaml" "${STAGE}/values-openshift.yaml"
cp "${ROOT_DIR}/scripts/helm-airgap-load.sh" "${STAGE}/helm-airgap-load.sh"
chmod 755 "${STAGE}/helm-airgap-load.sh"

# ── images ───────────────────────────────────────────────────────────────────

for image in "${IMAGES[@]}"; do
  step "pull ${image} (${PLATFORM})"
  docker pull --quiet --platform "${PLATFORM}" "${image}" >/dev/null \
    || die "docker pull ${image} failed" \
      "Signed in?  echo \"\$TOKEN\" | docker login ghcr.io -u yurdtech --password-stdin" \
      "No token yet? Ask info@yurdtech.az (docs/13-REGISTRY-ACCESS.md)."
done

step "save images.tar"
docker save -o "${STAGE}/images.tar" "${IMAGES[@]}"

# ── manifest + checksums ─────────────────────────────────────────────────────

{
  printf 'bundle: tasksense-helm-airgap\n'
  printf 'version: %s\n' "${VERSION}"
  printf 'chart: %s\n' "${CHART_TGZ}"
  printf 'chartVersion: %s\n' "${CHART_VERSION}"
  printf 'platform: %s\n' "${PLATFORM}"
  printf 'created: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'images:\n'
  for image in "${IMAGES[@]}"; do printf '  - %s\n' "${image}"; done
  # Registry digests, for comparing against the release notes / cosign out of band.
  printf 'digests:\n'
  for image in "${IMAGES[@]}"; do
    digest="$(docker image inspect --format '{{join .RepoDigests " "}}' "${image}" 2>/dev/null || true)"
    printf '  %s: "%s"\n' "${image}" "${digest}"
  done
} > "${STAGE}/manifest.yaml"

(cd "${STAGE}" && "${SHA[@]}" images.tar "${CHART_TGZ}" values-openshift.yaml helm-airgap-load.sh manifest.yaml > checksums.sha256)

BUNDLE="${OUT_DIR}/tasksense-helm-airgap-${VERSION}.tar.gz"
tar -czf "${BUNDLE}" -C "${STAGE}" .
(cd "${OUT_DIR}" && "${SHA[@]}" "$(basename "${BUNDLE}")" > "$(basename "${BUNDLE}").sha256")

step "${BUNDLE}"
cat <<EOF

  $(du -h "${BUNDLE}" | cut -f1)  ${BUNDLE}
  $(cut -d' ' -f1 "${BUNDLE}.sha256")  (sha256, also in ${BUNDLE}.sha256)

  Carry both files inside. There:

    sha256sum -c $(basename "${BUNDLE}").sha256
    mkdir tasksense-bundle && tar -xzf $(basename "${BUNDLE}") -C tasksense-bundle
    cd tasksense-bundle && ./helm-airgap-load.sh harbor.corp.internal

EOF
