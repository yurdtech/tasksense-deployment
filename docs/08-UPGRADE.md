# Upgrading and rolling back

```bash
git pull                       # 1. the deployment files first — always
./scripts/upgrade.sh 1.2.0     # 2. backup, migrate, start, verify
```

That is the whole procedure on Docker Compose. Read the rest once, before your
first upgrade: it explains what the script does, what it cannot undo, and how
rollback really works.

**Two facts everything below follows from:**

- **Migrations only go forward.** A release can change the shape of the data;
  there is no "down" migration. Putting the older image back does not put the
  older data back.
- **So a real rollback is a restore.** It is the previous version *plus* the
  backup taken just before the upgrade. `upgrade.sh` takes that backup, records
  it, and `rollback.sh` restores it by default.

Expect a short outage: the API is a single process, so the old version stops
before the new one starts. Typically a minute or two, plus migration time on a
large database. Tell users, and use a change window.

---

## Before you upgrade

- [ ] Read the release notes for every version between yours and the target —
      <https://github.com/yurdtech/tasksense-deployment/releases>.
- [ ] Confirm last night's backup exists, is a plausible size, and is off the
      host.
- [ ] Look for new settings: compare `compose/.env` with the new
      `compose/.env.example` (below).
- [ ] If the release notes say the reverse-proxy configuration changed,
      update it from `examples/` in the same window.
- [ ] For a major version: rehearse on a restored copy first.

New settings since your `.env` was written:

```bash
comm -13 <(grep -oE '^[A-Z_]+' compose/.env | sort -u) \
         <(grep -oE '^#?[A-Z_]+=' compose/.env.example | tr -d '#=' | sort -u)
```

Expected: a list of variable names your `.env` does not set yet. Every one has
a safe default; read its entry in [17-ENVIRONMENT](17-ENVIRONMENT.md) and decide.

---

## Docker Compose

### 1. Refresh the deployment files

```bash
cd /opt/tasksense-deployment
git pull                         # or: git fetch --tags && git checkout v1.2.0
```

Releases change these files too — the compose stack, the scripts, the
examples. Skipping this step upgrades the image but leaves you on the old
scripts.

### 2. Run the upgrade

```bash
./scripts/upgrade.sh 1.2.0
```

What it does, in order:

1. **Preflight** against the target version. A blocking problem stops the
   upgrade before anything has changed.
2. **Fetches the new image** — pulls it, or loads it with `--offline` — while
   the old version is still serving.
3. **Stops the application and the import worker**, then takes a **backup**
   (`backups/tasksense-pre-upgrade-<timestamp>.tar.gz`, bundled or external
   MongoDB alike). Nothing writes after it is taken, so it is exact. If the
   backup fails, the previous version is started again and nothing has changed.
4. **Records the rollback point** in `.previous-version`: the previous version
   and which backup belongs to it.
5. **Switches `TASKSENSE_VERSION`** and runs the new version's **migrations**
   (the one-shot `migrate` service).
6. **Starts the new version** and waits up to four minutes for its health
   check.

Expected ending (abridged):

```
==> Upgrade 1.1.0 → 1.2.0
…
==> Migrations
  ✓ schema migrated

==> Starting 1.2.0

==> Verifying
  {"version":"1.2.0","commit":"…","builtAt":"…","service":"tasksense-api"}

==> Upgraded to 1.2.0
  backup from just before: /opt/tasksense-deployment/backups/tasksense-pre-upgrade-20261016-210000Z.tar.gz
  back to 1.1.0, with that backup's data:  ./scripts/rollback.sh
```

The last five pre-upgrade backups are kept; nightly rotation never removes
them.

Then check:

```bash
curl -s http://127.0.0.1:3000/api/v1/version
curl -s http://127.0.0.1:3000/api/v1/health
```

Expected: the new version and commit; `"status":"ok"` and
`"schema":{"state":"current"}`. `"indexes":"building"` for a while after a
large upgrade is normal — new indexes on big collections build in the
background while the application serves.

Sign in, open a board, open a document, download an attachment. Watch the log
for a few minutes:

