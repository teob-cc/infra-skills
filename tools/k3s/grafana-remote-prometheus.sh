#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Link a reading cluster's Grafana to an exporting cluster's Prometheus
# ============================================================================
# observability.sh on the exporting env (PROMETHEUS_EXPORT_ALLOWED_CIDRS) serves its
# Prometheus query API behind basic auth; the credential is the Secret
# observability/prometheus-export (keys username, password). observability.sh on the
# reading env gives its Grafana one datasource Prometheus-<name> per entry
# <name>=<url> of GRAFANA_REMOTE_PROMETHEUS, with the credential from the Secret
# observability/grafana-remote-prometheus, keys <name>-username and <name>-password.
# This script copies the credential from the first Secret into the second, in one
# process, and keeps the reading env's SOPS copy in
# envs/<reading-env>/secrets.sops/grafana-remote-prometheus.yaml so that
# tools/sops/apply.sh can restore it. docs/GRAFANA-ACROSS-CLUSTERS.md has the order of runs.
#
# Usage:
#   tools/k3s/grafana-remote-prometheus.sh <reading-env> <name> --from <exporting-env> \
#       --from-envs-root DIR --from-kubeconfig FILE [--from-context CTX] \
#       --to-envs-root DIR --to-kubeconfig FILE [--to-context CTX]
#                                         # set or refresh the keys of <name>
#   tools/k3s/grafana-remote-prometheus.sh <reading-env> <name> --remove \
#       --to-envs-root DIR --to-kubeconfig FILE [--to-context CTX]
#                                         # drop the keys of <name> (after the datasource)
#
# Both sides are named explicitly: the envs root (the envs/ directory of each env's envs
# repo; the two may be different repos) and the admin kubeconfig, with an optional
# context (default: the kubeconfig's current one). Each context must contain its env's
# name, and the two must reach different API servers. INFRA_ENVS_ROOT and KUBECONFIG
# are not consulted.
#
# Only the keys of <name> change; the other names' keys are kept, from the cluster's
# Secret and from the SOPS copy. Values travel through pipes only: none is printed,
# none is a process argument, and the one file they touch, the git-ignored
# secrets.plain copy that tools/sops/encrypt.sh reads, is removed again whatever
# happens. Grafana is restarted when it already reads <name>'s keys. Commit the encrypted
# file in the reading env's envs repo afterwards.
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

usage() {
  sed -n '/^# Usage:/,/^# Both sides/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
}

log() { echo "[grafana-remote-prometheus] $*"; }
info() { echo "[grafana-remote-prometheus:info] $*"; }
warn() { echo "[grafana-remote-prometheus:warn] $*" >&2; }
err() { echo "[grafana-remote-prometheus:error] $*" >&2; }

if [[ $# -lt 2 || "${1:0:1}" == "-" || "${2:0:1}" == "-" ]]; then
  usage; exit 1
fi
TO_ENV="$1"; NAME="$2"; shift 2
MODE=link
FROM_ENV="" FROM_ROOT="" FROM_KUBECONFIG="" FROM_CONTEXT=""
TO_ROOT="" TO_KUBECONFIG="" TO_CONTEXT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove) MODE=remove; shift ;;
    --from|--from-envs-root|--from-kubeconfig|--from-context|--to-envs-root|--to-kubeconfig|--to-context)
      [[ $# -ge 2 && -n "$2" ]] || { err "$1 needs a value"; exit 1; }
      case "$1" in
        --from) FROM_ENV="$2" ;;
        --from-envs-root) FROM_ROOT="$2" ;;
        --from-kubeconfig) FROM_KUBECONFIG="$2" ;;
        --from-context) FROM_CONTEXT="$2" ;;
        --to-envs-root) TO_ROOT="$2" ;;
        --to-kubeconfig) TO_KUBECONFIG="$2" ;;
        --to-context) TO_CONTEXT="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { err "Missing: $1"; exit 1; }; }
need kubectl
need jq
need yq
need sops

NS="${NAMESPACE_OBSERVABILITY:-observability}"
FROM_SECRET="prometheus-export"
TO_SECRET="grafana-remote-prometheus"
FILE="${TO_SECRET}.yaml"

# The same rule as observability.sh's GRAFANA_REMOTE_PROMETHEUS check.
if ! [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,27}[a-z0-9])?$ ]]; then
  err "<name> '${NAME}' must be lower-case letters, digits and dashes, at most 29 (it becomes the uid Prometheus-<name>)"
  exit 1
fi
[[ -n "$TO_ROOT" && -n "$TO_KUBECONFIG" ]] || { err "--to-envs-root and --to-kubeconfig are required"; usage; exit 1; }
if [[ "$MODE" == link ]]; then
  [[ -n "$FROM_ENV" && -n "$FROM_ROOT" && -n "$FROM_KUBECONFIG" ]] || {
    err "--from, --from-envs-root and --from-kubeconfig are required (or --remove)"; usage; exit 1; }
  [[ "$FROM_ENV" != "$TO_ENV" ]] || { err "The exporting and the reading env are the same (${TO_ENV})"; exit 1; }
