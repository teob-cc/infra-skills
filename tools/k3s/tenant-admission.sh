#!/usr/bin/env bash
set -euo pipefail
# ============================================================================
# tenant-admission — ValidatingAdmissionPolicies for shared-root tenant workers (INFRA-214)
# ============================================================================
# A tenant worker is a node whose root is shared with a tenant (docs/TENANTS.md). The tenant can
# read everything on that node: the kubelet's client certificate (system:node:<node>), the
# agent token it joined with, and the client certificate k3s gives every agent for flannel and
# the network-policy controller (system:k3s-controller, one identity shared by all agents).
# Four in-process admission policies (no webhook, nothing to keep running) stop that access from
# reaching other workloads:
#
#   infra-skills-node-registration
#       An agent token lets its holder register new nodes. A kubelet may create a Node only
#       with the taint infra-skills/quarantine=true:NoExecute (or if its name is on
#       NODE_REGISTRATION_ALLOWLIST), so a node nobody vetted never receives a pod. A node named
#       <tenant>-* must also carry infra-skills/tenant=<tenant>:NoExecute. join-worker.sh adds
#       both taints and lifts the quarantine as cluster admin once the node checks out.
#   infra-skills-tenant-node-self
#       The kubelet of a tenant node (system:node:<tenant>-*, or any node labelled
#       node-restriction.kubernetes.io/tenant) may not change its spec (taints, unschedulable)
#       or any label outside the set the kubelet itself maintains (hostname, os, arch,
#       instance type, zone, region), and may register only with those. NodeRestriction
#       already keeps it off node-restriction.kubernetes.io/*; this also covers the labels
#       other workloads select on (gpu=..., role labels).
#   infra-skills-node-shared-agent-identity
#       system:k3s-controller may patch nodes/status of every node. On nodes it may change
#       only flannel's annotations, and flannel's public-ip must be one of the node's own
#       addresses: a tenant holding that certificate cannot relabel nodes, rewrite their
#       addresses or point another node's VXLAN traffic at itself.
#   infra-skills-tenant-pod-placement
#       Pods in a namespace labelled infra-skills/tenant=<tenant> must select
#       node-restriction.kubernetes.io/tenant=<tenant>, tolerate exactly their tenant's taint
#       (no wildcard, no other tenant, no quarantine) and may name only <tenant>-* nodes.
#       Pods anywhere else may not tolerate a tenant or the quarantine taint (a wildcard
#       toleration with effect NoExecute or none counts) and may not name a tenant node, so no
#       platform pod, and none of its Secrets, ever lands on a tenant node. Namespaces in
#       TENANT_NODE_SHARED_NAMESPACES are exempt from the second rule (a DaemonSet that must run
#       on every node and holds no credential worth protecting); default none.
#
# The tenant label on a node (node-restriction.kubernetes.io/tenant=<tenant>) is set by a cluster
# admin with kubectl: NodeRestriction stops a kubelet from setting it, and with it the k3s
# node-label config cannot set it either.
#
# Usage:
#   tools/k3s/tenant-admission.sh <env-name> [options]
#
# Options:
#   (none)             print the plan (kubectl diff + preflight), then apply
#   --plan             print the plan and the preflight only; change nothing
#   --dry-run=server   send the rendered policies to the API server as a server-side dry run
#                      (CEL is compiled and type-checked there); change nothing
#   --print            print the rendered objects (JSON List) and exit
#   --warn             bind with validationActions [Warn, Audit] instead of [Deny]: report
#                      what would be denied without denying it (first rollout on a live cluster)
#   --remove           delete the policies and bindings (rollback); combine with --plan or
#                      --dry-run=server to preview
#   -h, --help         show this help
#
# env.properties:
#   TENANTS                          tenant names (space/comma list), e.g. "symbioen"; a tenant's
#                                    nodes are named <tenant>-*, its namespaces are labelled
#                                    infra-skills/tenant=<tenant>
#   NODE_REGISTRATION_ALLOWLIST      node names a kubelet may register without the quarantine
#                                    taint (default none: every new node starts quarantined)
#   TENANT_NODE_SHARED_NAMESPACES    namespaces whose pods may tolerate tenant taints (default none)
#   K3S_SHARED_AGENT_USERS           shared agent identities to fence (default system:k3s-controller)
#
# Objects carry app.kubernetes.io/managed-by=infra-skills-tenant-admission and are applied
# server-side under the field manager of the same name.
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

