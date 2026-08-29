#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# GitHub Organization Secrets Provisioning
# ============================================================================
# Provisions Harbor and Nexus credentials as GitHub organization-level secrets.
# Organization secrets are automatically available to all repositories and
# GitHub Actions runners without per-repository configuration.
#
# Prerequisites:
#   - Harbor must be provisioned (harbor.sh)
#   - Nexus must be provisioned (provision-delivery.sh with --skip-nexus=false)
#   - GitHub App credentials must be available
#   - gh CLI must be installed
#
# Usage:
#   tools/k3s/provision-org-secrets.sh <env-name> [options]
#
# Options:
#   --visibility <all|private|selected>  Secret visibility (default: all)
#   --selected-repos <repo1,repo2,...>   Comma-separated list of repos (for selected visibility)
#   --skip-harbor                        Skip Harbor credentials
#   --skip-nexus                         Skip Nexus credentials
#   --skip-environments                  Skip syncing per-repo GitHub Environment secrets
#
# Organization Secrets Created:
#   HARBOR_USERNAME_<ENV>    - Harbor robot account username
#   HARBOR_PASSWORD_<ENV>    - Harbor robot account password
#   NEXUS_USERNAME_<ENV>     - Nexus deployment user username
#   NEXUS_PASSWORD_<ENV>     - Nexus deployment user password
#   NEXUS_URL_<ENV>          - Nexus repository URL
#
# Repository Environment Secrets Synced (plain names, no suffix):
#   For every org repo that has a GitHub Environment named <env-name>, any of
#   HARBOR_USERNAME, HARBOR_PASSWORD, NEXUS_USERNAME, NEXUS_PASSWORD, NEXUS_URL
#   that ALREADY EXIST in that environment are refreshed with current values.
#   Secrets are never created in environments that don't have them.
#   This matters because environment secrets have the highest precedence: they
#   silently override repo-level secrets AND the secrets: block passed into
#   reusable workflows, so a stale copy breaks CI even when org secrets are fresh.
#
# Example:
#   # Provision secrets for all repositories
#   tools/k3s/provision-org-secrets.sh dev
#
#   # Provision secrets for specific repositories only
#   tools/k3s/provision-org-secrets.sh dev --visibility selected --selected-repos "app1,app2"
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

# --- Argument parsing ---
if [[ -z "${1:-}" ]]; then
  cat >&2 <<EOF
Usage: $0 <env-name> [options]

Options:
  --visibility <all|private|selected>  Secret visibility (default: all)
  --selected-repos <repo1,repo2,...>   Comma-separated list of repos (for selected visibility)
  --skip-harbor                        Skip Harbor credentials
  --skip-nexus                         Skip Nexus credentials
  --skip-environments                  Skip syncing per-repo GitHub Environment secrets

Available environments:
EOF
  find "$(provision::envs_root)" -maxdepth 2 -type f -name env.properties -print | \
    sed "s#$(provision::envs_root)/##; s#/env.properties##" | sort || true
  exit 1
fi

if provision::load_env "${1:-}"; then
  shift
else
  echo "ERROR: Environment '$1' not found (envs/$1/env.properties missing)." >&2
  exit 1
fi

# Validate kubectl context matches environment
if ! provision::validate_kubectl_context; then
  exit 1
fi

# Parse flags
VISIBILITY="all"
SELECTED_REPOS=""
SKIP_HARBOR=false
SKIP_NEXUS=false
SKIP_ENVIRONMENTS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --visibility)
      VISIBILITY="$2"
      shift 2
      ;;
    --selected-repos)
      SELECTED_REPOS="$2"
      shift 2
      ;;
    --skip-harbor)
      SKIP_HARBOR=true
      shift
      ;;
    --skip-nexus)
      SKIP_NEXUS=true
      shift
      ;;
    --skip-environments)
      SKIP_ENVIRONMENTS=true
      shift
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

# Validate visibility
if [[ ! "$VISIBILITY" =~ ^(all|private|selected)$ ]]; then
  echo "ERROR: Invalid visibility '$VISIBILITY'. Must be one of: all, private, selected" >&2
  exit 1
fi

if [[ "$VISIBILITY" == "selected" && -z "$SELECTED_REPOS" ]]; then
  echo "ERROR: --selected-repos required when --visibility=selected" >&2
  exit 1
fi

# --- Validation ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need kubectl
need gh
need jq

if ! provision::require_tools; then
  exit 1
fi

