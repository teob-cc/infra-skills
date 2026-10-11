#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Read-only kubeconfig for an agent (kubernetes-mcp-server)
# ============================================================================
# Writes a kubeconfig with one context per cluster, each authenticated as the
# ServiceAccount kube-system/claude-readonly with a short-lived token (a
# TokenRequest, `kubectl create token`; no token Secret exists in any cluster).
# Re-run when the tokens expire. Also installs the kubernetes-mcp-server
# configuration (tools/k3s/claude-mcp/kubernetes-mcp-server.toml).
#
# Usage (with your own admin kube contexts, named as you pass them):
#   tools/k3s/claude-ro-kubeconfig.sh <context> [<context> ...]
#   DURATION=8h tools/k3s/claude-ro-kubeconfig.sh test prod
#
# Environment:
#   KUBECONFIG_OUT  the kubeconfig written (default ~/.kube/claude-ro.yaml); contexts
#                   not named this time keep their entries
#   DURATION        token lifetime (default 24h)
#   SA_NAMESPACE / SA_NAME   the ServiceAccount (default kube-system/claude-readonly)
#   MCP_CONFIG_OUT  where the MCP server config goes
#                   (default ~/.config/claude-ro/kubernetes-mcp-server.toml)
#
# The ServiceAccount and its rights are the env side, GitOps in the envs repo
# (envs/<env>/apps/claude-readonly/rbac.yaml, see docs/GITOPS.md "Read-only access
# for agents"): the ClusterRole `view` bound per namespace (no Secrets, no exec, and
# not the sso namespace, whose dex-config holds client secrets), plus the
# cluster-scoped kinds and CRDs. The script refuses to write a token that can read
# Secrets or exec. The MCP server, once (Claude Code):
#
#   claude mcp add kubernetes --scope user -- npx -y kubernetes-mcp-server@0.0.67 \
#     --config ~/.config/claude-ro/kubernetes-mcp-server.toml --kubeconfig ~/.kube/claude-ro.yaml
# ============================================================================

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <context> [<context> ...]" >&2
  echo "Contexts in your kubeconfig:" >&2
  kubectl config get-contexts -o name 2>/dev/null | sed 's/^/  /' >&2 || true
  exit 1
fi

OUT="${KUBECONFIG_OUT:-$HOME/.kube/claude-ro.yaml}"
DURATION="${DURATION:-24h}"
SA_NAMESPACE="${SA_NAMESPACE:-kube-system}"
SA_NAME="${SA_NAME:-claude-readonly}"
MCP_CONFIG_OUT="${MCP_CONFIG_OUT:-$HOME/.config/claude-ro/kubernetes-mcp-server.toml}"
HERE="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[claude-ro-kubeconfig] $*"; }
warn() { echo "[claude-ro-kubeconfig:warn] $*" >&2; }
err() { echo "[claude-ro-kubeconfig:error] $*" >&2; }

for tool in kubectl yq; do
  command -v "$tool" >/dev/null || { err "$tool is needed"; exit 1; }
done

umask 077
mkdir -p "$(dirname "$OUT")" "$(dirname "$MCP_CONFIG_OUT")"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
# Start from the current file so that contexts not named this time keep their
# (possibly still valid) entries.
if [[ -f "$OUT" ]]; then
  cp "$OUT" "$TMP"
else
  printf 'apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []\n' > "$TMP"
fi

for ctx in "$@"; do
  server="$(kubectl config view --raw --minify --context "$ctx" -o jsonpath='{.clusters[0].cluster.server}')"
  ca="$(kubectl config view --raw --minify --context "$ctx" -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  [[ -n "$server" && -n "$ca" ]] || { err "context '$ctx' has no server or CA data"; exit 1; }
  if ! kubectl --context "$ctx" -n "$SA_NAMESPACE" get serviceaccount "$SA_NAME" >/dev/null 2>&1; then
    warn "skip $ctx: no ServiceAccount $SA_NAMESPACE/$SA_NAME (the env's claude-readonly manifests are not synced there)"
    continue
  fi
  token="$(kubectl --context "$ctx" -n "$SA_NAMESPACE" create token "$SA_NAME" --duration="$DURATION")"
  NAME="$ctx" SERVER="$server" CA="$ca" TOKEN="$token" USER_NAME="${SA_NAME}@${ctx}" yq -i '
    .clusters = ((.clusters // []) | map(select(.name != strenv(NAME))) + [{"name": strenv(NAME), "cluster": {"server": strenv(SERVER), "certificate-authority-data": strenv(CA)}}]) |
    .users = ((.users // []) | map(select(.name != strenv(USER_NAME))) + [{"name": strenv(USER_NAME), "user": {"token": strenv(TOKEN)}}]) |
    .contexts = ((.contexts // []) | map(select(.name != strenv(NAME))) + [{"name": strenv(NAME), "context": {"cluster": strenv(NAME), "user": strenv(USER_NAME)}}])
  ' "$TMP"
  unset token
  # What the token may do, as a check: reading pods yes, reading Secrets and exec no.
  pods="$(kubectl --kubeconfig "$TMP" --context "$ctx" auth can-i list pods -n default 2>/dev/null || true)"
  secrets="$(kubectl --kubeconfig "$TMP" --context "$ctx" auth can-i get secrets -n default 2>/dev/null || true)"
  exec_="$(kubectl --kubeconfig "$TMP" --context "$ctx" auth can-i create pods --subresource=exec -n default 2>/dev/null || true)"
  log "$ctx: token for $DURATION (list pods: $pods, get secrets: $secrets, exec: $exec_)"
  if [[ "$secrets" != "no" || "$exec_" != "no" ]]; then
    err "the $SA_NAME token of $ctx can read Secrets or exec; not writing $OUT"
    exit 1
  fi
done

if [[ "$(yq '.contexts | length' "$TMP")" -gt 0 && "$(yq '.current-context // ""' "$TMP")" == "" ]]; then
  NAME="$(yq '.contexts[0].name' "$TMP")" yq -i '.current-context = strenv(NAME)' "$TMP"
fi
mv "$TMP" "$OUT"
chmod 600 "$OUT"
trap - EXIT
install -m 0644 "$HERE/claude-mcp/kubernetes-mcp-server.toml" "$MCP_CONFIG_OUT"
log "Wrote $OUT ($(yq '[.contexts[].name] | join(", ")' "$OUT")) and $MCP_CONFIG_OUT"
