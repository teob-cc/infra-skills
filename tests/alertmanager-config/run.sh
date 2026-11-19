#!/usr/bin/env bash
# Checks the Alertmanager config that tools/k3s/observability.sh generates, without a
# cluster. The config lives in a heredoc of that script, so the test runs the script
# itself with `--dry-run` for a fake env (envs/fake), with stand-ins for kubectl and
# helm on PATH (stubs/): kubectl answers the reads a dry run makes and fails on any
# write; helm turns the server-side dry run into `helm template` of the pinned chart.
#
# What it checks:
#   1. a dry run makes no writing kubectl or helm call;
#   2. without the Secret alertmanager-slack (absent, or present without a `token`
#      key) the rendered alertmanager.yml is byte-for-byte expected/*.yml, with and
#      without the dead-man Secret;
#   3. every variant passes `amtool check-config`;
#   4. `amtool config routes test`: which receivers a p1, p2, p3, Watchdog and an
#      unlabelled alert reach, with and without Slack;
#   5. with the Secret, Alertmanager mounts it and reads the token from the file, and
#      the token is in no rendered file and no line the script prints.
#
# Usage:
#   tests/alertmanager-config/run.sh            # run the checks
#   tests/alertmanager-config/run.sh --update   # rewrite expected/*.yml after a wanted
#                                               # change to the config without Slack
# Needs helm, yq, jq and docker (amtool comes from the Alertmanager image; set
# AMTOOL_IMAGE to the version your clusters run). The chart is fetched from the
# prometheus-community repository, so it needs the network.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
AMTOOL_IMAGE="${AMTOOL_IMAGE:-quay.io/prometheus/alertmanager:v0.34.0}"
UPDATE=false
[[ "${1:-}" == "--update" ]] && UPDATE=true

for tool in helm yq jq docker; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing: $tool" >&2; exit 1; }
done
REAL_HELM="$(command -v helm)"
WORK="$(mktemp -d -t alertmanager-config-test-XXXX)"
# The stand-in Secret holds this value; it must never show up in anything rendered.
FAKE_TOKEN="stub-slack-token-not-real"
FAKE_TOKEN_B64="$(printf '%s' "$FAKE_TOKEN" | base64)"

