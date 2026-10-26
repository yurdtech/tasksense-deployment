# Monitoring

Three feeds: **metrics** for Prometheus, **health endpoints** for probes and
uptime checks, and **structured logs** for your SIEM. Ready-made alert rules
are in [`examples/prometheus-alerts.yaml`](../examples/prometheus-alerts.yaml).

---

## Metrics

### 1. Turn them on

`GET /api/v1/metrics`, Prometheus text format, behind its own bearer token.

```dotenv
METRICS_ENABLED=1
METRICS_TOKEN=<openssl rand -hex 32>
```

Apply with `docker compose -f compose/docker-compose.yml up -d`. On Kubernetes,
enable metrics in your values and put `METRICS_TOKEN` in the Secret; with
`metrics.serviceMonitor.enabled` the chart wires the token into a
ServiceMonitor for the Prometheus Operator.

The endpoint answers **404** while either setting is missing and **403** to a
wrong token. It is behind a token because the gauges report seat usage, user
count and licence expiry — an inventory of the installation.

### 2. Check it

```bash
curl -s -H "Authorization: Bearer $METRICS_TOKEN" http://127.0.0.1:3000/api/v1/metrics | head -3
```

Expected:

```
# HELP tasksense_http_requests_total Total HTTP requests handled.
# TYPE tasksense_http_requests_total counter
tasksense_http_requests_total{method="GET",route="…",status="200"} 42
```

### 3. Scrape it

The application listens on loopback, so a Prometheus on another host scrapes
through your reverse proxy. Allow `/api/v1/metrics` there from the monitoring
segment only, if your policy wants a second fence besides the token.

```yaml
# prometheus.yml
scrape_configs:
  - job_name: tasksense
    scheme: https
    metrics_path: /api/v1/metrics
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/secrets/tasksense-metrics-token
    tls_config:
      ca_file: /etc/prometheus/corp-ca.pem
    static_configs:
      - targets: ["tasksense.corp.internal"]
```

Expected: the target is `UP` on Prometheus's *Targets* page within a minute.

Only the **API** exports metrics. The import worker has no HTTP listener; watch
it through its container's restarts and its log.

### What is exposed

| Metric | Type | |
| --- | --- | --- |
| `tasksense_http_requests_total{method,route,status}` | counter | `route` is the pattern (`/tasks/:id`), never the concrete URL — labelling by URL would mint a series per task |
| `tasksense_http_request_duration_seconds{method,route}` | histogram | Buckets 5 ms – 10 s. The two live-update streams count their whole connection time — exclude them from latency queries |
| `tasksense_event_loop_lag_p50_seconds`, `…_p99_seconds`, `…_max_seconds` | gauge | Event-loop delay since the previous scrape. High p99 means the one API process is blocked and every user waits |
| `tasksense_event_loop_lag_ms` | gauge | Deprecated alias of the p99, in ms |
| `tasksense_process_rss_bytes`, `tasksense_process_heap_used_bytes` | gauge | Memory of the API process — compare with the container limit and `APP_HEAP_MB` |
| `tasksense_mongo_up` | gauge | 1 when MongoDB answered the scrape's ping |
| `tasksense_mongo_operation_seconds` | histogram | Time one operation held its connection: round trip plus server time |
| `tasksense_mongo_pool_wait_seconds` | histogram | Time waiting for a pooled connection |
| `tasksense_mongo_connections_in_use` | gauge | Connections checked out now |
| `tasksense_mongo_pool_checkouts_total` | counter | |
| `tasksense_mongo_pool_checkout_failures_total{reason}` | counter | `reason="timeout"` means the pool was exhausted |
| `tasksense_mongo_pool_cleared_total` | counter | Pool resets — network errors and replica-set failovers |
| `tasksense_mongo_connections_created_total`, `…_closed_total` | counter | |
| `tasksense_mongo_command_duration_seconds{command}`, `tasksense_mongo_command_failures_total{command}` | histogram, counter | Only with `MONGODB_COMMAND_MONITORING=1` — costs CPU, for diagnosis |
| `tasksense_agent_runs_total{outcome}` | counter | Only meaningful with the AI features on |
| `tasksense_users`, `tasksense_workspaces` | gauge | |
| `tasksense_seats_limit` | gauge | Licensed seats; 0 when unlimited |
| `tasksense_seats_used` | gauge | Suspended accounts excluded |
| `tasksense_seats_over_limit` | gauge | Seats beyond the licence; **nothing is blocked when it rises** |
| `tasksense_license_valid`, `…_expired`, `…_invalid`, `…_perpetual` | gauge | The licence state, one 0/1 gauge each |
| `tasksense_license_expires_in_days` | gauge | −1 when there is no date to count to; the gauges above say why |

