#!/usr/bin/env bash
set -euo pipefail

# Nexus Repository provisioning for Kubernetes (k3s)
#
# Usage:
#   tools/k3s/nexus.sh <env-name> [--show-credentials]
#
# Options:
#   --show-credentials    Display deployment credentials in plaintext and exit
#
# Requires:
#   - cert-manager installed (identity.sh typically provisions it)
#   - Traefik ingress (k3s default) or set INGRESS_CLASS accordingly
#   - Cloudflare token optional for DNS automation
#

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

# --- Parse arguments ---
if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--show-credentials]" >&2
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

# Parse optional flags
SHOW_CREDENTIALS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --show-credentials)
      SHOW_CREDENTIALS=true
      shift
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# --- Validation ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
need kubectl
need helm
need jq
need yq
need curl

if ! provision::require_tools; then
  exit 1
fi

# Validate kubectl context matches environment
if ! provision::validate_kubectl_context; then
  exit 1
fi

# --- Logging helpers ---
log() { echo "[nexus] $*"; }
info() { echo "[nexus:info] $*"; }
warn() { echo "[nexus:warn] $*" >&2; }
err() { echo "[nexus:error] $*" >&2; }

# ============================================================================
# Show Credentials Mode
# ============================================================================
show_credentials() {
  local namespace="${NAMESPACE_NEXUS:-nexus}"
  
  # Validate kubectl context matches environment
  if ! provision::validate_kubectl_context; then
    exit 1
  fi
  
  # Check if deployment credentials secret exists
  if ! kubectl -n "$namespace" get secret nexus-deployment-credentials >/dev/null 2>&1; then
    err "Deployment credentials secret not found in namespace: $namespace"
    err "Run provisioning first: tools/k3s/nexus.sh ${ENV_NAME}"
    exit 1
  fi
  
  # Extract credentials
  local username password
  username=$(kubectl -n "$namespace" get secret nexus-deployment-credentials -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
  password=$(kubectl -n "$namespace" get secret nexus-deployment-credentials -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  
  if [[ -z "$username" || -z "$password" ]]; then
    err "Failed to retrieve credentials from secret"
    exit 1
  fi
  
  # Derive API host from HOSTNAME if not provided
  if [[ -n "${HOSTNAME:-}" ]]; then
    NEXUS_API_HOST="${NEXUS_API_HOST:-nexus-api.${HOSTNAME}}"
  fi
  
  if [[ -z "${NEXUS_API_HOST:-}" ]]; then
    err "NEXUS_API_HOST is not set. Set HOSTNAME in env.properties or NEXUS_API_HOST explicitly."
    exit 1
  fi

  # Display credentials in plaintext format
  echo "NEXUS_PASSWORD=${password}"
  echo "NEXUS_REGISTRY=${NEXUS_API_HOST}"
  echo "NEXUS_USERNAME=${username}"
  
  exit 0
}

# If --show-credentials flag is set, show credentials and exit
if [[ "$SHOW_CREDENTIALS" == "true" ]]; then
  show_credentials
fi

# --- Config defaults ---
NAMESPACE_NEXUS="${NAMESPACE_NEXUS:-nexus}"
: "${INGRESS_CLASS:=traefik}"
: "${CLUSTER_ISSUER:=letsencrypt-prod}"
: "${NEXUS_STORAGE_CLASS:=local-path}"
: "${NEXUS_STORAGE_SIZE:=50Gi}"
: "${NEXUS_TLS_SECRET:=nexus-tls}"
# Enforce Pomerium ForwardAuth on external access (Traefik middleware created by identity.sh)
: "${ENFORCE_POMERIUM:=true}"

# Derive host from HOSTNAME if not provided
if [[ -n "${HOSTNAME:-}" ]]; then
  NEXUS_HOST="${NEXUS_HOST:-nexus.${HOSTNAME}}"
  NEXUS_API_HOST="${NEXUS_API_HOST:-nexus-api.${HOSTNAME}}"
  info "Service host: NEXUS_HOST=${NEXUS_HOST}"
  info "API host: NEXUS_API_HOST=${NEXUS_API_HOST}"
fi

# Validate required configuration
if [[ -z "${NEXUS_HOST:-}" ]]; then
  err "NEXUS_HOST is not set. Set HOSTNAME in env.properties or NEXUS_HOST explicitly."
  exit 1
fi

if [[ -z "${NEXUS_API_HOST:-}" ]]; then
  err "NEXUS_API_HOST is not set. Set HOSTNAME in env.properties or NEXUS_API_HOST explicitly."
  exit 1
fi

if [[ -z "${EXTERNAL_IP:-}" ]]; then
  err "EXTERNAL_IP is not set in env.properties"
  exit 1
fi

log "Starting Nexus provisioning for environment: ${ENV_NAME}"

# ============================================================================
# Phase 0: DNS Management
# ============================================================================
ensure_dns_records() {
  log "=== Phase 0: DNS Management ==="

  if ! provision::cloudflare_read_token 2>/dev/null; then
    warn "Cloudflare API token not found. Skipping DNS record creation."
    warn "DNS records must be created manually or via other means."
    return 0
  fi

  # If wildcard exists for env, skip specific record
  if [[ -n "${HOSTNAME:-}" ]] && provision::cloudflare_check_wildcard "$HOSTNAME"; then
    info "Wildcard DNS record found: ${WILDCARD_PATTERN} -> ${WILDCARD_IP}"
    info "Wildcard covers Nexus access - skipping individual record creation"
  else
    # Create DNS records for both UI (SSO-protected) and API (IP-whitelisted)
    provision::cloudflare_ensure_dns_record "$NEXUS_HOST" "$EXTERNAL_IP" || \
      warn "Failed to create DNS record for $NEXUS_HOST"
    provision::cloudflare_ensure_dns_record "$NEXUS_API_HOST" "$EXTERNAL_IP" || \
      warn "Failed to create DNS record for $NEXUS_API_HOST"
  fi

  info "✓ DNS records ensured"
  info "  Public UI (SSO): ${NEXUS_HOST}"
  info "  API (IP-whitelisted): ${NEXUS_API_HOST}"
  info "  Internal CI/CD: nexus.${NAMESPACE_NEXUS}.svc.cluster.local:8081"
}

ensure_dns_records

# ============================================================================
# Phase 1: Prepare values and namespace
# ============================================================================
prepare_values() {
  log "=== Phase 1: Prepare Helm values ==="

  # Create namespace
  kubectl get ns "$NAMESPACE_NEXUS" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_NEXUS"

  # Determine PVC behavior: reuse existing if present
  local existing_pvc=""
  if kubectl -n "$NAMESPACE_NEXUS" get pvc nexus-data >/dev/null 2>&1; then
    existing_pvc="nexus-data"
    info "Found existing PVC '${existing_pvc}' - will reuse it"
  elif kubectl -n "$NAMESPACE_NEXUS" get pvc nexus-nexus-data >/dev/null 2>&1; then
    # In case release name affects PVC name
    existing_pvc="nexus-nexus-data"
    info "Found existing PVC '${existing_pvc}' - will reuse it"
  fi

  # Build temporary values override file
  VALUES_TMP=$(mktemp)

  # Disable default Ingress if using Pomerium (we'll create a separate Pomerium-routing Ingress)
  local ingress_enabled="true"
  if [[ "${ENFORCE_POMERIUM}" == "true" ]]; then
    ingress_enabled="false"
    info "Disabling default Nexus Ingress (will create Pomerium-routing Ingress instead)"
  fi

  cat > "$VALUES_TMP" <<YAML
ingress:
  enabled: ${ingress_enabled}
  className: ${INGRESS_CLASS}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    {{POMERIUM_ANNOTATION}}
  host: ${NEXUS_HOST}
  tls:
    enabled: true
    secretName: ${NEXUS_TLS_SECRET}

apiIngress:
  enabled: true
  className: ${INGRESS_CLASS}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
  host: ${NEXUS_API_HOST}
  tls:
    enabled: true
    secretName: nexus-api-tls
  ipWhitelist:
    customIPs:
YAML

  # Load custom IPs from whitelist file for apiIngress
  local whitelist_file="$ENVS_ROOT/shared/nexus-whitelist-ips.txt"
  if [[ -f "$whitelist_file" ]]; then
    info "Loading custom IPs from whitelist file for API access"
    while IFS= read -r ip; do
      [[ -z "$ip" || "$ip" =~ ^# ]] && continue
      echo "      - \"$ip\"" >> "$VALUES_TMP"
    done < "$whitelist_file"
  fi

  cat >> "$VALUES_TMP" <<YAML

persistence:
  enabled: true
  storageClass: ${NEXUS_STORAGE_CLASS}
  size: ${NEXUS_STORAGE_SIZE}
YAML

  if [[ -n "$existing_pvc" ]]; then
    cat >> "$VALUES_TMP" <<YAML
  existingClaim: ${existing_pvc}
YAML
  fi

  # Remove Pomerium annotation placeholder (we'll create a separate Pomerium-routing Ingress instead)
  sed -i '' "s#{{POMERIUM_ANNOTATION}}##" "$VALUES_TMP" || true

  info "Generated override values at $VALUES_TMP"
}

prepare_values

# ============================================================================
# Phase 2: Install/Upgrade Nexus
# ============================================================================
install_nexus() {
  log "=== Phase 2: Helm install/upgrade ==="

  helm upgrade --install nexus "$(provision::chart_path nexus)" \
    --namespace "$NAMESPACE_NEXUS" \
    --create-namespace \
    -f "$VALUES_TMP" \
    --wait --timeout 10m

  info "Waiting for Nexus StatefulSet rollout..."
  kubectl -n "$NAMESPACE_NEXUS" rollout status statefulset/nexus --timeout=600s || true

  info "✓ Nexus installed/updated"
}

install_nexus

# ============================================================================
# Phase 2b: Create Pomerium-routing Ingress
# ============================================================================
create_pomerium_ingress() {
  log "=== Phase 2b: Pomerium-routing Ingress ==="
  
  if [[ "${ENFORCE_POMERIUM}" != "true" ]]; then
    info "Pomerium enforcement disabled - skipping Pomerium-routing Ingress"
    return 0
  fi
  
  # Create an Ingress in the sso namespace that routes through Pomerium (like identity app)
  # This replaces the ForwardAuth middleware approach
  # Note: Ingress must be in same namespace as the backend service (pomerium-proxy)
  cat <<YAML | kubectl apply -f -
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nexus-pomerium
  namespace: ${NAMESPACE_SSO:-sso}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    cert-manager.io/common-name: ${NEXUS_HOST}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${NEXUS_HOST}
    secretName: nexus-pomerium-tls
  rules:
  - host: ${NEXUS_HOST}
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

  info "✓ Pomerium-routing Ingress created for Nexus"
  info "  Traffic flow: ${NEXUS_HOST} → Pomerium (sso/pomerium-proxy) → Nexus"
  info "  Note: Original nexus/nexus Ingress still exists for internal access"
}

create_pomerium_ingress

# ============================================================================
# Phase 3: Post-install - retrieve and store admin password
# ============================================================================
store_admin_password() {
  log "=== Phase 3: Admin password handling ==="

  # If secret already exists, keep it (idempotent)
  if kubectl -n "$NAMESPACE_NEXUS" get secret nexus-admin-credentials >/dev/null 2>&1; then
    info "Admin credentials secret already exists - skipping retrieval"
    return 0
  fi

  local pod
  pod=$(kubectl -n "$NAMESPACE_NEXUS" get pods -l app.kubernetes.io/name=nexus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$pod" ]]; then
    warn "Could not find Nexus pod to retrieve initial admin password"
    return 0
  fi

  # Try to read initial password file (exists until first UI login)
  local admin_pass
  if ! admin_pass=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- sh -c 'cat /nexus-data/admin.password 2>/dev/null' 2>/dev/null || true); then
    admin_pass=""
  fi

  if [[ -z "$admin_pass" ]]; then
    warn "Initial admin password file not found (may have been reset via UI)."
    warn "You can reset admin password via Nexus UI: ${NEXUS_HOST}"
    return 0
  fi

  kubectl -n "$NAMESPACE_NEXUS" create secret generic nexus-admin-credentials \
    --from-literal=username=admin \
    --from-literal=password="$admin_pass" \
    --dry-run=client -o yaml | kubectl apply -f -

  info "✓ Stored initial admin credentials in secret: nexus/${NAMESPACE_NEXUS}/nexus-admin-credentials"
}

store_admin_password

# ============================================================================
# Phase 3b: Configure Nexus security and create deployment user
# ============================================================================
configure_nexus_security() {
  log "=== Phase 3b: Configure Nexus Security ==="

  # Get Nexus pod name
  local pod
  pod=$(kubectl -n "$NAMESPACE_NEXUS" get pods -l app.kubernetes.io/name=nexus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$pod" ]]; then
    warn "Could not find Nexus pod; skipping security configuration"
    return 0
  fi

  # Wait for pod to be fully ready (Running + Ready condition)
  info "Waiting for Nexus pod to be ready..."
  local pod_ready=false
  for i in {1..60}; do
    local phase status
    phase=$(kubectl -n "$NAMESPACE_NEXUS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    status=$(kubectl -n "$NAMESPACE_NEXUS" get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$phase" == "Running" && "$status" == "True" ]]; then
      pod_ready=true
      break
    fi
    info "  Pod status: phase=${phase}, ready=${status} (waiting...)"
    sleep 5
  done
  if [[ "$pod_ready" != "true" ]]; then
    warn "Nexus pod did not become ready; skipping security configuration"
    return 0
  fi
  info "✓ Nexus pod is ready"

  # Try to get admin password from initial password file first
  info "Retrieving initial admin password from pod..."
  local admin_password
  admin_password=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- sh -c 'cat /nexus-data/admin.password 2>/dev/null' 2>/dev/null || true)
  
  if [[ -z "$admin_password" ]]; then
    # Fall back to secret if initial password file doesn't exist
    info "Initial password file not found, checking secret..."
    admin_password=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-admin-credentials -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  else
    info "✓ Retrieved initial admin password from /nexus-data/admin.password"
  fi
  
  if [[ -z "$admin_password" ]]; then
    warn "Admin password not available; skipping Nexus API configuration"
    return 0
  fi

  # Use localhost from within the pod to bypass Pomerium authentication
  local base_url="http://localhost:8081"

  info "Waiting for Nexus API to be ready..."
  local ready=false
  for i in {1..60}; do
    # Access Nexus API via localhost from within the pod
    code=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -o /dev/null -w "%{http_code}" -sS -u "admin:${admin_password}" --max-time 10 "${base_url}/service/rest/v1/status" 2>/dev/null || echo 000)
    if [[ "$code" == "200" ]]; then 
      ready=true
      break
    fi
    info "  API status: HTTP ${code} (waiting...)"
    sleep 5
  done
  if [[ "$ready" != "true" ]]; then
    warn "Nexus API did not become ready; skipping security configuration"
    return 0
  fi
  info "✓ Nexus API is ready"

  info "Disabling anonymous access (if enabled)..."
  # Get current security settings
  local anon_enabled
  anon_enabled=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -sS -u "admin:${admin_password}" --max-time 10 -H "Content-Type: application/json" "${base_url}/service/rest/v1/security/anonymous" 2>/dev/null | jq -r '.enabled // empty' || true)
  if [[ "$anon_enabled" == "true" ]]; then
    kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -sS -u "admin:${admin_password}" --max-time 10 -H "Content-Type: application/json" -X PUT \
      -d '{"enabled":false,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}' \
      "${base_url}/service/rest/v1/security/anonymous" >/dev/null 2>&1 || true
    info "  ✓ Anonymous access disabled"
  else
    info "  ✓ Anonymous already disabled"
  fi

  # Ensure deployment user exists
  local dep_user dep_pass
  dep_user="${NEXUS_DEPLOYMENT_USERNAME:-deployment}"
  dep_pass=""

  info "Ensuring deployment user '${dep_user}' exists..."
  local user_exists
  user_exists=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -sS -u "admin:${admin_password}" --max-time 10 -H "Content-Type: application/json" "${base_url}/service/rest/v1/security/users" 2>/dev/null | jq -r ".[] | select(.userId==\"${dep_user}\") | .userId" || true)
  if [[ -n "$user_exists" ]]; then
    info "  ✓ Deployment user already exists"
    # If a credentials secret exists, keep it; otherwise skip storing password we don't know
    if ! kubectl -n "$NAMESPACE_NEXUS" get secret nexus-deployment-credentials >/dev/null 2>&1; then
      warn "  No existing nexus-deployment-credentials secret; cannot retrieve existing password"
    fi
  else
    dep_pass=$(openssl rand -base64 24 | tr -d '\n')
    local payload
    payload=$(cat <<EOF
{
  "userId": "${dep_user}",
  "firstName": "Deployment",
  "lastName": "User",
  "emailAddress": "deployment@local",
  "password": "${dep_pass}",
  "status": "active",
  "roles": ["nx-admin"]
}
EOF
)
    # Note: Using nx-admin for broad CI usage; adjust to least privilege if needed.
    local create_code
    create_code=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -o /dev/null -w "%{http_code}" -sS -u "admin:${admin_password}" --max-time 10 -H "Content-Type: application/json" -X POST -d "$payload" "${base_url}/service/rest/v1/security/users" 2>/dev/null || echo 000)
    if [[ "$create_code" == "200" || "$create_code" == "201" ]]; then
      info "  ✓ Deployment user created"
      kubectl -n "$NAMESPACE_NEXUS" create secret generic nexus-deployment-credentials \
        --from-literal=username="${dep_user}" \
        --from-literal=password="${dep_pass}" \
        --dry-run=client -o yaml | kubectl apply -f -
      info "  ✓ Stored deployment credentials in secret nexus-deployment-credentials"
      info "  ℹ Note: github-action-runner.sh will copy these to its namespace with cluster-internal URL"
    else
      warn "  Failed to create deployment user (HTTP ${create_code})"
    fi
  fi
}