```bash
docker compose -f compose/docker-compose.yml logs -f app
```

### Which versions you can go to

| From → to | |
| --- | --- |
| Patch (`1.1.0 → 1.1.3`) | Directly. |
| Minor, skipping some (`1.0.2 → 1.3.0`) | Directly. Every migration in between runs, in order, in the `migrate` step. Read every release note in between. |
| Major (`1.x → 2.0`) | Asks for confirmation. Rehearse on a restored copy first; assume a longer window. |
| Older than what is installed | **Refused.** Use `rollback.sh` — going down is a restore, not an upgrade. |

### If it fails

`upgrade.sh` tells you which of these happened, and does not claim more than
is true:

| What failed | State afterwards | What it does |
| --- | --- | --- |
| Before the migration (preflight, backup, pulling the image) | The database is untouched | Starts the previous version again. Fix the cause and re-run. |
| The migration, or the new version's start, **after** migrations ran | The database has the new shape; the old version cannot be trusted on it | **Offers to restore the pre-upgrade backup and the previous version** — default yes; `--yes` answers yes without asking (for unattended runs). Because the application was stopped before the backup, accepting loses nothing. |
| You declined the restore | Left as it is, for investigation: the application stopped, `TASKSENSE_VERSION` at the new version, the database migrated | Prints the `rollback.sh` command (back with the old data) and the `up -d` to retry once the cause is fixed. |

Before rolling back a version that **started but misbehaves**, collect
diagnostics first, so the problem can be fixed rather than only avoided:

```bash
./scripts/collect-diagnostics.sh
```

---

## Rolling back

```bash
./scripts/rollback.sh
```

Goes back to the version in `.previous-version` **and restores the backup
`upgrade.sh` took just before upgrading** (it shows which, and asks; `--yes`
for automation). It takes a safety backup of the current state first, so the
rollback itself is recoverable. The result is the installation exactly as it
was before the upgrade. `./scripts/rollback.sh 1.1.0` names the version
explicitly; it refuses a version newer than the installed one.

> **Everything written after the upgrade is lost by a full rollback** —
> tasks, comments, uploads made on the new version. That is what "restore the
> pre-upgrade backup" means. Roll back soon, or not at all; after a day of
> work, fixing forward is usually better.

```bash
./scripts/rollback.sh --app-only
```

Puts only the previous image back and **leaves the data as the new version
left it**. It warns loudly before doing it, because it is safe only when the
release notes say the upgrade made no migration. Otherwise the older code runs
against a schema it does not know; `/api/v1/health` then reports
`"schema":{"state":"ahead"}` and the `TaskSenseSchemaAhead` alert fires
([09-MONITORING](09-MONITORING.md)). It keeps serving, but treat that state as
temporary.

If the import worker is on and the version you go back to predates it,
`rollback.sh` refuses until you remove `import-worker` from
`COMPOSE_PROFILES`.

---

## Air-gapped upgrades

