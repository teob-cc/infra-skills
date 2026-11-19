#!/usr/bin/env bash
# Checks what tools/k3s/observability.sh generates for the alert triage webhook, without a
# cluster. Alertmanager's config and the alert rules live in that script, so the test runs
# the script itself with `--dry-run` for a fake env (envs/fake), with stand-ins for kubectl
# and helm on PATH (stubs/): kubectl answers the reads a dry run makes and fails on any
# write; helm turns the server-side dry run into `helm template` of the pinned chart.
#
# What it checks:
#   1. a dry run makes no writing kubectl or helm call;
#   2. without ALERTMANAGER_TRIAGE_WEBHOOK_URL the rendered alertmanager.yml is byte-for-byte
#      expected/*.yml, which were rendered from the script as it was before the webhook
#      existed (with and without the dead-man Secret);
#   3. with the URL in env.properties: `amtool check-config` passes, the receiver is a
#      webhook to that URL without resolved notifications, and the difference to the config
#      without it is that receiver and one route, nothing else;
#   4. `amtool config routes test`: p1 and p2 reach alert-triage and then every receiver
#      they reached before; p3, Watchdog and an unlabelled alert are routed as before;
#   5. the service's two alerts are in the rules with the URL and absent without it, and
#      every other rule is unchanged;
#   6. a URL with a query or credentials is refused.
#
# Usage:
#   tests/alert-triage/alertmanager-webhook.sh            # run the checks
#   tests/alert-triage/alertmanager-webhook.sh --update   # rewrite expected/* after a wanted
#                                                          # change to the config without triage
# Needs helm, yq, jq and docker (amtool comes from the Alertmanager image; set AMTOOL_IMAGE
# to the version your clusters run). The chart is fetched from the prometheus-community
# repository, so it needs the network.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
AMTOOL_IMAGE="${AMTOOL_IMAGE:-quay.io/prometheus/alertmanager:v0.34.0}"
URL="http://alert-triage.holmes.svc.cluster.local:8080/webhook"
UPDATE=false
[[ "${1:-}" == "--update" ]] && UPDATE=true

for tool in helm yq jq docker; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing: $tool" >&2; exit 1; }
done
REAL_HELM="$(command -v helm)"
WORK="$(mktemp -d -t alert-triage-webhook-test-XXXX)"

failures=0
ok() { echo "ok    $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }

# An env dir per variant: the switch is a line in env.properties, as an operator sets it.
env_root() { # <name> [line to append to env.properties]
  mkdir -p "$WORK/envs-$1/fake"
  cp "$HERE/envs/fake/env.properties" "$WORK/envs-$1/fake/env.properties"
  [[ -n "${2:-}" ]] && echo "$2" >> "$WORK/envs-$1/fake/env.properties"
  echo "$WORK/envs-$1"
}

# run_script <name> <deadman: absent|present> <envs root>; returns the script's exit status
run_script() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  REAL_HELM="$REAL_HELM" STUB_LOG="$dir/calls.log" STUB_VALUES_OUT="$dir/values.yaml" \
    STUB_SLACK_SECRET=absent STUB_DEADMAN_SECRET="$2" \
    INFRA_ENVS_ROOT="$3" KUBECONFIG=/dev/null PATH="$HERE/stubs:$PATH" \
    "$REPO/tools/k3s/observability.sh" fake --dry-run >"$dir/output.txt" 2>&1
}
render() {
  local dir="$WORK/$1" rendered
  if ! run_script "$@"; then
    echo "observability.sh fake --dry-run failed for variant $1; see $dir/output.txt" >&2
    tail -20 "$dir/output.txt" >&2
    exit 1
  fi
  rendered="$(sed -n 's/.*Rendered files kept in //p' "$dir/output.txt")"
  cp "$rendered/alertmanager.new" "$dir/alertmanager.yml"
  cp "$rendered/alerting_rules.new" "$dir/alerting_rules.yml"
}

amtool() { docker run --rm -v "$WORK":/w:ro --entrypoint amtool "$AMTOOL_IMAGE" "$@"; }

# routes <variant> <expected receivers, comma-separated> <label=value>...
routes() {
  local variant=$1 expected=$2 got
  shift 2
  got="$(amtool config routes test --config.file="/w/$variant/alertmanager.yml" "$@" 2>&1 | tr -d '\r')"
  if [[ "$got" == "$expected" ]]; then
    ok "$variant: {$*} -> $got"
  else
    fail "$variant: {$*} -> $got (expected $expected)"
  fi
}

echo "Rendering four variants into $WORK ..."
OFF="$(env_root off)"
ON="$(env_root on "ALERTMANAGER_TRIAGE_WEBHOOK_URL=\"$URL\"")"
render plain absent "$OFF"
render deadman present "$OFF"
render triage absent "$ON"
render triage-deadman present "$ON"

# 1. A dry run writes nothing.
for v in plain deadman triage triage-deadman; do
  if [[ -e "$WORK/$v/calls.log.writes" ]]; then
    fail "$v: the dry run made a writing call: $(cat "$WORK/$v/calls.log.writes")"
  else
    ok "$v: no writing kubectl or helm call"
  fi
done

# 2. Without the URL everything is what it was before the webhook existed.
if [[ "$UPDATE" == "true" ]]; then
  cp "$WORK/plain/alertmanager.yml" "$HERE/expected/alertmanager-without-triage.yml"
  cp "$WORK/deadman/alertmanager.yml" "$HERE/expected/alertmanager-without-triage-deadman.yml"
  echo "expected/* rewritten"
