#!/usr/bin/env bash
set -euo pipefail

# Join a worker node to an existing K3s cluster via Tailscale.
# Unlike provision-hetzner-baremetal.sh, this does NOT assume Hetzner VLAN.
# The worker connects to the master via Tailscale IPs.
#
# Usage: join-worker.sh <env> <worker-name> [flags]
#   e.g.: join-worker.sh cit gpu-worker --ssh-user tim
#
# Reads env.properties from envs/<env>/<worker-name>/env.properties
# Expects: VLAN_IP (Tailscale IP), MASTER_VLAN_IP, MASTER_HOSTNAME, EXTERNAL_IP

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
NODE_LABELS=""
NODE_TAINTS=""
REMOVE=false
UNINSTALL=false
DEBUG=false

usage() {
  cat <<EOF
Usage: $(basename "$0") <env> <worker-name> [flags]

Join a worker node to an existing K3s cluster via Tailscale.

Arguments:
  env           Environment name (e.g. cit)
  worker-name   Worker subdirectory under envs/<env>/ (e.g. gpu-worker)

Flags:
  --ssh-user USER       SSH username (default: auto-detect)
  --ssh-key PATH        SSH private key (default: ~/.ssh/id_ed25519)
  --label KEY=VALUE     Add label to node (repeatable, e.g. --label gpu=rtx4080)
  --taint KEY=VAL:EFF   Add taint to node (repeatable, e.g. --taint gpu=rtx4080:NoSchedule)
  --remove              Park: drain, delete node, stop+disable k3s-agent
                        (keeps k3s and the containerd image cache for fast revival)
  --uninstall           Like --remove, but also runs k3s-agent-uninstall.sh
                        (wipes /var/lib/rancher incl. cached images)
  --debug               Enable debug output
  -h, --help            Show this help
EOF
  exit 0
}

# --- Parse arguments ---
ENV_ARG=""
WORKER_ARG=""
declare -a LABELS=()
declare -a TAINTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-user)  SSH_USER="$2"; shift 2 ;;
    --ssh-key)   SSH_KEY="$2"; shift 2 ;;
    --label)     LABELS+=("$2"); shift 2 ;;
    --taint)     TAINTS+=("$2"); shift 2 ;;
    --remove)    REMOVE=true; shift ;;
    --uninstall) REMOVE=true; UNINSTALL=true; shift ;;
    --debug)     DEBUG=true; shift ;;
    -h|--help)   usage ;;
    -*)          err "Unknown flag: $1"; usage ;;
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

# Validate required vars
for var in VLAN_IP MASTER_VLAN_IP MASTER_HOSTNAME EXTERNAL_IP; do
  if [[ -z "${!var:-}" ]]; then
    err "${var} not set in ${ENV_FILE}"
    exit 1
  fi
done

