#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# K3S WireGuard VPN Provisioning (wg-portal)
# ============================================================================
# Provisions WireGuard VPN infrastructure with wg-portal web management:
# 1. Host prerequisites (IP forwarding, kernel module)
# 2. Namespace and secrets
# 3. wg-portal deployment (via ArgoCD or direct Helm)
# 4. Firewall validation
#
# Usage:
#   tools/k3s/wireguard.sh <env-name> [options]
#
# Options:
#   --check-host             Check host prerequisites via SSH and exit
#   --setup-host             Apply host prerequisites via SSH (sysctl, modprobe)
#   --apply-secrets          Decrypt and apply SOPS secrets only
#   --status                 Show WireGuard status (wg show, pods, services)
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

# --- Parse arguments ---
if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--check-host] [--setup-host] [--apply-secrets] [--status]" >&2
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
CHECK_HOST=false
SETUP_HOST=false
APPLY_SECRETS=false
STATUS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-host) CHECK_HOST=true; shift ;;
    --setup-host) SETUP_HOST=true; shift ;;
    --apply-secrets) APPLY_SECRETS=true; shift ;;
    --status) STATUS=true; shift ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validation ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
need kubectl
need helm
need jq
need yq

if ! provision::require_tools; then
  exit 1
fi

if ! provision::validate_kubectl_context; then
  exit 1
fi

# --- Logging helpers ---
log() { echo "[wireguard] $*"; }
info() { echo "[wireguard:info] $*"; }
warn() { echo "[wireguard:warn] $*" >&2; }
err() { echo "[wireguard:error] $*" >&2; }

# --- Config defaults ---
NAMESPACE_WG="${NAMESPACE_WG:-wireguard}"
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"
WG_HOST="${WG_HOST:-wg.${HOSTNAME}}"
: "${INGRESS_CLASS:=traefik}"
: "${CLUSTER_ISSUER:=letsencrypt-prod}"

# ============================================================================
# Host prerequisite checks
# ============================================================================

ssh_host() {
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "root@${EXTERNAL_IP}" "$@"
}

do_check_host() {
  log "Checking host prerequisites on ${EXTERNAL_IP}..."

  local ok=true

  # IP forwarding
  local ipv4_fwd
  ipv4_fwd=$(ssh_host 'sysctl -n net.ipv4.ip_forward' 2>/dev/null) || { warn "Cannot SSH to host"; return 1; }
  if [[ "$ipv4_fwd" == "1" ]]; then
    info "✓ IPv4 forwarding enabled"
  else
    warn "✗ IPv4 forwarding disabled (net.ipv4.ip_forward=$ipv4_fwd)"
    ok=false
  fi

  local ipv6_fwd
  ipv6_fwd=$(ssh_host 'sysctl -n net.ipv6.conf.all.forwarding' 2>/dev/null) || true
  if [[ "$ipv6_fwd" == "1" ]]; then
    info "✓ IPv6 forwarding enabled"
  else
    warn "✗ IPv6 forwarding disabled"
    ok=false
  fi

  # WireGuard kernel module
  if ssh_host 'lsmod | grep -q wireguard' 2>/dev/null; then
    info "✓ WireGuard kernel module loaded"
  else
    warn "✗ WireGuard kernel module not loaded"
    ok=false
  fi

  # Firewall check (UDP 51820)
  if ssh_host 'ss -ulnp | grep -q 51820' 2>/dev/null; then
    info "✓ Port 51820/UDP is listening"
  else
    info "○ Port 51820/UDP not yet listening (expected before wg-portal starts)"
  fi

  if $ok; then
    log "All host prerequisites met."
  else
    warn "Some prerequisites missing. Run with --setup-host to fix."
    return 1
  fi
}

do_setup_host() {
  log "Setting up host prerequisites on ${EXTERNAL_IP}..."

  ssh_host 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

# IP forwarding (persistent)
if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then
  echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-wireguard.conf
  echo "Enabled IPv4 forwarding"
fi
if [[ "$(sysctl -n net.ipv6.conf.all.forwarding)" != "1" ]]; then
  echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-wireguard.conf
  echo "Enabled IPv6 forwarding"
fi
sysctl --system >/dev/null 2>&1

# WireGuard kernel module
if ! lsmod | grep -q wireguard; then
  modprobe wireguard
  echo "Loaded wireguard module"
fi
if ! grep -q wireguard /etc/modules-load.d/wireguard.conf 2>/dev/null; then
  echo "wireguard" >> /etc/modules-load.d/wireguard.conf
  echo "Persisted wireguard module"
fi

echo "Host prerequisites applied."
REMOTE_SCRIPT

  log "Host setup complete."
}

# ============================================================================
# Secrets
# ============================================================================

