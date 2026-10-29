#!/usr/bin/env bash
# This file is mounted into a Linux container and must remain LF-only.
set -euo pipefail

admin_config=/etc/kafka/admin/admin.properties

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
create_user vistay-authentication "$KAFKA_AUTHENTICATION_PASSWORD"
create_user vistay-user "$KAFKA_USER_PASSWORD"
create_user vistay-property "$KAFKA_PROPERTY_PASSWORD"
create_user vistay-booking "$KAFKA_BOOKING_PASSWORD"
create_user vistay-finance "$KAFKA_FINANCE_PASSWORD"
create_user vistay-payment "$KAFKA_PAYMENT_PASSWORD"
create_user vistay-operations "$KAFKA_OPERATIONS_PASSWORD"
create_user vistay-ota "$KAFKA_OTA_PASSWORD"
create_user vistay-notification "$KAFKA_NOTIFICATION_PASSWORD"
create_user vistay-media "$KAFKA_MEDIA_PASSWORD"
create_user vistay-warehouse "$KAFKA_WAREHOUSE_PASSWORD"

create_topic() {
  local topic="$1"
  /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server kafka:9092 \
    --command-config "$admin_config" \
    --create --if-not-exists \
    --topic "$topic" \
    --partitions 3 \
    --replication-factor 1
}

# Epic 01 contracts use purpose-specific topics. Auto-creation stays disabled so
# producers cannot accidentally create misspelled or unreviewed event streams.
create_topic vistay.auth.account-provisioned.v1
create_topic vistay.user.profile-provisioned.v1
create_topic vistay.user.authorization-changed.v1
create_topic vistay.notification.notification-created.v1
create_topic vistay.payment.intent-created.v1
create_topic vistay.payment.qr-ready.v1
create_topic vistay.payment.intent-expired.v1
create_topic vistay.payment.transaction-confirmed.v1
create_topic vistay.payment.transaction-unmatched.v1

grant_producer() {
  local principal="$1"
  local topic="$2"
  /opt/kafka/bin/kafka-acls.sh \
    --bootstrap-server kafka:9092 \
    --command-config "$admin_config" \
    --add --allow-principal "User:${principal}" \
    --operation Write --operation Describe \
    --topic "$topic"
  /opt/kafka/bin/kafka-acls.sh \
    --bootstrap-server kafka:9092 \
    --command-config "$admin_config" \
    --add --allow-principal "User:${principal}" \
    --operation IdempotentWrite --cluster
}

grant_consumer() {
  local principal="$1"
  local topic="$2"
  local group="$3"
  /opt/kafka/bin/kafka-acls.sh \
    --bootstrap-server kafka:9092 \
    --command-config "$admin_config" \
    --add --allow-principal "User:${principal}" \
    --operation Read --operation Describe \
    --topic "$topic"
  /opt/kafka/bin/kafka-acls.sh \
    --bootstrap-server kafka:9092 \
    --command-config "$admin_config" \
    --add --allow-principal "User:${principal}" \
    --operation Read --operation Describe \
    --group "$group"
}

grant_producer vistay-authentication vistay.auth.account-provisioned.v1
grant_consumer vistay-user vistay.auth.account-provisioned.v1 vistay-user
grant_producer vistay-user vistay.user.profile-provisioned.v1
grant_producer vistay-user vistay.user.authorization-changed.v1
grant_consumer vistay-authentication vistay.user.authorization-changed.v1 vistay-authentication-service-authorization-cache
grant_consumer vistay-booking vistay.user.authorization-changed.v1 vistay-booking-service-authorization-cache
grant_consumer vistay-finance vistay.user.authorization-changed.v1 vistay-finance-service-authorization-cache
grant_consumer vistay-payment vistay.user.authorization-changed.v1 vistay-payment-service-authorization-cache
grant_consumer vistay-notification vistay.user.authorization-changed.v1 vistay-notification-service-authorization-cache
grant_consumer vistay-notification vistay.user.profile-provisioned.v1 vistay-notification
grant_producer vistay-notification vistay.notification.notification-created.v1
grant_producer vistay-payment vistay.payment.intent-created.v1
grant_producer vistay-payment vistay.payment.qr-ready.v1
grant_producer vistay-payment vistay.payment.intent-expired.v1
grant_producer vistay-payment vistay.payment.transaction-confirmed.v1
grant_producer vistay-payment vistay.payment.transaction-unmatched.v1
grant_consumer vistay-finance vistay.payment.transaction-confirmed.v1 vistay-finance-payment-confirmed-v1

client_config=/tmp/vistay-client.properties
cat >"$client_config" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="vistay-authentication" password="${KAFKA_AUTHENTICATION_PASSWORD}";
ssl.truststore.location=/etc/kafka/admin/kafka.truststore.jks
ssl.truststore.password=${KAFKA_STORE_PASSWORD}
ssl.endpoint.identification.algorithm=https
enable.idempotence=true
acks=all
retries=3
max.block.ms=10000
delivery.timeout.ms=10000
request.timeout.ms=5000
EOF

# Fail initialization if a workload cannot authenticate and produce over the
# internal CLIENT route. This catches listener advertisement, SCRAM, TLS, and
# the positive ACL path without granting broad cluster-level Describe access.
/opt/kafka/bin/kafka-broker-api-versions.sh \
  --bootstrap-server kafka:9094 \
  --command-config "$client_config" >/dev/null
positive_output=/tmp/vistay-positive-acl-smoke.jsonl
/opt/kafka/bin/kafka-verifiable-producer.sh \
  --bootstrap-server kafka:9094 \
  --command-config "$client_config" \
  --topic vistay.auth.account-provisioned.v1 \
  --max-messages 1 >"$positive_output"
grep -q 'producer_send_success' "$positive_output"

# The same principal must not be able to write another service's topic.
negative_output=/tmp/vistay-negative-acl-smoke.log
set +e
timeout 20s /opt/kafka/bin/kafka-verifiable-producer.sh \
  --bootstrap-server kafka:9094 \
  --command-config "$client_config" \
  --topic vistay.user.profile-provisioned.v1 \
  --max-messages 1 >"$negative_output" 2>&1
set -e
if grep -q 'producer_send_success' "$negative_output"; then
  echo "ACL regression: authentication principal can write the User-owned topic." >&2
  exit 1
fi
grep -q 'TopicAuthorizationException' "$negative_output"
rm -f "$client_config" "$positive_output" "$negative_output"
