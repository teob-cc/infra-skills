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
#       - the node's public IP on 80/443 (only a public address: an ExternalIP or
#         EXTERNAL_IP inside one of the ranges below stays denied like every node address);
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
#         (postgres), S3 clients on 9000 (minio). Those client allows admit every namespace
#         that is not a tenant's (no infra-skills/tenant label), or only
#         NETPOL_POSTGRES_CLIENT_NAMESPACES / NETPOL_MINIO_CLIENT_NAMESPACES when set. A
#         tenant's namespaces reach only the CNPG poolers labelled infra-skills/tenant=<tenant>,
#         and MinIO only when the tenant is listed in NETPOL_TENANT_MINIO (docs/TENANTS.md).
#   * NETPOL_APP_NAMESPACES (opt-in): application namespaces get the same default-deny ingress
#     and the same allows as a platform namespace (same namespace, Traefik, Pomerium, Prometheus).
#   * a fenced namespace other than the postgres one that runs a CNPG cluster (a Cluster object
#     or pods labelled cnpg.io/cluster): the CNPG operator may reach that cluster's pods on
#     8000 (instance manager status) and 5432, which the CNPG docs require (security.md "Network
#     Policies", networking.md). Re-run the script after creating a CNPG cluster in a fenced namespace.
#
# Tenant workers (ops-owned nodes that run only a tenant's pods, docs/TENANTS.md: label
# node-restriction.kubernetes.io/tenant, taint infra-skills/tenant, or a name <tenant>-* for a
# tenant in TENANTS) are left out of platform-allow-from-nodes and of the public addresses
# runners may reach: a pod that escapes to root there could otherwise reach every webhook and
# platform pod from the host network. Runners stay denied every node address, tenant nodes included.
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
# Pods that already carry their own ingress fence, i.e. pods that a policy not managed here selects
# for ingress (pgweb-from-pomerium-only, mcp-grafana-from-pomerium-only, an app chart's policy),
# are left out of the allow policies here, because NetworkPolicies add up and a namespace-wide
# allow would widen theirs. They stay under the default deny; --plan logs each one. The allows
# select exactly the pods that no fence selects, by labels alone, so a pod created later gets
# them unless a fence selects it: a fence with several labels (A and B) needs one selector per
# label (not A, or not B), so each allow becomes one policy per selector (<name>, <name>-2, ...),
# at most NETPOL_MAX_ALLOW_SELECTORS per namespace. A fence whose podSelector uses NotIn or
# DoesNotExist stops the run. A policy with an empty podSelector is an extra allow, not a fence.
#
# Every cluster read stops the run on an API error (Forbidden, a timeout, a failed discovery),
# before anything is applied or deleted. NotFound from the server reads as absent for three
# reads only, each by name: the CNPG Cluster CRD (then no Cluster objects), the ServiceCIDR
# `kubernetes` and the Service kube-system/traefik (then the fallbacks below).
#
# Everything is derived from the cluster and env.properties: node addresses and podCIDRs,
# the service CIDR (ServiceCIDR object, else --service-cidr in k3s node-args, else the k3s
# default), the cluster CIDR (--cluster-cidr in node-args, else the k3s default, checked
# against every node podCIDR), EXTERNAL_IP, Traefik's target ports (else 8000/8443). Namespaces
# that do not exist are skipped, so the step can run before optional components are installed;
# re-run it after adding one. --remove reads only the managed policies and deletes them.
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
#   NETPOL_APP_NAMESPACES        application namespaces fenced like platform ones
#   NETPOL_POSTGRES_CLIENT_NAMESPACES, NETPOL_MINIO_CLIENT_NAMESPACES
#                                restrict the Postgres / S3 client allows to these namespaces
#   NETPOL_TENANT_MINIO          tenants whose namespaces may reach MinIO on 9000
#   NETPOL_MAX_ALLOW_SELECTORS   most selectors per namespace for the allows around fences (16)
#   TENANTS                      tenant names (tools/k3s/tenant-admission.sh)
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

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/netpol.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
# kget <what> <kubectl args...>: the read's stdout. Any API error (Forbidden, a timeout, ...) stops the
# run, before anything is applied or deleted: a read that silently came back empty would render
# policies for a cluster that is not there.
kget() {
  local what=$1; shift
  if ! kubectl "$@" >"$TMPD/kget.out" 2>"$TMPD/kget.err"; then
    provision::error "could not read ${what}: $(tr '\n' ' ' <"$TMPD/kget.err")"
    provision::error "stopping before anything is applied or deleted"
    exit 1
  fi
  cat "$TMPD/kget.out"
}
# kget_found <what> <kubectl args...>: like kget, but NotFound from the server (one object read by
# name, or a raw path the server does not serve) reads as empty output. Only for reads where absence
# is a valid state. kubectl's "the server doesn't have a resource type" is not NotFound: it also comes
# from a discovery that failed half-way, so it stops the run like any other error.
kget_found() {
  local what=$1; shift
  if ! kubectl "$@" >"$TMPD/kget.out" 2>"$TMPD/kget.err"; then
    grep -qF 'Error from server (NotFound)' "$TMPD/kget.err" && return 0
    provision::error "could not read ${what}: $(tr '\n' ' ' <"$TMPD/kget.err")"
    provision::error "stopping before anything is applied or deleted"
    exit 1
  fi
  cat "$TMPD/kget.out"
}

