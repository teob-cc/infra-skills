#!/usr/bin/env bash
# Common helpers for provisioning scripts
# Do NOT set -euo pipefail here because this file is sourced by other scripts
# and we don't want to alter their shell options unexpectedly.

# Compute repo root relative to the caller script that sourced this file.
# Usage: provision::repo_root
provision::repo_root() {
  # BASH_SOURCE[0] is this file; BASH_SOURCE[1] is the immediate caller
  local caller_dir
  caller_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" &>/dev/null && pwd)
  cd -- "${caller_dir}/.." >/dev/null 2>&1 && pwd
}

# Simple log helpers (kept quiet: no colors, no set -e)
provision::info() { echo "[info] $*" >&2; }
provision::warn() { echo "[warn] $*" >&2; }
provision::error() { echo "[error] $*" >&2; }

# Validate required tools are installed
# Usage: provision::require_tools
# This should be called early in provisioning scripts to ensure yq and jq are available
provision::require_tools() {
  local missing=()
  
  if ! command -v yq >/dev/null 2>&1; then
    missing+=("yq")
  fi
  
  if ! command -v jq >/dev/null 2>&1; then
    missing+=("jq")
  fi
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    provision::error "Required tools not found: ${missing[*]}"
    provision::error ""
    provision::error "Please install the missing tools:"
    for tool in "${missing[@]}"; do
      case "$tool" in
        yq)
          provision::error "  yq: https://github.com/mikefarah/yq#install"
          provision::error "      brew install yq  (macOS)"
          provision::error "      or: go install github.com/mikefarah/yq/v4@latest"
          ;;
        jq)
          provision::error "  jq: https://stedolan.github.io/jq/download/"
          provision::error "      brew install jq  (macOS)"
          provision::error "      apt-get install jq  (Ubuntu/Debian)"
          ;;
      esac
    done
    return 1
  fi
  
  return 0
}

# Parse YAML value from file using yq
# Usage: provision::yaml_get <file> <key>
# Example: provision::yaml_get /path/to/file.yaml .stringData.githubOrg
# For multi-line values like private keys: provision::yaml_get file.yaml .stringData.githubAppPrivateKey
provision::yaml_get() {
  local file="$1" key="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  yq eval "$key" "$file" 2>/dev/null || true
}

# Parse JSON value using jq
# Usage: provision::json_get <json_string> <jq_expression>
# Example: provision::json_get "$response" '.token'
provision::json_get() {
  local json="$1" expr="$2"
  printf '%s' "$json" | jq -r "$expr" 2>/dev/null || true
}

# Determine the default SSH key paths (returns base path without .pub)
# Preference: id_ed25519, fallback: id_rsa
provision::default_ssh_key_base() {
  local ssh_dir pub base
  ssh_dir="${HOME}/.ssh"
  for base in "${ssh_dir}/id_ed25519" "${ssh_dir}/id_rsa"; do
    if [[ -f "${base}" && -f "${base}.pub" ]]; then
      echo "${base}"
      return 0
    fi
  done
  return 1
}

# Print SSH public key fingerprint (if ssh-keygen is available)
provision::ssh_pub_fingerprint() {
  local pub="$1"
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -lf "$pub" 2>/dev/null || true
  else
    echo "$pub (ssh-keygen not found)"
  fi
}

# Determine default SOPS age private key file
provision::default_age_key_file() {
  if [[ -n "${SOPS_AGE_KEY_FILE:-}" ]]; then
    echo "$SOPS_AGE_KEY_FILE"
  else
    echo "${HOME}/.config/sops/age/keys.txt"
  fi
}

# Print age public recipients derived from a keys.txt (non-sensitive)
# If multiple private keys are present, prints all corresponding recipients.
provision::age_list_public_recipients() {
  local keyfile="$1"
  if ! command -v age-keygen >/dev/null 2>&1; then
    echo "age-keygen not found"
    return 0
  fi
  if [[ ! -f "$keyfile" ]]; then
    echo "(no key file)"
    return 0
  fi
  # Extract each AGE-SECRET-KEY line and derive its public key
  local line tmp pub
  while IFS= read -r line; do
    [[ "$line" == AGE-SECRET-KEY-* ]] || continue
    tmp=$(mktemp) || { echo "(tmpfile error)"; continue; }
    printf '%s\n' "$line" > "$tmp"
    pub=$(age-keygen -y "$tmp" 2>/dev/null || true)
    rm -f "$tmp"
    [[ -n "$pub" ]] && echo "$pub"
  done < "$keyfile"
}

# Validate local default SSH and SOPS keys; print non-sensitive info
# Returns 0 if both are present, 1 otherwise.
provision::validate_local_keys() {
  local ok=0

  # SSH
  local ssh_base ssh_pub
  if ssh_base=$(provision::default_ssh_key_base); then
    ssh_pub="${ssh_base}.pub"
    provision::info "Found SSH public key: ${ssh_pub}"
    provision::info "SSH fingerprint: $(provision::ssh_pub_fingerprint "$ssh_pub")"
  else
    provision::warn "Default SSH key not found (~/.ssh/id_ed25519 or id_rsa)."
    ok=1
  fi

  # SOPS/age
  local age_file
  age_file=$(provision::default_age_key_file)
  if [[ -f "$age_file" ]]; then
    provision::info "Found SOPS age key file: ${age_file}"
    provision::info "Age public recipients:"
    provision::age_list_public_recipients "$age_file"
  else
    provision::warn "SOPS age key file not found: ${age_file}"
    provision::warn "Set SOPS_AGE_KEY_FILE or create ${HOME}/.config/sops/age/keys.txt"
    ok=1
  fi

  return $ok
}