failures=0
ok() { echo "ok    $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }

# render <name> <slack: absent|present|no-token-key> <deadman: absent|present>
render() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  if ! REAL_HELM="$REAL_HELM" STUB_LOG="$dir/calls.log" STUB_VALUES_OUT="$dir/values.yaml" \
      STUB_SLACK_SECRET="$2" STUB_DEADMAN_SECRET="$3" STUB_TOKEN_B64="$FAKE_TOKEN_B64" \
      INFRA_ENVS_ROOT="$HERE/envs" KUBECONFIG=/dev/null PATH="$HERE/stubs:$PATH" \
      "$REPO/tools/k3s/observability.sh" fake --dry-run >"$dir/output.txt" 2>&1; then
    echo "observability.sh fake --dry-run failed for variant $1; see $dir/output.txt" >&2
    tail -20 "$dir/output.txt" >&2
    exit 1
  fi
  local rendered
  rendered="$(sed -n 's/.*Rendered files kept in //p' "$dir/output.txt")"
  cp "$rendered/alertmanager.new" "$dir/alertmanager.yml"
  cp "$rendered/manifest.yaml" "$dir/manifest.yaml"
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

echo "Rendering five variants into $WORK ..."
render plain absent absent
render deadman absent present
render slack present absent
render slack-deadman present present
render slack-no-token-key no-token-key absent

# 1. A dry run writes nothing.
for v in plain deadman slack slack-deadman slack-no-token-key; do
  if [[ -e "$WORK/$v/calls.log.writes" ]]; then
    fail "$v: the dry run made a writing call: $(cat "$WORK/$v/calls.log.writes")"
  else
    ok "$v: no writing kubectl or helm call"
  fi
done

# 2. Without a usable Slack Secret the config is what it was before Slack existed.
if [[ "$UPDATE" == "true" ]]; then
  cp "$WORK/plain/alertmanager.yml" "$HERE/expected/alertmanager-without-slack.yml"
  cp "$WORK/deadman/alertmanager.yml" "$HERE/expected/alertmanager-without-slack-deadman.yml"
  echo "expected/*.yml rewritten"
fi
same() { # <variant> <expected file>
  if cmp -s "$WORK/$1/alertmanager.yml" "$HERE/expected/$2"; then
    ok "$1: byte-for-byte expected/$2"
  else
    fail "$1: differs from expected/$2"
    diff -u "$HERE/expected/$2" "$WORK/$1/alertmanager.yml" || true
  fi
}
same plain alertmanager-without-slack.yml
same deadman alertmanager-without-slack-deadman.yml
same slack-no-token-key alertmanager-without-slack.yml

# 3. amtool accepts every variant.
for v in plain deadman slack slack-deadman; do
  if out="$(amtool check-config "/w/$v/alertmanager.yml" 2>&1)"; then
    ok "$v: amtool check-config ($(echo "$out" | grep -c 'receivers\|SUCCESS' >/dev/null && echo "$out" | sed -n 's/^ - \([0-9]* receivers\)$/\1/p'))"
  else
    fail "$v: amtool check-config"
    echo "$out"
  fi
done

# 4. Routing. Email and Telegram get what they got before; Slack only adds p1 and p2.
routes plain ops-email,ops-telegram severity=p1 alertname=X app=infra
routes plain ops-email,ops-telegram severity=p2 alertname=X app=infra
routes plain ops-email,ops-telegram severity=p3 alertname=X app=infra
routes plain watchdog-null alertname=Watchdog severity=none app=infra
routes plain ops-email alertname=X
routes deadman deadman alertname=Watchdog severity=none app=infra
routes slack ops-slack,ops-email,ops-telegram severity=p1 alertname=X app=infra
routes slack ops-slack,ops-email,ops-telegram severity=p2 alertname=X app=infra
routes slack ops-email,ops-telegram severity=p3 alertname=X app=infra
routes slack watchdog-null alertname=Watchdog severity=none app=infra
routes slack ops-email alertname=X
routes slack-deadman deadman alertname=Watchdog severity=none app=infra
routes slack-deadman ops-slack,ops-email,ops-telegram severity=p1 alertname=X app=infra

# 5. The Secret is mounted and read from a file; the token itself is nowhere.
sts_mounts() { # <variant> -> secret names mounted by the Alertmanager StatefulSet
  yq 'select(.kind == "StatefulSet" and .metadata.name == "prometheus-alertmanager")
      | .spec.template.spec.volumes[] | select(has("secret")) | .secret.secretName' "$WORK/$1/manifest.yaml" | tr '\n' ' '
}
[[ "$(sts_mounts slack)" == *"alertmanager-slack"* ]] \
  && ok "slack: StatefulSet mounts Secret alertmanager-slack" \
  || fail "slack: StatefulSet does not mount Secret alertmanager-slack ($(sts_mounts slack))"
for v in plain slack-no-token-key; do
  [[ "$(sts_mounts "$v")" != *"alertmanager-slack"* ]] \
    && ok "$v: StatefulSet does not mount alertmanager-slack" \
    || fail "$v: StatefulSet mounts alertmanager-slack"
done
cred="$(yq '.receivers[] | select(.name == "ops-slack") | .slack_configs[0].http_config.authorization.credentials_file' "$WORK/slack/alertmanager.yml")"
[[ "$cred" == "/etc/alertmanager/slack/token" ]] \
  && ok "slack: token read from $cred" \
  || fail "slack: credentials_file is '$cred'"
for v in slack slack-deadman; do
  if grep -rqF -e "$FAKE_TOKEN" -e "$FAKE_TOKEN_B64" -e "xoxb-" \
      "$WORK/$v/alertmanager.yml" "$WORK/$v/manifest.yaml" "$WORK/$v/values.yaml" "$WORK/$v/output.txt"; then
    fail "$v: the token is in a rendered file or in the script's output"
  else
    ok "$v: token not in the config, the manifest, the Helm values or the output"
  fi
done

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed. Rendered files: $WORK"
  exit 1
fi
echo "All checks passed. Rendered files: $WORK"
