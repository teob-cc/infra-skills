#!/usr/bin/env bash
# Checks `tools/k3s/postgres.sh <env> --provision-credentials <app-id> ...` (INFRA-243) without a
# cluster: kubectl, helm and openssl are stand-ins (stubs/), the environment is a fake (envs/), and
# psql runs only as the stub's canned answers, or, with --real-postgres, against a throwaway local
# server (initdb in a temp directory, unix socket only, stopped at exit).
#
# What it checks:
#   1. the default path is unchanged: SQL, kubectl calls, Secret and Pooler equal the golden files
#      recorded from origin/main 1850e9c (golden/), for a plain app, a tenant with a Pooler and a
#      hyphenated app id, and an app with PG_READONLY_ROLE;
#   2. --database <name>[:<PREFIX>] (grant mode): no database is created, the role gets CONNECT,
#      schema, table and sequence rights and default privileges on each, PUBLIC's CONNECT is
#      revoked, the Secret holds <PREFIX>_HOST/PORT/DATABASE/USERNAME/PASSWORD per database (the
#      Pooler host with --pooler, POSTGRES_* without a prefix); bad specs, a missing database and
#      --create-missing; --take-ownership and its refusals;
#   3. --migration-role: the second role (no statement_timeout, own connection limit, member of
#      the app role), default privileges for it, and its Secret <app-id>-db-migrate;
#   4. --connection-limit: the role's CONNECTION LIMIT and the Pooler's pool size;
#   5. re-runs: the same SQL again; --keep-password keeps the password and makes no new one;
#   6. under bash -x no password reaches stdout or stderr, and none is ever on kubectl's argv;
#   7. (--real-postgres) the same runs against a real server: the rights, timeouts, default
#      privileges, ownership move, refusals and re-runs behave as documented.
#
# Usage: tests/postgres-credentials/run.sh [--real-postgres]   (needs bash, jq, yq; --real-postgres
#        also initdb, pg_ctl and psql on PATH)
# The bash -c snippets below get their values as arguments; $1 in single quotes is meant.
# shellcheck disable=SC2016
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/tools/k3s/postgres.sh"
REAL=false
[[ "${1:-}" == --real-postgres ]] && REAL=true
for t in jq yq; do command -v "$t" >/dev/null 2>&1 || { echo "Missing: $t" >&2; exit 1; }; done
WORK="$(mktemp -d -t pg-credentials-test-XXXX)"
export KUBECONFIG=/dev/null PATH="$HERE/stubs:$PATH"
unset PG_READONLY_ROLE PG_TENANT_CONNECTION_LIMIT PG_APP_CONNECTION_LIMIT PG_MIGRATION_CONNECTION_LIMIT \
      STUB_DB_OWNERS STUB_OPEN_DBS STUB_PGHOST STUB_PGPORT STUB_NO_NS APP_NAMESPACE
PW_RE='Pw0Stub[0-9]+AbCdEfGhIjKlMn\+/='

failures=0
ok() { echo "ok    $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { # <description> <command...>
  local d="$1"; shift
  if "$@"; then ok "$d"; else fail "$d"; fi
}
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }

# run <name> <args...>: postgres.sh fake --provision-credentials <args...> in a fresh copy of envs/,
# its own stub log; rc in RC, the run's directory in D. PRE_RUN=<dir> reuses a directory (re-runs).
run() {
  local name="$1"; shift
  D="${PRE_RUN:-$WORK/$name}"
  if [[ -z "${PRE_RUN:-}" ]]; then mkdir -p "$D"; cp -R "$HERE/envs/." "$D/"; fi
  : > "$D/log"; rm -rf "$D/log.sql" "$D/log.applied"
  RC=0
  STUB_LOG="$D/log" INFRA_ENVS_ROOT="$D" ${TRACE:-} "$SCRIPT" fake --provision-credentials "$@" >"$D/out" 2>&1 || RC=$?
  touch "$D/log.sql"
}
norm() { sed -E -e "s#$D#<WORK>#g" -e "s#$PW_RE#<PW>#g"; }
secret_json() { yq -o=json '.' "$1" | jq -S .; }
key() { # <secret file> <key>
  yq -r ".stringData.$2 // \"\"" "$1"
}

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
      check "$name: applied $(basename "$f") equals golden" diff <(jq -S . "$f" | norm) "$HERE/golden/$name.applied.$(basename "$f").json"
    else
      check "$name: applied $(basename "$f") equals golden" diff <(secret_json "$f" | norm) "$HERE/golden/$name.applied.$(basename "$f").json"
    fi
  done
}
golden plain my-app
golden tenant evse-ts --tenant symbioen --pooler --connection-limit 30
PG_READONLY_ROLE=claude_ro golden ro app2 --pooler --statement-timeout 30s
check "tenant: secret file is mode 600" [ -n "$(find "$WORK/golden-tenant/fake/secrets.plain/evse-ts-db.secret.yaml" -perm 600)" ]

