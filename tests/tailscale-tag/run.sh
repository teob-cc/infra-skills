#!/usr/bin/env bash
# Checks that every server-mode and worker-mode `tailscale up` keeps the device's tailnet tag
# (TAILSCALE_TAG in env.properties), that no Tailscale key reaches a trace or a debug log, that the
# tenant worker's auth key is revoked, and that tools/doctor.sh warns about devices without their tag.
# Nothing leaves the machine: curl, ssh, kubectl, helm and tailscale are stand-ins (stubs/), the
# environments are fakes (envs/), HOME is an empty temp directory (no real SSH or age key is read)
# and the Tailscale API key is a fake one written into a temp copy of envs/.
#
# What it checks:
#   1. lint: every `tailscale up` command in tools/ passes --advertise-tags;
#   2. provision-common.sh: provision::tailscale_tag (set / unset with a warning / malformed / a
#      tenant tag refused for a server or worker / tenant mode allows only tag:tenant-<tenant>),
#      provision::tailscale_authkey_body, provision::tailscale_expected_tag,
#      provision::tailscale_key_id, provision::tailscale_key_response_summary, without_xtrace;
#   3. tailscale::create_authkey of the bare-metal and the cloud script sends a tagged key request,
#      and with `set -x` and --debug neither the API key nor the auth key reaches the output, and
#      the API key is never on curl's command line;
#   4. postinstall step 11 of both scripts, run against the tailscale stand-in;
#   5. the tenant worker's cloud-init passes --advertise-tags=tag:tenant-<tenant>;
#   6. provision-hetzner-cloud.sh stops before any call on a malformed tag, a tenant tag on a
#      server, a non-tenant tag on a tenant worker; an exported TAILSCALE_TAG is not read;
#   7. provision-gpu-host.sh, run end to end against stubs (also under bash -x, and with an
#      exported TAILSCALE_TAG the file does not set);
#   8. tools/doctor.sh: tailnet-tags OK / WARN / UNKN, no writing call, and under bash -x the API
#      key is in no output;
#   9. the tenant worker's auth key is revoked by id after the create: when the node enrolls, when
#      it does not, when the server create fails, and (EXIT trap) when a later step fails; never
#      twice; and the run under set -x shows no key;
#  10. a refused tagged mint stops the server path of both scripts (no untagged fallback); unset
#      TAILSCALE_TAG keeps going untagged; the substitutions run with xtrace off.
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
# Fake keys. The parts after the id are what must never show up in a trace or a log.
API_KEY="tskey-api-kApiStub1CNTRL-apisecretnotreal"; API_SECRET="apisecretnotreal"
AUTH_KEY="tskey-auth-kStub123CNTRL-notrealsecret"; AUTH_SECRET="notrealsecret"; AUTH_ID="kStub123CNTRL"
printf '%s\n' "$API_KEY" > "$WORK/envs/shared/secrets.plain/tailscale-api-key.txt"
export HOME="$WORK/home" INFRA_ENVS_ROOT="$WORK/envs" KUBECONFIG=/dev/null STUB_AUTHKEY="$AUTH_KEY"
export PATH="$HERE/stubs:$PATH"
unset SOPS_AGE_KEY_FILE SOPS_AGE_KEY TAILSCALE_TAG TENANT STUB_MINT

failures=0
ok() { echo "ok    $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { # <description> <command...>
  local d="$1"; shift
  if "$@"; then ok "$d"; else fail "$d"; fi
}
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }
no_secret_in() { # <file...>: neither key, nor its secret part, is in any of the files
  ! grep -qF -e "$API_KEY" -e "$API_SECRET" -e "$AUTH_KEY" -e "$AUTH_SECRET" "$@" 2>/dev/null
}

