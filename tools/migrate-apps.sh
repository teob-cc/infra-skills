#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Move ArgoCD-managed apps (and their Postgres data) from one environment to another
# ============================================================================
# Plan-driven; the `migrate-apps` skill (.claude/skills/migrate-apps/SKILL.md) is the procedure and
# says when to run which phase. Every kubectl call names its cluster's kubeconfig explicitly: a
# migration talks to two clusters at once, so the current context is never trusted.
#
# Usage:
#   tools/migrate-apps.sh <plan.yaml> <phase> [--yes] [--margin N] [--jobs N] [--force]
#
# Phases (read-only unless marked *; a * phase prints what it would do and stops without --yes):
#   inventory        apps, workloads, images, secrets, PVCs, hosts, DB sizes, and the chart defaults
#                    that silently keep pointing at the source (pinned namespaces, registry, DB peers)
#   artifacts *      copy the apps' images and OCI chart dependencies source Harbor -> target Harbor
#   secrets *        copy the plan's Secrets (metadata stripped, values never printed), apply rewrites
#   roles *          create the databases' owner roles on the target with the source passwords, plus
#                    NOLOGIN placeholders for every other source role (so restored GRANTs apply)
#   copy *           first copy of every database: small ones streamed (pg_dump | pg_restore), journal
#                    databases dumped into the target Postgres volume and restored there, detached
#   status           progress of the detached journal restores
#   freeze *         source: ArgoCD auto-sync off (apps + their parent app-of-apps), Deployments to 0,
#                    CronJobs suspended; state saved next to the plan for `rollback`
#   delta *          journal top-up above the restored watermark, full re-copy of everything else,
#                    sequences, and the plan's volumes
#   verify           exact row counts per table, source vs target (non-zero exit on any difference)
#   dns *            the plan's hosts -> the target's EXTERNAL_IP (explicit A records; wildcards untouched)
#   dns-rollback *   the plan's hosts -> the source's EXTERNAL_IP
#   rollback *       source: replicas, CronJobs and ArgoCD sync policies back from the freeze state
#
# Environment:
#   SRC_ENVS_ROOT / DST_ENVS_ROOT   envs roots of the two environments (default: provision::envs_root);
#                                   they differ when the environments belong to different envs repos
#   CF_ENVS_ROOT                    envs root whose shared/secrets.plain/cloudflare.yaml owns the hosts'
#                                   zones (default: SRC_ENVS_ROOT, the side the hosts are moving away from)
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

info() { provision::info "$@"; }
warn() { provision::warn "$@"; }
err() { provision::error "$@"; }
die() { err "$@"; exit 1; }

usage() { sed -n '/^# Usage:/,/^# =====/p' "$0" | sed 's/^# \{0,1\}//; /^=====/d'; }

[[ $# -ge 2 ]] || { usage; exit 2; }
PLAN=$1 PHASE=$2; shift 2
YES=false FORCE=false MARGIN=200000 JOBS=4
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=true; shift ;;
    --force) FORCE=true; shift ;;
    --margin) MARGIN=$2; shift 2 ;;
    --jobs) JOBS=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -f "$PLAN" ]] || die "plan not found: $PLAN"
provision::require_tools kubectl jq yq curl

p() { yq -r "$1" "$PLAN"; }
pj() { yq -o=json -I=0 "$1" "$PLAN"; }

SRC_ENV=$(p .source); DST_ENV=$(p .target)
[[ "$SRC_ENV" != null && "$DST_ENV" != null ]] || die "plan needs 'source' and 'target' env names"
SRC_ROOT=${SRC_ENVS_ROOT:-$(provision::envs_root)}
DST_ROOT=${DST_ENVS_ROOT:-$(provision::envs_root)}
KS=$(INFRA_ENVS_ROOT=$SRC_ROOT provision::ensure_kubeconfig "$SRC_ENV") || exit 1
KD=$(INFRA_ENVS_ROOT=$DST_ROOT provision::ensure_kubeconfig "$DST_ENV") || exit 1
prop() { (set +u; source "$1/$2/env.properties"; eval "echo \"\${$3:-}\""); }
SRC_HOSTNAME=$(prop "$SRC_ROOT" "$SRC_ENV" HOSTNAME); DST_HOSTNAME=$(prop "$DST_ROOT" "$DST_ENV" HOSTNAME)
SRC_IP=$(prop "$SRC_ROOT" "$SRC_ENV" EXTERNAL_IP); DST_IP=$(prop "$DST_ROOT" "$DST_ENV" EXTERNAL_IP)
SRC_HARBOR="harbor.${SRC_HOSTNAME}"; DST_HARBOR="harbor.${DST_HOSTNAME}"
STATE="${PLAN%.*}.freeze.json"
LOG="${PLAN%.*}.log"

