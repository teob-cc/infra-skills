#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# K3S Observability Stack Provisioning
# ============================================================================
# Provisions comprehensive observability infrastructure:
# 1. Loki (log aggregation and storage)
# 2. Promtail (log shipping agent)
# 3. Prometheus (metrics collection and storage)
# 4. Grafana (visualization with GitHub SSO via Dex)
# 5. Pre-configured Kubernetes dashboards
#
# Usage:
#   tools/k3s/observability.sh <env-name> [options]
#
# Options:
#   --skip-loki          Skip Loki installation
#   --skip-promtail      Skip Promtail installation
#   --skip-prometheus    Skip Prometheus installation
#   --skip-grafana       Skip Grafana installation
#   --skip-dns           Skip DNS record creation
#   --skip-sso           Skip GitHub SSO configuration
#   --sync-dashboards    Only upsert dashboards from envs/shared/dashboards into Grafana
#   --rules-only         Only upgrade the prometheus release (rules, scrape jobs,
#                        Alertmanager config) with the full rendered values
#   --dry-run            With --rules-only semantics: render server-side, print the
#                        ConfigMap diff against the live release, change nothing
#
# env.properties (optional):
#   GRAFANA_ADMIN_PASSWORD  Grafana admin password; unset = keep the one in
#                        secret/grafana, generated on first install only
#   GRAFANA_MCP=true     Ensure the Viewer service account `mcp-grafana` and its token
#                        (Secret observability/mcp-grafana-token, SOPS copy in the envs
#                        repo) for the mcp-grafana MCP server; see grafana-mcp-token.sh
#   LOG_SHIPPER=alloy    Ship logs with Grafana Alloy instead of Promtail (EOL 2026-03-02);
#                        uninstalls the promtail release. Default: promtail
#   LOKI_RETENTION_PERIOD  e.g. 2160h; enables compactor retention. Default: keep forever
#   GITHUB_ORG           Org for Grafana's role mapping; default: secrets.plain, then the
#                        live Dex config
#
# Environment:
#   ALLOW_GRAFANA_REGRESSION=true  let a run drop SSO, root_url or a datasource that the
#                        live Grafana release has (refused by default)
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

# --- Argument parsing ---
if [[ -z "${1:-}" ]]; then
  cat >&2 <<EOF
Usage: $0 <env-name> [options]

Options:
  --skip-loki          Skip Loki installation
  --skip-promtail      Skip Promtail installation
  --skip-prometheus    Skip Prometheus installation
  --skip-grafana       Skip Grafana installation
  --skip-dns           Skip DNS record creation
  --skip-sso           Skip GitHub SSO configuration
  --sync-dashboards    Only upsert dashboards into Grafana
  --rules-only         Only upgrade the prometheus release (rules, scrape, Alertmanager)
  --dry-run            Like --rules-only, but only print the ConfigMap diff

Available environments:
EOF
  find "$(provision::envs_root)" -maxdepth 2 -type f -name env.properties -print | \
    sed "s#$(provision::envs_root)/##; s#/env.properties##" | sort || true
  exit 1
fi

if provision::load_env "${1:-}"; then
  shift
else
  echo "ERROR: Environment '$1' not found (envs/$1/env.properties missing)." >&2
  exit 1
fi

# Validate kubectl context matches environment
if ! provision::validate_kubectl_context; then
  exit 1
fi

# Parse flags
SKIP_LOKI=false
SKIP_PROMTAIL=false
SKIP_PROMETHEUS=false
SKIP_GRAFANA=false
SKIP_DNS=false
SKIP_SSO=false
SYNC_DASHBOARDS=false
RULES_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-loki) SKIP_LOKI=true; shift ;;
    --skip-promtail) SKIP_PROMTAIL=true; shift ;;
    --skip-prometheus) SKIP_PROMETHEUS=true; shift ;;
    --skip-grafana) SKIP_GRAFANA=true; shift ;;
    --skip-dns) SKIP_DNS=true; shift ;;
    --skip-sso) SKIP_SSO=true; shift ;;
    --sync-dashboards) SYNC_DASHBOARDS=true; shift ;;
    --rules-only) RULES_ONLY=true; shift ;;
    --dry-run) DRY_RUN=true; RULES_ONLY=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# --rules-only upgrades the prometheus release alone (alert rules, scrape jobs,
# Alertmanager routing), always with the full values this script renders, never a
# partial object. Loki, Promtail/Alloy, Grafana, DNS, SSO, the operator CRDs and the
# blackbox exporter are left as they are, so a rules change cannot touch Grafana's
# admin password or SSO. --dry-run implies it: helm renders the upgrade server-side,
# the script prints the diff of the prometheus-server and alertmanager ConfigMaps
# against the live ones, and nothing is written.
if [[ "$RULES_ONLY" == "true" ]]; then
  if [[ "$SKIP_PROMETHEUS" == "true" ]]; then
    echo "--rules-only/--dry-run and --skip-prometheus contradict each other" >&2
    exit 1
  fi
  SKIP_LOKI=true; SKIP_PROMTAIL=true; SKIP_GRAFANA=true; SKIP_DNS=true; SKIP_SSO=true
fi

# --- Validation ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need kubectl
need helm
need openssl
need yq

if ! provision::require_tools; then
  exit 1
fi

# --- Logging helpers ---
log() { echo "[observability] $*"; }
info() { echo "[observability:info] $*"; }
warn() { echo "[observability:warn] $*" >&2; }
err() { echo "[observability:error] $*" >&2; }

# --- Configuration ---
NAMESPACE_OBSERVABILITY="${NAMESPACE_OBSERVABILITY:-observability}"
NAMESPACE_ARGOCD="${NAMESPACE_ARGOCD:-argocd}"
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"

# Derive service hosts from HOSTNAME if not provided
if [[ -n "${HOSTNAME:-}" ]]; then
  GRAFANA_HOST="${GRAFANA_HOST:-grafana.${HOSTNAME}}"
  DEX_HOST="${DEX_HOST:-dex.${HOSTNAME}}"
  
  info "Auto-generated service hosts from HOSTNAME=${HOSTNAME}:"
  info "  GRAFANA_HOST=${GRAFANA_HOST}"
  info "  DEX_HOST=${DEX_HOST}"
fi

# Storage configuration with defaults
LOKI_STORAGE_SIZE="${LOKI_STORAGE_SIZE:-10Gi}"
LOKI_STORAGE_CLASS="${LOKI_STORAGE_CLASS:-local-path}"
PROMETHEUS_STORAGE_SIZE="${PROMETHEUS_STORAGE_SIZE:-10Gi}"
PROMETHEUS_STORAGE_CLASS="${PROMETHEUS_STORAGE_CLASS:-local-path}"
GRAFANA_STORAGE_SIZE="${GRAFANA_STORAGE_SIZE:-5Gi}"
GRAFANA_STORAGE_CLASS="${GRAFANA_STORAGE_CLASS:-local-path}"
ALERTMANAGER_STORAGE_SIZE="${ALERTMANAGER_STORAGE_SIZE:-2Gi}"
ALERTMANAGER_STORAGE_CLASS="${ALERTMANAGER_STORAGE_CLASS:-local-path}"

# Alertmanager email receiver — overridable per env.
# NOTIFY_EMAIL is where alerts land (your ops inbox, or an alias that forwards
# to it); FROM_EMAIL must be on a sender domain verified with your SMTP
# provider, or delivery fails silently.
ALERTMANAGER_NOTIFY_EMAIL="${ALERTMANAGER_NOTIFY_EMAIL:-ops@example.com}"
ALERTMANAGER_FROM_EMAIL="${ALERTMANAGER_FROM_EMAIL:-alerts@example.com}"
# Databases the generic 40 GiB PostgresDatabaseSizeHigh alert must skip, as a
# Prometheus label regex (e.g. "journal|archive"). An event journal that grows by
# design is not an anomaly at 40 GiB; give it its own horizon alert in
# envs/<env>/alerts/ instead. Set in env.properties; empty = alert on every database.
POSTGRES_SIZE_ALERT_EXCLUDE="${POSTGRES_SIZE_ALERT_EXCLUDE:-}"
# SMTP relay used by Alertmanager — Resend by default, but any SMTP relay works.
# The `resend-api-key` Secret in $NAMESPACE_OBSERVABILITY (applied via SOPS) is
# mounted at /etc/alertmanager/resend-key/api_key and read via
# smtp_auth_password_file.
ALERTMANAGER_SMTP_HOST="${ALERTMANAGER_SMTP_HOST:-smtp.resend.com:465}"

# Dead-man's switch for the alerting pipeline itself. The infra-alerting group fires
# an always-on Watchdog alert; when a heartbeat URL is configured, Alertmanager POSTs
# it to that URL every minute or two (healthchecks.io, Cronitor, Better Stack
# heartbeats and similar all accept a POST). The external service pages you when the
# heartbeats stop, which is the only way to learn that Prometheus, Alertmanager or the
# whole node is down: nothing inside the cluster can report its own death.
# Off by default. Two ways to switch it on:
#   - apply a Secret `alertmanager-deadman` (namespace observability, key `url`) via
#     SOPS like alertmanager-telegram -- preferred, the URL is a credential;
#   - export ALERTMANAGER_DEADMAN_URL before running this script; the script writes
#     it into that Secret. Keep it out of env.properties, which is committed in plain.
# With neither, the Watchdog goes to a null receiver and is visible only in the
# Alertmanager UI.
ALERTMANAGER_DEADMAN_URL="${ALERTMANAGER_DEADMAN_URL:-}"

# Public endpoints probed end-to-end by the blackbox exporter, space-separated, set
# per env in envs/<env>/env.properties. Empty (the default) skips the exporter and the
# scrape job entirely, so envs that have not opted in are unaffected. The shared
# 'uptime' alert group in envs/shared/alerts/uptime.yml consumes the resulting metrics.
PROBE_TARGETS="${PROBE_TARGETS:-}"

# Dynamic endpoints probed with an uncached POST, space-separated, same per-env opt-in.
# A GET probe cannot see through an nginx micro-cache with background_update on: once
# a URL has been cached, nginx serves instant stale 200s indefinitely while the backend
# is dead (seen on a public site: every GET probe green, every real php request
# hung on a wedged php-fpm pool). POST bypasses shared caches by convention (route
# POST past the cache in your nginx skip-cache map so it hits the backend directly),
# so these probes exercise the full path to the application backend. Probed via the http_2xx_post module defined in the
# blackbox exporter values below; the same shared 'uptime' rules consume the metrics.
PROBE_TARGETS_POST="${PROBE_TARGETS_POST:-}"

# Helm chart versions. Every chart here used to be installed unpinned, so any run
# silently upgraded whatever was latest that day: a routing-only change once
# dragged Prometheus from 29.18.0 to 29.27.0 (v3.13.1 -> v3.14.0) as a side
# effect. Pinning makes a version change its own reviewable edit.
#
# Defaults track cit, the reference env. Envs that sit on other versions pin
# themselves in envs/<env>/env.properties (prod does) rather than being dragged
# forward or rolled back by a run -- prod is a major Loki version behind cit, so a
# single shared default could only be wrong for one of them. Upgrading an env is
# then a deliberate edit to its env.properties, not a side effect of provisioning.
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-7.5.0}"
PROMTAIL_CHART_VERSION="${PROMTAIL_CHART_VERSION:-6.17.1}"
PROMETHEUS_CHART_VERSION="${PROMETHEUS_CHART_VERSION:-29.27.0}"
GRAFANA_CHART_VERSION="${GRAFANA_CHART_VERSION:-10.5.15}"
BLACKBOX_CHART_VERSION="${BLACKBOX_CHART_VERSION:-11.17.2}"
PROMETHEUS_OPERATOR_CRDS_CHART_VERSION="${PROMETHEUS_OPERATOR_CRDS_CHART_VERSION:-9.3.2}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.14.2}"

# Application images, pinned apart from the charts. Both charts are frozen upstream
# (2026): grafana/grafana stopped at 10.5.15 / Grafana 12.3.1, which went out of
# security support on 2026-08-19, and the OSS Loki chart moved to grafana-community.
# Overriding the image keeps the rendered manifests identical except for the image
# (checked with helm template against the live releases). Grafana 12.4 is the last
# 12.x minor and is supported until 2027-05-24; Loki 3.6.x still gets security
# patches. Tag and digest move together; the digest is the multi-arch index.
GRAFANA_IMAGE_TAG="${GRAFANA_IMAGE_TAG:-12.4.13}"
GRAFANA_IMAGE_SHA="${GRAFANA_IMAGE_SHA:-41bbc1b5e04416f81891806076db2a2ff60a5d4da5f78d36a88b033a8c199185}"
LOKI_IMAGE_TAG="${LOKI_IMAGE_TAG:-3.6.19}"
LOKI_IMAGE_DIGEST="${LOKI_IMAGE_DIGEST:-sha256:0f9cbc340cbe33ee498e654075034336962057db072f57b37f253e14d476443a}"
LOKI_CANARY_IMAGE_DIGEST="${LOKI_CANARY_IMAGE_DIGEST:-sha256:43f68b496f2cdf49177dfa1136cc962afbf43f45ed34393ec345dab3701b0e88}"
ALLOY_IMAGE_TAG="${ALLOY_IMAGE_TAG:-v1.21.1}"
ALLOY_IMAGE_DIGEST="${ALLOY_IMAGE_DIGEST:-sha256:4039c971193053a84e53dd9ed3e7d4561c069256b024631cd3498a353ed7ece8}"

# Log shipper. Promtail reached end of life on 2026-03-02; Grafana Alloy replaces it.
# promtail (default) keeps the current DaemonSet. alloy installs the Alloy DaemonSet
# with the Promtail config converted by `alloy convert --source-format=promtail`
# (same labels, same Loki push URL), reads Promtail's positions file so nothing is
# shipped twice, and uninstalls the promtail release. Set per env in env.properties.
LOG_SHIPPER="${LOG_SHIPPER:-promtail}"

# Loki retention. Empty (the default) keeps logs until the volume fills, which is
# what every env did until 2026-10. A duration such as 2160h (90 days) turns on the
# compactor's retention and deletes older chunks. Set per env in env.properties.
LOKI_RETENTION_PERIOD="${LOKI_RETENTION_PERIOD:-}"

# Ingress configuration
INGRESS_CLASS="${INGRESS_CLASS:-traefik}"
CLUSTER_ISSUER="${CLUSTER_ISSUER:-letsencrypt-prod}"

# --- StoreBack read-only Postgres datasource (powers the "UCE - shops & activity" dashboard) ---
# DB + role were renamed uce -> storeback in 2026-07; these default to the post-rename names.
UCE_PG_DATABASE="${UCE_PG_DATABASE:-storeback}"
UCE_PG_RO_ROLE="${UCE_PG_RO_ROLE:-grafana_ro}"
UCE_GRAFANA_PG_SECRET="${UCE_GRAFANA_PG_SECRET:-grafana-uce-pg}"
# Flipped to "true" by ensure_grafana_pg_readonly once role+secret are in place.
UCE_PG_DATASOURCE_READY="false"

