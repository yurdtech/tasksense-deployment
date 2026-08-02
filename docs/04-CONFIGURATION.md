# Configuration reference

Every setting the application reads, what it does, and what happens if you get
it wrong.

Settings live in `compose/.env` (Compose) or `values.yaml` (Helm). The whole file
is validated at startup: an invalid configuration produces a readable error
listing **every** problem at once, so one edit and one restart fixes it.

```
Invalid environment configuration:
  - NODE_ENV: must be "production" when DEPLOYMENT_MODE=onprem
  - STORAGE_SECRET: is required when DEPLOYMENT_MODE=onprem — without it
    stored S3 and LLM credentials are encrypted with a public development key
```

---

## Required

The application will not start without these.

| Setting | Example | Notes |
| --- | --- | --- |
| `TASKSENSE_VERSION` | `1.0.0` | Pin it. `latest` means a restart can move you to a different version. |
| `APP_URL` | `https://tasksense.bank.internal` | What users type. Sign-in redirects are built from it. |
| `STORAGE_SECRET` | `openssl rand -base64 32` | Min 32 chars. Encrypts stored credentials. **Not recoverable — back it up.** |
| `MONGO_USER` / `MONGO_PASSWORD` | `tasksense` / `openssl rand -hex 24` | The database account. **Hex, not base64.** The password is substituted into a connection string, and a URI reads `/ : @ ? # [ ] %` as structure — one of those ends the password early and the driver rejects the whole URI with *Password contains unescaped characters*, before connecting to anything. |
| `FIRST_ADMIN_EMAIL` | `admin@bank.internal` | First install only. Becomes the administrator of the new workspace. |

`DEPLOYMENT_MODE=onprem` and `NODE_ENV=production` are set by the compose file
and should not be overridden. Together they enable the strict configuration
contract, disable the demo sign-in, remove the seed-reset endpoint and turn on
the strict security headers.

---

## Network

| Setting | Default | Notes |
| --- | --- | --- |
| `BIND_ADDRESS` | `127.0.0.1` | Which host interface the container publishes on. Keep loopback unless the reverse proxy is on another machine. |
| `HTTP_PORT` | `3000` | Host port. |
| `CORS_ALLOWED_ORIGINS` | — | Browser origins allowed to call the API. Normally the same as `APP_URL`. |

---

## Sign-in

Full walkthroughs in [05-IDENTITY](05-IDENTITY.md).

### Active Directory / LDAP

All four of URL, bind DN, bind password and base DN are needed; a partial
configuration disables directory sign-in rather than half-enabling it.

| Setting | Default | Notes |
| --- | --- | --- |
| `LDAP_URL` | — | Must be `ldaps://`. Plain `ldap://` is refused on-premise: it puts every password on the wire. |
| `LDAP_BIND_DN` | — | Read-only service account. |
| `LDAP_BIND_PASSWORD` | — | |
| `LDAP_BASE_DN` | — | Subtree to search. |
| `LDAP_USER_FILTER` | `(sAMAccountName={{username}})` | `{{username}}` is replaced, escaped. |
| `LDAP_TLS_CA` | — | PEM path inside the container. Mount it. |
| `LDAP_TLS_REJECT_UNAUTHORIZED` | `true` | Setting it false accepts any certificate and defeats `ldaps`. Lab use only. |
| `LDAP_ATTR_EMAIL` | `mail` | Email is how a directory identity joins a local account. |
| `LDAP_ATTR_NAME` | `displayName` | |
| `LDAP_ATTR_GROUPS` | `memberOf` | If your directory does not maintain it, a reverse group search is used automatically. |
| `LDAP_GROUP_MAP` | — | `<group DN>=<role>` pairs, `;` separated. Re-read at every sign-in. |
| `LDAP_LABEL` | `Sign in with your directory account` | Form heading. |

### OIDC

| Setting | Notes |
| --- | --- |
| `OIDC_ISSUER` | Discovery is read from `<issuer>/.well-known/openid-configuration`. |
| `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` | From your provider. |
| `OIDC_REDIRECT_URI` | Must match what you registered, exactly. Defaults to `<APP_URL>/api/v1/auth/oidc/callback`. |
| `OIDC_LABEL` | Button text. |

### Sessions and passwords

| Setting | Default | Notes |
| --- | --- | --- |
| `SESSION_TTL_HOURS` | `0` (never expires) | Sessions issued before you set this are not retroactively expired. |
| `OWNER_EMAILS` | — | Comma-separated. Always granted admin; use it to recover from a lockout. |

The password minimum is set in Admin → Access control, not here, because it is a
workspace policy rather than a deployment setting.

---

## Database

| Setting | Default | Notes |
| --- | --- | --- |
| `MONGODB_URI` | the bundled container | Set it to use a cluster you already run; the bundled database is then not started at all, and `MONGO_USER`/`MONGO_PASSWORD` are unused. TLS and replica-set options go in the URI: `?tls=true&tlsCAFile=/certs/ca.pem&replicaSet=rs0&authSource=admin`. Percent-encode `/ : @ ? # [ ] %` in the password. |
| `MONGODB_DB` | `tasksense` | |
| `MONGODB_TIMEOUT_MS` | `5000` | Initial connection timeout. |

