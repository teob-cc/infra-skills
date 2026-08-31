#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Host-level backup provisioning (rdiff-backup to a remote backup host)
# ============================================================================
# Provisions backup infrastructure on bare-metal hosts:
# 1. Optionally creates a per-app user with home under /data/users
#    (see BACKUP_APP_USER below)
# 2. Creates backup-user (UID 11002) with SSH key for remote backups
# 3. Installs rdiff-backup
# 4. Sets up daily cron: backup at 06:00, increment cleanup (${BACKUP_RETENTION:-30D}) at 06:30
#
# The backup runs over your VPN directly to the backup host (no SSH tunnel).
#
# Required configuration (environment variables — no defaults shipped):
#   BACKUP_TARGET_HOST   # your NAS/backup host reachable over your VPN
#   BACKUP_TARGET_USER   # SSH user on the backup host
#   BACKUP_REMOTE_BASE   # base dir for backup repos on the backup host
#                        # (e.g. /volume1/remote_backups on a NAS)
# Optional configuration:
#   BACKUP_TARGET_PORT   # SSH port on the backup host (default: 22)
#   BACKUP_REMOTE_RDIFF  # rdiff-backup binary path on the backup host
#                        # (default: rdiff-backup; NAS appliances often
#                        #  install it at e.g. /opt/bin/rdiff-backup)
#   BACKUP_APP_USER      # per-app user to create (e.g. "myapp"); skipped
#   BACKUP_APP_UID       #   if unset (e.g. 1002)
#
# Usage:
#   tools/backup.sh <env-name> [options]
#
# Options:
#   --skip-users           Skip user creation (already exist)
#   --skip-rdiff-backup    Skip rdiff-backup installation
#   --show-status          Show backup status and exit
#   --run-now              Run backup immediately
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

# --- Configuration ---
BACKUP_USER="backup-user"
BACKUP_UID=11002
# Optional per-app user whose data lives under /data/users.
# Example: BACKUP_APP_USER=myapp BACKUP_APP_UID=1002. Skipped when unset.
APP_USER="${BACKUP_APP_USER:-}"
APP_UID="${BACKUP_APP_UID:-}"
DATA_DIR="/data/users"
# k3s local-path PVC root (where Harbor registry, Nexus, Grafana, etc. live).
# Live Postgres PGDATA is excluded — back that up via pg_dump instead.
K3S_STORAGE_DIR="/data/k3s-storage"
# Glob fragments matched against PVC dir names under $K3S_STORAGE_DIR.
# rdiff-backup --exclude takes shell globs against the source root.
K3S_STORAGE_EXCLUDES=(
  "${K3S_STORAGE_DIR}/*_postgres_postgres-cluster-*"  # live PGDATA — use pg_dump
  "${K3S_STORAGE_DIR}/*_observability_storage-loki-*" # logs are recreatable
  "${K3S_STORAGE_DIR}/*_harbor_data-harbor-trivy-*"   # CVE-DB cache
  "${K3S_STORAGE_DIR}/*_harbor_harbor-registry*"      # images rebuild from source in CI
)

# How long increments are kept on the backup target. rdiff-backup stores a full
# mirror plus reverse increments, so this bounds the increment tree, not the mirror:
# the latest state is always present regardless. Raise it if your recovery window
# is longer; at 90 days the increments can dwarf the mirror they serve.
BACKUP_RETENTION="${BACKUP_RETENTION:-30D}"
# --- Backup target (required; set these in your environment) ---
BACKUP_TARGET_HOST="${BACKUP_TARGET_HOST:-}"    # your NAS/backup host reachable over your VPN
BACKUP_TARGET_PORT="${BACKUP_TARGET_PORT:-22}"  # SSH port on the backup host
BACKUP_TARGET_USER="${BACKUP_TARGET_USER:-}"    # SSH user on the backup host
REMOTE_BACKUP_BASE="${BACKUP_REMOTE_BASE:-}"    # base dir for backup repos, e.g. /volume1/remote_backups
# rdiff-backup binary on the backup host; NAS appliances often install it
# outside the default PATH (e.g. /opt/bin/rdiff-backup).
REMOTE_RDIFF_BIN="${BACKUP_REMOTE_RDIFF:-rdiff-backup}"

# --- Parse arguments ---
if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--skip-users] [--skip-rdiff-backup] [--show-status] [--run-now]" >&2
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

