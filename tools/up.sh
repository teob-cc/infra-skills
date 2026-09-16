#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# up — ordered, idempotent, resumable platform stack orchestrator (TEO-129)
# ============================================================================
# Applies the K3s platform stack on an ALREADY-PROVISIONED node, in the correct
# dependency order, one existing `tools/k3s/<step>.sh <env>` script per step.
#
# It is a thin orchestrator, not a re-implementation: server provisioning
# (tools/provision-hetzner-*.sh) is a prerequisite and is NOT run here. Each
# step delegates to its canonical script; up.sh only owns ORDER, CHECKPOINTING,
# and CONFIRMATION.
#
# The order is derived from the provision skill (.claude/skills/provision):
#   1. identity              cert-manager + Dex + Pomerium (base for everything)
#   2. secrets               the env's committed secrets (tools/sops/apply.sh) -- apps need them
#   3. harbor                registry (runners push images here -> before runners)
#   4. github-action-runner  CI runners (need Harbor)
#   5. argocd                GitOps (syncs envs/<env>/apps/)
#   6. observability         Prometheus + Loki + Grafana
#   7. runner-image          Harbor creds -> envs repo, build the custom runner image on the
#                            vanilla runners, switch the RunnerDeployment to it
#   8. postgres  (optional)  CloudNativePG + pgweb
#   9. mysql     (optional)  Percona MySQL operator + Adminer
#  10. redpanda  (optional)  Redpanda operator + broker (kafka-journal stack)
#  11. scylla    (optional)  Scylla operator + node (kafka-journal stack)
#  12. nexus     (optional)  artifact repository
#  13. wireguard (optional)  wg-portal VPN
#  14. backup    (optional)  host-level rdiff-backup cron to your backup host (tools/backup.sh)
#
# After redpanda/scylla ran, observability is re-applied automatically so their scrape jobs
# and alert groups load. A step whose output shows a transient error (API connection lost,
# TLS handshake timeout, Helm wait deadline) is retried once before it counts as failed.
#
# Optional steps are skipped by default. An environment declares the ones it needs in
# env.properties:  UP_OPTIONAL_STEPS="postgres nexus redpanda scylla backup"  -- those run
# in the default flow. --with-optional includes ALL optional steps; --only/--from target
# one directly. After redpanda/scylla, rerun observability to load their scrape jobs.
#
# Usage:
#   tools/up.sh <env-name> [options]
#
# Options:
#   --resume            (default) skip completed steps, continue from the first
#                       incomplete one
#   --force             rerun every selected step, ignoring checkpoints
#   --from <step>       rerun from <step> to the end (ignores checkpoints there)
#   --only <step>       run exactly one step (ignores checkpoints)
#   --with-optional     include optional steps in the default/resume flow
#   --list              print the ordered steps with completion state and exit
#                       (no cluster access needed)
#   --yes, -y           do not prompt before each step (hands-off / agent runs)
#   --help, -h          show this help
#
# Checkpoint state (per env):
#   ${XDG_STATE_HOME:-$HOME/.local/state}/infra-skills/up-<env>.state
#   One completed step name per line. Delete it to start clean.
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

PROG="$(basename "$0")"

# --- Ordered step definitions (parallel arrays; bash 3.2 compatible) ---------
# STEP_NAMES[i] is both the step id and the tools/k3s/<name>.sh basename.
STEP_NAMES=(identity secrets harbor github-action-runner argocd observability runner-image postgres mysql redpanda scylla nexus wireguard backup)
STEP_TIERS=(core     core    core   core                 core   core          core         optional optional optional optional optional optional optional)
# Script each step delegates to, relative to the repo root.
STEP_CMDS=(tools/k3s/identity.sh tools/sops/apply.sh tools/k3s/harbor.sh tools/k3s/github-action-runner.sh tools/k3s/argocd.sh tools/k3s/observability.sh tools/k3s/runner-image.sh tools/k3s/postgres.sh tools/k3s/mysql.sh tools/k3s/redpanda.sh tools/k3s/scylla.sh tools/k3s/nexus.sh tools/k3s/wireguard.sh tools/backup.sh)

