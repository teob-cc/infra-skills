#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# K3S AmneziaWG gateway for Nexus
# ============================================================================
# People outside the cluster reach Nexus over an AmneziaWG tunnel instead of an IP allowlist.
# A tunnel peer can reach one thing: a proxy that serves Nexus read-only with a fixed account,
# so no Nexus credentials are needed on the client. Keys are self-service on a Pomerium-gated
# page (charts/amneziawg has the details).
#
# Phases:
#   1. Namespace and secrets (server key and obfuscation parameters, read-only Nexus account)
#   2. DNS: the in-tunnel Nexus hostname -> the gateway's tunnel address
#   3. Helm chart
#   4. Pomerium route and ingress for the key page
#
# Usage:
#   tools/k3s/amneziawg.sh <env-name> [--status]
#
# env.properties (all optional):
#   AWG_HOST_PORT     UDP port on the node that clients dial (default 51820); open it in the firewall
#   AWG_SUBNET_PREFIX tunnel /24 as a prefix (default "10.77.0.")
#   AWG_PORTAL_HOST   key page host (default vpn.<HOSTNAME>)
#   AWG_NEXUS_HOST    in-tunnel Nexus host (default nexus-vpn.<HOSTNAME>)
#   AWG_GROUPS        groups that may open the key page (default "<org>:vpn,<org>:admins")
#   AWG_ADMIN_GROUPS  groups that see and revoke every device (default "<org>:admins")
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--status]" >&2
  exit 1
fi
if provision::load_env "${1:-}"; then
  shift
else
  echo "ERROR: Environment '$1' not found (envs/$1/env.properties missing)." >&2
  exit 1
fi

STATUS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) STATUS=true; shift ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

provision::require_tools || exit 1
provision::validate_kubectl_context || exit 1

log() { echo "[amneziawg] $*"; }
info() { echo "[amneziawg:info] $*"; }
warn() { echo "[amneziawg:warn] $*" >&2; }
err() { echo "[amneziawg:error] $*" >&2; }

NAMESPACE_VPN="${NAMESPACE_VPN:-vpn}"
NAMESPACE_SSO="${NAMESPACE_SSO:-sso}"
NAMESPACE_NEXUS="${NAMESPACE_NEXUS:-nexus}"
RELEASE="${AWG_RELEASE:-vpn}"
: "${INGRESS_CLASS:=traefik}"
: "${CLUSTER_ISSUER:=letsencrypt-prod}"
: "${AWG_HOST_PORT:=51820}"
: "${AWG_SUBNET_PREFIX:=10.77.0.}"
: "${AWG_PORTAL_HOST:=vpn.${HOSTNAME}}"
: "${AWG_NEXUS_HOST:=nexus-vpn.${HOSTNAME}}"
AWG_LISTEN_PORT=51820
NEXUS_READER_USER="${AWG_NEXUS_USER:-vpn-reader}"
NEXUS_READER_ROLE="${AWG_NEXUS_ROLE:-vpn-read}"
SECRET_FILE="amneziawg.yaml"
SOPS_FILE="${ENVS_ROOT}/${ENV_NAME}/secrets.sops/${SECRET_FILE}"
PLAIN_FILE="${ENVS_ROOT}/${ENV_NAME}/secrets.plain/${SECRET_FILE}"

if [[ -z "${AWG_GROUPS:-}" || -z "${AWG_ADMIN_GROUPS:-}" ]]; then
  ORG=$(provision::git_org) || exit 1
  : "${AWG_GROUPS:=${ORG}:vpn,${ORG}:admins}"
  : "${AWG_ADMIN_GROUPS:=${ORG}:admins}"
fi

# ============================================================================
# Status
# ============================================================================
do_status() {
  kubectl -n "$NAMESPACE_VPN" get pods,svc,pvc,certificate -o wide 2>/dev/null || { warn "Namespace $NAMESPACE_VPN not found"; return 1; }
  echo
  info "--- interface ---"
  kubectl -n "$NAMESPACE_VPN" exec "deploy/${RELEASE}" -c awg -- awg show awg0 2>/dev/null \
    | grep -vE '^\s*(private key|preshared key):' || info "(gateway container not answering)"
  echo
  info "--- devices (public keys only) ---"
  kubectl -n "$NAMESPACE_VPN" exec "deploy/${RELEASE}" -c portal -- cat /data/peers.json 2>/dev/null \
    | jq -r '.peers[] | [.owner, .name, .ip, .createdAt] | @tsv' || info "(no state yet)"
}