MongoDB is the only data store and there is **no fallback**: an instance that
cannot reach it exits at startup rather than serving an empty workspace that
looks like data loss.

---

## Files

| Setting | Default | Notes |
| --- | --- | --- |
| `STORAGE_LOCAL_ROOT` | `/app/api/data/uploads` | On the data volume. |
| `STORAGE_MAX_FILE_MB` | `25` | Also set the body limit on your reverse proxy, or large uploads fail before arriving. |

For MinIO, WebDAV or S3, configure the provider in Admin → Storage rather than
here — the credentials are then encrypted at rest with `STORAGE_SECRET`.

---

## Email

Unset, notifications still appear in the application; only email is skipped.

| Setting | Default |
| --- | --- |
| `SMTP_HOST` | — |
| `SMTP_PORT` | `587` |
| `SMTP_SECURE` | `false` (TLS on connect) |
| `SMTP_USER` / `SMTP_PASS` | — (omitted if either is missing) |
| `EMAIL_FROM` | — |

---

## Observability

| Setting | Default (on-premise) | Notes |
| --- | --- | --- |
| `LOG_FORMAT` | `json` | One object per line, for a SIEM. `text` is readable but not parseable. |
| `LOG_LEVEL` | `log` | `verbose`, `debug`, `log`, `warn`, `error`, `fatal`. |
| `METRICS_ENABLED` | off | Prometheus at `/api/v1/metrics`. |
| `METRICS_TOKEN` | — | Required with the above. Without it the endpoint stays off and returns 404. |

Health endpoints — wire these to the right probe:

| Path | Answers | Use for |
| --- | --- | --- |
| `/api/v1/health/live` | Is the process running? | `livenessProbe` |
| `/api/v1/health/ready` | Can it serve requests (database reachable)? | `readinessProbe` |
| `/api/v1/health` | Same as `ready` | Compose healthcheck, scripts |

Pointing `livenessProbe` at `/health` or `/health/ready` restarts every replica
during a database failover — the one moment when that lengthens the outage.

---

## Egress

| Setting | Default | Notes |
| --- | --- | --- |
| `EGRESS_ALLOWLIST` | empty | Comma-separated hosts the server may call, beyond those named by other settings. |

Everything else is refused, including private and link-local addresses, so an
admin-configured webhook URL cannot be used to probe your network. Add a
self-hosted GitLab or Jira here if you want the integrations to reach them.

---

## AI features

Off unless configured. Connect an OpenAI-compatible endpoint **inside your
network** from Admin → Agents → Providers. See [12-AI-MODELS](12-AI-MODELS.md).

| Setting | Default | Notes |
| --- | --- | --- |
| `AGENT_EXECUTOR` | `off` | Runs model-authored commands in a sandboxed workspace. Review what it does before enabling. |
| `AGENT_DISPATCHER` | `off` | The background scheduler. Leave off if you are not using AI features. |
| `AGENT_MAX_CONCURRENT` | `2` | Parallel agent runs. |
| `AGENT_TICK_MS` | `15000` | Scheduler interval. |

---

## Operations

| Setting | Default | Notes |
| --- | --- | --- |
| `LICENSE_KEY` | — | Verified offline. Without it: 10 accounts, 500 automation runs a month. Expiry never blocks data access, and exceeding the seats never blocks sign-in — see [14-LICENSING](14-LICENSING.md). |
| `BACKUP_DIR` | `/app/api/data/backups` | In-application snapshots. Keep it on the data volume, or a container rebuild discards them. |
| `SWAGGER_ENABLED` | off | The interactive API browser. It publishes the whole API surface. |
| `APP_CPU_LIMIT` / `APP_MEMORY_LIMIT` | `2` / `2g` | |
| `MONGO_CPU_LIMIT` / `MONGO_MEMORY_LIMIT` | `2` / `2g` | |

---

## Refused on-premise

These are rejected at startup rather than ignored, so a copied-in configuration
file fails loudly instead of quietly doing something you did not intend:

| Setting | Why |
| --- | --- |
| `NODE_ENV` other than `production` | Gates the seed-reset endpoint and the demo sign-in. |
| `AUTH_DEMO_LOGIN` | A password-less sign-in. |
| `GOOGLE_CLIENT_ID` | Verifies tokens against Google's servers. Use OIDC or LDAP. |
| `STRIPE_*` | Entitlement comes from `LICENSE_KEY`, verified offline. |
| `MONGODB_URI` left at the localhost development default | Almost always a copied file rather than an intent. |

---

## Changing a setting

```bash
${EDITOR:-vi} compose/.env
docker compose -f compose/docker-compose.yml up -d
curl -fsS http://127.0.0.1:3000/api/v1/health
```

Restarting takes a few seconds. Sessions survive it.

Two settings deserve care:

- **`STORAGE_SECRET`** — changing it makes previously stored provider
  credentials unreadable. They must be re-entered in Admin → Storage.
- **`APP_URL`** — changing it breaks SSO until you update the redirect URI at
  your identity provider to match.
