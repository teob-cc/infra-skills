#!/usr/bin/env bash
set -euo pipefail

# GitOps provisioning script for Kubernetes clusters.
# Provisions Argo CD with Dex SSO integration.
#
# Prerequisites:
#   - identity.sh must have been run first (provides Dex SSO)
#   - cert-manager must be installed
#   - GitHub OAuth App configured in Dex
#
# Usage:
#   tools/k3s/argocd.sh <env-name>

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
need yq

if ! provision::require_tools; then
  exit 1
fi

# Validate kubectl context matches environment
if ! provision::validate_kubectl_context; then
  exit 1
fi

# --- Logging helpers ---
log() { echo "[gitops] $*"; }
info() { echo "[gitops:info] $*"; }
warn() { echo "[gitops:warn] $*" >&2; }
err() { echo "[gitops:error] $*" >&2; }

# --- Config defaults ---
NAMESPACE_ARGOCD="${NAMESPACE_ARGOCD:-argocd}"
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"

# Derive hosts from HOSTNAME if not provided
if [[ -n "${HOSTNAME:-}" ]]; then
  ARGOCD_HOST="${ARGOCD_HOST:-argocd.${HOSTNAME}}"
  DEX_HOST="${DEX_HOST:-dex.${HOSTNAME}}"
  
  info "Service hosts:"
  info "  ARGOCD_HOST=${ARGOCD_HOST}"
  info "  DEX_HOST=${DEX_HOST}"
fi

# Validate required configuration
if [[ -z "${ARGOCD_HOST:-}" ]]; then
  err "ARGOCD_HOST is not set. Set HOSTNAME in env.properties or ARGOCD_HOST explicitly."
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

# GitOps repo URL: REPO_URL env var wins; else GITOPS_REPO_URL from env.properties;
# else derived from the environment's GitHub org as https://github.com/<org>/infra-envs.git
if [[ -z "${REPO_URL:-}" ]]; then
  if [[ -n "${GITOPS_REPO_URL:-}" ]]; then
    REPO_URL="$GITOPS_REPO_URL"
  else
    gitops_org=$(provision::yaml_get "$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml" .stringData.githubOrg 2>/dev/null || true)
    if [[ -z "${gitops_org}" || "${gitops_org}" == "null" ]]; then
      err "Cannot determine the GitOps repo URL: set GITOPS_REPO_URL in env.properties (or REPO_URL in the environment)."
      exit 1
    fi
    REPO_URL="https://github.com/${gitops_org}/infra-envs.git"
  fi
fi

log "Starting GitOps provisioning for environment: ${ENV_NAME}"

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
    local dex_ready
    dex_ready=$(kubectl -n "$NAMESPACE_SSO" get pods -l app=dex -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    
    if [[ "$dex_ready" == "True" ]]; then
      info "  ✓ Dex is running and ready"
    else
      warn "  ⚠ Dex pod exists but may not be ready (status: ${dex_ready})"
    fi
  fi
  
  # Check if Dex ConfigMap exists (required for client registration)
  info "Checking Dex configuration..."
  if kubectl -n "$NAMESPACE_SSO" get configmap dex-config >/dev/null 2>&1; then
    info "  ✓ Dex ConfigMap 'dex-config' exists"
  else
    err "  ✗ Dex ConfigMap 'dex-config' not found in ${NAMESPACE_SSO}."
    err "     This is required for Dex client registration. Run identity.sh first."
    validation_failed=true
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
    info "Wildcard DNS covers Argo CD - skipping individual record creation"
  else
    # Create DNS record for Argo CD
    if [[ -n "${ARGOCD_HOST:-}" ]]; then
      provision::cloudflare_ensure_dns_record "$ARGOCD_HOST" "$EXTERNAL_IP" || \
        warn "Failed to create DNS record for $ARGOCD_HOST"
    fi
  fi
  
  info "✓ DNS records ensured"
}

ensure_dns_records

