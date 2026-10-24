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
#   tools/k3s/harbor.sh <env-name> [--skip-node-auth]
#
# Who logs in how: people use SSO (Dex OIDC; members of <org>:admins are Harbor admins), CI and
# the nodes use robot accounts (robot$runner for push, robot$node-pull for pull). Nobody uses
# the local `admin` account: it exists only for this script's API bootstrap (registry endpoint,
# projects, robots, retention, OIDC switch). Its password is random, generated at first install,
# and kept only in the cluster (Secret harbor/harbor-core, key HARBOR_ADMIN_PASSWORD, which each
# re-run reads back): never in env.properties, secrets.plain/ or secrets.sops/, and never on a
# command line (Helm gets it from a 0600 values file, curl from a -K config on a pipe). A
# reprovision generates a new one. With OIDC on, the Harbor UI refuses it anyway.
#
# Pull credentials and private projects (Phase 4b): the `library` and `dockerhub-proxy`
# projects are private by default. Before they turn private, a pull-only robot
# (robot$node-pull) is created and its credential lands in:
#   - harbor/harbor-node-pull (Secret), SOPS-encrypted into envs/<env>/secrets.sops/
#   - /etc/rancher/k3s/registries.yaml on the server node (containerd), over SSH as
#     ${NODE_SSH_USER:-root}@${TAILSCALE_IP:-EXTERNAL_IP}; k3s restarts when the file changes
#   - argocd/repo-harbor-charts (ArgoCD OCI credential for the app charts), when ArgoCD exists
#     (argocd.sh creates it otherwise)
#
#   --skip-node-auth            don't touch the node (no SSH, no k3s restart); the projects stay
#                               as they are unless HARBOR_PRIVATE_PROJECTS=force
#   HARBOR_PRIVATE_PROJECTS     true (default): private once every node has the credential, i.e.
#                               the server was written and there are no agent nodes;
#                               force: private regardless (agents joined with join-worker.sh,
#                               which copies registries.yaml from the server); false: leave public

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

SKIP_NODE_AUTH=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-node-auth) SKIP_NODE_AUTH=true; shift ;;
    *) echo "Unknown option: $1 (known: --skip-node-auth)" >&2; exit 1 ;;
  esac
done

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

# curl as Harbor's admin: admin_curl PASSWORD [curl args...]. The credential reaches curl as a
# config on a file descriptor (-K), never on argv, where any local user could read it in ps.
admin_curl() {
  local pw="$1"
  shift
  curl -K <(provision::curl_user_cfg admin "$pw") "$@"
}

# --- Config defaults ---
NAMESPACE_HARBOR="${NAMESPACE_HARBOR:-harbor}"
NAMESPACE_ARGOCD="${NAMESPACE_ARGOCD:-argocd}"
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"

# Version pins. goharbor has no chart for Harbor 2.14.5 (1.18.4 ships 2.14.4), so the chart
# stays on 1.18.4 and every component image is set to v2.14.5, which patches the 2026-10-06
# advisories (robot -> system admin, webhook SSRF, signed-image policy bypass). 2.14.4 -> 2.14.5
# has no database migration. Empty HARBOR_IMAGE_TAG = the chart's appVersion; raise deliberately.
HARBOR_CHART_VERSION="${HARBOR_CHART_VERSION:-1.18.4}"
HARBOR_IMAGE_TAG="${HARBOR_IMAGE_TAG-v2.14.5}"
HARBOR_IMAGE_COMPONENTS=(nginx portal core jobservice registry.registry registry.controller trivy database.internal redis.internal exporter)

# The ingress certificate. cert-manager issues it into this secret (ingress-shim, from the
# ingress annotations) and Harbor only reads it: expose.tls.certSource=secret. With the chart's
# default certSource=auto the chart renders the same secret with a self-signed cert, and every
# upgrade fights cert-manager over it.
TLS_SECRET_NAME="${TLS_SECRET_NAME:-harbor-ingress}"

# Pull credentials and private projects (see the header).
HARBOR_PRIVATE_PROJECTS="${HARBOR_PRIVATE_PROJECTS:-true}"
HARBOR_PRIVATE_PROJECT_NAMES=(library dockerhub-proxy)
NODE_PULL_ROBOT="${NODE_PULL_ROBOT:-node-pull}"
NODE_PULL_SECRET="harbor-node-pull"
NODE_SSH_USER="${NODE_SSH_USER:-root}"
NODE_SSH_HOST="${NODE_SSH_HOST:-${TAILSCALE_IP:-${EXTERNAL_IP:-}}}"

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

