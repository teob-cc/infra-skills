#!/usr/bin/env bash
set -euo pipefail

# Decrypt SOPS-encrypted secrets under envs/<ENV>/secrets.sops into a target directory.
# - YAML files (*.yml, *.yaml): standard sops YAML decrypt
# - Non-YAML files: sops binary mode (--input-type binary --output-type binary)
# Optional: pass a specific FILE (basename) to decrypt only that file.
# Default output: envs/<ENV>/secrets.plain
# Safety: if destination file exists and is newer than the source, it will NOT be overwritten unless --force is used.
# Requires: sops
# Usage:
#   tools/decrypt.sh [--force] [ENV] [FILE] [OUT_DIR]
# Backward compatibility:
#   tools/decrypt.sh [ENV] [OUT_DIR]          # if 2nd arg looks like a path or dir, treat as OUT_DIR
# Examples:
#   tools/decrypt.sh hetzner06                 # -> envs/hetzner06/secrets.plain (all files)
#   tools/decrypt.sh shared cloudflare.yaml    # -> only that file into default out dir
#   tools/decrypt.sh hetzner06 /tmp/outdir     # -> all files to custom out dir
#   tools/decrypt.sh --force shared            # -> overwrite newer targets

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
  shift
fi

ENV_NAME=${1:-hetzner06}
ARG2=${2:-}
ARG3=${3:-}
REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)
ENCRYPTED_DIR="$ENVS_ROOT/$ENV_NAME/secrets.sops"

# ---- Key discovery (age) ----
# If user hasn't set a key via env, fall back to the standard SOPS age key path.
DEFAULT_AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"
if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "$DEFAULT_AGE_KEY_FILE" ]]; then
  export SOPS_AGE_KEY_FILE="$DEFAULT_AGE_KEY_FILE"
fi

# If neither age key env nor SSH-plugin env is set, warn if default not found.
if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -z "${SOPS_AGE_KEY:-}" && -z "${SOPS_AGE_SSH_PRIVATE_KEY_FILE:-}" ]]; then
  if [[ ! -f "$DEFAULT_AGE_KEY_FILE" ]]; then
    echo "Error: No SOPS age key found." >&2
    echo "Looked for: \$SOPS_AGE_KEY_FILE, \$SOPS_AGE_KEY, \$SOPS_AGE_SSH_PRIVATE_KEY_FILE, and ${DEFAULT_AGE_KEY_FILE}" >&2
    echo "Tip: put your key at ${DEFAULT_AGE_KEY_FILE} or set SOPS_AGE_KEY_FILE explicitly." >&2
    exit 1
  fi
fi

# ---- Tooling checks ----
if ! command -v sops >/dev/null 2>&1; then
  echo "Error: sops is not installed. Please install it first." >&2
  exit 1
fi

# If user configured SSH recipients, ensure the age SSH plugin exists (best-effort)
if [[ -n "${SOPS_AGE_SSH_PRIVATE_KEY_FILE:-}" ]]; then
  if ! command -v age-plugin-ssh >/dev/null 2>&1; then
    echo "Warning: SOPS_AGE_SSH_PRIVATE_KEY_FILE is set but age-plugin-ssh is not installed; SSH recipients won't work." >&2
  fi
fi

# ---- Inputs & dirs ----
if [[ ! -d "$ENCRYPTED_DIR" ]]; then
  echo "Error: directory not found: $ENCRYPTED_DIR" >&2
  exit 1
fi

# Parse args: detect if ARG2 is a file in ENCRYPTED_DIR or an OUT_DIR
FILE_NAME=""
OUT_DIR=""
if [[ -n "$ARG2" ]]; then
  if [[ -f "$ENCRYPTED_DIR/$ARG2" ]]; then
    FILE_NAME="$ARG2"
    OUT_DIR="${ARG3:-}"
  elif [[ "$ARG2" == */* || -d "$ARG2" ]]; then
    # looks like a path or existing dir
    OUT_DIR="$ARG2"
  else
    # fallback: treat as file name if it has a yaml extension
    case "$ARG2" in
      *.yml|*.yaml)
        FILE_NAME="$ARG2"; OUT_DIR="${ARG3:-}" ;;
      *)
        # otherwise consider it an OUT_DIR name (relative allowed)
        OUT_DIR="$ARG2" ;;
    esac
  fi
fi

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$ENVS_ROOT/$ENV_NAME/secrets.plain"
fi
mkdir -p "$OUT_DIR"

# ---- Collect files ----
shopt -s nullglob
files=( )
if [[ -n "$FILE_NAME" ]]; then
  if [[ ! -f "$ENCRYPTED_DIR/$FILE_NAME" ]]; then
    echo "Error: file not found: $ENCRYPTED_DIR/$FILE_NAME" >&2
    exit 1
  fi
  files=( "$ENCRYPTED_DIR/$FILE_NAME" )
else
  files=( "$ENCRYPTED_DIR"/* )
fi

if (( ${#files[@]} == 0 )); then
  echo "No files found under $ENCRYPTED_DIR" >&2
  exit 0
fi

# ---- Decrypt ----
for src in "${files[@]}"; do
  [[ -f "$src" ]] || continue
  rel_name="$(basename "$src")"
  dst="$OUT_DIR/$rel_name"

  # Skip if target is newer than source and not forcing
  if [[ -f "$dst" && "$FORCE" -ne 1 ]]; then
    # cross-platform mtime: macOS/BSD uses stat -f %m, GNU uses stat -c %Y
    get_mtime() {
      if stat -f %m "$1" >/dev/null 2>&1; then
        stat -f %m "$1"
      else
        stat -c %Y "$1"
      fi
    }
    src_mtime="$(get_mtime "$src")" || src_mtime=0
    dst_mtime="$(get_mtime "$dst")" || dst_mtime=0
    if [[ "$dst_mtime" -gt "$src_mtime" ]]; then
      echo "Skip (newer target): $dst is newer than $src. Use --force to overwrite." >&2
      continue
    fi
  fi

  # Decrypt (stdout to file). Use a temp then atomic move to avoid partials.
  tmp="$(mktemp "$OUT_DIR/.${rel_name}.XXXXXX")"
  case "$rel_name" in
    *.yml|*.yaml)
      if ! sops --decrypt "$src" > "$tmp"; then
        echo "Failed to decrypt: $rel_name" >&2
        rm -f "$tmp"; exit 1
      fi
      ;;
    *)
      if ! sops --decrypt --input-type binary --output-type binary "$src" > "$tmp"; then
        echo "Failed to decrypt (binary): $rel_name" >&2
        rm -f "$tmp"; exit 1
      fi
      ;;
  esac
  mv -f "$tmp" "$dst"
  echo "Decrypted: $rel_name -> $dst"
done

echo "$OUT_DIR"
