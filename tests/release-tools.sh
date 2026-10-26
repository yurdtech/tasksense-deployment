#!/usr/bin/env bash
#
# The two scripts a customer runs before anything is installed:
# verify-signature.sh on what they downloaded, and load-images.sh to get the
# images onto a host or into their own registry.
#
#   tests/release-tools.sh
#
# A release ships one SHA256SUMS (signed as SHA256SUMS.sig) listing three
# files, and a customer usually has only one of them. Fake cosign, skopeo and
# docker; offline; bash 3.2 or newer.

# shellcheck disable=SC2016  # the single-quoted snippets run in another shell

set -uo pipefail

# shellcheck source=helpers/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/common.sh"

printf '\nrelease tools\n\n'

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
sandbox "${WORK}"
V="$(example_version)"

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# cosign: "good" verifies; "offline-only" verifies only without the
# transparency log, as a key-signed blob does on a host that cannot reach it.
mkdir -p "${WORK}/cosign-bin"
cat > "${WORK}/cosign-bin/cosign" <<'EOF'
#!/usr/bin/env bash
printf 'cosign %s\n' "$*" >> "${FAKE_LOG}"
sig=""; prev=""; tlog=0
for a in "$@"; do
  [ "${prev}" = "--signature" ] && sig="${a}"
  [ "${a}" = "--insecure-ignore-tlog=true" ] && tlog=1
  prev="${a}"
done
case "$(cat "${sig}")" in
  good) exit 0 ;;
  offline-only) [ "${tlog}" = "1" ] && exit 0; echo "searching tlog: no route to rekor" >&2; exit 1 ;;
  *) echo "invalid signature" >&2; exit 1 ;;
esac
EOF
chmod +x "${WORK}/cosign-bin/cosign"

REL="${WORK}/release"
mkdir -p "${REL}"
printf 'deployment files' > "${REL}/tasksense-deployment-${V}.tar.gz"
{
  printf '%s  tasksense-onprem-%s.tar.gz\n' "0000000000000000000000000000000000000000000000000000000000000000" "${V}"
  printf '%s  tasksense-deployment-%s.tar.gz\n' "$(sha "${REL}/tasksense-deployment-${V}.tar.gz")" "${V}"
  printf '%s  tasksense-%s.tgz\n' "1111111111111111111111111111111111111111111111111111111111111111" "${V}"
} > "${REL}/SHA256SUMS"
printf 'good' > "${REL}/SHA256SUMS.sig"
if command -v openssl >/dev/null 2>&1 && openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl ec -pubout 2>/dev/null > "${REL}/cosign.pub" && [ -s "${REL}/cosign.pub" ]; then :
else printf -- '-----BEGIN PUBLIC KEY-----\nMFkw\n-----END PUBLIC KEY-----\n' > "${REL}/cosign.pub"; fi

verify() { PATH="${WORK}/cosign-bin:${PATH}" "${SANDBOX}/scripts/verify-signature.sh" "$@" 2>&1; }

# ── verify-signature.sh ──────────────────────────────────────────────────────
out="$(verify "${REL}/tasksense-deployment-${V}.tar.gz")"; rc=$?
check "one of the three files, beside SHA256SUMS: verified" "0" "${rc}"
contains "the files it does not have are not its problem" "VERIFIED" "${out}"
contains "the key's fingerprint is printed for an out-of-band comparison" "fingerprint (SHA-256 of the" "${out}"
before_sig="$(grep -n 'cosign verify-blob' "${FAKE_LOG}" | head -n1 | cut -d: -f1)"
check "the signature is checked" "yes" "$([ -n "${before_sig}" ] && echo yes || echo no)"

printf 'tampered' > "${REL}/tasksense-deployment-${V}.tar.gz"
out="$(verify "${REL}/tasksense-deployment-${V}.tar.gz")"; rc=$?
check "a changed file: fails" "1" "${rc}"
contains "with both hashes" "checksum mismatch for tasksense-deployment-${V}.tar.gz" "${out}"
printf 'deployment files' > "${REL}/tasksense-deployment-${V}.tar.gz"

