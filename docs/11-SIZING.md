# Sizing

| Users | CPU | Memory | Disk | Database |
| --- | --- | --- | --- | --- |
| Up to 50 | 2 cores | 4 GB | 20 GB | Bundled container |
| Up to 200 | 4 cores | 8 GB | 100 GB SSD | Bundled, or your cluster |
| Up to 1000 | 8 cores | 16 GB | 500 GB SSD | Replica set, shared object storage |
| More | — | — | — | Talk to us |

"Users" means people with accounts. Concurrency is what actually costs
resources, and in practice about a fifth of a team is active at once.

Split the memory roughly in half between the application and MongoDB —
`APP_MEMORY_LIMIT` and `MONGO_MEMORY_LIMIT` in `.env`.

---

## What consumes what

**Disk is attachments.** The database itself stays small: a workspace with
100 000 tasks and three years of history is a few gigabytes. Estimate

```
users × attachments per user per month × average size × months retained
```

200 users at 5 files a month averaging 2 MB is about 24 GB a year. Add the same
again for backups if they live on this host — better, put them elsewhere.

Cap it with `STORAGE_MAX_FILE_MB`, or move files to MinIO or WebDAV
(Admin → Storage) so the application host stops growing.

**Memory is MongoDB's working set.** It wants the indexes and the hot documents
in cache; starve it and every query becomes disk I/O. If reports feel slow
before the CPU is busy, this is usually why.

**CPU is request handling**, and it is rarely the limit — unless you enable the
AI features, which are a different workload entirely
([12-AI-MODELS](12-AI-MODELS.md)).

---

## When to grow

Watch, rather than guess:

```bash
docker stats --no-stream
docker compose -f compose/docker-compose.yml logs app | grep slow
```

| Symptom | Do |
| --- | --- |
| Application pinned at its CPU limit | Raise `APP_CPU_LIMIT` |
| MongoDB at its memory limit, queries slowing | Raise `MONGO_MEMORY_LIMIT` |
| Disk above 80% | Move files to object storage, or add disk |
| Slow-request warnings under normal load | Memory first, then CPU |

With metrics enabled, `tasksense_http_request_duration_seconds` is the number to
alert on — p95 above a second means something needs attention.

---

## Growing beyond one host

In order of what actually helps:

1. **Object storage** for attachments. Removes disk growth from the equation and
   is the easiest change.
2. **MongoDB on its own host**, or a replica set. Removes the memory contention
   between the two, and gives you a database that survives a node.
3. **More application replicas**, on Kubernetes. The application holds no state
   between requests, so this works — put a load balancer in front and point
   every replica at the same database and object storage.

Rate limiting is per process, so with N replicas the effective limit is N times
the configured one. Adjust if you rely on it.
