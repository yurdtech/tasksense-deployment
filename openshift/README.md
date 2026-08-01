# OpenShift

The same Helm chart, with `values-openshift.yaml` on top:

```bash
oc new-project tasksense

oc create secret docker-registry ghcr \
  --docker-server=ghcr.io \
  --docker-username=<username> \
  --docker-password="$TASKSENSE_REGISTRY_TOKEN"

helm install tasksense ../helm/tasksense \
  -f ../helm/tasksense/values-openshift.yaml \
  --set appUrl=https://tasksense.apps.cluster.example.com \
  --set mongodbUri='mongodb://user:pass@mongo:27017/?authSource=admin' \
  --set storageSecret="$(openssl rand -base64 32)" \
  --set firstAdminEmail=admin@bank.internal
```

## Security context constraints

The image runs under **`restricted-v2` unmodified**. No custom SCC, no elevated
ServiceAccount, nothing to ask the cluster administrator for.

That works because of how the image is built rather than how it is deployed:
files are owned by **group 0** and are group-writable where the application
writes, so the arbitrary uid OpenShift assigns can use them. `runAsUser` is
deliberately **unset** in the OpenShift values — asking for uid 1001 is what
makes a chart fail admission on a cluster that assigns its own.

Confirm after installing:

```bash
oc get pod -l app.kubernetes.io/name=tasksense \
  -o jsonpath='{.items[0].spec.securityContext}{"\n"}'
oc get pod -l app.kubernetes.io/name=tasksense \
  -o jsonpath='{.items[0].metadata.annotations.openshift\.io/scc}{"\n"}'
```

The second should print `restricted-v2`. If it prints something more permissive,
something in your values re-introduced a request the SCC had to accommodate.

## Storage

`ReadWriteOnce` is the default and is right for one replica. For more than one,
either use a `ReadWriteMany` class (OpenShift Data Foundation provides one) or
point Admin → Storage at S3-compatible object storage and set
`persistence.enabled=false`. The chart refuses to render a configuration with
several replicas on a `ReadWriteOnce` volume, because the failure otherwise is a
pod that never schedules and a reason buried in an event.

## Routes

`values-openshift.yaml` enables a Route with edge TLS and redirects plain HTTP.
The router timeout is raised to 24h in the template: the live-update stream is
server-sent events, and the default 30s timeout closes it repeatedly, which the
interface shows as a reconnect loop.

To use your own certificate, set `route.tls.certificate` and `route.tls.key`, or
create the Route yourself and leave `route.enabled=false`.

## Registry

If your cluster mirrors images, push once at the boundary and point the chart at
your registry:

```bash
../scripts/load-images.sh --registry image-registry.apps.cluster.example.com/tasksense
helm upgrade tasksense ../helm/tasksense \
  --reuse-values \
  --set image.repository=image-registry.apps.cluster.example.com/tasksense/tasksense
```