usage() { sed -n '/^# Usage:/,/^# Objects carry/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d' >&2; }

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
ACTIONS='["Deny"]'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan|--diff) MODE=plan; shift ;;
    --dry-run=server) MODE=dry-run; shift ;;
    --dry-run) provision::error "use --dry-run=server"; exit 1 ;;
    --print) MODE=print; shift ;;
    --warn) ACTIONS='["Warn","Audit"]'; shift ;;
    --remove) REMOVE=true; shift ;;
    *) provision::error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { provision::error "jq not found"; exit 1; }
if [[ "$MODE" != print ]]; then
  command -v kubectl >/dev/null 2>&1 || { provision::error "kubectl not found"; exit 1; }
  provision::validate_kubectl_context
fi

log() { echo "[tenant-admission] $*" >&2; }

MANAGER="infra-skills-tenant-admission"
TENANT_NODE_LABEL="node-restriction.kubernetes.io/tenant"
TENANT_NS_LABEL="infra-skills/tenant"
TENANT_TAINT="infra-skills/tenant"
QUARANTINE_TAINT="infra-skills/quarantine"

# words <list> -> one item per line (space/comma separated input)
words() { tr ', ' '\n\n' <<<"${1:-}" | sed '/^$/d'; }
json_words() { words "${1:-}" | jq -R . | jq -sc .; }

DNS_LABEL='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
for t in $(words "${TENANTS:-}"); do
  [[ "$t" =~ $DNS_LABEL ]] || { provision::error "TENANTS: not a DNS label: $t"; exit 1; }
