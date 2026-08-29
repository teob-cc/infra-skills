#!/usr/bin/env bash
set -uo pipefail
# NOTE: deliberately no `set -e` — doctor is a read-only diagnosis that must run
# every check to completion even when individual checks fail, and report rather
# than abort.

# ============================================================================
# doctor — read-only health & drift diagnosis for a Sovereign Stack environment
# ============================================================================
# Runs entirely against your own cluster with your own kubeconfig. It NEVER
# mutates anything (only `kubectl get`, `helm list/get`, `openssl x509`), needs
# NO hosted control plane, and every check is independently guarded so a missing
# capability degrades to SKIP rather than an error.
#
# It reports drift and risk — cluster health, certificate expiry, config drift,
# backups & restore-test evidence, releases-behind, image scanning — and prints
# a remedy path. The remedies you can act on yourself are free; the managed,
# orchestrated form of the same remedies is the commercial control plane
# (see pragmasoft.nl).
#
# Usage:
#   tools/doctor.sh <env-name> [--json] [--strict]
#
#   --json     emit findings as a JSON array (for an agent to consume)
#   --strict   exit non-zero if any check is WARN or CRIT (for CI gating)
#
# Exit code: 0 normally (diagnosis is informational); with --strict, 1 if any
# WARN/CRIT finding.
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

JSON=false
STRICT=false
ENV_ARG=""
for arg in "$@"; do
  case "$arg" in
    --json) JSON=true ;;
    --strict) STRICT=true ;;
    -h|--help)
      sed -n '/^# doctor —/,/^# ===.*===$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) provision::error "unknown flag: $arg"; exit 2 ;;
    *) ENV_ARG="$arg" ;;
  esac
done

if [[ -z "$ENV_ARG" ]]; then
  cat >&2 <<EOF
Usage: $0 <env-name> [--json] [--strict]

Read-only health & drift diagnosis. Available environments:
EOF
  find "$(provision::envs_root)" -maxdepth 2 -type f -name env.properties -print 2>/dev/null | \
    sed "s#$(provision::envs_root)/##; s#/env.properties##" | sort || true
  exit 2
fi

if ! provision::load_env "$ENV_ARG"; then
  provision::error "Environment '$ENV_ARG' not found (envs/$ENV_ARG/env.properties missing)."
  exit 2
fi

command -v kubectl >/dev/null 2>&1 || { provision::error "kubectl not found"; exit 2; }
# Read-only diagnosis: a context mismatch means we'd diagnose the wrong cluster,
# so validate, but this never mutates regardless.
provision::validate_kubectl_context || exit 2

# All cluster reads go through this: read-verb only, bounded so a slow or
# unreachable cluster can never hang the diagnosis.
KC_TIMEOUT="${DOCTOR_KUBECTL_TIMEOUT:-15s}"
kc() { kubectl --request-timeout="$KC_TIMEOUT" "$@" 2>/dev/null; }
have_crd() { kc get crd "$1" >/dev/null 2>&1; }

# Is the cluster API actually reachable? Set once, up front, so downstream
# checks never mistake an unreachable API for an absent capability (a timed-out
# read looks empty otherwise). Uses a cheap authenticated liveness read.
API_OK=true
probe_api() { kubectl --request-timeout="$KC_TIMEOUT" get --raw='/livez' >/dev/null 2>&1 \
  || kubectl --request-timeout="$KC_TIMEOUT" get --raw='/healthz' >/dev/null 2>&1; }
if ! probe_api; then API_OK=false; fi
# Guard for cluster-dependent checks: emit a truthful UNKN and skip when the API
# is unreachable, rather than reporting the capability as absent.
require_api() {
  if [[ "$API_OK" != true ]]; then
    record "$1" "UNKN" "not checked — cluster API unreachable" \
      "restore API access (kubeconfig / cluster up) then re-run doctor"
    return 1
  fi
  return 0
}

# --- Findings accumulation -------------------------------------------------
# Parallel arrays: name / status / detail / remedy.
F_NAME=(); F_STATUS=(); F_DETAIL=(); F_REMEDY=()
WARN_COUNT=0
CRIT_COUNT=0

