#!/usr/bin/env bash
# ============================================================================
# runner-image — build the custom GitHub Actions runner image for <env> and switch to it
# ============================================================================
# The last mile of the CI setup, previously four hand-run steps:
#   1. push Harbor robot credentials to the envs repo (tools/k3s/registry-credentials.sh)
#   2. make sure the envs repo carries the thin caller workflow
#      (.github/workflows/build-runner-image.yml -> reusable workflow in infra-skills)
#   3. dispatch it on the (vanilla) self-hosted runners and wait for the push to Harbor
#   4. re-run tools/k3s/github-action-runner.sh, which detects the image and switches the
#      RunnerDeployment from summerwind/actions-runner-dind to it
#
# Usage:
#   tools/k3s/runner-image.sh <env> [--rebuild] [--skip-build]
#     --rebuild     dispatch the build even if the image already exists in Harbor
#     --skip-build  never dispatch; only push credentials and switch if the image exists
#
# Needs: gh (logged in as an org owner/admin), the GitHub App + Harbor already provisioned.
# The envs repo is the GitOps repo (GITOPS_REPO_URL or <org>/infra-envs).
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tools/provision-common.sh"

ENV_ARG="${1:-}"; shift || true
[[ -n "$ENV_ARG" ]] || { echo "Usage: $0 <env> [--rebuild] [--skip-build]" >&2; exit 1; }
provision::load_env "$ENV_ARG" || { provision::error "Environment '${ENV_ARG}' not found"; exit 1; }

REBUILD=false; SKIP_BUILD=false
for a in "$@"; do
  case "$a" in
    --rebuild) REBUILD=true ;;
    --skip-build) SKIP_BUILD=true ;;
    *) provision::error "Unknown argument: $a"; exit 1 ;;
  esac
done

log()  { echo "[runner-image] $*"; }
info() { echo "[runner-image:info] $*"; }
warn() { echo "[runner-image:warn] $*" >&2; }
err()  { echo "[runner-image:error] $*" >&2; }

provision::validate_kubectl_context || exit 1
command -v gh >/dev/null 2>&1 || { err "gh CLI is required"; exit 1; }

# --- Who / where -------------------------------------------------------------
provision::github_read_credentials >/dev/null 2>&1 || true
GITHUB_ORG="${GITHUB_ORG:-}"
if [[ -z "$GITHUB_ORG" ]]; then
  err "GITHUB_ORG unknown: set it in env.properties or provide github-oauth-credentials.yaml"; exit 1
fi
if [[ -n "${GITOPS_REPO_URL:-}" ]]; then
  ENVS_REPO="$(basename "${GITOPS_REPO_URL%.git}")"
else
  ENVS_REPO="infra-envs"
fi
HARBOR_HOST="harbor.${HOSTNAME}"
IMAGE_PATH="library/github-runner"
WORKFLOW_FILE="build-runner-image.yml"

log "=== Phase 1: Harbor credentials -> ${GITHUB_ORG}/${ENVS_REPO} (environment '${ENV_NAME}') ==="
"$REPO_ROOT/tools/k3s/registry-credentials.sh" "$ENV_NAME" "$ENVS_REPO"

log "=== Phase 2: caller workflow in the envs repo ==="
if gh api "/repos/${GITHUB_ORG}/${ENVS_REPO}/contents/.github/workflows/${WORKFLOW_FILE}" >/dev/null 2>&1; then
  info "✓ .github/workflows/${WORKFLOW_FILE} present in ${GITHUB_ORG}/${ENVS_REPO}"
else
  err "The envs repo has no .github/workflows/${WORKFLOW_FILE}."
  err "Copy ${REPO_ROOT}/docs/examples/envs-repo/${WORKFLOW_FILE} into ${GITHUB_ORG}/${ENVS_REPO} at that"
  err "path, commit and push, then re-run this step."
  exit 1
fi

log "=== Phase 3: custom image in Harbor? ==="
image_exists() {
  local user pass body code count
  kubectl -n harbor get secret harbor-robot-runner >/dev/null 2>&1 || return 1
  user=$(kubectl -n harbor get secret harbor-robot-runner -o jsonpath='{.data.username}' | base64 -d)
  pass=$(kubectl -n harbor get secret harbor-robot-runner -o jsonpath='{.data.password}' | base64 -d)
  body=$(curl -sS -m 20 -w '\n%{http_code}' -u "${user}:${pass}" \
    "https://${HARBOR_HOST}/api/v2.0/projects/${IMAGE_PATH%%/*}/repositories/${IMAGE_PATH##*/}/artifacts?page_size=1" 2>/dev/null || echo "000")
  code=${body##*$'\n'}
  count=$(printf '%s' "${body%$'\n'*}" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
  [[ "$code" == "200" && "${count:-0}" -gt 0 ]]
}

NEED_BUILD=true
if image_exists; then
  info "✓ ${HARBOR_HOST}/${IMAGE_PATH}:latest exists"
  $REBUILD && info "--rebuild requested" || NEED_BUILD=false
else
  info "image not in Harbor yet"
fi
if $SKIP_BUILD; then NEED_BUILD=false; info "--skip-build: not dispatching"; fi

if $NEED_BUILD; then
  log "=== Phase 4: build on the self-hosted runners ==="
  # Vanilla runners must be up to run the build. The runner step guarantees that.
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
  info "run https://github.com/${GITHUB_ORG}/${ENVS_REPO}/actions/runs/${run_id} — waiting (typically 10-15 min)"
  # gh run watch polls; --exit-status makes a failed run fail this step. Large downloads in
  # the build that stall or reset mean MTU: see the provision skill troubleshooting.
  if ! gh run watch "$run_id" -R "${GITHUB_ORG}/${ENVS_REPO}" --exit-status --interval 30 >/dev/null; then
    err "build failed: gh run view ${run_id} -R ${GITHUB_ORG}/${ENVS_REPO} --log-failed"
    err "If a large download stalled/reset inside the build, check dockerMTU on the RunnerDeployment"
    err "(tools/k3s/github-action-runner.sh sets it from the pod MTU) and re-run with --rebuild."
    exit 1
  fi
  image_exists || { err "run succeeded but ${HARBOR_HOST}/${IMAGE_PATH} still has no artifact"; exit 1; }
  info "✓ image pushed to ${HARBOR_HOST}/${IMAGE_PATH}:latest"
fi

log "=== Phase 5: switch runners to the custom image ==="
if image_exists; then
  "$REPO_ROOT/tools/k3s/github-action-runner.sh" "$ENV_NAME"
  kubectl -n actions-runner-system get runnerdeployment "${ENV_NAME}-runners" \
    -o jsonpath='{"[runner-image:info]   image now: "}{.spec.template.spec.image}{"\n"}'
else
  warn "no custom image available; runners stay on the vanilla image"
fi
log "=== runner image step completed for environment: ${ENV_NAME} ==="
