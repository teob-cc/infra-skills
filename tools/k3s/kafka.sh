#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# K3S Apache Kafka Provisioning (Strimzi operator, KRaft)
# ============================================================================
# Provisions a single-node Apache Kafka for the kafka-journal persistence stack:
# 1. Strimzi cluster operator (Helm chart oci://quay.io/strimzi-helm/strimzi-kafka-operator),
#    watching its own namespace; CRDs applied server-side from the chart on every run
# 2. Static local PV on /data/kafka (class local-storage, node-pinned)
# 3. Kafka (v1) + KafkaNodePool: one combined controller+broker node (KRaft),
#    listener `internal` :9093 SASL_PLAINTEXT SCRAM-SHA-512, simple authorization with
#    the KafkaUser `admin` as superuser, entity operator (topic + user), kafkaExporter,
#    JMX exporter metrics (ConfigMap kafka-metrics)
# 4. kafka-metrics and kafka-exporter-metrics Services for Prometheus endpoint discovery
# 5. App KafkaUsers from envs/<env>/kafka-users/*.yaml (written by --provision-credentials)
# 6. Kafbat UI behind Pomerium (console.<env>, pgweb pattern)
# 7. Grafana dashboard `kafka-journal` (ConfigMap grafana-dashboard-kafka-journal, labelled
#    grafana_dashboard=1, from tools/k3s/kafka/kafka-journal-dashboard.json)
#
# Usage:
#   tools/k3s/kafka.sh <env-name> [options]
#
# Options:
#   --skip-operator          Skip operator installation (use existing)
#   --skip-console           Skip the Kafbat UI and its route
#   --force-console          Take console.<env> even when another Ingress or Pomerium route
#                            owns it (by default kafka.sh warns and skips the console)
#   --force-cleanup          Remove the Kafka CRs + operator before reinstalling (PV/PVC and
#                            the cluster ID kept, so the broker comes back with its data)
#   --show-credentials [app-id]  Display Kafka credentials and exit
#   --show-resources         Display current Kafka resource usage and exit
#   --dashboard-only         Only (re)apply the kafka-journal Grafana dashboard and exit
#   --watch [kind]           Inspect a running broker (kind: help|health|topics|groups|logs)
#   --provision-credentials <app-id>  Provision a SCRAM-SHA-512 KafkaUser for an application
#                            (keeps an existing password; add --rotate-password for a new one)
#
# Sizing (test defaults; prod overrides via env vars):
#   KAFKA_STORAGE_SIZE=100Gi KAFKA_MEMORY=3Gi KAFKA_HEAP=2g tools/k3s/kafka.sh prod
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

# --- Parse arguments ---
if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--skip-operator] [--skip-console] [--force-console] [--force-cleanup] [--show-credentials [app-id]] [--show-resources] [--dashboard-only] [--watch [kind]] [--provision-credentials <app-id> [--rotate-password]]" >&2
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
FORCE_CONSOLE=false
ROTATE_PASSWORD=false
FORCE_CLEANUP=false
SHOW_CREDENTIALS=false
SHOW_CREDENTIALS_APP_ID=""
SHOW_RESOURCES=false
DASHBOARD_ONLY=false
WATCH=false
WATCH_KIND="help"
PROVISION_CREDENTIALS=false
APP_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-operator) SKIP_OPERATOR=true; shift ;;
    --skip-console) SKIP_CONSOLE=true; shift ;;
    --force-console) FORCE_CONSOLE=true; shift ;;
    --rotate-password) ROTATE_PASSWORD=true; shift ;;
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
    --dashboard-only) DASHBOARD_ONLY=true; shift ;;
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
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validation ---
if [[ "$FORCE_CLEANUP" == "true" && "$SKIP_OPERATOR" == "true" ]]; then
  echo "ERROR: --force-cleanup reinstalls the operator; it cannot be combined with --skip-operator" >&2
  exit 1
fi
if [[ "$ROTATE_PASSWORD" == "true" && "$PROVISION_CREDENTIALS" != "true" ]]; then
  echo "ERROR: --rotate-password only goes with --provision-credentials <app-id>" >&2
  exit 1
fi
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
need kubectl
need helm
need jq
need yq
need openssl

if ! provision::require_tools; then
  exit 1
fi

if ! provision::validate_kubectl_context; then
  exit 1
fi

# --- Logging helpers ---
log() { echo "[kafka] $*"; }
info() { echo "[kafka:info] $*"; }
warn() { echo "[kafka:warn] $*" >&2; }
err() { echo "[kafka:error] $*" >&2; }

# --- Config defaults ---
: "${NAMESPACE_KAFKA:=kafka}"
# Strimzi 1.3.1 (2026-11-04) supports Kafka 4.2.0-4.3.2; 4.3.2 is its default. Kafka 4.4.x
# needs a Strimzi release that lists it in kafka-versions.yaml. Bump in this order:
# STRIMZI_VERSION, then KAFKA_VERSION, then KAFKA_METADATA_VERSION (docs/KAFKA-JOURNAL-OPS.md).
: "${STRIMZI_VERSION:=1.3.1}"
: "${STRIMZI_CHART:=oci://quay.io/strimzi-helm/strimzi-kafka-operator}"
: "${KAFKA_VERSION:=4.3.2}"
: "${KAFKA_METADATA_VERSION:=4.3-IV0}"
: "${KAFKA_CLUSTER_NAME:=kafka}"
: "${KAFKA_POOL_NAME:=dual-role}"
: "${KAFKA_STORAGE_SIZE:=25Gi}"               # prod: 100Gi
: "${KAFKA_MEMORY:=2Gi}"                      # container request = limit
: "${KAFKA_HEAP:=1g}"                         # -Xms = -Xmx
: "${KAFKA_CPU_REQUEST:=500m}"
: "${KAFKA_CPU_LIMIT:=2}"
: "${KAFKA_DATA_DIR:=/data/kafka}"
: "${KAFKA_NODE:=$ENV_NAME}"                  # kubernetes.io/hostname to pin PV + broker
# Apps create their topics (or declare KafkaTopics); the broker does not auto-create them.
: "${KAFKA_AUTO_CREATE_TOPICS:=false}"
: "${KAFKA_SUPERUSER:=admin}"

