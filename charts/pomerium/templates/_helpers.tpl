{{- define "pomerium.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "pomerium.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "pomerium.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "pomerium.labels" -}}
app.kubernetes.io/name: {{ include "pomerium.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/component: auth-proxy
app.kubernetes.io/part-of: identity
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end -}}

{{- define "pomerium.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pomerium.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "pomerium.config" -}}
address: ":80"
insecure_server: true
skip_xff_append: true
# Global request-read timeout → Envoy HTTP connection-manager `request_timeout`
# (time to receive the *entire* request, body included). Pomerium's default is 30s,
# which 408s a multi-GB snapshot upload at ~30s of transfer regardless of the
# per-route `timeout` / `idle_timeout` (those are response/idle timeouts, separate).
# Bumped to 4h to match the per-route values and the Traefik responding timeouts.
timeout_read: 14400s
authenticate_service_url: {{ required "config.authenticateServiceUrl" .Values.config.authenticateServiceUrl }}
authenticate_internal_service_url: http://127.0.0.1:80
idp_provider: {{ .Values.config.idpProvider }}
idp_provider_url: {{ required "config.idpProviderUrl" .Values.config.idpProviderUrl }}
idp_client_id: {{ .Values.config.idpClientId }}
idp_client_secret: {{ required "config.idpClientSecret" .Values.config.idpClientSecret }}
idp_scopes: ["openid", "profile", "email", "groups"]
cookie_secret: {{ required "config.cookieSecret" .Values.config.cookieSecret }}
shared_secret: {{ required "config.sharedSecret" .Values.config.sharedSecret }}
{{- if .Values.config.runtimeFlags }}
# Pomerium runtime feature flags (e.g. `mcp: true` to enable the MCP authorization
# server + `mcp:` route stanzas — default-off as of v0.32.x). Set per env in
# pomerium-routes.yaml next to `config.routes`.
runtime_flags:
{{ toYaml .Values.config.runtimeFlags | indent 2 }}
{{- end }}
{{- if .Values.config.mcpAllowedClientIdDomains }}
# Domains whose MCP client-ID metadata URLs Pomerium will fetch (wildcards allowed,
# e.g. "*.example.com"). REQUIRED when the mcp runtime flag is on — client
# registration 401s with "client domain not authorized" if the list is empty.
mcp_allowed_client_id_domains:
{{ toYaml .Values.config.mcpAllowedClientIdDomains | indent 2 }}
{{- end }}
{{- if .Values.config.routes }}
routes:
{{ toYaml .Values.config.routes | indent 2 }}
{{- else }}
routes: []
{{- end }}
{{- end -}}

