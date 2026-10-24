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
#
# env.properties (optional):
#   PG_READONLY_ROLE=claude_ro   A read-only login (pg_read_all_data, read-only sessions,
#                                3 connections) as a CNPG managed role; see
#                                "Read-only login" below
#   PGWEB_ALLOWED_GROUPS=org:admins,org:dba
#                                Groups (Dex groups claim) admitted to pgweb by its Pomerium
#                                route; default: <github-org>:admins. pgweb has no login of its
#                                own, so a NetworkPolicy (pgweb-from-pomerium-only) also keeps
#                                every in-cluster client but Pomerium away from it.
#   PG_WAL_ARCHIVE=minio         Continuous backup with point-in-time recovery (off when unset):
#                                the Barman Cloud plugin archives WAL and takes base backups to
#                                the env's MinIO (tools/k3s/minio.sh, in-cluster endpoint), see
#                                "Continuous backup" below and docs/POSTGRES-BACKUP.md
#   PG_BACKUP_RETENTION=7d       Recovery window kept in the object store (Nd, Nw or Nm)
#   PG_BACKUP_SCHEDULE="0 0 2 * * *"
#                                Base backup schedule (CNPG cron, with seconds, operator time = UTC);
#                                the default finishes before the 06:15 k3s-storage NAS sweep
#   PG_RECOVER_FROM=postgres-cluster  PG_BACKUP_SERVER_NAME=postgres-cluster-20261024
#                                A new cluster is recovered from its backups instead of initdb
#                                (rebuilt node; optional PG_RECOVER_TARGET_TIME), and archives into
#                                a new folder of the bucket
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
# PostgreSQL operand image (CNPG postgres-containers). Use the immutable
# MM.mm-TIMESTAMP-TYPE-OS tag: the bare MM.mm tags (e.g. 16.6) are the deprecated
# "system" images on Debian bullseye, slated for removal upstream. "standard" = minimal +
# pgvector, pgaudit, pg_failover_slots, all locales. It carries no Barman binaries and needs
# none: continuous backup (PG_WAL_ARCHIVE) runs barman-cloud in the Barman Cloud plugin's
# sidecar, not in the operand image (the in-tree barmanObjectStore would need them).
# 16.15-202610190958-standard-trixie = sha256:f105e137d731f6ac4f69667383f2373345ce8b72dadcc10ab6d385a7a32d6e7f
# (pgvector 0.8.7, glibc 2.41). Like the operator, a running cluster keeps its image;
# a changed POSTGRES_IMAGE only warns (see create_postgres_cluster).
: "${POSTGRES_IMAGE:=ghcr.io/cloudnative-pg/postgresql:16.15-202610190958-standard-trixie}"

# CloudNativePG operator settings
# Note: CNPG_VERSION is the Helm chart version, not the operator version
# Chart 0.29.1 = Operator 1.30.1 (supports Kubernetes 1.34-1.36, Postgres 14-18).
# Earlier pairs: 0.22.0 = 1.24.0 (EOL May 2025), 0.27.0 = 1.28.0, 0.28.0 = 1.29.0.
# Only the latest CNPG minor is supported (plus 3 months); bump this every quarter.
# This script installs the operator but never upgrades a running one; to upgrade,
# see the warning printed by install_cnpg_operator below.
CNPG_NAMESPACE="${CNPG_NAMESPACE:-cnpg-system}"
CNPG_VERSION="${CNPG_VERSION:-0.29.1}"

