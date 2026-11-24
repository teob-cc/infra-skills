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
#   4. pods with their own fence (INFRA-216 rounds 3 and 4): in fixtures/fences, the namespace-wide
#      allows of "web" and "memory" leave out every pod that a policy not managed here selects for
#      ingress (matchLabels, In and Exists selectors, two policies on one selector), and select
#      every other pod: over all 60 combinations of the labels the "web" fences use, each allow
#      (all its policies together) selects a pod exactly when no fence does, so a later pod that
#      shares one label with a two-label fence keeps its allows. The policies do not depend on the
#      pods running. Egress-only and managed policies, policies outside the fenced namespaces and a
#      namespace-wide policy (nexus) leave nothing out. --print logs each exclusion and the pods it
#      leaves out;
#   5. the run stops before anything is applied or deleted (a run without --print, so the stub
#      sees every apply) when: a fence's podSelector uses NotIn; the fences need more selectors
#      than NETPOL_MAX_ALLOW_SELECTORS; the API refuses the NetworkPolicy list, the CNPG pod list or
#      a fenced namespace's pod list. The same run without a fault does apply;
#   6. CNPG discovery: the Cluster CRD is absent only on NotFound for its raw path; a refused CRD
#      read, a refused Cluster list, or a Cluster list that fails on a discovery timeout followed by
#      "the server doesn't have a resource type" stops the run, so the operator allow is not pruned;
#   7. --remove reads only the managed policies: a fence the render refuses or a failing CNPG read
#      does not block it, --only/--plan/--dry-run=server hold, a refused managed list stops it;
#   8. ServiceCIDR and the traefik Service fall back (k3s defaults) only on NotFound; a refused read
#      of either, of the Traefik pods or of the kubernetes Service stops the run.
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
MEM_SEL='{"matchExpressions":[{"key":"fenced","operator":"DoesNotExist"}]}'
OBS_SEL='{"matchExpressions":[{"key":"app","operator":"NotIn","values":["mcp-grafana"]}]}'
# The fences of 'web' in fixtures/fences (evse twice, portal, gw, tier In db), and the 'web' policy
# selectors they need: not (instance=evse and name=evse), not (instance=portal and name=portal), not gw,
# not tier=db, written out as a union.
WEB_FENCES='[{"matchLabels":{"app.kubernetes.io/instance":"evse","app.kubernetes.io/name":"evse"}},
  {"matchLabels":{"app.kubernetes.io/instance":"portal","app.kubernetes.io/name":"portal"}},
  {"matchLabels":{"app.kubernetes.io/name":"gw"}}, {"matchExpressions":[{"key":"tier","operator":"In","values":["db"]}]}]'
