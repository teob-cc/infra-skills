# Evaluator Key Intake — Bare-Metal Lease Path

You are an **external evaluator** standing up your K3s platform on a Hetzner
**dedicated (bare-metal) server** you lease yourself. This guide is a first-principles walk
through every secret the provisioning scripts read, grounded in the exact filenames and field
names the code expects. A wrong filename or a wrong YAML key silently breaks the run — so each
section quotes the function that consumes the file.

## How secrets flow (and why the control plane never sees them)

You bring four provider credential sets (Hetzner, Cloudflare, GitHub, Tailscale) plus a domain and two
locally generated keypairs. They all land as plaintext in a **git-ignored** `secrets.plain/`
directory inside your own private `infra-envs` repo, then get SOPS-encrypted into `secrets.sops/`
(the only form ever committed). The private age key that can decrypt them stays on your machine at
`~/.config/sops/age/keys.txt` and is never committed. This is the sovereignty guarantee: the
control plane and this repo only ever hold ciphertext you alone can open.

Before filling anything in, scaffold the environment with the **`new-env`** skill
(`.claude/skills/new-env/SKILL.md`). It creates the `infra-envs` layout, the `.gitignore` entry
`**/secrets.plain/`, the `.sops.yaml`, and stub secret files. This document tells you exactly
what to put in each stub.

### Directory layout (resolved by `provision::envs_root`)

The scripts resolve the envs root as `INFRA_ENVS_ROOT` → sibling `../infra-envs/envs` → in-repo
`./envs`. Paths below are relative to that root:

```
envs/
  shared/secrets.plain/
    hetzner-webservice-user.txt      # Hetzner Robot API user
    tailscale-api-key.txt            # Tailscale API token
    cloudflare.yaml                  # Cloudflare API token
    github-app-credentials.yaml      # GitHub App (CI automation)
  <env>/
    env.properties                   # HOSTNAME, EXTERNAL_IP, VLAN_IP, ACME_EMAIL
    secrets.plain/
      github-oauth-credentials.yaml  # GitHub OAuth App (Dex SSO)
```

> `<env>` is your short environment name (e.g. `eval`, `prod`). `shared/` secrets are reused
> across every environment; per-env secrets live under `envs/<env>/`.

---

## Key set 1 — Hetzner Robot (bare-metal)

**What & why.** Hetzner's *Robot* is the dedicated-server control panel (distinct from Hetzner
*Cloud*). The bare-metal script drives the Robot **webservice API** at
`https://robot-ws.your-server.de` to: check/enable **rescue mode**, register your provisioning
**SSH key**, set **reverse DNS**, and trigger the OS reinstall via `installimage`. All of that
authenticates with a *webservice user*, which is a separate credential from your Hetzner account
login.

**In the provider console.**
1. Order a **dedicated server** in Hetzner Robot (e.g. an AX-line box). Bare-metal here assumes
   two NVMe disks — the script lays down LVM-on-RAID1 across `nvme0n1` + `nvme1n1` with Ubuntu
   24.04.
2. In Robot → **Settings → Webservice and app settings**, create/enable the **webservice user**
   and set its password. This is the user + password the API calls use.
3. `EXTERNAL_IP` is the **main public IPv4** of the server as shown on its Robot server page —
   copy it into `env.properties` (see Key set 4). The script reinstalls the OS on exactly this IP,
   so double-check it.
4. You do **not** need to register your SSH key by hand — the script computes your public key and
   POSTs it to the Robot key store automatically (`robot::add_pubkey`) if it is missing. Manual
   registration in Robot → **Keys** is the fallback if the auto-add fails.

**Scopes.** The webservice user has full Robot API access to servers in your account; there is no
finer-grained scoping. Treat it as highly privileged.

**File — `envs/shared/secrets.plain/hetzner-webservice-user.txt`.**
Read by `robot::read_credentials` in `tools/provision-hetzner-baremetal.sh`. Two accepted shapes
(the parser looks for a `:` on line 1; otherwise it reads two lines):

```
# Option A — single line, user and password separated by a colon
your-webservice-user:your-webservice-password
```

```
# Option B — two lines: user on line 1, password on line 2
your-webservice-user
your-webservice-password
```

Plain text, no YAML. This file is **not** encrypted as a Kubernetes Secret — it is a bare text
file (SOPS binary mode; see the encrypt step).

**Encrypt.**
```bash
tools/sops/encrypt.sh shared hetzner-webservice-user.txt
```

---

## Key set 2 — Cloudflare (DNS)

**What & why.** The scripts manage DNS for you: they create/update the A record for `<HOSTNAME>`
and the wildcard `*.<HOSTNAME>` pointing at `EXTERNAL_IP`, so every `<service>.<HOSTNAME>` host
resolves. cert-manager later completes Let's Encrypt HTTP/DNS challenges against those names. Your
domain's DNS must therefore be hosted on Cloudflare.

