#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PostgreSQL Database Dump Script
# ============================================================================
# Creates a full dump of a PostgreSQL database from a Kubernetes cluster.
# The dump is saved locally on the provisioning host.
#
# Usage:
#   tools/k3s/postgres-dump.sh <database-name> [options]
#
# Options:
#   --namespace <namespace>    PostgreSQL namespace (default: postgres)
#   --output <file>             Output file path (default: <dbname>-<timestamp>.sql)
#   --format <format>          Dump format: plain, custom, directory, tar (default: plain)
#   --list-databases           List available databases and exit
#   --env <env-name>           Use environment-specific namespace (overrides --namespace)
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

# --- Defaults ---
NAMESPACE_POSTGRES="${NAMESPACE_POSTGRES:-postgres}"
DUMP_FORMAT="${DUMP_FORMAT:-plain}"
LIST_DATABASES=false
ENV_NAME=""
OUTPUT_FILE=""

# --- Parse arguments ---
DATABASE_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      NAMESPACE_POSTGRES="$2"
      shift 2
      ;;
    --output|-o)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --format|-f)
      DUMP_FORMAT="$2"
      shift 2
      ;;
    --list-databases|-l)
      LIST_DATABASES=true
      shift
      ;;
    --env)
      ENV_NAME="$2"
      shift 2
      ;;
    --help|-h)
      cat <<EOF
Usage: $0 <database-name> [options]

Options:
  --namespace <namespace>    PostgreSQL namespace (default: postgres)
  --output <file>             Output file path (default: <dbname>-<timestamp>.sql)
  --format <format>          Dump format: plain, custom, directory, tar (default: plain)
  --list-databases           List available databases and exit
  --env <env-name>           Use environment-specific namespace (overrides --namespace)
  --help                     Show this help message

Examples:
  $0 app
  $0 evse --output evse-backup.sql
  $0 app --format custom --output app-backup.dump
  $0 --list-databases
EOF
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$DATABASE_NAME" ]]; then
        DATABASE_NAME="$1"
      else
        echo "ERROR: Multiple database names provided: $DATABASE_NAME and $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# --- Load environment if specified ---
if [[ -n "$ENV_NAME" ]]; then
  if provision::load_env "$ENV_NAME" 2>/dev/null; then
    # Environment may override NAMESPACE_POSTGRES
    NAMESPACE_POSTGRES="${NAMESPACE_POSTGRES:-postgres}"
  else
    provision::error "Environment '$ENV_NAME' not found (envs/$ENV_NAME/env.properties missing)."
    exit 1
  fi
fi

# --- Validation ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
need kubectl

# --- Logging helpers ---
log() { echo "[postgres-dump] $*"; }
info() { echo "[postgres-dump:info] $*"; }
warn() { echo "[postgres-dump:warn] $*" >&2; }
err() { echo "[postgres-dump:error] $*" >&2; }

# --- Check kubectl context ---
if ! kubectl cluster-info >/dev/null 2>&1; then
  err "Cannot connect to Kubernetes cluster. Check kubectl context."
  exit 1
fi

# Validate kubectl context matches environment (if env was specified)
if [[ -n "$ENV_NAME" ]]; then
  if ! provision::validate_kubectl_context; then
    exit 1
  fi
fi

# --- Check if namespace exists ---
if ! kubectl get ns "$NAMESPACE_POSTGRES" >/dev/null 2>&1; then
  err "Namespace '$NAMESPACE_POSTGRES' does not exist"
  exit 1
fi

# --- Check if cluster exists ---
if ! kubectl -n "$NAMESPACE_POSTGRES" get cluster postgres-cluster >/dev/null 2>&1; then
  err "PostgreSQL cluster 'postgres-cluster' not found in namespace: $NAMESPACE_POSTGRES"
  exit 1
fi

# --- Find PostgreSQL pod ---
PG_POD=$(kubectl -n "$NAMESPACE_POSTGRES" get pods -l cnpg.io/cluster=postgres-cluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$PG_POD" ]]; then
  err "No PostgreSQL pod found in cluster"
  exit 1
fi

info "Found PostgreSQL pod: $PG_POD"

# --- Get superuser credentials ---
if ! kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-superuser >/dev/null 2>&1; then
  err "PostgreSQL superuser secret not found"
  err "Run provisioning first: tools/k3s/postgres.sh <env-name>"
  exit 1
fi

PG_USER=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-superuser -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "postgres")
PG_PASS=$(kubectl -n "$NAMESPACE_POSTGRES" get secret postgres-cluster-superuser -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [[ -z "$PG_PASS" ]]; then
  err "Failed to retrieve superuser password"
  exit 1
fi

# --- List databases function ---
list_databases() {
  log "=== Available Databases ==="
  kubectl -n "$NAMESPACE_POSTGRES" exec "$PG_POD" -- \
    env PGPASSWORD="$PG_PASS" psql -U "$PG_USER" -d postgres -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres' ORDER BY datname" \
    2>/dev/null | while read -r dbname; do
    if [[ -n "$dbname" ]]; then
      echo "  - $dbname"
    fi
  done
  exit 0
}

if [[ "$LIST_DATABASES" == "true" ]]; then
  list_databases
fi

# --- Validate database name provided ---
if [[ -z "$DATABASE_NAME" ]]; then
  err "Database name is required"
  err ""
  err "Usage: $0 <database-name> [options]"
  err "       $0 --list-databases  (to see available databases)"
  exit 1
fi

# --- Verify database exists ---
info "Verifying database '$DATABASE_NAME' exists..."
if ! kubectl -n "$NAMESPACE_POSTGRES" exec "$PG_POD" -- \
  env PGPASSWORD="$PG_PASS" psql -U "$PG_USER" -d postgres -tc \
  "SELECT 1 FROM pg_database WHERE datname = '$DATABASE_NAME'" | grep -q 1; then
  err "Database '$DATABASE_NAME' does not exist"
  err ""
  err "Available databases:"
  list_databases
  exit 1
fi

info "✓ Database '$DATABASE_NAME' found"

# --- Determine output file ---
if [[ -z "$OUTPUT_FILE" ]]; then
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  case "$DUMP_FORMAT" in
    plain)
      OUTPUT_FILE="${DATABASE_NAME}-${TIMESTAMP}.sql"
      ;;
    custom)
      OUTPUT_FILE="${DATABASE_NAME}-${TIMESTAMP}.dump"
      ;;
    directory)
      OUTPUT_FILE="${DATABASE_NAME}-${TIMESTAMP}.d"
      ;;
    tar)
      OUTPUT_FILE="${DATABASE_NAME}-${TIMESTAMP}.tar"
      ;;
    *)
      err "Invalid format: $DUMP_FORMAT (must be: plain, custom, directory, tar)"
      exit 1
      ;;
  esac
