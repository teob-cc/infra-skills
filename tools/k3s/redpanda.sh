#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# K3S Redpanda Provisioning (Redpanda Operator v2)
# ============================================================================
# Provisions a single-broker Redpanda (Kafka API) instance for the kafka-journal
# persistence stack:
# 1. Redpanda operator (Helm chart redpanda/operator)
# 2. Static local PV on /data/redpanda (class local-storage, node-pinned)
# 3. Redpanda CR: single broker, SASL/SCRAM enabled, internal listener :9093,
#    admin API :9644, consumer-group lag metrics on /public_metrics
# 4. redpanda-metrics Service for Prometheus endpoint discovery
# 5. Redpanda Console UI behind Pomerium (console.<env>, pgweb pattern)
#
# Usage:
#   tools/k3s/redpanda.sh <env-name> [options]
#
# Options:
#   --skip-operator          Skip operator installation (use existing)
#   --skip-console           Skip Redpanda Console installation
#   --force-cleanup          Remove operator + Redpanda CR before reinstalling
#   --show-credentials [app-id]  Display Kafka credentials and exit
#   --show-resources         Display current Redpanda resource usage and exit
#   --watch [kind]           Inspect a running broker (kind: help|health|topics|groups|logs)
#   --provision-credentials <app-id>  Provision SASL/SCRAM credentials for an application
#   --impl <impl>            Implementation seam: redpanda (default) | strimzi (reserved)
#
# Sizing (cit defaults; prod overrides via env vars):
#   REDPANDA_STORAGE_SIZE=100Gi REDPANDA_SMP=2 REDPANDA_MEMORY=2048Mi tools/k3s/redpanda.sh prod
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

# --- Parse arguments ---
if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--skip-operator] [--skip-console] [--force-cleanup] [--show-credentials [app-id]] [--show-resources] [--watch [kind]] [--provision-credentials <app-id>] [--impl <impl>]" >&2
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
SKIP_CONSOLE=false
FORCE_CLEANUP=false
SHOW_CREDENTIALS=false
SHOW_CREDENTIALS_APP_ID=""
SHOW_RESOURCES=false
WATCH=false
WATCH_KIND="help"
PROVISION_CREDENTIALS=false
APP_ID=""
IMPL="redpanda"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-operator) SKIP_OPERATOR=true; shift ;;
    --skip-console) SKIP_CONSOLE=true; shift ;;
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
    --impl)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --impl requires an argument (redpanda|strimzi)" >&2
        exit 1
      fi
      IMPL="$2"; shift 2
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$IMPL" != "redpanda" ]]; then
  echo "ERROR: --impl ${IMPL} is reserved but not implemented." >&2
  echo "Only 'redpanda' is supported today; 'strimzi' is the design fallback" >&2
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
log() { echo "[redpanda] $*"; }
info() { echo "[redpanda:info] $*"; }
warn() { echo "[redpanda:warn] $*" >&2; }
err() { echo "[redpanda:error] $*" >&2; }

# --- Config defaults ---
: "${NAMESPACE_REDPANDA:=redpanda}"
# Operator chart version pinned 2026-07-19: 25.3.x line matches the v25.1.x
# broker era (26.x tracks newer brokers). helm search repo redpanda/operator --versions
: "${REDPANDA_OPERATOR_VERSION:=25.3.7}"
# Same broker pin as the kafka-journal clone-platform spike (compose + CI)
: "${REDPANDA_IMAGE_TAG:=v25.1.1}"
: "${REDPANDA_STORAGE_SIZE:=25Gi}"            # prod: 100Gi
: "${REDPANDA_SMP:=1}"                        # prod: 2
: "${REDPANDA_MEMORY:=1536Mi}"                # seastar --memory; prod: 2048Mi
: "${REDPANDA_CONTAINER_MEM_MIN:=2Gi}"        # container request
: "${REDPANDA_CONTAINER_MEM_MAX:=2560Mi}"     # container limit
: "${REDPANDA_DATA_DIR:=/data/redpanda}"
: "${REDPANDA_NODE:=$ENV_NAME}"               # kubernetes.io/hostname to pin PV + broker
: "${REDPANDA_CLUSTER_NAME:=redpanda}"