# Compute envs/ directory path.
# Resolution order:
#   1. INFRA_ENVS_ROOT env var (explicit override)
#   2. Sibling checkout: ../infra-envs/envs (split-repo layout)
#   3. Legacy: envs/ inside the same repo (monorepo layout)
# Usage: provision::envs_root
provision::envs_root() {
  if [[ -n "${INFRA_ENVS_ROOT:-}" ]]; then
    echo "${INFRA_ENVS_ROOT}"
    return
  fi
  local rr
  rr=$(provision::repo_root)
  # New layout: infra-envs checked out as sibling
  if [[ -d "${rr}/../infra-envs/envs" ]]; then
    echo "$(cd "${rr}/../infra-envs/envs" && pwd)"
    return
  fi
  # Legacy: envs/ inside same repo
  echo "${rr}/envs"
}

# Resolve a Helm chart directory, allowing an envs-repo override.
# Usage: provision::chart_path NAME  -> echoes the chart directory
# Precedence: envs/shared/apps/<NAME> (per-installation customization override)
# over the chart bundled with infra-skills at charts/<NAME>.
provision::chart_path() {
  local name=$1
  local override
  override="$(provision::envs_root)/shared/apps/${name}"
  if [[ -d "$override" ]]; then
    echo "$override"
    return 0
  fi
  # infra-skills root relative to this file (tools/provision-common.sh)
  local tools_root
  tools_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)
  local bundled="${tools_root}/charts/${name}"
  if [[ -d "$bundled" ]]; then
    echo "$bundled"
    return 0
  fi
  provision::error "Chart '${name}' not found (looked in ${override} and ${bundled})"
  return 1
}

# Optionally load envs/<env>/env.properties if the first argument looks like an env name
# and the file exists. Sets ENV_NAME and sources the file into the caller's environment.
# returns 1 if nothing was loaded and arguments should remain unchanged.
# Usage in caller scripts:
#   # after computing REPO_ROOT if needed
#   source "$REPO_ROOT/tools/provision-common.sh"
#   if provision::load_env "${1:-}"; then shift; fi
provision::load_env() {
  local first_arg=${1:-}
  if [[ -z "$first_arg" ]]; then
    return 1
  fi
  # treat arguments starting with '-' as flags, not env names
  if [[ ${first_arg:0:1} == '-' ]]; then
    return 1
  fi
  local envs_root
  envs_root=$(provision::envs_root)
  local env_file="${envs_root}/${first_arg}/env.properties"
  if [[ -f "$env_file" ]]; then
    ENV_NAME="$first_arg"
    # shellcheck disable=SC1090
    source "$env_file"
    export ENV_NAME
    return 0
  fi
  return 1
}

# Validate that kubectl context matches the environment being provisioned
# Usage: provision::validate_kubectl_context
# Requires ENV_NAME to be set
# Returns 0 if context matches, 1 otherwise and prints error with instructions
provision::validate_kubectl_context() {
  if [[ -z "${ENV_NAME:-}" ]]; then
    provision::error "ENV_NAME not set - cannot validate kubectl context"
    return 1
  fi
  
  if ! command -v kubectl >/dev/null 2>&1; then
    provision::warn "kubectl not found - skipping context validation"
    return 0
  fi
  
  local current_context
  current_context=$(kubectl config current-context 2>/dev/null || echo "")
  
  if [[ -z "$current_context" ]]; then
    provision::error "No kubectl context is currently set"
    provision::error ""
    provision::error "Available contexts:"
    kubectl config get-contexts -o name 2>/dev/null | sed 's/^/  /' || true
    provision::error ""
    provision::error "To switch context, run:"
    provision::error "  kubectl config use-context <context-name>"
    return 1
  fi
  
  # Check if current context name contains the environment name
  # This handles contexts like "default", "k3s-cit", "cit", etc.
  if [[ "$current_context" != *"$ENV_NAME"* ]]; then
    provision::error "kubectl context mismatch!"
    provision::error ""
    provision::error "  Environment:     ${ENV_NAME}"
    provision::error "  Current context: ${current_context}"
    provision::error ""
    provision::error "Available contexts:"
    kubectl config get-contexts -o name 2>/dev/null | sed 's/^/  /' || true
    provision::error ""
    provision::error "To switch to the correct context, run:"
    provision::error "  kubectl config use-context <context-name>"
    provision::error ""
    provision::error "Expected context name to contain: ${ENV_NAME}"
    return 1
  fi
  
  provision::info "kubectl context validated: ${current_context} (matches ${ENV_NAME})"
  return 0
}

# --- Cloudflare DNS Management ---
# Read Cloudflare API token from secrets file
# Sets CF_API_TOKEN global variable if successful
provision::cloudflare_read_token() {
  local envs_root
  envs_root=$(provision::envs_root)
  local cf_file="${envs_root}/shared/secrets.plain/cloudflare.yaml"
  if [[ ! -f "$cf_file" ]]; then
    return 1
  fi
  
  # Try multiple parsing strategies for YAML
  # 1. Look for 'cloudflare-api-token: <value>' or similar
  CF_API_TOKEN=$(grep -iE '^[[:space:]]*(cloudflare[-_]?api[-_]?token|api[-_]?token|token|api[-_]?key)[[:space:]]*:[[:space:]]*' "$cf_file" | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)
  
  # 2. If not found, try looking for any line with a token-like value (long alphanumeric string)
  if [[ -z "${CF_API_TOKEN:-}" || "${CF_API_TOKEN}" == "cloudflare-api-token" ]]; then
    CF_API_TOKEN=$(grep -oE '[A-Za-z0-9_-]{32,}' "$cf_file" | head -1)
  fi
  
  if [[ -z "${CF_API_TOKEN:-}" || "${CF_API_TOKEN}" == "cloudflare-api-token" ]]; then
    return 1
  fi
  
  [[ -n "${CF_API_TOKEN:-}" ]]
}

