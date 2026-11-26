#!/usr/bin/env bash
# Checks the Pomerium route helpers of tools/provision-common.sh (provision::pomerium_routes_add,
# provision::pomerium_routes_add_for_groups, provision::_pomerium_routes_upsert,
# provision::pomerium_routes_remove) and ensure_grafana_pomerium of tools/k3s/observability.sh
# (INFRA-253) without a cluster: kubectl is a stand-in (stubs/) that logs every call, the
# environment is a temp envs/fake with a routes file copied from fixtures/.
#
# What it checks:
#   1. a new route is what origin/main 2c39306 wrote, byte for byte, for every caller's shape
#      (argocd/nexus/kafka/scylla/mysql, wireguard's defaults, pgweb/amneziawg groups, Grafana
#      with and without GRAFANA_FRAME_ANCESTORS), and Pomerium is reloaded;
#   2. an existing route keeps its access fields (policy) and every key the caller does not set
#      (timeout, other response headers), its place in the file and the comments: Grafana's
#      route, and argocd's route through pomerium_routes_add;
#   3. GRAFANA_ALLOWED_GROUPS: rendered as one claim/groups per entry (blanks trimmed), written
#      over an existing allow_any_authenticated_user; the same groups as the file's policy change
#      nothing; provision::pomerium_groups_valid accepts and refuses the right values, and
#      observability.sh checks the property before any cluster call;
#   4. path routes on the same host (Grafana's /mcp prefix route) and other hosts' routes are
#      untouched in every case; a stale duplicate catch-all is dropped;
#   5. a run that leaves the file as it was writes nothing (bytes and mode) and makes no reload
#      call (no pomerium-config read or write, no rollout restart); the same for
#      pomerium_routes_remove of a host without a route; a second identical run is a no-op;
#   6. GRAFANA_FRAME_ANCESTORS set then unset: the CSP header comes and goes, other response
#      headers stay;
#   7. pomerium_routes_add_for_groups (pgweb, amneziawg) still replaces the access of an existing
#      route (a changed PGWEB_ALLOWED_GROUPS lands) and now keeps its other keys.
#
# Usage: tests/pomerium-routes/run.sh        (needs bash, jq, yq v4, git for check 1)
# The helpers run in subshells on purpose (each case its own PATH, STUB_LOG and envs root), and the
# single-quoted $ are jq variables.
# shellcheck disable=SC2016,SC2030,SC2031
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
for tool in jq yq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing: $tool" >&2; exit 1; }
done
WORK="$(mktemp -d -t pomerium-routes-test-XXXX)"
trap 'rm -rf "$WORK"' EXIT
BASE_COMMIT=2c39306

failures=0
ok() { echo "ok    $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { # <description> <command...>
  local what="$1"; shift
  if "$@"; then ok "$what"; else fail "$what"; fi
}

G=https://grafana.fake.example.test
GTO=http://grafana.observability.svc.cluster.local:80

# setup <case> <fixture file|none>: a fresh envs/fake for one case
setup() {
  local dir="$WORK/$1"
  mkdir -p "$dir/envs/fake"
  [[ "$2" == none ]] || cp "$HERE/fixtures/$2" "$dir/envs/fake/pomerium-routes.yaml"
  : > "$dir/kubectl.log"
}
routes_file() { echo "$WORK/$1/envs/fake/pomerium-routes.yaml"; }

# run_common <case> <common.sh> <function> <args...>: one helper call against the stand-ins
run_common() {
  local dir="$WORK/$1" common="$2"; shift 2
  ( export PATH="$HERE/stubs:$PATH" STUB_LOG="$dir/kubectl.log" INFRA_ENVS_ROOT="$dir/envs" ENV_NAME=fake
    # shellcheck disable=SC1090
    source "$common"
    "$@" ) >>"$dir/output.txt" 2>&1
}
run_new() { local c="$1"; shift; run_common "$c" "$REPO/tools/provision-common.sh" "$@"; }

