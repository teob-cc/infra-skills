#!/usr/bin/env bash
# base-image — build library/teob-base (Temurin JRE + Node + Claude Code CLI) for <env>.
# The runtime base image every JVM service on the platform starts FROM. Wrapper around
# tools/k3s/harbor-image.sh <env> teob-base; same flags (--rebuild, --skip-build).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_ARG="${1:-}"; shift || true
[[ -n "$ENV_ARG" ]] || { echo "Usage: $0 <env> [--rebuild] [--skip-build]" >&2; exit 1; }
exec "$SCRIPT_DIR/harbor-image.sh" "$ENV_ARG" teob-base "$@"
