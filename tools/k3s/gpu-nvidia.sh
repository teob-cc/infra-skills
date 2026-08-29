#!/usr/bin/env bash
set -euo pipefail

# Configure NVIDIA GPU runtime for K3s on a worker node.
# Installs nvidia-container-toolkit for containerd, patches K3s containerd config,
# and deploys the NVIDIA device plugin DaemonSet.
#
# Prerequisites: K3s agent running (use join-worker.sh first), NVIDIA driver installed.
#
# Usage: gpu-nvidia.sh <env> <worker-name> [flags]
#   e.g.: gpu-nvidia.sh cit gpu-worker --ssh-user tim

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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
DEVICE_PLUGIN_VERSION="v0.17.0"
SKIP_CTK=false
SKIP_CONTAINERD=false
SKIP_DEVICE_PLUGIN=false
DEBUG=false

usage() {
  cat <<EOF
Usage: $(basename "$0") <env> <worker-name> [flags]

Configure NVIDIA GPU runtime for K3s on a worker node.

Arguments:
  env           Environment name (e.g. cit)
  worker-name   Worker subdirectory under envs/<env>/ (e.g. gpu-worker)

Flags:
  --ssh-user USER          SSH username (default: auto-detect)
  --ssh-key PATH           SSH private key (default: ~/.ssh/id_ed25519)
  --device-plugin VER      NVIDIA device plugin version (default: v0.17.0)
  --skip-ctk               Skip nvidia-container-toolkit install
  --skip-containerd        Skip K3s containerd config patch
  --skip-device-plugin     Skip device plugin DaemonSet deployment
  --debug                  Enable debug output
  -h, --help               Show this help
EOF
  exit 0
}

# --- Parse arguments ---
ENV_ARG=""
WORKER_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-user)         SSH_USER="$2"; shift 2 ;;
    --ssh-key)          SSH_KEY="$2"; shift 2 ;;
    --device-plugin)    DEVICE_PLUGIN_VERSION="$2"; shift 2 ;;
    --skip-ctk)         SKIP_CTK=true; shift ;;
    --skip-containerd)  SKIP_CONTAINERD=true; shift ;;
    --skip-device-plugin) SKIP_DEVICE_PLUGIN=true; shift ;;
    --debug)            DEBUG=true; shift ;;
    -h|--help)          usage ;;
    -*)                 err "Unknown flag: $1"; usage ;;
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

VLAN_IP_ADDR="${VLAN_IP%%/*}"
NODE_NAME="${WORKER_ARG//_/-}"

info "NVIDIA GPU setup for ${ENV_NAME}/${WORKER_ARG} (node: ${NODE_NAME})"

# --- SSH setup ---
if [[ -z "$SSH_KEY" ]]; then
  SSH_KEY=$(provision::default_ssh_key_base) || { err "No SSH key found"; exit 1; }
fi
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$SSH_KEY")

SSH_HOST="$EXTERNAL_IP"
if [[ -z "$SSH_USER" ]]; then
  for u in admin tim root; do
    if ssh "${SSH_OPTS[@]}" "$u@${SSH_HOST}" "true" 2>/dev/null; then
      SSH_USER="$u"
      break
    fi
  done
  if [[ -z "$SSH_USER" ]]; then
    SSH_HOST="$VLAN_IP_ADDR"
    for u in admin tim root; do
      if ssh "${SSH_OPTS[@]}" "$u@${SSH_HOST}" "true" 2>/dev/null; then
        SSH_USER="$u"
        break
      fi
    done
  fi
  if [[ -z "$SSH_USER" ]]; then
    err "Could not auto-detect SSH user. Use --ssh-user."
    exit 1
  fi
fi
SSH_TARGET="${SSH_USER}@${SSH_HOST}"
info "  SSH: ${SSH_TARGET}"

# --- Load kubeconfig ---
KUBECONFIG_FILE="${ENV_ROOT}/${ENV_ARG}/kubeconfig.yaml"
if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  err "Kubeconfig not found: ${KUBECONFIG_FILE}"
  exit 1
fi
export KUBECONFIG="$KUBECONFIG_FILE"

# --- Verify prerequisites ---
info "Verifying prerequisites..."