# grafana <case> <GRAFANA_ALLOWED_GROUPS> <grafana_frame_csp>: ensure_grafana_pomerium as
# observability.sh defines it, with the variables the script would have set
GRAFANA_FN="$WORK/ensure_grafana_pomerium.sh"
sed -n '/^ensure_grafana_pomerium() {$/,/^}$/p' "$REPO/tools/k3s/observability.sh" > "$GRAFANA_FN"
[[ -s "$GRAFANA_FN" ]] || { echo "ensure_grafana_pomerium not found in observability.sh" >&2; exit 1; }
grafana() {
  local dir="$WORK/$1"
  # The variables and log helpers are read by the sourced ensure_grafana_pomerium.
  # shellcheck disable=SC2034,SC2329
  ( export PATH="$HERE/stubs:$PATH" STUB_LOG="$dir/kubectl.log" INFRA_ENVS_ROOT="$dir/envs" ENV_NAME=fake
    # shellcheck disable=SC1091
    source "$REPO/tools/provision-common.sh"
    log() { echo "[observability] $*"; }
    info() { echo "[observability:info] $*"; }
    warn() { echo "[observability:warn] $*" >&2; }
    GRAFANA_HOST=grafana.fake.example.test NAMESPACE_SSO=sso NAMESPACE_OBSERVABILITY=observability
    CLUSTER_ISSUER=letsencrypt INGRESS_CLASS=traefik
    GRAFANA_ALLOWED_GROUPS="$2" grafana_frame_csp="$3"
    # shellcheck disable=SC1090
    source "$GRAFANA_FN"
    ensure_grafana_pomerium ) >>"$dir/output.txt" 2>&1
}

# catch_all <case> <from>: the first catch-all route of <from>, as compact JSON ("null" if none)
catch_all() {
  yq -o=json -I=0 '.config.routes // []' "$(routes_file "$1")" |
    jq -c --arg f "$2" '[.[] | select(.from == $f and (has("prefix") or has("path") or has("regex") | not))][0]'
}
# others <case|file>: every route except Grafana's catch-all routes, in order
others_of() {
  yq -o=json -I=0 '.config.routes // []' "$1" |
    jq -c --arg f "$G" '[.[] | select(.from != $f or has("prefix") or has("path") or has("regex"))]'
}
reloaded() { grep -q "rollout restart" "$WORK/$1/kubectl.log"; }
no_reload_calls() { ! grep -qE "pomerium-config|rollout|create secret" "$WORK/$1/kubectl.log"; }
jqe() { jq -e "$@" >/dev/null; }   # jq -e, quiet: for check
json_eq() { [[ "$(jq -cS . <<<"$1")" == "$(jq -cS . <<<"$2")" ]]; }

# --- 1. new routes: as origin/main made them -------------------------------------------------
OLD_COMMON="$WORK/provision-common.${BASE_COMMIT}.sh"
if git -C "$REPO" show "${BASE_COMMIT}:tools/provision-common.sh" > "$OLD_COMMON" 2>/dev/null; then
  csp="frame-ancestors 'self' https://portal.example.test"
  csp_extra=$(jq -cn --arg c "$csp" '{set_response_headers: {"Content-Security-Policy": $c}}')
  # <name> <old call...> -- <new call...>; "grafana" as the new call runs ensure_grafana_pomerium
  fresh_same() {
    local name="$1"; shift
    local old=() new=()
    while [[ "$1" != "--" ]]; do old+=("$1"); shift; done
    shift; new=("$@")
    for fx in none empty; do
      setup "fresh-$name-$fx-old" none; setup "fresh-$name-$fx-new" none
      if [[ "$fx" == empty ]]; then
        printf 'config:\n  routes: []\n' > "$(routes_file "fresh-$name-$fx-old")"
        printf 'config:\n  routes: []\n' > "$(routes_file "fresh-$name-$fx-new")"
      fi
      run_common "fresh-$name-$fx-old" "$OLD_COMMON" "${old[@]}"
      if [[ "${new[0]}" == grafana ]]; then
        grafana "fresh-$name-$fx-new" "${new[1]}" "${new[2]}"
      else
        run_new "fresh-$name-$fx-new" "${new[@]}"
      fi
      check "new route ($name, routes file $fx) is byte for byte what ${BASE_COMMIT} wrote" \
        cmp -s "$(routes_file "fresh-$name-$fx-old")" "$(routes_file "fresh-$name-$fx-new")"
      check "new route ($name, routes file $fx) reloads Pomerium" reloaded "fresh-$name-$fx-new"
    done
  }
  fresh_same argocd provision::pomerium_routes_add https://argocd.fake.example.test http://argocd-server.argocd.svc.cluster.local:80 sso true true true \
    -- provision::pomerium_routes_add https://argocd.fake.example.test http://argocd-server.argocd.svc.cluster.local:80 sso true true true
  fresh_same wireguard provision::pomerium_routes_add https://wg.fake.example.test http://wireguard-wg-portal.wireguard.svc.cluster.local:8888 sso \
    -- provision::pomerium_routes_add https://wg.fake.example.test http://wireguard-wg-portal.wireguard.svc.cluster.local:8888 sso
  fresh_same pgweb provision::pomerium_routes_add_for_groups https://pgweb.fake.example.test http://pgweb.postgres.svc.cluster.local:8081 "fake-org:admins, fake-org:dba" sso \
    -- provision::pomerium_routes_add_for_groups https://pgweb.fake.example.test http://pgweb.postgres.svc.cluster.local:8081 "fake-org:admins, fake-org:dba" sso
  fresh_same grafana provision::pomerium_routes_add "$G" "$GTO" sso true true true '{}' -- grafana "" ""
  fresh_same grafana-csp provision::pomerium_routes_add "$G" "$GTO" sso true true true "$csp_extra" -- grafana "" "$csp"
