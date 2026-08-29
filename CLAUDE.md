# CLAUDE.md

This file guides AI agents working with this repository. infra-skills provisions a complete,
self-hosted Kubernetes platform — identity/SSO, CI/CD, GitOps delivery, registries, databases,
observability — onto servers you own (Hetzner bare-metal or Cloud, or anything Ubuntu-compatible
you can SSH into). Everything runs under the operator's own accounts: their GitHub org, their
Hetzner account, their domain, their secrets. The scripts never phone home.

## Skills

- `/onboard` — first contact: from an empty directory to a provisioned platform with published
  architecture docs. Clones this repo, creates the user's envs repo, walks credentials
  (browser-assisted where available), provisions, documents.
- `/new-env` — interview the user and scaffold a new environment config (env.properties, routes,
  secret templates, SOPS setup).
- `/provision` — the full provisioning sequence for an existing environment config, in dependency
  order, with validation steps.

## How environment configs are discovered

Scripts find environment configs via `provision::envs_root()` (in `tools/provision-common.sh`):

1. `INFRA_ENVS_ROOT` env var (explicit override, points at an `envs/` directory)
2. `../infra-envs/envs` — sibling checkout named `infra-envs` (recommended layout)
3. `./envs` inside this repo (monorepo layout)

Each environment lives at `envs/<env>/`:

```
envs/
  <env>/
    env.properties          # HOSTNAME, EXTERNAL_IP, VLAN_IP, ACME_EMAIL (+ HCLOUD_* for cloud VMs)
    kubeconfig.yaml         # written by the server-provisioning script
    pomerium-routes.yaml    # auth-proxy routing rules
    apps/                   # ArgoCD Application manifests + Helm charts
    alerts/                 # optional Prometheus alert-group fragments (merged by observability.sh)
    secrets.plain/          # plaintext secrets — gitignored, NEVER committed
    secrets.sops/           # age-encrypted secrets — committed
  shared/
    alerts/                 # optional alert-group fragments applied to every environment
    secrets.plain/          # cross-env credentials (Cloudflare token, GitHub App, Hetzner token)
```

`HOSTNAME` in env.properties is the environment's base domain (e.g. `prod.example.com`). Every
service hostname is derived from it: `dex.<HOSTNAME>`, `harbor.<HOSTNAME>`, `argocd.<HOSTNAME>`,
`grafana.<HOSTNAME>`, etc. DNS is managed via the Cloudflare API (token in
`shared/secrets.plain/cloudflare.yaml`); an A record for `<HOSTNAME>` plus a wildcard
`*.<HOSTNAME>` cover everything.

## Provisioning order (summary — the `/provision` skill has the full sequence)

1. Server: `tools/provision-hetzner-baremetal.sh` or `tools/provision-hetzner-cloud.sh`
2. `tools/k3s/identity.sh` — cert-manager + Dex (GitHub OAuth) + Pomerium. Always first.
3. `tools/k3s/harbor.sh` — container registry (before runners; runners push to it)
4. `tools/k3s/registry-credentials.sh` + `tools/k3s/github-action-runner.sh --bootstrap`
5. `tools/k3s/argocd.sh` — GitOps; deploys everything in `envs/<env>/apps/`
6. `tools/k3s/observability.sh`, `tools/k3s/mysql.sh` — independent, any order
7. Optional: `postgres.sh`, `redpanda.sh`, `scylla.sh`, `nexus.sh` — per environment needs

## Conventions all scripts follow

- First argument is the environment name; `provision::load_env()` loads its `env.properties`.
- Scripts validate the kubectl context matches the target environment before changing anything.
- `provision::require_tools()` checks required CLIs: kubectl, helm, sops, age, yq, jq, curl.
- Most scripts support `--skip-*` flags for individual components; data-layer scripts support
  `--watch` (live monitoring) and `--provision-credentials <app-id>` (per-app credentials written
  to `secrets.plain/`).
- Secrets workflow: `tools/sops/encrypt.sh <env>` (plain → sops), `tools/sops/decrypt.sh <env>`,
  `tools/sops/apply.sh <env>` (apply to cluster). `.sops.yaml` at the envs repo root pins the age
  recipient — replace it with the operator's own age public key.
- Helm charts for Dex, Pomerium, and Nexus are bundled at `charts/` and resolved via
  `provision::chart_path <name>`; a chart at `envs/shared/apps/<name>` in the envs repo takes
  precedence (per-installation customization).

## Guardrails — non-negotiable

- **Confirm before destruction.** `--wipe` reinstalls a server's OS; `--destroy` deletes a cloud
  server. Echo the target hostname/IP back to the user and get an explicit yes first.
- **Never commit `secrets.plain/`.** Never print secret values into the conversation; reference
  key names and file paths instead.
- **`sops/apply.sh` uses the current kubectl context.** Verify the context (or set KUBECONFIG
  explicitly) before applying secrets — the wrong context applies them to the wrong cluster.
- **Don't hardcode domains or orgs.** Hosts derive from `HOSTNAME`; the GitHub org comes from
  `github-oauth-credentials.yaml` (`stringData.githubOrg`). If you find a hardcoded value in a
  script, that's a bug worth flagging.
- One step at a time: the provisioning order exists because of real dependencies (Dex before
  everything, Harbor before runners). Don't parallelize across steps.
