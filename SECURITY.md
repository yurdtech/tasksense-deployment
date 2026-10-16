# Security policy

## Reporting a vulnerability

Please report privately rather than opening a public issue:

**security@yurdtech.az**

Include:

- The version and commit — `curl https://<your-host>/api/v1/version`
- What you observed, and how to reproduce it
- The impact as you see it

We acknowledge within two business days. For a confirmed critical issue we aim
to ship a fix within five, and we will tell you if that is going to slip rather
than let the clock run. Security fixes are marked as such in the release notes.

If you would rather encrypt the report, ask for our PGP key first.

Everything that is not a vulnerability — support, licences, registry tokens —
goes to **info@yurdtech.az**.

## What is in scope

This repository holds deployment artifacts — the Compose stack, the Helm chart,
the scripts, the examples and the documentation. Issues in those belong here.

Issues in the **application** itself also go to the address above, not to a
public issue tracker, even though its source is not in this repository.

Out of scope: findings against a customer's own installation that stem from how
it was configured rather than from what we ship. If you are unsure which one you
have found, report it and we will work it out. The settings we recommend for a
regulated installation are in
[docs/06-SECURITY.md](docs/06-SECURITY.md#hardening-checklist).

## Supported versions

The current minor release and the one before it receive security fixes. These
deployment files require TaskSense **1.1.0** or later. Older versions need an
upgrade — see [docs/08-UPGRADE.md](docs/08-UPGRADE.md); skipping minor versions
is supported.

## What we publish with each release

| | Where |
| --- | --- |
| Signed image (cosign) | `ghcr.io/yurdtech/tasksense:<version>` — private, read-only token |
| Signed Helm chart (cosign) | `oci://ghcr.io/yurdtech/charts/tasksense` — private, same token |
| Offline bundle, its `SHA256SUMS` signed with cosign | `ghcr.io/yurdtech/tasksense-offline:<version>` — private, same token |
| SBOM (CycloneDX) — `sbom.cdx.json` | in the offline bundle; also an attestation on the image |
| Trivy scan of fixable CRITICAL and HIGH findings — `trivy-report.json` | in the offline bundle. It reports rather than blocks; re-scan in your registry and gate on it if your policy requires |
| Deployment files, chart, `SHA256SUMS`, `SHA256SUMS.sig`, `cosign.pub` | the public [Releases](https://github.com/yurdtech/tasksense-deployment/releases) page |

Verify before installing:

```bash
cosign verify --key cosign.pub ghcr.io/yurdtech/tasksense:<version>
cosign verify --key cosign.pub ghcr.io/yurdtech/charts/tasksense:<version>
./scripts/verify-signature.sh tasksense-onprem-<version>.tar.gz
```

`verify-signature.sh` checks the checksum and the signature and **fails closed**
when cosign is not installed. Compare the fingerprint of `cosign.pub` with the
one we give you through a second channel before the first install — a signature
only proves who holds the key. Details:
[docs/13-REGISTRY-ACCESS.md](docs/13-REGISTRY-ACCESS.md#verify-what-you-pulled).

## Disclosure

We will credit you when the fix ships, unless you prefer otherwise. We ask that
you give us the time above before publishing, and we will not ask you to stay
quiet indefinitely.