else
  fail "cannot read tools/provision-common.sh at ${BASE_COMMIT} (needs the git history)"
fi

# Grafana with groups on a new route: the policy, no allow_any
setup fresh-grafana-groups none
grafana fresh-grafana-groups "fake-org:uce, fake-org:admins" ""
check "new Grafana route with GRAFANA_ALLOWED_GROUPS: policy on both groups, no allow_any" \
  json_eq "$(catch_all fresh-grafana-groups "$G")" \
  "{\"from\":\"$G\",\"to\":\"$GTO\",\"preserve_host_header\":true,\"pass_identity_headers\":true,
    \"policy\":[{\"allow\":{\"or\":[{\"claim/groups\":\"fake-org:uce\"},{\"claim/groups\":\"fake-org:admins\"}]}}]}"

# --- 2./4./5. the prod-like file: Grafana without groups changes nothing -----------------------
setup prod-keep prod-like.yaml
before="$WORK/prod-keep/before.yaml"
cp "$(routes_file prod-keep)" "$before"
chmod 644 "$(routes_file prod-keep)"
grafana prod-keep "" ""
check "Grafana run on a route with a policy: the file is byte for byte unchanged" cmp -s "$before" "$(routes_file prod-keep)"
check "Grafana run on a route with a policy: no reload call (no pomerium-config, no rollout)" no_reload_calls prod-keep
check "Grafana run on a route with a policy: says the route is unchanged" grep -q "unchanged" "$WORK/prod-keep/output.txt"

# the same with a 'to' that differs (no :80): only 'to' changes, the rest stays, Pomerium reloads
setup prod-to prod-like.yaml
sed -i.bak 's#to: "http://grafana.observability.svc.cluster.local:80"#to: http://grafana.observability.svc.cluster.local#' "$(routes_file prod-to)"
rm -f "$(routes_file prod-to).bak"
chmod 644 "$(routes_file prod-to)"
before_json=$(catch_all prod-to "$G")
before_others=$(others_of "$(routes_file prod-to)")
grafana prod-to "" ""
after_json=$(catch_all prod-to "$G")
check "existing policy preserved (Grafana, groups unset)" \
  json_eq "$(jq -c .policy <<<"$after_json")" "$(jq -c .policy <<<"$before_json")"
check "existing route gets no allow_any_authenticated_user" \
  jqe 'has("allow_any_authenticated_user") | not' <<<"$after_json"
check "keys the caller does not set stay (timeout, X-Robots-Tag)" \
  jqe '.timeout == "60s" and .set_response_headers == {"X-Robots-Tag": "noindex"}' <<<"$after_json"
check "only 'to' changed" json_eq "$(jq -c --arg t "$GTO" '.to = $t' <<<"$before_json")" "$after_json"
check "/mcp prefix route and other hosts' routes untouched, in order" \
  json_eq "$before_others" "$(others_of "$(routes_file prod-to)")"
check "Grafana's catch-all stays after its /mcp route" \
  jqe --arg f "$G" '([to_entries[] | select(.value.from == $f and .value.prefix == "/mcp")][0].key)
                        < ([to_entries[] | select(.value.from == $f and (.value | has("prefix") | not))][0].key)' \
  <<<"$(yq -o=json -I=0 '.config.routes' "$(routes_file prod-to)")"
