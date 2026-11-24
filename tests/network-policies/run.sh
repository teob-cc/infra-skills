#!/usr/bin/env bash
# Checks `tools/k3s/network-policies.sh <env> --print` (INFRA-216) without a cluster: kubectl is a
# stand-in (stubs/kubectl) that answers from a fixture directory (fixtures/), and the environment
# is a fake (envs/fake: app namespaces "web" and "memory", tenant "acme").
#
# What it checks:
#   1. the render of a cluster without the cases below is unchanged: fixtures/plain equals
#      golden/plain.json, recorded from origin/main 8f7d8c3, byte for byte;
#   2. runner egress (gap 5): a node whose ExternalIP is private (192.168.1.50, a LAN worker) is
#      not allowed as "the node's public IP on 80/443", and stays inside the internet rule's
#      exceptions; the public server address keeps its 80/443 allow, and a private EXTERNAL_IP
#      in env.properties gets no allow either;
#   3. the CNPG operator (gap 1): a fenced app namespace that runs a CNPG cluster ("memory") gets
#      platform-allow-cnpg-operator: the operator pods of cnpg-system to the pods labelled
#      cnpg.io/cluster, on 8000 and 5432 only. A fenced namespace without one ("web"), the postgres
#      namespace (the operator is already admitted there) and an unfenced namespace ("other-db") get
#      none. The cluster is found from its pods alone when the Cluster CRD is absent, and from its
#      Cluster object alone when no pod runs yet.
#   4. pods with their own fence (INFRA-216 round 3): in fixtures/fences, the namespace-wide allows
#      of "web" and "memory" leave out every pod that a policy not managed here selects for
#      ingress (matchLabels, In and Exists selectors, two policies on one selector), and keep the
#      others; those pods stay under the default deny. Egress-only and managed policies, policies
#      outside the fenced namespaces and a namespace-wide policy (nexus) leave nothing out. --print
#      logs each exclusion and the pods it leaves out;
#   5. the run stops before anything is applied or deleted (a run without --print, so the stub
#      sees every apply) when: a fence's podSelector uses NotIn; a multi-label fence would leave out
#      a pod that no policy of its own selects; the API refuses the NetworkPolicy list, the CNPG
#      Cluster list (refused, not absent), the CNPG pod list or a fenced namespace's pod list. The
#      same run without a fault does apply.
#
# Usage: tests/network-policies/run.sh   (needs bash and jq). NP_SCRIPT=<path> runs another
#        network-policies.sh (for example origin/main's, in a checkout of that commit) against the
#        same checks.
# The bash -c snippets below get their values as arguments; $1 in single quotes is meant.
# shellcheck disable=SC2016
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="${NP_SCRIPT:-$REPO/tools/k3s/network-policies.sh}"
command -v jq >/dev/null 2>&1 || { echo "Missing: jq" >&2; exit 1; }
WORK="$(mktemp -d -t netpol-test-XXXX)"
export KUBECONFIG=/dev/null PATH="$HERE/stubs:$PATH" INFRA_ENVS_ROOT="$HERE/envs"
unset NETPOL_SKIP_NAMESPACES NETPOL_RUNNER_EGRESS_DENY NETPOL_POSTGRES_CLIENT_NAMESPACES \
      NETPOL_MINIO_CLIENT_NAMESPACES NETPOL_TENANT_MINIO STUB_NO_CNPG_CRD TEST_EXTERNAL_IP

failures=0
ok() { echo "ok    $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { # <description> <command...>
  local d="$1"; shift
  if "$@"; then ok "$d"; else fail "$d"; fi
}