# Redpanda Console (UI) — pgweb pattern: Deployment + Pomerium-routed Ingress
: "${REDPANDA_CONSOLE_IMAGE:=docker.redpanda.com/redpandadata/console:v3.8.0}"
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"
: "${INGRESS_CLASS:=traefik}"
: "${CLUSTER_ISSUER:=letsencrypt-prod}"
: "${ENFORCE_POMERIUM:=true}"
if [[ -n "${HOSTNAME:-}" ]]; then
  REDPANDA_CONSOLE_HOST="${REDPANDA_CONSOLE_HOST:-console.${HOSTNAME}}"
fi

# Deterministic names derived from the CR
BROKER_POD="${REDPANDA_CLUSTER_NAME}-0"
DATA_PVC="datadir-${REDPANDA_CLUSTER_NAME}-0"
SUPERUSER_SECRET="redpanda-superusers"
# NB: the redpanda chart's internal Kafka listener is 9093 (9092 is refused)
BOOTSTRAP_SERVERS="${REDPANDA_CLUSTER_NAME}.${NAMESPACE_REDPANDA}.svc.cluster.local:9093"

# --- Shared helpers ---

# Superuser credentials live in $SUPERUSER_SECRET as users.txt "user:pass:mechanism"
# (the redpanda chart/operator auth.sasl.secretRef format).
superuser_creds() {
  local line
  line=$(kubectl -n "$NAMESPACE_REDPANDA" get secret "$SUPERUSER_SECRET" \
    -o jsonpath='{.data.users\.txt}' 2>/dev/null | base64 -d | head -1 || true)
  if [[ -z "$line" ]]; then
    return 1
  fi
  SUPERUSER_NAME="${line%%:*}"
  SUPERUSER_PASS="$(echo "$line" | cut -d: -f2)"
}

# rpk with superuser SASL identity (Kafka API operations need it once SASL is on)
rpk_admin() {
  superuser_creds || { err "Superuser secret ${SUPERUSER_SECRET} not found"; exit 1; }
  kubectl -n "$NAMESPACE_REDPANDA" exec "$BROKER_POD" -c redpanda -- \
    rpk "$@" \
    -X user="$SUPERUSER_NAME" -X pass="$SUPERUSER_PASS" -X sasl.mechanism=SCRAM-SHA-256
}

require_broker() {
  if ! kubectl -n "$NAMESPACE_REDPANDA" get redpanda "$REDPANDA_CLUSTER_NAME" >/dev/null 2>&1; then
    err "Redpanda cluster not found in namespace: $NAMESPACE_REDPANDA"
    err "Run provisioning first: tools/k3s/redpanda.sh ${ENV_NAME}"
    exit 1
  fi
}

# ============================================================================
# Show Credentials Mode
# ============================================================================
show_credentials() {
  local app_id="${1:-}"

  if [[ -n "$app_id" ]]; then
    local secret_name="${app_id}-kafka"
    local app_namespace="${APP_NAMESPACE:-default}"

    if ! kubectl -n "$app_namespace" get secret "$secret_name" >/dev/null 2>&1; then
      err "Credentials secret '${secret_name}' not found in namespace '${app_namespace}'"
      err "Provision credentials first: tools/k3s/redpanda.sh ${ENV_NAME} --provision-credentials ${app_id}"
      exit 1
    fi

    local servers username password
    servers=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.KAFKA_BOOTSTRAP_SERVERS}' 2>/dev/null | base64 -d 2>/dev/null || true)
    username=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.KAFKA_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null || true)
    password=$(kubectl -n "$app_namespace" get secret "$secret_name" -o jsonpath='{.data.KAFKA_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)

    if [[ -z "$username" || -z "$password" ]]; then
      err "Failed to retrieve credentials from secret '${secret_name}' in namespace '${app_namespace}'"
      exit 1
    fi

    echo "KAFKA_BOOTSTRAP_SERVERS=${servers:-$BOOTSTRAP_SERVERS}"
    echo "KAFKA_USERNAME=${username}"
    echo "KAFKA_PASSWORD=${password}"
    echo ""
    echo "# SASL mechanism: SCRAM-SHA-256, security protocol: SASL_PLAINTEXT (internal listener)"
    echo "# Secret: ${secret_name} (namespace: ${app_namespace})"
    exit 0
  fi

  # Superuser credentials
  if ! superuser_creds; then
    err "Superuser secret ${SUPERUSER_SECRET} not found in namespace: $NAMESPACE_REDPANDA"
    err "Run provisioning first: tools/k3s/redpanda.sh ${ENV_NAME}"
    exit 1
  fi
  echo "KAFKA_BOOTSTRAP_SERVERS=${BOOTSTRAP_SERVERS}"
  echo "KAFKA_USERNAME=${SUPERUSER_NAME}"
  echo "KAFKA_PASSWORD=${SUPERUSER_PASS}"
  echo ""
  echo "# Superuser (SCRAM-SHA-256). Secret: ${SUPERUSER_SECRET} (namespace: ${NAMESPACE_REDPANDA})"
  exit 0
}