printf 'x' > "${REL}/tasksense-renamed.tar.gz"
out="$(verify "${REL}/tasksense-renamed.tar.gz")"; rc=$?
check "a file the list does not name: fails" "1" "${rc}"
contains "saying so" "is not listed in SHA256SUMS" "${out}"

printf 'forged' > "${REL}/SHA256SUMS.sig"
out="$(verify "${REL}/tasksense-deployment-${V}.tar.gz")"; rc=$?
check "a signature by another key: fails" "1" "${rc}"
contains "and says not to install" "Do not install anything from this download" "${out}"

printf 'offline-only' > "${REL}/SHA256SUMS.sig"
out="$(verify "${REL}/tasksense-deployment-${V}.tar.gz")"; rc=$?
check "a key-signed list verifies without the transparency log, offline" "0" "${rc}"

rm -f "${REL}/SHA256SUMS.sig"
out="$(verify "${REL}/tasksense-deployment-${V}.tar.gz")"; rc=$?
check "no SHA256SUMS.sig: fails" "1" "${rc}"
printf 'good' > "${REL}/SHA256SUMS.sig"

mv "${REL}/cosign.pub" "${WORK}/elsewhere.pub"
out="$(verify "${REL}/tasksense-deployment-${V}.tar.gz")"; rc=$?
check "no key anywhere: fails" "1" "${rc}"
out="$(verify "${REL}/tasksense-deployment-${V}.tar.gz" --key "${WORK}/elsewhere.pub")"; rc=$?
check "--key names one" "0" "${rc}"
contains "and it is the one used" "elsewhere.pub" "${out}"
mv "${WORK}/elsewhere.pub" "${REL}/cosign.pub"

# No cosign at all: fail closed. PATH without the fake, and without any real
# cosign a developer may have installed in the usual places.
NOCOSIGN_PATH="$(printf '%s' "${PATH}" | tr ':' '\n' | grep -v -e '/usr/local/bin' -e '/opt/homebrew/bin' -e 'cosign-bin' | paste -sd: -)"
out="$(PATH="${NOCOSIGN_PATH}" "${SANDBOX}/scripts/verify-signature.sh" "${REL}/tasksense-deployment-${V}.tar.gz" 2>&1)"; rc=$?
if PATH="${NOCOSIGN_PATH}" command -v cosign >/dev/null 2>&1; then
  printf '  (a cosign is installed in a system directory — the fail-closed case cannot be checked here)\n'
else
  check "no cosign: fails closed" "1" "${rc}"
  contains "naming the override" "--allow-unverified" "${out}"
  out="$(PATH="${NOCOSIGN_PATH}" "${SANDBOX}/scripts/verify-signature.sh" "${REL}/tasksense-deployment-${V}.tar.gz" --allow-unverified 2>&1)"; rc=$?
  check "--allow-unverified: the checksum alone passes" "0" "${rc}"
  contains "and says loudly what was not done" "UNVERIFIED" "${out}"
  check "never claiming it was" "0" "$(printf '%s\n' "${out}" | grep -c '^VERIFIED' || true)"
fi

# ── load-images.sh ───────────────────────────────────────────────────────────
mkdir -p "${WORK}/skopeo-bin"
printf '#!/usr/bin/env bash\nprintf "skopeo %%s\\n" "$*" >> "${FAKE_LOG}"\n' > "${WORK}/skopeo-bin/skopeo"
chmod +x "${WORK}/skopeo-bin/skopeo"

: > "${FAKE_LOG}"
out="$(PATH="${WORK}/skopeo-bin:${PATH}" "${SANDBOX}/scripts/load-images.sh" --registry harbor.acme.internal/tasksense 2>&1)"; rc=$?
check "mirroring works with no compose/.env at all" "0" "${rc}"
contains "the application, at the version the bundle ships" \
  "skopeo copy --all docker://ghcr.io/yurdtech/tasksense:${V} docker://harbor.acme.internal/tasksense/tasksense:${V}" "$(docker_calls)"
contains "and MongoDB, which an air-gapped host needs just as much" \
  "skopeo copy --all docker://docker.io/library/mongo:7 docker://harbor.acme.internal/tasksense/mongo:7" "$(docker_calls)"
contains "and both .env lines are named" "MONGO_IMAGE=harbor.acme.internal/tasksense/mongo" "${out}"

