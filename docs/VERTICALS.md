# Verticals — provider seams and the road to 100% sovereign

The platform touches four external concerns. Each one is a **vertical**: a capability the
platform needs, with a provider currently behind it. The providers shipped today are pragmatic
defaults — chosen because they make day 1 cheap and reliable — not commitments. This document
names each vertical, where its seam lives in the code, and what replacing the provider takes.

Two motivations drive the design:

- **Sovereignty.** Today the stack depends on exactly three third-party control planes
  (GitHub, Cloudflare, Tailscale) plus a hardware vendor. Each has a self-hostable
  replacement on the roadmap. A platform where every vertical runs a self-hosted provider is
  100% sovereign: nothing outside your own hardware can revoke, throttle, or observe it.
- **Migration.** The compute vertical is deliberately thin. Hetzner is where the economics
  shine, but nothing in the platform *requires* it — supporting more clouds is how you move
  *between* them, with the platform as the constant.

## 1. Identity + git + pipelines — GitHub (today)

One provider currently answers three questions: *who are you* (OAuth through Dex, team-based
ACLs in Pomerium), *where does code live* (the `infra-envs` GitOps repo, app repos), and *what
runs CI* (Actions on self-hosted runners provisioned by `tools/k3s/github-action-runner.sh`).
They are one vertical because they share the trust root: the GitHub org and a GitHub App.

- **Seam today:** `provision::git_org` in `tools/provision-common.sh` answers "which org owns
  this environment"; the GitHub App plumbing (`provision::github_app_mint_jwt`,
  `provision::github_get_installation_token`) is concentrated in the same file, and
  `GITHUB_API_URL` is already overridable — GitHub Enterprise Server mostly works today.
  The four reusable workflows in `.github/workflows/` take `gitops_repo` and registry
  parameters instead of assuming an org.
- **Sovereign roadmap:** Forgejo (or Gitea) for identity + git, Woodpecker (or Forgejo
  Actions) for pipelines — both run comfortably on the platform itself. Dex already speaks
  generic OIDC, so the identity swap is a connector change, not an architecture change. The
  hard part is the CI runner story and the App-token model; that is why this is the deepest
  vertical and the last to swap.

## 2. DNS / edge — Cloudflare (today)

The platform needs exactly two DNS operations: *make NAME resolve to IP* and *is NAME covered
by a wildcard*. Everything else in the Cloudflare integration is protocol, not logic.

- **Seam today:** `provision::dns_ensure_record` and `provision::dns_check_wildcard` in
  `tools/provision-common.sh`, dispatched on `DNS_PROVIDER` (default `cloudflare`). Adding a
  provider = implementing those two operations for it in one `case` arm each.
- **Roadmap:** any DNS API (Hetzner DNS, deSEC, PowerDNS self-hosted). This is the cheapest
  vertical to extend — a good first contribution.

## 3. Compute — Hetzner bare-metal & Cloud (today)

Two scripts own the provider protocol: `tools/provision-hetzner-baremetal.sh` (Robot API,
rescue mode, RAID/LVM layout, vSwitch VLAN) and `tools/provision-hetzner-cloud.sh` (hcloud
API, Cloud Networks). Everything after "an Ubuntu server answers SSH" is provider-free.

- **Seam today:** `tools/k3s/join-worker.sh` — it deliberately assumes no Hetzner facility
  (no VLAN, no vendor API) and joins **any Ubuntu machine reachable over the private
  network** as a worker. That is the empirically proven provider-free path: the platform
  already runs mixed fleets this way.
- **Roadmap:** a `provision-<cloud>.sh` per provider (the two Hetzner scripts are the
  reference shape: create/wipe/destroy + wait-for-SSH + private network). Migration between
  clouds is then: provision the new servers, join them, drain the old ones — the GitOps layer
  and the data-layer backups do not change.

## 4. Private network — Tailscale (today)

The least visible and most load-bearing vertical: admin SSH and `kubectl` reach servers over
the tailnet only; UFW exposes just 443 (and 80 for ACME) publicly; backups travel over it.
It is configured by the provisioning scripts rather than abstracted behind functions — which
is precisely why it is named here: an invisible dependency is the one that bites during a
migration.

- **Seam today:** membership in the mesh is the only contract. Nothing checks *which*
  coordination server issued the IPs.
- **Sovereign roadmap:** headscale — a self-hosted, API-compatible Tailscale control plane.
  Expected to be the second-easiest swap after DNS.

## Adding a provider

1. Pick the vertical and read its seam above.
2. DNS: add a `case` arm to the two `provision::dns_*` functions. Compute: write
   `tools/provision-<provider>.sh` following the Hetzner scripts' phase structure; reuse
   `join-worker.sh` for workers. Network/forge: open an issue first — these two carry the
   trust root and deserve design discussion before code.
3. No provider code may phone home, embed credentials, or write outside the envs repo — the
   same rules the existing scripts live by (`CLAUDE.md`, Guardrails).

## What is deliberately *not* pluggable

K3s, Dex, Pomerium, ArgoCD, Harbor, SOPS/age, and the GitOps conventions are the platform,
not verticals. Swapping those is a fork, not a provider.
