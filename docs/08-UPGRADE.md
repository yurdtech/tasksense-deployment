# Upgrading

```bash
./scripts/upgrade.sh 1.1.0
```

That is the whole procedure. It backs up first, switches version, waits for the
new one to become healthy, and **puts the old one back if it does not**.

---

## What it actually does

1. Refuses a version jump (see below).
2. Runs `backup.sh`. If the backup fails, the upgrade stops — an upgrade without
   a restore point is not worth the risk.
3. Pulls the new image, or loads it from `./images` with `--offline`.
4. Records the current version for `rollback.sh`, then switches `.env`.
5. Starts the new version and polls its health endpoint for up to four minutes.
6. On success, done. On failure, restores the previous `.env`, restarts, and
   tells you where the backup is.

Migrations run at startup, inside step 5, before the application reports ready.

Expect a minute or two of downtime. There is no zero-downtime path on a
single-node install; on Kubernetes, use a rolling update.

---

## One minor version at a time

`1.0.x → 1.1.x → 1.2.x`, not `1.0 → 1.5`. The script enforces it.

Migrations are written to run in order. Skipping a release skips its migration,
which usually does not fail loudly — it leaves the database subtly wrong.

Patch releases (`1.1.0 → 1.1.3`) can be taken directly.

Crossing a major version asks for confirmation and expects you to have read the
release notes. Assume a longer window and rehearse it on a copy first.

---

## Before you upgrade

- [ ] Read the release notes for every version between yours and the target
- [ ] Confirm last night's backup exists and is a plausible size
- [ ] Tell users — there will be a short outage
- [ ] For a major version: rehearse on a restored copy

## After

```bash
curl -fsS https://tasksense.bank.internal/api/v1/version
```

Sign in, open a board, open a document, download an attachment. Then watch the
log for a few minutes:

```bash
docker compose -f compose/docker-compose.yml logs -f app
```

---

## Rolling back

```bash
./scripts/rollback.sh          # to the previous version
./scripts/rollback.sh 1.0.0    # to a specific one
```

**This reverts the application only.** If the newer version ran a migration,
the older code may not understand the database it finds. When that is a risk —
and it usually is, across a minor version — restore the backup instead:

```bash
ls -t backups/ | head -3
./scripts/restore.sh backups/<the one from just before the upgrade>
```

`upgrade.sh` names that file for you when it fails.

---

## Air-gapped upgrades

Download the new release archive where you have internet, verify it, carry it
in, then:

```bash
tar xzf tasksense-onprem-1.1.0.tar.gz
cd tasksense-onprem-1.1.0
cp /opt/tasksense-deployment/compose/.env compose/.env    # keep your settings
./scripts/upgrade.sh 1.1.0 --offline
```

Or mirror the new image into your registry first
([13-REGISTRY-ACCESS](13-REGISTRY-ACCESS.md)) and upgrade normally.

---

## Version support

The current minor release and the one before it get security fixes. Staying
more than two minors behind means a multi-step upgrade to get current — which
works, but takes an afternoon rather than ten minutes.

---

## If an upgrade fails

`upgrade.sh` has already tried to roll itself back. Read what it printed.

**Old version running again** — nothing was lost. The log above the rollback
says why the new one would not start; usually a setting the new version
requires. Fix `.env` and try again.

**Neither version starts** — restore:

```bash
./scripts/restore.sh backups/<from just before the upgrade>
```

**Started, but something is wrong** — collect diagnostics before rolling back,
so the problem can be fixed rather than just avoided:

```bash
./scripts/collect-diagnostics.sh
```
