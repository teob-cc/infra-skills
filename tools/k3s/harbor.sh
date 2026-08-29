#!/usr/bin/env bash
set -euo pipefail

# Registry provisioning script for Kubernetes clusters.
# Provisions Harbor container registry with Dex SSO integration.
#
# Prerequisites:
#   - identity.sh must have been run first (provides Dex SSO)
#   - cert-manager must be installed
#   - Dex client secret for Harbor must exist
#
# Usage:
#   tools/k3s/harbor.sh <env-name>

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

# --- Parse arguments ---
if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name>" >&2
  echo "Available environments:" >&2
  find "$(provision::envs_root)" -maxdepth 2 -type f -name env.properties -print | sed "s#$(provision::envs_root)/##; s#/env.properties##" | sort || true
  exit 1
fi

if provision::load_env "${1:-}"; then
  shift
else
  echo "ERROR: Environment '$1' not found (envs/$1/env.properties missing)." >&2
  exit 1
fi

# --- Validation ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
need kubectl
need helm
need curl
need jq

if ! provision::require_tools; then
  exit 1
fi

# Validate kubectl context matches environment
if ! provision::validate_kubectl_context; then
  exit 1
fi

# --- Logging helpers ---
log() { echo "[registry] $*"; }
info() { echo "[registry:info] $*"; }
warn() { echo "[registry:warn] $*" >&2; }
err() { echo "[registry:error] $*" >&2; }

# --- Config defaults ---
NAMESPACE_HARBOR="${NAMESPACE_HARBOR:-harbor}"
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"

# Derive hosts from HOSTNAME if not provided
if [[ -n "${HOSTNAME:-}" ]]; then
  HARBOR_HOST="${HARBOR_HOST:-harbor.${HOSTNAME}}"
  DEX_HOST="${DEX_HOST:-dex.${HOSTNAME}}"
  
  info "Service hosts:"
  info "  HARBOR_HOST=${HARBOR_HOST}"
  info "  DEX_HOST=${DEX_HOST}"
fi

# Validate required configuration
if [[ -z "${HARBOR_HOST:-}" ]]; then
  err "HARBOR_HOST is not set. Set HOSTNAME in env.properties or HARBOR_HOST explicitly."
  exit 1
fi

if [[ -z "${DEX_HOST:-}" ]]; then
  err "DEX_HOST is not set. Set HOSTNAME in env.properties or DEX_HOST explicitly."
  exit 1
fi

if [[ -z "${EXTERNAL_IP:-}" ]]; then
  err "EXTERNAL_IP is not set in env.properties"
  exit 1
fi

if [[ -z "${HARBOR_ADMIN_PASSWORD:-}" ]]; then
  info "HARBOR_ADMIN_PASSWORD not set - generating random password..."
  HARBOR_ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -d '\n')
  info "Generated Harbor admin password (length: ${#HARBOR_ADMIN_PASSWORD})"
  info "This password will be stored in Harbor's secret and can be retrieved with:"
  info "  kubectl -n harbor get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d"
fi

log "Starting Registry provisioning for environment: ${ENV_NAME}"

# ============================================================================
# Phase 0: Prerequisites Validation
# ============================================================================

validate_prerequisites() {
  log "=== Phase 0: Prerequisites Validation ==="
  
  local validation_failed=false
  
  # Check if Dex is deployed
  info "Checking Dex SSO..."
  if ! kubectl get ns "$NAMESPACE_SSO" >/dev/null 2>&1; then
    err "Namespace ${NAMESPACE_SSO} not found. Run identity.sh first."
    validation_failed=true
  elif ! kubectl -n "$NAMESPACE_SSO" get deploy dex >/dev/null 2>&1; then
    err "Dex deployment not found in ${NAMESPACE_SSO}. Run identity.sh first."
    validation_failed=true
  else
    info "  ✓ Dex is deployed"
  fi
  
  # Check cert-manager
  info "Checking cert-manager..."
  if kubectl get clusterissuer letsencrypt-prod >/dev/null 2>&1; then
    info "  ✓ ClusterIssuer 'letsencrypt-prod' exists"
  else
    warn "  ⚠ ClusterIssuer 'letsencrypt-prod' not found. TLS certificates may not be issued."
  fi
  
  if [[ "$validation_failed" == "true" ]]; then
    err ""
    err "Prerequisites validation failed. Please run identity.sh first:"
    err "  tools/k3s/identity.sh ${ENV_NAME}"
    exit 1
  fi
  
  info "✓ All prerequisites validated"
}

validate_prerequisites

# ============================================================================
# Phase 1: DNS Management
# ============================================================================

