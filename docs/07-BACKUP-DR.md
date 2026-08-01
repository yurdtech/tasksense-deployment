# Backup and recovery

Set this up on day one. Then restore from it once, before you need to.

---

## Two different things, do not confuse them

| | What it is | Use it for |
| --- | --- | --- |
| **`scripts/backup.sh`** | Database dump + uploaded files + configuration | **Disaster recovery.** Rebuilds an installation from nothing. |
| The nightly snapshot in Admin → Backup | A JSON export of one workspace's content | Undoing a mistake inside the application |

The in-application snapshot deliberately excludes credentials, token hashes and
attachment contents, so it cannot rebuild an installation. It is useful, but it
is not your backup.

---

## Taking a backup

```bash
./scripts/backup.sh                                 # → ./backups/
./scripts/backup.sh --output /mnt/backup/tasksense  # somewhere that survives this host
./scripts/backup.sh --no-config                     # omit .env
```

Produces one `tar.gz` containing:

| | |
| --- | --- |
| `mongodb.archive.gz` | Everything: tasks, documents, users, history, settings |
| `app-data.tar.gz` | Uploaded files, agent workspaces, in-app snapshots |
| `env` | Your configuration, unless `--no-config` |
| `manifest.json` | Version and timestamp, checked at restore |

It refuses to write an archive whose database dump is implausibly small, so a
failed dump cannot quietly become a useless backup.

> **The archive contains `MONGO_PASSWORD` and `STORAGE_SECRET` in clear text.**
> Store it as you would a database dump. `--no-config` omits them — but then
> keep `STORAGE_SECRET` somewhere else, because a restore without it recovers
> credentials nobody can decrypt.

## Scheduling it

```cron
0 2 * * * cd /opt/tasksense-deployment && ./scripts/backup.sh --output /mnt/backup/tasksense >> /var/log/tasksense-backup.log 2>&1
```

`/mnt/backup` must not be a directory on the machine you are backing up. A copy
on the same disk survives a mistake; it does not survive the disk.

Retention — keep 30 days, and move the first of each month somewhere colder:

```bash
find /mnt/backup/tasksense -name 'tasksense-*.tar.gz' -mtime +30 -delete
```

Encrypting at rest, if your policy requires it:

```bash
./scripts/backup.sh --output /tmp/staging
gpg --encrypt --recipient backup@bank.internal /tmp/staging/tasksense-*.tar.gz
mv /tmp/staging/*.gpg /mnt/backup/ && shred -u /tmp/staging/*.tar.gz
```

---

## Restoring

```bash
./scripts/restore.sh /mnt/backup/tasksense/tasksense-20260801-020000Z.tar.gz
```

It shows what the archive is and where it is going, asks twice, and **takes a
backup of the current state first** — so a restore aimed at the wrong host is
itself recoverable. It refuses an archive from a newer version than the one
installed; upgrade first, then restore.

Restoring into a *newer* version is normal: startup migrations bring the schema
forward.

---

## Rehearsing it

Do this once before go-live and once a year after. Twenty minutes.

```bash
# On a scratch VM, or the same host with a different HTTP_PORT and volume names.
./scripts/install.sh
./scripts/restore.sh /mnt/backup/tasksense/<latest>.tar.gz

curl -fsS http://127.0.0.1:3000/api/v1/health
# Then sign in and check: are the tasks there, the documents, the members,
# the attachments? Open one attachment — that is the part a database-only
# backup silently loses.
```

Record how long it took. That number is your real RTO, not the one in the table
below.

---

## Recovery targets

With a nightly backup on separate storage:

| | Target | What it depends on |
| --- | --- | --- |
| **RPO** — work at risk | 24 hours | Backup frequency. Run it more often if that is too much. |
| **RTO** — time to recover | 1 hour | 15 min provision + 10 min install + restore time |

Restore time is dominated by attachment volume. A 10 GB archive restores in
minutes; 500 GB does not.

To narrow the RPO below a day, either run `backup.sh` more often, or run MongoDB
as a replica set so a single node's loss costs nothing.

---

## Scenarios

**The application will not start after a change.** Not a restore. Roll the
version back, or fix the configuration — the log names the problem on its first
lines.

```bash
./scripts/rollback.sh
```

**An upgrade went wrong.** `upgrade.sh` already took a backup and already tried
to roll itself back. If the previous version is running again, nothing was lost.
If neither version starts:

```bash
ls -t backups/ | head -3
./scripts/restore.sh backups/<the one from just before the upgrade>
```

**Someone deleted a lot of work.** Try Admin → Trash first — deleted tasks are
kept for 60 days and restore with their comments and attachments. Only if that
is not enough, restore a backup into a scratch instance, find what is missing,
and copy it across. Restoring over a live installation to recover one item
discards everything done since the backup.

**The host is gone.** Provision a new one, install the same version, restore.
This is the path the rehearsal above exercises.

**The database is corrupt.** Stop the application, restore. Corruption normally
means the storage is failing — move to different disks before restoring onto
them.

---

## Backing up MongoDB directly

If your DBAs already back up MongoDB and want to continue:

```bash
mongodump --uri="mongodb://tasksense:<password>@localhost:27017/tasksense?authSource=admin" \
  --archive=/mnt/backup/tasksense-$(date -u +%Y%m%d).archive --gzip
```

You still need the uploaded files and `STORAGE_SECRET`:

```bash
docker run --rm -v tasksense-app-data:/data -v /mnt/backup:/out alpine \
  tar czf /out/tasksense-files-$(date -u +%Y%m%d).tar.gz -C /data .
```

A database-only backup restores an installation with every attachment missing.
This is the most common way an on-premise backup turns out to be incomplete.