generic_sels() { # <render> <ns> <allow>: the podSelectors of <allow>, <allow>-2, ... in <ns>, as a JSON array
  jq -c --arg ns "$2" --arg n "$3" '[.items[] | select(.metadata.namespace == $ns)
    | select(.metadata.name | test("^" + $n + "(-[0-9]+)?$")) | .spec.podSelector] | sort' "$WORK/$1.json"
}
all_generic() { # <render> <ns> <selector json>...: every namespace-wide allow of <ns> has exactly these podSelectors
  local r=$1 ns=$2 p want; shift 2
  want=$(printf '%s\n' "$@" | jq -sc 'sort')
  for p in $GENERIC; do
    [[ "$(generic_sels "$r" "$ns" "$p")" == "$want" ]] || return 1
  done
}
# shellcheck disable=SC2016  # a jq function
MATCH='def matches($sel): (.metadata.labels // {}) as $l
  | all(($sel.matchLabels // {}) | to_entries[]; $l[.key] == .value)
  and all(($sel.matchExpressions // [])[]; . as $e | ($l[$e.key]) as $v
    | if $e.operator == "In" then $v != null and any($e.values[]; . == $v)
      elif $e.operator == "NotIn" then $v == null or all($e.values[]; . != $v)
      elif $e.operator == "Exists" then $v != null else $v == null end);'
selected_pods() { # <render> <ns> <allow> <pods file>: the pods that <allow> (all its policies) selects
  jq -r --argjson sels "$(generic_sels "$1" "$2" "$3")" "$MATCH"'
    [.items[] | select(. as $p | any($sels[]; . as $s | $p | matches($s))) | .metadata.name] | join(" ")' "$4"
}
# Every combination of the labels the 'web' fences use (absent, a fenced value, another value): 60 pods.
jq -n '[([null, "evse", "portal", "tools"][]) as $i | ([null, "evse", "portal", "gw", "tools"][]) as $n | ([null, "db", "web"][]) as $t
  | {metadata: {name: "i=\($i)/n=\($n)/t=\($t)", labels: ({"app.kubernetes.io/instance": $i, "app.kubernetes.io/name": $n, tier: $t}
      | with_entries(select(.value != null)))}}] | {items: .}' >"$WORK/web-label-space.json"
exact_complement() { # <render>: in 'web', each allow selects exactly the pods that no fence selects
  local p
  for p in $GENERIC; do
    jq -e --argjson sels "$(generic_sels "$1" web "$p")" --argjson fences "$WEB_FENCES" "$MATCH"'
      [.items[] | . as $pod | (any($sels[]; . as $s | $pod | matches($s))) != (any($fences[]; . as $f | $pod | matches($f)) | not)
       | select(.)] | length == 0' "$WORK/web-label-space.json" >/dev/null || return 1
  done
}
render fences fences || fail "fences render ran"
check "fences: in 'web', each allow selects exactly the pods no fence selects (60 label combinations)" exact_complement fences
jq -n '{items: [{metadata: {name: "evse-tool-1", labels: {"app.kubernetes.io/instance": "tools", "app.kubernetes.io/name": "evse"}}}]}' >"$WORK/tools-pod.json"
tools_pod_allowed() { local p; for p in $GENERIC; do [[ "$(selected_pods fences web "$p" "$WORK/tools-pod.json")" == evse-tool-1 ]] || return 1; done; }
check "fences: in 'web', a later pod name=evse, instance=tools (no fence selects it) gets all four allows" tools_pod_allowed
check "fences: in 'web', every allow has the same 4 selectors (2 two-label fences: 2 x 2)" \
  bash -c 's=""; for p in $2; do t=$(jq -c --arg ns web --arg n "$p" "[.items[] | select(.metadata.namespace == \$ns) | select(.metadata.name | test(\"^\" + \$n + \"(-[0-9]+)?\$\")) | .spec.podSelector] | sort" "$1"); [[ $(jq length <<<"$t") == 4 ]] || exit 1; [[ -z "$s" || "$s" == "$t" ]] || exit 1; s=$t; done' _ "$WORK/fences.json" "$GENERIC"
mkdir -p "$WORK/no-pods"; cp "$HERE/fixtures/fences/"* "$WORK/no-pods/"; rm "$WORK/no-pods/pods-web.json"
render no-pods fences STUB_DIR="$WORK/no-pods" || fail "fences render without the pods of 'web' ran"
check "fences: the policies of 'web' do not depend on the pods running there" \
  bash -c '[[ "$(jq -c "[.items[] | select(.metadata.namespace == \"web\")]" "$1")" == "$(jq -c "[.items[] | select(.metadata.namespace == \"web\")]" "$2")" ]]' _ "$WORK/fences.json" "$WORK/no-pods.json"
check "fences: every namespace-wide allow of 'memory' leaves out the pods of an Exists fence" all_generic fences memory "$MEM_SEL"
check "fences: observability keeps its mcp-grafana exclusion, merged with its live policy" all_generic fences observability "$OBS_SEL"
check "fences: nexus (a namespace-wide extra allow) leaves nothing out" all_generic fences nexus '{}'
check "fences: single-selector namespaces keep the plain policy names (no -2)" \
  bash -c '[[ -z "$(jq -r ".items[] | select(.metadata.namespace != \"web\") | .metadata.name | select(test(\"-[0-9]+\$\"))" "$1")" ]]' _ "$WORK/fences.json"
check "fences: in 'web' the allows select exactly storeback-1 and cron-1 (egress-only and managed policies leave nothing out)" \
  bash -c '[[ "$1" == "storeback-1 cron-1" ]]' _ "$(selected_pods fences web platform-allow-same-namespace "$HERE/fixtures/fences/pods-web.json")"
check "fences: in 'web' the default deny still selects every pod" \
  bash -c '[[ "$1" == "evse-1 portal-1 gw-1 db-0 storeback-1 cron-1" ]]' _ "$(selected_pods fences web platform-default-deny-ingress "$HERE/fixtures/fences/pods-web.json")"
check "fences: the log names the pods 'web' leaves out" grep -qF "web: pods left out of the allows: evse-1 portal-1 gw-1 db-0" "$WORK/fences.err"
check "fences: the log names each fence of 'web'" bash -c 'for p in evse-from-pomerium-only evse-from-comparator portal gw-ingress db-fence; do grep -qF "web: allows leave out the pods of $p (" "$1" || exit 1; done' _ "$WORK/fences.err"
check "fences: the log names nexus/vpn-allow as left alone" grep -qF "nexus/vpn-allow selects every pod of its namespace" "$WORK/fences.err"

# --- 5. the run stops before it applies -----------------------------------------------------
run_apply() { # run_apply <name> <fixture dir> [VAR=value ...] [-- <options>]: a run without --print; rc in $WORK/<name>.rc
  local name=$1 fixture=$2 rc=0 vars=(); shift 2
  while (( $# > 0 )) && [[ "$1" != -- ]]; do vars+=("$1"); shift; done
  [[ "${1:-}" == -- ]] && shift
  env STUB_DIR="$HERE/fixtures/$fixture" STUB_LOG="$WORK/$name.log" ${vars[@]+"${vars[@]}"} \
    bash "$SCRIPT" fake "$@" >"$WORK/$name.out" 2>"$WORK/$name.err" || rc=$?
  echo "$rc" >"$WORK/$name.rc"
}
mutated() { grep -qE '^kubectl (apply|delete|-n [^ ]+ delete) ' "$WORK/$1.log"; }
stopped() { # <name> <text>: non-zero exit, <text> in stderr, no apply or delete reached kubectl
  [[ "$(cat "$WORK/$1.rc")" != 0 ]] && grep -qF -- "$2" "$WORK/$1.err" && ! mutated "$1"
}
ran() { [[ "$(cat "$WORK/$1.rc")" == 0 ]] && grep -qE '^kubectl apply ' "$WORK/$1.log"; }
run_apply apply-ok fences
check "stop: the fences run without a fault applies (so the checks below can see an apply)" ran apply-ok
mkdir -p "$WORK/notin" "$WORK/later-pod"
cp "$HERE/fixtures/fences/"* "$WORK/notin/"; cp "$HERE/fixtures/fences/"* "$WORK/later-pod/"
jq '.items += [{metadata: {namespace: "web", name: "notin-fence", labels: {}},
  spec: {podSelector: {matchExpressions: [{key: "tier", operator: "NotIn", values: ["web"]}]}, policyTypes: ["Ingress"], ingress: [{}]}}]' \
  "$HERE/fixtures/fences/netpols.json" >"$WORK/notin/netpols.json"
jq '.items += [{metadata: {name: "evse-tool-1", labels: {"app.kubernetes.io/instance": "tools", "app.kubernetes.io/name": "evse"}}}]' \
  "$HERE/fixtures/fences/pods-web.json" >"$WORK/later-pod/pods-web.json"
run_apply notin fences STUB_DIR="$WORK/notin"
check "stop: a fence selector with NotIn stops the run, nothing applied" stopped notin "web/notin-fence: its podSelector uses NotIn or DoesNotExist"
run_apply later-pod fences STUB_DIR="$WORK/later-pod"
check "fences: a running pod that shares one label with a two-label fence does not stop the run" ran later-pod
check "fences: ... and the allows keep it (not in the left-out pods)" grep -qF "web: pods left out of the allows: evse-1 portal-1 gw-1 db-0" "$WORK/later-pod.err"
run_apply cap fences NETPOL_MAX_ALLOW_SELECTORS=3
check "stop: fences that need more selectors than NETPOL_MAX_ALLOW_SELECTORS stop the run, nothing applied" \
  stopped cap "web: its fences need 4 selectors for the namespace-wide allows"
run_apply cap-ok fences NETPOL_MAX_ALLOW_SELECTORS=4
check "fences: at the cap the run applies" ran cap-ok
run_apply forbid-np fences STUB_FAIL="get networkpolicies -A"
check "stop: a refused NetworkPolicy list stops the run, nothing applied" stopped forbid-np "could not read NetworkPolicies"
run_apply forbid-cnpg-pods lan-worker STUB_FAIL="-l cnpg.io/cluster"
check "stop: a refused CNPG pod list stops the run, nothing applied" stopped forbid-cnpg-pods "could not read pods labelled cnpg.io/cluster"
run_apply forbid-pods fences STUB_FAIL="-n web get pods"
check "stop: a refused pod list of a fenced namespace stops the run, nothing applied" stopped forbid-pods "could not read pods in web"

# --- 6. CNPG discovery: absent only on NotFound for the CRD by name --------------------------
# fixture: a Cluster object in 'memory', no CNPG pod yet, and a managed operator allow already there
mkdir -p "$WORK/cnpg-live"
cp "$WORK/clusters-only/"* "$WORK/cnpg-live/"
jq -n '{items: [{metadata: {namespace: "memory", name: "platform-allow-cnpg-operator",
  labels: {"app.kubernetes.io/managed-by": "infra-skills-network-policies"}}}]}' >"$WORK/cnpg-live/managed.json"