**In the provider console.** Cloudflare dashboard → **My Profile → API Tokens → Create Token**.
Use a **scoped** token, not the global API key.

**Scopes.**
- **Zone → DNS → Edit** (create/update A records)
- **Zone → Zone → Read** (the scripts look the zone up by name via `/zones?name=<domain>`)
- Zone Resources: **Include → Specific zone → your domain**.

**File — `envs/shared/secrets.plain/cloudflare.yaml`.**
Read by `cloudflare::read_token` (in `provision-hetzner-baremetal.sh`) and
`provision::cloudflare_read_token` (in `provision-common.sh`). The parser greps for a key matching
`cloudflare-api-token` / `api-token` / `token` / `api-key`, so use the canonical key:

```yaml
cloudflare-api-token: "<your-scoped-cloudflare-api-token>"
```

> Note: this file is a plain YAML key/value, **not** a Kubernetes Secret manifest — there is no
> `stringData` wrapper here. The `.sops.yaml` rule encrypts the whole file since it has no
> `data`/`stringData` block to target selectively; it is committed only as ciphertext.

**Encrypt.**
```bash
tools/sops/encrypt.sh shared cloudflare.yaml
```

---

## Key set 3 — GitHub org: App + OAuth App

You create **two distinct GitHub applications** in your org, for two different jobs:

- a **GitHub App** — CI automation (self-hosted Actions runners, ArgoCD repo access, org secrets).
- a **GitHub OAuth App** — human SSO login through Dex (Argo CD, Grafana, Harbor, etc.).

Both live in **your own GitHub org** — that org gates SSO membership and hosts the CI runners.

### 3a — GitHub App (CI automation)

**In the console.** `https://github.com/organizations/<org>/settings/apps` → **New GitHub App**.
After creating it: note the **App ID**, generate a **private key** (downloads a `.pem`), then
**Install** the App on your org and note the **Installation ID** (it is the number in the
installation settings URL).

**Permissions** (from the `new-env` skill):
- Repository → **Contents: Read & write**
- Repository → **Secrets: Read & write**
- Repository → **Environments: Read & write**
- Repository → **Metadata: Read-only**
- Organization → **Self-hosted runners: Read & write**

**File — `envs/shared/secrets.plain/github-app-credentials.yaml`.**
Read by `provision::github_read_credentials` in `tools/provision-common.sh`, which pulls exactly
these three paths with `yq`: `.stringData.githubAppID`, `.stringData.githubAppInstallationID`,
`.stringData.githubAppPrivateKey`. The same camelCase keys are read by `argocd.sh`,
`github-action-runner.sh`, `registry-credentials.sh`, and `provision-org-secrets.sh`.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-app-credentials
  namespace: actions-runner-system
type: Opaque
stringData:
  githubAppID: "<app-id>"
  githubAppInstallationID: "<installation-id>"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    ...paste the full downloaded .pem here, indented under the block scalar...
    -----END RSA PRIVATE KEY-----
```

> ⚠️ **Field names must be camelCase.** The scripts read `githubAppID` /
> `githubAppInstallationID` / `githubAppPrivateKey`. (The `new-env` skill's example currently
> shows snake_case `github_app_id` etc.; that snake_case form is only how the runner script
> *emits* the in-cluster Secret — the intake file you write here must use the camelCase keys the
> readers expect, or every GitHub-dependent step gets empty values.)

**Encrypt** (this file has a `stringData` block, so SOPS encrypts only those values):
```bash
tools/sops/encrypt.sh shared github-app-credentials.yaml
```

### 3b — GitHub OAuth App (Dex SSO)

**In the console.** `https://github.com/organizations/<org>/settings/applications` → **New OAuth
App**. Set:
- **Authorization callback URL:** `https://dex.<HOSTNAME>/callback` (exactly — this is Dex's
  redirect URI; `<HOSTNAME>` is your base domain from `env.properties`).
- After creating it, note the **Client ID** and generate a **Client secret**.

An OAuth App has no permission checkboxes; org membership is what gates who may log in.

**File — `envs/<env>/secrets.plain/github-oauth-credentials.yaml`** (per-environment, not shared).
Read by `provision::github_read_credentials` when `ENV_NAME` is set, via `.stringData.githubClientID`,
`.stringData.githubClientSecret`, `.stringData.githubOrg`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-oauth-credentials
type: Opaque
stringData:
  githubClientID: "<oauth-app-client-id>"
  githubClientSecret: "<oauth-app-client-secret>"
  githubOrg: "<your-github-org>"
