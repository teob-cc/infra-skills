#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Host-level backup provisioning (rdiff-backup to a remote backup host)
# ============================================================================
# Provisions backup infrastructure on bare-metal hosts:
# 1. Optionally creates a per-app user with home under /data/users
#    (see BACKUP_APP_USER below)
# 2. Creates backup-user (UID 11002) with SSH key for remote backups
# 3. Installs rdiff-backup and sqlite3
# 4. Installs the k3s-storage sweep, which leaves out every CloudNativePG volume
# 5. Installs the k3s server-state snapshot (see below)
# 6. Sets up daily cron: server state 05:45, backup 06:00, k3s-storage 06:15, increment
#    cleanup 06:30/06:35 (users repo ${BACKUP_USERS_RETENTION:-same as k3s}, k3s-storage
#    ${BACKUP_RETENTION:-30D}). These live in a marked block of root's crontab; any other entries
#    in it are kept.
#
# k3s server state (/usr/local/bin/k3s-server-state-snapshot, 05:45): a consistent copy of
# the datastore (sqlite .backup of kine's state.db, or k3s etcd-snapshot save on embedded
# etcd) plus server/token, server/tls/, server/cred/, server/manifests/ and /etc/rancher/k3s/,
# in a root-only (0700) dated dir under /data/users/k3s-server-state, the newest
# ${BACKUP_K3S_STATE_KEEP:-3} kept. The 06:00 rdiff takes it to the backup host.
# SECURITY: this puts the cluster CA private keys, the join token, the admin kubeconfig and
# the secrets-encryption key on the backup host. Anyone who can read the backup repo there
# can impersonate the cluster's API server and read every Secret in the datastore copy.
# That is the point (without server/cred/ an encrypted datastore restore cannot read a
# single Secret, and without tls/ every node and kubeconfig must be re-issued), so guard
# the backup host and its SSH key accordingly.
# On the backup host, pin each node's key to the rdiff-backup server, so a stolen key is no
# shell and reaches only the backup tree (Step 5 tests through that, not with a plain ssh):
#   restrict,command="<rdiff-backup> server --restrict-path <BACKUP_REMOTE_BASE>" ssh-ed25519 ...
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
#   BACKUP_K3S_EXCLUDES  # further PVC-dir globs to leave out of the k3s-storage
#                        # sweep, space-separated, e.g. "*_observability_prometheus-server"
#   BACKUP_K3S_STATE_KEEP  # dated k3s server-state copies kept on the node (default: 3)
#
# Every variable may also be set in the environment's env.properties, which wins
# over the shell environment.
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
# CloudNativePG volumes (live PGDATA) are not listed here: the sweep looks them up
# by their cnpg.io/cluster label at run time, whatever the cluster is called. A name
# glob covered only postgres-cluster and swept every other CNPG cluster's PGDATA.
K3S_STORAGE_EXCLUDES=(
  "${K3S_STORAGE_DIR}/*_observability_storage-loki-*" # logs are recreatable
  "${K3S_STORAGE_DIR}/*_harbor_data-harbor-trivy-*"   # CVE-DB cache
  "${K3S_STORAGE_DIR}/*_harbor_harbor-registry*"      # images rebuild from source in CI
)

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

