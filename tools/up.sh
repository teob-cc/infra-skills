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
#   2. harbor                registry (runners push images here → before runners)
#   3. github-action-runner  CI runners (need Harbor)
#   4. argocd                GitOps (syncs envs/<env>/apps/)
#   5. observability         Prometheus + Loki + Grafana
#   6. postgres  (optional)  CloudNativePG + pgweb
#   7. nexus     (optional)  artifact repository
#
# Optional steps are skipped by default; include them with --with-optional, or
# target one directly with --only/--from.
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
STEP_NAMES=(identity harbor github-action-runner argocd observability postgres nexus)
STEP_TIERS=(core     core   core                 core   core          optional optional)

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
  --with-optional     include optional steps (postgres, nexus) in the flow
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
    printf '  %s %d. %-22s (%s)\n' "$local_mark" "$((i + 1))" "${STEP_NAMES[$i]}" "${STEP_TIERS[$i]}"
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
    if [[ "${STEP_TIERS[$i]}" == "optional" && "$WITH_OPTIONAL" -ne 1 && "$i" -ne "$from_idx" ]]; then
      continue
    fi
    ACTIVE+=("$i")
  done
else
  # resume / force over the default flow (core + optional-if-requested)
  [[ "$MODE" == "force" ]] && RESPECT_STATE=0
  for i in "${!STEP_NAMES[@]}"; do
    if [[ "${STEP_TIERS[$i]}" == "optional" && "$WITH_OPTIONAL" -ne 1 ]]; then
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

# --- Execute ----------------------------------------------------------------
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
  script="${REPO_ROOT}/tools/k3s/${name}.sh"

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
  provision::info "step  ${name} (${tier})  →  tools/k3s/${name}.sh ${ENV_NAME}"
  if ! confirm_step "$name"; then
    provision::warn "declined '${name}'. Stopping to preserve step order."
    provision::warn "Resume with: ${PROG} ${ENV_NAME} --from ${name}"
    exit 0
  fi

  if "$script" "$ENV_NAME"; then
    mark_done "$name"
    ran=$((ran + 1))
    provision::info "done  ${name}"
  else
    rc=$?
    resume_hint "$name"
    exit "$rc"
  fi
done

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
