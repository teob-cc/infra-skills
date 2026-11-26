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
#   R1. a refused Secret apply, a refused rollout or an unreadable Secret: the caller fails
#       (ensure_grafana_pomerium, pomerium_routes_add, pomerium_routes_remove), the routes file
#       stays as it was, and the identical rerun applies and restarts (the live routes are then
#       the file's); an unreadable Secret is never overwritten;
#   R2. a failed or silently short write of the routes file (a stand-in cat) leaves the file as it
#       was (bytes, mode, no temp file), the caller fails, the rerun writes it; the file is
#       replaced by a rename;
#   R3. GRAFANA_ALLOWED_GROUPS with glob characters is refused even when the cwd has matching
#       files, and the validator checks the entries the renderer makes;
#   R4. a CSP change keeps the head and inline comments of the sibling header; set then unset
#       gives the fixture back byte for byte.
#   R5. a Forbidden `get deploy` fails the reload (file kept, retried by the identical rerun); a
#       real NotFound still succeeds with a warning;
#   R6. a refused Ingress apply fails ensure_grafana_pomerium before any route call, also under
#       set -e at the `|| exit 1` call site;
#   R7. a relative symlink (and a chain of two) stays a link and its referent is replaced (mode
#       kept, no temp files, rerun a no-op); a symlink loop is refused before any reload.
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

