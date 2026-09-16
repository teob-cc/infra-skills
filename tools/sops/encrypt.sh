#!/usr/bin/env bash
set -euo pipefail

# Encrypt plaintext secrets under envs/<ENV>/secrets.plain into envs/<ENV>/secrets.sops
# - YAML files (*.yml, *.yaml): encrypted as structured YAML (default sops mode)
# - Non-YAML files: encrypted with sops binary mode (--input-type binary --output-type binary)
# Optional: pass a specific FILE (basename like mysecret.yaml or any other file) to encrypt only that file.
# Requires: sops (https://github.com/getsops/sops)
# Keys: AGE recipients via $AGE_RECIPIENTS (comma-separated), otherwise the creation rules of the
#       nearest .sops.yaml at or above the envs root (i.e. the one in YOUR envs repo).
# Usage:
#   tools/sops/encrypt.sh [ENV] [FILE]
# Examples:
#   tools/sops/encrypt.sh                        # lists environments
#   tools/sops/encrypt.sh prod                   # encrypt all secrets in env
#   tools/sops/encrypt.sh shared cloudflare.yaml # encrypt only cloudflare.yaml
#   AGE_RECIPIENTS="age1..." tools/sops/encrypt.sh prod

list_environments() {
  local envs_dir="$1"
  echo "Available environments:"
  find "$envs_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;
}

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
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

# The creation rules (age recipients) live in the ENVS repo: the nearest .sops.yaml at or
# above the envs root. sops itself searches for the config from the current working
# directory, so running this script from anywhere else -- or from infra-skills, whose
# .sops.yaml is a placeholder template -- either fails or encrypts to the wrong recipient.
# Resolve it here and pass it explicitly.
SOPS_CONFIG=""
if [[ -z "${AGE_RECIPIENTS:-}" ]]; then
  d="$ENVS_ROOT"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/.sops.yaml" ]]; then SOPS_CONFIG="$d/.sops.yaml"; break; fi
    d="$(dirname "$d")"
  done
  if [[ -z "$SOPS_CONFIG" ]]; then
    echo "Error: no .sops.yaml found at or above $ENVS_ROOT and AGE_RECIPIENTS is unset." >&2
    echo "       Create one in the envs repo root (see the new-env skill, Step 4) or export AGE_RECIPIENTS." >&2
    exit 1
  fi
  if grep -qE 'REPLACE|PLACEHOLDER' "$SOPS_CONFIG"; then
    echo "Error: $SOPS_CONFIG still carries the placeholder recipient; put your own age public key in it." >&2
    exit 1
  fi
fi

# Encrypt into a temp file and replace the destination only once sops succeeded AND the
# output carries encryption metadata. A failed run used to truncate the destination
# first, leaving an empty file under secrets.sops that then got committed.
encrypt_one() {  # <src> <dst> <yaml|binary>
  local src="$1" dst="$2" mode="$3" tmp
  tmp="$(mktemp "${dst}.XXXXXX")"
  local -a args=(--encrypt)
  [[ "$mode" == binary ]] && args+=(--input-type binary --output-type binary)
  if [[ -n "${AGE_RECIPIENTS:-}" ]]; then
    # shellcheck disable=SC2086
    args+=(--age ${AGE_RECIPIENTS//,/ --age })
  else
    args+=(--config "$SOPS_CONFIG")
  fi
  if ! sops "${args[@]}" "$src" > "$tmp"; then
    rm -f "$tmp"
    echo "Error: sops failed on $(basename "$src"); $dst left untouched." >&2
    return 1
  fi
  if ! grep -qE '^sops:|ENC\[' "$tmp"; then
    rm -f "$tmp"
    echo "Error: sops produced no encrypted output for $(basename "$src"); $dst left untouched." >&2
    return 1
  fi
  mv "$tmp" "$dst"
}

mkdir -p "$ENCRYPTED_DIR"

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

failed=0
for src in "${files[@]}"; do
  [[ -f "$src" ]] || continue
  rel_name="$(basename "$src")"
  dst="$ENCRYPTED_DIR/$rel_name"
  case "$rel_name" in
    *.yml|*.yaml) mode=yaml ;;
    *)            mode=binary ;;
  esac
  if encrypt_one "$src" "$dst" "$mode"; then
    echo "Encrypted: $rel_name -> envs/$ENV_NAME/secrets.sops/$rel_name"
  else
    failed=1
  fi
done

if (( failed )); then
  echo "Done with errors; see above." >&2
  exit 1
fi
echo "Done. Encrypted files are in: envs/$ENV_NAME/secrets.sops"