```

**Encrypt.**
```bash
tools/sops/encrypt.sh <env> github-oauth-credentials.yaml
```

---

## Supporting inputs

### Domain + ACME email → `envs/<env>/env.properties`

`provision-hetzner-baremetal.sh` sources this file and requires `HOSTNAME`, `EXTERNAL_IP`,
`VLAN_IP` (checked in `REQUIRED=(HOSTNAME EXTERNAL_IP VLAN_IP)`). `ACME_EMAIL` is required later by
`tools/k3s/identity.sh` (`: "${ACME_EMAIL:?...}"`) for Let's Encrypt registration.

```properties
HOSTNAME=eval.example.com          # base domain; every service host is <service>.eval.example.com
EXTERNAL_IP=1.2.3.4                 # main public IPv4 from the Hetzner Robot server page
VLAN_IP=192.168.100.1              # internal VLAN 4000 address; /24 assumed if CIDR omitted
ACME_EMAIL=you@example.com         # Let's Encrypt contact
```

`env.properties` holds no secrets, so it is committed in the clear (not under `secrets.plain/`).

### Tailscale API token → `envs/shared/secrets.plain/tailscale-api-key.txt`

**What & why.** Admin SSH to the node runs over Tailscale, not the public Internet (UFW only
opens 443/tcp inbound). You supply a Tailscale **API access token**; the script then *mints
short-lived node auth keys itself* via `tailscale::create_authkey` — you do **not** hand it a
node auth key directly.

**In the console.** Tailscale admin → **Settings → Keys → Generate access token**. The value
starts with `tskey-api`.

**File shape.** Read by `tailscale::read_api_token`; validated to start with `tskey-api`. Bare
single line, no YAML:

```
tskey-api-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**Encrypt.**
```bash
tools/sops/encrypt.sh shared tailscale-api-key.txt
```

### age keypair (SOPS) → `~/.config/sops/age/keys.txt`

Used to encrypt/decrypt everything above. `provision::validate_local_keys` looks for it at
`$SOPS_AGE_KEY_FILE` or the default `~/.config/sops/age/keys.txt`.

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt     # generates the private key
age-keygen -y ~/.config/sops/age/keys.txt     # prints your PUBLIC recipient (age1...)
```

Put the **public** recipient into `.sops.yaml` at your `infra-envs` root, replacing the
placeholder `age1REPLACE_WITH_YOUR_OWN_RECIPIENT` in **both** `age:` lists. The template ships an
intentionally invalid recipient so a verbatim copy fails loudly rather than encrypting to
someone else's key. The private key never leaves your machine.

### SSH keypair → `~/.ssh/id_ed25519`

`provision::default_ssh_key_base` prefers `~/.ssh/id_ed25519` (falls back to `~/.ssh/id_rsa`). The
public key is auto-registered into the Hetzner Robot key store for rescue-mode access.

```bash
ssh-keygen -t ed25519 -C "eval-provisioning" -f ~/.ssh/id_ed25519
```

---

## Pre-flight checklist

Verify each row before running `tools/provision-hetzner-baremetal.sh <env> --wipe`.

| File / value | Exact path | Consumed by (verified) |
|---|---|---|
| Hetzner Robot user:pass | `envs/shared/secrets.plain/hetzner-webservice-user.txt` | `robot::read_credentials` in `provision-hetzner-baremetal.sh` |
| Tailscale API token (`tskey-api…`) | `envs/shared/secrets.plain/tailscale-api-key.txt` | `tailscale::read_api_token` in `provision-hetzner-baremetal.sh` |
| Cloudflare token (`cloudflare-api-token:`) | `envs/shared/secrets.plain/cloudflare.yaml` | `cloudflare::read_token` / `provision::cloudflare_read_token` |
| GitHub App (`githubAppID` / `githubAppInstallationID` / `githubAppPrivateKey`) | `envs/shared/secrets.plain/github-app-credentials.yaml` | `provision::github_read_credentials` (+ argocd/runner/registry/org-secrets scripts) |
| GitHub OAuth App (`githubClientID` / `githubClientSecret` / `githubOrg`) | `envs/<env>/secrets.plain/github-oauth-credentials.yaml` | `provision::github_read_credentials` (when `ENV_NAME` set) |
| `HOSTNAME` / `EXTERNAL_IP` / `VLAN_IP` | `envs/<env>/env.properties` | `provision-hetzner-baremetal.sh` (`REQUIRED=(...)`) |
| `ACME_EMAIL` | `envs/<env>/env.properties` | `tools/k3s/identity.sh` |
| age private key + `.sops.yaml` recipient | `~/.config/sops/age/keys.txt`; `.sops.yaml` | `provision::validate_local_keys`; SOPS |
| SSH keypair | `~/.ssh/id_ed25519` (+ `.pub`) | `provision::default_ssh_key_base`; Robot key auto-registration |

Then confirm nothing plaintext is staged for commit and that the ciphertext exists:

```bash
tools/sops/encrypt.sh shared          # encrypt all shared secrets at once
tools/sops/encrypt.sh <env>           # encrypt the env's secrets (github-oauth-credentials.yaml)
git status                            # secrets.plain/ must be git-ignored; only secrets.sops/ committed
```

**Automated verification (TEO-127):** once available, run `tools/validate-keys.sh <env>` to check
that every file above exists, parses, and carries the expected fields — before you kick off
provisioning. Until then, walk the table by hand.
