#!/usr/bin/env bash
set -euo pipefail

# Self-hosted runners for the org's PUBLIC repositories, so their CI never runs on GitHub-hosted runners.
#
# The regular pool (github-action-runner.sh) sits in the org's "Default" runner group, which never admits public
# repos: those runners carry the GitHub App key, Nexus and Postgres credentials in their env. This script gives the
# public repos a pool of their own:
#
#   - a runner group (PUBLIC_RUNNER_GROUP, default "public") that admits exactly PUBLIC_RUNNER_REPOS and nothing
#     else, with public repositories allowed;
#   - a RunnerDeployment <env>-public-runners in that group, labelled self-hosted, linux, x64, <env>-public, with NO
#     cluster secrets in its env (a workflow brings its own through GitHub secrets/environments), its own caches,
#     and a NetworkPolicy: no ingress, and egress to the internet only, off every private range (pods, services,
#     the nodes' VLAN and Tailscale addresses); DNS and Traefik excepted, so the env's public endpoints, e.g.
#     nexus-api.<env>, still work;
#   - the org's fork pull request policy at "all_external_contributors": a fork PR's workflow waits for a
#     maintainer's approval before it gets one of these privileged (Docker-in-Docker) runners.
#
# Workflows in those repos use:  runs-on: [self-hosted, <env>-public]
#
# Usage:
#   tools/k3s/public-runners.sh <env-name> [--dry-run]
#
# env.properties:
#   PUBLIC_RUNNER_REPOS     public repos (space- or comma-separated) admitted to the group; required
#   PUBLIC_RUNNER_GROUP     runner group name (default: public)
#   PUBLIC_RUNNER_REPLICAS  runners in the pool (default: 1)
#
# Requires github-action-runner.sh to have run first (ARC, the GitHub App credentials, the runner image).
# The GitHub App needs the organization permissions "Self-hosted runners: Read and write" and
# "Administration: Read and write" (the fork PR policy).

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--dry-run]" >&2
  exit 1
fi
provision::load_env "$1" || { echo "ERROR: Environment '$1' not found" >&2; exit 1; }
shift

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

provision::validate_kubectl_context || exit 1
provision::require_tools || exit 1

log() { echo "[public-runners] $*"; }
info() { echo "[public-runners:info] $*"; }
warn() { echo "[public-runners:warn] $*" >&2; }
err() { echo "[public-runners:error] $*" >&2; }

NAMESPACE_RUNNER="${NAMESPACE_RUNNER:-actions-runner-system}"
GROUP_NAME="${PUBLIC_RUNNER_GROUP:-public}"
REPLICAS="${PUBLIC_RUNNER_REPLICAS:-1}"
RUNNER_NAME="${ENV_NAME}-public-runners"
LABEL="${ENV_NAME}-public"
RUNNER_IMAGE="${RUNNER_IMAGE_REF:-harbor.${HOSTNAME}/library/github-runner:latest}"
# The egress policy keeps the runners off every private and link-local range: pods and services (k3s's
# 10.42/16, 10.43/16), the nodes' VLAN and Tailscale addresses, and the metadata address.
PRIVATE_RANGES="10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16"
# ... and every node's own IPv4 addresses, the public ones included: the API server (6443), the kubelet and anything
# else bound on a node answer there. The env's public endpoints are unaffected: their traffic is DNATed to Traefik.
NODE_IPS=$(kubectl get nodes -o json |
  jq -r '[.items[].status.addresses[] | select(.type == "InternalIP" or .type == "ExternalIP") | .address
          | select(test("^[0-9.]+$"))] | unique | map(. + "/32") | join(", ")')
[[ -n "$NODE_IPS" ]] && PRIVATE_RANGES="${PRIVATE_RANGES}, ${NODE_IPS}"

repos_list=$(printf '%s' "${PUBLIC_RUNNER_REPOS:-}" | tr ', ' '\n\n' | sed '/^$/d' | sort -u)
[[ -n "$repos_list" ]] || { err "PUBLIC_RUNNER_REPOS is empty in envs/${ENV_NAME}/env.properties"; exit 1; }

ORG=$(provision::yaml_get "$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml" .stringData.githubOrg)
[[ -n "$ORG" ]] || { err "No githubOrg in secrets.plain/github-oauth-credentials.yaml"; exit 1; }

