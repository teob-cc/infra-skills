#!/usr/bin/env bash
set -euo pipefail

# Install a bare-metal GitHub Actions self-hosted runner on a GPU host.
# Uses GitHub App credentials to obtain a runner registration token.
# The runner registers with repo-level or org-level labels for GPU job scheduling.
#
# Usage: setup-gh-runner.sh <env> <worker-name> [flags]
#   e.g.: setup-gh-runner.sh prod gpu-worker --repo <org>/<repo>
#
# Prerequisites: Docker installed on the host (for GPU image builds).

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
REPO=""
RUNNER_LABELS="self-hosted,linux,gpu"
RUNNER_USER="github-runner"
REMOVE=false
DEBUG=false

usage() {
  cat <<EOF
Usage: $(basename "$0") <env> <worker-name> [flags]

Install a bare-metal GitHub Actions self-hosted runner on a GPU host.

Arguments:
  env           Environment name (e.g. cit)
  worker-name   Worker subdirectory under envs/<env>/ (e.g. gpu-worker)

Flags:
  --repo OWNER/REPO     GitHub repo to register runner with (required)
  --labels LABELS       Comma-separated runner labels (default: self-hosted,linux,gpu)
  --ssh-user USER       SSH username (default: auto-detect)
  --ssh-key PATH        SSH private key (default: ~/.ssh/id_ed25519)
  --runner-user USER    Linux user for runner (default: github-runner)
  --remove              Unregister and remove the runner
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
    --repo)         REPO="$2"; shift 2 ;;
    --labels)       RUNNER_LABELS="$2"; shift 2 ;;
    --ssh-user)     SSH_USER="$2"; shift 2 ;;
    --ssh-key)      SSH_KEY="$2"; shift 2 ;;
    --runner-user)  RUNNER_USER="$2"; shift 2 ;;
    --remove)       REMOVE=true; shift ;;
    --debug)        DEBUG=true; shift ;;
    -h|--help)      usage ;;
    -*)             err "Unknown flag: $1"; usage ;;
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

if [[ -z "$REPO" ]]; then
  err "--repo OWNER/REPO is required."
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

NODE_NAME="${WORKER_ARG//_/-}"
info "GitHub Actions runner setup for ${ENV_NAME}/${WORKER_ARG}"
info "  Repo: ${REPO}"
info "  Labels: ${RUNNER_LABELS}"

# --- SSH setup ---
if [[ -z "$SSH_KEY" ]]; then
  SSH_KEY=$(provision::default_ssh_key_base) || { err "No SSH key found"; exit 1; }
fi
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$SSH_KEY")

SSH_HOST="$EXTERNAL_IP"
VLAN_IP_ADDR="${VLAN_IP%%/*}"
if [[ -n "$SSH_USER" ]]; then
  # The LAN address is only reachable from the same network; when operating
  # remotely, fall back to the Tailscale IP.
  if ! ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${SSH_USER}@${SSH_HOST}" "true" 2>/dev/null; then
    warn "Worker not reachable at ${SSH_HOST}, falling back to Tailscale IP ${VLAN_IP_ADDR}"
    SSH_HOST="$VLAN_IP_ADDR"
  fi
fi
if [[ -z "$SSH_USER" ]]; then
  for u in admin tim root; do
    if ssh "${SSH_OPTS[@]}" "$u@${SSH_HOST}" "true" 2>/dev/null; then
      SSH_USER="$u"
      break
    fi
  done
  if [[ -z "$SSH_USER" ]]; then
    err "Could not auto-detect SSH user. Use --ssh-user."
    exit 1
  fi
fi
SSH_TARGET="${SSH_USER}@${SSH_HOST}"
info "  SSH: ${SSH_TARGET}"

# --- Obtain GitHub Installation Token ---
info "Obtaining GitHub App installation token..."
INSTALLATION_TOKEN=$(provision::github_get_installation_token) || {
  err "Failed to get GitHub installation token"
  exit 1
}
ok "Got installation token"

# --- Get runner registration token ---
info "Creating runner registration token for ${REPO}..."
REG_TOKEN_RESPONSE=$(curl -sS -X POST \
  -H "Authorization: Bearer ${INSTALLATION_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/actions/runners/registration-token")
REG_TOKEN=$(printf '%s' "$REG_TOKEN_RESPONSE" | jq -r '.token // empty')
if [[ -z "$REG_TOKEN" || "$REG_TOKEN" == "null" ]]; then
  err "Failed to create runner registration token"
  err "Response: ${REG_TOKEN_RESPONSE}"
  exit 1
fi
ok "Got runner registration token (valid for 1 hour)"

# --- Remove mode ---
if $REMOVE; then
  info "Removing runner from ${REPO}..."
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo bash -s" <<REMOVE_SCRIPT
set -euo pipefail
RUNNER_HOME="/home/${RUNNER_USER}/actions-runner"
if [[ -d "\$RUNNER_HOME" ]]; then
  cd "\$RUNNER_HOME"
  sudo ./svc.sh stop 2>/dev/null || true
  sudo ./svc.sh uninstall 2>/dev/null || true
  sudo -u ${RUNNER_USER} ./config.sh remove --token '${REG_TOKEN}' 2>/dev/null || true
  echo "[OK] Runner removed"