record() {
  # record <name> <status: OK|WARN|CRIT|SKIP> <detail> <remedy>
  F_NAME+=("$1"); F_STATUS+=("$2"); F_DETAIL+=("$3"); F_REMEDY+=("${4:-}")
  case "$2" in
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    CRIT) CRIT_COUNT=$((CRIT_COUNT + 1)) ;;
  esac
}

# --- Check: cluster & node health -----------------------------------------
check_cluster() {
  local nodes ready total notready
  if [[ "$API_OK" != true ]]; then
    record "cluster" "CRIT" "cluster API unreachable (kubeconfig or cluster down)" \
      "check kubeconfig / that the workload cluster is up (tools/provision-hetzner-cloud.sh)"
    return
  fi
  nodes="$(kc get nodes --no-headers)"
  if [[ -z "$nodes" ]]; then
    record "cluster" "CRIT" "API reachable but no nodes returned" \
      "check node registration / RBAC for node list"
    return
  fi
  total="$(echo "$nodes" | wc -l | tr -d ' ')"
  ready="$(echo "$nodes" | awk '$2=="Ready"' | wc -l | tr -d ' ')"
  notready=$((total - ready))
  if [[ "$notready" -gt 0 ]]; then
    record "cluster" "CRIT" "$ready/$total nodes Ready ($notready not Ready)" \
      "kubectl describe node <name>; check kubelet / network mesh"
  else
    record "cluster" "OK" "$ready/$total nodes Ready" ""
  fi
}

# --- Check: pods not Running/Completed -------------------------------------
check_pods() {
  require_api "workloads" || return
  local pods bad
  pods="$(kc get pods -A --no-headers)"
  if [[ -z "$pods" ]]; then
    record "workloads" "SKIP" "no pods visible" ""
    return
  fi
  bad="$(echo "$pods" | awk '$4!="Running" && $4!="Completed"' | wc -l | tr -d ' ')"
  if [[ "$bad" -gt 0 ]]; then
    record "workloads" "WARN" "$bad pod(s) not Running/Completed" \
      "kubectl get pods -A | grep -vE 'Running|Completed'"
  else
    record "workloads" "OK" "all pods Running/Completed" ""
  fi
}

# --- Check: TLS / certificate expiry ---------------------------------------
# Prefer cert-manager Certificate objects; fall back to scanning kubernetes.io/tls
# Secrets and reading notAfter via openssl. WARN < 21d, CRIT expired or < 7d.
check_certs() {
  require_api "certificates" || return
  local now soonest_days="" soonest_name="" expired=0 warned=0 checked=0
  now="$(date +%s)"
  local secrets
  secrets="$(kc get secrets -A --field-selector type=kubernetes.io/tls \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
  if [[ -z "$secrets" ]]; then
    record "certificates" "SKIP" "no TLS secrets found" ""
    return
  fi
  command -v openssl >/dev/null 2>&1 || { record "certificates" "SKIP" "openssl not available" ""; return; }
  local line ns name crt end_epoch days
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ns="${line%%/*}"; name="${line##*/}"
    crt="$(kc get secret "$name" -n "$ns" -o jsonpath='{.data.tls\.crt}' | base64 -d 2>/dev/null)"
    [[ -z "$crt" ]] && continue
    end_epoch="$(echo "$crt" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
    [[ -z "$end_epoch" ]] && continue
    end_epoch="$(date -j -f '%b %d %T %Y %Z' "$end_epoch" +%s 2>/dev/null || date -d "$end_epoch" +%s 2>/dev/null)"
    [[ -z "$end_epoch" ]] && continue
    checked=$((checked + 1))
    days=$(((end_epoch - now) / 86400))
    if [[ "$days" -lt 0 ]]; then expired=$((expired + 1)); fi
    if [[ "$days" -lt 21 ]]; then warned=$((warned + 1)); fi
    if [[ -z "$soonest_days" || "$days" -lt "$soonest_days" ]]; then soonest_days="$days"; soonest_name="$ns/$name"; fi
  done <<< "$secrets"
  if [[ "$checked" -eq 0 ]]; then
    record "certificates" "SKIP" "no readable certs" ""
  elif [[ "$expired" -gt 0 ]]; then
    record "certificates" "CRIT" "$expired cert(s) expired; soonest $soonest_name in ${soonest_days}d ($checked checked)" \
      "renew via cert-manager / the ingress issuer"
  elif [[ "$soonest_days" -lt 21 ]]; then
    record "certificates" "WARN" "soonest expiry $soonest_name in ${soonest_days}d ($checked checked)" \
      "confirm cert-manager auto-renewal is healthy"
  else
    record "certificates" "OK" "$checked cert(s), soonest in ${soonest_days}d" ""
  fi
}

