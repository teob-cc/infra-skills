#!/usr/bin/env bash
# Hetzner bare-metal provisioning helper
#
# This script automates the steps described in the inline comments of the
# original placeholder. It will:
# 1) Read environment from envs/<env>/env.properties (HOSTNAME, EXTERNAL_IP, VLAN_IP)
# 2) Perform diagnostics (DNS resolution, reachability, SSH connectivity)
# 3) Connect to the host in rescue mode as root and run installimage with an
#    LVM-on-RAID1 layout (nvme0n1 + nvme1n1) and Ubuntu 24.04
# 4) Wait for reboot and then run a follow-up provisioning on the fresh system:
#    - Base packages, user, UFW
#    - Configure VLAN 4000 with the provided VLAN_IP
#    - Kernel/network tuning and k3s installation
#
# Usage:
#   tools/provision-hetzner-baremetal.sh <env-name> [--ssh-key PATH] [--run-installimage] [--run-followup] [--skip-diagnose] [--wipe] [--debug] [--list-robot-keys]
#
# Notes:
# - By default the script will run both installimage and follow-up steps.
# - UFW allows only 443/tcp from the Internet by default; management access (e.g., SSH) is intended via Tailscale when enabled.
# - NIC for VLAN link is auto-detected on the remote as the default route's iface.
# - You can override with REMOTE_IFACE via env.properties if desired.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
source "$REPO_ROOT/tools/provision-common.sh"
ENV_ROOT=$(provision::envs_root)
# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
# Validate local keys before continuing
if ! provision::validate_local_keys; then
  provision::warn "Missing required local keys. Aborting provisioning."
  exit 1
fi
function usage() {
  cat <<USAGE
${BLUE}Hetzner bare-metal provisioning${NC}
Usage: $0 <env-name> [--ssh-key PATH] [--run-installimage] [--run-followup] [--skip-diagnose] [--wipe] [--debug] [--list-robot-keys] [--remove-from-cluster]

Examples:
  $0 cit --ssh-key ~/.ssh/id_ed25519
  $0 cit-worker1 --remove-from-cluster  # Remove worker node from cluster

Options:
  --remove-from-cluster    Gracefully remove a worker node from the Kubernetes cluster
                          (drain, delete node, stop k3s-agent)

Environment file expected at: envs/<env>/env.properties with variables:
  HOSTNAME=example.domain.tld
  EXTERNAL_IP=1.2.3.4
  VLAN_IP=192.168.100.5/24   # CIDR is preferred; /24 default is added if missing
  # Optional: if set, this node will be provisioned as a k3s worker joining an existing master
  # MASTER_VLAN_IP=192.168.100.1
  # MASTER_HOSTNAME=master.example.domain.tld
USAGE
}

if [[ ${1:-} == "" ]]; then
  echo -e "${YELLOW}No env-name provided. Available environments:${NC}"
  find "${ENV_ROOT}" -maxdepth 2 -type f -name env.properties -print | sed "s#${ENV_ROOT}/##; s#/env.properties##" | sort || true
  echo
  usage
  exit 1
fi

ENV_NAME=$1; shift || true
ENV_DIR="${ENV_ROOT}/${ENV_NAME}"
ENV_FILE="${ENV_DIR}/env.properties"

SSH_KEY="${SSH_KEY:-}"
RUN_INSTALLIMAGE=true
RUN_FOLLOWUP=true
SKIP_DIAGNOSE=false
WIPE=false
DEBUG=false
LIST_ROBOT_KEYS=false
REMOVE_FROM_CLUSTER=false

# Default behavior: run everything unless specifically limited
DEFAULT_RUN_ALL=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-key)
      SSH_KEY="$2"; shift 2;;
    --run-installimage)
      RUN_INSTALLIMAGE=true; DEFAULT_RUN_ALL=false; shift;;
    --run-followup)
      RUN_FOLLOWUP=true; DEFAULT_RUN_ALL=false; shift;;
    --skip-diagnose)
      SKIP_DIAGNOSE=false ; shift;;
    --wipe)
      WIPE=true; shift;;
    --debug)
      DEBUG=true; shift;;
    --list-robot-keys)
      LIST_ROBOT_KEYS=true; shift;;
    --remove-from-cluster)
      REMOVE_FROM_CLUSTER=true; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo -e "${RED}Unknown argument: $1${NC}"; usage; exit 1;;
  esac
done

if [[ ! -f "${ENV_FILE}" ]]; then
  echo -e "${RED}Environment file not found: ${ENV_FILE}${NC}"
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