# Read after load_env, so the values in env.properties take effect (read before it,
# they were silently ignored and only an exported shell variable worked).
# How long increments are kept on the backup target. rdiff-backup stores a full
# mirror plus reverse increments, so this bounds the increment tree, not the mirror:
# the latest state is always present regardless. Raise it if your recovery window
# is longer; at 90 days the increments can dwarf the mirror they serve.
BACKUP_RETENTION="${BACKUP_RETENTION:-30D}"
# The users repo may keep less: what it holds (DB dumps, the server-state snapshots) already
# has its own on-node retention, and a dump written under a dated name is a new file to rdiff,
# so every dump that ages out on the node is kept whole as an increment for the whole window
# (30 x a 10 GB dump = 300 GB). A short window here leaves the NAS with what the node keeps.
# Keep it at 2D or more: at 1D the 06:30 cleanup leaves no increment at all, rdiff-backup prunes
# the emptied increment dirs, and the next night it fails writing increments into them
# (rdiff-backup 2.2.6, "No such file or directory: .../increments/<dir>/<file>.missing").
BACKUP_USERS_RETENTION="${BACKUP_USERS_RETENTION:-$BACKUP_RETENTION}"
# --- Backup target (required; set these in your environment) ---
BACKUP_TARGET_HOST="${BACKUP_TARGET_HOST:-}"    # your NAS/backup host reachable over your VPN
BACKUP_TARGET_PORT="${BACKUP_TARGET_PORT:-22}"  # SSH port on the backup host
BACKUP_TARGET_USER="${BACKUP_TARGET_USER:-}"    # SSH user on the backup host
REMOTE_BACKUP_BASE="${BACKUP_REMOTE_BASE:-}"    # base dir for backup repos, e.g. /volume1/remote_backups
# rdiff-backup binary on the backup host; NAS appliances often install it
# outside the default PATH (e.g. /opt/bin/rdiff-backup).
REMOTE_RDIFF_BIN="${BACKUP_REMOTE_RDIFF:-rdiff-backup}"
read -r -a extra_excludes <<< "${BACKUP_K3S_EXCLUDES:-}"   # read -a splits without globbing
for pattern in ${extra_excludes[@]+"${extra_excludes[@]}"}; do
  K3S_STORAGE_EXCLUDES+=("${K3S_STORAGE_DIR}/${pattern}")
done

# --- Resolve SSH target ---
# Prefer Tailscale IP from env.properties, fall back to EXTERNAL_IP
SSH_HOST="${TAILSCALE_IP:-${EXTERNAL_IP}}"
ENV_DIR="${ENVS_ROOT}/${ENV_NAME}"
SECRETS_PLAIN="${ENV_DIR}/secrets.plain"
REMOTE_BACKUP_DIR="${REMOTE_BACKUP_BASE}/${ENV_NAME}"
REMOTE_K3S_BACKUP_DIR="${REMOTE_BACKUP_BASE}/${ENV_NAME}-k3s-storage"

RDIFF_SCHEMA="ssh -p ${BACKUP_TARGET_PORT} -i ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519 %s ${REMOTE_RDIFF_BIN} --server"
K3S_SWEEP="/usr/local/bin/nas-backup-k3s-storage"
# k3s server state (see the header): snapshot script, its root-only target under DATA_DIR.
K3S_STATE_SNAPSHOT="/usr/local/bin/k3s-server-state-snapshot"
K3S_STATE_DIR="${DATA_DIR}/k3s-server-state"
K3S_STATE_KEEP="${BACKUP_K3S_STATE_KEEP:-3}"
[[ "$K3S_STATE_KEEP" =~ ^[1-9][0-9]*$ ]] || { echo "BACKUP_K3S_STATE_KEEP must be a positive integer" >&2; exit 1; }
# Marks the part of root's crontab this script owns; everything outside it is left alone.
CRON_BEGIN="# BEGIN infra-skills backup.sh (managed block, re-run tools/backup.sh to change)"
CRON_END="# END infra-skills backup.sh"

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
    echo
    echo \"=== k3s server state (${K3S_STATE_DIR}) ===\"
    ls -la ${K3S_STATE_DIR}/ 2>/dev/null || echo \"not present\"
  '"
  exit 0
fi