check "comments stay" grep -q "# Grafana UI: two teams." "$(routes_file prod-to)"
check "the 'to' change reloads Pomerium" reloaded prod-to
check "the file keeps its mode (644)" [ "$(stat -f %Lp "$(routes_file prod-to)" 2>/dev/null || stat -c %a "$(routes_file prod-to)")" = 644 ]
: > "$WORK/prod-to/kubectl.log"
cp "$(routes_file prod-to)" "$WORK/prod-to/second-before.yaml"
grafana prod-to "" ""
check "a second identical run changes nothing and reloads nothing" \
  bash -c "cmp -s '$WORK/prod-to/second-before.yaml' '$(routes_file prod-to)' && ! grep -qE 'pomerium-config|rollout|create secret' '$WORK/prod-to/kubectl.log'"

# argocd's route (hand-written admins policy) through pomerium_routes_add: kept
setup argocd-keep prod-like.yaml
cp "$(routes_file argocd-keep)" "$WORK/argocd-keep/before.yaml"
run_new argocd-keep provision::pomerium_routes_add https://argocd.fake.example.test http://argocd-server.argocd.svc.cluster.local:80 sso true true true
check "argocd.sh-style call on a route with a policy: unchanged, no reload" \
  bash -c "cmp -s '$WORK/argocd-keep/before.yaml' '$(routes_file argocd-keep)' && ! grep -q rollout '$WORK/argocd-keep/kubectl.log'"

# --- 3. GRAFANA_ALLOWED_GROUPS ------------------------------------------------------------------
setup groups-same prod-like.yaml
cp "$(routes_file groups-same)" "$WORK/groups-same/before.yaml"
grafana groups-same "fake-org:uce,fake-org:admins" ""
check "GRAFANA_ALLOWED_GROUPS equal to the file's policy: unchanged, no reload" \
  bash -c "cmp -s '$WORK/groups-same/before.yaml' '$(routes_file groups-same)' && ! grep -q rollout '$WORK/groups-same/kubectl.log'"

setup groups-open open-grafana.yaml
before_mcp=$(others_of "$(routes_file groups-open)")
grafana groups-open " fake-org:admins , fake-org:sre " ""
after_json=$(catch_all groups-open "$G")
check "GRAFANA_ALLOWED_GROUPS rendered as a policy (blanks trimmed), allow_any removed" \
  json_eq "$after_json" "{\"from\":\"$G\",\"to\":\"$GTO\",\"preserve_host_header\":true,\"pass_identity_headers\":true,
    \"policy\":[{\"allow\":{\"or\":[{\"claim/groups\":\"fake-org:admins\"},{\"claim/groups\":\"fake-org:sre\"}]}}]}"
check "the stale duplicate catch-all is gone" \
  [ "$(yq -o=json -I=0 '.config.routes' "$(routes_file groups-open)" | jq --arg f "$G" '[.[] | select(.from == $f and (has("prefix") | not))] | length')" = 1 ]
check "/mcp prefix route untouched by the groups run" json_eq "$before_mcp" "$(others_of "$(routes_file groups-open)")"
check "the groups run reloads Pomerium" reloaded groups-open

# shellcheck disable=SC1091
valid() { ( source "$REPO/tools/provision-common.sh"; provision::pomerium_groups_valid "$1" ); }
for v in "fake-org:admins" "fake-org:admins,fake-org:uce" " fake-org:a , b2:team_x.y ," "Org-1:My-Team"; do
  check "groups valid: '$v'" valid "$v"
done
for v in "" " , " "admins" "fake-org:" ":admins" "fake org:admins" "fake-org:admins;x" "-org:admins" "o:a,b"; do
  check "groups refused: '$v'" bash -c "! ( source '$REPO/tools/provision-common.sh'; provision::pomerium_groups_valid '$v' )"
done
# observability.sh itself, with a malformed value in env.properties: it stops with the error
# after reading its kubectl context, before any other kubectl or helm call
setup obs-bad none
printf 'HOSTNAME=fake.example.test\nEXTERNAL_IP=192.0.2.10\nACME_EMAIL=ops@example.test\nGRAFANA_ALLOWED_GROUPS="fake-org:admins;x"\n' \
  > "$WORK/obs-bad/envs/fake/env.properties"
obs_rc=0
STUB_LOG="$WORK/obs-bad/kubectl.log" INFRA_ENVS_ROOT="$WORK/obs-bad/envs" KUBECONFIG=/dev/null \
  PATH="$HERE/stubs:$PATH" "$REPO/tools/k3s/observability.sh" fake >"$WORK/obs-bad/output.txt" 2>&1 || obs_rc=$?
