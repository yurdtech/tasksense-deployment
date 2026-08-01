#!/usr/bin/env bash
#
# Verifies a release archive before you trust it.
#
#   ./scripts/verify-signature.sh tasksense-onprem-1.0.0.tar.gz
#
# Run this on the machine that downloaded the archive, before carrying it into
# the secure network. It checks two independent things:
#
#   1. the SHA-256 checksum — that the file arrived intact
#   2. the cosign signature — that we produced it, and nobody altered it since
#
# Download SHA256SUMS, SHA256SUMS.sig and cosign.pub alongside the archive from
# the same release page.

set -euo pipefail

ARCHIVE="${1:-}"
[ -n "${ARCHIVE}" ] || { echo "usage: verify-signature.sh <archive.tar.gz>" >&2; exit 1; }
[ -f "${ARCHIVE}" ] || { echo "no such file: ${ARCHIVE}" >&2; exit 1; }

DIR="$(cd "$(dirname "${ARCHIVE}")" && pwd)"
NAME="$(basename "${ARCHIVE}")"
cd "${DIR}"

fail() { printf '\n\033[31mFAILED\033[0m  %s\n' "$1" >&2; shift; for l in "$@"; do printf '        %s\n' "$l" >&2; done; exit 1; }

# ── Checksum ─────────────────────────────────────────────────────────────────
echo "==> Checksum"
[ -f SHA256SUMS ] || fail "SHA256SUMS not found next to the archive" \
  "Download it from the same release page."

if command -v sha256sum >/dev/null 2>&1; then
  grep " ${NAME}\$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1 \
    || fail "checksum mismatch for ${NAME}" \
            "The file is corrupt or was modified in transit. Download it again."
else
  EXPECTED="$(awk -v n="${NAME}" '$2 == n || $2 == "*"n {print $1}' SHA256SUMS)"
  [ -n "${EXPECTED}" ] || fail "${NAME} is not listed in SHA256SUMS"
  ACTUAL="$(shasum -a 256 "${NAME}" | awk '{print $1}')"
  [ "${EXPECTED}" = "${ACTUAL}" ] || fail "checksum mismatch for ${NAME}" \
    "expected ${EXPECTED}" "actual   ${ACTUAL}"
fi
echo "  ✓ ${NAME} matches SHA256SUMS"

# ── Signature ────────────────────────────────────────────────────────────────
echo "==> Signature"
if ! command -v cosign >/dev/null 2>&1; then
  echo "  ! cosign is not installed — checksum verified, signature NOT verified" >&2
  echo "    A checksum proves the file is intact; only the signature proves it is ours." >&2
  echo "    Install: https://docs.sigstore.dev/cosign/installation/" >&2
  exit 0
fi
[ -f SHA256SUMS.sig ] || fail "SHA256SUMS.sig not found"
[ -f cosign.pub ] || fail "cosign.pub not found" \
  "Get the public key from the release page or from your TaskSense contact."

cosign verify-blob --key cosign.pub --signature SHA256SUMS.sig SHA256SUMS >/dev/null 2>&1 \
  || fail "signature verification failed" \
          "SHA256SUMS was not signed by the key in cosign.pub. Do not install this archive." \
          "Contact your TaskSense representative."
echo "  ✓ SHA256SUMS is signed by the TaskSense release key"

printf '\n\033[32mVERIFIED\033[0m  %s is intact and authentic\n\n' "${NAME}"
