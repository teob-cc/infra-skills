### What these scripts do
- `tools/sops/encrypt.sh [ENV] [FILE]`
    - Encrypts files from `envs/<ENV>/secrets.plain/` into `envs/<ENV>/secrets.sops/` (same filenames).
    - YAML files (`*.yaml`, `*.yml`) use structured sops encryption.
    - Non‑YAML files use sops binary mode (`--input-type binary --output-type binary`).
    - If `FILE` is provided (e.g., `cloudflare.yaml` or any other filename), only that file is encrypted.
    - Uses your SOPS config (`.sops.yaml`) or `AGE_RECIPIENTS` to determine recipients.

- `tools/sops/decrypt.sh [ENV] [FILE] [OUT_DIR]`
    - Decrypts files from `envs/<ENV>/secrets.sops/` into a target directory.
    - YAML files use standard sops decrypt; non‑YAML uses binary mode.
    - If `FILE` is provided, only that file is decrypted. If the 2nd arg looks like a path, it's treated as `OUT_DIR`.
    - Default `OUT_DIR` is `envs/<ENV>/secrets.plain/`.
    - Safety: if a destination exists and is newer than the source, it will not be overwritten unless you pass `--force`.
    - Prints the output directory path at the end.

- `tools/sops/apply.sh [ENV] [FILE]`
    - Prefers applying plaintext YAML from `envs/<ENV>/secrets.plain/` and will NOT decrypt if that directory exists (and contains YAML or the specified file).
    - If plaintext is missing (or the requested file is absent there), falls back to decrypting from `envs/<ENV>/secrets.sops/` to a temp dir and applies from there.
    - Only YAML is applied via `kubectl apply -f ...`.
    - Assumes your `kubectl` context already points to the target cluster.

### Prerequisites
- Install SOPS and age
    - macOS (brew): `brew install sops age`
    - Linux (Debian/Ubuntu): `sudo apt-get install -y sops` and download age release or `sudo apt-get install -y age`
- Generate an age key pair (for decryption)
    - `mkdir -p ~/.config/sops/age`
    - `age-keygen -o ~/.config/sops/age/keys.txt`
    - Show your public key (recipient) to share: `age-keygen -y ~/.config/sops/age/keys.txt`
    - SOPS reads `~/.config/sops/age/keys.txt` automatically. Alternatively set `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`.

### Recommended Git hygiene for this repo
- Keep plaintext out of Git. Ensure plaintext secrets are ignored:
    - Add to `.gitignore`: `/envs/*/secrets.plain/`
- Commit only the encrypted copies under `secrets.sops/` and never commit files from `secrets.plain/`.

### Where `.sops.yaml` goes and why it matters
- Put `.sops.yaml` at the repository root (same directory as `tools/` and `envs/`). SOPS looks for `.sops.yaml` in the current directory and up the directory tree.
- Having it:
    - Avoids the warning: “Neither AGE_RECIPIENTS nor .sops.yaml found.”
    - Defines which keys SOPS should encrypt to when creating or re-encrypting files.
    - Optionally restricts which YAML fields get encrypted.

### Minimal `.sops.yaml` for this layout (single set of recipients)
Put this file at your repo root: `.sops.yaml`

```yaml
# Encrypt any YAML under envs/*/secrets.sops/ to these age recipients
creation_rules:
  - path_regex: envs/.*/secrets\.sops/.*\.(yaml|yml)$
    # Only encrypt Kubernetes Secret payloads (common pattern)
    encrypted_regex: '^(data|stringData)$'
    age: [
      'age1EXAMPLEUSERPUBLICKEYAAAAAAAAAAAAAAA',  # your user public key
      'age1EXAMPLECIPUBLICKEYBBBBBBBBBBBBBBBBB'   # optional CI key so automation can decrypt
    ]
```

Notes:
- Replace the two `age1...` values with real recipients. You can have one or many.
- `encrypted_regex` ensures metadata remains plaintext in Git while only `data`/`stringData` contents are encrypted. Remove it to encrypt entire files.

### Per-environment recipients (optional)
If each environment should be encrypted to a different team/key, use multiple rules. SOPS picks the first matching rule.