fi
same() { # <variant> <rendered file> <expected file>
  if cmp -s "$WORK/$1/$2" "$HERE/expected/$3"; then
    ok "$1: $2 is byte-for-byte expected/$3"
  else
    fail "$1: $2 differs from expected/$3"
    diff -u "$HERE/expected/$3" "$WORK/$1/$2" | head -40 || true
  fi
}
same plain alertmanager.yml alertmanager-without-triage.yml
same deadman alertmanager.yml alertmanager-without-triage-deadman.yml

# 3. With the URL: a valid config, and the only difference is one receiver and one route.
for v in plain deadman triage triage-deadman; do
  if out="$(amtool check-config "/w/$v/alertmanager.yml" 2>&1)"; then
    ok "$v: amtool check-config"
  else
    fail "$v: amtool check-config"
    echo "$out"
  fi
done
receiver="$(yq -o=json -I=0 '.receivers[] | select(.name == "alert-triage")' "$WORK/triage/alertmanager.yml")"
want='{"name":"alert-triage","webhook_configs":[{"max_alerts":50,"send_resolved":false,"url":"'"$URL"'"}]}'
[[ "$receiver" == "$want" ]] && ok "triage: receiver is $receiver" || fail "triage: receiver is $receiver (expected $want)"
route="$(yq -o=json -I=0 '.route.routes[0]' "$WORK/triage/alertmanager.yml")"
want='{"continue":true,"matchers":["severity=~\"p1|p2\""],"receiver":"alert-triage"}'
[[ "$route" == "$want" ]] && ok "triage: first route is $route" || fail "triage: first route is $route (expected $want)"
for pair in "triage plain" "triage-deadman deadman"; do
  set -- $pair
  if yq 'del(.receivers[] | select(.name == "alert-triage")) | del(.route.routes[0])' "$WORK/$1/alertmanager.yml" \
      | diff -q - <(yq '.' "$WORK/$2/alertmanager.yml") >/dev/null; then
    ok "$1: without that receiver and that route the config equals $2"
  else
    fail "$1: differs from $2 in more than the receiver and the route"
  fi
done

# 4. Routing. Every receiver gets what it got before; alert-triage only adds p1 and p2.
routes plain ops-email,ops-telegram severity=p1 alertname=X app=infra
routes plain ops-email,ops-telegram severity=p2 alertname=X app=infra
routes plain ops-email,ops-telegram severity=p3 alertname=X app=infra
routes plain watchdog-null alertname=Watchdog severity=none app=infra
routes plain ops-email alertname=X
routes triage alert-triage,ops-email,ops-telegram severity=p1 alertname=X app=infra
routes triage alert-triage,ops-email,ops-telegram severity=p2 alertname=X app=infra
routes triage ops-email,ops-telegram severity=p3 alertname=X app=infra
routes triage watchdog-null alertname=Watchdog severity=none app=infra
routes triage ops-email alertname=X
routes triage-deadman deadman alertname=Watchdog severity=none app=infra
routes triage-deadman alert-triage,ops-email,ops-telegram severity=p1 alertname=X app=infra

# 5. The service's own alert rules come with the switch, and nothing else changes.
alerts() { yq '.groups[].rules[] | select(has("alert")) | .alert' "$WORK/$1/alerting_rules.yml" | sort -u; }
added="$(comm -13 <(alerts plain) <(alerts triage) | tr '\n' ' ')"
removed="$(comm -23 <(alerts plain) <(alerts triage) | tr '\n' ' ')"
[[ "$added" == "AlertTriageCapReached AlertTriageFailing " && -z "$removed" ]] \
  && ok "triage: alerts added: $added; removed: none" \
  || fail "triage: alerts added: '$added', removed: '$removed'"
if yq 'del(.groups[] | select(.name == "alert-triage"))' "$WORK/triage/alerting_rules.yml" \
    | diff -q - <(yq '.' "$WORK/plain/alerting_rules.yml") >/dev/null; then
  ok "triage: without the group alert-triage the rules equal plain"
else
  fail "triage: the rules differ from plain in more than the group alert-triage"
fi
grep -q "Merging alert groups from .*charts/alert-triage/alerts/alert-triage.yml" "$WORK/triage/output.txt" \
  && ok "triage: the script says it merged the chart's fragment" || fail "triage: no merge line in the output"
grep -q "alert-triage" "$WORK/plain/output.txt" \
  && fail "plain: the output mentions alert-triage" || ok "plain: the output does not mention alert-triage"

# 6. Only a plain URL is accepted.
n=0
for bad in 'http://x.example/webhook?token=abc' 'http://user:pw@x.example/webhook' 'x.example/webhook' "http://x.example/'; rm -rf /"; do
  n=$((n + 1))
  if run_script "bad-$n" absent "$(env_root "bad-$n" "ALERTMANAGER_TRIAGE_WEBHOOK_URL=\"$bad\"")"; then
    fail "the script accepted ALERTMANAGER_TRIAGE_WEBHOOK_URL=$bad"
  elif grep -q "is not a plain http(s) URL" "$WORK/bad-$n/output.txt"; then
    ok "refused: $bad"
  else
    fail "the script failed for another reason with $bad"; tail -5 "$WORK/bad-$n/output.txt"
  fi
done

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed. Rendered files: $WORK"
  exit 1
fi
echo "All checks passed. Rendered files: $WORK"