# ============================================================================
# Phase 2: Register Dex Client for Argo CD
# ============================================================================

register_dex_client() {
  log "=== Phase 2: Register Dex Client for Argo CD ==="
  
  # Register Argo CD as a Dex client
  local redirect_uris="https://${ARGOCD_HOST}/api/dex/callback,https://${ARGOCD_HOST}/auth/callback"
  local dex_client_secret
  
  dex_client_secret=$(provision::dex_register_client "argocd" "Argo CD" "$redirect_uris" "$NAMESPACE_SSO") || {
    err "Failed to register Dex client for Argo CD"
    exit 1
  }
  
  # Export for use in Argo CD configuration
  export DEX_CLIENT_SECRET="$dex_client_secret"
  
  info "✓ Dex client registered for Argo CD"
  info "  Redirect URIs: ${redirect_uris}"
}

register_dex_client

# ============================================================================
# Phase 3: GitHub Credentials
# ============================================================================

apply_github_credentials() {
  log "=== Phase 3: GitHub Credentials ==="
  
  local github_app_file="$ENVS_ROOT/shared/secrets.plain/github-app-credentials.yaml"
  local github_oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
  
  # Validate files exist
  if [[ ! -f "$github_app_file" ]]; then
    err "GitHub App credentials file not found: $github_app_file"
    exit 1
  fi
  
  if [[ ! -f "$github_oauth_file" ]]; then
    err "GitHub OAuth credentials file not found: $github_oauth_file"
    exit 1
  fi
  
  # Create namespace
  kubectl get ns "$NAMESPACE_ARGOCD" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_ARGOCD"
  
  # Apply GitHub App credentials (for Argo CD repo access)
  info "Applying GitHub App credentials to ${NAMESPACE_ARGOCD}..."
  yq eval ".metadata.namespace = \"$NAMESPACE_ARGOCD\" | .metadata.name = \"github-app-credentials\"" "$github_app_file" | kubectl apply -f - || {
    err "Failed to apply github-app-credentials to namespace $NAMESPACE_ARGOCD"
    exit 1
  }
  
  # Apply GitHub OAuth credentials (for Dex SSO - already in argocd namespace from identity.sh)
  info "Verifying GitHub OAuth credentials in ${NAMESPACE_ARGOCD}..."
  if ! kubectl -n "$NAMESPACE_ARGOCD" get secret github-oauth-credentials >/dev/null 2>&1; then
    info "Applying GitHub OAuth credentials to ${NAMESPACE_ARGOCD}..."
    yq eval ".metadata.namespace = \"$NAMESPACE_ARGOCD\" | .metadata.name = \"github-oauth-credentials\"" "$github_oauth_file" | kubectl apply -f - || {
      err "Failed to apply github-oauth-credentials to namespace $NAMESPACE_ARGOCD"
      exit 1
    }
  else
    info "  ✓ GitHub OAuth credentials already exist in ${NAMESPACE_ARGOCD}"
  fi
  
  info "✓ GitHub credentials applied"
}

apply_github_credentials

# ============================================================================
# Phase 4: Argo CD Provisioning
# ============================================================================

