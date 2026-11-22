#!/usr/bin/env bash
# Checks that every server-mode and worker-mode `tailscale up` keeps the device's tailnet tag
# (TAILSCALE_TAG in env.properties), and that tools/doctor.sh warns about devices without it.
# Nothing leaves the machine: curl, ssh, kubectl, helm and tailscale are stand-ins (stubs/), the
# environments are fakes (envs/), HOME is an empty temp directory (no real SSH or age key is read)
# and the Tailscale API key is a fake one written into a temp copy of envs/.
#
# What it checks:
#   1. lint: every `tailscale up` command in tools/ passes --advertise-tags;
#   2. provision-common.sh: provision::tailscale_tag (set / unset with a warning / malformed),
#      provision::tailscale_authkey_body (tagged and untagged key requests),
#      provision::tailscale_expected_tag (TAILSCALE_TAG, the tenant default, none);
#   3. tailscale::create_authkey of the bare-metal and the cloud script sends a tagged key request;
#   4. postinstall step 11 of both scripts, run against the tailscale stand-in: `tailscale up`
#      gets --advertise-tags=<tag> when TAILSCALE_TAG is set and no tag flag when it is not, and an
#      already logged-in device without the tag gets a warning; both scripts substitute the tag;
#   5. the tenant worker's cloud-init passes --advertise-tags=tag:tenant-<tenant>;
#   6. provision-hetzner-cloud.sh refuses a malformed TAILSCALE_TAG before any call;
#   7. provision-gpu-host.sh, run end to end against stubs: tagged key request and
#      `tailscale up ... --advertise-tags=tag:gpu-worker`; unset: untagged with a warning;
#   8. tools/doctor.sh: tailnet-tags is OK when every node carries its tag, WARN for an untagged
#      server, a server with another tag, an untagged worker, a tag with TAILSCALE_TAG unset;
#      UNKN when the API cannot be read; and doctor makes no writing call.
#
# Usage: tests/tailscale-tag/run.sh        (needs bash, jq)
# Literal ${...} in single quotes below are code the tests look for, not expansions.
# shellcheck disable=SC2016
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "Missing: jq" >&2; exit 1; }
WORK="$(mktemp -d -t tailscale-tag-test-XXXX)"
mkdir -p "$WORK/home" "$WORK/envs/shared/secrets.plain"
cp -R "$HERE/envs/." "$WORK/envs/"
printf 'tskey-api-kstub-notreal\n' > "$WORK/envs/shared/secrets.plain/tailscale-api-key.txt"
export HOME="$WORK/home" INFRA_ENVS_ROOT="$WORK/envs" KUBECONFIG=/dev/null
export PATH="$HERE/stubs:$PATH"
unset SOPS_AGE_KEY_FILE SOPS_AGE_KEY TAILSCALE_TAG TENANT

failures=0
ok() { echo "ok    $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { # <description> <command...>
  local d="$1"; shift
  if "$@"; then ok "$d"; else fail "$d"; fi
}
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }

# Prints one function of a script: from `function NAME(){` to its closing `}` (after the heredoc
# TERMINATOR line when the function is one big heredoc that has `}` lines of its own).
extract_fn() { # <file> <name> [heredoc terminator]
  awk -v name="$2" -v term="${3:-}" '
    index($0, "function " name "(){") == 1 { on = 1 }
    on { print }
    on && term != "" && $0 == term { seen = 1; next }
    on && $0 == "}" && (term == "" || seen) { exit }' "$1"
}

