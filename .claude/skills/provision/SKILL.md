---
name: provision
description: Provision or reprovision a K3s platform environment from scratch on Hetzner bare-metal or Cloud VMs. Use when the user asks about provisioning, reprovisioning, setting up, destroying, or rebuilding an environment.
argument-hint: "[env-name]"
---

# Provisioning Skill

When the user asks to provision or reprovision an environment, follow this sequence. If no
environment name is given, list the directories under the envs root (see CLAUDE.md for how it is
resolved) and ask which one. If the environment config doesn't exist yet, run `/new-env` first.

Throughout this document `<HOSTNAME>` means the base domain from the environment's
`env.properties` — every service host is `<service>.<HOSTNAME>`.

## Before You Start

1. Read `envs/<env>/env.properties` for HOSTNAME, EXTERNAL_IP, VLAN_IP, ACME_EMAIL and
   `UP_OPTIONAL_STEPS` (which optional components this environment runs). If the environment
   has its own `CLAUDE.md`, read it now — its **Post-provision checklist** section (if any) is
   part of the job, see Step 12.
2. Verify prerequisites exist:
   - `envs/<env>/secrets.plain/github-oauth-credentials.yaml` — GitHub OAuth App credentials
     (callback URL `https://dex.<HOSTNAME>/callback`)
   - `envs/shared/secrets.plain/cloudflare.yaml` — Cloudflare API token (DNS)
   - `envs/shared/secrets.plain/github-app-credentials.yaml` — GitHub App for CI runners
   - `envs/shared/secrets.plain/tailscale-api-key.txt` — Tailscale API key (node auth keys are
     minted from it; an expired key stalls the server step after the wipe)
   - SSH key at `~/.ssh/id_ed25519`; SOPS age key at `~/.config/sops/age/keys.txt`
   - Tools: kubectl, helm, sops, age, yq, jq, curl, openssl
   - If any secret file is missing, `/new-env` documents its shape and how to create it.
3. `tools/preflight-local.sh` checks the local toolchain in one go; `tools/validate-keys.sh <env>`
   validates every credential **before** anything destructive runs — always run it ahead of a
   `--wipe`, and do not proceed with a FAIL.
4. `secrets.sops/` is the source of truth; `secrets.plain/` is a working copy that drifts.
   `tools/sops/apply.sh --dry-run <env>` (and `shared`) must print **no WARNING lines** before a
   reprovision — a WARNING means a never-encrypted file or a plaintext value that differs.
   Refresh the working copy with `tools/sops/decrypt.sh --force <env>`.
5. **Reprovisioning an existing environment:** before `--wipe`, list what the server holds that
   exists nowhere else — Nexus hosted repositories (private artifacts), Harbor images, PVC data,
   CI runners other repos depend on — and confirm each is migrated, mirrored, or explicitly
   wipeable. "The app moved" does not mean "its build inputs moved".

## Provisioning Sequence

All commands run from the `infra-skills/` directory. Run them **in order** — each step depends on
the previous ones. Always confirm with the user before executing destructive or remote commands.

> **Orchestrated alternative:** `tools/up.sh <env>` runs Steps 2–9 in order (including the
> runner-image step and a final observability re-apply after redpanda/scylla), resumable — it
> starts with `tools/preflight-cluster.sh <env>` (read-only: node, DNS, 443, pod MTU vs runner
> dockerMTU, Tailscale freshness) and retries a transient step failure once. It
> records completed steps under `~/.local/state/infra-skills/` and continues from the first
> incomplete one on re-run. Optional steps run when the environment lists them in
> `UP_OPTIONAL_STEPS` (or with `--with-optional`). Use the per-script path below when you need to
> explain, customise, or debug a step; use `up.sh` for a straight run. Either way, finish with
> `tools/doctor.sh <env>` — a read-only health and drift check over the whole environment.

### Step 1 — Server Provisioning

Choose based on `env.properties`: if it has `HCLOUD_SERVER_TYPE`, it's a **Cloud** environment;
otherwise **bare-metal**.

#### Option A: Bare-Metal Server
Wipes the server, installs Ubuntu 24.04, sets up LVM-on-RAID1, installs K3s + Tailscale,
configures UFW (only 443/tcp from the Internet).
```bash
tools/provision-hetzner-baremetal.sh <env> --wipe
```
`BASE_OS_IMAGE` in env.properties picks the Hetzner image (default `Ubuntu-2404-noble`; e.g.
`Ubuntu-2604-resolute` for 26.04 LTS — the postinstall follows the installed release). For an
environment that will be wiped and rebuilt often, set `ACME_STAGING=true` so certificate
re-issuance does not hit Let's Encrypt's duplicate limit (5 per week per name set).

