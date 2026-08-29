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
#   tools/k3s/github-action-runner.sh <env-name> [--bootstrap] [--custom-runner]
#
# Options:
#   --bootstrap      Create bootstrap runners for building images (vanilla runner)
#                    Use this for initial provisioning
#   --custom-runner  Use custom runner image with pre-installed build tools
#                    Eliminates need for job container, faster workflow startup
#
# Workflow (Option A - Custom Runner Image, Recommended):
#   1. Bootstrap:        tools/k3s/github-action-runner.sh dev --bootstrap
#   2. Build base image: gh workflow run build-builder-image.yml -f environment=dev
#   3. Build runner:     gh workflow run build-runner-image.yml -f environment=dev
#   4. Deploy runners:   tools/k3s/github-action-runner.sh dev --custom-runner
#   5. Remove container: directive from workflows
#
# Workflow (Option B - Job Container, Simpler):
#   1. Bootstrap:        tools/k3s/github-action-runner.sh dev --bootstrap
#   2. Build base image: gh workflow run build-builder-image.yml -f environment=dev
#   3. Deploy runners:   tools/k3s/github-action-runner.sh dev
#   4. Keep container: directive (image pulled on each run)

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

# --- Parse arguments ---
if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--bootstrap]" >&2
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
while [[ $# -gt 0 ]]; do
  case "$1" in
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
  log "=== Phase 2c: Build Base Builder Image ==="
  
  local harbor_host="harbor.${HOSTNAME}"
  local image_name="library/base:latest"
  local full_image="${harbor_host}/${image_name}"
  
  # Check if base image already exists in Harbor
  info "Checking if base image exists in Harbor..."
  if kubectl -n harbor get secret harbor-robot-runner >/dev/null 2>&1; then
    local harbor_user harbor_pass
    harbor_user=$(kubectl -n harbor get secret harbor-robot-runner -o jsonpath='{.data.username}' | base64 -d)
    harbor_pass=$(kubectl -n harbor get secret harbor-robot-runner -o jsonpath='{.data.password}' | base64 -d)
    
    # Try to pull the image to check if it exists
    if docker login "${harbor_host}" -u "${harbor_user}" -p "${harbor_pass}" >/dev/null 2>&1 && \
       docker pull "${full_image}" >/dev/null 2>&1; then
      info "  ✓ Base image already exists in Harbor: ${full_image}"
      info "  Skipping build. To rebuild, delete the image from Harbor or run:"
      info "    gh workflow run build-builder-image.yml -f environment=${ENV_NAME}"
      return 0
    fi
  fi
  
  warn "Base image not found in Harbor: ${full_image}"
  warn ""
  warn "The base image must be built for linux/amd64 architecture."
  warn "Building from arm64 Macs will create incompatible images."
  warn ""
  warn "Options:"
  warn "  1. Build via GitHub Actions workflow (recommended):"
  warn "     gh workflow run build-builder-image.yml -f environment=${ENV_NAME}"
  warn ""
  warn "  2. Build locally if on amd64 Linux:"
  warn "     docker buildx build --platform linux/amd64 \\"
  warn "       --build-arg HARBOR_REGISTRY=${harbor_host} \\"
  warn "       -t ${full_image} images/builder"
  warn "     docker push ${full_image}"
  warn ""
  warn "Skipping base image build. Runners will fail until image is available."
  return 0
  
  # Old auto-build code (commented out due to architecture issues)
  # info "Base image not found in Harbor. Building and pushing..."
  
  # Check if we have the builder Dockerfile
  if [[ ! -f "$REPO_ROOT/images/builder/Dockerfile" ]]; then
    err "Builder Dockerfile not found at: $REPO_ROOT/images/builder/Dockerfile"
    err "Cannot build base image. Please create the Dockerfile or push the image manually."
    return 1
  fi
  
  # Check if helm.tgz exists (required by Dockerfile)
  if [[ ! -f "$REPO_ROOT/images/builder/helm.tgz" ]]; then
    warn "helm.tgz not found. Downloading Helm v3.19.0..."
    local helm_version="v3.19.0"
    wget -q "https://get.helm.sh/helm-${helm_version}-linux-amd64.tar.gz" \
      -O "$REPO_ROOT/images/builder/helm.tgz" || {
      err "Failed to download Helm. Please download manually to images/builder/helm.tgz"
      return 1
    }
  fi
  
  info "Building base image..."
  info "  Context: $REPO_ROOT/images/builder"
  info "  Image: ${full_image}"
  info "  Platform: linux/amd64"
  
  # Ensure buildx is available for cross-platform builds
  if ! docker buildx version >/dev/null 2>&1; then
    warn "docker buildx not available. Trying regular docker build..."
    docker build \
      --platform linux/amd64 \
      --build-arg HARBOR_REGISTRY="${harbor_host}" \
      -t "${full_image}" \
      "$REPO_ROOT/images/builder" || {
      err "Failed to build base image"
      return 1
    }
  else
    # Use buildx for better cross-platform support
    info "Using docker buildx for cross-platform build"
    docker buildx build \
      --platform linux/amd64 \
      --build-arg HARBOR_REGISTRY="${harbor_host}" \
      --load \
      -t "${full_image}" \
      "$REPO_ROOT/images/builder" || {
      err "Failed to build base image"
      return 1
    }
  fi
  
  info "✓ Base image built successfully"
  
  # Login to Harbor and push
  info "Pushing base image to Harbor..."
  if kubectl -n harbor get secret harbor-robot-runner >/dev/null 2>&1; then
    local harbor_user harbor_pass
    harbor_user=$(kubectl -n harbor get secret harbor-robot-runner -o jsonpath='{.data.username}' | base64 -d)
    harbor_pass=$(kubectl -n harbor get secret harbor-robot-runner -o jsonpath='{.data.password}' | base64 -d)
    
    docker login "${harbor_host}" -u "${harbor_user}" -p "${harbor_pass}" || {
      err "Failed to login to Harbor"
      return 1
    }
    
    docker push "${full_image}" || {
      err "Failed to push base image to Harbor"
      return 1
    }
    
    info "✓ Base image pushed to Harbor: ${full_image}"
  else
    err "Harbor robot account credentials not found"
    err "Cannot push base image. Please push manually or provision Harbor first."
    return 1
  fi
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
  local custom_runner_image="${harbor_host}/library/github-runner:latest"
  
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
  local api_check
  api_check=$(curl -sS -o /dev/null -w "%{http_code}" -u "${harbor_user}:${harbor_pass}" \
    "https://${harbor_host}/api/v2.0/projects/library/repositories/github-runner/artifacts?page_size=1" 2>/dev/null || echo "000")
  if [[ "$api_check" == "200" ]]; then
    info "  ✓ Custom runner image found in Harbor: ${custom_runner_image}"
    
    # Check if runner deployment exists
    local runner_name="${ENV_NAME}-runners"
    if kubectl -n "$NAMESPACE_RUNNER" get runnerdeployment "${runner_name}" >/dev/null 2>&1; then
      # Get current image from deployment
      local current_image
      current_image=$(kubectl -n "$NAMESPACE_RUNNER" get runnerdeployment "${runner_name}" -o jsonpath='{.spec.template.spec.image}' 2>/dev/null || echo "")
      
      if [[ -n "$current_image" ]]; then
        if [[ "$current_image" == "summerwind/actions-runner-dind:latest" ]]; then
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
      info "  Will use vanilla runner image (summerwind/actions-runner-dind:latest)"
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
  info "  Will mount hostPath volumes for Docker layer cache and buildx cache"
  info "  Caches will persist on node filesystem at /var/lib/github-runner-cache/${ENV_NAME}/"
  
  local cache_volume_mounts="
        - name: docker-cache
          mountPath: /var/lib/docker
        - name: buildx-cache
          mountPath: /tmp/.buildx-cache${maven_volume_mount}"
  
  local cache_volumes="
        - name: docker-cache
          hostPath:
            path: /var/lib/github-runner-cache/${ENV_NAME}/docker
            type: DirectoryOrCreate
        - name: buildx-cache
          hostPath:
            path: /var/lib/github-runner-cache/${ENV_NAME}/buildx
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
    runner_image="harbor.${HOSTNAME}/library/github-runner:latest"
    image_pull_policy="Always"
    info "  Using custom runner image: ${runner_image}"
  else
    runner_image="summerwind/actions-runner-dind:latest"
    info "  Using vanilla runner image: ${runner_image}"
  fi

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
      dockerEnabled: true
      image: ${runner_image}$(if [[ -n "$image_pull_policy" ]]; then echo "
      imagePullPolicy: ${image_pull_policy}"; fi)
      # Increase termination grace period to allow dockerd to shut down gracefully
      # This helps prevent PreStopHook failures when pod is being terminated
      terminationGracePeriodSeconds: 300
      dockerdContainerResources:
        limits:
          memory: "6Gi"
        requests:
          cpu: "500m"
          memory: "2Gi"
      resources:
        limits:
          memory: "6Gi"
        requests:
          cpu: "500m"
          memory: "2Gi"
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
      ready_count=$(kubectl -n "$NAMESPACE_RUNNER" get pods -l runner-deployment-name="${runner_name}" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l | tr -d ' ')
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
info "  ✓ Persistent caches: Docker (/var/lib/github-runner-cache/${ENV_NAME}/docker)"
info "                       Buildx (/var/lib/github-runner-cache/${ENV_NAME}/buildx)"
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
  info "  Runner image: harbor.${HOSTNAME}/library/github-runner:latest (custom)"
else
  info "  Runner image: summerwind/actions-runner-dind:latest (vanilla)"
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
