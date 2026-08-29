#!/usr/bin/env bash
set -uo pipefail
# NOTE: deliberately no `set -e` — preflight is a read-only workstation check that
# must run every check to completion even when individual checks fail, and report
# rather than abort at the first missing tool.

# ============================================================================
# preflight-local — workstation toolchain preflight for a fresh machine
# ============================================================================
# Verifies that the local workstation has everything the provisioning and
# new-env skills/scripts assume: the required CLI toolchain, local key material
# (SSH + SOPS age), and that the agent skills are discoverable.
#
# It runs entirely locally, touches no cluster, and NEVER installs anything in
# the default (report-only) mode. With --install it will attempt installs via
# the OS package manager (brew on macOS, apt-get on Linux), printing the exact
# command for every action first — it never escalates privileges silently. For
# tools with no package-manager recipe it prints the upstream install URL.
#
# Usage:
#   tools/preflight-local.sh            # report only (default; installs nothing)
#   tools/preflight-local.sh --install  # attempt installs for missing tools
#   tools/preflight-local.sh --help
#
# Exit code: 0 if all REQUIRED tools are present; 1 if any required tool is
# missing (so an agent can gate provisioning on it). Missing key material is a
# warning and does not change the exit code.
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    -h|--help)
      sed -n '/^# preflight-local —/,/^# ===.*===$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) provision::error "unknown flag: $arg"; exit 2 ;;
    *)  provision::error "unexpected argument: $arg"; exit 2 ;;
  esac
done

# --- OS detection ----------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
  Darwin) PKG_MGR="brew" ;;
  Linux)  PKG_MGR="apt-get" ;;
  *)      PKG_MGR="" ;;
esac

# The toolset the provision / new-env skills and scripts assume. Keep this in
# sync with .claude/skills/provision/SKILL.md "Verify prerequisites".
REQUIRED_TOOLS=(kubectl helm sops age age-keygen yq jq gh curl openssl ssh ssh-keygen git)

# --- Install hints ---------------------------------------------------------
# Package-manager install command for a tool on the current OS, or empty if the
# tool is not installable via the package manager here (then use upstream_hint).
pm_command() {
  local tool="$1" pkg
  if [[ "$OS" == "Darwin" ]]; then
    case "$tool" in
      ssh|ssh-keygen) echo "" ;;                 # ships with macOS OpenSSH
      age-keygen)     echo "brew install age" ;;  # age-keygen ships with age
      *)              echo "brew install $tool" ;;
    esac
  elif [[ "$OS" == "Linux" ]]; then
    case "$tool" in
      jq|curl|openssl|git) echo "sudo apt-get install -y $tool" ;;
      age|age-keygen)      echo "sudo apt-get install -y age" ;;
      ssh|ssh-keygen)      echo "sudo apt-get install -y openssh-client" ;;
      *)                   echo "" ;;             # kubectl/helm/sops/yq/gh: upstream only
    esac
  else
    echo ""
  fi
}

# Upstream install URL/command for tools with no (reliable) package-manager recipe.
upstream_hint() {
  local tool="$1"
  case "$tool" in
    kubectl)        echo "https://kubernetes.io/docs/tasks/tools/" ;;
    helm)           echo "https://helm.sh/docs/intro/install/" ;;
    sops)           echo "https://github.com/getsops/sops/releases" ;;
    age|age-keygen) echo "https://github.com/FiloSottile/age/releases" ;;
    yq)             echo "https://github.com/mikefarah/yq#install  (the apt 'yq' is a different tool)" ;;
    gh)             echo "https://github.com/cli/cli#installation" ;;
    jq)             echo "https://jqlang.github.io/jq/download/" ;;
    curl)           echo "https://curl.se/download.html" ;;
    openssl)        echo "https://www.openssl.org/source/" ;;
    git)            echo "https://git-scm.com/downloads" ;;
    ssh|ssh-keygen)
      if [[ "$OS" == "Darwin" ]]; then
        echo "ships with macOS; if missing run: xcode-select --install"
      else
        echo "https://www.openssh.com/  (OpenSSH client)"
      fi
      ;;
    *) echo "" ;;
  esac
}

# Best single install hint for report mode: prefer the package-manager command,
# fall back to the upstream hint.
install_hint() {
  local tool="$1" cmd
  cmd="$(pm_command "$tool")"
  if [[ -n "$cmd" ]]; then echo "$cmd"; else upstream_hint "$tool"; fi
}

# --- Version probing -------------------------------------------------------
tool_version() {
  local tool="$1" v=""
  case "$tool" in
    kubectl)    v="$(kubectl version --client 2>/dev/null | head -n1)" ;;
    helm)       v="$(helm version --short 2>/dev/null)" ;;
    openssl)    v="$(openssl version 2>/dev/null)" ;;
    ssh)        v="$(ssh -V 2>&1 | head -n1)" ;;
    ssh-keygen) v="$(ssh -V 2>&1 | head -n1)" ;;   # ssh-keygen has no --version; ships with ssh
    *)          v="$( { "$tool" --version; } 2>&1 | head -n1)" ;;
  esac
  [[ -z "$v" ]] && v="(version unknown)"
  echo "$v"
}

