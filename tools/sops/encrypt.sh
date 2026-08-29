#!/usr/bin/env bash
set -euo pipefail

# Encrypt plaintext secrets under envs/<ENV>/secrets.plain into envs/<ENV>/secrets.sops
# - YAML files (*.yml, *.yaml): encrypted as structured YAML (default sops mode)
# - Non-YAML files: encrypted with sops binary mode (--input-type binary --output-type binary)
# Optional: pass a specific FILE (basename like mysecret.yaml or any other file) to encrypt only that file.
# Requires: sops (https://github.com/getsops/sops)
# Keys: AGE recipients via $AGE_RECIPIENTS (comma-separated), or use rules from .sops.yaml if present
# Usage:
#   tools/encrypt.sh [ENV] [FILE]
# Examples:
#   tools/encrypt.sh                        # lists environments
#   tools/encrypt.sh hetzner06              # encrypt all secrets in env
#   tools/encrypt.sh shared cloudflare.yaml # encrypt only cloudflare.yaml
#   AGE_RECIPIENTS="age1..." tools/encrypt.sh hetzner06

list_environments() {
  local envs_dir="$1"
  echo "Available environments:"
  find "$envs_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;
}

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

if [[ -z "${1:-}" ]]; then
  list_environments "$ENVS_ROOT"
  exit 0
fi

ENV_NAME="${1}"
FILE_NAME="${2:-}"
if [[ ! -d "$ENVS_ROOT/$ENV_NAME" ]]; then
  echo "Error: environment '$ENV_NAME' not found" >&2
  list_environments "$ENVS_ROOT"
  exit 1
fi

PLAINTEXT_DIR="$ENVS_ROOT/$ENV_NAME/secrets.plain"
ENCRYPTED_DIR="$ENVS_ROOT/$ENV_NAME/secrets.sops"

if ! command -v sops >/dev/null 2>&1; then
  echo "Error: sops is not installed. Please install it first." >&2
  exit 1
fi

if [[ ! -d "$PLAINTEXT_DIR" ]]; then
  echo "Error: directory not found: $PLAINTEXT_DIR" >&2
  exit 1
fi

mkdir -p "$ENCRYPTED_DIR"

# If AGE_RECIPIENTS is not set and .sops.yaml is absent, warn the user.
if [[ -z "${AGE_RECIPIENTS:-}" ]] && [[ ! -f "$REPO_ROOT/.sops.yaml" ]]; then
  cat >&2 <<EOF
Warning: Neither AGE_RECIPIENTS env var nor .sops.yaml found.
SOPS will attempt to use its defaults, which may fail for new files.
Set AGE_RECIPIENTS or create a .sops.yaml with creation rules.
EOF
fi

shopt -s nullglob
files=( )
if [[ -n "$FILE_NAME" ]]; then
  if [[ ! -f "$PLAINTEXT_DIR/$FILE_NAME" ]]; then
    echo "Error: file not found: $PLAINTEXT_DIR/$FILE_NAME" >&2
    exit 1
  fi
  files=( "$PLAINTEXT_DIR/$FILE_NAME" )
else
  # Include all files in plaintext dir (YAML and non-YAML)
  files=( "$PLAINTEXT_DIR"/* )
fi

if (( ${#files[@]} == 0 )); then
  echo "No files found under $PLAINTEXT_DIR" >&2
  exit 0
fi

for src in "${files[@]}"; do
  [[ -f "$src" ]] || continue
  rel_name="$(basename "$src")"
  dst="$ENCRYPTED_DIR/$rel_name"

  # Choose mode based on extension
  case "$rel_name" in
    *.yml|*.yaml)
      if [[ -n "${AGE_RECIPIENTS:-}" ]]; then
        # shellcheck disable=SC2086
        sops --encrypt --age ${AGE_RECIPIENTS//,/ --age } "$src" > "$dst"
      else
        sops --encrypt "$src" > "$dst"
      fi
      ;;
    *)
      if [[ -n "${AGE_RECIPIENTS:-}" ]]; then
        # shellcheck disable=SC2086
        sops --encrypt --input-type binary --output-type binary --age ${AGE_RECIPIENTS//,/ --age } "$src" > "$dst"
      else
        sops --encrypt --input-type binary --output-type binary "$src" > "$dst"
      fi
      ;;
  esac

  echo "Encrypted: $rel_name -> envs/$ENV_NAME/secrets.sops/$rel_name"
done

echo "Done. Encrypted files are in: envs/$ENV_NAME/secrets.sops"