ensure_dns_records() {
  log "=== Phase 1: DNS Management ==="
  
  if ! provision::cloudflare_read_token 2>/dev/null; then
    warn "Cloudflare API token not found. Skipping DNS record creation."
    warn "DNS records must be created manually or via other means."
    return 0
  fi
  
  # Check for wildcard DNS record
  if [[ -n "${HOSTNAME:-}" ]] && provision::cloudflare_check_wildcard "$HOSTNAME"; then
    info "Wildcard DNS record found: ${WILDCARD_PATTERN} -> ${WILDCARD_IP}"
    info "Wildcard DNS covers Harbor - skipping individual record creation"
  else
    # Create DNS record for Harbor
    if [[ -n "${HARBOR_HOST:-}" ]]; then
      provision::cloudflare_ensure_dns_record "$HARBOR_HOST" "$EXTERNAL_IP" || \
        warn "Failed to create DNS record for $HARBOR_HOST"
    fi
  fi
  
  info "✓ DNS records ensured"
}

ensure_dns_records

# ============================================================================
# Phase 2: Register Dex Client for Harbor
# ============================================================================

register_dex_client() {
  log "=== Phase 2: Register Dex Client for Harbor ==="
  
  # Register Harbor as a Dex client
  local redirect_uris="https://${HARBOR_HOST}/c/oidc/callback"
  local dex_client_secret
  
  dex_client_secret=$(provision::dex_register_client "harbor" "Harbor" "$redirect_uris" "$NAMESPACE_SSO") || {
    err "Failed to register Dex client for Harbor"
    exit 1
  }
  
  # Export for use in Harbor configuration
  export DEX_CLIENT_SECRET="$dex_client_secret"
  
  info "✓ Dex client registered for Harbor"
  info "  Redirect URI: ${redirect_uris}"
}

register_dex_client

# ============================================================================
# Phase 3: Harbor Installation
# ============================================================================

install_harbor() {
  log "=== Phase 3: Harbor Installation ==="
  
  # Create namespace
  kubectl get ns "$NAMESPACE_HARBOR" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_HARBOR"
  
  # Add Harbor Helm repository
  if ! helm repo list 2>/dev/null | grep -q "goharbor"; then
    info "Adding Harbor Helm repository..."
    helm repo add goharbor https://helm.goharbor.io
  fi
  helm repo update goharbor
  
  # Check if TLS secret already exists to prevent rate limiting
  local tls_secret_name="${TLS_SECRET_NAME:-harbor-tls}"
  if kubectl -n "$NAMESPACE_HARBOR" get secret "$tls_secret_name" >/dev/null 2>&1; then
    info "TLS secret '$tls_secret_name' already exists - will reuse it"
  fi
  
  # Storage configuration with defaults
  local registry_size="${REGISTRY_SIZE:-50Gi}"
  local chartmuseum_size="${CHARTMUSEUM_SIZE:-5Gi}"
  local jobservice_size="${JOBSERVICE_SIZE:-1Gi}"
  local database_size="${DATABASE_SIZE:-10Gi}"
  local redis_size="${REDIS_SIZE:-2Gi}"
  local trivy_size="${TRIVY_SIZE:-5Gi}"
  local storage_class="${HARBOR_STORAGE_CLASS:-local-path}"
  local ingress_class="${INGRESS_CLASS:-traefik}"
  local cluster_issuer="${CLUSTER_ISSUER:-letsencrypt-prod}"
  
  # Check if Harbor is already installed to avoid re-provisioning ingress
  if helm list -n "$NAMESPACE_HARBOR" 2>/dev/null | grep -q "^harbor"; then
    info "Harbor already installed - updating without modifying ingress..."
    
    # Update Harbor without touching ingress configuration to avoid cert-manager rate limits
    helm upgrade --install harbor goharbor/harbor \
      --namespace "$NAMESPACE_HARBOR" \
      --wait \
      --timeout 15m \
      --reuse-values \
      --set harborAdminPassword="$HARBOR_ADMIN_PASSWORD" \
      --set persistence.enabled=true \
      --set persistence.resourcePolicy=keep
    
    info "  Note: Ingress not updated to avoid cert-manager rate limits"
  else
    info "Installing Harbor via Helm (first installation)..."
    info "  External URL: https://${HARBOR_HOST}"
    info "  Storage class: ${storage_class}"
    info "  Registry size: ${registry_size}"
    
    helm upgrade --install harbor goharbor/harbor \
      --namespace "$NAMESPACE_HARBOR" \
      --create-namespace \
      --wait \
      --timeout 15m \
      --set expose.type=ingress \
      --set expose.ingress.hosts.core="$HARBOR_HOST" \
      --set expose.ingress.ingressClassName="${ingress_class}" \
      --set expose.ingress.annotations."cert-manager\.io/cluster-issuer"="${cluster_issuer}" \
      --set expose.ingress.annotations."cert-manager\.io/common-name"="$HARBOR_HOST" \
      --set-string expose.ingress.annotations."acme\.cert-manager\.io/http01-edit-in-place"="true" \
      --set expose.tls.enabled=true \
      --set expose.tls.secretName="${tls_secret_name}" \
      --set externalURL="https://$HARBOR_HOST" \
      --set harborAdminPassword="$HARBOR_ADMIN_PASSWORD" \
      --set persistence.enabled=true \
      --set persistence.resourcePolicy=keep \
      --set persistence.imageChartStorage.type=filesystem \
      --set persistence.persistentVolumeClaim.registry.storageClass="${storage_class}" \
      --set persistence.persistentVolumeClaim.registry.size="${registry_size}" \
      --set persistence.persistentVolumeClaim.chartmuseum.storageClass="${storage_class}" \
      --set persistence.persistentVolumeClaim.chartmuseum.size="${chartmuseum_size}" \
      --set persistence.persistentVolumeClaim.jobservice.storageClass="${storage_class}" \
      --set persistence.persistentVolumeClaim.jobservice.size="${jobservice_size}" \
      --set persistence.persistentVolumeClaim.database.storageClass="${storage_class}" \
      --set persistence.persistentVolumeClaim.database.size="${database_size}" \
      --set persistence.persistentVolumeClaim.redis.storageClass="${storage_class}" \
      --set persistence.persistentVolumeClaim.redis.size="${redis_size}" \
      --set trivy.enabled=true \
      --set trivy.vulnerabilityReports.scannerReportsPersistence.enabled=true \
      --set trivy.resources.requests.cpu="100m" \
      --set trivy.resources.requests.memory="256Mi" \
      --set persistence.persistentVolumeClaim.trivy.storageClass="${storage_class}" \
      --set persistence.persistentVolumeClaim.trivy.size="${trivy_size}" \
      --set notary.enabled="${NOTARY_ENABLED:-false}"
  fi
  
  info "Waiting for Harbor core components to be ready..."
  kubectl -n "$NAMESPACE_HARBOR" rollout status deploy -l "app.kubernetes.io/instance=harbor" --timeout=600s || true
  
  info "✓ Harbor installed successfully"
}

