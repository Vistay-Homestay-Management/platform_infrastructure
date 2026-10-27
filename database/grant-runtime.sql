\set ON_ERROR_STOP on

-- Required psql variables: owner_role and app_role.
SELECT format('SET ROLE %I', :'owner_role') \gexec
SELECT format('GRANT USAGE ON SCHEMA app, extensions TO %I', :'app_role') \gexec
SELECT format(
    'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO %I',
    :'app_role'
) \gexec
SELECT format(
    'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA app TO %I',
    :'app_role'
) \gexec
SELECT format(
    'REVOKE ALL ON TABLE app.flyway_schema_history FROM %I',
    :'app_role'
)
WHERE to_regclass('app.flyway_schema_history') IS NOT NULL
\gexec
SELECT format(
    'ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I',
    :'app_role'
) \gexec
SELECT format(
    'ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT USAGE, SELECT ON SEQUENCES TO %I',
    :'app_role'
) \gexec
RESET ROLE;
