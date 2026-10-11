#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Grafana token for mcp-grafana
# ============================================================================
# mcp-grafana (the Grafana MCP server, envs/<env>/apps/observability/mcp-grafana.yaml
# in the envs repo, behind a Pomerium MCP route) reads Grafana with the token of a
# Viewer service account. It finds the token in the Secret
# observability/mcp-grafana-token, key `token`; the envs repo keeps it SOPS-encrypted
# in envs/<env>/secrets.sops/mcp-grafana-token.yaml so that tools/sops/apply.sh can
# restore it.
#
# Usage:
#   tools/k3s/grafana-mcp-token.sh <env-name> --ensure        # idempotent (observability.sh
#                                                            # runs it with GRAFANA_MCP=true)
#   tools/k3s/grafana-mcp-token.sh <env-name> --rotate        # always mint a new token
#   tools/k3s/grafana-mcp-token.sh <env-name> --clipboard     # a token made by hand, from the
#                                                            # clipboard (macOS)
#   tools/k3s/grafana-mcp-token.sh <env-name> <file>          # ... from a file
#   tools/k3s/grafana-mcp-token.sh <env-name>                 # ... asked for (not echoed)
#   tools/k3s/grafana-mcp-token.sh <env-name> --from-cluster  # only SOPS-encrypt the token the
#                                                            # cluster's Secret already holds
#
# --ensure and --rotate talk to Grafana's API from inside the grafana pod as its
# configured admin (provision::grafana_api): the service account `mcp-grafana`
# (role Viewer) is created when missing, and --ensure mints a token only when the
# Secret is missing or Grafana refuses the token in it. A minted or supplied token is
# applied to the cluster, encrypted into the envs repo (tools/sops/encrypt.sh, the
# envs repo's .sops.yaml) and mcp-grafana is restarted. No value is printed and no
# plaintext copy is left behind. Commit the encrypted file afterwards.
#
# Old tokens stay valid until deleted in Grafana (Administration -> Service
# accounts -> mcp-grafana); busybox wget in the Grafana image cannot send DELETE.
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <env-name> [--ensure | --rotate | --clipboard | <file> | --from-cluster]" >&2
  echo "Available environments:" >&2
  find "$(provision::envs_root)" -maxdepth 2 -type f -name env.properties -print | \
    sed "s#$(provision::envs_root)/##; s#/env.properties##" | sort >&2 || true
  exit 1
fi
if provision::load_env "${1:-}"; then
  shift
else
  echo "ERROR: Environment '$1' not found (envs/$1/env.properties missing)." >&2
  exit 1
fi
MODE="${1:-}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need kubectl
need jq
need sops

if ! provision::validate_kubectl_context; then
  exit 1
fi

log() { echo "[grafana-mcp-token] $*"; }
info() { echo "[grafana-mcp-token:info] $*"; }
warn() { echo "[grafana-mcp-token:warn] $*" >&2; }
err() { echo "[grafana-mcp-token:error] $*" >&2; }

NAMESPACE_OBSERVABILITY="${NAMESPACE_OBSERVABILITY:-observability}"
ENVS_ROOT="$(provision::envs_root)"
ACCOUNT="${GRAFANA_MCP_ACCOUNT:-mcp-grafana}"
SECRET="mcp-grafana-token"   # what envs/<env>/apps/observability/mcp-grafana.yaml reads
FILE="${SECRET}.yaml"
PLAIN="${ENVS_ROOT}/${ENV_NAME}/secrets.plain/${FILE}"
SOPS_FILE="${ENVS_ROOT}/${ENV_NAME}/secrets.sops/${FILE}"
ns="$NAMESPACE_OBSERVABILITY"

# A Grafana service-account token is glsa_<32 alphanumerics>_<8 hex>; the first such word.
extract_token() { grep -oE 'glsa_[A-Za-z0-9]{20,}_[A-Fa-f0-9]{8}' | head -1 || true; }

# The id of the service account, created with role Viewer when missing.
ensure_account() {
  local found id role
  provision::grafana_api "$ns" GET /api/user >/dev/null 2>&1 || {
    err "Grafana refuses its configured admin (secret/grafana). Run tools/k3s/observability.sh ${ENV_NAME},"
    err "which aligns the stored admin password, then retry."
    return 1
  }
  found=$(provision::grafana_api "$ns" GET "/api/serviceaccounts/search?query=${ACCOUNT}" | \
    jq -c --arg n "$ACCOUNT" '[.serviceAccounts[]? | select(.name == $n)][0] // empty')
  if [[ -z "$found" ]]; then
    id=$(provision::grafana_api "$ns" POST /api/serviceaccounts \
      "{\"name\":\"${ACCOUNT}\",\"role\":\"Viewer\",\"isDisabled\":false}" | jq -r '.id // empty')
    [[ -n "$id" ]] || { err "Could not create the service account ${ACCOUNT}"; return 1; }
    info "✓ Service account ${ACCOUNT} created (Viewer, id ${id})" >&2
  else
    id=$(jq -r '.id' <<< "$found")
    role=$(jq -r '.role // ""' <<< "$found")
    info "✓ Service account ${ACCOUNT} exists (id ${id}, role ${role:-?})" >&2
    [[ "$role" == "Viewer" ]] || warn "Service account ${ACCOUNT} has role '${role}', not Viewer - fix it in Grafana" >&2
  fi
  echo "$id"
}