MANAGER="infra-skills-network-policies"
SELECTOR="app.kubernetes.io/managed-by=${MANAGER}"
EMPTY_LIST='{"apiVersion":"v1","kind":"List","items":[]}'
RENDERED="$TMPD/policies.json"

# managed_stale <rendered file>: "ns/name" of every managed policy in the selected namespaces (--only,
# --skip) that the rendered file does not contain.
managed_stale() {
  local managed
  # set -e does not reach into $(...): stop explicitly
  managed=$(kget "the managed NetworkPolicies" get networkpolicy -A -l "$SELECTOR" -o json) || exit 1
  jq -r --slurpfile r "$1" --arg only "${ONLY//,/ }" --arg skip "${SKIP//,/ }" '
    ($r[0].items | map(.metadata.namespace + "/" + .metadata.name)) as $want
    | ($only | split(" ") | map(select(. != ""))) as $o | ($skip | split(" ") | map(select(. != ""))) as $s
    | .items[] | .metadata.namespace as $ns
    | select(($o | length) == 0 or ($o | index($ns)))
    | select(($s | index($ns)) | not)
    | "\($ns)/\(.metadata.name)" | select(. as $k | $want | index($k) | not)' <<<"$managed"
}
list_policies() { # list_policies <"ns/name" lines>: one "  - ns/name" line each, to stderr
  local k
  while read -r k; do
    if [[ -n "$k" ]]; then echo "  - $k" >&2; fi
  done <<<"$1"
}
delete_policies() { # delete_policies <"ns/name" lines> <kubectl delete flags...>
  local list=$1 k; shift
  while read -r k; do
    if [[ -n "$k" ]]; then kubectl -n "${k%%/*}" delete networkpolicy "${k#*/}" "$@"; fi
  done <<<"$list"
}

# --- Rollback -------------------------------------------------------------------
# --remove depends on nothing but the managed policies: no discovery, no render, no fence checks,
# so a cluster state that would stop a render (a fence selector, a failed CNPG read) cannot block it.
if [[ "$REMOVE" == true ]]; then
  echo "$EMPTY_LIST" >"$RENDERED"
  if [[ "$MODE" == print ]]; then cat "$RENDERED"; exit 0; fi
  STALE=$(managed_stale "$RENDERED")
  if [[ -z "$STALE" ]]; then log "remove: no managed policies${ONLY:+ in $ONLY}"; exit 0; fi
  log "remove: would delete $(grep -c . <<<"$STALE") managed policies:"
  list_policies "$STALE"
  case "$MODE" in
    plan) exit 0 ;;
    dry-run) delete_policies "$STALE" --dry-run=server; log "server-side dry run passed; nothing changed"; exit 0 ;;
  esac
  delete_policies "$STALE" --ignore-not-found
  log "removed. Re-run without --remove to put the policies back."
  exit 0
fi

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
NODES_ALL_JSON=$(kget "the nodes" get nodes -o json)
TENANT_NODE_LABEL="node-restriction.kubernetes.io/tenant"
TENANT_NS_LABEL="infra-skills/tenant"
words_json() { tr ', ' '\n\n' <<<"${1:-}" | sed '/^$/d' | jq -R . | jq -sc .; }
TENANTS_J=$(words_json "${TENANTS:-}")
# shellcheck disable=SC2016  # a jq filter
IS_TENANT='((.metadata.labels // {})[$tl] // "") != "" or ((.spec.taints // []) | any(.key == "infra-skills/tenant"))
  or (.metadata.name as $n | $tenants | any(. as $t | $n | startswith($t + "-")))'
TENANT_NODES_JSON=$(jq -c --arg tl "$TENANT_NODE_LABEL" --argjson tenants "$TENANTS_J" "{items: [.items[] | select($IS_TENANT)]}" <<<"$NODES_ALL_JSON")
NODES_JSON=$(jq -c --arg tl "$TENANT_NODE_LABEL" --argjson tenants "$TENANTS_J" "{items: [.items[] | select(($IS_TENANT) | not)]}" <<<"$NODES_ALL_JSON")
TENANT_NODE_IPS=()  # addresses of tenant nodes: never a source the platform trusts
while read -r ip; do [[ -n "$ip" ]] && is_ipv4 "$ip" && TENANT_NODE_IPS+=("$ip"); done < <(
  jq -r '.items[].status.addresses[]? | select(.type=="InternalIP" or .type=="ExternalIP") | .address' <<<"$TENANT_NODES_JSON")
