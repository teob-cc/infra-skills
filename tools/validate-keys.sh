#!/usr/bin/env bash
# TEO-127: read-only key validation preflight
#
# Verifies that every credential needed to provision an environment is present
# AND actually works, BEFORE anything destructive runs (notably the bare-metal
# `provision-hetzner-baremetal.sh ... --wipe`, which reimages the leased server).
#
# This script is strictly READ-ONLY: it only performs GET / verify calls and
# reads local files. It never creates, updates, or deletes any resource — no
# DNS records, no SSH keys, no Tailscale keys, no server boot changes, nothing.
#
# Usage:
#   tools/validate-keys.sh <env-name>
#
# Exit status:
#   0  every check passed
#   1  one or more checks failed (or no env given)
#
# Conventions follow tools/k3s/apply-pomerium-routes.sh: source
# provision-common.sh, resolve envs via provision::envs_root, load the env with
# provision::load_env. We deliberately do NOT `set -e` so that every check runs
# and the operator sees the full picture in one pass.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENV_ROOT=$(provision::envs_root)

# --- Argument parsing / usage (lists available envs like apply-pomerium-routes.sh) ---
if [[ -z "${1:-}" ]]; then
  cat >&2 <<EOF
Usage: $0 <env-name>

Read-only preflight: checks that every provisioning key is present and works
BEFORE any destructive step (e.g. bare-metal --wipe). Makes NO changes.

Available environments:
EOF
  find "$ENV_ROOT" -maxdepth 2 -type f -name env.properties -print 2>/dev/null | \
    sed "s#${ENV_ROOT}/##; s#/env.properties##" | sort || true
  exit 1
fi

if provision::load_env "${1:-}"; then
  shift
else
  provision::error "Environment '$1' not found (${ENV_ROOT}/$1/env.properties missing)."
  exit 1
fi

# --- Result tracking -----------------------------------------------------------
declare -a CHECK_NAMES=()
declare -a CHECK_STATUS=()

check_ok()   { echo "[OK]   $*" >&2; }
check_fail() { echo "[FAIL] $*" >&2; }

record() {
  # record <check-name> <0|1>
  CHECK_NAMES+=("$1")
  CHECK_STATUS+=("$2")
}

SHARED_SECRETS="${ENV_ROOT}/shared/secrets.plain"

echo "== Read-only key validation preflight for env: ${ENV_NAME} ==" >&2
echo "   (no resources are created, updated, or deleted)" >&2
echo >&2

# ==============================================================================
# 1) Hetzner Robot webservice
#    File + read pattern mirror provision-hetzner-baremetal.sh robot::read_credentials
#    and robot::api (https://robot-ws.your-server.de). READ-ONLY: GET /server/<ip>.
# ==============================================================================
check_hetzner_robot() {
  local name="Hetzner Robot"
  local file="${SHARED_SECRETS}/hetzner-webservice-user.txt"

  if [[ ! -f "$file" ]]; then
    check_fail "${name}: credentials file missing: ${file}"
    check_fail "       Decrypt it: sops -d envs/shared/secrets.sops/hetzner-webservice-user.txt > ${file}"
    record "$name" 1; return
  fi

  # Same parsing as robot::read_credentials: "user:password" on one line, or
  # user on line 1 and password on line 2.
  local l1 l2 ruser rpass
  l1=$(sed -n '1p' "$file" | tr -d '\r\n')
  l2=$(sed -n '2p' "$file" | tr -d '\r\n') || true
  if [[ "$l1" == *:* ]]; then
    ruser="${l1%%:*}"; rpass="${l1#*:}"
  else
    ruser="$l1"; rpass="$l2"
  fi
  if [[ -z "${ruser:-}" || -z "${rpass:-}" ]]; then
    check_fail "${name}: invalid credentials format in ${file} (expected 'user:password' or user/password on two lines)"
    record "$name" 1; return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    check_fail "${name}: curl not found (required to reach the Robot API)"
    record "$name" 1; return
  fi

  if [[ -z "${EXTERNAL_IP:-}" ]]; then
    check_fail "${name}: EXTERNAL_IP not set in ${ENV_ROOT}/${ENV_NAME}/env.properties; cannot confirm the leased server"
    record "$name" 1; return
  fi

  # READ-ONLY GET of the specific leased server (robot-ws base URL from baremetal script).
  local http
  http=$(curl -sS -u "${ruser}:${rpass}" -H 'Accept: application/json' \
    -o /dev/null -w '%{http_code}' \
    "https://robot-ws.your-server.de/server/${EXTERNAL_IP}" 2>/dev/null || echo "000")

  case "$http" in
    2*)
      check_ok "${name}: authenticated; leased server ${EXTERNAL_IP} is visible"
      record "$name" 0 ;;
    401|403)
      check_fail "${name}: authentication rejected (HTTP ${http}). Check the webservice user/password in ${file} (Robot > Settings > Webservice/app settings)."
      record "$name" 1 ;;
    404)
      check_fail "${name}: authenticated, but server ${EXTERNAL_IP} is NOT in this Robot account (HTTP 404). Check EXTERNAL_IP for env ${ENV_NAME}."
      record "$name" 1 ;;
    000)
      check_fail "${name}: could not reach robot-ws.your-server.de (network/curl error)."
      record "$name" 1 ;;
    *)
      check_fail "${name}: unexpected Robot API response (HTTP ${http}) for /server/${EXTERNAL_IP}."
      record "$name" 1 ;;
  esac
}

