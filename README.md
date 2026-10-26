# TaskSense — On-Premise Deployment

Everything needed to run **TaskSense** inside your own network: the Docker
Compose stack, the Helm chart, install / upgrade / backup scripts, reverse-proxy
and alerting examples, and the operations documentation.

TaskSense is a task-intelligence platform — boards, sprints, backlog, a docs
knowledge base, service desk, automation, reporting, Jira migration and
optional AI agents. This repository is the **deployment surface only**: there
is no application source here. The image is pre-built, signed and versioned,
and you pull it from our private registry with a read-only token.

**No component of a running installation contacts the internet.** Identity,
mail, object storage and — if you use the AI features — the language model all
point at services inside your own network.
[docs/06-SECURITY.md](docs/06-SECURITY.md) shows how to verify that rather than
take our word for it.

> **Minimum application version: TaskSense 1.1.0.** These deployment files
> (profiles, the `migrate` service, the import worker, the Helm guards) expect
> 1.1.0 or later. Each release stamps its version into
> `compose/.env.example` and `helm/tasksense/Chart.yaml`.

---

## Choose your deployment

Two equal, fully supported options. Both run the same image and the same
feature set; pick the one that fits your infrastructure.

| | **Option A — Docker Compose** | **Option B — Helm chart** |
| --- | --- | --- |
| Runs on | one Linux VM with Docker + Compose v2.20+ | Kubernetes 1.27+ / OpenShift 4.12+ (`restricted-v2`) |
| Full guide | [docs/01-INSTALL-COMPOSE.md](docs/01-INSTALL-COMPOSE.md) — or the `./tasksense` wizard | [docs/02-INSTALL-KUBERNETES.md](docs/02-INSTALL-KUBERNETES.md), [docs/03-INSTALL-OPENSHIFT.md](docs/03-INSTALL-OPENSHIFT.md) |
| Configuration | `compose/.env` — the only file you edit | `my-values.yaml` + a Kubernetes Secret |
| Database | bundled MongoDB 7 (profile `bundled-mongo`), or yours via `MONGODB_URI` | yours — the chart bundles none |
| Exposure / TLS | loopback port + your reverse proxy ([examples/](examples/)) | Ingress or OpenShift Route |
| Scaling | **vertical**: one active API process, sized with CPU/memory limits; optional import worker (0 or 1) for Jira migrations | the same: `replicaCount` is fixed at 1 (the chart refuses more), `Recreate` upgrades; optional `worker.enabled` |
| High availability | Docker restarts the process; VM-level HA; MongoDB replica set | Kubernetes restarts / reschedules the pod; MongoDB replica set |
| Upgrades | `scripts/upgrade.sh` — backup, migrate, verify; `rollback.sh` restores the pre-upgrade backup | `helm upgrade` — pre-upgrade dump + migration Job |
| Air-gapped installs | offline bundle + `install.sh --offline` | `scripts/helm-airgap-bundle.sh` / `helm-airgap-load.sh` |

Why one API process, and what "HA" honestly means here:
[docs/15-SCALING-AND-HA.md](docs/15-SCALING-AND-HA.md).

Before installing, start with [docs/18-PRE-INSTALL-CHECKLIST.md](docs/18-PRE-INSTALL-CHECKLIST.md)
— firewall matrix, certificates, directory, database and who does what.

---

## Option A — Docker Compose quick start

> New to this? Follow the full guide instead — it shows what every command
> should print: **[docs/01-INSTALL-COMPOSE.md](docs/01-INSTALL-COMPOSE.md)**.
> Or run `./tasksense`, which asks the questions and does all of this.

