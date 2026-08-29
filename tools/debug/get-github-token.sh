#!/usr/bin/env bash
set -euo pipefail

# This script mints a short-lived GitHub App installation access token.
# It prefers environment variables but can fall back to reading from a
# Kubernetes Secret (ARC controller-manager) if kubectl is available.
#
# Required values (in order of precedence):
#   - GITHUB_APP_ID
#   - GITHUB_APP_INSTALLATION_ID
#   - GITHUB_APP_PRIVATE_KEY           (PEM content)
#   Optional fallbacks:
#   - GITHUB_APP_PRIVATE_KEY_FILE      (path to PEM file)
#   - ARC_SECRET_NAME                  (default: controller-manager)
#   - ARC_NAMESPACE                    (default: actions-runner-system)
#
# Output: the token is printed to stdout
# Usage example inside a GitHub Actions step:
#   TOKEN=$(bash images/builder/get-github-token.sh)
#   echo "::add-mask::${TOKEN}"
#   git config user.name "ci-bot"
#   git config user.email "ci-bot@example.com"
#   git remote set-url origin "https://x-access-token:${TOKEN}@github.com/<org>/<repo>.git"
#   git push

# --- Resolve inputs ---
APP_ID=${GITHUB_APP_ID:-}
INSTALLATION_ID=${GITHUB_APP_INSTALLATION_ID:-}
PRIVATE_KEY=${GITHUB_APP_PRIVATE_KEY:-}

# If a key file is provided, prefer it
if [[ -z "${PRIVATE_KEY}" && -n "${GITHUB_APP_PRIVATE_KEY_FILE:-}" ]]; then
  if [[ -f "${GITHUB_APP_PRIVATE_KEY_FILE}" ]]; then
    PRIVATE_KEY=$(cat "${GITHUB_APP_PRIVATE_KEY_FILE}")
  else
    echo "GITHUB_APP_PRIVATE_KEY_FILE is set but file not found: ${GITHUB_APP_PRIVATE_KEY_FILE}" >&2
  fi
fi

# If any are missing and kubectl is available, try reading from ARC Secret
if { [[ -z "${APP_ID}" || -z "${INSTALLATION_ID}" || -z "${PRIVATE_KEY}" ]] && command -v kubectl >/dev/null 2>&1; }; then
  ARC_SECRET_NAME=${ARC_SECRET_NAME:-controller-manager}
  ARC_NAMESPACE=${ARC_NAMESPACE:-actions-runner-system}
  # Only try if we can see the secret
  if kubectl -n "${ARC_NAMESPACE}" get secret "${ARC_SECRET_NAME}" >/dev/null 2>&1; then
    APP_ID=${APP_ID:-$(kubectl -n "${ARC_NAMESPACE}" get secret "${ARC_SECRET_NAME}" -o jsonpath='{.data.github_app_id}' 2>/dev/null | base64 -d || true)}
    INSTALLATION_ID=${INSTALLATION_ID:-$(kubectl -n "${ARC_NAMESPACE}" get secret "${ARC_SECRET_NAME}" -o jsonpath='{.data.github_app_installation_id}' 2>/dev/null | base64 -d || true)}
    if [[ -z "${PRIVATE_KEY}" ]]; then
      PRIVATE_KEY=$(kubectl -n "${ARC_NAMESPACE}" get secret "${ARC_SECRET_NAME}" -o jsonpath='{.data.github_app_private_key}' 2>/dev/null | base64 -d || true)
    fi
  fi
fi

# Final validation with helpful error
if [[ -z "${APP_ID}" ]]; then
  echo "GITHUB_APP_ID is required. Set env GITHUB_APP_ID, or ensure ARC Secret is accessible via kubectl." >&2
  exit 1
fi
if [[ -z "${INSTALLATION_ID}" ]]; then
  echo "GITHUB_APP_INSTALLATION_ID is required. Set env GITHUB_APP_INSTALLATION_ID, or ensure ARC Secret is accessible via kubectl." >&2
  exit 1
fi
if [[ -z "${PRIVATE_KEY}" ]]; then
  echo "GITHUB_APP_PRIVATE_KEY is required. Set env GITHUB_APP_PRIVATE_KEY or GITHUB_APP_PRIVATE_KEY_FILE, or ensure ARC Secret is accessible via kubectl." >&2
  exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
keyfile="$workdir/key.pem"

# Write the multi-line PEM into a file
printf "%s" "$PRIVATE_KEY" > "$keyfile"
chmod 600 "$keyfile"

# Create JWT
header=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
now=$(date +%s)
iat=$((now-60)); exp=$((now+540))   # 9 minutes lifetime
payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$iat" "$exp" "$APP_ID" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$keyfile" -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
JWT="$header.$payload.$sig"

# Exchange for installation token
TOKEN=$(curl -sS -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" | jq -r '.token')

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "Failed to mint installation token" >&2
  exit 1
fi

printf "%s\n" "$TOKEN"
