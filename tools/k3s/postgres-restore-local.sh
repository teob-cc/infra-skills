#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PostgreSQL Local Restore Script
# ============================================================================
# Restores a PostgreSQL dump to a local PostgreSQL instance.
# Handles role/database name mismatches automatically.
#
# Usage:
#   tools/k3s/postgres-restore-local.sh <dump-file> [options]
#
# Options:
#   --host <host>             PostgreSQL host (default: localhost)
#   --port <port>             PostgreSQL port (default: 5432)
#   --user <user>             PostgreSQL user (default: postgres)
#   --database <db>           Target database name (default: postgres)
#   --password <pass>         PostgreSQL password (or use PGPASSWORD env var)
#   --create-role            Create the source database role if it doesn't exist
#   --skip-role-check        Skip role creation (assume role exists)
#   --format <format>         Dump format: auto, plain, custom (default: auto)
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

# --- Defaults ---
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
PGPASSWORD="${PGPASSWORD:-}"
CREATE_ROLE=true
SKIP_ROLE_CHECK=false
DUMP_FORMAT="auto"
DUMP_FILE=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|-h)
      PGHOST="$2"
      shift 2
      ;;
    --port|-p)
      PGPORT="$2"
      shift 2
      ;;
    --user|-U)
      PGUSER="$2"
      shift 2
      ;;
    --database|-d)
      PGDATABASE="$2"
      shift 2
      ;;
    --password)
      PGPASSWORD="$2"
      shift 2
      ;;
    --create-role)
      CREATE_ROLE=true
      shift
      ;;
    --skip-role-check)
      SKIP_ROLE_CHECK=true
      CREATE_ROLE=false
      shift
      ;;
    --format|-f)
      DUMP_FORMAT="$2"
      shift 2
      ;;
    --help)
      cat <<EOF
Usage: $0 <dump-file> [options]

Arguments:
  <dump-file>                Path to the PostgreSQL dump file

Options:
  --host <host>              PostgreSQL host (default: localhost)
  --port <port>              PostgreSQL port (default: 5432)
  --user <user>              PostgreSQL user (default: postgres)
  --database <db>            Target database name (default: postgres)
  --password <pass>          PostgreSQL password (or use PGPASSWORD env var)
  --create-role              Create the source database role if needed (default)
  --skip-role-check          Skip role creation (assume role exists)
  --format <format>          Dump format: auto, plain, custom (default: auto)
  --help                     Show this help message

Examples:
  # Restore to local postgres database
  $0 evse-dump.sql --password postgres

  # Restore to specific database
  $0 evse-dump.sql --database mydb --password postgres

  # Restore custom format dump
  $0 evse-dump.dump --format custom --password postgres
EOF
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$DUMP_FILE" ]]; then
        DUMP_FILE="$1"
      else
        echo "ERROR: Too many arguments" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# --- Validation ---
if [[ -z "$DUMP_FILE" ]]; then
  echo "ERROR: Dump file is required" >&2
  exit 1
fi

if [[ ! -f "$DUMP_FILE" ]]; then
  echo "ERROR: Dump file not found: $DUMP_FILE" >&2
  exit 1
fi

# --- Logging helpers ---
log() { echo "[postgres-restore-local] $*"; }
info() { echo "[postgres-restore-local:info] $*"; }
warn() { echo "[postgres-restore-local:warn] $*" >&2; }
err() { echo "[postgres-restore-local:error] $*" >&2; }

# --- Set PGPASSWORD if provided ---
if [[ -n "$PGPASSWORD" ]]; then
  export PGPASSWORD
fi

# --- Detect dump format ---
detect_format() {
  if [[ "$DUMP_FORMAT" != "auto" ]]; then
    echo "$DUMP_FORMAT"
    return 0
  fi

  # Check file extension
  case "$DUMP_FILE" in
    *.dump|*.backup)
      echo "custom"
      ;;
    *.sql|*.txt)
      echo "plain"
      ;;
    *)
      # Check file header
      if head -c 5 "$DUMP_FILE" 2>/dev/null | grep -q "PGDMP"; then
        echo "custom"
      else
        echo "plain"
      fi
      ;;
  esac
}

