{{/* Labels shared by every object */}}
{{- define "kubemart.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: kubemart
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
kubemart/environment: {{ .root.Values.global.environment }}
{{- end }}

{{/* Selector labels for one service */}}
{{- define "kubemart.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{/* Full image reference: <registry>/<repository>:<tag> */}}
{{- define "kubemart.image" -}}
{{- $registry := .root.Values.global.imageRegistry -}}
{{- if $registry -}}
{{ printf "%s/%s:%s" $registry .svc.image (toString .svc.tag) }}
{{- else -}}
{{ printf "%s:%s" .svc.image (toString .svc.tag) }}
{{- end -}}
{{- end }}

{{/*
Secret the postgres-operator creates for a database user:
  <user>.<cluster>.credentials.postgresql.acid.zalan.do  (keys: username, password)
Usage: include "kubemart.dbSecret" (dict "root" $root "user" "orders")
*/}}
{{- define "kubemart.dbSecret" -}}
{{ printf "%s.%s.credentials.postgresql.acid.zalan.do" .user .root.Values.postgres.clusterName }}
{{- end }}

{{/* Valkey Service name */}}
{{- define "kubemart.valkeyName" -}}
{{ .Release.Name }}-valkey
{{- end }}

{{/* Security settings every container gets (passes the "restricted" Pod Security Standard) */}}
{{- define "kubemart.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: {{ .readOnly }}
capabilities:
  drop: ["ALL"]
{{- end }}