**WARNING:** `--wipe` is destructive — it reinstalls the OS. `tools/validate-keys.sh` prints the
server's Robot name, product and datacenter: read them back to the user and get an explicit yes
before running. A server whose Robot name is another environment's hostname is a red flag, not
a formality.

#### Option B: Hetzner Cloud VM
Creates a Cloud VM via the Hetzner Cloud API, attaches it to a Cloud Network, sets up Tailscale
for admin SSH, and runs postinstall (K3s, UFW, etc.).
```bash
tools/provision-hetzner-cloud.sh <env>                      # Full lifecycle: create + provision
tools/provision-hetzner-cloud.sh <env> --create-server      # Create server only
tools/provision-hetzner-cloud.sh <env> --provision-only     # Provision existing server
tools/provision-hetzner-cloud.sh <env> --destroy            # Tear down (server + Tailscale + DNS)
```
Requires `envs/shared/secrets.plain/hetzner-cloud-token.txt`. **`--destroy`** removes the server,
the Tailscale device, and the Cloudflare DNS records — confirm with the user first.

Both options write `envs/<env>/kubeconfig.yaml` with the Tailscale IP as the API server address.

#### Worker nodes (optional)
An environment may have worker directories `envs/<env>/<worker>/env.properties` with
`MASTER_VLAN_IP` / `MASTER_HOSTNAME` (and `NODE_LABELS`, `NODE_TAINTS`, `REGISTRY_HOSTS` for
special nodes such as a GPU box). Join them after the master is up — and again after any
reprovision, since the cluster CA and node token are new:
```bash
tools/k3s/join-worker.sh <env> <worker>
```

### Step 2 — Identity (cert-manager + Dex + Pomerium)
Must run first among the K3s scripts — cert-manager and Dex are dependencies for everything else.
```bash
tools/k3s/identity.sh <env>
```
Provisions cert-manager for TLS, the Dex OIDC provider with GitHub OAuth, and the Pomerium auth
proxy with routes from `pomerium-routes.yaml`.

### Step 3 — Environment secrets
Applications synced by ArgoCD (Step 6) reference the Secrets committed in `envs/<env>/secrets.sops/`;
without them their pods never start. Apply the committed set now (missing namespaces are
created; Helm and ArgoCD adopt them later):
```bash
tools/sops/apply.sh <env>          # decrypts secrets.sops and applies it to the current context
```
Verify the kubectl context first — `apply.sh` targets whatever context is current. Use
`--dry-run` to preview; `--plain` only for a secret you just wrote and have not encrypted yet.

### Step 4 — Harbor (container registry)
Must run before the GitHub Actions runners, since runners push images to Harbor.
```bash
tools/k3s/harbor.sh <env>
```
Harbor with Dex SSO and a Docker Hub proxy cache, at `harbor.<HOSTNAME>`. Creates a robot account
for CI/CD. After a reprovision Harbor is **empty**: every application image must be rebuilt by
its repository's CI (Step 10) before ArgoCD can start it.

### Step 5 — Harbor Credentials + GitHub Actions Runners
The custom runner image is built by **your envs repo**, through a thin caller workflow that
runs the public reusable `build-runner-image.yml` on your own runners (`/new-env` scaffolds it;
template in `docs/examples/envs-repo/build-runner-image.yml`). Push Harbor credentials to that
repo **before** bootstrapping runners, so the build can push to Harbor.

```bash
# 5a. Runners on the vanilla image (the script falls back to it while Harbor has no custom image)
tools/k3s/github-action-runner.sh <env>

# 5b. Everything else in one step: Harbor creds -> envs repo, dispatch the caller workflow with
#     environment + base_domain, wait for the push, switch the RunnerDeployment to the image.
tools/k3s/runner-image.sh <env>            # --rebuild to force a new build, --skip-build to only switch
```

```bash
# 5c. Runtime base image for JVM services: library/teob-base (Temurin 25 JRE + Node 22 +
#     Claude Code CLI, images/teob-base). Applications set dockerBaseImage / FROM to
#     harbor.<base_domain>/library/teob-base:latest. Same mechanics as 5b via the caller
#     workflow build-teob-base-image.yml in the envs repo.
tools/k3s/base-image.sh <env>              # --rebuild to force a new build
```