On a machine with internet, fetch and verify the new bundle exactly as for the
first install ([13-REGISTRY-ACCESS](13-REGISTRY-ACCESS.md#no-route-out-air-gapped)):

```bash
echo '<TOKEN>' | oras login ghcr.io -u yurdtech --password-stdin
oras pull ghcr.io/yurdtech/tasksense-offline:1.2.0
./scripts/verify-signature.sh tasksense-onprem-1.2.0.tar.gz
```

Carry it in. On the server, unpack it **over** the existing installation
directory — that refreshes the deployment files and the `images/` directory,
and keeps what is yours (`compose/.env`, `compose/certs/`, `backups/`,
`.previous-version`), none of which the bundle contains:

```bash
cd /opt/tasksense-deployment
tar xzf /path/to/tasksense-onprem-1.2.0.tar.gz --strip-components=1
./scripts/upgrade.sh 1.2.0 --offline
```

The bundle's single top-level directory is `tasksense-onprem-<version>/`, which
is what `--strip-components=1` removes.

Or mirror the new images into your registry first
([13-REGISTRY-ACCESS](13-REGISTRY-ACCESS.md#mirroring-into-your-own-registry))
and upgrade normally.

---

## Kubernetes and OpenShift

```bash
helm upgrade tasksense oci://ghcr.io/yurdtech/charts/tasksense \
  --version 1.2.0 -n tasksense -f my-values.yaml
```

The chart version is the application version. What happens:

1. **Pre-upgrade hook:** with backups enabled, `migrations.backupBeforeUpgrade`
   dumps the database to the backup PVC; then the migration Job runs.
2. The Deployment is replaced with the **Recreate** strategy — the old pod
   stops before the new one starts. A short outage, by design.

Check:

```bash
kubectl -n tasksense logs job/tasksense-migrate
kubectl -n tasksense rollout status deploy/tasksense
helm test tasksense -n tasksense --logs
```

> The hook Jobs run while the **previous** version is still serving, because
> Helm runs pre-upgrade hooks before it changes the Deployment — writes made
> during the dump may or may not be in it. For a strictly consistent
> pre-upgrade dump, stop the application first:
> `kubectl -n tasksense scale deploy/tasksense --replicas=0` (and
> `deploy/tasksense-worker` if the worker is on) — `helm upgrade` brings them
> back (the chart's `replicaCount: 1` is re-applied).

**Rolling back on Kubernetes:** `helm rollback tasksense -n tasksense` puts the
previous chart and image back — **application only**, like `--app-only` above.
For a full rollback, restore the pre-upgrade dump from the backup PVC as well:
[02-INSTALL-KUBERNETES › Rollback](02-INSTALL-KUBERNETES.md#rollback).

---

## Upgrading from 1.0.x to 1.1.0

1.1.0 is the minimum version these deployment files support. On top of the
procedure above:

| Change | What to do |
| --- | --- |
| **Docker Compose v2.20+** is required (profiles, optional dependencies) | `docker compose version` before you start. |
| `.env` gains `COMPOSE_PROFILES` | Added for you (`bundled-mongo`, when `MONGODB_URI` is empty) by `upgrade.sh`, `install.sh` and `preflight.sh`. With your own MongoDB, nothing is added — check it is not listed. |
| Migrations run in the one-shot `migrate` service | Nothing to do; the application now starts only after it succeeded (`MIGRATE_ON_BOOT=manual` is set by the stack). |
| Session lifetime default changes from never (`0`) to 30 days | Set `SESSION_TTL_HOURS=12` for a bank. Sessions issued before the upgrade keep no expiry; to end them all, Admin → Security → sign everyone out. |
| `AGENT_EXECUTOR` | Anything other than `off` now fails `preflight.sh`. Set `AGENT_EXECUTOR=off`. |
| `SWAGGER_ENABLED` | Still on unless set — set `SWAGGER_ENABLED=false`. |
| Uploads are staged on the data volume (`TMPDIR=/app/api/data/tmp`) | Free disk on Docker's data root for the largest upload; 2× a Jira backup's size during a migration. |
| Live updates authenticate with a short-lived `?ticket=` | Nothing to do — browsers pick up the new web interface on reload. Update the proxy's log format to drop query strings (`examples/nginx.conf`). |
| Upload routes need a large body limit on the proxy | Without the new upload locations from `examples/nginx.conf` (21g, unbuffered), a Jira backup upload stops at 25 MB. |
| A private CA can be trusted process-wide | `NODE_EXTRA_CA_CERTS=/certs/<bundle>.pem` ([17-ENVIRONMENT](17-ENVIRONMENT.md#7-trusting-your-certificate-authority)). |

---

## The bundled MongoDB

It has its own lifecycle: it stays on major 7 until a release note says
otherwise. Moving it to a later major needs MongoDB's feature-compatibility
steps — never just a bigger `MONGO_VERSION` in `.env`. When a TaskSense
release requires it, the release notes carry the procedure.

---

## Version support

The current minor release and the one before it receive security fixes
([SECURITY.md](../SECURITY.md)). Because skipping minor versions is supported,
catching up from further behind is one upgrade — but read every release note
on the way.