# --- Run backup now ---
if $RUN_NOW; then
  log "Running backup now for ${ENV_NAME} ..."
  if remote "test -x ${K3S_STATE_SNAPSHOT}"; then
    log "  k3s server state -> ${K3S_STATE_DIR}"
    remote "${K3S_STATE_SNAPSHOT}" || err "k3s server-state snapshot failed; continuing with the rdiff"
  else
    warn "${K3S_STATE_SNAPSHOT} is not installed; run $0 ${ENV_NAME} first."
  fi
  log "  /data/users -> ${REMOTE_BACKUP_DIR}"
  remote "rdiff-backup --remote-schema '${RDIFF_SCHEMA}' ${DATA_DIR} ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_BACKUP_DIR} && /usr/local/bin/nas-backup-stamp ${ENV_NAME}"
  if ! remote "test -x ${K3S_SWEEP}"; then
    err "${K3S_SWEEP} is not installed; run $0 ${ENV_NAME} first."
    exit 1
  fi
  log "  ${K3S_STORAGE_DIR} -> ${REMOTE_K3S_BACKUP_DIR}"
  remote "${K3S_SWEEP}"
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
# sqlite3 takes the consistent copy of kine's state.db (Step 3d); not skippable with the above.
remote bash -c "'command -v sqlite3 >/dev/null || { apt-get update -qq && apt-get install -y -qq sqlite3; }'"

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
# node-exporter reads this as non-root; callers may run under umask 077 (the k3s state snapshot).
chmod 644 "${f}.tmp"
mv "${f}.tmp" "${f}"
HELPER
remote "cat > /usr/local/bin/nas-backup-stamp && chmod 755 /usr/local/bin/nas-backup-stamp && mkdir -p ${TEXTFILE_DIR}" < "$STAMP_HELPER_TMP"
rm -f "$STAMP_HELPER_TMP"
info "Stamp helper installed; metrics dir ${TEXTFILE_DIR}."

# --- Step 3c: Install the k3s-storage sweep ---
# The CNPG volumes are looked up when the sweep runs, not when this script runs, so
# a Postgres cluster created later is left out as well. A failed lookup fails the
# sweep (and the NasBackupStale alert fires) rather than shipping live PGDATA.
log "Step 3c: Installing k3s-storage sweep ${K3S_SWEEP} ..."
static_excludes=""
for pattern in "${K3S_STORAGE_EXCLUDES[@]}"; do
  static_excludes+=" '${pattern}'"
