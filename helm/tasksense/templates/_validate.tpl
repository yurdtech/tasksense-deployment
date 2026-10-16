{{/*
Refuses to render a configuration that would install something broken — the
preflight.sh of the Helm path. Failing here costs a second; failing after
`helm install` costs a CrashLoopBackOff and a look through pod logs to find out
that a value was missing.

Included at the top of every template, so whichever one Helm renders first
reports the real problem rather than a nil-pointer error further down.
*/}}
{{- define "tasksense.validate" -}}
{{- $v := .Values -}}

{{- /* ── values from chart 1.0, reused wholesale ─────────────────────────── */ -}}
{{- if not (and (hasKey $v "config") (hasKey $v "worker") (hasKey $v "certs") (hasKey $v "global")) -}}
{{- fail "these values come from chart 1.0 (no config / worker / certs / global block). That is what `helm upgrade --reuse-values` does across chart versions: it drops every default the new chart adds. Upgrade with your own file instead: `helm upgrade ... -f my-values.yaml` (or --reset-then-reuse-values on Helm >= 3.14). docs/02-INSTALL-KUBERNETES.md, \"Upgrade\"." -}}
{{- end -}}

{{- /* ── single active API ─────────────────────────────────────────────── */ -}}
{{- $as := index $v "autoscaling" | default (dict) -}}
{{- if and (kindIs "map" $as) (eq (toString (index $as "enabled")) "true") -}}
{{- fail "autoscaling.enabled=true is not supported (the HPA was removed in chart 1.1.0): the TaskSense API is a single active process — its schedulers and the live-update feed are in-process, without a distributed lock, so a second replica would run every scheduled job twice and split the live feed. Remove the autoscaling block; size the pod vertically (resources, heapMb) and move Jira imports to the worker (worker.enabled=true). docs/15-SCALING-AND-HA.md" -}}
{{- end -}}
{{- $pdb := index $v "podDisruptionBudget" | default (dict) -}}
{{- if and (kindIs "map" $pdb) (eq (toString (index $pdb "enabled")) "true") -}}
{{- fail "podDisruptionBudget.enabled=true is not supported for the API: with its single replica, minAvailable: 1 (or maxUnavailable: 0) blocks every node drain forever — `kubectl drain` hangs on this pod. Remove the podDisruptionBudget block; a drain is a short restart of the pod. docs/15-SCALING-AND-HA.md" -}}
{{- end -}}
{{- $replicas := int ($v.replicaCount | default 0) -}}
{{- if or (gt $replicas 1) (lt $replicas 0) -}}
{{- fail (printf "replicaCount=%v is not supported: the TaskSense API must run as exactly one active process (0 stops it). Its schedulers and the live-update (SSE) feed are in-process and have no distributed lock — a second replica runs every scheduled job twice and splits the live feed. Availability comes from Kubernetes restarting the pod and from a MongoDB replica set; heavy Jira imports go to the separate worker (worker.enabled=true). docs/15-SCALING-AND-HA.md" (toString $v.replicaCount)) -}}
{{- end -}}

{{- /* ── renamed in 1.1.0 ──────────────────────────────────────────────── */ -}}
{{- if hasKey $v.migrations "hook" -}}
{{- fail "migrations.hook was replaced in chart 1.1.0: use migrations.enabled (the pre-install/pre-upgrade Job, default true) and migrations.backoffLimit" -}}
{{- end -}}
{{- if hasKey $v.migrations "onBoot" -}}
{{- fail "migrations.onBoot was removed in chart 1.1.0: MIGRATE_ON_BOOT is manual while migrations.enabled=true (the Job migrates) and auto with migrations.enabled=false (the API migrates at boot)" -}}
{{- end -}}
{{- if hasKey $v "storageMaxFileMb" -}}
{{- fail "storageMaxFileMb moved to config.storageMaxFileMb in chart 1.1.0" -}}
{{- end -}}
{{- if kindIs "string" $v.backup.image -}}
{{- fail (printf "backup.image is a map since chart 1.1.0 so it can follow global.imageRegistry: backup.image.repository / backup.image.tag (you have %q)" $v.backup.image) -}}
{{- end -}}

