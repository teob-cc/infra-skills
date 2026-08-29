#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PostgreSQL Table Restore Script
# ============================================================================
# Restores a single table from a PostgreSQL dump file.
# Supports both plain SQL and custom format dumps.
#
# Usage:
#   tools/k3s/postgres-restore-table.sh <dump-file> <table-name> [options]
#
# Options:
#   --host <host>             PostgreSQL host (default: localhost)
#   --port <port>             PostgreSQL port (default: 5432)
#   --user <user>             PostgreSQL user (default: postgres)
#   --database <db>           Target database name (required)
#   --password <pass>         PostgreSQL password (or use PGPASSWORD env var)
#   --drop-first              Drop table if it exists before restoring
#   --format <format>         Dump format: auto, plain, custom (default: auto)
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

# --- Defaults ---
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE=""
PGPASSWORD="${PGPASSWORD:-}"
DROP_FIRST=false
DUMP_FORMAT="auto"
TABLE_NAME=""
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
    --drop-first)
      DROP_FIRST=true
      shift
      ;;
    --format|-f)
      DUMP_FORMAT="$2"
      shift 2
      ;;
    --help)
      cat <<EOF
Usage: $0 <dump-file> <table-name> [options]

Arguments:
  <dump-file>                Path to the PostgreSQL dump file
  <table-name>               Name of the table to restore

Options:
  --host <host>              PostgreSQL host (default: localhost)
  --port <port>              PostgreSQL port (default: 5432)
  --user <user>              PostgreSQL user (default: postgres)
  --database <db>            Target database name (required)
  --password <pass>          PostgreSQL password (or use PGPASSWORD env var)
  --drop-first               Drop table if it exists before restoring
  --format <format>          Dump format: auto, plain, custom (default: auto)
  --help                     Show this help message

Examples:
  # Restore table from plain SQL dump
  $0 app-dump.sql station_view --database app --password postgres

  # Restore table from custom format dump
  $0 app-dump.dump station_view --database app --format custom

  # Restore with drop first
  $0 app-dump.sql station_view --database app --drop-first
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
      elif [[ -z "$TABLE_NAME" ]]; then
        TABLE_NAME="$1"
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

if [[ -z "$TABLE_NAME" ]]; then
  echo "ERROR: Table name is required" >&2
  exit 1
fi

if [[ -z "$PGDATABASE" ]]; then
  echo "ERROR: Database name is required (--database)" >&2
  exit 1
fi

if [[ ! -f "$DUMP_FILE" ]]; then
  echo "ERROR: Dump file not found: $DUMP_FILE" >&2
  exit 1
fi

# --- Logging helpers ---
log() { echo "[postgres-restore-table] $*"; }
info() { echo "[postgres-restore-table:info] $*"; }
warn() { echo "[postgres-restore-table:warn] $*" >&2; }
err() { echo "[postgres-restore-table:error] $*" >&2; }

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
      if head -c 5 "$DUMP_FILE" | grep -q "PGDMP"; then
        echo "custom"
      else
        echo "plain"
      fi
      ;;
  esac
}

FORMAT=$(detect_format)
info "Detected dump format: $FORMAT"

# --- Set PGPASSWORD if provided ---
if [[ -n "$PGPASSWORD" ]]; then
  export PGPASSWORD
fi

# --- Test connection ---
info "Testing database connection..."
if ! psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
  err "Cannot connect to database. Check connection parameters."
  exit 1
fi
info "✓ Connected to database: $PGDATABASE"

# --- Drop table if requested ---
if [[ "$DROP_FIRST" == "true" ]]; then
  info "Dropping table '$TABLE_NAME' if it exists..."
  psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
    -c "DROP TABLE IF EXISTS $TABLE_NAME CASCADE;" || {
    warn "Failed to drop table (may not exist)"
  }
fi

# --- Restore table based on format ---
log "=== Restoring table: $TABLE_NAME ==="

case "$FORMAT" in
  custom)
    info "Using pg_restore for custom format dump..."
    info "Extracting and restoring table..."
    
    # pg_restore with table filter
    pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
      --table="$TABLE_NAME" \
      --no-owner --no-acl \
      "$DUMP_FILE" || {
      err "Failed to restore table"
      exit 1
    }
    ;;
  plain)
    info "Extracting table from plain SQL dump..."
    
    # Create temporary file for table-specific SQL
    TEMP_SQL=$(mktemp)
    trap "rm -f $TEMP_SQL" EXIT
    
    # Extract table definition and data
    # This is a simplified extraction - may need adjustment for complex schemas
    info "Extracting CREATE TABLE statement..."
    grep -A 1000 "CREATE TABLE.*$TABLE_NAME" "$DUMP_FILE" | \
      grep -B 1000 -m 1 "^--" | head -n -1 > "$TEMP_SQL" || true
    
    # Extract COPY or INSERT statements for this table
    info "Extracting data statements..."
    grep -E "^(COPY|INSERT INTO).*$TABLE_NAME" "$DUMP_FILE" >> "$TEMP_SQL" || true
    
    # Extract table constraints and indexes
    info "Extracting constraints and indexes..."
    grep -E "(ALTER TABLE|CREATE.*INDEX).*$TABLE_NAME" "$DUMP_FILE" >> "$TEMP_SQL" || true
    
    # Check if we found anything
    if [[ ! -s "$TEMP_SQL" ]]; then
      err "No data found for table '$TABLE_NAME' in dump file"
      err "Available tables in dump:"
      grep -E "^CREATE TABLE|^COPY|^INSERT INTO" "$DUMP_FILE" | \
        sed -E 's/.*(TABLE|INTO) ([^ (]+).*/\2/' | sort -u | head -20
      exit 1
    fi
    
    info "Restoring table from extracted SQL..."
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
      -f "$TEMP_SQL" || {
      err "Failed to restore table"
      err "You may need to manually extract the table from the dump file"
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
info "✓ Table '$TABLE_NAME' restored successfully"

# --- Verify table exists and show row count ---
info "Verifying table..."
ROW_COUNT=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAc \
  "SELECT COUNT(*) FROM $TABLE_NAME;" 2>/dev/null || echo "0")

info "  Rows in table: $ROW_COUNT"

exit 0
