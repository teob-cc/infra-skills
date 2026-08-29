#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# K3S MySQL Provisioning (Percona Operator for MySQL - PS)
# ============================================================================
# Provisions MySQL infrastructure using Percona Operator for MySQL (PS variant):
# 1. Percona PS Operator (MySQL operator)
# 2. Single-instance MySQL server (Percona Server 8.0)
# 3. mysqld-exporter for Prometheus metrics
# 4. Adminer web management tool
# 5. Pomerium integration for Adminer access
#
# Usage:
#   tools/k3s/mysql.sh <env-name> [options]
#
# Options:
#   --skip-operator          Skip operator installation (use existing)
#   --skip-adminer           Skip Adminer installation
#   --force-cleanup          Force cleanup of existing resources before installation
#   --show-credentials [app-id]  Display MySQL credentials and exit (app-id for app-specific creds)
#   --show-resources         Display current MySQL resource usage and exit
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
  echo "Usage: $0 <env-name> [--skip-operator] [--skip-adminer] [--force-cleanup] [--show-credentials [app-id]] [--show-resources] [--watch [kind]] [--provision-credentials <app-id>] [--dump-table <table> [--database <dbname>] [--output <file>]]" >&2
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
SKIP_ADMINER=false
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
    --skip-adminer) SKIP_ADMINER=true; shift ;;
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
log() { echo "[mysql] $*"; }
info() { echo "[mysql:info] $*"; }
warn() { echo "[mysql:warn] $*" >&2; }
err() { echo "[mysql:error] $*" >&2; }

# --- Config defaults ---
NAMESPACE_MYSQL="${NAMESPACE_MYSQL:-mysql}"
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"
: "${INGRESS_CLASS:=traefik}"
: "${CLUSTER_ISSUER:=letsencrypt-prod}"
: "${MYSQL_STORAGE_CLASS:=local-path}"
: "${MYSQL_STORAGE_SIZE:=50Gi}"
: "${ENFORCE_POMERIUM:=true}"
: "${MYSQL_IMAGE:=percona/percona-server:8.4.6-6.1}"

# Percona PS Operator settings
PERCONA_NAMESPACE="${PERCONA_NAMESPACE:-${NAMESPACE_MYSQL}}"
PERCONA_PS_OPERATOR_VERSION="${PERCONA_PS_OPERATOR_VERSION:-1.0.0}"

# MySQL cluster name
MYSQL_CLUSTER_NAME="${MYSQL_CLUSTER_NAME:-mysql-cluster}"

# Derive hosts from HOSTNAME if not provided
if [[ -n "${HOSTNAME:-}" ]]; then
  ADMINER_HOST="${ADMINER_HOST:-adminer.${HOSTNAME}}"
  info "Service host: ADMINER_HOST=${ADMINER_HOST}"
fi

# Validate required configuration
if [[ -z "${ADMINER_HOST:-}" ]] && [[ "$SKIP_ADMINER" != "true" ]]; then
  err "ADMINER_HOST is not set. Set HOSTNAME in env.properties or ADMINER_HOST explicitly."
  exit 1
fi

if [[ -z "${EXTERNAL_IP:-}" ]]; then
  err "EXTERNAL_IP is not set in env.properties"
  exit 1
fi

# ============================================================================
# Helper: Get MySQL root password from the cluster secret
# ============================================================================
get_mysql_root_password() {
  local namespace="$NAMESPACE_MYSQL"
  local secret_name="${MYSQL_CLUSTER_NAME}-secrets"

  if ! kubectl -n "$namespace" get secret "$secret_name" >/dev/null 2>&1; then
    return 1
  fi

  kubectl -n "$namespace" get secret "$secret_name" -o jsonpath='{.data.root}' 2>/dev/null | base64 -d 2>/dev/null || return 1
}

# Helper: Get MySQL pod name
get_mysql_pod() {
  local namespace="$NAMESPACE_MYSQL"
  kubectl -n "$namespace" get pods -l "app.kubernetes.io/instance=${MYSQL_CLUSTER_NAME},app.kubernetes.io/component=database" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# Helper: Get MySQL service host
get_mysql_host() {
  echo "${MYSQL_CLUSTER_NAME}-mysql.${NAMESPACE_MYSQL}.svc.cluster.local"
}

# ============================================================================
# Show Credentials Mode
# ============================================================================
show_credentials() {
  local app_id="${1:-}"
  local namespace="$NAMESPACE_MYSQL"

  if [[ -n "$app_id" ]]; then
    # App-specific credentials from <app-id>-db secret
    local secret_name="${app_id}-db"
    local app_namespace="${APP_NAMESPACE:-default}"

    if ! kubectl -n "$app_namespace" get secret "$secret_name" >/dev/null 2>&1; then
      err "Credentials secret '${secret_name}' not found in namespace '${app_namespace}'"
      err "Provision credentials first: tools/k3s/mysql.sh ${ENV_NAME} --provision-credentials ${app_id}"
      exit 1
    fi

    local username password host port dbname
    username=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.MYSQL_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null || true)
    password=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.MYSQL_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
    host=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.MYSQL_HOST}' 2>/dev/null | base64 -d 2>/dev/null || true)
    port=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.MYSQL_PORT}' 2>/dev/null | base64 -d 2>/dev/null || true)
    dbname=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.MYSQL_DATABASE}' 2>/dev/null | base64 -d 2>/dev/null || true)

    if [[ -z "$username" || -z "$password" ]]; then
      err "Failed to retrieve credentials from secret '${secret_name}' in namespace '${app_namespace}'"
      exit 1
    fi

    echo "MYSQL_HOST=${host:-$(get_mysql_host)}"
    echo "MYSQL_PORT=${port:-3306}"
    echo "MYSQL_DATABASE=${dbname:-${app_id}}"
    echo "MYSQL_USERNAME=${username}"
    echo "MYSQL_PASSWORD=${password}"
    echo ""
    echo "# Connection string:"
    echo "MYSQL_URL=mysql://${username}:${password}@${host:-$(get_mysql_host)}:${port:-3306}/${dbname:-${app_id}}"
    echo ""
    echo "# Secret: ${secret_name} (namespace: ${app_namespace})"

    exit 0
  fi

  # Generic cluster credentials (root)
  local root_pass
  root_pass=$(get_mysql_root_password) || true

  if [[ -z "$root_pass" ]]; then
    err "MySQL root credentials secret not found in namespace: $namespace"
    err "Run provisioning first: tools/k3s/mysql.sh ${ENV_NAME}"
    exit 1
  fi

  local mysql_host
  mysql_host=$(get_mysql_host)

  echo "MYSQL_HOST=${mysql_host}"
  echo "MYSQL_PORT=3306"
  echo "MYSQL_DATABASE=mysql"
  echo "MYSQL_USERNAME=root"
  echo "MYSQL_PASSWORD=${root_pass}"
  echo ""
  echo "# Connection string:"
  echo "MYSQL_URL=mysql://root:${root_pass}@${mysql_host}:3306/mysql"

  exit 0
}

