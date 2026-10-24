# Installing on a VM with Docker Compose

A complete, copy-paste walkthrough. Follow the steps in order; each command is
followed by what it should print. A first install takes about 30 minutes, most
of it waiting for downloads and for your reverse proxy change.

**What you end up with:** on one Linux server, the TaskSense application (API
and web interface on one port), a one-shot `migrate` service that prepares the
database before the application starts, and — unless you bring your own — a
MongoDB container. Optionally, a separate import worker for a Jira migration.

> **Minimum version for this guide: TaskSense 1.1.0.** For a 1.0.x install,
> upgrade first ([08-UPGRADE](08-UPGRADE.md)); everything here assumes the
> 1.1.0 deployment files.

There are two ways through it, and they produce the same installation:

- **The guided installer** — `./tasksense` asks the questions, tests your
  answers against your real directory, mail relay and database, writes
  `compose/.env` and runs `scripts/install.sh`. About fifteen minutes.
- **By hand** — the steps below. Read them if you are automating, if you want
  to know what the wizard writes, or if change control wants every command on
  paper. The wizard does exactly this.

Banks: before the maintenance window, work through
[18-PRE-INSTALL-CHECKLIST](18-PRE-INSTALL-CHECKLIST.md) with your network,
directory and database teams. Almost every failed first install is a firewall
rule, a certificate or a database account that was not ready.

---

## 0. Before you start

**A 64-bit Linux server** (x86_64 or arm64) with:

- **Docker Engine 24+ and Docker Compose v2.20 or newer** — the stack uses
  Compose profiles and optional dependencies, which older Compose does not
  understand:
  ```bash
  docker --version
  docker compose version
  ```
  Expected: two version lines, the second `v2.20.0` or newer. Podman 4+ works
  too, with `docker-compose` v2.20+ as its compose provider; the scripts
  detect it.
- **Resources** for your size — [11-SIZING](11-SIZING.md). The smallest
  supported host is 2 vCPU, 4 GB RAM and 40 GB of disk for Docker's data root.
- **Disk for a Jira import**, if you will import a Jira site backup: free space
  on Docker's data root of **twice the backup's size**, on top of the above.
- **A DNS name** for the installation and a **TLS certificate** for it from
  your CA, installed on your reverse proxy (nginx, HAProxy, F5…).
- A user in the `docker` group; root only for the reverse proxy.

**From us, before you begin:**

| What | Used for |
| --- | --- |
| **Registry token** | Pulling the private images (step 2). Read-only. |
| **Version number** | `TASKSENSE_VERSION` (step 4), at least `1.1.0`. |
| **Licence key** | A single `tsl_…` line for `LICENSE_KEY` (step 4). Optional — without it the free-tier limits apply. |

