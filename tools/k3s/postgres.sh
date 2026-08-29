#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# K3S PostgreSQL Provisioning (CloudNativePG Operator)
# ============================================================================
# Provisions PostgreSQL infrastructure using CloudNativePG operator:
# 1. CloudNativePG operator (PostgreSQL operator)
# 2. Single-master PostgreSQL cluster (no replicas) with pgvector extension
# 3. pgweb web management tool
# 4. Pomerium integration for pgweb access
#
# Usage:
#   tools/k3s/postgres.sh <env-name> [options]
#
# Options:
#   --skip-operator          Skip operator installation (use existing)
#   --skip-pgweb             Skip pgweb installation
#   --force-cleanup          Force cleanup of existing resources before installation
#   --show-credentials [app-id]  Display PostgreSQL credentials and exit (app-id for app-specific creds)
#   --show-resources         Display current PostgreSQL resource usage and exit
#   --watch [kind]           Watch/inspect a running cluster (kind: help|cluster|pods|events|logs|operator-logs|sql|exporter|services|pvc)
#   --provision-credentials <app-id>  Provision database credentials for an application
#   --dump-table <table>     Dump a specific table (use --database to specify database, --output to specify file)
#   --database <dbname>      Database name for dump-table (default: app)
#   --output <file>          Output file for dump-table (default: stdout)
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

# --- Parse arguments ---
if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--skip-operator] [--skip-pgweb] [--force-cleanup] [--show-credentials [app-id]] [--show-resources] [--watch [kind]] [--provision-credentials <app-id>] [--dump-table <table> [--database <dbname>] [--output <file>]]" >&2
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

# Parse optional flags
SKIP_OPERATOR=false
SKIP_PGWEB=false
SHOW_CREDENTIALS=false
SHOW_RESOURCES=false
FORCE_CLEANUP=false
WATCH=false
WATCH_KIND="help"
PROVISION_CREDENTIALS=false
APP_ID=""
SHOW_CREDENTIALS_APP_ID=""
DUMP_TABLE=false
DUMP_TABLE_NAME=""
DUMP_DATABASE=""
DUMP_OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-operator) SKIP_OPERATOR=true; shift ;;
    --skip-pgweb) SKIP_PGWEB=true; shift ;;
    --force-cleanup) FORCE_CLEANUP=true; shift ;;
    --show-credentials)
      SHOW_CREDENTIALS=true
      if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
        SHOW_CREDENTIALS_APP_ID="$2"
        shift 2
      else
        shift
      fi
      ;;
    --show-resources) SHOW_RESOURCES=true; shift ;;
    --watch)
      WATCH=true
      if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
        WATCH_KIND="$2"
        shift 2
      else
        WATCH_KIND="help"
        shift
      fi
      ;;
    --provision-credentials)
      PROVISION_CREDENTIALS=true
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --provision-credentials requires an app-id argument" >&2
        exit 1
      fi
      APP_ID="$2"
      shift 2
      ;;
    --dump-table)
      DUMP_TABLE=true
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --dump-table requires a table name argument" >&2
        exit 1
      fi
      DUMP_TABLE_NAME="$2"
      shift 2
      ;;
    --database)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --database requires a database name argument" >&2
        exit 1
      fi
      DUMP_DATABASE="$2"
      shift 2
      ;;
    --output)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --output requires a file path argument" >&2
        exit 1
      fi
      DUMP_OUTPUT="$2"
      shift 2
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validation ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
need kubectl
need helm
need jq
need yq

if ! provision::require_tools; then
  exit 1
fi

# Validate kubectl context matches environment
if ! provision::validate_kubectl_context; then
  exit 1
fi

# --- Logging helpers ---
log() { echo "[postgres] $*"; }
info() { echo "[postgres:info] $*"; }
warn() { echo "[postgres:warn] $*" >&2; }
err() { echo "[postgres:error] $*" >&2; }

# --- Config defaults ---
NAMESPACE_POSTGRES="${NAMESPACE_POSTGRES:-postgres}"
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"
: "${INGRESS_CLASS:=traefik}"
: "${CLUSTER_ISSUER:=letsencrypt-prod}"
: "${POSTGRES_STORAGE_CLASS:=local-path}"
: "${POSTGRES_STORAGE_SIZE:=50Gi}"
: "${POSTGRES_INSTANCES:=1}"
: "${ENFORCE_POMERIUM:=true}"
# PostgreSQL image - must be CNPG-compatible (requires specific version tag format)
# Use ghcr.io/cloudnative-pg/postgresql for vanilla PG, or ghcr.io/tensorchord/cloudnative-pgvecto.rs for pgvector
: "${POSTGRES_IMAGE:=ghcr.io/cloudnative-pg/postgresql:16.6}"

# CloudNativePG operator settings
# Note: CNPG_VERSION is the Helm chart version, not the operator version
# Chart 0.22.0 = Operator 1.24.0, Chart 0.26.1 = Operator 1.27.1
CNPG_NAMESPACE="${CNPG_NAMESPACE:-cnpg-system}"
CNPG_VERSION="${CNPG_VERSION:-0.22.0}"

# Derive hosts from HOSTNAME if not provided
if [[ -n "${HOSTNAME:-}" ]]; then
  PGWEB_HOST="${PGWEB_HOST:-pgweb.${HOSTNAME}}"
  info "Service host: PGWEB_HOST=${PGWEB_HOST}"
fi

# Validate required configuration
if [[ -z "${PGWEB_HOST:-}" ]] && [[ "$SKIP_PGWEB" != "true" ]]; then
  err "PGWEB_HOST is not set. Set HOSTNAME in env.properties or PGWEB_HOST explicitly."
  exit 1
fi

if [[ -z "${EXTERNAL_IP:-}" ]]; then
  err "EXTERNAL_IP is not set in env.properties"
  exit 1
fi