```bash
# 0. Requirements: Docker 24+ and Docker Compose v2.20+, and the registry token we gave you.

# 1. Get the deployment files
git clone https://github.com/yurdtech/tasksense-deployment.git
cd tasksense-deployment

# 2. Log in to the private registry (one time). The username is always "yurdtech".
echo '<TOKEN>' | docker login ghcr.io -u yurdtech --password-stdin
#    → Login Succeeded

# 3. Create the configuration
cp compose/.env.example compose/.env && chmod 600 compose/.env
#    → edit compose/.env: APP_URL, CORS_ALLOWED_ORIGINS, FIRST_ADMIN_EMAIL,
#      STORAGE_SECRET (openssl rand -base64 32), MONGO_PASSWORD (openssl rand -hex 24),
#      LICENSE_KEY. The template already carries the recommended defaults
#      (SESSION_TTL_HOURS=12, SWAGGER_ENABLED=false, AGENT_EXECUTOR=off) — keep them.

# 4. Check it before starting anything
./scripts/preflight.sh
#    → ✓ preflight passed.

# 5. Pull, migrate and start (waits for the health check)
./scripts/install.sh
#    (by hand: docker compose -f compose/docker-compose.yml pull && … up -d)

# 6. Verify
docker compose -f compose/docker-compose.yml ps -a
#    → tasksense-app running (healthy), tasksense-mongo running (healthy),
#      tasksense-migrate Exited (0) — the one-shot migrator, finished
curl -s http://127.0.0.1:3000/api/v1/health
#    → {"status":"ok",…,"database":"up","indexes":"ready","schema":{"state":"current"}}
```

Then put TLS in front ([examples/nginx.conf](examples/nginx.conf)), sign in as
`FIRST_ADMIN_EMAIL` (it has no password until you claim it), and schedule
backups ([docs/07-BACKUP-DR.md](docs/07-BACKUP-DR.md)).

---

## Option B — Helm chart quick start

> Full guide, with OpenShift Routes, Ingress, NetworkPolicy, backups and the
> values reference: **[docs/02-INSTALL-KUBERNETES.md](docs/02-INSTALL-KUBERNETES.md)**.

```bash
# 0. Requirements: kubectl + Helm 3.14+, a cluster, a MongoDB 7 you run, and the registry token.

# 1. Namespace + image pull secret (same token as Option A)
kubectl create namespace tasksense
kubectl -n tasksense create secret docker-registry ghcr \
  --docker-server=ghcr.io --docker-username=yurdtech --docker-password='<TOKEN>'

# 2. The secrets, as one Kubernetes Secret (or from Vault / External Secrets)
kubectl -n tasksense create secret generic tasksense-secrets \
  --from-literal=MONGODB_URI='mongodb://tasksense:<pw>@mongo-1.corp.internal:27017,mongo-2.corp.internal:27017,mongo-3.corp.internal:27017/?replicaSet=rs0&authSource=admin&tls=true&tlsCAFile=/certs/corp-ca.pem' \
  --from-literal=STORAGE_SECRET="$(openssl rand -base64 32)" \
  --from-literal=LICENSE_KEY='tsl_…'
#    → secret/tasksense-secrets created

# 3. Your CA, mounted at /certs and trusted process-wide
kubectl -n tasksense create configmap tasksense-ca --from-file=corp-ca.pem

# 4. A minimal values file
cat > my-values.yaml <<'EOF'
appUrl: https://tasksense.corp.internal
firstAdminEmail: tasksense-admin@corp.internal
existingSecret: tasksense-secrets
certs:
  existingConfigMap: tasksense-ca
  caBundle: corp-ca.pem            # → NODE_EXTRA_CA_CERTS=/certs/corp-ca.pem
config:
  sessionTtlHours: 12              # the chart's defaults already; stated for the reviewer
  swaggerEnabled: false
EOF

# 5. Install from the OCI registry (dump + migrations run first, as hook Jobs)
echo '<TOKEN>' | helm registry login ghcr.io -u yurdtech --password-stdin
helm install tasksense oci://ghcr.io/yurdtech/charts/tasksense \
  --version 1.1.0 -n tasksense -f my-values.yaml --wait --timeout 30m
#    → STATUS: deployed      (--timeout: the first migration can outlast Helm's 5-minute default)

# 6. Verify
kubectl -n tasksense get pods            # → tasksense-… 1/1 Running
kubectl -n tasksense logs job/tasksense-migrate
helm test tasksense -n tasksense --logs  # → Phase: Succeeded
```

The API runs as exactly one pod by design; the chart refuses `replicaCount`
above 1, autoscaling, and the import worker without `ReadWriteMany` storage.
Expose it with an Ingress or, on OpenShift, a Route —
[docs/03-INSTALL-OPENSHIFT.md](docs/03-INSTALL-OPENSHIFT.md).

---

## Bundled MongoDB, or your own?

**Bundled (Compose default).** TaskSense runs MongoDB 7 in a container on an
internal network with no published port; the data lives in the
`tasksense-mongo-data` volume. Nothing to configure. Good for pilots and small
installations.