# Optional steps the environment opted into (env.properties UP_OPTIONAL_STEPS, space or
# comma separated). Read after load_env, see env_wants().
env_wants() {
  local want="$1" s
  for s in ${UP_OPTIONAL_STEPS//,/ }; do [[ "$s" == "$want" ]] && return 0; done
  return 1
}

# --- Usage ------------------------------------------------------------------
print_usage() {
  cat >&2 <<EOF
Usage: $PROG <env-name> [options]

Applies the platform stack in dependency order on an already-provisioned node.

Options:
  --resume            (default) skip completed steps, continue from first incomplete
  --force             rerun every selected step, ignoring checkpoints
  --from <step>       rerun from <step> to the end
  --only <step>       run exactly one step
  --with-optional     include ALL optional steps (an env lists the ones it needs in
                      env.properties UP_OPTIONAL_STEPS; those always run)
  --list              print ordered steps with completion state and exit
  --yes, -y           do not prompt before each step
  --help, -h          show this help

Steps (in order):
EOF
  local i
  for i in "${!STEP_NAMES[@]}"; do
    printf '  %d. %-22s (%s)\n' "$((i + 1))" "${STEP_NAMES[$i]}" "${STEP_TIERS[$i]}" >&2
  done
  cat >&2 <<EOF

Available environments:
EOF
  find "$(provision::envs_root)" -maxdepth 2 -type f -name env.properties -print 2>/dev/null | \
    sed "s#$(provision::envs_root)/##; s#/env.properties##" | sort || true
}

# --- Early flag-only handling (--help before requiring an env) ---------------
for a in "$@"; do
  case "$a" in
    -h|--help) print_usage; exit 0 ;;
  esac
done

# --- Environment argument ---------------------------------------------------
if [[ -z "${1:-}" ]]; then
  print_usage
  exit 1
fi

if provision::load_env "${1:-}"; then
  shift
else
  provision::error "Environment '${1}' not found (${1}/env.properties missing under $(provision::envs_root))."
  exit 1
fi

# --- Flag parsing -----------------------------------------------------------
MODE="resume"        # resume | force
ASSUME_YES=0
WITH_OPTIONAL=0
ONLY_STEP=""
FROM_STEP=""
DO_LIST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume)        MODE="resume" ;;
    --force)         MODE="force" ;;
    --from)          FROM_STEP="${2:-}"; shift ;;
    --from=*)        FROM_STEP="${1#*=}" ;;
    --only)          ONLY_STEP="${2:-}"; shift ;;
    --only=*)        ONLY_STEP="${1#*=}" ;;
    --with-optional) WITH_OPTIONAL=1 ;;
    --list)          DO_LIST=1 ;;
    -y|--yes)        ASSUME_YES=1 ;;
    -h|--help)       print_usage; exit 0 ;;
    *)               provision::error "Unknown argument: $1"; print_usage; exit 1 ;;
  esac
  shift
done

# --- Step helpers -----------------------------------------------------------
# Return the index of a step name, or -1 if unknown.
step_index() {
  local want="$1" i
  for i in "${!STEP_NAMES[@]}"; do
    [[ "${STEP_NAMES[$i]}" == "$want" ]] && { echo "$i"; return 0; }
  done
  echo "-1"
  return 1
}

validate_step_name() {
  local name="$1"
  if [[ "$(step_index "$name")" == "-1" ]]; then
    provision::error "Unknown step: '${name}'. Valid steps: ${STEP_NAMES[*]}"
    exit 1
  fi
}

# --- Checkpoint state -------------------------------------------------------
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/infra-skills"
STATE_FILE="${STATE_DIR}/up-${ENV_NAME}.state"

is_done() {
  [[ -f "$STATE_FILE" ]] && grep -qxF "$1" "$STATE_FILE"
}