done
for n in $(words "${NODE_REGISTRATION_ALLOWLIST:-}"); do
  [[ "$n" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || { provision::error "NODE_REGISTRATION_ALLOWLIST: not a node name: $n"; exit 1; }
  for t in $(words "${TENANTS:-}"); do
    [[ "$n" == "$t-"* ]] && { provision::error "NODE_REGISTRATION_ALLOWLIST: $n is a tenant node name ($t-*); tenant nodes always start quarantined"; exit 1; }
  done
done
TENANTS_J=$(json_words "${TENANTS:-}")
ALLOW_J=$(json_words "${NODE_REGISTRATION_ALLOWLIST:-}")
SHARED_NS_J=$(json_words "${TENANT_NODE_SHARED_NAMESPACES:-}")
AGENT_USERS_J=$(json_words "${K3S_SHARED_AGENT_USERS:-system:k3s-controller}")

log "env ${ENV_NAME}: tenants ${TENANTS_J}; registration allowlist ${ALLOW_J}; shared namespaces ${SHARED_NS_J}; shared agent users ${AGENT_USERS_J}; actions ${ACTIONS}"

# --- Render -------------------------------------------------------------------
# policy <name> <purpose> <spec-json>; each policy gets one binding of the same name
policy() {
  jq -nc --arg name "$1" --arg why "$2" --arg mgr "$MANAGER" --argjson spec "$3" --argjson actions "$ACTIONS" '
    {apiVersion: "admissionregistration.k8s.io/v1", kind: "ValidatingAdmissionPolicy",
     metadata: {name: $name, labels: {"app.kubernetes.io/managed-by": $mgr, "app.kubernetes.io/part-of": "tenant-isolation"},
                annotations: {"infra-skills/purpose": $why}},
     spec: ({failurePolicy: "Fail"} + $spec)},
    {apiVersion: "admissionregistration.k8s.io/v1", kind: "ValidatingAdmissionPolicyBinding",
     metadata: {name: $name, labels: {"app.kubernetes.io/managed-by": $mgr, "app.kubernetes.io/part-of": "tenant-isolation"}},
     spec: {policyName: $name, validationActions: $actions}}'
}

# CEL fragments. JSON string arrays are valid CEL list literals.
CEL_TAINTS='has(object.spec.taints) ? object.spec.taints : []'
CEL_KUBELET_LABEL='^(kubernetes\\.io/(hostname|os|arch)|beta\\.kubernetes\\.io/(os|arch|instance-type)|node\\.kubernetes\\.io/instance-type|topology\\.kubernetes\\.io/(region|zone)|failure-domain\\.beta\\.kubernetes\\.io/(region|zone))$'
CEL_FLANNEL_ANNOTATION='^flannel\\.alpha\\.coreos\\.com/(backend-data|backend-v6-data|backend-type|kube-subnet-manager|public-ip|public-ipv6)$'

render_node_registration() {
  policy infra-skills-node-registration \
    "a kubelet registers a new node only quarantined (or allowlisted); tenant nodes also with their tenant taint" \
    "$(jq -nc --argjson tenants "$TENANTS_J" --argjson allow "$ALLOW_J" \
        --arg q "$QUARANTINE_TAINT" --arg tt "$TENANT_TAINT" --arg taints "$CEL_TAINTS" '{
      matchConstraints: {resourceRules: [{apiGroups: [""], apiVersions: ["v1"], operations: ["CREATE"], resources: ["nodes"]}]},
      matchConditions: [{name: "kubelet", expression: "request.userInfo.username.startsWith(\"system:node:\")"}],
      variables: [
        {name: "taints", expression: $taints},
        {name: "tenant", expression: (($tenants | tojson) + ".filter(t, object.metadata.name.startsWith(t + \"-\"))")}
      ],
      validations: [
        {expression: ("object.metadata.name in " + ($allow | tojson) + " || variables.taints.exists(t, t.key == \"" + $q + "\" && t.effect == \"NoExecute\")"),
         messageExpression: ("\"node \" + object.metadata.name + \" may register only with the taint " + $q + "=true:NoExecute (infra-skills tenant-admission; join-worker.sh adds it and lifts it once the node checks out)\""),
         reason: "Forbidden"},
        {expression: ("variables.tenant.all(n, variables.taints.exists(t, t.key == \"" + $tt + "\" && t.value == n && t.effect == \"NoExecute\"))"),
         messageExpression: ("\"tenant node \" + object.metadata.name + \" must register with the taint " + $tt + "=\" + variables.tenant[0] + \":NoExecute\""),
         reason: "Forbidden"}
      ]}')"
}

render_tenant_node_self() {
  policy infra-skills-tenant-node-self \
    "the kubelet of a tenant node may not change its spec (taints) or labels other workloads select on" \
    "$(jq -nc --argjson tenants "$TENANTS_J" --arg tl "$TENANT_NODE_LABEL" --arg re "$CEL_KUBELET_LABEL" '{
      matchConstraints: {resourceRules: [{apiGroups: [""], apiVersions: ["v1"], operations: ["CREATE", "UPDATE"], resources: ["nodes", "nodes/status"]}]},
      matchConditions: [{name: "tenant-kubelet", expression: (
        "request.userInfo.username.startsWith(\"system:node:\") && (" + ($tenants | tojson)
        + ".exists(t, request.userInfo.username.startsWith(\"system:node:\" + t + \"-\")) || (oldObject != null && has(oldObject.metadata.labels) && \"" + $tl + "\" in oldObject.metadata.labels))")}],
      variables: [
        {name: "newLabels", expression: "has(object.metadata.labels) ? object.metadata.labels : {}"},
        {name: "oldLabels", expression: "oldObject != null && has(oldObject.metadata.labels) ? oldObject.metadata.labels : {}"},
        {name: "foreignNew", expression: ("variables.newLabels.filter(k, !k.matches(\"" + $re + "\"))")},
        {name: "foreignOld", expression: ("variables.oldLabels.filter(k, !k.matches(\"" + $re + "\"))")}
      ],
      validations: [
        {expression: "request.operation != \"CREATE\" || size(variables.foreignNew) == 0",
         messageExpression: "\"tenant node \" + object.metadata.name + \" may register only with kubelet-maintained labels; not: \" + variables.foreignNew.join(\", \")",
         reason: "Forbidden"},
        {expression: "request.operation != \"UPDATE\" || (variables.foreignNew.all(k, k in variables.oldLabels && variables.oldLabels[k] == variables.newLabels[k]) && variables.foreignOld.all(k, k in variables.newLabels))",
         message: "the kubelet of a tenant node may change only kubelet-maintained labels (hostname, os, arch, instance type, zone, region)",
         reason: "Forbidden"},
        {expression: "request.operation != \"UPDATE\" || object.spec == oldObject.spec",
         message: "the kubelet of a tenant node may not change its spec (taints, unschedulable, ...)",
         reason: "Forbidden"}
      ]}')"
}