fi

# An env's own properties, read in a subshell so the two envs' env.properties never mix.
# Prints the value of each variable named, one per line (non-secret settings only).
env_props() { # <envs-root> <env> <var>...
  local root="$1" env="$2"
  shift 2
  [[ -f "${root}/${env}/env.properties" ]] || { err "No env '${env}' in ${root} (envs/${env}/env.properties missing)"; return 1; }
  ( unset HOSTNAME
    INFRA_ENVS_ROOT="$root"
    provision::load_env "$env" >/dev/null 2>&1 || exit 1
    PROMETHEUS_EXPORT_HOST="${PROMETHEUS_EXPORT_HOST:-${HOSTNAME:+prometheus-export.${HOSTNAME}}}"
    for v in "$@"; do printf '%s\n' "${!v:-}"; done )
}

# The context to use for <kubeconfig>: the one given, or its current one. It must name the env.
resolve_context() { # <kubeconfig> <context or ""> <env>
  local kc="$1" ctx="$2" env="$3"
  [[ -f "$kc" ]] || { err "No such kubeconfig: ${kc}"; return 1; }
  [[ -n "$ctx" ]] || ctx=$(kubectl --kubeconfig "$kc" config current-context 2>/dev/null || true)
  [[ -n "$ctx" ]] || { err "${kc} has no current context; pass one"; return 1; }
  if [[ "$ctx" != *"$env"* ]]; then
    err "Context '${ctx}' (${kc}) does not contain the env name '${env}'; wrong cluster?"
    return 1
  fi
  echo "$ctx"
}

abs_dir() { (cd "$1" 2>/dev/null && pwd) || { err "No such envs root: $1"; return 1; }; }
TO_ROOT=$(abs_dir "$TO_ROOT")
env_props "$TO_ROOT" "$TO_ENV" HOSTNAME >/dev/null
TO_CONTEXT=$(resolve_context "$TO_KUBECONFIG" "$TO_CONTEXT" "$TO_ENV")
kto() { kubectl --kubeconfig "$TO_KUBECONFIG" --context "$TO_CONTEXT" "$@"; }

