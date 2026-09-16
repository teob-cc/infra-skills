#!/usr/bin/env bash
# ============================================================================
# runner-image — build the custom GitHub Actions runner image for <env> and switch to it
# ============================================================================
# Thin wrapper: tools/k3s/harbor-image.sh <env> github-runner does the credentials / caller
# workflow / dispatch / wait; then tools/k3s/github-action-runner.sh detects the image in
# Harbor and switches the RunnerDeployment from summerwind/actions-runner-dind to it.
#
# Usage: tools/k3s/runner-image.sh <env> [--rebuild] [--skip-build]
# shellcheck disable=SC1091
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_ARG="${1:-}"; shift || true
[[ -n "$ENV_ARG" ]] || { echo "Usage: $0 <env> [--rebuild] [--skip-build]" >&2; exit 1; }

"$REPO_ROOT/tools/k3s/harbor-image.sh" "$ENV_ARG" github-runner "$@"

echo "[runner-image] === switch runners to the custom image ==="
"$REPO_ROOT/tools/k3s/github-action-runner.sh" "$ENV_ARG"
kubectl -n actions-runner-system get runnerdeployment "${ENV_ARG}-runners" \
  -o jsonpath='{"[runner-image:info]   image now: "}{.spec.template.spec.image}{"\n"}'
echo "[runner-image] === runner image step completed for environment: ${ENV_ARG} ==="