do_apply_secrets() {
  log "Applying WireGuard secrets..."

  # Ensure namespace exists
  kubectl get ns "$NAMESPACE_WG" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_WG"

  local secrets_dir="${ENVS_ROOT}/${ENV_NAME}/secrets.sops"
  local plain_dir="${ENVS_ROOT}/${ENV_NAME}/secrets.plain"

  if [[ -f "${secrets_dir}/wireguard.yaml" ]]; then
    info "Decrypting and applying wireguard.yaml from SOPS..."
    sops -d "${secrets_dir}/wireguard.yaml" | kubectl apply -f -
  elif [[ -f "${plain_dir}/wireguard.yaml" ]]; then
    warn "Using plaintext secret (encrypt with: tools/sops/encrypt.sh ${ENV_NAME} wireguard.yaml)"
    kubectl apply -f "${plain_dir}/wireguard.yaml"
  else
    err "No wireguard secret found in secrets.sops/ or secrets.plain/"
    err "Create ${plain_dir}/wireguard.yaml with wg-portal-secrets, then encrypt it."
    return 1
  fi

  log "Secrets applied."
}

# ============================================================================
# Status
# ============================================================================

do_status() {
  log "WireGuard status for ${ENV_NAME}..."
  echo

  info "--- Namespace ---"
  kubectl get ns "$NAMESPACE_WG" 2>/dev/null || { warn "Namespace $NAMESPACE_WG not found"; return 1; }
  echo

  info "--- Pods ---"
  kubectl -n "$NAMESPACE_WG" get pods -o wide
  echo

  info "--- Services ---"
  kubectl -n "$NAMESPACE_WG" get svc
  echo

  info "--- Pomerium Ingress ---"
  kubectl -n "$NAMESPACE_SSO" get ingress wg-portal-pomerium 2>/dev/null || info "(no Pomerium ingress found)"
  echo

  info "--- WireGuard interfaces (via host) ---"
  ssh_host 'wg show' 2>/dev/null || info "(cannot reach host via SSH or no wg interfaces)"
}

# ============================================================================
# Full provisioning
# ============================================================================

do_provision() {
  log "Provisioning WireGuard for ${ENV_NAME} (${HOSTNAME})..."
  log "  WireGuard portal: https://${WG_HOST}"
  log "  External IP: ${EXTERNAL_IP}"
  echo

  # Phase 1: Namespace
  info "Phase 1: Namespace"
  kubectl get ns "$NAMESPACE_WG" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_WG"
  info "✓ Namespace $NAMESPACE_WG ready"

  # Phase 2: Secrets
  info "Phase 2: Secrets"
  do_apply_secrets

  # Phase 3: Pomerium integration
  info "Phase 3: Pomerium integration"

  # Add Pomerium route
  provision::pomerium_routes_add \
    "https://${WG_HOST}" \
    "http://wireguard-wg-portal.${NAMESPACE_WG}.svc.cluster.local:8888" \
    "$NAMESPACE_SSO"

  # Create Pomerium-routing Ingress in sso namespace
  cat <<YAML | kubectl apply -f -
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wg-portal-pomerium
  namespace: ${NAMESPACE_SSO}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    cert-manager.io/common-name: ${WG_HOST}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${WG_HOST}
    secretName: wg-portal-pomerium-tls
  rules:
  - host: ${WG_HOST}
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
  info "✓ Pomerium ingress and route configured"

  # Phase 4: ArgoCD handles the deployment
  info "Phase 4: Deployment"
  if kubectl get application wireguard -n argocd >/dev/null 2>&1; then
    info "✓ ArgoCD Application 'wireguard' exists"
    info "  ArgoCD will sync the Helm chart automatically."
    info "  Check sync status: kubectl -n argocd get application wireguard"
  else
    warn "ArgoCD Application 'wireguard' not found."
    warn "Ensure wireguard-app.yaml is committed and pushed to infra-envs."
    warn "Or apply manually: kubectl apply -f ${ENVS_ROOT}/${ENV_NAME}/apps/wireguard-app.yaml"
  fi

  echo
  log "Provisioning steps complete."
  echo
  info "Next steps:"
  info "  1. Ensure host prerequisites: $0 ${ENV_NAME} --setup-host"
  info "  2. Ensure firewall allows UDP 51820-51821 inbound"
  info "  3. Wait for ArgoCD sync, then access https://${WG_HOST}"
  info "  4. Create WireGuard interfaces in the web UI"
  info "  5. Add peers and scan QR codes on iOS"
  info "  6. Check status: $0 ${ENV_NAME} --status"
}

# ============================================================================
# Main
# ============================================================================

if $CHECK_HOST; then
  do_check_host
elif $SETUP_HOST; then
  do_setup_host
elif $APPLY_SECRETS; then
  do_apply_secrets
elif $STATUS; then
  do_status
else
  do_provision
fi
