# Scaling and high availability

The short version, stated plainly so it is not discovered during an audit:

- **Without Redis, the TaskSense API is one process** — exactly as before.
  That is the default on Compose and Helm, and it is the right layout up to
  profile L in [11-SIZING](11-SIZING.md). It scales **vertically**.
- **With Redis configured, the API can run as 2 to 20 processes** behind a
  round-robin load balancer, without sticky sessions. There is no mode switch:
  Redis is used when it is configured and not at all otherwise.
- **Background jobs run once on every topology.** With one process there is
  nothing to share; with several, every scheduler and sweep takes a lease in
  MongoDB first, so a second process never runs the same pass.
- **Configured but unreachable Redis is an outage, not a fallback.** Readiness
  fails until Redis is back; the API never quietly drops to per-process memory.
- Several API processes need **shared storage** — a `ReadWriteMany` data volume
  on Kubernetes — and should run beside the **import worker**.
- **Upgrades** stop every API process first by default (`Recreate`). Rolling
  updates are opt-in, Kubernetes only, and only for releases marked
  rolling-safe.

---

## Two topologies

| | One process (no Redis) | Several processes (Redis) |
| --- | --- | --- |
| Compose | the `app` service, container `tasksense-app` | the `replicas` profile: `APP_REPLICAS` app containers (`tasksense-app-1`, `-2`, …) behind a bundled load balancer, `tasksense-lb`, with the bundled Redis (`bundled-redis`) or yours |
| Helm | `replicaCount: 1` (the default) | `replicaCount: 2`–`20`, or `autoscaling.enabled: true` |
| Also required | nothing | Redis; a `ReadWriteMany` data volume (Helm); the import worker (Compose — `preflight.sh` refuses `replicas` without `import-worker`) |
| Recommended | | `worker.enabled: true` (Helm); Redis with Sentinel; pods spread over nodes |
| Rate-limit counters | in memory | in Redis (`RATE_LIMIT_STORE` defaults to `redis`) |
| MongoDB pool per process | 100 | 50 (Helm `config.mongodbMaxPoolSize`, Compose `MONGODB_MAX_POOL_SIZE`; an explicit value wins); see [the connection budget](11-SIZING.md#the-mongodb-connection-budget) |
| Upgrade | stop, migrate, start | the same by default; `strategy.type: RollingUpdate` on Helm for rolling-safe releases |

Nothing changes for an installation that configures no Redis: one process,
in-memory state, `Recreate` upgrades, and the chart and `preflight.sh` still
refuse a second copy without Redis.

---

## What the processes share, and how

| What | One process | Several processes |
| --- | --- | --- |
| Schedulers and sweeps — agent dispatcher, automation schedules, due-date sweep, digests, nightly snapshots, metric snapshots, retention | in-process timers, as before | a lease in MongoDB (collection `jobLeases`): one process runs each pass; when its holder stops (shut down, killed, its node lost), another takes the job over — at once when the holder has left the Redis heartbeat list for 20 s, otherwise when the lease runs out |
| Live updates (server-sent events) | in-process | each process keeps the streams of the browsers connected to it; a change made through any process is announced to all of them over Redis pub/sub, and each tells its own browsers |
| Cache invalidations (workspace settings, sign-in settings, …) | in-process | over Redis pub/sub. After a lost connection to Redis every process flushes its caches; `SETTINGS_CACHE_TTL_MS` bounds how late a lost invalidation is noticed (at most 5 s with Redis) |
| `?ticket=` credentials for the streams and video | in memory | in Redis, encrypted (AES-256-GCM) under a key derived from the ticket itself — the contents of Redis alone yield no usable credential |
| Sign-in lockout counts | in memory | in Redis |
| Status of started-then-polled jobs (exports, imports, previews) | in memory | in Redis |
| Rate-limit counters | in memory (`RATE_LIMIT_STORE=memory`) | in Redis (`RATE_LIMIT_STORE=redis`, the default when Redis is configured) |
| Jira backup landings | a lease in MongoDB, in the worker or the API | the same |

The job leases are taken only where Redis is configured — where there can be
several processes. There is nothing to configure, and
`tasksense_singleton_job_runs_total{job}` shows which process ran what
([09-MONITORING](09-MONITORING.md)).

Behind the lease, what a repeated pass would show twice is taken once: a
due-date reminder, a filter digest, a scheduled request, an agent
decomposition and a workspace's backup of the day are each claimed in MongoDB
(collection `jobClaims`, or a stamp on the schedule or subscription) before
the work starts, so even a process that lost its lease mid-pass — a long pause,
a node that came back — sends, raises or writes nothing the first one already
did. Another process takes a claim over only when its holder has dropped off
the heartbeat list. A process that stopped mid-job therefore holds nothing up
for longer than the heartbeat window.

`RATE_LIMIT_STORE=memory` beside Redis is allowed but wrong for several
processes: each counts only what reached it, so every limit is N times higher.
The application logs a warning; the chart and `preflight.sh` refuse it with
more than one API process. `mongo` shares the counters too, at one database
round trip per throttled request.

---

## Redis

### What TaskSense needs from it

| | Requirement |
| --- | --- |
| Version | **Redis 6 or newer recommended** — ACL users and native TLS arrived in 6. |
| Availability | **Sentinel recommended** (`REDIS_SENTINELS` + `REDIS_SENTINEL_NAME`): a single Redis is a single point of failure for every API process. Redis Cluster is supported (`REDIS_CLUSTER_NODES`). |
| Eviction | **None, ever.** `maxmemory-policy noeviction`. A ticket or a lockout count evicted under memory pressure is a sign-in that fails or a limit that resets. On a Redis shared with applications that need an eviction policy, give TaskSense its own instead — a separate database number or `REDIS_KEY_PREFIX` keeps the names apart but does not exempt them from eviction. |
| Persistence | Not needed. What TaskSense keeps there is short-lived — tickets, counters, job status, messages in flight — and the bundled Redis runs without RDB or AOF. |
| TLS | `rediss://` in `REDIS_URL`, or `REDIS_TLS=true` with sentinels / cluster nodes. The CA is `NODE_EXTRA_CA_CERTS`, the same bundle MongoDB's TLS trusts. |
| Account | An ACL user (`REDIS_USERNAME` / `REDIS_PASSWORD`, or `user:password@` in the URL) with read and write commands on keys under the prefix (`~tasksense:*`), `PUBLISH` / `SUBSCRIBE` on channels under it (`&tasksense:*`), `EVAL` / `EVALSHA`, `PING` and `INFO`. No administrative commands. A missing permission shows as a `NOPERM` error in the API's log. |
| Names | Every key and channel starts with `REDIS_KEY_PREFIX` (default `tasksense:`), so one Redis can serve a test installation beside production without either hearing the other. |
| Size | Not measured yet. The keys are small and expire on their own; start with 1 GB of `maxmemory` and watch `used_memory`. |

External Redis — connection strings, Sentinel, TLS, the Kubernetes values:
[16-EXTERNAL-DATABASES](16-EXTERNAL-DATABASES.md#redis).

### When Redis is down

- `/api/v1/health/ready` answers **503** in every API process:
  `{"status":"error","service":"tasksense-api","database":"up","redis":"down"}`.
  Kubernetes takes the pods out of the Service, the bundled load balancer
  takes the containers out of rotation, and users get an error page until
  Redis is back. Liveness (`/api/v1/health/live`) does not look at Redis or
  MongoDB, so nothing is restarted.
- There is **no fallback to memory**. With several processes that would split
  the installation into processes that each believe something different about
  who is signed in, which tickets exist and what changed.
- Commands wait at most 2 s, so a hanging Redis costs a request seconds, not
  its whole deadline. The connection retries on its own; when it returns,
  every process flushes its caches and readiness passes again.
- `tasksense_redis_up` is `0` and the `TaskSenseRedisDown` alert fires after
  2 minutes ([09-MONITORING](09-MONITORING.md#alerts)).

A Sentinel failover is an outage of exactly this kind for as long as the
failover takes (Sentinel's `down-after-milliseconds` plus the election).

---

## Shared storage

Every API process must see the same files:

| Path | What |
| --- | --- |
| `/app/api/data/uploads` (`STORAGE_LOCAL_ROOT`) | attachments, unless they are on object storage (Admin → Storage) |
| `/app/api/data/backups` (`BACKUP_DIR`) | the application's own nightly per-workspace snapshots |
| `/app/api/data/tmp` (`TMPDIR`) | upload staging: a Jira backup is received by one process and landed by another |

- **Kubernetes:** `persistence.accessMode: ReadWriteMany` — NFS, CephFS / ODF,
  Azure Files, EFS. The chart refuses more than one API process, autoscaling,
  a PodDisruptionBudget or `RollingUpdate` without it. Object storage for
  attachments does not remove the requirement: the snapshots and the staging
  area stay on the volume.
- **Compose:** the replicas run on one host and share the `tasksense-app-data`
  volume. Nothing to do.

---

## The import worker

Landing a large Jira site backup — parsing a multi-gigabyte `entities.xml` and
writing hundreds of thousands of issues — is the heaviest thing TaskSense does.
In an API process it shares one heap with every user. The import worker is a
second process from the **same image** (`node dist/worker.js`) that does that
and nothing else.

| | API (`WORKER_ROLE=api`) | Worker (`WORKER_ROLE=worker`) |
| --- | --- | --- |
| Serves users, HTTP, the live feed | yes | no — no listener, no port |
| Schedulers (dispatcher, automation, digests, snapshots) | yes, under the job leases | no |
| Jira backup landings | no | yes |
| Default memory | 2 GB, heap 1536 MB | 6 GB, heap 4096 MB |

How it behaves:

- A landing is held under a **lease**. If the worker dies — out of memory, a
  node drained — the lease expires, the next worker process adopts the landing
  at its last checkpoint, and the API never notices.
- Uploads are **staged on the data volume** (`TMPDIR=/app/api/data/tmp`): the
  API receives the file, the worker reads it from the same place. On
  Kubernetes that is why enabling the worker requires a `ReadWriteMany` data
  volume — the chart refuses otherwise.
- **Zero or one.** The worker is for migration-sized work, not throughput.
- **With several API processes, run it.** Without it every API pod runs
  `WORKER_ROLE=all`, and any of them can adopt a landing that takes hours, in
  the same heap that serves users. The chart's NOTES warn; on Compose the
  `replicas` profile requires `import-worker`.

Turning it on:

| | Compose (`compose/.env`) | Helm |
| --- | --- | --- |
| Enable | add `import-worker` to `COMPOSE_PROFILES` | `worker.enabled: true` |
| API role | `WORKER_ROLE=api` (`preflight.sh` enforces it) | set automatically |
| Memory | `WORKER_MEMORY_LIMIT`, `WORKER_HEAP_MB` | `worker.resources`, `worker.heapMb` |
| Shared staging | the same `tasksense-app-data` volume | `persistence.accessMode: ReadWriteMany` |

With one API process, leave it on for the migration window and turn it off
afterwards; with `WORKER_ROLE=all` (the default) the API does the occasional
small landing itself.

---

## Several API processes on Kubernetes

```yaml
replicaCount: 3                 # 2–20; or autoscaling below
redis:
  sentinels: [redis-0.redis:26379, redis-1.redis:26379, redis-2.redis:26379]
  sentinelName: mymaster
  existingSecret: tasksense-redis
  existingSecretKey: ""         # no REDIS_URL — the sentinels are the connection
  existingSecretPasswordKey: REDIS_PASSWORD
persistence:
  accessMode: ReadWriteMany
  storageClass: <an RWX class>
worker:
  enabled: true
podDisruptionBudget:
  enabled: true
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
```

What the chart enforces and adds:

- **The cap is 20.** `replicaCount` and `autoscaling.maxReplicas` above 20 are
  refused: it is the ceiling the shared state and the MongoDB connection
  budget were sized for (20 × 50 = 1 000 connections). Beyond it, talk to us
  (info@yurdtech.az).
- **Redis, and `ReadWriteMany`, or no second process.** `replicaCount > 1`,
  `autoscaling.enabled`, `podDisruptionBudget.enabled` and
  `strategy.type: RollingUpdate` are refused without both
  ([the refusal table](02-INSTALL-KUBERNETES.md#step-4--render-it-first)).
- **`REDIS_*` reach the API, the worker and the migration Job** — the worker
  publishes invalidations and live-update pings too, and the migration CLI
  validates the same configuration.
- **The MongoDB pool per process drops to 50** unless you set
  `config.mongodbMaxPoolSize`.
- **Spread.** `topologySpreadConstraints` is rendered as given; an entry
  without a `labelSelector` gets the API pods' own. `affinity` works as
  before.

### Draining: the preStop sleep

When a pod is deleted, Kubernetes removes it from the Service's endpoints and
starts shutting the container down at the same time; the ingress controller
hears about the endpoint change a moment later. A process that stopped at once
would have requests routed to it after it closed. So with more than one API process (or
`RollingUpdate`) the API container gets a **preStop `sleep`** of
`preStopSleepSeconds` (default 10): it keeps serving while the routes are
withdrawn, then receives SIGTERM and finishes in-flight requests. Open
live-update streams end and the browsers reconnect to another pod.

`terminationGracePeriodSeconds` (default 45) counts the sleep, so the chart
refuses one below `preStopSleepSeconds + 20`. `preStopSleepSeconds: 0` turns
the sleep off.

### Autoscaling and the disruption budget

| | Values | Renders |
| --- | --- | --- |
| HorizontalPodAutoscaler | `autoscaling.enabled: true`, `minReplicas` (2), `maxReplicas` (10, at most 20), `targetCPUUtilizationPercentage` (70), `targetMemoryUtilizationPercentage` (empty = off) | `autoscaling/v2` on the API Deployment, which then has no `replicas:` field — the HPA owns it, and a `helm upgrade` does not reset it |
| PodDisruptionBudget | `podDisruptionBudget.enabled: true` | `policy/v1`, `maxUnavailable: 1`: a node drain evicts one API pod at a time; on Kubernetes 1.27 and later also `unhealthyPodEvictionPolicy: AlwaysAllow` |

Utilisation targets are percentages of `resources.requests`, which the chart
sets by default. Size the MongoDB connection budget for `maxReplicas`, not for
today's count. A drain waits for each evicted pod's replacement to become
ready. A pod that is not ready serves nobody, so on Kubernetes 1.27 and later
the budget lets it be evicted regardless; on 1.25 and 1.26 (OpenShift 4.12,
4.13) that setting does not exist, and a drain waits while the budget is
exhausted — for example while Redis is down and every API pod is unready.

### Upgrades: Recreate or RollingUpdate

| | `strategy.type: Recreate` (default) | `strategy.type: RollingUpdate` (opt-in) |
| --- | --- | --- |
| What happens | the dump and the migration Job run while the old pods still serve; then every old pod stops before the first new one starts | the dump and the migration Job run first, as with Recreate; then one new pod starts (`maxSurge: 1`), becomes ready, one old pod goes (`maxUnavailable: 0`), and so on |
| Outage | a minute or two plus migrations | none, if the release is rolling-safe |
| Requires | nothing | Redis, `ReadWriteMany`, and a release marked **rolling-safe** |

During a rolling update **two releases serve side by side** for as long as it
lasts, behind one round-robin Service. A release is rolling-safe only when its
release notes say so, which means both of:

1. **Its migrations are backwards compatible.** The migration Job finishes
   before the first new pod starts, so the old release runs against the
   migrated schema for the whole rollout.
2. **Its API and the previous release's web build work with each other in
   both directions.** A browser that loaded the old interface calls new pods,
   and one that loaded the new interface calls old pods.

A release not marked rolling-safe is upgraded with `Recreate`, whatever the
values say: `helm upgrade … --set strategy.type=Recreate`
([08-UPGRADE](08-UPGRADE.md#rolling-updates-kubernetes)).

**Shared web assets.** With `RollingUpdate` the chart sets
`WEB_ASSETS_SHARED_DIR=/app/api/data/web-assets`. Each pod copies its web
build's content-hashed files there at boot and serves the directory after its
own build, so a page loaded from one release finds its scripts on a pod of the
other. Without it about half of a page's chunk requests reach a pod that does
not have them and 404 — a blank page or the error screen — until the rollout
ends. Files no release has brought along for 30 days are pruned. `Recreate`
does not need the directory.

---

## Several API processes on Docker Compose

The `replicas` profile adds `compose/docker-compose.replicas.yml` to the
stack ([01-INSTALL-COMPOSE](01-INSTALL-COMPOSE.md#several-api-processes-the-replicas-profile)):

```dotenv
COMPOSE_PROFILES=bundled-mongo,import-worker,replicas,bundled-redis
WORKER_ROLE=api
APP_REPLICAS=3
BUNDLED_REDIS_PASSWORD=<openssl rand -hex 24>
```

| Service | Container | What it does |
| --- | --- | --- |
| `app` | `tasksense-app-1` … `-N` | `APP_REPLICAS` API processes (1–20, default 3), no host port, `WORKER_ROLE=api`, `TRUST_PROXY=2` |
| `lb` | `tasksense-lb` | Caddy (`caddy:2.10-alpine`) on `BIND_ADDRESS:HTTP_PORT`: round robin over the `app` containers found through Docker's DNS, health checks on `/api/v1/health/ready` (active) and on refused connections (passive), streams flushed immediately, `X-Forwarded-For` appended to. No TLS — the host's reverse proxy still terminates it, pointed at the same `127.0.0.1:HTTP_PORT` as before |
| `redis` *(profile `bundled-redis`)* | `tasksense-redis` | `redis:7-alpine`, password from `BUNDLED_REDIS_PASSWORD`, no persistence, `noeviction`. Your own Redis instead: drop `bundled-redis` and set `REDIS_URL` (or the Sentinel / Cluster settings) |
| `worker` | `tasksense-worker` | the import worker — required with `replicas` |

All replicas run on one host, so this buys headroom on a large host and
survives one process crashing — not the loss of the host. The override uses
Compose's `!reset` tag and needs **Docker Compose 2.24.4 or newer**;
`preflight.sh` refuses it on an older Compose and on podman-compose. Upgrades
stop every replica, back up, migrate and start them again — the same window
as one process.

**Changing the number of replicas.** Set `APP_REPLICAS` in `compose/.env`,
then run:

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml \
  -f compose/docker-compose.replicas.yml up -d --no-recreate app
```

The running replicas keep serving. Compose starts the new ones, or stops the
extra ones, and `tasksense-lb` routes to a new replica once it reports ready.

Leave out `--no-recreate`, as `./tasksense configure` does, and every replica is
recreated at once: `APP_REPLICAS` is part of every container's environment.
That is a short outage.

Measured on 2026-11-04: 3 → 5 → 2 replicas, with one replica killed in
between, under steady traffic. Not one request failed.

---

## TRUST_PROXY: how many proxies to believe

The API takes the client's address from `X-Forwarded-For`, believing exactly
`TRUST_PROXY` proxies in front of it (default 1 — the nginx, Caddy, ingress
controller or router every installation has). Count every proxy that appends
to `X-Forwarded-For`:

| Topology | Proxies | `TRUST_PROXY` |
| --- | --- | --- |
| Compose, one process | host proxy | `1` (default) |
| Compose, `replicas` | host proxy → `tasksense-lb` | `2` (set by the override) |
| Compose, `replicas`, another load balancer in front of the host proxy | LB → host proxy → `tasksense-lb` | `3` |
| Kubernetes / OpenShift | ingress controller / router | `1` (default); `config.trustProxy` if another proxy in front of it appends |

Wrong in either direction is a security problem. Too few, and every client
looks like the nearest proxy: the per-address sign-in limit becomes **one
bucket for the whole installation** — a morning's sign-ins get 429s, and one
anonymous client can lock everyone out. Too many, and a client can choose its
own address with a header. `preflight.sh` refuses `TRUST_PROXY` below 2 with
the `replicas` profile.

---

## What you can scale, in the order that helps

1. **Memory for MongoDB's cache** (`MONGO_CACHE_GB`, or your DBA's sizing).
   MongoDB wants its indexes and hot documents in memory; starved, every query
   becomes disk I/O. If reports feel slow before the CPU is busy, this is why.
2. **The database host or cluster.** Your own replica set, on its own hosts,
   removes the memory contention between application and database and adds
   availability — [16-EXTERNAL-DATABASES](16-EXTERNAL-DATABASES.md).
3. **Memory for the API** (`APP_MEMORY_LIMIT` with `APP_HEAP_MB`; Helm
   `resources.limits.memory` with `heapMb`). Keep the heap at about 75 % of
   the limit — the rest is buffers, sockets and native memory.
4. **CPU for the API**, up to about 4. JavaScript runs on one core; the extra
   cores serve garbage collection, compression, TLS to MongoDB and password
   hashing. Beyond 4 a process rarely gets faster.
5. **Attachments on object storage** (Admin → Storage: S3, MinIO, WebDAV).
   Removes disk growth from the application host.
6. **The import worker** for a Jira migration — above.
7. **More API processes**, with Redis — profiles XL and XXL in
   [11-SIZING](11-SIZING.md). One process per 2–4 cores is the shape: past
   about 4 cores, a second process uses the hardware where a bigger one
   cannot.

---

## The Jira sync worker

The Jira sync over the API does two kinds of work in the background:

- **Full migrations.** It reads a whole Jira site: every issue with its
  history, comments, worklogs, attachments and users.
- **The two-way sync's queue.** It applies Jira's changes to TaskSense and
  TaskSense's changes to Jira.

The sync worker is a separate process from the **same image**
(`node dist/sync-worker.js`) that does this work and nothing else. A migration
reading hundreds of thousands of issues therefore never shares a heap or an
event loop with the people using the product.

| | API (`JIRA_SYNC_RUNNER=external`) | Sync worker (`WORKER_ROLE=sync`) |
| --- | --- | --- |
| Serves users, HTTP, the live feed | yes | no |
| Jira webhooks, creating an issue in Jira while a user waits | yes, and it queues the rest | no |
| Full migrations, the two-way sync's queue and sweeps | no | yes |
| Port | 3000 | 3100: `/live`, `/ready`, `/metrics` only, cluster-internal |
| Default memory | 2 GB, heap 1536 MB | 3 GB, heap 2048 MB |

How it behaves:

- **Resuming.** Every migration run and queue item is held under a **lease**
  and checkpointed. If the worker dies, the next sync worker process adopts the
  work at its last checkpoint, and nothing is landed twice.
- **Live updates.** The worker's writes reach open browsers within a second.
  - **With Redis**, the worker uses the same Redis connection settings as the
    API pods (the Helm `redis` block, or `REDIS_URL` in Compose). It publishes
    its change pings and cache invalidations on the bus that every API pod
    listens to. It shows in Admin → Data → Cluster as a sync worker.
  - **Without Redis**, it appends a small row to a capped MongoDB collection,
    and the API reads that collection with a tailable cursor. This works on a
    standalone MongoDB, with no replica set.

  Either way, a missed ping only makes a tab late, never wrong. Readiness
  depends on MongoDB alone. `/ready` and `/metrics` (`tasksense_redis_up`)
  still report whether the worker reaches Redis.
- **Storage.** It writes attachments into the storage the workspace has
  active (Admin → Storage: local, S3/MinIO, WebDAV), the same storage an
  upload uses. It writes user pictures as profile photos in MongoDB. With the
  local storage provider it mounts the API's data volume:
  - with `ReadWriteMany`, it can run on any node;
  - with `ReadWriteOnce`, the chart schedules it onto the API's node;
  - `ReadWriteOncePod` is refused.
- **Egress.** It is the process that calls Jira. Add the Jira site, and for
  Jira Cloud user pictures the avatar host, to `EGRESS_ALLOWLIST`.
- **Zero or one.** A second worker would only wait on the leases.

Turning it on:

| | Compose (`compose/.env`) | Helm |
| --- | --- | --- |
| Enable | add `jira-sync` to `COMPOSE_PROFILES` | `jiraSync.enabled: true` |
| API side | `JIRA_SYNC_RUNNER=external` (`preflight.sh` enforces it) | set automatically |
| Memory | `SYNC_MEMORY_LIMIT`, `SYNC_HEAP_MB` | `jiraSync.resources`, `jiraSync.heapMb` |
| Metrics | `/metrics` on 3100 inside the compose network | a `ServiceMonitor` when `metrics.serviceMonitor.enabled` |

Without the worker (`JIRA_SYNC_RUNNER=inline`, the default), the API runs the
Jira sync itself. That suits a small site. For a large migration, turn the
worker on.

---

## High availability

### What fails, and what happens

| Failure | One process | Several processes | Data lost |
| --- | --- | --- | --- |
| An API process crashes | Docker / the kubelet restarts it — back in about 30 s | The others keep serving; the load balancer or Service routes around it while it restarts | Nothing |
| An API process hangs | Compose: not restarted automatically — Docker does not act on an unhealthy healthcheck; alert on it ([09-MONITORING](09-MONITORING.md)). Kubernetes: the liveness probe (`/api/v1/health/live`) restarts it | Kubernetes: the same; Compose: `tasksense-lb`'s health checks take it out of rotation | Nothing |
| A MongoDB replica-set member fails | Election in seconds; the application carries on | Same | Nothing |
| Redis fails | — (not used) | Every API process reports not ready until Redis, or Sentinel's new master, is back. No restarts | What a Redis without persistence held — tickets, counters, job status; no user data |
| The host / node fails | Compose with hypervisor HA (vSphere HA, Hyper-V) on shared storage: the VM restarts elsewhere in minutes; without: rebuild and restore — target 1 hour. Kubernetes: the pod is rescheduled once the node is declared lost (about 5 min by default), plus the time to move a `ReadWriteOnce` volume (up to about 6 min) | Kubernetes, pods spread over nodes: the others serve; the `ReadWriteMany` volume is already mounted elsewhere. Compose: the same as one process — every replica is on that host | Nothing with shared storage; otherwise everything since the last backup |
| The bundled MongoDB's volume is lost | Restore the last backup | Same | Since the last backup (≤ 24 h) |
| Someone deletes a lot of work | Admin → Trash (60 days), or restore into a scratch instance | Same | Nothing, if caught within 60 days |

### Recovery targets

With a nightly backup on storage that survives the host:

| | Target | Depends on |
| --- | --- | --- |
| **RPO** | 24 hours | Backup frequency. Run `backup.sh` more often, or use your DBA's point-in-time backups of an external replica set, to narrow it. |
| **RTO** | 1 hour | Provision (15 min) + install (10 min) + restore. Restore time grows with attachment volume — rehearse it and record the real number ([07-BACKUP-DR](07-BACKUP-DR.md#rehearsing-it)). |

### Making the most of it

- **Run the database as a replica set** — the part that holds the data then
  survives a node.
- **Compose:** run the VM under hypervisor HA with its disks on shared
  storage; enable Docker at boot (`systemctl enable docker`). Keep backups off
  the host.
- **Kubernetes, one process:** set a `PriorityClass` so the pod is not the
  first evicted, avoid nodes that are drained often, and prefer storage that
  re-attaches quickly (or `ReadWriteMany`). The chart refuses a
  PodDisruptionBudget without Redis; one added outside the chart with
  `minAvailable: 1` blocks every node drain.
- **Kubernetes, several processes:** spread the pods over nodes
  (`topologySpreadConstraints`), turn on the disruption budget, run Redis with
  Sentinel across the same failure domains, and keep the import worker on.
- **Upgrades** have a short outage by default (the old version stops before the
  new one starts) — a minute or two plus migrations. Plan them in a change
  window ([08-UPGRADE](08-UPGRADE.md)); on Kubernetes, a rolling-safe release
  can roll instead.