mark_done() {
  mkdir -p "$STATE_DIR"
  is_done "$1" || printf '%s\n' "$1" >>"$STATE_FILE"
}

# --- --list (no cluster needed) ---------------------------------------------
if [[ "$DO_LIST" -eq 1 ]]; then
  echo "Stack steps for env '${ENV_NAME}':"
  echo "State file: ${STATE_FILE}"
  echo
  for i in "${!STEP_NAMES[@]}"; do
    local_mark="[ ]"
    is_done "${STEP_NAMES[$i]}" && local_mark="[x]"
    tier="${STEP_TIERS[$i]}"; [[ "$tier" == optional ]] && env_wants "${STEP_NAMES[$i]}" && tier="optional, selected by env"
    printf '  %s %2d. %-22s (%s)\n' "$local_mark" "$((i + 1))" "${STEP_NAMES[$i]}" "$tier"
  done
  exit 0
fi

# --- Build the selected (active) step list ----------------------------------
# ACTIVE holds the ordered indices to consider. RESPECT_STATE decides whether a
# completed step is skipped.
ACTIVE=()
RESPECT_STATE=1

if [[ -n "$ONLY_STEP" ]]; then
  validate_step_name "$ONLY_STEP"
  ACTIVE=("$(step_index "$ONLY_STEP")")
  RESPECT_STATE=0
elif [[ -n "$FROM_STEP" ]]; then
  validate_step_name "$FROM_STEP"
  from_idx="$(step_index "$FROM_STEP")"
  RESPECT_STATE=0
  for i in "${!STEP_NAMES[@]}"; do
    (( i < from_idx )) && continue
    if [[ "${STEP_TIERS[$i]}" == "optional" && "$WITH_OPTIONAL" -ne 1 && "$i" -ne "$from_idx" ]] && ! env_wants "${STEP_NAMES[$i]}"; then
      continue
    fi
    ACTIVE+=("$i")
  done
else
  # resume / force over the default flow (core + optional-if-requested)
  [[ "$MODE" == "force" ]] && RESPECT_STATE=0
  for i in "${!STEP_NAMES[@]}"; do
    if [[ "${STEP_TIERS[$i]}" == "optional" && "$WITH_OPTIONAL" -ne 1 ]] && ! env_wants "${STEP_NAMES[$i]}"; then
      continue
    fi
    ACTIVE+=("$i")
  done
fi

# --- Confirmation prompt ----------------------------------------------------
confirm_step() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  local ans=""
  if [[ -r /dev/tty ]]; then
    read -r -p "  → run step '$1'? [y/N] " ans </dev/tty || ans=""
  else
    read -r -p "  → run step '$1'? [y/N] " ans || ans=""
  fi
  [[ "$ans" =~ ^[Yy] ]]
}

# --- Pre-flight -------------------------------------------------------------
provision::info "up: applying stack for env '${ENV_NAME}' (mode: ${MODE}$([[ $WITH_OPTIONAL -eq 1 ]] && echo ', +optional')$([[ -n $ONLY_STEP ]] && echo ", only=${ONLY_STEP}")$([[ -n $FROM_STEP ]] && echo ", from=${FROM_STEP}"))"
provision::info "state file: ${STATE_FILE}"

if ! command -v kubectl >/dev/null 2>&1; then
  provision::error "kubectl not found — a stack apply targets the live cluster."
  exit 1
fi

# A stack apply targets the live cluster — validate the context first.
if ! provision::validate_kubectl_context; then
  exit 1
fi

# --- Cluster preflight (read-only) -----------------------------------------
# Catches what validate-keys cannot (it runs before the server exists): node not Ready,
# DNS not pointing at the server, 443 closed, runner MTU mismatch. Warnings do not stop
# the run; a node that is not Ready does.
PREFLIGHT="${REPO_ROOT}/tools/preflight-cluster.sh"
if [[ -x "$PREFLIGHT" && -z "$ONLY_STEP" ]]; then
  if ! "$PREFLIGHT" "$ENV_NAME"; then
    provision::error "cluster preflight failed — fix the FAIL lines above, then re-run."
    exit 1
  fi