# Curl wrapper for Cloudflare API
# Usage: provision::cloudflare_api METHOD PATH [curl-args...]
provision::cloudflare_api() {
  local method="$1" path="$2"; shift 2
  local url="https://api.cloudflare.com/client/v4${path}"
  local response
  response=$(curl -sS -X "$method" "$url" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@")
  printf "%s" "$response"
}

# Create or update a DNS A record in Cloudflare
# Usage: provision::cloudflare_create_or_update_dns_record ZONE_ID NAME IP
provision::cloudflare_create_or_update_dns_record() {
  local zone_id="$1" name="$2" ip="$3"
  
  # Require jq for JSON parsing
  if ! command -v jq >/dev/null 2>&1; then
    provision::warn "jq is required for Cloudflare DNS management. Install jq and retry."
    return 1
  fi
  
  # Check if record exists
  local existing record_id
  existing=$(provision::cloudflare_api GET "/zones/${zone_id}/dns_records?type=A&name=${name}" 2>/dev/null)
  record_id=$(printf '%s' "$existing" | jq -r '.result[0].id // empty' 2>/dev/null)
  
  if [[ -n "$record_id" && "$record_id" != "null" ]]; then
    # Record exists, check if IP matches
    local current_ip
    current_ip=$(printf '%s' "$existing" | jq -r '.result[0].content // empty' 2>/dev/null)
    if [[ "$current_ip" == "$ip" ]]; then
      provision::info "DNS record already correct: ${name} -> ${ip}"
      return 0
    else
      provision::info "Updating DNS record: ${name} from ${current_ip} to ${ip}"
      local update_response
      update_response=$(provision::cloudflare_api PUT "/zones/${zone_id}/dns_records/${record_id}" \
        -d "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}" 2>/dev/null)
      if printf '%s' "$update_response" | jq -e '.success == true' >/dev/null 2>&1; then
        provision::info "Updated DNS record: ${name} -> ${ip}"
        return 0
      else
        provision::warn "Failed to update DNS record: ${name}"
        return 1
      fi
    fi
  else
    # Record doesn't exist, create it
    provision::info "Creating DNS record: ${name} -> ${ip}"
    local create_response
    create_response=$(provision::cloudflare_api POST "/zones/${zone_id}/dns_records" \
      -d "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":false}" 2>/dev/null)
    if printf '%s' "$create_response" | jq -e '.success == true' >/dev/null 2>&1; then
      provision::info "Created DNS record: ${name} -> ${ip}"
      return 0
    else
      provision::warn "Failed to create DNS record: ${name}"
      return 1
    fi
  fi
}

# Ensure a DNS A record exists in Cloudflare for the given hostname and IP
# Usage: provision::cloudflare_ensure_dns_record HOSTNAME IP
# This function derives the zone from HOSTNAME and creates/updates the A record
# Skips creation if a wildcard record already covers this hostname
provision::cloudflare_ensure_dns_record() {
  local hostname="$1" ip="$2"
  
  # Read Cloudflare API token
  if ! provision::cloudflare_read_token; then
    provision::warn "Cloudflare API token not found. Skipping DNS record creation for ${hostname}"
    return 1
  fi
  
  # Require jq for JSON parsing
  if ! command -v jq >/dev/null 2>&1; then
    provision::warn "jq is required for Cloudflare DNS management. Install jq and retry."
    return 1
  fi
  
  # Derive base domain (last two labels: domain.tld)
  local base_domain
  base_domain=$(printf '%s' "$hostname" | awk -F. '{if (NF>=2){print $(NF-1)"."$NF}else{print $0}}')
  
  # Find Cloudflare zone ID for the base domain
  local zones_response zone_id
  zones_response=$(provision::cloudflare_api GET "/zones?name=${base_domain}" 2>/dev/null)
  zone_id=$(printf '%s' "$zones_response" | jq -r '.result[0].id // empty' 2>/dev/null)
  
  if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
    provision::warn "Cloudflare zone not found for domain: ${base_domain}"
    return 1
  fi
  
  # Check for wildcard record that would cover this hostname
  # Extract parent domain for wildcard check (e.g., dex.env.domain.com -> *.env.domain.com)
  local parent_wildcard
  parent_wildcard=$(printf '%s' "$hostname" | awk -F. '{if (NF>2){printf "*." ; for(i=2;i<=NF;i++){printf "%s",$i; if(i<NF)printf "."}}else{print $0}}')
  
  if [[ "$parent_wildcard" != "$hostname" ]]; then
    local wildcard_check
    wildcard_check=$(provision::cloudflare_api GET "/zones/${zone_id}/dns_records?type=A&name=${parent_wildcard}" 2>/dev/null)
    local wildcard_exists
    wildcard_exists=$(printf '%s' "$wildcard_check" | jq -r '.result[0].id // empty' 2>/dev/null)
    
    if [[ -n "$wildcard_exists" && "$wildcard_exists" != "null" ]]; then
      local wildcard_ip
      wildcard_ip=$(printf '%s' "$wildcard_check" | jq -r '.result[0].content // empty' 2>/dev/null)
      provision::info "Skipping DNS record for ${hostname}: wildcard ${parent_wildcard} -> ${wildcard_ip} already exists"
      return 0
    fi
  fi
  
  # Create or update the DNS record
  provision::cloudflare_create_or_update_dns_record "$zone_id" "$hostname" "$ip"
}

# Check if a wildcard DNS record exists for a given hostname
# Usage: provision::cloudflare_check_wildcard HOSTNAME
# Returns 0 if wildcard exists, 1 otherwise
# Sets WILDCARD_PATTERN and WILDCARD_IP global variables if found
provision::cloudflare_check_wildcard() {
  local hostname="$1"
  
  # Read Cloudflare API token
  if ! provision::cloudflare_read_token; then
    return 1
  fi
  
  # Require jq for JSON parsing
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  
  # Derive wildcard pattern (*.hostname)
  WILDCARD_PATTERN="*.${hostname}"
  
  # Derive base domain (last two labels: domain.tld)
  local base_domain
  base_domain=$(printf '%s' "$hostname" | awk -F. '{if (NF>=2){print $(NF-1)"."$NF}else{print $0}}')
  
  # Find Cloudflare zone ID for the base domain
  local zones_response zone_id
  zones_response=$(provision::cloudflare_api GET "/zones?name=${base_domain}" 2>/dev/null || true)
  zone_id=$(printf '%s' "$zones_response" | jq -r '.result[0].id // empty' 2>/dev/null || true)
  
  if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
    return 1
  fi
  
  # Check for wildcard record
  local wildcard_check wildcard_id
  wildcard_check=$(provision::cloudflare_api GET "/zones/${zone_id}/dns_records?type=A&name=${WILDCARD_PATTERN}" 2>/dev/null || true)
  wildcard_id=$(printf '%s' "$wildcard_check" | jq -r '.result[0].id // empty' 2>/dev/null || true)
  
  if [[ -n "$wildcard_id" && "$wildcard_id" != "null" ]]; then
    WILDCARD_IP=$(printf '%s' "$wildcard_check" | jq -r '.result[0].content // empty' 2>/dev/null || true)
    return 0
  fi
  
  return 1
}


# --- DNS vertical (provider-neutral entry points) ------------------------------
# The platform's only DNS needs are "make NAME resolve to IP" and "is NAME
# covered by a wildcard record". Scripts should call these provision::dns_*
# functions rather than a provider function directly; the provider behind them
# is selected by DNS_PROVIDER (default: cloudflare). Adding a provider means
# implementing these two operations for it -- see docs/VERTICALS.md.

# Usage: provision::dns_ensure_record HOSTNAME IP
provision::dns_ensure_record() {
  case "${DNS_PROVIDER:-cloudflare}" in
    cloudflare) provision::cloudflare_ensure_dns_record "$@" ;;
    *)
      provision::error "Unknown DNS_PROVIDER '${DNS_PROVIDER}' (see docs/VERTICALS.md)"
      return 1
      ;;
  esac
}

