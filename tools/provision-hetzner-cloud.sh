#!/usr/bin/env bash
# Hetzner Cloud provisioning helper
#
# This script provisions K3s servers on Hetzner Cloud VMs via API.
# It handles the full lifecycle: server creation, cloud-init, DNS, Tailscale,
# postinstall, and worker node support.
#
# Usage:
#   tools/provision-hetzner-cloud.sh <env-name> [flags]
#
# Flags:
#   --ssh-key PATH          SSH key path (default: ~/.ssh/id_ed25519)
#   --create-server         Create server only (skip provisioning)
#   --provision-only        Provision existing server (skip creation)
#   --skip-diagnose         Skip pre-flight checks
#   --skip-dns              Skip Cloudflare DNS setup
#   --skip-tailscale        Skip Tailscale setup
#   --destroy               Tear down server (with confirmation)
#   --debug                 Verbose logging
#
# Environment file expected at: envs/<env>/env.properties with variables:
#   HOSTNAME=example.domain.tld
#   ACME_EMAIL=admin@example.com
#   HCLOUD_SERVER_TYPE=cpx31         # Hetzner Cloud server type
#   HCLOUD_LOCATION=fsn1             # Datacenter (fsn1, nbg1, hel1)
#   HCLOUD_IMAGE=ubuntu-24.04        # OS image
#   HCLOUD_NETWORK_ZONE=eu-central   # For private network
#   PRIVATE_IP=10.0.0.2/16           # Private network IP
#   # Optional: worker mode
#   # MASTER_PRIVATE_IP=10.0.0.1
#   # MASTER_HOSTNAME=master.example.domain.tld
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
${BLUE}Hetzner Cloud provisioning${NC}
Usage: $0 <env-name> [--ssh-key PATH] [--create-server] [--provision-only] [--skip-diagnose] [--skip-dns] [--skip-tailscale] [--destroy] [--debug]

Examples:
  $0 cloud-test --ssh-key ~/.ssh/id_ed25519
  $0 cloud-test --create-server           # Create server only
  $0 cloud-test --provision-only           # Provision existing server
  $0 cloud-test --destroy                  # Tear down server

Environment file expected at: envs/<env>/env.properties with variables:
  HOSTNAME=example.domain.tld
  ACME_EMAIL=admin@example.com
  HCLOUD_SERVER_TYPE=cax11         # Hetzner Cloud server type (default: cax11)
  HCLOUD_LOCATION=hel1             # Datacenter (default: hel1)
  HCLOUD_IMAGE=ubuntu-24.04        # OS image (default: ubuntu-24.04)
  HCLOUD_NETWORK_ZONE=eu-central   # For private network (default: eu-central)
  PRIVATE_IP=10.0.0.2/16           # Private network IP
  # Optional: worker mode
  # MASTER_PRIVATE_IP=10.0.0.1
  # MASTER_HOSTNAME=master.example.domain.tld
USAGE
}

function info(){ echo -e "${BLUE}[INFO]${NC} $*" >&2; }
function ok(){ echo -e "${GREEN}[OK]${NC} $*" >&2; }
function warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
function err(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }
function debug(){ $DEBUG && echo -e "${YELLOW}[DEBUG]${NC} $*" >&2 || true; }
function dbg(){ if $DEBUG; then echo -e "${YELLOW}[DEBUG]${NC} $*" >&2; fi }

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

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
CREATE_SERVER=true
PROVISION_SERVER=true
SKIP_DIAGNOSE=false
SKIP_DNS=false
SKIP_TAILSCALE=false
DESTROY=false
DEBUG=false

# Default behavior: run everything unless specifically limited
DEFAULT_RUN_ALL=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-key)
      SSH_KEY="$2"; shift 2;;
    --create-server)
      CREATE_SERVER=true; PROVISION_SERVER=false; DEFAULT_RUN_ALL=false; shift;;
    --provision-only)
      CREATE_SERVER=false; PROVISION_SERVER=true; DEFAULT_RUN_ALL=false; shift;;
    --skip-diagnose)
      SKIP_DIAGNOSE=true; shift;;
    --skip-dns)
      SKIP_DNS=true; shift;;
    --skip-tailscale)
      SKIP_TAILSCALE=true; shift;;
    --destroy)
      DESTROY=true; shift;;
    --debug)
      DEBUG=true; shift;;
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

# Defaults for cloud-specific properties
HCLOUD_SERVER_TYPE="${HCLOUD_SERVER_TYPE:-cax11}"
HCLOUD_LOCATION="${HCLOUD_LOCATION:-hel1}"
HCLOUD_IMAGE="${HCLOUD_IMAGE:-ubuntu-24.04}"
HCLOUD_NETWORK_ZONE="${HCLOUD_NETWORK_ZONE:-eu-central}"

# Validate required properties
REQUIRED=(HOSTNAME PRIVATE_IP)
for v in "${REQUIRED[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo -e "${RED}Missing required variable ${v} in ${ENV_FILE}${NC}"; exit 1
  fi
done

