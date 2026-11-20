#!/usr/bin/env bash
set -euo pipefail
# ============================================================================
# tenant — namespace scaffold for a shared-root tenant (INFRA-214, docs/TENANTS.md)
# ============================================================================
# Renders and applies what a tenant's workloads live in. The node side (tenant worker,
# admission policies) is join-worker.sh --tenant and tenant-admission.sh.
#
#   * Namespace(s), labelled infra-skills/tenant=<tenant> (what the admission policies and the
#     network policies key on) and Pod Security "restricted" (enforce, audit, warn);
#   * ResourceQuota (CPU, memory, pods, PVCs, storage; no LoadBalancer or NodePort Services)
#     and a LimitRange that gives every container a default request and limit;
#   * NetworkPolicies: default-deny ingress AND egress; then ingress from the same namespace,
#     Traefik, Pomerium and Prometheus; egress to the same namespace, cluster DNS, the tenant's
#     own CNPG poolers (postgres namespace, label infra-skills/tenant=<tenant>), MinIO when the
#     tenant is in NETPOL_TENANT_MINIO, Traefik when TENANT_EGRESS_INGRESS=true, and the
#     TENANT_EGRESS destinations (feeds, APIs). Private ranges stay out of an internet egress;
#   * an Argo CD AppProject <tenant>: the tenant's repos only, destinations only its
#     namespaces on this cluster, no cluster-scoped resource, no quota/limit/NetworkPolicy/RBAC
#     objects, and a role read-only (applications and logs, get) for TENANT_ARGOCD_GROUPS.
#
# Usage:
#   tools/k3s/tenant.sh <env-name> <tenant> [options]
#
# Options:
#   (none)             print the plan (kubectl diff), then apply
#   --plan             print the plan only; change nothing
#   --dry-run=server   server-side dry run of the rendered objects; change nothing
#   --print            print the rendered objects (JSON List) and exit
#   --skip-argocd      leave the AppProject out
#   -h, --help         show this help
#
# Settings: envs/<env>/tenants/<tenant>/tenant.properties (sourced when present), else the
# environment:
#   TENANT_NAMESPACES        namespaces of the tenant (default: <tenant>)
#   TENANT_QUOTA_CPU         requests.cpu / limits.cpu (default 4 / 8)
#   TENANT_QUOTA_LIMITS_CPU
#   TENANT_QUOTA_MEMORY      requests.memory / limits.memory (default 8Gi / 16Gi)
#   TENANT_QUOTA_LIMITS_MEMORY
#   TENANT_QUOTA_PODS        pods (default 30); TENANT_QUOTA_PVCS (default 10);
#   TENANT_QUOTA_STORAGE     requests.storage (default 100Gi)
#   TENANT_EGRESS            space list of CIDR[:port[,port...]], e.g. "0.0.0.0/0:443 192.0.2.10/32:8080";
#                            0.0.0.0/0 always excludes RFC 1918, CGNAT, link-local and loopback
#   TENANT_EGRESS_INGRESS    true: egress to Traefik (this cluster's public hostnames)
#   TENANT_SOURCE_REPOS      repos the AppProject may deploy from (required for the AppProject)
#   TENANT_ARGOCD_GROUPS     Dex groups (org:team) given the read-only project role
#   NETPOL_TENANT_MINIO      tenants whose namespaces may reach MinIO (also network-policies.sh)
#
# Objects carry app.kubernetes.io/managed-by=infra-skills-tenant and infra-skills/tenant=<tenant>;
# applied server-side under the field manager infra-skills-tenant. Removing a tenant is
# deliberately not automated: its namespaces hold its data.
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

usage() { sed -n '/^# Usage:/,/^# Objects carry/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d' >&2; }

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
if [[ -z "${1:-}" || -z "${2:-}" ]]; then usage; exit 1; fi
if provision::load_env "$1"; then
  shift
else
  provision::error "Environment '$1' not found (envs/$1/env.properties missing under $(provision::envs_root))."
  exit 1
fi
TENANT="$1"; shift
[[ "$TENANT" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { provision::error "tenant must be a DNS label: $TENANT"; exit 1; }

MODE=apply
SKIP_ARGOCD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan|--diff) MODE=plan; shift ;;
    --dry-run=server) MODE=dry-run; shift ;;
    --dry-run) provision::error "use --dry-run=server"; exit 1 ;;
    --print) MODE=print; shift ;;
    --skip-argocd) SKIP_ARGOCD=true; shift ;;
    *) provision::error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