else
  echo "[WARN] Runner directory not found at \$RUNNER_HOME"
fi
REMOVE_SCRIPT
  ok "Runner removed"
  exit 0
fi

# --- Check if runner already installed ---
RUNNER_EXISTS=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  "test -f /home/${RUNNER_USER}/actions-runner/.runner && echo yes || echo no")
if [[ "$RUNNER_EXISTS" == "yes" ]]; then
  RUNNER_STATUS=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
    "systemctl is-active actions.runner.*.service 2>/dev/null || echo inactive")
  if [[ "$RUNNER_STATUS" == "active" ]]; then
    ok "Runner already installed and running"
    info "To reconfigure, run with --remove first."
    exit 0
  else
    warn "Runner installed but not running. Reconfiguring..."
  fi
fi

# --- Determine latest runner version ---
info "Fetching latest runner release..."
RUNNER_VERSION=$(curl -sS -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/actions/runner/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
if [[ -z "$RUNNER_VERSION" || "$RUNNER_VERSION" == "null" ]]; then
  RUNNER_VERSION="2.322.0"
  warn "Could not detect latest version, using ${RUNNER_VERSION}"
fi
info "  Runner version: ${RUNNER_VERSION}"

# --- Install runner on host ---
info "Installing runner on ${NODE_NAME}..."
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo bash -s" <<INSTALL_SCRIPT
set -euo pipefail

# Create runner user if it doesn't exist
if ! id -u ${RUNNER_USER} >/dev/null 2>&1; then
  useradd -m -s /bin/bash ${RUNNER_USER}
  echo "[OK] Created user ${RUNNER_USER}"
fi

# Add to docker group for GPU image builds
usermod -aG docker ${RUNNER_USER} 2>/dev/null || true

RUNNER_HOME="/home/${RUNNER_USER}/actions-runner"
mkdir -p "\$RUNNER_HOME"

# Download runner
cd "\$RUNNER_HOME"
TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
if [[ ! -f "\$TARBALL" ]]; then
  curl -sL -o "\$TARBALL" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/\$TARBALL"
  echo "[OK] Downloaded runner v${RUNNER_VERSION}"
fi

# Extract (idempotent)
tar xzf "\$TARBALL" --overwrite 2>/dev/null || tar xzf "\$TARBALL"
chown -R ${RUNNER_USER}:${RUNNER_USER} "\$RUNNER_HOME"

# Clear stale local config so config.sh can re-register. This is the normal
# revival path for a temporary node: GitHub purges runner registrations after
# ~14 days offline, but the local .runner/.credentials files remain and make
# config.sh refuse to run. Try a clean remove first, then force-delete.
if [[ -f .runner ]]; then
  ./svc.sh stop 2>/dev/null || true
  ./svc.sh uninstall 2>/dev/null || true
  sudo -u ${RUNNER_USER} ./config.sh remove --token '${REG_TOKEN}' 2>/dev/null || true
  rm -f .runner .credentials .credentials_rsaparams
  echo "[OK] Cleared stale runner configuration"
fi

# Configure runner
sudo -u ${RUNNER_USER} ./config.sh \
  --url "https://github.com/${REPO}" \
  --token '${REG_TOKEN}' \
  --name '${NODE_NAME}' \
  --labels '${RUNNER_LABELS}' \
  --work _work \
  --unattended \
  --replace

echo "[OK] Runner configured"

# Install and start as systemd service
./svc.sh install ${RUNNER_USER}
./svc.sh start

echo "[OK] Runner service started"
INSTALL_SCRIPT

ok "Runner installed on ${NODE_NAME}"

# --- Verify ---
info "Verifying runner registration..."
sleep 3
RUNNERS_RESPONSE=$(curl -sS \
  -H "Authorization: Bearer ${INSTALLATION_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/actions/runners")
RUNNER_ONLINE=$(printf '%s' "$RUNNERS_RESPONSE" | jq -r \
  ".runners[] | select(.name == \"${NODE_NAME}\") | .status" 2>/dev/null || echo "not_found")

if [[ "$RUNNER_ONLINE" == "online" ]]; then
  ok "Runner '${NODE_NAME}' is online in ${REPO}"
  RUNNER_LABELS_ACTUAL=$(printf '%s' "$RUNNERS_RESPONSE" | jq -r \
    ".runners[] | select(.name == \"${NODE_NAME}\") | .labels[].name" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  info "  Labels: ${RUNNER_LABELS_ACTUAL}"
else
  warn "Runner status: ${RUNNER_ONLINE}. It may take a moment to come online."
  warn "Check: https://github.com/${REPO}/settings/actions/runners"
fi

echo ""
info "=== GPU runner setup complete ==="
info "  Node:   ${NODE_NAME}"
info "  Repo:   ${REPO}"
info "  Labels: ${RUNNER_LABELS}"
info ""
info "GPU CI jobs can now target: runs-on: [self-hosted, gpu]"
