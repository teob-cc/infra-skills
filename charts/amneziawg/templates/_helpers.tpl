{{- define "amneziawg.labels" -}}
app.kubernetes.io/name: amneziawg
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "amneziawg.selector" -}}
app.kubernetes.io/name: amneziawg
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