: > "${FAKE_LOG}"
PATH="${WORK}/skopeo-bin:${PATH}" "${SANDBOX}/scripts/load-images.sh" --registry harbor.acme.internal/tasksense/ --version 1.4.2 --mongo-version 7.0.14 >/dev/null 2>&1
contains "--version and --mongo-version choose the tags" \
  "skopeo copy --all docker://ghcr.io/yurdtech/tasksense:1.4.2 docker://harbor.acme.internal/tasksense/tasksense:1.4.2" "$(docker_calls)"
contains "a trailing slash on the registry is harmless" "docker://harbor.acme.internal/tasksense/mongo:7.0.14" "$(docker_calls)"

# A PATH with no skopeo anywhere. Dropping the fake is not enough: GitHub's
# Ubuntu runners ship a real one in /usr/bin, which then tried a real copy and
# failed — and /usr/bin itself cannot leave PATH. So: one directory linking
# every command on PATH (first one wins, as in a lookup) except skopeo.
NOSKOPEO_BIN="${WORK}/noskopeo-bin"
mkdir -p "${NOSKOPEO_BIN}"
IFS=: read -r -a path_dirs <<< "${PATH}"
for dir in "${path_dirs[@]}"; do
  [ -d "${dir}" ] || continue
  for cmd in "${dir}"/*; do
    name="${cmd##*/}"
    [ "${name}" = skopeo ] || [ -e "${NOSKOPEO_BIN}/${name}" ] || [ ! -x "${cmd}" ] || ln -s "${cmd}" "${NOSKOPEO_BIN}/${name}"
  done
done

: > "${FAKE_LOG}"
out="$(PATH="${NOSKOPEO_BIN}" "${SANDBOX}/scripts/load-images.sh" --registry harbor.acme.internal/tasksense --version 1.4.2 2>&1)"; rc=$?
check "without skopeo: pull, tag and push instead" "0" "${rc}"
contains "pushing the application" "push harbor.acme.internal/tasksense/tasksense:1.4.2" "$(docker_calls)"
contains "and MongoDB" "push harbor.acme.internal/tasksense/mongo:7" "$(docker_calls)"

mkdir -p "${SANDBOX}/images"
printf 'x' > "${SANDBOX}/images/tasksense-${V}.tar"; printf 'x' > "${SANDBOX}/images/mongo-7.tar"
: > "${FAKE_LOG}"
out="$(FAKE_LOADED_VERSION="${V}" "${SANDBOX}/scripts/load-images.sh" --offline 2>&1)"; rc=$?
check "--offline loads every archive in images/" "2" "$(grep -c '^load -i' "${FAKE_LOG}")"
lacks "and pushes nothing" "push" "$(docker_calls)"

: > "${FAKE_LOG}"
out="$(FAKE_LOADED_VERSION="${V}" "${SANDBOX}/scripts/load-images.sh" --offline --registry harbor.acme.internal/tasksense 2>&1)"; rc=$?
check "--offline --registry: loads, then fills the registry inside" "0" "${rc}"
contains "with the application" "push harbor.acme.internal/tasksense/tasksense:${V}" "$(docker_calls)"
contains "and MongoDB" "push harbor.acme.internal/tasksense/mongo:7" "$(docker_calls)"

fixture_env "${SANDBOX}/compose/.env"
PATH="${WORK}/skopeo-bin:${PATH}" "${SANDBOX}/scripts/load-images.sh" --registry harbor.acme.internal/tasksense --update-env >/dev/null 2>&1
check "--update-env points BOTH images at the mirror" \
  "harbor.acme.internal/tasksense/tasksense harbor.acme.internal/tasksense/mongo" \
  "$(sed -n 's/^TASKSENSE_IMAGE=//p' "${SANDBOX}/compose/.env") $(sed -n 's/^MONGO_IMAGE=//p' "${SANDBOX}/compose/.env")"
check "where the example documents them, not appended" "1" "$(grep -c '^TASKSENSE_IMAGE=' "${SANDBOX}/compose/.env")"

out="$("${SANDBOX}/scripts/load-images.sh" --registry harbor 2>&1)"; rc=$?
check "a registry without a path is refused" "1" "${rc}"

finish
