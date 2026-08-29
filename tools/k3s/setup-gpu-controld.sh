#!/usr/bin/env bash
set -euo pipefail

# Install the GPU worker control daemon on the box and sync its bearer token into the
# cluster Secret the gpu-status app reads. Lets the in-cluster status page join/leave/
# shutdown the on-demand GPU worker over the tailnet without SSH (the box runs Tailscale
# SSH in interactive check-mode, which a headless caller can't satisfy).
#
# Usage: setup-gpu-controld.sh <env> <worker-name> [--ssh-user USER] [--remove]
#   e.g.: setup-gpu-controld.sh cit gpu-worker --ssh-user tim
#
# Run from a workstation (needs kubectl for <env> + interactive SSH to the box). The box
# must be powered on. Idempotent; reuses the existing token if the cluster Secret exists.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/tools/provision-common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
info(){ echo -e "${BLUE}[INFO]${NC} $*" >&2; }
ok(){ echo -e "${GREEN}[OK]${NC} $*" >&2; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
err(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

SSH_USER=""; SSH_KEY=""; REMOVE=false
ENV_ARG=""; WORKER_ARG=""
NAMESPACE="gpu-status"
SECRET_NAME="gpu-control"
PORT=9696

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --ssh-key)  SSH_KEY="$2"; shift 2 ;;
    --remove)   REMOVE=true; shift ;;
    -h|--help)  echo "Usage: $(basename "$0") <env> <worker-name> [--ssh-user USER] [--remove]"; exit 0 ;;
    -*) err "Unknown flag: $1"; exit 1 ;;
    *) if [[ -z "$ENV_ARG" ]]; then ENV_ARG="$1"; elif [[ -z "$WORKER_ARG" ]]; then WORKER_ARG="$1"; else err "Unexpected arg: $1"; exit 1; fi; shift ;;
  esac
done
[[ -z "$ENV_ARG" || -z "$WORKER_ARG" ]] && { err "Both <env> and <worker-name> are required."; exit 1; }

ENV_ROOT="$(provision::envs_root)"
ENV_FILE="${ENV_ROOT}/${ENV_ARG}/${WORKER_ARG}/env.properties"
[[ -f "$ENV_FILE" ]] || { err "Environment file not found: ${ENV_FILE}"; exit 1; }
source "$ENV_FILE"
export KUBECONFIG="${ENV_ROOT}/${ENV_ARG}/kubeconfig.yaml"
VLAN_IP_ADDR="${VLAN_IP%%/*}"

# --- SSH target (prefer LAN EXTERNAL_IP, fall back to Tailscale IP) ---
[[ -z "$SSH_KEY" ]] && SSH_KEY=$(provision::default_ssh_key_base) || true
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${SSH_KEY:+-i "$SSH_KEY"})
[[ -z "$SSH_USER" ]] && SSH_USER="tim"
SSH_HOST="$EXTERNAL_IP"
if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" true 2>/dev/null; then
  warn "Box not reachable at ${SSH_HOST}; using Tailscale IP ${VLAN_IP_ADDR}"
  SSH_HOST="$VLAN_IP_ADDR"
fi
SSH_TARGET="${SSH_USER}@${SSH_HOST}"
info "Box: ${SSH_TARGET}   namespace: ${NAMESPACE}"

if $REMOVE; then
  info "Removing control daemon from ${WORKER_ARG}..."
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo bash -c '
    systemctl disable --now gpu-worker-controld 2>/dev/null || true
    rm -f /etc/systemd/system/gpu-worker-controld.service /opt/gpu-controld/controld.py /etc/gpu-controld/token
    systemctl daemon-reload'" || warn "box-side removal failed (box may be off)"
  kubectl -n "$NAMESPACE" delete secret "$SECRET_NAME" --ignore-not-found
  ok "Control daemon removed"
  exit 0
fi

# --- Token: reuse the cluster Secret's if present, else mint one ---
TOKEN="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(openssl rand -hex 32)"
  info "Minted a new control token"
else
  info "Reusing existing control token from Secret ${NAMESPACE}/${SECRET_NAME}"
fi

# --- Install daemon + unit + token on the box ---
info "Installing control daemon on ${WORKER_ARG} (port ${PORT}, bound to tailscale0)..."
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo install -d -m 755 /opt/gpu-controld && sudo install -d -m 700 /etc/gpu-controld"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo tee /opt/gpu-controld/controld.py >/dev/null" < "${SCRIPT_DIR}/gpu-controld/controld.py"
printf '%s' "$TOKEN" | ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo tee /etc/gpu-controld/token >/dev/null && sudo chmod 600 /etc/gpu-controld/token"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo tee /etc/systemd/system/gpu-worker-controld.service >/dev/null" <<UNIT
[Unit]
Description=GPU worker control daemon (join/leave/shutdown over tailnet)
After=network-online.target tailscaled.service
Wants=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/gpu-controld/controld.py
Environment=GPU_CONTROLD_PORT=${PORT}
Environment=GPU_MASTER_IP=${MASTER_VLAN_IP%%/*}
Restart=always
RestartSec=3
User=root
[Install]
WantedBy=multi-user.target
UNIT
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo systemctl daemon-reload && sudo systemctl enable --now gpu-worker-controld && sleep 1 && systemctl is-active gpu-worker-controld"
ok "Control daemon installed and running"

# --- Sync the token into the cluster Secret the app reads ---
kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=token="$TOKEN" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "Token synced to Secret ${NAMESPACE}/${SECRET_NAME}"

# --- Verify the daemon answers over the tailnet ---
info "Health check via tailnet (${VLAN_IP_ADDR}:${PORT})..."
if curl -fsS -m 8 "http://${VLAN_IP_ADDR}:${PORT}/healthz" 2>/dev/null; then
  echo; ok "Control daemon reachable. gpu-status Join/Leave buttons can drive it."
else
  warn "Could not reach the daemon over the tailnet from here (may be normal if this host can't route to the box's tailnet IP). The cluster app reaches it via the master's tailscale0."
fi