# --- Ensure the read-only Postgres role + password secret for the Grafana datasource ---
#
# The "UCE - shops & activity" dashboard reads the app DB directly through a
# SELECT-only role. Three things have to line up, and historically none of them
# were checked, so the dashboard rendered "No data" on cit and had no datasource
# at all on prod:
#
#   1. the `grafana-uce-pg` secret exists in the observability namespace,
#   2. the PG role has that same password and can SELECT in `public`,
#   3. Grafana gets the password as $UCE_GRAFANA_PG_PASSWORD so provisioning can
#      expand it (the datasource YAML holds the variable, never the literal).
#
# Password precedence: explicit UCE_GRAFANA_PG_PASSWORD env > existing secret >
# freshly generated. Generating and then applying it to PG keeps the two in sync
# on a fresh cluster without the operator having to do anything by hand.
#
# Best-effort by design: a cluster without the app DB yet (or without the CNPG
# pod up) should still get Prometheus + Loki + every other dashboard. On failure
# we warn and continue; the datasource is simply omitted.
ensure_grafana_pg_readonly() {
  local ns="${NAMESPACE_OBSERVABILITY}"
  local pg_ns="${NAMESPACE_POSTGRES:-postgres}"
  local pw=""

  if [[ -n "${UCE_GRAFANA_PG_PASSWORD:-}" ]]; then
    pw="${UCE_GRAFANA_PG_PASSWORD}"
  else
    pw="$(kubectl -n "$ns" get secret "$UCE_GRAFANA_PG_SECRET" \
            -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  fi

  if [[ -z "$pw" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      pw="$(openssl rand -base64 32 | tr -d '\n' | tr -d '=/+' | cut -c1-32)"
    else
      pw="$(dd if=/dev/urandom bs=1 count=48 2>/dev/null | base64 | tr -d '\n' | tr -d '=/+' | cut -c1-32)"
    fi
    log "Generated a ${UCE_PG_RO_ROLE} password for this cluster."
  fi

  # Find the CNPG primary. `-rw` is a Service, so exec needs the pod behind it.
  local pg_pod
  pg_pod="$(kubectl -n "$pg_ns" get pod \
              -l cnpg.io/instanceRole=primary \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "$pg_pod" ]]; then
    pg_pod="$(kubectl -n "$pg_ns" get pod \
                -l cnpg.io/cluster=postgres-cluster \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi

  if [[ -z "$pg_pod" ]]; then
    warn "No Postgres pod found in namespace '${pg_ns}' - skipping the Postgres-UCE datasource."
    UCE_PG_DATASOURCE_READY="false"
    return 0
  fi

  # Password goes in on stdin, never in argv - `-v pw=...` would expose it in the
  # pod's process list. Single quotes are doubled for the psql \set literal.
  local pw_sql="${pw//"'"/"''"}"

  if ! kubectl -n "$pg_ns" exec -i "$pg_pod" -c postgres -- \
         psql -U postgres -d "$UCE_PG_DATABASE" -v ON_ERROR_STOP=1 -q \
         -v role="$UCE_PG_RO_ROLE" -v db="$UCE_PG_DATABASE" >/dev/null 2>&1 <<SQL
\set pw '${pw_sql}'
-- CREATE ROLE has no IF NOT EXISTS; \gexec runs the statement only when the
-- SELECT yields a row. A DO block can't be used here because psql does not
-- interpolate :variables inside dollar-quoted strings.
SELECT format('CREATE ROLE %I LOGIN', :'role')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')
\gexec
ALTER ROLE :"role" WITH LOGIN PASSWORD :'pw';
GRANT CONNECT ON DATABASE :"db" TO :"role";
GRANT USAGE ON SCHEMA public TO :"role";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"role";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO :"role";
SQL
  then
    warn "Could not provision the ${UCE_PG_RO_ROLE} role on ${pg_ns}/${pg_pod} (db '${UCE_PG_DATABASE}')."
    warn "Skipping the Postgres-UCE datasource; the shops dashboard will stay empty."
    UCE_PG_DATASOURCE_READY="false"
    return 0
  fi

  kubectl -n "$ns" create secret generic "$UCE_GRAFANA_PG_SECRET" \
    --from-literal=password="$pw" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  UCE_GRAFANA_PG_PASSWORD="$pw"
  UCE_PG_DATASOURCE_READY="true"
  info "✓ ${UCE_PG_RO_ROLE} ready on db '${UCE_PG_DATABASE}'; password stored in secret/${UCE_GRAFANA_PG_SECRET}"
}

# --- Upsert Grafana dashboards from repo (envs/shared/dashboards/*.json) ---
upsert_repo_dashboards() {
  local dashboards_dir="${ENVS_ROOT}/shared/dashboards"
  local namespace="${NAMESPACE_OBSERVABILITY}"

  if [[ ! -d "$dashboards_dir" ]]; then
    info "No shared dashboards directory found (${dashboards_dir}) - skipping dashboard upsert"
    return 0
  fi

  shopt -s nullglob
  local files=("$dashboards_dir"/*.json)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    info "No dashboards found in ${dashboards_dir} (*.json) - skipping dashboard upsert"
    return 0
  fi

  log "Upserting ${#files[@]} Grafana dashboards from ${dashboards_dir} ..."

  for f in "${files[@]}"; do
    if [[ ! -s "$f" ]]; then
      warn "Skipping empty dashboard file: ${f}"
      continue
    fi

    # Basic JSON validation (avoid pushing broken dashboards)
    if ! jq -e . >/dev/null 2>&1 <"$f"; then
      warn "Skipping invalid JSON dashboard: ${f}"
      continue
    fi

    local base cm_name key
    base="$(basename "$f" .json)"
    key="$(basename "$f")"
    cm_name="grafana-dashboard-${base}"
    cm_name="$(printf '%s' "$cm_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-')"
    cm_name="${cm_name%-}"

    # One dashboard per ConfigMap (avoids Kubernetes ConfigMap size limits)
    kubectl -n "$namespace" create configmap "$cm_name" \
      --from-file="${key}=${f}" \
      --dry-run=client -o yaml | \
      yq eval '.metadata.labels.grafana_dashboard = "1"' - | \
      kubectl apply -f - >/dev/null
  done

  info "✓ Shared dashboards upserted (ConfigMaps labeled grafana_dashboard=1)"
}

# --- Align Grafana's stored admin password with the configured one ---
#
# A Grafana whose database predates the password fix above still holds whatever
# password its first run generated, while secret/grafana holds a later one. The
# configured admin is then refused (the UI login, and the API calls of the
# mcp-grafana step). Check the configured admin against the API and, only when it is
# refused, reset the stored password to the configured one with grafana's own CLI:
# the value is expanded inside the pod and never leaves it. Best-effort.
ensure_grafana_admin_login() {
  local ns="${NAMESPACE_OBSERVABILITY}" pod
  if ! pod=$(provision::grafana_pod "$ns"); then
    warn "No running Grafana pod - skipping the admin password check."
    return 0
  fi
  if provision::grafana_api "$ns" GET /api/user >/dev/null 2>&1; then
    info "✓ Grafana accepts the configured admin password"
    return 0
  fi
  warn "Grafana refuses the configured admin password (its database predates secret/grafana's) - resetting it."
  # shellcheck disable=SC2016  # expanded by the pod's shell
  if kubectl -n "$ns" exec "$pod" -c grafana -- sh -c '
       if command -v grafana >/dev/null 2>&1; then set -- grafana cli; else set -- grafana-cli; fi
       "$@" --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
         admin reset-admin-password "$GF_SECURITY_ADMIN_PASSWORD"' >/dev/null 2>&1 &&
     provision::grafana_api "$ns" GET /api/user >/dev/null 2>&1; then
    info "✓ Grafana's stored admin password reset to the one in secret/grafana"
  else
    warn "Could not align Grafana's admin password; the mcp-grafana step will fail until it is."
    warn "  kubectl -n ${ns} exec deploy/grafana -c grafana -- sh -c 'grafana cli admin reset-admin-password \"\$GF_SECURITY_ADMIN_PASSWORD\"'"
  fi
}

# --- Refuse to drop what the live Grafana release has ---
#
# Compares the live release's user values with the values this run rendered and lists
# what would disappear: the Dex SSO block, envFromSecret (the Dex client secret),
# server.root_url, and every datasource by name. Only names and flags are compared,
# never secret values. Exits the script on a regression unless
# ALLOW_GRAFANA_REGRESSION=true. No live release (first install) passes.
grafana_values_guard() {
  local new_file="$1" live_json new_json lost
  live_json=$(helm get values grafana -n "$NAMESPACE_OBSERVABILITY" -o json 2>/dev/null || true)
  if [[ -z "$live_json" || "$live_json" == "null" ]]; then
    return 0
  fi
  new_json=$(yq eval -o=json '.' "$new_file")
  lost=$(jq -rn --argjson live "$live_json" --argjson new "$new_json" '
    def sso: (.["grafana.ini"]["auth.generic_oauth"].enabled // "") | tostring;
    def dsnames: [.datasources["datasources.yaml"].datasources[]?.name];
    [ (if ($live|sso) == "true" and ($new|sso) != "true"
         then "Dex SSO (grafana.ini auth.generic_oauth)" else empty end),
      (if ($live.envFromSecret // "") != "" and ($new.envFromSecret // "") == ""
         then "envFromSecret \($live.envFromSecret)" else empty end),
      (if ($live["grafana.ini"].server.root_url // "") != "" and ($new["grafana.ini"].server.root_url // "") == ""
         then "grafana.ini server.root_url" else empty end),
      (($live|dsnames) - ($new|dsnames) | .[] | "datasource \(.)")
    ] | .[]')
  if [[ -z "$lost" ]]; then
    info "✓ New Grafana values keep the live release's SSO, root_url and datasources"
    return 0
  fi
  if [[ "${ALLOW_GRAFANA_REGRESSION:-false}" == "true" ]]; then
    warn "Grafana upgrade drops (ALLOW_GRAFANA_REGRESSION=true):"
    printf '%s\n' "$lost" | sed 's/^/  - /' >&2
    return 0
  fi
  err "This run would remove from the live Grafana release:"
  printf '%s\n' "$lost" | sed 's/^/  - /' >&2
  err "Usual causes: --skip-sso, the Dex client step failed, or the Postgres-UCE role check failed."
  err "Fix the cause, or set ALLOW_GRAFANA_REGRESSION=true to accept the loss. Nothing was changed in Grafana."
  exit 1
}

# --- Front Grafana with Pomerium ---
#
# Grafana's UI sits behind Pomerium like the other back-office tools (same pattern as
# argocd.sh): an ingress in the sso namespace hands the whole host to pomerium-proxy, and a
# route lets signed-in users through. Grafana's own Dex SSO and GitHub role mapping still
# apply behind it; its password login and basic-auth API are no longer reachable from
# outside. In-cluster callers (provision::grafana_api, mcp-grafana) use the Service and are
# unaffected. The host's path routes (grafana-mcp's /mcp) are kept by pomerium_routes_add.
ensure_grafana_pomerium() {
  log "Fronting https://${GRAFANA_HOST} with Pomerium ..."
  kubectl apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-pomerium
  namespace: ${NAMESPACE_SSO}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    cert-manager.io/common-name: ${GRAFANA_HOST}
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: ${GRAFANA_HOST}
      http:
        paths:
          - backend:
              service:
                name: pomerium-proxy
                port:
                  number: 80
            path: /
            pathType: Prefix
  tls:
    - hosts:
        - ${GRAFANA_HOST}
      secretName: grafana-pomerium-tls
YAML
  if provision::pomerium_routes_add "https://${GRAFANA_HOST}" \
       "http://grafana.${NAMESPACE_OBSERVABILITY}.svc.cluster.local:80" "${NAMESPACE_SSO}" true true true; then
    info "✓ Pomerium route ensured: https://${GRAFANA_HOST} -> grafana"
  else
    warn "Failed to ensure the Pomerium route for https://${GRAFANA_HOST}; add it to envs/<env>/pomerium-routes.yaml and run tools/k3s/apply-pomerium-routes.sh"
  fi
}

# --- Detect Tailscale IP ---
detect_tailscale_ip() {
  local tailscale_ip=""
  
  # Try to get Tailscale IP from the current machine
  if command -v tailscale >/dev/null 2>&1; then
    tailscale_ip=$(tailscale ip -4 2>/dev/null | head -n1 || true)
    if [[ -n "$tailscale_ip" && "$tailscale_ip" =~ ^100\. ]]; then
      echo "$tailscale_ip"
      return 0
    fi
  fi
  
  # Try to get Tailscale IP from kubectl node
  local nodes
  nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  
  for node in $nodes; do
    local node_ips
    node_ips=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
    
    for ip in $node_ips; do
      if [[ "$ip" =~ ^100\. ]]; then
        echo "$ip"
        return 0
      fi
    done
  done
  
  return 1
}

# --- Ensure DNS records ---
ensure_dns_records() {
  if [[ "$SKIP_DNS" == "true" ]]; then
    info "Skipping DNS record creation (--skip-dns)"
    return 0
  fi
  
  if [[ -z "${EXTERNAL_IP:-}" ]]; then
    warn "EXTERNAL_IP not set. Skipping DNS record creation."
    warn "Set EXTERNAL_IP in env.properties or export it before running"
    return 0
  fi
  
  if [[ -z "${GRAFANA_HOST:-}" ]]; then
    warn "GRAFANA_HOST not set. Skipping DNS record creation."
    warn "Set HOSTNAME in env.properties to auto-generate service hosts"
    return 0
  fi

  log "Ensuring DNS record for Grafana ..."
  log "EXTERNAL_IP: ${EXTERNAL_IP}"
  log "GRAFANA_HOST: ${GRAFANA_HOST}"
  
  # Auto-detect Tailscale IP if not set
  if [[ -z "${TAILSCALE_IP:-}" ]]; then
    TAILSCALE_IP=$(detect_tailscale_ip || true)
    if [[ -n "$TAILSCALE_IP" ]]; then
      info "Auto-detected Tailscale IP: $TAILSCALE_IP"
    fi
  fi
  
  # Check for wildcard DNS
  WILDCARD_EXISTS=false
  if [[ -n "${HOSTNAME:-}" ]]; then
    WILDCARD_PATTERN="*.${HOSTNAME}"
    
    if provision::cloudflare_read_token 2>/dev/null; then
      if command -v jq >/dev/null 2>&1; then
        base_domain=$(printf '%s' "$HOSTNAME" | awk -F. '{if (NF>=2){print $(NF-1)"."$NF}else{print $0}}')
        zones_response=$(provision::cloudflare_api GET "/zones?name=${base_domain}" 2>/dev/null || true)
        zone_id=$(printf '%s' "$zones_response" | jq -r '.result[0].id // empty' 2>/dev/null || true)
        
        if [[ -n "$zone_id" && "$zone_id" != "null" ]]; then
          wildcard_check=$(provision::cloudflare_api GET "/zones/${zone_id}/dns_records?type=A&name=${WILDCARD_PATTERN}" 2>/dev/null || true)
          wildcard_id=$(printf '%s' "$wildcard_check" | jq -r '.result[0].id // empty' 2>/dev/null || true)
          
          if [[ -n "$wildcard_id" && "$wildcard_id" != "null" ]]; then
            wildcard_ip=$(printf '%s' "$wildcard_check" | jq -r '.result[0].content // empty' 2>/dev/null || true)
            info "Wildcard DNS record found: ${WILDCARD_PATTERN} -> ${wildcard_ip}"
            WILDCARD_EXISTS=true
          fi
        fi
      fi
    fi
  fi
  
  if [[ "$WILDCARD_EXISTS" == "false" ]]; then
    # Use GRAFANA_IP if set, otherwise use EXTERNAL_IP
    local grafana_ip="${GRAFANA_IP:-$EXTERNAL_IP}"
    
    log "Creating DNS record: $GRAFANA_HOST → $grafana_ip"
    if provision::cloudflare_ensure_dns_record "$GRAFANA_HOST" "$grafana_ip"; then
      info "✓ DNS record created/updated for $GRAFANA_HOST"
    else
      warn "Failed to create DNS record for $GRAFANA_HOST"
      warn "You may need to create it manually in Cloudflare"
    fi
  else
    info "Wildcard DNS exists, skipping individual Grafana DNS record"
  fi
}

# --- Register Dex client for Grafana ---
register_dex_grafana_client() {
  if [[ "$SKIP_SSO" == "true" ]]; then
    info "Skipping Dex client registration (--skip-sso)"
    return 0
  fi
  
  log "Registering Dex client for Grafana..."
  
  # Check if SSO namespace exists
  if ! kubectl get ns "$NAMESPACE_SSO" >/dev/null 2>&1; then
    warn "SSO namespace ($NAMESPACE_SSO) not found. Skipping Dex client registration."
    warn "Run tools/k3s/identity.sh first to provision Dex SSO."
    return 1
  fi
  
  # Register Grafana as a Dex client
  local redirect_uris="https://${GRAFANA_HOST}/login/generic_oauth"
  local dex_client_secret
  
  dex_client_secret=$(provision::dex_register_client "grafana" "Grafana" "$redirect_uris" "$NAMESPACE_SSO") || {
    warn "Failed to register Dex client for Grafana"
    return 1
  }
  
  # Export for use in Grafana configuration
  export DEX_CLIENT_SECRET_GRAFANA="$dex_client_secret"
  
  info "✓ Dex client registered for Grafana"
  info "  Redirect URI: ${redirect_uris}"
  
  return 0
}

# --- Main execution ---
log "Starting observability stack provisioning for environment: ${ENV_NAME}"

# Create namespace
kubectl get ns "$NAMESPACE_OBSERVABILITY" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_OBSERVABILITY"

# Sync dashboards-only mode (no installs/upgrades)
if [[ "$SYNC_DASHBOARDS" == "true" ]]; then
  upsert_repo_dashboards
  if kubectl -n "$NAMESPACE_OBSERVABILITY" get deploy grafana >/dev/null 2>&1; then
    info "Restarting Grafana to pick up dashboard changes..."
    kubectl -n "$NAMESPACE_OBSERVABILITY" rollout restart deploy/grafana >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE_OBSERVABILITY" rollout status deploy/grafana --timeout=300s || true
  else
    warn "Grafana deployment not found in namespace '${NAMESPACE_OBSERVABILITY}' (dashboards synced, but Grafana not restarted)"
  fi
  exit 0
fi

# Add Helm repositories
log "Adding Helm repositories ..."
if ! helm repo list 2>/dev/null | grep -q "^grafana"; then
  helm repo add grafana https://grafana.github.io/helm-charts
fi
if ! helm repo list 2>/dev/null | grep -q "^prometheus-community"; then
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
fi
helm repo update || warn "Some Helm repositories failed to update (non-fatal)"

# Ensure DNS records
ensure_dns_records

# Register Dex client for Grafana SSO
register_dex_grafana_client
# ============================================================================
# Phase 1: Install Loki (Log Aggregation)
# ============================================================================
if [[ "$SKIP_LOKI" != "true" ]]; then
  log "=== Phase 1: Installing Loki (log aggregation) ==="

  loki_values=$(mktemp -t loki-values-XXXX.yaml)
  trap 'rm -f "$loki_values"' EXIT
  
  loki_retention_block=""
  if [[ -n "$LOKI_RETENTION_PERIOD" ]]; then
    loki_retention_block="  compactor:
    retention_enabled: true
    delete_request_store: filesystem
  limits_config:
    retention_period: ${LOKI_RETENTION_PERIOD}"
    info "Loki retention: ${LOKI_RETENTION_PERIOD} (compactor deletes older chunks)"
  fi

  cat > "$loki_values" <<EOF
deploymentMode: SingleBinary

loki:
  image:
    tag: ${LOKI_IMAGE_TAG}
    digest: ${LOKI_IMAGE_DIGEST}
${loki_retention_block}
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
    bucketNames:
      chunks: loki-chunks
      ruler: loki-ruler
      admin: loki-admin
  schemaConfig:
    configs:
      - from: 2024-04-01
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: ${LOKI_STORAGE_SIZE}
    storageClassName: ${LOKI_STORAGE_CLASS}

read:
  replicas: 0

write:
  replicas: 0

backend:
  replicas: 0

lokiCanary:
  image:
    tag: ${LOKI_IMAGE_TAG}
    digest: ${LOKI_CANARY_IMAGE_DIGEST}
EOF

  helm upgrade --install loki grafana/loki \
    --version "$LOKI_CHART_VERSION" \
    --namespace "$NAMESPACE_OBSERVABILITY" \
    --wait \
    --timeout 10m \
    -f "$loki_values"
  
  info "✓ Loki installed successfully"
  info "  Endpoint: http://loki.${NAMESPACE_OBSERVABILITY}.svc.cluster.local:3100"
else
  info "Skipping Loki installation (--skip-loki)"
fi

# ============================================================================
# Phase 2: Install Promtail (Log Shipper)
# ============================================================================
if [[ "$SKIP_PROMTAIL" != "true" && "$LOG_SHIPPER" != "alloy" ]]; then
  log "=== Phase 2: Installing Promtail (log shipper) ==="

  # Going back from Alloy: both DaemonSets would ship every line twice.
  if helm status alloy -n "$NAMESPACE_OBSERVABILITY" >/dev/null 2>&1; then
    err "LOG_SHIPPER=promtail but the alloy release exists in ${NAMESPACE_OBSERVABILITY}; refusing to run both."
    err "  Roll back with: helm uninstall alloy -n ${NAMESPACE_OBSERVABILITY}, then re-run. Promtail resumes from its positions at the cutover, so lines Alloy shipped since then may be sent twice."
    exit 1
  fi

  promtail_values=$(mktemp -t promtail-values-XXXX.yaml)
  trap 'rm -f "$promtail_values"' EXIT
  cat > "$promtail_values" <<EOF
config:
  clients:
    - url: http://loki:3100/loki/api/v1/push
  snippets:
    pipelineStages:
      - cri: {}
      # NOTE: there used to be a \`match { selector: '{app="uce"}' }\` stage here that
      # regex-extracted the shop UUID and promoted it to a \`shop_id\` stream label.
      # It is deliberately gone:
      #
      #   1. The selector was never updated for the 2026-07 uce -> storeback rename,
      #      so it had silently matched nothing for a month and the "UCE - log viewer"
      #      dashboard (which required shop_id=~".+") returned No data for every query.
      #   2. Even fixed, a per-shop *stream* label is the wrong shape for Loki. Stream
      #      labels are the index; one stream per shop per pod per container multiplies
      #      out permanently and never gets reclaimed. Shop count is unbounded upward,
      #      which is exactly the cardinality Loki tells you not to put in labels.
      #
      # Per-shop filtering now happens at query time as a line filter (|= "<uuid>"),
      # the same way the "UCE - runtime fairness" dashboard already extracts level and
      # logger with | regexp. Same UX, no index blow-up.
EOF

  helm upgrade --install promtail grafana/promtail \
    --version "$PROMTAIL_CHART_VERSION" \
    --namespace "$NAMESPACE_OBSERVABILITY" \
    --wait \
    --timeout 10m \
    -f "$promtail_values"

  info "✓ Promtail installed successfully"
  info "  Shipping logs to: http://loki:3100/loki/api/v1/push"
elif [[ "$SKIP_PROMTAIL" != "true" ]]; then
  log "=== Phase 2: Installing Grafana Alloy (log shipper, LOG_SHIPPER=alloy) ==="

  # The pipeline below is `alloy convert --source-format=promtail` (Alloy v1.21.1) of
  # the Promtail config this script deployed (live on prod and hosting, 2026-10-23):
  # same discovery, relabelling (app, instance, component, namespace, job, pod,
  # container, node_name), cri stage and push URL, so every stream keeps its labels and
  # dashboards and LogQL queries are unaffected. legacy_positions_file reads the
  # Promtail positions on the node, so Alloy resumes where Promtail stopped instead of
  # re-shipping every file. Alloy's own positions live under storagePath on a hostPath
  # so they survive pod restarts. Alloy's self-metrics differ from Promtail's; nothing
  # in the alert rules uses Promtail's.
  alloy_config=$(mktemp -t alloy-config-XXXX.alloy)
  alloy_values=$(mktemp -t alloy-values-XXXX.yaml)
  trap 'rm -f "$alloy_config" "$alloy_values"' EXIT
  cat > "$alloy_config" <<'ALLOY'
discovery.kubernetes "kubernetes_pods" {
	role = "pod"

	selectors {
		role  = "pod"
		field = "spec.nodeName=" + coalesce(sys.env("HOSTNAME"), constants.hostname)
	}
}

discovery.relabel "kubernetes_pods" {
	targets = discovery.kubernetes.kubernetes_pods.targets

	rule {
		source_labels = ["__meta_kubernetes_pod_controller_name"]
		regex         = "([0-9a-z-.]+?)(-[0-9a-f]{8,10})?"
		target_label  = "__tmp_controller_name"
	}

	rule {
		source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name", "__meta_kubernetes_pod_label_app", "__tmp_controller_name", "__meta_kubernetes_pod_name"]
		regex         = "^;*([^;]+)(;.*)?$"
		target_label  = "app"
	}

	rule {
		source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_instance", "__meta_kubernetes_pod_label_instance"]
		regex         = "^;*([^;]+)(;.*)?$"
		target_label  = "instance"
	}

	rule {
		source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_component", "__meta_kubernetes_pod_label_component"]
		regex         = "^;*([^;]+)(;.*)?$"
		target_label  = "component"
	}

	rule {
		source_labels = ["__meta_kubernetes_pod_node_name"]
		target_label  = "node_name"
	}

	rule {
		source_labels = ["__meta_kubernetes_namespace"]
		target_label  = "namespace"
	}

	rule {
		source_labels = ["namespace", "app"]
		separator     = "/"
		target_label  = "job"
	}

	rule {
		source_labels = ["__meta_kubernetes_pod_name"]
		target_label  = "pod"
	}

	rule {
		source_labels = ["__meta_kubernetes_pod_container_name"]
		target_label  = "container"
	}

	rule {
		source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
		separator     = "/"
		target_label  = "__path__"
		replacement   = "/var/log/pods/*$1/*.log"
	}

	rule {
		source_labels = ["__meta_kubernetes_pod_annotationpresent_kubernetes_io_config_hash", "__meta_kubernetes_pod_annotation_kubernetes_io_config_hash", "__meta_kubernetes_pod_container_name"]
		separator     = "/"
		regex         = "true/(.*)"
		target_label  = "__path__"
		replacement   = "/var/log/pods/*$1/*.log"
	}
}

loki.source.file "kubernetes_pods" {
	targets    = discovery.relabel.kubernetes_pods.output
	forward_to = [loki.process.kubernetes_pods.receiver]

	file_match {
		enabled = true
	}
	legacy_positions_file = "/run/promtail/positions.yaml"
}

loki.process "kubernetes_pods" {
	forward_to = [loki.write.default.receiver]

	stage.cri { }
}

loki.write "default" {
	endpoint {
		url = "http://loki:3100/loki/api/v1/push"
	}
}
ALLOY

  cat > "$alloy_values" <<EOF
image:
  tag: ${ALLOY_IMAGE_TAG}
  digest: ${ALLOY_IMAGE_DIGEST}
crds:
  create: false        # monitoring CRDs come from prometheus-operator-crds (Phase 3a)
controller:
  type: daemonset
  volumes:
    extra:
      - name: promtail-positions
        hostPath:
          path: /run/promtail
          type: DirectoryOrCreate
      - name: alloy-data
        hostPath:
          path: /var/lib/alloy
          type: DirectoryOrCreate
alloy:
  storagePath: /var/lib/alloy/data
  # Runs as root like Promtail did: pod logs are root:root 0640. Same hardening as the
  # promtail chart's container, minus readOnlyRootFilesystem.
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop: [ALL]
  mounts:
    varlog: true
    extra:
      - name: promtail-positions
        mountPath: /run/promtail
        readOnly: true
      - name: alloy-data
        mountPath: /var/lib/alloy
EOF
  ALLOY_CFG="$alloy_config" yq -i '.alloy.configMap.content = load_str(strenv(ALLOY_CFG))' "$alloy_values"

  # Promtail first, so the two never ship the same lines; Promtail writes its positions
  # on shutdown and Alloy picks them up. The gap delays logs, it does not lose them.
  if helm status promtail -n "$NAMESPACE_OBSERVABILITY" >/dev/null 2>&1; then
    log "Uninstalling the promtail release (replaced by Alloy) ..."
    helm uninstall promtail -n "$NAMESPACE_OBSERVABILITY" --wait --timeout 5m
  fi

  helm upgrade --install alloy grafana/alloy \
    --version "$ALLOY_CHART_VERSION" \
    --namespace "$NAMESPACE_OBSERVABILITY" \
    --wait \
    --timeout 10m \
    -f "$alloy_values"

  info "✓ Grafana Alloy installed successfully (DaemonSet alloy)"
  info "  Shipping logs to: http://loki:3100/loki/api/v1/push"
  info "  Roll back: helm uninstall alloy -n ${NAMESPACE_OBSERVABILITY}; re-run with LOG_SHIPPER=promtail"
else
  info "Skipping log shipper installation (--skip-promtail)"
fi

# ============================================================================
# Phase 3a: Install Prometheus Operator CRDs (for ServiceMonitor support)
# ============================================================================
if [[ "$SKIP_PROMETHEUS" != "true" && "$RULES_ONLY" != "true" ]]; then
  log "=== Phase 3a: Installing Prometheus Operator CRDs (ServiceMonitor support) ==="
  
  # Install Prometheus Operator CRDs to enable ServiceMonitor resources
  # This allows applications to define ServiceMonitors even if we use standalone Prometheus
  # Note: We install CRDs separately because we use standalone Prometheus, not Prometheus Operator
  if ! kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    log "Installing Prometheus Operator CRDs..."
    
    # Try method 1: Install via prometheus-operator Helm chart (CRDs only, no operator)
    if helm upgrade --install prometheus-operator-crds prometheus-community/prometheus-operator \
      --version "$PROMETHEUS_OPERATOR_CRDS_CHART_VERSION" \
      --namespace "$NAMESPACE_OBSERVABILITY" \
      --set prometheusOperator.enabled=false \
      --set prometheusOperator.createCustomResource=false \
      --set prometheusOperator.manageCrds=true \
      --wait \
      --timeout 5m 2>/dev/null; then
      info "✓ CRDs installed via Helm chart"
    else
      # Method 2: Install CRDs directly from GitHub
      log "Helm method failed, trying direct CRD installation from GitHub..."
      CRD_VERSION="0.68.0"
      CRD_BASE_URL="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v${CRD_VERSION}/example/prometheus-operator-crd"
      
      # Function to get filename component from CRD name
      get_crd_file_component() {
        case "$1" in
          servicemonitors.monitoring.coreos.com) echo "servicemonitors" ;;
          podmonitors.monitoring.coreos.com) echo "podmonitors" ;;
          prometheuses.monitoring.coreos.com) echo "prometheuses" ;;
          prometheusrules.monitoring.coreos.com) echo "prometheusrules" ;;
          alertmanagers.monitoring.coreos.com) echo "alertmanagers" ;;
          probes.monitoring.coreos.com) echo "probes" ;;
          scrapes.monitoring.coreos.com) echo "scrapes" ;;
          *) echo "" ;;
        esac
      }
      
      # List of CRDs to install
      CRD_NAMES=(
        "servicemonitors.monitoring.coreos.com"
        "podmonitors.monitoring.coreos.com"
        "prometheuses.monitoring.coreos.com"
        "prometheusrules.monitoring.coreos.com"
        "alertmanagers.monitoring.coreos.com"
        "probes.monitoring.coreos.com"
        "scrapes.monitoring.coreos.com"
      )
      
      installed_count=0
      for crd_name in "${CRD_NAMES[@]}"; do
        if ! kubectl get crd "$crd_name" >/dev/null 2>&1; then
          file_component=$(get_crd_file_component "$crd_name")
          if [[ -z "$file_component" ]]; then
            warn "  Unknown CRD: $crd_name, skipping"
            continue
          fi
          log "Installing CRD: $crd_name"
          if kubectl apply -f "${CRD_BASE_URL}/monitoring.coreos.com_${file_component}.yaml" 2>/dev/null; then
            info "  ✓ Installed $crd_name"
            installed_count=$((installed_count + 1))
          else
            warn "  ✗ Failed to install $crd_name from GitHub"
            warn "    URL: ${CRD_BASE_URL}/monitoring.coreos.com_${file_component}.yaml"
          fi
        else
          info "  CRD $crd_name already exists"
          installed_count=$((installed_count + 1))
        fi
      done
      
      if [[ $installed_count -gt 0 ]]; then
        info "✓ Installed $installed_count CRD(s) from GitHub"
      fi
    fi
    
    # Verify ServiceMonitor CRD is installed (most critical one)
    if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
      info "✓ Prometheus Operator CRDs installed successfully"
      info "  ServiceMonitor CRD is now available for applications"
    else
      err "✗ ServiceMonitor CRD installation failed"
      err "  Applications using ServiceMonitors will encounter errors"
      err "  You may need to install CRDs manually:"
      err "    kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml"
    fi
  else
    info "✓ Prometheus Operator CRDs already installed"
  fi
fi

# ============================================================================
# Phase 3: Install Prometheus (Metrics Collection)
# ============================================================================
if [[ "$SKIP_PROMETHEUS" != "true" ]]; then
  log "=== Phase 3: Installing Prometheus (metrics collection) ==="
  
  # Determine PostgreSQL namespace (default to 'postgres')
  NAMESPACE_POSTGRES="${NAMESPACE_POSTGRES:-postgres}"
  # kafka-journal stack namespaces (redpanda.sh / scylla.sh)
  NAMESPACE_REDPANDA="${NAMESPACE_REDPANDA:-redpanda}"
  NAMESPACE_SCYLLA="${NAMESPACE_SCYLLA:-scylla}"
  # MySQL stack namespace (mysql.sh deploys the mysql-exporter Service there)
  NAMESPACE_MYSQL="${NAMESPACE_MYSQL:-mysql}"
  # Platform namespaces for the platform-workloads alerts: a Deployment or
  # StatefulSet here with no ready replica is an outage of the platform (ingress,
  # DNS, certificates, identity, registry, GitOps, the Postgres operator), so it
  # pages at p1. App namespaces get the generic p2 rules in infra-workloads only.
  PLATFORM_NAMESPACES_RE="kube-system|${NAMESPACE_CERT_MANAGER:-cert-manager}|${NAMESPACE_SSO}|${NAMESPACE_HARBOR:-harbor}|${NAMESPACE_ARGOCD}|${CNPG_NAMESPACE:-cnpg-system}"
  # Traefik names a Kubernetes backend '<namespace>-<service>-<port>@kubernetes';
  # this selects the platform UIs and APIs behind the edge (Pomerium, Dex, Harbor,
  # Argo CD, Nexus, Grafana) for PlatformServiceErrorsHigh.
  PLATFORM_TRAEFIK_SERVICES_RE="(${NAMESPACE_SSO}|${NAMESPACE_HARBOR:-harbor}|${NAMESPACE_ARGOCD}|${NAMESPACE_NEXUS:-nexus}|${NAMESPACE_OBSERVABILITY})-.*@kubernetes"

  # Dead-man's switch (see ALERTMANAGER_DEADMAN_URL above). The Secret must exist
  # before the chart mounts it, so this runs ahead of the values file.
  DEADMAN_ENABLED=false
  if [[ -n "$ALERTMANAGER_DEADMAN_URL" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      info "Dry run: would write ALERTMANAGER_DEADMAN_URL into Secret ${NAMESPACE_OBSERVABILITY}/alertmanager-deadman"
    else
      info "Writing ALERTMANAGER_DEADMAN_URL into Secret ${NAMESPACE_OBSERVABILITY}/alertmanager-deadman"
      kubectl -n "$NAMESPACE_OBSERVABILITY" create secret generic alertmanager-deadman \
        --from-literal=url="$ALERTMANAGER_DEADMAN_URL" --dry-run=client -o yaml \
        | kubectl apply -f - >/dev/null
    fi
    DEADMAN_ENABLED=true
  elif kubectl -n "$NAMESPACE_OBSERVABILITY" get secret alertmanager-deadman >/dev/null 2>&1; then
    DEADMAN_ENABLED=true
  fi
  if [[ "$DEADMAN_ENABLED" == "true" ]]; then
    info "Dead-man's switch on: Watchdog heartbeats go to the URL in Secret alertmanager-deadman"
    WATCHDOG_RECEIVER="deadman"
    DEADMAN_SECRET_MOUNT="    - name: deadman-url
      mountPath: /etc/alertmanager/deadman
      secretName: alertmanager-deadman
      readOnly: true"
    DEADMAN_RECEIVER_BLOCK="      - name: deadman
        webhook_configs:
          - url_file: /etc/alertmanager/deadman/url
            send_resolved: false"
  else
    info "No dead-man's switch configured (Secret alertmanager-deadman absent); Watchdog goes to a null receiver"
    WATCHDOG_RECEIVER="watchdog-null"
    DEADMAN_SECRET_MOUNT=""
    DEADMAN_RECEIVER_BLOCK=""
  fi

  # Create Prometheus values with PostgreSQL exporter scrape config
  prometheus_values=$(mktemp -t prometheus-values-XXXX.yaml)
  trap 'rm -f "$prometheus_values"' EXIT

  # Blackbox scrape job, built from PROBE_TARGETS (empty string when not configured).
  # Prometheus talks to the exporter, not to the site: the target travels as a query
  # param and __address__ is rewritten to the exporter's service.
  BLACKBOX_SCRAPE_JOB=""
  if [[ -n "$PROBE_TARGETS" ]]; then
    probe_target_lines=""
    for probe_url in $PROBE_TARGETS; do
      probe_target_lines+="          - ${probe_url}"$'\n'
    done
    BLACKBOX_SCRAPE_JOB="  - job_name: 'blackbox-http'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
${probe_target_lines%$'\n'}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: prometheus-blackbox-exporter.${NAMESPACE_OBSERVABILITY}.svc.cluster.local:9115"
  fi

  # Uncached POST probes (see PROBE_TARGETS_POST above). Separate job so the module
  # differs; scrape_timeout must exceed the module's 10s so a hung backend registers
  # as a failed probe rather than a cancelled scrape.
  BLACKBOX_SCRAPE_JOB_POST=""
  if [[ -n "$PROBE_TARGETS_POST" ]]; then
    probe_post_target_lines=""
    for probe_url in $PROBE_TARGETS_POST; do
      probe_post_target_lines+="          - ${probe_url}"$'\n'
    done
    BLACKBOX_SCRAPE_JOB_POST="  - job_name: 'blackbox-http-post'
    metrics_path: /probe
    scrape_timeout: 15s
    params:
      module: [http_2xx_post]
    static_configs:
      - targets:
${probe_post_target_lines%$'\n'}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: prometheus-blackbox-exporter.${NAMESPACE_OBSERVABILITY}.svc.cluster.local:9115"
  fi
  
  cat > "$prometheus_values" <<EOF
server:
  # Stamp every alert with the env it came from. When several envs share one
  # Telegram bot and chat, and the notification templates carry no env, an alert
  # from one env is indistinguishable from another's. Alertmanager attaches this
  # to every alert, so it is available to the templates below as
  # .CommonLabels.env.
  global:
    external_labels:
      env: ${ENV_NAME}
  persistentVolume:
    enabled: true
    size: ${PROMETHEUS_STORAGE_SIZE}
    storageClass: ${PROMETHEUS_STORAGE_CLASS}

# Additional scrape configs for PostgreSQL exporter
extraScrapeConfigs: |
${BLACKBOX_SCRAPE_JOB}
${BLACKBOX_SCRAPE_JOB_POST}
  - job_name: 'postgres-exporter'
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - ${NAMESPACE_POSTGRES}
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: postgres-exporter
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: metrics
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_service_name]
        target_label: service
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
  # Redpanda broker metrics (kafka-journal stack). Discovers the plain
  # redpanda-metrics Service created by tools/k3s/redpanda.sh; the admin API
  # serves Prometheus metrics on /public_metrics (not /metrics).
  - job_name: 'redpanda'
    metrics_path: /public_metrics
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - ${NAMESPACE_REDPANDA}
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: redpanda-metrics
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: metrics
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_service_name]
        target_label: service
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
  # ScyllaDB native Prometheus metrics (kafka-journal stack). Discovers the
  # scylla-metrics Service created by tools/k3s/scylla.sh (:9180 /metrics).
  - job_name: 'scylla'
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - ${NAMESPACE_SCYLLA}
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: scylla-metrics
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: metrics
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_service_name]
        target_label: service
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
  # mysqld-exporter deployed by tools/k3s/mysql.sh (Service mysql-exporter, port
  # 'metrics' :9104). The Service carries no prometheus.io/scrape annotation, so the
  # chart's kubernetes-service-endpoints job skips it; without this job MySQL is
  # unmonitored. Inert in envs without the MySQL stack.
  - job_name: 'mysql-exporter'
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - ${NAMESPACE_MYSQL}
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: mysql-exporter
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: metrics
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_service_name]
        target_label: service
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
  # Alertmanager's own metrics (notification failures, config reloads). The chart
  # does not scrape it, so a Telegram outage or a rejected message was invisible.
  # Matches the regular Service only; the -headless one fronts the same pod.
  - job_name: 'alertmanager'
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - ${NAMESPACE_OBSERVABILITY}
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_name]
        action: keep
        regex: alertmanager
      - source_labels: [__meta_kubernetes_service_name]
        action: drop
        regex: .*-headless
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: http
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
  # CloudNativePG instance metrics (cnpg_*: collector up, replication lag, WAL
  # archiver, backups, connections). The operator would create a PodMonitor, which
  # the plain prometheus chart cannot read, so this is the pod-role equivalent: every
  # instance pod in every namespace (label cnpg.io/podRole=instance), port 'metrics'
  # (:9187). Feeds the infra-cnpg alert group.
  - job_name: 'cnpg'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_cnpg_io_podRole]
        action: keep
        regex: instance
      - source_labels: [__meta_kubernetes_pod_container_port_name]
        action: keep
        regex: metrics
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_cnpg_io_cluster]
        target_label: cluster
      - source_labels: [__meta_kubernetes_pod_label_cnpg_io_instanceRole]
        target_label: role
  # Argo CD component metrics (argocd_app_info, argocd_app_sync_total). The install
  # carries no metrics Services or scrape annotations, so scrape the pods' 'metrics'
  # container ports: application-controller :8082, server :8083, repo-server :8084,
  # applicationset :8080, notifications :9001. Feeds the platform-argocd group.
  - job_name: 'argocd'
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names:
            - ${NAMESPACE_ARGOCD}
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_container_port_name]
        action: keep
        regex: metrics
      - source_labels: [__meta_kubernetes_pod_phase]
        action: drop
        regex: Succeeded|Failed
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
        target_label: component
  # Dex telemetry (Service dex, port 'telemetry' :5558): http_requests_total by
  # handler and code. Feeds the platform-identity group.
  - job_name: 'dex'
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - ${NAMESPACE_SSO}
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: dex
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: telemetry
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod

alertmanager:
  enabled: true
  persistentVolume:
    enabled: true
    size: ${ALERTMANAGER_STORAGE_SIZE}
    storageClass: ${ALERTMANAGER_STORAGE_CLASS}
  configmapReload:
    enabled: true
  ingress:
    enabled: false   # routed via Pomerium, see envs/<env>/apps/observability/alertmanager-ingress.yaml
  extraSecretMounts:
    - name: resend-key
      mountPath: /etc/alertmanager/resend-key
      secretName: resend-api-key
      readOnly: true
    - name: telegram-creds
      mountPath: /etc/alertmanager/telegram
      secretName: alertmanager-telegram
      readOnly: true
${DEADMAN_SECRET_MOUNT}
  config:
    global:
      smtp_smarthost: ${ALERTMANAGER_SMTP_HOST}
      smtp_from: ${ALERTMANAGER_FROM_EMAIL}
      smtp_auth_username: resend
      smtp_auth_password_file: /etc/alertmanager/resend-key/api_key
      smtp_require_tls: true
    route:
      receiver: ops-email
      group_by: [alertname, severity, app]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      routes:
        # The always-firing Watchdog (infra-alerting group) must never reach a human
        # channel: it goes to the dead-man heartbeat when one is configured, else to
        # a null receiver. First route, no continue.
        - matchers: [alertname="Watchdog"]
          receiver: ${WATCHDOG_RECEIVER}
          group_wait: 0s
          group_interval: 1m
          repeat_interval: 1m
        - matchers: [severity="p1"]
          receiver: ops-email
          group_wait: 0s
          repeat_interval: 1h
          continue: true
        - matchers: [severity="p1"]
          receiver: ops-telegram
          group_wait: 0s
          repeat_interval: 1h
        - matchers: [severity="p2"]
          receiver: ops-email
          continue: true
        - matchers: [severity="p2"]
          receiver: ops-telegram
        # p3 gets a second channel too. Email can 550 silently (e.g. an SMTP
        # provider key not authorised for the sender domain), and if p3 has no
        # other path a low-severity alert can go unseen for a month. The
        # telegram leg repeats daily rather than 4-hourly, keeping the
        # low-severity tier quiet in the ops chat without leaving it single-homed.
        - matchers: [severity="p3"]
          receiver: ops-email
          continue: true
        - matchers: [severity="p3"]
          receiver: ops-telegram
          repeat_interval: 24h
    receivers:
      - name: ops-email
        email_configs:
          - to: ${ALERTMANAGER_NOTIFY_EMAIL}
            send_resolved: true
            headers:
              Subject: "[{{ .CommonLabels.severity | toUpper }}] [{{ .CommonLabels.env }}] {{ .CommonLabels.alertname }} ({{ .Status | toUpper }})"
      - name: ops-telegram
        telegram_configs:
          - bot_token_file: /etc/alertmanager/telegram/bot_token
            chat_id_file: /etc/alertmanager/telegram/chat_id
            parse_mode: HTML
            send_resolved: true
            message: |
              <b>[{{ .CommonLabels.severity | toUpper }}] [{{ .CommonLabels.env }}] {{ .CommonLabels.alertname }}</b>
              status: {{ .Status }}
              {{ range .Alerts }}{{ .Annotations.summary }}
              {{ if .Annotations.runbook }}runbook: {{ .Annotations.runbook }}{{ end }}
              {{ end }}
      - name: watchdog-null
${DEADMAN_RECEIVER_BLOCK}
    inhibit_rules:
      - source_matchers: [severity="p1"]
        target_matchers: [severity=~"p2|p3"]
        equal: [alertname, app]

# Infra alert rules baked into the chart values. App/env-specific groups live in
# envs/shared/alerts/*.yml and envs/<env>/alerts/*.yml (fragments with a top-level
# 'groups:' list) and are merged in after this file is generated.
serverFiles:
  alerting_rules.yml:
    groups:
      # Infra disk-space watchdog. The standalone Prometheus chart ships no default
      # node/PV rules, so this fills the gap. PVCs use the local-path provisioner,
      # which does NOT enforce the requested size — Postgres data (and Harbor, Nexus,
      # Loki, Prometheus) all live under /var/lib/rancher/k3s/storage and will grow
      # until the host volume backing that path fills, at which point writes fail hard.
      # node-exporter / kube-state-metrics are enabled, so these metrics already exist.
      - name: infra-disk
        interval: 1m
        rules:
          - alert: NodeFilesystemSpaceLow
            expr: |
              node_filesystem_avail_bytes{fstype!="",mountpoint!=""}
                / node_filesystem_size_bytes{fstype!="",mountpoint!=""} * 100 < 15
              and node_filesystem_readonly{fstype!="",mountpoint!=""} == 0
            for: 30m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Disk {{ \$labels.mountpoint }} on {{ \$labels.instance }} below 15% free"
              description: |
                {{ \$labels.device }} mounted at {{ \$labels.mountpoint }} on {{ \$labels.instance }}
                is {{ \$value | printf "%.1f" }}% free. local-path PVCs (Postgres data, Harbor,
                Nexus, Loki, Prometheus) share this disk and ignore their requested size limits —
                extend the LVM volume or clean up before it runs out.
          - alert: NodeFilesystemSpaceCritical
            expr: |
              node_filesystem_avail_bytes{fstype!="",mountpoint!=""}
                / node_filesystem_size_bytes{fstype!="",mountpoint!=""} * 100 < 7
              and node_filesystem_readonly{fstype!="",mountpoint!=""} == 0
            for: 10m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "Disk {{ \$labels.mountpoint }} on {{ \$labels.instance }} critically low (<7% free)"
              description: |
                {{ \$labels.device }} at {{ \$labels.mountpoint }} on {{ \$labels.instance }} has only
                {{ \$value | printf "%.1f" }}% free. Postgres / Harbor / Nexus writes will fail when
                this hits zero — extend the LVM volume or free space now.
          - alert: NodeFilesystemFillingUp
            expr: |
              node_filesystem_avail_bytes{fstype!="",mountpoint!=""}
                / node_filesystem_size_bytes{fstype!="",mountpoint!=""} * 100 < 30
              and predict_linear(node_filesystem_avail_bytes{fstype!="",mountpoint!=""}[6h], 24*60*60) < 0
              and node_filesystem_readonly{fstype!="",mountpoint!=""} == 0
            for: 1h
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Disk {{ \$labels.mountpoint }} on {{ \$labels.instance }} predicted to fill within 24h"
              description: |
                At the current 6h trend, free space on {{ \$labels.device }} ({{ \$labels.mountpoint }}
                on {{ \$labels.instance }}) reaches zero within a day. Plan a cleanup or LVM extend.
          - alert: NodeFilesystemInodesLow
            expr: |
              node_filesystem_files_free{fstype!="",mountpoint!=""}
                / node_filesystem_files{fstype!="",mountpoint!=""} * 100 < 10
              and node_filesystem_readonly{fstype!="",mountpoint!=""} == 0
            for: 30m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Disk {{ \$labels.mountpoint }} on {{ \$labels.instance }} low on inodes (<10% free)"
          # pg_database_size_bytes IS exported. It can look absent when
          # postgres-exporter is failing to authenticate (pg_up=0), which
          # suppresses every pg_* series — see the postgres-monitoring group in
          # envs/shared/alerts/postgres-exporter.yml. NodeFilesystemSpaceLow on vg0-data
          # remains the backstop for the underlying volume.
          - alert: PostgresDatabaseSizeHigh
            expr: pg_database_size_bytes{datname!~"${POSTGRES_SIZE_ALERT_EXCLUDE}"} > 40 * 1024 * 1024 * 1024
            for: 1h
            labels: { severity: p3, app: infra }
            annotations:
              summary: "Postgres database {{ \$labels.datname }} over 40 GiB"
              description: |
                {{ \$labels.datname }} is {{ \$value | humanize1024 }}B — past the 50Gi PVC nominal
                size, which local-path does not enforce. Watch NodeFilesystemSpaceLow and review
                retention / run a cleanup.

      # Pod-health watchdog. Catches the failure mode where a needrestart-triggered
      # k3s restart leaves pods running with stale bind mounts (Loki, Harbor redis,
      # etc. drift to NotReady but the pod is still "Running" from k8s' POV).
      # CrashLoopBackOff and ImagePullBackOff are covered by the same expression.
      # Filters out Succeeded/Failed pods so completed Jobs and CronJob runs don't fire.
      - name: infra-pods
        interval: 1m
        rules:
          - alert: PodNotReady
            expr: |
              kube_pod_status_ready{condition="false"} == 1
              and on (namespace, pod)
              kube_pod_status_phase{phase=~"Pending|Running|Unknown"} == 1
            for: 20m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Pod {{ \$labels.namespace }}/{{ \$labels.pod }} not Ready for >20m"
              description: |
                {{ \$labels.namespace }}/{{ \$labels.pod }} has been not Ready for at least
                20 minutes. Common causes: stale bind mount after a k3s restart
                (\`kubectl rollout restart\` usually fixes), CrashLoopBackOff, image pull
                failure, or scheduling pressure.
          - alert: PodContainerRestarting
            expr: |
              increase(kube_pod_container_status_restarts_total[1h]) > 5
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Container {{ \$labels.namespace }}/{{ \$labels.pod }}/{{ \$labels.container }} restarting frequently"
              description: |
                {{ \$labels.container }} in {{ \$labels.namespace }}/{{ \$labels.pod }} has restarted
                more than 5 times in the last hour. Check logs / previous-container logs.

      # NAS offsite-backup watchdog. The 06:00/06:15 rdiff crons on each node fail
      # silently (no MTA on the hosts) — a sync broken by something as small as a
      # missing pubkey on the backup host can go unnoticed for weeks. Every
      # successful sync stamps nas_backup_last_success_timestamp_seconds via
      # /usr/local/bin/nas-backup-stamp (tools/backup.sh), scraped through the
      # node-exporter textfile collector configured above.
      - name: infra-backup
        interval: 5m
        rules:
          - alert: NasBackupStale
            expr: |
              time() - nas_backup_last_success_timestamp_seconds > 26 * 3600
            for: 30m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "NAS backup repo {{ \$labels.repo }} stale for >26h"
              description: |
                The rdiff-backup sync for repo {{ \$labels.repo }} has not succeeded
                for over 26 hours (schedule is daily 06:00 users / 06:15 k3s-storage).
                Check the root crontab on the node, the backup-user key authorization
                on the backup host, and VPN connectivity:
                tools/backup.sh <env> --show-status
          - alert: NasBackupMetricMissing
            expr: |
              absent(nas_backup_last_success_timestamp_seconds)
            for: 1h
            labels: { severity: p2, app: infra }
            annotations:
              summary: "NAS backup stamp metrics absent"
              description: |
                No nas_backup_last_success_timestamp_seconds series is being scraped.
                Either the node-exporter textfile collector lost its config, the stamp
                files under /var/lib/node_exporter/textfile were removed, or the crontab
                no longer calls /usr/local/bin/nas-backup-stamp (tools/backup.sh).

      # Hardware watchdog: software RAID, NVMe controllers, filesystems remounted
      # read-only, ECC memory, temperatures. All from node-exporter collectors that
      # are on by default (mdadm, nvme, filesystem, edac, hwmon); no extra daemon.
      # mdadm on the hosts has no mail transport, so a dead RAID member is otherwise
      # silent: a node can run on a single disk for weeks without anyone noticing.
      # node_md_state also reports "check", "resync" and "recovering" -- the monthly
      # checkarray scrub and a rebuild after a disk swap -- which are normal; only
      # "inactive" means the array is down. Loss of redundancy is node_md_degraded.
      # SMART wear and media-error counters need smartctl (a textfile-collector
      # script); not wired yet.
      - name: infra-hardware
        interval: 1m
        rules:
          - alert: MdRaidDegraded
            expr: node_md_degraded > 0
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "RAID {{ \$labels.device }} on {{ \$labels.instance }} degraded ({{ \$value }} disk(s) missing)"
              description: |
                Software RAID {{ \$labels.device }} on {{ \$labels.instance }} has lost redundancy:
                the next disk failure loses the data on it. Check \`cat /proc/mdstat\` and
                \`mdadm --detail /dev/{{ \$labels.device }}\` on the node, open a disk-replacement
                ticket with the hosting provider, and re-add the new disk with mdadm.
                Silence this in Alertmanager (with an expiry) while the swap is scheduled.
          - alert: MdRaidDiskFailed
            expr: node_md_disks{state="failed"} > 0
            for: 5m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "RAID {{ \$labels.device }} on {{ \$labels.instance }} has {{ \$value }} failed member(s)"
              description: |
                mdadm marked a member of {{ \$labels.device }} on {{ \$labels.instance }} as faulty.
                If MdRaidDegraded is not firing a spare took over; replace the failed disk and
                \`mdadm --remove\` the faulty member either way.
          - alert: MdRaidInactive
            expr: node_md_state{state="inactive"} == 1
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "RAID {{ \$labels.device }} on {{ \$labels.instance }} is inactive"
              description: |
                Software RAID {{ \$labels.device }} on {{ \$labels.instance }} is not running.
                Anything on it (LVM volumes, /boot) is unavailable. Check /proc/mdstat.
          - alert: MdRaidRebuildStuck
            expr: node_md_state{state=~"recovering|resync"} == 1
            for: 24h
            labels: { severity: p3, app: infra }
            annotations:
              summary: "RAID {{ \$labels.device }} on {{ \$labels.instance }} in {{ \$labels.state }} for over 24h"
              description: |
                A rebuild or resync of {{ \$labels.device }} normally finishes within hours.
                Check /proc/mdstat for progress and the kernel log for I/O errors on the
                remaining member.
          - alert: NvmeControllerNotLive
            expr: node_nvme_info{state!="live"} == 1
            for: 10m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "NVMe {{ \$labels.device }} ({{ \$labels.model }}) on {{ \$labels.instance }} is {{ \$labels.state }}"
              description: |
                The kernel reports NVMe controller {{ \$labels.device }} (serial {{ \$labels.serial }})
                as {{ \$labels.state }}. A dead controller has dropped out of every RAID array it
                was in. Give the serial to the hosting provider when requesting the swap.
          - alert: NodeFilesystemReadOnly
            expr: |
              node_filesystem_readonly{fstype=~"ext[234]|xfs|btrfs",mountpoint!~"/var/lib/kubelet/.*|/run/.*|/snap/.*"} == 1
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "{{ \$labels.mountpoint }} on {{ \$labels.instance }} is read-only"
              description: |
                {{ \$labels.device }} at {{ \$labels.mountpoint }} on {{ \$labels.instance }} is mounted
                read-only. ext4 remounts itself read-only on I/O errors (errors=remount-ro), so this
                usually means the disk underneath is failing. Every write to it fails until fixed.
          - alert: NodeMemoryUncorrectableErrors
            expr: increase(node_edac_uncorrectable_errors_total[1h]) > 0
            for: 0m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Uncorrectable ECC memory errors on {{ \$labels.instance }}"
              description: |
                EDAC controller {{ \$labels.controller }} on {{ \$labels.instance }} logged
                uncorrectable memory errors in the last hour. Data may have been corrupted; ask
                the hosting provider for a memory check.
          - alert: NodeMemoryCorrectableErrorsHigh
            expr: increase(node_edac_correctable_errors_total[24h]) > 10
            for: 0m
            labels: { severity: p3, app: infra }
            annotations:
              summary: "Correctable ECC memory errors rising on {{ \$labels.instance }}"
              description: |
                EDAC controller {{ \$labels.controller }} on {{ \$labels.instance }} corrected more than
                10 memory errors in 24h. A DIMM is degrading; plan a replacement.
          - alert: NodeHardwareTemperatureCritical
            expr: |
              node_hwmon_temp_celsius
                >= on (instance, chip, sensor) (node_hwmon_temp_crit_celsius > 0)
            for: 10m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$labels.chip }}/{{ \$labels.sensor }} on {{ \$labels.instance }} at its critical temperature"
              description: |
                Sensor {{ \$labels.sensor }} of {{ \$labels.chip }} on {{ \$labels.instance }} reads
                {{ \$value }}°C, at or above its critical threshold. NVMe drives throttle and then
                shut down; CPUs throttle.
          - alert: NodeTextfileScrapeError
            expr: node_textfile_scrape_error == 1
            for: 30m
            labels: { severity: p3, app: infra }
            annotations:
              summary: "node-exporter cannot parse a textfile metric on {{ \$labels.instance }}"
              description: |
                A file under /var/lib/node_exporter/textfile is malformed, so the stamp metrics
                it carries (NAS backups, Scylla snapshots) are missing or stale. Check the
                node-exporter log for the file name.
          # Disk latency, per physical device (md/dm layers inherit it). A failing NVMe
          # or SATA disk usually slows down long before mdadm drops it. The IOPS floor
          # keeps an idle disk's single slow flush from counting; on the reference cluster (2026-10)
          # neither threshold held for 30 minutes in 3 days, including an 80 GB restore.
          - alert: NodeDiskReadLatencyHigh
            expr: |
              (
                rate(node_disk_read_time_seconds_total{device=~"nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+|xvd[a-z]+"}[5m])
                  / rate(node_disk_reads_completed_total{device=~"nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+|xvd[a-z]+"}[5m])
              ) > 0.1
              and rate(node_disk_reads_completed_total{device=~"nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+|xvd[a-z]+"}[5m]) > 1
            for: 30m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Disk {{ \$labels.device }} on {{ \$labels.instance }} reads take {{ \$value | humanizeDuration }} on average"
              description: |
                Average read latency on {{ \$labels.device }} has been above 100 ms for 30 minutes
                (healthy NVMe: under 1 ms). Either the disk is failing (check dmesg for I/O
                errors and resets, and smartctl -a /dev/{{ \$labels.device }}) or it is saturated
                (see NodeIOStalled). Compare with the other RAID member: one slow member is a
                disk to replace.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#hardware"
          - alert: NodeDiskWriteLatencyHigh
            expr: |
              (
                rate(node_disk_write_time_seconds_total{device=~"nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+|xvd[a-z]+"}[5m])
                  / rate(node_disk_writes_completed_total{device=~"nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+|xvd[a-z]+"}[5m])
              ) > 0.5
              and rate(node_disk_writes_completed_total{device=~"nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+|xvd[a-z]+"}[5m]) > 1
            for: 30m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Disk {{ \$labels.device }} on {{ \$labels.instance }} writes take {{ \$value | humanizeDuration }} on average"
              description: |
                Average write latency on {{ \$labels.device }} has been above 500 ms for 30 minutes.
                Bulk writes (a restore, a backup) push it up briefly; half an hour is a failing
                or worn-out disk, or sustained saturation. Check dmesg, smartctl and the other
                RAID member; Postgres commits and etcd/kine writes stall behind this.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#hardware"

      # Alerting-pipeline watchdog. Without these, a Telegram outage, a message
      # Telegram rejects, or a dead Alertmanager looks exactly like "nothing firing".
      # Watchdog always fires; Alertmanager routes it to the dead-man heartbeat (see
      # ALERTMANAGER_DEADMAN_URL) or to a null receiver. Only that external heartbeat
      # can report AlertmanagerDown or a dead node: an alert about the pipeline that
      # cannot deliver alerts is visible in the Alertmanager and Grafana UIs only.
      - name: infra-alerting
        interval: 1m
        rules:
          - alert: Watchdog
            expr: vector(1)
            labels: { severity: none, app: infra }
            annotations:
              summary: "Always firing: proves Prometheus -> Alertmanager -> heartbeat works"
              description: |
                This alert is meant to fire all the time. Alertmanager forwards it to the
                dead-man heartbeat URL, and the external service pages when it stops arriving.
          - alert: AlertmanagerDown
            expr: up{job="alertmanager"} == 0
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "Prometheus cannot scrape Alertmanager"
              description: |
                No alert reaches any channel while Alertmanager is down. Check the
                prometheus-alertmanager-0 pod in the observability namespace.
          - alert: AlertmanagerScrapeMissing
            expr: absent(up{job="alertmanager"})
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "No Alertmanager scrape target"
              description: |
                The 'alertmanager' scrape job finds no target, so notification failures go
                unseen. The Service label app.kubernetes.io/name=alertmanager or its 'http'
                port name changed; fix the job in tools/k3s/observability.sh.
          - alert: AlertmanagerNotificationsFailing
            expr: |
              sum by (integration, reason) (
                increase(alertmanager_notifications_failed_total{integration!="email"}[15m])
              ) > 0
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "Alertmanager {{ \$labels.integration }} notifications failing ({{ \$labels.reason }})"
              description: |
                Alertmanager gave up on {{ \$value | printf "%.0f" }} {{ \$labels.integration }}
                notification(s) in 15 minutes after retries. For Telegram the usual causes are a
                revoked bot token, a changed chat id, or a message Telegram rejects (over 4096
                characters, or HTML parse_mode choking on a '<' in an annotation). Check the
                alertmanager log for the API error.
          # Email is a second channel next to Telegram; its failures are a defect to fix,
          # not an outage, so they get the low tier (daily Telegram reminder).
          - alert: AlertmanagerEmailNotificationsFailing
            expr: |
              sum by (integration, reason) (
                increase(alertmanager_notifications_failed_total{integration="email"}[1h])
              ) > 0
            for: 1h
            labels: { severity: p3, app: infra }
            annotations:
              summary: "Alertmanager email notifications failing ({{ \$labels.reason }})"
              description: |
                Every email notification in the last hour failed after retries, so alerts reach
                Telegram only. Check the alertmanager log for the SMTP reply; a 550 "API key is
                not authorized to send emails from <domain>" means the SMTP provider key has not
                been authorised for ALERTMANAGER_FROM_EMAIL's domain.
          - alert: AlertmanagerConfigReloadFailed
            expr: alertmanager_config_last_reload_successful == 0
            for: 10m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Alertmanager failed to load its configuration"
              description: |
                Alertmanager runs on its previous configuration; the latest change is not in
                effect. The alertmanager log names the offending field.
          - alert: PrometheusAlertmanagerUnreachable
            expr: prometheus_notifications_alertmanagers_discovered < 1
            for: 10m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "Prometheus has no Alertmanager to send alerts to"
              description: |
                Prometheus discovers no Alertmanager endpoint; every alert is dropped.
          - alert: PrometheusNotificationErrors
            expr: |
              sum by (alertmanager) (rate(prometheus_notifications_errors_total[5m])) > 0
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Prometheus fails to push alerts to {{ \$labels.alertmanager }}"
              description: |
                Prometheus gets errors posting alerts to Alertmanager. Alerts may arrive late
                or not at all.
          - alert: PrometheusRuleEvaluationFailures
            expr: |
              sum by (rule_group) (increase(prometheus_rule_evaluation_failures_total[15m])) > 0
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Rule group {{ \$labels.rule_group }} fails to evaluate"
              description: |
                At least one rule in {{ \$labels.rule_group }} errors on every evaluation (often a
                many-to-many match after a label change), so it can never fire. Check the
                Prometheus /rules page.
          - alert: PrometheusConfigReloadFailed
            expr: prometheus_config_last_reload_successful == 0
            for: 10m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Prometheus failed to load its configuration"
              description: |
                Prometheus runs on its previous scrape and rule configuration; the latest change
                (a new rule, a new scrape job) is not in effect. The prometheus-server log, or
                promtool check config on the prometheus-server ConfigMap, names the error.
          - alert: PrometheusTSDBFailing
            expr: |
              increase(prometheus_tsdb_compactions_failed_total[3h]) > 0
              or increase(prometheus_tsdb_head_truncations_failed_total[3h]) > 0
              or increase(prometheus_tsdb_wal_corruptions_total[3h]) > 0
            for: 0m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Prometheus storage errors (compaction, head truncation or WAL)"
              description: |
                Prometheus could not compact or truncate its TSDB, or found a corrupt WAL. Disk
                use grows and queries slow down until it is fixed; a full volume stops all
                alerting. Check the prometheus-server log and free space on its PVC.
          # Catch-all for scrape targets without a dedicated alert below. A dead target is
          # a blind spot: every rule over its metrics goes quiet instead of firing.
          - alert: ScrapeTargetDown
            expr: |
              up{job!~"alertmanager|mysql-exporter|redpanda|scylla|kubernetes-api-servers|kubernetes-nodes|cnpg|argocd|dex"} == 0
            for: 15m
            labels: { severity: p3, app: infra }
            annotations:
              summary: "Scrape target {{ \$labels.job }} {{ \$labels.instance }} down for >15m"
              description: |
                Prometheus cannot scrape {{ \$labels.instance }} (job {{ \$labels.job }},
                namespace {{ \$labels.namespace }}). Rules over its metrics cannot fire while it
                is down. The Prometheus /targets page shows the scrape error.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#alerting-pipeline"

      # Node golden signals: saturation (CPU, memory, I/O, conntrack, file
      # descriptors), errors (NIC errors, OOM kills, clock) and the exporter that
      # every node and hardware rule depends on. Disk space lives in infra-disk, disk
      # health in infra-hardware. Thresholds sit well above what the reference cluster (12 cores, one
      # node, ~75 pods) reached in the 3 days before 2026-10-24: CPU 65%, CPU PSI 0.26,
      # memory PSI 0.007, I/O PSI 0.2, 44% memory available at the low point.
      - name: infra-node
        interval: 1m
        rules:
          - alert: NodeExporterDown
            expr: |
              kube_node_info unless on (node) (up{service=~".*node-exporter"} == 1)
            for: 10m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "No node-exporter metrics from node {{ \$labels.node }}"
              description: |
                Prometheus gets nothing from node-exporter on {{ \$labels.node }}, so every disk,
                RAID, NVMe, memory and backup alert for that node is blind. Check the
                prometheus-prometheus-node-exporter DaemonSet pod on the node and the
                Prometheus /targets page.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"
          - alert: NodeCPUSaturated
            expr: rate(node_pressure_cpu_waiting_seconds_total[5m]) > 0.5
            for: 30m
            labels: { severity: p3, app: infra }
            annotations:
              summary: "Runnable tasks on {{ \$labels.instance }} wait for CPU {{ \$value | humanizePercentage }} of the time"
              description: |
                CPU pressure (PSI 'some') has been above 50% for 30 minutes: work queues for
                CPU and every request on the node gets slower. Find the consumer with
                kubectl top pods -A --sort-by=cpu; a scraper flood shows up as the web-tier pods.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"
          - alert: NodeCPUUtilisationHigh
            expr: |
              1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.9
            for: 1h
            labels: { severity: p3, app: infra }
            annotations:
              summary: "CPU on {{ \$labels.instance }} {{ \$value | humanizePercentage }} busy for an hour"
              description: |
                The node has had less than 10% idle CPU for an hour. No headroom is left for a
                rollout, a CI build or a traffic spike. kubectl top pods -A --sort-by=cpu.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"
          - alert: NodeMemoryLow
            expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.10
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$labels.instance }} has {{ \$value | humanizePercentage }} memory available"
              description: |
                Less than 10% of RAM is available. The kernel OOM killer and kubelet eviction
                (MemoryPressure) come next. kubectl top pods -A --sort-by=memory; check for a
                leaking pod or a missing memory limit.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"
          - alert: NodeMemoryCritical
            expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.05
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "{{ \$labels.instance }} has only {{ \$value | humanizePercentage }} memory available"
              description: |
                Under 5% of RAM is available: OOM kills of Postgres, Traefik or k3s itself are
                imminent. Scale down or restart the largest consumer now
                (kubectl top pods -A --sort-by=memory).
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"
          - alert: NodeMemoryPressureStalls
            expr: rate(node_pressure_memory_stalled_seconds_total[5m]) > 0.1
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "All tasks on {{ \$labels.instance }} stall on memory {{ \$value | humanizePercentage }} of the time"
              description: |
                Memory PSI 'full' above 10% for 15 minutes: the node is reclaiming page cache or
                thrashing, and everything on it is slow. Usually precedes NodeMemoryLow or OOM
                kills; find the consumer with kubectl top pods -A --sort-by=memory.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"
          - alert: NodeOOMKills
            expr: increase(node_vmstat_oom_kill[30m]) > 0
            for: 0m
            labels: { severity: p3, app: infra }
            annotations:
              summary: "Kernel OOM killer fired {{ \$value | printf \"%.0f\" }} time(s) on {{ \$labels.instance }} in 30m"
              description: |
                The kernel killed processes for memory, either a container hitting its limit
                (KubeContainerOOMKilled names it) or the whole node running out. dmesg -T | grep
                -i 'killed process' on the node shows the victim.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"
          - alert: NodeIOStalled
            expr: rate(node_pressure_io_stalled_seconds_total[5m]) > 0.3
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "All tasks on {{ \$labels.instance }} stall on I/O {{ \$value | humanizePercentage }} of the time"
              description: |
                I/O PSI 'full' above 30% for 15 minutes: the disks cannot keep up. Postgres,
                Prometheus and the k3s datastore all slow down. Look for a backup, restore or
                compaction (iotop on the node) and at NodeDiskRead/WriteLatencyHigh for a
                failing disk.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"
          - alert: NodeNetworkErrors
            expr: |
              (
                rate(node_network_receive_errs_total{device!~"lo|veth.*"}[5m])
                  / rate(node_network_receive_packets_total{device!~"lo|veth.*"}[5m]) > 0.01
              )
              or
              (
                rate(node_network_transmit_errs_total{device!~"lo|veth.*"}[5m])
                  / rate(node_network_transmit_packets_total{device!~"lo|veth.*"}[5m]) > 0.01
              )
            for: 30m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Interface {{ \$labels.device }} on {{ \$labels.instance }} has {{ \$value | humanizePercentage }} packet errors"
              description: |
                More than 1% of packets on {{ \$labels.device }} fail with errors for 30 minutes:
                a bad cable or switch port, a NIC fault, or an MTU mismatch on the VLAN or
                WireGuard/Tailscale link. ip -s link show {{ \$labels.device }} and ethtool -S on
                the node; for a provider-side fault, open a ticket with the hosting provider.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"
          - alert: NodeClockSkew
            expr: |
              (node_timex_offset_seconds > 0.05 and deriv(node_timex_offset_seconds[5m]) >= 0)
              or
              (node_timex_offset_seconds < -0.05 and deriv(node_timex_offset_seconds[5m]) <= 0)
            for: 10m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Clock on {{ \$labels.instance }} is {{ \$value | humanizeDuration }} off"
              description: |
                The system clock is more than 50 ms off and not converging. TLS, OIDC tokens
                (Dex/Pomerium), certificate checks and multi-node k3s all depend on time.
                timedatectl timesync-status / chronyc tracking on the node.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"
          - alert: NodeClockNotSynchronising
            expr: |
              min_over_time(node_timex_sync_status[5m]) == 0
              and node_timex_maxerror_seconds >= 16
            for: 10m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Clock on {{ \$labels.instance }} is not synchronised with NTP"
              description: |
                The kernel reports the clock as unsynchronised and its error bound has grown
                to 16 s. systemd-timesyncd or chrony is stopped or cannot reach its servers
                (outbound UDP 123). systemctl status systemd-timesyncd on the node.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"
          - alert: NodeConntrackNearLimit
            expr: node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.75
            for: 5m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "conntrack table on {{ \$labels.instance }} {{ \$value | humanizePercentage }} full"
              description: |
                When the table is full the kernel drops new connections ("nf_conntrack: table
                full" in dmesg), which looks like random timeouts on every service. A connection
                flood (scrapers) is the usual cause; raise net.netfilter.nf_conntrack_max only
                after finding it.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"
          - alert: NodeFileDescriptorsNearLimit
            expr: node_filefd_allocated / node_filefd_maximum > 0.8
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$labels.instance }} uses {{ \$value | humanizePercentage }} of its file descriptors"
              description: |
                The kernel-wide file handle limit is nearly reached; opening files and sockets
                will fail with EMFILE/ENFILE. Find the process with the most open files
                (ls /proc/*/fd | wc -l per pid) on the node.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#node"

      # k3s control plane: the API server (availability, 5xx, latency, throttling),
      # its datastore (kine/SQLite on every env here; the same apiserver-side etcd_*
      # metrics cover embedded etcd), the kubelet and the node objects. k3s serves
      # the apiserver and kubelet metrics from one process, so each series appears in
      # both the kubernetes-api-servers and kubernetes-nodes jobs; every rule pins one
      # job to avoid double counting.
      - name: infra-k8s-control-plane
        interval: 1m
        rules:
          - alert: KubeAPIServerDown
            expr: absent(up{job="kubernetes-api-servers"} == 1)
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "Kubernetes API server unreachable for >5m"
              description: |
                Prometheus cannot scrape the API server. Nothing can be deployed or rescheduled
                and controllers (cert-manager, ArgoCD, CNPG) stall; running pods keep serving.
                On the node: systemctl status k3s, journalctl -u k3s -n 200. A full disk or a
                locked/corrupt /var/lib/rancher/k3s/server/db/state.db are the usual causes.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: KubeAPIServerErrorsHigh
            expr: |
              sum(rate(apiserver_request_total{job="kubernetes-api-servers",code=~"5.."}[5m]))
                / sum(rate(apiserver_request_total{job="kubernetes-api-servers"}[5m])) > 0.05
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$value | humanizePercentage }} of API server requests fail with 5xx"
              description: |
                More than 5% of API requests return a server error for 15 minutes (the reference cluster peaked
                at 1.2% in the day before 2026-10-24). Usually the datastore (see
                K3sDatastoreLatencyHigh) or a broken aggregated API/webhook. Break it down with
                sum by (resource, verb, code) (rate(apiserver_request_total{code=~"5.."}[5m])).
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: KubeAPIServerLatencyHigh
            expr: |
              histogram_quantile(0.99, sum by (le, verb) (rate(apiserver_request_duration_seconds_bucket{job="kubernetes-api-servers",verb=~"GET|POST|PUT|PATCH|DELETE|APPLY",subresource!~"log|exec|portforward|attach|proxy"}[5m]))) > 1
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "API server p99 {{ \$labels.verb }} latency {{ \$value | humanizeDuration }}"
              description: |
                99th-percentile latency for single-object {{ \$labels.verb }} requests has been
                above 1 s for 15 minutes (normal here: under 0.2 s). The datastore is the usual
                bottleneck (disk latency, a huge SQLite file); also check CPU saturation.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: KubeAPIServerListLatencyHigh
            expr: |
              histogram_quantile(0.99, sum by (le) (rate(apiserver_request_duration_seconds_bucket{job="kubernetes-api-servers",verb="LIST"}[5m]))) > 5
            for: 15m
            labels: { severity: p3, app: infra }
            annotations:
              summary: "API server p99 LIST latency {{ \$value | humanizeDuration }}"
              description: |
                99th-percentile LIST latency above 5 s for 15 minutes (normal here: about 1 s).
                Controllers resync slowly and kubectl feels stuck. Often a client listing a
                large resource in a loop; apiserver_request_total by (resource, client) finds it.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: KubeAPIServerThrottling
            expr: |
              sum(rate(apiserver_flowcontrol_rejected_requests_total{job="kubernetes-api-servers"}[5m])) > 0
            for: 15m
            labels: { severity: p3, app: infra }
            annotations:
              summary: "API server rejects requests (priority and fairness)"
              description: |
                The API server is shedding load with 429s for 15 minutes. Some client is
                flooding it; apiserver_flowcontrol_rejected_requests_total by (flow_schema)
                says which flow schema.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: K3sDatastoreLatencyHigh
            expr: |
              histogram_quantile(0.99, sum by (le, operation) (rate(etcd_request_duration_seconds_bucket{job="kubernetes-api-servers"}[5m]))) > 0.5
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "k3s datastore p99 {{ \$labels.operation }} latency {{ \$value | humanizeDuration }}"
              description: |
                The API server waits more than 0.5 s (p99) on the datastore for
                {{ \$labels.operation }} for 15 minutes (normal: under 0.1 s). With kine/SQLite
                that is disk latency or a bloated state.db; check NodeIOStalled, disk latency and
                ls -lh /var/lib/rancher/k3s/server/db/ on the node.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: K3sDatastoreErrors
            expr: |
              sum by (operation) (rate(etcd_request_errors_total{job="kubernetes-api-servers"}[5m])) > 0.1
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "k3s datastore {{ \$labels.operation }} requests failing"
              description: |
                The API server gets errors back from its datastore (kine/SQLite or etcd). Writes
                and watches are unreliable; journalctl -u k3s on the server shows the kine or
                etcd error (disk full, database locked, corruption).
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: K3sDatastoreLarge
            expr: max(apiserver_storage_size_bytes{job="kubernetes-api-servers"}) > 2 * 1024 * 1024 * 1024
            for: 1h
            labels: { severity: p3, app: infra }
            annotations:
              summary: "k3s datastore is {{ \$value | humanize1024 }}B"
              description: |
                The k3s database passed 2 GiB (typical: under 100 MiB). SQLite slows down as it grows;
                usually an object kind is being created in a loop (Events, Jobs, ReplicaSets).
                kubectl get --raw /metrics | grep apiserver_storage_objects lists counts by kind.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: KubeletDown
            expr: |
              kube_node_info unless on (node) label_replace(up{job="kubernetes-nodes"} == 1, "node", "\$1", "instance", "(.*)")
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "kubelet on {{ \$labels.node }} unreachable for >5m"
              description: |
                Prometheus cannot scrape the kubelet on {{ \$labels.node }}. If KubeNodeNotReady
                fires too, the node or k3s/k3s-agent is down: systemctl status k3s (or k3s-agent)
                and journalctl on the node.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: KubeletPLEGSlow
            expr: |
              histogram_quantile(0.99, sum by (le, instance) (rate(kubelet_pleg_relist_duration_seconds_bucket{job="kubernetes-nodes"}[5m]))) >= 10
            for: 5m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "kubelet on {{ \$labels.instance }}: PLEG relist p99 {{ \$value | humanizeDuration }}"
              description: |
                The kubelet takes over 10 s to list containers (normal: under 0.2 s); at 3
                minutes the node goes NotReady. containerd is overloaded or wedged:
                journalctl -u k3s | grep -i pleg, and crictl ps on the node.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: KubeletTooManyPods
            expr: |
              max by (node) (kubelet_running_pods{job="kubernetes-nodes"})
                / on (node) max by (node) (kube_node_status_capacity{resource="pods"}) > 0.9
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Node {{ \$labels.node }} runs {{ \$value | humanizePercentage }} of its pod capacity"
              description: |
                Past the max-pods limit (110 by default) new pods stay Pending. Clean up
                finished Jobs (failedJobsHistoryLimit) and stray pods, or raise --max-pods in the
                k3s config.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: KubeNodeNotReady
            expr: kube_node_status_condition{condition="Ready",status="true"} == 0
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "Node {{ \$labels.node }} NotReady for >5m"
              description: |
                The kubelet on {{ \$labels.node }} stopped reporting ready. Its pods are not
                rescheduled on a single-node cluster, and are evicted after 5 minutes on a
                multi-node one. kubectl describe node {{ \$labels.node }}; on the node,
                systemctl status k3s (or k3s-agent).
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: KubeNodePressure
            expr: |
              kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure",status="true"} == 1
            for: 5m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Node {{ \$labels.node }} reports {{ \$labels.condition }}"
              description: |
                The kubelet has started evicting pods and refuses new ones. DiskPressure means
                the root filesystem or the image store passed the eviction threshold (see
                infra-disk); MemoryPressure, NodeMemoryLow; PIDPressure, a fork bomb or a
                thread leak.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: KubeNodeUnschedulable
            expr: kube_node_spec_unschedulable == 1
            for: 2h
            labels: { severity: p3, app: infra }
            annotations:
              summary: "Node {{ \$labels.node }} has been cordoned for >2h"
              description: |
                A cordon left behind after maintenance. kubectl uncordon {{ \$labels.node }}
                once the work is done.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"
          - alert: KubeStateMetricsDown
            expr: absent(up{service=~".*kube-state-metrics"} == 1)
            for: 10m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "kube-state-metrics is not scraped"
              description: |
                Every node, pod, workload, PVC and Job alert reads kube-state-metrics; while it
                is down they all stay silent. Check the prometheus-kube-state-metrics Deployment
                in the observability namespace.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#control-plane"

      # Workload health across all namespaces: errors (crash loops, OOM kills, failed
      # Jobs and CronJobs), availability (Deployments, StatefulSets, DaemonSets) and
      # saturation (unschedulable pods, PVCs filling). PodNotReady and
      # PodContainerRestarting in infra-pods stay the generic backstop; these name the
      # cause. CronJob-owned Jobs are judged by their CronJob only: a failed run stays
      # in the Job history (failedJobsHistoryLimit) long after the next run succeeded.
      - name: infra-workloads
        interval: 1m
        rules:
          - alert: KubePodCrashLooping
            expr: |
              max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}[5m]) >= 1
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$labels.namespace }}/{{ \$labels.pod }} ({{ \$labels.container }}) in CrashLoopBackOff"
              description: |
                The container keeps exiting. kubectl -n {{ \$labels.namespace }} logs
                {{ \$labels.pod }} -c {{ \$labels.container }} --previous shows why; a missing
                Secret key or a failed DB connection are the usual causes after a deploy.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"
          - alert: KubePodImagePullFailing
            expr: |
              kube_pod_container_status_waiting_reason{reason=~"ImagePullBackOff|ErrImagePull|InvalidImageName|CreateContainerConfigError"} == 1
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$labels.namespace }}/{{ \$labels.pod }} cannot start: {{ \$labels.reason }}"
              description: |
                The container never starts. For pull errors: the tag does not exist in Harbor,
                the pull secret is wrong, or Harbor is down (PlatformWorkloadDown). For
                CreateContainerConfigError: a referenced Secret or ConfigMap key is missing.
                kubectl -n {{ \$labels.namespace }} describe pod {{ \$labels.pod }}.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"
          - alert: KubeContainerOOMKilled
            expr: |
              (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1)
              and on (namespace, pod, container)
              (increase(kube_pod_container_status_restarts_total[30m]) > 0)
            for: 0m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$labels.namespace }}/{{ \$labels.pod }} ({{ \$labels.container }}) was OOMKilled"
              description: |
                The container exceeded its memory limit and was killed in the last 30 minutes.
                Raise the limit in its chart values, or find the leak; kubectl top pod and the
                Grafana pod dashboards show the memory curve before the kill.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"
          - alert: KubePodUnschedulable
            expr: kube_pod_status_unschedulable == 1
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$labels.namespace }}/{{ \$labels.pod }} cannot be scheduled"
              description: |
                No node fits the pod: requests exceed what is left, a node selector or affinity
                matches nothing, or its PVC is bound to another node (local-path). kubectl -n
                {{ \$labels.namespace }} describe pod {{ \$labels.pod }} shows the scheduler event.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"
          - alert: KubeDeploymentReplicasUnavailable
            expr: |
              kube_deployment_status_replicas_unavailable > 0
              and on (namespace, deployment) kube_deployment_spec_replicas > 0
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Deployment {{ \$labels.namespace }}/{{ \$labels.deployment }} has {{ \$value }} unavailable replica(s)"
              description: |
                Fewer replicas are available than desired for 15 minutes. kubectl -n
                {{ \$labels.namespace }} rollout status deploy/{{ \$labels.deployment }} and
                describe its newest pod.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"
          - alert: KubeDeploymentRolloutStuck
            expr: |
              kube_deployment_status_condition{condition="Progressing",status="false"} == 1
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Rollout of {{ \$labels.namespace }}/{{ \$labels.deployment }} exceeded its progress deadline"
              description: |
                The new ReplicaSet does not become ready; the old pods keep serving if there are
                any. kubectl -n {{ \$labels.namespace }} rollout status
                deploy/{{ \$labels.deployment }}; roll back through Git (ArgoCD), not by hand.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"
          - alert: KubeStatefulSetReplicasNotReady
            expr: |
              kube_statefulset_status_replicas_ready < kube_statefulset_replicas
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "StatefulSet {{ \$labels.namespace }}/{{ \$labels.statefulset }} has {{ \$value }} ready replica(s)"
              description: |
                Fewer replicas are ready than desired for 15 minutes. StatefulSets roll one pod
                at a time, so a single stuck pod blocks the rest. kubectl -n
                {{ \$labels.namespace }} describe sts {{ \$labels.statefulset }}.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"
          - alert: KubeDaemonSetUnavailable
            expr: |
              kube_daemonset_status_number_unavailable > 0
              or (kube_daemonset_status_desired_number_scheduled - kube_daemonset_status_current_number_scheduled) > 0
              or kube_daemonset_status_number_misscheduled > 0
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "DaemonSet {{ \$labels.namespace }}/{{ \$labels.daemonset }} not running on every node"
              description: |
                At least one node lacks a ready pod of {{ \$labels.daemonset }} (node-exporter,
                promtail, svclb-traefik). That node loses its metrics, logs or ingress.
                kubectl -n {{ \$labels.namespace }} get pods -o wide -l for the DaemonSet.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"
          - alert: KubeJobFailed
            expr: |
              kube_job_failed{condition="true"} == 1
              unless on (namespace, job_name) kube_job_owner{owner_kind="CronJob"}
            for: 15m
            labels: { severity: p3, app: infra }
            annotations:
              summary: "Job {{ \$labels.namespace }}/{{ \$labels.job_name }} failed"
              description: |
                A one-off Job (a migration, a seed, a restore) ran out of retries. kubectl -n
                {{ \$labels.namespace }} logs job/{{ \$labels.job_name }}. Delete the Job once
                handled; this alert lasts as long as the failed Job object.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"
          - alert: KubeCronJobLastRunFailed
            expr: |
              (
                (kube_cronjob_status_last_schedule_time - kube_cronjob_status_last_successful_time) > 0
                or
                (kube_cronjob_status_last_schedule_time unless on (namespace, cronjob) kube_cronjob_status_last_successful_time)
              )
              and on (namespace, cronjob) kube_cronjob_status_active == 0
              and on (namespace, cronjob) kube_cronjob_spec_suspend == 0
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "CronJob {{ \$labels.namespace }}/{{ \$labels.cronjob }}: latest run did not succeed"
              description: |
                The most recent scheduled run of {{ \$labels.cronjob }} finished without success
                (or none ever succeeded) and nothing is running now. Backups and dumps are
                CronJobs, so this can mean no fresh backup. kubectl -n {{ \$labels.namespace }}
                get jobs --sort-by=.status.startTime, then logs of the newest one. Rerun with
                kubectl create job --from=cronjob/{{ \$labels.cronjob }} <name>.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"
          # local-path volumes report the host filesystem, not the PVC (the provisioner
          # does not enforce sizes), so they are left to NodeFilesystemSpace* in
          # infra-disk; these cover every other storage class.
          - alert: KubePersistentVolumeFillingUp
            expr: |
              (
                max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_available_bytes{job="kubernetes-nodes"})
                  / max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes{job="kubernetes-nodes"})
              ) < 0.10
              and on (namespace, persistentvolumeclaim) kube_persistentvolumeclaim_info{storageclass!="local-path"}
            for: 30m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "PVC {{ \$labels.namespace }}/{{ \$labels.persistentvolumeclaim }} has {{ \$value | humanizePercentage }} free"
              description: |
                The volume is over 90% full. Expand the PVC (if the storage class allows it),
                or prune the data (Postgres: check bloat and WAL; Redpanda: retention).
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"
          - alert: KubePersistentVolumeFull
            expr: |
              (
                max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_available_bytes{job="kubernetes-nodes"})
                  / max by (namespace, persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes{job="kubernetes-nodes"})
              ) < 0.03
              and on (namespace, persistentvolumeclaim) kube_persistentvolumeclaim_info{storageclass!="local-path"}
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "PVC {{ \$labels.namespace }}/{{ \$labels.persistentvolumeclaim }} almost full ({{ \$value | humanizePercentage }} free)"
              description: |
                Writes to this volume fail within minutes. Free space or expand it now.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"
          - alert: KubePersistentVolumeClaimPending
            expr: kube_persistentvolumeclaim_status_phase{phase="Pending"} == 1
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "PVC {{ \$labels.namespace }}/{{ \$labels.persistentvolumeclaim }} Pending for >15m"
              description: |
                No volume binds to the claim, so its pod cannot start. kubectl -n
                {{ \$labels.namespace }} describe pvc {{ \$labels.persistentvolumeclaim }}: a
                wrong storage class, a static local PV that does not match, or the
                local-path-provisioner pod is down.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#workloads"

      # CoreDNS: availability, errors (SERVFAIL, broken upstreams), latency and
      # saturation (forwarder concurrency limit). A DNS outage looks like every
      # service failing at once.
      - name: infra-dns
        interval: 1m
        rules:
          - alert: CoreDNSDown
            expr: absent(up{service="kube-dns"} == 1)
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "CoreDNS is not answering metrics scrapes"
              description: |
                Cluster DNS is down or unscraped. Pods cannot resolve Services or external
                hosts (Postgres, Harbor, Let's Encrypt, GitHub). kubectl -n kube-system get pods
                -l k8s-app=kube-dns and its logs.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#dns"
          - alert: CoreDNSErrorsHigh
            expr: |
              sum(rate(coredns_dns_responses_total{rcode="SERVFAIL"}[5m]))
                / sum(rate(coredns_dns_responses_total[5m])) > 0.05
              and sum(rate(coredns_dns_responses_total[5m])) > 0.1
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$value | humanizePercentage }} of DNS answers are SERVFAIL"
              description: |
                CoreDNS fails over 5% of queries for 15 minutes. Usually the upstream resolver
                (the node's /etc/resolv.conf) is unreachable or slow. kubectl -n kube-system
                logs deploy/coredns.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#dns"
          - alert: CoreDNSLatencyHigh
            expr: |
              histogram_quantile(0.99, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket[5m]))) > 1
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "CoreDNS p99 latency {{ \$value | humanizeDuration }}"
              description: |
                99th-percentile DNS latency above 1 s for 15 minutes (normal: under 50 ms).
                Upstream resolver trouble or CPU throttling of the CoreDNS pod.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#dns"
          - alert: CoreDNSForwardFailing
            expr: |
              increase(coredns_forward_healthcheck_broken_total[10m]) > 0
              or increase(coredns_forward_max_concurrent_rejects_total[10m]) > 0
            for: 5m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "CoreDNS cannot forward to its upstream resolvers"
              description: |
                Every upstream failed its health check, or CoreDNS hit its forward concurrency
                limit and is refusing queries. External names (Let's Encrypt, GitHub, Harbor's
                upstreams) stop resolving. Check the node's resolvers (resolvectl status).
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#dns"

      # Certificates: cert-manager Certificates (ingress TLS, webhooks, operator certs)
      # and the k3s-managed certificates (apiserver, kubelet, controller and client
      # certs, from k3s_certificate_expiration_seconds). Let's Encrypt certificates
      # renew 30 days before expiry, so under 14 days means renewal is failing. k3s
      # renews its own leaf certificates on start when they are within 120 days of
      # expiry, so a server that is never restarted lets them run out after a year.
      - name: infra-certificates
        interval: 5m
        rules:
          - alert: CertManagerCertificateNotReady
            expr: |
              max by (namespace, name, issuer_name) (certmanager_certificate_ready_status{condition=~"False|Unknown"}) == 1
            for: 1h
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Certificate {{ \$labels.namespace }}/{{ \$labels.name }} not Ready for >1h"
              description: |
                cert-manager cannot issue or renew {{ \$labels.name }} (issuer
                {{ \$labels.issuer_name }}). kubectl -n {{ \$labels.namespace }} describe
                certificate {{ \$labels.name }}, then the pending Order and Challenge. For DNS-01:
                the Cloudflare token and the zone; for HTTP-01: DNS must point at this cluster.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#certificates"
          - alert: CertManagerCertificateExpiringSoon
            expr: |
              (min by (namespace, name) (certmanager_certificate_expiration_timestamp_seconds) - time()) < 14 * 86400
              and min by (namespace, name) (certmanager_certificate_expiration_timestamp_seconds) > 0
            for: 1h
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Certificate {{ \$labels.namespace }}/{{ \$labels.name }} expires in {{ \$value | humanizeDuration }}"
              description: |
                Renewal should have happened at 30 days left. Find out why cert-manager is not
                renewing (CertManagerCertificateNotReady, cert-manager logs) and force it with
                cmctl renew -n {{ \$labels.namespace }} {{ \$labels.name }}.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#certificates"
          - alert: CertManagerCertificateExpiryCritical
            expr: |
              (min by (namespace, name) (certmanager_certificate_expiration_timestamp_seconds) - time()) < 3 * 86400
              and min by (namespace, name) (certmanager_certificate_expiration_timestamp_seconds) > 0
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "Certificate {{ \$labels.namespace }}/{{ \$labels.name }} expires in {{ \$value | humanizeDuration }}"
              description: |
                Browsers and clients reject the host within days. Fix issuance now (see
                CertManagerCertificateExpiringSoon); Let's Encrypt rate limits leave little
                room for retries.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#certificates"
          - alert: CertManagerAbsent
            expr: |
              absent(up{app_kubernetes_io_name="cert-manager",app_kubernetes_io_component="controller"} == 1)
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "cert-manager controller is not scraped"
              description: |
                No metrics from the cert-manager controller: it is down (no renewals happen) or
                lost its prometheus.io/scrape annotation, which blinds the certificate alerts.
                kubectl -n cert-manager get pods.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#certificates"
          - alert: K3sCertificateExpiringSoon
            expr: |
              min by (subject) (k3s_certificate_expiration_seconds{job="kubernetes-api-servers",usages!="CertSign"}) < 30 * 86400
            for: 1h
            labels: { severity: p2, app: infra }
            annotations:
              summary: "k3s certificate {{ \$labels.subject }} expires in {{ \$value | humanizeDuration }}"
              description: |
                A k3s-managed certificate (apiserver, kubelet, controller or a client cert) has
                under 30 days left. k3s renews leaf certificates when it starts within 120 days
                of expiry: systemctl restart k3s on the server (k3s-agent on workers), or
                k3s certificate rotate. When they expire the API server and kubelets stop
                talking to each other.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#certificates"
          - alert: K3sCertificateExpiryCritical
            expr: |
              min by (subject) (k3s_certificate_expiration_seconds{job="kubernetes-api-servers",usages!="CertSign"}) < 7 * 86400
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "k3s certificate {{ \$labels.subject }} expires in {{ \$value | humanizeDuration }}"
              description: |
                Restart k3s on the server now (systemctl restart k3s) so it renews its
                certificates; then check K3sCertificateExpiringSoon has cleared.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#certificates"
          - alert: K3sCACertificateExpiring
            expr: |
              min by (subject) (k3s_certificate_expiration_seconds{job="kubernetes-api-servers",usages="CertSign"}) < 180 * 86400
            for: 1h
            labels: { severity: p3, app: infra }
            annotations:
              summary: "k3s CA {{ \$labels.subject }} expires in {{ \$value | humanizeDuration }}"
              description: |
                A k3s CA (10-year lifetime) is within 6 months of expiry. Rotating a CA is a
                planned operation (k3s certificate rotate-ca); every kubeconfig and node join
                token changes.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#certificates"

      # Edge (Traefik): traffic, errors and latency per entrypoint, and the platform
      # backends behind it. Pomerium has no metrics listener configured, so its
      # errors are read from Traefik's per-service counters (sso-pomerium-proxy-*).
      # Traffic floors keep a quiet env (a handful of probes an hour) from paging on
      # one failed request.
      - name: platform-edge
        interval: 1m
        rules:
          - alert: TraefikMetricsMissing
            expr: absent(up{app_kubernetes_io_name="traefik"} == 1)
            for: 5m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "No Traefik metrics"
              description: |
                Traefik is down (then PlatformWorkloadDown fires too, and every site is
                unreachable) or lost its prometheus.io/scrape pod annotation, which blinds the
                edge alerts. kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#edge"
          - alert: TraefikHighErrorRate
            expr: |
              sum by (entrypoint) (rate(traefik_entrypoint_requests_total{code=~"5.."}[5m]))
                / sum by (entrypoint) (rate(traefik_entrypoint_requests_total[5m])) > 0.05
              and sum by (entrypoint) (rate(traefik_entrypoint_requests_total[5m])) > 0.1
            for: 10m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$value | humanizePercentage }} of requests on entrypoint {{ \$labels.entrypoint }} end in 5xx"
              description: |
                More than 5% of edge requests fail for 10 minutes (the reference cluster peaked at 2.7%). Find
                the backend: sum by (service, code) (rate(traefik_service_requests_total{code=~"5.."}[5m])).
                502/504 is a backend down or too slow, 503 a Service without ready endpoints.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#edge"
          - alert: TraefikSlowRequests
            expr: |
              (
                1 - sum by (entrypoint) (rate(traefik_entrypoint_request_duration_seconds_bucket{le="1.2"}[15m]))
                  / sum by (entrypoint) (rate(traefik_entrypoint_request_duration_seconds_count[15m]))
              ) > 0.25
              and sum by (entrypoint) (rate(traefik_entrypoint_requests_total[15m])) > 0.5
            for: 15m
            labels: { severity: p3, app: infra }
            annotations:
              summary: "{{ \$value | humanizePercentage }} of requests on {{ \$labels.entrypoint }} take over 1.2 s"
              description: |
                A quarter of edge requests are slow for 15 minutes. Long-lived streams (SSE,
                websockets) count as slow too, so check per service first:
                traefik_service_request_duration_seconds_bucket by (service). Then node
                saturation (NodeCPUSaturated, NodeIOStalled) and the backend itself.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#edge"
          - alert: TraefikTrafficStopped
            expr: |
              sum(rate(traefik_entrypoint_requests_total[15m])) == 0
              and sum(rate(traefik_entrypoint_requests_total[15m] offset 1d)) > 0.05
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Traefik received no requests for 15 minutes (it did yesterday)"
              description: |
                The edge sees no traffic at all while there was some a day ago: DNS no longer
                points here, the provider firewall or the svclb-traefik pod drops port 80/443,
                or the public IP changed. Check from outside: curl -sI https://<a public host>.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#edge"
          - alert: PlatformServiceErrorsHigh
            expr: |
              sum by (service) (rate(traefik_service_requests_total{service=~"${PLATFORM_TRAEFIK_SERVICES_RE}",code=~"5.."}[5m]))
                / sum by (service) (rate(traefik_service_requests_total{service=~"${PLATFORM_TRAEFIK_SERVICES_RE}"}[5m])) > 0.1
              and sum by (service) (rate(traefik_service_requests_total{service=~"${PLATFORM_TRAEFIK_SERVICES_RE}"}[5m])) > 0.02
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$value | humanizePercentage }} of requests to {{ \$labels.service }} fail with 5xx"
              description: |
                A platform service behind Traefik (Pomerium, Dex, Harbor, Argo CD, Nexus,
                Grafana) answers more than 10% 5xx for 15 minutes. For sso-pomerium-proxy the
                5xx may come from an app behind Pomerium: Pomerium's log names the upstream.
                Otherwise check the service's pods and logs.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#edge"

      # Platform services: workload availability in the platform namespaces (Traefik,
      # CoreDNS, cert-manager, Pomerium, Dex, Harbor, Argo CD, the CNPG operator),
      # Dex errors from its own telemetry, and Argo CD application state. Harbor and
      # Pomerium expose no metrics as installed, so their "up" is their Deployments'
      # readiness and their errors are in PlatformServiceErrorsHigh.
      - name: platform-services
        interval: 1m
        rules:
          - alert: PlatformWorkloadDown
            expr: |
              (
                kube_deployment_status_replicas_available{namespace=~"${PLATFORM_NAMESPACES_RE}"} == 0
                and on (namespace, deployment) kube_deployment_spec_replicas > 0
              )
              or
              (
                kube_statefulset_status_replicas_ready{namespace=~"${PLATFORM_NAMESPACES_RE}"} == 0
                and on (namespace, statefulset) kube_statefulset_replicas > 0
              )
            for: 10m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "Platform workload {{ \$labels.namespace }}/{{ \$labels.deployment }}{{ \$labels.statefulset }} has no ready replica"
              description: |
                {{ \$labels.deployment }}{{ \$labels.statefulset }} in {{ \$labels.namespace }} has
                been completely down for 10 minutes. Depending on which: Traefik = every site
                down; CoreDNS = cluster DNS down; pomerium-proxy/dex = every protected app and
                login down; harbor-* = no image pulls or CI pushes; argocd-* = GitOps stopped;
                cert-manager = no renewals; cnpg = Postgres failover and backups stopped.
                kubectl -n {{ \$labels.namespace }} describe pods and logs --previous.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#platform-services"
          - alert: DexErrors
            expr: |
              sum(increase(http_requests_total{job="dex",code=~"5.."}[15m])) > 5
            for: 5m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Dex answered {{ \$value | printf \"%.0f\" }} requests with 5xx in 15m"
              description: |
                Logins through Dex fail (Grafana, Argo CD, Pomerium-protected apps). The
                GitHub connector (OAuth App credentials, GitHub outage) or Dex's storage is the
                usual cause: kubectl -n ${NAMESPACE_SSO} logs deploy/dex.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#platform-services"
          - alert: DexMetricsMissing
            expr: absent(up{job="dex"} == 1)
            for: 15m
            labels: { severity: p3, app: infra }
            annotations:
              summary: "No Dex telemetry scraped"
              description: |
                The 'dex' scrape job finds no ready target (Service dex, port 'telemetry'), so
                DexErrors cannot fire. Dex is down (PlatformWorkloadDown) or its Service changed.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#platform-services"
          - alert: ArgoCDAppUnhealthy
            expr: |
              argocd_app_info{health_status=~"Degraded|Missing|Unknown"} == 1
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Argo CD app {{ \$labels.name }} is {{ \$labels.health_status }}"
              description: |
                Argo CD reports {{ \$labels.name }} (namespace {{ \$labels.dest_namespace }}) as
                {{ \$labels.health_status }} for 15 minutes: a resource failed (Degraded), was
                never created (Missing), or cannot be assessed. argocd app get {{ \$labels.name }}
                or the Argo CD UI lists the failing resource.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#argocd"
          - alert: ArgoCDAppSyncFailing
            expr: |
              sum by (name) (increase(argocd_app_sync_total{phase=~"Error|Failed"}[1h])) > 0
              and on (name) argocd_app_info{sync_status!="Synced"} == 1
            for: 10m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Argo CD sync of {{ \$labels.name }} failed and the app is still not Synced"
              description: |
                A sync attempt failed in the last hour and the app has not converged since,
                so the last Git change is not deployed. argocd app get {{ \$labels.name }} shows
                the operation message (an invalid manifest, an immutable field, a webhook
                rejecting the object).
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#argocd"
          - alert: ArgoCDAppOutOfSync
            expr: |
              argocd_app_info{sync_status="OutOfSync",autosync_enabled="true"} == 1
            for: 6h
            labels: { severity: p3, app: infra }
            annotations:
              summary: "Argo CD app {{ \$labels.name }} OutOfSync for >6h despite auto-sync"
              description: |
                Auto-sync is on but the live state still differs from Git after 6 hours. Either a
                field is mutated by a controller (add ignoreDifferences for it), or sync is
                failing quietly. argocd app diff {{ \$labels.name }} shows the drift.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#argocd"
          - alert: ArgoCDMetricsMissing
            expr: absent(up{job="argocd",component="argocd-application-controller"} == 1)
            for: 15m
            labels: { severity: p3, app: infra }
            annotations:
              summary: "No Argo CD application-controller metrics"
              description: |
                The 'argocd' scrape job finds no ready application controller (port 'metrics'
                :8082), so the Argo CD app alerts cannot fire. Check
                argocd-application-controller-0 in the ${NAMESPACE_ARGOCD} namespace.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#argocd"

      # CloudNativePG clusters (the 'cnpg' scrape job): instance up, replication,
      # WAL archiving, backups, connection and transaction-ID saturation. Archiving and
      # backup rules are inert until a cluster has a backup target (barman object
      # store or the Barman Cloud plugin): without one CNPG's archive_command succeeds
      # without storing anything, and the backup timestamps stay 0.
      - name: infra-cnpg
        interval: 1m
        rules:
          - alert: CNPGInstanceDown
            expr: up{job="cnpg"} == 0 or cnpg_collector_up == 0
            for: 5m
            labels: { severity: p1, app: infra }
            annotations:
              summary: "Postgres instance {{ \$labels.namespace }}/{{ \$labels.pod }} is down"
              description: |
                The CNPG instance manager does not answer, or cannot reach its Postgres.
                Single-instance clusters have no failover: the apps on {{ \$labels.cluster }}
                are down. kubectl -n {{ \$labels.namespace }} get cluster,pods and
                kubectl cnpg status {{ \$labels.cluster }} -n {{ \$labels.namespace }}.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#cnpg"
          - alert: CNPGReplicationLagHigh
            expr: |
              cnpg_pg_replication_lag > 300
              and on (namespace, pod) cnpg_pg_replication_in_recovery == 1
            for: 10m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Replica {{ \$labels.namespace }}/{{ \$labels.pod }} is {{ \$value | humanizeDuration }} behind"
              description: |
                A standby lags its primary by more than 5 minutes; a failover now loses that
                much. Check the replica's disk latency and the network, and
                cnpg_pg_replication_is_wal_receiver_up.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#cnpg"
          - alert: CNPGArchivingFailing
            expr: |
              cnpg_pg_stat_archiver_last_failed_time > 0
              and (cnpg_pg_stat_archiver_last_failed_time - cnpg_pg_stat_archiver_last_archived_time) > 1
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "WAL archiving fails on {{ \$labels.namespace }}/{{ \$labels.pod }}"
              description: |
                The latest archive_command attempt failed and none succeeded since: point-in-time
                recovery stops at the last archived segment, and pg_wal grows until the volume
                fills. kubectl -n {{ \$labels.namespace }} logs {{ \$labels.pod }} | grep -i
                archive; usually object-store credentials or reachability.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#cnpg"
          - alert: CNPGWALArchiveBacklog
            expr: cnpg_collector_pg_wal_archive_status{value="ready"} > 50
            for: 30m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$value }} WAL segments waiting to be archived on {{ \$labels.namespace }}/{{ \$labels.pod }}"
              description: |
                WAL is produced faster than it is archived, or archiving is stuck. Each segment
                is 16 MiB on the Postgres volume. See CNPGArchivingFailing.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#cnpg"
          - alert: CNPGBackupStale
            expr: |
              (time() - max by (namespace, cluster, pod) ({job="cnpg",__name__=~".*last_available_backup_timestamp"})) > 26 * 3600
              and max by (namespace, cluster, pod) ({job="cnpg",__name__=~".*last_available_backup_timestamp"}) > 0
            for: 1h
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Last base backup of {{ \$labels.namespace }}/{{ \$labels.cluster }} is {{ \$value | humanizeDuration }} old"
              description: |
                No successful base backup for over 26 hours, so a restore needs more WAL (or loses
                data, if archiving is broken too). kubectl -n {{ \$labels.namespace }} get
                backups,scheduledbackups.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#cnpg"
          - alert: CNPGLastBackupFailed
            expr: |
              max by (namespace, cluster, pod) ({job="cnpg",__name__=~".*last_failed_backup_timestamp"})
                > max by (namespace, cluster, pod) ({job="cnpg",__name__=~".*last_available_backup_timestamp"})
            for: 15m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Latest base backup of {{ \$labels.namespace }}/{{ \$labels.cluster }} failed"
              description: |
                The most recent backup attempt failed after the last good one.
                kubectl -n {{ \$labels.namespace }} describe backup (newest) shows the error.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#cnpg"
          - alert: CNPGConnectionsNearLimit
            expr: |
              sum by (namespace, cluster, pod) (cnpg_backends_total)
                / on (namespace, cluster, pod) max by (namespace, cluster, pod) (cnpg_pg_settings_setting{name="max_connections"}) > 0.8
            for: 10m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$labels.namespace }}/{{ \$labels.pod }} uses {{ \$value | humanizePercentage }} of max_connections"
              description: |
                New connections fail with "too many clients" at 100%. Usually an app pool sized
                above its share or leaking connections: cnpg_backends_total by (datname, usename,
                application_name).
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#cnpg"
          - alert: CNPGTransactionIDAgeHigh
            expr: max by (namespace, cluster, pod, datname) (cnpg_pg_database_xid_age) > 1000000000
            for: 1h
            labels: { severity: p2, app: infra }
            annotations:
              summary: "Database {{ \$labels.datname }} on {{ \$labels.namespace }}/{{ \$labels.cluster }}: XID age {{ \$value | humanize }}"
              description: |
                Transaction-ID age passed 1 billion (autovacuum normally keeps it near 200
                million). At about 2.1 billion Postgres stops accepting writes to prevent
                wraparound. A long-running transaction or a stuck replication slot blocks
                vacuum; run VACUUM (FREEZE) on the oldest tables.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#cnpg"
          - alert: CNPGLongRunningTransaction
            expr: |
              cnpg_backends_max_tx_duration_seconds{application_name!~"pg_dump|pg_basebackup|.*barman.*"} > 3600
            for: 15m
            labels: { severity: p3, app: infra }
            annotations:
              summary: "Transaction open for {{ \$value | humanizeDuration }} on {{ \$labels.namespace }}/{{ \$labels.pod }} ({{ \$labels.datname }}, {{ \$labels.usename }})"
              description: |
                A transaction ({{ \$labels.state }}, application '{{ \$labels.application_name }}')
                has been open for over an hour. It holds back vacuum and can hold locks.
                SELECT pid, state, xact_start, query FROM pg_stat_activity ORDER BY xact_start;
                pg_terminate_backend(pid) if it is abandoned.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#cnpg"
          - alert: CNPGFenced
            expr: cnpg_collector_fencing_on == 1 or cnpg_collector_manual_switchover_required == 1
            for: 10m
            labels: { severity: p2, app: infra }
            annotations:
              summary: "{{ \$labels.namespace }}/{{ \$labels.pod }} is fenced or waits for a manual switchover"
              description: |
                The instance is fenced (Postgres stopped on purpose) or the cluster needs a
                manual switchover to finish an update. kubectl cnpg status {{ \$labels.cluster }}
                -n {{ \$labels.namespace }}; kubectl cnpg fencing off, or kubectl cnpg promote.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/ALERTING.md#cnpg"

      # MySQL (Percona operator stack from tools/k3s/mysql.sh, scraped by the
      # 'mysql-exporter' job above). Inert in envs without the MySQL stack.
      - name: mysql
        interval: 1m
        rules:
          - alert: MysqlExporterDown
            expr: up{job="mysql-exporter"} == 0
            for: 10m
            labels: { severity: p2, app: mysql }
            annotations:
              summary: "Prometheus cannot scrape mysql-exporter"
              description: |
                MySQL is unmonitored while the exporter is down. Check the mysql-exporter
                Deployment in the mysql namespace.
          - alert: MysqlDown
            expr: mysql_up == 0
            for: 5m
            labels: { severity: p1, app: mysql }
            annotations:
              summary: "mysql-exporter cannot connect to MySQL"
              description: |
                mysqld-exporter's connection to MySQL fails. Either MySQL is down or the
                exporter's credentials (Secret mysql-exporter-credentials) no longer work.
                Check the mysql-cluster-mysql-0 pod first.
          - alert: MysqlConnectionsNearLimit
            expr: |
              mysql_global_status_threads_connected / mysql_global_variables_max_connections > 0.8
            for: 10m
            labels: { severity: p2, app: mysql }
            annotations:
              summary: "MySQL connections above 80% of max_connections"
              description: |
                {{ \$value | humanizePercentage }} of max_connections in use. New connections fail
                with "Too many connections" at 100%, which takes the PHP sites down. Usually a
                scraper flood or a wedged pool holding connections.

      # kafka-journal stack watchdog (Redpanda + ScyllaDB + replicator; see
      # docs/KAFKA-JOURNAL-OPS.md). Rules are inert until the redpanda/scylla scrape jobs
      # have live targets and the replicator consumer group exists — like the
      # uce-* rules they activate the moment the metrics appear.
      # Lag gauges require the enable_consumer_group_metrics cluster property
      # to include consumer_lag (set by tools/k3s/redpanda.sh in the CR).
      # ScyllaSnapshotOverdue keys off a node-exporter textfile stamp written
      # by the scylla-backup CronJob (nas-backup-stamp pattern).
      - name: kafka-journal
        interval: 1m
        rules:
          - alert: RedpandaDown
            expr: up{job="redpanda"} == 0
            for: 5m
            labels: { severity: p1, app: kafka-journal }
            annotations:
              summary: "Redpanda broker target down for >5m"
              description: |
                Prometheus cannot scrape the Redpanda admin API (:9644
                /public_metrics). Journal appends are failing or about to —
                check the broker pod and the redpanda CR status.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/KAFKA-JOURNAL-OPS.md#redpanda-loss"
          - alert: ScyllaDown
            expr: up{job="scylla"} == 0
            for: 5m
            labels: { severity: p2, app: kafka-journal }
            annotations:
              summary: "Scylla metrics target down for >5m"
              description: |
                Prometheus cannot scrape Scylla (:9180). Reads and the
                replicator write path are degraded; the journal itself keeps
                accepting appends (Redpanda) until topic retention runs out.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/KAFKA-JOURNAL-OPS.md#scylla-loss"
          - alert: KafkaJournalReplicatorLagHigh
            expr: |
              max(redpanda_kafka_consumer_group_lag_max) > 10000
            for: 15m
            labels: { severity: p2, app: kafka-journal }
            annotations:
              summary: "kafka-journal replicator lag > 10k events for >15m"
              description: |
                The replicator consumer group is more than 10k events behind
                the journal head on at least one partition. Read models are
                stale; check replicator throughput and Scylla write latency.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/KAFKA-JOURNAL-OPS.md#replicator-stall"
          - alert: KafkaJournalReplicatorStalled
            expr: |
              sum(redpanda_kafka_consumer_group_lag_sum) > 0
              and sum(delta(redpanda_kafka_consumer_group_committed_offset[15m])) == 0
            for: 15m
            labels: { severity: p1, app: kafka-journal }
            annotations:
              summary: "kafka-journal replicator stalled: lag present, no commits for 15m"
              description: |
                There is uncommitted journal backlog but the replicator has not
                committed any offsets in 15 minutes. If this persists past the
                7-day topic retention, unreplicated events are lost — restart
                the replicator and check Scylla availability.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/KAFKA-JOURNAL-OPS.md#replicator-stall"
          - alert: KafkaJournalDataDiskLow
            expr: |
              (redpanda_storage_disk_free_bytes / redpanda_storage_disk_total_bytes) < 0.15
            for: 30m
            labels: { severity: p2, app: kafka-journal }
            annotations:
              summary: "Redpanda data disk below 15% free"
              description: |
                Free space on the Redpanda data mount is under 15%. The static
                local PV shares /data with Scylla and backups — prune or grow
                before the broker hits its write floor.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/KAFKA-JOURNAL-OPS.md#disk-full"
          - alert: ScyllaSnapshotOverdue
            expr: |
              time() - scylla_snapshot_last_success_timestamp_seconds > 26 * 3600
            for: 30m
            labels: { severity: p1, app: kafka-journal }
            annotations:
              summary: "Scylla snapshot stale or stamp metric absent (>26h)"
              description: |
                The daily scylla-backup CronJob has not stamped a successful
                snapshot for over 26 hours. Daily snapshots are the durability
                line: they must stay well under the 7-day journal topic
                retention. Run tools/k3s/scylla.sh <env> --snapshot-now and
                check the CronJob.
              runbook: "https://github.com/teob-cc/infra-skills/blob/main/docs/KAFKA-JOURNAL-OPS.md#snapshot-cadence"

