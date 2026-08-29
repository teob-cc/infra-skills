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

1. Read `envs/<env>/env.properties` for HOSTNAME, EXTERNAL_IP, VLAN_IP, ACME_EMAIL. If the
   environment has its own `CLAUDE.md`, read that too.
2. Verify prerequisites exist:
   - `envs/<env>/secrets.plain/github-oauth-credentials.yaml` — GitHub OAuth App credentials
     (callback URL `https://dex.<HOSTNAME>/callback`)
   - `envs/shared/secrets.plain/cloudflare.yaml` — Cloudflare API token (DNS)
   - `envs/shared/secrets.plain/github-app-credentials.yaml` — GitHub App for CI runners
   - SSH key at `~/.ssh/id_ed25519`; SOPS age key at `~/.config/sops/age/keys.txt`
   - Tools: kubectl, helm, sops, age, yq, jq, curl, openssl
   - If any secret file is missing, `/new-env` documents its shape and how to create it.
3. `tools/preflight-local.sh` checks the local toolchain in one go; `tools/validate-keys.sh <env>`
   validates every credential **before** anything destructive runs — always run it ahead of a
   `--wipe`.

## Provisioning Sequence

All commands run from the `infra-skills/` directory. Run them **in order** — each step depends on
the previous ones. Always confirm with the user before executing destructive or remote commands.

> **Orchestrated alternative:** `tools/up.sh <env>` runs this same sequence in order, resumable —
> it records completed steps under `~/.local/state/infra-skills/` and continues from the first
> incomplete one on re-run. Use the per-script path below when you need to explain, customise, or
> debug a step; use `up.sh` for a straight run. Either way, finish with `tools/doctor.sh <env>` —
> a read-only health and drift check over the whole environment.

### Step 1 — Server Provisioning

Choose based on `env.properties`: if it has `HCLOUD_SERVER_TYPE`, it's a **Cloud** environment;
otherwise **bare-metal**.

#### Option A: Bare-Metal Server
Wipes the server, installs Ubuntu 24.04, sets up LVM-on-RAID1, installs K3s + Tailscale,
configures UFW (only 443/tcp from the Internet).
```bash
tools/provision-hetzner-baremetal.sh <env> --wipe
```
**WARNING:** `--wipe` is destructive — it reinstalls the OS. Confirm the target IP with the user
before running.

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

### Step 2 — Identity (cert-manager + Dex + Pomerium)
Must run first among the K3s scripts — cert-manager and Dex are dependencies for everything else.
```bash
tools/k3s/identity.sh <env>
```
Provisions cert-manager for TLS, the Dex OIDC provider with GitHub OAuth, and the Pomerium auth
proxy with routes from `pomerium-routes.yaml`.

### Step 3 — Harbor (container registry)
Must run before the GitHub Actions runners, since runners push images to Harbor.
```bash
tools/k3s/harbor.sh <env>
```
Harbor with Dex SSO and a Docker Hub proxy cache, at `harbor.<HOSTNAME>`. Creates a robot account
for CI/CD.

### Step 4 — Harbor Credentials + GitHub Actions Runners
Push Harbor credentials **before** bootstrapping runners, so the runner image build workflow can
push to Harbor.

```bash
# 4a. Push Harbor credentials to the repo that builds the runner image
tools/k3s/registry-credentials.sh <env> <infra-repo-name>

# 4b. Bootstrap with the vanilla runner image
tools/k3s/github-action-runner.sh <env> --bootstrap

# 4c. Build the custom runner image (build-runner-image.yml workflow), then upgrade:
gh workflow run build-runner-image.yml -R <org>/<infra-repo-name> -f environment=<env>
# Wait for it to complete (~5 minutes), then:
tools/k3s/github-action-runner.sh <env>
```

The script auto-detects the custom image in Harbor and switches runners from vanilla to custom,
deleting the bootstrap deployment so GitHub can't schedule jobs on the vanilla runner.

