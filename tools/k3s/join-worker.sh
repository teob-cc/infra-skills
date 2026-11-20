#!/usr/bin/env bash
set -euo pipefail

# Join a worker node to an existing K3s cluster via Tailscale.
# Unlike provision-hetzner-baremetal.sh, this does NOT assume Hetzner VLAN.
# The worker connects to the master via Tailscale IPs.
#
# Usage: join-worker.sh <env> <worker-name> [flags]
#   e.g.: join-worker.sh cit gpu-worker --ssh-user <user>
#
# Reads env.properties from envs/<env>/<worker-name>/env.properties
# Expects: VLAN_IP (Tailscale IP), MASTER_VLAN_IP, MASTER_HOSTNAME, EXTERNAL_IP
# Optional: TENANT, NODE_LABELS, NODE_TAINTS, REGISTRY_HOSTS, MASTER_SSH_USER,
#   SSH_VIA=tailscale (SSH straight to VLAN_IP, e.g. when the public :22 is firewalled)

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
TENANT_FLAG=""
TOKEN_MODE=""
KEEP_QUARANTINE=false
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
  --label KEY=VALUE     Add label to node (repeatable, e.g. --label gpu=rtx4080).
                        infra-skills/on-demand=true marks a node that is powered on only
                        when needed: alerts treat it as parked, not failed, while it is
                        not Ready (docs/ALERTING.md, "On-demand nodes")
  --taint KEY=VAL:EFF   Add taint to node (repeatable, e.g. --taint gpu=rtx4080:NoSchedule)
  --tenant NAME         Join a shared-root tenant worker (docs/TENANTS.md; or TENANT= in the worker's
                        env.properties): short-lived agent-only join token, tenant-only registries.yaml, node name
                        NAME-*, taints infra-skills/quarantine + infra-skills/tenant=NAME:NoExecute,
                        label node-restriction.kubernetes.io/tenant=NAME set as cluster admin.
                        Needs tools/k3s/tenant-admission.sh first
  --token MODE          Join token: bootstrap (a k3s bootstrap token made for this join, agent-only,
                        deleted when the run ends; default for --tenant), agent (server/agent-token,
                        when the server was installed with one), server (the server token, which
                        also admits servers) or auto (default: agent if present, else server).
                        An agent already joined is moved off the server token. JOIN_TOKEN_TTL
                        (default 30m) bounds a bootstrap token that could not be deleted
  --keep-quarantine     Leave the infra-skills/quarantine taint on a newly registered node (by
                        default it is lifted once the node registered with the expected address)
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
    --tenant)    TENANT_FLAG="$2"; shift 2 ;;
    --token)     TOKEN_MODE="$2"; shift 2 ;;
    --keep-quarantine) KEEP_QUARANTINE=true; shift ;;
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

# --- Tenant worker (shared root, docs/TENANTS.md) ---
TENANT="${TENANT_FLAG:-${TENANT:-}}"
TENANT_NODE_LABEL="node-restriction.kubernetes.io/tenant"
TENANT_TAINT="infra-skills/tenant"
QUARANTINE_TAINT="infra-skills/quarantine"
if [[ -n "$TENANT" ]]; then
  if [[ ! "$TENANT" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    err "Tenant name must be a DNS label: ${TENANT}"; exit 1
  fi
  if [[ "$NODE_NAME" != "${TENANT}-"* ]]; then
    err "A node of tenant ${TENANT} must be named ${TENANT}-* (got ${NODE_NAME}): the admission policies recognise tenant nodes by name"
    exit 1
  fi
  case "${TOKEN_MODE:-bootstrap}" in
    bootstrap|agent) TOKEN_MODE="${TOKEN_MODE:-bootstrap}" ;;
    *) err "A tenant worker joins with an agent-only token (--token bootstrap, the default, or agent), never with the server token"; exit 1 ;;
  esac
