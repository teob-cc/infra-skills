#!/usr/bin/env bash
set -euo pipefail
# MinIO (single-node S3-compatible object store) provisioning for Kubernetes (k3s)
#
# Usage:
#   tools/k3s/minio.sh <env-name> [--show-credentials]
#
# Serves the S3 API inside the cluster at http://minio.${NAMESPACE_MINIO}.svc.cluster.local:9000 and, by
# default, publicly at https://${MINIO_HOST} (default s3.${HOSTNAME}) through Traefik with a cert-manager
# certificate. The web console is NOT exposed — reach it with
#   kubectl -n minio port-forward svc/minio 9001:9001
#
# Root credentials are generated once and kept in the `minio-root` secret (namespace minio); re-running the
# script reuses them. Data lives on a local-path PVC (single node, no replication). It is the target of
# postgres.sh's continuous backup (PG_WAL_ARCHIVE=minio), so it holds the only on-node copy of the WAL archive:
# tools/backup.sh's nightly k3s-storage sweep copies the volume to the backup host, which is what survives a lost
# node. local-path does not enforce MINIO_STORAGE; size /data for the base backups the retention window keeps.
#
# Options:
#   --show-credentials    Print the root credentials and exit
#
# env.properties (optional):
#   MINIO_STORAGE=20Gi             PVC request
#   MINIO_PUBLIC_INGRESS=true      false: no public S3 endpoint (in-cluster only); a re-run removes the
#                                  Ingress and its allowlist. Only for envs with no client outside the cluster.
#   MINIO_ALLOWED_CIDRS="203.0.113.7/32 198.51.100.0/24"
#                                  Restrict the public endpoint to these source ranges (plus the private and
#                                  Tailscale ranges) with a Traefik ipAllowList; unset = open to the Internet
#                                  (S3 auth still applies). Needs the real client IP at Traefik, which the
#                                  provisioners give it (traefik Service externalTrafficPolicy=Local).
#
# Requires: cert-manager with a ClusterIssuer (${CLUSTER_ISSUER:-letsencrypt-prod}), Traefik, DNS for
# ${MINIO_HOST} pointing at the node (a *.${HOSTNAME} wildcard covers it).
#
REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--show-credentials]" >&2
  exit 1
fi
if provision::load_env "${1:-}"; then
  shift
else
  echo "ERROR: Environment '$1' not found (envs/$1/env.properties missing)." >&2
  exit 1
fi

SHOW_CREDENTIALS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --show-credentials) SHOW_CREDENTIALS=true; shift ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
need kubectl
need openssl
need jq
provision::validate_kubectl_context

log() { echo "[minio] $*"; }
err() { echo "[minio:error] $*" >&2; }

: "${NAMESPACE_MINIO:=minio}"
# Upstream stopped publishing free MinIO images (2025); Chainguard rebuilds it from source. Its free tier only
# offers `latest`, so pin the digest (this one is MinIO RELEASE.2026-09-22T19-25-18Z, runs as uid 65532).
: "${MINIO_IMAGE:=cgr.dev/chainguard/minio@sha256:25bc63a89475bc494bfbce9bbeddb0421aece3f3968d77c809db5104d07b4545}"
: "${MINIO_STORAGE:=20Gi}"
: "${CLUSTER_ISSUER:=letsencrypt-prod}"
: "${INGRESS_CLASS:=traefik}"
: "${MINIO_PUBLIC_INGRESS:=true}"
: "${MINIO_ALLOWED_CIDRS:=}"
if [[ "$MINIO_PUBLIC_INGRESS" != true && "$MINIO_PUBLIC_INGRESS" != false ]]; then
  err "MINIO_PUBLIC_INGRESS='${MINIO_PUBLIC_INGRESS}' must be true or false"; exit 1
fi
if [[ -z "${MINIO_HOST:-}" ]]; then
  [[ -n "${HOSTNAME:-}" ]] || { err "Set HOSTNAME in env.properties or MINIO_HOST explicitly."; exit 1; }
  MINIO_HOST="s3.${HOSTNAME}"
fi
NS="$NAMESPACE_MINIO"

if [[ "$SHOW_CREDENTIALS" == true ]]; then
  kubectl -n "$NS" get secret minio-root -o json \
    | jq -r '.data | "MINIO_ROOT_USER=\(.MINIO_ROOT_USER|@base64d)\nMINIO_ROOT_PASSWORD=\(.MINIO_ROOT_PASSWORD|@base64d)"'
  echo "Endpoint: https://${MINIO_HOST}"
  exit 0
fi