provision_argocd() {
  log "=== Phase 4: Argo CD Provisioning ==="
  
  # Add Helm repo
  if ! helm repo list 2>/dev/null | grep -q "argo-cd"; then
    info "Adding Argo CD Helm repository..."
    helm repo add argo-cd https://argoproj.github.io/argo-helm
  fi
  helm repo update argo-cd
  
  # Load GitHub OAuth config
  local oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
  local github_org
  github_org=$(provision::yaml_get "$oauth_file" .stringData.githubOrg)
  
  if [[ -z "$github_org" ]]; then
    err "GitHub organization not found in github-oauth-credentials.yaml"
    exit 1
  fi
  
  # Get Dex issuer URL
  local dex_issuer="https://${DEX_HOST}"
  
  # Use Dex client secret from registration phase
  if [[ -z "${DEX_CLIENT_SECRET:-}" ]]; then
    err "DEX_CLIENT_SECRET not set. Dex client registration may have failed."
    exit 1
  fi
  
  # Generate or retrieve webhook secret for GitHub
  local webhook_secret
  if kubectl -n "$NAMESPACE_ARGOCD" get secret argocd-secret -o jsonpath='{.data.webhook\.github\.secret}' 2>/dev/null | base64 -d 2>/dev/null | grep -q .; then
    webhook_secret=$(kubectl -n "$NAMESPACE_ARGOCD" get secret argocd-secret -o jsonpath='{.data.webhook\.github\.secret}' | base64 -d)
    info "Using existing GitHub webhook secret"
  else
    webhook_secret=$(openssl rand -hex 20)
    info "Generated new GitHub webhook secret"
  fi
  export ARGOCD_WEBHOOK_SECRET="$webhook_secret"
  
  info "Configuring Argo CD with Dex SSO..."
  info "  Dex issuer: ${dex_issuer}"
  info "  GitHub org: ${github_org}"
  
  # Render Helm values
  local values_file
  values_file=$(mktemp -t argocd-values-XXXX.yaml)
  
  cat <<YAML > "$values_file"
configs:
  params:
    server.insecure: true
  cm:
    url: https://${ARGOCD_HOST}
    admin.enabled: "true"

    # Reconciliation cadence. Default upstream is 180s. We keep it tight (10s) so that
    # non-webhook-driven changes (manual edits, ConfigMap drift, missed webhooks) get
    # picked up fast. GitHub webhook configured below still triggers instant sync on
    # push, but this guarantees a hard upper bound when the webhook misses.
    timeout.reconciliation: 10s

    # OIDC configuration pointing to external Dex
    oidc.config: |
      name: Dex
      issuer: ${dex_issuer}
      clientID: argocd
      clientSecret: \$oidc.default.clientSecret
      requestedScopes:
        - openid
        - profile
        - email
        - groups
      requestedIDTokenClaims:
        groups:
          essential: true
  
  rbac:
    policy.default: ''
    policy.csv: |
      # Grant admin role to GitHub organization admins
      g, ${github_org}:admins, role:admin
      
      # Admin role has full access to everything
      p, role:admin, applications, *, */*, allow
      p, role:admin, clusters, *, *, allow
      p, role:admin, repositories, *, *, allow
      p, role:admin, projects, *, *, allow
      p, role:admin, accounts, *, *, allow
      p, role:admin, certificates, *, *, allow
      p, role:admin, gpgkeys, *, *, allow
      p, role:admin, logs, *, *, allow
      p, role:admin, exec, *, *, allow
      
      # Readonly role - can view everything but not modify
      p, role:readonly, applications, get, */*, allow
      p, role:readonly, applications, list, */*, allow
      p, role:readonly, clusters, get, *, allow
      p, role:readonly, clusters, list, *, allow
      p, role:readonly, repositories, get, *, allow
      p, role:readonly, repositories, list, *, allow
      p, role:readonly, projects, get, *, allow
      p, role:readonly, projects, list, *, allow
      p, role:readonly, logs, get, */*, allow
      
      # Grant readonly role to all authenticated users from the org
      g, ${github_org}:*, role:readonly

repoServer:
  env:
    - name: ARGOCD_GIT_USE_SSH_AGENT
      value: "false"
    - name: GIT_SSH_COMMAND
      value: "ssh -o IdentityAgent=none -o IdentitiesOnly=yes"

applicationController:
  env:
    - name: ARGOCD_GIT_USE_SSH_AGENT
      value: "false"
    - name: GIT_SSH_COMMAND
      value: "ssh -o IdentityAgent=none -o IdentitiesOnly=yes"

# Disable embedded Dex (we use external Dex from identity.sh)
dex:
  enabled: false

server:
  insecure: true
  service:
    type: ClusterIP

global:
  domain: ${ARGOCD_HOST}

server:
  # No direct ingress: argocd-server is reached via Pomerium (SSO / GitHub-team gate).
  # The Pomerium ingress for ${ARGOCD_HOST} is created below (in the sso namespace);
  # the Pomerium route lives in envs/<env>/pomerium-routes.yaml. argocd-server runs with
  # server.insecure=true (plain HTTP on :8080), so Pomerium proxies to it over HTTP.
  ingress:
    enabled: false
YAML
  
  # Check if Argo CD is already installed to avoid updating ingress
  if helm list -n "$NAMESPACE_ARGOCD" 2>/dev/null | grep -q "^argocd"; then
    info "Argo CD already installed - updating without modifying ingress..."
    # Reuse existing ingress configuration to avoid triggering cert-manager
    helm upgrade --install argocd argo-cd/argo-cd \
      --namespace "$NAMESPACE_ARGOCD" \
      --wait \
      --timeout 10m \
      --reuse-values \
      -f "$values_file"
    info "  Note: Ingress not updated to avoid cert-manager rate limits"
  else
    info "Installing Argo CD via Helm..."
    helm upgrade --install argocd argo-cd/argo-cd \
      --namespace "$NAMESPACE_ARGOCD" \
      --create-namespace \
      --wait \
      --timeout 10m \
      -f "$values_file"
  fi
  
  # Pomerium ingress for the Argo CD UI/API (argocd-server has no direct ingress).
  # Pomerium gates access (GitHub team via Dex); ArgoCD's own Dex SSO + RBAC applies behind it.
  # The matching Pomerium route is in envs/<env>/pomerium-routes.yaml (apply-pomerium-routes.sh).
  info "Creating Pomerium ingress for ${ARGOCD_HOST} ..."
  kubectl apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-pomerium
  namespace: sso
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER:-letsencrypt-prod}
    cert-manager.io/common-name: ${ARGOCD_HOST}