Not exported by TaskSense, and used by the alert file: index and schema state
(from the health endpoint, through blackbox_exporter — below) and backup age
(from your backup job — below).

---

## Health endpoints

| Path | Answers | Use for |
| --- | --- | --- |
| `/api/v1/health/live` | The process is running. Never touches MongoDB | Kubernetes `livenessProbe` |
| `/api/v1/health/ready` | It can serve: MongoDB reachable (503 if not). Also reports `indexes` and `schema` | `readinessProbe`, uptime checks, load balancers |
| `/api/v1/health` | Same as `ready` | Compose healthcheck, scripts |
| `/api/v1/version` | Version, commit, build date | Confirming what is deployed |

A healthy answer:

```json
{"status":"ok","service":"tasksense-api","timestamp":"…","database":"up","indexes":"ready","schema":{"state":"current"}}
```

| Field | Values | Meaning |
| --- | --- | --- |
| `indexes` | `ready` · `building` · `degraded` | `building`: large indexes still building in the background after an upgrade or restore — queries needing them are slow until done. `degraded`: an index failed to build; the log names it. Neither fails the probe |
| `schema.state` | `current` · `ahead` | `ahead`: this version runs on a database a **newer** release migrated (an application-only rollback). It keeps serving; finish the rollback ([08-UPGRADE](08-UPGRADE.md#rolling-back)) |

> Point a Kubernetes `livenessProbe` at `/health/live`, never at `/health` or
> `/health/ready`: those fail while MongoDB fails over, and a liveness failure
> restarts the pod — the one moment when that makes the outage longer.

### Index and schema state, through blackbox_exporter

TaskSense has no metric for these; they are in the health response. Probe it
with [blackbox_exporter](https://github.com/prometheus/blackbox_exporter):

```yaml
# blackbox.yml
modules:
  tasksense_ready:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: [200]
      fail_if_body_not_matches_regexp: ['"indexes":"ready"']
      tls_config:
        ca_file: /etc/blackbox/corp-ca.pem
  tasksense_schema:
    prober: http
    timeout: 5s
    http:
      valid_status_codes: [200]
      fail_if_body_not_matches_regexp: ['"schema":\{"state":"current"\}']
      tls_config:
        ca_file: /etc/blackbox/corp-ca.pem
```

```yaml
# prometheus.yml — one job per module; the names match examples/prometheus-alerts.yaml
scrape_configs:
  - job_name: tasksense-health
    metrics_path: /probe
    params: { module: [tasksense_ready] }
    static_configs:
      - targets: ["https://tasksense.corp.internal/api/v1/health/ready"]
    relabel_configs:
      - { source_labels: [__address__], target_label: __param_target }
      - { source_labels: [__param_target], target_label: instance }
      - { target_label: __address__, replacement: "blackbox-exporter:9115" }
  - job_name: tasksense-schema
    metrics_path: /probe
    params: { module: [tasksense_schema] }
    static_configs:
      - targets: ["https://tasksense.corp.internal/api/v1/health/ready"]
    relabel_configs:
      - { source_labels: [__address__], target_label: __param_target }
      - { source_labels: [__param_target], target_label: instance }
      - { target_label: __address__, replacement: "blackbox-exporter:9115" }
```

Expected: `probe_success{job="tasksense-health"} 1` and
`probe_success{job="tasksense-schema"} 1` on a healthy installation.

### Backup age

TaskSense does not know when you last backed it up. Let the backup job say so.

**Compose**, with node_exporter's textfile collector
(`--collector.textfile.directory=/var/lib/node_exporter/textfile`): the cron
line in [07-BACKUP-DR](07-BACKUP-DR.md#2-schedule-it-off-the-host) writes, after
every **successful** run,

```
tasksense_backup_last_success_timestamp_seconds 1760580000
```

**Kubernetes:** kube-state-metrics already exports
`kube_cronjob_status_last_successful_time` for the chart's backup CronJob.

Both feed the `TaskSenseBackupTooOld` / `TaskSenseBackupCronJobTooOld` alerts
(26 hours: the 24-hour RPO plus one slow night).

---

## Alerts

`examples/prometheus-alerts.yaml` is a `PrometheusRule` for the Prometheus
Operator; on plain Prometheus, copy its `groups:` into a rules file. The ones
that matter most:

| Alert | Fires when | Works on |
| --- | --- | --- |
| **TaskSenseDown** | The metrics scrape fails for 2 min — the whole service, since the API is one process | both |
| **TaskSenseMongoDown** | `tasksense_mongo_up == 0` | both |
| **TaskSenseHealthProbeFailing** | Readiness fails, or `indexes` is not `ready`, for 5 min | both (blackbox) |
| **TaskSenseSchemaAhead** | Running on a database a newer release migrated | both (blackbox) |
| **TaskSenseErrorRate** | More than 5 % of requests are 5xx | both |
| **TaskSenseSlowRequests** | p95 above 1 s, streams and imports excluded | both |
| **TaskSenseEventLoopLag** | Event-loop p99 above 0.5 s for 5 min | both |
| **TaskSenseMongoPoolExhausted** | Requests timed out waiting for a connection | both |
| **TaskSenseBackupTooOld** / **…CronJobTooOld** | No successful backup for 26 h | Compose / Kubernetes |
| **TaskSenseLicenceExpiring** / **Expired** / **Invalid** | 30 days out; lapsed; unverifiable | both |
| **TaskSenseSeatsOverLimit** | Informational — nobody is turned away on-premise | both |
| **TaskSenseRestarting**, **TaskSenseDataVolumeFilling** | Kubernetes only (kube-state-metrics, kubelet) | Kubernetes |

On Compose, watch the data volume's disk with your node exporter
(`node_filesystem_avail_bytes` for Docker's data root), and container restarts
with cAdvisor if you run it — Docker itself does not restart a container whose
healthcheck fails, so alert on **TaskSenseDown**.

The thresholds are deliberately loose. Tighten them once you know what normal
looks like on your hardware.

Validate the rules before loading them:

```bash
promtool check rules tasksense-rules.yaml
```

Expected: `SUCCESS: 18 rules found`.

---

## Logs

`LOG_FORMAT=json` (the on-premise default) writes one JSON object per line to
stdout:

```json
{"ts":"2026-10-16T10:20:32.019Z","level":"log","ctx":"HTTP","msg":"GET /api/v1/tasks 200 14ms","requestId":"3f2a…","workspaceId":"w-1"}
```

| Field | |
| --- | --- |
| `ts`, `level`, `ctx`, `msg` | Timestamp, severity, subsystem, message |
| `requestId` | Also returned as the `X-Request-Id` response header. `examples/nginx.conf` sends the proxy's own request id upstream, so the proxy's access log and the application log share it |
| `workspaceId` | The tenant (on-premise there is one) |

Requests slower than one second are logged at `warn` with `(slow)` at the end.

**Shipping them.** Compose writes container logs with Docker's `json-file`
driver, rotated at 50 MB × 5 per container. Collect them with whatever already
reads container logs on your hosts — Fluent Bit, Vector, Filebeat, a Splunk
forwarder — from `/var/lib/docker/containers/*/*-json.log`. On Kubernetes, your
cluster's log agent picks up stdout. Nothing to configure on our side.

### What is never logged

Passwords, session tokens, API keys, personal access tokens, request bodies,
or complete model prompts. The short-lived `?ticket=` the live-update streams
and video playback use is masked, as are the path tokens of the inbound-mail,
invite and automation-hook routes. The MongoDB connection string is logged with
its password replaced by `***`.

Configure your **reverse proxy** the same way: `examples/nginx.conf` logs the
path without the query string and masks those path tokens.

### Audit

Every change to a task, document, epic, sprint, release, user, setting and the
other administered objects is recorded — actor, object, field, old value, new
value, time — in the `history` collection in MongoDB, readable in
Admin → Audit log. Administrative actions are included: role changes,
suspensions, the security policy, sign-in settings, sessions revoked, tokens
revoked.

Audit records are **not** written to the log stream. To get them into a SIEM:

- read the `history` collection periodically (by `at` timestamp) with a
  read-only database account, or
- register an outgoing webhook (Admin → Webhooks): every audit event is POSTed,
  HMAC-SHA256-signed, to a receiver you run.

Not recorded today: successful and failed sign-ins, sign-outs, and the client
IP address or user agent of a change. Correlate with the application's request
log (`POST /api/v1/auth/login` → 401) and your proxy's access log —
[06-SECURITY](06-SECURITY.md#known-limitations).

---

## What to watch, in order

1. **`tasksense_mongo_up`** — nothing works without it.
2. **Backup age** — the failure that is silent until the day you need it.
3. **`tasksense_license_expires_in_days`** — silent until it is not.
4. **Event-loop lag p99 and p95 request duration** — the first sign of an
   undersized database cache or a landing in the wrong process
   ([11-SIZING](11-SIZING.md)).
5. **Disk on the data volume** — attachments and staged uploads grow; a Jira
   import needs twice the backup's size free.
6. **Restarts** — steady restarts are usually memory; the log line before each
   one says so.