FORMAT=$(detect_format)
info "Detected dump format: $FORMAT"

# --- Extract source database name from dump ---
extract_source_db() {
  if [[ "$FORMAT" == "plain" ]]; then
    # Look for CREATE DATABASE statement
    grep -m 1 "^CREATE DATABASE" "$DUMP_FILE" 2>/dev/null | \
      sed -E "s/^CREATE DATABASE[[:space:]]+([^[:space:]]+).*/\1/" || echo ""
  else
    # For custom format, we can't easily extract it, so return empty
    echo ""
  fi
}

SOURCE_DB=$(extract_source_db)
if [[ -n "$SOURCE_DB" ]]; then
  info "Detected source database name: $SOURCE_DB"
fi

# --- Extract roles that need to be created ---
extract_roles() {
  if [[ "$FORMAT" == "plain" ]]; then
    # Find OWNER TO statements
    grep -E "OWNER TO [a-zA-Z0-9_]+" "$DUMP_FILE" 2>/dev/null | \
      sed -E "s/.*OWNER TO ([a-zA-Z0-9_]+).*/\1/" | \
      sort -u || true
  else
    echo ""
  fi
}

# --- Test connection ---
info "Testing database connection..."
if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
  err "Cannot connect to database. Check connection parameters."
  exit 1
fi
info "✓ Connected to database: $PGDATABASE"

# --- Create missing roles ---
if [[ "$CREATE_ROLE" == "true" && "$FORMAT" == "plain" ]]; then
  info "Checking for required roles..."
  ROLES=$(extract_roles)
  
  if [[ -n "$ROLES" ]]; then
    while IFS= read -r role; do
      [[ -z "$role" ]] && continue
      
      # Check if role exists
      if psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname = '$role';" 2>/dev/null | grep -q 1; then
        info "  Role '$role' already exists"
      else
        info "  Creating role: $role"
        psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
          -c "CREATE ROLE $role;" || {
          warn "Failed to create role '$role' (may need superuser privileges)"
        }
      fi
    done <<< "$ROLES"
  fi
fi

# --- Restore based on format ---
log "=== Restoring dump ==="
info "Source:       $DUMP_FILE"
info "Target DB:    $PGDATABASE"
info "Format:       $FORMAT"
info ""

case "$FORMAT" in
  custom)
    info "Using pg_restore for custom format dump..."
    pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
      --no-owner --no-acl \
      --verbose \
      "$DUMP_FILE" || {
      err "Restore failed"
      exit 1
    }
    ;;
  plain)
    info "Processing plain SQL dump..."
    
    # Create temporary processed file
    TEMP_SQL=$(mktemp)
    trap "rm -f $TEMP_SQL" EXIT
    
    info "Filtering dump for local restore..."
    
    # Process the dump file:
    # 1. Remove CREATE DATABASE (we're restoring to existing database)
    # 2. Remove ALTER DATABASE (database-specific settings)
    # 3. Replace \connect statements to use target database
    # 4. Replace OWNER TO <source-db> with OWNER TO <target-user> or remove
    # 5. Keep everything else
    
    sed -E "
      /^CREATE DATABASE/d
      /^ALTER DATABASE/d
      s/^\\\\connect [^[:space:]]+/\\\\connect $PGDATABASE/
      s/OWNER TO ${SOURCE_DB}/OWNER TO $PGUSER/g
    " "$DUMP_FILE" > "$TEMP_SQL" || {
      err "Failed to process dump file"
      exit 1
    }
    
    info "Restoring processed dump..."
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
      --set=client_encoding=UTF8 \
      -f "$TEMP_SQL" || {
      err "Restore failed"
      err ""
      err "You may need to:"
      err "  1. Create the source database role: CREATE ROLE ${SOURCE_DB};"
      err "  2. Or use --skip-role-check if roles are already created"
      exit 1
    }
    
    rm -f "$TEMP_SQL"
    ;;
  *)
    err "Unsupported format: $FORMAT"
    exit 1
    ;;
esac

info ""
info "✓ Dump restored successfully to database: $PGDATABASE"

exit 0
