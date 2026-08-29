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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-loki) SKIP_LOKI=true; shift ;;
    --skip-promtail) SKIP_PROMTAIL=true; shift ;;
    --skip-prometheus) SKIP_PROMETHEUS=true; shift ;;
    --skip-grafana) SKIP_GRAFANA=true; shift ;;
    --skip-dns) SKIP_DNS=true; shift ;;
    --skip-sso) SKIP_SSO=true; shift ;;
    --sync-dashboards) SYNC_DASHBOARDS=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

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
# SMTP relay used by Alertmanager — Resend by default, but any SMTP relay works.
# The `resend-api-key` Secret in $NAMESPACE_OBSERVABILITY (applied via SOPS) is
# mounted at /etc/alertmanager/resend-key/api_key and read via
# smtp_auth_password_file.
ALERTMANAGER_SMTP_HOST="${ALERTMANAGER_SMTP_HOST:-smtp.resend.com:465}"

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
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-7.1.0}"
PROMTAIL_CHART_VERSION="${PROMTAIL_CHART_VERSION:-6.17.1}"
PROMETHEUS_CHART_VERSION="${PROMETHEUS_CHART_VERSION:-29.27.0}"
GRAFANA_CHART_VERSION="${GRAFANA_CHART_VERSION:-10.5.15}"
BLACKBOX_CHART_VERSION="${BLACKBOX_CHART_VERSION:-11.17.2}"
PROMETHEUS_OPERATOR_CRDS_CHART_VERSION="${PROMETHEUS_OPERATOR_CRDS_CHART_VERSION:-9.3.2}"

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
  
  cat > "$loki_values" <<EOF
deploymentMode: SingleBinary

loki:
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
if [[ "$SKIP_PROMTAIL" != "true" ]]; then
  log "=== Phase 2: Installing Promtail (log shipper) ==="
  
  promtail_values=$(mktemp -t promtail-values-XXXX.yaml)
  trap 'rm -f "$promtail_values"' EXIT
  cat > "$promtail_values" <<EOF
config:
  clients:
    - url: http://loki:3100/loki/api/v1/push
  snippets:
    pipelineStages:
      - cri: {}
      # NOTE: there used to be a `match { selector: '{app="uce"}' }` stage here that
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
  info "  shop_id label extraction enabled for app=uce"
else
  info "Skipping Promtail installation (--skip-promtail)"
fi

# ============================================================================
# Phase 3a: Install Prometheus Operator CRDs (for ServiceMonitor support)
# ============================================================================
if [[ "$SKIP_PROMETHEUS" != "true" ]]; then
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
            expr: pg_database_size_bytes > 40 * 1024 * 1024 * 1024
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
  if kubectl -n default get secret resend-api-key >/dev/null 2>&1; then
    if ! kubectl -n "$NAMESPACE_OBSERVABILITY" get secret resend-api-key >/dev/null 2>&1; then
      info "Mirroring resend-api-key from default → ${NAMESPACE_OBSERVABILITY} for Alertmanager SMTP"
      kubectl -n default get secret resend-api-key -o yaml \
        | sed -E 's/^(  namespace:).*/\1 '"$NAMESPACE_OBSERVABILITY"'/; /(resourceVersion|uid|creationTimestamp):/d' \
        | kubectl -n "$NAMESPACE_OBSERVABILITY" apply -f - >/dev/null
    fi
  else
    warn "resend-api-key Secret not found in 'default' namespace."
    warn "Alertmanager pod will stay in CreateContainerConfigError until you apply it:"
    warn "  sops -d \$INFRA_ENVS_ROOT/${ENV_NAME}/secrets.sops/resend-api-key.yaml | kubectl apply -f -"
    warn "Then re-run this script (or kubectl -n default get secret resend-api-key -o yaml | "
    warn "  kubectl -n ${NAMESPACE_OBSERVABILITY} apply -f -)."
  fi

  # Alertmanager also mounts the alertmanager-telegram secret unconditionally, so a
  # missing one wedges the pod exactly like a missing resend-api-key. An env
  # provisioned without either has no Alertmanager at all — and nothing pages when
  # a public site goes down, which is exactly how such a gap gets discovered.
  if ! kubectl -n "$NAMESPACE_OBSERVABILITY" get secret alertmanager-telegram >/dev/null 2>&1; then
    warn "alertmanager-telegram Secret not found in '${NAMESPACE_OBSERVABILITY}' namespace."
    warn "Alertmanager will not start, so NO alert of any severity will be delivered."
    warn "Apply it before relying on alerting:"
    warn "  sops -d \$INFRA_ENVS_ROOT/${ENV_NAME}/secrets.sops/alertmanager-telegram.yaml | kubectl apply -f -"
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
  if [[ -n "$PROBE_TARGETS" || -n "$PROBE_TARGETS_POST" ]]; then
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

  # Generate Grafana admin password if not provided
  if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      GRAFANA_ADMIN_PASSWORD="$(openssl rand -base64 32 | tr -d '\n' | tr -d '=/' | cut -c1-24)"
    else
      GRAFANA_ADMIN_PASSWORD="$(dd if=/dev/urandom bs=1 count=32 2>/dev/null | base64 | tr -d '\n' | tr -d '=/' | cut -c1-24)"
    fi
    log "Generated GRAFANA_ADMIN_PASSWORD for this run."
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
    # whole `kubernetes` provider "no database write permissions because of
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
  
  # NOTE: the `postgresql` provider is intentionally empty. It used to pull four
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

    # MySQL InnoDB Metrics - Buffer pool, I/O, transactions
    mysql-innodb:
      gnetId: 7564
      revision: 1
      datasource: Prometheus

    # MySQL Exporter Quickstart - mysqld-exporter dashboard
    mysql-exporter-quickstart:
      gnetId: 14057
      revision: 1
      datasource: Prometheus

EOF

  # Add GitHub SSO configuration if Dex is available
  if [[ "$SKIP_SSO" != "true" && -n "${DEX_CLIENT_SECRET_GRAFANA:-}" ]]; then
    # Load GitHub org from OAuth credentials
    oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
    github_org=""
    if [[ -f "$oauth_file" ]]; then
      github_org=$(provision::yaml_get "$oauth_file" .stringData.githubOrg)
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
  
  # Add Ingress configuration if GRAFANA_HOST is set
  if [[ -n "${GRAFANA_HOST:-}" ]]; then
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
  
  info "✓ Grafana installed successfully"
  if [[ -n "${GRAFANA_HOST:-}" ]]; then
    info "  URL: https://${GRAFANA_HOST}/"
  fi
  info "  Admin credentials: admin / ${GRAFANA_ADMIN_PASSWORD}"
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
  log "  Admin: admin / ${GRAFANA_ADMIN_PASSWORD}"
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
log "  2. Log in with admin credentials or GitHub SSO"
log "  3. Explore pre-configured Kubernetes dashboards"
log "  4. View logs in Loki datasource"
log "  5. Monitor metrics in Prometheus datasource"
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
