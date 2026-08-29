#!/usr/bin/env bash
# Check certificate status and expiry for all delivery services

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== Certificate Status Check ==="
echo ""

check_cert() {
  local namespace=$1
  local secret_name=$2
  local service_name=$3
  
  echo "[$service_name]"
  
  # Check if secret exists
  if ! kubectl -n "$namespace" get secret "$secret_name" >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} Secret not found: $namespace/$secret_name"
    echo ""
    return
  fi
  
  # Get certificate data
  cert_data=$(kubectl -n "$namespace" get secret "$secret_name" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true)
  
  if [[ -z "$cert_data" ]]; then
    echo -e "  ${RED}✗${NC} No certificate data in secret"
    echo ""
    return
  fi
  
  # Check expiry
  expiry=$(echo "$cert_data" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  expiry_epoch=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry" +%s 2>/dev/null || echo "0")
  now_epoch=$(date +%s)
  days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
  
  # Check issuer
  issuer=$(echo "$cert_data" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
  
  # Check subject
  subject=$(echo "$cert_data" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')
  
  # Color code based on days left
  if [[ $days_left -lt 7 ]]; then
    color=$RED
    status="CRITICAL"
  elif [[ $days_left -lt 30 ]]; then
    color=$YELLOW
    status="WARNING"
  else
    color=$GREEN
    status="OK"
  fi
  
  echo -e "  ${color}✓${NC} Certificate valid"
  echo "  Expires: $expiry ($days_left days) - $status"
  echo "  Issuer: $issuer"
  echo "  Subject: $subject"
  
  # Check if it's a staging cert
  if echo "$issuer" | grep -qi "staging"; then
    echo -e "  ${YELLOW}⚠${NC}  Using Let's Encrypt STAGING (untrusted)"
  fi
  
  # Check Certificate resource if it exists
  if kubectl -n "$namespace" get certificate "$secret_name" >/dev/null 2>&1; then
    cert_ready=$(kubectl -n "$namespace" get certificate "$secret_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    echo "  Certificate Resource: Ready=$cert_ready"
    
    # Check for renewal status
    renewal_time=$(kubectl -n "$namespace" get certificate "$secret_name" -o jsonpath='{.status.renewalTime}' 2>/dev/null || echo "")
    if [[ -n "$renewal_time" ]]; then
      echo "  Renewal scheduled: $renewal_time"
    fi
  fi
  
  echo ""
}

# Check common delivery services
check_cert "argocd" "argocd-server-tls" "Argo CD"
check_cert "harbor" "harbor-tls" "Harbor"
check_cert "nexus" "nexus-tls" "Nexus"
check_cert "observability" "grafana-tls" "Grafana"

# Check for failed certificate requests
echo "=== Failed Certificate Requests ==="
failed_requests=$(kubectl get certificaterequest -A -o json 2>/dev/null | \
  jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="False")) | "\(.metadata.namespace)/\(.metadata.name): \(.status.conditions[] | select(.type=="Ready") | .message)"' 2>/dev/null || true)

if [[ -n "$failed_requests" ]]; then
  echo -e "${RED}Found failed certificate requests:${NC}"
  echo "$failed_requests"
  echo ""
  echo "To clean up failed requests:"
  echo "  kubectl delete certificaterequest -A --field-selector status.conditions[0].status=False"
else
  echo -e "${GREEN}✓ No failed certificate requests${NC}"
fi
echo ""

# Check cert-manager status
echo "=== cert-manager Status ==="
if kubectl -n cert-manager get pods >/dev/null 2>&1; then
  cert_manager_ready=$(kubectl -n cert-manager get pods -l app=cert-manager -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$cert_manager_ready" == "True" ]]; then
    echo -e "${GREEN}✓ cert-manager is running${NC}"
  else
    echo -e "${RED}✗ cert-manager is not ready${NC}"
    kubectl -n cert-manager get pods
  fi
else
  echo -e "${RED}✗ cert-manager namespace not found${NC}"
fi
echo ""

# Check ClusterIssuers
echo "=== ClusterIssuers ==="
kubectl get clusterissuer 2>/dev/null || echo "No ClusterIssuers found"
echo ""

echo "=== Summary ==="
echo "To check detailed certificate info:"
echo "  kubectl -n <namespace> describe certificate <name>"
echo ""
echo "To manually trigger renewal:"
echo "  kubectl -n <namespace> delete certificaterequest --all"
echo "  kubectl -n <namespace> annotate certificate <name> cert-manager.io/issue-temporary-certificate=true --overwrite"
echo ""
echo "To check rate limit status:"
echo "  kubectl -n <namespace> describe certificaterequest | grep -i 'rate limit'"