```yaml
creation_rules:
  - path_regex: envs/cit/secrets\.sops/.*\.(yaml|yml)$
    encrypted_regex: '^(data|stringData)$'
    age: [ 'age1HETZNER06USER...', 'age1CI...' ]

  - path_regex: envs/prod/secrets\.sops/.*\.(yaml|yml)$
    encrypted_regex: '^(data|stringData)$'
    age: [ 'age1PRODUSER...', 'age1CI...' ]

  - path_regex: envs/.*/secrets\.sops/.*\.(yaml|yml)$
    encrypted_regex: '^(data|stringData)$'
    age: [ 'age1DEFAULTFALLOVER...' ]
```

### Using the scripts
- First-time setup (once per repo or when keys change)
    1) Create `.sops.yaml` at repo root with the desired recipients (see above). Commit it.
    2) Ensure every human/automation that must decrypt has the matching private key (their `keys.txt` file).

- Encrypt plaintext secrets for an env
    - Place or edit plaintext Secret manifests in `envs/<ENV>/secrets.plain/` (YAML) and any additional non‑YAML files you want encrypted.
    - Run: `tools/sops/encrypt.sh <ENV>`
        - Example: `tools/sops/encrypt.sh cit`
    - Or a single file: `tools/sops/encrypt.sh shared cloudflare.yaml`
    - Result: encrypted copies end up in `envs/<ENV>/secrets.sops/` with the same filenames.

- Decrypt when you need to inspect or apply manually
    - All files (default out dir): `tools/sops/decrypt.sh cit`
    - One file: `tools/sops/decrypt.sh shared cloudflare.yaml`
    - Custom out dir: `tools/sops/decrypt.sh cit /tmp/hetz-secrets`
    - Overwrite newer targets: `tools/sops/decrypt.sh --force cit`
    - The script prints the output directory; files in there are plaintext.

- Apply to the cluster (prefers plaintext)
    - Ensure your `kubectl` context points to the correct cluster.
    - `tools/sops/apply.sh cit`
    - If `secrets.plain/` exists, it applies YAML from there without decrypting. Otherwise it decrypts from `secrets.sops/` and applies.

### Alternative without `.sops.yaml` (quick test)
- You can skip `.sops.yaml` and pass recipients via env var once:
    - `AGE_RECIPIENTS="age1USER...,age1CI..." tools/sops/encrypt.sh cit`
- Long-term, `.sops.yaml` is better for consistency and to avoid mistakes.

### Editing encrypted files directly (optional workflow)
- Standard SOPS workflow is to edit encrypted files in place: `sops envs/<ENV>/secrets.sops/foo.yaml`
    - Saves back encrypted, decrypting transparently in your editor.
- Your scripts also support a “source-of-truth plaintext” workflow where you keep local plaintext in `envs/<ENV>/secrets.plain/` and generate the encrypted copies for Git. Pick the workflow your team prefers, but don’t commit plaintext.

### CI/CD decryption
- In CI, provide a decryption key via secret storage and set `SOPS_AGE_KEY_FILE` to the key path.
- Then simply run:
    - `tools/sops/decrypt.sh cit` → get a dir path
    - `kubectl apply -f <that-dir>` (or just `tools/sops/apply.sh cit`)

### Troubleshooting
- Warning about missing config: If you see
    - `Warning: Neither AGE_RECIPIENTS env var nor .sops.yaml found.`
    - Fix by setting `AGE_RECIPIENTS` for the command or adding `.sops.yaml` at repo root.
- “sops: command not found”: install SOPS (`brew install sops` or OS package).
- “failed to decrypt” errors in CI: ensure the CI has the correct private key and `SOPS_AGE_KEY_FILE` points to it.
- macOS default bash: The scripts are compatible with Bash 3 (macOS default).

### Quick start checklist
1) Generate your age key and note the public recipient: `age-keygen -y ~/.config/sops/age/keys.txt`
2) Create `.sops.yaml` at repo root with that recipient (and any CI recipient).
3) Put plaintext K8s Secrets into `envs/cit/secrets.plain/*.yaml`.
4) Run `tools/sops/encrypt.sh cit`.
5) Commit `envs/cit/secrets.sops/*.yaml` and `.sops.yaml` (plaintext dir stays ignored).
6) Apply: `tools/sops/apply.sh cit`.

If you share your actual age recipient(s), I can craft a tailored `.sops.yaml` block for your repo.