done
SWEEP_TMP=$(mktemp)
sweep=$(cat << 'SWEEP'
#!/bin/sh
# nas-backup-k3s-storage — rdiff the k3s PVC root to the backup host.
# Installed by infra-skills/tools/backup.sh; run by root's crontab.
set -euf
src="@SRC@"
[ -d "$src" ] || { echo "$src not present, nothing to back up"; exit 0; }
cnpg=$(k3s kubectl get pvc -A -l cnpg.io/cluster \
  -o jsonpath='{range .items[*]}{.spec.volumeName}_{.metadata.namespace}_{.metadata.name}{"\n"}{end}')
set --
for d in $cnpg; do set -- "$@" --exclude "$src/$d"; done
for g in @EXCLUDES@; do set -- "$@" --exclude "$g"; done
rdiff-backup "$@" --remote-schema '@SCHEMA@' "$src" '@DEST@'
/usr/local/bin/nas-backup-stamp '@REPO@'
SWEEP
)
sweep=${sweep//@SRC@/$K3S_STORAGE_DIR}
sweep=${sweep//@EXCLUDES@/$static_excludes}
sweep=${sweep//@SCHEMA@/$RDIFF_SCHEMA}
sweep=${sweep//@DEST@/${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_K3S_BACKUP_DIR}}
sweep=${sweep//@REPO@/${ENV_NAME}-k3s-storage}
printf '%s\n' "$sweep" > "$SWEEP_TMP"
remote "cat > ${K3S_SWEEP} && chmod 755 ${K3S_SWEEP}" < "$SWEEP_TMP"
rm -f "$SWEEP_TMP"
info "Sweep installed; excluded now: $(remote "k3s kubectl get pvc -A -l cnpg.io/cluster -o name | wc -l") CNPG volume(s) plus ${#K3S_STORAGE_EXCLUDES[@]} glob(s)."

# --- Step 3d: Install the k3s server-state snapshot ---
# See the header: the datastore, CA keys, token and secrets-encryption key, into a root-only
# dir the 06:00 rdiff picks up. The datastore is never copied as a live file: sqlite's online
# backup (or an etcd snapshot) gives a consistent point in time, a plain cp of state.db plus
# its -wal does not. A failure stamps nothing, so NasBackupStale fires for the repo
# <env>-k3s-server-state after 26h.
log "Step 3d: Installing k3s server-state snapshot ${K3S_STATE_SNAPSHOT} ..."
STATE_TMP=$(mktemp)
state_script=$(cat << 'STATE'
#!/bin/sh
# k3s-server-state-snapshot — consistent copy of the k3s server state for the nightly rdiff.
# Installed by infra-skills/tools/backup.sh; run by root's crontab at 05:45.
# The copy holds the cluster CA private keys (tls/), the join token, the admin kubeconfig
# (etc-rancher-k3s/k3s.yaml) and the secrets-encryption key (cred/encryption-config.json):
# it is root-only here and must be guarded on the backup host as well.
# Restore outline: stop k3s; put tls/, cred/, token back under /var/lib/rancher/k3s/server/,
# the datastore back as db/state.db (gunzip) or via k3s server --cluster-reset
# --cluster-reset-restore-path=<snapshot> (etcd); config from etc-rancher-k3s/; start k3s.
set -eu
umask 077
srv=/var/lib/rancher/k3s/server
dest='@DEST@'
keep='@KEEP@'
[ -d "$srv" ] || { echo "$srv not present (not a k3s server), nothing to snapshot"; exit 0; }
mkdir -p "$dest"
chmod 700 "$dest"
day=$(date +%Y-%m-%d)
work="$dest/.partial-$day"
rm -rf "$work"
mkdir "$work"
if [ -d "$srv/db/etcd/member" ]; then
  k3s etcd-snapshot save --dir "$work" --name k3s-state >/dev/null
elif [ -f "$srv/db/state.db" ]; then
  sqlite3 "$srv/db/state.db" ".backup '$work/state.db'"
  # The copy inherits WAL mode; switch it to a single self-contained file before checking it.
  check=$(sqlite3 "$work/state.db" 'PRAGMA journal_mode=DELETE; PRAGMA integrity_check;' | tail -n 1)
  rm -f "$work/state.db-wal" "$work/state.db-shm"
  [ "$check" = ok ] || { echo "integrity_check of the copy failed: $check" >&2; exit 1; }
  gzip -1 "$work/state.db"
else
  echo "no datastore under $srv/db (neither etcd/member nor state.db)" >&2
  exit 1
fi
cp -a "$srv/token" "$srv/tls" "$srv/cred" "$srv/manifests" "$work/"
[ -d /etc/rancher/k3s ] && cp -a /etc/rancher/k3s "$work/etc-rancher-k3s"
rm -rf "${dest:?}/$day"
mv "$work" "$dest/$day"
ls -1d "$dest"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] | sort -r | tail -n +"$((keep + 1))" | while read -r old; do
  rm -rf "$old"
done
/usr/local/bin/nas-backup-stamp '@REPO@'
STATE
)
state_script=${state_script//@DEST@/$K3S_STATE_DIR}
state_script=${state_script//@KEEP@/$K3S_STATE_KEEP}
state_script=${state_script//@REPO@/${ENV_NAME}-k3s-server-state}
printf '%s\n' "$state_script" > "$STATE_TMP"
remote "cat > ${K3S_STATE_SNAPSHOT} && chmod 700 ${K3S_STATE_SNAPSHOT}" < "$STATE_TMP"
rm -f "$STATE_TMP"
info "Snapshot installed: ${K3S_STATE_DIR}/<date>, newest ${K3S_STATE_KEEP} kept (holds the cluster CA keys and the secrets-encryption key)."

# --- Step 4: Configure cron ---
log "Step 4: Setting up cron jobs ..."

# In crontab, % means newline — must be escaped as \%
RDIFF_SCHEMA_CRON="${RDIFF_SCHEMA//%/\\%}"

# The schedule, as the block this script owns in root's crontab.
CRON_BLOCK="${CRON_BEGIN}
# k3s server state (datastore, CA keys, token, secrets-encryption key) into ${K3S_STATE_DIR} at 05:45
45 5 * * * ${K3S_STATE_SNAPSHOT}

# Backup ${DATA_DIR} to the backup host over the VPN at 06:00
0 6 * * * rdiff-backup --remote-schema '${RDIFF_SCHEMA_CRON}' ${DATA_DIR} ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_BACKUP_DIR} && /usr/local/bin/nas-backup-stamp ${ENV_NAME}

# Backup ${K3S_STORAGE_DIR} (Nexus, Grafana, app volumes, etc.) at 06:15.
# Excludes live PGDATA (use pg_dump), Loki logs, Trivy cache, and Harbor blobs.
15 6 * * * ${K3S_SWEEP}

# Remove increments older than ${BACKUP_USERS_RETENTION} (users) and ${BACKUP_RETENTION} (k3s-storage) at 06:30/06:35
30 6 * * * rdiff-backup --remove-older-than ${BACKUP_USERS_RETENTION} --remote-schema '${RDIFF_SCHEMA_CRON}' --force ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_BACKUP_DIR}
35 6 * * * rdiff-backup --remove-older-than ${BACKUP_RETENTION} --remote-schema '${RDIFF_SCHEMA_CRON}' --force ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_K3S_BACKUP_DIR}
${CRON_END}"

# Merge it into root's crontab instead of replacing the crontab: the old block is swapped
# for the new one, every other entry stays. Lines an older backup.sh wrote without markers
# (they name the backup target or the sweep, or carry its comments) are dropped once, so
# the first run with markers does not double the schedule.
CRON_MERGE_TMP=$(mktemp)
{
  printf '%s\n' "set -eu" "block=\$(cat <<'CRON_BLOCK_EOF'"
  printf '%s\n' "$CRON_BLOCK"
  printf '%s\n' "CRON_BLOCK_EOF" ")"
  printf "begin='%s' end='%s' target='%s' sweep='%s'\n" "$CRON_BEGIN" "$CRON_END" \
    "${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_BACKUP_BASE}" "$K3S_SWEEP"
  cat <<'MERGE'
kept=$( (crontab -l 2>/dev/null || true) | awk -v b="$begin" -v e="$end" -v t="$target" -v s="$sweep" '
  $0 == b { skip = 1; next }
  $0 == e { skip = 0; next }
  skip { next }
  index($0, t) || index($0, s) { next }
  /^# (Backup \/data\/|Excludes live PGDATA|Remove increments older than)/ { next }
  { print }' | cat -s | sed '/./,$!d')
{ if [ -n "$kept" ]; then printf '%s\n\n' "$kept"; fi; printf '%s\n' "$block"; } | crontab -
MERGE
} > "$CRON_MERGE_TMP"
remote "bash -s" < "$CRON_MERGE_TMP"
rm -f "$CRON_MERGE_TMP"

info "Cron jobs installed."
remote crontab -l

# --- Step 5: Test SSH connectivity to the backup host ---
log "Step 5: Testing SSH connectivity to the backup host ..."
# Through rdiff-backup itself: a key pinned to the rdiff-backup server (see the header) runs no
# 'echo', so a plain ssh test would report a working key as broken.
TEST_SCHEMA="ssh -p ${BACKUP_TARGET_PORT} -i ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 %s ${REMOTE_RDIFF_BIN} --server"
if remote "rdiff-backup --remote-schema '${TEST_SCHEMA}' test ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}::${REMOTE_BACKUP_BASE}" 2>/dev/null | grep -q 'Server OK'; then
  info "SSH to backup host: OK"
else
  warn "SSH to backup host failed. Ensure the public key is in ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}:~/.ssh/authorized_keys"
  warn "Public key: $(cat "$SSH_PUB_FILE" 2>/dev/null || remote "cat ${DATA_DIR}/${BACKUP_USER}/.ssh/id_ed25519.pub")"
fi

echo
log "Backup provisioning complete for ${ENV_NAME}."
log "  Backup user:    ${BACKUP_USER} (UID ${BACKUP_UID})"
log "  Sources:        ${DATA_DIR} (incl. ${K3S_STATE_DIR}), ${K3S_STORAGE_DIR} (excl. live PGDATA, Loki, Trivy)"
log "  Remote (users): ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}:${REMOTE_BACKUP_DIR}"
log "  Remote (k3s):   ${BACKUP_TARGET_USER}@${BACKUP_TARGET_HOST}:${REMOTE_K3S_BACKUP_DIR}"
log "  Schedule:       daily 05:45 (k3s server state), 06:00 (users), 06:15 (k3s-storage), 06:30/35 (cleanup users ${BACKUP_USERS_RETENTION}, k3s ${BACKUP_RETENTION})"
log ""
log "To run a backup now:  $0 ${ENV_NAME} --run-now"
log "To check status:      $0 ${ENV_NAME} --show-status"
