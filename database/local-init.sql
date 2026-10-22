\set ON_ERROR_STOP on

SELECT format('CREATE DATABASE %I', database_name)
FROM (VALUES
  ('vistay_keycloak_db'),
  ('vistay_authentication_db'),
  ('vistay_user_db'),
  ('vistay_property_db'),
  ('vistay_booking_db'),
  ('vistay_finance_db'),
  ('vistay_operations_db'),
  ('vistay_ota_db'),
  ('vistay_notification_db'),
  ('vistay_media_db'),
  ('vistay_warehouse_db')
) AS databases(database_name)
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = database_name)
\gexec
