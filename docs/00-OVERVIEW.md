# Overview

What TaskSense is, what running it on your own infrastructure involves, and what
to decide before you start.

---

## What it is

A task-intelligence platform: boards and sprints, a backlog, a documents
knowledge base, org structure, reporting, and optional AI agents. Think of the
scope as Jira plus Confluence, in one application, running entirely inside your
network.

## What it is made of

Two containers. That is the whole system.

```
        your users
             │  HTTPS
     ┌───────▼────────┐
     │ reverse proxy  │   nginx / Caddy / F5 — yours, terminates TLS
     └───────┬────────┘
             │  HTTP, loopback only
     ┌───────▼────────┐        ┌──────────────┐
     │ tasksense-app  │───────▶│   MongoDB    │
     │ API + web UI   │        │  (container  │
     │ one port       │        │   or your    │
     └───────┬────────┘        │   cluster)   │
             │                 └──────────────┘
             ▼
      files: a volume, or your MinIO / WebDAV / S3
```

The API serves the web interface itself, so there is one origin, one certificate
and no CORS to configure.

**Optional, and off unless you configure them:**

| | What it needs |
| --- | --- |
| Sign-in via Active Directory / LDAP | your directory |
| Sign-in via OIDC | Keycloak, AD FS, Azure AD, Okta |
| Email notifications | an internal SMTP relay |
| Shared file storage | MinIO, WebDAV, or any S3-compatible service |
| AI features | an OpenAI-compatible endpoint you host (vLLM, Ollama) |
| Metrics | Prometheus |

Every one points at a host you name. **Nothing contacts the vendor** — no
telemetry, no licence activation, no update check. See
[06-SECURITY](06-SECURITY.md) for how to verify that rather than believe it.

---

## Sizing

| Users | CPU | Memory | Disk | Notes |
| --- | --- | --- | --- | --- |
| Up to 50 | 2 cores | 4 GB | 20 GB | Single VM, everything on it |
| Up to 200 | 4 cores | 8 GB | 100 GB SSD | Single VM; separate MongoDB if you have one |
| Up to 1000 | 8 cores | 16 GB | 500 GB SSD | MongoDB replica set, shared object storage |
| More | — | — | — | Talk to us |

Disk is dominated by attachments. The database itself stays small: a workspace
with 100 000 tasks and three years of history is a few gigabytes.

Detail in [11-SIZING](11-SIZING.md).

---

## Choosing a platform

| | Choose it when | Guide |
| --- | --- | --- |
| **Docker Compose** on a VM | You want the simplest thing that works. Most installations. | [01](01-INSTALL-COMPOSE.md) |
| **Kubernetes** (Helm) | You have a cluster and a platform team already running things on it. | ships with the Helm chart |
| **OpenShift** | Same, on Red Hat. The image runs under `restricted-v2` unmodified. | ships with the Helm chart |

Compose is not the lesser option. A single well-backed-up VM is easier to
operate, easier to reason about and easier to restore than a cluster, and for a
few hundred users the difference in capacity is theoretical. Choose Kubernetes
because you already run Kubernetes, not to be safe.

## Choosing how to get the software

| | When | Guide |
| --- | --- | --- |
| Pull from `ghcr.io` | The host, or a proxy it uses, can reach the internet | [13](13-REGISTRY-ACCESS.md) |
| Mirror into your registry | You run Harbor, Nexus or Artifactory | [13](13-REGISTRY-ACCESS.md) |
| Offline archive | The host has no route out at all | [01](01-INSTALL-COMPOSE.md) |

The offline archive is a signed `.tar.gz` containing the images, the manifests,
the scripts and this documentation. Download it where you have internet, verify
the signature, carry it in.

---

## Licensing

A signed `LICENSE_KEY` enables the licensed tier. It is **verified offline** with
an Ed25519 signature: no activation server, no phone-home, no usage reporting.
The key encodes your organisation, a seat count and an optional expiry.

Without a key the instance runs on free-tier limits (seat cap, monthly
automation cap). **An expired licence never blocks access to your data** — the
instance keeps serving; the licensed features stop.

---

## What you decide before installing

1. **Hostname and certificate.** Users type `https://<this>`. Sign-in redirects
   are built from it, so changing it later means reconfiguring your identity
   provider.
2. **How people sign in.** Active Directory, OIDC, or local passwords. Keep at
   least one local administrator regardless, as an escape hatch.
3. **Where MongoDB lives.** The bundled container is fine and is what most
   installations use. Point at your own cluster if you already operate one.
4. **Where attachments live.** The container's volume by default; MinIO or
   WebDAV if you want them on shared or replicated storage.
5. **Where backups go.** A path on this host is not a backup. See
   [07-BACKUP-DR](07-BACKUP-DR.md).
6. **Whether you want the AI features.** They need a model endpoint inside your
   network and, realistically, a GPU. Everything else works without them.

---

## Roughly how long it takes

| | |
| --- | --- |
| Provision the VM, install Docker | 30 min |
| Configure `.env` and install | 30 min |
| Reverse proxy and certificate | 30 min |
| Connect the directory, test sign-in | 1 hour |
| Backups configured and a restore rehearsed | 1 hour |
| Security review | your timeline |

A working installation in an afternoon is realistic. Do not skip the restore
rehearsal — a backup you have never restored is a hypothesis.

---

## Where to go next

- Installing: [01-INSTALL-COMPOSE](01-INSTALL-COMPOSE.md)
- Every setting: [04-CONFIGURATION](04-CONFIGURATION.md)
- For the security review: [06-SECURITY](06-SECURITY.md)
- Backups and recovery: [07-BACKUP-DR](07-BACKUP-DR.md)
