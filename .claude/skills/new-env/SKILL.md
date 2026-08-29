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
  .gitignore          # must contain: **/secrets.plain/
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
that verifies SSO end-to-end):

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

## Step 4 — SOPS / age setup

If the user has no age key:

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt   # prints the public key (recipient)
```

Put the **public** key into `.sops.yaml` at the envs repo root (both `age:` lists), replacing any
recipient already there. The private key never leaves `~/.config/sops/age/keys.txt`.

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

Prefer the **manifest flow** over manual creation (two clicks instead of six steps): build a
manifest JSON with the name (e.g. `<org>-ci`), the permissions above, `"public": false`, and no
webhook (`"hook_attributes"` omitted, `"redirect_url"` optional); have the user open
`https://github.com/organizations/<org>/settings/apps/new` with the manifest POSTed (an HTML
form with a `manifest` field, or walk them through pasting it), click **Create**; GitHub
redirects with a one-time `code`; then exchange it —

```bash
gh api -X POST /app-manifests/<code>/conversions
```

— the response contains `id` (app id), `pem` (private key), and after the user installs the App
on the org (one more click), the installation id via `gh api /app/installations` with an App
JWT, or simply from the installation page URL. Write all three into the credentials file below.
Install it on the org:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-app-credentials
  namespace: actions-runner-system
type: Opaque
stringData:
  github_app_id: "<app-id>"
  github_app_installation_id: "<installation-id>"
  github_app_private_key: |
    -----BEGIN RSA PRIVATE KEY-----
    ...
    -----END RSA PRIVATE KEY-----
```

Cloud VMs only — `envs/shared/secrets.plain/hetzner-cloud-token.txt`: the Hetzner Cloud API
token, as a bare single-line file.

`envs/shared/secrets.plain/tailscale-api-key.txt` — a Tailscale **API key** (admin console →
Settings → Keys), as a bare single-line file. Admin SSH runs over Tailscale (only 443 is open
to the Internet); the provisioning scripts mint per-node auth keys from this API key
automatically.

Also confirm the operator has: an SSH key (`~/.ssh/id_ed25519`) and the CLIs
`kubectl helm sops age yq jq curl`.

## Step 6 — Encrypt and hand over

```bash
tools/sops/encrypt.sh <env>        # secrets.plain -> secrets.sops (committable)
```

Commit everything except `secrets.plain/` (verify with `git status` that nothing plaintext is
staged). Then run `/provision <env>`.
