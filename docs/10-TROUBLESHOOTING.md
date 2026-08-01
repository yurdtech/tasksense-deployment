# Troubleshooting

Start here:

```bash
docker compose -f compose/docker-compose.yml ps
docker compose -f compose/docker-compose.yml logs --tail 50 app
curl -fsS http://127.0.0.1:3000/api/v1/health
```

The application prints why it will not start on the **first** lines of its log,
and a configuration problem is reported in full — every invalid setting at once,
each with what is wrong and what to do about it.

---

## Somebody cannot be added, or the plan says Free unexpectedly

Check what the licence actually is before anything else:

```bash
curl -s -H "Authorization: Bearer <token>" \
  http://localhost:3000/api/v1/billing/status | jq .licence
```

| `state` | Cause | Fix |
| --- | --- | --- |
| `absent` | No `LICENSE_KEY` in `.env` | Free-tier limits are correct behaviour. [14-LICENSING](14-LICENSING.md) |
| `invalid` | The key was copied short, or altered | It must start with `tsl_` and include everything after it, on one line |
| `expired` | The date inside the key has passed | Renew at info@meiksense.io. Your data is untouched |
| `valid` | The licence is fine | The limit you hit is the one in the key — check `over` on `/api/v1/team/seats` |

**On-premise, exceeding the seat count does not block sign-in.** If somebody
genuinely cannot get in, the cause is not seats — check the directory
configuration in [05-IDENTITY](05-IDENTITY.md).

A change to `LICENSE_KEY` takes effect on restart; it is read once at startup.


## "Authentication failed", with the right password in `.env`

```
Cannot reach MongoDB at mongodb://tasksense:235ca6…@mongo:27017/?authSource=admin:
MongoServerError: Authentication failed.
```

The password in `.env` is the password, and it is refused. Both are true.

MongoDB writes its username and password **once**, when it first creates its
data directory. Every later start ignores `MONGO_INITDB_ROOT_PASSWORD`
completely. So a volume left by an earlier install keeps the credentials it was
made with, and a new `.env` cannot change them.

It comes up after any install that did not finish: the second attempt generates
a new password and meets the first attempt's database.

```bash
docker volume ls | grep tasksense-mongo-data     # is one there?
```

If that database holds nothing you need:

```bash
docker compose -f compose/docker-compose.yml down -v
./tasksense
```

`-v` is the part that matters. Without it the volume survives and the next
attempt fails identically.

If it holds data you need, put the original password back in `.env` instead —
it is in the `.env` from the install that created the volume, or in your
password manager. There is no way to recover it from the database.


## It will not start

### "Invalid environment configuration"

Exactly what it says, and it lists everything. One edit to `.env`, one restart.

```
- NODE_ENV: must be "production" when DEPLOYMENT_MODE=onprem
- STORAGE_SECRET: is required when DEPLOYMENT_MODE=onprem
```

### "Cannot reach MongoDB"

The database is the only data store and there is no fallback, so the process
exits rather than serving an empty workspace that looks like data loss.

```bash
docker compose -f compose/docker-compose.yml ps mongo
docker compose -f compose/docker-compose.yml logs mongo | tail -20
```

Usually: MongoDB is still starting (wait, it will retry), or `MONGO_PASSWORD` in
`.env` no longer matches the one the volume was created with. Changing the
password after first install does **not** change it inside MongoDB — set it back,
or change it in the database.

### Exits immediately with no message

Almost always a mangled `.env`: an unquoted value containing `#`, or a stray
newline in a pasted secret.

```bash
grep -nE '^[A-Z_]+=' compose/.env | grep -E '#|\s$'
```

### Port already in use

```bash
ss -ltnp | grep 3000
```

Change `HTTP_PORT`, or stop what is holding it.

---

## It starts, but nobody can reach it

### Reverse proxy returns 502

The container binds to `127.0.0.1` by default. If the proxy runs on another
host, it cannot reach it — set `BIND_ADDRESS=0.0.0.0` and firewall the port
properly.

```bash
curl -fsS http://127.0.0.1:3000/api/v1/health    # works?
```

If that works and the proxy does not, the problem is the proxy.

### The interface loads but nothing updates until you refresh

Live updates are server-sent events and your proxy is buffering them. The nginx
snippet in `examples/nginx.conf` disables buffering on the two stream paths;
without it, changes arrive only when the buffer happens to flush.

### Uploads fail at a certain size

Two limits, both must allow it: `STORAGE_MAX_FILE_MB` and the proxy's body
limit (`client_max_body_size` in nginx). The proxy rejects the request before it
reaches the application, so the error comes from the proxy.

---

## Sign-in

### Directory sign-in says "The directory is not reachable"

The service account or the host. The real reason is in the log:

```bash
docker compose -f compose/docker-compose.yml logs app | grep -i ldap
```

Test the same bind from the host with `ldapsearch` before changing anything —
[05-IDENTITY](05-IDENTITY.md).

### "Invalid username or password" for a user who exists

The search filter does not match them. TaskSense deliberately gives the same
answer for "no such user" and "wrong password", so the log is where the
distinction is.

### SSO returns "redirect_uri mismatch"

`OIDC_REDIRECT_URI` must match what is registered at the provider **exactly**,
including scheme and path. This is the most common SSO failure.

### Everyone signs in as a plain member

`LDAP_GROUP_MAP` group DNs do not match what the directory returns. Copy them
from `ldapsearch` output — the full DN, not just the `CN`.

### Locked out entirely

Add your address to `OWNER_EMAILS` and restart. Those accounts are always
admin, which is what the setting is for.

```bash
echo 'OWNER_EMAILS=you@bank.internal' >> compose/.env
docker compose -f compose/docker-compose.yml up -d
```

---

## Performance

### Everything is slow

```bash
docker stats --no-stream
```

If the application is at its CPU limit, raise `APP_CPU_LIMIT`. If MongoDB is at
its memory limit, raise `MONGO_MEMORY_LIMIT` — it wants room for its working set,
and an undersized cache turns every query into disk I/O.

Slow requests are logged at `warn` with their duration:

```bash
docker compose -f compose/docker-compose.yml logs app | grep slow
```

### Disk filling up

```bash
docker system df -v | grep tasksense
```

Attachments dominate. Either move storage to MinIO or WebDAV
(Admin → Storage), lower `STORAGE_MAX_FILE_MB`, or add disk. Check that old
backups are being pruned — `find /mnt/backup -mtime +30 -delete`.

---

## Data

### Something was deleted

Admin → Trash. Deleted tasks are kept for 60 days and restore with their
comments and attachments.

### An attachment will not download

Check the storage provider is reachable (Admin → Storage → Test). If the
provider was reconfigured, or `STORAGE_SECRET` changed, its stored credentials
can no longer be decrypted and must be re-entered.

### Everything vanished after a restore

Almost certainly a restore of a `--no-config` backup onto a host with a
different `STORAGE_SECRET` — the data is there, the credentials to reach the
files are not. Restore the original secret.

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

Send it to your support contact with what you expected and what happened
instead.
