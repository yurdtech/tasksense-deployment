# Sizing

TaskSense scales **vertically**: one API process, sized with memory and CPU
limits, and a MongoDB with enough cache. There is no "add another replica"
step — the API is a single active process by design
([15-SCALING-AND-HA](15-SCALING-AND-HA.md)).

"Users" below means people with accounts. Concurrency is what costs resources,
and in practice about a fifth of a team is active at once.

---

## The table

| Profile | Users | Host (Compose, all-in-one) | API | Bundled MongoDB |
| --- | --- | --- | --- | --- |
| **S** | up to 50 | 2 vCPU · 4 GB RAM · 40 GB disk | `APP_CPU_LIMIT=2` `APP_MEMORY_LIMIT=2g` `APP_HEAP_MB=1536` *(defaults)* | `MONGO_CPU_LIMIT=2` `MONGO_MEMORY_LIMIT=2g` `MONGO_CACHE_GB=1` *(defaults)* |
| **M** | up to 200 | 4 vCPU · 8 GB RAM · 100 GB SSD | `2` · `3g` · `APP_HEAP_MB=2304` | `2` · `4g` · `MONGO_CACHE_GB=2` |
| **L** | up to 1 000 | 8 vCPU · 16 GB RAM · 250 GB SSD | `4` · `4g` · `APP_HEAP_MB=3072` | Your own replica set ([16](16-EXTERNAL-DATABASES.md)); if bundled: `4` · `8g` · `MONGO_CACHE_GB=4` |
| more | — | — | — | Talk to us |

Add for a **Jira migration window** (the import worker,
[15-SCALING-AND-HA](15-SCALING-AND-HA.md#the-import-worker)):

| | Host | Worker |
| --- | --- | --- |
| Import worker | **+2 vCPU, +6 GB RAM**, and free disk of **2 × the Jira backup's size** on the data volume | `WORKER_CPU_LIMIT=2` `WORKER_MEMORY_LIMIT=6g` `WORKER_HEAP_MB=4096` *(defaults)* |

**Helm** uses the same numbers: `resources.limits.memory` and `heapMb` for
the API (defaults `2Gi` and `1536`), `worker.resources.limits.memory` and
`worker.heapMb` for the worker (`6Gi` and `4096`). MongoDB is yours — size it
with your DBA from the cache rule below.

With your own MongoDB on separate hosts, the TaskSense host needs only the API
column (plus the worker during a migration): 2–4 vCPU and 4–8 GB is enough up
to profile L.

---

## The three rules behind the numbers

1. **Heap ≈ 75 % of the container limit.** `APP_HEAP_MB` is Node.js's
   `--max-old-space-size`. The rest of the limit is buffers, sockets and
   native memory. A heap at or above the limit gets the container killed by
   the kernel instead of a clean out-of-memory error in the log.
2. **MongoDB cache ≤ half its memory limit.** `MONGO_CACHE_GB` is
   `--wiredTigerCacheSizeGB`. MongoDB also needs memory outside the cache —
   connections, aggregation, the file-system cache it relies on.
3. **Limits are ceilings, not reservations.** On profile S the two containers'
   limits add up to the whole host; they are rarely at their ceilings at the
   same time. From profile M up, leave 1–2 GB for the operating system.

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
| API pinned at its CPU limit | `docker stats` | Raise `APP_CPU_LIMIT`, up to about 4 |
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

More API replicas is **not** on this list: it is not supported, and the Helm
chart refuses it. Why, and what it would take:
[15-SCALING-AND-HA](15-SCALING-AND-HA.md).
