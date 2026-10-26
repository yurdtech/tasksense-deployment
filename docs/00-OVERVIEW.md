# Overview

What TaskSense is, what running it on your own infrastructure involves, and what
to decide before you start. Applies to **TaskSense 1.1.0** and later.

---

## What it is

A task-intelligence platform: boards and sprints, a backlog, epics and
releases, a documents knowledge base, a service desk, automation, reporting,
and optional AI agents. Think of the scope as Jira plus Confluence, in one
application, running entirely inside your network — with tooling to migrate
from Jira, including a full site-backup import.

## What it is made of

One image, a database, and your reverse proxy.

```
            your users
                 │ HTTPS
        ┌────────▼─────────┐
        │  reverse proxy   │  nginx / HAProxy / F5 / Ingress / Route — yours, terminates TLS
        └────────┬─────────┘
                 │ HTTP, loopback or cluster network
        ┌────────▼─────────┐          ┌───────────────────┐
        │  tasksense  API  │─────────▶│     MongoDB 7     │
        │  + web interface │          │ bundled container │
        │  one process     │          │ or your replica   │
        └───┬──────────┬───┘          │ set               │
            │          │              └────────▲──────────┘
   data volume      ┌──▼───────────────┐       │
   (attachments,    │ import worker    │───────┘
   upload staging)  │ optional, 0 or 1 │
                    └──────────────────┘
        migrate: a one-shot run of the same image before every start
```

| Part | What it does |
| --- | --- |
| **API** | Serves the web interface and the REST API from one port, so there is one origin, one certificate and no CORS to configure. A **single active process** by design — see [15-SCALING-AND-HA](15-SCALING-AND-HA.md). |
| **migrate** | Brings the database schema up to the installed version, then exits. The API starts only after it succeeded. |
| **Import worker** *(optional)* | The same image running only Jira backup landings, so a multi-gigabyte import never competes with users for memory. For the migration window. |
| **MongoDB 7** | The only data store. Bundled as a container on Docker Compose, or yours (required on Kubernetes). |
| **Data volume** | Attachments (unless you use object storage), upload staging, the application's own snapshots. |

**Optional, and off unless you configure them:**

| | What it needs |
| --- | --- |
| Sign-in via Active Directory / LDAP | your directory, over LDAPS |
| Sign-in via OIDC (and MFA) | Keycloak, AD FS, Entra ID, Okta |
| E-mail notifications | an internal SMTP relay |
| Shared file storage | MinIO, WebDAV, or any S3-compatible service |
| AI features | an OpenAI-compatible model gateway you host (vLLM, Ollama) |
| Metrics | Prometheus |

Every one points at a host you name. **Nothing contacts the vendor** — no
telemetry, no licence activation, no update check. See
[06-SECURITY](06-SECURITY.md) for how to verify that rather than believe it.

---

## Sizing

| Users | Host | Notes |
| --- | --- | --- |
| up to 50 | 2 vCPU · 4 GB · 40 GB | One VM, everything on it — the defaults |
| up to 200 | 4 vCPU · 8 GB · 100 GB SSD | One VM; or your MongoDB elsewhere |
| up to 1 000 | 8 vCPU · 16 GB · 250 GB SSD | Your MongoDB replica set; object storage for attachments |
| Jira migration | +2 vCPU · +6 GB · 2 × the backup's size free | For the import worker, during the window |
| more | — | Talk to us |

Growth is **vertical** — memory and CPU for one process, and a well-cached
database. Disk is dominated by attachments. Detail: [11-SIZING](11-SIZING.md).

---

## Choosing a platform

| | Choose it when | Guide |
| --- | --- | --- |
| **Docker Compose** on a VM | You want the simplest thing that works. Most installations. | [01](01-INSTALL-COMPOSE.md) |
| **Kubernetes** (Helm) | You have a cluster and a platform team already running things on it. | [02](02-INSTALL-KUBERNETES.md) |
| **OpenShift** | Same, on Red Hat. The image runs under `restricted-v2` unmodified. | [03](03-INSTALL-OPENSHIFT.md) |

Compose is not the lesser option. TaskSense is one process either way, so a
cluster adds no capacity — it adds automatic rescheduling and fits your existing
operations. A single well-backed-up VM is easier to operate, to reason about and
to restore. Choose Kubernetes because you already run Kubernetes.

