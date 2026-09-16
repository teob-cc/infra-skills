#!/usr/bin/env bash
# Apply the Kubernetes Secret manifests of an environment to the CURRENT kubectl context.
#
# Source of truth is envs/<ENV>/secrets.sops (the committed, age-encrypted set). It is
# decrypted into a private temp dir and applied from there; envs/<ENV>/secrets.plain is
# only a working copy. When both exist the script compares them and warns about
#   - plaintext files with no encrypted counterpart (not applied: they were never
#     committed -- run tools/sops/encrypt.sh <ENV> <file>), and
#   - plaintext files whose values differ from the encrypted ones (encrypted wins).
# That ordering exists because a stale secrets.plain once shadowed the committed set:
# it lacked nine committed files and still carried five for an app that no longer existed.
#
# Usage:
#   tools/sops/apply.sh [--plain] [--dry-run] <ENV> [FILE]
#     FILE       basename (e.g. mysecret.yaml) to apply only that file
#     --plain    apply secrets.plain instead (write-first workflow: you just created a
#                secret and have not encrypted it yet)
#     --dry-run  kubectl apply --dry-run=client; nothing reaches the cluster
# Examples:
#   tools/sops/apply.sh prod
#   tools/sops/apply.sh shared cloudflare.yaml
#   tools/sops/apply.sh --plain cit new-app-secret.yaml
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

USE_PLAIN=0; DRY_RUN=""; ENV_NAME=""; FILE_NAME=""
for arg in "$@"; do
  case "$arg" in
    --plain)   USE_PLAIN=1 ;;
    --dry-run) DRY_RUN="--dry-run=client" ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) if [[ -z "$ENV_NAME" ]]; then ENV_NAME="$arg"; elif [[ -z "$FILE_NAME" ]]; then FILE_NAME="$arg"; else
         echo "Error: unexpected argument '$arg'" >&2; exit 1; fi ;;
  esac
