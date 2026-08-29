#!/usr/bin/env bash
set -euo pipefail

# Diagnostic script for GitHub Actions runner pod stops
# Helps identify root cause of unexpected runner terminations

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

# Parse arguments
if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [pod-name]" >&2
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

NAMESPACE_RUNNER="${NAMESPACE_RUNNER:-actions-runner-system}"
RUNNER_NAME="${ENV_NAME}-runners"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  GitHub Actions Runner Diagnostic Tool"
echo "  Environment: ${ENV_NAME}"
echo "  Namespace: ${NAMESPACE_RUNNER}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if specific pod was provided
SPECIFIC_POD="${1:-}"

# ============================================================================
# 1. Check for OOMKilled pods
# ============================================================================
echo "1. Checking for OOMKilled pods"
echo "   ────────────────────────────────────────────────────────────────────"
OOM_PODS=$(kubectl -n "$NAMESPACE_RUNNER" get pods -l runner-deployment-name="$RUNNER_NAME" -o json 2>/dev/null | \
  jq -r '.items[] | select(.status.containerStatuses[]?.lastState.terminated.reason == "OOMKilled") | .metadata.name' 2>/dev/null || echo "")

if [[ -n "$OOM_PODS" ]]; then
  echo "   ⚠ FOUND OOMKilled pods:"
  echo "$OOM_PODS" | while read -r pod; do
    echo "     - $pod"
  done
  echo ""
  echo "   💡 SOLUTION: Increase memory limits in RunnerDeployment"
  echo "      Current limits: 4Gi (runner) + 4Gi (dockerd) = 8Gi total"
  echo "      Edit: kubectl -n ${NAMESPACE_RUNNER} edit runnerdeployment ${RUNNER_NAME}"
  echo ""
else
  echo "   ✓ No OOMKilled pods found"
  echo ""
fi

# ============================================================================
# 2. Check for PreStopHook failures
# ============================================================================
echo "2. Checking for PreStopHook failures"
echo "   ────────────────────────────────────────────────────────────────────"
PRESTOP_FAILURES=$(kubectl -n "$NAMESPACE_RUNNER" get events --sort-by='.lastTimestamp' 2>/dev/null | \
  grep -i "FailedPreStopHook" | tail -5 || echo "")

if [[ -n "$PRESTOP_FAILURES" ]]; then
  echo "   ⚠ FOUND PreStopHook failures:"
  echo "$PRESTOP_FAILURES" | while read -r line; do
    echo "     $line"
  done
  echo ""
  echo "   💡 PreStopHook failures usually indicate:"
  echo "      - Dockerd container is unresponsive (often due to OOM)"
  echo "      - Termination grace period too short"
  echo "      - Dockerd already crashed before shutdown"
  echo ""
  echo "   💡 SOLUTION:"
  echo "      1. Increase memory limits (most common fix)"
  echo "      2. Increase terminationGracePeriodSeconds (already set to 300s)"
  echo ""
else
  echo "   ✓ No PreStopHook failures found"
  echo ""
fi

# ============================================================================
# 3. Check recent pod terminations
# ============================================================================
echo "3. Recent pod terminations (last 10)"
echo "   ────────────────────────────────────────────────────────────────────"
kubectl -n "$NAMESPACE_RUNNER" get pods -l runner-deployment-name="$RUNNER_NAME" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\t"}{.status.containerStatuses[0].lastState.terminated.finishedAt}{"\n"}{end}' 2>/dev/null | \
  sort -k4 -r | head -10 | while IFS=$'\t' read -r name phase reason finished; do
  if [[ -n "$reason" && "$reason" != "<no value>" ]]; then
    echo "   ⚠ $name: $phase (reason: $reason, finished: ${finished:-unknown})"
  fi
done
echo ""

# ============================================================================
# 4. Check pod events for termination reasons
# ============================================================================
echo "4. Recent events related to runners (last 20)"
echo "   ────────────────────────────────────────────────────────────────────"
kubectl -n "$NAMESPACE_RUNNER" get events --sort-by='.lastTimestamp' 2>/dev/null | \
  grep -iE 'runner|oom|kill|evict|pressure|memory' | tail -20 || echo "   (no relevant events found)"
echo ""

# ============================================================================
# 5. Check current resource usage
# ============================================================================
echo "5. Current resource usage"
echo "   ────────────────────────────────────────────────────────────────────"
if kubectl top pods -n "$NAMESPACE_RUNNER" -l runner-deployment-name="$RUNNER_NAME" 2>/dev/null | head -5; then
  echo ""
else
  echo "   ⚠ Metrics server not available (cannot show resource usage)"
  echo ""
fi

# ============================================================================
# 6. Check node resources
# ============================================================================
echo "6. Node resource allocation"
echo "   ────────────────────────────────────────────────────────────────────"
NODES=$(kubectl get nodes -o name 2>/dev/null | head -3)
if [[ -n "$NODES" ]]; then
  for node in $NODES; do
    node_name="${node#node/}"
    echo "   Node: $node_name"
    kubectl describe node "$node_name" 2>/dev/null | grep -A 10 "Allocated resources" || echo "     (could not get node info)"
    echo ""
  done
