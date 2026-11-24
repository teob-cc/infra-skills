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
#   2. --database <name>[:<PREFIX>] (grant mode): no database is created, the role gets CONNECT,
#      schema, table and sequence rights and default privileges on each, PUBLIC keeps its CONNECT
#      (a warning names who relies on it), the Secret holds <PREFIX>_HOST/PORT/DATABASE/USERNAME/
#      PASSWORD per database; bad specs, a missing database and --create-missing; --revoke-public
#      with --keep-connect; --take-ownership through the ledger, and its refusals;
#   3. --migration-role: the second role (no statement_timeout, own connection limit, no membership
#      in the app role), its grants and default privileges, --migration-schema, its Secret; role
#      names: reserved, pg_*, privileged and unmarked roles are refused;
#   4. connection limits and timeouts: values and range checks before any SQL;
#   5. re-runs: the same SQL again; --keep-password keeps an existing role's password untouched,
#      and refuses a file whose *_PASSWORD values disagree;
#   6. a failing or short openssl stops the run before any SQL;
#   7. under bash -x no password reaches stdout or stderr, and none is ever on kubectl's argv;
#   8. (--real-postgres) the same against a real server, with log_statement = all and
#      log_min_duration_statement = 0: rights, PUBLIC, ownership moves (an interrupted one is
#      completed by the next run), names with quotes, | and spaces, refused roles, and no password
#      of the protected statements in the server log, also when the statement fails.
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
      STUB_OPENSSL_FAIL STUB_OPENSSL_SHORT APP_NAMESPACE
PW_RE='Pw0Stub[0-9]+AbCdEfGhIjKlMn\+/='
US=$'\x1f'

