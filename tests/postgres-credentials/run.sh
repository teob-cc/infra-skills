#!/usr/bin/env bash
# Checks `tools/k3s/postgres.sh <env> --provision-credentials <app-id> ...` (INFRA-243) without a
# cluster: kubectl, helm, openssl and sleep are stand-ins (stubs/), the environment is a fake
# (envs/), and psql runs only as the stub's canned answers, or, with --real-postgres, against a
# throwaway local server (initdb in a temp directory, unix socket only, stopped at exit).
#
# What it checks:
#   1. the default path is unchanged: SQL, kubectl calls, Secret and Pooler equal the golden files
#      recorded from origin/main 1850e9c (golden/), as parsed objects and byte for byte, for a
#      plain app, a tenant with a Pooler and a hyphenated app id, and an app with PG_READONLY_ROLE;
#      the goldens differ from origin/main only by the read-only preflight session (and its kubectl
#      exec), the role transaction (BEGIN moved up to take in the role guard, CREATE ROLE and the
#      COMMENT ON ROLE marker) and the password line (a SCRAM verifier);
#   2. --database <name>[:<PREFIX>] (grant mode): no database is created, the role gets CONNECT,
#      schema, table and sequence rights and default privileges on each, PUBLIC keeps its CONNECT
#      (a warning names who relies on it), the Secret holds <PREFIX>_HOST/PORT/DATABASE/USERNAME/
#      PASSWORD per database; bad specs, a missing database and --create-missing (its intent, and
#      an unfinished creation finished); --revoke-public with --keep-connect; --take-ownership
#      through the ledger (object by object, no REASSIGN OWNED, bounded waits), and its refusals;
#   3. --migration-role: the second role (no statement_timeout, own connection limit, no membership
#      either way), its grants and default privileges, --migration-schema, its Secret; role
#      names: reserved, pg_*, privileged, unmarked and not adoptable roles are refused, each role
#      written in one guarded transaction;
#   4. connection limits and timeouts: values and range checks before any SQL;
#   5. re-runs: the same SQL again; --keep-password keeps an existing role's password untouched,
#      refuses a file whose *_PASSWORD values disagree, and a stored password that does not match
#      the role's live verifier, at the start or right before the Secret (it then stays as it is);
#   6. a failing or short openssl stops the run before any SQL;
#   6b. with the secret names exported by the caller and SHELLOPTS=allexport, no password or
#      verifier reaches the environment of kubectl, openssl or perl (checked on every run);
#   7. under bash -x no password reaches stdout or stderr, and none is ever on kubectl's argv;
#   8. (--real-postgres) the same against a real server, with log_statement = all,
#      log_min_duration_statement = 0 and sampled logging on (no plaintext password ever reaches
#      psql or the server log; SCRAM logins with the Secrets' passwords work): rights, PUBLIC,
#      ownership moves (an interrupted one is completed by the next run with the same destination;
#      the source's other databases and tablespaces untouched; an owner changed by hand refused;
#      a held lock fails fast; every object kind moved), roles changed between the preflight and
#      the change, names with quotes, | and spaces, refused roles, failing password statements,
#      a creation cut after CREATE DATABASE (and a same-named database made by someone else), a
#      password rotated during a run, a database owner or role comment changed or a database made
#      again while a run waits, objects and default privileges the move cannot handle (refused
#      before any password changes), another app's pending creation of a name, a renamed
#      replacement of a created database, a move that times out with an existing role's password
#      kept, a destination with default privileges of its own.
#
# Usage: tests/postgres-credentials/run.sh [--real-postgres]   (needs bash, jq, yq; --real-postgres
#        also initdb, pg_ctl and psql on PATH). PG_SCRIPT=<path> runs another postgres.sh (for
#        example an older commit's) against the same checks.
# The bash -c snippets below get their values as arguments; $1 in single quotes is meant.
# shellcheck disable=SC2016
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="${PG_SCRIPT:-$REPO/tools/k3s/postgres.sh}"
REAL=false
[[ "${1:-}" == --real-postgres ]] && REAL=true
for t in jq yq; do command -v "$t" >/dev/null 2>&1 || { echo "Missing: $t" >&2; exit 1; }; done
WORK="$(mktemp -d -t pg-credentials-test-XXXX)"
export KUBECONFIG=/dev/null PATH="$HERE/stubs:$PATH"
unset PG_READONLY_ROLE PG_TENANT_CONNECTION_LIMIT PG_APP_CONNECTION_LIMIT PG_MIGRATION_CONNECTION_LIMIT \
      STUB_DB_OWNERS STUB_ROLES STUB_NEED STUB_OPEN_DBS STUB_PGHOST STUB_PGPORT STUB_NO_NS STUB_NO_POOLER_ROLE \
      STUB_OPENSSL_FAIL STUB_OPENSSL_SHORT APP_NAMESPACE STUB_INTENTS STUB_LEDGER STUB_VERIFIERS STUB_VERIFIERS_LATER STUB_CUT STUB_CUT_BEFORE STUB_OBJECTS
PW_RE='Pw0Stub[0-9]+AbCdEfGhIjKlMn\+/='
US=$'\x1f'

RUN_SEQ=0   # each run gets its own password prefix (Pw0Stub<run>), so passwords never repeat across runs
PLAINTEXT_RUNS=""   # runs whose SQL held a plaintext password (P1-1)
ENV_RUNS=""         # runs that put a secret into a child's environment (P2-1)
failures=0
ok() { echo "ok    $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { # <description> <command...>
  local d="$1"; shift
  if "$@"; then ok "$d"; else fail "$d"; fi
}
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }
before() { # <file> <first fixed string> <second fixed string>: the first occurs, on an earlier line
  local a b
  a=$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1); b=$(grep -nF -- "$3" "$1" | head -1 | cut -d: -f1)
  [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]
}

# run <name> <args...>: postgres.sh fake --provision-credentials <args...> in a fresh copy of envs/,
# its own stub log; rc in RC, the run's directory in D. PRE_RUN=<dir> reuses a directory (re-runs).
run() {
  local name="$1"; shift
  D="${PRE_RUN:-$WORK/$name}"
  if [[ -z "${PRE_RUN:-}" ]]; then rm -rf "$D"; mkdir -p "$D"; cp -R "$HERE/envs/." "$D/"; fi
  : > "$D/log"; rm -rf "$D/log.sql" "$D/log.applied" "$D/log.env" "$D"/log.vread.*
  RC=0
  RUN_SEQ=$((RUN_SEQ + 1))
  STUB_PW_PREFIX="Pw0Stub$(printf '%03d' "$RUN_SEQ")" STUB_LOG="$D/log" INFRA_ENVS_ROOT="$D" ${TRACE:-} "$SCRIPT" fake --provision-credentials "$@" >"$D/out" 2>&1 || RC=$?
  touch "$D/log.sql"
  # P1-1: no plaintext password ever goes to psql, on any path
  if grep -qE "$PW_RE" "$D/log.sql"; then PLAINTEXT_RUNS+=" $name"; fi
  # P2-1 (round 4): no password or verifier in the environment of kubectl, openssl or perl
  if [[ -f "$D/log.env" ]] && grep -qE "$PW_RE|SCRAM-SHA-256" "$D/log.env"; then ENV_RUNS+=" $name"; fi
}
SCRAM_RE='SCRAM-SHA-256\$4096:[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+'
norm() { sed -E -e "s#$D#<WORK>#g" -e "s#$PW_RE#<PW>#g" -e "s#$SCRAM_RE#<SCRAM>#g"; }
SCRAM_PL="$REPO/tools/k3s/pg-scram.pl"
verifier_of() { printf '%s\n' "$1" | perl "$SCRAM_PL" make; }   # <password>
matches() { printf '%s\n%s\n' "$1" "$2" | perl "$SCRAM_PL" check "${3:-x}"; }   # <password> <verifier> [role]
secret_json() { yq -o=json '.' "$1" | jq -S .; }
key() { # <secret file> <key>
  yq -r ".stringData.$2 // \"\"" "$1" 2>/dev/null || true
}
# Preflight rows for the stub (| becomes \x1f):
#   dbrow <name> <owner> [owner is new f] [pending f] [old owner = owner] [old privileged f]
#         [PUBLIC has CONNECT t] [connected now through PUBLIC] [login roles relying on PUBLIC]
#         [pending destination] [pending destination is the new owner f] [owner is the pending move's source or destination t]
dbrow() {
  local old="${5:-$2}" isnew="${3:-f}"
  [[ "$old" != "$2" ]] && isnew=f
  echo "db|$1|t|$2|${3:-f}|${4:-f}|$old|$isnew|${6:-f}|${7:-t}|${8:-}|${9:-}|${10:-}|${11:-f}|${12:-t}|16600|${13:-17700}|${14:-16600}"
}
#   rolerow <kind> <name> [exists t] [marked t] [comment] [attributes] [memberships] [owns its db f]
#           [LOGIN t] [any membership, either direction] [member of the other role, or it of this one f]
rolerow() { echo "role|$1|$2|${3:-t}|${4:-t}|${5:-}|${6:-}|${7:-}|${8:-f}|$([[ "${3:-t}" == t ]] && echo 16500)|${9:-t}|${10:-}|${11:-f}"; }
nodb() { echo "db|$1|f||f|f||f|f|f||||f|t|||"; }