run_apply cnpg-live lan-worker STUB_DIR="$WORK/cnpg-live"
check "CNPG: without a fault, the existing operator allow stays (rendered, not deleted)" \
  bash -c '[[ "$(cat "$1.rc")" == 0 ]] && ! grep -q "delete networkpolicy platform-allow-cnpg-operator" "$1.log"' _ "$WORK/cnpg-live"
run_apply cnpg-partial lan-worker STUB_DIR="$WORK/cnpg-live" STUB_CNPG_DISCOVERY_TIMEOUT=1
check "stop: a discovery timeout + \"doesn't have a resource type\" on the Cluster list stops the run, operator allow not pruned" \
  stopped cnpg-partial "could not read CNPG Cluster objects"
run_apply forbid-cluster lan-worker STUB_FAIL="get clusters.postgresql.cnpg.io"
check "stop: a refused CNPG Cluster list (not an absent CRD) stops the run, nothing applied" stopped forbid-cluster "could not read CNPG Cluster objects"
run_apply forbid-crd lan-worker STUB_FAIL="customresourcedefinitions/clusters.postgresql.cnpg.io"
check "stop: a refused read of the Cluster CRD by name stops the run, nothing applied" stopped forbid-crd "could not read the CNPG Cluster CRD"
run_apply no-crd-apply lan-worker STUB_NO_CNPG_CRD=1
check "CNPG: an absent Cluster CRD (NotFound by name) does not stop the run" ran no-crd-apply
check "CNPG: ... and the Cluster list is not read" bash -c '! grep -q "get clusters.postgresql.cnpg.io" "$1"' _ "$WORK/no-crd-apply.log"

