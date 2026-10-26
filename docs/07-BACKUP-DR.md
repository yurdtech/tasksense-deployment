# Backup and disaster recovery

Set this up on day one. Then restore from it once, on another machine, before
you need to.

**Targets** with a nightly backup on storage that survives the host:
**RPO 24 hours, RTO 1 hour.** What they depend on is at the
[end of this page](#recovery-targets).

---

## What has to be backed up

| | Where | Without it |
| --- | --- | --- |
| **The database** | MongoDB, database `MONGODB_DB` (`tasksense`) | Nothing — every task, document, user, setting and audit entry is here |
| **Attachments** | the data volume (`tasksense-app-data`, `/app/api/data/uploads`) — or your object storage, if configured in Admin → Storage | Every file is gone; the database still lists them. The most common way an on-premise backup turns out incomplete |
| **`STORAGE_SECRET`** | `compose/.env`, or the Kubernetes Secret | Stored credentials (LDAP bind passwords, SMTP, object storage, model providers) cannot be decrypted after a restore |
| **The rest of the configuration** | `compose/.env`, `compose/certs/` | Rebuildable by hand, slowly |

Two different things, do not confuse them:

| | What it is | Use it for |
| --- | --- | --- |
| **`scripts/backup.sh`** | Database dump + attachments + configuration, in one archive | **Disaster recovery.** Rebuilds an installation from nothing |
| Admin → Backup & export | The application's nightly JSON snapshot of the workspace's content (last 14 kept) | Undoing a mistake, exporting content. It deliberately excludes credentials, token hashes and attachments, so it cannot rebuild an installation |

---

## Docker Compose

### 1. Take a backup

```bash
./scripts/backup.sh --output /mnt/backup/tasksense
```

It works the same for the bundled MongoDB and for your own: for an external
database it runs `mongodump` in a throwaway container from `MONGO_IMAGE`,
reaching the database the way the application does, with the password passed
inside the container — never on a command line where `ps` would show it.

By default the application keeps running and the dump is taken **live** —
fine for a nightly copy, though a write landing mid-dump may be half in it.
`--stop-app` stops the application and the worker for the duration (a short
outage) and gives an exact copy; `upgrade.sh` always does that.

Expected ending:

```
==> Done
  ✓ /mnt/backup/tasksense/tasksense-20261016-020000Z.tar.gz
  1.2G, taken live
```

The archive (mode `600`, with a `.sha256` file beside it) contains:

| | |
| --- | --- |
| `mongodb.archive.gz` | `mongodump --archive --gzip` of `MONGODB_DB` |
| `app-data.tar.gz` | The data volume — attachments, the application's snapshots — **without** the upload staging area (`data/tmp`, where a staged Jira backup can be 20 GB) |
| `env` | `compose/.env`, unless `--no-config` |
| `manifest.json` | TaskSense version, date, database mode (bundled or external) and name, and whether it was taken with the application stopped — checked at restore |

It refuses to write an archive whose database dump is implausibly small (the
wrong `MONGODB_DB`, most often), so a failed dump cannot quietly become a
useless backup. It stages the archive in the output directory, not in `/tmp`,
so that directory needs room for about twice one archive while it runs.

> **The archive contains `STORAGE_SECRET` and the database password in clear
> text.** Store it as you would a database dump, and encrypt it (below).
> `--no-config` leaves `.env` out — then keep `STORAGE_SECRET` in your vault,
> because a restore without it recovers credentials nobody can decrypt.

### 2. Schedule it, off the host

`crontab -e` as the service account:

```cron
0 2 * * * cd /opt/tasksense-deployment && ./scripts/backup.sh --output /mnt/backup/tasksense --keep 30 >> /var/log/tasksense-backup.log 2>&1 && echo "tasksense_backup_last_success_timestamp_seconds $(date +\%s)" > /var/lib/node_exporter/textfile/tasksense_backup.prom
```

- `/mnt/backup` must be storage that survives this host — NFS, a backup
  appliance's share, object storage synchronised by your backup agent. A copy
  on the same disk survives a mistake; it does not survive the disk.
- `--keep 30` keeps the newest 30 nightly archives in that directory (default
  14; `0` keeps everything). Rotation only touches archives of the same kind,
  so it never removes the `tasksense-pre-upgrade-…` copies `upgrade.sh` takes.
  Move the first of each month somewhere colder if policy wants longer.
- The part after `&&` feeds the **backup-age alert**
  ([09-MONITORING](09-MONITORING.md#backup-age)); it runs only when the backup
  succeeded. Drop it if you do not run node_exporter.

Encrypting at rest, if your policy requires it:

```bash
./scripts/backup.sh --output /var/tmp/tasksense-staging
gpg --encrypt --recipient backup@corp.internal /var/tmp/tasksense-staging/tasksense-*.tar.gz
mv /var/tmp/tasksense-staging/*.gpg /mnt/backup/tasksense/
shred -u /var/tmp/tasksense-staging/tasksense-*.tar.gz
```

Keep the private key of `backup@corp.internal` where a disaster cannot take it
along with the server.

### 3. Restore

```bash
./scripts/restore.sh /mnt/backup/tasksense/tasksense-20261016-020000Z.tar.gz
```

What it does, in order:

1. Shows what the archive is (version, date, database mode) and where it is
   going, and asks for confirmation (`--yes` for automation).
2. Stops the application and the import worker — nothing writes while data is
   replaced.
3. Takes a safety backup of the current state — a restore aimed at the wrong
   host or the wrong archive is itself recoverable.
4. **Drops the whole `MONGODB_DB` database**, then restores the dump into it —
   bundled, or your own MongoDB through a tools container. Nothing from the
   current state survives next to the restored one.
5. Replaces the files on the data volume.
6. Starts the stack. The `migrate` service runs first, so a backup from an
   older version is brought forward before the application starts.

`compose/.env` is never overwritten. If the archive's `STORAGE_SECRET` differs
from the installed one, the archive's configuration is saved beside the
backups and the restore says so — reconcile it before users sign in, or
stored credentials will not decrypt.

Expected ending: the version line and `==> Restored`, then

```bash
curl -s http://127.0.0.1:3000/api/v1/health
```

answers `"status":"ok"`.

It **refuses an archive from a newer version** than the one installed —
migrations only go forward, and older code against a newer schema misbehaves
quietly. Install that version first, then restore. Restoring an older archive
into a newer version is normal.

---

## Your own MongoDB

`backup.sh` covers it (see above), and `upgrade.sh` takes one before every
upgrade. For a narrower RPO than nightly, your DBAs' own tooling — snapshots,
Ops Manager / Cloud Manager, point-in-time recovery on the replica set — is the
better primary backup. Then keep running `backup.sh` (or at least back up the
data volume and `STORAGE_SECRET`): a database-only backup restores an
installation with every attachment missing.

`restore.sh` restores through the application's own `MONGODB_URI`, so that
account needs `dropDatabase` on `MONGODB_DB` — the `dbAdmin` role in
[16-EXTERNAL-DATABASES](16-EXTERNAL-DATABASES.md#1-create-the-account). If it
has `readWrite` only, restore the database as your DBA, then the files:

```bash
mongorestore --uri="mongodb://dba@mongo-1.corp.internal:27017/?replicaSet=rs0&authSource=admin&tls=true&tlsCAFile=/etc/pki/corp-ca.pem" \
  --nsInclude='tasksense.*' --drop --archive=mongodb.archive.gz --gzip
```

(`mongodb.archive.gz` is inside the `backup.sh` archive: `tar xzf` it first.)
Then put `app-data.tar.gz` back into the `tasksense-app-data` volume with the
application stopped.

---

## Kubernetes and OpenShift

| | How |
| --- | --- |
| Database, nightly | The chart's backup CronJob (`backup.enabled: true`) dumps `MONGODB_DB` to its own PVC (`backup.persistence`, kept on `helm uninstall`), with retention. Copy that PVC's contents off the cluster with your backup tooling. |
| Database, before every upgrade | `migrations.backupBeforeUpgrade` (on when backups are enabled) dumps to the same PVC before the migration Job runs. |
| Attachments | On the data PVC — the CronJob does **not** cover them. Use VolumeSnapshots or your backup agent (Velero, Kasten, Trilio…) for that PVC, or put attachments on object storage. |
| `STORAGE_SECRET` | In your vault, with the Secret it came from. |

Restore procedure on Kubernetes:
[02-INSTALL-KUBERNETES › Restoring a dump](02-INSTALL-KUBERNETES.md#restoring-a-dump).

---

## Rehearsing it

Do this once before go-live, and at least once a year — quarterly is better for
production. Twenty minutes plus restore time.

On a **scratch VM**, not the production host (the Compose project and volume
names are fixed — `tasksense`, `tasksense-app-data`, `tasksense-mongo-data` —
so a second install on the same host would reattach the live data):

```bash
git clone https://github.com/yurdtech/tasksense-deployment.git && cd tasksense-deployment
git checkout v<the version production runs>
tar xzf /mnt/backup/tasksense/<latest>.tar.gz -O ./env > compose/.env   # or your vault copy
chmod 600 compose/.env
./scripts/preflight.sh
./scripts/install.sh
./scripts/restore.sh /mnt/backup/tasksense/<latest>.tar.gz
curl -fsS http://127.0.0.1:3000/api/v1/health
```

Then sign in and check: are the tasks there, the documents, the members? Does
directory sign-in work (it proves `STORAGE_SECRET` decrypted the bind
password)? **Open an attachment** — that is the part a database-only backup
silently loses. Check the licence state in Admin → Plan & billing.

Record how long it took. That number is your real RTO, not the one in the
table below.

---

## Recovery targets

| | Target | What it depends on |
| --- | --- | --- |
| **RPO** — work at risk | 24 hours | Backup frequency. Run `backup.sh` more often, or use point-in-time backups of an external replica set. |
| **RTO** — time to recover | 1 hour | 15 min provision + 10 min install + restore time + checks |

Restore time is dominated by attachment volume: a 10 GB archive restores in
minutes; 500 GB does not. Put attachments on replicated object storage to take
them out of the restore path.

A replica set protects against losing a database **node**; it does not protect
against a mistake, which replicates instantly. It complements backups; it does
not replace them.

---

## Scenarios

**The application will not start after a configuration change.** Not a
restore. The log names the problem on its first lines; fix `.env` and
`docker compose -f compose/docker-compose.yml up -d`.

**An upgrade went wrong.** `upgrade.sh` took a backup before migrating and, if
the new version fails after migrations ran, offers to restore it together with
the previous version (`--yes` answers for you). If you declined, or it could
not:

```bash
./scripts/rollback.sh
```

restores the pre-upgrade backup it recorded **and** the previous version.
Details and the `--app-only` case: [08-UPGRADE](08-UPGRADE.md#rolling-back).

**Someone deleted a lot of work.** Try Admin → Trash first — deleted tasks and
projects are kept for 60 days and restore with their comments and attachments.
Only if that is not enough, restore a backup into a **scratch** instance, find
what is missing, and copy it across. Restoring over the live installation to
recover one item discards everything done since the backup.

**The host is gone.** Provision a new one, install the **same** version,
restore. This is the path the rehearsal exercises.

**The database is corrupt.** Stop the application, restore. Corruption usually
means failing storage — move to different disks before restoring onto them.
