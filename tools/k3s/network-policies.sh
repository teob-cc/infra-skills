#!/usr/bin/env bash
set -euo pipefail
# ============================================================================
# network-policies — NetworkPolicies for the platform namespaces (INFRA-56)
# ============================================================================
# Fences the platform namespaces with NetworkPolicies, enforced by the kube-router
# controller that k3s embeds:
#
#   * CI runners (ARC runner pods, actions-runner-system): EGRESS allow-list. Runners run
#     arbitrary code next to a privileged dind, so they may reach only
#       - cluster DNS (kube-dns pods, 53/udp+tcp);
#       - the ingress controller (Traefik and its k3s servicelb pods), i.e. Harbor, Nexus
#         and every other public hostname of this cluster, through Traefik;
#       - the node's public IP on 80/443;
#       - the internet: 0.0.0.0/0 except the pod and service CIDRs, RFC 1918, CGNAT
#         100.64.0.0/10 (Tailscale), link-local 169.254.0.0/16 (cloud metadata), loopback,
#         and every node address.
#     So no cluster-internal Service, no kube API, no node-local port, no tailnet.
#   * every platform namespace: default-deny INGRESS, then explicit allows from
#       - the same namespace (ArgoCD -> repo-server/redis, Harbor internals, ...);
#       - Traefik (kube-system), for Ingress backends and ACME http01 solver pods;
#       - Pomerium (sso), for the routes it proxies;
#       - Prometheus (observability), for scraping;
#       - the nodes, where admission webhooks live (cert-manager, CNPG, ARC): the API
#         server calls them from the host network;
#       - plus per-namespace extras: Postgres clients on 5432 and the CNPG operator
#         (postgres), S3 clients on 9000 (minio).
#
# How kube-router treats host-network sources: it ACCEPTs any packet whose source address
# is local to the pod's node (iptables `-m addrtype --src-type LOCAL`), before the policy
# rules. Kubelet probes and the API server -> webhook calls on the same node therefore
# always pass. On a multi-node cluster the API server reaches a webhook pod on another node
# from its node IP or, over flannel vxlan, from its flannel.1/cni0 address (the first two
# addresses of its podCIDR); platform-allow-from-nodes lists exactly those as ipBlocks.
# kube-router evaluates egress after DNAT, so a ClusterIP is checked as the backend pod
# IP: denying the pod CIDR is what keeps runners off cluster Services.
#
# Pods that already carry their own narrower ingress fence (pgweb-from-pomerium-only,
# mcp-grafana-from-pomerium-only) are left out of the allow policies here, because
# NetworkPolicies add up and a namespace-wide allow would widen theirs.
#
# Everything is derived from the cluster and env.properties: node addresses and podCIDRs,
# the service CIDR (ServiceCIDR object, else --service-cidr in k3s node-args, else the k3s
# default), the cluster CIDR (--cluster-cidr in node-args, else the k3s default, checked
# against every node podCIDR), EXTERNAL_IP, Traefik's target ports. Namespaces that do
# not exist are skipped, so the step can run before optional components are installed;
# re-run it after adding one.
#
# Usage:
#   tools/k3s/network-policies.sh <env-name> [options]
#
# Options:
#   (none)             print the plan (kubectl diff + stale policies), then apply it
#   --plan             print the plan only; change nothing
#   --dry-run=server   send the rendered policies to the API server as a server-side dry
#                      run (admission + validation); change nothing
#   --print            print the rendered policies (JSON List) to stdout and exit
#   --remove           delete every policy this script manages (rollback); combine with
#                      --plan or --dry-run=server to preview
#   --only <ns,...>    limit to these namespaces
#   --skip <ns,...>    leave these namespaces out
#   -h, --help         show this help
#
# Environment (all optional; env.properties may set them):
#   NETPOL_SKIP_NAMESPACES       space/comma list, same as --skip
#   NETPOL_RUNNER_EGRESS_DENY    extra CIDRs runners must not reach (e.g. your other servers)
#   NAMESPACE_RUNNER, NAMESPACE_HARBOR, NAMESPACE_OBSERVABILITY, NAMESPACE_ARGOCD,
#   NAMESPACE_SSO, NAMESPACE_CERT_MANAGER, NAMESPACE_NEXUS, NAMESPACE_MINIO,
#   CNPG_NAMESPACE, NAMESPACE_POSTGRES   the namespace names the other scripts use
#
# Policies carry app.kubernetes.io/managed-by=infra-skills-network-policies and are
# applied server-side under the field manager of the same name. A managed policy that the
# current render no longer contains is deleted on apply.
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

