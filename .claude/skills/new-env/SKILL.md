---
name: new-env
description: Scaffold a new environment config from scratch — interview the user, generate env.properties, routes, secret templates, and SOPS setup. Use when the user wants to set up their first environment or add another one, and no envs/<name> directory exists yet.
argument-hint: "[env-name]"
---

# New Environment Scaffold

Interview the user, then generate a complete environment config skeleton. When everything is in
place, hand over to `/provision`.

## Step 1 — Locate or create the envs root

Resolve the envs root the same way the scripts do (`INFRA_ENVS_ROOT` → `../infra-envs/envs` →
`./envs`). If none exists, recommend creating a **private** Git repo (e.g. `<org>/infra-envs`)
checked out as a sibling of infra-skills, containing:

```
infra-envs/
  .sops.yaml          # copy from infra-skills/.sops.yaml, replace the age recipient (Step 4)
  .gitignore          # must contain: **/secrets.plain/  and  **/kubeconfig.yaml
  envs/
    shared/secrets.plain/
    <env>/...
```

The `.gitignore` line for `secrets.plain/` is mandatory — verify it before writing any secret
template.

## Step 2 — Interview

Ask for (accept an env name from the arguments if given):

1. **Environment name** — short, lowercase (e.g. `prod`, `staging`).
2. **Base domain** — becomes `HOSTNAME`, e.g. `prod.example.com`. The domain's DNS must be on
   Cloudflare (scripts manage records via the Cloudflare API).
3. **Server type** — Hetzner bare-metal (existing server, they have the IP) or Hetzner Cloud VM
   (created via API; ask for server type e.g. `cax21`, location e.g. `hel1`).
4. **ACME email** — for Let's Encrypt certificates.
5. **GitHub org** — gates SSO and hosts the CI runners.
6. **Components beyond the core** — core is identity + Harbor + runners + ArgoCD +
   observability; optional: PostgreSQL, MySQL, Redpanda/Scylla, Nexus.

## Step 3 — Generate the environment files

`envs/<env>/env.properties` — bare-metal:

```properties
HOSTNAME=<base-domain>
EXTERNAL_IP=<server-public-ip>
VLAN_IP=192.168.100.1
ACME_EMAIL=<acme-email>
# Optional — only if the envs repo is not https://github.com/<github-org>/infra-envs.git:
# GITOPS_REPO_URL=<git-url-of-your-envs-repo>
# Optional — Let's Encrypt staging (untrusted certs, no rate limits) for throwaway envs that
# get wiped and rebuilt often; leave unset for anything people will use in a browser:
# ACME_STAGING=true
# Optional — Hetzner image name prefix for bare-metal (default Ubuntu-2404-noble):
# BASE_OS_IMAGE=Ubuntu-2604-resolute
# Optional components tools/up.sh runs for this env (from: postgres mysql redpanda scylla nexus wireguard backup):
UP_OPTIONAL_STEPS="postgres"
```

For a Cloud VM, add (and omit EXTERNAL_IP — the script fills it in after creation):

```properties
HCLOUD_SERVER_TYPE=cax21
HCLOUD_LOCATION=hel1
HCLOUD_IMAGE=ubuntu-24.04
HCLOUD_NETWORK_ZONE=eu-central
PRIVATE_IP=10.0.0.2/16
```

`envs/<env>/pomerium-routes.yaml` — minimal starter (the identity script provisions a test app
that verifies SSO end-to-end). The platform scripts append their own routes here as they run
(argocd, pgweb, adminer, console, cassandra) — commit the file again after provisioning:

```yaml
config:
  routes:
    - from: https://identity.<base-domain>
      to: http://identity-app.sso.svc.cluster.local
      preserve_host_header: true
      pass_identity_headers: true
      allow_any_authenticated_user: true
```

`envs/<env>/apps/` — empty directory (ArgoCD Application manifests land here later).

`.github/workflows/build-runner-image.yml` in the envs repo — the thin caller that builds the
custom CI runner image on the org's own runners (copy `docs/examples/envs-repo/build-runner-image.yml`
from infra-skills verbatim). `/provision` Step 4 dispatches it; it needs the Harbor secrets that
`tools/k3s/registry-credentials.sh <env> <envs-repo-name>` installs.


## Step 4 — SOPS / age setup