# --- Logging helpers ---
log() { echo "[org-secrets] $*"; }
info() { echo "[org-secrets:info] $*"; }
warn() { echo "[org-secrets:warn] $*" >&2; }
err() { echo "[org-secrets:error] $*" >&2; }

# --- Configuration ---
NAMESPACE_HARBOR="${NAMESPACE_HARBOR:-harbor}"
NAMESPACE_NEXUS="${NAMESPACE_NEXUS:-nexus}"

# Derive hosts from HOSTNAME if not provided
if [[ -n "${HOSTNAME:-}" ]]; then
  HARBOR_HOST="${HARBOR_HOST:-harbor.${HOSTNAME}}"
  NEXUS_HOST="${NEXUS_HOST:-nexus.${HOSTNAME}}"
fi

# Normalize environment name for secret suffix (uppercase, replace dashes/dots with underscores)
ENV_SUFFIX=$(echo "${ENV_NAME}" | tr '[:lower:]' '[:upper:]' | tr '.-' '__')

log "Starting organization secrets provisioning for environment: ${ENV_NAME}"
log "  Secret suffix: ${ENV_SUFFIX}"
log "  Visibility: ${VISIBILITY}"
if [[ "$VISIBILITY" == "selected" ]]; then
  log "  Selected repositories: ${SELECTED_REPOS}"
fi

# ============================================================================
# Step 1: Get GitHub Organization and Generate Token
# ============================================================================

log "=== Step 1: GitHub Authentication ==="

# Get GitHub organization from OAuth credentials
oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
if [[ ! -f "$oauth_file" ]]; then
  err "GitHub OAuth credentials not found: $oauth_file"
  exit 1
fi

github_org=$(provision::yaml_get "$oauth_file" .stringData.githubOrg)
if [[ -z "$github_org" ]]; then
  err "Failed to read GitHub organization from $oauth_file"
  exit 1
fi

info "GitHub organization: ${github_org}"

# Generate GitHub App token using common function
info "Generating GitHub App token..."
github_token=$(provision::github_get_installation_token)
if [[ -z "$github_token" ]]; then
  err "Failed to generate GitHub App token"
  exit 1
fi

export GH_TOKEN="$github_token"
info "✓ GitHub App token generated"

# Validate GitHub App has organization secrets permission
info "Validating GitHub App permissions..."
app_file="$ENVS_ROOT/shared/secrets.plain/github-app-credentials.yaml"
gh_app_id=$(provision::yaml_get "$app_file" .stringData.githubAppID)
gh_app_private_key=$(provision::yaml_get "$app_file" .stringData.githubAppPrivateKey)

# Generate JWT to query app info (installation token can't access /app endpoint)
gh_jwt=$(provision::github_app_mint_jwt "$gh_app_id" "$gh_app_private_key")