# ============================================================================
# Show Credentials Mode
# ============================================================================
show_credentials() {
  local app_id="${1:-}"
  local namespace="$NAMESPACE_POSTGRES"

  if [[ -n "$app_id" ]]; then
    # App-specific credentials from <app-id>-db secret
    local secret_name="${app_id}-db"
    local app_namespace="${APP_NAMESPACE:-default}"

    if ! kubectl -n "$app_namespace" get secret "$secret_name" >/dev/null 2>&1; then
      err "Credentials secret '${secret_name}' not found in namespace '${app_namespace}'"
      err "Provision credentials first: tools/k3s/postgres.sh ${ENV_NAME} --provision-credentials ${app_id}"
      exit 1
    fi

    # App secrets use POSTGRES_* keys (created by --provision-credentials)
    local username password host port dbname
    username=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.POSTGRES_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null || true)
    password=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
    host=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.POSTGRES_HOST}' 2>/dev/null | base64 -d 2>/dev/null || true)
    port=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.POSTGRES_PORT}' 2>/dev/null | base64 -d 2>/dev/null || true)
    dbname=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.POSTGRES_DATABASE}' 2>/dev/null | base64 -d 2>/dev/null || true)

    if [[ -z "$username" || -z "$password" ]]; then
      err "Failed to retrieve credentials from secret '${secret_name}' in namespace '${app_namespace}'"
      exit 1
    fi

    echo "POSTGRES_HOST=${host:-postgres-cluster-rw.${namespace}.svc.cluster.local}"
    echo "POSTGRES_PORT=${port:-5432}"
    echo "POSTGRES_DATABASE=${dbname:-${app_id}}"
    echo "POSTGRES_USERNAME=${username}"
    echo "POSTGRES_PASSWORD=${password}"
    echo ""
    echo "# Connection string:"
    echo "POSTGRES_URL=postgresql://${username}:${password}@${host:-postgres-cluster-rw.${namespace}.svc.cluster.local}:${port:-5432}/${dbname:-${app_id}}"
    echo ""
    echo "# Secret: ${secret_name} (namespace: ${app_namespace})"

    exit 0
  fi

  # Generic cluster credentials (postgres-cluster-app)
  if ! kubectl -n "$namespace" get secret postgres-cluster-app >/dev/null 2>&1; then
    err "PostgreSQL credentials secret not found in namespace: $namespace"
    err "Run provisioning first: tools/k3s/postgres.sh ${ENV_NAME}"
    exit 1
  fi

  # Cluster-generated secrets use lowercase keys
  local username password host port dbname
  username=$(kubectl -n "$namespace" get secret postgres-cluster-app -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
  password=$(kubectl -n "$namespace" get secret postgres-cluster-app -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  host=$(kubectl -n "$namespace" get secret postgres-cluster-app -o jsonpath='{.data.host}' 2>/dev/null | base64 -d 2>/dev/null || true)
  port=$(kubectl -n "$namespace" get secret postgres-cluster-app -o jsonpath='{.data.port}' 2>/dev/null | base64 -d 2>/dev/null || true)
  dbname=$(kubectl -n "$namespace" get secret postgres-cluster-app -o jsonpath='{.data.dbname}' 2>/dev/null | base64 -d 2>/dev/null || true)

  if [[ -z "$username" || -z "$password" ]]; then
    err "Failed to retrieve credentials from secret"
    exit 1
  fi

  echo "POSTGRES_HOST=${host:-postgres-cluster-rw.${namespace}.svc.cluster.local}"
  echo "POSTGRES_PORT=${port:-5432}"
  echo "POSTGRES_DATABASE=${dbname:-app}"
  echo "POSTGRES_USERNAME=${username}"
  echo "POSTGRES_PASSWORD=${password}"
  echo ""
  echo "# Connection string:"
  echo "POSTGRES_URL=postgresql://${username}:${password}@${host:-postgres-cluster-rw.${namespace}.svc.cluster.local}:${port:-5432}/${dbname:-app}"

  exit 0
}

if [[ "$SHOW_CREDENTIALS" == "true" ]]; then
  show_credentials "$SHOW_CREDENTIALS_APP_ID"
fi


# ============================================================================
# Show Resources Mode
# ============================================================================
show_resources() {
  local namespace="$NAMESPACE_POSTGRES"
  
  # Check if cluster exists
  if ! kubectl -n "$namespace" get cluster postgres-cluster >/dev/null 2>&1; then
    err "PostgreSQL cluster not found in namespace: $namespace"
    err "Run provisioning first: tools/k3s/postgres.sh ${ENV_NAME}"
    exit 1
  fi
  
  echo "=== PostgreSQL Resource Usage ==="
  echo ""
  
  # Get cluster spec resources
  echo "--- Configured Resources (from Cluster spec) ---"
  kubectl -n "$namespace" get cluster postgres-cluster -o jsonpath='{.spec.resources}' 2>/dev/null | jq . 2>/dev/null || echo "Unable to retrieve spec"
  echo ""
  
  # Get pod resource usage via kubectl top
  echo "--- Current Resource Usage (kubectl top) ---"
  if kubectl top pods -n "$namespace" -l cnpg.io/cluster=postgres-cluster 2>/dev/null; then
    :
  else
    echo "Metrics not available (metrics-server may not be installed)"
  fi
  echo ""
  
  # Get pod resource requests/limits
  echo "--- Pod Resource Requests/Limits ---"
  kubectl -n "$namespace" get pods -l cnpg.io/cluster=postgres-cluster -o custom-columns=\
'NAME:.metadata.name,'\
'CPU_REQ:.spec.containers[0].resources.requests.cpu,'\
'CPU_LIM:.spec.containers[0].resources.limits.cpu,'\
'MEM_REQ:.spec.containers[0].resources.requests.memory,'\
'MEM_LIM:.spec.containers[0].resources.limits.memory' 2>/dev/null || echo "Unable to retrieve pod resources"
  echo ""
  
  # Get storage usage
  echo "--- Storage Usage ---"
  kubectl -n "$namespace" get pvc -l cnpg.io/cluster=postgres-cluster -o custom-columns=\
'NAME:.metadata.name,'\
'CAPACITY:.status.capacity.storage,'\
'STORAGE_CLASS:.spec.storageClassName' 2>/dev/null || echo "Unable to retrieve PVC info"
  echo ""
  
  # Get cluster status
  echo "--- Cluster Status ---"
  kubectl -n "$namespace" get cluster postgres-cluster -o custom-columns=\
'NAME:.metadata.name,'\
'PHASE:.status.phase,'\
'INSTANCES:.spec.instances,'\
'READY:.status.readyInstances' 2>/dev/null || echo "Unable to retrieve cluster status"
  
  exit 0
}

if [[ "$SHOW_RESOURCES" == "true" ]]; then
  show_resources
fi

# ============================================================================
# Watch/Inspect Mode (Operational Helpers)
# ============================================================================
watch_cluster() {
  local kind="${1:-help}"
  local namespace="$NAMESPACE_POSTGRES"

  if ! kubectl -n "$namespace" get cluster postgres-cluster >/dev/null 2>&1; then
    err "PostgreSQL cluster not found in namespace: $namespace"
    err "Run provisioning first: tools/k3s/postgres.sh ${ENV_NAME}"
    exit 1
  fi

  case "$kind" in
    help|--help|-h)
      cat <<EOF
=== PostgreSQL Watch/Inspect Toolbox (CloudNativePG) ===

Run one of:
  tools/k3s/postgres.sh ${ENV_NAME} --watch cluster         # Cluster status changes (CNPG Cluster CR)
  tools/k3s/postgres.sh ${ENV_NAME} --watch pods            # Pod scheduling/restarts/ready changes
  tools/k3s/postgres.sh ${ENV_NAME} --watch events          # Namespace events stream
  tools/k3s/postgres.sh ${ENV_NAME} --watch logs            # Postgres instance logs (all pods)
  tools/k3s/postgres.sh ${ENV_NAME} --watch operator-logs   # CNPG operator logs
  tools/k3s/postgres.sh ${ENV_NAME} --watch sql             # Open psql into primary (superuser if available)
  tools/k3s/postgres.sh ${ENV_NAME} --watch exporter        # Port-forward postgres-exporter metrics (9187)
  tools/k3s/postgres.sh ${ENV_NAME} --watch services        # Show services/endpoints/PVs/PVCs (snapshot)
  tools/k3s/postgres.sh ${ENV_NAME} --watch pvc             # Watch PVC/PV binding and usage (snapshot)

Useful one-liners (run manually, in separate terminals):
  kubectl -n ${namespace} get cluster postgres-cluster -o yaml | sed -n '/^status:/,\$p'
  kubectl -n ${namespace} get pods -l cnpg.io/cluster=postgres-cluster -o wide
  kubectl -n ${namespace} describe pod -l cnpg.io/cluster=postgres-cluster | sed -n '1,200p'
  kubectl -n ${namespace} logs -l cnpg.io/cluster=postgres-cluster --all-containers --tail=200

CNPG-specific (optional kubectl plugin):
  kubectl cnpg status -n ${namespace} postgres-cluster
  kubectl cnpg report -n ${namespace} postgres-cluster

SQL snippets (inside psql):
  \\conninfo
  SELECT now(), inet_server_addr(), inet_server_port();
  SELECT pg_is_in_recovery();
  SELECT * FROM pg_stat_activity ORDER BY query_start DESC NULLS LAST LIMIT 50;
  SELECT * FROM pg_stat_replication;
  SELECT * FROM pg_stat_wal_receiver;
EOF
      exit 0
      ;;

    cluster)
      info "Watching CNPG cluster status: ${namespace}/postgres-cluster"
      kubectl -n "$namespace" get cluster postgres-cluster -w
      ;;

    pods)
      info "Watching PostgreSQL pods: cnpg.io/cluster=postgres-cluster"
      kubectl -n "$namespace" get pods -l cnpg.io/cluster=postgres-cluster -w
      ;;

    events)
      info "Watching Kubernetes events in namespace: ${namespace}"
      kubectl -n "$namespace" get events --watch
      ;;

    logs)
      info "Tailing PostgreSQL logs (all cluster pods)..."
      kubectl -n "$namespace" logs -l cnpg.io/cluster=postgres-cluster -f --tail=200 --all-containers
      ;;

    operator-logs)
      info "Tailing CNPG operator logs in namespace: ${CNPG_NAMESPACE}"
      kubectl -n "$CNPG_NAMESPACE" logs deploy/cnpg-cloudnative-pg -f --tail=200
      ;;

    sql)
      local pg_pod
      pg_pod=$(kubectl -n "$namespace" get pods -l cnpg.io/cluster=postgres-cluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [[ -z "$pg_pod" ]]; then
        err "No PostgreSQL pod found in cluster"
        exit 1
      fi

      local user pass
      if kubectl -n "$namespace" get secret postgres-cluster-superuser >/dev/null 2>&1; then
        user=$(kubectl -n "$namespace" get secret postgres-cluster-superuser -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "postgres")
        pass=$(kubectl -n "$namespace" get secret postgres-cluster-superuser -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
        info "Opening psql as superuser '${user}' in pod: ${pg_pod}"
      else
        warn "Superuser secret not found; falling back to app credentials"
        user=$(kubectl -n "$namespace" get secret postgres-cluster-app -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "app")
        pass=$(kubectl -n "$namespace" get secret postgres-cluster-app -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
        info "Opening psql as app user '${user}' in pod: ${pg_pod}"
      fi

      kubectl -n "$namespace" exec -it "$pg_pod" -- env PGPASSWORD="${pass}" psql -U "$user" -d postgres
      ;;

    exporter)
      if ! kubectl -n "$namespace" get svc postgres-exporter >/dev/null 2>&1; then
        err "Service not found: ${namespace}/postgres-exporter"
        err "If you just provisioned, re-run: tools/k3s/postgres.sh ${ENV_NAME}"
        exit 1
      fi
      info "Port-forwarding postgres-exporter to localhost:9187"
      info "Open: http://127.0.0.1:9187/metrics"
      kubectl -n "$namespace" port-forward svc/postgres-exporter 9187:9187
      ;;

    services)
      echo "=== Services / Endpoints (snapshot) ==="
      kubectl -n "$namespace" get svc -o wide
      echo ""
      kubectl -n "$namespace" get endpoints -o wide || true
      echo ""
      echo "=== CNPG objects (snapshot) ==="
      kubectl -n "$namespace" get cluster,backup,scheduledbackup,pooler 2>/dev/null || true
      ;;

    pvc)
      echo "=== PVCs (snapshot) ==="
      kubectl -n "$namespace" get pvc -o wide
      echo ""
      echo "=== PVs (snapshot) ==="
      kubectl get pv | (grep -E "postgres|cnpg|${namespace}" || true)
      ;;

    *)
      err "Unknown watch kind: ${kind}"
      err "Run: tools/k3s/postgres.sh ${ENV_NAME} --watch help"
      exit 1
      ;;
  esac
}