# Usage: provision::dns_check_wildcard HOSTNAME  (sets WILDCARD_IP on success)
provision::dns_check_wildcard() {
  case "${DNS_PROVIDER:-cloudflare}" in
    cloudflare) provision::cloudflare_check_wildcard "$@" ;;
    *)
      provision::error "Unknown DNS_PROVIDER '${DNS_PROVIDER}' (see docs/VERTICALS.md)"
      return 1
      ;;
  esac
}

# --- GitHub credentials (App + OAuth) -----------------------------------------
# Reads consolidated github-oauth-credentials.yaml and
# Read GitHub credentials from plain secrets files.
# Sets global variables:
#   GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY (from github-app-credentials.yaml)
#   GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, GITHUB_ORG (from github-oauth-credentials.yaml if ENV_NAME is set)
# Returns 0 if GitHub App credentials are present.
provision::github_read_credentials() {
  local envs_root app_file oauth_file
  envs_root=$(provision::envs_root)
  app_file="${envs_root}/shared/secrets.plain/github-app-credentials.yaml"
  
  if [[ ! -f "$app_file" ]]; then
    provision::warn "GitHub app credentials file not found: $app_file"
    return 1
  fi
  
  # Read GitHub App credentials (required)
  GITHUB_APP_ID=$(provision::yaml_get "$app_file" .stringData.githubAppID)
  GITHUB_APP_INSTALLATION_ID=$(provision::yaml_get "$app_file" .stringData.githubAppInstallationID)
  GITHUB_APP_PRIVATE_KEY=$(provision::yaml_get "$app_file" .stringData.githubAppPrivateKey)
  
  # Read OAuth credentials from environment-specific file (optional)
  if [[ -n "${ENV_NAME:-}" ]]; then
    oauth_file="${envs_root}/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
    if [[ -f "$oauth_file" ]]; then
      GITHUB_CLIENT_ID=$(provision::yaml_get "$oauth_file" .stringData.githubClientID)
      GITHUB_CLIENT_SECRET=$(provision::yaml_get "$oauth_file" .stringData.githubClientSecret)
      GITHUB_ORG=${GITHUB_ORG:-$(provision::yaml_get "$oauth_file" .stringData.githubOrg)}
    fi
  fi

  [[ -n "$GITHUB_APP_ID" && -n "$GITHUB_APP_INSTALLATION_ID" && -n "$GITHUB_APP_PRIVATE_KEY" ]]
}

