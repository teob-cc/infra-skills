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

1. Confirm the user's **GitHub organisation** and that they are an owner/admin of it.
2. Check tools: `git gh kubectl helm sops age yq jq curl` and an SSH key. `gh auth status` must
   be logged in. Offer install commands (brew/apt) for anything missing — after cloning (Step 1),
   `tools/preflight-local.sh` performs this whole toolchain check in one command.
3. Confirm accounts: a domain with DNS on **Cloudflare**, a **Hetzner** account (Cloud project
   or bare-metal server), a **Tailscale** account (free tier is fine).
4. State the cost up front: a working delivery environment from ~€80/month on Hetzner, billed
   to them at cost; a throwaway Cloud test environment costs cents per day.

## Step 1 — Get the platform code (clone, don't fork)

```bash
git clone https://github.com/teob-cc/infra-skills.git
```

**Clone, not fork**: infra-skills is a read-only upstream — updates arrive with `git pull`, and
everything installation-specific (config, secrets, chart overrides) lives in the user's own
envs repo, never in infra-skills. A fork is only ever needed to modify the provisioning scripts
themselves, and can be made later without losing anything.

If the sovereign-stack plugin was installed before this clone, run `/plugin marketplace update`
and `/reload-plugins` now so the skill text matches the scripts you just cloned. When a skill
step contradicts what the scripts read, the scripts win — a stale plugin once handed out a
secret template with key names no script reads.

## Step 2 — Create their envs repo and scaffold the environment

```bash
gh repo create <org>/infra-envs --private --clone
```

as a **sibling** of the infra-skills checkout, then follow the `new-env` skill to scaffold the
environment (interview, `env.properties`, routes, SOPS/age setup, secret templates).

## Step 3 — Credentials

Collect via the `new-env` templates. Offer three assisted modes, user's choice per credential:

- **Browser-assisted with clipboard hand-off (preferred when available):** if you have
  browser-control tools (e.g. Claude in Chrome) and the user consents, drive their browser to
  the exact token-creation page, pre-fill names and scopes, and let the **user click the final
  Create button** while they watch. Then have the user click the page's **Copy** button and run
  `! pbpaste > envs/<...>/secrets.plain/<file>` (macOS; `xclip -o` / `wl-paste` on Linux) so the
  value goes clipboard → file and never enters the conversation. Verify the file with a
  length/prefix check, never by printing it.
- **Browser-assisted, agent-carried:** same, but with explicit consent you read the value off
  the page and write it to the file yourself. Faster, but the value then exists in the session
  transcript — say so before doing it, and never echo it into the conversation, logs, or any
  remote destination. Passwords (Hetzner Robot) are never carried this way.
- **Instructed:** give the exact click path (page URL → menu → scopes to tick → expiry) and
  have the user paste the value into the named file themselves.

The complete set:

| Credential | Where it goes | How to get it |
|---|---|---|
| Cloudflare API token (DNS edit, one zone) | `envs/shared/secrets.plain/cloudflare.yaml` | Cloudflare dashboard → API tokens |
| Hetzner Cloud API token (Cloud VMs only) | `envs/shared/secrets.plain/hetzner-cloud-token.txt` | Hetzner Cloud console → project → API tokens |
| Hetzner Robot webservice user (bare-metal only) | `envs/shared/secrets.plain/hetzner-webservice-user.txt` | Robot → Settings → Webservice and app settings; `user:password` on one line. A password — **instructed mode only**, the user writes the file |
| GitHub App | `envs/shared/secrets.plain/github-app-credentials.yaml` | **Manifest flow** — see `new-env`; one click to create, one to install |
| GitHub OAuth App (SSO) | `envs/<env>/secrets.plain/github-oauth-credentials.yaml` | Org settings → OAuth Apps; callback `https://dex.<domain>/callback` |
| Tailscale API key | `envs/shared/secrets.plain/tailscale-api-key.txt` | Tailscale admin console → Keys → API key. The scripts mint per-node auth keys from it automatically |

Tailscale prerequisite: the tailnet's SSH policy must contain an **`accept`** rule (default new
tailnets ship one `check` rule: admin console → Access controls → `"ssh"` → change `"action":
"check"` to `"accept"`). Nodes run Tailscale SSH; in check mode every session wants a browser
re-auth and unattended provisioning hangs. `tools/validate-keys.sh <env>` reports this.

Then encrypt (`tools/sops/encrypt.sh <env>`) and commit — verify `secrets.plain/` is gitignored
before the first commit.

## Step 4 — Provision

Run `tools/validate-keys.sh <env>` first — it validates every credential from Step 3 before
anything destructive happens and names the Robot server that a wipe would reinstall; read that
back to the user and get an explicit yes. Then, in this order (from the infra-skills checkout):

1. Server: `tools/provision-hetzner-baremetal.sh <env> --wipe` (or `provision-hetzner-cloud.sh`).
   `up.sh` does **not** do this step. Expect rescue → installimage → reboot → K3s/Tailscale →
   reboot → kubeconfig written and merged as context `<env>`.
2. Stack: `tools/up.sh <env> --yes`. It first runs `tools/preflight-cluster.sh <env>`
   (node, DNS, 443, pod MTU, Tailscale), then identity → secrets → harbor → runners → argocd →
   observability → **runner-image** (Harbor creds to the envs repo, custom image build on the
   vanilla runners, switch) → **base-image** (`library/teob-base`, the runtime base every JVM
   service starts FROM) → the env's `UP_OPTIONAL_STEPS`, re-applies observability if
   redpanda/scylla ran, and ends with `tools/doctor.sh <env>`. It checkpoints and retries a
   transient failure once; on a real failure fix the cause and re-run — it resumes.
   Prerequisite for the two image steps: the envs repo must contain
   `.github/workflows/build-runner-image.yml` and `build-teob-base-image.yml` (copied from
   `docs/examples/envs-repo/` in Step 2) — commit and push them before `up.sh` gets there.

Details and troubleshooting live in the `provision` skill. Finish with the validation checks
(dex, harbor, argocd, grafana all serving) and `tools/doctor.sh <env>` — the read-only health
check that becomes their routine smoke test. Its CRIT/WARN lines (backups, alert delivery,
image scanning, Tailscale key expiry) become Step 5's day-2 table.

## Step 5 — Publish their architecture docs

Close the loop: generate `docs/ARCHITECTURE.md` **in their envs repo**, describing what now
exists — from live state, not assumptions. `tools/architecture-doc.sh <env>` writes it from
`kubectl`, `helm list -A`, the env config, the Hetzner Robot record and `doctor.sh`; review the
result and add what only a human knows (cost, who is on call). It contains:

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