app_info=$(curl -sS \
  -H "Authorization: Bearer $gh_jwt" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app")

app_name=$(echo "$app_info" | jq -r '.name // "Unknown"')
org_secrets_perm=$(echo "$app_info" | jq -r '.permissions.organization_secrets // "none"')

info "  GitHub App: ${app_name}"
info "  Organization secrets permission: ${org_secrets_perm}"

if [[ "$org_secrets_perm" != "write" ]]; then
  err ""
  err "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  err "  GitHub App Missing Required Permissions"
  err "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  err ""
  err "The GitHub App '${app_name}' needs WRITE access to organization secrets."
  err ""
  err "Current permission: ${org_secrets_perm}"
  err "Required permission: write"
  err ""
  err "To fix this:"
  err ""
  err "  1. Go to: https://github.com/organizations/${github_org}/settings/apps"
  err "  2. Click on your GitHub App: ${app_name}"
  err "  3. Click 'Permissions & events' in the left sidebar"
  err "  4. Scroll down to 'Organization permissions'"
  err "  5. Find 'Secrets' and set it to 'Read and write'"
  err "  6. Click 'Save changes'"
  err "  7. Organization owners will need to approve the permission change"
  err ""
  err "After updating permissions, re-run this script."
  err ""
  unset GH_TOKEN
  exit 1
fi

info "✓ GitHub App has required permissions"

# Additional check: verify the installation token has the permission
info "Verifying installation token permissions..."
install_info=$(curl -sS \
  -H "Authorization: Bearer $github_token" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/installation/repositories")

install_perms=$(curl -sS \
  -H "Authorization: Bearer $gh_jwt" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations" | jq -r ".[0].permissions.organization_secrets // \"none\"")

if [[ "$install_perms" != "write" ]]; then
  warn ""
  warn "⚠️  Installation token may not have organization secrets permission yet"
  warn ""
  warn "App permission: ${org_secrets_perm}"
  warn "Installation permission: ${install_perms}"
  warn ""
  warn "This can happen if:"
  warn "  1. The permission was just approved and hasn't propagated yet (wait 1-2 minutes)"
  warn "  2. The GitHub App installation needs to be updated"
  warn ""
  warn "To refresh the installation:"
  warn "  1. Go to: https://github.com/organizations/${github_org}/settings/installations"
  warn "  2. Click 'Configure' next to ${app_name}"
  warn "  3. Review and confirm the permissions"
  warn ""
  warn "Then re-run this script."
  warn ""
fi

# ============================================================================
# Step 2: Retrieve Harbor Credentials
# ============================================================================

if [[ "$SKIP_HARBOR" != "true" ]]; then
  log "=== Step 2: Harbor Credentials ==="
  
  # Check if Harbor namespace exists
  if ! kubectl get ns "$NAMESPACE_HARBOR" >/dev/null 2>&1; then
    warn "Harbor namespace '${NAMESPACE_HARBOR}' not found"
    warn "Run registry.sh first: tools/k3s/registry.sh ${ENV_NAME}"
    SKIP_HARBOR=true
  else
    # Check if robot credentials exist
    if ! kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner >/dev/null 2>&1; then
      warn "Harbor robot credentials not found in ${NAMESPACE_HARBOR}/harbor-robot-runner"
      warn "Run registry.sh first: tools/k3s/registry.sh ${ENV_NAME}"
      SKIP_HARBOR=true
    else
      HARBOR_USERNAME=$(kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner -o jsonpath='{.data.username}' | base64 -d)
      HARBOR_PASSWORD=$(kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner -o jsonpath='{.data.password}' | base64 -d)
      
      if [[ -z "$HARBOR_USERNAME" || -z "$HARBOR_PASSWORD" ]]; then
        err "Failed to retrieve Harbor robot credentials from secret"
        SKIP_HARBOR=true
      else
        info "✓ Retrieved Harbor robot credentials"
        info "  Username: ${HARBOR_USERNAME}"
        info "  Registry: ${HARBOR_HOST}"
      fi
    fi
  fi
fi

# ============================================================================
# Step 3: Retrieve Nexus Credentials
# ============================================================================

if [[ "$SKIP_NEXUS" != "true" ]]; then
  log "=== Step 3: Nexus Credentials ==="
  
  # Check if Nexus namespace exists
  if ! kubectl get ns "$NAMESPACE_NEXUS" >/dev/null 2>&1; then
    warn "Nexus namespace '${NAMESPACE_NEXUS}' not found"
    warn "Run provision-delivery.sh without --skip-nexus"
    SKIP_NEXUS=true
  else
    # Check if deployment credentials exist
    if ! kubectl -n "$NAMESPACE_NEXUS" get secret nexus-deployment-credentials >/dev/null 2>&1; then
      warn "Nexus deployment credentials not found in ${NAMESPACE_NEXUS}/nexus-deployment-credentials"
      warn "Run provision-delivery.sh without --skip-nexus"
      SKIP_NEXUS=true
    else
      NEXUS_USERNAME=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-deployment-credentials -o jsonpath='{.data.username}' | base64 -d)
      NEXUS_PASSWORD=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-deployment-credentials -o jsonpath='{.data.password}' | base64 -d)
      
      if [[ -z "$NEXUS_USERNAME" || -z "$NEXUS_PASSWORD" ]]; then
        err "Failed to retrieve Nexus deployment credentials from secret"
        SKIP_NEXUS=true
      else
        info "✓ Retrieved Nexus deployment credentials"
        info "  Username: ${NEXUS_USERNAME}"
        info "  URL: https://${NEXUS_HOST}"
      fi
    fi
  fi
fi

# Check if we have any credentials to provision
if [[ "$SKIP_HARBOR" == "true" && "$SKIP_NEXUS" == "true" ]]; then
  err "No credentials available to provision"
  err "Ensure Harbor and/or Nexus are provisioned first"
  exit 1
fi

# ============================================================================
# Step 4: Create Organization Secrets
# ============================================================================

log "=== Step 4: Creating Organization Secrets ==="

# Helper function to create/update organization secret
create_org_secret() {
  local secret_name="$1"
  local secret_value="$2"
  local description="$3"
  
  info "Setting organization secret: ${secret_name}..."
  
  # Build gh secret set command
  local gh_cmd=(gh secret set "$secret_name" --org "$github_org" --body "$secret_value")
  
  # Add visibility
  case "$VISIBILITY" in
    all)
      gh_cmd+=(--visibility all)
      ;;
    private)
      gh_cmd+=(--visibility private)
      ;;
    selected)
      gh_cmd+=(--visibility selected)
      # Convert comma-separated list to space-separated for --repos flag
      local repos_list
      repos_list=$(echo "$SELECTED_REPOS" | tr ',' ' ')
      gh_cmd+=(--repos "$repos_list")
      ;;
  esac
  
  # Execute command
  if "${gh_cmd[@]}" 2>&1; then
    info "  ✓ ${secret_name} configured"
    return 0
  else
    err "  Failed to configure ${secret_name}"
    return 1
  fi
}

