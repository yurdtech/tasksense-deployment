# Installing on OpenShift

The same Helm chart as [Kubernetes](02-INSTALL-KUBERNETES.md), with
`values-openshift.yaml` on top. Read that guide first — everything in it applies.
This covers only what differs.

Requires OpenShift 4.10+.

---


## Installing

```bash
./tasksense          # → OpenShift
```

Asks the same questions as the Kubernetes path, offers a Route instead of an
Ingress, and adds `-f values-openshift.yaml` to the command it prints. It stops
at the values file unless you tell it to run the install.

By hand:

```bash
oc new-project tasksense

oc create secret docker-registry ghcr \
  --docker-server=ghcr.io \
  --docker-username=yurdtech \
  --docker-password="$TASKSENSE_REGISTRY_TOKEN"

helm install tasksense ./helm/tasksense \
  -f ./helm/tasksense/values-openshift.yaml \
  --set appUrl=https://tasksense.apps.cluster.bank.internal \
  --set mongodbUri='mongodb://user:pass@mongo:27017/?authSource=admin' \
  --set storageSecret="$(openssl rand -base64 32)" \
  --set firstAdminEmail=admin@bank.internal \
  --wait
```

---

## Security context constraints

**The image runs under `restricted-v2` unmodified.** No custom SCC, no elevated
ServiceAccount, nothing to request from a cluster administrator — which is
usually the longest part of getting software approved on OpenShift.

That works because of how the image is built, not how it is deployed: its files
are owned by **group 0** and are group-writable where the application writes, so
the arbitrary uid OpenShift assigns can use them.

`values-openshift.yaml` **clears** `runAsUser` and `fsGroup` rather than setting
them. Asking for uid 1001 is precisely what makes a chart fail admission on a
cluster that assigns its own — a chart that "supports OpenShift" but pins a uid
does not.

Confirm after installing:

```bash
oc get pod -l app.kubernetes.io/name=tasksense \
  -o jsonpath='{.items[0].metadata.annotations.openshift\.io/scc}{"\n"}'
```

It should print `restricted-v2`. Anything more permissive means something in
your values re-introduced a request the SCC had to accommodate.

---

## Routes instead of Ingress

`values-openshift.yaml` disables the Ingress and creates a Route with edge TLS,
redirecting plain HTTP.

The template sets `haproxy.router.openshift.io/timeout: 24h`. This is not
optional: live updates are server-sent events, and the router's default 30-second
timeout closes the stream repeatedly, which users see as an interface that keeps
reconnecting.

For your own certificate, set `route.tls.certificate` and `route.tls.key`, or
create the Route yourself and leave `route.enabled=false`.

```bash
oc get route tasksense
```

---

## Storage

`ReadWriteOnce` is the default and is right for one replica. For more, either use
a `ReadWriteMany` class — OpenShift Data Foundation provides one — or point
Admin → Storage at S3-compatible object storage and set
`persistence.enabled=false`.

---

## Internal registry

If your cluster mirrors images rather than pulling from the internet, push once
at the boundary:

```bash
./scripts/load-images.sh --registry image-registry.apps.cluster.bank.internal/tasksense

helm upgrade tasksense ./helm/tasksense --reuse-values \
  --set image.repository=image-registry.apps.cluster.bank.internal/tasksense/tasksense
```

Full detail in [13-REGISTRY-ACCESS](13-REGISTRY-ACCESS.md).

---

## Monitoring

OpenShift ships Prometheus. Enable user-workload monitoring, then the chart's
ServiceMonitor is picked up automatically:

```bash
oc -n openshift-monitoring get configmap cluster-monitoring-config -o yaml
# enableUserWorkload: true
```

```yaml
metrics:
  enabled: true
  token: "<openssl rand -hex 32>"
  serviceMonitor:
    enabled: true
```

See [09-MONITORING](09-MONITORING.md) for what to alert on.
