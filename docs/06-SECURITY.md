# Security

Written for a security review. It describes what the software does, where the
boundaries are, and how to verify the claims rather than take them on trust.
Where something is *not* implemented, it says so.

Applies to **TaskSense 1.1.0** and these deployment files.

- [What runs, and where it can reach](#what-runs-and-where-it-can-reach)
- [Verifying "no external calls"](#verifying-no-external-calls)
- [Authentication](#authentication)
- [Sessions and URL tickets](#sessions-and-url-tickets)
- [Authorisation and tenancy](#authorisation-and-tenancy)
- [Data at rest and in transit](#data-at-rest-and-in-transit)
- [Outbound requests and SSRF](#outbound-requests-and-ssrf)
- [AI features and the agent executor](#ai-features-and-the-agent-executor)
- [API documentation endpoints](#api-documentation-endpoints)
- [Audit and logging](#audit-and-logging)
- [Containers and supply chain](#containers-and-supply-chain)
- [Hardening checklist](#hardening-checklist)
- [Known limitations](#known-limitations)
- [Reporting a vulnerability](#reporting-a-vulnerability)

---

## What runs, and where it can reach

| Process | Image / command | Listens on | Talks to |
| --- | --- | --- | --- |
| **API** (`app`) | `ghcr.io/yurdtech/tasksense`, `node dist/main.js` | port 3000; Compose publishes it on `127.0.0.1:3000` for your reverse proxy | MongoDB; whatever you configure — directory, IdP, SMTP, object storage, model gateway, webhook targets |
| **migrate** (one-shot) | same image, `node dist/database/migrations/cli.js up` | nothing | MongoDB; exits after the schema is current |
| **Import worker** (optional) | same image, `node dist/worker.js` | **nothing** — no HTTP listener | MongoDB; the shared upload staging directory |
| **MongoDB** (Compose, optional) | `mongo:7`, `--auth` | nothing published; internal Compose network only | nothing |

The API serves both the REST API and the web interface from one port: one
origin, no cross-origin requests, no second web server.

**Nothing calls out to the vendor.** There is no telemetry, no licence
activation server, no update check and no crash reporting. The licence is an
Ed25519-signed token verified locally against a public key compiled into the
image.

The web bundle is built without the marketing site, the Google sign-in SDK or
any web-font request, and with no source maps. CI enforces it: the build fails
if a third-party origin appears in the output. Check it yourself:

```bash
docker run --rm --entrypoint sh ghcr.io/yurdtech/tasksense:1.1.0 -c \
  'grep -ohrE "https://[a-zA-Z0-9._-]+" /app/web/dist | sort -u'
```

Expected: only placeholder strings from form fields
(`yourcompany.atlassian.net`, `you@company.com`).

Network rules for the whole installation, in and out:
[18-PRE-INSTALL-CHECKLIST](18-PRE-INSTALL-CHECKLIST.md#2-firewall-matrix).

---

## Verifying "no external calls"

Do not take the claim on faith. Run the installation with the internet removed
and watch the wire.

```bash
# 1. Install from the offline bundle onto a host with no route out
#    (docs/13-REGISTRY-ACCESS.md#no-route-out-air-gapped).
# 2. Capture everything that is not local traffic, and use the product:
#    sign in, create tasks, upload a file, open reports, run a backup.
sudo tcpdump -i any -n 'not net 10.0.0.0/8 and not net 172.16.0.0/12 and not net 192.168.0.0/16 and not host 127.0.0.1'
```

Expected: nothing, for as long as you care to watch.

A lighter check on a normal host — block the application user's egress except
to private ranges and confirm the product still works end to end:

```bash
sudo iptables -I OUTPUT -m owner --uid-owner 1001 ! -d 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 -j REJECT
```

Our nightly CI runs the image on an internal-only Docker network and checks the
same thing.

---

## Authentication

| Method | How the password is checked | Notes |
| --- | --- | --- |
| Active Directory / LDAP | The directory, by binding **as the user** | No password stored locally. LDAPS only |
| OIDC (Keycloak, AD FS, Entra ID, Okta) | The identity provider | Authorization-code flow; MFA comes from the IdP |
| Local e-mail and password | scrypt hash in the database | Self-registration closed on-premise; keep one as a break-glass account |
| Personal access tokens | SHA-256 hash of the token | For scripts and integrations; scoped read / write / admin, optional expiry |

SAML and SCIM are **not implemented** ([known limitations](#known-limitations)).

### Directory sign-in, in detail

Directory settings live in the application (Admin → Authentication), not in
`.env`. Bind passwords are stored AES-256-GCM encrypted, keyed off
`STORAGE_SECRET`, and never returned by any endpoint. At sign-in:

1. Bind as the read-only service account.
2. Search for the user with the configured filter. The username is RFC 4515
   escaped first, so `*)(objectClass=*` cannot rewrite the filter.
3. Bind **as the user** with the password they typed — the only thing that
   verifies it. The application never stores or sees a password hash for a
   directory account.
4. Read group membership and map it to a role.

Behaviours worth knowing:

- **An empty password is refused before the directory is contacted.** An LDAP
  bind without a password is an *unauthenticated* bind, which most directories
  answer with success.
- **"No such user" and "wrong password" return the same message** — no
  account enumeration.
- **A filter matching two entries is refused** rather than binding as the
  first.
- **`ldap://` is rejected** on-premise unless the directory's lab-only
  "allow an insecure connection" switch is set.
- **Several independent directories** are tried in order; one domain's outage
  does not lock out the others.
- **Enabling a directory requires a passed connection test**, and a
  configuration that would disable every sign-in method is refused.
- **Group membership is re-read at every sign-in.** Removing someone from a
  directory group takes effect at their next sign-in; a disabled directory
  account cannot sign in again. An existing session lives until it expires —
  hence a short `SESSION_TTL_HOURS`.

### Brute force

- Sign-in routes are rate-limited to **10 requests a minute per client
  address** (the proxy's `X-Forwarded-For`, one hop trusted).
- Independently, **10 failed sign-ins for one identifier within 15 minutes**
  lock that identifier for the rest of the window (HTTP 429) — counted whether
  or not the account exists, so the lock does not reveal which accounts do. A
  successful sign-in clears it.
- Both counters are in the API's memory (`RATE_LIMIT_STORE=memory`, the single
  process by design); a restart resets them. Directory accounts are also
  subject to your AD lockout policy.

---

## Sessions and URL tickets

- **Opaque bearer tokens**, held in the browser's local storage. Not JWTs,
  no cookies — so no CSRF surface. Only the SHA-256 hash is stored server-side,
  so revocation is immediate.
- **Lifetime: `SESSION_TTL_HOURS`**, default 720 hours (30 days) in 1.1.0 —
  before 1.1.0 the default was never. **Set 12 for production.** A workspace policy
  in Admin → Security overrides it. Sessions issued before a lifetime applied
  carry no expiry — so an upgrade does not sign the company out at once — and
  are ended with Admin → Security → sign everyone out. There is no idle
  timeout and no refresh token.
- Twenty concurrent sessions per account; the oldest is evicted beyond that.
- Suspending a member invalidates their sessions and tokens immediately;
  changing a password ends every session on that account.

**URL tickets.** `EventSource` (the two live-update streams) and `<video src>`
cannot send an `Authorization` header, so those routes authenticate from the
query string. The query string never carries the session: the browser mints a
**ticket** — 32 random bytes — from its header-authenticated session, scoped to
one use:

| Scope | Routes | Lifetime |
| --- | --- | --- |
| `stream` | `/api/v1/state/stream`, `/api/v1/agents/events/stream` | 60 seconds (one connect; a reconnect mints a new one) |
| `media` | attachment playback | 1 hour |

Tickets are held in the API's memory, by hash; they cannot mint further
tickets, and signing out, suspension or a password change kills every ticket
the session minted. What reaches a proxy log or a `Referer` is therefore a
value that expires within the hour and opens only those routes — and the
example proxy configurations do not log query strings at all.

---

## Authorisation and tenancy

Deny by default: every route requires authentication unless explicitly marked
public (sign-in, health, version, the web interface, and the token-addressed
integration endpoints below). A second guard checks the caller's role against
the per-workspace permission matrix (5 roles, 26 permissions, editable in
Admin → Roles & permissions), plus project overrides, issue security levels and
the token's scope ceiling — a personal access token can never do more than its
owner.

Every database query is scoped to the caller's workspace in the repository
layer, not by each call site remembering to. On-premise runs a **single
workspace**: everyone who signs in joins it; self-service tenant creation is
off.

`POST /state/reset` — the demo-data reset — **does not exist** in an
on-premise build: the route is not registered.

**Token-addressed public endpoints**, by design without a session because your
systems call them: inbound mail (`/api/v1/inbound-mail/<token>`), automation
web hooks (`/api/v1/automation/hooks/<token>`), GitLab / GitHub webhooks
(`/api/v1/integrations/{gitlab,github}/webhook/<id>`, verified by token or
HMAC-SHA256), invite links. If you do not use them, block those paths at the
proxy; if you do, allow them only from the mail relay / GitLab segment.

---

## Data at rest and in transit

**In transit.**

| Hop | Protection |
| --- | --- |
| Browser / API client → reverse proxy | Your TLS certificate. The application sends HSTS (2 years, `includeSubDomains`), a strict Content-Security-Policy, `X-Frame-Options: DENY`, `Referrer-Policy` |
| Proxy → application | Plain HTTP on loopback (Compose) or the cluster network |
| Application → directory | LDAPS, certificate verified against the CA pasted per directory |
| Application → MongoDB | TLS when the URI says `tls=true`, verified against `tlsCAFile=/certs/…`. The bundled container is on the internal Compose network without TLS |
| Application → SMTP, IdP, object storage, model gateway | TLS, verified against the public roots plus `NODE_EXTRA_CA_CERTS=/certs/<corp-ca>.pem` |

**At rest.** Two layers, and they are different:

| Data | Protection |
| --- | --- |
| Stored credentials — LDAP bind passwords, SMTP, object-storage keys, model-provider keys, VCS webhook secrets | AES-256-GCM; one key per purpose, derived with scrypt from `STORAGE_SECRET` |
| Local passwords | scrypt, per-account salt |
| Session tokens, personal access tokens | SHA-256; the token itself is never stored |
| **Everything else** — tasks, documents, comments, attachments, audit history | **Not encrypted by the application** |

That last row matters. Business content is stored as ordinary MongoDB documents
and ordinary files. If your policy requires encryption at rest, provide it
underneath: encrypted volumes (LUKS / dm-crypt, encrypted storage classes),
MongoDB Enterprise encrypted storage, or an object store that encrypts.

`STORAGE_SECRET` must be at least 32 characters; on-premise the application
refuses to start without it (it would otherwise fall back to a development key
published in the source). There is no re-encryption tool: rotating it means
re-entering the stored credentials. Back it up separately from the backups that
contain it.

---

## Outbound requests and SSRF

Some URLs are supplied by users rather than operators — webhook targets, an
importer's base URL, a model provider's address. Each is a request the server
makes from inside your network. Every such request is checked first:

- The host name is resolved and the **address** is judged, not the name
  (`evil.example.com` can have an A record of `127.0.0.1`).
- Private, loopback, link-local and carrier-grade-NAT ranges are refused —
  including `169.254.169.254`, the cloud metadata endpoint — and so is a host
  name resolving to *any* private address.
- Only `http` and `https`; redirects are followed manually and re-checked at
  every hop, dropping credentials when the origin changes.
- `EGRESS_ALLOWLIST` re-opens named internal hosts, so reaching a self-hosted
  Jira or GitLab is a decision recorded in configuration.

Not covered by this guard: the SMTP, LDAP and OIDC clients (they reach only the
hosts you configured) and the model provider SDK. Residual risk: DNS is
resolved by the check and again by the HTTP client, so DNS rebinding is not
fully closed. **Enforce egress at the network layer too** — a firewall on the
VM, or the chart's NetworkPolicy — with the list in
[18-PRE-INSTALL-CHECKLIST](18-PRE-INSTALL-CHECKLIST.md#2-firewall-matrix).

---

## AI features and the agent executor

The AI features are off unless an administrator connects a model provider.
Point them at a gateway inside your network; nothing is sent to us. Prompts
contain task text; they do not contain credentials or attachments.
[12-AI-MODELS](12-AI-MODELS.md)

Every agent result lands as a **draft in a review lane**: a person with the
`approve_agent_work` permission (lead and admin by default) accepts it.
Starting runs (`run_agents`) and approving them are separate permissions.

**The agent executor — running agent tasks with shell and file tools — is not
available.** It would need an isolated sandbox runtime, and none ships with
TaskSense. `AGENT_EXECUTOR=off` is the only supported value:

- the application refuses `on` / `auto` at startup (logged as an error;
  execution stays off) and `unsafe-host` in production;
- `preflight.sh` fails on any of them; the wizard and the Helm chart never
  set anything but `off`.

What remains is "knowledge mode": planning, decomposition, descriptions,
acceptance criteria — a single JSON completion per step, no tools.

---

## API documentation endpoints

| Path | What | Default |
| --- | --- | --- |
| `/api/v1/swagger` | Interactive Swagger UI over the whole API | **On** unless `SWAGGER_ENABLED=false` |
| `/api-docs` | Static API reference | Always served, without sign-in |
| `/docs` | The product guide | Always served, without sign-in |

None of them grants access — every API call still needs a credential — but they
publish the API surface. **Set `SWAGGER_ENABLED=false`**, and if your policy
treats the reference as reconnaissance, limit `/api-docs` (and `/docs`) to an
internal segment at the proxy; `examples/nginx.conf` and `examples/Caddyfile`
show how.

---

## Audit and logging

**Audit trail.** Changes to tasks, documents, epics, sprints, releases, users,
settings and the other administered objects are recorded with actor, object,
field, old value, new value and time, in the `history` collection. The
application offers no route to edit or delete it. Administrative actions —
role changes, suspensions, security policy, sign-in settings, revoked sessions
and tokens — are included. Automation runs, imports and agent runs keep their
own trails.

**Application logs.** `LOG_FORMAT=json` (the on-premise default): one object
per line on stdout with timestamp, level, subsystem, message, request id and
workspace. Every request gets an id, returned as `X-Request-Id`; the example
nginx configuration passes its own, so proxy and application logs correlate.

**Never written to logs:** passwords, session tokens, API keys, personal access
tokens, request bodies, complete model prompts. URL tickets and the path tokens
of the inbound-mail, invite and hook routes are masked; the MongoDB URI is
logged with its password masked.

What is missing is listed under [known limitations](#known-limitations):
sign-in events and client addresses are not in the audit trail. SIEM
integration: [09-MONITORING](09-MONITORING.md#logs).

`scripts/collect-diagnostics.sh` bundles logs and configuration for support
with every secret replaced by `<redacted>`. Review the archive before sending
it — logs contain user names and task titles.

---

## Containers and supply chain

**Runtime hardening.**

- Base image pinned by **digest**. Multi-stage build; the runtime image has no
  compiler, no source, no development dependencies and no package manager
  (npm is removed).
- Runs as **UID 1001, GID 0**, `tini` as PID 1. Writable only:
  `/app/api/data` (the data volume) and `/tmp`.
- **Compose:** read-only root filesystem, `cap_drop: ALL`,
  `no-new-privileges`, `/tmp` as a small tmpfs; memory and CPU limits; log
  rotation. Uploads are staged on the data volume, not in `/tmp`.
- **Helm:** `runAsNonRoot`, `seccompProfile: RuntimeDefault`,
  `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, all capabilities
  dropped; runs under OpenShift's `restricted-v2` SCC unmodified; its own
  ServiceAccount with no API token mounted; an optional default-deny
  NetworkPolicy.

**What we publish, and how to check it.**

| | |
| --- | --- |
| Signatures | Images, the Helm chart and the offline bundle's `SHA256SUMS` are signed with cosign. `cosign.pub` is on the public releases page; compare its fingerprint with the one we give you out-of-band. |
| `scripts/verify-signature.sh` | Checks the bundle's checksum **and** signature, and **fails closed** when cosign is missing. |
| SBOM | CycloneDX, `sbom.cdx.json` in the offline bundle, and as an attestation on the image. |
| Vulnerability scan | Trivy, fixable CRITICAL and HIGH findings, `trivy-report.json` in the offline bundle. It reports rather than blocks the release; re-scan in your registry and gate on it if your policy requires. |

```bash
cosign verify --key cosign.pub ghcr.io/yurdtech/tasksense:1.1.0
./scripts/verify-signature.sh tasksense-onprem-1.1.0.tar.gz
```

The image and the bundle are private in the registry; access is a per-customer,
read-only token that can be revoked at any time
([13-REGISTRY-ACCESS](13-REGISTRY-ACCESS.md)).

---

## Hardening checklist

Before going live:

- [ ] Image (and chart) signature verified; key fingerprint compared out-of-band
- [ ] `STORAGE_SECRET` generated with `openssl rand -base64 32`, stored in the vault separately from the backups
- [ ] `MONGO_PASSWORD` generated (bundled), or a dedicated MongoDB account with `readWrite` (+ `dbAdmin`) on `tasksense` only, over TLS
- [ ] `compose/.env` mode `600`, owned by the service account, in no repository (`preflight.sh` warns)
- [ ] TLS on the reverse proxy with a certificate your clients trust; proxy logs without query strings
- [ ] `BIND_ADDRESS=127.0.0.1`, or the proxy's interface plus a firewall rule
- [ ] `SESSION_TTL_HOURS=12` (or your policy)
- [ ] `SWAGGER_ENABLED=false`; `/api-docs` restricted at the proxy if required
- [ ] `AGENT_EXECUTOR=off`; `AGENT_DISPATCHER=off` unless an AI pilot is approved
- [ ] `OWNER_EMAILS` empty
- [ ] `EGRESS_ALLOWLIST` empty, or only hosts you intend
- [ ] Every directory in Admin → Authentication on `ldaps://`, CA pasted, insecure switch off
- [ ] At least one local administrator with a strong password, in the break-glass procedure
- [ ] `NODE_EXTRA_CA_CERTS` set to your CA bundle instead of any "skip verification" setting
- [ ] Egress limited at the network layer (firewall / NetworkPolicy)
- [ ] `LOG_FORMAT=json`, logs shipped to the SIEM; audit export or webhook in place
- [ ] `METRICS_TOKEN` generated; metrics scraped from the monitoring segment only
- [ ] Backups scheduled off-host, encrypted, *and a restore rehearsed* ([07-BACKUP-DR](07-BACKUP-DR.md))
- [ ] Helm: `networkPolicy.enabled: true`; one replica (enforced)

---

## Known limitations

Stated plainly, so they are not discovered during an audit:

1. **Business content is not encrypted at rest by the application.** Use
   encrypted storage underneath.
2. **No SAML, no SCIM.** OIDC and LDAP only. Deprovisioning is by directory
   status and group membership at the next sign-in; an existing session lives
   until it expires.
3. **No multi-factor authentication inside TaskSense.** Get it from your IdP
   through OIDC. LDAP sign-in is password-only.
4. **The audit trail has gaps:** sign-ins, sign-outs and failed sign-ins are not
   recorded, and no record carries the client IP or user agent. There is no
   retention setting and no built-in export to syslog. Compensate with the
   request log, the proxy's access log, and a periodic export or webhook.
5. **OIDC is simplified:** no PKCE, identity read from the userinfo endpoint
   rather than a locally verified ID token, `email_verified` not checked —
   accounts are linked by e-mail. Low practical risk against your own IdP over
   HTTPS when it only issues verified addresses; hardening is planned.
6. **Some tokens are stored in clear text** in the database: invite and
   password-reset tokens (short-lived, single-use), the inbound-mail and
   automation-hook tokens, outgoing-webhook signing secrets. Anyone with a
   database dump can read them; protect dumps accordingly.
7. **`STORAGE_SECRET` cannot be rotated in place** — rotation is re-entering
   the stored credentials.
8. **DNS rebinding is not fully closed** in the SSRF guard, and the SMTP, LDAP,
   OIDC and model SDK clients are outside it. Enforce egress at the network.
9. **Single active process.** Availability comes from restart and a MongoDB
   replica set, not redundancy of the API ([15-SCALING-AND-HA](15-SCALING-AND-HA.md)).
   Rate-limit and lockout counters reset when it restarts.
10. **No IP allowlist inside the application.** Enforce at the proxy or
    firewall.
11. **Uploaded files are not virus-scanned.** Restrict extensions in
    Admin → Storage, or scan at the proxy (ICAP) or on the volume.
12. **The licence cannot be revoked remotely** — an instance that never calls
    us cannot be told anything. Protect `LICENSE_KEY` like a secret.
13. **No agent executor.** Tool-using agent execution needs a sandbox that
    does not ship; it is off and cannot be turned on.

---

## Reporting a vulnerability

Privately, not as a public issue: **security@yurdtech.az**. Include the version
(`curl https://<your-host>/api/v1/version`), what you observed, and how to
reproduce it. We acknowledge within two business days and aim to ship a fix
for a confirmed critical issue within five. Details: [SECURITY.md](../SECURITY.md).
