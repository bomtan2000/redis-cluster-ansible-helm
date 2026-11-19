{{- define "redis.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis.headless" -}}
{{- printf "%s-headless" (include "redis.fullname" .) -}}
{{- end -}}

{{/* StatefulSet selector is immutable: keep exactly `app: redis` like the existing cluster. */}}
{{- define "redis.selectorLabels" -}}
app: {{ include "redis.fullname" . }}
{{- end -}}

{{- define "redis.labels" -}}
{{ include "redis.selectorLabels" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* "redis-0 redis-1 ... redis-5" */}}
{{- define "redis.podNames" -}}
{{- $names := list -}}
{{- range $i := until (int .Values.replicas) -}}
{{- $names = append $names (printf "%s-%d" (include "redis.fullname" $) $i) -}}
{{- end -}}
{{- join " " $names -}}
{{- end -}}

{{- define "redis.headlessDomain" -}}
{{- printf "%s.%s.svc.cluster.local" (include "redis.headless" .) .Release.Namespace -}}
{{- end -}}

{{- define "redis.image" -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