# Create Harbor secrets
if [[ "$SKIP_HARBOR" != "true" ]]; then
  info "Provisioning Harbor secrets..."
  
  create_org_secret "HARBOR_USERNAME_${ENV_SUFFIX}" "$HARBOR_USERNAME" "Harbor robot account username for ${ENV_NAME}"
  create_org_secret "HARBOR_PASSWORD_${ENV_SUFFIX}" "$HARBOR_PASSWORD" "Harbor robot account password for ${ENV_NAME}"
  
  info "✓ Harbor secrets provisioned"
fi

# Create Nexus secrets
if [[ "$SKIP_NEXUS" != "true" ]]; then
  info "Provisioning Nexus secrets..."
  
  create_org_secret "NEXUS_USERNAME_${ENV_SUFFIX}" "$NEXUS_USERNAME" "Nexus deployment user username for ${ENV_NAME}"
  create_org_secret "NEXUS_PASSWORD_${ENV_SUFFIX}" "$NEXUS_PASSWORD" "Nexus deployment user password for ${ENV_NAME}"
  create_org_secret "NEXUS_URL_${ENV_SUFFIX}" "https://${NEXUS_HOST}" "Nexus repository URL for ${ENV_NAME}"
  
  info "✓ Nexus secrets provisioned"
fi

# ============================================================================
# Step 5: Sync Repository Environment Secrets
# ============================================================================
# GitHub Environment secrets have the highest precedence: a job that sets
# `environment:` (as the reusable build workflows do) resolves secrets from the
# caller repo's environment FIRST, silently overriding repo-level secrets and
# even the values passed via the workflow_call `secrets:` block. Stale copies
# there survive an org-secret re-push and break CI. This step refreshes plain-
# named secrets in every repo environment named "${ENV_NAME}" — updating only
# secrets that already exist, never creating new ones.

ENV_SECRETS_UPDATED=0
ENV_SECRETS_FAILED=0
ENV_REPOS_TOUCHED=""

if [[ "$SKIP_ENVIRONMENTS" != "true" ]]; then
  log "=== Step 5: Syncing repository environment secrets (environment: ${ENV_NAME}) ==="

  # Candidate secret names -> values (plain names; environments don't use the env suffix)
  env_secret_names=()
  env_secret_values=()
  if [[ "$SKIP_HARBOR" != "true" ]]; then
    env_secret_names+=("HARBOR_USERNAME" "HARBOR_PASSWORD")
    env_secret_values+=("$HARBOR_USERNAME" "$HARBOR_PASSWORD")
  fi
  if [[ "$SKIP_NEXUS" != "true" ]]; then
    env_secret_names+=("NEXUS_USERNAME" "NEXUS_PASSWORD" "NEXUS_URL")
    env_secret_values+=("$NEXUS_USERNAME" "$NEXUS_PASSWORD" "https://${NEXUS_HOST}")
  fi

  # All repos the GitHub App installation can see
  all_repos=$(gh api --paginate "/installation/repositories" --jq '.repositories[].name' 2>/dev/null || true)

  if [[ -z "$all_repos" ]]; then
    warn "Could not list installation repositories - skipping environment sync"
    warn "The GitHub App needs repository access and 'Secrets'/'Environments' permissions"
  else
    for repo in $all_repos; do
      # Does this repo have an environment named after the target env?
      if ! gh api "repos/${github_org}/${repo}/environments/${ENV_NAME}" >/dev/null 2>&1; then
        continue
      fi

      # Which of our candidate secrets already exist there?
      existing=$(gh api --paginate "repos/${github_org}/${repo}/environments/${ENV_NAME}/secrets" \
        --jq '.secrets[].name' 2>/dev/null || true)
      [[ -z "$existing" ]] && continue

      repo_updated=0
      for i in "${!env_secret_names[@]}"; do
        name="${env_secret_names[$i]}"
        if grep -qx "$name" <<<"$existing"; then
          if gh secret set "$name" --repo "${github_org}/${repo}" --env "$ENV_NAME" \
               --body "${env_secret_values[$i]}" >/dev/null 2>&1; then
            ENV_SECRETS_UPDATED=$((ENV_SECRETS_UPDATED + 1))
            repo_updated=$((repo_updated + 1))
          else
            warn "  Failed to update ${repo} environment ${ENV_NAME}: ${name}"
            ENV_SECRETS_FAILED=$((ENV_SECRETS_FAILED + 1))
          fi
        fi
      done

      if [[ "$repo_updated" -gt 0 ]]; then
        info "  ✓ ${repo} (${repo_updated} secret(s) refreshed)"
        ENV_REPOS_TOUCHED="${ENV_REPOS_TOUCHED} ${repo}"
      fi
    done

    info "✓ Environment secrets synced: ${ENV_SECRETS_UPDATED} updated across$(echo "$ENV_REPOS_TOUCHED" | wc -w | tr -d ' ') repo(s)"
    if [[ "$ENV_SECRETS_FAILED" -gt 0 ]]; then
      warn "${ENV_SECRETS_FAILED} update(s) failed - the GitHub App may lack repository 'Secrets' write permission"
    fi
  fi