TENANT_PROPS="$(provision::envs_root)/${ENV_NAME}/tenants/${TENANT}/tenant.properties"
# shellcheck disable=SC1090
[[ -f "$TENANT_PROPS" ]] && source "$TENANT_PROPS"

command -v jq >/dev/null 2>&1 || { provision::error "jq not found"; exit 1; }
if [[ "$MODE" != print ]]; then
  command -v kubectl >/dev/null 2>&1 || { provision::error "kubectl not found"; exit 1; }
  provision::validate_kubectl_context
fi

log() { echo "[tenant] $*" >&2; }
words() { tr ', ' '\n\n' <<<"${1:-}" | sed '/^$/d'; }
words_json() { words "${1:-}" | jq -R . | jq -sc .; }

MANAGER="infra-skills-tenant"
TENANT_LABEL="infra-skills/tenant"
NS_ARGOCD="${NAMESPACE_ARGOCD:-argocd}"
NS_POSTGRES="${NAMESPACE_POSTGRES:-postgres}"
NS_MINIO="${NAMESPACE_MINIO:-minio}"
NS_OBS="${NAMESPACE_OBSERVABILITY:-observability}"
NS_SSO="${NAMESPACE_SSO:-sso}"
NS_INGRESS=kube-system

NAMESPACES_J=$(words_json "${TENANT_NAMESPACES:-$TENANT}")
for ns in $(jq -r '.[]' <<<"$NAMESPACES_J"); do
  [[ "$ns" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { provision::error "TENANT_NAMESPACES: not a namespace name: $ns"; exit 1; }
done
ALLOW_MINIO=false
words "${NETPOL_TENANT_MINIO:-}" | grep -qx "$TENANT" && ALLOW_MINIO=true

# TENANT_EGRESS -> [{cidr, ports: [..]}]
EGRESS_J='[]'
for e in $(words "${TENANT_EGRESS:-}"); do
  cidr="${e%%:*}"; ports=""
  [[ "$e" == *:* ]] && ports="${e#*:}"
  [[ "$cidr" == */* ]] || cidr="$cidr/32"
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || { provision::error "TENANT_EGRESS: not an IPv4 CIDR: $cidr"; exit 1; }
  [[ -z "$ports" || "$ports" =~ ^[0-9]+(,[0-9]+)*$ ]] || { provision::error "TENANT_EGRESS: ports must be numbers: $e"; exit 1; }
  EGRESS_J=$(jq -c --arg c "$cidr" --arg p "$ports" '. + [{cidr: $c, ports: ($p | split(",") | map(select(. != "") | tonumber))}]' <<<"$EGRESS_J")
done

log "env ${ENV_NAME}, tenant ${TENANT}: namespaces ${NAMESPACES_J}; egress ${EGRESS_J}; minio ${ALLOW_MINIO}; traefik egress ${TENANT_EGRESS_INGRESS:-false}"

# --- Render -------------------------------------------------------------------
meta() { # meta <kind-specific json> -> adds the common labels
  jq -c --arg mgr "$MANAGER" --arg tl "$TENANT_LABEL" --arg t "$TENANT" \
    '.metadata.labels = ((.metadata.labels // {}) + {"app.kubernetes.io/managed-by": $mgr, ($tl): $t})'
}
from_ns_pods() { # from_ns_pods <ns> <k=v> -> a NetworkPolicyPeer
  jq -nc --arg ns "$1" --arg k "${2%%=*}" --arg v "${2#*=}" \
    '{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": $ns}}, podSelector: {matchLabels: {($k): $v}}}'
}

render_namespace() {
  local ns=$1
  jq -nc --arg ns "$ns" '{apiVersion: "v1", kind: "Namespace", metadata: {name: $ns, labels: {
      "pod-security.kubernetes.io/enforce": "restricted", "pod-security.kubernetes.io/enforce-version": "latest",
      "pod-security.kubernetes.io/audit": "restricted", "pod-security.kubernetes.io/warn": "restricted"}}}' | meta
  jq -nc --arg ns "$ns" \
     --arg rc "${TENANT_QUOTA_CPU:-4}" --arg lc "${TENANT_QUOTA_LIMITS_CPU:-8}" \
     --arg rm "${TENANT_QUOTA_MEMORY:-8Gi}" --arg lm "${TENANT_QUOTA_LIMITS_MEMORY:-16Gi}" \
     --arg pods "${TENANT_QUOTA_PODS:-30}" --arg pvcs "${TENANT_QUOTA_PVCS:-10}" --arg st "${TENANT_QUOTA_STORAGE:-100Gi}" '
    {apiVersion: "v1", kind: "ResourceQuota", metadata: {name: "tenant-quota", namespace: $ns},
     spec: {hard: {"requests.cpu": $rc, "limits.cpu": $lc, "requests.memory": $rm, "limits.memory": $lm,
                   pods: $pods, persistentvolumeclaims: $pvcs, "requests.storage": $st,
                   "services.loadbalancers": "0", "services.nodeports": "0"}}}' | meta
  jq -nc --arg ns "$ns" '
    {apiVersion: "v1", kind: "LimitRange", metadata: {name: "tenant-defaults", namespace: $ns},
     spec: {limits: [{type: "Container",
       defaultRequest: {cpu: "100m", memory: "128Mi"}, default: {cpu: "1", memory: "512Mi"},
       max: {cpu: "4", memory: "8Gi"}}]}}' | meta
}

netpol() { # netpol <ns> <name> <purpose> <spec-json>
  jq -nc --arg ns "$1" --arg name "$2" --arg why "$3" --argjson spec "$4" '{
    apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy",
    metadata: {name: $name, namespace: $ns, annotations: {"infra-skills/purpose": $why}}, spec: $spec}' | meta
}

PRIVATE_J='["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","100.64.0.0/10","169.254.0.0/16","127.0.0.0/8"]'

render_netpols() {
  local ns=$1 egress
  netpol "$ns" tenant-default-deny "deny all ingress and egress that no other policy allows" \
    '{"podSelector": {}, "policyTypes": ["Ingress", "Egress"]}'
  netpol "$ns" tenant-allow-ingress "same namespace, Traefik, Pomerium, Prometheus" \
    "$(jq -nc --argjson tr "$(from_ns_pods "$NS_INGRESS" app.kubernetes.io/name=traefik)" \
              --argjson po "$(from_ns_pods "$NS_SSO" app.kubernetes.io/name=pomerium)" \
              --argjson pr "$(from_ns_pods "$NS_OBS" app.kubernetes.io/name=prometheus)" \
      '{podSelector: {}, policyTypes: ["Ingress"], ingress: [{from: [{podSelector: {}}, $tr, $po, $pr]}]}')"
  egress=$(jq -nc --arg ing "$NS_INGRESS" --arg pg "$NS_POSTGRES" --arg tl "$TENANT_LABEL" --arg t "$TENANT" '[
    {to: [{podSelector: {}}]},
    {to: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": $ing}}, podSelector: {matchLabels: {"k8s-app": "kube-dns"}}}],
     ports: [{port: 53, protocol: "UDP"}, {port: 53, protocol: "TCP"}]},
    {to: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": $pg}}, podSelector: {matchLabels: {"cnpg.io/podRole": "pooler", ($tl): $t}}}],
     ports: [{port: 5432, protocol: "TCP"}]}]')
  if $ALLOW_MINIO; then
    egress=$(jq -c --argjson m "$(from_ns_pods "$NS_MINIO" app=minio)" '. + [{to: [$m], ports: [{port: 9000, protocol: "TCP"}]}]' <<<"$egress")
  fi
  if [[ "${TENANT_EGRESS_INGRESS:-false}" == true ]]; then
    egress=$(jq -c --argjson tr "$(from_ns_pods "$NS_INGRESS" app.kubernetes.io/name=traefik)" \
                   --argjson lb "$(from_ns_pods "$NS_INGRESS" svccontroller.k3s.cattle.io/svcname=traefik)" \
      '. + [{to: [$tr, $lb]}]' <<<"$egress")
  fi
  egress=$(jq -c --argjson e "$EGRESS_J" --argjson priv "$PRIVATE_J" '. + ($e | map(
      {to: [{ipBlock: ({cidr: .cidr} + (if .cidr == "0.0.0.0/0" then {except: $priv} else {} end))}]}
      + (if (.ports | length) > 0 then {ports: (.ports | map({port: ., protocol: "TCP"}))} else {} end)))' <<<"$egress")
  netpol "$ns" tenant-allow-egress "same namespace, DNS, own CNPG poolers, configured destinations" \
    "$(jq -nc --argjson e "$egress" '{podSelector: {}, policyTypes: ["Egress"], egress: $e}')"
}

render_appproject() {
  local repos groups
  repos=$(words_json "${TENANT_SOURCE_REPOS:-}")
  groups=$(words_json "${TENANT_ARGOCD_GROUPS:-}")
  if [[ "$repos" == "[]" ]]; then
    log "TENANT_SOURCE_REPOS not set: no AppProject (set it in ${TENANT_PROPS})"
    return 0
  fi
  jq -nc --arg t "$TENANT" --arg ns "$NS_ARGOCD" --argjson repos "$repos" --argjson groups "$groups" --argjson dests "$NAMESPACES_J" '{
    apiVersion: "argoproj.io/v1alpha1", kind: "AppProject", metadata: {name: $t, namespace: $ns},
    spec: {
      description: ("tenant " + $t + " (infra-skills tools/k3s/tenant.sh)"),
      sourceRepos: $repos,
      destinations: ($dests | map({server: "https://kubernetes.default.svc", namespace: .})),
      clusterResourceWhitelist: [],
      namespaceResourceBlacklist: [
        {group: "", kind: "ResourceQuota"}, {group: "", kind: "LimitRange"},
        {group: "networking.k8s.io", kind: "NetworkPolicy"},
        {group: "rbac.authorization.k8s.io", kind: "Role"}, {group: "rbac.authorization.k8s.io", kind: "RoleBinding"}],
      roles: [{name: "read-only", description: "tenant members: see applications and their logs",
               policies: [("p, proj:" + $t + ":read-only, applications, get, " + $t + "/*, allow"),
                          ("p, proj:" + $t + ":read-only, logs, get, " + $t + "/*, allow")],
               groups: $groups}]}}' | meta
}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/tenant.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
RENDERED="$TMPD/tenant.json"
{
  for ns in $(jq -r '.[]' <<<"$NAMESPACES_J"); do
    render_namespace "$ns"
    render_netpols "$ns"
  done
  $SKIP_ARGOCD || render_appproject
} | jq -s '{apiVersion: "v1", kind: "List", items: .}' >"$RENDERED"

if [[ "$MODE" == print ]]; then cat "$RENDERED"; exit 0; fi

# Namespaces first: the namespaced objects of a server-side dry run need them to exist.
NS_LIST="$TMPD/ns.json"; REST="$TMPD/rest.json"
jq '{apiVersion: "v1", kind: "List", items: [.items[] | select(.kind == "Namespace")]}' "$RENDERED" >"$NS_LIST"
jq '{apiVersion: "v1", kind: "List", items: [.items[] | select(.kind != "Namespace")]}' "$RENDERED" >"$REST"
if jq -e '.items | any(.kind == "AppProject")' "$REST" >/dev/null && ! kubectl get crd appprojects.argoproj.io >/dev/null 2>&1; then
  provision::error "Argo CD is not installed (no AppProject CRD); run argocd.sh first or use --skip-argocd"; exit 1
fi

log "plan: $(jq '.items | length' "$RENDERED") objects"
set +e
kubectl diff --server-side --field-manager="$MANAGER" -f "$NS_LIST"; rc1=$?
MISSING_NS=$(jq -r '.items[].metadata.name' "$NS_LIST" | while read -r n; do kubectl get ns "$n" >/dev/null 2>&1 || echo "$n"; done)
rc2=0
if [[ -z "$MISSING_NS" ]]; then kubectl diff --server-side --field-manager="$MANAGER" -f "$REST"; rc2=$?; fi
set -e
(( rc1 > 1 || rc2 > 1 )) && { provision::error "kubectl diff failed"; exit 1; }
[[ -n "$MISSING_NS" ]] && log "namespaces to create first: ${MISSING_NS//$'\n'/ } (their contents are diffed once they exist)"

case "$MODE" in
  plan) exit 0 ;;
  dry-run)
    kubectl apply --server-side --field-manager="$MANAGER" --dry-run=server -f "$NS_LIST"
    [[ -z "$MISSING_NS" ]] && kubectl apply --server-side --field-manager="$MANAGER" --dry-run=server -f "$REST"
    log "server-side dry run passed; nothing changed"
    exit 0 ;;
esac

kubectl apply --server-side --field-manager="$MANAGER" -f "$NS_LIST"
kubectl apply --server-side --field-manager="$MANAGER" -f "$REST"
log "applied. Tenant pods need nodeSelector node-restriction.kubernetes.io/tenant=${TENANT} and the toleration"
log "  infra-skills/tenant=${TENANT}:NoExecute (tenant-admission.sh enforces both); Postgres via postgres.sh --provision-credentials --tenant ${TENANT} --pooler"
