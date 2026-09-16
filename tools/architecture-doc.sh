#!/usr/bin/env bash
# ============================================================================
# architecture-doc — write docs/ARCHITECTURE.md in the envs repo from live state
# ============================================================================
# The handover document of the onboard skill (Step 5). Everything in it comes from the
# cluster, the env config, Hetzner Robot and doctor.sh — nothing is assumed. Re-run after
# material changes; review the result and add what only a human knows (cost, on-call).
#
# Usage: tools/architecture-doc.sh <env> [output-path]
#   default output: <envs-repo>/docs/ARCHITECTURE.md
# Read-only towards the cluster. Requires kubectl, helm, jq, yq, curl.
# shellcheck disable=SC1091
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/tools/provision-common.sh"
[[ -n "${1:-}" ]] || { echo "Usage: $0 <env> [output-path]" >&2; exit 2; }
provision::load_env "$1" || { provision::error "Environment '$1' not found"; exit 2; }
provision::validate_kubectl_context || exit 2
if ! kubectl --request-timeout=10s get --raw='/livez' >/dev/null 2>&1; then
  provision::error "Kubernetes API unreachable — refusing to write a document from empty state."
  provision::error "Is your Tailscale client connected? (tailscale status)"
  exit 2
fi
ENVS_ROOT="$(provision::envs_root)"
OUT="${2:-$(cd "$ENVS_ROOT/.." && pwd)/docs/ARCHITECTURE.md}"
mkdir -p "$(dirname "$OUT")"
kc() { kubectl --request-timeout=20s "$@" 2>/dev/null; }
TODAY="$(date +%Y-%m-%d)"

# --- Gather ------------------------------------------------------------------
provision::github_read_credentials >/dev/null 2>&1 || true
ORG="${GITHUB_ORG:-<github-org>}"
GITOPS="${GITOPS_REPO_URL:-https://github.com/${ORG}/infra-envs.git}"
NODE_JSON="$(kc get nodes -o json)"
NODE_NAME="$(jq -r '.items[0].metadata.name' <<<"$NODE_JSON")"
NODE_COUNT="$(jq -r '.items | length' <<<"$NODE_JSON")"
K8S_VER="$(jq -r '.items[0].status.nodeInfo.kubeletVersion' <<<"$NODE_JSON")"
OS_IMG="$(jq -r '.items[0].status.nodeInfo.osImage' <<<"$NODE_JSON")"
KERNEL="$(jq -r '.items[0].status.nodeInfo.kernelVersion' <<<"$NODE_JSON")"
CRI="$(jq -r '.items[0].status.nodeInfo.containerRuntimeVersion' <<<"$NODE_JSON")"
CPU="$(jq -r '.items[0].status.capacity.cpu' <<<"$NODE_JSON")"
MEM_GI="$(jq -r '.items[0].status.capacity.memory' <<<"$NODE_JSON" | sed 's/Ki//' | awk '{printf "%d", $1/1048576}')"
INTERNAL_IP="$(jq -r '.items[0].status.addresses[] | select(.type=="InternalIP") | .address' <<<"$NODE_JSON" | head -1)"
API_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"

# Hetzner Robot record (bare-metal only)
ROBOT_LINE=""
rf="${ENVS_ROOT}/shared/secrets.plain/hetzner-webservice-user.txt"
if [[ -n "${EXTERNAL_IP:-}" && -f "$rf" && -z "${HCLOUD_SERVER_TYPE:-}" ]]; then
  l1=$(sed -n 1p "$rf" | tr -d '\r\n'); l2=$(sed -n 2p "$rf" | tr -d '\r\n')
  if [[ "$l1" == *:* ]]; then cred="$l1"; else cred="${l1}:${l2}"; fi
  ROBOT_LINE="$(curl -sS -m 15 -u "$cred" "https://robot-ws.your-server.de/server/${EXTERNAL_IP}" 2>/dev/null \
    | jq -r '.server | "Hetzner bare-metal **\(.product)**, datacenter **\(.dc)**, Robot name `\(.server_name)`"' 2>/dev/null)"
fi
[[ -n "$ROBOT_LINE" ]] || ROBOT_LINE="${HCLOUD_SERVER_TYPE:+Hetzner Cloud **${HCLOUD_SERVER_TYPE}** in ${HCLOUD_LOCATION:-?}}"
[[ -n "$ROBOT_LINE" ]] || ROBOT_LINE="(server record unavailable — no Robot credentials decrypted)"