ks() { kubectl --kubeconfig "$KS" "$@"; }
kd() { kubectl --kubeconfig "$KD" "$@"; }
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG" >&2; }

# Mutating phases describe themselves first; nothing changes without --yes.
confirm() {
  info "phase '$PHASE': $SRC_ENV ($SRC_IP) -> $DST_ENV ($DST_IP)"
  printf '  %s\n' "$@" >&2
  $YES || { info "re-run with --yes to do this"; exit 0; }
}

APPS=$(p '.apps[]')
DBS=$(p '.databases[]?.name')
SPG_NS=$(p '.postgres.source.namespace // "postgres"'); SPG_CL=$(p '.postgres.source.cluster // "postgres-cluster"')
DPG_NS=$(p '.postgres.target.namespace // "postgres"'); DPG_CL=$(p '.postgres.target.cluster // "postgres-cluster"')
cnpg_primary() { kubectl --kubeconfig "$1" -n "$2" get clusters.postgresql.cnpg.io "$3" -o jsonpath='{.status.currentPrimary}'; }
SPG_POD=""; DPG_POD=""
pg_pods() {
  [[ -n "$SPG_POD" ]] && return 0
  SPG_POD=$(cnpg_primary "$KS" "$SPG_NS" "$SPG_CL") || die "no CNPG cluster $SPG_NS/$SPG_CL on $SRC_ENV"
  DPG_POD=$(cnpg_primary "$KD" "$DPG_NS" "$DPG_CL") || die "no CNPG cluster $DPG_NS/$DPG_CL on $DST_ENV (create it first)"
}
# Source and target psql/pg_dump as the postgres superuser over the local socket (peer auth).
sx() { ks -n "$SPG_NS" exec -i "$SPG_POD" -c postgres -- "$@"; }
dx() { kd -n "$DPG_NS" exec -i "$DPG_POD" -c postgres -- "$@"; }
# Dumps and restore logs live in the target Postgres volume, next to PGDATA, so a restore runs
# inside the cluster and does not depend on the operator's laptop staying online.
MIG_DIR=/var/lib/postgresql/data/migrate

db_journal() { p ".databases[] | select(.name == \"$1\") | .journal.table // \"\""; }
db_ordering() { p ".databases[] | select(.name == \"$1\") | .journal.ordering // \"ordering\""; }

app_json() { ks -n argocd get applications.argoproj.io "$1" -o json; }
# Resources an Application owns, as "Kind namespace name" lines.
app_resources() { app_json "$1" | jq -r '.status.resources[]? | "\(.kind) \(.namespace // "-") \(.name)"'; }
pod_specs() {
  # Pod templates of the app's Deployments, StatefulSets and CronJobs, one JSON object per line.
  local kind ns name
  while read -r kind ns name; do
    case $kind in
      Deployment|StatefulSet) ks -n "$ns" get "$kind" "$name" -o json | jq -c --arg k "$kind" '{kind:$k, ns:.metadata.namespace, name:.metadata.name, spec:.spec.template.spec}' ;;
      CronJob) ks -n "$ns" get cronjob "$name" -o json | jq -c '{kind:"CronJob", ns:.metadata.namespace, name:.metadata.name, spec:.spec.jobTemplate.spec.template.spec}' ;;
    esac
  done < <(app_resources "$1")
}

