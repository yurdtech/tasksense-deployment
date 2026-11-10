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

{{- /* The same, from a chart before the blocks below existed (1.1.0). */ -}}
{{- $missing := list -}}
{{- range $k := list "redis" "autoscaling" "podDisruptionBudget" "strategy" "jiraSync" -}}
{{- if not (hasKey $v $k) -}}{{- $missing = append $missing $k -}}{{- end -}}
{{- end -}}
{{- if $missing -}}
{{- fail (printf "these values come from an earlier chart (no %s block). That is what `helm upgrade --reuse-values` does across chart versions: it drops every default the new chart adds. Upgrade with your own file instead: `helm upgrade ... -f my-values.yaml` (or --reset-then-reuse-values on Helm >= 3.14). docs/02-INSTALL-KUBERNETES.md, \"Upgrade\"." (join " / " $missing)) -}}
{{- end -}}

{{- /* ── how many API processes ────────────────────────────────────────── */ -}}
{{- /* One without Redis: tickets, lockouts, rate-limit counters, cache
       invalidations and the live-update fan-out are then in its memory, and
       a second pod would believe something different about each. Up to 20
       with Redis, which shares them, and a ReadWriteMany volume, because
       every pod reads and writes the same attachments and staged uploads.
       With Redis, schedulers run under MongoDB job leases. */ -}}
{{- $r := $v.redis | default (dict) -}}
{{- $redis := eq (include "tasksense.redisConfigured" .) "true" -}}
{{- $as := $v.autoscaling | default (dict) -}}
{{- $hpa := and (kindIs "map" $as) (eq (toString (index $as "enabled")) "true") -}}
{{- $pdb := index $v "podDisruptionBudget" | default (dict) -}}
{{- $pdbOn := and (kindIs "map" $pdb) (eq (toString (index $pdb "enabled")) "true") -}}
{{- $replicas := int ($v.replicaCount | default 0) -}}
{{- $strategy := toString (dig "type" "Recreate" ($v.strategy | default (dict))) -}}
{{- if not (has $strategy (list "Recreate" "RollingUpdate")) -}}
{{- fail (printf "strategy.type must be Recreate or RollingUpdate (got %s)" $strategy) -}}
{{- end -}}
{{- if lt $replicas 0 -}}
{{- fail (printf "replicaCount must be 0 or more (got %v; 0 stops the API)" (toString $v.replicaCount)) -}}
{{- end -}}
{{- if gt $replicas 20 -}}
{{- fail (printf "replicaCount=%d is above the supported maximum of 20 API pods. Twenty is what the shared state, the MongoDB connection budget (20 x 50) and the planned load test are sized for; beyond it, talk to us (info@yurdtech.az). docs/15-SCALING-AND-HA.md" $replicas) -}}
{{- end -}}
{{- if $hpa -}}
{{- $min := int (index $as "minReplicas" | default 0) -}}
{{- $max := int (index $as "maxReplicas" | default 0) -}}
{{- if gt $max 20 -}}
{{- fail (printf "autoscaling.maxReplicas=%d is above the supported maximum of 20 API pods. Twenty is what the shared state, the MongoDB connection budget (20 x 50) and the planned load test are sized for. docs/15-SCALING-AND-HA.md" $max) -}}
{{- end -}}
{{- if or (lt $min 1) (gt $min $max) -}}
{{- fail (printf "autoscaling.minReplicas (%d) must be between 1 and autoscaling.maxReplicas (%d)" $min $max) -}}
{{- end -}}
{{- $cpu := include "tasksense.str" (index $as "targetCPUUtilizationPercentage") -}}
{{- $mem := include "tasksense.str" (index $as "targetMemoryUtilizationPercentage") -}}
{{- if and (not $cpu) (not $mem) -}}
{{- fail "autoscaling.enabled=true needs a target: autoscaling.targetCPUUtilizationPercentage and/or autoscaling.targetMemoryUtilizationPercentage" -}}
{{- end -}}
{{- if and $cpu (not (dig "requests" "cpu" "" ($v.resources | default (dict)))) -}}
{{- fail "autoscaling.targetCPUUtilizationPercentage needs resources.requests.cpu — utilisation is measured against the request" -}}
{{- end -}}
{{- if and $mem (not (dig "requests" "memory" "" ($v.resources | default (dict)))) -}}
{{- fail "autoscaling.targetMemoryUtilizationPercentage needs resources.requests.memory — utilisation is measured against the request" -}}
{{- end -}}
{{- end -}}

