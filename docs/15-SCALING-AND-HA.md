# Scaling and high availability

The short version, stated plainly so it is not discovered during an audit:

- **The TaskSense API is a single active process, by design.** You never run
  two of it — not on Compose, not on Kubernetes, not even for a moment during
  an upgrade.
- You scale it **vertically**: more memory, a bigger database cache, faster
  MongoDB. [11-SIZING](11-SIZING.md) has the numbers.
- The only optional second process is the **import worker**, which takes Jira
  backup landings off the API. Zero or one of it.
- **Availability** comes from the orchestrator restarting the process quickly
  and from MongoDB as a replica set — not from running several copies.

---

## Why one process

Several things the API does live inside its own process, with no coordination
between processes:

| What | Where it lives | What two copies would do |
| --- | --- | --- |
| Schedulers — agent dispatcher, automation schedules, due-date sweep, digests, nightly snapshots, metric snapshots | in-process timers, no distributed lock | Run twice: duplicate e-mails, duplicate snapshots, automation rules firing twice |
| The live-update feed (server-sent events) | in-process | A change made through one copy reaches only the browsers connected to that copy; everyone else sees it after a refresh |
| `?ticket=` credentials for the streams and video | in memory | A ticket minted by one copy is unknown to the other: streams fail at random with 401 |
| Sign-in lockout and rate-limit counters | in memory (`RATE_LIMIT_STORE=memory`) | Each copy counts separately; the limits multiply |

So the packaging makes a second copy impossible rather than merely
discouraged:

- **Compose** has one `app` service with a fixed container name
  (`tasksense-app`); `docker compose up --scale app=2` fails.

- **Helm** refuses to render with `replicaCount` above 1 (0 stops the API), with
  `autoscaling` set, or with a PodDisruptionBudget for the API, and always
  upgrades with the `Recreate` strategy — the old pod is gone before the new
  one starts.

---

## What you can scale

In the order that helps:

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
   hashing. Beyond 4 the API rarely gets faster.
5. **Attachments on object storage** (Admin → Storage: S3, MinIO, WebDAV).
   Removes disk growth from the application host.
6. **The import worker** for a Jira migration — below.

---

## The import worker

Landing a large Jira site backup — parsing a multi-gigabyte `entities.xml` and
writing hundreds of thousands of issues — is the heaviest thing TaskSense does.
In the API process it shares one heap with every user. The import worker is a
second process from the **same image** (`node dist/worker.js`) that does that
and nothing else.

| | API (`WORKER_ROLE=api`) | Worker (`WORKER_ROLE=worker`) |
| --- | --- | --- |
| Serves users, HTTP, the live feed | yes | no — no listener, no port |
| Schedulers (dispatcher, automation, digests, snapshots) | yes | no |
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

Turning it on:

| | Compose (`compose/.env`) | Helm |
| --- | --- | --- |
| Enable | add `import-worker` to `COMPOSE_PROFILES` | `worker.enabled: true` |
| API role | `WORKER_ROLE=api` (`preflight.sh` enforces it) | set automatically |
| Memory | `WORKER_MEMORY_LIMIT`, `WORKER_HEAP_MB` | `worker.resources`, `worker.heapMb` |
| Shared staging | the same `tasksense-app-data` volume | `persistence.accessMode: ReadWriteMany` |

Leave it on for the migration window and turn it off afterwards; with
`WORKER_ROLE=all` (the default) the API does the occasional small landing
itself.

---

## High availability

### What fails, and what happens

| Failure | Docker Compose | Kubernetes / OpenShift | Data lost |
| --- | --- | --- | --- |
| The API process crashes | Docker restarts it (`restart: unless-stopped`) — back in about 30 s | The kubelet restarts it — about 30 s | Nothing |
| The API hangs | Not restarted automatically: Docker does not act on an unhealthy healthcheck. Alert on it ([09-MONITORING](09-MONITORING.md)) and restart | The liveness probe (`/api/v1/health/live`) restarts it | Nothing |
| A MongoDB replica-set member fails | Election in seconds; the application carries on | Same | Nothing |
| The host / node fails | With hypervisor HA (vSphere HA, Hyper-V) on shared storage: the VM restarts elsewhere in minutes. Without: rebuild and restore — target 1 hour | The pod is rescheduled once the node is declared lost (about 5 min by default), plus the time to move a `ReadWriteOnce` volume (up to about 6 min) | Nothing with shared storage; otherwise everything since the last backup |
| The bundled MongoDB's volume is lost | Restore the last backup | — (no bundled database) | Since the last backup (≤ 24 h) |
| Someone deletes a lot of work | Admin → Trash (60 days), or restore into a scratch instance | Same | Nothing, if caught within 60 days |

### Recovery targets

With a nightly backup on storage that survives the host:

| | Target | Depends on |
| --- | --- | --- |
| **RPO** | 24 hours | Backup frequency. Run `backup.sh` more often, or use your DBA's point-in-time backups of an external replica set, to narrow it. |
| **RTO** | 1 hour | Provision (15 min) + install (10 min) + restore. Restore time grows with attachment volume — rehearse it and record the real number ([07-BACKUP-DR](07-BACKUP-DR.md#rehearsing-it)). |

### Making the most of one process

- **Run the database as a replica set** — the part that holds the data then
  survives a node.
- **Compose:** run the VM under hypervisor HA with its disks on shared
  storage; enable Docker at boot (`systemctl enable docker`). Keep backups off
  the host.
- **Kubernetes:** set a `PriorityClass` so the pod is not the first evicted,
  avoid nodes that are drained often, and prefer storage that re-attaches
  quickly (or `ReadWriteMany`). Do not add a PodDisruptionBudget — with one
  replica, `minAvailable: 1` blocks every node drain.
- **Upgrades** have a short outage by design (the old version stops before the
  new one starts) — a minute or two plus migrations. Plan them in a change
  window ([08-UPGRADE](08-UPGRADE.md)).

---

## What horizontal scaling would need

For transparency — none of this is in 1.1.0. Running several active API
processes would require:

1. a leader lease for every scheduler, so each job runs once;
2. a shared change feed for live updates (MongoDB change streams, which
   require a replica set);
3. URL tickets, lockout and rate-limit counters in a shared store
   (`RATE_LIMIT_STORE=mongo` already exists for the rate limits);
4. settings-cache invalidation across processes (`SETTINGS_CACHE_TTL_MS=0`
   already exists for the worker).

If your load is beyond what one well-sized process serves — in practice,
thousands of concurrently active users — talk to us (info@yurdtech.az) before
sizing hardware around it.