spec:
  ingressClassName: ${INGRESS_CLASS:-traefik}
  rules:
    - host: ${ARGOCD_HOST}
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
        - ${ARGOCD_HOST}
      secretName: argocd-pomerium-tls
YAML
  # Remove a leftover direct argocd-server ingress from older installs (now disabled in Helm values).
  kubectl -n "$NAMESPACE_ARGOCD" delete ingress argocd-server --ignore-not-found

  # Store Dex client secret and GitHub webhook secret in argocd-secret.
  # We patch these post-install rather than rendering them into Helm values,
  # because the values file is committed to disk via heredoc and any ${VAR}
  # references would be passed through verbatim to argocd-secret without
  # substitution (no envsubst pass).
  info "Configuring OIDC client secret and GitHub webhook secret..."
  kubectl -n "$NAMESPACE_ARGOCD" patch secret argocd-secret \
    -p "{\"stringData\":{\"oidc.default.clientSecret\":\"${DEX_CLIENT_SECRET}\",\"webhook.github.secret\":\"${ARGOCD_WEBHOOK_SECRET}\"}}" \
    --type=merge
  
  # Restart Argo CD server to pick up OIDC configuration
  info "Restarting Argo CD server to apply OIDC configuration..."
  kubectl -n "$NAMESPACE_ARGOCD" rollout restart deployment/argocd-server
  
  info "Waiting for Argo CD components to be ready..."
  kubectl -n "$NAMESPACE_ARGOCD" rollout status deploy/argocd-server --timeout=600s || true
  kubectl -n "$NAMESPACE_ARGOCD" rollout status deploy/argocd-repo-server --timeout=600s || true
  kubectl -n "$NAMESPACE_ARGOCD" rollout status deploy/argocd-applicationset-controller --timeout=600s || true
  
  # Cleanup temp file
  rm -f "$values_file"
  
  info "✓ Argo CD provisioned successfully"
}

provision_argocd

# ============================================================================
# Phase 5: Configure Argo CD Resources
# ============================================================================