# Check NVIDIA driver on host
DRIVER_VER=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1" || true)
if [[ -z "$DRIVER_VER" ]]; then
  err "NVIDIA driver not found on ${NODE_NAME}. Run provision-gpu-host.sh first."
  exit 1
fi
ok "NVIDIA driver ${DRIVER_VER} detected"

# Check K3s agent running
if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "systemctl is-active --quiet k3s-agent 2>/dev/null"; then
  err "k3s-agent not running on ${NODE_NAME}. Run join-worker.sh first."
  exit 1
fi
ok "k3s-agent is running"

# Check node exists in cluster
if ! kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
  err "Node ${NODE_NAME} not found in cluster. Run join-worker.sh first."
  exit 1
fi
ok "Node ${NODE_NAME} found in cluster"

# --- Step 1: nvidia-container-toolkit for containerd ---
if ! $SKIP_CTK; then
  info "Step 1/3: Checking nvidia-container-toolkit..."
  if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "command -v nvidia-ctk >/dev/null 2>&1"; then
    CTK_VER=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "nvidia-ctk --version 2>/dev/null | head -1")
    ok "nvidia-container-toolkit already installed (${CTK_VER})"
  else
    info "Installing nvidia-container-toolkit..."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" sudo bash -s <<'SCRIPT'
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
    ok "nvidia-container-toolkit installed"
  fi

  # Configure for containerd (K3s uses containerd)
  info "Configuring nvidia-ctk for containerd..."
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo nvidia-ctk runtime configure --runtime=containerd"
  ok "nvidia-ctk configured for containerd"

  # Generate CDI (Container Device Interface) specs for GPU discovery
  info "Generating CDI specs..."
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>&1 | tail -3"
  ok "CDI specs generated"
else
  info "Step 1/3: Skipping nvidia-container-toolkit (--skip-ctk)"
fi

# --- Step 2: Patch K3s containerd config ---
if ! $SKIP_CONTAINERD; then
  info "Step 2/3: Patching K3s containerd config for NVIDIA runtime..."

  # The config.toml.tmpl REPLACES the auto-generated config.toml entirely.
  # We must copy the existing generated config first, then append the NVIDIA runtime
  # and set it as the default runtime (required for the device plugin to detect GPUs).
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" sudo bash -s <<'SCRIPT'
set -euo pipefail

CONTAINERD_DIR="/var/lib/rancher/k3s/agent/etc/containerd"
CONFIG_TOML="${CONTAINERD_DIR}/config.toml"
TEMPLATE="${CONTAINERD_DIR}/config.toml.tmpl"

# Ensure the generated config exists (K3s creates it on agent start)
if [[ ! -f "$CONFIG_TOML" ]]; then
  echo "[ERROR] ${CONFIG_TOML} not found. Is k3s-agent running?" >&2
  exit 1
fi

# Check if NVIDIA runtime is already configured as default
if [[ -f "$TEMPLATE" ]] && grep -q 'default_runtime_name = "nvidia"' "$TEMPLATE" 2>/dev/null; then
  echo "[OK] NVIDIA runtime already configured as default in config.toml.tmpl"
  exit 0
fi

# Copy the auto-generated config as the template base
cp "$CONFIG_TOML" "$TEMPLATE"

# Set nvidia as the default containerd runtime. Since this GPU node is tainted,
# only GPU workloads are scheduled here, so making nvidia the default is safe.
# This is required for the NVIDIA device plugin to detect GPUs.
if ! grep -q "default_runtime_name" "$TEMPLATE"; then
  # Insert default_runtime_name before the first runtimes block
  sed -i "/\[plugins.*containerd.*runtimes\.runc\]/i\\
[plugins.'io.containerd.cri.v1.runtime'.containerd]\\
  default_runtime_name = \"nvidia\"\\
" "$TEMPLATE"
fi

# Append NVIDIA runtime block (v1 format for newer containerd)
cat >> "$TEMPLATE" <<'EOF'

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.'nvidia']
  runtime_type = "io.containerd.runc.v2"
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.'nvidia'.options]
  BinaryName = "/usr/bin/nvidia-container-runtime"
  SystemdCgroup = true
EOF

