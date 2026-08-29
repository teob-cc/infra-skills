#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# K3S ScyllaDB Provisioning (Scylla Operator)
# ============================================================================
# Provisions a single-node ScyllaDB instance (Cassandra API) for the
# kafka-journal persistence stack:
# 1. Scylla operator (Helm chart scylla/scylla-operator; requires cert-manager)
# 2. Static local PV on /data/scylla (data); snapshot staging dir under
#    /data/users/scylla-backups (PV/PVC owned by the scylla-backup chart)
# 3. ScyllaCluster CR: 1 member, developerMode, PasswordAuthenticator,
#    native Prometheus metrics :9180
# 4. scylla-metrics Service for Prometheus endpoint discovery
# 5. cassandra-web UI behind Pomerium (cassandra.<env>, pgweb pattern)
#
# Usage:
#   tools/k3s/scylla.sh <env-name> [options]
#
# Options:
#   --skip-operator          Skip operator installation (use existing)
#   --skip-web               Skip cassandra-web UI installation
#   --force-cleanup          Remove ScyllaCluster CR + operator before reinstalling
#   --show-credentials [app-id]  Display Cassandra credentials and exit
#   --show-resources         Display current Scylla resource usage and exit
#   --watch [kind]           Inspect a running cluster (kind: help|status|compactions|logs)
#   --provision-credentials <app-id>  Provision role + keyspace for an application
#   --snapshot-now           nodetool snapshot + tar to the staging PV (backup primitive)
#   --impl <impl>            Implementation seam: scylla (default) | k8ssandra (reserved)
#
# Sizing (cit defaults; prod overrides via env vars):
#   SCYLLA_STORAGE_SIZE=150Gi SCYLLA_MEMORY_LIMIT=5Gi tools/k3s/scylla.sh prod
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

# --- Parse arguments ---
if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--skip-operator] [--skip-web] [--force-cleanup] [--show-credentials [app-id]] [--show-resources] [--watch [kind]] [--provision-credentials <app-id>] [--snapshot-now] [--impl <impl>]" >&2
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

SKIP_OPERATOR=false
SKIP_WEB=false
FORCE_CLEANUP=false
SHOW_CREDENTIALS=false
SHOW_CREDENTIALS_APP_ID=""
SHOW_RESOURCES=false
WATCH=false
WATCH_KIND="help"
PROVISION_CREDENTIALS=false
APP_ID=""
SNAPSHOT_NOW=false
IMPL="scylla"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-operator) SKIP_OPERATOR=true; shift ;;
    --skip-web) SKIP_WEB=true; shift ;;
    --force-cleanup) FORCE_CLEANUP=true; shift ;;
    --show-credentials)
      SHOW_CREDENTIALS=true
      if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
        SHOW_CREDENTIALS_APP_ID="$2"; shift 2
      else
        shift
      fi
      ;;
    --show-resources) SHOW_RESOURCES=true; shift ;;
    --watch)
      WATCH=true
      if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
        WATCH_KIND="$2"; shift 2
      else
        WATCH_KIND="help"; shift
      fi
      ;;
    --provision-credentials)
      PROVISION_CREDENTIALS=true
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --provision-credentials requires an app-id argument" >&2
        exit 1
      fi
      APP_ID="$2"; shift 2
      ;;
    --snapshot-now) SNAPSHOT_NOW=true; shift ;;
    --impl)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --impl requires an argument (scylla|k8ssandra)" >&2
        exit 1
      fi
      IMPL="$2"; shift 2
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$IMPL" != "scylla" ]]; then
  echo "ERROR: --impl ${IMPL} is reserved but not implemented." >&2
  echo "Only 'scylla' is supported today; 'k8ssandra' is the design fallback" >&2
  echo "(see docs/KAFKA-JOURNAL-OPS.md)." >&2
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

if ! provision::validate_kubectl_context; then
  exit 1
fi

# --- Logging helpers ---
log() { echo "[scylla] $*"; }
info() { echo "[scylla:info] $*"; }
warn() { echo "[scylla:warn] $*" >&2; }
err() { echo "[scylla:error] $*" >&2; }