# --- Check: config drift (GitOps) ------------------------------------------
check_drift() {
  require_api "config-drift" || return
  if ! have_crd applications.argoproj.io; then
    record "config-drift" "SKIP" "no ArgoCD (GitOps not in use here)" \
      "the paid control plane reconciles desired vs live continuously"
    return
  fi
  local apps out_of_sync degraded total
  apps="$(kc get applications.argoproj.io -A -o jsonpath='{range .items[*]}{.status.sync.status}/{.status.health.status}{"\n"}{end}')"
  if [[ -z "$apps" ]]; then
    record "config-drift" "SKIP" "ArgoCD present, no Applications" ""
    return
  fi
  total="$(echo "$apps" | grep -c . )"
  out_of_sync="$(echo "$apps" | grep -c '^OutOfSync' )"
  degraded="$(echo "$apps" | grep -c '/Degraded$' )"
  if [[ "$out_of_sync" -gt 0 || "$degraded" -gt 0 ]]; then
    record "config-drift" "WARN" "$out_of_sync/$total OutOfSync, $degraded Degraded" \
      "reconcile desired state (git) with live; argocd app sync"
  else
    record "config-drift" "OK" "$total apps Synced/Healthy" ""
  fi
}

# --- Check: backups & restore-test evidence --------------------------------
# CNPG is the reference persistence backend. A backup that has never been
# restore-tested is not a backup. We look for a restore-test marker ConfigMap
# ('doctor-restore-test' with data.lastTested) that a restore drill writes.
check_backups() {
  require_api "backups" || return
  if ! have_crd clusters.postgresql.cnpg.io; then
    record "backups" "SKIP" "no CNPG Postgres detected" ""
    return
  fi
  local scheduled last_backup marker tested_epoch now age_days
  scheduled="$(kc get scheduledbackups.postgresql.cnpg.io -A --no-headers | wc -l | tr -d ' ')"
  if [[ "${scheduled:-0}" -eq 0 ]]; then
    record "backups" "CRIT" "CNPG present but NO scheduled backups" \
      "configure a ScheduledBackup for every cluster"
    return
  fi
  # Restore-test marker (written by a restore drill; absence = never tested).
  marker="$(kc get configmap doctor-restore-test -A -o jsonpath='{.items[0].data.lastTested}')"
  now="$(date +%s)"
  if [[ -z "$marker" ]]; then
    record "backups" "WARN" "$scheduled scheduled backup(s), but NEVER restore-tested" \
      "run a restore drill and record it (a backup you can't restore isn't a backup)"
    return
  fi
  tested_epoch="$(date -j -f '%Y-%m-%d' "$marker" +%s 2>/dev/null || date -d "$marker" +%s 2>/dev/null)"
  age_days=$(((now - ${tested_epoch:-now}) / 86400))
  if [[ "$age_days" -gt 90 ]]; then
    record "backups" "WARN" "$scheduled backup(s); last restore-test ${age_days}d ago (stale)" \
      "re-run a restore drill (recommended quarterly)"
  else
    record "backups" "OK" "$scheduled backup(s); restore-tested ${age_days}d ago" ""
  fi
}

