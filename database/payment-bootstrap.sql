\set ON_ERROR_STOP on

SELECT format('CREATE ROLE %I NOLOGIN', 'vistay_payment_owner')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vistay_payment_owner')
\gexec

SELECT format('CREATE ROLE %I LOGIN NOCREATEDB NOCREATEROLE NOREPLICATION', role_name)
FROM (VALUES ('vistay_payment_migrator'), ('vistay_payment_app')) AS roles(role_name)
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = role_name)
\gexec

SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_payment_migrator', :'payment_migrator_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_payment_app', :'payment_app_password') \gexec
GRANT vistay_payment_owner TO vistay_payment_migrator;

SELECT format('CREATE DATABASE %I OWNER %I', 'vistay_payment_db', 'vistay_payment_owner')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'vistay_payment_db')
\gexec

REVOKE CONNECT ON DATABASE vistay_payment_db FROM PUBLIC;
GRANT CONNECT ON DATABASE vistay_payment_db TO vistay_payment_migrator, vistay_payment_app;
ALTER ROLE vistay_payment_migrator IN DATABASE vistay_payment_db SET role TO vistay_payment_owner;