echo "[OK] NVIDIA runtime set as default in config.toml.tmpl"
SCRIPT
  ok "K3s containerd config patched"

  # Restart k3s-agent to pick up the new containerd config
  info "Restarting k3s-agent..."
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo systemctl restart k3s-agent"

  # Wait for agent to stabilize
  sleep 5
  if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "systemctl is-active --quiet k3s-agent 2>/dev/null"; then
    ok "k3s-agent restarted successfully"
  else
    err "k3s-agent failed to restart after containerd config change"
    err "Check: ssh ${SSH_TARGET} sudo journalctl -u k3s-agent -n 50"
    exit 1
  fi
else
  info "Step 2/3: Skipping containerd config (--skip-containerd)"
fi

# --- Step 3: NVIDIA device plugin DaemonSet ---
if ! $SKIP_DEVICE_PLUGIN; then
  info "Step 3/3: Deploying NVIDIA device plugin (${DEVICE_PLUGIN_VERSION})..."

  # Check if already deployed
  if kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset >/dev/null 2>&1; then
    CURRENT_IMG=$(kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    ok "NVIDIA device plugin already deployed (${CURRENT_IMG})"
  else
    kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"
    ok "NVIDIA device plugin DaemonSet deployed"
  fi

  # Pin the DaemonSet to GPU-labeled nodes and tolerate the GPU taint. The stock
  # manifest has neither, so without this patch the plugin pod lands on every node
  # (crashlooping on non-GPU ones) and never schedules onto a tainted GPU worker.
  info "Pinning device plugin to gpu=rtx4080 nodes (nodeSelector + taint toleration)..."
  kubectl patch daemonset -n kube-system nvidia-device-plugin-daemonset --type=strategic -p '{
    "spec": {"template": {"spec": {
      "nodeSelector": {"gpu": "rtx4080"},
      "tolerations": [
        {"key": "nvidia.com/gpu", "operator": "Exists", "effect": "NoSchedule"},
        {"key": "gpu", "value": "rtx4080", "effect": "NoSchedule"}
      ]
    }}}}'
  ok "Device plugin scheduling patched"

  # Wait for the device plugin pod to be running on our node
  info "Waiting for device plugin pod on ${NODE_NAME}..."
  for i in $(seq 1 30); do
    POD_STATUS=$(kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds \
      --field-selector "spec.nodeName=${NODE_NAME}" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    if [[ "$POD_STATUS" == "Running" ]]; then
      break
    fi
    sleep 2
  done

  if [[ "$POD_STATUS" == "Running" ]]; then
    ok "NVIDIA device plugin pod running on ${NODE_NAME}"
  else
    warn "Device plugin pod not Running yet (status: ${POD_STATUS:-unknown}). It may need a moment."
    warn "The DaemonSet tolerations may need to match the node's taints."
    warn "Check: kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds -o wide"
  fi

  # Verify GPU is reported as allocatable resource
  info "Checking GPU allocatable resources on ${NODE_NAME}..."
  sleep 3
  GPU_COUNT=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
  if [[ "$GPU_COUNT" != "0" && -n "$GPU_COUNT" ]]; then
    ok "GPU reported: nvidia.com/gpu = ${GPU_COUNT}"
  else
    warn "nvidia.com/gpu not yet reported. The device plugin pod may still be initializing."
    warn "Check: kubectl describe node ${NODE_NAME} | grep nvidia"
  fi
else
  info "Step 3/3: Skipping device plugin (--skip-device-plugin)"
fi

# --- Verification ---
echo ""
info "=== NVIDIA GPU setup complete ==="
info ""
info "Node status:"
kubectl get node "$NODE_NAME" -o wide
echo ""
info "GPU resources:"
kubectl describe node "$NODE_NAME" 2>/dev/null | grep -A5 "Allocatable:" | grep -E "nvidia|Allocatable" || \
  warn "GPU resources not visible yet"
echo ""
info "Quick GPU test:"
info "  kubectl run gpu-test --rm -it --restart=Never \\"
info "    --image=nvidia/cuda:12.8.0-base-ubuntu24.04 \\"
info "    --overrides='{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${NODE_NAME}\"},\"tolerations\":[{\"operator\":\"Exists\"}]}}' \\"
info "    -- nvidia-smi"