# --- Config defaults ---
: "${NAMESPACE_SCYLLA_OPERATOR:=scylla-operator}"
: "${NAMESPACE_SCYLLA:=scylla}"
# Operator chart version pinned 2026-07-19: helm search repo scylla/scylla-operator --versions
: "${SCYLLA_OPERATOR_VERSION:=v1.21.0}"
# Same 2025.1 line as the kafka-journal clone-platform spike; pinned to a patch
: "${SCYLLA_IMAGE_TAG:=2025.1.14}"
: "${SCYLLA_AGENT_VERSION:=3.11.2}"
: "${SCYLLA_STORAGE_SIZE:=60Gi}"              # prod: 150Gi
: "${SCYLLA_BACKUP_STORAGE_SIZE:=10Gi}"
: "${SCYLLA_SMP:=2}"                          # cpu limit → scylla --smp
: "${SCYLLA_MEMORY_REQUEST:=3Gi}"
: "${SCYLLA_MEMORY_LIMIT:=4Gi}"               # prod: 5Gi
: "${SCYLLA_CPU_REQUEST:=1}"
: "${SCYLLA_DATA_DIR:=/data/scylla}"
# Staging under /data/users so the node's 06:00 rdiff-backup → NAS cron
# (tools/backup.sh) carries snapshot tars offsite automatically
: "${SCYLLA_BACKUP_DIR:=/data/users/scylla-backups}"
: "${SCYLLA_NODE:=$ENV_NAME}"                 # kubernetes.io/hostname to pin PVs + pod
: "${SCYLLA_CLUSTER_NAME:=scylla}"
: "${SCYLLA_DC:=dc1}"
: "${SCYLLA_RACK:=rack1}"

# cassandra-web (interim CQL browser until the in-house journal viewer lands)
: "${CASSANDRA_WEB_IMAGE:=ipushc/cassandra-web:v1.1.6}"
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"
: "${INGRESS_CLASS:=traefik}"
: "${CLUSTER_ISSUER:=letsencrypt-prod}"
: "${ENFORCE_POMERIUM:=true}"
if [[ -n "${HOSTNAME:-}" ]]; then
  CASSANDRA_WEB_HOST="${CASSANDRA_WEB_HOST:-cassandra.${HOSTNAME}}"
fi

# Deterministic names derived from the CR
SCYLLA_POD="${SCYLLA_CLUSTER_NAME}-${SCYLLA_DC}-${SCYLLA_RACK}-0"
DATA_PVC="data-${SCYLLA_CLUSTER_NAME}-${SCYLLA_DC}-${SCYLLA_RACK}-0"
SUPERUSER_SECRET="scylla-superuser"
CONTACT_POINTS="${SCYLLA_CLUSTER_NAME}-client.${NAMESPACE_SCYLLA}.svc.cluster.local:9042"

# --- Shared helpers ---
require_cluster() {
  if ! kubectl -n "$NAMESPACE_SCYLLA" get scyllacluster "$SCYLLA_CLUSTER_NAME" >/dev/null 2>&1; then
    err "ScyllaCluster not found in namespace: $NAMESPACE_SCYLLA"
    err "Run provisioning first: tools/k3s/scylla.sh ${ENV_NAME}"
    exit 1
  fi
}

superuser_pass() {
  kubectl -n "$NAMESPACE_SCYLLA" get secret "$SUPERUSER_SECRET" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true
}

# cqlsh as the cassandra superuser inside the scylla container
cql() {
  local pass
  pass=$(superuser_pass)
  if [[ -z "$pass" ]]; then
    pass="cassandra"
  fi
  kubectl -n "$NAMESPACE_SCYLLA" exec "$SCYLLA_POD" -c scylla -- \
    cqlsh -u cassandra -p "$pass" -e "$1"
}

# ============================================================================
# Show Credentials Mode
# ============================================================================
show_credentials() {
  local app_id="${1:-}"

  if [[ -n "$app_id" ]]; then
    local secret_name="${app_id}-cassandra"
    local app_namespace="${APP_NAMESPACE:-default}"

    if ! kubectl -n "$app_namespace" get secret "$secret_name" >/dev/null 2>&1; then
      err "Credentials secret '${secret_name}' not found in namespace '${app_namespace}'"
      err "Provision credentials first: tools/k3s/scylla.sh ${ENV_NAME} --provision-credentials ${app_id}"
      exit 1
    fi

    local points username password keyspace
    points=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.CASSANDRA_CONTACT_POINTS}' 2>/dev/null | base64 -d 2>/dev/null || true)
    username=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.CASSANDRA_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null || true)
    password=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.CASSANDRA_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
    keyspace=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.CASSANDRA_KEYSPACE}' 2>/dev/null | base64 -d 2>/dev/null || true)

    if [[ -z "$username" || -z "$password" ]]; then
      err "Failed to retrieve credentials from secret '${secret_name}' in namespace '${app_namespace}'"
      exit 1
    fi

    echo "CASSANDRA_CONTACT_POINTS=${points:-$CONTACT_POINTS}"
    echo "CASSANDRA_USERNAME=${username}"
    echo "CASSANDRA_PASSWORD=${password}"
    echo "CASSANDRA_KEYSPACE=${keyspace}"
    echo ""
    echo "# Secret: ${secret_name} (namespace: ${app_namespace})"
    exit 0
  fi

  local pass
  pass=$(superuser_pass)
  if [[ -z "$pass" ]]; then
    err "Superuser secret ${SUPERUSER_SECRET} not found in namespace: $NAMESPACE_SCYLLA"
    err "Run provisioning first: tools/k3s/scylla.sh ${ENV_NAME}"
    exit 1
  fi
  echo "CASSANDRA_CONTACT_POINTS=${CONTACT_POINTS}"
  echo "CASSANDRA_USERNAME=cassandra"
  echo "CASSANDRA_PASSWORD=${pass}"
  echo ""
  echo "# Superuser. Secret: ${SUPERUSER_SECRET} (namespace: ${NAMESPACE_SCYLLA})"
  exit 0
}

