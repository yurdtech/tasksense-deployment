# Using your own MongoDB and Redis

With Docker Compose, TaskSense runs its own MongoDB by default. If your
organisation already operates MongoDB — a replica set, with its own backups,
monitoring, disk encryption and DBAs — point TaskSense at it instead. With
Helm, your own MongoDB is the only option: the chart bundles none. Redis is
needed only to run more than one API process — [Redis](#redis) below.

**You never edit `docker-compose.yml` or the chart templates.** Everything
below is configuration: `compose/.env`, or Helm values and the Secret. That is
what keeps upgrades painless.

MongoDB is TaskSense's **only** data store. There is no queue or search server
beside it, and no fallback: an application that cannot reach it at startup
exits rather than serve an empty workspace that looks like data loss. Redis,
where it is configured, holds only short-lived state the API processes share —
no user data.

---

## What TaskSense needs from the database

| | |
| --- | --- |
| Version | **MongoDB 7.x** — the version we build and test against. |
| Topology | A **replica set** (three members) is recommended for availability. A standalone server works: TaskSense uses no multi-document transactions and no change streams. Sharding is not needed and not tested. |
| One database | Named by `MONGODB_DB` (default `tasksense`). TaskSense creates its collections and indexes itself on first start; nothing has to be prepared. |
| One account | Its own user — see below. Never the root account, never shared with another application. |
| Network | TCP from the TaskSense host (or pods) to **every member** of the replica set on its port (usually 27017). The driver discovers the topology and talks to whichever member is primary — opening only one member breaks the first failover. |
| Size | Small, next to attachments: 100 000 tasks with three years of history is a few GB. A migrated Jira with hundreds of thousands of issues is tens of GB — measure it on a test landing rather than guessing. |

---

## 1. Create the account

Run as a DBA, in `mongosh` against the primary:

```javascript
use admin
db.createUser({
  user: "tasksense",
  pwd: passwordPrompt(),
  roles: [
    { role: "readWrite", db: "tasksense" },
    { role: "dbAdmin",   db: "tasksense" }
  ]
})
```

Expected: `{ ok: 1 }`.

| Role | Why |
| --- | --- |
| `readWrite` on `tasksense` | Everything the application and its migrations do: reads, writes, creating and dropping its own collections and indexes. Also enough for `backup.sh`'s dump. |
| `dbAdmin` on `tasksense` | `scripts/restore.sh` connects with this same account and **drops the whole database** before restoring, so nothing from the failed state survives next to the restored one. It also lets the operator read index statistics. |

If your policy allows only `readWrite` for an application account, the
application and the backups run normally with it; restores are then done by a
DBA account (see [07-BACKUP-DR](07-BACKUP-DR.md#your-own-mongodb)).

Generate the password, rather than choosing it, and prefer one without URI
punctuation so you do not have to encode it:

```bash
openssl rand -hex 24
```

---

## 2. Write the connection string

TaskSense takes one URI. TLS, the replica set and the authentication database
all ride in it as query parameters, exactly as the MongoDB drivers expect. The
database name comes from `MONGODB_DB`, **not** from the path of the URI.

```dotenv
# Replica set — list every member; the driver finds the primary itself.
MONGODB_URI=mongodb://tasksense:<pw>@mongo-1.corp.internal:27017,mongo-2.corp.internal:27017,mongo-3.corp.internal:27017/?replicaSet=rs0&authSource=admin&tls=true&tlsCAFile=/certs/corp-ca.pem

# Standalone
MONGODB_URI=mongodb://tasksense:<pw>@mongo.corp.internal:27017/?authSource=admin&tls=true&tlsCAFile=/certs/corp-ca.pem

# DNS seed list (SRV). TLS is on by default with +srv.
MONGODB_URI=mongodb+srv://tasksense:<pw>@mongo.corp.internal/?authSource=admin&tlsCAFile=/certs/corp-ca.pem
```

Rules:

- **`authSource`** names the database the user was created in — `admin` in
  the example above. Leave it out and the driver authenticates against the
  database in the URI path, which fails with `Authentication failed`.
- **Percent-encode the password** if it contains `/ : @ ? # [ ] %`: `p@ss/w0rd`
  is written `p%40ss%2Fw0rd`. Unencoded, the driver refuses the whole URI
  (`Password contains unescaped characters`) before connecting to anything.
- **SRV** needs the `_mongodb._tcp.<host>` SRV record and the TXT record to be
  resolvable from inside the container (Compose) or pod (Kubernetes) — that is
  your internal DNS, not the host's `/etc/hosts`.
- **No `localhost`.** Inside a container, `localhost` is the container itself.
  A MongoDB running directly on the Docker host is reached by the host's own
  DNS name or address, and must listen on that interface (MongoDB's default
  `bindIp: 127.0.0.1` refuses it).
- Never use `tlsInsecure=true` or `tlsAllowInvalidHostnames=true` outside a
  lab. The host names in the URI must be in the server certificates' SAN.

---

## 3. TLS with your own CA

The application trusts the public CAs only. For a server certificate issued by
your CA, give it the CA file.

**Compose.** Put the PEM (root and issuing CAs concatenated) in
`compose/certs/` — mounted read-only at `/certs` in every container — and name
it in the URI:

```bash
cp /etc/pki/ca-trust/source/anchors/corp-ca.pem compose/certs/corp-ca.pem
```

```dotenv
MONGODB_URI=mongodb://…/?replicaSet=rs0&authSource=admin&tls=true&tlsCAFile=/certs/corp-ca.pem
NODE_EXTRA_CA_CERTS=/certs/corp-ca.pem     # the same bundle, for SMTP, OIDC and the rest
```

The path is the one **inside** the container. `preflight.sh` checks that the
file named by `tlsCAFile` exists in `compose/certs/`.

**Helm.** Mount the same bundle at `/certs` — `certs.existingConfigMap` (a
ConfigMap you manage), `certs.existingSecret` (for client keys) or inline
`certs.files` — and name it in `certs.caBundle` so `NODE_EXTRA_CA_CERTS`
points at it. The URI stays the same; the bundle is mounted in the API, the
worker, the migration Job and the backup Jobs alike.
[02-INSTALL-KUBERNETES › Private CA](02-INSTALL-KUBERNETES.md#private-ca)

```yaml
certs:
  existingConfigMap: tasksense-ca      # kubectl create configmap tasksense-ca --from-file=corp-ca.pem
  caBundle: corp-ca.pem
```

**Client certificates (x.509 authentication)** are supported by the driver
(`authMechanism=MONGODB-X509&tlsCertificateKeyFile=/certs/<client>.pem`) but are
not part of our test matrix. The key file must be readable by UID 1001 / GID 0
and is a private key — on Kubernetes mount it from a Secret, not a ConfigMap.

---

## 4. Point TaskSense at it

**Compose** — in `compose/.env`:

```dotenv
COMPOSE_PROFILES=                  # was: bundled-mongo   (keep import-worker if you use it)
MONGODB_URI=mongodb://tasksense:<pw>@mongo-1.corp.internal:27017,mongo-2.corp.internal:27017,mongo-3.corp.internal:27017/?replicaSet=rs0&authSource=admin&tls=true&tlsCAFile=/certs/corp-ca.pem
MONGODB_DB=tasksense
MONGODB_TIMEOUT_MS=15000           # an election takes seconds; 5 s is for the same host
MONGODB_COMPRESSORS=zlib           # the default; worth it across any network
MONGO_USER=
MONGO_PASSWORD=
```

Both halves, or neither: removing `bundled-mongo` without a URI, or setting a
URI while `bundled-mongo` is still listed, fails `preflight.sh`.
`MONGO_USER` / `MONGO_PASSWORD` only ever created the bundled container — leave
them empty.

**Helm** — `MONGODB_URI` goes in the Secret (it carries a password), the rest
in values:

```bash
kubectl -n tasksense create secret generic tasksense-secrets \
  --from-literal=MONGODB_URI='mongodb://tasksense:<pw>@mongo-1.corp.internal:27017,…/?replicaSet=rs0&authSource=admin&tls=true&tlsCAFile=/certs/corp-ca.pem' \
  --from-literal=STORAGE_SECRET="$(openssl rand -base64 32)"
```

```yaml
existingSecret: tasksense-secrets
config:
  mongodbDatabase: tasksense       # MONGODB_DB
  mongodbTimeoutMs: 15000          # MONGODB_TIMEOUT_MS — already the chart default
  mongodbCompressors: zlib         # MONGODB_COMPRESSORS
```

The other Secret keys and values:
[02-INSTALL-KUBERNETES](02-INSTALL-KUBERNETES.md#step-2--the-secret).

---

## 5. Verify it worked

The point is to prove the application reached **your** server, not a leftover
bundled one.

```bash
./scripts/preflight.sh
```

Expected, among the other checks: the external database answers on every
host:port in the URI, and the CA file exists.

```bash
docker compose -f compose/docker-compose.yml up -d
docker compose -f compose/docker-compose.yml ps -a
```

Expected: **no** `tasksense-mongo`; `tasksense-migrate` **Exited (0)**;
`tasksense-app` **healthy**.

```bash
docker compose -f compose/docker-compose.yml logs app | grep "MongoDB connected"
```

Expected — your host, with the password masked:

```
MongoDB connected: mongodb://tasksense:***@mongo-1.corp.internal:27017,…/tasksense
```

```bash
curl -s http://127.0.0.1:3000/api/v1/health
```

Expected: HTTP 200, `"database":"up"`. A **503** means the application cannot
reach it now; the log names the reason.

On Kubernetes: `kubectl -n tasksense logs job/<release>-migrate` shows the
migration against your server, and the same `MongoDB connected` line is in the
application pod's log.

---

## Moving from the bundled database to yours

```bash
./scripts/backup.sh --output /mnt/backup/tasksense      # on the bundled database
# edit compose/.env as in step 4
./scripts/preflight.sh
./scripts/restore.sh /mnt/backup/tasksense/tasksense-<timestamp>.tar.gz
```

`restore.sh` stops the application, drops and restores the database
`MONGODB_URI` now points at (through a tools container, with the account from
step 1), restores the files, and starts again — the migration step runs
first. The old `tasksense-mongo-data` volume is left on disk; remove it
deliberately once you are satisfied: `docker volume rm tasksense-mongo-data`.

## Switching back to the bundled database

```dotenv
COMPOSE_PROFILES=bundled-mongo
# MONGODB_URI=…
MONGO_USER=tasksense
MONGO_PASSWORD=<the password the bundled volume was created with>
```

Then `docker compose -f compose/docker-compose.yml up -d`. If the old volume
still exists, the bundled MongoDB starts with **that** data, not a copy of
your external one — restore a backup to bring the data across.

---

## Replica sets and failover

- Writes need a primary. During an election (normally a few seconds) a request
  that cannot reach one fails with a 503 instead of hanging; the driver
  carries on against the new primary as soon as it sees it.
- `MONGODB_TIMEOUT_MS=15000` gives the driver time to find the new primary
  instead of failing every request during the election.
- The liveness probe (`/api/v1/health/live`) never touches MongoDB, so a
  failover never restarts the application; the readiness probe
  (`/api/v1/health/ready`) takes it out of rotation until the database is back.
- `tasksense_mongo_pool_cleared_total` counts failovers and network errors as
  the application saw them ([09-MONITORING](09-MONITORING.md)).

---

## Things that go wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Cannot reach MongoDB at mongodb://tasksense:***@…: MongoServerSelectionError` | Firewall, DNS, or the server listens on `127.0.0.1` only | `preflight.sh` tests TCP to each host; open the port to **every** member; check `bindIp` |
| `Authentication failed` | Wrong `authSource`, wrong password, or unencoded URI characters | `authSource=admin` (or wherever the user lives); percent-encode the password |
| `self signed certificate in certificate chain` / `unable to get local issuer certificate` | Your CA is not trusted | CA bundle in `certs/`, `tlsCAFile=/certs/<file>.pem` |
| `Hostname/IP does not match certificate's altnames` | The URI uses a name or IP that is not in the server certificate | Use the names in the certificate's SAN |
| Works, then fails after a failover | Only one member opened in the firewall, or only one listed in the URI | List and open all members |
| `not authorized on tasksense to execute command { dropDatabase … }` during a restore | The account has `readWrite` only | Grant `dbAdmin` on `tasksense`, or restore with a DBA account |
| `querySrv ENOTFOUND` | SRV record not resolvable from inside the container | Fix internal DNS, or use the plain `mongodb://host1,host2,host3` form |
| The application log names the wrong host | `bundled-mongo` still in `COMPOSE_PROFILES` | `preflight.sh` flags the conflict |

More in [10-TROUBLESHOOTING](10-TROUBLESHOOTING.md).

---

## What you take on

With your own database, these become your DBAs' responsibility:

- **Backups.** `scripts/backup.sh` still dumps it (with `mongodump --uri` in a
  throwaway container, password never on a command line) together with the
  files and configuration, and `upgrade.sh` still takes one before every
  upgrade. Your DBA's own backup policy — snapshots, Ops Manager, point-in-time
  recovery — is better for a narrow RPO. Either way the attachments on the
  data volume must be backed up too: [07-BACKUP-DR](07-BACKUP-DR.md).
- **Availability.** TaskSense serves nothing while MongoDB is unreachable.
- **Encryption at rest.** Business content is not encrypted by the
  application ([06-SECURITY](06-SECURITY.md#data-at-rest-and-in-transit)); use
  encrypted storage or MongoDB Enterprise encryption.
- **MongoDB upgrades**, within the 7.x line until a TaskSense release says
  otherwise.

---

## Redis

Only for running **more than one API process**
([15-SCALING-AND-HA](15-SCALING-AND-HA.md)). With one process, configure none:
the API then keeps that state in its own memory, exactly as before. Redis is
used when one connection setting is present and not at all otherwise — there
is no switch.

### What TaskSense needs from it

| | |
| --- | --- |
| Version | **Redis 6 or newer** recommended (ACL users, native TLS). |
| Topology | **Sentinel** recommended — a primary, replicas and three sentinels. A single Redis works and is a single point of failure for every API process. Redis Cluster is supported. |
| Eviction | `maxmemory-policy noeviction`. Nothing TaskSense stores may be evicted; on a Redis shared with applications that need an eviction policy, use a Redis of its own. |
| Persistence | Not needed — tickets, counters, job status and messages in flight, all short-lived. |
| Network | TCP from every API pod and the worker to the data nodes (usually 6379) and, with Sentinel, to every sentinel (usually 26379). |
| Size | Not measured yet; the keys are small and expire on their own. 1 GB of `maxmemory` is a generous start — watch `used_memory`. |

### The connection settings

Exactly **one** of these:

| Setting | Form |
| --- | --- |
| `REDIS_URL` | `redis://[user:password@]host:6379[/db]`; `rediss://` for TLS |
| `REDIS_SENTINELS` + `REDIS_SENTINEL_NAME` | `host:port,host:port,…` of the sentinels, and the name of the master group they watch |
| `REDIS_CLUSTER_NODES` | `host:port,host:port,…` — seed nodes of a Redis Cluster |

And, as needed:

| Setting | What it does |
| --- | --- |
| `REDIS_USERNAME` / `REDIS_PASSWORD` | The ACL user and password for sentinels / cluster nodes; with `REDIS_URL` they override the URL's own |
| `REDIS_SENTINEL_PASSWORD` | The sentinels' own password, when they have one apart from the data nodes' |
| `REDIS_TLS=true` | TLS to the sentinels and cluster nodes (a URL says it with `rediss://`). The CA is `NODE_EXTRA_CA_CERTS` — the same bundle MongoDB's TLS trusts |
| `REDIS_KEY_PREFIX` | Prepended to every key and channel; default `tasksense:`. A test installation on the same Redis needs a different one |

A half-made configuration is refused at startup, by name, before anything
listens — two connection settings at once; `REDIS_SENTINELS` without
`REDIS_SENTINEL_NAME`; `REDIS_PASSWORD`, `REDIS_USERNAME` or `REDIS_TLS` with no
connection; `REDIS_TLS` beside a URL; `RATE_LIMIT_STORE=redis` without Redis.
An empty value counts as unset.

### The account

A user of its own, limited to TaskSense's prefix. A starting point in Redis 7
syntax — try it on a staging Redis first; a missing permission shows as a
`NOPERM` error in the API's log:

```
ACL SETUSER tasksense on >PASSWORD resetkeys ~tasksense:* resetchannels &tasksense:* +@read +@write +@pubsub +@scripting +@connection -@dangerous +info
```

Redis Cluster also needs `+cluster|slots` (topology discovery). Generate the
password with `openssl rand -hex 24` — it may go inside a URL.

### Point TaskSense at it

**Compose** — the `replicas` profile without `bundled-redis`, in
`compose/.env`:

```dotenv
COMPOSE_PROFILES=import-worker,replicas          # your own MongoDB and Redis
BUNDLED_REDIS_PASSWORD=                          # empty: no bundled Redis

# One Redis
REDIS_URL=rediss://tasksense:<pw>@redis.corp.internal:6380/0

# — or Sentinel —
#REDIS_SENTINELS=redis-1.corp.internal:26379,redis-2.corp.internal:26379,redis-3.corp.internal:26379
#REDIS_SENTINEL_NAME=tasksense
#REDIS_USERNAME=tasksense
#REDIS_PASSWORD=<pw>
#REDIS_TLS=true

NODE_EXTRA_CA_CERTS=/certs/corp-ca.pem           # the CA of the Redis certificates
```

`preflight.sh` checks that exactly one Redis is described: the bundled one,
or yours.

**Helm** — the URL carries a password, so it goes in a Secret:

```bash
kubectl -n tasksense create secret generic tasksense-redis \
  --from-literal=REDIS_URL='rediss://tasksense:<pw>@redis.corp.internal:6380/0'
```

```yaml
redis:
  existingSecret: tasksense-redis    # REDIS_URL from its key REDIS_URL
```

Sentinel, with the password in the same kind of Secret:

```yaml
redis:
  sentinels: [redis-1.corp.internal:26379, redis-2.corp.internal:26379, redis-3.corp.internal:26379]
  sentinelName: tasksense
  username: tasksense
  tls: true
  existingSecret: tasksense-redis
  existingSecretKey: ""              # no REDIS_URL — the sentinels are the connection
  existingSecretPasswordKey: REDIS_PASSWORD
```

`redis.existingSecret` may be the Secret named by `existingSecret`. With
`existingSecret` set, the inline `redis.url`, `redis.password` and
`redis.sentinelPassword` are refused — they would have nowhere to go; a
sentinel password of its own is then the key `REDIS_SENTINEL_PASSWORD` in that
Secret. Without `existingSecret`, the inline values are rendered into the
chart's Secret. Every value: [the values reference](02-INSTALL-KUBERNETES.md#values-reference).

### Verify it

```bash
curl -s http://127.0.0.1:3000/api/v1/health/ready      # Compose; on Kubernetes through the Ingress
```

Expected: HTTP 200 with `"redis":"up"`. A **503** with `"redis":"down"` means
the API cannot reach it or authenticate; the log says which:

```bash
docker compose -f compose/docker-compose.yml -f compose/docker-compose.replicas.yml logs app | grep -i redis
```

Expected at startup: a line beginning `Redis:` that names the connection
(password masked) and the key prefix. On Kubernetes:
`kubectl -n tasksense logs deploy/tasksense | grep -i redis`.

### Things that go wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| Startup refused: `REDIS_SENTINELS: cannot be combined with REDIS_URL …` | Two connection settings | Keep exactly one |
| Startup refused: `REDIS_PASSWORD: has no effect: no Redis is configured …` | A password with nothing to send it to | Add the connection setting, or remove the password |
| Every API process not ready, `"redis":"down"` | Address, firewall, TLS or credentials | The log names it; with TLS, the CA in `NODE_EXTRA_CA_CERTS`; on Kubernetes with NetworkPolicy, `networkPolicy.redis.*` |
| `NOPERM` in the log | The ACL user lacks a command, key or channel | Compare with the ACL above; the key prefix must match `REDIS_KEY_PREFIX` |
| `OOM command not allowed when used memory > 'maxmemory'` | `noeviction` at work: Redis is full | Raise `maxmemory`; find what else uses that Redis |