By hand, 5b is: `tools/k3s/registry-credentials.sh <env> <envs-repo-name>`, then
`gh workflow run build-runner-image.yml -R <org>/<envs-repo-name> -f environment=<env>
-f base_domain=<base-domain>` (both inputs required), wait (10–15 min), then
`tools/k3s/github-action-runner.sh <env>` again. A build whose large downloads stall or reset
is an MTU problem (see Troubleshooting), not a CDN problem.

The script auto-detects the custom image in Harbor and switches runners from vanilla to custom,
deleting the bootstrap deployment so GitHub can't schedule jobs on the vanilla runner. Runner
labels are `self-hosted` + the environment name; any workflow with `runs-on: [self-hosted, <env>]`
queues while this environment is down.

### Step 6 — ArgoCD (GitOps)
Required — application manifests in `envs/<env>/apps/` are ArgoCD Applications.
```bash
tools/k3s/argocd.sh <env>
```
The GitOps repo URL defaults to `https://github.com/<your-github-org>/infra-envs.git` (org taken
from `github-oauth-credentials.yaml`). Override with `GITOPS_REPO_URL` in `env.properties` (or a
`REPO_URL` environment variable) if your envs repo is named or hosted differently.

### Step 7 — Observability + MySQL (independent, any order)

```bash
tools/k3s/observability.sh <env>    # Prometheus + Loki + Grafana (GitHub SSO), grafana.<HOSTNAME>
tools/k3s/mysql.sh <env>            # Percona MySQL operator + Adminer, adminer.<HOSTNAME>
```
The MySQL cluster may take 1–2 minutes to become ready after the script completes. Alert groups
come from `envs/shared/alerts/` and `envs/<env>/alerts/`; `POSTGRES_SIZE_ALERT_EXCLUDE` in
`env.properties` keeps by-design-growing databases out of the generic size alert.

### Step 8 — Databases and VPN (optional)

**PostgreSQL** (CloudNativePG + pgweb):
```bash
tools/k3s/postgres.sh <env>
```
pgweb at `pgweb.<HOSTNAME>`. Supports `--provision-credentials <app-id>` for per-app DB users.

**Redpanda + ScyllaDB** (Kafka-style journal persistence stack) — only for environments running
apps that need it:
```bash
tools/k3s/redpanda.sh <env>      # Redpanda operator + single broker (Kafka API, SASL/SCRAM)
tools/k3s/scylla.sh <env>        # Scylla operator + single node (Cassandra API, password auth)
```
Both use static local PVs under `/data` pinned to the main node, and support `--watch` and
`--provision-credentials <app-id>`; `scylla.sh --snapshot-now` is the backup primitive. After
first install, rerun `tools/k3s/observability.sh <env>` to load their scrape jobs and alerts.

**WireGuard** (wg-portal VPN with web management) — only if the environment has a `wg.<HOSTNAME>`
route and a `wg-portal-secrets` secret:
```bash
tools/k3s/wireguard.sh <env>
```

### Step 9 — Nexus (artifact repository, optional)
```bash
tools/k3s/nexus.sh <env>
```
A reprovisioned Nexus is empty. Private artifacts that were hosted only here (see Before You
Start, item 5) must be re-uploaded from the mirror taken before the wipe.

### Step 10 — Registry Credentials for App Repos
Push Harbor (and Nexus, if provisioned) robot credentials as GitHub environment secrets — once
per application repository that deploys to this environment. Without this, CI can't push images.
Then trigger each repository's CI so Harbor is populated again.
```bash
tools/k3s/registry-credentials.sh <env> <github-repo-name>
```

### Step 11 — Sync GitHub Org Secrets + host backups
```bash
tools/k3s/provision-org-secrets.sh <env>
tools/backup.sh <env>              # nightly rdiff-backup of /data to your backup host (BACKUP_* in env.properties)
tools/backup.sh <env> --run-now    # first run, then verify on the backup host
```

### Step 12 — Environment-specific post-provision items
Anything the generic stack does not cover lives in the environment's own `CLAUDE.md` under
**Post-provision checklist** (hand-applied manifests, artifact re-uploads, per-app credentials,
worker rejoin, external cutovers). Read it and work through it item by item; if the environment
has no such section and you had to do something by hand, add it there — the next reprovision
should not rediscover it.

### Final Validation

```bash
tools/doctor.sh <env>                # read-only health + drift check; aim for no CRIT
kubectl get nodes                    # Node ready
kubectl get pods -A                  # All pods running
curl -sS -o /dev/null -w "%{http_code}" https://dex.<HOSTNAME>/.well-known/openid-configuration
curl -sS -o /dev/null -w "%{http_code}" https://harbor.<HOSTNAME>/api/v2.0/health
curl -sS -o /dev/null -w "%{http_code}" https://argocd.<HOSTNAME>
curl -sS -o /dev/null -w "%{http_code}" https://grafana.<HOSTNAME>/api/health
```