# --- 7. --remove: the managed policies only ---------------------------------------------------
# fixture: fences plus a DoesNotExist fence in 'web' (a render would stop), and managed policies in
# 'web' and 'memory'
mkdir -p "$WORK/remove"
cp "$HERE/fixtures/fences/"* "$WORK/remove/"
jq '.items += [{metadata: {namespace: "web", name: "dne-fence", labels: {}},
  spec: {podSelector: {matchExpressions: [{key: "tier", operator: "DoesNotExist"}]}, policyTypes: ["Ingress"], ingress: [{}]}}]' \
  "$HERE/fixtures/fences/netpols.json" >"$WORK/remove/netpols.json"
jq -n '{items: ([["web", "platform-default-deny-ingress"], ["web", "platform-allow-same-namespace-2"], ["memory", "platform-default-deny-ingress"]]
  | map({metadata: {namespace: .[0], name: .[1], labels: {"app.kubernetes.io/managed-by": "infra-skills-network-policies"}}}))}' \
  >"$WORK/remove/managed.json"
removed() { # <name> <ns/name>...: rc 0 and exactly these deletes reached kubectl
  local n=$1; shift
  [[ "$(cat "$WORK/$n.rc")" == 0 ]] || return 1
  [[ "$(sed -n 's/^kubectl -n \([^ ]*\) delete networkpolicy \([^ ]*\) .*/\1\/\2/p' "$WORK/$n.log" | sort)" == "$(printf '%s\n' "$@" | sort)" ]]
}
run_apply remove-web fences STUB_DIR="$WORK/remove" -- --remove --only web
check "remove: a fence the render refuses (DoesNotExist) does not block --remove --only web" \
  removed remove-web web/platform-default-deny-ingress web/platform-allow-same-namespace-2