render() { # render <name> <fixture dir> [VAR=value ...] -> $WORK/<name>.json (stderr: $WORK/<name>.err)
  local name=$1 fixture=$2; shift 2
  if ! env STUB_DIR="$HERE/fixtures/$fixture" STUB_LOG="$WORK/$name.log" "$@" \
      bash "$SCRIPT" fake --print >"$WORK/$name.json" 2>"$WORK/$name.err"; then
    echo "network-policies.sh failed for $name:" >&2; cat "$WORK/$name.err" >&2
    echo '{"items":[]}' >"$WORK/$name.json"
    return 1
  fi
}
pol() { # pol <render> <namespace> <name> -> the policy's JSON, or nothing
  jq -c --arg ns "$2" --arg n "$3" '.items[] | select(.metadata.namespace == $ns and .metadata.name == $n)' "$WORK/$1.json"
}
egress() { pol "$1" actions-runner-system platform-runner-egress; }
# cidrs a runner may reach on a port-limited rule (the "public IP on 80/443" allow)
allowed_blocks() { egress "$1" | jq -r '.spec.egress[] | select(.ports) | .to[] | .ipBlock.cidr // empty'; }
excepted() { egress "$1" | jq -r '.spec.egress[] | .to[] | .ipBlock | select(.cidr == "0.0.0.0/0") | .except[]'; }
covered_by_except() { # <render> <ip>: inside one of the internet rule's exceptions
  local r=$1 ip=$2 c
  for c in $(excepted "$r"); do
    jq -en --arg c "$c" --arg ip "$ip" '
      def n: split(".") | map(tonumber) | .[0] * 16777216 + .[1] * 65536 + .[2] * 256 + .[3];
      ($c | split("/")) as [$net, $len] | ($len | tonumber) as $l
      | (if $l == 0 then 0 else (pow(2; 32) - pow(2; 32 - $l)) end) as $m
      | (($net | n) - (($net | n) % pow(2; 32 - $l))) == (($ip | n) - (($ip | n) % pow(2; 32 - $l)))' >/dev/null && return 0
  done
  return 1
}

# --- 1. unchanged render --------------------------------------------------------------------
render plain plain || fail "plain render ran"
check "plain cluster: render equals golden/plain.json (origin/main 8f7d8c3)" \
  cmp -s "$WORK/plain.json" "$HERE/golden/plain.json"

# --- 2. runner egress -----------------------------------------------------------------------
render lan lan-worker || fail "lan-worker render ran"
check "runner egress: the public server address keeps its 80/443 allow" \
  bash -c '[[ "$1" == *"203.0.113.10/32"* ]]' _ "$(allowed_blocks lan)"
check "runner egress: no 80/443 allow to the LAN worker's private ExternalIP 192.168.1.50" \
  bash -c '[[ "$1" != *"192.168.1.50"* ]]' _ "$(allowed_blocks lan)"
check "runner egress: every allowed 80/443 address is outside RFC 1918, CGNAT, link-local and loopback" \
  bash -c 'for c in $1; do case "$c" in 10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|169.254.*|127.*) exit 1;; esac; done' _ "$(allowed_blocks lan)"
check "runner egress: 192.168.1.50 stays inside the internet rule's exceptions" covered_by_except lan 192.168.1.50
check "runner egress: 203.0.113.10 stays inside the internet rule's exceptions" covered_by_except lan 203.0.113.10
render private-ext plain TEST_EXTERNAL_IP=10.1.2.3 || fail "private EXTERNAL_IP render ran"
check "runner egress: a private EXTERNAL_IP gets no 80/443 allow" \
  bash -c '[[ "$1" != *"10.1.2.3"* ]]' _ "$(allowed_blocks private-ext)"
check "runner egress: a private EXTERNAL_IP stays inside the exceptions" covered_by_except private-ext 10.1.2.3

# --- 3. CNPG operator in app namespaces -----------------------------------------------------
op_ok() { # <render> <ns>: the operator policy is exactly operator pods -> cnpg.io/cluster pods on 8000+5432
  pol "$1" "$2" platform-allow-cnpg-operator | jq -e '
    .spec.podSelector == {matchExpressions: [{key: "cnpg.io/cluster", operator: "Exists"}]}
    and .spec.policyTypes == ["Ingress"]
    and (.spec.ingress | length) == 1
    and .spec.ingress[0].from == [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": "cnpg-system"}},
                                  podSelector: {matchLabels: {"app.kubernetes.io/name": "cloudnative-pg"}}}]
    and (.spec.ingress[0].ports | map("\(.port)/\(.protocol)") | sort) == ["5432/TCP", "8000/TCP"]
    and .metadata.labels["app.kubernetes.io/managed-by"] == "infra-skills-network-policies"' >/dev/null
}
none() { [[ -z "$(pol "$1" "$2" platform-allow-cnpg-operator)" ]]; }
check "CNPG: fenced app namespace 'memory' admits the operator on 8000 and 5432" op_ok lan memory
check "CNPG: fenced app namespace 'web' (no CNPG cluster) gets no operator policy" none lan web
check "CNPG: the postgres namespace gets no extra operator policy" none lan postgres
check "CNPG: unfenced namespace 'other-db' gets nothing" none lan other-db
check "CNPG: 'memory' keeps its default deny" bash -c '[[ -n "$1" ]]' _ "$(pol lan memory platform-default-deny-ingress)"
render no-crd lan-worker STUB_NO_CNPG_CRD=1 || fail "render without the Cluster CRD ran"
check "CNPG: without the Cluster CRD, the cluster is found from its pods" op_ok no-crd memory
mkdir -p "$WORK/clusters-only"
cp "$HERE/fixtures/lan-worker/"{nodes.json,namespaces.txt,cnpg-clusters.json} "$WORK/clusters-only/"
# env applies its assignments in order, so this STUB_DIR replaces the fixture's
render clusters-only lan-worker STUB_DIR="$WORK/clusters-only" || fail "render with Cluster objects only ran"
check "CNPG: with no pod yet, the cluster is found from its Cluster object" op_ok clusters-only memory
check "CNPG: the plain cluster has no operator policy anywhere" \
  bash -c '[[ -z "$(jq -r ".items[] | select(.metadata.name == \"platform-allow-cnpg-operator\") | .metadata.namespace" "$1")" ]]' _ "$WORK/plain.json"

