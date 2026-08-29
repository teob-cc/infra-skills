{{- define "dex.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "dex.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "dex.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "dex.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- if .Values.serviceAccount.name -}}
{{- .Values.serviceAccount.name -}}
{{- else -}}
{{- include "dex.fullname" . -}}
{{- end -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "dex.labels" -}}
app.kubernetes.io/name: {{ include "dex.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/component: sso
app.kubernetes.io/part-of: identity
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end -}}

{{- define "dex.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dex.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "dex.config" -}}
issuer: {{ required "config.issuer" .Values.config.issuer }}
storage:
  type: kubernetes
  config:
    inCluster: true
web:
  http: 0.0.0.0:{{ default 5556 .Values.service.httpPort }}
  allowedOrigins:
    - '*'
telemetry:
  http: 0.0.0.0:{{ default 5558 .Values.service.telemetryPort }}
oauth2:
  skipApprovalScreen: true
  responseTypes:
    - code
    - token
    - id_token
connectors:
  - type: github
    id: github
    name: GitHub
    config:
      clientID: {{ required "config.github.clientID" .Values.config.github.clientID | quote }}
      clientSecret: {{ required "config.github.clientSecret" .Values.config.github.clientSecret | quote }}
      redirectURI: {{ printf "%s/callback" (required "config.issuer" .Values.config.issuer) | quote }}
      loadAllGroups: {{ default true .Values.config.github.loadAllGroups }}
      useLoginAsID: {{ default true .Values.config.github.useLoginAsID }}
      orgs:
        - name: {{ required "config.github.org" .Values.config.github.org | quote }}
{{- if .Values.config.github.teams }}
          teams:
{{- range .Values.config.github.teams }}
            - {{ . | quote }}
{{- end }}
{{- end }}
staticClients:
{{- if .Values.config.staticClients }}
{{ toYaml .Values.config.staticClients | indent 2 }}
{{- else }}
  []
{{- end }}
enablePasswordDB: {{ default false .Values.config.enablePasswordDB }}
{{- end -}}
