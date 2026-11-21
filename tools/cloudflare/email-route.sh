#!/usr/bin/env bash
set -euo pipefail
# ============================================================================
# email-route — Cloudflare Email Routing aliases (forward-only) for an environment's mail domain
# ============================================================================
# Creates, lists and removes forwarding rules "<alias>@<MAIL_DOMAIN> -> <destination>" through
# the Email Routing rules API. Typical use: a tenant alias (tenant@your-domain) that tenant service
# accounts (a Databricks workspace, a cloud console) sign up with, instead of a person's address.
# tools/k3s/tenant.sh calls it when tenant.properties asks for an alias (docs/TENANTS.md).
#
# Usage:
#   tools/cloudflare/email-route.sh <env-name> --list
#   tools/cloudflare/email-route.sh <env-name> <alias> --forward-like <existing alias> [--dry-run]
#   tools/cloudflare/email-route.sh <env-name> <alias> --to <verified destination> [--dry-run]
#   tools/cloudflare/email-route.sh <env-name> <alias> --remove [--yes] [--dry-run]
#
# Options:
#   --list                 the zone's rules: alias, destinations, enabled, rule id, name
#   --forward-like ALIAS   forward to the same destination(s) as the rule of ALIAS
#   --to ADDRESS           forward to ADDRESS; it must be a verified destination (below)
#   --name TEXT            the rule's name (default "infra-skills: <alias>[ like <ALIAS>]")
#   --remove               delete the rule of <alias> (asks for the alias unless --yes)
#   --yes                  answer the --remove confirmation
#   --dry-run              print the write calls (method, path, body) instead of sending them;
#                          read calls still run
#   -h, --help             show this help
#
# <alias> is a local part ("billing") or a full address in MAIL_DOMAIN ("billing@<MAIL_DOMAIN>").
#
# Idempotent: a rule for <alias> with the same destinations, enabled, is a no-op. A rule for
# <alias> with other destinations, or disabled, is reported and left alone (remove it first).
#
# Verified destinations: Cloudflare delivers only to destination addresses verified on the
# account. The script reads them (GET /accounts/<id>/email/routing/addresses; the token needs
# "Email Routing Addresses: Read" on the account). When the token cannot read them (a token
# scoped to the zone only), a destination counts as verified only when an enabled rule of the
# zone already forwards to it; anything else is refused.
#
# Settings: envs/<env>/env.properties
#   MAIL_DOMAIN                  the Cloudflare zone that receives the mail (required)
#   CLOUDFLARE_EMAIL_TOKEN_FILE  a file holding only the API token: absolute, ~/..., or relative to
#                                the envs root (default: the token in shared/secrets.plain/cloudflare.yaml).
#                                Permissions: Zone / Email Routing Rules: Edit (and Read)
#   CLOUDFLARE_EMAIL_ZONE_ID     the zone id (default: looked up by MAIL_DOMAIN)
#
# The token is passed to curl through a config on a file descriptor, never on the command line,
# and never printed.
# ============================================================================

REPO_ROOT="$(cd "$(dirname "$0")"/../.. && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/provision-common.sh"

usage() { sed -n '/^# Usage:/,/^# The token is passed/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d' >&2; }
log() { echo "[email-route] $*" >&2; }
die() { provision::error "$*"; exit 1; }
# The plan goes to the script's stdout through fd 3, also from inside $(...).
exec 3>&1
plan() { echo "[DRY-RUN] $*" >&3; }

for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
[[ -n "${1:-}" ]] || { usage; exit 1; }
provision::load_env "$1" || die "Environment '$1' not found (envs/$1/env.properties missing under $(provision::envs_root))."
shift

ALIAS="" MODE="" LIST=false REMOVE=false FORWARD_LIKE="" TO="" RULE_NAME="" YES=false DRY_RUN=false
if [[ -n "${1:-}" && "${1:0:1}" != - ]]; then ALIAS="$1"; shift; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST=true; shift ;;
    --forward-like) [[ -n "${2:-}" ]] || die "--forward-like needs an alias"; FORWARD_LIKE="$2"; MODE=create; shift 2 ;;
    --to) [[ -n "${2:-}" ]] || die "--to needs an address"; TO="$2"; MODE=create; shift 2 ;;
    --name) [[ -n "${2:-}" ]] || die "--name needs a text"; RULE_NAME="$2"; shift 2 ;;
    --remove) REMOVE=true; shift ;;
    --yes) YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) usage; die "Unknown argument: $1" ;;
  esac
