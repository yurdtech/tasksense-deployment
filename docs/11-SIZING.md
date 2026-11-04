# Sizing

Up to profile L, TaskSense scales **vertically**: one API process, sized with
memory and CPU limits, and a MongoDB with enough cache. Beyond it — profiles
XL and XXL — the API runs as **several processes**, which needs Redis and
shared storage ([15-SCALING-AND-HA](15-SCALING-AND-HA.md)). Without Redis the
API is one process, whatever the size.

"Users" below means people with accounts. Concurrency is what costs resources,
and in practice about a fifth of a team is active at once.

---

## The table

| Profile | Users | Host (Compose, all-in-one) | API | Bundled MongoDB |
| --- | --- | --- | --- | --- |
| **S** | up to 50 | 2 vCPU · 4 GB RAM · 40 GB disk | `APP_CPU_LIMIT=2` `APP_MEMORY_LIMIT=2g` `APP_HEAP_MB=1536` *(defaults)* | `MONGO_CPU_LIMIT=2` `MONGO_MEMORY_LIMIT=2g` `MONGO_CACHE_GB=1` *(defaults)* |
| **M** | up to 200 | 4 vCPU · 8 GB RAM · 100 GB SSD | `2` · `3g` · `APP_HEAP_MB=2304` | `2` · `4g` · `MONGO_CACHE_GB=2` |
| **L** | up to 1 000 | 8 vCPU · 16 GB RAM · 250 GB SSD | `4` · `4g` · `APP_HEAP_MB=3072` | Your own replica set ([16](16-EXTERNAL-DATABASES.md)); if bundled: `4` · `8g` · `MONGO_CACHE_GB=4` |
| **XL** *(estimate)* | about 1 000 – 5 000 | Kubernetes, or one Compose host of 16 vCPU · 64 GB with `replicas` | 3 – 6 API processes, each `2` · `4g` · `APP_HEAP_MB=3072` (Helm: `resources.requests.cpu: "2"`, `limits.memory: 4Gi`, `heapMb: 3072`); the import worker; Redis | Your own replica set: three members of 8 vCPU · 32 GB |
| **XXL** *(estimate)* | about 5 000 – 10 000 | Kubernetes | 6 – 12 API pods, each as in XL; autoscaling up to 20; the import worker; Redis | Your own replica set: three members of 16 vCPU · 64 GB |
| more | — | — | — | Talk to us |

