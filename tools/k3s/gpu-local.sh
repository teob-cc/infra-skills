#!/usr/bin/env bash
set -euo pipefail

# Claim a shared GPU worker for local (off-cluster) dev work, or release it back
# to the cluster. On a box that also runs local GPU workloads (ComfyUI, llama.cpp,
# a render loop) the node's single GPU is shared with cluster Jobs; claiming it
# cordons the node and evicts cluster GPU pods so local work gets the whole card,
# without parking/uninstalling the agent (unlike join-worker.sh --remove).
#
# Mechanism: cordon + drain (NOT a NoExecute taint — the NVIDIA device-plugin
# DaemonSet does not tolerate a custom taint and would be evicted too; drain
# --ignore-daemonsets keeps it running, so the GPU stays advertised and the node
# is reclaimable with a single `release`).
#
# Usage: gpu-local.sh <env> <worker-name> <claim|release|status> [flags]
#   e.g.: gpu-local.sh test gpu-worker claim
#         gpu-local.sh test gpu-worker release
#         gpu-local.sh test gpu-worker status

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
NO_DRAIN=false
DRAIN_TIMEOUT=120
LABEL_KEY="gpu-mode"
ANNO_PREFIX="gpu.teob.cc"

usage() {
  cat <<EOF
Usage: $(basename "$0") <env> <worker-name> <claim|release|status> [flags]

Claim a shared GPU worker for local dev work (cordon + evict cluster GPU pods),
or release it back to the cluster. Keeps the k3s-agent and NVIDIA device-plugin
running throughout (unlike join-worker.sh --remove, which parks the node).

Arguments:
  env           Environment name (e.g. test)
  worker-name   Worker subdirectory under envs/<env>/ (e.g. gpu-worker)
  action        claim   — cordon the node, evict cluster GPU pods, label gpu-mode=localdev
                release — uncordon the node, label gpu-mode=cluster
                status  — show schedulability, gpu-mode label, GPU allocatable, pods

Flags:
  --no-drain       (claim) cordon only — block new cluster pods but let running
                   GPU Jobs finish (use when nothing is running / you don't want
                   to interrupt an in-flight render)
  --timeout SEC    drain timeout in seconds (default: ${DRAIN_TIMEOUT})
  -h, --help       Show this help
EOF
  exit 0
}

# --- Parse arguments ---
ENV_ARG=""; WORKER_ARG=""; ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-drain)  NO_DRAIN=true; shift ;;
    --timeout)   DRAIN_TIMEOUT="$2"; shift 2 ;;
    -h|--help)   usage ;;
    -*)          err "Unknown flag: $1"; usage ;;
    *)
      if [[ -z "$ENV_ARG" ]]; then ENV_ARG="$1"
      elif [[ -z "$WORKER_ARG" ]]; then WORKER_ARG="$1"
      elif [[ -z "$ACTION" ]]; then ACTION="$1"
      else err "Unexpected argument: $1"; usage; fi
      shift ;;
  esac
done

if [[ -z "$ENV_ARG" || -z "$WORKER_ARG" || -z "$ACTION" ]]; then
  err "<env>, <worker-name> and <action> are all required."
  usage
fi
case "$ACTION" in
  claim|release|status) ;;
  *) err "Unknown action: ${ACTION} (expected claim|release|status)"; usage ;;
esac

provision::require_tools kubectl

# --- Load environment (for the node name) ---
ENV_ROOT="$(provision::envs_root)"
ENV_FILE="${ENV_ROOT}/${ENV_ARG}/${WORKER_ARG}/env.properties"
if [[ ! -f "$ENV_FILE" ]]; then
  err "Environment file not found: ${ENV_FILE}"
  exit 1
fi
NODE_NAME="${WORKER_ARG//_/-}"

# --- Target the env's cluster ---
KUBECONFIG_FILE="$(provision::ensure_kubeconfig "${ENV_ARG}")" || exit 1
export KUBECONFIG="$KUBECONFIG_FILE"

if ! kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
  err "Node ${NODE_NAME} not found in ${ENV_ARG} cluster. Is it joined? (join-worker.sh ${ENV_ARG} ${WORKER_ARG})"
  exit 1
fi

print_status() {
  local unsched mode gpu_alloc
  unsched=$(kubectl get node "$NODE_NAME" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)
  mode=$(kubectl get node "$NODE_NAME" -o jsonpath="{.metadata.labels.${LABEL_KEY}}" 2>/dev/null)
  gpu_alloc=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
  info "Node ${NODE_NAME}: schedulable=$([[ "$unsched" == "true" ]] && echo 'NO (cordoned)' || echo yes)  ${LABEL_KEY}=${mode:-<unset>}  nvidia.com/gpu alloc=${gpu_alloc:-0}"
  # jsonpath reads a dot as a path separator, so the dots of the annotation prefix must be
  # escaped; unescaped, both lookups return nothing and the claim is never shown.
  local claimed_by claimed_at anno_path="${ANNO_PREFIX//./\\.}"
  claimed_by=$(kubectl get node "$NODE_NAME" -o jsonpath="{.metadata.annotations.${anno_path}/claimed-by}" 2>/dev/null)
  claimed_at=$(kubectl get node "$NODE_NAME" -o jsonpath="{.metadata.annotations.${anno_path}/claimed-at}" 2>/dev/null)
  [[ -n "$claimed_by" ]] && info "  claimed-by=${claimed_by} claimed-at=${claimed_at}"
  info "  non-daemonset pods on node:"
  kubectl get pods -A --field-selector "spec.nodeName=${NODE_NAME}" \
    -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,OWNER:.metadata.ownerReferences[0].kind' 2>/dev/null \
    | awk 'NR==1 || $3!="DaemonSet"' >&2
}

case "$ACTION" in
  status)
    print_status
    exit 0
    ;;

  claim)
    info "Claiming ${NODE_NAME} for local dev work..."
    kubectl cordon "$NODE_NAME" >&2
    ok "Cordoned (no new cluster pods will schedule here)"
    if $NO_DRAIN; then
      warn "--no-drain: leaving running pods in place (they keep using the GPU until they finish)"
    else
      info "Evicting cluster pods (daemonsets kept)..."
      if kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data \
           --timeout="${DRAIN_TIMEOUT}s" >&2; then
        ok "Drained — cluster GPU workloads evicted, device-plugin kept running"
      else
        warn "Drain did not complete within ${DRAIN_TIMEOUT}s (a pod may be slow to terminate)."
        warn "Node stays cordoned; re-run claim or check: kubectl get pods -A --field-selector spec.nodeName=${NODE_NAME}"
      fi
    fi
    kubectl label node "$NODE_NAME" "${LABEL_KEY}=localdev" --overwrite >&2
    kubectl annotate node "$NODE_NAME" \
      "${ANNO_PREFIX}/claimed-by=${USER:-unknown}@$(hostname -s 2>/dev/null || echo host)" \
      "${ANNO_PREFIX}/claimed-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite >&2
    ok "Node ${NODE_NAME} is yours. The GPU is free for local ComfyUI/llama/render work."
    info "Release it when done:  $(basename "$0") ${ENV_ARG} ${WORKER_ARG} release"
    print_status
    ;;

  release)
    info "Releasing ${NODE_NAME} back to the cluster..."
    kubectl uncordon "$NODE_NAME" >&2
    kubectl label node "$NODE_NAME" "${LABEL_KEY}=cluster" --overwrite >&2
    kubectl annotate node "$NODE_NAME" \
      "${ANNO_PREFIX}/claimed-by-" "${ANNO_PREFIX}/claimed-at-" >/dev/null 2>&1 || true
    ok "Node ${NODE_NAME} is back in the cluster GPU pool."
    print_status
    ;;
esac