done
if $REMOVE; then [[ -z "$MODE" ]] || die "--remove takes no --forward-like or --to"; MODE=remove; fi
if $LIST; then [[ -z "$MODE" && -z "$ALIAS" ]] || die "--list takes no alias and no other action"; MODE=list; fi
[[ -n "$MODE" ]] || { usage; die "say --list, --forward-like, --to or --remove"; }
[[ -n "$FORWARD_LIKE" && -n "$TO" ]] && die "--forward-like and --to exclude each other"
[[ "$MODE" == list || -n "$ALIAS" ]] || die "an alias is required"

command -v jq >/dev/null 2>&1 || die "jq not found"
command -v curl >/dev/null 2>&1 || die "curl not found"
[[ -n "${MAIL_DOMAIN:-}" ]] || die "MAIL_DOMAIN is not set in envs/${ENV_NAME}/env.properties"
MAIL_DOMAIN=$(tr '[:upper:]' '[:lower:]' <<<"$MAIL_DOMAIN")

# "billing" or "billing@<MAIL_DOMAIN>" -> "billing@<mail_domain>"; anything else is refused.
address_of() {
  local a
  a=$(tr '[:upper:]' '[:lower:]' <<<"$1")
  if [[ "$a" == *@* ]]; then
    [[ "${a#*@}" == "$MAIL_DOMAIN" ]] || die "$1 is not in MAIL_DOMAIN ${MAIL_DOMAIN}"
    a="${a%@*}"
  fi
  [[ "$a" =~ ^[a-z0-9]([a-z0-9._+-]*[a-z0-9])?$ ]] || die "not an alias (local part): $1"
  echo "${a}@${MAIL_DOMAIN}"
}