SKIP_USERS=false
SKIP_RDIFF=false
SHOW_STATUS=false
RUN_NOW=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-users) SKIP_USERS=true; shift ;;
    --skip-rdiff-backup) SKIP_RDIFF=true; shift ;;
    --show-status) SHOW_STATUS=true; shift ;;
    --run-now) RUN_NOW=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Resolve SSH target ---
# Prefer Tailscale IP from env.properties, fall back to EXTERNAL_IP
SSH_HOST="${TAILSCALE_IP:-${EXTERNAL_IP}}"
ENV_DIR="${ENVS_ROOT}/${ENV_NAME}"
SECRETS_PLAIN="${ENV_DIR}/secrets.plain"
REMOTE_BACKUP_DIR="${REMOTE_BACKUP_BASE}/${ENV_NAME}"
REMOTE_K3S_BACKUP_DIR="${REMOTE_BACKUP_BASE}/${ENV_NAME}-k3s-storage"

# Build the rdiff-backup --exclude flags for the k3s-storage sweep.
RDIFF_EXCLUDES=""
for pattern in "${K3S_STORAGE_EXCLUDES[@]}"; do
  RDIFF_EXCLUDES+=" --exclude '${pattern}'"
done

log()  { echo "[backup] $*"; }
info() { echo "[backup:info] $*"; }
warn() { echo "[backup:warn] $*" >&2; }
err()  { echo "[backup:error] $*" >&2; }

# --- Fail early when the backup target is not configured ---
MISSING_VARS=()
[[ -n "$BACKUP_TARGET_HOST" ]] || MISSING_VARS+=(BACKUP_TARGET_HOST)
[[ -n "$BACKUP_TARGET_USER" ]] || MISSING_VARS+=(BACKUP_TARGET_USER)
[[ -n "$REMOTE_BACKUP_BASE" ]] || MISSING_VARS+=(BACKUP_REMOTE_BASE)
if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
  err "Backup target is not configured. Missing: ${MISSING_VARS[*]}"
  err "Set the backup-target variables in your environment, e.g.:"
  err "  BACKUP_TARGET_HOST=<vpn-ip-of-your-backup-host> \\"
  err "  BACKUP_TARGET_USER=<ssh-user-on-backup-host> \\"
  err "  BACKUP_REMOTE_BASE=/volume1/remote_backups \\"
  err "  $0 ${ENV_NAME}"
  exit 1
fi

remote() {
  ssh -o StrictHostKeyChecking=accept-new "root@${SSH_HOST}" "$@"
}

# --- Show status ---
if $SHOW_STATUS; then
  log "Backup status for ${ENV_NAME} (${SSH_HOST}):"
  echo
  remote bash -c "'
    echo \"=== Users ===\"
    for u in ${BACKUP_USER} ${APP_USER}; do
      id \$u 2>/dev/null || echo \"\$u: not found\"
    done
    echo
    echo \"=== rdiff-backup ===\"
    which rdiff-backup 2>/dev/null && rdiff-backup --version || echo \"not installed\"
    echo
    echo \"=== Cron ===\"
    crontab -l 2>/dev/null || echo \"no crontab\"
    echo
    echo \"=== /data/users ===\"
    ls -la ${DATA_DIR}/ 2>/dev/null || echo \"${DATA_DIR} does not exist\"
    echo
    echo \"=== Backup SSH key ===\"
    ls -la ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519 2>/dev/null || echo \"no SSH key\"
  '"
  exit 0
fi

# --- Run backup now ---
if $RUN_NOW; then
  RDIFF_SCHEMA="ssh -p ${BACKUP_TARGET_PORT} -i ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519 %s ${REMOTE_RDIFF_BIN} --server"
  log "Running backup now for ${ENV_NAME} ..."
  log "  /data/users -> ${REMOTE_BACKUP_DIR}"
  remote "rdiff-backup --remote-schema '${RDIFF_SCHEMA}' ${DATA_DIR} ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_BACKUP_DIR} && /usr/local/bin/nas-backup-stamp ${ENV_NAME}"
  if remote "test -d ${K3S_STORAGE_DIR}"; then
    log "  ${K3S_STORAGE_DIR} -> ${REMOTE_K3S_BACKUP_DIR}"
    remote "rdiff-backup ${RDIFF_EXCLUDES} --remote-schema '${RDIFF_SCHEMA}' ${K3S_STORAGE_DIR} ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_K3S_BACKUP_DIR} && /usr/local/bin/nas-backup-stamp ${ENV_NAME}-k3s-storage"
  else
    warn "${K3S_STORAGE_DIR} not present on host — skipping k3s-storage backup."
  fi
  log "Backup complete."
  exit 0