# ==============================================================================
# 2) Cloudflare
#    Reuses provision::cloudflare_read_token + provision::cloudflare_api
#    (provision-common.sh). READ-ONLY: GET /zones?name=<base-domain>.
# ==============================================================================
check_cloudflare() {
  local name="Cloudflare"
  local file="${SHARED_SECRETS}/cloudflare.yaml"

  if ! provision::cloudflare_read_token; then
    if [[ ! -f "$file" ]]; then
      check_fail "${name}: token file missing: ${file}"
      check_fail "       Decrypt it: sops -d envs/shared/secrets.sops/cloudflare.yaml > ${file}"
    else
      check_fail "${name}: could not parse an API token from ${file}"
    fi
    record "$name" 1; return
  fi

  if ! command -v jq >/dev/null 2>&1; then
    check_fail "${name}: jq not found (required to parse the Cloudflare API response)"
    record "$name" 1; return
  fi

  if [[ -z "${HOSTNAME:-}" ]]; then
    check_fail "${name}: HOSTNAME not set in env.properties; cannot determine the zone to verify"
    record "$name" 1; return
  fi

  # Derive the base domain (last two labels) exactly like the provisioning code.
  local base_domain
  base_domain=$(printf '%s' "$HOSTNAME" | awk -F. '{if (NF>=2){print $(NF-1)"."$NF}else{print $0}}')

  local resp success zone_id
  resp=$(provision::cloudflare_api GET "/zones?name=${base_domain}" 2>/dev/null)
  success=$(printf '%s' "$resp" | jq -r '.success // empty' 2>/dev/null)

  if [[ "$success" != "true" ]]; then
    local errmsg
    errmsg=$(printf '%s' "$resp" | jq -r '.errors[0].message // "unknown error"' 2>/dev/null)
    check_fail "${name}: token did not authenticate (${errmsg}). Check the token in ${file} and its Zone:Read permission."
    record "$name" 1; return
  fi

  zone_id=$(printf '%s' "$resp" | jq -r '.result[0].id // empty' 2>/dev/null)
  if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
    check_fail "${name}: authenticated, but the token cannot see zone '${base_domain}' (needed for ${HOSTNAME}). Grant Zone:Read for this zone."
    record "$name" 1; return
  fi

  check_ok "${name}: token valid; zone '${base_domain}' is readable (for ${HOSTNAME})"
  record "$name" 0
}

# ==============================================================================
# 3) GitHub App
#    Reuses provision::github_validate_credentials (mints an installation token
#    and checks org access). READ-ONLY: POST .../access_tokens only mints a
#    short-lived read token; no repo/secret is written.
# ==============================================================================
check_github() {
  local name="GitHub App"
  local app_file="${SHARED_SECRETS}/github-app-credentials.yaml"
  local oauth_file="${ENV_ROOT}/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"

  if [[ ! -f "$app_file" ]]; then
    check_fail "${name}: app credentials file missing: ${app_file}"
    check_fail "       Decrypt it: sops -d envs/shared/secrets.sops/github-app-credentials.yaml > ${app_file}"
    record "$name" 1; return
  fi

  if provision::github_validate_credentials; then
    check_ok "${name}: credentials valid; installation token minted and org access confirmed"
    record "$name" 0
  else
    check_fail "${name}: validation failed. Check appID/installationID/privateKey in ${app_file} and that the App is installed on the org."
    record "$name" 1
  fi

  # OAuth creds are optional for provisioning (only used for Dex/SSO); note if absent.
  if [[ ! -f "$oauth_file" ]]; then
    provision::info "${name}: note — OAuth app creds not present (${oauth_file}); SSO login setup will need them, but provisioning does not."
  fi
}

