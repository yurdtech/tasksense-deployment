# Getting the container image

The image lives in GitHub Container Registry and is **private**. You will have
received a registry token from us; it grants read access to this one package and
nothing else.

---

## The guided installer asks for it

```bash
./tasksense
```

At the point the image is needed it asks for the username and token, hides the
token as you type it, signs in, and tells you where to ask if you do not have
one yet. Nothing else to read; the rest of this page is for the cases it does
not cover.

## Pulling directly

```bash
echo "$TASKSENSE_REGISTRY_TOKEN" | docker login ghcr.io -u yurdtech --password-stdin
docker pull ghcr.io/yurdtech/tasksense:1.0.0
```

The username is `yurdtech`. It is the account the token belongs to, not yours —
**you do not need a GitHub account to pull.** The registry authenticates the
token and does not check the username at all, so if a colleague's notes say
something else, either works.

The token is the whole credential. Guard it accordingly, and if it is ever
exposed tell us and we will revoke that one; it is issued per customer, so
revoking yours affects nobody else.

Signing in is per host, not per pull — Docker stores the credential in
`~/.docker/config.json`, and `install.sh` uses it from there.

### Verify what you pulled

```bash
cosign verify --key cosign.pub ghcr.io/yurdtech/tasksense:1.0.0
```

`cosign.pub` is attached to every release. The signature proves the image is the
one we built and that nothing has altered it since.

---

## Through a corporate proxy

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/proxy.conf <<'EOF'
[Service]
Environment="HTTPS_PROXY=http://proxy.bank.internal:3128"
Environment="NO_PROXY=localhost,127.0.0.1,.bank.internal"
EOF
sudo systemctl daemon-reload && sudo systemctl restart docker
```

Hosts to allow: `ghcr.io`, `pkg-containers.githubusercontent.com` (where the
layers are actually served), and `registry-1.docker.io` for the MongoDB image.

---

## Mirroring into your own registry

If you run Harbor, Nexus or Artifactory, pull once at the boundary and serve
internally from there. Run this where you can reach both:

```bash
docker login ghcr.io -u yurdtech -p "$TASKSENSE_REGISTRY_TOKEN"
docker login harbor.bank.internal

./scripts/load-images.sh --registry harbor.bank.internal/tasksense
```

It uses `skopeo` when available, which preserves the multi-architecture index —
`docker pull` and `docker push` would flatten it to whatever architecture the
machine running them happens to be.

Then in `compose/.env`:

```bash
TASKSENSE_IMAGE=harbor.bank.internal/tasksense/tasksense
MONGO_IMAGE=harbor.bank.internal/tasksense/mongo
```

Repeat for each upgrade, before running `upgrade.sh`.

---

## No route out at all

Every release also ships as a signed archive containing the images, the
manifests, the scripts and this documentation.

On a machine that has internet:

```bash
# From https://github.com/yurdtech/tasksense-deployment/releases
# Download: tasksense-onprem-1.0.0.tar.gz, SHA256SUMS, SHA256SUMS.sig, cosign.pub
./scripts/verify-signature.sh tasksense-onprem-1.0.0.tar.gz
```

Verify **before** carrying it in, not after. Then transfer it by whatever your
policy allows and:

```bash
tar xzf tasksense-onprem-1.0.0.tar.gz
cd tasksense-onprem-1.0.0
cp compose/.env.example compose/.env && ${EDITOR:-vi} compose/.env
./scripts/install.sh --offline
```

No registry credentials are needed on that host — nothing there ever contacts a
registry.

> **The archive carries `linux/amd64` images.** A `docker-archive` holds one
> image, not a manifest list, so the offline bundle has to pick an architecture,
> and it picks the one datacentre servers run. The registry serves both amd64
> and arm64 — if you run something else, pull from it or mirror into your own,
> as above. `install.sh --offline` checks the host architecture first and says
> so, rather than loading images that then refuse to start.

---

## About the token

**What it is.** A read-only credential for one package. It cannot push, cannot
read our source, and cannot reach any other repository or package.

**How to look after it.** Treat it as a password:

- Do not commit it. `install.sh` never writes it anywhere.
- Prefer a CI secret or a secrets manager over a shell profile.
- Tell us if it may have been exposed and we will issue a replacement — each
  customer has their own, so revoking one affects nobody else.

**Expiry.** Tokens are issued with one. We contact you before it lapses; an
expired token stops new pulls and affects nothing that is already running.

**It is not your licence.** The token controls *distribution*; the licensed tier
is enabled by `LICENSE_KEY`, which is verified offline. They are independent, and
neither one reports anything back to us.

---

## Troubleshooting

| Message | Cause |
| --- | --- |
| `denied: denied` | Not logged in, or the token has expired. Run `docker login ghcr.io` again. |
| `unauthorized: authentication required` | Wrong username. It is the account we gave you, not your own GitHub login. |
| `manifest unknown` | That version does not exist. Check the releases page. |
| Times out, no error | Proxy not configured for Docker — see above. Note that the daemon does not read your shell's `HTTPS_PROXY`. |
| `no matching manifest for linux/...` | Unsupported architecture. We publish `amd64` and `arm64`. |

Still stuck: `./scripts/collect-diagnostics.sh` and send the archive to your
support contact.