# --- Token ---------------------------------------------------------------------------------------
# The token goes into a curl config file (mktemp, 0600) and leaves the shell; xtrace is off while
# it is in a variable, so even bash -x does not print it.
CF_LAST=$(mktemp)
CF_CFG=$(mktemp)
trap 'rm -f "$CF_LAST" "$CF_CFG"' EXIT
{ XTRACE=$-; set +x; } 2>/dev/null
CF_API_TOKEN=""
if [[ -n "${CLOUDFLARE_EMAIL_TOKEN_FILE:-}" ]]; then
  tf="$CLOUDFLARE_EMAIL_TOKEN_FILE"
  case "$tf" in
    /*) ;;
    "~/"*) tf="${HOME}/${tf#\~/}" ;;
    *) tf="$(provision::envs_root)/${tf}" ;;
  esac
  [[ -f "$tf" ]] || die "CLOUDFLARE_EMAIL_TOKEN_FILE not found: $tf"
  CF_API_TOKEN=$(tr -d ' \t\r\n' <"$tf")
  [[ -n "$CF_API_TOKEN" ]] || die "CLOUDFLARE_EMAIL_TOKEN_FILE is empty: $tf"
else
  provision::cloudflare_read_token || die "no Cloudflare token: set CLOUDFLARE_EMAIL_TOKEN_FILE or create shared/secrets.plain/cloudflare.yaml"
fi
printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" >"$CF_CFG"
unset CF_API_TOKEN
[[ "$XTRACE" == *x* ]] && set -x

# --- API -----------------------------------------------------------------------------------------
# The last response is kept in $CF_LAST, a file: cf runs inside $(...), so a variable would not
# survive it.
# cf METHOD PATH [JSON_BODY] -> the response body on success; dry-run prints writes instead.
cf() {
  local method="$1" path="$2" body="${3:-}"
  if $DRY_RUN && [[ "$method" != GET ]]; then
    plan "CLOUDFLARE ${method} ${path}${body:+ ${body}}"
    echo '{"success":true,"result":{"id":"<rule-id>"}}' >"$CF_LAST"
    cat "$CF_LAST"
    return 0
  fi
  local -a data=()
  [[ -n "$body" ]] && data=(--data-binary "$body")
  curl -sS -X "$method" "https://api.cloudflare.com/client/v4${path}" \
    -K "$CF_CFG" \
    -H 'Content-Type: application/json' ${data[@]+"${data[@]}"} >"$CF_LAST" 2>/dev/null \
    || { echo '{"success":false,"errors":[{"message":"curl failed"}]}' >"$CF_LAST"; return 1; }
  jq -e '.success == true' >/dev/null 2>&1 <"$CF_LAST" || return 1
  cat "$CF_LAST"
}
cf_errors() { jq -r '[.errors[]? | "\(.code // "") \(.message // "")"] | join("; ")' 2>/dev/null <"$CF_LAST" || echo "unparsable response"; }

ZONE_ID="${CLOUDFLARE_EMAIL_ZONE_ID:-}"
ACCOUNT_ID=""
zone_path="/zones?name=${MAIL_DOMAIN}"
[[ -n "$ZONE_ID" ]] && zone_path="/zones/${ZONE_ID}"
if out=$(cf GET "$zone_path"); then
  if [[ -n "$ZONE_ID" ]]; then
    ACCOUNT_ID=$(jq -r '.result.account.id // empty' <<<"$out")
  else
    ZONE_ID=$(jq -r '.result[0].id // empty' <<<"$out")
    ACCOUNT_ID=$(jq -r '.result[0].account.id // empty' <<<"$out")
  fi
fi
[[ -n "$ZONE_ID" ]] || die "zone ${MAIL_DOMAIN} not found or not readable with this token: $(cf_errors)"

# Every rule of the zone (paged), as one JSON array.
RULES='[]'
page=1
while :; do
  out=$(cf GET "/zones/${ZONE_ID}/email/routing/rules?per_page=50&page=${page}") \
    || die "cannot list the Email Routing rules of ${MAIL_DOMAIN}: $(cf_errors)"
  RULES=$(jq -c --argjson more "$(jq -c '.result // []' <<<"$out")" '. + $more' <<<"$RULES")
  total=$(jq -r '.result_info.total_count // 0' <<<"$out")
  [[ $(jq 'length' <<<"$RULES") -lt $total && $(jq '.result | length' <<<"$out") -gt 0 ]] || break
  page=$((page + 1))
done

# Is Email Routing on for the zone? Needs a zone-settings read the token may lack: best effort.
if out=$(cf GET "/zones/${ZONE_ID}/email/routing"); then
  [[ "$(jq -r '.result.enabled' <<<"$out")" == true ]] || log "WARNING: Email Routing is not enabled on ${MAIL_DOMAIN}: rules exist but no mail is routed"
fi

rule_of() { # rule_of ADDRESS -> the rule matching exactly "to == ADDRESS" (JSON or empty)
  jq -c --arg a "$1" 'first(.[] | select(any(.matchers[]?; .type == "literal" and .field == "to"
    and ((.value // "") | ascii_downcase) == $a))) // empty' <<<"$RULES"
}
dests_of() { jq -c '[.actions[]? | select(.type == "forward") | .value[]?] | map(ascii_downcase) | unique' <<<"$1"; }

# --- list ------------------------------------------------------------------------------------------
if [[ "$MODE" == list ]]; then
  echo "Email Routing rules of ${MAIL_DOMAIN} (zone ${ZONE_ID}):"
  jq -r '.[] | select(any(.matchers[]?; .type == "literal" and .field == "to"))
    | [([.matchers[] | select(.field == "to") | .value] | join(",")),
       ([.actions[] | if .type == "forward" then (.value | join(",")) else .type end] | join(",")),
       (if .enabled then "enabled" else "disabled" end), .id, (.name // "")] | @tsv' <<<"$RULES" \
    | sort | column -t -s $'\t'
  jq -r '.[] | select(any(.matchers[]?; .type == "all"))
    | "catch-all: \(if .enabled then "enabled" else "disabled" end), \([.actions[] | if .type == "forward" then "forward to \(.value | join(","))" else .type end] | join(","))"' <<<"$RULES"
  exit 0
fi

ADDRESS=$(address_of "$ALIAS")
EXISTING=$(rule_of "$ADDRESS")

# --- remove ----------------------------------------------------------------------------------------
if [[ "$MODE" == remove ]]; then
  if [[ -z "$EXISTING" ]]; then log "no rule for ${ADDRESS}: nothing to remove"; exit 0; fi
  id=$(jq -r '.id' <<<"$EXISTING")
  log "rule ${id} (${ADDRESS} -> $(dests_of "$EXISTING" | jq -r 'join(",")')) will be deleted"
  if ! $DRY_RUN && ! $YES; then
    confirm=""
    read -rp "Type the alias ${ADDRESS} to delete its rule: " confirm || true
    [[ "$(tr '[:upper:]' '[:lower:]' <<<"$confirm")" == "$ADDRESS" ]] || die "confirmation failed; nothing deleted"
  fi
  cf DELETE "/zones/${ZONE_ID}/email/routing/rules/${id}" >/dev/null || die "delete failed: $(cf_errors)"
  log "$($DRY_RUN && echo "would delete" || echo "deleted") the rule of ${ADDRESS}"
  exit 0
fi

# --- create --------------------------------------------------------------------------------------
if [[ -n "$FORWARD_LIKE" ]]; then
  SOURCE=$(address_of "$FORWARD_LIKE")
  [[ "$SOURCE" != "$ADDRESS" ]] || die "--forward-like names the alias itself"
  src_rule=$(rule_of "$SOURCE")
  [[ -n "$src_rule" ]] || die "no rule for ${SOURCE} to forward like"
  [[ "$(jq -r '.enabled' <<<"$src_rule")" == true ]] || die "the rule of ${SOURCE} is disabled"
  WANT=$(dests_of "$src_rule")
  [[ "$(jq 'length' <<<"$WANT")" -gt 0 ]] || die "the rule of ${SOURCE} does not forward (its actions: $(jq -c '[.actions[].type]' <<<"$src_rule"))"
  DEFAULT_NAME="infra-skills: ${ADDRESS} like ${SOURCE}"
else
  t=$(tr '[:upper:]' '[:lower:]' <<<"$TO")
  [[ "$t" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "not an email address: $TO"
  WANT=$(jq -cn --arg t "$t" '[$t]')
  DEFAULT_NAME="infra-skills: ${ADDRESS}"
fi
RULE_NAME="${RULE_NAME:-$DEFAULT_NAME}"

# Idempotence: the alias already has a rule.
if [[ -n "$EXISTING" ]]; then
  id=$(jq -r '.id' <<<"$EXISTING")
  have=$(dests_of "$EXISTING")
  if [[ "$have" == "$WANT" && "$(jq -r '.enabled' <<<"$EXISTING")" == true ]]; then
    log "rule ${id} already forwards ${ADDRESS} to the same $(jq 'length' <<<"$WANT") destination(s): nothing to do"
    exit 0
  fi
  die "${ADDRESS} already has rule ${id} ($(jq -r '.enabled | if . then "enabled" else "disabled" end' <<<"$EXISTING"), to $(jq -r 'join(",")' <<<"$have")), not the requested one (to $(jq -r 'join(",")' <<<"$WANT")). Remove it first (--remove) if it should change."
fi

# Verified destinations: the account's list when readable, else what the zone already forwards to.
if [[ -n "$ACCOUNT_ID" ]] && out=$(cf GET "/accounts/${ACCOUNT_ID}/email/routing/addresses?per_page=50"); then
  verified=$(jq -c '[.result[]? | select(.verified != null) | .email | ascii_downcase]' <<<"$out")
  basis="verified on the account"
else
  log "the token cannot read the account's destination addresses ($(cf_errors)); a destination counts as verified only when an enabled rule of ${MAIL_DOMAIN} already forwards to it"
  verified=$(jq -c '[.[] | select(.enabled) | .actions[]? | select(.type == "forward") | .value[]? | ascii_downcase] | unique' <<<"$RULES")
  basis="already a destination of an enabled rule"
fi
missing=$(jq -c --argjson v "$verified" '[.[] | select(. as $d | $v | index($d) | not)]' <<<"$WANT")
if [[ "$(jq 'length' <<<"$missing")" -gt 0 ]]; then
  die "not a verified destination: $(jq -r 'join(",")' <<<"$missing"). Add and verify it in the Cloudflare dashboard (Email Routing, Destination addresses) first."
fi
log "destination(s) ${basis}: $(jq -r 'join(",")' <<<"$WANT")"

body=$(jq -cn --arg name "$RULE_NAME" --arg to "$ADDRESS" --argjson dests "$WANT" \
  '{name: $name, enabled: true, matchers: [{type: "literal", field: "to", value: $to}],
    actions: [{type: "forward", value: $dests}]}')
out=$(cf POST "/zones/${ZONE_ID}/email/routing/rules" "$body") || die "create failed: $(cf_errors)"
log "$($DRY_RUN && echo "would create" || echo "created") rule $(jq -r '.result.id // "?"' <<<"$out"): ${ADDRESS} -> $(jq -r 'join(",")' <<<"$WANT")"