NODE_IPS=()      # every IPv4 node address
while read -r ip; do [[ -n "$ip" ]] && is_ipv4 "$ip" && NODE_IPS+=("$ip"); done < <(
  jq -r '.items[].status.addresses[] | select(.type=="InternalIP" or .type=="ExternalIP") | .address' <<<"$NODES_JSON")
PUBLIC_IPS=()    # node addresses Traefik answers on publicly
while read -r ip; do [[ -n "$ip" ]] && is_ipv4 "$ip" && PUBLIC_IPS+=("$ip"); done < <(
  { jq -r '.items[].status.addresses[] | select(.type=="ExternalIP") | .address' <<<"$NODES_JSON"; echo "${EXTERNAL_IP:-}"; } | sort -u)
for ip in ${PUBLIC_IPS[@]+"${PUBLIC_IPS[@]}"}; do
  [[ " ${NODE_IPS[*]-} " == *" $ip "* ]] || NODE_IPS+=("$ip")
done
# Ranges runners never reach: RFC 1918, CGNAT (Tailscale), link-local (cloud metadata), loopback.
DENY_RANGES=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 127.0.0.0/8)
in_deny_range() { local r; for r in "${DENY_RANGES[@]}"; do cidr_contains "$r" "$1" && return 0; done; return 1; }
# An ExternalIP in one of those ranges (a LAN worker's address) is not public: runners would reach
# it through the "public IP on 80/443" allow. It stays a node address, denied like the others.
PRIVATE_EXTERNAL=()
PUBLIC_ONLY=()
for ip in ${PUBLIC_IPS[@]+"${PUBLIC_IPS[@]}"}; do
  if in_deny_range "$ip"; then PRIVATE_EXTERNAL+=("$ip"); else PUBLIC_ONLY+=("$ip"); fi
done
PUBLIC_IPS=(${PUBLIC_ONLY[@]+"${PUBLIC_ONLY[@]}"})
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
# The ServiceCIDR object, read by its raw path: no discovery involved, and NotFound means the object (or,
# before Kubernetes 1.33, the API) is not there. Then node-args, then the k3s default.
SERVICE_CIDR_JSON=$(kget_found "the ServiceCIDR kubernetes" get --raw /apis/networking.k8s.io/v1/servicecidrs/kubernetes)
SERVICE_CIDR=$(jq -r '.spec.cidrs[]? | select(test("^[0-9.]+/[0-9]+$"))' <<<"${SERVICE_CIDR_JSON:-null}" | head -1)
[[ -n "$SERVICE_CIDR" ]] || SERVICE_CIDR=$(node_arg service-cidr | tr ',' '\n' | grep -E '^[0-9.]+/[0-9]+$' | head -1 || true)
SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"
[[ -n "$SERVICE_CIDR_JSON" ]] || log "no ServiceCIDR kubernetes (NotFound): service CIDR from k3s node-args or the k3s default"