if $STATUS; then
  do_status
  exit $?
fi

# ============================================================================
# Phase 1: Namespace and secrets
# ============================================================================
rand_between() { # inclusive
  local lo=$1 hi=$2 n
  n=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
  echo $(( lo + n % (hi - lo + 1) ))
}

nexus_api() { # METHOD PATH [JSON]  -> prints the HTTP code; the body stays in /tmp/awg-nexus-body in the Nexus pod
  local method=$1 path=$2 data=${3:-}
  local args=(-sS -o /tmp/awg-nexus-body -w '%{http_code}' -u "admin:${NEXUS_ADMIN_PASSWORD}" --max-time 20
    -H 'Content-Type: application/json' -X "$method")
  [[ -n "$data" ]] && args+=(-d "$data")
  kubectl -n "$NAMESPACE_NEXUS" exec "$NEXUS_POD" -- curl "${args[@]}" "http://localhost:8081/service/rest/v1${path}" 2>/dev/null || echo 000
}

# Creates (or resets the password of) the read-only Nexus account; echoes nothing, sets NEXUS_READER_PASSWORD.
ensure_nexus_reader() {
  NEXUS_POD=$(kubectl -n "$NAMESPACE_NEXUS" get pods -l app.kubernetes.io/name=nexus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$NEXUS_POD" ]] || { err "No Nexus pod in namespace $NAMESPACE_NEXUS; run nexus.sh first"; return 1; }
  NEXUS_ADMIN_PASSWORD=$(kubectl -n "$NAMESPACE_NEXUS" get secret nexus-admin-credentials -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [[ -n "$NEXUS_ADMIN_PASSWORD" ]] || { err "Secret nexus-admin-credentials not found in $NAMESPACE_NEXUS"; return 1; }

  local code role_json
  role_json=$(jq -cn --arg id "$NEXUS_READER_ROLE" \
    '{id: $id, name: $id, description: "Read and browse every repository (VPN gateway)",
      privileges: ["nx-repository-view-*-*-read", "nx-repository-view-*-*-browse"], roles: []}')
  code=$(nexus_api GET "/security/roles/${NEXUS_READER_ROLE}")
  if [[ "$code" == "200" ]]; then
    info "✓ Nexus role ${NEXUS_READER_ROLE} exists"
  else
    code=$(nexus_api POST /security/roles "$role_json")
    [[ "$code" == "200" || "$code" == "201" ]] || { err "Creating Nexus role ${NEXUS_READER_ROLE} failed (HTTP ${code})"; return 1; }
    info "✓ Nexus role ${NEXUS_READER_ROLE} created (read + browse)"
  fi

  NEXUS_READER_PASSWORD=$(openssl rand -base64 30 | tr -d '\n/+=' | cut -c1-32)
  local exists
  code=$(nexus_api GET "/security/users?userId=${NEXUS_READER_USER}")
  [[ "$code" == "200" ]] || { err "Listing Nexus users failed (HTTP ${code})"; return 1; }
  exists=$(kubectl -n "$NAMESPACE_NEXUS" exec "$NEXUS_POD" -- cat /tmp/awg-nexus-body 2>/dev/null \
    | jq -r --arg u "$NEXUS_READER_USER" '[.[] | select(.userId == $u)] | length')
  if [[ "$exists" == "1" ]]; then
    code=$(kubectl -n "$NAMESPACE_NEXUS" exec "$NEXUS_POD" -- curl -sS -o /dev/null -w '%{http_code}' \
      -u "admin:${NEXUS_ADMIN_PASSWORD}" --max-time 20 -H 'Content-Type: text/plain' -X PUT -d "$NEXUS_READER_PASSWORD" \
      "http://localhost:8081/service/rest/v1/security/users/${NEXUS_READER_USER}/change-password" 2>/dev/null || echo 000)
    [[ "$code" == "204" || "$code" == "200" ]] || { err "Resetting the password of ${NEXUS_READER_USER} failed (HTTP ${code})"; return 1; }
    info "✓ Nexus user ${NEXUS_READER_USER} existed; password reset"
  else
    local user_json
    user_json=$(jq -cn --arg u "$NEXUS_READER_USER" --arg p "$NEXUS_READER_PASSWORD" --arg r "$NEXUS_READER_ROLE" \
      '{userId: $u, firstName: "VPN", lastName: "Reader", emailAddress: "vpn-reader@local", password: $p, status: "active", roles: [$r]}')
    code=$(nexus_api POST /security/users "$user_json")
    [[ "$code" == "200" || "$code" == "201" ]] || { err "Creating Nexus user ${NEXUS_READER_USER} failed (HTTP ${code})"; return 1; }
    info "✓ Nexus user ${NEXUS_READER_USER} created with role ${NEXUS_READER_ROLE}"
  fi
  kubectl -n "$NAMESPACE_NEXUS" exec "$NEXUS_POD" -- rm -f /tmp/awg-nexus-body >/dev/null 2>&1 || true
}

generate_secrets() {
  log "Generating the gateway key, obfuscation parameters and the Nexus read-only account"
  provision::assert_plaintext_ignored "$PLAIN_FILE" || return 1
  ensure_nexus_reader

  local private_key jc jmin jmax s1 s2 h1 h2 h3 h4
  private_key=$(openssl genpkey -algorithm X25519 -outform DER | tail -c 32 | base64)
  [[ $(printf '%s' "$private_key" | base64 -d | wc -c | tr -d ' ') == "32" ]] || { err "openssl did not produce an X25519 key"; return 1; }
  jc=$(rand_between 4 10); jmin=$(rand_between 40 60); jmax=$(rand_between 70 110)
  s1=$(rand_between 15 150)
  s2=$(rand_between 15 150)
  # The protocol requires S1 + 56 != S2.
  while (( s1 + 56 == s2 )); do s2=$(rand_between 15 150); done
  h1=$(rand_between 5 2147483647); h2=$h1; h3=$h1; h4=$h1
  while (( h2 == h1 )); do h2=$(rand_between 5 2147483647); done
  while (( h3 == h1 || h3 == h2 )); do h3=$(rand_between 5 2147483647); done
  while (( h4 == h1 || h4 == h2 || h4 == h3 )); do h4=$(rand_between 5 2147483647); done

  mkdir -p "$(dirname "$PLAIN_FILE")"
  ( umask 077
    cat > "$PLAIN_FILE" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: awg-server
  namespace: ${NAMESPACE_VPN}
type: Opaque
stringData:
  awg0.conf: |
    [Interface]
    PrivateKey = ${private_key}
    ListenPort = ${AWG_LISTEN_PORT}
    Jc = ${jc}
    Jmin = ${jmin}
    Jmax = ${jmax}
    S1 = ${s1}
    S2 = ${s2}
    H1 = ${h1}
    H2 = ${h2}
    H3 = ${h3}
    H4 = ${h4}
---
apiVersion: v1
kind: Secret
metadata:
  name: awg-nexus-reader
  namespace: ${NAMESPACE_VPN}
type: Opaque
stringData:
  username: ${NEXUS_READER_USER}
  password: ${NEXUS_READER_PASSWORD}
  basic: $(printf '%s:%s' "$NEXUS_READER_USER" "$NEXUS_READER_PASSWORD" | base64 | tr -d '\n')
YAML
  )
  "$REPO_ROOT/tools/sops/encrypt.sh" "$ENV_NAME" "$SECRET_FILE"
  info "✓ Wrote ${PLAIN_FILE} and its encrypted copy; commit secrets.sops/${SECRET_FILE}"
}

log "Phase 1: namespace and secrets"
kubectl get ns "$NAMESPACE_VPN" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE_VPN"
if [[ ! -f "$SOPS_FILE" ]]; then
  generate_secrets
fi
provision::use_default_age_key 2>/dev/null || true
sops -d "$SOPS_FILE" | kubectl apply -f - >/dev/null
info "✓ Secrets awg-server and awg-nexus-reader applied from secrets.sops/${SECRET_FILE}"

# ============================================================================
# Phase 2: DNS
# ============================================================================
log "Phase 2: DNS"
GATEWAY_IP="${AWG_SUBNET_PREFIX}1"
if provision::cloudflare_read_token 2>/dev/null; then
  # The address is private: the name only works inside the tunnel, and the certificate for it
  # is issued over DNS-01.
  # provision::dns_ensure_record skips a name that a wildcard covers, and this name must NOT follow
  # the wildcard, so the record is written directly.
  zone_name=$(printf '%s' "$AWG_NEXUS_HOST" | awk -F. '{print $(NF-1)"."$NF}')
  zone_id=$(provision::cloudflare_api GET "/zones?name=${zone_name}" 2>/dev/null | jq -r '.result[0].id // empty')
  if [[ -n "$zone_id" ]]; then
    provision::cloudflare_create_or_update_dns_record "$zone_id" "$AWG_NEXUS_HOST" "$GATEWAY_IP" || warn "Could not create the record for ${AWG_NEXUS_HOST}"
  else
    warn "DNS zone ${zone_name} not found. Create by hand: ${AWG_NEXUS_HOST} A ${GATEWAY_IP}"
  fi
  if ! provision::dns_check_wildcard "$HOSTNAME" 2>/dev/null; then
    provision::dns_ensure_record "$AWG_PORTAL_HOST" "$EXTERNAL_IP" || warn "Could not create the record for ${AWG_PORTAL_HOST}"
  fi
else
  warn "No DNS API token. Create by hand: ${AWG_NEXUS_HOST} A ${GATEWAY_IP}, ${AWG_PORTAL_HOST} A ${EXTERNAL_IP}"
fi

# ============================================================================
# Phase 3: Chart
# ============================================================================
log "Phase 3: chart"
VALUES_TMP=$(mktemp)
trap 'rm -f "$VALUES_TMP"' EXIT
jq -n --arg prefix "$AWG_SUBNET_PREFIX" --argjson hostPort "$AWG_HOST_PORT" --argjson listenPort "$AWG_LISTEN_PORT" \
  --arg endpoint "${EXTERNAL_IP}:${AWG_HOST_PORT}" --arg nexusHost "$AWG_NEXUS_HOST" --arg nexusNs "$NAMESPACE_NEXUS" \
  --arg issuer "$CLUSTER_ISSUER" --arg portalHost "$AWG_PORTAL_HOST" --arg admins "$AWG_ADMIN_GROUPS" --arg ssoNs "$NAMESPACE_SSO" \
  '{awg: {subnetPrefix: $prefix, hostPort: $hostPort, listenPort: $listenPort, endpoint: $endpoint},
    nexus: {host: $nexusHost, namespace: $nexusNs, upstream: ("http://nexus." + $nexusNs + ".svc.cluster.local:8081"),
            certificate: {issuerName: $issuer}},
    portal: {host: $portalHost, adminGroups: ($admins | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))),
             pomerium: {namespace: $ssoNs}}}' > "$VALUES_TMP"