{{- /* ── task execution stays off ──────────────────────────────────────── */ -}}
{{- if hasKey $v.config "agentExecutor" -}}
{{- $ae := include "tasksense.onOff" $v.config.agentExecutor -}}
{{- if ne $ae "off" -}}
{{- fail (printf "config.agentExecutor=%s is not allowed: this chart always renders AGENT_EXECUTOR=off. There is no sandbox runtime yet, and the unsafe-host mode runs agent tools as the API's own OS user inside your network. Remove the key." $ae) -}}
{{- end -}}
{{- end -}}

{{- /* ── extraEnv must not shadow what the chart owns ──────────────────── */ -}}
{{- $owned := dict
      "AGENT_EXECUTOR" "always off, not configurable"
      "WORKER_ROLE" "set from worker.enabled"
      "MIGRATE_ON_BOOT" "set from migrations.enabled"
      "TMPDIR" "fixed to /app/api/data/tmp"
      "NODE_OPTIONS" "use heapMb / worker.heapMb / migrations.heapMb"
      "NODE_EXTRA_CA_CERTS" "use certs.caBundle"
      "MONGODB_URI" "a secret: mongodbUri or existingSecret"
      "STORAGE_SECRET" "a secret: storageSecret or existingSecret"
      "LICENSE_KEY" "a secret: licenseKey or existingSecret"
      "METRICS_TOKEN" "a secret: metrics.token or existingSecret"
      "OIDC_CLIENT_SECRET" "a secret: config.oidc.clientSecret or existingSecret"
      "SMTP_PASS" "a secret: config.smtp.pass or existingSecret"
      "DEPLOYMENT_MODE" "fixed to onprem"
      "NODE_ENV" "fixed to production"
      "PORT" "fixed to 3000"
      "APP_URL" "use appUrl"
      "STORAGE_LOCAL_ROOT" "fixed to the data volume"
      "BACKUP_DIR" "fixed to the data volume" -}}
{{- range $k, $_ := $v.extraEnv -}}
{{- if hasKey $owned $k -}}
{{- fail (printf "extraEnv.%s cannot be set: the chart manages it (%s)" $k (get $owned $k)) -}}
{{- end -}}
{{- end -}}

{{- /* ── required values ───────────────────────────────────────────────── */ -}}
{{- if not $v.existingSecret -}}
{{- if not $v.appUrl -}}
{{- fail "appUrl is required — the URL users type, e.g. https://tasksense.bank.internal" -}}
{{- end -}}
{{- if not $v.mongodbUri -}}
{{- fail "mongodbUri is required — this chart does not bundle MongoDB (docs/16-EXTERNAL-DATABASES.md). Or supply MONGODB_URI through existingSecret." -}}
{{- end -}}
{{- if not $v.storageSecret -}}
{{- fail "storageSecret is required — generate one with: openssl rand -base64 32 (or supply STORAGE_SECRET through existingSecret)" -}}
{{- end -}}
{{- if lt (len (toString $v.storageSecret)) 32 -}}
{{- fail (printf "storageSecret must be at least 32 characters (it is %d) — generate one with: openssl rand -base64 32" (len (toString $v.storageSecret))) -}}
{{- end -}}
{{- if not (regexMatch "^mongodb(\\+srv)?://" (toString $v.mongodbUri)) -}}
{{- fail "mongodbUri must start with mongodb:// or mongodb+srv://" -}}
{{- end -}}
{{- if and $v.metrics.enabled (not $v.metrics.token) -}}
{{- fail "metrics.token is required when metrics.enabled — the endpoint reports seat usage and licence expiry (openssl rand -hex 32), or put METRICS_TOKEN in existingSecret" -}}
{{- end -}}
{{- end -}}
{{- if $v.appUrl -}}
{{- if not (regexMatch "^https?://[^/?#]+" (toString $v.appUrl)) -}}
{{- fail (printf "appUrl must be an absolute http(s) URL, e.g. https://tasksense.bank.internal (got %q)" (toString $v.appUrl)) -}}
{{- end -}}
{{- end -}}