done
[[ -n "$ENV_NAME" ]] || { echo "Usage: $0 [--plain] [--dry-run] <ENV> [FILE]" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl not found in PATH." >&2; exit 1; }

PLAINTEXT_DIR="$ENVS_ROOT/$ENV_NAME/secrets.plain"
ENCRYPTED_DIR="$ENVS_ROOT/$ENV_NAME/secrets.sops"
has_yaml() { compgen -G "$1/*.y*ml" >/dev/null 2>&1; }

# Normalised value view of a Secret manifest, so formatting differences (data vs
# stringData, key order, comments) do not count as drift -- only values do.
secret_values() {
  yq -o=json '.' "$1" 2>/dev/null | jq -S '{name: .metadata.name, ns: (.metadata.namespace // "default"),
    v: (((.stringData // {}) + ((.data // {}) | with_entries(.value |= @base64d))))}'
}

apply_target=""
tmp_dir=""
cleanup() { [[ -n "$tmp_dir" ]] && rm -rf "$tmp_dir"; }
trap cleanup EXIT

if [[ "$USE_PLAIN" -eq 1 ]]; then
  [[ -d "$PLAINTEXT_DIR" ]] || { echo "Error: --plain given but $PLAINTEXT_DIR does not exist" >&2; exit 1; }
  if [[ -n "$FILE_NAME" ]]; then
    apply_target="$PLAINTEXT_DIR/$FILE_NAME"
    [[ -f "$apply_target" ]] || { echo "Error: $apply_target not found" >&2; exit 1; }
  else
    has_yaml "$PLAINTEXT_DIR" || { echo "Error: no YAML in $PLAINTEXT_DIR" >&2; exit 1; }
    apply_target="$PLAINTEXT_DIR"
  fi
  echo "Applying PLAINTEXT secrets from $PLAINTEXT_DIR (--plain). Encrypt and commit them afterwards."

elif [[ -d "$ENCRYPTED_DIR" ]] && has_yaml "$ENCRYPTED_DIR"; then
  command -v sops >/dev/null 2>&1 || { echo "Error: sops not installed but encrypted secrets present: $ENCRYPTED_DIR" >&2; exit 1; }
  tmp_dir="$(mktemp -d -t sops-apply-XXXXXX)"; chmod 700 "$tmp_dir"
  if [[ -n "$FILE_NAME" ]]; then
    [[ -f "$ENCRYPTED_DIR/$FILE_NAME" ]] || {
      if [[ -f "$PLAINTEXT_DIR/$FILE_NAME" ]]; then
        echo "Error: $FILE_NAME exists only in secrets.plain (never encrypted/committed)." >&2
        echo "       Either: tools/sops/encrypt.sh $ENV_NAME $FILE_NAME   or apply it with --plain." >&2
      else
        echo "Error: $FILE_NAME not found in $ENCRYPTED_DIR" >&2
      fi; exit 1; }
    "$REPO_ROOT/tools/sops/decrypt.sh" --force "$ENV_NAME" "$FILE_NAME" "$tmp_dir" >/dev/null || { echo "Error: decrypt failed" >&2; exit 1; }
    apply_target="$tmp_dir/$FILE_NAME"
  else
    "$REPO_ROOT/tools/sops/decrypt.sh" --force "$ENV_NAME" "$tmp_dir" >/dev/null || { echo "Error: decrypt failed" >&2; exit 1; }
    apply_target="$tmp_dir"
  fi
  echo "Applying secrets decrypted from $ENCRYPTED_DIR"

  # Drift report against the plaintext working copy, if there is one.
  if [[ -d "$PLAINTEXT_DIR" ]]; then
    unencrypted=(); differing=()
    for p in "$PLAINTEXT_DIR"/*.y*ml; do
      [[ -f "$p" ]] || continue
      b="$(basename "$p")"
      [[ -n "$FILE_NAME" && "$b" != "$FILE_NAME" ]] && continue
      if [[ ! -f "$ENCRYPTED_DIR/$b" ]]; then unencrypted+=("$b"); continue; fi
      [[ -f "$tmp_dir/$b" ]] || continue
      if [[ "$(secret_values "$p")" != "$(secret_values "$tmp_dir/$b")" ]]; then differing+=("$b"); fi
    done
    if (( ${#unencrypted[@]} )); then
      echo "WARNING: in secrets.plain but never encrypted -> NOT applied:" >&2
      printf '         %s\n' "${unencrypted[@]}" >&2
      echo "         tools/sops/encrypt.sh $ENV_NAME <file>   (or apply with --plain)" >&2
    fi
    if (( ${#differing[@]} )); then
      echo "WARNING: plaintext values differ from the encrypted (applied) ones:" >&2
      printf '         %s\n' "${differing[@]}" >&2
      echo "         refresh the working copy: tools/sops/decrypt.sh --force $ENV_NAME" >&2
    fi
  fi

elif [[ -d "$PLAINTEXT_DIR" ]] && has_yaml "$PLAINTEXT_DIR"; then
  echo "No encrypted secrets for '$ENV_NAME'; applying plaintext from $PLAINTEXT_DIR (encrypt them: tools/sops/encrypt.sh $ENV_NAME)"
  if [[ -n "$FILE_NAME" ]]; then
    apply_target="$PLAINTEXT_DIR/$FILE_NAME"
    [[ -f "$apply_target" ]] || { echo "Error: $apply_target not found" >&2; exit 1; }
  else
    apply_target="$PLAINTEXT_DIR"
  fi

else
  echo "Error: no secrets found for env '$ENV_NAME' (checked $ENCRYPTED_DIR and $PLAINTEXT_DIR)." >&2
  exit 1
fi

echo "kubectl context: $(kubectl config current-context 2>/dev/null || echo '?')"
# Secrets land in namespaces that later steps (observability, minecraft, wireguard...)
# create; on a fresh cluster those do not exist yet, and kubectl apply would fail on
# them. Create any missing namespace up front -- Helm and ArgoCD adopt existing ones.
if [[ -d "$apply_target" ]]; then ns_files=("$apply_target"/*.y*ml); else ns_files=("$apply_target"); fi
for ns in $(for f in "${ns_files[@]}"; do
              yq -r 'select(.kind == "Secret") | .metadata.namespace // "default"' "$f" 2>/dev/null; done | sort -u); do
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    if [[ -n "$DRY_RUN" ]]; then echo "would create namespace $ns"; else
      kubectl create namespace "$ns" && echo "created namespace $ns"; fi
  fi
done
# shellcheck disable=SC2086
kubectl apply $DRY_RUN -f "$apply_target" || exit 1
echo "Secrets applied from: $apply_target"