render_shared_agent_identity() {
  policy infra-skills-node-shared-agent-identity \
    "the shared k3s agent identity may change only flannel annotations of a node, public-ip pinned to the node's own addresses" \
    "$(jq -nc --argjson users "$AGENT_USERS_J" --arg re "$CEL_FLANNEL_ANNOTATION" '{
      matchConstraints: {resourceRules: [{apiGroups: [""], apiVersions: ["v1"], operations: ["UPDATE"], resources: ["nodes", "nodes/status"]}]},
      matchConditions: [{name: "shared-agent-identity", expression: ("request.userInfo.username in " + ($users | tojson))}],
      variables: [
        {name: "newA", expression: "has(object.metadata.annotations) ? object.metadata.annotations : {}"},
        {name: "oldA", expression: "has(oldObject.metadata.annotations) ? oldObject.metadata.annotations : {}"},
        {name: "changed", expression: "variables.newA.filter(k, !(k in variables.oldA) || variables.oldA[k] != variables.newA[k]) + variables.oldA.filter(k, !(k in variables.newA))"},
        {name: "addresses", expression: "has(oldObject.status.addresses) ? oldObject.status.addresses.map(a, a.address) : []"}
      ],
      validations: [
        {expression: "(has(object.metadata.labels) ? object.metadata.labels : {}) == (has(oldObject.metadata.labels) ? oldObject.metadata.labels : {})",
         message: "the shared k3s agent identity may not change node labels", reason: "Forbidden"},
        {expression: "object.spec == oldObject.spec",
         message: "the shared k3s agent identity may not change a node spec", reason: "Forbidden"},
        {expression: "(has(object.status.addresses) ? object.status.addresses : []) == (has(oldObject.status.addresses) ? oldObject.status.addresses : [])",
         message: "the shared k3s agent identity may not change node addresses", reason: "Forbidden"},
        {expression: ("variables.changed.all(k, k.matches(\"" + $re + "\"))"),
         messageExpression: "\"the shared k3s agent identity may change only flannel annotations; not: \" + variables.changed.filter(k, !k.startsWith(\"flannel.alpha.coreos.com/\")).join(\", \")",
         reason: "Forbidden"},
        {expression: "[\"flannel.alpha.coreos.com/public-ip\", \"flannel.alpha.coreos.com/public-ipv6\"].all(k, !(k in variables.changed) || !(k in variables.newA) || variables.newA[k] in variables.addresses)",
         message: "flannel public-ip must be one of the addresses of the node itself", reason: "Forbidden"}
      ]}')"
}

