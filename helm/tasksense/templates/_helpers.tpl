{{/*
Shared naming, labels, images, security contexts and the environment — one
definition for the API, the worker and the hook Jobs, so they cannot drift
apart. A Job that migrates with a different MONGODB_URI than the pods use is a
very quiet kind of wrong.
*/}}

{{- define "tasksense.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "tasksense.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
<fullname>-<suffix>, with the base shortened so the whole name fits: Job names
become a pod label (63 characters at most) and a CronJob adds 11 characters to
its name for every Job (52 at most). Call with (dict "root" $ "suffix" "migrate" "max" 63).
*/}}
{{- define "tasksense.suffixedName" -}}
{{- $max := int (.max | default 63) -}}
{{- $base := include "tasksense.fullname" .root | trunc (int (sub $max (add1 (len .suffix)))) | trimSuffix "-" -}}
{{- printf "%s-%s" $base .suffix -}}
{{- end -}}

{{- define "tasksense.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* The version actually deployed (image.tag wins over appVersion). */}}
{{- define "tasksense.appVersion" -}}
{{- .Values.image.tag | default .Chart.AppVersion | toString -}}
{{- end -}}

{{/*
Metadata labels. Call with (dict "root" $ "component" "api").
*/}}
{{- define "tasksense.labels" -}}
helm.sh/chart: {{ include "tasksense.chart" .root }}
app.kubernetes.io/name: {{ include "tasksense.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/version: {{ include "tasksense.appVersion" .root | trunc 63 | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: tasksense
{{- with .component }}
app.kubernetes.io/component: {{ . }}
{{- end }}
{{- with .root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
The API Deployment's selector. It is immutable on a Deployment and chart 1.0
shipped exactly these two labels, so they stay as they are — changing them
would make `helm upgrade` from 1.0 fail with "field is immutable".
*/}}
{{- define "tasksense.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tasksense.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* API pod labels: the selector plus component/part-of. The Service selects on component=api too. */}}
{{- define "tasksense.apiPodLabels" -}}
{{ include "tasksense.selectorLabels" . }}
app.kubernetes.io/component: api
app.kubernetes.io/part-of: tasksense
{{- end -}}

{{/*
Every other pod (worker, migration, backups, helm test) gets a DIFFERENT
app.kubernetes.io/name, so it can never match the API's two-label selector:
otherwise the Service would send user traffic to a migration pod, and
`kubectl logs deploy/tasksense` could print the worker's log.
Call with (dict "root" $ "component" "worker").
*/}}
{{- define "tasksense.componentSelectorLabels" -}}
app.kubernetes.io/name: {{ printf "%s-%s" (include "tasksense.name" .root) .component | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{- define "tasksense.componentPodLabels" -}}
{{ include "tasksense.componentSelectorLabels" . }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/part-of: tasksense
{{- end -}}

{{/* ── Names ─────────────────────────────────────────────────────────────── */}}

{{- define "tasksense.configMapName" -}}
{{- printf "%s-env" (include "tasksense.fullname" .) -}}
{{- end -}}

{{- define "tasksense.secretName" -}}
{{- default (printf "%s-secrets" (include "tasksense.fullname" .)) .Values.existingSecret -}}
{{- end -}}

{{/*
Hook-time copies. Helm creates pre-install/pre-upgrade hooks BEFORE the
release's ordinary resources, so a hook Job that referenced the release's own
ConfigMap, Secret, certificate ConfigMap, pull secret or ServiceAccount would
wait forever for an object that does not exist yet (on a first install). The
hook Jobs therefore use short-lived copies (templates/hook-resources.yaml),
deleted once the hooks finish. Anything the operator supplies (existingSecret,
certs.existing*, a pre-created ServiceAccount) already exists and is used as is.
*/}}
{{- define "tasksense.hookName" -}}
{{- include "tasksense.suffixedName" (dict "root" . "suffix" "hook") -}}
{{- end -}}

{{- define "tasksense.hookSecretName" -}}
{{- if .Values.existingSecret -}}
{{- .Values.existingSecret -}}
{{- else -}}
{{- include "tasksense.suffixedName" (dict "root" . "suffix" "hook-secrets") -}}
{{- end -}}
{{- end -}}

{{- define "tasksense.hookConfigMapName" -}}
{{- include "tasksense.suffixedName" (dict "root" . "suffix" "hook-env") -}}
{{- end -}}

{{- define "tasksense.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "tasksense.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "tasksense.hookServiceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- include "tasksense.hookName" . -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* (dict "root" $ "hook" true) */}}
{{- define "tasksense.registrySecretName" -}}
{{- if .hook -}}
{{- include "tasksense.suffixedName" (dict "root" .root "suffix" "hook-registry") -}}
{{- else -}}
{{- include "tasksense.suffixedName" (dict "root" .root "suffix" "registry") -}}
{{- end -}}
{{- end -}}

{{- define "tasksense.dataClaimName" -}}
{{- .Values.persistence.existingClaim | default (printf "%s-data" (include "tasksense.fullname" .)) -}}
{{- end -}}

{{- define "tasksense.backupClaimName" -}}
{{- .Values.backup.persistence.existingClaim | default (printf "%s-backups" (include "tasksense.fullname" .)) -}}
{{- end -}}

{{/* ── Images ────────────────────────────────────────────────────────────── */}}

{{/*
Image reference with the air-gap registry override.
Call with (dict "root" $ "image" .Values.image "default" "<tag>").
With global.imageRegistry set, the source registry HOST is replaced and the
repository path kept (ghcr.io/yurdtech/tasksense -> <reg>/yurdtech/tasksense);
plain Docker Hub names gain library/ (mongo -> <reg>/library/mongo). This is the
rule scripts/helm-airgap-load.sh retags with — change both or neither.
*/}}
{{- define "tasksense.imageRef" -}}
{{- $reg := trimSuffix "/" (toString (.root.Values.global.imageRegistry | default "")) -}}
{{- $repo := .image.repository -}}
{{- if $reg -}}
{{- if contains "/" $repo -}}
{{- if regexMatch "^[^/]+[.:][^/]+/" $repo -}}
{{- $repo = printf "%s/%s" $reg (regexReplaceAll "^[^/]+/" $repo "") -}}
{{- else -}}
{{- $repo = printf "%s/%s" $reg $repo -}}
{{- end -}}
{{- else -}}
{{- $repo = printf "%s/library/%s" $reg $repo -}}
{{- end -}}
{{- end -}}
{{- if .image.digest -}}
{{- printf "%s@%s" $repo .image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (toString (.image.tag | default .default)) -}}
{{- end -}}
{{- end -}}

{{- define "tasksense.image" -}}
{{- include "tasksense.imageRef" (dict "root" . "image" .Values.image "default" .Chart.AppVersion) -}}
{{- end -}}

{{- define "tasksense.mongoImage" -}}
{{- include "tasksense.imageRef" (dict "root" . "image" .Values.backup.image "default" "7") -}}
{{- end -}}

{{/*
imagePullSecrets block. (dict "root" $ "hook" bool) — hook pods use the hook
copy of the chart-rendered registry secret.
*/}}
{{- define "tasksense.imagePullSecrets" -}}
{{- $names := list -}}
{{- range .root.Values.imagePullSecrets -}}
{{- if kindIs "string" . -}}
{{- $names = append $names . -}}
{{- else if and (kindIs "map" .) .name -}}
{{- $names = append $names .name -}}
{{- end -}}
{{- end -}}
{{- if .root.Values.imageCredentials.create -}}
{{- $names = append $names (include "tasksense.registrySecretName" (dict "root" .root "hook" .hook)) -}}
{{- end -}}
{{- if $names }}
imagePullSecrets:
{{- range uniq $names }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "tasksense.dockerconfigjson" -}}
{{- $c := .Values.imageCredentials -}}
{{- $auth := printf "%s:%s" $c.username $c.password | b64enc -}}
{{- dict "auths" (dict $c.registry (dict "username" $c.username "password" $c.password "auth" $auth)) | toJson -}}
{{- end -}}

{{/* ── Security posture ──────────────────────────────────────────────────── */}}

{{/*
OpenShift detection: the route.openshift.io API is present on the target
cluster (helm install/upgrade sees the real API groups; bare `helm template`
does not, unless --api-versions route.openshift.io/v1). openshift.enabled
forces it either way. Returns "true" or "".
*/}}
{{- define "tasksense.isOpenShift" -}}
{{- $forced := toString .Values.openshift.enabled -}}
{{- if eq $forced "true" -}}
true
{{- else if eq $forced "false" -}}
{{- else if .Capabilities.APIVersions.Has "route.openshift.io/v1" -}}
true
{{- end -}}
{{- end -}}

{{/*
Pod security context — two postures from one helper.
  OpenShift:  nothing pinned. restricted-v2 assigns a uid, gid 0 and an fsGroup
              from the namespace's range; a pod that names its own is rejected.
  Kubernetes: the kubelet cannot prove runAsNonRoot without a numeric uid, so
              the image's uid is pinned, with an fsGroup that makes the volume
              writable.
Call with (dict "root" $ "overrides" <map> "uid" 1001 "gid" nil "fsGroup" 1001).
*/}}
{{- define "tasksense.podSecurityContext" -}}
{{- $o := .overrides | default dict -}}
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
  fsGroupChangePolicy: OnRootMismatch
  {{- if not (include "tasksense.isOpenShift" .root) }}
  runAsUser: {{ hasKey $o "runAsUser" | ternary (get $o "runAsUser") .uid }}
  {{- $gid := hasKey $o "runAsGroup" | ternary (get $o "runAsGroup") .gid }}
  {{- if not (kindIs "invalid" $gid) }}
  runAsGroup: {{ $gid }}
  {{- end }}
  fsGroup: {{ hasKey $o "fsGroup" | ternary (get $o "fsGroup") .fsGroup }}
  {{- else if hasKey $o "fsGroup" }}
  fsGroup: {{ get $o "fsGroup" }}
  {{- end }}
{{- end -}}

{{- define "tasksense.appPodSecurityContext" -}}
{{- include "tasksense.podSecurityContext" (dict "root" . "overrides" .Values.podSecurityContext "uid" 1001 "gid" nil "fsGroup" 1001) -}}
{{- end -}}

{{- define "tasksense.mongoPodSecurityContext" -}}
{{- include "tasksense.podSecurityContext" (dict "root" . "overrides" .Values.backup.podSecurityContext "uid" 999 "gid" 999 "fsGroup" 999) -}}
{{- end -}}

{{- define "tasksense.containerSecurityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  privileged: false
  capabilities:
    drop:
      - ALL
{{- end -}}

{{/* ── Value coercion ────────────────────────────────────────────────────── */}}

{{/*
A value as an environment string. Helm reads every number in a values FILE as
float64 and would render 1000000 as "1e+06"; whole numbers are printed as
integers instead. YAML 1.1 also reads an unquoted on/off as a boolean, so
booleans pass through as "true"/"false" here and onOff below maps them back.
*/}}
{{- define "tasksense.str" -}}
{{- if kindIs "float64" . -}}
{{- if eq (floor .) . -}}{{- int64 . -}}{{- else -}}{{- . -}}{{- end -}}
{{- else if kindIs "invalid" . -}}
{{- else -}}
{{- toString . -}}
{{- end -}}
{{- end -}}

{{- define "tasksense.onOff" -}}
{{- if kindIs "bool" . -}}{{- ternary "on" "off" . -}}{{- else -}}{{- toString . | lower -}}{{- end -}}
{{- end -}}

{{/* A list, or a comma-separated string, as a CSV string. */}}
{{- define "tasksense.csv" -}}
{{- if kindIs "slice" . -}}
{{- join "," . -}}
{{- else -}}
{{- toString (. | default "") -}}
{{- end -}}
{{- end -}}

{{/* Kubernetes quantity (50Gi, 512Mi, 2G, 1073741824) -> bytes. */}}
{{- define "tasksense.toBytes" -}}
{{- $q := toString . -}}
{{- if hasSuffix "Ti" $q -}}{{- mulf (trimSuffix "Ti" $q | float64) 1099511627776 | int64 -}}
{{- else if hasSuffix "Gi" $q -}}{{- mulf (trimSuffix "Gi" $q | float64) 1073741824 | int64 -}}
{{- else if hasSuffix "Mi" $q -}}{{- mulf (trimSuffix "Mi" $q | float64) 1048576 | int64 -}}
{{- else if hasSuffix "Ki" $q -}}{{- mulf (trimSuffix "Ki" $q | float64) 1024 | int64 -}}
{{- else if hasSuffix "T" $q -}}{{- mulf (trimSuffix "T" $q | float64) 1000000000000 | int64 -}}
{{- else if hasSuffix "G" $q -}}{{- mulf (trimSuffix "G" $q | float64) 1000000000 | int64 -}}
{{- else if hasSuffix "M" $q -}}{{- mulf (trimSuffix "M" $q | float64) 1000000 | int64 -}}
{{- else if hasSuffix "k" $q -}}{{- mulf (trimSuffix "k" $q | float64) 1000 | int64 -}}
{{- else -}}{{- $q | float64 | int64 -}}
{{- end -}}
{{- end -}}

{{/* nginx size (21g, 25m, 512k, 0 = unlimited) -> bytes. */}}
{{- define "tasksense.nginxBytes" -}}
{{- $q := lower (toString .) -}}
{{- if hasSuffix "g" $q -}}{{- mulf (trimSuffix "g" $q | float64) 1073741824 | int64 -}}
{{- else if hasSuffix "m" $q -}}{{- mulf (trimSuffix "m" $q | float64) 1048576 | int64 -}}
{{- else if hasSuffix "k" $q -}}{{- mulf (trimSuffix "k" $q | float64) 1024 | int64 -}}
{{- else -}}{{- $q | float64 | int64 -}}
{{- end -}}
{{- end -}}

{{/* The origin (scheme://host[:port]) and the host of appUrl. */}}
{{- define "tasksense.appOrigin" -}}
{{- regexFind "^[a-zA-Z][a-zA-Z0-9+.-]*://[^/?#]+" (toString .Values.appUrl) -}}
{{- end -}}

{{- define "tasksense.appHost" -}}
{{- $o := include "tasksense.appOrigin" . -}}
{{- regexReplaceAll ":[0-9]+$" (regexReplaceAll "^[^:]+://" $o "") "" -}}
{{- end -}}

{{/* ── Environment ───────────────────────────────────────────────────────── */}}

{{/*
The non-secret configuration, as a map rendered into the ConfigMap and its
hook copy. Sorted by toYaml, so the checksum only moves when a value does.
*/}}
{{- define "tasksense.configData" -}}
{{- $c := .Values.config -}}
{{- $d := dict -}}
{{- $_ := set $d "DEPLOYMENT_MODE" "onprem" -}}
{{- $_ := set $d "NODE_ENV" "production" -}}
{{- $_ := set $d "PORT" "3000" -}}
{{- $_ := set $d "LOG_FORMAT" (toString .Values.logging.format) -}}
{{- $_ := set $d "LOG_LEVEL" (toString .Values.logging.level) -}}
{{- $_ := set $d "STORAGE_LOCAL_ROOT" "/app/api/data/uploads" -}}
{{- $_ := set $d "BACKUP_DIR" "/app/api/data/backups" -}}
{{- $_ := set $d "AGENT_WORKSPACE_ROOT" "/app/api/data/workspaces" -}}
{{- if .Values.appUrl -}}
{{- $_ := set $d "APP_URL" (trimSuffix "/" (toString .Values.appUrl)) -}}
{{- $origins := list (include "tasksense.appOrigin" .) -}}
{{- $extra := include "tasksense.csv" $c.corsAllowedOrigins -}}
{{- if $extra -}}{{- $origins = append $origins $extra -}}{{- end -}}
{{- $_ := set $d "CORS_ALLOWED_ORIGINS" (join "," $origins) -}}
{{- end -}}
{{- with .Values.firstAdminEmail -}}
{{- $_ := set $d "FIRST_ADMIN_EMAIL" (toString .) -}}
{{- end -}}
{{- $_ := set $d "MONGODB_DB" (include "tasksense.str" $c.mongodbDatabase) -}}
{{- $_ := set $d "MONGODB_TIMEOUT_MS" (include "tasksense.str" $c.mongodbTimeoutMs) -}}
{{- $_ := set $d "MONGODB_OP_TIMEOUT_MS" (include "tasksense.str" $c.mongodbOpTimeoutMs) -}}
{{- $_ := set $d "MONGODB_MIN_POOL_SIZE" (include "tasksense.str" $c.mongodbMinPoolSize) -}}
{{- $_ := set $d "MONGODB_MAX_POOL_SIZE" (include "tasksense.str" $c.mongodbMaxPoolSize) -}}
{{- $_ := set $d "MONGODB_COMPRESSORS" (include "tasksense.str" $c.mongodbCompressors) -}}
{{- $_ := set $d "SESSION_TTL_HOURS" (include "tasksense.str" $c.sessionTtlHours) -}}
{{- $_ := set $d "SWAGGER_ENABLED" (ternary "true" "false" (eq (toString $c.swaggerEnabled) "true")) -}}
{{- $_ := set $d "OWNER_EMAILS" (include "tasksense.csv" $c.ownerEmails) -}}
{{- $_ := set $d "AGENT_DISPATCHER" (include "tasksense.onOff" $c.agentDispatcher) -}}
{{- $_ := set $d "EGRESS_ALLOWLIST" (include "tasksense.csv" $c.egressAllowlist) -}}
{{- $_ := set $d "RATE_LIMIT_STORE" (include "tasksense.str" $c.rateLimitStore) -}}
{{- $_ := set $d "STORAGE_MAX_FILE_MB" (include "tasksense.str" $c.storageMaxFileMb) -}}
{{- $_ := set $d "STORAGE_MAX_VIDEO_FILE_MB" (include "tasksense.str" $c.storageMaxVideoFileMb) -}}
{{- $_ := set $d "JIRA_BACKUP_MAX_GB" (include "tasksense.str" $c.jiraBackupMaxGb) -}}
{{- $_ := set $d "JIRA_BACKUP_RETENTION_DAYS" (include "tasksense.str" $c.jiraBackupRetentionDays) -}}
{{- $_ := set $d "STATE_TASK_LIMIT" (include "tasksense.str" $c.stateTaskLimit) -}}
{{- $_ := set $d "REPORTS_MAX_TASKS" (include "tasksense.str" $c.reportsMaxTasks) -}}
{{- $_ := set $d "AUTOMATION_PROCESSING_MINUTES_PER_12H" (include "tasksense.str" $c.automationProcessingMinutesPer12h) -}}
{{- $_ := set $d "METRICS_ENABLED" (ternary "true" "false" (eq (toString .Values.metrics.enabled) "true")) -}}
{{- with $c.oidc -}}
{{- with .issuer }}{{ $_ := set $d "OIDC_ISSUER" (toString .) }}{{ end -}}
{{- with .clientId }}{{ $_ := set $d "OIDC_CLIENT_ID" (toString .) }}{{ end -}}
{{- with .redirectUri }}{{ $_ := set $d "OIDC_REDIRECT_URI" (toString .) }}{{ end -}}
{{- with .label }}{{ $_ := set $d "OIDC_LABEL" (toString .) }}{{ end -}}
{{- end -}}
{{- if and $c.smtp $c.smtp.host -}}
{{- $_ := set $d "SMTP_HOST" (toString $c.smtp.host) -}}
{{- $_ := set $d "SMTP_PORT" (include "tasksense.str" ($c.smtp.port | default 587)) -}}
{{- $_ := set $d "SMTP_SECURE" (ternary "true" "false" (eq (toString $c.smtp.secure) "true")) -}}
{{- with $c.smtp.user }}{{ $_ := set $d "SMTP_USER" (toString .) }}{{ end -}}
{{- end -}}
{{- with $c.emailFrom }}{{ $_ := set $d "EMAIL_FROM" (toString .) }}{{ end -}}
{{- range $k, $v := .Values.extraEnv -}}
{{- $_ := set $d $k (include "tasksense.str" $v) -}}
{{- end -}}
{{- toYaml $d -}}
{{- end -}}

{{/* The chart-managed secret values (only without existingSecret). */}}
{{- define "tasksense.secretData" -}}
{{- $c := .Values.config -}}
{{- $d := dict "MONGODB_URI" (toString .Values.mongodbUri) "STORAGE_SECRET" (toString .Values.storageSecret) -}}
{{- with .Values.licenseKey }}{{ $_ := set $d "LICENSE_KEY" (toString .) }}{{ end -}}
{{- if and .Values.metrics.enabled .Values.metrics.token }}{{ $_ := set $d "METRICS_TOKEN" (toString .Values.metrics.token) }}{{ end -}}
{{- if and $c.oidc $c.oidc.clientSecret }}{{ $_ := set $d "OIDC_CLIENT_SECRET" (toString $c.oidc.clientSecret) }}{{ end -}}
{{- if and $c.smtp $c.smtp.pass }}{{ $_ := set $d "SMTP_PASS" (toString $c.smtp.pass) }}{{ end -}}
{{- toYaml $d -}}
{{- end -}}

{{/*
Per-process environment. These are explicit `env` entries on purpose: an
explicit entry wins over every envFrom source, so neither a Secret nor an
extraEnvFrom can switch task execution on or change a process's role.
Call with (dict "root" $ "role" "api|worker|migrate" "heapMb" <n>).
*/}}
{{- define "tasksense.processEnv" -}}
{{- $root := .root -}}
- name: TMPDIR
  # Upload staging (Jira backups up to config.jiraBackupMaxGb, attachments,
  # archive restores). On the data volume: shared by the API and the worker,
  # and large — /tmp itself stays a small emptyDir.
  value: /app/api/data/tmp
- name: AGENT_EXECUTOR
  value: "off"
- name: MIGRATE_ON_BOOT
  value: {{ ternary "manual" "auto" (eq (toString $root.Values.migrations.enabled) "true") | quote }}
{{- if .heapMb }}
- name: NODE_OPTIONS
  value: {{ printf "--max-old-space-size=%d" (int .heapMb) | quote }}
{{- end }}
{{- if eq .role "api" }}
- name: WORKER_ROLE
  value: {{ ternary "api" "all" (eq (toString $root.Values.worker.enabled) "true") | quote }}
{{- else if eq .role "worker" }}
- name: WORKER_ROLE
  value: worker
{{- end }}
{{- with $root.Values.certs.caBundle }}
- name: NODE_EXTRA_CA_CERTS
  value: {{ printf "/certs/%s" . | quote }}
{{- end }}
{{- end -}}

{{/* envFrom: (dict "root" $ "hook" bool). Secret first, ConfigMap after it, extras last. */}}
{{- define "tasksense.envFrom" -}}
envFrom:
  - secretRef:
      name: {{ ternary (include "tasksense.hookSecretName" .root) (include "tasksense.secretName" .root) (eq (toString .hook) "true") }}
  - configMapRef:
      name: {{ ternary (include "tasksense.hookConfigMapName" .root) (include "tasksense.configMapName" .root) (eq (toString .hook) "true") }}
{{- with .root.Values.extraEnvFrom }}
{{ toYaml . | indent 2 }}
{{- end }}
{{- end -}}

{{/* Restarts the pods when configuration rendered by the chart changes. */}}
{{- define "tasksense.configChecksum" -}}
{{- $parts := list (include "tasksense.configData" .) (toYaml .Values.certs) -}}
{{- if not .Values.existingSecret -}}
{{- $parts = append $parts (include "tasksense.secretData" .) -}}
{{- end -}}
{{- join "\n---\n" $parts | sha256sum -}}
{{- end -}}

{{/* ── Volumes ───────────────────────────────────────────────────────────── */}}

{{- define "tasksense.hasCerts" -}}
{{- if or .Values.certs.existingConfigMap .Values.certs.existingSecret .Values.certs.files -}}true{{- end -}}
{{- end -}}

{{/* One projected /certs volume. (dict "root" $ "hook" bool) */}}
{{- define "tasksense.certsVolume" -}}
{{- $root := .root -}}
{{- if include "tasksense.hasCerts" $root }}
- name: certs
  projected:
    defaultMode: 0444
    sources:
      {{- if $root.Values.certs.files }}
      - configMap:
          name: {{ include "tasksense.suffixedName" (dict "root" $root "suffix" (ternary "hook-certs" "certs" (eq (toString .hook) "true"))) }}
      {{- end }}
      {{- with $root.Values.certs.existingConfigMap }}
      - configMap:
          name: {{ . }}
      {{- end }}
      {{- with $root.Values.certs.existingSecret }}
      - secret:
          name: {{ . }}
      {{- end }}
{{- end }}
{{- end -}}

{{- define "tasksense.certsMount" -}}
{{- if include "tasksense.hasCerts" . }}
- name: certs
  mountPath: /certs
  readOnly: true
{{- end }}
{{- end -}}

{{/*
Creates the staging directory on the data volume. A fresh claim is empty — the
directories baked into the image are shadowed by the mount — and code that asks
os.tmpdir() for a scratch file expects it to exist.
*/}}
{{- define "tasksense.prepareDataInitContainer" -}}
- name: prepare-data
  image: {{ include "tasksense.image" . }}
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command: ["sh", "-c", "mkdir -p /app/api/data/tmp /app/api/data/uploads /app/api/data/backups /app/api/data/workspaces"]
  {{- include "tasksense.containerSecurityContext" . | nindent 2 }}
  resources:
    requests:
      cpu: 10m
      memory: 16Mi
    limits:
      memory: 64Mi
  volumeMounts:
    - name: data
      mountPath: /app/api/data
{{- end -}}

{{/*
The data volume for the API and the worker: the claim, or an emptyDir when
persistence is off (trials only — files go with the pod).
*/}}
{{- define "tasksense.dataVolume" -}}
- name: data
{{- if .Values.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ include "tasksense.dataClaimName" . }}
{{- else }}
  emptyDir:
    sizeLimit: {{ .Values.persistence.size }}
{{- end }}
{{- end -}}

{{/*
The dump script shared by the nightly CronJob and the pre-upgrade Job.
The URI carries the database password, so it is handed to mongodump in a
config file on an in-memory volume — never on the command line, where `ps` on
the node would show it. A URI whose path names another database than
MONGODB_DB (often /admin, used as the auth database) is rewritten to an
explicit authSource, because mongodump refuses --db and a different URI
database together.
*/}}
{{- define "tasksense.dumpScript" -}}
set -euo pipefail
umask 077
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="${BACKUP_PREFIX}-${STAMP}"
OUT="/backups/${NAME}.archive.gz"
PART="${OUT}.partial"
trap 'rm -f "${PART}" /work/mongodump.yaml' EXIT

uri="${MONGODB_URI}"
scheme="${uri%%://*}"
rest="${uri#*://}"
hosts="${rest%%/*}"
path=""; query=""
if [ "${rest}" != "${hosts}" ]; then
  after="${rest#*/}"
  path="${after%%\?*}"
  case "${after}" in *\?*) query="${after#*\?}" ;; esac
fi
if [ -n "${path}" ] && [ "${path}" != "${MONGODB_DB}" ]; then
  case "&${query}&" in
    *"&authSource="*) ;;
    *) query="${query:+${query}&}authSource=${path}" ;;
  esac
  uri="${scheme}://${hosts}/${query:+?${query}}"
fi
q="'"
printf "uri: '%s'\n" "${uri//${q}/${q}${q}}" > /work/mongodump.yaml

echo "dumping database ${MONGODB_DB} -> ${OUT}"
mongodump --config=/work/mongodump.yaml --db="${MONGODB_DB}" --archive="${PART}" --gzip

# A dump that is implausibly small is worse than no dump: it looks like a
# backup until the day it is needed.
SIZE="$(wc -c < "${PART}" | tr -d ' ')"
if [ "${SIZE}" -lt 1024 ]; then
  echo "dump is only ${SIZE} bytes — refusing to keep it" >&2
  exit 1
fi
mv "${PART}" "${OUT}"
printf '{"file":"%s","kind":"%s","database":"%s","bytes":%s,"createdAt":"%s","release":"%s","revision":"%s","chartVersion":"%s","appVersion":"%s"}\n' \
  "${NAME}.archive.gz" "${BACKUP_KIND}" "${MONGODB_DB}" "${SIZE}" "${STAMP}" \
  "${RELEASE_NAME}" "${RELEASE_REVISION}" "${CHART_VERSION}" "${APP_VERSION}" > "/backups/${NAME}.json"
echo "wrote ${OUT} (${SIZE} bytes)"

# Retention: nightly and pre-upgrade dumps alike.
find /backups -maxdepth 1 -type f \( -name 'mongodump-*' -o -name 'pre-upgrade-*' \) \
  ! -name '*.partial' -mtime +"${RETENTION_DAYS}" -print -delete
{{- end -}}

{{/* Env for the dump containers. (dict "root" $ "hook" bool "kind" "nightly|pre-upgrade" "prefix" "...") */}}
{{- define "tasksense.dumpEnv" -}}
{{- $root := .root -}}
- name: MONGODB_URI
  valueFrom:
    secretKeyRef:
      name: {{ ternary (include "tasksense.hookSecretName" $root) (include "tasksense.secretName" $root) (eq (toString .hook) "true") }}
      key: MONGODB_URI
- name: MONGODB_DB
  value: {{ include "tasksense.str" $root.Values.config.mongodbDatabase | quote }}
- name: BACKUP_KIND
  value: {{ .kind | quote }}
- name: BACKUP_PREFIX
  value: {{ .prefix | quote }}
- name: RETENTION_DAYS
  value: {{ include "tasksense.str" $root.Values.backup.retentionDays | quote }}
- name: RELEASE_NAME
  value: {{ $root.Release.Name | quote }}
- name: RELEASE_REVISION
  value: {{ $root.Release.Revision | quote }}
- name: CHART_VERSION
  value: {{ $root.Chart.Version | quote }}
- name: APP_VERSION
  value: {{ include "tasksense.appVersion" $root | quote }}
{{- end -}}

{{/*
Whether the pre-upgrade dump runs. It needs the backups claim, which is an
ordinary release resource: it exists on an upgrade only if backup.enabled was
already on in the previous revision. On the upgrade that first turns backups
on, the claim does not exist yet when pre-upgrade hooks run, and a Job
mounting it would sit Pending until the upgrade timed out — so it is skipped
(NOTES says so). Offline rendering (helm template, no cluster) cannot look, so
it renders the Job for review.
*/}}
{{- define "tasksense.preUpgradeBackup" -}}
{{- if and .Values.backup.enabled .Values.migrations.enabled .Values.migrations.backupBeforeUpgrade -}}
{{- $claim := lookup "v1" "PersistentVolumeClaim" .Release.Namespace (include "tasksense.backupClaimName" .) -}}
{{- $api := lookup "apps/v1" "Deployment" .Release.Namespace (include "tasksense.fullname" .) -}}
{{- if or $claim (not $api) -}}true{{- end -}}
{{- end -}}
{{- end -}}