# Allow VLAN_IP without CIDR by defaulting to /24
if [[ "${VLAN_IP:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  VLAN_IP="${VLAN_IP}/24"
fi

REQUIRED=(HOSTNAME EXTERNAL_IP VLAN_IP)
for v in "${REQUIRED[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo -e "${RED}Missing required variable ${v} in ${ENV_FILE}${NC}"; exit 1
  fi
done

# Determine if this node should join an existing master as a worker
WORKER_MODE=false
if [[ -n "${MASTER_VLAN_IP:-}" ]]; then
  WORKER_MODE=true
  if [[ -z "${MASTER_HOSTNAME:-}" ]]; then
    echo -e "${RED}MASTER_VLAN_IP is set but MASTER_HOSTNAME is missing in ${ENV_FILE}${NC}"; exit 1
  fi
fi

SSH_PORT_RESCUE=22
SSH_PORT_FINAL=22

SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=${HOME}/.ssh/known_hosts
  -o ConnectTimeout=10
)
[[ -n "${SSH_KEY}" ]] && SSH_OPTS+=(-i "${SSH_KEY}")


function info(){ echo -e "${BLUE}[INFO]${NC} $*" >&2; }
function ok(){ echo -e "${GREEN}[OK]${NC} $*" >&2; }
function warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
function err(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }
function dbg(){ if $DEBUG; then echo -e "${YELLOW}[DEBUG]${NC} $*" >&2; fi }

# --- Hetzner Robot API helpers and Cloudflare checks (pre-provision) ---

# Read Robot API credentials from secrets file. Supports formats:
#  - single line: user:password
#  - two lines: first line user, second line password
function robot::read_credentials(){
  local file="${ENV_ROOT}/shared/secrets.plain/hetzner-webservice-user.txt"
  if [[ ! -f "$file" ]]; then
    err "Hetzner Robot API credentials file not found: $file"
    return 1
  fi
  local l1 l2
  l1=$(sed -n '1p' "$file" | tr -d '\r\n')
  l2=$(sed -n '2p' "$file" | tr -d '\r\n') || true
  if [[ "$l1" == *:* ]]; then
    ROBOT_USER="${l1%%:*}"
    ROBOT_PASS="${l1#*:}"
  else
    ROBOT_USER="$l1"
    ROBOT_PASS="$l2"
  fi
  if [[ -z "${ROBOT_USER:-}" || -z "${ROBOT_PASS:-}" ]]; then
    err "Invalid Hetzner Robot API credentials format in $file"
    return 1
  fi
}

# Curl wrapper for Robot API
function robot::api(){
  local method="$1" path="$2"; shift 2
  local url="https://robot-ws.your-server.de${path}"
  dbg "ROBOT ${method} ${url} $*"
  local response http body
  # Capture body and HTTP status without --fail so we can log errors too
  response=$(curl -sS -u "${ROBOT_USER}:${ROBOT_PASS}" -X "$method" \
    -H 'Accept: application/json' \
    "$url" "$@" -w "\n%{http_code}")
  http=$(printf "%s" "$response" | tail -n1)
  body=$(printf "%s\n" "$response" | sed '$d')
  # Export last HTTP status/body for callers to inspect on error
  ROBOT_LAST_HTTP="$http"
  ROBOT_LAST_BODY="$body"
  dbg "ROBOT status=${http} body=${body}"
  if [[ "$http" =~ ^2[0-9][0-9]$ ]]; then
    printf "%s" "$body"
    return 0
  else
    # Do not print body to stderr here to keep callers' stderr clean; rely on dbg and globals
    return 22
  fi
}

# Return 0 if rescue is active for EXTERNAL_IP via Robot API, else 1.
function robot::rescue_active(){
  # Try dedicated rescue endpoint first
  local out rc
  set +e
  out=$(robot::api GET "/server/${EXTERNAL_IP}/rescue" 2>/dev/null); rc=$?
  set -e
  if [[ $rc -eq 0 && -n "$out" ]]; then
    # Look for typical JSON field active:true
    echo "$out" | grep -qi '"active"[[:space:]]*:[[:space:]]*true' && return 0 || return 1
  fi
  # Fallback: boot endpoint sometimes shows "rescue" mode
  set +e
  out=$(robot::api GET "/server/${EXTERNAL_IP}/boot" 2>/dev/null); rc=$?
  set -e
  if [[ $rc -eq 0 && -n "$out" ]]; then
    echo "$out" | grep -qi 'rescue' && return 0 || return 1
  fi
  # If API failed, assume not active
  return 1
}

# Get the SSH key fingerprint for the provisioning key (MD5 format for Robot API)
function robot::get_key_fingerprint(){
  local pubfile="$1"
  if [[ ! -f "$pubfile" ]]; then
    err "Public key file not found: $pubfile"; return 1
  fi
  if command -v ssh-keygen >/dev/null 2>&1; then
    # Get MD5 fingerprint without colons (Robot API format)
    ssh-keygen -lf "$pubfile" -E md5 2>/dev/null | awk '{print $2}' | sed 's/MD5://; s/://g'
  else
    err "ssh-keygen not found; cannot compute key fingerprint"
    return 1
  fi
}

# List Robot keys (name and fingerprint if possible)
function robot::list_keys(){
  local out
  out=$(robot::api GET "/key" 2>/dev/null || true)
  if [[ -z "$out" ]]; then
    echo "(no keys or API error)"
    return 0
  fi
  # Ensure it's JSON before piping to jq to avoid parse errors
  if command -v jq >/dev/null 2>&1 && printf '%s' "$out" | grep -q '^[[:space:]]*{'; then
    # Print: name  |  short-fp  |  type
    printf "%s" "$out" | jq -r '.key[]?.key | [.name, .data] | @tsv' 2>/dev/null | while IFS=$'\t' read -r name data; do
      local tmp fp type
      tmp=$(mktemp); printf "%s\n" "$data" > "$tmp"
      if command -v ssh-keygen >/dev/null 2>&1; then
        fp=$(ssh-keygen -lf "$tmp" 2>/dev/null | awk '{print $2}')
        type=$(echo "$data" | awk '{print $1}')
        echo "$name | $fp | $type"
      else
        echo "$name | $(echo "$data" | awk '{print $2}' | cut -c1-16)... | $(echo "$data" | awk '{print $1}')"
      fi
      rm -f "$tmp"
    done
  else
    echo "$out"
  fi
}

# Normalize SSH pubkey string to "type base64" (strip trailing comment)
function key::normalize(){
  awk '{print $1" "$2}' "$1" 2>/dev/null
}

# Check if the provisioning SSH public key exists in Robot API keys
# Compares only the base64 part (second field) to avoid type/comment mismatches
function robot::has_pubkey(){
  local want="$1"
  local out want_b64
  out=$(robot::api GET "/key" 2>/dev/null || true)
  [[ -z "$out" ]] && return 1
  # Extract base64 part only (second field)
  want_b64=$(printf '%s\n' "$want" | awk '{print $2}')
  dbg "Checking Robot keys by base64 part only; want_b64='${want_b64}'"
  
  if command -v jq >/dev/null 2>&1; then
    # JSON form: {"key":[{"key":{"name":"...","data":"ssh-<type> <base64> [comment]"}}, ...]}
    # jq -r unescapes JSON (including \/ -> /)
    # Extract base64 (second field) from each key and compare
    while IFS= read -r key_b64; do
      [[ -z "$key_b64" ]] && continue
      if [[ "$key_b64" == "$want_b64" ]]; then
        dbg "Match found: key_b64='${key_b64}'"
        return 0
      fi
    done < <(printf '%s' "$out" | jq -r '.key[]?.key.data // empty' 2>/dev/null | awk '{print $2}')
  else
    # Fallback parsing without jq: extract base64 from JSON manually
    # Account for JSON escaping of slashes (\/)
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # Unescape JSON slashes
      line=$(printf '%s' "$line" | sed 's/\\//g')
      if [[ "$line" == "$want_b64" ]]; then
        dbg "Match found (no-jq): line='${line}'"
        return 0
      fi
    done < <(printf '%s\n' "$out" | grep -Eo '"data"\s*:\s*"[^"]+' | sed -E 's/.*"data"\s*:\s*"//; s/"$//' | awk '{print $2}')
  fi
  
  # Last resort: raw base64 substring search (unescape slashes first)
  local out_unescaped
  out_unescaped=$(printf '%s' "$out" | sed 's/\\//g')
  if printf '%s\n' "$out_unescaped" | grep -qF "$want_b64"; then
    dbg "Match found via substring search"
    return 0
  fi
  
  return 1
}

# Add a public key to Robot API key store
function robot::add_pubkey(){
  local name="$1" pubfile="$2"
  if [[ ! -f "$pubfile" ]]; then
    err "Public key file not found: $pubfile"; return 1
  fi
  local data
  data=$(cat "$pubfile")
  robot::api POST "/key" --data-urlencode "name=${name}" --data-urlencode "data=${data}"
}

# Set reverse DNS (PTR) record for an IP via Robot API
# Usage: robot::set_rdns <ip> <hostname>
function robot::set_rdns(){
  local ip="$1" ptr="$2"
  info "Setting reverse DNS for ${ip} -> ${ptr}"
  # Check current rDNS first
  local current_out
  if current_out=$(robot::api GET "/rdns/${ip}" 2>/dev/null); then
    local current_ptr
    current_ptr=$(printf '%s' "$current_out" | jq -r '.rdns.ptr // empty' 2>/dev/null || true)
    if [[ "$current_ptr" == "$ptr" ]]; then
      ok "Reverse DNS already set correctly: ${ip} -> ${ptr}"
      return 0
    fi
    if [[ -n "$current_ptr" ]]; then
      info "Current rDNS: ${ip} -> ${current_ptr}, updating to ${ptr}"
    fi
  fi
  # Create or update the PTR record
  if robot::api POST "/rdns/${ip}" --data-urlencode "ptr=${ptr}" >/dev/null; then
    ok "Reverse DNS set: ${ip} -> ${ptr}"
  else
    warn "Failed to set reverse DNS for ${ip} (HTTP ${ROBOT_LAST_HTTP:-?}). This is non-fatal."
    dbg "Response body: ${ROBOT_LAST_BODY:-}"
  fi
}

# Read Tailscale API token from secrets file
function tailscale::read_api_token(){
  local ts_file="${ENV_ROOT}/shared/secrets.plain/tailscale-api-key.txt"
  if [[ ! -f "$ts_file" ]]; then
    return 1
  fi
  dbg "Reading Tailscale API token from: $ts_file"
  TS_API_TOKEN=$(tr -d '\n\r' < "$ts_file" | xargs)
  if [[ -z "${TS_API_TOKEN:-}" ]]; then
    err "Failed to read Tailscale API token from $ts_file"
    return 1
  fi
  [[ -n "${TS_API_TOKEN:-}" ]]
}

# Validate Tailscale API key by checking format and testing API access
function tailscale::validate_api_key(){
  if ! tailscale::read_api_token; then
    err "Tailscale API key file not found: ${ENV_ROOT}/shared/secrets.plain/tailscale-api-key.txt"
    return 1
  fi
  
  info "Validating Tailscale API key..."
  local key_content="$TS_API_TOKEN"
  
  dbg "API key length: ${#key_content}"
  dbg "API key prefix: ${key_content:0:20}..."
  
  if [[ -z "$key_content" ]]; then
    err "Tailscale API key file is empty"
    return 1
  fi
  
  # Check if it's a valid API key (starts with tskey-api)
  if [[ ! "$key_content" =~ ^tskey-api ]]; then
    err "Tailscale API key has invalid format. Expected to start with 'tskey-api', got: ${key_content:0:20}..."
    return 1
  fi
  
  ok "API key format is valid"
  
  # Test API access using /tailnet/-/devices endpoint (- is placeholder for current tailnet)
  info "Testing Tailscale API access..."
  local out rc
  set +e
  out=$(tailscale::api GET "/tailnet/-/devices")
  rc=$?
  set -e
  
  dbg "API call returned: rc=$rc"
  dbg "API call output length: ${#out}"
  
  if [[ $rc -eq 0 ]]; then
    ok "Tailscale API key is valid and API is accessible"
    return 0
  else
    err "Tailscale API key validation failed (rc=$rc)"
    if [[ -n "${TS_LAST_BODY:-}" ]]; then
      dbg "Response body: ${TS_LAST_BODY}"
    fi
    return 1
  fi
}

# Curl wrapper for Tailscale API
function tailscale::api(){
  local method="$1" path="$2"; shift 2
  local url="https://api.tailscale.com/api/v2${path}"
  dbg "TAILSCALE ${method} ${url}"
  dbg "TAILSCALE API token length: ${#TS_API_TOKEN}"
  dbg "TAILSCALE API token prefix: ${TS_API_TOKEN:0:20}..."
  
  local response http body
  local curl_output curl_rc
  
  if $DEBUG; then
    info "TAILSCALE curl command: curl -sS -u '${TS_API_TOKEN:0:20}...:[redacted]' -X ${method} -H 'Content-Type: application/json' ${url} $@"
  fi
  
  response=$(curl -sS -u "${TS_API_TOKEN}:" -X "$method" \
    -H 'Content-Type: application/json' \
    "$url" "$@" -w "\n%{http_code}" 2>&1)
  curl_rc=$?
  
  if [[ $curl_rc -ne 0 ]]; then
    err "TAILSCALE curl failed with exit code $curl_rc"
    err "TAILSCALE curl output: $response"
    TS_LAST_HTTP="000"
    TS_LAST_BODY="curl error: $response"
    return 22
  fi
  
  http=$(printf "%s" "$response" | tail -n1)
  body=$(printf "%s\n" "$response" | sed '$d')
  TS_LAST_HTTP="$http"
  TS_LAST_BODY="$body"
  
  dbg "TAILSCALE status=${http}"
  dbg "TAILSCALE response body length: ${#body}"
  dbg "TAILSCALE response total length: ${#response}"
  
  if [[ ${#body} -lt 500 ]]; then
    dbg "TAILSCALE response body: ${body}"
  else
    dbg "TAILSCALE response body (truncated): ${body:0:500}..."
  fi
  
  if [[ "$http" =~ ^2[0-9][0-9]$ ]]; then
    printf "%s" "$body"
    return 0
  else
    dbg "TAILSCALE API error: HTTP ${http}, body: ${body}"
    return 22
  fi
}

# Get tailnet name from API
function tailscale::get_tailnet(){
  local out
  out=$(tailscale::api GET "/tailnet" 2>/dev/null || true)
  if [[ -n "$out" ]] && command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r '.name // empty' 2>/dev/null | head -1
  else
    # Fallback: extract from token or use default
    echo "tailnet"
  fi
}

# Create an auth key via Tailscale API
# Usage: tailscale::create_authkey <hostname> [ephemeral] [preauthorized] [tags]
function tailscale::create_authkey(){
  local hostname="$1"
  local ephemeral="${2:-true}"
  local preauthorized="${3:-true}"
  local tags="${4:-}"
  
  info "Creating Tailscale auth key for ${hostname}..."
  
  local tailnet
  tailnet=$(tailscale::get_tailnet)
  if [[ -z "$tailnet" || "$tailnet" == "tailnet" ]]; then
    warn "Could not determine tailnet name; using API without tailnet in path"
    tailnet="-"
  fi
  
  # Sanitize description: remove dots and special characters that Tailscale API rejects
  local safe_hostname
  safe_hostname=$(printf '%s' "$hostname" | tr '.' '-' | tr -cd 'A-Za-z0-9-_')
  
  # Build tags array - only include if tags are provided and non-empty
  local tags_json
  if [[ -n "${tags}" ]]; then
    tags_json="[${tags}]"
  else
    tags_json="[]"
  fi
  
  local json_data
  json_data=$(cat <<JSON
{
  "capabilities": {
    "devices": {
      "create": {
        "reusable": false,
        "ephemeral": ${ephemeral},
        "preauthorized": ${preauthorized},
        "tags": ${tags_json}
      }
    }
  },
  "expirySeconds": 3600,
  "description": "Provisioning for ${safe_hostname}"
}
JSON
)
  
  dbg "Creating auth key with JSON: ${json_data}"
  
  local out rc
  set +e
  # Use -d with proper JSON passing for curl
  out=$(curl -sS -u "${TS_API_TOKEN}:" -X POST \
    -H 'Content-Type: application/json' \
    "https://api.tailscale.com/api/v2/tailnet/${tailnet}/keys" \
    -d "${json_data}" -w "\n%{http_code}" 2>&1)
  rc=$?
  set -e
  
  if [[ $rc -ne 0 ]]; then
    err "Tailscale API curl failed with exit code $rc"
    err "Response: $out"
    return 1
  fi
  
  local http body
  http=$(printf "%s" "$out" | tail -n1)
  body=$(printf "%s\n" "$out" | sed '$d')
  
  dbg "Tailscale API HTTP status: $http"
  dbg "Tailscale API response: $body"
  
  if [[ "$http" =~ ^2[0-9][0-9]$ ]] && command -v jq >/dev/null 2>&1; then
    local key
    key=$(printf '%s' "$body" | jq -r '.key // empty' 2>/dev/null)
    if [[ -n "$key" ]]; then
      ok "Created Tailscale auth key"
      echo "$key"
      return 0
    fi
  fi
  
  warn "Failed to create Tailscale auth key via API (HTTP: ${http:-unknown})"
  if $DEBUG; then
    dbg "Response: ${body:-no response}"
  fi
  return 1
}

# Get device ID by hostname
function tailscale::get_device_id(){
  local hostname="$1"
  local tailnet
  tailnet=$(tailscale::get_tailnet)
  if [[ -z "$tailnet" || "$tailnet" == "tailnet" ]]; then
    tailnet="-"
  fi
  
  local out
  out=$(tailscale::api GET "/tailnet/${tailnet}/devices" 2>/dev/null || true)
  if [[ -n "$out" ]] && command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r ".devices[] | select(.hostname == \"${hostname}\") | .id" 2>/dev/null | head -1
  fi
}

# Get Tailscale IP address by hostname
# Returns the first IPv4 address from the device's addresses list
function tailscale::get_device_ip(){
  local hostname="$1"
  local tailnet
  tailnet=$(tailscale::get_tailnet)
  if [[ -z "$tailnet" || "$tailnet" == "tailnet" ]]; then
    tailnet="-"
  fi
  
  local out
  out=$(tailscale::api GET "/tailnet/${tailnet}/devices" 2>/dev/null || true)
  if [[ -n "$out" ]] && command -v jq >/dev/null 2>&1; then
    # Extract first IPv4 address from addresses array (Tailscale IPs start with 100.x.x.x)
    # Simplified jq filter: find device by hostname, get first IPv4 address starting with 100
    printf '%s' "$out" | jq -r ".devices[] | select(.hostname == \"$hostname\") | .addresses[] | select(startswith(\"100.\")) | select(contains(\":\") | not)" 2>/dev/null | head -1
  fi
}

# Delete a Tailscale device by its device ID
function tailscale::delete_device(){
  local device_id="$1"
  info "Deleting Tailscale device ${device_id}..."
  local out rc
  set +e
  out=$(tailscale::api DELETE "/device/${device_id}" 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    ok "Deleted Tailscale device ${device_id}"
    return 0
  else
    warn "Failed to delete Tailscale device ${device_id}: ${out}"
    return 1
  fi
}

# Remove all existing Tailscale devices matching a hostname (cleanup before re-provisioning)
function tailscale::cleanup_stale_devices(){
  local hostname="$1"
  if ! tailscale::read_api_token 2>/dev/null; then
    dbg "Tailscale API token not available; skipping stale device cleanup"
    return 0
  fi
  local tailnet
  tailnet=$(tailscale::get_tailnet)
  if [[ -z "$tailnet" || "$tailnet" == "tailnet" ]]; then
    tailnet="-"
  fi
  local out
  out=$(tailscale::api GET "/tailnet/${tailnet}/devices" 2>/dev/null || true)
  if [[ -z "$out" ]]; then
    return 0
  fi
  local device_ids
  device_ids=$(printf '%s' "$out" | jq -r ".devices[] | select(.hostname == \"${hostname}\") | .id" 2>/dev/null || true)
  if [[ -z "$device_ids" ]]; then
    dbg "No stale Tailscale devices found for hostname ${hostname}"
    return 0
  fi
  info "Cleaning up stale Tailscale devices for ${hostname}..."
  while IFS= read -r did; do
    [[ -n "$did" ]] && tailscale::delete_device "$did" || true
  done <<< "$device_ids"
}

# Configure device settings via API
function tailscale::configure_device(){
  local device_id="$1"
  local advertise_routes="${2:-}"
  
  if [[ -z "$device_id" ]]; then
    warn "No device ID provided; skipping device configuration"
    return 1
  fi
  
  info "Configuring Tailscale device ${device_id}..."
  
  local json_data
  if [[ -n "$advertise_routes" ]]; then
    json_data=$(cat <<JSON
{
  "authorizedSubnetRoutes": [${advertise_routes}]
}
JSON
)
  else
    json_data='{}'
  fi
  
  local out rc
  set +e
  out=$(tailscale::api POST "/device/${device_id}/routes" -d "${json_data}" 2>&1)
  rc=$?
  set -e
  
  if [[ $rc -eq 0 ]]; then
    ok "Configured Tailscale device settings"
    return 0
  else
    warn "Failed to configure device via API (HTTP: ${TS_LAST_HTTP:-unknown})"
    return 1
  fi
}

# Read Cloudflare API token from secrets file
function cloudflare::read_token(){
  local cf_file="${ENV_ROOT}/shared/secrets.plain/cloudflare.yaml"
  if [[ ! -f "$cf_file" ]]; then
    return 1
  fi
  dbg "Reading Cloudflare token from: $cf_file"
  
  # Try multiple parsing strategies for YAML
  # 1. Look for 'cloudflare-api-token: <value>' or similar
  CF_API_TOKEN=$(grep -iE '^[[:space:]]*(cloudflare[-_]?api[-_]?token|api[-_]?token|token|api[-_]?key)[[:space:]]*:[[:space:]]*' "$cf_file" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)
  
  # 2. If not found, try looking for any line with a token-like value (long alphanumeric string)
  if [[ -z "${CF_API_TOKEN:-}" || "${CF_API_TOKEN}" == "cloudflare-api-token" ]]; then
    CF_API_TOKEN=$(grep -oE '[A-Za-z0-9_-]{32,}' "$cf_file" | head -1)
  fi
  
  dbg "Extracted CF_API_TOKEN length: ${#CF_API_TOKEN}"
  
  if [[ -z "${CF_API_TOKEN:-}" || "${CF_API_TOKEN}" == "cloudflare-api-token" ]]; then
    err "Failed to parse Cloudflare API token from $cf_file"
    if $DEBUG; then
      info "File content:"
      cat "$cf_file"
    fi
    return 1
  fi
  
  [[ -n "${CF_API_TOKEN:-}" ]]
}

# Curl wrapper for Cloudflare API
function cloudflare::api(){
  local method="$1" path="$2"; shift 2
  local url="https://api.cloudflare.com/client/v4${path}"
  # Send debug to /dev/tty to avoid capturing it in subshells
  if $DEBUG; then
    echo -e "${YELLOW}[DEBUG]${NC} CLOUDFLARE ${method} ${url}" >&2
  fi
  local response
  response=$(curl -sS -X "$method" "$url" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@")
  if $DEBUG; then
    # Only show first 200 chars of response in debug to avoid duplication issues
    echo -e "${YELLOW}[DEBUG]${NC} CLOUDFLARE response (truncated): $(printf '%s' "$response" | head -c 200)..." >&2
  fi
  printf "%s" "$response"
}

# Create or update a DNS A record in Cloudflare
function cloudflare::create_or_update_dns_record(){
  local zone_id="$1" name="$2" ip="$3"
  
  info "Checking DNS record: ${name} -> ${ip}"
  
  # Check if record exists
  local existing
  existing=$(cloudflare::api GET "/zones/${zone_id}/dns_records?type=A&name=${name}" 2>/dev/null)
  local record_id
  record_id=$(printf '%s' "$existing" | jq -r '.result[0].id // empty' 2>/dev/null)
  
  if [[ -n "$record_id" && "$record_id" != "null" ]]; then
    # Record exists, check if IP matches
    local current_ip
    current_ip=$(printf '%s' "$existing" | jq -r '.result[0].content // empty' 2>/dev/null)
    if [[ "$current_ip" == "$ip" ]]; then
      ok "DNS record already correct: ${name} -> ${ip}"
      return 0
    else
      info "Updating DNS record: ${name} from ${current_ip} to ${ip}"
      local update_response
      update_response=$(cloudflare::api PUT "/zones/${zone_id}/dns_records/${record_id}" \
        -d "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}" 2>/dev/null)
      if printf '%s' "$update_response" | jq -e '.success == true' >/dev/null 2>&1; then
        ok "Updated DNS record: ${name} -> ${ip}"
        return 0
      else
        err "Failed to update DNS record: ${name}"
        if $DEBUG; then
          echo -e "${YELLOW}[DEBUG]${NC} Update response: $update_response" >&2
        fi
        return 1
      fi
    fi
  else
    # Record doesn't exist, create it
    info "Creating DNS record: ${name} -> ${ip}"
    local create_response
    create_response=$(cloudflare::api POST "/zones/${zone_id}/dns_records" \
      -d "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}" 2>/dev/null)
    if printf '%s' "$create_response" | jq -e '.success == true' >/dev/null 2>&1; then
      ok "Created DNS record: ${name} -> ${ip}"
      return 0
    else
      err "Failed to create DNS record: ${name}"
      if $DEBUG; then
        echo -e "${YELLOW}[DEBUG]${NC} Create response: $create_response" >&2
      fi
      return 1
    fi
  fi
}

# Validate Cloudflare DNS via API: check zone exists and A records for HOSTNAME and *.HOSTNAME -> EXTERNAL_IP
function dns::validate_cloudflare(){
  # Read Cloudflare API token
  if ! cloudflare::read_token; then
    warn "Cloudflare API token not found (skipping DNS validation)"
    return 0
  fi
  dbg "Cloudflare API token loaded"
  
  # Derive top-level domain (last two labels: domain.tld)
  local base_domain
  base_domain=$(printf '%s' "$HOSTNAME" | awk -F. '{if (NF>=2){print $(NF-1)"."$NF}else{print $0}}')
  dbg "Checking for base domain: $base_domain via Cloudflare API"
  
  # List zones and find the one matching base_domain
  local zones_response zone_id
  zones_response=$(cloudflare::api GET "/zones?name=${base_domain}" 2>/dev/null)
  
  if ! command -v jq >/dev/null 2>&1; then
    err "jq is required for Cloudflare DNS validation. Install jq and retry."
    return 1
  fi
  
  # Extract zone_id with better error handling
  local jq_error
  zone_id=$(printf '%s' "$zones_response" | jq -r '.result[0].id // empty' 2>&1)
  jq_error=$?
  
  if [[ $jq_error -ne 0 ]]; then
    err "Failed to parse Cloudflare API response with jq"
    if $DEBUG; then
      info "Raw zones_response:"
      printf '%s\n' "$zones_response"
      echo ""
    fi
    return 1
  fi
  
  dbg "Extracted zone_id: '${zone_id}'"
  
  if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
    err "Cloudflare zone not found for domain: $base_domain"
    local available_zones
    available_zones=$(printf '%s' "$zones_response" | jq -r '.result[].name // empty' 2>/dev/null | tr '\n' ' ')
    if [[ -n "$available_zones" ]]; then
      dbg "Available zones: $available_zones"
    else
      dbg "No zones found in API response"
      if $DEBUG; then
        info "Raw API response:"
        printf '%s\n' "$zones_response" | head -20
      fi
    fi
    err "Configure the zone in Cloudflare or check your API token permissions."
    return 1
  fi
  ok "Found Cloudflare zone for ${base_domain}"
  dbg "zone_id=${zone_id}"
  
  # Create or update DNS records
  info "Ensuring DNS records are configured..."
  
  # 1. Create/update A record for HOSTNAME -> EXTERNAL_IP
  if ! cloudflare::create_or_update_dns_record "$zone_id" "$HOSTNAME" "$EXTERNAL_IP"; then
    err "Failed to configure DNS record for ${HOSTNAME}"
    return 1
  fi
  
  # 2. Create/update wildcard A record for *.HOSTNAME -> EXTERNAL_IP
  local wildcard="*.${HOSTNAME}"
  if ! cloudflare::create_or_update_dns_record "$zone_id" "$wildcard" "$EXTERNAL_IP"; then
    err "Failed to configure wildcard DNS record for ${wildcard}"
    return 1
  fi
  
  ok "DNS records configured in Cloudflare"
  
  # Check if host is already resolvable to the correct IP
  info "Checking if ${HOSTNAME} is already resolvable..."
  local resolved_ip
  if command -v dig >/dev/null 2>&1; then
    resolved_ip=$(dig +short "${HOSTNAME}" A | head -1)
  elif command -v host >/dev/null 2>&1; then
    resolved_ip=$(host "${HOSTNAME}" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
  elif command -v nslookup >/dev/null 2>&1; then
    resolved_ip=$(nslookup "${HOSTNAME}" | grep -A1 'Name:' | grep 'Address:' | awk '{print $2}' | head -1)
  else
    warn "No DNS tools (dig/host/nslookup) available; skipping DNS resolution check"
    resolved_ip=""
  fi
  
  if [[ -z "$resolved_ip" ]]; then
    warn "DNS does not resolve yet for ${HOSTNAME}, waiting 5 seconds for propagation..."
    sleep 5
    # Re-check after wait
    if command -v dig >/dev/null 2>&1; then
      resolved_ip=$(dig +short "${HOSTNAME}" A | head -1)
    fi
  fi
  
  if [[ -z "$resolved_ip" ]]; then
    warn "DNS still does not resolve for ${HOSTNAME} (may need more time to propagate)"
    info "Continuing anyway as records are configured in Cloudflare..."
  elif [[ "$resolved_ip" != "$EXTERNAL_IP" ]]; then
    warn "DNS resolves to ${resolved_ip} (expected: ${EXTERNAL_IP}). May need time to propagate."
    info "Continuing anyway as records are configured in Cloudflare..."
  else
    ok "DNS resolves correctly: ${HOSTNAME} -> ${EXTERNAL_IP}"
  fi
  
  ok "Cloudflare DNS validation complete"
  return 0
}

# Remove stale SSH known_hosts entries for the target before any SSH attempt
function cleanup_known_hosts(){
  local kh="${HOME}/.ssh/known_hosts"
  mkdir -p "${HOME}/.ssh" 2>/dev/null || true
  if [[ -f "$kh" ]]; then
    info "Cleaning known_hosts for ${HOSTNAME} and ${EXTERNAL_IP}"
    for host in "${HOSTNAME}" "${EXTERNAL_IP}"; do
      [[ -n "$host" ]] || continue
      ssh-keygen -R "$host" >/dev/null 2>&1 || true
      ssh-keygen -R "[$host]:22" >/dev/null 2>&1 || true
    done
    # Fallback: strip any remaining lines containing host/IP (covers non-standard formats)
    local tmpfile
    tmpfile=$(mktemp)
    grep -v -e "${EXTERNAL_IP}" -e "${HOSTNAME}" "$kh" > "$tmpfile" 2>/dev/null || true
    mv "$tmpfile" "$kh" 2>/dev/null || true
  fi
}

# Perform cleanup now to avoid REMOTE HOST IDENTIFICATION HAS CHANGED errors
cleanup_known_hosts

# Pre-provision checks: Robot API credentials, SSH key presence in Robot, server state vs rescue, Cloudflare DNS
info "Running pre-provision checks (Robot API, SSH key, rescue state, DNS) ..."

# 1) Load Robot API credentials
if ! robot::read_credentials; then
  err "Cannot read Hetzner Robot API credentials. Aborting."
  exit 1
fi

if $LIST_ROBOT_KEYS; then
  info "Listing Hetzner Robot API keys:"
  robot::list_keys
  exit 0
fi

# Handle --remove-from-cluster option
if $REMOVE_FROM_CLUSTER; then
  info "=== Removing worker node from Kubernetes cluster ==="
  
  # Validate this is a worker node
  if [[ "$WORKER_MODE" != "true" ]]; then
    err "Node ${HOSTNAME} is not configured as a worker node (MASTER_VLAN_IP not set in env.properties)"
    err "Only worker nodes can be removed from the cluster using this option."
    exit 1
  fi
  
  if [[ -z "${MASTER_VLAN_IP:-}" || -z "${MASTER_HOSTNAME:-}" ]]; then
    err "MASTER_VLAN_IP and MASTER_HOSTNAME must be set in ${ENV_FILE} to remove a worker node"
    exit 1
  fi
  
  # Detect Tailscale IP for the worker node
  TAILSCALE_IP=""
  if detect_tailscale_ip "${HOSTNAME}"; then
    info "Worker node Tailscale IP: ${TAILSCALE_IP}"
    WORKER_SSH_HOST="${TAILSCALE_IP}"
  else
    info "Tailscale IP not found, using EXTERNAL_IP: ${EXTERNAL_IP}"
    WORKER_SSH_HOST="${EXTERNAL_IP}"
  fi
  
  # Extract node name from HOSTNAME (first component before first dot)
  NODE_NAME="${HOSTNAME%%.*}"
  
  info "Worker node details:"
  info "  Hostname: ${HOSTNAME}"
  info "  Node name: ${NODE_NAME}"
  info "  SSH host: ${WORKER_SSH_HOST}"
  info "  Master: ${MASTER_HOSTNAME} (${MASTER_VLAN_IP})"
  echo ""
  
  # Step 1: Drain the node
  info "Step 1/4: Draining node ${NODE_NAME} (evicting all pods)..."
  if kubectl drain "${NODE_NAME}" --ignore-daemonsets --delete-emptydir-data --timeout=300s; then
    ok "Node ${NODE_NAME} drained successfully"
  else
    warn "Failed to drain node ${NODE_NAME}. Continuing anyway..."
  fi
  
  # Step 2: Delete the node from the cluster
  info "Step 2/4: Deleting node ${NODE_NAME} from cluster..."
  if kubectl delete node "${NODE_NAME}"; then
    ok "Node ${NODE_NAME} deleted from cluster"
  else
    warn "Failed to delete node ${NODE_NAME} from cluster. It may have already been removed."
  fi
  
  # Step 3: Stop k3s-agent on the worker node
  info "Step 3/4: Stopping k3s-agent service on ${HOSTNAME}..."
  if ssh -p 22 "${SSH_OPTS[@]}" admin@"${WORKER_SSH_HOST}" "sudo systemctl stop k3s-agent && sudo systemctl disable k3s-agent" 2>/dev/null; then
    ok "k3s-agent stopped and disabled on ${HOSTNAME}"
  else
    warn "Failed to stop k3s-agent on ${HOSTNAME}. Node may be unreachable."
  fi
  
  # Step 4: Optionally uninstall k3s-agent
  info "Step 4/4: Uninstalling k3s-agent from ${HOSTNAME}..."
  if ssh -p 22 "${SSH_OPTS[@]}" admin@"${WORKER_SSH_HOST}" "sudo /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || sudo /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true" 2>/dev/null; then
    ok "k3s-agent uninstalled from ${HOSTNAME}"
  else
    warn "Failed to uninstall k3s-agent from ${HOSTNAME}. You may need to do this manually."
  fi
  
  echo ""
  ok "=== Worker node ${NODE_NAME} successfully removed from cluster ==="
  info ""
  info "Summary:"
  info "  ✓ Node drained (pods evicted)"
  info "  ✓ Node deleted from Kubernetes cluster"
  info "  ✓ k3s-agent service stopped and disabled"
  info "  ✓ k3s-agent uninstalled from ${HOSTNAME}"
  info ""
  info "The node ${HOSTNAME} is now disconnected from the cluster."
  info "You can re-provision it later using: tools/provision-hetzner-baremetal.sh ${ENV_NAME}"
  exit 0
fi

# 2) Ensure the SSH public key to be used is registered in Robot API keys
PROV_SSH_PUB=""
if [[ -n "${SSH_KEY}" ]]; then
  [[ -f "${SSH_KEY}.pub" ]] && PROV_SSH_PUB="${SSH_KEY}.pub" || true
fi
if [[ -z "${PROV_SSH_PUB}" ]]; then
  if base=$(provision::default_ssh_key_base); then
    PROV_SSH_PUB="${base}.pub"
  fi
fi
if [[ -z "${PROV_SSH_PUB}" || ! -f "${PROV_SSH_PUB}" ]]; then
  err "Provisioning SSH public key not found. Provide --ssh-key or ensure default key exists."
  exit 1
fi
want_key=$(key::normalize "${PROV_SSH_PUB}")
if ! robot::has_pubkey "$want_key"; then
  warn "Provisioning SSH key not found in Hetzner Robot API keys. Attempting to add it automatically ..."
  fp=$(provision::ssh_pub_fingerprint "${PROV_SSH_PUB}" | awk '{print $2}' | tr -d '()')
  # Build a safe key name (Robot rejects some chars). Allow [A-Za-z0-9._-]
  key_name_raw="infra-provision-${ENV_NAME}-${fp}"
  key_name=$(printf "%s" "$key_name_raw" | tr -c 'A-Za-z0-9._-' '-')
  set +e
  add_out=$(robot::add_pubkey "$key_name" "${PROV_SSH_PUB}"); add_rc=$?
  # If conflict, treat as success and continue
  if [[ $add_rc -ne 0 && "${ROBOT_LAST_HTTP:-}" == "409" ]] && printf '%s' "${ROBOT_LAST_BODY:-}" | grep -q 'KEY_ALREADY_EXISTS'; then
    dbg "Robot reported KEY_ALREADY_EXISTS for name=${key_name}; proceeding."
    add_rc=0
  fi
  set -e
  if [[ $add_rc -ne 0 ]]; then
    warn "Initial add failed (name=${key_name}). Retrying with simpler name..."
    # Retry with a simpler safe name without fingerprint noise
    key_name_simple=$(printf "infra-provision-%s" "$ENV_NAME" | tr -c 'A-Za-z0-9._-' '-')
    set +e
    add_out=$(robot::add_pubkey "$key_name_simple" "${PROV_SSH_PUB}"); add_rc=$?
    if [[ $add_rc -ne 0 && "${ROBOT_LAST_HTTP:-}" == "409" ]] && printf '%s' "${ROBOT_LAST_BODY:-}" | grep -q 'KEY_ALREADY_EXISTS'; then
      dbg "Robot reported KEY_ALREADY_EXISTS for name=${key_name_simple}; proceeding."
      add_rc=0
    fi
    set -e
    if [[ $add_rc -ne 0 ]]; then
      err "Failed to add SSH key to Robot API. Please add it manually in Robot (Keys) and retry."
      provision::warn "Wanted key: $(provision::ssh_pub_fingerprint "${PROV_SSH_PUB}")"
      info "Existing Robot keys:"
      robot::list_keys || true
      exit 1
    fi
  fi
  if robot::has_pubkey "$want_key"; then
    ok "Added provisioning SSH key to Robot API (name: ${key_name:-$key_name_simple})."
  else
    err "SSH key still not visible in Robot API after add. Please verify in the Robot UI."
    info "Existing Robot keys:"
    robot::list_keys || true
    exit 1
  fi
else
  ok "Provisioning SSH key is present in Robot API keys."
fi

# 3) If server is up (SSH reachable, even if root auth fails), require rescue mode unless --wipe
# Note: test_root_ssh is defined later in the file; skip this check for now in prechecks
# The main provisioning logic will handle server state detection
info "Skipping SSH reachability check in prechecks (will be done in main provisioning phase)."

# 4) Validate Cloudflare DNS configuration for HOSTNAME and wildcard -> EXTERNAL_IP
# Skip DNS validation for worker nodes (they don't run ingress)
if $WORKER_MODE; then
  info "Worker mode detected; skipping DNS validation (no ingress on worker nodes)"
else
  if ! dns::validate_cloudflare; then
    err "Cloudflare DNS validation failed. Fix DNS config and retry."
    exit 1
  fi
fi

# 4b) Set reverse DNS (PTR) record via Hetzner Robot API
robot::set_rdns "${EXTERNAL_IP}" "${HOSTNAME}"

# 5) Validate Tailscale API key before provisioning (used to generate auth keys)
if ! tailscale::validate_api_key; then
  err "Tailscale API key validation failed."
  err "Please ensure the key in envs/shared/secrets.plain/tailscale-api-key.txt is valid."
  err "API keys must start with 'tskey-api' and be non-empty."
  err "You can decrypt the SOPS file with: tools/sops/decrypt.sh envs/shared/secrets.sops/tailscale-api-key.txt"
  exit 1
fi

ok "Pre-provision checks passed."

# Emit the unified post-install script template.
# This script is safe to run inside the installimage chroot (pre-first-boot)
# and also directly on an already installed OS. It avoids restarting services
# and applies settings that will take effect on next boot; when run on a live
# system, the caller will reboot right after executing it.
function gen_postinstall(){
  cat <<'POSTINSTALL_EOF'
set -euo pipefail
export TERM=${TERM:-dumb}
export DEBIAN_FRONTEND=noninteractive
export LANG=${LANG:-en_US.UTF-8}
export LC_ALL=${LC_ALL:-en_US.UTF-8}
export LC_CTYPE=${LC_CTYPE:-en_US.UTF-8}

MARKER_DIR="/etc/infra-postinstall.d"
MARKER_COMPLETE="/etc/infra-postinstall.done"
mkdir -p "$MARKER_DIR"

# Function to mark step completion
mark_step() {
  local step_name="$1"
  touch "$MARKER_DIR/$step_name" || true
  echo "[postinstall] ✓ Marked step complete: $step_name"
}

# Function to check if step is complete
is_step_done() {
  local step_name="$1"
  [[ -f "$MARKER_DIR/$step_name" ]]
}

# Function to skip already completed steps
skip_if_done() {
  local step_name="$1"
  local step_desc="$2"
  if is_step_done "$step_name"; then
    echo "[postinstall] ⊘ Skipping (already done): $step_desc"
    return 0
  fi
  return 1
}

if [[ -f "$MARKER_COMPLETE" ]]; then
  echo "[INFO] Postinstall already applied; exiting."
  exit 0
fi

echo "[postinstall] Starting postinstall provisioning..."
echo "[postinstall] Step markers stored in: $MARKER_DIR"

# Step 1: Tailscale APT repository
if skip_if_done "01-tailscale-repo" "Tailscale APT repository"; then
  :
else
  echo "[postinstall] Adding Tailscale APT repository ..."
  curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list
  echo "[postinstall] Tailscale APT repository configured"
  mark_step "01-tailscale-repo"
fi

# Step 2: Update apt and install packages
if skip_if_done "02-apt-update-packages" "APT update and package installation"; then
  :
else
  echo "[postinstall] Updating apt cache (single call) ..."
  apt update &&  apt -y dist-upgrade && apt -y autoremove
  
  echo "[postinstall] Installing base packages (kernel, locales, tools) ..."
  apt install -y --install-recommends linux-generic-hwe-24.04 \
    locales ufw git vlan binutils make \
    libcurl4-openssl-dev libsqlite3-dev curl \
    apt-transport-https gnupg2 sudo kubetail tailscale
  mark_step "02-apt-update-packages"
fi

# Step 2a: Prevent needrestart from auto-restarting k3s on package upgrades.
# A k3s restart unmounts /var/lib/rancher/k3s/storage bind mounts and pod
# volume mounts, leaving services (Harbor, Nexus, Loki, Grafana) with stale
# mounts. Restart k3s manually during a maintenance window instead.
if skip_if_done "02a-needrestart-override-k3s" "needrestart override for k3s"; then
  :
else
  mkdir -p /etc/needrestart/conf.d
  cat > /etc/needrestart/conf.d/k3s.conf <<'NEEDRESTART_EOF'
# Managed by provision-hetzner-baremetal.sh
$nrconf{override_rc}{qr(^k3s$)} = 0;
$nrconf{override_rc}{qr(^k3s-agent$)} = 0;
NEEDRESTART_EOF
  mark_step "02a-needrestart-override-k3s"
fi

# Step 3: Configure locales
if skip_if_done "03-configure-locales" "Locale configuration"; then
  :
else
  echo "[postinstall] Configuring locales ..."
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
  sed -i 's/^# *C.UTF-8/C.UTF-8/' /etc/locale.gen || true
  locale-gen en_US.UTF-8 C.UTF-8
  update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LC_CTYPE=en_US.UTF-8
  printf '%s\n' 'LANG="en_US.UTF-8"' 'LC_ALL="en_US.UTF-8"' 'LC_CTYPE="en_US.UTF-8"' > /etc/default/locale
  mark_step "03-configure-locales"
fi

# Step 4: Create admin user with sudo
if skip_if_done "04-admin-user" "Admin user creation"; then
  :
else
  echo "[postinstall] Ensuring 'admin' user exists and has passwordless sudo ..."
  if ! id admin >/dev/null 2>&1; then
    useradd admin -g sudo -s /bin/bash || true
    echo "[postinstall] Created user 'admin'"
  else
    echo "[postinstall] User 'admin' already exists"
  fi
  mkdir -p ~admin/.ssh
  if [[ -d ~/.ssh ]]; then cp -r ~/.ssh/authorized_keys ~admin/.ssh/ 2>/dev/null || true; fi
  chown -R admin:"$(id -gn admin 2>/dev/null || echo sudo)" ~admin 2>/dev/null || true
  sed -i 's/) ALL/) NOPASSWD: ALL/' /etc/sudoers
  echo "[postinstall] 'admin' user configured with SSH and sudo"
  mark_step "04-admin-user"
fi

# Step 5: Configure UFW rules
if skip_if_done "05-ufw-rules" "UFW rules configuration"; then
  :
else
  echo "[postinstall] Preparing UFW rules (not enabled yet) ..."
  # UFW base rules: default deny incoming
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true
  
  # External access policy:
  # - Only HTTPS (443/tcp) from the Internet
  # - Explicitly deny HTTP (80/tcp) from the Internet
  # - Minecraft server (25565/tcp) from the Internet
  # - SSH allowed via Tailscale interface and VLAN
  ufw allow 443/tcp comment 'https' >/dev/null 2>&1 || true
  ufw deny 80/tcp comment 'deny http' >/dev/null 2>&1 || true
  ufw allow 25565/tcp comment 'minecraft' >/dev/null 2>&1 || true
  ufw allow 80/udp comment 'wireguard-wg0' >/dev/null 2>&1 || true
  ufw allow 81/udp comment 'wireguard-wg1' >/dev/null 2>&1 || true

  # Allow SSH via Tailscale and VLAN
  ufw allow in on tailscale0 to any port 22 proto tcp comment 'ssh via tailscale' >/dev/null 2>&1 || true
  [[ -n "${VLAN_IP:-}" ]] && ufw allow in on vlan4000 to any port 22 proto tcp comment 'ssh via vlan' >/dev/null 2>&1 || true
  
  # Allow all traffic on Tailscale interface
  ufw allow in on tailscale0 comment 'allow all via tailscale' >/dev/null 2>&1 || true
  
  # UFW rules for k3s internal networks
  ufw allow from 10.42.0.0/16 to any comment 'k3s pods' >/dev/null 2>&1 || true
  ufw allow from 10.43.0.0/16 to any comment 'k3s services' >/dev/null 2>&1 || true
  
  # k3s/Flannel specifics (do not expose VXLAN to Internet)
  # 8472/udp is NOT opened to the Internet; rely on interface scoping below
  ufw allow in on cni0 comment 'k3s cni0' >/dev/null 2>&1 || true
  ufw allow in on flannel.1 comment 'flannel overlay' >/dev/null 2>&1 || true
  ufw allow from 10.42.0.0/16 to any port 10250 proto tcp comment 'kubelet' >/dev/null 2>&1 || true
  
  # Allow Kubernetes API on VLAN only (safe on all nodes; only master listens)
  ufw allow in on vlan4000 to any port 6443 proto tcp comment 'k8s api on vlan' >/dev/null 2>&1 || true
  
  # Enable forwarding for Kubernetes networking
  if grep -q '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw 2>/dev/null; then
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
  else
    echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> /etc/default/ufw
  fi
  
  # Show UFW status (rules configured but not enabled yet)
  echo "[postinstall] UFW rules configured (not enabled yet):"
  ufw status verbose || true
  mark_step "05-ufw-rules"
fi

# Step 6: Configure VLAN 8021q module
if skip_if_done "06-vlan-8021q" "VLAN 8021q module configuration"; then
  :
else
  echo "[postinstall] Ensuring 8021q module loads on boot ..."
  if ! grep -q '^8021q$' /etc/modules 2>/dev/null; then echo 8021q >> /etc/modules; fi
  mkdir -p /etc/modules-load.d && echo 8021q > /etc/modules-load.d/8021q.conf
  echo "[postinstall] 8021q module configured for autoload"
  # Load 8021q now so VLAN can be brought up immediately (best-effort)
  modprobe 8021q >/dev/null 2>&1 || true
  echo "[postinstall] 8021q kernel module loaded (if supported)"
  mark_step "06-vlan-8021q"
fi

# Step 7: Configure VLAN 4000 networking
if skip_if_done "07-vlan-4000" "VLAN 4000 configuration"; then
  :
else
  echo "[postinstall] Detecting primary interface from default route ..."
  REMOTE_IFACE=$(ip route | awk '/default/ {print $5; exit}')
  echo "[postinstall] Detected primary interface: ${REMOTE_IFACE}"
  
  echo "[postinstall] Writing netplan for VLAN 4000 to /etc/netplan/60-vlan4000.yaml ..."
  mkdir -p /etc/netplan
  cat >/etc/netplan/60-vlan4000.yaml <<YAML_EOF
network:
  version: 2
  vlans:
    vlan4000:
      id: 4000
      link: ${REMOTE_IFACE}
      dhcp4: no
      addresses: [@VLAN_IP@]
      mtu: 1400
YAML_EOF
  echo "[postinstall] Netplan VLAN configuration written. It will be applied on next boot."
  # Attempt to apply VLAN now by restarting networkd or applying netplan (best-effort)
  if command -v netplan >/dev/null 2>&1; then
    echo "[postinstall] Applying netplan configuration to bring up vlan4000 now ..."
    netplan generate >/dev/null 2>&1 || true
    netplan apply >/dev/null 2>&1 || true
  elif command -v systemctl >/dev/null 2>&1 && [[ "$(cat /proc/1/comm 2>/dev/null || true)" == "systemd" ]]; then
    echo "[postinstall] Restarting systemd-networkd to apply VLAN configuration ..."
    systemctl restart systemd-networkd || true
  else
    if command -v networkctl >/dev/null 2>&1; then
      echo "[postinstall] Reloading networkd via networkctl (non-systemd context) ..."
      networkctl reload || true
    fi
  fi
  # Show brief network status after attempting to apply VLAN
  (ip -brief addr || ip addr) 2>/dev/null | sed 's/^/[postinstall]   /' || true
  mark_step "07-vlan-4000"
fi

# Step 8: Disable swap
if skip_if_done "08-disable-swap" "Disable swap"; then
  :
else
  echo "[postinstall] Disabling swap (removing from /etc/fstab) ..."
  sed -i '/\sswap\s/d' /etc/fstab || true
  echo "[postinstall] Swap entries removed from /etc/fstab"
  mark_step "08-disable-swap"
fi

# Step 9: Network tuning
if skip_if_done "09-network-tuning" "Network tuning (fq qdisc and BBR)"; then
  :
else
  echo "[postinstall] Applying network tuning (fq qdisc and bbr congestion control) ..."
  if ! grep -q 'net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null; then echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf; fi
  if ! grep -q 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null; then echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf; fi
  echo "[postinstall] Network tuning lines ensured in /etc/sysctl.conf (will apply after reboot)"
  mark_step "09-network-tuning"
fi

# Step 9a: Increase inotify limits for Kubernetes workloads
if skip_if_done "09a-inotify-limits" "inotify limits configuration"; then
  :
else
  echo "[postinstall] Increasing inotify limits for Kubernetes workloads ..."
  # Increase inotify limits to prevent "too many open files" errors in containerized workloads
  # Default values are often too low for Kubernetes nodes with many pods
  if ! grep -q 'fs.inotify.max_user_instances' /etc/sysctl.conf 2>/dev/null; then 
    echo 'fs.inotify.max_user_instances=8192' >> /etc/sysctl.conf
  fi
  if ! grep -q 'fs.inotify.max_user_watches' /etc/sysctl.conf 2>/dev/null; then 
    echo 'fs.inotify.max_user_watches=524288' >> /etc/sysctl.conf
  fi
  if ! grep -q 'fs.inotify.max_queued_events' /etc/sysctl.conf 2>/dev/null; then 
    echo 'fs.inotify.max_queued_events=32768' >> /etc/sysctl.conf
  fi
  echo "[postinstall] inotify limits configured in /etc/sysctl.conf (will apply after reboot)"
  mark_step "09a-inotify-limits"
fi

# Step 10: Enable and configure Tailscale
if skip_if_done "10-tailscale-enable" "Tailscale service enablement"; then
  :
else
  echo "[postinstall] Enabling and configuring Tailscale ..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now tailscaled 2>/dev/null || systemctl enable tailscaled || true
  fi
  mark_step "10-tailscale-enable"
fi

# Step 11: Bring up Tailscale with auth key
if skip_if_done "11-tailscale-up" "Tailscale authentication"; then
  :
else
  echo "[postinstall] Bringing up Tailscale with provided auth key..."
  TS_CONFIGURED=false
  if ! tailscale status --peers=false >/dev/null 2>&1; then
    TS_AUTHKEY="@TAILSCALE_AUTHKEY@"
    
    if [[ -n "$TS_AUTHKEY" ]]; then
      if tailscale up --authkey "$TS_AUTHKEY" --ssh --hostname "@PUBLIC_HOSTNAME@" --accept-routes; then
        echo "[postinstall] Tailscale brought up successfully."
        TS_CONFIGURED=true
      else
        echo "[postinstall] WARNING: Tailscale up command failed. Error code: $?"
        echo "[postinstall] This may indicate an invalid or expired auth key."
      fi
    else
      echo "[postinstall] No Tailscale auth key provided; skipping automatic login."
      echo "[postinstall] Run 'tailscale up' manually to complete Tailscale setup."
    fi
  else
    echo "[postinstall] Tailscale is already logged in."
    TS_CONFIGURED=true
  fi
  mark_step "11-tailscale-up"
fi

# Step 12: Validate Tailscale and get IP for k3s config
if skip_if_done "12-tailscale-validate" "Tailscale validation and IP detection"; then
  :
else
  echo "[postinstall] Validating Tailscale connectivity..."
  TS_CONFIGURED=false
  TS_IP=""
  # Check if Tailscale is configured
  if tailscale status --peers=false >/dev/null 2>&1; then
    TS_CONFIGURED=true
  fi
  
  if [[ "$TS_CONFIGURED" == "true" ]]; then
    # Wait up to 60 seconds for Tailscale interface to be ready
    TS_INTERFACE_UP=false
    for i in {1..60}; do
      if ip link show tailscale0 >/dev/null 2>&1; then
        echo "[postinstall] Tailscale interface (tailscale0) is up."
        TS_INTERFACE_UP=true
        break
      fi
      sleep 1
    done
    
    if [[ "$TS_INTERFACE_UP" == "true" ]]; then
      # Get Tailscale IP for use in k3s config
      TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
      if [[ -n "$TS_IP" ]]; then
        echo "[postinstall] Tailscale IP: $TS_IP"
        echo "[postinstall] Tailscale is configured and validated."
      else
        echo "[postinstall] WARNING: Could not get Tailscale IP. Tailscale may not be fully configured."
      fi
    else
      echo "[postinstall] WARNING: Tailscale interface did not come up after 60 seconds."
    fi
  else
    echo "[postinstall] WARNING: Tailscale is not configured."
  fi
  mark_step "12-tailscale-validate"
fi

# Step 12b: Update k3s config with actual Tailscale IP
if skip_if_done "12b-k3s-update-tailscale-ip" "k3s config update with Tailscale IP"; then
  :
else
  echo "[postinstall] Updating k3s config with actual Tailscale IP..."
  if [[ -n "$TS_IP" ]]; then
    # Update k3s config to include the actual Tailscale IP
    if [[ -f /etc/rancher/k3s/config.yaml ]]; then
      # Replace empty @TAILSCALE_IP@ with actual IP, or add it if missing
      if grep -q '@TAILSCALE_IP@' /etc/rancher/k3s/config.yaml; then
        sed -i "s/@TAILSCALE_IP@/$TS_IP/" /etc/rancher/k3s/config.yaml
        echo "[postinstall] Updated k3s config with Tailscale IP: $TS_IP"
      elif ! grep -q "  - $TS_IP" /etc/rancher/k3s/config.yaml; then
        # Add Tailscale IP to tls-san if not already present
        sed -i "/tls-san:/a\  - $TS_IP" /etc/rancher/k3s/config.yaml
        echo "[postinstall] Added Tailscale IP to k3s tls-san: $TS_IP"
      fi
      
      # If k3s is running, rotate certificates to pick up new SANs
      if command -v k3s >/dev/null 2>&1 && systemctl is-active --quiet k3s 2>/dev/null; then
        echo "[postinstall] Rotating k3s certificates to apply new Tailscale IP SAN..."
        k3s certificate rotate --service server || true
        k3s certificate rotate --service api-server || true
        k3s certificate rotate --service controller-manager || true
        k3s certificate rotate --service scheduler || true
        echo "[postinstall] k3s certificate rotation completed"
      fi
    fi
  else
    echo "[postinstall] WARNING: Tailscale IP not available; skipping k3s config update"
  fi
  mark_step "12b-k3s-update-tailscale-ip"
fi

# Step 13: Configure k3s with Tailscale IP (master nodes only)
if skip_if_done "13-k3s-config" "k3s configuration"; then
  :
else
  # Only create k3s config for master nodes (not for workers)
  # Worker nodes will be configured later via k3s agent installation
  if [[ "@WORKER_MODE@" != "true" ]]; then
    echo "[postinstall] Writing k3s config with TLS SANs for @PUBLIC_HOSTNAME@, @EXTERNAL_IP@, and $TS_IP ..."
    mkdir -p /etc/rancher/k3s
    cat >/etc/rancher/k3s/config.yaml <<K3S_EOF
write-kubeconfig-mode: "0644"
tls-san:
  - @PUBLIC_HOSTNAME@
  - @EXTERNAL_IP@
  - $TS_IP
  - localhost
K3S_EOF
    # Bind flannel to the Tailscale interface so cross-node pod networking works with
    # workers that join over Tailscale (e.g. the on-demand GPU node). Without this, the
    # master advertises a flannel public-ip the worker can't reach and VXLAN traffic —
    # service DNS, in-cluster S3 — is silently undeliverable. Only set when Tailscale is
    # up (else flannel can't find tailscale0 and cluster networking would fail to start).
    if [[ -n "$TS_IP" ]]; then
      echo "flannel-iface: tailscale0" >>/etc/rancher/k3s/config.yaml
      echo "[postinstall] Set flannel-iface=tailscale0 (cross-node pod networking over Tailscale)"
    fi

    # Kubelet image garbage collection. The defaults (85/80, no max age) let one image
    # tag per CI build pile up until the disk is nearly full -- a node that deploys a
    # few times a day accumulates tens of GiB of tags nothing references any more.
    # imageMaximumGCAge is the real lever: an image no container has used for 48h is
    # evicted regardless of disk pressure, so a node keeps roughly the last two days of
    # builds and everything else is re-pulled from the environment's own registry. It
    # has to go through a config file -- there is no --image-maximum-gc-age kubelet flag.
    # Only safe while no CronJob runs less often than the max age; raise it first if you
    # add a weekly or monthly job.
    #
    # The thresholds are only a backstop, deliberately not tuned tight: they are a
    # percentage of the *imagefs*, and kubelet can only ever delete images. On a node
    # whose non-image data already exceeds the low threshold -- local-path PVCs sharing
    # the root filesystem, say -- kubelet would re-run GC every cycle, evict every image
    # not currently running, and still never reach the target. Keep the low threshold
    # above the node's non-image floor; let imageMaximumGCAge do the actual work.
    cat >/etc/rancher/k3s/kubelet.config <<KUBELET_EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
imageMinimumGCAge: 2m
imageMaximumGCAge: 48h
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
KUBELET_EOF
    printf 'kubelet-arg:\n  - "config=/etc/rancher/k3s/kubelet.config"\n' >>/etc/rancher/k3s/config.yaml
    echo "[postinstall] Wrote kubelet image-GC config (max age 48h, thresholds 80/70)"

    # If k3s already exists, request certificate rotation to pick up new SANs (will be applied after restart)
    if command -v k3s >/dev/null 2>&1; then
      echo "[postinstall] Existing k3s detected; rotating certificates..."
      k3s certificate rotate --service server || true
      k3s certificate rotate --service api-server || true
      k3s certificate rotate --service controller-manager || true
      k3s certificate rotate --service scheduler || true
      echo "[postinstall] k3s certificate rotation completed"
    fi
  else
    echo "[postinstall] Worker mode detected; skipping k3s server config (will be configured as agent later)"
  fi
  mark_step "13-k3s-config"
fi

# Step 14: Install k3s (master nodes only)
if skip_if_done "14-k3s-install" "k3s installation"; then
  :
else
  # Only install k3s server on master nodes
  # Worker nodes will have k3s agent installed later via the provisioning script
  if [[ "@WORKER_MODE@" != "true" ]]; then
    echo "[postinstall] Installing k3s server (skip auto-start); logging to /root/k3s-install.log ..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true sh - >/root/k3s-install.log 2>&1 || true
  else
    echo "[postinstall] Worker mode detected; skipping k3s server installation (agent will be installed later)"
  fi
  mark_step "14-k3s-install"
fi

# Step 14a: Redirect k3s local-path storage to /data volume (master nodes only).
# The /data partition is much larger than rootfs; storing PVCs there prevents
# disk pressure. We use a SYMLINK (not a bind mount) because a bind mount under
# /var/lib/rancher/k3s/ is unmounted whenever k3s restarts, leaving any pod
# with a still-open local-volume mount referencing a now-empty inode (Loki,
# Harbor redis, Grafana have all hit this). A symlink is followed at mount()
# time, so pod mounts resolve to /data/k3s-storage/* and survive k3s restarts.
# After provisioning, also patch local-path-config so new PVs land on
# /data/k3s-storage natively (kubectl patch is done by k3s/postgres.sh /
# observability.sh on first run; safe to apply manually otherwise).
if skip_if_done "14a-k3s-storage-redirect" "k3s local-path storage redirect to /data"; then
  :
else
  if [[ "@WORKER_MODE@" != "true" ]]; then
    echo "[postinstall] Redirecting k3s local-path storage to /data volume (symlink)..."
    mkdir -p /data/k3s-storage
    # Clean up any prior fstab bind-mount entry (legacy layout).
    if grep -q "/data/k3s-storage /var/lib/rancher/k3s/storage" /etc/fstab; then
      sed -i.bak "/\\/data\\/k3s-storage \\/var\\/lib\\/rancher\\/k3s\\/storage/d" /etc/fstab
      mountpoint -q /var/lib/rancher/k3s/storage && umount /var/lib/rancher/k3s/storage || true
    fi
    # Create symlink (or replace existing empty dir).
    if [[ -L /var/lib/rancher/k3s/storage ]]; then
      echo "[postinstall] symlink already present"
    else
      [[ -d /var/lib/rancher/k3s/storage ]] && rmdir /var/lib/rancher/k3s/storage 2>/dev/null || true
      mkdir -p /var/lib/rancher/k3s
      ln -sf /data/k3s-storage /var/lib/rancher/k3s/storage
    fi
    echo "[postinstall] ✓ /var/lib/rancher/k3s/storage -> /data/k3s-storage (symlink)"
  else
    echo "[postinstall] Worker mode detected; skipping storage redirect"
  fi
  mark_step "14a-k3s-storage-redirect"
fi

# Step 14b: Configure Traefik to preserve real client IPs (master nodes only)
if skip_if_done "14b-traefik-config" "Traefik externalTrafficPolicy configuration"; then
  :
else
  if [[ "@WORKER_MODE@" != "true" ]]; then
    echo "[postinstall] Starting k3s temporarily to configure Traefik..."
    systemctl start k3s 2>/dev/null || true
    
    # Wait for k3s to be ready (up to 2 minutes)
    echo "[postinstall] Waiting for k3s API server to be ready..."
    for i in {1..24}; do
      if kubectl get nodes >/dev/null 2>&1; then
        echo "[postinstall] k3s API server is ready"
        break
      fi
      sleep 5
    done
    
    # Wait for Traefik service to exist (up to 2 minutes)
    echo "[postinstall] Waiting for Traefik service to be created..."
    for i in {1..24}; do
      if kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
        echo "[postinstall] Traefik service found"
        break
      fi
      sleep 5
    done
    
    # Configure Traefik to preserve real client IPs
    if kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
      echo "[postinstall] Configuring Traefik externalTrafficPolicy=Local to preserve client IPs..."
      kubectl -n kube-system patch svc traefik -p '{"spec":{"externalTrafficPolicy":"Local"}}' 2>/dev/null || true
      
      # Verify the change
      POLICY=$(kubectl -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}' 2>/dev/null || echo "")
      if [[ "$POLICY" == "Local" ]]; then
        echo "[postinstall] ✓ Traefik configured with externalTrafficPolicy=Local (preserves real client IPs)"
      else
        echo "[postinstall] WARNING: Failed to configure Traefik externalTrafficPolicy"
      fi
    else
      echo "[postinstall] WARNING: Traefik service not found, skipping configuration"
    fi
    
    # Stop k3s again (will be started after final reboot)
    echo "[postinstall] Stopping k3s (will auto-start after reboot)..."
    systemctl stop k3s 2>/dev/null || true
  else
    echo "[postinstall] Worker mode detected; skipping Traefik configuration"
  fi
  mark_step "14b-traefik-config"
fi

# Step 15: Enable UFW after Tailscale is confirmed
if skip_if_done "15-ufw-enable" "UFW enablement after Tailscale"; then
  :
else
  echo "[postinstall] Checking if Tailscale is ready before enabling UFW..."
  TS_CONFIGURED=false
  # Check if Tailscale is configured
  if tailscale status --peers=false >/dev/null 2>&1; then
    TS_CONFIGURED=true
  fi
  
  if [[ "$TS_CONFIGURED" == "true" ]]; then
    # Wait up to 60 seconds for Tailscale interface to be ready
    TS_INTERFACE_UP=false
    for i in {1..60}; do
      if ip link show tailscale0 >/dev/null 2>&1; then
        echo "[postinstall] Tailscale interface (tailscale0) is up."
        TS_INTERFACE_UP=true
        break
      fi
      sleep 1
    done
    
    if [[ "$TS_INTERFACE_UP" != "true" ]]; then
      echo "[postinstall] WARNING: Tailscale interface did not come up after 60 seconds."
      echo "[postinstall] NOT enabling UFW to avoid lockout. Enable manually after verifying Tailscale."
      echo "[postinstall] To enable UFW after Tailscale is working: sudo ufw --force enable"
    else
      # Get Tailscale IP for validation
      TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
      if [[ -n "$TS_IP" ]]; then
        echo "[postinstall] Tailscale IP: $TS_IP"
        echo "[postinstall] Tailscale is configured and validated."
      else
        echo "[postinstall] WARNING: Could not get Tailscale IP. Tailscale may not be fully configured."
      fi
      
      # Enable UFW after Tailscale is confirmed working
      echo "[postinstall] Enabling UFW and ensuring it starts on boot ..."
      ufw --force enable >/dev/null 2>&1 || true
      if command -v systemctl >/dev/null 2>&1 && [[ "$(cat /proc/1/comm 2>/dev/null || true)" == "systemd" ]]; then
        systemctl enable ufw || true
      fi
      echo "[postinstall] UFW status after enabling (verbose):"
      ufw status verbose || true
    fi
  else
    echo "[postinstall] WARNING: Tailscale is not configured. SSH access may be lost after UFW is enabled."
    echo "[postinstall] NOT enabling UFW to avoid lockout. Enable manually after verifying Tailscale."
    echo "[postinstall] To enable UFW after Tailscale is working: sudo ufw --force enable"
  fi
  mark_step "15-ufw-enable"
fi

# Step 16: SSH hardening - disable root login
if skip_if_done "16-ssh-hardening" "SSH hardening (disable root login)"; then
  :
else
  echo "[postinstall] Disabling SSH root login via sshd drop-in ..."
  mkdir -p /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-disable-root.conf <<'SSHD_EOF'
# Managed by infra postinstall
PermitRootLogin no
SSHD_EOF
  # Also enforce in main sshd_config to avoid overrides by later directives
  if [[ -f /etc/ssh/sshd_config ]]; then
    if grep -q '^[#[:space:]]*PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null; then
      sed -ri 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
    else
      echo 'PermitRootLogin no' >> /etc/ssh/sshd_config || true
    fi
  fi
  # Validate configuration syntax (non-fatal in chroot/non-systemd contexts)
  if command -v sshd >/dev/null 2>&1; then
    sshd -t || true
  fi
  # Apply SSH configuration without waiting for reboot (prefer reload to avoid dropping current connection)
  if command -v systemctl >/dev/null 2>&1 && [[ "$(cat /proc/1/comm 2>/dev/null || true)" == "systemd" ]]; then
    echo "[postinstall] Reloading sshd to apply configuration changes ..."
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    # Fallback to restart if reload is unsupported
    if ! systemctl is-active --quiet sshd 2>/dev/null && ! systemctl is-active --quiet ssh 2>/dev/null; then
      echo "[postinstall] Reload may have failed; restarting sshd ..."
      systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    fi
    systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null || true
  else
    # Non-systemd or chrooted: try sending SIGHUP to running sshd if possible
    if command -v pgrep >/dev/null 2>&1; then
      echo "[postinstall] Signaling sshd (SIGHUP) to reload configuration ..."
      pgrep -x sshd >/dev/null 2>&1 && kill -HUP $(pgrep -x sshd | head -n1) 2>/dev/null || true
    fi
  fi
  echo "[postinstall] SSH root login disabled. Change applied immediately if possible and will persist after reboot."
  mark_step "16-ssh-hardening"
fi

# Step 17: Mark completion and reboot
echo "[postinstall] Postinstall completion summary:"
echo "[postinstall] ============================================"
ls -1 "$MARKER_DIR" | sed 's/^/[postinstall]   ✓ /'
echo "[postinstall] ============================================"

echo "[postinstall] Marking final completion at $MARKER_COMPLETE ..."
date +"%Y-%m-%dT%H:%M:%S%z" > "$MARKER_COMPLETE" || touch "$MARKER_COMPLETE" || true
echo "[postinstall] Postinstall completed successfully."
echo "[postinstall] All 18 steps have been executed."
echo "[postinstall] Now rebooting to apply all changes..."
sleep 2
reboot
POSTINSTALL_EOF
}

function wait_for_ssh(){
  local ip=$1 port=$2 tries=${3:-120}
  info "Waiting for SSH on ${ip}:${port} ..."
  for ((i=1; i<=tries; i++)); do
    set +e
    local out
    out=$(ssh -p "$port" "${SSH_OPTS[@]}" -o PreferredAuthentications=publickey -o NumberOfPasswordPrompts=0 root@"$ip" 'true' 2>&1)
    local ec=$?
    set -e
    if [[ $ec -eq 0 ]] || grep -qiE 'permission denied|authentication failed' <<<"$out"; then
      ok "SSH is available on ${ip}:${port}"
      return 0
    fi
    sleep 5
  done
  return 1
}

# Test root SSH on a given port. Prints one of: ok | auth-failed | unreachable
function test_root_ssh(){
  local port=$1
  set +e
  local out
  out=$(ssh -p "$port" "${SSH_OPTS[@]}" -o BatchMode=yes -o PreferredAuthentications=publickey -o NumberOfPasswordPrompts=0 root@"${EXTERNAL_IP}" 'true' 2>&1)
  local ec=$?
  set -e
  if [[ $ec -eq 0 ]]; then
    echo ok
    return 0
  fi
  if grep -qiE 'permission denied|authentication failed' <<<"$out"; then
    echo auth-failed
    return 1
  fi
  echo unreachable
  return 2
}

# Get Tailscale IP for a hostname (early detection)
# Returns 0 if IP found and stored in TAILSCALE_IP variable, 1 otherwise
function detect_tailscale_ip(){
  local hostname="$1"
  
  if ! tailscale::read_api_token 2>/dev/null; then
    dbg "Tailscale API token not available; skipping Tailscale IP detection"
    TAILSCALE_IP=""
    return 1
  fi
  
  dbg "Attempting to detect Tailscale IP for ${hostname}..."
  local tailscale_ip
  tailscale_ip=$(tailscale::get_device_ip "${hostname}" || true)
  
  if [[ -z "$tailscale_ip" ]]; then
    dbg "Could not retrieve Tailscale IP for ${hostname} from API"
    TAILSCALE_IP=""
    return 1
  fi
  
  TAILSCALE_IP="${tailscale_ip}"
  ok "Detected Tailscale IP for ${hostname}: ${TAILSCALE_IP}"
  return 0
}

# Try to get Tailscale IP for a hostname and attempt SSH connection
# Returns 0 if successful, 1 if Tailscale IP not available or SSH fails
function try_ssh_via_tailscale(){
  local hostname="$1" port="${2:-22}" user="${3:-admin}"
  
  if ! tailscale::read_api_token 2>/dev/null; then
    dbg "Tailscale API token not available; skipping Tailscale IP fallback"
    return 1
  fi
  
  info "Attempting to get Tailscale IP for ${hostname}..."
  local tailscale_ip
  tailscale_ip=$(tailscale::get_device_ip "${hostname}" || true)
  
  if [[ -z "$tailscale_ip" ]]; then
    dbg "Could not retrieve Tailscale IP for ${hostname}"
    return 1
  fi
  
  ok "Found Tailscale IP for ${hostname}: ${tailscale_ip}"
  info "Attempting SSH on ${user}@${tailscale_ip}:${port} (via Tailscale)..."
  
  if ssh -p "$port" "${SSH_OPTS[@]}" "${user}@${tailscale_ip}" 'true' >/dev/null 2>&1; then
    ok "SSH successful via Tailscale IP: ${user}@${tailscale_ip}:${port}"
    # Update EXTERNAL_IP to use Tailscale IP for subsequent connections
    EXTERNAL_IP="${tailscale_ip}"
    PROVISION_HOST="${tailscale_ip}"
    return 0
  else
    warn "SSH failed via Tailscale IP ${tailscale_ip}"
    return 1
  fi
}

# Wait for SSH on host:port for a specific user
function wait_for_ssh_user(){
  local host=$1 port=$2 user=$3 tries=${4:-120}
  info "Waiting for SSH on ${user}@${host}:${port} ..."
  for ((i=1; i<=tries; i++)); do
    if ssh -p "$port" "${SSH_OPTS[@]}" "${user}@${host}" 'true' >/dev/null 2>&1; then
      ok "SSH is available on ${user}@${host}:${port}"
      return 0
    fi
    sleep 5
  done
  
  # If public IP failed, try Tailscale IP as fallback
  dbg "SSH on public IP failed after ${tries} tries; attempting Tailscale IP fallback..."
  if try_ssh_via_tailscale "${HOSTNAME}" "$port" "$user"; then
    return 0
  fi
  
  return 1
}

# Show system parameters on remote host as admin
function show_system_info(){
  local host=$1 port=${2:-22}
  ssh -p "$port" "${SSH_OPTS[@]}" admin@"$host" "bash -s" <<'REMOTE_INFO'
set -euo pipefail
if command -v hostnamectl >/dev/null 2>&1; then
  echo '=== hostnamectl ==='
  hostnamectl status --no-pager || true
else
  echo '=== hostname ==='
  hostname
fi
echo '=== uname -a ==='
uname -a || true
if command -v lsb_release >/dev/null 2>&1; then
  echo '=== OS Release ==='
  lsb_release -a || true
else
  echo '=== /etc/os-release ==='
  grep -E '^(NAME|VERSION)=' /etc/os-release || true
fi
echo '=== Kernel ==='
uname -r || true
if command -v lscpu >/dev/null 2>&1; then
  echo '=== CPU ==='
  lscpu | egrep 'Model name:|CPU\(s\):' || true
fi
echo '=== Memory ==='
free -h || true
echo '=== Disks ==='
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/  /' || true
echo '=== Network (brief) ==='
ip -brief addr || ip addr || true
REMOTE_INFO
}

if ! $SKIP_DIAGNOSE; then
  info "Diagnosing DNS resolution for ${HOSTNAME}"
  if (command -v getent >/dev/null 2>&1 && getent hosts "${HOSTNAME}" >/dev/null) || \
     (command -v dig >/dev/null 2>&1 && dig +short "${HOSTNAME}" | grep -qE '^[0-9.]+$') || \
     (command -v host >/dev/null 2>&1 && host "${HOSTNAME}" >/dev/null); then
    ok "DNS resolves ${HOSTNAME}"
  else
    warn "DNS does not resolve ${HOSTNAME}. Continuing with EXTERNAL_IP ${EXTERNAL_IP}."
  fi

  info "Pinging ${EXTERNAL_IP}"
  if ping -c1 -W1 "${EXTERNAL_IP}" >/dev/null 2>&1; then
    ok "Host ${EXTERNAL_IP} is reachable by ICMP"
  else
    warn "ICMP ping failed for ${EXTERNAL_IP}. SSH may still work."
  fi

  # Check if machine is in Tailscale first - if so, skip public IP SSH test
  info "Checking if machine is registered in Tailscale..."
  if detect_tailscale_ip "${HOSTNAME}"; then
    ok "Machine found in Tailscale (${TAILSCALE_IP}). Skipping public IP SSH test."
  else
    info "Testing SSH connectivity (rescue, port ${SSH_PORT_RESCUE})"
    if ssh -p ${SSH_PORT_RESCUE} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" 'env TERM=xterm uname -a || true' >/dev/null; then
      ok "SSH connectivity OK on port ${SSH_PORT_RESCUE}"
    else
      warn "Cannot SSH to ${EXTERNAL_IP}:${SSH_PORT_RESCUE}. Ensure rescue mode is active and IP is correct."
    fi
  fi
fi


# Auto-select phase based on remote state if neither phase was requested.
if $DEFAULT_RUN_ALL; then
  info "Auto-detecting remote state..."
  ACTIVE_SSH_PORT=""
  TAILSCALE_IP=""
  
  # If --wipe flag is set, skip detection and go straight to rescue mode
  if $WIPE; then
    info "--wipe flag provided. Proceeding to rescue mode activation..."
    # Will be handled below in the wipe section
  else
    # First, try to detect Tailscale IP and attempt SSH via Tailscale
    info "Checking if machine is already registered in Tailscale..."
    if detect_tailscale_ip "${HOSTNAME}"; then
      info "Machine found in Tailscale. Attempting SSH via Tailscale IP..."
      
      # Try as admin user first (already provisioned)
      if ssh -p 22 "${SSH_OPTS[@]}" admin@"${TAILSCALE_IP}" 'sudo -n true' 2>/dev/null; then
        ok "Successfully connected as admin@${TAILSCALE_IP} (Tailscale) with sudo access"
        EXTERNAL_IP="${TAILSCALE_IP}"
        PROVISION_HOST="${TAILSCALE_IP}"
        ACTIVE_SSH_PORT=22
        REMOTE_STATE="installed"
        info "Machine is already provisioned. Proceeding with post-provisioning steps via Tailscale..."
      # Try as root user (rescue mode or fresh install)
      elif ssh -p 22 "${SSH_OPTS[@]}" root@"${TAILSCALE_IP}" 'true' 2>/dev/null; then
        ok "Successfully connected as root@${TAILSCALE_IP} (Tailscale)"
        EXTERNAL_IP="${TAILSCALE_IP}"
        PROVISION_HOST="${TAILSCALE_IP}"
        ACTIVE_SSH_PORT=22
        REMOTE_STATE="rescue"
        info "Connected via Tailscale IP. Proceeding with provisioning..."
      else
        dbg "SSH via Tailscale IP failed; will try public IP next"
      fi
    fi
    
    # If Tailscale connection failed or not available, try public IP
    if [[ -z "${ACTIVE_SSH_PORT}" ]]; then
      info "Attempting to detect remote state via root SSH on public IP..."
      set +e
      state22=$(test_root_ssh 22); rc22=$?
      set -e
      auth_failed=false
      if [[ $rc22 -eq 0 ]]; then ACTIVE_SSH_PORT=22; fi
      if [[ $rc22 -eq 1 ]]; then auth_failed=true; fi
    fi
    
    if [[ -z "${ACTIVE_SSH_PORT}" ]]; then
      if $auth_failed; then
        info "SSH is reachable but root login is disabled. Attempting to use admin user..."
        
        # Try to connect as admin user with sudo (on public IP)
        if ssh -p 22 "${SSH_OPTS[@]}" admin@"${EXTERNAL_IP}" 'sudo -n true' 2>/dev/null; then
          info "Successfully connected as admin@${EXTERNAL_IP} with sudo access. Continuing with post-provisioning..."
          ACTIVE_SSH_PORT=22
          REMOTE_STATE="installed"
        else
          # Try via Tailscale if public IP admin access failed
          if [[ -n "${TAILSCALE_IP}" ]]; then
            info "Admin access on public IP failed. Retrying via Tailscale IP..."
            if ssh -p 22 "${SSH_OPTS[@]}" admin@"${TAILSCALE_IP}" 'sudo -n true' 2>/dev/null; then
              ok "Successfully connected as admin@${TAILSCALE_IP} (Tailscale) with sudo access"
              EXTERNAL_IP="${TAILSCALE_IP}"
              PROVISION_HOST="${TAILSCALE_IP}"
              ACTIVE_SSH_PORT=22
              REMOTE_STATE="installed"
            else
              info "SSH is reachable but neither root nor admin login is available. Assuming already provisioned; exiting."
              info "Hint: Use --wipe flag to force full reprovisioning of an existing server."
              exit 0
            fi
          else
            info "SSH is reachable but neither root nor admin login is available. Assuming already provisioned; exiting."
            info "Hint: Use --wipe flag to force full reprovisioning of an existing server."
            exit 0
          fi
        fi
      fi
    fi
  fi
  
  # If we still don't have SSH connection, handle wipe or error
  if [[ -z "${ACTIVE_SSH_PORT}" ]]; then
    if $WIPE; then
      warn "Cannot establish SSH connectivity, but --wipe flag provided."
      warn "Will proceed to activate rescue mode and trigger hardware reset..."
      # Server is provisioned but we need to wipe it - activate rescue mode
      info "Activating Hetzner Rescue System via Robot API..."
      dbg "Attempting to activate rescue for server IP: ${EXTERNAL_IP}"
      # Get the SSH key fingerprint for the provisioning key
      key_fp=$(robot::get_key_fingerprint "${PROV_SSH_PUB}")
      if [[ -n "$key_fp" ]]; then
        info "Using SSH key fingerprint: ${key_fp}"
      else
        warn "Could not determine SSH key fingerprint; rescue mode may use default key"
      fi
      set +e
      if [[ -n "$key_fp" ]]; then
        rescue_response=$(robot::api POST "/boot/${EXTERNAL_IP}/rescue" -d "os=linux" -d "arch=64" -d "authorized_key=${key_fp}" 2>&1)
      else
        rescue_response=$(robot::api POST "/boot/${EXTERNAL_IP}/rescue" -d "os=linux" -d "arch=64" 2>&1)
      fi
      rescue_rc=$?
      set -e
      if [[ $rescue_rc -ne 0 ]]; then
        warn "Failed with /boot/${EXTERNAL_IP}/rescue endpoint. Trying to find server by listing all servers..."
        # Try to get server list and find the server number
        set +e
        servers_list=$(robot::api GET "/server")
        servers_rc=$?
        set -e
        if [[ $servers_rc -eq 0 ]]; then
          dbg "Servers list retrieved, searching for IP ${EXTERNAL_IP}"
          if command -v jq >/dev/null 2>&1; then
            server_number=$(printf '%s' "$servers_list" | jq -r ".[] | select(.server.server_ip == \"${EXTERNAL_IP}\") | .server.server_number" 2>/dev/null | head -1)
            if [[ -n "$server_number" && "$server_number" != "null" ]]; then
              info "Found server number: ${server_number} for IP ${EXTERNAL_IP}"
              info "Retrying rescue activation with server number..."
              set +e
              if [[ -n "$key_fp" ]]; then
                rescue_response=$(robot::api POST "/boot/${server_number}/rescue" -d "os=linux" -d "arch=64" -d "authorized_key=${key_fp}" 2>&1)
              else
                rescue_response=$(robot::api POST "/boot/${server_number}/rescue" -d "os=linux" -d "arch=64" 2>&1)
              fi
              rescue_rc=$?
              set -e
            fi
          fi
        fi
        if [[ $rescue_rc -ne 0 ]]; then
          err "Failed to activate rescue mode. HTTP status: ${ROBOT_LAST_HTTP:-unknown}"
          err "API response: ${ROBOT_LAST_BODY:-no response}"
          if [[ -n "$rescue_response" ]]; then
            err "Full response: $rescue_response"
          fi
          err "Please activate rescue mode manually in Hetzner Robot and retry."
          exit 1
        fi
      fi
      ok "Rescue mode activated"
      
      # Update server name in Robot API to match HOSTNAME
      info "Updating server name in Robot API to '${HOSTNAME}'..."
      # Get server number if we don't have it yet
      if [[ -z "${server_number:-}" ]]; then
        set +e
        servers_list=$(robot::api GET "/server")
        servers_rc=$?
        set -e
        if [[ $servers_rc -eq 0 ]]; then
          dbg "Servers list retrieved, searching for IP ${EXTERNAL_IP}"
          if $DEBUG; then
            info "Raw servers list:"
            printf '%s\n' "$servers_list"
            echo ""
          fi
          if command -v jq >/dev/null 2>&1; then
            # Try to parse and show all server IPs for debugging
            if $DEBUG; then
              info "Available server IPs in Robot API:"
              printf '%s' "$servers_list" | jq -r '.[].server.server_ip' 2>&1 | sed 's/^/  /'
            fi
            server_number=$(printf '%s' "$servers_list" | jq -r ".[] | select(.server.server_ip == \"${EXTERNAL_IP}\") | .server.server_number" 2>&1 | head -1)
            dbg "Extracted server_number: '${server_number:-<empty>}'"
            if [[ -z "$server_number" || "$server_number" == "null" ]]; then
              warn "jq failed to extract server_number. Trying alternative parsing..."
              # Fallback: grep-based extraction
              server_number=$(printf '%s' "$servers_list" | grep -o "\"server_ip\":\"${EXTERNAL_IP}\"" -A 20 | grep -o '"server_number":[0-9]*' | head -1 | cut -d: -f2)
              dbg "Fallback extracted server_number: '${server_number:-<empty>}'"
            fi
          else
            warn "jq not available; cannot parse server list"
          fi
        else
          warn "Failed to retrieve servers list. HTTP status: ${ROBOT_LAST_HTTP:-unknown}"
        fi
      fi
      if [[ -n "${server_number:-}" && "$server_number" != "null" ]]; then
        dbg "Updating server name for server number: ${server_number}"
        set +e
        name_response=$(robot::api POST "/server/${server_number}" -d "server_name=${HOSTNAME}" 2>&1)
        name_rc=$?
        set -e
        if [[ $name_rc -eq 0 ]]; then
          ok "Server name updated to '${HOSTNAME}' in Robot API"
        else
          warn "Failed to update server name in Robot API (non-fatal). HTTP status: ${ROBOT_LAST_HTTP:-unknown}"
          if $DEBUG; then
            dbg "Name update response: $name_response"
          fi
        fi
      else
        warn "Could not determine server number; skipping server name update"
      fi
      
      info "Triggering hardware reset via Robot API..."
      dbg "Attempting to reset server IP: ${EXTERNAL_IP}"
      set +e
      reset_response=$(robot::api POST "/reset/${EXTERNAL_IP}" -d "type=hw" 2>&1)
      reset_rc=$?
      set -e
      if [[ $reset_rc -ne 0 ]]; then
        warn "Failed with /reset/${EXTERNAL_IP} endpoint. Trying to find server number..."
        # Try to get server list and find the server number (reuse if we already have it)
        if [[ -z "${server_number:-}" ]]; then
          set +e
          servers_list=$(robot::api GET "/server")
          servers_rc=$?
          set -e
          if [[ $servers_rc -eq 0 ]]; then
            dbg "Servers list retrieved, searching for IP ${EXTERNAL_IP}"
            if command -v jq >/dev/null 2>&1; then
              server_number=$(printf '%s' "$servers_list" | jq -r ".[] | select(.server.server_ip == \"${EXTERNAL_IP}\") | .server.server_number" 2>/dev/null | head -1)
            fi
          fi
        fi
        if [[ -n "${server_number:-}" && "$server_number" != "null" ]]; then
          info "Found server number: ${server_number} for IP ${EXTERNAL_IP}"
          info "Retrying hardware reset with server number..."
          set +e
          reset_response=$(robot::api POST "/reset/${server_number}" -d "type=hw" 2>&1)
          reset_rc=$?
          set -e
        fi
        if [[ $reset_rc -ne 0 ]]; then
          err "Failed to trigger hardware reset. HTTP status: ${ROBOT_LAST_HTTP:-unknown}"
          err "API response: ${ROBOT_LAST_BODY:-no response}"
          if [[ -n "$reset_response" ]]; then
            err "Full response: $reset_response"
          fi
          err "Please reset the server manually in Hetzner Robot and retry."
          exit 1
        fi
      fi
      ok "Hardware reset triggered"
      info "Waiting for server to boot into rescue mode (this may take 2-3 minutes)..."
      sleep 120
      cleanup_known_hosts
      if ! wait_for_ssh "${EXTERNAL_IP}" ${SSH_PORT_RESCUE} 120; then
        err "SSH did not come up in rescue mode after reset"
        exit 1
      fi
      # Verify we're in rescue mode
      remote_state=$(ssh -p ${SSH_PORT_RESCUE} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" "export TERM=xterm; if hostname | grep -qi rescue || grep -qi rescue /etc/issue; then echo rescue; else echo installed; fi" 2>/dev/null || true)
      if [[ "${remote_state}" != "rescue" ]]; then
        err "Server did not boot into rescue mode. Please check Hetzner Robot console and retry."
        exit 1
      fi
      ok "Server is now in rescue mode"
      ACTIVE_SSH_PORT=${SSH_PORT_RESCUE}
      RUN_INSTALLIMAGE=true
      RUN_FOLLOWUP=false
    else
      err "Cannot establish SSH connectivity to ${EXTERNAL_IP}."
      err "Use --wipe flag to force rescue mode activation and provisioning."
      exit 1
    fi
  fi
fi

# Detect rescue vs installed
remote_state="${REMOTE_STATE:-}"
if [[ -z "$remote_state" ]]; then
  remote_state=$(ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" "export TERM=xterm; if hostname | grep -qi rescue || grep -qi rescue /etc/issue; then echo rescue; else echo installed; fi" 2>/dev/null || true)
fi
info "SSH works on port ${ACTIVE_SSH_PORT}; remote_state='${remote_state}'"
if [[ "${remote_state}" == "rescue" ]]; then
  ok "Remote is Hetzner Rescue System"
  RUN_INSTALLIMAGE=true
  RUN_FOLLOWUP=false
else
  ok "Remote is installed OS"
  if $WIPE; then
    warn "--wipe flag provided. Will activate rescue mode and reprovision the server."
    info "Activating Hetzner Rescue System via Robot API..."
    dbg "Attempting to activate rescue for server IP: ${EXTERNAL_IP}"
    # Get the SSH key fingerprint for the provisioning key
    key_fp=$(robot::get_key_fingerprint "${PROV_SSH_PUB}")
    if [[ -n "$key_fp" ]]; then
      info "Using SSH key fingerprint: ${key_fp}"
    else
      warn "Could not determine SSH key fingerprint; rescue mode may use default key"
    fi
    set +e
    if [[ -n "$key_fp" ]]; then
      rescue_response=$(robot::api POST "/boot/${EXTERNAL_IP}/rescue" -d "os=linux" -d "arch=64" -d "authorized_key=${key_fp}" 2>&1)
    else
      rescue_response=$(robot::api POST "/boot/${EXTERNAL_IP}/rescue" -d "os=linux" -d "arch=64" 2>&1)
    fi
    rescue_rc=$?
    set -e
    if [[ $rescue_rc -ne 0 ]]; then
      warn "Failed with /boot/${EXTERNAL_IP}/rescue endpoint. Trying to find server by listing all servers..."
      # Try to get server list and find the server number
      set +e
      servers_list=$(robot::api GET "/server")
      servers_rc=$?
      set -e
      if [[ $servers_rc -eq 0 ]]; then
        dbg "Servers list retrieved, searching for IP ${EXTERNAL_IP}"
        if command -v jq >/dev/null 2>&1; then
          server_number=$(printf '%s' "$servers_list" | jq -r ".[] | select(.server.server_ip == \"${EXTERNAL_IP}\") | .server.server_number" 2>/dev/null | head -1)
          if [[ -n "$server_number" && "$server_number" != "null" ]]; then
            info "Found server number: ${server_number} for IP ${EXTERNAL_IP}"
            info "Retrying rescue activation with server number..."
            set +e
            if [[ -n "$key_fp" ]]; then
              rescue_response=$(robot::api POST "/boot/${server_number}/rescue" -d "os=linux" -d "arch=64" -d "authorized_key=${key_fp}" 2>&1)
            else
              rescue_response=$(robot::api POST "/boot/${server_number}/rescue" -d "os=linux" -d "arch=64" 2>&1)
            fi
            rescue_rc=$?
            set -e
          fi
        fi
      fi
      if [[ $rescue_rc -ne 0 ]]; then
        err "Failed to activate rescue mode. HTTP status: ${ROBOT_LAST_HTTP:-unknown}"
        err "API response: ${ROBOT_LAST_BODY:-no response}"
        if [[ -n "$rescue_response" ]]; then
          err "Full response: $rescue_response"
        fi
        err "Please activate rescue mode manually in Hetzner Robot and retry."
        exit 1
      fi
    fi
    ok "Rescue mode activated"
    
    # Update server name in Robot API to match HOSTNAME if different
    info "Checking server name in Robot API..."
    # Get server number and current name if we don't have them yet
    if [[ -z "${server_number:-}" ]]; then
      set +e
      servers_list=$(robot::api GET "/server")
      servers_rc=$?
      set -e
      if [[ $servers_rc -eq 0 ]]; then
        dbg "Servers list retrieved, searching for IP ${EXTERNAL_IP}"
        if $DEBUG; then
          info "Raw servers list:"
          printf '%s\n' "$servers_list" | head -n 20
          echo "..."
        fi
        if command -v jq >/dev/null 2>&1; then
          # Extract server info for the current IP
          server_info=$(printf '%s' "$servers_list" | jq -r ".[] | select(.server.server_ip == \"${EXTERNAL_IP}\")" 2>/dev/null || true)
          if [[ -n "$server_info" ]]; then
            server_number=$(printf '%s' "$server_info" | jq -r '.server.server_number' 2>/dev/null || true)
            current_name=$(printf '%s' "$server_info" | jq -r '.server.server_name' 2>/dev/null || true)
            dbg "Current server name: '${current_name:-<empty>}', target: '${HOSTNAME}'"
          fi
        fi
        
        # Fallback if jq parsing failed
        if [[ -z "$server_number" || "$server_number" == "null" ]]; then
          warn "jq parsing failed, trying alternative extraction..."
          server_line=$(printf '%s' "$servers_list" | grep -o "\"server_ip\":\"${EXTERNAL_IP}\".*\"server_number\":\?[0-9]*" -m 1 || true)
          if [[ -n "$server_line" ]]; then
            server_number=$(echo "$server_line" | grep -o '"server_number":\?\s*\"\?[0-9]\+\"\?' | grep -o '[0-9]\+' | head -1)
            current_name=$(echo "$server_line" | grep -o '"server_name":\?\s*\"\([^\"]*\)\"' | sed -n 's/.*"server_name"\s*:\s*"\([^"]*\)".*/\1/p' | head -1)
            dbg "Fallback extracted - number: '${server_number:-<empty>}', name: '${current_name:-<empty>}'"
          fi
        fi
      else
        warn "Failed to retrieve servers list. HTTP status: ${ROBOT_LAST_HTTP:-unknown}"
      fi
    fi
    
    if [[ -n "${server_number:-}" && "$server_number" != "null" ]]; then
      # Only update if the name is different
      if [[ "$current_name" != "$HOSTNAME" ]]; then
        info "Updating server name from '${current_name:-<empty>}' to '${HOSTNAME}' in Robot API..."
        set +e
        name_response=$(robot::api POST "/server/${server_number}" -d "server_name=${HOSTNAME}" 2>&1)
        name_rc=$?
        set -e
        if [[ $name_rc -eq 0 ]]; then
          ok "Server name updated to '${HOSTNAME}' in Robot API"
        else
          warn "Failed to update server name in Robot API (non-fatal). HTTP status: ${ROBOT_LAST_HTTP:-unknown}"
          if $DEBUG; then
            dbg "Name update response: $name_response"
          fi
        fi
      else
        ok "Server name is already set to '${HOSTNAME}' in Robot API"
      fi
    else
      warn "Could not determine server number; skipping server name update"
    fi
    
    info "Triggering hardware reset via Robot API..."
    dbg "Attempting to reset server IP: ${EXTERNAL_IP}"
    set +e
    reset_response=$(robot::api POST "/reset/${EXTERNAL_IP}" -d "type=hw" 2>&1)
    reset_rc=$?
    set -e
    if [[ $reset_rc -ne 0 ]]; then
      warn "Failed with /reset/${EXTERNAL_IP} endpoint. Trying to find server number..."
      # Try to get server list and find the server number (reuse if we already have it)
      if [[ -z "${server_number:-}" ]]; then
        set +e
        servers_list=$(robot::api GET "/server")
        servers_rc=$?
        set -e
        if [[ $servers_rc -eq 0 ]]; then
          dbg "Servers list retrieved, searching for IP ${EXTERNAL_IP}"
          if command -v jq >/dev/null 2>&1; then
            server_number=$(printf '%s' "$servers_list" | jq -r ".[] | select(.server.server_ip == \"${EXTERNAL_IP}\") | .server.server_number" 2>/dev/null | head -1)
          fi
        fi
      fi
      if [[ -n "${server_number:-}" && "$server_number" != "null" ]]; then
        info "Found server number: ${server_number} for IP ${EXTERNAL_IP}"
        info "Retrying hardware reset with server number..."
        set +e
        reset_response=$(robot::api POST "/reset/${server_number}" -d "type=hw" 2>&1)
        reset_rc=$?
        set -e
      fi
      if [[ $reset_rc -ne 0 ]]; then
        err "Failed to trigger hardware reset. HTTP status: ${ROBOT_LAST_HTTP:-unknown}"
        err "API response: ${ROBOT_LAST_BODY:-no response}"
        if [[ -n "$reset_response" ]]; then
          err "Full response: $reset_response"
        fi
        err "Please reset the server manually in Hetzner Robot and retry."
        exit 1
      fi
    fi
    ok "Hardware reset triggered"
    info "Waiting for server to boot into rescue mode (this may take 2-3 minutes)..."
    sleep 120
    cleanup_known_hosts
    if ! wait_for_ssh "${EXTERNAL_IP}" ${SSH_PORT_RESCUE} 120; then
      err "SSH did not come up in rescue mode after reset"
      exit 1
    fi
    # Verify we're in rescue mode
    remote_state=$(ssh -p ${SSH_PORT_RESCUE} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" "export TERM=xterm; if hostname | grep -qi rescue || grep -qi rescue /etc/issue; then echo rescue; else echo installed; fi" 2>/dev/null || true)
    if [[ "${remote_state}" != "rescue" ]]; then
      err "Server did not boot into rescue mode. Please check Hetzner Robot console and retry."
      exit 1
    fi
    ok "Server is now in rescue mode"
    ACTIVE_SSH_PORT=${SSH_PORT_RESCUE}
    RUN_INSTALLIMAGE=true
    RUN_FOLLOWUP=false
  else
    ok "Remote is already in installed state; skipping --wipe"
    RUN_INSTALLIMAGE=false
    RUN_FOLLOWUP=true
  fi
fi


if $RUN_INSTALLIMAGE; then
  info "Running installimage on ${EXTERNAL_IP} (rescue)"
  BOOTSTRAP_CONTENT=$(cat <<'REMOTE_BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail
export TERM=${TERM:-dumb}
# Compute data LV size based on nvme0n1 size
TOTAL_SIZE=$(( $(blockdev --getsize64 /dev/nvme0n1) / (1024*1024*1024) ))
DATA_SIZE=$(( TOTAL_SIZE - 102 )) # 100GB root + 2GB boot (approx overhead)
cat <<EOT > setup
DRIVE1 /dev/nvme0n1
DRIVE2 /dev/nvme1n1

SWRAID 1
SWRAIDLEVEL 1

BOOTLOADER grub

HOSTNAME ${HOSTNAME_ENV}

PART /boot/efi esp 256M
PART /boot ext3 1G
PART lvm vg0 all

LV vg0 root /      ext4  100G
LV vg0 data /data  ext4  ${DATA_SIZE}G

IMAGE /root/images/Ubuntu-2404-noble-amd64-base.tar.gz
EOT
echo "Preparing setup:"
cat setup

# Locate installimage in rescue environment
INSTALLIMAGE_BIN="$(command -v installimage || true)"
if [[ -z "${INSTALLIMAGE_BIN}" ]]; then
  for p in /usr/sbin/installimage /root/.oldroot/nfs/install/installimage /nfs/install/installimage; do
    if [[ -x "$p" ]]; then INSTALLIMAGE_BIN="$p"; break; fi
  done
fi
if [[ -z "${INSTALLIMAGE_BIN}" ]]; then
  echo "[ERROR] installimage not found. Please boot the server into the Hetzner Rescue System from the Robot/Console and try again." >&2
  exit 1
fi

echo "installimage script located at ${INSTALLIMAGE_BIN}"

cat > ./run-installimage.sh <<RUN_INSTALL
#!/usr/bin/env bash
set -euo pipefail
export TERM=${TERM:-dumb}
export DEBIAN_FRONTEND=noninteractive
exec "${INSTALLIMAGE_BIN}" -a -c setup
RUN_INSTALL
chmod +x ./run-installimage.sh
sync
exit 0

REMOTE_BOOTSTRAP
  )
  # Upload and execute the bootstrap on the remote
  ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" "cat >/root/installimage-bootstrap.sh && chmod +x /root/installimage-bootstrap.sh" <<< "$BOOTSTRAP_CONTENT"
  ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" "export HOSTNAME_ENV='${HOSTNAME}'; export TERM=dumb; /root/installimage-bootstrap.sh"
  ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" "export TERM=dumb; ./run-installimage.sh && reboot"

  # Wait for rescue to go away and new system to come back (SSH expected on port ${SSH_PORT_FINAL} after post-install)
  info "Waiting for host to reboot into fresh system..."
  # Wait for current SSH (rescue) to go down
  for i in {1..60}; do
    if ! ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" -o ConnectTimeout=5 root@"${EXTERNAL_IP}" 'true' >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  # Then wait for SSH on port ${SSH_PORT_FINAL} to come up (fresh installed OS)
  # Clean known_hosts again because the host key changed after OS install
  cleanup_known_hosts
  if ! wait_for_ssh "${EXTERNAL_IP}" ${SSH_PORT_FINAL} 180; then
    err "SSH did not come up on port ${SSH_PORT_FINAL} after installimage"
    exit 1
  fi
  # Re-check remote state to ensure we are out of rescue
  remote_state_post=$(ssh -p ${SSH_PORT_FINAL} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" "if hostname | grep -qi rescue || grep -qi rescue /etc/issue; then echo rescue; else echo installed; fi" 2>/dev/null || true)
  if [[ "${remote_state_post}" == "rescue" ]]; then
    err "System is still in Hetzner Rescue System after reboot. Disable Rescue mode in Hetzner Robot (set boot from disk) and try again."
    exit 1
  fi
  ok "Host came back in installed OS"
  ACTIVE_SSH_PORT=${SSH_PORT_FINAL}
  # Now proceed with follow-up phase to execute postinstall on the installed OS
  RUN_FOLLOWUP=true
fi

if $RUN_FOLLOWUP; then
  info "Starting follow-up provisioning on ${EXTERNAL_IP} (installed OS)"
  
  # Check if postinstall is already done (try root first, then admin with sudo)
  POSTINSTALL_DONE=false
  
  # Determine which host to use for SSH (prefer Tailscale IP if available)
  CHECK_HOST="${EXTERNAL_IP}"
  if [[ -n "${TAILSCALE_IP:-}" ]]; then
    CHECK_HOST="${TAILSCALE_IP}"
  fi
  
  # First try root if we have access
  if ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" root@"${CHECK_HOST}" 'test -f /etc/infra-postinstall.done' 2>/dev/null; then
    POSTINSTALL_DONE=true
  fi
  
  # If not done via root, try admin access with sudo
  if [[ "$POSTINSTALL_DONE" == "false" ]]; then
    if ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" admin@"${CHECK_HOST}" 'sudo test -f /etc/infra-postinstall.done' 2>/dev/null; then
      POSTINSTALL_DONE=true
    fi
  fi
  
  if $POSTINSTALL_DONE; then
    info "Postinstall already applied; skipping postinstall execution."
    # Don't exit - continue to post-provisioning phase to fetch kubeconfig, etc.
    
    # Set up SSH connection variables for post-provisioning
    # Detect Tailscale IP and prefer it over public IP
    info "Detecting Tailscale IP for post-provisioning..."
    TAILSCALE_IP_AFTER_REBOOT=""
    if detect_tailscale_ip "${HOSTNAME}"; then
      TAILSCALE_IP_AFTER_REBOOT="${TAILSCALE_IP}"
      ok "Detected Tailscale IP: ${TAILSCALE_IP_AFTER_REBOOT}"
    fi
    
    # Set SSH_HOST_AFTER_REBOOT for post-provisioning phase
    SSH_HOST_AFTER_REBOOT="${TAILSCALE_IP_AFTER_REBOOT:-${EXTERNAL_IP}}"
    if [[ -n "${TAILSCALE_IP_AFTER_REBOOT}" ]]; then
      info "Will use Tailscale IP ${SSH_HOST_AFTER_REBOOT} for post-provisioning"
    else
      info "Will use public IP ${SSH_HOST_AFTER_REBOOT} for post-provisioning"
    fi
    
    # Skip to post-provisioning phase (no reboot needed)
    # The else block below handles postinstall execution and reboot waiting
  else
    # Determine which user to use for provisioning
    PROVISION_USER="root"
    PROVISION_HOST="${EXTERNAL_IP}"
    USE_SUDO=""
    
    # Test if root SSH works
    if ! ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" 'true' 2>/dev/null; then
      # Root SSH failed, try admin user
      info "Root SSH not available, attempting to use admin user with sudo..."
      
      # First ensure we can resolve the hostname
      if ! host "${HOSTNAME}" >/dev/null 2>&1; then
        # If hostname doesn't resolve, add to /etc/hosts temporarily
        echo "${EXTERNAL_IP} ${HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null
        trap 'sudo sed -i "/^${EXTERNAL_IP} ${HOSTNAME}$/d" /etc/hosts' EXIT
      fi
      
      # Test admin access with sudo
      if ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" admin@"${HOSTNAME}" 'sudo -n true' 2>/dev/null; then
        PROVISION_USER="admin"
        PROVISION_HOST="${HOSTNAME}"
        USE_SUDO="sudo"
        
        # Ensure passwordless sudo is properly configured
        ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" admin@"${HOSTNAME}" 'echo "%sudo   ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/admin-nopasswd >/dev/null 2>&1'
        
        ok "Using admin user with passwordless sudo for provisioning"
      else
        # Try to diagnose the issue
        if ! ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" admin@"${HOSTNAME}" 'true' 2>/dev/null; then
          err "Cannot SSH as admin@${HOSTNAME}. Ensure the admin user exists and your SSH key is authorized."
        else
          err "SSH access works but passwordless sudo is not configured for admin user."
          err "Please run 'sudo visudo' on the remote host and add the following line:"
          err "%sudo   ALL=(ALL:ALL) NOPASSWD: ALL"
        fi
        exit 1
      fi
    fi
    
    # Upload unified post-install script and execute it
    POSTINSTALL_CONTENT=$(gen_postinstall)
    
    # Create Tailscale auth key via API for this host (only if not already provisioned)
    TAILSCALE_AUTHKEY=""
    if [[ "${remote_state}" == "installed" && -n "${TAILSCALE_IP}" ]]; then
      info "Machine is already provisioned and connected to Tailscale. Skipping auth key creation."
    else
      # Clean up stale Tailscale devices with the same hostname before creating a new key
      tailscale::cleanup_stale_devices "${HOSTNAME}"

      info "Using Tailscale API to create single-use auth key for ${HOSTNAME}..."
      # Create non-ephemeral, preauthorized key (servers are permanent infrastructure)
      TAILSCALE_AUTHKEY=$(tailscale::create_authkey "${HOSTNAME}" "false" "true" "" || true)
      if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
        ok "Created Tailscale single-use auth key via API"
      else
        warn "Failed to create Tailscale auth key via API"
        warn "Postinstall will proceed without automatic Tailscale authentication"
        warn "You will need to manually run 'tailscale up' on the host after provisioning"
        TAILSCALE_AUTHKEY=""
      fi
    fi
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@VLAN_IP@/${VLAN_IP}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@PUBLIC_HOSTNAME@/${HOSTNAME}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@EXTERNAL_IP@/${EXTERNAL_IP}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@TAILSCALE_IP@/${TAILSCALE_IP:-}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@MASTER_VLAN_IP@/${MASTER_VLAN_IP:-}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@WORKER_MODE@/${WORKER_MODE}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@TAILSCALE_AUTHKEY@/${TAILSCALE_AUTHKEY}}
    
    # Upload and execute postinstall script
    if [[ "$PROVISION_USER" == "root" ]]; then
      ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" "cat >/root/postinstall.sh && chmod +x /root/postinstall.sh" <<< "$POSTINSTALL_CONTENT"
      if ! ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" "export TERM=xterm; /bin/bash /root/postinstall.sh"; then
        warn "Postinstall script failed, but continuing..."
      fi
    else
      # Using admin user with sudo
      ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" admin@"${HOSTNAME}" "cat >/tmp/postinstall.sh && chmod +x /tmp/postinstall.sh" <<< "$POSTINSTALL_CONTENT"
      if ! ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" admin@"${HOSTNAME}" "export TERM=xterm; sudo /bin/bash /tmp/postinstall.sh"; then
        warn "Postinstall script failed, but continuing..."
      fi
    fi

    info "Waiting for system to reboot after follow-up..."
    # Wait for current SSH to go down
    for i in {1..30}; do
      ssh_down=false
      if [[ "$PROVISION_USER" == "root" ]]; then
        if ! ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" -o ConnectTimeout=5 root@"${EXTERNAL_IP}" 'true' >/dev/null 2>&1; then
          ssh_down=true
        fi
      else
        if ! ssh -p ${ACTIVE_SSH_PORT} "${SSH_OPTS[@]}" -o ConnectTimeout=5 admin@"${HOSTNAME}" 'true' >/dev/null 2>&1; then
          ssh_down=true
        fi
      fi
      if $ssh_down; then
        break
      fi
      sleep 2
    done
    
    # After reboot, detect Tailscale IP from API (machine should now be in Tailscale)
    info "Detecting Tailscale IP after reboot..."
    TAILSCALE_IP_AFTER_REBOOT=""
    if detect_tailscale_ip "${HOSTNAME}"; then
      TAILSCALE_IP_AFTER_REBOOT="${TAILSCALE_IP}"
      ok "Detected Tailscale IP after reboot: ${TAILSCALE_IP_AFTER_REBOOT}"
    else
      info "Tailscale IP not yet available from API"
    fi
    
    # After reboot, prefer Tailscale IP if available
    SSH_HOST_AFTER_REBOOT="${EXTERNAL_IP}"
    if [[ -n "${TAILSCALE_IP_AFTER_REBOOT}" ]]; then
      info "Attempting to use Tailscale IP ${TAILSCALE_IP_AFTER_REBOOT} after reboot..."
      if wait_for_ssh "${TAILSCALE_IP_AFTER_REBOOT}" ${SSH_PORT_FINAL} 60; then
        SSH_HOST_AFTER_REBOOT="${TAILSCALE_IP_AFTER_REBOOT}"
        ok "Using Tailscale IP for post-reboot SSH"
      else
        info "Tailscale IP not yet available, falling back to public IP ${EXTERNAL_IP}"
      fi
    fi
    
    # Wait for SSH on preferred host
    if ! wait_for_ssh "${SSH_HOST_AFTER_REBOOT}" ${SSH_PORT_FINAL} 180; then
      warn "SSH on ${SSH_HOST_AFTER_REBOOT}:${SSH_PORT_FINAL} did not become available."
      
      # If we tried Tailscale first, try public IP as fallback
      if [[ "${SSH_HOST_AFTER_REBOOT}" == "${TAILSCALE_IP}" ]]; then
        warn "Attempting public IP fallback ${EXTERNAL_IP}..."
        if wait_for_ssh "${EXTERNAL_IP}" ${SSH_PORT_FINAL} 60; then
          SSH_HOST_AFTER_REBOOT="${EXTERNAL_IP}"
          ok "Successfully connected via public IP"
        else
          warn "Could not connect via public IP either. System may still be rebooting."
        fi
      fi
    fi
    
  fi
fi

# Post-provisioning: Configure Tailscale device via API if available (runs for both new and existing installs)
if $RUN_FOLLOWUP; then
  if tailscale::read_api_token 2>/dev/null; then
    info "Waiting for device to appear in Tailscale network..."
    # Wait up to 60 seconds for device to register
    DEVICE_ID=""
    for i in {1..12}; do
      DEVICE_ID=$(tailscale::get_device_id "${HOSTNAME}" || true)
      if [[ -n "$DEVICE_ID" ]]; then
        ok "Device registered in Tailscale: ${DEVICE_ID}"
        break
      fi
      sleep 5
    done
    
    if [[ -n "$DEVICE_ID" ]]; then
      # Configure device settings (e.g., advertise VLAN subnet)
      if [[ -n "${VLAN_IP:-}" ]]; then
        # Extract subnet from VLAN_IP (e.g., 192.168.100.5/24 -> "192.168.100.0/24")
        VLAN_SUBNET=$(echo "${VLAN_IP}" | awk -F'[./]' '{printf "%d.%d.%d.0/%s\n", $1, $2, $3, $NF}')
        info "Configuring device to advertise VLAN subnet: ${VLAN_SUBNET}"
        if tailscale::configure_device "${DEVICE_ID}" "\"${VLAN_SUBNET}\""; then
          ok "Tailscale device configured to advertise ${VLAN_SUBNET}"
        else
          warn "Failed to configure subnet routes via API (non-fatal)"
        fi
      fi
    else
      warn "Device did not appear in Tailscale network within 60 seconds"
      info "You may need to manually configure the device in Tailscale admin console"
    fi
  fi
fi

# Fetch kubeconfig from remote and write local per-env file and try to merge into ~/.kube/config
function fetch_kubeconfig(){
  local host="${1:-${HOSTNAME}}" env_name="${ENV_NAME}"
  local tailscale_ip="${2:-${TAILSCALE_IP}}"
  local out_dir="${ENV_DIR}"
  mkdir -p "${out_dir}" 2>/dev/null || true
  # Try to read remote kubeconfig via admin with sudo
  set +e
  KCFG_CONTENT=$(ssh -p ${SSH_PORT_FINAL} "${SSH_OPTS[@]}" admin@"${host}" 'sudo cat /etc/rancher/k3s/k3s.yaml' 2>/dev/null)
  rc=$?
  set -e
  if [[ $rc -ne 0 || -z "${KCFG_CONTENT}" ]]; then
    warn "Could not read remote kubeconfig /etc/rancher/k3s/k3s.yaml yet. Skipping extraction for now."
    return 0
  fi
  # Adjust server to use Tailscale IP (if available) or HOSTNAME, and rename context/user/cluster names to env
  local api_server_host="${HOSTNAME}"
  if [[ -n "${tailscale_ip}" ]]; then
    api_server_host="${tailscale_ip}"
    info "Using Tailscale IP ${tailscale_ip} for kubeconfig API server"
  fi
  local adjusted
  adjusted=$(printf "%s" "${KCFG_CONTENT}" \
    | awk -v env="${env_name}" -v host="${api_server_host}" '
      {
        gsub(/server: https:\/\/127\.0\.0\.1:6443/, "server: https://" host ":6443")
      }
      /^[[:space:]]*(-[[:space:]]*)?name:[[:space:]]*default[[:space:]]*$/ { sub(/default[[:space:]]*$/, env) }
      /^[[:space:]]*cluster:[[:space:]]*default[[:space:]]*$/ { sub(/default[[:space:]]*$/, env) }
      /^[[:space:]]*user:[[:space:]]*default[[:space:]]*$/ { sub(/default[[:space:]]*$/, env) }
      /^[[:space:]]*current-context:/ { print "current-context: " env; next }
      { print }
    ')
  echo "${adjusted}" > "${out_dir}/kubeconfig.yaml"
  ok "Wrote kubeconfig to ${out_dir}/kubeconfig.yaml (context: ${env_name}, server: https://${api_server_host}:6443)"
  # Try to merge into ~/.kube/config if kubectl is available locally
  local kube_home="${HOME}/.kube"
  mkdir -p "${kube_home}"
  if command -v kubectl >/dev/null 2>&1; then
    if [[ -f "${kube_home}/config" ]]; then
      # Prefer the freshly fetched kubeconfig to override any stale entries with the same names
      KUBECONFIG="${out_dir}/kubeconfig.yaml:${kube_home}/config" kubectl config view --flatten >"${kube_home}/config.tmp" 2>/dev/null && mv "${kube_home}/config.tmp" "${kube_home}/config" && ok "Merged ${env_name} context into ${kube_home}/config (new takes precedence)" || warn "Failed to merge kubeconfig into ${kube_home}/config"
    else
      cp "${out_dir}/kubeconfig.yaml" "${kube_home}/config"
      ok "Created ${kube_home}/config with ${env_name} context"
    fi
    # Ensure kubectl uses the new context by default to avoid interactive auth prompts
    kubectl --kubeconfig "${kube_home}/config" config use-context "${env_name}" >/dev/null 2>&1 \
      && ok "Set current-context to ${env_name} in ${kube_home}/config" \
      || warn "Failed to set current-context to ${env_name} in ${kube_home}/config"
  else
    info "kubectl not found locally; skipping merge. Use: KUBECONFIG=${out_dir}/kubeconfig.yaml kubectl get nodes"
  fi
}

if $DEFAULT_RUN_ALL; then
  # Use the SSH host determined after reboot (prefers Tailscale if available)
  SSH_HOST="${SSH_HOST_AFTER_REBOOT:-${EXTERNAL_IP}}"
  if [[ "${SSH_HOST}" == "${TAILSCALE_IP_AFTER_REBOOT}" ]]; then
    info "Using Tailscale IP for post-provisioning SSH: ${SSH_HOST}"
  fi
  
  info "Waiting for admin SSH on ${SSH_HOST}:${SSH_PORT_FINAL} and collecting system info..."
  if wait_for_ssh_user "${SSH_HOST}" ${SSH_PORT_FINAL} admin 240; then
    show_system_info "${SSH_HOST}" ${SSH_PORT_FINAL}
    if $WORKER_MODE; then
      info "Worker mode detected (MASTER_VLAN_IP=${MASTER_VLAN_IP}). Validating VLAN connectivity..."
      VLAN_IP_ADDR="${VLAN_IP%/*}"
      
      # Step 1: Verify worker's VLAN interface is up
      info "Checking if VLAN interface (vlan4000) is up on worker..."
      if ! ssh -p ${SSH_PORT_FINAL} "${SSH_OPTS[@]}" admin@"${SSH_HOST}" "ip link show vlan4000 | grep -q 'state UP'" 2>/dev/null; then
        err "VLAN interface vlan4000 is not UP on worker ${HOSTNAME}"
        err "Run: ip link show vlan4000"
        exit 1
      fi
      ok "Worker VLAN interface is UP"
      
      # Step 2: Verify worker has correct VLAN IP configured
      info "Verifying worker VLAN IP configuration..."
      WORKER_VLAN_ACTUAL=$(ssh -p ${SSH_PORT_FINAL} "${SSH_OPTS[@]}" admin@"${SSH_HOST}" "ip -4 addr show vlan4000 | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}' | head -1" 2>/dev/null || true)
      if [[ "${WORKER_VLAN_ACTUAL}" != "${VLAN_IP_ADDR}" ]]; then
        err "Worker VLAN IP mismatch: expected ${VLAN_IP_ADDR}, got ${WORKER_VLAN_ACTUAL:-<none>}"
        exit 1
      fi
      ok "Worker VLAN IP correctly configured: ${VLAN_IP_ADDR}"
      
      # Step 3: Test ICMP connectivity from worker to master via VLAN
      info "Testing ICMP connectivity from worker to master via VLAN..."
      if ! ssh -p ${SSH_PORT_FINAL} "${SSH_OPTS[@]}" admin@"${SSH_HOST}" "ping -c3 -W2 -I vlan4000 ${MASTER_VLAN_IP}" >/dev/null 2>&1; then
        err "Cannot ping master ${MASTER_VLAN_IP} from worker ${HOSTNAME} via VLAN"
        err "Ensure master is provisioned with VLAN before adding workers"
        err "On master, verify: ip addr show vlan4000"
        exit 1
      fi
      ok "ICMP connectivity verified: worker → master via VLAN (${MASTER_VLAN_IP})"
      
      # Step 4: Test k3s API port (6443/tcp) connectivity from worker to master
      info "Testing k3s API port (6443/tcp) connectivity from worker to master..."
      if ! ssh -p ${SSH_PORT_FINAL} "${SSH_OPTS[@]}" admin@"${SSH_HOST}" "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/${MASTER_VLAN_IP}/6443'" 2>/dev/null; then
        err "Cannot reach k3s API port 6443 on master ${MASTER_VLAN_IP} from worker"
        err "Ensure k3s server is running on master and UFW allows port 6443 on vlan4000"
        err "On master, verify: sudo ufw status | grep 6443"
        err "On master, verify: sudo systemctl status k3s"
        exit 1
      fi
      ok "k3s API port 6443 is reachable on master via VLAN"
      
      ok "All VLAN connectivity checks passed"

      # Check if K3S_TOKEN is already provided via environment variable
      if [[ -n "${K3S_TOKEN:-}" ]]; then
        info "Using K3S_TOKEN from environment variable"
        MASTER_NODE_TOKEN="${K3S_TOKEN}"
      else
        info "Fetching master node-token from ${MASTER_HOSTNAME} ..."
        
        # Try to detect master's Tailscale IP for SSH access
        MASTER_SSH_HOST="${MASTER_HOSTNAME}"
        if tailscale::read_api_token 2>/dev/null; then
          MASTER_TAILSCALE_IP=$(tailscale::get_device_ip "${MASTER_HOSTNAME}" 2>/dev/null || true)
          if [[ -n "${MASTER_TAILSCALE_IP}" ]]; then
            info "Using master's Tailscale IP for SSH: ${MASTER_TAILSCALE_IP}"
            MASTER_SSH_HOST="${MASTER_TAILSCALE_IP}"
          fi
        fi
        
        set +e
        MASTER_NODE_TOKEN=$(ssh -p ${SSH_PORT_FINAL} "${SSH_OPTS[@]}" admin@"${MASTER_SSH_HOST}" 'sudo cat /var/lib/rancher/k3s/server/node-token' 2>/dev/null)
        rc_token=$?
        set -e
        
        if [[ $rc_token -ne 0 || -z "${MASTER_NODE_TOKEN}" ]]; then
          err "Failed to retrieve master node token from ${MASTER_SSH_HOST}"
          err ""
          err "Please retrieve the token manually and set it as an environment variable:"
          err "  1. SSH to master: ssh admin@${MASTER_HOSTNAME}"
          err "  2. Get token: sudo cat /var/lib/rancher/k3s/server/node-token"
          err "  3. Re-run with: K3S_TOKEN='<token>' tools/provision-hetzner-baremetal.sh ${ENV_NAME}"
          err ""
          err "Alternatively, ensure you can SSH to the master from this machine:"
          err "  ssh -p ${SSH_PORT_FINAL} admin@${MASTER_SSH_HOST}"
          exit 1
        fi
        ok "Retrieved master node token"
      fi

      info "Installing k3s agent on worker ${HOSTNAME} ..."
      set +e
      ssh -p ${SSH_PORT_FINAL} "${SSH_OPTS[@]}" admin@"${SSH_HOST}" bash -s <<AGENT
set -euo pipefail
export K3S_URL="https://${MASTER_VLAN_IP}:6443"
export K3S_TOKEN="${MASTER_NODE_TOKEN}"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent \
  --node-ip ${VLAN_IP_ADDR} \
  --node-external-ip ${EXTERNAL_IP}" sh -

# Check if k3s-agent service started successfully
if ! systemctl is-active --quiet k3s-agent; then
  echo "[ERROR] k3s-agent service failed to start"
  echo "[INFO] Service status:"
  systemctl status k3s-agent --no-pager || true
  echo ""
  echo "[INFO] Recent logs:"
  journalctl -u k3s-agent -n 50 --no-pager || true
  exit 1
fi
AGENT
      agent_rc=$?
      set -e
      
      if [[ $agent_rc -ne 0 ]]; then
        err "k3s agent installation failed on ${HOSTNAME}"
        err ""
        err "To diagnose the issue, SSH to the worker and check:"
        err "  ssh admin@${SSH_HOST}"
        err "  sudo systemctl status k3s-agent"
        err "  sudo journalctl -u k3s-agent -n 100"
        err ""
        err "Common issues:"
        err "  - Master k3s API not reachable via VLAN (check UFW on master)"
        err "  - Invalid node token (verify token is current)"
        err "  - VLAN connectivity issues (ping master from worker)"
        exit 1
      fi
      ok "k3s agent installation triggered on ${HOSTNAME}"

      info "Validating node registration on master ${MASTER_HOSTNAME} ..."
      # Prefer k3s kubectl on master to avoid dependency on kubectl binary
      # Use MASTER_SSH_HOST if it was set earlier (Tailscale IP)
      VALIDATION_HOST="${MASTER_SSH_HOST:-${MASTER_HOSTNAME}}"
      if ssh -p ${SSH_PORT_FINAL} "${SSH_OPTS[@]}" admin@"${VALIDATION_HOST}" 'sudo k3s kubectl get nodes -o wide' 2>/dev/null; then
        ok "Node validation successful"
      else
        warn "kubectl query on master failed; verify manually with:"
        warn "  ssh admin@${MASTER_HOSTNAME} 'sudo k3s kubectl get nodes -o wide'"
      fi
    else
      # Attempt to extract kubeconfig now that the system is up (master case)
      fetch_kubeconfig "${SSH_HOST}" "${TAILSCALE_IP}"
    fi
  else
    warn "admin@${SSH_HOST}:${SSH_PORT_FINAL} is not reachable yet."
  fi
fi

ok "Provisioning steps completed for ${ENV_NAME} (${EXTERNAL_IP})"