fi

# --- Step 1: Create users ---
if ! $SKIP_USERS; then
  log "Step 1: Creating users on ${SSH_HOST} ..."

  # Per-app user example: apps that keep host-level data under /data/users
  # get their own user so the backup sweep picks their files up with sane
  # ownership. Configure via BACKUP_APP_USER / BACKUP_APP_UID.
  if [[ -n "$APP_USER" && -n "$APP_UID" ]]; then
    remote bash -c "'
      mkdir -p ${DATA_DIR}
      if id ${APP_USER} &>/dev/null; then
        echo \"User ${APP_USER} already exists\"
      else
        useradd -u ${APP_UID} -d ${DATA_DIR}/${APP_USER} -m -s /bin/bash ${APP_USER}
        echo \"Created user ${APP_USER} (UID ${APP_UID})\"
      fi
    '"
  fi

  remote bash -c "'
    mkdir -p ${DATA_DIR}

    if id ${BACKUP_USER} &>/dev/null; then
      echo \"User ${BACKUP_USER} already exists\"
    else
      useradd -u ${BACKUP_UID} -d ${DATA_DIR}/${BACKUP_USER} -m -s /bin/bash ${BACKUP_USER}
      echo \"Created user ${BACKUP_USER} (UID ${BACKUP_UID})\"
    fi
  '"
  info "Users ready."
else
  info "Skipping user creation."
fi

# --- Step 2: Deploy SSH key for backup-user ---
log "Step 2: Deploying backup SSH key ..."

SSH_KEY_FILE="${SECRETS_PLAIN}/backup-ssh-id_ed25519"
SSH_PUB_FILE="${SECRETS_PLAIN}/backup-ssh-id_ed25519.pub"

if [[ ! -f "$SSH_KEY_FILE" ]]; then
  warn "SSH key not found at ${SSH_KEY_FILE}"
  warn "Generating new key pair ..."
  remote bash -c "'
    su - ${BACKUP_USER} -c \"mkdir -p ~/.ssh && chmod 700 ~/.ssh\"
    if [[ ! -f ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519 ]]; then
      su - ${BACKUP_USER} -c \"ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N \\\"\\\"\"
    fi
  '"
  # Retrieve generated key for local storage
  mkdir -p "$(dirname "$SSH_KEY_FILE")"
  remote "cat ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519" > "$SSH_KEY_FILE"
  remote "cat ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519.pub" > "$SSH_PUB_FILE"
  chmod 600 "$SSH_KEY_FILE"
  warn "Keys saved to ${SECRETS_PLAIN}/. Run sops/encrypt.sh to encrypt them."
else
  # Deploy existing key
  remote bash -c "'
    su - ${BACKUP_USER} -c \"mkdir -p ~/.ssh && chmod 700 ~/.ssh\"
  '"
  cat "$SSH_KEY_FILE" | remote "tee ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519 > /dev/null && chmod 600 ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519 && chown ${BACKUP_USER}:${BACKUP_USER} ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519"
  if [[ -f "$SSH_PUB_FILE" ]]; then
    cat "$SSH_PUB_FILE" | remote "tee ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519.pub > /dev/null && chown ${BACKUP_USER}:${BACKUP_USER} ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519.pub"
  fi
  info "SSH key deployed."
fi

# --- Step 3: Install rdiff-backup ---
if ! $SKIP_RDIFF; then
  log "Step 3: Installing rdiff-backup ..."
  remote bash -c "'
    if command -v rdiff-backup &>/dev/null; then
      echo \"rdiff-backup already installed: \$(rdiff-backup --version)\"
    else
      apt-get update -qq && apt-get install -y -qq rdiff-backup
      echo \"Installed rdiff-backup \$(rdiff-backup --version)\"
    fi
  '"
  info "rdiff-backup ready."
else
  info "Skipping rdiff-backup installation."
fi

