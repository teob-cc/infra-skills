#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# K3S Identity & SSO Provisioning
# ============================================================================
# Provisions identity and authentication infrastructure:
# 1. cert-manager (TLS certificate management)
# 2. Dex (standalone SSO provider with GitHub OAuth)
# 3. Pomerium (auth proxy for path-based access control)
# 4. Shared secrets for SSO clients (Argo CD, Harbor, Grafana)
#
# Realm-Based Access Control:
#   /public/*     - No authentication required
#   /backoffice/* - GitHub organization SSO (via Dex)
#   /api/*        - Custom ForwardAuth (application-specific)
#
# Usage:
#   tools/k3s/identity.sh <env-name> [options]
#
# Options:
#   --skip-cert-manager      Skip cert-manager installation
#   --skip-dex               Skip Dex SSO installation
#   --skip-pomerium          Skip Pomerium provisioning (implies --skip-dex)
#   --update-oauth-secret    Force update of OAuth secret and validate OAuth App
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
  --skip-cert-manager      Skip cert-manager installation
  --skip-dex               Skip Dex SSO installation
  --update-oauth-secret    Force update of OAuth secret and validate OAuth App

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
SKIP_CERT_MANAGER=false
SKIP_DEX=false
SKIP_POMERIUM=false
UPDATE_OAUTH_SECRET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-cert-manager) SKIP_CERT_MANAGER=true; shift ;;
    --skip-dex) SKIP_DEX=true; shift ;;
    --skip-pomerium) SKIP_POMERIUM=true; shift ;;
    --update-oauth-secret) UPDATE_OAUTH_SECRET=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done
if [[ "$SKIP_DEX" == "true" ]]; then
  SKIP_POMERIUM=true
fi


# --- Validation ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need kubectl
need helm
need curl
need openssl
need envsubst

if ! provision::require_tools; then
  exit 1
fi

# --- Logging helpers ---
log() { echo "[identity] $*"; }
info() { echo "[identity:info] $*"; }
warn() { echo "[identity:warn] $*" >&2; }
err() { echo "[identity:error] $*" >&2; }

# --- Configuration ---
NAMESPACE_CERT_MANAGER="${NAMESPACE_CERT_MANAGER:-cert-manager}"
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"

# Derive hosts from HOSTNAME if not provided
if [[ -n "${HOSTNAME:-}" ]]; then
  DEX_HOST="${DEX_HOST:-dex.${HOSTNAME}}"
  IDENTITY_HOST="${IDENTITY_HOST:-identity.${HOSTNAME}}"
  AUTH_HOST="${AUTH_HOST:-auth.${HOSTNAME}}"
  
  info "Auto-generated hosts from HOSTNAME=${HOSTNAME}:"
  info "  DEX_HOST=${DEX_HOST}"
  info "  IDENTITY_HOST=${IDENTITY_HOST}"
  info "  AUTH_HOST=${AUTH_HOST}"
fi

# Required configuration
: "${ACME_EMAIL:?Set ACME_EMAIL via env var or envs/<env>/env.properties}"
: "${EXTERNAL_IP:?Set EXTERNAL_IP via env var or envs/<env>/env.properties}"
: "${CLUSTER_ISSUER:=letsencrypt-prod}"
: "${INGRESS_CLASS:=traefik}"

log "Starting identity provisioning for environment: ${ENV_NAME}"
log "  ACME Email: ${ACME_EMAIL}"
log "  External IP: ${EXTERNAL_IP}"

# ============================================================================
# Phase Functions (to be added)
# ============================================================================

ensure_dns_records() {
  log "=== Phase 0: DNS Management ==="
  
  if ! provision::cloudflare_read_token 2>/dev/null; then
    warn "Cloudflare API token not found. Skipping DNS record creation."
    warn "DNS records must be created manually or via other means."
    return 0
  fi

  # Check for wildcard DNS record using common function
  if [[ -n "${HOSTNAME:-}" ]] && provision::cloudflare_check_wildcard "$HOSTNAME"; then
    info "Wildcard DNS record found: ${WILDCARD_PATTERN} -> ${WILDCARD_IP}"
    info "Wildcard DNS covers all services - skipping DNS management"
    return 0
  fi
  
  # No wildcard found - create wildcard DNS record to cover all services
  if [[ -n "${HOSTNAME:-}" ]]; then
    local wildcard_hostname="*.${HOSTNAME}"
    info "Creating wildcard DNS record: ${wildcard_hostname} -> ${EXTERNAL_IP}"
    
    if provision::cloudflare_ensure_dns_record "$wildcard_hostname" "$EXTERNAL_IP"; then
      info "✓ Wildcard DNS record created: ${wildcard_hostname} -> ${EXTERNAL_IP}"
      info "  This covers: dex, argocd, harbor, grafana, and all future services"
    else
      warn "Failed to create wildcard DNS record: ${wildcard_hostname}"
      warn "Falling back to individual DNS record creation"
      
      # Fallback: create individual records
      if [[ -n "${DEX_HOST:-}" ]]; then
        provision::cloudflare_ensure_dns_record "$DEX_HOST" "$EXTERNAL_IP" || \
          warn "Failed to create DNS record for $DEX_HOST"
      fi
      
      if [[ -n "${IDENTITY_HOST:-}" ]]; then
        provision::cloudflare_ensure_dns_record "$IDENTITY_HOST" "$EXTERNAL_IP" || \
          warn "Failed to create DNS record for $IDENTITY_HOST"
      fi

      if [[ -n "${AUTH_HOST:-}" ]]; then
        provision::cloudflare_ensure_dns_record "$AUTH_HOST" "$EXTERNAL_IP" || \
          warn "Failed to create DNS record for $AUTH_HOST"
      fi
    fi
  fi
  
  info "✓ DNS records ensured"
}

