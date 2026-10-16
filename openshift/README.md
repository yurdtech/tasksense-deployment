# OpenShift

There are no separate OpenShift manifests: OpenShift uses the Helm chart in
[`../helm/tasksense`](../helm/tasksense) with its overlay
[`values-openshift.yaml`](../helm/tasksense/values-openshift.yaml) placed
**before** your own values file, so yours wins:

```bash
oc new-project tasksense
oc create secret docker-registry ghcr -n tasksense \
  --docker-server=ghcr.io --docker-username=yurdtech \
  --docker-password="$TASKSENSE_REGISTRY_TOKEN"
oc create secret generic tasksense-secrets -n tasksense \
  --from-env-file=tasksense-secrets.env          # MONGODB_URI, STORAGE_SECRET, …

helm install tasksense oci://ghcr.io/yurdtech/charts/tasksense --version 1.1.0 \
  -n tasksense \
  -f ../helm/tasksense/values-openshift.yaml \
  -f my-values.yaml \
  --wait --timeout 30m
```

- Runs under **`restricted-v2` unmodified** — no SCC, no ClusterRole, no uid
  pinned (the chart detects OpenShift; the overlay forces it for offline
  rendering).
- One **Route** on `appUrl`'s host, edge TLS, 24h router timeout for the
  live-update streams and the large Jira backup uploads.
- **NetworkPolicy** (opt-in) knows the router, `openshift-dns` and user-workload
  monitoring.
- The import worker needs **ReadWriteMany** storage (ODF CephFS, NFS).

The full guide — steps with expected output, SCC checks, Routes with your own
certificate, the cluster CA bundle, mirrors, monitoring, troubleshooting — is
[docs/03-INSTALL-OPENSHIFT.md](../docs/03-INSTALL-OPENSHIFT.md). The wizard
(`./tasksense` → OpenShift) writes the values file and prints these commands.
