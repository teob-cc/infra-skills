# infra-skills

A complete, self-hosted production platform on hardware you own — provisioned by scripts you can
read, designed to be driven by your AI agent.

One command sequence takes a fresh Hetzner server (bare-metal or Cloud VM) to a working K3s
platform: GitHub single sign-on in front of everything (Dex + Pomerium), CI/CD on your own
runners, GitOps delivery (ArgoCD), container and artifact registries (Harbor, Nexus), production
databases (PostgreSQL, MySQL, optionally Redpanda + ScyllaDB), and observability (Prometheus +
Loki + Grafana) — with TLS, DNS, and age-encrypted secrets handled along the way. Everything runs
under **your** accounts: your GitHub org, your Hetzner account, your domain, your keys. Nothing
phones home.

## Who this is for — and not for

**For:** teams shipping a real product — you have a GitHub organisation, a domain, and
production ambitions, and you want hyperscaler-grade infrastructure at bare-metal prices without
giving up control of any of it.

**Not for:** single-VPS hobby setups. There is no Docker-Compose mode, no Raspberry Pi target,
and no plan to add them. If that's what you need, [Coolify](https://coolify.io) and friends will
serve you better.

**Support policy:** this repo is maintained for our own production use and released as-is.
Issues are read on a best-effort basis; PRs are welcome. If you want the platform delivered,
kept current, and backed by humans, that's the commercial offering:
[pragmasoft.nl](https://pragmasoft.nl).

## Quickstart — with your AI agent

Self-service onboarding: give your agent three API keys — Cloudflare, Hetzner, GitHub — and get
a full environment back. The repo ships agent instructions (`CLAUDE.md`) and the skills that
drive it; the step-by-step walkthrough is in
[docs/GETTING-STARTED.md](docs/GETTING-STARTED.md).

```bash
git clone https://github.com/teob-cc/infra-skills.git
cd infra-skills
claude   # or your agent of choice
```

Then say:

- **`/onboard`** — first contact, from an empty directory: the agent fetches the platform code,
  creates your envs repo, walks you through the credentials (driving your browser to the token
  pages if you let it), provisions, and publishes your architecture docs.
- **`/new-env`** — the agent interviews you (domain, server, GitHub org, components), scaffolds
  your environment config, and walks you through the three keys and the few credentials only
  you can create.
- **`/provision <env>`** — the agent runs the full provisioning sequence in dependency order,
  asking before anything destructive, and validates the result.

The skills can also be installed globally from the plugin marketplace, without being inside the
checkout:

```
/plugin marketplace add teob-cc/infra-skills
/plugin install sovereign-stack@pragmasoft
```

Prefer doing it by hand? The same sequence is documented in
[`.claude/skills/provision/SKILL.md`](.claude/skills/provision/SKILL.md) — the scripts are plain
bash and take `<env-name>` as their first argument.

## Repository contents

| Path | Description |
|---|---|
| `tools/` | Provisioning scripts (server, k3s components, SOPS, DNS) |
| `charts/` | Bundled Helm charts (Dex, Pomerium, Nexus) — override via `envs/shared/apps/<name>` |
| `images/` | Docker images (CI runner, base builder) |
| `.github/workflows/` | Reusable CI/CD workflows |
| `docs/` | Getting started, GitOps delivery, verticals, operations runbooks |
| `.claude/` | Agent instructions and skills (`/onboard`, `/new-env`, `/provision`) |
| `.claude-plugin/`, `plugins/` | Plugin marketplace (`/plugin marketplace add teob-cc/infra-skills`) |
| `.sops.yaml` | SOPS encryption rules template |

## Environment configs

Environment configs live outside this repo (yours, in your own private repo). Clone the two as
siblings:

```
work/
  infra-skills/   # this repo
  infra-envs/    # your environment configs (private)
```

`provision::envs_root()` resolves the envs directory in this order:

1. `INFRA_ENVS_ROOT` env var (explicit override)
2. `../infra-envs/envs` relative to this repo (sibling checkout)
3. `./envs` inside the same repo (monorepo layout)

Each environment is a directory: `env.properties` (base domain, IPs, ACME email),
`pomerium-routes.yaml` (auth-proxy routes), `apps/` (ArgoCD Applications), `secrets.plain/`
(gitignored) and `secrets.sops/` (age-encrypted, committed). `/new-env` generates all of it.

## Prerequisites — in plain terms

The platform stands on four accounts, all of them yours. If infrastructure is not your day
job — maybe you're the product person who ended up operating this — here is what each service
actually does in this stack, and where to sign up. Your agent explains any of this again during
onboarding, at whatever depth you need, and can walk you through each signup page.

- **[GitHub](https://github.com/account/organizations/new)** — an *organisation*, not just a
  personal account: it holds your code, runs your build pipelines, and doubles as the login
  authority — "sign in with GitHub, must be a member of your org" is the front door to every
  dashboard the platform serves. Free.
- **[Cloudflare](https://dash.cloudflare.com/sign-up)** — your domain's address book (DNS). It
  answers "where is `grafana.your-domain.com`?" with your server's address; the provisioning
  scripts maintain those records through its API. The free plan is enough — you point your
  domain's nameservers at Cloudflare once, and everything after that is automatic.
- **[Hetzner](https://accounts.hetzner.com/signUp)** — the actual computer. A German hosting
  company renting serious hardware at honest prices: a capable bare-metal server from about
  EUR 80,- per month, a throwaway Cloud test VM for cents per day. Billed to you directly — we
  never sit between you and your server. Any Ubuntu server you can SSH into works too.
- **[Tailscale](https://login.tailscale.com/start)** — the private corridor for administration.
  The server keeps exactly one door open to the public Internet: port 443, the web. SSH and the
  Kubernetes API travel over an encrypted private network that only your enrolled machines can
  enter. The free tier is fine.

Locally you need an SSH key, a SOPS age key (see `tools/sops/README.md`), and the CLIs
`kubectl helm sops age yq jq curl` — `tools/preflight-local.sh` checks the whole list in
one go.

## Verticals — what is swappable

Every external dependency is a *vertical*: a concern with a provider behind it. Today's
providers are the pragmatic defaults, not commitments — the roadmap runs toward 100%
sovereign, and toward other clouds when you need to migrate:

| Vertical | Today | Roadmap |
|---|---|---|
| Identity + git + pipelines | GitHub (org, App, OAuth, Actions) | Forgejo/Gitea + Woodpecker (fully self-hosted) |
| DNS / edge | Cloudflare | any DNS API |
| Compute | Hetzner bare-metal & Cloud | other clouds, on-prem — join any Ubuntu server as a worker today |
| Private network | Tailscale | headscale (self-hosted control plane) |

The seams and how to add a provider: [docs/VERTICALS.md](docs/VERTICALS.md).

## Documentation

- [Getting Started](docs/GETTING-STARTED.md)
- [Verticals & provider seams](docs/VERTICALS.md)
- [GitOps Service Delivery](docs/GITOPS.md)
- [Evaluator key intake](docs/EVALUATOR-KEYS.md)
- [Kafka-journal operations (Redpanda + ScyllaDB)](docs/KAFKA-JOURNAL-OPS.md)

## License

[Apache License 2.0](LICENSE). Use it, fork it, run it in production, build a business on it.
