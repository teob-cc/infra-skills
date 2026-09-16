#!/usr/bin/env bash
# ============================================================================
# harbor-image — build one of the platform images on the env's runners, push to its Harbor
# ============================================================================
# Images live in infra-skills under images/<name> and are built by the reusable workflow
# .github/workflows/build-<name>-image.yml, invoked through a thin caller of the same name in
# the environment's envs repo (templates in docs/examples/envs-repo/). This tool:
#   1. pushes the Harbor robot credentials to the envs repo (tools/k3s/registry-credentials.sh)
#   2. checks that the caller workflow exists there
#   3. dispatches it with environment + base_domain and waits for the push (unless the image
#      already exists in Harbor and --rebuild was not given)
#
# Usage:
#   tools/k3s/harbor-image.sh <env> <image> [--rebuild] [--skip-build]
#     <image>       github-runner | teob-base
#     --rebuild     dispatch even if library/<image> already has an artifact
#     --skip-build  never dispatch (only verify credentials and presence)
# Exit 0 when the image is present in Harbor afterwards. Needs gh logged in as an org owner.
# shellcheck disable=SC1091
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tools/provision-common.sh"

ENV_ARG="${1:-}"; IMAGE="${2:-}"; shift 2 2>/dev/null || true
[[ -n "$ENV_ARG" && -n "$IMAGE" ]] || { echo "Usage: $0 <env> <github-runner|teob-base> [--rebuild] [--skip-build]" >&2; exit 1; }
case "$IMAGE" in github-runner|teob-base) ;; *) echo "Unknown image '${IMAGE}' (expected github-runner or teob-base)" >&2; exit 1 ;; esac
provision::load_env "$ENV_ARG" || { provision::error "Environment '${ENV_ARG}' not found"; exit 1; }

REBUILD=false; SKIP_BUILD=false
for a in "$@"; do case "$a" in --rebuild) REBUILD=true ;; --skip-build) SKIP_BUILD=true ;; *) provision::error "Unknown argument: $a"; exit 1 ;; esac; done

log()  { echo "[harbor-image:${IMAGE}] $*"; }
info() { echo "[harbor-image:${IMAGE}:info] $*"; }
err()  { echo "[harbor-image:${IMAGE}:error] $*" >&2; }

provision::validate_kubectl_context || exit 1
command -v gh >/dev/null 2>&1 || { err "gh CLI is required"; exit 1; }
provision::github_read_credentials >/dev/null 2>&1 || true
[[ -n "${GITHUB_ORG:-}" ]] || { err "GITHUB_ORG unknown: set it in env.properties or provide github-oauth-credentials.yaml"; exit 1; }
if [[ -n "${GITOPS_REPO_URL:-}" ]]; then ENVS_REPO="$(basename "${GITOPS_REPO_URL%.git}")"; else ENVS_REPO="infra-envs"; fi
HARBOR_HOST="harbor.${HOSTNAME}"
WORKFLOW_FILE="build-${IMAGE}-image.yml"

image_exists() {
  local user pass body code count
  kubectl -n harbor get secret harbor-robot-runner >/dev/null 2>&1 || return 1
  user=$(kubectl -n harbor get secret harbor-robot-runner -o jsonpath='{.data.username}' | base64 -d)
  pass=$(kubectl -n harbor get secret harbor-robot-runner -o jsonpath='{.data.password}' | base64 -d)
  body=$(curl -sS -m 20 -w '\n%{http_code}' -u "${user}:${pass}" \
    "https://${HARBOR_HOST}/api/v2.0/projects/library/repositories/${IMAGE}/artifacts?page_size=1" 2>/dev/null || echo "000")
  code=${body##*$'\n'}
  count=$(printf '%s' "${body%$'\n'*}" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
  [[ "$code" == "200" && "${count:-0}" -gt 0 ]]
}

log "=== Phase 1: Harbor credentials -> ${GITHUB_ORG}/${ENVS_REPO} (environment '${ENV_NAME}') ==="
"$REPO_ROOT/tools/k3s/registry-credentials.sh" "$ENV_NAME" "$ENVS_REPO"

log "=== Phase 2: caller workflow in the envs repo ==="
if gh api "/repos/${GITHUB_ORG}/${ENVS_REPO}/contents/.github/workflows/${WORKFLOW_FILE}" >/dev/null 2>&1; then
  info "✓ .github/workflows/${WORKFLOW_FILE} present in ${GITHUB_ORG}/${ENVS_REPO}"
else
  err "The envs repo has no .github/workflows/${WORKFLOW_FILE}."
  err "Copy ${REPO_ROOT}/docs/examples/envs-repo/${WORKFLOW_FILE} into ${GITHUB_ORG}/${ENVS_REPO} at that path, commit, push, re-run."
  exit 1
fi

log "=== Phase 3: ${HARBOR_HOST}/library/${IMAGE} present? ==="
NEED_BUILD=true
if image_exists; then
  info "✓ ${HARBOR_HOST}/library/${IMAGE}:latest exists"
  if $REBUILD; then info "--rebuild requested"; else NEED_BUILD=false; fi
else
  info "not in Harbor yet"
fi
$SKIP_BUILD && { NEED_BUILD=false; info "--skip-build: not dispatching"; }

if $NEED_BUILD; then
  log "=== Phase 4: build on the self-hosted runners ==="
  if ! kubectl -n actions-runner-system get runnerdeployment "${ENV_NAME}-runners" >/dev/null 2>&1; then
    err "RunnerDeployment ${ENV_NAME}-runners not found; run tools/k3s/github-action-runner.sh ${ENV_NAME} first."; exit 1
  fi
  before=$(gh run list -R "${GITHUB_ORG}/${ENVS_REPO}" --workflow "$WORKFLOW_FILE" --limit 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null || echo 0)
  gh workflow run "$WORKFLOW_FILE" -R "${GITHUB_ORG}/${ENVS_REPO}" -f "environment=${ENV_NAME}" -f "base_domain=${HOSTNAME}"
  run_id=""
  for _ in $(seq 1 20); do
    sleep 5
    run_id=$(gh run list -R "${GITHUB_ORG}/${ENVS_REPO}" --workflow "$WORKFLOW_FILE" --limit 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null || echo 0)
    [[ "$run_id" != "0" && "$run_id" != "$before" ]] && break
    run_id=""
  done
  [[ -n "$run_id" ]] || { err "could not find the dispatched run in ${GITHUB_ORG}/${ENVS_REPO}"; exit 1; }
  info "run https://github.com/${GITHUB_ORG}/${ENVS_REPO}/actions/runs/${run_id} — waiting"
  if ! gh run watch "$run_id" -R "${GITHUB_ORG}/${ENVS_REPO}" --exit-status --interval 30 >/dev/null; then
    err "build failed: gh run view ${run_id} -R ${GITHUB_ORG}/${ENVS_REPO} --log-failed"
    err "Large downloads that stall or reset inside the build mean MTU: check dockerMTU on the RunnerDeployment."
    exit 1
  fi
  image_exists || { err "run succeeded but ${HARBOR_HOST}/library/${IMAGE} still has no artifact"; exit 1; }
  info "✓ pushed ${HARBOR_HOST}/library/${IMAGE}:latest"
fi
image_exists && log "=== ${HARBOR_HOST}/library/${IMAGE} ready ===" || { err "image not available"; exit 1; }
