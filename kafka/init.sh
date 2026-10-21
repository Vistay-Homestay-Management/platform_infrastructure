#!/usr/bin/env bash
set -euo pipefail

admin_config=/etc/kafka/secrets/admin.properties

create_user() {
  local username="$1"
  local password="$2"
  /opt/kafka/bin/kafka-configs.sh \
    --bootstrap-server kafka:9092 \
    --command-config "$admin_config" \
    --alter \
    --add-config "SCRAM-SHA-512=[iterations=8192,password=${password}]" \
    --entity-type users \
    --entity-name "$username"
}

create_user vistay-admin "$KAFKA_ADMIN_PASSWORD"

for service in authentication user property booking finance operations ota notification media warehouse; do
  create_user "vistay-${service}" "$KAFKA_SERVICE_PASSWORD"
done

for domain in authentication user property booking finance operations ota notification media warehouse; do
  /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server kafka:9092 \
    --command-config "$admin_config" \
    --create --if-not-exists \
    --topic "vistay.${domain}.events.v1" \
    --partitions 3 \
    --replication-factor 1
done
