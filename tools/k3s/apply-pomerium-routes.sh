#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Apply Pomerium Routes
# ============================================================================
# Updates Pomerium routes configuration from environment-specific routes file.
# This script applies routes to an existing Pomerium installation without
# reinstalling the entire Pomerium deployment.
#
# Usage:
#   tools/k3s/apply-pomerium-routes.sh <env-name>
#
# Prerequisites:
#   - Pomerium must be installed (via tools/k3s/identity.sh)
#   - Routes file must exist at: envs/<env-name>/pomerium-routes.yaml
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

# --- Argument parsing ---
if [[ -z "${1:-}" ]]; then
  cat >&2 <<EOF
Usage: $0 <env-name>

Applies Pomerium routes from envs/<env-name>/pomerium-routes.yaml

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

ALLOW_ROUTE_REMOVAL=false
for arg in "$@"; do
  case "$arg" in
    --allow-route-removal) ALLOW_ROUTE_REMOVAL=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# --- Validation ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need kubectl
need helm
need jq
need yq

# Validate kubectl context matches environment
if ! provision::validate_kubectl_context; then
  exit 1
fi

# --- Logging helpers ---
log() { echo "[apply-pomerium-routes] $*"; }
info() { echo "[apply-pomerium-routes:info] $*"; }
warn() { echo "[apply-pomerium-routes:warn] $*" >&2; }
err() { echo "[apply-pomerium-routes:error] $*" >&2; }

# --- Configuration ---
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"

log "Applying Pomerium routes for environment: ${ENV_NAME}"

# Check if Pomerium is installed
if ! kubectl -n "$NAMESPACE_SSO" get deploy pomerium-proxy >/dev/null 2>&1; then
  err "Pomerium is not installed in namespace: ${NAMESPACE_SSO}"
  err "Please run: tools/k3s/identity.sh ${ENV_NAME}"
  exit 1
fi

# Resolve envs root (sibling infra-envs checkout in the split-repo layout).
envs_root="$(provision::envs_root)"

# Check if routes file exists
env_routes_file="${envs_root}/${ENV_NAME}/pomerium-routes.yaml"
if [[ ! -f "$env_routes_file" ]]; then
  err "Routes file not found: ${env_routes_file}"
  err ""
  err "Create a routes file with the following structure:"
  err "  config:"
  err "    routes:"
  err "      - from: https://example.com"
  err "        to: http://service.namespace.svc.cluster.local"
  err "        policy:"
  err "          - allow:"
  err "              or:"
  err "                - email:"
  err "                    is: user@example.com"
  exit 1
fi

info "Loading Pomerium routes from: ${env_routes_file}"

# Get current Helm release values to preserve configuration
log "Retrieving current Pomerium configuration..."
helm_release="pomerium"

if ! helm list -n "$NAMESPACE_SSO" 2>/dev/null | grep -q "^${helm_release}"; then
  err "Pomerium Helm release '${helm_release}' not found in namespace: ${NAMESPACE_SSO}"
  err "Please run: tools/k3s/identity.sh ${ENV_NAME}"
  exit 1
fi

# --- Route-drift guard ------------------------------------------------------
# The helm upgrade below replaces config.routes wholesale (last writer wins).
# Applying from a stale envs checkout silently deletes every route committed
# since it was last pulled — an entire app's hostname goes dark with no error.
# Compare live route hosts against the file and refuse to drop any unless
# --allow-route-removal is passed (deliberate removals are rare; pulls aren't).
live_hosts=$(helm get values "$helm_release" -n "$NAMESPACE_SSO" -o json 2>/dev/null | \
  jq -r '.config.routes // [] | .[].from' | sort -u)
file_hosts=$(yq eval '.config.routes // [] | .[].from' "$env_routes_file" | sort -u)
dropped_hosts=$(comm -23 <(echo "$live_hosts") <(echo "$file_hosts") | sed '/^$/d')
if [[ -n "$dropped_hosts" ]]; then
  if [[ "$ALLOW_ROUTE_REMOVAL" == "true" ]]; then
    warn "Removing routes for hosts (per --allow-route-removal):"
    while IFS= read -r h; do warn "  - $h"; done <<< "$dropped_hosts"
  else
    err "Refusing to apply: these hosts have live routes but none in ${env_routes_file}:"
    while IFS= read -r h; do err "  - $h"; done <<< "$dropped_hosts"
    err ""
    err "Most likely the envs checkout is stale — git pull it and retry."
    err "To deliberately remove these hosts' routes, re-run with --allow-route-removal."
    exit 1
  fi
fi

# Apply routes using Helm upgrade with existing values
log "Updating Pomerium routes via Helm..."
helm upgrade "$helm_release" "$(provision::chart_path pomerium)" \
  --namespace "$NAMESPACE_SSO" \
  --reuse-values \
  --values "$env_routes_file" \
  --wait --timeout=3m

# Force restart to pick up config changes (Pomerium doesn't auto-reload)
info "Restarting Pomerium to apply route changes..."
kubectl -n "$NAMESPACE_SSO" rollout restart deployment pomerium-proxy
kubectl -n "$NAMESPACE_SSO" rollout status deployment pomerium-proxy --timeout=60s || \
  warn "Pomerium restart timed out - routes may not be active yet"

# Display configured routes count from secret
route_count=$(kubectl -n "$NAMESPACE_SSO" get secret pomerium-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null | base64 -d 2>/dev/null | grep -c "^  - from:" || echo "0")

info "✓ Pomerium routes applied successfully"
info "  Routes configured: ${route_count}"
info "  Namespace: ${NAMESPACE_SSO}"

log "=== Route application completed for environment: ${ENV_NAME} ==="