# Helm inventory: release|namespace|chart|app_version
HELM="$(helm list -A -o json 2>/dev/null | jq -r '.[] | "\(.name)|\(.namespace)|\(.chart)|\(.app_version)"' | sort)"
# Hosts: ingress + pomerium routes
INGRESS_HOSTS="$(kc get ingress -A -o json | jq -r '.items[] | .spec.rules[]?.host as $h | "\(.metadata.namespace)|\(.metadata.name)|\($h)"' | sort -u)"
ROUTES_FILE="${ENVS_ROOT}/${ENV_NAME}/pomerium-routes.yaml"
ROUTES="$( [[ -f "$ROUTES_FILE" ]] && yq -r '.config.routes[] | "\(.from)|\(.to)"' "$ROUTES_FILE" 2>/dev/null )"
PVCS="$(kc get pvc -A -o json | jq -r '.items[] | "\(.metadata.namespace)|\(.metadata.name)|\(.spec.resources.requests.storage)|\(.spec.storageClassName)"' | sort)"
ARGO_APPS="$(kc get applications -n argocd -o json | jq -r '.items[] | "\(.metadata.name)|\(.status.sync.status)|\(.status.health.status)"')"
RUNNER_IMG="$(kc get runnerdeployment -n actions-runner-system "${ENV_NAME}-runners" -o jsonpath='{.spec.template.spec.image}')"
RUNNER_REPLICAS="$(kc get runnerdeployment -n actions-runner-system "${ENV_NAME}-runners" -o jsonpath='{.spec.replicas}')"
RUNNER_MTU="$(kc get runnerdeployment -n actions-runner-system "${ENV_NAME}-runners" -o jsonpath='{.spec.template.spec.dockerMTU}')"
CERT_COUNT="$(kc get certificates -A --no-headers | wc -l | tr -d ' ')"
PLACEHOLDERS="$(kc get secrets -A -l infra-skills/placeholder=true -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}')"
AGE_RECIPIENT="$(grep -o 'age1[a-z0-9]*' "$(cd "$ENVS_ROOT/.." && pwd)/.sops.yaml" 2>/dev/null | head -1)"
SOPS_FILES="$(cd "$ENVS_ROOT/.." && find envs -path '*secrets.sops*' -type f | sort)"
ACME="$( [[ "${ACME_STAGING:-false}" == "true" ]] && echo "Let's Encrypt **staging** (untrusted)" || echo "Let's Encrypt production" )"
UFW_LINE="Inbound from the Internet: 443/tcp only (UFW). Everything on the Tailscale interface; cluster CNI ranges."
# doctor output (read-only)
DOCTOR="$("$REPO_ROOT/tools/doctor.sh" "$ENV_NAME" 2>/dev/null | grep -E '^\s*\[(OK|WARN|CRIT|SKIP|UNKN)' | sed 's/^\s*//')"

# --- Helpers to render tables ------------------------------------------------
endpoint_for() {
  # endpoint_for <release-name> -> best-effort URL from ingress hosts / routes
  local n="$1" h
  case "$n" in
    dex) h="dex" ;; harbor) h="harbor" ;; argocd) h="argocd" ;; grafana) h="grafana" ;;
    pomerium) h="auth" ;; cnpg) h="pgweb" ;; ps-operator) h="adminer" ;; redpanda-operator) h="console" ;;
    scylla-operator) h="cassandra" ;; nexus) h="nexus-api" ;; *) h="" ;;
  esac
  [[ -n "$h" ]] && echo "https://${h}.${HOSTNAME}" || echo "in-cluster"
}