fi

# --- Execute ----------------------------------------------------------------
# Transient failure signatures worth one automatic retry (seen on real runs: an HTTP/2
# connection to the API server dropped mid-apply over Tailscale; Helm's --wait deadline).
TRANSIENT_RE='client connection lost|connection reset by peer|TLS handshake timeout|i/o timeout|context deadline exceeded|EOF$|connection refused'
run_step() {
  # run_step <script> <env> -> exit status of the (possibly retried) step
  local script="$1" env="$2" log rc
  log=$(mktemp)
  "$script" "$env" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if [[ $rc -ne 0 ]] && grep -qiE "$TRANSIENT_RE" "$log"; then
    provision::warn "step failed with a transient-looking error; retrying once in 20s..."
    sleep 20
    "$script" "$env" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
  fi
  rm -f "$log"
  return "$rc"
}

resume_hint() {
  local step="$1"
  provision::error ""
  provision::error "Step '${step}' FAILED. Nothing after it was run."
  provision::error "Fix the cause, then resume with:"
  provision::error "  ${PROG} ${ENV_NAME} --from ${step}"
  provision::error "or rerun just that step:"
  provision::error "  ${PROG} ${ENV_NAME} --only ${step}"
}

ran=0
skipped=0
for idx in "${ACTIVE[@]}"; do
  name="${STEP_NAMES[$idx]}"
  tier="${STEP_TIERS[$idx]}"
  script="${REPO_ROOT}/${STEP_CMDS[$idx]}"

  if [[ "$RESPECT_STATE" -eq 1 ]] && is_done "$name"; then
    provision::info "skip  ${name} (already completed)"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ ! -x "$script" ]]; then
    provision::error "step script not found or not executable: ${script}"
    exit 1
  fi

  echo
  provision::info "step  ${name} (${tier})  →  ${STEP_CMDS[$idx]} ${ENV_NAME}"
  if ! confirm_step "$name"; then
    provision::warn "declined '${name}'. Stopping to preserve step order."
    provision::warn "Resume with: ${PROG} ${ENV_NAME} --from ${name}"
    exit 0
  fi

  if run_step "$script" "$ENV_NAME"; then
    mark_done "$name"
    ran=$((ran + 1))
    provision::info "done  ${name}"
    [[ "$name" == redpanda || "$name" == scylla ]] && RERUN_OBSERVABILITY=1
  else
    rc=$?
    resume_hint "$name"
    exit "$rc"
  fi
done

# Redpanda/Scylla ship scrape jobs and alert groups that observability.sh only picks up
# once their CRDs exist. Re-apply it after they ran (idempotent, a few minutes).
if [[ "${RERUN_OBSERVABILITY:-0}" -eq 1 && -z "$ONLY_STEP" ]]; then
  echo
  provision::info "step  observability (re-apply after redpanda/scylla)  →  tools/k3s/observability.sh ${ENV_NAME}"
  if ! run_step "${REPO_ROOT}/tools/k3s/observability.sh" "$ENV_NAME"; then
    provision::warn "observability re-apply failed; run tools/k3s/observability.sh ${ENV_NAME} by hand."
  fi
fi

echo
provision::info "stack apply complete for '${ENV_NAME}': ${ran} run, ${skipped} skipped."

# --- Final verification -----------------------------------------------------
DOCTOR="${REPO_ROOT}/tools/doctor.sh"
if [[ -x "$DOCTOR" ]]; then
  provision::info "final verification: tools/doctor.sh ${ENV_NAME}"
  echo
  if "$DOCTOR" "$ENV_NAME"; then
    provision::info "doctor completed."
  else
    provision::warn "doctor reported issues — review its output above."
  fi
else
  provision::warn "tools/doctor.sh not found — skipping final verification."
fi
