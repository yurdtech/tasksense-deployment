{{/*
The pod spec shared by the nightly backup CronJob and the pre-upgrade dump Job.
Call with (dict "root" $ "hook" bool "kind" "nightly|pre-upgrade" "prefix" "<file prefix>").

It mounts the backups claim and /certs (MONGODB_URI may name
tlsCAFile=/certs/…) — never the data volume. It reads only MONGODB_URI from the
Secret (secretKeyRef), not the whole configuration.
*/}}
{{- define "tasksense.dumpPodSpec" -}}
{{- $root := .root -}}
{{- $hook := eq (toString .hook) "true" -}}
restartPolicy: Never
serviceAccountName: {{ ternary (include "tasksense.hookServiceAccountName" $root) (include "tasksense.serviceAccountName" $root) $hook }}
automountServiceAccountToken: false
enableServiceLinks: false
{{- include "tasksense.imagePullSecrets" (dict "root" $root "hook" $hook) }}
{{- include "tasksense.mongoPodSecurityContext" $root | nindent 0 }}
containers:
  - name: mongodump
    image: {{ include "tasksense.mongoImage" $root }}
    imagePullPolicy: {{ $root.Values.backup.image.pullPolicy | default "IfNotPresent" }}
    # bash, not sh: /bin/sh in the mongo image is dash, which rejects pipefail.
    command:
      - /bin/bash
      - -c
      - |
        {{- include "tasksense.dumpScript" $root | nindent 8 }}
    {{- include "tasksense.containerSecurityContext" $root | nindent 4 }}
    env: {{- include "tasksense.dumpEnv" (dict "root" $root "hook" $hook "kind" .kind "prefix" .prefix) | nindent 6 }}
    resources: {{- toYaml $root.Values.backup.resources | nindent 6 }}
    volumeMounts:
      - name: backups
        mountPath: /backups
      # In memory: holds the mongodump config file with the URI in it.
      - name: work
        mountPath: /work
      - name: tmp
        mountPath: /tmp
      {{- include "tasksense.certsMount" $root | nindent 6 }}
volumes:
  - name: backups
    persistentVolumeClaim:
      claimName: {{ include "tasksense.backupClaimName" $root }}
  - name: work
    emptyDir:
      medium: Memory
      sizeLimit: 1Mi
  - name: tmp
    emptyDir:
      sizeLimit: 64Mi
  {{- include "tasksense.certsVolume" (dict "root" $root "hook" $hook) | nindent 2 }}
{{- with $root.Values.backup.nodeSelector }}
nodeSelector: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.backup.tolerations }}
tolerations: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.backup.affinity }}
affinity: {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
