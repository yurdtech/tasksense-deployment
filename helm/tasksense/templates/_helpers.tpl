{{/*
Shared naming and the environment block, so the Deployment and the migration
Job cannot drift apart — a Job that runs migrations with a different MONGODB_URI
than the pods is a very quiet kind of wrong.
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

{{- define "tasksense.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "tasksense.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "tasksense.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tasksense.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "tasksense.secretName" -}}
{{- default (printf "%s-config" (include "tasksense.fullname" .)) .Values.existingSecret -}}
{{- end -}}

{{- define "tasksense.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}

{{/*
Refuses to render on a configuration that would install something broken.
Failing here costs a second; failing after `helm install` costs a CrashLoopBackOff
and a look through pod logs to find out that a value was missing.
*/}}
{{- define "tasksense.validate" -}}
{{- if not .Values.existingSecret -}}
  {{- if not .Values.appUrl -}}
    {{- fail "appUrl is required — the URL users type, e.g. https://tasksense.bank.internal" -}}
  {{- end -}}
  {{- if not .Values.mongodbUri -}}
    {{- fail "mongodbUri is required — this chart does not bundle MongoDB, see docs/02-INSTALL-KUBERNETES.md" -}}
  {{- end -}}
  {{- if not .Values.storageSecret -}}
    {{- fail "storageSecret is required — generate one with: openssl rand -base64 32" -}}
  {{- end -}}
  {{- if lt (len .Values.storageSecret) 32 -}}
    {{- fail "storageSecret must be at least 32 characters" -}}
  {{- end -}}
{{- end -}}
{{- if and .Values.metrics.enabled (not .Values.metrics.token) (not .Values.existingSecret) -}}
  {{- fail "metrics.token is required when metrics.enabled — the endpoint reports seat usage and licence expiry" -}}
{{- end -}}
{{- $replicas := int .Values.replicaCount -}}
{{- if .Values.autoscaling.enabled -}}{{- $replicas = int .Values.autoscaling.minReplicas -}}{{- end -}}
{{- if and .Values.persistence.enabled (gt $replicas 1) (eq .Values.persistence.accessMode "ReadWriteOnce") -}}
  {{- fail "persistence.accessMode ReadWriteOnce cannot be shared by several replicas — use ReadWriteMany, or object storage with persistence.enabled=false" -}}
{{- end -}}
{{- end -}}

{{/*
The environment every TaskSense process gets. Shared by the Deployment and the
migration Job.
*/}}
{{- define "tasksense.env" -}}
- name: DEPLOYMENT_MODE
  value: onprem
- name: NODE_ENV
  value: production
- name: PORT
  value: "3000"
- name: LOG_FORMAT
  value: {{ .Values.logging.format | quote }}
- name: LOG_LEVEL
  value: {{ .Values.logging.level | quote }}
- name: STORAGE_MAX_FILE_MB
  value: {{ .Values.storageMaxFileMb | quote }}
- name: MIGRATE_ON_BOOT
  value: {{ .Values.migrations.onBoot | quote }}
{{- if .Values.persistence.enabled }}
- name: STORAGE_LOCAL_ROOT
  value: /app/api/data/uploads
- name: BACKUP_DIR
  value: /app/api/data/backups
{{- end }}
{{- if .Values.metrics.enabled }}
- name: METRICS_ENABLED
  value: "1"
{{- end }}
{{- range $key, $value := .Values.extraEnv }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}
{{- end -}}

{{- define "tasksense.envFrom" -}}
- secretRef:
    name: {{ include "tasksense.secretName" . }}
{{- with .Values.extraEnvFrom }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end -}}
