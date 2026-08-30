# Getting started — self-service onboarding with your AI agent

From a handful of API keys to a full production environment, driven by your own AI agent. This
is the free, self-service path; if you'd rather have it done for you, see
[pragmasoft.nl](https://pragmasoft.nl).

**Fastest path — one skill, empty directory:**

```
/plugin marketplace add teob-cc/infra-skills
/plugin install sovereign-stack@pragmasoft
/sovereign-stack:onboard
```

The onboard skill does the rest: clones the platform code, creates your private envs repo,
walks you through each credential (driving your browser to the right token pages if you let
it), provisions the environment, and finishes by publishing architecture docs of what you now
own into your own repo. The sections below describe the same journey step by step, for the
manual-minded.

## What you need

**Accounts** (all yours; nothing is shared with us):

| Account | Why |
|---|---|
| GitHub organisation | SSO identity, CI runners, your envs repo |
| Domain with DNS on Cloudflare | TLS'd hostnames for every service |
| Hetzner (bare-metal or Cloud) | The hardware. A working delivery environment from ~€80/mo |
| Tailscale (free tier is fine) | Admin SSH — only 443 is open to the Internet |

**The four keys** — created in your accounts, granted to your agent, stored only in your own
repo (age-encrypted):

1. **Cloudflare API token** — scoped to DNS edit for your zone.
2. **Hetzner Cloud API token** — Cloud environments only; bare-metal needs just SSH access.
3. **GitHub App credentials** — for CI automation (runners, secrets). Plus one GitHub **OAuth
   App** for single sign-on — the `/new-env` skill walks you through creating both.
4. **Tailscale API token** — admin SSH runs over Tailscale, not the public Internet; the
   scripts mint short-lived per-node auth keys from this token themselves.

**Local tools:** `kubectl helm sops age yq jq curl`, an SSH key, and an AI agent
(Claude Code or compatible).

## Step 1 — Get the skills

**Clone the repo** (required either way — the provisioning scripts live here):

```bash
git clone https://github.com/teob-cc/infra-skills.git
cd infra-skills
claude
```

Skills in `.claude/skills/` are picked up automatically when your agent runs inside the
checkout. Optionally, install them globally from the marketplace so they're available in any
directory:

```
/plugin marketplace add teob-cc/infra-skills
/plugin install sovereign-stack@pragmasoft
```

(Marketplace-installed skills are namespaced: `/sovereign-stack:new-env`,
`/sovereign-stack:provision`.)

## Step 2 — Scaffold your environment

```
/new-env prod
```

The agent interviews you (domain, server type, GitHub org, optional components), creates your
private envs repo with `env.properties`, routes, and secret templates, sets up SOPS/age
encryption, and tells you exactly where each of the four keys goes. Secrets are edited into
files directly — never pasted into the chat.

## Step 3 — Provision

```
/provision prod
```

The agent runs the full sequence in dependency order — server, identity/SSO, registry, CI
runners, GitOps, observability, databases — asking before anything destructive, and finishes
with a validation pass:

```
https://dex.<your-domain>/.well-known/openid-configuration   → 200
https://harbor.<your-domain>/api/v2.0/health                 → 200
https://argocd.<your-domain>                                 → 200
https://grafana.<your-domain>/api/health                     → 200
```

From here, every push to an app repo builds on your own runners, publishes to your own
registry, and deploys via GitOps. See [GITOPS.md](GITOPS.md) for wiring your first service.

## When something breaks

The skills carry the troubleshooting knowledge for the common failure modes (context
mismatches, DNS, runner image detection, Tailscale after reprovisioning) — ask your agent
first. Beyond that: issues are read best-effort, PRs are welcome, and the maintained,
human-backed version of this platform is the commercial offering at
[pragmasoft.nl](https://pragmasoft.nl).
