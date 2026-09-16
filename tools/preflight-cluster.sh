#!/usr/bin/env bash
# ============================================================================
# preflight-cluster — read-only checks between "server is up" and "apply the stack"
# ============================================================================
# validate-keys.sh runs before the server exists; doctor.sh runs after the stack is up.
# This covers the gap: the things that made real stack applies fail or stall.
#   FAIL (exit 1): kubectl context mismatch, node not Ready
#   WARN (exit 0): DNS not pointing at EXTERNAL_IP, 443 closed, wildcard missing,
#                  runner dockerMTU != pod MTU, Tailscale node not seen recently
# Usage: tools/preflight-cluster.sh <env>
# shellcheck disable=SC1091
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/tools/provision-common.sh"
[[ -n "${1:-}" ]] || { echo "Usage: $0 <env>" >&2; exit 2; }
provision::load_env "$1" || { provision::error "Environment '$1' not found"; exit 2; }

FAILS=0; WARNS=0
ok()   { printf '  [OK  ] %-12s %s\n' "$1" "$2"; }
warn() { printf '  [WARN] %-12s %s\n' "$1" "$2"; [[ -n "${3:-}" ]] && printf '         └─ %s\n' "$3"; WARNS=$((WARNS+1)); }
fail() { printf '  [FAIL] %-12s %s\n' "$1" "$2"; [[ -n "${3:-}" ]] && printf '         └─ %s\n' "$3"; FAILS=$((FAILS+1)); }
kc() { kubectl --request-timeout=15s "$@" 2>/dev/null; }

echo "  preflight-cluster — ${ENV_NAME}  (read-only; nothing is changed)"
echo "  ================================================================"

# context
if provision::validate_kubectl_context >/dev/null 2>&1; then
  ok "context" "kubectl context matches ${ENV_NAME}"
else
  fail "context" "kubectl context does not match ${ENV_NAME}" "kubectl config use-context ${ENV_NAME} (envs/${ENV_NAME}/kubeconfig.yaml)"
fi

# API reachable at all? Over Tailscale, the usual cause is the operator's own client being
# stopped -- everything else on the platform is fine in that case.
if ! kubectl --request-timeout=10s get --raw='/livez' >/dev/null 2>&1; then
  api="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  fail "api" "Kubernetes API ${api} unreachable" "is your Tailscale client connected? (tailscale status); then ssh over Tailscale and check systemctl status k3s"
  echo "  ================================================================"
  echo "  ${WARNS} warning(s), ${FAILS} failure(s)."
  exit 1
fi

# node
ready=$(kc get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c True)
total=$(kc get nodes --no-headers | wc -l | tr -d ' ')
if [[ "${total:-0}" -gt 0 && "$ready" -eq "$total" ]]; then ok "node" "${ready}/${total} Ready ($(kc get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'))"
else fail "node" "${ready}/${total:-0} nodes Ready" "ssh to the node over Tailscale; systemctl status k3s"; fi

# DNS + 443
if [[ -n "${EXTERNAL_IP:-}" ]]; then
  a=$(dig +short "$HOSTNAME" A 2>/dev/null | tail -1)
  w=$(dig +short "preflight-probe.${HOSTNAME}" A 2>/dev/null | tail -1)
  [[ "$a" == "$EXTERNAL_IP" ]] && ok "dns" "${HOSTNAME} -> ${a}" || warn "dns" "${HOSTNAME} resolves to '${a:-nothing}', expected ${EXTERNAL_IP}" "the server script creates the records; propagation can lag a few minutes"
  [[ "$w" == "$EXTERNAL_IP" ]] && ok "dns-wild" "*.${HOSTNAME} -> ${w}" || warn "dns-wild" "*.${HOSTNAME} resolves to '${w:-nothing}'" "every service host depends on the wildcard record"
  if nc -z -w 5 "$EXTERNAL_IP" 443 >/dev/null 2>&1; then ok "port-443" "${EXTERNAL_IP}:443 reachable"
  else warn "port-443" "${EXTERNAL_IP}:443 not reachable" "UFW should allow 443/tcp; Traefik must be running"; fi
fi

# pod MTU vs runner dockerMTU
probe="preflight-mtu-$$"
kc run "$probe" -n default --restart=Never --image=busybox:1.36 --command -- cat /sys/class/net/eth0/mtu >/dev/null
kc wait -n default --for=jsonpath='{.status.phase}'=Succeeded "pod/${probe}" --timeout=90s >/dev/null
pod_mtu=$(kc logs -n default "$probe" | tr -dc '0-9')
kc delete pod -n default "$probe" --ignore-not-found >/dev/null
if [[ "$pod_mtu" =~ ^[0-9]+$ ]]; then
  ok "pod-mtu" "pods see MTU ${pod_mtu}"
  dm=$(kc get runnerdeployment -n actions-runner-system "${ENV_NAME}-runners" -o jsonpath='{.spec.template.spec.dockerMTU}')
  if kc get runnerdeployment -n actions-runner-system "${ENV_NAME}-runners" >/dev/null; then
    if [[ "${dm:-1500}" -le "$pod_mtu" ]]; then ok "runner-mtu" "runner dockerMTU ${dm} <= pod MTU"
    else warn "runner-mtu" "runner dockerMTU ${dm:-unset (1500)} > pod MTU ${pod_mtu}: large downloads in image builds will stall" "kubectl -n actions-runner-system patch runnerdeployment ${ENV_NAME}-runners --type merge -p '{\"spec\":{\"template\":{\"spec\":{\"dockerMTU\":${pod_mtu}}}}}'"; fi
  fi
else
  warn "pod-mtu" "could not probe pod MTU (busybox pull failed?)" ""
fi

# Tailscale node freshness
tsf="$(provision::envs_root)/shared/secrets.plain/tailscale-api-key.txt"
if [[ -f "$tsf" ]]; then
  key=$(head -1 "$tsf" | tr -d '[:space:]')
  seen=$(curl -sS -m 10 -u "${key}:" "https://api.tailscale.com/api/v2/tailnet/-/devices" 2>/dev/null | jq -r --arg h "$HOSTNAME" '.devices[]? | select(.hostname==$h or .name==($h|split(".")|join("-"))) | .lastSeen' 2>/dev/null | head -1)
  if [[ -n "$seen" ]]; then
    se=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$seen" +%s 2>/dev/null || date -u -d "$seen" +%s 2>/dev/null || echo 0)
    age=$(( $(date +%s) - se )); (( age < 0 )) && age=0
    (( age < 600 )) && ok "tailscale" "node ${HOSTNAME} seen ${age}s ago" || warn "tailscale" "node ${HOSTNAME} last seen ${age}s ago" "tailscale status on the node; duplicate devices in the admin console"
  else
    warn "tailscale" "no tailnet device named ${HOSTNAME}" "the server script registers it; check the admin console"
  fi
fi

echo "  ================================================================"
echo "  ${WARNS} warning(s), ${FAILS} failure(s)."
[[ "$FAILS" -eq 0 ]]