# run_common <case> <common.sh> <function> <args...>: one helper call against the stand-ins; its
# exit status is the helper's (callers that expect a failure take it with || rc=$?). PRELUDE, when
# set, is evaluated after sourcing (case-local stand-in functions).
run_common() {
  local dir="$WORK/$1" common="$2"; shift 2
  ( export PATH="$HERE/stubs:$PATH" STUB_LOG="$dir/kubectl.log" INFRA_ENVS_ROOT="$dir/envs" ENV_NAME=fake
    # shellcheck disable=SC1090
    source "$common"
    eval "${PRELUDE:-}"   # a stand-in function for one case (e.g. a failing cat)
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
    err() { echo "[observability:error] $*" >&2; }
    eval "${PRELUDE:-}"
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


# ===== Round 2 (validator findings on 5507145, INFRA-253 comment 17340) ============================
live_routes() { # <case>: the routes of the stand-in's live pomerium-config, as compact JSON
  local s="$WORK/$1/kubectl.log.secret"
  if [[ -f "$s" ]]; then yq -o=json -I=0 '.routes // []' "$s"; else echo '[]'; fi
}
file_routes() { yq -o=json -I=0 '.config.routes // []' "$(routes_file "$1")"; }
no_stray_temp() { [ -z "$(find "$WORK/$1/envs/fake" -name '.pomerium-routes.yaml.*')" ]; }

# --- R1. a failed reload fails the caller, leaves the file, and the rerun retries ----------------
# Secret apply refused: open route, GRAFANA_ALLOWED_GROUPS set
setup r1-apply open-grafana.yaml
cp "$(routes_file r1-apply)" "$WORK/r1-apply/before.yaml"
rc=0; STUB_FAIL_APPLY=1 grafana r1-apply "fake-org:admins" "" || rc=$?
check "R1 apply refused: ensure_grafana_pomerium fails (exit $rc)" [ "$rc" -ne 0 ]
check "R1 apply refused: an error, no 'route ensured'" \
  bash -c "grep -q 'Failed to ensure the Pomerium route' '$WORK/r1-apply/output.txt' && ! grep -q 'route ensured' '$WORK/r1-apply/output.txt'"
check "R1 apply refused: routes file byte for byte as before" cmp -s "$WORK/r1-apply/before.yaml" "$(routes_file r1-apply)"
check "R1 apply refused: no rollout after the failed apply" bash -c "! grep -q 'rollout restart' '$WORK/r1-apply/kubectl.log'"
check "R1 apply refused: no temp file left next to the routes file" no_stray_temp r1-apply
: > "$WORK/r1-apply/kubectl.log"
rc=0; grafana r1-apply "fake-org:admins" "" || rc=$?
check "R1 identical rerun: succeeds (exit $rc)" [ "$rc" -eq 0 ]
check "R1 identical rerun: applies the Secret and restarts Pomerium (retried)" \
  bash -c "grep -q 'create secret generic pomerium-config' '$WORK/r1-apply/kubectl.log' && grep -q 'rollout restart' '$WORK/r1-apply/kubectl.log'"
check "R1 identical rerun: the file now has the groups policy, no allow_any" \
  jqe '(has("allow_any_authenticated_user") | not) and .policy == [{"allow":{"or":[{"claim/groups":"fake-org:admins"}]}}]' <<<"$(catch_all r1-apply "$G")"
check "R1 identical rerun: the live routes are the file's routes" json_eq "$(live_routes r1-apply)" "$(file_routes r1-apply)"
check "R1 live config keeps its other settings" \
  [ "$(yq '.authenticate_service_url' "$WORK/r1-apply/kubectl.log.secret")" = "https://auth.example.test" ]
: > "$WORK/r1-apply/kubectl.log"
grafana r1-apply "fake-org:admins" ""
check "R1 third run: nothing to do, no reload" no_reload_calls r1-apply

# rollout restart refused: the Secret is live, the file is not written; the rerun restarts again
setup r1-rollout open-grafana.yaml
cp "$(routes_file r1-rollout)" "$WORK/r1-rollout/before.yaml"
rc=0; STUB_FAIL_ROLLOUT=1 grafana r1-rollout "fake-org:admins" "" || rc=$?
check "R1 rollout refused: fails, file as before" bash -c "[ $rc -ne 0 ] && cmp -s '$WORK/r1-rollout/before.yaml' '$(routes_file r1-rollout)'"
: > "$WORK/r1-rollout/kubectl.log"
rc=0; grafana r1-rollout "fake-org:admins" "" || rc=$?
check "R1 rollout refused, rerun: restarts and writes the file" \
  bash -c "[ $rc -eq 0 ] && grep -q 'rollout restart' '$WORK/r1-rollout/kubectl.log' && ! cmp -s '$WORK/r1-rollout/before.yaml' '$(routes_file r1-rollout)'"

# the Secret cannot be read: no routes-only config is applied over the live one
setup r1-read open-grafana.yaml
cp "$(routes_file r1-read)" "$WORK/r1-read/before.yaml"
rc=0; STUB_FAIL_SECRET_READ=1 grafana r1-read "fake-org:admins" "" || rc=$?
check "R1 Secret read fails: fails, no Secret written, no rollout, file as before" \
  bash -c "[ $rc -ne 0 ] && ! grep -qE 'create secret|rollout' '$WORK/r1-read/kubectl.log' && cmp -s '$WORK/r1-read/before.yaml' '$(routes_file r1-read)'"

# the other callers get the failure too (argocd.sh-style, and remove)
setup r1-argocd none
rc=0; STUB_FAIL_APPLY=1 run_new r1-argocd provision::pomerium_routes_add https://argocd.fake.example.test http://argocd-server.argocd.svc.cluster.local:80 sso true true true || rc=$?
check "R1 pomerium_routes_add returns the failure (exit $rc) and creates no routes file" \
  bash -c "[ $rc -ne 0 ] && [ ! -e '$(routes_file r1-argocd)' ]"
setup r1-remove prod-like.yaml
cp "$(routes_file r1-remove)" "$WORK/r1-remove/before.yaml"
rc=0; STUB_FAIL_APPLY=1 run_new r1-remove provision::pomerium_routes_remove https://nexus.fake.example.test sso || rc=$?
check "R1 pomerium_routes_remove returns the failure, file as before" \
  bash -c "[ $rc -ne 0 ] && cmp -s '$WORK/r1-remove/before.yaml' '$(routes_file r1-remove)'"
check "R1 observability.sh stops when ensure_grafana_pomerium fails" \
  grep -qE '^ +ensure_grafana_pomerium \|\| exit 1$' "$REPO/tools/k3s/observability.sh"

# --- R2. the routes file is replaced atomically; a failed or short write leaves it alone ---------
for variant in "fails:1" "silent:0"; do
  name=${variant%%:*} code=${variant##*:}
  setup "r2-$name" open-grafana.yaml
  chmod 640 "$(routes_file "r2-$name")"
  cp "$(routes_file "r2-$name")" "$WORK/r2-$name/before.yaml"
  # the write of the staged routes emits only "config:" (and exits $code)
  rc=0; PRELUDE="cat() { printf 'config:\n'; return $code; }" grafana "r2-$name" "fake-org:admins" "" || rc=$?
  check "R2 short write ($name, cat exit $code): ensure_grafana_pomerium fails" [ "$rc" -ne 0 ]
  check "R2 short write ($name): routes file byte for byte as before, mode 640" \
    bash -c "cmp -s '$WORK/r2-$name/before.yaml' '$(routes_file "r2-$name")' && [ \"\$(stat -f %Lp '$(routes_file "r2-$name")' 2>/dev/null || stat -c %a '$(routes_file "r2-$name")')\" = 640 ]"
  check "R2 short write ($name): says the file was not written" grep -q "was not written" "$WORK/r2-$name/output.txt"
  check "R2 short write ($name): no temp file left next to the routes file" no_stray_temp "r2-$name"
  : > "$WORK/r2-$name/kubectl.log"
  rc=0; grafana "r2-$name" "fake-org:admins" "" || rc=$?
  check "R2 short write ($name), rerun: writes the whole file (mode 640 kept) and reloads" \
    bash -c "[ $rc -eq 0 ] && grep -q 'rollout restart' '$WORK/r2-$name/kubectl.log' && [ \"\$(stat -f %Lp '$(routes_file "r2-$name")' 2>/dev/null || stat -c %a '$(routes_file "r2-$name")')\" = 640 ]"
  check "R2 short write ($name), rerun: the file parses and has the policy" \
    jqe '.policy | length == 1' <<<"$(catch_all "r2-$name" "$G")"
done
setup r2-atomic open-grafana.yaml
ino_before=$(stat -f %i "$(routes_file r2-atomic)" 2>/dev/null || stat -c %i "$(routes_file r2-atomic)")
grafana r2-atomic "fake-org:admins" ""
ino_after=$(stat -f %i "$(routes_file r2-atomic)" 2>/dev/null || stat -c %i "$(routes_file r2-atomic)")
check "R2 the file is replaced by a rename (new inode), not truncated in place" [ "$ino_before" != "$ino_after" ]

# --- R3. GRAFANA_ALLOWED_GROUPS: no pathname expansion; the validated entries are the rendered ones
GLOBDIR="$WORK/r3-globdir"
mkdir -p "$GLOBDIR" && touch "$GLOBDIR/fake-org:admins" "$GLOBDIR/fake-org:uce"
for v in "fake-org:*" "fake-org:adm?ns" "fake-org:[a]dmins" "*" "fake-org:admins,fake-org:*"; do
  check "R3 refused with a matching file in the cwd: '$v'" \
    bash -c "cd '$GLOBDIR' && ! ( source '$REPO/tools/provision-common.sh'; provision::pomerium_groups_valid '$v' )"
done
check "R3 an entry with a newline inside is refused (the renderer would keep it)" \
  bash -c "! ( source '$REPO/tools/provision-common.sh'; provision::pomerium_groups_valid \$'fake-org:a\nfake-org:b' )"
check "R3 validator and renderer share one split (PROVISION_POMERIUM_GROUPS_JQ)" \
  bash -c "[ \"\$(grep -c 'PROVISION_POMERIUM_GROUPS_JQ\"' '$REPO/tools/provision-common.sh')\" -ge 2 ]"
setup r3-obs none
printf 'HOSTNAME=fake.example.test\nEXTERNAL_IP=192.0.2.10\nACME_EMAIL=ops@example.test\nGRAFANA_ALLOWED_GROUPS="fake-org:*"\n' \
  > "$WORK/r3-obs/envs/fake/env.properties"
obs_rc=0
( cd "$GLOBDIR" && STUB_LOG="$WORK/r3-obs/kubectl.log" INFRA_ENVS_ROOT="$WORK/r3-obs/envs" KUBECONFIG=/dev/null \
    PATH="$HERE/stubs:$PATH" "$REPO/tools/k3s/observability.sh" fake ) >"$WORK/r3-obs/output.txt" 2>&1 || obs_rc=$?
check "R3 observability.sh refuses GRAFANA_ALLOWED_GROUPS=fake-org:* run from a dir with fake-org:admins" \
  bash -c "[ $obs_rc = 1 ] && grep -q 'GRAFANA_ALLOWED_GROUPS: .* is not a comma-separated list' '$WORK/r3-obs/output.txt'"

# --- R4. a CSP change keeps the comments of its sibling headers -----------------------------------
setup r4 prod-like.yaml
grafana r4 "" "frame-ancestors 'self' https://portal.example.test"
check "R4 CSP set: the sibling header's head comment stays" grep -q "# keep crawlers out (comment on a sibling header)" "$(routes_file r4)"
check "R4 CSP set: the sibling header's inline comment stays" grep -q "X-Robots-Tag: noindex # inline comment" "$(routes_file r4)"
check "R4 CSP set: the header is there" jqe '.set_response_headers["Content-Security-Policy"] | startswith("frame-ancestors")' <<<"$(catch_all r4 "$G")"
grafana r4 "" ""
check "R4 CSP set then unset: the file is byte for byte the fixture again" cmp -s "$HERE/fixtures/prod-like.yaml" "$(routes_file r4)"

# ===== Round 3 (validator findings on 96e75e9, INFRA-253 comment 17348) ============================
# --- R5. a failed deployment lookup (Forbidden) is an error, not "no deployment" -----------------
setup r5-forbidden open-grafana.yaml
cp "$(routes_file r5-forbidden)" "$WORK/r5-forbidden/before.yaml"
rc=0; STUB_FAIL_GET_DEPLOY=1 grafana r5-forbidden "fake-org:admins" "" || rc=$?
check "R5 get deploy Forbidden: ensure_grafana_pomerium fails (exit $rc)" [ "$rc" -ne 0 ]
check "R5 get deploy Forbidden: says the lookup failed" grep -q "looking up deployment/pomerium-proxy in sso failed" "$WORK/r5-forbidden/output.txt"
check "R5 get deploy Forbidden: routes file byte for byte as before, no rollout" \
  bash -c "cmp -s '$WORK/r5-forbidden/before.yaml' '$(routes_file r5-forbidden)' && ! grep -q 'rollout restart' '$WORK/r5-forbidden/kubectl.log'"
: > "$WORK/r5-forbidden/kubectl.log"
rc=0; grafana r5-forbidden "fake-org:admins" "" || rc=$?
check "R5 lookup recovered, identical rerun: applies, restarts pomerium-proxy, writes the file" \
  bash -c "[ $rc -eq 0 ] && grep -q 'create secret generic pomerium-config' '$WORK/r5-forbidden/kubectl.log' && grep -q 'rollout restart deployment/pomerium-proxy' '$WORK/r5-forbidden/kubectl.log' && ! cmp -s '$WORK/r5-forbidden/before.yaml' '$(routes_file r5-forbidden)'"
check "R5 rerun: the file has the policy" jqe '.policy | length == 1' <<<"$(catch_all r5-forbidden "$G")"
# a real NotFound (no Pomerium deployment at all) is still a success with a warning
setup r5-notfound open-grafana.yaml
rc=0; STUB_NO_DEPLOY=1 grafana r5-notfound "fake-org:admins" "" || rc=$?
check "R5 no deployment (NotFound): succeeds, warns, writes the file, no rollout" \
  bash -c "[ $rc -eq 0 ] && grep -q 'nothing restarted' '$WORK/r5-notfound/output.txt' && ! grep -q 'rollout restart' '$WORK/r5-notfound/kubectl.log' && grep -q 'claim/groups: fake-org:admins' '$(routes_file r5-notfound)'"

# --- R6. a refused Ingress apply fails before the route step --------------------------------------
setup r6-ingress open-grafana.yaml
cp "$(routes_file r6-ingress)" "$WORK/r6-ingress/before.yaml"
rc=0; STUB_FAIL_INGRESS_APPLY=1 grafana r6-ingress "fake-org:admins" "" || rc=$?
check "R6 Ingress apply refused: ensure_grafana_pomerium fails (exit $rc)" [ "$rc" -ne 0 ]
check "R6 Ingress apply refused: says so" grep -q "Failed to apply ingress sso/grafana-pomerium" "$WORK/r6-ingress/output.txt"
check "R6 Ingress apply refused: no Secret read or write, no rollout, file as before" \
  bash -c "! grep -qE 'pomerium-config|rollout' '$WORK/r6-ingress/kubectl.log' && cmp -s '$WORK/r6-ingress/before.yaml' '$(routes_file r6-ingress)'"
# as observability.sh calls it: under set -euo pipefail, `ensure_grafana_pomerium || exit 1`
setup r6-callsite open-grafana.yaml
callsite_rc=0
( export PATH="$HERE/stubs:$PATH" STUB_LOG="$WORK/r6-callsite/kubectl.log" INFRA_ENVS_ROOT="$WORK/r6-callsite/envs" \
    ENV_NAME=fake STUB_FAIL_INGRESS_APPLY=1
  bash -c 'set -euo pipefail
    source "$1/tools/provision-common.sh"
    log() { :; }; info() { :; }; warn() { :; }; err() { echo "ERR $*"; }
    GRAFANA_HOST=grafana.fake.example.test NAMESPACE_SSO=sso NAMESPACE_OBSERVABILITY=observability
    CLUSTER_ISSUER=letsencrypt INGRESS_CLASS=traefik GRAFANA_ALLOWED_GROUPS=fake-org:admins grafana_frame_csp=""
    source "$2"
    ensure_grafana_pomerium || exit 1
    echo "AFTER the route step"' _ "$REPO" "$GRAFANA_FN" ) >"$WORK/r6-callsite/output.txt" 2>&1 || callsite_rc=$?
check "R6 call site under set -e with || exit 1: exits 1, never gets past, no route calls" \
  bash -c "[ $callsite_rc = 1 ] && ! grep -q 'AFTER' '$WORK/r6-callsite/output.txt' && ! grep -qE 'pomerium-config|rollout' '$WORK/r6-callsite/kubectl.log'"

# --- R7. a symlinked routes file stays a symlink; the referent is replaced atomically -------------
setup r7 none
mkdir -p "$WORK/r7/shared"
cp "$HERE/fixtures/open-grafana.yaml" "$WORK/r7/shared/routes.yaml"
chmod 640 "$WORK/r7/shared/routes.yaml"
ln -s ../../shared/routes.yaml "$(routes_file r7)"
rc=0; grafana r7 "fake-org:admins" "" || rc=$?
check "R7 relative symlink: succeeds (exit $rc)" [ "$rc" -eq 0 ]
check "R7 relative symlink: still a symlink with the same target text" \
  bash -c "[ -L '$(routes_file r7)' ] && [ \"\$(readlink '$(routes_file r7)')\" = ../../shared/routes.yaml ]"
check "R7 relative symlink: the referent has the new policy and kept mode 640" \
  bash -c "grep -q 'claim/groups: fake-org:admins' '$WORK/r7/shared/routes.yaml' && ! grep -q allow_any_authenticated_user: '$WORK/r7/shared/routes.yaml' && [ \"\$(stat -f %Lp '$WORK/r7/shared/routes.yaml' 2>/dev/null || stat -c %a '$WORK/r7/shared/routes.yaml')\" = 640 ]"
check "R7 relative symlink: no temp file left in either directory" \
  [ -z "$(find "$WORK/r7/shared" "$WORK/r7/envs/fake" -name '.*.yaml.*')" ]
: > "$WORK/r7/kubectl.log"
grafana r7 "fake-org:admins" ""
check "R7 relative symlink, identical rerun: no reload" no_reload_calls r7
# a chain of two relative links
setup r7-chain none
mkdir -p "$WORK/r7-chain/shared/real"
cp "$HERE/fixtures/open-grafana.yaml" "$WORK/r7-chain/shared/real/routes.yaml"
ln -s real/routes.yaml "$WORK/r7-chain/shared/routes.yaml"
ln -s ../../shared/routes.yaml "$(routes_file r7-chain)"
rc=0; grafana r7-chain "fake-org:admins" "" || rc=$?
check "R7 chain of two relative links: both stay links, the final file is updated" \
  bash -c "[ $rc -eq 0 ] && [ -L '$(routes_file r7-chain)' ] && [ -L '$WORK/r7-chain/shared/routes.yaml' ] && grep -q 'claim/groups: fake-org:admins' '$WORK/r7-chain/shared/real/routes.yaml'"
# a symlink loop is refused before any reload
setup r7-loop none
ln -s loop-b.yaml "$WORK/r7-loop/envs/fake/loop-a.yaml"
ln -s loop-a.yaml "$WORK/r7-loop/envs/fake/loop-b.yaml"
ln -s loop-a.yaml "$(routes_file r7-loop)"
rc=0; grafana r7-loop "fake-org:admins" "" || rc=$?
check "R7 symlink loop: fails, no Secret read or write, no rollout, links untouched" \
  bash -c "[ $rc -ne 0 ] && ! grep -qE 'pomerium-config|rollout' '$WORK/r7-loop/kubectl.log' && [ -L '$(routes_file r7-loop)' ]"
check "R7 provision::_resolve_symlinks: absolute target, plain file, missing file" \
  bash -c "source '$REPO/tools/provision-common.sh'; d='$WORK/r7-resolve'; mkdir -p \"\$d\"; : > \"\$d/f\"; ln -sf \"\$d/f\" \"\$d/abs\";
    [ \"\$(provision::_resolve_symlinks \"\$d/abs\")\" = \"\$d/f\" ] && [ \"\$(provision::_resolve_symlinks \"\$d/f\")\" = \"\$d/f\" ] &&
    [ \"\$(provision::_resolve_symlinks \"\$d/none\")\" = \"\$d/none\" ]"
echo
if (( failures > 0 )); then
  echo "$failures check(s) failed (work dir kept: $WORK)"
  trap - EXIT
  exit 1
fi
echo "all checks passed"
