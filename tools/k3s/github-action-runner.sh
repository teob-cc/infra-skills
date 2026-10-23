#!/usr/bin/env bash
set -euo pipefail

# CI provisioning script for Kubernetes clusters.
# Provisions GitHub Actions Runner Controller (ARC) for self-hosted runners.
#
# Prerequisites:
#   - cert-manager must be installed
#   - GitHub App credentials must be configured
#
# Usage:
#   tools/k3s/github-action-runner.sh <env-name> [--bootstrap] [--custom-runner] [--allow-runner-repo-removal]
#
# Options:
#   --bootstrap      Create bootstrap runners for building images (vanilla runner)
#                    Use this for initial provisioning
#   --custom-runner  Use custom runner image with pre-installed build tools
#                    Eliminates need for job container, faster workflow startup
#   --allow-runner-repo-removal
#                    Let RUNNER_GROUP_REPOS take repos out of the org runner group (Phase 3b)
#
# env.properties:
#   RUNNER_GROUP_REPOS  repos (space- or comma-separated) the org's "Default" runner group is
#                       restricted to; the runners are privileged, so a job on them is root on the
#                       node. Unset: the group is left alone (with a warning when it admits all repos)
#
# Workflow (Option A - Custom Runner Image, Recommended):
#   1. Bootstrap:        tools/k3s/github-action-runner.sh dev --bootstrap
#   2. Base images: tools/k3s/runner-image.sh <env> and tools/k3s/base-image.sh <env>
#   3. Build runner:     gh workflow run build-runner-image.yml -f environment=dev
#   4. Deploy runners:   tools/k3s/github-action-runner.sh dev --custom-runner
#   5. Remove container: directive from workflows
#
# Workflow (Option B - Job Container, Simpler):
#   1. Bootstrap:        tools/k3s/github-action-runner.sh dev --bootstrap
#   2. Base images: tools/k3s/runner-image.sh <env> and tools/k3s/base-image.sh <env>
#   3. Deploy runners:   tools/k3s/github-action-runner.sh dev
#   4. Keep container: directive (image pulled on each run)

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

# --- Parse arguments ---
if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--bootstrap] [--custom-runner] [--allow-runner-repo-removal]" >&2
  echo "Available environments:" >&2
  find "$(provision::envs_root)" -maxdepth 2 -type f -name env.properties -print | sed "s#$(provision::envs_root)/##; s#/env.properties##" | sort || true
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

# Parse optional flags
BOOTSTRAP_MODE=false
CUSTOM_RUNNER_IMAGE=false
ALLOW_RUNNER_REPO_REMOVAL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-runner-repo-removal)
      ALLOW_RUNNER_REPO_REMOVAL=true
      shift
      ;;
    --bootstrap)
      BOOTSTRAP_MODE=true
      shift
      ;;
    --custom-runner)
      CUSTOM_RUNNER_IMAGE=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# --- Validation ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
need kubectl
need helm

if ! provision::require_tools; then
  exit 1
fi

# --- Logging helpers ---
log() { echo "[ci] $*"; }
info() { echo "[ci:info] $*"; }
warn() { echo "[ci:warn] $*" >&2; }
err() { echo "[ci:error] $*" >&2; }

# --- Config defaults ---
NAMESPACE_RUNNER="${NAMESPACE_RUNNER:-actions-runner-system}"

log "Starting CI provisioning for environment: ${ENV_NAME}"

# ============================================================================
# Phase 0: Prerequisites Validation
# ============================================================================

validate_prerequisites() {
  log "=== Phase 0: Prerequisites Validation ==="
  
  local validation_failed=false
  
  # Check cert-manager
  info "Checking cert-manager..."
  if kubectl get pods -n cert-manager >/dev/null 2>&1; then
    info "  ✓ cert-manager is installed"
  else
    err "  ✗ cert-manager not found. Install cert-manager first."
    validation_failed=true
  fi
  
  # Check GitHub App credentials
  info "Checking GitHub App credentials..."
  local app_file="$ENVS_ROOT/shared/secrets.plain/github-app-credentials.yaml"
  if [[ ! -f "$app_file" ]]; then
    err "  ✗ GitHub App credentials file not found: $app_file"
    validation_failed=true
  else
    local github_app_id github_app_installation_id github_app_private_key
    github_app_id=$(provision::yaml_get "$app_file" .stringData.githubAppID)
    github_app_installation_id=$(provision::yaml_get "$app_file" .stringData.githubAppInstallationID)
    github_app_private_key=$(provision::yaml_get "$app_file" .stringData.githubAppPrivateKey)
    
    if [[ -n "$github_app_id" && -n "$github_app_installation_id" && -n "$github_app_private_key" ]]; then
      info "  ✓ GitHub App credentials found"
    else
      err "  ✗ GitHub App credentials incomplete"
      err "    Required: githubAppID, githubAppInstallationID, githubAppPrivateKey"
      validation_failed=true
    fi
  fi
  
  # Check GitHub organization
  info "Checking GitHub organization..."
  local oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
  if [[ ! -f "$oauth_file" ]]; then
    err "  ✗ GitHub OAuth credentials file not found: $oauth_file"
    validation_failed=true
  else
    local github_org
    github_org=$(provision::yaml_get "$oauth_file" .stringData.githubOrg)
    
    if [[ -n "$github_org" ]]; then
      info "  ✓ GitHub organization: ${github_org}"
    else
      err "  ✗ GitHub organization not found in github-oauth-credentials.yaml"
      validation_failed=true
    fi
  fi
  
  if [[ "$validation_failed" == "true" ]]; then
    err ""
    err "Prerequisites validation failed."
    exit 1
  fi
  
  info "✓ All prerequisites validated"
}

validate_prerequisites

# ============================================================================
# Phase 1: GitHub Credentials
# ============================================================================