install_harbor

# ============================================================================
# Phase 4: Harbor Configuration
# ============================================================================

# Helper function to configure Harbor resources (registry, projects, robot account)
configure_harbor_resources() {
  local admin_password="$1"
  local api_url="$2"
  local curl_args=(-sS -k)
  
  # Create Docker Hub registry endpoint
  info "Creating Docker Hub proxy registry endpoint..."
  local registry_payload
  registry_payload=$(cat <<'EOF'
{
  "name": "dockerhub",
  "type": "docker-hub",
  "url": "https://hub.docker.com",
  "description": "Docker Hub proxy cache",
  "insecure": false,
  "credential": {
    "type": "basic",
    "access_key": "",
    "access_secret": ""
  }
}
EOF
)
  
  local registry_response registry_http_code registry_body registry_id
  registry_response=$(curl "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
    -u "admin:${admin_password}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "${registry_payload}" \
    "${api_url}/registries" 2>&1 || echo -e "\n000")
  
  registry_http_code=$(echo "$registry_response" | tail -n 1)
  registry_body=$(echo "$registry_response" | sed '$d')
  
  registry_id=""
  if [[ "$registry_http_code" == "201" ]]; then
    info "✓ Docker Hub registry endpoint created"
  elif [[ "$registry_http_code" == "409" ]]; then
    info "✓ Docker Hub registry endpoint already exists"
  else
    warn "Failed to create Docker Hub registry endpoint (HTTP ${registry_http_code})"
    warn "Response: ${registry_body}"
  fi

  # Always resolve registry_id via GET to avoid relying on POST response body
  registry_id=$(curl "${curl_args[@]}" --max-time 10 \
    -u "admin:${admin_password}" \
    "${api_url}/registries?page_size=100" 2>/dev/null | jq -r '.[] | select(.name == "dockerhub") | .id' 2>/dev/null || true)
  if [[ -n "$registry_id" && "$registry_id" != "null" ]]; then
    info "  Resolved dockerhub registry ID: ${registry_id}"
  else
    err "  Unable to resolve dockerhub registry ID. Cannot continue with proxy cache configuration."
    return 1
  fi
  
  # Create Docker Hub proxy cache project
  info "Creating Docker Hub proxy cache project..."
  info "  Using registry_id: ${registry_id:-<empty>}"
  
  if [[ -z "$registry_id" || "$registry_id" == "null" ]]; then
    err "Registry ID not available - cannot create proxy cache project"
    err "Please ensure Docker Hub registry endpoint was created successfully"
    err "Debug: registry_id='${registry_id}'"
    return 1
  else
    local proxy_payload
    proxy_payload=$(cat <<EOF
{
  "project_name": "dockerhub-proxy",
  "metadata": {
    "public": "true"
  },
  "registry_id": ${registry_id},
  "storage_limit": -1
}
EOF
)
    info "  Project payload: ${proxy_payload}"
    
    local proxy_response proxy_http_code proxy_body
    proxy_response=$(curl "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
      -u "admin:${admin_password}" \
      -H "Content-Type: application/json" \
      -X POST \
      -d "${proxy_payload}" \
      "${api_url}/projects" 2>&1 || echo -e "\n000")
    
    proxy_http_code=$(echo "$proxy_response" | tail -n 1)
    proxy_body=$(echo "$proxy_response" | sed '$d')
    
    if [[ "$proxy_http_code" == "201" ]]; then
      info "✓ Docker Hub proxy cache project created (registry_id: ${registry_id})"
    elif [[ "$proxy_http_code" == "409" ]]; then
      info "✓ Docker Hub proxy cache project already exists"
      # Verify it's configured as proxy cache and patch if necessary
      local project_info project_id project_registry_id
      project_info=$(curl "${curl_args[@]}" --max-time 10 \
        -u "admin:${admin_password}" \
        "${api_url}/projects?name=dockerhub-proxy" 2>/dev/null || true)
      project_id=$(echo "$project_info" | jq -r '.[0].project_id // empty' 2>/dev/null || true)
      project_registry_id=$(echo "$project_info" | jq -r '.[0].registry_id // empty' 2>/dev/null || true)

      if [[ -z "$project_id" || "$project_id" == "null" ]]; then
        warn "  Unable to determine project_id for dockerhub-proxy"
      elif [[ "$project_registry_id" != "$registry_id" ]]; then
        info "  Project is not linked to Docker Hub registry (current registry_id: ${project_registry_id:-<unset>}). Patching..."
        local patch_payload patch_response patch_http_code patch_body
        patch_payload=$(cat <<EOF
{
  "project_name": "dockerhub-proxy",
  "metadata": {
    "public": "true"
  },
  "registry_id": ${registry_id},
  "storage_limit": -1
}
EOF
)
        info "  Patch payload: ${patch_payload}"
        patch_response=$(curl "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
          -u "admin:${admin_password}" \
          -H "Content-Type: application/json" \
          -X PUT \
          -d "${patch_payload}" \
          "${api_url}/projects/${project_id}" 2>&1 || echo -e "\n000")
        patch_http_code=$(echo "$patch_response" | tail -n 1)
        patch_body=$(echo "$patch_response" | sed '$d')

        if [[ "$patch_http_code" == "200" || "$patch_http_code" == "204" ]]; then
          info "  ✓ Updated dockerhub-proxy project to use registry_id ${registry_id}"
        else
          err "  Failed to patch dockerhub-proxy project (HTTP ${patch_http_code})"
          err "  Response: ${patch_body}"
        fi
      else
        info "  Confirmed as proxy cache (registry_id: ${project_registry_id})"
      fi
    else
      err "Failed to create Docker Hub proxy cache project (HTTP ${proxy_http_code})"
      err "Response: ${proxy_body}"
      err ""
      err "Manual recovery - run this command:"
      err "  curl -k -u admin:PASSWORD -H 'Content-Type: application/json' -X POST \\"
      err "    -d '{\"project_name\":\"dockerhub-proxy\",\"metadata\":{\"public\":\"true\"},\"registry_id\":${registry_id},\"storage_limit\":-1}' \\"
      err "    https://${HARBOR_HOST}/api/v2.0/projects"
    fi
  fi
  
  # Create robot account
  info "Creating robot account 'runner' for GitHub Actions..."
  local robot_payload
  robot_payload=$(cat <<'EOF'
{
  "name": "runner",
  "description": "Robot account for GitHub Actions runners",
  "duration": -1,
  "level": "system",
  "permissions": [
    {
      "kind": "project",
      "namespace": "*",
      "access": [
        {"resource": "repository", "action": "push"},
        {"resource": "repository", "action": "pull"},
        {"resource": "artifact", "action": "delete"},
        {"resource": "artifact", "action": "read"},
        {"resource": "artifact", "action": "list"}
      ]
    }
  ]
}
EOF
)
  
  local robot_response robot_http_code robot_body
  robot_response=$(curl "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
    -u "admin:${admin_password}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "${robot_payload}" \
    "${api_url}/robots" 2>&1 || echo -e "\n000")
  
  robot_http_code=$(echo "$robot_response" | tail -n 1)
  robot_body=$(echo "$robot_response" | sed '$d')
  
  if [[ "$robot_http_code" == "201" ]]; then
    local robot_name robot_secret
    robot_name=$(echo "$robot_body" | jq -r '.name // empty')
    robot_secret=$(echo "$robot_body" | jq -r '.secret // empty')
    
    info "✓ Robot account created: ${robot_name}"
    
    # Store credentials in Kubernetes secret
    kubectl -n "$NAMESPACE_HARBOR" create secret generic harbor-robot-runner \
      --from-literal=username="${robot_name}" \
      --from-literal=password="${robot_secret}" \
      --dry-run=client -o yaml | kubectl apply -f -
    
    info "  Robot credentials stored in harbor/harbor-robot-runner secret"
    info "  Username: ${robot_name}"
  elif [[ "$robot_http_code" == "409" ]]; then
    info "✓ Robot account 'runner' already exists"
    if kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner >/dev/null 2>&1; then
      local robot_name
      robot_name=$(kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner -o jsonpath='{.data.username}' | base64 -d)
      info "  Retrieved robot credentials from harbor/harbor-robot-runner secret"
      info "  Username: ${robot_name}"
    fi
  else
    err "Failed to create robot account (HTTP ${robot_http_code})"
    err "Response: ${robot_body}"
  fi
}

# Helper function: tag-retention policy + garbage-collection schedule.
# CI pushes a fresh image tag on every deploy; without this they accumulate
# forever on the registry PVC (and pile up in the nodes' containerd cache).
# Keeps the last K artifacts per repo in the `library` project and runs GC
# weekly to actually purge the blobs of everything retention/delete drops.
# Override the count with HARBOR_RETAIN_LAST_K (default 10).
configure_harbor_retention_gc() {
  local admin_password="$1"
  local api_url="$2"
  local curl_args=(-sS -k)
  local keep_last="${HARBOR_RETAIN_LAST_K:-10}"

  info "Configuring Harbor tag retention (keep last ${keep_last} per repo) + weekly GC..."

  # --- Tag-retention policy on the default `library` project ---
  local lib_meta lib_project_id lib_retention_id
  lib_meta=$(curl "${curl_args[@]}" --max-time 10 -u "admin:${admin_password}" \
    "${api_url}/projects/library" 2>/dev/null || true)
  lib_project_id=$(echo "$lib_meta" | jq -r '.project_id // empty' 2>/dev/null || true)
  lib_retention_id=$(echo "$lib_meta" | jq -r '.metadata.retention_id // empty' 2>/dev/null || true)

  if [[ -z "$lib_project_id" || "$lib_project_id" == "null" ]]; then
    warn "  Could not resolve 'library' project id — skipping retention policy"
  elif [[ -n "$lib_retention_id" && "$lib_retention_id" != "null" ]]; then
    info "  ✓ Tag-retention policy already present on 'library' (id ${lib_retention_id})"
  else
    local retention_payload
    retention_payload=$(cat <<EOF
{
  "algorithm": "or",
  "rules": [
    {
      "action": "retain",
      "template": "latestPushedK",
      "params": { "latestPushedK": ${keep_last} },
      "scope_selectors": { "repository": [ { "kind": "doublestar", "decoration": "repoMatches", "pattern": "**" } ] },
      "tag_selectors": [ { "kind": "doublestar", "decoration": "matches", "pattern": "**" } ]
    }
  ],
  "scope": { "level": "project", "ref": ${lib_project_id} },
  "trigger": { "kind": "Schedule", "settings": { "cron": "0 5 1 * * 0" } }
}
EOF
)
    local rt_response rt_code
    rt_response=$(curl "${curl_args[@]}" --max-time 15 -w "\n%{http_code}" \
      -u "admin:${admin_password}" -H "Content-Type: application/json" \
      -X POST -d "${retention_payload}" "${api_url}/retentions" 2>&1 || echo -e "\n000")
    rt_code=$(echo "$rt_response" | tail -n 1)
    if [[ "$rt_code" == "201" ]]; then
      info "  ✓ Created tag-retention policy on 'library' (keep last ${keep_last}, runs weekly Sun 01:05 UTC)"
    else
      warn "  Failed to create retention policy (HTTP ${rt_code}): $(echo "$rt_response" | sed '$d')"
    fi
  fi

  # --- Weekly garbage collection (purges blobs of deleted/untagged artifacts) ---
  local gc_payload gc_response gc_code
  gc_payload='{"schedule":{"type":"Weekly","cron":"0 0 3 * * 0"},"parameters":{"delete_untagged":true,"dry_run":false,"workers":2}}'
  gc_response=$(curl "${curl_args[@]}" --max-time 15 -w "\n%{http_code}" \
    -u "admin:${admin_password}" -H "Content-Type: application/json" \
    -X POST -d "${gc_payload}" "${api_url}/system/gc/schedule" 2>&1 || echo -e "\n000")
  gc_code=$(echo "$gc_response" | tail -n 1)
  if [[ "$gc_code" == "409" || "$gc_code" == "400" ]]; then
    gc_response=$(curl "${curl_args[@]}" --max-time 15 -w "\n%{http_code}" \
      -u "admin:${admin_password}" -H "Content-Type: application/json" \
      -X PUT -d "${gc_payload}" "${api_url}/system/gc/schedule" 2>&1 || echo -e "\n000")
    gc_code=$(echo "$gc_response" | tail -n 1)
  fi
  if [[ "$gc_code" == "200" || "$gc_code" == "201" ]]; then
    info "  ✓ Garbage collection scheduled weekly (Sun 03:00 UTC, delete_untagged)"
  else
    warn "  Failed to set GC schedule (HTTP ${gc_code}): $(echo "$gc_response" | sed '$d')"
  fi
}

# Helper function to configure Harbor OIDC
configure_harbor_oidc() {
  local admin_password="$1"
  local api_url="$2"
  local auth_mode="$3"
  local curl_args=(-sS -k)
  
  info "Configuring Harbor OIDC (current auth_mode: ${auth_mode:-db_auth})..."
  
  # Get GitHub org for admin group configuration
  local oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
  local github_org_for_harbor=""
  if [[ -f "$oauth_file" ]]; then
    github_org_for_harbor=$(provision::yaml_get "$oauth_file" .stringData.githubOrg)
  fi
  
  # Configure OIDC - use Dex from SSO namespace
  local dex_issuer="https://${DEX_HOST}"
  local config_payload
  config_payload=$(cat <<EOF
{
  "auth_mode": "oidc_auth",
  "oidc_name": "GitHub SSO",
  "oidc_endpoint": "${dex_issuer}",
  "oidc_client_id": "harbor",
  "oidc_client_secret": "${DEX_CLIENT_SECRET}",
  "oidc_scope": "openid,profile,email,groups",
  "oidc_verify_cert": false,
  "oidc_auto_onboard": true,
  "oidc_user_claim": "preferred_username",
  "oidc_groups_claim": "groups",
  "oidc_admin_group": "${github_org_for_harbor}:admins"
}
EOF
)
  
  info "Applying Harbor OIDC configuration..."
  info "  Dex issuer: ${dex_issuer}"
  info "  Admin group: ${github_org_for_harbor}:admins"
  
  local response http_code
  response=$(curl "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
    -u "admin:${admin_password}" \
    -H "Content-Type: application/json" \
    -X PUT \
    -d "${config_payload}" \
    "${api_url}/configurations" 2>&1 || echo -e "\n000")
  
  http_code=$(echo "$response" | tail -n 1)
  
  if [[ "$http_code" == "200" ]]; then
    info "✓ Harbor OIDC configured successfully"
    info "  Note: Admin password login is now DISABLED in Harbor UI"
    info "  Users must log in via GitHub SSO through Dex"
    info "  Admin password is still valid for API access"
  else
    err "Failed to configure Harbor OIDC (HTTP ${http_code})"
    err "Response: $(echo "$response" | sed '$d')"
    return 1
  fi
}

configure_harbor() {
  log "=== Phase 4: Harbor Configuration ==="
  
  # Get the actual Harbor admin password from the secret
  info "Retrieving Harbor admin password from secret..."
  local actual_harbor_password
  actual_harbor_password=$(kubectl -n "$NAMESPACE_HARBOR" get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
  
  if [[ -z "$actual_harbor_password" ]]; then
    info "Could not retrieve Harbor admin password from secret. Using provided password."
    actual_harbor_password="$HARBOR_ADMIN_PASSWORD"
  else
    info "Retrieved Harbor admin password from secret (length: ${#actual_harbor_password})"
  fi
  
  local base_api="https://${HARBOR_HOST}/api/v2.0"
  local curl_args=(-sS -k)  # Use -k for self-signed certs
  
  # Wait for Harbor API to be ready (max 10 minutes)
  info "Waiting for Harbor API to be ready..."
  local harbor_ready=false
  for i in {1..120}; do
    local http_code
    http_code=$(curl "${curl_args[@]}" --max-time 5 -w "%{http_code}" -o /dev/null \
      -u "admin:${actual_harbor_password}" "${base_api}/systeminfo" 2>/dev/null || echo "000")
    
    if [[ "$http_code" == "200" ]]; then
      harbor_ready=true
      break
    fi
    
    # Show progress every 10 attempts
    if (( i % 10 == 0 )); then
      echo -n " [${i}s]"
    else
      echo -n "."
    fi
    sleep 5
  done
  echo ""
  
  if [[ "$harbor_ready" != "true" ]]; then
    err "Harbor API did not become ready in 10 minutes."
    err "Harbor pods status:"
    kubectl -n "$NAMESPACE_HARBOR" get pods -l app=harbor
    warn "Skipping Harbor configuration."
    return 1
  fi
  
  info "Harbor API is ready"
  
  # Check if Harbor is already configured with OIDC
  local current_config
  current_config=$(curl "${curl_args[@]}" --max-time 10 \
    -u "admin:${actual_harbor_password}" \
    "${base_api}/systeminfo" 2>/dev/null || true)
  
  local current_auth_mode
  current_auth_mode=$(echo "$current_config" | jq -r '.auth_mode // empty' 2>/dev/null || true)
  
  if [[ "$current_auth_mode" == "oidc_auth" ]]; then
    info "✓ Harbor is already configured with OIDC authentication"
    info "  Auth mode: oidc_auth"
    info "  Note: Admin password login via UI is disabled when OIDC is active"
    info "  Use GitHub SSO to log in: https://${HARBOR_HOST}"

    # Ensure Harbor resources (dockerhub-proxy project, registry endpoint, robot account)
    # Even when OIDC is already configured, we still have API access with admin password.
    configure_harbor_resources "$actual_harbor_password" "$base_api" || warn "Failed to ensure Harbor resources under OIDC mode"
    configure_harbor_retention_gc "$actual_harbor_password" "$base_api" || warn "Failed to configure Harbor retention/GC"

    # Verify robot account exists
    if kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner >/dev/null 2>&1; then
      info "  ✓ Robot account credentials found in harbor-robot-runner secret"
    else
      warn "  Robot account credentials not found. May need to be recreated."
    fi
    
    return 0
  fi
  
  info "Harbor is in database auth mode. Configuring resources before switching to OIDC..."
  
  configure_harbor_resources "$actual_harbor_password" "$base_api"
  configure_harbor_retention_gc "$actual_harbor_password" "$base_api" || warn "Failed to configure Harbor retention/GC"
  configure_harbor_oidc "$actual_harbor_password" "$base_api" "$current_auth_mode"

  info "✓ Harbor configuration completed"
}

configure_harbor

# ============================================================================
# Phase 5: Validation
# ============================================================================

validate_deployment() {
  log "=== Phase 5: Validation ==="
  
  local validation_failed=false
  
  # Validate Harbor pods
  info "Validating Harbor deployment..."
  
  local harbor_core_ready
  harbor_core_ready=$(kubectl -n "$NAMESPACE_HARBOR" get pods -l component=core -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  
  if [[ "$harbor_core_ready" == "True" ]]; then
    info "  ✓ Harbor core pod is Ready"
  else
    warn "  ✗ Harbor core pod not ready (status: ${harbor_core_ready})"
    validation_failed=true
  fi
  
  # Check Harbor service (core service)
  if kubectl -n "$NAMESPACE_HARBOR" get svc harbor-core >/dev/null 2>&1; then
    info "  ✓ Harbor service exists"
  else
    warn "  ✗ Harbor service not found"
    validation_failed=true
  fi
  
  # Check Harbor ingress
  if kubectl -n "$NAMESPACE_HARBOR" get ingress harbor-ingress >/dev/null 2>&1; then
    info "  ✓ Harbor ingress exists"
  else
    warn "  ✗ Harbor ingress not found"
    validation_failed=true
  fi
  
  # Check robot credentials
  info "Validating Harbor robot credentials..."
  
  if kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner >/dev/null 2>&1; then
    local robot_username robot_password
    robot_username=$(kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    robot_password=$(kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [[ -n "$robot_username" && -n "$robot_password" ]]; then
      info "  ✓ Robot credentials available in harbor-robot-runner secret"
      info "    Username: ${robot_username}"
    else
      warn "  ✗ Robot credentials incomplete in harbor-robot-runner secret"
      validation_failed=true
    fi
  else
    warn "  ✗ harbor-robot-runner secret not found"
    validation_failed=true
  fi
  
  # Test Harbor endpoint
  if [[ -n "${HARBOR_HOST:-}" ]]; then
    info "Testing Harbor endpoint..."
    
    # Check if TLS certificate is ready
    local cert_ready=false
    if kubectl -n "$NAMESPACE_HARBOR" get certificate "${TLS_SECRET_NAME:-harbor-tls}" >/dev/null 2>&1; then
      local cert_status
      cert_status=$(kubectl -n "$NAMESPACE_HARBOR" get certificate "${TLS_SECRET_NAME:-harbor-tls}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
      
      if [[ "$cert_status" == "True" ]]; then
        info "  ✓ TLS certificate ready"
        cert_ready=true
      else
        warn "  ⚠ TLS certificate not ready yet (status: ${cert_status})"
      fi
    fi
    
    # Test endpoint (with retry)
    local max_attempts=5
    local attempt=0
    local endpoint_ok=false
    
    while [[ $attempt -lt $max_attempts ]]; do
      if curl -sSf -k --max-time 10 "https://${HARBOR_HOST}" >/dev/null 2>&1; then
        info "  ✓ Harbor endpoint responding"
        endpoint_ok=true
        break
      fi
      
      attempt=$((attempt + 1))
      if [[ $attempt -lt $max_attempts ]]; then
        sleep 5
      fi
    done
    
    if [[ "$endpoint_ok" != "true" ]]; then
      warn "  ⚠ Harbor endpoint not responding after ${max_attempts} attempts"
      warn "    URL: https://${HARBOR_HOST}"
      warn "    This may be normal if DNS/certificate is still propagating"
    fi
  fi
  
  # Summary
  if [[ "$validation_failed" == "true" ]]; then
    warn ""
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "  Some validations failed"
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn ""
    warn "Some components may need additional time to become ready."
    warn "Run the following commands to check status:"
    warn ""
    warn "  kubectl -n ${NAMESPACE_HARBOR} get pods"
    warn "  kubectl -n ${NAMESPACE_HARBOR} get ingress"
    warn "  kubectl -n ${NAMESPACE_HARBOR} get certificate"
    warn "  curl -k https://${HARBOR_HOST}"
    warn ""
    return 1
  else
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  ✓ All validations passed"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
  fi
}

validate_deployment

# ============================================================================
# Summary
# ============================================================================

log "=== Registry provisioning completed for environment: ${ENV_NAME} ==="
info ""
info "Services provisioned:"
info "  ✓ Harbor (namespace: ${NAMESPACE_HARBOR})"
info ""
info "Endpoints:"
info "  Harbor: https://${HARBOR_HOST}"
info ""
info "Authentication:"
info "  SSO via Dex: https://${DEX_HOST}"
info "  GitHub organization: $(provision::yaml_get "$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml" .stringData.githubOrg 2>/dev/null || echo 'N/A')"
info ""
info "Harbor Resources:"
info "  ✓ Docker Hub proxy registry endpoint"
info "  ✓ Docker Hub proxy project (dockerhub-proxy)"
info "  ✓ Robot account for CI/CD (harbor-robot-runner secret)"
info ""
info "Robot Account Credentials:"
if kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner >/dev/null 2>&1; then
  robot_user=$(kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
  robot_pass=$(kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
  info "  Username: ${robot_user}"
  info "  Password: ${robot_pass}"
  info ""
  info "  Retrieve credentials later with:"
  info "    kubectl -n ${NAMESPACE_HARBOR} get secret harbor-robot-runner -o jsonpath='{.data.username}' | base64 -d"
  info "    kubectl -n ${NAMESPACE_HARBOR} get secret harbor-robot-runner -o jsonpath='{.data.password}' | base64 -d"
else
  info "  Robot credentials not found in harbor-robot-runner secret"
fi
info ""
info "Next steps:"
info "  1. Access Harbor: https://${HARBOR_HOST}"
info "  2. Login with GitHub SSO (admin password login is DISABLED)"
info "  3. Configure organization secrets for CI/CD:"
info "     tools/k3s/provision-org-secrets.sh ${ENV_NAME}"
info "  4. Or configure per-repository secrets:"
info "     tools/k3s/registry-credentials.sh ${ENV_NAME} <repo-name>"
info ""
info "Docker Hub proxy cache usage:"
info "  Pull official images:"
info "    docker pull ${HARBOR_HOST}/dockerhub-proxy/library/nginx:latest"
info "    docker pull ${HARBOR_HOST}/dockerhub-proxy/library/eclipse-temurin:25_36-jdk-ubi10-minimal"
info ""
info "  Pull user images:"
info "    docker pull ${HARBOR_HOST}/dockerhub-proxy/<username>/<image>:<tag>"
info ""
info "  In Dockerfile:"
info "    FROM ${HARBOR_HOST}/dockerhub-proxy/library/eclipse-temurin:25_36-jdk-ubi10-minimal"
info ""
info "Harbor Admin Password (API access only):"
info "  kubectl -n ${NAMESPACE_HARBOR} get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d"
info ""