fi
TOKEN_MODE="${TOKEN_MODE:-auto}"
case "$TOKEN_MODE" in bootstrap|agent|server|auto) ;; *) err "--token must be bootstrap, agent, server or auto"; exit 1 ;; esac
# Labels under node-restriction.kubernetes.io/ can be set only by an admin (NodeRestriction):
# the kubelet would fail to register with them, so they are never persisted in config.yaml.
# A tenant node persists no labels at all: tenant-admission.sh lets its kubelet register
# only with the labels the kubelet maintains itself.
declare -a PERSIST_LABELS=()
for label in ${LABELS[@]+"${LABELS[@]}"}; do
  [[ "$label" == "${TENANT_NODE_LABEL}="* && -n "$TENANT" ]] && { err "--label ${TENANT_NODE_LABEL} is set by --tenant"; exit 1; }
  [[ -n "$TENANT" || "$label" == node-restriction.kubernetes.io/* ]] && continue
  PERSIST_LABELS+=("$label")
done

info "K3s worker join for ${ENV_NAME}/${WORKER_ARG}"
[[ -n "$TENANT" ]] && info "  Tenant: ${TENANT} (shared-root tenant worker)"
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
# SSH_VIA=tailscale (worker env.properties): go straight to the Tailscale IP, e.g. a cloud
# node whose public :22 is closed by its firewall (saves the timeout of the probe below).
[[ "${SSH_VIA:-}" == tailscale ]] && SSH_HOST="$VLAN_IP_ADDR"
if [[ -n "$SSH_USER" && "$SSH_HOST" != "$VLAN_IP_ADDR" ]]; then
  # The LAN address is only reachable from the same network; when operating
  # remotely, fall back to the Tailscale IP.
  if ! ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${SSH_USER}@${SSH_HOST}" "true" 2>/dev/null; then
    warn "Worker not reachable at ${SSH_HOST}, falling back to Tailscale IP ${VLAN_IP_ADDR}"
    SSH_HOST="$VLAN_IP_ADDR"
  fi
fi
if [[ -z "$SSH_USER" ]]; then
  for u in admin root; do
    if ssh "${SSH_OPTS[@]}" "$u@${SSH_HOST}" "true" 2>/dev/null; then
      SSH_USER="$u"
      break
    fi
  done
  # Fall back to Tailscale IP
  if [[ -z "$SSH_USER" ]]; then
    SSH_HOST="$VLAN_IP_ADDR"
    for u in admin root; do
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
# Restored from envs/<env>/secrets.sops/kubeconfig when the git-ignored file is missing.
KUBECONFIG_FILE="$(provision::ensure_kubeconfig "${ENV_ARG}")" || exit 1
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

# --- Get the join token from the master ---
# server/node-token is the server token: it also admits a new SERVER, which gets the
# datastore and every Secret. An agent keeps its token in
# /etc/systemd/system/k3s-agent.service.env, readable by whoever is root on it. Modes:
#   bootstrap  a bootstrap token made for this join (`k3s token create --ttl`), deleted again
#              once the node registered. It joins agents only (a server join is refused) and
#              the copy left on the node is dead afterwards; the agent keeps working through
#              restarts on its node password. No change on the server. Default for --tenant.
#   agent      server/agent-token, when the server was installed with a separate agent-token.
#              Not added here to a running server: on k3s v1.36 (sqlite) adding agent-token to
#              an existing server makes every k3s start after the first fail with
#              "cred/passwd newer than datastore" (INFRA-214, reproduced 2026-11-20).
#   server     the server token (the historical default).
#   auto       agent when the server has a separate agent token, else server (default).
info "Fetching K3s join token from master (--token ${TOKEN_MODE})..."

# Try SSH to master via Tailscale IP
MASTER_SSH_HOST="$MASTER_VLAN_IP_ADDR"
MASTER_NODE_TOKEN=""
AGENT_TOKEN_STATE=""
BOOTSTRAP_TOKEN_ID=""

MASTER_USERS=(admin root)
[[ -n "${MASTER_SSH_USER:-}" ]] && MASTER_USERS=("$MASTER_SSH_USER" "${MASTER_USERS[@]}")
for master_user in "${MASTER_USERS[@]}"; do
  AGENT_TOKEN_STATE=$(ssh "${SSH_OPTS[@]}" "${master_user}@${MASTER_SSH_HOST}" \
    "d=/var/lib/rancher/k3s/server; sudo test -f \$d/node-token || exit 1; if sudo test -f \$d/agent-token && ! sudo test -L \$d/agent-token && ! sudo cmp -s \$d/token \$d/agent-token; then echo separate; else echo shared; fi" \
    2>/dev/null || true)
  if [[ -n "$AGENT_TOKEN_STATE" ]]; then
    MASTER_SSH_USER="$master_user"
    break
  fi
done
if [[ -z "$AGENT_TOKEN_STATE" ]]; then
  err "Could not read the K3s tokens on the master."
  err "Retrieve it manually: ssh <user>@${MASTER_SSH_HOST} sudo cat /var/lib/rancher/k3s/server/node-token"
  err "Or set MASTER_SSH_USER=<user> (a login with sudo on the master) and re-run."
  exit 1
fi
if [[ "$TOKEN_MODE" == auto ]]; then
  if [[ "$AGENT_TOKEN_STATE" == separate ]]; then
    TOKEN_MODE=agent
  else
    TOKEN_MODE=server
    warn "Joining with the server token, which also admits servers; --token bootstrap joins with a short-lived agent-only token instead."
  fi
fi
case "$TOKEN_MODE" in
  agent)
    if [[ "$AGENT_TOKEN_STATE" != separate ]]; then
      err "The server has no separate agent token (server/agent-token is the server token). Use --token bootstrap."
      exit 1
    fi
    MASTER_NODE_TOKEN=$(ssh "${SSH_OPTS[@]}" "${MASTER_SSH_USER}@${MASTER_SSH_HOST}" "sudo cat /var/lib/rancher/k3s/server/agent-token" 2>/dev/null || true)
    [[ "$MASTER_NODE_TOKEN" == *"::server:"* ]] && { err "server/agent-token holds a server token; refusing"; exit 1; }
    ;;
  server)
    MASTER_NODE_TOKEN=$(ssh "${SSH_OPTS[@]}" "${MASTER_SSH_USER}@${MASTER_SSH_HOST}" "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null || true)
    ;;
  bootstrap)
    MASTER_NODE_TOKEN=$(ssh "${SSH_OPTS[@]}" "${MASTER_SSH_USER}@${MASTER_SSH_HOST}" \
      "sudo k3s token create --ttl ${JOIN_TOKEN_TTL:-30m} --description 'join-worker ${NODE_NAME}' 2>/dev/null | tail -1" 2>/dev/null || true)
    if [[ ! "$MASTER_NODE_TOKEN" =~ ::[a-z0-9]{6}\.[a-z0-9]{16}$ ]]; then
      err "Could not create a bootstrap token on the master (k3s token create)"; exit 1
    fi
    BOOTSTRAP_TOKEN_ID="${MASTER_NODE_TOKEN##*::}"; BOOTSTRAP_TOKEN_ID="${BOOTSTRAP_TOKEN_ID%%.*}"
    ;;
esac
if [[ -z "$MASTER_NODE_TOKEN" ]]; then
  err "Could not read the ${TOKEN_MODE} token on the master as ${MASTER_SSH_USER}@${MASTER_SSH_HOST}"
  exit 1
fi
ok "Got K3s ${TOKEN_MODE} token (via ${MASTER_SSH_USER}@${MASTER_SSH_HOST})${BOOTSTRAP_TOKEN_ID:+, id ${BOOTSTRAP_TOKEN_ID}, valid ${JOIN_TOKEN_TTL:-30m}}"
# Delete the bootstrap token when the script ends, joined or not: its job is done once the
# node registered, and an unused one should not outlive the run.
delete_bootstrap_token() {
  [[ -n "$BOOTSTRAP_TOKEN_ID" ]] || return 0
  ssh "${SSH_OPTS[@]}" "${MASTER_SSH_USER}@${MASTER_SSH_HOST}" "sudo k3s token delete ${BOOTSTRAP_TOKEN_ID} >/dev/null 2>&1" \
    && info "Bootstrap token ${BOOTSTRAP_TOKEN_ID} deleted" \
    || warn "Could not delete bootstrap token ${BOOTSTRAP_TOKEN_ID}; it expires after ${JOIN_TOKEN_TTL:-30m}"
  BOOTSTRAP_TOKEN_ID=""
}
trap delete_bootstrap_token EXIT

# A node that once held the server token keeps it in the agent env file until rewritten
# below; if the tenant already had root then, the server token must be rotated.
if [[ -n "$TENANT" ]] && ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
     "sudo grep -q '::server:' /etc/systemd/system/k3s-agent.service.env 2>/dev/null"; then
  warn "This node holds the SERVER token in /etc/systemd/system/k3s-agent.service.env; it is replaced now."
  warn "  If the tenant was already root on it, rotate the server token (k3s token rotate) — see docs/TENANTS.md."
fi

# --- Admission policies (tools/k3s/tenant-admission.sh) ---
# With infra-skills-node-registration in place a kubelet can register a new node only with
# the quarantine taint; a tenant node additionally needs the tenant policies, or nothing
# stops its kubelet from untainting or relabelling itself.
REGISTRATION_POLICY=false
kubectl get validatingadmissionpolicy infra-skills-node-registration >/dev/null 2>&1 && REGISTRATION_POLICY=true
if [[ -n "$TENANT" ]]; then
  for p in infra-skills-node-registration infra-skills-tenant-node-self infra-skills-node-shared-agent-identity infra-skills-tenant-pod-placement; do
    if ! kubectl get validatingadmissionpolicybinding "$p" >/dev/null 2>&1; then
      err "Admission policy ${p} is not installed: run tools/k3s/tenant-admission.sh ${ENV_ARG} (with TENANTS including ${TENANT}) first"
      exit 1
    fi
    if ! kubectl get validatingadmissionpolicybinding "$p" -o json | jq -e '.spec.validationActions | index("Deny")' >/dev/null; then
      warn "Admission policy ${p} only warns (validationActions without Deny): it does not protect this tenant node yet"
    fi
  done
  if ! kubectl get validatingadmissionpolicy infra-skills-node-registration -o json \
       | jq -e --arg t "$TENANT" '.spec.variables[] | select(.name == "tenant") | .expression | contains("\"" + $t + "\"")' >/dev/null; then
    err "tenant-admission.sh does not know tenant ${TENANT}: add it to TENANTS in envs/${ENV_ARG}/env.properties and re-run it"
    exit 1
  fi
fi
QUARANTINE=false
if ! kubectl get node "$NODE_NAME" >/dev/null 2>&1 && { [[ -n "$TENANT" ]] || $REGISTRATION_POLICY; }; then
  QUARANTINE=true
fi
# A tenant node always carries its quarantine taint in config.yaml: whenever it registers
# anew it waits for an admin (this script) to check it and lift the taint.
[[ -n "$TENANT" ]] && TAINTS=("${TENANT_TAINT}=${TENANT}:NoExecute" ${TAINTS[@]+"${TAINTS[@]}"})
# The quarantine taint is persisted (applied at every fresh registration) but never applied
# with kubectl below: this script lifts it once the node checks out.
declare -a PERSIST_TAINTS=(${TAINTS[@]+"${TAINTS[@]}"})
if [[ -n "$TENANT" ]] || $REGISTRATION_POLICY; then
  PERSIST_TAINTS=("${QUARANTINE_TAINT}=true:NoExecute" ${PERSIST_TAINTS[@]+"${PERSIST_TAINTS[@]}"})
fi
if $QUARANTINE && [[ -z "$TENANT" ]]; then
  info "infra-skills-node-registration is installed: ${NODE_NAME} registers quarantined (${QUARANTINE_TAINT}=true:NoExecute)"
fi

# --- Registry credentials (containerd) ---
# harbor.sh writes the pull-only robot for Harbor's private projects into the server's
# /etc/rancher/k3s/registries.yaml; an agent needs the same file or it cannot pull from
# library/dockerhub-proxy. Copy it (never printed); an agent that is already running is
# restarted below only when the file changed.
#
# A tenant node gets its own file instead: the server's mirrors, every credential removed,
# and only the tenant's pull robot (envs/<env>/secrets.plain/registry-tenant-<tenant>.yaml,
# or its secrets.sops copy: stringData.registry, .username, .password). The platform's
# node-pull robot would let the tenant pull every private platform image.
REGISTRIES_CHANGED=false
REGISTRIES_YAML=$(ssh "${SSH_OPTS[@]}" "${MASTER_SSH_USER}@${MASTER_SSH_HOST}" \
  "sudo cat /etc/rancher/k3s/registries.yaml 2>/dev/null" 2>/dev/null || true)
if [[ -n "$TENANT" ]]; then
  command -v yq >/dev/null 2>&1 || { err "yq is required for a tenant join"; exit 1; }
  TENANT_REG_PLAIN="${ENV_ROOT}/${ENV_ARG}/secrets.plain/registry-tenant-${TENANT}.yaml"
  TENANT_REG_SOPS="${ENV_ROOT}/${ENV_ARG}/secrets.sops/registry-tenant-${TENANT}.yaml"
  TENANT_REG=""
  if [[ -f "$TENANT_REG_PLAIN" ]]; then
    TENANT_REG=$(cat "$TENANT_REG_PLAIN")
  elif [[ -f "$TENANT_REG_SOPS" ]]; then
    TENANT_REG=$(sops -d "$TENANT_REG_SOPS") || { err "Cannot decrypt ${TENANT_REG_SOPS}"; exit 1; }
  fi
  REG_SRC="${REGISTRIES_YAML:-}"; [[ -n "$REG_SRC" ]] || REG_SRC="{}"
  REG_BASE=$(printf "%s\n" "$REG_SRC" | yq eval 'del(.configs[].auth)' -)
  if [[ -n "$TENANT_REG" ]]; then
    REG_HOST=$(printf '%s\n' "$TENANT_REG" | yq eval '.stringData.registry // ""' -)
    REG_USER=$(printf '%s\n' "$TENANT_REG" | yq eval '.stringData.username // ""' -)
    REG_PASS=$(printf '%s\n' "$TENANT_REG" | yq eval '.stringData.password // ""' -)
    if [[ -z "$REG_HOST" || -z "$REG_USER" || -z "$REG_PASS" ]]; then
      err "registry-tenant-${TENANT}.yaml needs stringData.registry, .username and .password"; exit 1
    fi
    REGISTRIES_YAML=$(printf '%s\n' "$REG_BASE" | H="$REG_HOST" U="$REG_USER" P="$REG_PASS" \
      yq eval '.configs[strenv(H)].auth = {"username": strenv(U), "password": strenv(P)}' -)
    unset REG_PASS TENANT_REG
    info "Tenant registries.yaml: the server's mirrors, ${REG_USER} for ${REG_HOST}, no platform credential"
  else
    REGISTRIES_YAML="$REG_BASE"
    warn "No registry-tenant-${TENANT}.yaml in secrets.plain/ or secrets.sops/: the tenant node gets no registry credential (public images only)"
  fi
  [[ "$REGISTRIES_YAML" == "{}" ]] && REGISTRIES_YAML="# Managed by join-worker.sh --tenant ${TENANT}: no registry credential"
fi
if [[ -n "$REGISTRIES_YAML" ]]; then
  if [[ "$(printf '%s\n' "$REGISTRIES_YAML" | shasum -a 256 | cut -d' ' -f1)" != \
        "$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo cat /etc/rancher/k3s/registries.yaml 2>/dev/null | sha256sum" 2>/dev/null | cut -d' ' -f1)" ]]; then
    printf '%s\n' "$REGISTRIES_YAML" | ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
      "sudo sh -c 'umask 077; mkdir -p /etc/rancher/k3s && cat > /etc/rancher/k3s/registries.yaml'"
    REGISTRIES_CHANGED=true
    if [[ -n "$TENANT" ]]; then ok "Wrote the tenant registries.yaml"; else ok "Copied /etc/rancher/k3s/registries.yaml from the server"; fi
  else
    info "/etc/rancher/k3s/registries.yaml already up to date"
  fi
fi
unset REGISTRIES_YAML


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
if [[ ${#PERSIST_LABELS[@]} -gt 0 ]]; then
  K3S_CONFIG+="node-label:"$'\n'
  for label in "${PERSIST_LABELS[@]}"; do K3S_CONFIG+="  - \"${label}\""$'\n'; done
fi
if [[ ${#PERSIST_TAINTS[@]} -gt 0 ]]; then
  K3S_CONFIG+="node-taint:"$'\n'
  for taint in "${PERSIST_TAINTS[@]}"; do K3S_CONFIG+="  - \"${taint}\""$'\n'; done
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
    # Switch a joined agent to the chosen token (e.g. off the server token). A bootstrap token
    # replaces only a server token: an agent joined with an expired one keeps working.
    TOKEN_SWITCHED=false
    ENV_F=/etc/systemd/system/k3s-agent.service.env
    TOKEN_CURRENT="sudo grep -qxF \"K3S_TOKEN='${MASTER_NODE_TOKEN}'\" $ENV_F"
    [[ "$TOKEN_MODE" == bootstrap ]] && TOKEN_CURRENT="! sudo grep -q '::server:' $ENV_F"
    if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$TOKEN_CURRENT" 2>/dev/null; then
      info "Switching the agent to the ${TOKEN_MODE} token..."
      ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo sed -i \
        -e \"s|^K3S_TOKEN=.*|K3S_TOKEN='${MASTER_NODE_TOKEN}'|\" \
        /etc/systemd/system/k3s-agent.service.env && sudo systemctl daemon-reload"
      TOKEN_SWITCHED=true
    fi
    if [[ "$REGISTRIES_CHANGED" == "true" || "$TOKEN_SWITCHED" == "true" ]]; then
      info "Restarting k3s-agent (new registries.yaml or token)..."
      ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo systemctl restart --no-block k3s-agent"
    fi
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
# (2) Tunnel/VXLAN DNAT (6443/8472) to the master's Tailscale IP, from every non-Tailscale
#     address the agent may dial: the master's InternalIP AND the apiserver endpoint (the
#     `kubernetes` Service endpoint, which the remotedialer tunnel for logs/exec dials).
#     They differ when the master runs on its Tailscale IP but advertises its public IP
#     (tls-san): checking InternalIP alone skipped the NAT and `kubectl logs/exec` on the
#     worker returned 502 (test and prod, 2026-11). Skipped when both are the Tailscale IP.
# The master may report dual-stack addresses; take the IPv4 ones.
ipv4_only() { tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true; }
MASTER_INTERNAL_IP=$(kubectl get node -l node-role.kubernetes.io/control-plane \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | ipv4_only | head -1)
MASTER_API_IPS=$(kubectl -n default get endpoints kubernetes \
  -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | ipv4_only)
TUNNEL_NAT_IPS=$(printf '%s\n' "$MASTER_INTERNAL_IP" $MASTER_API_IPS | grep -v -x -F -e "$MASTER_VLAN_IP_ADDR" -e '' | sort -u | tr '\n' ' ' || true)
TUNNEL_NAT_IPS="${TUNNEL_NAT_IPS% }"
NEED_TUNNEL_NAT=false
if [[ -n "$TUNNEL_NAT_IPS" ]]; then
  NEED_TUNNEL_NAT=true
  info "Master reachable only over Tailscale; tunnel DNAT from: ${TUNNEL_NAT_IPS}"
fi
# Build the persisted rules.v4 (only rules we manage — a full iptables-save would capture
# KUBE-*/CNI-* chains that fail to restore at boot). At boot, restore APPENDs to the
# still-empty OUTPUT chain, so the bypass lands ahead of kube-proxy's later jump.
PERSIST_BODY="*nat"
if [[ -n "${REGISTRY_HOSTS:-}" ]]; then
  PERSIST_BODY+=$'\n'"-A OUTPUT -d ${MASTER_VLAN_IP_ADDR}/32 -p tcp --dport 443 -j RETURN"
fi
if $NEED_TUNNEL_NAT; then
  for nat_ip in $TUNNEL_NAT_IPS; do
    PERSIST_BODY+=$'\n'"-A OUTPUT -d ${nat_ip}/32 -p tcp --dport 6443 -j DNAT --to-destination ${MASTER_VLAN_IP_ADDR}:6443"
    PERSIST_BODY+=$'\n'"-A OUTPUT -d ${nat_ip}/32 -p udp --dport 8472 -j DNAT --to-destination ${MASTER_VLAN_IP_ADDR}"
  done
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
# (2) tunnel DNAT from each non-Tailscale master address (TUNNEL_NAT_IPS)
if [[ "${NEED_TUNNEL_NAT}" == "true" ]]; then
  iptables -t nat -S OUTPUT | grep -E -- '--dport (6443|8472) .*DNAT' | grep -v -- "--to-destination ${MASTER_VLAN_IP_ADDR}" | sed 's/^-A //' | while read -r r; do iptables -t nat -D \$r; echo TUNNEL_CHANGED; done
  addt() { local src=\$1 proto=\$2 dport=\$3 dnat=\$4
    if ! iptables -t nat -C OUTPUT -d \$src -p \$proto --dport \$dport -j DNAT --to-destination ${MASTER_VLAN_IP_ADDR}\$dnat 2>/dev/null; then
      iptables -t nat -A OUTPUT -d \$src -p \$proto --dport \$dport -j DNAT --to-destination ${MASTER_VLAN_IP_ADDR}\$dnat; echo TUNNEL_CHANGED; fi
    if ! iptables -t nat -C POSTROUTING -d ${MASTER_VLAN_IP_ADDR} -p \$proto --dport \$dport -o tailscale0 -j MASQUERADE 2>/dev/null; then
      iptables -t nat -A POSTROUTING -d ${MASTER_VLAN_IP_ADDR} -p \$proto --dport \$dport -o tailscale0 -j MASQUERADE; echo TUNNEL_CHANGED; fi
  }
  for src in ${TUNNEL_NAT_IPS}; do
    addt \$src tcp 6443 :6443
    addt \$src udp 8472 ""
  done
fi
# Persist across reboots. On Ubuntu, installing iptables-persistent removes ufw (the host
# firewall of e.g. a cloud tenant node): where ufw is installed and iptables-persistent is
# not, a oneshot unit restores only these rules (appended, before k3s-agent) instead.
mkdir -p /etc/iptables
if dpkg -s ufw >/dev/null 2>&1 && ! dpkg -s iptables-persistent >/dev/null 2>&1; then
  cat > /etc/iptables/infra-skills-worker-nat.v4 <<'RULESEOF'
${PERSIST_BODY}
RULESEOF
  cat > /etc/systemd/system/infra-skills-worker-nat.service <<'UNITEOF'
[Unit]
Description=infra-skills join-worker NAT rules (Harbor :443 bypass, k3s tunnel)
After=network-pre.target
Before=k3s-agent.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iptables-restore --noflush /etc/iptables/infra-skills-worker-nat.v4
[Install]
WantedBy=multi-user.target
UNITEOF
  systemctl daemon-reload
  systemctl enable infra-skills-worker-nat.service >/dev/null 2>&1
else
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
fi
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

# --- Tenant label (admin only: NodeRestriction keeps the kubelet off this prefix) ---
if [[ -n "$TENANT" ]]; then
  kubectl label node "$NODE_NAME" "${TENANT_NODE_LABEL}=${TENANT}" --overwrite >/dev/null
  ok "Label ${TENANT_NODE_LABEL}=${TENANT} set"
fi

# --- Quarantine ---
# A node registered with the quarantine taint receives no pod until an admin lifts it. This
# script lifts it only when the node is the one it just set up: its InternalIP is the
# worker's address and, for a tenant node, it carries the tenant taint and label.
NODE_JSON=$(kubectl get node "$NODE_NAME" -o json)
if jq -e --arg q "$QUARANTINE_TAINT" '(.spec.taints // []) | any(.key == $q)' <<<"$NODE_JSON" >/dev/null; then
  NODE_IP_OK=$(jq -r --arg ip "$VLAN_IP_ADDR" '[.status.addresses[]? | select(.type == "InternalIP") | .address] | index($ip) != null' <<<"$NODE_JSON")
  TENANT_OK=true
  if [[ -n "$TENANT" ]]; then
    TENANT_OK=$(jq -r --arg t "$TENANT" --arg tt "$TENANT_TAINT" --arg tl "$TENANT_NODE_LABEL" \
      '((.spec.taints // []) | any(.key == $tt and .value == $t and .effect == "NoExecute")) and ((.metadata.labels // {})[$tl] == $t)' <<<"$NODE_JSON")
  fi
  if $KEEP_QUARANTINE; then
    warn "Node ${NODE_NAME} stays quarantined (--keep-quarantine). Lift it with: kubectl taint node ${NODE_NAME} ${QUARANTINE_TAINT}-"
  elif [[ "$NODE_IP_OK" != true ]]; then
    err "Node ${NODE_NAME} stays quarantined: its InternalIP is not ${VLAN_IP_ADDR}. Check it is the machine you joined:"
    err "  kubectl get node ${NODE_NAME} -o wide"
    exit 1
  elif [[ "$TENANT_OK" != true ]]; then
    err "Node ${NODE_NAME} stays quarantined: it lacks ${TENANT_TAINT}=${TENANT}:NoExecute or ${TENANT_NODE_LABEL}=${TENANT}"
    exit 1
  else
    kubectl taint node "$NODE_NAME" "${QUARANTINE_TAINT}-" >/dev/null
    ok "Quarantine lifted (${NODE_NAME} registered with ${VLAN_IP_ADDR})"
  fi
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