# harborAdminPassword only seeds the admin account when Harbor's database is created; setting a
# new one on an upgrade changes the harbor-core Secret but not the account, and every API call
# this script makes afterwards (it reads the Secret) is refused. So a re-run keeps the
# installed value unless HARBOR_ADMIN_PASSWORD is given explicitly (shell environment only).
# The password lives in the cluster alone (harbor/harbor-core and the Helm release); see the
# header. env.properties is committed, so a password there is refused.
if grep -qE '^[[:space:]]*(export[[:space:]]+)?HARBOR_ADMIN_PASSWORD=' "${ENVS_ROOT}/${ENV_NAME}/env.properties" 2>/dev/null; then
  err "HARBOR_ADMIN_PASSWORD is set in ${ENV_NAME}/env.properties. Remove it: the admin password is"
  err "generated at first install and kept only in the cluster (harbor/harbor-core)."
  exit 1
fi
if [[ -z "${HARBOR_ADMIN_PASSWORD:-}" ]]; then
  HARBOR_ADMIN_PASSWORD=$(kubectl -n "$NAMESPACE_HARBOR" get secret harbor-core \
    -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [[ -n "$HARBOR_ADMIN_PASSWORD" ]] && info "Keeping the admin password of the installed Harbor (harbor/harbor-core)"
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
  local tls_secret_name="${TLS_SECRET_NAME}"
  if kubectl -n "$NAMESPACE_HARBOR" get secret "$tls_secret_name" >/dev/null 2>&1; then
    info "TLS secret '$tls_secret_name' already exists - will reuse it"
    # An install from before certSource=secret has the chart own this secret; the upgrade below
    # drops it from the release, and without this annotation Helm would delete the live
    # certificate. cert-manager keeps renewing it either way.
    kubectl -n "$NAMESPACE_HARBOR" annotate secret "$tls_secret_name" \
      helm.sh/resource-policy=keep --overwrite >/dev/null
  fi

  # Settings every run applies, install or upgrade: the chart and image pins and the TLS source.
  # caSecretName points harbor-core's CA download at the same secret; with certSource=secret and
  # no caSecretName the chart renders that volume without a secret name.
  local common_args=(--version "$HARBOR_CHART_VERSION"
    --set expose.tls.enabled=true
    --set expose.tls.certSource=secret
    --set "expose.tls.secret.secretName=${tls_secret_name}"
    --set "caSecretName=${tls_secret_name}")
  local component
  if [[ -n "$HARBOR_IMAGE_TAG" ]]; then
    for component in "${HARBOR_IMAGE_COMPONENTS[@]}"; do
      common_args+=(--set "${component}.image.tag=${HARBOR_IMAGE_TAG}")
    done
  fi
  info "  Chart harbor ${HARBOR_CHART_VERSION}, image ${HARBOR_IMAGE_TAG:-<chart appVersion>}, TLS from secret ${tls_secret_name}"

  # The admin password goes to Helm in a values file only this user can read (mktemp: 0600),
  # removed when the script exits; --set would put it on helm's argv. JSON is valid YAML, and
  # jq -R reads the password from stdin, so it is on no command line here either.
  ADMIN_VALUES_FILE=$(mktemp)
  trap 'rm -f "$ADMIN_VALUES_FILE"' EXIT
  printf '%s' "$HARBOR_ADMIN_PASSWORD" | jq -Rs '{harborAdminPassword: .}' > "$ADMIN_VALUES_FILE"
  common_args+=(-f "$ADMIN_VALUES_FILE")

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
      "${common_args[@]}" \
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
      "${common_args[@]}" \
      --set externalURL="https://$HARBOR_HOST" \
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
# Phase 3b: harbor-db collation versions
# ============================================================================
# A harbor-db image built on a newer glibc changes the collation of every text index built
# under the old one (2.14.5 moved glibc 2.36 -> 2.43): non-ASCII keys can mis-sort until the
# indexes are rebuilt, and Postgres warns "collation version mismatch" on every connection.
# For each database whose recorded collation version differs from the library's: REINDEX it
# (the registry database is small; writes to an index block while it is rebuilt), then
# REFRESH COLLATION VERSION. A no-op when nothing is mismatched, and on an external database.
ensure_harbor_db_collation() {
  log "=== Phase 3b: harbor-db collation versions ==="
  local pod="harbor-database-0"
  if ! kubectl -n "$NAMESPACE_HARBOR" get pod "$pod" >/dev/null 2>&1; then
    info "No ${pod} (external database?) - skipping"
    return 0
  fi
  kubectl -n "$NAMESPACE_HARBOR" wait --for=condition=Ready "pod/${pod}" --timeout=300s >/dev/null 2>&1 || true
  hdb_psql() {
    kubectl -n "$NAMESPACE_HARBOR" exec "$pod" -c database -- \
      psql -U postgres -v ON_ERROR_STOP=1 -At "$@" 2>/dev/null
  }
  local mismatched db
  if ! mismatched=$(hdb_psql -c "SELECT datname FROM pg_database WHERE datallowconn AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)"); then
    warn "Could not read collation versions from ${pod} - skipping (check by hand after an image change)"
    return 0
  fi
  if [[ -z "$mismatched" ]]; then
    info "✓ Collation versions current"
    return 0
  fi
  info "Collation version changed for: $(echo "$mismatched" | tr '\n' ' ')"
  for db in $mismatched; do
    info "  REINDEX DATABASE ${db} ..."
    hdb_psql -d "$db" -c "REINDEX DATABASE \"${db}\"" >/dev/null || { err "  REINDEX of ${db} failed"; return 1; }
    hdb_psql -d "$db" -c "ALTER DATABASE \"${db}\" REFRESH COLLATION VERSION" >/dev/null || { err "  REFRESH COLLATION VERSION of ${db} failed"; return 1; }
  done
  mismatched=$(hdb_psql -c "SELECT datname FROM pg_database WHERE datallowconn AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)" || echo "?")
  if [[ -n "$mismatched" ]]; then
    err "Still mismatched after reindexing: ${mismatched}"
    return 1
  fi
  info "✓ Indexes rebuilt and collation versions refreshed"
}

ensure_harbor_db_collation || warn "harbor-db collation step failed - see above"

# ============================================================================
# Phase 4: Harbor Configuration
# ============================================================================

# Helper function to configure Harbor resources (registry, projects, robot account)
configure_harbor_resources() {
  local admin_password="$1"
  local api_url="$2"
  local curl_args=(-sS)
  
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
  registry_response=$(admin_curl "$admin_password" "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
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
  registry_id=$(admin_curl "$admin_password" "${curl_args[@]}" --max-time 10 \
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
    # Created public; ensure_private_projects (Phase 4b) makes it private once the nodes
    # and ArgoCD hold pull credentials.
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
    proxy_response=$(admin_curl "$admin_password" "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
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
      project_info=$(admin_curl "$admin_password" "${curl_args[@]}" --max-time 10 \
        "${api_url}/projects?name=dockerhub-proxy" 2>/dev/null || true)
      project_id=$(echo "$project_info" | jq -r '.[0].project_id // empty' 2>/dev/null || true)
      project_registry_id=$(echo "$project_info" | jq -r '.[0].registry_id // empty' 2>/dev/null || true)

      if [[ -z "$project_id" || "$project_id" == "null" ]]; then
        warn "  Unable to determine project_id for dockerhub-proxy"
      elif [[ "$project_registry_id" != "$registry_id" ]]; then
        info "  Project is not linked to Docker Hub registry (current registry_id: ${project_registry_id:-<unset>}). Patching..."
        local patch_payload patch_response patch_http_code patch_body
        # No metadata.public here: visibility is ensure_private_projects' business.
        patch_payload=$(cat <<EOF
{
  "project_name": "dockerhub-proxy",
  "registry_id": ${registry_id},
  "storage_limit": -1
}
EOF
)
        info "  Patch payload: ${patch_payload}"
        patch_response=$(admin_curl "$admin_password" "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
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
      err "  curl -K <(printf 'user = \"admin:%s\"\\n' \"\$(kubectl -n harbor get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)\") \\"
      err "    -H 'Content-Type: application/json' -X POST \\"
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
  robot_response=$(admin_curl "$admin_password" "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
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
    # Built with printf (a builtin) and piped, so the secret is on no command line.
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: harbor-robot-runner\n  namespace: %s\ntype: Opaque\ndata:\n  username: %s\n  password: %s\n' \
      "$NAMESPACE_HARBOR" "$(printf '%s' "$robot_name" | base64 | tr -d '\n')" \
      "$(printf '%s' "$robot_secret" | base64 | tr -d '\n')" | kubectl apply -f -
    
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
  local curl_args=(-sS)
  local keep_last="${HARBOR_RETAIN_LAST_K:-10}"

  info "Configuring Harbor tag retention (keep last ${keep_last} per repo) + weekly GC..."

  # --- Tag-retention policy on the default `library` project ---
  local lib_meta lib_project_id lib_retention_id
  lib_meta=$(admin_curl "$admin_password" "${curl_args[@]}" --max-time 10 \
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
    rt_response=$(admin_curl "$admin_password" "${curl_args[@]}" --max-time 15 -w "\n%{http_code}" \
      -H "Content-Type: application/json" \
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
  gc_response=$(admin_curl "$admin_password" "${curl_args[@]}" --max-time 15 -w "\n%{http_code}" \
    -H "Content-Type: application/json" \
    -X POST -d "${gc_payload}" "${api_url}/system/gc/schedule" 2>&1 || echo -e "\n000")
  gc_code=$(echo "$gc_response" | tail -n 1)
  if [[ "$gc_code" == "409" || "$gc_code" == "400" ]]; then
    gc_response=$(admin_curl "$admin_password" "${curl_args[@]}" --max-time 15 -w "\n%{http_code}" \
      -H "Content-Type: application/json" \
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
  local curl_args=(-sS)
  
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
  response=$(admin_curl "$admin_password" "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
    -H "Content-Type: application/json" \
    -X PUT \
    --data-binary @<(printf '%s' "${config_payload}") \
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
  local curl_args=(-sS)  # publicly trusted cert (cert-manager ACME)
  
  # Wait for Harbor API to be ready (max 10 minutes)
  info "Waiting for Harbor API to be ready..."
  local harbor_ready=false
  for i in {1..120}; do
    local http_code
    http_code=$(admin_curl "$actual_harbor_password" "${curl_args[@]}" --max-time 5 -w "%{http_code}" -o /dev/null \
      "${base_api}/systeminfo" 2>/dev/null || echo "000")
    
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
  current_config=$(admin_curl "$actual_harbor_password" "${curl_args[@]}" --max-time 10 \
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
# Phase 4b: Pull credentials and private projects
# ============================================================================
# Anything that pulls from library or dockerhub-proxy without logging in - containerd on the
# nodes, ArgoCD fetching the app charts - needs a credential before those projects turn
# private. One pull-only robot serves both (see the header for where it goes).

# A value for a double-quoted curl config entry: \ and " escaped (a hand-set password may hold them).
curl_cfg_quote() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }

# Harbor API as admin: METHOD PATH [JSON]. Prints the body, a newline and the HTTP code.
# The password reaches curl through a config on a file descriptor, not argv.
harbor_api() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS --max-time 20 -X "$method" -H "Content-Type: application/json" -w '\n%{http_code}')
  # The body can carry a secret (a robot's new one), so it goes in on stdin, not on argv.
  [[ -n "$data" ]] && args+=(--data-binary @-)
  printf '%s' "$data" | curl "${args[@]}" -K <(provision::curl_user_cfg admin "$HARBOR_API_PASSWORD") \
    "https://${HARBOR_HOST}/api/v2.0${path}" 2>/dev/null || printf '\n000'
}
http_code() { printf '%s' "${1##*$'\n'}"; }
http_body() { printf '%s' "${1%$'\n'*}"; }

# Does Harbor accept USER/PASS? The registry base /v2/ answers 200 to a valid credential and 401
# to anything else. (/service/token is no test: it hands an anonymous token to a wrong secret.)
pull_credential_valid() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
    -K <(printf 'user = "%s:%s"\n' "$(curl_cfg_quote "$1")" "$(curl_cfg_quote "$2")") "https://${HARBOR_HOST}/v2/" 2>/dev/null || echo 000)
  [[ "$code" == "200" ]]
}

# Write the robot's Secret to secrets.plain, apply it, SOPS-encrypt it into secrets.sops and
# remove the plaintext (the pattern of postgres.sh's read-only login). Values are never printed.
store_node_pull_secret() {
  local user="$1" pass="$2" file="${NODE_PULL_SECRET}.yaml"
  local plain="${ENVS_ROOT}/${ENV_NAME}/secrets.plain/${file}"
  local sops_file="${ENVS_ROOT}/${ENV_NAME}/secrets.sops/${file}"
  provision::assert_plaintext_ignored "$plain" || return 1
  ( umask 077
    mkdir -p "$(dirname "$plain")"
    cat > "$plain" <<YAML
# Harbor robot ${user}: pull-only on $(IFS=,; echo "${HARBOR_PRIVATE_PROJECT_NAMES[*]}"). Used by containerd
# (/etc/rancher/k3s/registries.yaml on the nodes) and by ArgoCD (argocd/repo-harbor-charts).
# Written by infra-skills tools/k3s/harbor.sh; never commit.
apiVersion: v1
kind: Secret
metadata:
  name: ${NODE_PULL_SECRET}
  namespace: ${NAMESPACE_HARBOR}
type: kubernetes.io/basic-auth
stringData:
  username: "${user}"
  password: "${pass}"
YAML
  )
  kubectl apply -f "$plain" >/dev/null
  info "  ✓ Secret ${NAMESPACE_HARBOR}/${NODE_PULL_SECRET} applied"
  if command -v sops >/dev/null 2>&1 && \
     "$REPO_ROOT/tools/sops/encrypt.sh" "$ENV_NAME" "$file" >/dev/null && \
     grep -q 'password: ENC\[' "$sops_file"; then
    rm -f "$plain"
    info "  ✓ Encrypted to ${ENV_NAME}/secrets.sops/${file} - commit it in the envs repo"
  else
    warn "  Could not SOPS-encrypt it; the plaintext stays (git-ignored) at ${plain#"${ENVS_ROOT}/"}:"
    warn "  tools/sops/encrypt.sh ${ENV_NAME} ${file}, then delete the plaintext"
  fi
}

# Sets NODE_PULL_USER / NODE_PULL_PASS. Keeps a working credential (cluster Secret, else the
# envs repo's SOPS copy); otherwise creates the robot, or gives an existing robot a new secret
# when no copy of its current one is left.
ensure_node_pull_credentials() {
  NODE_PULL_USER="" NODE_PULL_PASS=""
  if ! kubectl -n "$NAMESPACE_HARBOR" get secret "$NODE_PULL_SECRET" >/dev/null 2>&1; then
    local f
    for f in "${ENVS_ROOT}/${ENV_NAME}/secrets.sops/"*.yaml; do
      [[ -f "$f" ]] || continue
      if [[ -n "$(NS="$NAMESPACE_HARBOR" NAME="$NODE_PULL_SECRET" yq eval 'select(.kind == "Secret" and .metadata.name == strenv(NAME) and .metadata.namespace == strenv(NS)) | .metadata.name' "$f" 2>/dev/null)" ]]; then
        info "Applying ${NODE_PULL_SECRET} from ${f#"${ENVS_ROOT}/"}"
        sops -d "$f" | kubectl apply -f - >/dev/null || warn "  could not decrypt/apply ${f#"${ENVS_ROOT}/"} (sops and the age key are needed)"
        break
      fi
    done
  fi
  NODE_PULL_USER=$(kubectl -n "$NAMESPACE_HARBOR" get secret "$NODE_PULL_SECRET" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
  NODE_PULL_PASS=$(kubectl -n "$NAMESPACE_HARBOR" get secret "$NODE_PULL_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ -n "$NODE_PULL_USER" && -n "$NODE_PULL_PASS" ]] && pull_credential_valid "$NODE_PULL_USER" "$NODE_PULL_PASS"; then
    info "✓ Pull-only robot ${NODE_PULL_USER}: credential in ${NAMESPACE_HARBOR}/${NODE_PULL_SECRET} is valid"
    return 0
  fi
  [[ -n "$NODE_PULL_USER" ]] && warn "The credential in ${NAMESPACE_HARBOR}/${NODE_PULL_SECRET} is refused by Harbor - replacing it"

  local out robot_id
  out=$(harbor_api GET "/robots?q=name%3D~${NODE_PULL_ROBOT}&page_size=100")
  robot_id=$(http_body "$out" | jq -r --arg n "$NODE_PULL_ROBOT" \
    '[.[]? | select(.name == $n or (.name | endswith("$" + $n)))][0].id // empty' 2>/dev/null || true)
  if [[ -n "$robot_id" ]]; then
    # The robot exists but no usable copy of its secret does: set a new one (8-128 chars,
    # upper + lower + digit). Whatever used the old secret must take the new one.
    local secret
    secret="Np1$(openssl rand -hex 20)"
    out=$(harbor_api PATCH "/robots/${robot_id}" "$(printf '%s' "$secret" | jq -Rc '{secret: .}')")
    if [[ "$(http_code "$out")" != "200" ]]; then
      err "Could not refresh the secret of robot id ${robot_id} (HTTP $(http_code "$out"))"
      return 1
    fi
    NODE_PULL_USER=$(harbor_api GET "/robots/${robot_id}" | sed '$d' | jq -r '.name // empty')
    NODE_PULL_PASS="$secret"
    info "✓ Robot ${NODE_PULL_USER} existed without a usable secret copy - set a new secret"
  else
    local payload
    payload=$(jq -cn --arg n "$NODE_PULL_ROBOT" --arg projects "$(IFS=,; echo "${HARBOR_PRIVATE_PROJECT_NAMES[*]}")" '{
      name: $n, level: "system", duration: -1, disable: false,
      description: "Pull-only: containerd on the nodes and ArgoCD chart pulls (private projects)",
      permissions: [($projects | split(","))[] | {kind: "project", namespace: ., access: [
        {resource: "repository", action: "pull"}, {resource: "artifact", action: "read"}]}]}')
    out=$(harbor_api POST "/robots" "$payload")
    if [[ "$(http_code "$out")" != "201" ]]; then
      err "Could not create robot ${NODE_PULL_ROBOT} (HTTP $(http_code "$out")): $(http_body "$out" | jq -c 'del(.secret)' 2>/dev/null)"
      return 1
    fi
    NODE_PULL_USER=$(http_body "$out" | jq -r '.name // empty')
    NODE_PULL_PASS=$(http_body "$out" | jq -r '.secret // empty')
    info "✓ Created pull-only robot ${NODE_PULL_USER} ($(IFS=,; echo "${HARBOR_PRIVATE_PROJECT_NAMES[*]}"))"
  fi
  if ! pull_credential_valid "$NODE_PULL_USER" "$NODE_PULL_PASS"; then
    err "Harbor refuses the new credential of ${NODE_PULL_USER}"
    return 1
  fi
  store_node_pull_secret "$NODE_PULL_USER" "$NODE_PULL_PASS"
}

# containerd auth on the server node: /etc/rancher/k3s/registries.yaml gets
# configs."<harbor-host>".auth = the robot; other entries in the file are kept. k3s reads the
# file at start, so it is restarted when the file changed (or changed after k3s last started):
# the API is away for under a minute; running pods are not restarted.
# Returns 0 when the server has the credential active and there are no agent nodes,
# 2 when agent nodes exist (they are not reached from here), 1 when skipped or failed.
ensure_node_registry_auth() {
  if [[ "$SKIP_NODE_AUTH" == "true" ]]; then
    info "Node registry auth skipped (--skip-node-auth)"
    return 1
  fi
  if [[ -z "$NODE_SSH_HOST" ]]; then
    warn "No NODE_SSH_HOST / TAILSCALE_IP / EXTERNAL_IP - cannot reach the node"
    return 1
  fi
  local target="${NODE_SSH_USER}@${NODE_SSH_HOST}" sudo="" f=/etc/rancher/k3s/registries.yaml
  [[ "$NODE_SSH_USER" != "root" ]] && sudo="sudo"
  local ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
  # shellcheck disable=SC2029  # the remote commands are composed on this side on purpose
  node_ssh() { ssh "${ssh_opts[@]}" "$target" "$@"; }

  if ! node_ssh "$sudo systemctl is-active --quiet k3s"; then
    warn "Cannot reach ${target} over SSH, or k3s (server) is not active there - node auth not set"
    return 1
  fi
  local current desired cur_user cur_pass restart=false
  current=$(node_ssh "$sudo cat $f 2>/dev/null || true") || { warn "Cannot read ${f} on ${target}"; return 1; }
  cur_user=$(printf '%s' "$current" | H="$HARBOR_HOST" yq eval '.configs[strenv(H)].auth.username // ""' - 2>/dev/null || true)
  cur_pass=$(printf '%s' "$current" | H="$HARBOR_HOST" yq eval '.configs[strenv(H)].auth.password // ""' - 2>/dev/null || true)
  if [[ "$cur_user" == "$NODE_PULL_USER" && "$cur_pass" == "$NODE_PULL_PASS" ]]; then
    info "✓ ${f} on ${NODE_SSH_HOST} already holds the credential for ${HARBOR_HOST}"
    # Written but not yet read by k3s (e.g. staged by hand without a restart)?
    if ! node_ssh "m=\$(stat -c %Y $f); s=\$(date -d \"\$(systemctl show k3s -p ActiveEnterTimestamp --value)\" +%s); [ \"\$m\" -le \"\$s\" ]"; then
      info "  ... but k3s started before it was written"
      restart=true
    fi
  else
    if [[ -n "$current" ]]; then
      desired=$(printf '%s' "$current" | H="$HARBOR_HOST" U="$NODE_PULL_USER" P="$NODE_PULL_PASS" \
        yq eval '.configs[strenv(H)].auth = {"username": strenv(U), "password": strenv(P)}' -)
    else
      desired=$(H="$HARBOR_HOST" U="$NODE_PULL_USER" P="$NODE_PULL_PASS" \
        yq eval -n '.configs[strenv(H)].auth = {"username": strenv(U), "password": strenv(P)}')
    fi
    printf '%s\n' "$desired" | node_ssh "$sudo sh -c 'umask 077; mkdir -p /etc/rancher/k3s && cat > $f.tmp && mv $f.tmp $f'" \
      || { err "Could not write ${f} on ${target}"; return 1; }
    info "✓ Wrote the ${HARBOR_HOST} credential to ${f} on ${NODE_SSH_HOST}"
    restart=true
  fi

  if [[ "$restart" == "true" ]]; then
    info "Restarting k3s on ${NODE_SSH_HOST} so containerd reads ${f} (API away for up to a minute)..."
    node_ssh "$sudo timeout 300 systemctl restart k3s" || warn "  systemctl restart k3s did not return cleanly"
    local i
    for i in $(seq 1 60); do
      kubectl get --raw=/readyz >/dev/null 2>&1 && break
      sleep 5
    done
    if ! kubectl get --raw=/readyz >/dev/null 2>&1; then
      err "The API did not come back within 5 minutes of the k3s restart"
      return 1
    fi
    kubectl wait node -l node-role.kubernetes.io/control-plane --for=condition=Ready --timeout=300s >/dev/null 2>&1 || warn "  the server node is not Ready yet"
    info "✓ k3s restarted; API back"
  fi

  local agents
  agents=$(kubectl get nodes -o json | jq -r '[.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == null) | .metadata.name] | join(" ")')
  if [[ -n "$agents" ]]; then
    warn "Agent node(s) not reached from here: ${agents}"
    warn "  tools/k3s/join-worker.sh <env> <worker> copies ${f} from the server to a worker."
    return 2
  fi
  return 0
}

# A running pod's image from library (cached on the node), to prove a pull with the node's
# credential after the projects turned private. Digest references first: a moved tag would
# download a new image. Empty when there is none.
node_probe_image() {
  kubectl get pods -A -o json 2>/dev/null | jq -r --arg h "${HARBOR_HOST}/" \
    '[.items[].spec.containers[].image | select(startswith($h + "library/"))]
     | (map(select(contains("@sha256:"))) + .) | first // empty'
}

set_project_public() { # <project> <true|false>
  local out
  out=$(harbor_api PUT "/projects/$1" "$(jq -cn --arg p "$2" '{metadata: {public: $p}}')")
  [[ "$(http_code "$out")" == "200" ]]
}

# Make the projects private when every puller holds the credential (see HARBOR_PRIVATE_PROJECTS).
ensure_private_projects() {
  local node_auth_rc="$1" project out public changed=()
  case "$HARBOR_PRIVATE_PROJECTS" in
    false)
      info "HARBOR_PRIVATE_PROJECTS=false - leaving project visibility as it is"
      return 0 ;;
    force) ;;
    *)
      if [[ "$node_auth_rc" != "0" ]]; then
        warn "Not making ${HARBOR_PRIVATE_PROJECT_NAMES[*]} private: not every node is known to hold the pull credential."
        warn "  Fix the node step above (or join agents with join-worker.sh and re-run with HARBOR_PRIVATE_PROJECTS=force)."
        return 0
      fi ;;
  esac
  if kubectl get ns "$NAMESPACE_ARGOCD" >/dev/null 2>&1 && ! kubectl -n "$NAMESPACE_ARGOCD" get secret repo-harbor-charts >/dev/null 2>&1; then
    warn "ArgoCD is installed but ${NAMESPACE_ARGOCD}/repo-harbor-charts is missing - not making the projects private"
    return 0
  fi

  for project in "${HARBOR_PRIVATE_PROJECT_NAMES[@]}"; do
    out=$(harbor_api GET "/projects/${project}")
    if [[ "$(http_code "$out")" != "200" ]]; then
      warn "  Project ${project} not found (HTTP $(http_code "$out")) - skipped"
      continue
    fi
    public=$(http_body "$out" | jq -r '.metadata.public // "false"')
    if [[ "$public" == "false" ]]; then
      info "  ✓ ${project} is private"
    elif set_project_public "$project" false; then
      info "  ✓ ${project} made private"
      changed+=("$project")
    else
      err "  Could not make ${project} private"
    fi
  done
  [[ ${#changed[@]} -gt 0 ]] || return 0

  # Prove the node can still pull; undo on failure, so running workloads keep restarting.
  local image target="${NODE_SSH_USER}@${NODE_SSH_HOST}" sudo=""
  [[ "$NODE_SSH_USER" != "root" ]] && sudo="sudo"
  image=$(node_probe_image)
  if [[ -z "$image" || "$SKIP_NODE_AUTH" == "true" ]]; then
    info "  (no running library image to probe a node pull with)"
    return 0
  fi
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "$sudo k3s crictl pull '$image'" >/dev/null 2>&1; then
    info "  ✓ The node pulls ${image} with its credential"
  else
    err "  The node cannot pull ${image} now - making ${changed[*]} public again"
    for project in "${changed[@]}"; do set_project_public "$project" true || err "  Could not revert ${project}!"; done
    return 1
  fi
}

pull_credentials_and_private_projects() {
  log "=== Phase 4b: Pull credentials and private projects ==="
  HARBOR_API_PASSWORD=$(kubectl -n "$NAMESPACE_HARBOR" get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [[ -n "$HARBOR_API_PASSWORD" ]] || HARBOR_API_PASSWORD="$HARBOR_ADMIN_PASSWORD"

  ensure_node_pull_credentials || return 1
  if provision::argocd_harbor_charts_repo "$HARBOR_HOST" "$NAMESPACE_ARGOCD"; then
    info "✓ ArgoCD credential argocd/repo-harbor-charts ensured"
  else
    info "ArgoCD not installed yet - argocd.sh creates argocd/repo-harbor-charts"
  fi
  local node_auth_rc=0
  if [[ "$HARBOR_PRIVATE_PROJECTS" == "false" ]]; then
    # Public projects need no node credential: no SSH, no k3s restart.
    info "HARBOR_PRIVATE_PROJECTS=false - node registry auth not touched"
    node_auth_rc=1
  else
    ensure_node_registry_auth || node_auth_rc=$?
  fi
  ensure_private_projects "$node_auth_rc"
}

pull_credentials_and_private_projects || warn "Phase 4b incomplete - see above; the projects keep their visibility"

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
      if curl -sSf --max-time 10 "https://${HARBOR_HOST}" >/dev/null 2>&1; then
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
    warn "  curl -sSI https://${HARBOR_HOST}"
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
info "  ✓ Pull-only robot for the nodes and ArgoCD (${NODE_PULL_SECRET} secret)"
for p in "${HARBOR_PRIVATE_PROJECT_NAMES[@]}"; do
  vis=$(harbor_api GET "/projects/${p}" | sed '$d' | jq -r 'if .metadata.public == "true" then "public" elif .metadata.public == "false" then "private" else "?" end' 2>/dev/null || echo "?")
  info "  Project ${p}: ${vis}"
done
info ""
info "Robot Account Credentials:"
if kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner >/dev/null 2>&1; then
  robot_user=$(kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
  info "  Username: ${robot_user}"
  info ""
  info "  Retrieve credentials with:"
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