# Kafbat UI (Apache-2.0 fork of provectus kafka-ui) — pgweb pattern: Deployment +
# Pomerium-routed Ingress. Pinned to v1.5.0: v1.5.1 was published the day this was
# written (2026-11-20) and is not yet two weeks old.
: "${KAFBAT_UI_IMAGE:=ghcr.io/kafbat/kafka-ui:v1.5.0}"
# Read-only by default: the UI connects as the superuser, and the Pomerium route lets any
# authenticated org member in, so a writable UI would let anyone delete journal topics.
# KAFBAT_UI_READONLY=false makes it writable (then narrow the route to admins).
: "${KAFBAT_UI_READONLY:=true}"
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"
: "${INGRESS_CLASS:=traefik}"
: "${CLUSTER_ISSUER:=letsencrypt-prod}"
: "${ENFORCE_POMERIUM:=true}"
if [[ -n "${HOSTNAME:-}" ]]; then
  # The Kafbat UI host. While another Ingress or Pomerium route owns it, kafka.sh skips the
  # console (deploy_console); --force-console takes it over.
  KAFKA_CONSOLE_HOST="${KAFKA_CONSOLE_HOST:-console.${HOSTNAME}}"
fi

# Deterministic names Strimzi derives from the CRs
BROKER_POD="${KAFKA_CLUSTER_NAME}-${KAFKA_POOL_NAME}-0"
# JBOD volume id 0 (the Strimzi single-node example layout): data-<id>-<pod>
DATA_PVC="data-0-${BROKER_POD}"
DATA_PV="kafka-data-pv"
SUPERUSER_SECRET="${KAFKA_SUPERUSER}"   # the User Operator names the Secret after the KafkaUser
BOOTSTRAP_SERVERS="${KAFKA_CLUSTER_NAME}-kafka-bootstrap.${NAMESPACE_KAFKA}.svc.cluster.local:9093"
KAFKA_BIN="/opt/kafka/bin"
USERS_DIR="$ENVS_ROOT/${ENV_NAME}/kafka-users"
METRICS_RULES_FILE="$REPO_ROOT/tools/k3s/kafka/kafka-metrics-config.yml"
DASHBOARD_FILE="$REPO_ROOT/tools/k3s/kafka/kafka-journal-dashboard.json"
: "${NAMESPACE_OBSERVABILITY:=observability}"

# --- Shared helpers ---

secret_field() {
  # secret_field <namespace> <secret> <key> -> decoded value, empty when missing
  kubectl -n "$1" get secret "$2" -o json 2>/dev/null | jq -r --arg k "$3" '.data[$k] // empty' | base64 -d 2>/dev/null || true
}

superuser_creds() {
  SUPERUSER_PASS="$(secret_field "$NAMESPACE_KAFKA" "$SUPERUSER_SECRET" password)"
  [[ -n "$SUPERUSER_PASS" ]]
}

# Run a Kafka CLI tool in the broker pod as the superuser. The client properties go in
# on stdin (--command-config /dev/stdin), so the password never lands in a file or argv.
# The container's KAFKA_HEAP_OPTS is the broker's heap (-Xms=-Xmx); a CLI JVM started with
# it inside the broker's memory limit could get the broker OOM-killed, hence 256m.
kafka_admin() {
  local tool="$1"; shift
  superuser_creds || { err "Superuser secret ${SUPERUSER_SECRET} not found in ${NAMESPACE_KAFKA}"; exit 1; }
  printf '%s\n' \
    "security.protocol=SASL_PLAINTEXT" \
    "sasl.mechanism=SCRAM-SHA-512" \
    "sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"${KAFKA_SUPERUSER}\" password=\"${SUPERUSER_PASS}\";" |
    kubectl -n "$NAMESPACE_KAFKA" exec -i "$BROKER_POD" -c kafka -- \
      env KAFKA_HEAP_OPTS=-Xmx256m "${KAFKA_BIN}/${tool}" --bootstrap-server "$BOOTSTRAP_SERVERS" --command-config /dev/stdin "$@"
}

# Strimzi keeps the KRaft cluster ID only in the Kafka CR's status. A Kafka CR that is
# deleted and created again gets a new ID, and the broker then refuses its own data
# ("Invalid cluster.id in .../meta.properties"). kafka.sh records the ID in this ConfigMap
# and restores it when it has to create the CR again (Strimzi's recovery procedure: create
# paused, set status.clusterId, unpause). KAFKA_CLUSTER_ID overrides the record, for when
# the namespace (and so the ConfigMap) is gone but /data/kafka is kept: the ID is the
# cluster.id line of /data/kafka/kafka-log0/meta.properties on the node.
CLUSTER_ID_CM="${KAFKA_CLUSTER_NAME}-cluster-id"
: "${KAFKA_CLUSTER_ID:=}"

