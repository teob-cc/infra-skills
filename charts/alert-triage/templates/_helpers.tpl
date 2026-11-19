{{- define "alert-triage.labels" -}}
app.kubernetes.io/name: alert-triage
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "alert-triage.selector" -}}
app.kubernetes.io/name: alert-triage
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
