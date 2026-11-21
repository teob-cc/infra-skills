#!/usr/bin/env bash
set -euo pipefail

# Self-hosted CI runners for a tenant (INFRA-214, docs/TENANTS.md), registered with the TENANT's GitHub
# organization and running only on the tenant's own workers. The ops org runs those workers; the tenant gets
# pods only, and its CI is such a pod pool.
#
# The platform pool (github-action-runner.sh) injects the platform's Nexus and Postgres credentials into every
# runner and sits next to platform workloads. A tenant pool must see none of that:
#
#   - namespace <tenant>-ci, labelled infra-skills/tenant=<tenant>; runner pods can reference Secrets only from
#     their own namespace, so no platform Secret can ever reach them;
#   - no Docker by default: the runner pod is not privileged and the namespace enforces Pod Security "baseline".
#     TENANT_RUNNER_DOCKER=true adds Docker-in-Docker, which runs PRIVILEGED (namespace "privileged"): anyone
#     who can push a workflow in the tenant's organization then has root on the tenant worker. The node-level
#     controls of docs/TENANTS.md (bootstrap token, admission policies, network policies) are what contain it;
#   - every runner pod selects node-restriction.kubernetes.io/tenant=<tenant> and tolerates
#     infra-skills/tenant=<tenant>:NoExecute (tenant-admission.sh denies anything else in a tenant namespace);
#   - the GitHub App of the tenant's organization (Secret TENANT_RUNNER_APP_SECRET in <tenant>-ci, keys
#     github_app_id, github_app_installation_id, github_app_private_key; put there from the envs repo with
#     tools/sops/apply.sh, never created here);
#   - env from exactly the Secrets listed in TENANT_RUNNER_SECRETS (envFrom, all in <tenant>-ci); nothing else.
#     No service account token;
#   - a NetworkPolicy: no ingress; egress to DNS, Traefik (the env's public hostnames, e.g. Harbor) and the
#     internet, off every private range and every node address;
#   - images the tenant node can pull without platform credentials: TENANT_RUNNER_IMAGE (default the public
#     summerwind/actions-runner), plus docker:dind with TENANT_RUNNER_DOCKER=true. A tenant worker's
#     registries.yaml carries only the tenant's robot.
#
# Workflows in the tenant's repos use:  runs-on: [self-hosted, <tenant>-<env>]
#
# Usage:
#   tools/k3s/tenant-runners.sh <env-name> <tenant> [--dry-run]
#
# Settings: envs/<env>/tenants/<tenant>/tenant.properties (sourced when present), else the environment:
#   TENANT_GITHUB_ORG          the tenant's GitHub organization (required)
#   TENANT_RUNNER_REPLICAS     runners (default 1)
#   TENANT_RUNNER_APP_SECRET   Secret with the tenant's GitHub App (default <tenant>-github-app)
#   TENANT_RUNNER_SECRETS      Secrets in <tenant>-ci whose keys become the runners' env (space list)
#   TENANT_RUNNER_IMAGE        runner image (default summerwind/actions-runner:latest)
#   TENANT_RUNNER_MEMORY_LIMIT runner container memory limit (default 8Gi); TENANT_DOCKERD_MEMORY_LIMIT (4Gi)
#   TENANT_RUNNER_DOCKER       true: Docker-in-Docker, PRIVILEGED (root on the tenant worker for the tenant's CI); default false
#
# Requires: github-action-runner.sh (the ARC controller), tenant-admission.sh, a joined tenant node.

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

if [[ -z "${1:-}" || -z "${2:-}" ]]; then
  echo "Usage: $0 <env-name> <tenant> [--dry-run]" >&2
  exit 1