# Create a short-lived GitHub App JWT using openssl
provision::github_app_mint_jwt() {
  local app_id="$1" private_key_pem="$2"
  if ! command -v openssl >/dev/null 2>&1; then
    provision::warn "openssl is required to mint GitHub App JWT"
    return 1
  fi
  local header payload now iat exp unsigned signature jwt
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  now=$(date +%s)
  iat=$((now-60))
  exp=$((now+540))
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$iat" "$exp" "$app_id" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  unsigned="${header}.${payload}"
  signature=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign <(printf '%s' "$private_key_pem") -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  jwt="${unsigned}.${signature}"
  printf '%s' "$jwt"
}

# Validate credentials: obtain installation token and check org accessibility.
provision::github_validate_credentials() {
  local api_url="${GITHUB_API_URL:-https://api.github.com}"
  local ok=0

  if ! provision::github_read_credentials; then
    provision::warn "Failed to read GitHub app credentials"
    return 1
  fi
  # OAuth credentials are optional for validation (only needed for SSO)
  if [[ -z "${GITHUB_ORG:-}" ]]; then
    provision::info "GITHUB_ORG not set. Skipping org accessibility check."
    provision::info "Set ENV_NAME to load OAuth credentials from envs/\${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
  fi

  local jwt
  jwt=$(provision::github_app_mint_jwt "$GITHUB_APP_ID" "$GITHUB_APP_PRIVATE_KEY") || {
    provision::warn "Failed to mint GitHub App JWT"
    return 1
  }

  if ! command -v curl >/dev/null 2>&1; then
    provision::warn "curl is required to validate GitHub credentials"
    return 1
  fi

  local install_token_response install_token
  install_token_response=$(curl -sS -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "${api_url}/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens")
  install_token=$(printf '%s' "$install_token_response" | jq -r '.token // empty' 2>/dev/null)
  if [[ -z "$install_token" || "$install_token" == "null" ]]; then
    provision::warn "Failed to obtain GitHub App installation token"
    return 1
  fi

  # Optionally check org accessibility if org specified
  if [[ -n "${GITHUB_ORG:-}" ]]; then
    local org_resp
    org_resp=$(curl -sS -H "Authorization: token ${install_token}" -H "Accept: application/vnd.github+json" "${api_url}/orgs/${GITHUB_ORG}")
    local message
    message=$(printf '%s' "$org_resp" | jq -r '.message // empty' 2>/dev/null)
    if [[ "$message" == "Not Found" || "$message" == "Resource not accessible by integration" ]]; then
      provision::warn "Installation token cannot access org '${GITHUB_ORG}'"
      ok=1
    fi
  fi

  if [[ $ok -ne 0 ]]; then
    return 1
  fi
  return 0
}

# Get GitHub App installation token
# Usage: provision::github_get_installation_token
# Requires: GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY to be set
# Returns: Installation token via stdout
provision::github_get_installation_token() {
  local api_url="${GITHUB_API_URL:-https://api.github.com}"
  
  if ! provision::github_read_credentials; then
    provision::error "Failed to read GitHub App credentials"
    return 1
  fi
  
  local jwt
  jwt=$(provision::github_app_mint_jwt "$GITHUB_APP_ID" "$GITHUB_APP_PRIVATE_KEY") || {
    provision::error "Failed to mint GitHub App JWT"
    return 1
  }
  
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    provision::error "curl and jq are required to get installation token"
    return 1
  fi
  
  local token_response token
  token_response=$(curl -sS -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "${api_url}/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens")
  
  token=$(printf '%s' "$token_response" | jq -r '.token // empty' 2>/dev/null)
  
  if [[ -z "$token" || "$token" == "null" ]]; then
    provision::error "Failed to obtain GitHub App installation token"
    provision::error "Response: ${token_response}"
    return 1
  fi
  
  printf '%s' "$token"
}


# --- Git-forge vertical accessor ----------------------------------------------
# Single place that answers "which org owns this environment". GitHub is the
# only git/identity/CI provider today; scripts that need just the org name
# should call this instead of re-deriving the oauth file path and yq
# expression -- it is the seam a future forge provider plugs into
# (see docs/VERTICALS.md).
# Usage: org=$(provision::git_org [env-name])
provision::git_org() {
  local env_name="${1:-${ENV_NAME:-}}"
  if [[ -z "$env_name" ]]; then
    provision::error "provision::git_org: no environment name (pass one or set ENV_NAME)"
    return 1
  fi
  local envs_root="${ENVS_ROOT:-$(provision::envs_root)}"
  local oauth_file="${envs_root}/${env_name}/secrets.plain/github-oauth-credentials.yaml"
  if [[ ! -f "$oauth_file" ]]; then
    provision::error "GitHub OAuth credentials file not found: $oauth_file"
    return 1
  fi
  provision::yaml_get "$oauth_file" .stringData.githubOrg
}

# --- Dex SSO Client Management ---