# Prints one function of a script: from `function NAME(){` to its closing `}` (after the heredoc
# TERMINATOR line when the function is one big heredoc that has `}` lines of its own), or the one
# line of a one-line function.
extract_fn() { # <file> <name> [heredoc terminator]
  awk -v name="$2" -v term="${3:-}" '
    index($0, "function " name "(){") == 1 { on = 1; if ($0 ~ /; }$/) { print; exit } }
    on { print }
    on && term != "" && $0 == term { seen = 1; next }
    on && $0 == "}" && (term == "" || seen) { exit }' "$1"
}
fns() { # <file> <name>... : several functions; a name starting with ? may be missing (a helper
  # older revisions of the script do not have, so the same test can run against them)
  local f="$1"; shift
  local n optional
  for n in "$@"; do
    optional=false
    if [[ "$n" == \?* ]]; then optional=true; n="${n#\?}"; fi
    if ! extract_fn "$f" "$n" | grep -q .; then
      $optional && continue
      echo "extract_fn: no function $n in $f" >&2; return 1
    fi
    extract_fn "$f" "$n"
  done
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
for bad in env-prod "tag:" "tag:a,tag:b" "tag:has space" "tag:x;id" tag:tenant-acme tag:tenant-; do
  if TAILSCALE_TAG="$bad" provision::tailscale_tag x >/dev/null 2>&1; then
    fail "tailscale_tag (server/worker): '$bad' accepted"
  else
    ok "tailscale_tag (server/worker): '$bad' refused"
  fi
done
out="$(TAILSCALE_TAG=tag:tenant-acme provision::tailscale_tag x 2>&1 >/dev/null || true)"
check "tailscale_tag (server/worker): a tenant tag names the problem" contains "$out" "is a tenant tag"
out="$(TAILSCALE_TAG='' provision::tailscale_tag x acme 2>"$WORK/err")"
check "tailscale_tag (tenant acme): unset -> tag:tenant-acme" [ "$out" = tag:tenant-acme ]
out="$(TAILSCALE_TAG=tag:tenant-acme provision::tailscale_tag x acme 2>"$WORK/err")"
check "tailscale_tag (tenant acme): tag:tenant-acme accepted" [ "$out" = tag:tenant-acme ]
for bad in tag:env-prod tag:tenant-other tag:gpu-worker; do
  if TAILSCALE_TAG="$bad" provision::tailscale_tag x acme >/dev/null 2>&1; then
    fail "tailscale_tag (tenant acme): '$bad' accepted"
  else
    ok "tailscale_tag (tenant acme): '$bad' refused"
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
check "expected_tag: tenant tag wins over a file's other tag" \
  [ "$(provision::tailscale_expected_tag "$WORK/envs/tenantbad/acme-2/env.properties")" = tag:tenant-acme ]
check "expected_tag: none" [ -z "$(provision::tailscale_expected_tag "$WORK/envs/untagged/env.properties")" ]
check "expected_tag: an exported TAILSCALE_TAG is not read" \
  [ -z "$(TAILSCALE_TAG=tag:env-evil provision::tailscale_expected_tag "$WORK/envs/untagged/env.properties")" ]
check "load_env: an exported TAILSCALE_TAG is cleared" \
  bash -c 'source "$1/tools/provision-common.sh"; export TAILSCALE_TAG=tag:env-evil; provision::load_env untagged; [ -z "${TAILSCALE_TAG:-}" ]' _ "$REPO"
check "key_id: tskey-auth-<id>-<secret> -> <id>" [ "$(provision::tailscale_key_id "$AUTH_KEY")" = "$AUTH_ID" ]
if provision::tailscale_key_id "<tailscale-auth-key>" >/dev/null; then fail "key_id: not a key accepted"; else ok "key_id: not a key -> fails"; fi
out="$(provision::tailscale_key_response_summary "{\"id\":\"$AUTH_ID\",\"key\":\"$AUTH_KEY\",\"expires\":\"2099-01-01T01:00:00Z\"}")"
check "key_response_summary: id and expiry ($out)" contains "$out" "\"id\":\"$AUTH_ID\""
check "key_response_summary: never the key" no_secret_in <(printf '%s' "$out")
out="$( (set -x; provision::without_xtrace true; echo "flags: $-") 2>/dev/null )"
check "without_xtrace: xtrace back on afterwards ($out)" contains "${out#flags: }" x
check "without_xtrace: inner command untraced" bash -c '
  source "$1/tools/provision-common.sh"
  inner(){ local s=hidden-inner-value; :; }
  out=$( { set -x; provision::without_xtrace inner; set +x; } 2>&1 ); [[ "$out" != *hidden-inner-value* ]]' _ "$REPO"

# --- 3. create_authkey ------------------------------------------------------------------------
echo "== 3. tailscale::create_authkey: tagged request; no key in a trace, a debug log or curl's argv"
mint() { # <script> <tag> <xtrace+debug: true|false> -> stdout in $WORK/mint.out, stderr in $WORK/mint.err
  rm -f "$WORK"/mint.log*
  STUB_LOG="$WORK/mint.log" bash -c '
    set -euo pipefail
    source "$1/tools/provision-common.sh"
    info(){ echo "info $*" >&2; }; ok(){ echo "ok $*" >&2; }; warn(){ echo "warn $*" >&2; }
    err(){ echo "err $*" >&2; }; dbg(){ if $DEBUG; then echo "dbg $*" >&2; fi; }; plan(){ echo "plan $*" >&2; }
    DEBUG=$3; DRY_RUN=false; TS_LAST_HTTP=""; TS_LAST_BODY=""
    tailscale::get_tailnet(){ echo -; }
    eval "$(cat)"
    if $3; then set -x; fi
    tailscale::read_api_token
    tailscale::create_authkey fake.example.com false true "$2"' _ "$REPO" "$2" "$3" \
    < <(fns "$REPO/tools/$1" tailscale::read_api_token__impl tailscale::read_api_token \
          tailscale::create_authkey__impl tailscale::create_authkey; \
        [[ "$1" == *cloud* ]] && fns "$REPO/tools/$1" tailscale::api__impl tailscale::api; \
        echo 'ENV_ROOT="$INFRA_ENVS_ROOT"') >"$WORK/mint.out" 2>"$WORK/mint.err"
}
for script in provision-hetzner-baremetal.sh provision-hetzner-cloud.sh; do
  check "$script: mint runs" mint "$script" tag:env-fake false
  check "$script: returns the key" [ "$(cat "$WORK/mint.out")" = "$AUTH_KEY" ]
  check "$script: request tagged tag:env-fake" \
    [ "$(jq -sc '.[0].capabilities.devices.create.tags' "$WORK/mint.log.keybody")" = '["tag:env-fake"]' ]
  check "$script: mint under set -x and --debug runs" mint "$script" tag:env-fake true
  check "$script: set -x/--debug: the trace is on (sanity)" grep -q '^+' "$WORK/mint.err"
  check "$script: set -x/--debug: no API key or auth key in stderr" no_secret_in "$WORK/mint.err"
  check "$script: the API key is never on curl's command line" no_secret_in "$WORK/mint.log"
done
mint provision-hetzner-baremetal.sh tag:env-fake true || true
check "provision-hetzner-baremetal.sh: --debug logs the key id, not the key" grep -qF "\"id\":\"$AUTH_ID\"" "$WORK/mint.err"

# --- 4. postinstall step 11 -----------------------------------------------------------------
echo "== 4. postinstall step 11 (tailscale up) of both scripts"
step11() { # <script> <tag> <logged in: true|false> <self json> -> output; tailscale up args in $WORK/s11.log.up
  local content
  content="$(eval "$(extract_fn "$REPO/tools/$1" gen_postinstall POSTINSTALL_EOF)"; gen_postinstall)"
  content=${content//@TAILSCALE_TAG@/$2}
  content=${content//@TAILSCALE_AUTHKEY@/$AUTH_KEY}
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
    contains "$up" "up --authkey $AUTH_KEY --ssh --hostname fake.example.com --accept-routes"
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
  check "$script: mints the server key through tailscale::server_authkey (tagged, fail-closed)" \
    grep -qF 'TAILSCALE_AUTHKEY=$(tailscale::server_authkey "${HOSTNAME}") || exit 1' "$REPO/tools/$script"
  check "$script: server_authkey mints with TAILSCALE_TAG" \
    grep -qF 'tailscale::create_authkey "$hostname" "false" "true" "${TAILSCALE_TAG:-}"' "$REPO/tools/$script"
done
check "provision-hetzner-cloud.sh: tenant postinstall substitutes the tag too" \
  [ "$(grep -cF '@TAILSCALE_TAG@/${TAILSCALE_TAG}}' "$REPO/tools/provision-hetzner-cloud.sh")" = 2 ]

# --- 5. tenant cloud-init ----------------------------------------------------------------------
echo "== 5. tenant worker cloud-init"
ci="$(eval "$(extract_fn "$REPO/tools/provision-hetzner-cloud.sh" gen_cloud_init_tenant CLOUDINIT_EOF)"
  gen_cloud_init_tenant "ssh-ed25519 AAAAstub" "$AUTH_KEY" acme-1 tag:tenant-acme)"
check "cloud-init: tailscale up --advertise-tags=tag:tenant-acme" \
  contains "$ci" "tailscale up --auth-key=file:/run/infra-skills/ts-authkey --hostname=acme-1 --advertise-tags=tag:tenant-acme"
check "cloud-init: the caller passes TAILSCALE_TAG" \
  grep -qF 'gen_cloud_init_tenant "${SSH_PUBKEY_CONTENT}" "${ts_authkey}" "${NODE_NAME}" "${TAILSCALE_TAG}"' "$REPO/tools/provision-hetzner-cloud.sh"

# --- 6. tag identity, refused before any call -----------------------------------------------------
echo "== 6. provision-hetzner-cloud.sh: the tag comes from the node's file and fits its role; refusals come before any call"
cloud() { # <name> <args...> -> rc in $rc, output in $WORK/<name>.out, calls in $WORK/<name>.log*
  local name="$1"; shift
  rc=0; STUB_LOG="$WORK/$name.log" "$REPO/tools/provision-hetzner-cloud.sh" "$@" >"$WORK/$name.out" 2>&1 || rc=$?
}
no_call() { [ ! -e "$WORK/$1.log" ] && [ ! -e "$WORK/$1.log.remote" ]; }
cloud badtag badtag --dry-run
check "badtag (malformed): exit 1" [ "$rc" = 1 ]
check "badtag: names the problem" grep -q "TAILSCALE_TAG must be one tag" "$WORK/badtag.out"
check "badtag: no curl or ssh call" no_call badtag
cloud tenanttag tenanttag --dry-run
check "server with tag:tenant-acme: exit 1" [ "$rc" = 1 ]
check "server with tag:tenant-acme: names the problem" grep -q "is a tenant tag" "$WORK/tenanttag.out"
check "server with tag:tenant-acme: no curl or ssh call" no_call tenanttag
cloud tenantbad tenantbad --worker acme-2 --dry-run
check "tenant worker acme-2 with tag:env-tenantbad: exit 1" [ "$rc" = 1 ]
check "tenant worker acme-2: names the problem" grep -q "must carry tag:tenant-acme" "$WORK/tenantbad.out"
check "tenant worker acme-2: no curl or ssh call" no_call tenantbad
export TAILSCALE_TAG=tag:tenant-acme
cloud exported noprivip --dry-run
unset TAILSCALE_TAG
check "exported TAILSCALE_TAG=tag:tenant-acme, file without a tag: not read (no tenant-tag refusal)" \
  bash -c '! grep -q "is a tenant tag" "$1"' _ "$WORK/exported.out"
check "exported TAILSCALE_TAG: the file's (unset) tag warns" grep -q "TAILSCALE_TAG is not set" "$WORK/exported.out"
check "exported TAILSCALE_TAG: stops at the missing PRIVATE_IP, no call" bash -c 'grep -q "PRIVATE_IP" "$1.out" && [ ! -e "$1.log" ]' _ "$WORK/exported"

# --- 7. provision-gpu-host.sh end to end ------------------------------------------------------
echo "== 7. provision-gpu-host.sh against stubs"
gpu() { # [-x] <env> <worker> -> output in $WORK/gpu.out, calls in $WORK/gpu.log*
  local trace=()
  if [[ "$1" == -x ]]; then trace=(bash -x); shift; fi
  rm -f "$WORK"/gpu.log*
  STUB_LOG="$WORK/gpu.log" STUB_TS_STATE="" ${trace[@]+"${trace[@]}"} "$REPO/tools/provision-gpu-host.sh" "$@" \
    --ssh-user stub --ssh-key /dev/null --skip-nvidia --skip-docker --skip-ufw >"$WORK/gpu.out" 2>&1
}
check "gpu-host fake gpu-worker: runs" gpu fake gpu-worker
check "gpu-host: key request tagged tag:gpu-worker" \
  [ "$(jq -sc '.[0].capabilities.devices.create.tags' "$WORK/gpu.log.keybody")" = '["tag:gpu-worker"]' ]
check "gpu-host: tailscale up --advertise-tags='tag:gpu-worker'" \
  grep -qF "sudo tailscale up --authkey '$AUTH_KEY' --ssh --hostname 'gpu-worker' --advertise-tags='tag:gpu-worker'" "$WORK/gpu.log.remote"
check "gpu-host: the API key is never on curl's command line" no_secret_in "$WORK/gpu.log"
check "gpu-host under bash -x: runs" gpu -x fake gpu-worker
check "gpu-host under bash -x: the trace is on (sanity)" grep -q '^+' "$WORK/gpu.out"
check "gpu-host under bash -x: no API key or auth key in the output" no_secret_in "$WORK/gpu.out"
mkdir -p "$WORK/envs/fake/gpu-untagged"
grep -v '^TAILSCALE_TAG=' "$WORK/envs/fake/gpu-worker/env.properties" > "$WORK/envs/fake/gpu-untagged/env.properties"
check "gpu-host fake gpu-untagged: runs" gpu fake gpu-untagged
check "gpu-host untagged: warns" grep -q "TAILSCALE_TAG is not set" "$WORK/gpu.out"
check "gpu-host untagged: key request untagged" [ "$(jq -sc '.[0].capabilities.devices.create.tags' "$WORK/gpu.log.keybody")" = '[]' ]
check "gpu-host untagged: no tag flag" bash -c '! grep -q advertise-tags "$1"' _ "$WORK/gpu.log.remote"
export TAILSCALE_TAG=tag:env-evil
check "gpu-host gpu-untagged with an exported TAILSCALE_TAG=tag:env-evil: runs" gpu fake gpu-untagged
unset TAILSCALE_TAG
check "gpu-host: the exported tag is not used (key request untagged)" \
  [ "$(jq -sc '.[0].capabilities.devices.create.tags' "$WORK/gpu.log.keybody")" = '[]' ]
check "gpu-host: the exported tag is not advertised" bash -c '! grep -q "tag:env-evil" "$1"' _ "$WORK/gpu.log.remote"
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
check "doctor: the API key is never on curl's command line" no_secret_in "$WORK/doctor.log"
STUB_LOG="$WORK/doctor-x.log" STUB_CONTEXT_ENV=fake STUB_DEVICES="$(dev all-tagged)" \
  bash -x "$REPO/tools/doctor.sh" fake >"$WORK/doctor-x.out" 2>&1 || true
check "doctor under bash -x: the trace is on and reaches both Tailscale checks (sanity)" \
  bash -c 'grep -q "^+" "$1" && grep -q "without_xtrace check_tailscale_tags" "$1" && grep -q "tailnet-tags" "$1"' _ "$WORK/doctor-x.out"
check "doctor under bash -x: no API key in the output" no_secret_in "$WORK/doctor-x.out"
echo "-- doctor fake (server untagged), text output:"
STUB_LOG="$WORK/doctor.log" STUB_CONTEXT_ENV=fake STUB_DEVICES="$(dev server-untagged)" \
  "$REPO/tools/doctor.sh" fake 2>/dev/null | grep -A1 'tailnet-tags' || true

# --- 9. tenant worker: the auth key is revoked after the create -----------------------------------
echo "== 9. tenant worker auth key: revoked by id, enrolled or not"
CLOUD="$REPO/tools/provision-hetzner-cloud.sh"
tenant() { # <case: enrolled|absent|create-fails|later-fails> <xtrace: true|false> [revoke: ok|fail|flaky]
  #   -> rc in $rc, output in $WORK/tenant.out. Runs the script's own tenant::preflight (reads the
  #   API key, tests it, checks the policy) and tenant::create (cleanup_stale_devices, mint, create,
  #   enrolment, revoke) against the curl stub; only Hetzner, ssh-keygen and sleep are stand-ins.
  local devices=/dev/null
  case "$1" in enrolled) devices="$HERE/devices/all-tagged.json" ;; esac
  rm -f "$WORK"/tenant.log* "$WORK/tenant.userdata"
  rc=0
  STUB_LOG="$WORK/tenant.log" STUB_DEVICES="$devices" STUB_REVOKE="${3:-ok}" CASE="$1" WORK_DIR="$WORK" bash -c '
    set -euo pipefail
    source "$1/tools/provision-common.sh"
    info(){ echo "info $*" >&2; }; ok(){ echo "ok $*" >&2; }; warn(){ echo "warn $*" >&2; }
    err(){ echo "err $*" >&2; }; dbg(){ :; }; plan(){ echo "plan $*" >&2; }; env_set(){ :; }; sleep(){ :; }
    DRY_RUN=false; DEBUG=false; TS_LAST_HTTP=""; TS_LAST_BODY=""; ENV_ROOT="$INFRA_ENVS_ROOT"; TS_API_TOKEN=""
    NODE_NAME=acme-1; TENANT=acme; ENV_NAME=fake; ENV_FILE=/dev/null
    TAILSCALE_TAG=tag:tenant-acme; TS_DEVICE_TAG=tag:tenant-acme; TS_ENROLL_TRIES=2
    MASTER_HOSTNAME=fake.example.com; MASTER_VLAN_IP=100.100.0.1
    CREATE_SERVER=true; DESTROY=false; NO_JOIN=true; TAILSCALE_POLICY_CHECK=warn
    HCLOUD_SERVER_NAME=acme-1; HCLOUD_SERVER_TYPE=cx33; HCLOUD_IMAGE=ubuntu-24.04; HCLOUD_LOCATION=hel1
    HCLOUD_FIREWALL_NAME=acme-1; HCLOUD_SERVER_ID=""; HCLOUD_PUBLIC_IP=""; HCLOUD_LABELS_TEXT=stub
    PROV_SSH_PUB=/dev/null; SSH_PUBKEY_CONTENT="ssh-ed25519 AAAAstub"
    ssh-keygen(){ echo "256 SHA256:stubfingerprint stub (ED25519)"; }
    tailscale::get_tailnet(){ echo -; }
    hcloud::token_file(){ echo stub; }; hcloud::read_token(){ HCLOUD_TOKEN=stub; }
    hcloud::get_server(){ :; }; hcloud::check_server_type(){ :; }; hcloud::create_ssh_key(){ echo 11; }
    hcloud::ensure_firewall(){ echo 22; }; hcloud::firewall_applied(){ :; }; hcloud::apply_firewall(){ :; }
    hcloud::create_server(){ printf "%s" "$6" > "$WORK_DIR/tenant.userdata"
      [[ $CASE != create-fails ]] || return 1; HCLOUD_SERVER_ID=42; HCLOUD_PUBLIC_IP=192.0.2.60; }
    hcloud::wait_for_running(){ [[ $CASE != later-fails ]]; }
    eval "$(cat)"
    if $2; then set -x; fi
    tenant::preflight
    rc=0; tenant::create || rc=$?
    set +x
    if [[ -s "$STUB_LOG.revoked" ]]; then echo "revoked-before-return"; fi
    echo "attempts-before-return: $(cat "$STUB_LOG.revoke-attempts" 2>/dev/null | wc -l | tr -d " ")"
    exit "$rc"' _ "$REPO" "$2" \
    < <(fns "$CLOUD" tailscale::read_api_token__impl tailscale::read_api_token tailscale::api__impl tailscale::api \
          tailscale::create_authkey__impl tailscale::create_authkey tailscale::devices tailscale::get_device_ip \
          tailscale::delete_device '?tailscale::cleanup_stale_devices__impl' tailscale::cleanup_stale_devices \
          tailscale::policy_problems tailscale::policy_tests \
          tenant::preflight tenant::create '?tenant::create_server_with_key' tenant::revoke_key '?tenant::await_enrollment'
        extract_fn "$CLOUD" gen_cloud_init_tenant CLOUDINIT_EOF) >"$WORK/tenant.out" 2>&1 || rc=$?
}
revoked_once() { [ "$(cat "$WORK/tenant.log.revoked" 2>/dev/null)" = "$AUTH_ID" ]; }
tenant enrolled false
check "enrolled: tenant::create succeeds (rc $rc)" [ "$rc" = 0 ]
check "enrolled: the key went into the user data (sanity)" grep -qF "$AUTH_KEY" "$WORK/tenant.userdata"
check "enrolled: key $AUTH_ID revoked, once" revoked_once
check "enrolled: revoked by tenant::create itself, not only by the EXIT trap" grep -q "^revoked-before-return" "$WORK/tenant.out"
check "enrolled: says so" grep -q "Revoked the node's Tailscale auth key $AUTH_ID" "$WORK/tenant.out"
tenant absent false
check "not enrolled: tenant::create fails (rc $rc)" [ "$rc" != 0 ]
check "not enrolled: key revoked, once" revoked_once
check "not enrolled: revoked by tenant::create itself" grep -q "^revoked-before-return" "$WORK/tenant.out"
check "not enrolled: says the node did not appear" grep -q "did not appear on the tailnet" "$WORK/tenant.out"
tenant create-fails false
check "server create fails: tenant::create fails (rc $rc)" [ "$rc" != 0 ]
check "server create fails: key revoked, once" revoked_once
check "server create fails: revoked by tenant::create itself" grep -q "^revoked-before-return" "$WORK/tenant.out"
tenant later-fails false
check "a later step fails (EXIT trap): rc $rc" [ "$rc" != 0 ]
check "a later step fails: key revoked, once" revoked_once
check "a later step fails: revoked by the EXIT trap (not before return)" bash -c '! grep -q "^revoked-before-return" "$1"' _ "$WORK/tenant.out"
tenant enrolled true
check "enrolled under set -x: runs (rc $rc)" [ "$rc" = 0 ]
check "enrolled under set -x: the trace is on (sanity)" grep -q '^+' "$WORK/tenant.out"
check "enrolled under set -x: no API key or auth key in the output" no_secret_in "$WORK/tenant.out"
check "enrolled under set -x: the real tenant::preflight and cleanup_stale_devices ran in the trace (sanity)" \
  bash -c 'grep -q "^+ tenant::preflight" "$1" && grep -q "cleanup_stale_devices" "$1" && grep -q "DELETE https://api.tailscale.com/api/v2/device/3" "$2"' _ "$WORK/tenant.out" "$WORK/tenant.log.writes"
check "enrolled: 1 revoke attempt" grep -q "^attempts-before-return: 1$" "$WORK/tenant.out"
tenant enrolled false flaky
check "revoke fails once, then succeeds: revoked (rc $rc)" bash -c '[ "$2" = 0 ] && grep -q "^attempts-before-return: 2$" "$1"' _ "$WORK/tenant.out" "$rc"
check "revoke fails once: key revoked, once" revoked_once
tenant enrolled false fail
check "revoke keeps failing, node enrolled: tenant::create succeeds (rc $rc)" [ "$rc" = 0 ]
check "revoke keeps failing, enrolled: 3 attempts, then the EXIT trap tries again" \
  bash -c 'grep -q "^attempts-before-return: 3$" "$1" && [ "$(wc -l < "$2" | tr -d " ")" = 6 ]' _ "$WORK/tenant.out" "$WORK/tenant.log.revoke-attempts"
check "revoke keeps failing, enrolled: a warning with the key id" \
  grep -q "^warn Could not revoke Tailscale auth key $AUTH_ID .*the one-off key is spent" "$WORK/tenant.out"
check "revoke keeps failing, enrolled: no revoke error" bash -c '! grep -q "^err Could not revoke" "$1"' _ "$WORK/tenant.out"
check "revoke keeps failing, enrolled: no key in the output" no_secret_in "$WORK/tenant.out"
tenant absent false fail
check "revoke keeps failing, node not enrolled: exits non-zero (rc $rc)" [ "$rc" != 0 ]
check "revoke keeps failing, not enrolled: an error with the key id and the manual revoke" \
  bash -c 'grep -q "^err Could not revoke Tailscale auth key $2 .*did not enrol" "$1" && grep -q "^err Revoke it now: .*key $2, Revoke" "$1"' _ "$WORK/tenant.out" "$AUTH_ID"
check "revoke keeps failing, not enrolled: no key in the output" no_secret_in "$WORK/tenant.out"
tenant absent true fail
check "revoke keeps failing, not enrolled, set -x: exits non-zero, no key in the output (rc $rc)" \
  bash -c '[ "$2" != 0 ] && grep -q "^+" "$1"' _ "$WORK/tenant.out" "$rc"
check "revoke keeps failing, not enrolled, set -x: no key in the output" no_secret_in "$WORK/tenant.out"
check "tenant path: the API key is never on curl's command line" no_secret_in "$WORK/tenant.log"
check "tenant key request: single use, preauthorized, 1 h, tag:tenant-acme" \
  [ "$(jq -sc '.[0] | [.capabilities.devices.create | .reusable, .preauthorized, .tags[0]] + [.expirySeconds]' "$WORK/tenant.log.keybody")" = '[false,true,"tag:tenant-acme",3600]' ]

# --- 10. fail closed on a refused tagged mint --------------------------------------------------
echo "== 10. server path: a refused tagged mint stops the run"
mainblock() { # <script> -> its auth-key and substitution block, as it stands in the script
  local start='# Create Tailscale auth key. With TAILSCALE_TAG set'
  [[ "$1" == *baremetal* ]] && start='# Create Tailscale auth key via API for this host'
  awk -v s="$start" 'index($0, s) { on = 1 } on { print } on && $0 == "    provision::xtrace_restore" { exit }' "$REPO/tools/$1"
}
serverkey() { # <script> <tag> <mint: ok|deny> <xtrace: true|false> [notoken] -> rc in $rc, output in $WORK/sk.out
  local script="$1"
  rm -f "$WORK"/sk.log*
  rc=0
  BLOCK="$(mainblock "$script")" STUB_LOG="$WORK/sk.log" STUB_MINT="$3" STUB_DEVICES="$HERE/devices/all-tagged.json" bash -c '
    set -euo pipefail
    source "$1/tools/provision-common.sh"
    info(){ echo "info $*" >&2; }; ok(){ echo "ok $*" >&2; }; warn(){ echo "warn $*" >&2; }
    err(){ echo "err $*" >&2; }; dbg(){ :; }; plan(){ echo "plan $*" >&2; }
    DEBUG=false; DRY_RUN=false; TS_LAST_HTTP=""; TS_LAST_BODY=""; TS_API_TOKEN=""
    ENV_ROOT="$INFRA_ENVS_ROOT"; [[ "$4" == notoken ]] && ENV_ROOT=/nonexistent
    TAILSCALE_TAG="$2"; HOSTNAME=fake.example.com; SKIP_TAILSCALE=false; remote_state=new; TAILSCALE_IP=""
    VLAN_IP=192.168.100.1/24; EXTERNAL_IP=192.0.2.10; WORKER_MODE=false; PRIVATE_IP_ADDR=10.0.0.2; NODE_ROLE=server
    tailscale::get_tailnet(){ echo -; }
    POSTINSTALL_CONTENT="authkey=@TAILSCALE_AUTHKEY@ tag=@TAILSCALE_TAG@"
    eval "$(cat)"
    # bare metal reads the API key in its pre-flight; the cloud block reads it itself
    [[ "$4" == notoken ]] || tailscale::read_api_token
    if $3; then set -x; fi
    eval "$BLOCK"
    set +x
    echo "continued: ${POSTINSTALL_CONTENT//$STUB_AUTHKEY/<the-auth-key>}"' _ "$REPO" "$2" "$4" "${5:-}" \
    < <(fns "$REPO/tools/$script" tailscale::read_api_token__impl tailscale::read_api_token \
          tailscale::create_authkey__impl tailscale::create_authkey tailscale::server_authkey \
          tailscale::api__impl tailscale::api tailscale::delete_device tailscale::cleanup_stale_devices
        if [[ "$script" == *cloud* ]]; then fns "$REPO/tools/$script" '?tailscale::cleanup_stale_devices__impl' tailscale::devices; fi) >"$WORK/sk.out" 2>&1 || rc=$?
}
for script in provision-hetzner-baremetal.sh provision-hetzner-cloud.sh; do
  check "$script: the block is found (sanity)" bash -c '[[ "$1" == *server_authkey* && "$1" == *xtrace_restore* ]]' _ "$(mainblock "$script")"
  serverkey "$script" tag:env-fake deny false
  check "$script: tagged, mint refused: stops (rc $rc)" [ "$rc" != 0 ]
  check "$script: tagged, mint refused: does not go on" bash -c '! grep -q "^continued" "$1"' _ "$WORK/sk.out"
  check "$script: tagged, mint refused: says why" grep -q "stopping, no untagged fallback" "$WORK/sk.out"
  serverkey "$script" "" deny false
  check "$script: untagged, mint refused: goes on (rc $rc)" [ "$rc" = 0 ]
  check "$script: untagged, mint refused: no key, warns" \
    bash -c 'grep -q "^continued: authkey= tag=$" "$1" && grep -q "^warn Failed to create a Tailscale auth key" "$1"' _ "$WORK/sk.out"
  serverkey "$script" tag:env-fake ok false
  check "$script: tagged, minted: goes on with the key and the tag" grep -q "^continued: authkey=<the-auth-key> tag=tag:env-fake$" "$WORK/sk.out"
  serverkey "$script" tag:env-fake ok true
  check "$script: tagged, minted, set -x: the trace is on (sanity)" grep -q '^+' "$WORK/sk.out"
  check "$script: tagged, minted, set -x: the real cleanup_stale_devices ran (sanity)" grep -q "DELETE https://api.tailscale.com/api/v2/device/1" "$WORK/sk.log.writes"
  check "$script: tagged, minted, set -x: no API key or auth key in the output" no_secret_in "$WORK/sk.out"
  check "$script: xtrace is back on after the block" grep -q '^+ set +x' "$WORK/sk.out"
done
serverkey provision-hetzner-cloud.sh tag:env-fake ok false notoken
check "provision-hetzner-cloud.sh: tagged, no API key readable: stops (rc $rc)" \
  bash -c '[ "$2" != 0 ] && grep -q "no tagged key can be minted" "$1" && ! grep -q "^continued" "$1"' _ "$WORK/sk.out" "$rc"

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed. Work dir: $WORK"
  exit 1
fi
echo "All checks passed. Work dir: $WORK"