github_api() { # METHOD PATH [JSON] -> body, newline, HTTP code
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS --max-time 20 -X "$method" -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28" -w '\n%{http_code}')
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")
  curl "${args[@]}" -K <(printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN") \
    "${GITHUB_API_URL:-https://api.github.com}${path}" 2>/dev/null || printf '\n000'
}
body() { printf '%s' "${1%$'\n'*}"; }
code() { printf '%s' "${1##*$'\n'}"; }

log "Public-repo runners for ${ORG} on ${ENV_NAME}$([[ "$DRY_RUN" == true ]] && echo ' (dry run)')"
GH_TOKEN=$(provision::github_get_installation_token) || { err "No GitHub App token"; exit 1; }

# --- Repos: each must exist and be public (a private repo belongs in the Default group) ---
repo_ids="[]"
for r in $repos_list; do
  out=$(github_api GET "/repos/${ORG}/${r}")
  [[ "$(code "$out")" == 200 ]] || { err "Repo ${ORG}/${r} not found or not visible to the GitHub App"; exit 1; }
  vis=$(body "$out" | jq -r .visibility)
  [[ "$vis" == public ]] || { err "${ORG}/${r} is ${vis}; only public repos go in '${GROUP_NAME}'"; exit 1; }
  repo_ids=$(jq -c --argjson id "$(body "$out" | jq .id)" '. + [$id]' <<<"$repo_ids")
done
info "Repos: $(echo "$repos_list" | tr '\n' ' ')"

# --- Fork PR policy ---
# Read and set with the GitHub App when it has "Administration" on the org, else with the operator's gh login (an
# org owner). Without the policy confirmed, nothing else happens.
fork_policy_get() {
  local out
  out=$(github_api GET "/orgs/${ORG}/actions/permissions/fork-pr-contributor-approval")
  if [[ "$(code "$out")" == 200 ]]; then body "$out" | jq -r .approval_policy; return; fi
  gh api "orgs/${ORG}/actions/permissions/fork-pr-contributor-approval" --jq .approval_policy 2>/dev/null || echo unknown
}
fork_policy_set() {
  local out
  out=$(github_api PUT "/orgs/${ORG}/actions/permissions/fork-pr-contributor-approval" \
    '{"approval_policy":"all_external_contributors"}')
  [[ "$(code "$out")" == 204 ]] && return 0
  gh api -X PUT "orgs/${ORG}/actions/permissions/fork-pr-contributor-approval" \
    -f approval_policy=all_external_contributors >/dev/null 2>&1
}
policy=$(fork_policy_get)
if [[ "$policy" == all_external_contributors ]]; then
  info "✓ Fork PR workflows from outside collaborators wait for approval"
elif [[ "$DRY_RUN" == true ]]; then
  info "Would set the fork PR approval policy: ${policy} -> all_external_contributors"
else
  fork_policy_set || { err "Could not set the fork PR approval policy (was: ${policy}); set 'Require approval for all outside collaborators' in Settings > Actions > General, then re-run"; exit 1; }
  info "✓ Fork PR approval policy: ${policy} -> all_external_contributors"
fi

# --- Runner group ---
out=$(github_api GET "/orgs/${ORG}/actions/runner-groups?per_page=100")
[[ "$(code "$out")" == 200 ]] || { err "Cannot read the runner groups (HTTP $(code "$out"))"; exit 1; }
group=$(body "$out" | jq -c --arg n "$GROUP_NAME" '[.runner_groups[] | select(.name == $n)][0] // empty')
spec=$(jq -nc --arg n "$GROUP_NAME" --argjson ids "$repo_ids" \
  '{name: $n, visibility: "selected", selected_repository_ids: $ids, allows_public_repositories: true}')
if [[ -z "$group" ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    info "Would create runner group '${GROUP_NAME}' (selected repos, public allowed)"
  else
    out=$(github_api POST "/orgs/${ORG}/actions/runner-groups" "$spec")
    [[ "$(code "$out")" == 201 ]] || { err "Could not create runner group '${GROUP_NAME}' (HTTP $(code "$out")): $(body "$out")"; exit 1; }
    info "✓ Runner group '${GROUP_NAME}' created"
  fi
else
  gid=$(jq -r .id <<<"$group")
  if [[ "$DRY_RUN" == true ]]; then
    info "Would set runner group '${GROUP_NAME}' (id ${gid}) to exactly the repos above, public allowed"
  else
    out=$(github_api PATCH "/orgs/${ORG}/actions/runner-groups/${gid}" \
      "$(jq -c 'del(.selected_repository_ids)' <<<"$spec")")
    [[ "$(code "$out")" == 200 ]] || { err "Could not update runner group '${GROUP_NAME}' (HTTP $(code "$out"))"; exit 1; }
    out=$(github_api PUT "/orgs/${ORG}/actions/runner-groups/${gid}/repositories" \
      "$(jq -nc --argjson ids "$repo_ids" '{selected_repository_ids: $ids}')")
    [[ "$(code "$out")" == 204 ]] || { err "Could not set the repos of '${GROUP_NAME}' (HTTP $(code "$out"))"; exit 1; }
    info "✓ Runner group '${GROUP_NAME}' admits exactly the repos above"
  fi
fi

# --- dockerd MTU: as github-action-runner.sh, the pod's interface MTU ---
pod_mtu=1230
if [[ "$DRY_RUN" != true ]]; then
  probe="mtu-probe-$$"
  kubectl -n "$NAMESPACE_RUNNER" run "$probe" --restart=Never --image=busybox:1.36 \
    --command -- cat /sys/class/net/eth0/mtu >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE_RUNNER" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${probe}" \
    --timeout=90s >/dev/null 2>&1 || true
  m=$(kubectl -n "$NAMESPACE_RUNNER" logs "$probe" 2>/dev/null | tr -dc '0-9' || true)
  kubectl -n "$NAMESPACE_RUNNER" delete pod "$probe" --ignore-not-found >/dev/null 2>&1 || true
  [[ "$m" =~ ^[0-9]{3,4}$ ]] && pod_mtu=$m
fi

manifest=$(cat <<EOF
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: ${RUNNER_NAME}
  namespace: ${NAMESPACE_RUNNER}
spec:
  replicas: ${REPLICAS}
  template:
    metadata:
      labels:
        teob-runner-pool: public
    spec:
      organization: ${ORG}
      group: ${GROUP_NAME}
      labels:
        - self-hosted
        - linux
        - x64
        - ${LABEL}
      dockerEnabled: true
      dockerMTU: ${pod_mtu}
      image: ${RUNNER_IMAGE}
      imagePullPolicy: Always
      # No cluster secrets here, unlike the Default pool: no GitHub App key, Nexus or Postgres credentials, and no
      # service account token.
      automountServiceAccountToken: false
      # The probes are github-action-runner.sh's (a lost containerd socket must recycle the pod).
      containers:
        - name: runner
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-XX:MaxRAMPercentage=85.0 -Dcats.effect.tracing.mode=none -XX:+UseParallelGC"
          livenessProbe:
            exec:
              command: ["sh", "-c", "sudo -n test -S /run/docker/containerd/containerd.sock && timeout 15 docker info >/dev/null"]
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 20
            failureThreshold: 3
        - name: docker
          image: docker:29.3-dind
          livenessProbe:
            exec:
              command:
                - sh
                - -c
                - >-
                  test -S /run/docker/containerd/containerd.sock &&
                  timeout 8 ctr --address /run/docker/containerd/containerd.sock version >/dev/null &&
                  timeout 8 docker info >/dev/null
            initialDelaySeconds: 30
            periodSeconds: 30
            timeoutSeconds: 20
            failureThreshold: 3
      terminationGracePeriodSeconds: 300
      dockerdContainerResources:
        limits:
          memory: "${DOCKERD_MEMORY_LIMIT:-8Gi}"
        requests:
          cpu: "500m"
          memory: "2Gi"
      resources:
        limits:
          memory: "${PUBLIC_RUNNER_MEMORY_LIMIT:-12Gi}"
        requests:
          cpu: "500m"
          memory: "2Gi"
      initContainers:
        - name: coursier-cache-perms
          image: busybox:1.37
          command: ["sh", "-c", "chown 1001:1001 /cache || true"]
          securityContext:
            runAsUser: 0
          volumeMounts:
            - name: coursier-cache
              mountPath: /cache
      volumeMounts:
        - name: coursier-cache
          mountPath: /home/runner/.cache/coursier
      volumes:
        # its own cache, never shared with the Default pool's
        - name: coursier-cache
          hostPath:
            path: /var/lib/github-runner-cache/${ENV_NAME}-public/coursier
            type: DirectoryOrCreate
---
# Internet only: off every private range except DNS and Traefik (the env's public endpoints hairpin through it).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${RUNNER_NAME}
  namespace: ${NAMESPACE_RUNNER}
spec:
  podSelector:
    matchLabels:
      teob-runner-pool: public
  policyTypes: [Ingress, Egress]
  ingress: []
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              app.kubernetes.io/name: traefik
      ports:
        - { protocol: TCP, port: 8000 }
        - { protocol: TCP, port: 8443 }
        - { protocol: TCP, port: 80 }
        - { protocol: TCP, port: 443 }
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [${PRIVATE_RANGES}]
EOF
)

if [[ "$DRY_RUN" == true ]]; then
  info "Would apply:"
  printf '%s\n' "$manifest"
  kubectl apply --dry-run=server -f - <<<"$manifest" >/dev/null && info "✓ server-side dry run accepted"
  exit 0
fi

kubectl apply -f - <<<"$manifest"
info "✓ ${RUNNER_NAME}: ${REPLICAS} runner(s), label ${LABEL}, group ${GROUP_NAME}"
info "  Workflows: runs-on: [self-hosted, ${LABEL}]"