if [[ "$WATCH" == "true" ]]; then
  watch_cluster "$WATCH_KIND"
fi

# ============================================================================
# Provision Credentials Mode
# ============================================================================
provision_credentials() {
  local app_id="$1"
  local namespace="$NAMESPACE_POSTGRES"
  local app_namespace="${APP_NAMESPACE:-default}"
  
  # Validate app_id (alphanumeric and hyphens only, for safety)
  if [[ ! "$app_id" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    err "Invalid app-id: ${app_id}"
    err "App ID must be lowercase alphanumeric with hyphens (e.g., 'my-app', 'evse')"
    exit 1
  fi
  
  log "=== Provisioning PostgreSQL credentials for application: ${app_id} ==="
  
  # Check if cluster exists and is ready
  if ! kubectl -n "$namespace" get cluster postgres-cluster >/dev/null 2>&1; then
    err "PostgreSQL cluster not found in namespace: $namespace"
    err "Run provisioning first: tools/k3s/postgres.sh ${ENV_NAME}"
    exit 1
  fi
  
  # Check cluster status
  local phase
  phase=$(kubectl -n "$namespace" get cluster postgres-cluster -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [[ "$phase" != "Cluster in healthy state" ]]; then
    warn "PostgreSQL cluster is not in healthy state (phase: ${phase})"
    warn "Credentials provisioning may fail. Continue anyway? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi
  
  # Get superuser credentials
  if ! kubectl -n "$namespace" get secret postgres-cluster-superuser >/dev/null 2>&1; then
    err "PostgreSQL superuser secret not found"
    err "Run provisioning first: tools/k3s/postgres.sh ${ENV_NAME}"
    exit 1
  fi
  
  local pg_host="postgres-cluster-rw.${namespace}.svc.cluster.local"
  local pg_port="5432"
  local superuser
  local superpass
  superuser=$(kubectl -n "$namespace" get secret postgres-cluster-superuser -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "postgres")
  superpass=$(kubectl -n "$namespace" get secret postgres-cluster-superuser -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  
  if [[ -z "$superpass" ]]; then
    err "Failed to retrieve superuser password"
    exit 1
  fi
  
  # Generate app credentials
  local app_username="${app_id}"
  local app_password
  app_password=$(openssl rand -base64 24 | tr -d '\n')
  local app_database="${app_id}"
  
  info "Creating database user and database: ${app_username}/${app_database}"
  
  # Find a PostgreSQL pod to execute commands
  local pg_pod
  pg_pod=$(kubectl -n "$namespace" get pods -l cnpg.io/cluster=postgres-cluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -z "$pg_pod" ]]; then
    err "No PostgreSQL pod found in cluster"
    exit 1
  fi
  
  # Create database and user
  info "Creating database '${app_database}' and user '${app_username}'..."
  
  # Create user (or update password if exists)
  kubectl -n "$namespace" exec "$pg_pod" -- psql -U "$superuser" -d postgres -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = '${app_username}') THEN CREATE USER ${app_username} WITH PASSWORD '${app_password}'; ELSE ALTER USER ${app_username} WITH PASSWORD '${app_password}'; END IF; END \$\$;" || {
    err "Failed to create/update database user"
    exit 1
  }
  
  # Create database if not exists
  kubectl -n "$namespace" exec "$pg_pod" -- psql -U "$superuser" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '${app_database}'" | grep -q 1 || \
    kubectl -n "$namespace" exec "$pg_pod" -- psql -U "$superuser" -d postgres -c "CREATE DATABASE ${app_database} OWNER ${app_username};" || {
    err "Failed to create database"
    exit 1
  }
  
  # Grant privileges including ability to create extensions
  kubectl -n "$namespace" exec "$pg_pod" -- psql -U "$superuser" -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${app_database} TO ${app_username};" || {
    warn "Failed to grant privileges (database may already have correct permissions)"
  }
  
  # Grant CREATE privilege on the database schema to allow extension creation
  kubectl -n "$namespace" exec "$pg_pod" -- psql -U "$superuser" -d "${app_database}" -c "GRANT CREATE ON SCHEMA public TO ${app_username};" || {
    warn "Failed to grant CREATE privilege on schema public"
  }
  
  # Pre-install common extensions as superuser so app user can use them
  info "Pre-installing common PostgreSQL extensions..."
  kubectl -n "$namespace" exec "$pg_pod" -- psql -U "$superuser" -d "${app_database}" -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null || \
    warn "pgvector extension not available (image may not include it)"
  kubectl -n "$namespace" exec "$pg_pod" -- psql -U "$superuser" -d "${app_database}" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" 2>/dev/null || true
  kubectl -n "$namespace" exec "$pg_pod" -- psql -U "$superuser" -d "${app_database}" -c "CREATE EXTENSION IF NOT EXISTS btree_gin;" 2>/dev/null || true
  kubectl -n "$namespace" exec "$pg_pod" -- psql -U "$superuser" -d "${app_database}" -c "CREATE EXTENSION IF NOT EXISTS btree_gist;" 2>/dev/null || true

  info "✓ Database and user created"
  
  # Create secret file
  local secrets_dir="$ENVS_ROOT/${ENV_NAME}/secrets.plain"
  local secret_file="${secrets_dir}/${app_id}-db.secret.yaml"
  
  # Ensure secrets directory exists
  mkdir -p "$secrets_dir"
  
  # Create secret YAML file
  info "Creating secret file: ${secret_file}"
  cat > "$secret_file" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${app_id}-db
  namespace: ${app_namespace}
