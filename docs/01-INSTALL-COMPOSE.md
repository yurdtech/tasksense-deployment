# Installing on a VM with Docker Compose

About 30 minutes on a prepared host, most of it spent deciding what to put in
`.env`.

---

## Before you start

| | |
| --- | --- |
| OS | Any Linux with Docker 24+ or Podman 4+ and the compose plugin |
| CPU / memory / disk | 2 cores, 4 GB, 20 GB minimum — see [11-SIZING](11-SIZING.md) |
| Hostname | A DNS name pointing at this host, and a certificate for it |
| Access | A user in the `docker` group; root only for the reverse proxy |

Check the host:

```bash
git clone https://github.com/yurdtech/tasksense-deployment.git
cd tasksense-deployment
./scripts/preflight.sh
```

It reports resources, port conflicts, `.env` permissions and whether the
registry is reachable. Fix anything it marks with `✗` before continuing.

---

## 1. Configure

```bash
cp compose/.env.example compose/.env
chmod 600 compose/.env
${EDITOR:-vi} compose/.env
```

The file explains every setting inline. Five have no default and the application
will not start without them:

```bash
TASKSENSE_VERSION=1.0.0                          # pin it; never "latest"
APP_URL=https://tasksense.bank.internal          # what users type
FIRST_ADMIN_EMAIL=admin@bank.internal            # becomes the administrator
STORAGE_SECRET=$(openssl rand -base64 32)        # encrypts stored credentials
MONGO_PASSWORD=$(openssl rand -base64 24)        # the database account
```

> **`STORAGE_SECRET` is not recoverable.** It encrypts the credentials you later
> enter for object storage and model providers. Back it up wherever you keep
> database passwords. A restore without it recovers unreadable credentials.

Then set how people sign in — Active Directory, OIDC, or local passwords only.
[05-IDENTITY](05-IDENTITY.md) has a walkthrough per provider. You can install
first with local passwords and connect the directory afterwards.

---

## 2. Install

**With access to the registry:**

```bash
echo "$TASKSENSE_REGISTRY_TOKEN" | docker login ghcr.io -u <username> --password-stdin
./scripts/install.sh
```

**Without:** download `tasksense-onprem-<version>.tar.gz`, `SHA256SUMS`,
`SHA256SUMS.sig` and `cosign.pub` from the
[releases page](https://github.com/yurdtech/tasksense-deployment/releases) on a
machine that has internet, then:

```bash
./scripts/verify-signature.sh tasksense-onprem-1.0.0.tar.gz   # do not skip
tar xzf tasksense-onprem-1.0.0.tar.gz
cd tasksense-onprem-1.0.0
cp compose/.env.example compose/.env && ${EDITOR:-vi} compose/.env
./scripts/install.sh --offline
```

**Into your own registry** (run where you can reach both):

```bash
./scripts/load-images.sh --registry harbor.bank.internal/tasksense
# then set TASKSENSE_IMAGE and MONGO_IMAGE in .env, and:
./scripts/install.sh
```

The script starts the stack and waits until the application answers its own
health check. If it does not, it prints the log — a configuration error is
reported in full on the first lines.

---

## 3. Put TLS in front

The container listens on `127.0.0.1:3000` and speaks plain HTTP. Terminate TLS
in front of it.

**Caddy** — obtains and renews certificates itself:

```caddyfile
tasksense.bank.internal {
    reverse_proxy localhost:3000
}
```

**nginx** — copy `examples/nginx.conf`. Two things it must get right:

```nginx
location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    client_max_body_size 25m;          # must match STORAGE_MAX_FILE_MB
}

# Live updates are server-sent events. Buffering them makes the interface
# appear frozen: changes arrive only when the buffer happens to flush.
location ~ ^/api/v1/(state|agents/events)/stream {
    proxy_pass http://127.0.0.1:3000;
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 24h;
    proxy_set_header Connection '';
    proxy_http_version 1.1;
}
```

Verify:

```bash
curl -fsS https://tasksense.bank.internal/api/v1/health
curl -fsS https://tasksense.bank.internal/api/v1/version
```

---

## 4. First sign-in

Open `https://tasksense.bank.internal`.

The account in `FIRST_ADMIN_EMAIL` exists and is an administrator, but **has no
password** — no default credential ships with the product. Get in one of two
ways:

- **Through your directory or IdP**, if configured: sign in with that address.
- **Set a local password**: choose "Create account", enter the same address and
  pick a password. The existing administrator account is upgraded, not
  duplicated.

Then, in Admin:

1. **Members** — invite your team, or let them sign in through the directory.
2. **Access control** — set the password policy and session duration.
3. **Storage** — point at MinIO or WebDAV if you do not want files on the volume.
4. **Backup** — confirm the nightly snapshot is running.

---

## 5. Backups

Configure this on day one, not after the first incident.

```bash
./scripts/backup.sh --output /mnt/backup/tasksense
```

Nightly, as the service account:

```cron
0 2 * * * cd /opt/tasksense-deployment && ./scripts/backup.sh --output /mnt/backup/tasksense >> /var/log/tasksense-backup.log 2>&1
```

`/mnt/backup` must be somewhere that survives this host. Then **rehearse a
restore** — a backup you have never restored is a hypothesis.
[07-BACKUP-DR](07-BACKUP-DR.md).

---

## Operating it

```bash
docker compose -f compose/docker-compose.yml logs -f app   # follow logs
./scripts/upgrade.sh 1.1.0                                 # upgrade, with rollback
./scripts/rollback.sh                                      # undo it
./scripts/backup.sh                                        # back up
./scripts/restore.sh <archive>                             # restore
./scripts/collect-diagnostics.sh                           # bundle for support
```

Start the whole stack on boot: both containers are `restart: unless-stopped`, so
enabling Docker at boot is enough.

```bash
sudo systemctl enable docker
```

---

## If something goes wrong

The application prints the reason it will not start on the first lines of its
log:

```bash
docker compose -f compose/docker-compose.yml logs app | head -40
```

A configuration problem is reported in full — every invalid setting at once,
each with what is wrong and what to do — so one edit and one restart fixes the
file. [10-TROUBLESHOOTING](10-TROUBLESHOOTING.md) covers the common ones.