provision_cert_manager() {
  log "=== Phase 1: cert-manager ==="
  
  # Check if already installed
  if kubectl get ns "$NAMESPACE_CERT_MANAGER" >/dev/null 2>&1 && \
     kubectl -n "$NAMESPACE_CERT_MANAGER" get deploy cert-manager >/dev/null 2>&1; then
    info "cert-manager already installed - checking status"
    
    # Verify ClusterIssuer exists
    if kubectl get clusterissuer letsencrypt-prod >/dev/null 2>&1; then
      info "✓ cert-manager and ClusterIssuer already configured"
      return 0
    else
      info "cert-manager installed but ClusterIssuer missing - will create"
    fi
  fi
  
  # Create namespace
  kubectl get ns "$NAMESPACE_CERT_MANAGER" >/dev/null 2>&1 || \
    kubectl create ns "$NAMESPACE_CERT_MANAGER"
  
  # Add Helm repo
  if ! helm repo list 2>/dev/null | grep -q jetstack; then
    helm repo add jetstack https://charts.jetstack.io
  fi
  helm repo update
  
  # Install cert-manager with CRDs
  local helm_args=(
    upgrade --install cert-manager jetstack/cert-manager
    --namespace "$NAMESPACE_CERT_MANAGER"
    --set crds.enabled=true
    --wait
    --timeout 5m
  )
  
  if [[ -n "${CERT_MANAGER_CHART_VERSION:-}" ]]; then
    helm_args+=(--version "$CERT_MANAGER_CHART_VERSION")
  fi
  
  log "Installing cert-manager via Helm..."
  helm "${helm_args[@]}"
  
  # Wait for components
  log "Waiting for cert-manager pods to be Ready..."
  kubectl -n "$NAMESPACE_CERT_MANAGER" rollout status deploy/cert-manager --timeout=180s
  kubectl -n "$NAMESPACE_CERT_MANAGER" rollout status deploy/cert-manager-webhook --timeout=180s
  kubectl -n "$NAMESPACE_CERT_MANAGER" rollout status deploy/cert-manager-cainjector --timeout=180s
  
  # Apply Cloudflare API token secret
  log "Applying Cloudflare API token secret..."
  "$REPO_ROOT/tools/sops/apply.sh" shared cloudflare.yaml
  
  # Create ClusterIssuer
  log "Creating Let's Encrypt ClusterIssuer..."
  cat <<YAML | ACME_EMAIL="$ACME_EMAIL" envsubst | kubectl apply -f -
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  namespace: ${NAMESPACE_CERT_MANAGER}
spec:
  acme:
    email: \${ACME_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: cluster-issuer-account-key
    solvers:
      - dns01:
          cloudflare:
            email: \${ACME_EMAIL}
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
YAML
  
  # Verify
  log "Verifying ClusterIssuer..."
  kubectl get clusterissuers.cert-manager.io
  
  info "✓ cert-manager provisioned successfully"
}

validate_github_oauth_app() {
  log "=== Phase 2: GitHub OAuth Validation ==="
  
  # Check if Dex is already deployed
  local dex_deployed=false
  if kubectl get ns "$NAMESPACE_SSO" >/dev/null 2>&1 && \
     kubectl -n "$NAMESPACE_SSO" get deploy dex >/dev/null 2>&1; then
    dex_deployed=true
  fi
  
  # Skip validation if Dex already deployed and not forcing update
  if [[ "$dex_deployed" == "true" && "$UPDATE_OAUTH_SECRET" != "true" ]]; then
    info "✓ Dex already deployed - OAuth credentials already configured"
    info "  Skipping OAuth App validation (use --update-oauth-secret to force update)"
    return 0
  fi
  
  # First provisioning or forced update - proceed with validation
  if [[ "$dex_deployed" == "false" ]]; then
    info "First Dex provisioning detected - OAuth App validation required"
  elif [[ "$UPDATE_OAUTH_SECRET" == "true" ]]; then
    info "Forced OAuth secret update - OAuth App validation required"
  fi
  
  local oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
  
  if [[ ! -f "$oauth_file" ]]; then
    err "GitHub OAuth credentials file not found: $oauth_file"
    err ""
    err "Create this file with:"
    err "  apiVersion: v1"
    err "  kind: Secret"
    err "  metadata:"
    err "    name: github-oauth-credentials"
    err "  stringData:"
    err "    githubClientID: \"<oauth-app-client-id>\""
    err "    githubClientSecret: \"<oauth-app-client-secret>\""
    err "    githubOrg: \"<github-org>\""
    return 1
  fi
  
  # Read credentials
  local github_client_id github_client_secret github_org dex_callback_url
  
  github_client_id=$(provision::yaml_get "$oauth_file" .stringData.githubClientID)
  github_client_secret=$(provision::yaml_get "$oauth_file" .stringData.githubClientSecret)
  github_org=$(provision::yaml_get "$oauth_file" .stringData.githubOrg)
  
  if [[ -n "$DEX_HOST" ]]; then
    dex_callback_url="https://${DEX_HOST}/callback"
  else
    dex_callback_url="https://<DEX_HOST>/callback"
  fi
  
  # Validate credentials are present
  if [[ -z "$github_client_id" || -z "$github_client_secret" || -z "$github_org" ]]; then
    err "GitHub OAuth App credentials incomplete"
    err ""
    err "1. Create OAuth App at:"
    err "   https://github.com/organizations/${github_org:-YOUR_ORG}/settings/applications/new"
    err ""
    err "2. Configure:"
    err "   • Application name: Infra SSO"
    err "   • Homepage URL: https://${DEX_HOST:-dex.example.com}"
    err "   • Callback URL: ${dex_callback_url}"
    err ""
    err "3. Update: $oauth_file"
    return 1
  fi
  
  info "✓ GitHub OAuth App credentials found"
  info "  Client ID: ${github_client_id}"
  info "  Organization: ${github_org}"
  info "  Callback URL: ${dex_callback_url}"
  
  # Interactive validation checklist
  if [[ -t 0 ]]; then
    echo ""
    info "Please verify OAuth App configuration:"
    info "  1. App exists at: https://github.com/organizations/${github_org}/settings/applications"
    info "  2. Client ID matches: ${github_client_id}"
    info "  3. Homepage URL: https://${DEX_HOST}"
    info "  4. Callback URL: ${dex_callback_url}"
    echo ""
    
    read -p "Have you verified the OAuth App? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      err "OAuth App validation not confirmed"
      return 1
    fi
  fi
  
  # Validate GitHub App credentials (for repo access)
  log "Validating GitHub App credentials..."
  if ! provision::github_validate_credentials; then
    warn "GitHub App credentials validation failed"
    warn "This may affect Argo CD repository access"
  else
    info "✓ GitHub App credentials validated"
  fi
  
  # Apply OAuth credentials to cluster
  info "Applying OAuth credentials to cluster..."
  kubectl get ns "$NAMESPACE_SSO" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_SSO"
  kubectl apply -n "$NAMESPACE_SSO" -f "$oauth_file"
  info "✓ OAuth credentials applied to namespace: $NAMESPACE_SSO"
  
  return 0
}

provision_dex() {
  log "=== Phase 3: Dex SSO ==="
  
  # Create namespace
  kubectl get ns "$NAMESPACE_SSO" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_SSO"
  
  # Read GitHub OAuth credentials
  local oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
  local github_client_id github_client_secret github_org
  
  github_client_id=$(provision::yaml_get "$oauth_file" .stringData.githubClientID)
  github_client_secret=$(provision::yaml_get "$oauth_file" .stringData.githubClientSecret)
  github_org=$(provision::yaml_get "$oauth_file" .stringData.githubOrg)
  
  if [[ -z "$github_client_id" || -z "$github_client_secret" || -z "$github_org" ]]; then
    err "GitHub OAuth credentials incomplete. Cannot provision Dex."
    return 1
  fi
  
  # Dex issuer URL
  local dex_issuer="https://${DEX_HOST}"
  
  # Check if Dex is already installed to avoid overwriting client configurations
  if helm list -n "$NAMESPACE_SSO" 2>/dev/null | grep -q "^dex"; then
    info "Dex already installed - skipping reinstallation to preserve client configurations"
    info "  Note: Client registrations via provision::dex_register_client are preserved"
    info "  Note: To force Dex reinstallation, run: helm uninstall -n $NAMESPACE_SSO dex"
    
    # Verify Dex is running
    if kubectl -n "$NAMESPACE_SSO" get pods -l app.kubernetes.io/name=dex -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
      info "  ✓ Dex is running"
    else
      warn "  Dex pod may not be running - checking status..."
      kubectl -n "$NAMESPACE_SSO" get pods -l app.kubernetes.io/name=dex
    fi
    
    return 0
  fi
  
  info "Installing Dex via Helm chart (first installation)..."
  
  # Deploy Dex using Helm
  helm upgrade --install dex "$(provision::chart_path dex)" \
    --namespace "$NAMESPACE_SSO" \
    --create-namespace \
    --set config.issuer="${dex_issuer}" \
    --set config.github.clientID="${github_client_id}" \
    --set config.github.clientSecret="${github_client_secret}" \
    --set config.github.org="${github_org}" \
    --set ingress.enabled=true \
    --set ingress.host="${DEX_HOST}" \
    --set ingress.className="${INGRESS_CLASS}" \
    --set ingress.clusterIssuer="${CLUSTER_ISSUER}" \
    --wait --timeout=3m
  
  # Verify Dex is running
  if kubectl -n "$NAMESPACE_SSO" get pods -l app.kubernetes.io/name=dex -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
    info "✓ Dex is running"
  else
    warn "Dex pod may not be running yet"
    kubectl -n "$NAMESPACE_SSO" get pods -l app.kubernetes.io/name=dex
  fi
  
  info "✓ Dex SSO provider provisioned successfully"
  info "  Issuer: ${dex_issuer}"
  info "  Static clients will be registered by service provisioning scripts"
}

register_pomerium_dex_client() {
  log "=== Phase 4: Dex Client for Pomerium ==="
  
  if [[ -z "${AUTH_HOST:-}" ]]; then
    err "AUTH_HOST not set. Cannot register Pomerium Dex client."
    return 1
  fi

  # Register both modern and legacy callback paths to avoid Unregistered redirect_uri errors
  local redirect_uri1="https://${AUTH_HOST}/oauth2/callback"
  local redirect_uri2="https://${AUTH_HOST}/.pomerium/api/v1/oauth/callback"
  local redirect_uris="${redirect_uri1},${redirect_uri2}"

  info "Registering Dex client for Pomerium with redirect URIs: ${redirect_uris}"
  local dex_client_secret
  dex_client_secret=$(provision::dex_register_client "pomerium" "Pomerium" "$redirect_uris" "$NAMESPACE_SSO") || {
    err "Failed to register Dex client for Pomerium"
    return 1
  }

  if [[ -z "$dex_client_secret" ]]; then
    err "Dex client secret for Pomerium is empty"
    return 1
  fi

  DEX_CLIENT_SECRET_POMERIUM="$dex_client_secret"
  info "✓ Dex client registered for Pomerium"
}

ensure_traefik_crds() {
	# Ensure Traefik Middleware CRDs are installed.
	# We now standardize on the traefik.io API group and no longer
	# support the legacy traefik.containo.us CRDs.
	if kubectl get crd middlewares.traefik.io >/dev/null 2>&1; then
		info "Traefik Middleware CRD already present (traefik.io)"
		return 0
	fi

	warn "Traefik Middleware CRD (traefik.io) not found. Attempting to install..."
	# Best-effort apply of official Traefik CRDs (v2). Version pinned to a stable series.
	# If your Traefik version differs, adjust TRAEFIK_VERSION env var (e.g., 2.10, 2.11).
	local TRAEFIK_VERSION
	TRAEFIK_VERSION="${TRAEFIK_VERSION:-v2.11.2}"
	local CRD_URL="https://raw.githubusercontent.com/traefik/traefik/${TRAEFIK_VERSION}/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml"
	if curl -fsSL "$CRD_URL" | kubectl apply -f - >/dev/null 2>&1; then
		if kubectl get crd middlewares.traefik.io >/dev/null 2>&1; then
			info "✓ Installed Traefik CRDs (traefik.io)"
			return 0
		fi
	fi
	warn "Failed to install Traefik CRDs (traefik.io) automatically. You can install them manually from:"
	warn "  $CRD_URL"
	return 1
}

provision_pomerium() {
  log "=== Phase 5: Pomerium Proxy ==="

  kubectl get ns "$NAMESPACE_SSO" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_SSO"

  if [[ -z "${AUTH_HOST:-}" ]]; then
    err "AUTH_HOST not set. Cannot provision Pomerium."
    return 1
  fi

  if [[ -z "${DEX_HOST:-}" ]]; then
    err "DEX_HOST not set. Cannot provision Pomerium."
    return 1
  fi

  if [[ -z "${IDENTITY_HOST:-}" ]]; then
    err "IDENTITY_HOST not set. Cannot provision Pomerium routes."
    return 1
  fi

  if [[ -z "${DEX_CLIENT_SECRET_POMERIUM:-}" ]]; then
    err "Dex client secret for Pomerium not available."
    return 1
  fi

  local shared_secret cookie_secret

  if kubectl -n "$NAMESPACE_SSO" get secret pomerium-secrets >/dev/null 2>&1; then
    shared_secret=$(kubectl -n "$NAMESPACE_SSO" get secret pomerium-secrets -o jsonpath='{.data.sharedSecret}' 2>/dev/null | base64 -d 2>/dev/null || true)
    cookie_secret=$(kubectl -n "$NAMESPACE_SSO" get secret pomerium-secrets -o jsonpath='{.data.cookieSecret}' 2>/dev/null | base64 -d 2>/dev/null || true)
  fi

  if [[ -z "$shared_secret" ]]; then
    shared_secret=$(openssl rand -base64 32 | tr -d '\n')
  fi

  if [[ -z "$cookie_secret" ]]; then
    cookie_secret=$(openssl rand -base64 32 | tr -d '\n')
  fi

  info "Installing Pomerium via Helm chart..."

  # Ensure Traefik Middleware CRDs exist (try to install if missing)
  ensure_traefik_crds || true

 	# Check if Traefik Middleware CRD exists (we only support traefik.io now)
 	local create_middleware=true
 	if ! kubectl get crd middlewares.traefik.io >/dev/null 2>&1; then
 		warn "Traefik Middleware CRD (traefik.io) not found. Will skip middleware creation."
 		create_middleware=false
 	fi

 	# Deploy Pomerium using Helm
 	local middleware_override_arg=()

  # Route management now lives in sso/pomerium-config secret.
  # If an environment-specific routes file exists, always load it via Helm values.
  # If no routes file and the secret does not exist, bootstrap minimal identity routes.
  #
  # Note: To update routes after initial provisioning, use:
  #   tools/k3s/apply-pomerium-routes.sh <env-name>
  local routes_values_arg=()
  local env_routes_file="${ENVS_ROOT}/${ENV_NAME}/pomerium-routes.yaml"
  if [[ -f "$env_routes_file" ]]; then
    info "Loading Pomerium routes from: ${env_routes_file}"
    routes_values_arg+=(--values "$env_routes_file")
  elif ! kubectl -n "$NAMESPACE_SSO" get secret pomerium-config >/dev/null 2>&1; then
    info "pomerium-config not found and no env routes file - bootstrapping default identity routes"
    routes_values_arg+=(--set-json 'config.routes=[{"from":"https://'"${IDENTITY_HOST}"'","to":"http://identity-app.sso.svc.cluster.local","prefix":"/protected","preserve_host_header":true,"pass_identity_headers":true,"allow_any_authenticated_user":true},{"from":"https://'"${IDENTITY_HOST}"'","to":"http://identity-app.sso.svc.cluster.local","prefix":"/public","preserve_host_header":true,"allow_public_unauthenticated_access":true,"pass_identity_headers":true},{"from":"https://'"${IDENTITY_HOST}"'","to":"http://identity-app.sso.svc.cluster.local","preserve_host_header":true,"allow_public_unauthenticated_access":true,"pass_identity_headers":true}]')
  else
    info "Existing pomerium-config secret detected - preserving routes"
  fi

  # Build Helm args to avoid unbound array expansion on older bash
  local helm_args=(
    upgrade --install pomerium "$(provision::chart_path pomerium)"
    --namespace "$NAMESPACE_SSO"
    --create-namespace
    --set config.authenticateServiceUrl="https://${AUTH_HOST}" \
    --set config.idpProviderUrl="https://${DEX_HOST}"
    --set config.idpClientSecret="${DEX_CLIENT_SECRET_POMERIUM}"
    --set config.cookieSecret="${cookie_secret}"
    --set config.sharedSecret="${shared_secret}"
  )
  if (( ${#routes_values_arg[@]:-0} > 0 )); then
    helm_args+=("${routes_values_arg[@]}")
  fi
  helm_args+=(
    --set ingress.enabled=true
    --set ingress.host="${AUTH_HOST}"
    --set ingress.className="${INGRESS_CLASS}"
    --set ingress.clusterIssuer="${CLUSTER_ISSUER}"
    --set middleware.create="${create_middleware}"
    --wait --timeout=3m
  )
  if (( ${#middleware_override_arg[@]:-0} > 0 )); then
    helm_args+=("${middleware_override_arg[@]}")
  fi
  helm "${helm_args[@]}"

  # Force restart to pick up config changes (Pomerium doesn't auto-reload)
  info "Restarting Pomerium to apply configuration changes..."
  kubectl -n "$NAMESPACE_SSO" rollout restart deployment pomerium-proxy >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE_SSO" rollout status deployment pomerium-proxy --timeout=60s >/dev/null 2>&1 || \
    warn "Pomerium restart timed out - routes may not be active yet"

  info "✓ Pomerium proxy deployed"
  info "  Authenticate host: https://${AUTH_HOST}"
  if [[ "$create_middleware" == "true" ]]; then
    info "  ForwardAuth middleware: sso/pomerium-auth"
  else
    info "  ForwardAuth middleware: skipped (Traefik CRD not available)"
  fi
  
  # Display configured routes count from secret
  local route_count
  route_count=$(kubectl -n "$NAMESPACE_SSO" get secret pomerium-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null | base64 -d 2>/dev/null | grep -c "^  - from:" || echo "0")
  info "  Routes configured: ${route_count}"
}

provision_identity_app() {
  log "=== Phase 6: Identity Test Application ==="
  
  local identity_host="${IDENTITY_HOST:-identity.${HOSTNAME}}"
  
  info "Deploying identity test application at https://${identity_host}"
  
  # Create a simple test application that shows authentication status
  cat <<'YAML' | kubectl apply -f -
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: identity-app-html
  namespace: sso
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
      <title>Identity Test Application</title>
      <style>
        body {
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
          max-width: 800px;
          margin: 50px auto;
          padding: 20px;
          background: #f5f5f5;
        }
        .container {
          background: white;
          padding: 30px;
          border-radius: 8px;
          box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1 { color: #333; }
        .status { 
          padding: 15px;
          margin: 20px 0;
          border-radius: 4px;
          background: #e8f5e9;
          border-left: 4px solid #4caf50;
        }
        .info {
          background: #f5f5f5;
          padding: 15px;
          border-radius: 4px;
          margin: 10px 0;
        }
        .header {
          font-weight: bold;
          color: #666;
          margin-bottom: 5px;
        }
        pre {
          background: #263238;
          color: #aed581;
          padding: 15px;
          border-radius: 4px;
          overflow-x: auto;
        }
        a {
          color: #1976d2;
          text-decoration: none;
        }
        a:hover {
          text-decoration: underline;
        }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>Identity Test Application</h1>
        
        <div class="status">
          <strong>Application is running</strong>
        </div>
        
        <h2>Purpose</h2>
        <p>This application serves as:</p>
        <ul>
          <li>OAuth/OIDC flow validation endpoint</li>
          <li>Pomerium route configuration test</li>
          <li>Identity infrastructure health check</li>
        </ul>
        
        <h2>Authentication Headers</h2>
        <div class="info">
          <div class="header">X-Pomerium-Jwt-Assertion:</div>
          <pre id="jwt">Not authenticated via Pomerium</pre>
        </div>
        
        <div class="info">
          <div class="header">X-Pomerium-Claim-Email:</div>
          <pre id="email">Not available</pre>
        </div>
        
        <div class="info">
          <div class="header">X-Pomerium-Claim-Groups:</div>
          <pre id="groups">Not available</pre>
        </div>
        
        <h2>Endpoints</h2>
        <ul>
          <li><a id="dex-oidc-link" href="#" target="_blank">Dex OIDC Configuration</a></li>
          <li><a href="/public">Public Route (no auth)</a></li>
          <li><a href="/protected">Protected Route (requires auth)</a></li>
        </ul>
        
        <h2>Request Headers</h2>
        <pre id="headers">Loading...</pre>
      </div>
      
      <script>
        // Set Dex OIDC discovery link to the dex.<domain> host inferred from current host
        (function(){
          try {
            var h = window.location.hostname || '';
            var dexHost = h.replace(/^identity\./, 'dex.');
            var link = document.getElementById('dex-oidc-link');
            if (link && dexHost && dexHost !== h) {
              link.href = 'https://' + dexHost + '/.well-known/openid-configuration';
            }
          } catch (e) { /* ignore */ }
        })();

        // Display headers from a simple endpoint
        fetch('/headers')
          .then(r => r.json())
          .then(data => {
            document.getElementById('headers').textContent = JSON.stringify(data, null, 2);
            
            // Extract Pomerium headers if present
            if (data['x-pomerium-jwt-assertion']) {
              document.getElementById('jwt').textContent = data['x-pomerium-jwt-assertion'].substring(0, 100) + '...';
            }
            if (data['x-pomerium-claim-email']) {
              document.getElementById('email').textContent = data['x-pomerium-claim-email'];
            }
            if (data['x-pomerium-claim-groups']) {
              document.getElementById('groups').textContent = data['x-pomerium-claim-groups'];
            }
          })
          .catch(err => {
            document.getElementById('headers').textContent = 'Error loading headers';
          });
      </script>
    </body>
    </html>
  protected.html: |
    <!DOCTYPE html>
    <html>
    <head>
      <title>Protected Route</title>
      <style>
        body {
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
          max-width: 900px;
          margin: 50px auto;
          padding: 20px;
          background: #f5f5f5;
        }
        .container {
          background: #fff;
          padding: 30px;
          border-radius: 8px;
          box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1 {
          color: #333;
          margin-top: 0;
        }
        h2 {
          color: #555;
          border-bottom: 2px solid #e0e0e0;
          padding-bottom: 8px;
          margin-top: 30px;
        }
        .status {
          padding: 15px;
          margin: 20px 0;
          border-radius: 4px;
          background: #e8f5e9;
          border-left: 4px solid #4caf50;
        }
        .info {
          background: #f5f5f5;
          padding: 12px 15px;
          border-radius: 4px;
          margin: 8px 0;
        }
        .label {
          font-weight: 600;
          color: #555;
          font-size: 13px;
          margin-bottom: 4px;
        }
        .value {
          color: #1a1a1a;
          font-family: 'Monaco', 'Courier New', monospace;
          font-size: 13px;
          word-break: break-all;
          background: #fff;
          padding: 8px;
          border-radius: 3px;
          border: 1px solid #e0e0e0;
          min-height: 20px;
        }
        .jwt-section {
          background: #263238;
          color: #aed581;
          padding: 15px;
          border-radius: 4px;
          margin: 10px 0;
          font-family: 'Monaco', 'Courier New', monospace;
          font-size: 12px;
          overflow-x: auto;
        }
        .jwt-claim {
          margin: 5px 0;
          padding: 5px;
        }
        .jwt-claim-key {
          color: #80cbc4;
          font-weight: bold;
        }
        .jwt-claim-value {
          color: #aed581;
        }
        a {
          color: #1976d2;
          text-decoration: none;
        }
        a:hover {
          text-decoration: underline;
        }
        .note {
          background: #fff3cd;
          border-left: 4px solid #ffc107;
          padding: 12px;
          margin: 15px 0;
          font-size: 14px;
        }
        .loading {
          color: #999;
          font-style: italic;
        }
        pre {
          background: #263238;
          color: #aed581;
          padding: 15px;
          border-radius: 4px;
          overflow-x: auto;
          font-size: 12px;
        }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>Protected Route</h1>
        
        <div class="status">
          <strong>Authenticated via Pomerium</strong>
        </div>
        
        <div class="note">
          <strong>Note:</strong> This page dynamically fetches headers and decodes JWT from <code>/headers</code> endpoint.
        </div>
        
        <h2>JWT Claims (Decoded)</h2>
        <div id="jwt-decoded" class="jwt-section loading">Loading JWT claims...</div>
        
        <h2>Identity Information</h2>
        <div class="info">
          <div class="label">Email</div>
          <div id="claim-email" class="value loading">Loading...</div>
        </div>
        <div class="info">
          <div class="label">User ID (sub)</div>
          <div id="claim-sub" class="value loading">Loading...</div>
        </div>
        <div class="info">
          <div class="label">Name</div>
          <div id="claim-name" class="value loading">Loading...</div>
        </div>
        <div class="info">
          <div class="label">Groups</div>
          <div id="claim-groups" class="value loading">Loading...</div>
        </div>
        <div class="info">
          <div class="label">User</div>
          <div id="claim-user" class="value loading">Loading...</div>
        </div>
        <div class="info">
          <div class="label">Session ID</div>
          <div id="claim-session-id" class="value loading">Loading...</div>
        </div>
        
        <h2>Request Headers</h2>
        <div class="info">
          <div class="label">Remote Address (Your IP)</div>
          <div id="header-remote-addr" class="value loading">Loading...</div>
        </div>
        <div class="info">
          <div class="label">X-Real-IP</div>
          <div id="header-real-ip" class="value loading">Loading...</div>
        </div>
        <div class="info">
          <div class="label">X-Forwarded-For</div>
          <div id="header-xff" class="value loading">Loading...</div>
        </div>
        <div class="info">
          <div class="label">Host</div>
          <div id="header-host" class="value loading">Loading...</div>
        </div>
        
        <h2>Raw Headers (JSON)</h2>
        <pre id="raw-headers">Loading...</pre>
        
        <p style="margin-top:30px">
          <a href="/">← Home</a> | 
          <a href="/public">Public Route</a> | 
          <a href="/headers">Headers API</a>
        </p>
      </div>
      
      <script>
        function decodeJWT(token) {
          try {
            const parts = token.split('.');
            if (parts.length !== 3) {
              return { error: 'Invalid JWT format (expected 3 parts)' };
            }
            
            // Decode payload (second part)
            const payload = parts[1];
            const decoded = atob(payload.replace(/-/g, '+').replace(/_/g, '/'));
            return JSON.parse(decoded);
          } catch (e) {
            return { error: 'Failed to decode JWT: ' + e.message };
          }
        }
        
        function displayJWTClaims(claims) {
          const container = document.getElementById('jwt-decoded');
          if (claims.error) {
            container.innerHTML = '<span style="color:#ef5350">' + claims.error + '</span>';
            return;
          }
          
          let html = '';
          for (const [key, value] of Object.entries(claims)) {
            const valueStr = typeof value === 'object' ? JSON.stringify(value) : String(value);
            html += '<div class="jwt-claim">';
            html += '<span class="jwt-claim-key">' + key + ':</span> ';
            html += '<span class="jwt-claim-value">' + valueStr + '</span>';
            html += '</div>';
          }
          container.innerHTML = html || '<span style="color:#999">No claims found</span>';
        }
        
        // Fetch headers and populate the page
        fetch('/headers')
          .then(r => r.json())
          .then(data => {
            // Display raw headers
            document.getElementById('raw-headers').textContent = JSON.stringify(data, null, 2);
            
            // Decode and display JWT
            if (data['x-pomerium-jwt-assertion']) {
              const claims = decodeJWT(data['x-pomerium-jwt-assertion']);
              displayJWTClaims(claims);
            } else {
              document.getElementById('jwt-decoded').innerHTML = '<span style="color:#ff9800">No JWT token found in headers</span>';
            }
            
            // Display Pomerium claims
            document.getElementById('claim-email').textContent = data['x-pomerium-claim-email'] || 'Not available';
            document.getElementById('claim-sub').textContent = data['x-pomerium-claim-sub'] || 'Not available';
            document.getElementById('claim-name').textContent = data['x-pomerium-claim-name'] || 'Not available';
            document.getElementById('claim-groups').textContent = data['x-pomerium-claim-groups'] || 'Not available';
            document.getElementById('claim-user').textContent = data['x-pomerium-claim-user'] || 'Not available';
            document.getElementById('claim-session-id').textContent = data['x-pomerium-session-id'] || 'Not available';
            
            // Display request headers
            document.getElementById('header-remote-addr').textContent = data['remote-addr'] || 'Not available';
            document.getElementById('header-real-ip').textContent = data['x-real-ip'] || 'Not available';
            document.getElementById('header-xff').textContent = data['x-forwarded-for'] || 'Not available';
            document.getElementById('header-host').textContent = data['host'] || 'Not available';
          })
          .catch(err => {
            document.getElementById('jwt-decoded').innerHTML = '<span style="color:#ef5350">Error loading headers: ' + err.message + '</span>';
            document.getElementById('raw-headers').textContent = 'Error loading headers: ' + err.message;
          });
      </script>
    </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: identity-app
  namespace: sso
spec:
  replicas: 1
  selector:
    matchLabels:
      app: identity-app
  template:
    metadata:
      labels:
        app: identity-app
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
        - name: nginx-config
          mountPath: /etc/nginx/conf.d
      volumes:
      - name: html
        configMap:
          name: identity-app-html
      - name: nginx-config
        configMap:
          name: identity-app-nginx-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: identity-app-nginx-config
  namespace: sso
data:
  default.conf: |
    server {
      listen 80;
      server_name _;
      
      # Enable real IP from upstream proxies (Traefik ingress)
      set_real_ip_from 10.0.0.0/8;
      set_real_ip_from 172.16.0.0/12;
      real_ip_header X-Forwarded-For;
      real_ip_recursive on;
      
      location / {
        root /usr/share/nginx/html;
        index index.html;
      }
      
      location /headers {
        default_type application/json;
        add_header Content-Type application/json;
        return 200 '{
          "host": "$host",
          "remote-addr": "$remote_addr",
          "x-real-ip": "$realip_remote_addr",
          "x-forwarded-for": "$http_x_forwarded_for",
          "x-pomerium-jwt-assertion": "$http_x_pomerium_jwt_assertion",
          "x-pomerium-claim-email": "$http_x_pomerium_claim_email",
          "x-pomerium-claim-groups": "$http_x_pomerium_claim_groups",
          "x-pomerium-claim-sub": "$http_x_pomerium_claim_sub",
          "x-pomerium-claim-name": "$http_x_pomerium_claim_name",
          "x-pomerium-claim-user": "$http_x_pomerium_claim_user",
          "x-pomerium-session-id": "$http_x_pomerium_session_id",
          "user-agent": "$http_user_agent"
        }';
      }
      
      location /public {
        default_type text/html;
        return 200 '<html><head><style>body{font-family:sans-serif;max-width:600px;margin:50px auto;padding:20px}</style></head><body><h1>Public Route</h1><p>This route is accessible without authentication.</p><p><a href="/">← Back to Home</a></p></body></html>';
      }
      
      location /protected {
        root /usr/share/nginx/html;
        try_files /protected.html =404;
      }
    }
---
apiVersion: v1
kind: Service
metadata:
  name: identity-app
  namespace: sso
spec:
  selector:
    app: identity-app
  ports:
  - port: 80
    targetPort: 80
YAML

  # Create Ingress that routes through Pomerium
  cat <<YAML | kubectl apply -f -
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: identity-app-pomerium
  namespace: sso
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER:-letsencrypt-prod}
    cert-manager.io/common-name: ${identity_host}
spec:
  ingressClassName: ${INGRESS_CLASS:-traefik}
  tls:
  - hosts:
    - ${identity_host}
    secretName: identity-app-tls
  rules:
  - host: ${identity_host}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: pomerium-proxy
            port:
              number: 80
YAML

  # Wait for deployment
  kubectl -n sso rollout status deployment/identity-app --timeout=120s || true
  
  info "✓ Identity test application deployed"
  info "  URL: https://${identity_host}"
  info "  Service: identity-app.sso.svc.cluster.local"
}


# export_shared_secrets function removed - secrets are now managed by individual service scripts

# ============================================================================
# Main Execution
# ============================================================================

ensure_dns_records

if [[ "$SKIP_CERT_MANAGER" != "true" ]]; then
  provision_cert_manager
fi

# Always run validation - it will auto-skip if secret exists (unless --update-oauth-secret is used)
validate_github_oauth_app

if [[ "$SKIP_DEX" != "true" ]]; then
  provision_dex

  if [[ "$SKIP_POMERIUM" != "true" ]]; then
    register_pomerium_dex_client
    provision_pomerium
    provision_identity_app
  else
    info "Skipping Pomerium provisioning per flag"
  fi
fi

# ============================================================================
# Validation
# ============================================================================

quick_checks() {
  log "=== Quick checks ==="

  # Check pods in cert-manager namespace
  if [[ "$SKIP_CERT_MANAGER" != "true" ]]; then
    if kubectl get ns "$NAMESPACE_CERT_MANAGER" >/dev/null 2>&1; then
      local total ready all_ready
      total=$(kubectl -n "$NAMESPACE_CERT_MANAGER" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
      if [[ "$total" -gt 0 ]]; then
        # Count pods where all containers are ready
        ready=$(kubectl -n "$NAMESPACE_CERT_MANAGER" get pods -o json | \
          jq -r '[.items[] | ( ( .status.containerStatuses // [] ) | all(.ready == true) )] | map(select(.==true)) | length' 2>/dev/null || echo 0)
        if [[ "$ready" == "$total" ]]; then
          info "  ✓ cert-manager pods Ready: ${ready}/${total}"
        else
          warn "  ✗ cert-manager pods Ready: ${ready}/${total}"
        fi
      else
        warn "  ✗ No pods found in namespace ${NAMESPACE_CERT_MANAGER}"
      fi
    fi
  fi

  # Check pods in sso namespace
  if [[ "$SKIP_DEX" != "true" || "$SKIP_POMERIUM" != "true" ]]; then
    if kubectl get ns "$NAMESPACE_SSO" >/dev/null 2>&1; then
      local total ready
      total=$(kubectl -n "$NAMESPACE_SSO" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
      if [[ "$total" -gt 0 ]]; then
        ready=$(kubectl -n "$NAMESPACE_SSO" get pods -o json | \
          jq -r '[.items[] | ( ( .status.containerStatuses // [] ) | all(.ready == true) )] | map(select(.==true)) | length' 2>/dev/null || echo 0)
        if [[ "$ready" == "$total" ]]; then
          info "  ✓ sso pods Ready: ${ready}/${total}"
        else
          warn "  ✗ sso pods Ready: ${ready}/${total}"
        fi
      else
        warn "  ✗ No pods found in namespace ${NAMESPACE_SSO}"
      fi
    fi
  fi

  # Dex OIDC config
  if [[ -n "${DEX_HOST:-}" ]]; then
    local oidc
    if oidc=$(curl -sS -k --max-time 10 "https://${DEX_HOST}/.well-known/openid-configuration" 2>/dev/null); then
      if command -v jq >/dev/null 2>&1; then
        local issuer expected
        issuer=$(echo "$oidc" | jq -r '.issuer // empty' 2>/dev/null || true)
        expected="https://${DEX_HOST}"
        if [[ "$issuer" == "$expected" ]]; then
          info "  ✓ Dex OIDC issuer OK: ${issuer}"
        else
          warn "  ✗ Dex OIDC issuer mismatch. Expected ${expected}, got: ${issuer:-<empty>}"
        fi
      else
        info "  ✓ Dex OIDC endpoint responded (jq not installed to validate issuer)"
      fi
    else
      warn "  ✗ Dex OIDC endpoint did not respond"
    fi
  fi
}

# Verify that the protected route redirects unauthenticated users to the authenticate service
check_protected_redirect() {
  # If hosts are not set, skip this check silently
  if [[ -z "${IDENTITY_HOST:-}" || -z "${AUTH_HOST:-}" ]]; then
    return 0
  fi
  local url="https://${IDENTITY_HOST}/protected"
  local code location
  # First get the HTTP code without following redirects (with fresh cookie jar to ensure unauthenticated state)
  code=$(curl -sS -k -c /dev/null -b /dev/null -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  # Then capture the Location header (case-insensitive to support both HTTP/1.1 and HTTP/2)
  location=$(curl -sS -k -c /dev/null -b /dev/null -D - -o /dev/null "$url" 2>/dev/null | grep -i "^location:" | cut -d' ' -f2- | tr -d '\r')

  if [[ "$code" == "302" || "$code" == "303" ]]; then
    if [[ "$location" == https://${AUTH_HOST}* ]]; then
      info "  ✓ /protected triggers auth redirect to ${AUTH_HOST}"
      return 0
    else
      warn "  ✗ /protected redirect does not point to https://${AUTH_HOST} (got: ${location:-<none>})"
      return 1
    fi
  elif [[ "$code" == "200" ]]; then
    # HTTP 200 might mean:
    # 1. User is already authenticated (has valid session)
    # 2. Route is misconfigured and allows unauthenticated access
    # Check if response contains Pomerium headers via a lightweight test
    info "  ℹ /protected returned HTTP 200 (may be authenticated or route misconfigured)"
    info "    Tip: Clear browser cookies and test manually at ${url}"
    return 0  # Don't fail validation for this case
  else
    warn "  ✗ /protected returned unexpected HTTP ${code}"
    return 1
  fi
}

# Wait up to a timeout (seconds) for pods and OIDC endpoint to become ready
wait_until_ready() {
  local timeout_secs="${1:-60}"
  local interval_cert_sso=5
  local interval_oidc=10
  local start_ts end_ts now
  start_ts=$(date +%s)
  end_ts=$((start_ts + timeout_secs))

  local cm_ok="skip" sso_ok="skip" oidc_ok="skip"

  while :; do
    now=$(date +%s)
    # cert-manager pods
    if [[ "$SKIP_CERT_MANAGER" != "true" ]]; then
      cm_ok="false"
      if kubectl get ns "$NAMESPACE_CERT_MANAGER" >/dev/null 2>&1; then
        local total ready
        total=$(kubectl -n "$NAMESPACE_CERT_MANAGER" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
        if [[ "$total" -gt 0 ]]; then
          ready=$(kubectl -n "$NAMESPACE_CERT_MANAGER" get pods -o json | jq -r '[.items[] | ( ( .status.containerStatuses // [] ) | all(.ready == true) )] | map(select(.==true)) | length' 2>/dev/null || echo 0)
          if [[ "$ready" == "$total" ]]; then
            cm_ok="true"
          fi
        fi
      fi
    fi

    # sso pods
    if [[ "$SKIP_DEX" != "true" || "$SKIP_POMERIUM" != "true" ]]; then
      sso_ok="false"
      if kubectl get ns "$NAMESPACE_SSO" >/dev/null 2>&1; then
        local total2 ready2
        total2=$(kubectl -n "$NAMESPACE_SSO" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
        if [[ "$total2" -gt 0 ]]; then
          ready2=$(kubectl -n "$NAMESPACE_SSO" get pods -o json | jq -r '[.items[] | ( ( .status.containerStatuses // [] ) | all(.ready == true) )] | map(select(.==true)) | length' 2>/dev/null || echo 0)
          if [[ "$ready2" == "$total2" ]]; then
            sso_ok="true"
          fi
        fi
      fi
    fi

    # Dex OIDC endpoint issuer check
    if [[ -n "${DEX_HOST:-}" ]]; then
      oidc_ok="false"
      local oidc_json issuer expected
      if oidc_json=$(curl -sS -k --max-time 5 "https://${DEX_HOST}/.well-known/openid-configuration" 2>/dev/null); then
        if command -v jq >/dev/null 2>&1; then
          issuer=$(echo "$oidc_json" | jq -r '.issuer // empty' 2>/dev/null || true)
          expected="https://${DEX_HOST}"
          if [[ "$issuer" == "$expected" ]]; then
            oidc_ok="true"
          fi
        else
          # if jq is missing but endpoint responds, consider ok
          oidc_ok="true"
        fi
      fi
    fi

    # Determine if all required checks are ok
    local all_ok=true
    [[ "$SKIP_CERT_MANAGER" == "true" ]] || { [[ "$cm_ok" == "true" ]] || all_ok=false; }
    { [[ "$SKIP_DEX" == "true" && "$SKIP_POMERIUM" == "true" ]] || [[ "$sso_ok" == "true" ]]; } || all_ok=false
    [[ -z "${DEX_HOST:-}" ]] || { [[ "$oidc_ok" == "true" ]] || all_ok=false; }

    if [[ "$all_ok" == "true" ]]; then
      info "Automated validation: components became ready within $((now-start_ts))s"
      return 0
    fi

    if (( now >= end_ts )); then
      warn "Automated validation: timeout ${timeout_secs}s reached; components not ready"
      return 1
    fi

    # Sleep by the smallest interval among checks
    sleep 5
  done
}

validate_deployment() {
  log "=== Validating deployment ==="
  
  local validation_failed=false
  
  # Validate cert-manager
  if [[ "$SKIP_CERT_MANAGER" != "true" ]]; then
    info "Validating cert-manager..."
    
    # Check ClusterIssuer
    if kubectl get clusterissuer letsencrypt-prod >/dev/null 2>&1; then
      local issuer_ready
      issuer_ready=$(kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
      
      if [[ "$issuer_ready" == "True" ]]; then
        info "  ✓ ClusterIssuer 'letsencrypt-prod' is Ready"
      else
        warn "  ✗ ClusterIssuer 'letsencrypt-prod' status: ${issuer_ready}"
        validation_failed=true
      fi
    else
      warn "  ✗ ClusterIssuer 'letsencrypt-prod' not found"
      validation_failed=true
    fi
    
    # Check cert-manager pods
    local cert_manager_ready
    cert_manager_ready=$(kubectl -n "$NAMESPACE_CERT_MANAGER" get pods -l app.kubernetes.io/instance=cert-manager -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | tr ' ' '\n' | grep -c "True" || echo "0")
    local cert_manager_total
    cert_manager_total=$(kubectl -n "$NAMESPACE_CERT_MANAGER" get pods -l app.kubernetes.io/instance=cert-manager --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ "$cert_manager_ready" -gt 0 && "$cert_manager_ready" -eq "$cert_manager_total" ]]; then
      info "  ✓ cert-manager pods ready: ${cert_manager_ready}/${cert_manager_total}"
    else
      warn "  ✗ cert-manager pods ready: ${cert_manager_ready}/${cert_manager_total}"
      validation_failed=true
    fi
  fi
  
  # Validate Dex
  if [[ "$SKIP_DEX" != "true" ]]; then
    info "Validating Dex SSO..."
    
    # Check Dex pods
    local dex_ready
    dex_ready=$(kubectl -n "$NAMESPACE_SSO" get pods -l app=dex -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    
    if [[ "$dex_ready" == "True" ]]; then
      info "  ✓ Dex pod is Ready"
    else
      warn "  ✗ Dex pod status: ${dex_ready:-Not Found}"
      validation_failed=true
    fi
    
    # Check Dex service
    if kubectl -n "$NAMESPACE_SSO" get svc dex >/dev/null 2>&1; then
      info "  ✓ Dex service exists"
    else
      warn "  ✗ Dex service not found"
      validation_failed=true
    fi
    
    # Check Dex ingress
    if kubectl -n "$NAMESPACE_SSO" get ingress dex >/dev/null 2>&1; then
      info "  ✓ Dex ingress exists"
    else
      warn "  ✗ Dex ingress not found"
      validation_failed=true
    fi
    
    # Test Dex OIDC endpoint
    if [[ -n "${DEX_HOST:-}" ]]; then
      info "Testing Dex OIDC endpoint..."
      
      # Check if TLS certificate already exists and is ready
      local cert_ready=false
      local initial_wait=0
      
      if kubectl -n "$NAMESPACE_SSO" get certificate dex-tls >/dev/null 2>&1; then
        local cert_status
        cert_status=$(kubectl -n "$NAMESPACE_SSO" get certificate dex-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$cert_status" == "True" ]]; then
          info "  ✓ TLS certificate already ready, skipping initial wait"
          cert_ready=true
        fi
      fi
      
      # Initial wait for cert-manager to issue certificate (only if not ready)
      if [[ "$cert_ready" != "true" ]]; then
        initial_wait=60
        info "  Waiting for TLS certificate issuance and DNS propagation..."
        info "  Initial wait: ${initial_wait}s for certificate issuance..."
        sleep "$initial_wait"
      fi
      
      # Retry configuration
      local max_duration=300  # 5 minutes total
      local retry_interval=20  # 20 seconds between retries
      local max_attempts=$((max_duration / retry_interval))
      local attempt=0
      local oidc_config_available=false
      local elapsed=0
      
      info "  Retrying every ${retry_interval}s for up to $((max_duration / 60)) minutes..."
      
      while [[ $attempt -lt $max_attempts ]]; do
        attempt=$((attempt + 1))
        elapsed=$((initial_wait + (attempt - 1) * retry_interval))
        
        # Try to fetch OIDC configuration
        if curl -sSf -k --max-time 10 "https://${DEX_HOST}/.well-known/openid-configuration" >/dev/null 2>&1; then
          oidc_config_available=true
          info "  ✓ Dex OIDC endpoint responding after ${elapsed}s"
          break
        fi
        
        # Show progress
        if [[ $attempt -lt $max_attempts ]]; then
          info "  Attempt ${attempt}/${max_attempts} failed (${elapsed}s elapsed), retrying in ${retry_interval}s..."
          sleep "$retry_interval"
        fi
      done
      
      if [[ "$oidc_config_available" == "true" ]]; then
        info "  ✓ Dex OIDC endpoint responding: https://${DEX_HOST}/.well-known/openid-configuration"
        
        # Validate OIDC configuration content
        local oidc_config
        oidc_config=$(curl -sSf -k --max-time 10 "https://${DEX_HOST}/.well-known/openid-configuration" 2>/dev/null || echo "{}")
        
        local issuer
        issuer=$(echo "$oidc_config" | jq -r '.issuer // empty' 2>/dev/null || true)
        
        if [[ "$issuer" == "https://${DEX_HOST}" ]]; then
          info "  ✓ Dex issuer correctly configured: ${issuer}"
        else
          warn "  ✗ Dex issuer mismatch. Expected: https://${DEX_HOST}, Got: ${issuer}"
          validation_failed=true
        fi
      else
        warn "  ✗ Dex OIDC endpoint not responding after $((initial_wait + max_duration))s"
        warn "    URL: https://${DEX_HOST}/.well-known/openid-configuration"
        warn ""
        warn "  Possible causes:"
        warn "    • Certificate issuance still in progress"
        warn "    • DNS propagation delay"
        warn "    • Ingress controller issues"
        warn "    • Dex pod not ready"
        warn ""
        warn "  Check certificate status:"
        warn "    kubectl -n ${NAMESPACE_SSO} get certificate dex-tls"
        warn "    kubectl -n ${NAMESPACE_SSO} describe certificate dex-tls"
        validation_failed=true
      fi
    fi
    
    # Check for individual Dex client secrets (created by service scripts)
    local client_secrets_found=()
    for client in argocd harbor grafana pomerium; do
      if kubectl -n "$NAMESPACE_SSO" get secret "dex-client-${client}" >/dev/null 2>&1; then
        client_secrets_found+=("$client")
      fi
    done
    
    if [[ ${#client_secrets_found[@]} -gt 0 ]]; then
      local secrets_list=$(IFS=,; echo "${client_secrets_found[*]}")
      info "  ✓ Dex client secrets registered: ${secrets_list}"
    else
      info "  ℹ No Dex clients registered yet (run service provisioning scripts)"
    fi
    
    # Test OAuth flow end-to-end
    if [[ -n "${DEX_HOST:-}" && "$oidc_config_available" == "true" ]]; then
      info "Testing OAuth flow end-to-end..."
      
      # Get authorization endpoint from OIDC config
      local auth_endpoint token_endpoint
      auth_endpoint=$(echo "$oidc_config" | jq -r '.authorization_endpoint // empty' 2>/dev/null || true)
      token_endpoint=$(echo "$oidc_config" | jq -r '.token_endpoint // empty' 2>/dev/null || true)
      
      if [[ -n "$auth_endpoint" && -n "$token_endpoint" ]]; then
        info "  ✓ OIDC endpoints discovered:"
        info "    Authorization: ${auth_endpoint}"
        info "    Token: ${token_endpoint}"
        
        # Test authorization endpoint (simple reachability test)
        # We can't test with query params because we don't know the registered redirect_uri
        local auth_response
        auth_response=$(curl -sS -k --max-time 10 -w "\n%{http_code}" -o /dev/null "${auth_endpoint}" 2>&1 || echo -e "\n000")
        
        local auth_http_code
        auth_http_code=$(echo "$auth_response" | tail -n 1)
        
        # Accept various success codes:
        # 400 = Bad Request (missing required params - endpoint is working)
        # 404 = Not Found (endpoint exists but path not recognized)
        # 200 = OK (unlikely without params)
        # 302/303 = Redirect
        if [[ "$auth_http_code" == "400" || "$auth_http_code" == "200" || "$auth_http_code" == "302" || "$auth_http_code" == "303" ]]; then
          info "  ✓ Authorization endpoint reachable (HTTP ${auth_http_code})"
        else
          warn "  ✗ Authorization endpoint test failed (HTTP ${auth_http_code})"
          if [[ ${#client_secrets_found[@]} -gt 0 ]]; then
            info "    Note: Registered clients: ${client_secrets_found[*]}"
          fi
          validation_failed=true
        fi
        
        # Test token endpoint (should require authentication)
        # Remove -f flag to get actual HTTP status instead of 000
        local token_response
        token_response=$(curl -sS -k --max-time 5 -w "\n%{http_code}" -o /dev/null -X POST "$token_endpoint" 2>&1 || echo -e "\n000")
        
        local token_http_code
        token_http_code=$(echo "$token_response" | tail -n 1)
        
        # Token endpoint should return 400 (bad request) or 401 (unauthorized) without valid credentials
        if [[ "$token_http_code" == "400" || "$token_http_code" == "401" ]]; then
          info "  ✓ Token endpoint responding correctly (HTTP ${token_http_code})"
        elif [[ "$token_http_code" == "405" ]]; then
          info "  ✓ Token endpoint exists (HTTP 405 - Method Not Allowed without params)"
        else
          warn "  ⚠ Token endpoint returned unexpected status (HTTP ${token_http_code})"
        fi
        
        # Validate GitHub connector configuration
        local oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
        if [[ -f "$oauth_file" ]]; then
          local github_org
          github_org=$(provision::yaml_get "$oauth_file" .stringData.githubOrg)
          
          if [[ -n "$github_org" ]]; then
            info "  ✓ OAuth flow configured for GitHub org: ${github_org}"
            info "    Users must be members of: ${github_org}"
          fi
        fi
        
      else
        warn "  ✗ Could not discover OAuth endpoints from OIDC configuration"
        validation_failed=true
      fi
    fi
  fi
  
  # Note: Dex client secrets are now managed by individual service scripts
  # Each service (argocd.sh, harbor.sh, observability.sh, pomerium.sh) creates
  # its own dex-client-{service} secret when it registers with Dex
  
  # Validate Pomerium
  if [[ "$SKIP_POMERIUM" != "true" ]]; then
    info "Validating Pomerium proxy..."
    
    if kubectl -n "$NAMESPACE_SSO" get deploy pomerium-proxy >/dev/null 2>&1; then
      local pomerium_ready
      pomerium_ready=$(kubectl -n "$NAMESPACE_SSO" get deploy pomerium-proxy -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
      if [[ "$pomerium_ready" == "True" ]]; then
        info "  ✓ Pomerium deployment is Available"
      else
        warn "  ✗ Pomerium deployment not yet available"
        validation_failed=true
      fi
    else
      warn "  ✗ Pomerium deployment not found"
      validation_failed=true
    fi
    
    if kubectl -n "$NAMESPACE_SSO" get svc pomerium-proxy >/dev/null 2>&1; then
      info "  ✓ Pomerium service exists"
    else
      warn "  ✗ Pomerium service not found"
      validation_failed=true
    fi
    
    if kubectl -n "$NAMESPACE_SSO" get ingress pomerium-authenticate >/dev/null 2>&1; then
      info "  ✓ Pomerium authenticate ingress exists"
    else
      warn "  ✗ Pomerium authenticate ingress not found"
      validation_failed=true
    fi
    
  		# Only check middleware if Traefik CRD is available (traefik.io only)
  		if kubectl get crd middlewares.traefik.io >/dev/null 2>&1; then
  			if kubectl -n "$NAMESPACE_SSO" get middleware.traefik.io pomerium-auth >/dev/null 2>&1; then
  				info "  ✓ Traefik middleware 'pomerium-auth' present (traefik.io)"
  			else
  				warn "  ✗ Traefik middleware 'pomerium-auth' missing (traefik.io)"
  				validation_failed=true
  			fi
  		else
  			info "  ⓘ Traefik middleware check skipped (CRD not available)"
  		fi

    # Verify protected route triggers authentication redirect
    info "Testing protected route redirect behavior..."
    if ! check_protected_redirect; then
      validation_failed=true
    fi
  fi
  
  # Summary with automated wait-and-retry (up to 60s)
  echo ""
  if [[ "$validation_failed" == "true" ]]; then
    info "Initial validation has warnings. Waiting up to 60s for components to become ready..."
    if wait_until_ready 60; then
      info "Components became ready within the grace period. Re-checking..."
      # Re-run lightweight checks for user-friendly output
      quick_checks || true
      # Also re-validate protected route redirect
      if ! check_protected_redirect; then
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        warn "  Validation failed: /protected does not redirect to authenticate service"
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 1
      fi
      info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      info "  ✓ All validations passed (after wait)"
      info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      return 0
    else
      warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      warn "  Validation failed after waiting 60s"
      warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      warn ""
      warn "Components did not become ready in time. You can inspect with:"
      [[ "$SKIP_CERT_MANAGER" != "true" ]] && warn "  kubectl -n ${NAMESPACE_CERT_MANAGER} get pods"
      [[ "$SKIP_DEX" != "true" ]] && warn "  kubectl -n ${NAMESPACE_SSO} get pods"
      [[ -n "${DEX_HOST:-}" ]] && warn "  curl -k https://${DEX_HOST}/.well-known/openid-configuration | jq"
      warn ""
      return 1
    fi
  else
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  ✓ All validations passed"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
  fi
}

validate_deployment

# Run quick checks that the user usually runs manually
quick_checks

# ============================================================================
# Summary
# ============================================================================

log "=== Identity provisioning completed for environment: ${ENV_NAME} ==="
info ""
info "Services provisioned:"
[[ "$SKIP_CERT_MANAGER" != "true" ]] && info "  ✓ cert-manager (namespace: ${NAMESPACE_CERT_MANAGER})"
[[ "$SKIP_DEX" != "true" ]] && info "  ✓ Dex SSO (namespace: ${NAMESPACE_SSO})"
[[ "$SKIP_POMERIUM" != "true" ]] && info "  ✓ Pomerium proxy (namespace: ${NAMESPACE_SSO})"
[[ "$SKIP_POMERIUM" != "true" ]] && info "  ✓ Identity Test App (namespace: ${NAMESPACE_SSO})"
info ""
info "Endpoints:"
[[ -n "${DEX_HOST:-}" ]] && info "  Dex: https://${DEX_HOST}"
[[ "$SKIP_POMERIUM" != "true" && -n "${AUTH_HOST:-}" ]] && info "  Pomerium Authenticate: https://${AUTH_HOST}"
[[ "$SKIP_POMERIUM" != "true" && -n "${IDENTITY_HOST:-}" ]] && info "  Identity Test App: https://${IDENTITY_HOST}"
info ""

# Note: Dex static clients are registered by individual service scripts
if [[ "$SKIP_DEX" != "true" ]]; then
  info "Dex is ready for client registration"
  info "Run service provisioning scripts to register clients:"
  info "  • tools/k3s/argocd.sh ${ENV_NAME}"
  info "  • tools/k3s/harbor.sh ${ENV_NAME}"
  info "  • tools/k3s/observability.sh ${ENV_NAME}"
  info ""
fi

# Show next steps
info "Next steps:"
info "  1. Deploy applications with realm-based routing:"
info "     See: templates/app-with-realms/"
info ""
info "  2. Update Pomerium routes:"
info "     Edit: envs/${ENV_NAME}/pomerium-routes.yaml"
info "     Apply: tools/k3s/apply-pomerium-routes.sh ${ENV_NAME}"
info ""
info "  3. Or manually edit Pomerium config:"
info "     kubectl -n ${NAMESPACE_SSO} edit secret pomerium-config"
info ""
