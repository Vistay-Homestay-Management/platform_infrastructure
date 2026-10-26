\set ON_ERROR_STOP on

-- Password values are supplied as psql variables by the provisioning script.
-- No credential is stored in source control.
SELECT format('CREATE ROLE %I NOLOGIN', role_name)
FROM (VALUES
    ('vistay_authentication_owner'), ('vistay_user_owner'),
    ('vistay_property_owner'), ('vistay_booking_owner'),
    ('vistay_finance_owner'), ('vistay_operations_owner'),
    ('vistay_ota_owner'), ('vistay_notification_owner'),
    ('vistay_media_owner'), ('vistay_warehouse_owner'),
    ('vistay_payment_owner')
) AS owners(role_name)
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = role_name)
\gexec

SELECT format('CREATE ROLE %I LOGIN', role_name)
FROM (VALUES
    ('vistay_authentication_migrator'), ('vistay_authentication_app'),
    ('vistay_user_migrator'), ('vistay_user_app'),
    ('vistay_property_migrator'), ('vistay_property_app'),
    ('vistay_booking_migrator'), ('vistay_booking_app'),
    ('vistay_finance_migrator'), ('vistay_finance_app'),
    ('vistay_operations_migrator'), ('vistay_operations_app'),
    ('vistay_ota_migrator'), ('vistay_ota_app'),
    ('vistay_notification_migrator'), ('vistay_notification_app'),
    ('vistay_media_migrator'), ('vistay_media_app'),
    ('vistay_warehouse_migrator'), ('vistay_warehouse_app'),
    ('vistay_payment_migrator'), ('vistay_payment_app')
) AS logins(role_name)
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = role_name)
\gexec

SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_authentication_migrator', :'authentication_migrator_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_authentication_app', :'authentication_app_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_user_migrator', :'user_migrator_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_user_app', :'user_app_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_property_migrator', :'property_migrator_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_property_app', :'property_app_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_booking_migrator', :'booking_migrator_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_booking_app', :'booking_app_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_finance_migrator', :'finance_migrator_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_finance_app', :'finance_app_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_operations_migrator', :'operations_migrator_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_operations_app', :'operations_app_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_ota_migrator', :'ota_migrator_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_ota_app', :'ota_app_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_notification_migrator', :'notification_migrator_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_notification_app', :'notification_app_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_media_migrator', :'media_migrator_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_media_app', :'media_app_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_warehouse_migrator', :'warehouse_migrator_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_warehouse_app', :'warehouse_app_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_payment_migrator', :'payment_migrator_password') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', 'vistay_payment_app', :'payment_app_password') \gexec

SELECT format('GRANT %I TO %I', owner_name, migrator_name)
FROM (VALUES
    ('vistay_authentication_owner', 'vistay_authentication_migrator'),
    ('vistay_user_owner', 'vistay_user_migrator'),
    ('vistay_property_owner', 'vistay_property_migrator'),
    ('vistay_booking_owner', 'vistay_booking_migrator'),
    ('vistay_finance_owner', 'vistay_finance_migrator'),
    ('vistay_operations_owner', 'vistay_operations_migrator'),
    ('vistay_ota_owner', 'vistay_ota_migrator'),
    ('vistay_notification_owner', 'vistay_notification_migrator'),
    ('vistay_media_owner', 'vistay_media_migrator'),
    ('vistay_warehouse_owner', 'vistay_warehouse_migrator'),
    ('vistay_payment_owner', 'vistay_payment_migrator')
) AS memberships(owner_name, migrator_name)
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', database_name, owner_name)
FROM (VALUES
    ('vistay_authentication_db', 'vistay_authentication_owner'),
    ('vistay_user_db', 'vistay_user_owner'),
    ('vistay_property_db', 'vistay_property_owner'),
    ('vistay_booking_db', 'vistay_booking_owner'),
    ('vistay_finance_db', 'vistay_finance_owner'),
    ('vistay_operations_db', 'vistay_operations_owner'),
    ('vistay_ota_db', 'vistay_ota_owner'),
    ('vistay_notification_db', 'vistay_notification_owner'),
    ('vistay_media_db', 'vistay_media_owner'),
    ('vistay_warehouse_db', 'vistay_warehouse_owner'),
    ('vistay_payment_db', 'vistay_payment_owner')
) AS databases(database_name, owner_name)
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = database_name)
\gexec

SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', database_name)
FROM (VALUES
    ('vistay_authentication_db'), ('vistay_user_db'), ('vistay_property_db'),
    ('vistay_booking_db'), ('vistay_finance_db'), ('vistay_operations_db'),
    ('vistay_ota_db'), ('vistay_notification_db'), ('vistay_media_db'),
    ('vistay_warehouse_db'), ('vistay_payment_db')
) AS databases(database_name)
\gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I, %I', database_name, migrator_name, app_name)
FROM (VALUES
    ('vistay_authentication_db', 'vistay_authentication_migrator', 'vistay_authentication_app'),
    ('vistay_user_db', 'vistay_user_migrator', 'vistay_user_app'),
    ('vistay_property_db', 'vistay_property_migrator', 'vistay_property_app'),
    ('vistay_booking_db', 'vistay_booking_migrator', 'vistay_booking_app'),
    ('vistay_finance_db', 'vistay_finance_migrator', 'vistay_finance_app'),
    ('vistay_operations_db', 'vistay_operations_migrator', 'vistay_operations_app'),
    ('vistay_ota_db', 'vistay_ota_migrator', 'vistay_ota_app'),
    ('vistay_notification_db', 'vistay_notification_migrator', 'vistay_notification_app'),
    ('vistay_media_db', 'vistay_media_migrator', 'vistay_media_app'),
    ('vistay_warehouse_db', 'vistay_warehouse_migrator', 'vistay_warehouse_app'),
    ('vistay_payment_db', 'vistay_payment_migrator', 'vistay_payment_app')
) AS grants(database_name, migrator_name, app_name)
\gexec

SELECT format('ALTER ROLE %I IN DATABASE %I SET role TO %L', migrator_name, database_name, owner_name)
FROM (VALUES
    ('vistay_authentication_db', 'vistay_authentication_owner', 'vistay_authentication_migrator'),
    ('vistay_user_db', 'vistay_user_owner', 'vistay_user_migrator'),
    ('vistay_property_db', 'vistay_property_owner', 'vistay_property_migrator'),
    ('vistay_booking_db', 'vistay_booking_owner', 'vistay_booking_migrator'),
    ('vistay_finance_db', 'vistay_finance_owner', 'vistay_finance_migrator'),
    ('vistay_operations_db', 'vistay_operations_owner', 'vistay_operations_migrator'),
    ('vistay_ota_db', 'vistay_ota_owner', 'vistay_ota_migrator'),
    ('vistay_notification_db', 'vistay_notification_owner', 'vistay_notification_migrator'),
    ('vistay_media_db', 'vistay_media_owner', 'vistay_media_migrator'),
    ('vistay_warehouse_db', 'vistay_warehouse_owner', 'vistay_warehouse_migrator'),
    ('vistay_payment_db', 'vistay_payment_owner', 'vistay_payment_migrator')
) AS settings(database_name, owner_name, migrator_name)
\gexec