{{- /* ── worker ────────────────────────────────────────────────────────── */ -}}
{{- if $v.worker.enabled -}}
{{- if not $v.persistence.enabled -}}
{{- fail "worker.enabled=true requires persistence.enabled=true: the worker lands uploads staged by the API on the shared data volume (TMPDIR=/app/api/data/tmp)" -}}
{{- end -}}
{{- if ne (toString $v.persistence.accessMode) "ReadWriteMany" -}}
{{- fail (printf "worker.enabled=true needs persistence.accessMode=ReadWriteMany (it is %s): the API stages Jira backup and archive uploads on the data volume (TMPDIR=/app/api/data/tmp) and the worker lands them from the same files, so both pods mount one claim — usually on different nodes. Use a ReadWriteMany storage class (NFS, CephFS / ODF, Azure Files, EFS …); with persistence.existingClaim, declare the claim's mode here. Without RWX storage leave the worker off: the API (WORKER_ROLE=all) runs the landings itself." (toString $v.persistence.accessMode)) -}}
{{- end -}}
{{- end -}}

{{- /* ── enumerations the application would reject at boot ─────────────── */ -}}
{{- if not (has (toString $v.persistence.accessMode) (list "ReadWriteOnce" "ReadWriteMany" "ReadWriteOncePod")) -}}
{{- fail (printf "persistence.accessMode must be ReadWriteOnce, ReadWriteMany or ReadWriteOncePod (got %s)" (toString $v.persistence.accessMode)) -}}
{{- end -}}
{{- if not (has (toString $v.config.mongodbCompressors) (list "zlib" "none")) -}}
{{- fail (printf "config.mongodbCompressors must be zlib or none (got %s)" (toString $v.config.mongodbCompressors)) -}}
{{- end -}}
{{- if not (has (toString $v.config.rateLimitStore) (list "memory" "mongo")) -}}
{{- fail (printf "config.rateLimitStore must be memory or mongo (got %s)" (toString $v.config.rateLimitStore)) -}}
{{- end -}}
{{- if not (has (include "tasksense.onOff" $v.config.agentDispatcher) (list "on" "off")) -}}
{{- fail (printf "config.agentDispatcher must be \"on\" or \"off\" (got %s)" (toString $v.config.agentDispatcher)) -}}
{{- end -}}
{{- if not (has (toString $v.logging.format) (list "json" "text")) -}}
{{- fail (printf "logging.format must be json or text (got %s)" (toString $v.logging.format)) -}}
{{- end -}}
{{- if not (has (toString $v.logging.level) (list "verbose" "debug" "log" "warn" "error" "fatal")) -}}
{{- fail (printf "logging.level must be one of verbose, debug, log, warn, error, fatal (got %s)" (toString $v.logging.level)) -}}
{{- end -}}
{{- if lt (int64 (include "tasksense.str" $v.config.sessionTtlHours | default "0")) 0 -}}
{{- fail "config.sessionTtlHours must be 0 or more (0 = sessions never expire)" -}}
{{- end -}}
{{- if or (lt (int64 (include "tasksense.str" $v.config.automationProcessingMinutesPer12h | default "0")) 0) (gt (int64 (include "tasksense.str" $v.config.automationProcessingMinutesPer12h | default "0")) 720) -}}
{{- fail "config.automationProcessingMinutesPer12h must be between 0 and 720" -}}
{{- end -}}
{{- if and $v.config.oidc $v.config.oidc.issuer (not $v.config.oidc.clientId) -}}
{{- fail "config.oidc.clientId is required with config.oidc.issuer" -}}
{{- end -}}