# Does Grafana accept the token the cluster's Secret holds? The token goes to the pod
# on stdin, not in argv here.
cluster_token_valid() {
  local pod
  kubectl -n "$ns" get secret "$SECRET" >/dev/null 2>&1 || return 1
  pod=$(provision::grafana_pod "$ns") || return 1
  # shellcheck disable=SC2016  # expanded by the pod's shell
  kubectl -n "$ns" get secret "$SECRET" -o jsonpath='{.data.token}' | base64 -d | \
    kubectl -n "$ns" exec -i "$pod" -c grafana -- sh -c \
      'read -r t; wget -q -O /dev/null --header "Authorization: Bearer $t" http://localhost:3000/api/org' >/dev/null 2>&1
}

mint_token() { # <account id> -> token on stdout (captured, never printed)
  provision::grafana_api "$ns" POST "/api/serviceaccounts/$1/tokens" \
    "{\"name\":\"${ACCOUNT}-$(date +%Y%m%d-%H%M%S)\"}" | jq -r '.key // empty' | extract_token
}

# Write the Secret to secrets.plain, optionally apply it, encrypt it into
# secrets.sops and remove the plaintext. $TOKEN holds the value.
store_token() { # <apply: true|false>
  local apply="$1"
  provision::assert_plaintext_ignored "$PLAIN" || return 1
  ( umask 077
    mkdir -p "$(dirname "$PLAIN")"
    cat > "$PLAIN" <<EOF
# mcp-grafana's Grafana token (service account ${ACCOUNT}, Viewer).
# Written by infra-skills tools/k3s/grafana-mcp-token.sh; never commit.
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET}
  namespace: ${ns}
type: Opaque
stringData:
  token: "${TOKEN}"
EOF
  )
  # From here on the plaintext goes, whatever happens.
  trap 'rm -f "$PLAIN"' EXIT
  if [[ "$apply" == "true" ]]; then
    kubectl apply -f "$PLAIN" >/dev/null
    info "✓ Secret ${ns}/${SECRET} applied"
  fi
  "$REPO_ROOT/tools/sops/encrypt.sh" "$ENV_NAME" "$FILE" >/dev/null
  if ! grep -q 'token: ENC\[' "$SOPS_FILE"; then
    err "The token did not come out encrypted in ${SOPS_FILE}"
    return 1
  fi
  rm -f "$PLAIN"
  trap - EXIT
  info "✓ Encrypted to ${SOPS_FILE#"${ENVS_ROOT}/"} - commit it in the envs repo"
  if [[ "$apply" == "true" ]] && kubectl -n "$ns" get deploy/mcp-grafana >/dev/null 2>&1; then
    kubectl -n "$ns" rollout restart deploy/mcp-grafana >/dev/null
    info "✓ mcp-grafana restarted"
  fi
}

TOKEN=""
case "$MODE" in
  --ensure|--rotate)
    account_id=$(ensure_account)
    if [[ "$MODE" == "--ensure" ]] && cluster_token_valid; then
      info "✓ Secret ${ns}/${SECRET} holds a token Grafana accepts - nothing to do"
      if [[ ! -f "$SOPS_FILE" ]]; then
        warn "No SOPS copy at ${SOPS_FILE#"${ENVS_ROOT}/"}; keep one with: $0 ${ENV_NAME} --from-cluster"
      fi
      exit 0
    fi
    if [[ "$MODE" == "--ensure" ]]; then
      info "No usable token in ${ns}/${SECRET} (missing, or refused by Grafana) - minting one"
    fi
    TOKEN=$(mint_token "$account_id")
    [[ -n "$TOKEN" ]] || { err "Grafana returned no token"; exit 1; }
    info "✓ Token minted for ${ACCOUNT}"
    store_token true
    ;;
  --from-cluster)
    TOKEN=$(kubectl -n "$ns" get secret "$SECRET" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d | extract_token)
    [[ -n "$TOKEN" ]] || { err "No Grafana token in the Secret ${ns}/${SECRET}"; exit 1; }
    store_token false
    ;;
  --clipboard|"")
    if [[ "$MODE" == "--clipboard" ]]; then
      need pbpaste
      TOKEN=$(pbpaste | extract_token)
    else
      [[ -t 0 ]] || { err "No terminal to ask on; pass --ensure, --clipboard or a file"; exit 1; }
      read -rs -p "Grafana service-account token (glsa_...): " raw || true
      echo
      TOKEN=$(printf '%s' "${raw:-}" | extract_token)
      unset raw
    fi
    [[ -n "$TOKEN" ]] || { err "No Grafana service-account token (glsa_...) in what came; nothing changed"; exit 1; }
    store_token true
    ;;
  -*) err "Unknown option: $MODE"; exit 1 ;;
  *)
    [[ -f "$MODE" ]] || { err "No such file: $MODE"; exit 1; }
    TOKEN=$(extract_token < "$MODE")
    [[ -n "$TOKEN" ]] || { err "No Grafana service-account token (glsa_...) in $MODE; nothing changed"; exit 1; }
    store_token true
    ;;
esac
unset TOKEN
log "=== mcp-grafana token done for environment: ${ENV_NAME} ==="