## Troubleshooting

- **Helm repo errors** (stale repos): `helm repo remove <name>` and retry.
- **Let's Encrypt rate limits** after repeated rebuilds (`too many certificates already issued`):
  set `ACME_STAGING=true` for the throwaway environment, or wait for the weekly window.
- **doctor.sh WARN alerting**: placeholder Alertmanager secrets are in place; nothing is
  delivered until the real ones are applied (templates in `new-env`).
- **A step died mid-Helm** (wait timeout, `http2: client connection lost` over Tailscale): check
  `helm -n <ns> status <release>`. A first install left in `failed` state must be
  `helm -n <ns> uninstall <release>` before `up.sh` can resume that step; a transient API loss
  needs nothing but a re-run (`up.sh` resumes from the checkpoint).
- **kubectl context mismatch**: all scripts validate the context matches the target env. Check
  `envs/<env>/kubeconfig.yaml` and `~/.kube/config`.
- **Secrets**: plaintext lives in `secrets.plain/` (gitignored, never committed); encrypted
  copies in `secrets.sops/` are the truth. Manage with `tools/sops/encrypt.sh` / `decrypt.sh` /
  `apply.sh`. `apply.sh` uses the **current kubectl context** — verify it before applying.
- **Apps not deploying**: ArgoCD auto-syncs manifests from `envs/<env>/apps/`. If images aren't
  in Harbor yet, trigger the app's CI workflow first. If a pod waits on a Secret, Step 3 was
  skipped or the secret was never encrypted (`apply.sh --dry-run` reports it).
- **Tailscale/SSH issues after a wipe**: the script cleans stale Tailscale devices; if SSH hangs,
  check for duplicate devices in the Tailscale admin console. If "Waiting for SSH on <tailscale-ip>"
  never returns, the tailnet SSH policy is in `check` mode (browser re-auth per session): change the
  rule's action to `accept` in Access controls; the script detects this and fails fast, and
  `validate-keys.sh` reports it before a wipe.
- **installimage "Image not found"**: Hetzner renames rescue images (`.tar.gz` → `.tar.zst` in
  2026); the script resolves the Ubuntu 24.04 image at run time and lists what is available on failure. A worker that will not rejoin after
  a reprovision needs `join-worker.sh` again — the old node token is invalid.
- **A CI job dies mid-step with no log on GitHub** (job shows the step still "in progress",
  `gh api .../logs` returns BlobNotFound): the runner container was OOM-killed — `dmesg -T | grep
  oom` on the node names the process. JVM builds need more than the heap: raise
  `RUNNER_MEMORY_LIMIT` (default 16Gi) in env.properties and re-run `tools/k3s/github-action-runner.sh`.
- **Image builds on the runners stall on large downloads** (`Connection reset by peer`, CDN
  timeouts, while small requests work): MTU. Pods sit at flannel's MTU (1230 over Tailscale) and
  dockerd inside the runner pod defaults to 1500. The runner script sets ARC `dockerMTU` from a
  probe; for an existing deployment: `kubectl -n actions-runner-system patch runnerdeployment
  <env>-runners --type merge -p '{"spec":{"template":{"spec":{"dockerMTU":1230}}}}'`.
- **Runner image not detected**: the script checks Harbor via API; if the image exists but isn't
  found, check Harbor API connectivity and the robot account credentials.

## Multiple GitHub Orgs

To run an environment under a different GitHub org than your main one:

- The new org needs its **own envs repo** (may bundle infra-skills as a Git submodule, with
  `INFRA_ENVS_ROOT` set via direnv), its **own GitHub App** (same permissions as in `/new-env`),
  and its **own OAuth App** for Dex.
- infra-skills is public, so the new org needs nothing private from the original one: its envs
  repo carries the same thin `build-runner-image.yml` caller (Step 5), and its app repos call the
  public reusable workflows with `base_domain` set to that environment's domain. Only `gitops_repo`
  needs passing when the envs repo is not `<org>/infra-envs`.
- If builds must resolve artifacts from another environment's Nexus, create an authenticated
  proxy repository in the local Nexus pointing at the source Nexus `maven-public` group, add it
  to the local `maven-public` group, and whitelist the new server's outbound IPs (IPv4 **and**
  IPv6 — Hetzner servers often prefer IPv6 outbound) on the source side.