# Ensure PRIVATE_IP has CIDR notation
if [[ "${PRIVATE_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  PRIVATE_IP="${PRIVATE_IP}/16"
fi
PRIVATE_IP_ADDR="${PRIVATE_IP%/*}"

# Determine if this node should join an existing master as a worker
WORKER_MODE=false
if [[ -n "${MASTER_PRIVATE_IP:-}" ]]; then
  WORKER_MODE=true
  if [[ -z "${MASTER_HOSTNAME:-}" ]]; then
    echo -e "${RED}MASTER_PRIVATE_IP is set but MASTER_HOSTNAME is missing in ${ENV_FILE}${NC}"; exit 1
  fi
fi

# Derive server name from env name (Hetzner Cloud server names)
HCLOUD_SERVER_NAME="${ENV_NAME}"

# Network name derived from hostname base domain
HCLOUD_NETWORK_NAME="lh-network"

SSH_PORT=22

SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=${HOME}/.ssh/known_hosts
  -o ConnectTimeout=10
)
[[ -n "${SSH_KEY}" ]] && SSH_OPTS+=(-i "${SSH_KEY}")

# Determine SSH key for cloud-init
if [[ -n "${SSH_KEY}" ]]; then
  PROV_SSH_KEY="${SSH_KEY}"
  PROV_SSH_PUB="${SSH_KEY}.pub"
else
  PROV_SSH_KEY=$(provision::default_ssh_key_base) || { err "No SSH key found"; exit 1; }
  PROV_SSH_PUB="${PROV_SSH_KEY}.pub"
fi
if [[ ! -f "${PROV_SSH_PUB}" ]]; then
  err "SSH public key not found: ${PROV_SSH_PUB}"
  exit 1
fi
SSH_PUBKEY_CONTENT=$(cat "${PROV_SSH_PUB}")

# ============================================================================
# Hetzner Cloud API functions
# ============================================================================

function hcloud::read_token(){
  local token_file="${ENV_ROOT}/shared/secrets.plain/hetzner-cloud-token.txt"
  if [[ ! -f "$token_file" ]]; then
    err "Hetzner Cloud API token not found: $token_file"
    err ""
    err "Create this file with your Hetzner Cloud API token:"
    err "  1. Go to https://console.hetzner.cloud → Project → Security → API Tokens"
    err "  2. Create a Read/Write token"
    err "  3. Save it to: $token_file"
    err "  4. Encrypt with: tools/sops/encrypt.sh shared hetzner-cloud-token.txt"
    return 1
  fi
  HCLOUD_TOKEN=$(tr -d '\n\r' < "$token_file" | xargs)
  if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
    err "Hetzner Cloud API token file is empty: $token_file"
    return 1
  fi
  [[ -n "${HCLOUD_TOKEN:-}" ]]
}

# Curl wrapper for Hetzner Cloud API
# Usage: hcloud::api METHOD PATH [curl-args...]
function hcloud::api(){
  local method="$1" path="$2"; shift 2
  local url="https://api.hetzner.cloud/v1${path}"
  dbg "HCLOUD ${method} ${url}"

  local response http body
  response=$(curl -sS -X "$method" "$url" \
    -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@" -w "\n%{http_code}" 2>&1)
  local curl_rc=$?

  if [[ $curl_rc -ne 0 ]]; then
    err "HCLOUD curl failed with exit code $curl_rc"
    HCLOUD_LAST_HTTP="000"
    HCLOUD_LAST_BODY="curl error: $response"
    return 22
  fi

  http=$(printf "%s" "$response" | tail -n1)
  body=$(printf "%s\n" "$response" | sed '$d')
  HCLOUD_LAST_HTTP="$http"
  HCLOUD_LAST_BODY="$body"

  dbg "HCLOUD status=${http}"
  if [[ ${#body} -lt 500 ]]; then
    dbg "HCLOUD response: ${body}"
  else
    dbg "HCLOUD response (truncated): ${body:0:500}..."
  fi

  if [[ "$http" =~ ^2[0-9][0-9]$ ]]; then
    printf "%s" "$body"
    return 0
  else
    dbg "HCLOUD API error: HTTP ${http}, body: ${body}"
    return 22
  fi
}

# Get server by name
# Returns server JSON or empty string
function hcloud::get_server(){
  local name="$1"
  local out
  out=$(hcloud::api GET "/servers?name=${name}" 2>/dev/null) || return 1
  local server
  server=$(printf '%s' "$out" | jq -r '.servers[0] // empty' 2>/dev/null)
  if [[ -n "$server" && "$server" != "null" ]]; then
    printf '%s' "$server"
    return 0
  fi
  return 1
}

# Register SSH public key (idempotent)
# Returns key ID
function hcloud::create_ssh_key(){
  local name="$1" pubkey="$2"
  # Check if key already exists by name
  local out existing_id
  out=$(hcloud::api GET "/ssh_keys?name=${name}" 2>/dev/null) || true
  existing_id=$(printf '%s' "$out" | jq -r '.ssh_keys[0].id // empty' 2>/dev/null)
  if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
    dbg "SSH key '${name}' already exists with ID ${existing_id}"
    echo "$existing_id"
    return 0
  fi
  # Create new key
  local create_out
  create_out=$(hcloud::api POST "/ssh_keys" \
    -d "{\"name\":\"${name}\",\"public_key\":\"${pubkey}\"}" 2>/dev/null) || {
    # Key might exist with different name but same fingerprint
    local error_code
    error_code=$(printf '%s' "${HCLOUD_LAST_BODY}" | jq -r '.error.code // empty' 2>/dev/null)
    if [[ "$error_code" == "uniqueness_error" ]]; then
      # Find key by fingerprint
      local fp_out all_keys
      all_keys=$(hcloud::api GET "/ssh_keys" 2>/dev/null) || return 1
      existing_id=$(printf '%s' "$all_keys" | jq -r ".ssh_keys[] | select(.public_key == \"${pubkey}\") | .id" 2>/dev/null | head -1)
      if [[ -n "$existing_id" ]]; then
        dbg "SSH key already exists with different name, ID ${existing_id}"
        echo "$existing_id"
        return 0
      fi
    fi
    err "Failed to create SSH key"
    return 1
  }
  local key_id
  key_id=$(printf '%s' "$create_out" | jq -r '.ssh_key.id' 2>/dev/null)
  ok "Registered SSH key '${name}' (ID: ${key_id})"
  echo "$key_id"
}

# Ensure Cloud Network exists and return its ID
# Creates network + subnet if not existing
function hcloud::ensure_network(){
  local name="$1" network_zone="$2" ip_range="$3"
  # Check if network exists
  local out existing_id
  out=$(hcloud::api GET "/networks?name=${name}" 2>/dev/null) || return 1
  existing_id=$(printf '%s' "$out" | jq -r '.networks[0].id // empty' 2>/dev/null)
  if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
    dbg "Network '${name}' already exists with ID ${existing_id}"
    echo "$existing_id"
    return 0
  fi
  # Create network
  info "Creating Hetzner Cloud Network '${name}' (${ip_range})..."
  local create_out
  create_out=$(hcloud::api POST "/networks" \
    -d "{\"name\":\"${name}\",\"ip_range\":\"${ip_range}\"}" 2>/dev/null) || {
    err "Failed to create network '${name}'"
    return 1
  }
  local network_id
  network_id=$(printf '%s' "$create_out" | jq -r '.network.id' 2>/dev/null)
  ok "Created network '${name}' (ID: ${network_id})"

  # Create subnet
  info "Creating subnet in network ${network_id}..."
  hcloud::api POST "/networks/${network_id}/actions/add_subnet" \
    -d "{\"type\":\"cloud\",\"network_zone\":\"${network_zone}\",\"ip_range\":\"${ip_range}\"}" >/dev/null 2>&1 || {
    err "Failed to create subnet in network '${name}'"
    return 1
  }
  ok "Created subnet ${ip_range} in network '${name}'"

  echo "$network_id"
}

# Attach server to network with static IP
function hcloud::attach_to_network(){
  local server_id="$1" network_id="$2" ip="$3"
  info "Attaching server ${server_id} to network ${network_id} with IP ${ip}..."

  # Check if already attached
  local server_out
  server_out=$(hcloud::api GET "/servers/${server_id}" 2>/dev/null) || return 1
  local attached_network
  attached_network=$(printf '%s' "$server_out" | jq -r ".server.private_net[] | select(.network == ${network_id}) | .ip // empty" 2>/dev/null)
  if [[ -n "$attached_network" ]]; then
    ok "Server already attached to network with IP ${attached_network}"
    return 0
  fi

  set +e
  local attach_out
  attach_out=$(hcloud::api POST "/servers/${server_id}/actions/attach_to_network" \
    -d "{\"network\":${network_id},\"ip\":\"${ip}\"}")
  local attach_rc=$?
  set -e
  if [[ $attach_rc -ne 0 ]]; then
    err "Failed to attach server to network"
    err "API response: ${HCLOUD_LAST_BODY:-no response}"
    return 1
  fi
  ok "Attached server to network with IP ${ip}"
}

# Create a server via Hetzner Cloud API
function hcloud::create_server(){
  local name="$1" server_type="$2" image="$3" location="$4" ssh_key_id="$5" user_data="$6"

  info "Creating Hetzner Cloud server '${name}' (${server_type} in ${location})..."

  # Build request body
  local request_body
  request_body=$(jq -n \
    --arg name "$name" \
    --arg server_type "$server_type" \
    --arg image "$image" \
    --arg location "$location" \
    --argjson ssh_keys "[${ssh_key_id}]" \
    --arg user_data "$user_data" \
    '{
      name: $name,
      server_type: $server_type,
      image: $image,
      location: $location,
      ssh_keys: $ssh_keys,
      user_data: $user_data,
      start_after_create: true
    }') || {
    err "Failed to build server creation request JSON"
    return 1
  }
  dbg "Server creation request body (truncated): ${request_body:0:200}..."

  local create_out
  set +e
  create_out=$(hcloud::api POST "/servers" -d "$request_body")
  local create_rc=$?
  set -e
  if [[ $create_rc -ne 0 ]]; then
    err "Failed to create server '${name}'"
    err "API response: ${HCLOUD_LAST_BODY:-no response}"
    return 1
  fi

  local server_id public_ip
  server_id=$(printf '%s' "$create_out" | jq -r '.server.id' 2>/dev/null)
  public_ip=$(printf '%s' "$create_out" | jq -r '.server.public_net.ipv4.ip' 2>/dev/null)

  ok "Created server '${name}' (ID: ${server_id}, IP: ${public_ip})"
  HCLOUD_SERVER_ID="$server_id"
  HCLOUD_PUBLIC_IP="$public_ip"
}

# Wait for server action to complete
function hcloud::wait_for_action(){
  local action_id="$1" timeout="${2:-120}"
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local out status
    out=$(hcloud::api GET "/actions/${action_id}" 2>/dev/null) || true
    status=$(printf '%s' "$out" | jq -r '.action.status // empty' 2>/dev/null)
    if [[ "$status" == "success" ]]; then
      return 0
    elif [[ "$status" == "error" ]]; then
      err "Action ${action_id} failed"
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  err "Action ${action_id} timed out after ${timeout}s"
  return 1
}

# Wait for server to have status "running"
function hcloud::wait_for_running(){
  local server_id="$1" timeout="${2:-120}"
  info "Waiting for server ${server_id} to be running..."
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local out status
    out=$(hcloud::api GET "/servers/${server_id}" 2>/dev/null) || true
    status=$(printf '%s' "$out" | jq -r '.server.status // empty' 2>/dev/null)
    if [[ "$status" == "running" ]]; then
      ok "Server is running"
      return 0
    fi
    dbg "Server status: ${status}"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  err "Server did not become running within ${timeout}s"
  return 1
}

# Delete server
function hcloud::delete_server(){
  local server_id="$1"
  info "Deleting server ${server_id}..."
  hcloud::api DELETE "/servers/${server_id}" >/dev/null 2>&1 || {
    err "Failed to delete server ${server_id}"
    return 1
  }
  ok "Server ${server_id} deleted"
}

# Set reverse DNS on server's primary IPv4
function hcloud::set_rdns(){
  local server_id="$1" ip="$2" hostname="$3"
  info "Setting reverse DNS for ${ip} -> ${hostname}..."
  hcloud::api POST "/servers/${server_id}/actions/change_dns_ptr" \
    -d "{\"ip\":\"${ip}\",\"dns_ptr\":\"${hostname}\"}" >/dev/null 2>&1 || {
    warn "Failed to set reverse DNS (non-fatal)"
    return 0
  }
  ok "Reverse DNS set: ${ip} -> ${hostname}"
}

# ============================================================================
# Tailscale API functions (same pattern as baremetal script)
# ============================================================================

function tailscale::read_api_token(){
  local ts_file="${ENV_ROOT}/shared/secrets.plain/tailscale-api-key.txt"
  if [[ ! -f "$ts_file" ]]; then
    return 1
  fi
  dbg "Reading Tailscale API token from: $ts_file"
  TS_API_TOKEN=$(tr -d '\n\r' < "$ts_file" | xargs)
  [[ -n "${TS_API_TOKEN:-}" ]]
}

function tailscale::api(){
  local method="$1" path="$2"; shift 2
  local url="https://api.tailscale.com/api/v2${path}"
  dbg "TAILSCALE ${method} ${url}"

  local response http body
  response=$(curl -sS -u "${TS_API_TOKEN}:" -X "$method" \
    -H 'Content-Type: application/json' \
    "$url" "$@" -w "\n%{http_code}" 2>&1)
  local curl_rc=$?

  if [[ $curl_rc -ne 0 ]]; then
    err "TAILSCALE curl failed with exit code $curl_rc"
    TS_LAST_HTTP="000"
    TS_LAST_BODY="curl error: $response"
    return 22
  fi

  http=$(printf "%s" "$response" | tail -n1)
  body=$(printf "%s\n" "$response" | sed '$d')
  TS_LAST_HTTP="$http"
  TS_LAST_BODY="$body"
  dbg "TAILSCALE status=${http}"

  if [[ "$http" =~ ^2[0-9][0-9]$ ]]; then
    printf "%s" "$body"
    return 0
  else
    dbg "TAILSCALE API error: HTTP ${http}, body: ${body}"
    return 22
  fi
}

function tailscale::get_tailnet(){
  local out
  out=$(tailscale::api GET "/tailnet" 2>/dev/null || true)
  if [[ -n "$out" ]] && command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r '.name // empty' 2>/dev/null | head -1
  else
    echo "-"
  fi
}

function tailscale::create_authkey(){
  local hostname="$1"
  local ephemeral="${2:-false}"
  local preauthorized="${3:-true}"

  info "Creating Tailscale auth key for ${hostname}..."

  local tailnet
  tailnet=$(tailscale::get_tailnet)
  [[ -z "$tailnet" || "$tailnet" == "tailnet" ]] && tailnet="-"

  local safe_hostname
  safe_hostname=$(printf '%s' "$hostname" | tr '.' '-' | tr -cd 'A-Za-z0-9-_')

  local json_data
  json_data=$(cat <<JSON
{
  "capabilities": {
    "devices": {
      "create": {
        "reusable": false,
        "ephemeral": ${ephemeral},
        "preauthorized": ${preauthorized},
        "tags": []
      }
    }
  },
  "expirySeconds": 3600,
  "description": "Provisioning for ${safe_hostname}"
}
JSON
)

  local out http body
  out=$(curl -sS -u "${TS_API_TOKEN}:" -X POST \
    -H 'Content-Type: application/json' \
    "https://api.tailscale.com/api/v2/tailnet/${tailnet}/keys" \
    -d "${json_data}" -w "\n%{http_code}" 2>&1)
  local rc=$?

  if [[ $rc -ne 0 ]]; then
    err "Tailscale API curl failed with exit code $rc"
    return 1
  fi

  http=$(printf "%s" "$out" | tail -n1)
  body=$(printf "%s\n" "$out" | sed '$d')

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
  return 1
}

function tailscale::get_device_id(){
  local hostname="$1"
  local tailnet
  tailnet=$(tailscale::get_tailnet)
  [[ -z "$tailnet" || "$tailnet" == "tailnet" ]] && tailnet="-"

  local out
  out=$(tailscale::api GET "/tailnet/${tailnet}/devices" 2>/dev/null || true)
  if [[ -n "$out" ]] && command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r ".devices[] | select(.hostname == \"${hostname}\") | .id" 2>/dev/null | head -1
  fi
}

function tailscale::get_device_ip(){
  local hostname="$1"
  local tailnet
  tailnet=$(tailscale::get_tailnet)
  [[ -z "$tailnet" || "$tailnet" == "tailnet" ]] && tailnet="-"

  local out
  out=$(tailscale::api GET "/tailnet/${tailnet}/devices" 2>/dev/null || true)
  if [[ -n "$out" ]] && command -v jq >/dev/null 2>&1; then
    printf '%s' "$out" | jq -r ".devices[] | select(.hostname == \"$hostname\") | .addresses[] | select(startswith(\"100.\")) | select(contains(\":\") | not)" 2>/dev/null | head -1
  fi
}

function tailscale::delete_device(){
  local device_id="$1"
  info "Deleting Tailscale device ${device_id}..."
  tailscale::api DELETE "/device/${device_id}" >/dev/null 2>&1 || {
    warn "Failed to delete Tailscale device ${device_id}"
    return 1
  }
  ok "Deleted Tailscale device ${device_id}"
}

function tailscale::cleanup_stale_devices(){
  local hostname="$1"
  if ! tailscale::read_api_token 2>/dev/null; then
    return 0
  fi
  local tailnet
  tailnet=$(tailscale::get_tailnet)
  [[ -z "$tailnet" || "$tailnet" == "tailnet" ]] && tailnet="-"

  local out device_ids
  out=$(tailscale::api GET "/tailnet/${tailnet}/devices" 2>/dev/null || true)
  [[ -z "$out" ]] && return 0
  device_ids=$(printf '%s' "$out" | jq -r ".devices[] | select(.hostname == \"${hostname}\") | .id" 2>/dev/null || true)
  [[ -z "$device_ids" ]] && return 0
  info "Cleaning up stale Tailscale devices for ${hostname}..."
  while IFS= read -r did; do
    [[ -n "$did" ]] && tailscale::delete_device "$did" || true
  done <<< "$device_ids"
}

# ============================================================================
# Cloudflare DNS functions (reuse from baremetal pattern)
# ============================================================================

function cloudflare::read_token(){
  local cf_file="${ENV_ROOT}/shared/secrets.plain/cloudflare.yaml"
  if [[ ! -f "$cf_file" ]]; then
    return 1
  fi
  CF_API_TOKEN=$(grep -iE '^[[:space:]]*(cloudflare[-_]?api[-_]?token|api[-_]?token|token|api[-_]?key)[[:space:]]*:[[:space:]]*' "$cf_file" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)
  if [[ -z "${CF_API_TOKEN:-}" || "${CF_API_TOKEN}" == "cloudflare-api-token" ]]; then
    CF_API_TOKEN=$(grep -oE '[A-Za-z0-9_-]{32,}' "$cf_file" | head -1)
  fi
  [[ -n "${CF_API_TOKEN:-}" && "${CF_API_TOKEN}" != "cloudflare-api-token" ]]
}

function cloudflare::api(){
  local method="$1" path="$2"; shift 2
  local url="https://api.cloudflare.com/client/v4${path}"
  dbg "CLOUDFLARE ${method} ${url}"
  curl -sS -X "$method" "$url" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@"
}

function cloudflare::create_or_update_dns_record(){
  local zone_id="$1" name="$2" ip="$3"

  info "Checking DNS record: ${name} -> ${ip}"
  local existing record_id
  existing=$(cloudflare::api GET "/zones/${zone_id}/dns_records?type=A&name=${name}" 2>/dev/null)
  record_id=$(printf '%s' "$existing" | jq -r '.result[0].id // empty' 2>/dev/null)

  if [[ -n "$record_id" && "$record_id" != "null" ]]; then
    local current_ip
    current_ip=$(printf '%s' "$existing" | jq -r '.result[0].content // empty' 2>/dev/null)
    if [[ "$current_ip" == "$ip" ]]; then
      ok "DNS record already correct: ${name} -> ${ip}"
      return 0
    fi
    info "Updating DNS record: ${name} from ${current_ip} to ${ip}"
    local update_response
    update_response=$(cloudflare::api PUT "/zones/${zone_id}/dns_records/${record_id}" \
      -d "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}" 2>/dev/null)
    if printf '%s' "$update_response" | jq -e '.success == true' >/dev/null 2>&1; then
      ok "Updated DNS record: ${name} -> ${ip}"
      return 0
    fi
    err "Failed to update DNS record: ${name}"
    return 1
  fi

  info "Creating DNS record: ${name} -> ${ip}"
  local create_response
  create_response=$(cloudflare::api POST "/zones/${zone_id}/dns_records" \
    -d "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}" 2>/dev/null)
  if printf '%s' "$create_response" | jq -e '.success == true' >/dev/null 2>&1; then
    ok "Created DNS record: ${name} -> ${ip}"
    return 0
  fi
  err "Failed to create DNS record: ${name}"
  return 1
}

function cloudflare::delete_dns_record(){
  local zone_id="$1" name="$2"
  local existing record_id
  existing=$(cloudflare::api GET "/zones/${zone_id}/dns_records?type=A&name=${name}" 2>/dev/null)
  record_id=$(printf '%s' "$existing" | jq -r '.result[0].id // empty' 2>/dev/null)
  if [[ -n "$record_id" && "$record_id" != "null" ]]; then
    cloudflare::api DELETE "/zones/${zone_id}/dns_records/${record_id}" >/dev/null 2>&1 || {
      warn "Failed to delete DNS record: ${name}"
      return 1
    }
    ok "Deleted DNS record: ${name}"
  else
    debug "DNS record not found: ${name} (nothing to delete)"
  fi
}

function dns::cleanup_cloudflare(){
  if ! cloudflare::read_token; then
    warn "Cloudflare API token not found (skipping DNS cleanup)"
    return 0
  fi
  local base_domain
  base_domain=$(printf '%s' "$HOSTNAME" | awk -F. '{if (NF>=2){print $(NF-1)"."$NF}else{print $0}}')
  local zones_response zone_id
  zones_response=$(cloudflare::api GET "/zones?name=${base_domain}" 2>/dev/null)
  zone_id=$(printf '%s' "$zones_response" | jq -r '.result[0].id // empty' 2>/dev/null)
  if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
    warn "Cloudflare zone not found for domain: $base_domain (skipping DNS cleanup)"
    return 0
  fi
  cloudflare::delete_dns_record "$zone_id" "$HOSTNAME" || true
  cloudflare::delete_dns_record "$zone_id" "*.${HOSTNAME}" || true
  ok "DNS records cleaned up from Cloudflare"
}

function dns::setup_cloudflare(){
  local target_ip="$1"
  if ! cloudflare::read_token; then
    warn "Cloudflare API token not found (skipping DNS setup)"
    return 0
  fi

  local base_domain
  base_domain=$(printf '%s' "$HOSTNAME" | awk -F. '{if (NF>=2){print $(NF-1)"."$NF}else{print $0}}')

  local zones_response zone_id
  zones_response=$(cloudflare::api GET "/zones?name=${base_domain}" 2>/dev/null)
  zone_id=$(printf '%s' "$zones_response" | jq -r '.result[0].id // empty' 2>/dev/null)

  if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
    err "Cloudflare zone not found for domain: $base_domain"
    return 1
  fi
  ok "Found Cloudflare zone for ${base_domain}"

  # A record for HOSTNAME
  cloudflare::create_or_update_dns_record "$zone_id" "$HOSTNAME" "$target_ip" || return 1
  # Wildcard A record
  cloudflare::create_or_update_dns_record "$zone_id" "*.${HOSTNAME}" "$target_ip" || return 1
  ok "DNS records configured in Cloudflare"
}

# ============================================================================
# SSH helpers
# ============================================================================

function cleanup_known_hosts(){
  if [[ -n "${HCLOUD_PUBLIC_IP:-}" ]]; then
    ssh-keygen -R "${HCLOUD_PUBLIC_IP}" 2>/dev/null || true
  fi
  ssh-keygen -R "${HOSTNAME}" 2>/dev/null || true
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
  return 1
}

# ============================================================================
# Cloud-init user-data generation
# ============================================================================

function gen_cloud_init(){
  local ssh_pubkey="$1"
  cat <<CLOUDINIT_EOF
#cloud-config
package_update: true
packages:
  - curl
  - jq
users:
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${ssh_pubkey}
    shell: /bin/bash
  - name: root
    ssh_authorized_keys:
      - ${ssh_pubkey}
CLOUDINIT_EOF
}

# ============================================================================
# Postinstall script generation (cloud-adapted from baremetal)
# ============================================================================

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

mark_step() {
  local step_name="$1"
  touch "$MARKER_DIR/$step_name" || true
  echo "[postinstall] ✓ Marked step complete: $step_name"
}

is_step_done() {
  local step_name="$1"
  [[ -f "$MARKER_DIR/$step_name" ]]
}

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

echo "[postinstall] Starting postinstall provisioning (Hetzner Cloud)..."
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

# Step 2: Update apt and install packages (no vlan package needed for cloud)
if skip_if_done "02-apt-update-packages" "APT update and package installation"; then
  :
else
  echo "[postinstall] Updating apt cache ..."
  apt update && apt -y dist-upgrade && apt -y autoremove

  echo "[postinstall] Installing base packages ..."
  apt install -y --install-recommends linux-generic-hwe-24.04 \
    locales ufw git binutils make \
    libcurl4-openssl-dev libsqlite3-dev curl \
    apt-transport-https gnupg2 sudo kubetail tailscale
  mark_step "02-apt-update-packages"
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

# Step 5: Configure UFW rules (using Cloud Network interface instead of vlan4000)
if skip_if_done "05-ufw-rules" "UFW rules configuration"; then
  :
else
  echo "[postinstall] Preparing UFW rules ..."

  # Auto-detect the Cloud Network interface by finding which interface has our private IP
  CLOUD_NET_IFACE=""
  CLOUD_NET_IFACE=$(ip -o addr show | grep "@PRIVATE_IP_ADDR@" | awk '{print $2}' | head -1 || true)
  if [[ -z "$CLOUD_NET_IFACE" ]]; then
    # Fallback: find any non-lo, non-tailscale, non-eth0 interface in 10.x range
    CLOUD_NET_IFACE=$(ip -o addr show | grep 'inet 10\.' | grep -v ' lo ' | awk '{print $2}' | head -1 || true)
  fi
  if [[ -z "$CLOUD_NET_IFACE" ]]; then
    echo "[postinstall] WARNING: Could not detect Cloud Network interface, defaulting to enp7s0"
    CLOUD_NET_IFACE="enp7s0"
  fi
  echo "[postinstall] Detected Cloud Network interface: $CLOUD_NET_IFACE"
  # Persist for later steps
  echo "$CLOUD_NET_IFACE" > /etc/infra-postinstall.d/cloud-net-iface

  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true

  # HTTPS from Internet
  ufw allow 443/tcp comment 'https' >/dev/null 2>&1 || true
  ufw deny 80/tcp comment 'deny http' >/dev/null 2>&1 || true

  # SSH via Tailscale and Cloud Network
  ufw allow in on tailscale0 to any port 22 proto tcp comment 'ssh via tailscale' >/dev/null 2>&1 || true
  ufw allow in on "$CLOUD_NET_IFACE" to any port 22 proto tcp comment 'ssh via cloud network' >/dev/null 2>&1 || true

  # Allow all traffic on Tailscale interface
  ufw allow in on tailscale0 comment 'allow all via tailscale' >/dev/null 2>&1 || true

  # K3s internal networks
  ufw allow from 10.42.0.0/16 to any comment 'k3s pods' >/dev/null 2>&1 || true
  ufw allow from 10.43.0.0/16 to any comment 'k3s services' >/dev/null 2>&1 || true

  # k3s/Flannel specifics
  ufw allow in on cni0 comment 'k3s cni0' >/dev/null 2>&1 || true
  ufw allow in on flannel.1 comment 'flannel overlay' >/dev/null 2>&1 || true
  ufw allow from 10.42.0.0/16 to any port 10250 proto tcp comment 'kubelet' >/dev/null 2>&1 || true

  # Kubernetes API on Cloud Network only
  ufw allow in on "$CLOUD_NET_IFACE" to any port 6443 proto tcp comment 'k8s api on cloud network' >/dev/null 2>&1 || true

  # Enable forwarding for Kubernetes networking
  if grep -q '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw 2>/dev/null; then
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
  else
    echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> /etc/default/ufw
  fi

  echo "[postinstall] UFW rules configured (not enabled yet):"
  ufw status verbose || true
  mark_step "05-ufw-rules"
fi

# Step 6: Skip VLAN 8021q module (not needed for Hetzner Cloud)
mark_step "06-vlan-8021q"

# Step 7: Validate Cloud Network interface (instead of VLAN 4000 setup)
if skip_if_done "07-cloud-network" "Cloud Network interface validation"; then
  :
else
  echo "[postinstall] Validating Cloud Network interface ..."
  # Read the detected interface from step 5, or re-detect
  if [[ -f /etc/infra-postinstall.d/cloud-net-iface ]]; then
    CLOUD_NET_IFACE=$(cat /etc/infra-postinstall.d/cloud-net-iface)
  else
    CLOUD_NET_IFACE=$(ip -o addr show | grep "@PRIVATE_IP_ADDR@" | awk '{print $2}' | head -1 || true)
  fi
  # Wait up to 30 seconds for the interface to appear
  for i in {1..30}; do
    if [[ -n "$CLOUD_NET_IFACE" ]] && ip link show "$CLOUD_NET_IFACE" >/dev/null 2>&1; then
      echo "[postinstall] Cloud Network interface ($CLOUD_NET_IFACE) is present"
      break
    fi
    # Re-detect in case it appeared with a different name
    CLOUD_NET_IFACE=$(ip -o addr show | grep "@PRIVATE_IP_ADDR@" | awk '{print $2}' | head -1 || true)
    sleep 1
  done
  if [[ -z "$CLOUD_NET_IFACE" ]] || ! ip link show "$CLOUD_NET_IFACE" >/dev/null 2>&1; then
    echo "[postinstall] WARNING: Cloud Network interface not found"
    echo "[postinstall] Server may not be attached to a Hetzner Cloud Network yet"
  fi
  (ip -brief addr || ip addr) 2>/dev/null | sed 's/^/[postinstall]   /' || true
  mark_step "07-cloud-network"
fi

# Step 8: Disable swap
if skip_if_done "08-disable-swap" "Disable swap"; then
  :
else
  echo "[postinstall] Disabling swap ..."
  sed -i '/\sswap\s/d' /etc/fstab || true
  swapoff -a 2>/dev/null || true
  mark_step "08-disable-swap"
fi

# Step 9: Network tuning
if skip_if_done "09-network-tuning" "Network tuning (fq qdisc and BBR)"; then
  :
else
  echo "[postinstall] Applying network tuning ..."
  if ! grep -q 'net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null; then echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf; fi
  if ! grep -q 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null; then echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf; fi
  mark_step "09-network-tuning"
fi

# Step 9a: Increase inotify limits
if skip_if_done "09a-inotify-limits" "inotify limits configuration"; then
  :
else
  echo "[postinstall] Increasing inotify limits ..."
  if ! grep -q 'fs.inotify.max_user_instances' /etc/sysctl.conf 2>/dev/null; then
    echo 'fs.inotify.max_user_instances=8192' >> /etc/sysctl.conf
  fi
  if ! grep -q 'fs.inotify.max_user_watches' /etc/sysctl.conf 2>/dev/null; then
    echo 'fs.inotify.max_user_watches=524288' >> /etc/sysctl.conf
  fi
  if ! grep -q 'fs.inotify.max_queued_events' /etc/sysctl.conf 2>/dev/null; then
    echo 'fs.inotify.max_queued_events=32768' >> /etc/sysctl.conf
  fi
  mark_step "09a-inotify-limits"
fi

# Step 10: Enable Tailscale
if skip_if_done "10-tailscale-enable" "Tailscale service enablement"; then
  :
else
  echo "[postinstall] Enabling Tailscale ..."
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
        echo "[postinstall] WARNING: Tailscale up command failed."
      fi
    else
      echo "[postinstall] No Tailscale auth key provided; skipping automatic login."
    fi
  else
    echo "[postinstall] Tailscale is already logged in."
    TS_CONFIGURED=true
  fi
  mark_step "11-tailscale-up"
fi

# Step 12: Validate Tailscale and get IP
if skip_if_done "12-tailscale-validate" "Tailscale validation and IP detection"; then
  :
else
  echo "[postinstall] Validating Tailscale connectivity..."
  TS_CONFIGURED=false
  TS_IP=""
  if tailscale status --peers=false >/dev/null 2>&1; then
    TS_CONFIGURED=true
  fi
  if [[ "$TS_CONFIGURED" == "true" ]]; then
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
      TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
      if [[ -n "$TS_IP" ]]; then
        echo "[postinstall] Tailscale IP: $TS_IP"
      fi
    fi
  fi
  mark_step "12-tailscale-validate"
fi

# Step 12b is merged into step 13 (Tailscale IP now written directly into k3s config)
mark_step "12b-k3s-update-tailscale-ip"

# Step 13: Configure k3s (master nodes only, using Cloud Network IP)
if skip_if_done "13-k3s-config" "k3s configuration"; then
  :
else
  if [[ "@WORKER_MODE@" != "true" ]]; then
    echo "[postinstall] Writing k3s config with TLS SANs..."
    # Read the detected Cloud Network interface
    if [[ -f /etc/infra-postinstall.d/cloud-net-iface ]]; then
      K3S_FLANNEL_IFACE=$(cat /etc/infra-postinstall.d/cloud-net-iface)
    else
      K3S_FLANNEL_IFACE=$(ip -o addr show | grep "@PRIVATE_IP_ADDR@" | awk '{print $2}' | head -1 || true)
      K3S_FLANNEL_IFACE=${K3S_FLANNEL_IFACE:-enp7s0}
    fi
    echo "[postinstall] Using flannel interface: $K3S_FLANNEL_IFACE"
    mkdir -p /etc/rancher/k3s

    # Build tls-san list — include Tailscale IP if available from step 12
    K3S_TLS_SANS="  - @PUBLIC_HOSTNAME@
  - @EXTERNAL_IP@
  - localhost"
    if [[ -n "${TS_IP:-}" ]]; then
      K3S_TLS_SANS="  - @PUBLIC_HOSTNAME@
  - @EXTERNAL_IP@
  - ${TS_IP}
  - localhost"
      echo "[postinstall] Including Tailscale IP ${TS_IP} in k3s TLS SANs"
    else
      echo "[postinstall] WARNING: Tailscale IP not available; k3s TLS SANs will not include it"
    fi

    cat >/etc/rancher/k3s/config.yaml <<K3S_EOF
write-kubeconfig-mode: "0644"
tls-san:
${K3S_TLS_SANS}
node-ip: @PRIVATE_IP_ADDR@
flannel-iface: ${K3S_FLANNEL_IFACE}
K3S_EOF
  else
    echo "[postinstall] Worker mode detected; skipping k3s server config"
  fi
  mark_step "13-k3s-config"
fi

# Step 14: Install k3s (master nodes only)
if skip_if_done "14-k3s-install" "k3s installation"; then
  :
else
  if [[ "@WORKER_MODE@" != "true" ]]; then
    echo "[postinstall] Installing k3s server ..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true sh - >/root/k3s-install.log 2>&1 || true
  else
    echo "[postinstall] Worker mode detected; skipping k3s server installation"
  fi
  mark_step "14-k3s-install"
fi

# Step 14b: Configure Traefik (master nodes only)
if skip_if_done "14b-traefik-config" "Traefik externalTrafficPolicy configuration"; then
  :
else
  if [[ "@WORKER_MODE@" != "true" ]]; then
    echo "[postinstall] Starting k3s temporarily to configure Traefik..."
    systemctl start k3s 2>/dev/null || true

    echo "[postinstall] Waiting for k3s API server..."
    for i in {1..24}; do
      if kubectl get nodes >/dev/null 2>&1; then
        echo "[postinstall] k3s API server is ready"
        break
      fi
      sleep 5
    done

    echo "[postinstall] Waiting for Traefik service..."
    for i in {1..24}; do
      if kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
        echo "[postinstall] Traefik service found"
        break
      fi
      sleep 5
    done

    if kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
      echo "[postinstall] Configuring Traefik externalTrafficPolicy=Local..."
      kubectl -n kube-system patch svc traefik -p '{"spec":{"externalTrafficPolicy":"Local"}}' 2>/dev/null || true
      POLICY=$(kubectl -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}' 2>/dev/null || echo "")
      if [[ "$POLICY" == "Local" ]]; then
        echo "[postinstall] ✓ Traefik configured with externalTrafficPolicy=Local"
      fi
    fi

    echo "[postinstall] Stopping k3s (will auto-start after reboot)..."
    systemctl stop k3s 2>/dev/null || true
  fi
  mark_step "14b-traefik-config"
fi

# Step 15: Enable UFW after Tailscale is confirmed
if skip_if_done "15-ufw-enable" "UFW enablement after Tailscale"; then
  :
else
  echo "[postinstall] Checking Tailscale before enabling UFW..."
  TS_CONFIGURED=false
  if tailscale status --peers=false >/dev/null 2>&1; then
    TS_CONFIGURED=true
  fi

  if [[ "$TS_CONFIGURED" == "true" ]]; then
    TS_INTERFACE_UP=false
    for i in {1..60}; do
      if ip link show tailscale0 >/dev/null 2>&1; then
        TS_INTERFACE_UP=true
        break
      fi
      sleep 1
    done

    if [[ "$TS_INTERFACE_UP" != "true" ]]; then
      echo "[postinstall] WARNING: Tailscale interface did not come up. NOT enabling UFW."
    else
      echo "[postinstall] Enabling UFW ..."
      ufw --force enable >/dev/null 2>&1 || true
      if command -v systemctl >/dev/null 2>&1; then
        systemctl enable ufw || true
      fi
      ufw status verbose || true
    fi
  else
    echo "[postinstall] WARNING: Tailscale not configured. NOT enabling UFW to avoid lockout."
  fi
  mark_step "15-ufw-enable"
fi

# Step 16: SSH hardening
if skip_if_done "16-ssh-hardening" "SSH hardening (disable root login)"; then
  :
else
  echo "[postinstall] Disabling SSH root login ..."
  mkdir -p /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-disable-root.conf <<'SSHD_EOF'
# Managed by infra postinstall
PermitRootLogin no
SSHD_EOF
  if [[ -f /etc/ssh/sshd_config ]]; then
    if grep -q '^[#[:space:]]*PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null; then
      sed -ri 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
    else
      echo 'PermitRootLogin no' >> /etc/ssh/sshd_config || true
    fi
  fi
  if command -v sshd >/dev/null 2>&1; then sshd -t || true; fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
  fi
  mark_step "16-ssh-hardening"
fi

# Step 17: Mark completion and reboot
echo "[postinstall] Postinstall completion summary:"
echo "[postinstall] ============================================"
ls -1 "$MARKER_DIR" | sed 's/^/[postinstall]   ✓ /'
echo "[postinstall] ============================================"

date +"%Y-%m-%dT%H:%M:%S%z" > "$MARKER_COMPLETE" || touch "$MARKER_COMPLETE" || true
echo "[postinstall] Postinstall completed successfully."
echo "[postinstall] Now rebooting to apply all changes..."
sleep 2
reboot
POSTINSTALL_EOF
}

# ============================================================================
# Kubeconfig extraction
# ============================================================================

function fetch_kubeconfig(){
  local host="${1:-${HOSTNAME}}" tailscale_ip="${2:-}"
  local out_dir="${ENV_DIR}"
  mkdir -p "${out_dir}" 2>/dev/null || true

  set +e
  KCFG_CONTENT=$(ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" admin@"${host}" 'sudo cat /etc/rancher/k3s/k3s.yaml' 2>/dev/null)
  rc=$?
  set -e

  if [[ $rc -ne 0 || -z "${KCFG_CONTENT}" ]]; then
    warn "Could not read remote kubeconfig yet. Skipping."
    return 0
  fi

  local api_server_host="${HOSTNAME}"
  if [[ -n "${tailscale_ip}" ]]; then
    api_server_host="${tailscale_ip}"
    info "Using Tailscale IP ${tailscale_ip} for kubeconfig API server"
  fi

  local adjusted
  adjusted=$(printf "%s" "${KCFG_CONTENT}" \
    | awk -v env="${ENV_NAME}" -v host="${api_server_host}" '
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
  ok "Wrote kubeconfig to ${out_dir}/kubeconfig.yaml (context: ${ENV_NAME}, server: https://${api_server_host}:6443)"

  local kube_home="${HOME}/.kube"
  mkdir -p "${kube_home}"
  if command -v kubectl >/dev/null 2>&1; then
    if [[ -f "${kube_home}/config" ]]; then
      KUBECONFIG="${out_dir}/kubeconfig.yaml:${kube_home}/config" kubectl config view --flatten >"${kube_home}/config.tmp" 2>/dev/null && mv "${kube_home}/config.tmp" "${kube_home}/config" && ok "Merged ${ENV_NAME} context into ${kube_home}/config" || warn "Failed to merge kubeconfig"
    else
      cp "${out_dir}/kubeconfig.yaml" "${kube_home}/config"
      ok "Created ${kube_home}/config with ${ENV_NAME} context"
    fi
    kubectl --kubeconfig "${kube_home}/config" config use-context "${ENV_NAME}" >/dev/null 2>&1 || true
  fi
}

# ============================================================================
# MAIN FLOW
# ============================================================================

# Validate required tools
provision::require_tools || exit 1
if ! command -v curl >/dev/null 2>&1; then err "curl is required"; exit 1; fi

# Read Hetzner Cloud token
if ! hcloud::read_token; then
  exit 1
fi

# --- DESTROY MODE ---
if $DESTROY; then
  echo -e "${RED}WARNING: This will permanently delete the server '${HCLOUD_SERVER_NAME}'${NC}"
  echo -e "${RED}All data on the server will be lost!${NC}"
  read -rp "Type the server name to confirm deletion [${HCLOUD_SERVER_NAME}]: " confirm
  if [[ "$confirm" != "$HCLOUD_SERVER_NAME" ]]; then
    err "Confirmation failed. Aborting."
    exit 1
  fi

  # Find and delete server
  info "Looking up server '${HCLOUD_SERVER_NAME}'..."
  server_json=$(hcloud::get_server "${HCLOUD_SERVER_NAME}" 2>/dev/null || true)
  if [[ -z "$server_json" ]]; then
    warn "Server '${HCLOUD_SERVER_NAME}' not found in Hetzner Cloud"
  else
    server_id=$(printf '%s' "$server_json" | jq -r '.id' 2>/dev/null)
    hcloud::delete_server "$server_id"
  fi

  # Clean up Tailscale device
  if ! $SKIP_TAILSCALE && tailscale::read_api_token 2>/dev/null; then
    tailscale::cleanup_stale_devices "${HOSTNAME}"
  fi

  # Clean up Cloudflare DNS records
  if ! $SKIP_DNS; then
    dns::cleanup_cloudflare
  fi

  ok "Destroy complete"
  exit 0
fi

# --- PRE-FLIGHT CHECKS ---
if ! $SKIP_DIAGNOSE; then
  info "Running pre-flight checks..."

  # Validate Tailscale API key
  if ! $SKIP_TAILSCALE; then
    if tailscale::read_api_token; then
      ok "Tailscale API key loaded"
    else
      warn "Tailscale API key not found; Tailscale setup will be skipped"
    fi
  fi
fi

# --- SERVER CREATION ---
if $CREATE_SERVER; then
  # Check if server already exists
  existing_server=$(hcloud::get_server "${HCLOUD_SERVER_NAME}" 2>/dev/null || true)
  if [[ -n "$existing_server" ]]; then
    HCLOUD_SERVER_ID=$(printf '%s' "$existing_server" | jq -r '.id' 2>/dev/null)
    HCLOUD_PUBLIC_IP=$(printf '%s' "$existing_server" | jq -r '.public_net.ipv4.ip' 2>/dev/null)
    ok "Server '${HCLOUD_SERVER_NAME}' already exists (ID: ${HCLOUD_SERVER_ID}, IP: ${HCLOUD_PUBLIC_IP})"
  else
    # Register SSH key
    info "Registering SSH public key in Hetzner Cloud..."
    SSH_KEY_ID=$(hcloud::create_ssh_key "infra-provisioning" "${SSH_PUBKEY_CONTENT}") || {
      err "Failed to register SSH key"
      exit 1
    }

    # Ensure Cloud Network exists
    # Derive IP range from PRIVATE_IP CIDR
    NETWORK_CIDR="${PRIVATE_IP#*/}"
    NETWORK_IP_RANGE="10.0.0.0/${NETWORK_CIDR}"
    info "Ensuring Cloud Network '${HCLOUD_NETWORK_NAME}' exists..."
    HCLOUD_NETWORK_ID=$(hcloud::ensure_network "${HCLOUD_NETWORK_NAME}" "${HCLOUD_NETWORK_ZONE}" "${NETWORK_IP_RANGE}") || {
      err "Failed to create/get Cloud Network"
      exit 1
    }
    ok "Cloud Network ready (ID: ${HCLOUD_NETWORK_ID})"

    # Generate cloud-init user data
    USER_DATA=$(gen_cloud_init "${SSH_PUBKEY_CONTENT}")

    # Create server
    hcloud::create_server "${HCLOUD_SERVER_NAME}" "${HCLOUD_SERVER_TYPE}" "${HCLOUD_IMAGE}" \
      "${HCLOUD_LOCATION}" "${SSH_KEY_ID}" "${USER_DATA}" || {
      err "Failed to create server"
      exit 1
    }

    # Wait for server to be running
    hcloud::wait_for_running "${HCLOUD_SERVER_ID}" 120 || {
      err "Server did not start"
      exit 1
    }

    # Attach to Cloud Network with static IP
    hcloud::attach_to_network "${HCLOUD_SERVER_ID}" "${HCLOUD_NETWORK_ID}" "${PRIVATE_IP_ADDR}" || {
      err "Failed to attach server to Cloud Network"
      exit 1
    }

    # Set reverse DNS
    hcloud::set_rdns "${HCLOUD_SERVER_ID}" "${HCLOUD_PUBLIC_IP}" "${HOSTNAME}"
  fi

  # Update EXTERNAL_IP in env.properties if it changed
  if [[ -n "${HCLOUD_PUBLIC_IP}" ]]; then
    EXTERNAL_IP="${HCLOUD_PUBLIC_IP}"
    if grep -q '^EXTERNAL_IP=' "${ENV_FILE}"; then
      current_ip=$(grep '^EXTERNAL_IP=' "${ENV_FILE}" | cut -d= -f2)
      if [[ "$current_ip" != "$EXTERNAL_IP" ]]; then
        info "Updating EXTERNAL_IP in env.properties: ${current_ip:-<empty>} -> ${EXTERNAL_IP}"
        sed -i.bak "s/^EXTERNAL_IP=.*/EXTERNAL_IP=${EXTERNAL_IP}/" "${ENV_FILE}"
        rm -f "${ENV_FILE}.bak"
      fi
    else
      echo "EXTERNAL_IP=${EXTERNAL_IP}" >> "${ENV_FILE}"
    fi
    ok "Server public IP: ${EXTERNAL_IP}"
  fi

  # DNS setup
  if ! $SKIP_DNS && [[ -n "${EXTERNAL_IP:-}" ]]; then
    info "Setting up Cloudflare DNS records..."
    dns::setup_cloudflare "${EXTERNAL_IP}" || warn "DNS setup failed (non-fatal)"
  fi
fi

# --- PROVISIONING ---
if $PROVISION_SERVER; then
  # If we didn't create the server, look it up
  if [[ -z "${HCLOUD_PUBLIC_IP:-}" ]]; then
    existing_server=$(hcloud::get_server "${HCLOUD_SERVER_NAME}" 2>/dev/null || true)
    if [[ -z "$existing_server" ]]; then
      err "Server '${HCLOUD_SERVER_NAME}' not found. Run with --create-server first."
      exit 1
    fi
    HCLOUD_SERVER_ID=$(printf '%s' "$existing_server" | jq -r '.id' 2>/dev/null)
    HCLOUD_PUBLIC_IP=$(printf '%s' "$existing_server" | jq -r '.public_net.ipv4.ip' 2>/dev/null)
    EXTERNAL_IP="${HCLOUD_PUBLIC_IP}"
  fi

  # Ensure Cloud Network is set up (for --provision-only case)
  if [[ -z "${HCLOUD_NETWORK_ID:-}" ]]; then
    NETWORK_CIDR="${PRIVATE_IP#*/}"
    NETWORK_IP_RANGE="10.0.0.0/${NETWORK_CIDR}"
    HCLOUD_NETWORK_ID=$(hcloud::ensure_network "${HCLOUD_NETWORK_NAME}" "${HCLOUD_NETWORK_ZONE}" "${NETWORK_IP_RANGE}") || true
    if [[ -n "${HCLOUD_NETWORK_ID}" ]]; then
      hcloud::attach_to_network "${HCLOUD_SERVER_ID}" "${HCLOUD_NETWORK_ID}" "${PRIVATE_IP_ADDR}" || true
    fi
  fi

  # Wait for cloud-init to finish and SSH to be ready
  cleanup_known_hosts
  info "Waiting for SSH to become available on ${EXTERNAL_IP}..."
  if ! wait_for_ssh "${EXTERNAL_IP}" ${SSH_PORT} 120; then
    err "SSH did not become available on ${EXTERNAL_IP}:${SSH_PORT}"
    exit 1
  fi

  # Wait for cloud-init to complete
  info "Waiting for cloud-init to finish..."
  for i in {1..60}; do
    if ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" 'cloud-init status --wait' >/dev/null 2>&1; then
      ok "cloud-init completed"
      break
    fi
    # Alternative check
    if ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" 'test -f /var/lib/cloud/instance/boot-finished' 2>/dev/null; then
      ok "cloud-init completed (boot-finished marker found)"
      break
    fi
    sleep 5
  done

  # Check if postinstall already done
  POSTINSTALL_DONE=false
  if ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" 'test -f /etc/infra-postinstall.done' 2>/dev/null; then
    POSTINSTALL_DONE=true
    info "Postinstall already applied; skipping."
  fi
  if [[ "$POSTINSTALL_DONE" == "false" ]]; then
    if ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" admin@"${EXTERNAL_IP}" 'sudo test -f /etc/infra-postinstall.done' 2>/dev/null; then
      POSTINSTALL_DONE=true
      info "Postinstall already applied; skipping."
    fi
  fi

  if [[ "$POSTINSTALL_DONE" == "false" ]]; then
    # Generate and upload postinstall script
    POSTINSTALL_CONTENT=$(gen_postinstall)

    # Create Tailscale auth key
    TAILSCALE_AUTHKEY=""
    if ! $SKIP_TAILSCALE && tailscale::read_api_token 2>/dev/null; then
      tailscale::cleanup_stale_devices "${HOSTNAME}"
      TAILSCALE_AUTHKEY=$(tailscale::create_authkey "${HOSTNAME}" "false" "true" || true)
      if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
        ok "Created Tailscale auth key"
      else
        warn "Failed to create Tailscale auth key; manual Tailscale setup needed"
      fi
    fi

    # Template substitutions
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@PRIVATE_IP_ADDR@/${PRIVATE_IP_ADDR}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@PUBLIC_HOSTNAME@/${HOSTNAME}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@EXTERNAL_IP@/${EXTERNAL_IP}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@MASTER_PRIVATE_IP@/${MASTER_PRIVATE_IP:-}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@WORKER_MODE@/${WORKER_MODE}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@TAILSCALE_AUTHKEY@/${TAILSCALE_AUTHKEY}}

    # Upload and execute
    info "Uploading and running postinstall script..."
    ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" "cat >/root/postinstall.sh && chmod +x /root/postinstall.sh" <<< "$POSTINSTALL_CONTENT"
    if ! ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" root@"${EXTERNAL_IP}" "export TERM=xterm; /bin/bash /root/postinstall.sh"; then
      warn "Postinstall script failed, but continuing..."
    fi

    # Wait for reboot
    info "Waiting for system to reboot after postinstall..."
    for i in {1..30}; do
      if ! ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" -o ConnectTimeout=5 root@"${EXTERNAL_IP}" 'true' >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
  fi

  # After reboot, detect Tailscale IP
  TAILSCALE_IP=""
  SSH_HOST="${EXTERNAL_IP}"
  if ! $SKIP_TAILSCALE && tailscale::read_api_token 2>/dev/null; then
    info "Detecting Tailscale IP after reboot..."
    for i in {1..12}; do
      TAILSCALE_IP=$(tailscale::get_device_ip "${HOSTNAME}" 2>/dev/null || true)
      if [[ -n "$TAILSCALE_IP" ]]; then
        ok "Detected Tailscale IP: ${TAILSCALE_IP}"
        break
      fi
      sleep 5
    done
    if [[ -n "$TAILSCALE_IP" ]]; then
      if wait_for_ssh "${TAILSCALE_IP}" ${SSH_PORT} 60 2>/dev/null; then
        SSH_HOST="${TAILSCALE_IP}"
        ok "Using Tailscale IP for SSH"
      fi
    fi
  fi

  # Wait for admin SSH
  info "Waiting for admin SSH on ${SSH_HOST}..."
  if wait_for_ssh_user "${SSH_HOST}" ${SSH_PORT} admin 240; then
    ok "admin SSH is available"

    if $WORKER_MODE; then
      # Worker node provisioning
      info "Worker mode: joining cluster via master ${MASTER_HOSTNAME}..."

      # Validate Cloud Network connectivity to master
      info "Testing connectivity to master ${MASTER_PRIVATE_IP} via Cloud Network..."
      if ! ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" admin@"${SSH_HOST}" "ping -c3 -W2 ${MASTER_PRIVATE_IP}" >/dev/null 2>&1; then
        err "Cannot ping master ${MASTER_PRIVATE_IP} from worker via Cloud Network"
        exit 1
      fi
      ok "Cloud Network connectivity verified"

      # Test k3s API port
      if ! ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" admin@"${SSH_HOST}" "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/${MASTER_PRIVATE_IP}/6443'" 2>/dev/null; then
        err "Cannot reach k3s API port 6443 on master ${MASTER_PRIVATE_IP}"
        exit 1
      fi
      ok "k3s API port reachable on master"

      # Get master node token
      if [[ -n "${K3S_TOKEN:-}" ]]; then
        MASTER_NODE_TOKEN="${K3S_TOKEN}"
      else
        info "Fetching master node-token from ${MASTER_HOSTNAME}..."
        MASTER_SSH_HOST="${MASTER_HOSTNAME}"
        if [[ -n "${TAILSCALE_IP:-}" ]] && tailscale::read_api_token 2>/dev/null; then
          MASTER_TS_IP=$(tailscale::get_device_ip "${MASTER_HOSTNAME}" 2>/dev/null || true)
          if [[ -n "${MASTER_TS_IP}" ]]; then
            MASTER_SSH_HOST="${MASTER_TS_IP}"
          fi
        fi
        set +e
        MASTER_NODE_TOKEN=$(ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" admin@"${MASTER_SSH_HOST}" 'sudo cat /var/lib/rancher/k3s/server/node-token' 2>/dev/null)
        rc_token=$?
        set -e
        if [[ $rc_token -ne 0 || -z "${MASTER_NODE_TOKEN}" ]]; then
          err "Failed to retrieve master node token from ${MASTER_SSH_HOST}"
          err "Set K3S_TOKEN env var and retry, or SSH to master and get it manually."
          exit 1
        fi
        ok "Retrieved master node token"
      fi

      # Install k3s agent — detect Cloud Network interface dynamically
      info "Installing k3s agent on worker ${HOSTNAME}..."
      set +e
      ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" admin@"${SSH_HOST}" bash -s <<AGENT
set -euo pipefail
# Auto-detect Cloud Network interface
CLOUD_NET_IFACE=""
if [[ -f /etc/infra-postinstall.d/cloud-net-iface ]]; then
  CLOUD_NET_IFACE=\$(cat /etc/infra-postinstall.d/cloud-net-iface)
else
  CLOUD_NET_IFACE=\$(ip -o addr show | grep "${PRIVATE_IP_ADDR}" | awk '{print \$2}' | head -1 || true)
  CLOUD_NET_IFACE=\${CLOUD_NET_IFACE:-enp7s0}
fi
echo "Using flannel interface: \$CLOUD_NET_IFACE"
export K3S_URL="https://${MASTER_PRIVATE_IP}:6443"
export K3S_TOKEN="${MASTER_NODE_TOKEN}"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent \
  --node-ip ${PRIVATE_IP_ADDR} \
  --node-external-ip ${EXTERNAL_IP} \
  --flannel-iface \$CLOUD_NET_IFACE" sh -

if ! systemctl is-active --quiet k3s-agent; then
  echo "[ERROR] k3s-agent service failed to start"
  systemctl status k3s-agent --no-pager || true
  journalctl -u k3s-agent -n 50 --no-pager || true
  exit 1
fi
AGENT
      agent_rc=$?
      set -e

      if [[ $agent_rc -ne 0 ]]; then
        err "k3s agent installation failed on ${HOSTNAME}"
        exit 1
      fi
      ok "k3s agent installed on ${HOSTNAME}"

      # Validate node registration
      VALIDATION_HOST="${MASTER_SSH_HOST:-${MASTER_HOSTNAME}}"
      if ssh -p ${SSH_PORT} "${SSH_OPTS[@]}" admin@"${VALIDATION_HOST}" 'sudo k3s kubectl get nodes -o wide' 2>/dev/null; then
        ok "Node registration validated"
      else
        warn "Could not validate node registration; check manually"
      fi
    else
      # Master node - extract kubeconfig
      fetch_kubeconfig "${SSH_HOST}" "${TAILSCALE_IP}"
    fi
  else
    warn "admin SSH not available on ${SSH_HOST}:${SSH_PORT}"
  fi

  # Configure Tailscale device via API
  if ! $SKIP_TAILSCALE && tailscale::read_api_token 2>/dev/null; then
    info "Waiting for device to appear in Tailscale..."
    DEVICE_ID=""
    for i in {1..12}; do
      DEVICE_ID=$(tailscale::get_device_id "${HOSTNAME}" || true)
      if [[ -n "$DEVICE_ID" ]]; then
        ok "Device registered in Tailscale: ${DEVICE_ID}"
        break
      fi
      sleep 5
    done
  fi
fi

ok "Provisioning complete for ${ENV_NAME}"
info "Server: ${HCLOUD_SERVER_NAME} (${HCLOUD_PUBLIC_IP:-unknown})"
info "Private IP: ${PRIVATE_IP_ADDR}"
[[ -n "${TAILSCALE_IP:-}" ]] && info "Tailscale IP: ${TAILSCALE_IP}"
info ""
info "Next steps:"
info "  kubectl get nodes                        # Verify K3s is running"
info "  tools/k3s/identity.sh ${ENV_NAME}        # Set up Dex + Pomerium"
info "  tools/k3s/argocd.sh ${ENV_NAME}          # Set up ArgoCD"