If the user has no age key:

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt   # prints the public key (recipient)
```

Put the **public** key into `.sops.yaml` at the envs repo root (both `age:` lists), replacing any
recipient already there. The private key never leaves `~/.config/sops/age/keys.txt`.

On macOS a bare `sops -d` does **not** look in `~/.config/sops/age/` (it uses
`~/Library/Application Support/sops/age/keys.txt`). The `tools/sops/*.sh` wrappers set
`SOPS_AGE_KEY_FILE` for you; for manual sops calls export it:
`export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`.

## Step 5 — Secret templates

Write these into place with placeholder values, then walk the user through filling them in. Never
ask the user to paste secret values into the chat — have them edit the files directly.

`envs/<env>/secrets.plain/github-oauth-credentials.yaml` — a GitHub **OAuth App** (create at
`https://github.com/organizations/<org>/settings/applications`, callback URL
`https://dex.<base-domain>/callback`):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-oauth-credentials
type: Opaque
stringData:
  githubClientID: "<oauth-app-client-id>"
  githubClientSecret: "<oauth-app-client-secret>"
  githubOrg: "<github-org>"
```

`envs/shared/secrets.plain/cloudflare.yaml` — API token scoped to DNS edit for the zone:

```yaml
cloudflare-api-token: "<token>"
```

`envs/shared/secrets.plain/github-app-credentials.yaml` — a GitHub **App** (separate from the
OAuth App) for CI automation. Repository permissions: Contents R/W, Secrets R/W, Environments
R/W, Metadata Read; organization permissions: Self-hosted runners R/W.
(Creating a repository *environment* additionally needs Administration R/W, which the App does
not get; `registry-credentials.sh` falls back to the operator's own `gh` login for that one call.)

Prefer the **manifest flow** over manual creation (two clicks instead of six steps):
`docs/examples/github-app-manifest.html` is a self-submitting form -- fill in `<org>`, `<name>`
and the environment domain, open it in the browser (a `file://` URL works), click **Create**;
GitHub redirects to `redirect_url` with a one-time `code`; then exchange it --

```bash
gh api -X POST /app-manifests/<code>/conversions
```

— the response contains `id` (app id), `pem` (private key), and after the user installs the App
on the org (one more click), the installation id via `gh api /app/installations` with an App
JWT, or simply from the installation page URL. Write all three into the credentials file below.
Install it on the org:

```yaml
# Key names are what the scripts read (provision::github_read_credentials); no namespace --
# each consumer (ArgoCD, the runner controller) copies it into its own namespace.
apiVersion: v1
kind: Secret
metadata:
  name: github-credentials
type: Opaque
stringData:
  githubAppID: "<app-id>"
  githubAppInstallationID: "<installation-id>"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    ...
    -----END RSA PRIVATE KEY-----
```

When carrying the `pem` from the conversion response into the file, keep its line breaks —
e.g. `PEM="$pem" yq -i '.stringData.githubAppPrivateKey = strenv(PEM)' <file>`. A flattened
key makes every GitHub-dependent step fail with an openssl "Could not find private key" error.

Cloud VMs only — `envs/shared/secrets.plain/hetzner-cloud-token.txt`: the Hetzner Cloud API
token, as a bare single-line file.

Bare-metal only — `envs/shared/secrets.plain/hetzner-webservice-user.txt`: the Hetzner **Robot**
webservice user (Robot → Settings → *Webservice and app settings*; a separate credential from the
account login), as `user:password` on one line (or user on line 1, password on line 2). It drives
rescue mode, SSH-key registration and `installimage`, so it is highly privileged. It is a password:
have the user write the file themselves rather than driving the browser for it.

`envs/shared/secrets.plain/tailscale-api-key.txt` — a Tailscale **API key** (admin console →
Settings → Keys), as a bare single-line file. Admin SSH runs over Tailscale (only 443 is open
to the Internet); the provisioning scripts mint per-node auth keys from this API key
automatically. The tailnet's SSH policy needs an `accept` rule (the default `check` rule makes
Tailscale SSH demand a browser re-auth per session, which hangs unattended runs) — admin console
→ Access controls → `"ssh"` → `"action": "accept"`; `tools/validate-keys.sh` checks it.

Optional, alert routing (Alertmanager). Without them `observability.sh` installs labelled
placeholder Secrets so Alertmanager starts, and no alert is delivered anywhere — record that in
the architecture doc's day-2 section. Fill in when the org has an SMTP relay / Telegram bot:

`envs/<env>/secrets.plain/resend-api-key.yaml` (namespace `default`; mirrored into
`observability` by the script; any SMTP relay works, `ALERTMANAGER_SMTP_HOST` in env.properties):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: resend-api-key
  namespace: default
type: Opaque
stringData:
  api_key: "<smtp-api-key>"
```

`envs/<env>/secrets.plain/alertmanager-telegram.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-telegram
  namespace: observability
type: Opaque
stringData:
  bot_token: "<telegram-bot-token>"
  chat_id: "<telegram-chat-id>"
```

Also confirm the operator has: an SSH key (`~/.ssh/id_ed25519`) and the CLIs
`kubectl helm sops age yq jq curl`.

## Step 6 — Encrypt and hand over

```bash
tools/sops/encrypt.sh <env>        # secrets.plain -> secrets.sops (committable)
```

Commit everything except `secrets.plain/` (verify with `git status` that nothing plaintext is
staged). Also copy `docs/examples/envs-repo/build-runner-image.yml` and
`build-teob-base-image.yml` to `.github/workflows/` in the envs repo now — `up.sh`'s
runner-image and base-image steps need them there. Then run `/provision <env>`.
