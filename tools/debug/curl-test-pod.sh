#!/usr/bin/env bash
# Debug intermittent connectivity in Kubernetes with repeated curl tests

set -euo pipefail

# Configuration
CONTEXT="${1:-}"
NAMESPACE="${2:-default}"
POD_NAME="curl-debug-$(date +%s)"

if [[ -z "$CONTEXT" ]]; then
  echo "Usage: $0 <context> [namespace]"
  exit 1
fi

# Switch kubectl context
echo "Switching kubectl context to '$CONTEXT'..."
kubectl config use-context "$CONTEXT"

echo "Creating debug pod '$POD_NAME' in namespace '$NAMESPACE'..."
kubectl run "$POD_NAME" \
  --image=curlimages/curl:latest \
  --restart=Never \
  --namespace "$NAMESPACE" \
  -- sleep infinity

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/"$POD_NAME" --namespace "$NAMESPACE" --timeout=60s

echo "Starting interactive shell in pod. Type exit to leave."
kubectl exec -it "$POD_NAME" -n "$NAMESPACE" -- sh

echo "Example command to test connectivity repeatedly:"
echo "kubectl exec -it $POD_NAME -n $NAMESPACE -- sh -c 'while true; do date; curl -s -o /dev/null -w \"%{http_code}\\n\" https://google.com; sleep 2; done'"

read -p "Run repeated curl test now? (y/n): " confirm
if [[ "$confirm" == "y" ]]; then
  echo "Running curl test..."
  kubectl exec "$POD_NAME" -n "$NAMESPACE" -- sh -c \
    'while true; do date; curl -s -o /dev/null -w "%{http_code}\n" https://google.com || echo "curl failed"; sleep 2; done'
fi

echo "Cleaning up..."
kubectl delete pod "$POD_NAME" -n "$NAMESPACE"