# --- Render ------------------------------------------------------------------
{
cat <<MD
# Architecture — \`${ENV_NAME}\` environment (${ORG})

Generated from live state on ${TODAY} by \`tools/architecture-doc.sh ${ENV_NAME}\`. Regenerate after
material changes; nothing here is assumed. Human-only facts (cost, on-call) go in the marked slots.

## 1. Overview

| | |
|---|---|
| Organisation | **${ORG}** (GitHub org; SSO authority) |
| Environment | \`${ENV_NAME}\` |
| Base domain | \`${HOSTNAME}\` (DNS on Cloudflare: \`A\` + wildcard \`A\` → server) |
| Server | ${ROBOT_LINE} |
| Public IPv4 | \`${EXTERNAL_IP:-?}\` (443/tcp only) |
| Admin address | \`${INTERNAL_IP}\` (Tailscale; SSH and Kubernetes API) |
| OS / kernel | ${OS_IMG}, kernel ${KERNEL} |
| Kubernetes | K3s ${K8S_VER}, ${CRI}, ${NODE_COUNT} node(s) (\`${NODE_NAME}\`) |
| Capacity | ${CPU} vCPU, ${MEM_GI} GiB RAM |
| Certificates | ${ACME}, ${CERT_COUNT} issued |
| Generated | ${TODAY} |
| Monthly cost | _fill in: provider list price, billed to ${ORG}_ |

## 2. Topology

\`\`\`mermaid
flowchart LR
  U[Browser / CI] -->|DNS *.${HOSTNAME}| CF[Cloudflare DNS]
  CF -->|443/tcp only| T[Traefik + cert-manager TLS<br/>DNS-01 via Cloudflare]
  T --> P[Pomerium auth proxy]
  T --> H[Harbor]
  T --> D[Dex OIDC]
  T --> G[Grafana]
  P -->|GitHub org login via Dex| A[ArgoCD and admin UIs]
  D <-->|OAuth App| GH[(GitHub ${ORG})]
  OPS[Operator] -->|Tailscale SSH + kubectl| N[(${NODE_NAME}<br/>${INTERNAL_IP})]
\`\`\`

Delivery loop:

\`\`\`mermaid
flowchart LR
  DEV[git push] --> GHA[GitHub Actions<br/>self-hosted runners in cluster<br/>labels: self-hosted, linux, x64, ${ENV_NAME}]
  GHA -->|docker push| HB[Harbor<br/>harbor.${HOSTNAME}/library]
  GHA -->|version bump| ENVS[(${GITOPS}<br/>envs/${ENV_NAME}/apps/)]
  ENVS -->|auto-sync| ACD[ArgoCD]
  ACD --> K8S[(K3s)]
  K8S -->|pull| HB
\`\`\`

## 3. Component inventory (\`helm list -A\`)

| Release | Namespace | Chart | App version | Endpoint |
|---|---|---|---|---|
MD
while IFS='|' read -r n ns chart ver; do
  [[ -n "$n" ]] && printf '| %s | %s | %s | %s | %s |\n' "$n" "$ns" "$chart" "$ver" "$(endpoint_for "$n")"
done <<<"$HELM"
cat <<MD

Runners: RunnerDeployment \`${ENV_NAME}-runners\`, ${RUNNER_REPLICAS:-?} replica(s), image \`${RUNNER_IMG:-?}\`, dockerd MTU ${RUNNER_MTU:-unset}.

Hosts served (ingress objects):

| Namespace | Ingress | Host |
|---|---|---|
MD
while IFS='|' read -r ns name host; do [[ -n "$host" ]] && printf '| %s | %s | https://%s |\n' "$ns" "$name" "$host"; done <<<"$INGRESS_HOSTS"
cat <<MD

Pomerium routes (\`envs/${ENV_NAME}/pomerium-routes.yaml\`): $(printf '%s' "$ROUTES" | cut -d'|' -f1 | sed 's#https://##' | paste -sd ', ' -)

Persistent volumes (\`local-path\` on the node's disk; no off-node replication):

| Namespace | Claim | Size |
|---|---|---|
MD
while IFS='|' read -r ns name size sc; do [[ -n "$name" ]] && printf '| %s | %s | %s |\n' "$ns" "$name" "$size"; done <<<"$PVCS"
cat <<MD

## 4. Access model

- **Login**: members of the GitHub org **${ORG}** via the OAuth App for \`https://dex.${HOSTNAME}/callback\`.
  Dex issues OIDC tokens; Pomerium fronts the admin UIs; ArgoCD, Harbor and Grafana run their own
  Dex-backed login and RBAC on top.
- **Kubernetes API**: \`${API_SERVER}\`, Tailscale only. Kubeconfig: \`envs/${ENV_NAME}/kubeconfig.yaml\`
  (gitignored), merged locally as context \`${ENV_NAME}\`.
- **SSH**: Tailscale SSH on \`${INTERNAL_IP}\` (tailnet policy must have an \`accept\` rule); OpenSSH root
  login disabled; port 22 closed on the public interface.
- **Exposure**: ${UFW_LINE}
- **Pod networking**: flannel over the Tailscale interface; nested networks (docker-in-docker in the
  runners) must use the pod MTU or large transfers stall.
- **CI**: GitHub App installed on the org registers runners and writes repo contents, secrets and
  environments. Harbor robot credentials live as GitHub environment secrets (\`HARBOR_USERNAME\`,
  \`HARBOR_PASSWORD\`, environment \`${ENV_NAME}\`) in the envs repo.
- **GitOps**: ArgoCD apps: $(printf '%s' "$ARGO_APPS" | awk -F'|' '{printf "%s (%s/%s) ", $1, $2, $3}')

## 5. Secrets inventory (names and locations only)

SOPS + age; recipient \`${AGE_RECIPIENT:-?}\` (\`.sops.yaml\` at the envs repo root). The private key
lives only in the operator's \`~/.config/sops/age/keys.txt\`. \`**/secrets.plain/\` and the kubeconfig
are gitignored.

| File | Contents |
|---|---|
MD
while read -r f; do
  case "$(basename "$f")" in
    cloudflare.yaml) d="Cloudflare API token (DNS edit, one zone)" ;;
    github-app-credentials.yaml) d="GitHub App: app id, installation id, private key" ;;
    hetzner-webservice-user.txt) d="Hetzner Robot webservice user (rescue / reinstall — highly privileged)" ;;
    hetzner-cloud-token.txt) d="Hetzner Cloud API token" ;;
    tailscale-api-key.txt) d="Tailscale API key (mints node auth keys; max 90-day lifetime)" ;;
    github-oauth-credentials.yaml) d="GitHub OAuth App for Dex (client id + secret)" ;;
    resend-api-key.yaml) d="SMTP relay key for Alertmanager email" ;;
    alertmanager-telegram.yaml) d="Telegram bot token + chat id for Alertmanager" ;;
    *) d="" ;;
  esac
  [[ -n "$f" ]] && printf '| `%s` | %s |\n' "$f" "$d"
done <<<"$SOPS_FILES"
cat <<MD

In-cluster only (created by the scripts): Harbor admin/robot accounts, ArgoCD admin and Dex client
secrets, database superuser passwords${PLACEHOLDERS:+, and **placeholder** Alertmanager secrets (${PLACEHOLDERS% }) — alert delivery is not configured}.

## 6. Day-2: what is NOT done, and who owns it

You do. \`tools/doctor.sh ${ENV_NAME}\` on ${TODAY}:

\`\`\`
${DOCTOR}
\`\`\`

| Gap | What to do |
|---|---|
| Database backups | CNPG \`ScheduledBackup\` to off-node object storage, a MySQL dump CronJob, \`scylla.sh --snapshot-now\` on a schedule; then a restore drill. \`tools/backup.sh\` for host-level rdiff-backup. |
| Alert delivery | Apply real SMTP and Telegram secrets (templates in the \`new-env\` skill), re-run \`tools/k3s/observability.sh ${ENV_NAME}\`. |
| Image scanning | Harbor's Trivy scans the registry; add trivy-operator for in-cluster CVE exposure. |
| Upgrade cadence | Chart versions are pinned in the scripts; upgrades are your decision and your test. |
| Tailscale API key | Needed only for (re)provisioning; rotate before it expires (doctor warns at 14 days). |
| Single node | A hardware failure takes everything down until restore. Workers: \`tools/k3s/join-worker.sh\`. |
| Certificates | Repeated rebuilds of the same hostnames hit Let's Encrypt limits; \`ACME_STAGING=true\` for throwaway envs. |

Maintained/commercial path (continuous reconciliation, tested upgrade bundles, restore drills,
managed scanning): https://pragmasoft.nl. Everything above keeps working without it.

## 7. Next steps

1. First service: an ArgoCD \`Application\` under \`envs/${ENV_NAME}/apps/\`; ArgoCD auto-syncs.
   Walkthrough: infra-skills \`docs/GITOPS.md\`.
2. Registry access for an app repo: \`tools/k3s/registry-credentials.sh ${ENV_NAME} <repo-name>\`.
3. Per-app database users: \`tools/k3s/postgres.sh ${ENV_NAME} --provision-credentials <app-id>\`.
4. Routine smoke test: \`tools/doctor.sh ${ENV_NAME}\`.

## Daily URLs

- ArgoCD — https://argocd.${HOSTNAME}
- Grafana — https://grafana.${HOSTNAME}
- Harbor — https://harbor.${HOSTNAME}
MD
} > "$OUT"
provision::info "wrote ${OUT} ($(wc -l < "$OUT" | tr -d ' ') lines)"