**XL and XXL are estimates.** They are extrapolated from profile L, the
per-process rules below and the single-process load test that follows. Size a
pilot from these rows, watch the metrics under [When to grow](#when-to-grow),
and adjust.

### What one API process carried (k6, 2026-11-04)

**Setup:**
- one workspace of 10 011 members and 4 033 tasks;
- MongoDB 8.2 and Redis 8 on the same machine as the API;
- one native API process, Node 22 on one core of a shared 18-core
  workstation.

**Load:** each active user reads its board and updates one of its tasks every
5–15 s, and keeps three live-update streams open. Alongside, people open the
app (`GET /state`, 3 MB, 295 KB gzipped) and sign in, both in proportion to
the active users.

| Active users | Requests/s | Board p50 / p95 | Task update p50 / p95 | `/state` p50 / p95 | Errors |
| --- | --- | --- | --- | --- | --- |
| 100 | 15 | 8 ms / 54 ms | 11 ms / 54 ms | 167 ms / 380 ms | 0 |
| 300 | 44 | 10 ms / 244 ms | 16 ms / 0.7 s | 156 ms / 0.9 s | 0 |
| 400 | 52 | 14 ms / 2.1 s | 24 ms / 8.5 s | 206 ms / 4.9 s | 0 |

At 300 active users the p95 of a task update varied from 0.7 s to 2.5 s
between runs.

**What this gives for 10 000 users.** About 2 000 of them are active at
once, and one process serves about 300 of them with p95 under a second. That
is 7 API processes. Add headroom for losing a node and for the morning wave of
app opens: **8–10 processes**, inside the XXL row.

**Not measured yet: several processes at the full load.** On the test
machine, 5 and 10 processes shared the cores with the load generator and other
workloads, and each process got about a third of a core. Those runs measured
the machine, not TaskSense. The XL and XXL rows stay estimates until the full
test runs with the load generator on machines of its own.

What XL and XXL need besides the API processes:

| | XL | XXL |
| --- | --- | --- |
| Redis | Sentinel: a primary, a replica and three sentinels; 1 GB `maxmemory`, `noeviction` *(estimate — not measured)* | the same, 2 GB *(estimate)* |
| Data volume (Kubernetes) | `ReadWriteMany`, required: attachments (unless they are on object storage) plus 2 × the largest Jira backup | the same |
| MongoDB connections | up to 6 × 50 + 50 = 350 with the pool of 50 the chart and the Compose `replicas` profile default to | up to 20 × 50 + 50 = 1 050 — [the budget](#the-mongodb-connection-budget) |
| Spread | pods over at least two nodes | over at least three nodes, PodDisruptionBudget on |

On Compose all replicas share one host: XL fits there with your own MongoDB
and Redis, but the host remains a single point of failure. XXL belongs on
Kubernetes.

Add for a **Jira migration window** (the import worker,
[15-SCALING-AND-HA](15-SCALING-AND-HA.md#the-import-worker)):

| | Host | Worker |
| --- | --- | --- |
| Import worker | **+2 vCPU, +6 GB RAM**, and free disk of **2 × the Jira backup's size** on the data volume | `WORKER_CPU_LIMIT=2` `WORKER_MEMORY_LIMIT=6g` `WORKER_HEAP_MB=4096` *(defaults)* |

**Helm** uses the same numbers: `resources.limits.memory` and `heapMb` for
the API (defaults `2Gi` and `1536`), `worker.resources.limits.memory` and
`worker.heapMb` for the worker (`6Gi` and `4096`). MongoDB is yours — size it
with your DBA from the cache rule below. With several API pods the numbers are
per pod.

With your own MongoDB on separate hosts, the TaskSense host needs only the API
column (plus the worker during a migration): 2–4 vCPU and 4–8 GB is enough up
to profile L.

---

## The four rules behind the numbers

1. **Heap ≈ 75 % of the container limit.** `APP_HEAP_MB` is Node.js's
   `--max-old-space-size`. The rest of the limit is buffers, sockets and
   native memory. A heap at or above the limit gets the container killed by
   the kernel instead of a clean out-of-memory error in the log.
2. **MongoDB cache ≤ half its memory limit.** `MONGO_CACHE_GB` is
   `--wiredTigerCacheSizeGB`. MongoDB also needs memory outside the cache —
   connections, aggregation, the file-system cache it relies on.
3. **Limits are ceilings, not reservations.** On profile S the two containers'
   limits add up to the whole host; they are rarely at their ceilings at the
   same time. From profile M up, leave 1–2 GB for the operating system. With
   the Compose `replicas` profile every app container has its own
   `APP_MEMORY_LIMIT`: `APP_REPLICAS × APP_MEMORY_LIMIT`, plus the worker,
   Redis and the load balancer, must fit the host.
4. **One process per 2–4 cores.** A process rarely gets faster beyond about 4
   cores (JavaScript runs on one; the others serve garbage collection, TLS and
   compression). Past that, another process uses the hardware where a bigger
   one cannot — which is what XL and XXL do.

---

## The MongoDB connection budget

Every API process, the worker, the migration Job and the backup Jobs open their
own connection pool. What MongoDB must accept, at most:

```
connections = (API processes at most + workers) × MONGODB_MAX_POOL_SIZE
            + a pool for the migration Job and each backup Job while it runs
```

- "API processes at most" is `replicaCount`, or `autoscaling.maxReplicas` with
  the autoscaler — size for the ceiling, not today's count. On Compose it is
  `APP_REPLICAS`.
- `MONGODB_MAX_POOL_SIZE` is 100 by default. The chart lowers it to **50** with
  more than one API pod or with autoscaling (`config.mongodbMaxPoolSize`
  empty), and so does the Compose `replicas` profile (for every copy and the
  worker); an explicit value wins.
- The cap of 20 API processes at 50 each is **1 000** connections, plus 50 for
  the worker.
- `MONGODB_MIN_POOL_SIZE` (10) stays open per process even when idle: 20
  processes hold 200 connections at rest.

Check the sum against what the cluster is configured to accept
(`net.maxIncomingConnections` and the server's file-descriptor limit) and
against its memory: each connection costs the server memory (MongoDB
documents up to about 1 MB). `tasksense_mongo_pool_wait_seconds` rising means a
pool is too small; checkout timeouts under load with a small cluster mean the
sum is too large for it.

---

## What consumes what

**Disk is attachments.** The database stays small: a workspace with 100 000
tasks and three years of history is a few GB. Estimate attachments as

```
users × files per user per month × average size × months retained
```

200 users at 5 files a month averaging 2 MB is about 24 GB a year. Cap it with
`STORAGE_MAX_FILE_MB`, or move files to object storage (Admin → Storage) so the
application host stops growing.

Docker's data root also holds:

| | Size |
| --- | --- |
| Images (TaskSense + MongoDB) | about 1–1.5 GB per version kept |
| Upload staging (`/app/api/data/tmp`) | up to the largest upload in flight; a Jira backup is kept for `JIRA_BACKUP_RETENTION_DAYS` (7) after upload |
| The application's own nightly JSON snapshots | the last 14, each an export of the workspace's content without attachments |
| `./backups/` if you leave backups on the host | each archive ≈ database dump + all attachments — move them off the host |

**A Jira import needs twice the backup.** The uploaded `entities.xml` is staged
on the data volume and kept for a week so further projects can be landed from
it; the landed issues, comments and attachments then occupy the database and
the volume as well. Plan free space of **2 × the backup's size** before you
upload (a 13 GB site backup: 26 GB free). `preflight.sh` warns when Docker's
data root has less than `2 × JIRA_BACKUP_MAX_GB` free.

**Memory is MongoDB's working set**, then the API's heap. During a Jira landing
the worker (or, without it, the API) is the biggest consumer by far.

**CPU is request handling**, and it is rarely the limit — unless you enable the
AI features with a local model, which is a different workload entirely and runs
on its own hardware ([12-AI-MODELS](12-AI-MODELS.md)).

---

## When to grow

Watch, rather than guess:

```bash
docker stats --no-stream
docker compose -f compose/docker-compose.yml logs app | grep '(slow)'
```

With metrics enabled ([09-MONITORING](09-MONITORING.md)):

| Symptom | Metric | Do |
| --- | --- | --- |
| Queries slow before the CPU is busy | `tasksense_mongo_operation_seconds` p95 rising | Raise `MONGO_CACHE_GB` (and `MONGO_MEMORY_LIMIT`), or the external cluster's memory |
| Requests waiting for a connection | `tasksense_mongo_pool_wait_seconds`, `…_checkout_failures_total{reason="timeout"}` | Find the slow queries first; then `MONGODB_MAX_POOL_SIZE` |
| The interface stalls for everyone at once | `tasksense_event_loop_lag_p99_seconds` > 0.5 | Usually a landing or a huge report — run the import worker; otherwise raise `APP_CPU_LIMIT` |
| Restarts, `JavaScript heap out of memory` in the log | `tasksense_process_heap_used_bytes` near `APP_HEAP_MB` | Raise `APP_MEMORY_LIMIT` and `APP_HEAP_MB` together |
| API pinned at its CPU limit | `docker stats` | Raise `APP_CPU_LIMIT`, up to about 4; beyond that, more API processes (with Redis) |
| Several processes, all busy | `tasksense_http_request_duration_seconds` p95 rising on every pod | More API processes (`replicaCount`, `autoscaling.maxReplicas`, `APP_REPLICAS`) — and check the [connection budget](#the-mongodb-connection-budget) first |
| Messages between processes arrive late | `tasksense_cluster_bus_lag_seconds` p99 above a second | Redis latency or load; see [09-MONITORING](09-MONITORING.md) |
| Disk above 80 % | your node exporter | Object storage for attachments, prune old backups, or more disk |

`tasksense_http_request_duration_seconds` p95 above a second under normal load
means one of the above needs attention.

---

## Growing beyond one host

In order of what actually helps:

1. **Object storage** for attachments. Removes disk growth from the equation.
2. **MongoDB on its own hosts, as a replica set.** Removes the memory
   contention between application and database, and gives you a database that
   survives a node.
3. **A bigger API container** — memory first, CPU up to about 4.
4. **More API processes**, once one process at about 4 cores is not enough.
   It needs Redis, `ReadWriteMany` storage on Kubernetes and the import
   worker; the chart and `preflight.sh` refuse it without them, and cap it at
   20. [15-SCALING-AND-HA](15-SCALING-AND-HA.md).
