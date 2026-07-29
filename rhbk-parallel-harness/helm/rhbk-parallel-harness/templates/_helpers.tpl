{{- define "rhbk-parallel-harness.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rhbk-parallel-harness.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "rhbk-parallel-harness.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
