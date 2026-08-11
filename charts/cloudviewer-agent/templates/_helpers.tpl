{{/*
Helpers, upstream-vector-chart idioms kept, generality dropped.
No nameOverride/fullnameOverride: one agent DaemonSet per cluster is the
supported shape, and fewer knobs is the point of this chart.
*/}}

{{- define "cloudviewer-agent.name" -}}
{{- .Chart.Name }}
{{- end }}

{{/*
Release-derived resource name, truncated to the 63-char DNS label limit.
"cloudviewer-agent" installed as release "cloudviewer-agent" stays exactly
that instead of doubling up.
*/}}
{{- define "cloudviewer-agent.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "cloudviewer-agent.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "cloudviewer-agent.selectorLabels" . }}
{{- end }}

{{/*
Selector labels are a subset of the full labels and must stay stable:
a DaemonSet's selector is immutable after install.
*/}}
{{- define "cloudviewer-agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cloudviewer-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Image reference. A digest pin wins over the tag (immutable — what the
release publishes and what "the chart pins by digest" in specs/30 §6
means); otherwise the tag, defaulting to the chart's appVersion.
*/}}
{{- define "cloudviewer-agent.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}
{{- end }}

{{/*
The Secret the token volume mounts: the user's existingSecret, or the one
secret.yaml creates from .Values.token.
*/}}
{{- define "cloudviewer-agent.secretName" -}}
{{- .Values.existingSecret | default (include "cloudviewer-agent.fullname" .) }}
{{- end }}
