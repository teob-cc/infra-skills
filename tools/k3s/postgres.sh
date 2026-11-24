#!/usr/bin/env bash
set -euo pipefail
# No allexport: an inherited SHELLOPTS=allexport would put every secret into child environments.
set +a

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
#       --tenant <name>      ... for a tenant (docs/TENANTS.md): secret in the tenant namespace, stricter
#                            limits, no read-only role access, Pooler labelled for the tenant
#       --pooler             ... and a CNPG Pooler pooler-<app-id> (PgBouncer); the secret points at it
#       --connection-limit N ... role CONNECTION LIMIT (default PG_APP_CONNECTION_LIMIT, else 50; tenant 20).
#                            Per role: it counts the role's sessions across all its databases
#       --statement-timeout D  role statement_timeout (default PG_APP_STATEMENT_TIMEOUT; tenant 60s)
#       --database <name>[:<PREFIX>]  (repeatable) use these existing databases instead of creating
#                            <app-id>: the role gets CONNECT, schema USAGE/CREATE, table and sequence
#                            rights and default privileges on each (PUBLIC's CONNECT stays; a warning
#                            names the roles that rely on it);
#                            the Secret gets <PREFIX>_HOST/PORT/DATABASE/USERNAME/PASSWORD per
#                            database (POSTGRES_* when no prefix; at most one such database)
#       --revoke-public --keep-connect <role>[,<role>]|none  ... and revoke PUBLIC's CONNECT and
#                            TEMPORARY on them; the owner, the former owner, these roles,
#                            PG_READONLY_ROLE and the pooler role get CONNECT first
#       --take-ownership     ... move each database to the role (or to the migration role) instead:
#                            the old owner's objects in it one by one, then the database, in one
#                            transaction (never its other databases or tablespaces), checked; an
#                            interrupted move is completed by the next run; refused when that owner is
#                            a superuser or the owner was changed by hand since the move started
#       --create-missing     ... create a named database that does not exist (else: an error); a
#                            creation an earlier run did not finish is finished
#       --migration-role [name]  a second login role (default <app-id>_migrate) for migrate Jobs: no
#                            statement_timeout, its own small connection limit, the app role's rights
#                            on the named databases (no membership), Secret <app-id>-db-migrate with
#                            the same keys; the app role gets rights on what it creates through
#                            default privileges
#       --migration-schema <db>.<schema>  (repeatable) a schema the migration role owns (created
#                            if missing); it gets CREATE on <db>
#       --migration-connection-limit N  its CONNECTION LIMIT (default PG_MIGRATION_CONNECTION_LIMIT, else 2)
#       --keep-password      keep the passwords in secrets.plain/<app-id>-db[-migrate].secret.yaml: an
#                            existing role's password is not touched (the stored one must match its
#                            verifier in the cluster), a missing role is created with it (stops when a
#                            file has none, or its *_PASSWORD values differ)
#                            Passwords reach the server only as SCRAM-SHA-256 verifiers (pg-scram.pl)
#                            Existing roles are reused only when this script made them for this app
#                            (COMMENT ON ROLE marker); reserved, pg_* and privileged roles are refused
#   --revoke-public-connect [--apply]  List (or, with --apply, revoke) CONNECT and TEMPORARY that
#                            PUBLIC still holds on application databases; owners, the read-only role
#                            and the pooler role get explicit grants first
#   --dump-table <table>     Dump a specific table (use --database to specify database, --output to specify file)
#   --database <dbname>      Database name for dump-table (default: app; see also --provision-credentials)
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
PG_TENANT=""
PG_POOLER=false
PG_CONN_LIMIT=""
PG_STATEMENT_TIMEOUT=""
PG_DATABASES=()
PG_MIGRATION_ROLE=false
PG_MIGRATION_ROLE_NAME=""
PG_MIGRATION_CONN_LIMIT=""
PG_TAKE_OWNERSHIP=false
PG_CREATE_MISSING=false
PG_KEEP_PASSWORD=false
PG_MIGRATION_SCHEMAS=()
PG_REVOKE_PUBLIC=false
PG_KEEP_CONNECT=""
REVOKE_PUBLIC_CONNECT=false
REVOKE_PUBLIC_APPLY=false
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
    --tenant) PG_TENANT="${2:?--tenant needs a tenant name}"; shift 2 ;;
    --pooler) PG_POOLER=true; shift ;;
    --connection-limit) PG_CONN_LIMIT="${2:?--connection-limit needs a number}"; shift 2 ;;
    --statement-timeout) PG_STATEMENT_TIMEOUT="${2:?--statement-timeout needs a duration, e.g. 60s}"; shift 2 ;;
    --migration-role)
      PG_MIGRATION_ROLE=true
      if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
        PG_MIGRATION_ROLE_NAME="$2"
        shift 2
      else
        shift
      fi
      ;;
    --migration-connection-limit) PG_MIGRATION_CONN_LIMIT="${2:?--migration-connection-limit needs a number}"; shift 2 ;;
    --take-ownership) PG_TAKE_OWNERSHIP=true; shift ;;
    --create-missing) PG_CREATE_MISSING=true; shift ;;
    --keep-password) PG_KEEP_PASSWORD=true; shift ;;
    --migration-schema) PG_MIGRATION_SCHEMAS+=("${2:?--migration-schema needs <database>.<schema>}"); shift 2 ;;
    --revoke-public) PG_REVOKE_PUBLIC=true; shift ;;
    --keep-connect) PG_KEEP_CONNECT="${2:?--keep-connect needs <role>[,<role>] or none}"; shift 2 ;;
    --revoke-public-connect) REVOKE_PUBLIC_CONNECT=true; shift ;;
    --apply) REVOKE_PUBLIC_APPLY=true; shift ;;
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
      # --dump-table reads one (the last); --provision-credentials takes each as <name>[:<PREFIX>]
      DUMP_DATABASE="$2"
      PG_DATABASES+=("$2")
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
if [[ "$PROVISION_CREDENTIALS" != "true" ]] && \
   [[ "$PG_MIGRATION_ROLE" == "true" || -n "$PG_MIGRATION_CONN_LIMIT" || "$PG_TAKE_OWNERSHIP" == "true" || "$PG_CREATE_MISSING" == "true" || "$PG_KEEP_PASSWORD" == "true" || ${#PG_MIGRATION_SCHEMAS[@]} -gt 0 || "$PG_REVOKE_PUBLIC" == "true" || -n "$PG_KEEP_CONNECT" ]]; then
  echo "ERROR: --migration-role, --migration-connection-limit, --take-ownership, --create-missing, --keep-password, --migration-schema, --revoke-public and --keep-connect go with --provision-credentials" >&2
  exit 1
fi
if [[ "$PROVISION_CREDENTIALS" == "true" && ${#PG_DATABASES[@]} -eq 0 ]] && \
   [[ "$PG_TAKE_OWNERSHIP" == "true" || "$PG_CREATE_MISSING" == "true" || "$PG_REVOKE_PUBLIC" == "true" ]]; then
  echo "ERROR: --take-ownership, --create-missing and --revoke-public go with --database <name>[:<PREFIX>]" >&2
  exit 1
fi
if [[ -n "$PG_MIGRATION_CONN_LIMIT" && "$PG_MIGRATION_ROLE" != "true" ]]; then
  echo "ERROR: --migration-connection-limit goes with --migration-role" >&2
  exit 1
fi
if [[ ${#PG_MIGRATION_SCHEMAS[@]} -gt 0 && "$PG_MIGRATION_ROLE" != "true" ]]; then
  echo "ERROR: --migration-schema goes with --migration-role" >&2
  exit 1
fi
if [[ "$PG_REVOKE_PUBLIC" == "true" && -z "$PG_KEEP_CONNECT" ]]; then
  echo "ERROR: --revoke-public needs --keep-connect <role>[,<role>] (or --keep-connect none): the roles besides the owner that keep CONNECT" >&2
  exit 1
fi
if [[ -n "$PG_KEEP_CONNECT" && "$PG_REVOKE_PUBLIC" != "true" ]]; then
  echo "ERROR: --keep-connect goes with --revoke-public" >&2
  exit 1
fi

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
# postgres-cluster resources and memory parameters, applied only when the cluster is
# created (a running cluster is never changed; live-patch it and record the values in
# envs/<env>/env.properties). Defaults are the small-node profile; an env whose
# cluster holds a large event journal overrides them.
: "${POSTGRES_CPU_REQUEST:=500m}"
: "${POSTGRES_MEMORY_REQUEST:=1Gi}"
: "${POSTGRES_CPU_LIMIT:=2}"
: "${POSTGRES_MEMORY_LIMIT:=2Gi}"
: "${POSTGRES_SHARED_BUFFERS:=256MB}"
: "${POSTGRES_EFFECTIVE_CACHE_SIZE:=512MB}"
: "${POSTGRES_MAINTENANCE_WORK_MEM:=64MB}"
: "${POSTGRES_MAX_WAL_SIZE:=4GB}"
: "${POSTGRES_MAX_CONNECTIONS:=100}"
# wal_compression: lz4 (or zstd) compresses full-page images in WAL, which shrinks the WAL
# archive of a write-heavy journal by a large share for little CPU. A reload applies it, no restart.
: "${POSTGRES_WAL_COMPRESSION:=off}"
# checkpoint_timeout: time between checkpoints. A table whose few rows are rewritten all day gets
# its hot pages flushed at every checkpoint, so 30min writes them a sixth as often as 5min, for a
# longer crash recovery (up to that much WAL to replay). A reload applies it, no restart.
: "${POSTGRES_CHECKPOINT_TIMEOUT:=5min}"
# log_temp_files: log every temporary file of at least this many kB (0 = all, -1 = off), to find
# the queries whose sorts spill past work_mem. A reload applies it, no restart.
: "${POSTGRES_LOG_TEMP_FILES:=-1}"
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
# Plaintext passwords never reach the server, argv or a trace. They are made and read with
# xtrace off (provision::without_xtrace), and only the Secret file gets them, written by a
# function that gets the variable's name rather than its value. The server gets a SCRAM-SHA-256
# verifier computed here (tools/k3s/pg-scram.pl, core Perl), on stdin: ALTER ROLE ... PASSWORD
# 'SCRAM-SHA-256$4096:...' is stored as is, so no server log setting (log_statement, duration
# or sampled logging, error statements) can show a password. The password statement still runs
# with log_statement = none, and on the --database and migration paths also with
# log_min_error_statement = panic and log_min_duration_statement = -1; numbers are range-checked
# here first so the server has nothing to reject.
#
# Roles: the script reuses an existing role only when it made the role for this app. COMMENT ON
# ROLE holds the marker infra-skills:app:<app-id> (app role) or infra-skills:migrate:<app-id>
# (migration role); an unmarked app role is adopted only when it has LOGIN, owns the database
# <app-id> (made by the default path before the marker), has no elevated attribute and no role
# membership at all, in either direction. Reserved and pg_* names are refused, and so are roles
# that are superusers, hold CREATEROLE, CREATEDB, REPLICATION or BYPASSRLS, belong to a role that
# does, or are members of one another (app and migration role, by any path). The same preflight
# runs on every path, the plain default one included, and each role's marker and password are
# then written in one transaction that locks the role catalogs and checks all of it again first
# (pg_sql_role_tx).

PG_ROLE_MARKER="infra-skills"
PG_INT_MAX=2147483647
PG_US=$'\x1f'   # field separator of the preflight rows (psql -F)
PG_SCRAM="$REPO_ROOT/tools/k3s/pg-scram.pl"
# shellcheck disable=SC2016  # a regex: the $ are literal
PG_VERIFIER_RE='^SCRAM-SHA-256\$4096:[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+$'

# pg_reserved_role <name>: true for a name this script never provisions or adopts.
pg_reserved_role() {
  case "$1" in
    postgres|app|streaming_replica|cnpg_pooler_pgbouncer|public|none|all|user|current_user|current_role|session_user|pg_*) return 0 ;;
  esac
  [[ -n "${PG_READONLY_ROLE:-}" && "$1" == "$PG_READONLY_ROLE" ]]
}

# pg_int_between <value> <min> <max>: an integer (at most 10 digits) in [min, max].
pg_int_between() {
  [[ "$1" =~ ^-?[0-9]{1,10}$ ]] || return 1
  local v=$((10#${1#-}))
  [[ "$1" == -* ]] && v=$((-v))
  (( v >= $2 && v <= $3 ))
}

# pg_duration_ok <value>: a Postgres duration (ms, s, min, h; bare = ms) that fits in an int of ms.
pg_duration_ok() {
  [[ "$1" =~ ^([0-9]{1,10})(ms|s|min|h)?$ ]] || return 1
  local n=$((10#${BASH_REMATCH[1]})) mult=1
  case "${BASH_REMATCH[2]}" in s) mult=1000 ;; min) mult=60000 ;; h) mult=3600000 ;; esac
  (( n * mult <= PG_INT_MAX ))
}

# pg_new_password <var>: a new random password into <var>; fails when openssl fails or prints
# fewer than 24 characters. Call it through provision::without_xtrace.
# shellcheck disable=SC2329  # invoked through provision::without_xtrace
pg_new_password() {
  local +x _pw
  _pw=$(openssl rand -base64 24 | tr -d '\n') || return 1
  [[ ${#_pw} -ge 24 ]] || return 1
  printf -v "$1" '%s' "$_pw"
}

# pg_make_verifier <password var> <verifier var>: the SCRAM-SHA-256 verifier of the password (a
# new random salt, 4096 iterations). Call it through provision::without_xtrace.
# shellcheck disable=SC2329  # invoked through provision::without_xtrace
pg_make_verifier() {
  local +x _v
  _v=$(printf '%s\n' "${!1}" | perl "$PG_SCRAM" make) || return 1
  [[ "$_v" =~ $PG_VERIFIER_RE ]] || return 1
  printf -v "$2" '%s' "$_v"
}

# pg_matches_live <password var> <role>: true when the password matches the role's verifier in
# the cluster (pg_authid.rolpassword, read over the pod's socket; SCRAM with its own salt and
# iterations, or md5). Uses the caller's namespace, pg_pod and superuser. Call it through
# provision::without_xtrace.
# shellcheck disable=SC2329  # invoked through provision::without_xtrace
pg_matches_live() {
  local +x _live
  _live=$(kubectl -n "$namespace" exec -i "$pg_pod" -c postgres -- psql -U "$superuser" -d postgres -v ON_ERROR_STOP=1 -q -tA <<SQL
-- infra-skills:verifier
\\set r '$2'
SELECT coalesce(rolpassword, '') FROM pg_authid WHERE rolname = :'r';
SQL
) || return 1
  printf '%s\n%s\n' "${!1}" "$_live" | perl "$PG_SCRAM" check "$2"
}

# pg_stored_password <var> <secret file> <role>: the *_PASSWORD value the Secret file holds, into
# <var> (empty when the file or the key is missing). Returns 3 when the file's *_PASSWORD values
# differ and 4 when a *_USERNAME names another role. Call it through provision::without_xtrace.
# shellcheck disable=SC2329  # invoked through provision::without_xtrace
pg_stored_password() {
  local +x _pws="" _users=""
  printf -v "$1" '%s' ""
  [[ -f "$2" ]] || return 0
  _pws=$(yq -r '[(.stringData // {}) | to_entries | .[] | select(.key | test("_PASSWORD$")) | .value | tostring] | unique | .[]' "$2" 2>/dev/null) || return 2
  _users=$(yq -r '[(.stringData // {}) | to_entries | .[] | select(.key | test("_USERNAME$")) | .value | tostring] | unique | .[]' "$2" 2>/dev/null) || return 2
  [[ "$_pws" != *$'\n'* ]] || return 3
  [[ -z "$_users" || "$_users" == "$3" ]] || return 4
  printf -v "$1" '%s' "$_pws"
}

# pg_password_usable <var>: at least 24 characters that can go into the Secret as they are.
# shellcheck disable=SC2329  # invoked through provision::without_xtrace
pg_password_usable() { [[ "${!1}" =~ ^[A-Za-z0-9+/=._~-]{24,}$ ]]; }

# pg_password <var> <secret file> <role> <role exists: t|f> <set var> <verifier var>: the
# password into <var>, into <set var> whether the run sets it (true) or leaves the role's
# password alone (false), and when it sets it, its SCRAM verifier into <verifier var>.
#   default          a new password, set on the role;
#   --keep-password  the password the file holds (every *_PASSWORD in it must agree). A role that
#                    exists keeps its password untouched, and the stored one must match it (else
#                    the run stops and the Secret stays as it is); a missing role is created with it.
pg_password() {
  local var="$1" file="$2" role="$3" exists="$4" setvar="$5" vvar="$6" rc=0
  if [[ "$PG_KEEP_PASSWORD" == "true" ]]; then
    provision::without_xtrace pg_stored_password "$var" "$file" "$role" || rc=$?
    case "$rc" in
      0) ;;
      3) err "--keep-password: ${file} holds different *_PASSWORD values for role ${role}; they must all agree"; exit 1 ;;
      4) err "--keep-password: ${file} names another *_USERNAME than ${role}"; exit 1 ;;
      *) err "--keep-password: cannot read ${file}"; exit 1 ;;
    esac
    if ! provision::without_xtrace pg_password_usable "$var"; then
      err "--keep-password: ${file} holds no usable *_PASSWORD for role ${role} (24 or more of A-Z a-z 0-9 + / = . _ ~ -)."
      err "  Decrypt it first (tools/sops/decrypt.sh ${ENV_NAME}), or leave --keep-password out to set a new password."
      exit 1
    fi
    if [[ "$exists" == "t" ]]; then
      if ! provision::without_xtrace pg_matches_live "$var" "$role"; then
        err "--keep-password: the password in ${file##*/} is not role ${role}'s password in the cluster (stale Secret?)."
        err "  Nothing changed and the Secret is left as it is. Decrypt the current one from secrets.sops, or leave --keep-password out to set a new password."
        exit 1
      fi
      printf -v "$setvar" '%s' false
      info "Keeping the password of role ${role}: it matches the role's verifier, and is not touched (${file##*/})"
      return 0
    fi
    printf -v "$setvar" '%s' true
    info "Role ${role} does not exist yet: it is created with the password from ${file##*/}"
  else
    if ! provision::without_xtrace pg_new_password "$var"; then
      err "Could not make a password for role ${role}: openssl rand failed or printed fewer than 24 characters"
      exit 1
    fi
    printf -v "$setvar" '%s' true
  fi
  if ! provision::without_xtrace pg_make_verifier "$var" "$vvar"; then
    err "Could not compute the SCRAM verifier for role ${role} (perl ${PG_SCRAM##*/} failed)"
    exit 1
  fi
}


# pg_write_secret <file> <secret> <namespace> <host> <port> <username> <password var> <host note>
#                 <legacy: true|false> <db:PREFIX>...
# legacy (the default path): the Secret exactly as before INFRA-243, POSTGRES_* for one database.
# Otherwise <PREFIX>_HOST/PORT/DATABASE/USERNAME/PASSWORD for each database, values quoted. Call
# it through provision::without_xtrace: printf would trace the password.
# shellcheck disable=SC2329  # invoked through provision::without_xtrace
pg_write_secret() {
  local file="$1" name="$2" ns="$3" host="$4" port="$5" user="$6" pw_var="$7" note="$8" legacy="$9"; shift 9
  local entry db prefix sep=""
  (umask 077
   {
     printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\nstringData:\n' "$name" "$ns"
     if [[ "$legacy" == "true" ]]; then
       db="${1%%:*}"
       printf '  # PostgreSQL host%s\n  POSTGRES_HOST: %s\n\n' "$note" "$host"
       printf '  # PostgreSQL port\n  POSTGRES_PORT: "%s"\n\n' "$port"
       printf '  # PostgreSQL database name\n  POSTGRES_DATABASE: %s\n\n' "$db"
       printf '  # PostgreSQL username\n  POSTGRES_USERNAME: %s\n\n' "$user"
       printf '  # PostgreSQL password\n  POSTGRES_PASSWORD: %s\n' "${!pw_var}"
     else
       for entry in "$@"; do
         db="${entry%%:*}"; prefix="${entry#*:}"
         printf '%s' "$sep"; sep=$'\n'
         if [[ $# -gt 1 ]]; then printf '  # Database %s\n' "$db"; fi
         printf '  # PostgreSQL host%s\n  %s_HOST: "%s"\n\n' "$note" "$prefix" "$host"
         printf '  # PostgreSQL port\n  %s_PORT: "%s"\n\n' "$prefix" "$port"
         printf '  # PostgreSQL database name\n  %s_DATABASE: "%s"\n\n' "$prefix" "$db"
         printf '  # PostgreSQL username\n  %s_USERNAME: "%s"\n\n' "$prefix" "$user"
         printf '  # PostgreSQL password\n  %s_PASSWORD: "%s"\n' "$prefix" "${!pw_var}"
       done
     fi
   } > "$file")
}

# pg_sql_role_guard <role> <kind: app|migrate> <oid the preflight saw, '' = no such role> <the
# other role of this run, or ''>: inside the caller's transaction, lock the role catalogs
# (pg_authid, pg_auth_members: no role can be created, altered or granted until it commits),
# pg_database (no ALTER DATABASE OWNER: an adopted role keeps owning its database) and
# pg_shdescription (no COMMENT ON ROLE: the marker stays as checked), all SHARE ROW EXCLUSIVE,
# waiting at most 5 s; logins only read them and are not held off. Then check again what the
# preflight checked; any change raises and rolls the transaction back,
# before the role's marker or password is written. Names are validated (a closed character set),
# the oid is digits. Prints SQL.
pg_sql_role_guard() {
  cat <<SQL
SET LOCAL lock_timeout = '5s';
LOCK TABLE pg_catalog.pg_authid IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE pg_catalog.pg_auth_members IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE pg_catalog.pg_database IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE pg_catalog.pg_shdescription IN SHARE ROW EXCLUSIVE MODE;
SELECT set_config('infra_skills.g_role', '$1', true) AS g_role, set_config('infra_skills.g_kind', '$2', true) AS g_kind,
       set_config('infra_skills.g_oid', '$3', true) AS g_oid, set_config('infra_skills.g_other', '$4', true) AS g_other,
       set_config('infra_skills.g_marker', '${PG_ROLE_MARKER}:$2:${app_id}', true) AS g_marker \\gset
SQL
  cat <<'SQL'
DO $$
DECLARE
  nm text := current_setting('infra_skills.g_role');
  kind text := current_setting('infra_skills.g_kind');
  want text := current_setting('infra_skills.g_oid');
  other text := current_setting('infra_skills.g_other');
  mk text := current_setting('infra_skills.g_marker');
  r record;
  c text;
BEGIN
  SELECT oid, rolcanlogin, (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls) AS elevated
    INTO r FROM pg_roles WHERE rolname = nm;
  IF NOT FOUND THEN
    IF want <> '' THEN RAISE EXCEPTION 'infra-skills: role % was dropped after the preflight; nothing changed', nm; END IF;
    RETURN;
  END IF;
  IF want = '' THEN RAISE EXCEPTION 'infra-skills: role % was made by someone else after the preflight; nothing changed', nm; END IF;
  IF r.oid::text <> want THEN RAISE EXCEPTION 'infra-skills: role % was dropped and made again after the preflight; nothing changed', nm; END IF;
  IF r.elevated THEN
    RAISE EXCEPTION 'infra-skills: role % gained SUPERUSER, CREATEROLE, CREATEDB, REPLICATION or BYPASSRLS after the preflight; nothing changed', nm;
  END IF;
  IF EXISTS (SELECT FROM pg_roles g WHERE g.oid <> r.oid AND pg_has_role(r.oid, g.oid, 'MEMBER')
               AND (g.rolname ~ '^pg_' OR g.rolsuper OR g.rolcreaterole OR g.rolcreatedb OR g.rolreplication OR g.rolbypassrls)) THEN
    RAISE EXCEPTION 'infra-skills: role % joined a privileged or pg_* role after the preflight; nothing changed', nm;
  END IF;
  IF other <> '' AND EXISTS (SELECT FROM pg_roles o WHERE o.rolname = other
                               AND (pg_has_role(r.oid, o.oid, 'MEMBER') OR pg_has_role(o.oid, r.oid, 'MEMBER'))) THEN
    RAISE EXCEPTION 'infra-skills: roles % and % are members of one another (directly or through a group); nothing changed', nm, other;
  END IF;
  c := shobj_description(r.oid, 'pg_authid');
  IF c IS NOT DISTINCT FROM mk THEN RETURN; END IF;
  IF kind = 'app' AND c IS NULL AND r.rolcanlogin
     AND EXISTS (SELECT FROM pg_database d WHERE d.datname = nm AND d.datdba = r.oid)
     AND NOT EXISTS (SELECT FROM pg_auth_members m WHERE m.member = r.oid OR m.roleid = r.oid) THEN
    RETURN;
  END IF;
  RAISE EXCEPTION 'infra-skills: role % changed after the preflight (marker, LOGIN, owner of its database or memberships); nothing changed', nm;
END
$$;
SQL
}

# pg_sql_role_tx <psql variable holding the role> <kind: app|migrate> <oid the preflight saw>
# <the other role or ''> <password set: true|false> <name of the bash variable with the SCRAM
# verifier> <connection limit> <guarded logging: true|false>: one transaction that runs the guard
# (pg_sql_role_guard), creates the role if missing, writes its marker and its password (or only
# LOGIN and the limit). Guarded logging (the --database and migration paths): psql's errors terse,
# and the password statement with log_min_error_statement = panic and log_min_duration_statement
# = -1 as well as log_statement = none. The default path keeps origin/main's lines (log_statement
# = none) around its own \set pw. [own transaction: true|false] false: no BEGIN/COMMIT, inside the
# caller's transaction (the late passwords of both roles: both or neither). Prints SQL.
pg_sql_role_tx() {
  local v="$1" kind="$2" oid="$3" other="$4" pw_set="$5" vvar="$6" limit="$7" guarded="$8" own_tx="${9:-true}" name marker
  name="$app_username"; [[ "$kind" == migrate ]] && name="$mig_role"
  marker="${PG_ROLE_MARKER}:${kind}:${app_id}"
  if [[ "$guarded" == "true" && "$pw_set" == "true" ]]; then
    # a heredoc: bash -x does not trace its expansion (printf's arguments it would)
    cat <<SQL
\\set pw '${!vvar}'
\\set VERBOSITY terse
SQL
  fi
  [[ "$own_tx" == "true" ]] && echo 'BEGIN;'
  pg_sql_role_guard "$name" "$kind" "$oid" "$other"
  cat <<SQL
SELECT format('CREATE ROLE %I LOGIN', :'$v') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'$v') \\gexec
SQL
  if [[ "$guarded" == "true" ]]; then
    printf '\\set marker %s\n' "'${marker}'"
    cat <<SQL
SELECT format('COMMENT ON ROLE %I IS %L', :'$v', :'marker')
 WHERE shobj_description((SELECT oid FROM pg_roles WHERE rolname = :'$v'), 'pg_authid') IS DISTINCT FROM :'marker' \\gexec
SQL
  else
    cat <<SQL
SELECT format('COMMENT ON ROLE %I IS %L', :'$v', '${marker}') WHERE shobj_description((SELECT oid FROM pg_roles WHERE rolname = :'$v'), 'pg_authid') IS DISTINCT FROM '${marker}' \\gexec
SQL
  fi
  if [[ "$pw_set" == "true" ]]; then
    echo "SET LOCAL log_statement = 'none';"
    if [[ "$guarded" == "true" ]]; then
      printf "SET LOCAL log_min_error_statement = 'panic';\nSET LOCAL log_min_duration_statement = -1;\n"
    fi
    printf 'ALTER ROLE :"%s" WITH LOGIN PASSWORD :'"'"'pw'"'"' CONNECTION LIMIT %s;\n' "$v" "$limit"
  else
    printf 'ALTER ROLE :"%s" WITH LOGIN CONNECTION LIMIT %s;\n' "$v" "$limit"
  fi
  if [[ "$guarded" == "true" ]]; then
    # The role's oid as guarded (the catalogs are still locked): :app_goid / :migrate_goid, the
    # identity a later ledger row and ownership move are bound to.
    printf 'SELECT oid AS %s_goid FROM pg_roles WHERE rolname = :'"'"'%s'"'"' \\gset\n' "$kind" "$v"
  fi
  [[ "$own_tx" == "true" ]] && echo 'COMMIT;'
  if [[ "$guarded" == "true" && "$pw_set" == "true" ]]; then
    printf '\\unset pw\n\\set VERBOSITY default\n'
  fi
}

# The SQL below uses the caller's variables (provision_credentials). Values spliced into it are
# validated names and numbers (a closed character set); every name read from the server stays on
# the server and is quoted there with format('%I').

# The default path's session, as before INFRA-243 byte for byte when $1 is true, except that the
# password goes to the server as its SCRAM verifier (\set pw), and that CREATE ROLE, the role's
# marker (COMMENT ON ROLE) and the password statement run in one transaction behind the role
# guard (pg_sql_role_guard: the preflight's checks again, under a lock). $1 false
# (--keep-password, the role exists): no password is sent and the role's password stays.
pg_sql_default_app() {
  cat <<SQL
\\set role '${app_username}'
\\set db '${app_database}'
SQL
  if [[ "$1" == "true" ]]; then
    cat <<SQL
\\set pw '${app_verifier}'
SQL
  fi
  cat <<SQL
\\set ro '${ro_role}'
SQL
  pg_sql_role_tx role app "$app_oid" "$mig_role" "$1" app_verifier "$conn_limit" false
  cat <<SQL
SELECT format('ALTER ROLE %I SET statement_timeout = %L', :'role', '${statement_timeout}') WHERE '${statement_timeout}' <> '' \\gexec
SELECT format('ALTER ROLE %I SET idle_in_transaction_session_timeout = %L', :'role', '${idle_tx_timeout}') WHERE '${idle_tx_timeout}' <> '' \\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \\gexec
REVOKE CONNECT, TEMPORARY ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"db" TO :"role";
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db', :'ro') WHERE :'ro' <> '' AND EXISTS (SELECT FROM pg_roles WHERE rolname = :'ro') \\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO cnpg_pooler_pgbouncer', :'db') WHERE EXISTS (SELECT FROM pg_roles WHERE rolname = 'cnpg_pooler_pgbouncer') \\gexec
SELECT 'WARN role ' || rolname || ' has ' || concat_ws(', ', CASE WHEN rolsuper THEN 'SUPERUSER' END, CASE WHEN rolcreaterole THEN 'CREATEROLE' END,
       CASE WHEN rolcreatedb THEN 'CREATEDB' END, CASE WHEN rolreplication THEN 'REPLICATION' END, CASE WHEN rolbypassrls THEN 'BYPASSRLS' END)
  FROM pg_roles WHERE rolname = :'role' AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls);
\\c :"db"
GRANT CREATE ON SCHEMA public TO :"role";
SQL
}

# The preflight: one read of the catalog before anything changes (it writes nothing). Rows
# (fields split by \x1f, names with control characters replaced by '?'):
#   role <kind> <name> <exists> <marker ok> <comment> <attributes> <privileged memberships> <owns
#        database <name>> <oid> <LOGIN> <any membership, either direction> <member of the other
#        role of this run, or it of this one, by any path>
#   need <role> <exists>
#   ledger <schema owner ok> <tables' owner and kind ok> <columns ok>   (--take-ownership, --revoke-public, --create-missing)
#   intent <database> <it is this app's> <bound: this app's, and it names this database: by the oid
#          it recorded, or, before that, by the marker of that one creation (COMMENT ON DATABASE
#          infra-skills:created:<app-id>:<nonce>)> <its app>   (--create-missing: a pending intent)
#   db <name> <exists> <owner> <owner is the new owner> <transfer pending> <old owner> <old owner is
#      the new owner> <old owner privileged> <PUBLIC has CONNECT> <roles connected now only
#      through PUBLIC> <login roles relying on PUBLIC> <pending transfer's destination> <that
#      destination is the new owner> <the owner is the pending transfer's source or destination>
#      <the owner's oid> <the database's oid> <the move's source oid (the pending row's, else the owner)>
# The ledger (postgres database, schema infra_skills, no PUBLIC access; the main session makes it
# once the preflight has passed): ownership_transfer holds, per database oid, the original owner
# and the destination role of an ownership move (an interrupted move is completed by the next run
# with the same destination; a run with another destination is refused); create_intent holds
# each database --create-missing is about to create, until its ACL is done.
pg_sql_preflight() {
  cat <<SQL
-- infra-skills:preflight
\\set app_role '${app_username}'
\\set mig_role '${mig_role}'
\\set app_marker '${PG_ROLE_MARKER}:app:${app_id}'
\\set mig_marker '${PG_ROLE_MARKER}:migrate:${app_id}'
\\set targets '${target_names[*]}'
\\set owner '${new_owner}'
\\set excluded '${pub_excluded}'
\\set need '${need_roles}'
SET client_min_messages = warning;
SQL
  cat <<'SQL'
SELECT 'role', k.kind, k.name, (r.oid IS NOT NULL),
       coalesce(shobj_description(r.oid, 'pg_authid') = k.marker, false),
       coalesce(regexp_replace(shobj_description(r.oid, 'pg_authid'), '[[:cntrl:]]', '?', 'g'), ''),
       coalesce(concat_ws(',', CASE WHEN r.rolsuper THEN 'SUPERUSER' END, CASE WHEN r.rolcreaterole THEN 'CREATEROLE' END,
                CASE WHEN r.rolcreatedb THEN 'CREATEDB' END, CASE WHEN r.rolreplication THEN 'REPLICATION' END,
                CASE WHEN r.rolbypassrls THEN 'BYPASSRLS' END), ''),
       coalesce((SELECT string_agg(regexp_replace(g.rolname, '[[:cntrl:]]', '?', 'g'), ',' ORDER BY g.rolname)
                   FROM pg_roles g WHERE g.oid <> r.oid AND pg_has_role(r.oid, g.oid, 'MEMBER')
                    AND (g.rolname ~ '^pg_' OR g.rolsuper OR g.rolcreaterole OR g.rolcreatedb OR g.rolreplication OR g.rolbypassrls)), ''),
       coalesce(k.kind = 'app' AND EXISTS (SELECT FROM pg_database d WHERE d.datname = k.name AND d.datdba = r.oid), false),
       coalesce(r.oid::text, ''), coalesce(r.rolcanlogin, false),
       coalesce((SELECT string_agg(CASE WHEN m.member = r.oid THEN 'member of ' ELSE 'has member ' END
                                   || regexp_replace(g.rolname, '[[:cntrl:]]', '?', 'g'), ', ' ORDER BY g.rolname)
                   FROM pg_auth_members m JOIN pg_roles g ON g.oid = CASE WHEN m.member = r.oid THEN m.roleid ELSE m.member END
                  WHERE m.member = r.oid OR m.roleid = r.oid), ''),
       coalesce((SELECT pg_has_role(r.oid, o.oid, 'MEMBER') OR pg_has_role(o.oid, r.oid, 'MEMBER') FROM pg_roles o WHERE o.rolname = k.other), false)
  FROM (VALUES (1, 'app', :'app_role', :'app_marker', :'mig_role'), (2, 'migrate', :'mig_role', :'mig_marker', :'app_role')) k(ord, kind, name, marker, other)
  LEFT JOIN pg_roles r ON r.rolname = k.name
 WHERE k.name <> ''
 ORDER BY k.ord;
SELECT 'need', k, EXISTS (SELECT FROM pg_roles WHERE rolname = k) FROM unnest(string_to_array(:'need', ',')) k WHERE k <> '';
SQL
  local dummy="(SELECT NULL::oid AS datoid, NULL::name AS datname, NULL::oid AS from_role, NULL::oid AS to_role, NULL::timestamptz AS done_at WHERE false)"
  [[ "$pg_ledger" == "true" ]] || { [[ "$existing_mode" == "true" ]] && pg_sql_preflight_db "$dummy"; return 0; }
  # Trust first, from the catalogs only (pg_namespace, pg_class, pg_attribute): the ledger
  # itself is not read here.
  cat <<'SQL'
SELECT to_regclass('infra_skills.ownership_transfer') IS NOT NULL AS l_exists,
       to_regclass('infra_skills.create_intent') IS NOT NULL AS i_exists,
       coalesce((SELECT n.nspowner = (SELECT oid FROM pg_roles WHERE rolname = current_user) FROM pg_namespace n WHERE n.nspname = 'infra_skills'), true) AS l_schema_ok,
       NOT EXISTS (SELECT FROM pg_class c
                    WHERE c.oid IN (to_regclass('infra_skills.ownership_transfer'), to_regclass('infra_skills.create_intent'))
                      AND NOT (c.relowner = (SELECT oid FROM pg_roles WHERE rolname = current_user) AND c.relkind = 'r')) AS l_table_ok,
       (to_regclass('infra_skills.ownership_transfer') IS NULL
         OR (SELECT count(*) = 6 AND count(*) FILTER (WHERE attname IN ('datoid', 'datname', 'from_role', 'to_role', 'started_at', 'done_at')) = 6
               FROM pg_attribute WHERE attrelid = to_regclass('infra_skills.ownership_transfer') AND attnum > 0 AND NOT attisdropped))
       AND (to_regclass('infra_skills.create_intent') IS NULL
         OR (SELECT count(*) = 7 AND count(*) FILTER (WHERE attname IN ('datname', 'app', 'revoke_public', 'started_at', 'done_at', 'datoid', 'nonce')) = 7
               FROM pg_attribute WHERE attrelid = to_regclass('infra_skills.create_intent') AND attnum > 0 AND NOT attisdropped)) AS l_cols_ok \gset
SELECT 'ledger', :'l_schema_ok', :'l_table_ok', :'l_cols_ok';
SELECT (:'l_schema_ok'::boolean AND :'l_table_ok'::boolean AND :'l_cols_ok'::boolean) AS l_trusted \gset
SQL
  [[ "$existing_mode" == "true" ]] || return 0
  # Only --create-missing reads create_intent, and only --take-ownership ownership_transfer; each
  # only once the checks above passed.
  if [[ "$PG_CREATE_MISSING" == "true" ]]; then
    printf '\\set app_id %s\n' "'${app_id}'"
    # A pending intent is bound to its database by the oid it recorded right after CREATE DATABASE;
    # before that oid is recorded, only by the marker of that one creation (its nonce).
    cat <<'SQL'
SELECT (:'l_trusted'::boolean AND :'i_exists'::boolean) AS use_intent \gset
\if :use_intent
SELECT 'intent', i.datname, (i.app = :'app_id'),
       coalesce(i.app = :'app_id' AND CASE WHEN i.datoid IS NOT NULL THEN i.datoid = d.oid
                                           ELSE shobj_description(d.oid, 'pg_database') = 'infra-skills:created:' || i.app || ':' || i.nonce END, false),
       regexp_replace(i.app, '[[:cntrl:]]', '?', 'g')
  FROM infra_skills.create_intent i LEFT JOIN pg_database d ON d.datname = i.datname
 WHERE i.done_at IS NULL AND i.datname = ANY (string_to_array(:'targets', ' '));
\endif
SQL
  fi
  if [[ "$PG_TAKE_OWNERSHIP" != "true" ]]; then
    pg_sql_preflight_db "$dummy"
    return 0
  fi
  cat <<'SQL'
SELECT (:'l_trusted'::boolean AND :'l_exists'::boolean) AS use_ledger \gset
\if :use_ledger
SQL
  pg_sql_preflight_db "infra_skills.ownership_transfer"
  printf '%s\n' '\else'
  pg_sql_preflight_db "$dummy"
  printf '%s\n' '\endif'
}

# pg_sql_preflight_db <ledger source>: the preflight's db rows.
pg_sql_preflight_db() {
  cat <<SQL
SELECT 'db', t.name, (d.oid IS NOT NULL),
       coalesce(regexp_replace(o.rolname, '[[:cntrl:]]', '?', 'g'), ''),
       coalesce(d.datdba = n.oid, false),
       (l.datoid IS NOT NULL),
       coalesce(regexp_replace(eo.rolname, '[[:cntrl:]]', '?', 'g'), ''),
       coalesce(eo.oid = n.oid, false),
       coalesce(eo.rolsuper OR eo.rolname ~ '^pg_', false),
       coalesce(has_database_privilege('public', d.oid, 'CONNECT'), false),
       coalesce(pub.now, ''), coalesce(pub.may, ''),
       coalesce(regexp_replace(pg_get_userbyid(l.to_role), '[[:cntrl:]]', '?', 'g'), ''),
       coalesce(l.to_role = n.oid, false),
       coalesce(d.datdba IN (l.from_role, l.to_role), true),
       coalesce(d.datdba::text, ''),
       coalesce(d.oid::text, ''), coalesce(eo.oid::text, '')
  FROM unnest(string_to_array(:'targets', ' ')) WITH ORDINALITY t(name, ord)
  LEFT JOIN pg_database d ON d.datname = t.name
  LEFT JOIN pg_roles o ON o.oid = d.datdba
  LEFT JOIN pg_roles n ON n.rolname = :'owner'
  LEFT JOIN $1 l ON l.datoid = d.oid AND l.done_at IS NULL
  LEFT JOIN pg_roles eo ON eo.oid = coalesce(l.from_role, d.datdba)
  LEFT JOIN LATERAL (
    SELECT array_to_string((array_agg(x.name ORDER BY x.name) FILTER (WHERE x.connected))[1:20], ', ')
             || CASE WHEN count(*) FILTER (WHERE x.connected) > 20 THEN format(' (+%s more)', count(*) FILTER (WHERE x.connected) - 20) ELSE '' END AS now,
           array_to_string((array_agg(x.name ORDER BY x.name))[1:20], ', ')
             || CASE WHEN count(*) > 20 THEN format(' (+%s more)', count(*) - 20) ELSE '' END AS may
      FROM (SELECT regexp_replace(r.rolname, '[[:cntrl:]]', '?', 'g') AS name,
                   EXISTS (SELECT FROM pg_stat_activity a WHERE a.datid = d.oid AND a.usesysid = r.oid) AS connected
              FROM pg_roles r
             WHERE r.rolcanlogin AND NOT r.rolsuper AND r.oid <> d.datdba
               AND r.rolname <> ALL (string_to_array(:'excluded', ','))
               AND r.rolname NOT IN (:'app_role', :'mig_role')
               AND NOT EXISTS (SELECT FROM $1 la WHERE la.datoid = d.oid AND la.from_role = r.oid)
               AND NOT EXISTS (SELECT FROM aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) e
                                WHERE e.grantee <> 0 AND e.privilege_type = 'CONNECT' AND pg_has_role(r.oid, e.grantee, 'USAGE'))) x
  ) pub ON d.oid IS NOT NULL AND has_database_privilege('public', d.oid, 'CONNECT')
 ORDER BY t.ord;
SQL
}

# The app role's cluster-wide part in --database mode: created with this app's marker, LOGIN,
# the connection limit, the password (unless kept), the timeouts.
pg_sql_app_role() {
  printf '\\set role %s\n\\set stmt_to %s\n\\set idle_to %s\n' \
    "'${app_username}'" "'${statement_timeout}'" "'${idle_tx_timeout}'"
  pg_sql_role_tx role app "$app_oid" "$mig_role" "${app_pw_now:-$app_pw_set}" app_verifier "$conn_limit" true
  cat <<'SQL'
SELECT format('ALTER ROLE %I SET statement_timeout = %L', :'role', :'stmt_to') WHERE :'stmt_to' <> '' \gexec
SELECT format('ALTER ROLE %I SET idle_in_transaction_session_timeout = %L', :'role', :'idle_to') WHERE :'idle_to' <> '' \gexec
SQL
}

# The migration role's cluster-wide part: created with its marker, LOGIN, its own connection
# limit, the password (unless kept), no statement or idle-in-transaction timeout. It is never a
# member of the app role, nor the app role of it, by any path (the preflight and the guard refuse
# that). Needs :role set.
pg_sql_migration_role() {
  printf '\\set mrole %s\n' "'${mig_role}'"
  pg_sql_role_tx mrole migrate "$mig_oid" "$app_username" "${mig_pw_now:-$mig_pw_set}" mig_verifier "$mig_conn_limit" true
  cat <<'SQL'
ALTER ROLE :"mrole" SET statement_timeout = 0;
ALTER ROLE :"mrole" SET idle_in_transaction_session_timeout = 0;
SQL
}

# pg_sql_rights <psql variable holding the grantee>: in the current database, USAGE and CREATE
# on every schema (pg_* and information_schema aside), DML on all tables, USAGE, SELECT, UPDATE
# on all sequences.
pg_sql_rights() {
  cat <<SQL
SELECT format('GRANT USAGE, CREATE ON SCHEMA %I TO %I', nspname, :'$1') FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' \\gexec
SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA %I TO %I', nspname, :'$1') FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' \\gexec
SELECT format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA %I TO %I', nspname, :'$1') FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' \\gexec
SQL
}

# pg_sql_creator_defaults <psql variable holding the grantee>: default privileges for the roles
# that create objects here (the database owner, each schema owner and the app role; not
# superusers, not pg_*) to the grantee, the grantee itself aside. Needs the temp view
# infra_skills_creators.
pg_sql_creator_defaults() {
  cat <<SQL
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO %I', rolname, :'$1') FROM infra_skills_creators WHERE rolname <> :'$1' \\gexec
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', rolname, :'$1') FROM infra_skills_creators WHERE rolname <> :'$1' \\gexec
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT USAGE ON SCHEMAS TO %I', rolname, :'$1') FROM infra_skills_creators WHERE rolname <> :'$1' \\gexec
SQL
}

pg_sql_creators_view() {
  cat <<'SQL'
CREATE TEMP VIEW infra_skills_creators AS
  SELECT DISTINCT r.rolname FROM pg_roles r
   WHERE (r.oid IN (SELECT datdba FROM pg_database WHERE datname = current_database()
                   UNION SELECT nspowner FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema')
      OR r.rolname = :'role')
     AND NOT r.rolsuper AND r.rolname !~ '^pg_';
SQL
}

# pg_sql_migration_in_db <schemas>: the migration role in the current database. Its schemas
# (--migration-schema) are created or moved to it, and the app role gets USAGE, CREATE and DML
# on them; the migration role gets the same rights as the app role and default privileges from
# the creators; ALTER DEFAULT PRIVILEGES FOR ROLE <migrate> gives the app role what it creates.
pg_sql_migration_in_db() {
  if [[ -n "$1" ]]; then
    printf '\\set mschemas %s\n' "'$1'"
    cat <<'SQL'
SELECT format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', s, :'mrole') FROM unnest(string_to_array(:'mschemas', ' ')) s \gexec
SELECT format('ALTER SCHEMA %I OWNER TO %I', n.nspname, :'mrole') FROM pg_namespace n
 WHERE n.nspname = ANY (string_to_array(:'mschemas', ' ')) AND n.nspowner <> (SELECT oid FROM pg_roles WHERE rolname = :'mrole') \gexec
SELECT format('GRANT USAGE, CREATE ON SCHEMA %I TO %I', s, :'role') FROM unnest(string_to_array(:'mschemas', ' ')) s \gexec
SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA %I TO %I', s, :'role') FROM unnest(string_to_array(:'mschemas', ' ')) s \gexec
SELECT format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA %I TO %I', s, :'role') FROM unnest(string_to_array(:'mschemas', ' ')) s \gexec
SQL
  fi
  pg_sql_rights mrole
  pg_sql_creator_defaults mrole
  cat <<'SQL'
ALTER DEFAULT PRIVILEGES FOR ROLE :"mrole" GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO :"role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"mrole" GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"mrole" GRANT USAGE ON SCHEMAS TO :"role";
SQL
}

# pg_migration_schemas <db>: the schemas --migration-schema names in <db>, space separated.
pg_migration_schemas() {
  local s out=""
  for s in ${PG_MIGRATION_SCHEMAS[@]+"${PG_MIGRATION_SCHEMAS[@]}"}; do
    [[ "${s%%.*}" == "$1" ]] && out+="${out:+ }${s#*.}"
  done
  printf '%s' "$out"
}

# pg_public_list_sql <database>: a read-only query that lists every login role (superusers and the
# owner aside) that reaches <database> only through PUBLIC, and whether it is connected now. The
# name is a validated database name (no quote).
pg_public_list_sql() {
  printf '%s' "SELECT r.rolname, EXISTS (SELECT FROM pg_stat_activity a WHERE a.datid = d.oid AND a.usesysid = r.oid) AS connected_now FROM pg_database d JOIN pg_roles r ON r.rolcanlogin AND NOT r.rolsuper AND r.oid <> d.datdba WHERE d.datname = '$1' AND NOT EXISTS (SELECT FROM aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) e WHERE e.grantee <> 0 AND e.privilege_type = 'CONNECT' AND pg_has_role(r.oid, e.grantee, 'USAGE')) ORDER BY 1;"
}

# pg_recovery_cmd <target index>: the exact command that finishes the ACL of a database an earlier
# --create-missing run made and did not finish: this database alone (with its key prefix), this
# run's tenant, migration role and Pooler, --revoke-public with this run's --keep-connect (none
# when not given), and no --create-missing.
pg_recovery_cmd() {
  local spec="${targets[$1]}" prefix
  prefix=":${spec#*:}"; [[ "$prefix" == ":POSTGRES" ]] && prefix=""
  printf 'tools/k3s/postgres.sh %s --provision-credentials %s%s --database %s%s%s%s --revoke-public --keep-connect %s' \
    "$ENV_NAME" "$app_id" "${tenant:+ --tenant ${tenant}}" "${target_names[$1]}" "$prefix" "${mig_role:+ --migration-role ${mig_role}}" \
    "$([[ "$PG_POOLER" == "true" ]] && printf ' --pooler')" "${PG_KEEP_CONNECT:-none}"
}

# pg_sql_preflight_objects: the second, read-only part of the preflight, for --take-ownership: in
# each database to move (\c), with the source role the first part found (:src). It runs before any
# password is made or set, so whatever would make the move fail stops the run with nothing changed.
# Rows (fields split by \x1f):
#   objects <database> <catalogs>   objects of the source that the move does not handle (operators,
#                                   collations, text search objects, ...): the run refuses;
#   defacl <database> <entries>     default privileges of the source that GRANT cannot reproduce
#                                   exactly (a grant option, or a privilege revoked from the
#                                   built-in default): the run refuses and prints them;
#   dstacl <database> <both sides>  the destination already has default privileges here that
#                                   differ from what the copy from the source would give (only
#                                   the exact grants this script makes are left out; grant options
#                                   and revoked built-in defaults count): the run refuses and prints both;
#   extskip <database> <what>       extensions of the source, and the source's members of any
#                                   extension: they stay with the source (a warning).
pg_sql_preflight_objects() {
  local i
  printf '%s\n' '-- infra-skills:preflight-objects' 'SET client_min_messages = warning;'
  for i in "${!target_names[@]}"; do
    [[ "${t_transfer[$i]}" == "true" ]] || continue
    printf '\\set db %s\n\\set src %s\n\\set dst %s\n\\set app_r %s\n\\set mig_r %s\n\\c :"db"\n' \
      "'${target_names[$i]}'" "${t_src_oid[$i]}" "'${new_owner}'" "'${app_username}'" "'${mig_role}'"
    cat <<'SQL'
SELECT 'objects', current_database(), string_agg(DISTINCT s.classid::regclass::text, ', ')
  FROM pg_shdepend s
 WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
   AND s.refclassid = 'pg_authid'::regclass AND s.refobjid = :src AND s.deptype = 'o'
   AND s.classid NOT IN ('pg_default_acl'::regclass, 'pg_extension'::regclass, 'pg_namespace'::regclass,
                         'pg_proc'::regclass, 'pg_largeobject'::regclass)
   AND NOT EXISTS (SELECT FROM pg_depend e WHERE e.classid = s.classid AND e.objid = s.objid AND e.deptype = 'e')
   AND NOT (s.classid = 'pg_class'::regclass AND EXISTS (
         SELECT FROM pg_class c WHERE c.oid = s.objid AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f', 'c')
            AND NOT (c.relkind = 'S' AND EXISTS (SELECT FROM pg_depend a JOIN pg_class o ON o.oid = a.refobjid
                                                  WHERE a.classid = 'pg_class'::regclass AND a.objid = c.oid AND a.refclassid = 'pg_class'::regclass
                                                    AND a.deptype IN ('a', 'i') AND o.relowner <> :src))))
   AND NOT (s.classid = 'pg_type'::regclass AND EXISTS (
         SELECT FROM pg_type t WHERE t.oid = s.objid
            AND ((t.typrelid = 0 AND t.typtype IN ('b', 'd', 'e', 'r', 'm') AND NOT EXISTS (SELECT FROM pg_type a WHERE a.typarray = t.oid))
                 -- a standalone composite type: moved with its pg_class row (relkind c)
                 OR (t.typtype = 'c' AND EXISTS (SELECT FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind = 'c')))))
HAVING count(*) > 0;
SELECT 'defacl', current_database(), string_agg(x.d, '; ' ORDER BY x.d)
  FROM (SELECT format('%s%s: %s to %s WITH GRANT OPTION', k.w, k.s, e.privilege_type,
                      CASE WHEN e.grantee = 0 THEN 'PUBLIC' ELSE regexp_replace(pg_get_userbyid(e.grantee), '[[:cntrl:]]', '?', 'g') END) AS d
          FROM pg_default_acl a
          CROSS JOIN LATERAL (SELECT CASE a.defaclobjtype WHEN 'r' THEN 'tables' WHEN 'S' THEN 'sequences' WHEN 'f' THEN 'functions'
                                                          WHEN 'T' THEN 'types' ELSE 'schemas' END AS w,
                                     CASE WHEN a.defaclnamespace <> 0 THEN ' in schema ' || quote_ident((SELECT nspname FROM pg_namespace WHERE oid = a.defaclnamespace))
                                          ELSE '' END AS s) k
          CROSS JOIN LATERAL aclexplode(a.defaclacl) e
         WHERE a.defaclrole = :src AND e.is_grantable AND e.grantee <> a.defaclrole
        UNION ALL
        SELECT format('%s: %s revoked from %s (a built-in default)', k.w, d.privilege_type,
                      CASE WHEN d.grantee = 0 THEN 'PUBLIC' ELSE regexp_replace(pg_get_userbyid(d.grantee), '[[:cntrl:]]', '?', 'g') END)
          FROM pg_default_acl a
          CROSS JOIN LATERAL (SELECT CASE a.defaclobjtype WHEN 'r' THEN 'tables' WHEN 'S' THEN 'sequences' WHEN 'f' THEN 'functions'
                                                          WHEN 'T' THEN 'types' ELSE 'schemas' END AS w) k
          CROSS JOIN LATERAL aclexplode(acldefault((CASE a.defaclobjtype WHEN 'S' THEN 's' ELSE a.defaclobjtype::text END)::"char", a.defaclrole)) d
         WHERE a.defaclrole = :src AND a.defaclnamespace = 0
           AND NOT EXISTS (SELECT FROM aclexplode(a.defaclacl) e WHERE e.grantee = d.grantee AND e.privilege_type = d.privilege_type)) x
HAVING count(*) > 0;
WITH norm AS (
  -- default privileges of the source and the destination here. Left out: each role's own entries
  -- (and the source's grants to the destination, which the copy drops); exactly the grants this
  -- script makes itself (to the app and migration roles, no grant option: DML on tables; USAGE,
  -- SELECT, UPDATE on sequences; USAGE on schemas); for global entries, the built-in defaults
  -- as they are. Any other entry, a grant option, and a revoked built-in default count.
  SELECT a.defaclrole AS role, a.defaclobjtype AS t, a.defaclnamespace AS ns,
         format('%s %s%s', CASE WHEN e.grantee = 0 THEN 'PUBLIC' ELSE regexp_replace(pg_get_userbyid(e.grantee), '[[:cntrl:]]', '?', 'g') END,
                e.privilege_type, CASE WHEN e.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END) AS entry
    FROM pg_default_acl a CROSS JOIN LATERAL aclexplode(a.defaclacl) e
   WHERE a.defaclrole IN (:src, coalesce((SELECT oid FROM pg_roles WHERE rolname = :'dst'), 0))
     AND e.grantee NOT IN (a.defaclrole, coalesce((SELECT oid FROM pg_roles WHERE rolname = :'dst'), 0))
     AND NOT (NOT e.is_grantable AND e.grantee IN (SELECT oid FROM pg_roles WHERE rolname IN (:'app_r', :'mig_r'))
              AND (a.defaclobjtype::text, e.privilege_type) IN (('r', 'SELECT'), ('r', 'INSERT'), ('r', 'UPDATE'), ('r', 'DELETE'), ('r', 'TRUNCATE'),
                                                                ('r', 'REFERENCES'), ('r', 'TRIGGER'), ('S', 'USAGE'), ('S', 'SELECT'), ('S', 'UPDATE'),
                                                                ('n', 'USAGE')))
     AND NOT (a.defaclnamespace = 0 AND NOT e.is_grantable AND EXISTS (
           SELECT FROM aclexplode(acldefault((CASE a.defaclobjtype WHEN 'S' THEN 's' ELSE a.defaclobjtype::text END)::"char", a.defaclrole)) d
            WHERE d.grantee = e.grantee AND d.privilege_type = e.privilege_type))
  UNION ALL
  SELECT a.defaclrole, a.defaclobjtype, a.defaclnamespace,
         format('%s %s revoked (a built-in default)', CASE WHEN d.grantee = 0 THEN 'PUBLIC' ELSE regexp_replace(pg_get_userbyid(d.grantee), '[[:cntrl:]]', '?', 'g') END,
                d.privilege_type)
    FROM pg_default_acl a
    CROSS JOIN LATERAL aclexplode(acldefault((CASE a.defaclobjtype WHEN 'S' THEN 's' ELSE a.defaclobjtype::text END)::"char", a.defaclrole)) d
   WHERE a.defaclrole IN (:src, coalesce((SELECT oid FROM pg_roles WHERE rolname = :'dst'), 0)) AND a.defaclnamespace = 0
     AND NOT EXISTS (SELECT FROM aclexplode(a.defaclacl) e WHERE e.grantee = d.grantee AND e.privilege_type = d.privilege_type)
), side AS (
  SELECT (role = :src) AS is_src, t, ns, string_agg(entry, ', ' ORDER BY entry) AS l FROM norm GROUP BY 1, 2, 3
)
SELECT 'dstacl', current_database(),
       string_agg(format('%s%s: %s has %s, the copy from the old owner gives %s',
                         CASE d.t WHEN 'r' THEN 'tables' WHEN 'S' THEN 'sequences' WHEN 'f' THEN 'functions' WHEN 'T' THEN 'types' ELSE 'schemas' END,
                         CASE WHEN d.ns <> 0 THEN ' in schema ' || quote_ident((SELECT nspname FROM pg_namespace WHERE oid = d.ns)) ELSE '' END,
                         :'dst', d.l, coalesce(s.l, 'nothing')), '; ')
  FROM side d LEFT JOIN side s ON s.is_src AND s.t = d.t AND s.ns = d.ns
 WHERE NOT d.is_src AND d.l IS DISTINCT FROM s.l
HAVING count(*) > 0;
SELECT 'extskip', current_database(), string_agg(x.d, '; ' ORDER BY x.d)
  FROM (SELECT format('extension %s (its own)', regexp_replace(x.extname, '[[:cntrl:]]', '?', 'g')) AS d
          FROM pg_extension x WHERE x.extowner = :src
        UNION ALL
        SELECT format('%s object(s) in extension %s (owned by %s)', count(*), regexp_replace(x.extname, '[[:cntrl:]]', '?', 'g'),
                      regexp_replace(pg_get_userbyid(x.extowner), '[[:cntrl:]]', '?', 'g'))
          FROM pg_shdepend s
          JOIN pg_depend e ON e.classid = s.classid AND e.objid = s.objid AND e.deptype = 'e' AND e.refclassid = 'pg_extension'::regclass
          JOIN pg_extension x ON x.oid = e.refobjid
         WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
           AND s.refclassid = 'pg_authid'::regclass AND s.refobjid = :src AND s.deptype = 'o' AND x.extowner <> :src
         GROUP BY x.extname, x.extowner) x
HAVING count(*) > 0;
SQL
  done
}

# pg_sql_existing_db <index>: one --database target, from the postgres database: create it
# (--create-missing, after recording the intent; or finish one an earlier run created), move its
# ownership (--take-ownership, through the ledger), CONNECT for the roles, PUBLIC's CONNECT
# (revoked only with --revoke-public, or on a database made here), then in the database the
# rights and default privileges. Prints SQL.
pg_sql_existing_db() {
  local i="$1" db="${target_names[$1]}" schemas revoke=false
  schemas="$(pg_migration_schemas "$db")"
  [[ "$PG_REVOKE_PUBLIC" == "true" || "${t_creates[$i]}" == "true" ]] && revoke=true
  printf '\\set db %s\n' "'${db}'"
  if [[ "${t_creates[$i]}" == "true" ]]; then
    # The intent first, claimed by (app, name): a run that stops after CREATE DATABASE leaves it
    # pending, and the next run of this app with --create-missing finishes the database (PUBLIC's
    # CONNECT revoked) instead of taking it for an existing one; another app's pending intent for
    # the name is never taken over (the preflight refused it; checked again here). Each creation
    # gets a nonce: right after CREATE DATABASE (not conditional: a database someone else made
    # since the preflight stops the run) the database gets the marker infra-skills:created:<app-id>:
    # <nonce> and the intent its oid. A retry finishes only the database that oid names, or, if the
    # run stopped before the oid was recorded, the one with that creation's marker.
    printf '\\set app %s\n' "'${app_id}'"
    cat <<'SQL'
INSERT INTO infra_skills.create_intent AS t (datname, app, revoke_public, nonce) VALUES (:'db', :'app', true, gen_random_uuid()::text)
ON CONFLICT (datname) DO UPDATE SET app = excluded.app, revoke_public = true, nonce = excluded.nonce, started_at = now(), done_at = NULL, datoid = NULL
 WHERE t.done_at IS NOT NULL;
SELECT set_config('infra_skills.c_db', :'db', false) AS c_db_set, set_config('infra_skills.c_app', :'app', false) AS c_app_set \gset
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM infra_skills.create_intent
                  WHERE datname = current_setting('infra_skills.c_db') AND app = current_setting('infra_skills.c_app') AND done_at IS NULL) THEN
    RAISE EXCEPTION 'infra-skills: the pending creation of database % belongs to another app; nothing created', current_setting('infra_skills.c_db');
  END IF;
END
$$;
SELECT 'infra-skills:created:' || app || ':' || nonce AS c_marker FROM infra_skills.create_intent
 WHERE datname = :'db' AND app = :'app' AND done_at IS NULL \gset
SQL
    if [[ "${t_finish[$i]}" != "true" ]]; then
      echo 'CREATE DATABASE :"db" OWNER :"owner";'
      echo "COMMENT ON DATABASE :\"db\" IS :'c_marker';"
    fi
    cat <<'SQL'
UPDATE infra_skills.create_intent SET datoid = (SELECT oid FROM pg_database WHERE datname = :'db' AND shobj_description(oid, 'pg_database') = :'c_marker')
 WHERE datname = :'db' AND app = :'app' AND done_at IS NULL AND datoid IS NULL;
-- The ACL of a database this run (or an earlier one) created: one transaction that holds off a
-- rename or drop (pg_database) and first checks it is still the recorded database. The recorded
-- oid is authoritative (the marker only established it, in the UPDATE above or an earlier run).
BEGIN;
SET LOCAL lock_timeout = '5s';
LOCK TABLE pg_catalog.pg_database IN SHARE ROW EXCLUSIVE MODE;
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM infra_skills.create_intent i JOIN pg_database x ON x.oid = i.datoid AND x.datname = i.datname
                  WHERE i.datname = current_setting('infra_skills.c_db') AND i.app = current_setting('infra_skills.c_app') AND i.done_at IS NULL) THEN
    RAISE EXCEPTION 'infra-skills: database % is not the one this app''s creation recorded (its oid); its ACL is left as it is', current_setting('infra_skills.c_db');
  END IF;
END
$$;
SQL
  fi
  if [[ "${t_transfer[$i]}" == "true" ]]; then
    # The pending ledger row of this database, by the oid the preflight saw (0 when there is none:
    # the transaction below then refuses); the destination is the role as its transaction guarded it.
    printf '\\set datoid %s\n' "${t_datoid[$i]}"
    cat <<'SQL'
SELECT coalesce(l.datoid, 0) AS l_datoid, coalesce(l.from_role, 0) AS from_oid, coalesce(l.to_role, 0) AS to_oid,
       :dest_goid AS owner_oid
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (SELECT t.datoid, t.from_role, t.to_role FROM infra_skills.ownership_transfer t
                      WHERE t.datoid = :datoid AND t.done_at IS NULL) l ON true \gset
SQL
  fi
  echo 'GRANT CONNECT, TEMPORARY ON DATABASE :"db" TO :"role";'
  if [[ -n "$mig_role" ]]; then
    echo 'GRANT CONNECT, TEMPORARY ON DATABASE :"db" TO :"mrole";'
    if [[ -n "$schemas" ]]; then echo 'GRANT CREATE ON DATABASE :"db" TO :"mrole";'; fi
  fi
  cat <<'SQL'
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db', :'ro') WHERE :'ro' <> '' AND EXISTS (SELECT FROM pg_roles WHERE rolname = :'ro') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO cnpg_pooler_pgbouncer', :'db') WHERE EXISTS (SELECT FROM pg_roles WHERE rolname = 'cnpg_pooler_pgbouncer') \gexec
SQL
  if [[ "$revoke" == "true" ]]; then
    echo "SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', datname, pg_get_userbyid(datdba)) FROM pg_database WHERE datname = :'db' \\gexec"
    if [[ "$pg_ledger" == "true" ]]; then
      cat <<'SQL'
SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', d.datname, r.rolname) FROM infra_skills.ownership_transfer l
  JOIN pg_database d ON d.oid = l.datoid JOIN pg_roles r ON r.oid = l.from_role WHERE d.datname = :'db' \gexec
SQL
    fi
    cat <<'SQL'
SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', :'db', k) FROM unnest(string_to_array(:'keep', ',')) k WHERE k <> '' \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db', :'ro_keep') WHERE :'ro_keep' <> '' \gexec
REVOKE CONNECT, TEMPORARY ON DATABASE :"db" FROM PUBLIC;
SQL
  fi
  [[ "${t_creates[$i]}" == "true" ]] && echo 'COMMIT;'
  cat <<'SQL'
\c :"db"
SET client_min_messages = warning;
SQL
  [[ "${t_transfer[$i]}" == "true" ]] && pg_sql_takeover
  pg_sql_rights role
  pg_sql_creators_view
  pg_sql_creator_defaults role
  if [[ -n "$mig_role" ]]; then pg_sql_migration_in_db "$schemas"; fi
  echo '\c postgres'
  if [[ "${t_transfer[$i]}" == "true" ]]; then
    echo "UPDATE infra_skills.ownership_transfer SET done_at = now() WHERE datoid = :l_datoid AND done_at IS NULL;"
  fi
  if [[ "${t_creates[$i]}" == "true" ]]; then
    echo "UPDATE infra_skills.create_intent SET done_at = now() WHERE datname = :'db' AND app = :'app' AND done_at IS NULL;"
  fi
}

# pg_sql_takeover: the ownership move of the current database, from the source role the ledger
# recorded (:from_oid) to the destination (:to_oid), as one transaction with bounded waits
# (lock_timeout 5s, statement_timeout 60s): a lock held elsewhere fails the run fast, with
# nothing changed. No REASSIGN OWNED: it would also move the source's other databases and its
# tablespaces. Instead:
#   1. ALTER ... OWNER for each object of the source in this database: schemas; tables,
#      partitions, views, materialized views, sequences (those of a column follow their table),
#      foreign tables, composite types; functions, procedures, aggregates; types, domains, ranges
#      and multiranges (array types follow); large objects. Extensions and the source's members of
#      any extension stay with the source (Postgres has no ALTER EXTENSION ... OWNER; the preflight
#      warns about them). The source's default privileges are copied to the destination (the
#      source's own stay); the preflight refused any it cannot copy exactly;
#   2. LOCK pg_database (SHARE ROW EXCLUSIVE, held until commit, no concurrent ALTER DATABASE
#      OWNER), then check the database oid, the role oids and the live owner against the ledger
#      row: the owner must be the source (or already the destination, when an earlier run's move
#      committed but was not marked done). Any mismatch rolls everything back;
#   3. ALTER DATABASE ... OWNER, then CONNECT and TEMPORARY again for the source and the app role
#      (ALTER DATABASE OWNER hands the old owner's own ACL entries to the new owner);
#   4. a check that nothing in this database still belongs to the source (default privileges and
#      extensions aside), else the whole move rolls back.
pg_sql_takeover() {
  cat <<'SQL'
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
SELECT set_config('infra_skills.from_oid', :'from_oid', true) AS s_from, set_config('infra_skills.to_oid', :'to_oid', true) AS s_to,
       set_config('infra_skills.datoid', :'l_datoid', true) AS s_dat, set_config('infra_skills.owner_oid', :'owner_oid', true) AS s_own \gset
SELECT format('ALTER SCHEMA %I OWNER TO %I', n.nspname, pg_get_userbyid(:to_oid)) FROM pg_namespace n
 WHERE n.nspowner = :from_oid
   AND NOT EXISTS (SELECT FROM pg_depend e WHERE e.classid = 'pg_namespace'::regclass AND e.objid = n.oid AND e.deptype = 'e') \gexec
SELECT format('ALTER %s %s OWNER TO %I', CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'S' THEN 'SEQUENCE'
                                          WHEN 'f' THEN 'FOREIGN TABLE' WHEN 'c' THEN 'TYPE' ELSE 'TABLE' END, c.oid::regclass, pg_get_userbyid(:to_oid))
  FROM pg_class c
 WHERE c.relowner = :from_oid AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f', 'c')
   AND NOT EXISTS (SELECT FROM pg_depend e WHERE e.classid = 'pg_class'::regclass AND e.objid = c.oid AND e.deptype = 'e')
   AND NOT (c.relkind = 'S' AND EXISTS (SELECT FROM pg_depend a WHERE a.classid = 'pg_class'::regclass AND a.objid = c.oid
                                          AND a.refclassid = 'pg_class'::regclass AND a.deptype IN ('a', 'i')))
 ORDER BY c.oid \gexec
SELECT format('ALTER ROUTINE %s OWNER TO %I', p.oid::regprocedure, pg_get_userbyid(:to_oid)) FROM pg_proc p
 WHERE p.proowner = :from_oid
   AND NOT EXISTS (SELECT FROM pg_depend e WHERE e.classid = 'pg_proc'::regclass AND e.objid = p.oid AND e.deptype = 'e') \gexec
SELECT format('ALTER %s %s OWNER TO %I', CASE t.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END, t.oid::regtype, pg_get_userbyid(:to_oid))
  FROM pg_type t
 WHERE t.typowner = :from_oid AND t.typrelid = 0 AND t.typtype IN ('b', 'd', 'e', 'r')
   AND NOT EXISTS (SELECT FROM pg_type a WHERE a.typarray = t.oid)
   AND NOT EXISTS (SELECT FROM pg_depend e WHERE e.classid = 'pg_type'::regclass AND e.objid = t.oid AND e.deptype = 'e') \gexec
SELECT format('ALTER TYPE %s OWNER TO %I', t.oid::regtype, pg_get_userbyid(:to_oid)) FROM pg_type t
 WHERE t.typowner = :from_oid AND t.typtype = 'm'
   AND NOT EXISTS (SELECT FROM pg_depend e WHERE e.classid = 'pg_type'::regclass AND e.objid = t.oid AND e.deptype = 'e') \gexec
SELECT format('ALTER LARGE OBJECT %s OWNER TO %I', l.oid, pg_get_userbyid(:to_oid)) FROM pg_largeobject_metadata l WHERE l.lomowner = :from_oid \gexec
SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I%s GRANT %s ON %s TO %s', pg_get_userbyid(:to_oid),
              CASE WHEN a.defaclnamespace <> 0 THEN format(' IN SCHEMA %I', n.nspname) ELSE '' END, e.privilege_type,
              CASE a.defaclobjtype WHEN 'r' THEN 'TABLES' WHEN 'S' THEN 'SEQUENCES' WHEN 'f' THEN 'FUNCTIONS' WHEN 'T' THEN 'TYPES' ELSE 'SCHEMAS' END,
              CASE WHEN e.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(e.grantee)) END)
  FROM pg_default_acl a LEFT JOIN pg_namespace n ON n.oid = a.defaclnamespace, aclexplode(a.defaclacl) e
 WHERE a.defaclrole = :from_oid AND e.grantee NOT IN (a.defaclrole, :to_oid) \gexec
LOCK TABLE pg_catalog.pg_database IN SHARE ROW EXCLUSIVE MODE;
DO $$
DECLARE
  f oid := current_setting('infra_skills.from_oid')::oid;
  t oid := current_setting('infra_skills.to_oid')::oid;
  dat oid := current_setting('infra_skills.datoid')::oid;
  own oid := current_setting('infra_skills.owner_oid')::oid;
  cur oid;
  live oid;
BEGIN
  SELECT oid, datdba INTO cur, live FROM pg_database WHERE datname = current_database();
  IF dat = 0 OR cur <> dat THEN
    RAISE EXCEPTION 'infra-skills: % is not the database the ledger recorded (no pending move, or it was dropped and made again); nothing moved', current_database();
  END IF;
  IF t = 0 OR t <> own THEN
    RAISE EXCEPTION 'infra-skills: the destination role of % is not the one the ledger recorded (dropped and made again?); nothing moved', current_database();
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE oid = f AND NOT rolsuper) THEN
    RAISE EXCEPTION 'infra-skills: the recorded owner of % (oid %) is gone or now a superuser; nothing moved', current_database(), f;
  END IF;
  IF live <> f AND live <> t THEN
    RAISE EXCEPTION 'infra-skills: % is owned by % now, not by % as recorded when the move started (changed by hand?); nothing moved. Check it, then fix or delete its row in infra_skills.ownership_transfer (postgres database).',
      current_database(), pg_get_userbyid(live), pg_get_userbyid(f);
  END IF;
END
$$;
SELECT format('ALTER DATABASE %I OWNER TO %I', current_database(), pg_get_userbyid(:to_oid)) \gexec
SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', current_database(), pg_get_userbyid(:from_oid)) \gexec
GRANT CONNECT, TEMPORARY ON DATABASE :"db" TO :"role";
DO $$
DECLARE
  f oid := current_setting('infra_skills.from_oid')::oid;
  kinds text;
BEGIN
  SELECT string_agg(DISTINCT s.classid::regclass::text, ', ') INTO kinds FROM pg_shdepend s
   WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
     AND s.refclassid = 'pg_authid'::regclass AND s.refobjid = f AND s.deptype = 'o'
     AND s.classid NOT IN ('pg_default_acl'::regclass, 'pg_extension'::regclass)
     AND NOT EXISTS (SELECT FROM pg_depend e WHERE e.classid = s.classid AND e.objid = s.objid AND e.deptype = 'e');
  IF kinds IS NOT NULL THEN
    RAISE EXCEPTION 'infra-skills: objects in database % are still owned by % (%), kinds this script does not move; nothing moved. Move them by hand (ALTER ... OWNER TO), then re-run.',
      current_database(), pg_get_userbyid(f), kinds;
  END IF;
  IF (SELECT datdba FROM pg_database WHERE datname = current_database()) = f THEN
    RAISE EXCEPTION 'infra-skills: database % is still owned by %', current_database(), pg_get_userbyid(f);
  END IF;
END
$$;
COMMIT;
SQL
}

provision_credentials() {
  local app_id="$1"
  local namespace="$NAMESPACE_POSTGRES"
  local tenant="$PG_TENANT"
  local app_namespace="${APP_NAMESPACE:-${tenant:-default}}"

  # Validate app_id (alphanumeric and hyphens only, for safety)
  if [[ ! "$app_id" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    err "Invalid app-id: ${app_id}"
    err "App ID must be lowercase alphanumeric with hyphens (e.g., 'my-app', 'evse')"
    exit 1
  fi
  if pg_reserved_role "$app_id"; then
    err "Invalid app-id: ${app_id} is a reserved role (postgres, app, streaming_replica, cnpg_pooler_pgbouncer, PG_READONLY_ROLE, pg_*, ...)"
    exit 1
  fi
  if [[ -n "$tenant" && ! "$tenant" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    err "Invalid tenant: ${tenant}"; exit 1
  fi
  # Role limits. A tenant shares the cluster with the platform's apps: its role gets a small
  # connection budget and time limits, so a runaway query or pool cannot starve them.
  local conn_limit statement_timeout idle_tx_timeout v
  if [[ -n "$tenant" ]]; then
    conn_limit="${PG_CONN_LIMIT:-${PG_TENANT_CONNECTION_LIMIT:-20}}"
    statement_timeout="${PG_STATEMENT_TIMEOUT:-${PG_TENANT_STATEMENT_TIMEOUT:-60s}}"
    idle_tx_timeout="${PG_TENANT_IDLE_IN_TRANSACTION_TIMEOUT:-5min}"
  else
    conn_limit="${PG_CONN_LIMIT:-${PG_APP_CONNECTION_LIMIT:-50}}"
    statement_timeout="${PG_STATEMENT_TIMEOUT:-${PG_APP_STATEMENT_TIMEOUT:-}}"
    idle_tx_timeout="${PG_APP_IDLE_IN_TRANSACTION_TIMEOUT:-}"
  fi
  if ! pg_int_between "$conn_limit" -1 "$PG_INT_MAX"; then
    err "connection limit must be a number from -1 to ${PG_INT_MAX}: ${conn_limit}"; exit 1
  fi
  for v in "$statement_timeout" "$idle_tx_timeout"; do
    [[ -z "$v" ]] || pg_duration_ok "$v" || { err "not a Postgres duration up to ${PG_INT_MAX} ms: ${v}"; exit 1; }
  done

  # --database <name>[:<PREFIX>]: existing databases instead of a new one named <app-id>. Each
  # entry is kept as "<db>:<PREFIX>", POSTGRES when no prefix was given.
  local targets=() spec t_db t_prefix seen_dbs=" " seen_prefixes=" "
  for spec in ${PG_DATABASES[@]+"${PG_DATABASES[@]}"}; do
    t_db="${spec%%:*}"; t_prefix="POSTGRES"
    [[ "$spec" == *:* ]] && t_prefix="${spec#*:}"
    if [[ ! "$t_db" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ || ${#t_db} -gt 63 ]]; then
      err "--database ${spec}: '${t_db}' is not a database name this script handles (letters, digits, _ and -, at most 63)"; exit 1
    fi
    case "$t_db" in postgres|template0|template1)
      err "--database ${t_db}: the cluster's own databases are not app databases"; exit 1 ;;
    esac
    if [[ ! "$t_prefix" =~ ^[A-Z]([A-Z0-9_]*[A-Z0-9])?$ ]]; then
      err "--database ${spec}: the key prefix must be upper case, e.g. JOURNAL_DB (keys JOURNAL_DB_HOST, ...)"; exit 1
    fi
    [[ "$seen_dbs" == *" ${t_db} "* ]] && { err "--database ${t_db} is named twice"; exit 1; }
    if [[ "$seen_prefixes" == *" ${t_prefix} "* ]]; then
      err "--database ${spec}: key prefix ${t_prefix} is already used by another database"
      [[ "$t_prefix" == POSTGRES ]] && err "  (only one database may go without a prefix)"
      exit 1
    fi
    seen_dbs+="${t_db} "; seen_prefixes+="${t_prefix} "
    targets+=("${t_db}:${t_prefix}")
  done
  local existing_mode=false entry i
  [[ ${#targets[@]} -gt 0 ]] && existing_mode=true
  local app_username="${app_id}"
  local app_database="${app_id}"
  [[ "$existing_mode" == "false" ]] && targets=("${app_database}:POSTGRES")
  local target_names=()
  for entry in "${targets[@]}"; do target_names+=("${entry%%:*}"); done

  # --migration-role: a second login role for migrate Jobs and backfills.
  local mig_role="" mig_conn_limit=""
  if [[ "$PG_MIGRATION_ROLE" == "true" ]]; then
    mig_role="${PG_MIGRATION_ROLE_NAME:-${app_id}_migrate}"
    if [[ ! "$mig_role" =~ ^[a-z_][a-z0-9_-]*$ || ${#mig_role} -gt 63 || "$mig_role" == "$app_id" ]]; then
      err "Invalid migration role name: ${mig_role} (lower case, digits, _ and -, at most 63, not the app role)"; exit 1
    fi
    if pg_reserved_role "$mig_role"; then
      err "Invalid migration role name: ${mig_role} is a reserved role (postgres, app, streaming_replica, cnpg_pooler_pgbouncer, PG_READONLY_ROLE, pg_*, ...)"; exit 1
    fi
    mig_conn_limit="${PG_MIGRATION_CONN_LIMIT:-${PG_MIGRATION_CONNECTION_LIMIT:-2}}"
    pg_int_between "$mig_conn_limit" 1 "$PG_INT_MAX" || { err "migration connection limit must be a number from 1 to ${PG_INT_MAX}: ${mig_conn_limit}"; exit 1; }
  fi
  # --migration-schema <db>.<schema>: schemas the migration role owns (it gets CREATE on <db>).
  for spec in ${PG_MIGRATION_SCHEMAS[@]+"${PG_MIGRATION_SCHEMAS[@]}"}; do
    t_db="${spec%%.*}"
    if [[ "$spec" != *.* || ! "${spec#*.}" =~ ^[a-z_][a-z0-9_]*$ || ${#spec} -gt 127 || "${spec#*.}" == pg_* || "${spec#*.}" == information_schema ]]; then
      err "--migration-schema ${spec}: give <database>.<schema>, the schema lower case, digits and _ (not pg_* or information_schema)"; exit 1
    fi
    [[ " ${target_names[*]} " == *" ${t_db} "* ]] || { err "--migration-schema ${spec}: ${t_db} is not one of this run's databases (${target_names[*]})"; exit 1; }
  done

  # --revoke-public --keep-connect <role>[,<role>] (with --database)
  local keep_roles="" k need_roles="" pub_excluded="" _keep=()
  if [[ "$PG_REVOKE_PUBLIC" == "true" ]]; then
    if [[ "$PG_KEEP_CONNECT" != "none" ]]; then
      IFS=',' read -r -a _keep <<<"$PG_KEEP_CONNECT"
      for k in ${_keep[@]+"${_keep[@]}"}; do
        if [[ ! "$k" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ || ${#k} -gt 63 ]]; then
          err "--keep-connect: '${k}' is not a role name this script handles (letters, digits, _ . -, at most 63)"; exit 1
        fi
        keep_roles+="${keep_roles:+,}${k}"
      done
      [[ -n "$keep_roles" ]] || { err "--keep-connect: no role given (use --keep-connect none to keep no other role)"; exit 1; }
    fi
  fi

  log "=== Provisioning PostgreSQL credentials for application: ${app_id}${tenant:+ (tenant ${tenant})} ==="

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

  local pg_host="postgres-cluster-rw.${namespace}.svc.cluster.local"
  local pg_port="5432"
  local pooler_name="pooler-${app_id}"
  local superuser="postgres"
  local secrets_dir="$ENVS_ROOT/${ENV_NAME}/secrets.plain"
  local secret_file="${secrets_dir}/${app_id}-db.secret.yaml"
  local mig_secret_file="${secrets_dir}/${app_id}-db-migrate.secret.yaml"
  # shellcheck disable=SC2034  # the passwords are read by name (pg_sql_role_tx, pg_write_secret)
  # +x: never exported, even when the caller's environment holds these names (bash 3.2 locals
  # inherit the export attribute) -- no secret reaches a child process's environment.
  local +x app_password="" mig_password=""
  local app_pw_set=true mig_pw_set=true app_exists=f mig_exists=f app_oid="" mig_oid=""
  # shellcheck disable=SC2034  # read by name (pg_sql_role_tx)
  local +x app_verifier="" mig_verifier=""
  local ro_role=""
  [[ -z "$tenant" ]] && ro_role="${PG_READONLY_ROLE:-}"
  # --revoke-public keeps a configured read-only login's CONNECT, tenant or not (it reached the
  # databases through PUBLIC until now).
  local ro_keep=""
  [[ "$PG_REVOKE_PUBLIC" == "true" ]] && ro_keep="${PG_READONLY_ROLE:-}"

  # Find the primary to execute commands (psql as the local superuser over the socket)
  local pg_pod
  pg_pod=$(kubectl -n "$namespace" get pods -l cnpg.io/cluster=postgres-cluster,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  [[ -n "$pg_pod" ]] || pg_pod=$(kubectl -n "$namespace" get pods -l cnpg.io/cluster=postgres-cluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$pg_pod" ]]; then
    err "No PostgreSQL pod found in cluster"
    exit 1
  fi

  # --- Preflight (every path, the plain default one included): the roles, the databases and
  # their owners, the ledger, the roles that need to exist; nothing changes before it passes.
  local new_owner="${mig_role:-$app_username}" pg_ledger=false
  local t_creates=() t_finish=() t_transfer=() t_owner=() t_owner_oid=() t_public=() t_pub_now=() t_pub_may=() t_datoid=() t_src_oid=() intents=" " intents_bound=" "
  [[ "$PG_TAKE_OWNERSHIP" == "true" || "$PG_REVOKE_PUBLIC" == "true" || "$PG_CREATE_MISSING" == "true" ]] && pg_ledger=true
  if [[ "$PG_REVOKE_PUBLIC" == "true" ]]; then
    need_roles="$keep_roles"
    [[ -n "$ro_keep" ]] && need_roles+="${need_roles:+,}${ro_keep}"
  fi
  pub_excluded="${keep_roles}${PG_READONLY_ROLE:+,${PG_READONLY_ROLE}},cnpg_pooler_pgbouncer"
  for i in "${!target_names[@]}"; do t_creates[i]=false; t_finish[i]=false; t_transfer[i]=false; done
  local pre_out line refused=false missing=()
  local -a f
  pre_out=$(pg_sql_preflight | kubectl -n "$namespace" exec -i "$pg_pod" -c postgres -- psql -U "$superuser" -d postgres \
              -v ON_ERROR_STOP=1 -q -tA -F "$PG_US") \
    || { err "The preflight read of roles and databases failed"; exit 1; }
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS="$PG_US" read -r -a f <<<"$line"
    case "${f[0]}" in
      role)
        # role <kind> <name> <exists> <marker ok> <comment> <attributes> <privileged memberships>
        #      <owns its database> <oid> <LOGIN> <any membership> <linked with the other role>
        local r_kind="${f[1]}" r_name="${f[2]}" r_exists="${f[3]}" r_marked="${f[4]}" r_comment="${f[5]:-}" r_attrs="${f[6]:-}"
        local r_members="${f[7]:-}" r_owns="${f[8]:-f}" r_oid="${f[9]:-}" r_login="${f[10]:-f}" r_any="${f[11]:-}" r_linked="${f[12]:-f}"
        [[ "$r_oid" =~ ^[0-9]*$ ]] || { err "The preflight returned an odd oid for role ${r_name}"; exit 1; }
        [[ "$r_kind" == app ]] && { app_exists="$r_exists"; app_oid="$r_oid"; }
        [[ "$r_kind" == migrate ]] && { mig_exists="$r_exists"; mig_oid="$r_oid"; }
        [[ "$r_exists" == t ]] || continue
        if [[ -n "$r_attrs" ]]; then
          err "Role ${r_name} exists with ${r_attrs}: this script does not hand out such a role (${r_kind} role)"; refused=true
        elif [[ -n "$r_members" ]]; then
          err "Role ${r_name} belongs to ${r_members}: this script does not hand out such a role (${r_kind} role)"; refused=true
        elif [[ "$r_linked" == t ]]; then
          err "Roles ${app_username} and ${mig_role} are members of one another (directly or through a group): the migration role must not hold"
          err "  the app role's rights, nor the app role the migration role's. Revoke that membership first; nothing changed."
          refused=true
        elif [[ "$r_marked" == t ]]; then
          :
        elif [[ "$r_kind" == app && "$r_owns" == t && -z "$r_comment" && "$r_login" == t && -z "$r_any" ]]; then
          info "Role ${r_name} owns database ${r_name} (made by the default path): adopting it as this app's role"
        else
          if [[ "$r_kind" == app && "$r_owns" == t && -z "$r_comment" ]]; then
            err "Role ${r_name} owns database ${r_name} but is not adopted automatically: $([[ "$r_login" == t ]] || printf 'it has NOLOGIN')$([[ "$r_login" != t && -n "$r_any" ]] && printf '; ')${r_any:+it is in role memberships (${r_any})}."
          else
            err "Role ${r_name} exists but was not made by this script for ${app_id} (${r_comment:+comment \"${r_comment}\", }no marker ${PG_ROLE_MARKER}:${r_kind}:${app_id})."
          fi
          err "  Pick another name, or, if it really is this app's ${r_kind} role, mark it first: COMMENT ON ROLE \"${r_name}\" IS '${PG_ROLE_MARKER}:${r_kind}:${app_id}';"
          refused=true
        fi
        ;;
      need)
        [[ "${f[2]}" == t ]] || { err "--revoke-public: role ${f[1]} does not exist (named with --keep-connect or PG_READONLY_ROLE)"; refused=true; }
        ;;
      ledger)
        if [[ "${f[1]}" != t || "${f[2]}" != t || "${f[3]}" != t ]]; then
          err "infra_skills.ownership_transfer or infra_skills.create_intent (or their schema) in the postgres database is not what this script makes:"
          err "  schema owner ok=${f[1]}, tables' owner and kind ok=${f[2]}, columns ok=${f[3]}. Check them by hand first."
          refused=true
        fi
        ;;
      intent)
        # intent <database> <this app's> <bound to this app and this database> <its app>
        if [[ "${f[2]:-f}" != t ]]; then
          # Another app's pending creation of a database by that name (made or not): never this run's.
          err "Database ${f[1]}: app ${f[4]:-?} has a pending creation of a database by that name (infra_skills.create_intent)."
          err "  Nothing changed. Pick another database name, or finish or clear that app's creation first."
          refused=true
        else
          intents+="${f[1]} "
          [[ "${f[3]:-f}" == t ]] && intents_bound+="${f[1]} "
        fi
        ;;
      db)
        # db <name> <exists> <owner> <owner is new> <pending> <old owner> <old is new> <old privileged> <public> <now> <may>
        #    <pending to> <pending to is new> <owner is the pending move's source or destination> <owner oid>
        #    <database oid> <source oid>
        for i in "${!target_names[@]}"; do
          [[ "${target_names[$i]}" == "${f[1]}" ]] || continue
          t_owner[i]="${f[3]:-}"; t_owner_oid[i]="${f[15]:-}"; t_datoid[i]="${f[16]:-}"; t_src_oid[i]="${f[17]:-}"; t_public[i]="${f[9]:-f}"; t_pub_now[i]="${f[10]:-}"; t_pub_may[i]="${f[11]:-}"
          if [[ "${f[2]}" != t ]]; then
            t_creates[i]=true
            if [[ "$PG_CREATE_MISSING" == "true" ]]; then
              info "Database ${f[1]} does not exist: it will be created, owned by ${new_owner}"
            else
              missing+=("${f[1]}")
            fi
          elif [[ "$intents" == *" ${f[1]} "* ]]; then
            # --create-missing: an earlier run recorded it and stopped before its ACL was done. Only a
            # database that run made (the oid the intent recorded, or before that its creation's
            # marker) is finished.
            if [[ "$intents_bound" != *" ${f[1]} "* ]]; then
              err "Database ${f[1]} exists, but nothing shows it is the one an earlier run for ${app_id} created: neither the oid"
              err "  recorded in infra_skills.create_intent nor that creation's marker (COMMENT ON DATABASE '${PG_ROLE_MARKER}:created:${app_id}:<nonce>') matches."
              err "  Nothing changed; PUBLIC keeps its CONNECT on it. To finish by hand:"
              err "  1. identify the database: SELECT oid, datdba::regrole, shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = '${f[1]}';"
              err "     and compare with SELECT * FROM infra_skills.create_intent WHERE datname = '${f[1]}'; (postgres database);"
              err "  2. if it is this app's database, close it and grant the roles (the ACL step the creation did not reach), with"
              err "     this database only and without --create-missing (--keep-connect: the roles besides the owner that keep CONNECT, or none):"
              err "     $(pg_recovery_cmd "$i")"
              err "     if it is not, rename or drop it, or pick another name;"
              err "  3. then delete the row: DELETE FROM infra_skills.create_intent WHERE datname = '${f[1]}' AND app = '${app_id}';"
              err "  4. then run this run's command again. Deleting the row and re-running --create-missing alone would leave PUBLIC's CONNECT on it."
              refused=true
            elif [[ "${f[4]}" == t ]]; then
              t_creates[i]=true; t_finish[i]=true
              info "Database ${f[1]} was created by an earlier run that did not finish: finishing it (PUBLIC's CONNECT revoked, grants)"
            else
              err "Database ${f[1]} was being created by an earlier run, but its owner is now ${f[3]}, not ${new_owner}. Nothing changed;"
              err "  PUBLIC keeps its CONNECT on it. Check it by hand; if it is this app's, finish its ACL (this database only, without --create-missing):"
              err "  $(pg_recovery_cmd "$i")"
              err "  then DELETE FROM infra_skills.create_intent WHERE datname = '${f[1]}' AND app = '${app_id}'; (postgres database), and run this run's command again."
              refused=true
            fi
          elif [[ "$PG_TAKE_OWNERSHIP" == "true" && "${f[5]}" == t && "${f[13]:-f}" != t ]]; then
            err "--take-ownership: an unfinished move of ${f[1]} from ${f[6]} to ${f[12]:-?} is recorded; this run would move it to ${new_owner}."
            err "  Re-run with the same destination (${f[12]:-?}) to complete it first; nothing changed."
            refused=true
          elif [[ "$PG_TAKE_OWNERSHIP" == "true" && "${f[5]}" == t && "${f[14]:-t}" != t ]]; then
            err "--take-ownership: ${f[1]} is owned by ${f[3]} now, not by ${f[6]} as recorded when the move started (changed by hand?)."
            err "  Nothing changed. Check it, then fix or delete its row in infra_skills.ownership_transfer (postgres database)."
            refused=true
          elif [[ "$PG_TAKE_OWNERSHIP" == "true" && ( "${f[5]}" == t || "${f[4]}" != t ) && "${f[7]}" != t ]]; then
            if [[ "${f[8]}" == t ]]; then
              err "--take-ownership: ${f[1]} is owned by ${f[6]}, a superuser or system role; moving its objects is refused"; refused=true
            else
              t_transfer[i]=true
              [[ "${t_owner_oid[i]}" =~ ^[0-9]+$ && "${t_datoid[i]}" =~ ^[0-9]+$ && "${t_src_oid[i]}" =~ ^[0-9]+$ ]] \
                || { err "The preflight returned no owner, database or source oid for ${f[1]}"; exit 1; }
              if [[ "${f[5]}" == t ]]; then
                info "Ownership of ${f[1]}: an earlier run left the move from ${f[6]} unfinished; completing it to ${new_owner}"
              else
                info "Ownership of ${f[1]}: ${f[6]} -> ${new_owner} (its objects in ${f[1]}, then the database, one transaction)"
              fi
            fi
          fi
        done
        ;;
    esac
  done <<<"$pre_out"
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "These databases do not exist: ${missing[*]} (check the names, or add --create-missing)"
    exit 1
  fi
  [[ "$refused" == "true" ]] && exit 1

  # --- Preflight, part 2 (--take-ownership): read-only, inside each database to move. Objects
  # the move cannot handle and default privileges it cannot copy exactly stop the run here,
  # before any password is made or set; what stays with the source is named.
  if [[ " ${t_transfer[*]:-} " == *" true "* ]]; then
    pre_out=$(pg_sql_preflight_objects | kubectl -n "$namespace" exec -i "$pg_pod" -c postgres -- psql -U "$superuser" -d postgres \
                -v ON_ERROR_STOP=1 -q -tA -F "$PG_US") \
      || { err "The preflight read inside the databases to take over failed"; exit 1; }
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      IFS="$PG_US" read -r -a f <<<"$line"
      case "${f[0]}" in
        objects)
          err "--take-ownership: in ${f[1]}, the old owner also owns objects this script does not move (${f[2]:-?})."
          err "  Move them by hand first (ALTER ... OWNER TO ${new_owner}), then re-run; nothing changed."
          refused=true ;;
        defacl)
          err "--take-ownership: in ${f[1]}, the old owner has default privileges that cannot be copied exactly: ${f[2]:-?}."
          err "  Set them for ${new_owner} by hand (ALTER DEFAULT PRIVILEGES FOR ROLE ...) and reset the old owner's, then re-run; nothing changed."
          refused=true ;;
        dstacl)
          err "--take-ownership: in ${f[1]}, ${new_owner} already has default privileges that differ from what the copy would give: ${f[2]:-?}."
          err "  Align them by hand (ALTER DEFAULT PRIVILEGES FOR ROLE ${new_owner} ...), then re-run; nothing changed."
          refused=true ;;
        extskip)
          warn "--take-ownership: in ${f[1]}, these stay with the old owner (Postgres has no ALTER EXTENSION ... OWNER): ${f[2]:-?}" ;;
      esac
    done <<<"$pre_out"
    [[ "$refused" == "true" ]] && exit 1
  fi

  # Passwords (with --keep-password: the ones the Secret files hold, and only for a new role)
  pg_password app_password "$secret_file" "$app_username" "$app_exists" app_pw_set app_verifier
  [[ -n "$mig_role" ]] && pg_password mig_password "$mig_secret_file" "$mig_role" "$mig_exists" mig_pw_set mig_verifier

  # --- Pooler (before the grants: CNPG creates its auth role cnpg_pooler_pgbouncer) ---
  if [[ "$PG_POOLER" == "true" ]]; then
    info "Applying CNPG Pooler ${pooler_name} (PgBouncer, ${PG_POOLER_MODE:-session} mode)..."
    jq -nc --arg n "$pooler_name" --arg ns "$namespace" --arg t "$tenant" --arg app "$app_id" \
       --arg mode "${PG_POOLER_MODE:-session}" --arg pool "$([[ "$conn_limit" == -1 ]] && echo 20 || echo "$conn_limit")" '
      ({"app.kubernetes.io/part-of": $app} + (if $t != "" then {"infra-skills/tenant": $t} else {} end)) as $l
      | {apiVersion: "postgresql.cnpg.io/v1", kind: "Pooler", metadata: {name: $n, namespace: $ns, labels: $l},
         spec: {cluster: {name: "postgres-cluster"}, instances: 1, type: "rw",
                pgbouncer: {poolMode: $mode, parameters: {max_client_conn: "200", default_pool_size: $pool}},
                template: {metadata: {labels: $l}, spec: {containers: []}}}}' \
      | kubectl apply -f - || { err "Failed to apply Pooler ${pooler_name}"; exit 1; }
    pg_host="${pooler_name}.${namespace}.svc.cluster.local"
    local pooler_role_found=false
    for i in $(seq 1 30); do
      kubectl -n "$namespace" exec "$pg_pod" -c postgres -- psql -U "$superuser" -d postgres -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname = 'cnpg_pooler_pgbouncer'" 2>/dev/null | grep -q 1 && { pooler_role_found=true; break; }
      sleep 2
    done
    # A run that closes PUBLIC on a database (the default path, --create-missing, --revoke-public)
    # needs the pooler role first, or the Pooler could not reach that database.
    local closes_public=false
    [[ "$existing_mode" == "false" || "$PG_REVOKE_PUBLIC" == "true" || " ${t_creates[*]} " == *" true "* ]] && closes_public=true
    if [[ "$closes_public" == "true" && "$pooler_role_found" != "true" ]]; then
      err "The pooler role cnpg_pooler_pgbouncer does not exist after 60 s (Pooler ${pooler_name} not ready?)."
      err "  This run would close PUBLIC's CONNECT on a database, so the Pooler needs that role first; nothing else changed. Re-run once the Pooler is up."
      exit 1
    fi
  fi

  if [[ "$existing_mode" == "false" ]]; then
  info "Creating database '${app_database}' and role '${app_username}' (connection limit ${conn_limit}${statement_timeout:+, statement_timeout ${statement_timeout}}${idle_tx_timeout:+, idle_in_transaction_session_timeout ${idle_tx_timeout}})..."

  # The SQL goes over stdin, never on a command line, and the password statement runs with
  # log_statement off, so the password lands in neither ps nor the server log. Identifiers are
  # quoted (:"name"), so app ids with hyphens work.
  #   * REVOKE CONNECT, TEMPORARY ... FROM PUBLIC: by default every role may connect to every
  #     database; with it revoked only the owner and explicit grants can. Other databases
  #     keep PUBLIC's CONNECT until --revoke-public-connect --apply (listed below for a tenant).
  #   * a new role gets no attribute beyond LOGIN; an existing one keeps its attributes (a
  #     warning names the dangerous ones).
  pg_sql_default_app "$app_pw_set" | kubectl -n "$namespace" exec -i "$pg_pod" -c postgres -- psql -U "$superuser" -d postgres -v ON_ERROR_STOP=1 -q || { err "Failed to create/update the database role and database"; exit 1; }

  # Pre-install common extensions as superuser so app user can use them
  info "Pre-installing common PostgreSQL extensions..."
  local ext
  for ext in vector pg_trgm btree_gin btree_gist; do
    kubectl -n "$namespace" exec "$pg_pod" -c postgres -- psql -U "$superuser" -d "${app_database}" -qc "CREATE EXTENSION IF NOT EXISTS ${ext};" >/dev/null 2>&1 || \
      { [[ "$ext" == vector ]] && warn "pgvector extension not available (image may not include it)"; }
  done

  info "✓ Database and user created"
  else
    # --- Existing databases (--database): the role gets rights on each, the database keeps its
    # owner (grant mode) unless --take-ownership moves it to ${new_owner}.
    #   * the app role (and the migration role) get CONNECT and TEMPORARY, the pooler role and
    #     PG_READONLY_ROLE (not for a tenant) CONNECT. PUBLIC keeps its CONNECT unless
    #     --revoke-public: then the owner, the former owner, the --keep-connect roles, the
    #     read-only and the pooler role get CONNECT first (a database made here is closed too);
    #   * in every schema (pg_* and information_schema aside): USAGE and CREATE, and SELECT,
    #     INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER on all tables, USAGE, SELECT,
    #     UPDATE on all sequences;
    #   * default privileges for the database owner and each schema owner (not superusers), so
    #     tables and sequences they create later are the role's too.
    local entry_list=""
    for i in "${!targets[@]}"; do entry_list+="${entry_list:+, }${target_names[$i]} (${targets[$i]#*:}_*)"; done
    info "Role '${app_username}' (connection limit ${conn_limit}${statement_timeout:+, statement_timeout ${statement_timeout}}${idle_tx_timeout:+, idle_in_transaction_session_timeout ${idle_tx_timeout}}) on: ${entry_list}"
    info "  $([[ "$PG_TAKE_OWNERSHIP" == "true" ]] && echo "ownership mode: the databases move to ${new_owner}" || echo "grant mode: the databases keep their owners")"
    if [[ ${#targets[@]} -gt 1 && "$conn_limit" != -1 ]]; then
      info "  CONNECTION LIMIT ${conn_limit} counts every session of ${app_username}, across all ${#targets[@]} databases (Pooler clients included)"
    fi
    for i in "${!targets[@]}"; do
      [[ "${t_creates[$i]}" == "true" || "${t_public[$i]:-f}" != t ]] && continue
      if [[ "$PG_REVOKE_PUBLIC" == "true" ]]; then
        info "${target_names[$i]}: revoking PUBLIC's CONNECT and TEMPORARY (kept: owner ${t_owner[$i]:-?}${keep_roles:+, ${keep_roles}}${ro_keep:+, ${ro_keep}}, the pooler role, the former owner)"
        [[ -n "${t_pub_may[$i]}" ]] && warn "${target_names[$i]}: these login roles connect only through PUBLIC and lose CONNECT now: ${t_pub_may[$i]}"
        [[ -n "${t_pub_now[$i]}" ]] && warn "${target_names[$i]}:   connected now: ${t_pub_now[$i]}"
      else
        warn "${target_names[$i]}: PUBLIC keeps CONNECT (left as it is)."
        if [[ -n "${t_pub_may[$i]}" ]]; then
          warn "  Login roles that connect through PUBLIC only: ${t_pub_may[$i]}"
          [[ -n "${t_pub_now[$i]}" ]] && warn "  connected now: ${t_pub_now[$i]}"
        fi
        warn "  To close it: --revoke-public --keep-connect <role>[,<role>] (or none); the owner, PG_READONLY_ROLE and the pooler role keep CONNECT"
      fi
      if [[ "${t_pub_may[$i]}" == *" more)" || "${t_pub_now[$i]}" == *" more)" ]]; then
        warn "${target_names[$i]}: the lists above are cut at 20. The full list (read-only; run it in psql as the superuser, e.g."
        warn "  tools/k3s/postgres.sh ${ENV_NAME} --watch sql, before any --revoke-public run):"
        warn "  $(pg_public_list_sql "${target_names[$i]}")"
      fi
    done
    {
      printf '\\set ro %s\n\\set ro_keep %s\n\\set owner %s\n\\set keep %s\n\\set mrole %s\n\\set targets %s\nSET client_min_messages = warning;\n' \
        "'${ro_role}'" "'${ro_keep}'" "'${new_owner}'" "'${keep_roles}'" "'${mig_role}'" "'${target_names[*]}'"
      if [[ "$pg_ledger" == "true" ]]; then
        cat <<'SQL'
CREATE SCHEMA IF NOT EXISTS infra_skills;
REVOKE ALL ON SCHEMA infra_skills FROM PUBLIC;
CREATE TABLE IF NOT EXISTS infra_skills.ownership_transfer (
  datoid oid PRIMARY KEY, datname name NOT NULL, from_role oid NOT NULL, to_role oid NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(), done_at timestamptz);
REVOKE ALL ON infra_skills.ownership_transfer FROM PUBLIC;
CREATE TABLE IF NOT EXISTS infra_skills.create_intent (
  datname name PRIMARY KEY, app text NOT NULL, revoke_public boolean NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(), done_at timestamptz, datoid oid, nonce text NOT NULL);
REVOKE ALL ON infra_skills.create_intent FROM PUBLIC;
SQL
      fi
      # With ownership moves, a role that exists keeps its current password until every move has
      # committed (a move that fails, on a lock timeout say, then leaves both the password and
      # the Secret as they were); its new password is set at the end of this session. A role made
      # in this run gets its password when it is created.
      local app_pw_now="$app_pw_set" mig_pw_now="$mig_pw_set" app_pw_late=false mig_pw_late=false
      if [[ " ${t_transfer[*]} " == *" true "* ]]; then
        [[ "$app_pw_set" == "true" && "$app_exists" == "t" ]] && { app_pw_now=false; app_pw_late=true; }
        [[ -n "$mig_role" && "$mig_pw_set" == "true" && "$mig_exists" == "t" ]] && { mig_pw_now=false; mig_pw_late=true; }
      fi
      pg_sql_app_role
      # The migration role first: a database created or taken over below may be its own.
      [[ -n "$mig_role" ]] && pg_sql_migration_role
      # The ledger: each database's original owner, recorded before anything moves. It records
      # the owner and the database the preflight saw (by oid) and the destination role as its
      # transaction above guarded it (:dest_goid), not whatever carries those names at this
      # moment; a database or destination role dropped and made again since is refused here, and
      # an owner changed in between fails the move's check under the lock.
      printf '\\set dest_goid :%s\n' "$([[ -n "$mig_role" ]] && echo migrate_goid || echo app_goid)"
      for i in "${!targets[@]}"; do
        [[ "${t_transfer[$i]}" == "true" ]] || continue
        printf '\\set db %s\n\\set seen_owner %s\n\\set datoid %s\n' "'${target_names[$i]}'" "${t_owner_oid[$i]}" "${t_datoid[$i]}"
        cat <<'SQL'
INSERT INTO infra_skills.ownership_transfer AS t (datoid, datname, from_role, to_role)
SELECT d.oid, d.datname, :seen_owner, n.oid FROM pg_database d, pg_roles n
 WHERE d.oid = :datoid AND d.datname = :'db' AND n.oid = :dest_goid AND n.rolname = :'owner' AND :seen_owner <> n.oid
ON CONFLICT (datoid) DO UPDATE
   SET datname = excluded.datname, from_role = excluded.from_role, to_role = excluded.to_role, started_at = now(), done_at = NULL
 WHERE t.done_at IS NOT NULL;
SELECT set_config('infra_skills.i_db', :'db', false) AS i_db,
       set_config('infra_skills.i_ok', (EXISTS (SELECT FROM pg_database WHERE oid = :datoid AND datname = :'db')
                                        AND EXISTS (SELECT FROM pg_roles WHERE oid = :dest_goid AND rolname = :'owner'))::text, false) AS i_ok \gset
DO $$
BEGIN
  IF NOT current_setting('infra_skills.i_ok')::boolean THEN
    RAISE EXCEPTION 'infra-skills: database % or the destination role was dropped and made again since the preflight (another oid under the same name); nothing moved',
      current_setting('infra_skills.i_db');
  END IF;
END
$$;
SQL
      done
      for i in "${!targets[@]}"; do pg_sql_existing_db "$i"; done
      # Every move has committed (ON_ERROR_STOP ends the session at the first failure): now the
      # new passwords of the roles that existed, in one transaction with both roles' guards, so
      # both change or neither does.
      if [[ "$app_pw_late" == "true" || "$mig_pw_late" == "true" ]]; then
        echo 'BEGIN;'
        if [[ "$app_pw_late" == "true" ]]; then
          printf '\\set role %s\n' "'${app_username}'"
          pg_sql_role_tx role app "$app_oid" "$mig_role" true app_verifier "$conn_limit" true false
        fi
        if [[ "$mig_pw_late" == "true" ]]; then
          printf '\\set mrole %s\n' "'${mig_role}'"
          pg_sql_role_tx mrole migrate "$mig_oid" "$app_username" true mig_verifier "$mig_conn_limit" true false
        fi
        echo 'COMMIT;'
      fi
    } | kubectl -n "$namespace" exec -i "$pg_pod" -c postgres -- psql -U "$superuser" -d postgres -v ON_ERROR_STOP=1 -q \
      || { err "Failed to set up role ${app_username} on: ${target_names[*]}"; exit 1; }

    for i in "${!targets[@]}"; do
      [[ "${t_creates[$i]}" == "true" ]] || continue
      local ext
      for ext in vector pg_trgm btree_gin btree_gist; do
        kubectl -n "$namespace" exec "$pg_pod" -c postgres -- psql -U "$superuser" -d "${target_names[$i]}" -qc "CREATE EXTENSION IF NOT EXISTS ${ext};" >/dev/null 2>&1 || \
          { [[ "$ext" == vector ]] && warn "pgvector extension not available in ${target_names[$i]} (image may not include it)"; }
      done
    done
    info "✓ Role ${app_username} set up on: ${target_names[*]}"
  fi

  # --- Migration role on the default path (with --database it ran in the session above) ---
  if [[ -n "$mig_role" && "$existing_mode" == "false" ]]; then
    info "Migration role '${mig_role}' (connection limit ${mig_conn_limit}, no statement_timeout)..."
    {
      printf '\\set role %s\nSET client_min_messages = warning;\n' "'${app_username}'"
      pg_sql_migration_role
      local schemas
      schemas="$(pg_migration_schemas "$app_database")"
      printf '\\set db %s\n' "'${app_database}'"
      echo 'GRANT CONNECT, TEMPORARY ON DATABASE :"db" TO :"mrole";'
      if [[ -n "$schemas" ]]; then echo 'GRANT CREATE ON DATABASE :"db" TO :"mrole";'; fi
      printf '\\c :"db"\nSET client_min_messages = warning;\n'
      pg_sql_creators_view
      pg_sql_migration_in_db "$schemas"
      echo '\c postgres'
    } | kubectl -n "$namespace" exec -i "$pg_pod" -c postgres -- psql -U "$superuser" -d postgres -v ON_ERROR_STOP=1 -q \
      || { err "Failed to set up the migration role ${mig_role}"; exit 1; }
  fi
  [[ -n "$mig_role" ]] && info "✓ Migration role ${mig_role} set up"

  local db_list="" excl=""
  for entry in "${targets[@]}"; do
    db_list+="${db_list:+, }${entry%%:*}"; excl+="'${entry%%:*}', "
  done

  # A tenant role can still reach every database where PUBLIC keeps CONNECT: name them.
  if [[ -n "$tenant" ]]; then
    local open_dbs
    open_dbs=$(kubectl -n "$namespace" exec -i "$pg_pod" -c postgres -- psql -U "$superuser" -d postgres -tA <<SQL
SELECT string_agg(datname, ' ' ORDER BY datname) FROM pg_database
 WHERE datallowconn AND NOT datistemplate AND datname NOT IN (${excl}'postgres') AND has_database_privilege('${app_username}', datname, 'CONNECT');
SQL
)
    if [[ -n "$open_dbs" ]]; then
      warn "Tenant role ${app_username} may still CONNECT to: ${open_dbs}"
      warn "  (PUBLIC holds CONNECT there). Close them: tools/k3s/postgres.sh ${ENV_NAME} --revoke-public-connect [--apply]"
    else
      info "✓ Tenant role ${app_username} can connect only to ${db_list} (and postgres)"
    fi
    info "  The postgres database stays open to every role (the exporter and CNPG use it); it holds no app data."
  fi

  # Ensure namespace exists (a tenant namespace comes from tools/k3s/tenant.sh)
  if ! kubectl get ns "$app_namespace" >/dev/null 2>&1; then
    if [[ -n "$tenant" ]]; then
      err "Namespace ${app_namespace} does not exist: run tools/k3s/tenant.sh ${ENV_NAME} ${tenant} first"
      exit 1
    fi
    kubectl create ns "$app_namespace"
  fi

  # --keep-password: the kept passwords must still be the roles' passwords right before the Secret
  # is written and applied (another run or an operator may have rotated one since the first
  # check). Runs for one app are not serialized: two at once are not supported.
  if [[ "$app_pw_set" == "false" ]] && ! provision::without_xtrace pg_matches_live app_password "$app_username"; then
    err "--keep-password: role ${app_username}'s password changed during this run (rotated elsewhere?); the Secret is neither written nor applied."
    exit 1
  fi
  if [[ -n "$mig_role" && "$mig_pw_set" == "false" ]] && ! provision::without_xtrace pg_matches_live mig_password "$mig_role"; then
    err "--keep-password: role ${mig_role}'s password changed during this run (rotated elsewhere?); the Secret is neither written nor applied."
    exit 1
  fi

  # Create secret file(s): on the default path exactly as before INFRA-243
  local legacy=true
  [[ "$existing_mode" == "true" ]] && legacy=false
  mkdir -p "$secrets_dir"
  local host_note=""
  [[ "$PG_POOLER" == "true" ]] && host_note=" (CNPG Pooler ${pooler_name})"
  info "Creating secret file: ${secret_file}"
  provision::without_xtrace pg_write_secret "$secret_file" "${app_id}-db" "$app_namespace" "$pg_host" "$pg_port" \
    "$app_username" app_password "$host_note" "$legacy" "${targets[@]}"
  if [[ -n "$mig_role" ]]; then
    info "Creating secret file: ${mig_secret_file}"
    provision::without_xtrace pg_write_secret "$mig_secret_file" "${app_id}-db-migrate" "$app_namespace" "$pg_host" "$pg_port" \
      "$mig_role" mig_password "$host_note" "$legacy" "${targets[@]}"
  fi

  info "✓ Secret file created"

  # Apply to kubectl
  info "Applying secret to Kubernetes..."
  kubectl apply -f "$secret_file" || {
    err "Failed to apply secret to Kubernetes"
    exit 1
  }
  if [[ -n "$mig_role" ]]; then
    kubectl apply -f "$mig_secret_file" || { err "Failed to apply the migration secret to Kubernetes"; exit 1; }
  fi

  info "✓ Secret applied to namespace: ${app_namespace}"

  # Output summary
  echo ""
  info "=== Credentials Provisioned ==="
  info "Application ID:     ${app_id}"
  info "Database:           ${db_list}"
  info "Username:           ${app_username}"
  info "Secret name:        ${app_id}-db"
  info "Secret namespace:   ${app_namespace}"
  info "Secret file:        ${secret_file}"
  if [[ -n "$mig_role" ]]; then
    info "Migration role:     ${mig_role} (connection limit ${mig_conn_limit}, no statement_timeout)"
    info "Migration secret:   ${app_id}-db-migrate (${mig_secret_file##*/}), same keys"
    if [[ "$PG_TAKE_OWNERSHIP" != "true" ]]; then
      info "Note: ${mig_role} can create objects and change what it owns, but it cannot ALTER or DROP what other"
      info "  roles own (the app role's tables, the old owner's). To hand the existing objects to it, run once:"
      info "  tools/k3s/postgres.sh ${ENV_NAME} --provision-credentials ${app_id} --database <db>[:<PREFIX>] --take-ownership --migration-role ${mig_role}"
    fi
  fi
  info ""
  info "Connection details:"
  info "  Host:             ${pg_host}"
  info "  Port:             ${pg_port}"
  info "  Database:         ${db_list}"
  info "  Username:         ${app_username}"
  info "  Connection limit: ${conn_limit} (per role, across all its databases)"
  info ""
  info "Secret fields:"
  for entry in "${targets[@]}"; do
    local p="${entry#*:}"
    info "  ${p}_HOST"
    info "  ${p}_PORT"
    info "  ${p}_DATABASE"
    info "  ${p}_USERNAME"
    info "  ${p}_PASSWORD"
  done
  echo ""

  exit 0
}

# ============================================================================
# Revoke PUBLIC's CONNECT on application databases
# ============================================================================
# Every role may connect to every database by default (PUBLIC holds CONNECT and TEMPORARY).
# This lists the databases where PUBLIC still does and, with --apply, first grants CONNECT
# explicitly to each database's owner, PG_READONLY_ROLE and cnpg_pooler_pgbouncer, then
# revokes PUBLIC's. The postgres database and templates are left alone (the exporter and
# CNPG use postgres).
revoke_public_connect() {
  local namespace="$NAMESPACE_POSTGRES" pg_pod
  pg_pod=$(kubectl -n "$namespace" get pods -l cnpg.io/cluster=postgres-cluster,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  [[ -n "$pg_pod" ]] || { err "No primary PostgreSQL pod found"; exit 1; }
  local dbs
  dbs=$(kubectl -n "$namespace" exec -i "$pg_pod" -c postgres -- psql -U postgres -d postgres -tA <<'SQL'
SELECT datname FROM pg_database
 WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' AND has_database_privilege('public', datname, 'CONNECT')
 ORDER BY 1;
SQL
)
  if [[ -z "$dbs" ]]; then
    info "✓ PUBLIC holds CONNECT on no application database"
    exit 0
  fi
  info "PUBLIC holds CONNECT on: $(tr '\n' ' ' <<<"$dbs")"
  if [[ "$REVOKE_PUBLIC_APPLY" != "true" ]]; then
    info "Nothing changed. Revoke with: tools/k3s/postgres.sh ${ENV_NAME} --revoke-public-connect --apply"
    info "  (grants CONNECT to each owner${PG_READONLY_ROLE:+, ${PG_READONLY_ROLE}} and cnpg_pooler_pgbouncer first; any other role that"
    info "   relied on PUBLIC then needs its own GRANT CONNECT)"
    exit 0
  fi
  kubectl -n "$namespace" exec -i "$pg_pod" -c postgres -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q <<SQL || { err "revoke failed"; exit 1; }
\\set ro '${PG_READONLY_ROLE:-}'
SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', d.datname, pg_get_userbyid(d.datdba)) FROM pg_database d
 WHERE d.datallowconn AND NOT d.datistemplate AND d.datname <> 'postgres' AND has_database_privilege('public', d.datname, 'CONNECT') \\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', d.datname, r.rolname) FROM pg_database d, pg_roles r
 WHERE r.rolname IN (:'ro', 'cnpg_pooler_pgbouncer') AND d.datallowconn AND NOT d.datistemplate AND d.datname <> 'postgres'
   AND has_database_privilege('public', d.datname, 'CONNECT') \\gexec
SELECT format('REVOKE CONNECT, TEMPORARY ON DATABASE %I FROM PUBLIC', d.datname) FROM pg_database d
 WHERE d.datallowconn AND NOT d.datistemplate AND d.datname <> 'postgres' AND has_database_privilege('public', d.datname, 'CONNECT') \\gexec
SQL
  info "✓ PUBLIC's CONNECT revoked on: $(tr '\n' ' ' <<<"$dbs")"
  exit 0
}

if [[ "$REVOKE_PUBLIC_CONNECT" == "true" ]]; then
  revoke_public_connect
fi

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
  # The sh -c script is single-quoted on purpose: it expands its variables inside the pod.
  # shellcheck disable=SC2016
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
    # Resources and memory parameters are never changed here either (a change restarts the
    # instance). Compared as written, so "8" and "8000m" count as different: keep the live
    # patch and env.properties in the same notation.
    local live_sizing want_sizing
    live_sizing=$(kubectl -n "$NAMESPACE_POSTGRES" get cluster postgres-cluster -o jsonpath='{.spec.resources.limits.cpu}/{.spec.resources.limits.memory}/{.spec.postgresql.parameters.shared_buffers}' 2>/dev/null || true)
    want_sizing="${POSTGRES_CPU_LIMIT}/${POSTGRES_MEMORY_LIMIT}/${POSTGRES_SHARED_BUFFERS}"
    if [[ -n "$live_sizing" && "$live_sizing" != "$want_sizing" ]]; then
      warn "postgres-cluster limits cpu/memory/shared_buffers are ${live_sizing}; env.properties says ${want_sizing}. Not changing it here."
      warn "  Patch it deliberately (restarts the instance), e.g. from envs/<env>/migrations/ if the env keeps a patch file."
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
      max_connections: "${POSTGRES_MAX_CONNECTIONS}"
      shared_buffers: "${POSTGRES_SHARED_BUFFERS}"
      effective_cache_size: "${POSTGRES_EFFECTIVE_CACHE_SIZE}"
      maintenance_work_mem: "${POSTGRES_MAINTENANCE_WORK_MEM}"
      checkpoint_completion_target: "0.9"
      wal_buffers: "16MB"
      default_statistics_target: "100"
      random_page_cost: "1.1"
      effective_io_concurrency: "200"
      work_mem: "4MB"
      min_wal_size: "1GB"
      max_wal_size: "${POSTGRES_MAX_WAL_SIZE}"
      wal_compression: "${POSTGRES_WAL_COMPRESSION}"
      checkpoint_timeout: "${POSTGRES_CHECKPOINT_TIMEOUT}"
      log_temp_files: "${POSTGRES_LOG_TEMP_FILES}"
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
      memory: "${POSTGRES_MEMORY_REQUEST}"
      cpu: "${POSTGRES_CPU_REQUEST}"
    limits:
      memory: "${POSTGRES_MEMORY_LIMIT}"
      cpu: "${POSTGRES_CPU_LIMIT}"
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