No internet on the server? Use the offline bundle instead of steps 1–2 —
[13-REGISTRY-ACCESS](13-REGISTRY-ACCESS.md#no-route-out-air-gapped), then
continue at step 3.

---

## 1. Get the deployment files

```bash
git clone https://github.com/yurdtech/tasksense-deployment.git
cd tasksense-deployment
git checkout v1.1.0          # the release you were told to install
```


This repository holds **only** deployment files — the Compose stack, the Helm
chart, scripts and these documents. There is no application source; the image
comes from our registry. Keep the clone: every upgrade starts with a
`git pull` here, because releases change these files too.

> No git on the server? Each release on
> <https://github.com/yurdtech/tasksense-deployment/releases> carries
> `tasksense-deployment-<version>.tar.gz` — the same files, no images — with
> `SHA256SUMS`, `SHA256SUMS.sig` and `cosign.pub`.

Every command below runs from this directory.

---

## 2. Log in to the image registry (one time)

The image is private. Authenticate Docker with the token we gave you. The
username is always `yurdtech` — **not** your own; you do not need a GitHub
account.

```bash
echo '<TOKEN>' | docker login ghcr.io -u yurdtech --password-stdin
```

Expected:

```
Login Succeeded
```

`denied` or `unauthorized` means the token is wrong, expired, or was pasted
with a stray newline — [13-REGISTRY-ACCESS](13-REGISTRY-ACCESS.md#troubleshooting).
Docker stores the credential in `~/.docker/config.json`; nothing in this
repository writes it anywhere else.

---

## 3. Choose your database

**Bundled (default).** TaskSense runs MongoDB 7 in a container beside the
application, on an internal network with no published port. Nothing to
decide — continue to step 4.

**Your own.** If your DBAs run MongoDB (a replica set, with their backups and
monitoring), point TaskSense at it instead. It is two lines in `.env`:

```dotenv
COMPOSE_PROFILES=                      # drop "bundled-mongo"
MONGODB_URI=mongodb://tasksense:<pw>@mongo-1.bank.internal:27017,mongo-2.bank.internal:27017,mongo-3.bank.internal:27017/?replicaSet=rs0&tls=true&tlsCAFile=/certs/bank-ca.pem&authSource=admin
```

Read [16-EXTERNAL-DATABASES](16-EXTERNAL-DATABASES.md) first — the account,
its roles, TLS with your CA and how to verify the connection. The settings go
into the file you create in the next step. You never edit
`docker-compose.yml`.

---

## 4. Create your configuration

```bash
cp compose/.env.example compose/.env
chmod 600 compose/.env        # it will hold passwords and the storage key
${EDITOR:-vi} compose/.env
```

The file explains every setting where it appears. These have no default:

```dotenv
TASKSENSE_VERSION=1.1.0                          # pin it; never "latest"
APP_URL=https://tasksense.bank.internal          # what users type
CORS_ALLOWED_ORIGINS=https://tasksense.bank.internal
FIRST_ADMIN_EMAIL=tasksense-admin@bank.internal  # becomes the administrator
STORAGE_SECRET=                                  # openssl rand -base64 32
MONGO_PASSWORD=                                  # openssl rand -hex 24 (bundled MongoDB only)
```

Generate the two secrets:

```bash
openssl rand -base64 32     # → STORAGE_SECRET
openssl rand -hex 24        # → MONGO_PASSWORD  (hex: it goes into a URI)
```

> **`STORAGE_SECRET` is not recoverable.** It encrypts every credential you
> later store in the application — LDAP bind passwords, SMTP, object storage,
> model providers. Put a copy in your secrets vault next to the database
> backups. A restore without it gives you credentials nobody can decrypt.

> **`MONGO_PASSWORD` is applied once**, when the bundled database volume is
> first created. Changing it in `.env` later does not change it inside MongoDB
> — see [10-TROUBLESHOOTING](10-TROUBLESHOOTING.md#authentication-failed-with-the-right-password-in-env).

The template already carries the values we recommend for a bank — keep them
(the reasons are in [17-ENVIRONMENT](17-ENVIRONMENT.md)) and add your licence:

```dotenv
SESSION_TTL_HOURS=12            # one working day; without the line the application uses 30 days
SWAGGER_ENABLED=false           # without the line the API browser is ON
AGENT_EXECUTOR=off              # the only supported value
AGENT_DISPATCHER=off            # until an AI pilot is approved
LICENSE_KEY=tsl_...             # from us
```

**Your CA.** If MongoDB, the mail relay, the OIDC provider or the model
gateway use certificates issued by your own CA, put the CA bundle (root and
issuing CAs, PEM, concatenated) in `compose/certs/` and point the application
at it. The folder is mounted read-only at `/certs` in every container:

```bash
cp /etc/pki/ca-trust/source/anchors/bank-ca.pem compose/certs/bank-ca.pem
```

```dotenv
NODE_EXTRA_CA_CERTS=/certs/bank-ca.pem      # the path INSIDE the container
```

The directory (LDAP) CA does not go here — it is pasted as text per directory
in Admin → Authentication (step 9).

Sign-in methods are configured later: OIDC in this file
([05-IDENTITY](05-IDENTITY.md#oidc--keycloak-ad-fs-entra-id-okta)), LDAP in the
application. You can install with local passwords first.

Every other setting has a safe default. Full reference:
[17-ENVIRONMENT](17-ENVIRONMENT.md).

---

## 5. Check the configuration and the host

```bash
./scripts/preflight.sh
```

It reads `.env` and the host and reports anything that would fail once
containers start: Docker and Compose versions, placeholders left in, duplicated
keys, the file's permissions, a short `STORAGE_SECRET`, `COMPOSE_PROFILES`
that do not match `MONGODB_URI`, an external database that does not answer, a
`tlsCAFile` or `NODE_EXTRA_CA_CERTS` file missing from `certs/`, an
`AGENT_EXECUTOR` other than `off`, free disk, a port already taken, and
whether Compose accepts the file. It changes nothing.

Expected ending:

```
✓ preflight passed.
```

Lines marked `✗` block the install — the summary then reads
`✗ <n> problem(s) must be fixed first.` and the script exits 1; fix them and
run it again. Lines marked `!` are warnings (for example `SWAGGER_ENABLED`
still on, or less free disk than a Jira import needs); the summary counts them
(`✓ preflight passed. 2 warning(s) — review them above.`). They do not stop
you, but read them.

---

## 6. Install

```bash
./scripts/install.sh
```

It runs the preflight again, pulls the images, starts MongoDB (if bundled),
runs the `migrate` service once, starts the application only after the
migration succeeded, and waits until the application answers its health check.

Expected ending (abridged):

```
==> Installed
  {"version":"1.1.0","commit":"…","builtAt":"…","service":"tasksense-api"}

  TaskSense is running.

  Address        https://tasksense.bank.internal
  Administrator  tasksense-admin@bank.internal
  Containers     tasksense-app tasksense-mongo
```

If it stops at `did not become healthy`, it prints the log: a configuration
problem is reported in full on the first lines.
[10-TROUBLESHOOTING](10-TROUBLESHOOTING.md) covers the common ones.

> **The same by hand**, if your runbook wants plain Compose commands:
> ```bash
> docker compose -f compose/docker-compose.yml pull
> docker compose -f compose/docker-compose.yml up -d
> ```
> Compose reads `compose/.env`, including `COMPOSE_PROFILES`, on its own.

---

## 7. First-run checks

Run each command and compare with the expected result.

**a) The services:**

```bash
docker compose -f compose/docker-compose.yml ps -a
```

Expected — `tasksense-app` **running (healthy)**; with the bundled database
`tasksense-mongo` **running (healthy)**; `tasksense-migrate` **Exited (0)**.
The migrator is a one-shot job: exited with 0 is correct. (`-a` matters —
without it Compose hides exited containers.) With the import worker,
`tasksense-worker` **running** as well.

**b) The migration:**

```bash
docker compose -f compose/docker-compose.yml logs migrate
```

Expected, on a fresh database: `✓ applied <n>: …` listing the migrations;
on later starts: `✓ nothing pending — schema is up to date`.

**c) Health, from the server itself:**

```bash
curl -s http://127.0.0.1:3000/api/v1/health
```

Expected (HTTP 200):

```json
{"status":"ok","service":"tasksense-api","timestamp":"…","database":"up","indexes":"ready","schema":{"state":"current"}}
```

`"indexes":"building"` right after a restore of a large database is normal —
big indexes build in the background while the application serves. A **503**
means the application cannot reach MongoDB.

**d) The version:**

```bash
curl -s http://127.0.0.1:3000/api/v1/version
```

Expected: `{"version":"1.1.0","commit":"…","builtAt":"…","service":"tasksense-api"}`.
Confirm a deployment by the commit, not only the tag.

To watch the log live:

```bash
docker compose -f compose/docker-compose.yml logs -f app
```

---

## 8. Put TLS in front

The container listens on `127.0.0.1:3000` and speaks plain HTTP. Terminate TLS
on your reverse proxy. Ready-made configurations:

- **nginx** — [`examples/nginx.conf`](../examples/nginx.conf)
- **Caddy** — [`examples/Caddyfile`](../examples/Caddyfile)
- **HAProxy, F5, others** — reproduce the settings below.

Whatever the proxy, it must:

| Setting | Why |
| --- | --- |
| Send `Host`, `X-Forwarded-For`, `X-Real-IP`, `X-Forwarded-Proto` on **every** path | The application trusts one proxy hop for the client address (rate limits, sign-in lockout) and builds links from the scheme. |
| Not buffer `/api/v1/state/stream` and `/api/v1/agents/events/stream`, read timeout 24 h | Live updates are server-sent events. Buffered, the interface looks frozen. |
| Allow 21 GB bodies, unbuffered, 4 h timeouts on the upload routes; 25 MB elsewhere | Jira site backups and attachments. The routes are listed in `examples/nginx.conf`. |
| Keep idle upstream connections for less than 65 s | The application closes idle sockets at 65 s; the proxy must close first. |
| Not add its own CSP / HSTS / frame headers | The application sets them; two sets contradict each other. |
| Not log query strings | Live updates and video playback authenticate with a short-lived `?ticket=`. |

Install and reload (nginx):

```bash
sudo cp examples/nginx.conf /etc/nginx/conf.d/tasksense.conf
sudo ${EDITOR:-vi} /etc/nginx/conf.d/tasksense.conf    # host name, certificate paths
sudo nginx -t && sudo systemctl reload nginx
```

Expected: `nginx: configuration file /etc/nginx/nginx.conf test is successful`.

Verify from a workstation:

```bash
curl -fsS https://tasksense.bank.internal/api/v1/health
curl -fsS https://tasksense.bank.internal/api/v1/version
```

Expected: the same two answers as in step 7. Then open the address in two
browser windows side by side and move a card on the board in one — it should
move in the other within a second. If it only moves after a refresh, the proxy
is buffering the streams.

---

## 9. First sign-in

Open `https://tasksense.bank.internal`.

The `FIRST_ADMIN_EMAIL` account exists and is an administrator, but **has no
password** — no default credential ships with the product. Claim it one of two
ways:

- **Through your directory or IdP**, once configured: sign in with that
  address.
- **Set a local password**: choose **Create account**, enter the same address
  and a password. The existing administrator is claimed, not duplicated.
  (Self-registration is otherwise closed on-premise.)

Keep that local password in your break-glass procedure — it is how you get in
when the directory is down.

Then, in **Admin**:

1. **Authentication** — add your directories (LDAPS, CA pasted as text), run
   each one's **Test connection**, save. [05-IDENTITY](05-IDENTITY.md)
2. **Security** — confirm the session lifetime (12 h) and set the minimum
   password length for local accounts.
3. **Email delivery** — send a test message.
4. **Storage** — leave attachments on the volume, or connect S3 / MinIO /
   WebDAV. An internal endpoint's host must be in `EGRESS_ALLOWLIST` first
   ([04-CONFIGURATION](04-CONFIGURATION.md#internal-hosts-the-application-calls-egress_allowlist)).
5. **Users** — invite your team, or let them sign in through the directory.

---

## 10. Backups

Configure this on day one, not after the first incident.

```bash
./scripts/backup.sh --output /mnt/backup/tasksense
```

Expected ending:

```
==> Done
  ✓ /mnt/backup/tasksense/tasksense-20261016-020000Z.tar.gz
  1.2G, taken live
```

Nightly, as the service account (`crontab -e`), keeping the last 30:

```cron
0 2 * * * cd /opt/tasksense-deployment && ./scripts/backup.sh --output /mnt/backup/tasksense --keep 30 >> /var/log/tasksense-backup.log 2>&1
```

`/mnt/backup` must be storage that survives this host. It works the same for
the bundled and for your own MongoDB. Then **rehearse a restore** on a second
VM — a backup you have never restored is a hypothesis.
[07-BACKUP-DR](07-BACKUP-DR.md)

---

## 11. Secure the install

Before handing it to users — the full list, with the reasoning, is in
[06-SECURITY](06-SECURITY.md#hardening-checklist):

- `compose/.env` mode `600`, owned by the service account, in no repository.
- `BIND_ADDRESS=127.0.0.1` unless the proxy is another host (then that
  interface, and a firewall rule allowing only the proxy).
- `SWAGGER_ENABLED=false`, `SESSION_TTL_HOURS=12`, `AGENT_EXECUTOR=off`,
  `OWNER_EMAILS` empty.
- Every directory on `ldaps://` with your CA pasted.
- Logs shipped to your SIEM (`LOG_FORMAT=json`, the default).
- Metrics on, with a token, scraped only from the monitoring segment
  ([09-MONITORING](09-MONITORING.md)).
- Image signature verified ([13-REGISTRY-ACCESS](13-REGISTRY-ACCESS.md#verify-what-you-pulled)).

---

## Optional: the import worker, for a Jira migration

Landing a large Jira site backup is the heaviest thing TaskSense does. In the
API process it competes with every user for memory and CPU. The import worker
is a second process from the same image that takes over **only** that work:
if a landing exhausts it, the worker restarts and resumes from its last
checkpoint, and the API never notices.

Turn it on for the migration window:

```dotenv
COMPOSE_PROFILES=bundled-mongo,import-worker    # or just import-worker with your own MongoDB
WORKER_ROLE=api                                 # the API must stop running landings itself
```

```bash
./scripts/preflight.sh
docker compose -f compose/docker-compose.yml up -d
docker compose -f compose/docker-compose.yml logs worker | head -5
```

Expected: `[tasksense-worker] up — landings sweep runs here; interactive workloads do not`.

`preflight.sh` refuses `import-worker` without `WORKER_ROLE=api`. The worker
has no published port and needs about 6 GB of RAM (`WORKER_MEMORY_LIMIT`)
while it runs. Uploads are staged on the data volume (`/app/api/data/tmp`),
shared by both processes — keep **twice the backup's size** free there.

When the migration is done, remove `import-worker` from `COMPOSE_PROFILES`,
set `WORKER_ROLE=all` (or delete the line) and `up -d` again. Sizing and the
reasoning: [15-SCALING-AND-HA](15-SCALING-AND-HA.md).

---

## Operating it

```bash
./tasksense status                                         # health, version, containers
docker compose -f compose/docker-compose.yml logs -f app   # follow the log
./scripts/upgrade.sh 1.2.0                                 # backup, migrate, restart, verify
./scripts/rollback.sh                                      # back to the previous version and its data
./scripts/backup.sh                                        # database + files + configuration
./scripts/restore.sh <archive>                             # restore from a backup
./scripts/collect-diagnostics.sh                           # bundle for support (secrets masked)
```

Every service is `restart: unless-stopped`, so enabling Docker at boot starts
TaskSense with the server:

```bash
sudo systemctl enable docker
```

Upgrading: [08-UPGRADE](08-UPGRADE.md) — always `git pull` (or the new
deployment archive) first.

---

## Stopping and removing

```bash
docker compose -f compose/docker-compose.yml stop      # pause everything, keep containers and data
docker compose -f compose/docker-compose.yml down      # remove containers; DATA is kept
```

Remove it completely, data included:

```bash
./scripts/backup.sh                                     # last chance
docker compose -f compose/docker-compose.yml down -v    # -v DELETES the volumes
rm -f compose/.env                                      # holds the secrets
```

`down -v` deletes `tasksense-app-data` (attachments, staged uploads, snapshots)
and `tasksense-mongo-data` (the bundled database). Backups under `./backups/`
and anything in `compose/certs/` are plain files it never touches. An external
database is not touched either — drop the `tasksense` database there with your
DBA.

---

## Where to go next

| Task | Guide |
| --- | --- |
| Every setting explained | [17-ENVIRONMENT](17-ENVIRONMENT.md) |
| Your own MongoDB | [16-EXTERNAL-DATABASES](16-EXTERNAL-DATABASES.md) |
| Directory and SSO sign-in | [05-IDENTITY](05-IDENTITY.md) |
| Backups and disaster recovery | [07-BACKUP-DR](07-BACKUP-DR.md) |
| Capacity and availability | [11-SIZING](11-SIZING.md), [15-SCALING-AND-HA](15-SCALING-AND-HA.md) |
| Something is wrong | [10-TROUBLESHOOTING](10-TROUBLESHOOTING.md) |
