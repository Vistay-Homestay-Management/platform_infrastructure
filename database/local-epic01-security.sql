\set ON_ERROR_STOP on

SELECT format('CREATE ROLE %I NOLOGIN', role_name)
FROM (VALUES
  ('vistay_authentication_owner'),
  ('vistay_user_owner'),
  ('vistay_notification_owner'),
  ('vistay_finance_owner'),
  ('vistay_payment_owner')
) AS owners(role_name)
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = role_name)
\gexec

SELECT format('CREATE ROLE %I LOGIN NOCREATEDB NOCREATEROLE NOREPLICATION', role_name)
FROM (VALUES
  ('vistay_authentication_migrator'), ('vistay_authentication_app'),
  ('vistay_user_migrator'), ('vistay_user_app'),
  ('vistay_notification_migrator'), ('vistay_notification_app'),
  ('vistay_finance_migrator'), ('vistay_finance_app'),
  ('vistay_payment_migrator'), ('vistay_payment_app')
) AS logins(role_name)
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = role_name)
\gexec

SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_authentication_migrator', :'authentication_migrator_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_authentication_app', :'authentication_app_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_user_migrator', :'user_migrator_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_user_app', :'user_app_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_notification_migrator', :'notification_migrator_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_notification_app', :'notification_app_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_finance_migrator', :'finance_migrator_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_finance_app', :'finance_app_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_payment_migrator', :'payment_migrator_password') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', 'vistay_payment_app', :'payment_app_password') \gexec

GRANT vistay_authentication_owner TO vistay_authentication_migrator;
GRANT vistay_user_owner TO vistay_user_migrator;
GRANT vistay_notification_owner TO vistay_notification_migrator;
GRANT vistay_finance_owner TO vistay_finance_migrator;
GRANT vistay_payment_owner TO vistay_payment_migrator;

ALTER DATABASE vistay_authentication_db OWNER TO vistay_authentication_owner;
ALTER DATABASE vistay_user_db OWNER TO vistay_user_owner;
ALTER DATABASE vistay_notification_db OWNER TO vistay_notification_owner;
ALTER DATABASE vistay_finance_db OWNER TO vistay_finance_owner;
ALTER DATABASE vistay_payment_db OWNER TO vistay_payment_owner;

REVOKE CONNECT ON DATABASE vistay_authentication_db FROM PUBLIC;
REVOKE CONNECT ON DATABASE vistay_user_db FROM PUBLIC;
REVOKE CONNECT ON DATABASE vistay_notification_db FROM PUBLIC;
REVOKE CONNECT ON DATABASE vistay_finance_db FROM PUBLIC;
REVOKE CONNECT ON DATABASE vistay_payment_db FROM PUBLIC;
GRANT CONNECT ON DATABASE vistay_authentication_db TO vistay_authentication_migrator, vistay_authentication_app;
GRANT CONNECT ON DATABASE vistay_user_db TO vistay_user_migrator, vistay_user_app;
GRANT CONNECT ON DATABASE vistay_notification_db TO vistay_notification_migrator, vistay_notification_app;
GRANT CONNECT ON DATABASE vistay_finance_db TO vistay_finance_migrator, vistay_finance_app;
GRANT CONNECT ON DATABASE vistay_payment_db TO vistay_payment_migrator, vistay_payment_app;

ALTER ROLE vistay_authentication_migrator IN DATABASE vistay_authentication_db SET role TO vistay_authentication_owner;
ALTER ROLE vistay_user_migrator IN DATABASE vistay_user_db SET role TO vistay_user_owner;
ALTER ROLE vistay_notification_migrator IN DATABASE vistay_notification_db SET role TO vistay_notification_owner;
ALTER ROLE vistay_finance_migrator IN DATABASE vistay_finance_db SET role TO vistay_finance_owner;
ALTER ROLE vistay_payment_migrator IN DATABASE vistay_payment_db SET role TO vistay_payment_owner;

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

\connect vistay_finance_db
CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION vistay_finance_owner;
ALTER SCHEMA app OWNER TO vistay_finance_owner;
GRANT USAGE ON SCHEMA app TO vistay_finance_app;
ALTER DEFAULT PRIVILEGES FOR ROLE vistay_finance_owner IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO vistay_finance_app;
ALTER DEFAULT PRIVILEGES FOR ROLE vistay_finance_owner IN SCHEMA app
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO vistay_finance_app;

\connect vistay_payment_db
CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION vistay_payment_owner;
ALTER SCHEMA app OWNER TO vistay_payment_owner;
GRANT USAGE ON SCHEMA app TO vistay_payment_app;
ALTER DEFAULT PRIVILEGES FOR ROLE vistay_payment_owner IN SCHEMA app
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO vistay_payment_app;
ALTER DEFAULT PRIVILEGES FOR ROLE vistay_payment_owner IN SCHEMA app
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO vistay_payment_app;