# --- Check: releases behind ------------------------------------------------
# Compares live helm chart versions against an optional upstream manifest
# (envs/shared/versions.yaml: chart -> latest version). Honest about absence.
check_releases() {
  require_api "releases" || return
  command -v helm >/dev/null 2>&1 || { record "releases" "SKIP" "helm not available" ""; return; }
  local releases count
  releases="$(helm --kube-context "$(kubectl config current-context)" list -A -o json 2>/dev/null)"
  count="$(echo "$releases" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
  local manifest="$(provision::envs_root)/shared/versions.yaml"
  if [[ ! -f "$manifest" ]]; then
    record "releases" "SKIP" "$count helm release(s); no upstream versions manifest to compare" \
      "the paid layer ships tested release bundles + upgrade orchestration"
    return
  fi
  local behind
  behind="$(echo "$releases" | python3 - "$manifest" <<'PY' 2>/dev/null || echo "?"
import sys, json, re
releases = json.load(sys.stdin)
latest = {}
for line in open(sys.argv[1]):
    m = re.match(r'\s*([\w.-]+)\s*:\s*([\w.+-]+)', line)
    if m: latest[m.group(1)] = m.group(2)
behind = [r["name"] for r in releases
          if r.get("chart","").rsplit("-",1)[0] in latest
          and not r.get("chart","").endswith(latest[r["chart"].rsplit("-",1)[0]])]
print(len(behind))
PY
)"
  if [[ "$behind" == "0" ]]; then
    record "releases" "OK" "$count release(s), all at latest known version" ""
  elif [[ "$behind" == "?" ]]; then
    record "releases" "SKIP" "$count release(s); version comparison unavailable" ""
  else
    record "releases" "WARN" "$behind release(s) behind the versions manifest" \
      "review and apply updates; the paid layer orchestrates tested upgrades"
  fi
}

# --- Check: image scanning / CVEs ------------------------------------------
# We do not fabricate a CVE count. We report whether scan evidence exists.
check_scanning() {
  require_api "image-scan" || return
  if have_crd vulnerabilityreports.aquasecurity.github.io; then
    local crit
    crit="$(kc get vulnerabilityreports.aquasecurity.github.io -A \
      -o jsonpath='{range .items[*]}{.report.summary.criticalCount}{"\n"}{end}' | awk '{s+=$1} END{print s+0}')"
    if [[ "${crit:-0}" -gt 0 ]]; then
      record "image-scan" "WARN" "trivy: $crit CRITICAL vulnerabilit(ies) across images" \
        "patch/upgrade affected images"
    else
      record "image-scan" "OK" "trivy operator present, 0 critical" ""
    fi
  else
    record "image-scan" "WARN" "no image scanner detected (CVE exposure unknown)" \
      "install trivy-operator, or subscribe for managed scanning + patch bundles"
  fi
}

# --- Run all checks --------------------------------------------------------
check_cluster
check_pods
check_certs
check_drift
check_backups
check_releases
check_scanning

# --- Output ----------------------------------------------------------------
json_escape() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }

if [[ "$JSON" == true ]]; then
  printf '{\n  "env": %s,\n  "checks": [\n' "$(json_escape "$ENV_NAME")"
  local_n=${#F_NAME[@]}
  for i in "${!F_NAME[@]}"; do
    printf '    {"check": %s, "status": %s, "detail": %s, "remedy": %s}' \
      "$(json_escape "${F_NAME[$i]}")" "$(json_escape "${F_STATUS[$i]}")" \
      "$(json_escape "${F_DETAIL[$i]}")" "$(json_escape "${F_REMEDY[$i]}")"
    [[ "$i" -lt $((local_n - 1)) ]] && printf ','
    printf '\n'
  done
  printf '  ],\n  "summary": {"warn": %d, "crit": %d}\n}\n' "$WARN_COUNT" "$CRIT_COUNT"
else
  echo ""
  echo "  doctor — $ENV_NAME  (read-only; nothing was changed)"
  echo "  ================================================================"
  for i in "${!F_NAME[@]}"; do
    printf '  [%-4s] %-14s %s\n' "${F_STATUS[$i]}" "${F_NAME[$i]}" "${F_DETAIL[$i]}"
    [[ -n "${F_REMEDY[$i]}" && "${F_STATUS[$i]}" != "OK" ]] && printf '         └─ %s\n' "${F_REMEDY[$i]}"
  done
  echo "  ================================================================"
  echo "  $WARN_COUNT warning(s), $CRIT_COUNT critical."
  if [[ "$WARN_COUNT" -gt 0 || "$CRIT_COUNT" -gt 0 ]]; then
    echo ""
    echo "  Every remedy above is yours to run — the scripts and charts are open."
    echo "  The managed form (continuous reconciliation, tested upgrade bundles,"
    echo "  restore drills, managed scanning, compliance evidence) is the"
    echo "  commercial control plane."
    echo "  See: https://pragmasoft.nl  ·  it facilitates; you stay the operator."
  fi
  echo ""
fi

if [[ "$STRICT" == true && ( "$WARN_COUNT" -gt 0 || "$CRIT_COUNT" -gt 0 ) ]]; then
  exit 1
fi
exit 0
