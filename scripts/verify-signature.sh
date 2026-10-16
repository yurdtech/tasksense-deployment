#!/usr/bin/env bash
#
# Verifies a downloaded release file before you trust it.
#
#   ./scripts/verify-signature.sh tasksense-onprem-1.1.0.tar.gz
#   ./scripts/verify-signature.sh tasksense-deployment-1.1.0.tar.gz tasksense-1.1.0.tgz
#   ./scripts/verify-signature.sh <file> --key /path/to/cosign.pub
#   ./scripts/verify-signature.sh <file> --allow-unverified   checksum only — loudly
#
# A release publishes one SHA256SUMS, signed as SHA256SUMS.sig, that lists
# all of its files: the offline bundle (tasksense-onprem-<v>.tar.gz), the
# deployment files (tasksense-deployment-<v>.tar.gz) and the Helm chart
# (tasksense-<v>.tgz). You usually have only one of them; put SHA256SUMS and
# SHA256SUMS.sig beside it. Run this on the machine that downloaded the file,
# before carrying it into the secure network. In order:
#
#   1. the cosign signature on SHA256SUMS — that we produced the list and
#      nobody altered it. Without cosign this FAILS unless --allow-unverified.
#   2. the SHA-256 of each file you name against its line in that list — that
#      the file is the one we listed. Files you do not have are not checked; a
#      named file with no line in the list fails.
#
# The public key: --key, else cosign.pub beside the file, else the cosign.pub
# shipped in this repository. Its fingerprint is printed — compare it with the
# one YurdTech gave you through another channel (info@yurdtech.az): a key that
# arrived with the download proves only that the two arrived together.

set -euo pipefail

KEY=""
ALLOW_UNVERIFIED=0
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --key)              KEY="${2:?--key needs a path}"; shift 2 ;;
    --allow-unverified) ALLOW_UNVERIFIED=1; shift ;;
    -h|--help)          sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)                 echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
    *)                  FILES+=("$1"); shift ;;
  esac
done
[ "${#FILES[@]}" -gt 0 ] || { echo "usage: verify-signature.sh <file>… [--key cosign.pub] [--allow-unverified]" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else R=""; G=""; Y=""; B=""; N=""; fi
fail() { printf '\n%sFAILED%s  %s\n' "$R" "$N" "$1" >&2; shift; for l in "$@"; do printf '        %s\n' "$l" >&2; done; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# Every named file must exist, and sit beside the same SHA256SUMS.
DIR=""
for f in "${FILES[@]}"; do
  [ -f "${f}" ] || fail "no such file: ${f}"
  d="$(cd "$(dirname "${f}")" && pwd)"
  [ -z "${DIR}" ] || [ "${DIR}" = "${d}" ] || fail "the files are in different directories" "Put them, SHA256SUMS and SHA256SUMS.sig in one directory."
  DIR="${d}"
done
SUMS="${DIR}/SHA256SUMS"
SIG="${DIR}/SHA256SUMS.sig"
[ -f "${SUMS}" ] || fail "SHA256SUMS not found next to ${FILES[0]}" "Download it from the same release page."

# ── 1. Signature ─────────────────────────────────────────────────────────────
echo "==> Signature on SHA256SUMS"
SIGNED=0
if ! command -v cosign >/dev/null 2>&1; then
  if [ "${ALLOW_UNVERIFIED}" = "0" ]; then
    fail "cosign is not installed, so the signature cannot be checked" \
         "A checksum proves a file matches a list; only the signature proves the list is ours." \
         "Install cosign (https://docs.sigstore.dev/cosign/installation/) and run this again," \
         "or pass --allow-unverified to check the checksum alone — and record that you did."
  fi
  printf '  %s!%s cosign is not installed — the signature is NOT verified (--allow-unverified)\n' "$Y" "$N" >&2
else
  [ -f "${SIG}" ] || fail "SHA256SUMS.sig not found next to SHA256SUMS" "Download it from the same release page."
  if [ -z "${KEY}" ]; then
    if [ -f "${DIR}/cosign.pub" ]; then KEY="${DIR}/cosign.pub"
    elif [ -f "${REPO_ROOT}/cosign.pub" ]; then KEY="${REPO_ROOT}/cosign.pub"
    else fail "no public key: pass --key, or put cosign.pub beside the file" "Get it from the release page and compare its fingerprint with YurdTech."; fi
  fi
  [ -f "${KEY}" ] || fail "no such key: ${KEY}"

  # The fingerprint of the key itself (SHA-256 of its DER encoding), which
  # survives line-ending changes a PEM file can pick up in transit.
  if command -v openssl >/dev/null 2>&1 && FP="$(openssl pkey -pubin -in "${KEY}" -outform DER 2>/dev/null | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')" && [ -n "${FP}" ]; then
    printf '  key %s\n  fingerprint (SHA-256 of the DER public key): %s%s%s\n' "${KEY}" "$B" "${FP}" "$N"
  else
    printf '  key %s\n  fingerprint (SHA-256 of the key file): %s%s%s\n' "${KEY}" "$B" "$(sha256_of "${KEY}")" "$N"
  fi
  echo "  compare it with the fingerprint YurdTech gave you out-of-band"

  # Offline first: the key is what is being checked. A cosign that wants the
  # transparency log needs network the secure side does not have, so on a
  # refusal the same signature is checked against the same key without it.
  if cosign verify-blob --key "${KEY}" --signature "${SIG}" "${SUMS}" >/dev/null 2>&1 \
     || cosign verify-blob --key "${KEY}" --signature "${SIG}" --insecure-ignore-tlog=true "${SUMS}" >/dev/null 2>&1; then
    SIGNED=1
    printf '  %s✓%s SHA256SUMS is signed by that key\n' "$G" "$N"
  else
    fail "the signature does not verify — SHA256SUMS was not signed by the key in ${KEY}" \
         "Do not install anything from this download. Contact ${SUPPORT_EMAIL:-info@yurdtech.az}."
  fi
fi

# ── 2. Checksums of the files you have ───────────────────────────────────────
echo "==> Checksums"
for f in "${FILES[@]}"; do
  name="$(basename "${f}")"
  # `sha256sum` writes "<hash>  name" or "<hash> *name" (binary mode).
  EXPECTED="$(awk -v n="${name}" '$2 == n || $2 == "*" n {print $1}' "${SUMS}" | head -n1)"
  [ -n "${EXPECTED}" ] || fail "${name} is not listed in SHA256SUMS" \
    "This SHA256SUMS belongs to a different release, or the file was renamed."
  ACTUAL="$(sha256_of "${DIR}/${name}")"
  [ "${EXPECTED}" = "${ACTUAL}" ] || fail "checksum mismatch for ${name}" \
    "expected ${EXPECTED}" "actual   ${ACTUAL}" \
    "The file is corrupt or was modified. Download it again."
  printf '  %s✓%s %s matches SHA256SUMS\n' "$G" "$N" "${name}"
done

if [ "${SIGNED}" = "1" ]; then
  printf '\n%sVERIFIED%s  %s: intact and signed by the release key\n\n' "$G" "$N" "$(printf '%s ' "${FILES[@]##*/}")"
else
  printf '\n%sUNVERIFIED%s  checksums match, but the signature was NOT checked — the files are intact, not proven ours\n\n' "$Y" "$N" >&2
fi
