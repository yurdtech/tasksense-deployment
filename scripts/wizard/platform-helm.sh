#!/usr/bin/env bash
#
# The Kubernetes and OpenShift path: ask the questions, write a values file.
#
#   scripts/wizard/platform-helm.sh
#   scripts/wizard/platform-helm.sh --openshift
#
# It stops at the values file and shows you the command, rather than running
# `helm install` itself.
#
# That is deliberate. A cluster is usually somebody else's to change: the
# namespace exists because a platform team made it, the pull secret came from a
# process, and the install may need to go through a pipeline rather than a
# terminal. A wizard that reached in and applied resources would be wrong about
# who is in charge. It offers to run it too, for the case where you are.
#
# The four values the chart refuses to render without are asked for; everything
# else keeps the chart's default and is left out of the file, so what you review
# is what is different about your cluster rather than a copy of values.yaml.

# shellcheck source=../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../ui.sh
. "${SCRIPT_DIR}/ui.sh"

OPENSHIFT=0
[ "${1:-}" = "--openshift" ] && OPENSHIFT=1

CHART_DIR="${ROOT_DIR}/helm/tasksense"
OUT="${ROOT_DIR}/my-values.yaml"

ui_require_tty

if [ "${OPENSHIFT}" = "1" ]; then
  ui_banner "OpenShift"
  ui_text "The same chart as Kubernetes, with values-openshift.yaml layered on top: it clears the fixed uid so the restricted-v2 SCC can assign one, and swaps the Ingress for a Route."
else
  ui_banner "Kubernetes"
  ui_text "The Helm chart. Read docs/02-INSTALL-KUBERNETES.md alongside this — it covers what the chart does not ask about: pull secrets, storage classes, network policy."
fi

# ── the four required values ─────────────────────────────────────────────────

ui_step 1 4 "Required"
ui_text "The chart refuses to render without these four. There are no defaults that would be right."

ui_ask "appUrl" "https://tasksense.bank.internal" \
  "The URL users type. Sign-in redirects are built from it, so changing it later means reconfiguring your identity provider too." ui_valid_url
APP_URL="${UI_VALUE}"

printf '\n'
ui_text "MongoDB is not bundled in the chart. In a cluster the database is an operator's job, not a sidecar's — a StatefulSet we shipped would be worse than the one your platform team already runs, and it would be ours to page about."
ui_ask "mongodbUri" "mongodb://tasksense:PASSWORD@mongodb.tasksense.svc:27017/?authSource=admin" \
  "Put TLS and replica-set options in the URI: ?replicaSet=rs0&tls=true&authSource=admin"
MONGO_URI="${UI_VALUE}"

printf '\n'
ui_secret "storageSecret" \
  "Encrypts stored provider credentials at rest. Not recoverable — back it up with the database, or a restore returns credentials nobody can decrypt." 32
STORAGE_SECRET="${UI_VALUE}"

printf '\n'
ui_ask "firstAdminEmail" "" \
  "Becomes the administrator of the new, empty workspace. No password is set for it." ui_valid_email
ADMIN_EMAIL="${UI_VALUE}"

# ── secrets ──────────────────────────────────────────────────────────────────

ui_step 2 4 "Where secrets live"
ui_text "A values file with a database URI and an encryption key in it is a file that ends up in Git. If you run Vault, sealed-secrets or an external-secrets operator, the chart will read the four values from a Secret you manage instead."

USE_EXISTING=""
if ui_yesno "Supply them from an existing Secret?" n; then
  ui_ask "existingSecret" "tasksense-secrets" \
    "Its keys must be APP_URL, MONGODB_URI, STORAGE_SECRET and FIRST_ADMIN_EMAIL. What you typed above is then ignored — it is only used here to fill in the ingress host."
  USE_EXISTING="${UI_VALUE}"
fi

# ── networking ───────────────────────────────────────────────────────────────

ui_step 3 4 "Getting traffic to it"

HOST="${APP_URL#https://}"; HOST="${HOST#http://}"; HOST="${HOST%%/*}"

INGRESS=0
ROUTE=0
if [ "${OPENSHIFT}" = "1" ]; then
  if ui_yesno "Create a Route for ${HOST}?" y; then ROUTE=1; fi
else
  if ui_yesno "Create an Ingress for ${HOST}?" y; then
    INGRESS=1
    ui_ask "ingress.className" "nginx" \
      "The IngressClass your cluster uses. 'kubectl get ingressclass' lists them."
    INGRESS_CLASS="${UI_VALUE}"
    printf '\n'
    ui_ask "TLS secret name" "tasksense-tls" \
      "A kubernetes.io/tls Secret in the same namespace. Leave the default if cert-manager will create it."
    TLS_SECRET="${UI_VALUE}"
  fi
fi

# ── storage and scale ────────────────────────────────────────────────────────

ui_step 4 4 "Storage and scale"
ui_text "The volume holds uploaded files and agent workspaces. With more than one replica it must be ReadWriteMany — or turn it off and use object storage, configured from Admin → Storage once running."