fi

# Ensure output directory exists
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
if [[ "$OUTPUT_DIR" != "." && "$OUTPUT_DIR" != "" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

# --- Perform dump ---
log "=== Creating database dump ==="
info "Database:     $DATABASE_NAME"
info "Format:       $DUMP_FORMAT"
info "Output file:  $OUTPUT_FILE"
info "Pod:          $PG_POD"
info ""

case "$DUMP_FORMAT" in
  plain)
    info "Running pg_dump (plain SQL format)..."
    info "Ensuring UTF-8 encoding for proper Unicode handling..."
    kubectl -n "$NAMESPACE_POSTGRES" exec "$PG_POD" -- \
      env PGPASSWORD="$PG_PASS" \
      PGCLIENTENCODING=UTF8 \
      pg_dump -U "$PG_USER" -d "$DATABASE_NAME" \
      --clean --if-exists --create \
      --encoding=UTF8 \
      --verbose \
      > "$OUTPUT_FILE"
    ;;
  custom)
    info "Running pg_dump (custom format)..."
    info "Ensuring UTF-8 encoding for proper Unicode handling..."
    kubectl -n "$NAMESPACE_POSTGRES" exec "$PG_POD" -- \
      env PGPASSWORD="$PG_PASS" \
      PGCLIENTENCODING=UTF8 \
      pg_dump -U "$PG_USER" -d "$DATABASE_NAME" \
      --format=custom --clean --if-exists \
      --encoding=UTF8 \
      --verbose \
      > "$OUTPUT_FILE"
    ;;
  directory)
    err "Directory format requires special handling - not yet implemented"
    err "Use 'custom' format instead, or implement directory format handling"
    exit 1
    ;;
  tar)
    err "Tar format requires special handling - not yet implemented"
    err "Use 'custom' format instead, or implement tar format handling"
    exit 1
    ;;
  *)
    err "Invalid format: $DUMP_FORMAT"
    exit 1
    ;;
esac

# --- Verify dump file ---
if [[ ! -f "$OUTPUT_FILE" ]]; then
  err "Dump file was not created: $OUTPUT_FILE"
  exit 1
fi

FILE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
info ""
info "✓ Dump completed successfully"
info "  File: $OUTPUT_FILE"
info "  Size: $FILE_SIZE"

# --- Show restore instructions ---
info ""
info "=== Restore Instructions ==="
case "$DUMP_FORMAT" in
  plain)
    info "To restore this dump to local PostgreSQL:"
    info ""
    info "Option 1: Create the role first, then restore:"
    info "  PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d postgres -c \"CREATE ROLE ${DATABASE_NAME};\""
    info "  PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d postgres < $OUTPUT_FILE"
    info ""
    info "Option 2: Filter out database/role creation and restore to existing database:"
    info "  grep -v \"^CREATE DATABASE\" $OUTPUT_FILE | \\"
    info "  grep -v \"^ALTER DATABASE\" | \\"
    info "  grep -v \"^\\\\connect\" | \\"
    info "  sed 's/OWNER TO ${DATABASE_NAME}/OWNER TO postgres/g' | \\"
    info "  PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d postgres"
    info ""
    info "To restore to Kubernetes cluster:"
    info "  kubectl -n $NAMESPACE_POSTGRES exec -i $PG_POD -- \\"
    info "    env PGPASSWORD='<password>' psql -U $PG_USER -d postgres < $OUTPUT_FILE"
    ;;
  custom)
    info "To restore this dump to local PostgreSQL:"
    info "  # Create the role first if needed:"
    info "  PGPASSWORD=postgres psql -h localhost -p 5432 -U postgres -d postgres -c \"CREATE ROLE ${DATABASE_NAME};\""
    info "  # Then restore:"
    info "  PGPASSWORD=postgres pg_restore -h localhost -p 5432 -U postgres -d postgres --no-owner --no-acl $OUTPUT_FILE"
    info ""
    info "To restore to Kubernetes cluster:"
    info "  kubectl -n $NAMESPACE_POSTGRES exec -i $PG_POD -- \\"
    info "    env PGPASSWORD='<password>' pg_restore -U $PG_USER -d <target-db> --no-owner --no-acl < $OUTPUT_FILE"
    ;;
esac

exit 0