render_pod_placement() {
  policy infra-skills-tenant-pod-placement \
    "tenant pods run only on their tenant's nodes; no other pod tolerates a tenant or quarantine taint" \
    "$(jq -nc --argjson tenants "$TENANTS_J" --argjson shared "$SHARED_NS_J" \
        --arg nl "$TENANT_NS_LABEL" --arg tl "$TENANT_NODE_LABEL" --arg tt "$TENANT_TAINT" --arg q "$QUARANTINE_TAINT" '{
      matchConstraints: {resourceRules: [{apiGroups: [""], apiVersions: ["v1"], operations: ["CREATE", "UPDATE"], resources: ["pods"]}]},
      matchConditions: [
        # mirror pods of static pods: NodeRestriction binds them to the own node of the kubelet and denies them Secrets
        {name: "not-a-kubelet", expression: "!request.userInfo.username.startsWith(\"system:node:\")"},
        # tolerations are the only placement field a pod update may change
        {name: "create-or-tolerations-changed", expression: "request.operation == \"CREATE\" || (has(object.spec.tolerations) ? object.spec.tolerations : []) != (has(oldObject.spec.tolerations) ? oldObject.spec.tolerations : [])"}
      ],
      variables: [
        {name: "tenant", expression: ("has(namespaceObject.metadata.labels) && \"" + $nl + "\" in namespaceObject.metadata.labels ? namespaceObject.metadata.labels[\"" + $nl + "\"] : \"\"")},
        {name: "tolerations", expression: "has(object.spec.tolerations) ? object.spec.tolerations : []"},
        # a toleration matches a NoExecute taint with key K when its key is K (or empty with operator Exists) and its effect is NoExecute or empty
        {name: "noExecute", expression: "variables.tolerations.filter(t, !has(t.effect) || t.effect == \"\" || t.effect == \"NoExecute\")"},
        {name: "wildcard", expression: "variables.noExecute.filter(t, (!has(t.key) || t.key == \"\") && has(t.operator) && t.operator == \"Exists\")"},
        {name: "tenantTols", expression: ("variables.noExecute.filter(t, has(t.key) && t.key == \"" + $tt + "\")")},
        {name: "quarantineTols", expression: ("variables.noExecute.filter(t, has(t.key) && t.key == \"" + $q + "\")")},
        {name: "nodeName", expression: "has(object.spec.nodeName) ? object.spec.nodeName : \"\""},
        {name: "shared", expression: ("namespaceObject.metadata.name in " + ($shared | tojson))}
      ],
      validations: [
        # --- tenant namespaces
        {expression: ("variables.tenant == \"\" || (has(object.spec.nodeSelector) && \"" + $tl + "\" in object.spec.nodeSelector && object.spec.nodeSelector[\"" + $tl + "\"] == variables.tenant)"),
         messageExpression: ("\"pods of tenant \" + variables.tenant + \" must have nodeSelector " + $tl + "=\" + variables.tenant"),
         reason: "Forbidden"},
        {expression: ("variables.tenant == \"\" || variables.tenantTols.exists(t, (!has(t.operator) || t.operator == \"Equal\") && has(t.value) && t.value == variables.tenant)"),
         messageExpression: ("\"pods of tenant \" + variables.tenant + \" must tolerate " + $tt + "=\" + variables.tenant + \":NoExecute (operator Equal)\""),
         reason: "Forbidden"},
        {expression: ("variables.tenant == \"\" || (size(variables.wildcard) == 0 && size(variables.quarantineTols) == 0 && variables.tenantTols.all(t, (!has(t.operator) || t.operator == \"Equal\") && has(t.value) && t.value == variables.tenant))"),
         messageExpression: ("\"pods of tenant \" + variables.tenant + \" may tolerate only their own tenant taint: no wildcard, no other tenant, no " + $q + "\""),
         reason: "Forbidden"},
        {expression: "variables.tenant == \"\" || request.operation != \"CREATE\" || variables.nodeName == \"\" || variables.nodeName.startsWith(variables.tenant + \"-\")",
         messageExpression: "\"pods of tenant \" + variables.tenant + \" may name only \" + variables.tenant + \"-* nodes\"",
         reason: "Forbidden"},
        # --- every other namespace
        {expression: "variables.tenant != \"\" || variables.shared || (size(variables.wildcard) == 0 && size(variables.tenantTols) == 0 && size(variables.quarantineTols) == 0)",
         message: ("pods outside tenant namespaces may not tolerate " + $tt + " or " + $q + " (a wildcard toleration with effect NoExecute or none counts); see docs/TENANTS.md"),
         reason: "Forbidden"},
        {expression: ("variables.tenant != \"\" || request.operation != \"CREATE\" || !" + ($tenants | tojson) + ".exists(t, variables.nodeName.startsWith(t + \"-\"))"),
         message: "pods outside tenant namespaces may not name a tenant node",
         reason: "Forbidden"}
      ]}')"
}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/tenant-admission.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
RENDERED="$TMPD/policies.json"
{
  if [[ "$REMOVE" != true ]]; then
    render_node_registration
    render_tenant_node_self
    render_shared_agent_identity
    render_pod_placement
  fi
} | jq -s '{apiVersion: "v1", kind: "List", items: .}' >"$RENDERED"
COUNT=$(jq '.items | length' "$RENDERED")

if [[ "$MODE" == print ]]; then cat "$RENDERED"; exit 0; fi