# --- Step 3b: Install the NAS-sync success-stamp helper ---
# Each successful rdiff cron stamps a timestamp metric into node-exporter's
# textfile collector dir; the NasBackupStale alert (tools/k3s/observability.sh,
# group infra-backup) fires when a repo's stamp goes stale. Without this the
# crons fail silently — there is no MTA on the nodes, so a broken sync can go
# unnoticed for weeks.
TEXTFILE_DIR="/var/lib/node_exporter/textfile"
log "Step 3b: Installing NAS backup stamp helper ..."
STAMP_HELPER_TMP=$(mktemp)
cat > "$STAMP_HELPER_TMP" << 'HELPER'
#!/bin/sh
# nas-backup-stamp <repo> — record a successful NAS rdiff sync for Prometheus.
# Installed by infra-skills/tools/backup.sh; scraped via node-exporter's
# textfile collector; watched by the NasBackupStale alert.
set -eu
repo="$1"
dir="/var/lib/node_exporter/textfile"
mkdir -p "$dir"
f="${dir}/nas_backup_${repo}.prom"
echo "nas_backup_last_success_timestamp_seconds{repo=\"${repo}\"} $(date +%s)" > "${f}.tmp"
mv "${f}.tmp" "${f}"
HELPER
remote "cat > /usr/local/bin/nas-backup-stamp && chmod 755 /usr/local/bin/nas-backup-stamp && mkdir -p ${TEXTFILE_DIR}" < "$STAMP_HELPER_TMP"
rm -f "$STAMP_HELPER_TMP"
info "Stamp helper installed; metrics dir ${TEXTFILE_DIR}."

# --- Step 4: Configure cron ---
log "Step 4: Setting up cron jobs ..."

RDIFF_SCHEMA="ssh -p ${BACKUP_TARGET_PORT} -i ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519 %s ${REMOTE_RDIFF_BIN} --server"
# In crontab, % means newline — must be escaped as \%
RDIFF_SCHEMA_CRON="${RDIFF_SCHEMA//%/\\%}"

remote bash -c "\"cat > /tmp/backup-crontab.txt << 'CRON'
# Backup ${DATA_DIR} to the backup host over the VPN at 06:00
0 6 * * * rdiff-backup --remote-schema '${RDIFF_SCHEMA_CRON}' ${DATA_DIR} ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_BACKUP_DIR} && /usr/local/bin/nas-backup-stamp ${ENV_NAME}

# Backup ${K3S_STORAGE_DIR} (Harbor blobs, Nexus, Grafana, etc.) at 06:15.
# Excludes live PGDATA (use pg_dump), Loki logs, Trivy cache, and Harbor blobs.
15 6 * * * [ -d ${K3S_STORAGE_DIR} ] && rdiff-backup ${RDIFF_EXCLUDES} --remote-schema '${RDIFF_SCHEMA_CRON}' ${K3S_STORAGE_DIR} ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_K3S_BACKUP_DIR} && /usr/local/bin/nas-backup-stamp ${ENV_NAME}-k3s-storage

# Remove increments older than ${BACKUP_RETENTION} at 06:30
30 6 * * * rdiff-backup --remove-older-than ${BACKUP_RETENTION} --remote-schema '${RDIFF_SCHEMA_CRON}' --force ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_BACKUP_DIR}
35 6 * * * rdiff-backup --remove-older-than ${BACKUP_RETENTION} --remote-schema '${RDIFF_SCHEMA_CRON}' --force ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_K3S_BACKUP_DIR}
CRON
crontab /tmp/backup-crontab.txt && rm /tmp/backup-crontab.txt\""

info "Cron jobs installed."
remote crontab -l

# --- Step 5: Test SSH connectivity to the backup host ---
log "Step 5: Testing SSH connectivity to the backup host ..."
if remote "ssh -p ${BACKUP_TARGET_PORT} -i ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST} 'echo OK'" 2>/dev/null | grep -q OK; then
  info "SSH to backup host: OK"
else
  warn "SSH to backup host failed. Ensure the public key is in ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}:~/.ssh/authorized_keys"
  warn "Public key: $(cat "$SSH_PUB_FILE" 2>/dev/null || remote "cat ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519.pub")"
fi

echo
log "Backup provisioning complete for ${ENV_NAME}."
log "  Backup user:    ${BACKUP_USER} (UID ${BACKUP_UID})"
log "  Sources:        ${DATA_DIR}, ${K3S_STORAGE_DIR} (excl. live PGDATA, Loki, Trivy)"
log "  Remote (users): ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}:${REMOTE_BACKUP_DIR}"
log "  Remote (k3s):   ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}:${REMOTE_K3S_BACKUP_DIR}"
log "  Schedule:       daily 06:00 (users), 06:15 (k3s-storage), 06:30/35 (cleanup ${BACKUP_RETENTION})"
log ""
log "To run a backup now:  $0 ${ENV_NAME} --run-now"
log "To check status:      $0 ${ENV_NAME} --show-status"