(( ${#NODE_IPS[@]} > 0 )) || { provision::error "no IPv4 node address found"; exit 1; }
(( ${#POD_CIDRS[@]} > 0 )) || { provision::error "no node podCIDR found (is this a k3s/flannel cluster?)"; exit 1; }
for c in "${POD_CIDRS[@]}"; do
  cidr_contains "$CLUSTER_CIDR" "$c" || {
    provision::error "node podCIDR $c is outside the cluster CIDR $CLUSTER_CIDR; set --cluster-cidr in the k3s config or fix the node."
    exit 1; }
done
KUBERNETES_SVC_IP=$(kget "the kubernetes Service" -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}')
if [[ -n "$KUBERNETES_SVC_IP" ]] && ! cidr_contains "$SERVICE_CIDR" "$KUBERNETES_SVC_IP"; then
  provision::error "kubernetes Service IP $KUBERNETES_SVC_IP is outside the service CIDR $SERVICE_CIDR"; exit 1
fi

# Traefik target ports (the Service maps 80/443 to the pod's web/websecure ports). No traefik Service
# (NotFound): 8000/8443, the k3s chart's ports.
TRAEFIK_SVC=$(kget_found "the Service ${NS_INGRESS}/traefik" -n "$NS_INGRESS" get svc traefik -o json)
TRAEFIK_PORTS=$(jq -r '.spec.ports[]?.targetPort' <<<"${TRAEFIK_SVC:-null}")
TRAEFIK_POD=$(kget "the Traefik pods" -n "$NS_INGRESS" get pods -l app.kubernetes.io/name=traefik -o json)
TRAEFIK_TARGETS=()
for p in $TRAEFIK_PORTS; do
  if [[ "$p" =~ ^[0-9]+$ ]]; then TRAEFIK_TARGETS+=("$p"); continue; fi
  n=$(jq -r --arg p "$p" '[.items[].spec.containers[].ports[]? | select(.name == $p) | .containerPort][0] // empty' <<<"$TRAEFIK_POD")
  [[ -n "$n" ]] && TRAEFIK_TARGETS+=("$n")
done
if (( ${#TRAEFIK_TARGETS[@]} == 0 )); then
  [[ -n "$TRAEFIK_SVC" ]] || log "no Service ${NS_INGRESS}/traefik (NotFound)"
  log "Traefik ports not found; assuming 8000/8443"; TRAEFIK_TARGETS=(8000 8443)
fi
TRAEFIK_TARGETS=($(printf '%s\n' "${TRAEFIK_TARGETS[@]}" | sort -un))

NODE_SOURCES=()  # where host-network clients (API server, kubelet) come from
for ip in "${NODE_IPS[@]}"; do NODE_SOURCES+=("$ip/32"); done
for c in "${POD_CIDRS[@]}"; do NODE_SOURCES+=("$(gateway_block "$c")"); done

RUNNER_EXCEPT=("${DENY_RANGES[@]}")
add_except() {
  local c=$1 r
  for r in "${RUNNER_EXCEPT[@]}"; do cidr_contains "$r" "$c" && return 0; done
  RUNNER_EXCEPT+=("$c")
}
add_except "$CLUSTER_CIDR"
add_except "$SERVICE_CIDR"
for ip in "${NODE_IPS[@]}"; do add_except "$ip/32"; done
for ip in ${TENANT_NODE_IPS[@]+"${TENANT_NODE_IPS[@]}"}; do add_except "$ip/32"; done
for c in ${NETPOL_RUNNER_EGRESS_DENY//,/ }; do
  [[ "$c" == */* ]] || c="$c/32"
  is_ipv4 "${c%/*}" || { provision::error "NETPOL_RUNNER_EGRESS_DENY: not an IPv4 CIDR: $c"; exit 1; }
  add_except "$c"
done

log "env ${ENV_NAME}: nodes ${NODE_IPS[*]}; public ${PUBLIC_IPS[*]:-none}"
(( ${#PRIVATE_EXTERNAL[@]} > 0 )) && log "private ExternalIPs, not public (runners stay denied): ${PRIVATE_EXTERNAL[*]}"
log "cluster CIDR ${CLUSTER_CIDR}, service CIDR ${SERVICE_CIDR}, node podCIDRs ${POD_CIDRS[*]}"
log "Traefik target ports ${TRAEFIK_TARGETS[*]}"
TENANT_NODE_NAMES=$(jq -r '[.items[].metadata.name] | join(" ")' <<<"$TENANT_NODES_JSON")
[[ -n "$TENANT_NODE_NAMES" ]] && log "tenant nodes, not trusted as node sources: ${TENANT_NODE_NAMES} (${TENANT_NODE_IPS[*]-})"

# --- Namespace selection ------------------------------------------------------
in_list() { local x=$1; shift; local l=" ${*//,/ } "; [[ "$l" == *" $x "* ]]; }
ALL_NS=("$NS_RUNNER" "$NS_HARBOR" "$NS_OBS" "$NS_ARGOCD" "$NS_SSO" "$NS_CERT" "$NS_NEXUS" "$NS_MINIO" "$NS_CNPG" "$NS_POSTGRES")
for ns in $(tr ', ' '\n\n' <<<"${NETPOL_APP_NAMESPACES:-}" | sed '/^$/d'); do
  in_list "$ns" "${ALL_NS[*]}" || ALL_NS+=("$ns")
done
EXISTING_NS=$(kget "the namespaces" get ns -o jsonpath='{.items[*].metadata.name}')
TARGET_NS=()
for ns in "${ALL_NS[@]}"; do
  [[ -n "$ONLY" ]] && ! in_list "$ns" "$ONLY" && continue
  [[ -n "${SKIP// /}" ]] && in_list "$ns" "$SKIP" && { log "skip ${ns} (--skip)"; continue; }
  in_list "$ns" "$EXISTING_NS" || { log "skip ${ns} (namespace does not exist)"; continue; }
  TARGET_NS+=("$ns")
done
# Namespaces that run a CNPG cluster: a Cluster object or pods labelled cnpg.io/cluster (instances,
# poolers, bootstrap and backup jobs). Whether the Cluster CRD exists is read by name, by its raw path
# (NotFound: not installed, so no Cluster objects); once it exists, any error listing Clusters stops the
# run. kubectl's "doesn't have a resource type" is never taken for an absent CRD: a discovery that
# timed out half-way prints it too, and reading it as "no clusters" would prune the operator allow.
CNPG_CRD=$(kget_found "the CNPG Cluster CRD" get --raw /apis/apiextensions.k8s.io/v1/customresourcedefinitions/clusters.postgresql.cnpg.io)
if [[ -n "$CNPG_CRD" ]]; then
  CNPG_CLUSTERS_JSON=$(kget "CNPG Cluster objects" get clusters.postgresql.cnpg.io -A -o json)
else
  log "no CNPG Cluster CRD (NotFound): CNPG clusters are found from their pods only"
  CNPG_CLUSTERS_JSON="$EMPTY_LIST"
fi
CNPG_PODS_JSON=$(kget "pods labelled cnpg.io/cluster" get pods -A -l cnpg.io/cluster -o json)
CNPG_NS=$(jq -rs '[.[].items[]?.metadata.namespace] | unique | join(" ")' <<<"$CNPG_CLUSTERS_JSON$CNPG_PODS_JSON")
for ns in ${TARGET_NS[@]+"${TARGET_NS[@]}"}; do
  [[ "$ns" != "$NS_POSTGRES" ]] && in_list "$ns" "$CNPG_NS" && log "${ns} runs a CNPG cluster: the operator may reach its pods on 8000 and 5432"
done

# --- Pods with their own fence ------------------------------------------------
# NetworkPolicies add up: a namespace-wide allow (same namespace, Traefik, Pomerium, Prometheus)
# would widen a narrower ingress policy that a chart or an operator put on some pods (evse's
# evse-from-pomerium-only, pgweb-from-pomerium-only, ...). The allows therefore select exactly the
# pods that no such fence selects; fenced pods stay under the default deny and get only what their
# own policy admits. The allows follow from the fences' labels alone, never from the pods running
# now, so a pod created later is either fenced or allowed, never neither.
#
# A fence is a conjunction of requirements (matchLabels k=v, k In (...), k Exists); its complement
# is the union of the negated requirements (k NotIn (...), k DoesNotExist). The pods outside every
# fence of a namespace are the intersection of those unions, written out as a union of selectors
# (one negated requirement per fence in each), with redundant ones dropped. Each allow gets one
# policy per selector, so a fence with two labels doubles them; NETPOL_MAX_ALLOW_SELECTORS caps the
# count per namespace. A podSelector with NotIn or DoesNotExist stops the run (no such fence exists
# in our charts). A policy with an empty podSelector covers the whole namespace (an extra allow,
# such as nexus/vpn-allow-vpn-gateway); it is no per-pod fence and is left alone. pgweb (postgres)
# and mcp-grafana (observability) are left out even before their own policies exist.
MAX_ALLOW_SELECTORS="${NETPOL_MAX_ALLOW_SELECTORS:-16}"
[[ "$MAX_ALLOW_SELECTORS" =~ ^[1-9][0-9]*$ ]] || { provision::error "NETPOL_MAX_ALLOW_SELECTORS: not a positive number: $MAX_ALLOW_SELECTORS"; exit 1; }
NETPOLS_JSON=$(kget "NetworkPolicies" get networkpolicies -A -o json)
TARGET_NS_J=$(printf '%s\n' ${TARGET_NS[@]+"${TARGET_NS[@]}"} | sed '/^$/d' | jq -R . | jq -sc .)
FENCES_J=$(jq -c --arg m "$MANAGER" --argjson ns "$TARGET_NS_J" '[.items[]
  | select(.metadata.namespace as $n | $ns | index($n))
  | select((.metadata.labels["app.kubernetes.io/managed-by"] // "") != $m)
  | select((.spec.policyTypes // ["Ingress"]) | index("Ingress"))
  | {ns: .metadata.namespace, name: .metadata.name, sel: (.spec.podSelector // {})}]' <<<"$NETPOLS_JSON")
sel_text() { jq -r '[(.matchLabels // {} | to_entries[] | "\(.key)=\(.value)"),
  ((.matchExpressions // [])[] | "\(.key) \(.operator)" + (if .values then " " + (.values | join("|")) else "" end))] | join(",")
  | if . == "" then "every pod" else . end'; }
# shellcheck disable=SC2016  # a jq filter
WHOLE_NS='((.sel.matchLabels // {}) | length) == 0 and ((.sel.matchExpressions // []) | length) == 0'
for p in $(jq -r ".[] | select($WHOLE_NS) | \"\(.ns)/\(.name)\"" <<<"$FENCES_J"); do
  log "${p} selects every pod of its namespace: an extra allow, not a per-pod fence; left alone"
done
FENCES_J=$(jq -c "[.[] | select($WHOLE_NS | not)]" <<<"$FENCES_J")
UNSUPPORTED=$(jq -r '.[] | select(any(.sel.matchExpressions[]?; .operator != "In" and .operator != "Exists"))
  | "\(.ns)/\(.name)"' <<<"$FENCES_J")
if [[ -n "$UNSUPPORTED" ]]; then
  while read -r p; do
    provision::error "${p}: its podSelector uses NotIn or DoesNotExist, which has no exclusion the namespace-wide allows could use"
  done <<<"$UNSUPPORTED"
  provision::error "narrow that selector to matchLabels, In or Exists, or leave its namespace out (--skip); nothing was changed"
  exit 1
fi
# Per namespace: the fences as requirement lists (built-in pgweb / mcp-grafana included), then the
# selectors of the allows: {ns: {raw: <product of the fence sizes>, sels: [podSelector]}}. Past a raw
# product of 4096 the expansion is not tried (the cap below stops the run).
ALLOW_J=$(jq -c --arg obs "$NS_OBS" --arg pg "$NS_POSTGRES" '
  def neg: if .operator == "In" then {key, operator: "NotIn", values} else {key, operator: "DoesNotExist"} end;
  # one requirement per key: DoesNotExist absorbs NotIn, NotIn values add up
  def norm: group_by(.key) | map(if any(.[]; .operator == "DoesNotExist") then {key: .[0].key, operator: "DoesNotExist"}
                                 else {key: .[0].key, operator: "NotIn", values: ([.[].values[]] | unique)} end);
  # every pod requirement $a admits, $b admits too
  def implies($a; $b): $a.key == $b.key and ($a.operator == "DoesNotExist"
    or ($b.operator == "NotIn" and (($b.values - $a.values) | length) == 0));
  # every pod selector $n admits, selector $w admits too
  def within($n; $w): all($w[]; . as $b | any($n[]; implies(.; $b)));
  [.[] | {ns, reqs: ([.sel.matchLabels // {} | to_entries[] | {key, operator: "In", values: [.value]}]
          + [.sel.matchExpressions[]? | if .operator == "In" then {key, operator, values: (.values | unique)} else {key, operator} end]
          | unique)}]
  + [{ns: $obs, reqs: [{key: "app", operator: "In", values: ["mcp-grafana"]}]},
     {ns: $pg, reqs: [{key: "app", operator: "In", values: ["pgweb"]}]}]
  | group_by(.ns) | map(.[0].ns as $ns | [.[].reqs] | unique as $fences
    | ([$fences[] | length] | reduce .[] as $k (1; . * $k)) as $raw
    | {key: $ns, value: {raw: $raw,
        sels: (if $raw > 4096 then [] else
          reduce $fences[] as $f ([[]]; [.[] as $t | $f[] as $r | $t + [$r | neg]])
          | map(norm) | unique
          | . as $all | map(. as $t | select(any($all[]; . != $t and within($t; .)) | not))
          | map(if length == 0 then {} else {matchExpressions: .} end) end)}})
  | from_entries' <<<"$FENCES_J")
for ns in $(jq -r 'keys[]' <<<"$ALLOW_J"); do
  read -r raw count < <(jq -r --arg ns "$ns" '.[$ns] | "\(.raw) \(.sels | length)"' <<<"$ALLOW_J")
  if (( raw > 4096 || count > MAX_ALLOW_SELECTORS )); then
    provision::error "${ns}: its fences need $( (( raw > 4096 )) && echo "up to ${raw}" || echo "${count}") selectors for the namespace-wide allows (each allow gets one policy per selector), more than NETPOL_MAX_ALLOW_SELECTORS=${MAX_ALLOW_SELECTORS}"
    provision::error "give those fences fewer labels (a fence with labels A and B needs a selector for 'not A' and one for 'not B'), raise NETPOL_MAX_ALLOW_SELECTORS, or --skip ${ns}; nothing was changed"
    exit 1
  fi
done
# The log: each fence, the allow selectors and the pods running now that the allows leave out.
# shellcheck disable=SC2016  # a jq function
SEL_MATCH='def matches($sel): (.metadata.labels // {}) as $l
  | all(($sel.matchLabels // {}) | to_entries[]; $l[.key] == .value)
  and all(($sel.matchExpressions // [])[]; . as $e | ($l[$e.key]) as $v
    | if $e.operator == "In" then $v != null and any($e.values[]; . == $v)
      elif $e.operator == "NotIn" then $v == null or all($e.values[]; . != $v)
      elif $e.operator == "Exists" then $v != null
      else $v == null end);'
for ns in $(jq -r '[.[].ns] | unique | .[]' <<<"$FENCES_J"); do
  PODS_JSON=$(kget "pods in ${ns}" -n "$ns" get pods -o json)
  sels=$(jq -c --arg ns "$ns" '.[$ns].sels' <<<"$ALLOW_J")
  for p in $(jq -r --arg ns "$ns" '.[] | select(.ns == $ns) | .name' <<<"$FENCES_J"); do
    log "${ns}: allows leave out the pods of ${p} ($(jq -c --arg ns "$ns" --arg p "$p" '.[] | select(.ns == $ns and .name == $p) | .sel' <<<"$FENCES_J" | sel_text))"
  done
  log "${ns}: each allow selects the pods of any of $(jq -r 'length' <<<"$sels") selectors: $(jq -c '.[]' <<<"$sels" | sel_text | paste -sd';' - | sed 's/;/ | /g')"
  excluded=$(jq -r --argjson sels "$sels" "$SEL_MATCH"'
    [.items[] | select(. as $pod | any($sels[]; . as $s | $pod | matches($s)) | not) | .metadata.name] | join(" ")' <<<"$PODS_JSON")
  log "${ns}: pods left out of the allows: ${excluded:-none}"
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
# allow <ns> <name> <purpose> <ingress-rules-json>: a namespace-wide allow, one policy per selector of
# <ns> (ALLOW_J): <name> for the first, <name>-2, <name>-3, ... for the others. Together they select
# every pod that no fence of its own selects.
allow() {
  local ns=$1 name=$2 why=$3 rules=$4 i=0 s
  while read -r s; do
    i=$((i + 1))
    policy "$ns" "${name}$( (( i > 1 )) && echo "-$i")" "$why" \
      "$(jq -nc --argjson s "$s" --argjson r "$rules" '{podSelector: $s, policyTypes: ["Ingress"], ingress: $r}')"
  done < <(jq -c --arg ns "$ns" '(.[$ns].sels // [{}])[]' <<<"$ALLOW_J")
}
needs_node_sources() { in_list "$1" "$NS_RUNNER $NS_CERT $NS_CNPG"; }

TRAEFIK_PEER=$(from_ns_pods "$NS_INGRESS" app.kubernetes.io/name=traefik)
POMERIUM_PEER=$(from_ns_pods "$NS_SSO" app.kubernetes.io/name=pomerium)
PROMETHEUS_PEER=$(from_ns_pods "$NS_OBS" app.kubernetes.io/name=prometheus)
CNPG_OPERATOR_PEER=$(from_ns_pods "$NS_CNPG" app.kubernetes.io/name=cloudnative-pg)
# Postgres / S3 clients: every namespace that is not a tenant's, or only the listed ones.
client_peer() { # client_peer <namespace list> -> a NetworkPolicyPeer
  jq -nc --arg l "$TENANT_NS_LABEL" --argjson names "$(words_json "${1:-}")" '
    {namespaceSelector: {matchExpressions: ([{key: $l, operator: "DoesNotExist"}]
      + (if ($names | length) > 0 then [{key: "kubernetes.io/metadata.name", operator: "In", values: $names}] else [] end))}}'
}
PG_CLIENTS=$(client_peer "${NETPOL_POSTGRES_CLIENT_NAMESPACES:-}")
S3_CLIENTS=$(jq -c --arg l "$TENANT_NS_LABEL" --argjson t "$(words_json "${NETPOL_TENANT_MINIO:-}")" \
  '[.] + (if ($t | length) > 0 then [{namespaceSelector: {matchExpressions: [{key: $l, operator: "In", values: $t}]}}] else [] end)' \
  <<<"$(client_peer "${NETPOL_MINIO_CLIENT_NAMESPACES:-}")")

render_ns() {
  local ns=$1
  policy "$ns" platform-default-deny-ingress "deny all ingress that no other policy allows" \
    '{"podSelector": {}, "policyTypes": ["Ingress"]}'
  allow "$ns" platform-allow-same-namespace "pods of this namespace talk to each other" '[{"from": [{"podSelector": {}}]}]'
  allow "$ns" platform-allow-from-prometheus "Prometheus scrapes metrics" "[{\"from\": [$PROMETHEUS_PEER]}]"
  if needs_node_sources "$ns"; then
    policy "$ns" platform-allow-from-nodes "API server -> admission webhooks, from the host network of any node" \
      "$(jq -nc --argjson c "$NODE_SOURCES_J" '{podSelector: {}, policyTypes: ["Ingress"], ingress: [{from: ($c | map({ipBlock: {cidr: .}}))}]}')"
  fi
  if [[ "$ns" == "$NS_RUNNER" ]]; then
    render_runner_egress "$ns"
    return
  fi
  allow "$ns" platform-allow-from-ingress-controller "Traefik -> Ingress backends and ACME solver pods" "[{\"from\": [$TRAEFIK_PEER]}]"
  allow "$ns" platform-allow-from-pomerium "Pomerium -> the backends it proxies" "[{\"from\": [$POMERIUM_PEER]}]"
  case "$ns" in
    "$NS_POSTGRES")
      policy "$ns" platform-allow-postgres-clients "apps in every non-tenant namespace -> CNPG instances/poolers on 5432; CNPG operator -> instances" \
        "$(jq -nc --argjson op "$(from_ns_pods "$NS_CNPG" app.kubernetes.io/name=cloudnative-pg)" --argjson clients "$PG_CLIENTS" '{
          podSelector: {matchExpressions: [{key: "cnpg.io/podRole", operator: "In", values: ["instance", "pooler"]}]},
          policyTypes: ["Ingress"],
          ingress: [{from: [$clients], ports: [{port: 5432, protocol: "TCP"}]}, {from: [$op]}]}')"
      local t
      for t in $(jq -r '.[]' <<<"$TENANTS_J"); do
        policy "$ns" "platform-allow-postgres-tenant-${t}" "tenant ${t} -> only its own CNPG poolers (labelled ${TENANT_NS_LABEL}=${t}) on 5432" \
          "$(jq -nc --arg t "$t" --arg l "$TENANT_NS_LABEL" '{
            podSelector: {matchLabels: {"cnpg.io/podRole": "pooler", ($l): $t}},
            policyTypes: ["Ingress"],
            ingress: [{from: [{namespaceSelector: {matchLabels: {($l): $t}}}], ports: [{port: 5432, protocol: "TCP"}]}]}')"
      done
      ;;
    "$NS_MINIO")
      policy "$ns" platform-allow-s3-clients "apps in every non-tenant namespace (and NETPOL_TENANT_MINIO tenants) -> the S3 API on 9000" \
        "$(jq -nc --argjson clients "$S3_CLIENTS" '{podSelector: {matchLabels: {app: "minio"}}, policyTypes: ["Ingress"], ingress: [{from: $clients, ports: [{port: 9000, protocol: "TCP"}]}]}')"
      ;;
  esac
  # The postgres namespace admits the operator on every port (platform-allow-postgres-clients).
  if [[ "$ns" != "$NS_POSTGRES" ]] && in_list "$ns" "$CNPG_NS"; then
    policy "$ns" platform-allow-cnpg-operator "CNPG operator -> this namespace's CNPG cluster pods: instance manager status 8000, PostgreSQL 5432" \
      "$(jq -nc --argjson op "$CNPG_OPERATOR_PEER" '{
        podSelector: {matchExpressions: [{key: "cnpg.io/cluster", operator: "Exists"}]},
        policyTypes: ["Ingress"],
        ingress: [{from: [$op], ports: [{port: 8000, protocol: "TCP"}, {port: 5432, protocol: "TCP"}]}]}')"
  fi
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

{
  for ns in ${TARGET_NS[@]+"${TARGET_NS[@]}"}; do render_ns "$ns"; done
} | jq -s '{apiVersion: "v1", kind: "List", items: .}' >"$RENDERED"
COUNT=$(jq '.items | length' "$RENDERED")

if [[ "$MODE" == print ]]; then cat "$RENDERED"; exit 0; fi

# Managed policies that the render no longer contains.
STALE=$(managed_stale "$RENDERED")

# --- Plan ----------------------------------------------------------------------
log "plan: ${COUNT} policies in ${#TARGET_NS[@]} namespaces (${TARGET_NS[*]:-none})"
# NetworkPolicies add up: another policy in these namespaces with an ingress rule that has no
# `from` admits every source, tenant nodes included, whatever the default deny says. Charts
# ship such policies (the Argo CD chart's argocd-server policy is `ingress: [{}]`; INFRA-214
# found it reachable from a tenant node). Named here; narrowing them is the chart's setting.
if (( ${#TARGET_NS[@]} > 0 )); then
  jq -r --arg m "$MANAGER" --argjson ns "$TARGET_NS_J" <<<"$NETPOLS_JSON" '
    .items[] | select(.metadata.namespace as $n | $ns | index($n))
    | select((.metadata.labels["app.kubernetes.io/managed-by"] // "") != $m)
    | select(any(.spec.ingress[]?; (.from // []) | length == 0))
    | "\(.metadata.namespace)/\(.metadata.name) (pods \(.spec.podSelector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",") | if . == "" then "all" else . end))"' \
  | while read -r p; do log "warning: ${p} admits ingress from anywhere (overrides the default deny for those pods, tenant nodes included)"; done
fi
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
  list_policies "$STALE"
fi

case "$MODE" in
  plan) exit 0 ;;
  dry-run)
    (( COUNT > 0 )) && kubectl apply --server-side --field-manager="$MANAGER" --dry-run=server -f "$RENDERED"
    delete_policies "$STALE" --dry-run=server
    log "server-side dry run passed; nothing changed"
    exit 0 ;;
esac

# --- Apply ---------------------------------------------------------------------
(( COUNT > 0 )) && kubectl apply --server-side --field-manager="$MANAGER" -f "$RENDERED"
delete_policies "$STALE" --ignore-not-found
log "applied. Probe the protected apps now; to roll back: $0 ${ENV_NAME} --remove"
