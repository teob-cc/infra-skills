#!/usr/bin/env bash
set -euo pipefail

# Provision a GPU host for K3s worker duty.
# Assumes a bare Ubuntu 24.04 host reachable via SSH with root/sudo access.
# Installs: NVIDIA driver + CUDA, Docker CE + nvidia-ctk, UFW, Tailscale.
#
# Usage: provision-gpu-host.sh <env> <worker-name> [flags]
#   e.g.: provision-gpu-host.sh cit gpu-worker --ssh-user tim
#
# Reads env.properties from envs/<env>/<worker-name>/env.properties
# Expects: EXTERNAL_IP (reachable SSH address before Tailscale is up)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/tools/provision-common.sh"

# --- Colors & logging ---
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Defaults ---
SSH_USER=""
SSH_KEY=""
SKIP_NVIDIA=false
SKIP_DOCKER=false
SKIP_UFW=false
SKIP_TAILSCALE=false
DEBUG=false
NVIDIA_DRIVER="580"

# --- Usage ---
usage() {
  cat <<EOF
Usage: $(basename "$0") <env> <worker-name> [flags]

Provision a GPU host for K3s worker duty.

Arguments:
  env           Environment name (e.g. cit)
  worker-name   Worker subdirectory under envs/<env>/ (e.g. gpu-worker)

Flags:
  --ssh-user USER       SSH username (default: auto-detect or 'admin')
  --ssh-key PATH        SSH private key (default: ~/.ssh/id_ed25519)
  --nvidia-driver VER   NVIDIA driver branch to install (default: 580)
  --skip-nvidia         Skip NVIDIA driver + CUDA installation
  --skip-docker         Skip Docker CE installation
  --skip-ufw            Skip UFW firewall setup
  --skip-tailscale      Skip Tailscale installation
  --debug               Enable debug output
  -h, --help            Show this help
EOF
  exit 0
}

# --- Parse arguments ---
ENV_ARG=""
WORKER_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-user)    SSH_USER="$2"; shift 2 ;;
    --ssh-key)     SSH_KEY="$2"; shift 2 ;;
    --nvidia-driver) NVIDIA_DRIVER="$2"; shift 2 ;;
    --skip-nvidia) SKIP_NVIDIA=true; shift ;;
    --skip-docker) SKIP_DOCKER=true; shift ;;
    --skip-ufw)    SKIP_UFW=true; shift ;;
    --skip-tailscale) SKIP_TAILSCALE=true; shift ;;
    --debug)       DEBUG=true; shift ;;
    -h|--help)     usage ;;
    -*)            err "Unknown flag: $1"; usage ;;
    *)
      if [[ -z "$ENV_ARG" ]]; then
        ENV_ARG="$1"
      elif [[ -z "$WORKER_ARG" ]]; then
        WORKER_ARG="$1"
      else
        err "Unexpected argument: $1"; usage
      fi
      shift ;;
  esac
done

if [[ -z "$ENV_ARG" || -z "$WORKER_ARG" ]]; then
  err "Both <env> and <worker-name> are required."
  usage
fi

# --- Load environment ---
ENV_ROOT="$(provision::envs_root)"
ENV_FILE="${ENV_ROOT}/${ENV_ARG}/${WORKER_ARG}/env.properties"
if [[ ! -f "$ENV_FILE" ]]; then
  err "Environment file not found: ${ENV_FILE}"
  exit 1
fi
source "$ENV_FILE"
ENV_NAME="$ENV_ARG"
export ENV_NAME

info "Provisioning GPU host for ${ENV_NAME}/${WORKER_ARG}"
info "  Host: ${HOSTNAME} (${EXTERNAL_IP})"

# --- SSH setup ---
if [[ -z "$SSH_KEY" ]]; then
  SSH_KEY=$(provision::default_ssh_key_base) || { err "No SSH key found"; exit 1; }
fi
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$SSH_KEY")

if [[ -z "$SSH_USER" ]]; then
  # Try common users
  for u in admin tim root; do
    if ssh "${SSH_OPTS[@]}" "$u@${EXTERNAL_IP}" "true" 2>/dev/null; then
      SSH_USER="$u"
      break
    fi
  done
  if [[ -z "$SSH_USER" ]]; then
    err "Could not auto-detect SSH user. Use --ssh-user."
    exit 1
  fi
fi

SSH_TARGET="${SSH_USER}@${EXTERNAL_IP}"
info "  SSH: ${SSH_TARGET}"

# Helper: run command on remote host with sudo
remote() {
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo bash -c $(printf '%q' "$1")"
}

remote_script() {
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo bash -s" <<< "$1"
}