if [[ "$SHOW_CREDENTIALS" == "true" ]]; then
  show_credentials "$SHOW_CREDENTIALS_APP_ID"
fi

# ============================================================================
# Show Resources Mode
# ============================================================================
show_resources() {
  require_cluster

  echo "=== ScyllaDB Resource Usage ==="
  echo ""
  echo "--- ScyllaCluster status ---"
  kubectl -n "$NAMESPACE_SCYLLA" get scyllacluster "$SCYLLA_CLUSTER_NAME" -o custom-columns=\
'NAME:.metadata.name,'\
'VERSION:.spec.version,'\
"MEMBERS:.status.racks.${SCYLLA_RACK}.members,"\
"READY:.status.racks.${SCYLLA_RACK}.readyMembers" 2>/dev/null || true
  echo ""
  echo "--- Current Resource Usage (kubectl top) ---"
  kubectl top pods -n "$NAMESPACE_SCYLLA" 2>/dev/null || echo "Metrics not available"
  echo ""
  echo "--- Pod Resource Requests/Limits ---"
  kubectl -n "$NAMESPACE_SCYLLA" get pods -l "scylla/cluster=${SCYLLA_CLUSTER_NAME}" -o custom-columns=\
'NAME:.metadata.name,'\
'CPU_REQ:.spec.containers[0].resources.requests.cpu,'\
'CPU_LIM:.spec.containers[0].resources.limits.cpu,'\
'MEM_REQ:.spec.containers[0].resources.requests.memory,'\
'MEM_LIM:.spec.containers[0].resources.limits.memory' 2>/dev/null || true
  echo ""
  echo "--- Storage ---"
  kubectl -n "$NAMESPACE_SCYLLA" get pvc -o wide 2>/dev/null || true
  kubectl get pv scylla-data-pv 2>/dev/null || true
  echo ""
  echo "--- Disk usage (nodetool) ---"
  kubectl -n "$NAMESPACE_SCYLLA" exec "$SCYLLA_POD" -c scylla -- nodetool status 2>/dev/null || true
  exit 0
}

if [[ "$SHOW_RESOURCES" == "true" ]]; then
  show_resources
fi

# ============================================================================
# Watch/Inspect Mode
# ============================================================================
watch_cluster() {
  local kind="${1:-help}"
  require_cluster

  case "$kind" in
    help|--help|-h)
      cat <<EOF
=== ScyllaDB Watch/Inspect Toolbox ===

Run one of:
  tools/k3s/scylla.sh ${ENV_NAME} --watch status       # nodetool status + info
  tools/k3s/scylla.sh ${ENV_NAME} --watch compactions  # nodetool compactionstats
  tools/k3s/scylla.sh ${ENV_NAME} --watch logs         # scylla logs (follow)

Useful one-liners:
  kubectl -n ${NAMESPACE_SCYLLA} get scyllacluster ${SCYLLA_CLUSTER_NAME} -o yaml | sed -n '/^status:/,\$p'
  kubectl -n ${NAMESPACE_SCYLLA} get pods -o wide
  kubectl -n ${NAMESPACE_SCYLLA} exec ${SCYLLA_POD} -c scylla -- cqlsh -u cassandra -p '<pass>' -e 'DESCRIBE KEYSPACES'
  Metrics endpoint:
    kubectl -n ${NAMESPACE_SCYLLA} exec ${SCYLLA_POD} -c scylla -- curl -s localhost:9180/metrics | head
EOF
      exit 0
      ;;
    status)
      kubectl -n "$NAMESPACE_SCYLLA" exec "$SCYLLA_POD" -c scylla -- nodetool status
      echo ""
      kubectl -n "$NAMESPACE_SCYLLA" exec "$SCYLLA_POD" -c scylla -- nodetool info || true
      ;;
    compactions)
      kubectl -n "$NAMESPACE_SCYLLA" exec "$SCYLLA_POD" -c scylla -- nodetool compactionstats
      ;;
    logs)
      kubectl -n "$NAMESPACE_SCYLLA" logs "$SCYLLA_POD" -c scylla -f --tail=200
      ;;
    *)
      err "Unknown watch kind: ${kind}"
      err "Run: tools/k3s/scylla.sh ${ENV_NAME} --watch help"
      exit 1
      ;;
  esac
  exit 0
}

