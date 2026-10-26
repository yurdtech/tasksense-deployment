# Environment reference

Every setting TaskSense reads, grouped by what it is for: whether you must set
it, its default, what it does, and what we recommend for production.

- **Docker Compose:** all of these go in `compose/.env` (copy
  `compose/.env.example`). You never edit `docker-compose.yml`.
- **Helm:** the same settings are chart values — mostly `config.<camelCase>`
  (`SESSION_TTL_HOURS` → `config.sessionTtlHours`, `MONGODB_DB` →
  `config.mongodbDatabase`, `SMTP_*` → `config.smtp.*`, `OIDC_*` →
  `config.oidc.*`), plus `appUrl`, `firstAdminEmail`, `heapMb`, `worker.*`,
  `certs.*`, `logging.*`, `metrics.*`. Secrets — `STORAGE_SECRET`,
  `MONGODB_URI`, `OIDC_CLIENT_SECRET`, `SMTP_PASS`, `METRICS_TOKEN`,
  `LICENSE_KEY` — go in the Secret named by `existingSecret`. The full mapping
  is the [values reference](02-INSTALL-KUBERNETES.md#values-reference).
  **The chart's defaults are already the recommended values** where they
  differ from the application's: `sessionTtlHours: 12`, `swaggerEnabled:
  false`, `mongodbTimeoutMs: 15000`; `AGENT_EXECUTOR` is always rendered
  `off`.

The application validates the whole environment at startup and refuses to run
on an invalid one, listing **every** problem at once:

```
Invalid environment configuration:
  - APP_URL: is required when DEPLOYMENT_MODE=onprem — set it to this installation's own URL
  - STORAGE_SECRET: must be at least 32 characters (try: openssl rand -base64 32)
```

A variable the application does not know is ignored silently, so a typo in a
name is not reported — `./scripts/preflight.sh` catches the common ones
(placeholders left in, duplicated keys, inconsistent profiles).

In the **Required** column: **yes** means no default exists and the
installation does not start without it; **bundled** means required only with
the bundled MongoDB; **—** means optional.

**Recommended** is the value we suggest for a production installation. Where it is
blank, the default is the recommendation.

---

## 1. Version, images and profiles *(Compose)*

| Variable | Required | Default | What it does | Recommended |
| --- | --- | --- | --- | --- |
| `TASKSENSE_VERSION` | yes | `1.1.0` in `.env.example` | The release to run. Pin it; never `latest` — a restart could move you to another version. The release stamps the real version into `.env.example`. | The version approved by change control |
| `TASKSENSE_IMAGE` | — | `ghcr.io/yurdtech/tasksense` | Image repository. Set it when you mirror into your own registry. | `harbor.corp.internal/tasksense/tasksense` if mirrored |
| `MONGO_IMAGE` | — | `mongo` | Repository of the bundled MongoDB, and of the throwaway container `backup.sh` runs `mongodump` in for an external database. Mirror it even if you use your own MongoDB. | Your mirror, if you set `TASKSENSE_IMAGE` |
| `MONGO_VERSION` | — | `7` | Bundled MongoDB tag. A major upgrade is a deliberate step — [08-UPGRADE](08-UPGRADE.md). | Pin a patch (`7.0.14`) for reproducible images |
| `COMPOSE_PROFILES` | yes | `bundled-mongo` | Which optional services run. `bundled-mongo`: the MongoDB container. `import-worker`: the separate Jira import process. Comma-separated; empty runs neither. | `bundled-mongo` for a pilot; empty with your own MongoDB; add `import-worker` for the Jira migration |

> **`COMPOSE_PROFILES` and `MONGODB_URI` go together.** Remove
> `bundled-mongo` *and* set `MONGODB_URI`, or neither — `preflight.sh` fails
> on a mismatch. An `.env` from a 1.0.x install has no `COMPOSE_PROFILES`
> line; `install.sh`, `upgrade.sh` and `preflight.sh` add
> `COMPOSE_PROFILES=bundled-mongo` to it when `MONGODB_URI` is empty.

## 2. Address and network

| Variable | Required | Default | What it does | Recommended |
| --- | --- | --- | --- | --- |
| `APP_URL` | yes | — | The URL users type, with scheme, no trailing slash. Sign-in redirects, e-mail links and the OIDC redirect URI are built from it. | `https://tasksense.<corp-domain>` |
| `CORS_ALLOWED_ORIGINS` | — | must be set; `.env.example` uses `APP_URL` | Browser origins allowed to call the API, comma-separated. UI and API share one origin, so this is `APP_URL`. | Same as `APP_URL` |
| `BIND_ADDRESS` *(Compose)* | — | `127.0.0.1` | Host interface the application port is published on. Loopback means only a proxy on this host reaches it. | Keep `127.0.0.1`; if the proxy is another host, that host's interface plus a firewall rule |
| `HTTP_PORT` *(Compose)* | — | `3000` | Host port. The container always listens on 3000. | |
| `NODE_USE_ENV_PROXY` | with an outbound proxy | — | `1` makes the application's own HTTPS calls (the Jira Cloud sync, the Jira API import, outgoing webhooks, a cloud model) go through `HTTPS_PROXY`. Without it they try to connect directly. Compose: `compose/.env`; Helm: `extraEnv`. | `1` when the host reaches the internet only through a proxy |
| `HTTPS_PROXY` / `NO_PROXY` | with an outbound proxy | — | The corporate proxy, e.g. `http://proxy.corp.internal:3128`, and what bypasses it — keep `localhost,127.0.0.1,mongo` and your internal hosts in `NO_PROXY`. Read only when `NODE_USE_ENV_PROXY=1`. | As your network team gives them |

## 3. Secrets and licence

| Variable | Required | Default | What it does | Recommended |
| --- | --- | --- | --- | --- |
| `STORAGE_SECRET` | yes | — | At least 32 characters. Root key for every credential stored in the database: LDAP bind passwords, SMTP, object storage, model-provider and VCS webhook secrets (AES-256-GCM, one derived key per purpose). **Not recoverable, and there is no re-encryption tool** — changing it means re-entering those credentials. | `openssl rand -base64 32`, kept in your secrets vault next to the database backups |
| `LICENSE_KEY` | — | — | The `tsl_…` licence, verified offline. Without it: 10 accounts, 500 automation runs a month. [14-LICENSING](14-LICENSING.md) | Set; treat as a secret (it cannot be revoked) |

## 4. Sign-in and sessions

LDAP / Active Directory has **no environment variables** — it is configured in
the application (Admin → Authentication). See [05-IDENTITY](05-IDENTITY.md).

| Variable | Required | Default | What it does | Recommended |
| --- | --- | --- | --- | --- |
| `FIRST_ADMIN_EMAIL` | first install | — | Created on first start as the administrator, with **no password**. Claimed by signing in through LDAP/OIDC with that address, or by registering with it. | A named administrator's address — the break-glass account |
| `OWNER_EMAILS` | — | empty | Comma-separated addresses that are always administrators. A lockout escape hatch; nothing else on-premise needs it. | **Empty.** Use it only to recover from a lockout, then remove it |
| `SESSION_TTL_HOURS` | — | `720` (30 days); `.env.example` and the chart: `12` | How long a sign-in lasts. `0` means never — the default before 1.1.0. A workspace policy in Admin → Security overrides it. Sessions issued before a limit applied keep no expiry. | **`12`** (one working day) |
| `OIDC_ISSUER` | — | — | OIDC issuer URL; discovery is read from `<issuer>/.well-known/openid-configuration`. | Your IdP (Keycloak / AD FS / Entra) |
| `OIDC_CLIENT_ID` | with OIDC | — | Client id registered at the IdP. | |
| `OIDC_CLIENT_SECRET` | with OIDC | — | Client secret. Also keys the HMAC that protects the `state` parameter. | Secret |
| `OIDC_REDIRECT_URI` | — | `<APP_URL>/api/v1/auth/oidc/callback` | Must match the IdP registration exactly. | Register exactly this |
| `OIDC_LABEL` | — | `Continue with SSO` | Sign-in button text. | `Sign in with <company> account` |

## 5. Database

| Variable | Required | Default | What it does | Recommended |
| --- | --- | --- | --- | --- |
| `MONGODB_URI` | yes, unless bundled | built from `MONGO_USER`/`MONGO_PASSWORD` for the bundled container | Connection string to your own MongoDB. TLS, replica set and auth source go in the URI. Percent-encode `/ : @ ? # [ ] %` in the password. [16-EXTERNAL-DATABASES](16-EXTERNAL-DATABASES.md) | `mongodb://tasksense:<pw>@m1,m2,m3/?replicaSet=rs0&tls=true&tlsCAFile=/certs/corp-ca.pem&authSource=admin` |
| `MONGO_USER` *(Compose)* | bundled | `tasksense` | Root user the bundled container is created with. Unused with `MONGODB_URI` — leave empty. | |
| `MONGO_PASSWORD` *(Compose)* | bundled | — | Its password. Applied **only when the volume is first created**; changing it later does not change it in MongoDB. Hex, not base64 (it is substituted into a URI). | `openssl rand -hex 24` |
| `MONGODB_DB` | — | `tasksense` | Database name. Backups, restores and the migration job all read it. | |
| `MONGODB_TIMEOUT_MS` | — | `5000` | Server-selection timeout: how long every operation, and the initial connect, waits for a reachable server. | **`15000`** across a network or with a replica set (an election takes seconds) |
| `MONGODB_OP_TIMEOUT_MS` | — | `30000` | Deadline of one database operation; also bounds the wait for a pooled connection. `0` disables it. Imports, restores, exports, backups, migrations and index builds run without it. | |
| `MONGODB_MIN_POOL_SIZE` | — | `10` | Connections kept warm, so the first request after a quiet spell does not pay for TCP + TLS + authentication. | |
| `MONGODB_MAX_POOL_SIZE` | — | `100` | Pool ceiling. Raise only if `tasksense_mongo_pool_checkout_failures_total{reason="timeout"}` says so. | |
| `MONGODB_COMPRESSORS` | — | `zlib`; `.env.example`: `none` (bundled) | Wire compression to MongoDB. **Switch it to `zlib` when you move to your own MongoDB.** | `zlib` for a database on another host; **`none`** for the bundled same-host container |
| `MONGODB_COMMAND_MONITORING` | — | off | Per-command duration metrics. Costs CPU; turn on to diagnose, then off. | Off |
| `MONGO_CACHE_GB` *(Compose)* | — | `1` | WiredTiger cache of the bundled MongoDB (`--wiredTigerCacheSizeGB`). Keep it at about half of `MONGO_MEMORY_LIMIT` minus 1 GB, never above it. | See [11-SIZING](11-SIZING.md) |

## 6. Processes, memory and CPU

The API is **one process by design** — see [15-SCALING-AND-HA](15-SCALING-AND-HA.md).
The only optional second process is the import worker.

| Variable | Required | Default | What it does | Recommended |
| --- | --- | --- | --- | --- |
| `WORKER_ROLE` | — | `all` | Which background work this process runs. `all`: everything in one process. `api`: everything except Jira backup landings. `worker`: only landings (the compose `worker` service forces this). | **`api`** whenever the `import-worker` profile is on — `preflight.sh` enforces it |
| `APP_HEAP_MB` *(Compose)* | — | `1536` | Node.js heap of the API (`--max-old-space-size`). Keep it at about 75 % of `APP_MEMORY_LIMIT`. | |
| `APP_CPU_LIMIT` *(Compose)* | — | `2` | CPU ceiling of the API container. | |
| `APP_MEMORY_LIMIT` *(Compose)* | — | `2g` | Memory ceiling of the API container. | |
| `WORKER_HEAP_MB` *(Compose)* | — | `4096` | Node.js heap of the import worker. A landing of a large Jira backup is the most memory-hungry thing TaskSense does. | |
| `WORKER_CPU_LIMIT` *(Compose)* | — | `2` | CPU ceiling of the worker. | |
| `WORKER_MEMORY_LIMIT` *(Compose)* | — | `6g` | Memory ceiling of the worker. | |
| `MONGO_CPU_LIMIT` *(Compose)* | — | `2` | CPU ceiling of the bundled MongoDB. | |
| `MONGO_MEMORY_LIMIT` *(Compose)* | — | `2g` | Memory ceiling of the bundled MongoDB. | |
| `NODE_OPTIONS` | — | set by the stack | Compose and Helm build it from the heap settings above (`--max-old-space-size=<MB>`). Set the heap variables, not this. | |
| `SETTINGS_CACHE_TTL_MS` | — | `30000` with `WORKER_ROLE=all`, `0` otherwise | How long a cached workspace-settings document is trusted before it is re-checked; only matters when a second process writes. | |

## 7. Trusting your certificate authority

| Variable | Required | Default | What it does | Recommended |
| --- | --- | --- | --- | --- |
| `NODE_EXTRA_CA_CERTS` | — | — | A PEM bundle the application trusts **in addition to** the public roots, for every outbound TLS connection: MongoDB, SMTP, OIDC discovery and token calls, object storage, the model gateway. Path **inside the container**. One file may hold several CAs. | **`/certs/corp-ca.pem`** — root and issuing CAs concatenated |

Put the file in `compose/certs/` (Compose; mounted read-only at `/certs`) or
in `certs.*` values (Helm). The LDAP CA is the exception: it is pasted as text
in Admin → Authentication, per directory. MongoDB can also be given its CA in
the URI (`tlsCAFile=/certs/…`).

## 8. Mail

Unset, notifications still appear in the application; only e-mail is skipped.
Admin → Email delivery overrides these once saved there.

| Variable | Required | Default | What it does | Recommended |
| --- | --- | --- | --- | --- |
| `SMTP_HOST` | — | — | Relay host. | The internal relay |
| `SMTP_PORT` | — | `587` | Relay port. | `25` / `587` (STARTTLS) or `465` (implicit TLS) |
| `SMTP_SECURE` | — | `false` | `true`: TLS from the first byte (port 465). `false`: plain connection, upgraded with STARTTLS when the relay offers it. | Match the relay |
| `SMTP_USER` / `SMTP_PASS` | — | — | Relay authentication; omitted when either is empty. | Per relay policy |
| `EMAIL_FROM` | — | — | Sender, e.g. `TaskSense <tasksense@corp.internal>`. | An address the relay accepts |

## 9. Files, uploads and the Jira import

| Variable | Required | Default | What it does | Recommended |
| --- | --- | --- | --- | --- |
| `STORAGE_MAX_FILE_MB` | — | `25` | Per-file attachment limit. | Per your policy |
| `STORAGE_MAX_VIDEO_FILE_MB` | — | `200` | Limit for inline-playable video (mp4/webm/mov). | Lower, or equal to the above, if video is not wanted |
| `JIRA_BACKUP_MAX_GB` | — | `20` | Largest Jira site backup (`entities.xml`) and workspace archive accepted. Streamed to disk, never held in memory. Your reverse proxy's upload limit must be at least this (`examples/nginx.conf` uses 21g). | At least the size of the backup you will import |
| `JIRA_BACKUP_RETENTION_DAYS` | — | `7` | How long an uploaded Jira backup is kept for further landings before it is deleted. | `7` during the migration; it is a full copy of your Jira, so not longer than needed |
| `TMPDIR` | — | set by the stack | Where uploads are staged: `/app/api/data/tmp`, on the data volume, shared by the API and the worker. Not configurable in `.env`. | Plan **free space = 2 × the Jira backup size** on the data volume |
| `STORAGE_LOCAL_ROOT` | — | set by the stack | `/app/api/data/uploads` — attachments on the data volume. Object storage (S3/MinIO/WebDAV) is configured in Admin → Storage instead. | |
| `BACKUP_DIR` | — | set by the stack | `/app/api/data/backups` — the application's own nightly per-workspace JSON snapshots. Not a disaster-recovery backup ([07-BACKUP-DR](07-BACKUP-DR.md)). | |

## 10. Limits for very large workspaces

The defaults are sized for a workspace migrated from a large Jira (hundreds of
thousands of issues). Change them only on our advice.

| Variable | Default | What it bounds |
| --- | --- | --- |
| `STATE_TASK_LIMIT` | `5000` | Tasks in the initial screen load; the rest are paged, and the screen says how many were withheld. |
| `STATE_COMMENT_LIMIT` | `5000` | Comments in the initial load (newest first). |
| `STATE_HISTORY_LIMIT` | `5000` | Audit entries in the initial load. |
| `STATE_WORKLOG_LIMIT` | `5000` | Worklogs in the initial load. |
| `STATE_NOTIFICATION_LIMIT` | `500` | Notifications in the initial load. |
| `STATE_AGENT_EVENT_LIMIT` | `2000` | Agent events in the initial load. |
| `STATE_AGENT_RUN_LIMIT` | `1000` | Agent runs in the initial load. |
| `STATE_DOC_BODY_BUDGET` | `2000000` | Bytes of document bodies in the initial load; the rest load when opened. |
| `TASKS_MAX_UNPAGED` | `1000` | Ceiling of an unpaged `GET /tasks`. |
| `EXPORT_JSON_MAX_ROWS` | `100000` | Rows in a single-document JSON export; above it the streamed NDJSON archive is used. |
| `REPORTS_MAX_TASKS` | `150000` | Rows one report reads; a report that hits it says so. |
| `AUTOMATION_PROCESSING_MINUTES_PER_12H` | `60` | Automation processing time per workspace per 12 h (Jira's own rule). `0` lifts it. |

## 11. Logs and metrics

| Variable | Required | Default | What it does | Recommended |
| --- | --- | --- | --- | --- |
| `LOG_FORMAT` | — | `json` on-premise | `json`: one object per line for a SIEM. `text`: readable, not parseable. | `json` |
| `LOG_LEVEL` | — | `log` | `verbose`, `debug`, `log`, `warn`, `error`, `fatal`. There is no `info`; `log` is the ordinary level. | `log` |
| `METRICS_ENABLED` | — | off | Prometheus endpoint at `/api/v1/metrics`. Needs `METRICS_TOKEN` too. | `1` |
| `METRICS_TOKEN` | with metrics | — | Bearer token the endpoint requires. Without it the endpoint answers 404; with a wrong one, 403. | `openssl rand -hex 32` |

## 12. Security switches

| Variable | Required | Default | What it does | Recommended |
| --- | --- | --- | --- | --- |
| `SWAGGER_ENABLED` | — | **on** in the application; `.env.example` and the chart: `false` | The interactive API browser at `/api/v1/swagger`. The application serves it unless this is `false` — it publishes the whole API surface without sign-in. Removing the line from `.env` turns it back **on**. | **`false`** |
| `EGRESS_ALLOWLIST` | — | empty | Internal hosts the application may call from administrator-supplied URLs: the object-storage endpoint (S3 / MinIO / WebDAV), webhooks, importers, the model base URL. Everything private is refused otherwise, and Admin → Storage will not save an endpoint it would refuse. SMTP, LDAP, OIDC and MongoDB are not affected. See [04-CONFIGURATION](04-CONFIGURATION.md#internal-hosts-the-application-calls-egress_allowlist). | Only hosts you intend: the MinIO / S3 host if attachments are not on the volume, the Jira host during migration **and for the two-way Jira sync** (e.g. `your-company.atlassian.net` — listing it also spares the DNS check a proxied network cannot answer), GitLab, the model gateway |
| `RATE_LIMIT_STORE` | — | `memory` | Where rate-limit counters live. `memory` fits the single-process design; `mongo` survives restarts at one database round trip per throttled request. | `memory` |

## 13. AI features

Off unless you connect a model provider (Agents → Settings & roles). See
[12-AI-MODELS](12-AI-MODELS.md).

| Variable | Required | Default | What it does | Recommended |
| --- | --- | --- | --- | --- |
| `AGENT_DISPATCHER` | — | `on` (app); `off` in the chart and `.env.example` | The scheduler that advances agent work every `AGENT_TICK_MS`. | `off` unless an AI pilot is approved |
| `AGENT_EXECUTOR` | — | `off` | Running agent tasks with shell and file tools. **No sandbox ships with TaskSense, so `off` is the only supported value.** The application refuses `on`/`auto` at startup (logged as an error; execution stays off) and `unsafe-host` in production; `preflight.sh` fails on any of them; the wizard and the Helm chart never set anything else. | **`off`** |
| `AGENT_MODEL` | — | `claude-opus-4-8` | Default model id; usually overridden per provider in the application. | The model your gateway serves |
| `AGENT_TICK_MS` | — | `15000` | Dispatcher interval. | |
| `AGENT_MAX_CONCURRENT` | — | `2` | Parallel agent runs per workspace. | |
| `AGENT_AUTO_DECOMPOSE` | — | on | Agents may split large tasks into subtasks. `false` turns it off. | |
| `AGENT_WORKSPACE_ROOT`, `AGENT_EXEC_MAX_TURNS`, `AGENT_EXEC_ALLOW_NETWORK` | — | `data/workspaces`, `30`, `off` | Executor settings. Inert while `AGENT_EXECUTOR=off`. | Leave unset |
| `ANTHROPIC_API_KEY` | — | — | A server-wide fallback key for a cloud provider. | **Leave unset** — connect your internal gateway in the application, where the key is encrypted |

## 14. Set by the stack — do not set

Compose and Helm set these; a value in `.env` is overridden or rejected.

| Variable | Value | Why |
| --- | --- | --- |
| `DEPLOYMENT_MODE` | `onprem` | Turns on the strict on-premise contract: required secrets, strict security headers, single workspace, closed self-registration, demo/cloud integrations refused. |
| `NODE_ENV` | `production` | Required by the contract above. |
| `PORT` | `3000` | The container port. Change `HTTP_PORT` instead. |
| `MIGRATE_ON_BOOT` | `manual` | Migrations run once, in the `migrate` service (Compose) or the migration Job (Helm), before the application starts. `auto` (the application default) is for a bare single container. |
| `TMPDIR`, `STORAGE_LOCAL_ROOT`, `BACKUP_DIR` | on the data volume | See section 9. |
| `WEB_DIST_DIR`, `TASKSENSE_COMMIT`, `TASKSENSE_BUILD_DATE` | baked into the image | What `/api/v1/version` reports. |

## 15. Refused on-premise

These make the application refuse to start, so a copied-in hosted
configuration fails loudly instead of quietly reaching a cloud service:

| Variable | Why |
| --- | --- |
| `AUTH_DEMO_LOGIN` | A password-less sign-in for demos. |
| `GOOGLE_CLIENT_ID` | Verifies tokens against Google. Use OIDC or LDAP. |
| `STRIPE_SECRET_KEY`, `STRIPE_PRICE_PRO` | Entitlement comes from `LICENSE_KEY`, verified offline. |
| `RESEND_API_KEY` | Posts mail to a cloud API. Use `SMTP_*`. |
| `MONGODB_URI=mongodb://localhost:27017` | The development default — almost always a copied file, never an intent. |

Not refused, but **leave unset on-premise**: `GMAIL_USER`, `GMAIL_APP_PASSWORD`
and `SLACK_WEBHOOK_URL` reach public cloud services.

---

## A hardened baseline

What we would put in `compose/.env` for a regulated installation with its own
MongoDB, before site-specific values:

```dotenv
TASKSENSE_VERSION=1.1.0
COMPOSE_PROFILES=                      # your own MongoDB; add import-worker for the Jira migration
APP_URL=https://tasksense.corp.internal
CORS_ALLOWED_ORIGINS=https://tasksense.corp.internal
BIND_ADDRESS=127.0.0.1
FIRST_ADMIN_EMAIL=tasksense-admin@corp.internal
STORAGE_SECRET=<openssl rand -base64 32>
LICENSE_KEY=tsl_...

MONGODB_URI=mongodb://tasksense:<pw>@mongo-1.corp.internal:27017,mongo-2.corp.internal:27017,mongo-3.corp.internal:27017/?replicaSet=rs0&tls=true&tlsCAFile=/certs/corp-ca.pem&authSource=admin
MONGODB_TIMEOUT_MS=15000
MONGODB_COMPRESSORS=zlib
NODE_EXTRA_CA_CERTS=/certs/corp-ca.pem

SESSION_TTL_HOURS=12
SWAGGER_ENABLED=false
OWNER_EMAILS=
AGENT_EXECUTOR=off
AGENT_DISPATCHER=off
EGRESS_ALLOWLIST=

LOG_FORMAT=json
METRICS_ENABLED=1
METRICS_TOKEN=<openssl rand -hex 32>
```

During the Jira migration window, additionally:

```dotenv
COMPOSE_PROFILES=import-worker
WORKER_ROLE=api
EGRESS_ALLOWLIST=jira.corp.internal    # only if importing over the Jira API rather than from a backup file
```

With attachments in an internal object store, add its host (keep the others):

```dotenv
EGRESS_ALLOWLIST=minio.corp.internal
```
