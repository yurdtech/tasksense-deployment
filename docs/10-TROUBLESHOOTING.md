# Troubleshooting

Common problems, each as **symptom → cause → fix**.

Start with these four — they answer most questions:

```bash
./scripts/preflight.sh                                          # .env and host, known mistakes
docker compose -f compose/docker-compose.yml ps -a              # running / exited / unhealthy (-a shows the migrator)
docker compose -f compose/docker-compose.yml logs --tail 50 app # also: migrate | worker | mongo
curl -s http://127.0.0.1:3000/api/v1/health
```

The application prints why it will not start on the **first** lines of its
log, and a configuration problem is reported in full — every invalid setting at
once, each with what is wrong.

On Kubernetes the equivalents are `kubectl -n tasksense get pods`,
`kubectl -n tasksense logs job/tasksense-migrate`,
`kubectl -n tasksense logs deploy/tasksense` and `helm test tasksense -n tasksense`
— chart-specific problems are in [02-INSTALL-KUBERNETES](02-INSTALL-KUBERNETES.md)
and [03-INSTALL-OPENSHIFT](03-INSTALL-OPENSHIFT.md).

---

## Installing

### `docker login` / pull fails with `denied`, `unauthorized` or `manifest unknown`

**Cause:** the token is wrong, expired or pasted with a newline; or
`TASKSENSE_VERSION` names a version that does not exist.

**Fix:**

```bash
echo '<TOKEN>' | docker login ghcr.io -u yurdtech --password-stdin   # username is always yurdtech
```