# Automatic security configuration - uses localhost to bypass Pomerium
configure_nexus_security || true

# ============================================================================
# Phase 3d: Configure Maven Repositories
# ============================================================================
configure_maven_repositories() {
  log "=== Phase 3d: Configure Maven Repositories ==="

  # Get Nexus pod name
  local pod
  pod=$(kubectl -n "$NAMESPACE_NEXUS" get pods -l app.kubernetes.io/name=nexus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$pod" ]]; then
    warn "Could not find Nexus pod; skipping Maven repository configuration"
    return 0
  fi

  # Get admin password
  local admin_password
  admin_password=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- sh -c 'cat /nexus-data/admin.password 2>/dev/null' 2>/dev/null || true)
  if [[ -z "$admin_password" ]]; then
    admin_password=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-admin-credentials -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  fi
  
  if [[ -z "$admin_password" ]]; then
    warn "Admin password not available; skipping Maven repository configuration"
    return 0
  fi

  local base_url="http://localhost:8081"

  # Helper function to check if repository exists
  repo_exists() {
    local repo_name="$1"
    local code
    code=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -o /dev/null -w "%{http_code}" -sS -u "admin:${admin_password}" --max-time 10 "${base_url}/service/rest/v1/repositories/${repo_name}" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]]
  }

  # 1. Create maven-central proxy repository
  info "Configuring maven-central proxy repository..."
  if repo_exists "maven-central"; then
    info "  ✓ maven-central already exists"
  else
    local payload_central
    payload_central=$(cat <<'EOF'
{
  "name": "maven-central",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "proxy": {
    "remoteUrl": "https://repo1.maven.org/maven2/",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  },
  "maven": {
    "versionPolicy": "RELEASE",
    "layoutPolicy": "STRICT"
  }
}
EOF
)
    local create_code
    create_code=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -o /dev/null -w "%{http_code}" -sS -u "admin:${admin_password}" --max-time 10 -H "Content-Type: application/json" -X POST -d "$payload_central" "${base_url}/service/rest/v1/repositories/maven/proxy" 2>/dev/null || echo 000)
    if [[ "$create_code" == "201" ]]; then
      info "  ✓ maven-central proxy created"
    else
      warn "  Failed to create maven-central (HTTP ${create_code})"
    fi
  fi

  # 2. Create maven-releases hosted repository
  info "Configuring maven-releases hosted repository..."
  if repo_exists "maven-releases"; then
    info "  ✓ maven-releases already exists"
  else
    local payload_releases
    payload_releases=$(cat <<'EOF'
{
  "name": "maven-releases",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true,
    "writePolicy": "ALLOW_ONCE"
  },
  "maven": {
    "versionPolicy": "RELEASE",
    "layoutPolicy": "STRICT"
  }
}
EOF
)
    local create_code
    create_code=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -o /dev/null -w "%{http_code}" -sS -u "admin:${admin_password}" --max-time 10 -H "Content-Type: application/json" -X POST -d "$payload_releases" "${base_url}/service/rest/v1/repositories/maven/hosted" 2>/dev/null || echo 000)
    if [[ "$create_code" == "201" ]]; then
      info "  ✓ maven-releases hosted created"
    else
      warn "  Failed to create maven-releases (HTTP ${create_code})"
    fi
  fi

  # 3. Create maven-snapshots hosted repository
  info "Configuring maven-snapshots hosted repository..."
  if repo_exists "maven-snapshots"; then
    info "  ✓ maven-snapshots already exists"
  else
    local payload_snapshots
    payload_snapshots=$(cat <<'EOF'
{
  "name": "maven-snapshots",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true,
    "writePolicy": "ALLOW"
  },
  "maven": {
    "versionPolicy": "SNAPSHOT",
    "layoutPolicy": "STRICT"
  }
}
EOF
)
    local create_code
    create_code=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -o /dev/null -w "%{http_code}" -sS -u "admin:${admin_password}" --max-time 10 -H "Content-Type: application/json" -X POST -d "$payload_snapshots" "${base_url}/service/rest/v1/repositories/maven/hosted" 2>/dev/null || echo 000)
    if [[ "$create_code" == "201" ]]; then
      info "  ✓ maven-snapshots hosted created"
    else
      warn "  Failed to create maven-snapshots (HTTP ${create_code})"
    fi
  fi

  # 4. Create maven-public group repository
  info "Configuring maven-public group repository..."
  if repo_exists "maven-public"; then
    info "  ✓ maven-public already exists"
  else
    local payload_public
    payload_public=$(cat <<'EOF'
{
  "name": "maven-public",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "group": {
    "memberNames": [
      "maven-releases",
      "maven-snapshots",
      "maven-central"
    ]
  }
}
EOF
)
    local create_code
    create_code=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -o /dev/null -w "%{http_code}" -sS -u "admin:${admin_password}" --max-time 10 -H "Content-Type: application/json" -X POST -d "$payload_public" "${base_url}/service/rest/v1/repositories/maven/group" 2>/dev/null || echo 000)
    if [[ "$create_code" == "201" ]]; then
      info "  ✓ maven-public group created"
    else
      warn "  Failed to create maven-public (HTTP ${create_code})"
    fi
  fi

  info "✓ Maven repositories configured"
  info "  Available repositories:"
  info "    - maven-central (proxy to Maven Central)"
  info "    - maven-releases (hosted releases)"
  info "    - maven-snapshots (hosted snapshots)"
  info "    - maven-public (group aggregating all Maven repositories)"
}

