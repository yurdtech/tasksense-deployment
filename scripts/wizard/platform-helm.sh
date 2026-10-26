#!/usr/bin/env bash
#
# The Kubernetes and OpenShift path: ask the questions, write a values file.
#
#   scripts/wizard/platform-helm.sh
#   scripts/wizard/platform-helm.sh --openshift
#
# It stops at the values file and shows you the exact commands, rather than
# running `helm install` itself.
#
# That is deliberate. A cluster is usually somebody else's to change: the
# namespace exists because a platform team made it, the pull secret came from a
# process, and the install may need to go through a pipeline rather than a
# terminal. A wizard that reached in and applied resources would be wrong about
# who is in charge. It offers to run it too, for the case where you are.
#
# Only what differs from the chart defaults goes into the file, so what you
# review is what is different about your cluster rather than a copy of
# values.yaml. The chart's defaults are already the recommended ones (12h sessions, no
# Swagger, no task execution); the questions below are the ones with no right
# default.

# shellcheck source=../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../ui.sh
. "${SCRIPT_DIR}/ui.sh"

OPENSHIFT=0
[ "${1:-}" = "--openshift" ] && OPENSHIFT=1

CHART_DIR="${ROOT_DIR}/helm/tasksense"
OCI_CHART="oci://ghcr.io/yurdtech/charts/tasksense"
CHART_VERSION="$(awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }' "${CHART_DIR}/Chart.yaml")"
OUT="${ROOT_DIR}/my-values.yaml"
STEPS=7

ui_require_tty

# A YAML single-quoted scalar: nothing typed here can break the file.
yq_str() {
  local q="'"
  printf "'%s'" "${1//${q}/${q}${q}}"
}

# pick <flag> <if 1> <otherwise>
pick() {
  if [ "$1" = "1" ]; then printf '%s' "$2"; else printf '%s' "$3"; fi
}

valid_mongo_uri() {
  case "$1" in
    mongodb://*|mongodb+srv://*) return 0 ;;
    *) printf 'must start with mongodb:// or mongodb+srv://'; return 1 ;;
  esac
}

valid_hours() {
  case "$1" in
    ''|*[!0-9]*) printf 'a whole number of hours (0 = never expires)'; return 1 ;;
    *) return 0 ;;
  esac
}

valid_name() {
  case "$1" in
    *[!a-z0-9.-]*|-*|*-) printf 'lowercase letters, digits, - and . only'; return 1 ;;
    *) return 0 ;;
  esac
}

valid_pem_file() {
  [ -f "$1" ] || { printf 'no such file: %s' "$1"; return 1; }
  grep -q -- '-----BEGIN CERTIFICATE-----' "$1" || { printf '%s holds no PEM certificate (-----BEGIN CERTIFICATE-----)' "$1"; return 1; }
  return 0
}

if [ "${OPENSHIFT}" = "1" ]; then
  ui_banner "OpenShift"
  ui_text "The same chart as Kubernetes, with values-openshift.yaml layered under your file: the restricted-v2 SCC assigns the uid (the chart pins none on OpenShift), and a Route replaces the Ingress."
else
  ui_banner "Kubernetes"
  ui_text "The Helm chart. Read docs/02-INSTALL-KUBERNETES.md alongside this — it covers what the chart does not ask about: storage classes, network policy, backups and restore."
fi
ui_hint "TaskSense runs as ONE active API process (plus an optional import worker). There is no replica count to choose: availability comes from Kubernetes restarting the pod and from your MongoDB replica set."

# ── 1. required ──────────────────────────────────────────────────────────────

ui_step 1 "${STEPS}" "Required"
ui_text "The chart refuses to render without these. There are no defaults that would be right."

ui_ask "Namespace" "tasksense" \
  "Where the release goes. Usually created by your platform team; the pull secret and any Secret you supply live in it too." valid_name
NAMESPACE="${UI_VALUE}"