# Default labels/taints from env.properties (comma-separated NODE_LABELS / NODE_TAINTS),
# so a temporary node rejoins with the right scheduling config without remembering flags.
if [[ ${#LABELS[@]} -eq 0 && -n "${NODE_LABELS:-}" ]]; then
  IFS=',' read -r -a LABELS <<< "$NODE_LABELS"
fi
if [[ ${#TAINTS[@]} -eq 0 && -n "${NODE_TAINTS:-}" ]]; then
  IFS=',' read -r -a TAINTS <<< "$NODE_TAINTS"
fi

# Strip CIDR suffix from VLAN_IP if present (e.g. 100.64.148.61/32 -> 100.64.148.61)
VLAN_IP_ADDR="${VLAN_IP%%/*}"
MASTER_VLAN_IP_ADDR="${MASTER_VLAN_IP%%/*}"

# Derive node name from worker directory name or hostname
NODE_NAME="${WORKER_ARG}"
# Normalize: replace underscores with hyphens for K8s
NODE_NAME="${NODE_NAME//_/-}"

info "K3s worker join for ${ENV_NAME}/${WORKER_ARG}"
info "  Node:   ${NODE_NAME}"
info "  Worker: ${VLAN_IP_ADDR} (Tailscale)"
info "  Master: ${MASTER_VLAN_IP_ADDR} (Tailscale)"

# --- SSH setup ---
if [[ -z "$SSH_KEY" ]]; then
  SSH_KEY=$(provision::default_ssh_key_base) || { err "No SSH key found"; exit 1; }
fi
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$SSH_KEY")

# Prefer EXTERNAL_IP for SSH (Tailscale SSH may intercept connections to Tailscale IPs
# and require browser-based auth, which breaks BatchMode)
SSH_HOST="$EXTERNAL_IP"
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
  # Fall back to Tailscale IP
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

# --- Load master kubeconfig ---
KUBECONFIG_FILE="${ENV_ROOT}/${ENV_ARG}/kubeconfig.yaml"
if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  err "Kubeconfig not found: ${KUBECONFIG_FILE}"
  exit 1
fi
export KUBECONFIG="$KUBECONFIG_FILE"

# --- Remove mode ---
if $REMOVE; then
  info "Removing worker node ${NODE_NAME} from cluster..."

  # Step 1: Drain
  info "Step 1/3: Draining node ${NODE_NAME}..."
  kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --timeout=120s 2>/dev/null || \
    warn "Drain failed or node not found (may already be removed)"

  # Step 2: Delete from cluster
  info "Step 2/3: Deleting node ${NODE_NAME} from cluster..."
  kubectl delete node "$NODE_NAME" 2>/dev/null || \
    warn "Node deletion failed (may already be removed)"

  # Step 3: Stop and disable k3s-agent on the worker. Disabling matters: an enabled
  # agent re-registers a bare node (no labels/taints applied via kubectl) on next boot.
  info "Step 3/3: Stopping k3s-agent on ${NODE_NAME}..."
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo systemctl stop k3s-agent && sudo systemctl disable k3s-agent" 2>/dev/null || \
    warn "Failed to stop k3s-agent (box may be powered off — disable it manually on next boot)"

  if $UNINSTALL; then
    info "Uninstalling k3s-agent (wipes cached images)..."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true" || true
    ok "Worker node ${NODE_NAME} removed and k3s uninstalled"
  else
    # Flush k3s' iptables (KUBE-*/CNI-/flannel). Stopping the agent does NOT remove them,
    # and the stale kube-proxy rules hijack outbound :443 to the master's LoadBalancer IP
    # (DNAT to a now-dead pod) — which silently breaks Harbor pulls / any HTTPS to the
    # master from the parked box (e.g. local docker-based render dev). k3s-killall.sh
    # strips only KUBE-/CNI-/flannel rules (keeps Docker + the Tailscale tunnel NAT) and
    # leaves the install + image cache intact.
    info "Flushing stale k3s iptables on ${NODE_NAME} (clean networking while parked)..."
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo /usr/local/bin/k3s-killall.sh 2>/dev/null || true" || \
      warn "Could not run k3s-killall.sh (box may be off); stale :443 NAT may linger until next boot"
    ok "Worker node ${NODE_NAME} parked (k3s + image cache kept; iptables cleaned; rejoin re-enables the agent)"
  fi
  exit 0
fi

# --- Verify master reachability from worker ---
info "Verifying worker can reach master K3s API (${MASTER_VLAN_IP_ADDR}:6443)..."
if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/${MASTER_VLAN_IP_ADDR}/6443'" 2>/dev/null; then
  err "Cannot reach K3s API at ${MASTER_VLAN_IP_ADDR}:6443 from worker"
  err "Ensure Tailscale is running on both nodes and connectivity is established."
  exit 1
fi
ok "Master K3s API reachable from worker"

# --- Get K3s node token from master ---
info "Fetching K3s node token from master..."

# Try SSH to master via Tailscale IP
MASTER_SSH_HOST="$MASTER_VLAN_IP_ADDR"
MASTER_NODE_TOKEN=""

for master_user in admin tim root; do
  MASTER_NODE_TOKEN=$(ssh "${SSH_OPTS[@]}" "${master_user}@${MASTER_SSH_HOST}" \
    "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null || true)
  if [[ -n "$MASTER_NODE_TOKEN" ]]; then
    info "  Fetched token via SSH as ${master_user}@${MASTER_SSH_HOST}"
    break
  fi
done

if [[ -z "$MASTER_NODE_TOKEN" ]]; then
  err "Could not fetch K3s node token from master."
  err "Retrieve it manually: ssh <user>@${MASTER_SSH_HOST} sudo cat /var/lib/rancher/k3s/server/node-token"
  err "Then set K3S_TOKEN=<token> and re-run."
  exit 1
fi
ok "Got K3s node token"

# --- Persist agent config (flannel-iface, labels, taints) ---
# kubectl-applied labels/taints live on the node object and die with it (e.g. parked
# with --remove while the box is off, then the node re-registers on next boot).
# /etc/rancher/k3s/config.yaml survives on the host and is applied at every fresh
# registration, so a power-cycled temporary node always comes back correctly scheduled.
#
# flannel-iface=tailscale0 is essential: the worker reaches the master only over
# Tailscale, so flannel must bind its VXLAN to tailscale0 (otherwise it picks the
# LAN/default interface and cross-node pod traffic — service DNS, in-cluster S3 —
# is silently undeliverable). The master must also run flannel-iface=tailscale0.
K3S_CONFIG="# Managed by join-worker.sh"$'\n'
K3S_CONFIG+="flannel-iface: tailscale0"$'\n'
if [[ ${#LABELS[@]} -gt 0 ]]; then
  K3S_CONFIG+="node-label:"$'\n'
  for label in "${LABELS[@]}"; do K3S_CONFIG+="  - \"${label}\""$'\n'; done
fi
if [[ ${#TAINTS[@]} -gt 0 ]]; then
  K3S_CONFIG+="node-taint:"$'\n'
  for taint in "${TAINTS[@]}"; do K3S_CONFIG+="  - \"${taint}\""$'\n'; done
fi
info "Persisting agent config (flannel-iface/labels/taints) to /etc/rancher/k3s/config.yaml..."
printf '%s' "$K3S_CONFIG" | ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
  "sudo mkdir -p /etc/rancher/k3s && sudo tee /etc/rancher/k3s/config.yaml >/dev/null"
ok "Agent config persisted"

# --- Make ingress hosts (Harbor) resolve to the master over Tailscale ---
# Registry/ingress hostnames resolve via public DNS to the master's PUBLIC IP, which
# the worker can't reach. Pin them to the master's Tailscale IP in /etc/hosts so
# containerd can pull images (Traefik serves the valid LE cert by SNI regardless of IP).
if [[ -n "${REGISTRY_HOSTS:-}" ]]; then
  HOSTS_BLOCK=""
  for h in ${REGISTRY_HOSTS//,/ }; do
    HOSTS_BLOCK+="${MASTER_VLAN_IP_ADDR} ${h}"$'\n'
  done
  info "Pinning registry/ingress hosts to ${MASTER_VLAN_IP_ADDR} in /etc/hosts: ${REGISTRY_HOSTS}"
  printf '%s' "$HOSTS_BLOCK" | ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo bash -c '
    sed -i \"/# join-worker registry hosts/,+0d\" /etc/hosts
    for h in ${REGISTRY_HOSTS//,/ }; do sed -i \"/ \$h\\$/d\" /etc/hosts; done
    while read -r line; do [ -n \"\$line\" ] && echo \"\$line # join-worker registry hosts\" >> /etc/hosts; done
  '"
  ok "Registry hosts pinned"
fi

# --- Check if already joined ---
if kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
  NODE_STATUS=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  if [[ "$NODE_STATUS" == "True" ]]; then
    ok "Node ${NODE_NAME} is already joined and Ready"
    # Still apply labels/taints below
  else
    warn "Node ${NODE_NAME} exists but is not Ready (status: ${NODE_STATUS}). Proceeding with re-join."
  fi
elif ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "test -x /usr/local/bin/k3s && test -f /etc/systemd/system/k3s-agent.service" 2>/dev/null; then
  # Parked node: k3s still installed (image cache intact), agent stopped/disabled.
  # Restart (not just enable --now) so a running agent re-reads config.yaml too.
  info "k3s-agent already installed — reviving parked node..."
  # The server URL and token are baked into the agent env file at install time; if the
  # master's Tailscale IP changed or the cluster CA was rotated while parked, rewrite
  # both so the agent connects to the new one (a stale token's embedded CA hash makes
  # the agent spin in "activating" forever, hanging systemctl restart).
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo sed -i \
    -e \"s|^K3S_URL=.*|K3S_URL='https://${MASTER_VLAN_IP_ADDR}:6443'|\" \
    -e \"s|^K3S_TOKEN=.*|K3S_TOKEN='${MASTER_NODE_TOKEN}'|\" \
    /etc/systemd/system/k3s-agent.service.env && sudo systemctl daemon-reload"
  # --no-block: k3s-agent is Type=notify, so a restart blocks until the agent is ready —
  # an agent that can't validate its token never gets there and hangs the script. Let the
  # registration poll below time out with a diagnosable error instead.
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo systemctl enable k3s-agent >/dev/null 2>&1; sudo systemctl restart --no-block k3s-agent"

  info "Waiting for node ${NODE_NAME} to register..."
  for i in $(seq 1 30); do
    if kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  if ! kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
    err "Node ${NODE_NAME} did not register within 60 seconds."
    err "Check: ssh ${SSH_TARGET} sudo journalctl -u k3s-agent -n 50"
    exit 1
  fi
  ok "Node ${NODE_NAME} re-registered"
else
  # --- Determine K3s version (must match the server) ---
  SERVER_VERSION=$(kubectl get node -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)
  if [[ -n "$SERVER_VERSION" ]]; then
    info "Server K3s version: ${SERVER_VERSION}. Agent will match."
    K3S_VERSION_FLAG="INSTALL_K3S_VERSION=${SERVER_VERSION}"
  else
    warn "Could not detect server K3s version. Agent will install latest stable."
    K3S_VERSION_FLAG=""
  fi

  # --- Install K3s agent ---
  info "Installing K3s agent on ${NODE_NAME}..."
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" bash -s <<AGENT
set -euo pipefail
export K3S_URL="https://${MASTER_VLAN_IP_ADDR}:6443"
export K3S_TOKEN="${MASTER_NODE_TOKEN}"
${K3S_VERSION_FLAG:+export ${K3S_VERSION_FLAG}}
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent \\
  --node-ip ${VLAN_IP_ADDR} \\
  --node-external-ip ${EXTERNAL_IP} \\
  --node-name ${NODE_NAME}" sh -

# Verify k3s-agent started
if ! systemctl is-active --quiet k3s-agent; then
  echo "[ERROR] k3s-agent failed to start" >&2
  systemctl status k3s-agent --no-pager || true
  journalctl -u k3s-agent -n 30 --no-pager || true
  exit 1
fi
echo "[OK] k3s-agent is running"
AGENT
  ok "K3s agent installed on ${NODE_NAME}"

  # Wait for node to register
  info "Waiting for node ${NODE_NAME} to register..."
  for i in $(seq 1 30); do
    if kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if ! kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
    err "Node ${NODE_NAME} did not register within 60 seconds."
    err "Check: ssh ${SSH_TARGET} sudo journalctl -u k3s-agent -n 50"
    exit 1
  fi
  ok "Node ${NODE_NAME} registered"
fi

# --- Ensure agent starts on boot (all join paths) ---
# Joined state implies auto-rejoin after a reboot; with labels/taints in
# config.yaml that is safe. Parking (--remove) disables the agent again.
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo systemctl enable k3s-agent >/dev/null 2>&1 || true"

# --- Fix K3s tunnel routing (all join paths: fresh install, revival, already-joined) ---
# K3s agents establish a websocket tunnel to the server for kubelet proxying (logs, exec).
# The agent discovers the server's external IP from the API and uses it for the tunnel.
# If the worker can only reach the server via Tailscale (not its external IP), the tunnel
# will fail with "failed to find Session" on the server side.
# Fix: DNAT+MASQUERADE to redirect the external IP to the Tailscale IP.
# --- Worker → master NAT / routing (applied whenever joined over Tailscale) ---
# (1) Harbor/ingress :443 bypass (always, when REGISTRY_HOSTS set). Registry hosts are
#     pinned to MASTER_VLAN_IP, which is also Traefik's LoadBalancer IP. While joined,
#     kube-proxy DNATs :443→that IP into the in-cluster Traefik POD, reached over
#     flannel-VXLAN-over-Tailscale. That double encapsulation exceeds the real ~1228B
#     Tailscale path MTU (the interface claims 1280), so large TLS flights — image
#     manifests / cert chains — are DF-dropped and pulls hang as "TLS handshake timeout"
#     (tiny curls survive). A RETURN before KUBE-SERVICES makes :443→MASTER_VLAN_IP skip
#     the DNAT and hit the master's HOST Traefik directly over Tailscale (single-encap,
#     fits the path) — the same path that works when the node is parked.
# (2) Tunnel/VXLAN DNAT (6443/8472) from the master's PUBLIC IP — only when the master
#     advertises a non-Tailscale InternalIP. Skipped on current cit (master is on its
#     Tailscale IP, so API/tunnel/VXLAN already reach it directly).
# The master may report dual-stack InternalIPs; take the IPv4 one.
MASTER_EXTERNAL_IP=$(kubectl get node -l node-role.kubernetes.io/control-plane \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null \
  | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
NEED_TUNNEL_NAT=false
if [[ -n "$MASTER_EXTERNAL_IP" && "$MASTER_EXTERNAL_IP" != "$MASTER_VLAN_IP_ADDR" ]]; then
  NEED_TUNNEL_NAT=true
fi
# Build the persisted rules.v4 (only rules we manage — a full iptables-save would capture
# KUBE-*/CNI-* chains that fail to restore at boot). At boot, restore APPENDs to the
# still-empty OUTPUT chain, so the bypass lands ahead of kube-proxy's later jump.
PERSIST_BODY="*nat"
if [[ -n "${REGISTRY_HOSTS:-}" ]]; then
  PERSIST_BODY+=$'\n'"-A OUTPUT -d ${MASTER_VLAN_IP_ADDR}/32 -p tcp --dport 443 -j RETURN"
fi
if $NEED_TUNNEL_NAT; then
  PERSIST_BODY+=$'\n'"-A OUTPUT -d ${MASTER_EXTERNAL_IP}/32 -p tcp --dport 6443 -j DNAT --to-destination ${MASTER_VLAN_IP_ADDR}:6443"
  PERSIST_BODY+=$'\n'"-A OUTPUT -d ${MASTER_EXTERNAL_IP}/32 -p udp --dport 8472 -j DNAT --to-destination ${MASTER_VLAN_IP_ADDR}"
  PERSIST_BODY+=$'\n'"-A POSTROUTING -d ${MASTER_VLAN_IP_ADDR}/32 -p tcp --dport 6443 -o tailscale0 -j MASQUERADE"
  PERSIST_BODY+=$'\n'"-A POSTROUTING -d ${MASTER_VLAN_IP_ADDR}/32 -p udp --dport 8472 -o tailscale0 -j MASQUERADE"
fi
PERSIST_BODY+=$'\n'"COMMIT"

info "Ensuring worker NAT (Harbor :443 bypass$([[ $NEED_TUNNEL_NAT == true ]] && echo ' + tunnel DNAT'))..."
NAT_OUT=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" sudo bash -s <<NAT
set -euo pipefail
# (1) Harbor bypass — insert before KUBE-SERVICES (idempotent).
if [[ -n "${REGISTRY_HOSTS:-}" ]]; then
  if ! iptables -t nat -C OUTPUT -d ${MASTER_VLAN_IP_ADDR} -p tcp --dport 443 -j RETURN 2>/dev/null; then
    iptables -t nat -I OUTPUT 1 -d ${MASTER_VLAN_IP_ADDR} -p tcp --dport 443 -j RETURN
  fi
fi
# (2) tunnel DNAT (only when the master advertises a non-Tailscale InternalIP)
if [[ "${NEED_TUNNEL_NAT}" == "true" ]]; then
  iptables -t nat -S OUTPUT | grep -E -- '--dport (6443|8472) .*DNAT' | grep -v -- "--to-destination ${MASTER_VLAN_IP_ADDR}" | sed 's/^-A //' | while read -r r; do iptables -t nat -D \$r; echo TUNNEL_CHANGED; done
  addt() { local proto=\$1 dport=\$2 dnat=\$3
    if ! iptables -t nat -C OUTPUT -d ${MASTER_EXTERNAL_IP} -p \$proto --dport \$dport -j DNAT --to-destination ${MASTER_VLAN_IP_ADDR}\$dnat 2>/dev/null; then
      iptables -t nat -A OUTPUT -d ${MASTER_EXTERNAL_IP} -p \$proto --dport \$dport -j DNAT --to-destination ${MASTER_VLAN_IP_ADDR}\$dnat; echo TUNNEL_CHANGED; fi
    if ! iptables -t nat -C POSTROUTING -d ${MASTER_VLAN_IP_ADDR} -p \$proto --dport \$dport -o tailscale0 -j MASQUERADE 2>/dev/null; then
      iptables -t nat -A POSTROUTING -d ${MASTER_VLAN_IP_ADDR} -p \$proto --dport \$dport -o tailscale0 -j MASQUERADE; echo TUNNEL_CHANGED; fi
  }
  addt tcp 6443 :6443
  addt udp 8472 ""
fi
# Persist across reboots.
if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections
  echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections
  apt-get install -y -qq iptables-persistent >/dev/null
fi
mkdir -p /etc/iptables
cat > /etc/iptables/rules.v4 <<'RULESEOF'
${PERSIST_BODY}
RULESEOF
rm -f /etc/iptables/rules.v6
echo "[OK] Worker NAT rules configured"
NAT
)
if [[ $NEED_TUNNEL_NAT == true ]] && grep -q TUNNEL_CHANGED <<<"$NAT_OUT"; then
  info "Tunnel NAT changed — restarting k3s-agent..."
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo systemctl restart k3s-agent"
  sleep 5
fi
ok "Worker NAT in place (Harbor :443 bypass$([[ $NEED_TUNNEL_NAT == true ]] && echo ' + 6443/8472 tunnel'))"

# --- Apply labels ---
if [[ ${#LABELS[@]} -gt 0 ]]; then
  info "Applying labels to node ${NODE_NAME}..."
  for label in "${LABELS[@]}"; do
    kubectl label node "$NODE_NAME" "$label" --overwrite
    info "  Label: ${label}"
  done
  ok "Labels applied"
fi

# --- Apply taints ---
if [[ ${#TAINTS[@]} -gt 0 ]]; then
  info "Applying taints to node ${NODE_NAME}..."
  for taint in "${TAINTS[@]}"; do
    kubectl taint nodes "$NODE_NAME" "$taint" --overwrite 2>/dev/null || \
      kubectl taint nodes "$NODE_NAME" "$taint"
    info "  Taint: ${taint}"
  done
  ok "Taints applied"
fi

# --- Final status ---
echo ""
info "=== Worker node joined ==="
kubectl get node "$NODE_NAME" -o wide
echo ""

if [[ ${#LABELS[@]} -eq 0 && ${#TAINTS[@]} -eq 0 ]]; then
  info "Tip: Add GPU labels/taints with:"
  info "  kubectl label node ${NODE_NAME} gpu=rtx4080"
  info "  kubectl taint nodes ${NODE_NAME} gpu=rtx4080:NoSchedule"
fi

info ""
info "Next step for GPU nodes:"
info "  tools/k3s/gpu-nvidia.sh ${ENV_ARG} ${WORKER_ARG}"