# ---------------------------------------------------------------------------
phase_inventory() {
  local app aj dest specs
  for app in $APPS; do
    aj=$(app_json "$app") || { warn "Application $app not found on $SRC_ENV"; continue; }
    dest=$(jq -r '.spec.destination.namespace // "-"' <<<"$aj")
    echo "== $app  (destination ns: $dest, auto-sync: $(jq -c '.spec.syncPolicy.automated // "off"' <<<"$aj"), parent: $(jq -r '.metadata.annotations["argocd.argoproj.io/tracking-id"] // "-" | split(":")[0]' <<<"$aj"))"
    echo "   source: $(jq -r '.spec.source | (.repoURL + " " + (.path // .chart // "") + " " + (.targetRevision // ""))' <<<"$aj")"
    # A chart that pins its own namespace lands there whatever the Application says; the target
    # must provide that namespace (and its Secrets) too.
    jq -r --arg d "$dest" '.status.resources[]? | select(.namespace != null and .namespace != $d) | "   ! \(.kind)/\(.name) renders into namespace \(.namespace), not \($d)"' <<<"$aj" | sort -u
    # Raw manifests next to an app's chart (CronJobs calling it, say) belong to the parent
    # app-of-apps, not to the app: freeze only touches them when the plan lists them.
    local parent
    parent=$(jq -r '.metadata.annotations["argocd.argoproj.io/tracking-id"] // empty | split(":")[0]' <<<"$aj")
    [[ -z "$parent" ]] || app_resources "$parent" | awk -v a="$app" '($1=="CronJob" || $1=="Deployment") && index($3, a"-")==1 {print "   ? " $1 "/" $2 "/" $3 " is owned by the parent app: list it under extraWorkloads if it is part of " a}'
    specs=$(pod_specs "$app")
    [[ -n "$specs" ]] || { echo "   (no workloads)"; continue; }
    jq -r '"   \(.kind)/\(.name) [\(.ns)]"' <<<"$specs"
    jq -r '.spec | (.containers + (.initContainers // []))[].image' <<<"$specs" | sort -u | while read -r img; do
      if [[ $img == "$SRC_HARBOR/"* ]]; then echo "   image (copy):  $img"; else echo "   image (as-is): $img"; fi
    done
    jq -r '.ns as $n | .spec | ([(.containers + (.initContainers // []))[] | (.env[]?.valueFrom.secretKeyRef.name // empty), (.envFrom[]?.secretRef.name // empty)] + [.volumes[]?.secret.secretName // empty] + [.imagePullSecrets[]?.name // empty]) | .[] | "\($n)/\(.)"' <<<"$specs" \
      | sort -u | sed 's/^/   secret: /'
    jq -r '.ns as $n | .spec.volumes[]?.persistentVolumeClaim.claimName // empty | "\($n)/\(.)"' <<<"$specs" | sort -u | sed 's/^/   pvc: /'
    # StatefulSet volumeClaimTemplates do not show up as pod volumes.
    app_resources "$app" | awk '$1=="StatefulSet"{print $2, $3}' | while read -r ns name; do
      ks -n "$ns" get sts "$name" -o json | jq -r --arg n "$ns" '.metadata.name as $s | .spec.volumeClaimTemplates[]?.metadata.name | "   pvc: \($n)/\(.)-\($s)-0 (volumeClaimTemplate)"'
    done
    # NetworkPolicies whose egress names the source Postgres: on the target they block the new DB.
    app_resources "$app" | awk '$1=="NetworkPolicy"{print $2, $3}' | while read -r ns name; do
      ks -n "$ns" get networkpolicy "$name" -o json | jq -r --arg pns "$SPG_NS" --arg n "$name" \
        '[.spec.egress[]?.to[]? | select(.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == $pns)] | select(length > 0) | "   ! NetworkPolicy/\($n) allows egress only to the source Postgres namespace \($pns): override it for the target"'
    done
  done
  echo "== hosts (ingresses of the apps and Pomerium routes to their Services)"
  local svcs routes
  svcs=$(for app in $APPS; do app_resources "$app" | awk '$1=="Service"{print $3"."$2".svc"}'; done | sort -u)
  for app in $APPS; do app_resources "$app" | awk '$1=="Ingress"{print $2, $3}' | while read -r ns name; do
    ks -n "$ns" get ingress "$name" -o jsonpath='{range .spec.rules[*]}{.host}{"\n"}{end}'; done; done | sort -u | sed 's/^/   ingress: /'
  routes="$SRC_ROOT/$SRC_ENV/pomerium-routes.yaml"
  if [[ -f "$routes" && -n "$svcs" ]]; then
    yq -o=json -I=0 '.config.routes[]?' "$routes" | jq -r --arg s "$svcs" '($s | split("\n")) as $svc | select(.to as $t | any($svc[]; . as $x | $t | contains("//" + $x + "."))) | .from' \
      | sed 's#^https://##' | sort -u | sed 's/^/   route:   /'
  fi
  if [[ -n "$DBS" ]]; then
    pg_pods
    echo "== databases on $SRC_ENV ($SPG_NS/$SPG_CL)"
    for db in $DBS; do sx psql -XAt -c "select '   ' || datname || '  owner=' || pg_get_userbyid(datdba) || '  ' || pg_size_pretty(pg_database_size(datname)) from pg_database where datname = '$db'"; done
    echo "== target $DST_ENV ($DPG_NS/$DPG_CL) free space for dumps: $(dx df -h /var/lib/postgresql/data | awk 'NR==2{print $4}')"
  fi
}

# ---------------------------------------------------------------------------
registry_login() {  # kubeconfig registry-host
  local u
  u=$(kubectl --kubeconfig "$1" -n harbor get secret harbor-robot-runner -o jsonpath='{.data.username}' | base64 -d)
  kubectl --kubeconfig "$1" -n harbor get secret harbor-robot-runner -o jsonpath='{.data.password}' | base64 -d | docker login "$2" -u "$u" --password-stdin >/dev/null
  kubectl --kubeconfig "$1" -n harbor get secret harbor-robot-runner -o jsonpath='{.data.password}' | base64 -d | helm registry login "$2" -u "$u" --password-stdin >/dev/null 2>&1
}