`manifest unknown` → check `TASKSENSE_VERSION` against the releases page.
Everything else: [13-REGISTRY-ACCESS › Troubleshooting](13-REGISTRY-ACCESS.md#troubleshooting).

### Compose says `Additional property required is not allowed` or ignores the profiles

**Cause:** Docker Compose older than v2.20. The stack uses profiles and
optional dependencies (`depends_on.required`).

**Fix:** install a current Compose plugin; `docker compose version` must print
`v2.20.0` or newer. `preflight.sh` checks it.

### `preflight.sh`: `COMPOSE_PROFILES` and `MONGODB_URI` disagree

**Cause:** `MONGODB_URI` is set but `bundled-mongo` is still listed (two
databases, and the application would use yours while a second one runs empty),
or `bundled-mongo` was removed without setting a URI (no database at all).

**Fix:** both halves or neither —
[16-EXTERNAL-DATABASES](16-EXTERNAL-DATABASES.md#4-point-tasksense-at-it).

### `preflight.sh`: `import-worker` requires `WORKER_ROLE=api`

**Cause:** with the worker running and the API still on `WORKER_ROLE=all`, both
processes would try to run Jira landings.

**Fix:** `WORKER_ROLE=api` in `.env`.

### `preflight.sh`: a CA file does not exist

**Cause:** `tlsCAFile=/certs/…` in `MONGODB_URI`, or `NODE_EXTRA_CA_CERTS`,
names a file that is not in `compose/certs/` — usually a host path where the
container path belongs.

**Fix:** copy the PEM into `compose/certs/` and use `/certs/<name>.pem` in
`.env`. The path is the one **inside** the container.

### `preflight.sh`: `AGENT_EXECUTOR` must be `off`

**Cause:** an `.env` from an older install, or written by hand, with `on`,
`auto` or `unsafe-host`. No sandbox ships, so tool-using execution is not
available.

**Fix:** `AGENT_EXECUTOR=off`.

---

## It will not start

### `tasksense-migrate` exited with 1, and the application never started

**Symptom:** `ps -a` shows `tasksense-migrate  Exited (1)`; `tasksense-app` is
`Created` but not running.

**Cause:** the application starts only after the migration succeeds — by
design, so it never serves a half-migrated database. The migration failed.

**Fix:**

```bash
docker compose -f compose/docker-compose.yml logs migrate
```

Usually the database connection (next two entries). After fixing it,
`docker compose -f compose/docker-compose.yml up -d` runs the migration again —
migrations are idempotent, and an interrupted one is taken over and re-run.

### "Invalid environment configuration"

Exactly what it says, and it lists everything:

```
Invalid environment configuration:
  - APP_URL: is required when DEPLOYMENT_MODE=onprem — set it to this installation's own URL
  - STORAGE_SECRET: must be at least 32 characters (try: openssl rand -base64 32)
```

**Fix:** one edit to `.env`, one `up -d`. Every variable: [17-ENVIRONMENT](17-ENVIRONMENT.md).

### "Cannot reach MongoDB at mongodb://…"

**Cause:** MongoDB is the only data store and there is no fallback, so the
process exits rather than serving an empty workspace that looks like data loss.
Bundled: MongoDB is still starting, or the password no longer matches (next
entry). External: firewall, DNS, TLS or credentials.

**Fix — bundled:**

```bash
docker compose -f compose/docker-compose.yml ps mongo
docker compose -f compose/docker-compose.yml logs mongo | tail -20
```

**Fix — external:** `preflight.sh` tests TCP to every host in the URI; the
error text after the URI names the reason —
[16-EXTERNAL-DATABASES › Things that go wrong](16-EXTERNAL-DATABASES.md#things-that-go-wrong).

### "Authentication failed" with the right password in .env

```
Cannot reach MongoDB at mongodb://tasksense:***@mongo:27017/?authSource=admin:
MongoServerError: Authentication failed.
```

**Cause:** the bundled MongoDB writes its user and password **once**, when it
first creates its data volume; every later start ignores the password
completely. A volume left by an earlier install keeps the credentials it was
made with. It comes up after any install that did not finish: the second
attempt generates a new password and meets the first attempt's database.

```bash
docker volume ls | grep tasksense-mongo-data     # is one there?
```

**Fix — the volume holds nothing you need:**

```bash
docker compose -f compose/docker-compose.yml down -v
./scripts/install.sh
```

`-v` is the part that matters; without it the volume survives and the next
attempt fails identically.

**Fix — it holds data you need:** put the original password back in `.env` —
it is in the `.env` of the install that created the volume, inside any
`backup.sh` archive (`tar xzf <archive> -O ./env`), or in your vault. It cannot
be recovered from the database.

### Exits immediately with no useful message

**Cause:** almost always a mangled `.env` — an unquoted value containing `#`, a
stray newline in a pasted secret, or a key listed twice (`preflight.sh` reports
duplicates).

**Fix:**

```bash
grep -nE '^[A-Z_]+=' compose/.env | grep -E '#|\s$'
```

### `JavaScript heap out of memory`, or the container restarts under load

**Cause:** the heap (`APP_HEAP_MB`, `WORKER_HEAP_MB`) is too small for the
workload, or too close to the container limit, so the kernel kills it first.

**Fix:** raise the limit and the heap together, keeping the heap at about 75 %
of the limit — [11-SIZING](11-SIZING.md). If it happens during a Jira landing,
run the import worker so the landing has its own memory.

### Port already in use

```bash
ss -ltnp | grep 3000
```

Change `HTTP_PORT`, or stop what is holding the port.

---

## It starts, but nobody can reach it

### The reverse proxy returns 502

**Cause:** the container is published on `127.0.0.1` (the default); a proxy on
another host cannot reach it.

**Fix:** check from the TaskSense host first:

```bash
curl -fsS http://127.0.0.1:3000/api/v1/health
```

If that works and the proxy does not, set `BIND_ADDRESS` to the interface the
proxy reaches and allow only the proxy in the firewall — or fix the proxy.

### The interface loads, but nothing updates until you refresh

**Cause:** the live-update streams (server-sent events) are being buffered, cut
by a short read timeout, or stripped of their query string.

**Fix:** on the proxy, for `/api/v1/state/stream` and
`/api/v1/agents/events/stream`: buffering off, read timeout 24 h, and the query
string passed through unchanged — it carries the `?ticket=` the stream
authenticates with. `examples/nginx.conf` does all three. A `401` on those two
paths in the proxy log means the ticket did not arrive.

### Uploads fail at a certain size

**Cause:** two limits apply, and both must allow it: the application's
(`STORAGE_MAX_FILE_MB` for attachments, `STORAGE_MAX_VIDEO_FILE_MB` for video,
`JIRA_BACKUP_MAX_GB` for a Jira backup) and the proxy's body limit. An HTML
`413` page comes from the proxy; a JSON one naming the setting comes from
TaskSense.

**Fix:** raise the one that answered. The upload routes and the 21 GB limit are
in `examples/nginx.conf`.

### A Jira backup upload climbs to 100 %, then starts again — or fails with 408

**Cause:** a timeout or an idle-connection race between the proxy and the
application drops the connection with no response, and the browser silently
re-sends the whole body. Or the proxy buffers the body to its own disk, and
that disk is full.

**Fix:** on the upload routes — `proxy_request_buffering off`, read and send
timeouts of 4 h, upstream keep-alive shorter than 65 s
(`examples/nginx.conf`). Check the proxy host's free disk.

---

## Jira import

### `No space left on device` during an upload or a landing

**Cause:** uploads are staged on the data volume (`/app/api/data/tmp`), and the
landed content goes to MongoDB and the volume as well. A site backup needs
about **twice its size** free.

**Fix:** free or add space on Docker's data root (or the data PVC), then upload
again. A staged backup is deleted after `JIRA_BACKUP_RETENTION_DAYS` (7);
`preflight.sh` warns when free space is under `2 × JIRA_BACKUP_MAX_GB`.

### The upload finished, but the landing never starts

**Cause:** nobody runs landings — `WORKER_ROLE=api` is set while the
`import-worker` profile is off (or the worker is not running).

**Fix:** either start the worker (`import-worker` in `COMPOSE_PROFILES`, then
`up -d`) or set `WORKER_ROLE=all` again.

```bash
docker compose -f compose/docker-compose.yml logs worker | tail -20
```

### The worker restarts during a landing

**Cause:** usually memory. A restart is safe — the landing's lease expires and
it resumes from its last checkpoint — but repeated restarts mean it never
finishes.

**Fix:** raise `WORKER_MEMORY_LIMIT` and `WORKER_HEAP_MB` together (for
example `8g` / `6144`), `up -d`, and let it resume.

---

## Sign-in

### Directory sign-in says "The directory is not reachable"

**Cause:** the service account's credentials, or the host/port — the directory's
**Test connection** in Admin → Authentication names the actual reason.

**Fix:** test the same bind from the host before changing anything:

```bash
ldapsearch -H ldaps://dc01.bank.internal:636 -D "CN=svc-tasksense,OU=Service Accounts,DC=bank,DC=internal" -W \
  -b "DC=bank,DC=internal" "(sAMAccountName=<user>)" mail memberOf
```

More in [05-IDENTITY](05-IDENTITY.md#when-it-does-not-work).

### "Invalid username or password" for a user who exists

**Cause:** the search filter does not match them. TaskSense deliberately gives
the same answer for "no such user" and "wrong password".

**Fix:** run the directory's **Test connection** with that username; it shows
the filter result and the resolved role.

### "Too many failed sign-ins" (HTTP 429)

**Cause:** ten failed attempts for that identifier within 15 minutes.

**Fix:** wait for the window to pass, or restart the application to clear the
counters (they are in memory). Repeated occurrences for one account are worth
a look in the proxy log — that is what the lock is for.

### SSO returns "redirect_uri mismatch"

**Cause:** `OIDC_REDIRECT_URI` does not match the registration at the IdP
**exactly**, including scheme and path. The most common SSO failure.

**Fix:** register `<APP_URL>/api/v1/auth/oidc/callback` verbatim.

### SSO fails with `unable to get local issuer certificate`

**Cause:** the IdP's certificate is issued by your CA, and the application's
server-to-server calls (discovery, token exchange) do not trust it.

**Fix:** `NODE_EXTRA_CA_CERTS=/certs/bank-ca.pem` with the bundle in
`compose/certs/` (Helm: `certs.*`), then `up -d`. The same fixes SMTP and object
storage with internal certificates.

### Everyone signs in as a plain member

**Cause:** the group → role mapping does not match what the directory returns.

**Fix:** copy the group DNs from `ldapsearch` output — the full DN, not the
`CN` — and re-run Test connection with a real username.

### Users are signed out every day

**Cause:** `SESSION_TTL_HOURS=12` (or the workspace policy in Admin → Security)
— working as configured.

**Fix:** none needed; it is the bank recommendation. Change the policy if yours
differs.

### Locked out entirely

**Cause:** the directory is down and no local administrator password exists, or
every administrator was demoted.

**Fix:** sign in with the break-glass local account. Failing that, add your
address to `OWNER_EMAILS` and restart — those accounts are always
administrators — then remove it again:

```bash
echo 'OWNER_EMAILS=you@bank.internal' >> compose/.env
docker compose -f compose/docker-compose.yml up -d
```

---

## Licence: somebody cannot be added, or the plan says Free

```bash
curl -s -H "Authorization: Bearer <token>" http://127.0.0.1:3000/api/v1/billing/status | jq .licence
```

| `state` | Cause | Fix |
| --- | --- | --- |
| `absent` | No `LICENSE_KEY` | Free-tier limits are correct behaviour — [14-LICENSING](14-LICENSING.md) |
| `invalid` | The key was copied short or altered | It must start with `tsl_` and include everything after it, on one line |
| `expired` | The date inside the key has passed | Renew at info@yurdtech.az. Your data is untouched |
| `valid` | The licence is fine | The limit hit is the one in the key — check `over` on `/api/v1/team/seats` |

**On-premise, exceeding the seat count does not block sign-in.** If somebody
cannot get in, the cause is not seats. A change to `LICENSE_KEY` takes effect
on restart.

---

## Health and performance

### `/api/v1/health` reports `"indexes":"building"` or `"degraded"`

**Cause:** `building` — after an upgrade or restore, large indexes build in the
background while the application serves; queries that need them are slow until
they finish. `degraded` — an index failed to build.

**Fix:** `building`: wait. `degraded`: the application log names the index and
the server's reason (often duplicate data a migration has not cleaned yet);
send it to support.

```bash
docker compose -f compose/docker-compose.yml logs app | grep -i index
```

### `/api/v1/health` reports `"schema":{"state":"ahead"}`

**Cause:** this version runs on a database a newer release has migrated — an
application-only rollback.

**Fix:** finish the rollback with the pre-upgrade backup, or upgrade again —
[08-UPGRADE › Rolling back](08-UPGRADE.md#rolling-back).

### Everything is slow

```bash
docker stats --no-stream
docker compose -f compose/docker-compose.yml logs app | grep '(slow)'
```

**Cause and fix:** MongoDB at its memory limit → raise `MONGO_MEMORY_LIMIT` and
`MONGO_CACHE_GB`; the API pinned at its CPU limit → raise `APP_CPU_LIMIT` (up to
about 4); everybody stalls at once → event-loop lag, usually a landing or a huge
report in the API process — [11-SIZING › When to grow](11-SIZING.md#when-to-grow).
More API replicas is not an option ([15-SCALING-AND-HA](15-SCALING-AND-HA.md)).

### Disk filling up

```bash
docker system df -v | grep tasksense
```

Attachments and staged uploads dominate. Move attachments to object storage
(Admin → Storage), lower `STORAGE_MAX_FILE_MB`, remove old images
(`docker image prune`), check old backups are pruned, or add disk.

---

## Upgrades and restores

### `upgrade.sh` refuses: the target is older than what is installed

**Cause:** going down is not an upgrade — migrations only go forward.

**Fix:** `./scripts/rollback.sh` ([08-UPGRADE](08-UPGRADE.md#rolling-back)).

### `restore.sh` refuses: the backup is from a newer version

**Cause:** older code against a newer schema misbehaves quietly.

**Fix:** install that version first (`upgrade.sh <version>`), then restore.

### Attachments will not download after a restore, or directory sign-in stopped

**Cause:** the restore ran with a different `STORAGE_SECRET` than the backup was
taken with (a `--no-config` backup restored onto a new host). The data is
there; the stored credentials cannot be decrypted.

**Fix:** put the original `STORAGE_SECRET` back and restart. Without it,
re-enter the credentials in Admin → Authentication, Storage and Email delivery.

### Something was deleted

Admin → Trash. Deleted tasks and projects are kept for 60 days and restore with
their comments and attachments.

---

## Getting help

```bash
./scripts/collect-diagnostics.sh
```

Bundles versions, container status, recent logs and your configuration with
every secret replaced by `<redacted>`. **Review it before sending** — logs
contain user names and task titles:

```bash
tar tzf tasksense-diagnostics-*.tar.gz
```

Send it to **info@yurdtech.az** (or your support contact) with what you
expected and what happened instead. Never send `compose/.env`, a Secret, or a
backup archive — they contain credentials.
