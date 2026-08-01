# Security policy

## Reporting a vulnerability

Please report privately rather than opening a public issue:

**security@yurdtech.az**

Include:

- The version — `curl https://<your-host>/api/v1/version`
- What you observed, and how to reproduce it
- The impact as you see it

We acknowledge within two business days. For a confirmed critical issue we aim
to ship a fix within five, and we will tell you if that is going to slip rather
than let the clock run.

If you would rather encrypt the report, ask for our PGP key first.

## What is in scope

This repository holds deployment artifacts — the compose files, the Helm chart,
the installation scripts and the documentation. Issues in those belong here.

Issues in the **application** itself also go to the address above, not to a
public issue tracker, even though its source is not in this repository.

Out of scope: findings against a customer's own installation that stem from how
it was configured rather than from what we ship. If you are unsure which one you
have found, report it and we will work it out.

## Supported versions

The current minor release and the one before it receive security fixes. Older
versions need an upgrade — see [docs/08-UPGRADE.md](docs/08-UPGRADE.md).

## What we publish with each release

- An SBOM (CycloneDX)
- A Trivy scan for fixable CRITICAL and HIGH vulnerabilities, published with the
  release. It reports rather than blocks — see
  [docs/06-SECURITY.md](docs/06-SECURITY.md#supply-chain) for why, and for what
  keeps the count at zero. The scan is reproducible against the published
  digest if you want to gate on it yourself.
- A cosign signature over the image and over the offline archive's checksums

Verify before installing:

```bash
cosign verify --key cosign.pub ghcr.io/yurdtech/tasksense:<version>
./scripts/verify-signature.sh tasksense-onprem-<version>.tar.gz
```

## Disclosure

We will credit you when the fix ships, unless you prefer otherwise. We ask that
you give us the time above before publishing, and we will not ask you to stay
quiet indefinitely.
