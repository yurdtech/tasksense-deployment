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

On Docker Compose, and on Kubernetes without Redis, expect a short outage:
every API process of the old version stops before the new one starts — one
process, or all of them with several. Typically a minute or two, plus
migration time on a large database. Tell users, and use a change window.

On Kubernetes with Redis there is no outage by default: the chart rolls pod by
pod, and each new API pod is ready before an old one stops
([Rolling updates](#rolling-updates-kubernetes)). A release whose notes say it
is not **rolling-safe** is upgraded with `Recreate` instead.

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
3. **Stops the application and the import worker** — with the `replicas`
   profile, every API container — then takes a **backup**
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

With the `replicas` profile, name both files
(`-f compose/docker-compose.yml -f compose/docker-compose.replicas.yml`); the
log then interleaves every replica, each line prefixed with its container.
Compose has no rolling update: the `replicas` topology upgrades with the same
stop–backup–migrate–start window as one process.

### Which versions you can go to

| From → to | |
| --- | --- |
| Patch (`1.1.0 → 1.1.5`) | Directly. |
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
2. The API pods are replaced. With Redis the default is **RollingUpdate**:
   each new pod starts and becomes ready before an old one stops, so there is
   no outage — below. Without Redis it is **Recreate**: every old pod stops
   before the first new one starts, a short outage.

Check:

```bash
kubectl -n tasksense logs job/tasksense-migrate
kubectl -n tasksense rollout status deploy/tasksense
kubectl -n tasksense rollout status deploy/tasksense-sync    # the sync worker, unless jiraSync.enabled: false
helm test tasksense -n tasksense --logs
```

> The hook Jobs run while the **previous** version is still serving, because
> Helm runs pre-upgrade hooks before it changes the Deployment — writes made
> during the dump may or may not be in it. For a strictly consistent
> pre-upgrade dump, stop the application first:
> `kubectl -n tasksense scale deploy/tasksense --replicas=0` (and
> `deploy/tasksense-worker` if the worker is on, and `deploy/tasksense-sync`) —
> `helm upgrade` brings them
> back (the chart's `replicaCount` is re-applied). With `autoscaling.enabled`
> the Deployment has no replica count of its own: scale it back to
> `autoscaling.minReplicas` after the upgrade, and the autoscaler takes over.

### Rolling updates (Kubernetes)

With Redis, `strategy.type` left empty (the default) means `RollingUpdate`,
and the API pods are replaced one at a time (`maxSurge: 1`, `maxUnavailable:
0`): the hook Jobs run first as above, then a new pod starts, becomes ready,
and only then does an old one go, until none of the old release is left. One
API pod works the same way: for a moment there are two. For that time **two
releases serve side by side** behind one round-robin Service.

It works on a `ReadWriteMany` volume and on a `ReadWriteOnce` one. On
`ReadWriteOnce` the new pod is scheduled onto the node that holds the volume
(beside the old pod and the workers), so that node needs room for one more
API pod while the upgrade runs. If it has none, the new pod stays `Pending`
and the old one keeps serving until you free the room or upgrade with
`Recreate`. `ReadWriteOncePod` allows one pod only, so the default there is
`Recreate`.

That is safe for a release that is **rolling-safe**, which means both of:

1. **Its migrations are backwards compatible.** The migration Job finishes
   before the first new pod starts, so the previous release runs against the
   migrated schema until the rollout ends — it must still read and write it
   correctly.
2. **Its API and the previous release's web build work with each other, both
   ways.** A browser that loaded the previous interface calls new pods, and a
   browser that loaded the new interface calls old ones.

Rolling-safe is a statement about the release immediately before it. The
release notes and the section for each version below say when a release is
**not**. Upgrading across several releases, or to a release that is not
rolling-safe, uses `Recreate` for that upgrade:

```bash
helm upgrade tasksense oci://ghcr.io/yurdtech/charts/tasksense \
  --version 1.2.0 -n tasksense -f my-values.yaml --set strategy.type=Recreate
```

During a rolling update the chart's `WEB_ASSETS_SHARED_DIR` keeps the
interface whole: each pod copies its web build's content-hashed files to
`/app/api/data/web-assets` on the shared volume and serves them after its own,
so a page from one release finds its scripts on a pod of the other. Each old
pod gets its preStop sleep and drain time before it stops; open live-update
streams reconnect to another pod. Watch it with
`kubectl -n tasksense rollout status deploy/tasksense`.

`helm rollback` with `RollingUpdate` rolls back the same way, pod by pod — the
older release then runs on the newer schema, which is what a rolling-safe
release promises. After a release that was not rolling-safe, roll back with
`Recreate` and the pre-upgrade dump, as below.

**Rolling back on Kubernetes:** `helm rollback tasksense -n tasksense` puts the
previous chart and image back — **application only**, like `--app-only` above.
For a full rollback, restore the pre-upgrade dump from the backup PVC as well:
[02-INSTALL-KUBERNETES › Rollback](02-INSTALL-KUBERNETES.md#rollback).

---

## The upgrade that brings the Jira sync worker

From 1.1.1 the Jira and Confluence sync runs in its own process: the
`tasksense-sync` container on Compose, the `<release>-sync` Deployment on
Kubernetes and OpenShift. **It is on by default, and the upgrade starts it**,
with nothing to edit. Without a Jira connection it only answers its health
check.

| | Docker Compose | Kubernetes / OpenShift |
| --- | --- | --- |
| What the upgrade does | `upgrade.sh` finds no `JIRA_SYNC_RUNNER` in `.env`. It adds `jira-sync` to `COMPOSE_PROFILES` and sets `JIRA_SYNC_RUNNER=external`, prints **The Jira sync worker**, and keeps the original as `backups/env-before-sync-worker-*`. Then it starts the container with the rest. | `jiraSync.enabled` defaults to `true`, so `helm upgrade -f my-values.yaml` creates the Deployment and its Service, and gives the API `JIRA_SYNC_RUNNER=external`. |
| Check | `docker compose -f compose/docker-compose.yml ps sync` → `healthy` | `kubectl -n tasksense rollout status deploy/tasksense-sync` |
| Extra resources | up to 1 CPU and 3 GB (`SYNC_CPU_LIMIT`, `SYNC_MEMORY_LIMIT`) | requests 250m / 1Gi, limit 1 CPU / 3Gi — mind the namespace quota |
| Storage | the same data volume as the API, nothing to do | `ReadWriteOnce`: scheduled onto the API's node. `ReadWriteMany`: anywhere. `ReadWriteOncePod`, or `persistence.enabled: false`: the chart refuses — set `jiraSync.enabled: false` before upgrading |
| Network | none inbound. Outbound, to the Jira site on 443 (or the proxy), once Jira is connected | the same. With `networkPolicy.enabled`, egress to the site or the proxy ([18](18-PRE-INSTALL-CHECKLIST.md), O15) |
| To keep the old behaviour | before the upgrade, set `JIRA_SYNC_RUNNER=inline` in `.env`. A `.env` that names it is never changed | `jiraSync.enabled: false` in the values file |
| Rolling back | `rollback.sh` sees that the older image has no sync worker. It removes `jira-sync`, sets `JIRA_SYNC_RUNNER=inline`, and keeps the original `.env` | nothing to do: the older chart has no sync Deployment |

Turning it off later, and everything it needs:
[15-SCALING-AND-HA](15-SCALING-AND-HA.md#the-jira-sync-worker),
[01-INSTALL-COMPOSE](01-INSTALL-COMPOSE.md#the-jira-sync-worker-on-by-default),
[02-INSTALL-KUBERNETES](02-INSTALL-KUBERNETES.md#the-jira-sync-worker).

---

## The upgrade that brings the automation worker

From 1.1.3 automation rules can run in a process of their own: the
`<release>-automation` Deployment on Kubernetes and OpenShift. **It is off by
default**, and the upgrade changes nothing about where rules run until you
turn it on. Turn it on for a busy installation, where a burst of rules would
otherwise share the API's event loop and database pool.

| | Kubernetes / OpenShift |
| --- | --- |
| Turn it on | `automationWorker.enabled: true` in the values file, then `helm upgrade`. The chart creates the Deployment and its Service, and gives every other pod `AUTOMATION_RUNNER=external`. |
| Check | `kubectl -n tasksense rollout status deploy/tasksense-automation`; `/ready` on port 3200 |
| Extra resources | requests 250m / 768Mi, limit 2Gi per replica — mind the namespace quota |
| Storage | as the sync worker: `ReadWriteOnce` is scheduled onto the API's node, `ReadWriteMany` anywhere; `ReadWriteOncePod` or `persistence.enabled: false` is refused |
| Redis | recommended: the API wakes the worker through it at once. Without Redis the worker picks events up within its 5-second poll. |
| Turning it off | `automationWorker.enabled: false` and `helm upgrade`. Events the worker had not run yet stay in the queue and the API runs them. |

Three changes come with 1.1.3 whether or not the worker is on:

| Change | What to do |
| --- | --- |
| **No automation budget on-premise by default** — `AUTOMATION_PROCESSING_MINUTES_PER_12H` (`config.automationProcessingMinutesPer12h`) now defaults to `0`. With 60, a busy day could spend the budget by midday, and every rule then waited for the next 12-hour window. | Nothing. To keep a budget, set the value explicitly. |
| **Schema migration `014-backfill-tenant-ws`** — rows written before workspaces existed get the default workspace id, exactly how they were already read, so queries of the default workspace use their indexes. | Nothing. It runs in the `migrate` step and is idempotent; on a large database it takes a few minutes. Back up first, as for every upgrade with a migration. `./scripts/rollback.sh --app-only` / `helm rollback` to 1.1.2 is safe: 1.1.2 reads those rows the same way. |
| **Upgrades without an outage on Kubernetes** — with Redis, `strategy.type` now defaults to `RollingUpdate`, also on a `ReadWriteOnce` volume: the new API pod is ready before the old one stops. The API, sync and automation pods are kept on the node of a `ReadWriteOnce` volume. | Nothing; a values file that sets `strategy.type: Recreate` keeps it. **1.1.3 is rolling-safe from 1.1.2**: its one migration is the backfill above, and 1.1.2's interface and API work with 1.1.3's both ways. Coming from an earlier release, upgrade with `--set strategy.type=Recreate`. The node of a `ReadWriteOnce` volume needs room for one more API pod during the upgrade. |

More on the worker: [15-SCALING-AND-HA](15-SCALING-AND-HA.md#the-automation-worker),
[02-INSTALL-KUBERNETES](02-INSTALL-KUBERNETES.md).

---

## Upgrading from 1.1.4 to 1.1.5

The procedure above, with nothing to edit first. 1.1.5 adds two schema
migrations, run in order in the `migrate` step, each idempotent:
`018-space-access-into-roles` and `019-jira-epics-into-their-space`. Both keep
the fields 1.1.4 reads, so the upgrade rolls pod by pod as before, and
`./scripts/rollback.sh --app-only` / `helm rollback` to 1.1.4 starts and runs
on the migrated database. A rollback does **not** narrow access back for the
spaces 018 moved (see the first row). A 1.1.4 pod that takes a scheduled rule from the queue runs it as it runs a
retry, and the other fields and collections 1.1.5 adds are ignored by 1.1.4.
Deliveries still waiting for a retry at a rollback are then not retried
(1.1.4 has no retries), as before.

**Read this before you upgrade: who sees a space now works as in Jira.**
Check the first row below with whoever runs the workspace.

| Change | What to do |
| --- | --- |
| **Space access works like Jira** — who sees a space now comes only from its permission scheme's *Browse Space*: its roles, groups and people. Squad rosters, tribe grants (`tribeAccess`) and the workspace's access mode no longer decide it, and whoever sees a space sees all of its boards. Migration 018 puts everyone who sees a space today into its *Members* role and gives the space a permission scheme of its own, so nobody sees less. Someone who saw only some of a space's boards, or only its work on another space's board, now sees the whole space; the migrate log lists each such person under `now see a whole space:`. **Spaces bound to a Jira project are left to the Jira sync**, which brings their real scheme, roles and the groups in those roles. **People limited by tribe see much more.** In an upgrade test with the access mode *membership* and tribe grants, members limited to one tribe went from 0 or 4 of a space's 36 tasks to all 36, in a space 018 moved and in a space bound to Jira alike | **If your installation limits people by tribe or uses the access mode *membership*, decide before the upgrade.** Afterwards those people see every space their roles let them browse. For a space bound to Jira that is whatever *Browse Projects* grants in Jira, once the sync's structure step has brought the scheme. After the upgrade, read the migrate log and check the *Permissions* page of the spaces concerned; to narrow a space again, take people out of its roles. A rollback to 1.1.4 brings the old view back only for spaces bound to Jira. In the spaces 018 moved, the people it put into the *Members* role keep more than they had (27 to 31 of 36 tasks in the test), because 1.1.4 also reads that role. |
| **Webhooks and Slack posts are retried** — a post the receiver did not take (no answer, a timeout, `429`, a `5xx`) or that a restart cut off is sent again after 1, 5, 15 and 60 minutes, for up to 24 hours, instead of being dropped after two attempts. A post is still sent at once; only failures wait. They are kept in a new collection, `deliveryOutbox`; one given up on stays there a week | Nothing. A receiver should expect a post it already has after a timeout or a restart, and recognise it by its `event`, `entityId` and `at`. Egress is unchanged: the same receivers, from the same pods. |
| **A webhook can limit how many posts run at once** — Admin → Webhooks → *Deliveries at once* (1–50) | Nothing; a hook without it sends every post at once, as before. Set it for a receiver that cannot take a burst. |
| **Notification e-mail is retried when the relay is down** — the same retries; a mail the relay refuses for good (a `5xx` other than an authentication failure) is not retried | Nothing. Test mails, invites, sign-in mail and an automation rule's e-mail action send as before. |
| **Scheduled rules go through the automation queue** — a workspace's due rules now run side by side, `AUTOMATION_WORKSPACE_CONCURRENCY` at a time (default 5), instead of one after another in one pass | Nothing. With the automation worker on they run there, as before. The process that runs automation holds a few more rules in memory at the busiest minute; raise the variable only step by step ([17 › Limits](17-ENVIRONMENT.md#10-limits-for-very-large-workspaces)); with Helm set it under `extraEnv`. |
| **Admin → Automation → *Keep skipped runs for*** — runs whose conditions did not match can be kept 30, 14, 7 or 1 day instead of 90 | Nothing; the default is 90 days, as before. |
| **Indexes** — new ones back the automation queue, the run history, the delivery retries and a few lookups, and are built in the background when 1.1.5 first starts. Two indexes they replace are left in place on a large database | Nothing at the upgrade. Until the new indexes are done `GET /api/v1/health` reports `"indexes":"building"`. For each index left in place the API logs `Index <collection>.<name> is superseded and left in place on a large collection — once this release is accepted, drop it by hand: db.getCollection("<collection>").dropIndex("<name>")`. Once you keep 1.1.5, run those commands; the application's own account (`readWrite`) may drop them. |
| **A Jira epic belongs to its issue's space** — migration 019 gives every Jira epic without a space the space of its epic issue, so other spaces' boards and timelines no longer offer it | Nothing. The migrate log says how many it moved. |
| **Text limits** — Admin → Text limits sets the longest task description and comment (1 to 32,767 characters). The default for both is now 32,767, Jira's cap; it was 2,000 for a comment and 32,000 for a description. A lowered limit applies only to text that changes | Nothing. Set a lower limit there if your workspace had relied on the old ones. |
| **Task e-mail** — one subject per task, the whole description with what changed marked, and a close or reopen now also reaches the task's reporter | Nothing. Reporters receive these mails under their usual notification settings. |
| **The Epics screen is back** — 1.1.4 moved epics onto the Timeline; they have their own screen again, and an epic's name on the Timeline opens it there | Nothing. |
| **Knowledge Base diagrams** — canvas, BPMN and database diagrams are stored in two new collections, `diagrams` and `diagramRevisions`; an Admin switch per diagram kind | Nothing. Backups dump them with the rest of the database. The editor's formula, chart and diagram libraries are bundled in the image; nothing is fetched from outside. |
| **API tokens** — a token's scope now also limits what the services behind a route do (a read-only token can still search); a token made with another token is tied to it; an unknown token id answers `404`. The Jira-compatible API (`/rest/api/2`, `/rest/api/3`, `latest`) answers more of Jira's calls and refuses what a field cannot take; *Admin → Security → Jira-compatible API* can refuse unknown fields too (off by default) | Check a script or integration whose token has a narrower scope than the calls it makes: a call outside the scope is now refused. The app, the MCP server with a full-scope token and the Jira sync are not affected. |
| **What's New** — after the upgrade, people see the 1.1.5 notes once in the app | Admin → Overview → Workspace: *Show What's New after updates* stops the pop-up, *What's New* turns the notes off altogether. |

---

## Upgrading from 1.1.3 to 1.1.4

The procedure above, with nothing to edit first. 1.1.4 adds three schema
migrations, run in order in the `migrate` step, each idempotent:
`015-member-edits-own-tasks`, `016-one-epic-per-epic-issue` and
`017-space-overrides-into-schemes`. It is **rolling-safe from 1.1.3**: 1.1.3
reads the migrated rows the same way, so on Kubernetes with Redis the chart
rolls it pod by pod, and `./scripts/rollback.sh --app-only` / `helm rollback`
to 1.1.3 keeps working. Coming from 1.1.2 or earlier, upgrade with
`--set strategy.type=Recreate`, and read
[1.1.2 to 1.1.3](#upgrading-from-112-to-113) first: its changes come with this
upgrade too.

**Read this before you upgrade: members see and do less until an
administrator allows it.** Plan the settings below with whoever runs the
workspace, so people are not surprised the next morning.

| Change | What to do |
| --- | --- |
| **Members edit their own tasks** — migration 015 moves every `member` role nobody changed from *Create & edit tasks* to *Edit own tasks*: members edit only the tasks they reported or are assigned to. They still create tasks, comment and log time. A member role an administrator changed is left as it is | If members should keep editing every task, give the member role *Create & edit tasks* again in the Admin console after the upgrade. The migrate log names each workspace it moved. |
| **Members see less by default** — four things are now behind an Admin switch, and each starts **off**: teammates' e-mail addresses (only admins see them; everyone still sees their own), KPI numbers, current values and targets (only admins see them; members see the KPI names), launching agents (admins and leads always may) and Arena (off for everyone) | After the upgrade, turn on what your people should keep: *Members see teammates' e-mail*, *Members see KPI numbers*, *Members can launch agents* (Admin → Overview → Agents) and *Arena*. The Admin search finds each by name. |
| **One epic per Jira epic issue** — migration 016 removes the duplicate epics that Jira-sync stories running at the same time created for one epic issue. The oldest is kept, and releases and KPI links are moved onto it. A new unique index keeps it from happening again | Nothing. The migrate log says how many it removed. |
| **A space's own permission changes become a permission scheme** — migration 017 copies the scheme each such space used, writes the space's changes into the copy and points the space at it, as in Jira. The old changes stay on the space, unread, so a rollback still has them | Nothing; access stays as it was. The one case it cannot keep is a *Manage access* role that held a permission only as reporter, assignee or through a user field. The migrate log lists each one as `could not keep: <space>: <role> loses <permission>`; grant it again on the new scheme. |
| **Faster first load in large workspaces** — the first load carries the start of each task's description, not all of it, and reads the epics separately; a task's whole text is read when it is opened. Each process builds at most 8 first loads at once, so a restart that reconnects every tab no longer piles them all onto one event loop | Nothing. New indexes are built in the background when 1.1.4 first starts; until they are done `GET /api/v1/health` reports `"indexes":"building"`. A load that waits longer than 30 s is answered `503` with `Retry-After`, and the tab asks again. `STATE_BUILD_CONCURRENCY` and `STATE_BUILD_MAX_WAIT_MS` change the two numbers ([17 › Large workspaces](17-ENVIRONMENT.md#10-limits-for-very-large-workspaces)); with Helm set them under `extraEnv`. |
| **Epics live on the Timeline** — the Epics screen is gone; its links open the Timeline, which now creates, edits and opens epics | Nothing. |
| **Access with groups** — a whole group can hold a role in a space, a space's *Permissions* page shows who can do what, people can ask for access from a link they cannot open, and an administrator can hide a sidebar tab or show it only to chosen teams and people | Nothing changes until someone uses it. |
| **Workflows per work type** — bugs and stories can follow different statuses in one space, and a move can require something first or update fields for you | Nothing; existing workflows stay as they are. |
| **Jira sync** — the migration screens were redesigned, and you can bring over only people from the e-mail domains you choose | Nothing. |
| **What's New** — after the upgrade, people see the 1.1.4 notes once in the app | Admin → Overview → Workspace: *Show What's New after updates* stops the pop-up, *What's New* turns the notes off altogether. |

---

## Upgrading from 1.1.2 to 1.1.3

The procedure above, with nothing to edit first. 1.1.3 adds one schema
migration, `014-backfill-tenant-ws`, and is **rolling-safe from 1.1.2**: on
Kubernetes with Redis the chart rolls it pod by pod, without an outage
([Rolling updates](#rolling-updates-kubernetes)). Coming from 1.1.1 or
earlier, upgrade with `--set strategy.type=Recreate`, and read
[1.1.1 to 1.1.2](#upgrading-from-111-to-112) first: its changes come with this
upgrade too.

The changes for operators — the migration, rolling updates by default, no
automation budget on-premise and the optional automation worker — are in
[The upgrade that brings the automation worker](#the-upgrade-that-brings-the-automation-worker).
The rest of the release:

| Change | What to do |
| --- | --- |
| **Large workspaces stay fast** — the Epics screen is paged by the server, with its counts from a separate request; a person's snapshot holds the newest tasks *they* can see rather than the workspace's; the people list is sent once per tab instead of with every snapshot | Nothing. New indexes back these reads and are built in the background when 1.1.3 first starts. Until they are done, `GET /api/v1/health` reports `"indexes":"building"` and those reads are slower; on a large database allow a few minutes. |
| **A stopping API process finishes its requests** — on `SIGTERM` it answers `Connection: close`, closes idle connections and waits up to 10 s for the requests in flight | Nothing. Keep `terminationGracePeriodSeconds` at least `preStopSleepSeconds` + 20; the defaults (45 and 10) are. |
| **Automation rules are safer to run twice** — a rule run again after its process stopped mid-run does not repeat its emails, web requests or created tasks; an incoming webhook accepts an `Idempotency-Key` header | Nothing. |
| **Automation behaviour changes** — *Delete task* acts only with its actor's permission on the task it names; two administrators saving rules at once no longer undo each other's work (the later save is refused, `409`); a web request's `4xx` / `5xx` answer is named in the run log and can fail the rule (opt-in per action, off) | Check that the actor of a rule that deletes tasks may delete them. A script that writes `PUT /api/v1/automation` without `revision` behaves as before. |
| **Fields, priorities and work types are set per space** — through field contexts and priority / work type schemes, as in Jira. *Fields by squad*, *Priorities by squad* and *Work types by squad* are gone, and lists saved there are no longer applied | Before the upgrade, note any per-squad lists in the Admin console; afterwards set them again as field contexts or schemes on the spaces concerned. |
| **Access fixes** — someone with *Manage access* is never locked out of a space by its access rules, and a space's override still grants them what the scheme withholds; a dashboard's edit controls follow *Manage access*, as the server already did; a saved filter is changed only by its owner, and a private one is sent to no one else | Nothing changes on default settings. |
| **Meeting invites** — the meeting email is an HTML invite with a calendar file, so mail clients add the meeting themselves; an update moves it and a cancellation removes it. Yes / Maybe / No links answer without signing in; they are signed and stay valid until 30 days after the meeting | Check that `APP_URL` (`config.appUrl`) is the address people reach TaskSense on: the links point at it. Admin → Notification schemes → Meeting invites switches the calendar file and the answers, and names an organizer mailbox whose replies (Accept / Tentative / Decline) are read back. |
| **Sign-in codes for a list of people** — optional: Admin → Authentication → Sign-in verification → *Send codes only to the people listed* | Nothing changes until it is turned on. |
| **Jira sync** — a board keeps its own filter, its new cards and its earlier work; Jira types above Epic land as their own types, on boards and under their parents | Nothing. |
| **What's New** — after the upgrade, people see the 1.1.3 notes once in the app | Admin → Overview → Workspace: *Show What's New after updates* stops the pop-up, *What's New* turns the notes off altogether. |

---

## Upgrading from 1.1.1 to 1.1.2

The procedure above, with nothing to edit first. 1.1.2 adds **no schema
migration**: the `migrate` step reports the schema current, and
`./scripts/rollback.sh --app-only` (or `helm rollback`) returns to 1.1.1
without the schema-ahead warning. It is not marked rolling-safe — keep
`Recreate` for this upgrade. Coming from 1.1.0, read
[1.1.0 to 1.1.1](#upgrading-from-110-to-111) first: its changes come with
this upgrade too.

| Change | What to do |
| --- | --- |
| **The Jira sync lands on S3 / MinIO storage** — a key with an escaped character (`sprints/13767:8167`) was signed wrongly, S3 answered 403 `SignatureDoesNotMatch` and a migration stopped at *Projects, boards and sprints* | Nothing. A run stopped that way resumes from its checkpoint: Sync → the run → Resume. |
| **A storage failure no longer stops the Jira sync as UNKNOWN** — S3 429 / 503 SlowDown and 5xx requeue the run from its checkpoint; 401 / 403 report a permission error | Nothing. |
| **The sync worker logs its runs** — `tasksense-sync` writes, at the default log level, when a run starts, each kind and scope, every page it lands with its counts, and how it ended; the run's warnings (Jira rate limits, retries, a full disk) go to the process log too | Nothing. Read a run's progress with `docker compose logs -f sync` / `kubectl logs -f deploy/tasksense-sync`. |
| **Open tabs stay live through a migration** — the change stream now carries the changed rows, so tabs no longer each fetch `GET /state/delta` as a migration lands | Nothing. |
| **SMTP to a plain or internal relay** — STARTTLS can be switched off, and a certificate no trusted CA signed can be accepted | Only for a relay whose STARTTLS is broken: `SMTP_IGNORE_TLS=true` (`config.smtp.ignoreTls`). For an internal certificate, mount your CA (`NODE_EXTRA_CA_CERTS` / `certs.*`); `SMTP_TLS_REJECT_UNAUTHORIZED=false` (`config.smtp.tlsRejectUnauthorized`) only as a last resort. A relay set in the Admin console has the same two settings; one saved before keeps *When the server offers it*. [17-ENVIRONMENT](17-ENVIRONMENT.md) |
| **Cross-workspace and reach fixes** — a media link is bound to its workspace; an API token cannot switch workspace; a session whose account has no workspace left ends; releases, plans, history and the epic sync stay within the caller's reach | Nothing changes on default settings. A script that switched workspace with an API token gets a refusal: make a token in each workspace instead. |
| **Image scan** — the three fixable HIGH findings of the 1.1.1 image (body-parser, multer) are fixed | Nothing. |
| **What's New** — after the upgrade, people see the 1.1.2 notes once in the app | Admin → Overview → Workspace: *Show What's New after updates* stops the pop-up, *What's New* turns the notes off altogether. |
| **Knowledge Base: a new page is its author's draft until the first Publish** | Tell the teams that write in the Knowledge Base. |
| **Pulse: every check-in needs a note** | Tell the teams that use Pulse. |
| **Team invites** — many addresses at once, one link for several people, a custom link expiry | Nothing. |

---

## Upgrading from 1.1.0 to 1.1.1

The procedure above, with nothing to edit first. 1.1.1 adds **no schema
migration**: the `migrate` step reports the schema current, and
`./scripts/rollback.sh --app-only` (or `helm rollback`) returns to 1.1.0
without the schema-ahead warning. It is not marked rolling-safe — keep
`Recreate` for this upgrade.

| Change | What to do |
| --- | --- |
| **The Jira sync worker starts** — one more container on Compose, one more Deployment on Kubernetes | Nothing, unless the Kubernetes data volume is `ReadWriteOncePod` or `persistence.enabled: false`: then set `jiraSync.enabled: false` first, or the chart refuses the upgrade. Mind the namespace quota (requests 250m / 1Gi). [The upgrade that brings the Jira sync worker](#the-upgrade-that-brings-the-jira-sync-worker). |
| **Jira and Confluence sync** — a new Sync page imports projects, boards, issues with their full history, comments, worklogs, attachments, people, workflows and automation rules, and Confluence spaces into Docs. It only reads from Jira until an administrator makes a board live | Before connecting Jira, add the Jira site (and the proxy, if any) to `EGRESS_ALLOWLIST` / `config.egressAllowlist`. Free disk for the attachments it copies: a run pauses itself below 2 GB free. |
| **Several API processes with Redis** — optional | Nothing changes without `REDIS_URL`. To scale out: [15-SCALING-AND-HA](15-SCALING-AND-HA.md). |
| **Sign-in verification by email code** — optional, off | Admin → Authentication → Sign-in verification, separately for directory (LDAP) and for email + password sign-in. It needs a working email channel and is refused without one. |
| **Space permission schemes are applied as Jira applies them** | Nothing changes on default settings. Where an administrator has set a space's permission scheme, screens or automation actors, some requests that 1.1.0 allowed are now refused — on purpose: a space whose scheme withholds *Browse* is hidden from that person everywhere (a direct link answers 404); a rule whose actor is a named person acts with that person's permissions; the REST API refuses a field the space's screen leaves off (400); a workflow, priority or work-type scheme in use cannot be deleted (409); `votes` is no longer accepted on `PATCH /tasks/:id`. Review such spaces before the upgrade and tell the teams concerned. |
| **Team screen** — only administrators invite, and a role change needs an administrator's approval | Tell the people who invited colleagues until now. |
| **Invites expire** — a link invite after 7 days, an email invite after 14 (Admin → Security → Invites). An invite from 1.1.0 carries no date and runs out by its age; a pending invitee takes no seat until they accept | Re-send invites older than that, or lengthen the expiry before the upgrade. |

---

## Upgrading from 1.0.x to 1.1.0

1.1.0 is the minimum version these deployment files support. On top of the
procedure above:

| Change | What to do |
| --- | --- |
| **Docker Compose v2.20+** is required (profiles, optional dependencies) | `docker compose version` before you start. |
| `.env` gains `COMPOSE_PROFILES` | Added for you (`bundled-mongo`, when `MONGODB_URI` is empty) by `upgrade.sh`, `install.sh` and `preflight.sh`. With your own MongoDB, nothing is added — check it is not listed. |
| Migrations run in the one-shot `migrate` service | Nothing to do; the application now starts only after it succeeded (`MIGRATE_ON_BOOT=manual` is set by the stack). |
| Session lifetime default changes from never (`0`) to 30 days | Set `SESSION_TTL_HOURS=12` for production. Sessions issued before the upgrade keep no expiry; to end them all, Admin → Security → sign everyone out. |
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