type: Opaque
stringData:
  # PostgreSQL host
  POSTGRES_HOST: ${pg_host}

  # PostgreSQL port
  POSTGRES_PORT: "${pg_port}"

  # PostgreSQL database name
  POSTGRES_DATABASE: ${app_database}

  # PostgreSQL username
  POSTGRES_USERNAME: ${app_username}

  # PostgreSQL password
  POSTGRES_PASSWORD: ${app_password}
YAML

  info "✓ Secret file created"
  
  # Ensure namespace exists
  kubectl get ns "$app_namespace" >/dev/null 2>&1 || kubectl create ns "$app_namespace"
  
  # Apply to kubectl
  info "Applying secret to Kubernetes..."
  kubectl apply -f "$secret_file" || {
    err "Failed to apply secret to Kubernetes"
    exit 1
  }
  
  info "✓ Secret applied to namespace: ${app_namespace}"
  
  # Output summary
  echo ""
  info "=== Credentials Provisioned ==="
  info "Application ID:     ${app_id}"
  info "Database:           ${app_database}"
  info "Username:           ${app_username}"
  info "Secret name:        ${app_id}-db"
  info "Secret namespace:   ${app_namespace}"
  info "Secret file:        ${secret_file}"
  info ""
  info "Connection details:"
  info "  Host:             ${pg_host}"
  info "  Port:             ${pg_port}"
  info "  Database:         ${app_database}"
  info "  Username:         ${app_username}"
  info ""
  info "Secret fields:"
  info "  POSTGRES_HOST"
  info "  POSTGRES_PORT"
  info "  POSTGRES_DATABASE"
  info "  POSTGRES_USERNAME"
  info "  POSTGRES_PASSWORD"
  echo ""
  
  exit 0
}

if [[ "$PROVISION_CREDENTIALS" == "true" ]]; then
  provision_credentials "$APP_ID"
fi