configure_argocd_resources() {
  log "=== Phase 5: Configure Argo CD Resources ==="
  
  local repo_url="${REPO_URL}"
  
  # Create AppProject for environment
  info "Creating AppProject for ${ENV_NAME}..."
  kubectl apply -f - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ${ENV_NAME}
  namespace: ${NAMESPACE_ARGOCD}
spec:
  description: ArgoCD project for ${ENV_NAME} environment
  sourceRepos:
    - '*'
  destinations:
    - namespace: '*'
      server: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
YAML
  
  info "✓ AppProject '${ENV_NAME}' created"
  
  # Configure repository credentials using GitHub App
  info "Configuring repository credentials..."
  local app_file="$ENVS_ROOT/shared/secrets.plain/github-app-credentials.yaml"
  
  if [[ ! -f "$app_file" ]]; then
    warn "GitHub App credentials file not found: $app_file"
    warn "Repository credentials not configured - you'll need to add them manually"
  else
    local gh_app_id gh_app_installation_id gh_app_private_key
    gh_app_id=$(provision::yaml_get "$app_file" .stringData.githubAppID)
    gh_app_installation_id=$(provision::yaml_get "$app_file" .stringData.githubAppInstallationID)
    gh_app_private_key=$(provision::yaml_get "$app_file" .stringData.githubAppPrivateKey)
    
    if [[ -n "$gh_app_id" && -n "$gh_app_installation_id" && -n "$gh_app_private_key" ]]; then
      kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: repo-argocd-infra
  namespace: ${NAMESPACE_ARGOCD}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${repo_url}
  githubAppID: "${gh_app_id}"
  githubAppInstallationID: "${gh_app_installation_id}"
  githubAppPrivateKey: |
$(echo "$gh_app_private_key" | sed 's/^/    /')
YAML
      info "✓ Repository credentials configured for ${repo_url}"
    else
      warn "GitHub App credentials incomplete in github-app-credentials.yaml"
      warn "Repository credentials not configured"
    fi
  fi
  
  # Create root application (apps-of-apps pattern)
  info "Creating root application for ${ENV_NAME}..."
  kubectl apply -f - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ENV_NAME}-root
  namespace: ${NAMESPACE_ARGOCD}
spec:
  project: ${ENV_NAME}
  source:
    repoURL: ${repo_url}
    targetRevision: HEAD
    path: envs/${ENV_NAME}/apps
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NAMESPACE_ARGOCD}
  syncPolicy:
    automated:
      prune: true
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
YAML
  
  info "✓ Root application '${ENV_NAME}-root' created"
  info "  Repository: ${repo_url}"
  info "  Path: envs/${ENV_NAME}/apps"
}

configure_argocd_resources

# ============================================================================
# Phase 6: Validation
# ============================================================================

