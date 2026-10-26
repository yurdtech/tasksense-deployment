# Installing on Kubernetes

For clusters you already run. If you do not have one, [Docker
Compose](01-INSTALL-COMPOSE.md) is easier to operate and easier to restore, and
for a few hundred users the capacity difference is theoretical. OpenShift uses
the same chart — read this page, then [03-INSTALL-OPENSHIFT](03-INSTALL-OPENSHIFT.md)
for what differs.

| Requirement | |
|---|---|
| Kubernetes | 1.25 or newer (OpenShift 4.12+) |
| Helm | 3.14 or newer (3.8 is the floor for OCI charts; 3.14 adds `--reset-then-reuse-values`) |
| MongoDB | 6.0 or newer, **external**, a replica set recommended — [16-EXTERNAL-DATABASES](16-EXTERNAL-DATABASES.md) |
| Storage | A storage class for the data volume (ReadWriteOnce; **ReadWriteMany** for the import worker) |
| Ingress | An ingress controller (ingress-nginx or F5 NGINX get their annotations automatically) |
| Registry | A read-only registry token from us, or your own mirror — [13-REGISTRY-ACCESS](13-REGISTRY-ACCESS.md) |
| TaskSense | 1.1.0 or newer (chart 1.1.0) |

---

## What the chart installs

TaskSense is **one active API process**, plus an optional import worker. That
is a property of the application, not a chart limitation: its schedulers and the
live-update feed run in-process, without a distributed lock, so two API
replicas would run every scheduled job twice. The chart therefore refuses
`replicaCount` above 1, deploys with `strategy: Recreate` (never two overlapping,
not even during an upgrade), and ships no HPA and no PodDisruptionBudget.
Availability comes from Kubernetes restarting the pod and from your MongoDB
replica set — [15-SCALING-AND-HA](15-SCALING-AND-HA.md) explains the numbers.