# ============================================================================
# Dump Table Mode
# ============================================================================
dump_table() {
  local table_name="$1"
  local database="${2:-app}"
  local output_file="${3:-}"
  local namespace="$NAMESPACE_POSTGRES"
  
  log "=== Dumping PostgreSQL table: ${database}.${table_name} ==="
  
  # Check if cluster exists
  if ! kubectl -n "$namespace" get cluster postgres-cluster >/dev/null 2>&1; then
    err "PostgreSQL cluster not found in namespace: $namespace"
    err "Run provisioning first: tools/k3s/postgres.sh ${ENV_NAME}"
    exit 1
  fi
  
  # Find a PostgreSQL pod
  local pg_pod
  pg_pod=$(kubectl -n "$namespace" get pods -l cnpg.io/cluster=postgres-cluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -z "$pg_pod" ]]; then
    err "No PostgreSQL pod found in cluster"
    exit 1
  fi
  
  # Get superuser credentials (prefer superuser for full access)
  local user pass
  if kubectl -n "$namespace" get secret postgres-cluster-superuser >/dev/null 2>&1; then
    user=$(kubectl -n "$namespace" get secret postgres-cluster-superuser -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "postgres")
    pass=$(kubectl -n "$namespace" get secret postgres-cluster-superuser -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    info "Using superuser credentials for dump"
  else
    warn "Superuser secret not found; falling back to app credentials"
    if kubectl -n "$namespace" get secret postgres-cluster-app >/dev/null 2>&1; then
      user=$(kubectl -n "$namespace" get secret postgres-cluster-app -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "app")
      pass=$(kubectl -n "$namespace" get secret postgres-cluster-app -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    else
      err "No PostgreSQL credentials found"
      exit 1
    fi
  fi
  
  if [[ -z "$pass" ]]; then
    err "Failed to retrieve password"
    exit 1
  fi
  
  # Verify table exists
  info "Verifying table exists: ${database}.${table_name}"
  if ! kubectl -n "$namespace" exec "$pg_pod" -- env PGPASSWORD="$pass" psql -U "$user" -d "$database" -tc "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '${table_name}'" | grep -q 1; then
    err "Table '${table_name}' not found in database '${database}'"
    err "Available tables:"
    kubectl -n "$namespace" exec "$pg_pod" -- env PGPASSWORD="$pass" psql -U "$user" -d "$database" -c "\dt" 2>/dev/null || true
    exit 1
  fi
  
  info "Dumping table: ${database}.${table_name}"
  info "Pod: ${pg_pod}"
  info "User: ${user}"
  
  # Perform the dump
  if [[ -n "$output_file" ]]; then
    info "Output file: ${output_file}"
    kubectl -n "$namespace" exec "$pg_pod" -- env PGPASSWORD="$pass" pg_dump -U "$user" -d "$database" -t "$table_name" --no-owner --no-acl > "$output_file" || {
      err "Failed to dump table"
      exit 1
    }
    info "✓ Table dumped to: ${output_file}"
  else
    info "Dumping to stdout..."
    kubectl -n "$namespace" exec "$pg_pod" -- env PGPASSWORD="$pass" pg_dump -U "$user" -d "$database" -t "$table_name" --no-owner --no-acl || {
      err "Failed to dump table"
      exit 1
    }
  fi
  
  exit 0
}

if [[ "$DUMP_TABLE" == "true" ]]; then
  if [[ -z "$DUMP_TABLE_NAME" ]]; then
    err "--dump-table requires a table name"
    exit 1
  fi
  dump_table "$DUMP_TABLE_NAME" "${DUMP_DATABASE:-app}" "$DUMP_OUTPUT"
fi

log "Starting PostgreSQL provisioning for environment: ${ENV_NAME}"

# ============================================================================
# Phase 0: DNS Management
# ============================================================================
ensure_dns_records() {
  log "=== Phase 0: DNS Management ==="

  if ! provision::cloudflare_read_token 2>/dev/null; then
    warn "Cloudflare API token not found. Skipping DNS record creation."
    warn "DNS records must be created manually or via other means."
    return 0
  fi

  # If wildcard exists for env, skip specific record
  if [[ -n "${HOSTNAME:-}" ]] && provision::cloudflare_check_wildcard "$HOSTNAME"; then
    info "Wildcard DNS record found: ${WILDCARD_PATTERN} -> ${WILDCARD_IP}"
    info "Wildcard covers pgweb access - skipping individual record creation"
  else
    # Create DNS record for pgweb
    if [[ -n "${PGWEB_HOST:-}" ]]; then
      provision::cloudflare_ensure_dns_record "$PGWEB_HOST" "$EXTERNAL_IP" || \
        warn "Failed to create DNS record for $PGWEB_HOST"
    fi
  fi

  info "✓ DNS records ensured"
}

ensure_dns_records

# ============================================================================
# Phase 1: Install CloudNativePG Operator
# ============================================================================
install_cnpg_operator() {
  log "=== Phase 1: CloudNativePG Operator ==="

  if [[ "$SKIP_OPERATOR" == "true" ]]; then
    info "Skipping operator installation (--skip-operator)"
    return 0
  fi

  # Force cleanup if requested
  if [[ "$FORCE_CLEANUP" == "true" ]]; then
    info "Force cleanup requested - removing existing operator resources"
    helm uninstall cnpg --namespace "$CNPG_NAMESPACE" --ignore-not-found=true
    kubectl delete ns "$CNPG_NAMESPACE" --ignore-not-found=true
    # Note: CRDs are not deleted as they might be needed by existing clusters
    info "✓ Force cleanup completed"
  fi

  # Check if already installed
  # First check if CRDs exist (most reliable indicator)
  if kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; then
    info "✓ CloudNativePG CRDs already configured"

    # Check if operator is running
    if kubectl -n "$CNPG_NAMESPACE" get deploy cnpg-cloudnative-pg >/dev/null 2>&1; then
      info "CloudNativePG operator already installed and running"
      return 0
    else
      warn "CloudNativePG CRDs exist but operator deployment not found"
      warn "This might indicate an incomplete installation"
    fi
  fi

  # Additional check for namespace and deployment
  if kubectl get ns "$CNPG_NAMESPACE" >/dev/null 2>&1 && \
     kubectl -n "$CNPG_NAMESPACE" get deploy cnpg-cloudnative-pg >/dev/null 2>&1; then
    info "CloudNativePG operator already installed"
    return 0
  fi

  # Add Helm repo
  if ! helm repo list 2>/dev/null | grep -q cloudnative-pg; then
    helm repo add cnpg https://cloudnative-pg.github.io/charts
  fi
  helm repo update

  # Install CloudNativePG operator
  info "Installing CloudNativePG operator v${CNPG_VERSION}..."
  helm upgrade --install cnpg cnpg/cloudnative-pg \
    --namespace "$CNPG_NAMESPACE" \
    --create-namespace \
    --version "$CNPG_VERSION" \
    --wait \
    --timeout 5m

  # Wait for operator to be ready
  info "Waiting for CloudNativePG operator to be ready..."
  kubectl -n "$CNPG_NAMESPACE" rollout status deployment/cnpg-cloudnative-pg --timeout=120s

  info "✓ CloudNativePG operator installed"
}

install_cnpg_operator

# ============================================================================
# Enable pgvector extension in PostgreSQL databases
# ============================================================================
enable_pgvector_extension() {
  local namespace="$NAMESPACE_POSTGRES"
  
  # Wait a bit for the database to be fully ready
  sleep 5
  
  # Find a PostgreSQL pod
  local pg_pod
  pg_pod=$(kubectl -n "$namespace" get pods -l cnpg.io/cluster=postgres-cluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -z "$pg_pod" ]]; then
    warn "No PostgreSQL pod found - skipping pgvector extension enablement"
    return 0
  fi
  
  # Get superuser credentials
  if ! kubectl -n "$namespace" get secret postgres-cluster-superuser >/dev/null 2>&1; then
    warn "PostgreSQL superuser secret not found - skipping pgvector extension enablement"
    return 0
  fi
  
  local superuser superpass
  superuser=$(kubectl -n "$namespace" get secret postgres-cluster-superuser -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "postgres")
  superpass=$(kubectl -n "$namespace" get secret postgres-cluster-superuser -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  
  if [[ -z "$superpass" ]]; then
    warn "Failed to retrieve superuser password - skipping pgvector extension enablement"
    return 0
  fi
  
  # Enable extension in postgres database (template database)
  info "Enabling pgvector extension in PostgreSQL..."
  if kubectl -n "$namespace" exec "$pg_pod" -- env PGPASSWORD="$superpass" psql -U "$superuser" -d postgres -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    info "✓ pgvector extension enabled in postgres database"
  else
    warn "⚠ Failed to enable pgvector extension in postgres database (may already be enabled or image may not include pgvector)"
  fi
  
  # Enable extension in app database
  if kubectl -n "$namespace" exec "$pg_pod" -- env PGPASSWORD="$superpass" psql -U "$superuser" -d app -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    info "✓ pgvector extension enabled in app database"
  else
    warn "⚠ Failed to enable pgvector extension in app database (may already be enabled or image may not include pgvector)"
  fi
}

# ============================================================================
# Phase 2: Create PostgreSQL Cluster
# ============================================================================
create_postgres_cluster() {
  log "=== Phase 2: PostgreSQL Cluster ==="

  # Create namespace
  kubectl get ns "$NAMESPACE_POSTGRES" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_POSTGRES"

  # Check if cluster already exists
  if kubectl -n "$NAMESPACE_POSTGRES" get cluster postgres-cluster >/dev/null 2>&1; then
    info "PostgreSQL cluster already exists"

    # Check cluster status
    local phase
    phase=$(kubectl -n "$NAMESPACE_POSTGRES" get cluster postgres-cluster -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    info "Cluster phase: ${phase}"

    # Ensure required secrets exist (CloudNativePG operator should create them but sometimes doesn't)
    if ! kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-superuser >/dev/null 2>&1; then
      warn "PostgreSQL superuser secret missing - creating it manually"
      kubectl -n "$NAMESPACE_POSTGRES" create secret generic postgres-cluster-superuser \
        --from-literal=username="postgres" \
        --from-literal=password="$(openssl rand -base64 24)"
    fi
    if ! kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app >/dev/null 2>&1; then
      warn "PostgreSQL app secret missing - creating it manually"
      kubectl -n "$NAMESPACE_POSTGRES" create secret generic postgres-cluster-app \
        --from-literal=username="app" \
        --from-literal=password="$(openssl rand -base64 24)" \
        --from-literal=host="postgres-cluster-rw.${NAMESPACE_POSTGRES}.svc.cluster.local" \
        --from-literal=port="5432" \
        --from-literal=dbname="app"
    fi

    if [[ "$phase" == "Cluster in healthy state" ]]; then
      info "✓ PostgreSQL cluster is healthy"
      # Try to enable pgvector extension in existing cluster
      enable_pgvector_extension
      return 0
    else
      info "Waiting for cluster to become healthy..."
    fi
  else
    # Create the PostgreSQL cluster
    info "Creating single-master PostgreSQL cluster..."
    cat <<YAML | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-cluster
  namespace: ${NAMESPACE_POSTGRES}
spec:
  description: "PostgreSQL cluster for ${ENV_NAME}"
  imageName: ${POSTGRES_IMAGE}
  
  # Single master, no replicas
  instances: ${POSTGRES_INSTANCES}
  
  # Enable superuser access (creates postgres-cluster-superuser secret)
  enableSuperuserAccess: true

  # Primary update strategy
  primaryUpdateStrategy: unsupervised
  
  # Storage configuration
  storage:
    size: ${POSTGRES_STORAGE_SIZE}
    storageClass: ${POSTGRES_STORAGE_CLASS}
  
  # PostgreSQL configuration
  postgresql:
    parameters:
      max_connections: "100"
      shared_buffers: "256MB"
      effective_cache_size: "512MB"
      maintenance_work_mem: "64MB"
      checkpoint_completion_target: "0.9"
      wal_buffers: "16MB"
      default_statistics_target: "100"
      random_page_cost: "1.1"
      effective_io_concurrency: "200"
      work_mem: "4MB"
      min_wal_size: "1GB"
      max_wal_size: "4GB"
    pg_hba:
      - host all all 10.0.0.0/8 md5
      - host all all 172.16.0.0/12 md5
      - host all all 192.168.0.0/16 md5
  
  # Bootstrap configuration
  bootstrap:
    initdb:
      database: app
      owner: app
      # Let CloudNativePG auto-generate credentials for the superuser and app user.
      # This will create the following secrets automatically:
      #   - postgres-cluster-superuser
      #   - postgres-cluster-app
      # We intentionally do not reference a pre-existing secret here to avoid
      # mount failures when the secret does not exist yet.
  
  # Backup configuration (optional - can be enabled later)
  # backup:
  #   barmanObjectStore:
  #     ...
  
  # Monitoring
  monitoring:
    enablePodMonitor: false
  
  # Resource limits
  resources:
    requests:
      memory: "1Gi"
      cpu: "500m"
    limits:
      memory: "2Gi"
      cpu: "2000m"
YAML
  fi

  # Wait for cluster to be ready (15 minutes timeout - initial setup can take time)
  info "Waiting for PostgreSQL cluster to be ready (timeout: 15 minutes)..."
  local ready=false
  for i in {1..90}; do
    local phase
    phase=$(kubectl -n "$NAMESPACE_POSTGRES" get cluster postgres-cluster -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    local ready_instances
    ready_instances=$(kubectl -n "$NAMESPACE_POSTGRES" get cluster postgres-cluster -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
    
    if [[ "$phase" == "Cluster in healthy state" ]] && [[ "${ready_instances:-0}" -ge 1 ]]; then
      ready=true
      break
    fi
    
    # Show progress every 30 seconds (every 3rd iteration)
    if (( i % 3 == 0 )); then
      info "  Cluster status: phase=${phase}, readyInstances=${ready_instances:-0} (${i}0s elapsed...)"
    fi
    sleep 10
  done

  if [[ "$ready" != "true" ]]; then
    warn "PostgreSQL cluster did not become ready in time (15 minutes)"
    warn "Check status with: kubectl -n $NAMESPACE_POSTGRES get cluster postgres-cluster"
    warn ""
    warn "Diagnostic information:"
    warn "--- Cluster Status ---"
    kubectl -n "$NAMESPACE_POSTGRES" get cluster postgres-cluster -o yaml 2>/dev/null | grep -A 20 "status:" || true
    warn ""
    warn "--- Pod Status ---"
    kubectl -n "$NAMESPACE_POSTGRES" get pods -l cnpg.io/cluster=postgres-cluster 2>/dev/null || true
    warn ""
    warn "--- Recent Events ---"
    kubectl -n "$NAMESPACE_POSTGRES" get events --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
    warn ""
    warn "The cluster may still be initializing. You can continue to monitor with:"
    warn "  kubectl -n $NAMESPACE_POSTGRES get cluster postgres-cluster -w"
    warn "  kubectl -n $NAMESPACE_POSTGRES logs -l cnpg.io/cluster=postgres-cluster -f"
    # Don't return 1 - allow script to continue for pgweb setup
    # The cluster will eventually become ready
    return 0
  fi

  info "✓ PostgreSQL cluster is ready"
  
  # Enable pgvector extension in the database if not already enabled
  enable_pgvector_extension
}

create_postgres_cluster

# ============================================================================
# Phase 3: Deploy PostgreSQL Exporter for Prometheus Metrics
# ============================================================================
deploy_postgres_exporter() {
  log "=== Phase 3: PostgreSQL Exporter Deployment ==="

  # Wait for cluster to be ready and get credentials
  if ! kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app >/dev/null 2>&1; then
    warn "PostgreSQL app credentials not found - skipping postgres_exporter deployment"
    warn "Run provisioning again after cluster is ready"
    return 0
  fi

  # Get PostgreSQL connection info
  local pg_host pg_port pg_db
  pg_host="postgres-cluster-rw.${NAMESPACE_POSTGRES}.svc.cluster.local"
  pg_port="5432"
  pg_db="postgres"  # Connect to postgres database for metrics collection

  # Credentials are read straight from the CNPG-managed postgres-cluster-app secret at pod start
  # (DATA_SOURCE_USER/PASS), never copied into a second secret. The previous version baked the
  # password into a DATA_SOURCE_NAME DSN in postgres-exporter-credentials, which silently went
  # stale every time CNPG rotated the app password: the exporter then logged
  #   password authentication failed for user "app"
  # forever, pg_up dropped to 0, and every pg_* panel in the Grafana postgres dashboards went
  # blank with no alert. That drift has bitten repeatedly, on more than one env. A rotation
  # now only needs a pod restart, not a manual secret re-sync.
  kubectl -n "$NAMESPACE_POSTGRES" delete secret postgres-exporter-credentials --ignore-not-found

  # Deploy postgres_exporter
  cat <<YAML | kubectl apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-exporter
  namespace: ${NAMESPACE_POSTGRES}
  labels:
    app: postgres-exporter
    component: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres-exporter
  template:
    metadata:
      labels:
        app: postgres-exporter
        component: monitoring
    spec:
      containers:
      - name: postgres-exporter
        image: quay.io/prometheuscommunity/postgres-exporter:v0.15.0
        ports:
        - containerPort: 9187
          name: metrics
        env:
        - name: DATA_SOURCE_URI
          value: "${pg_host}:${pg_port}/${pg_db}?sslmode=disable"
        - name: DATA_SOURCE_USER
          valueFrom:
            secretKeyRef:
              name: postgres-cluster-app
              key: username
        - name: DATA_SOURCE_PASS
          valueFrom:
            secretKeyRef:
              name: postgres-cluster-app
              key: password
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "200m"
        livenessProbe:
          httpGet:
            path: /
            port: 9187
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /
            port: 9187
          initialDelaySeconds: 10
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-exporter
  namespace: ${NAMESPACE_POSTGRES}
  labels:
    app: postgres-exporter
    component: monitoring
spec:
  selector:
    app: postgres-exporter
  ports:
  - port: 9187
    targetPort: 9187
    name: metrics
YAML

  info "  Note: Prometheus will auto-discover this service via kubernetes_sd_configs"
  info "  (configured in observability.sh extraScrapeConfigs)"

  info "✓ PostgreSQL Exporter deployed"
  info "  Metrics endpoint: http://postgres-exporter.${NAMESPACE_POSTGRES}.svc.cluster.local:9187/metrics"
}

deploy_postgres_exporter

# ============================================================================
# Phase 4: Deploy pgweb
# ============================================================================
deploy_pgweb() {
  log "=== Phase 4: pgweb Deployment ==="

  if [[ "$SKIP_PGWEB" == "true" ]]; then
    info "Skipping pgweb installation (--skip-pgweb)"
    return 0
  fi

  # Get PostgreSQL connection info
  local pg_host pg_port pg_user pg_pass pg_db
  pg_host="postgres-cluster-rw.${NAMESPACE_POSTGRES}.svc.cluster.local"
  pg_port="5432"
  pg_db="postgres"  # Connect to postgres database by default
  
  # Get credentials from the superuser secret (for admin access to all databases)
  if kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-superuser >/dev/null 2>&1; then
    pg_user=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-superuser -o jsonpath='{.data.username}' | base64 -d)
    pg_pass=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-superuser -o jsonpath='{.data.password}' | base64 -d)
    info "Using PostgreSQL superuser credentials for admin access to all databases"
    info "  User: ${pg_user}"
  else
    warn "PostgreSQL superuser credentials not found - falling back to app user"
    if kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app >/dev/null 2>&1; then
      pg_user=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app -o jsonpath='{.data.username}' | base64 -d)
      pg_pass=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app -o jsonpath='{.data.password}' | base64 -d)
      info "  User: ${pg_user}"
    else
      warn "PostgreSQL credentials not found - pgweb will need manual connection"
      pg_user="postgres"
      pg_pass=""
    fi
  fi

  # Verify credentials by testing connection from a PostgreSQL pod
  info "Verifying PostgreSQL credentials..."
  local pg_pod
  pg_pod=$(kubectl -n "$NAMESPACE_POSTGRES" get pods -l cnpg.io/cluster=postgres-cluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -n "$pg_pod" ]]; then
    # Test connection using PGPASSWORD environment variable
    if kubectl -n "$NAMESPACE_POSTGRES" exec "$pg_pod" -- env PGPASSWORD="$pg_pass" psql -U "$pg_user" -d "$pg_db" -c "SELECT version();" >/dev/null 2>&1; then
      info "✓ Credentials verified successfully"
    else
      warn "⚠ Credential verification failed - connection may still work from pgweb pod"
      warn "  This could be due to pg_hba.conf restrictions or credential issues"
    fi
  else
    warn "⚠ Could not find PostgreSQL pod to verify credentials"
  fi

  info "Creating pgweb connection secret..."
  # Selective URL encode - only encode characters that break URL parsing
  # Characters that MUST be encoded in password: : @ / ? # [ ]
  # Note: + doesn't need encoding in password portion, but some parsers may require it
  selective_url_encode() {
    local string="$1"
    local encoded=""
    local i=0
    while [ $i -lt ${#string} ]; do
      local char="${string:$i:1}"
      case "$char" in
        # Safe characters that don't need encoding
        [a-zA-Z0-9.~_+-])
          encoded="${encoded}${char}"
          ;;
        # Characters that MUST be encoded (break URL parsing)
        :|@|/|\?|\#|\[|\]|" ")
          local hex
          printf -v hex '%%%02X' "'$char"
          encoded="${encoded}${hex}"
          ;;
        # All other special characters - encode to be safe
        *)
          local hex
          printf -v hex '%%%02X' "'$char"
          encoded="${encoded}${hex}"
          ;;
      esac
      i=$((i + 1))
    done
    echo -n "$encoded"
  }
  
  # Encode username and password (selective encoding - keeps + unencoded)
  local pg_user_enc pg_pass_enc
  pg_user_enc=$(selective_url_encode "$pg_user")
  pg_pass_enc=$(selective_url_encode "$pg_pass")
  
  info "Password encoding: keeping + unencoded, encoding / and other URL-breaking chars"
  
  # Build connection string
  local pg_conn_string="postgres://${pg_user_enc}:${pg_pass_enc}@${pg_host}:${pg_port}/${pg_db}?sslmode=disable"
  
  # Debug: show connection string without password (for troubleshooting)
  info "Connection string format: postgres://${pg_user}:***@${pg_host}:${pg_port}/${pg_db}?sslmode=disable"
  
  # Verify the connection string was created
  if [[ -z "$pg_conn_string" ]]; then
    err "Failed to create connection string"
    return 1
  fi
  
  # Create secret with connection string
  # Store both encoded (for URL) and raw password (as backup)
  kubectl -n "$NAMESPACE_POSTGRES" create secret generic pgweb-connection \
    --from-literal=PGWEB_DATABASE_URL="$pg_conn_string" \
    --from-literal=PGWEB_HOST="$pg_host" \
    --from-literal=PGWEB_PORT="$pg_port" \
    --from-literal=PGWEB_USER="$pg_user" \
    --from-literal=PGWEB_PASS="$pg_pass" \
    --from-literal=PGWEB_DB="$pg_db" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  info "✓ Connection secret created (contains both URL and individual parameters)"

  # Clean up any existing pgweb deployment and service
  kubectl -n "$NAMESPACE_POSTGRES" delete deployment pgweb --ignore-not-found=true
  kubectl -n "$NAMESPACE_POSTGRES" delete service pgweb --ignore-not-found=true

  # Deploy pgweb
  cat <<YAML | kubectl apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgweb
  namespace: ${NAMESPACE_POSTGRES}
  labels:
    app: pgweb
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pgweb
  template:
    metadata:
      labels:
        app: pgweb
    spec:
      containers:
      - name: pgweb
        image: sosedoff/pgweb:latest
        ports:
        - containerPort: 8081
          name: http
        env:
        # Try individual connection parameters first (avoids URL encoding issues)
        # pgweb supports both PGWEB_DATABASE_URL and individual parameters
        - name: PGWEB_HOST
          valueFrom:
            secretKeyRef:
              name: pgweb-connection
              key: PGWEB_HOST
        - name: PGWEB_PORT
          valueFrom:
            secretKeyRef:
              name: pgweb-connection
              key: PGWEB_PORT
        - name: PGWEB_USER
          valueFrom:
            secretKeyRef:
              name: pgweb-connection
              key: PGWEB_USER
        - name: PGWEB_PASS
          valueFrom:
            secretKeyRef:
              name: pgweb-connection
              key: PGWEB_PASS
        - name: PGWEB_DB
          valueFrom:
            secretKeyRef:
              name: pgweb-connection
              key: PGWEB_DB
        - name: PGWEB_BIND
          value: "0.0.0.0"
        - name: PGWEB_HTTP_PORT
          value: "8081"
        resources:
          requests:
            memory: "256Mi"
            cpu: "50m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /
            port: 8081
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /
            port: 8081
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: pgweb
  namespace: ${NAMESPACE_POSTGRES}
