# Getting the software: registry access, mirrors and air-gap

Everything TaskSense ships that is not public lives in GitHub Container
Registry (`ghcr.io`) and is **private**:

| Package | What it is | Pulled with |
| --- | --- | --- |
| `ghcr.io/yurdtech/tasksense:<version>` | The application image (amd64 + arm64) | `docker pull`, or Kubernetes |
| `ghcr.io/yurdtech/charts/tasksense:<version>` | The Helm chart, as an OCI artifact | `helm install oci://…` |
| `ghcr.io/yurdtech/tasksense-offline:<version>` | The **offline bundle**: deployment files, the TaskSense and `mongo:7` images (linux/amd64), checksums, signature, SBOM and vulnerability report | `oras pull` |

One read-only token from us opens all three. What is public — on
<https://github.com/yurdtech/tasksense-deployment/releases> — is the deployment
repository itself: `tasksense-deployment-<version>.tar.gz` (the files, no
images), the chart `tasksense-<version>.tgz`, `SHA256SUMS`, `SHA256SUMS.sig`
and `cosign.pub`.

Which path is yours:

| Your server can… | Use |
| --- | --- |
| reach `ghcr.io` (directly or through a proxy) | [Pull directly](#pulling-directly) |
| reach only your own registry (Harbor, Nexus, Artifactory) | [Mirror into it](#mirroring-into-your-own-registry) |
| reach nothing at all | [The offline bundle](#no-route-out-air-gapped) |

---

## The token

**How you get it.** We issue one per customer: a read-only GitHub token — a
classic personal access token with only the `read:packages` scope, or a
fine-grained token / package grant limited to the three packages above. It
reaches you through the channel agreed in the contract, never by plain e-mail
together with the server address.

**What it can do.** Read those three packages. It cannot push, cannot read our
source, and cannot reach any other repository or package.

**The username is always `yurdtech`** — the account the token belongs to, not
yours. You do not need a GitHub account. (The registry authenticates the token
and does not check the username, so an old runbook with another name still
works; use `yurdtech`.)

**Expiry.** Tokens are issued with one. We contact you before it lapses. An
expired token stops new pulls and affects nothing that is already running.

**It is not your licence.** The token controls *downloading*; the licensed tier
is `LICENSE_KEY`, verified offline. They are independent, and neither reports
anything back to us.

---

## The guided installer asks for it

```bash
./tasksense
```

At the point the image is needed it asks for the token, hides it as you type,
signs in, and tells you where to ask if you do not have one yet. The rest of
this page is for the cases it does not cover.

---

## Pulling directly

### 1. Log in

```bash
echo '<TOKEN>' | docker login ghcr.io -u yurdtech --password-stdin
```

Expected:

```
Login Succeeded
```

Docker stores the credential in `~/.docker/config.json`. Signing in is per
host, not per pull; `install.sh` and `upgrade.sh` use it from there and never
write the token anywhere themselves.

### 2. Pull

```bash
docker pull ghcr.io/yurdtech/tasksense:1.1.0
```

Expected: ends with `Status: Downloaded newer image for ghcr.io/yurdtech/tasksense:1.1.0`.
`install.sh` does this for you; doing it by hand is a quick way to prove the
token and the network path work before the maintenance window.

### Verify what you pulled

Every image and every chart is signed with our cosign key. Get `cosign.pub`
from the public releases page, then:

```bash
cosign verify --key cosign.pub ghcr.io/yurdtech/tasksense:1.1.0
```

Expected: `Verification for ghcr.io/yurdtech/tasksense:1.1.0 -- The following checks were performed on each of these signatures: … The signatures were verified against the specified public key`,
followed by a JSON line naming the image digest.

cosign also looks the signature up in the public Sigstore transparency log. On
a machine that cannot reach it, add `--insecure-ignore-tlog=true`: the
signature is still checked against the key — only the public log lookup is
skipped. (`verify-signature.sh` does the same on its own when the log is out
of reach.)

> **Check the key itself out-of-band.** A signature only proves the image was
> signed by *whoever holds the key in `cosign.pub`*. Compare its fingerprint
> with the one we give you by another channel (on the phone, or in the
> delivery letter) once, before the first install:
>
> ```bash
> openssl pkey -pubin -in cosign.pub -outform DER | sha256sum
> ```
>
> That is the same fingerprint `scripts/verify-signature.sh` prints.

---

## Kubernetes and OpenShift

The cluster needs the same token, as an image pull secret, and Helm needs it to
fetch the chart.

### 1. Pull secret

```bash
kubectl create namespace tasksense
kubectl -n tasksense create secret docker-registry ghcr \
  --docker-server=ghcr.io \
  --docker-username=yurdtech \
  --docker-password='<TOKEN>'
```

Expected: `secret/ghcr created`. Reference it in your values:

```yaml
imagePullSecrets:
  - name: ghcr
```

Or let the chart create it from values (`imageCredentials.create: true` with
`registry`, `username`, `password`) — convenient, but the token is then part
of the Helm release, readable by anyone who can read the release. A secret you
create, or one from Vault / External Secrets, is the better choice for a bank.

### 2. The chart

```bash
echo '<TOKEN>' | helm registry login ghcr.io -u yurdtech --password-stdin
helm install tasksense oci://ghcr.io/yurdtech/charts/tasksense \
  --version 1.1.0 -n tasksense -f my-values.yaml
```

Expected: `Login Succeeded`, then `STATUS: deployed` and the chart's notes.
The chart version always equals the application version. Verify the chart
signature the same way as the image:

```bash
cosign verify --key cosign.pub ghcr.io/yurdtech/charts/tasksense:1.1.0
```

The whole Helm installation: [02-INSTALL-KUBERNETES](02-INSTALL-KUBERNETES.md),
[03-INSTALL-OPENSHIFT](03-INSTALL-OPENSHIFT.md).

---

## Through a corporate proxy

The Docker daemon does not read your shell's `HTTPS_PROXY`. Give it its own:

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/proxy.conf <<'EOF'
[Service]
Environment="HTTPS_PROXY=http://proxy.bank.internal:3128"
Environment="NO_PROXY=localhost,127.0.0.1,.bank.internal"
EOF
sudo systemctl daemon-reload && sudo systemctl restart docker
```

Hosts the proxy must allow, during installation and upgrades only:

| Host | For |
| --- | --- |
| `ghcr.io` | Registry API, authentication |
| `pkg-containers.githubusercontent.com` | Where the image layers are actually served |
| `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` | The bundled `mongo:7` image (Docker Hub) |

A running installation needs none of them.

---

## Mirroring into your own registry

If you run Harbor, Nexus or Artifactory, pull once at the boundary and serve
everything internally from there. Run this on a machine that can reach both
`ghcr.io` and your registry — it needs no `compose/.env`:

```bash
echo '<TOKEN>' | docker login ghcr.io -u yurdtech --password-stdin
docker login harbor.bank.internal

./scripts/load-images.sh --registry harbor.bank.internal/tasksense --version 1.1.0
```

Expected: one line per image copied —
`harbor.bank.internal/tasksense/tasksense:1.1.0` and
`harbor.bank.internal/tasksense/mongo:7` — then the settings to put in `.env`
(`--update-env` writes them for you). `--mongo-version` picks another MongoDB
tag.

It uses `skopeo` when it is installed, which keeps the multi-architecture
index; without it, it falls back to pull/tag/push, which keeps only the
architecture of the machine running it.

The MongoDB image is mirrored too, even if you use your own database: the
backup script runs `mongodump` in a throwaway container from that image.

**Compose** — in `compose/.env`, both lines:

```dotenv
TASKSENSE_IMAGE=harbor.bank.internal/tasksense/tasksense
MONGO_IMAGE=harbor.bank.internal/tasksense/mongo
```

**Helm** — point the chart at the mirror:

```yaml
global:
  imageRegistry: harbor.bank.internal
```

`global.imageRegistry` replaces the registry **host** and keeps the
repository path, so it expects the images at
`harbor.bank.internal/yurdtech/tasksense:<version>` and
`harbor.bank.internal/library/mongo:7` — the layout `helm-airgap-load.sh`
(below) produces. That is **not** the layout `load-images.sh --registry`
produces: for a cluster, mirror with `helm-airgap-load.sh`, or set the image
repositories explicitly in your values.

Repeat the mirror for every upgrade, before running `upgrade.sh` or
`helm upgrade`.

---

## No route out (air-gapped)

### Docker Compose: the offline bundle

The bundle is one signed archive: the deployment files, the TaskSense and
`mongo:7` images for linux/amd64, a `VERSION` file, and the proof that it is
ours. It holds the private images, so it is **not** on the public releases
page; it is published privately next to the image and pulled with the **same
token**, on any machine that has internet:

**1. Fetch it** (needs [ORAS](https://oras.land/docs/installation)):

```bash
echo '<TOKEN>' | oras login ghcr.io -u yurdtech --password-stdin
oras pull ghcr.io/yurdtech/tasksense-offline:1.1.0
```

Expected: `Downloaded` lines and four files in the current directory:
`tasksense-onprem-1.1.0.tar.gz`, `SHA256SUMS`, `SHA256SUMS.sig` and
`cosign.pub`. The bill of materials (`sbom.cdx.json`) and the vulnerability
scan (`trivy-report.json`) are inside the tarball, at its top level.

**2. Verify it — before carrying it in, not after:**

```bash
./scripts/verify-signature.sh tasksense-onprem-1.1.0.tar.gz
```

(Use the script from a clone of this repository, or from
`tasksense-deployment-1.1.0.tar.gz` on the public releases page.)

Expected:

```
==> Signature on SHA256SUMS
  key ./cosign.pub
  fingerprint (SHA-256 of the DER public key): 3b0c…
  compare it with the fingerprint YurdTech gave you out-of-band
  ✓ SHA256SUMS is signed by that key
==> Checksums
  ✓ tasksense-onprem-1.1.0.tar.gz matches SHA256SUMS

VERIFIED  tasksense-onprem-1.1.0.tar.gz : intact and signed by the release key
```

Compare the printed fingerprint with the one we gave you out-of-band. The
script **fails closed**: if `cosign` is not installed it stops with an error
rather than passing on the checksum alone. `--allow-unverified` overrides that,
loudly (`UNVERIFIED` instead of `VERIFIED`), for a lab — never for production.
`--key <file>` uses a public key you already hold instead of the `cosign.pub`
beside the archive, which is the stronger check. The same script verifies
`tasksense-deployment-<version>.tar.gz` and the chart `tasksense-<version>.tgz`
from the public releases page — one `SHA256SUMS` lists them all.

`sbom.cdx.json` (CycloneDX) and `trivy-report.json` are for your own
vulnerability management; scan the images again in your registry if your
policy requires it.

**3. Carry it in** by whatever your policy allows, then on the server:

```bash
tar xzf tasksense-onprem-1.1.0.tar.gz
cd tasksense-onprem-1.1.0
cp compose/.env.example compose/.env && chmod 600 compose/.env
${EDITOR:-vi} compose/.env              # docs/01-INSTALL-COMPOSE.md, step 4
./scripts/preflight.sh --offline
./scripts/install.sh --offline
```

Expected: `install.sh` loads both images from `images/` (`loading … done`),
then continues exactly as in [01-INSTALL-COMPOSE](01-INSTALL-COMPOSE.md#6-install).
No registry credentials are needed on that host — nothing there contacts a
registry. `TASKSENSE_VERSION` in the bundle's `.env.example` is already the
bundle's version.

> **The bundle carries `linux/amd64` images.** An image archive holds one
> architecture, and the bundle picks the one datacentre servers run.
> `install.sh --offline` checks the host first and refuses an arm64 host with
> a clear message rather than loading images that then fail to start. On
> arm64, mirror from the registry instead (it serves both).

### Kubernetes and OpenShift: the Helm air-gap bundle

On a machine with internet, logged in to `ghcr.io`:

```bash
./scripts/helm-airgap-bundle.sh            # → dist/tasksense-helm-airgap-1.1.0.tar.gz
```

It packs the chart, every image the chart can use — the application and the
`mongo` image the backup Jobs run — the OpenShift overlay, the loader and a
manifest with image digests, all checksummed. `--version`, `--platform`
(default `linux/amd64`) and `-o <dir>` change what and where; `--from-oci`
packs the published chart instead of the local one.

Expected: ends with the bundle path,
`dist/tasksense-helm-airgap-1.1.0.tar.gz`.

Inside your network, on a machine logged in to your registry:

```bash
mkdir bundle && tar xzf tasksense-helm-airgap-1.1.0.tar.gz -C bundle && cd bundle
./helm-airgap-load.sh harbor.bank.internal
```

Expected: the checksums verify (`OK`), each image is pushed
(`==> ghcr.io/yurdtech/tasksense:1.1.0 -> harbor.bank.internal/yurdtech/tasksense:1.1.0`),
and the script prints the `helm install` command with
`--set global.imageRegistry=harbor.bank.internal`.

---

## Rotating the token

Rotation is a new token from us, not something you generate:

1. Ask us (info@yurdtech.az) — routinely before expiry, **immediately** if the
   token may have been exposed. Each customer has their own, so revoking yours
   affects nobody else.
2. Re-run the login wherever the old one was used:
   ```bash
   echo '<NEW TOKEN>' | docker login ghcr.io -u yurdtech --password-stdin
   echo '<NEW TOKEN>' | helm registry login ghcr.io -u yurdtech --password-stdin
   kubectl -n tasksense create secret docker-registry ghcr \
     --docker-server=ghcr.io --docker-username=yurdtech \
     --docker-password='<NEW TOKEN>' --dry-run=client -o yaml | kubectl apply -f -
   ```
   …and in the CI secret or vault entry your mirror job reads.
3. Tell us when you have switched; we revoke the old one.

Nothing running is affected at any point — a token is only used to pull.

**Looking after it:** do not commit it; prefer a CI secret or a vault over a
shell profile; `install.sh` never writes it to disk itself.

---

## Troubleshooting

| Message | Cause | Fix |
| --- | --- | --- |
| `denied: denied` | Not logged in, or the token has expired | `docker login ghcr.io` again; ask us for a new token if it still fails |
| `unauthorized: authentication required` | Wrong token, expired, or pasted with a stray newline | Log in again from a fresh copy; use `--password-stdin` |
| `manifest unknown` | That version does not exist | Check the releases page; `TASKSENSE_VERSION` must be a published version |
| Times out, no error | The daemon has no proxy configured (see above) | It does not read your shell's `HTTPS_PROXY` |
| `no matching manifest for linux/...` | Unsupported architecture | We publish `amd64` and `arm64` |
| `ImagePullBackOff` on Kubernetes | Pull secret missing in that namespace, or `global.imageRegistry` pointing where the images are not | `kubectl -n tasksense describe pod <pod>` names the image it tried |
| `verify-signature.sh`: `cosign is not installed` | Fails closed by design | Install cosign; `--allow-unverified` only for a lab |
| `verify-signature.sh`: `signature verification failed` | The checksums were not signed by that key | **Do not install.** Contact us |

Still stuck: `./scripts/collect-diagnostics.sh` and send the archive to
info@yurdtech.az.