if [[ "$SHOW_CREDENTIALS" == "true" ]]; then
  show_credentials "$SHOW_CREDENTIALS_APP_ID"
fi

# ============================================================================
# Show Resources Mode
# ============================================================================
show_resources() {
  require_broker

  echo "=== Redpanda Resource Usage ==="
  echo ""
  echo "--- Redpanda CR status ---"
  kubectl -n "$NAMESPACE_REDPANDA" get redpanda "$REDPANDA_CLUSTER_NAME" -o custom-columns=\
'NAME:.metadata.name,'\
'READY:.status.conditions[?(@.type=="Ready")].status,'\
'REASON:.status.conditions[?(@.type=="Ready")].reason' 2>/dev/null || true
  echo ""
  echo "--- Current Resource Usage (kubectl top) ---"
  kubectl top pods -n "$NAMESPACE_REDPANDA" 2>/dev/null || echo "Metrics not available"
  echo ""
  echo "--- Pod Resource Requests/Limits ---"
  kubectl -n "$NAMESPACE_REDPANDA" get pods -l app.kubernetes.io/name=redpanda -o custom-columns=\
'NAME:.metadata.name,'\
'CPU_REQ:.spec.containers[0].resources.requests.cpu,'\
'CPU_LIM:.spec.containers[0].resources.limits.cpu,'\
'MEM_REQ:.spec.containers[0].resources.requests.memory,'\
'MEM_LIM:.spec.containers[0].resources.limits.memory' 2>/dev/null || true
  echo ""
  echo "--- Storage ---"
  kubectl -n "$NAMESPACE_REDPANDA" get pvc -o wide 2>/dev/null || true
  kubectl get pv redpanda-data-pv 2>/dev/null || true
  echo ""
  echo "--- Broker disk (rpk) ---"
  kubectl -n "$NAMESPACE_REDPANDA" exec "$BROKER_POD" -c redpanda -- df -h "$REDPANDA_DATA_DIR" 2>/dev/null \
    || kubectl -n "$NAMESPACE_REDPANDA" exec "$BROKER_POD" -c redpanda -- df -h /var/lib/redpanda/data 2>/dev/null || true
  exit 0
}

if [[ "$SHOW_RESOURCES" == "true" ]]; then
  show_resources
fi

# ============================================================================
# Watch/Inspect Mode
# ============================================================================
watch_broker() {
  local kind="${1:-help}"
  require_broker

  case "$kind" in
    help|--help|-h)
      cat <<EOF
=== Redpanda Watch/Inspect Toolbox ===

Run one of:
  tools/k3s/redpanda.sh ${ENV_NAME} --watch health   # rpk cluster health (snapshot)
  tools/k3s/redpanda.sh ${ENV_NAME} --watch topics   # rpk topic list + details
  tools/k3s/redpanda.sh ${ENV_NAME} --watch groups   # rpk group list + lag per group
  tools/k3s/redpanda.sh ${ENV_NAME} --watch logs     # broker logs (follow)