# --- 2. existing databases ----------------------------------------------------------------
echo "== 2. --database <name>[:<PREFIX>]"
export STUB_DB_OWNERS=$'evse|evse_ts|f||0\nevse_ts|evse_ts|f||0'
run grant evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB
check "grant: exit 0" [ "$RC" = 0 ]
sql="$(cat "$D/log.sql")"; s="$D/fake/secrets.plain/evse-ts-db.secret.yaml"
check "grant: no CREATE DATABASE" lacks "$sql" "CREATE DATABASE"
check "grant: no REASSIGN OWNED, no ALTER DATABASE OWNER" bash -c '[[ "$1" != *"REASSIGN OWNED"* && "$1" != *"ALTER DATABASE"* ]]' _ "$sql"
check "grant: the owners query names both databases" contains "$sql" "\\set targets 'evse evse_ts'"
check "grant: PUBLIC's CONNECT revoked on each (2)" [ "$(grep -c 'REVOKE CONNECT, TEMPORARY ON DATABASE :"db" FROM PUBLIC' "$D/log.sql")" = 2 ]
check "grant: owner gets CONNECT before the revoke" contains "$sql" "GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', datname, pg_get_userbyid(datdba)"
check "grant: schema USAGE, CREATE" contains "$sql" "GRANT USAGE, CREATE ON SCHEMA %I TO %I"
check "grant: table rights" contains "$sql" "GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA"
check "grant: sequence rights" contains "$sql" "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA"
check "grant: default privileges for the owners" contains "$sql" "ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO %I"
check "grant: tenant role keeps 60s" grep -qF "'60s') WHERE" "$D/log.sql"
check "grant: tenant role keeps 5min idle in transaction" grep -qF "'5min') WHERE" "$D/log.sql"
check "grant: tenant -> no read-only role" contains "$sql" "\\set ro ''"
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

STUB_DB_OWNERS='legacy_db|old_app|f||0' run grant-noprefix my-app --database legacy_db
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
  check "$d: no SQL written" bash -c '! grep -q "ALTER ROLE" "$1"' _ "$D/log.sql"
  check "$d: no Secret written" bash -c '[ ! -e "$1/fake/secrets.plain" ] || [ -z "$(ls "$1/fake/secrets.plain")" ]' _ "$D"
}
bad "two databases without a prefix" "only one database may go without a prefix" x --database evse --database evse_ts
bad "a prefix used twice" "key prefix A_DB is already used" x --database evse:A_DB --database evse_ts:A_DB
bad "a lower-case prefix" "the key prefix must be upper case" x --database evse:journal
bad "an empty prefix" "the key prefix must be upper case" x --database evse:
bad "a database named twice" "--database evse is named twice" x --database evse:A --database evse:B
bad "a database name with a quote" "is not a database name" x "--database" "ev'se"
bad "--take-ownership without --database" "--take-ownership and --create-missing go with --database" x --take-ownership
bad "--create-missing without --database" "--take-ownership and --create-missing go with --database" x --create-missing
STUB_DB_OWNERS='evse|evse_ts|f||0' bad "a missing database" "These databases do not exist: manifest" x --database evse:A --database manifest:B