fi

# Cleanup
unset GH_TOKEN

# ============================================================================
# Summary
# ============================================================================

log "=== Organization Secrets Provisioning Completed ==="
info ""
info "Organization: ${github_org}"
info "Environment: ${ENV_NAME}"
info "Secret visibility: ${VISIBILITY}"
if [[ "$VISIBILITY" == "selected" ]]; then
  info "Selected repositories: ${SELECTED_REPOS}"
fi
info ""
info "Secrets created:"

if [[ "$SKIP_HARBOR" != "true" ]]; then
  info "  Harbor:"
  info "    ✓ HARBOR_USERNAME_${ENV_SUFFIX}"
  info "    ✓ HARBOR_PASSWORD_${ENV_SUFFIX}"
fi

if [[ "$SKIP_NEXUS" != "true" ]]; then
  info "  Nexus:"
  info "    ✓ NEXUS_USERNAME_${ENV_SUFFIX}"
  info "    ✓ NEXUS_PASSWORD_${ENV_SUFFIX}"
  info "    ✓ NEXUS_URL_${ENV_SUFFIX}"
fi

if [[ "$SKIP_ENVIRONMENTS" != "true" ]]; then
  info "  Repository environment secrets (environment: ${ENV_NAME}):"
  info "    ✓ ${ENV_SECRETS_UPDATED} existing secret(s) refreshed in:${ENV_REPOS_TOUCHED:- (none)}"
fi

info ""
info "These secrets are now available in ALL workflows across the organization:"
info ""
info "  Example usage in GitHub Actions:"
info ""
if [[ "$SKIP_HARBOR" != "true" ]]; then
  info "    # Harbor login (registry URL: ${HARBOR_HOST})"
  info "    - name: Login to Harbor"
  info "      uses: docker/login-action@v3"
  info "      with:"
  info "        registry: ${HARBOR_HOST}"
  info "        username: \${{ secrets.HARBOR_USERNAME_${ENV_SUFFIX} }}"
  info "        password: \${{ secrets.HARBOR_PASSWORD_${ENV_SUFFIX} }}"
  info ""
fi
if [[ "$SKIP_NEXUS" != "true" ]]; then
  info "    # Nexus Maven deployment"
  info "    - name: Deploy to Nexus"
  info "      run: |"
  info "        mvn deploy -s settings.xml \\"
  info "          -Dnexus.url=\${{ secrets.NEXUS_URL_${ENV_SUFFIX} }} \\"
  info "          -Dnexus.username=\${{ secrets.NEXUS_USERNAME_${ENV_SUFFIX} }} \\"
  info "          -Dnexus.password=\${{ secrets.NEXUS_PASSWORD_${ENV_SUFFIX} }}"
  info ""
fi
info "View organization secrets:"
info "  https://github.com/organizations/${github_org}/settings/secrets/actions"
info ""
info "Note: secret precedence is environment > repository > organization. Jobs that set"
info "'environment:' (the reusable build workflows do) resolve environment secrets first,"
info "overriding even the secrets: block passed into a workflow_call."
info ""