Useful one-liners:
  kubectl -n ${NAMESPACE_REDPANDA} get redpanda ${REDPANDA_CLUSTER_NAME} -o yaml | sed -n '/^status:/,\$p'
  kubectl -n ${NAMESPACE_REDPANDA} get pods -o wide
  kubectl -n ${NAMESPACE_REDPANDA} exec ${BROKER_POD} -c redpanda -- rpk cluster config get enable_consumer_group_metrics
  curl the metrics endpoint:
    kubectl -n ${NAMESPACE_REDPANDA} exec ${BROKER_POD} -c redpanda -- curl -s localhost:9644/public_metrics | head
EOF
      exit 0
      ;;
    health)
      kubectl -n "$NAMESPACE_REDPANDA" exec "$BROKER_POD" -c redpanda -- rpk cluster health
      ;;
    topics)
      rpk_admin topic list --detailed
      ;;
    groups)
      rpk_admin group list
      echo ""
      for g in $(rpk_admin group list 2>/dev/null | awk 'NR>1 {print $2}'); do
        echo "--- group: $g ---"
        rpk_admin group describe "$g" || true
      done
      ;;
    logs)
      kubectl -n "$NAMESPACE_REDPANDA" logs "$BROKER_POD" -c redpanda -f --tail=200
      ;;
    *)
      err "Unknown watch kind: ${kind}"
      err "Run: tools/k3s/redpanda.sh ${ENV_NAME} --watch help"
      exit 1
      ;;
  esac
  exit 0
}

if [[ "$WATCH" == "true" ]]; then
  watch_broker "$WATCH_KIND"
fi