{{- /* ── Redis: exactly one connection, never half of one ───────────────── */ -}}
{{- $urlFromSecret := and $r.existingSecret $r.existingSecretKey -}}
{{- $sentinels := include "tasksense.csv" $r.sentinels -}}
{{- $cluster := include "tasksense.csv" $r.clusterNodes -}}
{{- $given := list -}}
{{- if or $r.url $urlFromSecret -}}{{- $given = append $given (ternary "redis.url" (printf "redis.existingSecret (%s)" (toString $r.existingSecretKey)) (not (empty $r.url))) -}}{{- end -}}
{{- if $sentinels -}}{{- $given = append $given "redis.sentinels" -}}{{- end -}}
{{- if $cluster -}}{{- $given = append $given "redis.clusterNodes" -}}{{- end -}}
{{- if gt (len $given) 1 -}}
{{- fail (printf "redis: set exactly one connection — redis.url (or redis.existingSecret), redis.sentinels or redis.clusterNodes; %s are set together. The application refuses two at boot." (join " and " $given)) -}}
{{- end -}}
{{- if and $r.url $urlFromSecret -}}
{{- fail (printf "redis.url and redis.existingSecret (key %s) both supply REDIS_URL — keep one. For a Secret that holds only the password, set redis.existingSecretKey to \"\" and name the password with redis.existingSecretPasswordKey." (toString $r.existingSecretKey)) -}}
{{- end -}}
{{- if and $r.existingSecret (not $r.existingSecretKey) (not $r.existingSecretPasswordKey) -}}
{{- fail (printf "redis.existingSecret=%s names no key: set redis.existingSecretKey (REDIS_URL) and/or redis.existingSecretPasswordKey (REDIS_PASSWORD)" (toString $r.existingSecret)) -}}
{{- end -}}
{{- if and $r.password $r.existingSecret $r.existingSecretPasswordKey -}}
{{- fail "redis.password and redis.existingSecretPasswordKey both supply REDIS_PASSWORD — keep one" -}}
{{- end -}}
{{- if and $r.url (not (regexMatch "^rediss?://" (toString $r.url))) -}}
{{- fail "redis.url must start with redis:// or rediss:// (TLS)" -}}
{{- end -}}
{{- if and (or $r.url $urlFromSecret) (eq (toString $r.tls) "true") -}}
{{- fail "redis.tls does not apply to redis.url — use a rediss:// URL for TLS (redis.tls is for sentinels and cluster nodes)" -}}
{{- end -}}
{{- if and $sentinels (not $r.sentinelName) -}}
{{- fail "redis.sentinels needs redis.sentinelName — the name of the master group the sentinels watch (often mymaster)" -}}
{{- end -}}
{{- if not $sentinels -}}
{{- if $r.sentinelName -}}{{- fail "redis.sentinelName only applies with redis.sentinels" -}}{{- end -}}
{{- if $r.sentinelPassword -}}{{- fail "redis.sentinelPassword only applies with redis.sentinels" -}}{{- end -}}
{{- end -}}
{{- if not $redis -}}
{{- range $k := list "username" "password" "existingSecretPasswordKey" -}}
{{- if index $r $k -}}
{{- fail (printf "redis.%s has no effect without a Redis connection — set redis.url (or redis.existingSecret), redis.sentinels or redis.clusterNodes. The application refuses it at boot." $k) -}}
{{- end -}}
{{- end -}}
{{- if eq (toString $r.tls) "true" -}}
{{- fail "redis.tls has no effect without a Redis connection — set redis.sentinels or redis.clusterNodes" -}}
{{- end -}}
{{- end -}}
{{- if $v.existingSecret -}}
{{- range $k := list "url" "password" "sentinelPassword" -}}
{{- if index $r $k -}}
{{- fail (printf "redis.%s is a secret, and with existingSecret=%s the chart renders no Secret of its own to put it in. Put it in a Secret you manage (it can be %s) and name it: redis.existingSecret, with redis.existingSecretKey for REDIS_URL and redis.existingSecretPasswordKey for REDIS_PASSWORD; a sentinel password goes into %s as REDIS_SENTINEL_PASSWORD." $k (toString $v.existingSecret) (toString $v.existingSecret) (toString $v.existingSecret)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* ── more than one API process needs Redis and shared storage ────────── */ -}}
{{- $needs := list -}}
{{- if gt $replicas 1 -}}{{- $needs = append $needs (printf "replicaCount=%d" $replicas) -}}{{- end -}}
{{- if $hpa -}}{{- $needs = append $needs "autoscaling.enabled=true" -}}{{- end -}}
{{- if $pdbOn -}}{{- $needs = append $needs "podDisruptionBudget.enabled=true" -}}{{- end -}}
{{- if eq $strategy "RollingUpdate" -}}{{- $needs = append $needs "strategy.type=RollingUpdate" -}}{{- end -}}
{{- range $what := $needs -}}
{{- if not $redis -}}
{{- fail (printf "%s is not supported without Redis: more than one API process needs the state Redis shares — sign-in tickets, lockout and rate-limit counters, job status, cache invalidations and the live-update fan-out. Without it each pod believes something different about who is signed in and what changed. Configure redis.url (or redis.existingSecret, redis.sentinels, redis.clusterNodes) and persistence.accessMode=ReadWriteMany, or keep replicaCount=1 with strategy Recreate (0 stops the API). docs/15-SCALING-AND-HA.md" $what) -}}
{{- end -}}
{{- if not $v.persistence.enabled -}}
{{- fail (printf "%s needs persistence.enabled=true: every API pod must see the same attachments, backups and staged uploads, and an emptyDir is one pod's own" $what) -}}
{{- end -}}
{{- if ne (toString $v.persistence.accessMode) "ReadWriteMany" -}}
{{- fail (printf "%s needs persistence.accessMode=ReadWriteMany (it is %s): every API pod mounts the data volume — attachments, BACKUP_DIR and the uploads staged in TMPDIR=/app/api/data/tmp — usually from different nodes, and a ReadWriteOnce claim attaches to one node only. Use a ReadWriteMany storage class (NFS, CephFS / ODF, Azure Files, EFS …); with persistence.existingClaim, declare the claim's mode here. docs/15-SCALING-AND-HA.md" $what (toString $v.persistence.accessMode)) -}}
{{- end -}}
{{- end -}}

{{- /* ── the drain before SIGTERM ───────────────────────────────────────── */ -}}
{{- $preStop := int ($v.preStopSleepSeconds | default 0) -}}
{{- if lt $preStop 0 -}}
{{- fail "preStopSleepSeconds must be 0 or more (0 turns the drain off)" -}}
{{- end -}}
{{- if include "tasksense.preStop" . -}}
{{- if lt (int $v.terminationGracePeriodSeconds) (add $preStop 20) -}}
{{- fail (printf "terminationGracePeriodSeconds (%d) must be at least preStopSleepSeconds + 20 (%d): the grace period includes the preStop sleep, and the process still needs time after it to finish in-flight requests" (int $v.terminationGracePeriodSeconds) (add $preStop 20)) -}}
{{- end -}}
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
      "WORKER_ROLE" "set from worker.enabled / jiraSync.enabled"
      "JIRA_SYNC_RUNNER" "set from jiraSync.enabled"
      "SYNC_WORKER_PORT" "use jiraSync.port"
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
      "BACKUP_DIR" "fixed to the data volume"
      "WEB_ASSETS_SHARED_DIR" "set from strategy.type"
      "REDIS_URL" "a secret: redis.url or redis.existingSecret"
      "REDIS_PASSWORD" "a secret: redis.password or redis.existingSecretPasswordKey"
      "REDIS_SENTINEL_PASSWORD" "a secret: redis.sentinelPassword"
      "REDIS_SENTINELS" "use redis.sentinels"
      "REDIS_SENTINEL_NAME" "use redis.sentinelName"
      "REDIS_CLUSTER_NODES" "use redis.clusterNodes"
      "REDIS_USERNAME" "use redis.username"
      "REDIS_TLS" "use redis.tls"
      "REDIS_KEY_PREFIX" "use redis.keyPrefix" -}}
{{- range $k, $_ := $v.extraEnv -}}
{{- if hasKey $owned $k -}}
{{- fail (printf "extraEnv.%s cannot be set: the chart manages it (%s)" $k (get $owned $k)) -}}
{{- end -}}
{{- end -}}

