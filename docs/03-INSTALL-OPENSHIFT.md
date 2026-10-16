# Installing on OpenShift

The same Helm chart as [Kubernetes](02-INSTALL-KUBERNETES.md), with
`values-openshift.yaml` layered **under** your own values file. Read that guide
first — the secrets, the values file, the import worker, backups, upgrade,
rollback and the values reference all apply unchanged. This page covers what
differs.

Requires OpenShift 4.12 or newer (Kubernetes 1.25) and Helm 3.14+. Nothing
cluster-scoped is installed: no SCC, no CRD, no ClusterRole — a namespace admin
can install it.

---

## Install

### Step 1 — Project and pull secret

```bash
oc new-project tasksense

oc create secret docker-registry ghcr -n tasksense \
  --docker-server=ghcr.io \
  --docker-username=yurdtech \
  --docker-password="$TASKSENSE_REGISTRY_TOKEN"

echo "$TASKSENSE_REGISTRY_TOKEN" | helm registry login ghcr.io -u yurdtech --password-stdin
```

Expected:

```
Now using project "tasksense" on server "https://api.ocp.bank.internal:6443".
secret/ghcr created
Login Succeeded
```

### Step 2 — The Secret

As in [Kubernetes, Step 2](02-INSTALL-KUBERNETES.md#step-2--the-secret):
`MONGODB_URI` and `STORAGE_SECRET` (plus `METRICS_TOKEN`, `LICENSE_KEY`,
`OIDC_CLIENT_SECRET`, `SMTP_PASS` as needed) in a Secret you manage.

```bash
oc create secret generic tasksense-secrets -n tasksense --from-env-file=tasksense-secrets.env
```

Expected: `secret/tasksense-secrets created`.

### Step 3 — The values file

The wizard asks and writes it, and prints the commands below with the overlay
already in the right place:

```bash
./tasksense          # → OpenShift
```

Or by hand — the minimal file:

```yaml
# my-values.yaml
appUrl: https://tasksense.apps.ocp.bank.internal
firstAdminEmail: admin@bank.internal
existingSecret: tasksense-secrets
```

`route.host` defaults to the host of `appUrl` (they must agree, or sign-in
redirects and CORS break), with edge TLS on the router's certificate. For a
Jira migration add the worker on CephFS:

```yaml
worker:
  enabled: true
persistence:
  accessMode: ReadWriteMany
  storageClass: ocs-storagecluster-cephfs     # OpenShift Data Foundation
  size: 200Gi
```

### Step 4 — Install

The overlay goes **before** your file — with several `-f`, the later file wins,
and yours must:

```bash
helm install tasksense oci://ghcr.io/yurdtech/charts/tasksense --version 1.1.0 \
  -n tasksense \
  -f helm/tasksense/values-openshift.yaml \
  -f my-values.yaml \
  --wait --timeout 30m
```

`helm/tasksense/values-openshift.yaml` comes from this repository at the same
release tag (the air-gap bundle carries it too). From the chart directory
instead of OCI: replace the chart reference with `./helm/tasksense` and drop
`--version`.

Expected: `STATUS: deployed` and NOTES beginning

```
TaskSense 1.1.0 — chart 1.1.0, release tasksense (revision 1) in tasksense.
  ...
  security     OpenShift posture (uid/fsGroup from the SCC); AGENT_EXECUTOR=off; sessions 12h; Swagger off
```

### Step 5 — Verify

```bash
oc -n tasksense get pods
oc -n tasksense logs job/tasksense-migrate
oc -n tasksense get route tasksense -o jsonpath='{.spec.host}{"\n"}'
helm test tasksense -n tasksense
```

Expected: the API pod `1/1 Running`, the migration Job `Completed` with
`✓ applied …` or `✓ nothing pending — schema is up to date`, the Route host you
set in `appUrl`, and `Phase: Succeeded`.

---

## Security context constraints

**The image runs under `restricted-v2` unmodified.** No custom SCC, no elevated
ServiceAccount, nothing to request from a cluster administrator — usually the
longest part of getting software approved on OpenShift.

It works because of how the image is built: its files are owned by **group 0**
and group-writable where the application writes, so the arbitrary uid OpenShift
assigns can use them. The chart pins **no** `runAsUser`, `runAsGroup` or
`fsGroup` on OpenShift — under `restricted-v2` a pod that asks for a specific
uid is rejected at admission. It still sets everything the SCC requires:
`runAsNonRoot`, `allowPrivilegeEscalation: false`, all capabilities dropped,
`seccompProfile: RuntimeDefault`, a read-only root filesystem, and no
ServiceAccount token.

The chart recognises OpenShift by the `route.openshift.io` API on the cluster
during `helm install` / `upgrade`. `values-openshift.yaml` also forces it
(`openshift.enabled: true`) — needed when the manifests are rendered without a
cluster (`helm template`, a GitOps renderer). The same applies to the backup
Jobs, which use the `mongo` image: on Kubernetes they pin its uid 999, on
OpenShift nothing.

Confirm after installing:

```bash
oc -n tasksense get pod -l app.kubernetes.io/name=tasksense \
  -o jsonpath='{.items[0].metadata.annotations.openshift\.io/scc}{"\n"}'
oc -n tasksense get pod -l app.kubernetes.io/name=tasksense \
  -o jsonpath='{.items[0].spec.securityContext}{"\n"}'
```

Expected: `restricted-v2`, and a security context with a uid and fsGroup from
the project's range (e.g. `"runAsUser":1000680000`) that the chart did not set.
Anything more permissive than `restricted-v2` means something in your values
re-introduced a request the SCC had to accommodate — usually a
`podSecurityContext.runAsUser`.

A cluster that enforces Pod Security Admission `restricted` on the namespace
admits the same pods.

---

## Routes

`values-openshift.yaml` disables the Ingress and creates one Route, edge TLS,
plain HTTP redirected. One Route carries all traffic, because the HAProxy router
has no request-body limit: the large uploads (Jira site backups up to 20 GB,
attachments) need no rule of their own, unlike nginx. What they and the
live-update streams need is a long timeout, so the chart sets
`haproxy.router.openshift.io/timeout: 24h`. With the router's default 30
seconds the event stream is closed repeatedly — users see an interface that
keeps reconnecting — and a large upload is cut off.

Your own certificate:

```yaml
route:
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
    certificate: |
      -----BEGIN CERTIFICATE-----
      ...
    key: |
      -----BEGIN PRIVATE KEY-----
      ...
    caCertificate: |
      -----BEGIN CERTIFICATE-----
      ...
```

`reencrypt` needs `destinationCACertificate` and TLS on the pod, which
TaskSense does not terminate — use `edge`. To manage the Route yourself, set
`route.enabled: false` and keep the 24h timeout annotation on yours.

---

## NetworkPolicy

With `networkPolicy.enabled: true` the chart detects OpenShift and allows:

- ingress from the router — by namespace (`openshift-ingress`) **and** by the
  policy-group labels, which also match a router on the host network (the
  default on bare-metal and vSphere installs, where traffic does not come from a
  pod in `openshift-ingress`);
- ingress from user-workload monitoring (`openshift-user-workload-monitoring`)
  when metrics are on;
- egress to `openshift-dns` on 53 and 5353, plus your `egressCIDRs`.

A policy naming the wrong namespaces blocks the router and all name resolution
the moment it is applied; override any of them with
`networkPolicy.ingressControllerNamespace`, `monitoringNamespace` and
`dns.namespace` / `dns.port` if your cluster differs. An in-cluster MongoDB in
another project goes in `networkPolicy.extraEgress`.

---

## Storage

`ReadWriteOnce` (e.g. `ocs-storagecluster-ceph-rbd`, `thin-csi`) is right for
the API alone. The import worker needs `ReadWriteMany` —
`ocs-storagecluster-cephfs` with OpenShift Data Foundation, or an NFS class. The
chart refuses `worker.enabled` on anything else. The backups volume
(`backup.persistence`) can stay ReadWriteOnce.

```bash
oc get storageclass
```

---

## Private CA

As on Kubernetes: `certs.files` (or `certs.existingConfigMap`) plus
`certs.caBundle`. If the bank CA is already distributed through the cluster-wide
trusted CA bundle, inject it into a ConfigMap and mount that:

```bash
oc -n tasksense create configmap bank-ca
oc -n tasksense label configmap bank-ca config.openshift.io/inject-trusted-cabundle=true
```

```yaml
certs:
  existingConfigMap: bank-ca
  caBundle: ca-bundle.crt          # the key OpenShift injects
```

Expected: `oc -n tasksense get cm bank-ca -o jsonpath='{.data}' | head -c 80`
shows `{"ca-bundle.crt":"-----BEGIN CERTIFICATE-----…`.

---

## Internal registry or mirror

Two ways, both without touching the chart:

1. **The offline bundle into Quay / Harbor / Nexus** —
   [Air-gapped install](02-INSTALL-KUBERNETES.md#air-gapped-install), then
   `--set global.imageRegistry=<registry>` and a pull secret for it.
2. **A cluster-wide mirror** (`ImageDigestMirrorSet` / `ImageTagMirrorSet`, or
   the older `ImageContentSourcePolicy`) that redirects `ghcr.io/yurdtech` and
   `docker.io/library/mongo` to your mirror: leave the chart's image names as
   they are, keep only a pull secret your mirror accepts. A digest mirror only
   applies to images pulled by digest — set `image.digest` and
   `backup.image.digest`, or use an `ImageTagMirrorSet`.

---

## Monitoring

OpenShift ships Prometheus. Enable user-workload monitoring, then the chart's
ServiceMonitor is scraped automatically:

```bash
oc -n openshift-monitoring get configmap cluster-monitoring-config -o yaml | grep enableUserWorkload
```

Expected: `enableUserWorkload: true`.

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
# METRICS_TOKEN in your existingSecret (or metrics.token without one)
```

See [09-MONITORING](09-MONITORING.md) for what to alert on.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `unable to validate against any security context constraint … runAsUser: Invalid value` | A uid was pinned | Remove `podSecurityContext.runAsUser`; keep `-f values-openshift.yaml` (or `openshift.enabled: true`) |
| Pods admitted under `anyuid` instead of `restricted-v2` | The ServiceAccount was granted `anyuid` | `oc adm policy remove-scc-from-user anyuid -z tasksense`; the chart needs no SCC |
| Route answers 503 | No ready endpoint | `oc get endpoints tasksense`; readiness needs MongoDB — `oc logs deploy/tasksense` |
| Live updates stall / "reconnecting" | Route timeout overridden, or another proxy in front | `oc get route tasksense -o yaml \| grep timeout` → `24h`; an F5/WAF in front needs buffering off and a long timeout too |
| Everything times out after enabling NetworkPolicy | DNS or router blocked | Check the detected namespaces in `oc get networkpolicy tasksense -o yaml`; set them explicitly |
| `ImagePullBackOff` from a mirror | Pull secret or path | `global.imageRegistry` must match the path `helm-airgap-load.sh` printed |
| Your `route.*` / `ingress.*` settings are ignored (e.g. the edge termination replaced your `reencrypt`) | `-f values-openshift.yaml` came after your file, so the overlay won | Overlay first: `-f values-openshift.yaml -f my-values.yaml` |
| `helm template` output pins uid 1001 | Rendered offline without the overlay — no cluster to detect | Add `-f values-openshift.yaml` (it sets `openshift.enabled: true`) or `--api-versions route.openshift.io/v1` |

Everything in [Kubernetes → Troubleshooting](02-INSTALL-KUBERNETES.md#troubleshooting)
applies too, with `oc` for `kubectl`.