if [[ "$WATCH" == "true" ]]; then
  watch_cluster "$WATCH_KIND"
fi

# ============================================================================
# Snapshot-Now Mode (backup primitive — called by the scylla-backup CronJob)
# ============================================================================
snapshot_now() {
  require_cluster
  local tag
  tag="snap-$(date +%Y%m%d-%H%M%S)"

  log "=== Taking Scylla snapshot: ${tag} ==="

  info "nodetool snapshot -t ${tag}..."
  kubectl -n "$NAMESPACE_SCYLLA" exec "$SCYLLA_POD" -c scylla -- nodetool snapshot -t "$tag" || {
    err "nodetool snapshot failed"
    exit 1
  }

  # Tar the snapshot dirs from the host data dir to the staging dir. Snapshot
  # hardlinks live under <data>/data/<keyspace>/<table>/snapshots/<tag>/ on the
  # node's local PV, so a node-pinned Job with both hostPaths can archive them.
  info "Archiving snapshot to ${SCYLLA_BACKUP_DIR}/scylla-${tag}.tar.gz..."
  kubectl -n "$NAMESPACE_SCYLLA" delete job scylla-snapshot-archive --ignore-not-found=true >/dev/null 2>&1
  cat <<YAML | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: scylla-snapshot-archive
  namespace: ${NAMESPACE_SCYLLA}
spec:
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/hostname: ${SCYLLA_NODE}
      containers:
        - name: archive
          image: alpine:3.20
          command:
            - sh
            - -c
            - |
              set -e
              cd /host/data
              dirs=\$(find . -type d -path '*/snapshots/${tag}')
              if [ -z "\$dirs" ]; then
                echo "No snapshot dirs found for tag ${tag}" >&2
                exit 1
              fi
              tar -czf /host/backups/scylla-${tag}.tar.gz \$dirs
              ls -lh /host/backups/scylla-${tag}.tar.gz
          securityContext:
            runAsUser: 0
          volumeMounts:
            - name: data
              mountPath: /host/data
              readOnly: true
            - name: backups
              mountPath: /host/backups
      volumes:
        - name: data
          hostPath:
            path: ${SCYLLA_DATA_DIR}
            type: Directory
        - name: backups
          hostPath:
            path: ${SCYLLA_BACKUP_DIR}
            type: DirectoryOrCreate
YAML
  if ! kubectl -n "$NAMESPACE_SCYLLA" wait --for=condition=complete job/scylla-snapshot-archive --timeout=600s; then
    err "Snapshot archive job did not complete; snapshot ${tag} left in place for inspection"
    kubectl -n "$NAMESPACE_SCYLLA" logs job/scylla-snapshot-archive --tail=50 || true
    exit 1
  fi
  kubectl -n "$NAMESPACE_SCYLLA" logs job/scylla-snapshot-archive --tail=5 || true

  info "Clearing on-disk snapshot ${tag}..."
  kubectl -n "$NAMESPACE_SCYLLA" exec "$SCYLLA_POD" -c scylla -- nodetool clearsnapshot -t "$tag" || \
    warn "clearsnapshot failed — clean up manually: nodetool clearsnapshot -t ${tag}"

  info "✓ Snapshot archived: ${SCYLLA_BACKUP_DIR}/scylla-${tag}.tar.gz (on node ${SCYLLA_NODE})"
  exit 0
}

if [[ "$SNAPSHOT_NOW" == "true" ]]; then
  snapshot_now
fi

# ============================================================================
# Provision Credentials Mode
# ============================================================================
ensure_superuser_secret() {
  # Rotate the default cassandra/cassandra superuser password into a secret.
  if kubectl -n "$NAMESPACE_SCYLLA" get secret "$SUPERUSER_SECRET" >/dev/null 2>&1; then
    return 0
  fi

  info "Rotating default cassandra superuser password..."
  local new_pass
  new_pass=$(openssl rand -base64 24 | tr -d '\n' | tr '/+' '_-')
  kubectl -n "$NAMESPACE_SCYLLA" exec "$SCYLLA_POD" -c scylla -- \
    cqlsh -u cassandra -p cassandra -e "ALTER ROLE cassandra WITH PASSWORD = '${new_pass}';" || {
    err "Failed to rotate cassandra password (is PasswordAuthenticator active and the default password still in place?)"
    exit 1
  }
  kubectl -n "$NAMESPACE_SCYLLA" create secret generic "$SUPERUSER_SECRET" \
    --from-literal=username=cassandra \
    --from-literal=password="$new_pass"
  info "✓ Superuser password rotated and stored in secret ${SUPERUSER_SECRET}"
}

