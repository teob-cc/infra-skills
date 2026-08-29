#!/usr/bin/env bash
set -euo pipefail

# Apply Kubernetes Secret manifests for an environment.
# Optional: pass a specific FILE (basename like mysecret.yaml) to apply only that file.
# Prefers plaintext if available (envs/<ENV>/secrets.plain) without decrypting.
# If plaintext is not present, and encrypted files exist (envs/<ENV>/secrets.sops),
# decrypts them to a temp dir and applies with kubectl.
# Assumes kubectl context is already configured for the target cluster.
# Usage:
#   tools/apply.sh [ENV] [FILE]
# Example:
#   tools/apply.sh hetzner06
#   tools/apply.sh shared cloudflare.yaml

ENV_NAME=${1:-hetzner06}
FILE_NAME=${2:-}
REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)
PLAINTEXT_DIR="$ENVS_ROOT/$ENV_NAME/secrets.plain"
ENCRYPTED_DIR="$ENVS_ROOT/$ENV_NAME/secrets.sops"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl not found in PATH." >&2
  exit 1
fi

apply_target=""

# 1) Prefer plaintext dir if present
if [[ -d "$PLAINTEXT_DIR" ]]; then
  if [[ -n "$FILE_NAME" ]]; then
    if [[ -f "$PLAINTEXT_DIR/$FILE_NAME" ]]; then
      apply_target="$PLAINTEXT_DIR/$FILE_NAME"
    elif [[ -d "$ENCRYPTED_DIR" && -f "$ENCRYPTED_DIR/$FILE_NAME" ]]; then
      # plaintext missing specific file; fall back to decrypting that file
      if ! command -v sops >/dev/null 2>&1; then
        echo "Error: sops not installed but need to decrypt: $ENCRYPTED_DIR/$FILE_NAME" >&2
        exit 1
      fi
      echo "Plaintext file missing; decrypting the encrypted file: $FILE_NAME"
      out_dir="$("$REPO_ROOT/tools/sops/decrypt.sh" "$ENV_NAME" "$FILE_NAME" | tail -n 1)"
      apply_target="$out_dir/$FILE_NAME"
      [[ -f "$apply_target" ]] || { echo "Error: expected decrypted file not found: $apply_target" >&2; exit 1; }
    else
      echo "Error: file not found in plaintext or encrypted dirs: $FILE_NAME" >&2
      exit 1
    fi
  else
    if compgen -G "$PLAINTEXT_DIR/*.y*ml" >/dev/null; then
      apply_target="$PLAINTEXT_DIR"
    else
      # No YAML in plaintext; try encrypted
      if [[ -d "$ENCRYPTED_DIR" ]] && compgen -G "$ENCRYPTED_DIR/*.y*ml" >/dev/null; then
        if ! command -v sops >/dev/null 2>&1; then
          echo "Error: sops not installed but encrypted secrets present: $ENCRYPTED_DIR" >&2
          exit 1
        fi
        echo "No YAML in plaintext. Decrypting from $ENCRYPTED_DIR..."
        out_dir="$("$REPO_ROOT/tools/sops/decrypt.sh" "$ENV_NAME" | tail -n 1)"
        apply_target="$out_dir"
      else
        echo "No YAML files to apply in $PLAINTEXT_DIR and no encrypted YAML in $ENCRYPTED_DIR" >&2
        exit 0
      fi
    fi
  fi

# 2) If no plaintext dir, use encrypted if available
elif [[ -d "$ENCRYPTED_DIR" ]] && compgen -G "$ENCRYPTED_DIR/*.y*ml" >/dev/null; then
  if ! command -v sops >/dev/null 2>&1; then
    echo "Error: sops not installed but encrypted secrets present: $ENCRYPTED_DIR" >&2
    exit 1
  fi
  echo "Plaintext dir missing; decrypting from $ENCRYPTED_DIR..."
  if [[ -n "$FILE_NAME" ]]; then
    out_dir="$("$REPO_ROOT/tools/sops/decrypt.sh" "$ENV_NAME" "$FILE_NAME" | tail -n 1)"
    apply_target="$out_dir/$FILE_NAME"
    [[ -f "$apply_target" ]] || { echo "Error: expected decrypted file not found: $apply_target" >&2; exit 1; }
  else
    out_dir="$("$REPO_ROOT/tools/sops/decrypt.sh" "$ENV_NAME" | tail -n 1)"
    apply_target="$out_dir"
  fi

# 3) Neither plaintext nor encrypted
else
  echo "Error: no secrets directory found for env '$ENV_NAME'." >&2
  echo "Checked: $PLAINTEXT_DIR and $ENCRYPTED_DIR" >&2
  exit 1
fi

set -x
kubectl apply -f "$apply_target"
set +x

if [[ -d "$apply_target" ]]; then
  echo "Secrets applied from: $apply_target"
else
  echo "Secret applied: $apply_target"
fi