{{- /* ── heap must fit inside the memory limit ─────────────────────────── */ -}}
{{- range $w := list (dict "name" "heapMb" "heap" $v.heapMb "res" $v.resources "limitName" "resources.limits.memory") (dict "name" "worker.heapMb" "heap" $v.worker.heapMb "res" $v.worker.resources "limitName" "worker.resources.limits.memory") (dict "name" "migrations.heapMb" "heap" $v.migrations.heapMb "res" $v.migrations.resources "limitName" "migrations.resources.limits.memory") -}}
{{- $limit := dig "limits" "memory" "" ($w.res | default dict) -}}
{{- if and $w.heap $limit -}}
{{- $heapBytes := mul (int64 $w.heap) 1048576 -}}
{{- $limitBytes := include "tasksense.toBytes" $limit | int64 -}}
{{- if gt (mul $heapBytes 10) (mul $limitBytes 9) -}}
{{- fail (printf "%s (%v MB) leaves too little of %s (%s) for native memory and buffers — keep the heap at about 75%% of the limit, or the kernel OOM-kills the pod before V8 collects" $w.name (toString $w.heap) $w.limitName (toString $limit)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* ── networking ────────────────────────────────────────────────────── */ -}}
{{- if and $v.ingress.enabled $v.route.enabled -}}
{{- fail "ingress.enabled and route.enabled are mutually exclusive — an Ingress for Kubernetes, a Route for OpenShift" -}}
{{- end -}}
{{- if $v.ingress.enabled -}}
{{- if and (not $v.ingress.hosts) (not $v.appUrl) -}}
{{- fail "ingress.hosts is required when appUrl is not set (appUrl's host is the default)" -}}
{{- end -}}
{{- $upload := include "tasksense.nginxBytes" $v.ingress.uploadMaxBody | int64 -}}
{{- $jira := mulf (include "tasksense.str" $v.config.jiraBackupMaxGb | float64) 1073741824 | int64 -}}
{{- if and (gt $upload 0) (lt $upload $jira) -}}
{{- fail (printf "ingress.uploadMaxBody (%s) is smaller than config.jiraBackupMaxGb (%s GB): the ingress would reject a Jira backup the application accepts, with an nginx 413 instead of the application's own message. Set ingress.uploadMaxBody to at least %dg." (toString $v.ingress.uploadMaxBody) (include "tasksense.str" $v.config.jiraBackupMaxGb) (add1 (int64 (ceil (include "tasksense.str" $v.config.jiraBackupMaxGb | float64))))) -}}
{{- end -}}
{{- end -}}

{{- /* ── certificates ──────────────────────────────────────────────────── */ -}}
{{- with $v.certs.caBundle -}}
{{- if not (include "tasksense.hasCerts" $) -}}
{{- fail (printf "certs.caBundle=%s but no certificate is mounted — set certs.files, certs.existingConfigMap or certs.existingSecret" .) -}}
{{- end -}}
{{- if and $v.certs.files (not $v.certs.existingConfigMap) (not $v.certs.existingSecret) (not (hasKey $v.certs.files .)) -}}
{{- fail (printf "certs.caBundle=%s is not one of the files in certs.files (%s)" . (keys $v.certs.files | sortAlpha | join ", ")) -}}
{{- end -}}
{{- if contains "/" (toString .) -}}
{{- fail (printf "certs.caBundle is a file NAME under /certs, not a path (got %s)" .) -}}
{{- end -}}
{{- end -}}

{{- /* ── registry credentials ──────────────────────────────────────────── */ -}}
{{- if $v.imageCredentials.create -}}
{{- if or (not $v.imageCredentials.username) (not $v.imageCredentials.password) -}}
{{- fail "imageCredentials.create=true needs imageCredentials.username and imageCredentials.password (the registry token)" -}}
{{- end -}}
{{- end -}}
{{- end -}}
