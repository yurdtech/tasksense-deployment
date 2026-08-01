# Security

Written for a security review. It describes what the software does, where the
boundaries are, and how to verify the claims rather than take them on trust.
Where something is *not* implemented, it says so.

- [What runs, and where it can reach](#what-runs-and-where-it-can-reach)
- [Verifying "no external calls"](#verifying-no-external-calls)
- [Authentication](#authentication)
- [Authorisation and tenancy](#authorisation-and-tenancy)
- [Data at rest and in transit](#data-at-rest-and-in-transit)
- [Outbound requests and SSRF](#outbound-requests-and-ssrf)
- [Audit and logging](#audit-and-logging)
- [Supply chain](#supply-chain)
- [Hardening checklist](#hardening-checklist)
- [Known limitations](#known-limitations)
- [Reporting a vulnerability](#reporting-a-vulnerability)

---

## What runs, and where it can reach

Two containers:

| Container | Listens on | Talks to |
| --- | --- | --- |
| `tasksense-app` | `127.0.0.1:3000` (your reverse proxy fronts it) | MongoDB; whatever you configure — directory, SMTP, object storage, model endpoint |
| `tasksense-mongo` | nothing published; internal network only | nothing |

The application serves both the API and the web UI from one port, so there is
one origin, no cross-origin requests, and no second web server to configure.

**Nothing here calls out to the vendor.** There is no telemetry, no licence
activation server, no update check, no crash reporting. The licence key is
verified with an Ed25519 signature locally.

The web bundle is built with the marketing site, the Google sign-in SDK and all
web-font requests removed, and it carries no source maps. That is enforced in CI
rather than by convention: the build fails if a third-party origin appears in the
output. You can check the same thing yourself:

```bash
docker run --rm --entrypoint sh ghcr.io/yurdtech/tasksense:<version> -c \
  'grep -ohrE "https://[a-zA-Z0-9._-]+" /app/web/dist | sort -u'
```

The only hosts that appear are placeholder strings in form fields
(`yourcompany.atlassian.net`, `you@company.com`).

---

## Verifying "no external calls"

Do not take the claim on faith. Run the installation with the internet removed
and watch the wire.

```bash
# 1. Install into a network namespace with no route out.
sudo ip netns add airgap
sudo ip netns exec airgap ./scripts/install.sh --offline

# 2. Capture everything that is not local traffic, and use the product.
#    Sign in, create tasks, upload a file, open reports, run a backup.
sudo tcpdump -i any -n 'not net 10.0.0.0/8 and not net 172.16.0.0/12 and not host 127.0.0.1'
```

Expected result: nothing, for as long as you care to watch.

A lighter check on a normal host — block egress and confirm the product still
works end to end:

```bash
sudo iptables -I OUTPUT -m owner --uid-owner 1001 ! -d 172.16.0.0/12 -j REJECT
```

---

## Authentication

### Methods

| Method | How the password is checked | Notes |
| --- | --- | --- |
| Active Directory / LDAP | The directory, by binding as the user | No password is stored locally |
| OIDC (Keycloak, AD FS, Azure AD, Okta) | The identity provider | Authorization-code flow |
| Local email and password | scrypt hash in the database | Keep at least one, as a lockout escape hatch |
| Personal access tokens | SHA-256 hash of the token | For integrations; scoped read or write, optional expiry |

SAML and SCIM are **not implemented**. If your identity provider only speaks
SAML, raise it before signing — OIDC covers Keycloak, AD FS 2016+, Azure AD and
Okta, but a SAML-only deployment is not supported today.

### Directory sign-in, in detail

1. Bind as the read-only service account from `LDAP_BIND_DN`.
2. Search for the user with your `LDAP_USER_FILTER`. The username is RFC-4515
   escaped first, so a value like `*)(objectClass=*` cannot rewrite the filter.
3. Bind **as the user** with the password they typed. This is the only thing
   that verifies it; the application never sees a stored hash and never writes
   one.
4. Read group membership and map it to a role.

Specific behaviours worth knowing:

- **An empty password is refused before the directory is contacted.** An LDAP
  bind with no password is an *unauthenticated* bind, which most directories
  answer with success — so without this check, a blank password box would be a
  valid login for any known username.
- **"No such user" and "wrong password" return the same message**, so accounts
  cannot be enumerated.
- **A filter matching two entries is refused** rather than binding as whichever
  came first.
- **`ldap://` is rejected** on an on-premise installation. Use `ldaps://` with
  `LDAP_TLS_CA` pointing at your issuing CA.
- **Group membership is re-read at every sign-in.** Removing someone from a
  directory group takes effect at their next login with no action in TaskSense.
  The corollary: local role edits to a directory-managed account do not persist.

### Sessions

- Bearer tokens, held in browser local storage. No cookies, so no CSRF surface.
- `SESSION_TTL_HOURS` bounds a session's lifetime. Sessions issued before the
  setting was configured are not retroactively expired — enabling it bounds new
  sign-ins rather than logging the whole company out at once.
- Twenty concurrent sessions per account; the oldest is evicted beyond that.
- Suspending a member invalidates their sessions and tokens immediately.
- Changing a password ends every session on that account.
- Sign-in endpoints are rate-limited to 10 attempts per minute per IP.

---

## Authorisation and tenancy

Deny by default: every route requires authentication unless explicitly marked
public (sign-in, health, the SPA itself). A second guard then checks the caller's
role against a per-workspace permission matrix.

Every database query is scoped to the caller's workspace in the repository
layer, not by each call site remembering to. Indexes lead with the tenant key so
the access path itself enforces the boundary.

On-premise runs a **single workspace**: everyone who signs in through your
directory joins the same one. Self-service tenant creation, which the hosted
product does, is off.

`POST /state/reset` — the endpoint that restores demo data — **does not exist**
in an on-premise build. The route is not registered, so it cannot be reached by
a misconfiguration or a stolen admin token.

---

## Data at rest and in transit

**In transit.** TLS is terminated by your reverse proxy; the container speaks
plain HTTP on loopback. HSTS, a strict Content-Security-Policy,
`X-Frame-Options: DENY` and `Referrer-Policy` are set by the application. Traffic
to MongoDB is on the container network — put it on TLS if your policy requires
encryption between processes on the same host (`docs/04-CONFIGURATION.md`).

**At rest.** Two layers, and they are different:

| Data | Protection |
| --- | --- |
| Stored credentials — object-storage keys, model API keys | AES-256-GCM, key derived from `STORAGE_SECRET` |
| Local passwords | scrypt, per-account salt |
| Personal access tokens | SHA-256; the token itself is never stored |
| **Everything else** — tasks, documents, comments, attachments | **Not encrypted by the application** |

That last row matters. Business content is stored as ordinary MongoDB documents
and ordinary files. If your policy requires encryption at rest, provide it
underneath: encrypted volumes (LUKS, dm-crypt), MongoDB Enterprise encrypted
storage, or an object-storage backend that encrypts. TaskSense does not
double-encrypt, and claiming otherwise would be false.

`STORAGE_SECRET` must be at least 32 characters, and the application refuses to
start on-premise without it. Without it, credentials would be encrypted with a
development key that is published in the source. Back it up alongside the
database: a restore without it recovers unreadable credentials.

---

## Outbound requests and SSRF

Some URLs are supplied by users rather than operators — the endpoint an admin
registers for outbound webhooks, the base URL an importer is pointed at, the
address of a custom model provider. Each one is a request the server makes from
inside your network, which is what makes them useful for probing it.

Every outbound request is checked first:

- The hostname is resolved and the **address** is judged, not the name. Checking
  the name is the classic mistake: `evil.example.com` is an ordinary hostname
  whose A record points at `127.0.0.1`.
- Private, loopback, link-local and carrier-grade-NAT ranges are refused —
  including `169.254.169.254`, the cloud metadata endpoint.
- A hostname resolving to *any* private address is refused, not just one where
  all addresses are private.
- Only `http` and `https`. No `file:`, no `gopher:`.
- `EGRESS_ALLOWLIST` re-opens named internal hosts, so reaching a self-hosted
  GitLab or Jira is a deliberate decision you record in configuration.

Residual risk: DNS is resolved by the check and again by the HTTP client, so a
record that changes between the two (DNS rebinding) is not fully closed. Closing
it requires pinning the connection to the resolved address. If this matters to
your threat model, enforce egress at the network layer as well.

---

## Audit and logging

**Audit trail.** Every change to a task, document, epic or attachment is recorded
with actor, entity, field, old value and new value, in a database collection an
administrator can read and export. Automation runs keep their own trail.

**Application logs.** With `LOG_FORMAT=json` (the on-premise default), one JSON
object per line on stdout, carrying timestamp, level, subsystem, message,
request id and workspace. Collect with your normal container log pipeline.

Log correlation: every request gets an id, returned as `X-Request-Id` and present
on every line it produced, so one user-reported failure can be traced without
guessing at timestamps.

**Never written to logs:** passwords, session tokens, API keys, personal access
tokens, request bodies of sign-in endpoints, or complete model prompts. Session
tokens that arrive in a query string (the live-update stream, which cannot send
headers) are redacted before the line is written. User email addresses appear
only in audit records, where they are the point.

`scripts/collect-diagnostics.sh` bundles logs and configuration for support with
every secret replaced by `<redacted>`. Review the archive before sending it —
logs contain user names and task titles.

---

## Supply chain

- Base image pinned by **digest**, not tag. A tag can be re-pointed at a
  different image; a digest cannot.
- Multi-stage build; the runtime image carries no compiler, no source and no
  development dependencies.
- Runs as **uid 1001, non-root**, with a read-only root filesystem, all Linux
  capabilities dropped and `no-new-privileges` set. On OpenShift it runs under
  an arbitrary uid in group 0 (`restricted-v2`).
- Every release is scanned with **Trivy** for CRITICAL and HIGH vulnerabilities
  that have a fix available. The result is published with the release, and the
  current image reports **zero**.

  The scan reports rather than blocks. New advisories land continuously against
  transitive dependencies, and a release that is otherwise ready is not held
  back by one published an hour earlier — the fix for that is a dependency
  bump, which ships as its own change. Findings are never silent: they appear
  in the build summary and raise a warning on the run.

  Two things keep the count at zero rather than merely visible: the runtime
  image contains no package manager (the bundled npm CLI carried its own
  vendored dependency tree, which was the source of most findings including the
  only CRITICAL), and the remainder are pinned above their advisories through
  dependency overrides.

  If you require a hard gate on your own copy, run `trivy image` against the
  digest before promoting it — the scan is reproducible and the SBOM below tells
  you exactly what is inside.

- An **SBOM** (CycloneDX) is published with each release.
- Images and release archives are **signed with cosign**. Verify before
  installing:

  ```bash
  cosign verify --key cosign.pub ghcr.io/yurdtech/tasksense:<version>
  ./scripts/verify-signature.sh tasksense-onprem-<version>.tar.gz
  ```

- The image is private in the registry. Access is a per-customer token you can
  have revoked at any time — see `13-REGISTRY-ACCESS.md`.

---

## Hardening checklist

Before going live:

- [ ] `STORAGE_SECRET` generated with `openssl rand -base64 32`, backed up separately
- [ ] `MONGO_PASSWORD` generated, not chosen
- [ ] `compose/.env` is mode `600` and owned by the service account
- [ ] TLS terminated at the reverse proxy, with a certificate your clients trust
- [ ] `BIND_ADDRESS=127.0.0.1` so only the proxy can reach the container
- [ ] `LDAP_URL` uses `ldaps://` and `LDAP_TLS_CA` points at your issuing CA
- [ ] At least one local administrator, so an identity-provider outage cannot lock you out
- [ ] `SESSION_TTL_HOURS` set to your policy
- [ ] `SWAGGER_ENABLED` left off
- [ ] `EGRESS_ALLOWLIST` empty, or listing only hosts you intend
- [ ] `LOG_FORMAT=json` and logs shipped to your SIEM
- [ ] Backups scheduled *and a restore rehearsed* (`docs/07-BACKUP-DR.md`)
- [ ] `METRICS_TOKEN` generated if metrics are enabled
- [ ] Image signature verified before first install

---

## Known limitations

Stated plainly, so they are not discovered during an audit:

1. **Business content is not encrypted at rest by the application.** Use
   encrypted storage underneath.
2. **No SAML, no SCIM.** OIDC and LDAP only. Deprovisioning is by directory
   group membership at next sign-in, not by a push from your IdP — a disabled
   directory account cannot sign in, but its existing session survives until it
   expires. Set `SESSION_TTL_HOURS` accordingly.
3. **DNS rebinding is not fully closed** in the SSRF guard (above).
4. **Rate limiting is per process.** With several replicas the effective limit
   is multiplied by the replica count.
5. **No IP allowlist inside the application.** Enforce at the proxy or firewall.
6. **Uploaded files are not virus-scanned.** Put a scanner in front, or restrict
   the permitted extensions in Admin → Storage.
7. **Multi-factor authentication is not implemented locally.** Get it from your
   identity provider by using OIDC or LDAP for sign-in.
8. **The web interface has no automated test suite.** API behaviour is covered;
   UI regressions are caught by review and manual testing.

---

## Reporting a vulnerability

Please report privately, not as a public issue: `security@yurdtech.az`.

Include the version (`curl https://<your-host>/api/v1/version`), what you
observed, and how to reproduce it. We acknowledge within two business days and
aim to ship a fix for a confirmed critical issue within five.