if [[ "$SHOW_CREDENTIALS" == "true" ]]; then
  show_credentials "$SHOW_CREDENTIALS_APP_ID"
fi

# ============================================================================
# Show Resources Mode
# ============================================================================
show_resources() {
  local namespace="$NAMESPACE_MYSQL"

  # Check if cluster exists
  if ! kubectl -n "$namespace" get perconaservermysql "$MYSQL_CLUSTER_NAME" >/dev/null 2>&1; then
    err "MySQL cluster not found in namespace: $namespace"
    err "Run provisioning first: tools/k3s/mysql.sh ${ENV_NAME}"
    exit 1
  fi

  echo "=== MySQL Resource Usage ==="
  echo ""

  # Get cluster spec resources
  echo "--- Configured Resources (from CR spec) ---"
  kubectl -n "$namespace" get perconaservermysql "$MYSQL_CLUSTER_NAME" -o jsonpath='{.spec.mysql.resources}' 2>/dev/null | jq . 2>/dev/null || echo "Unable to retrieve spec"
  echo ""

  # Get pod resource usage via kubectl top
  echo "--- Current Resource Usage (kubectl top) ---"
  if kubectl top pods -n "$namespace" -l "app.kubernetes.io/instance=${MYSQL_CLUSTER_NAME}" 2>/dev/null; then
    :
  else
    echo "Metrics not available (metrics-server may not be installed)"
  fi
  echo ""

  # Get pod resource requests/limits
  echo "--- Pod Resource Requests/Limits ---"
  kubectl -n "$namespace" get pods -l "app.kubernetes.io/instance=${MYSQL_CLUSTER_NAME}" -o custom-columns=\
'NAME:.metadata.name,'\
'CPU_REQ:.spec.containers[0].resources.requests.cpu,'\
'CPU_LIM:.spec.containers[0].resources.limits.cpu,'\
'MEM_REQ:.spec.containers[0].resources.requests.memory,'\
'MEM_LIM:.spec.containers[0].resources.limits.memory' 2>/dev/null || echo "Unable to retrieve pod resources"
  echo ""

  # Get storage usage
  echo "--- Storage Usage ---"
  kubectl -n "$namespace" get pvc -l "app.kubernetes.io/instance=${MYSQL_CLUSTER_NAME}" -o custom-columns=\
'NAME:.metadata.name,'\
'CAPACITY:.status.capacity.storage,'\
'STORAGE_CLASS:.spec.storageClassName' 2>/dev/null || echo "Unable to retrieve PVC info"
  echo ""

  # Get cluster status
  echo "--- Cluster Status ---"
  kubectl -n "$namespace" get perconaservermysql "$MYSQL_CLUSTER_NAME" -o custom-columns=\
'NAME:.metadata.name,'\
'STATE:.status.state,'\
'READY:.status.mysql.ready' 2>/dev/null || echo "Unable to retrieve cluster status"

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
  local namespace="$NAMESPACE_MYSQL"

  if [[ "$kind" != "help" && "$kind" != "--help" && "$kind" != "-h" ]]; then
    if ! kubectl -n "$namespace" get perconaservermysql "$MYSQL_CLUSTER_NAME" >/dev/null 2>&1; then
      err "MySQL cluster not found in namespace: $namespace"
      err "Run provisioning first: tools/k3s/mysql.sh ${ENV_NAME}"
      exit 1
    fi
  fi

  case "$kind" in
    help|--help|-h)
      cat <<EOF
=== MySQL Watch/Inspect Toolbox (Percona Operator) ===

Run one of:
  tools/k3s/mysql.sh ${ENV_NAME} --watch cluster         # Cluster status changes (PerconaServerMySQL CR)
  tools/k3s/mysql.sh ${ENV_NAME} --watch pods            # Pod scheduling/restarts/ready changes
  tools/k3s/mysql.sh ${ENV_NAME} --watch events          # Namespace events stream
  tools/k3s/mysql.sh ${ENV_NAME} --watch logs            # MySQL instance logs (all pods)
  tools/k3s/mysql.sh ${ENV_NAME} --watch operator-logs   # Percona operator logs
  tools/k3s/mysql.sh ${ENV_NAME} --watch sql             # Open mysql CLI into primary
  tools/k3s/mysql.sh ${ENV_NAME} --watch exporter        # Port-forward mysqld-exporter metrics (9104)
  tools/k3s/mysql.sh ${ENV_NAME} --watch services        # Show services/endpoints/PVs/PVCs (snapshot)
  tools/k3s/mysql.sh ${ENV_NAME} --watch pvc             # Watch PVC/PV binding and usage (snapshot)

Useful one-liners (run manually, in separate terminals):
  kubectl -n ${namespace} get perconaservermysql ${MYSQL_CLUSTER_NAME} -o yaml | sed -n '/^status:/,\$p'
  kubectl -n ${namespace} get pods -l app.kubernetes.io/instance=${MYSQL_CLUSTER_NAME} -o wide
  kubectl -n ${namespace} describe pod -l app.kubernetes.io/instance=${MYSQL_CLUSTER_NAME} | sed -n '1,200p'
  kubectl -n ${namespace} logs -l app.kubernetes.io/instance=${MYSQL_CLUSTER_NAME} --all-containers --tail=200

SQL snippets (inside mysql):
  SELECT version();
  SHOW DATABASES;
  SHOW PROCESSLIST;
  SHOW GLOBAL STATUS;
  SHOW GLOBAL VARIABLES LIKE '%max_connections%';
  SELECT * FROM performance_schema.replication_group_members;