helm upgrade --install "$RELEASE" "$(provision::chart_path amneziawg)" \
  --namespace "$NAMESPACE_VPN" -f "$VALUES_TMP" ${AWG_HELM_ARGS:-}
info "✓ Release ${RELEASE} installed"

# ============================================================================
# Phase 4: Pomerium route and ingress for the key page
# ============================================================================
log "Phase 4: Pomerium route (${AWG_GROUPS})"
provision::pomerium_routes_add_for_groups \
  "https://${AWG_PORTAL_HOST}" \
  "http://${RELEASE}-portal.${NAMESPACE_VPN}.svc.cluster.local:8080" \
  "$AWG_GROUPS" "$NAMESPACE_SSO"

cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: awg-portal-pomerium
  namespace: ${NAMESPACE_SSO}
  annotations:
    cert-manager.io/cluster-issuer: ${CLUSTER_ISSUER}
    cert-manager.io/common-name: ${AWG_PORTAL_HOST}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${AWG_PORTAL_HOST}
    secretName: awg-portal-pomerium-tls
  rules:
  - host: ${AWG_PORTAL_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: pomerium-proxy
            port:
              number: 80
YAML
info "✓ Pomerium route and ingress configured"

kubectl -n "$NAMESPACE_VPN" rollout status "deploy/${RELEASE}" --timeout=300s || warn "Rollout not complete; check: $0 ${ENV_NAME} --status"

echo
log "Done."
info "  Key page:        https://${AWG_PORTAL_HOST}  (groups: ${AWG_GROUPS})"
info "  Client endpoint: ${EXTERNAL_IP}:${AWG_HOST_PORT}/udp  (must be open in the node firewall)"
info "  Nexus in tunnel: https://${AWG_NEXUS_HOST}  (read-only, no credentials)"
info "  Status:          $0 ${ENV_NAME} --status"
