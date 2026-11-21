#!/usr/bin/env bash
# Hetzner Cloud provisioning helper
#
# Creates, provisions and destroys Hetzner Cloud VMs through the Hetzner Cloud API. Three kinds of node:
#
#   server          (default) a K3s server on a cloud VM, with a Hetzner Cloud private network.
#   private worker  MASTER_PRIVATE_IP set: a K3s agent that joins a cloud server over that network.
#   tenant worker   --worker <tenant>-<n>: a VM in the OPERATING org's Hetzner project (the env's ops
#                   token) that runs only one tenant's pods and joins an existing cluster (bare metal or
#                   cloud) over Tailscale as an isolated tenant worker, through tools/k3s/join-worker.sh
#                   --tenant. The ops org holds root and every key; the tenant gets no shell. No private
#                   network, no public inbound port but Tailscale's, no DNS records.
#                   See docs/HETZNER-CLOUD-TENANT.md.
#
# Usage:
#   tools/provision-hetzner-cloud.sh <env-name> [--worker <tenant>-<n>] [flags]
#
# Flags:
#   --worker NAME           Tenant worker mode: config in envs/<env>/<NAME>/env.properties
#   --ssh-key PATH          SSH key path (default: ~/.ssh/id_ed25519)
#   --create-server         Create server only (skip provisioning)
#   --provision-only        Provision existing server (skip creation)
#   --no-join               Tenant worker: provision the node but do not run join-worker.sh
#   --skip-diagnose         Skip pre-flight checks
#   --skip-dns              Skip Cloudflare DNS setup (never done for a tenant worker)
#   --skip-tailscale        Skip Tailscale setup (not possible for a tenant worker)
#   --destroy               Tear down server (with confirmation)
#   --confirm NAME          Answer the --destroy confirmation non-interactively (must equal the server name)
#   --dry-run               Print every API call (method, URL, body with secrets redacted) and every
#                           remote step instead of running it. GET calls still run when a token is
#                           available, so the plan reflects what exists; nothing is created or deleted.
#   --debug                 Verbose logging
#
# Server / private worker: envs/<env>/env.properties with
#   HOSTNAME=example.domain.tld
#   ACME_EMAIL=admin@example.com
#   HCLOUD_SERVER_TYPE=cpx32         # Hetzner Cloud server type
#   HCLOUD_LOCATION=hel1             # Location (fsn1, nbg1, hel1)
#   HCLOUD_IMAGE=ubuntu-24.04        # OS image
#   HCLOUD_NETWORK_ZONE=eu-central   # For private network
#   PRIVATE_IP=10.0.0.2/16           # Private network IP
#   # Optional: private worker mode
#   # MASTER_PRIVATE_IP=10.0.0.1
#   # MASTER_HOSTNAME=master.example.domain.tld
#
# Tenant worker: envs/<env>/<tenant>-<n>/env.properties (the same file tools/k3s/join-worker.sh reads)
#   TENANT=symbioen                  # DNS label; the node is named <tenant>-*
#   MASTER_VLAN_IP=100.x.y.z         # the cluster server's Tailscale IP
#   MASTER_HOSTNAME=prod.example.com # the cluster server's hostname
#   HCLOUD_SERVER_TYPE=cx33          # default cx33
#   HCLOUD_LOCATION=hel1             # default hel1; put it where the cluster server is
#   HCLOUD_IMAGE=ubuntu-24.04
#   # Written by this script: EXTERNAL_IP (public IPv4), VLAN_IP (Tailscale IPv4), SSH_VIA=tailscale
#   # Optional: HCLOUD_TOKEN_FILE, TAILSCALE_TAG (default tag:tenant-<tenant>), HCLOUD_FIREWALL_SSH_CIDRS,
#   #           TAILSCALE_DENY_TESTS. Not REGISTRY_HOSTS: a tenant node pulls over public 443.
#   The API token is the ops org's: envs/shared/secrets.plain/hetzner-cloud-token.txt (or its sops copy
#   in secrets.sops/), or HCLOUD_TOKEN_FILE (relative to envs/) for an env whose nodes live in another
#   ops project. Every resource is labelled managed-by=infra-skills, tenant=<tenant>, node=<name>;
#   nothing without those labels is changed or deleted.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
source "$REPO_ROOT/tools/provision-common.sh"
ENV_ROOT=$(provision::envs_root)

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

function usage() {
  cat <<USAGE
Hetzner Cloud provisioning
Usage: $0 <env-name> [--worker NAME] [--ssh-key PATH] [--create-server] [--provision-only] [--no-join]
          [--skip-diagnose] [--skip-dns] [--skip-tailscale] [--destroy] [--confirm NAME] [--dry-run] [--debug]

Examples:
  $0 cloud-test --ssh-key ~/.ssh/id_ed25519
  $0 cloud-test --create-server           # Create server only
  $0 cloud-test --provision-only           # Provision existing server
  $0 cloud-test --destroy                  # Tear down server
  $0 prod --worker symbioen-1 --dry-run    # Tenant worker: print the plan
  $0 prod --worker symbioen-1              # Tenant worker: create, provision, join
  $0 prod --worker symbioen-1 --destroy    # Tenant worker: drain/remove from the cluster, then delete

Server / private worker: envs/<env>/env.properties with
  HOSTNAME=example.domain.tld
  ACME_EMAIL=admin@example.com
  HCLOUD_SERVER_TYPE=cax11         # Hetzner Cloud server type (default: cax11)
  HCLOUD_LOCATION=hel1             # Location (default: hel1)
  HCLOUD_IMAGE=ubuntu-24.04        # OS image (default: ubuntu-24.04)
  HCLOUD_NETWORK_ZONE=eu-central   # For private network (default: eu-central)
  PRIVATE_IP=10.0.0.2/16           # Private network IP
  # Optional: private worker mode
  # MASTER_PRIVATE_IP=10.0.0.1
  # MASTER_HOSTNAME=master.example.domain.tld

Tenant worker (--worker NAME): envs/<env>/NAME/env.properties with
  TENANT=<tenant>                  # NAME must be <tenant>-*
  MASTER_VLAN_IP=100.x.y.z         # cluster server's Tailscale IP
  MASTER_HOSTNAME=<server hostname>
  HCLOUD_SERVER_TYPE=cx33          # default: cx33
  HCLOUD_LOCATION=hel1             # default: hel1
  Token: the ops project's, envs/shared/secrets.plain/hetzner-cloud-token.txt (or HCLOUD_TOKEN_FILE)
  See docs/HETZNER-CLOUD-TENANT.md.
USAGE
}

function info(){ echo -e "${BLUE}[INFO]${NC} $*" >&2; }
function ok(){ echo -e "${GREEN}[OK]${NC} $*" >&2; }
function warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
function err(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }
function debug(){ $DEBUG && echo -e "${YELLOW}[DEBUG]${NC} $*" >&2 || true; }
function dbg(){ if $DEBUG; then echo -e "${YELLOW}[DEBUG]${NC} $*" >&2; fi }
# Dry-run output goes to the script's stdout (fd 3, also from inside $(...)), so a plan can be
# captured with > plan.txt while the log stays on stderr.
exec 3>&1
function plan(){ echo -e "[DRY-RUN] $*" >&3; }

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
CLUSTER_DIR="${ENV_ROOT}/${ENV_NAME}"
ENV_DIR="${CLUSTER_DIR}"

SSH_KEY="${SSH_KEY:-}"
CREATE_SERVER=true
PROVISION_SERVER=true
SKIP_DIAGNOSE=false
SKIP_DNS=false
SKIP_TAILSCALE=false
DESTROY=false
DESTROY_CONFIRM=""
DRY_RUN=false
DEBUG=false
WORKER_NAME=""
NO_JOIN=false

# Default behavior: run everything unless specifically limited
DEFAULT_RUN_ALL=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-key)
      SSH_KEY="$2"; shift 2;;
    --worker)
      WORKER_NAME="$2"; shift 2;;
    --create-server)
      CREATE_SERVER=true; PROVISION_SERVER=false; DEFAULT_RUN_ALL=false; shift;;
    --provision-only)
      CREATE_SERVER=false; PROVISION_SERVER=true; DEFAULT_RUN_ALL=false; shift;;
    --no-join)
      NO_JOIN=true; shift;;
    --skip-diagnose)
      SKIP_DIAGNOSE=true; shift;;
    --skip-dns)
      SKIP_DNS=true; shift;;
    --skip-tailscale)
      SKIP_TAILSCALE=true; shift;;
    --destroy)
      DESTROY=true; shift;;
    --confirm)
      DESTROY_CONFIRM="$2"; shift 2;;
    --dry-run)
      DRY_RUN=true; shift;;
    --debug)
      DEBUG=true; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo -e "${RED}Unknown argument: $1${NC}"; usage; exit 1;;
  esac
done

# Validate local keys before continuing (the SSH key goes onto the node; the age key decrypts sops copies)
if ! provision::validate_local_keys; then
  if $DRY_RUN; then
    provision::warn "Missing local keys (continuing: --dry-run)."
  else
    provision::warn "Missing required local keys. Aborting provisioning."
    exit 1
  fi
fi

# --- Node kind ---
# NODE_ROLE: server | private-worker | tenant-worker
TENANT_MODE=false
if [[ -n "$WORKER_NAME" ]]; then
  TENANT_MODE=true
  ENV_DIR="${CLUSTER_DIR}/${WORKER_NAME}"
fi
ENV_FILE="${ENV_DIR}/env.properties"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo -e "${RED}Environment file not found: ${ENV_FILE}${NC}"
  exit 1
fi

# bash sets HOSTNAME to the local machine's name; a tenant worker's env.properties need not set it.
$TENANT_MODE && unset HOSTNAME
# shellcheck disable=SC1090
source "${ENV_FILE}"