# Register or update a Dex static client
# Usage: provision::dex_register_client CLIENT_ID CLIENT_NAME REDIRECT_URIS [NAMESPACE_SSO]
# Example: provision::dex_register_client "argocd" "Argo CD" "https://argocd.example.com/callback,https://argocd.example.com/auth/callback"
provision::dex_register_client() {
  local client_id="$1"
  local client_name="$2"
  local redirect_uris="$3"
  local namespace_sso="${4:-sso}"
  
  if [[ -z "$client_id" || -z "$client_name" || -z "$redirect_uris" ]]; then
    provision::error "Usage: provision::dex_register_client CLIENT_ID CLIENT_NAME REDIRECT_URIS [NAMESPACE_SSO]"
    return 1
  fi
  
  # Check if Dex ConfigMap exists
  if ! kubectl -n "$namespace_sso" get configmap dex-config >/dev/null 2>&1; then
    provision::error "Dex ConfigMap 'dex-config' not found in namespace '${namespace_sso}'"
    provision::error ""
    provision::error "This means Dex has not been provisioned yet."
    provision::error ""
    provision::error "To fix this:"
    provision::error "  1. Run: tools/k3s/identity.sh <env-name>"
    provision::error ""
    provision::error "Debug commands:"
    provision::error "  kubectl get ns ${namespace_sso}"
    provision::error "  kubectl -n ${namespace_sso} get configmap"
    return 1
  fi
  
  # Generate or retrieve client secret
  local client_secret
  if kubectl -n "$namespace_sso" get secret "dex-client-${client_id}" >/dev/null 2>&1; then
    provision::info "Using existing Dex client secret for '${client_id}'"
    client_secret=$(kubectl -n "$namespace_sso" get secret "dex-client-${client_id}" -o jsonpath='{.data.secret}' 2>/dev/null | base64 -d 2>/dev/null || true)
  fi
  
  if [[ -z "$client_secret" ]]; then
    provision::info "Generating new Dex client secret for '${client_id}'"
    client_secret=$(openssl rand -base64 32 | tr -d '\n')
    
    # Store client secret
    kubectl -n "$namespace_sso" create secret generic "dex-client-${client_id}" \
      --from-literal=secret="$client_secret" \
      --dry-run=client -o yaml | kubectl apply -f - >&2
  fi
  
  # Get current Dex config using yq (required tool)
  provision::info "Retrieving Dex configuration from ConfigMap..."
  local current_config
  current_config=$(kubectl -n "$namespace_sso" get configmap dex-config -o yaml 2>/dev/null | yq eval '.data."config.yaml"' - 2>/dev/null || true)
  provision::info "Config retrieved"
  
  if [[ -z "$current_config" ]]; then
    provision::error "Failed to retrieve Dex configuration from ConfigMap 'dex-config'"
    provision::error "The ConfigMap exists but 'config.yaml' is empty or missing"
    provision::error ""
    provision::error "This usually means identity.sh needs to be run first to create the Dex configuration."
    provision::error ""
    provision::error "To fix this issue:"
    provision::error "  1. Run: tools/k3s/identity.sh <env-name>"
    provision::error "  2. Or manually recreate the dex-config ConfigMap"
    provision::error ""
    provision::error "Debug commands:"
    provision::error "  kubectl -n $namespace_sso get configmap dex-config -o yaml"
    provision::error "  kubectl -n $namespace_sso describe configmap dex-config"
    return 1
  fi
  
  provision::info "Successfully retrieved Dex configuration (${#current_config} bytes)"
  
  # Check if client already exists and handle idempotently
  provision::info "Checking for existing client..."
  local client_present existing_secret
  client_present=$(printf '%s' "$current_config" | yq eval ".staticClients[] | select(.id == \"${client_id}\") | .id" - 2>/dev/null || true)
  if [[ -n "$client_present" && "$client_present" != "null" ]]; then
    provision::info "Dex client '${client_id}' already defined - ensuring redirect URIs and secret"
    existing_secret=$(printf '%s' "$current_config" | yq eval -r ".staticClients[] | select(.id == \"${client_id}\") | .secret // empty" - 2>/dev/null || true)
    if [[ -z "$existing_secret" || "$existing_secret" == "null" ]]; then
      provision::warn "Existing Dex client '${client_id}' has no secret in config; will reuse/create Kubernetes secret value"
      # 'client_secret' may already be set from dex-client-<id> secret check above
      if [[ -z "${client_secret:-}" ]]; then
        client_secret=$(openssl rand -base64 32 | tr -d '\n')
        # Ensure K8s secret exists with this generated value
        kubectl -n "$namespace_sso" create secret generic "dex-client-${client_id}" \
          --from-literal=secret="$client_secret" \
          --dry-run=client -o yaml | kubectl apply -f - >&2
      fi
    else
      # Ensure a corresponding Kubernetes Secret exists and matches existing_secret
      kubectl -n "$namespace_sso" create secret generic "dex-client-${client_id}" \
        --from-literal=secret="$existing_secret" \
        --dry-run=client -o yaml | kubectl apply -f - >&2
      client_secret="$existing_secret"
    fi

    # Ensure provided redirect URIs are present (idempotent union)
    local desired_array=""
    IFS=',' read -ra URIS_IN <<< "$redirect_uris"
    for uri in "${URIS_IN[@]}"; do
      [[ -z "$uri" ]] && continue
      if [[ -n "$desired_array" ]]; then desired_array+=","; fi
      desired_array+="\"${uri}\""
    done

    # Compute if any desired URI is missing
    local missing_count
    missing_count=$(printf '%s' "$current_config" | yq eval ".staticClients[] | select(.id == \"${client_id}\") | ( [${desired_array}] - ((.redirectURIs // []) | unique) ) | length" - 2>/dev/null || echo 0)

    if [[ "$missing_count" != "0" ]]; then
      provision::info "Updating Dex client '${client_id}' redirectURIs (adding ${missing_count} missing)"
      local temp_cfg_file new_config
      temp_cfg_file=$(mktemp)
      printf '%s' "$current_config" > "$temp_cfg_file"
      # Use yq with proper syntax - update the matching client's redirectURIs
      if ! new_config=$(yq eval \
        "(.staticClients[] | select(.id == \"${client_id}\") | .redirectURIs) = (((.staticClients[] | select(.id == \"${client_id}\") | .redirectURIs) // []) + [${desired_array}] | unique)" \
        "$temp_cfg_file" 2>&1); then
        provision::error "Failed to update redirectURIs using yq"
        provision::error "yq output: $new_config"
        rm -f "$temp_cfg_file"
        return 1
      fi
      rm -f "$temp_cfg_file"

      # Apply updated ConfigMap
      provision::info "Applying updated Dex ConfigMap with augmented redirectURIs..."
      local cm_file
      cm_file=$(mktemp)
      cat > "$cm_file" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: dex-config
  namespace: ${namespace_sso}
data:
  config.yaml: |
$(echo "$new_config" | sed 's/^/    /')
EOF
      kubectl apply -f "$cm_file" >&2
      rm -f "$cm_file"

      # Restart Dex to apply changes
      if kubectl -n "$namespace_sso" get deploy dex >/dev/null 2>&1; then
        provision::info "Restarting Dex to apply updated client configuration..."
        kubectl -n "$namespace_sso" rollout restart deployment/dex >/dev/null 2>&1 || true
        kubectl -n "$namespace_sso" rollout status deployment/dex --timeout=120s >/dev/null 2>&1 || true
      fi
    else
      provision::info "✓ Dex client '${client_id}' redirectURIs already include desired entries"
    fi

    echo "$client_secret"
    return 0
  fi

  provision::info "Registering new Dex client '${client_id}'"
  
  # Build redirect URIs array for yq
  provision::info "Building client configuration..."
  local redirect_uris_array=""
  IFS=',' read -ra URIS <<< "$redirect_uris"
  for uri in "${URIS[@]}"; do
    if [[ -n "$redirect_uris_array" ]]; then
      redirect_uris_array+=","
    fi
    redirect_uris_array+="\"${uri}\""
  done
  
  # Create new client entry using yq
  provision::info "Adding new client entry..."
  local temp_config_file
  temp_config_file=$(mktemp)
  echo "$current_config" > "$temp_config_file"
  
  # Add new client using yq
  # First ensure staticClients array exists
  if ! yq eval '.staticClients' "$temp_config_file" >/dev/null 2>&1 || \
     [[ "$(yq eval '.staticClients' "$temp_config_file" 2>/dev/null)" == "null" ]]; then
    yq eval -i '.staticClients = []' "$temp_config_file"
  fi
  
  # Then add the new client
  if ! current_config=$(yq eval "
    .staticClients += [{
      \"id\": \"${client_id}\",
      \"name\": \"${client_name}\",
      \"redirectURIs\": [${redirect_uris_array}],
      \"secret\": \"${client_secret}\"
    }]
  " "$temp_config_file" 2>&1); then
    provision::error "Failed to add client using yq"
    provision::error "yq output: $current_config"
    rm -f "$temp_config_file"
    return 1
  fi
  
  rm -f "$temp_config_file"
  provision::info "Client entry added"
  
  # Validate that we have a non-empty config
  if [[ -z "$current_config" ]]; then
    provision::error "Configuration became empty after adding client!"
    provision::error "This is a bug in the registration function."
    return 1
  fi
  
  # Update ConfigMap using yq to build proper YAML structure
  provision::info "Updating ConfigMap..."
  local configmap_file
  configmap_file=$(mktemp)
  
  # Write the Dex config to a temp file
  local temp_dex_config
  temp_dex_config=$(mktemp)
  echo "$current_config" > "$temp_dex_config"
  
  # Create ConfigMap with yq by merging the config
  cat > "$configmap_file" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: dex-config
  namespace: ${namespace_sso}
data:
  config.yaml: |
$(echo "$current_config" | sed 's/^/    /')
EOF
  
  rm -f "$temp_dex_config"
  
  # Apply the ConfigMap
  kubectl apply -f "$configmap_file" >&2
  rm -f "$configmap_file"
  
  # Restart Dex to pick up changes
  if kubectl -n "$namespace_sso" get deploy dex >/dev/null 2>&1; then
    provision::info "Restarting Dex to apply configuration changes..."
    kubectl -n "$namespace_sso" rollout restart deployment/dex >/dev/null 2>&1 || true
    kubectl -n "$namespace_sso" rollout status deployment/dex --timeout=120s >/dev/null 2>&1 || true
  fi
  
  provision::info "✓ Dex client '${client_id}' registered successfully"
  
  # Export client secret for use by caller
  echo "$client_secret"
}

# --- Pomerium route management ------------------------------------------------
# Manage routes in env-specific pomerium-routes.yaml file
# This ensures routes persist and can be version-controlled

# Get the path to the environment-specific pomerium-routes.yaml file
provision::pomerium_routes_file() {
  if [[ -z "${ENV_NAME:-}" ]]; then
    provision::error "ENV_NAME not set - cannot determine routes file path"
    return 1
  fi
  local envs_root
  envs_root=$(provision::envs_root)
  echo "${envs_root}/${ENV_NAME}/pomerium-routes.yaml"
}

# Reload Pomerium configuration after routes file has been modified
# This applies the routes file to the pomerium-config secret and restarts pomerium
provision::pomerium_reload_routes() {
  local namespace_sso="${1:-sso}" routes_file="${2:-}"
  
  if [[ -z "$routes_file" ]]; then
    if ! routes_file=$(provision::pomerium_routes_file); then
      return 1
    fi
  fi
  
  if [[ ! -f "$routes_file" ]]; then
    provision::warn "Routes file not found: $routes_file - skipping reload"
    return 0
  fi
  
  # Extract just the routes section and create a config.yaml for the secret
  local tmp_config
  tmp_config=$(mktemp)
  
  # The routes file has structure: config.routes, but we need to create full config.yaml
  # Get current pomerium-config secret to preserve other settings
  local current_config
  current_config=$(kubectl -n "$namespace_sso" get secret pomerium-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  if [[ -n "$current_config" ]]; then
    # Merge: take current config and replace routes from file
    printf '%s' "$current_config" > "$tmp_config"
    # IMPORTANT: Do not inline the routes array into the yq expression (it can be multi-line).
    # Load routes from file directly to keep this idempotent and reliable.
    if ! yq eval -i ".routes = (load(\"$routes_file\") | .config.routes // [])" "$tmp_config" 2>/dev/null; then
      provision::warn "Failed to update routes in pomerium-config (yq merge failed) - leaving existing routes unchanged"
    fi
  else
    # No existing config, just use routes from file (config.yaml format, not config.routes)
    yq eval '.config | . style=""' "$routes_file" > "$tmp_config" 2>/dev/null || {
      provision::error "Failed to extract routes from $routes_file"
      rm -f "$tmp_config"
      return 1
    }
  fi
  
  # Apply to secret
  kubectl -n "$namespace_sso" create secret generic pomerium-config \
    --from-file=config.yaml="$tmp_config" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || {
    provision::error "Failed to update pomerium-config secret"
    rm -f "$tmp_config"
    return 1
  }
  
  rm -f "$tmp_config"
  
  # Restart Pomerium deployment to pick up changes (best-effort)
  if kubectl -n "$namespace_sso" get deploy pomerium-proxy >/dev/null 2>&1; then
    kubectl -n "$namespace_sso" rollout restart deployment/pomerium-proxy >/dev/null 2>&1 || true
  elif kubectl -n "$namespace_sso" get deploy pomerium >/dev/null 2>&1; then
    kubectl -n "$namespace_sso" rollout restart deployment/pomerium >/dev/null 2>&1 || true
  fi
  
  provision::info "Reloaded Pomerium routes from $routes_file"
  return 0
}

# Add or replace a route with given "from" URL in the environment's pomerium-routes.yaml
# Usage: provision::pomerium_routes_add FROM_URL TO_URL [NAMESPACE_SSO] [PRESERVE_HOST=true] [PASS_ID=true] [ALLOW_ANY=true]
provision::pomerium_routes_add() {
  local from_url="$1" to_url="$2" namespace_sso="${3:-sso}"
  local preserve_host="${4:-true}" pass_identity_headers="${5:-true}" allow_any="${6:-true}"

  if [[ -z "$from_url" || -z "$to_url" ]]; then
    provision::error "pomerium_routes_add: FROM_URL and TO_URL are required"
    return 1
  fi

  local routes_file
  if ! routes_file=$(provision::pomerium_routes_file); then
    return 1
  fi

  # Create file with initial structure if it doesn't exist
  if [[ ! -f "$routes_file" ]]; then
    provision::info "Creating new pomerium-routes.yaml at: $routes_file"
    cat > "$routes_file" <<'EOF'
config:
  routes: []
EOF
  fi

  # Two-step process: filter out existing route with same .from, then append new route
  local tmp_filtered tmp_final
  tmp_filtered=$(mktemp)
  tmp_final=$(mktemp)

  # Step 1: Remove existing route with same .from
  if ! yq eval ".config.routes |= (map(select(.from != \"${from_url}\")))" "$routes_file" > "$tmp_filtered" 2>/dev/null; then
    provision::error "Failed to filter routes in $routes_file using yq"
    rm -f "$tmp_filtered" "$tmp_final"
    return 1
  fi
  
  # Step 2: Append the new route using JSON syntax (handles URLs properly)
  if ! yq eval ".config.routes += [{\"from\": \"${from_url}\", \"to\": \"${to_url}\", \"preserve_host_header\": ${preserve_host}, \"pass_identity_headers\": ${pass_identity_headers}, \"allow_any_authenticated_user\": ${allow_any}}]" "$tmp_filtered" > "$tmp_final" 2>/dev/null; then
    provision::error "Failed to append route in $routes_file using yq"
    rm -f "$tmp_filtered" "$tmp_final"
    return 1
  fi
  
  rm -f "$tmp_filtered"
  tmp_out="$tmp_final"

  # Write back to the file
  mv "$tmp_out" "$routes_file"
  
  provision::info "Updated route in $routes_file: ${from_url} -> ${to_url}"
  
  # Apply the updated routes by running helm upgrade on pomerium
  provision::pomerium_reload_routes "$namespace_sso" "$routes_file"
  return 0
}

# Remove a route by its FROM_URL from the environment's pomerium-routes.yaml
provision::pomerium_routes_remove() {
  local from_url="$1" namespace_sso="${2:-sso}"
  if [[ -z "$from_url" ]]; then
    provision::error "pomerium_routes_remove: FROM_URL is required"
    return 1
  fi

  local routes_file
  if ! routes_file=$(provision::pomerium_routes_file); then
    return 1
  fi

  if [[ ! -f "$routes_file" ]]; then
    provision::warn "Routes file does not exist: $routes_file"
    return 0
  fi

  local tmp_out
  tmp_out=$(mktemp)
  
  if ! yq eval \
    ".config.routes |= (map(select(.from != \"${from_url}\")))" \
    "$routes_file" > "$tmp_out" 2>/dev/null; then
    provision::error "Failed to remove route from $routes_file using yq"
    rm -f "$tmp_out"
    return 1
  fi

  # Write back to the file
  mv "$tmp_out" "$routes_file"
  
  provision::info "Removed route from $routes_file: ${from_url}"
  
  # Apply the updated routes by running helm upgrade on pomerium
  provision::pomerium_reload_routes "$namespace_sso" "$routes_file"
  return 0
}
