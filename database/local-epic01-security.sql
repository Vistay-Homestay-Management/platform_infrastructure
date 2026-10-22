\set ON_ERROR_STOP on

SELECT format('CREATE ROLE %I NOLOGIN', role_name)
FROM (VALUES
  ('vistay_authentication_owner'),
  ('vistay_user_owner'),
  ('vistay_notification_owner')
) AS owners(role_name)
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = role_name)
\gexec

SELECT format('CREATE ROLE %I LOGIN NOCREATEDB NOCREATEROLE NOREPLICATION', role_name)
FROM (VALUES
  ('vistay_authentication_migrator'), ('vistay_authentication_app'),
  ('vistay_user_migrator'), ('vistay_user_app'),
  ('vistay_notification_migrator'), ('vistay_notification_app')
) AS logins(role_name)
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = role_name)
\gexec

SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_authentication_migrator', :'authentication_migrator_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_authentication_app', :'authentication_app_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_user_migrator', :'user_migrator_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_user_app', :'user_app_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_notification_migrator', :'notification_migrator_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_notification_app', :'notification_app_password') \gexec

GRANT vistay_authentication_owner TO vistay_authentication_migrator;
GRANT vistay_user_owner TO vistay_user_migrator;
GRANT vistay_notification_owner TO vistay_notification_migrator;

ALTER DATABASE vistay_authentication_db OWNER TO vistay_authentication_owner;
ALTER DATABASE vistay_user_db OWNER TO vistay_user_owner;
ALTER DATABASE vistay_notification_db OWNER TO vistay_notification_owner;

REVOKE CONNECT ON DATABASE vistay_authentication_db FROM PUBLIC;
REVOKE CONNECT ON DATABASE vistay_user_db FROM PUBLIC;
REVOKE CONNECT ON DATABASE vistay_notification_db FROM PUBLIC;
GRANT CONNECT ON DATABASE vistay_authentication_db TO vistay_authentication_migrator, vistay_authentication_app;
GRANT CONNECT ON DATABASE vistay_user_db TO vistay_user_migrator, vistay_user_app;
GRANT CONNECT ON DATABASE vistay_notification_db TO vistay_notification_migrator, vistay_notification_app;

ALTER ROLE vistay_authentication_migrator IN DATABASE vistay_authentication_db SET role TO vistay_authentication_owner;
ALTER ROLE vistay_user_migrator IN DATABASE vistay_user_db SET role TO vistay_user_owner;
ALTER ROLE vistay_notification_migrator IN DATABASE vistay_notification_db SET role TO vistay_notification_owner;

\connect vistay_authentication_db
CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION vistay_authentication_owner;
ALTER SCHEMA app OWNER TO vistay_authentication_owner;
GRANT USAGE ON SCHEMA app TO vistay_authentication_app;
ALTER DEFAULT PRIVILEGES FOR ROLE vistay_authentication_owner IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO vistay_authentication_app;
ALTER DEFAULT PRIVILEGES FOR ROLE vistay_authentication_owner IN SCHEMA app
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO vistay_authentication_app;

\connect vistay_user_db
CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION vistay_user_owner;
ALTER SCHEMA app OWNER TO vistay_user_owner;
GRANT USAGE ON SCHEMA app TO vistay_user_app;
ALTER DEFAULT PRIVILEGES FOR ROLE vistay_user_owner IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO vistay_user_app;
ALTER DEFAULT PRIVILEGES FOR ROLE vistay_user_owner IN SCHEMA app
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO vistay_user_app;

\connect vistay_notification_db
CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION vistay_notification_owner;
ALTER SCHEMA app OWNER TO vistay_notification_owner;
GRANT USAGE ON SCHEMA app TO vistay_notification_app;
ALTER DEFAULT PRIVILEGES FOR ROLE vistay_notification_owner IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO vistay_notification_app;
ALTER DEFAULT PRIVILEGES FOR ROLE vistay_notification_owner IN SCHEMA app
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO vistay_notification_app;
