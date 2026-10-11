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
#   tools/k3s/apply-pomerium-routes.sh <env-name> [--allow-route-removal]
#
# Every apply also brings the release up to the bundled chart: its defaults and
# its image (see "Values mode" below); the live secrets and ingress values stay.
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

# --- Values mode --------------------------------------------------------------
# --reuse-values carries over the previous release's *chart defaults* as well as
# its user-supplied values, so a chart bump never reaches the cluster through this
# script: hosting kept pomerium v0.26.0 under chart 0.2.0 (image v0.33.1) until the
# tag was forced by hand, and an older Pomerium silently ignores runtimeFlags.mcp.
# --reset-then-reuse-values (Helm >= 3.14) renders the new chart's defaults and
# keeps the live user-supplied values (secrets, ingress, middleware).
#
# The image is the chart's, not the release's: a hand fix (`--set image.tag=...`)
# leaves image.tag among the user-supplied values, where it would pin the release
# for good. So every apply sets image.repository/tag to the chart's own defaults,
# unless the routes file pins them deliberately (image: in pomerium-routes.yaml).
chart_dir="$(provision::chart_path pomerium)"
values_mode=(--reset-then-reuse-values)
if ! helm upgrade --help 2>/dev/null | grep -q -- '--reset-then-reuse-values'; then
  warn "This Helm ($(helm version --short 2>/dev/null)) has no --reset-then-reuse-values (Helm >= 3.14);"
  warn "falling back to --reuse-values: the chart's image is forced, other new chart defaults are not."
  values_mode=(--reuse-values)
fi
image_args=()
if [[ -n "$(yq eval '.image // ""' "$env_routes_file")" ]]; then
  info "Image pinned by ${env_routes_file#"${envs_root}/"} (image:) - not forcing the chart's"
else
  chart_repo=$(yq eval '.image.repository // ""' "$chart_dir/values.yaml")
  chart_tag=$(yq eval '.image.tag // ""' "$chart_dir/values.yaml")
  [[ -n "$chart_repo" ]] && image_args+=(--set "image.repository=${chart_repo}")
  [[ -n "$chart_tag" ]] && image_args+=(--set "image.tag=${chart_tag}")
fi

image_before=$(kubectl -n "$NAMESPACE_SSO" get deploy pomerium-proxy \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)

# Apply routes using Helm upgrade with existing values
log "Updating Pomerium routes via Helm (${values_mode[*]})..."
helm upgrade "$helm_release" "$chart_dir" \
  --namespace "$NAMESPACE_SSO" \
  "${values_mode[@]}" \
  --values "$env_routes_file" \
  ${image_args[@]+"${image_args[@]}"} \
  --wait --timeout=3m

image_after=$(kubectl -n "$NAMESPACE_SSO" get deploy pomerium-proxy \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
if [[ "$image_before" != "$image_after" ]]; then
  info "Pomerium image: ${image_before:-<none>} -> ${image_after}"
else
  info "Pomerium image: ${image_after} (unchanged)"
fi

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