{{- /* ── required values ───────────────────────────────────────────────── */ -}}
{{- if not $v.existingSecret -}}
{{- if not $v.appUrl -}}
{{- fail "appUrl is required — the URL users type, e.g. https://tasksense.corp.internal" -}}
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
{{- fail (printf "appUrl must be an absolute http(s) URL, e.g. https://tasksense.corp.internal (got %q)" (toString $v.appUrl)) -}}
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

{{- /* ── Jira sync worker ──────────────────────────────────────────────── */ -}}
{{- if $v.jiraSync.enabled -}}
{{- if not $v.persistence.enabled -}}
{{- fail "jiraSync.enabled=true (the default) requires persistence.enabled=true: the sync worker writes Jira attachments to the same data volume the API serves them from. Set jiraSync.enabled: false to keep the Jira sync in the API process." -}}
{{- end -}}
{{- if eq (toString $v.persistence.accessMode) "ReadWriteOncePod" -}}
{{- fail "jiraSync.enabled=true (the default) cannot run with persistence.accessMode=ReadWriteOncePod: only one pod may mount the data volume, and the sync worker writes attachments to it. Use ReadWriteOnce (the worker is then scheduled onto the API's node) or ReadWriteMany — or set jiraSync.enabled: false to keep the Jira sync in the API process." -}}
{{- end -}}
{{- if or (lt (int $v.jiraSync.port) 1024) (gt (int $v.jiraSync.port) 65535) (eq (int $v.jiraSync.port) 3000) -}}
{{- fail (printf "jiraSync.port must be between 1024 and 65535 and not 3000, the API's port (got %v)" $v.jiraSync.port) -}}
{{- end -}}
{{- end -}}

