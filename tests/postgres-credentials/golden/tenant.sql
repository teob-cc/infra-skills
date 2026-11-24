-- ### psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q -tA -F 
-- infra-skills:preflight
\set app_role 'evse-ts'
\set mig_role ''
\set app_marker 'infra-skills:app:evse-ts'
\set mig_marker 'infra-skills:migrate:evse-ts'
\set targets 'evse-ts'
\set owner 'evse-ts'
\set excluded ',cnpg_pooler_pgbouncer'
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
       coalesce(k.kind = 'app' AND EXISTS (SELECT FROM pg_database d WHERE d.datname = k.name AND d.datdba = r.oid), false),
       coalesce(r.oid::text, ''), coalesce(r.rolcanlogin, false),
       coalesce((SELECT string_agg(CASE WHEN m.member = r.oid THEN 'member of ' ELSE 'has member ' END
                                   || regexp_replace(g.rolname, '[[:cntrl:]]', '?', 'g'), ', ' ORDER BY g.rolname)
                   FROM pg_auth_members m JOIN pg_roles g ON g.oid = CASE WHEN m.member = r.oid THEN m.roleid ELSE m.member END
                  WHERE m.member = r.oid OR m.roleid = r.oid), ''),
       coalesce((SELECT pg_has_role(r.oid, o.oid, 'MEMBER') OR pg_has_role(o.oid, r.oid, 'MEMBER') FROM pg_roles o WHERE o.rolname = k.other), false)
  FROM (VALUES (1, 'app', :'app_role', :'app_marker', :'mig_role'), (2, 'migrate', :'mig_role', :'mig_marker', :'app_role')) k(ord, kind, name, marker, other)
  LEFT JOIN pg_roles r ON r.rolname = k.name
 WHERE k.name <> ''
 ORDER BY k.ord;
SELECT 'need', k, EXISTS (SELECT FROM pg_roles WHERE rolname = k) FROM unnest(string_to_array(:'need', ',')) k WHERE k <> '';
-- ### psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q
\set role 'evse-ts'
\set db 'evse-ts'
\set pw '<SCRAM>'
\set ro ''
BEGIN;
SET LOCAL lock_timeout = '5s';
LOCK TABLE pg_catalog.pg_authid IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE pg_catalog.pg_auth_members IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE pg_catalog.pg_database IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE pg_catalog.pg_shdescription IN SHARE ROW EXCLUSIVE MODE;
SELECT set_config('infra_skills.g_role', 'evse-ts', true) AS g_role, set_config('infra_skills.g_kind', 'app', true) AS g_kind,
       set_config('infra_skills.g_oid', '', true) AS g_oid, set_config('infra_skills.g_other', '', true) AS g_other,
       set_config('infra_skills.g_marker', 'infra-skills:app:evse-ts', true) AS g_marker \gset
DO $$
DECLARE
  nm text := current_setting('infra_skills.g_role');
  kind text := current_setting('infra_skills.g_kind');
  want text := current_setting('infra_skills.g_oid');
  other text := current_setting('infra_skills.g_other');
  mk text := current_setting('infra_skills.g_marker');
  r record;
  c text;
BEGIN
  SELECT oid, rolcanlogin, (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls) AS elevated
    INTO r FROM pg_roles WHERE rolname = nm;
  IF NOT FOUND THEN
    IF want <> '' THEN RAISE EXCEPTION 'infra-skills: role % was dropped after the preflight; nothing changed', nm; END IF;
    RETURN;
  END IF;
  IF want = '' THEN RAISE EXCEPTION 'infra-skills: role % was made by someone else after the preflight; nothing changed', nm; END IF;
  IF r.oid::text <> want THEN RAISE EXCEPTION 'infra-skills: role % was dropped and made again after the preflight; nothing changed', nm; END IF;
  IF r.elevated THEN
    RAISE EXCEPTION 'infra-skills: role % gained SUPERUSER, CREATEROLE, CREATEDB, REPLICATION or BYPASSRLS after the preflight; nothing changed', nm;
  END IF;
  IF EXISTS (SELECT FROM pg_roles g WHERE g.oid <> r.oid AND pg_has_role(r.oid, g.oid, 'MEMBER')
               AND (g.rolname ~ '^pg_' OR g.rolsuper OR g.rolcreaterole OR g.rolcreatedb OR g.rolreplication OR g.rolbypassrls)) THEN
    RAISE EXCEPTION 'infra-skills: role % joined a privileged or pg_* role after the preflight; nothing changed', nm;
  END IF;
  IF other <> '' AND EXISTS (SELECT FROM pg_roles o WHERE o.rolname = other
                               AND (pg_has_role(r.oid, o.oid, 'MEMBER') OR pg_has_role(o.oid, r.oid, 'MEMBER'))) THEN
    RAISE EXCEPTION 'infra-skills: roles % and % are members of one another (directly or through a group); nothing changed', nm, other;
  END IF;
  c := shobj_description(r.oid, 'pg_authid');
  IF c IS NOT DISTINCT FROM mk THEN RETURN; END IF;
  IF kind = 'app' AND c IS NULL AND r.rolcanlogin
     AND EXISTS (SELECT FROM pg_database d WHERE d.datname = nm AND d.datdba = r.oid)
     AND NOT EXISTS (SELECT FROM pg_auth_members m WHERE m.member = r.oid OR m.roleid = r.oid) THEN
    RETURN;
  END IF;
  RAISE EXCEPTION 'infra-skills: role % changed after the preflight (marker, LOGIN, owner of its database or memberships); nothing changed', nm;
END
$$;
SELECT format('CREATE ROLE %I LOGIN', :'role') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
SELECT format('COMMENT ON ROLE %I IS %L', :'role', 'infra-skills:app:evse-ts') WHERE shobj_description((SELECT oid FROM pg_roles WHERE rolname = :'role'), 'pg_authid') IS DISTINCT FROM 'infra-skills:app:evse-ts' \gexec
SET LOCAL log_statement = 'none';
ALTER ROLE :"role" WITH LOGIN PASSWORD :'pw' CONNECTION LIMIT 30;
COMMIT;
SELECT format('ALTER ROLE %I SET statement_timeout = %L', :'role', '60s') WHERE '60s' <> '' \gexec
SELECT format('ALTER ROLE %I SET idle_in_transaction_session_timeout = %L', :'role', '5min') WHERE '5min' <> '' \gexec
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
-- ### psql -U postgres -d postgres -tA
SELECT string_agg(datname, ' ' ORDER BY datname) FROM pg_database
 WHERE datallowconn AND NOT datistemplate AND datname NOT IN ('evse-ts', 'postgres') AND has_database_privilege('evse-ts', datname, 'CONNECT');
