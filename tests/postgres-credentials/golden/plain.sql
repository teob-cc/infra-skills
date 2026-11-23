-- ### psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q
\set role 'my-app'
\set db 'my-app'
\set pw '<PW>'
\set ro ''
SELECT format('CREATE ROLE %I LOGIN', :'role') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
BEGIN;
SET LOCAL log_statement = 'none';
ALTER ROLE :"role" WITH LOGIN PASSWORD :'pw' CONNECTION LIMIT 50;
COMMIT;
SELECT format('ALTER ROLE %I SET statement_timeout = %L', :'role', '') WHERE '' <> '' \gexec
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