STUB_DB_OWNERS='evse|evse_ts|f||0' run create-missing evse-ts --database evse:JOURNAL_DB --database manifest:MANIFEST_DB --create-missing
check "--create-missing: exit 0" [ "$RC" = 0 ]
check "--create-missing: creates only manifest" [ "$(grep -c "CREATE DATABASE %I OWNER %I', :'db', :'owner'" "$D/log.sql")" = 1 ]
check "--create-missing: owned by the app role" grep -q "^\\\\set owner 'evse-ts'" "$D/log.sql"
check "--create-missing: extensions only in manifest" bash -c 'grep "CREATE EXTENSION" "$1" | grep -qv -- "-d manifest" && exit 1; grep -q -- "-d manifest -qc CREATE EXTENSION" "$1"' _ "$D/log"

export STUB_DB_OWNERS=$'evse|evse_ts|f||0\nevse_ts|evse_ts|f||0'
run own evse-ts --database evse:JOURNAL_DB --database evse_ts:STATE_DB --take-ownership --migration-role
check "--take-ownership: exit 0" [ "$RC" = 0 ]
check "--take-ownership: REASSIGN OWNED BY the old owner to the migration role (2)" \
  [ "$(grep -c 'REASSIGN OWNED BY :"old_owner" TO :"owner"' "$D/log.sql")" = 2 ]
check "--take-ownership: new owner is evse-ts_migrate" grep -q "^\\\\set owner 'evse-ts_migrate'" "$D/log.sql"
check "--take-ownership: old owner evse_ts" grep -q "^\\\\set old_owner 'evse_ts'" "$D/log.sql"
check "--take-ownership: ALTER DATABASE OWNER" grep -q 'ALTER DATABASE :"db" OWNER TO :"owner"' "$D/log.sql"
check "--take-ownership: the migration role exists before the move" \
  bash -c '[ "$(grep -n "CREATE ROLE %I LOGIN., :.mrole" "$1" | head -1 | cut -d: -f1)" -lt "$(grep -n REASSIGN "$1" | head -1 | cut -d: -f1)" ]' _ "$D/log.sql"
STUB_DB_OWNERS='evse|evse-ts_migrate|f||0' run own-again evse-ts --database evse:JOURNAL_DB --take-ownership --migration-role
check "--take-ownership, already owned: no REASSIGN" bash -c '! grep -q REASSIGN "$1"' _ "$D/log.sql"
STUB_DB_OWNERS='evse|postgres|t||0' bad "--take-ownership from a superuser" "a superuser or system role" x --database evse --take-ownership
STUB_DB_OWNERS='evse|evse_ts|f|other_db|0' bad "--take-ownership, owner has another database" "also owns: other_db" x --database evse --take-ownership
STUB_DB_OWNERS='evse|evse_ts|f||1' bad "--take-ownership, owner has a tablespace" "owns a tablespace" x --database evse --take-ownership

# --- 3. migration role --------------------------------------------------------------------
echo "== 3. --migration-role"
run mig evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role
check "migration: exit 0" [ "$RC" = 0 ]
sql="$(cat "$D/log.sql")"; s="$D/fake/secrets.plain/evse-ts-db.secret.yaml"; m="$D/fake/secrets.plain/evse-ts-db-migrate.secret.yaml"
check "migration: role evse-ts_migrate" contains "$sql" "\\set mrole 'evse-ts_migrate'"
check "migration: connection limit 2" contains "$sql" "ALTER ROLE :\"mrole\" WITH LOGIN PASSWORD :'mpw' CONNECTION LIMIT 2;"
check "migration: password statement with log_statement none" bash -c 'grep -B1 "PASSWORD :.mpw." "$1" | grep -q "SET LOCAL log_statement = .none."' _ "$D/log.sql"
check "migration: statement_timeout 0" contains "$sql" 'ALTER ROLE :"mrole" SET statement_timeout = 0;'
check "migration: idle_in_transaction_session_timeout 0" contains "$sql" 'ALTER ROLE :"mrole" SET idle_in_transaction_session_timeout = 0;'
check "migration: member of the app role" contains "$sql" "GRANT %I TO %I', :'role', :'mrole') WHERE NOT pg_has_role"
check "migration: CONNECT on each database (2)" [ "$(grep -c 'GRANT CONNECT, TEMPORARY ON DATABASE :"db" TO :"mrole"' "$D/log.sql")" = 2 ]
check "migration: default privileges for it, tables (2)" [ "$(grep -c 'ALTER DEFAULT PRIVILEGES FOR ROLE :"mrole" GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO :"role"' "$D/log.sql")" = 2 ]
check "migration: default privileges for it, sequences (2)" [ "$(grep -c 'ALTER DEFAULT PRIVILEGES FOR ROLE :"mrole" GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"role"' "$D/log.sql")" = 2 ]
check "migration: the app role keeps 60s" contains "$sql" "SET statement_timeout = %L', :'role', '60s')"
check "migration: Secret evse-ts-db-migrate" [ "$(yq -r '.metadata.name + "/" + .metadata.namespace' "$m")" = evse-ts-db-migrate/symbioen ]
check "migration: same keys as the app Secret" diff <(yq -r '.stringData | keys | .[]' "$s") <(yq -r '.stringData | keys | .[]' "$m")
check "migration: JOURNAL_DB_USERNAME evse-ts_migrate" [ "$(key "$m" JOURNAL_DB_USERNAME)" = evse-ts_migrate ]
check "migration: Pooler host" [ "$(key "$m" STATE_DB_HOST)" = pooler-evse-ts.postgres.svc.cluster.local ]
check "migration: its own password" bash -c '[[ -n "$1" && -n "$2" && "$1" != "$2" ]]' _ "$(key "$s" JOURNAL_DB_PASSWORD)" "$(key "$m" JOURNAL_DB_PASSWORD)"
check "migration: both Secrets applied" bash -c '[ -f "$1/evse-ts-db.secret.yaml" ] && [ -f "$1/evse-ts-db-migrate.secret.yaml" ]' _ "$D/log.applied"

run mig-named my-app --migration-role my_app_ddl --migration-connection-limit 3
check "migration, default path: exit 0" [ "$RC" = 0 ]
check "migration, default path: the default SQL is unchanged (first session = golden)" \
  diff <(awk '/^-- ### /{n++} n==1' "$D/log.sql" | norm) <(awk '/^-- ### /{n++} n==1' "$HERE/golden/plain.sql")
check "migration, default path: named role, limit 3" contains "$(cat "$D/log.sql")" "\\set mrole 'my_app_ddl'"
check "migration, default path: limit 3" grep -q "CONNECTION LIMIT 3;" "$D/log.sql"
check "migration, default path: POSTGRES_USERNAME my_app_ddl" [ "$(key "$D/fake/secrets.plain/my-app-db-migrate.secret.yaml" POSTGRES_USERNAME)" = my_app_ddl ]
check "migration, default path: POSTGRES_DATABASE my-app" [ "$(key "$D/fake/secrets.plain/my-app-db-migrate.secret.yaml" POSTGRES_DATABASE)" = my-app ]
bad "a migration role named like the app role" "Invalid migration role name" my-app --migration-role my-app
bad "--migration-connection-limit without --migration-role" "--migration-connection-limit goes with --migration-role" x --migration-connection-limit 3
out="$(STUB_LOG="$WORK/p.log" INFRA_ENVS_ROOT="$WORK/golden-plain" "$SCRIPT" fake --migration-role 2>&1 || true)"
check "--migration-role alone: refused before any call" contains "$out" "go with --provision-credentials"

# --- 4. connection limit ------------------------------------------------------------------
echo "== 4. --connection-limit"
run limit evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --connection-limit 40
check "limit 40: role" grep -q "CONNECTION LIMIT 40;" "$D/log.sql"
check "limit 40: Pooler pool size" [ "$(jq -r '.spec.pgbouncer.parameters.default_pool_size' "$D/log.applied/stdin-0.json")" = 40 ]
run limit-default evse-ts --tenant symbioen --database evse:JOURNAL_DB
check "tenant default: 20" grep -q "CONNECTION LIMIT 20;" "$D/log.sql"
bad "a non-numeric limit" "connection limit must be a number" x --connection-limit lots --database evse

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
kept_pw="$(key "$D/fake/secrets.plain/evse-ts-db.secret.yaml" JOURNAL_DB_PASSWORD)"
kept_mpw="$(key "$D/fake/secrets.plain/evse-ts-db-migrate.secret.yaml" JOURNAL_DB_PASSWORD)"
PRE_RUN="$D" run rerun evse-ts --tenant symbioen --pooler --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role --keep-password
check "--keep-password: exit 0" [ "$RC" = 0 ]
check "--keep-password: no new password made" bash -c '! grep -q "^openssl" "$1"' _ "$D/log"
check "--keep-password: app password kept" [ "$kept_pw" = "$(key "$D/fake/secrets.plain/evse-ts-db.secret.yaml" STATE_DB_PASSWORD)" ]
check "--keep-password: migration password kept" [ "$kept_mpw" = "$(key "$D/fake/secrets.plain/evse-ts-db-migrate.secret.yaml" STATE_DB_PASSWORD)" ]
check "--keep-password: the SQL sets the kept one" grep -qF "\\set pw '$kept_pw'" "$D/log.sql"
check "--keep-password: the password is not in the output" bash -c '! grep -qF -e "$2" -e "$3" "$1"' _ "$D/out" "$kept_pw" "$kept_mpw"
[[ "$first_mpw" != "$kept_mpw" ]] || fail "re-run: migration password changed between the first two runs"
bad "--keep-password with no Secret file" "holds no usable *_PASSWORD" x --database evse --keep-password

# --- 6. no secret under bash -x -----------------------------------------------------------
echo "== 6. bash -x"
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

# --- 7. a real server ---------------------------------------------------------------------
if $REAL; then
  echo "== 7. real Postgres (local, unix socket only)"
  for t in initdb pg_ctl psql; do command -v "$t" >/dev/null 2>&1 || { echo "Missing: $t" >&2; exit 1; }; done
  PGDIR="$(mktemp -d -t pgc-XXXX)"; export STUB_PGHOST="$PGDIR" STUB_PGPORT=54329
  initdb -D "$PGDIR/data" -U postgres --auth=trust >/dev/null
  pg_ctl -D "$PGDIR/data" -l "$PGDIR/log" -w -o "-c listen_addresses='' -k $PGDIR -p $STUB_PGPORT" start >/dev/null
  trap 'pg_ctl -D "$PGDIR/data" -m immediate stop >/dev/null 2>&1 || true' EXIT
  q() { # <user> <db> <sql>: one value
    psql -h "$PGDIR" -p "$STUB_PGPORT" -U "$1" -d "$2" -XtAq -v ON_ERROR_STOP=1 -c "$3" 2>&1
  }
  can() { q "$@" >/dev/null 2>&1; }
  not() { ! "$@"; }
  # Fixture: the Scala-era owner evse_ts owns the journal (evse) and the read model (evse_ts);
  # an unrelated database other stays as it is.
  psql -h "$PGDIR" -p "$STUB_PGPORT" -U postgres -d postgres -Xq -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE evse_ts LOGIN;
CREATE ROLE stranger LOGIN;
CREATE DATABASE evse OWNER evse_ts;
CREATE DATABASE evse_ts OWNER evse_ts;
CREATE DATABASE other;
\c evse evse_ts
CREATE SCHEMA journal;
CREATE TABLE journal.events (ordering bigserial PRIMARY KEY, payload text);
INSERT INTO journal.events (payload) VALUES ('a');
\c evse_ts evse_ts
CREATE TABLE public.station_view (id int PRIMARY KEY);
SQL
  args=(evse-ts --tenant symbioen --database evse:JOURNAL_DB --database evse_ts:STATE_DB --migration-role)
  run real-grant "${args[@]}"
  check "real grant: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real grant: evse still owned by evse_ts" [ "$(q postgres postgres "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='evse'")" = evse_ts ]
  check "real grant: app role reads the journal" [ "$(q evse-ts evse 'SELECT count(*) FROM journal.events')" = 1 ]
  check "real grant: app role writes the journal (sequence too)" can evse-ts evse "INSERT INTO journal.events (payload) VALUES ('b')"
  check "real grant: app role writes the read model" can evse-ts evse_ts "INSERT INTO station_view VALUES (1)"
  check "real grant: app role statement_timeout 60s" [ "$(q evse-ts evse 'SHOW statement_timeout')" = 1min ]
  check "real grant: app role idle_in_transaction 5min" [ "$(q evse-ts evse 'SHOW idle_in_transaction_session_timeout')" = 5min ]
  check "real grant: app role connection limit 20" [ "$(q postgres postgres "SELECT rolconnlimit FROM pg_roles WHERE rolname='evse-ts'")" = 20 ]
  check "real grant: migration role statement_timeout 0" [ "$(q evse-ts_migrate evse 'SHOW statement_timeout')" = 0 ]
  check "real grant: migration role connection limit 2" [ "$(q postgres postgres "SELECT rolconnlimit FROM pg_roles WHERE rolname='evse-ts_migrate'")" = 2 ]
  check "real grant: PUBLIC can no longer connect to evse" not can stranger evse "SELECT 1"
  check "real grant: other keeps PUBLIC's CONNECT (untouched)" can stranger other "SELECT 1"
  check "real grant: the tenant warning names other" grep -q "may still CONNECT to: other" "$D/out"
  check "real grant: migration role creates a table" can evse-ts_migrate evse "CREATE TABLE journal.archive_manifest (day date PRIMARY KEY, n bigserial)"
  check "real grant: app role writes the migration role's table (default privileges)" \
    can evse-ts evse "INSERT INTO journal.archive_manifest (day) VALUES ('2026-11-23')"
  check "real grant: app role cannot ALTER the migration role's table" not can evse-ts evse "ALTER TABLE journal.archive_manifest ADD COLUMN x int"
  later_ok() { can evse_ts evse "CREATE TABLE journal.later (x int)" && can evse-ts evse "INSERT INTO journal.later VALUES (1)"; }
  check "real grant: a table the old owner adds later is the app role's too (default privileges)" later_ok
  check "real grant: migration role cannot ALTER the old owner's table (grant mode)" \
    not can evse-ts_migrate evse "ALTER TABLE journal.events ADD COLUMN y int"
  acl() { q postgres "$1" "SELECT string_agg(c.relname || '=' || coalesce(c.relacl::text, ''), ' ' ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname IN ('journal','public')" ; q postgres "$1" "SELECT string_agg(defaclrole::regrole::text || ':' || defaclobjtype || ':' || defaclacl::text, ' ' ORDER BY 1) FROM pg_default_acl"; q postgres postgres "SELECT datacl::text FROM pg_database WHERE datname = '$1'"; }
  before="$(acl evse; acl evse_ts)"
  PRE_RUN="$D" run real-grant "${args[@]}" --keep-password
  check "real re-run: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real re-run: rights unchanged" [ "$before" = "$(acl evse; acl evse_ts)" ]
  check "real re-run: one membership" [ "$(q postgres postgres "SELECT count(*) FROM pg_auth_members WHERE member = 'evse-ts_migrate'::regrole")" = 1 ]
  check "real re-run: the role has a SCRAM verifier" \
    [ "$(q postgres postgres "SELECT left(rolpassword, 13) FROM pg_authid WHERE rolname='evse-ts'")" = SCRAM-SHA-256 ]

  # Ownership: refused while evse_ts also owns evse_ts but only evse is named; then both.
  run real-own-refused evse-ts --database evse:JOURNAL_DB --take-ownership --migration-role
  check "real ownership: refused when the owner has another database" grep -q "also owns: evse_ts" "$D/out"
  check "real ownership: refused -> evse still owned by evse_ts" [ "$(q postgres postgres "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='evse'")" = evse_ts ]
  run real-own evse-ts --database evse:JOURNAL_DB --database evse_ts:STATE_DB --take-ownership --migration-role
  check "real ownership: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real ownership: databases owned by evse-ts_migrate" \
    [ "$(q postgres postgres "SELECT string_agg(DISTINCT pg_get_userbyid(datdba), ',') FROM pg_database WHERE datname IN ('evse','evse_ts')")" = evse-ts_migrate ]
  check "real ownership: tables owned by evse-ts_migrate" \
    [ "$(q postgres evse "SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname='journal'")" = evse-ts_migrate ]
  check "real ownership: migration role can ALTER the journal now" can evse-ts_migrate evse "ALTER TABLE journal.events ADD COLUMN y int"
  check "real ownership: app role still writes it" can evse-ts evse "INSERT INTO journal.events (payload) VALUES ('c')"
  check "real ownership: other untouched" [ "$(q postgres postgres "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='other'")" = postgres ]
  run real-own-super evse-ts --database other --take-ownership
  check "real ownership: refused for a superuser-owned database" grep -q "a superuser or system role" "$D/out"

  # --create-missing, and the default path with a migration role.
  run real-create evse-ts --tenant symbioen --database evse:JOURNAL_DB --database manifest:MANIFEST_DB --create-missing --migration-role
  check "real --create-missing: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real --create-missing: manifest owned by the migration role" \
    [ "$(q postgres postgres "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='manifest'")" = evse-ts_migrate ]
  manifest_ok() { can evse-ts_migrate manifest "CREATE TABLE days (d date)" && can evse-ts manifest "INSERT INTO days VALUES (now())"; }
  check "real --create-missing: the app role uses a table the migration role made there" manifest_ok
  run real-default my-app --migration-role
  check "real default + migration role: exit 0" [ "$RC" = 0 ] || sed 's/^/      /' "$D/out"
  check "real default: my-app owns database my-app" [ "$(q postgres postgres "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='my-app'")" = my-app ]
  check "real default: app role creates a table (as before)" can my-app my-app "CREATE TABLE t_app (x int)"
  check "real default: migration role can ALTER the app role's table (membership)" can my-app_migrate my-app "ALTER TABLE t_app ADD COLUMN y int"
  mig_ok() { can my-app_migrate my-app "CREATE TABLE t_mig (x int)" && can my-app my-app "INSERT INTO t_mig VALUES (1)"; }
  check "real default: app role uses the migration role's table" mig_ok
  check "real default: PUBLIC cannot connect" not can stranger my-app "SELECT 1"
  pg_ctl -D "$PGDIR/data" -m fast stop >/dev/null; trap - EXIT
fi

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed (work dir: $WORK)"
  exit 1
fi
echo "all checks passed"
rm -rf "$WORK"