phase_artifacts() {
  provision::require_tools docker helm
  local images charts app aj path chart
  images=$(for app in $APPS; do pod_specs "$app" | jq -r '.spec | (.containers + (.initContainers // []))[].image'; done | grep "^$SRC_HARBOR/" | sort -u || true)
  # Umbrella charts in the envs repo: the Application path holds a Chart.yaml whose dependencies
  # come from the source Harbor's OCI chart repo.
  charts=$(for app in $APPS; do
    aj=$(app_json "$app"); path=$(jq -r '.spec.source.path // empty' <<<"$aj"); chart="$(dirname "$SRC_ROOT")/$path/Chart.yaml"
    [[ -n "$path" && -f "$chart" ]] && yq -r '.dependencies[]? | select(.repository | test("^oci://")) | .repository + "/" + .name + " " + .version' "$chart"
  done | grep "^oci://$SRC_HARBOR/" | sort -u || true)
  confirm "images:" $images "charts:" ${charts:+"$charts"}
  registry_login "$KS" "$SRC_HARBOR"; registry_login "$KD" "$DST_HARBOR"
  local img dst ref ver tmp rc=0
  for img in $images; do
    dst="$DST_HARBOR/${img#"$SRC_HARBOR"/}"
    # A digest-only reference still needs a tag to push under; the digest itself is preserved, so
    # target values can keep "@sha256:..." with only the registry host changed.
    [[ $dst == *@sha256:* ]] && dst="${dst%@*}:sha256-${dst#*@sha256:}"
    if docker buildx imagetools create -t "$dst" "$img" >/dev/null 2>&1; then log "image $img -> $dst"; else err "image copy failed: $img"; rc=1; fi
  done
  tmp=$(mktemp -d)
  while read -r ref ver; do
    [[ -n "$ref" ]] || continue
    # helm push takes the repository the chart goes into, not the chart's own reference.
    if helm pull "$ref" --version "$ver" -d "$tmp" >/dev/null 2>&1 \
       && helm push "$(ls "$tmp"/*.tgz | head -1)" "oci://$DST_HARBOR/$(dirname "${ref#oci://"$SRC_HARBOR"/}")" >/dev/null 2>&1; then
      log "chart $ref $ver -> $DST_HARBOR"
    else err "chart copy failed: $ref $ver"; rc=1; fi
    rm -f "$tmp"/*.tgz
  done <<<"$charts"
  rm -rf "$tmp"
  return $rc
}

# ---------------------------------------------------------------------------
phase_secrets() {
  local n i from to names
  n=$(p '.secrets | length // 0')
  local desc=()
  for ((i = 0; i < n; i++)); do desc+=("$(p ".secrets[$i].from") -> $(p ".secrets[$i].to"): $(p ".secrets[$i].names | join(\" \")")"); done
  confirm "${desc[@]:-none}" "rewrites: $(p '[.secretRewrites[]? | .namespace + "/" + .secret + "." + .key] | join(" ")')"
  for ((i = 0; i < n; i++)); do
    from=$(p ".secrets[$i].from"); to=$(p ".secrets[$i].to"); names=$(p ".secrets[$i].names[]")
    kd get ns "$to" >/dev/null 2>&1 || kd create ns "$to"
    for s in $names; do
      if kd -n "$to" get secret "$s" >/dev/null 2>&1 \
         && [[ -z "$(kd -n "$to" get secret "$s" -o json | jq -r '.metadata.labels["infra-skills/migrated-from"] // empty')" ]]; then
        # Same name, not ours: an app of the target already owns it. Never overwrite blindly.
        if [[ "$(ks -n "$from" get secret "$s" -o json | jq -cS .data | shasum)" == "$(kd -n "$to" get secret "$s" -o json | jq -cS .data | shasum)" ]]; then
          log "secret $to/$s exists on $DST_ENV with identical data, left alone"
        else err "secret $to/$s exists on $DST_ENV with different data and is not from a migration: skipped"; fi
        continue
      fi
      ks -n "$from" get secret "$s" -o json \
        | jq --arg ns "$to" --arg src "$SRC_ENV" '{apiVersion:"v1", kind:"Secret", type:.type, metadata:{name:.metadata.name, namespace:$ns, labels:{"infra-skills/migrated-from":$src}}, data:.data}' \
        | kd apply -f - >/dev/null && log "secret $from/$s -> $DST_ENV $to/$s"
    done
  done
  n=$(p '.secretRewrites | length // 0')
  for ((i = 0; i < n; i++)); do
    local ns sec key val
    ns=$(p ".secretRewrites[$i].namespace"); sec=$(p ".secretRewrites[$i].secret"); key=$(p ".secretRewrites[$i].key"); val=$(p ".secretRewrites[$i].value")
    kd -n "$ns" patch secret "$sec" --type merge -p "{\"data\":{\"$key\":\"$(printf '%s' "$val" | base64 | tr -d '\n')\"}}" >/dev/null && log "secret $ns/$sec: $key rewritten"
  done
}

# ---------------------------------------------------------------------------
phase_roles() {
  pg_pods
  confirm "owner roles of: $(echo $DBS) (passwords from the plan's passwordFrom secrets on $SRC_ENV)" \
          "NOLOGIN placeholders on $DST_ENV for every other non-system role of $SRC_ENV"
  local db owner ns sec key pw r
  for db in $DBS; do
    owner=$(sx psql -XAt -c "select pg_get_userbyid(datdba) from pg_database where datname = '$db'")
    [[ -n "$owner" ]] || die "database $db not found on $SRC_ENV"
    ns=$(p ".databases[] | select(.name == \"$db\") | .passwordFrom.namespace"); sec=$(p ".databases[] | select(.name == \"$db\") | .passwordFrom.secret"); key=$(p ".databases[] | select(.name == \"$db\") | .passwordFrom.key")
    [[ "$sec" != null ]] || die "database $db: plan has no passwordFrom (the app's password must stay the same)"
    pw=$(ks -n "$ns" get secret "$sec" -o jsonpath="{.data.$key}" | base64 -d | sed "s/'/''/g")
    # The password travels on stdin into psql only; it is never an argument or printed.
    printf "DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '%s') THEN CREATE ROLE \"%s\" LOGIN; END IF; END\$\$;\nALTER ROLE \"%s\" LOGIN PASSWORD '%s';\n" "$owner" "$owner" "$owner" "$pw" \
      | dx psql -X -q -v ON_ERROR_STOP=1 && log "role $owner (owner of $db) ready on $DST_ENV"
    pw=""
  done
  for r in $(sx psql -XAt -c "select rolname from pg_roles where rolname !~ '^pg_' and rolname not in ('postgres', 'streaming_replica') and not rolsuper"); do
    dx psql -XAq -c "DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$r') THEN CREATE ROLE \"$r\" NOLOGIN; END IF; END\$\$"
  done
  log "placeholder roles ensured on $DST_ENV"
}

# ---------------------------------------------------------------------------
copy_small() {  # db: drop, recreate, stream
  local db=$1 owner
  owner=$(sx psql -XAt -c "select pg_get_userbyid(datdba) from pg_database where datname = '$db'")
  dx psql -XAq -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" -c "CREATE DATABASE \"$db\" OWNER \"$owner\""
  sx pg_dump -Fc -d "$db" | dx pg_restore -d "$db" --exit-on-error
  log "$db copied (streamed)"
}

phase_copy() {
  pg_pods
  local small="" big="" db
  for db in $DBS; do if [[ -n "$(db_journal "$db")" ]]; then big="$big $db"; else small="$small $db"; fi; done
  confirm "drop + recreate + stream on $DST_ENV:${small:- none}" \
          "dump into $DST_ENV:$MIG_DIR and restore there (pg_restore -j $JOBS, detached):${big:- none}" \
          "(a running app on $DST_ENV loses its connections to these databases)"
  for db in $small; do copy_small "$db"; done
  for db in $big; do
    log "$db: dumping from $SRC_ENV into $DST_ENV:$MIG_DIR/$db.dump (streams through this machine)"
    dx sh -c "mkdir -p $MIG_DIR && rm -f $MIG_DIR/$db.*"
    sx pg_dump -Fc -Z1 -d "$db" | dx sh -c "cat > $MIG_DIR/$db.dump.partial && mv $MIG_DIR/$db.dump.partial $MIG_DIR/$db.dump"
    log "$db: dump on $DST_ENV ($(dx sh -c "du -h $MIG_DIR/$db.dump | cut -f1")), starting the restore"
    dx psql -XAq -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)"
    dx sh -c "cd $MIG_DIR && PGOPTIONS='-c maintenance_work_mem=1GB -c synchronous_commit=off' nohup sh -c 'pg_restore -j $JOBS --create -d postgres $db.dump > $db.restore.log 2>&1; echo EXIT=\$? >> $db.restore.log' >/dev/null 2>&1 &"
  done
  [[ -z "$big" ]] || info "restores run inside $DST_ENV; follow with: $0 $PLAN status"
}

phase_status() {
  pg_pods
  local db
  for db in $DBS; do
    [[ -n "$(db_journal "$db")" ]] || continue
    echo "== $db: $(dx sh -c "grep -h '^EXIT=' $MIG_DIR/$db.restore.log 2>/dev/null || echo running"), $(dx sh -c "grep -c 'error' $MIG_DIR/$db.restore.log 2>/dev/null || echo 0") error lines"
  done
  dx psql -XAt -c "select '   copy ' || relid::regclass || ' ' || pg_size_pretty(bytes_processed) from pg_stat_progress_copy" \
              -c "select '   index ' || index_relid::regclass || ' ' || phase || ' ' || coalesce(round(100.0 * blocks_done / nullif(blocks_total, 0), 1)::text || '%', '') from pg_stat_progress_create_index"
}

# ---------------------------------------------------------------------------
phase_freeze() {
  [[ ! -f "$STATE" ]] || $FORCE || die "$STATE exists: a second freeze would record zero replicas as the originals. Use rollback, or --force."
  local app parents deps crons
  parents=$(for app in $APPS; do app_json "$app" | jq -r '.metadata.annotations["argocd.argoproj.io/tracking-id"] // empty | split(":")[0]'; done | sort -u)
  deps=$( (for app in $APPS; do app_resources "$app" | awk '$1=="Deployment"{print $2"/"$3}'; done; p '.extraWorkloads[]? | select(test("^Deployment/")) | sub("^Deployment/"; "")') | sort -u)
  crons=$( (for app in $APPS; do app_resources "$app" | awk '$1=="CronJob"{print $2"/"$3}'; done; p '.extraWorkloads[]? | select(test("^CronJob/")) | sub("^CronJob/"; "")') | sort -u)
  # ArgoCD first: an automated sync that fires while the Deployments are at 0 (any pending commit
  # does it) puts them straight back, and the source keeps writing during the delta.
  confirm "ArgoCD auto-sync off: $(echo $APPS $parents)" "scale to 0: $(echo $deps)" "suspend: $(echo $crons)"
  local st='{"applications":{},"deployments":[],"cronjobs":[]}' a x ns name v
  for a in $APPS $parents; do
    st=$(jq --arg a "$a" --argjson sp "$(app_json "$a" | jq '.spec.syncPolicy // {}')" '.applications[$a] = $sp' <<<"$st")
  done
  for x in $deps; do ns=${x%/*}; name=${x#*/}; v=$(ks -n "$ns" get deploy "$name" -o jsonpath='{.spec.replicas}')
    st=$(jq --arg ns "$ns" --arg n "$name" --argjson r "${v:-1}" '.deployments += [{ns:$ns, name:$n, replicas:$r}]' <<<"$st"); done
  for x in $crons; do ns=${x%/*}; name=${x#*/}; v=$(ks -n "$ns" get cronjob "$name" -o jsonpath='{.spec.suspend}')
    st=$(jq --arg ns "$ns" --arg n "$name" --argjson s "${v:-false}" '.cronjobs += [{ns:$ns, name:$n, suspend:$s}]' <<<"$st"); done
  printf '%s\n' "$st" > "$STATE"; log "freeze state saved to $STATE"
  for a in $APPS $parents; do ks -n argocd patch applications.argoproj.io "$a" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null && log "auto-sync off: $a"; done
  for x in $deps; do ks -n "${x%/*}" scale deploy "${x#*/}" --replicas=0 >/dev/null && log "scaled to 0: $x"; done
  for x in $crons; do ks -n "${x%/*}" patch cronjob "${x#*/}" --type merge -p '{"spec":{"suspend":true}}' >/dev/null && log "suspended: $x"; done
  local sel
  for x in $deps; do
    sel=$(ks -n "${x%/*}" get deploy "${x#*/}" -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
    ks -n "${x%/*}" wait --for=delete pod -l "$sel" --timeout=180s >/dev/null 2>&1 || true
    [[ -z "$(ks -n "${x%/*}" get pods -l "$sel" -o name)" ]] || warn "pods of $x are still terminating"
  done
  sleep 5
  for x in $deps; do [[ "$(ks -n "${x%/*}" get deploy "${x#*/}" -o jsonpath='{.spec.replicas}')" == 0 ]] || err "$x is back above 0: something else scales it (HPA, operator, CI deploy)"; done
  if [[ -n "$DBS" ]]; then pg_pods
    sx psql -XAt -c "select '   still connected: ' || datname || ' ' || usename || ' x' || count(*) from pg_stat_activity where datname in ($(for d in $DBS; do printf "'%s'," "$d"; done | sed 's/,$//')) and pid <> pg_backend_pid() group by datname, usename" ; fi
  log "freeze done"
}

phase_rollback() {
  [[ -f "$STATE" ]] || die "no freeze state at $STATE"
  confirm "restore on $SRC_ENV from $STATE: $(jq -r '[.deployments[] | "\(.ns)/\(.name)=\(.replicas)"] | join(" ")' "$STATE")" \
          "and the ArgoCD sync policies of $(jq -r '.applications | keys | join(" ")' "$STATE")"
  jq -c '.deployments[]' "$STATE" | while read -r d; do ks -n "$(jq -r .ns <<<"$d")" scale deploy "$(jq -r .name <<<"$d")" --replicas="$(jq -r .replicas <<<"$d")" >/dev/null && log "restored $(jq -r '.ns + "/" + .name' <<<"$d")"; done
  jq -c '.cronjobs[]' "$STATE" | while read -r c; do ks -n "$(jq -r .ns <<<"$c")" patch cronjob "$(jq -r .name <<<"$c")" --type merge -p "{\"spec\":{\"suspend\":$(jq -r .suspend <<<"$c")}}" >/dev/null; done
  jq -r '.applications | keys[]' "$STATE" | while read -r a; do
    ks -n argocd patch applications.argoproj.io "$a" --type merge -p "{\"spec\":{\"syncPolicy\":$(jq -c --arg a "$a" '.applications[$a]' "$STATE")}}" >/dev/null && log "sync policy restored: $a"
  done
  mv "$STATE" "$STATE.rolled-back.$(date +%s)"
  log "rollback done (DNS: run dns-rollback if it was flipped)"
}

# ---------------------------------------------------------------------------
phase_delta() {
  pg_pods
  confirm "journal databases: rows above (target max ordering - $MARGIN), ON CONFLICT DO NOTHING; every other table, the sequences" \
          "other databases: full re-copy" "volumes: $(p '[.volumes[]? | .source.namespace + "/" + .source.pvc] | join(" ")')" \
          "run this only after 'freeze': the source must have stopped writing"
  local db jt ord wm t
  for db in $DBS; do
    jt=$(db_journal "$db")
    if [[ -z "$jt" ]]; then copy_small "$db"; continue; fi
    ord=$(db_ordering "$db")
    wm=$(dx psql -XAt -d "$db" -c "select coalesce(max($ord), 0) from $jt")
    # The margin covers transactions still in flight when the first dump took its snapshot: they hold
    # orderings below the restored maximum. The journal key makes the overlap harmless.
    log "$db: target max($ord)=$wm, copying $jt rows with $ord > $((wm - MARGIN))"
    sx psql -XAt -d "$db" -c "\\copy (select * from $jt where $ord > $((wm - MARGIN))) to stdout" \
      | dx psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "create temp table mig_delta (like $jt)" -c "\\copy mig_delta from pstdin" \
          -c "insert into $jt select * from mig_delta on conflict do nothing" | tee -a "$LOG"
    for t in $(sx psql -XAt -d "$db" -c "select format('%I.%I', schemaname, relname) from pg_stat_user_tables where relname <> '$jt' order by 1"); do
      # DELETE with triggers off rather than TRUNCATE: a foreign key from another table would make
      # TRUNCATE refuse, and these tables are the small ones.
      sx psql -XAt -d "$db" -c "\\copy $t to stdout" \
        | dx psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "begin" -c "set local session_replication_role = replica" -c "delete from $t" -c "\\copy $t from pstdin" -c "commit" \
        && log "$db: $t re-copied"
    done
    sx psql -XAt -d "$db" -c "select format('select setval(%L, %s, %s);', format('%I.%I', schemaname, sequencename), last_value, 'true') from pg_sequences where last_value is not null" \
      | dx psql -XAq -v ON_ERROR_STOP=1 -d "$db" >/dev/null && log "$db: sequences set"
  done
  copy_volumes
}

helper_pod() {  # kubeconfig ns pvc name readonly
  kubectl --kubeconfig "$1" -n "$2" delete pod "$4" --ignore-not-found --wait=true >/dev/null
  kubectl --kubeconfig "$1" -n "$2" run "$4" --image=busybox:1.37 --restart=Never --overrides="$(jq -nc --arg n "$4" --arg c "$3" --argjson ro "$5" \
    '{spec:{containers:[{name:$n, image:"busybox:1.37", command:["sleep","3600"], stdin:true, volumeMounts:[{name:"d", mountPath:"/data", readOnly:$ro}]}], volumes:[{name:"d", persistentVolumeClaim:{claimName:$c, readOnly:$ro}}]}}')" >/dev/null
  kubectl --kubeconfig "$1" -n "$2" wait --for=condition=Ready "pod/$4" --timeout=180s >/dev/null
}

copy_volumes() {
  local n i sns spvc tns tpvc tsts reps
  n=$(p '.volumes | length // 0')
  for ((i = 0; i < n; i++)); do
    sns=$(p ".volumes[$i].source.namespace"); spvc=$(p ".volumes[$i].source.pvc")
    tns=$(p ".volumes[$i].target.namespace"); tpvc=$(p ".volumes[$i].target.pvc"); tsts=$(p ".volumes[$i].target.statefulset // \"\"")
    reps=0
    if [[ -n "$tsts" ]]; then
      reps=$(kd -n "$tns" get sts "$tsts" -o jsonpath='{.spec.replicas}')
      kd -n "$tns" scale sts "$tsts" --replicas=0 >/dev/null; kd -n "$tns" wait --for=delete "pod/$tsts-0" --timeout=180s >/dev/null 2>&1 || true
    fi
    helper_pod "$KS" "$sns" "$spvc" mig-src true
    helper_pod "$KD" "$tns" "$tpvc" mig-dst false
    ks -n "$sns" exec mig-src -- tar -C /data -cf - . \
      | kd -n "$tns" exec -i mig-dst -- sh -c 'find /data -mindepth 1 -delete && tar -C /data -xpf - && du -sh /data' | tee -a "$LOG"
    ks -n "$sns" delete pod mig-src --wait=false >/dev/null; kd -n "$tns" delete pod mig-dst --wait=false >/dev/null
    [[ -z "$tsts" ]] || kd -n "$tns" scale sts "$tsts" --replicas="$reps" >/dev/null
    log "volume $sns/$spvc -> $DST_ENV $tns/$tpvc"
  done
}

# ---------------------------------------------------------------------------
phase_verify() {
  pg_pods
  # Exact counts, not pg_stat estimates: estimates differ between two copies of the same data.
  local q="select string_agg(t, ' ' order by t) from (select format('%I.%I', table_schema, table_name) || '=' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text t from information_schema.tables where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema')) s"
  local db a b rc=0 jt ord
  for db in $DBS; do
    a=$(sx psql -XAt -d "$db" -c "set max_parallel_workers_per_gather = 4" -c "$q" | tail -1); b=$(dx psql -XAt -d "$db" -c "set max_parallel_workers_per_gather = 4" -c "$q" | tail -1)
    if [[ "$a" == "$b" ]]; then log "$db: all $(wc -w <<<"$a" | tr -d ' ') tables equal"; else
      log "$db: DIFFERENT"; diff <(tr ' ' '\n' <<<"$a") <(tr ' ' '\n' <<<"$b") | grep '^[<>]' | sed "s/^</  $SRC_ENV:/; s/^>/  $DST_ENV:/" | tee -a "$LOG"; rc=1; fi
    jt=$(db_journal "$db"); ord=$(db_ordering "$db")
    if [[ -n "$jt" ]]; then
      a=$(sx psql -XAt -d "$db" -c "select max($ord) from $jt"); b=$(dx psql -XAt -d "$db" -c "select max($ord) from $jt")
      [[ "$a" == "$b" ]] && log "$db: $jt max($ord) equal ($a)" || { log "$db: $jt max($ord) $SRC_ENV=$a $DST_ENV=$b"; rc=1; }
    fi
  done
  return $rc
}

# ---------------------------------------------------------------------------
phase_dns() {
  local ip=$1 hosts h base zid
  hosts=$(p '.hosts[]?')
  [[ -n "$ip" && -n "$hosts" ]] || die "no hosts in the plan, or no EXTERNAL_IP"
  confirm "A records -> $ip (ttl 120, unproxied), explicit per host so a parent wildcard keeps serving the rest:" $hosts
  INFRA_ENVS_ROOT=${CF_ENVS_ROOT:-$SRC_ROOT} provision::cloudflare_read_token || die "no Cloudflare token under ${CF_ENVS_ROOT:-$SRC_ROOT}/shared/secrets.plain/cloudflare.yaml"
  for h in $hosts; do
    base=$(awk -F. '{print $(NF-1)"."$NF}' <<<"$h")
    zid=$(provision::cloudflare_api GET "/zones?name=${base}" | jq -r '.result[0].id // empty')
    [[ -n "$zid" ]] || { err "no Cloudflare zone for $h"; continue; }
    provision::cloudflare_create_or_update_dns_record "$zid" "$h" "$ip" && log "dns $h -> $ip"
  done
}

case "$PHASE" in
  inventory) phase_inventory ;;
  artifacts) phase_artifacts ;;
  secrets) phase_secrets ;;
  roles) phase_roles ;;
  copy) phase_copy ;;
  status) phase_status ;;
  freeze) phase_freeze ;;
  delta) phase_delta ;;
  verify) phase_verify ;;
  dns) phase_dns "$DST_IP" ;;
  dns-rollback) phase_dns "$SRC_IP" ;;
  rollback) phase_rollback ;;
  *) usage; exit 2 ;;
esac
