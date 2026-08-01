# TaskSense — On-Premise Deployment

Everything needed to run TaskSense inside your own network: container images,
Docker Compose and Helm manifests, install and upgrade scripts, and the
operations documentation.

TaskSense is a task-intelligence platform — boards, sprints, backlog, a docs
knowledge base, reporting and optional AI agents. This repository is the
**deployment surface only**; the application source is not here.

**No component of a running installation contacts the internet.** Identity, mail,
object storage and — if you use the AI features — the language model all point at
services inside your own network. `docs/06-SECURITY.md` shows how to verify that
claim rather than take our word for it.

---

## Install in four commands

```bash
git clone https://github.com/yurdtech/tasksense-deployment.git
cd tasksense-deployment/compose
cp .env.example .env && ${EDITOR:-vi} .env      # required values are marked
../scripts/install.sh
```

`install.sh` checks the host first, pulls or loads the image, starts the stack
and waits until it answers its own health check. Roughly 30 minutes end to end,
most of it spent deciding what to put in `.env`.

New here? Read [`docs/00-OVERVIEW.md`](docs/00-OVERVIEW.md) first — it covers the
architecture and sizing in two pages.

---

## Getting the image

The image lives in GitHub Container Registry and is private. You will have
received a **registry token** from us; it grants read access to this one package
and nothing else.

```bash
echo "$TASKSENSE_REGISTRY_TOKEN" | docker login ghcr.io -u <username> --password-stdin
docker pull ghcr.io/yurdtech/tasksense:1.0.0
```

Full walkthrough, including rotating and revoking the token:
[`docs/13-REGISTRY-ACCESS.md`](docs/13-REGISTRY-ACCESS.md).

### If the host cannot reach ghcr.io

Every release also ships as a self-contained archive on the
[Releases](https://github.com/yurdtech/tasksense-deployment/releases) page:
container images, manifests, scripts and documentation, with checksums and a
signature. Download it on a machine that has internet, verify it, carry it in,
and install offline:

```bash
./scripts/verify-signature.sh tasksense-onprem-1.0.0.tar.gz
tar xzf tasksense-onprem-1.0.0.tar.gz && cd tasksense-onprem-1.0.0
./scripts/install.sh --offline
```

If you run a registry mirror (Harbor, Nexus, Artifactory), push the images there
once and point `.env` at it:

```bash
./scripts/load-images.sh --registry harbor.bank.internal/tasksense
```

---

## What you need

|              | Minimum                  | Recommended (≈200 users)     |
| ------------ | ------------------------ | ---------------------------- |
| CPU          | 2 cores                  | 4 cores                      |
| Memory       | 4 GB                     | 8 GB                         |
| Disk         | 20 GB                    | 100 GB SSD                   |
| Container    | Docker 24+ / Podman 4+   | Kubernetes 1.27+ / OpenShift 4.12+ |
| Database     | MongoDB 7                | MongoDB 7 replica set        |

Sizing for larger installs: [`docs/11-SIZING.md`](docs/11-SIZING.md).

---

## Documentation

| Document | Read it if you are |
| --- | --- |
| [00-OVERVIEW](docs/00-OVERVIEW.md) | deciding whether and how to deploy |
| [01-INSTALL-COMPOSE](docs/01-INSTALL-COMPOSE.md) | installing on a VM |
| [04-CONFIGURATION](docs/04-CONFIGURATION.md) | looking up what a setting does |
| [05-IDENTITY](docs/05-IDENTITY.md) | wiring up Active Directory, LDAP or SSO |
| [06-SECURITY](docs/06-SECURITY.md) | **reviewing this for a security committee** |
| [07-BACKUP-DR](docs/07-BACKUP-DR.md) | responsible for backups and recovery |
| [08-UPGRADE](docs/08-UPGRADE.md) | planning a version upgrade |
| [10-TROUBLESHOOTING](docs/10-TROUBLESHOOTING.md) | debugging a broken install |
| [13-REGISTRY-ACCESS](docs/13-REGISTRY-ACCESS.md) | managing the registry token |

Still being written, and shipping with the Helm chart: Kubernetes and OpenShift
installation, monitoring recipes, sizing detail, and running the AI features on
an internal model. Ask your contact if you need one of them now.

---

## Operating it

```bash
./scripts/preflight.sh              # check a host before installing
./scripts/install.sh                # first install
./scripts/upgrade.sh 1.1.0          # backup, migrate, restart, verify
./scripts/rollback.sh               # undo the last upgrade
./scripts/backup.sh                 # database + uploads + config
./scripts/restore.sh <archive>      # restore from a backup
./scripts/collect-diagnostics.sh    # bundle logs for support (secrets masked)
```

`upgrade.sh` takes a backup before it touches anything and rolls itself back if
the new version fails its health check.

---

## Licensing and support

TaskSense is commercial software. A signed `LICENSE_KEY` enables the licensed
tier; it is **verified offline** — no activation server, no phone-home, no usage
reporting. An expired licence never blocks access to your data.

- Security issues: see [SECURITY.md](SECURITY.md)
- Everything else: your support contact, or `support@yurdtech.az`

Bug reports about *deployment* — a script, a manifest, a document — are welcome
as issues here. Application bugs go through your support channel.