validate_deployment() {
  log "=== Phase 6: Validation ==="
  
  local validation_failed=false
  
  # Validate Argo CD pods
  info "Validating Argo CD deployment..."
  
  local argocd_server_ready
  argocd_server_ready=$(kubectl -n "$NAMESPACE_ARGOCD" get pods -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  
  if [[ "$argocd_server_ready" == "True" ]]; then
    info "  ✓ Argo CD server pod is Ready"
  else
    warn "  ✗ Argo CD server pod not ready (status: ${argocd_server_ready})"
    validation_failed=true
  fi
  
  # Check Argo CD service
  if kubectl -n "$NAMESPACE_ARGOCD" get svc argocd-server >/dev/null 2>&1; then
    info "  ✓ Argo CD server service exists"
  else
    warn "  ✗ Argo CD server service not found"
    validation_failed=true
  fi
  
  # Check Argo CD Pomerium ingress (argocd-server has no direct ingress; it's behind Pomerium)
  if kubectl -n sso get ingress argocd-pomerium >/dev/null 2>&1; then
    info "  ✓ Argo CD Pomerium ingress exists"
  else
    warn "  ✗ Argo CD Pomerium ingress not found (sso/argocd-pomerium)"
    validation_failed=true
  fi
  
  # Check OIDC configuration
  info "Validating OIDC configuration..."
  
  local oidc_client_secret
  oidc_client_secret=$(kubectl -n "$NAMESPACE_ARGOCD" get secret argocd-secret -o jsonpath='{.data.oidc\.default\.clientSecret}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  if [[ -n "$oidc_client_secret" ]]; then
    info "  ✓ OIDC client secret configured"
  else
    warn "  ✗ OIDC client secret not found in argocd-secret"
    validation_failed=true
  fi
  
  # Test Argo CD endpoint
  if [[ -n "${ARGOCD_HOST:-}" ]]; then
    info "Testing Argo CD endpoint..."
    
    # Check if TLS certificate is ready (on the Pomerium ingress, in the sso namespace)
    local cert_ready=false
    if kubectl -n sso get certificate argocd-pomerium-tls >/dev/null 2>&1; then
      local cert_status
      cert_status=$(kubectl -n sso get certificate argocd-pomerium-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
      
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
      if curl -sSf -k --max-time 10 "https://${ARGOCD_HOST}" >/dev/null 2>&1; then
        info "  ✓ Argo CD endpoint responding"
        endpoint_ok=true
        break
      fi
      
      attempt=$((attempt + 1))
      if [[ $attempt -lt $max_attempts ]]; then
        sleep 5
      fi
    done
    
    if [[ "$endpoint_ok" != "true" ]]; then
      warn "  ⚠ Argo CD endpoint not responding after ${max_attempts} attempts"
      warn "    URL: https://${ARGOCD_HOST}"
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
    warn "  kubectl -n ${NAMESPACE_ARGOCD} get pods"
    warn "  kubectl -n ${NAMESPACE_ARGOCD} get ingress"
    warn "  kubectl -n ${NAMESPACE_ARGOCD} get certificate"
    warn "  curl -k https://${ARGOCD_HOST}"
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

log "=== GitOps provisioning completed for environment: ${ENV_NAME} ==="
info ""
info "Services provisioned:"
info "  ✓ Argo CD (namespace: ${NAMESPACE_ARGOCD})"
info ""
info "Endpoints:"
info "  Argo CD: https://${ARGOCD_HOST}"
info ""
info "Authentication:"
info "  SSO via Dex: ${DEX_HOST}"
info "  GitHub organization: $(provision::yaml_get "$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml" .stringData.githubOrg)"
info ""
info "Argo CD Resources:"
info "  ✓ AppProject: ${ENV_NAME}"
info "  ✓ Repository: ${REPO_URL}"
info "  ✓ Root Application: ${ENV_NAME}-root"
info "    Path: envs/${ENV_NAME}/apps"
info ""
info "GitHub Webhook (for instant sync on push):"
info "  Webhook URL: https://${ARGOCD_HOST}/api/webhook"
info "  Content type: application/json"
info "  Secret: $(kubectl -n ${NAMESPACE_ARGOCD} get secret argocd-secret -o jsonpath='{.data.webhook\.github\.secret}' 2>/dev/null | base64 -d || echo '<not set>')"
info "  Events: Just the push event"
info ""
info "Sync Behavior:"
info "  ✓ Webhook triggers instant sync on git push"
info "  ✓ Manual changes persist until next git sync (selfHeal disabled)"
info "  ✓ Pruning enabled (deleted resources are removed)"
info ""
info "Next steps:"
info "  1. Access Argo CD: https://${ARGOCD_HOST}"
info "  2. Login with GitHub SSO"
info "  3. Configure GitHub webhook in repo Settings > Webhooks"
info "  4. Root application will auto-sync apps from envs/${ENV_NAME}/apps"
info ""
info "To get admin password (for emergency access):"
info "  kubectl -n ${NAMESPACE_ARGOCD} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
info ""