# --- Verify connectivity ---
info "Verifying SSH connectivity..."
if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "true" 2>/dev/null; then
  err "Cannot SSH to ${SSH_TARGET}"
  exit 1
fi
ok "SSH connectivity verified"

# --- Step 1: NVIDIA driver + CUDA ---
if ! $SKIP_NVIDIA; then
  info "Step 1/4: Checking NVIDIA driver + CUDA..."
  if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1"; then
    DRIVER_VER=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1")
    ok "NVIDIA driver already installed (version ${DRIVER_VER})"
  else
    info "Installing NVIDIA driver ${NVIDIA_DRIVER} + CUDA toolkit..."
    remote_script "$(cat <<'SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential dkms curl wget gnupg lsb-release \
  ca-certificates software-properties-common ubuntu-drivers-common

# NVIDIA driver
ubuntu-drivers install nvidia:NVIDIA_DRIVER_PLACEHOLDER

# CUDA toolkit repo + install
ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" == "amd64" ]]; then
  CUDA_ARCH="x86_64"
else
  CUDA_ARCH="$ARCH"
fi
wget -q "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/${CUDA_ARCH}/cuda-keyring_1.1-1_all.deb" -O /tmp/cuda-keyring.deb
dpkg -i /tmp/cuda-keyring.deb
apt-get update -qq
apt-get install -y -qq cuda-toolkit
rm -f /tmp/cuda-keyring.deb
echo "NVIDIA driver + CUDA installed. A reboot may be required."
SCRIPT
)" | sed "s/NVIDIA_DRIVER_PLACEHOLDER/${NVIDIA_DRIVER}/g"
    warn "NVIDIA driver installed. If this is a fresh install, reboot the host and re-run with --skip-nvidia."
  fi
else
  info "Step 1/4: Skipping NVIDIA driver + CUDA (--skip-nvidia)"
fi

# --- Step 2: Docker CE + nvidia-ctk ---
if ! $SKIP_DOCKER; then
  info "Step 2/4: Checking Docker CE..."
  if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "command -v docker >/dev/null 2>&1"; then
    DOCKER_VER=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "docker --version 2>/dev/null")
    ok "Docker already installed (${DOCKER_VER})"
  else
    info "Installing Docker CE..."
    remote "curl -fsSL https://get.docker.com | sh"
    ok "Docker CE installed"
  fi

  # nvidia-container-toolkit for Docker
  info "Checking nvidia-container-toolkit..."
  if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "command -v nvidia-ctk >/dev/null 2>&1"; then
    ok "nvidia-container-toolkit already installed"
  else
    info "Installing nvidia-container-toolkit..."
    remote_script "$(cat <<'SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -s -L "https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list" | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update -qq
apt-get install -y -qq nvidia-container-toolkit
SCRIPT
)"
    ok "nvidia-container-toolkit installed"
  fi

  # Configure Docker runtime
  info "Configuring NVIDIA Docker runtime..."
  remote "nvidia-ctk runtime configure --runtime=docker && systemctl restart docker"
  ok "NVIDIA Docker runtime configured"

  # Verify Docker GPU access
  info "Verifying Docker GPU access..."
  if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi >/dev/null 2>&1"; then
    ok "Docker GPU access verified"
  else
    warn "Docker GPU test failed. The NVIDIA driver may need a reboot to take effect."
  fi

  # Ensure SSH user is in docker group
  remote "usermod -aG docker ${SSH_USER} 2>/dev/null || true"
else
  info "Step 2/4: Skipping Docker CE (--skip-docker)"
fi

# --- Step 3: UFW firewall ---
if ! $SKIP_UFW; then
  info "Step 3/4: Configuring UFW firewall..."
  remote_script "$(cat <<'SCRIPT'
set -euo pipefail
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 comment 'Tailscale' 2>/dev/null || true
ufw allow 22/tcp comment 'SSH'
ufw --force enable
SCRIPT
)"
  ok "UFW configured (deny incoming, allow SSH + Tailscale)"
else
  info "Step 3/4: Skipping UFW (--skip-ufw)"
fi