| Object | What it is |
|---|---|
| Deployment `<release>` | The API (port 3000), 1 replica, `WORKER_ROLE=all` (or `api` with the worker) |
| Deployment `<release>-worker` *(opt-in)* | The import worker, `node dist/worker.js`, `WORKER_ROLE=worker` — lands Jira site backups |
| Job `<release>-migrate` (hook) | Schema migrations, **before** the new pod starts, on install and upgrade |
| Job `<release>-pre-upgrade-backup` (hook, opt-in) | `mongodump` before the migrations of every upgrade |
| CronJob `<release>-backup` *(opt-in)* | Nightly `mongodump` |
| PVC `<release>-data` | Attachments, workspaces, upload staging (`TMPDIR`). Kept on uninstall |
| PVC `<release>-backups` *(opt-in)* | The dumps. Kept on uninstall |
| ConfigMap `<release>-env` | Every non-secret setting, explicitly — `kubectl get cm` shows what runs |
| Secret `<release>-secrets` | Unless you supply `existingSecret` |
| Service, Ingress ×3 *(or a Route)* | Main, event streams, large uploads — see [Networking](#networking) |
| ServiceAccount | No permissions, no token mounted |
| NetworkPolicy, ServiceMonitor *(opt-in)* | Default-deny egress; Prometheus Operator |
| Pod `<release>-test-ready` (`helm test`) | Ready + version check through the Service |

Every pod runs non-root with a read-only root filesystem, all capabilities
dropped, no privilege escalation, `RuntimeDefault` seccomp and no
ServiceAccount token — a namespace labelled for Pod Security Admission
`restricted` admits all of them. On Kubernetes the image's uid 1001 is pinned
(fsGroup 1001; the backup Jobs use the `mongo` image's 999); on OpenShift
nothing is pinned and the `restricted-v2` SCC assigns the uid — the chart
detects which one it is talking to.

---

## Install

The steps assume namespace `tasksense` and release name `tasksense`. Replace
`1.1.0` with the version you are installing.

### Step 1 — Namespace and image pull secret

```bash
kubectl create namespace tasksense

kubectl create secret docker-registry ghcr -n tasksense \
  --docker-server=ghcr.io \
  --docker-username=yurdtech \
  --docker-password="$TASKSENSE_REGISTRY_TOKEN"
```

Expected:

```
namespace/tasksense created
secret/ghcr created
```

The username is `yurdtech` — the account the token belongs to, not yours. The
token is read-only and issued per customer; no token yet, ask
**info@yurdtech.az**. The chart expects the secret to be named `ghcr` by
default (`imagePullSecrets`). From your own mirror, see [Air-gapped](#air-gapped-install).

To pull the chart itself from the OCI registry, sign Helm in once:

```bash
echo "$TASKSENSE_REGISTRY_TOKEN" | helm registry login ghcr.io -u yurdtech --password-stdin
```

Expected: `Login Succeeded`.

### Step 2 — The Secret

The values in a Helm release are readable by anyone who can read the release.
Create the secrets yourself — or from Vault, sealed-secrets, an external-secrets
operator — and give the chart the name:

```bash
umask 077
cat > tasksense-secrets.env <<'EOF'
MONGODB_URI=mongodb://tasksense:PASSWORD@mongo-0.db.corp.internal:27017,mongo-1.db.corp.internal:27017,mongo-2.db.corp.internal:27017/?replicaSet=rs0&authSource=admin&tls=true&tlsCAFile=/certs/corp-ca.pem
EOF
printf 'STORAGE_SECRET=%s\n' "$(openssl rand -base64 32)" >> tasksense-secrets.env

kubectl create secret generic tasksense-secrets -n tasksense --from-env-file=tasksense-secrets.env
```

Expected: `secret/tasksense-secrets created`. Then store `STORAGE_SECRET` with
your database backups and delete the file (`shred -u tasksense-secrets.env`).

| Key | | |
|---|---|---|
| `MONGODB_URI` | required | Replica set, TLS, auth database in the URI. Percent-encode `/ : @ ? # [ ] %` in the password |
| `STORAGE_SECRET` | required | ≥ 32 characters. Encrypts stored provider credentials. **Not recoverable** — back it up with the database |
| `METRICS_TOKEN` | with `metrics.enabled` | Bearer token for `/api/v1/metrics` (`openssl rand -hex 32`) |
| `LICENSE_KEY` | optional | Your licence ([14-LICENSING](14-LICENSING.md)) |
| `OIDC_CLIENT_SECRET` | with OIDC | [05-IDENTITY](05-IDENTITY.md) |
| `SMTP_PASS` | with an authenticated relay | |

`APP_URL`, `CORS_ALLOWED_ORIGINS` and `FIRST_ADMIN_EMAIL` are not secrets: the
chart renders them from `appUrl` / `firstAdminEmail`. A Secret made for chart
1.0 may still contain them; it is only used for them when `appUrl` is empty.

For a quick trial you can instead put `mongodbUri` and `storageSecret` in the
values file and leave `existingSecret` empty — the chart then renders the Secret.

### Step 3 — The values file

Either let the wizard ask and write it:

```bash
./tasksense          # → Kubernetes
```

It writes `my-values.yaml` (mode 600, in `.gitignore`), prints the exact
`kubectl` and `helm` commands, and runs nothing unless you ask it to.

Or write it yourself. The minimal file:

```yaml
# my-values.yaml
appUrl: https://tasksense.corp.internal
firstAdminEmail: admin@corp.internal
existingSecret: tasksense-secrets

ingress:
  enabled: true
  className: nginx
  tls:
    - secretName: tasksense-tls
      hosts: [tasksense.corp.internal]
```

`ingress.hosts` defaults to the host of `appUrl`. Everything else has a working
default chosen for production: 12-hour sessions, no Swagger UI, JSON logs, task
execution off. Add what applies to you:

```yaml
# Your internal CA — MongoDB TLS, SMTP, LDAPS, OIDC and an LLM gateway in one place.
certs:
  files:
    corp-ca.pem: |
      -----BEGIN CERTIFICATE-----
      ...
      -----END CERTIFICATE-----
  caBundle: corp-ca.pem            # → NODE_EXTRA_CA_CERTS=/certs/corp-ca.pem

# Jira migration: the import worker, on ReadWriteMany storage.
worker:
  enabled: true
persistence:
  accessMode: ReadWriteMany
  storageClass: nfs-client
  size: 200Gi

# Nightly dump + a dump before every upgrade, on their own volume.
backup:
  enabled: true
  timeZone: Asia/Baku

# Bound outbound traffic to what TaskSense needs.
networkPolicy:
  enabled: true
  egressCIDRs: [10.20.0.0/16]      # MongoDB, directory, mail relay, IdP
```

The full list is in [the values reference](#values-reference) below and, with
explanations, in `helm/tasksense/values.yaml`.

### Step 4 — Render it first

```bash
helm template tasksense oci://ghcr.io/yurdtech/charts/tasksense --version 1.1.0 \
  -n tasksense -f my-values.yaml > /tmp/tasksense-rendered.yaml && echo rendered
```

Expected: `rendered`. The chart refuses a configuration that would install
something broken, and names the value to change:

| You set | The render fails with |
|---|---|
| `replicaCount: 2` | `replicaCount=2 is not supported: the TaskSense API must run as exactly one active process …` |
| `autoscaling.enabled: true` | `autoscaling.enabled=true is not supported (the HPA was removed in chart 1.1.0) …` |
| `podDisruptionBudget.enabled: true` | `… blocks every node drain forever …` |
| `worker.enabled` on ReadWriteOnce | `worker.enabled=true needs persistence.accessMode=ReadWriteMany …` |
| a short `storageSecret` | `storageSecret must be at least 32 characters …` |
| `config.agentExecutor: on` | `… this chart always renders AGENT_EXECUTOR=off …` |
| `config.jiraBackupMaxGb` above `ingress.uploadMaxBody` | `ingress.uploadMaxBody (21g) is smaller than config.jiraBackupMaxGb …` |
| metrics without a token | `metrics.token is required when metrics.enabled …` |

### Step 5 — Install

```bash
helm install tasksense oci://ghcr.io/yurdtech/charts/tasksense --version 1.1.0 \
  -n tasksense -f my-values.yaml --wait --timeout 30m
```

From a checkout of this repository (or the offline bundle) use the chart
directory instead: `helm install tasksense ./helm/tasksense -n tasksense -f my-values.yaml --wait --timeout 30m`.

`--timeout 30m`, not the default 5: the migration Job is a hook, Helm waits for
it, and on a large database index builds take minutes.

Expected (abridged):

```
NAME: tasksense
NAMESPACE: tasksense
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
TaskSense 1.1.0 — chart 1.1.0, release tasksense (revision 1) in tasksense.

  image        ghcr.io/yurdtech/tasksense:1.1.0
  api          1 replica, strategy Recreate, WORKER_ROLE=all, heap 1536 MB
  ...
```

### Step 6 — Verify

```bash
kubectl -n tasksense get pods
kubectl -n tasksense logs job/tasksense-migrate
helm test tasksense -n tasksense --logs
```

Expected:

```
NAME                         READY   STATUS      RESTARTS   AGE
tasksense-5d8c7b9f6d-x2kqp   1/1     Running     0          2m
tasksense-migrate-7wq9z      0/1     Completed   0          3m
```

The migration log ends with `✓ applied N: …` on a first install, or
`✓ nothing pending — schema is up to date`. `helm test` prints
`Phase: Succeeded` and, with `--logs`, the test pod's output:
`GET /api/v1/health/ready -> 200 {"status":"ok",…}` and the running version.
(`--logs` is the only way to read it: the pod is deleted once it succeeds, so
`kubectl logs tasksense-test-ready` afterwards finds nothing.) From outside the cluster:

```bash
curl -s https://tasksense.corp.internal/api/v1/health/ready
curl -s https://tasksense.corp.internal/api/v1/version
```

`/version` reports what is actually running — the first thing to check after an
upgrade and the first line of any support conversation.

### Step 7 — First sign-in

`firstAdminEmail` is the administrator of the new, empty workspace and has **no
password**. Sign in through your identity provider (OIDC) or directory (Admin →
Authentication, configured in the application), or register with that address
to set one. No default credential ships with the product.

---

## Private CA

Everything TaskSense connects to with TLS — MongoDB, the mail relay, LDAPS, the
OIDC issuer, an internal model gateway — is verified against Node's built-in
roots plus `NODE_EXTRA_CA_CERTS`. Mount your CA once and every connection
trusts it:

| Source | Value | Use for |
|---|---|---|
| Inline PEM | `certs.files.<name>.pem` | CA bundles (public) — simplest |
| Your ConfigMap | `certs.existingConfigMap` | CA bundles managed elsewhere |
| Your Secret | `certs.existingSecret` | client certificates and keys |

All of them appear read-only under `/certs` in the API, the worker, the
migration Job and the backup Jobs. `certs.caBundle: corp-ca.pem` sets
`NODE_EXTRA_CA_CERTS=/certs/corp-ca.pem`; the MongoDB URI names the same file
with `tlsCAFile=/certs/corp-ca.pem`. The directory (LDAP) CA is the exception: it
is pasted in the application, Admin → Authentication.

```bash
kubectl -n tasksense exec deploy/tasksense -- ls -l /certs
```

Expected: your file(s), e.g. `corp-ca.pem`.

---

## The import worker

For a Jira migration. A site backup (up to `config.jiraBackupMaxGb`, 20 GB) is
uploaded to the API, staged on the data volume (`TMPDIR=/app/api/data/tmp`) and
**landed** — turned into workspaces — by the worker in its own pod, with its own
heap (`worker.heapMb`, 4096) and limits (6Gi, 2 CPU). A migration that exhausts
the worker cannot take the user-facing API down; the worker restarts and resumes
at its last checkpoint.

The API stages and the worker reads the same files, usually from another node,
so `worker.enabled` requires `persistence.accessMode: ReadWriteMany` — NFS,
CephFS / ODF, Azure Files, EFS, Longhorn RWX. Without RWX storage leave the
worker off: the API (`WORKER_ROLE=all`) lands the backups itself.

```bash
kubectl -n tasksense logs deploy/tasksense-worker | head -1
```

Expected: `[tasksense-worker] up — landings sweep runs here; interactive workloads do not`.

Size the data volume for twice the largest backup plus your attachments: the
uploaded XML is kept `config.jiraBackupRetentionDays` (7) so the rest of a
migration can land from the same upload.

**An installation already running on a ReadWriteOnce claim** cannot switch it to
ReadWriteMany in place. Scale the API to 0, create an RWX claim, copy
`/app/api/data` across with a one-off pod that mounts both (`cp -a`), then
upgrade with `worker.enabled: true`, `persistence.accessMode: ReadWriteMany` and
`persistence.existingClaim: <the new claim>`. The old claim stays (it is kept on
uninstall too) until you delete it.

---

## Networking

### Ingress

The chart renders three Ingress objects for the same host(s), because three
kinds of traffic need different proxy settings and annotations apply per object:

| Object | Paths | Settings |
|---|---|---|
| `tasksense` | `/` | body `ingress.maxBody` (25m), timeouts `ingress.timeoutSeconds` (3600) |
| `tasksense-stream` | `/api/v1/state/stream`, `/api/v1/agents/events/stream` | buffering **off**, timeouts 24h — server-sent events; buffered, the interface looks frozen |
| `tasksense-upload` | `/api/v1/integrations/jira/backup`, `/api/v1/import`, `/api/v1/tasks/<id>/attachments`, `/api/v1/docs/<id>/attachments`, `/rest/api/{2,3}/issue/<id>/attachments` | body `ingress.uploadMaxBody` (21g), request buffering **off**, timeouts 4h |

Request buffering is off on the upload paths because nginx would otherwise
spool a 20 GB body to its own disk before forwarding it — the failure we saw in
production was every upload dying with a 408 once that disk filled.

The annotations are set for **ingress-nginx** (`nginx.ingress.kubernetes.io/*`)
and **F5 NGINX** (`nginx.org/*`); other controllers ignore them — add theirs
through `ingress.annotations` (all objects), `ingress.streamAnnotations` or
`ingress.uploadAnnotations`. The attachment paths carry ids, so they are regular
expressions (`ImplementationSpecific`); on a controller without regex paths,
replace `ingress.uploadPaths` with prefixes it understands. `cert-manager.io/*`
annotations are applied to the main object only, so one Certificate owns the
TLS secret all three share.

### NetworkPolicy

Off by default, worth turning on. It selects every pod of the release (API,
worker, Jobs), allows ingress from the ingress controller (and the
`ingressNamespaceSelectors` you list) and egress only to the cluster DNS and
`egressCIDRs`. The application makes outbound requests to URLs an administrator
configures — webhooks, importers, a model endpoint — and this is the layer that
bounds them. Namespaces are detected (`ingress-nginx`, `monitoring`,
`kube-system` here; the router, user-workload monitoring and `openshift-dns` on
OpenShift) and can be set explicitly. An in-cluster MongoDB in another namespace
goes in `networkPolicy.extraEgress`.

---

## Backups and restore

`backup.enabled: true` creates a backups volume (`backup.persistence`, kept on
uninstall) and:

- a **CronJob** (`backup.schedule`, `0 2 * * *`) that runs `mongodump` of
  `config.mongodbDatabase` into `mongodump-<UTC>.archive.gz`;
- with `migrations.backupBeforeUpgrade` (default true), a **pre-upgrade Job**
  that writes `pre-upgrade-rev<N>-to-<version>-<UTC>.archive.gz` **before** the
  migrations run. A failed dump stops the upgrade before anything is migrated.

Each dump has a `.json` manifest next to it. Dumps older than
`backup.retentionDays` (30) are deleted. The MongoDB password never appears on a
command line (it is passed to `mongodump` in a file on an in-memory volume).

The very first upgrade that turns backups on takes no pre-upgrade dump — the
volume is created by that revision; NOTES says so. Every later one does.

These are dumps of the **database only**. Attachments live on the data volume:
snapshot `tasksense-data` with your CSI snapshots or backup tooling (Velero,
Kasten, Commvault …). A cluster with a MongoDB backup operator can leave
`backup.enabled` off. The full DR picture is [07-BACKUP-DR](07-BACKUP-DR.md).

List the dumps:

```bash
kubectl -n tasksense run backups-ls --rm -it --restart=Never --image=mongo:7 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":999,"fsGroup":999},"containers":[{"name":"ls","image":"mongo:7","command":["ls","-lh","/backups"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"volumeMounts":[{"name":"b","mountPath":"/backups"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"tasksense-backups"}}]}}'
```

(On OpenShift drop the `runAsUser` and `fsGroup` fields.) With a ReadWriteOnce
backups volume, run it when no backup Job is active.

### Restoring a dump

A restore **replaces** the database. Stop the application first, so nothing
writes during it:

```bash
kubectl -n tasksense scale deploy/tasksense --replicas=0
kubectl -n tasksense scale deploy/tasksense-worker --replicas=0   # if enabled
```

Then run a one-off Job (set `DUMP` to the file, and the Secret / database names
to yours):

```yaml
# restore-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: tasksense-restore
  namespace: tasksense
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      securityContext: { runAsNonRoot: true, runAsUser: 999, fsGroup: 999, seccompProfile: { type: RuntimeDefault } }  # OpenShift: drop runAsUser/fsGroup
      containers:
        - name: restore
          image: mongo:7          # your mirror's path with global.imageRegistry
          env:
            - { name: DUMP, value: pre-upgrade-rev3-to-1.1.0-20261016T020000Z.archive.gz }
            - { name: MONGODB_DB, value: tasksense }
            - name: MONGODB_URI
              valueFrom: { secretKeyRef: { name: tasksense-secrets, key: MONGODB_URI } }
          command:
            - /bin/bash
            - -c
            - |
              set -euo pipefail
              q="'"; printf "uri: '%s'\n" "${MONGODB_URI//${q}/${q}${q}}" > /work/uri.yaml
              mongorestore --config=/work/uri.yaml --archive="/backups/${DUMP}" --gzip \
                --nsInclude="${MONGODB_DB}.*" --drop
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          volumeMounts:
            - { name: backups, mountPath: /backups, readOnly: true }
            - { name: work, mountPath: /work }
            # - { name: certs, mountPath: /certs, readOnly: true }   # if the URI names tlsCAFile
      volumes:
        - { name: backups, persistentVolumeClaim: { claimName: tasksense-backups } }
        - { name: work, emptyDir: { medium: Memory, sizeLimit: 1Mi } }
```

```bash
kubectl apply -f restore-job.yaml
kubectl -n tasksense logs -f job/tasksense-restore
```

Expected: the log ends with `… document(s) restored successfully. 0 document(s) failed to restore.`
(If the URI's path names a database other than `MONGODB_DB`, move it into
`authSource=` first — `mongorestore` refuses the combination.) Then bring the
application back at the version that matches the dump — see
[Rollback](#rollback) — and delete the Job.

---

## Upgrade

1. Read the release notes. Versions may be skipped: migrations apply in order.
   Downgrades are not supported — see [Rollback](#rollback).
2. Make sure there is a fresh dump: `backup.enabled` takes one automatically
   before the migrations; otherwise take your own now. Migrations are
   **forward-only**.
3. Render the new version with your file, as in Step 4.
4. Upgrade — with your values file, **never `--reuse-values`** across chart
   versions (it drops every default the new chart adds, and the chart refuses
   to render):

   ```bash
   helm upgrade tasksense oci://ghcr.io/yurdtech/charts/tasksense --version 1.1.0 \
     -n tasksense -f my-values.yaml --wait --timeout 30m
   ```

   (Helm 3.14+: `--reset-then-reuse-values` is the safe form of reuse.)

Expected: `Release "tasksense" has been upgraded. Happy Helming!`, then the NOTES
with the new version, and:

```bash
kubectl -n tasksense logs job/tasksense-pre-upgrade-backup | tail -1   # wrote /backups/pre-upgrade-…
kubectl -n tasksense logs job/tasksense-migrate | tail -2              # ✓ applied … / nothing pending
curl -s https://tasksense.corp.internal/api/v1/version                 # the new version
```

The order inside `helm upgrade` is fixed by hook weights: hook copies of the
configuration (-10) → pre-upgrade dump (-8) → migrations (-5) → the old pod is
stopped and the new one started (`Recreate`). The old version keeps serving
while the dump and the migrations run; for a dump of exactly the last state,
scale the API to 0 before upgrading. Expect a short interruption while the pod
is replaced — live views reconnect on their own.

**Upgrading from chart 1.0.** Removed: `autoscaling`, `podDisruptionBudget`,
`migrations.onBoot`, `migrations.hook.*` (now `migrations.enabled`),
`storageMaxFileMb` (now `config.storageMaxFileMb`); `backup.image` is now
`{repository, tag}`. The render names each one still in your file. The
Deployment's selector and the data claim's name are unchanged, so the upgrade
is in place. The chart never resizes a bound claim: a 1.0 claim keeps its 20Gi
although the default is now 50Gi, and NOTES prints the `kubectl patch pvc` to
grow it where the storage class allows expansion. Access modes cannot change on
a bound claim either — turning the worker on over a 1.0 ReadWriteOnce claim
stops the render with the steps (new RWX claim, copy, `persistence.existingClaim`).
The chart-managed Secret is now `<release>-secrets` (was `<release>-config`);
non-secret settings moved to the ConfigMap `<release>-env`.

## Rollback

`helm rollback` reverts the manifests, **not** the database: a migration that
ran stays applied, and the previous version would serve a schema it does not
know (`/health` reports `schema.state: "ahead"`). So a rollback after a
migrating upgrade is a restore:

1. Stop the application (`kubectl scale … --replicas=0`, as above).
2. Restore the `pre-upgrade-…` dump taken by that upgrade ([Restoring a dump](#restoring-a-dump)).
3. Roll the release back:

   ```bash
   helm history tasksense -n tasksense
   helm rollback tasksense <previous revision> -n tasksense --wait --timeout 30m
   ```

Expected: `Rollback was a success! Happy Helming!`; `/api/v1/version` reports
the previous version and `helm test` passes without a schema warning. If the
upgrade ran no migration (`nothing pending` in its log), step 2 is unnecessary.

---

## Air-gapped install

On a machine with internet access, from a checkout of this repository at the
release tag, signed in to `ghcr.io`:

```bash
scripts/helm-airgap-bundle.sh --version 1.1.0
```

Expected: `==> …/dist/tasksense-helm-airgap-1.1.0.tar.gz` and its `.sha256`. The
bundle holds the chart package, `values-openshift.yaml`, the TaskSense image and
the `mongo` image the backup Jobs use (linux/amd64; `--platform` to change), a
manifest with image digests and SHA-256 checksums. `--from-oci` bundles the
published chart instead of the checkout.

Inside the network, signed in to your registry (`docker login`, `podman login`
or `skopeo login` — any of the three works):

```bash
sha256sum -c tasksense-helm-airgap-1.1.0.tar.gz.sha256
mkdir tasksense-bundle && tar -xzf tasksense-helm-airgap-1.1.0.tar.gz -C tasksense-bundle
cd tasksense-bundle
./helm-airgap-load.sh harbor.corp.internal            # --push-chart to also push the chart
```

Expected: every checksum `OK`, then

```
  ghcr.io/yurdtech/tasksense:1.1.0 -> harbor.corp.internal/yurdtech/tasksense:1.1.0
  mongo:7 -> harbor.corp.internal/library/mongo:7
```

and the install command. That is the rule `global.imageRegistry` applies: the
registry host is replaced and the path kept; Docker Hub official images gain
`library/`. Install with:

```bash
kubectl create secret docker-registry tasksense-pull -n tasksense \
  --docker-server=harbor.corp.internal --docker-username='<robot account>' --docker-password='<token>'

helm install tasksense ./tasksense-1.1.0.tgz -n tasksense \
  --set global.imageRegistry=harbor.corp.internal \
  --set 'imagePullSecrets[0].name=tasksense-pull' \
  -f my-values.yaml --wait --timeout 30m
```

If your mirror already follows the Compose layout (`load-images.sh --registry
harbor.corp.internal/tasksense` → `…/tasksense/tasksense`, `…/tasksense/mongo`),
leave `global.imageRegistry` empty and name the repositories instead:
`image.repository: harbor.corp.internal/tasksense/tasksense`,
`backup.image.repository: harbor.corp.internal/tasksense/mongo`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `helm install` fails with `… is not supported` / `… is required` | A render guard | The message names the value — Step 4 table |
| `timed out waiting for the condition` on install/upgrade | `--timeout` shorter than the migration | Re-run with `--timeout 30m`; read `kubectl logs job/tasksense-migrate` |
| Migration Job `Error`, release `failed` | A migration failed (the app would have refused to start) | `kubectl logs job/tasksense-migrate`; fix the cause (often MongoDB reachability or permissions), upgrade again |
| `Cannot reach MongoDB at …` in the migration log | URI, DNS, firewall, TLS | Check `MONGODB_URI`; with TLS, `tlsCAFile=/certs/<file>` and that file in `certs.*`; with NetworkPolicy, the CIDR in `egressCIDRs` |
| Pod `CrashLoopBackOff`, log names a pending migration | The migration hook never ran — the manifests were applied without Helm hooks (`helm template \| kubectl apply`, a GitOps tool that drops hooks) | Install with `helm`, let your GitOps tool run the hook (Argo CD maps it to PreSync), or set `migrations.enabled=false` so the API migrates at boot |
| `ImagePullBackOff` | Pull secret missing / wrong server | `kubectl -n tasksense get secret ghcr`; with a mirror, `imagePullSecrets` and `global.imageRegistry` |
| Upload of a Jira backup fails at once with 413 | The ingress rejects the body | Check `kubectl get ingress tasksense-upload -o yaml` exists and its controller honours the annotations; `ingress.uploadMaxBody` ≥ `config.jiraBackupMaxGb` |
| Live updates arrive late or the UI says "reconnecting" | The stream is buffered or cut | `tasksense-stream` Ingress present? Another proxy (WAF, F5) in front also needs buffering off and a 24h timeout |
| Worker never starts: `Multi-Attach error` / pod `Pending` | Volume is not really ReadWriteMany | Use an RWX storage class |
| `kubectl drain` hangs on the TaskSense pod | A PodDisruptionBudget someone added outside the chart | Remove it — one replica cannot satisfy `minAvailable: 1` |
| Sign-in loops or CORS errors | `appUrl` differs from the URL in the browser | Set `appUrl` to exactly that URL; the ingress host follows it |
| `pre-upgrade-backup` Job `Pending` | The backups claim cannot be bound | `kubectl describe pvc tasksense-backups`; storage class, quota |

Collecting logs for support: `kubectl -n tasksense logs deploy/tasksense --since=1h`,
`kubectl -n tasksense get events --sort-by=.lastTimestamp`, `helm get values tasksense -n tasksense`
(remove secrets before sending). More in [10-TROUBLESHOOTING](10-TROUBLESHOOTING.md).

---

## Values reference

Environment variables are documented one by one in [17-ENVIRONMENT](17-ENVIRONMENT.md).
**(S)** = rendered into the Secret (with `existingSecret`, a key there instead).

| Value | Default | Environment / effect |
|---|---|---|
| `appUrl` | — (required) | `APP_URL`; its origin → `CORS_ALLOWED_ORIGINS`; default Ingress/Route host |
| `mongodbUri` | — (required without `existingSecret`) | `MONGODB_URI` **(S)** |
| `storageSecret` | — (required without `existingSecret`) | `STORAGE_SECRET` **(S)**, ≥ 32 characters |
| `firstAdminEmail` | `""` | `FIRST_ADMIN_EMAIL` (first install) |
| `licenseKey` | `""` | `LICENSE_KEY` **(S)** |
| `existingSecret` | `""` | Secret with the **(S)** keys |
| `replicaCount` | `1` | Must be 0 or 1 |
| `heapMb` | `1536` | API `NODE_OPTIONS=--max-old-space-size=1536` |
| `resources` | req 500m / 1Gi, limit 2Gi | API pod |
| `terminationGracePeriodSeconds` | `45` | API drain time |
| `worker.enabled` | `false` | Import worker; API gets `WORKER_ROLE=api` |
| `worker.heapMb` | `4096` | Worker `NODE_OPTIONS` |
| `worker.resources` | req 500m / 2Gi, limit 2 CPU / 6Gi | Worker pod |
| `config.mongodbDatabase` | `tasksense` | `MONGODB_DB` (also what the backups dump) |
| `config.mongodbTimeoutMs` | `15000` | `MONGODB_TIMEOUT_MS` (app default 5000) |
| `config.mongodbOpTimeoutMs` | `30000` | `MONGODB_OP_TIMEOUT_MS` |
| `config.mongodbMinPoolSize` / `MaxPoolSize` | `10` / `100` | `MONGODB_MIN_POOL_SIZE` / `MONGODB_MAX_POOL_SIZE` |
| `config.mongodbCompressors` | `zlib` | `MONGODB_COMPRESSORS` (`zlib` \| `none`) |
| `config.sessionTtlHours` | `12` | `SESSION_TTL_HOURS` (app default 720; 0 = never) |
| `config.swaggerEnabled` | `false` | `SWAGGER_ENABLED` (app default on) |
| `config.ownerEmails` | `""` | `OWNER_EMAILS` — keep empty |
| `config.agentDispatcher` | `"off"` | `AGENT_DISPATCHER` |
| — | — | `AGENT_EXECUTOR` is always `off`; setting `config.agentExecutor` fails |
| `config.egressAllowlist` | `[]` | `EGRESS_ALLOWLIST` (list or CSV) |
| `config.rateLimitStore` | `memory` | `RATE_LIMIT_STORE` |
| `config.storageMaxFileMb` | `25` | `STORAGE_MAX_FILE_MB` |
| `config.storageMaxVideoFileMb` | `200` | `STORAGE_MAX_VIDEO_FILE_MB` |
| `config.jiraBackupMaxGb` | `20` | `JIRA_BACKUP_MAX_GB` |
| `config.jiraBackupRetentionDays` | `7` | `JIRA_BACKUP_RETENTION_DAYS` |
| `config.stateTaskLimit` | `5000` | `STATE_TASK_LIMIT` |
| `config.reportsMaxTasks` | `150000` | `REPORTS_MAX_TASKS` |
| `config.automationProcessingMinutesPer12h` | `60` | `AUTOMATION_PROCESSING_MINUTES_PER_12H` |
| `config.corsAllowedOrigins` | `[]` | Extra `CORS_ALLOWED_ORIGINS` |
| `config.oidc.issuer` / `clientId` / `redirectUri` / `label` | `""` | `OIDC_ISSUER` / `OIDC_CLIENT_ID` / `OIDC_REDIRECT_URI` / `OIDC_LABEL` |
| `config.oidc.clientSecret` | `""` | `OIDC_CLIENT_SECRET` **(S)** |
| `config.smtp.host` / `port` / `secure` / `user` | `""` / `587` / `false` / `""` | `SMTP_HOST` / `SMTP_PORT` / `SMTP_SECURE` / `SMTP_USER` |
| `config.smtp.pass` | `""` | `SMTP_PASS` **(S)** |
| `config.emailFrom` | `""` | `EMAIL_FROM` |
| `logging.format` / `level` | `json` / `log` | `LOG_FORMAT` / `LOG_LEVEL` |
| `metrics.enabled` / `token` | `false` / `""` | `METRICS_ENABLED` / `METRICS_TOKEN` **(S)** |
| `metrics.serviceMonitor.enabled` | `false` | Prometheus Operator ServiceMonitor |
| `extraEnv` / `extraEnvFrom` | `{}` / `[]` | Anything else (chart-owned names are refused) |
| — | — | Always: `TMPDIR=/app/api/data/tmp`, `MIGRATE_ON_BOOT` (manual with the Job), `DEPLOYMENT_MODE=onprem`, `NODE_ENV=production` |
| `certs.files` / `existingConfigMap` / `existingSecret` | — | Mounted at `/certs` |
| `certs.caBundle` | `""` | `NODE_EXTRA_CA_CERTS=/certs/<caBundle>` |
| `extraVolumes` / `extraVolumeMounts` | `[]` | API, worker, migration Job |
| `serviceAccount.create` / `automountToken` | `true` / `false` | |
| `migrations.enabled` | `true` | Hook Job; `MIGRATE_ON_BOOT=manual` (false → `auto`) |
| `migrations.backupBeforeUpgrade` | `true` | Pre-upgrade dump (needs `backup.enabled`) |
| `migrations.activeDeadlineSeconds` / `ttlSecondsAfterFinished` / `backoffLimit` | `1800` / `86400` / `0` | |
| `persistence.enabled` / `accessMode` / `size` / `storageClass` / `existingClaim` | `true` / `ReadWriteOnce` / `50Gi` / `""` / `""` | Data volume |
| `backup.enabled` / `schedule` / `timeZone` / `retentionDays` / `suspend` | `false` / `0 2 * * *` / `""` / `30` / `false` | |
| `backup.image.repository` / `tag` | `mongo` / `7` | Through `global.imageRegistry` |
| `backup.persistence.size` / `storageClass` / `accessMode` / `existingClaim` | `50Gi` / `""` / `ReadWriteOnce` / `""` | Backups volume (kept) |
| `ingress.enabled` / `className` / `hosts` / `tls` | `false` / `nginx` / appUrl's host / `[]` | |
| `ingress.maxBody` / `timeoutSeconds` | `25m` / `3600` | Main object |
| `ingress.streamTimeoutSeconds` | `86400` | Event streams |
| `ingress.uploadMaxBody` / `uploadTimeoutSeconds` / `uploadPaths` | `21g` / `14400` / the five upload routes | Upload object |
| `ingress.annotations` / `streamAnnotations` / `uploadAnnotations` | `{}` | |
| `route.enabled` / `host` / `tls` / `annotations` | `false` / appUrl's host / edge + Redirect / `{}` | OpenShift |
| `networkPolicy.enabled` / `egressCIDRs` / `extraEgress` / `ingressNamespaceSelectors` | `false` / `[]` / `[]` / `[]` | |
| `global.imageRegistry` | `""` | Mirror host for every image |
| `image.repository` / `tag` / `digest` | `ghcr.io/yurdtech/tasksense` / appVersion / `""` | |
| `imagePullSecrets` | `[ghcr]` | |
| `imageCredentials.create` / `registry` / `username` / `password` | `false` / `ghcr.io` / `yurdtech` / `""` | Chart-rendered pull secret |
| `openshift.enabled` | `""` (detect) | Force the OpenShift posture |
| `podSecurityContext` | `{}` | Kubernetes uid/fsGroup overrides |

---

## Uninstalling

```bash
helm uninstall tasksense -n tasksense
```

The data and backups volumes survive on purpose (`resource-policy: keep`), so
attachments and dumps outlive an accidental uninstall. To remove everything:

```bash
kubectl -n tasksense delete pvc tasksense-data tasksense-backups
kubectl -n tasksense delete secret ghcr tasksense-secrets
kubectl delete namespace tasksense               # if it was only for this
```

The database is yours — drop the `tasksense` database there separately if it
should go.