apply_github_credentials() {
  log "=== Phase 1: GitHub Credentials ==="
  
  # Create namespace
  kubectl get ns "$NAMESPACE_RUNNER" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_RUNNER"
  
  # Apply GitHub App credentials with ARC-expected key names
  info "Configuring GitHub App credentials for ARC..."
  local app_file="$ENVS_ROOT/shared/secrets.plain/github-app-credentials.yaml"
  
  local github_app_id github_app_installation_id github_app_private_key
  github_app_id=$(provision::yaml_get "$app_file" .stringData.githubAppID)
  github_app_installation_id=$(provision::yaml_get "$app_file" .stringData.githubAppInstallationID)
  github_app_private_key=$(provision::yaml_get "$app_file" .stringData.githubAppPrivateKey)
  
  # Create secret with ARC-expected key names
  kubectl -n "$NAMESPACE_RUNNER" create secret generic github-credentials \
    --from-literal=github_app_id="$github_app_id" \
    --from-literal=github_app_installation_id="$github_app_installation_id" \
    --from-literal=github_app_private_key="$github_app_private_key" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  info "✓ GitHub App credentials configured for ARC"
  
  # Also create github-app-credentials secret for runner pods
  kubectl -n "$NAMESPACE_RUNNER" create secret generic github-app-credentials \
    --from-literal=githubAppID="$github_app_id" \
    --from-literal=githubAppInstallationID="$github_app_installation_id" \
    --from-literal=githubAppPrivateKey="$github_app_private_key" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  info "✓ GitHub App credentials configured for runner pods"
  
  # Copy Nexus deployment credentials if available
  info "Checking for Nexus deployment credentials..."
  local NAMESPACE_NEXUS="${NAMESPACE_NEXUS:-nexus}"
  if kubectl get ns "$NAMESPACE_NEXUS" >/dev/null 2>&1 && \
     kubectl -n "$NAMESPACE_NEXUS" get secret nexus-deployment-credentials >/dev/null 2>&1; then
    
    local nexus_user nexus_pass
    nexus_user=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-deployment-credentials -o jsonpath='{.data.username}' | base64 -d)
    nexus_pass=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-deployment-credentials -o jsonpath='{.data.password}' | base64 -d)
    
    # Use cluster-internal service URL (no external DNS/Ingress needed)
    # Runners run inside the cluster and can access services directly
    local nexus_service_url="http://nexus.${NAMESPACE_NEXUS}.svc.cluster.local:8081"
    
    if [[ -n "$nexus_user" && -n "$nexus_pass" ]]; then
      # NEXUS_REGISTRY is the external hostname used by SBT resolvers for Nexus API access
      local nexus_registry="nexus-api.${HOSTNAME}"

      kubectl -n "$NAMESPACE_RUNNER" create secret generic nexus-credentials \
        --from-literal=username="$nexus_user" \
        --from-literal=password="$nexus_pass" \
        --from-literal=url="${nexus_service_url}" \
        --from-literal=registry="${nexus_registry}" \
        --dry-run=client -o yaml | kubectl apply -f -

      info "✓ Nexus deployment credentials copied to runner namespace"
      info "  Username: ${nexus_user}"
      info "  URL: ${nexus_service_url} (cluster-internal)"
      info "  Registry: ${nexus_registry} (external, for SBT resolvers)"
      info "  Runners can access via NEXUS_USERNAME, NEXUS_PASSWORD, NEXUS_URL, NEXUS_REGISTRY env vars"
    else
      warn "Nexus credentials found but values are empty"
    fi
  else
    info "  Nexus deployment credentials not found in namespace: ${NAMESPACE_NEXUS}"
    info "  Run 'tools/k3s/nexus.sh ${ENV_NAME}' to provision Nexus and create credentials"
    info "  Runners will not have NEXUS_USERNAME/NEXUS_PASSWORD environment variables"
  fi
  
  # Copy PostgreSQL credentials if available
  info "Checking for PostgreSQL credentials..."
  local NAMESPACE_POSTGRES="${NAMESPACE_POSTGRES:-postgres}"
  if kubectl get ns "$NAMESPACE_POSTGRES" >/dev/null 2>&1 && \
     kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app >/dev/null 2>&1; then
    
    local pg_host pg_port pg_user pg_pass pg_db
    pg_host=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app -o jsonpath='{.data.host}' 2>/dev/null | base64 -d 2>/dev/null || echo "postgres-cluster-rw.${NAMESPACE_POSTGRES}.svc.cluster.local")
    pg_port=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app -o jsonpath='{.data.port}' 2>/dev/null | base64 -d 2>/dev/null || echo "5432")
    pg_user=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app -o jsonpath='{.data.username}' | base64 -d)
    pg_pass=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app -o jsonpath='{.data.password}' | base64 -d)
    pg_db=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app -o jsonpath='{.data.dbname}' 2>/dev/null | base64 -d 2>/dev/null || echo "app")
    
    # Ensure host is set (CloudNativePG may not include it in secret)
    if [[ -z "$pg_host" ]]; then
      pg_host="postgres-cluster-rw.${NAMESPACE_POSTGRES}.svc.cluster.local"
    fi
    
    if [[ -n "$pg_user" && -n "$pg_pass" ]]; then
      kubectl -n "$NAMESPACE_RUNNER" create secret generic postgres-credentials \
        --from-literal=host="$pg_host" \
        --from-literal=port="$pg_port" \
        --from-literal=username="$pg_user" \
        --from-literal=password="$pg_pass" \
        --from-literal=database="$pg_db" \
        --from-literal=url="postgresql://${pg_user}:${pg_pass}@${pg_host}:${pg_port}/${pg_db}" \
        --dry-run=client -o yaml | kubectl apply -f -
      
      info "✓ PostgreSQL credentials copied to runner namespace"
      info "  Host: ${pg_host}"
      info "  Database: ${pg_db}"
      info "  Runners can access via POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USERNAME, POSTGRES_PASSWORD, POSTGRES_DATABASE, POSTGRES_URL env vars"
    else
      warn "PostgreSQL credentials found but values are empty"
    fi
  else
    info "  PostgreSQL credentials not found in namespace: ${NAMESPACE_POSTGRES}"
    info "  Run 'tools/k3s/postgres.sh ${ENV_NAME}' to provision PostgreSQL"
    info "  Runners will not have POSTGRES_* environment variables"
  fi
}

apply_github_credentials

# ============================================================================
# Phase 1b: Postgres Credentials Sync CronJob
# ============================================================================
# The postgres-credentials secret above is a point-in-time COPY of the CNPG
# postgres-cluster-app secret. When CNPG rotates the app password (cluster
# reprovision/rotation), the copy goes stale and every Postgres-dependent CI
# run fails with "password authentication failed". This CronJob re-syncs the
# copy every 10 minutes and recycles idle runner pods so they pick up the new
# env; busy runners are ephemeral and get fresh env after their current job.