# ==============================================================================
# 4) Tailscale
#    File + read + validation pattern mirror provision-hetzner-baremetal.sh
#    tailscale::read_api_token / tailscale::validate_api_key. READ-ONLY:
#    GET /tailnet/-/devices.
# ==============================================================================
check_tailscale() {
  local name="Tailscale"
  local file="${SHARED_SECRETS}/tailscale-api-key.txt"

  if [[ ! -f "$file" ]]; then
    check_fail "${name}: auth key file missing: ${file}"
    check_fail "       Decrypt it: sops -d envs/shared/secrets.sops/tailscale-api-key.txt > ${file}"
    record "$name" 1; return
  fi

  local key
  key=$(tr -d '\n\r' < "$file" | xargs)
  if [[ -z "$key" ]]; then
    check_fail "${name}: key file is empty: ${file}"
    record "$name" 1; return
  fi

  # Format check (matches tailscale::validate_api_key): API keys start with tskey-api.
  if [[ ! "$key" =~ ^tskey-api ]]; then
    check_fail "${name}: key does not look like an API key (expected prefix 'tskey-api', got '${key:0:12}...'). A full API validation needs an API key."
    record "$name" 1; return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    check_fail "${name}: curl not found (required for API validation)"
    record "$name" 1; return
  fi

  # READ-ONLY: list devices in the current tailnet ('-' placeholder).
  local http
  http=$(curl -sS -u "${key}:" -H 'Content-Type: application/json' \
    -o /dev/null -w '%{http_code}' \
    "https://api.tailscale.com/api/v2/tailnet/-/devices" 2>/dev/null || echo "000")

  case "$http" in
    2*)
      check_ok "${name}: API key valid; tailnet is accessible (full API validation)"
      record "$name" 0 ;;
    401|403)
      check_fail "${name}: API key rejected (HTTP ${http}). Regenerate an API key in the Tailscale admin console and update ${file}."
      record "$name" 1 ;;
    000)
      check_fail "${name}: could not reach api.tailscale.com (network/curl error)."
      record "$name" 1 ;;
    *)
      check_fail "${name}: unexpected Tailscale API response (HTTP ${http})."
      record "$name" 1 ;;
  esac
}

# ==============================================================================
# 5) Local prerequisites
#    - ~/.ssh/id_ed25519
#    - ~/.config/sops/age/keys.txt (via provision::default_age_key_file)
#    - the .sops.yaml recipient must NOT be the shipped placeholder
# ==============================================================================
check_local() {
  local name="Local (SSH)"
  local ssh_key="${HOME}/.ssh/id_ed25519"
  if [[ -f "$ssh_key" ]]; then
    check_ok "${name}: ${ssh_key} present"
    record "$name" 0
  else
    check_fail "${name}: ${ssh_key} not found. Generate one: ssh-keygen -t ed25519"
    record "$name" 1
  fi

  name="Local (SOPS age key)"
  local age_file
  age_file=$(provision::default_age_key_file)
  if [[ -f "$age_file" ]]; then
    check_ok "${name}: ${age_file} present"
    record "$name" 0
  else
    check_fail "${name}: age key file not found: ${age_file}. Create it or set SOPS_AGE_KEY_FILE."
    record "$name" 1
  fi

  name="Local (.sops.yaml recipient)"
  local placeholder="age1REPLACE_WITH_YOUR_OWN_RECIPIENT"
  # The .sops.yaml governing envs/*/secrets lives at the infra-envs repo root
  # (one level above envs/). Fall back to this repo's root if that is absent.
  local sops_file="${ENV_ROOT}/../.sops.yaml"
  if [[ ! -f "$sops_file" ]]; then
    sops_file="${REPO_ROOT}/.sops.yaml"
  fi
  if [[ ! -f "$sops_file" ]]; then
    check_fail "${name}: .sops.yaml not found (looked in ${ENV_ROOT}/.. and ${REPO_ROOT})"
    record "$name" 1
  elif grep -q "$placeholder" "$sops_file"; then
    check_fail "${name}: ${sops_file} still uses the placeholder recipient '${placeholder}'."
    check_fail "       Replace it with YOUR recipient: age-keygen -y ${age_file}  (see new-env skill, Step 4)"
    record "$name" 1
  else
    check_ok "${name}: ${sops_file} has a real recipient (not the placeholder)"
    record "$name" 0
  fi
}

# --- Run every check (independent; none aborts the others) --------------------
check_hetzner_robot
echo >&2
check_cloudflare
echo >&2
check_github
echo >&2
check_tailscale
echo >&2
check_local

# --- Summary -------------------------------------------------------------------
echo >&2
echo "== Summary ==" >&2
overall=0
for i in "${!CHECK_NAMES[@]}"; do
  if [[ "${CHECK_STATUS[$i]}" == "0" ]]; then
    printf '  PASS  %s\n' "${CHECK_NAMES[$i]}" >&2
  else
    printf '  FAIL  %s\n' "${CHECK_NAMES[$i]}" >&2
    overall=1
  fi
done

echo >&2
if [[ "$overall" -eq 0 ]]; then
  echo "All checks passed. Safe to proceed. (No resources were modified.)" >&2
else
  echo "One or more checks FAILED. Fix the above before running any destructive step (e.g. --wipe)." >&2
fi

exit "$overall"