# --- Report -----------------------------------------------------------------
PRESENT=0
MISSING=0
MISSING_TOOLS=()

echo ""
echo "  preflight-local — workstation toolchain check"
echo "  OS: ${OS}    package manager: ${PKG_MGR:-<none detected>}"
echo "  ================================================================"
echo ""
echo "  Required tools"
echo "  --------------"
for tool in "${REQUIRED_TOOLS[@]}"; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  [%-7s] %-11s %s\n' "OK" "$tool" "$(tool_version "$tool")"
    PRESENT=$((PRESENT + 1))
  else
    printf '  [%-7s] %-11s install: %s\n' "MISSING" "$tool" "$(install_hint "$tool")"
    MISSING=$((MISSING + 1))
    MISSING_TOOLS+=("$tool")
  fi
done

echo ""
echo "  Local key material"
echo "  ------------------"
SSH_KEY="${HOME}/.ssh/id_ed25519"
if [[ -f "$SSH_KEY" ]]; then
  printf '  [%-7s] SSH key       %s\n' "OK" "$SSH_KEY"
  printf '            %s\n' "$(provision::ssh_pub_fingerprint "${SSH_KEY}.pub")"
else
  printf '  [%-7s] SSH key       missing: %s\n' "WARN" "$SSH_KEY"
  printf '            create it: ssh-keygen -t ed25519\n'
fi

AGE_KEY="$(provision::default_age_key_file)"
if [[ -f "$AGE_KEY" ]]; then
  printf '  [%-7s] SOPS age key  %s\n' "OK" "$AGE_KEY"
  while IFS= read -r rcpt; do
    [[ -n "$rcpt" ]] && printf '            recipient: %s\n' "$rcpt"
  done < <(provision::age_list_public_recipients "$AGE_KEY")
else
  printf '  [%-7s] SOPS age key  missing: %s\n' "WARN" "$AGE_KEY"
  printf '            create it: age-keygen -o %s\n' "$AGE_KEY"
fi

echo ""
echo "  Agent skills (must be discoverable so the evaluator's agent finds them)"
echo "  ----------------------------------------------------------------------"
SKILL_COUNT=0
for skill_file in "$REPO_ROOT"/.claude/skills/*/SKILL.md; do
  [[ -f "$skill_file" ]] || continue
  skill_name="$(basename "$(dirname "$skill_file")")"
  printf '  [%-7s] %-11s %s\n' "OK" "$skill_name" "$skill_file"
  SKILL_COUNT=$((SKILL_COUNT + 1))
done
if [[ "$SKILL_COUNT" -eq 0 ]]; then
  printf '  [%-7s] no SKILL.md found under %s/.claude/skills/\n' "WARN" "$REPO_ROOT"
fi

# --- Optional install pass -------------------------------------------------
if [[ "$INSTALL" == true && "$MISSING" -gt 0 ]]; then
  echo ""
  echo "  --install: attempting installs for ${MISSING} missing tool(s)"
  echo "  ------------------------------------------------------------"
  if [[ -z "$PKG_MGR" ]]; then
    provision::warn "no supported package manager for OS '${OS}' — install manually (see hints above)"
  elif [[ "$OS" == "Darwin" ]] && ! command -v brew >/dev/null 2>&1; then
    provision::warn "Homebrew (brew) not found — install it first: https://brew.sh"
  else
    for tool in "${MISSING_TOOLS[@]}"; do
      cmd="$(pm_command "$tool")"
      if [[ -z "$cmd" ]]; then
        provision::warn "${tool}: no ${PKG_MGR} recipe — install manually: $(upstream_hint "$tool")"
        continue
      fi
      # Print the exact command before running it — never escalate silently.
      provision::info "${tool}: running -> ${cmd}"
      if eval "$cmd"; then
        provision::info "${tool}: installed"
      else
        provision::warn "${tool}: install command failed — install manually: $(upstream_hint "$tool")"
      fi
    done
  fi
elif [[ "$MISSING" -gt 0 ]]; then
  echo ""
  echo "  (report-only mode — nothing installed. Re-run with --install to attempt"
  echo "   installs via ${PKG_MGR:-your package manager}, or use the hints above.)"
fi

# --- Summary ---------------------------------------------------------------
echo ""
echo "  ================================================================"
echo "  Summary: ${PRESENT} present / ${MISSING} missing (of ${#REQUIRED_TOOLS[@]} required tools)"
if [[ "$MISSING" -gt 0 ]]; then
  echo "  Missing: ${MISSING_TOOLS[*]}"
fi
echo "  ================================================================"
echo ""

if [[ "$MISSING" -gt 0 ]]; then
  exit 1
fi
exit 0