# Configure Maven repositories after security setup
configure_maven_repositories || true

# ============================================================================
# Phase 3e: Configure npm Repositories
# ============================================================================
configure_npm_repositories() {
  log "=== Phase 3e: Configure npm Repositories ==="

  # Get Nexus pod name
  local pod
  pod=$(kubectl -n "$NAMESPACE_NEXUS" get pods -l app.kubernetes.io/name=nexus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$pod" ]]; then
    warn "Could not find Nexus pod; skipping npm repository configuration"
    return 0
  fi

  # Get admin password
  local admin_password
  admin_password=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- sh -c 'cat /nexus-data/admin.password 2>/dev/null' 2>/dev/null || true)
  if [[ -z "$admin_password" ]]; then
    admin_password=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-admin-credentials -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  fi

  if [[ -z "$admin_password" ]]; then
    warn "Admin password not available; skipping npm repository configuration"
    return 0
  fi

  local base_url="http://localhost:8081"

  # Helper function to check if repository exists
  repo_exists() {
    local repo_name="$1"
    local code
    code=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -o /dev/null -w "%{http_code}" -sS -u "admin:${admin_password}" --max-time 10 "${base_url}/service/rest/v1/repositories/${repo_name}" 2>/dev/null || echo 000)
    [[ "$code" == "200" ]]
  }

  # 1. Create npm-private hosted repository
  info "Configuring npm-private hosted repository..."
  if repo_exists "npm-private"; then
    info "  ✓ npm-private already exists"
  else
    local payload_private
    payload_private=$(cat <<'EOF'
{
  "name": "npm-private",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true,
    "writePolicy": "ALLOW"
  }
}
EOF
)
    local create_code
    create_code=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -o /dev/null -w "%{http_code}" -sS -u "admin:${admin_password}" --max-time 10 -H "Content-Type: application/json" -X POST -d "$payload_private" "${base_url}/service/rest/v1/repositories/npm/hosted" 2>/dev/null || echo 000)
    if [[ "$create_code" == "201" ]]; then
      info "  ✓ npm-private hosted created"
    else
      warn "  Failed to create npm-private (HTTP ${create_code})"
    fi
  fi

  # 2. Create npm-proxy (proxy to npmjs.org)
  info "Configuring npm-proxy repository..."
  if repo_exists "npm-proxy"; then
    info "  ✓ npm-proxy already exists"
  else
    local payload_proxy
    payload_proxy=$(cat <<'EOF'
{
  "name": "npm-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "proxy": {
    "remoteUrl": "https://registry.npmjs.org/",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  }
}
EOF
)
    local create_code
    create_code=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -o /dev/null -w "%{http_code}" -sS -u "admin:${admin_password}" --max-time 10 -H "Content-Type: application/json" -X POST -d "$payload_proxy" "${base_url}/service/rest/v1/repositories/npm/proxy" 2>/dev/null || echo 000)
    if [[ "$create_code" == "201" ]]; then
      info "  ✓ npm-proxy created"
    else
      warn "  Failed to create npm-proxy (HTTP ${create_code})"
    fi
  fi

  # 3. Create npm-public group repository
  info "Configuring npm-public group repository..."
  if repo_exists "npm-public"; then
    info "  ✓ npm-public already exists"
  else
    local payload_public
    payload_public=$(cat <<'EOF'
{
  "name": "npm-public",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "group": {
    "memberNames": [
      "npm-private",
      "npm-proxy"
    ]
  }
}
EOF
)
    local create_code
    create_code=$(kubectl -n "$NAMESPACE_NEXUS" exec "$pod" -- curl -o /dev/null -w "%{http_code}" -sS -u "admin:${admin_password}" --max-time 10 -H "Content-Type: application/json" -X POST -d "$payload_public" "${base_url}/service/rest/v1/repositories/npm/group" 2>/dev/null || echo 000)
    if [[ "$create_code" == "201" ]]; then
      info "  ✓ npm-public group created"
    else
      warn "  Failed to create npm-public (HTTP ${create_code})"
    fi
  fi

  info "✓ npm repositories configured"
  info "  Available repositories:"
  info "    - npm-private (hosted, for publishing)"
  info "    - npm-proxy (proxy to npmjs.org)"
  info "    - npm-public (group aggregating private + proxy)"
}

