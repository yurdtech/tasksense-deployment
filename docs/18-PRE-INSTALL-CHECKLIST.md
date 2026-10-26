# Pre-install checklist

Everything your teams need to prepare **before** the installation window,
in one place: network, DNS and certificates, the reverse proxy, directory and
SSO, mail, the database, sizing, backups, registry access, and who does what.

Almost every failed first install is one of these not being ready on the day —
a firewall rule, a certificate chain, a database account. Work through this
with the network, PKI, directory, database and security teams two weeks ahead;
the install itself then takes an afternoon.

Section 12 is the **deployment profile**: the values to agree in the
kick-off meeting, and the questions still open.

Applies to TaskSense **1.1.0** or later.

---

## 1. Platform decision

| Decision | Options | Notes |
| --- | --- | --- |
| Platform | **Docker Compose** on one Linux VM · **Helm** on Kubernetes 1.27+ / OpenShift 4.12+ | Same image, same features. Compose is simpler to operate and restore; choose Helm because you already run a cluster ([00-OVERVIEW](00-OVERVIEW.md#choosing-a-platform)). |
| Database | Bundled MongoDB 7 (Compose only) · your own MongoDB 7 | For production, your own replica set ([16](16-EXTERNAL-DATABASES.md)). Bundled is fine for a pilot. |
| Software delivery | Pull from `ghcr.io` · mirror into Harbor/Nexus · offline bundle | [13-REGISTRY-ACCESS](13-REGISTRY-ACCESS.md) |
| Jira migration | XML site backup import · Jira API import · none | A backup import needs the import worker and disk (section 8). |
| AI features | Off · internal model gateway | Off unless a pilot is approved. Tool-using execution is not available in any case. |

- [ ] Platform agreed
- [ ] Database option agreed
- [ ] Delivery path agreed

---

## 2. Firewall matrix

Everything not listed can be denied. TaskSense needs **no internet access at
run time**.

### Inbound

| # | From | To | Port | Purpose | Needed |
| --- | --- | --- | --- | --- | --- |
| I1 | User workstations | Reverse proxy / Ingress / Route | 443/tcp | The web interface and API | Always |
| I2 | API clients, CI, MCP workstations | Reverse proxy | 443/tcp | REST and Jira-compatible API with personal access tokens | If used |
| I3 | GitLab / GitHub servers | Reverse proxy, path `/api/v1/integrations/{gitlab,github}/webhook/*` only | 443/tcp | Merge events | If used |
| I4 | Mail relay | Reverse proxy, path `/api/v1/inbound-mail/*` only | 443/tcp | Tasks from e-mail | If used |
| I5 | Monitoring (Prometheus, blackbox) | Reverse proxy, `/api/v1/metrics`, `/api/v1/health/*` | 443/tcp | Metrics and probes | Recommended |
| I6 | Reverse proxy host | TaskSense host | 3000/tcp | Only when the proxy is **not** on the TaskSense host (Compose: `BIND_ADDRESS`) | If applicable |
| I7 | Administrators' jump host | TaskSense host | 22/tcp | Operations | Compose |

MongoDB (bundled) publishes **no** port. The import worker listens on nothing.

### Outbound, from the TaskSense host (or pods)

| # | To | Port | Purpose | Needed |
| --- | --- | --- | --- | --- |
| O1 | Domain controllers (every domain configured) | 636/tcp (LDAPS) | Directory sign-in | If LDAP |
| O2 | OIDC identity provider | 443/tcp | Discovery, token, userinfo (server-to-server) | If OIDC |
| O3 | **Every** MongoDB replica-set member | 27017/tcp (or yours) | The database | Own MongoDB |
| O4 | SMTP relay | 25, 587 or 465/tcp | Notifications, invitations, password reset | If mail |
| O5 | Object storage (S3 / MinIO / WebDAV) | 443/tcp | Attachments, if not on the volume | If used |
| O6 | Internal model gateway | 443/tcp (or its port) | AI features | If AI pilot |
| O7 | Jira server | 443/tcp | Import over the Jira API (not needed for a backup-file import) | Migration window |
| O8 | Webhook receivers (e.g. a SIEM collector) | 443/tcp | Outgoing audit webhooks | If configured |
| O9 | DNS servers | 53/udp+tcp | Name resolution | Always |
| O10 | NTP | 123/udp | Time (TLS and tokens depend on it) | Always |
| O11 | Backup target (NFS 2049, SMB 445, or S3 443) | as applicable | `backup.sh` output | Compose |
| O12 | Log collector / SIEM | as applicable | Shipping container logs | Recommended |
| O13 | Internal registry (Harbor / Nexus) | 443/tcp | Image pulls | If mirrored |
| O14 | `ghcr.io`, `pkg-containers.githubusercontent.com`, `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` | 443/tcp | Image pulls — **install and upgrade windows only**; none with a mirror or the offline bundle | If pulling directly |

On Kubernetes, express O1–O13 as the chart's NetworkPolicy egress CIDRs
(default-deny otherwise) and I1/I5 as the ingress-controller and monitoring
namespaces.

- [ ] Inbound rules raised
- [ ] Outbound rules raised, including **every** MongoDB member
- [ ] Rules tested from the TaskSense host before the window (`nc -vz <host> <port>`)

---

## 3. DNS and TLS certificate

| Item | Value / requirement |
| --- | --- |
| FQDN | e.g. `tasksense.corp.internal` — becomes `APP_URL`. Changing it later means re-registering the OIDC client. |
| DNS record | A/CNAME to the reverse proxy / ingress VIP |
| Server certificate | Issued by your internal CA; SAN contains the FQDN; full chain (leaf + intermediates) in PEM; key unencrypted for the proxy or in the proxy's HSM/keystore |
| Renewal | Owner and date recorded; the proxy, not TaskSense, holds it |
| CA bundle for TaskSense | One PEM file with your **root and issuing** CAs, used for outbound TLS (MongoDB, SMTP, IdP, object storage, gateway): `compose/certs/corp-ca.pem` → `NODE_EXTRA_CA_CERTS=/certs/corp-ca.pem` |
| LDAP CA | The CA that issued the domain controllers' certificates, as PEM text — pasted in Admin → Authentication |
| Workstations | Trust your internal CA (browser policy) |

- [ ] FQDN and DNS record created
- [ ] Certificate (full chain) issued and on the proxy
- [ ] CA bundle PEM handed to the installer

---

## 4. Reverse proxy / WAF

TaskSense speaks plain HTTP on port 3000; TLS terminates at your reverse proxy
(nginx, HAProxy, F5) or Ingress/Route. Ready-made: `examples/nginx.conf`,
`examples/Caddyfile`. Whatever the product, it must:

| # | Requirement | Why |
| --- | --- | --- |
| P1 | Forward `Host`, `X-Forwarded-For`, `X-Real-IP`, `X-Forwarded-Proto` on **every** path | One proxy hop is trusted for the client address (rate limits, sign-in lockout) and the scheme |
| P2 | `/api/v1/state/stream` and `/api/v1/agents/events/stream`: response buffering **off**, read timeout **24 h**, query string passed unchanged | Live updates (server-sent events); the query carries a short-lived ticket |
| P3 | Upload routes — `/api/v1/integrations/{jira,confluence,csv}/…`, `/api/v1/import/…`, `/api/v1/{tasks,docs}/<id>/attachments`, `/rest/api/{2,3}/issue/<key>/attachments`: body limit **21 GB**, request buffering **off**, send/read timeouts **4 h** | Jira site backups (up to `JIRA_BACKUP_MAX_GB`, 20 GB) and attachments; the application enforces the real per-route limits |
| P4 | Everything else: body limit **25 MB**, read timeout 300 s | |
| P5 | HTTP/1.1 to the upstream with keep-alive; idle upstream connections closed in **under 65 s** | The application closes idle sockets at 65 s |
| P6 | Do **not** add CSP, HSTS, X-Frame-Options | The application sets them; two sets contradict |
| P7 | Access log **without query strings** (log the path only) | Defence in depth for the stream/video tickets |
| P8 | WAF: do not inspect/buffer P2 and P3 bodies; expect JSON with Markdown and HTML fragments in task descriptions (common false positives) | |
| P9 | Optional: limit `/api-docs` and `/docs` to an internal segment; I3/I4 paths to the GitLab / mail-relay segment | Public-by-design endpoints |

- [ ] Proxy configuration prepared and reviewed
- [ ] WAF exceptions for P2/P3 approved

---

## 5. Identity: LDAPS and OIDC

### Active Directory / LDAP (per domain)

| Item | Example |
| --- | --- |
| LDAPS URL(s) | `ldaps://dc01.corp.internal:636` (two DCs or a VIP) |
| Service account | `CN=svc-tasksense,OU=Service Accounts,DC=corp,DC=internal` — **read-only**, no interactive logon, password rotation process agreed |
| Search base | `DC=corp,DC=internal` |
| User filter | `(sAMAccountName={{username}})`, optionally `(&(…)(memberOf=CN=TaskSense-Users,…))` |
| Groups → roles | Full DNs for `admin`, `lead`, `member`, `viewer` (and `release_manager` if used) |
| Required attribute | `mail` on every user who will sign in — it joins the directory identity to the TaskSense account |
| CA | The DCs' issuing CA, PEM |
| Test users | One per role, for the connection test on the day |

### OIDC (Keycloak / AD FS / Entra ID / Okta)

| Item | Value |
| --- | --- |
| Client | Confidential, authorization-code flow |
| Redirect URI | `https://<FQDN>/api/v1/auth/oidc/callback`, exactly |
| Scopes / claims | `openid profile email`; `email` required and **verified** |
| Issuer URL | e.g. `https://sso.corp.internal/realms/corporate` |
| MFA | Enforced at the IdP (TaskSense has no MFA of its own) |
| Client secret | Delivered through the vault, into `OIDC_CLIENT_SECRET` |

### Break-glass

- [ ] A named administrator for `FIRST_ADMIN_EMAIL`, who will hold a local
      password in the break-glass procedure
- [ ] Session lifetime agreed (`SESSION_TTL_HOURS`, recommendation 12 h)
- [ ] Local password minimum agreed (6–32)

---

## 6. SMTP relay

| Item | Value |
| --- | --- |
| Relay host / port | e.g. `smtp.corp.internal:587` |
| TLS | STARTTLS (587/25) or implicit TLS (465 → `SMTP_SECURE=true`); certificate from your internal CA (covered by the CA bundle) |
| Authentication | Account or IP-based relay permission for the TaskSense host |
| Sender | `EMAIL_FROM`, e.g. `TaskSense <tasksense@corp.internal>`, allowed by the relay |

- [ ] Relay permits the TaskSense host and sender

---

## 7. MongoDB (if you provide it)

| Item | Requirement |
| --- | --- |
| Version | MongoDB 7.x |
| Topology | Replica set of three (name, e.g. `rs0`, and every member's host:port) |
| Database | `tasksense` (or agreed name → `MONGODB_DB`) |
| Account | `tasksense`, in `admin`, with `readWrite` + `dbAdmin` on the database only ([16 › Create the account](16-EXTERNAL-DATABASES.md#1-create-the-account)) |
| TLS | On; server certificates from your internal CA with SANs matching the host names in the URI |
| Encryption at rest | Encrypted storage or MongoDB Enterprise encryption — TaskSense does not encrypt business content |
| Backups | DBA policy (snapshots / PITR) **in addition to** `backup.sh`, or `backup.sh` as the primary |
| Monitoring | DBA's usual tooling; TaskSense exports pool and latency metrics |

- [ ] Account created and URI handed over through the vault
- [ ] TLS tested from the TaskSense host (`mongosh "<uri>" --eval 'db.runCommand({ping:1})'`)

---

## 8. Sizing and storage

| Item | Value |
| --- | --- |
| Users (accounts / concurrently active) | ____ / ____ |
| Profile | S / M / L — [11-SIZING](11-SIZING.md) |
| TaskSense host | vCPU ____ · RAM ____ GB · OS ____ |
| Docker data root (`/var/lib/docker`) on its own volume | ____ GB = images (~3 GB) + attachments + **2 × the Jira backup** + MongoDB (bundled) |
| Jira site backup size | ____ GB (e.g. a 13 GB backup needs 26 GB free for the import) |
| Migration window extra | +2 vCPU, +6 GB RAM for the import worker |
| Attachments growth | ____ GB/year — or object storage |

- [ ] Host provisioned to the profile
- [ ] Data volume sized, including the Jira import headroom

---

## 9. Backup and disaster recovery

| Item | Target / value |
| --- | --- |
| RPO | **24 h** (nightly `backup.sh`) — narrower with DBA point-in-time backups |
| RTO | **1 h** (provision + install + restore) — confirm by rehearsal |
| Backup target | Off-host: ____ (NFS / backup appliance / S3) |
| Encryption of archives | GPG key owner: ____ (archives contain `STORAGE_SECRET`) |
| Retention | ____ days (recommendation 30, monthly copies colder) |
| `STORAGE_SECRET` | Stored in vault ____, separately from the archives |
| Restore rehearsal | Date ____, on a scratch VM; result recorded |
| Who restores | ____ |

- [ ] Backup target mounted on the TaskSense host
- [ ] Rehearsal scheduled before go-live

---

## 10. Registry access or air-gap

| Path | You prepare |
| --- | --- |
| Direct pull | Outbound O14 during windows; Docker daemon proxy if used |
| Harbor / Nexus mirror | A project/repository; a robot account for pushes; pulls from the TaskSense host (O13); image scanning policy |
| Offline bundle | A transfer process into the secure zone; `cosign` and `oras` on the internet-side machine |

In every case:

- [ ] Read-only registry token received from YurdTech (username `yurdtech`)
- [ ] `cosign` installed where artefacts are verified
- [ ] cosign key fingerprint compared out-of-band with YurdTech

---

## 11. Who does what

| Task | Infrastructure | Network | PKI | Directory / IdP team | DBA | Security | Application owner | YurdTech |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| VM / cluster, OS, Docker | **R** | | | | | | | advises |
| Firewall rules, DNS | | **R** | | | | A | | provides matrix |
| Server certificate, CA bundle | | | **R** | | | | | |
| Reverse proxy / WAF | **R** | R | | | | A | | provides config |
| LDAP service account, groups | | | | **R** | | | C | |
| OIDC client, MFA policy | | | | **R** | | A | | |
| MongoDB account, TLS, backups | | | | | **R** | | | advises |
| Registry token, licence key | | | | | | | C | **R** |
| `.env` / values, install, first admin | C | | | | | | **R** | supports |
| Backups, restore rehearsal | **R** | | | | R | A | C | supports |
| Security review, pentest | | | | | | **R** | C | answers questions |
| Upgrades | C | | | | | A | **R** | release notes |
| Support | | | | | | | C | **R** — no remote access; diagnostics archive only |

R = responsible, A = approves, C = consulted. YurdTech has **no remote access**
to your environment; support works from the redacted output of
`./scripts/collect-diagnostics.sh`.

---

## 12. Deployment profile

To agree in the kick-off meeting. The right-hand column is for your values.

| Parameter | Options / default | Our recommendation | Your value |
| --- | --- | --- | --- |
| Deployment model | Compose (one Linux VM) · Helm (OpenShift / Kubernetes) | Compose for the pilot; OpenShift if you standardise on it | ☐ Compose ☐ Helm — host / cluster: ______ |
| Version | `TASKSENSE_VERSION` ≥ 1.1.0 | The current 1.1.x | version ____ · commit ______ |
| MongoDB | Bundled `mongo:7` (Compose) · your own (standalone / replica set, TLS + CA, own account) | Your own replica set, TLS, disk encryption | ☐ bundled ☐ own: hosts ______ · TLS ☐ · disk encryption ☐ |
| TLS termination and address | Reverse proxy (nginx / HAProxy / F5) or Route / Ingress; issuing CA; `APP_URL` | | proxy: ______ · CA: ______ · `https://______` |
| Sign-in | LDAP directories (one or more forests, group → role); OIDC (Keycloak / AD FS / Entra, MFA at the IdP); local break-glass admin; registration closed | LDAPS + OIDC for MFA, break-glass local admin | directories: ______ · LDAPS ☐ · OIDC: ______ · registration off ☐ · break-glass ☐ |
| Role mapping | AD group → admin / lead / member / viewer / release_manager | | admin: ______ · lead: ______ · default: ______ |
| Session policy | `SESSION_TTL_HOURS` (default 720); password minimum (default 6) | **12 h**; minimum 12 for local accounts | TTL __ h · minimum __ |
| Swagger / API reference | `SWAGGER_ENABLED` (default on); proxy limits on `/api-docs`, `/docs` | **off**; `/api-docs` internal only | ☐ off · proxy rule ☐ |
| AI — knowledge mode | Off · internal gateway (base URL, model) | Off until a pilot is approved | ☐ off ☐ gateway: ______ · model: ______ |
| AI — tool-using execution | Not available (`AGENT_EXECUTOR=off`, no sandbox ships) | off | off |
| AI — dispatcher | `AGENT_DISPATCHER` on / off; max concurrent | off without a pilot | ☐ on ☐ off · max __ |
| MCP / external AI clients | Not used · read-only PAT pilot · full | Not used, or read-only pilot | ☐ no ☐ pilot: ______ |
| E-mail | SMTP relay (host, port, TLS, CA), `EMAIL_FROM`; or in-app only | Relay with STARTTLS | relay: ______ · port __ · ☐ STARTTLS ☐ 465 |
| Attachments | Local volume (default) · S3 / MinIO · WebDAV; size limit; extension allow-list; an internal store's host in `EGRESS_ALLOWLIST` | Volume for the pilot; object storage for production | ☐ volume ☐ store: ______ · allowlisted ☐ · limit __ MB |
| Jira migration | XML site backup (tested with a 13 GB / 574k-issue site backup), automation rules (imported inactive), project selection, Confluence | Backup import with the import worker | source: ______ · window: ______ · disk ☐ · worker ☐ |
| Integrations | GitLab webhook, inbound mail, outgoing webhooks (SIEM), `EGRESS_ALLOWLIST` | Only what is used; allowlist minimal | GitLab: ______ · mail: ______ · allowlist: ______ |
| Monitoring | `METRICS_ENABLED` + `METRICS_TOKEN`; Prometheus; alert rules (`examples/prometheus-alerts.yaml`) | On | scrape: ______ · alert channel: ______ |
| Logging / SIEM | Container logs → SIEM; audit export or webhook; retention | JSON logs; audit via webhook or periodic export | SIEM: ______ · retention __ days · audit export: ______ |
| Backup | Nightly `backup.sh` / CronJob, encryption, off-host, quarterly restore test | RPO 24 h / RTO 1 h | schedule: ______ · RPO __ h · RTO __ h · owner: ______ |
| Network | Ingress 443; egress per section 2; Helm NetworkPolicy | Default-deny egress | egress list approved ☐ · NetworkPolicy ☐ |
| API replicas | 1 (enforced — single active process) | 1 | 1 |
| Registry / air-gap | `ghcr.io` read-only token · Harbor mirror · offline bundle; cosign | Harbor mirror | ☐ ghcr.io ☐ Harbor: ______ ☐ offline · cosign ☐ |
| Licence | `LICENSE_KEY`: organisation, seats, expiry | | seats __ · expiry ______ |
| Support and SLA | Channel, response times (critical / high / medium), release cadence, vulnerability notice | | channel: ______ · SLA: ______ |
| Pentest / audit | Your pentest environment and window; third-party report | | date: ______ · report: ☐ yes ☐ no |

### Questions to settle before the install

1. **MongoDB ownership.** Does the DBA team run it (replica set, disk
   encryption, separate accounts)? Should the TaskSense account be denied
   `remove` on the `history` (audit) collection for immutability — and is the
   resulting restore procedure (a DBA account) acceptable? Is the bundled
   MongoDB acceptable for the pilot only?
2. **Users.** How many accounts, and how many concurrently active? This decides
   the sizing profile.
3. **AI.** Is there an internal model gateway (vLLM / Ollama / LiteLLM), which
   models, an OpenAI-compatible endpoint? Is egress to a cloud provider ruled
   out? Knowledge mode only?
4. **MCP and external AI clients.** Allowed at all; if so, read-only tokens and
   the internal gateway only?
5. **MFA.** Is IdP MFA through OIDC sufficient, or will LDAP be the only path
   (then no MFA)?
6. **Audit.** Required retention; which events must reach the SIEM (sign-ins,
   permission changes, agent runs); is sign-in auditing (not in 1.1.0) a
   blocking requirement?
7. **Jira migration.** How the XML backup reaches the server (transfer path
   into the zone), the migration window, the resource uplift (RAM, disk), and
   who deletes the staged backup afterwards (it is a full copy of Jira; kept
   7 days by default).
8. **Sessions and passwords.** Your standard for session lifetime and local
   password policy; must directory deactivation cut existing sessions
   immediately (today: at session expiry)?
9. **Backup and DR.** Who owns backups and restores (infrastructure vs DBA), the
   archive encryption key, and whether RPO 24 h / RTO 1 h meet your
   classification for this system.
10. **Reverse proxy and WAF.** Which product fronts TaskSense, and can it meet
    P2–P5 (unbuffered streams, 21 GB unbuffered uploads, 4 h timeouts) — or do
    the upload routes need a separate path?
11. **Delivery.** Harbor mirror or offline bundle; the image scanning policy and
    who signs off findings; the cosign fingerprint exchange.
12. **Incidents.** Contact and escalation channels on both sides; aligning
    vendor patch releases with your change windows.