**Your own (Compose option, Helm always).** If your DBAs run MongoDB, point
TaskSense at it — a dedicated account with `readWrite` + `dbAdmin` on one
database, a replica set, TLS with your CA:

```dotenv
# compose/.env — drop the profile, set the URI
COMPOSE_PROFILES=
MONGODB_URI=mongodb://tasksense:<pw>@mongo-1.corp.internal:27017,mongo-2.corp.internal:27017,mongo-3.corp.internal:27017/?replicaSet=rs0&authSource=admin&tls=true&tlsCAFile=/certs/corp-ca.pem
MONGODB_TIMEOUT_MS=15000
```

You never edit `docker-compose.yml` or the chart templates. `backup.sh` backs
up either kind. Full guide: [docs/16-EXTERNAL-DATABASES.md](docs/16-EXTERNAL-DATABASES.md).

---

## Getting the software

| Your servers can… | Use | |
| --- | --- | --- |
| reach `ghcr.io` during installs | `docker login` / `helm registry login` with the token | [13 › Pulling directly](docs/13-REGISTRY-ACCESS.md#pulling-directly) |
| reach only your Harbor / Nexus / Artifactory | `./scripts/load-images.sh --registry harbor.corp.internal/tasksense --version 1.1.0` | [13 › Mirroring](docs/13-REGISTRY-ACCESS.md#mirroring-into-your-own-registry) |
| reach nothing | the offline bundle: `oras pull ghcr.io/yurdtech/tasksense-offline:1.1.0`, `verify-signature.sh`, carry in, `install.sh --offline` | [13 › Air-gapped](docs/13-REGISTRY-ACCESS.md#no-route-out-air-gapped) |

The registry token is read-only and per customer (username always `yurdtech`).
The offline bundle — deployment files, the TaskSense and `mongo:7` images,
checksums, cosign signature, SBOM and Trivy report — is private and pulled with
the same token. The public
[Releases](https://github.com/yurdtech/tasksense-deployment/releases) page
carries only the deployment files (`tasksense-deployment-<version>.tar.gz`), the
chart (`tasksense-<version>.tgz`), `SHA256SUMS`, `SHA256SUMS.sig` and
`cosign.pub`.

Verify before installing — the script fails closed without cosign:

```bash
cosign verify --key cosign.pub ghcr.io/yurdtech/tasksense:1.1.0
./scripts/verify-signature.sh tasksense-onprem-1.1.0.tar.gz
```

---

## What you need

|              | Minimum (≤ 50 users)         | Recommended (≈ 200 users)       |
| ------------ | ---------------------------- | ------------------------------- |
| CPU          | 2 vCPU                       | 4 vCPU                          |
| Memory       | 4 GB                         | 8 GB                            |
| Disk         | 40 GB                        | 100 GB SSD                      |
| Platform     | Docker 24+, Compose v2.20+   | or Kubernetes 1.27+ / OpenShift 4.12+ |
| Database     | MongoDB 7 (bundled)          | MongoDB 7 replica set           |

A Jira migration adds 2 vCPU, 6 GB RAM and free disk of twice the backup's
size for the window. Sizing: [docs/11-SIZING.md](docs/11-SIZING.md).

---

## Documentation

| Document | Read it if you are |
| --- | --- |
| [00-OVERVIEW](docs/00-OVERVIEW.md) | deciding whether and how to deploy |
| [01-INSTALL-COMPOSE](docs/01-INSTALL-COMPOSE.md) | installing on a VM |
| [02-INSTALL-KUBERNETES](docs/02-INSTALL-KUBERNETES.md) | installing on Kubernetes |
| [03-INSTALL-OPENSHIFT](docs/03-INSTALL-OPENSHIFT.md) | installing on OpenShift |
| [04-CONFIGURATION](docs/04-CONFIGURATION.md) | learning where settings live and how to change one |
| [05-IDENTITY](docs/05-IDENTITY.md) | wiring up Active Directory, LDAP or SSO |
| [06-SECURITY](docs/06-SECURITY.md) | **reviewing this for a security committee** |
| [07-BACKUP-DR](docs/07-BACKUP-DR.md) | responsible for backups and recovery (RPO 24 h / RTO 1 h) |
| [08-UPGRADE](docs/08-UPGRADE.md) | planning an upgrade — or a rollback |
| [09-MONITORING](docs/09-MONITORING.md) | wiring up Prometheus, alerts or a SIEM |
| [10-TROUBLESHOOTING](docs/10-TROUBLESHOOTING.md) | debugging a broken install |
| [11-SIZING](docs/11-SIZING.md) | working out CPU, memory and disk |
| [12-AI-MODELS](docs/12-AI-MODELS.md) | connecting an internal language model |
| [13-REGISTRY-ACCESS](docs/13-REGISTRY-ACCESS.md) | handling the registry token, a mirror or an air-gap |
| [14-LICENSING](docs/14-LICENSING.md) | asking what the licence key does |
| [15-SCALING-AND-HA](docs/15-SCALING-AND-HA.md) | asking "can we run two?" — and what HA means here |
| [16-EXTERNAL-DATABASES](docs/16-EXTERNAL-DATABASES.md) | connecting your own MongoDB |
| [17-ENVIRONMENT](docs/17-ENVIRONMENT.md) | looking up any setting, with the recommended value |
| [18-PRE-INSTALL-CHECKLIST](docs/18-PRE-INSTALL-CHECKLIST.md) | **preparing an on-premise install**: firewall, certificates, accounts, who does what |

---

## What's in this repository

| Path | Purpose |
| --- | --- |
| [`tasksense`](tasksense) | The guided installer and operations panel (`./tasksense`) |
| [`compose/docker-compose.yml`](compose/docker-compose.yml) | **Option A** — the stack: `app`, one-shot `migrate`, optional `worker` and bundled `mongo` (profiles) |
| [`compose/.env.example`](compose/.env.example) | Option A configuration template — copy to `compose/.env`. **The only file you edit.** |
| [`compose/certs/`](compose/certs/) | Your CA bundle; mounted read-only at `/certs` in every container |
| [`helm/tasksense/`](helm/tasksense/) | **Option B** — the Helm chart, also published at `oci://ghcr.io/yurdtech/charts/tasksense` |
| [`scripts/`](scripts/) | `preflight`, `install`, `upgrade`, `rollback`, `backup`, `restore`, `load-images`, `verify-signature`, `collect-diagnostics`, `helm-airgap-bundle` / `-load` |
| [`examples/nginx.conf`](examples/nginx.conf), [`examples/Caddyfile`](examples/Caddyfile) | Reverse-proxy configurations: streams, uploads, keep-alive, safe logging |
| [`examples/prometheus-alerts.yaml`](examples/prometheus-alerts.yaml) | Alert rules for Compose and Kubernetes |
| [`docs/`](docs/) | Everything above |

---

## Operating it (Compose)

```bash
./scripts/preflight.sh              # check the host and .env
./scripts/install.sh                # first install
./scripts/upgrade.sh 1.2.0          # preflight, backup, migrate, start, verify
./scripts/rollback.sh               # previous version AND its pre-upgrade data
./scripts/backup.sh                 # database + files + config (bundled or your MongoDB)
./scripts/restore.sh <archive>      # restore from a backup
./scripts/collect-diagnostics.sh    # bundle logs for support (secrets masked)
```

**Every upgrade starts with `git pull`** (or the new deployment archive):
releases change these files too. Migrations only go forward; a real rollback
restores the backup `upgrade.sh` took — [docs/08-UPGRADE.md](docs/08-UPGRADE.md).

---

## Licensing and support

TaskSense is commercial software. A signed `LICENSE_KEY` enables the licensed
tier; it is **verified offline** — no activation server, no phone-home, no usage
reporting. An expired licence never blocks access to your data.

- **Support, licences, registry tokens:** [info@yurdtech.az](mailto:info@yurdtech.az)
- **Security issues:** [security@yurdtech.az](mailto:security@yurdtech.az) — see [SECURITY.md](SECURITY.md)

When you contact support, send the output of `./scripts/collect-diagnostics.sh`
(Compose) or `kubectl -n tasksense get pods` plus the failing pod's log (Helm).
**Never send `compose/.env`, a Secret, or a backup archive** — they contain
credentials. We have no remote access to your environment.

Bug reports about *deployment* — a script, a manifest, a document — are welcome
as issues here. Application bugs go through support.