# --- 1. default path unchanged ------------------------------------------------------------
echo "== 1. default path: equal to the golden files from origin/main"
golden() { # <name> <args...>
  local name="$1" f; shift
  run "golden-$name" "$@"
  check "$name: exit 0" [ "$RC" = 0 ]
  check "$name: SQL equals golden/$name.sql" diff <(norm < "$D/log.sql") "$HERE/golden/$name.sql"
  check "$name: kubectl calls equal golden/$name.argv" diff <(grep -v '^openssl' "$D/log" | norm) "$HERE/golden/$name.argv"
  check "$name: secrets.plain equals golden/$name.files" diff <(ls "$D/fake/secrets.plain") "$HERE/golden/$name.files"
  for f in "$D"/log.applied/*; do
    if [[ "$f" == *.json ]]; then
      check "$name: applied $(basename "$f") equals golden (parsed)" diff <(jq -S . "$f" | norm) "$HERE/golden/$name.applied.$(basename "$f").json"
    else
      check "$name: applied $(basename "$f") equals golden (parsed)" diff <(secret_json "$f" | norm) "$HERE/golden/$name.applied.$(basename "$f").json"
    fi
    check "$name: applied $(basename "$f") equals golden byte for byte" cmp -s <(norm < "$f") "$HERE/golden/$name.applied.$(basename "$f").raw"
  done
  check "$name: secrets.plain file equals golden byte for byte" \
    cmp -s <(norm < "$D/fake/secrets.plain/$(cat "$HERE/golden/$name.files")") "$HERE/golden/$name.applied.$(cat "$HERE/golden/$name.files").raw"
}
golden plain my-app
golden tenant evse-ts --tenant symbioen --pooler --connection-limit 30
PG_READONLY_ROLE=claude_ro golden ro app2 --pooler --statement-timeout 30s
check "tenant: secret file is mode 600" [ -n "$(find "$WORK/golden-tenant/fake/secrets.plain/evse-ts-db.secret.yaml" -perm 600)" ]

# --- 2. existing databases ----------------------------------------------------------------
echo "== 2. --database <name>[:<PREFIX>]"
export STUB_DB_OWNERS; STUB_DB_OWNERS="$(dbrow evse scala_owner f f scala_owner f t '' 'other_app'; dbrow evse_ts scala_owner)"
run grant evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB
check "grant: exit 0" [ "$RC" = 0 ]
sql="$(cat "$D/log.sql")"; s="$D/fake/secrets.plain/evse-ts-db.secret.yaml"
check "grant: no CREATE DATABASE" lacks "$sql" "CREATE DATABASE"
check "grant: no REASSIGN OWNED, no ALTER DATABASE OWNER" bash -c '[[ "$1" != *"REASSIGN OWNED"* && "$1" != *"ALTER DATABASE"* ]]' _ "$sql"
check "grant: the preflight names both databases" contains "$sql" "\\set targets 'evse evse_ts'"
check "grant: the preflight asks psql for \\x1f-separated fields" grep -q -- "-tA -F ${US}\$" "$D/log"
check "grant: no owner name read from the server is spliced into SQL" lacks "$sql" "scala_owner"
check "grant: PUBLIC's CONNECT is left alone (P1-d)" lacks "$sql" "FROM PUBLIC"
check "grant: the warning says PUBLIC keeps CONNECT on evse" grep -q "evse: PUBLIC keeps CONNECT" "$D/out"
check "grant: the warning names the role relying on PUBLIC" grep -q "connect through PUBLIC only: other_app" "$D/out"
check "grant: who relies on PUBLIC counts only privileges a role can use, NOINHERIT aside (round 5 P3)" contains "$sql" "pg_has_role(r.oid, e.grantee, 'USAGE')"
check "grant: the app role gets CONNECT explicitly" contains "$sql" 'GRANT CONNECT, TEMPORARY ON DATABASE :"db" TO :"role";'
check "grant: schema USAGE, CREATE" contains "$sql" "GRANT USAGE, CREATE ON SCHEMA %I TO %I"
check "grant: table rights" contains "$sql" "GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA"
check "grant: sequence rights" contains "$sql" "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA"
check "grant: default privileges for the owners" contains "$sql" "ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO %I"
check "grant: tenant role keeps 60s" grep -qF "\\set stmt_to '60s'" "$D/log.sql"
check "grant: tenant role keeps 5min idle in transaction" grep -qF "\\set idle_to '5min'" "$D/log.sql"
check "grant: the role gets this app's marker" contains "$sql" "\\set marker 'infra-skills:app:evse-ts'"
check "grant: tenant -> no read-only role" contains "$sql" "\\set ro ''"
check "grant: password statement errors are not logged with their text (P1-c)" \
  bash -c 'grep -B3 "PASSWORD :.pw." "$1" | grep -q "SET LOCAL log_min_error_statement = .panic."' _ "$D/log.sql"
check "grant: no extension installed into existing databases" bash -c '! grep -q "CREATE EXTENSION" "$1"' _ "$D/log"
check "grant: JOURNAL_DB_HOST is the Pooler" [ "$(key "$s" JOURNAL_DB_HOST)" = pooler-evse-ts.postgres.svc.cluster.local ]
check "grant: JOURNAL_DB_DATABASE evse" [ "$(key "$s" JOURNAL_DB_DATABASE)" = evse ]
check "grant: STATE_DB_DATABASE evse_ts" [ "$(key "$s" STATE_DB_DATABASE)" = evse_ts ]
check "grant: STATE_DB_USERNAME evse-ts" [ "$(key "$s" STATE_DB_USERNAME)" = evse-ts ]
check "grant: STATE_DB_PORT 5432" [ "$(key "$s" STATE_DB_PORT)" = 5432 ]
check "grant: one password for both prefixes" bash -c '[[ -n "$1" && "$1" == "$2" ]]' _ "$(key "$s" JOURNAL_DB_PASSWORD)" "$(key "$s" STATE_DB_PASSWORD)"
check "grant: no POSTGRES_* keys" [ -z "$(key "$s" POSTGRES_HOST)" ]
check "grant: Secret evse-ts-db in namespace symbioen" [ "$(yq -r '.metadata.name + "/" + .metadata.namespace' "$s")" = evse-ts-db/symbioen ]
check "grant: the Secret was applied" [ -f "$D/log.applied/evse-ts-db.secret.yaml" ]
check "grant: the output names the per-role connection limit" grep -q "counts every session of evse-ts, across all 2 databases" "$D/out"

STUB_DB_OWNERS="$(dbrow legacy_db old_app)" run grant-noprefix my-app --database legacy_db
check "no prefix: exit 0" [ "$RC" = 0 ]
s="$D/fake/secrets.plain/my-app-db.secret.yaml"
check "no prefix: POSTGRES_DATABASE legacy_db" [ "$(key "$s" POSTGRES_DATABASE)" = legacy_db ]
check "no prefix: POSTGRES_HOST is the rw service" [ "$(key "$s" POSTGRES_HOST)" = postgres-cluster-rw.postgres.svc.cluster.local ]
check "no prefix: not a tenant -> read-only role variable empty (PG_READONLY_ROLE unset)" contains "$(cat "$D/log.sql")" "\\set ro ''"

bad() { # <description> <expected message> <args...>
  local d="$1" msg="$2"; shift 2
  run bad "$@"
  check "$d: refused" [ "$RC" != 0 ]
  check "$d: says '$msg'" grep -qF -- "$msg" "$D/out"
  check "$d: no SQL changes anything (the preflight aside)" bash -c '! awk "/^-- ### /{getline t; pre = (t ~ /^-- infra-skills:preflight/)} !pre" "$1" | grep -qE "ALTER ROLE|GRANT |REVOKE |CREATE ROLE"' _ "$D/log.sql"
  check "$d: no Secret written" bash -c '[ ! -e "$1/fake/secrets.plain" ] || [ -z "$(ls "$1/fake/secrets.plain")" ]' _ "$D"
}
bad "two databases without a prefix" "only one database may go without a prefix" x --database evse --database evse_ts
bad "a prefix used twice" "key prefix A_DB is already used" x --database evse:A_DB --database evse_ts:A_DB
bad "a lower-case prefix" "the key prefix must be upper case" x --database evse:journal
bad "an empty prefix" "the key prefix must be upper case" x --database evse:
bad "a database named twice" "--database evse is named twice" x --database evse:A --database evse:B
bad "a database name with a quote" "is not a database name" x "--database" "ev'se"
bad "the postgres database" "the cluster's own databases" x --database postgres
bad "--take-ownership without --database" "go with --database" x --take-ownership
bad "--create-missing without --database" "go with --database" x --create-missing
STUB_DB_OWNERS="$(dbrow evse scala_owner; nodb manifest)" bad "a missing database" "These databases do not exist: manifest" x --database evse:A --database manifest:B

STUB_DB_OWNERS="$(dbrow evse scala_owner; nodb manifest)" run create-missing evse-ts --database evse:JOURNAL_DB --database manifest:MANIFEST_DB --create-missing
check "--create-missing: exit 0" [ "$RC" = 0 ]
check "--create-missing: creates only manifest" [ "$(grep -c 'CREATE DATABASE :"db" OWNER :"owner";' "$D/log.sql")" = 1 ]
check "--create-missing: the intent is recorded before CREATE DATABASE (round 5 P2-d)" \
  before "$D/log.sql" "INSERT INTO infra_skills.create_intent" 'CREATE DATABASE :"db" OWNER :"owner";'
check "--create-missing: and marked done after the ACL" before "$D/log.sql" 'ON DATABASE :"db" FROM PUBLIC;' "UPDATE infra_skills.create_intent SET done_at = now()"
check "--create-missing: owned by the app role" grep -q "^\\\\set owner 'evse-ts'" "$D/log.sql"
check "--create-missing: PUBLIC revoked on the new database only" [ "$(grep -c 'REVOKE CONNECT, TEMPORARY ON DATABASE :"db" FROM PUBLIC' "$D/log.sql")" = 1 ]
check "--create-missing: extensions only in manifest" bash -c 'grep "CREATE EXTENSION" "$1" | grep -qv -- "-d manifest" && exit 1; grep -q -- "-d manifest -qc CREATE EXTENSION" "$1"' _ "$D/log"
check "--create-missing: the preflight reads create_intent only behind \\if :use_intent" before "$D/log.sql" "\\if :use_intent" "FROM infra_skills.create_intent i"
# Round 5 P2-d: an earlier run created manifest and stopped before its ACL; the retry finishes it.
STUB_INTENTS='intent|manifest|t|t|evse-ts' STUB_DB_OWNERS="$(dbrow evse scala_owner; dbrow manifest evse-ts t)" \
  run create-finish evse-ts --database evse:JOURNAL_DB --database manifest:MANIFEST_DB --create-missing
check "--create-missing, unfinished creation: exit 0 (round 5 P2-d)" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
check "--create-missing, unfinished creation: says so" grep -q "manifest was created by an earlier run that did not finish" "$D/out"
check "--create-missing, unfinished creation: not created again" bash -c '! grep -q "CREATE DATABASE" "$1"' _ "$D/log.sql"
check "--create-missing, unfinished creation: PUBLIC's CONNECT is revoked on it" [ "$(grep -c 'REVOKE CONNECT, TEMPORARY ON DATABASE :"db" FROM PUBLIC' "$D/log.sql")" = 1 ]
check "--create-missing, unfinished creation: extensions installed" grep -q -- "-d manifest -qc CREATE EXTENSION" "$D/log"
STUB_INTENTS='intent|manifest|t|t|evse-ts' STUB_DB_OWNERS="$(dbrow evse scala_owner; dbrow manifest someone_else)" \
  bad "--create-missing, unfinished creation now owned by another role" "its owner is now someone_else" evse-ts --database evse:JOURNAL_DB --database manifest:MANIFEST_DB --create-missing

# Round 6 P2-a: a pending intent for a same-named database that is not bound to it (no oid, no marker).
STUB_INTENTS='intent|manifest|t|f|evse-ts' STUB_DB_OWNERS="$(dbrow evse scala_owner; dbrow manifest evse-ts t)" \
  bad "--create-missing, a same-named database the intent is not bound to (round 6 P2-a)" "nothing shows it is the one an earlier run for evse-ts created" evse-ts --database evse:JOURNAL_DB --database manifest:MANIFEST_DB --create-missing
check "--create-missing: the intent is bound by its oid once recorded, else by that creation's marker (round 7 P2-b)" \
  bash -c 'grep -q "CASE WHEN i.datoid IS NOT NULL THEN i.datoid = d.oid" "$1" && grep -q "ELSE shobj_description(d.oid, .pg_database.) = .infra-skills:created:. || i.app || .:. || i.nonce END" "$1"' _ "$WORK/create-missing/log.sql"
check "--create-missing: the new database gets its creation's marker and the intent its oid right after CREATE DATABASE (round 7 P2-b)" \
  bash -c 'grep -A3 "^CREATE DATABASE :\"db\" OWNER :\"owner\";" "$1" | tr "\n" " " | grep -q "COMMENT ON DATABASE :\"db\" IS :.c_marker.; UPDATE infra_skills.create_intent SET datoid"' _ "$WORK/create-missing/log.sql"
check "--create-missing: each creation's nonce is recorded with the intent, before CREATE DATABASE (round 7 P2-b)" \
  before "$WORK/create-missing/log.sql" "VALUES (:'db', :'app', true, gen_random_uuid()::text)" 'CREATE DATABASE :"db" OWNER :"owner";'
check "--create-missing: the ACL runs in a transaction that checks the database's identity first (round 7 P2-b)" \
  bash -c 'awk "/its ACL is left as it is/{c=NR} /ON DATABASE :\"db\" FROM PUBLIC;/{ if (c && !r) r=NR } /^COMMIT;/{ if (r && !m) m=NR } END{exit !(c && r > c && m > r)}" "$1"' _ "$WORK/create-missing/log.sql"
check "--create-missing: intents are claimed and finished by (app, name) (round 7 P2-a)" \
  bash -c 'grep -q "belongs to another app; nothing created" "$1" && grep -q "SET done_at = now() WHERE datname = :.db. AND app = :.app. AND done_at IS NULL" "$1"' _ "$WORK/create-missing/log.sql"
check "--create-missing: the refusal says how to finish the ACL by hand (round 7 P3)" \
  grep -q "fake --provision-credentials evse-ts --database manifest\[:<PREFIX>\] --revoke-public --keep-connect" "$D/out"
# Round 7 P2-a: another app's pending creation of the same database name, made or not.
STUB_INTENTS='intent|manifest|f|f|other-app' STUB_DB_OWNERS="$(dbrow evse scala_owner; nodb manifest)" \
  bad "--create-missing, another app's pending creation of that name, database not made (round 7 P2-a)" "app other-app has a pending creation of a database by that name" evse-ts --database evse:JOURNAL_DB --database manifest:MANIFEST_DB --create-missing
STUB_INTENTS='intent|manifest|f|f|other-app' STUB_DB_OWNERS="$(dbrow evse scala_owner; dbrow manifest evse-ts t)" \
  bad "--create-missing, another app's pending creation of that name, database made (round 7 P2-a)" "app other-app has a pending creation of a database by that name" evse-ts --database evse:JOURNAL_DB --database manifest:MANIFEST_DB --create-missing

# --revoke-public --keep-connect (P1-d)
bad "--revoke-public without --keep-connect" "--revoke-public needs --keep-connect" x --database evse --revoke-public
bad "--keep-connect without --revoke-public" "--keep-connect goes with --revoke-public" x --database evse --keep-connect a
bad "--revoke-public without --database" "go with --database" x --revoke-public --keep-connect none
bad "--keep-connect with a quote" "is not a role name" x --database evse --revoke-public --keep-connect "a'b"
STUB_NEED='need|other_app|f' STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "--keep-connect names a missing role" "role other_app does not exist" x --database evse --revoke-public --keep-connect other_app
STUB_NO_POOLER_ROLE=1 STUB_NEED='need|other_app|t' STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "--revoke-public, pooler role missing" "cnpg_pooler_pgbouncer does not exist after 60 s" x --database evse --pooler --revoke-public --keep-connect other_app
STUB_NEED=$'need|other_app|t\nneed|reporting|t' STUB_DB_OWNERS="$(dbrow evse scala_owner f f scala_owner f t 'stranger' 'stranger')" \
  PG_READONLY_ROLE=claude_ro run revoke my-app --database evse --pooler --revoke-public --keep-connect other_app,reporting
check "--revoke-public: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
check "--revoke-public: the preflight checks the kept roles and the read-only role" grep -qF "\\set need 'other_app,reporting,claude_ro'" "$D/log.sql"
check "--revoke-public: owner gets CONNECT before the revoke" before "$D/log.sql" "pg_get_userbyid(datdba)) FROM pg_database WHERE datname = :'db'" 'ON DATABASE :"db" FROM PUBLIC;'
check "--revoke-public: the former owner (ledger) gets CONNECT before the revoke" before "$D/log.sql" "ON DATABASE %I TO %I', d.datname, r.rolname" 'ON DATABASE :"db" FROM PUBLIC;'
check "--revoke-public: the kept roles get CONNECT before the revoke" before "$D/log.sql" "unnest(string_to_array(:'keep', ','))" 'ON DATABASE :"db" FROM PUBLIC;'
check "--revoke-public: the kept roles are other_app,reporting" grep -qF "\\set keep 'other_app,reporting'" "$D/log.sql"
check "--revoke-public: read-only and pooler roles get CONNECT before the revoke" before "$D/log.sql" "TO cnpg_pooler_pgbouncer" 'ON DATABASE :"db" FROM PUBLIC;'
check "--revoke-public: revoked once" [ "$(grep -c 'REVOKE CONNECT, TEMPORARY ON DATABASE :"db" FROM PUBLIC' "$D/log.sql")" = 1 ]
check "--revoke-public: warns who loses CONNECT" grep -q "lose CONNECT now: stranger" "$D/out"
check "--revoke-public: and who is connected now" grep -q "connected now: stranger" "$D/out"
check "--revoke-public without --take-ownership: the preflight does not read the ledger (round 4 P2-2)" \
  bash -c '! awk "/^-- ### /{getline t; pre = (t ~ /^-- infra-skills:preflight/)} pre" "$1" | grep -q "JOIN infra_skills.ownership_transfer"' _ "$D/log.sql"
check "--revoke-public: the ledger's trust is checked in the preflight" grep -q "AS l_cols_ok" "$D/log.sql"

# --take-ownership (P2-a, P1-b)
export STUB_DB_OWNERS; STUB_DB_OWNERS="$(dbrow evse scala_owner; dbrow evse_ts scala_owner)"
run own evse-ts --database evse:JOURNAL_DB --database evse_ts:STATE_DB --take-ownership --migration-role
check "--take-ownership: exit 0" [ "$RC" = 0 ]
check "--take-ownership: the ledger is made" grep -q "CREATE TABLE IF NOT EXISTS infra_skills.ownership_transfer" "$D/log.sql"
check "--take-ownership: the original owner is recorded for each database (2)" [ "$(grep -c "INSERT INTO infra_skills.ownership_transfer" "$D/log.sql")" = 2 ]
check "--take-ownership: recorded before anything moves" before "$D/log.sql" "INSERT INTO infra_skills.ownership_transfer" "ALTER DATABASE %I OWNER TO %I"
check "--take-ownership: the owner comes from the ledger, quoted by the server (2)" [ "$(grep -c "ALTER DATABASE %I OWNER TO %I', current_database(), pg_get_userbyid(:to_oid)" "$D/log.sql")" = 2 ]
check "--take-ownership: no REASSIGN OWNED, which moves other databases and tablespaces too (round 5 P1-2)" bash -c '! grep -q "REASSIGN OWNED BY" "$1"' _ "$D/log.sql"
check "--take-ownership: the source's objects are moved one by one (schemas, relations, routines, types, large objects)" \
  bash -c 'for s in "ALTER SCHEMA %I OWNER TO %I" "ALTER %s %s OWNER TO %I" "ALTER ROUTINE %s OWNER TO %I" "ALTER LARGE OBJECT %s OWNER TO %I" "ALTER DEFAULT PRIVILEGES FOR ROLE %I%s GRANT"; do grep -qF "$s" "$1" || exit 1; done' _ "$D/log.sql"
check "--take-ownership: the move runs inside each database" bash -c 'awk "/^\\\\c :\"db\"/{indb=1} /^\\\\c postgres/{indb=0} /ALTER DATABASE %I OWNER TO/{ if (!indb) bad=1 } END{exit bad}" "$1"' _ "$D/log.sql"
check "--take-ownership: bounded waits in each move's transaction (round 5 P2-a)" \
  bash -c '[ "$(grep -B2 "^SET LOCAL statement_timeout = .60s.;" "$1" | tr "\n" " ")" = "BEGIN; SET LOCAL lock_timeout = '"'"'5s'"'"'; SET LOCAL statement_timeout = '"'"'60s'"'"'; -- BEGIN; SET LOCAL lock_timeout = '"'"'5s'"'"'; SET LOCAL statement_timeout = '"'"'60s'"'"'; " ]' _ "$D/log.sql"
check "--take-ownership: CONNECT for the source and the app role again, inside the transaction (round 5)" \
  bash -c '[ "$(grep -A2 "ALTER DATABASE %I OWNER TO %I" "$1" | grep -c "GRANT CONNECT, TEMPORARY")" = 4 ]' _ "$D/log.sql"
check "--take-ownership: no owner name spliced into SQL (P1-b)" bash -c '! grep -q "scala_owner" "$1" && ! grep -q "set old_owner" "$1"' _ "$D/log.sql"
check "--take-ownership: each move is checked (2)" [ "$(grep -c "are still owned by" "$D/log.sql")" = 2 ]
check "--take-ownership: and marked done (2)" [ "$(grep -c "SET done_at = now()" "$D/log.sql")" = 2 ]
check "--take-ownership: new owner is evse-ts_migrate" grep -q "^\\\\set owner 'evse-ts_migrate'" "$D/log.sql"
check "--take-ownership: the migration role exists before the move" \
  before "$D/log.sql" "CREATE ROLE %I LOGIN', :'mrole'" "INSERT INTO infra_skills.ownership_transfer"
STUB_DB_OWNERS="$(dbrow evse evse-ts_migrate t)" run own-again evse-ts --database evse:JOURNAL_DB --take-ownership --migration-role
check "--take-ownership, already owned: no REASSIGN" bash -c '! grep -q REASSIGN "$1"' _ "$D/log.sql"
STUB_DB_OWNERS="$(dbrow evse evse-ts_migrate t t scala_owner f t '' '' evse-ts_migrate t)" run own-retry evse-ts --database evse:JOURNAL_DB --take-ownership --migration-role
check "--take-ownership, unfinished move: completed, not skipped (P2-a)" grep -q "ALTER DATABASE %I OWNER TO" "$D/log.sql"
check "--take-ownership, unfinished move: says so" grep -q "left the move from scala_owner unfinished" "$D/out"
STUB_DB_OWNERS="$(dbrow evse evse-ts_migrate f t scala_owner f t '' '' evse-ts_migrate f)" \
  bad "--take-ownership, unfinished move to another role (P2-2)" "an unfinished move of evse from scala_owner to evse-ts_migrate" evse-ts --database evse:JOURNAL_DB --take-ownership
STUB_LEDGER='ledger|f|t|t' STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "--take-ownership, a ledger schema someone else owns" "is not what this script makes" x --database evse --take-ownership
run own-ledger-late evse-ts --database evse:JOURNAL_DB --take-ownership
check "--take-ownership: the preflight writes nothing (no ledger DDL in it)" bash -c '! awk "/^-- ### /{getline t; pre = (t ~ /^-- infra-skills:preflight/)} pre" "$1" | grep -qE "CREATE (SCHEMA|TABLE)"' _ "$D/log.sql"
check "--take-ownership: the ledger is made after the preflight" grep -q "CREATE TABLE IF NOT EXISTS infra_skills.ownership_transfer" "$D/log.sql"
check "--take-ownership: pending rows are keyed by the database oid" grep -q "ON CONFLICT (datoid) DO UPDATE" "$D/log.sql"
check "--take-ownership: the ledger is read only after its trust check (round 4 P2-2)" before "$D/log.sql" "AS l_cols_ok" "LEFT JOIN infra_skills.ownership_transfer l"
check "--take-ownership: and only behind \\if :use_ledger" before "$D/log.sql" "\\if :use_ledger" "LEFT JOIN infra_skills.ownership_transfer l"
check "--take-ownership: the database moves under a lock on pg_database, after a re-check against the ledger (round 5 P1-3)" \
  bash -c 'awk "/ALTER ROUTINE %s OWNER/{ if (!o) o=NR } /LOCK TABLE pg_catalog.pg_database/{ if (o && !l) l=NR } /as recorded when the move started/{ if (!c) c=NR } /ALTER DATABASE %I OWNER TO/{ if (!r) r=NR } END{exit !(o && l > o && c > l && r > c)}" "$1"' _ "$D/log.sql"
STUB_DB_OWNERS="$(dbrow evse postgres f f postgres t)" bad "--take-ownership from a superuser" "a superuser or system role" x --database evse --take-ownership
# Round 5 P1-2: the old owner's other databases and tablespaces no longer block a move (none is touched).
STUB_DB_OWNERS="$(dbrow evse scala_owner)" run own-shared x --database evse --take-ownership
check "--take-ownership, the owner has other databases or tablespaces: no refusal on that ground (round 5 P1-2)" [ "$RC" = 0 ]
check "--take-ownership: the preflight no longer looks for the owner's other databases" bash -c '! grep -q "pg_tablespace" "$1"' _ "$D/log.sql"
# Round 5 P1-3: a pending move whose database owner was changed by hand since is refused.
STUB_DB_OWNERS="$(dbrow evse hand_owner f t scala_owner f t '' '' x t f)" \
  bad "--take-ownership, owner changed by hand during an unfinished move (round 5 P1-3)" "is owned by hand_owner now, not by scala_owner as recorded" x --database evse --take-ownership

# Round 6 P2-b/P2-c/P3: the second preflight, inside the databases to move, before any password.
STUB_OBJECTS='objects|evse|pg_collation, pg_operator' STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "--take-ownership, the source owns kinds the move does not handle (round 6 P2-b)" "also owns objects this script does not move (pg_collation, pg_operator)" x --database evse --take-ownership
check "--take-ownership, unhandled kinds: refused before any password is made (no openssl call)" bash -c '! grep -q "^openssl" "$1"' _ "$D/log"
STUB_OBJECTS='defacl|evse|functions: EXECUTE revoked from PUBLIC (a built-in default)' STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "--take-ownership, default privileges that cannot be copied (round 6 P2-c)" "cannot be copied exactly: functions: EXECUTE revoked from PUBLIC" x --database evse --take-ownership
STUB_OBJECTS='extskip|evse|1 object(s) in extension btree_gin (owned by postgres); extension pg_trgm (its own)' STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  run own-extskip x --database evse --take-ownership
check "--take-ownership, extension objects: not a refusal (round 6 P3)" [ "$RC" = 0 ]
check "--take-ownership, extension objects: the warning names what stays, members of others' extensions too (round 6 P3)" \
  grep -q "these stay with the old owner .*1 object(s) in extension btree_gin (owned by postgres); extension pg_trgm (its own)" "$D/out"
check "--take-ownership: the second preflight runs inside each database to move, with the source's oid" \
  bash -c 'awk "/^-- infra-skills:preflight-objects/{p=1} p" "$1" | grep -q "^\\\\set src 16600$"' _ "$D/log.sql"
check "--take-ownership: the second preflight comes before any credential change" before "$D/log.sql" "-- infra-skills:preflight-objects" "ALTER ROLE"
check "--take-ownership: no extension warning left in the move's transaction (round 6 P3)" bash -c '! grep -q "RAISE WARNING" "$1"' _ "$D/log.sql"
# Round 6 P1-2: the ledger row and the move are bound to the preflight's database oid and the guarded role oid.
check "--take-ownership: the ledger insert takes the database by the preflight's oid and the guarded role oid (round 6 P1-2)" \
  bash -c 'grep -q "^\\\\set datoid 17700$" "$1" && grep -q "WHERE d.oid = :datoid AND d.datname = :.db. AND n.oid = :dest_goid AND n.rolname = :.owner." "$1" && grep -q "was dropped and made again since the preflight (another oid under the same name)" "$1"' _ "$D/log.sql"
check "--take-ownership: the guarded oid comes from the role transaction (round 6 P1-2)" \
  bash -c 'grep -B1 "^COMMIT;" "$1" | grep -q "SELECT oid AS app_goid FROM pg_roles WHERE rolname = :.role. \\\\gset" && grep -q "^\\\\set dest_goid :app_goid$" "$1"' _ "$D/log.sql"
# Round 7 P2-c: with moves, an existing role's new password comes only after every move committed;
# a role made in this run gets its password when it is created.
STUB_ROLES="$(rolerow app x; rolerow migrate x_mig)" STUB_DB_OWNERS="$(dbrow evse scala_owner)" run own-late x --database evse --take-ownership --migration-role x_mig
check "--take-ownership, existing roles: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
check "--take-ownership, existing roles: no password before the move (round 7 P2-c)" \
  bash -c 'awk "/PASSWORD :.pw./{ if (!p) p=NR } /ALTER DATABASE %I OWNER TO/{a=NR} END{exit !(a && p > a)}" "$1"' _ "$D/log.sql"
check "--take-ownership, existing roles: both passwords after it, each in a guarded transaction (round 7 P2-c)" \
  bash -c '[ "$(awk "/ALTER DATABASE %I OWNER TO/{a=1} a && /WITH LOGIN PASSWORD :.pw./{n++} END{print n+0}" "$1")" = 2 ] && [ "$(awk "/ALTER DATABASE %I OWNER TO/{a=1} a && /LOCK TABLE pg_catalog.pg_authid/{n++} END{print n+0}" "$1")" = 2 ]' _ "$D/log.sql"
STUB_DB_OWNERS="$(dbrow evse scala_owner)" run own-new x --database evse --take-ownership
check "--take-ownership, a role made in this run: its password at creation, before the move (round 7 P2-c)" before "$D/log.sql" "PASSWORD :'pw'" "ALTER DATABASE %I OWNER TO"
# Round 7 P2-d: the destination already has other default privileges in the database.
STUB_OBJECTS='dstacl|evse|tables: x has PUBLIC SELECT, the copy from the old owner gives nothing' STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "--take-ownership, the destination's own default privileges differ (round 7 P2-d)" "x already has default privileges that differ from what the copy would give: tables: x has PUBLIC SELECT, the copy from the old owner gives nothing" x --database evse --take-ownership
check "--take-ownership: the destination's default privileges are compared in the second preflight (round 7 P2-d)" \
  bash -c 'awk "/^-- infra-skills:preflight-objects/{p=1} /^-- ### /{p=0} p" "$1" | grep -q "SELECT .dstacl."' _ "$WORK/own-new/log.sql"
# --- 3. migration role --------------------------------------------------------------------
echo "== 3. --migration-role"
run mig evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role \
  --migration-schema evse.archive --migration-schema evse.backfill
check "migration: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
sql="$(cat "$D/log.sql")"; s="$D/fake/secrets.plain/evse-ts-db.secret.yaml"; m="$D/fake/secrets.plain/evse-ts-db-migrate.secret.yaml"
check "migration: role evse-ts_migrate" contains "$sql" "\\set mrole 'evse-ts_migrate'"
check "migration: its marker" contains "$sql" "\\set marker 'infra-skills:migrate:evse-ts'"
check "migration: connection limit 2" contains "$sql" "ALTER ROLE :\"mrole\" WITH LOGIN PASSWORD :'pw' CONNECTION LIMIT 2;"
check "migration: password statement with log_statement none" bash -c 'grep -B4 "ALTER ROLE :\"mrole\" WITH LOGIN PASSWORD" "$1" | grep -q "SET LOCAL log_statement = .none."' _ "$D/log.sql"
check "migration: password statement errors not logged with their text (P1-c)" bash -c 'grep -B4 "ALTER ROLE :\"mrole\" WITH LOGIN PASSWORD" "$1" | grep -q "SET LOCAL log_min_error_statement = .panic."' _ "$D/log.sql"
check "migration: nor slow-statement logged" bash -c 'grep -B4 "ALTER ROLE :\"mrole\" WITH LOGIN PASSWORD" "$1" | grep -q "SET LOCAL log_min_duration_statement = -1"' _ "$D/log.sql"
check "migration: statement_timeout 0" contains "$sql" 'ALTER ROLE :"mrole" SET statement_timeout = 0;'
check "migration: idle_in_transaction_session_timeout 0" contains "$sql" 'ALTER ROLE :"mrole" SET idle_in_transaction_session_timeout = 0;'
check "migration: no membership in the app role (P2-d)" lacks "$sql" "format('GRANT %I TO %I', :'role', :'mrole')"
check "migration: no REVOKE of a membership (a membership is refused instead, round 5 P2-c)" lacks "$sql" "format('REVOKE %I FROM %I'"
check "migration: each role's marker and password in one guarded transaction (round 5 P1-1)" \
  bash -c 'awk "/^BEGIN;/{t=1; g=0; m=0} /LOCK TABLE pg_catalog.pg_auth_members/{ if (t) g=1 } /COMMENT ON ROLE/{ if (t && g) m=1 } /WITH LOGIN PASSWORD :.pw./{ if (t && g && m) ok++ } /^COMMIT;/{t=0} END{exit !(ok == 2)}" "$1"' _ "$D/log.sql"
check "migration: the guard checks the app and migration roles against each other (round 5 P2-c)" \
  bash -c 'grep -qF "set_config('"'"'infra_skills.g_other'"'"', '"'"'evse-ts_migrate'"'"', true)" "$1" && grep -qF "set_config('"'"'infra_skills.g_other'"'"', '"'"'evse-ts'"'"', true)" "$1"' _ "$D/log.sql"
check "migration: CONNECT on each database (2)" [ "$(grep -c 'GRANT CONNECT, TEMPORARY ON DATABASE :"db" TO :"mrole"' "$D/log.sql")" = 2 ]
check "migration: CREATE on the database with migration schemas only (1)" [ "$(grep -c 'GRANT CREATE ON DATABASE :"db" TO :"mrole"' "$D/log.sql")" = 1 ]
check "migration: its schemas in evse" contains "$sql" "\\set mschemas 'archive backfill'"
check "migration: the schemas are created for it" contains "$sql" "CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I"
check "migration: explicit rights in each database (2)" [ "$(grep -c "GRANT USAGE, CREATE ON SCHEMA %I TO %I', nspname, :'mrole'" "$D/log.sql")" = 2 ]
check "migration: default privileges for it, tables (2)" [ "$(grep -c 'ALTER DEFAULT PRIVILEGES FOR ROLE :"mrole" GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO :"role"' "$D/log.sql")" = 2 ]
check "migration: default privileges for it, sequences (2)" [ "$(grep -c 'ALTER DEFAULT PRIVILEGES FOR ROLE :"mrole" GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"role"' "$D/log.sql")" = 2 ]
check "migration: the app role keeps 60s" contains "$sql" "\\set stmt_to '60s'"
check "migration: Secret evse-ts-db-migrate" [ "$(yq -r '.metadata.name + "/" + .metadata.namespace' "$m")" = evse-ts-db-migrate/symbioen ]
check "migration: same keys as the app Secret" diff <(yq -r '.stringData | keys | .[]' "$s") <(yq -r '.stringData | keys | .[]' "$m")
check "migration: JOURNAL_DB_USERNAME evse-ts_migrate" [ "$(key "$m" JOURNAL_DB_USERNAME)" = evse-ts_migrate ]
check "migration: Pooler host" [ "$(key "$m" STATE_DB_HOST)" = pooler-evse-ts.postgres.svc.cluster.local ]
check "migration: its own password" bash -c '[[ -n "$1" && -n "$2" && "$1" != "$2" ]]' _ "$(key "$s" JOURNAL_DB_PASSWORD)" "$(key "$m" JOURNAL_DB_PASSWORD)"
check "migration: both Secrets applied" bash -c '[ -f "$1/evse-ts-db.secret.yaml" ] && [ -f "$1/evse-ts-db-migrate.secret.yaml" ]' _ "$D/log.applied"

run mig-named my-app --migration-role my_app_ddl --migration-connection-limit 3 --migration-schema my-app.flyway
check "migration, default path: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
check "migration, default path: the app session is unchanged (second session = golden; the guard names the migration role)" \
  diff <(awk '/^-- ### /{n++} n==2' "$D/log.sql" | norm | sed "s/'infra_skills.g_other', 'my_app_ddl'/'infra_skills.g_other', ''/") <(awk '/^-- ### /{n++} n==2' "$HERE/golden/plain.sql")
check "migration, default path: named role, limit 3" contains "$(cat "$D/log.sql")" "\\set mrole 'my_app_ddl'"
check "migration, default path: limit 3" grep -q "CONNECTION LIMIT 3;" "$D/log.sql"
check "migration, default path: its schema flyway" grep -qF "\\set mschemas 'flyway'" "$D/log.sql"
check "migration, default path: CREATE on my-app" grep -qF 'GRANT CREATE ON DATABASE :"db" TO :"mrole";' "$D/log.sql"
check "migration, default path: POSTGRES_USERNAME my_app_ddl" [ "$(key "$D/fake/secrets.plain/my-app-db-migrate.secret.yaml" POSTGRES_USERNAME)" = my_app_ddl ]
check "migration, default path: POSTGRES_DATABASE my-app" [ "$(key "$D/fake/secrets.plain/my-app-db-migrate.secret.yaml" POSTGRES_DATABASE)" = my-app ]
check "migration, default path: the app Secret keeps the legacy rendering" grep -q '^  POSTGRES_HOST: postgres-cluster-rw' "$D/fake/secrets.plain/my-app-db.secret.yaml"
bad "a migration role named like the app role" "Invalid migration role name" my-app --migration-role my-app
bad "--migration-connection-limit without --migration-role" "--migration-connection-limit goes with --migration-role" x --migration-connection-limit 3
bad "--migration-schema without --migration-role" "--migration-schema goes with --migration-role" x --migration-schema x.s
bad "--migration-schema in a database not named" "is not one of this run's databases" x --database evse --migration-role --migration-schema other.s
bad "--migration-schema pg_*" "give <database>.<schema>" x --database evse --migration-role --migration-schema evse.pg_x
out="$(STUB_LOG="$WORK/p.log" INFRA_ENVS_ROOT="$WORK/golden-plain" "$SCRIPT" fake --migration-role 2>&1 || true)"
check "--migration-role alone: refused before any call" contains "$out" "go with --provision-credentials"

# Role names (P1-a)
bad "--migration-role postgres" "reserved role" x --database evse --migration-role postgres
bad "--migration-role pg_monitor" "reserved role" x --database evse --migration-role pg_monitor
bad "--migration-role app (CNPG's owner)" "reserved role" x --migration-role app
bad "--migration-role streaming_replica" "reserved role" x --migration-role streaming_replica
PG_READONLY_ROLE=claude_ro bad "--migration-role = PG_READONLY_ROLE" "reserved role" x --migration-role claude_ro
bad "app id postgres" "reserved role" postgres
bad "app id app" "reserved role" app
STUB_ROLES="$(rolerow migrate x_mig t f '' SUPERUSER)" STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "a superuser migration role" "exists with SUPERUSER" x --database evse --migration-role x_mig
STUB_ROLES="$(rolerow migrate x_mig t t '' CREATEROLE,CREATEDB)" STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "a CREATEROLE migration role, even marked" "exists with CREATEROLE,CREATEDB" x --database evse --migration-role x_mig
STUB_ROLES="$(rolerow migrate x_mig t t '' '' pg_write_server_files)" STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "a migration role in pg_write_server_files" "belongs to pg_write_server_files" x --database evse --migration-role x_mig
STUB_ROLES="$(rolerow migrate x_mig t f)" STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "an unmarked migration role" "was not made by this script for x" x --database evse --migration-role x_mig
STUB_ROLES="$(rolerow migrate x_mig t f 'infra-skills:migrate:other')" STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "another app's migration role" "was not made by this script for x" x --database evse --migration-role x_mig
STUB_ROLES="$(rolerow migrate x_mig t f)" bad "an unmarked migration role, default path" "was not made by this script for x" x --migration-role x_mig
STUB_ROLES="$(rolerow app x t f)" STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "an unmarked app role (--database)" "was not made by this script for x" x --database evse
STUB_ROLES="$(rolerow app x t f '' '' '' t)" STUB_DB_OWNERS="$(dbrow evse scala_owner)" run adopt x --database evse
check "an app role made by the default path: adopted" [ "$RC" = 0 ]
check "an app role made by the default path: says so" grep -q "adopting it as this app's role" "$D/out"
check "an app role made by the default path: gets the marker" grep -qF "COMMENT ON ROLE %I IS %L', :'role', :'marker'" "$D/log.sql"
STUB_ROLES="$(rolerow app x; rolerow migrate x_mig)" STUB_DB_OWNERS="$(dbrow evse scala_owner)" run marked x --database evse --migration-role x_mig
check "marked roles: reused" [ "$RC" = 0 ]
STUB_ROLES="$(rolerow app x t f)" bad "plain default path, an unrelated unmarked role (round 4 P1-1)" "Role x exists but was not made by this script for x" x
STUB_ROLES="$(rolerow app x t f '' '' pg_read_all_data t)" bad "plain default path, a legacy role in pg_read_all_data" "belongs to pg_read_all_data" x
# Round 5 P1-1: a legacy role is adopted only with LOGIN and no membership at all, either direction.
STUB_ROLES="$(rolerow app x t f '' '' '' t f)" bad "plain default path, a NOLOGIN owner (round 5 P1-1)" "it has NOLOGIN" x
STUB_ROLES="$(rolerow app x t f '' '' '' t t 'member of some_group')" bad "plain default path, an owner in a group (round 5 P1-1)" "role memberships (member of some_group)" x
STUB_ROLES="$(rolerow app x t f '' '' '' t t 'has member someone')" STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "--database, an owner with a member (round 5 P1-1)" "role memberships (has member someone)" x --database evse
# Round 5 P2-c: app and migration role members of one another, by any path.
STUB_ROLES="$(rolerow app x t t '' '' '' f t 'member of grp' t; rolerow migrate x_mig t t '' '' '' f t 'member of grp' t)" STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "app and migration role members of one another (round 5 P2-c)" "are members of one another" x --database evse --migration-role x_mig
STUB_ROLES="$(rolerow app x t f '' '' '' t)" run guard-oid x
check "default path: the guard gets the role's oid from the preflight (round 5 P1-1)" grep -qF "set_config('infra_skills.g_oid', '16500', true)" "$D/log.sql"
check "default path: CREATE ROLE, the marker and the password in one transaction after the guard (round 5 P1-1)" \
  bash -c 'awk "/^BEGIN;/{b=NR} /LOCK TABLE pg_catalog.pg_authid/{ if (b && !l) l=NR } /^DO \\$\\$/{ if (l && !g) g=NR } /CREATE ROLE %I LOGIN/{ if (g && !c) c=NR } /COMMENT ON ROLE/{ if (c && !m) m=NR } /PASSWORD :.pw./{ if (m && !p) p=NR } /^COMMIT;/{ if (p && !e) e=NR } END{exit !(e > p)}" "$1"' _ "$D/log.sql"
check "default path: the guard also locks pg_database and pg_shdescription before its check (round 6 P1-1)" \
  bash -c '[ "$(grep -A3 "^LOCK TABLE pg_catalog.pg_authid IN SHARE ROW EXCLUSIVE MODE;" "$1" | sed -n 2,4p | tr "\n" " ")" = "LOCK TABLE pg_catalog.pg_auth_members IN SHARE ROW EXCLUSIVE MODE; LOCK TABLE pg_catalog.pg_database IN SHARE ROW EXCLUSIVE MODE; LOCK TABLE pg_catalog.pg_shdescription IN SHARE ROW EXCLUSIVE MODE; " ]' _ "$D/log.sql"
STUB_ROLES="$(rolerow app x t f '' '' '' t)" run plain-legacy x
check "plain default path, the default path's own legacy role (owns database x): adopted" [ "$RC" = 0 ]
check "plain default path: says so" grep -q "adopting it as this app's role" "$D/out"
check "plain default path: the role gets the marker" grep -qF "COMMENT ON ROLE %I IS %L', :'role', 'infra-skills:app:x'" "$D/log.sql"
check "plain default path: the preflight runs before any change" before "$D/log.sql" "-- infra-skills:preflight" "CREATE ROLE %I LOGIN"
STUB_ROLES="$(rolerow app x t f)" bad "default path + --migration-role, an unrelated unmarked app role (P1-2)" "Role x exists but was not made by this script for x" x --migration-role
STUB_ROLES="$(rolerow app x t f '' SUPERUSER)" bad "default path + --keep-password, a superuser app role (P1-2)" "exists with SUPERUSER" x --keep-password
STUB_ROLES="$(rolerow app x t f '' '' '' t)" run legacy-mig x --migration-role
check "default path + --migration-role, the default path's own role (owns database x): accepted" [ "$RC" = 0 ]
check "default path + --migration-role: the hint names --take-ownership (P2-4)" grep -q "take-ownership --migration-role x_migrate" "$D/out"
check "default path + --migration-role: and says what the role cannot do" grep -q "cannot ALTER or DROP what other" "$D/out"
STUB_DB_OWNERS="$(dbrow evse scala_owner)" run hint-own x --database evse --take-ownership --migration-role
check "--take-ownership --migration-role: no hint" bash -c '! grep -q "cannot ALTER or DROP what other" "$1"' _ "$D/out"

# --- 4. limits ----------------------------------------------------------------------------
echo "== 4. connection limits and timeouts"
run limit evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --connection-limit 40
check "limit 40: role" grep -q "CONNECTION LIMIT 40;" "$D/log.sql"
check "limit 40: Pooler pool size" [ "$(jq -r '.spec.pgbouncer.parameters.default_pool_size' "$D/log.applied/stdin-0.json")" = 40 ]
run limit-default evse-ts --tenant symbioen --database evse:JOURNAL_DB
check "tenant default: 20" grep -q "CONNECTION LIMIT 20;" "$D/log.sql"
bad "a non-numeric limit" "connection limit must be a number" x --connection-limit lots --database evse
bad "a limit beyond int (P1-c)" "connection limit must be a number from -1 to 2147483647" x --connection-limit 99999999999 --database evse
bad "a limit of 2147483648" "connection limit must be a number from -1" x --connection-limit 2147483648
bad "a limit of -2" "connection limit must be a number from -1" x --connection-limit -2 --database evse
bad "a migration limit beyond int" "migration connection limit must be a number from 1" x --database evse --migration-role --migration-connection-limit 99999999999
bad "a migration limit of 0" "migration connection limit must be a number from 1" x --migration-role --migration-connection-limit 0
bad "a statement timeout beyond int ms" "not a Postgres duration" x --statement-timeout 999999h --database evse
run limit-spelling my-app --connection-limit 0030
check "default path: --connection-limit 0030 keeps its spelling (P3)" grep -qF "CONNECTION LIMIT 0030;" "$D/log.sql"
STUB_NO_POOLER_ROLE=1 bad "--pooler, pooler role missing, default path (P2-1)" "cnpg_pooler_pgbouncer does not exist after 60 s" x --pooler
STUB_NO_POOLER_ROLE=1 STUB_DB_OWNERS="$(nodb manifest)" \
  bad "--create-missing --pooler, pooler role missing (P2-1)" "cnpg_pooler_pgbouncer does not exist after 60 s" x --database manifest --create-missing --pooler
STUB_NO_POOLER_ROLE=1 STUB_DB_OWNERS="$(dbrow evse scala_owner)" run pooler-grant-mode x --database evse --pooler
check "--pooler in grant mode (PUBLIC stays open): no pooler role needed" [ "$RC" = 0 ]

# --- 5. re-runs ---------------------------------------------------------------------------
echo "== 5. re-runs"
run rerun evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role
first_sql="$(norm < "$D/log.sql")"; first_argv="$(grep -v '^openssl' "$D/log" | norm)"
first_pw="$(key "$D/fake/secrets.plain/evse-ts-db.secret.yaml" JOURNAL_DB_PASSWORD)"
first_mpw="$(key "$D/fake/secrets.plain/evse-ts-db-migrate.secret.yaml" JOURNAL_DB_PASSWORD)"
PRE_RUN="$D" run rerun evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role
check "re-run: exit 0" [ "$RC" = 0 ]
check "re-run: same SQL (passwords aside)" [ "$first_sql" = "$(norm < "$D/log.sql")" ]
check "re-run: same kubectl calls" [ "$first_argv" = "$(grep -v '^openssl' "$D/log" | norm)" ]
check "re-run: a new password by default" [ "$first_pw" != "$(key "$D/fake/secrets.plain/evse-ts-db.secret.yaml" JOURNAL_DB_PASSWORD)" ]
[[ "$first_mpw" != "$(key "$D/fake/secrets.plain/evse-ts-db-migrate.secret.yaml" JOURNAL_DB_PASSWORD)" ]] || fail "re-run: migration password changed between the first two runs"
kept_pw="$(key "$D/fake/secrets.plain/evse-ts-db.secret.yaml" JOURNAL_DB_PASSWORD)"
kept_mpw="$(key "$D/fake/secrets.plain/evse-ts-db-migrate.secret.yaml" JOURNAL_DB_PASSWORD)"
LIVE="$WORK/live-verifiers"; { echo "evse-ts $(verifier_of "$kept_pw")"; echo "evse-ts_migrate $(verifier_of "$kept_mpw")"; } > "$LIVE"
STALE="$WORK/stale-verifiers"; { echo "evse-ts $(verifier_of "Pw0Stub999ChangedElsewhere+/=")"; echo "evse-ts_migrate $(verifier_of "$kept_mpw")"; } > "$STALE"
secret_before="$(cat "$D/fake/secrets.plain/evse-ts-db.secret.yaml")"
STUB_VERIFIERS="$STALE" STUB_ROLES="$(rolerow app evse-ts; rolerow migrate evse-ts_migrate)" \
  PRE_RUN="$D" run rerun evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role --keep-password
check "--keep-password, stored password is stale: refused (P2-3)" [ "$RC" != 0 ]
check "--keep-password, stale: says so" grep -q "is not role evse-ts's password in the cluster" "$D/out"
check "--keep-password, stale: the Secret file is untouched" [ "$secret_before" = "$(cat "$D/fake/secrets.plain/evse-ts-db.secret.yaml")" ]
check "--keep-password, stale: nothing applied, no SQL change" bash -c '[ ! -e "$1/log.applied" ] && ! grep -q "ALTER ROLE" "$1/log.sql"' _ "$D"
STUB_VERIFIERS="$LIVE" STUB_ROLES="$(rolerow app evse-ts; rolerow migrate evse-ts_migrate)" \
  PRE_RUN="$D" run rerun evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role --keep-password
check "--keep-password, roles exist: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
check "--keep-password: no new password made" bash -c '! grep -q "^openssl" "$1"' _ "$D/log"
check "--keep-password, roles exist: no password sent at all (P2-c)" bash -c '! grep -q "PASSWORD" "$1" && ! grep -qF "$2" "$1" && ! grep -qF "$3" "$1"' _ "$D/log.sql" "$kept_pw" "$kept_mpw"
check "--keep-password, roles exist: limits still set" bash -c 'grep -qF "ALTER ROLE :\"role\" WITH LOGIN CONNECTION LIMIT 20;" "$1" && grep -qF "ALTER ROLE :\"mrole\" WITH LOGIN CONNECTION LIMIT 2;" "$1"' _ "$D/log.sql"
check "--keep-password: app password kept in the Secret" [ "$kept_pw" = "$(key "$D/fake/secrets.plain/evse-ts-db.secret.yaml" STATE_DB_PASSWORD)" ]
check "--keep-password: migration password kept in the Secret" [ "$kept_mpw" = "$(key "$D/fake/secrets.plain/evse-ts-db-migrate.secret.yaml" STATE_DB_PASSWORD)" ]
check "--keep-password: the password is not in the output" bash -c '! grep -qF -e "$2" -e "$3" "$1"' _ "$D/out" "$kept_pw" "$kept_mpw"
# Round 5 P2-b: the password is rotated elsewhere after the first check; the re-check before the
# Secret is written and applied catches it.
secret_before="$(cat "$D/fake/secrets.plain/evse-ts-db.secret.yaml")"
STUB_VERIFIERS="$LIVE" STUB_VERIFIERS_LATER="$STALE" STUB_ROLES="$(rolerow app evse-ts; rolerow migrate evse-ts_migrate)" \
  PRE_RUN="$D" run rerun evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role --keep-password
check "--keep-password, rotated after the first check: refused (round 5 P2-b)" [ "$RC" != 0 ]
check "--keep-password, rotated after the first check: says so" grep -q "role evse-ts's password changed during this run" "$D/out"
check "--keep-password, rotated after the first check: the verifier was read twice" [ "$(cat "$D/log.vread.evse-ts")" = 2 ]
check "--keep-password, rotated after the first check: the Secret file is untouched, nothing applied" \
  bash -c '[ "$1" = "$(cat "$2/fake/secrets.plain/evse-ts-db.secret.yaml")" ] && [ ! -e "$2/log.applied/evse-ts-db.secret.yaml" ]' _ "$secret_before" "$D"
PRE_RUN="$D" run rerun evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role --keep-password
check "--keep-password, roles missing: exit 0" [ "$RC" = 0 ]
check "--keep-password, roles missing: created with the stored password (its verifier)" \
  matches "$kept_pw" "$(sed -n "s/^\\\\set pw '\\(SCRAM-[^']*\\)'$/\\1/p" "$D/log.sql" | head -1)"
rr="$D"
yq -i ".stringData.STATE_DB_PASSWORD = \"Pw0Stub99AbCdEfGhIjKlMn+/=\"" "$rr/fake/secrets.plain/evse-ts-db.secret.yaml" \
  || fail "--keep-password: fixture: no Secret file to edit"
STUB_ROLES="$(rolerow app evse-ts)" PRE_RUN="$rr" run rerun evse-ts --tenant symbioen --database evse:JOURNAL_DB --database evse_ts:STATE_DB --keep-password
check "--keep-password, *_PASSWORD values disagree: refused (P2-c)" [ "$RC" != 0 ]
check "--keep-password, *_PASSWORD values disagree: says so" grep -q "they must all agree" "$D/out"
check "--keep-password, *_PASSWORD values disagree: no role change" bash -c '! grep -q "ALTER ROLE" "$1"' _ "$D/log.sql"
bad "--keep-password with no Secret file" "holds no usable *_PASSWORD" x --database evse --keep-password
run keep-default my-app
echo "my-app $(verifier_of "$(key "$D/fake/secrets.plain/my-app-db.secret.yaml" POSTGRES_PASSWORD)")" > "$WORK/live-default"
STUB_VERIFIERS="$WORK/live-default" STUB_ROLES="$(rolerow app my-app t f '' '' '' t)" PRE_RUN="$D" run keep-default my-app --keep-password
check "--keep-password, default path, role exists: exit 0" [ "$RC" = 0 ]
check "--keep-password, default path, role exists: no password sent" bash -c '! grep -q "PASSWORD" "$1"' _ "$D/log.sql"
check "--keep-password, default path: legacy Secret rendering" grep -q '^  POSTGRES_PASSWORD: Pw0Stub' "$D/fake/secrets.plain/my-app-db.secret.yaml"

# --- 6. openssl failures (P2-b) -----------------------------------------------------------
echo "== 6. password generation failures"
STUB_OPENSSL_FAIL=1 bad "openssl fails, default path" "Could not make a password" my-app
STUB_OPENSSL_SHORT=1 bad "openssl prints a short password, default path" "Could not make a password" my-app
STUB_OPENSSL_FAIL=1 STUB_DB_OWNERS="$(dbrow evse scala_owner)" bad "openssl fails, --database" "Could not make a password" x --database evse
STUB_OPENSSL_SHORT=1 STUB_DB_OWNERS="$(dbrow evse scala_owner)" bad "openssl short, migration role" "Could not make a password" x --database evse --migration-role

# --- 6b. no secret in a child's environment (round 4 P2-1) ------------------------------
echo "== 6b. exported names and SHELLOPTS=allexport"
LEAK_ENV="env SHELLOPTS=allexport app_password=placeholder mig_password=placeholder app_verifier=placeholder mig_verifier=placeholder _pw=placeholder _v=placeholder _live=placeholder _pws=placeholder"
for args in "my-app" "evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --migration-role"; do
  # shellcheck disable=SC2086  # word splitting of the argument list is meant
  STUB_DB_OWNERS="$(dbrow evse scala_owner)" TRACE="$LEAK_ENV" run envleak $args
  check "exported names ($args): exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "exported names ($args): perl ran (sanity)" grep -q "^### perl .*pg-scram.pl make" "$D/log.env"
  check "exported names ($args): the caller's exported names reach the children (sanity)" grep -q "^app_password=placeholder$" "$D/log.env"
  check "exported names ($args): no password or verifier in any child's environment" bash -c '! grep -qE "$2|SCRAM-SHA-256" "$1"' _ "$D/log.env" "$PW_RE"
done

# --- 7. no secret under bash -x -----------------------------------------------------------
echo "== 7. bash -x"
xtrace() { # <name> <args...>
  local name="$1"; shift
  TRACE="bash -x" run "$name" "$@"
  check "$name: exit 0" [ "$RC" = 0 ]
  check "$name: the trace is on (sanity)" grep -q '^+' "$D/out"
  check "$name: the verifiers went to psql on stdin (sanity)" grep -qE "$SCRAM_RE" "$D/log.sql"
  check "$name: no password in stdout/stderr" bash -c '! grep -qE "$2" "$1"' _ "$D/out" "$PW_RE"
  check "$name: no password on any kubectl argv" bash -c '! grep -qE "$2" "$1"' _ "$D/log" "$PW_RE"
  check "$name: no verifier in stdout/stderr either" bash -c '! grep -qE "$2" "$1"' _ "$D/out" "$SCRAM_RE"
}
xtrace xtrace-default evse-ts --tenant symbioen --pooler
xtrace xtrace-existing evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role
D="$WORK/xtrace-existing"; PRE_RUN="$D" TRACE="bash -x" run xtrace-existing evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role --keep-password
check "xtrace --keep-password: exit 0" [ "$RC" = 0 ]
check "xtrace --keep-password: no password in stdout/stderr" bash -c '! grep -qE "$2" "$1"' _ "$D/out" "$PW_RE"
unset STUB_DB_OWNERS

# --- 8. a real server ---------------------------------------------------------------------
if $REAL; then
  echo "== 8. real Postgres (local, unix socket only, every statement logged, sampled logging on)"
  for t in initdb pg_ctl psql; do command -v "$t" >/dev/null 2>&1 || { echo "Missing: $t" >&2; exit 1; }; done
  PGDIR="$(mktemp -d -t pgc-XXXX)"; export STUB_PGHOST="$PGDIR" STUB_PGPORT=54329
  initdb -D "$PGDIR/data" -U postgres --auth=trust >/dev/null
  pg_ctl -D "$PGDIR/data" -l "$PGDIR/log" -w \
    -o "-c listen_addresses='' -k $PGDIR -p $STUB_PGPORT -c log_statement=all -c log_min_duration_statement=0 -c log_min_duration_sample=0 -c log_statement_sample_rate=1 -c log_transaction_sample_rate=1" start >/dev/null
  # The database scramcheck takes SCRAM-SHA-256 only, every other one trusts the local socket.
  printf 'local scramcheck all scram-sha-256\nlocal all all trust\n' > "$PGDIR/data/pg_hba.conf"
  pg_ctl -D "$PGDIR/data" reload >/dev/null
  HOLDERS=()
  cleanup() {
    local p; for p in ${HOLDERS[@]+"${HOLDERS[@]}"}; do kill "$p" 2>/dev/null || true; done
    pg_ctl -D "$PGDIR/data" -m immediate stop >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  q() { # <user> <db> <sql>: one value
    psql -h "$PGDIR" -p "$STUB_PGPORT" -U "$1" -d "$2" -XtAq -v ON_ERROR_STOP=1 -c "$3" 2>&1
  }
  can() { q "$@" >/dev/null 2>&1; }
  not() { ! "$@"; }
  owner_of_db() { q postgres postgres "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$1'"; }
  # hold <db> <sql>: run <sql> in an open transaction in the background (a lock holder) until
  # release; returns once this holder's own backend (application_name holder-<n>) sleeps.
  HOLD_N=0
  hold() {
    HOLD_N=$((HOLD_N + 1))
    printf 'BEGIN;\n%s\nSELECT pg_sleep(60);\n' "$2" \
      | PGAPPNAME="holder-$HOLD_N" psql -h "$PGDIR" -p "$STUB_PGPORT" -U postgres -d "$1" -Xq >/dev/null 2>&1 &
    HOLDERS+=($!)
    local _; for _ in $(seq 1 50); do
      [[ "$(q postgres postgres "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'holder-$HOLD_N' AND query LIKE 'SELECT pg_sleep(60)%' AND state = 'active'")" -ge 1 ]] && return 0
      /bin/sleep 0.1
    done
    return 1
  }
  # release: end every holder and wait until their backends are gone.
  release() {
    q postgres postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name LIKE 'holder-%'" >/dev/null
    local _; for _ in $(seq 1 50); do
      [[ "$(q postgres postgres "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'holder-%'")" == 0 ]] && return 0
      /bin/sleep 0.1
    done
  }
  # The passwords a run sent on the paths this change protects: every \set pw / \set mpw except the
  # default path's own app statement (\set db before it, \set ro after it; unchanged from origin/main).
  protected_pws() {
    awk 'function emit() { if (pw != "" && !(before ~ /^\\set db / && $0 ~ /^\\set ro /)) print pw; pw = "" }
         { emit() }
         /^\\set m?pw '"'"'/ { pw = $0; sub(/^\\set m?pw '"'"'/, "", pw); sub(/'"'"'$/, "", pw); before = prev }
         { prev = $0 } END { if (pw != "") print pw }' "$1"
  }
  PROTECTED="$WORK/protected-passwords"; : > "$PROTECTED"
  collect() { protected_pws "$D/log.sql" >> "$PROTECTED"; }
  client_clean() { # <log.sql> <out>: no protected password of the run in its output
    local p; while IFS= read -r p; do [[ -n "$p" ]] && grep -qF -- "$p" "$2" && return 1; done < <(protected_pws "$1"); return 0
  }

  # Fixture: the Scala-era owner evse_ts owns the journal (evse) and the read model (evse_ts);
  # an unrelated database other stays as it is; roles for PUBLIC, privileged and odd names.
  psql -h "$PGDIR" -p "$STUB_PGPORT" -U postgres -d postgres -Xq -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE evse_ts LOGIN;
CREATE ROLE stranger LOGIN;
CREATE ROLE other_reader LOGIN;
CREATE ROLE claude_ro LOGIN;
CREATE ROLE cnpg_pooler_pgbouncer LOGIN;
CREATE ROLE super_admin LOGIN SUPERUSER PASSWORD 'super-admin-original-pw';
CREATE ROLE creator LOGIN CREATEROLE;
CREATE ROLE other_app_migrate LOGIN;
COMMENT ON ROLE other_app_migrate IS 'infra-skills:migrate:other-app';
CREATE ROLE lonely LOGIN PASSWORD 'lonely-original-password-0123';
CREATE DATABASE shared2 OWNER other_reader;
CREATE DATABASE scramcheck;
CREATE ROLE legacyapp LOGIN;
CREATE DATABASE legacyapp OWNER legacyapp;
CREATE ROLE race_src LOGIN;
CREATE DATABASE race_a OWNER race_src;
CREATE DATABASE race_b;
CREATE ROLE "O'Brien | ops ""x""" LOGIN;
CREATE DATABASE evse OWNER evse_ts;
CREATE DATABASE evse_ts OWNER evse_ts;
CREATE DATABASE other;
CREATE DATABASE legacy OWNER "O'Brien | ops ""x""";
-- round 5: legacy owners that must not be adopted, and roles to elevate during a run
CREATE ROLE nologinapp NOLOGIN PASSWORD 'nologinapp-original-0123456789';
CREATE DATABASE nologinapp OWNER nologinapp;
CREATE ROLE some_group;
CREATE ROLE grpapp LOGIN PASSWORD 'grpapp-original-0123456789';
CREATE DATABASE grpapp OWNER grpapp;
GRANT some_group TO grpapp;
CREATE ROLE hostapp LOGIN;
CREATE DATABASE hostapp OWNER hostapp;
GRANT hostapp TO stranger;
CREATE ROLE elevapp LOGIN PASSWORD 'elevapp-original-0123456789';
CREATE DATABASE elevapp OWNER elevapp;
CREATE ROLE elevapp2 LOGIN PASSWORD 'elevapp2-original-0123456789';
CREATE DATABASE elevapp2 OWNER elevapp2;
-- P2-c: marked app and migration roles linked through a group
CREATE ROLE p2c LOGIN PASSWORD 'p2c-original-0123456789';
COMMENT ON ROLE p2c IS 'infra-skills:app:p2c';
CREATE ROLE p2c_migrate LOGIN;
COMMENT ON ROLE p2c_migrate IS 'infra-skills:migrate:p2c';
CREATE ROLE p2c_grp;
GRANT p2c TO p2c_grp;
GRANT p2c_grp TO p2c_migrate;
-- P3: a NOINHERIT member of a group that holds CONNECT still relies on PUBLIC
CREATE ROLE p3grp;
CREATE ROLE aaa_noinh LOGIN NOINHERIT;
GRANT p3grp TO aaa_noinh;
CREATE DATABASE p3db;
GRANT CONNECT ON DATABASE p3db TO p3grp;
-- round 6: adoptable roles changed concurrently; a database made again; objects and default
-- privileges the move cannot handle
CREATE ROLE adbapp LOGIN PASSWORD 'adbapp-original-0123456789';
CREATE DATABASE adbapp OWNER adbapp;
CREATE ROLE acmapp LOGIN PASSWORD 'acmapp-original-0123456789';
CREATE DATABASE acmapp OWNER acmapp;
CREATE ROLE r6src LOGIN;
CREATE DATABASE r6db OWNER r6src;
CREATE ROLE unsup_src LOGIN;
CREATE DATABASE unsup OWNER unsup_src;
CREATE ROLE dacl_src LOGIN;
CREATE DATABASE dacl OWNER dacl_src;
-- round 7: a move with an existing app role under a held lock; a destination with its own
-- default privileges
CREATE ROLE lock_src NOLOGIN;
CREATE DATABASE lockdb OWNER lock_src;
CREATE ROLE d7src NOLOGIN;
CREATE DATABASE d7db OWNER d7src;
CREATE ROLE d7app NOLOGIN PASSWORD 'd7app-original-0123456789';
COMMENT ON ROLE d7app IS 'infra-skills:app:d7app';
\c evse evse_ts
CREATE SCHEMA journal;
CREATE TABLE journal.events (ordering bigserial PRIMARY KEY, payload text);
INSERT INTO journal.events (payload) VALUES ('a');
\c evse_ts evse_ts
CREATE TABLE public.station_view (id int PRIMARY KEY);
\c legacy "O'Brien | ops ""x"""
CREATE SCHEMA s1;
CREATE TABLE s1.t1 (id int);
INSERT INTO s1.t1 VALUES (1);
SQL
  super_pw_before="$(q postgres postgres "SELECT rolpassword FROM pg_authid WHERE rolname='super_admin'")"
  lonely_pw_before="$(q postgres postgres "SELECT rolpassword FROM pg_authid WHERE rolname='lonely'")"
  # scram_login <role> <password>: a SCRAM-SHA-256 login (database scramcheck) works
  scram_login() { PGPASSWORD="$2" psql -h "$PGDIR" -p "$STUB_PGPORT" -U "$1" -d scramcheck -XtAqc "SELECT current_user" 2>/dev/null | grep -qxF -- "$1"; }
  check "real: SCRAM login rejects a wrong password (sanity)" not scram_login evse_ts wrong-password

  # -- grant mode, PUBLIC left alone (P1-d), migration role without membership (P2-d)
  # stranger is connected to evse while the run looks:
  printf 'SELECT pg_sleep(30);\n' | psql -h "$PGDIR" -p "$STUB_PGPORT" -U stranger -d evse -Xq >/dev/null 2>&1 & HOLDERS+=($!)
  /bin/sleep 0.5
  args=(evse-ts --tenant symbioen --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role)
  run real-grant "${args[@]}"; collect
  check "real grant: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  release; q postgres postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'stranger'" >/dev/null
  check "real grant: evse still owned by evse_ts" [ "$(owner_of_db evse)" = evse_ts ]
  check "real grant: app role reads the journal" [ "$(q evse-ts evse 'SELECT count(*) FROM journal.events')" = 1 ]
  check "real grant: app role writes the journal (sequence too)" can evse-ts evse "INSERT INTO journal.events (payload) VALUES ('b')"
  check "real grant: app role writes the read model" can evse-ts evse_ts "INSERT INTO station_view VALUES (1)"
  check "real grant: app role statement_timeout 60s" [ "$(q evse-ts evse 'SHOW statement_timeout')" = 1min ]
  check "real grant: app role idle_in_transaction 5min" [ "$(q evse-ts evse 'SHOW idle_in_transaction_session_timeout')" = 5min ]
  check "real grant: app role connection limit 20" [ "$(q postgres postgres "SELECT rolconnlimit FROM pg_roles WHERE rolname='evse-ts'")" = 20 ]
  check "real grant: app role marker" [ "$(q postgres postgres "SELECT shobj_description(oid, 'pg_authid') FROM pg_roles WHERE rolname='evse-ts'")" = infra-skills:app:evse-ts ]
  check "real grant: migration role marker" [ "$(q postgres postgres "SELECT shobj_description(oid, 'pg_authid') FROM pg_roles WHERE rolname='evse-ts_migrate'")" = infra-skills:migrate:evse-ts ]
  check "real grant: migration role statement_timeout 0" [ "$(q evse-ts_migrate evse 'SHOW statement_timeout')" = 0 ]
  check "real grant: migration role connection limit 2" [ "$(q postgres postgres "SELECT rolconnlimit FROM pg_roles WHERE rolname='evse-ts_migrate'")" = 2 ]
  check "real grant: PUBLIC still connects to evse (P1-d: left alone)" can stranger evse "SELECT 1"
  check "real grant: the warning names stranger as relying on PUBLIC" grep -q "connect through PUBLIC only: .*stranger" "$D/out"
  check "real grant: and as connected now" grep -q "connected now: stranger" "$D/out"
  check "real grant: other keeps PUBLIC's CONNECT (untouched)" can stranger other "SELECT 1"
  check "real grant: the tenant warning names other" grep -q "may still CONNECT to: .*other" "$D/out"
  check "real grant: migration role is no member of the app role (P2-d)" \
    [ "$(q postgres postgres "SELECT count(*) FROM pg_auth_members WHERE member = (SELECT oid FROM pg_roles WHERE rolname='evse-ts_migrate')")" = 0 ]
  check "real grant: migration role creates a table" can evse-ts_migrate evse "CREATE TABLE journal.archive_manifest (day date PRIMARY KEY, n bigserial)"
  check "real grant: app role writes the migration role's table (default privileges)" \
    can evse-ts evse "INSERT INTO journal.archive_manifest (day) VALUES ('2026-11-23')"
  check "real grant: app role cannot ALTER the migration role's table" not can evse-ts evse "ALTER TABLE journal.archive_manifest ADD COLUMN x int"
  check "real grant: migration role writes the old owner's table (explicit grants)" can evse-ts_migrate evse "INSERT INTO journal.events (payload) VALUES ('m')"
  check "real grant: SCRAM login with the app Secret's password (P1-1)" scram_login evse-ts "$(key "$D/fake/secrets.plain/evse-ts-db.secret.yaml" JOURNAL_DB_PASSWORD)"
  check "real grant: SCRAM login with the migrate Secret's password" scram_login evse-ts_migrate "$(key "$D/fake/secrets.plain/evse-ts-db-migrate.secret.yaml" JOURNAL_DB_PASSWORD)"
  check "real grant: the stored verifiers are SCRAM-SHA-256 4096" [ "$(q postgres postgres "SELECT count(*) FROM pg_authid WHERE rolname IN ('evse-ts', 'evse-ts_migrate') AND rolpassword LIKE 'SCRAM-SHA-256\$4096:%'")" = 2 ]
  args+=(--migration-schema evse.archive)
  PRE_RUN="$D" run real-grant "${args[@]}"; collect
  check "real grant + --migration-schema: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real grant: --migration-schema: archive is owned by the migration role" \
    [ "$(q postgres evse "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname='archive'")" = evse-ts_migrate ]
  check "real grant: --migration-schema: the migration role may CREATE SCHEMA in evse" can evse-ts_migrate evse "CREATE SCHEMA scratch"
  arch_ok() { can evse-ts_migrate evse "CREATE TABLE archive.days (d date)" && can evse-ts evse "INSERT INTO archive.days VALUES (now())"; }
  check "real grant: --migration-schema: the app role uses its tables" arch_ok
  check "real grant: no CREATE on evse_ts (no schema named there)" not can evse-ts_migrate evse_ts "CREATE SCHEMA nope"
  # P2-d: the app role's rights elsewhere do not leak to the migration role.
  can evse-ts other "CREATE TABLE public.app_private (x int)" || fail "real grant: fixture: app role table in other"
  check "real grant: migration role cannot read the app role's table in an unrelated database" not can evse-ts_migrate other "SELECT * FROM public.app_private"
  check "real grant: nor ALTER it" not can evse-ts_migrate other "ALTER TABLE public.app_private ADD COLUMN y int"
  later_ok() { can evse_ts evse "CREATE TABLE journal.later (x int)" && can evse-ts evse "INSERT INTO journal.later VALUES (1)"; }
  check "real grant: a table the old owner adds later is the app role's too (default privileges)" later_ok
  check "real grant: migration role cannot ALTER the old owner's table (grant mode)" \
    not can evse-ts_migrate evse "ALTER TABLE journal.events ADD COLUMN y int"
  acl() { q postgres "$1" "SELECT string_agg(c.relname || '=' || coalesce(c.relacl::text, ''), ' ' ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname IN ('journal','public','archive')" ; q postgres "$1" "SELECT string_agg(defaclrole::regrole::text || ':' || defaclobjtype || ':' || defaclacl::text, ' ' ORDER BY 1) FROM pg_default_acl"; q postgres postgres "SELECT datacl::text FROM pg_database WHERE datname = '$1'"; }
  before_acl="$(acl evse; acl evse_ts)"
  pw_before="$(q postgres postgres "SELECT rolpassword FROM pg_authid WHERE rolname='evse-ts'")"
  PRE_RUN="$D" run real-grant "${args[@]}" --keep-password; collect
  check "real re-run --keep-password: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real re-run: rights unchanged" [ "$before_acl" = "$(acl evse; acl evse_ts)" ]
  check "real re-run --keep-password: the existing role's password is untouched (P2-c)" \
    [ "$pw_before" = "$(q postgres postgres "SELECT rolpassword FROM pg_authid WHERE rolname='evse-ts'")" ]
  check "real re-run: the role has a SCRAM verifier" [ "$(q postgres postgres "SELECT left(rolpassword, 13) FROM pg_authid WHERE rolname='evse-ts'")" = SCRAM-SHA-256 ]
  check "real re-run --keep-password: the kept password still logs in" scram_login evse-ts "$(key "$D/fake/secrets.plain/evse-ts-db.secret.yaml" JOURNAL_DB_PASSWORD)"
  # P2-3: the role's password changed elsewhere; --keep-password must not publish the stale one.
  q postgres postgres "ALTER ROLE \"evse-ts\" PASSWORD 'changed-elsewhere-0123456789abcdef'" >/dev/null
  stale_before="$(cat "$D/fake/secrets.plain/evse-ts-db.secret.yaml")"
  PRE_RUN="$D" run real-grant "${args[@]}" --keep-password; collect
  check "real --keep-password, stale Secret: refused (P2-3)" [ "$RC" != 0 ]
  check "real --keep-password, stale Secret: says so" grep -q "is not role evse-ts's password in the cluster" "$D/out"
  check "real --keep-password, stale Secret: the file is untouched" [ "$stale_before" = "$(cat "$D/fake/secrets.plain/evse-ts-db.secret.yaml")" ]
  check "real --keep-password, stale Secret: not applied" [ ! -e "$D/log.applied" ]
  check "real --keep-password, stale Secret: the role's password unchanged" scram_login evse-ts changed-elsewhere-0123456789abcdef
  # P1-2: the default path with --migration-role must not adopt an unrelated role.
  run real-p12 lonely --migration-role
  check "real default + --migration-role, unrelated unmarked role: refused (P1-2)" grep -q "Role lonely exists but was not made by this script" "$D/out"
  check "real P1-2: its password is untouched" [ "$lonely_pw_before" = "$(q postgres postgres "SELECT rolpassword FROM pg_authid WHERE rolname='lonely'")" ]
  check "real P1-2: no Secret written" bash -c '[ ! -e "$1/fake/secrets.plain" ] || [ -z "$(ls "$1/fake/secrets.plain")" ]' _ "$D"
  check "real P1-2: no migration role made" [ "$(q postgres postgres "SELECT count(*) FROM pg_roles WHERE rolname='lonely_migrate'")" = 0 ]
  # Round 4 P1-1: the plain default path (no new flags) runs the same preflight.
  run real-plain-lonely lonely
  check "real plain default path, unrelated unmarked role: refused (round 4 P1-1)" grep -q "Role lonely exists but was not made by this script" "$D/out"
  check "real plain default path: its password is untouched" [ "$lonely_pw_before" = "$(q postgres postgres "SELECT rolpassword FROM pg_authid WHERE rolname='lonely'")" ]
  check "real plain default path: no Secret written, none applied" bash -c '{ [ ! -e "$1/fake/secrets.plain" ] || [ -z "$(ls "$1/fake/secrets.plain")" ]; } && [ ! -e "$1/log.applied" ]' _ "$D"
  check "real plain default path: no database lonely made" [ -z "$(owner_of_db lonely)" ]
  run real-legacy legacyapp
  check "real plain default path, a legacy role that owns its database: adopted" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real plain default path: the legacy role gets the marker" [ "$(q postgres postgres "SELECT shobj_description(oid, 'pg_authid') FROM pg_roles WHERE rolname='legacyapp'")" = infra-skills:app:legacyapp ]
  check "real plain default path: SCRAM login with its new Secret" scram_login legacyapp "$(key "$D/fake/secrets.plain/legacyapp-db.secret.yaml" POSTGRES_PASSWORD)"
  # Round 5 P1-1: a legacy owner is adopted only with LOGIN and no membership at all, either direction.
  pw_of() { q postgres postgres "SELECT coalesce(rolpassword, '') || '/' || coalesce(shobj_description(oid, 'pg_authid'), '') FROM pg_authid WHERE rolname = '$1'"; }
  before_nl="$(pw_of nologinapp)"; before_grp="$(pw_of grpapp)"; before_host="$(pw_of hostapp)"
  run real-nologin nologinapp
  check "real round 5 P1-1: a NOLOGIN owner of its database is not adopted" bash -c '[ "$1" != 0 ] && grep -q "it has NOLOGIN" "$2/out"' _ "$RC" "$D"
  check "real round 5 P1-1: its password and comment are unchanged" [ "$before_nl" = "$(pw_of nologinapp)" ]
  run real-grpapp grpapp
  check "real round 5 P1-1: an owner that is a member of a group is not adopted" bash -c '[ "$1" != 0 ] && grep -q "role memberships (member of some_group)" "$2/out"' _ "$RC" "$D"
  check "real round 5 P1-1: its password and comment are unchanged" [ "$before_grp" = "$(pw_of grpapp)" ]
  run real-hostapp hostapp
  check "real round 5 P1-1: an owner with a member is not adopted" bash -c '[ "$1" != 0 ] && grep -q "role memberships (has member stranger)" "$2/out"' _ "$RC" "$D"
  check "real round 5 P1-1: its password and comment are unchanged" [ "$before_host" = "$(pw_of hostapp)" ]
  # ... and a role elevated between the preflight and the role transaction: a session changes it
  # before the run starts and commits 3.5 s later, while the run waits for the role catalogs' lock.
  ELEV_N=0
  elevate() { # <sql> [seconds 3.5]: in the background, BEGIN; <sql>; sleep; COMMIT. Returns once it sleeps.
    ELEV_N=$((ELEV_N + 1))
    printf 'BEGIN;\n%s\nSELECT pg_sleep(%s);\nCOMMIT;\n' "$1" "${2:-3.5}" \
      | PGAPPNAME="elev-$ELEV_N" psql -h "$PGDIR" -p "$STUB_PGPORT" -U postgres -d postgres -Xq >/dev/null 2>&1 &
    ELEV_PID=$!
    local _; for _ in $(seq 1 50); do
      [[ "$(q postgres postgres "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'elev-$ELEV_N' AND query LIKE 'SELECT pg_sleep(%' AND state = 'active'")" -ge 1 ]] && return 0
      /bin/sleep 0.1
    done
    return 1
  }
  before_elev="$(pw_of elevapp)"
  elevate "GRANT pg_read_server_files TO elevapp;" || fail "real round 5 P1-1: elevating session did not start"
  run real-elev elevapp; wait "$ELEV_PID" || true
  check "real round 5 P1-1: a role that joins pg_read_server_files after the preflight is refused" [ "$RC" != 0 ]
  check "real round 5 P1-1: by the guard, under the lock" grep -q "elevapp joined a privileged or pg_\* role after the preflight" "$D/out"
  check "real round 5 P1-1: its password and comment are unchanged" [ "$before_elev" = "$(pw_of elevapp)" ]
  before_elev2="$(pw_of elevapp2)"
  elevate "ALTER ROLE elevapp2 CREATEDB;" || fail "real round 5 P1-1: elevating session did not start"
  run real-elev2 elevapp2; wait "$ELEV_PID" || true
  check "real round 5 P1-1: a role that gains CREATEDB after the preflight is refused" grep -q "elevapp2 gained SUPERUSER, CREATEROLE, CREATEDB" "$D/out"
  check "real round 5 P1-1: its password and comment are unchanged" [ "$before_elev2" = "$(pw_of elevapp2)" ]
  # Round 5 P2-c: marked app and migration roles that are members of one another through a group.
  before_p2c="$(pw_of p2c)"
  run real-p2c p2c --migration-role
  check "real round 5 P2-c: app and migration role linked through a group: refused" bash -c '[ "$1" != 0 ] && grep -q "are members of one another" "$2/out"' _ "$RC" "$D"
  check "real round 5 P2-c: nothing changed (password, no database p2c)" bash -c '[ "$1" = "$2" ] && [ -z "$3" ]' _ "$before_p2c" "$(pw_of p2c)" "$(owner_of_db p2c)"
  # Round 6 P1-1: an adoptable role's database changes owner, or the role gets a comment, in a
  # session that commits after the preflight; the role transaction waits for its lock on
  # pg_database / pg_shdescription and then sees the change.
  pw_only() { q postgres postgres "SELECT coalesce(rolpassword, '') FROM pg_authid WHERE rolname = '$1'"; }
  before_adb="$(pw_of adbapp)"
  elevate "ALTER DATABASE adbapp OWNER TO stranger;" || fail "real round 6 P1-1: the ALTER DATABASE session did not start"
  run real-adb adbapp; wait "$ELEV_PID" || true
  check "real round 6 P1-1: a concurrent ALTER DATABASE OWNER of the adopted role's database is held off, then refused" \
    bash -c '[ "$1" != 0 ] && grep -q "role adbapp changed after the preflight" "$2/out"' _ "$RC" "$D"
  check "real round 6 P1-1: its password and comment are unchanged" [ "$before_adb" = "$(pw_of adbapp)" ]
  before_acm="$(pw_only acmapp)"
  elevate "COMMENT ON ROLE acmapp IS 'another tool''s role';" || fail "real round 6 P1-1: the COMMENT session did not start"
  run real-acm acmapp; wait "$ELEV_PID" || true
  check "real round 6 P1-1: a concurrent COMMENT ON ROLE is held off, then refused" \
    bash -c '[ "$1" != 0 ] && grep -q "role acmapp changed after the preflight" "$2/out"' _ "$RC" "$D"
  check "real round 6 P1-1: its password is unchanged, the other comment stays" \
    bash -c '[ "$1" = "$2" ] && [ "$3" = "another tool'"'"'s role" ]' _ "$before_acm" "$(pw_only acmapp)" "$(q postgres postgres "SELECT shobj_description(oid, 'pg_authid') FROM pg_roles WHERE rolname='acmapp'")"

  # -- --revoke-public (P1-d)
  run real-revoke-missing evse-ts --tenant symbioen --database evse:JOURNAL_DB --revoke-public --keep-connect nobody_here
  check "real --revoke-public, kept role missing: refused" grep -q "role nobody_here does not exist" "$D/out"
  check "real --revoke-public, kept role missing: PUBLIC untouched" can stranger evse "SELECT 1"
  check "real: a refused preflight leaves no ledger behind" [ -z "$(q postgres postgres "SELECT to_regclass('infra_skills.ownership_transfer')")" ]
  # Round 4 P2-2: a foreign ledger whose relation runs code when read (a view over a function that
  # writes to public.pwned) must not be read by the preflight at all.
  q postgres postgres "DROP SCHEMA IF EXISTS infra_skills CASCADE; CREATE SCHEMA infra_skills AUTHORIZATION stranger" >/dev/null \
    || fail "real: fixture: a foreign infra_skills schema"
  psql -h "$PGDIR" -p "$STUB_PGPORT" -U stranger -d postgres -Xq -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL' || fail "real: fixture: the trap view"
CREATE TABLE public.pwned (at timestamptz);
CREATE FUNCTION infra_skills.trap() RETURNS TABLE (datoid oid, datname name, from_role oid, to_role oid, started_at timestamptz, done_at timestamptz)
  LANGUAGE plpgsql AS $$ BEGIN INSERT INTO public.pwned VALUES (now()); RETURN; END $$;
CREATE VIEW infra_skills.ownership_transfer AS SELECT * FROM infra_skills.trap();
SQL
  run real-ledger-hijack evse-ts --database evse:JOURNAL_DB --database evse_ts:STATE_DB --take-ownership
  check "real: a ledger schema owned by another role is refused" grep -q "is not what this script makes" "$D/out"
  check "real: and nothing moved" [ "$(owner_of_db evse)" = evse_ts ]
  check "real: the foreign ledger was never read (round 4 P2-2)" [ "$(q postgres postgres "SELECT count(*) FROM public.pwned")" = 0 ]
  q postgres postgres "DROP TABLE IF EXISTS public.pwned" >/dev/null || true
  q postgres postgres "DROP SCHEMA IF EXISTS infra_skills CASCADE" >/dev/null || fail "real: fixture: drop the foreign schema"
  PG_READONLY_ROLE=claude_ro run real-revoke my-app --database evse --pooler --revoke-public --keep-connect other_reader
  check "real --revoke-public: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  collect
  check "real --revoke-public: stranger can no longer connect" not can stranger evse "SELECT 1"
  check "real --revoke-public: the kept role still connects" can other_reader evse "SELECT 1"
  check "real --revoke-public: the owner still connects" can evse_ts evse "SELECT 1"
  check "real --revoke-public: the read-only role still connects" can claude_ro evse "SELECT 1"
  check "real --revoke-public: the pooler role still connects" can cnpg_pooler_pgbouncer evse "SELECT 1"
  check "real --revoke-public: the earlier app role still connects (explicit grant)" can evse-ts evse "SELECT 1"
  check "real --revoke-public: the warning named stranger" grep -q "lose CONNECT now: .*stranger" "$D/out"
  check "real --revoke-public: evse_ts untouched" can stranger evse_ts "SELECT 1"
  # P2-1 (a): a tenant run still keeps the configured read-only login's CONNECT.
  check "real P2-1: claude_ro reaches shared2 through PUBLIC before (sanity)" can claude_ro shared2 "SELECT 1"
  PG_READONLY_ROLE=claude_ro run real-revoke-tenant t2app --tenant symbioen --database shared2 --revoke-public --keep-connect none; collect
  check "real --revoke-public, tenant: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real --revoke-public, tenant: the read-only login still connects (P2-1)" can claude_ro shared2 "SELECT 1"
  check "real --revoke-public, tenant: stranger no longer connects" not can stranger shared2 "SELECT 1"
  check "real --revoke-public, tenant: the owner still connects" can other_reader shared2 "SELECT 1"

  # -- --take-ownership: evse and evse_ts share their owner evse_ts. A lock held on evse_ts's table
  # interrupts the run after evse (a 2 s lock_timeout for postgres, so an older script is cut there
  # too). Round 5 P1-2: evse's move touches neither evse_ts nor, later, the source's tablespace. A
  # retry to another role is refused (P2-2), and so is one after a hand-made owner change (round 5
  # P1-3); the retry to the same role completes the move.
  q postgres postgres "ALTER ROLE postgres SET lock_timeout = '2s'" >/dev/null
  hold evse_ts "LOCK TABLE public.station_view IN ACCESS EXCLUSIVE MODE;" || fail "real ownership: lock holder did not start"
  run real-own evse-ts --database evse:JOURNAL_DB --database evse_ts:STATE_DB --take-ownership --migration-role; collect
  release
  q postgres postgres "ALTER ROLE postgres RESET lock_timeout" >/dev/null
  check "real ownership, interrupted: the run fails" [ "$RC" != 0 ]
  check "real ownership, interrupted: evse moved (database and tables)" bash -c '[ "$1" = evse-ts_migrate ] && [ "$2" = evse-ts_migrate ]' _ \
    "$(owner_of_db evse)" "$(q postgres evse "SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname='journal'")"
  check "real round 5 P1-2: evse_ts, the source's other database, is untouched by evse's move" [ "$(owner_of_db evse_ts)" = evse_ts ]
  check "real ownership, interrupted: evse_ts's table keeps its owner (its move rolled back)" [ "$(q postgres evse_ts "SELECT tableowner FROM pg_tables WHERE tablename='station_view'")" = evse_ts ]
  mkdir -p "$PGDIR/ts_evse"
  q postgres postgres "CREATE TABLESPACE ts_evse OWNER evse_ts LOCATION '$PGDIR/ts_evse'" >/dev/null || fail "real ownership: fixture: tablespace"
  check "real round 5: the old owner keeps CONNECT on evse after its move (PUBLIC was revoked there)" can evse_ts evse "SELECT 1"
  run real-own-conflict evse-ts --database evse:JOURNAL_DB --database evse_ts:STATE_DB --take-ownership
  check "real ownership, retry to another role: refused (P2-2)" grep -q "an unfinished move of evse_ts from evse_ts to evse-ts_migrate" "$D/out"
  check "real ownership, retry to another role: evse stays with the migration role" [ "$(owner_of_db evse)" = evse-ts_migrate ]
  check "real ownership, retry to another role: station_view untouched" [ "$(q postgres evse_ts "SELECT tableowner FROM pg_tables WHERE tablename='station_view'")" = evse_ts ]
  check "real ownership, retry to another role: the ledger row is unchanged" \
    [ "$(q postgres postgres "SELECT pg_get_userbyid(to_role) FROM infra_skills.ownership_transfer WHERE datname='evse_ts' AND done_at IS NULL")" = evse-ts_migrate ]
  q postgres postgres "ALTER DATABASE evse_ts OWNER TO stranger" >/dev/null || fail "real round 5 P1-3: fixture: owner by hand"
  PRE_RUN="$WORK/real-own" run real-own evse-ts --database evse:JOURNAL_DB --database evse_ts:STATE_DB --take-ownership --migration-role
  check "real round 5 P1-3: a retry after a hand-made owner change is refused" bash -c '[ "$1" != 0 ] && grep -q "evse_ts is owned by stranger now, not by evse_ts as recorded" "$2/out"' _ "$RC" "$D"
  check "real round 5 P1-3: the hand-made owner stays" [ "$(owner_of_db evse_ts)" = stranger ]
  check "real round 5 P1-3: and station_view its owner" [ "$(q postgres evse_ts "SELECT tableowner FROM pg_tables WHERE tablename='station_view'")" = evse_ts ]
  q postgres postgres "ALTER DATABASE evse_ts OWNER TO evse_ts" >/dev/null || fail "real round 5 P1-3: fixture: owner back"
  PRE_RUN="$D" run real-own evse-ts --database evse:JOURNAL_DB --database evse_ts:STATE_DB --take-ownership --migration-role; collect
  check "real ownership, retry: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real ownership, retry: completes the move instead of skipping it (P2-a)" \
    [ "$(q postgres evse_ts "SELECT tableowner FROM pg_tables WHERE tablename='station_view'")" = evse-ts_migrate ]
  check "real ownership: databases owned by evse-ts_migrate" \
    [ "$(q postgres postgres "SELECT string_agg(DISTINCT pg_get_userbyid(datdba), ',') FROM pg_database WHERE datname IN ('evse','evse_ts')")" = evse-ts_migrate ]
  check "real ownership: nothing in either database owned by evse_ts" \
    [ "$(q postgres evse_ts "SELECT count(*) FROM pg_shdepend WHERE refobjid = (SELECT oid FROM pg_roles WHERE rolname='evse_ts') AND deptype='o' AND classid <> 'pg_default_acl'::regclass AND dbid IN (SELECT oid FROM pg_database WHERE datname IN ('evse','evse_ts'))")" = 0 ]
  check "real round 5 P1-2: the tablespace still belongs to evse_ts after both moves" [ "$(q postgres postgres "SELECT pg_get_userbyid(spcowner) FROM pg_tablespace WHERE spcname='ts_evse'")" = evse_ts ]
  check "real ownership: the ledger says done for both" \
    [ "$(q postgres postgres "SELECT count(*) FROM infra_skills.ownership_transfer WHERE datname IN ('evse','evse_ts') AND done_at IS NOT NULL")" = 2 ]
  check "real ownership: the ledger is closed to PUBLIC" not can stranger postgres "SELECT * FROM infra_skills.ownership_transfer"
  check "real ownership: migration role can ALTER the journal now" can evse-ts_migrate evse "ALTER TABLE journal.events ADD COLUMN y int"
  check "real ownership: app role still writes it" can evse-ts evse "INSERT INTO journal.events (payload) VALUES ('c')"
  check "real ownership: other untouched" [ "$(owner_of_db other)" = postgres ]
  run real-own-super evse-ts --database other --take-ownership
  check "real ownership: refused for a superuser-owned database" grep -q "a superuser or system role" "$D/out"

  # Round 5: every kind of object the move handles, in one database (and an extension, which stays).
  psql -h "$PGDIR" -p "$STUB_PGPORT" -U postgres -d postgres -Xq -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || fail "real kinds: fixture"
CREATE ROLE kinds_src LOGIN;
CREATE DATABASE kinds OWNER kinds_src;
SQL
  psql -h "$PGDIR" -p "$STUB_PGPORT" -U kinds_src -d kinds -Xq -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || fail "real kinds: fixture objects"
CREATE SCHEMA k;
CREATE TABLE k.t (id bigserial PRIMARY KEY, n int GENERATED ALWAYS AS IDENTITY);
CREATE TABLE k.p (x int) PARTITION BY RANGE (x);
CREATE TABLE k.p1 PARTITION OF k.p FOR VALUES FROM (0) TO (10);
CREATE VIEW k.v AS SELECT 1 AS one;
CREATE MATERIALIZED VIEW k.mv AS SELECT 1 AS one;
CREATE SEQUENCE k.free;
CREATE TYPE k.comp AS (a int);
CREATE TYPE k.en AS ENUM ('a');
CREATE TYPE k.rng AS RANGE (subtype = int4);
CREATE DOMAIN k.dom AS int;
CREATE FUNCTION k.f() RETURNS int LANGUAGE sql AS 'SELECT 1';
CREATE PROCEDURE k.pr() LANGUAGE sql AS 'SELECT 1';
CREATE AGGREGATE k.agg(int) (sfunc = int4pl, stype = int);
SELECT lo_create(424242);
ALTER DEFAULT PRIVILEGES IN SCHEMA k GRANT SELECT ON TABLES TO other_reader;
GRANT USAGE ON SCHEMA k TO other_reader;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL
  # Round 6 P3: an extension of postgres in kinds, one of whose functions kinds_src owns.
  psql -h "$PGDIR" -p "$STUB_PGPORT" -U postgres -d kinds -Xq -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || fail "real kinds: fixture btree_gin member"
CREATE EXTENSION IF NOT EXISTS btree_gin;
SELECT format('ALTER FUNCTION %s OWNER TO kinds_src', e.objid::regprocedure) FROM pg_depend e
 WHERE e.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'btree_gin') AND e.classid = 'pg_proc'::regclass AND e.deptype = 'e'
 ORDER BY e.objid LIMIT 1 \gexec
SQL
  # Round 5 P2-a: a lock held on one of kinds' tables (no lock_timeout for postgres): the move fails
  # fast on its own lock_timeout, and nothing in kinds changed.
  hold kinds "LOCK TABLE k.t IN ACCESS EXCLUSIVE MODE;" || fail "real P2-a: lock holder did not start"
  t0=$SECONDS
  run real-kinds-locked kinds-app --database kinds --take-ownership
  took=$((SECONDS - t0))
  release
  check "real round 5 P2-a: a held table lock fails the move (${took}s)" [ "$RC" != 0 ]
  check "real round 5 P2-a: fast, on lock_timeout" bash -c '[ "$1" -lt 25 ] && grep -q "canceling statement due to lock timeout" "$2/out"' _ "$took" "$D"
  check "real round 5 P2-a: nothing changed (database, schema, tables, functions)" \
    [ "$(q postgres kinds "SELECT count(*) FROM pg_shdepend s WHERE s.refobjid = (SELECT oid FROM pg_roles WHERE rolname='kinds-app') AND s.deptype='o' AND s.dbid IN (0, (SELECT oid FROM pg_database WHERE datname='kinds'))")/$(owner_of_db kinds)" = 0/kinds_src ]
  run real-kinds kinds-app --database kinds --take-ownership; collect
  check "real round 5 kinds: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real round 5 kinds: nothing in kinds still belongs to kinds_src (extension aside)" \
    [ "$(q postgres kinds "SELECT count(*) FROM pg_shdepend s WHERE s.refobjid = (SELECT oid FROM pg_roles WHERE rolname='kinds_src') AND s.deptype='o' AND s.classid NOT IN ('pg_default_acl'::regclass, 'pg_extension'::regclass) AND s.dbid = (SELECT oid FROM pg_database WHERE datname='kinds') AND NOT EXISTS (SELECT FROM pg_depend e WHERE e.classid = s.classid AND e.objid = s.objid AND e.deptype = 'e')")" = 0 ]
  check "real round 5 kinds: the multirange moved with its range" [ "$(q postgres kinds "SELECT pg_get_userbyid(typowner) FROM pg_type WHERE typname='rng_multirange'")" = kinds-app ]
  check "real round 5 kinds: the large object moved" [ "$(q postgres kinds "SELECT pg_get_userbyid(lomowner) FROM pg_largeobject_metadata WHERE oid = 424242")" = kinds-app ]
  check "real round 5 kinds: the default privileges were copied to the new owner" \
    [ "$(q postgres kinds "SELECT count(*) FROM pg_default_acl WHERE defaclrole = (SELECT oid FROM pg_roles WHERE rolname='kinds-app') AND defaclacl::text LIKE '%other_reader=r/%'")" = 1 ]
  check "real round 5 kinds: a table the new owner creates later is readable by other_reader" \
    bash -c 'psql -h "$1" -p "$2" -U kinds-app -d kinds -XqAt -c "CREATE TABLE k.later (x int)" >/dev/null && psql -h "$1" -p "$2" -U other_reader -d kinds -XqAt -c "SELECT * FROM k.later" >/dev/null' _ "$PGDIR" "$STUB_PGPORT"
  check "real round 5 kinds: the extension stays with kinds_src, with a warning" \
    bash -c '[ "$1" = kinds_src ] && grep -q "these stay with the old owner .*extension pg_trgm (its own)" "$2/out"' _ "$(q postgres kinds "SELECT pg_get_userbyid(extowner) FROM pg_extension WHERE extname='pg_trgm'")" "$D"
  check "real round 6 P3: the warning also names kinds_src's member of an extension postgres owns" \
    grep -q "these stay with the old owner .*1 object(s) in extension btree_gin (owned by postgres)" "$D/out"
  check "real round 6 P3: and that member keeps its owner" \
    [ "$(q postgres kinds "SELECT count(*) FROM pg_proc p JOIN pg_depend e ON e.objid = p.oid AND e.classid = 'pg_proc'::regclass AND e.deptype = 'e' WHERE e.refobjid = (SELECT oid FROM pg_extension WHERE extname = 'btree_gin') AND pg_get_userbyid(p.proowner) = 'kinds_src'")" = 1 ]

  # Round 6 P2-b: an object kind the move does not handle (a collation): the run stops before any
  # credential change; the app role's password and its Secret stay as they are.
  q unsup_src unsup "CREATE COLLATION public.uc (locale = 'C')" >/dev/null || fail "real round 6 P2-b: fixture collation"
  run real-unsup unsup-app --database unsup
  check "real round 6 P2-b: grant mode first (sanity)" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  unsup_pw="$(pw_only unsup-app)"; unsup_secret="$(cat "$D/fake/secrets.plain/unsup-app-db.secret.yaml")"
  PRE_RUN="$D" run real-unsup unsup-app --database unsup --take-ownership
  check "real round 6 P2-b: an unhandled object kind stops the move" bash -c '[ "$1" != 0 ] && grep -q "does not move (pg_collation)" "$2/out"' _ "$RC" "$D"
  check "real round 6 P2-b: before any credential change: the password is unchanged" [ "$unsup_pw" = "$(pw_only unsup-app)" ]
  check "real round 6 P2-b: and the Secret file too, nothing applied" \
    bash -c '[ "$1" = "$(cat "$2/fake/secrets.plain/unsup-app-db.secret.yaml")" ] && [ ! -e "$2/log.applied" ]' _ "$unsup_secret" "$D"
  check "real round 6 P2-b: unsup keeps its owner" [ "$(owner_of_db unsup)" = unsup_src ]
  # Round 6 P2-c: default privileges GRANT cannot reproduce: refused before any change, and printed.
  psql -h "$PGDIR" -p "$STUB_PGPORT" -U dacl_src -d dacl -Xq -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || fail "real round 6 P2-c: fixture"
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO other_reader WITH GRANT OPTION;
CREATE TABLE public.dt (x int);
SQL
  run real-dacl dacl-app --database dacl --take-ownership
  check "real round 6 P2-c: refused" [ "$RC" != 0 ]
  check "real round 6 P2-c: prints the revoked default" grep -q "functions: EXECUTE revoked from PUBLIC (a built-in default)" "$D/out"
  check "real round 6 P2-c: and the grant option" grep -q "tables: SELECT to other_reader WITH GRANT OPTION" "$D/out"
  check "real round 6 P2-c: nothing changed (no role dacl-app, dacl and its table keep their owner)" \
    bash -c '[ -z "$1" ] && [ "$2" = dacl_src ] && [ "$3" = dacl_src ]' _ "$(pw_of dacl-app)" "$(owner_of_db dacl)" "$(q postgres dacl "SELECT tableowner FROM pg_tables WHERE tablename='dt'")"
  # Round 7 P2-c: lock-app exists (grant mode first) with its Secret. Its --take-ownership run times
  # out on a held table lock: its password and Secret stay as they were. The retry completes.
  q postgres lockdb "SET ROLE lock_src; CREATE TABLE public.lt (x int)" >/dev/null || fail "real round 7 P2-c: fixture table"
  run real-lock lock-app --database lockdb
  check "real round 7 P2-c: grant mode first (sanity)" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  lock_pw="$(pw_only lock-app)"; lock_secret="$(cat "$D/fake/secrets.plain/lock-app-db.secret.yaml")"
  hold lockdb "LOCK TABLE public.lt IN ACCESS EXCLUSIVE MODE;" || fail "real round 7 P2-c: lock holder did not start"
  PRE_RUN="$D" run real-lock lock-app --database lockdb --take-ownership
  release
  check "real round 7 P2-c: the move times out" bash -c '[ "$1" != 0 ] && grep -q "canceling statement due to lock timeout" "$2/out"' _ "$RC" "$D"
  check "real round 7 P2-c: the existing role's password is unchanged" [ "$lock_pw" = "$(pw_only lock-app)" ]
  check "real round 7 P2-c: and its Secret file too, nothing applied" \
    bash -c '[ "$1" = "$(cat "$2/fake/secrets.plain/lock-app-db.secret.yaml")" ] && [ ! -e "$2/log.applied" ]' _ "$lock_secret" "$D"
  check "real round 7 P2-c: the old Secret's password still logs in" scram_login lock-app "$(key "$D/fake/secrets.plain/lock-app-db.secret.yaml" POSTGRES_PASSWORD)"
  PRE_RUN="$D" run real-lock lock-app --database lockdb --take-ownership; collect
  check "real round 7 P2-c: the retry completes" bash -c '[ "$1" = 0 ] && [ "$2" = lock-app ] && [ "$3" = lock-app ]' _ "$RC" "$(owner_of_db lockdb)" \
    "$(q postgres lockdb "SELECT tableowner FROM pg_tables WHERE tablename='lt'")"
  check "real round 7 P2-c: with a new password, in the new Secret" \
    bash -c '[ "$1" != "$2" ]' _ "$lock_pw" "$(pw_only lock-app)"
  check "real round 7 P2-c: the new Secret's password logs in" scram_login lock-app "$(key "$D/fake/secrets.plain/lock-app-db.secret.yaml" POSTGRES_PASSWORD)"
  # Round 7 P2-d: the destination d7app already has a PUBLIC SELECT default in d7db; the copy from
  # d7src would not give it. Refused before any change, both sides printed.
  q postgres d7db "ALTER DEFAULT PRIVILEGES FOR ROLE d7app GRANT SELECT ON TABLES TO PUBLIC" >/dev/null || fail "real round 7 P2-d: fixture"
  q postgres d7db "SET ROLE d7src; CREATE TABLE public.d7t (x int)" >/dev/null || fail "real round 7 P2-d: fixture table"
  d7_pw="$(pw_only d7app)"
  run real-d7 d7app --database d7db --take-ownership
  check "real round 7 P2-d: a destination with its own PUBLIC SELECT default is refused" [ "$RC" != 0 ]
  check "real round 7 P2-d: both sides printed" \
    grep -q "d7app already has default privileges that differ from what the copy would give: tables: d7app has PUBLIC SELECT, the copy from the old owner gives nothing" "$D/out"
  check "real round 7 P2-d: nothing changed (password, owners)" \
    bash -c '[ "$1" = "$2" ] && [ "$3" = d7src ] && [ "$4" = d7src ]' _ "$d7_pw" "$(pw_only d7app)" "$(owner_of_db d7db)" "$(q postgres d7db "SELECT tableowner FROM pg_tables WHERE tablename='d7t'")"

  # Round 4 P1-2: SHARE ROW EXCLUSIVE on pg_database holds off ALTER DATABASE OWNER (PG14)...
  hold postgres "LOCK TABLE pg_catalog.pg_database IN SHARE ROW EXCLUSIVE MODE;" || fail "real P1-2: lock holder did not start"
  blocked_alter() { # the ALTER fails with a lock timeout (psql exits non-zero, hence no pipe)
    local out
    out=$(psql -h "$PGDIR" -p "$STUB_PGPORT" -U postgres -d postgres -XtAq \
            -c "SET lock_timeout = '500ms'; ALTER DATABASE race_b OWNER TO postgres" 2>&1 || true)
    [[ "$out" == *"canceling statement due to lock timeout"* ]]
  }
  check "real P1-2: SHARE ROW EXCLUSIVE on pg_database blocks a concurrent ALTER DATABASE OWNER" blocked_alter
  release
  # ... and the race (round 5 P1-3): after the preflight, another session changes race_a's owner by
  # hand. The move's check under the lock refuses, and everything in race_a is rolled back.
  q race_src race_a "CREATE TABLE ra (x int)" >/dev/null || fail "real race: fixture table"
  hold postgres "INSERT INTO infra_skills.ownership_transfer VALUES ((SELECT oid FROM pg_database WHERE datname='race_a'), 'race_a', (SELECT oid FROM pg_roles WHERE rolname='race_src'), (SELECT oid FROM pg_roles WHERE rolname='race_src'), now(), NULL);" \
    || fail "real race: ledger holder did not start"
  ( run real-race race-app --database race_a --take-ownership; echo "$RC" > "$WORK/race.rc" ) &
  racer=$!
  waited=0
  for _ in $(seq 1 100); do
    [[ "$(q postgres postgres "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE 'INSERT INTO infra_skills.ownership_transfer%'")" -ge 1 ]] && { waited=1; break; }
    /bin/sleep 0.1
  done
  check "real race: the run is past its preflight, waiting (sanity)" [ "$waited" = 1 ]
  q postgres postgres "ALTER DATABASE race_a OWNER TO stranger" >/dev/null || fail "real race: the other session's ALTER DATABASE"
  release
  wait "$racer" || true
  D="$WORK/real-race"
  check "real round 5 P1-3: the move fails when the owner changed after the preflight" [ "$(cat "$WORK/race.rc")" != 0 ]
  check "real round 5 P1-3: and says why" grep -q "race_a is owned by stranger now, not by race_src as recorded" "$D/out"
  check "real round 5 P1-3: the hand-made owner stays" [ "$(owner_of_db race_a)" = stranger ]
  check "real round 5 P1-3: race_a's table keeps its owner (rolled back)" [ "$(q postgres race_a "SELECT tableowner FROM pg_tables WHERE tablename='ra'")" = race_src ]
  # Round 6 P1-2: r6db is dropped and made again (same name, same owner) after the run's preflight,
  # while it waits for the role catalogs' lock (a session holds pg_authid and commits 5 s later).
  # The ledger row must not take the new database for the one the preflight saw.
  q r6src r6db "CREATE TABLE r6old (x int)" >/dev/null || fail "real round 6 P1-2: fixture table"
  elevate "ALTER ROLE stranger CONNECTION LIMIT 7;" 5 || fail "real round 6 P1-2: the pg_authid session did not start"
  ( run real-r6 r6app --database r6db --take-ownership; echo "$RC" > "$WORK/r6.rc" ) &
  r6=$!
  waited=0
  for _ in $(seq 1 100); do
    [[ "$(q postgres postgres "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE 'LOCK TABLE pg_catalog.pg_authid%'")" -ge 1 ]] && { waited=1; break; }
    /bin/sleep 0.05
  done
  check "real round 6 P1-2: the run is past its preflight, waiting (sanity)" [ "$waited" = 1 ]
  q postgres postgres "DROP DATABASE r6db" >/dev/null || fail "real round 6 P1-2: drop"
  q postgres postgres "CREATE DATABASE r6db OWNER r6src" >/dev/null || fail "real round 6 P1-2: create again"
  q r6src r6db "CREATE TABLE r6new (x int)" >/dev/null || fail "real round 6 P1-2: new table"
  wait "$r6" || true; wait "$ELEV_PID" || true
  D="$WORK/real-r6"
  check "real round 6 P1-2: a database made again under the same name and owner is refused" bash -c '[ "$1" != 0 ] && grep -q "database r6db or the destination role was dropped and made again since the preflight" "$2/out"' _ "$(cat "$WORK/r6.rc")" "$D"
  check "real round 6 P1-2: the new r6db and its table keep their owner" \
    bash -c '[ "$1" = r6src ] && [ "$2" = r6src ]' _ "$(owner_of_db r6db)" "$(q postgres r6db "SELECT tableowner FROM pg_tables WHERE tablename='r6new'")"

  # -- an owner named O'Brien | ops "x" (P1-b)
  run real-odd legacy-app --database legacy
  check "real odd owner, grant: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"; collect
  check "real odd owner, grant: app role reads s1.t1" [ "$(q legacy-app legacy 'SELECT count(*) FROM s1.t1')" = 1 ]
  odd_later() { psql -h "$PGDIR" -p "$STUB_PGPORT" -U "O'Brien | ops \"x\"" -d legacy -XtAq -c "CREATE TABLE s1.t2 (x int)" >/dev/null 2>&1 && can legacy-app legacy "INSERT INTO s1.t2 VALUES (1)"; }
  check "real odd owner, grant: default privileges for that owner" odd_later
  run real-odd-own legacy-app --database legacy --take-ownership; collect
  check "real odd owner, ownership: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real odd owner, ownership: the message names the owner" grep -qF "O'Brien | ops \"x\" -> legacy-app" "$D/out"
  check "real odd owner, ownership: legacy owned by legacy-app" [ "$(owner_of_db legacy)" = legacy-app ]
  check "real odd owner, ownership: s1.t1 owned by legacy-app" [ "$(q postgres legacy "SELECT tableowner FROM pg_tables WHERE tablename='t1'")" = legacy-app ]

  # -- refused roles (P1-a)
  run real-mig-super evse-ts --database evse:JOURNAL_DB --migration-role super_admin
  check "real: a superuser as migration role is refused" grep -q "exists with SUPERUSER" "$D/out"
  check "real: its password is untouched" [ "$super_pw_before" = "$(q postgres postgres "SELECT rolpassword FROM pg_authid WHERE rolname='super_admin'")" ]
  check "real: and no migrate Secret written" [ ! -e "$D/fake/secrets.plain/evse-ts-db-migrate.secret.yaml" ]
  run real-mig-createrole evse-ts --database evse:JOURNAL_DB --migration-role creator
  check "real: a CREATEROLE role as migration role is refused" grep -q "exists with CREATEROLE" "$D/out"
  run real-mig-unmarked evse-ts --database evse:JOURNAL_DB --migration-role stranger
  check "real: an unmarked role as migration role is refused" grep -q "was not made by this script for evse-ts" "$D/out"
  run real-mig-other evse-ts --database evse:JOURNAL_DB --migration-role other_app_migrate
  check "real: another app's migration role is refused" grep -q "was not made by this script for evse-ts" "$D/out"
  check "real: nothing changed on it" [ "$(q postgres postgres "SELECT rolconnlimit FROM pg_roles WHERE rolname='other_app_migrate'")" = -1 ]
  run real-app-unmarked stranger --database evse_ts
  check "real: an unmarked role as app role (--database) is refused" grep -q "Role stranger exists but was not made by this script" "$D/out"

  # -- --create-missing, and the default path with a migration role.
  run real-create evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database manifest:MANIFEST_DB --create-missing --migration-role; collect
  check "real --create-missing: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real --create-missing: manifest owned by the migration role" [ "$(owner_of_db manifest)" = evse-ts_migrate ]
  check "real --create-missing: PUBLIC cannot connect to the new database" not can stranger manifest "SELECT 1"
  check "real --create-missing --pooler: the pooler role connects to it (P2-1)" can cnpg_pooler_pgbouncer manifest "SELECT 1"
  manifest_ok() { can evse-ts_migrate manifest "CREATE TABLE days (d date)" && can evse-ts manifest "INSERT INTO days VALUES (now())"; }
  check "real --create-missing: the app role uses a table the migration role made there" manifest_ok
  # Round 5 P2-d: the session is cut after CREATE DATABASE and its marker (before PUBLIC's CONNECT
  # is revoked); the retry with the same flags finishes the database.
  STUB_CUT='UPDATE infra_skills.create_intent SET datoid' run real-p2d p2dapp --database p2d_new --create-missing
  check "real round 5 P2-d: the cut run fails" [ "$RC" != 0 ]
  check "real round 5 P2-d: p2d_new exists after the cut, PUBLIC still connects (sanity)" \
    bash -c '[ "$1" = p2dapp ] && psql -h "$2" -p "$3" -U stranger -d p2d_new -XqAt -c "SELECT 1" >/dev/null' _ "$(owner_of_db p2d_new)" "$PGDIR" "$STUB_PGPORT"
  check "real round 5 P2-d: the intent is pending" [ "$(q postgres postgres "SELECT count(*) FROM infra_skills.create_intent WHERE datname='p2d_new' AND done_at IS NULL")" = 1 ]
  PRE_RUN="$D" run real-p2d p2dapp --database p2d_new --create-missing; collect
  check "real round 5 P2-d: the retry finishes it: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real round 5 P2-d: PUBLIC can no longer connect to it" not can stranger p2d_new "SELECT 1"
  check "real round 5 P2-d: the app role connects" can p2dapp p2d_new "SELECT 1"
  check "real round 5 P2-d: the intent is done" [ "$(q postgres postgres "SELECT count(*) FROM infra_skills.create_intent WHERE datname='p2d_new' AND done_at IS NOT NULL")" = 1 ]
  check "real round 6 P2-a: the database the run made carries its marker" \
    bash -c '[[ "$1" == infra-skills:created:p2dapp:?* ]]' _ "$(q postgres postgres "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname='p2d_new'")"
  # Round 6 P2-a: the session is cut before CREATE DATABASE (the intent is recorded); then someone
  # else makes a database of that name, owned by the same role. The retry must not take it for its own.
  STUB_CUT_BEFORE='CREATE DATABASE' run real-p2a p2aapp --database p2a_new --create-missing
  check "real round 6 P2-a: the cut run fails before CREATE DATABASE (sanity)" bash -c '[ "$1" != 0 ] && [ -z "$2" ]' _ "$RC" "$(owner_of_db p2a_new)"
  q postgres postgres "CREATE DATABASE p2a_new OWNER p2aapp" >/dev/null || fail "real round 6 P2-a: the foreign database"
  PRE_RUN="$D" run real-p2a p2aapp --database p2a_new --create-missing
  check "real round 6 P2-a: a foreign same-named database with the same owner is refused" \
    bash -c '[ "$1" != 0 ] && grep -q "nothing shows it is the one an earlier run for p2aapp created" "$2/out"' _ "$RC" "$D"
  check "real round 6 P2-a: PUBLIC is untouched on it" can stranger p2a_new "SELECT 1"
  # ... and a cut between CREATE DATABASE and its marker: the retry cannot tell it apart, and refuses too.
  STUB_CUT='CREATE DATABASE' run real-p2a2 p2a2app --database p2a2_new --create-missing
  PRE_RUN="$D" run real-p2a2 p2a2app --database p2a2_new --create-missing
  check "real round 6 P2-a: a database cut off before its marker is not finished blindly either" \
    bash -c '[ "$1" != 0 ] && grep -q "nothing shows it is the one" "$2/out"' _ "$RC" "$D"
  check "real round 6 P2-a: PUBLIC is untouched on it" can stranger p2a2_new "SELECT 1"
  check "real round 7 P3: the refusal spells out the ACL step (--revoke-public --keep-connect)" \
    grep -q "fake --provision-credentials p2a2app --database p2a2_new\[:<PREFIX>\] --revoke-public --keep-connect" "$D/out"
  # Round 7 P2-a: app p7a's creation of p7db is cut before CREATE DATABASE; app p7b then asks for a
  # database of the same name. It is refused, and p7a's pending intent stays exactly as it was.
  STUB_CUT_BEFORE='CREATE DATABASE' run real-p7a p7a --database p7db --create-missing
  intent_of() { q postgres postgres "SELECT row_to_json(i)::text FROM infra_skills.create_intent i WHERE datname = '$1'" || true; }   # the whole row, any version
  p7_before="$(intent_of p7db)"
  check "real round 7 P2-a: p7a's intent is pending, no database yet (sanity)" bash -c '[[ "$1" == *"\"app\":\"p7a\""* && "$1" == *"\"done_at\":null"* && -z "$2" ]]' _ "$p7_before" "$(owner_of_db p7db)"
  run real-p7b p7b --database p7db --create-missing
  check "real round 7 P2-a: another app with the same database name is refused" \
    bash -c '[ "$1" != 0 ] && grep -q "app p7a has a pending creation of a database by that name" "$2/out"' _ "$RC" "$D"
  check "real round 7 P2-a: p7a's intent row is unchanged, and no database p7db was made" \
    bash -c '[ "$1" = "$2" ] && [ -z "$3" ]' _ "$p7_before" "$(intent_of p7db)" "$(owner_of_db p7db)"
  # Round 7 P2-b: p7r's creation is cut after the intent recorded its oid; someone renames p7rdb
  # away and makes a replacement with the app-wide marker an earlier version used. The retry must
  # require the recorded oid.
  STUB_CUT='UPDATE infra_skills.create_intent SET datoid' run real-p7r p7r --database p7rdb --create-missing
  check "real round 7 P2-b: the intent recorded the oid (sanity)" \
    [ "$(q postgres postgres "SELECT (datoid = (SELECT oid FROM pg_database WHERE datname = 'p7rdb'))::text FROM infra_skills.create_intent WHERE datname = 'p7rdb'")" = true ]
  q postgres postgres "ALTER DATABASE p7rdb RENAME TO p7rdb_old" >/dev/null || fail "real round 7 P2-b: rename"
  q postgres postgres "CREATE DATABASE p7rdb OWNER p7r" >/dev/null || fail "real round 7 P2-b: replacement"
  q postgres postgres "COMMENT ON DATABASE p7rdb IS 'infra-skills:created:p7r'" >/dev/null || fail "real round 7 P2-b: marker"
  PRE_RUN="$D" run real-p7r p7r --database p7rdb --create-missing
  check "real round 7 P2-b: a renamed replacement with the app's marker is refused" \
    bash -c '[ "$1" != 0 ] && grep -q "nothing shows it is the one an earlier run for p7r created" "$2/out"' _ "$RC" "$D"
  check "real round 7 P2-b: PUBLIC is untouched on the replacement" can stranger p7rdb "SELECT 1"
  # Round 5 P2-b: --keep-password, and the app role's password is rotated elsewhere while the run
  # waits (a held intent row stalls it after its first check); the Secret is not applied.
  rc_dir="$WORK/real-create"
  hold postgres "INSERT INTO infra_skills.create_intent (datname, app, revoke_public, nonce) VALUES ('p2b_new', 'x', true, 'held');" || fail "real P2-b: holder did not start"
  p2b_secret_before="$(cat "$rc_dir/fake/secrets.plain/evse-ts-db.secret.yaml")"
  ( PRE_RUN="$rc_dir" run real-create evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database manifest:MANIFEST_DB \
      --database p2b_new:P2B_DB --create-missing --migration-role --keep-password; echo "$RC" > "$WORK/p2b.rc" ) &
  p2b=$!
  waited=0
  for _ in $(seq 1 100); do
    [[ "$(q postgres postgres "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE 'INSERT INTO infra_skills.create_intent%'")" -ge 1 ]] && { waited=1; break; }
    /bin/sleep 0.1
  done
  check "real round 5 P2-b: the run passed its first password check and waits (sanity)" [ "$waited" = 1 ]
  q postgres postgres "ALTER ROLE \"evse-ts\" PASSWORD 'rotated-elsewhere-0123456789abcdef'" >/dev/null || fail "real P2-b: rotation"
  release
  wait "$p2b" || true
  D="$rc_dir"
  check "real round 5 P2-b: the run fails" [ "$(cat "$WORK/p2b.rc")" != 0 ]
  check "real round 5 P2-b: on the re-check before the Secret" grep -q "role evse-ts's password changed during this run" "$D/out"
  check "real round 5 P2-b: the Secret file is untouched, and not applied" \
    bash -c '[ "$1" = "$(cat "$2/fake/secrets.plain/evse-ts-db.secret.yaml")" ] && [ ! -e "$2/log.applied/evse-ts-db.secret.yaml" ]' _ "$p2b_secret_before" "$D"
  check "real round 5 P2-b: the rotated password still logs in" scram_login evse-ts rotated-elsewhere-0123456789abcdef
  # Round 5 P3: a NOINHERIT member of the group holding CONNECT still relies on PUBLIC.
  run real-p3 p3app --database p3db
  check "real round 5 P3: the PUBLIC warning names the NOINHERIT member" grep -q "connect through PUBLIC only: .*aaa_noinh" "$D/out"
  run real-default my-app --migration-role --migration-schema my-app.flyway; collect
  check "real default + migration role: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real default: my-app owns database my-app" [ "$(owner_of_db my-app)" = my-app ]
  check "real default: app role creates a table (as before)" can my-app my-app "CREATE TABLE t_app (x int)"
  check "real default: migration role cannot ALTER the app role's table (no membership)" not can my-app_migrate my-app "ALTER TABLE t_app ADD COLUMN y int"
  check "real default: migration role writes the app role's table (default privileges)" can my-app_migrate my-app "INSERT INTO t_app VALUES (1)"
  mig_ok() { can my-app_migrate my-app "CREATE TABLE flyway.history (x int)" && can my-app my-app "INSERT INTO flyway.history VALUES (1)"; }
  check "real default: app role uses the migration role's table in its schema" mig_ok
  check "real default: PUBLIC cannot connect" not can stranger my-app "SELECT 1"
  check "real default + migration role: the hint names --take-ownership (P2-4)" grep -q "take-ownership --migration-role my-app_migrate" "$D/out"
  check "real default: SCRAM login with the default Secret's password (P1-1)" scram_login my-app "$(key "$D/fake/secrets.plain/my-app-db.secret.yaml" POSTGRES_PASSWORD)"
  check "real default: SCRAM login with the migrate Secret's password" scram_login my-app_migrate "$(key "$D/fake/secrets.plain/my-app-db-migrate.secret.yaml" POSTGRES_PASSWORD)"
  run real-adopt my-app --database my-app:APP_DB; collect
  check "real: the default path's app role is adopted in --database mode" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real: and marked" [ "$(q postgres postgres "SELECT shobj_description(oid, 'pg_authid') FROM pg_roles WHERE rolname='my-app'")" = infra-skills:app:my-app ]
  run real-handoff my-app --database my-app:APP_DB --take-ownership --migration-role --migration-schema my-app.flyway; collect
  check "real handoff: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real handoff: the migration role can ALTER the app role's old table now (P2-4)" can my-app_migrate my-app "ALTER TABLE t_app ADD COLUMN y int"
  check "real handoff: the app role still writes it" can my-app my-app "INSERT INTO t_app (x) VALUES (2)"
  check "real handoff: the app role still connects" can my-app my-app "SELECT 1"
  check "real handoff: no hint after --take-ownership" bash -c '! grep -q "cannot ALTER or DROP what other" "$1"' _ "$D/out"

  # -- a failing password statement is not logged with its text (P1-c)
  q postgres postgres "ALTER ROLE postgres SET lock_timeout = '1s'" >/dev/null
  # a row lock on the role's pg_authid row: the guard's table locks pass, the password statement waits and times out
  hold postgres "SELECT 1 FROM pg_authid WHERE rolname = 'evse-ts' FOR UPDATE;" || fail "real P1-c: lock holder did not start"
  run real-fail-app evse-ts --tenant symbioen --database evse:JOURNAL_DB; collect
  release
  check "real P1-c, app role: the password statement failed (lock timeout)" [ "$RC" != 0 ]
  check "real P1-c, app role: the server logged the failure" grep -q "canceling statement due to lock timeout" "$PGDIR/log"
  check "real P1-c, app role: the client output holds no password" client_clean "$D/log.sql" "$D/out"
  check "real P1-c, app role: no plaintext password in the server log" bash -c '! grep -qE "$1" "$2"' _ "$PW_RE" "$PGDIR/log"
  hold postgres "SELECT 1 FROM pg_authid WHERE rolname = 'evse-ts_migrate' FOR UPDATE;" || fail "real P1-c: lock holder did not start"
  run real-fail-mig evse-ts --tenant symbioen --database evse:JOURNAL_DB --migration-role; collect
  release
  check "real P1-c, migration role: the password statement failed" [ "$RC" != 0 ]
  check "real P1-c, migration role: the client output holds no password" client_clean "$D/log.sql" "$D/out"
  check "real P1-c, migration role: no plaintext password in the server log" bash -c '! grep -qE "$1" "$2"' _ "$PW_RE" "$PGDIR/log"
  q postgres postgres "ALTER ROLE postgres RESET lock_timeout" >/dev/null
  run real-range evse-ts --tenant symbioen --database evse:JOURNAL_DB --connection-limit 99999999999
  check "real P1-c: an out-of-range limit is refused before any SQL" bash -c '[ "$1" != 0 ] && [ ! -s "$2" ]' _ "$RC" "$D/log.sql"

  # -- the server log: no password of a protected statement, in any of the runs above
  check "real log: passwords were set in these runs (sanity)" [ "$(sort -u "$PROTECTED" | grep -c .)" -ge 8 ]
  check "real log: sampled logging is on (sanity)" [ "$(q postgres postgres "SELECT current_setting('log_transaction_sample_rate') || '/' || current_setting('log_min_duration_sample') || '/' || current_setting('log_statement')")" = "1/0/all" ]
  check "real log: no plaintext password anywhere in the server log (P1-1)" bash -c '! grep -qE "$1" "$2"' _ "$PW_RE" "$PGDIR/log"
  check "real log: the default path's statement reached the server as a SCRAM verifier only" \
    grep -qF "ALTER ROLE \"my-app\" WITH LOGIN PASSWORD 'SCRAM-SHA-256\$4096:" "$PGDIR/log"
  cleanup; trap - EXIT
  (( failures > 0 )) || rm -rf "$PGDIR"
fi

check "no plaintext password reached psql in any run (P1-1)${PLAINTEXT_RUNS:+:$PLAINTEXT_RUNS}" [ -z "$PLAINTEXT_RUNS" ]
check "no secret in any child process's environment, in any run (P2-1)${ENV_RUNS:+:$ENV_RUNS}" [ -z "$ENV_RUNS" ]

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed (work dir: $WORK)"
  exit 1
fi
echo "all checks passed"
rm -rf "$WORK"