RUN_SEQ=0   # each run gets its own password prefix (Pw0Stub<run>), so passwords never repeat across runs
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
  if [[ -z "${PRE_RUN:-}" ]]; then mkdir -p "$D"; cp -R "$HERE/envs/." "$D/"; fi
  : > "$D/log"; rm -rf "$D/log.sql" "$D/log.applied"
  RC=0
  RUN_SEQ=$((RUN_SEQ + 1))
  STUB_PW_PREFIX="Pw0Stub$(printf '%03d' "$RUN_SEQ")" STUB_LOG="$D/log" INFRA_ENVS_ROOT="$D" ${TRACE:-} "$SCRIPT" fake --provision-credentials "$@" >"$D/out" 2>&1 || RC=$?
  touch "$D/log.sql"
}
norm() { sed -E -e "s#$D#<WORK>#g" -e "s#$PW_RE#<PW>#g"; }
secret_json() { yq -o=json '.' "$1" | jq -S .; }
key() { # <secret file> <key>
  yq -r ".stringData.$2 // \"\"" "$1" 2>/dev/null || true
}
# Preflight rows for the stub (| becomes \x1f):
#   dbrow <name> <owner> [owner is new f] [pending f] [old owner = owner] [old privileged f] [old's other dbs] [old's tablespaces 0]
#         [PUBLIC has CONNECT t] [connected now through PUBLIC] [login roles relying on PUBLIC]
dbrow() {
  local old="${5:-$2}" isnew="${3:-f}"
  [[ "$old" != "$2" ]] && isnew=f
  echo "db|$1|t|$2|${3:-f}|${4:-f}|$old|$isnew|${6:-f}|${7:-}|${8:-0}|${9:-t}|${10:-}|${11:-}"
}
#   rolerow <kind> <name> [exists t] [marked t] [comment] [attributes] [memberships] [owns its db f]
rolerow() { echo "role|$1|$2|${3:-t}|${4:-t}|${5:-}|${6:-}|${7:-}|${8:-f}"; }
nodb() { echo "db|$1|f||f|f||f|f||0|f||"; }

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
export STUB_DB_OWNERS; STUB_DB_OWNERS="$(dbrow evse scala_owner f f scala_owner f '' 0 t '' 'other_app'; dbrow evse_ts scala_owner)"
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
check "grant: the app role gets CONNECT explicitly" contains "$sql" 'GRANT CONNECT, TEMPORARY ON DATABASE :"db" TO :"role";'
check "grant: schema USAGE, CREATE" contains "$sql" "GRANT USAGE, CREATE ON SCHEMA %I TO %I"
check "grant: table rights" contains "$sql" "GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA"
check "grant: sequence rights" contains "$sql" "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA"
check "grant: default privileges for the owners" contains "$sql" "ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO %I"
check "grant: tenant role keeps 60s" grep -qF "\\set stmt_to '60s'" "$D/log.sql"
check "grant: tenant role keeps 5min idle in transaction" grep -qF "\\set idle_to '5min'" "$D/log.sql"
check "grant: the role gets this app's marker" contains "$sql" "\\set amarker 'infra-skills:app:evse-ts'"
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
  check "$d: no SQL changes anything (the preflight aside)" bash -c '! awk "/^-- ### /{getline t; pre = (t == \"-- infra-skills:preflight\")} !pre" "$1" | grep -qE "ALTER ROLE|GRANT |REVOKE |CREATE ROLE"' _ "$D/log.sql"
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
check "--create-missing: creates only manifest" [ "$(grep -c "CREATE DATABASE %I OWNER %I', :'db', :'owner'" "$D/log.sql")" = 1 ]
check "--create-missing: owned by the app role" grep -q "^\\\\set owner 'evse-ts'" "$D/log.sql"
check "--create-missing: PUBLIC revoked on the new database only" [ "$(grep -c 'REVOKE CONNECT, TEMPORARY ON DATABASE :"db" FROM PUBLIC' "$D/log.sql")" = 1 ]
check "--create-missing: extensions only in manifest" bash -c 'grep "CREATE EXTENSION" "$1" | grep -qv -- "-d manifest" && exit 1; grep -q -- "-d manifest -qc CREATE EXTENSION" "$1"' _ "$D/log"

# --revoke-public --keep-connect (P1-d)
bad "--revoke-public without --keep-connect" "--revoke-public needs --keep-connect" x --database evse --revoke-public
bad "--keep-connect without --revoke-public" "--keep-connect goes with --revoke-public" x --database evse --keep-connect a
bad "--revoke-public without --database" "go with --database" x --revoke-public --keep-connect none
bad "--keep-connect with a quote" "is not a role name" x --database evse --revoke-public --keep-connect "a'b"
STUB_NEED='need|other_app|f' STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "--keep-connect names a missing role" "role other_app does not exist" x --database evse --revoke-public --keep-connect other_app
STUB_NO_POOLER_ROLE=1 STUB_NEED='need|other_app|t' STUB_DB_OWNERS="$(dbrow evse scala_owner)" \
  bad "--revoke-public, pooler role missing" "the pooler role cnpg_pooler_pgbouncer does not exist" x --database evse --pooler --revoke-public --keep-connect other_app
STUB_NEED=$'need|other_app|t\nneed|reporting|t' STUB_DB_OWNERS="$(dbrow evse scala_owner f f scala_owner f '' 0 t 'stranger' 'stranger')" \
  PG_READONLY_ROLE=claude_ro run revoke my-app --database evse --pooler --revoke-public --keep-connect other_app,reporting
check "--revoke-public: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
check "--revoke-public: the preflight checks the kept roles and the read-only role" grep -qF "\\set need 'other_app,reporting,claude_ro'" "$D/log.sql"
check "--revoke-public: owner gets CONNECT before the revoke" before "$D/log.sql" "pg_get_userbyid(datdba)) FROM pg_database WHERE datname = :'db'" 'ON DATABASE :"db" FROM PUBLIC;'
check "--revoke-public: the former owner (ledger) gets CONNECT before the revoke" before "$D/log.sql" "FROM infra_skills.ownership_transfer l JOIN pg_roles r" 'ON DATABASE :"db" FROM PUBLIC;'
check "--revoke-public: the kept roles get CONNECT before the revoke" before "$D/log.sql" "unnest(string_to_array(:'keep', ','))" 'ON DATABASE :"db" FROM PUBLIC;'
check "--revoke-public: the kept roles are other_app,reporting" grep -qF "\\set keep 'other_app,reporting'" "$D/log.sql"
check "--revoke-public: read-only and pooler roles get CONNECT before the revoke" before "$D/log.sql" "TO cnpg_pooler_pgbouncer" 'ON DATABASE :"db" FROM PUBLIC;'
check "--revoke-public: revoked once" [ "$(grep -c 'REVOKE CONNECT, TEMPORARY ON DATABASE :"db" FROM PUBLIC' "$D/log.sql")" = 1 ]
check "--revoke-public: warns who loses CONNECT" grep -q "lose CONNECT now: stranger" "$D/out"
check "--revoke-public: and who is connected now" grep -q "connected now: stranger" "$D/out"

# --take-ownership (P2-a, P1-b)
export STUB_DB_OWNERS; STUB_DB_OWNERS="$(dbrow evse scala_owner; dbrow evse_ts scala_owner)"
run own evse-ts --database evse:JOURNAL_DB --database evse_ts:STATE_DB --take-ownership --migration-role
check "--take-ownership: exit 0" [ "$RC" = 0 ]
check "--take-ownership: the ledger is made in the preflight" grep -q "CREATE TABLE IF NOT EXISTS infra_skills.ownership_transfer" "$D/log.sql"
check "--take-ownership: the original owner is recorded for each database (2)" [ "$(grep -c "INSERT INTO infra_skills.ownership_transfer" "$D/log.sql")" = 2 ]
check "--take-ownership: recorded before anything moves" before "$D/log.sql" "INSERT INTO infra_skills.ownership_transfer" "ALTER DATABASE %I OWNER TO %I"
check "--take-ownership: the owner comes from the ledger, quoted by the server (2)" [ "$(grep -c "REASSIGN OWNED BY %I TO %I', pg_get_userbyid(:from_oid), pg_get_userbyid(:to_oid)" "$D/log.sql")" = 2 ]
check "--take-ownership: REASSIGN runs inside each database" bash -c 'awk "/^\\\\c :\"db\"/{indb=1} /^\\\\c postgres/{indb=0} /REASSIGN OWNED/{ if (!indb) bad=1 } END{exit bad}" "$1"' _ "$D/log.sql"
check "--take-ownership: no owner name spliced into SQL (P1-b)" bash -c '! grep -q "scala_owner" "$1" && ! grep -q "set old_owner" "$1"' _ "$D/log.sql"
check "--take-ownership: each move is checked (2)" [ "$(grep -c "are still owned by" "$D/log.sql")" = 2 ]
check "--take-ownership: and marked done (2)" [ "$(grep -c "SET done_at = now()" "$D/log.sql")" = 2 ]
check "--take-ownership: new owner is evse-ts_migrate" grep -q "^\\\\set owner 'evse-ts_migrate'" "$D/log.sql"
check "--take-ownership: the migration role exists before the move" \
  before "$D/log.sql" "CREATE ROLE %I LOGIN', :'mrole'" "INSERT INTO infra_skills.ownership_transfer"
STUB_DB_OWNERS="$(dbrow evse evse-ts_migrate t)" run own-again evse-ts --database evse:JOURNAL_DB --take-ownership --migration-role
check "--take-ownership, already owned: no REASSIGN" bash -c '! grep -q REASSIGN "$1"' _ "$D/log.sql"
STUB_DB_OWNERS="$(dbrow evse evse-ts_migrate t t scala_owner)" run own-retry evse-ts --database evse:JOURNAL_DB --take-ownership --migration-role
check "--take-ownership, unfinished move: completed, not skipped (P2-a)" grep -q "REASSIGN OWNED" "$D/log.sql"
check "--take-ownership, unfinished move: says so" grep -q "left the move from scala_owner unfinished" "$D/out"
STUB_DB_OWNERS="$(dbrow evse postgres f f postgres t)" bad "--take-ownership from a superuser" "a superuser or system role" x --database evse --take-ownership
STUB_DB_OWNERS="$(dbrow evse scala_owner f f scala_owner f other_db)" bad "--take-ownership, owner has another database" "also owns: other_db" x --database evse --take-ownership
STUB_DB_OWNERS="$(dbrow evse scala_owner f f scala_owner f '' 1)" bad "--take-ownership, owner has a tablespace" "owns a tablespace" x --database evse --take-ownership

# --- 3. migration role --------------------------------------------------------------------
echo "== 3. --migration-role"
run mig evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role \
  --migration-schema evse.archive --migration-schema evse.backfill
check "migration: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
sql="$(cat "$D/log.sql")"; s="$D/fake/secrets.plain/evse-ts-db.secret.yaml"; m="$D/fake/secrets.plain/evse-ts-db-migrate.secret.yaml"
check "migration: role evse-ts_migrate" contains "$sql" "\\set mrole 'evse-ts_migrate'"
check "migration: its marker" contains "$sql" "\\set mmarker 'infra-skills:migrate:evse-ts'"
check "migration: connection limit 2" contains "$sql" "ALTER ROLE :\"mrole\" WITH LOGIN PASSWORD :'pw' CONNECTION LIMIT 2;"
check "migration: password statement with log_statement none" bash -c 'grep -B4 "ALTER ROLE :\"mrole\" WITH LOGIN PASSWORD" "$1" | grep -q "SET LOCAL log_statement = .none."' _ "$D/log.sql"
check "migration: password statement errors not logged with their text (P1-c)" bash -c 'grep -B4 "ALTER ROLE :\"mrole\" WITH LOGIN PASSWORD" "$1" | grep -q "SET LOCAL log_min_error_statement = .panic."' _ "$D/log.sql"
check "migration: nor slow-statement logged" bash -c 'grep -B4 "ALTER ROLE :\"mrole\" WITH LOGIN PASSWORD" "$1" | grep -q "SET LOCAL log_min_duration_statement = -1"' _ "$D/log.sql"
check "migration: statement_timeout 0" contains "$sql" 'ALTER ROLE :"mrole" SET statement_timeout = 0;'
check "migration: idle_in_transaction_session_timeout 0" contains "$sql" 'ALTER ROLE :"mrole" SET idle_in_transaction_session_timeout = 0;'
check "migration: no membership in the app role (P2-d)" lacks "$sql" "format('GRANT %I TO %I', :'role', :'mrole')"
check "migration: an old membership is revoked" contains "$sql" "format('REVOKE %I FROM %I', :'role', :'mrole')"
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
check "migration, default path: the app session is unchanged (second session = golden)" \
  diff <(awk '/^-- ### /{n++} n==2' "$D/log.sql" | norm) "$HERE/golden/plain.sql"
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
check "an app role made by the default path: gets the marker" grep -qF "COMMENT ON ROLE %I IS %L', :'role', :'amarker'" "$D/log.sql"
STUB_ROLES="$(rolerow app x; rolerow migrate x_mig)" STUB_DB_OWNERS="$(dbrow evse scala_owner)" run marked x --database evse --migration-role x_mig
check "marked roles: reused" [ "$RC" = 0 ]

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
STUB_ROLES="$(rolerow app evse-ts; rolerow migrate evse-ts_migrate)" \
  PRE_RUN="$D" run rerun evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role --keep-password
check "--keep-password, roles exist: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
check "--keep-password: no new password made" bash -c '! grep -q "^openssl" "$1"' _ "$D/log"
check "--keep-password, roles exist: no password sent at all (P2-c)" bash -c '! grep -q "PASSWORD" "$1" && ! grep -qF "$2" "$1" && ! grep -qF "$3" "$1"' _ "$D/log.sql" "$kept_pw" "$kept_mpw"
check "--keep-password, roles exist: limits still set" bash -c 'grep -qF "ALTER ROLE :\"role\" WITH LOGIN CONNECTION LIMIT 20;" "$1" && grep -qF "ALTER ROLE :\"mrole\" WITH LOGIN CONNECTION LIMIT 2;" "$1"' _ "$D/log.sql"
check "--keep-password: app password kept in the Secret" [ "$kept_pw" = "$(key "$D/fake/secrets.plain/evse-ts-db.secret.yaml" STATE_DB_PASSWORD)" ]
check "--keep-password: migration password kept in the Secret" [ "$kept_mpw" = "$(key "$D/fake/secrets.plain/evse-ts-db-migrate.secret.yaml" STATE_DB_PASSWORD)" ]
check "--keep-password: the password is not in the output" bash -c '! grep -qF -e "$2" -e "$3" "$1"' _ "$D/out" "$kept_pw" "$kept_mpw"
PRE_RUN="$D" run rerun evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role --keep-password
check "--keep-password, roles missing: exit 0" [ "$RC" = 0 ]
check "--keep-password, roles missing: created with the stored password" grep -qF "\\set pw '$kept_pw'" "$D/log.sql"
rr="$D"
yq -i ".stringData.STATE_DB_PASSWORD = \"Pw0Stub99AbCdEfGhIjKlMn+/=\"" "$rr/fake/secrets.plain/evse-ts-db.secret.yaml" \
  || fail "--keep-password: fixture: no Secret file to edit"
STUB_ROLES="$(rolerow app evse-ts)" PRE_RUN="$rr" run rerun evse-ts --tenant symbioen --database evse:JOURNAL_DB --database evse_ts:STATE_DB --keep-password
check "--keep-password, *_PASSWORD values disagree: refused (P2-c)" [ "$RC" != 0 ]
check "--keep-password, *_PASSWORD values disagree: says so" grep -q "they must all agree" "$D/out"
check "--keep-password, *_PASSWORD values disagree: no role change" bash -c '! grep -q "ALTER ROLE" "$1"' _ "$D/log.sql"
bad "--keep-password with no Secret file" "holds no usable *_PASSWORD" x --database evse --keep-password
run keep-default my-app
STUB_ROLES="$(rolerow app my-app t f '' '' '' t)" PRE_RUN="$D" run keep-default my-app --keep-password
check "--keep-password, default path, role exists: exit 0" [ "$RC" = 0 ]
check "--keep-password, default path, role exists: no password sent" bash -c '! grep -q "PASSWORD" "$1"' _ "$D/log.sql"
check "--keep-password, default path: legacy Secret rendering" grep -q '^  POSTGRES_PASSWORD: Pw0Stub' "$D/fake/secrets.plain/my-app-db.secret.yaml"

# --- 6. openssl failures (P2-b) -----------------------------------------------------------
echo "== 6. password generation failures"
STUB_OPENSSL_FAIL=1 bad "openssl fails, default path" "Could not make a password" my-app
STUB_OPENSSL_SHORT=1 bad "openssl prints a short password, default path" "Could not make a password" my-app
STUB_OPENSSL_FAIL=1 STUB_DB_OWNERS="$(dbrow evse scala_owner)" bad "openssl fails, --database" "Could not make a password" x --database evse
STUB_OPENSSL_SHORT=1 STUB_DB_OWNERS="$(dbrow evse scala_owner)" bad "openssl short, migration role" "Could not make a password" x --database evse --migration-role

# --- 7. no secret under bash -x -----------------------------------------------------------
echo "== 7. bash -x"
xtrace() { # <name> <args...>
  local name="$1"; shift
  TRACE="bash -x" run "$name" "$@"
  check "$name: exit 0" [ "$RC" = 0 ]
  check "$name: the trace is on (sanity)" grep -q '^+' "$D/out"
  check "$name: the passwords went to psql on stdin (sanity)" grep -qE "$PW_RE" "$D/log.sql"
  check "$name: no password in stdout/stderr" bash -c '! grep -qE "$2" "$1"' _ "$D/out" "$PW_RE"
  check "$name: no password on any kubectl argv" bash -c '! grep -qE "$2" "$1"' _ "$D/log" "$PW_RE"
}
xtrace xtrace-default evse-ts --tenant symbioen --pooler
xtrace xtrace-existing evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role
D="$WORK/xtrace-existing"; PRE_RUN="$D" TRACE="bash -x" run xtrace-existing evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role --keep-password
check "xtrace --keep-password: exit 0" [ "$RC" = 0 ]
check "xtrace --keep-password: no password in stdout/stderr" bash -c '! grep -qE "$2" "$1"' _ "$D/out" "$PW_RE"
unset STUB_DB_OWNERS

# --- 8. a real server ---------------------------------------------------------------------
if $REAL; then
  echo "== 8. real Postgres (local, unix socket only, every statement logged)"
  for t in initdb pg_ctl psql; do command -v "$t" >/dev/null 2>&1 || { echo "Missing: $t" >&2; exit 1; }; done
  PGDIR="$(mktemp -d -t pgc-XXXX)"; export STUB_PGHOST="$PGDIR" STUB_PGPORT=54329
  initdb -D "$PGDIR/data" -U postgres --auth=trust >/dev/null
  pg_ctl -D "$PGDIR/data" -l "$PGDIR/log" -w \
    -o "-c listen_addresses='' -k $PGDIR -p $STUB_PGPORT -c log_statement=all -c log_min_duration_statement=0" start >/dev/null
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
  # release; waits until the backend waits in pg_sleep.
  hold() {
    printf 'BEGIN;\n%s\nSELECT pg_sleep(60);\n' "$2" | psql -h "$PGDIR" -p "$STUB_PGPORT" -U postgres -d "$1" -Xq >/dev/null 2>&1 &
    HOLDERS+=($!)
    local _; for _ in $(seq 1 50); do
      [[ "$(q postgres postgres "SELECT count(*) FROM pg_stat_activity WHERE query LIKE 'SELECT pg_sleep(60)%' AND state = 'active'")" -ge 1 ]] && return 0
      /bin/sleep 0.1
    done
    return 1
  }
  release() { q postgres postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE 'SELECT pg_sleep(60)%'" >/dev/null; }
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
  log_clean() { # <log.sql>: no protected password of the run in the server log
    local p; while IFS= read -r p; do [[ -n "$p" ]] && grep -qF -- "$p" "$PGDIR/log" && return 1; done < <(protected_pws "$1"); return 0
  }
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
CREATE ROLE "O'Brien | ops ""x""" LOGIN;
CREATE DATABASE evse OWNER evse_ts;
CREATE DATABASE evse_ts OWNER evse_ts;
CREATE DATABASE other;
CREATE DATABASE legacy OWNER "O'Brien | ops ""x""";
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

  # -- --revoke-public (P1-d)
  run real-revoke-missing evse-ts --tenant symbioen --database evse:JOURNAL_DB --revoke-public --keep-connect nobody_here
  check "real --revoke-public, kept role missing: refused" grep -q "role nobody_here does not exist" "$D/out"
  check "real --revoke-public, kept role missing: PUBLIC untouched" can stranger evse "SELECT 1"
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

  # -- --take-ownership, interrupted, then completed (P2-a)
  run real-own-refused evse-ts --database evse:JOURNAL_DB --take-ownership --migration-role
  check "real ownership: refused when the owner has another database" grep -q "also owns: evse_ts" "$D/out"
  check "real ownership: refused -> evse still owned by evse_ts" [ "$(owner_of_db evse)" = evse_ts ]
  q postgres postgres "ALTER ROLE postgres SET lock_timeout = '2s'" >/dev/null
  hold evse_ts "LOCK TABLE public.station_view IN ACCESS EXCLUSIVE MODE;" || fail "real ownership: lock holder did not start"
  run real-own evse-ts --database evse:JOURNAL_DB --database evse_ts:STATE_DB --take-ownership --migration-role; collect
  release
  check "real ownership, interrupted: the run fails" [ "$RC" != 0 ]
  check "real ownership, interrupted: evse's tables moved" [ "$(q postgres evse "SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname='journal'")" = evse-ts_migrate ]
  check "real ownership, interrupted: evse_ts's table still has the old owner" [ "$(q postgres evse_ts "SELECT tableowner FROM pg_tables WHERE tablename='station_view'")" = evse_ts ]
  PRE_RUN="$D" run real-own evse-ts --database evse:JOURNAL_DB --database evse_ts:STATE_DB --take-ownership --migration-role; collect
  check "real ownership, retry: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real ownership, retry: completes the move instead of skipping it (P2-a)" \
    [ "$(q postgres evse_ts "SELECT tableowner FROM pg_tables WHERE tablename='station_view'")" = evse-ts_migrate ]
  check "real ownership: databases owned by evse-ts_migrate" \
    [ "$(q postgres postgres "SELECT string_agg(DISTINCT pg_get_userbyid(datdba), ',') FROM pg_database WHERE datname IN ('evse','evse_ts')")" = evse-ts_migrate ]
  check "real ownership: nothing in either database owned by evse_ts" \
    [ "$(q postgres evse_ts "SELECT count(*) FROM pg_shdepend WHERE refobjid = (SELECT oid FROM pg_roles WHERE rolname='evse_ts') AND deptype='o' AND classid <> 'pg_default_acl'::regclass AND dbid IN (SELECT oid FROM pg_database WHERE datname IN ('evse','evse_ts'))")" = 0 ]
  check "real ownership: the ledger says done for both" \
    [ "$(q postgres postgres "SELECT count(*) FROM infra_skills.ownership_transfer WHERE datname IN ('evse','evse_ts') AND done_at IS NOT NULL")" = 2 ]
  check "real ownership: the ledger is closed to PUBLIC" not can stranger postgres "SELECT * FROM infra_skills.ownership_transfer"
  check "real ownership: migration role can ALTER the journal now" can evse-ts_migrate evse "ALTER TABLE journal.events ADD COLUMN y int"
  check "real ownership: app role still writes it" can evse-ts evse "INSERT INTO journal.events (payload) VALUES ('c')"
  check "real ownership: other untouched" [ "$(owner_of_db other)" = postgres ]
  q postgres postgres "ALTER ROLE postgres RESET lock_timeout" >/dev/null
  run real-own-super evse-ts --database other --take-ownership
  check "real ownership: refused for a superuser-owned database" grep -q "a superuser or system role" "$D/out"

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
  run real-create evse-ts --tenant symbioen --database evse:JOURNAL_DB --database manifest:MANIFEST_DB --create-missing --migration-role; collect
  check "real --create-missing: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real --create-missing: manifest owned by the migration role" [ "$(owner_of_db manifest)" = evse-ts_migrate ]
  check "real --create-missing: PUBLIC cannot connect to the new database" not can stranger manifest "SELECT 1"
  manifest_ok() { can evse-ts_migrate manifest "CREATE TABLE days (d date)" && can evse-ts manifest "INSERT INTO days VALUES (now())"; }
  check "real --create-missing: the app role uses a table the migration role made there" manifest_ok
  run real-default my-app --migration-role --migration-schema my-app.flyway; collect
  check "real default + migration role: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real default: my-app owns database my-app" [ "$(owner_of_db my-app)" = my-app ]
  check "real default: app role creates a table (as before)" can my-app my-app "CREATE TABLE t_app (x int)"
  check "real default: migration role cannot ALTER the app role's table (no membership)" not can my-app_migrate my-app "ALTER TABLE t_app ADD COLUMN y int"
  check "real default: migration role writes the app role's table (default privileges)" can my-app_migrate my-app "INSERT INTO t_app VALUES (1)"
  mig_ok() { can my-app_migrate my-app "CREATE TABLE flyway.history (x int)" && can my-app my-app "INSERT INTO flyway.history VALUES (1)"; }
  check "real default: app role uses the migration role's table in its schema" mig_ok
  check "real default: PUBLIC cannot connect" not can stranger my-app "SELECT 1"
  run real-adopt my-app --database my-app:APP_DB; collect
  check "real: the default path's app role is adopted in --database mode" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real: and marked" [ "$(q postgres postgres "SELECT shobj_description(oid, 'pg_authid') FROM pg_roles WHERE rolname='my-app'")" = infra-skills:app:my-app ]

  # -- a failing password statement is not logged with its text (P1-c)
  q postgres postgres "ALTER ROLE postgres SET lock_timeout = '1s'" >/dev/null
  hold postgres 'ALTER ROLE "evse-ts" CONNECTION LIMIT 20;' || fail "real P1-c: lock holder did not start"
  run real-fail-app evse-ts --tenant symbioen --database evse:JOURNAL_DB; collect
  release
  check "real P1-c, app role: the password statement failed (lock timeout)" [ "$RC" != 0 ]
  check "real P1-c, app role: the server logged the failure" grep -q "canceling statement due to lock timeout" "$PGDIR/log"
  check "real P1-c, app role: the client output holds no password" client_clean "$D/log.sql" "$D/out"
  check "real P1-c, app role: the server log holds no password of the run" log_clean "$D/log.sql"
  hold postgres 'ALTER ROLE "evse-ts_migrate" CONNECTION LIMIT 2;' || fail "real P1-c: lock holder did not start"
  run real-fail-mig evse-ts --tenant symbioen --database evse:JOURNAL_DB --migration-role; collect
  release
  check "real P1-c, migration role: the password statement failed" [ "$RC" != 0 ]
  check "real P1-c, migration role: the client output holds no password" client_clean "$D/log.sql" "$D/out"
  check "real P1-c, migration role: the server log holds no password of the run" log_clean "$D/log.sql"
  q postgres postgres "ALTER ROLE postgres RESET lock_timeout" >/dev/null
  run real-range evse-ts --tenant symbioen --database evse:JOURNAL_DB --connection-limit 99999999999
  check "real P1-c: an out-of-range limit is refused before any SQL" bash -c '[ "$1" != 0 ] && [ ! -s "$2" ]' _ "$RC" "$D/log.sql"

  # -- the server log: no password of a protected statement, in any of the runs above
  check "real log: protected passwords collected (sanity)" [ "$(sort -u "$PROTECTED" | grep -c .)" -ge 8 ]
  leaked=0
  while IFS= read -r p; do [[ -n "$p" ]] && grep -qF -- "$p" "$PGDIR/log" && leaked=$((leaked + 1)); done < <(sort -u "$PROTECTED")
  check "real log: none of the protected passwords is in the server log (log_statement=all, log_min_duration_statement=0, failures included)" [ "$leaked" = 0 ]
  default_leaks=$(grep -c "duration: .* statement: ALTER ROLE \"my-app\" WITH LOGIN PASSWORD" "$PGDIR/log" || true)
  echo "info  the default path's own ALTER ROLE ... PASSWORD (unchanged from origin/main) is in the log ${default_leaks} time(s) under log_min_duration_statement=0"
  cleanup; trap - EXIT
  (( failures > 0 )) || rm -rf "$PGDIR"
fi

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed (work dir: $WORK)"
  exit 1
fi
echo "all checks passed"
rm -rf "$WORK"