if [[ "$MODE" == link ]]; then
  FROM_ROOT=$(abs_dir "$FROM_ROOT")
  env_props "$FROM_ROOT" "$FROM_ENV" HOSTNAME >/dev/null
  FROM_CONTEXT=$(resolve_context "$FROM_KUBECONFIG" "$FROM_CONTEXT" "$FROM_ENV")
  kfrom() { kubectl --kubeconfig "$FROM_KUBECONFIG" --context "$FROM_CONTEXT" "$@"; }
  from_server=$(kfrom config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  to_server=$(kto config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  if [[ -z "$from_server" || "$from_server" == "$to_server" ]]; then
    err "The two sides reach the same API server (${to_server:-unknown}); refusing"
    exit 1
  fi
  info "Exporting:  ${FROM_ENV} (context ${FROM_CONTEXT}, envs root ${FROM_ROOT})"
fi
info "Reading:    ${TO_ENV} (context ${TO_CONTEXT}, envs root ${TO_ROOT})"

PLAIN="${TO_ROOT}/${TO_ENV}/secrets.plain/${FILE}"
SOPS_FILE="${TO_ROOT}/${TO_ENV}/secrets.sops/${FILE}"

# The reading Secret as it stands (JSON, or null), and its SOPS copy (JSON, or null).
to_live() { kto -n "$NS" get secret "$TO_SECRET" -o json 2>/dev/null || echo null; }
to_sops() {
  if [[ -f "$SOPS_FILE" ]]; then
    sops -d "$SOPS_FILE" | yq -p yaml -o json '.' - || { err "Could not decrypt ${SOPS_FILE} (age key?); refusing to rewrite it"; return 1; }
  else
    echo null
  fi
}

# Does the reading Grafana's Deployment refer to the Secret (with any key, or with <key>)?
grafana_refers() { # [key]
  kto -n "$NS" get deploy grafana -o json 2>/dev/null | jq -e --arg s "$TO_SECRET" --arg k "${1:-}" \
    '[.. | objects | .secretKeyRef? // empty | select(.name == $s) | .key] | if $k == "" then length > 0 else index($k) != null end' >/dev/null
}

if [[ "$MODE" == remove ]] && { grafana_refers "${NAME}-username" || grafana_refers "${NAME}-password"; }; then
  err "Grafana on ${TO_ENV} still reads ${NAME}-username/${NAME}-password. Take '${NAME}=...' out of"
  err "GRAFANA_REMOTE_PROMETHEUS in envs/${TO_ENV}/env.properties and run tools/k3s/observability.sh ${TO_ENV}"
  err "with ALLOW_GRAFANA_REGRESSION=true first (it refuses to drop a live datasource otherwise)."
  exit 1
fi

# The new reading Secret, built by jq from the documents on its stdin: [exporting Secret,]
# reading Secret, SOPS copy. Kept in memory, never in argv; jq gets only names as arguments.
if [[ "$MODE" == link ]]; then
  new_secret=$( { kfrom -n "$NS" get secret "$FROM_SECRET" -o json 2>/dev/null || echo null; to_live; to_sops; } | \
    jq -s --arg n "$NAME" --arg s "$TO_SECRET" --arg ns "$NS" '
      def d: if . == null then {} else (.data // {}) + ((.stringData // {}) | map_values(@base64)) end;
      .[0] as $from | .[1] as $live | .[2] as $sops |
      if $from == null or (($from.data.username // "") == "") or (($from.data.password // "") == "")
      then error("no username/password in the exporting Secret") else . end |
      {apiVersion: "v1", kind: "Secret", type: "Opaque", metadata: {name: $s, namespace: $ns},
       data: (($sops | d) + ($live | d)
              + {($n + "-username"): $from.data.username, ($n + "-password"): $from.data.password})}') || {
    err "Could not read ${NS}/${FROM_SECRET} on ${FROM_ENV} (does its env set PROMETHEUS_EXPORT_ALLOWED_CIDRS,"
    err "and has tools/k3s/observability.sh ${FROM_ENV} run?), or the reading side could not be read. Nothing changed."
    exit 1
  }
else
  new_secret=$( { to_live; to_sops; } | jq -s --arg n "$NAME" --arg s "$TO_SECRET" --arg ns "$NS" '
      def d: if . == null then {} else (.data // {}) + ((.stringData // {}) | map_values(@base64)) end;
      .[0] as $live | .[1] as $sops |
      {apiVersion: "v1", kind: "Secret", type: "Opaque", metadata: {name: $s, namespace: $ns},
       data: (($sops | d) + ($live | d) | del(.[$n + "-username"], .[$n + "-password"]))}') || {
    err "Could not read the reading side's Secret or SOPS copy. Nothing changed."; exit 1; }
fi
names=$(printf '%s' "$new_secret" | jq -r '.data | keys[] | select(endswith("-password")) | sub("-password$"; "")' | tr '\n' ' ')

# Apply and SOPS-encrypt the new Secret through the git-ignored secrets.plain, removed whatever
# happens (the subshell's EXIT trap). Every step is checked by hand.
provision::assert_plaintext_ignored "$PLAIN" || exit 1
(
  trap 'rm -f "$PLAIN"' EXIT
  umask 077
  mkdir -p "$(dirname "$PLAIN")" || exit 1
  printf '%s' "$new_secret" | yq -p json -o yaml '.' - > "$PLAIN" || exit 1
  kto apply -f "$PLAIN" >/dev/null || { err "Could not apply ${NS}/${TO_SECRET} on ${TO_ENV}"; exit 1; }
  info "✓ Secret ${NS}/${TO_SECRET} applied on ${TO_ENV} (names: ${names:-none})"
  INFRA_ENVS_ROOT="$TO_ROOT" "$REPO_ROOT/tools/sops/encrypt.sh" "$TO_ENV" "$FILE" >/dev/null || {
    err "tools/sops/encrypt.sh failed on ${FILE}; the cluster has the new Secret, the SOPS copy is the old one"; exit 1; }
  if [[ "$(yq '(.data // {}) | to_entries | map(select((.value | tostring | test("^ENC\\[")) | not)) | length' "$SOPS_FILE")" != "0" ]]; then
    err "Not every value came out encrypted in ${SOPS_FILE}"; exit 1
  fi
  info "✓ Encrypted to ${SOPS_FILE} - commit it in that envs repo"
)
unset new_secret

# Grafana reads the keys at start: a refreshed credential needs a restart.
if [[ "$MODE" == link ]] && grafana_refers "${NAME}-password"; then
  kto -n "$NS" rollout restart deploy/grafana >/dev/null && info "✓ Grafana on ${TO_ENV} restarted to read the new credential"
fi

if [[ "$MODE" == link ]]; then
  export_host=$(env_props "$FROM_ROOT" "$FROM_ENV" PROMETHEUS_EXPORT_HOST)
  export_cidrs=$(env_props "$FROM_ROOT" "$FROM_ENV" PROMETHEUS_EXPORT_ALLOWED_CIDRS)
  [[ -n "$export_cidrs" ]] || warn "envs/${FROM_ENV}/env.properties has no PROMETHEUS_EXPORT_ALLOWED_CIDRS: the export is off there"
  current=$(env_props "$TO_ROOT" "$TO_ENV" GRAFANA_REMOTE_PROMETHEUS)
  if [[ " ${current} " != *" ${NAME}="* ]]; then
    log "Next: add this entry to GRAFANA_REMOTE_PROMETHEUS in envs/${TO_ENV}/env.properties and run"
    log "tools/k3s/observability.sh ${TO_ENV}:"
    log "  ${NAME}=https://${export_host:-<the export host of ${FROM_ENV}>}"
  elif ! grafana_refers "${NAME}-password"; then
    log "Next: tools/k3s/observability.sh ${TO_ENV} (adds the datasource Prometheus-${NAME})"
  fi
fi
log "=== ${MODE} of '${NAME}' done for ${TO_ENV} ==="