# --- Preflight: what the policies would deny in the cluster as it is now ----------
# Admission checks requests, not stored objects: running pods are never evicted by these
# policies, but their controllers could no longer recreate them.
preflight() {
  local nodes pods nss
  nodes=$(kubectl get nodes -o json)
  pods=$(kubectl get pods -A -o json)
  nss=$(kubectl get ns -o json)
  jq -r --argjson tenants "$TENANTS_J" --arg tl "$TENANT_NODE_LABEL" --arg tt "$TENANT_TAINT" --arg q "$QUARANTINE_TAINT" '
    .items[] | .metadata.name as $n
    | (.metadata.labels // {}) as $l | (.spec.taints // []) as $taints
    | ([$tenants[] | select($n | startswith(. + "-"))] | first) as $t
    | if $t then
        (if ($l[$tl] // "") != $t then "node \($n): tenant node without label \($tl)=\($t) (set it as admin: kubectl label node \($n) \($tl)=\($t))" else empty end),
        (if ($taints | any(.key == $tt and .value == $t and .effect == "NoExecute")) then empty else "node \($n): tenant node without taint \($tt)=\($t):NoExecute" end)
      elif ($l[$tl] // "") != "" then "node \($n): labelled \($tl)=\($l[$tl]) but not named \($l[$tl])-*"
      else empty end,
      (if ($taints | any(.key == $q)) then "node \($n): quarantined (\($q)); lift with: kubectl taint node \($n) \($q)-" else empty end)
  ' <<<"$nodes" | sed 's/^/[tenant-admission] preflight: /' >&2
  jq -r --argjson tenants "$TENANTS_J" --argjson shared "$SHARED_NS_J" --slurpfile ns <(printf '%s' "$nss") \
     --arg nl "$TENANT_NS_LABEL" --arg tl "$TENANT_NODE_LABEL" --arg tt "$TENANT_TAINT" --arg q "$QUARANTINE_TAINT" '
    ($ns[0].items | map({key: .metadata.name, value: (.metadata.labels[$nl] // "")}) | from_entries) as $tenantOf
    | .items[] | .metadata.namespace as $pns | ($tenantOf[$pns] // "") as $t
    | (.metadata.ownerReferences[0].kind // "Pod") as $owner
    | [(.spec.tolerations // [])[] | select((.effect // "") == "" or .effect == "NoExecute")] as $ne
    | ([$ne[] | select((.key // "") == "" and .operator == "Exists")] | length) as $wild
    | ([$ne[] | select(.key == $tt)]) as $tten
    | ([$ne[] | select(.key == $q)] | length) as $quar
    | if $t != "" then
        (if (.spec.nodeSelector[$tl] // "") != $t then "pod \($pns)/\(.metadata.name) (\($owner)): no nodeSelector \($tl)=\($t)" else empty end),
        (if ($tten | any((.operator // "Equal") == "Equal" and .value == $t)) and $wild == 0 and $quar == 0
              and ($tten | all((.operator // "Equal") == "Equal" and .value == $t)) then empty
         else "pod \($pns)/\(.metadata.name) (\($owner)): tolerations are not exactly \($tt)=\($t):NoExecute" end)
      elif ($shared | index($pns)) then empty
      elif $wild > 0 or ($tten | length) > 0 or $quar > 0 then "pod \($pns)/\(.metadata.name) (\($owner)): tolerates tenant/quarantine taints (wildcard: \($wild))"
      else empty end
  ' <<<"$pods" | sort -u | sed 's/^/[tenant-admission] preflight: /' >&2
}

# --- Plan ----------------------------------------------------------------------
STALE=$(kubectl get validatingadmissionpolicies,validatingadmissionpolicybindings -l "app.kubernetes.io/managed-by=${MANAGER}" -o json \
  | jq -r --slurpfile r "$RENDERED" '($r[0].items | map(.kind + "/" + .metadata.name)) as $want
      | .items[] | (.kind + "/" + .metadata.name) | select(. as $k | $want | index($k) | not)')

log "plan: ${COUNT} objects"
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
  preflight
fi
if [[ -n "$STALE" ]]; then
  log "would delete (managed, no longer rendered):"
  sed 's/^/  - /' <<<"$STALE" >&2
fi

case "$MODE" in
  plan) exit 0 ;;
  dry-run)
    (( COUNT > 0 )) && kubectl apply --server-side --field-manager="$MANAGER" --dry-run=server -f "$RENDERED"
    while read -r k; do [[ -n "$k" ]] && kubectl delete "$k" --dry-run=server; done <<<"$STALE"
    log "server-side dry run passed; nothing changed"
    exit 0 ;;
esac

# --- Apply ---------------------------------------------------------------------
(( COUNT > 0 )) && kubectl apply --server-side --field-manager="$MANAGER" -f "$RENDERED"
while read -r k; do [[ -n "$k" ]] && kubectl delete "$k" --ignore-not-found; done <<<"$STALE"
log "applied. To roll back: $0 ${ENV_NAME} --remove"