provision_postgres_credentials_sync() {
  log "=== Phase 1b: Postgres Credentials Sync CronJob ==="
  local NAMESPACE_POSTGRES="${NAMESPACE_POSTGRES:-postgres}"

  if ! kubectl get ns "$NAMESPACE_POSTGRES" >/dev/null 2>&1 || \
     ! kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app >/dev/null 2>&1; then
    info "PostgreSQL not provisioned — skipping credentials sync CronJob"
    return 0
  fi

  sed -e "s/@NAMESPACE_RUNNER@/${NAMESPACE_RUNNER}/g" \
      -e "s/@NAMESPACE_POSTGRES@/${NAMESPACE_POSTGRES}/g" \
      -e "s/@RUNNER_SELECTOR@/runner-deployment-name=${ENV_NAME}-runners/g" <<'SYNCEOF' | kubectl apply -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: postgres-credentials-sync
  namespace: @NAMESPACE_RUNNER@
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: postgres-credentials-sync-read
  namespace: @NAMESPACE_POSTGRES@
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["postgres-cluster-app"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: postgres-credentials-sync-read
  namespace: @NAMESPACE_POSTGRES@
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: postgres-credentials-sync-read
subjects:
  - kind: ServiceAccount
    name: postgres-credentials-sync
    namespace: @NAMESPACE_RUNNER@
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: postgres-credentials-sync-write
  namespace: @NAMESPACE_RUNNER@
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["postgres-credentials"]
    verbs: ["get", "update", "patch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: postgres-credentials-sync-write
  namespace: @NAMESPACE_RUNNER@
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: postgres-credentials-sync-write
subjects:
  - kind: ServiceAccount
    name: postgres-credentials-sync
    namespace: @NAMESPACE_RUNNER@
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-credentials-sync
  namespace: @NAMESPACE_RUNNER@
spec:
  schedule: "*/10 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 300
      template:
        spec:
          serviceAccountName: postgres-credentials-sync
          restartPolicy: Never
          containers:
            - name: sync
              image: alpine/k8s:1.33.4
              env:
                - name: SRC_NS
                  value: @NAMESPACE_POSTGRES@
                - name: SRC_SECRET
                  value: postgres-cluster-app
                - name: DST_NS
                  value: @NAMESPACE_RUNNER@
                - name: DST_SECRET
                  value: postgres-credentials
                - name: RUNNER_POD_SELECTOR
                  value: @RUNNER_SELECTOR@
              command:
                - /bin/sh
                - -ec
                - |
                  src() { kubectl -n "$SRC_NS" get secret "$SRC_SECRET" -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true; }
                  dst() { kubectl -n "$DST_NS" get secret "$DST_SECRET" -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true; }
                  host=$(src host); [ -n "$host" ] || host="postgres-cluster-rw.${SRC_NS}.svc.cluster.local"
                  port=$(src port); [ -n "$port" ] || port=5432
                  user=$(src username); pass=$(src password)
                  db=$(src dbname); [ -n "$db" ] || db=app
                  if [ -z "$user" ] || [ -z "$pass" ]; then
                    echo "ERROR: source secret ${SRC_NS}/${SRC_SECRET} missing username/password"; exit 1
                  fi
                  if [ "$(dst username)" = "$user" ] && [ "$(dst password)" = "$pass" ] && [ "$(dst host)" = "$host" ]; then
                    echo "postgres-credentials in sync"; exit 0
                  fi
                  echo "drift detected: re-syncing ${DST_NS}/${DST_SECRET} from ${SRC_NS}/${SRC_SECRET}"
                  kubectl -n "$DST_NS" create secret generic "$DST_SECRET" \
                    --from-literal=host="$host" \
                    --from-literal=port="$port" \
                    --from-literal=username="$user" \
                    --from-literal=password="$pass" \
                    --from-literal=database="$db" \
                    --from-literal=url="postgresql://${user}:${pass}@${host}:${port}/${db}" \
                    --dry-run=client -o yaml | kubectl apply -f -
                  # Recycle idle runner pods so they pick up the new env.
                  # Busy runners are ephemeral: fresh pod (and env) after their current job.
                  for p in $(kubectl -n "$DST_NS" get pods -l "$RUNNER_POD_SELECTOR" -o name); do
                    if kubectl -n "$DST_NS" exec "${p#pod/}" -c runner -- pgrep -f 'Runner[.]Worker' >/dev/null 2>&1; then
                      echo "skip busy ${p}"
                    else
                      echo "recycling idle ${p}"
                      kubectl -n "$DST_NS" delete "${p}" --wait=false || true
                    fi
                  done
                  echo "re-sync complete"
SYNCEOF

  info "✓ postgres-credentials sync CronJob provisioned (every 10 min; recycles idle runners on drift)"
}

provision_postgres_credentials_sync

# ============================================================================
# Phase 2: Actions Runner Controller Installation
# ============================================================================

install_arc() {
  log "=== Phase 2: Actions Runner Controller Installation ==="
  
  # Add Helm repo
  if ! helm repo list 2>/dev/null | grep -q "actions-runner-controller"; then
    info "Adding Actions Runner Controller Helm repository..."
    helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller
  fi
  helm repo update actions-runner-controller
  
  # Render Helm values
  local values_file
  values_file=$(mktemp -t arc-values-XXXX.yaml)
  
  cat > "$values_file" <<EOF
authSecret:
  create: false
  name: github-credentials

githubWebhookServer:
  enabled: true
  service:
    type: ClusterIP
  ingress:
    enabled: false

replicaCount: 1
controllerManager:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
EOF
  
  info "Installing Actions Runner Controller via Helm..."
  helm upgrade --install actions-runner-controller \
    actions-runner-controller/actions-runner-controller \
    --namespace "$NAMESPACE_RUNNER" \
    --wait \
    --timeout 10m \
    -f "$values_file"
  
  # Cleanup temp file
  rm -f "$values_file"
  
  info "Waiting for ARC controller to be ready..."
  kubectl -n "$NAMESPACE_RUNNER" rollout status deploy/actions-runner-controller --timeout=180s || true
  
  info "✓ Actions Runner Controller installed successfully"
}

install_arc

# ============================================================================
# Phase 2b: Maven Settings Configuration
# ============================================================================

configure_maven_settings() {
  log "=== Phase 2b: Maven Settings Configuration ==="
  
  # Check if Nexus credentials are available
  if ! kubectl -n "$NAMESPACE_RUNNER" get secret nexus-credentials >/dev/null 2>&1; then
    warn "Nexus credentials not found in namespace: ${NAMESPACE_RUNNER}"
    warn "Maven settings will not be configured. Run 'tools/k3s/nexus.sh ${ENV_NAME}' first."
    return 0
  fi
  
  # Get Nexus URL from secret
  local nexus_url
  nexus_url=$(kubectl -n "$NAMESPACE_RUNNER" get secret nexus-credentials -o jsonpath='{.data.url}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  if [[ -z "$nexus_url" ]]; then
    warn "Nexus URL not found in credentials secret"
    return 0
  fi
  
  info "Configuring Maven settings for Nexus: ${nexus_url}"
  
  # Create Maven settings.xml ConfigMap
  # This settings.xml will be mounted into runner pods at /root/.m2/settings.xml
  # It configures Nexus as a transparent proxy for all Maven repositories
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: maven-settings
  namespace: ${NAMESPACE_RUNNER}
data:
  settings.xml: |
    <?xml version="1.0" encoding="UTF-8"?>
    <settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
              xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
              xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                                  http://maven.apache.org/xsd/settings-1.0.0.xsd">
      
      <!-- Server credentials for Nexus (read from environment variables) -->
      <servers>
        <server>
          <id>nexus</id>
          <username>\${env.NEXUS_USERNAME}</username>
          <password>\${env.NEXUS_PASSWORD}</password>
        </server>
        <server>
          <id>maven-releases</id>
          <username>\${env.NEXUS_USERNAME}</username>
          <password>\${env.NEXUS_PASSWORD}</password>
        </server>
        <server>
          <id>maven-snapshots</id>
          <username>\${env.NEXUS_USERNAME}</username>
          <password>\${env.NEXUS_PASSWORD}</password>
        </server>
      </servers>
      
      <!-- Mirror all Maven repositories through Nexus maven-public group -->
      <mirrors>
        <mirror>
          <id>nexus</id>
          <mirrorOf>*</mirrorOf>
          <url>${nexus_url}/repository/maven-public/</url>
        </mirror>
      </mirrors>
      
      <!-- Active profiles for deployment -->
      <profiles>
        <profile>
          <id>nexus</id>
          <repositories>
            <repository>
              <id>nexus</id>
              <url>${nexus_url}/repository/maven-public/</url>
              <releases>
                <enabled>true</enabled>
              </releases>
              <snapshots>
                <enabled>true</enabled>
              </snapshots>
            </repository>
          </repositories>
          <pluginRepositories>
            <pluginRepository>
              <id>nexus</id>
              <url>${nexus_url}/repository/maven-public/</url>
              <releases>
                <enabled>true</enabled>
              </releases>
              <snapshots>
                <enabled>true</enabled>
              </snapshots>
            </pluginRepository>
          </pluginRepositories>
        </profile>
      </profiles>
      
      <activeProfiles>
        <activeProfile>nexus</activeProfile>
      </activeProfiles>
    </settings>
EOF
  
  info "✓ Maven settings ConfigMap created"
  info "  All Maven dependencies will be proxied through: ${nexus_url}/repository/maven-public/"
  info "  Credentials will be read from NEXUS_USERNAME and NEXUS_PASSWORD environment variables"
}

configure_maven_settings

# ============================================================================
# Phase 2c: Build Base Builder Image
# ============================================================================

build_base_image() {
  # The builder base image of earlier iterations (images/builder -> library/base) is gone:
  # the custom runner image IS the build environment now (sbt, node, docker buildx, helm),
  # and applications start FROM library/teob-base, built by tools/k3s/base-image.sh
  # (up.sh step "base-image") from images/teob-base. Nothing to do here.
  log "=== Phase 2c: Base images ==="
  info "  build environment: the runner image (tools/k3s/runner-image.sh)"
  info "  application runtime base: harbor.${HOSTNAME}/library/teob-base (tools/k3s/base-image.sh)"
  return 0
}

# Skip base image build in bootstrap mode
if [[ "$BOOTSTRAP_MODE" == "false" ]]; then
  build_base_image
else
  info "Bootstrap mode: Skipping base image build"
fi

# ============================================================================
# Phase 2d: Detect Custom Runner Image
# ============================================================================

detect_custom_runner_image() {
  log "=== Phase 2d: Detect Custom Runner Image ==="
  
  # Skip detection in bootstrap mode
  if [[ "$BOOTSTRAP_MODE" == "true" ]]; then
    info "Bootstrap mode: Skipping custom runner image detection"
    return 0
  fi
  
  # If --custom-runner was explicitly passed, skip auto-detection
  # (We check if CUSTOM_RUNNER_IMAGE was set to true before this function runs)
  # Actually, we can't distinguish, so we'll always check and update if needed
  
  local harbor_host="harbor.${HOSTNAME}"
  local custom_runner_image="${RUNNER_IMAGE_REF:-${harbor_host}/library/github-runner:latest}"
  if [[ -n "${RUNNER_IMAGE_REF:-}" ]]; then
    # A source-controlled digest is an explicit operator choice; never silently
    # replace it with latest or a bootstrap image during subsequent provisioning.
    if [[ ! "$RUNNER_IMAGE_REF" =~ @sha256:[a-f0-9]{64}$ ]]; then
      provision::error "RUNNER_IMAGE_REF must be pinned by sha256 digest"
      return 1
    fi
    CUSTOM_RUNNER_IMAGE=true
    return 0
  fi
  
  info "Checking if custom runner image exists in Harbor..."
  
  # Check if Harbor credentials are available
  if ! kubectl -n harbor get secret harbor-robot-runner >/dev/null 2>&1; then
    info "  Harbor credentials not found, skipping custom runner image detection"
    return 0
  fi
  
  local harbor_user harbor_pass
  harbor_user=$(kubectl -n harbor get secret harbor-robot-runner -o jsonpath='{.data.username}' | base64 -d)
  harbor_pass=$(kubectl -n harbor get secret harbor-robot-runner -o jsonpath='{.data.password}' | base64 -d)
  
  # Check if the image exists via Harbor API (works from any machine, unlike docker pull)
  # Harbor returns HTTP 200 with an empty JSON array for a repository that does not exist
  # (observed on a fresh registry), so the status code alone is a false positive: require at
  # least one artifact in the response body.
  local api_body api_check artifact_count
  api_body=$(curl -sS -w '\n%{http_code}' -K <(provision::curl_user_cfg "$harbor_user" "$harbor_pass") \
    "https://${harbor_host}/api/v2.0/projects/library/repositories/github-runner/artifacts?page_size=1" 2>/dev/null || echo "000")
  api_check=${api_body##*$'\n'}
  artifact_count=$(printf '%s' "${api_body%$'\n'*}" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
  if [[ "$api_check" == "200" && "${artifact_count:-0}" -gt 0 ]]; then
    info "  ✓ Custom runner image found in Harbor: ${custom_runner_image}"
    
    # Check if runner deployment exists
    local runner_name="${ENV_NAME}-runners"
    if kubectl -n "$NAMESPACE_RUNNER" get runnerdeployment "${runner_name}" >/dev/null 2>&1; then
      # Get current image from deployment
      local current_image
      current_image=$(kubectl -n "$NAMESPACE_RUNNER" get runnerdeployment "${runner_name}" -o jsonpath='{.spec.template.spec.image}' 2>/dev/null || echo "")
      
      if [[ -n "$current_image" ]]; then
        if [[ "$current_image" == summerwind/actions-runner* ]]; then
          warn "  ⚠ Runner deployment exists but is using vanilla image"
          warn "  Current image: ${current_image}"
          warn "  Custom image available: ${custom_runner_image}"
          warn "  Auto-correcting: Will update deployment to use custom runner image"
          CUSTOM_RUNNER_IMAGE=true
        elif [[ "$current_image" == "${custom_runner_image}" ]]; then
          info "  ✓ Runner deployment already using custom runner image"
          # Ensure flag is set if not already
          CUSTOM_RUNNER_IMAGE=true
        else
          info "  ℹ Runner deployment using image: ${current_image}"
          info "  Custom runner image available but not being used"
          if [[ "$CUSTOM_RUNNER_IMAGE" != "true" ]]; then
            info "  To switch to custom image, run: $0 ${ENV_NAME} --custom-runner"
          fi
        fi
      else
        warn "  ⚠ Could not determine current runner image from deployment"
        warn "  Custom runner image available, will use it"
        CUSTOM_RUNNER_IMAGE=true
      fi
    else
      info "  ✓ Custom runner image found but no runner deployment exists"
      info "  Will create deployment with custom runner image"
      CUSTOM_RUNNER_IMAGE=true
    fi
  else
    info "  Custom runner image not found in Harbor: ${custom_runner_image}"
    if [[ "$CUSTOM_RUNNER_IMAGE" == "true" ]]; then
      warn "  ⚠ --custom-runner flag was set but custom image not found in Harbor"
      warn "  Will attempt to use custom image anyway (may fail if image doesn't exist)"
    else
      info "  Will use vanilla runner image (summerwind/actions-runner:v2.336.0-ubuntu-24.04)"
      info "  To build custom runner image, run:"
      info "    gh workflow run build-runner-image.yml -f environment=${ENV_NAME}"
    fi
  fi
}

detect_custom_runner_image

# ============================================================================
# Phase 3: Runner Deployment
# ============================================================================

create_runner_deployment() {
  log "=== Phase 3: Runner Deployment ==="
  
  # Get GitHub organization
  local oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
  local github_org
  github_org=$(provision::yaml_get "$oauth_file" .stringData.githubOrg)
  
  # Determine runner type and labels
  local runner_name runner_labels runner_replicas
  if [[ "$BOOTSTRAP_MODE" == "true" ]]; then
    runner_name="${ENV_NAME}-bootstrap-runners"
    runner_labels="self-hosted, linux, x64, ${ENV_NAME}, bootstrap"
    runner_replicas=1
    info "Creating BOOTSTRAP runner deployment for environment: ${ENV_NAME}..."
    info "  Purpose: Build base image and other bootstrap tasks"
  else
    runner_name="${ENV_NAME}-runners"
    runner_labels="self-hosted, linux, x64, ${ENV_NAME}"
    runner_replicas=2
    info "Creating runner deployment for environment: ${ENV_NAME}..."
    info "  Purpose: Regular CI/CD workflows"

    # Remove bootstrap runners to avoid label overlap (bootstrap labels are a
    # superset: self-hosted, linux, x64, <env>, bootstrap).  If the bootstrap
    # deployment is left around, GitHub may schedule jobs on the vanilla runner.
    local bootstrap_name="${ENV_NAME}-bootstrap-runners"
    if kubectl -n "$NAMESPACE_RUNNER" get runnerdeployment "${bootstrap_name}" >/dev/null 2>&1; then
      info "  Removing bootstrap runner deployment '${bootstrap_name}' (superseded by custom runners)..."
      kubectl -n "$NAMESPACE_RUNNER" delete runnerdeployment "${bootstrap_name}" --wait=false || true
    fi
  fi
  
  info "  Organization: ${github_org}"
  info "  Labels: ${runner_labels}"
  info "  Replicas: ${runner_replicas}"
  
  # Check if Nexus credentials are available
  local nexus_env_vars=""
  local maven_volume_mount=""
  local maven_volume=""
  
  if kubectl -n "$NAMESPACE_RUNNER" get secret nexus-credentials >/dev/null 2>&1; then
    nexus_env_vars="
            - name: NEXUS_USERNAME
              valueFrom:
                secretKeyRef:
                  name: nexus-credentials
                  key: username
            - name: NEXUS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: nexus-credentials
                  key: password
            - name: NEXUS_URL
              valueFrom:
                secretKeyRef:
                  name: nexus-credentials
                  key: url
            - name: NEXUS_REGISTRY
              valueFrom:
                secretKeyRef:
                  name: nexus-credentials
                  key: registry"
    info "  Will inject NEXUS_USERNAME, NEXUS_PASSWORD, NEXUS_URL, NEXUS_REGISTRY into runner pods"
    
    # Check if Maven settings ConfigMap exists
    if kubectl -n "$NAMESPACE_RUNNER" get configmap maven-settings >/dev/null 2>&1; then
      maven_volume_mount="
        - name: maven-settings
          mountPath: /root/.m2
          readOnly: true"
      maven_volume="
        - name: maven-settings
          configMap:
            name: maven-settings"
      info "  Will mount Maven settings.xml for transparent Nexus proxy"
    fi
  fi
  
  # Check if PostgreSQL credentials are available
  local postgres_env_vars=""
  if kubectl -n "$NAMESPACE_RUNNER" get secret postgres-credentials >/dev/null 2>&1; then
    postgres_env_vars="
            - name: POSTGRES_HOST
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: host
            - name: POSTGRES_PORT
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: port
            - name: POSTGRES_USERNAME
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: password
            - name: POSTGRES_DATABASE
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: database
            - name: POSTGRES_URL
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: url"
    info "  Will inject POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USERNAME, POSTGRES_PASSWORD, POSTGRES_DATABASE, POSTGRES_URL into runner pods"
  fi

  # Clean up any old PVCs from previous configurations
  info "Cleaning up old PVCs if they exist..."
  kubectl -n "$NAMESPACE_RUNNER" delete pvc "${ENV_NAME}-runner-docker-cache" 2>/dev/null || true
  kubectl -n "$NAMESPACE_RUNNER" delete pvc "${ENV_NAME}-runner-buildx-cache" 2>/dev/null || true
  
  # Configure persistent cache volumes using hostPath
  #
  # There is deliberately NO Docker layer cache here. `volumeMounts` in a
  # RunnerSpec lands on the *runner* container, while dockerd runs in the
  # injected `docker` sidecar — so a hostPath mounted at /var/lib/docker
  # caches nothing (measured: 188K after five months on a busy node) while
  # looking like it does. Moving it to `dockerVolumeMounts` is not the fix
  # either: with replicas > 1 every dind would share one data-root, and
  # dockerd requires exclusive access to it. Use a registry-backed cache
  # instead (`--cache-from/--cache-to type=registry`), as the Rust workflow
  # does.
  info "  Will mount hostPath volumes for the buildx and coursier caches"
  info "  Cache will persist on node filesystem at /var/lib/github-runner-cache/${ENV_NAME}/"

  local cache_volume_mounts="
        - name: buildx-cache
          mountPath: /tmp/.buildx-cache
        - name: coursier-cache
          mountPath: /home/runner/.cache/coursier${maven_volume_mount}"

  local cache_volumes="
        - name: buildx-cache
          hostPath:
            path: /var/lib/github-runner-cache/${ENV_NAME}/buildx
            type: DirectoryOrCreate
        - name: coursier-cache
          hostPath:
            path: /var/lib/github-runner-cache/${ENV_NAME}/coursier
            type: DirectoryOrCreate${maven_volume}"

  # Convert comma-separated labels to YAML array
  local labels_yaml=""
  IFS=',' read -ra LABEL_ARRAY <<< "$runner_labels"
  for label in "${LABEL_ARRAY[@]}"; do
    label=$(echo "$label" | xargs)  # trim whitespace
    labels_yaml="${labels_yaml}
        - ${label}"
  done

  # Determine runner image and pull policy
  local runner_image
  local image_pull_policy=""
  if [[ "$CUSTOM_RUNNER_IMAGE" == "true" ]]; then
    runner_image="${RUNNER_IMAGE_REF:-harbor.${HOSTNAME}/library/github-runner:latest}"
    image_pull_policy="Always"
    info "  Using custom runner image: ${runner_image}"
  else
    # NOT -dind: its entrypoint starts a second dockerd in the runner container that unlinks the
    # sidecar's containerd.sock at boot (see the probe comment in the manifest below).
    runner_image="summerwind/actions-runner:v2.336.0-ubuntu-24.04"
    info "  Using vanilla runner image: ${runner_image}"
  fi

  # Pods inherit flannel's MTU (1230 when the node's internal IP is its Tailscale address, as
  # the bare-metal script configures), but dockerd inside the runner pod defaults its bridge to
  # 1500. Larger packets from build containers are then silently dropped, so every big download
  # in an image build stalls or is reset ("Connection reset by peer" from get.helm.sh, Playwright
  # CDN timeouts). Hand the pod MTU to dockerd via ARC's dockerMTU. Probe it from a throwaway
  # pod; fall back to the Tailscale-derived value if the probe fails.
  local pod_mtu probe="mtu-probe-$$"
  kubectl -n "$NAMESPACE_RUNNER" run "$probe" --restart=Never --image=busybox:1.36 \
    --command -- cat /sys/class/net/eth0/mtu >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE_RUNNER" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${probe}" \
    --timeout=90s >/dev/null 2>&1 || true
  pod_mtu=$(kubectl -n "$NAMESPACE_RUNNER" logs "$probe" 2>/dev/null | tr -dc '0-9' || true)
  kubectl -n "$NAMESPACE_RUNNER" delete pod "$probe" --ignore-not-found >/dev/null 2>&1 || true
  [[ "$pod_mtu" =~ ^[0-9]{3,4}$ ]] || pod_mtu=1230
  info "  dockerd MTU inside runner pods: ${pod_mtu} (probed pod interface MTU)"

  kubectl apply -f - <<EOF
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: ${runner_name}
  namespace: ${NAMESPACE_RUNNER}
spec:
  replicas: ${runner_replicas}
  template:
    spec:
      organization: ${github_org}
      labels:${labels_yaml}
      dockerEnabled: true
      dockerMTU: ${pod_mtu}
      image: ${runner_image}$(if [[ -n "$image_pull_policy" ]]; then echo "
      imagePullPolicy: ${image_pull_policy}"; fi)
      # Entries here are merged by name into the containers ARC generates, so
      # this adds to the injected dind sidecar without redefining it.
      #
      # The env block MUST live on the \`runner\` entry, not on the top-level
      # \`env:\`. ARC v0.27.x only applies the top-level env when \`containers\`
      # is empty; the moment the docker sidecar below was added (2026-09-03) the
      # top-level env was silently dropped from every runner pod, and each
      # Deploy job died on
      #   [@octokit/auth-app] appId option is required
      # for twelve days before anyone looked at the pod's env instead of the
      # RunnerDeployment's. Image, mounts and RUNNER_* still come from ARC —
      # the merge is by container name, so this entry only contributes env.
      #
      # The probes are load-bearing. Without them a pod whose containerd socket
      # is gone still reports 2/2 Running, so the runner keeps accepting jobs it
      # cannot build; every one of them dies on
      #   failed to solve: dial /var/run/docker/containerd/containerd.sock: timeout
      # which reads like a broken commit rather than a broken node.
      #
      # Root cause (prod, 2026-10-09): the runner image was built FROM
      # actions-runner-dind, whose entrypoint starts its OWN dockerd in the runner
      # container next to this sidecar. Both share the pod's /run emptyDir; the
      # runner's dockerd dies on iptables ~1s after boot and its cleanup unlinks
      # /run/docker/containerd/containerd.sock -- the sidecar's live socket.
      # dockerd and buildkit keep working on the connections they already hold,
      # so builds pass until buildkit re-dials (~30 min idle), then fail forever.
      # The image is now the non-dind base (images/github-runner/Dockerfile).
      #
      # \`docker info\` does NOT catch this: it rides dockerd's long-lived
      # connection to containerd. Both probes therefore check the socket FILE and
      # open a fresh connection. The runner-container probe is the one that heals:
      # runner pods are restartPolicy Never, so a failed runner container
      # completes the pod and ARC replaces it; a killed sidecar alone would just
      # stay Terminated next to a runner that keeps taking jobs.
      #
      # The image is pinned because ARC's default is the floating \`docker:dind\`,
      # which silently rolls major versions under a long-lived deployment.
      containers:
        - name: runner
          env:
            - name: GITHUB_APP_ID
              valueFrom:
                secretKeyRef:
                  name: github-app-credentials
                  key: githubAppID
            - name: GITHUB_APP_PRIVATE_KEY
              valueFrom:
                secretKeyRef:
                  name: github-app-credentials
                  key: githubAppPrivateKey
            - name: JAVA_TOOL_OPTIONS
              value: "-XX:MaxRAMPercentage=85.0 -Dcats.effect.tracing.mode=none -XX:+UseParallelGC -XX:GCTimeRatio=4 -XX:AdaptiveSizePolicyWeight=90 -XX:+UseStringDeduplication"${nexus_env_vars}${postgres_env_vars}
          livenessProbe:
            exec:
              command:
                - sh
                - -c
                - sudo -n test -S /run/docker/containerd/containerd.sock && timeout 15 docker info >/dev/null
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 20
            failureThreshold: 3
        - name: docker
          image: docker:29.3-dind
          livenessProbe:
            exec:
              command:
                - sh
                - -c
                - >-
                  test -S /run/docker/containerd/containerd.sock &&
                  timeout 8 ctr --address /run/docker/containerd/containerd.sock version >/dev/null &&
                  timeout 8 docker info >/dev/null
            initialDelaySeconds: 30
            periodSeconds: 30
            timeoutSeconds: 20
            failureThreshold: 3
      # Increase termination grace period to allow dockerd to shut down gracefully
      # This helps prevent PreStopHook failures when pod is being terminated
      terminationGracePeriodSeconds: 300
      # Sized for JVM builds: a Scala 3 monorepo compile runs the sbt JVM past 6 GiB resident
      # (heap is capped by MaxRAMPercentage, but compiler, Zinc and metaspace are not), and the
      # cgroup then kills the runner mid-job with no log left on GitHub. Override per env in
      # env.properties: RUNNER_MEMORY_LIMIT / RUNNER_MEMORY_REQUEST / DOCKERD_MEMORY_LIMIT.
      dockerdContainerResources:
        limits:
          memory: "${DOCKERD_MEMORY_LIMIT:-8Gi}"
        requests:
          cpu: "500m"
          memory: "2Gi"
      resources:
        limits:
          memory: "${RUNNER_MEMORY_LIMIT:-16Gi}"
        requests:
          cpu: "500m"
          memory: "${RUNNER_MEMORY_REQUEST:-2Gi}"
      # kubelet creates a DirectoryOrCreate hostPath as root:root 0755, and the runner is
      # uid 1001. Without this the mount is unwritable and coursier silently falls back to
      # re-downloading everything on every job -- the failure mode looks like no cache at all.
      # Only the mountpoint is chowned; entries below it are written by the runner already.
      initContainers:
        - name: coursier-cache-perms
          image: busybox:1.37
          command: ["sh", "-c", "chown 1001:1001 /cache || true"]
          securityContext:
            runAsUser: 0
          volumeMounts:
            - name: coursier-cache
              mountPath: /cache
      volumeMounts:${cache_volume_mounts}
      volumes:${cache_volumes}
EOF
  
  info "✓ Runner deployment created"

  # Restart ARC controller to force clean reconciliation of runner registrations.
  # Without this, ephemeral runners consumed by cancelled jobs may leave stale
  # Runner CRDs that prevent new runners from registering with GitHub.
  info "Restarting ARC controller for clean runner registration..."
  kubectl -n "$NAMESPACE_RUNNER" rollout restart deploy/actions-runner-controller
  kubectl -n "$NAMESPACE_RUNNER" rollout status deploy/actions-runner-controller --timeout=60s || true

  info "  Runners will appear in GitHub org settings → Actions → Runners"
}

create_runner_deployment

# ============================================================================
# Phase 3b: Runner group access
# ============================================================================
# The runners register in the org's "Default" runner group. They run Docker-in-Docker,
# privileged: a job on them is root on the node, with the cluster's secrets in reach. By default
# that group admits every private repo of the org, so anyone who can push a workflow to any
# repo gets that. RUNNER_GROUP_REPOS (env.properties; repo names, space- or comma-separated)
# restricts the group to exactly those repos and keeps public repos out. The group is org-wide:
# every environment whose runners sit in it must carry the same list. A run that would take a
# repo out of the group stops unless --allow-runner-repo-removal is given (a stale list in one
# env must not lock another env's repos out). Empty: the group is left alone, with a warning
# when it is open to all repos.
RUNNER_GROUP_NAME="Default"

github_api() { # METHOD PATH [JSON] -> body, newline, HTTP code
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS --max-time 20 -X "$method" -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28" -w '\n%{http_code}')
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")
  curl "${args[@]}" -K <(printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN") \
    "${GITHUB_API_URL:-https://api.github.com}${path}" 2>/dev/null || printf '\n000'
}

restrict_runner_group() {
  log "=== Phase 3b: Runner group access ==="
  local org out code group visibility public_ok group_id
  org=$(provision::yaml_get "$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml" .stringData.githubOrg)
  GH_TOKEN=$(provision::github_get_installation_token) || { warn "No GitHub App token - runner group not checked"; return 1; }

  out=$(github_api GET "/orgs/${org}/actions/runner-groups?per_page=100")
  code=${out##*$'\n'}
  if [[ "$code" != "200" ]]; then
    warn "Cannot read the runner groups of ${org} (HTTP ${code}); the GitHub App needs the"
    warn "organization permission 'Self-hosted runners: Read and write'"
    return 1
  fi
  group=$(printf '%s' "${out%$'\n'*}" | jq -c --arg n "$RUNNER_GROUP_NAME" '[.runner_groups[] | select(.name == $n)][0] // empty')
  [[ -n "$group" ]] || { warn "No runner group '${RUNNER_GROUP_NAME}' in ${org}"; return 1; }
  group_id=$(jq -r .id <<<"$group")
  visibility=$(jq -r .visibility <<<"$group")
  public_ok=$(jq -r .allows_public_repositories <<<"$group")

  # Current members (only meaningful when visibility is "selected").
  local current="" page=1 names
  if [[ "$visibility" == "selected" ]]; then
    while :; do
      out=$(github_api GET "/orgs/${org}/actions/runner-groups/${group_id}/repositories?per_page=100&page=${page}")
      [[ "${out##*$'\n'}" == "200" ]] || { warn "Cannot list the repos of runner group ${RUNNER_GROUP_NAME}"; return 1; }
      names=$(printf '%s' "${out%$'\n'*}" | jq -r '.repositories[].name')
      [[ -n "$names" ]] || break
      current+="${names}"$'\n'
      page=$((page + 1))
    done
  fi
  current=$(printf '%s' "$current" | sed '/^$/d' | sort -u)

  local wanted repos_list="${RUNNER_GROUP_REPOS:-}"
  # shellcheck disable=SC2086  # split the list on spaces
  wanted=$(printf '%s\n' ${repos_list//,/ } | sed '/^$/d' | sort -u)
  if [[ -z "$wanted" ]]; then
    if [[ "$visibility" == "all" ]]; then
      warn "Runner group '${RUNNER_GROUP_NAME}' admits EVERY repo of ${org}; a workflow there runs as root on"
      warn "  this cluster's node. Set RUNNER_GROUP_REPOS in env.properties to the repos that build here."
    else
      info "Runner group '${RUNNER_GROUP_NAME}': ${visibility}, $(printf '%s' "$current" | grep -c . || true) repo(s); RUNNER_GROUP_REPOS unset - left alone"
    fi
    [[ "$public_ok" == "true" ]] && warn "Runner group '${RUNNER_GROUP_NAME}' allows public repositories - any fork PR could run on it"
    return 0
  fi

  local removed
  removed=$(comm -23 <(printf '%s\n' "$current" | sed '/^$/d') <(printf '%s\n' "$wanted"))
  if [[ -n "$removed" && "$ALLOW_RUNNER_REPO_REMOVAL" != "true" ]]; then
    err "RUNNER_GROUP_REPOS would take these repos out of runner group '${RUNNER_GROUP_NAME}': $(echo "$removed" | tr '\n' ' ')"
    err "  Another environment may rely on them (the group is org-wide). Add them to RUNNER_GROUP_REPOS,"
    err "  or re-run with --allow-runner-repo-removal. Nothing was changed."
    return 1
  fi
  # From "all", every repo not in the list loses the runners - the same risk, just unlisted.
  if [[ "$visibility" == "all" && "$ALLOW_RUNNER_REPO_REMOVAL" != "true" ]]; then
    err "Runner group '${RUNNER_GROUP_NAME}' admits every repo of ${org}; RUNNER_GROUP_REPOS would take out all"
    err "  repos not in the list, which another environment may rely on (the group is org-wide). Check the"
    err "  list, then re-run with --allow-runner-repo-removal. Nothing was changed."
    return 1
  fi

  local repo_ids repo id missing_repos=""
  repo_ids="[]"
  for repo in $wanted; do
    out=$(github_api GET "/repos/${org}/${repo}")
    id=$(printf '%s' "${out%$'\n'*}" | jq -r '.id // empty' 2>/dev/null)
    if [[ "${out##*$'\n'}" != "200" || -z "$id" ]]; then missing_repos+="${repo} "; continue; fi
    repo_ids=$(jq -c --argjson i "$id" '. + [$i]' <<<"$repo_ids")
  done
  if [[ -n "$missing_repos" ]]; then
    err "Unknown repos in RUNNER_GROUP_REPOS (or not visible to the GitHub App): ${missing_repos}- nothing changed"
    return 1
  fi

  if [[ "$visibility" == "selected" && "$public_ok" != "true" && "$current" == "$wanted" ]]; then
    info "✓ Runner group '${RUNNER_GROUP_NAME}' already admits exactly the $(jq length <<<"$repo_ids") listed repos"
    return 0
  fi
  out=$(github_api PATCH "/orgs/${org}/actions/runner-groups/${group_id}" \
    '{"visibility":"selected","allows_public_repositories":false}')
  [[ "${out##*$'\n'}" == "200" ]] || { err "Could not restrict runner group '${RUNNER_GROUP_NAME}' (HTTP ${out##*$'\n'})"; return 1; }
  out=$(github_api PUT "/orgs/${org}/actions/runner-groups/${group_id}/repositories" \
    "$(jq -cn --argjson repo_ids "$repo_ids" '{selected_repository_ids: $repo_ids}')")
  if [[ "${out##*$'\n'}" != "204" ]]; then
    err "Could not set the repos of runner group '${RUNNER_GROUP_NAME}' (HTTP ${out##*$'\n'})"
    # The group is "selected" now, with whatever list it had before (none, when it was "all"):
    # put the old visibility back rather than leave repos without runners.
    out=$(github_api PATCH "/orgs/${org}/actions/runner-groups/${group_id}" \
      "$(jq -cn --arg v "$visibility" --argjson p "$public_ok" '{visibility: $v, allows_public_repositories: $p}')")
    if [[ "${out##*$'\n'}" == "200" ]]; then
      err "  Visibility of '${RUNNER_GROUP_NAME}' set back to ${visibility}"
    else
      err "  Could not set the visibility back to ${visibility} (HTTP ${out##*$'\n'}) - fix it in Settings > Actions > Runner groups"
    fi
    return 1
  fi
  info "✓ Runner group '${RUNNER_GROUP_NAME}' restricted to $(jq length <<<"$repo_ids") repos (was: ${visibility})"
  [[ -n "$removed" ]] && info "  removed: $(echo "$removed" | tr '\n' ' ')"
  info "  Undo: Settings > Actions > Runner groups > ${RUNNER_GROUP_NAME} > Repository access: All"
  return 0
}

restrict_runner_group || warn "Runner group access not ensured - see above"

# ============================================================================
# Phase 4: Validation
# ============================================================================

validate_deployment() {
  log "=== Phase 4: Validation ==="
  
  local validation_failed=false
  
  # Validate ARC controller
  info "Validating ARC controller..."
  
  local arc_ready
  arc_ready=$(kubectl -n "$NAMESPACE_RUNNER" get pods -l app.kubernetes.io/name=actions-runner-controller -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  
  # Some setups may return multiple pods/values like "True True"; treat any True as ready
  if echo "$arc_ready" | grep -q "True"; then
    info "  ✓ ARC controller pod is Ready"
  else
    warn "  ✗ ARC controller pod not ready (status: ${arc_ready})"
    validation_failed=true
  fi
  
  # Check RunnerDeployment
  info "Validating runner deployment..."
  # Get runner_name from create_runner_deployment function context
  local runner_name
  if [[ "$BOOTSTRAP_MODE" == "true" ]]; then
    runner_name="${ENV_NAME}-bootstrap-runners"
  else
    runner_name="${ENV_NAME}-runners"
  fi
  
  if kubectl -n "$NAMESPACE_RUNNER" get runnerdeployment "${runner_name}" >/dev/null 2>&1; then
    info "  ✓ RunnerDeployment '${runner_name}' exists"
    
    # Wait for runner pods to be created (up to 60 seconds)
    info "  Waiting for runner pods to be created..."
    local runner_count=0
    local wait_attempts=12  # 12 * 5 = 60 seconds
    local attempt=0
    
    while [[ "$runner_count" -eq 0 && "$attempt" -lt "$wait_attempts" ]]; do
      runner_count=$(kubectl -n "$NAMESPACE_RUNNER" get pods -l runner-deployment-name="${runner_name}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
      if [[ "$runner_count" -eq 0 ]]; then
        sleep 5
        attempt=$((attempt + 1))
      fi
    done
    
    if [[ "$runner_count" -gt 0 ]]; then
      info "  ✓ ${runner_count} runner pod(s) created"
      
      # Show pod readiness status
      local ready_count
      # `|| true`: under `set -o pipefail` grep exits 1 when no pod is Ready yet, which would
      # abort the whole script here (observed as a silent "Step FAILED" right after
      # "runner pod(s) created").
      ready_count=$(kubectl -n "$NAMESPACE_RUNNER" get pods -l runner-deployment-name="${runner_name}" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l | tr -d ' ' || true)
      ready_count=${ready_count:-0}
      if [[ "$ready_count" -gt 0 ]]; then
        info "  ✓ ${ready_count}/${runner_count} runner pod(s) ready"
      else
        info "  ℹ Runner pods are starting (not ready yet)"
      fi
    else
      warn "  ⚠ No runner pods created after $(( wait_attempts * 5 ))s"
      warn "    Check status: kubectl -n ${NAMESPACE_RUNNER} describe runnerdeployment ${runner_name}"
    fi
  else
    warn "  ✗ RunnerDeployment '${runner_name}' not found"
    validation_failed=true
  fi
  
  # Summary
  if [[ "$validation_failed" == "true" ]]; then
    warn ""
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn "  Some validations failed"
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn ""
    warn "Check status with:"
    warn "  kubectl -n ${NAMESPACE_RUNNER} get pods"
    warn "  kubectl -n ${NAMESPACE_RUNNER} get runnerdeployment"
    warn "  kubectl -n ${NAMESPACE_RUNNER} logs -l app.kubernetes.io/name=actions-runner-controller"
    warn ""
    return 1
  else
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  ✓ All validations passed"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
  fi
}

validate_deployment

# ============================================================================
# Summary
# ============================================================================

log "=== CI provisioning completed for environment: ${ENV_NAME} ==="
info ""
info "Services provisioned:"
info "  ✓ Actions Runner Controller (namespace: ${NAMESPACE_RUNNER})"
info "  ✓ Base builder image (harbor.${HOSTNAME}/library/base:latest)"
info "  ✓ Runner Deployment: ${ENV_NAME}-runners"
info "  ✓ Persistent cache:  Buildx (/var/lib/github-runner-cache/${ENV_NAME}/buildx)"
info ""

# Get GitHub organization for summary
oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
github_org=$(provision::yaml_get "$oauth_file" .stringData.githubOrg 2>/dev/null || echo "N/A")

info "Configuration:"
info "  GitHub organization: ${github_org}"
info "  Runner labels: self-hosted, linux, x64, ${ENV_NAME}"
if [[ "$BOOTSTRAP_MODE" == "true" ]]; then
  info "  Runner replicas: 1 (bootstrap)"
else
  info "  Runner replicas: 2"
fi
if [[ "$CUSTOM_RUNNER_IMAGE" == "true" ]]; then
  info "  Runner image: ${RUNNER_IMAGE_REF:-harbor.${HOSTNAME}/library/github-runner:latest} (custom)"
else
  info "  Runner image: summerwind/actions-runner:v2.336.0-ubuntu-24.04 (vanilla)"
fi
info ""
info "Runners will appear in GitHub:"
info "  https://github.com/organizations/${github_org}/settings/actions/runners"
info ""
info "Use in GitHub Actions workflows:"
info "  jobs:"
info "    build:"
info "      runs-on: [self-hosted, linux, ${ENV_NAME}]"
info ""
info "Monitor runners:"
info "  kubectl -n ${NAMESPACE_RUNNER} get pods -l runner-deployment-name=${ENV_NAME}-runners"
info "  kubectl -n ${NAMESPACE_RUNNER} logs -l runner-deployment-name=${ENV_NAME}-runners -f"
info ""
info "Troubleshoot runner issues:"
info "  # Check if pods were OOMKilled (most common cause of unexpected stops)"
info "  kubectl -n ${NAMESPACE_RUNNER} get pods -l runner-deployment-name=${ENV_NAME}-runners -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.status.containerStatuses[*].lastState.terminated.reason}{\"\\t\"}{.status.containerStatuses[*].lastState.terminated.message}{\"\\n\"}{end}'"
info ""
info "  # Check pod events for termination reasons (including PreStopHook failures)"
info "  kubectl -n ${NAMESPACE_RUNNER} get events --sort-by='.lastTimestamp' | grep -iE 'runner|oom|kill|evict|prestop'"
info ""
info "  # Check pod status and resource usage"
info "  kubectl -n ${NAMESPACE_RUNNER} top pods -l runner-deployment-name=${ENV_NAME}-runners"
info ""
info "  # Describe a specific pod to see full status"
info "  kubectl -n ${NAMESPACE_RUNNER} describe pod <pod-name>"
info ""
info "  # Check node resources (runner may be evicted due to node pressure)"
info "  kubectl top nodes"
info "  kubectl describe nodes | grep -A 10 'Allocated resources'"
info ""
info "Common issues:"
info "  - OOMKilled: Increase memory limits (currently 4Gi per runner + 4Gi for dockerd)"
info "    → Most common cause of unexpected stops during sbt compile"
info "    → Also causes PreStopHook failures (dockerd becomes unresponsive)"
info "  - PreStopHook failures: Usually symptom of OOM, fixed by increasing memory limits"
info "    → terminationGracePeriodSeconds set to 300s to allow graceful shutdown"
info "  - Node pressure: Check node resources, may need more nodes or reduce other workloads"
info "  - Health check failures: Check pod logs for errors"
info ""