log "namespace ${NS}, host ${MINIO_HOST}, image ${MINIO_IMAGE}"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Root credentials: generate once, keep forever (re-runs must not rotate them under a running server).
if ! kubectl -n "$NS" get secret minio-root >/dev/null 2>&1; then
  log "generating root credentials (secret minio-root)"
  kubectl -n "$NS" create secret generic minio-root \
    --from-literal=MINIO_ROOT_USER="admin-$(openssl rand -hex 4)" \
    --from-literal=MINIO_ROOT_PASSWORD="$(openssl rand -base64 36 | tr -d '/+=' | cut -c1-40)"
fi

kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: ${MINIO_STORAGE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  labels: { app: minio }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector:
    matchLabels: { app: minio }
  template:
    metadata:
      labels: { app: minio }
    spec:
      securityContext: { runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532 }
      containers:
        - name: minio
          image: ${MINIO_IMAGE}
          args: ["server", "/data", "--console-address", ":9001"]
          envFrom:
            - secretRef: { name: minio-root }
          env:
            - name: MINIO_SERVER_URL
              value: "https://${MINIO_HOST}"
            - name: MINIO_BROWSER_REDIRECT
              value: "off"
          ports:
            - { name: api, containerPort: 9000 }
            - { name: console, containerPort: 9001 }
          readinessProbe:
            httpGet: { path: /minio/health/ready, port: api }
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /minio/health/live, port: api }
            periodSeconds: 20
          resources:
            requests: { cpu: 50m, memory: 256Mi }
            limits: { memory: 1Gi }
          volumeMounts:
            - { name: data, mountPath: /data }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: minio-data }
---
apiVersion: v1
kind: Service
metadata:
  name: minio
spec:
  selector: { app: minio }
  ports:
    - { name: api, port: 9000, targetPort: api }
    - { name: console, port: 9001, targetPort: console }
EOF

log "waiting for the deployment"
kubectl -n "$NS" rollout status deploy/minio --timeout=180s

if [[ "$MINIO_PUBLIC_INGRESS" != true ]]; then
  # In-cluster only: take the public endpoint down if an earlier run put it up.
  kubectl -n "$NS" delete ingress minio-api --ignore-not-found >/dev/null
  kubectl -n "$NS" delete middleware.traefik.io minio-api-allowlist --ignore-not-found >/dev/null 2>&1 || true
  log "done. S3 endpoint (in-cluster only, MINIO_PUBLIC_INGRESS=false): http://minio.${NS}.svc.cluster.local:9000"
  log "root credentials: $0 ${ENV_NAME} --show-credentials"
  exit 0
fi

# Optional source allowlist on the public endpoint (MINIO_ALLOWED_CIDRS). Without it the endpoint is open
# to the Internet and only S3 request signing keeps strangers out.
middleware_annotation=""
if [[ -n "$MINIO_ALLOWED_CIDRS" ]]; then
  ranges=""
  for cidr in ${MINIO_ALLOWED_CIDRS//,/ }; do
    [[ "$cidr" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || { err "MINIO_ALLOWED_CIDRS: '${cidr}' is not an IP or CIDR"; exit 1; }
    ranges+="      - \"${cidr}\""$'\n'
  done
  kubectl -n "$NS" apply -f - <<MIDDLEWARE
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: minio-api-allowlist
spec:
  ipAllowList:
    sourceRange:
      # in-cluster and node networks, Tailscale
      - "10.0.0.0/8"
      - "172.16.0.0/12"
      - "192.168.0.0/16"
      - "100.64.0.0/10"
${ranges}
MIDDLEWARE
  middleware_annotation="traefik.ingress.kubernetes.io/router.middlewares: ${NS}-minio-api-allowlist@kubernetescrd"
  log "public S3 endpoint restricted to ${MINIO_ALLOWED_CIDRS} (plus private and Tailscale ranges)"
else
  kubectl -n "$NS" delete middleware.traefik.io minio-api-allowlist --ignore-not-found >/dev/null 2>&1 || true
fi

kubectl -n "$NS" apply -f - <<INGRESS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-api
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    ${middleware_annotation}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts: [${MINIO_HOST}]
      secretName: minio-api-tls
  rules:
    - host: ${MINIO_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: minio, port: { name: api } }
INGRESS

log "waiting for the TLS certificate (minio-api-tls)"
kubectl -n "$NS" wait --for=condition=Ready certificate/minio-api-tls --timeout=300s \
  || err "certificate not ready yet — check: kubectl -n $NS describe certificate minio-api-tls"
log "done. S3 endpoint: https://${MINIO_HOST} (in-cluster: http://minio.${NS}.svc.cluster.local:9000)"
log "root credentials: $0 ${ENV_NAME} --show-credentials"