check "observability.sh refuses a malformed GRAFANA_ALLOWED_GROUPS (exit 1, names the property)" \
  bash -c "[ $obs_rc = 1 ] && grep -q 'GRAFANA_ALLOWED_GROUPS: .* is not a comma-separated list' '$WORK/obs-bad/output.txt'"
check "... before any cluster call but the context read" \
  bash -c "! grep -v '^config current-context\$' '$WORK/obs-bad/kubectl.log' | grep -q ."

# --- 6. GRAFANA_FRAME_ANCESTORS set, then unset ---------------------------------------------------
setup csp prod-like.yaml
grafana csp "" "frame-ancestors 'self' https://portal.example.test"
check "CSP set: header on the route next to X-Robots-Tag" \
  jqe '.set_response_headers == {"X-Robots-Tag": "noindex", "Content-Security-Policy": "frame-ancestors '"'"'self'"'"' https://portal.example.test"}' \
  <<<"$(catch_all csp "$G")"
check "CSP set: policy still there" jqe '.policy | length == 1' <<<"$(catch_all csp "$G")"
grafana csp "" ""
check "CSP unset: header gone, X-Robots-Tag stays" \
  jqe '.set_response_headers == {"X-Robots-Tag": "noindex"}' <<<"$(catch_all csp "$G")"
check "CSP set then unset: route as in the fixture" \
  json_eq "$(catch_all csp "$G")" "$(yq -o=json -I=0 '.config.routes' "$HERE/fixtures/prod-like.yaml" | jq -c --arg f "$G" '[.[] | select(.from == $f and (has("prefix") | not))][0]')"
setup csp-open open-grafana.yaml
grafana csp-open "" "frame-ancestors 'self' https://portal.example.test"
grafana csp-open "" ""
check "CSP set then unset on a route without other headers: no set_response_headers left" \
  jqe 'has("set_response_headers") | not' <<<"$(catch_all csp-open "$G")"

# --- 7. pomerium_routes_add_for_groups on existing routes ----------------------------------------
setup pgweb-change prod-like.yaml
yq -i '(.config.routes[] | select(.from == "https://pgweb.fake.example.test")).timeout = "30s"' "$(routes_file pgweb-change)"
run_new pgweb-change provision::pomerium_routes_add_for_groups https://pgweb.fake.example.test http://pgweb.postgres.svc.cluster.local:8081 "fake-org:dba" sso
check "pgweb: a changed PGWEB_ALLOWED_GROUPS replaces the policy, timeout stays" \
  json_eq "$(catch_all pgweb-change https://pgweb.fake.example.test)" \
  '{"from":"https://pgweb.fake.example.test","to":"http://pgweb.postgres.svc.cluster.local:8081","preserve_host_header":true,"pass_identity_headers":true,"timeout":"30s","policy":[{"allow":{"or":[{"claim/groups":"fake-org:dba"}]}}]}'
check "pgweb change reloads Pomerium" reloaded pgweb-change
setup nexus-groups prod-like.yaml
run_new nexus-groups provision::pomerium_routes_add_for_groups https://nexus.fake.example.test http://nexus.nexus.svc.cluster.local:8081 "fake-org:admins" sso
check "for_groups over an allow_any route drops allow_any_authenticated_user" \
  jqe '(has("allow_any_authenticated_user") | not) and (.policy | length == 1)' <<<"$(catch_all nexus-groups https://nexus.fake.example.test)"

# --- 5. pomerium_routes_remove without a route ----------------------------------------------------
setup remove-none prod-like.yaml
cp "$(routes_file remove-none)" "$WORK/remove-none/before.yaml"
run_new remove-none provision::pomerium_routes_remove https://nothing.fake.example.test sso
check "remove of a host without a route: unchanged, no reload call" \
  bash -c "cmp -s '$WORK/remove-none/before.yaml' '$(routes_file remove-none)' && ! grep -qE 'pomerium-config|rollout' '$WORK/remove-none/kubectl.log'"
setup remove-one prod-like.yaml
run_new remove-one provision::pomerium_routes_remove https://nexus.fake.example.test sso
check "remove of an existing route: gone, Pomerium reloaded" \
  bash -c "[ \"\$(yq '[.config.routes[] | select(.from == \"https://nexus.fake.example.test\")] | length' '$(routes_file remove-one)')\" = 0 ] && grep -q rollout '$WORK/remove-one/kubectl.log'"

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed (work dir kept: $WORK)"
  trap - EXIT
  exit 1
fi
echo "all checks passed"
