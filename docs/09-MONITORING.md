# Monitoring

Two feeds: metrics for Prometheus, and structured logs for your SIEM.

---

## Metrics

`GET /api/v1/metrics`, Prometheus text format, behind a bearer token.

```bash
METRICS_ENABLED=1
METRICS_TOKEN=$(openssl rand -hex 32)
```

Both are required — the endpoint 404s without the token rather than 403s, so a
scanner cannot tell it exists. It is behind a token because the gauges report
seat usage, user count and licence expiry: an inventory of the installation, not
something to leave readable by anything that can reach the port.

```bash
curl -H "Authorization: Bearer $METRICS_TOKEN" \
  https://tasksense.bank.internal/api/v1/metrics
```

On Kubernetes, set `metrics.serviceMonitor.enabled` and the chart wires the
token for you.

### What is exposed

| Metric | Type | |
|---|---|---|
| `tasksense_http_requests_total{method,route,status}` | counter | `route` is the pattern (`/tasks/:id`), never the concrete URL — labelling by URL would mint a series per task id |
| `tasksense_http_request_duration_seconds` | histogram | |
| `tasksense_agent_runs_total{outcome}` | counter | Only meaningful with the AI features on |
| `tasksense_mongo_up` | gauge | 1 when the last check reached the database |
| `tasksense_users`, `tasksense_workspaces` | gauge | |
| `tasksense_seats_limit` | gauge | 0 when unlimited |
| `tasksense_license_valid` | gauge | |
| `tasksense_license_expires_in_days` | gauge | −1 when perpetual or absent |

Counters are per process. With several replicas Prometheus scrapes each and sums
them, which is how it is meant to work — but remember it when reading a single
instance's numbers.

### Alerts

`examples/prometheus-alerts.yaml` has these ready to load. The four that matter:

| Alert | Why |
|---|---|
| **TaskSenseDown** | No instance is being scraped |
| **TaskSenseMongoDown** | `tasksense_mongo_up == 0`. The only data store; the application can serve nothing |
| **TaskSenseLicenceExpiring** | 30 days out. An expired licence silently drops to free-tier limits, and the first anyone hears is a user who cannot be invited |
| **TaskSenseSeatsNearLimit** | Above 90% of the cap, for the same reason |

Latency and error-rate alerts are in the same file, deliberately loose — tighten
them once you know what normal looks like on your hardware.

---

## Logs

`LOG_FORMAT=json` (the on-premise default) emits one object per line on stdout:

```json
{"ts":"2026-08-01T10:20:32.019Z","level":"log","ctx":"HTTP",
 "msg":"GET /api/v1/tasks 200 14ms [3f2a…]","requestId":"3f2a…","workspaceId":"w-demo"}
```

Collect it with whatever already reads container logs — Fluent Bit, Vector,
Filebeat, `journald`. Nothing to configure on our side.

| Field | |
|---|---|
| `ts`, `level`, `ctx`, `msg` | Timestamp, severity, subsystem, message |
| `requestId` | Also returned as `X-Request-Id`. One user-reported failure traces through every line it produced, without guessing at timestamps |
| `workspaceId` | Scope a query to one tenant |
| `channel: "audit"` | Marks a line the compliance team must retain |

### What is never logged

Passwords, session tokens, API keys, personal access tokens, sign-in request
bodies, and complete model prompts. A session token arriving in a query string —
the live-update stream, which cannot send headers — is redacted before the line
is written. User email addresses appear only in audit records, where they are the
point.

### Audit

Every change to a task, document, epic or attachment is recorded with actor,
entity, field, old value and new value, in the database. Readable and
exportable from Admin → Audit log, and mirrored to the log stream under
`channel: "audit"` so a SIEM sees it without a second integration.

---

## What to watch, in order

1. **`tasksense_mongo_up`** — nothing works without it.
2. **`tasksense_license_expires_in_days`** — the failure that is silent until it
   is not.
3. **p95 request duration** — the first sign of an undersized database cache;
   see [11-SIZING](11-SIZING.md).
4. **Disk on the uploads volume** — attachments grow without bound unless you
   cap or offload them.
5. **Restart count** — a pod restarting steadily is usually memory pressure, and
   the log says so on the line before the restart.

---

## Health endpoints

Not metrics, but the other thing to point a monitor at:

| Path | Answers |
|---|---|
| `/api/v1/health/live` | Is the process running? Never touches MongoDB |
| `/api/v1/health/ready` | Can this instance serve? Pings MongoDB |
| `/api/v1/version` | Which build is this? |

An external uptime check should use `/health/ready`. A Kubernetes
`livenessProbe` must use `/health/live` — see
[02-INSTALL-KUBERNETES](02-INSTALL-KUBERNETES.md#the-probes) for why the
difference matters.
