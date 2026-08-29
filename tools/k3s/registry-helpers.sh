#!/usr/bin/env bash
# Helper functions for harbor.sh
# This file is sourced by harbor.sh

validate_prerequisites() {
  log "=== Phase 0: Prerequisites Validation ==="
  
  local validation_failed=false
  
  # Check if Dex is deployed
  info "Checking Dex SSO..."
  if ! kubectl get ns "$NAMESPACE_SSO" >/dev/null 2>&1; then
    err "Namespace ${NAMESPACE_SSO} not found. Run identity.sh first."
    validation_failed=true
  elif ! kubectl -n "$NAMESPACE_SSO" get deploy dex >/dev/null 2>&1; then
    err "Dex deployment not found in ${NAMESPACE_SSO}. Run identity.sh first."
    validation_failed=true
  else
    info "  ✓ Dex is deployed"
  fi
  
  # Check if Dex client secrets exist
  info "Checking Dex client secrets..."
  if kubectl -n "$NAMESPACE_SSO" get secret dex-client-secrets >/dev/null 2>&1; then
    local harbor_secret
    harbor_secret=$(kubectl -n "$NAMESPACE_SSO" get secret dex-client-secrets -o jsonpath='{.data.harbor}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [[ -n "$harbor_secret" ]]; then
      info "  ✓ Dex client secret for Harbor found"
    else
      err "  ✗ Dex client secret for Harbor not found in dex-client-secrets"
      validation_failed=true
    fi
  else
    err "  ✗ dex-client-secrets not found in ${NAMESPACE_SSO}. Run identity.sh first."
    validation_failed=true
  fi
  
  # Check cert-manager
  info "Checking cert-manager..."
  if kubectl get clusterissuer letsencrypt-prod >/dev/null 2>&1; then
    info "  ✓ ClusterIssuer 'letsencrypt-prod' exists"
  else
    warn "  ⚠ ClusterIssuer 'letsencrypt-prod' not found. TLS certificates may not be issued."
  fi
  
  if [[ "$validation_failed" == "true" ]]; then
    err ""
    err "Prerequisites validation failed. Please run identity.sh first:"
    err "  tools/k3s/identity.sh ${ENV_NAME}"
    exit 1
  fi
  
  info "✓ All prerequisites validated"
}

ensure_dns_records() {
  log "=== Phase 1: DNS Management ==="
  
  if ! provision::cloudflare_read_token 2>/dev/null; then
    warn "Cloudflare API token not found. Skipping DNS record creation."
    warn "DNS records must be created manually or via other means."
    return 0
  fi
  
  # Check for wildcard DNS record
  if [[ -n "${HOSTNAME:-}" ]] && provision::cloudflare_check_wildcard "$HOSTNAME"; then
    info "Wildcard DNS record found: ${WILDCARD_PATTERN} -> ${WILDCARD_IP}"
    info "Wildcard DNS covers Harbor - skipping individual record creation"
  else
    # Create DNS record for Harbor
    if [[ -n "${HARBOR_HOST:-}" ]]; then
      provision::cloudflare_ensure_dns_record "$HARBOR_HOST" "$EXTERNAL_IP" || \
        warn "Failed to create DNS record for $HARBOR_HOST"
    fi
  fi
  
  info "✓ DNS records ensured"
}

install_harbor() {
  log "=== Phase 2: Harbor Installation ==="
  
  kubectl get ns "$NAMESPACE_HARBOR" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_HARBOR"
  
  if ! helm repo list 2>/dev/null | grep -q "goharbor"; then
    info "Adding Harbor Helm repository..."
    helm repo add goharbor https://helm.goharbor.io
  fi
  helm repo update goharbor
  
  local tls_secret_exists=false
  if kubectl -n "$NAMESPACE_HARBOR" get secret "${TLS_SECRET_NAME:-harbor-tls}" >/dev/null 2>&1; then
    info "TLS secret '${TLS_SECRET_NAME:-harbor-tls}' already exists - will reuse it"
    tls_secret_exists=true
  fi
  
  # Check if Harbor is already installed to avoid updating ingress
  if helm list -n "$NAMESPACE_HARBOR" 2>/dev/null | grep -q "^harbor"; then
    info "Harbor already installed - updating without modifying ingress..."
    # Update Harbor but reuse existing values to avoid triggering cert-manager
    helm upgrade --install harbor goharbor/harbor \
      --namespace "$NAMESPACE_HARBOR" \
      --wait \
      --timeout 15m \
      --reuse-values \
      --set harborAdminPassword="$HARBOR_ADMIN_PASSWORD"
    info "  Note: Ingress not updated to avoid cert-manager rate limits"
  else
    info "Installing Harbor via Helm..."
    helm upgrade --install harbor goharbor/harbor \
      --namespace "$NAMESPACE_HARBOR" \
      --wait \
      --timeout 15m \
      --set expose.type=ingress \
      --set expose.ingress.hosts.core="$HARBOR_HOST" \
      --set expose.ingress.ingressClassName="${INGRESS_CLASS:-traefik}" \
      --set expose.ingress.annotations."cert-manager\.io/cluster-issuer"="${CLUSTER_ISSUER:-letsencrypt-prod}" \
      --set expose.ingress.annotations."cert-manager\.io/common-name"="$HARBOR_HOST" \
      --set-string expose.ingress.annotations."acme\.cert-manager\.io/http01-edit-in-place"="true" \
      --set expose.tls.enabled=true \
      --set expose.tls.secretName="${TLS_SECRET_NAME:-harbor-tls}" \
      --set externalURL="https://$HARBOR_HOST" \
      --set harborAdminPassword="$HARBOR_ADMIN_PASSWORD" \
      --set persistence.enabled=true \
      --set persistence.resourcePolicy=keep \
      --set persistence.imageChartStorage.type=filesystem \
      --set persistence.persistentVolumeClaim.registry.storageClass="${HARBOR_STORAGE_CLASS:-local-path}" \
      --set persistence.persistentVolumeClaim.registry.size="${REGISTRY_SIZE:-50Gi}" \
      --set persistence.persistentVolumeClaim.chartmuseum.storageClass="${HARBOR_STORAGE_CLASS:-local-path}" \
      --set persistence.persistentVolumeClaim.chartmuseum.size="${CHARTMUSEUM_SIZE:-5Gi}" \
      --set persistence.persistentVolumeClaim.jobservice.storageClass="${HARBOR_STORAGE_CLASS:-local-path}" \
      --set persistence.persistentVolumeClaim.jobservice.size="${JOBSERVICE_SIZE:-1Gi}" \
      --set persistence.persistentVolumeClaim.database.storageClass="${HARBOR_STORAGE_CLASS:-local-path}" \
      --set persistence.persistentVolumeClaim.database.size="${DATABASE_SIZE:-10Gi}" \
      --set persistence.persistentVolumeClaim.redis.storageClass="${HARBOR_STORAGE_CLASS:-local-path}" \
      --set persistence.persistentVolumeClaim.redis.size="${REDIS_SIZE:-2Gi}" \
      --set trivy.enabled=true \
      --set trivy.vulnerabilityReports.scannerReportsPersistence.enabled=true \
      --set persistence.persistentVolumeClaim.trivy.storageClass="${HARBOR_STORAGE_CLASS:-local-path}" \
      --set persistence.persistentVolumeClaim.trivy.size="${TRIVY_SIZE:-5Gi}" \
      --set notary.enabled="${NOTARY_ENABLED:-false}"
  fi
  
  info "Waiting for Harbor core components to be ready..."
  kubectl -n "$NAMESPACE_HARBOR" rollout status deploy -l "app.kubernetes.io/instance=harbor" --timeout=600s || true
  
  info "✓ Harbor installed successfully"
}

configure_harbor() {
  log "=== Phase 3: Harbor Configuration ==="
  
  info "Retrieving Harbor admin password from secret..."
  local actual_harbor_password
  actual_harbor_password=$(kubectl -n "$NAMESPACE_HARBOR" get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
  
  if [[ -z "$actual_harbor_password" ]]; then
    info "Could not retrieve Harbor admin password from secret. Using provided password."
    actual_harbor_password="$HARBOR_ADMIN_PASSWORD"
  else
    info "Retrieved Harbor admin password from secret (length: ${#actual_harbor_password})"
  fi
  
  local base_api="https://${HARBOR_HOST}/api/v2.0"
  local curl_args=(-sS -k)
  
  info "Waiting for Harbor API to be ready..."
  local harbor_ready=false
  local password_works=false
  
  # Try both the secret password and the provided password
  for password_attempt in "$actual_harbor_password" "$HARBOR_ADMIN_PASSWORD"; do
    if [[ -z "$password_attempt" ]]; then
      continue
    fi
    
    for i in {1..120}; do
      local http_code
      http_code=$(curl "${curl_args[@]}" --max-time 5 -w "%{http_code}" -o /dev/null \
        -u "admin:${password_attempt}" "${base_api}/systeminfo" 2>/dev/null || echo "000")
      
      if [[ "$http_code" == "200" ]]; then
        harbor_ready=true
        password_works=true
        actual_harbor_password="$password_attempt"
        break 2
      elif [[ "$http_code" == "401" ]]; then
        # Wrong password, try next one
        break
      fi
      
      if (( i % 10 == 0 )); then
        echo -n " [${i}s]"
      else
        echo -n "."
      fi
      sleep 5
    done
  done
  echo ""
  
  if [[ "$harbor_ready" != "true" ]]; then
    err "Harbor API did not become ready in 10 minutes."
    err "Harbor pods status:"
    kubectl -n "$NAMESPACE_HARBOR" get pods -l app=harbor
    err "Skipping Harbor configuration."
    exit 1
  fi
  
  if [[ "$password_works" != "true" ]]; then
    err "Harbor API is ready but authentication failed."
    err "Neither the secret password nor the provided password worked."
    err "Please check the Harbor admin password:"
    err "  kubectl -n ${NAMESPACE_HARBOR} get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d"
    exit 1
  fi
  
  info "✓ Harbor API is ready and authenticated"
  
  local current_config current_auth_mode
  current_config=$(curl "${curl_args[@]}" --max-time 10 \
    -u "admin:${actual_harbor_password}" \
    "${base_api}/systeminfo" 2>/dev/null || true)
  
  current_auth_mode=$(echo "$current_config" | jq -r '.auth_mode // empty' 2>/dev/null || true)
  
  if [[ "$current_auth_mode" == "oidc_auth" ]]; then
    info "✓ Harbor is already configured with OIDC authentication"
    info "  Auth mode: oidc_auth"
    info "  Verifying required resources exist..."
    
    # Verify Docker Hub registry exists
    local registry_exists
    registry_exists=$(curl "${curl_args[@]}" --max-time 10 \
      -u "admin:${actual_harbor_password}" \
      "${base_api}/registries" 2>/dev/null | jq -r '.[] | select(.name == "dockerhub") | .id' 2>/dev/null || true)
    
    if [[ -n "$registry_exists" ]]; then
      info "  ✓ Docker Hub registry endpoint exists (ID: ${registry_exists})"
    else
      warn "  ✗ Docker Hub registry endpoint not found"
    fi
    
    # Verify dockerhub-proxy project exists
    local project_exists
    project_exists=$(curl "${curl_args[@]}" --max-time 10 \
      -u "admin:${actual_harbor_password}" \
      "${base_api}/projects?name=dockerhub-proxy" 2>/dev/null | jq -r '.[0].project_id // empty' 2>/dev/null || true)
    
    if [[ -n "$project_exists" ]]; then
      info "  ✓ Docker Hub proxy project exists (ID: ${project_exists})"
    else
      warn "  ✗ Docker Hub proxy project not found"
    fi
    
    # Verify robot account secret exists
    if kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner >/dev/null 2>&1; then
      info "  ✓ Robot account secret exists"
    else
      warn "  ✗ Robot account secret not found"
    fi
    
    info "  Use GitHub SSO to log in: https://${HARBOR_HOST}"
  else
    info "Harbor is in database auth mode. Configuring resources..."
    info ""
    info "IMPORTANT: Resources must be created BEFORE switching to OIDC mode."
    info "Order of operations:"
    info "  1. Create Docker Hub registry endpoint"
    info "  2. Create Docker Hub proxy cache project"
    info "  3. Create robot account for CI/CD"
    info "  4. Switch to OIDC authentication"
    info ""
    
    # Step 1: Create Docker Hub registry endpoint
    create_dockerhub_registry "$actual_harbor_password" "$base_api" "${curl_args[@]}"
    
    # Step 2: Create Docker Hub proxy cache project (requires registry from step 1)
    create_dockerhub_proxy_project "$actual_harbor_password" "$base_api" "${curl_args[@]}"
    
    # Step 3: Create robot account for CI/CD
    create_robot_account "$actual_harbor_password" "$base_api" "${curl_args[@]}"
    
    # Step 4: Switch to OIDC authentication (LAST STEP - cannot create resources after this)
    info ""
    info "All resources created successfully. Now switching to OIDC authentication..."
    info "WARNING: After switching to OIDC, the admin password will no longer work."
    info ""
    configure_harbor_oidc "$actual_harbor_password" "$base_api" "${curl_args[@]}"
  fi
  
  info "✓ Harbor configuration completed"
}

create_dockerhub_registry() {
  local admin_password="$1"
  local base_api="$2"
  shift 2
  local curl_args=("$@")
  
  info "Creating Docker Hub registry endpoint..."
  
  local registry_payload
  registry_payload='{"name":"dockerhub","type":"docker-hub","url":"https://hub.docker.com","description":"Docker Hub proxy cache","insecure":false,"credential":{"type":"basic","access_key":"","access_secret":""}}'
  
  local registry_response registry_http_code registry_location registry_body
  registry_response=$(curl "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" -D - \
    -u "admin:${admin_password}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "${registry_payload}" \
    "${base_api}/registries" 2>&1 || echo -e "\n000")
  
  registry_http_code=$(echo "$registry_response" | tail -n 1)
  registry_body=$(echo "$registry_response" | sed '$d')
  
  if [[ "$registry_http_code" == "201" ]]; then
    # Extract ID from Location header: /api/v2.0/registries/1
    registry_location=$(echo "$registry_body" | grep -i '^Location:' | sed 's/\r$//' | awk '{print $2}')
    REGISTRY_ID=$(echo "$registry_location" | grep -oE '[0-9]+$' || echo "")
    
    # Fallback: try to get from response body
    if [[ -z "$REGISTRY_ID" ]]; then
      REGISTRY_ID=$(echo "$registry_body" | grep -v '^HTTP' | grep -v '^Location:' | grep -v '^Content-' | grep -v '^Date:' | jq -r '.id // empty' 2>/dev/null || true)
    fi
    
    # Final fallback: query the API
    if [[ -z "$REGISTRY_ID" || "$REGISTRY_ID" == "null" ]]; then
      info "  Querying API for registry ID..."
      REGISTRY_ID=$(curl "${curl_args[@]}" --max-time 10 \
        -u "admin:${admin_password}" \
        "${base_api}/registries" 2>/dev/null | jq -r '.[] | select(.name == "dockerhub") | .id' 2>/dev/null || true)
    fi
    
    info "  ✓ Docker Hub registry endpoint created (ID: ${REGISTRY_ID:-unknown})"
  elif [[ "$registry_http_code" == "409" ]]; then
    info "  ✓ Docker Hub registry endpoint already exists"
    REGISTRY_ID=$(curl "${curl_args[@]}" --max-time 10 \
      -u "admin:${admin_password}" \
      "${base_api}/registries" 2>/dev/null | jq -r '.[] | select(.name == "dockerhub") | .id' 2>/dev/null || true)
  elif [[ "$registry_http_code" == "401" ]]; then
    err "  Failed to create Docker Hub registry endpoint (HTTP 401 Unauthorized)"
    err "  This usually means the Harbor admin password is incorrect."
    err "  Debug steps:"
    err "    1. Check Harbor admin password in secret:"
    err "       kubectl -n ${NAMESPACE_HARBOR} get secret harbor-core -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d"
    err "    2. Try logging in manually: https://${HARBOR_HOST}"
    err "    3. Reset admin password if needed:"
    err "       kubectl -n ${NAMESPACE_HARBOR} delete secret harbor-core"
    err "       helm upgrade harbor goharbor/harbor -n ${NAMESPACE_HARBOR} --reuse-values --set harborAdminPassword=<new-password>"
    REGISTRY_ID=""
  else
    warn "  Failed to create Docker Hub registry endpoint (HTTP ${registry_http_code})"
    if [[ -n "$registry_body" ]]; then
      warn "  Response: $(echo "$registry_body" | grep -v '^HTTP' | grep -v '^Location:' | grep -v '^Content-' | grep -v '^Date:' | head -5)"
    fi
    REGISTRY_ID=""
  fi
}

create_dockerhub_proxy_project() {
  local admin_password="$1"
  local base_api="$2"
  shift 2
  local curl_args=("$@")
  
  info "Creating Docker Hub proxy cache project..."
  
  # Check if registry endpoint exists
  if [[ -z "${REGISTRY_ID:-}" || "$REGISTRY_ID" == "null" ]]; then
    err "  Registry ID not found. Cannot create proxy cache project."
    err "  Docker Hub registry endpoint must be created first."
    exit 1
  fi
  
  # Proxy cache projects MUST have registry_id set
  local dockerhub_proxy_payload
  dockerhub_proxy_payload="{\"project_name\":\"dockerhub-proxy\",\"metadata\":{\"public\":\"false\"},\"registry_id\":${REGISTRY_ID}}"
  
  local proxy_response proxy_http_code proxy_body
  proxy_response=$(curl "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
    -u "admin:${admin_password}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "${dockerhub_proxy_payload}" \
    "${base_api}/projects" 2>&1 || echo -e "\n000")
  
  proxy_http_code=$(echo "$proxy_response" | tail -n 1)
  proxy_body=$(echo "$proxy_response" | sed '$d')
  
  if [[ "$proxy_http_code" == "201" ]]; then
    info "  ✓ Docker Hub proxy cache project created"
  elif [[ "$proxy_http_code" == "409" ]]; then
    warn "  Project 'dockerhub-proxy' already exists"
    
    # Check if it's a proxy cache project
    local project_info
    project_info=$(curl "${curl_args[@]}" --max-time 10 \
      -u "admin:${admin_password}" \
      "${base_api}/projects?name=dockerhub-proxy" 2>/dev/null || true)
    
    local existing_registry_id
    existing_registry_id=$(echo "$project_info" | jq -r '.[0].registry_id // empty' 2>/dev/null || true)
    
    if [[ -z "$existing_registry_id" || "$existing_registry_id" == "null" ]]; then
      err "  ✗ Existing project is NOT a proxy cache project (no registry_id)"
      err "  Please delete the existing 'dockerhub-proxy' project in Harbor UI and re-run:"
      err "    1. Go to: https://${HARBOR_HOST}/harbor/projects"
      err "    2. Delete project: dockerhub-proxy"
      err "    3. Re-run: tools/k3s/registry.sh ${ENV_NAME}"
      exit 1
    else
      info "  ✓ Existing proxy cache project found (registry_id: ${existing_registry_id})"
      
      # Update to ensure it's linked to the correct registry
      if [[ "$existing_registry_id" != "$REGISTRY_ID" ]]; then
        warn "  Registry ID mismatch. Updating..."
        local update_payload="{\"metadata\":{\"public\":\"false\"},\"registry_id\":${REGISTRY_ID}}"
        
        local update_response update_http_code
        update_response=$(curl "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
          -u "admin:${admin_password}" \
          -H "Content-Type: application/json" \
          -X PUT \
          -d "${update_payload}" \
          "${base_api}/projects/dockerhub-proxy" 2>&1 || echo -e "\n000")
        
        update_http_code=$(echo "$update_response" | tail -n 1)
        
        if [[ "$update_http_code" == "200" ]]; then
          info "  ✓ Project updated to use registry ID: ${REGISTRY_ID}"
        else
          warn "  Failed to update project (HTTP ${update_http_code})"
        fi
      fi
    fi
  else
    err "  Failed to create Docker Hub proxy cache project (HTTP ${proxy_http_code})"
    err "  Response: ${proxy_body}"
    exit 1
  fi
  
  # Final verification
  info "  Verifying proxy cache configuration..."
  local final_project_info
  final_project_info=$(curl "${curl_args[@]}" --max-time 10 \
    -u "admin:${admin_password}" \
    "${base_api}/projects?name=dockerhub-proxy" 2>/dev/null || true)
  
  local final_registry_id
  final_registry_id=$(echo "$final_project_info" | jq -r '.[0].registry_id // empty' 2>/dev/null || true)
  
  if [[ -n "$final_registry_id" && "$final_registry_id" != "null" ]]; then
    info "  ✓ Proxy cache project properly configured"
    info "    Registry ID: ${final_registry_id}"
    info "    Type: Private Proxy Cache"
  else
    err "  ✗ Proxy cache project NOT properly configured"
    err "  Manual intervention required in Harbor UI"
    exit 1
  fi
}

create_robot_account() {
  local admin_password="$1"
  local base_api="$2"
  shift 2
  local curl_args=("$@")
  
  info "Creating robot account 'runner' for CI/CD..."
  
  local robot_payload
  robot_payload='{"name":"runner","description":"Robot account for GitHub Actions runners","duration":-1,"level":"system","permissions":[{"kind":"project","namespace":"*","access":[{"resource":"repository","action":"push"},{"resource":"repository","action":"pull"},{"resource":"artifact","action":"delete"},{"resource":"artifact","action":"read"},{"resource":"artifact","action":"list"}]}]}'
  
  local robot_response robot_http_code robot_body
  robot_response=$(curl "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
    -u "admin:${admin_password}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "${robot_payload}" \
    "${base_api}/robots" 2>&1 || echo -e "\n000")
  
  robot_http_code=$(echo "$robot_response" | tail -n 1)
  robot_body=$(echo "$robot_response" | sed '$d')
  
  if [[ "$robot_http_code" == "201" ]]; then
    local robot_name robot_secret
    robot_name=$(echo "$robot_body" | jq -r '.name // empty')
    robot_secret=$(echo "$robot_body" | jq -r '.secret // empty')
    
    info "  ✓ Robot account created: ${robot_name}"
    
    kubectl -n "$NAMESPACE_HARBOR" create secret generic harbor-robot-runner \
      --from-literal=username="${robot_name}" \
      --from-literal=password="${robot_secret}" \
      --dry-run=client -o yaml | kubectl apply -f -
    
    info "    Robot credentials stored in harbor/harbor-robot-runner secret"
    echo ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Harbor Robot Account: ${robot_name}"
    info "  Password: ${robot_secret}"
    info "  Test: docker login ${HARBOR_HOST}"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
  elif [[ "$robot_http_code" == "409" ]]; then
    info "  ✓ Robot account 'runner' already exists"
    if kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner >/dev/null 2>&1; then
      info "    Robot credentials available in harbor/harbor-robot-runner secret"
    fi
  else
    err "  Failed to create robot account (HTTP ${robot_http_code})"
    exit 1
  fi
}

configure_harbor_oidc() {
  local admin_password="$1"
  local base_api="$2"
  shift 2
  local curl_args=("$@")
  
  info "Configuring Harbor OIDC with Dex..."
  
  local dex_client_secret_harbor
  dex_client_secret_harbor=$(kubectl -n "$NAMESPACE_SSO" get secret dex-client-secrets -o jsonpath='{.data.harbor}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  if [[ -z "$dex_client_secret_harbor" ]]; then
    err "Dex client secret for Harbor not found"
    exit 1
  fi
  
  local oauth_file="$ENVS_ROOT/${ENV_NAME}/secrets.plain/github-oauth-credentials.yaml"
  local github_org_for_harbor=""
  if [[ -f "$oauth_file" ]]; then
    github_org_for_harbor=$(provision::yaml_get "$oauth_file" .stringData.githubOrg)
  fi
  
  local dex_issuer="https://${DEX_HOST}"
  local config_payload
  config_payload="{\"auth_mode\":\"oidc_auth\",\"oidc_name\":\"Dex\",\"oidc_endpoint\":\"${dex_issuer}\",\"oidc_client_id\":\"harbor\",\"oidc_client_secret\":\"${dex_client_secret_harbor}\",\"oidc_scope\":\"openid,profile,email,groups\",\"oidc_verify_cert\":false,\"oidc_auto_onboard\":true,\"oidc_user_claim\":\"preferred_username\",\"oidc_groups_claim\":\"groups\",\"oidc_admin_group\":\"${github_org_for_harbor}:admins\"}"
  
  info "Applying Harbor OIDC configuration..."
  
  local response http_code
  response=$(curl "${curl_args[@]}" --max-time 10 -w "\n%{http_code}" \
    -u "admin:${admin_password}" \
    -H "Content-Type: application/json" \
    -X PUT \
    -d "${config_payload}" \
    "${base_api}/configurations" 2>&1 || echo -e "\n000")
  
  http_code=$(echo "$response" | tail -n 1)
  
  if [[ "$http_code" == "200" ]]; then
    info "  ✓ Harbor OIDC configured successfully"
    info "    OIDC Endpoint: ${dex_issuer}"
    info "    Admin group: ${github_org_for_harbor}:admins"
  else
    err "  Failed to configure Harbor OIDC (HTTP ${http_code})"
    exit 1
  fi
}

validate_deployment() {
  log "=== Phase 4: Validation ==="
  
  local validation_failed=false
  
  info "Validating Harbor deployment..."
  
  local harbor_core_ready
  harbor_core_ready=$(kubectl -n "$NAMESPACE_HARBOR" get pods -l component=core -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  
  if [[ "$harbor_core_ready" == "True" ]]; then
    info "  ✓ Harbor core pod is Ready"
  else
    warn "  ✗ Harbor core pod not ready"
    validation_failed=true
  fi
  
  if kubectl -n "$NAMESPACE_HARBOR" get ingress harbor-ingress >/dev/null 2>&1; then
    info "  ✓ Harbor ingress exists"
  else
    warn "  ✗ Harbor ingress not found"
    validation_failed=true
  fi
  
  if kubectl -n "$NAMESPACE_HARBOR" get secret harbor-robot-runner >/dev/null 2>&1; then
    info "  ✓ Robot account credentials stored"
  else
    warn "  ✗ Robot account credentials not found"
    validation_failed=true
  fi
  
  if [[ "$validation_failed" == "true" ]]; then
    warn "Some validations failed. Check Harbor status:"
    warn "  kubectl -n ${NAMESPACE_HARBOR} get pods"
    return 1
  else
    info "✓ All validations passed"
    return 0
  fi
}
