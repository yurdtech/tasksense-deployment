# Installing on Kubernetes

For clusters you already run. If you do not have one, [Docker
Compose](01-INSTALL-COMPOSE.md) is easier to operate and easier to restore, and
for a few hundred users the capacity difference is theoretical.

Requires Kubernetes 1.24+ and Helm 3.8+.

---

## MongoDB is not included

The chart does not bundle a database. In a cluster that is almost always
something a platform team already runs — an operator, a managed service, or a
StatefulSet with its own backup policy — and a bundled one would either be
ignored or, worse, used in production without anyone owning its backups.

`mongodbUri` is required. Put TLS and replica-set options in the URI:

```
mongodb://user:pass@mongo-0.mongo,mongo-1.mongo/?replicaSet=rs0&tls=true&authSource=admin
```

If you have no MongoDB and want one quickly, the Bitnami chart or the MongoDB
Community Operator both work. Whatever you choose, arrange its backups before
going live — the application's own snapshots are not disaster recovery
([07-BACKUP-DR](07-BACKUP-DR.md)).

---

## Install

### Building the values file with the wizard

```bash
git clone https://github.com/yurdtech/tasksense-deployment.git
cd tasksense-deployment
./tasksense          # → Kubernetes
```

It asks about the four values the chart refuses to render without, plus ingress,
storage and replicas, and writes `my-values.yaml`. It stops there and prints the
command rather than applying anything — a cluster is usually somebody else's to
change, and the install may need to go through a pipeline rather than a
terminal. It will run `helm install` for you if you ask it to.

`my-values.yaml` is in `.gitignore`: unless you moved the four values into a
Secret, it holds the storage key and the database URI.

### Or by hand

```bash
kubectl create namespace tasksense

kubectl create secret docker-registry ghcr -n tasksense \
  --docker-server=ghcr.io \
  --docker-username=<username> \
  --docker-password="$TASKSENSE_REGISTRY_TOKEN"

helm install tasksense ./helm/tasksense -n tasksense \
  --set appUrl=https://tasksense.bank.internal \
  --set mongodbUri='mongodb://user:pass@mongo:27017/?authSource=admin' \
  --set storageSecret="$(openssl rand -base64 32)" \
  --set firstAdminEmail=admin@bank.internal \
  --set ingress.enabled=true \
  --set ingress.hosts[0].host=tasksense.bank.internal \
  --set ingress.hosts[0].paths[0].path=/ \
  --set ingress.hosts[0].paths[0].pathType=Prefix \
  --wait
```

For anything beyond a trial, put those in a values file instead — a `--set` with
a secret in it lands in your shell history.

The chart refuses to render on a configuration that would install something
broken: a missing `appUrl`, `mongodbUri` or `storageSecret`, a `storageSecret`
under 32 characters, metrics without a token, or several replicas sharing a
`ReadWriteOnce` volume. Each failure names the value and what to do.

> `storageSecret` is **not recoverable**. It encrypts the credentials you later
> enter for object storage and model providers. Back it up with the database.

### Secrets from your own tooling

`--set storageSecret=…` puts the value in the Helm release, where anyone who can
read the release can read it. With Vault, sealed-secrets or an external-secrets
operator, create the Secret yourself and point the chart at it:

```yaml
existingSecret: tasksense-config
```

It must contain `APP_URL`, `MONGODB_URI`, `STORAGE_SECRET` and
`FIRST_ADMIN_EMAIL`. The chart then generates none of its own.

---

## What the chart installs

| | |
|---|---|
| Deployment | The application. Probes wired to the right endpoints — see below. |
| Job (`pre-install`, `pre-upgrade`) | Runs schema migrations **before** any pod starts |
| Service, Ingress *(or Route)* | Reaching it |
| PersistentVolumeClaim | Uploads, agent workspaces, in-app snapshots. `resource-policy: keep` — `helm uninstall` does not delete your attachments. |
| Secret | Configuration, unless you supply `existingSecret` |
| NetworkPolicy *(opt-in)* | Default-deny egress |
| ServiceMonitor *(opt-in)* | Prometheus Operator |
| CronJob *(opt-in)* | `mongodump` into the data volume |
| PodDisruptionBudget, HPA *(opt-in)* | |

### The probes

Getting these backwards causes an outage rather than preventing one, so the
chart wires them and you should not override them:

| Probe | Path | Why |
|---|---|---|
| `livenessProbe` | `/api/v1/health/live` | Never touches MongoDB |
| `readinessProbe` | `/api/v1/health/ready` | Fails when MongoDB is unreachable |
| `startupProbe` | `/api/v1/health/live` | Generous — covers migrations on first boot |

Pointing `livenessProbe` at `/health` or `/health/ready` restarts **every**
replica during a database failover: the one moment when killing the application
lengthens the outage instead of ending it.

### Migrations

`migrations.onBoot: manual` plus the pre-upgrade Job is the default, and is the
right pairing in a cluster. Migrations run **once, from a Job, before any new
pod starts**, and a failed migration fails the upgrade visibly — rather than
leaving pods crash-looping while `helm upgrade` reports success.

The runner is safe under concurrency on its own (the ledger's unique `_id` is
the lock), so the Job is about visibility, not correctness.

If the release fails at that step, the Job is where the reason is:

```bash
kubectl logs job/tasksense-migrate -n tasksense
```

---

## Storage and replicas

The default `ReadWriteOnce` volume is right for one replica.

For more than one, either use a `ReadWriteMany` storage class, or point
Admin → Storage at S3-compatible object storage and set
`persistence.enabled=false`. The chart refuses the combination of several
replicas and a `ReadWriteOnce` volume — otherwise the failure is a pod that
never schedules, with the reason buried in an event.

With one replica and a `ReadWriteOnce` volume the deployment strategy is
`Recreate`, not `RollingUpdate`: the new pod cannot mount a volume the old one
still holds, so a rolling update would hang until its deadline. A few seconds of
downtime is the better trade.

---

## Networking

**Ingress.** The annotations in `values.yaml` matter. Live updates are
server-sent events, so `proxy-buffering: off` and a long read timeout are
required — without them the interface looks frozen, because changes arrive only
when the buffer happens to flush. `proxy-body-size` must be at least
`storageMaxFileMb`, or uploads are rejected before they reach the application
and the error comes from the wrong place.

**NetworkPolicy.** Off by default, worth turning on. The application makes
outbound requests to URLs an administrator configures — webhooks, importers, a
model endpoint — and this is the layer that bounds them regardless of what is
typed into the admin console. List what it may reach:

```yaml
networkPolicy:
  enabled: true
  egressCIDRs:
    - 10.20.0.0/16      # MongoDB, the directory, the mail relay
```

DNS to `kube-system` is allowed automatically. Without that rule the policy
blocks the database as effectively as it blocks the internet.

---

## Upgrading

```bash
helm upgrade tasksense ./helm/tasksense -n tasksense --reuse-values \
  --set image.tag=1.1.0 --wait
```

One minor version at a time — migrations run in order, and skipping a release
skips its migration. Read the release notes first, and take a database backup:
`helm rollback` reverts the manifests, not a schema change.

```bash
helm rollback tasksense -n tasksense
```

---

## Verifying

```bash
kubectl rollout status deploy/tasksense -n tasksense
kubectl logs job/tasksense-migrate -n tasksense

kubectl port-forward svc/tasksense 8080:80 -n tasksense
curl http://localhost:8080/api/v1/health/ready
curl http://localhost:8080/api/v1/version
```

`/version` reports what is actually running, which is the first thing to check
after an upgrade and the first line of any support conversation.