remember_cluster_id() {
  local ready id recorded
  ready=$(kubectl -n "$NAMESPACE_KAFKA" get kafka.kafka.strimzi.io "$KAFKA_CLUSTER_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  id=$(kubectl -n "$NAMESPACE_KAFKA" get kafka.kafka.strimzi.io "$KAFKA_CLUSTER_NAME" \
    -o jsonpath='{.status.clusterId}' 2>/dev/null || true)
  [[ -n "$id" ]] || return 0
  recorded=$(recorded_cluster_id)
  [[ "$id" == "$recorded" ]] && return 0
  # The first ID is recorded as soon as the status carries one. A different ID replaces
  # the record only once the cluster is Ready, which proves it matches the data: a CR
  # recreated outside kafka.sh gets a new ID and crash-loops, and must not overwrite the
  # ID its data needs.
  if [[ -n "$recorded" && "$ready" != "True" ]]; then
    warn "Kafka CR has cluster ID ${id}, ConfigMap ${CLUSTER_ID_CM} records ${recorded}; keeping the record until the cluster is Ready"
    return 0
  fi
  kubectl -n "$NAMESPACE_KAFKA" create configmap "$CLUSTER_ID_CM" --from-literal=clusterId="$id" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

recorded_cluster_id() {
  kubectl -n "$NAMESPACE_KAFKA" get configmap "$CLUSTER_ID_CM" -o jsonpath='{.data.clusterId}' 2>/dev/null || true
}

require_broker() {
  if ! kubectl -n "$NAMESPACE_KAFKA" get kafka.kafka.strimzi.io "$KAFKA_CLUSTER_NAME" >/dev/null 2>&1; then
    err "Kafka cluster not found in namespace: $NAMESPACE_KAFKA"
    err "Run provisioning first: tools/k3s/kafka.sh ${ENV_NAME}"
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
      err "Provision credentials first: tools/k3s/kafka.sh ${ENV_NAME} --provision-credentials ${app_id}"
      exit 1
    fi

    local servers username password
    servers=$(secret_field "$app_namespace" "$secret_name" KAFKA_BOOTSTRAP_SERVERS)
    username=$(secret_field "$app_namespace" "$secret_name" KAFKA_USERNAME)
    password=$(secret_field "$app_namespace" "$secret_name" KAFKA_PASSWORD)

    if [[ -z "$username" || -z "$password" ]]; then
      err "Failed to retrieve credentials from secret '${secret_name}' in namespace '${app_namespace}'"
      exit 1
    fi

    echo "KAFKA_BOOTSTRAP_SERVERS=${servers:-$BOOTSTRAP_SERVERS}"
    echo "KAFKA_USERNAME=${username}"
    echo "KAFKA_PASSWORD=${password}"
    echo ""
    echo "# SASL mechanism: SCRAM-SHA-512, security protocol: SASL_PLAINTEXT (internal listener)"
    echo "# Secret: ${secret_name} (namespace: ${app_namespace})"
    exit 0
  fi

  if ! superuser_creds; then
    err "Superuser secret ${SUPERUSER_SECRET} not found in namespace: $NAMESPACE_KAFKA"
    err "Run provisioning first: tools/k3s/kafka.sh ${ENV_NAME}"
    exit 1
  fi
  echo "KAFKA_BOOTSTRAP_SERVERS=${BOOTSTRAP_SERVERS}"
  echo "KAFKA_USERNAME=${KAFKA_SUPERUSER}"
  echo "KAFKA_PASSWORD=${SUPERUSER_PASS}"
  echo ""
  echo "# Superuser (SCRAM-SHA-512). Secret: ${SUPERUSER_SECRET} (namespace: ${NAMESPACE_KAFKA}, managed by the User Operator)"
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

  echo "=== Kafka Resource Usage ==="
  echo ""
  echo "--- Strimzi CR status ---"
  kubectl -n "$NAMESPACE_KAFKA" get kafka.kafka.strimzi.io,kafkanodepool,kafkauser,kafkatopic 2>/dev/null || true
  echo ""
  echo "--- Current Resource Usage (kubectl top) ---"
  kubectl top pods -n "$NAMESPACE_KAFKA" 2>/dev/null || echo "Metrics not available"
  echo ""
  echo "--- Pod Resource Requests/Limits ---"
  kubectl -n "$NAMESPACE_KAFKA" get pods -o custom-columns=\
'NAME:.metadata.name,'\
'CPU_REQ:.spec.containers[0].resources.requests.cpu,'\
'CPU_LIM:.spec.containers[0].resources.limits.cpu,'\
'MEM_REQ:.spec.containers[0].resources.requests.memory,'\
'MEM_LIM:.spec.containers[0].resources.limits.memory' 2>/dev/null || true
  echo ""
  echo "--- Storage ---"
  kubectl -n "$NAMESPACE_KAFKA" get pvc -o wide 2>/dev/null || true
  kubectl get pv "$DATA_PV" 2>/dev/null || true
  echo ""
  echo "--- Broker disk ---"
  kubectl -n "$NAMESPACE_KAFKA" exec "$BROKER_POD" -c kafka -- df -h /var/lib/kafka/data-0 2>/dev/null || true
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
=== Kafka Watch/Inspect Toolbox ===

Run one of:
  tools/k3s/kafka.sh ${ENV_NAME} --watch health   # CR conditions + KRaft quorum status
  tools/k3s/kafka.sh ${ENV_NAME} --watch topics   # kafka-topics.sh --describe
  tools/k3s/kafka.sh ${ENV_NAME} --watch groups   # kafka-consumer-groups.sh, lag per partition
  tools/k3s/kafka.sh ${ENV_NAME} --watch logs     # broker logs (follow)

Useful one-liners:
  kubectl -n ${NAMESPACE_KAFKA} get kafka ${KAFKA_CLUSTER_NAME} -o yaml | sed -n '/^status:/,\$p'
  kubectl -n ${NAMESPACE_KAFKA} get kafkanodepool,kafkauser,kafkatopic
  kubectl -n ${NAMESPACE_KAFKA} get pods -o wide
  curl the metrics endpoints:
    kubectl -n ${NAMESPACE_KAFKA} exec ${BROKER_POD} -c kafka -- curl -s localhost:9404/metrics | head
EOF
      exit 0
      ;;
    health)
      kubectl -n "$NAMESPACE_KAFKA" get kafka.kafka.strimzi.io "$KAFKA_CLUSTER_NAME" \
        -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}'
      echo ""
      kafka_admin kafka-metadata-quorum.sh describe --status
      ;;
    topics)
      kafka_admin kafka-topics.sh --describe --exclude-internal
      ;;
    groups)
      kafka_admin kafka-consumer-groups.sh --list
      echo ""
      kafka_admin kafka-consumer-groups.sh --describe --all-groups
      ;;
    logs)
      kubectl -n "$NAMESPACE_KAFKA" logs "$BROKER_POD" -c kafka -f --tail=200
      ;;
    *)
      err "Unknown watch kind: ${kind}"
      err "Run: tools/k3s/kafka.sh ${ENV_NAME} --watch help"
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
# Writes two files and applies both:
#   secrets.plain/<app>-kafka.secret.yaml  Secret <app>-kafka-password (ns kafka; the
#       KafkaUser reads its SCRAM password from it) + Secret <app>-kafka (app namespace;
#       bootstrap servers, username, password for the app)
#   kafka-users/<app>.yaml  the KafkaUser (no secret in it; kafka.sh re-applies every file
#       in this directory, so a rebuilt cluster gets its users back)
# The KafkaUser is kept out of secrets.plain on purpose: tools/sops/apply.sh runs before
# this script and would fail on a kind whose CRD is not installed yet.
provision_credentials() {
  local app_id="$1"
  local app_namespace="${APP_NAMESPACE:-default}"
  # Topics, groups and transactional ids the app may use start with this prefix. The
  # default ends in a dot, which an app id cannot contain, so app "teob" gets "teob." and
  # never reaches the "teob-rust." resources of app "teob-rust". KAFKA_ACL_PREFIX sets
  # another prefix (for names that do not start with "<app-id>."), or "*" for everything.
  local acl_prefix="${KAFKA_ACL_PREFIX:-${app_id}.}"

  if [[ ! "$app_id" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    err "Invalid app-id: ${app_id}"
    err "App ID must be lowercase alphanumeric with hyphens (e.g., 'myapp')"
    exit 1
  fi
  if [[ "$app_id" == "$KAFKA_SUPERUSER" ]]; then
    err "App ID '${app_id}' is the superuser name; choose another"
    exit 1
  fi

  log "=== Provisioning Kafka credentials for application: ${app_id} ==="
  require_broker

  local secrets_dir="$ENVS_ROOT/${ENV_NAME}/secrets.plain"
  local secret_file="${secrets_dir}/${app_id}-kafka.secret.yaml"
  local user_file="${USERS_DIR}/${app_id}.yaml"
  mkdir -p "$secrets_dir" "$USERS_DIR"

  # A rerun keeps the app's password (the live Secret first, else the working copy in
  # secrets.plain), so it does not break a running app. --rotate-password makes a new one.
  local app_password="" pw_source=""
  if [[ "$ROTATE_PASSWORD" != "true" ]]; then
    app_password=$(secret_field "$NAMESPACE_KAFKA" "${app_id}-kafka-password" password)
    pw_source="Secret ${NAMESPACE_KAFKA}/${app_id}-kafka-password"
    if [[ -z "$app_password" && -f "$secret_file" ]]; then
      app_password=$(NAME="${app_id}-kafka-password" yq -r \
        'select(.kind == "Secret" and .metadata.name == strenv(NAME)) | .stringData.password // ""' \
        "$secret_file" 2>/dev/null | head -1)
      pw_source="${secret_file}"
    fi
  fi
  if [[ -n "$app_password" ]]; then
    info "Keeping the existing password (from ${pw_source}); --rotate-password makes a new one"
  else
    app_password=$(openssl rand -base64 24 | tr -d '\n')
    info "Generated a new password$([[ "$ROTATE_PASSWORD" == "true" ]] && echo ' (--rotate-password): restart the app after the Secret is applied')"
  fi

  info "Creating secret file: ${secret_file}"
  cat > "$secret_file" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${app_id}-kafka-password
  namespace: ${NAMESPACE_KAFKA}
type: Opaque
stringData:
  # SCRAM-SHA-512 password the Strimzi User Operator sets for KafkaUser ${app_id}
  password: ${app_password}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${app_id}-kafka
  namespace: ${app_namespace}
type: Opaque
stringData:
  # Kafka bootstrap servers (in-cluster internal listener, SASL_PLAINTEXT)
  KAFKA_BOOTSTRAP_SERVERS: ${BOOTSTRAP_SERVERS}

  # SASL/SCRAM-SHA-512 username
  KAFKA_USERNAME: ${app_id}

  # SASL/SCRAM-SHA-512 password
  KAFKA_PASSWORD: ${app_password}
YAML

  # ACLs: the app's own topics, consumer groups and transactional ids by prefix, plus
  # idempotent produce. KAFKA_ACL_PREFIX='*' grants every resource of those types.
  local pattern="prefix" name="$acl_prefix"
  if [[ "$acl_prefix" == "*" ]]; then pattern="literal"; fi
  info "Creating KafkaUser manifest: ${user_file} (ACL prefix: ${acl_prefix})"
  cat > "$user_file" <<YAML
# Written by tools/k3s/kafka.sh --provision-credentials ${app_id}; re-applied by every
# kafka.sh run. The password comes from Secret ${app_id}-kafka-password (secrets.sops).
apiVersion: kafka.strimzi.io/v1
kind: KafkaUser
metadata:
  name: ${app_id}
  namespace: ${NAMESPACE_KAFKA}
  labels:
    strimzi.io/cluster: ${KAFKA_CLUSTER_NAME}
spec:
  authentication:
    type: scram-sha-512
    password:
      valueFrom:
        secretKeyRef:
          name: ${app_id}-kafka-password
          key: password
  authorization:
    type: simple
    acls:
      - resource: { type: topic, name: "${name}", patternType: ${pattern} }
        operations: [Read, Write, Create, Delete, Describe, DescribeConfigs]
        host: "*"
      - resource: { type: group, name: "${name}", patternType: ${pattern} }
        operations: [Read, Describe, Delete]
        host: "*"
      - resource: { type: transactionalId, name: "${name}", patternType: ${pattern} }
        operations: [Write, Describe]
        host: "*"
      - resource: { type: cluster }
        operations: [IdempotentWrite, Describe]
        host: "*"
YAML

  kubectl get ns "$app_namespace" >/dev/null 2>&1 || kubectl create ns "$app_namespace"

  info "Applying secrets and KafkaUser..."
  kubectl apply -f "$secret_file" || { err "Failed to apply ${secret_file}"; exit 1; }
  kubectl apply -f "$user_file" || { err "Failed to apply ${user_file}"; exit 1; }

  info "Waiting for KafkaUser ${app_id} to be Ready..."
  if kubectl -n "$NAMESPACE_KAFKA" wait "kafkauser/${app_id}" --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
    info "✓ KafkaUser ${app_id} Ready"
  else
    warn "KafkaUser ${app_id} not Ready yet: kubectl -n ${NAMESPACE_KAFKA} describe kafkauser ${app_id}"
  fi

  echo ""
  info "=== Credentials Provisioned ==="
  info "Application ID:     ${app_id}"
  info "Username:           ${app_id}"
  info "Secret name:        ${app_id}-kafka (namespace: ${app_namespace})"
  info "Secret file:        ${secret_file}"
  info "KafkaUser file:     ${user_file}"
  info ""
  info "Bootstrap servers:  ${BOOTSTRAP_SERVERS}"
  info "Mechanism:          SCRAM-SHA-512 (SASL_PLAINTEXT, internal listener)"
  info ""
  info "Encrypt for git:    tools/sops/encrypt.sh ${ENV_NAME} ${app_id}-kafka.secret.yaml"
  info "Commit:             envs/${ENV_NAME}/kafka-users/${app_id}.yaml"
  echo ""
  exit 0
}

if [[ "$PROVISION_CREDENTIALS" == "true" ]]; then
  provision_credentials "$APP_ID"
fi

# ============================================================================
# Grafana dashboard (ConfigMap for the Grafana sidecar, mysql.sh pattern)
# ============================================================================
# The `kafka-journal` dashboard that docs/KAFKA-JOURNAL-OPS.md points at: broker and
# exporter health, partitions, message and byte rates, replicator lag (the expression of
# the kafka-journal alert group in observability.sh), replicator assignment, data disk.
# Grafana's dashboard sidecar loads ConfigMaps labelled grafana_dashboard=1 in the
# observability namespace into the "Shared" folder; no Grafana restart is needed.
deploy_dashboard() {
  log "=== Grafana dashboard: kafka-journal ==="
  if ! kubectl get ns "$NAMESPACE_OBSERVABILITY" >/dev/null 2>&1; then
    info "Namespace ${NAMESPACE_OBSERVABILITY} not found - skipping the kafka-journal dashboard"
    info "  After tools/k3s/observability.sh ${ENV_NAME}: tools/k3s/kafka.sh ${ENV_NAME} --dashboard-only"
    return 0
  fi
  if ! jq -e '.uid == "kafka-journal"' "$DASHBOARD_FILE" >/dev/null 2>&1; then
    err "Invalid dashboard JSON: ${DASHBOARD_FILE}"
    return 1
  fi
  kubectl -n "$NAMESPACE_OBSERVABILITY" create configmap grafana-dashboard-kafka-journal \
    --from-file=kafka-journal.json="$DASHBOARD_FILE" \
    --dry-run=client -o yaml \
    | yq eval '.metadata.labels.grafana_dashboard = "1"' - \
    | kubectl apply -f - >/dev/null
  info "✓ ConfigMap ${NAMESPACE_OBSERVABILITY}/grafana-dashboard-kafka-journal applied (Grafana folder 'Shared', uid kafka-journal)"
}

if [[ "$DASHBOARD_ONLY" == "true" ]]; then
  deploy_dashboard
  exit 0
fi

log "Starting Kafka provisioning for environment: ${ENV_NAME}"

# ============================================================================
# Phase 1: Strimzi cluster operator
# ============================================================================
install_operator() {
  log "=== Phase 1: Strimzi operator ==="

  if [[ "$SKIP_OPERATOR" == "true" ]]; then
    info "Skipping operator installation (--skip-operator)"
    return 0
  fi

  if [[ "$FORCE_CLEANUP" == "true" ]]; then
    info "Force cleanup requested - removing Kafka CRs and operator"
    # Order: the CRs while the operator still runs (it removes what it owns), then the
    # operator. CRDs, the namespace, KafkaUsers/KafkaTopics and the PV/PVC stay
    # (deleteClaim: false, Retain), so topics and data survive a reinstall; the cluster
    # ID is recorded first so the new Kafka CR can take it over (see remember_cluster_id).
    remember_cluster_id
    kubectl -n "$NAMESPACE_KAFKA" delete kafka.kafka.strimzi.io "$KAFKA_CLUSTER_NAME" --ignore-not-found=true --timeout=120s || true
    kubectl -n "$NAMESPACE_KAFKA" delete kafkanodepool "$KAFKA_POOL_NAME" --ignore-not-found=true --timeout=120s || true
    helm uninstall strimzi-cluster-operator --namespace "$NAMESPACE_KAFKA" --ignore-not-found=true
    info "✓ Force cleanup completed"
  fi

  kubectl get ns "$NAMESPACE_KAFKA" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_KAFKA"

  # Helm installs chart CRDs on first install only and never upgrades them. Apply them
  # server-side from the pinned chart on every run instead, so a STRIMZI_VERSION bump
  # brings its CRDs along.
  info "Applying Strimzi ${STRIMZI_VERSION} CRDs (server-side)..."
  helm show crds "$STRIMZI_CHART" --version "$STRIMZI_VERSION" | \
    kubectl apply --server-side --force-conflicts --field-manager=infra-skills-strimzi-crds -f - >/dev/null
  info "✓ CRDs applied"

  local installed=""
  installed=$(helm list -n "$NAMESPACE_KAFKA" -o json 2>/dev/null | \
    jq -r '.[] | select(.name=="strimzi-cluster-operator") | .chart' || true)
  if [[ "$installed" == "strimzi-kafka-operator-${STRIMZI_VERSION}" ]] && \
     kubectl -n "$NAMESPACE_KAFKA" get deploy strimzi-cluster-operator >/dev/null 2>&1; then
    info "Strimzi operator ${STRIMZI_VERSION} already installed"
    return 0
  fi

  info "Installing Strimzi operator (chart ${STRIMZI_VERSION})..."
  # watchNamespaces empty = the release namespace only: the Kafka cluster, its users and
  # topics all live in ${NAMESPACE_KAFKA}.
  helm upgrade --install strimzi-cluster-operator "$STRIMZI_CHART" \
    --namespace "$NAMESPACE_KAFKA" \
    --version "$STRIMZI_VERSION" \
    --skip-crds \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=384Mi \
    --set resources.limits.memory=384Mi \
    --wait \
    --timeout 5m

  info "✓ Strimzi operator installed"
}

install_operator

# ============================================================================
# Phase 2: Storage (static local PV on the pinned node)
# ============================================================================
prepare_storage() {
  log "=== Phase 2: Storage ==="

  kubectl get ns "$NAMESPACE_KAFKA" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_KAFKA"

  # One-shot privileged Job: create + chown the data dir on the target node
  # (Strimzi's Kafka container runs as uid 1001, gid 0)
  info "Ensuring ${KAFKA_DATA_DIR} exists on node ${KAFKA_NODE}..."
  kubectl -n "$NAMESPACE_KAFKA" delete job kafka-storage-init --ignore-not-found=true >/dev/null 2>&1
  cat <<YAML | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: kafka-storage-init
  namespace: ${NAMESPACE_KAFKA}
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/hostname: ${KAFKA_NODE}
      containers:
        - name: init
          image: busybox:1.36
          command: ["sh", "-c", "mkdir -p /host/dir && chown -R 1001:0 /host/dir && chmod 0770 /host/dir"]
          securityContext:
            runAsUser: 0
          volumeMounts:
            - name: host-data
              mountPath: /host/dir
      volumes:
        - name: host-data
          hostPath:
            path: ${KAFKA_DATA_DIR}
            type: DirectoryOrCreate
YAML
  kubectl -n "$NAMESPACE_KAFKA" wait --for=condition=complete job/kafka-storage-init --timeout=120s || {
    err "Storage init job did not complete; check: kubectl -n ${NAMESPACE_KAFKA} logs job/kafka-storage-init"
    exit 1
  }
  info "✓ Data directory ready"

  # StorageClass + static PV (same pattern as scylla.sh). claimRef pins the
  # PV to the PVC name Strimzi derives (data-<volume id>-<pod>), so it cannot bind to
  # another local-storage claim.
  info "Applying StorageClass local-storage + PV ${DATA_PV}..."
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
  name: ${DATA_PV}
spec:
  capacity:
    storage: ${KAFKA_STORAGE_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  claimRef:
    namespace: ${NAMESPACE_KAFKA}
    name: ${DATA_PVC}
  local:
    path: ${KAFKA_DATA_DIR}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${KAFKA_NODE}
YAML
  info "✓ Static PV applied"
}

prepare_storage

# ============================================================================
# Phase 3: Kafka cluster (KafkaNodePool + Kafka + superuser)
# ============================================================================
create_kafka_cluster() {
  log "=== Phase 3: Kafka cluster ==="

  if [[ ! -f "$METRICS_RULES_FILE" ]]; then
    err "JMX exporter rules not found: ${METRICS_RULES_FILE}"
    exit 1
  fi
  info "Applying ConfigMap kafka-metrics (JMX exporter rules)..."
  kubectl -n "$NAMESPACE_KAFKA" create configmap kafka-metrics \
    --from-file=kafka-metrics-config.yml="$METRICS_RULES_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -

  # A Kafka CR created again over existing data must take over the cluster ID of that data
  # (KAFKA_CLUSTER_ID, else the recorded one): when the CR is missing, or has no cluster ID
  # yet (also a restore that stopped halfway).
  local restore_id="" pause_block="" current_id="" id_source
  current_id=$(kubectl -n "$NAMESPACE_KAFKA" get kafka.kafka.strimzi.io "$KAFKA_CLUSTER_NAME" \
    -o jsonpath='{.status.clusterId}' 2>/dev/null || true)
  if [[ -n "$KAFKA_CLUSTER_ID" && -n "$current_id" && "$current_id" != "$KAFKA_CLUSTER_ID" ]]; then
    err "KAFKA_CLUSTER_ID=${KAFKA_CLUSTER_ID}, but Kafka CR ${KAFKA_CLUSTER_NAME} already has cluster ID ${current_id}."
    err "A running CR's ID is not changed in place: delete the Kafka CR (the PV/PVC stay), then rerun with KAFKA_CLUSTER_ID."
    exit 1
  fi
  if [[ -z "$current_id" ]]; then
    if [[ -n "$KAFKA_CLUSTER_ID" ]]; then
      restore_id="$KAFKA_CLUSTER_ID"; id_source="KAFKA_CLUSTER_ID"
    else
      restore_id=$(recorded_cluster_id); id_source="ConfigMap ${CLUSTER_ID_CM}"
    fi
  fi
  if [[ -n "$restore_id" ]]; then
    info "Kafka CR has no cluster ID, ${id_source} gives ${restore_id}: applying it paused to restore the ID"
    pause_block=$'  annotations:\n    strimzi.io/pause-reconciliation: "true"'
  fi

  info "Applying KafkaNodePool + Kafka (Kafka ${KAFKA_VERSION}, metadata ${KAFKA_METADATA_VERSION}, heap ${KAFKA_HEAP}, memory ${KAFKA_MEMORY})..."
  cat <<YAML | kubectl apply -f -
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: ${KAFKA_POOL_NAME}
  namespace: ${NAMESPACE_KAFKA}
  labels:
    strimzi.io/cluster: ${KAFKA_CLUSTER_NAME}
spec:
  replicas: 1
  roles:
    - controller
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: ${KAFKA_STORAGE_SIZE}
        class: local-storage
        deleteClaim: false
        kraftMetadata: shared
  resources:
    requests:
      cpu: "${KAFKA_CPU_REQUEST}"
      memory: ${KAFKA_MEMORY}
    limits:
      cpu: "${KAFKA_CPU_LIMIT}"
      memory: ${KAFKA_MEMORY}
  jvmOptions:
    "-Xms": ${KAFKA_HEAP}
    "-Xmx": ${KAFKA_HEAP}
  template:
    pod:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - ${KAFKA_NODE}
---
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: ${KAFKA_CLUSTER_NAME}
  namespace: ${NAMESPACE_KAFKA}
${pause_block}
spec:
  kafka:
    version: ${KAFKA_VERSION}
    metadataVersion: ${KAFKA_METADATA_VERSION}
    listeners:
      # In-cluster apps connect here: SASL_PLAINTEXT, SCRAM-SHA-512.
      - name: internal
        port: 9093
        type: internal
        tls: false
        authentication:
          type: scram-sha-512
    authorization:
      type: simple
      superUsers:
        - ${KAFKA_SUPERUSER}
    config:
      # Single node: Kafka's defaults assume three brokers, and transactions hang on an
      # internal topic that cannot reach its replication factor.
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      share.coordinator.state.topic.replication.factor: 1
      share.coordinator.state.topic.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
      auto.create.topics.enable: ${KAFKA_AUTO_CREATE_TOPICS}
    metricsConfig:
      type: jmxPrometheusExporter
      valueFrom:
        configMapKeyRef:
          name: kafka-metrics
          key: kafka-metrics-config.yml
  entityOperator:
    topicOperator:
      resources:
        requests: { cpu: 50m, memory: 256Mi }
        limits: { memory: 384Mi }
    userOperator:
      resources:
        requests: { cpu: 50m, memory: 256Mi }
        limits: { memory: 384Mi }
  kafkaExporter:
    # Consumer-group lag per partition (kafka_consumergroup_lag), read by the
    # kafka-journal alert group in observability.sh
    topicRegex: ".*"
    groupRegex: ".*"
    resources:
      requests: { cpu: 50m, memory: 64Mi }
      limits: { memory: 256Mi }
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaUser
metadata:
  name: ${KAFKA_SUPERUSER}
  namespace: ${NAMESPACE_KAFKA}
  labels:
    strimzi.io/cluster: ${KAFKA_CLUSTER_NAME}
spec:
  # Superuser through spec.kafka.authorization.superUsers, so no ACLs. The User Operator
  # generates the password into Secret ${SUPERUSER_SECRET} (keys password, sasl.jaas.config).
  authentication:
    type: scram-sha-512
YAML

  if [[ -n "$restore_id" ]]; then
    # Polled, not `kubectl wait`: a paused CR keeps status.observedGeneration at 0, and
    # kubectl wait treats every condition of such a status as stale.
    local paused="" _try
    for _try in {1..24}; do
      paused=$(kubectl -n "$NAMESPACE_KAFKA" get kafka.kafka.strimzi.io "$KAFKA_CLUSTER_NAME" \
        -o jsonpath='{.status.conditions[?(@.type=="ReconciliationPaused")].status}' 2>/dev/null || true)
      [[ "$paused" == "True" ]] && break
      sleep 5
    done
    if [[ "$paused" != "True" ]]; then
      err "Kafka CR did not report ReconciliationPaused; cluster ID not restored."
      err "It stays paused; set status.clusterId to ${restore_id} by hand, then remove the strimzi.io/pause-reconciliation annotation."
      exit 1
    fi
    kubectl -n "$NAMESPACE_KAFKA" patch kafka.kafka.strimzi.io "$KAFKA_CLUSTER_NAME" --subresource status \
      --type merge -p "{\"status\":{\"clusterId\":\"${restore_id}\"}}" >/dev/null
    if [[ "$(kubectl -n "$NAMESPACE_KAFKA" get kafka.kafka.strimzi.io "$KAFKA_CLUSTER_NAME" -o jsonpath='{.status.clusterId}')" != "$restore_id" ]]; then
      err "status.clusterId did not take ${restore_id}; the Kafka CR stays paused. Fix it by hand, then unpause."
      exit 1
    fi
    kubectl -n "$NAMESPACE_KAFKA" annotate kafka.kafka.strimzi.io "$KAFKA_CLUSTER_NAME" strimzi.io/pause-reconciliation- >/dev/null
    info "✓ Cluster ID ${restore_id} restored, reconciliation resumed"
  fi

  info "Waiting for the Kafka cluster to be Ready (timeout: 10 minutes)..."
  local ready=false i cond
  for i in {1..60}; do
    cond=$(kubectl -n "$NAMESPACE_KAFKA" get kafka.kafka.strimzi.io "$KAFKA_CLUSTER_NAME" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$cond" == "True" ]]; then
      ready=true
      break
    fi
    if (( i % 3 == 0 )); then
      info "  Kafka Ready=${cond:-unknown} (${i}0s elapsed...)"
    fi
    sleep 10
  done

  if [[ "$ready" != "true" ]]; then
    warn "Kafka CR did not report Ready in time"
    warn "Diagnostics:"
    kubectl -n "$NAMESPACE_KAFKA" get kafka.kafka.strimzi.io "$KAFKA_CLUSTER_NAME" -o yaml 2>/dev/null | sed -n '/^status:/,$p' || true
    kubectl -n "$NAMESPACE_KAFKA" get pods,pvc 2>/dev/null || true
    kubectl -n "$NAMESPACE_KAFKA" get events --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || true
    # Record the ID the status already carries (first install), so a later recreate can restore it.
    remember_cluster_id
    warn "Continuing; the broker may still be initializing."
    return 0
  fi
  info "✓ Kafka CR Ready"
  remember_cluster_id

  if kubectl -n "$NAMESPACE_KAFKA" wait "kafkauser/${KAFKA_SUPERUSER}" --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
    info "✓ Superuser ${KAFKA_SUPERUSER} Ready"
    if kafka_admin kafka-metadata-quorum.sh describe --status >/dev/null 2>&1; then
      info "✓ KRaft quorum answers (admin client over the internal listener)"
    else
      warn "kafka-metadata-quorum.sh failed; check: tools/k3s/kafka.sh ${ENV_NAME} --watch health"
    fi
  else
    warn "KafkaUser ${KAFKA_SUPERUSER} not Ready yet: kubectl -n ${NAMESPACE_KAFKA} describe kafkauser ${KAFKA_SUPERUSER}"
  fi
}

create_kafka_cluster

# ============================================================================
# Phase 4: Metrics Services (Prometheus endpoint discovery)
# ============================================================================
create_metrics_services() {
  log "=== Phase 4: Metrics Services ==="

  # Strimzi exposes the JMX exporter and kafka-exporter on container port 9404
  # (tcp-prometheus) but creates no Service for either. These two plain Services are the
  # discovery targets of the 'kafka' and 'kafka-exporter' jobs in observability.sh.
  cat <<YAML | kubectl apply -f -
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-metrics
  namespace: ${NAMESPACE_KAFKA}
  labels:
    app: kafka-metrics
    component: monitoring
spec:
  selector:
    strimzi.io/cluster: ${KAFKA_CLUSTER_NAME}
    strimzi.io/name: ${KAFKA_CLUSTER_NAME}-kafka
  ports:
    - port: 9404
      targetPort: 9404
      name: metrics
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-exporter-metrics
  namespace: ${NAMESPACE_KAFKA}
  labels:
    app: kafka-exporter-metrics
    component: monitoring
spec:
  selector:
    strimzi.io/cluster: ${KAFKA_CLUSTER_NAME}
    strimzi.io/name: ${KAFKA_CLUSTER_NAME}-kafka-exporter
  ports:
    - port: 9404
      targetPort: 9404
      name: metrics
YAML

  info "✓ kafka-metrics + kafka-exporter-metrics Services applied"
  info "  (scraped by the 'kafka' and 'kafka-exporter' jobs in observability.sh — rerun observability.sh after first install)"
}

create_metrics_services

# ============================================================================
# Phase 5: App KafkaUsers (envs/<env>/kafka-users/*.yaml)
# ============================================================================
apply_app_users() {
  log "=== Phase 5: App KafkaUsers ==="

  if [[ ! -d "$USERS_DIR" ]] || ! compgen -G "${USERS_DIR}/*.y*ml" >/dev/null 2>&1; then
    info "No app users in ${USERS_DIR} (create them with --provision-credentials <app-id>)"
    return 0
  fi

  local f name
  for f in "$USERS_DIR"/*.y*ml; do
    name=$(yq -r 'select(.kind == "KafkaUser") | .metadata.name' "$f" 2>/dev/null | head -1)
    if [[ -z "$name" ]]; then
      warn "Skipping ${f}: no KafkaUser in it"
      continue
    fi
    if ! kubectl -n "$NAMESPACE_KAFKA" get secret "${name}-kafka-password" >/dev/null 2>&1; then
      warn "Secret ${name}-kafka-password missing in ${NAMESPACE_KAFKA}: run tools/sops/apply.sh ${ENV_NAME} ${name}-kafka.secret.yaml"
    fi
    kubectl apply -f "$f" >/dev/null && info "✓ KafkaUser ${name} applied"
  done
}

apply_app_users

# ============================================================================
# Phase 6: Kafbat UI (pgweb pattern)
# ============================================================================
# Prints what else serves KAFKA_CONSOLE_HOST (an Ingress other than ours, or a catch-all
# Pomerium route to another upstream); prints nothing when the host is free or ours.
console_host_owner() {
  local found="" routes_file to
  found=$(kubectl get ingress -A -o json 2>/dev/null | jq -r --arg h "$KAFKA_CONSOLE_HOST" '
    .items[] | select(any(.spec.rules[]?; .host == $h))
    | select(.metadata.name != "kafka-console-pomerium")
    | "Ingress \(.metadata.namespace)/\(.metadata.name)"' | paste -sd, - || true)
  if routes_file=$(provision::pomerium_routes_file 2>/dev/null) && [[ -f "$routes_file" ]]; then
    to=$(FROM="https://${KAFKA_CONSOLE_HOST}" yq -r '.config.routes[]?
      | select(.from == strenv(FROM)) | select((has("prefix") or has("path") or has("regex")) | not)
      | .to' "$routes_file" 2>/dev/null | grep -v '//kafbat-ui\.' | head -1 || true)
    if [[ -n "$to" ]]; then
      found="${found:+${found}, }Pomerium route to ${to}"
    fi
  fi
  printf '%s' "$found"
}

deploy_console() {
  log "=== Phase 6: Kafbat UI ==="

  if [[ "$SKIP_CONSOLE" == "true" ]]; then
    info "Skipping Kafbat UI installation (--skip-console)"
    return 0
  fi

  if [[ -z "${KAFKA_CONSOLE_HOST:-}" ]]; then
    warn "KAFKA_CONSOLE_HOST not set (no HOSTNAME in env.properties) - skipping console"
    return 0
  fi

  # Another Ingress or Pomerium route may own console.<env> (an older UI, another tool). The
  # route upsert would take the host from it, so leave it alone unless told otherwise.
  local owner
  owner=$(console_host_owner)
  if [[ -n "$owner" ]]; then
    if [[ "$FORCE_CONSOLE" == "true" ]]; then
      warn "${KAFKA_CONSOLE_HOST} is in use (${owner}); taking it over (--force-console)"
    else
      warn "${KAFKA_CONSOLE_HOST} is in use (${owner}) - skipping the Kafbat UI and its route."
      warn "Remove that first, set KAFKA_CONSOLE_HOST to another host, or pass --force-console."
      SKIP_CONSOLE=true
      return 0
    fi
  fi

  # The UI talks Kafka as the superuser: the Secret the User Operator wrote carries a
  # ready sasl.jaas.config, referenced directly (no copy of the password).
  if ! kubectl -n "$NAMESPACE_KAFKA" get secret "$SUPERUSER_SECRET" >/dev/null 2>&1; then
    warn "Superuser secret ${SUPERUSER_SECRET} not found - skipping console"
    return 0
  fi

  cat <<YAML | kubectl apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafbat-ui
  namespace: ${NAMESPACE_KAFKA}
  labels:
    app: kafbat-ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kafbat-ui
  template:
    metadata:
      labels:
        app: kafbat-ui
    spec:
      containers:
      - name: kafbat-ui
        image: ${KAFBAT_UI_IMAGE}
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: DYNAMIC_CONFIG_ENABLED
          value: "false"
        - name: KAFKA_CLUSTERS_0_NAME
          value: "${KAFKA_CLUSTER_NAME}"
        - name: KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS
          value: "${BOOTSTRAP_SERVERS}"
        - name: KAFKA_CLUSTERS_0_READONLY
          value: "${KAFBAT_UI_READONLY}"
        - name: KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL
          value: "SASL_PLAINTEXT"
        - name: KAFKA_CLUSTERS_0_PROPERTIES_SASL_MECHANISM
          value: "SCRAM-SHA-512"
        - name: KAFKA_CLUSTERS_0_PROPERTIES_SASL_JAAS_CONFIG
          valueFrom:
            secretKeyRef:
              name: ${SUPERUSER_SECRET}
              key: sasl.jaas.config
        - name: JAVA_OPTS
          value: "-XX:MaxRAMPercentage=60"
        resources:
          requests:
            memory: "256Mi"
            cpu: "50m"
          limits:
            memory: "768Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /actuator/health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /actuator/health
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: kafbat-ui
  namespace: ${NAMESPACE_KAFKA}
spec:
  selector:
    app: kafbat-ui
  ports:
  - port: 8080
    targetPort: 8080
    name: http
YAML

  info "Waiting for the Kafbat UI deployment to be ready..."
  kubectl -n "$NAMESPACE_KAFKA" rollout status deployment/kafbat-ui --timeout=300s || true
  info "✓ Kafbat UI deployed"
}

deploy_console

# ============================================================================
# Phase 7: Pomerium ingress + route for the UI
# ============================================================================
expose_console() {
  log "=== Phase 7: Console ingress (Pomerium) ==="

  if [[ "$SKIP_CONSOLE" == "true" || -z "${KAFKA_CONSOLE_HOST:-}" ]]; then
    info "Skipping console ingress"
    return 0
  fi

  # DNS: covered by the env wildcard if present, else try to create the record
  if provision::cloudflare_read_token 2>/dev/null; then
    if provision::cloudflare_check_wildcard "$HOSTNAME" 2>/dev/null; then
      info "Wildcard DNS covers ${KAFKA_CONSOLE_HOST}"
    else
      provision::cloudflare_ensure_dns_record "$KAFKA_CONSOLE_HOST" "$EXTERNAL_IP" || \
        warn "Failed to create DNS record for ${KAFKA_CONSOLE_HOST} (wildcard may cover it)"
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
  name: kafka-console-pomerium
  namespace: ${NAMESPACE_SSO}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    cert-manager.io/common-name: ${KAFKA_CONSOLE_HOST}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${KAFKA_CONSOLE_HOST}
    secretName: kafka-console-pomerium-tls
  rules:
  - host: ${KAFKA_CONSOLE_HOST}
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

  local from_url="https://${KAFKA_CONSOLE_HOST}"
  local to_url="http://kafbat-ui.${NAMESPACE_KAFKA}.svc.cluster.local:8080"
  if provision::pomerium_routes_add "$from_url" "$to_url" "${NAMESPACE_SSO}" true true true; then
    info "✓ Pomerium route ensured: ${from_url} -> ${to_url}"
  else
    warn "Failed to ensure Pomerium route for ${from_url}"
  fi
}

expose_console || true

deploy_dashboard || warn "kafka-journal dashboard not applied; retry with: tools/k3s/kafka.sh ${ENV_NAME} --dashboard-only"

# ============================================================================
# Summary
# ============================================================================
log "=== Kafka provisioning complete ==="
info "Namespace:          ${NAMESPACE_KAFKA}"
info "Broker:             ${BROKER_POD} (Kafka ${KAFKA_VERSION}, Strimzi ${STRIMZI_VERSION}, heap ${KAFKA_HEAP}, memory ${KAFKA_MEMORY})"
info "Bootstrap servers:  ${BOOTSTRAP_SERVERS}"
info "Data dir:           ${KAFKA_DATA_DIR} on ${KAFKA_NODE} (PV ${DATA_PV}, ${KAFKA_STORAGE_SIZE})"
info "Auth:               SASL/SCRAM-SHA-512, simple authorization (superuser: ${KAFKA_SUPERUSER})"
if [[ "$SKIP_CONSOLE" != "true" && -n "${KAFKA_CONSOLE_HOST:-}" ]]; then
  info "Console:            https://${KAFKA_CONSOLE_HOST} (Kafbat UI, GitHub OAuth via Pomerium)"
fi
info "Dashboard:          Grafana > Shared > kafka-journal (uid kafka-journal)"
info ""
info "Next steps:"
info "  tools/k3s/kafka.sh ${ENV_NAME} --watch health"
info "  tools/k3s/kafka.sh ${ENV_NAME} --provision-credentials <app-id>"
info "  tools/k3s/observability.sh ${ENV_NAME}   # load the kafka scrape jobs + kafka-journal alerts"