spec:
  selector:
    app: pgweb
  ports:
  - port: 8080
    targetPort: 8081
    name: http
YAML

  # Wait for pgweb to be ready
  info "Waiting for pgweb deployment to be ready..."
  kubectl -n "$NAMESPACE_POSTGRES" rollout status deployment/pgweb --timeout=300s || true

  info "✓ pgweb deployed"
  info "  Connected to: ${pg_host}:${pg_port}/${pg_db}"
  info "  User: ${pg_user} (superuser - can see all databases)"
}

deploy_pgweb

# ============================================================================
# Phase 5: Create Pomerium-routing Ingress for pgweb
# ============================================================================
create_pomerium_ingress() {
  log "=== Phase 5: Pomerium-routing Ingress ==="

  if [[ "$SKIP_PGWEB" == "true" ]]; then
    info "Skipping Pomerium ingress (pgweb not installed)"
    return 0
  fi

  if [[ "${ENFORCE_POMERIUM}" != "true" ]]; then
    info "Pomerium enforcement disabled - creating direct ingress"
    # Create direct ingress without Pomerium
    cat <<YAML | kubectl apply -f -
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pgweb
  namespace: ${NAMESPACE_POSTGRES}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${PGWEB_HOST}
    secretName: pgweb-tls
  rules:
  - host: ${PGWEB_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: pgweb
            port:
              number: 8080
YAML
    return 0
  fi

  # Create Pomerium-routing Ingress (routes through Pomerium proxy in sso namespace)
  cat <<YAML | kubectl apply -f -
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pgweb-pomerium
  namespace: ${NAMESPACE_SSO}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    cert-manager.io/common-name: ${PGWEB_HOST}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${PGWEB_HOST}
    secretName: pgweb-pomerium-tls
  rules:
  - host: ${PGWEB_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: pomerium-proxy
            port:
              number: 80
YAML

  info "✓ Pomerium-routing Ingress created for pgweb"
}

create_pomerium_ingress

# ============================================================================
# Phase 6: Register Pomerium Route
# ============================================================================
register_pomerium_route() {
  log "=== Phase 6: Register Pomerium Route ==="

  if [[ "$SKIP_PGWEB" == "true" ]]; then
    info "Skipping Pomerium route (pgweb not installed)"
    return 0
  fi

  if [[ "${ENFORCE_POMERIUM}" != "true" ]]; then
    info "Pomerium enforcement disabled - skipping route registration"
    return 0
  fi

  local from_url="https://${PGWEB_HOST}"
  local to_url="http://pgweb.${NAMESPACE_POSTGRES}.svc.cluster.local:8080"
  
  if provision::pomerium_routes_add "$from_url" "$to_url" "${NAMESPACE_SSO}" true true true; then
    info "✓ Pomerium route ensured: ${from_url} -> ${to_url}"
  else
    warn "Failed to ensure Pomerium route for ${from_url}"
  fi
}

register_pomerium_route || true

# ============================================================================
# Phase 7: Validation
# ============================================================================
validate_deployment() {
  log "=== Phase 6: Validation ==="

  local failed=false

  # Check CloudNativePG operator
  if kubectl -n "$CNPG_NAMESPACE" get deploy cnpg-cloudnative-pg >/dev/null 2>&1; then
    local operator_ready
    operator_ready=$(kubectl -n "$CNPG_NAMESPACE" get deploy cnpg-cloudnative-pg -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${operator_ready:-0}" -ge 1 ]]; then
      info "  ✓ CloudNativePG operator is running"
    else
      warn "  ✗ CloudNativePG operator not ready"
      failed=true
    fi
  else
    warn "  ✗ CloudNativePG operator not found"
    failed=true
  fi

  # Check PostgreSQL cluster
  if kubectl -n "$NAMESPACE_POSTGRES" get cluster postgres-cluster >/dev/null 2>&1; then
    local cluster_phase
    cluster_phase=$(kubectl -n "$NAMESPACE_POSTGRES" get cluster postgres-cluster -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [[ "$cluster_phase" == "Cluster in healthy state" ]]; then
      info "  ✓ PostgreSQL cluster is healthy"
    else
      warn "  ⚠ PostgreSQL cluster phase: ${cluster_phase}"
    fi
  else
    warn "  ✗ PostgreSQL cluster not found"
    failed=true
  fi

  # Check pgweb (if not skipped)
  if [[ "$SKIP_PGWEB" != "true" ]]; then
    if kubectl -n "$NAMESPACE_POSTGRES" get deploy pgweb >/dev/null 2>&1; then
      local pgweb_ready
      pgweb_ready=$(kubectl -n "$NAMESPACE_POSTGRES" get deploy pgweb -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      if [[ "${pgweb_ready:-0}" -ge 1 ]]; then
        info "  ✓ pgweb is running"
      else
        warn "  ⚠ pgweb not ready yet"
      fi
    else
      warn "  ✗ pgweb deployment not found"
      failed=true
    fi

    # Check Ingress
    local ingress_found=false
    if [[ "${ENFORCE_POMERIUM}" == "true" ]] && kubectl -n "${NAMESPACE_SSO}" get ingress pgweb-pomerium >/dev/null 2>&1; then
      info "  ✓ Pomerium-routing Ingress exists"
      ingress_found=true
    elif kubectl -n "$NAMESPACE_POSTGRES" get ingress pgweb >/dev/null 2>&1; then
      info "  ✓ Direct Ingress exists"
      ingress_found=true
    fi
    if [[ "$ingress_found" != "true" ]]; then
      warn "  ⚠ No Ingress found for pgweb"
    fi
  fi

  if [[ "$failed" == "true" ]]; then
    return 1
  fi
  return 0
}

validate_deployment || true

# ============================================================================
# Summary
# ============================================================================
log "=== PostgreSQL provisioning completed for environment: ${ENV_NAME} ==="
info ""
info "Namespaces:"
info "  Operator:   ${CNPG_NAMESPACE}"
info "  Database:   ${NAMESPACE_POSTGRES}"
info ""
info "PostgreSQL Cluster:"
info "  Name:       postgres-cluster"
info "  Image:      ${POSTGRES_IMAGE}"
info "  Instances:  ${POSTGRES_INSTANCES} (single master)"
info "  Storage:    ${POSTGRES_STORAGE_SIZE} (${POSTGRES_STORAGE_CLASS})"
info "  Extensions: pgvector (enabled)"
info ""
info "Internal Connection (cluster):"
info "  Host:       postgres-cluster-rw.${NAMESPACE_POSTGRES}.svc.cluster.local"
info "  Port:       5432"
info "  Database:   app"
info ""
info "Credentials:"
info "  App user:   kubectl -n ${NAMESPACE_POSTGRES} get secret postgres-cluster-app -o jsonpath='{.data.password}' | base64 -d"
info "  Superuser:  kubectl -n ${NAMESPACE_POSTGRES} get secret postgres-cluster-superuser -o jsonpath='{.data.password}' | base64 -d"
info ""

if [[ "$SKIP_PGWEB" != "true" ]]; then
  info "pgweb Web Interface:"
  if [[ "${ENFORCE_POMERIUM}" == "true" ]]; then
    info "  URL:        https://${PGWEB_HOST} (requires GitHub OAuth via Pomerium)"
  else
    info "  URL:        https://${PGWEB_HOST}"
  fi
  info "  Note:       pgweb connects directly to PostgreSQL (no separate login required)"
  info ""
fi

info "Quick commands:"
info "  Show credentials:  tools/k3s/postgres.sh ${ENV_NAME} --show-credentials"
info "  Cluster status:    kubectl -n ${NAMESPACE_POSTGRES} get cluster postgres-cluster"
info "  Connect via psql:  kubectl -n ${NAMESPACE_POSTGRES} exec -it postgres-cluster-1 -- psql -U app -d app"
info "  Test pgvector:     kubectl -n ${NAMESPACE_POSTGRES} exec -it postgres-cluster-1 -- psql -U app -d app -c \"SELECT * FROM pg_extension WHERE extname = 'vector';\""
info ""

# Output actual credentials for easy copy-paste
info "=== Admin Credentials ==="
if kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app >/dev/null 2>&1; then
  app_user=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "app")
  app_pass=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-app -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ -n "$app_pass" ]]; then
    echo "POSTGRES_HOST=postgres-cluster-rw.${NAMESPACE_POSTGRES}.svc.cluster.local"
    echo "POSTGRES_PORT=5432"
    echo "POSTGRES_DATABASE=app"
    echo "POSTGRES_USERNAME=${app_user}"
    echo "POSTGRES_PASSWORD=${app_pass}"
    echo "POSTGRES_URL=postgresql://${app_user}:${app_pass}@postgres-cluster-rw.${NAMESPACE_POSTGRES}.svc.cluster.local:5432/app"
  else
    info "App credentials not yet available"
  fi
else
  info "PostgreSQL cluster credentials secret not found"
fi

if [[ "$SKIP_PGWEB" != "true" ]]; then
  echo ""
  echo "PGWEB_URL=https://${PGWEB_HOST}"
fi