# Configure npm repositories after Maven setup
configure_npm_repositories || true

# ============================================================================
# Phase 3c: Register Pomerium route (sso/pomerium-config)
# ============================================================================
register_pomerium_route() {
  log "=== Phase 3c: Register Pomerium Route ==="
  local from_url="https://${NEXUS_HOST}"
  local to_url="http://nexus.${NAMESPACE_NEXUS}.svc.cluster.local:8081"
  if provision::pomerium_routes_add "$from_url" "$to_url" "${NAMESPACE_SSO:-sso}" true true true; then
    info "✓ Pomerium route ensured: ${from_url} -> ${to_url}"
  else
    warn "Failed to ensure Pomerium route for ${from_url}"
  fi
}

register_pomerium_route || true

# ============================================================================
# Phase 4: Validation
# ============================================================================
validate_deployment() {
  log "=== Phase 4: Validation ==="

  local failed=false

  # Check StatefulSet ready replicas
  local ready
  ready=$(kubectl -n "$NAMESPACE_NEXUS" get statefulset nexus -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${ready:-0}" == "1" ]]; then
    info "  ✓ Nexus StatefulSet has 1 ready replica"
  else
    warn "  ✗ Nexus not fully ready (readyReplicas=${ready:-0})"
    failed=true
  fi

  # Check Service
  if kubectl -n "$NAMESPACE_NEXUS" get svc nexus >/dev/null 2>&1; then
    info "  ✓ Service exists"
  else
    warn "  ✗ Service not found"
    failed=true
  fi

  # Check Ingress (either in nexus namespace or Pomerium-routing in sso namespace)
  local ingress_found=false
  if kubectl -n "$NAMESPACE_NEXUS" get ingress nexus >/dev/null 2>&1; then
    info "  ✓ Ingress exists (nexus namespace)"
    ingress_found=true
  fi
  if [[ "${ENFORCE_POMERIUM}" == "true" ]] && kubectl -n "${NAMESPACE_SSO:-sso}" get ingress nexus-pomerium >/dev/null 2>&1; then
    info "  ✓ Pomerium-routing Ingress exists (${NAMESPACE_SSO:-sso} namespace)"
    ingress_found=true
  fi
  if kubectl -n "$NAMESPACE_NEXUS" get ingress nexus-api >/dev/null 2>&1; then
    info "  ✓ API Ingress exists (nexus namespace)"
    ingress_found=true
  fi
  if [[ "$ingress_found" != "true" ]]; then
    warn "  ✗ No Ingress found"
    failed=true
  fi

  # Probe endpoint (best-effort)
  local attempts=5 ok=false
  while (( attempts-- > 0 )); do
    if curl -fsS -k --max-time 5 "https://${NEXUS_HOST}" >/dev/null 2>&1; then
      ok=true; break
    fi
    sleep 3
  done
  if [[ "$ok" == "true" ]]; then
    info "  ✓ HTTPS endpoint responds"
  else
    warn "  ⚠ Endpoint may not be ready yet: https://${NEXUS_HOST}"
  fi

  if [[ "$failed" == "true" ]]; then
    return 1
  fi
  return 0
}

validate_deployment || true

# ============================================================================
# Phase 5: Save/update local env file with Nexus credentials
# ============================================================================
write_local_env_file() {
  log "=== Phase 5: Write local nexus env file ==="

  local outfile="$HOME/nexus-env.sh"
  local tmpfile
  tmpfile="$(mktemp)"

  # Resolve deployment credentials from secret
  local dep_pass
  if kubectl -n "$NAMESPACE_NEXUS" get secret nexus-deployment-credentials >/dev/null 2>&1; then
    dep_pass=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-deployment-credentials -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  fi

  if [[ -z "${dep_pass:-}" ]]; then
    warn "Deployment credentials not available; skipping $outfile generation. Re-run after nexus-deployment-credentials exists."
    return 0
  fi

  {
    echo "#!/bin/zsh"
    echo
    echo "launchctl setenv NEXUS_PASSWORD ${dep_pass}"
    echo "launchctl setenv NEXUS_REGISTRY ${NEXUS_API_HOST}"
    echo "launchctl setenv NEXUS_USERNAME deployment"
  } >"$tmpfile"

  # Secure write
  chmod 600 "$tmpfile" 2>/dev/null || true
  mv "$tmpfile" "$outfile"
  chmod 600 "$outfile" 2>/dev/null || true

  info "✓ Saved Nexus environment to $outfile (launchctl format)"
}

write_local_env_file || true

# ============================================================================
# Summary
# ============================================================================
log "=== Nexus provisioning completed for environment: ${ENV_NAME} ==="
info "Namespace: ${NAMESPACE_NEXUS}"
info ""
info "Access URLs:"
info "  Public UI (SSO):       https://${NEXUS_HOST} (requires GitHub OAuth via Pomerium)"
info "  API (IP-whitelisted):  https://${NEXUS_API_HOST} (requires Nexus credentials)"
info "  Internal (cluster):    http://nexus.${NAMESPACE_NEXUS}.svc.cluster.local:8081"
info ""
info "API Access Control:"
info "  - Restricted to cluster networks (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)"
info "  - Restricted to Tailscale VPN (100.64.0.0/10)"
info "  - Custom IPs from: envs/shared/nexus-whitelist-ips.txt"
info "  - Enforced via Traefik IP whitelist middleware"
info ""
info "Ingress:   class=${INGRESS_CLASS}, issuer=${CLUSTER_ISSUER}, tlsSecret=${NEXUS_TLS_SECRET}"
info "Storage:   class=${NEXUS_STORAGE_CLASS}, size=${NEXUS_STORAGE_SIZE}"
info ""

if kubectl -n "$NAMESPACE_NEXUS" get secret nexus-admin-credentials >/dev/null 2>&1; then
  user=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-admin-credentials -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || echo admin)
  pass_len=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-admin-credentials -o jsonpath='{.data.password}' | base64 -d 2>/dev/null | wc -c | tr -d ' ')
  info "Admin credentials stored in secret: nexus-admin-credentials (username=${user}, password length=${pass_len})"
  info "Retrieve: kubectl -n ${NAMESPACE_NEXUS} get secret nexus-admin-credentials -o jsonpath='{.data.password}' | base64 -d"
else
  info "Admin credentials secret not present (might have been reset via UI)."
fi

if kubectl -n "$NAMESPACE_NEXUS" get secret nexus-deployment-credentials >/dev/null 2>&1; then
  dep_user=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-deployment-credentials -o jsonpath='{.data.username}' | base64 -d 2>/dev/null || echo deployment)
  dep_pass_len=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-deployment-credentials -o jsonpath='{.data.password}' | base64 -d 2>/dev/null | wc -c | tr -d ' ')
  info "Deployment credentials stored in secret: nexus-deployment-credentials (username=${dep_user}, password length=${dep_pass_len})"
  info "These will be exported to GitHub repo environment by tools/k3s/registry-credentials.sh as NEXUS_USERNAME/NEXUS_PASSWORD if present."
else
  info "Deployment credentials secret not present."
fi