EOF
      exit 0
      ;;

    cluster)
      info "Watching Percona MySQL cluster status: ${namespace}/${MYSQL_CLUSTER_NAME}"
      kubectl -n "$namespace" get perconaservermysql "$MYSQL_CLUSTER_NAME" -w
      ;;

    pods)
      info "Watching MySQL pods: app.kubernetes.io/instance=${MYSQL_CLUSTER_NAME}"
      kubectl -n "$namespace" get pods -l "app.kubernetes.io/instance=${MYSQL_CLUSTER_NAME}" -w
      ;;

    events)
      info "Watching Kubernetes events in namespace: ${namespace}"
      kubectl -n "$namespace" get events --watch
      ;;

    logs)
      info "Tailing MySQL logs (all cluster pods)..."
      kubectl -n "$namespace" logs -l "app.kubernetes.io/instance=${MYSQL_CLUSTER_NAME},app.kubernetes.io/component=mysql" -f --tail=200 --all-containers
      ;;

    operator-logs)
      info "Tailing Percona PS operator logs in namespace: ${PERCONA_NAMESPACE}"
      kubectl -n "$PERCONA_NAMESPACE" logs deploy/ps-operator -f --tail=200
      ;;

    sql)
      local mysql_pod
      mysql_pod=$(get_mysql_pod)
      if [[ -z "$mysql_pod" ]]; then
        err "No MySQL pod found in cluster"
        exit 1
      fi

      local root_pass
      root_pass=$(get_mysql_root_password) || true
      if [[ -z "$root_pass" ]]; then
        err "Failed to retrieve MySQL root password"
        exit 1
      fi

      info "Opening mysql CLI as root in pod: ${mysql_pod}"
      kubectl -n "$namespace" exec -it "$mysql_pod" -- mysql -uroot -p"${root_pass}"
      ;;

    exporter)
      if ! kubectl -n "$namespace" get svc mysql-exporter >/dev/null 2>&1; then
        err "Service not found: ${namespace}/mysql-exporter"
        err "If you just provisioned, re-run: tools/k3s/mysql.sh ${ENV_NAME}"
        exit 1
      fi
      info "Port-forwarding mysql-exporter to localhost:9104"
      info "Open: http://127.0.0.1:9104/metrics"
      kubectl -n "$namespace" port-forward svc/mysql-exporter 9104:9104
      ;;

    services)
      echo "=== Services / Endpoints (snapshot) ==="
      kubectl -n "$namespace" get svc -o wide
      echo ""
      kubectl -n "$namespace" get endpoints -o wide || true
      echo ""
      echo "=== Percona MySQL objects (snapshot) ==="
      kubectl -n "$namespace" get perconaservermysql 2>/dev/null || true
      ;;

    pvc)
      echo "=== PVCs (snapshot) ==="
      kubectl -n "$namespace" get pvc -o wide
      echo ""
      echo "=== PVs (snapshot) ==="
      kubectl get pv | (grep -E "mysql|${namespace}" || true)
      ;;

    *)
      err "Unknown watch kind: ${kind}"
      err "Run: tools/k3s/mysql.sh ${ENV_NAME} --watch help"
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
  local namespace="$NAMESPACE_MYSQL"
  local app_namespace="${APP_NAMESPACE:-default}"

  # Validate app_id (alphanumeric and hyphens only, for safety)
  if [[ ! "$app_id" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    err "Invalid app-id: ${app_id}"
    err "App ID must be lowercase alphanumeric with hyphens (e.g., 'my-app', 'evse')"
    exit 1
  fi

  log "=== Provisioning MySQL credentials for application: ${app_id} ==="

  # Check if cluster exists
  if ! kubectl -n "$namespace" get perconaservermysql "$MYSQL_CLUSTER_NAME" >/dev/null 2>&1; then
    err "MySQL cluster not found in namespace: $namespace"
    err "Run provisioning first: tools/k3s/mysql.sh ${ENV_NAME}"
    exit 1
  fi

  # Check cluster status
  local state
  state=$(kubectl -n "$namespace" get perconaservermysql "$MYSQL_CLUSTER_NAME" -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")
  if [[ "$state" != "ready" ]]; then
    warn "MySQL cluster is not in ready state (state: ${state})"
    warn "Credentials provisioning may fail. Continue anyway? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi

  # Get root credentials
  local root_pass
  root_pass=$(get_mysql_root_password) || true
  if [[ -z "$root_pass" ]]; then
    err "MySQL root password not found"
    err "Run provisioning first: tools/k3s/mysql.sh ${ENV_NAME}"
    exit 1
  fi

  local mysql_host
  mysql_host=$(get_mysql_host)
  local mysql_port="3306"

  # Generate app credentials
  local app_username="${app_id}"
  local app_password
  app_password=$(openssl rand -base64 24 | tr -d '\n')
  local app_database="${app_id}"
  # MySQL usernames are limited to 32 characters
  if [[ ${#app_username} -gt 32 ]]; then
    err "App ID '${app_id}' is too long for a MySQL username (max 32 characters)"
    exit 1
  fi

  info "Creating database user and database: ${app_username}/${app_database}"

  # Find a MySQL pod to execute commands
  local mysql_pod
  mysql_pod=$(get_mysql_pod)

  if [[ -z "$mysql_pod" ]]; then
    err "No MySQL pod found in cluster"
    exit 1
  fi

  # Create database and user
  info "Creating database '${app_database}' and user '${app_username}'..."

  # Create database if not exists
  kubectl -n "$namespace" exec "$mysql_pod" -- mysql -uroot -p"${root_pass}" -e "CREATE DATABASE IF NOT EXISTS \`${app_database}\`;" || {
    err "Failed to create database"
    exit 1
  }

  # Create user (or update password if exists)
  kubectl -n "$namespace" exec "$mysql_pod" -- mysql -uroot -p"${root_pass}" -e "CREATE USER IF NOT EXISTS '${app_username}'@'%' IDENTIFIED BY '${app_password}'; ALTER USER '${app_username}'@'%' IDENTIFIED BY '${app_password}';" || {
    err "Failed to create/update database user"
    exit 1
  }

  # Grant privileges
  kubectl -n "$namespace" exec "$mysql_pod" -- mysql -uroot -p"${root_pass}" -e "GRANT ALL PRIVILEGES ON \`${app_database}\`.* TO '${app_username}'@'%'; FLUSH PRIVILEGES;" || {
    warn "Failed to grant privileges (database may already have correct permissions)"
  }

  info "Database and user created"

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
  # MySQL host
  MYSQL_HOST: ${mysql_host}

  # MySQL port
  MYSQL_PORT: "${mysql_port}"

  # MySQL database name
  MYSQL_DATABASE: ${app_database}

  # MySQL username
  MYSQL_USERNAME: ${app_username}

  # MySQL password
  MYSQL_PASSWORD: ${app_password}
YAML

  info "Secret file created"

  # Ensure namespace exists
  kubectl get ns "$app_namespace" >/dev/null 2>&1 || kubectl create ns "$app_namespace"

  # Apply to kubectl
  info "Applying secret to Kubernetes..."
  kubectl apply -f "$secret_file" || {
    err "Failed to apply secret to Kubernetes"
    exit 1
  }

  info "Secret applied to namespace: ${app_namespace}"

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
  info "  Host:             ${mysql_host}"
  info "  Port:             ${mysql_port}"
  info "  Database:         ${app_database}"
  info "  Username:         ${app_username}"
  info ""
  info "Secret fields:"
  info "  MYSQL_HOST"
  info "  MYSQL_PORT"
  info "  MYSQL_DATABASE"
  info "  MYSQL_USERNAME"
  info "  MYSQL_PASSWORD"
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
  local namespace="$NAMESPACE_MYSQL"

  log "=== Dumping MySQL table: ${database}.${table_name} ==="

  # Check if cluster exists
  if ! kubectl -n "$namespace" get perconaservermysql "$MYSQL_CLUSTER_NAME" >/dev/null 2>&1; then
    err "MySQL cluster not found in namespace: $namespace"
    err "Run provisioning first: tools/k3s/mysql.sh ${ENV_NAME}"
    exit 1
  fi

  # Find a MySQL pod
  local mysql_pod
  mysql_pod=$(get_mysql_pod)

  if [[ -z "$mysql_pod" ]]; then
    err "No MySQL pod found in cluster"
    exit 1
  fi

  # Get root credentials
  local root_pass
  root_pass=$(get_mysql_root_password) || true
  if [[ -z "$root_pass" ]]; then
    err "Failed to retrieve MySQL root password"
    exit 1
  fi

  info "Using root credentials for dump"

  # Verify table exists
  info "Verifying table exists: ${database}.${table_name}"
  if ! kubectl -n "$namespace" exec "$mysql_pod" -- mysql -uroot -p"${root_pass}" -N -e "SELECT 1 FROM information_schema.tables WHERE table_schema = '${database}' AND table_name = '${table_name}'" | grep -q 1; then
    err "Table '${table_name}' not found in database '${database}'"
    err "Available tables:"
    kubectl -n "$namespace" exec "$mysql_pod" -- mysql -uroot -p"${root_pass}" -e "SHOW TABLES FROM \`${database}\`" 2>/dev/null || true
    exit 1
  fi

  info "Dumping table: ${database}.${table_name}"
  info "Pod: ${mysql_pod}"

  # Perform the dump
  if [[ -n "$output_file" ]]; then
    info "Output file: ${output_file}"
    kubectl -n "$namespace" exec "$mysql_pod" -- mysqldump -uroot -p"${root_pass}" "$database" "$table_name" --no-create-db --skip-lock-tables > "$output_file" || {
      err "Failed to dump table"
      exit 1
    }
    info "Table dumped to: ${output_file}"
  else
    info "Dumping to stdout..."
    kubectl -n "$namespace" exec "$mysql_pod" -- mysqldump -uroot -p"${root_pass}" "$database" "$table_name" --no-create-db --skip-lock-tables || {
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

log "Starting MySQL provisioning for environment: ${ENV_NAME}"

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
    info "Wildcard covers Adminer access - skipping individual record creation"
  else
    # Create DNS record for Adminer
    if [[ -n "${ADMINER_HOST:-}" ]]; then
      provision::cloudflare_ensure_dns_record "$ADMINER_HOST" "$EXTERNAL_IP" || \
        warn "Failed to create DNS record for $ADMINER_HOST"
    fi
  fi

  info "DNS records ensured"
}

ensure_dns_records

# ============================================================================
# Phase 1: Install Percona PS Operator
# ============================================================================
install_percona_operator() {
  log "=== Phase 1: Percona PS Operator ==="

  if [[ "$SKIP_OPERATOR" == "true" ]]; then
    info "Skipping operator installation (--skip-operator)"
    return 0
  fi

  # Force cleanup if requested
  if [[ "$FORCE_CLEANUP" == "true" ]]; then
    info "Force cleanup requested - removing existing operator resources"
    helm uninstall ps-operator --namespace "$PERCONA_NAMESPACE" 2>/dev/null || true
    info "Force cleanup completed"
  fi

  # Check if already installed
  if kubectl get crd perconaservermysqls.ps.percona.com >/dev/null 2>&1; then
    info "Percona PS CRDs already configured"

    # Check if operator is running
    if kubectl -n "$PERCONA_NAMESPACE" get deploy ps-operator >/dev/null 2>&1; then
      info "Percona PS operator already installed and running"
      return 0
    else
      warn "Percona PS CRDs exist but operator deployment not found"
      warn "This might indicate an incomplete installation"
    fi
  fi

  # Additional check for deployment
  if kubectl get ns "$PERCONA_NAMESPACE" >/dev/null 2>&1 && \
     kubectl -n "$PERCONA_NAMESPACE" get deploy ps-operator >/dev/null 2>&1; then
    info "Percona PS operator already installed"
    return 0
  fi

  # Add Helm repo
  if ! helm repo list 2>/dev/null | grep -q percona; then
    helm repo add percona https://percona.github.io/percona-helm-charts/
  fi
  helm repo update

  # Install Percona PS operator
  info "Installing Percona PS operator v${PERCONA_PS_OPERATOR_VERSION}..."
  helm upgrade --install ps-operator percona/ps-operator \
    --namespace "$PERCONA_NAMESPACE" \
    --create-namespace \
    --version "$PERCONA_PS_OPERATOR_VERSION" \
    --wait \
    --timeout 5m

  # Wait for operator to be ready
  info "Waiting for Percona PS operator to be ready..."
  kubectl -n "$PERCONA_NAMESPACE" rollout status deployment/ps-operator --timeout=120s

  info "Percona PS operator installed"
}

install_percona_operator

# ============================================================================
# Phase 2: Create MySQL Instance
# ============================================================================
create_mysql_instance() {
  log "=== Phase 2: MySQL Instance ==="

  # Create namespace
  kubectl get ns "$NAMESPACE_MYSQL" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_MYSQL"

  # Check if cluster already exists
  if kubectl -n "$NAMESPACE_MYSQL" get perconaservermysql "$MYSQL_CLUSTER_NAME" >/dev/null 2>&1; then
    info "MySQL cluster already exists"

    # Check cluster status
    local state
    state=$(kubectl -n "$NAMESPACE_MYSQL" get perconaservermysql "$MYSQL_CLUSTER_NAME" -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")
    info "Cluster state: ${state}"

    if [[ "$state" == "ready" ]]; then
      info "MySQL cluster is ready"
      return 0
    else
      info "Waiting for cluster to become ready..."
    fi
  else
    # Generate all required passwords upfront to avoid partial internal secret
    # The operator copies these to internal-<cluster> secret on first init.
    # If only root is provided, the internal secret gets partially populated and
    # the bootstrap sidecar fails (missing operator/heartbeat keys). The operator
    # auto-generates missing keys in secretsName but does NOT re-sync to internal secret.
    info "Generating MySQL credentials (all required keys)..."
    local root_pass
    root_pass=$(openssl rand -base64 24 | tr -d '\n')

    kubectl -n "$NAMESPACE_MYSQL" create secret generic "${MYSQL_CLUSTER_NAME}-secrets" \
      --from-literal=root="${root_pass}" \
      --from-literal=operator="$(openssl rand -base64 24 | tr -d '\n')" \
      --from-literal=monitor="$(openssl rand -base64 24 | tr -d '\n')" \
      --from-literal=replication="$(openssl rand -base64 24 | tr -d '\n')" \
      --from-literal=orchestrator="$(openssl rand -base64 24 | tr -d '\n')" \
      --from-literal=heartbeat="$(openssl rand -base64 24 | tr -d '\n')" \
      --from-literal=xtrabackup="$(openssl rand -base64 24 | tr -d '\n')" \
      --dry-run=client -o yaml | kubectl apply -f -

    # Create the MySQL cluster
    info "Creating single-instance MySQL cluster..."
    cat <<YAML | kubectl apply -f -
apiVersion: ps.percona.com/v1
kind: PerconaServerMySQL
metadata:
  name: ${MYSQL_CLUSTER_NAME}
  namespace: ${NAMESPACE_MYSQL}
  finalizers:
    - percona.com/delete-mysql-pods-in-order
spec:
  crVersion: "${PERCONA_PS_OPERATOR_VERSION}"
  secretsName: ${MYSQL_CLUSTER_NAME}-secrets

  toolkit:
    image: percona/percona-toolkit:3.7.0-2

  unsafeFlags:
    mysqlSize: true
    proxy: true
    orchestratorSize: true

  mysql:
    clusterType: async
    autoRecovery: true
    size: 1
    image: ${MYSQL_IMAGE}
    resources:
      requests:
        memory: "1Gi"
        cpu: "500m"
      limits:
        memory: "2Gi"
        cpu: "2000m"
    volumeSpec:
      persistentVolumeClaim:
        storageClassName: ${MYSQL_STORAGE_CLASS}
        resources:
          requests:
            storage: ${MYSQL_STORAGE_SIZE}
    configuration: |
      [mysqld]
      max_connections=100
      innodb_buffer_pool_size=256M
      innodb_log_file_size=256M
      innodb_flush_log_at_trx_commit=2
      innodb_flush_method=O_DIRECT
      character-set-server=utf8mb4
      collation-server=utf8mb4_unicode_ci
      mysql-native-password=ON
      sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
      slow_query_log=ON
      long_query_time=1
      gtid_mode=OFF
      enforce_gtid_consistency=OFF

  orchestrator:
    enabled: true
    size: 1
    image: percona/percona-orchestrator:3.2.6-18
    resources:
      requests:
        memory: "128Mi"
        cpu: "100m"
      limits:
        memory: "256Mi"
        cpu: "500m"

  proxy:
    haproxy:
      enabled: false
      image: percona/haproxy:2.8.12
      size: 1
    router:
      enabled: false
      image: percona/percona-mysql-router:8.4.6
      size: 1

  backup:
    enabled: false
    image: percona/percona-xtrabackup:8.4.0-3
YAML
  fi

  # Wait for cluster to be ready (1 minute timeout)
  info "Waiting for MySQL cluster to be ready (timeout: 1 minute)..."
  local ready=false
  for i in {1..6}; do
    local state
    state=$(kubectl -n "$NAMESPACE_MYSQL" get perconaservermysql "$MYSQL_CLUSTER_NAME" -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")

    if [[ "$state" == "ready" ]]; then
      ready=true
      break
    fi

    info "  Cluster status: state=${state} (${i}0s elapsed...)"
    sleep 10
  done

  if [[ "$ready" != "true" ]]; then
    warn "MySQL cluster did not become ready within 1 minute"
    warn ""
    warn "Diagnostic information:"
    warn "--- Cluster Status ---"
    kubectl -n "$NAMESPACE_MYSQL" get perconaservermysql "$MYSQL_CLUSTER_NAME" -o yaml 2>/dev/null | grep -A 20 "status:" || true
    warn ""
    warn "--- Pod Status ---"
    kubectl -n "$NAMESPACE_MYSQL" get pods -l "app.kubernetes.io/instance=${MYSQL_CLUSTER_NAME}" 2>/dev/null || true
    warn ""
    warn "--- Recent Events ---"
    kubectl -n "$NAMESPACE_MYSQL" get events --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
    warn ""
    warn "If pod is in CrashLoopBackOff due to missing keys in internal secret, run:"
    warn "  kubectl -n $NAMESPACE_MYSQL delete secret internal-${MYSQL_CLUSTER_NAME}"
    warn "  kubectl -n $NAMESPACE_MYSQL delete pvc datadir-${MYSQL_CLUSTER_NAME}-mysql-0"
    warn "  kubectl -n $NAMESPACE_MYSQL delete pod ${MYSQL_CLUSTER_NAME}-mysql-0 --force --grace-period=0"
    warn "  kubectl -n $NAMESPACE_MYSQL delete pod ${MYSQL_CLUSTER_NAME}-orc-0"
    warn ""
    warn "Monitor with: kubectl -n $NAMESPACE_MYSQL get perconaservermysql $MYSQL_CLUSTER_NAME -w"
    # Don't return 1 - allow script to continue for Adminer setup
    return 0
  fi

  info "MySQL cluster is ready"
}

create_mysql_instance

# ============================================================================
# Phase 3: Deploy MySQL Exporter for Prometheus Metrics
# ============================================================================
deploy_mysql_exporter() {
  log "=== Phase 3: MySQL Exporter Deployment ==="

  # Wait for cluster to be ready and get credentials
  local root_pass
  root_pass=$(get_mysql_root_password) || true

  if [[ -z "$root_pass" ]]; then
    warn "MySQL root credentials not found - skipping mysqld-exporter deployment"
    warn "Run provisioning again after cluster is ready"
    return 0
  fi

  # Create exporter user in MySQL
  local mysql_pod
  mysql_pod=$(get_mysql_pod)
  if [[ -n "$mysql_pod" ]]; then
    local exporter_pass
    exporter_pass=$(openssl rand -base64 16 | tr -d '\n')

    info "Creating mysqld-exporter user..."
    kubectl -n "$NAMESPACE_MYSQL" exec "$mysql_pod" -- mysql -uroot -p"${root_pass}" -e \
      "CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY '${exporter_pass}' WITH MAX_USER_CONNECTIONS 3; GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%'; FLUSH PRIVILEGES;" 2>/dev/null || {
      warn "Failed to create exporter user (may already exist)"
      # Try to retrieve existing password from secret
      exporter_pass=$(kubectl -n "$NAMESPACE_MYSQL" get secret mysql-exporter-credentials -o jsonpath='{.data.MYSQL_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
      if [[ -z "$exporter_pass" ]]; then
        warn "No existing exporter credentials found - skipping exporter deployment"
        return 0
      fi
    }

    local mysql_host
    mysql_host=$(get_mysql_host)

    # Create secret for mysqld-exporter connection (.my.cnf format for v0.16+)
    local my_cnf
    my_cnf=$(cat <<EOF
[client]
user=exporter
password=${exporter_pass}
host=${mysql_host}
port=3306
EOF
)
    kubectl -n "$NAMESPACE_MYSQL" create secret generic mysql-exporter-credentials \
      --from-literal=.my.cnf="${my_cnf}" \
      --from-literal=MYSQL_PASSWORD="${exporter_pass}" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    warn "No MySQL pod found - skipping exporter user creation"
    return 0
  fi

  # Deploy mysqld-exporter
  cat <<YAML | kubectl apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql-exporter
  namespace: ${NAMESPACE_MYSQL}
  labels:
    app: mysql-exporter
    component: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql-exporter
  template:
    metadata:
      labels:
        app: mysql-exporter
        component: monitoring
    spec:
      containers:
      - name: mysqld-exporter
        image: prom/mysqld-exporter:v0.16.0
        args:
        - --config.my-cnf=/etc/mysql-exporter/.my.cnf
        ports:
        - containerPort: 9104
          name: metrics
        volumeMounts:
        - name: my-cnf
          mountPath: /etc/mysql-exporter
          readOnly: true
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
            port: 9104
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /
            port: 9104
          initialDelaySeconds: 10
          periodSeconds: 10
      volumes:
      - name: my-cnf
        secret:
          secretName: mysql-exporter-credentials
          items:
          - key: .my.cnf
            path: .my.cnf
---
apiVersion: v1
kind: Service
metadata:
  name: mysql-exporter
  namespace: ${NAMESPACE_MYSQL}
  labels:
    app: mysql-exporter
    component: monitoring
spec:
  selector:
    app: mysql-exporter
  ports:
  - port: 9104
    targetPort: 9104
    name: metrics
YAML

  info "  Note: Prometheus will auto-discover this service via kubernetes_sd_configs"
  info "  (configured in observability.sh extraScrapeConfigs)"

  info "MySQL Exporter deployed"
  info "  Metrics endpoint: http://mysql-exporter.${NAMESPACE_MYSQL}.svc.cluster.local:9104/metrics"
}

deploy_mysql_exporter

# ============================================================================
# Phase 3.5: Deploy Grafana Dashboard (ConfigMap sidecar)
# ============================================================================
deploy_mysql_dashboard() {
  log "=== Phase 3.5: MySQL Grafana Dashboard ==="

  local namespace="${NAMESPACE_OBSERVABILITY:-observability}"

  # Check if Grafana is deployed (skip if observability stack not present)
  if ! kubectl get ns "$namespace" >/dev/null 2>&1; then
    info "Observability namespace '${namespace}' not found - skipping dashboard deployment"
    info "Deploy observability stack first: tools/k3s/observability.sh ${ENV_NAME}"
    return 0
  fi

  info "Deploying MySQL operational dashboard to namespace: ${namespace}"

  # Create a custom MySQL operational dashboard as a ConfigMap
  # The Grafana sidecar picks up ConfigMaps labeled grafana_dashboard=1
  cat <<'DASHBOARD_JSON' | kubectl -n "$namespace" create configmap grafana-dashboard-mysql-operational \
    --from-file=mysql-operational.json=/dev/stdin \
    --dry-run=client -o yaml | \
    yq eval '.metadata.labels.grafana_dashboard = "1"' - | \
    kubectl apply -f -
{
  "annotations": { "list": [] },
  "description": "MySQL Operational Overview — connections, queries, InnoDB, replication, slow queries",
  "editable": true,
  "graphTooltip": 1,
  "schemaVersion": 39,
  "tags": ["mysql", "percona", "database"],
  "title": "MySQL Operational Overview",
  "uid": "mysql-operational-overview",
  "version": 1,
  "time": { "from": "now-1h", "to": "now" },
  "refresh": "30s",
  "templating": {
    "list": [
      {
        "current": {},
        "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
        "definition": "label_values(mysql_up, instance)",
        "name": "instance",
        "query": "label_values(mysql_up, instance)",
        "refresh": 2,
        "type": "query"
      }
    ]
  },
  "panels": [
    {
      "title": "MySQL Up",
      "type": "stat",
      "gridPos": { "h": 4, "w": 3, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus" },
      "targets": [{ "expr": "mysql_up{instance=~\"$instance\"}", "legendFormat": "{{instance}}" }],
      "fieldConfig": { "defaults": { "mappings": [{ "options": { "0": { "text": "DOWN", "color": "red" }, "1": { "text": "UP", "color": "green" } }, "type": "value" }], "thresholds": { "steps": [{ "color": "red", "value": null }, { "color": "green", "value": 1 }] } } }
    },
    {
      "title": "Uptime",
      "type": "stat",
      "gridPos": { "h": 4, "w": 3, "x": 3, "y": 0 },
      "datasource": { "type": "prometheus" },
      "targets": [{ "expr": "mysql_global_status_uptime{instance=~\"$instance\"}", "legendFormat": "" }],
      "fieldConfig": { "defaults": { "unit": "s" } }
    },
    {
      "title": "Current Connections",
      "type": "stat",
      "gridPos": { "h": 4, "w": 3, "x": 6, "y": 0 },
      "datasource": { "type": "prometheus" },
      "targets": [{ "expr": "mysql_global_status_threads_connected{instance=~\"$instance\"}", "legendFormat": "" }],
      "fieldConfig": { "defaults": { "thresholds": { "steps": [{ "color": "green", "value": null }, { "color": "yellow", "value": 50 }, { "color": "red", "value": 90 }] } } }
    },
    {
      "title": "Max Connections",
      "type": "stat",
      "gridPos": { "h": 4, "w": 3, "x": 9, "y": 0 },
      "datasource": { "type": "prometheus" },
      "targets": [{ "expr": "mysql_global_variables_max_connections{instance=~\"$instance\"}", "legendFormat": "" }]
    },
    {
      "title": "Threads Running",
      "type": "stat",
      "gridPos": { "h": 4, "w": 3, "x": 12, "y": 0 },
      "datasource": { "type": "prometheus" },
      "targets": [{ "expr": "mysql_global_status_threads_running{instance=~\"$instance\"}", "legendFormat": "" }],
      "fieldConfig": { "defaults": { "thresholds": { "steps": [{ "color": "green", "value": null }, { "color": "yellow", "value": 10 }, { "color": "red", "value": 30 }] } } }
    },
    {
      "title": "Questions / sec",
      "type": "stat",
      "gridPos": { "h": 4, "w": 3, "x": 15, "y": 0 },
      "datasource": { "type": "prometheus" },
      "targets": [{ "expr": "rate(mysql_global_status_questions{instance=~\"$instance\"}[5m])", "legendFormat": "" }],
      "fieldConfig": { "defaults": { "unit": "ops", "decimals": 1 } }
    },
    {
      "title": "Slow Queries / sec",
      "type": "stat",
      "gridPos": { "h": 4, "w": 3, "x": 18, "y": 0 },
      "datasource": { "type": "prometheus" },
      "targets": [{ "expr": "rate(mysql_global_status_slow_queries{instance=~\"$instance\"}[5m])", "legendFormat": "" }],
      "fieldConfig": { "defaults": { "unit": "ops", "decimals": 2, "thresholds": { "steps": [{ "color": "green", "value": null }, { "color": "yellow", "value": 0.1 }, { "color": "red", "value": 1 }] } } }
    },
    {
      "title": "Aborted Connections / sec",
      "type": "stat",
      "gridPos": { "h": 4, "w": 3, "x": 21, "y": 0 },
      "datasource": { "type": "prometheus" },
      "targets": [{ "expr": "rate(mysql_global_status_aborted_connects{instance=~\"$instance\"}[5m])", "legendFormat": "" }],
      "fieldConfig": { "defaults": { "unit": "ops", "decimals": 2, "thresholds": { "steps": [{ "color": "green", "value": null }, { "color": "yellow", "value": 0.5 }, { "color": "red", "value": 5 }] } } }
    },
    {
      "title": "Query Throughput",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 },
      "datasource": { "type": "prometheus" },
      "targets": [
        { "expr": "rate(mysql_global_status_commands_total{command=~\"select|insert|update|delete\",instance=~\"$instance\"}[5m])", "legendFormat": "{{command}}" }
      ],
      "fieldConfig": { "defaults": { "unit": "ops", "custom": { "fillOpacity": 10, "stacking": { "mode": "none" } } } }
    },
    {
      "title": "Connections",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 4 },
      "datasource": { "type": "prometheus" },
      "targets": [
        { "expr": "mysql_global_status_threads_connected{instance=~\"$instance\"}", "legendFormat": "Connected" },
        { "expr": "mysql_global_status_threads_running{instance=~\"$instance\"}", "legendFormat": "Running" },
        { "expr": "mysql_global_variables_max_connections{instance=~\"$instance\"}", "legendFormat": "Max Allowed" }
      ],
      "fieldConfig": { "defaults": { "custom": { "fillOpacity": 10 } } }
    },
    {
      "title": "InnoDB Buffer Pool",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 12 },
      "datasource": { "type": "prometheus" },
      "targets": [
        { "expr": "mysql_global_status_innodb_buffer_pool_bytes_data{instance=~\"$instance\"}", "legendFormat": "Data" },
        { "expr": "mysql_global_status_innodb_buffer_pool_bytes_dirty{instance=~\"$instance\"}", "legendFormat": "Dirty" },
        { "expr": "mysql_global_variables_innodb_buffer_pool_size{instance=~\"$instance\"}", "legendFormat": "Pool Size" }
      ],
      "fieldConfig": { "defaults": { "unit": "bytes", "custom": { "fillOpacity": 10 } } }
    },
    {
      "title": "InnoDB Row Operations",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 12 },
      "datasource": { "type": "prometheus" },
      "targets": [
        { "expr": "rate(mysql_global_status_innodb_row_ops_total{instance=~\"$instance\"}[5m])", "legendFormat": "{{operation}}" }
      ],
      "fieldConfig": { "defaults": { "unit": "ops", "custom": { "fillOpacity": 10 } } }
    },
    {
      "title": "InnoDB I/O",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 20 },
      "datasource": { "type": "prometheus" },
      "targets": [
        { "expr": "rate(mysql_global_status_innodb_data_reads{instance=~\"$instance\"}[5m])", "legendFormat": "Reads" },
        { "expr": "rate(mysql_global_status_innodb_data_writes{instance=~\"$instance\"}[5m])", "legendFormat": "Writes" },
        { "expr": "rate(mysql_global_status_innodb_data_fsyncs{instance=~\"$instance\"}[5m])", "legendFormat": "Fsyncs" }
      ],
      "fieldConfig": { "defaults": { "unit": "ops", "custom": { "fillOpacity": 10 } } }
    },
    {
      "title": "Network Traffic",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 20 },
      "datasource": { "type": "prometheus" },
      "targets": [
        { "expr": "rate(mysql_global_status_bytes_received{instance=~\"$instance\"}[5m])", "legendFormat": "Received" },
        { "expr": "rate(mysql_global_status_bytes_sent{instance=~\"$instance\"}[5m])", "legendFormat": "Sent" }
      ],
      "fieldConfig": { "defaults": { "unit": "Bps", "custom": { "fillOpacity": 10 } } }
    },
    {
      "title": "Table Locks",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 28 },
      "datasource": { "type": "prometheus" },
      "targets": [
        { "expr": "rate(mysql_global_status_table_locks_immediate{instance=~\"$instance\"}[5m])", "legendFormat": "Immediate" },
        { "expr": "rate(mysql_global_status_table_locks_waited{instance=~\"$instance\"}[5m])", "legendFormat": "Waited" }
      ],
      "fieldConfig": { "defaults": { "unit": "ops", "custom": { "fillOpacity": 10 } } }
    },
    {
      "title": "Temporary Objects",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 28 },
      "datasource": { "type": "prometheus" },
      "targets": [
        { "expr": "rate(mysql_global_status_created_tmp_tables{instance=~\"$instance\"}[5m])", "legendFormat": "Tmp Tables" },
        { "expr": "rate(mysql_global_status_created_tmp_disk_tables{instance=~\"$instance\"}[5m])", "legendFormat": "Tmp Disk Tables" },
        { "expr": "rate(mysql_global_status_created_tmp_files{instance=~\"$instance\"}[5m])", "legendFormat": "Tmp Files" }
      ],
      "fieldConfig": { "defaults": { "unit": "ops", "custom": { "fillOpacity": 10 } } }
    }
  ]
}
DASHBOARD_JSON

  info "MySQL operational dashboard deployed (ConfigMap: grafana-dashboard-mysql-operational)"
  info "  Dashboard will appear in Grafana under 'Shared' folder"
}

deploy_mysql_dashboard

# ============================================================================
# Phase 4: Deploy Adminer
# ============================================================================
deploy_adminer() {
  log "=== Phase 4: Adminer Deployment ==="

  if [[ "$SKIP_ADMINER" == "true" ]]; then
    info "Skipping Adminer installation (--skip-adminer)"
    return 0
  fi

  local mysql_host
  mysql_host=$(get_mysql_host)

  # Clean up any existing Adminer deployment and service
  kubectl -n "$NAMESPACE_MYSQL" delete deployment adminer --ignore-not-found=true
  kubectl -n "$NAMESPACE_MYSQL" delete service adminer --ignore-not-found=true

  # Deploy Adminer
  cat <<YAML | kubectl apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: adminer
  namespace: ${NAMESPACE_MYSQL}
  labels:
    app: adminer
spec:
  replicas: 1
  selector:
    matchLabels:
      app: adminer
  template:
    metadata:
      labels:
        app: adminer
    spec:
      containers:
      - name: adminer
        image: adminer:latest
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: ADMINER_DEFAULT_SERVER
          value: "${mysql_host}"
        - name: ADMINER_DESIGN
          value: "pepa-linha-dark"
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
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: adminer
  namespace: ${NAMESPACE_MYSQL}
spec:
  selector:
    app: adminer
  ports:
  - port: 8080
    targetPort: 8080
    name: http
YAML

  # Wait for Adminer to be ready
  info "Waiting for Adminer deployment to be ready..."
  kubectl -n "$NAMESPACE_MYSQL" rollout status deployment/adminer --timeout=300s || true

  info "Adminer deployed"
  info "  Default server: ${mysql_host}"
}

deploy_adminer

# ============================================================================
# Phase 5: Create Pomerium-routing Ingress for Adminer
# ============================================================================
create_pomerium_ingress() {
  log "=== Phase 5: Pomerium-routing Ingress ==="

  if [[ "$SKIP_ADMINER" == "true" ]]; then
    info "Skipping Pomerium ingress (Adminer not installed)"
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
  name: adminer
  namespace: ${NAMESPACE_MYSQL}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${ADMINER_HOST}
    secretName: adminer-tls
  rules:
  - host: ${ADMINER_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: adminer
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
  name: adminer-pomerium
  namespace: ${NAMESPACE_SSO}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    cert-manager.io/common-name: ${ADMINER_HOST}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${ADMINER_HOST}
    secretName: adminer-pomerium-tls
  rules:
  - host: ${ADMINER_HOST}
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

  info "Pomerium-routing Ingress created for Adminer"
}

create_pomerium_ingress

# ============================================================================
# Phase 6: Register Pomerium Route
# ============================================================================
register_pomerium_route() {
  log "=== Phase 6: Register Pomerium Route ==="

  if [[ "$SKIP_ADMINER" == "true" ]]; then
    info "Skipping Pomerium route (Adminer not installed)"
    return 0
  fi

  if [[ "${ENFORCE_POMERIUM}" != "true" ]]; then
    info "Pomerium enforcement disabled - skipping route registration"
    return 0
  fi

  local from_url="https://${ADMINER_HOST}"
  local to_url="http://adminer.${NAMESPACE_MYSQL}.svc.cluster.local:8080"

  if provision::pomerium_routes_add "$from_url" "$to_url" "${NAMESPACE_SSO}" true true true; then
    info "Pomerium route ensured: ${from_url} -> ${to_url}"
  else
    warn "Failed to ensure Pomerium route for ${from_url}"
  fi
}

register_pomerium_route || true

# ============================================================================
# Phase 7: Validation
# ============================================================================
validate_deployment() {
  log "=== Phase 7: Validation ==="

  local failed=false

  # Check Percona PS operator
  if kubectl -n "$PERCONA_NAMESPACE" get deploy ps-operator >/dev/null 2>&1; then
    local operator_ready
    operator_ready=$(kubectl -n "$PERCONA_NAMESPACE" get deploy ps-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${operator_ready:-0}" -ge 1 ]]; then
      info "  Percona PS operator is running"
    else
      warn "  Percona PS operator not ready"
      failed=true
    fi
  else
    warn "  Percona PS operator not found"
    failed=true
  fi

  # Check MySQL cluster
  if kubectl -n "$NAMESPACE_MYSQL" get perconaservermysql "$MYSQL_CLUSTER_NAME" >/dev/null 2>&1; then
    local cluster_state
    cluster_state=$(kubectl -n "$NAMESPACE_MYSQL" get perconaservermysql "$MYSQL_CLUSTER_NAME" -o jsonpath='{.status.state}' 2>/dev/null || echo "Unknown")
    if [[ "$cluster_state" == "ready" ]]; then
      info "  MySQL cluster is ready"
    else
      warn "  MySQL cluster state: ${cluster_state}"
    fi
  else
    warn "  MySQL cluster not found"
    failed=true
  fi

  # Check Adminer (if not skipped)
  if [[ "$SKIP_ADMINER" != "true" ]]; then
    if kubectl -n "$NAMESPACE_MYSQL" get deploy adminer >/dev/null 2>&1; then
      local adminer_ready
      adminer_ready=$(kubectl -n "$NAMESPACE_MYSQL" get deploy adminer -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      if [[ "${adminer_ready:-0}" -ge 1 ]]; then
        info "  Adminer is running"
      else
        warn "  Adminer not ready yet"
      fi
    else
      warn "  Adminer deployment not found"
      failed=true
    fi

    # Check Ingress
    local ingress_found=false
    if [[ "${ENFORCE_POMERIUM}" == "true" ]] && kubectl -n "${NAMESPACE_SSO}" get ingress adminer-pomerium >/dev/null 2>&1; then
      info "  Pomerium-routing Ingress exists"
      ingress_found=true
    elif kubectl -n "$NAMESPACE_MYSQL" get ingress adminer >/dev/null 2>&1; then
      info "  Direct Ingress exists"
      ingress_found=true
    fi
    if [[ "$ingress_found" != "true" ]]; then
      warn "  No Ingress found for Adminer"
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
log "=== MySQL provisioning completed for environment: ${ENV_NAME} ==="
info ""
info "Namespaces:"
info "  Operator:   ${PERCONA_NAMESPACE}"
info "  Database:   ${NAMESPACE_MYSQL}"
info ""
info "MySQL Cluster:"
info "  Name:       ${MYSQL_CLUSTER_NAME}"
info "  Image:      ${MYSQL_IMAGE}"
info "  Instances:  1 (single instance, async mode)"
info "  Storage:    ${MYSQL_STORAGE_SIZE} (${MYSQL_STORAGE_CLASS})"
info ""
info "Internal Connection (cluster):"
info "  Host:       $(get_mysql_host)"
info "  Port:       3306"
info ""
info "Credentials:"
info "  Root:       kubectl -n ${NAMESPACE_MYSQL} get secret ${MYSQL_CLUSTER_NAME}-secrets -o jsonpath='{.data.root}' | base64 -d"
info ""

if [[ "$SKIP_ADMINER" != "true" ]]; then
  info "Adminer Web Interface:"
  if [[ "${ENFORCE_POMERIUM}" == "true" ]]; then
    info "  URL:        https://${ADMINER_HOST} (requires GitHub OAuth via Pomerium)"
  else
    info "  URL:        https://${ADMINER_HOST}"
  fi
  info "  System:     MySQL"
  info "  Server:     $(get_mysql_host) (pre-filled)"
  info "  Username:   root"
  _adminer_pass=$(get_mysql_root_password) || true
  if [[ -n "$_adminer_pass" ]]; then
    info "  Password:   ${_adminer_pass}"
  else
    info "  Password:   (not yet available — cluster still initializing)"
  fi
  info "  Database:   (leave empty for all databases)"
  info ""
fi

info "Quick commands:"
info "  Show credentials:  tools/k3s/mysql.sh ${ENV_NAME} --show-credentials"
info "  Cluster status:    kubectl -n ${NAMESPACE_MYSQL} get perconaservermysql ${MYSQL_CLUSTER_NAME}"
info "  Connect via mysql: tools/k3s/mysql.sh ${ENV_NAME} --watch sql"
info ""

# Output actual credentials for easy copy-paste
info "=== Admin Credentials ==="
root_pass=$(get_mysql_root_password) || true
if [[ -n "$root_pass" ]]; then
  mysql_host=$(get_mysql_host)
  echo "MYSQL_HOST=${mysql_host}"
  echo "MYSQL_PORT=3306"
  echo "MYSQL_USERNAME=root"
  echo "MYSQL_PASSWORD=${root_pass}"
  echo "MYSQL_URL=mysql://root:${root_pass}@${mysql_host}:3306/mysql"
else
  info "MySQL root credentials not yet available"
fi

if [[ "$SKIP_ADMINER" != "true" ]]; then
  echo ""
  echo "ADMINER_URL=https://${ADMINER_HOST}"
fi