provision_credentials() {
  local app_id="$1"
  local app_namespace="${APP_NAMESPACE:-default}"

  if [[ ! "$app_id" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    err "Invalid app-id: ${app_id}"
    err "App ID must be lowercase alphanumeric with hyphens (e.g., 'myapp')"
    exit 1
  fi

  log "=== Provisioning Cassandra credentials for application: ${app_id} ==="
  require_cluster
  ensure_superuser_secret

  local app_username="${app_id//-/_}"
  local app_keyspace="${app_id//-/_}_journal"
  local app_password
  app_password=$(openssl rand -base64 24 | tr -d '\n' | tr '/+' '_-')

  info "Creating role '${app_username}' and keyspace '${app_keyspace}'..."
  cql "CREATE ROLE IF NOT EXISTS ${app_username} WITH PASSWORD = '${app_password}' AND LOGIN = true;" || {
    err "Failed to create role"
    exit 1
  }
  # Refresh the password in case the role pre-existed
  cql "ALTER ROLE ${app_username} WITH PASSWORD = '${app_password}';" || true

  # Explicit keyspace creation — do not rely on kafka-journal auto-create defaults.
  # Tablets are disabled: the 2025.1 tablets default drops LWT support, and the
  # kafka-journal clone-platform spike was validated against non-tablets keyspaces.
  cql "CREATE KEYSPACE IF NOT EXISTS ${app_keyspace} WITH replication = {'class': 'NetworkTopologyStrategy', 'replication_factor': 1} AND TABLETS = {'enabled': false};" || {
    err "Failed to create keyspace"
    exit 1
  }
  cql "GRANT ALL PERMISSIONS ON KEYSPACE ${app_keyspace} TO ${app_username};" || {
    err "Failed to grant permissions"
    exit 1
  }

  info "✓ Role and keyspace created"

  # Create secret file (same block shape as postgres.sh --provision-credentials)
  local secrets_dir="$ENVS_ROOT/${ENV_NAME}/secrets.plain"
  local secret_file="${secrets_dir}/${app_id}-cassandra.secret.yaml"
  mkdir -p "$secrets_dir"

  info "Creating secret file: ${secret_file}"
  cat > "$secret_file" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${app_id}-cassandra
  namespace: ${app_namespace}
type: Opaque
stringData:
  # Cassandra/Scylla contact points (in-cluster client service)
  CASSANDRA_CONTACT_POINTS: ${CONTACT_POINTS}

  # Cassandra role
  CASSANDRA_USERNAME: ${app_username}

  # Cassandra password
  CASSANDRA_PASSWORD: ${app_password}

  # Journal keyspace (pre-created, NetworkTopologyStrategy rf=1)
  CASSANDRA_KEYSPACE: ${app_keyspace}
YAML

  info "✓ Secret file created"

  kubectl get ns "$app_namespace" >/dev/null 2>&1 || kubectl create ns "$app_namespace"

  info "Applying secret to Kubernetes..."
  kubectl apply -f "$secret_file" || {
    err "Failed to apply secret to Kubernetes"
    exit 1
  }
  info "✓ Secret applied to namespace: ${app_namespace}"

  echo ""
  info "=== Credentials Provisioned ==="
  info "Application ID:     ${app_id}"
  info "Role:               ${app_username}"
  info "Keyspace:           ${app_keyspace}"
  info "Secret name:        ${app_id}-cassandra"
  info "Secret namespace:   ${app_namespace}"
  info "Secret file:        ${secret_file}"
  info ""
  info "Contact points:     ${CONTACT_POINTS}"
  info ""
  info "Encrypt for git:    tools/sops/encrypt.sh ${ENV_NAME} ${app_id}-cassandra.secret.yaml"
  echo ""
  exit 0
}

if [[ "$PROVISION_CREDENTIALS" == "true" ]]; then
  provision_credentials "$APP_ID"
fi

log "Starting ScyllaDB provisioning for environment: ${ENV_NAME}"

# ============================================================================
# Phase 1: Scylla Operator
# ============================================================================
install_operator() {
  log "=== Phase 1: Scylla Operator ==="

  if [[ "$SKIP_OPERATOR" == "true" ]]; then
    info "Skipping operator installation (--skip-operator)"
    return 0
  fi

  # The operator's webhook needs cert-manager (installed by identity.sh)
  if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    err "cert-manager CRDs not found — the Scylla operator webhook requires cert-manager."
    err "Run tools/k3s/identity.sh ${ENV_NAME} first."
    exit 1
  fi

  if [[ "$FORCE_CLEANUP" == "true" ]]; then
    info "Force cleanup requested - removing ScyllaCluster CR and operator"
    kubectl -n "$NAMESPACE_SCYLLA" delete scyllacluster "$SCYLLA_CLUSTER_NAME" --ignore-not-found=true --timeout=180s || true
    helm uninstall scylla-operator --namespace "$NAMESPACE_SCYLLA_OPERATOR" --ignore-not-found=true
    info "✓ Force cleanup completed"
  fi

  # CRD-existence guard for idempotency
  if kubectl get crd scyllaclusters.scylla.scylladb.com >/dev/null 2>&1 && \
     kubectl -n "$NAMESPACE_SCYLLA_OPERATOR" get deploy scylla-operator >/dev/null 2>&1; then
    info "Scylla operator already installed and CRDs present"
    return 0
  fi

  if ! helm repo list 2>/dev/null | grep -q '^scylla'; then
    helm repo add scylla https://scylla-operator-charts.storage.googleapis.com/stable
  fi
  helm repo update scylla >/dev/null

  info "Installing Scylla operator (chart ${SCYLLA_OPERATOR_VERSION})..."
  # replicas=1: single-node envs don't need operator HA, and the default of 2
  # wastes a pod on the pinned node
  helm upgrade --install scylla-operator scylla/scylla-operator \
    --namespace "$NAMESPACE_SCYLLA_OPERATOR" \
    --create-namespace \
    --version "$SCYLLA_OPERATOR_VERSION" \
    --set replicas=1 \
    --wait \
    --timeout 5m

  info "✓ Scylla operator installed"
}

install_operator

# ============================================================================
# Phase 2: Storage (static local PVs on the pinned node)
# ============================================================================
prepare_storage() {
  log "=== Phase 2: Storage ==="

  kubectl get ns "$NAMESPACE_SCYLLA" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_SCYLLA"

  # One-shot Job: create data + backup staging dirs on the target node
  info "Ensuring ${SCYLLA_DATA_DIR} and ${SCYLLA_BACKUP_DIR} exist on node ${SCYLLA_NODE}..."
  kubectl -n "$NAMESPACE_SCYLLA" delete job scylla-storage-init --ignore-not-found=true >/dev/null 2>&1
  cat <<YAML | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: scylla-storage-init
  namespace: ${NAMESPACE_SCYLLA}
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/hostname: ${SCYLLA_NODE}
      containers:
        - name: init
          image: busybox:1.36
          command: ["sh", "-c", "mkdir -p /host/data /host/backups && chown -R 999:999 /host/data && chmod 0770 /host/data && chmod 0770 /host/backups"]
          securityContext:
            runAsUser: 0
          volumeMounts:
            - name: host-data
              mountPath: /host/data
            - name: host-backups
              mountPath: /host/backups
      volumes:
        - name: host-data
          hostPath:
            path: ${SCYLLA_DATA_DIR}
            type: DirectoryOrCreate
        - name: host-backups
          hostPath:
            path: ${SCYLLA_BACKUP_DIR}
            type: DirectoryOrCreate
YAML
  kubectl -n "$NAMESPACE_SCYLLA" wait --for=condition=complete job/scylla-storage-init --timeout=120s || {
    err "Storage init job did not complete; check: kubectl -n ${NAMESPACE_SCYLLA} logs job/scylla-storage-init"
    exit 1
  }
  info "✓ Directories ready"

  # StorageClass + static PV (wan-models-pv pattern). claimRef pins the data PV
  # to the operator's deterministic PVC name so it cannot bind to another claim.
  # The snapshot staging PV/PVC is owned by the scylla-backup chart (storeback
  # pattern); --snapshot-now writes to the staging dir via hostPath directly.
  info "Applying StorageClass local-storage + PV scylla-data-pv..."
  cat <<YAML | kubectl apply -f -
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: scylla-data-pv
spec:
  capacity:
    storage: ${SCYLLA_STORAGE_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  claimRef:
    namespace: ${NAMESPACE_SCYLLA}
    name: ${DATA_PVC}
  local:
    path: ${SCYLLA_DATA_DIR}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${SCYLLA_NODE}
YAML
  info "✓ Static PV applied"
}

prepare_storage

# ============================================================================
# Phase 3: ScyllaCluster CR (single member)
# ============================================================================
create_scylla_cluster() {
  log "=== Phase 3: ScyllaCluster ==="

  info "Applying ScyllaCluster CR (${SCYLLA_IMAGE_TAG}, smp=${SCYLLA_SMP}, mem limit=${SCYLLA_MEMORY_LIMIT})..."
  cat <<YAML | kubectl apply -f -
apiVersion: scylla.scylladb.com/v1
kind: ScyllaCluster
metadata:
  name: ${SCYLLA_CLUSTER_NAME}
  namespace: ${NAMESPACE_SCYLLA}
spec:
  version: ${SCYLLA_IMAGE_TAG}
  agentVersion: ${SCYLLA_AGENT_VERSION}
  repository: docker.io/scylladb/scylla
  developerMode: true
  # PasswordAuthenticator for per-app roles (see --provision-credentials)
  scyllaArgs: "--authenticator PasswordAuthenticator --authorizer CassandraAuthorizer"
  datacenter:
    name: ${SCYLLA_DC}
    racks:
      - name: ${SCYLLA_RACK}
        members: 1
        storage:
          storageClassName: local-storage
          capacity: ${SCYLLA_STORAGE_SIZE}
        resources:
          requests:
            cpu: ${SCYLLA_CPU_REQUEST}
            memory: ${SCYLLA_MEMORY_REQUEST}
          limits:
            cpu: ${SCYLLA_SMP}
            memory: ${SCYLLA_MEMORY_LIMIT}
        placement:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
                - matchExpressions:
                    - key: kubernetes.io/hostname
                      operator: In
                      values:
                        - ${SCYLLA_NODE}
YAML

  info "Waiting for ScyllaCluster to be ready (timeout: 15 minutes)..."
  local ready=false
  for i in {1..90}; do
    local ready_members
    ready_members=$(kubectl -n "$NAMESPACE_SCYLLA" get scyllacluster "$SCYLLA_CLUSTER_NAME" \
      -o jsonpath="{.status.racks.${SCYLLA_RACK}.readyMembers}" 2>/dev/null || echo "0")
    if [[ "${ready_members:-0}" -ge 1 ]]; then
      ready=true
      break
    fi
    if (( i % 3 == 0 )); then
      info "  readyMembers=${ready_members:-0} (${i}0s elapsed...)"
    fi
    sleep 10
  done

  if [[ "$ready" != "true" ]]; then
    warn "ScyllaCluster did not report a ready member in time"
    warn "Diagnostics:"
    kubectl -n "$NAMESPACE_SCYLLA" get scyllacluster "$SCYLLA_CLUSTER_NAME" -o yaml 2>/dev/null | sed -n '/^status:/,$p' || true
    kubectl -n "$NAMESPACE_SCYLLA" get pods 2>/dev/null || true
    kubectl -n "$NAMESPACE_SCYLLA" get events --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || true
    warn "Continuing; the node may still be initializing."
    return 0
  fi

  info "✓ ScyllaCluster ready"
  kubectl -n "$NAMESPACE_SCYLLA" exec "$SCYLLA_POD" -c scylla -- nodetool status 2>/dev/null || true
}

create_scylla_cluster

# ============================================================================
# Phase 4: Metrics Service (Prometheus endpoint discovery)
# ============================================================================
create_metrics_service() {
  log "=== Phase 4: Metrics Service ==="

  # Plain Service with a named 'metrics' port — the discovery target for the
  # 'scylla' job in observability.sh extraScrapeConfigs (native Prometheus :9180).
  cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: scylla-metrics
  namespace: ${NAMESPACE_SCYLLA}
  labels:
    app: scylla-metrics
    component: monitoring
spec:
  selector:
    scylla/cluster: ${SCYLLA_CLUSTER_NAME}
  ports:
    - port: 9180
      targetPort: 9180
      name: metrics
YAML

  info "✓ scylla-metrics Service applied"
  info "  Metrics: http://scylla-metrics.${NAMESPACE_SCYLLA}.svc.cluster.local:9180/metrics"
  info "  (scraped by the 'scylla' job in observability.sh — rerun observability.sh after first install)"
}

create_metrics_service

# ============================================================================
# Phase 5: cassandra-web (interim CQL browser, pgweb pattern)
# ============================================================================
deploy_cassandra_web() {
  log "=== Phase 5: cassandra-web ==="

  if [[ "$SKIP_WEB" == "true" ]]; then
    info "Skipping cassandra-web installation (--skip-web)"
    return 0
  fi

  if [[ -z "${CASSANDRA_WEB_HOST:-}" ]]; then
    warn "CASSANDRA_WEB_HOST not set (no HOSTNAME in env.properties) - skipping cassandra-web"
    return 0
  fi

  # Connects with the cassandra superuser (like pgweb) so all keyspaces are visible.
  # The secret exists once --provision-credentials has rotated the default password.
  local pass
  pass=$(superuser_pass)
  if [[ -z "$pass" ]]; then
    warn "Superuser secret ${SUPERUSER_SECRET} not found - run --provision-credentials once first; skipping cassandra-web"
    return 0
  fi

  cat <<YAML | kubectl apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cassandra-web
  namespace: ${NAMESPACE_SCYLLA}
  labels:
    app: cassandra-web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cassandra-web
  template:
    metadata:
      labels:
        app: cassandra-web
    spec:
      containers:
      - name: cassandra-web
        image: ${CASSANDRA_WEB_IMAGE}
        ports:
        - containerPort: 8083
          name: http
        env:
        - name: CASSANDRA_HOST
          value: "${SCYLLA_CLUSTER_NAME}-client.${NAMESPACE_SCYLLA}.svc.cluster.local"
        - name: CASSANDRA_PORT
          value: "9042"
        - name: CASSANDRA_USERNAME
          valueFrom:
            secretKeyRef:
              name: ${SUPERUSER_SECRET}
              key: username
        - name: CASSANDRA_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${SUPERUSER_SECRET}
              key: password
        - name: HOST_PORT
          value: ":8083"
        resources:
          requests:
            memory: "64Mi"
            cpu: "25m"
          limits:
            memory: "256Mi"
            cpu: "250m"
        readinessProbe:
          httpGet:
            path: /
            port: 8083
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: cassandra-web
  namespace: ${NAMESPACE_SCYLLA}
spec:
  selector:
    app: cassandra-web
  ports:
  - port: 8083
    targetPort: 8083
    name: http
YAML

  info "Waiting for cassandra-web deployment to be ready..."
  kubectl -n "$NAMESPACE_SCYLLA" rollout status deployment/cassandra-web --timeout=180s || true
  info "✓ cassandra-web deployed"
}

deploy_cassandra_web

# ============================================================================
# Phase 6: Pomerium ingress + route for cassandra-web
# ============================================================================
expose_cassandra_web() {
  log "=== Phase 6: cassandra-web ingress (Pomerium) ==="

  if [[ "$SKIP_WEB" == "true" || -z "${CASSANDRA_WEB_HOST:-}" ]]; then
    info "Skipping cassandra-web ingress"
    return 0
  fi

  if provision::cloudflare_read_token 2>/dev/null; then
    if provision::cloudflare_check_wildcard "$HOSTNAME" 2>/dev/null; then
      info "Wildcard DNS covers ${CASSANDRA_WEB_HOST}"
    else
      provision::cloudflare_ensure_dns_record "$CASSANDRA_WEB_HOST" "$EXTERNAL_IP" || \
        warn "Failed to create DNS record for ${CASSANDRA_WEB_HOST} (wildcard may cover it)"
    fi
  fi

  if [[ "${ENFORCE_POMERIUM}" != "true" ]]; then
    warn "ENFORCE_POMERIUM != true - refusing to expose cassandra-web without auth"
    return 0
  fi

  cat <<YAML | kubectl apply -f -
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cassandra-web-pomerium
  namespace: ${NAMESPACE_SSO}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    cert-manager.io/common-name: ${CASSANDRA_WEB_HOST}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${CASSANDRA_WEB_HOST}
    secretName: cassandra-web-pomerium-tls
  rules:
  - host: ${CASSANDRA_WEB_HOST}
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

  local from_url="https://${CASSANDRA_WEB_HOST}"
  local to_url="http://cassandra-web.${NAMESPACE_SCYLLA}.svc.cluster.local:8083"
  if provision::pomerium_routes_add "$from_url" "$to_url" "${NAMESPACE_SSO}" true true true; then
    info "✓ Pomerium route ensured: ${from_url} -> ${to_url}"
  else
    warn "Failed to ensure Pomerium route for ${from_url}"
  fi
}

expose_cassandra_web || true

# ============================================================================
# Summary
# ============================================================================
log "=== ScyllaDB provisioning complete ==="
info "Namespace:          ${NAMESPACE_SCYLLA}"
info "Member:             ${SCYLLA_POD} (${SCYLLA_IMAGE_TAG}, developerMode, smp=${SCYLLA_SMP})"
info "Contact points:     ${CONTACT_POINTS}"
info "Data dir:           ${SCYLLA_DATA_DIR} on ${SCYLLA_NODE} (PV scylla-data-pv, ${SCYLLA_STORAGE_SIZE})"
info "Backup staging:     ${SCYLLA_BACKUP_DIR} (rdiff→NAS via the 06:00 node cron)"
if [[ "$SKIP_WEB" != "true" && -n "${CASSANDRA_WEB_HOST:-}" ]]; then
  info "cassandra-web:      https://${CASSANDRA_WEB_HOST} (GitHub OAuth via Pomerium)"
fi
info ""
info "Next steps:"
info "  tools/k3s/scylla.sh ${ENV_NAME} --watch status"
info "  tools/k3s/scylla.sh ${ENV_NAME} --provision-credentials <app-id>"
info "  tools/k3s/scylla.sh ${ENV_NAME} --snapshot-now"
info "  tools/k3s/observability.sh ${ENV_NAME}   # load scylla scrape job + kafka-journal alerts"