# --- 4. pods with their own fence -----------------------------------------------------------
GENERIC="platform-allow-same-namespace platform-allow-from-prometheus platform-allow-from-ingress-controller platform-allow-from-pomerium"
WEB_SEL='{"matchExpressions":[{"key":"app.kubernetes.io/instance","operator":"NotIn","values":["evse","portal"]},{"key":"app.kubernetes.io/name","operator":"NotIn","values":["evse","gw","portal"]},{"key":"tier","operator":"NotIn","values":["db"]}]}'
MEM_SEL='{"matchExpressions":[{"key":"fenced","operator":"DoesNotExist"}]}'
OBS_SEL='{"matchExpressions":[{"key":"app","operator":"NotIn","values":["mcp-grafana"]}]}'
all_generic() { # <render> <ns> <selector json>: every namespace-wide allow of <ns> has exactly this podSelector
  local p
  for p in $GENERIC; do
    pol "$1" "$2" "$p" | jq -e --argjson s "$3" '.spec.podSelector == $s' >/dev/null || return 1
  done
}
# shellcheck disable=SC2016  # a jq function
MATCH='def matches($sel): (.metadata.labels // {}) as $l
  | all(($sel.matchLabels // {}) | to_entries[]; $l[.key] == .value)
  and all(($sel.matchExpressions // [])[]; . as $e | ($l[$e.key]) as $v
    | if $e.operator == "In" then $v != null and any($e.values[]; . == $v)
      elif $e.operator == "NotIn" then $v == null or all($e.values[]; . != $v)
      elif $e.operator == "Exists" then $v != null else $v == null end);'
selected_pods() { # <render> <ns> <policy> <pods file>: the names of the pods that policy selects
  jq -r --argjson sel "$(pol "$1" "$2" "$3" | jq -c '.spec.podSelector')" "$MATCH"' [.items[] | select(matches($sel)) | .metadata.name] | join(" ")' "$4"
}
render fences fences || fail "fences render ran"
check "fences: every namespace-wide allow of 'web' leaves out the fenced pods (evse x2, portal, gw, tier In db)" all_generic fences web "$WEB_SEL"
check "fences: every namespace-wide allow of 'memory' leaves out the pods of an Exists fence" all_generic fences memory "$MEM_SEL"
check "fences: observability keeps its mcp-grafana exclusion, merged with its live policy" all_generic fences observability "$OBS_SEL"
check "fences: nexus (a namespace-wide extra allow) leaves nothing out" all_generic fences nexus '{}'
check "fences: in 'web' the allows select exactly storeback-1 and cron-1 (egress-only and managed policies leave nothing out)" \
  bash -c '[[ "$1" == "storeback-1 cron-1" ]]' _ "$(selected_pods fences web platform-allow-same-namespace "$HERE/fixtures/fences/pods-web.json")"
check "fences: in 'web' the default deny still selects every pod" \
  bash -c '[[ "$1" == "evse-1 portal-1 gw-1 db-0 storeback-1 cron-1" ]]' _ "$(selected_pods fences web platform-default-deny-ingress "$HERE/fixtures/fences/pods-web.json")"
check "fences: the log names the pods 'web' leaves out" grep -qF "web: pods left out of the allows: evse-1 portal-1 gw-1 db-0" "$WORK/fences.err"
check "fences: the log names each fence of 'web'" bash -c 'for p in evse-from-pomerium-only evse-from-comparator portal gw-ingress db-fence; do grep -qF "web: allows leave out the pods of $p (" "$1" || exit 1; done' _ "$WORK/fences.err"
check "fences: the log names nexus/vpn-allow as left alone" grep -qF "nexus/vpn-allow selects every pod of its namespace" "$WORK/fences.err"

# --- 5. the run stops before it applies -----------------------------------------------------
run_apply() { # run_apply <name> <fixture dir> [VAR=value ...]: a run without --print; rc in $WORK/<name>.rc
  local name=$1 fixture=$2 rc=0; shift 2
  env STUB_DIR="$HERE/fixtures/$fixture" STUB_LOG="$WORK/$name.log" "$@" \
    bash "$SCRIPT" fake >"$WORK/$name.out" 2>"$WORK/$name.err" || rc=$?
  echo "$rc" >"$WORK/$name.rc"
}
stopped() { # <name> <text>: non-zero exit, <text> in stderr, no apply or delete reached kubectl
  [[ "$(cat "$WORK/$1.rc")" != 0 ]] && grep -qF -- "$2" "$WORK/$1.err" && ! grep -qE '^kubectl (apply|delete|-n [^ ]+ delete) ' "$WORK/$1.log"
}
run_apply apply-ok fences
check "stop: the fences run without a fault applies (so the checks below can see an apply)" \
  bash -c '[[ "$(cat "$1.rc")" == 0 ]] && grep -qE "^kubectl apply " "$1.log"' _ "$WORK/apply-ok"
mkdir -p "$WORK/notin" "$WORK/orphan"
cp "$HERE/fixtures/fences/"* "$WORK/notin/"; cp "$HERE/fixtures/fences/"* "$WORK/orphan/"
jq '.items += [{metadata: {namespace: "web", name: "notin-fence", labels: {}},
  spec: {podSelector: {matchExpressions: [{key: "tier", operator: "NotIn", values: ["web"]}]}, policyTypes: ["Ingress"], ingress: [{}]}}]' \
  "$HERE/fixtures/fences/netpols.json" >"$WORK/notin/netpols.json"
jq '.items += [{metadata: {name: "evse-tool-1", labels: {"app.kubernetes.io/instance": "tools", "app.kubernetes.io/name": "evse"}}}]' \
  "$HERE/fixtures/fences/pods-web.json" >"$WORK/orphan/pods-web.json"
run_apply notin fences STUB_DIR="$WORK/notin"
check "stop: a fence selector with NotIn stops the run, nothing applied" stopped notin "web/notin-fence: its podSelector uses NotIn or DoesNotExist"
run_apply orphan fences STUB_DIR="$WORK/orphan"
check "stop: a pod left out by a multi-label fence that no policy selects stops the run, nothing applied" stopped orphan "web: pods evse-tool-1 would lose"
run_apply forbid-np fences STUB_FAIL="get networkpolicies -A"
check "stop: a refused NetworkPolicy list stops the run, nothing applied" stopped forbid-np "could not read NetworkPolicies"
run_apply forbid-cluster lan-worker STUB_FAIL="clusters.postgresql.cnpg.io"
check "stop: a refused CNPG Cluster list (not an absent CRD) stops the run, nothing applied" stopped forbid-cluster "could not read CNPG Cluster objects"
run_apply forbid-cnpg-pods lan-worker STUB_FAIL="-l cnpg.io/cluster"
check "stop: a refused CNPG pod list stops the run, nothing applied" stopped forbid-cnpg-pods "could not read pods labelled cnpg.io/cluster"
run_apply forbid-pods fences STUB_FAIL="-n web get pods"
check "stop: a refused pod list of a fenced namespace stops the run, nothing applied" stopped forbid-pods "could not read pods in web"
run_apply no-crd-apply lan-worker STUB_NO_CNPG_CRD=1
check "stop: an absent CNPG CRD does not stop the run" bash -c '[[ "$(cat "$1")" == 0 ]]' _ "$WORK/no-crd-apply.rc"

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed (work dir: $WORK)"
  exit 1
fi
echo "all checks passed"
rm -rf "$WORK"