# --- Step 4: Tailscale ---
if ! $SKIP_TAILSCALE; then
  info "Step 4/4: Setting up Tailscale..."

  # Check if already connected
  TS_STATUS=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null" || echo "")
  if [[ "$TS_STATUS" == "Running" ]]; then
    TS_IP=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "tailscale ip -4 2>/dev/null")
    ok "Tailscale already running (IP: ${TS_IP})"
  else
    # Install if needed
    if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "command -v tailscale >/dev/null 2>&1"; then
      info "Installing Tailscale..."
      remote "curl -fsSL https://tailscale.com/install.sh | sh"
      ok "Tailscale installed"
    fi

    # Read Tailscale API token
    TS_TOKEN_FILE="${ENV_ROOT}/shared/secrets.plain/tailscale-api-key.txt"
    if [[ ! -f "$TS_TOKEN_FILE" ]]; then
      err "Tailscale API key not found: ${TS_TOKEN_FILE}"
      err "Cannot create auth key. Install Tailscale manually on the host."
      exit 1
    fi
    TS_API_TOKEN=$(tr -d '\n\r' < "$TS_TOKEN_FILE" | xargs)

    # Clean up stale devices
    TS_HOSTNAME="${HOSTNAME%%.*}"
    info "Cleaning up stale Tailscale devices for ${TS_HOSTNAME}..."
    STALE_IDS=$(curl -sS -u "${TS_API_TOKEN}:" \
      "https://api.tailscale.com/api/v2/tailnet/-/devices" 2>/dev/null \
      | jq -r ".devices[] | select(.hostname == \"${TS_HOSTNAME}\") | .id" 2>/dev/null || true)
    if [[ -n "$STALE_IDS" ]]; then
      while IFS= read -r did; do
        [[ -n "$did" ]] && curl -sS -u "${TS_API_TOKEN}:" -X DELETE \
          "https://api.tailscale.com/api/v2/device/${did}" >/dev/null 2>&1 && \
          info "  Removed stale device ${did}" || true
      done <<< "$STALE_IDS"
    fi

    # Create pre-authorized, non-ephemeral auth key
    SAFE_HOSTNAME=$(printf '%s' "$TS_HOSTNAME" | tr '.' '-' | tr -cd 'A-Za-z0-9-_')
    TS_AUTHKEY=$(curl -sS -u "${TS_API_TOKEN}:" -X POST \
      -H 'Content-Type: application/json' \
      "https://api.tailscale.com/api/v2/tailnet/-/keys" \
      -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":false,\"preauthorized\":true,\"tags\":[]}}},\"expirySeconds\":3600,\"description\":\"Provisioning for ${SAFE_HOSTNAME}\"}" \
      | jq -r '.key')

    if [[ -z "$TS_AUTHKEY" || "$TS_AUTHKEY" == "null" ]]; then
      err "Failed to create Tailscale auth key"
      exit 1
    fi
    ok "Created Tailscale auth key"

    # Join tailnet
    info "Joining Tailscale tailnet as ${TS_HOSTNAME}..."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo tailscale up --authkey '${TS_AUTHKEY}' --ssh --hostname '${TS_HOSTNAME}'"
    TS_IP=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "tailscale ip -4 2>/dev/null")
    ok "Tailscale connected (IP: ${TS_IP})"
  fi

  # Update env.properties with actual Tailscale IP if placeholder
  if [[ -n "${TS_IP:-}" ]]; then
    if grep -q '<cit-gpu-worker-tailscale-ip>' "$ENV_FILE" 2>/dev/null; then
      sed -i.bak "s/<cit-gpu-worker-tailscale-ip>/${TS_IP}/" "$ENV_FILE"
      rm -f "${ENV_FILE}.bak"
      info "Updated VLAN_IP in env.properties to ${TS_IP}"
    fi
    if [[ "${VLAN_IP:-}" != "$TS_IP" ]]; then
      info "Note: Tailscale IP is ${TS_IP}. Ensure VLAN_IP in env.properties matches."
    fi
  fi

  # Verify connectivity to master
  if [[ -n "${MASTER_VLAN_IP:-}" ]]; then
    info "Verifying Tailscale connectivity to master (${MASTER_VLAN_IP})..."
    if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "tailscale ping -c 1 ${MASTER_VLAN_IP} >/dev/null 2>&1"; then
      ok "Tailscale connectivity to master verified"
    else
      warn "Cannot reach master at ${MASTER_VLAN_IP} via Tailscale. Check Tailscale admin console."
    fi
  fi
else
  info "Step 4/4: Skipping Tailscale (--skip-tailscale)"
fi

echo ""
info "=== GPU host provisioning complete ==="
info "  Host:      ${HOSTNAME} (${EXTERNAL_IP})"
info "  Tailscale: ${TS_IP:-unknown}"
info ""
info "Next steps:"
info "  1. Join K3s:  tools/k3s/join-worker.sh ${ENV_ARG} ${WORKER_ARG}"
info "  2. GPU setup: tools/k3s/gpu-nvidia.sh ${ENV_ARG} ${WORKER_ARG}"