## Choosing how to get the software

| | When | Guide |
| --- | --- | --- |
| Pull from `ghcr.io` | The host, or a proxy it uses, can reach it during installs and upgrades | [13](13-REGISTRY-ACCESS.md#pulling-directly) |
| Mirror into your registry | You run Harbor, Nexus or Artifactory | [13](13-REGISTRY-ACCESS.md#mirroring-into-your-own-registry) |
| Offline bundle | The host has no route out at all | [13](13-REGISTRY-ACCESS.md#no-route-out-air-gapped) |

All three use the same **read-only registry token** from us. The offline bundle
— deployment files, images, checksums, signature, SBOM and vulnerability
report — is pulled privately with that token (`oras pull`), verified where you
have internet, then carried in. A running installation never needs the
internet.

---

## Licensing

A signed `LICENSE_KEY` enables the licensed tier. It is **verified offline** with
an Ed25519 signature: no activation server, no phone-home, no usage reporting.
The key encodes your organisation, a seat count and an optional expiry.

Without a key the instance runs on free-tier limits: **10 accounts** and **500
automation runs a month**. Everything else is the same software.

**An expired licence never blocks access to your data**, and going over the seat
count never stops anybody signing in: on-premise the overage is reported, not
enforced. [14-LICENSING](14-LICENSING.md)

---

## How you install it

```bash
git clone https://github.com/yurdtech/tasksense-deployment.git
cd tasksense-deployment
./tasksense
```

`./tasksense` is a guided installer: it checks the host, asks for the registry
token, walks through the settings with each one explained, tests them against
your real directory, mail relay and database, and installs. It is also the
operations panel afterwards — status, upgrades, backups, diagnostics.

The same installation can be done by hand, from `compose/.env` and
`scripts/install.sh` — the right route for configuration management, a golden
image, or a change ticket that wants every command written down
([01-INSTALL-COMPOSE](01-INSTALL-COMPOSE.md)). Both write the same file and run
the same installer. On Kubernetes it is `helm install` from
`oci://ghcr.io/yurdtech/charts/tasksense`.

---

## What you decide before installing

The wizard asks about these, but it cannot decide them for you. The full
list, with what each team prepares, is
[18-PRE-INSTALL-CHECKLIST](18-PRE-INSTALL-CHECKLIST.md).

1. **Hostname and certificate.** Users type `https://<this>`. Sign-in redirects
   are built from it, so changing it later means reconfiguring your IdP.
2. **How people sign in.** Active Directory (LDAPS), OIDC (for MFA), or local
   passwords. Keep at least one local administrator regardless, as an escape
   hatch.
3. **Session lifetime.** 30 days unless you say otherwise; production installs set 12 hours.
4. **Where MongoDB lives.** The bundled container is fine for a pilot and small
   installations. A production install uses its own replica set.
5. **Where attachments live.** The data volume by default; MinIO, S3 or WebDAV
   for shared or replicated storage.
6. **Where backups go.** A path on this host is not a backup. See
   [07-BACKUP-DR](07-BACKUP-DR.md).
7. **Whether you migrate from Jira** — and so need the import worker and the
   disk for it.
8. **Whether you want the AI features.** They need a model gateway inside your
   network. Everything else works without them.

---

## Roughly how long it takes

| | |
| --- | --- |
| Pre-install checklist with your teams | 1–2 weeks of lead time, an hour of meetings |
| Provision the VM, install Docker | 30 min |
| Configure and install (`./tasksense`) | 15–30 min |
| Reverse proxy and certificate | 30 min |
| Connect the directory, test sign-in | 1 hour |
| Backups configured and a restore rehearsed | 1 hour |
| Security review | your timeline |

A working installation in an afternoon is realistic once the checklist is
done. Do not skip the restore rehearsal — a backup you have never restored is a
hypothesis.

---

## Where to go next

- Preparing your environment: [18-PRE-INSTALL-CHECKLIST](18-PRE-INSTALL-CHECKLIST.md)
- Installing: [01-INSTALL-COMPOSE](01-INSTALL-COMPOSE.md) — or just run `./tasksense`
- Every setting: [17-ENVIRONMENT](17-ENVIRONMENT.md)
- For the security review: [06-SECURITY](06-SECURITY.md)
- Backups and recovery: [07-BACKUP-DR](07-BACKUP-DR.md)