{{- /* ── enumerations the application would reject at boot ─────────────── */ -}}
{{- if not (has (toString $v.persistence.accessMode) (list "ReadWriteOnce" "ReadWriteMany" "ReadWriteOncePod")) -}}
{{- fail (printf "persistence.accessMode must be ReadWriteOnce, ReadWriteMany or ReadWriteOncePod (got %s)" (toString $v.persistence.accessMode)) -}}
{{- end -}}
{{- if not (has (toString $v.config.mongodbCompressors) (list "zlib" "none")) -}}
{{- fail (printf "config.mongodbCompressors must be zlib or none (got %s)" (toString $v.config.mongodbCompressors)) -}}
{{- end -}}
{{- $rls := include "tasksense.str" $v.config.rateLimitStore -}}
{{- if not (has $rls (list "" "memory" "mongo" "redis")) -}}
{{- fail (printf "config.rateLimitStore must be memory, mongo or redis — or empty, to let the application choose (got %s)" $rls) -}}
{{- end -}}
{{- if and (eq $rls "redis") (not $redis) -}}
{{- fail "config.rateLimitStore=redis needs Redis (redis.url, redis.existingSecret, redis.sentinels or redis.clusterNodes) — the application refuses it at boot. Leave it empty to let the application choose." -}}
{{- end -}}
{{- if and (eq $rls "memory") (include "tasksense.multiApi" .) -}}
{{- fail "config.rateLimitStore=memory with more than one API process: each pod would count only the requests that reached it, so every limit — sign-in attempts included — would be as many times higher as there are pods. Leave it empty (Redis is then used) or set redis / mongo." -}}
{{- end -}}
{{- with include "tasksense.str" $v.config.trustProxy -}}
{{- if not (regexMatch "^[0-5]$" .) -}}
{{- fail (printf "config.trustProxy must be a number of proxy hops from 0 to 5, or empty for the application's 1 (got %s)" .) -}}
{{- end -}}
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
{{- range $w := list (dict "name" "heapMb" "heap" $v.heapMb "res" $v.resources "limitName" "resources.limits.memory") (dict "name" "worker.heapMb" "heap" $v.worker.heapMb "res" $v.worker.resources "limitName" "worker.resources.limits.memory") (dict "name" "migrations.heapMb" "heap" $v.migrations.heapMb "res" $v.migrations.resources "limitName" "migrations.resources.limits.memory") (dict "name" "jiraSync.heapMb" "heap" $v.jiraSync.heapMb "res" $v.jiraSync.resources "limitName" "jiraSync.resources.limits.memory") -}}
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
