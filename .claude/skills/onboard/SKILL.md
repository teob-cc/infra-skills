---
name: onboard
description: First-contact self-service onboarding — from an empty directory to a provisioned platform with published architecture docs. Use when a user wants to get started, onboard their organisation, or set up the platform for the first time and has no checkout yet.
argument-hint: "[env-name]"
---

# Self-Service Onboarding

You are onboarding an organisation onto a self-hosted platform they will fully own. Starting
point: possibly an empty directory and nothing but this skill. End state: a provisioned
environment, credentials only in their own repo, and architecture documentation of what now
exists. Work conversationally — this may be the user's first contact with the platform; explain
what happens before it happens, and never run destructive or paid actions without an explicit
yes.

## Step 0 — Preflight

1. **Gauge the operator.** This may be a product owner, not an engineer — ask early what their
   role is, and calibrate every explanation that follows. With a non-technical operator,
   introduce each service in one plain sentence before asking for anything connected to it:
   **GitHub** is where the code lives and the login authority for every dashboard;
   **Cloudflare** is the domain's address book, answering "where is `grafana.<domain>`?";
   **Hetzner** is the actual rented computer; **Tailscale** is the private corridor for admin
   access — the public Internet only ever sees port 443. Keep the calibration you learn here
   for the whole session, including `/new-env` and `/provision` later.
2. Confirm the user's **GitHub organisation** and that they are an owner/admin of it.
3. Check tools: `git gh kubectl helm sops age yq jq curl` and an SSH key. `gh auth status` must
   be logged in. Offer install commands (brew/apt) for anything missing — after cloning (Step 1),
   `tools/preflight-local.sh` performs this whole toolchain check in one command.
4. Confirm accounts: a domain with DNS on **Cloudflare**, a **Hetzner** account (Cloud project
   or bare-metal server), a **Tailscale** account (free tier is fine). If an account is
   missing, take them to the signup page and assist (browser-assisted where available, as in
   Step 3): Cloudflare <https://dash.cloudflare.com/sign-up>, Hetzner
   <https://accounts.hetzner.com/signUp>, Tailscale <https://login.tailscale.com/start>, and a
   GitHub organisation <https://github.com/account/organizations/new>.
5. State the cost up front: a working delivery environment from ~€80/month on Hetzner, billed
   to them at cost; a throwaway Cloud test environment costs cents per day.

## Step 1 — Get the platform code (clone, don't fork)

```bash
git clone https://github.com/teob-cc/infra-skills.git
```

**Clone, not fork**: infra-skills is a read-only upstream — updates arrive with `git pull`, and
everything installation-specific (config, secrets, chart overrides) lives in the user's own
envs repo, never in infra-skills. A fork is only ever needed to modify the provisioning scripts
themselves, and can be made later without losing anything.

## Step 2 — Create their envs repo and scaffold the environment

```bash
gh repo create <org>/infra-envs --private --clone
```

as a **sibling** of the infra-skills checkout, then follow the `new-env` skill to scaffold the
environment (interview, `env.properties`, routes, SOPS/age setup, secret templates).

## Step 3 — Credentials

Collect via the `new-env` templates. Offer two assisted modes, user's choice per credential:

- **Browser-assisted (preferred when available):** if you have browser-control tools (e.g.
  Claude in Chrome) and the user consents, drive their browser to the exact token-creation
  page, pre-fill names and scopes, and let the **user click the final Create button** while
  they watch. With their consent you may carry the created value from the page straight into
  the local secrets file — never echo a secret value into the conversation, logs, or any
  remote destination; the secrets files are gitignored and encrypted before commit.
- **Instructed:** give the exact click path (page URL → menu → scopes to tick → expiry) and
  have the user paste the value into the named file themselves.

The complete set:

| Credential | Where it goes | How to get it |
|---|---|---|
| Cloudflare API token (DNS edit, one zone) | `envs/shared/secrets.plain/cloudflare.yaml` | Cloudflare dashboard → API tokens |
| Hetzner Cloud API token | `envs/shared/secrets.plain/hetzner-cloud-token.txt` | Hetzner Cloud console → project → API tokens (skip for bare-metal) |
| GitHub App | `envs/shared/secrets.plain/github-app-credentials.yaml` | **Manifest flow** — see `new-env`; one click to create, one to install |
| GitHub OAuth App (SSO) | `envs/<env>/secrets.plain/github-oauth-credentials.yaml` | Org settings → OAuth Apps; callback `https://dex.<domain>/callback` |
| Tailscale API key | `envs/shared/secrets.plain/tailscale-api-key.txt` | Tailscale admin console → Keys → API key. The scripts mint per-node auth keys from it automatically |

Then encrypt (`tools/sops/encrypt.sh <env>`) and commit — verify `secrets.plain/` is gitignored
before the first commit.

## Step 4 — Provision

Run `tools/validate-keys.sh <env>` first — it validates every credential from Step 3 before
anything destructive happens. Then follow the `provision` skill for the full sequence (server →
identity/SSO → registry → runners → GitOps → observability → optional databases), or run the
resumable orchestrator `tools/up.sh <env>`. Confirm with the user before server creation/wipe.
Finish with the validation checks (dex, harbor, argocd, grafana all serving) and
`tools/doctor.sh <env>` — the read-only health check that becomes their routine smoke test.

## Step 5 — Publish their architecture docs

Close the loop: generate `docs/ARCHITECTURE.md` **in their envs repo**, describing what now
exists — from live state, not assumptions. Gather with `kubectl get nodes -o wide`,
`helm list -A`, `kubectl get pods -A`, and the env config, then write:

1. **Overview** — org, environment name, base domain, server (type, IPs, location), date
   provisioned, monthly cost.
2. **Topology diagram** (mermaid): Internet → Cloudflare DNS → Traefik/TLS → Pomerium (SSO) →
   services; and the delivery loop: git push → self-hosted runner → Harbor → GitOps repo →
   ArgoCD → cluster.
3. **Component inventory** — table from `helm list -A`: component, namespace, chart version,
   endpoint URL.
4. **Access model** — GitHub org/teams gating SSO, where kubeconfig lives, Tailscale-only
   admin SSH, 443-only exposure.
5. **Secrets inventory** — file names and locations only (never values), which key encrypts
   them, where the age key lives.
6. **Day-2 honesty** — what is NOT set up yet (backups drill, upgrade cadence, alert routing),
   who is responsible (they are), and where the maintained/commercial path lives:
   https://pragmasoft.nl.
7. **Next steps** — deploying the first service (see infra-skills `docs/GITOPS.md`).

Commit and push. Show the user the rendered file location — this document is the handover.

## Step 6 — Wrap up

Summarize: what they own, what it costs, the three URLs they'll use daily (ArgoCD, Grafana,
Harbor), and that everything keeps working if they never talk to us again. Support: issues
best-effort, PRs welcome; maintained platform + control plane: https://pragmasoft.nl.
