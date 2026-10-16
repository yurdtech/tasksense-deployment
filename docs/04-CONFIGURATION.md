# Configuration

How TaskSense is configured, where each kind of setting lives, and how to change
one safely. The table of **every** variable — required or not, default, what it
does, what we recommend for a bank — is [17-ENVIRONMENT](17-ENVIRONMENT.md).

---

## Where settings live

| Kind | Docker Compose | Helm | Restart to apply |
| --- | --- | --- | --- |
| Deployment settings — address, database, secrets, OIDC, limits, logging | `compose/.env` | `my-values.yaml` (`config.*` and friends) | yes |
| Secrets — `STORAGE_SECRET`, `MONGODB_URI`, `OIDC_CLIENT_SECRET`, `SMTP_PASS`, `METRICS_TOKEN`, `LICENSE_KEY` | `compose/.env` (mode `600`) | a Kubernetes Secret (yours, or the chart's) | yes |
| CA certificates for outbound TLS | `compose/certs/` → `/certs` | `certs.*` values → `/certs` | yes |
| Directory sign-in (LDAP / AD), self-registration | **in the application** — Admin → Authentication | same | no |
| Session lifetime, password minimum | `SESSION_TTL_HOURS`; overridable in Admin → Security | same | no (Admin) |
| SMTP | `SMTP_*`; overridable in Admin → Email delivery | same | no (Admin) |
| Attachment storage (S3, MinIO, WebDAV) | Admin → Storage | same | no |
| Model providers, agent settings | Agents → Settings & roles | same | no |

Credentials entered in the application are encrypted at rest with
`STORAGE_SECRET`. **You never edit `docker-compose.yml` or the chart
templates** — that is what keeps upgrades a `git pull` away.

---

## How settings are checked

Three layers, each before the next can fail more confusingly:

1. **`./scripts/preflight.sh`** (Compose) reads `.env` and the host:
   placeholders left in, duplicate keys, permissions, `STORAGE_SECRET` length,
   `COMPOSE_PROFILES` against `MONGODB_URI`, the import worker without
   `WORKER_ROLE=api`, an external MongoDB that does not answer, CA files
   missing from `certs/`, `AGENT_EXECUTOR` other than `off`, Swagger on, a
   session lifetime of `0`, free disk, the port, and whether Compose accepts
   the file. Exit 0 = ready, 1 = blocking problem; warnings do not fail.
2. **Helm** refuses to render an unsupported values file: more than one API
   replica, autoscaling, the worker without a `ReadWriteMany` volume, a short
   `storageSecret`.
3. **The application** validates its whole environment at startup and refuses
   to run on an invalid one, listing every problem at once:

```
Invalid environment configuration:
  - NODE_ENV: must be "production" when DEPLOYMENT_MODE=onprem (it gates seed reset and demo login)
  - STORAGE_SECRET: is required when DEPLOYMENT_MODE=onprem — without it stored S3 and LLM credentials are encrypted with a public development key
```

One edit, one restart fixes the file. A variable the application does not know
is ignored — a misspelt name is not an error, which is why `preflight.sh`
exists.

---

## The minimum

These have no default; the stack does not start without them.

| Setting | Example | |
| --- | --- | --- |
| `TASKSENSE_VERSION` | `1.1.0` | Pin it; never `latest`. |
| `APP_URL` | `https://tasksense.bank.internal` | What users type. Sign-in redirects and e-mail links are built from it. |
| `CORS_ALLOWED_ORIGINS` | same as `APP_URL` | |
| `STORAGE_SECRET` | `openssl rand -base64 32` | At least 32 characters. **Not recoverable — back it up.** |
| `FIRST_ADMIN_EMAIL` | `tasksense-admin@bank.internal` | First install only. Becomes the administrator, with no password. |
| `MONGO_PASSWORD` | `openssl rand -hex 24` | **Bundled MongoDB only.** Hex — it is substituted into a URI. |
| or `MONGODB_URI` | `mongodb://…/?replicaSet=rs0&tls=true&…` | **Your own MongoDB**, together with `COMPOSE_PROFILES` without `bundled-mongo`. [16](16-EXTERNAL-DATABASES.md) |

For a bank, add the settings in
[17-ENVIRONMENT › A bank baseline](17-ENVIRONMENT.md#a-bank-baseline):
`SESSION_TTL_HOURS=12`, `SWAGGER_ENABLED=false`, `AGENT_EXECUTOR=off`,
`NODE_EXTRA_CA_CERTS`, metrics with a token.

---

## Optional services: profiles

Compose decides which optional services run from `COMPOSE_PROFILES` in `.env`:

| Profile | Service | Use it when |
| --- | --- | --- |
| `bundled-mongo` | MongoDB 7 beside the application | You do not bring your own database. The default in `.env.example`. |
| `import-worker` | The Jira import worker | You are landing a large Jira site backup. Requires `WORKER_ROLE=api`. |

Comma-separated, e.g. `COMPOSE_PROFILES=bundled-mongo,import-worker`; empty runs
neither. The `migrate` service always runs, once, before the application. On
Helm the same choices are `worker.enabled` and — always — your own MongoDB.

---

## Trusting your CA

TaskSense makes outbound TLS connections to MongoDB, the SMTP relay, the OIDC
provider, object storage and the model gateway. For any of them with a
certificate from your own CA:

**Compose:**

```bash
cat bank-root-ca.pem bank-issuing-ca.pem > compose/certs/bank-ca.pem    # one bundle, several CAs
```

```dotenv
NODE_EXTRA_CA_CERTS=/certs/bank-ca.pem
MONGODB_URI=mongodb://…&tls=true&tlsCAFile=/certs/bank-ca.pem   # MongoDB names the file itself
```

`compose/certs/` is mounted read-only at `/certs` in every container; the
paths in `.env` are the paths **inside** the container. `preflight.sh` checks
the files exist.

**Helm:** provide the bundle through the chart's `certs` values (an existing
ConfigMap or Secret, or inline files); it is mounted at `/certs` and
`certs.caBundle` sets `NODE_EXTRA_CA_CERTS`. See
[02-INSTALL-KUBERNETES](02-INSTALL-KUBERNETES.md).

The **LDAP** CA is the exception: it is pasted as PEM text per directory in
Admin → Authentication, with no file and no restart.

Certificates are public; private keys do not belong in `certs/`. TLS for the
address users type is terminated by your reverse proxy, not by TaskSense.

---

## Changing a setting

```bash
${EDITOR:-vi} compose/.env
./scripts/preflight.sh
docker compose -f compose/docker-compose.yml up -d
curl -fsS http://127.0.0.1:3000/api/v1/health
```

Expected: `preflight passed`; Compose recreates only the containers whose
configuration changed; the health check answers `"status":"ok"` within about a
minute. Sessions survive the restart; open live-update streams reconnect on
their own.

On Helm: change the values or the Secret, then
`helm upgrade tasksense oci://ghcr.io/yurdtech/charts/tasksense --version <installed version> -n tasksense -f my-values.yaml`.

Settings that deserve care:

- **`STORAGE_SECRET`** — changing it makes every stored credential unreadable:
  LDAP bind passwords, SMTP, storage, model providers. They must be re-entered.
  There is no re-encryption tool.
- **`APP_URL`** — changing it breaks OIDC until the redirect URI at your IdP is
  updated to match, and changes every link in e-mails already sent.
- **`MONGO_PASSWORD`** — only applied when the bundled database volume is first
  created. Changing it in `.env` afterwards locks the application out
  ([10-TROUBLESHOOTING](10-TROUBLESHOOTING.md#authentication-failed-with-the-right-password-in-env)).
- **`COMPOSE_PROFILES` / `MONGODB_URI`** — switching between the bundled and an
  external database does not move the data; restore a backup
  ([16-EXTERNAL-DATABASES](16-EXTERNAL-DATABASES.md#moving-from-the-bundled-database-to-yours)).

---

## Refused on-premise

`DEPLOYMENT_MODE=onprem` and `NODE_ENV=production` are set by the stack. Together
they enable the strict configuration contract, disable the demo sign-in, remove
the seed-reset endpoint and turn on the strict security headers. A configuration
copied from a hosted setup fails loudly instead of quietly reaching a cloud
service — `AUTH_DEMO_LOGIN`, `GOOGLE_CLIENT_ID`, `STRIPE_*`, `RESEND_API_KEY` and
the localhost MongoDB default are rejected at startup.
[17-ENVIRONMENT › Refused on-premise](17-ENVIRONMENT.md#15-refused-on-premise)