fi
provision::load_env "$1" || { echo "ERROR: Environment '$1' not found" >&2; exit 1; }
TENANT="$2"
shift 2
[[ "$TENANT" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "ERROR: tenant must be a DNS label: $TENANT" >&2; exit 1; }

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

TENANT_PROPS="$(provision::envs_root)/${ENV_NAME}/tenants/${TENANT}/tenant.properties"
# shellcheck disable=SC1090
[[ -f "$TENANT_PROPS" ]] && source "$TENANT_PROPS"

provision::validate_kubectl_context || exit 1
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

info() { echo "[tenant-runners:info] $*"; }
warn() { echo "[tenant-runners:warn] $*" >&2; }
err() { echo "[tenant-runners:error] $*" >&2; }

NS="${TENANT}-ci"
ORG="${TENANT_GITHUB_ORG:-}"
[[ -n "$ORG" ]] || { err "TENANT_GITHUB_ORG is not set (${TENANT_PROPS})"; exit 1; }
REPLICAS="${TENANT_RUNNER_REPLICAS:-1}"
APP_SECRET="${TENANT_RUNNER_APP_SECRET:-${TENANT}-github-app}"
IMAGE="${TENANT_RUNNER_IMAGE:-summerwind/actions-runner:latest}"
DOCKER="${TENANT_RUNNER_DOCKER:-false}"
[[ "$DOCKER" == true || "$DOCKER" == false ]] || { err "TENANT_RUNNER_DOCKER must be true or false"; exit 1; }
PSA=$([[ "$DOCKER" == true ]] && echo privileged || echo baseline)
LABEL="${TENANT}-${ENV_NAME}"
NAME="${TENANT}-runners"
TENANT_NODE_LABEL="node-restriction.kubernetes.io/tenant"
TENANT_TAINT="infra-skills/tenant"
SECRETS=$(tr ', ' '\n\n' <<<"${TENANT_RUNNER_SECRETS:-}" | sed '/^$/d')

# --- Preconditions ---
kubectl get crd runnerdeployments.actions.summerwind.dev >/dev/null 2>&1 \
  || { err "ARC is not installed (run github-action-runner.sh first)"; exit 1; }
kubectl get validatingadmissionpolicybinding infra-skills-tenant-pod-placement >/dev/null 2>&1 \
  || { err "tenant-admission.sh has not run: no tenant pod placement policy"; exit 1; }
TENANT_NODES=$(kubectl get nodes -l "${TENANT_NODE_LABEL}=${TENANT}" -o jsonpath='{.items[*].metadata.name}')
[[ -n "$TENANT_NODES" ]] || warn "No node is labelled ${TENANT_NODE_LABEL}=${TENANT} yet: the runners stay Pending until one joins (join-worker.sh --tenant ${TENANT})"
for s in "$APP_SECRET" $SECRETS; do
  [[ "$s" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || { err "not a Secret name: $s"; exit 1; }
  if ! kubectl -n "$NS" get secret "$s" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == true ]]; then warn "Secret ${NS}/${s} does not exist yet"; else err "Secret ${NS}/${s} does not exist (apply it from the envs repo first)"; exit 1; fi
  fi
done

# Node addresses (every node, the tenant's included) and private ranges are off limits; public endpoints of the
# env still work: their traffic is DNATed to Traefik, which the policy allows.
PRIVATE_J='["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","100.64.0.0/10","169.254.0.0/16","127.0.0.0/8"]'
EXCEPT_J=$(kubectl get nodes -o json | jq -c --argjson p "$PRIVATE_J" '$p + ([.items[].status.addresses[]
  | select(.type == "InternalIP" or .type == "ExternalIP") | .address | select(test("^[0-9.]+$")) | . + "/32"] | unique)')
ENVFROM_J=$(printf '%s\n' "$SECRETS" | sed '/^$/d' | jq -R '{secretRef: {name: .}}' | jq -sc .)

info "Tenant runners for ${ORG} on ${ENV_NAME}: ${REPLICAS} x ${IMAGE} in ${NS}, label ${LABEL}, Docker ${DOCKER}, env from: ${SECRETS:-nothing}"
[[ "$DOCKER" == true ]] && warn "TENANT_RUNNER_DOCKER=true: privileged Docker-in-Docker; the tenant's CI gets root on its tenant workers (docs/TENANTS.md)"