# Optional read-only login on postgres-cluster (e.g. for an operator's or an
# agent's Postgres MCP server): set PG_READONLY_ROLE (e.g. claude_ro) in
# env.properties. Unset = nothing of it is created, patched or applied.
#   PG_READONLY_SECRET     its kubernetes.io/basic-auth password Secret in
#                          $NAMESPACE_POSTGRES (default: the role with - for _, plus -pg,
#                          e.g. claude-ro-pg)
#   PG_READONLY_SOPS_FILE  the file name of its SOPS copy in envs/<env>/secrets.sops when
#                          this script generates the password (default:
#                          <secret>-postgres-cluster.yaml; an existing copy is found by
#                          content, whatever its name)
PG_READONLY_ROLE="${PG_READONLY_ROLE:-}"
if [[ -n "$PG_READONLY_ROLE" ]]; then
  if [[ ! "$PG_READONLY_ROLE" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    err "PG_READONLY_ROLE='${PG_READONLY_ROLE}' is not a plain lower-case Postgres role name"
    exit 1
  fi
  PG_READONLY_SECRET="${PG_READONLY_SECRET:-${PG_READONLY_ROLE//_/-}-pg}"
  PG_READONLY_SOPS_FILE="${PG_READONLY_SOPS_FILE:-${PG_READONLY_SECRET}-postgres-cluster.yaml}"
fi

# Continuous backup (point-in-time recovery), opt-in: PG_WAL_ARCHIVE=minio in env.properties.
# Unset (or "off") = nothing of it is installed, created or patched, and the cluster
# manifest renders without a plugins block.
#   BARMAN_PLUGIN_CHART_VERSION  Helm chart of the Barman Cloud plugin (CNPG-I), installed next
#                                to the operator in $CNPG_NAMESPACE. Chart 0.8.1 = plugin v0.15.1,
#                                which needs CloudNativePG >= 1.26 and cert-manager (identity.sh
#                                installs it). Like the operator, a running plugin is never
#                                upgraded here: a new plugin version changes the sidecar image
#                                and so restarts every instance.
#   PG_BACKUP_BUCKET             MinIO bucket (default cnpg-backups); objects land under
#                                s3://<bucket>/<cluster name>/{base,wals}
#   PG_BACKUP_OBJECTSTORE        name of the ObjectStore CR in $NAMESPACE_POSTGRES
#   PG_BACKUP_S3_USER            MinIO access key the plugin uses; its policy reaches that
#                                bucket only. The MinIO root key never leaves the minio namespace.
#   PG_BACKUP_S3_SECRET          Secret in $NAMESPACE_POSTGRES with ACCESS_KEY_ID/ACCESS_SECRET_KEY,
#                                kept, restored from secrets.sops, or generated and SOPS-encrypted
#   PG_BACKUP_ENDPOINT           S3 endpoint (default: the MinIO Service, plain HTTP inside the
#                                cluster; not the public s3.<HOSTNAME> ingress)
PG_WAL_ARCHIVE="${PG_WAL_ARCHIVE:-}"
[[ "$PG_WAL_ARCHIVE" == "off" ]] && PG_WAL_ARCHIVE=""
if [[ -n "$PG_WAL_ARCHIVE" && "$PG_WAL_ARCHIVE" != "minio" ]]; then
  err "PG_WAL_ARCHIVE='${PG_WAL_ARCHIVE}' is not supported (use minio, or leave it unset)"
  exit 1
fi
BARMAN_PLUGIN_CHART_VERSION="${BARMAN_PLUGIN_CHART_VERSION:-0.8.1}"
BARMAN_PLUGIN_NAME="barman-cloud.cloudnative-pg.io"
NAMESPACE_MINIO="${NAMESPACE_MINIO:-minio}"
PG_BACKUP_BUCKET="${PG_BACKUP_BUCKET:-cnpg-backups}"
PG_BACKUP_OBJECTSTORE="${PG_BACKUP_OBJECTSTORE:-postgres-cluster-minio}"
PG_BACKUP_S3_USER="${PG_BACKUP_S3_USER:-cnpg-backup}"
PG_BACKUP_S3_SECRET="${PG_BACKUP_S3_SECRET:-postgres-cluster-backup-s3}"
PG_BACKUP_SOPS_FILE="${PG_BACKUP_SOPS_FILE:-${PG_BACKUP_S3_SECRET}.yaml}"
PG_BACKUP_ENDPOINT="${PG_BACKUP_ENDPOINT:-http://minio.${NAMESPACE_MINIO}.svc.cluster.local:9000}"
PG_BACKUP_RETENTION="${PG_BACKUP_RETENTION:-7d}"
PG_BACKUP_SCHEDULE="${PG_BACKUP_SCHEDULE:-0 0 2 * * *}"
#   PG_BACKUP_SERVER_NAME        folder of this cluster's backups in the bucket (default: the
#                                cluster name, postgres-cluster). A cluster recovered from backup
#                                needs a new one: the plugin refuses to archive into a folder that
#                                already holds another cluster's WAL.
#   PG_RECOVER_FROM              only when the cluster does not exist yet (a rebuilt node): bootstrap
#                                it from the backups in folder PG_RECOVER_FROM (e.g. postgres-cluster)
#                                instead of an empty initdb; PG_RECOVER_TARGET_TIME (e.g.
#                                "2026-10-24 09:00:00+00") stops the replay there, unset = replay all.
PG_BACKUP_SERVER_NAME="${PG_BACKUP_SERVER_NAME:-}"
PG_RECOVER_FROM="${PG_RECOVER_FROM:-}"
PG_RECOVER_TARGET_TIME="${PG_RECOVER_TARGET_TIME:-}"
if [[ -n "$PG_RECOVER_FROM" ]]; then
  if [[ -z "$PG_WAL_ARCHIVE" ]]; then
    err "PG_RECOVER_FROM needs PG_WAL_ARCHIVE=minio (the ObjectStore it reads the backups from)"
    exit 1
  fi
  if [[ "${PG_BACKUP_SERVER_NAME:-postgres-cluster}" == "$PG_RECOVER_FROM" ]]; then
    err "PG_RECOVER_FROM=${PG_RECOVER_FROM}: the recovered cluster must archive into a new folder."
    err "  Set PG_BACKUP_SERVER_NAME too, e.g. PG_BACKUP_SERVER_NAME=postgres-cluster-$(date -u +%Y%m%d), and keep it in env.properties."
    exit 1
  fi
fi
for _name in "$PG_BACKUP_SERVER_NAME" "$PG_RECOVER_FROM"; do
  if [[ -n "$_name" && ! "$_name" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    err "'${_name}' is not a valid backup folder name (PG_BACKUP_SERVER_NAME / PG_RECOVER_FROM)"
    exit 1
  fi
done
unset _name
if [[ -n "$PG_RECOVER_TARGET_TIME" && ! "$PG_RECOVER_TARGET_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[\ T][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)$ ]]; then
  err "PG_RECOVER_TARGET_TIME='${PG_RECOVER_TARGET_TIME}' must be a timestamp with a zone, e.g. 2026-10-24 09:00:00+00"
  exit 1
fi
if [[ -n "$PG_WAL_ARCHIVE" ]]; then
  if [[ ! "$PG_BACKUP_RETENTION" =~ ^[1-9][0-9]*[dwm]$ ]]; then
    err "PG_BACKUP_RETENTION='${PG_BACKUP_RETENTION}' must look like 7d, 2w or 1m"
    exit 1
  fi
  if [[ ! "$PG_BACKUP_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
    err "PG_BACKUP_BUCKET='${PG_BACKUP_BUCKET}' is not a valid S3 bucket name"
    exit 1
  fi
  if [[ ! "$PG_BACKUP_S3_USER" =~ ^[A-Za-z0-9_-]{3,20}$ ]]; then
    err "PG_BACKUP_S3_USER='${PG_BACKUP_S3_USER}' must be 3-20 characters of A-Z a-z 0-9 _ -"
    exit 1
  fi
  read -r -a _sched_fields <<< "$PG_BACKUP_SCHEDULE"
  if [[ ${#_sched_fields[@]} -ne 6 ]]; then
    err "PG_BACKUP_SCHEDULE='${PG_BACKUP_SCHEDULE}' needs six fields (CNPG cron starts with seconds)"
    exit 1
  fi
  unset _sched_fields
fi

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
      kubectl -n "$namespace" get objectstores.barmancloud.cnpg.io 2>/dev/null || true
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
# A running operator is left alone: an operator upgrade restarts every Postgres
# instance (a single-instance cluster has no switchover), so it is a planned step,
# not a side effect of re-running this script. Say so when the live chart differs.
warn_cnpg_chart_drift() {
  local live_chart
  live_chart=$(kubectl -n "$CNPG_NAMESPACE" get deploy cnpg-cloudnative-pg \
    -o jsonpath='{.metadata.labels.helm\.sh/chart}' 2>/dev/null || true)
  if [[ -n "$live_chart" && "$live_chart" != "cloudnative-pg-${CNPG_VERSION}" ]]; then
    warn "CloudNativePG operator runs ${live_chart}; CNPG_VERSION is ${CNPG_VERSION}. Not upgrading it here."
    warn "  Read the CNPG release notes, back up, then (restarts every instance):"
    warn "  helm upgrade cnpg cnpg/cloudnative-pg -n ${CNPG_NAMESPACE} --version ${CNPG_VERSION} --reset-values --wait"
    warn "  (--reuse-values fails across chart versions: the new templates need values the old chart lacks)"
  fi
}

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
      warn_cnpg_chart_drift
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
# Continuous backup (PG_WAL_ARCHIVE=minio, optional)
# ============================================================================
# The Barman Cloud plugin (CNPG-I) replaces the in-tree spec.backup.barmanObjectStore,
# which is deprecated and goes away after CNPG 1.31. Pieces, each idempotent:
#   1b. the plugin itself, next to the operator (Helm, never upgraded here);
#   1c. a MinIO bucket and an access key whose policy reaches that bucket only, the key in
#       Secret $PG_BACKUP_S3_SECRET (SOPS copy in the envs repo), and the ObjectStore CR
#       with the retention policy;
#   2.  a new cluster gets spec.plugins (isWALArchiver: true) in its manifest; a running
#       cluster without it is not patched: the script prints the patch, as for image drift;
#   2b. a ScheduledBackup (method: plugin) once the cluster has the plugin.
# Recovery and the restore drill: docs/POSTGRES-BACKUP.md.
wal_archive_enabled() { [[ "$PG_WAL_ARCHIVE" == "minio" ]]; }

# "1.30" from the operator's image (…/cloudnative-pg:1.30.1[@sha256:…]); empty if unknown.
cnpg_operator_minor() {
  local image tag
  image=$(kubectl -n "$CNPG_NAMESPACE" get deploy cnpg-cloudnative-pg \
            -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  tag="${image%%@*}"
  tag="${tag##*:}"
  [[ "$tag" =~ ^v?([0-9]+)\.([0-9]+) ]] && echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
}

install_barman_plugin() {
  wal_archive_enabled || return 0
  log "=== Phase 1b: Barman Cloud plugin ==="

  if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    err "cert-manager is not installed; the Barman Cloud plugin needs it for its operator TLS."
    err "Run tools/k3s/identity.sh ${ENV_NAME} first."
    exit 1
  fi
  local minor
  minor=$(cnpg_operator_minor)
  if [[ -z "$minor" ]]; then
    warn "Could not read the CloudNativePG operator version; the plugin needs 1.26 or later"
  elif (( ${minor%%.*} == 1 && ${minor#*.} < 26 )); then
    err "CloudNativePG operator ${minor} is too old for the Barman Cloud plugin (needs 1.26+)."
    err "Upgrade the operator first (see the CNPG_VERSION note above), or unset PG_WAL_ARCHIVE."
    exit 1
  fi

  local live_chart
  live_chart=$(kubectl -n "$CNPG_NAMESPACE" get deploy plugin-barman-cloud \
                 -o jsonpath='{.metadata.labels.helm\.sh/chart}' 2>/dev/null || true)
  if [[ -n "$live_chart" ]]; then
    info "Barman Cloud plugin already installed (${live_chart})"
    if [[ "$live_chart" != "plugin-barman-cloud-${BARMAN_PLUGIN_CHART_VERSION}" ]]; then
      warn "Barman Cloud plugin runs ${live_chart}; BARMAN_PLUGIN_CHART_VERSION is ${BARMAN_PLUGIN_CHART_VERSION}. Not upgrading it here."
      warn "  A new plugin version changes the sidecar image, so every instance restarts. Read the"
      warn "  plugin's upgrade notes (0.8.x renamed its RBAC objects), then:"
      warn "  helm upgrade plugin-barman-cloud cnpg/plugin-barman-cloud -n ${CNPG_NAMESPACE} --version ${BARMAN_PLUGIN_CHART_VERSION} --wait"
    fi
    return 0
  fi

  if ! helm repo list 2>/dev/null | grep -q cloudnative-pg; then
    helm repo add cnpg https://cloudnative-pg.github.io/charts
  fi
  helm repo update cnpg >/dev/null
  info "Installing the Barman Cloud plugin (chart ${BARMAN_PLUGIN_CHART_VERSION}) into ${CNPG_NAMESPACE}..."
  helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud \
    --namespace "$CNPG_NAMESPACE" \
    --version "$BARMAN_PLUGIN_CHART_VERSION" \
    --wait \
    --timeout 5m
  kubectl -n "$CNPG_NAMESPACE" rollout status deployment/plugin-barman-cloud --timeout=120s
  info "✓ Barman Cloud plugin installed"
}

# The plugin's S3 key. Kept when the cluster has it; applied from the envs repo's SOPS copy
# when there is one (a rebuilt node, whose MinIO data came back from the NAS with this very
# key in it); otherwise generated, applied, and encrypted into envs/<env>/secrets.sops.
# The secret key is never printed.
ensure_backup_s3_secret() {
  local ns="$NAMESPACE_POSTGRES" secret="$PG_BACKUP_S3_SECRET" f sops_copy=""
  if kubectl -n "$ns" get secret "$secret" >/dev/null 2>&1; then
    info "Backup S3 key: keeping the existing secret ${ns}/${secret}"
    return 0
  fi
  for f in "${ENVS_ROOT}/${ENV_NAME}/secrets.sops/"*.yaml; do
    [[ -f "$f" ]] || continue
    if [[ -n "$(NS="$ns" NAME="$secret" yq eval 'select(.kind == "Secret" and .metadata.name == strenv(NAME) and .metadata.namespace == strenv(NS)) | .metadata.name' "$f" 2>/dev/null)" ]]; then
      sops_copy="$f"
      break
    fi
  done
  if [[ -n "$sops_copy" ]]; then
    info "Backup S3 key: applying ${secret} from ${sops_copy#"${ENVS_ROOT}/"}"
    if ! command -v sops >/dev/null 2>&1 || ! sops -d "$sops_copy" | kubectl apply -f - >/dev/null; then
      err "Could not decrypt ${sops_copy#"${ENVS_ROOT}/"} (sops and the age key are needed);"
      err "apply the env's secrets first: tools/sops/apply.sh ${ENV_NAME}"
      return 1
    fi
    return 0
  fi

  local plain="${ENVS_ROOT}/${ENV_NAME}/secrets.plain/${PG_BACKUP_SOPS_FILE}" key
  provision::assert_plaintext_ignored "$plain" || return 1
  key="$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-40)"
  ( umask 077
    mkdir -p "$(dirname "$plain")"
    cat > "$plain" <<YAML
# The MinIO access key of the Barman Cloud plugin (WAL archive and base backups of
# postgres-cluster in ${ns}); its MinIO policy reaches bucket ${PG_BACKUP_BUCKET} only.
# Written by infra-skills tools/k3s/postgres.sh; never commit.
apiVersion: v1
kind: Secret
metadata:
  name: ${secret}
  namespace: ${ns}
type: Opaque
stringData:
  ACCESS_KEY_ID: ${PG_BACKUP_S3_USER}
  ACCESS_SECRET_KEY: "${key}"
YAML
  )
  unset key
  kubectl apply -f "$plain" >/dev/null
  info "Backup S3 key: generated a key into secret ${ns}/${secret}"
  if command -v sops >/dev/null 2>&1 && \
     "$REPO_ROOT/tools/sops/encrypt.sh" "$ENV_NAME" "$PG_BACKUP_SOPS_FILE" >/dev/null && \
     grep -q 'ACCESS_SECRET_KEY: ENC\[' "${ENVS_ROOT}/${ENV_NAME}/secrets.sops/${PG_BACKUP_SOPS_FILE}"; then
    rm -f "$plain"
    info "  encrypted to ${ENV_NAME}/secrets.sops/${PG_BACKUP_SOPS_FILE} - commit it in the envs repo"
  else
    warn "  could not SOPS-encrypt it; the plaintext stays (git-ignored) at ${plain#"${ENVS_ROOT}/"}:"
    warn "  tools/sops/encrypt.sh ${ENV_NAME} ${PG_BACKUP_SOPS_FILE}, then delete the plaintext"
  fi
}

# Bucket, bucket-scoped policy and the plugin's user, made with the mc that ships in the
# MinIO image, inside the MinIO pod: the root credentials stay in that pod's environment,
# and the plugin's key goes in over stdin, not on any command line on this machine.
# Every step is a no-op when it is already in place (user add re-sets the same key).
ensure_minio_bucket_and_user() {
  local ns="$NAMESPACE_MINIO" access secret_key
  access=$(kubectl -n "$NAMESPACE_POSTGRES" get secret "$PG_BACKUP_S3_SECRET" \
             -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)
  secret_key=$(kubectl -n "$NAMESPACE_POSTGRES" get secret "$PG_BACKUP_S3_SECRET" \
             -o jsonpath='{.data.ACCESS_SECRET_KEY}' | base64 -d)
  if [[ -z "$access" || -z "$secret_key" ]]; then
    err "Secret ${NAMESPACE_POSTGRES}/${PG_BACKUP_S3_SECRET} lacks ACCESS_KEY_ID or ACCESS_SECRET_KEY"
    return 1
  fi
  local out
  if ! out=$(printf '%s\n%s\n' "$access" "$secret_key" | \
       kubectl -n "$ns" exec -i deploy/minio -c minio -- sh -c '
set -eu
IFS= read -r ACCESS
IFS= read -r SECRET
BUCKET="$1"; POLICY="$2"
export MC_CONFIG_DIR="/tmp/.mc-cnpg-$$"
trap "rm -rf \"$MC_CONFIG_DIR\"" EXIT
mkdir -p "$MC_CONFIG_DIR"
export MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@127.0.0.1:9000"
mc --quiet mb --ignore-existing "local/${BUCKET}" >/dev/null
cat > "$MC_CONFIG_DIR/policy.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:GetBucketLocation","s3:ListBucket","s3:ListBucketMultipartUploads"],
  "Resource":["arn:aws:s3:::${BUCKET}"]},
 {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"],
  "Resource":["arn:aws:s3:::${BUCKET}/*"]}]}
EOF
mc --quiet admin policy create local "$POLICY" "$MC_CONFIG_DIR/policy.json" >/dev/null
mc --quiet admin user add local "$ACCESS" "$SECRET" >/dev/null
# (the image has no grep) attach only when not attached yet: a second attach is an error
USERINFO=$(mc --quiet admin user info local "$ACCESS" --json)
case "$USERINFO" in
  *"\"$POLICY\""*) ;;
  *) mc --quiet admin policy attach local "$POLICY" --user "$ACCESS" >/dev/null ;;
esac
echo "bucket ${BUCKET}, user ${ACCESS}, policy ${POLICY}"
' sh "$PG_BACKUP_BUCKET" "${PG_BACKUP_BUCKET}-rw" 2>&1); then
    unset secret_key
    # mc may echo the alias URL, root credentials included: mask user:password@.
    err "Could not set up the MinIO bucket and user: $(sed -E 's#//[^/@[:space:]]*@#//***@#g' <<< "$out")"
    return 1
  fi
  unset secret_key
  info "✓ MinIO: ${out}"
}

ensure_backup_object_store() {
  wal_archive_enabled || return 0
  log "=== Phase 1c: Backup object store (MinIO) ==="

  if ! kubectl -n "$NAMESPACE_MINIO" get deploy minio >/dev/null 2>&1; then
    err "PG_WAL_ARCHIVE=minio, but there is no MinIO in namespace ${NAMESPACE_MINIO}."
    err "Run tools/k3s/minio.sh ${ENV_NAME} first (tools/up.sh: add minio to UP_OPTIONAL_STEPS)."
    exit 1
  fi
  kubectl -n "$NAMESPACE_MINIO" rollout status deploy/minio --timeout=180s >/dev/null || {
    err "MinIO in ${NAMESPACE_MINIO} is not ready"; exit 1; }

  kubectl get ns "$NAMESPACE_POSTGRES" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_POSTGRES"
  ensure_backup_s3_secret || { err "No S3 key for the plugin; continuous backup not set up"; exit 1; }
  ensure_minio_bucket_and_user || exit 1

  # The ObjectStore is the plugin's own CR, not the Cluster spec: applying it on a re-run
  # only carries PG_BACKUP_RETENTION and the endpoint over. An instanceSidecarConfiguration
  # change would roll the instances, so there is none here.
  cat <<YAML | kubectl apply -f -
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: ${PG_BACKUP_OBJECTSTORE}
  namespace: ${NAMESPACE_POSTGRES}
spec:
  # Recovery window: base backups older than the newest one before (now - window) go,
  # with their WAL, after the next backup completes.
  retentionPolicy: "${PG_BACKUP_RETENTION}"
  configuration:
    destinationPath: s3://${PG_BACKUP_BUCKET}/
    endpointURL: ${PG_BACKUP_ENDPOINT}
    s3Credentials:
      accessKeyId:
        name: ${PG_BACKUP_S3_SECRET}
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: ${PG_BACKUP_S3_SECRET}
        key: ACCESS_SECRET_KEY
    wal:
      compression: gzip
      maxParallel: 2
    data:
      compression: gzip
      jobs: 2
YAML
  info "✓ ObjectStore ${NAMESPACE_POSTGRES}/${PG_BACKUP_OBJECTSTORE} -> s3://${PG_BACKUP_BUCKET}/ at ${PG_BACKUP_ENDPOINT} (retention ${PG_BACKUP_RETENTION})"
}

install_barman_plugin
ensure_backup_object_store

# The spec.plugins entry of postgres-cluster, as one line of JSON (also valid YAML flow style).
# serverName only when PG_BACKUP_SERVER_NAME is set (default: the cluster's name).
barman_plugin_json() {
  jq -cn --arg name "$BARMAN_PLUGIN_NAME" --arg store "$PG_BACKUP_OBJECTSTORE" \
         --arg server "$PG_BACKUP_SERVER_NAME" \
    '{name: $name, isWALArchiver: true,
      parameters: ({barmanObjectName: $store} + (if $server == "" then {} else {serverName: $server} end))}'
}

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
# Read-only login (PG_READONLY_ROLE, optional)
# ============================================================================
# A CNPG managed role: login, member of pg_read_all_data (reads every table of every
# database of the cluster), at most 3 connections, its password in a Secret CNPG
# watches (cnpg.io/reload). The session settings CNPG cannot declare are set once as
# postgres: read-only transactions, a 30 s statement timeout, 60 s idle in a
# transaction. This reproduces the hand procedure of the envs repos'
# envs/<env>/postgres/postgres-cluster-claude-ro.patch.yaml and is a no-op on a
# cluster that already has it.

# The managed-role entry, as one line of JSON (also valid YAML flow style).
pg_readonly_role_json() {
  jq -cn --arg name "$PG_READONLY_ROLE" --arg secret "$PG_READONLY_SECRET" '{
    name: $name, ensure: "present", comment: "read-only login (pg_read_all_data)",
    login: true, inherit: true, connectionLimit: 3,
    inRoles: ["pg_read_all_data"], passwordSecret: {name: $secret}
  }'
}

# The password Secret. Kept when the cluster has it; applied from the envs repo's
# SOPS copy when there is one; otherwise generated, applied, and encrypted into
# envs/<env>/secrets.sops (the plaintext is removed). The value is never printed.
ensure_pg_readonly_secret() {
  local ns="$NAMESPACE_POSTGRES" secret="$PG_READONLY_SECRET" f sops_copy=""
  if kubectl -n "$ns" get secret "$secret" >/dev/null 2>&1; then
    info "Read-only login: keeping the existing secret ${ns}/${secret}"
    return 0
  fi
  for f in "${ENVS_ROOT}/${ENV_NAME}/secrets.sops/"*.yaml; do
    [[ -f "$f" ]] || continue
    if [[ -n "$(NS="$ns" NAME="$secret" yq eval 'select(.kind == "Secret" and .metadata.name == strenv(NAME) and .metadata.namespace == strenv(NS)) | .metadata.name' "$f" 2>/dev/null)" ]]; then
      sops_copy="$f"
      break
    fi
  done
  if [[ -n "$sops_copy" ]]; then
    info "Read-only login: applying ${secret} from ${sops_copy#"${ENVS_ROOT}/"}"
    if ! command -v sops >/dev/null 2>&1 || ! sops -d "$sops_copy" | kubectl apply -f - >/dev/null; then
      err "Could not decrypt ${sops_copy#"${ENVS_ROOT}/"} (sops and the age key are needed);"
      err "apply the env's secrets first: tools/sops/apply.sh ${ENV_NAME}"
      return 1
    fi
    return 0
  fi

  local plain="${ENVS_ROOT}/${ENV_NAME}/secrets.plain/${PG_READONLY_SOPS_FILE}" pw
  provision::assert_plaintext_ignored "$plain" || return 1
  pw="$(openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-40)"
  ( umask 077
    mkdir -p "$(dirname "$plain")"
    cat > "$plain" <<YAML
# The password of the read-only Postgres role ${PG_READONLY_ROLE} (pg_read_all_data) of the CNPG cluster
# postgres-cluster in ${ns}, read by CNPG (spec.managed.roles passwordSecret).
# Written by infra-skills tools/k3s/postgres.sh; never commit.
apiVersion: v1
kind: Secret
metadata:
  name: ${secret}
  namespace: ${ns}
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: ${PG_READONLY_ROLE}
  password: "${pw}"
YAML
  )
  unset pw
  kubectl apply -f "$plain" >/dev/null
  info "Read-only login: generated a password into secret ${ns}/${secret}"
  if command -v sops >/dev/null 2>&1 && \
     "$REPO_ROOT/tools/sops/encrypt.sh" "$ENV_NAME" "$PG_READONLY_SOPS_FILE" >/dev/null && \
     grep -q 'password: ENC\[' "${ENVS_ROOT}/${ENV_NAME}/secrets.sops/${PG_READONLY_SOPS_FILE}"; then
    rm -f "$plain"
    info "  encrypted to ${ENV_NAME}/secrets.sops/${PG_READONLY_SOPS_FILE} - commit it in the envs repo"
  else
    warn "  could not SOPS-encrypt it; the plaintext stays (git-ignored) at ${plain#"${ENVS_ROOT}/"}:"
    warn "  tools/sops/encrypt.sh ${ENV_NAME} ${PG_READONLY_SOPS_FILE}, then delete the plaintext"
  fi
}

# The managed role on an existing cluster (a new cluster gets it from its manifest),
# then the session settings once CNPG reports the role.
ensure_pg_readonly_role() {
  [[ -n "$PG_READONLY_ROLE" ]] || return 0
  log "=== Read-only login: ${PG_READONLY_ROLE} ==="
  local ns="$NAMESPACE_POSTGRES" role="$PG_READONLY_ROLE" cluster_json patch role_json

  ensure_pg_readonly_secret || { warn "Read-only login skipped (no password secret)"; return 0; }

  if ! cluster_json=$(kubectl -n "$ns" get cluster postgres-cluster -o json 2>/dev/null); then
    warn "No CNPG cluster postgres-cluster in ${ns} - read-only login skipped"
    return 0
  fi
  if jq -e --arg n "$role" '.spec.managed.roles[]? | select(.name == $n)' <<< "$cluster_json" >/dev/null; then
    info "Managed role ${role} already declared on postgres-cluster - leaving its spec as it is"
  else
    role_json=$(pg_readonly_role_json)
    # A JSON patch that appends: a merge patch would replace spec.managed.roles
    # wholesale and drop any other managed role.
    if jq -e '.spec.managed.roles' <<< "$cluster_json" >/dev/null; then
      patch="[{\"op\":\"add\",\"path\":\"/spec/managed/roles/-\",\"value\":${role_json}}]"
    elif jq -e '.spec.managed' <<< "$cluster_json" >/dev/null; then
      patch="[{\"op\":\"add\",\"path\":\"/spec/managed/roles\",\"value\":[${role_json}]}]"
    else
      patch="[{\"op\":\"add\",\"path\":\"/spec/managed\",\"value\":{\"roles\":[${role_json}]}}]"
    fi
    kubectl -n "$ns" patch cluster postgres-cluster --type json -p "$patch" >/dev/null
    info "✓ Managed role ${role} added to postgres-cluster"
  fi

  local reconciled=false i
  for i in {1..24}; do
    if kubectl -n "$ns" get cluster postgres-cluster -o json 2>/dev/null | \
         jq -e --arg n "$role" '(.status.managedRolesStatus.byStatus.reconciled // []) | index($n) != null' >/dev/null; then
      reconciled=true
      break
    fi
    sleep 5
  done
  if [[ "$reconciled" != "true" ]]; then
    warn "CNPG has not reconciled ${role} within 2 minutes (kubectl -n ${ns} get cluster postgres-cluster"
    warn "  -o jsonpath='{.status.managedRolesStatus}'); re-run this script to set its session settings."
    return 0
  fi

  local pg_pod
  pg_pod=$(kubectl -n "$ns" get pod -l cnpg.io/cluster=postgres-cluster,cnpg.io/instanceRole=primary \
             -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$pg_pod" ]]; then
    warn "No primary Postgres pod found - session settings of ${role} not checked"
    return 0
  fi
  # ALTER ROLE ... SET is idempotent; reading first keeps a re-run quiet and honest.
  local want="default_transaction_read_only=on,idle_in_transaction_session_timeout=60s,statement_timeout=30s" have
  have=$(kubectl -n "$ns" exec -i "$pg_pod" -c postgres -- psql -U postgres -d postgres -At -v ON_ERROR_STOP=1 \
           -v role="$role" 2>/dev/null <<'SQL' || true
SELECT coalesce(string_agg(c, ',' ORDER BY c), '')
FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole, unnest(s.setconfig) AS c
WHERE r.rolname = :'role' AND s.setdatabase = 0
  AND split_part(c, '=', 1) IN ('default_transaction_read_only', 'statement_timeout', 'idle_in_transaction_session_timeout');
SQL
)
  if [[ "$have" == "$want" ]]; then
    info "✓ ${role}: read-only session settings already in place"
    return 0
  fi
  if kubectl -n "$ns" exec -i "$pg_pod" -c postgres -- psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 \
       -v role="$role" >/dev/null <<'SQL'
ALTER ROLE :"role" SET default_transaction_read_only = on;
ALTER ROLE :"role" SET statement_timeout = '30s';
ALTER ROLE :"role" SET idle_in_transaction_session_timeout = '60s';
SQL
  then
    info "✓ ${role}: default_transaction_read_only=on, statement_timeout=30s, idle_in_transaction_session_timeout=60s"
  else
    warn "Could not set the session settings of ${role} on ${ns}/${pg_pod}"
  fi
}

# A running cluster keeps its pg_hba: say so when it still has md5 lines (INFRA-65), and
# print the patch (every md5 line becomes scram-sha-256, other lines unchanged). pg_hba is
# reloaded, not restarted, but a role whose stored password is still an MD5 hash can no
# longer log in afterwards: check first (docs/POSTGRES-BACKUP.md, "md5 to SCRAM").
warn_pg_hba_md5() {
  local hba
  hba=$(kubectl -n "$NAMESPACE_POSTGRES" get cluster postgres-cluster -o json 2>/dev/null | \
          jq -c '.spec.postgresql.pg_hba // []') || return 0
  jq -e 'any(.[]; test("\\smd5\\s*$"))' <<< "$hba" >/dev/null || return 0
  local patch
  patch=$(jq -c '{spec: {postgresql: {pg_hba: map(sub("\\smd5\\s*$"; " scram-sha-256"))}}}' <<< "$hba")
  warn "postgres-cluster pg_hba still has md5 lines; new clusters get scram-sha-256. Not changing it here."
  warn "  First check no login role has an MD5-hashed password (docs/POSTGRES-BACKUP.md, \"md5 to SCRAM\"):"
  warn "  kubectl -n ${NAMESPACE_POSTGRES} exec postgres-cluster-1 -c postgres -- psql -U postgres -Atc \"select rolname from pg_authid where rolpassword like 'md5%'\""
  warn "  If that prints nothing (a reload, no restart):"
  warn "  kubectl -n ${NAMESPACE_POSTGRES} patch cluster postgres-cluster --type=merge -p '${patch}'"
}

# Continuous backup on the cluster (PG_WAL_ARCHIVE=minio): the plugin entry, the scheduled
# base backup, and a look at the WAL archiver. A running cluster without the plugin entry
# is not patched; the patch is printed, as for image drift.
ensure_cluster_backup() {
  local ns="$NAMESPACE_POSTGRES" cluster_json
  cluster_json=$(kubectl -n "$ns" get cluster postgres-cluster -o json 2>/dev/null) || return 0

  if ! wal_archive_enabled; then
    if jq -e --arg p "$BARMAN_PLUGIN_NAME" '.spec.plugins[]? | select(.name == $p)' <<< "$cluster_json" >/dev/null; then
      info "postgres-cluster has the Barman Cloud plugin but PG_WAL_ARCHIVE is unset - leaving it as it is"
    fi
    return 0
  fi
  log "=== Phase 2b: Continuous backup on postgres-cluster ==="

  if jq -e '.spec.backup.barmanObjectStore' <<< "$cluster_json" >/dev/null; then
    warn "postgres-cluster also has the in-tree spec.backup.barmanObjectStore; two archivers must not"
    warn "  run at once. Follow the plugin's migration guide before relying on either:"
    warn "  https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/"
  fi

  local entry
  entry=$(jq -c --arg p "$BARMAN_PLUGIN_NAME" '[.spec.plugins[]? | select(.name == $p)][0] // empty' <<< "$cluster_json")
  if [[ -z "$entry" ]]; then
    local value patch
    value=$(barman_plugin_json)
    if jq -e '.spec.plugins' <<< "$cluster_json" >/dev/null; then
      patch="[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":${value}}]"
    else
      patch="[{\"op\":\"add\",\"path\":\"/spec/plugins\",\"value\":[${value}]}]"
    fi
    warn "postgres-cluster has no WAL archiver; PG_WAL_ARCHIVE=minio wants the Barman Cloud plugin. Not changing it here."
    warn "  Adding it injects the plugin sidecar, so the instance restarts (a single instance: a short outage):"
    warn "  kubectl -n ${ns} patch cluster postgres-cluster --type=json -p '${patch}'"
    warn "  Then re-run this script: it creates the ScheduledBackup once the plugin is on the cluster."
    return 0
  fi
  local store archiver
  store=$(jq -r '.parameters.barmanObjectName // ""' <<< "$entry")
  archiver=$(jq -r '.isWALArchiver // false' <<< "$entry")
  if [[ "$store" != "$PG_BACKUP_OBJECTSTORE" ]]; then
    warn "postgres-cluster's Barman Cloud plugin uses ObjectStore '${store}', not ${PG_BACKUP_OBJECTSTORE}. Leaving it."
  fi
  local live_server
  live_server=$(jq -r '.parameters.serverName // "postgres-cluster"' <<< "$entry")
  if [[ "$live_server" != "${PG_BACKUP_SERVER_NAME:-postgres-cluster}" ]]; then
    warn "postgres-cluster archives into folder '${live_server}', PG_BACKUP_SERVER_NAME says '${PG_BACKUP_SERVER_NAME:-postgres-cluster}'."
    warn "  Leaving it; set PG_BACKUP_SERVER_NAME=${live_server} in env.properties so the two agree."
  fi
  if [[ "$archiver" != "true" ]]; then
    warn "postgres-cluster's Barman Cloud plugin is not the WAL archiver (isWALArchiver is not true):"
    warn "  base backups alone give no point-in-time recovery. Not changing it here."
  fi

  # The ScheduledBackup is its own object; applying it changes no Cluster spec. immediate:
  # the first base backup runs now, not at the first scheduled time, so the recovery
  # window starts today.
  cat <<YAML | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: postgres-cluster-daily
  namespace: ${ns}
spec:
  # CNPG cron: seconds first; the operator runs in UTC. Done before the 06:15 NAS sweep
  # (tools/backup.sh), which copies the MinIO volume off the node.
  schedule: "${PG_BACKUP_SCHEDULE}"
  immediate: true
  backupOwnerReference: self
  cluster:
    name: postgres-cluster
  method: plugin
  pluginConfiguration:
    name: ${BARMAN_PLUGIN_NAME}
YAML
  info "✓ ScheduledBackup ${ns}/postgres-cluster-daily (${PG_BACKUP_SCHEDULE}, UTC)"

  # WAL archiving shows as the ContinuousArchiving condition; give a fresh plugin a minute.
  local i status=""
  for i in {1..12}; do
    status=$(kubectl -n "$ns" get cluster postgres-cluster -o json 2>/dev/null | \
               jq -r '(.status.conditions // [])[] | select(.type == "ContinuousArchiving") | "\(.status) \(.reason // "") \(.message // "")"' || true)
    [[ "$status" == True* ]] && break
    sleep 5
  done
  if [[ "$status" == True* ]]; then
    info "✓ WAL archiving works (ContinuousArchiving: ${status})"
  else
    warn "WAL archiving not confirmed yet (ContinuousArchiving: ${status:-no condition}). Check:"
    warn "  kubectl -n ${ns} get cluster postgres-cluster -o jsonpath='{.status.conditions}'"
    warn "  kubectl -n ${ns} logs postgres-cluster-1 -c plugin-barman-cloud --tail=50"
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

    # The image is never changed here: a new imageName restarts the instance. Say so.
    local live_image
    live_image=$(kubectl -n "$NAMESPACE_POSTGRES" get cluster postgres-cluster -o jsonpath='{.spec.imageName}' 2>/dev/null || true)
    if [[ -n "$live_image" && "$live_image" != "$POSTGRES_IMAGE" ]]; then
      warn "postgres-cluster runs ${live_image}; POSTGRES_IMAGE is ${POSTGRES_IMAGE}. Not changing it here."
      warn "  Back up, then (restarts the instance; same major only, a major upgrade needs its own plan):"
      warn "  kubectl -n ${NAMESPACE_POSTGRES} patch cluster postgres-cluster --type=merge -p '{\"spec\":{\"imageName\":\"${POSTGRES_IMAGE}\"}}'"
    fi
    warn_pg_hba_md5
    [[ -n "$PG_RECOVER_FROM" ]] && \
      warn "PG_RECOVER_FROM=${PG_RECOVER_FROM} ignored: postgres-cluster exists (it only bootstraps a new cluster); remove it from env.properties"

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
    # The read-only login's role goes into the manifest (a new cluster), so its password
    # Secret has to exist first; an existing cluster gets the role from
    # ensure_pg_readonly_role. Unset PG_READONLY_ROLE renders the manifest exactly as before.
    local managed_block=""
    if [[ -n "$PG_READONLY_ROLE" ]]; then
      ensure_pg_readonly_secret || warn "Read-only login: no password secret yet; CNPG will retry once it exists"
      managed_block="
  # Read-only login (PG_READONLY_ROLE); session settings: ensure_pg_readonly_role
  managed:
    roles:
      - $(pg_readonly_role_json)
"
    fi
    # Continuous backup: the plugin archives WAL from the first segment on, so the
    # ScheduledBackup (immediate) has a complete archive to pair its first base backup with.
    local plugins_block=""
    if wal_archive_enabled; then
      plugins_block="
  # Continuous backup (PG_WAL_ARCHIVE=minio): WAL archive + base backups to ObjectStore
  # ${PG_BACKUP_OBJECTSTORE}; docs/POSTGRES-BACKUP.md
  plugins:
    - $(barman_plugin_json)
"
    fi
    # Bootstrap: an empty database (initdb), or - PG_RECOVER_FROM, a rebuilt node - the
    # cluster's own backups in the ObjectStore, replayed to the end of the archive or to
    # PG_RECOVER_TARGET_TIME. docs/POSTGRES-BACKUP.md, "Losing the node".
    local bootstrap_block
    if [[ -n "$PG_RECOVER_FROM" ]]; then
      info "Bootstrapping from backup: server ${PG_RECOVER_FROM} in ObjectStore ${PG_BACKUP_OBJECTSTORE}${PG_RECOVER_TARGET_TIME:+, target time ${PG_RECOVER_TARGET_TIME}}"
      bootstrap_block="  bootstrap:
    recovery:
      source: origin
      database: app
      owner: app${PG_RECOVER_TARGET_TIME:+
      recoveryTarget:
        targetTime: \"${PG_RECOVER_TARGET_TIME}\"}
  externalClusters:
    - name: origin
      plugin:
        name: ${BARMAN_PLUGIN_NAME}
        parameters:
          barmanObjectName: ${PG_BACKUP_OBJECTSTORE}
          serverName: ${PG_RECOVER_FROM}"
    else
      # CloudNativePG generates the superuser and app credentials (secrets
      # postgres-cluster-superuser and postgres-cluster-app); no pre-existing secret is
      # referenced, so nothing can fail to mount.
      bootstrap_block="  bootstrap:
    initdb:
      database: app
      owner: app"
    fi
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
${managed_block}${plugins_block}
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
    # SCRAM only (INFRA-65). CNPG appends "host all all all scram-sha-256" itself (PG >= 14);
    # these private-range lines spell the method out. "md5" here would also accept roles
    # whose stored password is still an MD5 hash (password_encryption is scram-sha-256 by
    # default since PG 14, so new passwords never are).
    pg_hba:
      - host all all 10.0.0.0/8 scram-sha-256
      - host all all 172.16.0.0/12 scram-sha-256
      - host all all 192.168.0.0/16 scram-sha-256

  # Bootstrap configuration
${bootstrap_block}

  # Backups: PG_WAL_ARCHIVE=minio adds spec.plugins above (Barman Cloud plugin). Not the
  # in-tree spec.backup.barmanObjectStore: deprecated, removed after CNPG 1.31.

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
ensure_pg_readonly_role
ensure_cluster_backup

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

  # pgweb is a connect-form console: it reads no connection settings from its environment
  # (PGWEB_HOST/USER/PASS are not pgweb settings), so whoever opens it types the host and a
  # login. Earlier versions put the superuser's credentials into pgweb-connection and the pod's
  # env anyway, where nothing used them; that copy is removed.
  kubectl -n "$NAMESPACE_POSTGRES" delete secret pgweb-connection --ignore-not-found=true >/dev/null

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
        image: sosedoff/pgweb:0.17.0@sha256:a5256d416e2e8b92d69a4459058e3eca33a9f075d8325491644411d0bc3bd70b
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8081
          name: http
        env:
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

  # pgweb has no login of its own: whoever reaches its port has a database console. Behind
  # Pomerium, only the Pomerium proxy may connect, so the admins-only route (Phase 6) is the
  # one way in; without Pomerium the direct ingress needs Traefik to reach it, so no policy.
  if [[ "${ENFORCE_POMERIUM}" == "true" ]]; then
    cat <<YAML | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: pgweb-from-pomerium-only
  namespace: ${NAMESPACE_POSTGRES}
spec:
  podSelector:
    matchLabels:
      app: pgweb
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${NAMESPACE_SSO}
          podSelector:
            matchLabels:
              app.kubernetes.io/name: pomerium
      ports:
        - port: 8081
          protocol: TCP
YAML
  else
    kubectl -n "$NAMESPACE_POSTGRES" delete networkpolicy pgweb-from-pomerium-only --ignore-not-found=true >/dev/null
  fi

  # Wait for pgweb to be ready
  info "Waiting for pgweb deployment to be ready..."
  kubectl -n "$NAMESPACE_POSTGRES" rollout status deployment/pgweb --timeout=300s || true

  info "✓ pgweb deployed (connect form; log in with a database role, e.g. --show-credentials)"
  [[ "${ENFORCE_POMERIUM}" == "true" ]] && info "  NetworkPolicy pgweb-from-pomerium-only: only Pomerium reaches it"
  return 0
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

  # pgweb opens every database a typed-in login can reach, so the route admits only
  # PGWEB_ALLOWED_GROUPS (Dex groups claim "<github-org>:<team>", comma-separated), by default
  # the org's admins team - not every org member.
  local groups="${PGWEB_ALLOWED_GROUPS:-}"
  if [[ -z "$groups" ]]; then
    local org
    if ! org=$(provision::git_org "$ENV_NAME" 2>/dev/null) || [[ -z "$org" || "$org" == "null" ]]; then
      warn "GitHub org unknown and PGWEB_ALLOWED_GROUPS unset - not registering the pgweb route"
      return 0
    fi
    groups="${org}:admins"
  fi

  if provision::pomerium_routes_add_for_groups "$from_url" "$to_url" "$groups" "${NAMESPACE_SSO}"; then
    info "✓ Pomerium route ensured: ${from_url} -> ${to_url} (groups: ${groups})"
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
if wal_archive_enabled; then
  info "  Backup:     WAL archive + ${PG_BACKUP_SCHEDULE} (UTC) base backups to s3://${PG_BACKUP_BUCKET}/ (MinIO), retention ${PG_BACKUP_RETENTION}"
else
  info "  Backup:     no continuous backup (PG_WAL_ARCHIVE unset); see docs/POSTGRES-BACKUP.md"
fi
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