if $TENANT_MODE; then
  NODE_ROLE=tenant-worker
  NODE_NAME="${WORKER_NAME//_/-}"
  if [[ -z "${TENANT:-}" ]]; then
    err "--worker is the tenant worker mode: set TENANT=<tenant> in ${ENV_FILE}"; exit 1
  fi
  if [[ ! "$TENANT" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    err "TENANT must be a DNS label: ${TENANT}"; exit 1
  fi
  if [[ ! "$NODE_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ || "$NODE_NAME" != "${TENANT}-"* ]]; then
    err "A worker of tenant ${TENANT} must be named ${TENANT}-<n> (got ${NODE_NAME}): the admission policies recognise tenant nodes by name"
    exit 1
  fi
  for v in MASTER_VLAN_IP MASTER_HOSTNAME; do
    if [[ -z "${!v:-}" ]]; then
      err "Missing required variable ${v} in ${ENV_FILE}"; exit 1
    fi
  done
  # Tailscale is the only way in: the node's public interface admits nothing else.
  if $SKIP_TAILSCALE; then
    err "--skip-tailscale is not possible for a tenant worker: it joins the cluster over Tailscale"; exit 1
  fi
  SKIP_DNS=true
  HOSTNAME="${NODE_NAME}"
  HCLOUD_SERVER_TYPE="${HCLOUD_SERVER_TYPE:-cx33}"
  HCLOUD_LOCATION="${HCLOUD_LOCATION:-hel1}"
  HCLOUD_IMAGE="${HCLOUD_IMAGE:-ubuntu-24.04}"
  HCLOUD_SERVER_NAME="${NODE_NAME}"
  HCLOUD_FIREWALL_NAME="${HCLOUD_FIREWALL_NAME:-${NODE_NAME}}"
  HCLOUD_FIREWALL_SSH_CIDRS="${HCLOUD_FIREWALL_SSH_CIDRS:-}"
  TAILSCALE_TAG="${TAILSCALE_TAG:-tag:tenant-${TENANT}}"
  if [[ ! "$TAILSCALE_TAG" =~ ^tag:[A-Za-z0-9-]+$ ]]; then
    err "TAILSCALE_TAG must look like tag:<name> (got ${TAILSCALE_TAG})"; exit 1
  fi
  PRIVATE_IP_ADDR=""
  WORKER_MODE=true
else
  # Defaults for cloud-specific properties
  HCLOUD_SERVER_TYPE="${HCLOUD_SERVER_TYPE:-cax11}"
  HCLOUD_LOCATION="${HCLOUD_LOCATION:-hel1}"
  HCLOUD_IMAGE="${HCLOUD_IMAGE:-ubuntu-24.04}"
  HCLOUD_NETWORK_ZONE="${HCLOUD_NETWORK_ZONE:-eu-central}"
  TAILSCALE_TAG=""

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
  NODE_ROLE=server
  if [[ -n "${MASTER_PRIVATE_IP:-}" ]]; then
    WORKER_MODE=true
    NODE_ROLE=private-worker
    if [[ -z "${MASTER_HOSTNAME:-}" ]]; then
      echo -e "${RED}MASTER_PRIVATE_IP is set but MASTER_HOSTNAME is missing in ${ENV_FILE}${NC}"; exit 1
    fi
  fi

  # Derive server name from env name (Hetzner Cloud server names)
  HCLOUD_SERVER_NAME="${ENV_NAME}"

  # Network name derived from hostname base domain
  HCLOUD_NETWORK_NAME="lh-network"
fi

# Labels on every Hetzner resource this script creates, so destroy and a later run find them.
HCLOUD_LABELS_JSON=$(jq -cn --arg node "$HCLOUD_SERVER_NAME" --arg tenant "${TENANT:-}" \
  '{"managed-by": "infra-skills", "node": $node} + (if $tenant != "" then {tenant: $tenant} else {} end)')

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

HCLOUD_API="${HCLOUD_API:-https://api.hetzner.cloud/v1}"
HCLOUD_TOKEN=""

# Where the API token of the project the node lives in is read from: the ops org's project (a
# tenant worker too: the ops org owns the VM, so nobody else has its console, rescue system or
# root password reset). HCLOUD_TOKEN_FILE, relative to envs/, points at another ops project. An
# HCLOUD_TOKEN in the environment is never used (the hcloud CLI's variable may hold any project).
function hcloud::token_file(){
  if [[ -n "${HCLOUD_TOKEN_FILE:-}" ]]; then
    if [[ "$HCLOUD_TOKEN_FILE" == /* ]]; then echo "$HCLOUD_TOKEN_FILE"; else echo "${ENV_ROOT}/${HCLOUD_TOKEN_FILE}"; fi
  else
    echo "${ENV_ROOT}/shared/secrets.plain/hetzner-cloud-token.txt"
  fi
}

function hcloud::read_token(){
  local token_file sops_file
  token_file=$(hcloud::token_file)
  if [[ -f "$token_file" ]]; then
    HCLOUD_TOKEN=$(tr -d '\n\r' < "$token_file" | xargs)
  else
    sops_file="${token_file/\/secrets.plain\//\/secrets.sops\/}"
    if [[ "$sops_file" != "$token_file" && -f "$sops_file" ]]; then
      HCLOUD_TOKEN=$(sops -d "$sops_file" 2>/dev/null | tr -d '\n\r' | xargs) || HCLOUD_TOKEN=""
      [[ -z "$HCLOUD_TOKEN" ]] && { err "Cannot decrypt ${sops_file} (SOPS_AGE_KEY_FILE?)"; return 1; }
    else
      err "Hetzner Cloud API token not found: $token_file"
      err ""
      err "Create this file with the project's Hetzner Cloud API token:"
      err "  1. Go to https://console.hetzner.cloud → Project → Security → API Tokens"
      err "  2. Create a Read & Write token in your own (operating org's) project"
      err "  3. Save it to: $token_file"
      err "  4. Encrypt with: tools/sops/encrypt.sh $(basename "$(dirname "$(dirname "$token_file")")") $(basename "$token_file")"
      return 1
    fi
  fi
  if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
    err "Hetzner Cloud API token file is empty: $token_file"
    return 1
  fi
  dbg "Hetzner Cloud token read from $(hcloud::token_file) (or its sops copy)"
}

# Body shown in a dry-run plan: user_data (it carries a Tailscale auth key) is replaced by its size.
function hcloud::redact_body(){
  jq -c 'if type == "object" and has("user_data") then .user_data = "<cloud-init: \(.user_data | length) bytes, not shown>" else . end' 2>/dev/null <<<"$1" || echo "<body>"
}

# Curl wrapper for the Hetzner Cloud API.
# Usage: hcloud::api METHOD PATH [JSON_BODY]
# The token goes to curl through a config on a file descriptor and the body through a 0600 temp file,
# so neither shows up in the process list.
# --dry-run: a GET runs when a token is loaded (read-only) and is only printed otherwise; every other
# method is printed and never sent, and answers with a stand-in so the plan can go on.
function hcloud::api(){
  local method="$1" path="$2" data="${3:-}"
  local url="${HCLOUD_API}${path}"
  dbg "HCLOUD ${method} ${url}"

  if $DRY_RUN && { [[ "$method" != GET ]] || [[ -z "$HCLOUD_TOKEN" ]] || [[ "$path" == *"<"* ]]; }; then
    if [[ -n "$data" ]]; then plan "HCLOUD ${method} ${url} $(hcloud::redact_body "$data")"; else plan "HCLOUD ${method} ${url}"; fi
    HCLOUD_LAST_HTTP="000"; HCLOUD_LAST_BODY=""
    case "${method} ${path}" in
      "POST /ssh_keys")  printf '%s' '{"ssh_key":{"id":"<ssh-key-id>"}}' ;;
      "POST /firewalls") printf '%s' '{"firewall":{"id":"<firewall-id>"}}' ;;
      "POST /servers")   printf '%s' '{"server":{"id":"<server-id>","status":"running","public_net":{"ipv4":{"ip":"<public-ipv4>"},"firewalls":[]}},"action":{"id":"<action-id>"}}' ;;
      "DELETE /servers/"*) printf '%s' '{"action":{"id":"<action-id>","status":"success"}}' ;;
      *) printf '%s' '{}' ;;
    esac
    return 0
  fi

  $DRY_RUN && plan "HCLOUD ${method} ${url}  (read-only, run)"
  local response http body body_file="" curl_rc
  local -a data_args=()
  if [[ -n "$data" ]]; then
    body_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/hcloud-body.XXXXXX")
    printf '%s' "$data" >"$body_file"
    data_args=(--data-binary "@${body_file}")
  fi
  set +e
  response=$(curl -sS -X "$method" "$url" \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$HCLOUD_TOKEN") \
    -H "Content-Type: application/json" \
    ${data_args[@]+"${data_args[@]}"} -w "\n%{http_code}" 2>&1)
  curl_rc=$?
  set -e
  [[ -n "$body_file" ]] && rm -f "$body_file"

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

# The API's own error message of the last failed call, one line.
function hcloud::last_error(){
  printf '%s' "${HCLOUD_LAST_BODY:-}" | jq -r '.error | "\(.code): \(.message)"' 2>/dev/null || printf '%s' "${HCLOUD_LAST_BODY:-no response}"
}

# Get server by name
# Returns server JSON or empty string
function hcloud::get_server(){
  local name="$1"
  local out
  out=$(hcloud::api GET "/servers?name=${name}" 2>/dev/null) || return 1
  local server
  server=$(printf '%s' "$out" | jq -c '.servers[0] // empty' 2>/dev/null)
  if [[ -n "$server" && "$server" != "null" ]]; then
    printf '%s' "$server"
    return 0
  fi
  return 1
}

# Check that a server type exists, is x86 or ARM as expected, is not deprecated and is currently
# available in the location (server_types[].locations[].available; GET /datacenters is gone since
# 2026-10-01). Prints the monthly price. On "not available" it lists what is available there.
function hcloud::check_server_type(){
  local type="$1" location="$2" out st
  out=$(hcloud::api GET "/server_types?name=${type}") || { err "Cannot read server type ${type}: $(hcloud::last_error)"; return 1; }
  st=$(printf '%s' "$out" | jq -c '.server_types[0] // empty')
  if [[ -z "$st" ]]; then
    if $DRY_RUN && [[ -z "$HCLOUD_TOKEN" ]]; then
      plan "(no token: server type ${type} in ${location} not checked)"
      return 0
    fi
    err "Unknown Hetzner Cloud server type: ${type}"
    return 1
  fi
  local summary available deprecated
  summary=$(printf '%s' "$st" | jq -r --arg loc "$location" '
    "\(.name): \(.architecture), \(.cores) vCPU (\(.cpu_type)), \(.memory) GB RAM, \(.disk) GB disk, " +
    ((.prices[] | select(.location == $loc) | "EUR \(.price_monthly.net | tonumber * 100 | round / 100)/month net in \($loc)") // "no price in \($loc)")')
  available=$(printf '%s' "$st" | jq -r --arg loc "$location" '[.locations[]? | select(.name == $loc) | .available] | if length == 0 then "unknown" else (first | tostring) end')
  deprecated=$(printf '%s' "$st" | jq -r --arg loc "$location" '(.deprecation.unavailable_after // ([.locations[]? | select(.name == $loc) | .deprecation.unavailable_after // empty] | first)) // empty')
  info "Server type ${summary}"
  if [[ -n "$deprecated" ]]; then
    err "Server type ${type} is deprecated in ${location} (unavailable after ${deprecated})"
  fi
  if [[ "$available" != "true" || -n "$deprecated" ]]; then
    [[ -z "$deprecated" ]] && err "Server type ${type} is not available in ${location} right now (available=${available})"
    local mem arch all
    mem=$(printf '%s' "$st" | jq -r '.memory')
    arch=$(printf '%s' "$st" | jq -r '.architecture')
    all=$(hcloud::api GET "/server_types?per_page=50") || all='{}'
    info "Available ${arch} types in ${location} with at least ${mem} GB (set HCLOUD_SERVER_TYPE):"
    printf '%s' "$all" | jq -r --arg loc "$location" --arg arch "$arch" --argjson mem "$mem" '
      [.server_types[]? | select(.architecture == $arch and .memory >= $mem and .deprecation == null)
        | select(any(.locations[]?; .name == $loc and .available == true))
        | {name, cores, memory, disk, cpu_type, price: ([.prices[] | select(.location == $loc) | .price_monthly.net | tonumber] | first)}]
      | sort_by(.price)[] | "  \(.name)\t\(.cores) vCPU \(.cpu_type)\t\(.memory) GB\t\(.disk) GB\tEUR \(.price * 100 | round / 100)/month net"' >&2
    if $DRY_RUN; then
      warn "(--dry-run: continuing with ${type} anyway)"
      return 0
    fi
    return 1
  fi
  ok "Server type ${type} is available in ${location}"
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
  # Create new key. It is the operator's provisioning key, shared by every node in the ops
  # project, so it carries no node or tenant label.
  local create_out body
  body=$(jq -cn --arg name "$name" --arg key "$pubkey" --argjson labels "$HCLOUD_LABELS_JSON" \
    '{name: $name, public_key: $key, labels: ($labels | {"managed-by"})}')
  create_out=$(hcloud::api POST "/ssh_keys" "$body" 2>/dev/null) || {
    # Key might exist with different name but same fingerprint
    local error_code
    error_code=$(printf '%s' "${HCLOUD_LAST_BODY}" | jq -r '.error.code // empty' 2>/dev/null)
    if [[ "$error_code" == "uniqueness_error" ]]; then
      # Find key by public key
      local all_keys
      all_keys=$(hcloud::api GET "/ssh_keys?per_page=50" 2>/dev/null) || return 1
      existing_id=$(printf '%s' "$all_keys" | jq -r --arg key "$pubkey" '.ssh_keys[] | select(.public_key == $key) | .id' 2>/dev/null | head -1)
      if [[ -n "$existing_id" ]]; then
        dbg "SSH key already exists with different name, ID ${existing_id}"
        echo "$existing_id"
        return 0
      fi
    fi
    err "Failed to create SSH key: $(hcloud::last_error)"
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
    "$(jq -cn --arg name "$name" --arg range "$ip_range" '{name: $name, ip_range: $range}')" 2>/dev/null) || {
    err "Failed to create network '${name}': $(hcloud::last_error)"
    return 1
  }
  local network_id
  network_id=$(printf '%s' "$create_out" | jq -r '.network.id // "<network-id>"' 2>/dev/null)
  ok "Created network '${name}' (ID: ${network_id})"

  # Create subnet
  info "Creating subnet in network ${network_id}..."
  hcloud::api POST "/networks/${network_id}/actions/add_subnet" \
    "$(jq -cn --arg zone "$network_zone" --arg range "$ip_range" '{type: "cloud", network_zone: $zone, ip_range: $range}')" >/dev/null 2>&1 || {
    err "Failed to create subnet in network '${name}': $(hcloud::last_error)"
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
  server_out=$(hcloud::api GET "/servers/${server_id}" 2>/dev/null) || { $DRY_RUN || return 1; }
  local attached_network
  attached_network=$(printf '%s' "$server_out" | jq -r --arg net "$network_id" '.server.private_net[]? | select((.network | tostring) == $net) | .ip // empty' 2>/dev/null)
  if [[ -n "$attached_network" ]]; then
    ok "Server already attached to network with IP ${attached_network}"
    return 0
  fi

  set +e
  local attach_out
  attach_out=$(hcloud::api POST "/servers/${server_id}/actions/attach_to_network" \
    "$(jq -cn --arg net "$network_id" --arg ip "$ip" '{network: ($net | tonumber? // $net), ip: $ip}')")
  local attach_rc=$?
  set -e
  if [[ $attach_rc -ne 0 ]]; then
    err "Failed to attach server to network"
    err "API response: $(hcloud::last_error)"
    return 1
  fi
  ok "Attached server to network with IP ${ip}"
}

# The firewall rules of a tenant worker. Inbound is default-deny: a Hetzner Cloud firewall drops
# every inbound packet no rule matches. The only rule is Tailscale's direct-connection port
# (WireGuard, udp/41641); without it Tailscale still works through DERP relays, only slower.
# HCLOUD_FIREWALL_SSH_CIDRS (space- or comma-separated) adds public SSH for those sources: a
# break-glass for when Tailscale on the node is down (the Hetzner console is the other one).
# No outbound rule, so outbound stays open (apt, get.k3s.io, registries, Tailscale coordination).
function hcloud::tenant_firewall_rules(){
  jq -cn --arg ssh "${HCLOUD_FIREWALL_SSH_CIDRS:-}" '
    [{direction: "in", protocol: "udp", port: "41641", source_ips: ["0.0.0.0/0", "::/0"],
      description: "tailscale direct connections"}]
    + (($ssh | split(",") | map(split(" ")) | add // [] | map(select(. != ""))) as $cidrs
       | if ($cidrs | length) > 0
         then [{direction: "in", protocol: "tcp", port: "22", source_ips: $cidrs, description: "ssh break-glass"}]
         else [] end)'
}

# Ensure the node's firewall exists with exactly the tenant rules; return its ID.
function hcloud::ensure_firewall(){
  local name="$1" rules out fw_id
  rules=$(hcloud::tenant_firewall_rules)
  out=$(hcloud::api GET "/firewalls?name=${name}" 2>/dev/null) || { err "Cannot list firewalls: $(hcloud::last_error)"; return 1; }
  fw_id=$(printf '%s' "$out" | jq -r '.firewalls[0].id // empty')
  if [[ -n "$fw_id" ]]; then
    # The ops project holds other resources: never take over a firewall this script did not label.
    if ! printf '%s' "$out" | jq -e --argjson want "$HCLOUD_LABELS_JSON" \
         '.firewalls[0].labels as $l | all($want | to_entries[]; $l[.key] == .value)' >/dev/null; then
      err "Firewall '${name}' (ID: ${fw_id}) exists without the labels $(jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$HCLOUD_LABELS_JSON"): not this node's; set HCLOUD_FIREWALL_NAME"
      return 1
    fi
    if [[ "$(printf '%s' "$out" | jq -c '.firewalls[0].rules | map({direction, protocol, port, source_ips})')" \
       == "$(printf '%s' "$rules" | jq -c 'map({direction, protocol, port, source_ips})')" ]]; then
      ok "Firewall '${name}' exists with the expected rules (ID: ${fw_id})" >&2
    else
      info "Firewall '${name}' (ID: ${fw_id}) has other rules; setting the tenant rules..."
      hcloud::api POST "/firewalls/${fw_id}/actions/set_rules" "$(jq -cn --argjson rules "$rules" '{rules: $rules}')" >/dev/null \
        || { err "Cannot set firewall rules: $(hcloud::last_error)"; return 1; }
      ok "Firewall rules set"
    fi
    echo "$fw_id"
    return 0
  fi
  info "Creating firewall '${name}' (inbound: udp/41641 only$([[ -n "${HCLOUD_FIREWALL_SSH_CIDRS:-}" ]] && echo ", tcp/22 from ${HCLOUD_FIREWALL_SSH_CIDRS}"))..."
  out=$(hcloud::api POST "/firewalls" "$(jq -cn --arg name "$name" --argjson rules "$rules" --argjson labels "$HCLOUD_LABELS_JSON" \
    '{name: $name, labels: $labels, rules: $rules}')") || { err "Cannot create firewall: $(hcloud::last_error)"; return 1; }
  fw_id=$(printf '%s' "$out" | jq -r '.firewall.id')
  ok "Created firewall '${name}' (ID: ${fw_id})"
  echo "$fw_id"
}

# True when the firewall is applied to the server's public interface.
function hcloud::firewall_applied(){
  local server_id="$1" fw_id="$2" out
  out=$(hcloud::api GET "/servers/${server_id}") || return 1
  printf '%s' "$out" | jq -e --arg fw "$fw_id" \
    'any(.server.public_net.firewalls[]?; (.id | tostring) == $fw and .status == "applied")' >/dev/null
}

function hcloud::apply_firewall(){
  local server_id="$1" fw_id="$2"
  hcloud::api POST "/firewalls/${fw_id}/actions/apply_to_resources" \
    "$(jq -cn --arg id "$server_id" '{apply_to: [{type: "server", server: {id: ($id | tonumber? // $id)}}]}')" >/dev/null \
    || { err "Cannot apply firewall ${fw_id} to server ${server_id}: $(hcloud::last_error)"; return 1; }
}

# Create a server via Hetzner Cloud API
# Usage: hcloud::create_server NAME TYPE IMAGE LOCATION SSH_KEY_ID USER_DATA [FIREWALL_ID]
function hcloud::create_server(){
  local name="$1" server_type="$2" image="$3" location="$4" ssh_key_id="$5" user_data="$6" firewall_id="${7:-}"

  info "Creating Hetzner Cloud server '${name}' (${server_type} in ${location})..."

  # Build request body. A firewall given here is in force from the first boot.
  local request_body
  request_body=$(jq -n \
    --arg name "$name" \
    --arg server_type "$server_type" \
    --arg image "$image" \
    --arg location "$location" \
    --arg ssh_key "$ssh_key_id" \
    --arg user_data "$user_data" \
    --arg firewall "$firewall_id" \
    --argjson labels "$HCLOUD_LABELS_JSON" \
    '{
      name: $name,
      server_type: $server_type,
      image: $image,
      location: $location,
      ssh_keys: [($ssh_key | tonumber? // $ssh_key)],
      user_data: $user_data,
      labels: $labels,
      public_net: {enable_ipv4: true, enable_ipv6: true},
      start_after_create: true
    } + (if $firewall != "" then {firewalls: [{firewall: ($firewall | tonumber? // $firewall)}]} else {} end)') || {
    err "Failed to build server creation request JSON"
    return 1
  }

  local create_out
  set +e
  create_out=$(hcloud::api POST "/servers" "$request_body")
  local create_rc=$?
  set -e
  if [[ $create_rc -ne 0 ]]; then
    err "Failed to create server '${name}'"
    err "API response: $(hcloud::last_error)"
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
  $DRY_RUN && return 0
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
  if $DRY_RUN; then plan "wait until server ${server_id} is running"; return 0; fi
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

# Delete server and wait for the deletion to finish
function hcloud::delete_server(){
  local server_id="$1" out action_id
  info "Deleting server ${server_id}..."
  out=$(hcloud::api DELETE "/servers/${server_id}") || {
    err "Failed to delete server ${server_id}: $(hcloud::last_error)"
    return 1
  }
  action_id=$(printf '%s' "$out" | jq -r '.action.id // empty')
  [[ -n "$action_id" ]] && { hcloud::wait_for_action "$action_id" 180 || return 1; }
  ok "Server ${server_id} deleted"
}

# Set reverse DNS on server's primary IPv4
function hcloud::set_rdns(){
  local server_id="$1" ip="$2" hostname="$3"
  info "Setting reverse DNS for ${ip} -> ${hostname}..."
  hcloud::api POST "/servers/${server_id}/actions/change_dns_ptr" \
    "$(jq -cn --arg ip "$ip" --arg ptr "$hostname" '{ip: $ip, dns_ptr: $ptr}')" >/dev/null 2>&1 || {
    warn "Failed to set reverse DNS (non-fatal)"
    return 0
  }
  ok "Reverse DNS set: ${ip} -> ${hostname}"
}

# ============================================================================
# Tailscale API functions (same pattern as baremetal script)
# ============================================================================

TS_API_TOKEN=""

function tailscale::read_api_token(){
  local ts_file="${ENV_ROOT}/shared/secrets.plain/tailscale-api-key.txt"
  if [[ ! -f "$ts_file" ]]; then
    return 1
  fi
  dbg "Reading Tailscale API token from: $ts_file"
  TS_API_TOKEN=$(tr -d '\n\r' < "$ts_file" | xargs)
  [[ -n "${TS_API_TOKEN:-}" ]]
}

# Usage: tailscale::api METHOD PATH [JSON_BODY]  (dry-run: as hcloud::api)
function tailscale::api(){
  local method="$1" path="$2" data="${3:-}"
  local url="https://api.tailscale.com/api/v2${path}"
  dbg "TAILSCALE ${method} ${url}"

  # POST .../acl/validate only evaluates tests against the live policy and changes nothing: it runs
  # in a dry-run like a GET.
  local read_only=false
  [[ "$method" == GET || ( "$method" == POST && "$path" == */acl/validate ) ]] && read_only=true
  if $DRY_RUN && { ! $read_only || [[ -z "$TS_API_TOKEN" ]] || [[ "$path" == *"<"* ]]; }; then
    plan "TAILSCALE ${method} ${url}${data:+ ${data}}"
    TS_LAST_HTTP="000"; TS_LAST_BODY=""
    if [[ "$method" == POST && "$path" == */keys ]]; then
      printf '%s' '{"key":"<tailscale-auth-key>"}'
    else
      printf '%s' '{}'
    fi
    return 0
  fi

  $DRY_RUN && plan "TAILSCALE ${method} ${url}  (read-only, run)"
  local response http body curl_rc
  local -a data_args=()
  [[ -n "$data" ]] && data_args=(--data-binary "$data")
  set +e
  response=$(curl -sS -X "$method" \
    -K <(printf 'user = "%s:"\n' "$TS_API_TOKEN") \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    "$url" ${data_args[@]+"${data_args[@]}"} -w "\n%{http_code}" 2>&1)
  curl_rc=$?
  set -e

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

# "-" is the API's alias for the tailnet of the key.
function tailscale::get_tailnet(){
  echo "-"
}

# Create a one-off auth key: single use, valid one hour, preauthorized.
# Usage: tailscale::create_authkey HOSTNAME [EPHEMERAL] [PREAUTHORIZED] [TAG]
# With TAG the device joins as that tag (tagged devices have key expiry off by default). Minting a
# tagged key needs the API key's owner to be an admin or an owner of the tag in the tailnet policy
# file (tagOwners).
function tailscale::create_authkey(){
  local hostname="$1"
  local ephemeral="${2:-false}"
  local preauthorized="${3:-true}"
  local tag="${4:-}"

  info "Creating Tailscale auth key for ${hostname}${tag:+ (${tag})}..."

  local safe_hostname json_data out key
  safe_hostname=$(printf '%s' "$hostname" | tr '.' '-' | tr -cd 'A-Za-z0-9-_')
  json_data=$(jq -cn --argjson eph "$ephemeral" --argjson pre "$preauthorized" --arg tag "$tag" --arg desc "Provisioning ${safe_hostname}" '{
    capabilities: {devices: {create: {reusable: false, ephemeral: $eph, preauthorized: $pre,
      tags: (if $tag != "" then [$tag] else [] end)}}},
    expirySeconds: 3600,
    description: ($desc | .[0:50])
  }')

  if out=$(tailscale::api POST "/tailnet/$(tailscale::get_tailnet)/keys" "$json_data"); then
    key=$(printf '%s' "$out" | jq -r '.key // empty' 2>/dev/null)
    if [[ -n "$key" ]]; then
      ok "Created Tailscale auth key"
      echo "$key"
      return 0
    fi
  fi

  warn "Failed to create Tailscale auth key via API (HTTP: ${TS_LAST_HTTP:-unknown}): $(printf '%s' "${TS_LAST_BODY:-}" | jq -r '.message // empty' 2>/dev/null)"
  [[ -n "$tag" ]] && warn "A tagged key needs ${tag} in tagOwners of the tailnet policy, owned by the API key's user (or an admin)"
  return 1
}

# The devices of one node: same hostname, and in tenant mode also carrying the tenant tag, so that
# a same-named device of someone else on a shared tailnet is never matched (or deleted).
function tailscale::devices(){
  local hostname="$1" out
  out=$(tailscale::api GET "/tailnet/$(tailscale::get_tailnet)/devices" 2>/dev/null) || return 0
  printf '%s' "$out" | jq -c --arg h "$hostname" --arg tag "${TAILSCALE_TAG:-}" \
    '.devices[]? | select(.hostname == $h) | select($tag == "" or ((.tags // []) | index($tag)))' 2>/dev/null || true
}

function tailscale::get_device_id(){
  tailscale::devices "$1" | jq -r '.id' | head -1
}

function tailscale::get_device_ip(){
  tailscale::devices "$1" | jq -r '.addresses[]? | select(test("^100\\."))' | head -1
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

# A tagged tenant node is only as isolated as the tailnet policy makes it. The tailnet is segmented
# by tags (INFRA-219): operators (autogroup:member) reach everything, each env's servers carry an
# env tag, and a tenant tag reaches only its cluster server's tcp:6443 (k3s supervisor and API) and
# udp:8472 (flannel VXLAN). Read-only check of the policy and the device list:
#   REFUSE  the tag is not in tagOwners (Tailscale refuses the tagged auth key);
#   REFUSE  a rule whose source can be the node ("*", the tag, autogroup:tagged, a 100.x range
#           wider than /32, 0.0.0.0/0) reaches anything but the cluster server on tcp:6443 or
#           udp:8472 (the tag's other nodes on udp:8472 are allowed too). The server is SERVER_IP,
#           a hosts alias of it, or a tag that only the device with SERVER_IP carries;
#   REFUSE  nothing grants the tag the server's tcp:6443 or udp:8472 (the node could not join);
#   REFUSE  an ssh rule's source can be the node (Tailscale SSH from the tenant node);
#   REFUSE  Tailscale's own evaluator (POST /acl/validate, tests only) fails tailscale::policy_tests;
#   WARN    the evaluator says the server (its first tag, else its address) does not reach the
#           tag on udp:8472 and tcp:10250; the policy has no tests entry for the tag.
# Usage: tailscale::policy_problems TAG SERVER_IP. Prints "REFUSE ..." and "WARN ..." lines; returns
# 1 when there is a REFUSE line. TAILSCALE_POLICY_CHECK=warn downgrades the refusal in
# tenant::preflight (a throwaway test tailnet only). docs/HETZNER-CLOUD-TENANT.md has a policy.
function tailscale::policy_problems(){
  local tag="$1" server_ip="${2%%/*}" policy devices out
  policy=$(tailscale::api GET "/tailnet/$(tailscale::get_tailnet)/acl") || {
    echo "REFUSE cannot read the tailnet policy (HTTP ${TS_LAST_HTTP:-?}): check it by hand"; return 1; }
  devices=$(tailscale::api GET "/tailnet/$(tailscale::get_tailnet)/devices") || {
    echo "REFUSE cannot list the tailnet devices (HTTP ${TS_LAST_HTTP:-?})"; return 1; }
  out=$(jq -rn --slurpfile p <(printf '%s' "$policy") --slurpfile d <(printf '%s' "$devices") \
    --arg tag "$tag" --arg ip "$server_ip" '
    $p[0] as $pol | ($d[0].devices // []) as $devs | ($pol.hosts // {}) as $hosts
    | def ip_of($sel): ($hosts[$sel] // $sel) | tostring | sub("/32$"; "");
      def tag_devices($t): [$devs[] | select((.tags // []) | index($t))];
      def is_server($sel):
        if ($sel | startswith("tag:")) then
          tag_devices($sel) as $td | ($td | length) > 0 and all($td[]; (.addresses // []) | index($ip))
        else ip_of($sel) == $ip end;
      def can_be_node:
        . == "*" or . == $tag or . == "autogroup:tagged" or . == "0.0.0.0/0" or . == "::/0"
        or (test("^100\\.[0-9.]+/[0-9]+$") and ((split("/")[1] | tonumber) < 32));
      def proto: if . == "tcp" or . == "6" then "tcp" elif . == "udp" or . == "17" then "udp" else "" end;
      # Every accept rule as {kind, src, targets: [{sel, ports: ["tcp:6443", "*", ...]}]}.
      def rules:
        ( ($pol.grants // [])[] | . as $g
          | {kind: "grants", src: (.src // []),
             targets: [(.dst // [])[] | {sel: ., ports: ($g.ip // ["<app capabilities>"])}]} ),
        ( ($pol.acls // [])[] | select((.action // "accept") == "accept") | ((.proto // "") | proto) as $pr
          | {kind: "acls", src: (.src // []),
             targets: [(.dst // [])[] | capture("^(?<sel>.*):(?<ports>[^:]*)$")
                       | {sel, ports: (.ports | split(",") | map(if $pr == "" then . else "\($pr):\(.)" end))}]} );
      def allowed($t): ($t.ports - ["tcp:6443", "udp:8472"] | length) == 0 and is_server($t.sel)
                       or ($t.sel == $tag and ($t.ports - ["udp:8472"] | length) == 0);
      def desc: "\(.kind) rule src=\(.src | join(","))";
      ([$devs[] | select((.addresses // []) | index($ip))] | first) as $srv
    | (if (($pol.tagOwners // {}) | has($tag)) then empty
       else "REFUSE \($tag) is not in tagOwners: Tailscale refuses an auth key with it" end),
      (rules | select(any(.src[]; can_be_node)) as $r | $r.targets[] | select(allowed(.) | not)
       | "REFUSE \($r | desc) lets \($tag) reach \(.sel) on \(.ports | join(","))"
         + (if (.sel | startswith("tag:")) and .sel != $tag
            then " (\(.sel) is on: \([tag_devices(.sel)[] | .hostname // "?"] | join(", ") | if . == "" then "no device" else . end))"
            else "" end)),
      ([rules | select(any(.src[]; can_be_node)) | .targets[] | select(is_server(.sel)) | .ports[]] as $granted
       | ("tcp:6443", "udp:8472") | select(. as $want | $granted | index($want) | not)
       | "REFUSE nothing grants \($tag) the cluster server \($ip) on \(.): the node cannot join"),
      (if $srv == null then "WARN no tailnet device has the cluster server address \($ip)" else empty end),
      (($pol.ssh // [])[] | select(any((.src // [])[]; can_be_node))
       | "REFUSE ssh rule src=\(.src | join(",")) lets \($tag) open Tailscale SSH sessions to \((.dst // []) | join(","))"),
      (if any(($pol.tests // [])[]; .src == $tag) then empty
       else "WARN the policy has no tests entry with src \($tag)" end)
  ') || { echo "REFUSE cannot evaluate the tailnet policy (jq)"; return 1; }

  # The same questions put to Tailscale's own evaluator: POST /acl/validate with tests only runs
  # them against the live policy and changes nothing. It answers 200 either way; a "message" in
  # the body means a test failed.
  local tests verdict msg
  tests=$(tailscale::policy_tests "$tag" "$server_ip" "$devices")
  if verdict=$(tailscale::api POST "/tailnet/$(tailscale::get_tailnet)/acl/validate" "$tests"); then
    msg=$(printf '%s' "$verdict" | jq -r '(.message // empty) as $m | if $m == "" then empty
            else ([$m] + ([.data[]? | (.errors // [])[]] | unique) | join("; ")) end' 2>/dev/null)
    [[ -n "$msg" ]] && out+=$'\n'"REFUSE Tailscale's test run ($(jq 'length' <<<"$tests") tests): ${msg}"
  else
    out+=$'\n'"REFUSE cannot run the policy tests (HTTP ${TS_LAST_HTTP:-?})"
  fi

  # The way back, a warning only: the server reaches the node's flannel (udp:8472) and kubelet
  # (tcp:10250, metrics-server and Prometheus). Source: the server's first tag, else its address.
  local server_src
  server_src=$(printf '%s' "$devices" | jq -r --arg ip "$server_ip" \
    '[.devices[]? | select((.addresses // []) | index($ip))] | first | if . == null then empty else ((.tags // [])[0] // $ip) end')
  if [[ -n "$server_src" ]]; then
    tests=$(jq -cn --arg s "$server_src" --arg tag "$tag" \
      '[{src: $s, proto: "udp", accept: ["\($tag):8472"]}, {src: $s, proto: "tcp", accept: ["\($tag):10250"]}]')
    if verdict=$(tailscale::api POST "/tailnet/$(tailscale::get_tailnet)/acl/validate" "$tests"); then
      msg=$(printf '%s' "$verdict" | jq -r '(.message // empty) as $m | if $m == "" then empty
              else ([$m] + ([.data[]? | (.errors // [])[]] | unique) | join("; ")) end' 2>/dev/null)
      [[ -n "$msg" ]] && out+=$'\n'"WARN the cluster server (${server_src}) does not reach ${tag} on udp:8472 and tcp:10250 (pod traffic and metrics from the server would be dropped): ${msg}"
    fi
  fi

  out=$(sed '/^$/d' <<<"$out")
  [[ -n "$out" ]] && printf '%s\n' "$out"
  ! grep -q '^REFUSE' <<<"$out"
}

# Tests for /acl/validate: the tag reaches the cluster server on tcp:6443 and udp:8472 and nothing
# else there (22, 443, 10250, 5432), and no other tailnet device (its own tenant's nodes aside) on
# 22, 443, 6443 or udp:8472. TAILSCALE_DENY_TESTS adds "host:port" destinations it must not reach
# either (subnet routes such as a home LAN, which the device list does not show).
# Usage: tailscale::policy_tests TAG SERVER_IP DEVICES_JSON
function tailscale::policy_tests(){
  jq -cn --slurpfile d <(printf '%s' "$3") --arg tag "$1" --arg ip "$2" --arg extra "${TAILSCALE_DENY_TESTS:-}" '
    [($d[0].devices // [])[] | select((.addresses // []) | index($ip) | not)
     | select((.tags // []) | index($tag) | not) | (.addresses // [])[] | select(test("^100\\."))] as $others
    | ($extra | split(",") | map(split(" ")) | add // [] | map(select(. != ""))) as $x
    | [{src: $tag, proto: "tcp", accept: ["\($ip):6443"],
        deny: ["\($ip):22", "\($ip):443", "\($ip):10250", "\($ip):5432"]},
       {src: $tag, proto: "udp", accept: ["\($ip):8472"]}]
      + (if ($others | length) > 0 then
           [{src: $tag, proto: "tcp", deny: [$others[] | "\(.):22", "\(.):443", "\(.):6443"]},
            {src: $tag, proto: "udp", deny: [$others[] | "\(.):8472"]}]
         else [] end)
      + (if ($x | length) > 0 then [{src: $tag, deny: $x}] else [] end)'
}

function tailscale::cleanup_stale_devices(){
  local hostname="$1"
  if [[ -z "$TS_API_TOKEN" ]] && ! tailscale::read_api_token 2>/dev/null; then
    return 0
  fi
  local device_ids
  device_ids=$(tailscale::devices "$hostname" | jq -r '.id')
  [[ -z "$device_ids" ]] && return 0
  info "Cleaning up stale Tailscale devices for ${hostname}${TAILSCALE_TAG:+ (${TAILSCALE_TAG})}..."
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
  if $DRY_RUN && [[ "$method" != GET ]]; then plan "CLOUDFLARE ${method} ${url} $*"; printf "%s" '{"success":true,"result":[]}'; return 0; fi
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

# Tenant worker: the public interface admits no SSH (Hetzner firewall), so the node must reach the
# tailnet on its own at first boot. cloud-init installs Tailscale and joins with a one-off, one-hour,
# tagged auth key, then deletes the key file and cloud-init's copy of the user data. The key is
# single-use: once the node has joined, the copy Hetzner's metadata service keeps serving is spent.
# Root logs in with no key; admin (passwordless sudo) carries the operator's key.
function gen_cloud_init_tenant(){
  local ssh_pubkey="$1" ts_authkey="$2" node="$3"
  cat <<CLOUDINIT_EOF
#cloud-config
hostname: ${node}
preserve_hostname: false
disable_root: true
ssh_pwauth: false
users:
  - name: admin
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_pubkey}
write_files:
  - path: /run/infra-skills/ts-authkey
    permissions: '0600'
    owner: root:root
    content: ${ts_authkey}
  - path: /usr/local/sbin/infra-skills-tailscale-up
    permissions: '0700'
    owner: root:root
    content: |
      #!/bin/bash
      # Managed by infra-skills (provision-hetzner-cloud.sh --worker): first-boot Tailscale join.
      set -euo pipefail
      trap 'rm -f /run/infra-skills/ts-authkey /var/lib/cloud/instance/user-data.txt /var/lib/cloud/instance/user-data.txt.i' EXIT
      . /etc/os-release
      for i in 1 2 3 4 5 6; do
        curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/\${VERSION_CODENAME}.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg \\
          && curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/\${VERSION_CODENAME}.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list \\
          && break
        sleep 10
      done
      # First boot: unattended-upgrades may hold the dpkg lock; wait for it instead of failing.
      apt-get -o DPkg::Lock::Timeout=600 update -q
      DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -q tailscale
      systemctl enable --now tailscaled
      tailscale up --auth-key=file:/run/infra-skills/ts-authkey --hostname=${node}
      echo "[infra-skills] tailscale up: \$(tailscale ip -4 | head -1)"
runcmd:
  - [/usr/local/sbin/infra-skills-tailscale-up]
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

echo "[postinstall] Starting postinstall provisioning (Hetzner Cloud, @NODE_ROLE@)..."
NODE_ROLE="@NODE_ROLE@"
. /etc/os-release
echo "[postinstall] Step markers stored in: $MARKER_DIR"

# Step 1: Tailscale APT repository
if skip_if_done "01-tailscale-repo" "Tailscale APT repository"; then
  :
else
  echo "[postinstall] Adding Tailscale APT repository ..."
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.noarmor.gpg" | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.tailscale-keyring.list" | sudo tee /etc/apt/sources.list.d/tailscale.list
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
  if [[ "$NODE_ROLE" == "tenant-worker" ]]; then
    # A tenant worker carries only what the k3s agent and the host firewall need.
    apt install -y locales ufw curl iptables apt-transport-https gnupg2 sudo tailscale
  else
    # The HWE kernel metapackage exists per LTS release (linux-generic-hwe-24.04, ...).
    HWE_PKG="linux-generic-hwe-${VERSION_ID}"
    apt-cache show "$HWE_PKG" >/dev/null 2>&1 || HWE_PKG=""
    apt install -y --install-recommends ${HWE_PKG} \
      locales ufw git binutils make \
      libcurl4-openssl-dev libsqlite3-dev curl \
      apt-transport-https gnupg2 sudo kubetail tailscale
  fi
  mark_step "02-apt-update-packages"
fi

# Step 2a: Prevent needrestart from auto-restarting k3s/containerd/cron on package upgrades.
# A k3s restart unmounts /var/lib/rancher/k3s/storage bind mounts and pod
# volume mounts, leaving services (Harbor, Nexus, Loki, Grafana) with stale
# mounts. Restart k3s manually during a maintenance window instead.
# needrestart matches override_rc keys against the full unit name ("k3s.service"),
# so the keys must carry the .service suffix (the earlier ^k3s$ keys never matched).
if skip_if_done "02a-needrestart-override-k3s-v2" "needrestart override for k3s"; then
  :
else
  mkdir -p /etc/needrestart/conf.d
  cat > /etc/needrestart/conf.d/k3s.conf <<'NEEDRESTART_EOF'
# Managed by infra-skills (provision-hetzner-*.sh). Never auto-restart these from needrestart:
# needrestart matches override_rc keys as regexes against the full systemd unit name
# ("k3s.service", not "k3s"), so keys must account for the ".service" suffix.
#  - k3s / k3s-agent: a restart unmounts pod volumes and bind mounts (stale Harbor/Nexus/Loki
#    mounts) and bounces every workload on the node; do it in a maintenance window.
#  - containerd (+ its shims, which live in the k3s unit's cgroup on k3s): same blast radius.
#  - cron: a restart kills in-flight cron jobs (nightly rdiff-backup); it picks up new libs at reboot.
$nrconf{override_rc}{qr(^k3s(-agent)?\.service$)} = 0;
$nrconf{override_rc}{qr(^containerd\.service$)} = 0;
$nrconf{override_rc}{qr(^cron\.service$)} = 0;
NEEDRESTART_EOF
  mark_step "02a-needrestart-override-k3s-v2"
fi

# Step 2b: Bound the apt timers. apt-daily(-upgrade).service default to TimeoutStartSec=infinity,
# so one hung run (a stuck dpkg lock or mirror) keeps the unit "activating" and every later timer
# tick is skipped: hosting got no security updates for six months that way (INFRA-26).
if skip_if_done "02b-apt-daily-timeout" "apt-daily timeout drop-ins"; then
  :
else
  for unit in apt-daily apt-daily-upgrade; do
    mkdir -p "/etc/systemd/system/${unit}.service.d"
    cat > "/etc/systemd/system/${unit}.service.d/timeout.conf" <<'APT_TIMEOUT_EOF'
# Managed by infra-skills (provision-hetzner-*.sh): a hung run must not block every later one.
[Service]
TimeoutStartSec=2h
APT_TIMEOUT_EOF
  done
  systemctl daemon-reload
  mark_step "02b-apt-daily-timeout"
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
# A tenant worker's admin comes from cloud-init with its own key. Copying root's authorized_keys
# would replace that key with cloud-init's disable_root stub and lock admin out.
if skip_if_done "04-admin-user" "Admin user creation"; then
  :
elif [[ "$NODE_ROLE" == "tenant-worker" ]]; then
  echo "[postinstall] Tenant worker: 'admin' comes from cloud-init; nothing to do"
  mark_step "04-admin-user"
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
elif [[ "$NODE_ROLE" == "tenant-worker" ]]; then
  # Tenant worker: no private network, no ingress. The Hetzner Cloud firewall in front already
  # drops every inbound packet but udp/41641; ufw is the same policy on the host, plus the k3s
  # overlay. Everything from the cluster arrives over tailscale0 (API tunnel, kubelet 10250,
  # flannel VXLAN 8472/udp), and what may arrive there is decided by the tailnet policy.
  echo "[postinstall] Preparing UFW rules (tenant worker) ..."
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true
  ufw allow 41641/udp comment 'tailscale direct' >/dev/null 2>&1 || true
  ufw allow in on tailscale0 comment 'allow all via tailscale (tailnet policy decides)' >/dev/null 2>&1 || true
  ufw allow from 10.42.0.0/16 to any comment 'k3s pods' >/dev/null 2>&1 || true
  ufw allow from 10.43.0.0/16 to any comment 'k3s services' >/dev/null 2>&1 || true
  ufw allow in on cni0 comment 'k3s cni0' >/dev/null 2>&1 || true
  ufw allow in on flannel.1 comment 'flannel overlay' >/dev/null 2>&1 || true
  if grep -q '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw 2>/dev/null; then
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
  else
    echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> /etc/default/ufw
  fi
  echo "[postinstall] UFW rules configured (not enabled yet):"
  ufw show added || true
  mark_step "05-ufw-rules"
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
elif [[ "$NODE_ROLE" == "tenant-worker" ]]; then
  echo "[postinstall] Tenant worker: no Cloud Network (the cluster is reached over Tailscale)"
  mark_step "07-cloud-network"
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

    # secrets-encryption: Secrets are stored AES-CBC encrypted in the datastore. k3s generates
    # the key on first start into /var/lib/rancher/k3s/server/cred/encryption-config.json;
    # without that file a datastore backup's Secrets cannot be read, so tools/backup.sh copies
    # server/cred/ along with the datastore. Check: k3s secrets-encrypt status. Turning it on
    # for a running cluster is a separate procedure (k3s secrets-encrypt enable + reencrypt),
    # not something this file does.
    cat >/etc/rancher/k3s/config.yaml <<K3S_EOF
write-kubeconfig-mode: "0600"
secrets-encryption: true
tls-san:
${K3S_TLS_SANS}
node-ip: @PRIVATE_IP_ADDR@
flannel-iface: ${K3S_FLANNEL_IFACE}
K3S_EOF

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

    # Bundled Traefik: HTTP->HTTPS redirect, HSTS, externalTrafficPolicy=Local. Rendered on the
    # provisioning machine by provision::k3s_traefik_config (tools/provision-common.sh) and in
    # place before k3s first starts, so Traefik's first install already has it.
    mkdir -p /var/lib/rancher/k3s/server/manifests
    ( umask 077; cat >/var/lib/rancher/k3s/server/manifests/traefik-config.yaml <<'TRAEFIK_EOF'
@TRAEFIK_CONFIG_YAML@
TRAEFIK_EOF
    )
    echo "[postinstall] Wrote Traefik HelmChartConfig (server/manifests/traefik-config.yaml)"
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
    echo "[postinstall] Installing k3s server @K3S_VERSION@ ..."
    # An empty INSTALL_K3S_VERSION means the stable channel of the day (env.properties K3S_VERSION pins it).
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="@K3S_VERSION@" INSTALL_K3S_SKIP_START=true sh - >/root/k3s-install.log 2>&1 || true
  else
    echo "[postinstall] Worker mode detected; skipping k3s server installation"
  fi
  mark_step "14-k3s-install"
fi

# Step 14b: Configure Traefik (master nodes only)
# The HelmChartConfig from step 13 already declares externalTrafficPolicy: Local, so this patch
# normally changes nothing; it stays as the fallback for a chart that ignores service.spec.
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
  ( umask 077; echo "${adjusted}" > "${out_dir}/kubeconfig.yaml" )
  chmod 600 "${out_dir}/kubeconfig.yaml"
  ok "Wrote kubeconfig to ${out_dir}/kubeconfig.yaml (context: ${ENV_NAME}, server: https://${api_server_host}:6443)"
  # The plaintext is git-ignored; commit the encrypted copy so another checkout can restore it.
  "${REPO_ROOT}/tools/sops/kubeconfig.sh" save "${ENV_NAME}" \
    || warn "Could not save an encrypted copy; run: tools/sops/kubeconfig.sh save ${ENV_NAME}"

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
# env.properties writes
# ============================================================================

# Set KEY=VALUE in ENV_FILE (replace or append). --dry-run prints it instead.
function env_set(){
  local key="$1" val="$2"
  if $DRY_RUN; then plan "set ${key}=${val} in ${ENV_FILE}"; return 0; fi
  if grep -q "^${key}=" "${ENV_FILE}"; then
    local current
    current=$(grep "^${key}=" "${ENV_FILE}" | head -1 | cut -d= -f2-)
    [[ "$current" == "$val" ]] && return 0
    info "Updating ${key} in $(basename "$(dirname "${ENV_FILE}")")/env.properties: ${current:-<empty>} -> ${val:-<empty>}"
    sed -i.bak "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
    rm -f "${ENV_FILE}.bak"
  else
    printf '%s=%s\n' "$key" "$val" >> "${ENV_FILE}"
  fi
}

# ============================================================================
# Tenant worker (--worker): a node in the ops org's Hetzner project, running one tenant's pods,
# that joins the cluster over Tailscale through tools/k3s/join-worker.sh --tenant.
# docs/HETZNER-CLOUD-TENANT.md.
# ============================================================================

# True when a Hetzner resource (JSON with .labels) carries all of this node's labels: the ops
# project holds other servers and firewalls, and only this node's may be changed or deleted.
function tenant::ours(){
  jq -e --argjson want "$HCLOUD_LABELS_JSON" '.labels as $l | all($want | to_entries[]; $l[.key] == .value)' \
    >/dev/null 2>&1 <<<"$1"
}
HCLOUD_LABELS_TEXT=$(jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$HCLOUD_LABELS_JSON")

JOIN_WORKER="${REPO_ROOT}/tools/k3s/join-worker.sh"
CLUSTER_KUBECONFIG="${CLUSTER_DIR}/kubeconfig.yaml"

# Run a command on the node as admin over Tailscale; --dry-run prints it.
function tenant::ssh(){
  local host="$1"; shift
  if $DRY_RUN; then plan "ssh admin@${host} $*"; return 0; fi
  ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" "admin@${host}" "$@"
}

function tenant::kubectl(){
  KUBECONFIG="${CLUSTER_KUBECONFIG}" kubectl "$@"
}

# join-worker.sh with this script's SSH key; the kubeconfig is pinned to the cluster's own file so a
# different current context can never receive the node.
function tenant::join_worker(){
  local -a args=("$ENV_NAME" "$WORKER_NAME" --ssh-user admin)
  [[ -n "${SSH_KEY}" ]] && args+=(--ssh-key "${SSH_KEY}")
  args+=("$@")
  if $DRY_RUN; then plan "KUBECONFIG=${CLUSTER_KUBECONFIG} ${JOIN_WORKER} ${args[*]}"; return 0; fi
  KUBECONFIG="${CLUSTER_KUBECONFIG}" "${JOIN_WORKER}" "${args[@]}"
}

function tenant::preflight(){
  info "Tenant worker ${NODE_NAME} of tenant ${TENANT} for cluster ${ENV_NAME}"
  info "  Hetzner: ${HCLOUD_SERVER_TYPE} in ${HCLOUD_LOCATION}, image ${HCLOUD_IMAGE}, firewall '${HCLOUD_FIREWALL_NAME}'"
  info "  Tailscale: hostname ${NODE_NAME}, tag ${TAILSCALE_TAG}; cluster server ${MASTER_HOSTNAME} (${MASTER_VLAN_IP%%/*})"
  info "  Token: $(hcloud::token_file) (the ops project); labels ${HCLOUD_LABELS_TEXT}"

  if ! hcloud::read_token; then
    if $DRY_RUN; then warn "(--dry-run: continuing without a token; GET calls are printed, not run)"; HCLOUD_TOKEN=""; else return 1; fi
  fi
  if ! tailscale::read_api_token; then
    if $DRY_RUN; then
      warn "(--dry-run: no Tailscale API key; Tailscale calls are printed, not run)"
    else
      err "Tailscale API key not found (${ENV_ROOT}/shared/secrets.plain/tailscale-api-key.txt): a tenant worker is reached only over Tailscale"
      return 1
    fi
  fi

  # join-worker.sh pins REGISTRY_HOSTS to the server's Tailscale IP. The tenant tag is granted
  # no 443 there (and 100.64/10 is a trust signal for platform allowlists): pull over public 443.
  if [[ -n "${REGISTRY_HOSTS:-}" ]] && ! $DESTROY; then
    if $DRY_RUN; then warn "(--dry-run) REGISTRY_HOSTS is set in ${ENV_FILE}: remove it"; else
      err "REGISTRY_HOSTS is set in ${ENV_FILE}: a tenant node pulls images over public 443, not through the server's Tailscale IP (the tag is granted no 443). Remove it."
      return 1
    fi
  fi

  # Only for creating a node: destroy and re-provision must work whatever the policy says.
  if $CREATE_SERVER && ! $DESTROY && [[ -n "$TS_API_TOKEN" ]]; then
    local problems p
    if problems=$(tailscale::policy_problems "$TAILSCALE_TAG" "$MASTER_VLAN_IP"); then
      while IFS= read -r p; do [[ -n "$p" ]] && warn "Tailnet policy: ${p#WARN }"; done <<<"$problems"
      ok "Tailnet policy: ${TAILSCALE_TAG} is owned and confined"
    else
      while IFS= read -r p; do
        case "$p" in
          REFUSE*) err "Tailnet policy: ${p#REFUSE }";;
          WARN*) warn "Tailnet policy: ${p#WARN }";;
        esac
      done <<<"$problems"
      if $DRY_RUN || [[ "${TAILSCALE_POLICY_CHECK:-}" == "warn" ]]; then
        warn "(continuing: $($DRY_RUN && echo --dry-run || echo TAILSCALE_POLICY_CHECK=warn))"
      else
        err "Fix the tailnet policy first (docs/HETZNER-CLOUD-TENANT.md, \"Tailnet policy\"); TAILSCALE_POLICY_CHECK=warn overrides"
        return 1
      fi
    fi
  fi

  if ! $NO_JOIN || $DESTROY; then
    if [[ ! -f "$CLUSTER_KUBECONFIG" ]]; then
      if $DRY_RUN; then warn "(--dry-run) ${CLUSTER_KUBECONFIG} not found"; else
        err "${CLUSTER_KUBECONFIG} not found (restore it: tools/sops/kubeconfig.sh restore ${ENV_NAME}), or use --no-join"; return 1; fi
    fi
    # The tenant join (bootstrap token, tenant registries.yaml, taints) lives in join-worker.sh.
    if ! grep -q -- '--tenant' "$JOIN_WORKER"; then
      if $DRY_RUN; then warn "(--dry-run) ${JOIN_WORKER} has no --tenant yet"; else
        err "${JOIN_WORKER} has no --tenant: it needs the tenant join (infra-skills INFRA-214). Use --no-join until then."; return 1; fi
    fi
  fi
}

function tenant::create(){
  local existing fw_id ssh_key_id ts_authkey user_data fingerprint
  existing=$(hcloud::get_server "${HCLOUD_SERVER_NAME}" 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    HCLOUD_SERVER_ID=$(printf '%s' "$existing" | jq -r '.id')
    HCLOUD_PUBLIC_IP=$(printf '%s' "$existing" | jq -r '.public_net.ipv4.ip // empty')
    ok "Server '${HCLOUD_SERVER_NAME}' already exists (ID: ${HCLOUD_SERVER_ID}, IP: ${HCLOUD_PUBLIC_IP})"
    if ! tenant::ours "$existing"; then
      err "Server '${HCLOUD_SERVER_NAME}' in the ops project lacks the labels ${HCLOUD_LABELS_TEXT}: not this node; refusing to touch it"
      return 1
    fi
    fw_id=$(hcloud::ensure_firewall "${HCLOUD_FIREWALL_NAME}") || return 1
    if ! hcloud::firewall_applied "$HCLOUD_SERVER_ID" "$fw_id"; then
      info "Applying firewall '${HCLOUD_FIREWALL_NAME}' to the server..."
      hcloud::apply_firewall "$HCLOUD_SERVER_ID" "$fw_id" || return 1
    fi
  else
    hcloud::check_server_type "${HCLOUD_SERVER_TYPE}" "${HCLOUD_LOCATION}" || return 1

    fingerprint=$(ssh-keygen -lf "${PROV_SSH_PUB}" 2>/dev/null | awk '{print $2}' | sed 's/^SHA256://' | tr -cd 'A-Za-z0-9' | cut -c1-12)
    ssh_key_id=$(hcloud::create_ssh_key "infra-skills-${fingerprint:-operator}" "${SSH_PUBKEY_CONTENT}") || {
      err "Failed to register SSH key"; return 1; }

    fw_id=$(hcloud::ensure_firewall "${HCLOUD_FIREWALL_NAME}") || return 1

    # A device left by an earlier node of the same name and tag would make the new one "<name>-1".
    tailscale::cleanup_stale_devices "${NODE_NAME}"
    ts_authkey=$(tailscale::create_authkey "${NODE_NAME}" false true "${TAILSCALE_TAG}") || {
      err "No Tailscale auth key: the node would be unreachable (its public interface admits no SSH)"; return 1; }

    user_data=$(gen_cloud_init_tenant "${SSH_PUBKEY_CONTENT}" "${ts_authkey}" "${NODE_NAME}")
    unset ts_authkey
    hcloud::create_server "${HCLOUD_SERVER_NAME}" "${HCLOUD_SERVER_TYPE}" "${HCLOUD_IMAGE}" \
      "${HCLOUD_LOCATION}" "${ssh_key_id}" "${user_data}" "${fw_id}" || return 1
    unset user_data
    hcloud::wait_for_running "${HCLOUD_SERVER_ID}" 180 || return 1
  fi

  # The firewall must be in force before anything listens: refuse to go on without it.
  if ! $DRY_RUN; then
    local i
    for i in $(seq 1 24); do
      hcloud::firewall_applied "$HCLOUD_SERVER_ID" "$fw_id" && break
      sleep 5
    done
    if ! hcloud::firewall_applied "$HCLOUD_SERVER_ID" "$fw_id"; then
      err "Firewall '${HCLOUD_FIREWALL_NAME}' is not applied to server ${HCLOUD_SERVER_ID}; stopping"; return 1
    fi
    ok "Firewall '${HCLOUD_FIREWALL_NAME}' applied (inbound default-deny)"
  else
    plan "check GET /servers/${HCLOUD_SERVER_ID}: public_net.firewalls[] has ${fw_id} with status applied"
  fi

  EXTERNAL_IP="${HCLOUD_PUBLIC_IP}"
  env_set EXTERNAL_IP "${EXTERNAL_IP}"
  # join-worker.sh: SSH straight to VLAN_IP; the public :22 is closed.
  env_set SSH_VIA tailscale
}

function tenant::lookup_server(){
  [[ -n "${HCLOUD_SERVER_ID:-}" ]] && return 0
  local existing
  existing=$(hcloud::get_server "${HCLOUD_SERVER_NAME}" 2>/dev/null || true)
  if [[ -z "$existing" ]]; then
    if $DRY_RUN; then HCLOUD_SERVER_ID="<server-id>"; HCLOUD_PUBLIC_IP="<public-ipv4>"; return 0; fi
    err "Server '${HCLOUD_SERVER_NAME}' not found in the ops project. Run without --provision-only first."
    return 1
  fi
  HCLOUD_SERVER_ID=$(printf '%s' "$existing" | jq -r '.id')
  HCLOUD_PUBLIC_IP=$(printf '%s' "$existing" | jq -r '.public_net.ipv4.ip // empty')
  EXTERNAL_IP="${HCLOUD_PUBLIC_IP}"
}

function tenant::provision(){
  tenant::lookup_server || return 1

  # cloud-init installs Tailscale and joins; wait for the tagged device.
  TAILSCALE_IP=""
  if $DRY_RUN; then
    plan "wait for Tailscale device ${NODE_NAME} with ${TAILSCALE_TAG} (GET /tailnet/-/devices)"
    TAILSCALE_IP=$(tailscale::get_device_ip "${NODE_NAME}" 2>/dev/null || true)
    TAILSCALE_IP="${TAILSCALE_IP:-<tailscale-ip>}"
  else
    info "Waiting for ${NODE_NAME} on the tailnet (cloud-init installs Tailscale; up to 10 min)..."
    local i
    for i in $(seq 1 120); do
      TAILSCALE_IP=$(tailscale::get_device_ip "${NODE_NAME}" 2>/dev/null || true)
      [[ -n "$TAILSCALE_IP" ]] && break
      sleep 5
    done
    if [[ -z "$TAILSCALE_IP" ]]; then
      err "${NODE_NAME} did not appear on the tailnet with ${TAILSCALE_TAG}."
      err "Look at the Hetzner console of server ${HCLOUD_SERVER_ID}: /var/log/cloud-init-output.log"
      return 1
    fi
    ok "Tailscale IP of ${NODE_NAME}: ${TAILSCALE_IP}"
  fi
  env_set VLAN_IP "${TAILSCALE_IP}"

  ssh-keygen -R "${TAILSCALE_IP}" >/dev/null 2>&1 || true
  if ! $DRY_RUN; then
    wait_for_ssh_user "${TAILSCALE_IP}" "${SSH_PORT}" admin 60 || {
      err "No SSH to admin@${TAILSCALE_IP}: the tailnet policy must let this machine reach ${TAILSCALE_TAG}:22"; return 1; }
  fi
  tenant::ssh "${TAILSCALE_IP}" 'cloud-init status --wait >/dev/null 2>&1 || true'

  if ! $DRY_RUN && tenant::ssh "${TAILSCALE_IP}" 'sudo test -f /etc/infra-postinstall.done' 2>/dev/null; then
    info "Postinstall already applied; skipping."
  else
    local content
    content=$(gen_postinstall)
    content=${content//@NODE_ROLE@/${NODE_ROLE}}
    content=${content//@PRIVATE_IP_ADDR@/}
    content=${content//@PUBLIC_HOSTNAME@/${NODE_NAME}}
    content=${content//@EXTERNAL_IP@/${EXTERNAL_IP:-}}
    content=${content//@MASTER_PRIVATE_IP@/}
    content=${content//@WORKER_MODE@/true}
    content=${content//@K3S_VERSION@/}
    content=${content//@TAILSCALE_AUTHKEY@/}
    content=${content//@TRAEFIK_CONFIG_YAML@/}
    info "Running postinstall on ${NODE_NAME} (reboots at the end)..."
    if $DRY_RUN; then
      plan "upload postinstall ($(printf '%s\n' "$content" | wc -l | tr -d ' ') lines, role ${NODE_ROLE}) to admin@${TAILSCALE_IP}:/root/postinstall.sh and run it with sudo; it reboots"
    else
      printf '%s\n' "$content" | tenant::ssh "${TAILSCALE_IP}" 'sudo sh -c "umask 077; cat > /root/postinstall.sh"'
      tenant::ssh "${TAILSCALE_IP}" 'sudo env TERM=xterm bash /root/postinstall.sh' || true
      info "Waiting for the reboot..."
      local i
      for i in $(seq 1 30); do
        ssh -p "${SSH_PORT}" "${SSH_OPTS[@]}" -o ConnectTimeout=5 "admin@${TAILSCALE_IP}" true >/dev/null 2>&1 || break
        sleep 2
      done
      wait_for_ssh_user "${TAILSCALE_IP}" "${SSH_PORT}" admin 60 || { err "${NODE_NAME} did not come back after the reboot"; return 1; }
      tenant::ssh "${TAILSCALE_IP}" 'sudo test -f /etc/infra-postinstall.done' \
        || { err "Postinstall did not complete on ${NODE_NAME}: sudo cat /root/postinstall.sh, rerun with --provision-only"; return 1; }
      ok "Postinstall complete"
    fi
  fi
  tenant::verify "${TAILSCALE_IP}"
}

# What can be checked from here without the cluster: ufw active, Tailscale up with the tag,
# and the public SSH port closed (the Hetzner firewall drops it unless HCLOUD_FIREWALL_SSH_CIDRS).
function tenant::verify(){
  local ts_ip="$1"
  if $DRY_RUN; then
    plan "verify on ${NODE_NAME}: ufw active, tailscale up; from here: ${EXTERNAL_IP:-<public-ipv4>}:22 closed"
    return 0
  fi
  if tenant::ssh "$ts_ip" 'sudo ufw status | head -1' 2>/dev/null | grep -q 'Status: active'; then
    ok "ufw active on ${NODE_NAME}"
  else
    warn "ufw is not active on ${NODE_NAME}"
  fi
  if [[ -z "${HCLOUD_FIREWALL_SSH_CIDRS:-}" && -n "${EXTERNAL_IP:-}" ]]; then
    if nc -z -w 5 "${EXTERNAL_IP}" 22 >/dev/null 2>&1; then
      err "${EXTERNAL_IP}:22 answers from the internet: the Hetzner firewall is not in force"; return 1
    fi
    ok "${EXTERNAL_IP}:22 is closed from the internet"
  fi
}

function tenant::join(){
  info "Joining ${NODE_NAME} to ${ENV_NAME} as a worker of tenant ${TENANT} (join-worker.sh --tenant)..."
  tenant::join_worker --tenant "$TENANT"
}

function tenant::destroy(){
  local existing server_id fw_out fw_id
  echo -e "${RED}WARNING: This will remove node '${NODE_NAME}' from cluster ${ENV_NAME} and permanently delete server '${HCLOUD_SERVER_NAME}' in the ops Hetzner project${NC}" >&2
  if $DRY_RUN; then
    plan "confirm: type the server name ${HCLOUD_SERVER_NAME}"
  else
    local confirm="$DESTROY_CONFIRM"
    [[ -z "$confirm" ]] && read -rp "Type the server name to confirm deletion [${HCLOUD_SERVER_NAME}]: " confirm
    if [[ "$confirm" != "$HCLOUD_SERVER_NAME" ]]; then
      err "Confirmation failed. Aborting."; return 1
    fi
  fi

  existing=$(hcloud::get_server "${HCLOUD_SERVER_NAME}" 2>/dev/null || true)
  if [[ -n "$existing" ]] && ! tenant::ours "$existing"; then
    err "Server '${HCLOUD_SERVER_NAME}' lacks the labels ${HCLOUD_LABELS_TEXT}: refusing to delete what this script did not create"
    return 1
  fi

  # 1. Out of the cluster first: drain and delete the node object, stop the agent.
  if $DRY_RUN || tenant::kubectl get node "${NODE_NAME}" >/dev/null 2>&1; then
    tenant::join_worker --remove || { err "join-worker.sh --remove failed; the server is kept"; return 1; }
  else
    info "Node ${NODE_NAME} is not in cluster ${ENV_NAME}"
  fi

  # 2. The server.
  if [[ -n "$existing" ]]; then
    server_id=$(printf '%s' "$existing" | jq -r '.id')
    hcloud::delete_server "$server_id" || return 1
  elif $DRY_RUN; then
    hcloud::delete_server "<server-id>"
  else
    warn "Server '${HCLOUD_SERVER_NAME}' not found in the ops project"
  fi

  # 3. Its firewall (only one this script labelled for this node and tenant).
  fw_out=$(hcloud::api GET "/firewalls?name=${HCLOUD_FIREWALL_NAME}" 2>/dev/null || echo '{}')
  fw_id=""
  if tenant::ours "$(printf '%s' "$fw_out" | jq -c '.firewalls[0] // {}')"; then
    fw_id=$(printf '%s' "$fw_out" | jq -r '.firewalls[0].id')
  elif [[ "$(printf '%s' "$fw_out" | jq -r '.firewalls | length' 2>/dev/null)" -gt 0 ]]; then
    warn "Firewall '${HCLOUD_FIREWALL_NAME}' lacks the labels ${HCLOUD_LABELS_TEXT}: left in place"
  fi
  $DRY_RUN && [[ -z "$fw_id" ]] && fw_id="<firewall-id>"
  if [[ -n "$fw_id" ]]; then
    local i
    for i in 1 2 3 4 5 6; do
      hcloud::api DELETE "/firewalls/${fw_id}" >/dev/null 2>&1 && { ok "Deleted firewall '${HCLOUD_FIREWALL_NAME}'"; break; }
      # still in use until the server deletion has detached it
      [[ $i -eq 6 ]] && warn "Could not delete firewall ${fw_id}: $(hcloud::last_error)"
      sleep 5
    done
  fi

  # 4. The tailnet device(s) of this node, with the tenant tag only.
  tailscale::cleanup_stale_devices "${NODE_NAME}"

  env_set VLAN_IP ""
  env_set EXTERNAL_IP ""
  info "Left in place: the operator's SSH key 'infra-skills-*' in the ops project (free; shared by every node)"
  ok "Destroy complete"
}

function tenant::main(){
  tenant::preflight || exit 1
  if $DESTROY; then
    tenant::destroy || exit 1
    exit 0
  fi
  if $CREATE_SERVER; then tenant::create || exit 1; fi
  if $PROVISION_SERVER; then
    tenant::provision || exit 1
    if $NO_JOIN; then
      info "--no-join: join later with: KUBECONFIG=${CLUSTER_KUBECONFIG} ${JOIN_WORKER} ${ENV_NAME} ${WORKER_NAME} --tenant ${TENANT} --ssh-user admin"
    else
      tenant::join || exit 1
    fi
  fi
  ok "Tenant worker ${NODE_NAME} done$($DRY_RUN && echo ' (dry-run: nothing was changed)')"
  info "Server: ${HCLOUD_SERVER_NAME} (${HCLOUD_PUBLIC_IP:-unknown}), Tailscale: ${TAILSCALE_IP:-unknown}"
  exit 0
}

# ============================================================================
# MAIN FLOW
# ============================================================================

# Validate required tools
provision::require_tools || exit 1
if ! command -v curl >/dev/null 2>&1; then err "curl is required"; exit 1; fi

# Tenant worker: its own flow (create, provision over Tailscale, join-worker.sh --tenant)
if $TENANT_MODE; then
  tenant::main
fi

# Read Hetzner Cloud token
if ! hcloud::read_token; then
  if $DRY_RUN; then warn "(--dry-run: continuing without a token; GET calls are printed, not run)"; HCLOUD_TOKEN=""; else exit 1; fi
fi

# --- DESTROY MODE ---
if $DESTROY; then
  echo -e "${RED}WARNING: This will permanently delete the server '${HCLOUD_SERVER_NAME}'${NC}"
  echo -e "${RED}All data on the server will be lost!${NC}"
  confirm="$DESTROY_CONFIRM"
  if $DRY_RUN; then confirm="$HCLOUD_SERVER_NAME"; plan "confirm: type the server name ${HCLOUD_SERVER_NAME}"; fi
  [[ -z "$confirm" ]] && read -rp "Type the server name to confirm deletion [${HCLOUD_SERVER_NAME}]: " confirm
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
    hcloud::check_server_type "${HCLOUD_SERVER_TYPE}" "${HCLOUD_LOCATION}" || exit 1

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
  if [[ -n "${HCLOUD_PUBLIC_IP:-}" ]]; then
    EXTERNAL_IP="${HCLOUD_PUBLIC_IP}"
    env_set EXTERNAL_IP "${EXTERNAL_IP}"
    ok "Server public IP: ${EXTERNAL_IP}"
  fi

  # DNS setup
  if ! $SKIP_DNS && [[ -n "${EXTERNAL_IP:-}" ]]; then
    info "Setting up Cloudflare DNS records..."
    dns::setup_cloudflare "${EXTERNAL_IP}" || warn "DNS setup failed (non-fatal)"
  fi
fi

# --- PROVISIONING ---
if $DRY_RUN && $PROVISION_SERVER; then
  plan "provision ${HCLOUD_SERVER_NAME} over SSH (postinstall as ${NODE_ROLE}, k3s, kubeconfig): not simulated further"
  PROVISION_SERVER=false
fi
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
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@NODE_ROLE@/${NODE_ROLE}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@K3S_VERSION@/${K3S_VERSION:-}}
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@TAILSCALE_AUTHKEY@/${TAILSCALE_AUTHKEY}}
    TRAEFIK_CONFIG_YAML=$(provision::k3s_traefik_config) || exit 1
    POSTINSTALL_CONTENT=${POSTINSTALL_CONTENT//@TRAEFIK_CONFIG_YAML@/${TRAEFIK_CONFIG_YAML}}

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
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION:-}" INSTALL_K3S_EXEC="agent \
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