printf '\n'
ui_ask "appUrl" "https://tasksense.corp.internal" \
  "The URL users type. Sign-in redirects and CORS are built from it, and its host becomes the Ingress / Route host — so changing it later means reconfiguring your identity provider too." ui_valid_url
APP_URL="${UI_VALUE%/}"
HOST="${APP_URL#https://}"; HOST="${HOST#http://}"; HOST="${HOST%%/*}"; HOST="${HOST%%:*}"

printf '\n'
ui_text "MongoDB is not bundled in the chart: in a cluster the database is your platform team's (an operator, a managed service), with its own backups. A replica set is what makes TaskSense survive a database node failure."
ui_ask "mongodbUri" "mongodb://tasksense:PASSWORD@mongo-0.db.corp.internal:27017,mongo-1.db.corp.internal:27017,mongo-2.db.corp.internal:27017/?replicaSet=rs0&authSource=admin&tls=true&tlsCAFile=/certs/corp-ca.pem" \
  "Replica set, TLS and the auth database go in the URI. A private CA is referenced as /certs/<file> (step 4 mounts it). Percent-encode / : @ ? # [ ] % in the password." valid_mongo_uri
MONGO_URI="${UI_VALUE}"

printf '\n'
ui_ask "Database name" "tasksense" "config.mongodbDatabase (MONGODB_DB). The backup jobs dump this database."
MONGO_DB="${UI_VALUE}"

printf '\n'
while true; do
  ui_secret "storageSecret" \
    "Encrypts stored provider credentials at rest (STORAGE_SECRET). Not recoverable — back it up with the database, or a restore returns credentials nobody can decrypt." 32
  problem="$(ui_valid_secret "${UI_VALUE}")" && break
  warn "${problem}"
done
STORAGE_SECRET="${UI_VALUE}"

printf '\n'
ui_ask "firstAdminEmail" "" \
  "Becomes the administrator of the new, empty workspace. No password is set: sign in through your IdP or directory, or register with this address." ui_valid_email
ADMIN_EMAIL="${UI_VALUE}"

# ── 2. secrets ───────────────────────────────────────────────────────────────

ui_step 2 "${STEPS}" "Where secrets live"
ui_text "A values file with a database URI and an encryption key in it is a file that ends up in Git. With Vault, sealed-secrets or an external-secrets operator, the chart reads them from a Secret you manage instead."

USE_EXISTING=""
SECRETS_FILE=""
if ui_yesno "Supply them from a Secret you manage (recommended)?" y; then
  ui_ask "existingSecret" "tasksense-secrets" \
    "Keys, by exact name: MONGODB_URI and STORAGE_SECRET (required); METRICS_TOKEN (with metrics); LICENSE_KEY, OIDC_CLIENT_SECRET, SMTP_PASS (optional). Nothing secret then goes into the values file." valid_name
  USE_EXISTING="${UI_VALUE}"
  # Outside the repository and mode 600: it holds the values the Secret is made
  # from, and nothing should commit it by accident.
  SECRETS_FILE="$(umask 077 && mktemp "${TMPDIR:-/tmp}/tasksense-secrets.XXXXXX")"
  {
    printf 'MONGODB_URI=%s\n' "${MONGO_URI}"
    printf 'STORAGE_SECRET=%s\n' "${STORAGE_SECRET}"
  } > "${SECRETS_FILE}"
  chmod 600 "${SECRETS_FILE}"
fi

# ── 3. sign-in and surface ───────────────────────────────────────────────────

ui_step 3 "${STEPS}" "Sessions and the API reference"

ui_ask "Session lifetime (hours)" "12" \
  "How long a sign-in lasts (SESSION_TTL_HOURS). A working day is the usual answer; 0 means sessions never expire. A workspace policy (Admin → Security) can still shorten it." valid_hours
SESSION_TTL="${UI_VALUE}"
[ "${SESSION_TTL}" = "0" ] && warn "sessions will never expire — a stolen session stays valid forever"

