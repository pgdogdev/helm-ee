{{/*
Expand the name of the chart.
*/}}
{{- define "pgdog-control.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Truncated at 63 chars per the DNS naming spec.
*/}}
{{- define "pgdog-control.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart name and version, as used by the helm.sh/chart label.
*/}}
{{- define "pgdog-control.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Resource names for each component (preserve existing names for compatibility).
*/}}
{{- define "pgdog-control.control.fullname" -}}
{{- printf "%s-control" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Name for resources shared across releases — cluster-scoped objects
(ClusterRole, ClusterRoleBinding) and the namespaced Role/RoleBinding
written into each writeNamespace, which is reachable by every install
of this chart. Includes the release namespace so multiple installs on
the same cluster don't collide.
*/}}
{{- define "pgdog-control.control.clusterFullname" -}}
{{- printf "%s-%s-control" .Release.Name .Release.Namespace | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "pgdog-control.redis.fullname" -}}
{{- printf "%s-redis" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
ServiceAccount name for the control component. Falls back to the
control fullname when not explicitly set in values.
*/}}
{{- define "pgdog-control.control.serviceAccountName" -}}
{{- if .Values.control.rbac.serviceAccountName }}
{{- .Values.control.rbac.serviceAccountName }}
{{- else }}
{{- include "pgdog-control.control.fullname" . }}
{{- end }}
{{- end }}

{{/*
Common labels shared by all resources.
*/}}
{{- define "pgdog-control.commonLabels" -}}
helm.sh/chart: {{ include "pgdog-control.chart" . }}
app.kubernetes.io/part-of: {{ include "pgdog-control.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
Labels for the control component.
*/}}
{{- define "pgdog-control.labels" -}}
{{ include "pgdog-control.commonLabels" . }}
{{ include "pgdog-control.selectorLabels" . }}
{{- end }}

{{/*
Selector labels for the control component.
*/}}
{{- define "pgdog-control.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pgdog-control.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: control
{{- end }}

{{/*
Labels for the redis component.
*/}}
{{- define "pgdog-control.redis.labels" -}}
{{ include "pgdog-control.commonLabels" . }}
{{ include "pgdog-control.redis.selectorLabels" . }}
{{- end }}

{{/*
Selector labels for the redis component.
*/}}
{{- define "pgdog-control.redis.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pgdog-control.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: redis
{{- end }}