# --- 1. lint ------------------------------------------------------------------------------
echo "== 1. every tailscale up passes --advertise-tags"
ups="$(grep -rnE '(^|[[:space:]";(])(sudo )?tailscale up( |$)' "$REPO/tools" \
  | grep -vE ':[0-9]+:[[:space:]]*(#|echo|info|warn|err|plan|ok) ' || true)"
n=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  n=$((n + 1))
  where="${line#"$REPO"/}"; where="${where%%:*}:$(cut -d: -f2 <<<"$line")"
  if [[ "$line" == *"--advertise-tags"* || "$line" == *'TS_TAG_ARGS[@]'* ]]; then
    ok "$where"
  else
    fail "$where has no --advertise-tags: ${line#*:*:}"
  fi
done <<<"$ups"
if (( n >= 4 )); then ok "found $n tailscale up commands"; else fail "found only $n tailscale up commands (expected 4)"; fi

# --- 2. provision-common helpers ----------------------------------------------------------
echo "== 2. provision-common.sh helpers"
# shellcheck disable=SC1091
source "$REPO/tools/provision-common.sh"
out="$(TAILSCALE_TAG=tag:env-fake provision::tailscale_tag x 2>"$WORK/err")"
check "tailscale_tag: set -> prints it" [ "$out" = tag:env-fake ]
check "tailscale_tag: set -> no warning" [ ! -s "$WORK/err" ]
out="$(TAILSCALE_TAG='' provision::tailscale_tag envs/x/env.properties 2>"$WORK/err")"
check "tailscale_tag: unset -> prints nothing, exit 0" [ -z "$out" ]
check "tailscale_tag: unset -> warns" grep -q "TAILSCALE_TAG is not set (envs/x/env.properties)" "$WORK/err"
for bad in env-prod "tag:" "tag:a,tag:b" "tag:has space" "tag:x;id"; do
  if TAILSCALE_TAG="$bad" provision::tailscale_tag x >/dev/null 2>&1; then
    fail "tailscale_tag: '$bad' accepted"
  else
    ok "tailscale_tag: '$bad' refused"
  fi
done
body="$(provision::tailscale_authkey_body gpu-worker.fake.example.com false true tag:gpu-worker)"
check "authkey_body: tags [tag:gpu-worker]" [ "$(jq -c '.capabilities.devices.create.tags' <<<"$body")" = '["tag:gpu-worker"]' ]
check "authkey_body: single use, not ephemeral, preauthorized, 1 h" \
  [ "$(jq -c '[.capabilities.devices.create | .reusable, .ephemeral, .preauthorized] + [.expirySeconds]' <<<"$body")" = '[false,false,true,3600]' ]
body="$(provision::tailscale_authkey_body "$(printf 'a%.0s' {1..80}).example.com")"
check "authkey_body: untagged -> tags []" [ "$(jq -c '.capabilities.devices.create.tags' <<<"$body")" = '[]' ]
check "authkey_body: description capped at 50" [ "$(jq -r '.description | length' <<<"$body")" = 50 ]
check "expected_tag: TAILSCALE_TAG" [ "$(provision::tailscale_expected_tag "$WORK/envs/fake/env.properties")" = tag:env-fake ]
check "expected_tag: tenant default" [ "$(provision::tailscale_expected_tag "$WORK/envs/fake/acme-1/env.properties")" = tag:tenant-acme ]
check "expected_tag: none" [ -z "$(provision::tailscale_expected_tag "$WORK/envs/untagged/env.properties")" ]
check "expected_tag: caller's TAILSCALE_TAG untouched" [ -z "${TAILSCALE_TAG:-}" ]

# --- 3. create_authkey ------------------------------------------------------------------------
echo "== 3. tailscale::create_authkey sends a tagged key request"
for script in provision-hetzner-baremetal.sh provision-hetzner-cloud.sh; do
  : > "$WORK/calls.log.keybody"
  key="$(STUB_LOG="$WORK/calls.log" bash -c '
    set -euo pipefail
    source "$1/tools/provision-common.sh"
    info(){ :; }; ok(){ :; }; warn(){ echo "warn $*" >&2; }; err(){ :; }; dbg(){ :; }
    DEBUG=false; TS_API_TOKEN=tskey-api-kstub-notreal; TS_LAST_HTTP=""; TS_LAST_BODY=""
    tailscale::get_tailnet(){ echo -; }
    # The cloud script goes through tailscale::api; this stand-in hands the body to the curl stub.
    tailscale::api(){ curl -sS -X "$1" "https://api.tailscale.com/api/v2$2" -d "$3"; }
    eval "$(cat)"
    tailscale::create_authkey fake.example.com false true tag:env-fake' _ "$REPO" \
    < <(extract_fn "$REPO/tools/$script" tailscale::create_authkey))"
  check "$script: returns the key" [ "$key" = tskey-auth-stub-notreal ]
  check "$script: request tagged tag:env-fake" \
    [ "$(jq -sc '.[0].capabilities.devices.create.tags' "$WORK/calls.log.keybody")" = '["tag:env-fake"]' ]
done

# --- 4. postinstall step 11 -----------------------------------------------------------------
echo "== 4. postinstall step 11 (tailscale up) of both scripts"
step11() { # <script> <tag> <logged in: true|false> <self json> -> output; tailscale up args in $WORK/s11.log.up
  local content
  content="$(eval "$(extract_fn "$REPO/tools/$1" gen_postinstall POSTINSTALL_EOF)"; gen_postinstall)"
  content=${content//@TAILSCALE_TAG@/$2}
  content=${content//@TAILSCALE_AUTHKEY@/tskey-auth-stub-notreal}
  content=${content//@PUBLIC_HOSTNAME@/fake.example.com}
  printf '%s\n' "$content" > "$WORK/postinstall-$1-${2:-untagged}.sh"
  rm -f "$WORK/s11.log" "$WORK/s11.log.up"
  STUB_LOG="$WORK/s11.log" STUB_TS_LOGGED_IN="$3" STUB_TS_SELF_JSON="$4" bash -c '
    set -euo pipefail
    skip_if_done(){ return 1; }; mark_step(){ :; }
    eval "$(cat)"' < <(awk '/^# Step 11: /{on=1} /^# Step 12: /{on=0} on' <<<"$content") 2>&1
}
for script in provision-hetzner-baremetal.sh provision-hetzner-cloud.sh; do
  out="$(step11 "$script" tag:env-fake false '{}')"
  up="$(cat "$WORK/s11.log.up" 2>/dev/null || true)"
  check "$script: tagged: tailscale up --advertise-tags=tag:env-fake" contains "$up" "--advertise-tags=tag:env-fake"
  check "$script: tagged: tailscale up keeps --authkey --ssh --hostname --accept-routes" \
    contains "$up" "up --authkey tskey-auth-stub-notreal --ssh --hostname fake.example.com --accept-routes"
  check "$script: rendered postinstall parses (bash -n)" bash -n "$WORK/postinstall-$script-tag:env-fake.sh"
  out="$(step11 "$script" "" false '{}')"
  up="$(cat "$WORK/s11.log.up" 2>/dev/null || true)"
  check "$script: untagged: tailscale up runs" contains "$up" "up --authkey"
  check "$script: untagged: no tag flag" lacks "$up" "advertise-tags"
  out="$(step11 "$script" tag:env-fake true '{"Self":{"HostName":"fake","Tags":["tag:env-other"]}}')"
  check "$script: logged in without the tag: warns" contains "$out" "does not carry tag:env-fake"
  check "$script: logged in: no tailscale up" [ ! -e "$WORK/s11.log.up" ]
  out="$(step11 "$script" tag:env-fake true '{"Self":{"HostName":"fake","Tags":["tag:env-fake"]}}')"
  check "$script: logged in with the tag: no warning" lacks "$out" "WARNING"
  check "$script: substitutes @TAILSCALE_TAG@ from TAILSCALE_TAG" \
    grep -qF '//@TAILSCALE_TAG@/${TAILSCALE_TAG}}' "$REPO/tools/$script"
  check "$script: mints the server key with TAILSCALE_TAG" \
    grep -qE 'tailscale::create_authkey "\$\{HOSTNAME\}" "false" "true" "\$\{TAILSCALE_TAG\}"' "$REPO/tools/$script"
done
check "provision-hetzner-cloud.sh: tenant postinstall substitutes the tag too" \
  [ "$(grep -cF '@TAILSCALE_TAG@/${TAILSCALE_TAG}}' "$REPO/tools/provision-hetzner-cloud.sh")" = 2 ]

# --- 5. tenant cloud-init ----------------------------------------------------------------------
echo "== 5. tenant worker cloud-init"
ci="$(eval "$(extract_fn "$REPO/tools/provision-hetzner-cloud.sh" gen_cloud_init_tenant CLOUDINIT_EOF)"
  gen_cloud_init_tenant "ssh-ed25519 AAAAstub" tskey-auth-stub-notreal acme-1 tag:tenant-acme)"
check "cloud-init: tailscale up --advertise-tags=tag:tenant-acme" \
  contains "$ci" "tailscale up --auth-key=file:/run/infra-skills/ts-authkey --hostname=acme-1 --advertise-tags=tag:tenant-acme"
check "cloud-init: the caller passes TAILSCALE_TAG" \
  grep -qF 'gen_cloud_init_tenant "${SSH_PUBKEY_CONTENT}" "${ts_authkey}" "${NODE_NAME}" "${TAILSCALE_TAG}"' "$REPO/tools/provision-hetzner-cloud.sh"

# --- 6. malformed tag refused --------------------------------------------------------------------
echo "== 6. a malformed TAILSCALE_TAG stops the cloud provisioner before any call"
rc=0; STUB_LOG="$WORK/bad.log" "$REPO/tools/provision-hetzner-cloud.sh" badtag --dry-run >"$WORK/bad.out" 2>&1 || rc=$?
check "provision-hetzner-cloud.sh badtag: exit 1" [ "$rc" = 1 ]
check "provision-hetzner-cloud.sh badtag: names the problem" grep -q "TAILSCALE_TAG must be one tag" "$WORK/bad.out"
check "provision-hetzner-cloud.sh badtag: no curl or ssh call" bash -c '[ ! -e "$1" ] && [ ! -e "$1.remote" ]' _ "$WORK/bad.log"

# --- 7. provision-gpu-host.sh end to end ------------------------------------------------------
echo "== 7. provision-gpu-host.sh against stubs"
gpu() { # <worker dir> -> output in $WORK/gpu.out, calls in $WORK/gpu.log*
  rm -f "$WORK"/gpu.log*
  STUB_LOG="$WORK/gpu.log" STUB_TS_STATE="" "$REPO/tools/provision-gpu-host.sh" "$@" \
    --ssh-user stub --ssh-key /dev/null --skip-nvidia --skip-docker --skip-ufw >"$WORK/gpu.out" 2>&1
}
check "gpu-host fake gpu-worker: runs" gpu fake gpu-worker
check "gpu-host: key request tagged tag:gpu-worker" \
  [ "$(jq -sc '.[0].capabilities.devices.create.tags' "$WORK/gpu.log.keybody")" = '["tag:gpu-worker"]' ]
check "gpu-host: tailscale up --advertise-tags='tag:gpu-worker'" \
  grep -qF "sudo tailscale up --authkey 'tskey-auth-stub-notreal' --ssh --hostname 'gpu-worker' --advertise-tags='tag:gpu-worker'" "$WORK/gpu.log.remote"
mkdir -p "$WORK/envs/fake/gpu-untagged"
grep -v '^TAILSCALE_TAG=' "$WORK/envs/fake/gpu-worker/env.properties" > "$WORK/envs/fake/gpu-untagged/env.properties"
check "gpu-host fake gpu-untagged: runs" gpu fake gpu-untagged
check "gpu-host untagged: warns" grep -q "TAILSCALE_TAG is not set" "$WORK/gpu.out"
check "gpu-host untagged: key request untagged" [ "$(jq -sc '.[0].capabilities.devices.create.tags' "$WORK/gpu.log.keybody")" = '[]' ]
check "gpu-host untagged: no tag flag" bash -c '! grep -q advertise-tags "$1"' _ "$WORK/gpu.log.remote"
rm -rf "$WORK/envs/fake/gpu-untagged"

# --- 8. doctor.sh ------------------------------------------------------------------------------
echo "== 8. tools/doctor.sh tailnet-tags"
doctor() { # <env> <devices fixture|fail> -> the tailnet-tags finding as "STATUS<TAB>detail"
  STUB_LOG="$WORK/doctor.log" STUB_CONTEXT_ENV="$1" STUB_DEVICES="$2" \
    "$REPO/tools/doctor.sh" "$1" --json 2>/dev/null \
    | jq -r '.checks[] | select(.check == "tailnet-tags") | "\(.status)\t\(.detail)"'
}
dev() { echo "$HERE/devices/$1.json"; }
r="$(doctor fake "$(dev all-tagged)")"
check "all tagged -> OK ($r)" contains "$r" $'OK\tserver: tag:env-fake; acme-1: tag:tenant-acme; gpu-worker: tag:gpu-worker'
r="$(doctor fake "$(dev server-untagged)")"
check "server untagged -> WARN ($r)" contains "$r" $'WARN\tserver (fake.example.com): untagged, user-owned; expected tag:env-fake'
r="$(doctor fake "$(dev server-other-tag)")"
check "server with another tag -> WARN ($r)" contains "$r" $'WARN\tserver (fake.example.com): carries tag:env-other; expected tag:env-fake'
r="$(doctor fake "$(dev worker-untagged)")"
check "gpu-worker untagged -> WARN ($r)" contains "$r" $'WARN\tgpu-worker (gpu-worker): untagged, user-owned; expected tag:gpu-worker'
r="$(doctor untagged "$(dev untagged-env-tagged-device)")"
check "TAILSCALE_TAG unset, device tagged -> WARN ($r)" contains "$r" "carries tag:env-untagged but TAILSCALE_TAG is not set"
r="$(doctor untagged "$(dev all-tagged)")"
check "server not on the tailnet -> WARN ($r)" contains "$r" $'WARN\tserver: no device found on the tailnet'
r="$(doctor fake fail)"
check "API unreadable -> UNKN ($r)" contains "$r" $'UNKN\tcould not read the device list'
check "doctor made no writing call" [ ! -e "$WORK/doctor.log.writes" ]
echo "-- doctor fake (server untagged), text output:"
STUB_LOG="$WORK/doctor.log" STUB_CONTEXT_ENV=fake STUB_DEVICES="$(dev server-untagged)" \
  "$REPO/tools/doctor.sh" fake 2>/dev/null | grep -A1 'tailnet-tags' || true

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed. Work dir: $WORK"
  exit 1
fi
echo "All checks passed. Work dir: $WORK"