else
  echo "   ⚠ Could not get node information"
  echo ""
fi

# ============================================================================
# 7. Check specific pod if provided
# ============================================================================
if [[ -n "$SPECIFIC_POD" ]]; then
  echo "7. Detailed information for pod: $SPECIFIC_POD"
  echo "   ────────────────────────────────────────────────────────────────────"
  
  if kubectl -n "$NAMESPACE_RUNNER" get pod "$SPECIFIC_POD" >/dev/null 2>&1; then
    echo ""
    echo "   Status:"
    kubectl -n "$NAMESPACE_RUNNER" get pod "$SPECIFIC_POD" -o jsonpath='{.status}' | jq '.' 2>/dev/null || kubectl -n "$NAMESPACE_RUNNER" get pod "$SPECIFIC_POD" -o yaml | grep -A 50 "status:" | head -60
    echo ""
    echo "   Events:"
    kubectl -n "$NAMESPACE_RUNNER" describe pod "$SPECIFIC_POD" 2>/dev/null | grep -A 20 "Events:" || echo "     (no events)"
    echo ""
    echo "   Last 50 lines of logs:"
    kubectl -n "$NAMESPACE_RUNNER" logs "$SPECIFIC_POD" --tail=50 2>/dev/null || echo "     (could not get logs)"
    echo ""
  else
    echo "   ⚠ Pod not found: $SPECIFIC_POD"
    echo ""
  fi
fi

# ============================================================================
# 8. Check RunnerDeployment configuration
# ============================================================================
echo "8. RunnerDeployment resource limits and termination settings"
echo "   ────────────────────────────────────────────────────────────────────"
if kubectl -n "$NAMESPACE_RUNNER" get runnerdeployment "$RUNNER_NAME" >/dev/null 2>&1; then
  echo "   Runner container limits:"
  kubectl -n "$NAMESPACE_RUNNER" get runnerdeployment "$RUNNER_NAME" -o jsonpath='{.spec.template.spec.resources}' | jq '.' 2>/dev/null || echo "     (could not parse)"
  echo ""
  echo "   Dockerd container limits:"
  kubectl -n "$NAMESPACE_RUNNER" get runnerdeployment "$RUNNER_NAME" -o jsonpath='{.spec.template.spec.dockerdContainerResources}' | jq '.' 2>/dev/null || echo "     (could not parse)"
  echo ""
  echo "   Termination grace period:"
  TERM_GRACE=$(kubectl -n "$NAMESPACE_RUNNER" get runnerdeployment "$RUNNER_NAME" -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}' 2>/dev/null || echo "not set")
  if [[ "$TERM_GRACE" == "not set" ]]; then
    echo "     ⚠ Not configured (default: 30s, recommended: 300s)"
  else
    echo "     ✓ ${TERM_GRACE}s"
  fi
  echo ""
else
  echo "   ⚠ RunnerDeployment not found: $RUNNER_NAME"
  echo ""
fi

# ============================================================================
# Summary and recommendations
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Diagnostic Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Most common causes of runner stops:"
echo ""
echo "1. OOMKilled (Out of Memory) - MOST COMMON"
echo "   - Symptom: Pods terminated with reason 'OOMKilled'"
echo "   - Also causes: PreStopHook failures (dockerd becomes unresponsive)"
echo "   - Solution: Increase memory limits in RunnerDeployment"
echo "   - Command: kubectl -n ${NAMESPACE_RUNNER} edit runnerdeployment ${RUNNER_NAME}"
echo "   - Recommended: Increase to 8Gi for runner, 6Gi for dockerd (total 14Gi)"
echo ""
echo "   PreStopHook failures are often a symptom of OOM:"
echo "   - When pod is OOMKilled, dockerd may be unresponsive"
echo "   - PreStopHook tries to gracefully shut down dockerd but times out"
echo "   - Fix: Increase memory limits (prevents OOM) + terminationGracePeriodSeconds (already 300s)"
echo ""
echo "2. Node Pressure / Eviction"
echo "   - Symptom: Pods evicted due to node resource pressure"
echo "   - Solution: Add more nodes or reduce other workloads"
echo "   - Check: kubectl top nodes"
echo ""
echo "3. Health Check Failures"
echo "   - Symptom: Pods restarting frequently"
echo "   - Solution: Check pod logs for errors"
echo "   - Command: kubectl -n ${NAMESPACE_RUNNER} logs -l runner-deployment-name=${RUNNER_NAME} --tail=100"
echo ""
echo "4. Manual Termination"
echo "   - Symptom: Pods terminated by user/admin"
echo "   - Solution: Check audit logs or kubectl events"
echo ""
echo "To increase memory limits, edit the RunnerDeployment:"
echo "  kubectl -n ${NAMESPACE_RUNNER} edit runnerdeployment ${RUNNER_NAME}"
echo ""
echo "Then update resources section:"
echo "  resources:"
echo "    limits:"
echo "      memory: \"8Gi\"  # Increase from 4Gi"
echo "  dockerdContainerResources:"
echo "    limits:"
echo "      memory: \"6Gi\"  # Increase from 4Gi"
echo ""