### Step 5 — ArgoCD (GitOps)
Required — application manifests in `envs/<env>/apps/` are ArgoCD Applications.
```bash
tools/k3s/argocd.sh <env>
```
The GitOps repo URL defaults to `https://github.com/<your-github-org>/infra-envs.git` (org taken
from `github-oauth-credentials.yaml`). Override with `GITOPS_REPO_URL` in `env.properties` (or a
`REPO_URL` environment variable) if your envs repo is named or hosted differently.

### Step 6 — Observability + MySQL (independent, any order)

```bash
tools/k3s/observability.sh <env>    # Prometheus + Loki + Grafana (GitHub SSO), grafana.<HOSTNAME>
tools/k3s/mysql.sh <env>            # Percona MySQL operator + Adminer, adminer.<HOSTNAME>
```
The MySQL cluster may take 1–2 minutes to become ready after the script completes.

### Step 7 — Databases (optional)

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

### Step 8 — Nexus (artifact repository, optional)
```bash
tools/k3s/nexus.sh <env>
```

### Step 9 — Registry Credentials for App Repos
Push Harbor (and Nexus, if provisioned) robot credentials as GitHub environment secrets — once
per application repository. Without this, CI can't push images.
```bash
tools/k3s/registry-credentials.sh <env> <github-repo-name>
```

### Step 10 — Sync GitHub Org Secrets
```bash
tools/k3s/provision-org-secrets.sh <env>
```

### Final Validation

```bash
kubectl get nodes                    # Node ready
kubectl get pods -A                  # All pods running
curl -sS -o /dev/null -w "%{http_code}" https://dex.<HOSTNAME>/.well-known/openid-configuration
curl -sS -o /dev/null -w "%{http_code}" https://harbor.<HOSTNAME>/api/v2.0/health
curl -sS -o /dev/null -w "%{http_code}" https://argocd.<HOSTNAME>
curl -sS -o /dev/null -w "%{http_code}" https://grafana.<HOSTNAME>/api/health
```

## Troubleshooting

- **Helm repo errors** (stale repos): `helm repo remove <name>` and retry.
- **kubectl context mismatch**: all scripts validate the context matches the target env. Check
  `envs/<env>/kubeconfig.yaml` and `~/.kube/config`.
- **Secrets**: plaintext lives in `secrets.plain/` (gitignored, never committed); encrypted
  copies in `secrets.sops/`. Manage with `tools/sops/encrypt.sh` / `decrypt.sh` / `apply.sh`.
  `apply.sh` uses the **current kubectl context** — verify it before applying.
- **Apps not deploying**: ArgoCD auto-syncs manifests from `envs/<env>/apps/`. If images aren't
  in Harbor yet, trigger the app's CI workflow first.
- **Tailscale/SSH issues after a wipe**: the script cleans stale Tailscale devices; if SSH hangs,
  check for duplicate devices in the Tailscale admin console.
- **Runner image not detected**: the script checks Harbor via API; if the image exists but isn't
  found, check Harbor API connectivity and the robot account credentials.

## Multiple GitHub Orgs

To run an environment under a different GitHub org than your main one:

- The new org needs its **own envs repo** (may bundle infra-skills as a Git submodule, with
  `INFRA_ENVS_ROOT` set via direnv), its **own GitHub App** (same permissions as in `/new-env`),
  and its **own OAuth App** for Dex.
- CI runners in the new org can't pull private images or reusable workflows from the original
  org: copy the runner Dockerfile + `build-runner-image.yml` workflow into the new envs repo, and
  inline CI workflows into app repos (set the env name, GitOps repo, runner labels, and derive
  `HARBOR_REGISTRY`/`NEXUS_REGISTRY` from the environment).
- If builds must resolve artifacts from another environment's Nexus, create an authenticated
  proxy repository in the local Nexus pointing at the source Nexus `maven-public` group, add it
  to the local `maven-public` group, and whitelist the new server's outbound IPs (IPv4 **and**
  IPv6 — Hetzner servers often prefer IPv6 outbound) on the source side.
