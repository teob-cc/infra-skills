-- ### psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q -tA -F 
-- infra-skills:preflight
\set app_role 'app2'
\set mig_role ''
\set app_marker 'infra-skills:app:app2'
\set mig_marker 'infra-skills:migrate:app2'
\set targets 'app2'
\set owner 'app2'
\set excluded ',claude_ro,cnpg_pooler_pgbouncer'
\set need ''
SET client_min_messages = warning;
SELECT 'role', k.kind, k.name, (r.oid IS NOT NULL),
       coalesce(shobj_description(r.oid, 'pg_authid') = k.marker, false),
       coalesce(regexp_replace(shobj_description(r.oid, 'pg_authid'), '[[:cntrl:]]', '?', 'g'), ''),
       coalesce(concat_ws(',', CASE WHEN r.rolsuper THEN 'SUPERUSER' END, CASE WHEN r.rolcreaterole THEN 'CREATEROLE' END,
                CASE WHEN r.rolcreatedb THEN 'CREATEDB' END, CASE WHEN r.rolreplication THEN 'REPLICATION' END,
                CASE WHEN r.rolbypassrls THEN 'BYPASSRLS' END), ''),
       coalesce((SELECT string_agg(regexp_replace(g.rolname, '[[:cntrl:]]', '?', 'g'), ',' ORDER BY g.rolname)
                   FROM pg_roles g WHERE g.oid <> r.oid AND pg_has_role(r.oid, g.oid, 'MEMBER')
                    AND (g.rolname ~ '^pg_' OR g.rolsuper OR g.rolcreaterole OR g.rolcreatedb OR g.rolreplication OR g.rolbypassrls)), ''),
       coalesce(k.kind = 'app' AND EXISTS (SELECT FROM pg_database d WHERE d.datname = k.name AND d.datdba = r.oid), false)
  FROM (VALUES (1, 'app', :'app_role', :'app_marker'), (2, 'migrate', :'mig_role', :'mig_marker')) k(ord, kind, name, marker)
  LEFT JOIN pg_roles r ON r.rolname = k.name
 WHERE k.name <> ''
 ORDER BY k.ord;
SELECT 'need', k, EXISTS (SELECT FROM pg_roles WHERE rolname = k) FROM unnest(string_to_array(:'need', ',')) k WHERE k <> '';
-- ### psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q
\set role 'app2'
\set db 'app2'
\set pw '<SCRAM>'
\set ro 'claude_ro'
SELECT format('CREATE ROLE %I LOGIN', :'role') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
SELECT format('COMMENT ON ROLE %I IS %L', :'role', 'infra-skills:app:app2') WHERE shobj_description((SELECT oid FROM pg_roles WHERE rolname = :'role'), 'pg_authid') IS DISTINCT FROM 'infra-skills:app:app2' \gexec
BEGIN;
SET LOCAL log_statement = 'none';
ALTER ROLE :"role" WITH LOGIN PASSWORD :'pw' CONNECTION LIMIT 50;
COMMIT;
SELECT format('ALTER ROLE %I SET statement_timeout = %L', :'role', '30s') WHERE '30s' <> '' \gexec
SELECT format('ALTER ROLE %I SET idle_in_transaction_session_timeout = %L', :'role', '') WHERE '' <> '' \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
REVOKE CONNECT, TEMPORARY ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"db" TO :"role";
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db', :'ro') WHERE :'ro' <> '' AND EXISTS (SELECT FROM pg_roles WHERE rolname = :'ro') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO cnpg_pooler_pgbouncer', :'db') WHERE EXISTS (SELECT FROM pg_roles WHERE rolname = 'cnpg_pooler_pgbouncer') \gexec
SELECT 'WARN role ' || rolname || ' has ' || concat_ws(', ', CASE WHEN rolsuper THEN 'SUPERUSER' END, CASE WHEN rolcreaterole THEN 'CREATEROLE' END,
       CASE WHEN rolcreatedb THEN 'CREATEDB' END, CASE WHEN rolreplication THEN 'REPLICATION' END, CASE WHEN rolbypassrls THEN 'BYPASSRLS' END)
  FROM pg_roles WHERE rolname = :'role' AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls);
\c :"db"
GRANT CREATE ON SCHEMA public TO :"role";
