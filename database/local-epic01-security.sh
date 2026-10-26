#!/usr/bin/env bash
set -euo pipefail

psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 \
  --set authentication_migrator_password="$AUTHENTICATION_DB_MIGRATOR_PASSWORD" \
  --set authentication_app_password="$AUTHENTICATION_DB_APP_PASSWORD" \
  --set user_migrator_password="$USER_DB_MIGRATOR_PASSWORD" \
  --set user_app_password="$USER_DB_APP_PASSWORD" \
  --set notification_migrator_password="$NOTIFICATION_DB_MIGRATOR_PASSWORD" \
  --set notification_app_password="$NOTIFICATION_DB_APP_PASSWORD" \
  --set finance_migrator_password="$FINANCE_DB_MIGRATOR_PASSWORD" \
  --set finance_app_password="$FINANCE_DB_APP_PASSWORD" \
  --set payment_migrator_password="$PAYMENT_DB_MIGRATOR_PASSWORD" \
  --set payment_app_password="$PAYMENT_DB_APP_PASSWORD" \
  --file /opt/vistay/local-epic01-security.sql
