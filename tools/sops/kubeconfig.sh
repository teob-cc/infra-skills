#!/usr/bin/env bash
# Keep an environment's admin kubeconfig out of git, with an encrypted copy that is.
#
# envs/<ENV>/kubeconfig.yaml holds cluster-admin client credentials. It stays at that path
# (every script and runbook reads it there) but is git-ignored (**/kubeconfig.yaml). The
# committed copy is envs/<ENV>/secrets.sops/kubeconfig, sops binary mode, so the whole file is
# encrypted. It has no .yaml extension on purpose:
#   - the YAML creation rule (encrypted_regex ^(data|stringData)$) would leave client-key-data
#     in plaintext, because no kubeconfig key is called data/stringData;
#   - tools/sops/apply.sh applies only *.yaml/*.yml, so it never tries to kubectl-apply it.
# tools/sops/decrypt.sh <ENV> also writes it to secrets.plain/kubeconfig (git-ignored).
#
# Usage:
#   tools/sops/kubeconfig.sh save <ENV>               # kubeconfig.yaml -> secrets.sops/kubeconfig
#   tools/sops/kubeconfig.sh restore [--force] <ENV>  # secrets.sops/kubeconfig -> kubeconfig.yaml
#     restore leaves an existing kubeconfig.yaml alone unless --force.
# Save after anything that changes the kubeconfig (provisioning, CA rotation) and commit
# secrets.sops/kubeconfig in the envs repo. The provisioning scripts save it themselves.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"
ENVS_ROOT=$(provision::envs_root)

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

CMD="${1:-}"; shift || true
FORCE=0; ENV_NAME=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Error: unknown flag '$arg'" >&2; exit 1 ;;
    *) [[ -z "$ENV_NAME" ]] || { echo "Error: unexpected argument '$arg'" >&2; exit 1; }; ENV_NAME="$arg" ;;
  esac
done
case "$CMD" in save|restore) ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 1 ;; esac
[[ -n "$ENV_NAME" ]] || { usage >&2; exit 1; }
[[ -d "$ENVS_ROOT/$ENV_NAME" ]] || { echo "Error: environment '$ENV_NAME' not found under $ENVS_ROOT" >&2; exit 1; }
command -v sops >/dev/null 2>&1 || { echo "Error: sops is not installed." >&2; exit 1; }

KUBECONFIG_FILE="$ENVS_ROOT/$ENV_NAME/kubeconfig.yaml"
ENCRYPTED_FILE="$ENVS_ROOT/$ENV_NAME/secrets.sops/kubeconfig"
PLAIN_COPY="$ENVS_ROOT/$ENV_NAME/secrets.plain/kubeconfig"

if [[ "$CMD" == save ]]; then
  [[ -f "$KUBECONFIG_FILE" ]] || { echo "Error: $KUBECONFIG_FILE not found" >&2; exit 1; }
  provision::assert_plaintext_ignored "$KUBECONFIG_FILE" '**/kubeconfig.yaml' ||
    echo "Warning: the plaintext kubeconfig above is still carried by git; saving the encrypted copy anyway." >&2
  # encrypt.sh reads from secrets.plain/ so the envs repo's creation rules match the path.
  provision::assert_plaintext_ignored "$PLAIN_COPY" || exit 1
  mkdir -p "$(dirname "$PLAIN_COPY")"
  ( umask 077; cp "$KUBECONFIG_FILE" "$PLAIN_COPY" )
  "$REPO_ROOT/tools/sops/encrypt.sh" "$ENV_NAME" kubeconfig >/dev/null
  echo "Saved: envs/$ENV_NAME/secrets.sops/kubeconfig (commit it in the envs repo)"
  exit 0
fi

# restore
if [[ -f "$KUBECONFIG_FILE" && "$FORCE" -ne 1 ]]; then
  echo "Kept: $KUBECONFIG_FILE exists (use --force to overwrite it from secrets.sops)"
  exit 0
fi
[[ -f "$ENCRYPTED_FILE" ]] || {
  echo "Error: no encrypted kubeconfig at $ENCRYPTED_FILE" >&2
  echo "       Fetch it from the server (provision script) or copy it in, then: $0 save $ENV_NAME" >&2
  exit 1; }
provision::assert_plaintext_ignored "$KUBECONFIG_FILE" '**/kubeconfig.yaml' || exit 1
if [[ -z "${SOPS_AGE_KEY_FILE:-}${SOPS_AGE_KEY:-}" ]]; then
  # Same default as decrypt.sh: bare sops does not look here on macOS.
  SOPS_AGE_KEY_FILE="$(provision::default_age_key_file)"; export SOPS_AGE_KEY_FILE
fi
tmp="$(mktemp "$ENVS_ROOT/$ENV_NAME/.kubeconfig.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"
sops --decrypt --input-type binary --output-type binary "$ENCRYPTED_FILE" > "$tmp" ||
  { echo "Error: could not decrypt $ENCRYPTED_FILE (age key?)" >&2; exit 1; }
mv -f "$tmp" "$KUBECONFIG_FILE"
trap - EXIT
echo "Restored: $KUBECONFIG_FILE"