ui_ask "persistence.size" "20Gi" "Disk is attachments; the database itself is elsewhere."
PV_SIZE="${UI_VALUE}"

ui_ask "persistence.storageClass" "" \
  "Leave empty for the cluster default. 'kubectl get storageclass' lists them."
STORAGE_CLASS="${UI_VALUE}"

printf '\n'
ui_ask "replicaCount" "1" \
  "More than one needs a ReadWriteMany volume and migrations.onBoot=manual, which the chart already defaults to."
REPLICAS="${UI_VALUE}"

# ── write it ─────────────────────────────────────────────────────────────────

{
  printf '# TaskSense — values for this cluster.\n'
  printf '#\n'
  printf '# Written by ./tasksense. Only what differs from the chart defaults is\n'
  printf '# here; everything else is in helm/tasksense/values.yaml, which is worth\n'
  printf '# reading before an upgrade.\n'
  printf '\n'
  if [ -n "${USE_EXISTING}" ]; then
    printf '# The four required values come from this Secret.\n'
    printf 'existingSecret: %s\n\n' "${USE_EXISTING}"
  else
    printf 'appUrl: %s\n' "${APP_URL}"
    printf 'mongodbUri: %s\n' "${MONGO_URI}"
    printf 'storageSecret: %s\n' "${STORAGE_SECRET}"
    printf 'firstAdminEmail: %s\n\n' "${ADMIN_EMAIL}"
  fi

  printf 'replicaCount: %s\n\n' "${REPLICAS}"

  printf 'persistence:\n'
  printf '  size: %s\n' "${PV_SIZE}"
  [ -n "${STORAGE_CLASS}" ] && printf '  storageClass: %s\n' "${STORAGE_CLASS}"
  [ "${REPLICAS}" -gt 1 ] 2>/dev/null && printf '  accessMode: ReadWriteMany\n'
  printf '\n'

  if [ "${INGRESS}" = "1" ]; then
    printf 'ingress:\n'
    printf '  enabled: true\n'
    printf '  className: %s\n' "${INGRESS_CLASS}"
    printf '  hosts:\n'
    printf '    - host: %s\n' "${HOST}"
    printf '      paths:\n'
    printf '        - path: /\n'
    printf '          pathType: Prefix\n'
    printf '  tls:\n'
    printf '    - secretName: %s\n' "${TLS_SECRET}"
    printf '      hosts: [%s]\n\n' "${HOST}"
  fi

  if [ "${ROUTE}" = "1" ]; then
    printf 'route:\n'
    printf '  enabled: true\n'
    printf '  host: %s\n\n' "${HOST}"
  fi
} > "${OUT}"
chmod 600 "${OUT}"

# ── what to do with it ───────────────────────────────────────────────────────

HELM_CMD="helm install tasksense ${CHART_DIR} -n tasksense --create-namespace -f ${OUT}"
[ "${OPENSHIFT}" = "1" ] && HELM_CMD="${HELM_CMD} -f ${CHART_DIR}/values-openshift.yaml"
HELM_CMD="${HELM_CMD} --wait --timeout 10m"

cat <<EOF

  ${C_GREEN}✓${C_OFF} Written: ${C_BOLD}${OUT}${C_OFF}  ${C_DIM}(mode 600)${C_OFF}

  ${C_BOLD}Before installing${C_OFF}

  The chart needs a pull secret for the private registry, in the namespace:

    kubectl create namespace tasksense
    kubectl create secret docker-registry ghcr -n tasksense \\
      --docker-server=ghcr.io \\
      --docker-username=${REGISTRY_ACCOUNT} --docker-password=<your token>

  ${C_DIM}No token yet? Ask at ${SUPPORT_EMAIL}, with the organisation the licence
  is for and who should receive it. docs/13-REGISTRY-ACCESS.md${C_OFF}

  ${C_BOLD}Then${C_OFF}

    ${HELM_CMD}

EOF

if [ -n "${STORAGE_SECRET}" ] && [ -z "${USE_EXISTING}" ]; then
  warn "${OUT} contains the storage key and the database URI"
  ui_hint "Do not commit it. If it must live in Git, move those four values into a Secret and re-run with existingSecret."
  printf '\n'
fi

ui_menu "Now?" \
  "Review it first|print the file, then decide" \
  "Run helm install|if this cluster is yours to change" \
  "I will run it myself|the command is above"

case "${UI_CHOICE}" in
  1)
    printf '\n'
    sed 's/^/  /' "${OUT}"
    printf '\n'
    ui_yesno "Run the install now?" n || exit 0
    ;&
  2)
    command -v helm >/dev/null 2>&1 || die "helm is not on this machine" \
      "Install Helm 3.12+, or copy ${OUT} to a machine that has it."
    printf '\n'
    # Unquoted on purpose: it is a command line assembled above, and the paths
    # in it are ours rather than user input.
    # shellcheck disable=SC2086
    ${HELM_CMD}
    ;;
  3) exit 0 ;;
esac