prometheus-pushgateway:
  enabled: false

kube-state-metrics:
  enabled: true

prometheus-node-exporter:
  enabled: true
  # Textfile collector: node crons (NAS rdiff syncs) drop success-stamp metrics
  # under /var/lib/node_exporter/textfile via /usr/local/bin/nas-backup-stamp
  # (installed by tools/backup.sh). Watched by the infra-backup alert group.
  extraArgs:
    - --collector.textfile.directory=/host/textfile
  extraHostVolumeMounts:
    - name: textfile
      hostPath: /var/lib/node_exporter/textfile
      mountPath: /host/textfile
      readOnly: true
EOF
  
  # Alertmanager needs the resend-api-key secret in $NAMESPACE_OBSERVABILITY for SMTP auth.
  # The canonical secret lives in `default` (applied via SOPS; app workloads consume it
  # via envFrom); mirror it here so Alertmanager's extraSecretMounts can find it.
  # A dry run writes nothing: it only reports what is missing.
  if [[ "$DRY_RUN" == "true" ]]; then
    for s in resend-api-key alertmanager-telegram; do
      kubectl -n "$NAMESPACE_OBSERVABILITY" get secret "$s" >/dev/null 2>&1 \
        || warn "Dry run: Secret ${NAMESPACE_OBSERVABILITY}/$s is missing; a real run creates a placeholder"
    done
  elif kubectl -n default get secret resend-api-key >/dev/null 2>&1; then
    if ! kubectl -n "$NAMESPACE_OBSERVABILITY" get secret resend-api-key >/dev/null 2>&1; then
      info "Mirroring resend-api-key from default → ${NAMESPACE_OBSERVABILITY} for Alertmanager SMTP"
      kubectl -n default get secret resend-api-key -o yaml \
        | sed -E 's/^(  namespace:).*/\1 '"$NAMESPACE_OBSERVABILITY"'/; /(resourceVersion|uid|creationTimestamp):/d' \
        | kubectl -n "$NAMESPACE_OBSERVABILITY" apply -f - >/dev/null
    fi
  elif ! kubectl -n "$NAMESPACE_OBSERVABILITY" get secret resend-api-key >/dev/null 2>&1; then
    # Alertmanager mounts this Secret unconditionally; without it the pod never starts and
    # `helm --wait` below times out, failing the whole step. A fresh self-service environment
    # legitimately has no SMTP relay yet, so install a labelled placeholder: Alertmanager
    # starts, email delivery fails (visibly, in its log) until the real key is applied.
    warn "resend-api-key Secret not found in 'default' namespace -- creating a PLACEHOLDER."
    warn "Email alert delivery is NOT configured. To enable it, apply the real Secret:"
    warn "  sops -d \$INFRA_ENVS_ROOT/${ENV_NAME}/secrets.sops/resend-api-key.yaml | kubectl apply -f -"
    warn "then re-run this script (it mirrors the key into ${NAMESPACE_OBSERVABILITY})."
    kubectl -n "$NAMESPACE_OBSERVABILITY" create secret generic resend-api-key \
      --from-literal=api_key=unconfigured --dry-run=client -o yaml \
      | kubectl label --local -f - -o yaml infra-skills/placeholder=true \
      | kubectl apply -f - >/dev/null
  fi

  # Alertmanager also mounts the alertmanager-telegram secret unconditionally, so a
  # missing one wedges the pod exactly like a missing resend-api-key. An env
  # provisioned without either has no Alertmanager at all — and nothing pages when
  # a public site goes down, which is exactly how such a gap gets discovered.
  if [[ "$DRY_RUN" != "true" ]] && ! kubectl -n "$NAMESPACE_OBSERVABILITY" get secret alertmanager-telegram >/dev/null 2>&1; then
    warn "alertmanager-telegram Secret not found in '${NAMESPACE_OBSERVABILITY}' namespace -- creating a PLACEHOLDER."
    warn "Telegram alert delivery is NOT configured. Apply the real Secret before relying on alerting:"
    warn "  sops -d \$INFRA_ENVS_ROOT/${ENV_NAME}/secrets.sops/alertmanager-telegram.yaml | kubectl apply -f -"
    kubectl -n "$NAMESPACE_OBSERVABILITY" create secret generic alertmanager-telegram \
      --from-literal=bot_token=unconfigured --from-literal=chat_id=0 --dry-run=client -o yaml \
      | kubectl label --local -f - -o yaml infra-skills/placeholder=true \
      | kubectl apply -f - >/dev/null
  fi

  # Merge env-provided alert groups (fragments with a top-level 'groups:' list)
  # from envs/shared/alerts/ and envs/<env>/alerts/ into the generated values.
  for alerts_fragment in "${ENVS_ROOT}/shared/alerts/"*.yml "${ENVS_ROOT}/shared/alerts/"*.yaml \
                         "${ENVS_ROOT}/${ENV_NAME}/alerts/"*.yml "${ENVS_ROOT}/${ENV_NAME}/alerts/"*.yaml; do
    [[ -f "$alerts_fragment" ]] || continue
    info "Merging alert groups from ${alerts_fragment#"${ENVS_ROOT}/"}"
    yq eval-all -i '(select(fileIndex==0).serverFiles."alerting_rules.yml".groups) += (select(fileIndex==1).groups) | select(fileIndex==0)' \
      "$prometheus_values" "$alerts_fragment"
  done

  # Blackbox exporter backs the 'blackbox-http' scrape job above; installed only for
  # envs that opted into probing. Without it the shared 'uptime' alert group has no
  # series to evaluate and public endpoints go unwatched -- a public site can stay
  # down for many hours without anything firing.
  if [[ "$RULES_ONLY" == "true" ]]; then
    if [[ -n "$PROBE_TARGETS" || -n "$PROBE_TARGETS_POST" ]] \
        && ! helm -n "$NAMESPACE_OBSERVABILITY" status prometheus-blackbox-exporter >/dev/null 2>&1; then
      warn "--rules-only: blackbox exporter not installed although PROBE_TARGETS is set; run without --rules-only once"
    fi
  elif [[ -n "$PROBE_TARGETS" || -n "$PROBE_TARGETS_POST" ]]; then
    info "Installing blackbox exporter (GET: ${PROBE_TARGETS:-none}; POST: ${PROBE_TARGETS_POST:-none})"
    # http_2xx_post merges alongside the chart's stock modules (helm deep-merges maps).
    # 10s module timeout < 15s scrape_timeout on the blackbox-http-post job: a backend
    # that hangs past 10s becomes probe_success=0 instead of a lost scrape.
    blackbox_values=$(mktemp -t blackbox-values-XXXX.yaml)
    cat > "$blackbox_values" <<'BBEOF'