manifest=$(jq -n --arg ns "$NS" --arg t "$TENANT" --arg name "$NAME" --arg org "$ORG" --arg label "$LABEL" \
  --arg image "$IMAGE" --arg app "$APP_SECRET" --argjson replicas "$REPLICAS" --argjson envFrom "$ENVFROM_J" \
  --arg tl "$TENANT_NODE_LABEL" --arg tt "$TENANT_TAINT" --argjson except "$EXCEPT_J" \
  --arg mem "${TENANT_RUNNER_MEMORY_LIMIT:-8Gi}" --arg dmem "${TENANT_DOCKERD_MEMORY_LIMIT:-4Gi}" --arg psa "$PSA" --argjson docker "$DOCKER" '
  {"app.kubernetes.io/managed-by": "infra-skills-tenant-runners", "infra-skills/tenant": $t} as $l
  | {apiVersion: "v1", kind: "List", items: [
    {apiVersion: "v1", kind: "Namespace", metadata: {name: $ns, labels: ($l + {
      "pod-security.kubernetes.io/enforce": $psa,
      "pod-security.kubernetes.io/audit": "baseline", "pod-security.kubernetes.io/warn": "baseline"})}},
    {apiVersion: "actions.summerwind.dev/v1alpha1", kind: "RunnerDeployment",
     metadata: {name: $name, namespace: $ns, labels: $l},
     spec: {replicas: $replicas, template: {metadata: {labels: ($l + {"infra-skills/runner-pool": $t})}, spec: ({
       organization: $org, labels: ["self-hosted", "linux", "x64", $label],
       githubAPICredentialsFrom: {secretRef: {name: $app}},
       image: $image, imagePullPolicy: "IfNotPresent",
       dockerEnabled: $docker,
       automountServiceAccountToken: false,
       nodeSelector: {($tl): $t},
       tolerations: [{key: $tt, operator: "Equal", value: $t, effect: "NoExecute"}],
       envFrom: $envFrom,
       resources: {limits: {memory: $mem}, requests: {cpu: "500m", memory: "1Gi"}},
       terminationGracePeriodSeconds: 300}
       + (if $docker then {dockerMTU: 1230, dockerdContainerResources: {limits: {memory: $dmem}, requests: {cpu: "250m", memory: "512Mi"}}} else {} end))}}},
    {apiVersion: "networking.k8s.io/v1", kind: "NetworkPolicy",
     metadata: {name: ($name + "-egress"), namespace: $ns, labels: $l},
     spec: {podSelector: {}, policyTypes: ["Ingress", "Egress"], ingress: [],
       egress: [
         {to: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": "kube-system"}}, podSelector: {matchLabels: {"k8s-app": "kube-dns"}}}],
          ports: [{protocol: "UDP", port: 53}, {protocol: "TCP", port: 53}]},
         {to: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": "kube-system"}}, podSelector: {matchLabels: {"app.kubernetes.io/name": "traefik"}}},
               {namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": "kube-system"}}, podSelector: {matchLabels: {"svccontroller.k3s.cattle.io/svcname": "traefik"}}}]},
         {to: [{ipBlock: {cidr: "0.0.0.0/0", except: $except}}]}]}}]}')

# The dockerd MTU: the tenant node reaches the cluster over Tailscale (1280) with flannel VXLAN inside, as the
# GPU worker does; 1230 is what the platform pools measured on such paths.
if [[ "$DRY_RUN" == true ]]; then
  info "Would apply:"
  printf '%s\n' "$manifest" | jq -c '.items[] | {kind, ns: .metadata.namespace, name: .metadata.name}'
  if kubectl get ns "$NS" >/dev/null 2>&1; then
    kubectl apply --dry-run=server -f - <<<"$manifest" >/dev/null && info "✓ server-side dry run accepted"
  else
    jq '.items |= map(select(.kind == "Namespace"))' <<<"$manifest" | kubectl apply --dry-run=server -f - >/dev/null \
      && info "✓ server-side dry run accepted (namespace only; ${NS} does not exist yet)"
  fi
  exit 0
fi

jq '.items |= map(select(.kind == "Namespace"))' <<<"$manifest" | kubectl apply -f -
kubectl apply -f - <<<"$manifest"
info "✓ ${NAME}: ${REPLICAS} runner(s) for ${ORG}, label ${LABEL}, only on tenant nodes ${TENANT_NODES}"
info "  Workflows: runs-on: [self-hosted, ${LABEL}]"