check "remove: no discovery, no render reads (nodes, CNPG, NetworkPolicy list, pods, raw paths)" \
  bash -c '! grep -qE "get nodes|clusters|cnpg|get networkpolicies|get pods|--raw|get svc|get ns" "$1"' _ "$WORK/remove-web.log"
run_apply remove-faults fences STUB_DIR="$WORK/remove" STUB_FAIL="clusters.postgresql.cnpg.io" -- --remove
check "remove: a failing CNPG read does not block --remove (all namespaces)" \
  removed remove-faults web/platform-default-deny-ingress web/platform-allow-same-namespace-2 memory/platform-default-deny-ingress
run_apply remove-plan fences STUB_DIR="$WORK/remove" -- --remove --plan
check "remove: --remove --plan lists and deletes nothing" \
  bash -c '[[ "$(cat "$1.rc")" == 0 ]] && grep -qF "  - memory/platform-default-deny-ingress" "$1.err" && ! grep -q " delete " "$1.log"' _ "$WORK/remove-plan"
run_apply remove-dry fences STUB_DIR="$WORK/remove" -- --remove --dry-run=server
check "remove: --remove --dry-run=server deletes only as a server-side dry run" \
  bash -c '[[ "$(cat "$1.rc")" == 0 ]] && grep -q " delete networkpolicy .* --dry-run=server" "$1.log" && ! grep " delete " "$1.log" | grep -qv -- "--dry-run=server"' _ "$WORK/remove-dry"
run_apply remove-forbid fences STUB_DIR="$WORK/remove" STUB_FAIL="get networkpolicy -A -l" -- --remove
check "stop: --remove with a refused managed-policy list stops, nothing deleted" stopped remove-forbid "could not read the managed NetworkPolicies"

# --- 8. ServiceCIDR and Traefik: fallback on NotFound only ------------------------------------
render no-svc-objects plain STUB_NO_SERVICECIDR=1 STUB_NO_TRAEFIK_SVC=1 || fail "render without ServiceCIDR and traefik Service ran"
check "fallback: no ServiceCIDR and no traefik Service (NotFound): the k3s defaults, render equals golden/plain.json" \
  cmp -s "$WORK/no-svc-objects.json" "$HERE/golden/plain.json"
check "fallback: ... and the log says why" \
  bash -c 'grep -qF "no ServiceCIDR kubernetes (NotFound)" "$1" && grep -qF "no Service kube-system/traefik (NotFound)" "$1"' _ "$WORK/no-svc-objects.err"
run_apply forbid-scidr plain STUB_FAIL="servicecidrs"
check "stop: a refused ServiceCIDR read stops the run (no fallback), nothing applied" stopped forbid-scidr "could not read the ServiceCIDR kubernetes"
run_apply forbid-traefik-svc plain STUB_FAIL="get svc traefik"
check "stop: a refused traefik Service read stops the run (no fallback), nothing applied" stopped forbid-traefik-svc "could not read the Service kube-system/traefik"
run_apply forbid-traefik-pods plain STUB_FAIL="-l app.kubernetes.io/name=traefik"
check "stop: a refused Traefik pod list stops the run, nothing applied" stopped forbid-traefik-pods "could not read the Traefik pods"
run_apply forbid-k8s-svc plain STUB_FAIL="get svc kubernetes"
check "stop: a refused read of the kubernetes Service stops the run, nothing applied" stopped forbid-k8s-svc "could not read the kubernetes Service"
echo
if (( failures > 0 )); then
  echo "$failures check(s) failed (work dir: $WORK)"
  exit 1
fi
echo "all checks passed"
rm -rf "$WORK"