config:
  modules:
    http_2xx_post:
      prober: http
      timeout: 10s
      http:
        method: POST
        preferred_ip_protocol: ip4
BBEOF
    helm upgrade --install prometheus-blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
      --version "$BLACKBOX_CHART_VERSION" \
      --namespace "$NAMESPACE_OBSERVABILITY" \
      --wait \
      --timeout 5m \
      -f "$blackbox_values"
    rm -f "$blackbox_values"
  else
    info "PROBE_TARGETS unset for ${ENV_NAME}; skipping blackbox exporter (no uptime probing)"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    # Server-side render of the exact upgrade a real run performs, then a diff of the
    # three ConfigMaps it changes against the live objects. The live prometheus.yml
    # also carries the post-upgrade node-label patch below, so that relabel shows up
    # as removed here and is re-added by a real run.
    log "=== Dry run: helm upgrade prometheus --dry-run=server (nothing is applied) ==="
    dry_dir=$(mktemp -d -t prometheus-dry-run-XXXX)
    helm upgrade --install prometheus prometheus-community/prometheus \
      --version "$PROMETHEUS_CHART_VERSION" \
      --namespace "$NAMESPACE_OBSERVABILITY" \
      --dry-run=server -o json \
      -f "$prometheus_values" | jq -r '.manifest' > "$dry_dir/manifest.yaml"
    dry_cm() { # <configmap> <key> <out>
      yq "select(.kind == \"ConfigMap\" and .metadata.name == \"$1\") | .data.\"$2\"" "$dry_dir/manifest.yaml" > "$3.new"
      kubectl -n "$NAMESPACE_OBSERVABILITY" get configmap "$1" -o json 2>/dev/null \
        | jq -r --arg k "$2" '.data[$k] // ""' > "$3.live"
    }
    dry_cm prometheus-server alerting_rules.yml "$dry_dir/alerting_rules"
    dry_cm prometheus-server prometheus.yml "$dry_dir/prometheus"
    dry_cm prometheus-alertmanager alertmanager.yml "$dry_dir/alertmanager"
    for f in alerting_rules prometheus alertmanager; do
      # Normalise both sides through yq so key order and quoting do not show as changes.
      yq -P 'sort_keys(..)' "$dry_dir/$f.live" > "$dry_dir/$f.live.n" 2>/dev/null || cp "$dry_dir/$f.live" "$dry_dir/$f.live.n"
      yq -P 'sort_keys(..)' "$dry_dir/$f.new" > "$dry_dir/$f.new.n" 2>/dev/null || cp "$dry_dir/$f.new" "$dry_dir/$f.new.n"
      log "--- diff ${f} (live -> rendered) ---"
      diff -u "$dry_dir/$f.live.n" "$dry_dir/$f.new.n" || true
    done
    yq '.groups[].rules[].alert' "$dry_dir/alerting_rules.live" 2>/dev/null | sort -u > "$dry_dir/alerts.live" || true
    yq '.groups[].rules[].alert' "$dry_dir/alerting_rules.new" | sort -u > "$dry_dir/alerts.new"
    log "Alerts added:   $(comm -13 "$dry_dir/alerts.live" "$dry_dir/alerts.new" | wc -l | tr -d ' ')"
    log "Alerts removed: $(comm -23 "$dry_dir/alerts.live" "$dry_dir/alerts.new" | tr '\n' ' ')"
    log "Scrape jobs:    $(yq '.scrape_configs[].job_name' "$dry_dir/prometheus.new" | tr '\n' ' ')"
    log "Rendered files kept in $dry_dir"
    exit 0
  fi

  helm upgrade --install prometheus prometheus-community/prometheus \
    --version "$PROMETHEUS_CHART_VERSION" \
    --namespace "$NAMESPACE_OBSERVABILITY" \
    --wait \
    --timeout 10m \
    -f "$prometheus_values"
  
  # Workaround: Ensure postgres-exporter scrape config is applied
  # The Prometheus Helm chart may not always merge extraScrapeConfigs correctly
  info "Ensuring postgres-exporter scrape config is present..."
  sleep 2  # Give Prometheus a moment to update ConfigMap after Helm install
  
  pg_scrape_present=$(kubectl get configmap -n "$NAMESPACE_OBSERVABILITY" prometheus-server -o jsonpath='{.data.prometheus\.yaml}' 2>/dev/null | grep -c "job_name: 'postgres-exporter'" || echo "0")
  
  if [[ "$pg_scrape_present" == "0" ]]; then
    warn "Postgres-exporter scrape config not found - automatically adding it..."
    
    # Get the ConfigMap, add scrape config, and update it
    cm_file=$(mktemp)
    kubectl get configmap -n "$NAMESPACE_OBSERVABILITY" prometheus-server -o yaml > "$cm_file"
    
    # Create the scrape config block
    postgres_scrape_config="  - job_name: 'postgres-exporter'
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - ${NAMESPACE_POSTGRES}
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: postgres-exporter
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: metrics
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_service_name]
        target_label: service
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod"
    
    # Use yq to properly insert the scrape config into the YAML
    # Apply with server-side apply using helm field manager to avoid conflicts
    {
      # Extract prometheus.yml and check if postgres-exporter already exists
      prom_config=$(yq eval '.data."prometheus.yml"' "$cm_file")
      
      if [[ -z "$prom_config" ]]; then
        err "prometheus.yml not found in ConfigMap"
        exit 1
      fi
      
      # Check if postgres-exporter already exists
      if echo "$prom_config" | yq eval '.scrape_configs[] | select(.job_name == "postgres-exporter")' - >/dev/null 2>&1; then
        info "Postgres-exporter scrape config already present"
        exit 0
      fi
      
      # Create temporary file for the new scrape config
      new_scrape_file=$(mktemp)
      cat > "$new_scrape_file" <<EOF
job_name: 'postgres-exporter'
kubernetes_sd_configs:
  - role: endpoints
    namespaces:
      names:
        - ${NAMESPACE_POSTGRES}
relabel_configs:
  - source_labels: [__meta_kubernetes_service_name]
    action: keep
    regex: postgres-exporter
  - source_labels: [__meta_kubernetes_endpoint_port_name]
    action: keep
    regex: metrics
  - source_labels: [__meta_kubernetes_namespace]
    target_label: namespace
  - source_labels: [__meta_kubernetes_service_name]
    target_label: service
  - source_labels: [__meta_kubernetes_pod_name]
    target_label: pod
EOF
      
      # Write prometheus config to temp file for yq manipulation
      temp_prom_file=$(mktemp)
      echo "$prom_config" > "$temp_prom_file"
      
      # Add the new scrape config using yq
      updated_prom_config=$(yq eval ".scrape_configs += [load(\"$new_scrape_file\")]" "$temp_prom_file")
      
      # Update the ConfigMap
      yq eval ".data.\"prometheus.yml\" = \"$updated_prom_config\"" "$cm_file" | \
        kubectl apply --server-side --field-manager=helm --force-conflicts -f - 2>/dev/null
      
      rm -f "$new_scrape_file" "$temp_prom_file"
    } && {
        info "✓ Postgres-exporter scrape config added to Prometheus ConfigMap"
        rm -f "$cm_file"
        sleep 3  # Wait for configmap-reloader to pick up changes
      } || {
        warn "Failed to update ConfigMap automatically"
        warn "You may need to manually add the scrape config with:"
        warn "  kubectl edit configmap -n $NAMESPACE_OBSERVABILITY prometheus-server"
        rm -f "$cm_file"
      }
  else
    info "✓ Postgres-exporter scrape config already present"
  fi
  
  # Add relabel rule to set job name from service name for kubernetes-service-endpoints
  info "Ensuring job name relabel rule is present for kubernetes-service-endpoints..."
  sleep 2  # Give Prometheus a moment after previous operations
  
  job_relabel_present=$(kubectl get configmap -n "$NAMESPACE_OBSERVABILITY" prometheus-server -o jsonpath='{.data.prometheus\.yaml}' 2>/dev/null | grep -A 5 "job_name: kubernetes-service-endpoints" | grep -c "target_label: job" || echo "0")
  
  if [[ "$job_relabel_present" == "0" ]]; then
    info "Adding job name relabel rule to kubernetes-service-endpoints..."
    
    # Get the ConfigMap
    cm_file=$(mktemp)
    kubectl get configmap -n "$NAMESPACE_OBSERVABILITY" prometheus-server -o yaml > "$cm_file"
    
    # Use yq to add the relabel config
    {
      # Extract prometheus.yml
      prom_config=$(yq eval '.data."prometheus.yml"' "$cm_file")
      
      if [[ -z "$prom_config" ]]; then
        err "prometheus.yml not found in ConfigMap"
        exit 1
      fi
      
      # Check if job relabel already exists
      if echo "$prom_config" | yq eval '.scrape_configs[] | select(.job_name == "kubernetes-service-endpoints") | .relabel_configs[] | select(.target_label == "job" and .source_labels[] == "__meta_kubernetes_service_name")' - >/dev/null 2>&1; then
        info "Job relabel rule already exists"
        exit 0
      fi
      
      # Find the index of kubernetes-service-endpoints job
      job_index=$(echo "$prom_config" | yq eval '.scrape_configs | to_entries | map(select(.value.job_name == "kubernetes-service-endpoints")) | .[0].key' -)
      
      if [[ -z "$job_index" || "$job_index" == "null" ]]; then
        err "kubernetes-service-endpoints job not found"
        exit 1
      fi
      
      # Create the new relabel config file
      new_relabel_file=$(mktemp)
      cat > "$new_relabel_file" <<'EOF'
source_labels: [__meta_kubernetes_service_name]
target_label: job
action: replace
EOF
      
      # Find position to insert: after the address replacement config
      # Look for relabel config with target_label __address__ 
      relabel_count=$(echo "$prom_config" | yq eval ".scrape_configs[$job_index].relabel_configs | length" -)
      insert_pos=$relabel_count
      
      for i in $(seq 0 $((relabel_count - 1))); do
        target_label=$(echo "$prom_config" | yq eval ".scrape_configs[$job_index].relabel_configs[$i].target_label" - 2>/dev/null || echo "")
        if [[ "$target_label" == "__address__" ]]; then
          # Check if it has prometheus_io_port in source_labels
          source_labels_json=$(echo "$prom_config" | yq eval ".scrape_configs[$job_index].relabel_configs[$i].source_labels | @json" - 2>/dev/null || echo "[]")
          if echo "$source_labels_json" | grep -q "prometheus_io_port"; then
            insert_pos=$((i + 1))
            break
          fi
        fi
      done
      
      # Use yq to insert the new relabel config at the calculated position
      # We'll build the array by extracting parts and combining
      temp_config_file=$(mktemp)
      echo "$prom_config" > "$temp_config_file"
      
      # Insert the relabel config using yq
      # Extract existing relabel configs, insert new one, and replace
      updated_prom_config=$(yq eval "
        .scrape_configs[$job_index].relabel_configs as \$relabels |
        \$relabels[0:$insert_pos] + [load(\"$new_relabel_file\")] + \$relabels[$insert_pos:] as \$new_relabels |
        .scrape_configs[$job_index].relabel_configs = \$new_relabels
      " "$temp_config_file")
      
      # Update the ConfigMap
      yq eval ".data.\"prometheus.yml\" = \"$updated_prom_config\"" "$cm_file" | \
        kubectl apply --server-side --field-manager=helm --force-conflicts -f - 2>/dev/null
      
      rm -f "$new_relabel_file" "$temp_config_file"
    } && {
        info "✓ Job name relabel rule added to kubernetes-service-endpoints"
        rm -f "$cm_file"
        sleep 3  # Wait for configmap-reloader to pick up changes
      } || {
        warn "Failed to add job relabel rule automatically"
        warn "You may need to manually add it with:"
        warn "  kubectl edit configmap -n $NAMESPACE_OBSERVABILITY prometheus-server"
        rm -f "$cm_file"
      }
  else
    info "✓ Job name relabel rule already present"
  fi

  # Ensure kubelet/cadvisor metrics carry a `node` label. The dotdc Kubernetes
  # dashboards (k8s_views_nodes etc.) filter per-pod panels by {node="$node"},
  # which kube-prometheus-stack sets via relabeling but the plain prometheus
  # chart does not — without it those panels are silently empty.
  info "Ensuring node label relabel is present on kubelet/cadvisor scrape jobs..."
  node_cm_file=$(mktemp)
  kubectl get configmap -n "$NAMESPACE_OBSERVABILITY" prometheus-server -o yaml > "$node_cm_file"
  node_prom_config=$(yq eval '.data."prometheus.yml"' "$node_cm_file")
  if echo "$node_prom_config" | yq eval -e '[.scrape_configs[] | select(.job_name == "kubernetes-nodes-cadvisor") | .relabel_configs[] | select(.target_label == "node")] | length > 0' - >/dev/null 2>&1; then
    info "✓ Node label relabel already present"
  else
    node_updated_config=$(echo "$node_prom_config" | yq eval '(.scrape_configs[] | select(.job_name == "kubernetes-nodes" or .job_name == "kubernetes-nodes-cadvisor") | .relabel_configs) += [{"source_labels": ["__meta_kubernetes_node_name"], "target_label": "node"}]' -)
    if UPDATED_PROM_CONFIG="$node_updated_config" yq eval '.data."prometheus.yml" = strenv(UPDATED_PROM_CONFIG)' "$node_cm_file" | \
        kubectl apply --server-side --field-manager=helm --force-conflicts -f - >/dev/null 2>&1; then
      info "✓ Node label relabel added to kubernetes-nodes + kubernetes-nodes-cadvisor"
      sleep 3  # Wait for configmap-reloader to pick up changes
    else
      warn "Failed to add node label relabel automatically"
      warn "  kubectl edit configmap -n $NAMESPACE_OBSERVABILITY prometheus-server"
    fi
  fi
  rm -f "$node_cm_file"

  info "✓ Prometheus installed successfully"
  info "  Endpoint: http://prometheus-server.${NAMESPACE_OBSERVABILITY}.svc.cluster.local"
  info "  Configured to scrape postgres-exporter from ${NAMESPACE_POSTGRES} namespace"
  info "  Service metrics will use service name as job label (instead of kubernetes-service-endpoints)"
else
  info "Skipping Prometheus installation (--skip-prometheus)"
fi

# ============================================================================
# Phase 4: Install Grafana (Visualization + Dashboards)
# ============================================================================
if [[ "$SKIP_GRAFANA" != "true" ]]; then
  log "=== Phase 4: Installing Grafana (visualization with dashboards) ==="
  
  # Ensure dashboards exist in-cluster before Grafana starts (idempotent)
  upsert_repo_dashboards || true

  # Grafana admin password. Grafana applies GF_SECURITY_ADMIN_PASSWORD only when it
  # creates its database, so a password generated afresh on every run (as this did)
  # changed secret/grafana but never the stored admin: the two drifted apart, and the
  # admin login and the API calls below failed until reset by hand (2026-10-11).
  # Precedence: GRAFANA_ADMIN_PASSWORD from the environment > the one in the chart's
  # secret/grafana (key admin-password) > generated, on first install only.
  if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    log "Grafana admin password: GRAFANA_ADMIN_PASSWORD from the environment."
  else
    GRAFANA_ADMIN_PASSWORD="$(kubectl -n "$NAMESPACE_OBSERVABILITY" get secret grafana \
      -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [[ -n "$GRAFANA_ADMIN_PASSWORD" ]]; then
      log "Grafana admin password: reusing the one in secret/grafana (admin-password)."
    else
      if command -v openssl >/dev/null 2>&1; then
        GRAFANA_ADMIN_PASSWORD="$(openssl rand -base64 32 | tr -d '\n' | tr -d '=/' | cut -c1-24)"
      else
        GRAFANA_ADMIN_PASSWORD="$(dd if=/dev/urandom bs=1 count=32 2>/dev/null | base64 | tr -d '\n' | tr -d '=/' | cut -c1-24)"
      fi
      log "Grafana admin password: none in secret/grafana yet (first install) - generated one."
    fi
  fi
  
  # Read-only PG role + password secret for the "UCE - shops & activity" dashboard.
  ensure_grafana_pg_readonly || true

  grafana_values=$(mktemp -t grafana-values-XXXX.yaml)
  trap 'rm -f "$grafana_values"' EXIT

  # Postgres-UCE: read-only datasource against the app DB. Powers the
  # "UCE - shops & activity" dashboard. Role, password and grants are provisioned by
  # ensure_grafana_pg_readonly above; the password reaches Grafana as the
  # $UCE_GRAFANA_PG_PASSWORD env var (from secret/${UCE_GRAFANA_PG_SECRET}) so the
  # literal never lands in the rendered ConfigMap.
  #
  # Emitted only when the role actually got provisioned. A datasource whose password
  # never expands is worse than no datasource: every panel returns a connection error
  # instead of an honest "not configured", which is how prod shipped a shops dashboard
  # that showed No data for a month.
  uce_pg_datasource_block=""
  uce_pg_env_block="envValueFrom: {}"
  if [[ "$UCE_PG_DATASOURCE_READY" == "true" ]]; then
    uce_pg_datasource_block="    - name: Postgres-UCE
      type: postgres
      access: proxy
      # \`-rw\` (primary), not \`-ro\`: single-node CNPG cluster has no replicas, so the \`-ro\`
      # service has no endpoints and fails with \"Connection refused\". The role has
      # SELECT-only grants, so pointing at the primary is safe.
      url: postgres-cluster-rw.${NAMESPACE_POSTGRES:-postgres}.svc.cluster.local:5432
      database: ${UCE_PG_DATABASE}
      user: ${UCE_PG_RO_ROLE}
      isDefault: false
      secureJsonData:
        password: \"\$UCE_GRAFANA_PG_PASSWORD\"
      jsonData:
        # The grafana-postgresql-datasource plugin reads the DB name from jsonData.database
        # rather than the top-level field; setting both keeps it portable across plugin versions.
        database: ${UCE_PG_DATABASE}
        sslmode: disable
        postgresVersion: 1600
        timescaledb: false"
    uce_pg_env_block="envValueFrom:
  UCE_GRAFANA_PG_PASSWORD:
    secretKeyRef:
      name: ${UCE_GRAFANA_PG_SECRET}
      key: password"
  else
    warn "Postgres-UCE datasource omitted - the 'UCE - shops & activity' dashboard will have no datasource."
  fi

  cat > "$grafana_values" <<EOF
adminPassword: ${GRAFANA_ADMIN_PASSWORD}

image:
  tag: "${GRAFANA_IMAGE_TAG}"
  sha: "${GRAFANA_IMAGE_SHA}"

${uce_pg_env_block}

# Fix permission issues with local-path storage
securityContext:
  runAsUser: 472
  runAsGroup: 472
  fsGroup: 472
  runAsNonRoot: true

initChownData:
  enabled: false

persistence:
  enabled: true
  size: ${GRAFANA_STORAGE_SIZE}
  storageClassName: ${GRAFANA_STORAGE_CLASS}

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki:3100
      isDefault: true
    - name: Prometheus
      type: prometheus
      access: proxy
      url: http://prometheus-server
      isDefault: false
      jsonData:
        # Must match Prometheus's global scrape_interval (1m). Grafana otherwise
        # assumes 15s, making rate-interval macro windows too small to span two
        # samples — every rate() panel silently renders empty at short ranges.
        timeInterval: 1m
${uce_pg_datasource_block}
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
    - name: 'default'
      orgId: 1
      folder: ''
      type: file
      disableDeletion: false
      editable: true
      options:
        path: /var/lib/grafana/dashboards/default
    - name: 'kubernetes'
      orgId: 1
      folder: 'Kubernetes'
      type: file
      disableDeletion: false
      editable: true
      options:
        path: /var/lib/grafana/dashboards/kubernetes
    - name: 'postgresql'
      orgId: 1
      folder: 'PostgreSQL'
      type: file
      disableDeletion: false
      editable: true
      options:
        path: /var/lib/grafana/dashboards/postgresql
    - name: 'mysql'
      orgId: 1
      folder: 'MySQL'
      type: file
      disableDeletion: false
      editable: true
      options:
        path: /var/lib/grafana/dashboards/mysql

# Watch ConfigMaps labeled grafana_dashboard=1 and write JSON files
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    searchNamespace: ${NAMESPACE_OBSERVABILITY}
    folder: /var/lib/grafana/dashboards/shared
    provider:
      folder: Shared

dashboards:
  default:
    # Loki Logs Dashboard
    loki-logs:
      gnetId: 13639
      revision: 2
      datasource: Loki
  
  kubernetes:
    # Kubernetes Cluster Monitoring (Official)
    kubernetes-cluster:
      gnetId: 7249
      revision: 1
      datasource: Prometheus
    
    # Kubernetes API Server
    kubernetes-apiserver:
      gnetId: 15761
      revision: 16
      datasource: Prometheus
    
    # NOTE: no "Kubernetes Pods" entry. It used to be gnetId 6417, but 6417 is
    # "Kubernetes Cluster (Prometheus)" (uid 4XuMd2Iiz) -- the same dashboard already
    # registered below as kubernetes-cluster-prometheus. The duplicate uid gave the
    # whole \`kubernetes\` provider "no database write permissions because of
    # duplicates", freezing all 17 of its dashboards. The pods dashboard was never
    # actually installed; re-add one only with a gnetId whose uid does not collide.
    
    # Kubernetes Nodes (Detailed)
    kubernetes-nodes:
      gnetId: 15759
      revision: 26
      datasource: Prometheus
    
    # Kubernetes Cluster (Prometheus)
    kubernetes-cluster-prometheus:
      gnetId: 6417
      revision: 1
      datasource: Prometheus
    
    # Kubernetes Resources Namespace
    kubernetes-resources-namespace:
      gnetId: 15758
      revision: 34
      datasource: Prometheus
    
    # Kubernetes Resources Pod
    kubernetes-resources-pod:
      gnetId: 15760
      revision: 28
      datasource: Prometheus
    
    # Kubernetes Resources Cluster
    kubernetes-resources-cluster:
      gnetId: 15757
      revision: 37
      datasource: Prometheus
    
    # NOTE: no "Kubernetes Resources Workload" entry. It used to be gnetId 15762,
    # but 15762 is "Kubernetes / System / CoreDNS" (uid k8s_system_coredns) -- the
    # same dashboard already registered below as kubernetes-coredns, and the second
    # half of the duplicate-uid problem described above. The workload dashboard was
    # never actually installed.
    
    # Kubernetes Persistent Volumes
    kubernetes-persistent-volumes:
      gnetId: 13646
      revision: 2
      datasource: Prometheus
    
    # Kubernetes Networking
    kubernetes-networking-cluster:
      gnetId: 12114
      revision: 1
      datasource: Prometheus
    
    # Kubernetes Networking Namespace
    kubernetes-networking-namespace:
      gnetId: 12125
      revision: 1
      datasource: Prometheus
    
    # Kubernetes Networking Pod
    kubernetes-networking-pod:
      gnetId: 12124
      revision: 1
      datasource: Prometheus
    
    # Node Exporter Full
    node-exporter-full:
      gnetId: 1860
      revision: 37
      datasource: Prometheus
    
    # Kubernetes Deployment Statefulset Daemonset metrics
    kubernetes-deployment-statefulset-daemonset:
      gnetId: 8588
      revision: 1
      datasource: Prometheus
    
    # Kubernetes Ingress
    kubernetes-ingress:
      gnetId: 9614
      revision: 1
      datasource: Prometheus
    
    # Kubernetes CoreDNS
    kubernetes-coredns:
      gnetId: 15762
      revision: 18
      datasource: Prometheus
  
  # NOTE: the \`postgresql\` provider is intentionally empty. It used to pull four
  # dashboards straight from grafana.com by gnetId, and every one of them was
  # broken here:
  #
  #   * 9628 was registered TWICE (postgresql-database rev1 + postgresql-performance
  #     rev2). Both carry uid 000000039, so the provider tripped Grafana's duplicate
  #     check -- "the same UID is used more than once" -> "dashboards provisioning
  #     provider has no database write permissions because of duplicates". The
  #     provider could therefore never update ANY of its dashboards; whatever landed
  #     in the DB first was frozen there.
  #   * 9628 itself keys its template variables off kubernetes_namespace= and
  #     release= labels from an old kube-prometheus scheme this cluster never had.
  #     Both resolved empty, leaving instance=query_result(up{release=""}), and a
  #     ="" matcher matches series LACKING the label -- so it offered all 19 scrape
  #     targets and settled on CoreDNS. Every Postgres panel was empty.
  #   * 14114 and 9628 both use pre-0.15 postgres_exporter bgwriter counter names,
  #     which lost their series when the exporter gained _total suffixes.
  #   * 24298 ("pg_exporter") targets an exporter running a custom queries.yaml and
  #     references 22 metrics we do not emit; only 18 of its 47 queries can resolve.
  #
  # Fixed, validated copies of the two worth keeping are vendored in infra-envs at
  # envs/cit/apps/observability/ and land via the sidecar provider instead, so they
  # are reviewable and pinned rather than re-downloaded from grafana.com. Do not
  # re-add gnetId entries here without checking the uid does not collide.
  postgresql: {}

  mysql:
    # MySQL Overview (Percona) - Connections, queries, InnoDB metrics
    mysql-overview:
      gnetId: 7362
      revision: 5
      datasource: Prometheus

    # MySQL Exporter Quickstart - mysqld-exporter dashboard
    mysql-exporter-quickstart:
      gnetId: 14057
      revision: 1
      datasource: Prometheus

EOF

  # Add GitHub SSO configuration if Dex is available
  if [[ "$SKIP_SSO" != "true" && -n "${DEX_CLIENT_SECRET_GRAFANA:-}" ]]; then
    # GitHub org for the role mapping. secrets.plain is only a local cache and is often
    # stale or missing (secrets.sops is the truth), and a missing org used to drop the
    # whole SSO block with a warning - how prod lost SSO on 2026-08-23. Fall back to the
    # org Dex itself authenticates against (live dex-config; not a secret).
    oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
    github_org="${GITHUB_ORG:-}"
    if [[ -z "$github_org" && -f "$oauth_file" ]]; then
      github_org=$(provision::yaml_get "$oauth_file" .stringData.githubOrg)
    fi
    if [[ -z "$github_org" ]]; then
      github_org=$(kubectl -n "$NAMESPACE_SSO" get configmap dex-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
        | yq eval '[.connectors[] | select(.type == "github") | .config.orgs[0].name][0] // ""' - 2>/dev/null || true)
      [[ -n "$github_org" ]] && info "GitHub org for Grafana roles taken from the live Dex config: ${github_org}"
    fi

    if [[ -n "$github_org" && -n "$DEX_HOST" ]]; then
      log "Configuring GitHub SSO via Dex ..."
      
      # Create a secret for the Dex client secret
      kubectl -n "$NAMESPACE_OBSERVABILITY" create secret generic grafana-dex-secret \
        --from-literal=client-secret="${DEX_CLIENT_SECRET_GRAFANA}" \
        --dry-run=client -o yaml | kubectl apply -f -
      
      cat >> "$grafana_values" <<EOF

envFromSecret: grafana-dex-secret

grafana.ini:
  server:
    # Explicit: the chart derives domain from its ingress, and behind Pomerium there is none.
    domain: ${GRAFANA_HOST}
    root_url: https://${GRAFANA_HOST}
  auth.generic_oauth:
    enabled: "true"
    name: "GitHub SSO"
    allow_sign_up: "true"
    client_id: "grafana"
    client_secret: "\$__env{client-secret}"
    scopes: "openid profile email groups"
    auth_url: "https://${DEX_HOST}/auth"
    token_url: "https://${DEX_HOST}/token"
    api_url: "https://${DEX_HOST}/userinfo"
    role_attribute_path: "contains(groups[*], '${github_org}:admins') && 'Admin' || contains(groups[*], '${github_org}') && 'Editor' || 'Viewer'"
    role_attribute_strict: "false"
    allow_assign_grafana_admin: "true"
EOF
      
      info "✓ GitHub SSO configured for Grafana"
      info "  Organization: ${github_org}"
      info "  Dex issuer: https://${DEX_HOST}"
    else
      warn "GitHub org or DEX_HOST not configured. Skipping SSO setup."
    fi
  fi
  
  # With Pomerium in the sso namespace the UI goes through it (ensure_grafana_pomerium, after
  # the install) and the chart gets no ingress; without it the chart's ingress exposes Grafana.
  GRAFANA_VIA_POMERIUM=false
  if [[ -n "${GRAFANA_HOST:-}" ]] && kubectl -n "$NAMESPACE_SSO" get svc pomerium-proxy >/dev/null 2>&1; then
    GRAFANA_VIA_POMERIUM=true
    info "Grafana will be exposed at: https://${GRAFANA_HOST}/ (behind Pomerium)"
  elif [[ -n "${GRAFANA_HOST:-}" ]]; then
    cat >> "$grafana_values" <<EOF

ingress:
  enabled: true
  ingressClassName: ${INGRESS_CLASS}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    cert-manager.io/common-name: ${GRAFANA_HOST}
  hosts:
    - ${GRAFANA_HOST}
  tls:
    - secretName: grafana-tls
      hosts:
        - ${GRAFANA_HOST}
EOF
    info "Grafana will be exposed at: https://${GRAFANA_HOST}/"
  fi
  
  # The values above are rebuilt from scratch on every run, so anything this run could
  # not re-derive would silently vanish from the release (Dex SSO, the Postgres-UCE
  # datasource). Refuse to upgrade when the live release has something the new values
  # lack; ALLOW_GRAFANA_REGRESSION=true accepts the loss deliberately.
  grafana_values_guard "$grafana_values"

  log "Installing Grafana (this may take a few minutes)..."
  helm upgrade --install grafana grafana/grafana \
    --version "$GRAFANA_CHART_VERSION" \
    --namespace "$NAMESPACE_OBSERVABILITY" \
    --wait \
    --timeout 15m \
    -f "$grafana_values" || {
      warn "Grafana Helm install timed out or failed. Checking status..."
      kubectl -n "$NAMESPACE_OBSERVABILITY" get pods -l app.kubernetes.io/name=grafana
    }

  # Best-effort restart to ensure dashboard sidecar picks up changes immediately
  kubectl -n "$NAMESPACE_OBSERVABILITY" rollout restart deploy/grafana >/dev/null 2>&1 || true
  sleep 2
  
  log "Waiting for Grafana to be ready ..."
  kubectl -n "$NAMESPACE_OBSERVABILITY" rollout status deploy/grafana --timeout=300s || true

  ensure_grafana_admin_login || true

  if $GRAFANA_VIA_POMERIUM; then
    ensure_grafana_pomerium
  fi

  # mcp-grafana (envs/<env>/apps/observability/mcp-grafana.yaml, behind a Pomerium MCP
  # route) reads Grafana with a Viewer service-account token from the Secret
  # mcp-grafana-token. Opt in per env with GRAFANA_MCP=true: the service account is
  # ensured on every run, a token is minted (and SOPS-encrypted into the envs repo)
  # only when the Secret is missing or Grafana refuses its token.
  if [[ "${GRAFANA_MCP:-false}" == "true" ]]; then
    log "Ensuring the mcp-grafana service account and token (GRAFANA_MCP=true) ..."
    NAMESPACE_OBSERVABILITY="$NAMESPACE_OBSERVABILITY" \
      "$REPO_ROOT/tools/k3s/grafana-mcp-token.sh" "$ENV_NAME" --ensure || \
      warn "mcp-grafana token step failed; retry: tools/k3s/grafana-mcp-token.sh ${ENV_NAME} --ensure"
  fi
  
  info "✓ Grafana installed successfully"
  if [[ -n "${GRAFANA_HOST:-}" ]]; then
    info "  URL: https://${GRAFANA_HOST}/"
  fi
  info "  Admin: admin (password in secret/grafana, key admin-password)"
  info "  Dashboards: 20+ Kubernetes dashboards pre-configured"
else
  info "Skipping Grafana installation (--skip-grafana)"
fi

# ============================================================================
# Summary
# ============================================================================
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  Observability Stack Provisioning Complete"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""
log "Environment: ${ENV_NAME}"
log "Namespace: ${NAMESPACE_OBSERVABILITY}"
log ""

if [[ "$SKIP_LOKI" != "true" ]]; then
  log "✓ Loki (log aggregation)"
  log "  Endpoint: http://loki.${NAMESPACE_OBSERVABILITY}.svc.cluster.local:3100"
  log "  Storage: ${LOKI_STORAGE_SIZE} (${LOKI_STORAGE_CLASS})"
fi

if [[ "$SKIP_PROMTAIL" != "true" ]]; then
  log "✓ Promtail (log shipper)"
  log "  Shipping to: http://loki:3100/loki/api/v1/push"
fi

if [[ "$SKIP_PROMETHEUS" != "true" ]]; then
  log "✓ Prometheus (metrics collection)"
  log "  Endpoint: http://prometheus-server.${NAMESPACE_OBSERVABILITY}.svc.cluster.local"
  log "  Storage: ${PROMETHEUS_STORAGE_SIZE} (${PROMETHEUS_STORAGE_CLASS})"
  log "  ServiceMonitor CRD: Installed (applications can use ServiceMonitor resources)"
fi

if [[ "$SKIP_GRAFANA" != "true" ]]; then
  log "✓ Grafana (visualization)"
  if [[ -n "${GRAFANA_HOST:-}" ]]; then
    log "  URL: https://${GRAFANA_HOST}/"
  fi
  log "  Admin: admin (password: kubectl -n ${NAMESPACE_OBSERVABILITY} get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
  log "  Storage: ${GRAFANA_STORAGE_SIZE} (${GRAFANA_STORAGE_CLASS})"
  
  if [[ "$SKIP_SSO" != "true" && -n "${DEX_CLIENT_SECRET_GRAFANA:-}" ]]; then
    log "  SSO: Enabled (GitHub via Dex)"
  else
    log "  SSO: Disabled"
  fi
  
  log ""
  log "Pre-configured Dashboards:"
  log "  • Loki Logs (13639)"
  log "  • Kubernetes Cluster (7249)"
  log "  • Kubernetes API Server (15761)"
  log "  • Kubernetes Pods (6417)"
  log "  • Kubernetes Nodes (15759)"
  log "  • Kubernetes Resources - Namespace (15758)"
  log "  • Kubernetes Resources - Pod (15760)"
  log "  • Kubernetes Resources - Cluster (15757)"
  log "  • Kubernetes Resources - Workload (15762)"
  log "  • Kubernetes Persistent Volumes (13646)"
  log "  • Kubernetes Networking - Cluster (12114)"
  log "  • Kubernetes Networking - Namespace (12125)"
  log "  • Kubernetes Networking - Pod (12124)"
  log "  • Node Exporter Full (1860)"
  log "  • Kubernetes Deployments/StatefulSets/DaemonSets (8588)"
  log "  • Kubernetes Ingress (9614)"
  log "  • Kubernetes CoreDNS (15762)"
fi

if [[ "$SKIP_PROMETHEUS" != "true" ]]; then
  log ""
  log "PostgreSQL Dashboards:"
  log "  • PostgreSQL Overview (14114) - Database sizes, connections, cache hit ratio"
  log "  • PostgreSQL Database (9628) - Detailed database metrics"
  log "  • PostgreSQL Monitoring (24298) - Comprehensive monitoring with buffer/index metrics"
  log "  • PostgreSQL Performance (9628) - Buffer cache, indices, query performance"
fi

log ""
log "Next steps:"
log "  1. Access Grafana at https://${GRAFANA_HOST:-<GRAFANA_HOST>}/"
log "  2. Log in with GitHub SSO"
log "  3. Explore pre-configured Kubernetes dashboards"
log "  4. View logs in Loki datasource"
log "  5. Monitor metrics in Prometheus datasource"
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