# ============================================================================
# Provision Credentials Mode
# ============================================================================
provision_credentials() {
  local app_id="$1"
  local app_namespace="${APP_NAMESPACE:-default}"

  if [[ ! "$app_id" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    err "Invalid app-id: ${app_id}"
    err "App ID must be lowercase alphanumeric with hyphens (e.g., 'myapp')"
    exit 1
  fi

  log "=== Provisioning Kafka credentials for application: ${app_id} ==="
  require_broker

  local app_username="${app_id}"
  local app_password
  app_password=$(openssl rand -base64 24 | tr -d '\n')

  # SCRAM user via admin API (idempotent: delete+create refreshes the password)
  info "Creating SASL/SCRAM user '${app_username}'..."
  kubectl -n "$NAMESPACE_REDPANDA" exec "$BROKER_POD" -c redpanda -- \
    rpk security user delete "$app_username" >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE_REDPANDA" exec "$BROKER_POD" -c redpanda -- \
    rpk security user create "$app_username" -p "$app_password" --mechanism SCRAM-SHA-256 || {
    err "Failed to create SASL user"
    exit 1
  }

  # ACLs: full access to its own journal topics and consumer groups
  info "Granting ACLs for '${app_username}'..."
  rpk_admin security acl create \
    --allow-principal "User:${app_username}" \
    --operation all \
    --topic '*' --group '*' --transactional-id '*' || {
    err "Failed to create ACLs"
    exit 1
  }

  info "✓ SASL user and ACLs created"

  # Create secret file (same block shape as postgres.sh --provision-credentials)
  local secrets_dir="$ENVS_ROOT/${ENV_NAME}/secrets.plain"
  local secret_file="${secrets_dir}/${app_id}-kafka.secret.yaml"
  mkdir -p "$secrets_dir"

  info "Creating secret file: ${secret_file}"
  cat > "$secret_file" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${app_id}-kafka
  namespace: ${app_namespace}
type: Opaque
stringData:
  # Kafka bootstrap servers (in-cluster internal listener)
  KAFKA_BOOTSTRAP_SERVERS: ${BOOTSTRAP_SERVERS}

  # SASL/SCRAM-SHA-256 username
  KAFKA_USERNAME: ${app_username}

  # SASL/SCRAM-SHA-256 password
  KAFKA_PASSWORD: ${app_password}
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
  info "Username:           ${app_username}"
  info "Secret name:        ${app_id}-kafka"
  info "Secret namespace:   ${app_namespace}"
  info "Secret file:        ${secret_file}"
  info ""
  info "Bootstrap servers:  ${BOOTSTRAP_SERVERS}"
  info "Mechanism:          SCRAM-SHA-256 (SASL_PLAINTEXT, internal listener)"
  info ""
  info "Encrypt for git:    tools/sops/encrypt.sh ${ENV_NAME} ${app_id}-kafka.secret.yaml"
  echo ""
  exit 0
}

if [[ "$PROVISION_CREDENTIALS" == "true" ]]; then
  provision_credentials "$APP_ID"
fi

log "Starting Redpanda provisioning for environment: ${ENV_NAME}"

# ============================================================================
# Phase 1: Redpanda Operator
# ============================================================================
install_operator() {
  log "=== Phase 1: Redpanda Operator ==="

  if [[ "$SKIP_OPERATOR" == "true" ]]; then
    info "Skipping operator installation (--skip-operator)"
    return 0
  fi

  if [[ "$FORCE_CLEANUP" == "true" ]]; then
    info "Force cleanup requested - removing Redpanda CR and operator"
    kubectl -n "$NAMESPACE_REDPANDA" delete redpanda "$REDPANDA_CLUSTER_NAME" --ignore-not-found=true --timeout=120s || true
    helm uninstall redpanda-operator --namespace "$NAMESPACE_REDPANDA" --ignore-not-found=true
    # CRDs and the namespace are kept; PV/PVC are kept (Retain policy)
    info "✓ Force cleanup completed"
  fi

  # CRD-existence guard for idempotency
  if kubectl get crd redpandas.cluster.redpanda.com >/dev/null 2>&1 && \
     kubectl -n "$NAMESPACE_REDPANDA" get deploy -l app.kubernetes.io/name=operator -o name 2>/dev/null | grep -q .; then
    info "Redpanda operator already installed and CRDs present"
    return 0
  fi

  if ! helm repo list 2>/dev/null | grep -q '^redpanda'; then
    helm repo add redpanda https://charts.redpanda.com
  fi
  helm repo update redpanda >/dev/null

  info "Installing Redpanda operator (chart ${REDPANDA_OPERATOR_VERSION})..."
  # crds.enabled defaults to false in this chart — without it the operator
  # crash-loops on the missing Console/Redpanda CRDs
  helm upgrade --install redpanda-operator redpanda/operator \
    --namespace "$NAMESPACE_REDPANDA" \
    --create-namespace \
    --version "$REDPANDA_OPERATOR_VERSION" \
    --set crds.enabled=true \
    --wait \
    --timeout 5m

  info "✓ Redpanda operator installed"
}

install_operator

# ============================================================================
# Phase 2: Storage (static local PV on the pinned node)
# ============================================================================
prepare_storage() {
  log "=== Phase 2: Storage ==="

  kubectl get ns "$NAMESPACE_REDPANDA" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_REDPANDA"

  # One-shot privileged Job: create + chown the data dir on the target node
  # (redpanda container runs as uid/gid 101)
  info "Ensuring ${REDPANDA_DATA_DIR} exists on node ${REDPANDA_NODE}..."
  kubectl -n "$NAMESPACE_REDPANDA" delete job redpanda-storage-init --ignore-not-found=true >/dev/null 2>&1
  cat <<YAML | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: redpanda-storage-init
  namespace: ${NAMESPACE_REDPANDA}
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/hostname: ${REDPANDA_NODE}
      containers:
        - name: init
          image: busybox:1.36
          command: ["sh", "-c", "mkdir -p /host/dir && chown -R 101:101 /host/dir && chmod 0770 /host/dir"]
          securityContext:
            runAsUser: 0
          volumeMounts:
            - name: host-data
              mountPath: /host/dir
      volumes:
        - name: host-data
          hostPath:
            path: ${REDPANDA_DATA_DIR}
            type: DirectoryOrCreate
YAML
  kubectl -n "$NAMESPACE_REDPANDA" wait --for=condition=complete job/redpanda-storage-init --timeout=120s || {
    err "Storage init job did not complete; check: kubectl -n ${NAMESPACE_REDPANDA} logs job/redpanda-storage-init"
    exit 1
  }
  info "✓ Data directory ready"

  # StorageClass + static PV (wan-models-pv pattern). claimRef pins the PV to the
  # StatefulSet's deterministic PVC name so it cannot bind to another local-storage claim.
  info "Applying StorageClass local-storage + PV redpanda-data-pv..."
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
  name: redpanda-data-pv
spec:
  capacity:
    storage: ${REDPANDA_STORAGE_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  claimRef:
    namespace: ${NAMESPACE_REDPANDA}
    name: ${DATA_PVC}
  local:
    path: ${REDPANDA_DATA_DIR}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${REDPANDA_NODE}
YAML
  info "✓ Static PV applied"
}

prepare_storage

# ============================================================================
# Phase 3: Redpanda CR (single broker)
# ============================================================================
create_redpanda_cluster() {
  log "=== Phase 3: Redpanda cluster ==="

  # Bootstrap superuser secret (users.txt format consumed by auth.sasl.secretRef)
  if ! kubectl -n "$NAMESPACE_REDPANDA" get secret "$SUPERUSER_SECRET" >/dev/null 2>&1; then
    info "Creating superuser secret ${SUPERUSER_SECRET}..."
    local admin_pass
    admin_pass=$(openssl rand -base64 24 | tr -d '\n')
    kubectl -n "$NAMESPACE_REDPANDA" create secret generic "$SUPERUSER_SECRET" \
      --from-literal=users.txt="admin:${admin_pass}:SCRAM-SHA-256"
  fi

  info "Applying Redpanda CR (broker ${REDPANDA_IMAGE_TAG}, smp=${REDPANDA_SMP}, memory=${REDPANDA_MEMORY})..."
  cat <<YAML | kubectl apply -f -
apiVersion: cluster.redpanda.com/v1alpha2
kind: Redpanda
metadata:
  name: ${REDPANDA_CLUSTER_NAME}
  namespace: ${NAMESPACE_REDPANDA}
spec:
  clusterSpec:
    image:
      repository: docker.redpanda.com/redpandadata/redpanda
      tag: ${REDPANDA_IMAGE_TAG}
    statefulset:
      replicas: 1
      nodeSelector:
        kubernetes.io/hostname: ${REDPANDA_NODE}
    resources:
      cpu:
        cores: ${REDPANDA_SMP}
        overprovisioned: true
      memory:
        enable_memory_locking: false
        container:
          min: ${REDPANDA_CONTAINER_MEM_MIN}
          max: ${REDPANDA_CONTAINER_MEM_MAX}
        redpanda:
          memory: ${REDPANDA_MEMORY}
          reserveMemory: 0Mi
    storage:
      persistentVolume:
        enabled: true
        size: ${REDPANDA_STORAGE_SIZE}
        storageClass: local-storage
    auth:
      sasl:
        enabled: true
        secretRef: ${SUPERUSER_SECRET}
    tls:
      enabled: false
    external:
      enabled: false
    console:
      enabled: false
    monitoring:
      enabled: false
    config:
      cluster:
        # Exposes redpanda_kafka_consumer_group_lag_{max,sum} on /public_metrics
        # (consumed by the kafka-journal alert group in observability.sh)
        enable_consumer_group_metrics:
          - group
          - partition
          - consumer_lag
YAML

  # Poll for readiness (Redpanda CR Ready condition + pod ready)
  info "Waiting for Redpanda cluster to be ready (timeout: 10 minutes)..."
  local ready=false
  for i in {1..60}; do
    local cond
    cond=$(kubectl -n "$NAMESPACE_REDPANDA" get redpanda "$REDPANDA_CLUSTER_NAME" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$cond" == "True" ]]; then
      ready=true
      break
    fi
    if (( i % 3 == 0 )); then
      info "  Redpanda Ready=${cond:-unknown} (${i}0s elapsed...)"
    fi
    sleep 10
  done

  if [[ "$ready" != "true" ]]; then
    warn "Redpanda CR did not report Ready in time"
    warn "Diagnostics:"
    kubectl -n "$NAMESPACE_REDPANDA" get redpanda "$REDPANDA_CLUSTER_NAME" -o yaml 2>/dev/null | sed -n '/^status:/,$p' || true
    kubectl -n "$NAMESPACE_REDPANDA" get pods 2>/dev/null || true
    kubectl -n "$NAMESPACE_REDPANDA" get events --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || true
    warn "Continuing; the broker may still be initializing."
    return 0
  fi

  info "✓ Redpanda CR Ready"

  # Broker-level health via rpk (admin API, no SASL required)
  info "Checking cluster health (rpk)..."
  if kubectl -n "$NAMESPACE_REDPANDA" exec "$BROKER_POD" -c redpanda -- rpk cluster health 2>/dev/null | grep -q "Healthy:.*true"; then
    info "✓ rpk cluster health: healthy"
  else
    warn "rpk cluster health did not report healthy yet:"
    kubectl -n "$NAMESPACE_REDPANDA" exec "$BROKER_POD" -c redpanda -- rpk cluster health 2>/dev/null || true
  fi
}

create_redpanda_cluster

# ============================================================================
# Phase 4: Metrics Service (Prometheus endpoint discovery)
# ============================================================================
create_metrics_service() {
  log "=== Phase 4: Metrics Service ==="

  # Plain Service with a named 'metrics' port — the discovery target for the
  # 'redpanda' job in observability.sh extraScrapeConfigs (endpoint role,
  # metrics_path /public_metrics).
  cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: redpanda-metrics
  namespace: ${NAMESPACE_REDPANDA}
  labels:
    app: redpanda-metrics
    component: monitoring
spec:
  selector:
    app.kubernetes.io/name: redpanda
    app.kubernetes.io/instance: ${REDPANDA_CLUSTER_NAME}
  ports:
    - port: 9644
      targetPort: 9644
      name: metrics
YAML

  info "✓ redpanda-metrics Service applied"
  info "  Metrics: http://redpanda-metrics.${NAMESPACE_REDPANDA}.svc.cluster.local:9644/public_metrics"
  info "  (scraped by the 'redpanda' job in observability.sh — rerun observability.sh after first install)"
}

create_metrics_service

# ============================================================================
# Phase 5: Redpanda Console (UI, pgweb pattern)
# ============================================================================
deploy_console() {
  log "=== Phase 5: Redpanda Console ==="

  if [[ "$SKIP_CONSOLE" == "true" ]]; then
    info "Skipping Redpanda Console installation (--skip-console)"
    return 0
  fi

  if [[ -z "${REDPANDA_CONSOLE_HOST:-}" ]]; then
    warn "REDPANDA_CONSOLE_HOST not set (no HOSTNAME in env.properties) - skipping console"
    return 0
  fi

  # Console talks Kafka with the superuser identity (SASL is enforced on the Kafka listener)
  if ! superuser_creds; then
    warn "Superuser secret ${SUPERUSER_SECRET} not found - skipping console"
    return 0
  fi

  kubectl -n "$NAMESPACE_REDPANDA" create secret generic redpanda-console-kafka \
    --from-literal=KAFKA_SASL_USERNAME="$SUPERUSER_NAME" \
    --from-literal=KAFKA_SASL_PASSWORD="$SUPERUSER_PASS" \
    --dry-run=client -o yaml | kubectl apply -f -

  cat <<YAML | kubectl apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redpanda-console
  namespace: ${NAMESPACE_REDPANDA}
  labels:
    app: redpanda-console
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redpanda-console
  template:
    metadata:
      labels:
        app: redpanda-console
    spec:
      containers:
      - name: console
        image: ${REDPANDA_CONSOLE_IMAGE}
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: KAFKA_BROKERS
          value: "${BOOTSTRAP_SERVERS}"
        - name: KAFKA_SASL_ENABLED
          value: "true"
        - name: KAFKA_SASL_MECHANISM
          value: "SCRAM-SHA-256"
        - name: KAFKA_SASL_USERNAME
          valueFrom:
            secretKeyRef:
              name: redpanda-console-kafka
              key: KAFKA_SASL_USERNAME
        - name: KAFKA_SASL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: redpanda-console-kafka
              key: KAFKA_SASL_PASSWORD
        - name: REDPANDA_ADMINAPI_ENABLED
          value: "true"
        - name: REDPANDA_ADMINAPI_URLS
          value: "http://${REDPANDA_CLUSTER_NAME}.${NAMESPACE_REDPANDA}.svc.cluster.local:9644"
        resources:
          requests:
            memory: "128Mi"
            cpu: "50m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /admin/health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /admin/health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: redpanda-console
  namespace: ${NAMESPACE_REDPANDA}
spec:
  selector:
    app: redpanda-console
  ports:
  - port: 8080
    targetPort: 8080
    name: http
YAML

  info "Waiting for Redpanda Console deployment to be ready..."
  kubectl -n "$NAMESPACE_REDPANDA" rollout status deployment/redpanda-console --timeout=300s || true
  info "✓ Redpanda Console deployed"
}

deploy_console

# ============================================================================
# Phase 6: Pomerium ingress + route for the Console
# ============================================================================
expose_console() {
  log "=== Phase 6: Console ingress (Pomerium) ==="

  if [[ "$SKIP_CONSOLE" == "true" || -z "${REDPANDA_CONSOLE_HOST:-}" ]]; then
    info "Skipping console ingress"
    return 0
  fi

  # DNS: covered by the env wildcard if present, else try to create the record
  if provision::cloudflare_read_token 2>/dev/null; then
    if provision::cloudflare_check_wildcard "$HOSTNAME" 2>/dev/null; then
      info "Wildcard DNS covers ${REDPANDA_CONSOLE_HOST}"
    else
      provision::cloudflare_ensure_dns_record "$REDPANDA_CONSOLE_HOST" "$EXTERNAL_IP" || \
        warn "Failed to create DNS record for ${REDPANDA_CONSOLE_HOST} (wildcard may cover it)"
    fi
  fi

  if [[ "${ENFORCE_POMERIUM}" != "true" ]]; then
    warn "ENFORCE_POMERIUM != true - refusing to expose the console without auth"
    return 0
  fi

  cat <<YAML | kubectl apply -f -
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: redpanda-console-pomerium
  namespace: ${NAMESPACE_SSO}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    cert-manager.io/common-name: ${REDPANDA_CONSOLE_HOST}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${REDPANDA_CONSOLE_HOST}
    secretName: redpanda-console-pomerium-tls
  rules:
  - host: ${REDPANDA_CONSOLE_HOST}
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

  local from_url="https://${REDPANDA_CONSOLE_HOST}"
  local to_url="http://redpanda-console.${NAMESPACE_REDPANDA}.svc.cluster.local:8080"
  if provision::pomerium_routes_add "$from_url" "$to_url" "${NAMESPACE_SSO}" true true true; then
    info "✓ Pomerium route ensured: ${from_url} -> ${to_url}"
  else
    warn "Failed to ensure Pomerium route for ${from_url}"
  fi
}

expose_console || true

# ============================================================================
# Summary
# ============================================================================
log "=== Redpanda provisioning complete ==="
info "Namespace:          ${NAMESPACE_REDPANDA}"
info "Broker:             ${BROKER_POD} (${REDPANDA_IMAGE_TAG}, smp=${REDPANDA_SMP}, memory=${REDPANDA_MEMORY})"
info "Bootstrap servers:  ${BOOTSTRAP_SERVERS}"
info "Data dir:           ${REDPANDA_DATA_DIR} on ${REDPANDA_NODE} (PV redpanda-data-pv, ${REDPANDA_STORAGE_SIZE})"
info "Auth:               SASL/SCRAM-SHA-256 (superuser secret: ${SUPERUSER_SECRET})"
if [[ "$SKIP_CONSOLE" != "true" && -n "${REDPANDA_CONSOLE_HOST:-}" ]]; then
  info "Console:            https://${REDPANDA_CONSOLE_HOST} (GitHub OAuth via Pomerium)"
fi
info ""
info "Next steps:"
info "  tools/k3s/redpanda.sh ${ENV_NAME} --watch health"
info "  tools/k3s/redpanda.sh ${ENV_NAME} --provision-credentials <app-id>"
info "  tools/k3s/observability.sh ${ENV_NAME}   # load redpanda scrape job + kafka-journal alerts"