usage() { sed -n '/^# Usage:/,/^# Policies carry/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d' >&2; }

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
if [[ -z "${1:-}" ]]; then usage; exit 1; fi
if provision::load_env "${1:-}"; then
  shift
else
  provision::error "Environment '$1' not found (envs/$1/env.properties missing under $(provision::envs_root))."
  exit 1
fi

MODE=apply
REMOVE=false
ONLY=""
SKIP="${NETPOL_SKIP_NAMESPACES:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan|--diff) MODE=plan; shift ;;
    --dry-run=server) MODE=dry-run; shift ;;
    --dry-run) provision::error "use --dry-run=server"; exit 1 ;;
    --print) MODE=print; shift ;;
    --remove) REMOVE=true; shift ;;
    --only) ONLY="${2:?--only needs a namespace list}"; shift 2 ;;
    --skip) SKIP="${SKIP} ${2:?--skip needs a namespace list}"; shift 2 ;;
    *) provision::error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || { provision::error "kubectl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { provision::error "jq not found"; exit 1; }
provision::validate_kubectl_context

log() { echo "[netpol] $*" >&2; }

MANAGER="infra-skills-network-policies"
SELECTOR="app.kubernetes.io/managed-by=${MANAGER}"

NS_RUNNER="${NAMESPACE_RUNNER:-actions-runner-system}"
NS_HARBOR="${NAMESPACE_HARBOR:-harbor}"
NS_OBS="${NAMESPACE_OBSERVABILITY:-observability}"
NS_ARGOCD="${NAMESPACE_ARGOCD:-argocd}"
NS_SSO="${NAMESPACE_SSO:-sso}"
NS_CERT="${NAMESPACE_CERT_MANAGER:-cert-manager}"
NS_NEXUS="${NAMESPACE_NEXUS:-nexus}"
NS_MINIO="${NAMESPACE_MINIO:-minio}"
NS_CNPG="${CNPG_NAMESPACE:-cnpg-system}"
NS_POSTGRES="${NAMESPACE_POSTGRES:-postgres}"
NS_INGRESS=kube-system

# --- IPv4 helpers -------------------------------------------------------------
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
ip2int() { local IFS=.; local a b c d; read -r a b c d <<<"$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
int2ip() { local n=$1; echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"; }
mask() { local len=$1; (( len == 0 )) && { echo 0; return; }; echo $(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF )); }
# cidr_contains <outer-cidr> <inner-cidr-or-ip>
cidr_contains() {
  local o=$1 i=$2 olen ilen m
  olen=${o#*/}; [[ "$i" == */* ]] && ilen=${i#*/} || ilen=32
  (( ilen >= olen )) || return 1
  m=$(mask "$olen")
  (( ($(ip2int "${o%/*}") & m) == ($(ip2int "${i%/*}") & m) ))
}
# first two addresses of a podCIDR (flannel.1 = .0, cni0 = .1) as a /31
gateway_block() { local c=$1 m; m=$(mask "${c#*/}"); echo "$(int2ip $(( $(ip2int "${c%/*}") & m )))/31"; }

# --- Discover the cluster -----------------------------------------------------
NODES_JSON=$(kubectl get nodes -o json)
NODE_IPS=()      # every IPv4 node address
while read -r ip; do [[ -n "$ip" ]] && is_ipv4 "$ip" && NODE_IPS+=("$ip"); done < <(
  jq -r '.items[].status.addresses[] | select(.type=="InternalIP" or .type=="ExternalIP") | .address' <<<"$NODES_JSON")
PUBLIC_IPS=()    # node addresses Traefik answers on publicly
while read -r ip; do [[ -n "$ip" ]] && is_ipv4 "$ip" && PUBLIC_IPS+=("$ip"); done < <(
  { jq -r '.items[].status.addresses[] | select(.type=="ExternalIP") | .address' <<<"$NODES_JSON"; echo "${EXTERNAL_IP:-}"; } | sort -u)
for ip in ${PUBLIC_IPS[@]+"${PUBLIC_IPS[@]}"}; do
  [[ " ${NODE_IPS[*]-} " == *" $ip "* ]] || NODE_IPS+=("$ip")
done
POD_CIDRS=()
while read -r c; do [[ "$c" == */* ]] && is_ipv4 "${c%/*}" && POD_CIDRS+=("$c"); done < <(
  jq -r '.items[] | (.spec.podCIDRs // [.spec.podCIDR]) | .[]? // empty' <<<"$NODES_JSON")
node_arg() { # node_arg <flag> -> value of --flag (either "--flag v" or "--flag=v") in any node's k3s.io/node-args
  jq -r --arg f "--$1" '.items[].metadata.annotations["k3s.io/node-args"] // "[]" | fromjson
    | . as $a | range(0; length) as $i
    | if $a[$i] == $f then $a[$i + 1] elif ($a[$i] | startswith($f + "=")) then ($a[$i] | ltrimstr($f + "=")) else empty end' \
    <<<"$NODES_JSON" | head -1
}
CLUSTER_CIDR=$(node_arg cluster-cidr | tr ',' '\n' | grep -E '^[0-9.]+/[0-9]+$' | head -1 || true)
CLUSTER_CIDR="${CLUSTER_CIDR:-10.42.0.0/16}"
SERVICE_CIDR=$(kubectl get servicecidrs.networking.k8s.io kubernetes -o json 2>/dev/null \
  | jq -r '.spec.cidrs[]? | select(test("^[0-9.]+/[0-9]+$"))' | head -1 || true)
[[ -n "$SERVICE_CIDR" ]] || SERVICE_CIDR=$(node_arg service-cidr | tr ',' '\n' | grep -E '^[0-9.]+/[0-9]+$' | head -1 || true)
SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"

(( ${#NODE_IPS[@]} > 0 )) || { provision::error "no IPv4 node address found"; exit 1; }
(( ${#POD_CIDRS[@]} > 0 )) || { provision::error "no node podCIDR found (is this a k3s/flannel cluster?)"; exit 1; }
for c in "${POD_CIDRS[@]}"; do
  cidr_contains "$CLUSTER_CIDR" "$c" || {
    provision::error "node podCIDR $c is outside the cluster CIDR $CLUSTER_CIDR; set --cluster-cidr in the k3s config or fix the node."
    exit 1; }
done
kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null | {
  read -r kip || true
  if [[ -n "${kip:-}" ]] && ! cidr_contains "$SERVICE_CIDR" "$kip"; then
    provision::error "kubernetes Service IP $kip is outside the service CIDR $SERVICE_CIDR"; exit 1
  fi
}

# Traefik target ports (the Service maps 80/443 to the pod's web/websecure ports).
TRAEFIK_PORTS=$(kubectl -n "$NS_INGRESS" get svc traefik -o json 2>/dev/null | jq -r '.spec.ports[]?.targetPort' || true)
TRAEFIK_POD=$(kubectl -n "$NS_INGRESS" get pods -l app.kubernetes.io/name=traefik -o json 2>/dev/null || echo '{"items":[]}')
TRAEFIK_TARGETS=()
for p in $TRAEFIK_PORTS; do
  if [[ "$p" =~ ^[0-9]+$ ]]; then TRAEFIK_TARGETS+=("$p"); continue; fi
  n=$(jq -r --arg p "$p" '[.items[].spec.containers[].ports[]? | select(.name == $p) | .containerPort][0] // empty' <<<"$TRAEFIK_POD")
  [[ -n "$n" ]] && TRAEFIK_TARGETS+=("$n")
done
(( ${#TRAEFIK_TARGETS[@]} > 0 )) || { log "Traefik ports not found; assuming 8000/8443"; TRAEFIK_TARGETS=(8000 8443); }
TRAEFIK_TARGETS=($(printf '%s\n' "${TRAEFIK_TARGETS[@]}" | sort -un))

NODE_SOURCES=()  # where host-network clients (API server, kubelet) come from
for ip in "${NODE_IPS[@]}"; do NODE_SOURCES+=("$ip/32"); done
for c in "${POD_CIDRS[@]}"; do NODE_SOURCES+=("$(gateway_block "$c")"); done

DENY_RANGES=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 127.0.0.0/8)
RUNNER_EXCEPT=("${DENY_RANGES[@]}")
add_except() {
  local c=$1 r
  for r in "${RUNNER_EXCEPT[@]}"; do cidr_contains "$r" "$c" && return 0; done
  RUNNER_EXCEPT+=("$c")
}
add_except "$CLUSTER_CIDR"
add_except "$SERVICE_CIDR"
for ip in "${NODE_IPS[@]}"; do add_except "$ip/32"; done
for c in ${NETPOL_RUNNER_EGRESS_DENY//,/ }; do
  [[ "$c" == */* ]] || c="$c/32"
  is_ipv4 "${c%/*}" || { provision::error "NETPOL_RUNNER_EGRESS_DENY: not an IPv4 CIDR: $c"; exit 1; }
  add_except "$c"
done

log "env ${ENV_NAME}: nodes ${NODE_IPS[*]}; public ${PUBLIC_IPS[*]:-none}"
log "cluster CIDR ${CLUSTER_CIDR}, service CIDR ${SERVICE_CIDR}, node podCIDRs ${POD_CIDRS[*]}"
log "Traefik target ports ${TRAEFIK_TARGETS[*]}"

# --- Namespace selection ------------------------------------------------------
in_list() { local x=$1; shift; local l=" ${*//,/ } "; [[ "$l" == *" $x "* ]]; }
ALL_NS=("$NS_RUNNER" "$NS_HARBOR" "$NS_OBS" "$NS_ARGOCD" "$NS_SSO" "$NS_CERT" "$NS_NEXUS" "$NS_MINIO" "$NS_CNPG" "$NS_POSTGRES")
EXISTING_NS=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')
TARGET_NS=()
for ns in "${ALL_NS[@]}"; do
  [[ -n "$ONLY" ]] && ! in_list "$ns" "$ONLY" && continue
  [[ -n "${SKIP// /}" ]] && in_list "$ns" "$SKIP" && { log "skip ${ns} (--skip)"; continue; }
  in_list "$ns" "$EXISTING_NS" || { log "skip ${ns} (namespace does not exist)"; continue; }
  TARGET_NS+=("$ns")
done

# --- Render -------------------------------------------------------------------
json_arr() { printf '%s\n' "$@" | jq -R . | jq -sc .; }
NODE_SOURCES_J=$(json_arr "${NODE_SOURCES[@]}")
RUNNER_EXCEPT_J=$(json_arr "${RUNNER_EXCEPT[@]}")
PUBLIC_J='[]'
(( ${#PUBLIC_IPS[@]} > 0 )) && PUBLIC_J=$(json_arr "${PUBLIC_IPS[@]/%//32}")
TRAEFIK_PORTS_J=$(printf '%s\n' "${TRAEFIK_TARGETS[@]}" | jq -sc 'map({port: tonumber, protocol: "TCP"})')

# policy <ns> <name> <purpose> <spec-json>
policy() {
  jq -nc --arg ns "$1" --arg name "$2" --arg why "$3" --arg mgr "$MANAGER" --argjson spec "$4" '{
    apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy",
    metadata: {name: $name, namespace: $ns,
               labels: {"app.kubernetes.io/managed-by": $mgr, "app.kubernetes.io/part-of": "platform-network-policies"},
               annotations: {"infra-skills/purpose": $why}},
    spec: $spec}'
}
from_ns_pods() { # from_ns_pods <ns> <k=v> -> a NetworkPolicyPeer
  jq -nc --arg ns "$1" --arg k "${2%%=*}" --arg v "${2#*=}" \
    '{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": $ns}}, podSelector: {matchLabels: {($k): $v}}}'
}
# Pods with their own narrower fence are left out of the namespace-wide allows.
exclusions() {
  case "$1" in
    "$NS_OBS") echo '["mcp-grafana"]' ;;
    "$NS_POSTGRES") echo '["pgweb"]' ;;
    *) echo '[]' ;;
  esac
}
target_pods() { # podSelector for the allow policies of <ns>
  local ex; ex=$(exclusions "$1")
  jq -nc --argjson ex "$ex" 'if ($ex | length) == 0 then {} else {matchExpressions: [{key: "app", operator: "NotIn", values: $ex}]} end'
}
needs_node_sources() { in_list "$1" "$NS_RUNNER $NS_CERT $NS_CNPG"; }

TRAEFIK_PEER=$(from_ns_pods "$NS_INGRESS" app.kubernetes.io/name=traefik)
POMERIUM_PEER=$(from_ns_pods "$NS_SSO" app.kubernetes.io/name=pomerium)
PROMETHEUS_PEER=$(from_ns_pods "$NS_OBS" app.kubernetes.io/name=prometheus)

render_ns() {
  local ns=$1 sel
  sel=$(target_pods "$ns")
  policy "$ns" platform-default-deny-ingress "deny all ingress that no other policy allows" \
    '{"podSelector": {}, "policyTypes": ["Ingress"]}'
  policy "$ns" platform-allow-same-namespace "pods of this namespace talk to each other" \
    "$(jq -nc --argjson s "$sel" '{podSelector: $s, policyTypes: ["Ingress"], ingress: [{from: [{podSelector: {}}]}]}')"
  policy "$ns" platform-allow-from-prometheus "Prometheus scrapes metrics" \
    "$(jq -nc --argjson s "$sel" --argjson p "$PROMETHEUS_PEER" '{podSelector: $s, policyTypes: ["Ingress"], ingress: [{from: [$p]}]}')"
  if needs_node_sources "$ns"; then
    policy "$ns" platform-allow-from-nodes "API server -> admission webhooks, from the host network of any node" \
      "$(jq -nc --argjson c "$NODE_SOURCES_J" '{podSelector: {}, policyTypes: ["Ingress"], ingress: [{from: ($c | map({ipBlock: {cidr: .}}))}]}')"
  fi
  if [[ "$ns" == "$NS_RUNNER" ]]; then
    render_runner_egress "$ns"
    return
  fi
  policy "$ns" platform-allow-from-ingress-controller "Traefik -> Ingress backends and ACME solver pods" \
    "$(jq -nc --argjson s "$sel" --argjson p "$TRAEFIK_PEER" '{podSelector: $s, policyTypes: ["Ingress"], ingress: [{from: [$p]}]}')"
  policy "$ns" platform-allow-from-pomerium "Pomerium -> the backends it proxies" \
    "$(jq -nc --argjson s "$sel" --argjson p "$POMERIUM_PEER" '{podSelector: $s, policyTypes: ["Ingress"], ingress: [{from: [$p]}]}')"
  case "$ns" in
    "$NS_POSTGRES")
      policy "$ns" platform-allow-postgres-clients "apps in any namespace -> CNPG instances/poolers on 5432; CNPG operator -> instances" \
        "$(jq -nc --argjson op "$(from_ns_pods "$NS_CNPG" app.kubernetes.io/name=cloudnative-pg)" '{
          podSelector: {matchExpressions: [{key: "cnpg.io/podRole", operator: "In", values: ["instance", "pooler"]}]},
          policyTypes: ["Ingress"],
          ingress: [{from: [{namespaceSelector: {}}], ports: [{port: 5432, protocol: "TCP"}]}, {from: [$op]}]}')"
      ;;
    "$NS_MINIO")
      policy "$ns" platform-allow-s3-clients "apps in any namespace -> the S3 API on 9000" \
        "$(jq -nc '{podSelector: {matchLabels: {app: "minio"}}, policyTypes: ["Ingress"], ingress: [{from: [{namespaceSelector: {}}], ports: [{port: 9000, protocol: "TCP"}]}]}')"
      ;;
  esac
}

render_runner_egress() {
  local ns=$1
  policy "$ns" platform-runner-egress "CI runners: DNS, Traefik (Harbor/Nexus by public hostname) and the internet only" \
    "$(jq -nc --argjson except "$RUNNER_EXCEPT_J" --argjson pub "$PUBLIC_J" --argjson tp "$TRAEFIK_PORTS_J" \
        --arg ing "$NS_INGRESS" '{
      podSelector: {matchExpressions: [{key: "actions-runner", operator: "Exists"}]},
      policyTypes: ["Egress"],
      egress: ([
        {to: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": $ing}}, podSelector: {matchLabels: {"k8s-app": "kube-dns"}}}],
         ports: [{port: 53, protocol: "UDP"}, {port: 53, protocol: "TCP"}]},
        {to: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": $ing}}, podSelector: {matchLabels: {"app.kubernetes.io/name": "traefik"}}}],
         ports: $tp},
        {to: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": $ing}}, podSelector: {matchLabels: {"svccontroller.k3s.cattle.io/svcname": "traefik"}}}],
         ports: [{port: 80, protocol: "TCP"}, {port: 443, protocol: "TCP"}]}
      ] + (if ($pub | length) > 0 then [{to: ($pub | map({ipBlock: {cidr: .}})), ports: [{port: 80, protocol: "TCP"}, {port: 443, protocol: "TCP"}]}] else [] end)
        + [{to: [{ipBlock: {cidr: "0.0.0.0/0", except: $except}}]}])}')"
}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/netpol.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
RENDERED="$TMPD/policies.json"
{
  if [[ "$REMOVE" != true ]]; then
    for ns in ${TARGET_NS[@]+"${TARGET_NS[@]}"}; do render_ns "$ns"; done
  fi
} | jq -s '{apiVersion: "v1", kind: "List", items: .}' >"$RENDERED"
COUNT=$(jq '.items | length' "$RENDERED")

if [[ "$MODE" == print ]]; then cat "$RENDERED"; exit 0; fi

# Managed policies that the render no longer contains (all of them with --remove).
STALE=$(kubectl get networkpolicy -A -l "$SELECTOR" -o json | jq -r --slurpfile r "$RENDERED" \
  --arg only "${ONLY//,/ }" --arg skip "${SKIP//,/ }" '
  ($r[0].items | map(.metadata.namespace + "/" + .metadata.name)) as $want
  | ($only | split(" ") | map(select(. != ""))) as $o | ($skip | split(" ") | map(select(. != ""))) as $s
  | .items[] | .metadata.namespace as $ns
  | select(($o | length) == 0 or ($o | index($ns)))
  | select(($s | index($ns)) | not)
  | "\($ns)/\(.metadata.name)" | select(. as $k | $want | index($k) | not)')

# --- Plan ----------------------------------------------------------------------
log "plan: ${COUNT} policies in ${#TARGET_NS[@]} namespaces (${TARGET_NS[*]:-none})"
if (( COUNT > 0 )); then
  set +e
  kubectl diff --server-side --field-manager="$MANAGER" -f "$RENDERED"
  rc=$?
  set -e
  case $rc in
    0) log "no changes to apply" ;;
    1) : ;;
    *) provision::error "kubectl diff failed (rc=$rc)"; exit "$rc" ;;
  esac
fi
if [[ -n "$STALE" ]]; then
  log "would delete (managed, no longer rendered):"
  sed 's/^/  - /' <<<"$STALE" >&2
fi

case "$MODE" in
  plan) exit 0 ;;
  dry-run)
    (( COUNT > 0 )) && kubectl apply --server-side --field-manager="$MANAGER" --dry-run=server -f "$RENDERED"
    while read -r k; do
      [[ -n "$k" ]] && kubectl -n "${k%%/*}" delete networkpolicy "${k#*/}" --dry-run=server
    done <<<"$STALE"
    log "server-side dry run passed; nothing changed"
    exit 0 ;;
esac

# --- Apply ---------------------------------------------------------------------
(( COUNT > 0 )) && kubectl apply --server-side --field-manager="$MANAGER" -f "$RENDERED"
while read -r k; do
  [[ -n "$k" ]] && kubectl -n "${k%%/*}" delete networkpolicy "${k#*/}" --ignore-not-found
done <<<"$STALE"
log "applied. Probe the protected apps now; to roll back: $0 ${ENV_NAME} --remove"