SWAGGER=false
if ui_yesno "Serve the interactive API reference (Swagger UI at /api/v1/swagger)?" n; then
  SWAGGER=true
fi

# ── 4. internal CA ───────────────────────────────────────────────────────────

ui_step 4 "${STEPS}" "Your certificate authority"
ui_text "If MongoDB, the mail relay, the identity provider or an internal model gateway present certificates your organisation issued, Node must trust that CA. The PEM is mounted at /certs/corp-ca.pem in every TaskSense pod and set as NODE_EXTRA_CA_CERTS. (The directory/LDAP CA is pasted in the application instead: Admin → Authentication.)"

CA_FILE=""
printf '\n  %sPath to the CA bundle (PEM) on this machine — empty for none%s\n  > ' "${C_BOLD}" "${C_OFF}"
IFS= read -r CA_FILE
CA_FILE="${CA_FILE#"${CA_FILE%%[![:space:]]*}"}"; CA_FILE="${CA_FILE%"${CA_FILE##*[![:space:]]}"}"
if [ -n "${CA_FILE}" ]; then
  while ! problem="$(valid_pem_file "${CA_FILE}")"; do
    warn "${problem}"
    printf '  > '
    IFS= read -r CA_FILE
    [ -n "${CA_FILE}" ] || break
  done
fi
case "${MONGO_URI}" in
  *tlsCAFile=/certs/*)
    [ -n "${CA_FILE}" ] || warn "mongodbUri names tlsCAFile=/certs/… but no CA file was given — the pods would not find it"
    ;;
esac

# ── 5. import worker ─────────────────────────────────────────────────────────

ui_step 5 "${STEPS}" "Jira migration"
ui_text "A Jira site backup (up to 20 GB) is uploaded to the API and landed into workspaces. The import worker does the landing in its own pod, so a multi-gigabyte migration cannot slow down or restart the API users are on. It shares the data volume with the API, so that volume must be ReadWriteMany (NFS, CephFS / ODF, Azure Files, EFS …)."

WORKER=0
STORAGE_CLASS=""
if ui_yesno "Will you migrate from Jira with a site backup (runs the import worker)?" y; then
  WORKER=1
  ui_ask "ReadWriteMany storage class" "$(pick "${OPENSHIFT}" ocs-storagecluster-cephfs nfs-client)" \
    "'kubectl get storageclass' lists them. Without RWX storage answer no above: the API then runs the landings itself."
  STORAGE_CLASS="${UI_VALUE}"
fi

# ── 6. traffic ───────────────────────────────────────────────────────────────

ui_step 6 "${STEPS}" "Getting traffic to it"

INGRESS=0
ROUTE=0
INGRESS_CLASS=""
TLS_SECRET=""
if [ "${OPENSHIFT}" = "1" ]; then
  ui_text "A Route for ${HOST}, edge TLS with the router's certificate (set route.tls for your own), 24h timeout for the live-update stream and long uploads."
  if ui_yesno "Create the Route?" y; then ROUTE=1; fi
else
  if ui_yesno "Create an Ingress for ${HOST}?" y; then
    INGRESS=1
    ui_ask "ingress.className" "nginx" \
      "The IngressClass your cluster uses ('kubectl get ingressclass'). The chart sets the ingress-nginx and F5 NGINX annotations itself: live-update streams unbuffered for 24h, uploads up to 21g on their own paths."
    INGRESS_CLASS="${UI_VALUE}"
    printf '\n'
    ui_ask "TLS secret name" "tasksense-tls" \
      "A kubernetes.io/tls Secret in ${NAMESPACE} for ${HOST}. Leave the default if cert-manager will create it."
    TLS_SECRET="${UI_VALUE}"
  fi
fi

# ── 7. storage, backups and images ───────────────────────────────────────────

ui_step 7 "${STEPS}" "Storage, backups and images"
ui_text "The data volume holds attachments, agent workspaces and the upload staging area — a Jira backup is staged there in full and kept 7 days. Size it for twice the largest backup plus your attachments."

ui_ask "persistence.size" "$(pick "${WORKER}" 200Gi 50Gi)" "The database itself is elsewhere."
PV_SIZE="${UI_VALUE}"
if [ "${WORKER}" = "0" ]; then
  printf '\n'
  printf '  %spersistence.storageClass%s\n' "${C_BOLD}" "${C_OFF}"
  ui_hint "Leave empty for the cluster default. 'kubectl get storageclass' lists them."
  printf '  > '
  IFS= read -r STORAGE_CLASS
fi

BACKUP=0
printf '\n'
if ui_yesno "Nightly database dump onto its own volume, plus a dump before every upgrade?" y; then
  BACKUP=1
fi
ui_hint "Migrations are forward-only: the pre-upgrade dump is what a rollback restores. Attachments on the data volume need your volume snapshots either way."

MIRROR=""
PULL_SECRET="ghcr"
PULL_SERVER="ghcr.io"
printf '\n'
ui_menu "Where do the cluster's nodes pull images from?" \
  "ghcr.io|directly or through a proxy, with your registry token" \
  "Internal registry|Harbor / Nexus / Quay mirror, or the offline bundle"
if [ "${UI_CHOICE}" = "2" ]; then
  ui_ask "Registry (host[/project])" "harbor.corp.internal" \
    "Becomes global.imageRegistry: ghcr.io/yurdtech/tasksense is pulled as <registry>/yurdtech/tasksense, mongo as <registry>/library/mongo — the layout scripts/helm-airgap-load.sh pushes."
  MIRROR="${UI_VALUE%/}"
  PULL_SERVER="${MIRROR%%/*}"
  ui_ask "Pull secret name" "tasksense-pull" "A docker-registry Secret in ${NAMESPACE} for ${PULL_SERVER}." valid_name
  PULL_SECRET="${UI_VALUE}"
fi

CHART_REF="${OCI_CHART}"
printf '\n'
ui_menu "Install the chart from" \
  "ghcr.io (OCI)|${OCI_CHART} --version ${CHART_VERSION}" \
  "This directory|${CHART_DIR} — air-gapped, no access to ghcr.io"
[ "${UI_CHOICE}" = "2" ] && CHART_REF="${CHART_DIR}"

# ── write it ─────────────────────────────────────────────────────────────────

{
  printf '# TaskSense — values for this cluster (chart %s).\n' "${CHART_VERSION}"
  printf '#\n'
  printf '# Written by ./tasksense. Only what differs from the chart defaults is\n'
  printf '# here; everything else is in helm/tasksense/values.yaml, which is worth\n'
  printf '# reading before an upgrade. Upgrade with -f this file, never --reuse-values.\n'
  printf '\n'
  printf 'appUrl: %s\n' "$(yq_str "${APP_URL}")"
  printf 'firstAdminEmail: %s\n' "$(yq_str "${ADMIN_EMAIL}")"
  if [ -n "${USE_EXISTING}" ]; then
    printf '\n# MONGODB_URI and STORAGE_SECRET come from this Secret.\n'
    printf 'existingSecret: %s\n' "$(yq_str "${USE_EXISTING}")"
  else
    printf 'mongodbUri: %s\n' "$(yq_str "${MONGO_URI}")"
    printf 'storageSecret: %s\n' "$(yq_str "${STORAGE_SECRET}")"
  fi
  printf '\n'

  if [ -n "${MIRROR}" ]; then
    printf 'global:\n'
    printf '  imageRegistry: %s\n\n' "$(yq_str "${MIRROR}")"
  fi
  if [ "${PULL_SECRET}" != "ghcr" ]; then
    printf 'imagePullSecrets:\n'
    printf '  - name: %s\n\n' "${PULL_SECRET}"
  fi

  printf 'config:\n'
  printf '  mongodbDatabase: %s\n' "$(yq_str "${MONGO_DB}")"
  printf '  sessionTtlHours: %s\n' "${SESSION_TTL}"
  printf '  swaggerEnabled: %s\n\n' "${SWAGGER}"

  if [ -n "${CA_FILE}" ]; then
    printf 'certs:\n'
    printf '  files:\n'
    printf '    corp-ca.pem: |\n'
    tr -d '\r' < "${CA_FILE}" | sed 's/^/      /'
    printf '  caBundle: corp-ca.pem\n\n'
  fi

  if [ "${WORKER}" = "1" ]; then
    printf 'worker:\n'
    printf '  enabled: true\n\n'
  fi

  printf 'persistence:\n'
  printf '  size: %s\n' "$(yq_str "${PV_SIZE}")"
  [ -n "${STORAGE_CLASS}" ] && printf '  storageClass: %s\n' "$(yq_str "${STORAGE_CLASS}")"
  [ "${WORKER}" = "1" ] && printf '  accessMode: ReadWriteMany\n'
  printf '\n'

  if [ "${BACKUP}" = "1" ]; then
    printf 'backup:\n'
    printf '  enabled: true\n\n'
  fi

  if [ "${INGRESS}" = "1" ]; then
    printf 'ingress:\n'
    printf '  enabled: true\n'
    printf '  className: %s\n' "$(yq_str "${INGRESS_CLASS}")"
    printf '  hosts:\n'
    printf '    - %s\n' "$(yq_str "${HOST}")"
    printf '  tls:\n'
    printf '    - secretName: %s\n' "$(yq_str "${TLS_SECRET}")"
    printf '      hosts: [%s]\n\n' "$(yq_str "${HOST}")"
  fi

  if [ "${OPENSHIFT}" = "1" ]; then
    printf 'route:\n'
    printf '  enabled: %s\n' "$(pick "${ROUTE}" true false)"
    [ "${ROUTE}" = "1" ] && printf '  host: %s\n' "$(yq_str "${HOST}")"
    printf '\n'
  fi
} > "${OUT}"
chmod 600 "${OUT}"

# ── what to do with it ───────────────────────────────────────────────────────

# The command as an array (run) and as text (shown). The OpenShift overlay goes
# BEFORE the values file: with -f, the later file wins, and yours must win.
HELM_CMD=(helm install tasksense "${CHART_REF}")
[ "${CHART_REF}" = "${OCI_CHART}" ] && HELM_CMD+=(--version "${CHART_VERSION}")
HELM_CMD+=(-n "${NAMESPACE}")
[ "${OPENSHIFT}" = "1" ] && HELM_CMD+=(-f "${CHART_DIR}/values-openshift.yaml")
HELM_CMD+=(-f "${OUT}" --wait --timeout 30m)
HELM_TEXT="${HELM_CMD[*]}"

KUBECTL="kubectl"
[ "${OPENSHIFT}" = "1" ] && KUBECTL="oc"
HAS_MIRROR=0; [ -n "${MIRROR}" ] && HAS_MIRROR=1
HAS_EXISTING=0; [ -n "${USE_EXISTING}" ] && HAS_EXISTING=1

cat <<EOF

  ${C_GREEN}✓${C_OFF} Written: ${C_BOLD}${OUT}${C_OFF}  ${C_DIM}(mode 600)${C_OFF}

  ${C_BOLD}1. Namespace and image pull secret${C_OFF}

    ${KUBECTL} create namespace ${NAMESPACE}        ${C_DIM}# skip if your platform team made it${C_OFF}
    ${KUBECTL} create secret docker-registry ${PULL_SECRET} -n ${NAMESPACE} \\
      --docker-server=${PULL_SERVER} \\
      --docker-username=$(pick "${HAS_MIRROR}" '<robot account>' "${REGISTRY_ACCOUNT}") --docker-password=<token>
EOF
if [ -z "${MIRROR}" ]; then
  cat <<EOF

    ${C_DIM}The token is read-only and issued per customer. No token yet? Ask
    ${SUPPORT_EMAIL} — docs/13-REGISTRY-ACCESS.md${C_OFF}
EOF
else
  cat <<EOF

    ${C_DIM}Images not in ${MIRROR} yet? Build the offline bundle where ghcr.io is
    reachable (scripts/helm-airgap-bundle.sh), then inside:
      ./helm-airgap-load.sh ${MIRROR}${C_OFF}
EOF
fi

if [ -n "${USE_EXISTING}" ]; then
  cat <<EOF

  ${C_BOLD}2. The Secret${C_OFF}  ${C_DIM}(MONGODB_URI and STORAGE_SECRET are in ${SECRETS_FILE}, mode 600)${C_OFF}

    ${KUBECTL} create secret generic ${USE_EXISTING} -n ${NAMESPACE} \\
      --from-env-file=${SECRETS_FILE}
    rm -f ${SECRETS_FILE}

    ${C_DIM}Add LICENSE_KEY, OIDC_CLIENT_SECRET, SMTP_PASS or METRICS_TOKEN lines to the
    file first if you use them. Or create it from Vault / your operator with the
    same key names. Keep STORAGE_SECRET with your database backups.${C_OFF}
EOF
fi

if [ "${CHART_REF}" = "${OCI_CHART}" ]; then
  cat <<EOF

  ${C_BOLD}$(pick "${HAS_EXISTING}" 3 2). Sign Helm in to the chart registry${C_OFF}

    echo "<token>" | helm registry login ghcr.io -u ${REGISTRY_ACCOUNT} --password-stdin
EOF
fi

cat <<EOF

  ${C_BOLD}Then install${C_OFF}

    ${HELM_TEXT}

EOF
if [ "${CHART_REF}" = "${OCI_CHART}" ]; then
  cat <<EOF
  ${C_DIM}Air-gapped instead: the same command with ${CHART_DIR} (or the .tgz from
  the offline bundle) in place of ${OCI_CHART}, and no --version.${C_OFF}
EOF
fi
cat <<EOF
  ${C_DIM}Expected: the NOTES ("TaskSense ${CHART_VERSION} — chart ${CHART_VERSION} …"), then check:
    ${KUBECTL} -n ${NAMESPACE} logs job/tasksense-migrate
    helm test tasksense -n ${NAMESPACE}${C_OFF}

EOF

if [ -z "${USE_EXISTING}" ]; then
  warn "${OUT} contains the storage key and the database URI"
  ui_hint "Do not commit it. If it must live in Git, move MONGODB_URI and STORAGE_SECRET into a Secret and re-run choosing existingSecret."
  printf '\n'
fi

ui_menu "Now?" \
  "Review it first|print the file, then decide" \
  "Run helm install|if this cluster is yours to change" \
  "I will run it myself|the commands are above"

case "${UI_CHOICE}" in
  1)
    printf '\n'
    sed 's/^/  /' "${OUT}"
    printf '\n'
    ui_yesno "Run the install now?" n || exit 0
    ;;
  3) exit 0 ;;
esac

# Choice 2, or 1 confirmed.
command -v helm >/dev/null 2>&1 || die "helm is not on this machine" \
  "Install Helm 3.14+, or copy ${OUT} to a machine that has it."
if [ -n "${USE_EXISTING}" ] && ! "${KUBECTL}" -n "${NAMESPACE}" get secret "${USE_EXISTING}" >/dev/null 2>&1; then
  die "the Secret ${USE_EXISTING} does not exist in ${NAMESPACE} yet" "Create it first (step 2 above), then run: ${HELM_TEXT}"
fi
printf '\n'
"${HELM_CMD[@]}"
